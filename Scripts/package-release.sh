#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/package-release.sh <version> [output-directory]" >&2
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
stage_parent="$repo_root/.build/release-package"
stage_dir="$stage_parent/goh-${version}"
archive="$output_dir/${package_name}.tar.gz"
checksum="$output_dir/${package_name}.tar.gz.sha256"

swift build --package-path "$repo_root" --configuration release --disable-sandbox

rm -rf "$stage_parent"
mkdir -p "$stage_dir/bin" "$stage_dir/Resources" "$output_dir"

install -m 0755 "$repo_root/.build/release/goh" "$stage_dir/bin/goh"
install -m 0755 "$repo_root/.build/release/gohd" "$stage_dir/bin/gohd"
install -m 0644 "$repo_root/Resources/dev.goh.daemon.plist" "$stage_dir/Resources/dev.goh.daemon.plist"
install -m 0644 "$repo_root/LICENSE" "$stage_dir/LICENSE"
install -m 0644 "$repo_root/README.md" "$stage_dir/README.md"

rm -f "$archive" "$checksum"
tar -C "$stage_parent" -czf "$archive" "goh-${version}"

(
  cd "$output_dir"
  shasum -a 256 "${package_name}.tar.gz" > "${package_name}.tar.gz.sha256"
)

echo "archive=$archive"
echo "checksum=$checksum"
