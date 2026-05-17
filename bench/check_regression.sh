#!/usr/bin/env bash
# Phase 11.7 — wrapper for bin/CheckRegression.
#
# Re-runs the speedtest1 matrix recorded in bench/baseline.json and fails
# (exit 1) on any per-cell relative regression > REGRESSION_THRESHOLD_PCT.
#
# THRESHOLD CHOICE (11.7 re-pin, 2026-05-16)
# ------------------------------------------
# The baseline records ratios from --size 1 speedtest1 runs.  These workloads
# are very short (1-50ms per case) and the harness times them with 1ms-grained
# GetTickCount64.  Running the full matrix 9 times locally shows per-cell ratio
# swings of:
#       median max/min = 3.3x   (a typical cell varies 3x across runs)
#       75th pct max/min = 7.8x (a quarter of cells vary >7.8x)
# meaning a 10% gate at size=1 produces a stream of false positives — the
# previous threshold flagged 13-18 different cells on every consecutive run,
# with cells repeatedly flipping FAIL <-> BETTER.  See tasklist.md 11.7 for the
# full decision log.  At 200% the gate fires when a cell's ratio reaches 3x
# the max observed across the 9-run pinning window — a genuine perf regression
# worth opening as a Phase 12 sub-bug.
#
# If you upgrade the bench matrix to --size 5+ (longer per-case times -> less
# quantisation noise), drop this back to 25 or 10.
#
# Usage:
#   bench/check_regression.sh                       # default 200% threshold
#   REGRESSION_THRESHOLD_PCT=50 bench/check_regression.sh
#
# Requires:
#   * bin/CheckRegression   (build with src/bench/build.sh)
#   * bin/SpeedtestDiff     (same build)
#   * bin/passpeedtest1     (same build)
#   * ../sqlite3/speedtest1 (C oracle, see SpeedtestDiff header)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN="$ROOT_DIR/bin/CheckRegression"

if [ ! -x "$BIN" ]; then
  echo "ERROR: $BIN missing.  Run src/bench/build.sh first."
  exit 1
fi

: "${REGRESSION_THRESHOLD_PCT:=200}"
export REGRESSION_THRESHOLD_PCT

exec "$BIN" "$@"
