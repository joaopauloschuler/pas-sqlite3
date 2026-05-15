#!/usr/bin/env bash
# build_tcl_smoke.sh — phase 9.4.2.a build + run gate.
#
# Compiles src/tests/TestTclBridgeSmoke.pas against the FPC <-> Tcl 8.6
# bridge unit (src/tests/tcl/PasTclBridge.pas), links libtcl8.6 + libdl,
# runs the resulting bin/TestTclBridgeSmoke, and exits with its rc.
#
# This is intentionally separate from the heavyweight `build.sh` driver:
# the smoke gate has no dependency on libsqlite3.so and we want it to be
# the smallest possible sanity check that the Tcl ABI bindings link.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/.."
ROOT_DIR="$SRC_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
TCL_DIR="$SCRIPT_DIR/tcl"

mkdir -p "$BIN_DIR"

cd "$SCRIPT_DIR"

# -Fu: where to find PasTclBridge.pas
# -FE/-o: emit binary into bin/
# -k-ltcl8.6 -k-ldl: link Tcl + dynamic loader (Tcl uses dlopen for pkg load)
FPC_CMD=(fpc
  -MObjFPC -Scghi -O1
  -Fu"$TCL_DIR"
  -FU"$BIN_DIR"
  -FE"$BIN_DIR"
  -o"$BIN_DIR/TestTclBridgeSmoke"
  -k-ltcl8.6 -k-ldl
  "$SCRIPT_DIR/TestTclBridgeSmoke.pas")

echo "+ ${FPC_CMD[*]}"
"${FPC_CMD[@]}"

echo "+ $BIN_DIR/TestTclBridgeSmoke"
"$BIN_DIR/TestTclBridgeSmoke"
rc=$?
echo "TestTclBridgeSmoke rc=$rc"
exit $rc
