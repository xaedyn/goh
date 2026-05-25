#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: Scripts/dogfood-build.sh [--artifacts] [--clean] [--version <version>]

Builds a local debug dogfood install under .build/dogfood/current.

Options:
  --artifacts          Also build and verify unsigned release tarball and PKG.
  --clean              Remove the staged dogfood install before rebuilding.
  --version <version>  Version string for optional release artifacts.
USAGE
}

build_artifacts=false
clean=false
version="${GOH_DOGFOOD_VERSION:-dogfood-local}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts)
      build_artifacts=true
      shift
      ;;
    --clean)
      clean=true
      shift
      ;;
    --version)
      if [[ $# -lt 2 ]]; then
        echo "--version requires a value" >&2
        exit 64
      fi
      version="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [[ ! "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "version may contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
dogfood_root="$repo_root/.build/dogfood"
install_root="$dogfood_root/install/debug"
current_link="$dogfood_root/current"
artifact_dir="$dogfood_root/artifacts"

if [[ "$clean" == true ]]; then
  rm -rf "$install_root" "$current_link"
fi

swift build --package-path "$repo_root" --configuration debug --disable-sandbox

mkdir -p "$install_root/bin" "$install_root/Resources" "$dogfood_root/downloads"
install -m 0755 "$repo_root/.build/debug/goh" "$install_root/bin/goh"
install -m 0755 "$repo_root/.build/debug/gohd" "$install_root/bin/gohd"
install -m 0644 "$repo_root/Resources/dev.goh.daemon.plist" \
  "$install_root/Resources/dev.goh.daemon.plist"
install -m 0644 "$repo_root/LICENSE" "$install_root/LICENSE"
install -m 0644 "$repo_root/README.md" "$install_root/README.md"

ln -sfn "$install_root" "$current_link"

if [[ "$build_artifacts" == true ]]; then
  mkdir -p "$artifact_dir"
  "$repo_root/Scripts/package-release.sh" "$version" "$artifact_dir"
  "$repo_root/Scripts/verify-release-artifact.sh" \
    "$artifact_dir/goh-${version}-macos-arm64.tar.gz"
  "$repo_root/Scripts/package-pkg.sh" "$version" "$artifact_dir"
  "$repo_root/Scripts/verify-pkg-artifact.sh" \
    "$artifact_dir/goh-${version}-macos-arm64.pkg"
fi

cat <<EOF
dogfood_install=$install_root
dogfood_current=$current_link
dogfood_bin=$current_link/bin

Next:
  Scripts/dogfood-install.sh
  Scripts/dogfood-smoke.sh

Manual shell:
  export PATH="$current_link/bin:\$PATH"
  export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1
EOF

