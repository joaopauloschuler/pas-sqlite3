#!/usr/bin/env bash
# regression_bisect.sh — 9.4.8.e regression archive driver.
#
# Long-term: once the full Tcl corpus runs green under pas-strict,
# every reopened divergence counts as a regression.  This script
# walks `git bisect` between a known-good baseline commit and a
# known-broken commit, using `bin/TclTestDriver --limit-to <test>`
# as the bisect predicate, and prints the offending commit.
#
# Usage:
#   regression_bisect.sh <test-path> <good-commit> <bad-commit> [--build CMD]
#
#   <test-path>      Relative path matching a MANIFEST.txt entry
#                    (e.g. `../sqlite3/test/select1.test`).
#   <good-commit>    SHA / ref where the test passes (baseline).
#   <bad-commit>     SHA / ref where the test fails (regressed).
#   --build CMD      Optional build command to run at each bisect
#                    step.  Default: `bash src/tests/build_tcl_lib.sh
#                    && bash src/tests/build_tcl_driver.sh`.
#
# The bisect predicate exits 0 when the test PASSes, 1 when it FAILs,
# and 125 (skip) when the build itself fails — git bisect's
# documented convention for "untestable" revisions.
#
# Pre-reqs:
#   - clean working tree (no uncommitted changes)
#   - bin/libpassqlite3tcl.so re-buildable from source
#   - tclsh on PATH
#
# Note: bin/TclTestDriver does not yet expose a `--limit-to PATH`
# flag — `--filter SUBSTR` is the closest equivalent today.  This
# script uses `--filter` against the basename of <test-path>; once
# 9.4.7 lands the `--limit-to` exact-match flag, swap the call.

set -euo pipefail

if [ "$#" -lt 3 ]; then
  cat >&2 <<USAGE
usage: $0 <test-path> <good-commit> <bad-commit> [--build CMD]

Walks git bisect between <good-commit> and <bad-commit> using
bin/TclTestDriver as the test predicate; prints the first commit
where <test-path> starts FAILing.
USAGE
  exit 2
fi

TEST_PATH="$1"
GOOD="$2"
BAD="$3"
shift 3

BUILD_CMD='bash src/tests/build_tcl_lib.sh && bash src/tests/build_tcl_driver.sh'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --build) shift; BUILD_CMD="$1"; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: working tree must be clean for git bisect" >&2
  exit 2
fi

# Sanity: both refs must be reachable.
git rev-parse --verify "$GOOD^{commit}" >/dev/null
git rev-parse --verify "$BAD^{commit}"  >/dev/null

TEST_BASENAME="$(basename "$TEST_PATH" .test)"
PREDICATE_SCRIPT="$(mktemp)"
trap 'rm -f "$PREDICATE_SCRIPT"' EXIT

cat > "$PREDICATE_SCRIPT" <<PRED
#!/usr/bin/env bash
# bisect predicate for regression_bisect.sh
set -u
cd "$REPO_ROOT"

# Build current commit; mark untestable if build fails.
if ! ($BUILD_CMD) >/tmp/bisect_build.log 2>&1; then
  echo "BUILD FAIL at \$(git rev-parse --short HEAD)" >&2
  tail -20 /tmp/bisect_build.log >&2
  exit 125
fi

if [ ! -x bin/TclTestDriver ]; then
  echo "MISSING bin/TclTestDriver after build" >&2
  exit 125
fi

# Run only the target test (filtered by basename).  Capture log.
LOG=\$(mktemp)
bin/TclTestDriver --filter "$TEST_BASENAME" >"\$LOG" 2>&1 || true

# Look for an exact-path PASS line.
if awk -v p="$TEST_PATH" '
  /^PASS / && \$2 == p { found = 1; exit }
  END { exit (found ? 0 : 1) }
' "\$LOG"; then
  rm -f "\$LOG"
  exit 0   # PASS = "good"
fi

# Anything else (FAIL / SKIP / absent) treated as "bad" so the
# bisect converges on the first commit that drops PASS.
echo "NOT-PASS at \$(git rev-parse --short HEAD) for $TEST_PATH:" >&2
grep -E "^(PASS|FAIL|SKIP) " "\$LOG" | tail -5 >&2
rm -f "\$LOG"
exit 1
PRED
chmod +x "$PREDICATE_SCRIPT"

echo "Bisecting [$GOOD .. $BAD] for $TEST_PATH"
echo "Predicate: $PREDICATE_SCRIPT"

# Run the bisect.  `git bisect run` walks the range, calling the
# predicate at each midpoint, and finally prints the first-bad commit.
git bisect start
git bisect good "$GOOD"
git bisect bad  "$BAD"
git bisect run "$PREDICATE_SCRIPT"
BISECT_RC=$?
git bisect log > /tmp/bisect.log
git bisect reset

echo "---"
echo "Bisect log: /tmp/bisect.log"
echo "Predicate exit: $BISECT_RC"
exit "$BISECT_RC"
