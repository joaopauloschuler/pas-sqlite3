#!/usr/bin/env bash
# build_tcl_lib.sh — phase 9.4.2.b build recipe.
#
# Compiles src/tests/tcl/libpassqlite3tcl.lpr into a shared object at
# bin/libpassqlite3tcl.so.  `tclsh` can then `load` it as a Tcl
# package (entry point Sqlite3_Init).
#
# This is intentionally separate from build.sh: the loadable package
# does not link against the full passqlite3*.pas tree yet — only the
# minimal Tcl bridge + the Sqlite3_Init stub.  Real DbMain wiring
# lands in 9.4.2.c..f and will pull in passqlite3main / codegen / etc.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/.."
ROOT_DIR="$SRC_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
TCL_DIR="$SCRIPT_DIR/tcl"

mkdir -p "$BIN_DIR"

# Opt-in pre-update hook support: `PREUPDATE=1 ./build_tcl_lib.sh` adds
# -dSQLITE_ENABLE_PREUPDATE_HOOK so the engine pre-update API and the
# `db preupdate` Tcl subcommand are compiled in.  Off by default
# (matches build.sh and the upstream oracle build).
PREUPDATE_FLAGS=()
if [ "${PREUPDATE:-0}" = "1" ]; then
  echo "PREUPDATE=1 — passing -dSQLITE_ENABLE_PREUPDATE_HOOK to fpc."
  PREUPDATE_FLAGS=(-dSQLITE_ENABLE_PREUPDATE_HOOK)
fi

# -Fu paths:
#   $TCL_DIR  : PasTclBridge.pas, PasTclSqlite.pas
#   $SRC_DIR  : passqlite3types.pas (for SQLITE_VERSION constant)
# -FU/-FE   : .ppu/.o + final binary into bin/
# -k-ltcl8.6 -k-ldl : link Tcl + dlopen runtime
# Output .so name pinned via -o.
FPC_CMD=(fpc
  -MObjFPC -Scghi -O1
  -Cg
  "${PREUPDATE_FLAGS[@]}"
  -Fu"$TCL_DIR"
  -Fu"$SRC_DIR"
  -FU"$BIN_DIR"
  -FE"$BIN_DIR"
  -o"$BIN_DIR/libpassqlite3tcl.so"
  -k-ltcl8.6 -k-ldl -k-lm -k-lz
  "$TCL_DIR/libpassqlite3tcl.lpr")

echo "+ ${FPC_CMD[*]}"
"${FPC_CMD[@]}"

echo "+ file $BIN_DIR/libpassqlite3tcl.so"
file "$BIN_DIR/libpassqlite3tcl.so"
