#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: Scripts/dogfood-acceptance.sh [--timeout <seconds>] [--control-url <url>] [--performance]

Runs the private local readiness gate for dogfood builds:
  - build, install, doctor, and smoke through real launchd/XPC
  - foreground download behavior
  - JSON listing behavior
  - pause/resume/rm cleanup on a larger active download
  - daemon restart reachability

Options:
  --timeout <seconds>  Per-step wait timeout. Default: 90.
  --control-url <url>  Large URL used for pause/resume/rm. Default: Ubuntu ISO.
  --performance        Also run Benchmarks/competitive.sh. This uses live network.
USAGE
}

timeout="${GOH_ACCEPTANCE_TIMEOUT:-90}"
control_url="${GOH_ACCEPTANCE_CONTROL_URL:-https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso}"
run_performance=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      if [[ $# -lt 2 ]]; then
        echo "--timeout requires a value" >&2
        exit 64
      fi
      timeout="$2"
      shift 2
      ;;
    --control-url)
      if [[ $# -lt 2 ]]; then
        echo "--control-url requires a value" >&2
        exit 64
      fi
      control_url="$2"
      shift 2
      ;;
    --performance)
      run_performance=true
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
logs_dir="$dogfood_root/logs"
log_path="$logs_dir/goh.log"
goh="$install_path/bin/goh"
service_name="dev.goh.daemon"
service_target="gui/$(id -u)/$service_name"
run_id="$(date -u +%Y%m%d%H%M%S)-$$"

warnings=0
smoke_dest=""
control_job_id=""
control_dest=""
foreground_job_id=""
foreground_dest=""

ok() {
  printf '[ok] %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf '[warn] %s\n' "$1"
  if [[ $# -gt 1 && -n "$2" ]]; then
    printf '       %s\n' "$2"
  fi
}

fail() {
  printf '[fail] %s\n' "$1" >&2
  if [[ $# -gt 1 && -n "$2" ]]; then
    printf '%s\n' "$2" >&2
  fi
  exit 1
}

run_capture() {
  local label="$1"
  shift
  local output

  printf '[..] %s\n' "$label"
  if output="$("$@" 2>&1)"; then
    ok "$label"
  else
    fail "$label" "$output"
  fi
}

goh_dev() {
  GOH_XPC_ALLOW_UNVALIDATED_PEERS=1 "$goh" "$@"
}

job_line_for_id() {
  local job_id="$1"
  awk -v id="$job_id" '$1 == id { print; exit }'
}

job_state_for_id() {
  local job_id="$1"
  awk -v id="$job_id" '$1 == id { print $2; exit }'
}

cleanup() {
  set +e
  if [[ -n "$control_job_id" && -x "$goh" ]]; then
    goh_dev rm "$control_job_id" >/dev/null 2>&1
  fi
  if [[ -n "$foreground_job_id" && -x "$goh" ]]; then
    goh_dev rm --keep "$foreground_job_id" >/dev/null 2>&1
  fi
  if [[ -n "$control_dest" && "$control_dest" == "$downloads_dir"/acceptance-control-* ]]; then
    rm -f "$control_dest"
  fi
  if [[ -n "$smoke_dest" && "$smoke_dest" == "$downloads_dir"/smoke-* ]]; then
    rm -f "$smoke_dest"
  fi
  if [[ -n "$foreground_dest" && "$foreground_dest" == "$HOME"/Downloads/goh-acceptance-* ]]; then
    rm -f "$foreground_dest"
  fi
}
trap cleanup EXIT

wait_for_job_state() {
  local job_id="$1"
  local expected="$2"
  local deadline=$((SECONDS + timeout))
  local listing line state

  while (( SECONDS <= deadline )); do
    listing="$(goh_dev ls || true)"
    line="$(job_line_for_id "$job_id" <<<"$listing")"
    state="$(job_state_for_id "$job_id" <<<"$listing")"
    if [[ "$state" == "$expected" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
    sleep 0.25
  done

  return 1
}

wait_for_job_not_paused() {
  local job_id="$1"
  local deadline=$((SECONDS + timeout))
  local listing line state

  while (( SECONDS <= deadline )); do
    listing="$(goh_dev ls || true)"
    line="$(job_line_for_id "$job_id" <<<"$listing")"
    state="$(job_state_for_id "$job_id" <<<"$listing")"
    case "$state" in
      queued|active)
        printf '%s\n' "$line"
        return 0
        ;;
      completed)
        fail "goh resume" "Control download completed before cleanup; use a slower or larger --control-url."
        ;;
    esac
    sleep 0.25
  done

  return 1
}

wait_for_job_absent() {
  local job_id="$1"
  local deadline=$((SECONDS + timeout))
  local listing line

  while (( SECONDS <= deadline )); do
    listing="$(goh_dev ls || true)"
    line="$(job_line_for_id "$job_id" <<<"$listing")"
    if [[ -z "$line" ]]; then
      return 0
    fi
    sleep 0.25
  done

  return 1
}

wait_for_job_active() {
  local job_id="$1"
  local deadline=$((SECONDS + timeout))
  local listing line state

  while (( SECONDS <= deadline )); do
    listing="$(goh_dev ls || true)"
    line="$(job_line_for_id "$job_id" <<<"$listing")"
    state="$(job_state_for_id "$job_id" <<<"$listing")"
    case "$state" in
      active)
        printf '%s\n' "$line"
        return 0
        ;;
      completed)
        fail "goh pause" "Control download completed before it could be paused; use a slower or larger --control-url."
        ;;
      failed)
        fail "goh pause" "Control download failed before it could be paused: $line"
        ;;
    esac
    sleep 0.25
  done

  return 1
}

echo "Get over here!"
echo
echo "Private dogfood acceptance"
echo

mkdir -p "$downloads_dir" "$logs_dir"

run_capture "dogfood build" "$repo_root/Scripts/dogfood-build.sh"
run_capture "dogfood install" "$repo_root/Scripts/dogfood-install.sh"
run_capture "goh doctor" goh_dev doctor

printf '[..] dogfood-smoke.sh\n'
if smoke_output="$("$repo_root/Scripts/dogfood-smoke.sh" --timeout "$timeout" 2>&1)"; then
  ok "dogfood-smoke.sh"
else
  fail "dogfood-smoke.sh" "$smoke_output"
fi
smoke_dest="$(awk -F' -> ' '/^dogfood smoke passed:/ { print $2; exit }' <<<"$smoke_output")"
if [[ -n "$smoke_dest" && "$smoke_dest" == "$downloads_dir"/smoke-* ]]; then
  rm -f "$smoke_dest"
  smoke_dest=""
  ok "dogfood smoke cleanup"
fi

json_output="$(goh_dev ls --json 2>&1)" || fail "goh ls --json" "$json_output"
if grep -F '"jobs"' <<<"$json_output" >/dev/null; then
  ok "goh ls --json"
else
  fail "goh ls --json" "$json_output"
fi

foreground_name="goh-acceptance-$run_id"
foreground_url="https://httpbin.org/anything/$foreground_name"
foreground_dest="$HOME/Downloads/$foreground_name"
if [[ -e "$foreground_dest" ]]; then
  fail "foreground safety" "Refusing to touch pre-existing file: $foreground_dest"
fi

run_capture "foreground goh <url>" goh_dev "$foreground_url"
if [[ ! -s "$foreground_dest" ]]; then
  fail "foreground destination" "Foreground download did not create a non-empty file: $foreground_dest"
fi

foreground_listing="$(goh_dev ls || true)"
foreground_job_id="$(awk -v dest="$foreground_dest" 'index($0, dest) { print $1; exit }' <<<"$foreground_listing")"
if [[ -n "$foreground_job_id" && "$foreground_job_id" =~ ^[0-9]+$ ]]; then
  goh_dev rm --keep "$foreground_job_id" >/dev/null || true
  foreground_job_id=""
fi
rm -f "$foreground_dest"
foreground_dest=""
ok "foreground cleanup"

control_dest="$downloads_dir/acceptance-control-$run_id.download"
rm -f "$control_dest"
add_output="$(goh_dev add --output "$control_dest" --connections 1 --no-cookies "$control_url" 2>&1)" \
  || fail "goh add control download" "$add_output"
control_job_id="$(awk '/^Added job / { print $3; exit }' <<<"$add_output")"
if [[ -z "$control_job_id" || ! "$control_job_id" =~ ^[0-9]+$ ]]; then
  fail "goh add control download" "Could not parse job id from: $add_output"
fi
ok "goh add control download"

if ! wait_for_job_active "$control_job_id" >/dev/null; then
  fail "goh pause" "Timed out waiting for job $control_job_id to become active."
fi

pause_output="$(goh_dev pause "$control_job_id" 2>&1)" || fail "goh pause" "$pause_output"
if wait_for_job_state "$control_job_id" paused >/dev/null; then
  ok "goh pause"
else
  fail "goh pause" "Timed out waiting for job $control_job_id to enter paused state."
fi

resume_output="$(goh_dev resume "$control_job_id" 2>&1)" || fail "goh resume" "$resume_output"
if wait_for_job_not_paused "$control_job_id" >/dev/null; then
  ok "goh resume"
else
  fail "goh resume" "Timed out waiting for job $control_job_id to leave paused state."
fi

rm_output="$(goh_dev rm "$control_job_id" 2>&1)" || fail "goh rm" "$rm_output"
if ! wait_for_job_absent "$control_job_id"; then
  fail "goh rm" "Timed out waiting for job $control_job_id to leave the queue."
fi
control_job_id=""
if [[ -e "$control_dest" ]]; then
  fail "goh rm active cleanup" "Active rm left a partial file behind: $control_dest"
fi
ok "goh rm active cleanup"

if command -v lsof >/dev/null; then
  if lsof -c gohd 2>/dev/null | grep -F -- "$control_dest" >/dev/null; then
    fail "goh rm file handles" "gohd still has the removed destination open: $control_dest"
  fi
  ok "goh rm file handles"
else
  warn "goh rm file handles skipped" "lsof is not available on this machine."
fi
control_dest=""

run_capture "launchctl kickstart daemon" launchctl kickstart -k "$service_target"
run_capture "goh doctor after restart" goh_dev doctor

if [[ "$run_performance" == true ]]; then
  command -v aria2c >/dev/null || fail "Benchmarks/competitive.sh" "Missing aria2c. Run: brew install aria2"
  command -v curl >/dev/null || fail "Benchmarks/competitive.sh" "Missing curl."
  run_capture "release build for performance" swift build --package-path "$repo_root" --configuration release --disable-sandbox
  performance_log="$logs_dir/acceptance-performance-$run_id.log"
  printf '[..] Benchmarks/competitive.sh\n'
  if (
    cd "$repo_root"
    RUNS="${GOH_ACCEPTANCE_PERF_RUNS:-1}" Benchmarks/competitive.sh 2>&1 \
      | tee "$performance_log"
  ); then
    ok "Benchmarks/competitive.sh"
    printf '     Performance log: %s\n' "$performance_log"
    if grep -F "WARN" "$performance_log" >/dev/null; then
      warn "competitive benchmark emitted WARN lines" "Inspect the benchmark output before treating performance as accepted."
    fi
  else
    fail "Benchmarks/competitive.sh" "Benchmark failed. Performance log: $performance_log"
  fi
else
  warn "performance comparison skipped" "Run: GOH_ACCEPTANCE_PERF_RUNS=1 Scripts/dogfood-acceptance.sh --performance"
fi

echo
if (( warnings > 0 )); then
  echo "Private dogfood acceptance passed with $warnings warning(s)."
else
  echo "Private dogfood acceptance passed."
fi
