{$IFDEF FPC}
  {$MODE OBJFPC}
  {$H+}
  {$INLINE ON}
  {$GOTO ON}           // VDBE dispatch may benefit; parser definitely will
  {$COPERATORS ON}
  {$MACRO ON}
  {$CODEPAGE UTF8}
  {$POINTERMATH ON}    // u8* / PByte arithmetic everywhere
  {$ASMMODE INTEL}
  {$Q-}                // disable overflow checking — SQLite relies on wrap
  {$R-}                // disable range checking for the same reason
  {$IFDEF CPU32BITS} {$DEFINE CPU32} {$ENDIF}
  {$IFDEF CPU64BITS} {$DEFINE CPU64} {$ENDIF}
  {$IFDEF CPUARM}     {$DEFINE NOTAVX} {$ENDIF}
  {$IFDEF CPUAARCH64} {$DEFINE NOTAVX} {$ENDIF}
  // Performance optimisations (Phase 11)
  {$OPTIMIZATION REGVAR}
  {$OPTIMIZATION CSE}
  {$OPTIMIZATION DFA}
  {$OPTIMIZATION CONSTPROP}
{$ELSE}
  {$IFDEF CPU32BITS} {$DEFINE CPU32} {$ENDIF}
  {$IFDEF CPU64BITS} {$DEFINE CPU64} {$ENDIF}
{$ENDIF}

{
  Compile-time configuration summary for the Pascal port of SQLite 3.53.0.

  Target configuration (matches upstream plain ./configure && make + SQLITE_DEBUG
  for oracle build only):

    Enabled (upstream defaults):
      SQLITE_THREADSAFE=1        (serialized — full mutex)
      SQLITE_ENABLE_MATH_FUNCTIONS
      SQLITE_ENABLE_FTS5         (flag on; module out-of-scope for initial port)

    Disabled for v1:
      SQLITE_OMIT_LOAD_EXTENSION
      SQLITE_OMIT_DEPRECATED
      (all SQLITE_ENABLE_* that pull in ext/ modules)

    Oracle-build only (libsqlite3.so built with CFLAGS in build.sh):
      SQLITE_DEBUG
      SQLITE_ENABLE_EXPLAIN_COMMENTS
      SQLITE_ENABLE_API_ARMOR
{$DEFINE SQLITE_OMIT_AUTOINIT}
}

{
  10.1.42.d — SQLITE_DEBUG gate for the Pascal port.

  Default builds (src/tests/build.sh without SQLITE_DEBUG=1 in the
  environment) leave SQLITE_DEBUG *undefined*, so every
  `{$IFDEF SQLITE_DEBUG} ... {$ENDIF}` consumer block compiles out to a
  silent no-op — preserving non-debug parity with upstream's plain
  `./configure && make` build of the C reference.

  To opt in (e.g. for the future 10.1.42.a/b TREETRACE/WHERETRACE
  consumer arms, or for `OSTRACE` / `IOTRACE` if those land), run:

      SQLITE_DEBUG=1 ./src/tests/build.sh

  build.sh forwards that to fpc as `-dSQLITE_DEBUG`, which makes
  `{$IFDEF SQLITE_DEBUG}` blocks active for *all* Pascal units in the
  port (so emission lights up in codegen / where / vdbe alike, just
  like upstream's `-DSQLITE_DEBUG` flips the same switch across the
  whole C tree).

  This gate mirrors upstream sqliteInt.h:1127/1166 where TREETRACE /
  WHERETRACE bodies are themselves `#ifdef SQLITE_DEBUG`; defining the
  macro here flips them on, leaving it undefined leaves them inert.
}
