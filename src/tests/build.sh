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
FPC_FLAGS="-O3 -Fu$SRC_DIR -Fi$SRC_DIR -FE$BIN_DIR -Fl$SRC_DIR -k-lm -k-lz $@"

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
compile_test TestPCache
compile_test TestPager
compile_test TestPagerReadOnly
compile_test TestPagerRollback
compile_test TestPagerCrash
compile_test TestPagerCompat
compile_test TestWalCompat
compile_test TestBtreeCompat
compile_test TestVdbeAux
compile_test TestVdbeMem
compile_test TestVdbeCursor
compile_test TestVdbeRecord
compile_test TestVdbeArith
compile_test TestVdbeStr
compile_test TestVdbeAgg
compile_test TestVdbeTxn
compile_test TestVdbeMisc
compile_test TestVdbeApi
compile_test TestPublicApi
compile_test TestVdbeBlob
compile_test TestVdbeSort
compile_test TestVdbeTrace
compile_test TestVdbeVtab
compile_test TestVdbeVtabExec
compile_test TestTokenizer
compile_test TestParserSmoke
compile_test TestParser
compile_test TestWalker
compile_test TestExprBasic
compile_test TestWhereBasic
compile_test TestWhereStructs
compile_test TestWhereSimple
compile_test TestWhereExpr
compile_test TestWherePlanner
compile_test TestSelectBasic
compile_test TestAuthBuiltins
compile_test TestDMLBasic
compile_test TestSchemaBasic
compile_test TestWindowBasic
compile_test TestGroupOrder
compile_test TestJoinNatural
compile_test TestDateModifiers
compile_test TestOpenClose
compile_test TestPrepareBasic
compile_test TestInitCallback
compile_test TestRegistration
compile_test TestPrintf
compile_test TestJson
compile_test TestJsonEach
compile_test TestJsonRegister
compile_test TestVtab
compile_test TestCarray
compile_test TestDbpage
compile_test TestDbstat
compile_test TestConfigHooks
compile_test TestInitShutdown
compile_test TestExecGetTable
compile_test TestBackup
compile_test TestSerialize
compile_test TestUnlockNotify
compile_test TestLoadExt
compile_test TestRowidIn
compile_test TestShellTrustedSchema
compile_test TestUpdateCorrelated
compile_test TestCteOuterID
compile_test TestShellSemiComment
compile_test TestShellEcho
compile_test TestShellParameter
compile_test TestShellChanges
compile_test TestShellModes
compile_test TestShellSchema
compile_test TestShellRepl
compile_test TestShellIO
compile_test TestShellMeta
compile_test TestShellBackup
compile_test TestShellArchive
compile_test TestShellDbinfo
compile_test TestVtabLateral
compile_test TestExplainParity
compile_test TestBytecodeParity
compile_test TestWhereCorpus
compile_test DiagAggWhere
compile_test DiagAnalyze
compile_test DiagAppendvfs
compile_test DiagArith
compile_test DiagAutoIdx
compile_test DiagBloom
compile_test DiagCast
compile_test DiagCollate
compile_test DiagCovering
compile_test DiagColName
compile_test DiagConcat
compile_test DiagCreateIdx
compile_test DiagDate
compile_test DiagDbdump
compile_test DiagDbFileObject
compile_test DiagDequoteToken
compile_test DiagDml
compile_test DiagDropTable
compile_test DiagErrMsg
compile_test DiagErrMsg16
compile_test DiagExplainList
compile_test DiagFeatureProbe
compile_test DiagFloatRender
compile_test DiagFunctions
compile_test DiagGroupOrder
compile_test DiagIndexing
compile_test DiagInnerJoin
compile_test DiagJoinTrace
compile_test DiagLikeGlob
compile_test DiagMisc
compile_test DiagMoreFunc
compile_test DiagMultiValues   # Tasklist 6.10 step 6: constant
                               # multi-row VALUES — runtime PASS today
                               # (count=3) since 6.8.6 follow-up.
compile_test DiagOps
compile_test DiagOrderLimitTopN
compile_test DiagPragma
compile_test DiagPredicates
compile_test DiagPrintfFmt
compile_test DiagPubApi
compile_test DiagRecover       # Phase 10.1.48.c: .recover end-to-end gate.
compile_test DiagSampleProg    # Phase 8.10: canonical SQLite quickstart /
                               # cintro sample programs run through both
                               # the C reference and the Pascal port; gate
                               # asserts byte-identical transcripts.
compile_test DiagScalarFunc
compile_test DiagStrAccum
compile_test DiagSubsel
compile_test DiagSumOverflow
compile_test DiagTempTbl
compile_test DiagTrig          # Tasklist 6.23: AFTER INSERT trigger fire.
                               # Compiles cleanly; running the binary
                               # is expected to ABORT on the Pas side
                               # with a double-free until the
                               # sub-vdbe / parent-vdbe lifecycle
                               # bisect lands.  Kept in the suite to
                               # keep the bug visible.
compile_test DiagTxn           # Tasklist 6.10 step 15(b)/(c):
                               # BEGIN/ROLLBACK + savepoint rollback
                               # divergences (memdb pager regression).
                               # Always wrap runs with `timeout 10`.
compile_test DiagVacuum
compile_test DiagTmstmpvfs
compile_test DiagVfslog
compile_test DiagVfstrace
compile_test DiagWindow        # Tasklist 6.10 step 17: 13 window-fn
                               # divergences gated on 6.26 wiring.
compile_test TestSQLCorpus
compile_test TestFuzzDiff
compile_test TestReferenceVectors
compile_test Benchmark

# ---- Phase 10: passqlite3 CLI tool ----
# Lives under src/, not src/tests/, so compile it directly here rather
# than via compile_test().  Output binary lands at bin/passqlite3.
SHELL_SRC="$SRC_DIR/passqlite3shell.pas"
if [ -f "$SHELL_SRC" ]; then
  echo
  echo "Compiling passqlite3shell.pas ..."
  fpc $FPC_FLAGS "$SHELL_SRC" -opassqlite3
  echo "passqlite3shell compiled -> $BIN_DIR/passqlite3"
fi

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
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestPCache"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestPager"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestPagerReadOnly"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestPagerRollback"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestPagerCrash"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestWalCompat"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestDMLBasic"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestSchemaBasic"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestReferenceVectors
  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestTokenizer"

# ---- Step 4: Run the regression gate (build succeeded if we got here) ----
# `set -e` aborts before this point on any compile error, so reaching here
# means every Pascal binary built cleanly.  Set SKIP_REGRESSION=1 to skip
# (e.g. when iterating on a single test by hand).
if [ "${SKIP_REGRESSION:-0}" = "1" ]; then
  echo
  echo "SKIP_REGRESSION=1 set — skipping regression gate."
else
  echo
  echo "Build succeeded — running regression gate."
  echo
  # Don't let a failing test abort the script before we've shown the summary.
  set +e
  "$SCRIPT_DIR/run_regression.sh"
  regression_rc=$?
  set -e
  exit "$regression_rc"
fi
