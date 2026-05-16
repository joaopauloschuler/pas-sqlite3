#!/usr/bin/env bash
# build.sh — compile bin/passpeedtest1 (Phase 11.1 skeleton harness).
#
# Mirrors src/tests/build.sh's FPC flags so the speedtest1 binary picks
# up the same -dSQLITE_DEBUG / -dSQLITE_ENABLE_STMT_SCANSTATUS / -dSTAT4
# gates as the rest of the Pascal port.  libsqlite3.so is assumed to be
# already built by src/tests/build.sh; if it's missing this script will
# bail with a clear message.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # pas-sqlite3/src/bench/
SRC_DIR="$SCRIPT_DIR/.."                              # pas-sqlite3/src/
ROOT_DIR="$SRC_DIR/.."                                # pas-sqlite3/
BIN_DIR="$ROOT_DIR/bin"

mkdir -p "$BIN_DIR"

if [ ! -f "$SRC_DIR/libsqlite3.so" ]; then
  echo "ERROR: $SRC_DIR/libsqlite3.so missing.  Run src/tests/build.sh first."
  exit 1
fi

DEBUG_FLAGS=""
if [ "${SQLITE_DEBUG:-0}" = "1" ];                  then DEBUG_FLAGS="$DEBUG_FLAGS -dSQLITE_DEBUG"; fi
if [ "${SQLITE_ENABLE_STMT_SCANSTATUS:-0}" != "0" ]; then DEBUG_FLAGS="$DEBUG_FLAGS -dSQLITE_ENABLE_STMT_SCANSTATUS"; fi
if [ "${STAT4:-0}" != "0" ];                         then DEBUG_FLAGS="$DEBUG_FLAGS -dSQLITE_ENABLE_STAT4"; fi

FPC_FLAGS="-O3 $DEBUG_FLAGS -Fu$SRC_DIR -Fi$SRC_DIR -FE$BIN_DIR -Fl$SRC_DIR -k-lm -k-lz $@"

echo "Compiling passpeedtest1.pas ..."
fpc $FPC_FLAGS "$SCRIPT_DIR/passpeedtest1.pas"
echo "passpeedtest1 compiled -> $BIN_DIR/passpeedtest1"

echo "Compiling SpeedtestDiff.pas ..."
# SpeedtestDiff is a plain TProcess driver — does not link the pas engine
# units, only spawns bin/passpeedtest1 and the C oracle. No -k-l* needed.
fpc -O2 -FE$BIN_DIR "$SCRIPT_DIR/SpeedtestDiff.pas"
echo "SpeedtestDiff compiled -> $BIN_DIR/SpeedtestDiff"

echo "Compiling CheckRegression.pas ..."
# CheckRegression also a plain driver; uses FPC's fcl-json (fpjson + jsonparser).
FCLJSON_DIR=""
for d in /usr/lib/fpc/*/units/*/fcl-json /usr/lib64/fpc/*/units/*/fcl-json; do
  if [ -f "$d/fpjson.ppu" ]; then FCLJSON_DIR="$d"; break; fi
done
if [ -z "$FCLJSON_DIR" ]; then
  echo "ERROR: fcl-json units not found (need fpjson + jsonparser)."
  echo "       apt install fp-units-fcl  (or equivalent)."
  exit 1
fi
fpc -O2 -Fu"$FCLJSON_DIR" -FE$BIN_DIR "$SCRIPT_DIR/CheckRegression.pas"
echo "CheckRegression compiled -> $BIN_DIR/CheckRegression"

# Clean compiled artefacts
find "$SCRIPT_DIR" -maxdepth 1 \( -name '*.ppu' -o -name '*.o' -o -name '*.compiled' -o -name '*.s' \) -delete
find "$BIN_DIR"    -maxdepth 1 \( -name '*.ppu' -o -name '*.o' -o -name '*.compiled' -o -name '*.s' \) -delete

echo
echo "Run with: LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/passpeedtest1 --help"
