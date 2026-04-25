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
  passqlite3parser;  { Phase 8.2 — real sqlite3RunParser }

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
  sqlite3_create_module / _v2 — minimal createModule.

  Local Module record, mirroring sqliteInt.h:2211.  Allocated as a single
  block: SizeOf(TModule) + Length(zName) + 1 (the name is copied just past
  the struct, like sqlite3VtabCreateModule does).
  ---------------------------------------------------------------------- }
type
  TxModuleDestroy = procedure(p: Pointer); cdecl;
  TModule = record
    pModule:    Pointer;       { const sqlite3_module* }
    zName:      PAnsiChar;
    nRefModule: i32;
    _pad:       i32;
    pAux:       Pointer;
    xDestroy:   TxModuleDestroy;
    pEpoTab:    Pointer;       { Eponymous table — unused in Phase 8.3 }
  end;
  PTModule = ^TModule;

function createModule(db: PTsqlite3; zName: PAnsiChar; pModule: Pointer;
  pAux: Pointer; xDestroy: Pointer): i32;
var
  pMod, pDel: PTModule;
  zCopy:      PAnsiChar;
  nName:      i32;
  rc:         i32;
begin
  rc := SQLITE_OK;
  sqlite3_mutex_enter(db^.mutex);
  if pModule = nil then begin
    zCopy := zName;
    pMod  := nil;
  end else begin
    nName := sqlite3Strlen30(PChar(zName));
    pMod  := PTModule(sqlite3Malloc(SizeOf(TModule) + nName + 1));
    if pMod = nil then begin
      sqlite3OomFault(db);
      rc := sqlite3ApiExit(db, SQLITE_OK);
      sqlite3_mutex_leave(db^.mutex);
      if xDestroy <> nil then TxModuleDestroy(xDestroy)(pAux);
      Result := rc; Exit;
    end;
    zCopy := PAnsiChar(PByte(pMod) + SizeOf(TModule));
    Move(zName^, zCopy^, nName + 1);
    pMod^.zName      := zCopy;
    pMod^.pModule    := pModule;
    pMod^.pAux       := pAux;
    pMod^.xDestroy   := TxModuleDestroy(xDestroy);
    pMod^.pEpoTab    := nil;
    pMod^.nRefModule := 1;
  end;
  pDel := PTModule(sqlite3HashInsert(@db^.aModule, PChar(zCopy), pMod));
  if pDel <> nil then begin
    if pDel = pMod then begin
      { hash insert failed (OOM): Module is still in our hands. }
      sqlite3OomFault(db);
      sqlite3DbFree(Psqlite3db(db), pDel);
      pMod := nil;
    end else begin
      { Replaced an existing module of the same name.  Phase 8.3:
        no eponymous-table cleanup (vtab.c not ported); just call its
        destructor and free it. }
      if (pDel^.xDestroy <> nil) and (pDel^.pAux <> nil) then
        pDel^.xDestroy(pDel^.pAux);
      sqlite3_free(pDel);
    end;
  end;
  rc := sqlite3ApiExit(db, rc);
  if (rc <> SQLITE_OK) and (xDestroy <> nil) then
    TxModuleDestroy(xDestroy)(pAux);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
  if pMod = nil then ; { silence unused warning — pMod is observed via hash }
end;

function sqlite3_create_module(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer): i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  Result := createModule(db, zName, pModule, pAux, nil);
end;

function sqlite3_create_module_v2(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer; xDestroy: Pointer): i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  Result := createModule(db, zName, pModule, pAux, xDestroy);
end;

end.
