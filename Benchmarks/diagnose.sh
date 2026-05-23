#!/usr/bin/env bash
#
# diagnose.sh — one goh download with engine diagnostics enabled.
#
# Writes the wall-clock result to stdout and a timestamped per-range trace to
# stderr. Pipe both to a file (`./Benchmarks/diagnose.sh 2>&1 | tee trace.log`)
# and paste into PR #14.
#
#   swift build -c release
#   ./Benchmarks/diagnose.sh                          # the saturated default
#   ./Benchmarks/diagnose.sh <url>                    # override the URL
#   CONNECTIONS=4 ./Benchmarks/diagnose.sh            # override the count

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/.build/release/goh-bench"
URL="${1:-https://dl.google.com/android/repository/android-ndk-r27c-linux.zip}"
CONNECTIONS="${CONNECTIONS:-8}"

[[ -x "$BENCH" ]] || { echo "build first: swift build -c release" >&2; exit 1; }

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

{
  echo "goh diagnostic run — $(date)"
  echo "machine:     $(uname -mrs)"
  echo "url:         $URL"
  echo "connections: $CONNECTIONS"
  echo
} >&2

GOH_ENGINE_TRACE=1 "$BENCH" download "$URL" "$dir/download.bin" "$CONNECTIONS"
