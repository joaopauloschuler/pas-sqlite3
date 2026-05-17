#!/usr/bin/env bash
# permutations_matrix.sh — 9.4.7.e first-cut wrapper for permutations.tcl.
#
# Drives bin/TclTestDriver under one (or "all") wired permutation NAMEs.
# A first-cut subset is wired; the full ~30-permutation matrix is queued
# (see src/tests/tcl/PERMUTATIONS.md for wired vs deferred).
#
# Usage:
#   permutations_matrix.sh list                    # list wired names
#   permutations_matrix.sh run NAME [extra args]   # one permutation
#   permutations_matrix.sh all       [extra args]  # all wired in sequence
#
# Extra args are passed verbatim to TclTestDriver (e.g. --limit 10 --filter ...).
#
# Exit code: 0 iff every selected permutation exits 0.
#
# C ref: sqlite3/test/permutations.test:1148..1198 (run_tests dispatcher).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DRIVER="$ROOT_DIR/bin/TclTestDriver"

# Wired permutations — keep in sync with PERMUTATIONS in TclTestDriver.pas.
WIRED=(
  wal
  inmemory_journal
  persistent_journal
  truncate_journal
  no_journal
  exclusive
  exclusive-truncate
  utf16
  serialized
  multithread
)

usage() {
  cat <<EOF
permutations_matrix.sh — 9.4.7.e first-cut driver
Usage:
  $0 list
  $0 run NAME [driver args...]
  $0 all       [driver args...]

Wired permutations: ${WIRED[*]}
EOF
}

if [ $# -lt 1 ]; then usage; exit 2; fi

cmd="$1"; shift || true

case "$cmd" in
  list)
    for n in "${WIRED[@]}"; do echo "$n"; done
    ;;
  run)
    if [ $# -lt 1 ]; then usage; exit 2; fi
    name="$1"; shift
    [ -x "$DRIVER" ] || { echo "missing $DRIVER" >&2; exit 2; }
    exec "$DRIVER" --permutation "$name" "$@"
    ;;
  all)
    [ -x "$DRIVER" ] || { echo "missing $DRIVER" >&2; exit 2; }
    rc=0
    for n in "${WIRED[@]}"; do
      echo "=== permutation: $n ===" >&2
      "$DRIVER" --permutation "$n" "$@" || rc=1
    done
    exit $rc
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage; exit 2
    ;;
esac
