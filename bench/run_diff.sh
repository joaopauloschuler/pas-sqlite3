#!/usr/bin/env bash
# Phase 11.6 — wrapper for bin/SpeedtestDiff.
#
# Runs the pas vs C speedtest1 differential and exits 0/1 with PASS/FAIL.
#
# Forwards any args after the first non-option to speedtest1 (both runs);
# default = "--testset main --size 1".
#
# Requires:
#   * bin/passpeedtest1                        (build with src/bench/build.sh)
#   * ../sqlite3/speedtest1                    (C oracle, see SpeedtestDiff.pas)
#   * src/libsqlite3.so                        (only for the pas binary's vfs/etc.)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN="$ROOT_DIR/bin/SpeedtestDiff"

if [ ! -x "$BIN" ]; then
  echo "ERROR: $BIN missing.  Run src/bench/build.sh first."
  exit 1
fi

if [ "$#" -eq 0 ]; then
  set -- --testset main --size 1
fi

set +e
"$BIN" "$@"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  echo "run_diff: PASS"
else
  echo "run_diff: FAIL (rc=$rc)"
fi
exit $rc
