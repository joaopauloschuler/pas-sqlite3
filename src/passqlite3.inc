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
