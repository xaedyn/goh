#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
workflow="$repo_root/.github/workflows/release-artifacts.yml"
candidate_script="$repo_root/Scripts/private-release-candidate.sh"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "missing file: ${path#$repo_root/}" >&2
    exit 65
  fi
}

require_text() {
  local path="$1"
  local needle="$2"
  if ! grep -F -- "$needle" "$path" >/dev/null; then
    echo "missing ${path#$repo_root/} text: $needle" >&2
    exit 65
  fi
}

require_file "$workflow"
require_file "$candidate_script"

require_text "$workflow" "private_signed_pkg:"
require_text "$workflow" "type: boolean"
require_text "$workflow" "private-signed-pkg:"
require_text "$workflow" "github.event_name == 'workflow_dispatch' && inputs.private_signed_pkg"
require_text "$workflow" "DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64"
require_text "$workflow" "DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64"
require_text "$workflow" "APPLE_NOTARY_KEY_P8_BASE64"
require_text "$workflow" "DEVELOPER_ID_APPLICATION_IDENTITY"
require_text "$workflow" "DEVELOPER_ID_INSTALLER_IDENTITY"
require_text "$workflow" "Scripts/private-release-candidate.sh"
require_text "$workflow" "goh-\${{ steps.version.outputs.version }}-signed-macos-arm64"

require_text "$candidate_script" "security create-keychain"
require_text "$candidate_script" "security import"
require_text "$candidate_script" "security set-key-partition-list"
require_text "$candidate_script" 'codesign --force --sign "$GOH_APP_SIGN_IDENTITY" --options runtime --timestamp'
require_text "$candidate_script" "pkgbuild"
require_text "$candidate_script" "productbuild"
require_text "$candidate_script" '--sign "$GOH_INSTALLER_SIGN_IDENTITY"'
require_text "$candidate_script" "xcrun notarytool submit"
require_text "$candidate_script" "--timeout 30m"
require_text "$candidate_script" "notary_submit_status=0"
require_text "$candidate_script" "xcrun notarytool log"
require_text "$candidate_script" "xcrun stapler staple"
require_text "$candidate_script" "spctl -a -v --type install"
require_text "$candidate_script" "shasum -a 256"

echo "verified=$workflow"
