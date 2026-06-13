#!/usr/bin/env bash
set -euo pipefail

# dev-app.sh — assemble a local DEBUG goh.app for running the menu-bar app during
# development (the redesign work). Unsigned, unnotarized; for local testing only.
#
# Why a bundle and not the bare binary: the menu app uses UNUserNotificationCenter
# (and SMAppService), which abort when run without an app bundle. Wrapping the
# debug binary in a minimal .app gives it a CFBundleIdentifier + a Resources dir
# where Bundle.module finds the goh wordmark — the same layout package-app.sh
# produces for release.
#
# Usage: Scripts/dev-app.sh   →   prints the command to launch it.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
cd "$repo_root"

app="$repo_root/.build/dev-app/goh.app"
contents="$app/Contents"

swift build --configuration debug --disable-sandbox

menubar_bundle="$repo_root/.build/debug/goh_GohMenuBar.bundle"
if [[ ! -d "$menubar_bundle" ]]; then
  echo "error: missing resource bundle $menubar_bundle" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
install -m 0755 "$repo_root/.build/debug/goh-menu" "$contents/MacOS/goh-menu"
cp -R "$menubar_bundle" "$contents/Resources/"
sed 's/__VERSION__/dev/g' "$repo_root/Resources/app-Info.plist" > "$contents/Info.plist"
plutil -lint "$contents/Info.plist" >/dev/null
xattr -cr "$app"

# Sign with a Developer ID Application identity if one is available, so the app
# passes the daemon's same-team XPC peer validation and can talk to an already
# installed daemon — no GOH_XPC_ALLOW_UNVALIDATED_PEERS, no daemon swap. Falls
# back to unsigned (use the relax env + a dev daemon) if no identity is found.
identity="$(security find-identity -p codesigning -v 2>/dev/null \
  | grep -o 'Developer ID Application: [^"]*' | head -1)"
if [[ -n "$identity" ]]; then
  codesign --force --options runtime --sign "$identity" "$contents/MacOS/goh-menu"
  codesign --force --options runtime --sign "$identity" "$app"
  cat <<EOF

Built + signed $app
  (signed with: $identity)

Launch it — it talks to your installed daemon via same-team validation:

  "$contents/MacOS/goh-menu"

Look for the goh wordmark in your menu bar. Quit via the popover ⋯ → Quit goh,
or Ctrl-C in this terminal.
EOF
else
  cat <<EOF

Built (unsigned) $app

No Developer ID found. Launch with peer validation relaxed, against a dev daemon:

  GOH_XPC_ALLOW_UNVALIDATED_PEERS=1 "$contents/MacOS/goh-menu"
  (start a dev daemon first: Scripts/dogfood-install.sh)
EOF
fi
