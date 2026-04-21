#!/usr/bin/env bash
# build.sh — build libsqlite3.so from ../sqlite3/ and compile all Pascal test binaries.
#
# Run from any directory; paths are derived from the script location.
# Modelled on ../pas-bzip2/src/tests/build.sh and ../pas-core-math/src/tests/build.sh.
#
# SQLite 3.48+ uses autosetup (not classic autoconf/libtool).
# This script invokes upstream's own ./configure && make rather than a bespoke
# gcc line, so compile flags, generated headers (opcodes.h, parse.c,
# keywordhash.h, sqlite3.h) and link order all remain correct by construction.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/.."              # pas-sqlite3/src/
ROOT_DIR="$SRC_DIR/.."               # pas-sqlite3/
BIN_DIR="$ROOT_DIR/bin"
SQLITE3_C_DIR="$ROOT_DIR/../sqlite3"  # upstream split source tree

mkdir -p "$BIN_DIR"

# ---- Step 1: Build libsqlite3.so via upstream's own build system ----
SOFILE="$SRC_DIR/libsqlite3.so"
if [ ! -f "$SOFILE" ]; then
  echo "Building libsqlite3.so from $SQLITE3_C_DIR ..."

  if [ ! -d "$SQLITE3_C_DIR" ]; then
    echo "ERROR: $SQLITE3_C_DIR not found."
    echo "The upstream SQLite split source tree must be present at ../sqlite3/"
    echo "relative to this project root.  Please place it there and re-run."
    exit 1
  fi

  if [ ! -f "$SQLITE3_C_DIR/configure" ] && [ ! -f "$SQLITE3_C_DIR/auto.def" ]; then
    echo "ERROR: $SQLITE3_C_DIR does not look like a SQLite source tree."
    echo "Expected configure or auto.def at the root."
    exit 1
  fi

  (
    cd "$SQLITE3_C_DIR"

    # Clean previous build artefacts if any so we get a fresh .so
    if [ -f Makefile ]; then
      make clean 2>/dev/null || true
    fi

    # autosetup (SQLite >= 3.48) uses ./configure directly; classic autoconf
    # trees also have ./configure.  Either way we can run the same command.
    echo "  Running ./configure ..."
    ./configure \
      --enable-shared \
      CFLAGS="-O2 -fPIC -DSQLITE_DEBUG -DSQLITE_ENABLE_EXPLAIN_COMMENTS -DSQLITE_ENABLE_API_ARMOR"

    echo "  Running make ..."
    make
  )

  # Locate the produced .so — autosetup may place it at the top level or in
  # a sub-directory depending on the version.
  FOUND_SO="$(find "$SQLITE3_C_DIR" -maxdepth 4 -name 'libsqlite3.so*' -type f 2>/dev/null \
              | grep -v '\.so\.' | head -1)"
  if [ -z "$FOUND_SO" ]; then
    # Try versioned names (libsqlite3.so.0)
    FOUND_SO="$(find "$SQLITE3_C_DIR" -maxdepth 4 -name 'libsqlite3.so*' -type f 2>/dev/null \
                | head -1)"
  fi

  if [ -z "$FOUND_SO" ]; then
    echo "ERROR: libsqlite3.so not found under $SQLITE3_C_DIR after build."
    echo "Check that the upstream build succeeded and that --enable-shared was honoured."
    exit 1
  fi

  echo "  Symlinking $FOUND_SO -> $SOFILE"
  ln -sf "$(realpath "$FOUND_SO")" "$SOFILE"
  # Also create libsqlite3.so.0 so that binaries compiled against the system
  # libsqlite3.so (which has SONAME=libsqlite3.so.0) resolve to our oracle
  # when LD_LIBRARY_PATH=src/ is set at test runtime.
  ln -sf "$(realpath "$FOUND_SO")" "$SRC_DIR/libsqlite3.so.0"
  echo "  libsqlite3.so / libsqlite3.so.0 ready at $SRC_DIR"
else
  echo "libsqlite3.so already present, skipping C build."
fi

# ---- Step 2: Compile Pascal test binaries ----
FPC_FLAGS="-O3 -Fu$SRC_DIR -Fi$SRC_DIR -FE$BIN_DIR -Fl$SRC_DIR -k-lm $@"

compile_test() {
  local name="$1"
  local src="$SCRIPT_DIR/$name.pas"
  if [ ! -f "$src" ]; then
    echo "  SKIP $name.pas (not yet implemented)"
    return
  fi
  echo
  echo "Compiling $name.pas ..."
  fpc $FPC_FLAGS "$src"
  echo "$name compiled -> $BIN_DIR/$name"
}

compile_test TestSmoke
compile_test TestOSLayer
compile_test TestUtil
compile_test TestPagerCompat
compile_test TestBtreeCompat
compile_test TestVdbeTrace
compile_test TestExplainParity
compile_test TestSQLCorpus
compile_test TestFuzzDiff
compile_test TestReferenceVectors
compile_test Benchmark

# ---- Step 3: Clean compiled Pascal artefacts ----
find "$SRC_DIR"    -maxdepth 3 \( -name '*.ppu' -o -name '*.o' -o -name '*.compiled' -o -name '*.s' \) -delete
find "$BIN_DIR"    -maxdepth 1 \( -name '*.ppu' -o -name '*.o' -o -name '*.compiled' -o -name '*.s' \) -delete
find "$SCRIPT_DIR" -maxdepth 1 \( -name '*.ppu' -o -name '*.o' -o -name '*.compiled' -o -name '*.s' \) -delete

echo
echo "Build complete."
echo
echo "Run tests with LD_LIBRARY_PATH=$SRC_DIR:"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestSmoke"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestOSLayer"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestUtil"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestReferenceVectors"
