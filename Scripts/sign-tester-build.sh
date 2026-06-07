#!/usr/bin/env bash
set -euo pipefail

# sign-tester-build.sh — produce a SIGNED + NOTARIZED + STAPLED all-in-one tester PKG
# on your own Mac, using the Developer ID certificates already in your login keychain.
#
# This is the LOCAL, solo-developer counterpart to private-release-candidate.sh (which is
# CI-shaped: base64 certs + ephemeral keychain). Here the certs live in your login keychain,
# so there is no base64 import and no `--keychain` override — codesign/productbuild use the
# default keychain search list directly. The assembly + inside-out signing + notarize + staple
# flow mirrors private-release-candidate.sh exactly so the two stay equivalent.
#
# Scope: PRIVATE TESTER distribution only. This does NOT open the brew tap or do any public
# launch step. The output PKG is for you to hand to a handful of testers.
#
# ── One-time setup (do these once before the first run) ───────────────────────────────────
#   1. Create two certs (Apple Developer portal or Xcode → Settings → Accounts →
#      Manage Certificates): "Developer ID Application" and "Developer ID Installer".
#      Confirm both are present:   security find-identity -v -p codesigning   (Application)
#                                  security find-identity -v                  (Installer too)
#   2. Store a notarization credential as a keychain profile (Apple's recommended local path):
#        xcrun notarytool store-credentials goh-notary \
#          --apple-id "you@example.com" --team-id "YOURTEAMID" --password "app-specific-pw"
#      (Create the app-specific password at appleid.apple.com → Sign-In & Security.)
#
# ── Usage ─────────────────────────────────────────────────────────────────────────────────
#   Scripts/sign-tester-build.sh <version> [output-directory]
#
# Optional overrides (auto-detected from the keychain if unset):
#   GOH_APP_SIGN_IDENTITY        full "Developer ID Application: …" identity string
#   GOH_INSTALLER_SIGN_IDENTITY  full "Developer ID Installer: …" identity string
#   GOH_NOTARY_PROFILE           notarytool keychain profile name (default: goh-notary)
# Alternative notary auth (instead of the profile): set APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD
#   + APPLE_TEAM_ID and they will be used directly.
#
# Exit codes: 0 ok · 64 usage/config · 65 notarization rejected (Invalid)/build error ·
#   75 uploaded but Apple still processing past the wait (NOT a failure — the script prints
#      the exact `notarytool wait …` + `stapler staple …` recovery to finish once Apple's done) ·
#   1 signing error.
# Tunable: GOH_NOTARY_TIMEOUT (default 60m) — how long to wait on Apple's notary queue.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/sign-tester-build.sh <version> [output-directory]" >&2
  exit 64
fi

