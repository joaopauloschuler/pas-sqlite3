#!/usr/bin/env bash
# profile_callgrind.sh — Phase 11.9 profiling wrapper.
#
# Runs bin/passpeedtest1 under `valgrind --tool=callgrind`.  Callgrind
# emulates each instruction so it is ~50x slower than native: always
# use --size 1 unless you want a coffee break.
#
# Requires: valgrind.  Harness must be built with DWARF (`-gl -gw3`);
# src/bench/build.sh does this as of 11.9.
#
# Env-var overrides:
#   PROFILE_SIZE      default 1
#   PROFILE_TESTSET   default main
#
# Output: bench/callgrind.out  (machine-readable; feed to
# bin/AnnotateProfile or visualise with kcachegrind).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT_DIR/bin/passpeedtest1"
SRC_DIR="$ROOT_DIR/src"
OUT="$SCRIPT_DIR/callgrind.out"

if ! command -v valgrind >/dev/null 2>&1; then
  echo "ERROR: 'valgrind' not found in PATH."
  echo "       Install: apt install valgrind"
  exit 1
fi

if [ ! -x "$BIN" ]; then
  echo "ERROR: $BIN missing. Run src/bench/build.sh first."
  exit 1
fi

SIZE="${PROFILE_SIZE:-1}"
TESTSET="${PROFILE_TESTSET:-main}"

echo "Recording callgrind trace: --testset $TESTSET --size $SIZE ..."
echo "(this will take several minutes; callgrind ~= 50x native slowdown)"
rm -f "$OUT"

LD_LIBRARY_PATH="$SRC_DIR" \
  valgrind --tool=callgrind --callgrind-out-file="$OUT" \
    "$BIN" --testset "$TESTSET" --size "$SIZE"

echo "Done. Output -> $OUT"
echo "Annotate with: $ROOT_DIR/bin/AnnotateProfile $OUT"
echo "Visualise with: kcachegrind $OUT"
