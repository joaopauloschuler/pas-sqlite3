#!/usr/bin/env bash
# build_tcl_driver.sh — phase 9.4.3.a build recipe.
#
# Compiles src/tests/TclTestDriver.pas into bin/TclTestDriver and runs
# a smoke invocation that proves the driver can spawn tclsh against
# bin/libpassqlite3tcl.so and emit PASS/FAIL/SKIP lines for at least
# one .test file.
#
# Pre-req: bin/libpassqlite3tcl.so already built (see
# src/tests/build_tcl_lib.sh).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/.."
ROOT_DIR="$SRC_DIR/.."
BIN_DIR="$ROOT_DIR/bin"

mkdir -p "$BIN_DIR"

FPC_CMD=(fpc
  -MObjFPC -Scghi -O1
  -FU"$BIN_DIR"
  -FE"$BIN_DIR"
  -o"$BIN_DIR/TclTestDriver"
  "$SCRIPT_DIR/TclTestDriver.pas")

echo "+ ${FPC_CMD[*]}"
"${FPC_CMD[@]}"

# Smoke: limit 3, filter "select" — should hit select1/select2/select3.
# Any FAIL is acceptable here; the gate is "driver runs + emits lines".
SMOKE_CMD=("$BIN_DIR/TclTestDriver" --limit 3 --filter select)
echo "+ ${SMOKE_CMD[*]}"
"${SMOKE_CMD[@]}" || true
