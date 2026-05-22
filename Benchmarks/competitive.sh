#!/usr/bin/env bash
#
# competitive.sh — goh vs aria2c vs curl, median wall-clock over N runs.
#
# Slice 3b's competitive benchmark. Runs each tool on each workload N times and
# reports the median wall-clock. Run it on a real network; record the machine
# specs, the network conditions, and the raw output in the PR.
#
#   swift build -c release
#   AMENABLE_URL=<url> SATURATED_URL=<url> ./Benchmarks/competitive.sh
#
# Targets (see Benchmarks/README.md):
#   amenable workload  — goh beats curl decisively, beats aria2c by >= 10%
#   saturated workload — goh within noise of aria2c and curl (parity)

set -euo pipefail

RUNS="${RUNS:-3}"
CONNECTIONS="${CONNECTIONS:-8}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/.build/release/goh-bench"
AMENABLE_URL="${AMENABLE_URL:-}"
SATURATED_URL="${SATURATED_URL:-}"

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

# bench <label> <run-function> <url>
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
  printf '  %-7s median  %ss\n\n' "$label" "$(printf '%s\n' "${times[@]}" | median)"
}

# workload <name> <url>
workload() {
  local name="$1" url="$2"
  [[ -n "$url" ]] || { echo "skipping $name workload — URL not set"; echo; return; }
  echo "=== $name workload — $RUNS runs, $CONNECTIONS connections ==="
  echo "$url"
  bench goh    run_goh  "$url"
  bench aria2c run_aria "$url"
  bench curl   run_curl "$url"
}

echo "goh competitive benchmark — $(date)"
echo "machine: $(uname -mrs)"
echo
workload amenable  "$AMENABLE_URL"
workload saturated "$SATURATED_URL"
