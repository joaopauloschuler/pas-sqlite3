{$I passqlite3.inc}
unit passqlite3main;

{
  Phase 8.1 — Connection lifecycle (main.c subset).

  Public entry points:
    sqlite3_open       — open a database (READWRITE | CREATE)
    sqlite3_open_v2    — open a database with explicit flags + VFS name
    sqlite3_close      — close (legacy: refuses if statements outstanding)
    sqlite3_close_v2   — close (zombifies if statements outstanding)

  Internal helpers (mirror main.c names where practical):
    openDatabase                  — main allocation / setup path
    sqlite3Close                  — common close machinery
    sqlite3LeaveMutexAndCloseZombie — final tear-down
    connectionIsBusy              — detects pending Vdbe / backup state

  Scope of this initial port (Phase 8.1, 2026-04-25):
    * No URI parsing (zFilename is passed straight to BtreeOpen).
    * No shared-cache, no virtual-table list, no extension list.
    * No lookaside (db^.lookaside.bDisable = 1, sz = 0).
    * No WAL autocheckpoint wiring (the WAL layer ignores it currently).
    * No mutex allocation — db^.mutex stays nil.  Single-threaded use only.
    * Schema slots 0 and 1 are allocated via sqlite3SchemaGet(db, nil),
      not fetched from the BtShared (sqlite3BtreeSchema is not yet ported).
    * Collation registration (BINARY/NOCASE/RTRIM) is delegated to
      sqlite3RegisterPerConnectionBuiltinFunctions when available; the
      explicit createCollation calls from main.c openDatabase are skipped.

  These gaps are expected to close in Phase 8.2 (prepare_v2 wiring) and
  Phase 8.3+ (registration APIs, hooks, lookaside).
}

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser,  { Phase 8.2 — real sqlite3RunParser }
  passqlite3vtab;    { Phase 6.bis.1a — module/VTable lifecycle }

type
  PPTsqlite3 = ^PTsqlite3;

{ ----------------------------------------------------------------------
  SQLITE_STATE_* — db^.eOpenState magic values (sqliteInt.h:1951).
  ---------------------------------------------------------------------- }
const
  SQLITE_STATE_OPEN   = $76;  { Database is open }
  SQLITE_STATE_CLOSED = $CE;  { Database is closed }
  SQLITE_STATE_SICK   = $BA;  { Error and awaiting close }
  SQLITE_STATE_BUSY   = $6D;  { Database currently in use }
  SQLITE_STATE_ERROR  = $D5;  { An SQLITE_MISUSE error occurred }
  SQLITE_STATE_ZOMBIE = $A7;  { Close with last statement close }

{ ----------------------------------------------------------------------
  Phase 8.4 — public sqlite3.h DBCONFIG / CONFIG opcode values.
  ---------------------------------------------------------------------- }
const
  SQLITE_DBCONFIG_MAINDBNAME            = 1000;
  SQLITE_DBCONFIG_LOOKASIDE             = 1001;
  SQLITE_DBCONFIG_ENABLE_FKEY           = 1002;
  SQLITE_DBCONFIG_ENABLE_TRIGGER        = 1003;
  SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER = 1004;
  SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION = 1005;
  SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE      = 1006;
  SQLITE_DBCONFIG_ENABLE_QPSG           = 1007;
  SQLITE_DBCONFIG_TRIGGER_EQP           = 1008;
  SQLITE_DBCONFIG_RESET_DATABASE        = 1009;
  SQLITE_DBCONFIG_DEFENSIVE             = 1010;
  SQLITE_DBCONFIG_WRITABLE_SCHEMA       = 1011;
  SQLITE_DBCONFIG_LEGACY_ALTER_TABLE    = 1012;
  SQLITE_DBCONFIG_DQS_DML               = 1013;
  SQLITE_DBCONFIG_DQS_DDL               = 1014;
  SQLITE_DBCONFIG_ENABLE_VIEW           = 1015;
  SQLITE_DBCONFIG_LEGACY_FILE_FORMAT    = 1016;
  SQLITE_DBCONFIG_TRUSTED_SCHEMA        = 1017;
  SQLITE_DBCONFIG_STMT_SCANSTATUS       = 1018;
  SQLITE_DBCONFIG_REVERSE_SCANORDER     = 1019;
  SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE  = 1020;
  SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE   = 1021;
  SQLITE_DBCONFIG_ENABLE_COMMENTS       = 1022;
  SQLITE_DBCONFIG_FP_DIGITS             = 1023;

  SQLITE_CONFIG_SINGLETHREAD = 1;
  SQLITE_CONFIG_MULTITHREAD  = 2;
  SQLITE_CONFIG_SERIALIZED   = 3;
  SQLITE_CONFIG_MEMSTATUS    = 9;
  SQLITE_CONFIG_URI          = 17;
  SQLITE_CONFIG_COVERING_INDEX_SCAN = 20;
  SQLITE_CONFIG_STMTJRNL_SPILL = 26;
  SQLITE_CONFIG_SMALL_MALLOC = 27;
  SQLITE_CONFIG_SORTERREF_SIZE = 28;
  SQLITE_CONFIG_MEMDB_MAXSIZE  = 29;

{ ----------------------------------------------------------------------
  Public API
  ---------------------------------------------------------------------- }

function sqlite3_open(zFilename: PAnsiChar; ppDb: PPTsqlite3): i32;
function sqlite3_open_v2(zFilename: PAnsiChar; ppDb: PPTsqlite3;
                          flags: i32; zVfs: PAnsiChar): i32;
function sqlite3_close(db: PTsqlite3): i32;
function sqlite3_close_v2(db: PTsqlite3): i32;

{ Phase 8.2 — sqlite3_prepare family (prepare.c). }
function sqlite3_prepare(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                         ppStmt: PPointer; pzTail: PPAnsiChar): i32;
function sqlite3_prepare_v2(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                            ppStmt: PPointer; pzTail: PPAnsiChar): i32;
function sqlite3_prepare_v3(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                            prepFlags: u32; ppStmt: PPointer;
                            pzTail: PPAnsiChar): i32;

{ Phase 8.3 — registration APIs (main.c, vtab.c). }
function sqlite3_create_function(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer): i32;
function sqlite3_create_function_v2(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer;
  xDestroy: Pointer): i32;
function sqlite3_create_window_function(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xStep: Pointer; xFinal: Pointer; xValue: Pointer; xInverse: Pointer;
  xDestroy: Pointer): i32;

function sqlite3_create_collation(db: PTsqlite3; zName: PAnsiChar;
  enc: i32; pCtx: Pointer; xCompare: Pointer): i32;
function sqlite3_create_collation_v2(db: PTsqlite3; zName: PAnsiChar;
  enc: i32; pCtx: Pointer; xCompare: Pointer; xDel: Pointer): i32;
function sqlite3_collation_needed(db: PTsqlite3;
  pCollNeededArg: Pointer; xCollNeeded: Pointer): i32;

function sqlite3_create_module(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer): i32;
function sqlite3_create_module_v2(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer; xDestroy: Pointer): i32;

{ Phase 8.4 — configuration and hooks (main.c). }

{ Busy handler / timeout. }
function sqlite3_busy_handler(db: PTsqlite3;
  xBusy: Pointer; pArg: Pointer): i32;
function sqlite3_busy_timeout(db: PTsqlite3; ms: i32): i32;

{ Hooks: each returns the previously-installed pArg (or nil). }
function sqlite3_commit_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
function sqlite3_rollback_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
function sqlite3_update_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;

{ Trace v2.  Combinations of SQLITE_TRACE_STMT/PROFILE/ROW/CLOSE. }
function sqlite3_trace_v2(db: PTsqlite3; mTrace: u32;
  xTrace: Pointer; pArg: Pointer): i32;

{ db_config — Pascal-friendly typed entry points (no C varargs).
  The varargs C signature collapses into three argument shapes; we expose
  one entry point per shape.  Phase 8.4 covers MAINDBNAME / FP_DIGITS /
  LOOKASIDE / all flag-toggle ops in main.c:982. }
function sqlite3_db_config_text(db: PTsqlite3; op: i32;
  zName: PAnsiChar): i32;
function sqlite3_db_config_lookaside(db: PTsqlite3; op: i32;
  pBuf: Pointer; sz: i32; cnt: i32): i32;
function sqlite3_db_config_int(db: PTsqlite3; op: i32;
  onoff: i32; pRes: Pi32): i32;

{ config — int-shape entry point.  passqlite3util already provides the
  pointer-shape sqlite3_config(op, pArg) (overloaded); this adds the
  int-shape used by SQLITE_CONFIG_MEMSTATUS / SINGLETHREAD / etc. }
function sqlite3_config(op: i32; arg: i32): i32; overload;

{ Phase 8.5 — library-wide initialize / shutdown (main.c:190 / :372). }
function sqlite3_initialize: i32;
function sqlite3_shutdown:   i32;

{ Phase 8.6 — legacy.c (sqlite3_exec) + table.c (get_table / free_table). }

type
  Tsqlite3_callback = function(pArg: Pointer; nCol: i32;
                               argv: PPAnsiChar;
                               colv: PPAnsiChar): i32; cdecl;
  PPPAnsiChar = ^PPAnsiChar;

{ sqlite3_errmsg — minimal port: returns the textual form of db^.errCode.
  The full main.c version consults db^.pErr (a sqlite3_value), which is not
  populated by our codegen yet (sqlite3ErrorWithMsg only stores the code).
  Returning sqlite3ErrStr(errCode) is what main.c falls back to when
  pErr is nil, so this is byte-correct for that path. }
function sqlite3_errmsg(db: PTsqlite3): PAnsiChar;

