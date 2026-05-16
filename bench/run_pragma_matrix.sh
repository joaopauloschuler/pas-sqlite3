#!/usr/bin/env bash
# bench/run_pragma_matrix.sh — Phase 11.8 wrapper.
#
# Builds passpeedtest1 + PragmaMatrix if needed, then runs the 24-cell
# pragma/config matrix and writes bench/pragma_matrix.txt.
#
# Args are forwarded to bin/PragmaMatrix (e.g. --size 5 for bigger workload).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # pas-sqlite3/bench/
ROOT_DIR="$SCRIPT_DIR/.."                             # pas-sqlite3/
SRC_DIR="$ROOT_DIR/src"
BIN_DIR="$ROOT_DIR/bin"

if [ ! -x "$BIN_DIR/PragmaMatrix" ] || [ ! -x "$BIN_DIR/passpeedtest1" ]; then
  echo "Building bench binaries ..."
  "$SRC_DIR/bench/build.sh"
fi

C_ORACLE="$ROOT_DIR/../sqlite3/speedtest1"
if [ ! -x "$C_ORACLE" ]; then
  echo "ERROR: C oracle missing: $C_ORACLE"
  echo "       cd ../sqlite3 && gcc -O2 -o speedtest1 test/speedtest1.c \\"
  echo "           -I. -L. -l:libsqlite3.a -lpthread -lm -ldl"
  exit 2
fi

mkdir -p "$ROOT_DIR/bench"
exec "$BIN_DIR/PragmaMatrix" \
  --pas-bin "$BIN_DIR/passpeedtest1" \
  --c-bin   "$C_ORACLE" \
  --lib-dir "$SRC_DIR" \
  --out     "$ROOT_DIR/bench/pragma_matrix.txt" \
  "$@"
