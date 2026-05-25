#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/verify-pkg-artifact.sh <archive.pkg> [archive.pkg.sha256]" >&2
  exit 64
fi

pkg="$1"
checksum="${2:-${pkg}.sha256}"

if [[ ! -f "$pkg" ]]; then
  echo "pkg not found: $pkg" >&2
  exit 66
fi

if [[ ! -f "$checksum" ]]; then
  echo "checksum not found: $checksum" >&2
  exit 66
fi

pkg_dir="$(cd "$(dirname "$pkg")" && pwd -P)"
pkg_name="$(basename "$pkg")"
checksum_dir="$(cd "$(dirname "$checksum")" && pwd -P)"
checksum_name="$(basename "$checksum")"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/goh-pkg-verify.XXXXXX")"

cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT

(
  cd "$checksum_dir"
  shasum -a 256 -c "$checksum_name"
)

pkgutil --expand "$pkg_dir/$pkg_name" "$temp_dir/expanded"
distribution="$temp_dir/expanded/Distribution"

if [[ ! -f "$distribution" ]]; then
  echo "missing package Distribution" >&2
  exit 65
fi

xmllint --noout "$distribution"

product_id="$(xmllint --xpath "string(/installer-gui-script/product/@id)" "$distribution")"
min_os="$(xmllint --xpath "string(/installer-gui-script/volume-check/allowed-os-versions/os-version/@min)" "$distribution")"
arch="$(xmllint --xpath "string(/installer-gui-script/options/@hostArchitectures)" "$distribution")"
requires_scripts="$(xmllint --xpath "string(/installer-gui-script/options/@require-scripts)" "$distribution")"
component_ref="$(xmllint --xpath "string(/installer-gui-script/pkg-ref[starts-with(text(), '#')]/@id)" "$distribution")"

if [[ "$product_id" != "dev.goh.pkg" ]]; then
  echo "unexpected package product id: $product_id" >&2
  exit 65
fi

if [[ "$min_os" != "26.5" ]]; then
  echo "unexpected package minimum OS: $min_os" >&2
  exit 65
fi

if [[ "$arch" != "arm64" ]]; then
  echo "unexpected package architecture requirement: $arch" >&2
  exit 65
fi

if [[ "$requires_scripts" != "false" ]]; then
  echo "package should not require installer scripts" >&2
  exit 65
fi

if [[ "$component_ref" != "dev.goh.payload" ]]; then
  echo "unexpected package component reference: $component_ref" >&2
  exit 65
fi

package_infos=()
while IFS= read -r package_info; do
  package_infos+=("$package_info")
done < <(find "$temp_dir/expanded" -mindepth 2 -maxdepth 2 -type f -name PackageInfo | sort)

if [[ ${#package_infos[@]} -ne 1 ]]; then
  echo "expected exactly one package component info file" >&2
  exit 65
fi

component_id="$(xmllint --xpath "string(/pkg-info/@identifier)" "${package_infos[0]}")"
install_location="$(xmllint --xpath "string(/pkg-info/@install-location)" "${package_infos[0]}")"
postinstall_action="$(xmllint --xpath "string(/pkg-info/@postinstall-action)" "${package_infos[0]}")"

if [[ "$component_id" != "dev.goh.payload" ]]; then
  echo "unexpected package component id: $component_id" >&2
  exit 65
fi

if [[ "$install_location" != "/" ]]; then
  echo "unexpected package install location: $install_location" >&2
  exit 65
fi

if [[ "$postinstall_action" != "none" ]]; then
  echo "unexpected postinstall action: $postinstall_action" >&2
  exit 65
fi

payload_listing="$temp_dir/payload-files.txt"
pkgutil --payload-files "$pkg_dir/$pkg_name" > "$payload_listing"

required_payload_files=(
  "./usr/local/bin/goh"
  "./usr/local/bin/gohd"
  "./usr/local/share/doc/goh/LICENSE"
  "./usr/local/share/doc/goh/README.md"
  "./usr/local/share/goh/dev.goh.daemon.plist"
)

for path in "${required_payload_files[@]}"; do
  if ! grep -Fx "$path" "$payload_listing" >/dev/null; then
    echo "missing package payload file: $path" >&2
    exit 65
  fi
done

payloads=()
while IFS= read -r payload; do
  payloads+=("$payload")
done < <(find "$temp_dir/expanded" -mindepth 2 -maxdepth 2 -type f -name Payload | sort)

if [[ ${#payloads[@]} -ne 1 ]]; then
  echo "expected exactly one package payload" >&2
  exit 65
fi

mkdir -p "$temp_dir/payload-root"
(
  cd "$temp_dir/payload-root"
  gzip -dc "${payloads[0]}" | cpio -idm --quiet
)

if find "$temp_dir/payload-root" -name '._*' -print -quit | grep . >/dev/null; then
  echo "extracted package payload should not contain AppleDouble files" >&2
  exit 65
fi

for binary in "$temp_dir/payload-root/usr/local/bin/goh" "$temp_dir/payload-root/usr/local/bin/gohd"; do
  if [[ ! -x "$binary" ]]; then
    echo "missing executable package payload: ${binary#$temp_dir/payload-root/}" >&2
    exit 65
  fi
done

packaged_plist="$temp_dir/payload-root/usr/local/share/goh/dev.goh.daemon.plist"
plutil -lint "$packaged_plist" >/dev/null
daemon_path="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$packaged_plist")"
if [[ "$daemon_path" != "/usr/local/bin/gohd" ]]; then
  echo "unexpected packaged daemon path: $daemon_path" >&2
  exit 65
fi

if /usr/libexec/PlistBuddy -c "Print :StandardOutPath" "$packaged_plist" >/dev/null 2>&1; then
  echo "packaged reference plist should not set StandardOutPath" >&2
  exit 65
fi

if /usr/libexec/PlistBuddy -c "Print :StandardErrorPath" "$packaged_plist" >/dev/null 2>&1; then
  echo "packaged reference plist should not set StandardErrorPath" >&2
  exit 65
fi

"$temp_dir/payload-root/usr/local/bin/goh" --help >/dev/null

echo "verified=$pkg_dir/$pkg_name"