version="$1"
if [[ ! "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "version may contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
output_arg="${2:-.build/tester-artifacts}"
case "$output_arg" in
  /*) output_dir="$output_arg" ;;
  *) output_dir="$repo_root/$output_arg" ;;
esac

package_name="goh-${version}-macos-arm64"
stage_parent="$repo_root/.build/sign-tester-build"
payload_root="$stage_parent/payload"
requirements="$stage_parent/requirements.plist"
component_pkg="$stage_parent/payload.pkg"
pkg="$output_dir/${package_name}.pkg"
checksum="$output_dir/${package_name}.pkg.sha256"
notary_submit_json="$output_dir/${package_name}.notary-submit.json"
notary_log_json="$output_dir/${package_name}.notary-log.json"
pkg_version="0.0.0"
if [[ "$version" =~ ^v?([0-9]+([.][0-9]+){0,2})([-_].*)?$ ]]; then
  pkg_version="${BASH_REMATCH[1]}"
fi

cert_chain_warning=0

# ── Resolve signing identities from the login keychain (env override wins) ─────────────────
# Auto-detect requires EXACTLY one matching identity; otherwise we refuse to guess.
detect_identity() {  # $1 = match substring; remaining args = `security find-identity` policy
  local pattern="$1"; shift
  local lines
  lines="$(security find-identity -v "$@" 2>/dev/null | grep -F "$pattern" || true)"
  if [[ "$(printf '%s\n' "$lines" | grep -c '"' || true)" -ne 1 ]]; then
    return 1
  fi
  printf '%s\n' "$lines" | sed -E 's/.*"(.*)".*/\1/'
}

if [[ -n "${GOH_APP_SIGN_IDENTITY:-}" ]]; then
  app_identity="$GOH_APP_SIGN_IDENTITY"
elif ! app_identity="$(detect_identity "Developer ID Application" -p codesigning)"; then
  echo "error: could not auto-detect exactly one 'Developer ID Application' identity." >&2
  echo "  list:  security find-identity -v -p codesigning" >&2
  echo "  then:  export GOH_APP_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'" >&2
  exit 64
fi

if [[ -n "${GOH_INSTALLER_SIGN_IDENTITY:-}" ]]; then
  installer_identity="$GOH_INSTALLER_SIGN_IDENTITY"
elif ! installer_identity="$(detect_identity "Developer ID Installer")"; then
  echo "error: could not auto-detect exactly one 'Developer ID Installer' identity." >&2
  echo "  list:  security find-identity -v" >&2
  echo "  then:  export GOH_INSTALLER_SIGN_IDENTITY='Developer ID Installer: Your Name (TEAMID)'" >&2
  exit 64
fi

echo "Signing with:"
echo "  app:       $app_identity"
echo "  installer: $installer_identity"

# ── Resolve notarization credentials (keychain profile preferred) ──────────────────────────
# Apple's notary queue is sometimes slow (20-45+ min even with a green status page), so the
# wait is generous and a timeout is treated as "still pending," not a failure (see below).
notary_timeout="${GOH_NOTARY_TIMEOUT:-60m}"
notary_auth_args=()
# notary_auth_display is a SECRET-SAFE rendering of the auth args for printing in the
# recovery hint — it never includes the app-specific password.
notary_auth_display=""
if [[ -n "${APPLE_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  for v in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
    if [[ -z "${!v:-}" ]]; then echo "missing required env var: $v" >&2; exit 64; fi
  done
  notary_auth_args=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
  notary_auth_display="--apple-id $APPLE_ID --team-id $APPLE_TEAM_ID --password <your-app-specific-password>"
  echo "  notary:    Apple ID $APPLE_ID (team $APPLE_TEAM_ID)"
else
  notary_profile="${GOH_NOTARY_PROFILE:-goh-notary}"
  notary_auth_args=(--keychain-profile "$notary_profile")
  notary_auth_display="--keychain-profile $notary_profile"
  echo "  notary:    keychain profile '$notary_profile'"
  echo "             (set up once with: xcrun notarytool store-credentials $notary_profile …)"
fi

# ── Build + assemble payload (mirrors private-release-candidate.sh staging) ─────────────────
swift build --package-path "$repo_root" --configuration release --disable-sandbox

rm -rf "$stage_parent"
mkdir -p \
  "$payload_root/usr/local/bin" \
  "$payload_root/usr/local/share/doc/goh" \
  "$payload_root/usr/local/share/goh" \
  "$output_dir"

# CLI + daemon + docs + launchd plist. LOCKSTEP NOTE: this staging mirrors
# private-release-candidate.sh lines ~142-152 and package-pkg.sh; keep them in sync.
install -m 0755 "$repo_root/.build/release/goh" "$payload_root/usr/local/bin/goh"
install -m 0755 "$repo_root/.build/release/gohd" "$payload_root/usr/local/bin/gohd"
install -m 0644 "$repo_root/LICENSE" "$payload_root/usr/local/share/doc/goh/LICENSE"
install -m 0644 "$repo_root/README.md" "$payload_root/usr/local/share/doc/goh/README.md"
install -m 0644 "$repo_root/Resources/dev.goh.daemon.plist" "$payload_root/usr/local/share/goh/dev.goh.daemon.plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /usr/local/bin/gohd" "$payload_root/usr/local/share/goh/dev.goh.daemon.plist"
/usr/libexec/PlistBuddy -c "Delete :StandardOutPath" "$payload_root/usr/local/share/goh/dev.goh.daemon.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :StandardErrorPath" "$payload_root/usr/local/share/goh/dev.goh.daemon.plist" >/dev/null 2>&1 || true
plutil -lint "$payload_root/usr/local/share/goh/dev.goh.daemon.plist" >/dev/null
xattr -cr "$payload_root"

# Stage goh.app into /Applications in the payload (shared helper; needs repo_root/payload_root/version).
source "$script_dir/_stage-app-payload.sh"

# ── Sign inside-out: inner Mach-Os first, then the .app bundle last ────────────────────────
sign_target() {  # codesign with hardened runtime + timestamp, watching for a broken cert chain
  local target="$1" out
  if ! out="$(codesign --force --sign "$app_identity" --options runtime --timestamp "$target" 2>&1)"; then
    printf '%s\n' "$out" >&2
    echo "error: codesign failed for $target" >&2
    exit 1
  fi
  if printf '%s' "$out" | grep -q "unable to build chain to self-signed root"; then
    cert_chain_warning=1
  fi
  codesign --verify --strict --verbose=2 "$target"
}

for binary in "$payload_root/usr/local/bin/goh" "$payload_root/usr/local/bin/gohd" \
              "$payload_root/Applications/goh.app/Contents/MacOS/goh-menu"; do
  sign_target "$binary"
done
sign_target "$payload_root/Applications/goh.app"

# ── Build + sign the installer (Developer ID Installer) ────────────────────────────────────
cat > "$requirements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>os</key>
    <array>
        <string>26.5</string>
    </array>
    <key>arch</key>
    <array>
        <string>arm64</string>
    </array>
</dict>
</plist>
PLIST

rm -f "$pkg" "$checksum" "$notary_submit_json" "$notary_log_json"
pkgbuild \
  --root "$payload_root" \
  --identifier dev.goh.payload \
  --version "$pkg_version" \
  --install-location / \
  --ownership recommended \
  "$component_pkg"

productbuild \
  --product "$requirements" \
  --package "$component_pkg" / \
  --identifier dev.goh.pkg \
  --version "$pkg_version" \
  --sign "$installer_identity" \
  --timestamp \
  "$pkg"

pkgutil --check-signature "$pkg"

# ── Notarize + staple ─────────────────────────────────────────────────────────────────────
notary_submit_status=0
xcrun notarytool submit "$pkg" \
  --wait --timeout "$notary_timeout" --output-format json \
  "${notary_auth_args[@]}" \
  > "$notary_submit_json" || notary_submit_status=$?

submission_id="$(plutil -extract id raw -o - "$notary_submit_json" 2>/dev/null || true)"
submission_status="$(plutil -extract status raw -o - "$notary_submit_json" 2>/dev/null || true)"

# Download the log when there's a terminal status to explain (Accepted logs are empty-ish;
# Invalid logs carry the reason). Best-effort.
if [[ -n "$submission_id" ]]; then
  xcrun notarytool log "$submission_id" "$notary_log_json" "${notary_auth_args[@]}" >/dev/null 2>&1 || true
fi

if [[ "$submission_status" == "Invalid" ]]; then
  echo "error: notarization was REJECTED (Invalid). See the reason in:" >&2
  echo "  $notary_log_json" >&2
  echo "  (or: xcrun notarytool log $submission_id $notary_auth_display)" >&2
  exit 65
elif [[ "$submission_status" != "Accepted" ]]; then
  # Not rejected, just not finished in time — Apple is still processing. The .pkg is built
  # and signed; it only needs the ticket stapled once Apple finishes. This is NOT a failure.
  if [[ -n "$submission_id" ]]; then
    cat >&2 <<EOF

────────────────────────────────────────────────────────────────────────────
Apple is still processing notarization (didn't finish within $notary_timeout).
This is normal on a slow notary queue — nothing is wrong. The .pkg is built and
signed; it just needs the ticket stapled once Apple is done. Finish it with:

  xcrun notarytool wait $submission_id $notary_auth_display
  xcrun stapler staple "$pkg"
  xcrun stapler validate "$pkg"
  pkgutil --check-signature "$pkg"

(submission id: $submission_id)
────────────────────────────────────────────────────────────────────────────
EOF
    exit 75
  fi
  echo "error: notarization submission failed (no id returned); see $notary_submit_json" >&2
  exit 65
fi

# status == Accepted → staple the ticket.
xcrun stapler staple "$pkg"

# ── Verify ────────────────────────────────────────────────────────────────────────────────
# Authoritative offline checks (must pass):
xcrun stapler validate "$pkg"
pkgutil --check-signature "$pkg" >/dev/null

# Gatekeeper assessment (advisory): on macOS 26 Tahoe there is a known issue where a
# correctly-stapled .pkg can still report `rejected` here when the signing cert chain is
# incomplete. Treat a rejection as a signal to fix the cert chain, not necessarily a broken
# build — verify by installing on a clean tester machine.
spctl_status=0
spctl -a -vvv --type install "$pkg" || spctl_status=$?

if [[ "$cert_chain_warning" -eq 1 || "$spctl_status" -ne 0 ]]; then
  echo "" >&2
  echo "WARNING: signing-cert-chain / Gatekeeper-assessment concern detected." >&2
  if [[ "$cert_chain_warning" -eq 1 ]]; then
    echo "  codesign reported: 'unable to build chain to self-signed root'." >&2
  fi
  if [[ "$spctl_status" -ne 0 ]]; then
    echo "  spctl --type install did not return 'accepted' (known macOS 26 .pkg quirk)." >&2
  fi
  echo "  The staple + installer signature are valid (checked above), so the PKG may still" >&2
  echo "  install fine — but confirm on a clean tester Mac. To fix an incomplete cert chain," >&2
  echo "  install the Apple intermediate/root certs: https://developer.apple.com/forums/thread/712043" >&2
fi

( cd "$output_dir" && shasum -a 256 "${package_name}.pkg" > "${package_name}.pkg.sha256" )

echo ""
echo "Done."
echo "  pkg=$pkg"
echo "  checksum=$checksum"
echo "  Hand the .pkg to testers; double-click installs CLI + daemon + tray app."
