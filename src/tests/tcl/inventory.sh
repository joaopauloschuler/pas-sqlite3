#!/bin/sh
# 9.4.1.a: Inventory upstream SQLite Tcl test files and tag each one as
#   tcl-internal  -- depends on private/test-only C hooks (sqlite3_test_control,
#                    register_dbstat_vtab, sqlite3_db_status, etc.) or sources
#                    a *_common.tcl harness that does.
#   tcl-perf      -- speed/big-file/wal-protocol stress tests.
#   tcl-feature   -- everything else (default; portable SQL-level coverage).
#
# Output:
#   src/tests/tcl/MANIFEST.txt  -- TAB-separated "<tag>\t<path>", one per file.
# Summary counts go to stderr.
#
# Usage (run from pas-sqlite3 repo root):
#   sh src/tests/tcl/inventory.sh
#
# POSIX sh only -- no bashisms.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$SCRIPT_DIR/MANIFEST.txt"

# Upstream test directory -- sibling clone of sqlite3 next to pas-sqlite3.
TEST_DIR="${TEST_DIR:-$SCRIPT_DIR/../../../../sqlite3/test}"

if [ ! -d "$TEST_DIR" ]; then
    echo "inventory.sh: cannot find upstream test dir at $TEST_DIR" >&2
    exit 1
fi

# Resolve to a clean absolute path so MANIFEST entries are stable.
TEST_DIR=$(CDPATH= cd -- "$TEST_DIR" && pwd)

# Internal-API markers. A file matching ANY of these is tcl-internal.
# Note: the *_common.tcl source-lines are flagged because those harnesses
# themselves wrap private hooks (malloc fault-injection, lock primitives,
# incremental-blob test ops).
#
# 9.4.4.h retag: dropped `register_dbstat_vtab`, `db_save`, `db_save_and_close`
# from the trigger set — they landed via 9.4.6.b (dbstat Tcl registration) and
# 9.4.6.q.2 (db_save / db_save_and_close procs in tester_min.tcl).
INTERNAL_PATTERN='sqlite3_test_control|sqlite3_db_status|optimization_control|sqlite3_stmt_status|sqlite3InvokeBusyHandler|sqlite3_test_|malloc_common\.tcl|lock_common\.tcl|incrblob_common\.tcl'

# Perf-content markers (looked at file body, not just name).
PERF_PATTERN='set BIG |bigtest|performance'

n_total=0
n_internal=0
n_perf=0
n_feature=0

# Truncate manifest.
: > "$OUT"

# Iterate in sorted order for reproducible MANIFEST diffs.
# Use a glob; if no matches, the loop body sees a literal pattern -- guard.
for f in "$TEST_DIR"/*.test; do
    [ -f "$f" ] || continue
    n_total=$((n_total + 1))
    base=$(basename "$f")

    tag="tcl-feature"

    # Perf classification first by filename pattern.
    case "$base" in
        speed*.test|bigfile*.test|wal_big.test|walbak.test|walprotocol*.test)
            tag="tcl-perf"
            ;;
    esac

    # If still feature, check body for perf markers.
    if [ "$tag" = "tcl-feature" ]; then
        if grep -E -q "$PERF_PATTERN" "$f" 2>/dev/null; then
            tag="tcl-perf"
        fi
    fi

    # Internal-API markers override -- a perf test that also pokes private
    # hooks is more usefully tracked as internal (we can't run it portably
    # at all). Check after perf so we can re-tag.
    if grep -E -q "$INTERNAL_PATTERN" "$f" 2>/dev/null; then
        tag="tcl-internal"
    fi

    case "$tag" in
        tcl-internal) n_internal=$((n_internal + 1)) ;;
        tcl-perf)     n_perf=$((n_perf + 1)) ;;
        tcl-feature)  n_feature=$((n_feature + 1)) ;;
    esac

    # Emit a stable relative path "../sqlite3/test/<base>" so MANIFEST.txt
    # is independent of $HOME / clone location.
    printf '%s\t../sqlite3/test/%s\n' "$tag" "$base" >> "$OUT"
done

{
    echo "inventory.sh: scanned $n_total .test files under $TEST_DIR"
    echo "  tcl-internal : $n_internal"
    echo "  tcl-perf     : $n_perf"
    echo "  tcl-feature  : $n_feature"
    echo "manifest: $OUT"
} >&2
