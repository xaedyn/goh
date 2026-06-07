#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/private-release-candidate.sh <version> [output-directory]" >&2
  exit 64
fi

version="$1"

if [[ ! "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "version may contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
output_arg="${2:-.build/private-release-artifacts}"

case "$output_arg" in
  /*) output_dir="$output_arg" ;;
  *) output_dir="$repo_root/$output_arg" ;;
esac

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required environment variable: $name" >&2
    exit 64
  fi
}

decode_base64_env() {
  local name="$1"
  local destination="$2"
  printf '%s' "${!name}" | /usr/bin/base64 -D > "$destination"
}

require_env "DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64"
require_env "DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD"
require_env "DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64"
require_env "DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD"
require_env "GOH_APP_SIGN_IDENTITY"
require_env "GOH_INSTALLER_SIGN_IDENTITY"

package_name="goh-${version}-macos-arm64"
stage_parent="$repo_root/.build/private-release-candidate"
payload_root="$stage_parent/payload"
requirements="$stage_parent/requirements.plist"
component_pkg="$stage_parent/payload.pkg"
pkg="$output_dir/${package_name}.pkg"
checksum="$output_dir/${package_name}.pkg.sha256"
notary_submit_json="$output_dir/${package_name}.notary-submit.json"
notary_log_json="$output_dir/${package_name}.notary-log.json"
keychain="$stage_parent/goh-signing.keychain-db"
keychain_password="$(uuidgen)"
app_certificate="$stage_parent/developer-id-application.p12"
installer_certificate="$stage_parent/developer-id-installer.p12"
notary_key="$stage_parent/AuthKey_${APPLE_NOTARY_KEY_ID:-notary}.p8"
pkg_version="0.0.0"

if [[ "$version" =~ ^v?([0-9]+([.][0-9]+){0,2})([-_].*)?$ ]]; then
  pkg_version="${BASH_REMATCH[1]}"
fi

original_keychains=()
while IFS= read -r keychain_entry; do
  keychain_entry="${keychain_entry#"${keychain_entry%%[![:space:]]*}"}"
  keychain_entry="${keychain_entry%\"}"
  keychain_entry="${keychain_entry#\"}"
  original_keychains+=("$keychain_entry")
done < <(security list-keychains -d user)

cleanup() {
  if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$stage_parent"
}
trap cleanup EXIT

notary_auth_args=()
if [[ -n "${APPLE_NOTARY_KEY_ID:-}" || -n "${APPLE_NOTARY_ISSUER_ID:-}" || -n "${APPLE_NOTARY_KEY_P8_BASE64:-}" ]]; then
  require_env "APPLE_NOTARY_KEY_ID"
  require_env "APPLE_NOTARY_ISSUER_ID"
  require_env "APPLE_NOTARY_KEY_P8_BASE64"
  notary_auth_args=(
    --key "$notary_key"
    --key-id "$APPLE_NOTARY_KEY_ID"
    --issuer "$APPLE_NOTARY_ISSUER_ID"
  )
elif [[ -n "${APPLE_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  require_env "APPLE_ID"
  require_env "APPLE_APP_SPECIFIC_PASSWORD"
  require_env "APPLE_TEAM_ID"
  notary_auth_args=(
    --apple-id "$APPLE_ID"
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
    --team-id "$APPLE_TEAM_ID"
  )
else
  echo "missing notarization credentials: provide APPLE_NOTARY_* API key values or APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD" >&2
  exit 64
fi

swift build --package-path "$repo_root" --configuration release --disable-sandbox

rm -rf "$stage_parent"
mkdir -p \
  "$payload_root/usr/local/bin" \
  "$payload_root/usr/local/share/doc/goh" \
  "$payload_root/usr/local/share/goh" \
  "$output_dir"

decode_base64_env "DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64" "$app_certificate"
decode_base64_env "DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64" "$installer_certificate"
# Owner-only on the decoded .p12 material, immediately after decode and before
# the keychain import, matching the notary key below (audit L4).
chmod 0600 "$app_certificate" "$installer_certificate"
if [[ ${#notary_auth_args[@]} -gt 0 && -n "${APPLE_NOTARY_KEY_P8_BASE64:-}" ]]; then
  decode_base64_env "APPLE_NOTARY_KEY_P8_BASE64" "$notary_key"
  chmod 0600 "$notary_key"
fi

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$app_certificate" \
  -k "$keychain" \
  -P "$DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security import "$installer_certificate" \
  -k "$keychain" \
  -P "$DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD" \
  -T /usr/bin/productbuild \
  -T /usr/bin/security
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null

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

# Stage goh.app into the payload.
# NOTE: package-app.sh runs swift build again; it is idempotent (same release build).
source "$script_dir/_stage-app-payload.sh"

# Sign inside-out: inner Mach-Os first, then the .app bundle last.
# The goh-menu binary inside the .app must be signed before the bundle seal.
for binary in "$payload_root/usr/local/bin/goh" "$payload_root/usr/local/bin/gohd" \
              "$payload_root/Applications/goh.app/Contents/MacOS/goh-menu"; do
  codesign --force --sign "$GOH_APP_SIGN_IDENTITY" \
    --options runtime --timestamp --keychain "$keychain" "$binary"
  codesign --verify --strict --verbose=2 "$binary"
done

# Sign the .app bundle last (after inner binary is signed).
codesign --force --sign "$GOH_APP_SIGN_IDENTITY" \
  --options runtime --timestamp --keychain "$keychain" \
  "$payload_root/Applications/goh.app"
codesign --verify --strict --verbose=2 "$payload_root/Applications/goh.app"

# POST-CREDENTIAL NOTE: after the PKG is notarized and stapled, the .app
# inside it is also covered by the PKG's notarization ticket. No separate
# staple on the .app is required when it is delivered inside a notarized PKG.

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
  --sign "$GOH_INSTALLER_SIGN_IDENTITY" \
  --keychain "$keychain" \
  --timestamp \
  "$pkg"

pkgutil --check-signature "$pkg"

notary_submit_status=0
xcrun notarytool submit "$pkg" \
  --wait \
  --timeout 30m \
  --output-format json \
  "${notary_auth_args[@]}" \
  > "$notary_submit_json" || notary_submit_status=$?

submission_id="$(plutil -extract id raw -o - "$notary_submit_json" 2>/dev/null || true)"
submission_status="$(plutil -extract status raw -o - "$notary_submit_json" 2>/dev/null || true)"

if [[ -n "$submission_id" ]]; then
  if ! xcrun notarytool log "$submission_id" "$notary_log_json" "${notary_auth_args[@]}"; then
    echo "failed to download notarization log for submission $submission_id" >&2
    if [[ "$submission_status" == "Accepted" ]]; then
      exit 65
    fi
  fi
else
  echo "notarization submission did not return an id; see $notary_submit_json" >&2
fi

if [[ "$notary_submit_status" -ne 0 || "$submission_status" != "Accepted" ]]; then
  echo "notarization status was ${submission_status:-unknown}; see $notary_log_json" >&2
  exit 65
fi

xcrun stapler staple "$pkg"
spctl -a -v --type install "$pkg"

(
  cd "$output_dir"
  shasum -a 256 "${package_name}.pkg" > "${package_name}.pkg.sha256"
)

echo "pkg=$pkg"
echo "checksum=$checksum"
echo "notary_submit=$notary_submit_json"
echo "notary_log=$notary_log_json"
