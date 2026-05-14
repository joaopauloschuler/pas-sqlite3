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
exit $rc
