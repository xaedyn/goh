#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: Scripts/dogfood-smoke.sh [--url <url>] [--timeout <seconds>]

Runs a real launchd/XPC smoke test against the local dogfood daemon.
USAGE
}

url="${GOH_DOGFOOD_URL:-https://example.com/}"
timeout="${GOH_DOGFOOD_TIMEOUT:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      if [[ $# -lt 2 ]]; then
        echo "--url requires a value" >&2
        exit 64
      fi
      url="$2"
      shift 2
      ;;
    --timeout)
      if [[ $# -lt 2 ]]; then
        echo "--timeout requires a value" >&2
        exit 64
      fi
      timeout="$2"
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

case "$timeout" in
  ''|*[!0-9]*)
    echo "timeout must be a positive integer" >&2
    exit 64
    ;;
esac
if (( timeout < 1 )); then
  echo "timeout must be a positive integer" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
dogfood_root="$repo_root/.build/dogfood"
install_path="$dogfood_root/current"
downloads_dir="$dogfood_root/downloads"
log_path="$dogfood_root/logs/goh.log"
goh="$install_path/bin/goh"
service_name="dev.goh.daemon"

if [[ ! -x "$goh" ]]; then
  echo "dogfood goh not found: $goh" >&2
  echo "run: Scripts/dogfood-build.sh" >&2
  exit 66
fi

goh_dev() {
  GOH_XPC_ALLOW_UNVALIDATED_PEERS=1 "$goh" "$@"
}

mkdir -p "$downloads_dir" "$dogfood_root/logs"

# Smoke path intentionally exercises `goh ls`, `goh doctor`, and `goh add`
# over real XPC.
if ! goh_dev ls >/dev/null 2>&1; then
  "$repo_root/Scripts/dogfood-install.sh" "$install_path"
fi

doctor_output="$(goh_dev doctor 2>&1)" || {
  echo "dogfood doctor failed before smoke download" >&2
  printf '%s\n' "$doctor_output" >&2
  exit 1
}

dest="$downloads_dir/smoke-$(date -u +%Y%m%d%H%M%S)-$$.download"
add_output="$(goh_dev add --output "$dest" --connections 1 --no-cookies "$url")"
printf '%s\n' "$add_output"

job_id="$(awk '/^Added job / { print $3; exit }' <<<"$add_output")"
if [[ -z "$job_id" || ! "$job_id" =~ ^[0-9]+$ ]]; then
  echo "could not parse job id from add output" >&2
  exit 65
fi

deadline=$((SECONDS + timeout))
last_listing=""
seen_job=false

while (( SECONDS <= deadline )); do
  last_listing="$(goh_dev ls || true)"
  job_line="$(awk -v id="$job_id" '$1 == id { print; exit }' <<<"$last_listing")"

  if [[ -z "$job_line" ]]; then
    if [[ "$seen_job" == true ]]; then
      echo "dogfood smoke failed: job $job_id disappeared from goh ls" >&2
      echo "--- goh ls ---" >&2
      printf '%s\n' "$last_listing" >&2
      exit 1
    fi
    sleep 1
    continue
  fi
  seen_job=true

  if [[ "$job_line" == *"completed"* ]]; then
    if [[ ! -s "$dest" ]]; then
      echo "job completed but destination is missing or empty: $dest" >&2
      exit 65
    fi
    goh_dev rm --keep "$job_id" >/dev/null || true
    echo "dogfood smoke passed: job $job_id completed -> $dest"
    exit 0
  fi

  if [[ "$job_line" == *"failed"* ]]; then
    echo "dogfood smoke failed: job $job_id failed" >&2
    echo "--- goh ls ---" >&2
    printf '%s\n' "$last_listing" >&2
    if [[ -s "$log_path" ]]; then
      echo "--- gohd log tail ---" >&2
      tail -40 "$log_path" >&2
    fi
    exit 1
  fi

  sleep 1
done

echo "dogfood smoke timed out waiting for $service_name job $job_id" >&2
echo "--- goh ls ---" >&2
printf '%s\n' "$last_listing" >&2
if [[ -s "$log_path" ]]; then
  echo "--- gohd log tail ---" >&2
  tail -40 "$log_path" >&2
fi
exit 69
