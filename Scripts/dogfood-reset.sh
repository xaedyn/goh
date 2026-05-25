#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: Scripts/dogfood-reset.sh [--data] [--artifacts] [--all]

Stops the marked local dogfood LaunchAgent and removes dogfood-owned files.

Options:
  --data       Also delete ~/Library/Application Support/dev.goh.daemon.
  --artifacts  Also delete .build/dogfood build artifacts.
  --all        Equivalent to --data --artifacts.
USAGE
}

remove_data=false
remove_artifacts=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data)
      remove_data=true
      shift
      ;;
    --artifacts)
      remove_artifacts=true
      shift
      ;;
    --all)
      remove_data=true
      remove_artifacts=true
      shift
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
dogfood_root="$repo_root/.build/dogfood"
service_name="dev.goh.daemon"
uid="$(id -u)"
launch_domain="gui/$uid"
launch_agent="$HOME/Library/LaunchAgents/$service_name.plist"
support_dir="$HOME/Library/Application Support/$service_name"
marker="goh dogfood local LaunchAgent"

is_dogfood_plist() {
  [[ -f "$launch_agent" ]] \
    && grep -F "$marker" "$launch_agent" >/dev/null \
    && grep -F ".build/dogfood" "$launch_agent" >/dev/null
}

if [[ -f "$launch_agent" ]]; then
  if ! is_dogfood_plist; then
    echo "refusing to remove non-dogfood LaunchAgent: $launch_agent" >&2
    exit 73
  fi

  launchctl bootout "$launch_domain" "$launch_agent" >/dev/null 2>&1 || true
  rm -f "$launch_agent"
fi

if [[ "$remove_data" == true ]]; then
  if [[ -d "$support_dir" ]]; then
    rm -rf "$support_dir"
  fi
fi

if [[ "$remove_artifacts" == true ]]; then
  rm -rf "$dogfood_root"
else
  rm -rf "$dogfood_root/logs" "$dogfood_root/run"
fi

cat <<EOF
dogfood_reset=ok
dogfood_service=$launch_domain/$service_name
removed_data=$remove_data
removed_artifacts=$remove_artifacts
EOF

