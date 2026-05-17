#!/usr/bin/env bash
# profile_perf.sh — Phase 11.9 profiling wrapper.
#
# Runs bin/passpeedtest1 under `perf record -g -F 999`, then dumps a
# text report to bench/perf_report.txt.  Output is the input to
# bin/AnnotateProfile (see src/bench/AnnotateProfile.pas) and
# ultimately feeds Phase 12.1 hot-function selection.
#
# Requires: linux-perf-tools (`apt install linux-tools-common
# linux-tools-generic` or distro equivalent).  The harness must be
# built with DWARF (`-gl -gw3`); src/bench/build.sh adds these flags
# unconditionally as of 11.9.
#
# Env-var overrides:
#   PROFILE_SIZE      default 5  (--size N passed to passpeedtest1)
#   PROFILE_TESTSET   default main
#
# Note: Agent 7 reported `--testset main --size 5` may hit
# SQLITE_CORRUPT on the current engine.  If perf-record returns
# non-zero we fall back to --size 1 and document.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"           # pas-sqlite3/bench/
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"              # pas-sqlite3/
BIN="$ROOT_DIR/bin/passpeedtest1"
SRC_DIR="$ROOT_DIR/src"
PERF_DATA="$SCRIPT_DIR/perf.data"
PERF_REPORT="$SCRIPT_DIR/perf_report.txt"

if ! command -v perf >/dev/null 2>&1; then
  echo "ERROR: 'perf' not found in PATH."
  echo "       Install: apt install linux-tools-common linux-tools-\$(uname -r) linux-tools-generic"
  exit 1
fi

if [ ! -x "$BIN" ]; then
  echo "ERROR: $BIN missing. Run src/bench/build.sh first."
  exit 1
fi

SIZE="${PROFILE_SIZE:-5}"
TESTSET="${PROFILE_TESTSET:-main}"

run_perf() {
  local sz="$1"
  echo "Recording perf trace: --testset $TESTSET --size $sz ..."
  rm -f "$PERF_DATA"
  LD_LIBRARY_PATH="$SRC_DIR" \
    perf record -g -F 999 -o "$PERF_DATA" -- \
      "$BIN" --testset "$TESTSET" --size "$sz"
}

if ! run_perf "$SIZE"; then
  if [ "$SIZE" != "1" ]; then
    echo "WARN: perf-record failed at --size $SIZE (likely SQLITE_CORRUPT; see Agent 7 note)."
    echo "      Falling back to --size 1."
    SIZE=1
    run_perf 1
  else
    echo "ERROR: perf-record failed even at --size 1."
    exit 1
  fi
fi

echo "Writing report -> $PERF_REPORT"
perf report -i "$PERF_DATA" --stdio > "$PERF_REPORT"

echo "Done.  Annotate with: $ROOT_DIR/bin/AnnotateProfile $PERF_REPORT"
