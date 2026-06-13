#!/usr/bin/env bash
set -euo pipefail

# Assembles goh.app from a swift build --release output.
# Usage: Scripts/package-app.sh <version> [output-directory]
#
# THE BET (Approach B): engine + tray app are versioned together in the PKG.
# This script is called by package-pkg.sh; the output path must not drift
# between the two scripts (advisory E from spec §7.5).
#
# Exit codes:
#   0   success
#   64  usage / bad version / missing CFBundleIdentifier in template

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/package-app.sh <version> [output-directory]" >&2
  exit 64
fi

version="$1"

if [[ ! "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "version may contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
output_arg="${2:-.build/release-artifacts}"

case "$output_arg" in
  /*) output_dir="$output_arg" ;;
  *) output_dir="$repo_root/$output_arg" ;;
esac

template="$repo_root/Resources/app-Info.plist"
app_dir="$output_dir/goh.app"
contents="$app_dir/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
info_plist="$contents/Info.plist"

# Guard: template must declare a CFBundleIdentifier (needed by SMAppService +
# UNUserNotificationCenter).
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$template" >/dev/null 2>&1; then
  echo "error: Info.plist template at $template is missing CFBundleIdentifier" >&2
  exit 64
fi

swift build --package-path "$repo_root" --configuration release --disable-sandbox

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir" "$output_dir"

install -m 0755 "$repo_root/.build/release/goh-menu" "$macos_dir/goh-menu"

# Copy the GohMenuBar SwiftPM resource bundle (the goh wordmark SVG) into the
# app's Resources so Bundle.module resolves it at runtime. Without this the
# packaged app renders a blank wordmark in the status item + popover header.
menubar_bundle="$repo_root/.build/release/goh_GohMenuBar.bundle"
if [[ ! -d "$menubar_bundle" ]]; then
  echo "error: missing resource bundle $menubar_bundle (did the release build run?)" >&2
  exit 1
fi
cp -R "$menubar_bundle" "$resources_dir/"

# Substitute __VERSION__ placeholder with the actual version string.
sed "s/__VERSION__/$version/g" "$template" > "$info_plist"
plutil -lint "$info_plist" >/dev/null

# Verify the identifier round-trips correctly.
bundle_id="$(defaults read "$contents/Info" CFBundleIdentifier 2>/dev/null || true)"
if [[ -z "$bundle_id" ]]; then
  echo "error: CFBundleIdentifier not readable from assembled Info.plist" >&2
  exit 1
fi

xattr -cr "$app_dir"

echo "app=$app_dir"
echo "bundle_id=$bundle_id"
