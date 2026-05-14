#!/usr/bin/env bash
# build_tcl_lib_memdebug.sh — phase 9.4.7.b build recipe (memdebug profile).
#
# Same as build_tcl_lib.sh but adds -dSQLITE_MEMDEBUG and produces a
# separate shared object at bin/libpassqlite3tcl-memdebug.so.  This is the
# build the TclTestDriver selects with `--build memdebug` when running
# do_malloc_test (task 9.4.2.g.9).
#
# The SQLITE_MEMDEBUG define currently only affects the test_malloc.c port
# (src/tests/tcl/testmodules/TestModuleMalloc.pas): it un-stubs the
# sqlite3_memdebug_settitle / _backtrace / _malloc_count command bodies.
# The malloc fault-injection layer (install_malloc_faultsim,
# sqlite3_memdebug_fail / _pending) is compiled into BOTH builds — that
# matches the C source, where faultsim* sits outside #ifdef SQLITE_MEMDEBUG.
#
# The default build (build.sh / build_tcl_lib.sh) is unaffected: the
# {$ifdef SQLITE_MEMDEBUG} guards are inert without -dSQLITE_MEMDEBUG.
#
# The PREUPDATE=1 / UNLOCK_NOTIFY=1 env toggles from build_tcl_lib.sh are
# also honoured here.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/.."
ROOT_DIR="$SRC_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
TCL_DIR="$SCRIPT_DIR/tcl"

mkdir -p "$BIN_DIR"

PREUPDATE_FLAGS=()
if [ "${PREUPDATE:-0}" = "1" ]; then
  echo "PREUPDATE=1 — passing -dSQLITE_ENABLE_PREUPDATE_HOOK to fpc."
  PREUPDATE_FLAGS=(-dSQLITE_ENABLE_PREUPDATE_HOOK)
fi

UNLOCK_NOTIFY_FLAGS=()
if [ "${UNLOCK_NOTIFY:-0}" = "1" ]; then
  echo "UNLOCK_NOTIFY=1 — passing -dSQLITE_ENABLE_UNLOCK_NOTIFY to fpc."
  UNLOCK_NOTIFY_FLAGS=(-dSQLITE_ENABLE_UNLOCK_NOTIFY)
fi

# A private .ppu/.o staging dir keeps the memdebug objects from clobbering
# the default-build artifacts in bin/ (the -dSQLITE_MEMDEBUG units differ).
UNIT_DIR="$BIN_DIR/memdebug-units"
mkdir -p "$UNIT_DIR"

FPC_CMD=(fpc
  -MObjFPC -Scghi -O1
  -Cg
  -dSQLITE_MEMDEBUG
  -dSQLITE_TEST
  "${PREUPDATE_FLAGS[@]}"
  "${UNLOCK_NOTIFY_FLAGS[@]}"
  -Fu"$TCL_DIR"
  -Fu"$TCL_DIR/testmodules"
  -Fu"$SRC_DIR"
  -Fi"$SRC_DIR"
  -FU"$UNIT_DIR"
  -FE"$UNIT_DIR"
  -o"$BIN_DIR/libpassqlite3tcl-memdebug.so"
  -k-ltcl8.6 -k-ldl -k-lm -k-lz
  "$TCL_DIR/libpassqlite3tcl.lpr")

echo "+ ${FPC_CMD[*]}"
"${FPC_CMD[@]}"

echo "+ file $BIN_DIR/libpassqlite3tcl-memdebug.so"
file "$BIN_DIR/libpassqlite3tcl-memdebug.so"
</content>
