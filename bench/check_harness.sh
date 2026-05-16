#!/usr/bin/env bash
# Phase 11.1 — speedtest1 harness skeleton gate.
#
# Re-runs `bin/passpeedtest1 --testset main --size 1`, strips wall-clock
# numbers + the libversion line (which depends on the linked
# libsqlite3.so build hash), and diffs against bench/baseline/harness.txt.
#
# Exit 0 = identical, exit 1 = drift (next agent's gate to update).
#
# Phase 11.2+ extends this gate: when testset_main lands, re-baseline so
# the expected output includes the per-test "  1 - <name>........." lines
# (still stripped of wall-clock timings).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN="$ROOT_DIR/bin/passpeedtest1"
SRC="$ROOT_DIR/src"

if [ ! -x "$BIN" ]; then
  echo "ERROR: $BIN missing.  Run src/bench/build.sh first."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

set +e
LD_LIBRARY_PATH="$SRC" "$BIN" --testset main --size 1 "$TMP/st1.db" \
  > "$TMP/out.txt" 2> "$TMP/err.txt"
rc=$?
set -e

# Strip:
#   - the version banner line (libversion + sourceid drift)
#   - wall-clock seconds:    "  123.456s"  → "  TIME"
#   - "TOTAL ... XX.YYYs"
sed -E \
  -e '/^-- Speedtest1 for SQLite/d' \
  -e 's/[[:space:]]+[0-9]+\.[0-9]+s/  TIME/g' \
  "$TMP/out.txt" > "$TMP/out.stripped.txt"

# Append stderr (skeleton's "not yet ported" line is part of the gate).
cat "$TMP/err.txt" >> "$TMP/out.stripped.txt"
echo "rc=$rc" >> "$TMP/out.stripped.txt"

BASELINE="$SCRIPT_DIR/baseline/harness.txt"
if [ ! -f "$BASELINE" ]; then
  echo "No baseline at $BASELINE; capturing it now."
  mkdir -p "$(dirname "$BASELINE")"
  cp "$TMP/out.stripped.txt" "$BASELINE"
  echo "Baseline written.  Re-run to verify."
  exit 0
fi

if diff -u "$BASELINE" "$TMP/out.stripped.txt"; then
  echo "harness gate: PASS"
  exit 0
else
  echo "harness gate: FAIL — output drift vs $BASELINE"
  exit 1
fi
