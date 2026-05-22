#!/usr/bin/env bash
#
# competitive.sh — goh vs aria2c vs curl, median wall-clock over N runs.
#
# Slice 3b's competitive benchmark. Runs each tool on each workload N times and
# reports the median wall-clock. Run it on a real network; record the machine
# specs, the network conditions, and the raw output in the PR.
#
#   swift build -c release
#   ./Benchmarks/competitive.sh                       # committed default workloads
#   AMENABLE_URL=<url> SATURATED_URL=<url> ./Benchmarks/competitive.sh   # override
#
# Targets (see Benchmarks/README.md):
#   amenable workload  — goh beats curl decisively, beats aria2c by >= 10%
#   saturated workload — goh within noise of aria2c and curl (parity)

set -euo pipefail

RUNS="${RUNS:-3}"
CONNECTIONS="${CONNECTIONS:-8}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/.build/release/goh-bench"

# Default workloads — see Benchmarks/README.md for the rationale and the ranked
# fallback candidates. The amenable default is a researched candidate, not a
# guaranteed-amenable URL; the amenability check below validates it each run.
AMENABLE_URL="${AMENABLE_URL:-https://archive.org/download/his_girl_friday/his_girl_friday.mp4}"
SATURATED_URL="${SATURATED_URL:-https://dl.google.com/android/repository/android-ndk-r27c-linux.zip}"

[[ -x "$BENCH" ]] || { echo "build first: swift build -c release" >&2; exit 1; }
command -v aria2c >/dev/null || { echo "missing: aria2c (brew install aria2)" >&2; exit 1; }
command -v curl   >/dev/null || { echo "missing: curl" >&2; exit 1; }

now()     { perl -MTime::HiRes -e 'printf "%.6f\n", Time::HiRes::time()'; }
elapsed() { perl -e "printf \"%.3f\n\", $2 - $1"; }
median()  { sort -n | awk '{ a[NR]=$1 } END { print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2 }'; }

run_goh()  { "$BENCH" download "$1" "$2" "$CONNECTIONS" >/dev/null; }
run_aria() {
  aria2c -x"$CONNECTIONS" -s"$CONNECTIONS" --allow-overwrite=true \
    --console-log-level=error --summary-interval=0 \
    -d "$(dirname "$2")" -o "$(basename "$2")" "$1" >/dev/null
}
run_curl() { curl -sS -o "$2" "$1"; }

# bench <label> <run-function> <url> — prints the runs, sets LAST_MEDIAN.
LAST_MEDIAN=""
bench() {
  local label="$1" runfn="$2" url="$3"
  local times=()
  for ((i = 1; i <= RUNS; i++)); do
    local dir dest start end seconds
    dir="$(mktemp -d)"; dest="$dir/download.bin"
    start="$(now)"; "$runfn" "$url" "$dest"; end="$(now)"
    seconds="$(elapsed "$start" "$end")"
    times+=("$seconds")
    rm -rf "$dir"
    printf '  %-7s run %d  %ss\n' "$label" "$i" "$seconds"
  done
  LAST_MEDIAN="$(printf '%s\n' "${times[@]}" | median)"
  printf '  %-7s median  %ss\n\n' "$label" "$LAST_MEDIAN"
}

# workload <name> <url>
workload() {
  local name="$1" url="$2"
  [[ -n "$url" ]] || { echo "skipping $name workload — URL not set"; echo; return; }
  echo "=== $name workload — $RUNS runs, $CONNECTIONS connections ==="
  echo "$url"
  bench goh    run_goh  "$url"
  bench aria2c run_aria "$url"; local aria_median="$LAST_MEDIAN"
  bench curl   run_curl "$url"; local curl_median="$LAST_MEDIAN"

  # Each workload's structural assumption is verified at run time, not assumed.
  # Both compare 8-connection aria2c — a mature parallel downloader, the
  # reference — against single-stream curl, so the check measures the workload,
  # not goh. The full-precision division drives the threshold; the rounded
  # `ratio` is for display only.
  if [[ "$name" == "amenable" || "$name" == "saturated" ]]; then
    local division ratio
    division="$curl_median / ($aria_median > 0 ? $aria_median : 1)"
    ratio="$(perl -e "printf '%.2f', $division")"
    if [[ "$name" == "amenable" ]]; then
      # Per-connection limiting → 8 connections clearly beat one. aria2c must be
      # >= 1.5x single-stream curl, or the >= 10% target is measured wrong.
      if perl -e "exit(!($division >= 1.5))"; then
        echo "  amenability check: PASS — aria2c ${ratio}x single-stream curl"
      else
        echo "  amenability check: WARN — aria2c only ${ratio}x single-stream curl."
        echo "  This URL is not clearly per-connection-limited; the >= 10% comparison"
        echo "  is not valid against it. Pick another AMENABLE_URL — see README."
      fi
    else
      # One connection already saturates → 8 add nothing. aria2c must stay
      # within ~20% of single-stream curl (ratio <= 1.2); clearly faster means
      # the link was not saturated and the parity target is meaningless.
      if perl -e "exit(!($division <= 1.2))"; then
        echo "  saturation check: PASS — aria2c ${ratio}x single-stream curl (converged)"
      else
        echo "  saturation check: WARN — aria2c ${ratio}x single-stream curl."
        echo "  This URL does not fill the pipe on one connection; the parity"
        echo "  comparison is not valid against it. Pick another SATURATED_URL —"
        echo "  see README."
      fi
    fi
    echo
  fi
}

echo "goh competitive benchmark — $(date)"
echo "machine: $(uname -mrs)"
echo
workload amenable  "$AMENABLE_URL"
workload saturated "$SATURATED_URL"
