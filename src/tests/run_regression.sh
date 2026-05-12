#!/usr/bin/env bash
# run_regression.sh — run every Test* binary as a pass/fail regression gate.
#
# Convention: Test* binaries exit 0 on success, non-zero on failure.
# Anything matching bin/Test* is auto-discovered, so new tests join the
# gate by construction.  Run after src/tests/build.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/.."
ROOT_DIR="$SRC_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
LOG_DIR="$(mktemp -d -t pas-sqlite3-regression.XXXXXX)"

export LD_LIBRARY_PATH="$SRC_DIR"

TIMEOUT_SECS="${REGRESSION_TIMEOUT:-60}"

pass=0
fail=0
failed=()
assert_pass=0
assert_fail=0

shopt -s nullglob
binaries=("$BIN_DIR"/Test*)
if [ ${#binaries[@]} -eq 0 ]; then
  echo "ERROR: no Test* binaries found in $BIN_DIR — run src/tests/build.sh first." >&2
  exit 2
fi

echo "Running regression gate against $BIN_DIR (timeout ${TIMEOUT_SECS}s/test)"
echo "Logs: $LOG_DIR"
echo

for bin in "${binaries[@]}"; do
  [ -x "$bin" ] || continue
  name="$(basename "$bin")"
  log="$LOG_DIR/$name.log"
  printf '  %-32s ' "$name"
  # Run each test in its own working directory so transient files
  # (e.g. test.db) from one test cannot leak into the next.
  workdir="$LOG_DIR/$name.cwd"
  mkdir -p "$workdir"
  if (cd "$workdir" && timeout "$TIMEOUT_SECS" "$bin") >"$log" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  # Count per-assertion PASS/FAIL markers emitted by the test (lines
  # whose first non-whitespace token is the literal word PASS or FAIL).
  # Avoids matching summary lines like "Results: 1026 pass" or "ALL PASS".
  ap=$(grep -cE '^[[:space:]]*PASS([[:space:]]|$)' "$log" 2>/dev/null); ap=${ap:-0}
  af=$(grep -cE '^[[:space:]]*FAIL([[:space:]]|$)' "$log" 2>/dev/null); af=${af:-0}
  assert_pass=$((assert_pass + ap))
  assert_fail=$((assert_fail + af))

  if [ "$rc" -eq 0 ]; then
    printf 'PASS  (%d/%d)\n' "$ap" "$((ap + af))"
    pass=$((pass + 1))
  else
    if [ "$rc" -eq 124 ]; then
      printf 'FAIL  (%d/%d, timeout) — %s\n' "$ap" "$((ap + af))" "$log"
    else
      printf 'FAIL  (%d/%d, rc=%d) — %s\n' "$ap" "$((ap + af))" "$rc" "$log"
    fi
    fail=$((fail + 1))
    failed+=("$name (rc=$rc)")
  fi
done

echo
echo "Regression: $pass binaries passed, $fail binaries failed."
echo "Assertions: $assert_pass passed, $assert_fail failed (total $((assert_pass + assert_fail)))."
if [ "$fail" -ne 0 ]; then
  echo "Failed tests:"
  for f in "${failed[@]}"; do echo "  - $f"; done
  echo
  echo "Logs retained at: $LOG_DIR"
  exit 1
fi

# All-green: clean up logs.
rm -rf "$LOG_DIR"
exit 0
