#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/verify-release-artifact.sh <archive.tar.gz> [archive.tar.gz.sha256]" >&2
  exit 64
fi

archive="$1"
checksum="${2:-${archive}.sha256}"

if [[ ! -f "$archive" ]]; then
  echo "archive not found: $archive" >&2
  exit 66
fi

if [[ ! -f "$checksum" ]]; then
  echo "checksum not found: $checksum" >&2
  exit 66
fi

archive_dir="$(cd "$(dirname "$archive")" && pwd -P)"
archive_name="$(basename "$archive")"
checksum_dir="$(cd "$(dirname "$checksum")" && pwd -P)"
checksum_name="$(basename "$checksum")"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/goh-release-verify.XXXXXX")"

cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT

(
  cd "$checksum_dir"
  shasum -a 256 -c "$checksum_name"
)

tar -xzf "$archive_dir/$archive_name" -C "$temp_dir"

roots=()
while IFS= read -r root_entry; do
  roots+=("$root_entry")
done < <(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | sort)
if [[ ${#roots[@]} -ne 1 ]]; then
  echo "archive should contain exactly one top-level directory" >&2
  exit 65
fi

root="${roots[0]}"

required_files=(
  "$root/LICENSE"
  "$root/README.md"
  "$root/Resources/dev.goh.daemon.plist"
)

for path in "${required_files[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "missing packaged file: ${path#$root/}" >&2
    exit 65
  fi
done

for binary in "$root/bin/goh" "$root/bin/gohd"; do
  if [[ ! -x "$binary" ]]; then
    echo "missing executable binary: ${binary#$root/}" >&2
    exit 65
  fi
done

plutil -lint "$root/Resources/dev.goh.daemon.plist" >/dev/null
"$root/bin/goh" --help >/dev/null

echo "verified=$archive_dir/$archive_name"
