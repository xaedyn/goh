#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

require_file() {
  local path="$1"
  if [[ ! -f "$repo_root/$path" ]]; then
    echo "missing required file: $path" >&2
    exit 65
  fi
}

require_executable() {
  local path="$1"
  require_file "$path"
  if [[ ! -x "$repo_root/$path" ]]; then
    echo "script is not executable: $path" >&2
    exit 65
  fi
}

require_text() {
  local path="$1"
  local needle="$2"
  if ! grep -F -- "$needle" "$repo_root/$path" >/dev/null; then
    echo "expected '$needle' in $path" >&2
    exit 65
  fi
}

require_match() {
  local path="$1"
  local pattern="$2"
  if ! grep -E -- "$pattern" "$repo_root/$path" >/dev/null; then
    echo "expected pattern '$pattern' in $path" >&2
    exit 65
  fi
}

require_executable "Scripts/dogfood-build.sh"
require_executable "Scripts/dogfood-install.sh"
require_executable "Scripts/dogfood-smoke.sh"
require_executable "Scripts/dogfood-reset.sh"
require_file "DOGFOOD.md"

for script in \
  Scripts/dogfood-build.sh \
  Scripts/dogfood-install.sh \
  Scripts/dogfood-smoke.sh \
  Scripts/dogfood-reset.sh
do
  bash -n "$repo_root/$script"
  require_text "$script" ".build/dogfood"
  require_text "$script" "dev.goh.daemon"
done

require_text "Scripts/dogfood-build.sh" "swift build"
require_text "Scripts/dogfood-build.sh" "--configuration debug"
require_text "Scripts/dogfood-build.sh" "--artifacts"
require_text "Scripts/dogfood-install.sh" "GOH_XPC_ALLOW_UNVALIDATED_PEERS"
require_text "Scripts/dogfood-install.sh" "launchctl bootstrap"
require_text "Scripts/dogfood-install.sh" "launchctl bootout"
require_text "Scripts/dogfood-install.sh" "refusing to overwrite"
require_text "Scripts/dogfood-smoke.sh" "GOH_XPC_ALLOW_UNVALIDATED_PEERS"
require_text "Scripts/dogfood-smoke.sh" "goh ls"
require_match "Scripts/dogfood-smoke.sh" '^[[:space:]]*doctor_output="\$\(goh_dev[[:space:]]+doctor[[:space:]]+2>&1\)'
require_text "Scripts/dogfood-smoke.sh" "goh add"
require_text "Scripts/dogfood-reset.sh" "--data"
require_text "Scripts/dogfood-reset.sh" "refusing to remove"

require_text "DOGFOOD.md" "local debug build"
require_text "DOGFOOD.md" "GOH_XPC_ALLOW_UNVALIDATED_PEERS"
require_text "DOGFOOD.md" "Scripts/dogfood-build.sh"
require_text "DOGFOOD.md" "Scripts/dogfood-install.sh"
require_text "DOGFOOD.md" "Scripts/dogfood-smoke.sh"
require_text "DOGFOOD.md" "Scripts/dogfood-reset.sh"
require_text "DOGFOOD.md" "Application Support/dev.goh.daemon"

require_text ".github/workflows/ci.yml" "Validate dogfood kit"

echo "dogfood kit verified"
