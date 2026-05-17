#!/usr/bin/env bash
# build_tcl_lib_threadsafe.sh — phase 9.4.7.i build recipe (threadsafe profile).
#
# Same as build_tcl_lib.sh but explicitly passes -dSQLITE_THREADSAFE=1 and
# produces a separate shared object at bin/libpassqlite3tcl-threadsafe.so.
# The TclTestDriver selects this build with `--build threadsafe`.
#
# Engine note: the Pascal port already hardcodes serialized mode — the
# const block in src/passqlite3internal.pas pins SQLITE_THREADSAFE = 1
# and src/passqlite3os.pas wires the pthread_mutex_* implementation
# unconditionally (mutex_unix.c equivalent).  The default build
# (build_tcl_lib.sh) is therefore *already* a threadsafe build for all
# engine-side purposes.  This script exists so:
#   1. The `-dSQLITE_THREADSAFE=1` define is visible to any future
#      `{$IFDEF SQLITE_THREADSAFE}` consumer (currently none — audited
#      in src/tests/tcl/THREADSAFE_AUDIT.md).
#   2. Tests that switch behaviour based on `sqlite_options(threadsafe)`
#      (sort.test, pcache.test, …) can be re-run against an explicitly
#      labelled .so so CI logs stay self-describing.
#   3. CI nightly slots can compare default-vs-threadsafe artifacts.
#
# The PREUPDATE=1 / UNLOCK_NOTIFY=1 env toggles from build_tcl_lib.sh
# are also honoured here.

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

# Private .ppu/.o staging dir keeps the threadsafe-labelled objects from
# clobbering the default-build artifacts in bin/ (mirrors memdebug).
UNIT_DIR="$BIN_DIR/threadsafe-units"
mkdir -p "$UNIT_DIR"

FPC_CMD=(fpc
  -MObjFPC -Scghi -O1
  -Cg
  -dSQLITE_THREADSAFE
  -dSQLITE_TEST
  "${PREUPDATE_FLAGS[@]}"
  "${UNLOCK_NOTIFY_FLAGS[@]}"
  -Fu"$TCL_DIR"
  -Fu"$TCL_DIR/testmodules"
  -Fu"$SRC_DIR"
  -Fi"$SRC_DIR"
  -FU"$UNIT_DIR"
  -FE"$UNIT_DIR"
  -o"$BIN_DIR/libpassqlite3tcl-threadsafe.so"
  -k-ltcl8.6 -k-ldl -k-lm -k-lz -k-lpthread
  "$TCL_DIR/libpassqlite3tcl.lpr")

echo "+ ${FPC_CMD[*]}"
"${FPC_CMD[@]}"

echo "+ file $BIN_DIR/libpassqlite3tcl-threadsafe.so"
file "$BIN_DIR/libpassqlite3tcl-threadsafe.so"
