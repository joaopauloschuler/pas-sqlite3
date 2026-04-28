#!/usr/bin/env bash
# install_dependencies.sh — ensure build and test dependencies are present.
#
# Modelled on ../pas-bzip2/install_dependencies.sh and
# ../pas-core-math/install_dependencies.sh.
#
# Checks (in order):
#   1. fpc  — Free Pascal Compiler
#   2. gcc  — C compiler (needed to build libsqlite3.so)
#   3. make — required by upstream SQLite build
#   4. tcl  — required to run SQLite's own Tcl test suite (Phase 9.4)
#   5. ../sqlite3/ — the upstream split source tree must already be present;
#      this script does NOT auto-clone it.  Print a clear error if missing.
#
# Does NOT push/commit anything.  Safe to run repeatedly.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQLITE3_DIR="$SCRIPT_DIR/../sqlite3"

ok()   { echo "  [OK]  $*"; }
warn() { echo "  [!!]  $*"; }
fail() { echo "  [FAIL] $*"; exit 1; }

echo "=== pas-sqlite3 dependency check ==="
echo

# ---- fpc ----
if command -v fpc &>/dev/null; then
  FPC_VER="$(fpc -iV 2>/dev/null || true)"
  ok "fpc found: $FPC_VER"
else
  warn "fpc not found — installing via apt ..."
  sudo apt-get install -y fpc
  FPC_VER="$(fpc -iV 2>/dev/null || true)"
  ok "fpc installed: $FPC_VER"
fi

# ---- gcc ----
if command -v gcc &>/dev/null; then
  GCC_VER="$(gcc --version 2>/dev/null | head -1)"
  ok "gcc found: $GCC_VER"
else
  warn "gcc not found — installing via apt ..."
  sudo apt-get install -y gcc
  ok "gcc installed"
fi

# ---- make ----
if command -v make &>/dev/null; then
  ok "make found"
else
  warn "make not found — installing via apt ..."
  sudo apt-get install -y make
  ok "make installed"
fi

# ---- tcl ----
if command -v tclsh &>/dev/null; then
  TCL_VER="$(echo 'puts [info tclversion]; exit' | tclsh)"
  ok "tclsh found: $TCL_VER"
else
  warn "tclsh not found — installing via apt ..."
  sudo apt-get install -y tcl
  ok "tclsh installed"
fi

# ---- ../sqlite3/ ----
echo
echo "Checking for upstream SQLite split source tree ..."
if [ ! -d "$SQLITE3_DIR" ]; then
  fail "$SQLITE3_DIR not found.
Please place the upstream SQLite split source tree at:
  $SQLITE3_DIR
(Typically cloned or unpacked from https://sqlite.org/src/ or a release
tarball — NOT the amalgamation.)
The directory must contain src/*.c, test/*.test, tool/lemon.c, etc."
fi

if [ ! -f "$SQLITE3_DIR/auto.def" ] && [ ! -f "$SQLITE3_DIR/configure" ]; then
  fail "$SQLITE3_DIR does not look like a SQLite source tree.
Expected configure or auto.def at the root."
fi

# Check version
if [ -f "$SQLITE3_DIR/VERSION" ]; then
  SQLITE_VER="$(cat "$SQLITE3_DIR/VERSION")"
  ok "sqlite3 source tree found: version $SQLITE_VER"
else
  warn "VERSION file not found; cannot confirm SQLite version."
fi

# Count src/*.c files as a quick sanity check
C_COUNT="$(ls "$SQLITE3_DIR/src/"*.c 2>/dev/null | wc -l)"
if [ "$C_COUNT" -lt 50 ]; then
  fail "Only $C_COUNT .c files found in $SQLITE3_DIR/src/ — expected ~150."
else
  ok "Found $C_COUNT .c files in src/"
fi

# Check for lemon (needed for Phase 7)
if [ -f "$SQLITE3_DIR/tool/lemon.c" ]; then
  ok "tool/lemon.c present"
else
  warn "tool/lemon.c not found (needed for Phase 7 parser port)"
fi

echo
echo "=== All dependencies satisfied. ==="
echo "Next step: run src/tests/build.sh to build libsqlite3.so and test binaries."
