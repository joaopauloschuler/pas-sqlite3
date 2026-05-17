#!/usr/bin/env bash
# check_status_regression.sh — 9.4.5.a regression gate.
#
# Compares one or more TclTestDriver result logs against the canonical
# pas-strict/pas-soft/pas-skip tags in src/tests/tcl/STATUS.txt.
#
# Exits non-zero iff any test marked `pas-strict` in STATUS.txt is
# observed as FAIL in the result log(s).  pas-soft FAILs and pas-skip
# anything are ignored.  New PASS/FAIL classifications for tests not
# listed in STATUS.txt are warned about but do not fail the run.
#
# Usage:
#   check_status_regression.sh <result.log> [<result.log> ...]
#
# Result-log format (one line per test):
#   PASS|FAIL|SKIP <path> <nTest> <duration_ms>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUS_FILE="$SCRIPT_DIR/STATUS.txt"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <result.log> [<result.log> ...]" >&2
  exit 2
fi

if [ ! -f "$STATUS_FILE" ]; then
  echo "ERROR: missing $STATUS_FILE" >&2
  exit 2
fi

# Build status map: path -> tag (pas-strict|pas-soft|pas-skip)
STATUS_MAP=$(mktemp)
trap 'rm -f "$STATUS_MAP"' EXIT
awk -F'\t' '
  /^[[:space:]]*#/ { next }
  NF >= 2 && ($1 == "pas-strict" || $1 == "pas-soft" || $1 == "pas-skip") {
    print $2 "\t" $1
  }
' "$STATUS_FILE" | sort -u > "$STATUS_MAP"

# Build result map: path -> classification (PASS|FAIL|SKIP).
# Last entry wins if a path appears more than once (multi-shard concat).
RESULT_MAP=$(mktemp)
trap 'rm -f "$STATUS_MAP" "$RESULT_MAP"' EXIT
for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: result log not found: $f" >&2
    exit 2
  fi
  awk '/^(PASS|FAIL|SKIP) / { print $2 "\t" $1 }' "$f"
done | awk -F'\t' '{ m[$1] = $2 } END { for (k in m) print k "\t" m[k] }' \
     | sort -u > "$RESULT_MAP"

regressions=0
unknown=0

# Join: emit regressions for pas-strict rows observed FAIL.
join -t $'\t' "$STATUS_MAP" "$RESULT_MAP" | \
  awk -F'\t' -v out=/dev/stderr '
    $2 == "pas-strict" && $3 == "FAIL" {
      print "REGRESSION (pas-strict FAIL): " $1 > out
      r++
    }
    END { exit (r > 0 ? 1 : 0) }
  ' && rc=0 || rc=$?
regressions=$rc

# Warn about results for paths not in STATUS.txt.
join -t $'\t' -v 2 "$STATUS_MAP" "$RESULT_MAP" | while IFS=$'\t' read -r p c; do
  echo "WARN: result for unknown path (not in STATUS.txt): $p [$c]" >&2
done

if [ "$regressions" -ne 0 ]; then
  echo "FAIL: pas-strict regression(s) detected." >&2
  exit 1
fi

echo "OK: no pas-strict regressions."
exit 0