function sqlite3_exec(db: PTsqlite3; zSql: PAnsiChar;
                      xCallback: Tsqlite3_callback; pArg: Pointer;
                      pzErrMsg: PPAnsiChar): i32;

function sqlite3_get_table(db: PTsqlite3; zSql: PAnsiChar;
                           pazResult: PPPAnsiChar;
                           pnRow: Pi32; pnColumn: Pi32;
                           pzErrMsg: PPAnsiChar): i32;
procedure sqlite3_free_table(azResult: PPAnsiChar);

{ ----------------------------------------------------------------------
  Phase 8.8 — sqlite3_unlock_notify (notify.c).

  Upstream's notify.c is wrapped in `#ifdef SQLITE_ENABLE_UNLOCK_NOTIFY`,
  and our build configuration leaves that macro off (see passqlite3util's
  Tsqlite3 record: pBlockingConnection / pUnlockConnection / xUnlockNotify
  fields are intentionally omitted).  In that build mode the C library
  does not emit notify.c at all; SQLite consumers that need the symbol
  must compile with the macro on.

  We expose the symbol anyway as a tiny shim because: (1) the unlock-
  notify semantics on a single connection / no-shared-cache port are
  trivial — there can never be a blocking peer connection in this
  environment, so the callback is always safe to fire immediately;
  (2) consumers that always link `sqlite3_unlock_notify` (e.g. a Pascal
  wrapper that mirrors the public API verbatim) keep working without
  conditional compilation on their side.  This matches the documented
  fast-path in notify.c:167 ("0==db->pBlockingConnection → invoke the
  notify callback immediately").
  ---------------------------------------------------------------------- }
type
  Tsqlite3_unlock_notify_cb = procedure(apArg: PPointer; nArg: i32); cdecl;

function sqlite3_unlock_notify(db: PTsqlite3;
                               xNotify: Tsqlite3_unlock_notify_cb;
                               pArg: Pointer): i32;

{ ----------------------------------------------------------------------
  Phase 8.9 — loadext.c (sqlite3_load_extension family).

  Build configuration sets SQLITE_OMIT_LOAD_EXTENSION (see Phase 0.12 in
  passqlite3.inc), so upstream's loadext.c emits *only* the auto-extension
  surface (sqlite3_auto_extension / _cancel_auto_extension /
  _reset_auto_extension); the DLL-loading path
  (sqlite3_load_extension / sqlite3_enable_load_extension) is `#ifndef`-
  guarded out.  We expose the symbols anyway as thin shims:

    * sqlite3_load_extension      → SQLITE_ERROR + "extension loading is
                                    disabled" message, matching the
                                    documented behaviour in the OMIT build.
    * sqlite3_enable_load_extension → flips the db->flags bit faithfully,
                                    so DBCONFIG_ENABLE_LOAD_EXTENSION
                                    parity is preserved (a flag with no
                                    loader behind it is harmless).
    * sqlite3_auto_extension      → faithful port of loadext.c:808.
    * sqlite3_cancel_auto_extension → faithful port of loadext.c:858.
    * sqlite3_reset_auto_extension  → faithful port of loadext.c:886.

  The auto-extension list is *process-global* in the C code (a static
  WSD array protected by SQLITE_MUTEX_STATIC_MAIN).  We mirror that with
  a `var`-level dynamic array protected by the same static main mutex.
  ---------------------------------------------------------------------- }
type
  Tsqlite3_loadext_fn = procedure; cdecl;

function sqlite3_load_extension(db: PTsqlite3;
                                zFile, zProc: PAnsiChar;
                                pzErrMsg: PPAnsiChar): i32;
function sqlite3_enable_load_extension(db: PTsqlite3; onoff: i32): i32;

function sqlite3_auto_extension(xInit: Tsqlite3_loadext_fn): i32;
function sqlite3_cancel_auto_extension(xInit: Tsqlite3_loadext_fn): i32;
procedure sqlite3_reset_auto_extension;

implementation

{ ----------------------------------------------------------------------
  aHardLimit — default per-connection limits (mirrors main.c aHardLimit).
  Order matches SQLITE_LIMIT_* indices in passqlite3codegen.
  ---------------------------------------------------------------------- }
const
  SQLITE_MAX_LENGTH                = 1000000000;
  SQLITE_MAX_SQL_LENGTH            = 1000000000;
  SQLITE_MAX_COLUMN_LIMIT          = 2000;
  SQLITE_MAX_EXPR_DEPTH_LIMIT      = 1000;
  SQLITE_MAX_COMPOUND_SELECT       = 500;
  SQLITE_MAX_VDBE_OP               = 250000000;
  SQLITE_MAX_FUNCTION_ARG          = 127;
  SQLITE_MAX_ATTACHED              = 10;
  SQLITE_MAX_LIKE_PATTERN_LENGTH   = 50000;
  SQLITE_MAX_VARIABLE_NUMBER       = 32766;
  SQLITE_MAX_TRIGGER_DEPTH         = 1000;
  SQLITE_MAX_WORKER_THREADS_LIMIT  = 8;
  SQLITE_DEFAULT_WORKER_THREADS    = 0;

const
  aHardLimit: array[0..11] of i32 = (
    SQLITE_MAX_LENGTH,
    SQLITE_MAX_SQL_LENGTH,
    SQLITE_MAX_COLUMN_LIMIT,
    SQLITE_MAX_EXPR_DEPTH_LIMIT,
    SQLITE_MAX_COMPOUND_SELECT,
    SQLITE_MAX_VDBE_OP,
    SQLITE_MAX_FUNCTION_ARG,
    SQLITE_MAX_ATTACHED,
    SQLITE_MAX_LIKE_PATTERN_LENGTH,
    SQLITE_MAX_VARIABLE_NUMBER,
    SQLITE_MAX_TRIGGER_DEPTH,
    SQLITE_MAX_WORKER_THREADS_LIMIT
  );

{ ----------------------------------------------------------------------
  connectionIsBusy — true if the connection has unfinalised statements.
  main.c:1240
  ---------------------------------------------------------------------- }
function connectionIsBusy(db: PTsqlite3): i32;
begin
  if db^.pVdbe <> nil then begin Result := 1; Exit; end;
  Result := 0;
end;

{ ----------------------------------------------------------------------
  sqlite3LeaveMutexAndCloseZombie — final tear-down.
  main.c:1363  (simplified for Phase 8.1 scope)
  ---------------------------------------------------------------------- }
procedure sqlite3LeaveMutexAndCloseZombie(db: PTsqlite3);
var
  j: i32;
begin
  if (db^.eOpenState <> SQLITE_STATE_ZOMBIE) or (connectionIsBusy(db) <> 0) then
    Exit;

  { Roll back any open transaction and reset schemas. }
  sqlite3RollbackAll(db, SQLITE_OK);

  { Free any outstanding savepoints. }
  sqlite3CloseSavepoints(db);

  { Close all attached database back-ends. }
  for j := 0 to db^.nDb - 1 do begin
    if db^.aDb[j].pBt <> nil then begin
      sqlite3BtreeClose(PBtree(db^.aDb[j].pBt));
      db^.aDb[j].pBt := nil;
      if j <> 1 then
        db^.aDb[j].pSchema := nil;
    end;
  end;

  { Clear the temp-db schema separately (allocated independently). }
  if db^.aDb[1].pSchema <> nil then begin
    sqlite3SchemaClear(db^.aDb[1].pSchema);
  end;

  { Collapse aDb back to the static array (no-op when nDb<=2). }
  sqlite3CollapseDatabaseArray(db);

  { Clear the per-connection hash tables. }
  sqlite3HashClear(@db^.aFunc);
  sqlite3HashClear(@db^.aCollSeq);
  sqlite3HashClear(@db^.aModule);

  { Deallocate the cached error string, if any. }
  sqlite3Error(db, SQLITE_OK);
  if db^.pErr <> nil then begin
    sqlite3ValueFree(Psqlite3_value(db^.pErr));
    db^.pErr := nil;
  end;

  { Free the temp-schema record itself (allocated via sqlite3DbMallocZero). }
  if db^.aDb[1].pSchema <> nil then begin
    sqlite3DbFree(Psqlite3db(db), db^.aDb[1].pSchema);
    db^.aDb[1].pSchema := nil;
  end;

  db^.eOpenState := SQLITE_STATE_CLOSED;
  if db^.mutex <> nil then
    sqlite3_mutex_free(db^.mutex);
  sqlite3_free(db);
end;

{ ----------------------------------------------------------------------
  sqlite3Close — common close path shared by sqlite3_close{,v2}.
  main.c:1254
  ---------------------------------------------------------------------- }
function sqlite3Close(db: PTsqlite3; forceZombie: i32): i32;
begin
  if db = nil then begin
    { R-63257-11740: NULL is a harmless no-op. }
    Result := SQLITE_OK;
    Exit;
  end;
  if sqlite3SafetyCheckSickOrOk(db) = 0 then begin
    Result := SQLITE_MISUSE;
    Exit;
  end;

  { Legacy sqlite3_close() refuses if statements still pending. }
  if (forceZombie = 0) and (connectionIsBusy(db) <> 0) then begin
    sqlite3ErrorWithMsg(db, SQLITE_BUSY,
      'unable to close due to unfinalized statements or unfinished backups');
    Result := SQLITE_BUSY;
    Exit;
  end;

  db^.eOpenState := SQLITE_STATE_ZOMBIE;
  sqlite3LeaveMutexAndCloseZombie(db);
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  openDatabase — main.c:3324
  ---------------------------------------------------------------------- }
function openDatabase(zFilename: PAnsiChar; ppDb: PPTsqlite3;
                      flags: i32; zVfs: PAnsiChar): i32;
