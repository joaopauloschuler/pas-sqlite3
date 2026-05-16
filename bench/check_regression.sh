#!/usr/bin/env bash
# Phase 11.7 — wrapper for bin/CheckRegression.
#
# Re-runs the speedtest1 matrix recorded in bench/baseline.json and fails
# (exit 1) on any per-cell relative regression > REGRESSION_THRESHOLD_PCT
# (default 10).
#
# Usage:
#   bench/check_regression.sh                       # default 10% threshold
#   REGRESSION_THRESHOLD_PCT=20 bench/check_regression.sh
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

exec "$BIN" "$@"
