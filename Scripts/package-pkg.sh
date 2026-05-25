#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/package-pkg.sh <version> [output-directory]" >&2
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

package_name="goh-${version}-macos-arm64"
stage_parent="$repo_root/.build/pkg-package"
payload_root="$stage_parent/payload"
requirements="$stage_parent/requirements.plist"
component_pkg="$stage_parent/payload.pkg"
pkg="$output_dir/${package_name}.pkg"
checksum="$output_dir/${package_name}.pkg.sha256"
pkg_version="0.0.0"

if [[ "$version" =~ ^v?([0-9]+([.][0-9]+){0,2})([-_].*)?$ ]]; then
  pkg_version="${BASH_REMATCH[1]}"
fi

swift build --package-path "$repo_root" --configuration release --disable-sandbox

rm -rf "$stage_parent"
mkdir -p \
  "$payload_root/usr/local/bin" \
  "$payload_root/usr/local/share/doc/goh" \
  "$payload_root/usr/local/share/goh" \
  "$output_dir"

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

rm -f "$pkg" "$checksum"
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
  "$pkg"

(
  cd "$output_dir"
  shasum -a 256 "${package_name}.pkg" > "${package_name}.pkg.sha256"
)

echo "pkg=$pkg"
echo "checksum=$checksum"