var
  db   : PTsqlite3;
  rc   : i32;
  i    : i32;
  pVfs : Psqlite3_vfs;
  label opendb_out;
begin
  if ppDb = nil then begin Result := SQLITE_MISUSE; Exit; end;
  ppDb^ := nil;

  { Strip non-public flag bits, just like main.c:3371 does. }
  flags := flags and not (
      SQLITE_OPEN_DELETEONCLOSE or
      SQLITE_OPEN_EXCLUSIVE     or
      SQLITE_OPEN_MAIN_DB       or
      SQLITE_OPEN_TEMP_DB       or
      SQLITE_OPEN_TRANSIENT_DB  or
      SQLITE_OPEN_MAIN_JOURNAL  or
      SQLITE_OPEN_TEMP_JOURNAL  or
      SQLITE_OPEN_SUBJOURNAL    or
      SQLITE_OPEN_SUPER_JOURNAL or
      SQLITE_OPEN_NOMUTEX       or
      SQLITE_OPEN_FULLMUTEX     or
      SQLITE_OPEN_WAL);

  db := PTsqlite3(sqlite3MallocZero(SizeOf(Tsqlite3)));
  if db = nil then begin Result := SQLITE_NOMEM; Exit; end;

  if (flags and SQLITE_OPEN_EXRESCODE) <> 0 then
    db^.errMask := i32($FFFFFFFF)
  else
    db^.errMask := i32($FF);

  db^.nDb            := 2;
  db^.eOpenState     := SQLITE_STATE_BUSY;
  db^.aDb            := @db^.aDbStatic[0];
  db^.lookaside.bDisable := 1;
  db^.lookaside.sz   := 0;
  db^.nFpDigit       := 17;
  db^.openFlags      := u32(flags);

  { Install per-connection limits from aHardLimit. }
  for i := 0 to High(aHardLimit) do
    db^.aLimit[i] := aHardLimit[i];
  db^.aLimit[SQLITE_LIMIT_WORKER_THREADS] := SQLITE_DEFAULT_WORKER_THREADS;

  db^.autoCommit  := 1;
  db^.nextAutovac := -1;
  db^.szMmap      := 0;
  db^.nextPagesize := 0;
  db^.init.azInit := nil;

  db^.flags := db^.flags or
    (u64($00040) shl 32) or  { SQLITE_Comments — keep TestParser's flag bit }
    (u64($00001) shl 32);    { SQLITE_ShortColNames }

  sqlite3HashInit(@db^.aCollSeq);
  sqlite3HashInit(@db^.aModule);
  sqlite3HashInit(@db^.aFunc);

  { Locate the requested VFS.  Lazily run sqlite3_os_init the first
    time around — main.c does this via sqlite3_initialize(). }
  pVfs := sqlite3_vfs_find(zVfs);
  if pVfs = nil then begin
    sqlite3_os_init;
    sqlite3PcacheInitialize;
    pVfs := sqlite3_vfs_find(zVfs);
  end;
  if pVfs = nil then begin
    rc := SQLITE_ERROR;
    sqlite3ErrorWithMsg(db, rc, 'no such vfs');
    goto opendb_out;
  end;
  db^.pVfs := pVfs;

  { Validate flags{0..2} — must be exactly READONLY, READWRITE, or
    READWRITE|CREATE.  Mirrors main.c:3556. }
  if ((1 shl (flags and 7)) and $46) = 0 then begin
    rc := SQLITE_MISUSE;
    goto opendb_out;
  end;

  if (zFilename = nil) or (zFilename[0] = #0) then
    zFilename := ':memory:';

  { Open the back-end b-tree. }
  rc := sqlite3BtreeOpen(pVfs, PChar(zFilename), Psqlite3(db),
                         PPBtree(@db^.aDb[0].pBt), 0,
                         flags or SQLITE_OPEN_MAIN_DB);
  if rc <> SQLITE_OK then begin
    sqlite3Error(db, rc);
    goto opendb_out;
  end;

  { Allocate stand-in schemas for main and temp.  Phase 8.1 stub:
    sqlite3BtreeSchema is not ported, so we do not pull from BtShared. }
  db^.aDb[0].pSchema := sqlite3SchemaGet(db, nil);
  db^.aDb[1].pSchema := sqlite3SchemaGet(db, nil);

  db^.aDb[0].zDbSName     := 'main';
  db^.aDb[0].safety_level := 3;     { FULL — matches PAGER_SYNCHRONOUS_FULL }
  db^.aDb[1].zDbSName     := 'temp';
  db^.aDb[1].safety_level := 1;     { OFF }

  { Phase 6.x — nested-parse schema visibility: bootstrap sqlite_master /
    sqlite_temp_master into the in-memory schema so the schema-row UPDATE /
    INSERT / DELETE statements emitted by sqlite3NestedParse (from
    sqlite3EndTable, sqlite3CreateIndex, sqlite3CodeDropTable, etc.) can
    resolve their target via sqlite3SrcListLookup -> sqlite3LocateTableItem.
    Real on-disk schema initialisation (sqlite3InitOne port) lands in
    Phase 7. }
  sqlite3InstallSchemaTable(db, 0);
  sqlite3InstallSchemaTable(db, 1);

  { sqlite3SetTextEncoding consults collation tables, which require the full
    Phase 8.3 registration APIs.  Set the encoding directly for now. }
  db^.enc := SQLITE_UTF8;

  db^.eOpenState := SQLITE_STATE_OPEN;

  { Register per-connection built-ins (collations + scalar/aggregate funcs). }
  sqlite3RegisterPerConnectionBuiltinFunctions(db);

  sqlite3Error(db, SQLITE_OK);
  rc := SQLITE_OK;

opendb_out:
  if (rc and $FF) = SQLITE_NOMEM then begin
    sqlite3_close(db);
    db := nil;
  end else if rc <> SQLITE_OK then begin
    if db <> nil then db^.eOpenState := SQLITE_STATE_SICK;
  end;
  ppDb^  := db;
  Result := rc;
end;

{ ----------------------------------------------------------------------
  Public API entry points.
  ---------------------------------------------------------------------- }
function sqlite3_open(zFilename: PAnsiChar; ppDb: PPTsqlite3): i32;
begin
  Result := openDatabase(zFilename, ppDb,
              SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
end;

function sqlite3_open_v2(zFilename: PAnsiChar; ppDb: PPTsqlite3;
                          flags: i32; zVfs: PAnsiChar): i32;
begin
  Result := openDatabase(zFilename, ppDb, flags, zVfs);
end;

function sqlite3_close(db: PTsqlite3): i32;
begin
  Result := sqlite3Close(db, 0);
end;

function sqlite3_close_v2(db: PTsqlite3): i32;
begin
  Result := sqlite3Close(db, 1);
end;

{ ----------------------------------------------------------------------
  Phase 8.2 — sqlite3_prepare / sqlite3_prepare_v2 / sqlite3_prepare_v3
  Ported from prepare.c:682 (sqlite3Prepare), :836 (sqlite3LockAndPrepare),
  :925 (sqlite3_prepare), :937 (sqlite3_prepare_v2), :955 (sqlite3_prepare_v3).

  Scope of this Phase 8.2 port:
    * Single-attempt compile.  The C version retries on SQLITE_SCHEMA via
      sqlite3ResetOneSchema, but the schema-cookie subsystem is not yet
      ported — there is no schema state to reset, so the retry loop is
      reduced to one pass.
    * Schema-locked check (BtreeSchemaLocked) skipped — the codegen stub
      always returns 0 and there is no shared cache.
    * Vtab unlock list skipped (no vtabs registered).
    * Btree mutex enter/leave still goes via the codegen stubs (no-op).
    * Long-statement copy (when the caller passes a non-NUL-terminated
      buffer with explicit nBytes) is faithfully reproduced — we duplicate
      the SQL into a NUL-terminated buffer before handing it to the
      parser, then translate the parser's zTail back into the caller's
      buffer offset.
  ---------------------------------------------------------------------- }

const
  SQLITE_MAX_PREPARE_RETRY    = 25;
  SQLITE_PREPARE_PERSISTENT   = $01;  { sqlite3.h public flag bit }
  SQLITE_PREPARE_NORMALIZE    = $02;
  SQLITE_PREPARE_NO_VTAB      = $04;

function sqlite3Prepare(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                        prepFlags: u32; pReprepare: PVdbe;
                        ppStmt: PPointer; pzTail: PPAnsiChar): i32;
var
  rc:       i32;
  sParse:   TParse;
  zSqlCopy: PAnsiChar;
  mxLen:    i32;
  nDup:     i32;
  pT:       PTriggerPrg;
  label end_prepare;
begin
  rc := SQLITE_OK;

  { Inline sqlite3ParseObjectInit + zero the rest of TParse (PARSE_TAIL). }
  FillChar(sParse, SizeOf(sParse), 0);
  sParse.pOuterParse := db^.pParse;
  db^.pParse         := @sParse;
  sParse.db          := db;
  if pReprepare <> nil then begin
    sParse.pReprepare := pReprepare;
    sParse.explain    := u8(sqlite3_stmt_isexplain(Pointer(pReprepare)));
  end;

  Assert((ppStmt <> nil) and (ppStmt^ = nil));
  if db^.mallocFailed <> 0 then begin
    sqlite3ErrorMsg(@sParse, 'out of memory');
    db^.errCode := SQLITE_NOMEM;
    rc          := SQLITE_NOMEM;
    goto end_prepare;
  end;

  { Long-term prepared statements bypass lookaside. }
  if (prepFlags and SQLITE_PREPARE_PERSISTENT) <> 0 then begin
    Inc(sParse.disableLookaside);
    Inc(db^.lookaside.bDisable);
    db^.lookaside.sz := 0;
  end;
  sParse.prepFlags := u8(prepFlags and $FF);

  { Schema-locked check: codegen stub always returns 0; left as a
    documented no-op until shared-cache lands. }

  if (nBytes >= 0) and ((nBytes = 0) or (zSql[nBytes - 1] <> #0)) then begin
    mxLen := db^.aLimit[SQLITE_LIMIT_SQL_LENGTH];
    if nBytes > mxLen then begin
      sqlite3ErrorWithMsg(db, SQLITE_TOOBIG, 'statement too long');
      rc := sqlite3ApiExit(db, SQLITE_TOOBIG);
      goto end_prepare;
    end;
    nDup     := nBytes;
    zSqlCopy := PAnsiChar(sqlite3DbStrNDup(db, PChar(zSql), u64(nDup)));
    if zSqlCopy <> nil then begin
      sqlite3RunParser(@sParse, zSqlCopy);
      { Translate zTail back from copy-relative to caller-relative. }
      sParse.zTail := zSql + (PtrUInt(sParse.zTail) - PtrUInt(zSqlCopy));
      sqlite3DbFree(db, zSqlCopy);
    end else begin
      sParse.zTail := zSql + nBytes;
    end;
  end else begin
    sqlite3RunParser(@sParse, zSql);
  end;
  Assert(sParse.nQueryLoop = 0);

  if pzTail <> nil then
    pzTail^ := sParse.zTail;

  if (db^.init.busy = 0) and (sParse.pVdbe <> nil) then
    sqlite3VdbeSetSql(sParse.pVdbe, zSql,
                      i32(PtrUInt(sParse.zTail) - PtrUInt(zSql)),
                      u8(prepFlags and $FF));

  if db^.mallocFailed <> 0 then begin
    sParse.rc := SQLITE_NOMEM;
    sParse.parseFlags := sParse.parseFlags and (not u32($200)); { clear checkSchema }
  end;

  if (sParse.rc <> SQLITE_OK) and (sParse.rc <> SQLITE_DONE) then begin
    { schemaIsValid path skipped — no schema-cookie machinery yet. }
    if sParse.pVdbe <> nil then
      sqlite3VdbeFinalize(sParse.pVdbe);
    Assert(ppStmt^ = nil);
    rc := sParse.rc;
    if sParse.zErrMsg <> nil then begin
      sqlite3ErrorWithMsg(db, rc, PAnsiChar(sParse.zErrMsg));
      sqlite3DbFree(db, sParse.zErrMsg);
      sParse.zErrMsg := nil;
    end else begin
      sqlite3Error(db, rc);
    end;
  end else begin
    Assert(sParse.zErrMsg = nil);
    ppStmt^ := Pointer(sParse.pVdbe);
    rc      := SQLITE_OK;
    sqlite3ErrorClear(db);
  end;

  { Free any TriggerPrg structures allocated by the parser. }
  while sParse.pTriggerPrg <> nil do begin
    pT := sParse.pTriggerPrg;
    sParse.pTriggerPrg := pT^.pNext;
    sqlite3DbFree(db, pT);
  end;

end_prepare:
  sqlite3ParseObjectReset(@sParse);
  Result := rc;
end;

function sqlite3LockAndPrepare(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                               prepFlags: u32; pOld: PVdbe;
                               ppStmt: PPointer; pzTail: PPAnsiChar): i32;
var
  rc, cnt: i32;
begin
  if ppStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  ppStmt^ := nil;
  if (sqlite3SafetyCheckOk(db) = 0) or (zSql = nil) then begin
    Result := SQLITE_MISUSE;
    Exit;
  end;
  cnt := 0;
  sqlite3BtreeEnterAll(db);
  repeat
    rc := sqlite3Prepare(db, zSql, nBytes, prepFlags, pOld, ppStmt, pzTail);
    Assert((rc = SQLITE_OK) or (ppStmt^ = nil));
    if (rc = SQLITE_OK) or (db^.mallocFailed <> 0) then Break;
    Inc(cnt);
    { sqlite3ResetOneSchema not yet ported — bail after one retry on
      SQLITE_ERROR_RETRY only. }
    if (rc <> SQLITE_ERROR_RETRY) or (cnt > SQLITE_MAX_PREPARE_RETRY) then
      Break;
  until False;
  sqlite3BtreeLeaveAll(db);
  rc := sqlite3ApiExit(db, rc);
  db^.busyHandler.nBusy := 0;
  Result := rc;
end;

function sqlite3_prepare(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                         ppStmt: PPointer; pzTail: PPAnsiChar): i32;
begin
  Result := sqlite3LockAndPrepare(db, zSql, nBytes, 0, nil, ppStmt, pzTail);
end;

function sqlite3_prepare_v2(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                            ppStmt: PPointer; pzTail: PPAnsiChar): i32;
begin
  Result := sqlite3LockAndPrepare(db, zSql, nBytes,
                                  SQLITE_PREPARE_SAVESQL, nil, ppStmt, pzTail);
end;

function sqlite3_prepare_v3(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                            prepFlags: u32; ppStmt: PPointer;
                            pzTail: PPAnsiChar): i32;
begin
  Result := sqlite3LockAndPrepare(db, zSql, nBytes,
              (prepFlags and SQLITE_PREPARE_MASK) or SQLITE_PREPARE_SAVESQL,
              nil, ppStmt, pzTail);
end;

{ ----------------------------------------------------------------------
  Phase 8.3 — Registration APIs.
  Ported from main.c:1931..2230 (functions), main.c:2852..3848 (collations),
  vtab.c:39..134 (modules).

  Scope of this Phase 8.3 port:
    * sqlite3_create_function / _v2 / _create_window_function delegate to
      createFunctionApi → sqlite3CreateFunc (already present in codegen).
    * sqlite3_create_collation / _v2 implement the createCollation flow
      directly (replace check + ExpirePreparedStatements + FindCollSeq(create=1)).
    * sqlite3_create_module / _v2 inline a minimal sqlite3VtabCreateModule
      replacement: alloc Module struct, hash insert into db^.aModule.
      Vtab eponymous-table cleanup is skipped — no vtabs are registered
      yet (Phase 6.bis.1 not done), so the replace path can only happen
      if the same module name is registered twice in the same connection.
    * UTF-16 entry points (_create_function16, _create_collation16,
      _collation_needed16) are deferred until UTF-16 lands.
  ---------------------------------------------------------------------- }

const
  SQLITE_FUNC_ENCMASK = $03;

type
  TxCollCmpReg   = function(p: Pointer; n1: i32; z1: Pointer;
                            n2: i32; z2: Pointer): i32; cdecl;
  TxCollDelReg   = procedure(p: Pointer); cdecl;

{ createFunctionApi — main.c:2066 }
function createFunctionApi(db: PTsqlite3; zFunc: PAnsiChar; nArg: i32;
  enc: i32; p: Pointer; xSFunc, xStep, xFinal, xValue, xInverse,
  xDestroy: Pointer): i32;
var
  rc:   i32;
  pArg: PTFuncDestructor;
  label out_lbl;
begin
  rc   := SQLITE_ERROR;
  pArg := nil;
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if xDestroy <> nil then begin
    pArg := PTFuncDestructor(sqlite3Malloc(SizeOf(TFuncDestructor)));
    if pArg = nil then begin
      sqlite3OomFault(db);
      TxFuncDestroy(xDestroy)(p);
      goto out_lbl;
    end;
    pArg^.nRef     := 0;
    pArg^.xDestroy := TxFuncDestroy(xDestroy);
    pArg^.pUserData := p;
  end;
  rc := sqlite3CreateFunc(db, zFunc, nArg, enc, p,
          xSFunc, xStep, xFinal, xValue, xInverse, pArg);
  if (pArg <> nil) and (pArg^.nRef = 0) then begin
    TxFuncDestroy(xDestroy)(p);
    sqlite3_free(pArg);
  end;
out_lbl:
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_create_function(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer): i32;
begin
  Result := createFunctionApi(db, zFunc, nArg, enc, pUserData,
              xSFunc, xStep, xFinal, nil, nil, nil);
end;

function sqlite3_create_function_v2(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer;
  xDestroy: Pointer): i32;
begin
  Result := createFunctionApi(db, zFunc, nArg, enc, pUserData,
              xSFunc, xStep, xFinal, nil, nil, xDestroy);
end;

function sqlite3_create_window_function(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xStep: Pointer; xFinal: Pointer; xValue: Pointer; xInverse: Pointer;
  xDestroy: Pointer): i32;
begin
  Result := createFunctionApi(db, zFunc, nArg, enc, pUserData,
              nil, xStep, xFinal, xValue, xInverse, xDestroy);
end;

{ createCollation — main.c:2852.  Performs the replace-or-create flow that
  the codegen-side sqlite3FindCollSeq(create=1) cannot do on its own. }
function createCollation(db: PTsqlite3; zName: PAnsiChar; enc: u8;
  pCtx: Pointer; xCompare: Pointer; xDel: Pointer): i32;
var
  pColl: PTCollSeq;
  enc2:  i32;
begin
  enc2 := enc;
  if (enc2 = SQLITE_UTF16) or (enc2 = SQLITE_UTF16_ALIGNED) then
    enc2 := SQLITE_UTF16LE;  { native LE on x86_64 }
  if (enc2 < SQLITE_UTF8) or (enc2 > SQLITE_UTF16BE) then begin
    Result := SQLITE_MISUSE; Exit;
  end;

  pColl := PTCollSeq(sqlite3FindCollSeq(db, u8(enc2), zName, 0));
  if (pColl <> nil) and (pColl^.xCmp <> nil) then begin
    if db^.nVdbeActive <> 0 then begin
      sqlite3ErrorWithMsg(db, SQLITE_BUSY,
        'unable to delete/modify collation sequence due to active statements');
      Result := SQLITE_BUSY; Exit;
    end;
    sqlite3ExpirePreparedStatements(db, 0);
  end;

  pColl := PTCollSeq(sqlite3FindCollSeq(db, u8(enc2), zName, 1));
  if pColl = nil then begin Result := SQLITE_NOMEM; Exit; end;
  pColl^.xCmp  := TxCollCmpReg(xCompare);
  pColl^.pUser := pCtx;
  pColl^.xDel  := TxCollDelReg(xDel);
  pColl^.enc   := u8(enc2 or (enc and SQLITE_UTF16_ALIGNED));
  sqlite3Error(db, SQLITE_OK);
  Result := SQLITE_OK;
end;

function sqlite3_create_collation_v2(db: PTsqlite3; zName: PAnsiChar;
  enc: i32; pCtx: Pointer; xCompare: Pointer; xDel: Pointer): i32;
var
  rc: i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  rc := createCollation(db, zName, u8(enc), pCtx, xCompare, xDel);
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_create_collation(db: PTsqlite3; zName: PAnsiChar;
  enc: i32; pCtx: Pointer; xCompare: Pointer): i32;
begin
  Result := sqlite3_create_collation_v2(db, zName, enc, pCtx, xCompare, nil);
end;

function sqlite3_collation_needed(db: PTsqlite3;
  pCollNeededArg: Pointer; xCollNeeded: Pointer): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  db^.xCollNeeded    := xCollNeeded;
  db^.xCollNeeded16  := nil;
  db^.pCollNeededArg := pCollNeededArg;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  sqlite3_create_module / _v2 — vtab.c:108..134.

  The internal Module record + sqlite3VtabCreateModule live in
  passqlite3vtab (Phase 6.bis.1a).  These public entry points are the
  thin createModule() wrapper from vtab.c:87-101: enter the db mutex,
  call sqlite3VtabCreateModule, ApiExit, and on failure invoke the
  caller-supplied destructor exactly once.
  ---------------------------------------------------------------------- }

function _api_create_module(db: PTsqlite3; zName: PAnsiChar;
  pModule: PSqlite3Module; pAux: Pointer; xDestroy: TxModuleDestroy): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  sqlite3_mutex_enter(db^.mutex);
  sqlite3VtabCreateModule(db, zName, pModule, pAux, xDestroy);
  rc := sqlite3ApiExit(db, rc);
  if (rc <> SQLITE_OK) and Assigned(xDestroy) then xDestroy(pAux);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_create_module(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer): i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  Result := _api_create_module(db, zName, PSqlite3Module(pModule), pAux, nil);
end;

function sqlite3_create_module_v2(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer; xDestroy: Pointer): i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  Result := _api_create_module(db, zName, PSqlite3Module(pModule), pAux,
                               TxModuleDestroy(xDestroy));
end;

{ ----------------------------------------------------------------------
  Phase 8.4 — Configuration and hooks.
  Ported from main.c:
    426  sqlite3_config         (varargs — exposed here as int-shape overload)
    950  sqlite3_db_config      (varargs — exposed as three typed entry points)
   1718  sqliteDefaultBusyCallback
   1786  sqlite3_busy_handler
   1843  sqlite3_busy_timeout
   2277  sqlite3_trace_v2
   2337  sqlite3_commit_hook
   2362  sqlite3_update_hook
   2387  sqlite3_rollback_hook

  Scope of this Phase 8.4 port:
    * No C-ABI varargs.  sqlite3_config and sqlite3_db_config are split
      into typed entry points (one per argument shape).  Pascal callers
      are the v1 audience; a future ABI-compat layer can wrap these
      under a varargs trampoline.
    * setupLookaside is stubbed: lookaside slot allocation is not wired
      (Phase 8.1 already set bDisable=1, sz=0).  We record sz / nSlot
      / pBuf for future use but never actually serve allocations from
      the buffer.  If cnt <= 0 the subsystem is forcibly disabled.
    * sqlite3_progress_handler is intentionally NOT exported (gated by
      SQLITE_OMIT_PROGRESS_CALLBACK conventions; deferred to Phase 8.5+).
    * SETLK_TIMEOUT (compile-time gated in C) is not built in.
    * Db-config flags that reference codegen state we have not yet
      wired (e.g. SQLITE_DqsDDL parser-side enforcement, SQLITE_Defensive
      vdbe checks) still flip the flag bit; their *behaviour* engages
      only when the consumer subsystem honours the bit, which is a
      separate concern.
  ---------------------------------------------------------------------- }

const
  { sqlite3.flags bits not previously declared in passqlite3util.SQLITE_*. }
  SQLITE_StmtScanStatus_Bit = u64($00000400);
  SQLITE_NoCkptOnClose_Bit  = u64($00000800);
  SQLITE_ReverseOrder_Bit   = u64($00001000);
  SQLITE_LoadExtension_Bit  = u64($00010000);
  SQLITE_Fts3Tokenizer_Bit  = u64($00400000);
  SQLITE_EnableQPSG_Bit     = u64($00800000);
  SQLITE_TriggerEQP_Bit     = u64($01000000);
  SQLITE_ResetDatabase_Bit  = u64($02000000);
  SQLITE_LegacyAlter_Bit    = u64($04000000);
  SQLITE_NoSchemaError_Bit  = u64($08000000);
  SQLITE_Defensive_Bit      = u64($10000000);
  SQLITE_DqsDDL_Bit         = u64($20000000);
  SQLITE_DqsDML_Bit         = u64($40000000);
  SQLITE_EnableView_Bit     = u64($80000000);
  SQLITE_AttachCreate_Bit   = u64($00010) shl 32;
  SQLITE_AttachWrite_Bit    = u64($00020) shl 32;
  SQLITE_Comments_Bit       = u64($00040) shl 32;

type
  TBusyCallbackFn   = function(p: Pointer; n: i32): i32; cdecl;
  TCommitCallbackFn = function(p: Pointer): i32; cdecl;
  TRollbackCallbackFn = procedure(p: Pointer); cdecl;
  TTraceV2Fn        = function(n: u32; p, x, y: Pointer): i32; cdecl;

{ sqliteDefaultBusyCallback — main.c:1718.  Faithful port of the
  delays/totals nanosleep variant.  HAVE_NANOSLEEP is assumed (Linux). }
function sqliteDefaultBusyCallback(ptr: Pointer; count: i32): i32; cdecl;
const
  delays: array[0..11] of u8 = ( 1, 2, 5, 10, 15, 20, 25, 25,  25,  50,  50, 100);
  totals: array[0..11] of u8 = ( 0, 1, 3,  8, 18, 33, 53, 78, 103, 128, 178, 228);
  NDELAY = 12;
var
  db: PTsqlite3;
  tmout, delay, prior: i32;
begin
  db    := PTsqlite3(ptr);
  tmout := db^.busyTimeout;
  if count < NDELAY then begin
    delay := delays[count];
    prior := totals[count];
  end else begin
    delay := delays[NDELAY - 1];
    prior := totals[NDELAY - 1] + delay * (count - (NDELAY - 1));
  end;
  if (prior + delay) > tmout then begin
    delay := tmout - prior;
    if delay <= 0 then begin Result := 0; Exit; end;
  end;
  sqlite3OsSleep(Psqlite3_vfs(db^.pVfs), delay * 1000);
  Result := 1;
end;

function sqlite3_busy_handler(db: PTsqlite3;
  xBusy: Pointer; pArg: Pointer): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  db^.busyHandler.xBusyHandler := TBusyCallbackFn(xBusy);
  db^.busyHandler.pBusyArg     := pArg;
  db^.busyHandler.nBusy        := 0;
  db^.busyTimeout              := 0;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

function sqlite3_busy_timeout(db: PTsqlite3; ms: i32): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  if ms > 0 then begin
    sqlite3_busy_handler(db, @sqliteDefaultBusyCallback, Pointer(db));
    db^.busyTimeout := ms;
  end else begin
    sqlite3_busy_handler(db, nil, nil);
  end;
  Result := SQLITE_OK;
end;

{ Hooks — main.c:2337/2362/2387. }
function sqlite3_commit_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  Result               := db^.pCommitArg;
  db^.xCommitCallback  := TCommitCallbackFn(xCallback);
  db^.pCommitArg       := pArg;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_rollback_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  Result                 := db^.pRollbackArg;
  db^.xRollbackCallback  := TRollbackCallbackFn(xCallback);
  db^.pRollbackArg       := pArg;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_update_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  Result               := db^.pUpdateArg;
  db^.xUpdateCallback  := xCallback;
  db^.pUpdateArg       := pArg;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_trace_v2(db: PTsqlite3; mTrace: u32;
  xTrace: Pointer; pArg: Pointer): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if mTrace = 0 then xTrace := nil;
  if xTrace = nil then mTrace := 0;
  db^.mTrace      := u8(mTrace and $FF);
  db^.trace.xV2   := TTraceV2Fn(xTrace);
  db^.pTraceArg   := pArg;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  setupLookaside — main.c:776 (greatly simplified for Phase 8.4).

  We do not implement slot allocation; the lookaside subsystem stays
  disabled (bDisable=1) as it has been since Phase 8.1.  This stub
  exists so SQLITE_DBCONFIG_LOOKASIDE callers get well-defined
  behaviour: SQLITE_OK is returned, the caller's request is recorded
  in the (non-functional) sz / nSlot fields, and the bDisable flag
  reflects the request.
  ---------------------------------------------------------------------- }
function setupLookaside(db: PTsqlite3; pBuf: Pointer; sz, cnt: i32): i32;
begin
  if pBuf <> nil then ;  { silence unused warning }
  if (sz <= 0) or (cnt <= 0) then begin
    db^.lookaside.bDisable := 1;
    db^.lookaside.sz       := 0;
    db^.lookaside.nSlot    := 0;
  end else begin
    { Round sz down to a multiple of 8.  Mirrors C: sz = ROUNDDOWN8(sz). }
    sz := sz and (not 7);
    db^.lookaside.bDisable := 1;        { still no real allocation }
    db^.lookaside.sz       := u16(sz);
    db^.lookaside.nSlot    := u32(cnt);
  end;
  Result := SQLITE_OK;
end;

type
  TFlagOpEntry = record
    op:   i32;
    mask: u64;
  end;
const
  { Mirrors aFlagOp[] in main.c:986. }
  aFlagOp: array[0..20] of TFlagOpEntry = (
    (op: SQLITE_DBCONFIG_ENABLE_FKEY;           mask: SQLITE_ForeignKeys),
    (op: SQLITE_DBCONFIG_ENABLE_TRIGGER;        mask: SQLITE_EnableTrigger),
    (op: SQLITE_DBCONFIG_ENABLE_VIEW;           mask: SQLITE_EnableView_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER; mask: SQLITE_Fts3Tokenizer_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION; mask: SQLITE_LoadExtension_Bit),
    (op: SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE;      mask: SQLITE_NoCkptOnClose_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_QPSG;           mask: SQLITE_EnableQPSG_Bit),
    (op: SQLITE_DBCONFIG_TRIGGER_EQP;           mask: SQLITE_TriggerEQP_Bit),
    (op: SQLITE_DBCONFIG_RESET_DATABASE;        mask: SQLITE_ResetDatabase_Bit),
    (op: SQLITE_DBCONFIG_DEFENSIVE;             mask: SQLITE_Defensive_Bit),
    (op: SQLITE_DBCONFIG_WRITABLE_SCHEMA;       mask: SQLITE_WriteSchema or SQLITE_NoSchemaError_Bit),
    (op: SQLITE_DBCONFIG_LEGACY_ALTER_TABLE;    mask: SQLITE_LegacyAlter_Bit),
    (op: SQLITE_DBCONFIG_DQS_DDL;               mask: SQLITE_DqsDDL_Bit),
    (op: SQLITE_DBCONFIG_DQS_DML;               mask: SQLITE_DqsDML_Bit),
    (op: SQLITE_DBCONFIG_LEGACY_FILE_FORMAT;    mask: SQLITE_LegacyFileFmt),
    (op: SQLITE_DBCONFIG_TRUSTED_SCHEMA;        mask: SQLITE_TrustedSchema),
    (op: SQLITE_DBCONFIG_STMT_SCANSTATUS;       mask: SQLITE_StmtScanStatus_Bit),
    (op: SQLITE_DBCONFIG_REVERSE_SCANORDER;     mask: SQLITE_ReverseOrder_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE;  mask: SQLITE_AttachCreate_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE;   mask: SQLITE_AttachWrite_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_COMMENTS;       mask: SQLITE_Comments_Bit)
  );

{ Common flag-op handler. }
function dbConfigFlagOp(db: PTsqlite3; op: i32;
  onoff: i32; pRes: Pi32): i32;
var
  i: i32;
  oldFlags: u64;
begin
  for i := 0 to High(aFlagOp) do begin
    if aFlagOp[i].op = op then begin
      oldFlags := db^.flags;
      if onoff > 0 then
        db^.flags := db^.flags or aFlagOp[i].mask
      else if onoff = 0 then
        db^.flags := db^.flags and (not aFlagOp[i].mask);
      if oldFlags <> db^.flags then
        sqlite3ExpirePreparedStatements(db, 0);
      if pRes <> nil then begin
        if (db^.flags and aFlagOp[i].mask) <> 0 then pRes^ := 1 else pRes^ := 0;
      end;
      Result := SQLITE_OK;
      Exit;
    end;
  end;
  Result := SQLITE_ERROR;
end;

function sqlite3_db_config_text(db: PTsqlite3; op: i32;
  zName: PAnsiChar): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if op = SQLITE_DBCONFIG_MAINDBNAME then begin
    db^.aDb[0].zDbSName := zName;
    Result := SQLITE_OK;
  end else
    Result := SQLITE_ERROR;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_db_config_lookaside(db: PTsqlite3; op: i32;
  pBuf: Pointer; sz: i32; cnt: i32): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if op = SQLITE_DBCONFIG_LOOKASIDE then
    Result := setupLookaside(db, pBuf, sz, cnt)
  else
    Result := SQLITE_ERROR;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_db_config_int(db: PTsqlite3; op: i32;
  onoff: i32; pRes: Pi32): i32;
var
  rc: i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if op = SQLITE_DBCONFIG_FP_DIGITS then begin
    if (onoff > 3) and (onoff < 24) then db^.nFpDigit := u8(onoff);
    if pRes <> nil then pRes^ := db^.nFpDigit;
    rc := SQLITE_OK;
  end else
    rc := dbConfigFlagOp(db, op, onoff, pRes);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ sqlite3_config(int).  Mirrors the int-shape branches of main.c:426. }
function sqlite3_config(op: i32; arg: i32): i32; overload;
begin
  if sqlite3GlobalConfig.isInit <> 0 then begin
    { Only LOG / PCACHE_HDRSZ are anytime-config; neither uses int shape. }
    Result := SQLITE_MISUSE;
    Exit;
  end;
  Result := SQLITE_OK;
  case op of
    SQLITE_CONFIG_SINGLETHREAD: begin
      sqlite3GlobalConfig.bCoreMutex := 0;
      sqlite3GlobalConfig.bFullMutex := 0;
    end;
    SQLITE_CONFIG_MULTITHREAD: begin
      sqlite3GlobalConfig.bCoreMutex := 1;
      sqlite3GlobalConfig.bFullMutex := 0;
    end;
    SQLITE_CONFIG_SERIALIZED: begin
      sqlite3GlobalConfig.bCoreMutex := 1;
      sqlite3GlobalConfig.bFullMutex := 1;
    end;
    SQLITE_CONFIG_MEMSTATUS:    sqlite3GlobalConfig.bMemstat    := arg;
    SQLITE_CONFIG_SMALL_MALLOC: sqlite3GlobalConfig.bSmallMalloc := arg;
    SQLITE_CONFIG_URI:          sqlite3GlobalConfig.bOpenUri    := arg;
    SQLITE_CONFIG_COVERING_INDEX_SCAN: sqlite3GlobalConfig.bUseCis := arg;
    SQLITE_CONFIG_STMTJRNL_SPILL: sqlite3GlobalConfig.nStmtSpill := arg;
    SQLITE_CONFIG_SORTERREF_SIZE: sqlite3GlobalConfig.szSorterRef := u32(arg);
    SQLITE_CONFIG_MEMDB_MAXSIZE:  sqlite3GlobalConfig.mxMemdbSize := arg;
  else
    Result := SQLITE_MISUSE;
  end;
end;

{ ----------------------------------------------------------------------
  Phase 8.5 — sqlite3_initialize / sqlite3_shutdown.
  Ported from main.c:190 (sqlite3_initialize) and main.c:372 (sqlite3_shutdown).

  Scope notes:
    * SQLITE_EXTRA_INIT / SQLITE_OMIT_WSD / SQLITE_ENABLE_SQLLOG branches
      are compile-time gated in C and not relevant here.
    * sqlite3_reset_auto_extension is not ported (auto-extension subsystem
      not present); shutdown therefore omits the call.  Re-add with that
      subsystem in a later phase.
    * sqlite3_data_directory / sqlite3_temp_directory globals are not
      ported either, so the post-MallocEnd zeroing block is skipped.
    * The NDEBUG NaN sanity check is omitted.
  ---------------------------------------------------------------------- }

function sqlite3_initialize: i32;
var
  pMainMtx : Psqlite3_mutex;
  rc       : i32;
begin
  { If SQLite is already completely initialized, this is a no-op. }
  if sqlite3GlobalConfig.isInit <> 0 then begin
    sqlite3MemoryBarrier;
    Result := SQLITE_OK;
    Exit;
  end;

  { Make sure the mutex subsystem is initialized. }
  rc := sqlite3MutexInit;
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  { Initialize malloc + the recursive pInitMutex under STATIC_MAIN. }
  pMainMtx := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMainMtx);
  sqlite3GlobalConfig.isMutexInit := 1;
  if sqlite3GlobalConfig.isMallocInit = 0 then
    rc := sqlite3MallocInit;
  if rc = SQLITE_OK then begin
    sqlite3GlobalConfig.isMallocInit := 1;
    if sqlite3GlobalConfig.pInitMutex = nil then begin
      sqlite3GlobalConfig.pInitMutex :=
        sqlite3MutexAlloc(SQLITE_MUTEX_RECURSIVE);
      if (sqlite3GlobalConfig.bCoreMutex <> 0)
         and (sqlite3GlobalConfig.pInitMutex = nil) then
        rc := SQLITE_NOMEM;
    end;
  end;
  if rc = SQLITE_OK then
    Inc(sqlite3GlobalConfig.nRefInitMutex);
  sqlite3_mutex_leave(pMainMtx);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  { Recursive-mutex section: do the rest of the work serialized via
    pInitMutex so re-entrant calls (typically through sqlite3_os_init →
    sqlite3_vfs_register) don't deadlock. }
  sqlite3_mutex_enter(sqlite3GlobalConfig.pInitMutex);
  if (sqlite3GlobalConfig.isInit = 0)
     and (sqlite3GlobalConfig.inProgress = 0) then begin
    sqlite3GlobalConfig.inProgress := 1;

    { Reset the global builtin-functions hash and re-populate. }
    FillChar(sqlite3BuiltinFunctions, SizeOf(sqlite3BuiltinFunctions), 0);
    sqlite3RegisterBuiltinFunctions;

    if sqlite3GlobalConfig.isPCacheInit = 0 then
      rc := sqlite3PcacheInitialize;
    if rc = SQLITE_OK then begin
      sqlite3GlobalConfig.isPCacheInit := 1;
      rc := sqlite3OsInit;
    end;
    if rc = SQLITE_OK then
      rc := sqlite3MemdbInit;
    if rc = SQLITE_OK then begin
      sqlite3PCacheBufferSetup(
        sqlite3GlobalConfig.pPage,
        sqlite3GlobalConfig.szPage,
        sqlite3GlobalConfig.nPage);
    end;
    if rc = SQLITE_OK then begin
      sqlite3MemoryBarrier;
      sqlite3GlobalConfig.isInit := 1;
    end;
    sqlite3GlobalConfig.inProgress := 0;
  end;
  sqlite3_mutex_leave(sqlite3GlobalConfig.pInitMutex);

  { Tear down the recursive pInitMutex once the last in-flight caller
    leaves, to prevent a resource leak across repeated init/shutdown. }
  sqlite3_mutex_enter(pMainMtx);
  Dec(sqlite3GlobalConfig.nRefInitMutex);
  if sqlite3GlobalConfig.nRefInitMutex <= 0 then begin
    Assert(sqlite3GlobalConfig.nRefInitMutex = 0);
    sqlite3_mutex_free(sqlite3GlobalConfig.pInitMutex);
    sqlite3GlobalConfig.pInitMutex := nil;
  end;
  sqlite3_mutex_leave(pMainMtx);

  Result := rc;
end;

function sqlite3_shutdown: i32;
begin
  if sqlite3GlobalConfig.isInit <> 0 then begin
    sqlite3_os_end;
    { sqlite3_reset_auto_extension — auto-extension subsystem not ported. }
    sqlite3GlobalConfig.isInit := 0;
  end;
  if sqlite3GlobalConfig.isPCacheInit <> 0 then begin
    sqlite3PcacheShutdown;
    sqlite3GlobalConfig.isPCacheInit := 0;
  end;
  if sqlite3GlobalConfig.isMallocInit <> 0 then begin
    sqlite3MallocEnd;
    sqlite3GlobalConfig.isMallocInit := 0;
    { sqlite3_data_directory / sqlite3_temp_directory globals not ported. }
  end;
  if sqlite3GlobalConfig.isMutexInit <> 0 then begin
    sqlite3MutexEnd;
    sqlite3GlobalConfig.isMutexInit := 0;
  end;
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  Phase 8.6 — sqlite3_exec / sqlite3_get_table / sqlite3_free_table
  Faithful port of legacy.c (entire file) and table.c.
  ---------------------------------------------------------------------- }

function sqlite3_errmsg(db: PTsqlite3): PAnsiChar;
begin
  if db = nil then begin Result := sqlite3ErrStr(SQLITE_NOMEM); Exit; end;
  if sqlite3SafetyCheckSickOrOk(db) = 0 then begin
    Result := sqlite3ErrStr(SQLITE_MISUSE); Exit;
  end;
  if db^.mallocFailed <> 0 then begin
    Result := sqlite3ErrStr(SQLITE_NOMEM); Exit;
  end;
  Result := sqlite3ErrStr(db^.errCode and db^.errMask);
end;

type
  PPPAnsiCharLocal = ^PPAnsiChar;

  PTabResult = ^TTabResult;
  TTabResult = record
    azResult: PPAnsiChar;   { Accumulated output }
    zErrMsg:  PAnsiChar;    { Error message text, if an error occurs }
    nAlloc:   u32;          { Slots allocated for azResult[] }
    nRow:     u32;          { Number of rows in the result }
    nColumn:  u32;          { Number of columns in the result }
    nData:    u32;          { Slots used in azResult[].  (nRow+1)*nColumn }
    rc:       i32;          { Return code from sqlite3_exec() }
  end;

function sqlite3_exec(db: PTsqlite3; zSql: PAnsiChar;
                      xCallback: Tsqlite3_callback; pArg: Pointer;
                      pzErrMsg: PPAnsiChar): i32;
label
  exec_out;
var
  rc:        i32;
  zLeftover: PAnsiChar;
  pStmt:     PVdbe;
  pStmtP:    Pointer;
  azCols:    PPAnsiChar;
  azVals:    PPAnsiChar;
  callbackIsInit: Boolean;
  nCol, i:   i32;
  src, dst:  PAnsiChar;
  errSrc:    PAnsiChar;
  n:         PtrUInt;
begin
  rc     := SQLITE_OK;
  pStmt  := nil;
  azCols := nil;

  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  if zSql = nil then zSql := '';

  sqlite3_mutex_enter(db^.mutex);
  sqlite3Error(db, SQLITE_OK);
  while (rc = SQLITE_OK) and (zSql[0] <> #0) do begin
    nCol  := 0;
    azVals := nil;

    pStmtP := nil;
    rc := sqlite3_prepare_v2(db, zSql, -1, @pStmtP, @zLeftover);
    pStmt := PVdbe(pStmtP);
    Assert((rc = SQLITE_OK) or (pStmt = nil));
    if rc <> SQLITE_OK then continue;
    if pStmt = nil then begin
      { whitespace / comment-only statement }
      zSql := zLeftover;
      continue;
    end;
    callbackIsInit := False;

    while True do begin
      rc := sqlite3_step(pStmt);

      { Invoke the callback function if required. }
      if (xCallback <> nil) and
         ((rc = SQLITE_ROW) or
          ((rc = SQLITE_DONE) and (not callbackIsInit) and
           ((db^.flags and SQLITE_NullCallback) <> 0))) then
      begin
        if not callbackIsInit then begin
          nCol := sqlite3_column_count(pStmt);
          azCols := PPAnsiChar(sqlite3DbMallocRaw(db,
                       u64((2 * nCol + 1) * SizeOf(PAnsiChar))));
          if azCols = nil then goto exec_out;
          for i := 0 to nCol - 1 do begin
            (azCols + i)^ := sqlite3_column_name(pStmt, i);
            Assert((azCols + i)^ <> nil);
          end;
          callbackIsInit := True;
        end;
        if rc = SQLITE_ROW then begin
          azVals := PPAnsiChar(azCols + nCol);
          for i := 0 to nCol - 1 do begin
            (azVals + i)^ := PAnsiChar(sqlite3_column_text(pStmt, i));
            if ((azVals + i)^ = nil) and
               (sqlite3_column_type(pStmt, i) <> SQLITE_NULL) then
            begin
              sqlite3OomFault(db);
              goto exec_out;
            end;
          end;
          (azVals + nCol)^ := nil;
        end;
        if xCallback(pArg, nCol, azVals, azCols) <> 0 then begin
          rc := SQLITE_ABORT;
          sqlite3VdbeFinalize(pStmt);
          pStmt := nil;
          sqlite3Error(db, SQLITE_ABORT);
          goto exec_out;
        end;
      end;

      if rc <> SQLITE_ROW then begin
        rc := sqlite3VdbeFinalize(pStmt);
        pStmt := nil;
        zSql := zLeftover;
        while sqlite3Isspace(u8(zSql[0])) <> 0 do Inc(zSql);
        Break;
      end;
    end;

    sqlite3DbFree(db, azCols);
    azCols := nil;
  end;

exec_out:
  if pStmt <> nil then sqlite3VdbeFinalize(pStmt);
  sqlite3DbFree(db, azCols);

  rc := sqlite3ApiExit(db, rc);
  if (rc <> SQLITE_OK) and (pzErrMsg <> nil) then begin
    errSrc := sqlite3_errmsg(db);
    if errSrc = nil then errSrc := '';
    n := PtrUInt(sqlite3Strlen30(errSrc));
    dst := PAnsiChar(sqlite3_malloc64(u64(n + 1)));
    pzErrMsg^ := dst;
    if dst = nil then begin
      rc := SQLITE_NOMEM;
      sqlite3Error(db, SQLITE_NOMEM);
    end else begin
      src := errSrc;
      Move(src^, dst^, n);
      (dst + n)^ := #0;
    end;
  end else if pzErrMsg <> nil then
    pzErrMsg^ := nil;

  Assert((rc and db^.errMask) = rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ ----------------------------------------------------------------------
  table.c — sqlite3_get_table / sqlite3_get_table_cb / sqlite3_free_table
  ---------------------------------------------------------------------- }

function sqlite3_get_table_cb(pArg: Pointer; nCol: i32;
                              argv: PPAnsiChar;
                              colv: PPAnsiChar): i32; cdecl;
label
  malloc_failed;
var
  p:    PTabResult;
  need: i32;
  i, n: i32;
  z:    PAnsiChar;
  azNew: PPAnsiChar;
  src:  PAnsiChar;
begin
  p := PTabResult(pArg);

  if (p^.nRow = 0) and (argv <> nil) then
    need := nCol * 2
  else
    need := nCol;
  if (p^.nData + u32(need)) > p^.nAlloc then begin
    p^.nAlloc := p^.nAlloc * 2 + u32(need);
    azNew := PPAnsiChar(sqlite3Realloc(p^.azResult,
                                       NativeUInt(SizeOf(PAnsiChar) * p^.nAlloc)));
    if azNew = nil then goto malloc_failed;
    p^.azResult := azNew;
  end;

  { First row: emit the column names. }
  if p^.nRow = 0 then begin
    p^.nColumn := u32(nCol);
    for i := 0 to nCol - 1 do begin
      src := (colv + i)^;
      if src = nil then n := 0 else n := sqlite3Strlen30(src);
      z := PAnsiChar(sqlite3_malloc64(u64(n + 1)));
      if z = nil then goto malloc_failed;
      if n > 0 then Move(src^, z^, n);
      z[n] := #0;
      (p^.azResult + p^.nData)^ := z;
      Inc(p^.nData);
    end;
  end else if i32(p^.nColumn) <> nCol then begin
    sqlite3_free(p^.zErrMsg);
    p^.zErrMsg := PAnsiChar(sqlite3StrDup(
      'sqlite3_get_table() called with two or more incompatible queries'));
    p^.rc := SQLITE_ERROR;
    Result := 1; Exit;
  end;

  { Copy over the row data. }
  if argv <> nil then begin
    for i := 0 to nCol - 1 do begin
      src := (argv + i)^;
      if src = nil then begin
        z := nil;
      end else begin
        n := sqlite3Strlen30(src) + 1;
        z := PAnsiChar(sqlite3_malloc64(u64(n)));
        if z = nil then goto malloc_failed;
        Move(src^, z^, n);
      end;
      (p^.azResult + p^.nData)^ := z;
      Inc(p^.nData);
    end;
    Inc(p^.nRow);
  end;
  Result := 0;
  Exit;

malloc_failed:
  p^.rc := SQLITE_NOMEM;
  Result := 1;
end;

function sqlite3_get_table(db: PTsqlite3; zSql: PAnsiChar;
                           pazResult: PPPAnsiChar;
                           pnRow: Pi32; pnColumn: Pi32;
                           pzErrMsg: PPAnsiChar): i32;
var
  rc:    i32;
  res:   TTabResult;
  azNew: PPAnsiChar;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (pazResult = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  pazResult^ := nil;
  if pnColumn <> nil then pnColumn^ := 0;
  if pnRow    <> nil then pnRow^    := 0;
  if pzErrMsg <> nil then pzErrMsg^ := nil;
  res.zErrMsg := nil;
  res.nRow    := 0;
  res.nColumn := 0;
  res.nData   := 1;
  res.nAlloc  := 20;
  res.rc      := SQLITE_OK;
  res.azResult := PPAnsiChar(sqlite3_malloc64(SizeOf(PAnsiChar) * res.nAlloc));
  if res.azResult = nil then begin
    db^.errCode := SQLITE_NOMEM;
    Result := SQLITE_NOMEM; Exit;
  end;
  (res.azResult + 0)^ := nil;
  rc := sqlite3_exec(db, zSql, @sqlite3_get_table_cb, @res, pzErrMsg);
  { Stash nData in slot 0 so sqlite3_free_table knows the array length. }
  (res.azResult + 0)^ := PAnsiChar(PtrUInt(res.nData));
  if (rc and $FF) = SQLITE_ABORT then begin
    sqlite3_free_table(PPAnsiChar(res.azResult + 1));
    if res.zErrMsg <> nil then begin
      if pzErrMsg <> nil then begin
        sqlite3_free(pzErrMsg^);
        pzErrMsg^ := PAnsiChar(sqlite3StrDup(res.zErrMsg));
      end;
      sqlite3_free(res.zErrMsg);
    end;
    db^.errCode := res.rc;
    Result := res.rc; Exit;
  end;
  sqlite3_free(res.zErrMsg);
  if rc <> SQLITE_OK then begin
    sqlite3_free_table(PPAnsiChar(res.azResult + 1));
    Result := rc; Exit;
  end;
  if res.nAlloc > res.nData then begin
    azNew := PPAnsiChar(sqlite3Realloc(res.azResult,
                                       NativeUInt(SizeOf(PAnsiChar) * res.nData)));
    if azNew = nil then begin
      sqlite3_free_table(PPAnsiChar(res.azResult + 1));
      db^.errCode := SQLITE_NOMEM;
      Result := SQLITE_NOMEM; Exit;
    end;
    res.azResult := azNew;
  end;
  pazResult^ := PPAnsiChar(res.azResult + 1);
  if pnColumn <> nil then pnColumn^ := i32(res.nColumn);
  if pnRow    <> nil then pnRow^    := i32(res.nRow);
  Result := rc;
end;

procedure sqlite3_free_table(azResult: PPAnsiChar);
var
  i, n: i32;
  base: PPAnsiChar;
begin
  if azResult <> nil then begin
    base := PPAnsiChar(PtrUInt(azResult) - SizeOf(PAnsiChar));
    n := i32(PtrUInt((base + 0)^));
    for i := 1 to n - 1 do
      if (base + i)^ <> nil then sqlite3_free((base + i)^);
    sqlite3_free(base);
  end;
end;

{ Phase 8.8 — sqlite3_unlock_notify shim.

  Mirrors notify.c:148 in the trivial degenerate case enforced by our
  build configuration:
    * No shared-cache → the port never sets pBlockingConnection on any
      connection.  The C path at notify.c:167 (`0==db->pBlockingConnection`)
      is therefore the only branch reachable here, which fires xNotify
      immediately with a one-element argument array and returns OK.
    * xNotify=nil clears prior registrations — but with no per-connection
      state to clear, this is also a pure no-op returning OK.
    * db=nil → SQLITE_MISUSE_BKPT, matching the API_ARMOR guard. }
function sqlite3_unlock_notify(db: PTsqlite3;
                               xNotify: Tsqlite3_unlock_notify_cb;
                               pArg: Pointer): i32;
var
  arg: Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if Assigned(xNotify) then begin
    arg := pArg;
    xNotify(@arg, 1);
  end;
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  Phase 8.9 — loadext.c shims and faithful auto-extension list.

  See interface block above for design notes.
  ---------------------------------------------------------------------- }
const
  cExtLoadDisabledMsg: AnsiString = 'extension loading is disabled';

var
  gAutoExt   : array of Tsqlite3_loadext_fn;
  gAutoExtN  : i32 = 0;

{ sqlite3_load_extension — loadext.c:728 (with SQLITE_OMIT_LOAD_EXTENSION
  the C code does not emit this symbol at all; we provide a shim that
  tells the caller the obvious truth). }
function sqlite3_load_extension(db: PTsqlite3;
                                zFile, zProc: PAnsiChar;
                                pzErrMsg: PPAnsiChar): i32;
var
  z: PAnsiChar;
  n: PtrUInt;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if pzErrMsg <> nil then begin
    n := Length(cExtLoadDisabledMsg);
    z := sqlite3_malloc(i32(n + 1));
    if z <> nil then begin
      Move(cExtLoadDisabledMsg[1], z^, n);
      (z + n)^ := #0;
    end;
    pzErrMsg^ := z;
  end;
  Result := SQLITE_ERROR;
end;

{ sqlite3_enable_load_extension — loadext.c:759.  Faithful.  The
  SQLITE_LoadExtFunc bit is shifted >32 in upstream; we don't model that
  bit yet (it gates only the load_extension() SQL function which is not
  ported), so toggle SQLITE_LoadExtension only. }
function sqlite3_enable_load_extension(db: PTsqlite3; onoff: i32): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  if onoff <> 0 then
    db^.flags := db^.flags or SQLITE_LoadExtension_Bit
  else
    db^.flags := db^.flags and (not SQLITE_LoadExtension_Bit);
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ sqlite3_auto_extension — loadext.c:808.  Faithful. }
function sqlite3_auto_extension(xInit: Tsqlite3_loadext_fn): i32;
var
  rc      : i32;
  i       : i32;
  pMainMtx: Psqlite3_mutex;
begin
  if not Assigned(xInit) then begin Result := SQLITE_MISUSE; Exit; end;
  rc := sqlite3_initialize;
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  pMainMtx := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMainMtx);
  i := 0;
  while i < gAutoExtN do begin
    if Pointer(gAutoExt[i]) = Pointer(xInit) then break;
    Inc(i);
  end;
  if i = gAutoExtN then begin
    SetLength(gAutoExt, gAutoExtN + 1);
    gAutoExt[gAutoExtN] := xInit;
    Inc(gAutoExtN);
  end;
  sqlite3_mutex_leave(pMainMtx);
  Result := SQLITE_OK;
