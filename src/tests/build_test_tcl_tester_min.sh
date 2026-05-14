#!/usr/bin/env bash
# build_test_tcl_tester_min.sh — phase 9.4.2.g build + run gate.
#
# Compiles src/tests/TestTclTesterMin.pas against PasTclBridge, links
# libtcl8.6 + libdl, then runs the resulting bin/TestTclTesterMin which
# itself sources src/tests/tcl/tester_min.tcl through the loaded
# bin/libpassqlite3tcl.so package.
#
# Prereq: bin/libpassqlite3tcl.so must already exist (built via
# build_tcl_lib.sh).  We do NOT rebuild the shared library here; it's
# expected from the 9.4.2.b..f chain.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/.."
ROOT_DIR="$SRC_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
TCL_DIR="$SCRIPT_DIR/tcl"

mkdir -p "$BIN_DIR"

if [ ! -f "$BIN_DIR/libpassqlite3tcl.so" ]; then
  echo "ERROR: $BIN_DIR/libpassqlite3tcl.so missing; run build_tcl_lib.sh first."
  exit 2
fi
if [ ! -f "$TCL_DIR/tester_min.tcl" ]; then
  echo "ERROR: $TCL_DIR/tester_min.tcl missing."
  exit 2
fi

FPC_CMD=(fpc
  -MObjFPC -Scghi -O1
  -Fu"$TCL_DIR"
  -Fu"$TCL_DIR/testmodules"
  -Fu"$SRC_DIR"
  -Fi"$SRC_DIR"
  -FU"$BIN_DIR"
  -FE"$BIN_DIR"
  -o"$BIN_DIR/TestTclTesterMin"
  -k-ltcl8.6 -k-ldl
  "$SCRIPT_DIR/TestTclTesterMin.pas")

echo "+ ${FPC_CMD[*]}"
"${FPC_CMD[@]}"

echo "+ $BIN_DIR/TestTclTesterMin"
"$BIN_DIR/TestTclTesterMin"
rc=$?
echo "TestTclTesterMin rc=$rc"
if [ $rc -ne 0 ]; then exit $rc; fi

# 9.4.2.g.3 finish_test sub-tclsh gate.  finalize_testing calls exit, so
# we can't drive it from the in-process Pascal harness.  Spawn a child
# tclsh that loads the pas-sqlite3 Tcl bridge, sources tester_min.tcl,
# runs one trivial do_test, then finish_test.  Expect rc=0 (no errors)
# and the canonical "0 errors out of 1 tests" summary line.
echo "+ tclsh sub-process: tester_min.tcl finish_test gate"
SUB_OUT="$(tclsh <<TCL
load {$BIN_DIR/libpassqlite3tcl.so} Sqlite3
package require sqlite3
source {$TCL_DIR/tester_min.tcl}
sqlite3 db :memory:
do_test g3-finish-1 { expr 41+1 } 42
finish_test
TCL
)"
sub_rc=$?
echo "$SUB_OUT"
if [ $sub_rc -ne 0 ]; then
  echo "ERROR: sub-tclsh finish_test exited rc=$sub_rc"
  exit $sub_rc
fi
if ! echo "$SUB_OUT" | grep -q '0 errors out of 1 tests'; then
  echo "ERROR: sub-tclsh finish_test missing summary line"
  exit 3
fi
echo "PASS: sub-tclsh finish_test rc=0 with expected summary"
exit 0
