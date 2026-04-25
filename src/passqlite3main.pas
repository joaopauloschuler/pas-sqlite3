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
  passqlite3codegen;

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

end.