end;

{ sqlite3_cancel_auto_extension — loadext.c:858.  Returns 1 if removed,
  0 otherwise. }
function sqlite3_cancel_auto_extension(xInit: Tsqlite3_loadext_fn): i32;
var
  i, n    : i32;
  pMainMtx: Psqlite3_mutex;
begin
  if not Assigned(xInit) then begin Result := 0; Exit; end;
  n := 0;
  pMainMtx := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMainMtx);
  i := gAutoExtN - 1;
  while i >= 0 do begin
    if Pointer(gAutoExt[i]) = Pointer(xInit) then begin
      Dec(gAutoExtN);
      gAutoExt[i] := gAutoExt[gAutoExtN];
      Inc(n);
      break;
    end;
    Dec(i);
  end;
  sqlite3_mutex_leave(pMainMtx);
  Result := n;
end;

{ sqlite3_reset_auto_extension — loadext.c:886.  Faithful. }
procedure sqlite3_reset_auto_extension;
var
  pMainMtx: Psqlite3_mutex;
begin
  if sqlite3_initialize <> SQLITE_OK then Exit;
  pMainMtx := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMainMtx);
  SetLength(gAutoExt, 0);
  gAutoExtN := 0;
  sqlite3_mutex_leave(pMainMtx);
end;

end.
