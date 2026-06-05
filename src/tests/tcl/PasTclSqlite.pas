unit PasTclSqlite;

{
  PasTclSqlite — Pascal port of the Sqlite3_Init exporter and the
  minimal DbMain/DbObjCmd surface from
  /home/bpsa/app/sqlite3/src/tclsqlite.c.

  Phase 9.4.2.c deliverable: `sqlite3 db1 :memory:` actually opens an
  in-memory connection (sqlite3_open_v2), registers a per-connection
  Tcl obj-cmd, and `db1 close` tears it down via DbDeleteCmd.

  Subcommands other than "close" return TCL_ERROR with
  "unknown subcommand" — `eval`/`version`/`function`/etc. land in
  9.4.2.d..f.

  Memory rule for SqliteDb: the record only carries pointer fields
  (db, zNull is PAnsiChar — pointer, not managed AnsiString) so
  New/Dispose is safe; see memory feedback_new_record_ansistring for
  the AnsiString trap we are deliberately avoiding.
}

{$mode objfpc}{$H+}

interface

uses ctypes, PasTclBridge;

function Sqlite3_Init(interp: PTclInterp): cint; cdecl;
function Sqlite3_SafeInit(interp: PTclInterp): cint; cdecl;

implementation

uses SysUtils, passqlite3types, passqlite3util, passqlite3main, passqlite3vdbe,
     passqlite3parser,
     passqlite3codegen, passqlite3dbstat, passqlite3backup, passqlite3os,
     passqlite3percentile, passqlite3regexp,
     TestModuleMd5, TestModuleTclvar, TestModuleBestindex,
     TestModuleTest1, TestModuleFunc,
     TestModuleMalloc, TestModuleEcho, TestModuleIoerr, TestModuleCrash,
     TestModuleVfs, TestModuleFts3, TestModuleSchema;

const
  { tclsqlite.c:121..122 — default and hard cap on the LRU statement cache. }
  NUM_PREPARED_STMTS = 10;
  MAX_PREPARED_STMTS = 100;

type
  { Minimal Tcl_Obj / Tcl_ObjType peek layout — first fields only.
    tcl.h (Tcl 8.6):
      typedef struct Tcl_Obj { int refCount; char *bytes; int length;
                               const Tcl_ObjType *typePtr; ... } Tcl_Obj;
      typedef struct Tcl_ObjType { const char *name; ... } Tcl_ObjType;
    Used solely by DbSqlFunc auto-detect to mirror tclsqlite.c:1108..1127
    which inspects pVar->typePtr->name and pVar->bytes.  Anything past
    typePtr is left untouched, so the union internalRep size mismatch
    between Tcl 8.6 / 9.x is irrelevant for this read-only peek. }
  PTclObjPeek = ^TTclObjPeek;
  TTclObjPeek = record
    refCount: cint;
    bytes:    PAnsiChar;
    length:   cint;
    typePtr:  Pointer;
  end;
  PTclObjTypePeek = ^TTclObjTypePeek;
  TTclObjTypePeek = record
    name: PAnsiChar;
  end;

var
  { Backing storage for the Tcl_LinkVar-exposed $SQLITE_MAX_ATTACHED.
    Initialised inside Sqlite3_Init; READ_ONLY on the Tcl side. }
  cv_max_attached: cint;
  { Backing storage for $SQLITE_MAX_COMPOUND_SELECT (test_config.c:814
    LINKVAR).  Required by select7.test.  READ_ONLY on the Tcl side. }
  cv_max_compound_select: cint;
  { Backing storage for $SQLITE_MAX_COLUMN (test_config.c:811 LINKVAR).
    Required by e_createtable-3-9.x.  READ_ONLY on the Tcl side. }
  cv_max_column: cint;

function TclObjTypeName(p: PTclObj): PAnsiChar;
var
  pk: PTclObjPeek;
  tp: PTclObjTypePeek;
begin
  Result := nil;
  if p = nil then Exit;
  pk := PTclObjPeek(p);
  tp := PTclObjTypePeek(pk^.typePtr);
  if tp = nil then Exit;
  Result := tp^.name;
end;

function TclObjHasNoStringRep(p: PTclObj): Boolean;
begin
  Result := (p <> nil) and (PTclObjPeek(p)^.bytes = nil);
end;

type
  PSqlFunc = ^TSqlFunc;
  PSqliteDb = ^TSqliteDb;

  { Per-UDF state.  Pas analogue of struct SqlFunc in tclsqlite.c:148..
    Only pointer-typed fields, so New/Dispose is safe (no managed
    AnsiString — see memory feedback_new_record_ansistring). }
  TSqlFunc = record
    pDb:      PSqliteDb;   { back-pointer for zNull/interp access (tclsqlite.c:154) }
    interp:   PTclInterp;  { tclsqlite.c:150 — the Tcl interp to eval into }
    pScript:  PTclObj;     { tclsqlite.c:151 — the user-supplied Tcl script,
                             refcount-incremented for our duration }
    eType:    cint;        { tclsqlite.c:153 — declared -returntype, or
                             SQLITE_NULL meaning "auto-detect" }
    useEvalObjv: cint;     { tclsqlite.c:153 — True if it is safe to use
                             Tcl_EvalObjv on the script (no $ [ ; chars) }
    pNext:    PSqlFunc;    { tclsqlite.c:156 — next on the per-db chain }
  end;

  PSqlCollate = ^TSqlCollate;
  { Per-collation state.  Pas analogue of struct SqlCollate in
    tclsqlite.c:163..168.  Only pointer fields, so New/Dispose is safe;
    zScript is Tcl_Alloc'd separately (upstream tacks it onto the same
    Tcl_Alloc block via `&pCollate[1]`). }
  TSqlCollate = record
    interp:   PTclInterp;  { tclsqlite.c:165 — the Tcl interp to eval into }
    zScript:  PAnsiChar;   { tclsqlite.c:166 — the comparison Tcl script }
    pNext:    PSqlCollate; { tclsqlite.c:167 — next on the per-db chain }
  end;

  { Per-cached-statement state.  Pas analogue of struct SqlPreparedStmt
    in tclsqlite.c:174..183.  Each entry holds a sqlite3_stmt*, the
    SQL text (owned by SQLite via sqlite3_sql), the nParm-sized apParm
    buffer of currently bound Tcl_Obj* references, and prev/next links
    for the LRU cache.  Allocated with Tcl_Alloc; apParm trails the
    record exactly as upstream's `&pPreStmt[1]` aliasing (9.4.2.x.1.a). }
  PDbEvalContext = ^TDbEvalContext;

  PSqlPreparedStmt = ^TSqlPreparedStmt;
  TSqlPreparedStmt = record
    pNext:  PSqlPreparedStmt;     { tclsqlite.c:176 — LRU next }
    pPrev:  PSqlPreparedStmt;     { tclsqlite.c:177 — LRU prev }
    pStmt:  Pointer;              { tclsqlite.c:178 — sqlite3_stmt* }
    nSql:   cint;                 { tclsqlite.c:179 — bytes in zSql[] }
    zSql:   PAnsiChar;            { tclsqlite.c:180 — SQL text (sqlite-owned) }
    nParm:  cint;                 { tclsqlite.c:181 — used slots in apParm }
    apParm: PPTclObj;             { tclsqlite.c:182 — &pPreStmt[1] in C }
  end;

  { DbEvalContext — Pas analogue of struct DbEvalContext in
    tclsqlite.c:1626..1636.  Drives the row-stepper loop across
    `pPreStmt` lifetimes so the script body can re-enter via NRE
    without the surrounding stack frame having to stay live.  Allocated
    by Tcl_Alloc for the NRE path (so dataarray pointers remain valid
    across continuation boundaries) — 9.4.2.x.1.c. }
  TDbEvalContext = record
    pDb:       PSqliteDb;       { tclsqlite.c:1628 — owning connection }
    pSql:      PTclObj;         { tclsqlite.c:1629 — held SQL Tcl_Obj }
    zSql:      PAnsiChar;       { tclsqlite.c:1630 — cursor into pSql }
    pPreStmt:  PSqlPreparedStmt;{ tclsqlite.c:1631 — current cached stmt }
    nCol:      cint;            { tclsqlite.c:1632 — column count snap }
    evalFlags: cint;            { tclsqlite.c:1633 — SQLITE_EVAL_* bits }
    pVarName:  PTclObj;         { tclsqlite.c:1634 — array name (or nil) }
    apColName: PPTclObj;        { tclsqlite.c:1635 — Tcl_Alloc'd col-name
                                  cache (or nil if not yet computed) }
  end;

  { Per-connection state.  Pas analogue of struct SqliteDb in
    tclsqlite.c:215..  Only the fields needed by 9.4.2.c..f are present;
    later sub-tasks will extend (stmt cache, hooks). }
  TSqliteDb = record
    db:     PTsqlite3;     { tclsqlite.c:216  — the sqlite3* handle }
    interp: PTclInterp;    { tclsqlite.c:217  — owning Tcl interp   }
    openFlags: cint;       { tclsqlite.c:226 — flags used to open, masked
                             to SQLITE_OPEN_URI; ORed into the target
                             open in the backup/restore arms (9.4.2.q). }
    zNull:  PAnsiChar;     { tclsqlite.c:230  — placeholder for NULL,
                             populated by the `nullvalue` subcmd in
                             9.4.2.e; held as raw PChar so this record
                             has no managed fields (no AnsiString,
                             see memory feedback_new_record_ansistring) }
    pFunc:  PSqlFunc;      { tclsqlite.c:209  — head of TSqlFunc chain,
                             populated by the `function` subcmd in
                             9.4.2.f.  Freed in DbDeleteCmd. }
    zTrace:   PAnsiChar;   { tclsqlite.c:201 — `trace` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
    zTraceV2: PAnsiChar;   { tclsqlite.c:202 — `trace_v2` callback script. }
    zProfile: PAnsiChar;   { tclsqlite.c:203 — `profile` callback script. }
    zAuth:    PAnsiChar;   { tclsqlite.c:206 — `authorizer` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
    zBusy:    PAnsiChar;   { tclsqlite.c:199 — `busy` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
    zProgress: PAnsiChar;  { tclsqlite.c:204 — `progress` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
    zCommit:   PAnsiChar;  { tclsqlite.c:200 — `commit_hook` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
    pUpdateHook:   PTclObj; { tclsqlite.c:222 — `update_hook` script Tcl_Obj. }
    pRollbackHook: PTclObj; { tclsqlite.c:223 — `rollback_hook` script Tcl_Obj. }
    pWalHook:      PTclObj; { tclsqlite.c:224 — `wal_hook` script Tcl_Obj. }
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
    pPreUpdateHook: PTclObj; { tclsqlite.c:211 — `preupdate hook` script. }
{$ENDIF}
{$IFDEF SQLITE_ENABLE_UNLOCK_NOTIFY}
    pUnlockNotify: PTclObj;  { tclsqlite.c:212 — `unlock_notify` script. }
{$ENDIF}
    pCollate:      PSqlCollate; { tclsqlite.c:215 — head of TSqlCollate chain,
                             populated by the `collate` subcmd.  Freed in
                             DbDeleteCmd. }
    pCollateNeeded: PTclObj; { tclsqlite.c:217 — `collation_needed` script. }
    nTransaction:  cint;   { tclsqlite.c:225 — nesting depth of [transaction]
                             sub-commands; 0 = no open [transaction]. }
    maxStmt:       cint;   { tclsqlite.c:228 — bound on the prepared-statement
                             cache.  This minimal bridge has no stmt cache,
                             so `db cache size N` just stores N here and
                             `db cache flush` is a no-op (9.4.2.o). }
    nRef:          cint;   { tclsqlite.c:227 — refcount.  Initially 1 (the
                             cmd-delete hook holds it); each DbEvalContext
                             /DbTransPostCmd continuation also pins us so
                             the SqliteDb survives nested [vwait]s
                             (9.4.2.x.1.b). }
    stmtList:      PSqlPreparedStmt;  { tclsqlite.c:218 — head of the LRU
                             cache list (9.4.2.x.1.a). }
    stmtLast:      PSqlPreparedStmt;  { tclsqlite.c:219 — tail of LRU. }
    nStmt:         cint;              { tclsqlite.c:221 — current cache
                             occupancy. }
    nStep:         cint;   { tclsqlite.c:223 — SQLITE_STMTSTATUS_FULLSCAN_STEP
                             for the most recent statement (9.4.6.c). }
    nSort:         cint;   { tclsqlite.c:223 — SQLITE_STMTSTATUS_SORT. }
    nIndex:        cint;   { tclsqlite.c:223 — SQLITE_STMTSTATUS_AUTOINDEX. }
    nVMStep:       cint;   { tclsqlite.c:224 — SQLITE_STMTSTATUS_VM_STEP. }
    pIncrblob:     Pointer; { tclsqlite.c:222 — head of the open-incrblob
                             channel chain (PIncrblobChannel).  Closed
                             en-masse by DbDeleteCmd (9.4.2.p). }
  end;

  { Pas analogue of struct IncrblobChannel — tclsqlite.c:233..241.
    Only pointer/scalar fields, Tcl_Alloc'd (matching upstream), so it
    never holds a managed AnsiString. }
  PIncrblobChannel = ^TIncrblobChannel;
  TIncrblobChannel = record
    pBlob:    Psqlite3_blob;     { tclsqlite.c:234 — sqlite3 blob handle }
    pDb:      PSqliteDb;         { tclsqlite.c:235 — owning connection }
    iSeek:    Int64;            { tclsqlite.c:236 — current seek offset }
    isClosed: cuint;            { tclsqlite.c:237 — TCL_CLOSE_READ/WRITE }
    channel:  TTclChannel;      { tclsqlite.c:238 — channel identifier }
    pNext:    PIncrblobChannel; { tclsqlite.c:239 }
    pPrev:    PIncrblobChannel; { tclsqlite.c:240 }
  end;

{ Forward decl: DbMain hands DbObjCmdAdaptor to Tcl_CreateObjCommand. }
function DbObjCmdAdaptor(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl; forward;
function DbEvalArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl; forward;
procedure DbDeleteCmd(clientData: TClientData); cdecl; forward;
procedure DbSqlFunc(pCtx: Psqlite3_context; argc: cint;
  argv: PPointer); cdecl; forward;
procedure DbSqlFuncDelete(pUser: Pointer); cdecl; forward;
function DbUseNre: Boolean; forward;

{ Pointer-arithmetic helper: objv is a flat `Tcl_Obj* const* `; treat
  it as a base pointer + index*sizeof(pointer).  Equivalent to objv[i]
  in C. }
function ObjvAt(objv: PPTclObj; i: cint): PTclObj; inline;
begin
  Result := (PPTclObj(PtrUInt(objv) + PtrUInt(i) * SizeOf(Pointer)))^;
end;

{ ======================================================================
  Incremental-blob Tcl channel — Pas port of tclsqlite.c:254..511
  (the SQLITE_OMIT_INCRBLOB-guarded block).  A `db incrblob` subcommand
  opens an sqlite3_blob handle and wraps it in a custom Tcl channel so
  the blob can be driven with `read`/`puts`/`seek`/`close`.
  ====================================================================== }

{ incrblobClose2 — tclsqlite.c:277.  Tcl_DriverClose2Proc.  When `flags`
  is non-zero Tcl only wants to half-close (record it and return); when
  zero we genuinely tear the channel down. }
function IncrblobClose2(instanceData: TClientData; interp: PTclInterp;
  flags: cint): cint; cdecl;
var
  p:  PIncrblobChannel;
  rc: cint;
  db: PTsqlite3;
begin
  p := PIncrblobChannel(instanceData);
  db := p^.pDb^.db;
  if flags <> 0 then
  begin
    p^.isClosed := p^.isClosed or cuint(flags);
    Result := TCL_OK;
    Exit;
  end;
  rc := sqlite3_blob_close(p^.pBlob);
  { Unlink from the SqliteDb.pIncrblob list — tclsqlite.c:294..303. }
  if p^.pNext <> nil then
    p^.pNext^.pPrev := p^.pPrev;
  if p^.pPrev <> nil then
    p^.pPrev^.pNext := p^.pNext;
  if PIncrblobChannel(p^.pDb^.pIncrblob) = p then
    p^.pDb^.pIncrblob := p^.pNext;
  Tcl_Free(PChar(p));
  if rc <> SQLITE_OK then
  begin
    Tcl_SetResult(interp, PChar(sqlite3_errmsg(db)), TCL_VOLATILE);
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
end;

{ incrblobClose — tclsqlite.c:314.  Tcl_DriverCloseProc thunk. }
function IncrblobClose(instanceData: TClientData; interp: PTclInterp): cint; cdecl;
begin
  Result := IncrblobClose2(instanceData, interp, 0);
end;

{ incrblobInput — tclsqlite.c:325.  Read up to bufSize bytes from the
  blob at the current seek offset, clamped to the blob length. }
function IncrblobInput(instanceData: TClientData; buf: PChar; bufSize: cint;
  errorCodePtr: pcint): cint; cdecl;
var
  p:     PIncrblobChannel;
  nRead: Int64;
  nBlob: Int64;
  rc:    cint;
begin
  p := PIncrblobChannel(instanceData);
  nRead := bufSize;
  nBlob := sqlite3_blob_bytes(p^.pBlob);
  if (p^.iSeek + nRead) > nBlob then
    nRead := nBlob - p^.iSeek;
  if nRead <= 0 then
  begin
    Result := 0;
    Exit;
  end;
  rc := sqlite3_blob_read(p^.pBlob, Pointer(buf), cint(nRead), cint(p^.iSeek));
  if rc <> SQLITE_OK then
  begin
    errorCodePtr^ := rc;
    Result := -1;
    Exit;
  end;
  p^.iSeek := p^.iSeek + nRead;
  Result := cint(nRead);
end;

{ incrblobOutput — tclsqlite.c:357.  Write toWrite bytes at the current
  seek offset; the blob cannot grow, so an over-long write is EINVAL. }
function IncrblobOutput(instanceData: TClientData; buf: PChar; toWrite: cint;
  errorCodePtr: pcint): cint; cdecl;
const
  EINVAL = 22;
  EIO    = 5;
var
  p:      PIncrblobChannel;
  nWrite: Int64;
  nBlob:  Int64;
  rc:     cint;
begin
  p := PIncrblobChannel(instanceData);
  nWrite := toWrite;
  nBlob := sqlite3_blob_bytes(p^.pBlob);
  if (p^.iSeek + nWrite) > nBlob then
  begin
    errorCodePtr^ := EINVAL;
    Result := -1;
    Exit;
  end;
  if nWrite <= 0 then
  begin
    Result := 0;
    Exit;
  end;
  rc := sqlite3_blob_write(p^.pBlob, Pointer(buf), cint(nWrite), cint(p^.iSeek));
  if rc <> SQLITE_OK then
  begin
    errorCodePtr^ := EIO;
    Result := -1;
    Exit;
  end;
  p^.iSeek := p^.iSeek + nWrite;
  Result := cint(nWrite);
end;

{ incrblobWideSeek — tclsqlite.c:397.  Tcl_DriverWideSeekProc. }
function IncrblobWideSeek(instanceData: TClientData; offset: Int64;
  seekMode: cint; errorCodePtr: pcint): Int64; cdecl;
var
  p: PIncrblobChannel;
begin
  p := PIncrblobChannel(instanceData);
  case seekMode of
    SEEK_SET: p^.iSeek := offset;
    SEEK_CUR: p^.iSeek := p^.iSeek + offset;
    SEEK_END: p^.iSeek := sqlite3_blob_bytes(p^.pBlob) + offset;
  end;
  Result := p^.iSeek;
end;

{ incrblobSeek — tclsqlite.c:421.  Narrow Tcl_DriverSeekProc thunk. }
function IncrblobSeek(instanceData: TClientData; offset: clong;
  seekMode: cint; errorCodePtr: pcint): cint; cdecl;
begin
  Result := cint(IncrblobWideSeek(instanceData, offset, seekMode, errorCodePtr));
end;

{ incrblobWatch — tclsqlite.c:431.  No-op. }
procedure IncrblobWatch(instanceData: TClientData; mask: cint); cdecl;
begin
end;

{ incrblobHandle — tclsqlite.c:437.  Always fails (no OS handle). }
function IncrblobHandle(instanceData: TClientData; direction: cint;
  handlePtr: PPointer): cint; cdecl;
begin
  Result := TCL_ERROR;
end;

{ IncrblobChannelType — tclsqlite.c:445.  Driver dispatch table. }
var
  IncrblobChannelType: TTclChannelType = (
    typeName:         'incrblob';
    version:          TCL_CHANNEL_VERSION_5;
    closeProc:        @IncrblobClose;
    inputProc:        @IncrblobInput;
    outputProc:       @IncrblobOutput;
    seekProc:         @IncrblobSeek;
    setOptionProc:    nil;
    getOptionProc:    nil;
    watchProc:        @IncrblobWatch;
    getHandleProc:    @IncrblobHandle;
    close2Proc:       @IncrblobClose2;
    blockModeProc:    nil;
    flushProc:        nil;
    handlerProc:      nil;
    wideSeekProc:     @IncrblobWideSeek;
    threadActionProc: nil;
    truncateProc:     nil;
  );

  { Channel-name counter — tclsqlite.c:489 `static int count`. }
  gIncrblobCount: cint = 0;

{ createIncrblobChannel — tclsqlite.c:466.  Opens the blob, allocates an
  IncrblobChannel, registers a "incrblob_N" channel, links it into the
  per-db chain, and returns the channel name as the interp result. }
function CreateIncrblobChannel(interp: PTclInterp; pDb: PSqliteDb;
  const zDb, zTable, zColumn: PAnsiChar; iRow: Int64;
  isReadonly: cint): cint;
var
  p:        PIncrblobChannel;
  db:       PTsqlite3;
  pBlob:    Psqlite3_blob;
  rc:       cint;
  flags:    cint;
  wrFlag:   cint;
  zChannel: array[0..63] of AnsiChar;
begin
  db := pDb^.db;
  flags := TCL_READABLE;
  if isReadonly = 0 then
    flags := flags or TCL_WRITABLE;
  if isReadonly <> 0 then wrFlag := 0 else wrFlag := 1;

  rc := sqlite3_blob_open(db, zDb, zTable, zColumn, iRow, wrFlag, pBlob);
  if rc <> SQLITE_OK then
  begin
    Tcl_SetResult(interp, PChar(sqlite3_errmsg(pDb^.db)), TCL_VOLATILE);
    Result := TCL_ERROR;
    Exit;
  end;

  p := PIncrblobChannel(Tcl_Alloc(SizeOf(TIncrblobChannel)));
  FillChar(p^, SizeOf(TIncrblobChannel), 0);
  p^.pBlob := pBlob;
  if (flags and TCL_WRITABLE) = 0 then
    p^.isClosed := p^.isClosed or cuint(TCL_CLOSE_WRITE);

  Inc(gIncrblobCount);
  StrPCopy(zChannel, 'incrblob_' + IntToStr(gIncrblobCount));
  p^.channel := Tcl_CreateChannel(@IncrblobChannelType, zChannel, p, flags);
  Tcl_RegisterChannel(interp, p^.channel);

  { Link into SqliteDb.pIncrblob — tclsqlite.c:500..507. }
  p^.pNext := PIncrblobChannel(pDb^.pIncrblob);
  p^.pPrev := nil;
  if p^.pNext <> nil then
    p^.pNext^.pPrev := p;
  pDb^.pIncrblob := p;
  p^.pDb := pDb;

  Tcl_SetResult(interp, Tcl_GetChannelName(p^.channel), TCL_VOLATILE);
  Result := TCL_OK;
end;

{ closeIncrblobChannels — tclsqlite.c:259.  Called from DbDeleteCmd at
  connection shutdown; Tcl_UnregisterChannel fires incrblobClose which
  frees each IncrblobChannel, so we must not touch p after that. }
procedure CloseIncrblobChannels(pDb: PSqliteDb);
var
  p, pNext: PIncrblobChannel;
begin
  p := PIncrblobChannel(pDb^.pIncrblob);
  while p <> nil do
  begin
    pNext := p^.pNext;
    Tcl_UnregisterChannel(pDb^.interp, p^.channel);
    p := pNext;
  end;
end;

{ DbIncrblobArm — tclsqlite.c:3468 (DB_INCRBLOB).  Parses
  `db incrblob ?-readonly? ?DB? TABLE COLUMN ROWID`. }
function DbIncrblobArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:        PSqliteDb;
  isReadonly: cint;
  zDb:        PAnsiChar;
  zTable:     PAnsiChar;
  zColumn:    PAnsiChar;
  iRow:       Int64;
  rc:         cint;
begin
  pDb := PSqliteDb(clientData);
  isReadonly := 0;
  zDb := 'main';

  { Check for the -readonly option — tclsqlite.c:3479. }
  if (objc > 3) and (StrComp(Tcl_GetString(ObjvAt(objv, 2)), '-readonly') = 0) then
    isReadonly := 1;

  if (objc <> (5 + isReadonly)) and (objc <> (6 + isReadonly)) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, '?-readonly? ?DB? TABLE COLUMN ROWID');
    Result := TCL_ERROR;
    Exit;
  end;

  if objc = (6 + isReadonly) then
    zDb := Tcl_GetString(ObjvAt(objv, 2 + isReadonly));
  zTable  := Tcl_GetString(ObjvAt(objv, objc - 3));
  zColumn := Tcl_GetString(ObjvAt(objv, objc - 2));
  rc := Tcl_GetWideIntFromObj(interp, ObjvAt(objv, objc - 1), @iRow);

  if rc = TCL_OK then
    rc := CreateIncrblobChannel(interp, pDb, zDb, zTable, zColumn,
                                iRow, isReadonly);
  Result := rc;
end;

{ DbFreeStmt — port of dbFreeStmt (tclsqlite.c:571..579).  Finalises
  the underlying sqlite3_stmt and Tcl_Free's the cache node.  The C
  build also Tcl_Free's the zSql copy when sqlite3_sql returns 0
  (SQLITE_TEST legacy path); we never take that path so the field is
  always sqlite-owned (9.4.2.x.1.a). }
procedure DbFreeStmt(pPS: PSqlPreparedStmt);
begin
  if pPS = nil then Exit;
  if pPS^.pStmt <> nil then
    sqlite3_finalize(pPS^.pStmt);
  Tcl_Free(PChar(pPS));
end;

{ FlushStmtCache — port of flushStmtCache (tclsqlite.c:584..595).
  Walks the LRU list freeing each node, then zeros the head/tail and
  count.  Called by delDatabaseRef and the `cache flush` arm. }
procedure FlushStmtCache(pDb: PSqliteDb);
var
  pPS, pNext: PSqlPreparedStmt;
begin
  pPS := pDb^.stmtList;
  while pPS <> nil do
  begin
    pNext := pPS^.pNext;
    DbFreeStmt(pPS);
    pPS := pNext;
  end;
  pDb^.nStmt    := 0;
  pDb^.stmtLast := nil;
  pDb^.stmtList := nil;
end;

{ AddDatabaseRef — port of addDatabaseRef (tclsqlite.c:601..603).  Each
  long-lived continuation (DbEvalContext, DbTransPostCmd) bumps nRef so
  the SqliteDb survives nested [vwait]s even if `db close` is issued
  from the script body (9.4.2.x.1.b). }
procedure AddDatabaseRef(pDb: PSqliteDb); inline;
begin
  Inc(pDb^.nRef);
end;

{ DelDatabaseRef — port of delDatabaseRef (tclsqlite.c:609..666).  When
  the last reference drops, we run the same teardown the previous
  monolithic DbDeleteCmd did.  This is the *only* place that frees the
  SqliteDb pointer (9.4.2.x.1.b). }
procedure DelDatabaseRef(pDb: PSqliteDb); forward;

{ DbDeleteCmd — Tcl_CmdDeleteProc invoked when the per-connection
  command is destroyed (either via `db1 close` -> Tcl_DeleteCommand,
  or via `rename db1 ""`).  Tears the SqliteDb down.

  Mirrors tclsqlite.c:670 (DbDeleteCmd) → delDatabaseRef → sqlite3_close
  path, collapsed because we have no refcount or hook state yet. }
procedure DbDeleteCmd(clientData: TClientData); cdecl;
begin
  { tclsqlite.c:672..675 — DbDeleteCmd is now a thin wrapper that just
    releases the cmd-delete ref.  Any pinned continuation (eval/trans)
    holds its own ref and prevents the underlying object from going
    until it returns (9.4.2.x.1.b). }
  if clientData = nil then Exit;
  DelDatabaseRef(PSqliteDb(clientData));
end;

procedure DelDatabaseRef(pDb: PSqliteDb);
var
  pColl: PSqlCollate;
begin
  Assert(pDb^.nRef > 0);
  Dec(pDb^.nRef);
  if pDb^.nRef > 0 then Exit;
  { Drop any cached prepared statements before the connection closes —
    tclsqlite.c:613 (flushStmtCache).  Required so sqlite3_close_v2
    doesn't leak the cached sqlite3_stmt handles (9.4.2.x.1.a). }
  FlushStmtCache(pDb);
  { Close any still-open incrblob channels before the connection goes —
    tclsqlite.c:614 (closeIncrblobChannels in the DbDeleteCmd path). }
  CloseIncrblobChannels(pDb);
  { sqlite3_close_v2 fires our DbSqlFuncDelete xDestroy hook for every
    TSqlFunc previously registered via sqlite3_create_function_v2, which
    decrefs pScript and Disposes each chain entry.  After this call the
    pFunc list is fully dangling, so we just nil the head.  Compare
    tclsqlite.c:617..630 where the equivalent C path walks p->pFunc
    explicitly because the C build uses _create_function (no _v2) and
    therefore needs manual teardown; we have _v2 and lean on it. }
  if pDb^.db <> nil then
    sqlite3_close_v2(pDb^.db);
  pDb^.pFunc := nil;
  { Free zNull buffer if any — owned by us, see DbNullValueArm.  Pairs
    with the GetMem in the nullvalue setter (9.4.2.e). }
  if pDb^.zNull <> nil then
  begin
    FreeMem(pDb^.zNull);
    pDb^.zNull := nil;
  end;
  { Free trace/profile callback scripts — tclsqlite.c:631..639. }
  if pDb^.zTrace <> nil then
  begin
    Tcl_Free(pDb^.zTrace);
    pDb^.zTrace := nil;
  end;
  if pDb^.zTraceV2 <> nil then
  begin
    Tcl_Free(pDb^.zTraceV2);
    pDb^.zTraceV2 := nil;
  end;
  if pDb^.zProfile <> nil then
  begin
    Tcl_Free(pDb^.zProfile);
    pDb^.zProfile := nil;
  end;
  { Free authorizer callback script — tclsqlite.c:643..645. }
  if pDb^.zAuth <> nil then
  begin
    Tcl_Free(pDb^.zAuth);
    pDb^.zAuth := nil;
  end;
  { Free busy callback script — tclsqlite.c:628..630. }
  if pDb^.zBusy <> nil then
  begin
    Tcl_Free(pDb^.zBusy);
    pDb^.zBusy := nil;
  end;
  { Free progress callback script — tclsqlite.c:631..633. }
  if pDb^.zProgress <> nil then
  begin
    Tcl_Free(pDb^.zProgress);
    pDb^.zProgress := nil;
  end;
  { Free change-notification hook scripts — tclsqlite.c:646..651. }
  if pDb^.zCommit <> nil then
  begin
    Tcl_Free(pDb^.zCommit);
    pDb^.zCommit := nil;
  end;
  if pDb^.pUpdateHook <> nil then
  begin
    Tcl_DecrRefCount(pDb^.pUpdateHook);
    pDb^.pUpdateHook := nil;
  end;
  if pDb^.pRollbackHook <> nil then
  begin
    Tcl_DecrRefCount(pDb^.pRollbackHook);
    pDb^.pRollbackHook := nil;
  end;
  if pDb^.pWalHook <> nil then
  begin
    Tcl_DecrRefCount(pDb^.pWalHook);
    pDb^.pWalHook := nil;
  end;
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
  { Free the pre-update hook script — tclsqlite.c:652..654. }
  if pDb^.pPreUpdateHook <> nil then
  begin
    Tcl_DecrRefCount(pDb^.pPreUpdateHook);
    pDb^.pPreUpdateHook := nil;
  end;
{$ENDIF}
  { Free Tcl-callback collations — tclsqlite.c:622..627.  Walk the
    pCollate chain, freeing each zScript buffer and the node itself. }
  while pDb^.pCollate <> nil do
  begin
    pColl := pDb^.pCollate;
    pDb^.pCollate := pColl^.pNext;
    if pColl^.zScript <> nil then
      Tcl_Free(pColl^.zScript);
    Dispose(pColl);
  end;
  { Free collation-needed script — tclsqlite.c:660..662. }
  if pDb^.pCollateNeeded <> nil then
  begin
    Tcl_DecrRefCount(pDb^.pCollateNeeded);
    pDb^.pCollateNeeded := nil;
  end;
  Dispose(pDb);
end;

{ DbBindOneParam — 9.4.divbug.60.  Resolves a single `$NAME` / `:NAME` /
  `@NAME` bind parameter against the calling Tcl scope and dispatches on
  the resolved Tcl_Obj's typePtr->name to pick the matching
  sqlite3_bind_xxx flavour.  Mirrors tclsqlite.c:1491..1556 (the typed-
  bind ladder added for divbug.60).  When pPS is non-nil the BLOB/text
  branches stash an incref'd reference in apParm[iParm^] so the bytes
  survive until DbReleaseStmt drops them; when pPS is nil (objc==3 flat
  list path which finalises immediately) we hand SQLite SQLITE_TRANSIENT
  copies instead.  Returns True if the parameter was bound, False if the
  name didn't match the supported prefixes.  Sibling of divbug.29's
  DbSqlFunc auto-detect peek. }
function DbBindOneParam(pDb: PSqliteDb; pStmt: Pointer; i: cint;
                        zParamName: PAnsiChar;
                        pPS: PSqlPreparedStmt; iParm: pcint): Boolean;
var
  pVarObj: PTclObj;
  zType:   PAnsiChar;
  tc:      AnsiChar;
  nBytes:  cint;
  nBool:   cint;
  wVal:    Int64;
  rVal:    Double;
  pBlob:   PChar;
  pVarStr: PChar;
  xDel:    TxDelProc;
begin
  Result := False;
  if (zParamName = nil) or
     ((zParamName[0] <> '$') and (zParamName[0] <> ':')
      and (zParamName[0] <> '@')) then Exit;
  Result := True;
  pVarObj := Tcl_GetVar2Ex(pDb^.interp, zParamName + 1, nil, 0);
  if pVarObj = nil then
  begin
    sqlite3_bind_null(pStmt, i);
    Exit;
  end;
  zType := TclObjTypeName(pVarObj);
  if zType = nil then tc := #0 else tc := zType[0];

  { Choose SQLITE_STATIC + apParm[]-incref when we have a stmt cache
    node to anchor the lifetime; otherwise SQLITE_TRANSIENT so SQLite
    copies the bytes itself before the row loop. }
  if (pPS <> nil) and (iParm <> nil) then
    xDel := SQLITE_STATIC
  else
    xDel := SQLITE_TRANSIENT;

  { tclsqlite.c:1519..1527 — '@' always BLOB; bytearray w/o string rep
    also goes BLOB. }
  if (zParamName[0] = '@') or
     ((tc = 'b') and TclObjHasNoStringRep(pVarObj)
        and (StrComp(zType, 'bytearray') = 0)) then
  begin
    pBlob := Tcl_GetByteArrayFromObj(pVarObj, @nBytes);
    sqlite3_bind_blob(pStmt, i, pBlob, nBytes, xDel);
    if pPS <> nil then
    begin
      Tcl_IncrRefCount(pVarObj);
      (PPTclObj(PtrUInt(pPS^.apParm) + PtrUInt(iParm^)*SizeOf(Pointer)))^
        := pVarObj;
      Inc(iParm^);
    end;
  end
  else if (tc = 'b') and TclObjHasNoStringRep(pVarObj)
       and ((StrComp(zType, 'booleanString') = 0)
            or (StrComp(zType, 'boolean') = 0)) then
  begin
    { tclsqlite.c:1528..1534. }
    Tcl_GetBooleanFromObj(pDb^.interp, pVarObj, @nBool);
    sqlite3_bind_int(pStmt, i, nBool);
  end
  else if (tc = 'd') and (StrComp(zType, 'double') = 0) then
  begin
    { tclsqlite.c:1535..1538. }
    Tcl_GetDoubleFromObj(pDb^.interp, pVarObj, @rVal);
    sqlite3_bind_double(pStmt, i, rVal);
  end
  else if ((tc = 'w') and (StrComp(zType, 'wideInt') = 0))
       or ((tc = 'i') and (StrComp(zType, 'int') = 0)) then
  begin
    { tclsqlite.c:1539..1543. }
    Tcl_GetWideIntFromObj(pDb^.interp, pVarObj, @wVal);
    sqlite3_bind_int64(pStmt, i, wVal);
  end
  else
  begin
    { tclsqlite.c:1544..1549 — UTF-8 text fallback. }
    pVarStr := Tcl_GetStringFromObj(pVarObj, @nBytes);
    sqlite3_bind_text64(pStmt, i, pVarStr, u64(nBytes), xDel, SQLITE_UTF8);
    if pPS <> nil then
    begin
      Tcl_IncrRefCount(pVarObj);
      (PPTclObj(PtrUInt(pPS^.apParm) + PtrUInt(iParm^)*SizeOf(Pointer)))^
        := pVarObj;
      Inc(iParm^);
    end;
  end;
end;

{ DbPrepareAndBind — minimal port of dbPrepareAndBind
  (tclsqlite.c:1392..1562).  Looks up the first SQL statement in `zIn`
  against the LRU cache; if not found, prepares it (with
  SQLITE_PREPARE_PERSISTENT iff maxStmt>5, mirroring tclsqlite.c:1369..
  1374) and allocates a fresh SqlPreparedStmt.  Then walks the bind
  parameters and copies `$NAME` / `:NAME` / `@NAME` substitutions from
  the surrounding Tcl scope as text (the upstream typed-binding
  shortcuts — int/double/bytearray — are intentionally elided here;
  the existing DbEvalArm did the same and the smoke gates do not
  exercise them).

  On success *ppPS is set to a node OWNED BY THE CALLER (unlinked from
  the cache); on `zSql` consisting of only whitespace/comments,
  *ppPS is left nil and TCL_OK returned (matches upstream:1463).
  9.4.2.x.1.a. }
function DbPrepareAndBind(pDb: PSqliteDb; zIn: PAnsiChar;
  pzOut: PPAnsiChar; ppPS: PPointer): cint;
var
  zSql:       PAnsiChar;
  pStmt:      Pointer;
  pPS:        PSqlPreparedStmt;
  nSql:       cint;
  n:          cint;
  nVar:       cint;
  iParm:      cint;
  i:          cint;
  prepFlags:  u32;
  nByte:      PtrUInt;
  zParamName: PAnsiChar;
  rc:         cint;
begin
  ppPS^ := nil;
  zSql := zIn;
  { Trim leading whitespace — tclsqlite.c:1413. }
  while (zSql^ = ' ') or (zSql^ = #9) or (zSql^ = #10) or (zSql^ = #13) do
    Inc(zSql);
  nSql := 0;
  while zSql[nSql] <> #0 do Inc(nSql);

  { Linear LRU lookup — tclsqlite.c:1416..1443. }
  pPS := pDb^.stmtList;
  pStmt := nil;
  while pPS <> nil do
  begin
    n := pPS^.nSql;
    if (nSql >= n) and (CompareByte(pPS^.zSql^, zSql^, n) = 0) and
       ((zSql[n] = #0) or (zSql[n-1] = ';')) then
    begin
      pStmt := pPS^.pStmt;
      pzOut^ := zSql + pPS^.nSql;
      { Unlink from cache — tclsqlite.c:1429..1438. }
      if pPS^.pPrev <> nil then
        pPS^.pPrev^.pNext := pPS^.pNext
      else
        pDb^.stmtList := pPS^.pNext;
      if pPS^.pNext <> nil then
        pPS^.pNext^.pPrev := pPS^.pPrev
      else
        pDb^.stmtLast := pPS^.pPrev;
      Dec(pDb^.nStmt);
      break;
    end;
    pPS := pPS^.pNext;
  end;

  if pPS = nil then
  begin
    { Compile a fresh statement — tclsqlite.c:1447..1484. }
    prepFlags := 0;
    if pDb^.maxStmt > 5 then prepFlags := $01;  { SQLITE_PREPARE_PERSISTENT — passqlite3main.pas:1046 }
    pStmt := nil;
    rc := sqlite3_prepare_v3(pDb^.db, zSql, -1, prepFlags, @pStmt, pzOut);
    if rc <> SQLITE_OK then
    begin
      Tcl_SetObjResult(pDb^.interp,
        Tcl_NewStringObj(sqlite3_errmsg(pDb^.db), -1));
      Result := TCL_ERROR;
      Exit;
    end;
    if pStmt = nil then
    begin
      if sqlite3_errcode(pDb^.db) <> SQLITE_OK then
      begin
        Tcl_SetObjResult(pDb^.interp,
          Tcl_NewStringObj(sqlite3_errmsg(pDb^.db), -1));
        Result := TCL_ERROR;
        Exit;
      end;
      { No-op statement (comment / whitespace) — tclsqlite.c:1460..1464. }
      Result := TCL_OK;
      Exit;
    end;
    nVar := sqlite3_bind_parameter_count(pStmt);
    nByte := SizeOf(TSqlPreparedStmt) + PtrUInt(nVar) * SizeOf(Pointer);
    pPS := PSqlPreparedStmt(Tcl_Alloc(cuint(nByte)));
    FillChar(pPS^, nByte, 0);
    pPS^.pStmt := pStmt;
    pPS^.nSql  := cint(pzOut^ - zSql);
    pPS^.zSql  := sqlite3_sql(pStmt);
    pPS^.apParm := PPTclObj(PtrUInt(pPS) + SizeOf(TSqlPreparedStmt));
  end;

  Assert(pPS <> nil);
  nVar := sqlite3_bind_parameter_count(pStmt);
  iParm := 0;
  { Walk bind parameters — tclsqlite.c:1491..1556 via DbBindOneParam
    helper (9.4.divbug.60).  apParm[] anchors incref'd Tcl_Obj refs for
    the BLOB / text branches so SQLITE_STATIC bytes stay live until
    DbReleaseStmt drops them. }
  for i := 1 to nVar do
  begin
    zParamName := sqlite3_bind_parameter_name(pStmt, i);
    DbBindOneParam(pDb, pStmt, i, zParamName, pPS, @iParm);
  end;
  pPS^.nParm := iParm;
  ppPS^ := pPS;
  Result := TCL_OK;
end;

{ DbReleaseStmt — port of dbReleaseStmt (tclsqlite.c:1573..1614).
  Drops the Tcl_Obj* references held by apParm, then either inserts at
  the head of the LRU cache (re-using the node for the next match) or
  finalises immediately when the cache is disabled / the caller flags
  `discard`.  Eviction from the tail keeps `nStmt <= maxStmt`
  (9.4.2.x.1.a). }
procedure DbReleaseStmt(pDb: PSqliteDb; pPS: PSqlPreparedStmt;
  discard: cint);
var
  i:     cint;
  pLast: PSqlPreparedStmt;
  pParm: PTclObj;
begin
  if pPS = nil then Exit;
  { Drop the apParm[i] references — tclsqlite.c:1581..1583. }
  for i := 0 to pPS^.nParm - 1 do
  begin
    pParm := (PPTclObj(PtrUInt(pPS^.apParm) + PtrUInt(i)*SizeOf(Pointer)))^;
    if pParm <> nil then Tcl_DecrRefCount(pParm);
  end;
  pPS^.nParm := 0;

  if (pDb^.maxStmt <= 0) or (discard <> 0) then
  begin
    DbFreeStmt(pPS);
    Exit;
  end;

  { Push at the head of the LRU list — tclsqlite.c:1591..1603. }
  pPS^.pNext := pDb^.stmtList;
  pPS^.pPrev := nil;
  if pDb^.stmtList <> nil then
    pDb^.stmtList^.pPrev := pPS;
  pDb^.stmtList := pPS;
  if pDb^.stmtLast = nil then
    pDb^.stmtLast := pPS;
  Inc(pDb^.nStmt);

  { Evict from the tail to enforce maxStmt — tclsqlite.c:1607..1613. }
  while pDb^.nStmt > pDb^.maxStmt do
  begin
    pLast := pDb^.stmtLast;
    pDb^.stmtLast := pLast^.pPrev;
    if pDb^.stmtLast <> nil then
      pDb^.stmtLast^.pNext := nil
    else
      pDb^.stmtList := nil;
    Dec(pDb^.nStmt);
    DbFreeStmt(pLast);
  end;
end;

{ ----------------------------------------------------------------------
  dbEvalXxx split — Pas port of tclsqlite.c:1645..1876.  Lifecycle:

      DbEvalInit(p, pDb, pSql, pVarName, evalFlags)
      while DbEvalStep(p)==TCL_OK do
        DbEvalRowInfo(p, &nCol, &apColName)
        ... DbEvalColumnValueCtx(p, i) ...
      DbEvalFinalize(p)

  Behaviour-identical to the C reference; introduced in 9.4.2.x.1.c
  ahead of the NRE wiring in 9.4.2.x.1.d.  The existing DbEvalArm 2-arg
  flat-list path is NOT routed through this split yet — it remains on
  the direct prepare/step loop (the gate guarantee from the task brief).
  ---------------------------------------------------------------------- }

const
  SQLITE_EVAL_WITHOUTNULLS = $00001;  { tclsqlite.c:1638 }
  SQLITE_EVAL_ASDICT       = $00002;  { tclsqlite.c:1639 }

procedure DbReleaseColumnNames(p: PDbEvalContext);
var
  i: cint;
  pCol: PTclObj;
begin
  if p^.apColName <> nil then
  begin
    for i := 0 to p^.nCol - 1 do
    begin
      pCol := (PPTclObj(PtrUInt(p^.apColName) + PtrUInt(i)*SizeOf(Pointer)))^;
      if pCol <> nil then Tcl_DecrRefCount(pCol);
    end;
    Tcl_Free(PChar(p^.apColName));
    p^.apColName := nil;
  end;
  p^.nCol := 0;
end;

procedure DbEvalInit(p: PDbEvalContext; pDb: PSqliteDb; pSql: PTclObj;
  pVarName: PTclObj; evalFlags: cint);
begin
  FillChar(p^, SizeOf(TDbEvalContext), 0);
  p^.pDb := pDb;
  p^.zSql := Tcl_GetString(pSql);
  p^.pSql := pSql;
  Tcl_IncrRefCount(pSql);
  if pVarName <> nil then
  begin
    p^.pVarName := pVarName;
    Tcl_IncrRefCount(pVarName);
  end;
  p^.evalFlags := evalFlags;
  AddDatabaseRef(p^.pDb);
end;

procedure DbEvalRowInfo(p: PDbEvalContext; pnCol: pcint;
  papColName: PPointer);
var
  pStmt:     Pointer;
  i, nCol:   cint;
  apColName: PPTclObj;
  slot:      PPTclObj;
  pColList:  PTclObj;
  pStar:     PTclObj;
begin
  if p^.apColName = nil then
  begin
    pStmt := p^.pPreStmt^.pStmt;
    nCol := sqlite3_column_count(pStmt);
    p^.nCol := nCol;
    apColName := nil;
    if (nCol > 0) and ((papColName <> nil) or (p^.pVarName <> nil)) then
    begin
      apColName := PPTclObj(Tcl_Alloc(cuint(SizeOf(Pointer) * nCol)));
      for i := 0 to nCol - 1 do
      begin
        slot := PPTclObj(PtrUInt(apColName) + PtrUInt(i)*SizeOf(Pointer));
        slot^ := Tcl_NewStringObj(sqlite3_column_name(pStmt, i), -1);
        Tcl_IncrRefCount(slot^);
      end;
      p^.apColName := apColName;
    end;
    { Populate target(*) — tclsqlite.c:1718..1744 (array form only;
      dict form is identical in spec but unused by the smoke gates). }
    if (p^.pVarName <> nil) and (apColName <> nil) and
       ((p^.evalFlags and SQLITE_EVAL_ASDICT) = 0) then
    begin
      pColList := Tcl_NewListObj(0, nil);
      pStar    := Tcl_NewStringObj('*', -1);
      Tcl_IncrRefCount(pColList);
      Tcl_IncrRefCount(pStar);
      for i := 0 to nCol - 1 do
      begin
        slot := PPTclObj(PtrUInt(apColName) + PtrUInt(i)*SizeOf(Pointer));
        Tcl_ListObjAppendElement(p^.pDb^.interp, pColList, slot^);
      end;
      Tcl_ObjSetVar2(p^.pDb^.interp, p^.pVarName, pStar, pColList, 0);
      Tcl_DecrRefCount(pStar);
      Tcl_DecrRefCount(pColList);
    end;
  end;
  if papColName <> nil then papColName^ := p^.apColName;
  if pnCol <> nil then pnCol^ := p^.nCol;
end;

{ DbEvalStep — port of dbEvalStep (tclsqlite.c:1766..1823).  Returns
  TCL_OK  when a row is available (caller may call RowInfo/ColumnValue),
  TCL_BREAK when the SQL script is exhausted, or TCL_ERROR on failure
  (with the error message already loaded into pDb^.interp).  Drives
  prepared-statement reuse through DbPrepareAndBind/DbReleaseStmt. }
function DbEvalStep(p: PDbEvalContext): cint;
var
  rc, rcs: cint;
  pDb:     PSqliteDb;
  pPS:     PSqlPreparedStmt;
  pStmt:   Pointer;
begin
  while (p^.zSql[0] <> #0) or (p^.pPreStmt <> nil) do
  begin
    if p^.pPreStmt = nil then
    begin
      rc := DbPrepareAndBind(p^.pDb, p^.zSql, @p^.zSql, @p^.pPreStmt);
      if rc <> TCL_OK then begin Result := rc; Exit; end;
    end
    else
    begin
      pDb   := p^.pDb;
      pPS   := p^.pPreStmt;
      pStmt := pPS^.pStmt;
      rcs   := sqlite3_step(pStmt);
      if rcs = SQLITE_ROW then begin Result := TCL_OK; Exit; end;
      if p^.pVarName <> nil then
        DbEvalRowInfo(p, nil, nil);
      rcs := sqlite3_reset(pStmt);

      pDb^.nStep   := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_FULLSCAN_STEP, 1);
      pDb^.nSort   := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_SORT, 1);
      pDb^.nIndex  := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_AUTOINDEX, 1);
      pDb^.nVMStep := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_VM_STEP, 1);

      DbReleaseColumnNames(p);
      p^.pPreStmt := nil;

      if rcs <> SQLITE_OK then
      begin
        DbReleaseStmt(pDb, pPS, 1);
        Tcl_SetObjResult(pDb^.interp,
          Tcl_NewStringObj(sqlite3_errmsg(pDb^.db), -1));
        Result := TCL_ERROR;
        Exit;
      end
      else
        DbReleaseStmt(pDb, pPS, 0);
    end;
  end;
  Result := TCL_BREAK;
end;

procedure DbEvalFinalize(p: PDbEvalContext);
begin
  if p^.pPreStmt <> nil then
  begin
    sqlite3_reset(p^.pPreStmt^.pStmt);
    DbReleaseStmt(p^.pDb, p^.pPreStmt, 0);
    p^.pPreStmt := nil;
  end;
  if p^.pVarName <> nil then
  begin
    Tcl_DecrRefCount(p^.pVarName);
    p^.pVarName := nil;
  end;
  if p^.pSql <> nil then
  begin
    Tcl_DecrRefCount(p^.pSql);
    p^.pSql := nil;
  end;
  DbReleaseColumnNames(p);
  DelDatabaseRef(p^.pDb);
end;

{ Context-aware sibling of DbEvalColumnValue (the existing free-stmt
  helper).  Mirrors tclsqlite.c:1850..1876 verbatim. }
function DbEvalColumnValueCtx(p: PDbEvalContext; iCol: cint): PTclObj;
var
  pStmt: Pointer;
  v:     Int64;
  nByte: cint;
  zBlob: Pointer;
  zNullStr: PAnsiChar;
  emptyNull: array[0..0] of AnsiChar;
begin
  pStmt := p^.pPreStmt^.pStmt;
  case sqlite3_column_type(pStmt, iCol) of
    SQLITE_BLOB:
      begin
        nByte := sqlite3_column_bytes(pStmt, iCol);
        zBlob := sqlite3_column_blob(pStmt, iCol);
        if zBlob = nil then nByte := 0;
        Result := Tcl_NewByteArrayObj(zBlob, nByte);
      end;
    SQLITE_INTEGER:
      begin
        v := sqlite3_column_int64(pStmt, iCol);
        if (v >= -2147483647) and (v <= 2147483647) then
          Result := Tcl_NewIntObj(cint(v))
        else
          Result := Tcl_NewWideIntObj(v);
      end;
    SQLITE_FLOAT:
      Result := Tcl_NewDoubleObj(sqlite3_column_double(pStmt, iCol));
    SQLITE_NULL:
      begin
        emptyNull[0] := #0;
        if p^.pDb^.zNull <> nil then zNullStr := p^.pDb^.zNull
        else zNullStr := @emptyNull[0];
        Result := Tcl_NewStringObj(zNullStr, -1);
      end;
  else
    Result := Tcl_NewStringObj(sqlite3_column_text(pStmt, iCol), -1);
  end;
end;

{ DbEvalNextCmd — port of DbEvalNextCmd (tclsqlite.c:1915..2005).
  TTclNRPostProc continuation: receives the DbEvalContext* in data[0]
  and the per-row script Tcl_Obj* in data[1].  Walks dbEvalStep, sets
  the array/scalar bindings for each row, and either re-schedules
  itself via Tcl_NRAddCallback+Tcl_NREvalObj (when DbUseNre is true,
  the upstream-canonical path) or falls back to recursive Tcl_EvalObjEx
  (which collapses to the pre-9.4.2.x.1.d behaviour).  On exhaustion
  releases the context and returns TCL_OK / TCL_BREAK normalisation
  (9.4.2.x.1.d). }
function DbEvalNextCmd(data: PClientDataArray; interp: PTclInterp;
  bodyRc: cint): cint; cdecl;
var
  p:         PDbEvalContext;
  pScript:   PTclObj;
  pVarName:  PTclObj;
  rc:        cint;
  i, nCol:   cint;
  apColName: PPTclObj;
  slot:      PPTclObj;
  pColName:  PTclObj;
  pColVal:   PTclObj;
  data1:     PClientDataArray;
begin
  rc := bodyRc;
  p := PDbEvalContext(data^);
  data1 := PClientDataArray(PtrUInt(data) + SizeOf(TClientData));
  pScript := PTclObj(data1^);
  pVarName := p^.pVarName;

  while (rc = TCL_OK) or (rc = TCL_CONTINUE) do
  begin
    rc := DbEvalStep(p);
    if rc <> TCL_OK then break;
    DbEvalRowInfo(p, @nCol, @apColName);
    for i := 0 to nCol - 1 do
    begin
      slot := PPTclObj(PtrUInt(apColName) + PtrUInt(i)*SizeOf(Pointer));
      pColName := slot^;
      pColVal  := DbEvalColumnValueCtx(p, i);
      if pVarName = nil then
        Tcl_ObjSetVar2(interp, pColName, nil, pColVal, 0)
      else
        Tcl_ObjSetVar2(interp, pVarName, pColName, pColVal, 0);
    end;

    { 9.4.divbug.28 — the NRE per-row continuation path crashes (Tcl
      jumps to a stale function-pointer in TclNRRunCallbacks) once the
      first row of any multi-row EXPLAIN QUERY PLAN / SELECT is consumed
      from inside the script body.  Until the NRE plumbing is fully
      audited (the comment block at DbObjCmdNRE flags this as a
      follow-up to 9.4.2.x), evaluate the per-row script recursively —
      this is upstream's !DbUseNre() branch (tclsqlite.c:1992) and
      passes eqp2/cost/fordelete/delete2 cleanly. }
    rc := Tcl_EvalObjEx(interp, pScript, 0);
  end;

  Tcl_DecrRefCount(pScript);
  DbEvalFinalize(p);
  Tcl_Free(PChar(p));

  if (rc = TCL_OK) or (rc = TCL_BREAK) then
  begin
    Tcl_ResetResult(interp);
    rc := TCL_OK;
  end;
  Result := rc;
end;

{ DbEvalScriptArm — entry point for the 3/4/5-arg script-body form of
  `db eval` when DbUseNre is true (tclsqlite.c:3340..3360).  Allocates
  a DbEvalContext via Tcl_Alloc, runs DbEvalInit, then hands control
  over to DbEvalNextCmd by pretending it is the first continuation
  with bodyRc=TCL_OK.  When DbUseNre is false the original synchronous
  DbEvalArm path is used (callers gate on DbUseNre before invoking us).
  9.4.2.x.1.d. }
function DbEvalScriptArm(pDb: PSqliteDb; interp: PTclInterp;
  pSql, pVarName, pScript: PTclObj): cint;
var
  p:   PDbEvalContext;
  cd2: array[0..1] of TClientData;  { tclsqlite.c:3340 — ClientData cd2[2] }
begin
  p := PDbEvalContext(Tcl_Alloc(SizeOf(TDbEvalContext)));
  FillChar(p^, SizeOf(TDbEvalContext), 0);
  DbEvalInit(p, pDb, pSql, pVarName, 0);
  Tcl_IncrRefCount(pScript);
  cd2[0] := TClientData(p);
  cd2[1] := TClientData(pScript);
  { Mirrors tclsqlite.c:3356 — first hop is a direct call; subsequent
    hops happen through the Tcl_NRAddCallback inside DbEvalNextCmd. }
  Result := DbEvalNextCmd(PClientDataArray(@cd2[0]), interp, TCL_OK);
end;

{ DbEvalColumnValue — Pas port of dbEvalColumnValue (tclsqlite.c:1850..1876).
  Returns a fresh (refcount-0) typed Tcl_Obj for column iCol of the row the
  statement currently points at:
    SQLITE_INTEGER -> Tcl_NewWideIntObj  (via sqlite3_column_int64)
    SQLITE_FLOAT   -> Tcl_NewDoubleObj
    SQLITE_BLOB    -> Tcl_NewByteArrayObj
    SQLITE_NULL    -> Tcl_NewStringObj(zNull, -1)
    else (text)    -> Tcl_NewStringObj(sqlite3_column_text, -1)
  Divergence vs upstream: upstream narrows small int64 to Tcl_NewIntObj; we
  always use Tcl_NewWideIntObj — Tcl stringifies both identically and the
  numeric value is exact, so no observable difference. }
function DbEvalColumnValue(pStmt: Pointer; iCol: cint;
  zNullStr: PAnsiChar): PTclObj;
var
  zBlob: Pointer;
  nByte: cint;
  zTxt:  PAnsiChar;
begin
  case sqlite3_column_type(pStmt, iCol) of
    SQLITE_INTEGER:
      Result := Tcl_NewWideIntObj(sqlite3_column_int64(pStmt, iCol));
    SQLITE_FLOAT:
      Result := Tcl_NewDoubleObj(sqlite3_column_double(pStmt, iCol));
    SQLITE_BLOB:
      begin
        nByte := sqlite3_column_bytes(pStmt, iCol);
        zBlob := sqlite3_column_blob(pStmt, iCol);
        if zBlob = nil then nByte := 0;
        Result := Tcl_NewByteArrayObj(zBlob, nByte);
      end;
    SQLITE_NULL:
      Result := Tcl_NewStringObj(zNullStr, -1);
    else
      begin
        zTxt := sqlite3_column_text(pStmt, iCol);
        Result := Tcl_NewStringObj(zTxt, -1);
      end;
  end;
end;

{ DbEvalArm — port of the "eval" arm of DbObjCmd (tclsqlite.c:3299..3360)
  plus the row-stepper loop body from dbEvalStep (tclsqlite.c:1766..1823)
  and DbEvalNextCmd (tclsqlite.c:1915..2005).

  Contract:
    objc==3:  `db eval SQL` — accumulate a flat list of typed column
              Tcl_Objs and return it as the interp result.
    objc==5 (or objc==4 with empty array name):
              `db eval SQL ARRAY-NAME SCRIPT` — for each row, bind every
              column value into the named Tcl array (column-name -> value)
              via Tcl_ObjSetVar2, then evaluate the script body.
              TCL_BREAK / TCL_CONTINUE / TCL_RETURN / TCL_ERROR from the
              body are handled exactly as upstream DbEvalNextCmd.
    objc==4 with a non-empty 3rd arg:
              `db eval SQL SCRIPT` — pVarName is 0, so each column NAME is
              itself used as the scalar variable (upstream: pVarName==0
              -> Tcl_ObjSetVar2(interp, apColName[i], 0, value)).

  On any SQLITE error we SET the interp result to sqlite3_errmsg() and
  return TCL_ERROR (9.4.divbug.6 — SET, not Append, so a UDF error already
  on the interp result is not duplicated).

  Not ported (vs upstream): NRE machinery, -withoutnulls / -asdict flags,
  the prepared-statement cache, busy-handler SCHEMA retries. }
function DbEvalArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:        PSqliteDb;
  zSql:       PAnsiChar;
  zTail:      PAnsiChar;
  pStmt:      Pointer;
  rc:         i32;
  rcStep:     i32;
  i, nCol:    cint;
  pList:      PTclObj;
  zNullStr:   PAnsiChar;
  emptyNull:  array[0..0] of AnsiChar;
  nVar:       i32;
  iParam:     i32;
  zParamName: PAnsiChar;
  pVarName:   PTclObj;       { array name obj, or nil for the scalar form }
  pScript:    PTclObj;       { per-row script body, or nil for objc==3   }
  pColName:   PTclObj;
  pColVal:    PTclObj;
  rcBody:     cint;
  zArrName:   PAnsiChar;
  bDone:      Boolean;
  sEval:      TDbEvalContext;
  pRet:       PTclObj;
begin
  if (objc < 3) or (objc > 5) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('SQL ?ARRAY-NAME? ?SCRIPT?'));
    Result := TCL_ERROR;
    Exit;
  end;

  pDb  := PSqliteDb(clientData);
  zSql := Tcl_GetStringFromObj(ObjvAt(objv, 2), nil);
  if zSql = nil then
  begin
    Result := TCL_OK;
    Exit;
  end;

  { Decide the row-callback shape — mirrors tclsqlite.c:3320..3349. }
  pVarName := nil;
  pScript  := nil;
  if objc >= 4 then
  begin
    pScript := ObjvAt(objv, objc - 1);
    if objc >= 5 then
    begin
      { objv[3] is the array name; an empty string means "scalar form". }
      zArrName := Tcl_GetStringFromObj(ObjvAt(objv, 3), nil);
      if (zArrName <> nil) and (zArrName^ <> #0) then
        pVarName := ObjvAt(objv, 3);
    end;
    { 9.4.2.x.1.d — script-body form goes through the NRE-shaped
      DbEvalScriptArm (tclsqlite.c:3340..3356).  The DbEvalContext is
      heap-allocated and pins the SqliteDb via AddDatabaseRef, so the
      lifecycle survives nested [vwait] re-entries.  The objc==3 flat
      list form below stays on the existing direct prepare/step loop
      (tclsqlite.c:3320..3338). }
    Result := DbEvalScriptArm(pDb, interp, ObjvAt(objv, 2),
                              pVarName, pScript);
    Exit;
  end;

  { objc==3 flat-list form — faithful port of tclsqlite.c:3320..3338.
    Routes through the cached DbEvalInit/DbEvalStep/DbEvalFinalize
    machinery (DbPrepareAndBind/DbReleaseStmt) so that re-running an
    identical SQL string reuses the cached prepared statement rather than
    re-preparing it.  This is what lets tkt3871-1.3/1.5 observe only the
    run-time xFilter callbacks (no recompile-time xBestIndex) on a repeat
    query, matching C.  The objc>=4 script-body form returned earlier via
    DbEvalScriptArm, so pScript is always nil here. }
  pRet := Tcl_NewObj();
  Tcl_IncrRefCount(pRet);
  DbEvalInit(@sEval, pDb, ObjvAt(objv, 2), nil, 0);
  rc := DbEvalStep(@sEval);
  while rc = TCL_OK do
  begin
    DbEvalRowInfo(@sEval, @nCol, nil);
    for i := 0 to nCol - 1 do
      Tcl_ListObjAppendElement(interp, pRet, DbEvalColumnValueCtx(@sEval, i));
    rc := DbEvalStep(@sEval);
  end;
  DbEvalFinalize(@sEval);
  if rc = TCL_BREAK then
  begin
    Tcl_SetObjResult(interp, pRet);
    rc := TCL_OK;
  end;
  Tcl_DecrRefCount(pRet);
  Result := rc;
end;

{ DbNullValueArm — port of the "nullvalue" arm of DbObjCmd
  (tclsqlite.c:3524..3545).  2-arg form is a getter (returns current
  pDb^.zNull as a string, "" if nil).  3-arg form is a setter: free
  old buffer if any, copy objv[2] verbatim into a freshly GetMem'd
  PAnsiChar.  Tcl owns the objv string so we must copy.

  Memory rule: GetMem here matches FreeMem in DbDeleteCmd above. }
function DbNullValueArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:  PSqliteDb;
  zArg: PAnsiChar;
  nArg: cint;
begin
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('NULLVALUE'));
    Result := TCL_ERROR;
    Exit;
  end;
  pDb := PSqliteDb(clientData);
  if objc = 3 then
  begin
    nArg := 0;
    zArg := Tcl_GetStringFromObj(ObjvAt(objv, 2), @nArg);
    if pDb^.zNull <> nil then
    begin
      FreeMem(pDb^.zNull);
      pDb^.zNull := nil;
    end;
    if (zArg <> nil) and (nArg > 0) then
    begin
      GetMem(pDb^.zNull, nArg + 1);
      Move(zArg^, pDb^.zNull^, nArg);
      pDb^.zNull[nArg] := #0;
    end;
  end;
  Tcl_SetObjResult(interp, Tcl_NewStringObj(pDb^.zNull, -1));
  Result := TCL_OK;
end;

{ SafeToUseEvalObjv — Pas port of safeToUseEvalObjv (tclsqlite.c:528).
  Looks at the script prefix; if it contains no '$', '[' or ';' then the
  faster Tcl_EvalObjv() path is safe.  Otherwise the script must go
  through Tcl_EvalObjEx() with a valid string representation. }
function SafeToUseEvalObjv(pCmd: PTclObj): cint;
var
  z: PAnsiChar;
  n: cint;
begin
  z := Tcl_GetStringFromObj(pCmd, @n);
  while n > 0 do
  begin
    Dec(n);
    if (z^ = '$') or (z^ = '[') or (z^ = ';') then
    begin
      Result := 0;
      Exit;
    end;
    Inc(z);
  end;
  Result := 1;
end;

{ DbSqlFunc — sqlite3 xFunc trampoline.  Pas port of tclSqlFunc
  (tclsqlite.c:1015..1166), collapsed to the minimum the smoke gate
  needs.  Strategy:
    * argc==0 path: Tcl_EvalObjEx on pScript directly (matches
      C:1021..1029; this is the bytecode-cache fast path).
    * argc>0  path: build a fresh PPTclObj buffer of length argc+1,
      where slot 0 is pScript and slots 1..argc are per-arg Tcl_Obj
      built per sqlite3_value_type (mirrors C:1053..1082, condensed
      to int64/double/text branches; blob/null fall through to
      stringify-via-text for the minimum port).  Then Tcl_EvalObjv.
    * On TCL_OK the obj-result is routed to sqlite3_result_text via
      SQLITE_TRANSIENT (sqlite takes a copy).
    * On TCL_ERROR the obj-result string is routed to
      sqlite3_result_error.
    * TCL_BREAK -> sqlite3_result_null (matches C:1100..1101).
  Divergence from upstream: we do NOT do type-detection of the result
  (eType heuristic at tclsqlite.c:1108..1140); everything comes back
  as text and SQLite's normal affinity rules apply.  The smoke gate
  exercises both numeric and text round-trips and Tcl's autocoercion
  on the input side makes that sufficient. }
procedure DbSqlFunc(pCtx: Psqlite3_context; argc: cint;
  argv: PPointer); cdecl;
var
  pFn:    PSqlFunc;
  rc:     cint;
  i:      cint;
  pVal:   Psqlite3_value;
  pArg:   PTclObj;
  pCmd:   PTclObj;
  pRes:   PTclObj;
  zRes:   PAnsiChar;
  nRes:   cint;
  zErr:   PAnsiChar;
  pIn:    PPointer;
  vType:  i32;
  zText:  PAnsiChar;
  nText:  cint;
  objv:   PPTclObj;
  objc:   cint;
  eType:  cint;
  wv:     Int64;
  rv:     Double;
  data:   PAnsiChar;
  n:      cint;
  zType:  PAnsiChar;
begin
  pFn := PSqlFunc(sqlite3_user_data(pCtx));
  if pFn = nil then
  begin
    sqlite3_result_error(pCtx, PAnsiChar('DbSqlFunc: nil user_data'), -1);
    Exit;
  end;

  if argc = 0 then
  begin
    { Fast path — no shallow-list-copy work needed. }
    Tcl_IncrRefCount(pFn^.pScript);
    rc := Tcl_EvalObjEx(pFn^.interp, pFn^.pScript, 0);
    Tcl_DecrRefCount(pFn^.pScript);
  end
  else
  begin
    { argc>0 — make a "shallow" copy of the script list object, lappend
      the args, then evaluate the copy.  Mirrors tclSqlFunc (C:1037..
      1097): the outer list Tcl_Obj is duplicated but the element
      Tcl_Objs are shared, so first-element command-name shimmering is
      preserved across invocations.  This also makes script bodies that
      are NOT a bare command name (e.g. an apply-lambda or a multi-word
      script) work — they used to fail under the old Tcl_EvalObjv path. }
    if Tcl_ListObjGetElements(pFn^.interp, pFn^.pScript, @objc, @objv) <> TCL_OK then
    begin
      sqlite3_result_error(pCtx, Tcl_GetStringResult(pFn^.interp), -1);
      Exit;
    end;
    pCmd := Tcl_NewListObj(objc, objv);
    Tcl_IncrRefCount(pCmd);

    pIn := argv;
    for i := 0 to argc - 1 do
    begin
      pVal := Psqlite3_value(pIn^);
      vType := sqlite3_value_type(pVal);
      case vType of
        SQLITE_BLOB:
          begin
            nText := sqlite3_value_bytes(pVal);
            pArg := Tcl_NewByteArrayObj(sqlite3_value_blob(pVal), nText);
          end;
        SQLITE_INTEGER:
          begin
            { C:1060..1065 — narrow ints get an int-typed Tcl_Obj. }
            if (sqlite3_value_int64(pVal) >= -2147483647) and
               (sqlite3_value_int64(pVal) <= 2147483647) then
              pArg := Tcl_NewIntObj(cint(sqlite3_value_int64(pVal)))
            else
              pArg := Tcl_NewWideIntObj(sqlite3_value_int64(pVal));
          end;
        SQLITE_FLOAT:
          pArg := Tcl_NewDoubleObj(sqlite3_value_double(pVal));
        SQLITE_NULL:
          begin
            if pFn^.pDb^.zNull <> nil then
              pArg := Tcl_NewStringObj(pFn^.pDb^.zNull, -1)
            else
              pArg := Tcl_NewStringObj(PAnsiChar(''), 0);
          end;
        else
          begin
            zText := PAnsiChar(sqlite3_value_text(pVal));
            nText := sqlite3_value_bytes(pVal);
            if zText = nil then
              pArg := Tcl_NewStringObj(PAnsiChar(''), 0)
            else
              pArg := Tcl_NewStringObj(zText, nText);
          end;
      end;
      if Tcl_ListObjAppendElement(pFn^.interp, pCmd, pArg) <> TCL_OK then
      begin
        Tcl_DecrRefCount(pCmd);
        sqlite3_result_error(pCtx, Tcl_GetStringResult(pFn^.interp), -1);
        Exit;
      end;
      pIn := PPointer(PtrUInt(pIn) + SizeOf(Pointer));
    end;

    if pFn^.useEvalObjv = 0 then
      { Tcl_EvalObjEx() would auto-route a string-rep-less list through
        Tcl_EvalObjv(); force a valid string rep so it doesn't.  C:1090. }
      Tcl_GetString(pCmd);
    rc := Tcl_EvalObjEx(pFn^.interp, pCmd, TCL_EVAL_DIRECT);
    Tcl_DecrRefCount(pCmd);
  end;

  { Result routing — see C:1100..1147 minus the type-detection arm. }
  if rc = TCL_BREAK then
  begin
    sqlite3_result_null(pCtx);
  end
  else if (rc <> TCL_OK) and (rc <> TCL_RETURN) then
  begin
    zErr := Tcl_GetStringResult(pFn^.interp);
    if zErr = nil then zErr := PAnsiChar('Tcl error');
    sqlite3_result_error(pCtx, zErr, -1);
  end
  else
  begin
    { Result type routing — C:1107..1158.  eType is the declared
      -returntype; SQLITE_NULL means "auto-detect".  We can't read
      Tcl_Obj.typePtr->name from Pascal (Tcl_Obj is opaque here), so
      the auto-detect arm probes the obj with the Tcl_Get*FromObj
      accessors instead of inspecting the type name — same net result
      for the integer/double/text/blob distinction. }
    pRes  := Tcl_GetObjResult(pFn^.interp);
    eType := pFn^.eType;

    if eType = SQLITE_NULL then
    begin
      { Type-name auto-detection — mirrors tclsqlite.c:1108..1127.
        Probing with Tcl_Get*FromObj instead would mis-classify strings
        like '0x119' (returned by `format 0x%X`) as INTEGER because Tcl
        parses 0x-prefixed numeric literals; the C oracle keys off the
        *current* internalRep type name so a plain string stays TEXT.
        Bug 9.4.divbug.29 / collate1-1.x. }
      zType := TclObjTypeName(pRes);
      if zType = nil then zType := PAnsiChar('');
      if (zType[0] = 'b') and (StrComp(zType, 'bytearray') = 0)
           and TclObjHasNoStringRep(pRes) then
        eType := SQLITE_BLOB
      else if ((zType[0] = 'b') and TclObjHasNoStringRep(pRes)
                and (StrComp(zType, 'boolean') = 0))
           or ((zType[0] = 'b') and TclObjHasNoStringRep(pRes)
                and (StrComp(zType, 'booleanString') = 0))
           or ((zType[0] = 'w') and (StrComp(zType, 'wideInt') = 0))
           or ((zType[0] = 'i') and (StrComp(zType, 'int') = 0)) then
        eType := SQLITE_INTEGER
      else if (zType[0] = 'd') and (StrComp(zType, 'double') = 0) then
        eType := SQLITE_FLOAT
      else
        eType := SQLITE_TEXT;
    end;

    case eType of
      SQLITE_BLOB:
        begin
          n := 0;
          data := Tcl_GetByteArrayFromObj(pRes, @n);
          sqlite3_result_blob(pCtx, data, n, SQLITE_TRANSIENT);
        end;
      SQLITE_INTEGER:
        begin
          if Tcl_GetWideIntFromObj(nil, pRes, @wv) = TCL_OK then
            sqlite3_result_int64(pCtx, wv)
          else if Tcl_GetDoubleFromObj(nil, pRes, @rv) = TCL_OK then
            sqlite3_result_double(pCtx, rv)
          else
          begin
            n := 0;
            zRes := Tcl_GetStringFromObj(pRes, @n);
            if zRes = nil then sqlite3_result_null(pCtx)
            else sqlite3_result_text(pCtx, zRes, n, SQLITE_TRANSIENT);
          end;
        end;
      SQLITE_FLOAT:
        begin
          if Tcl_GetDoubleFromObj(nil, pRes, @rv) = TCL_OK then
            sqlite3_result_double(pCtx, rv)
          else
          begin
            n := 0;
            zRes := Tcl_GetStringFromObj(pRes, @n);
            if zRes = nil then sqlite3_result_null(pCtx)
            else sqlite3_result_text(pCtx, zRes, n, SQLITE_TRANSIENT);
          end;
        end;
      else
        begin
          nRes := 0;
          zRes := Tcl_GetStringFromObj(pRes, @nRes);
          if zRes = nil then
            sqlite3_result_null(pCtx)
          else
            sqlite3_result_text(pCtx, zRes, nRes, SQLITE_TRANSIENT);
        end;
    end;
  end;
end;

{ DbSqlFuncDelete — sqlite3_create_function_v2 xDestroy hook.  Fired
  on db close, on _create_function_v2 re-registration with the same
  name, and on explicit sqlite3_close_v2.  Mirrors the per-entry
  teardown in C's pDb->pFunc walker at tclsqlite.c:617..630. }
procedure DbSqlFuncDelete(pUser: Pointer); cdecl;
var
  pFn: PSqlFunc;
begin
  pFn := PSqlFunc(pUser);
  if pFn = nil then Exit;
  if pFn^.pScript <> nil then
  begin
    Tcl_DecrRefCount(pFn^.pScript);
    pFn^.pScript := nil;
  end;
  Dispose(pFn);
end;

{ DbFunctionArm — port of the `function` arm of DbObjCmd
  (tclsqlite.c:3386..3469).  Minimum surface: parse `NAME ?-argcount N?
  ?-deterministic? SCRIPT`.  Other flags (-directonly / -innocuous /
  -returntype) are unimplemented and rejected with "bad option".

  Reuse policy: unlike upstream's findSqlFunc (tclsqlite.c:548) which
  reuses an existing TSqlFunc on re-register, we always allocate a
  fresh one.  sqlite3_create_function_v2 will fire xDestroy on the
  *previously* registered TSqlFunc for the same name+nArg, which
  decrefs its pScript and Disposes it — net effect identical for
  the smoke gate. }
function DbFunctionArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:     PSqliteDb;
  pFn:     PSqlFunc;
  zName:   PAnsiChar;
  z:       PAnsiChar;
  nA:      cint;
  nArg:    cint;
  flags:   cint;
  i:       cint;
  nZ:      cint;
  eType:   cint;
  idx:     cint;
  rc:      i32;
  pScript: PTclObj;
const
  { tclsqlite.c:3417 — order fixes the SQLITE_* codes: index 0 ->
    integer(1), 1 -> real(2), 2 -> text(3), 3 -> blob(4), 4 -> any. }
  azType: array[0..5] of PAnsiChar =
    ('integer', 'real', 'text', 'blob', 'any', nil);
begin
  if objc < 4 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('NAME ?SWITCHES? SCRIPT'));
    Result := TCL_ERROR;
    Exit;
  end;
  pDb   := PSqliteDb(clientData);
  nArg  := -1;
  flags := SQLITE_UTF8;
  eType := SQLITE_NULL;

  { Flag loop runs over objv[3 .. objc-2]; objv[objc-1] is the script.
    Mirrors C's prefix-match (strncmp(z, "-opt", n) with n = strlen(z),
    n>1) so abbreviations like -det / -arg work. }
  i := 3;
  while i < (objc - 1) do
  begin
    z := Tcl_GetStringFromObj(ObjvAt(objv, i), @nZ);
    if z = nil then z := PAnsiChar('');
    if (nZ > 1) and (StrLComp(z, PAnsiChar('-argcount'), nZ) = 0) then
    begin
      if i = (objc - 2) then
      begin
        Tcl_AppendResult(interp,
          PChar('option requires an argument: '), z, Pointer(nil));
        Result := TCL_ERROR;
        Exit;
      end;
      nA := 0;
      if Tcl_GetIntFromObj(interp, ObjvAt(objv, i + 1), @nA) <> TCL_OK then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
      if nA < 0 then
      begin
        Tcl_AppendResult(interp,
          PChar('number of arguments must be non-negative'),
          Pointer(nil));
        Result := TCL_ERROR;
        Exit;
      end;
      nArg := nA;
      Inc(i, 2);
    end
    else if (nZ > 1) and (StrLComp(z, PAnsiChar('-deterministic'), nZ) = 0) then
    begin
      flags := flags or SQLITE_DETERMINISTIC;
      Inc(i);
    end
    else if (nZ > 1) and (StrLComp(z, PAnsiChar('-directonly'), nZ) = 0) then
    begin
      flags := flags or SQLITE_DIRECTONLY;
      Inc(i);
    end
    else if (nZ > 1) and (StrLComp(z, PAnsiChar('-innocuous'), nZ) = 0) then
    begin
      flags := flags or SQLITE_INNOCUOUS;
      Inc(i);
    end
    else if (nZ > 1) and (StrLComp(z, PAnsiChar('-returntype'), nZ) = 0) then
    begin
      if i = (objc - 2) then
      begin
        Tcl_AppendResult(interp,
          PChar('option requires an argument: '), z, Pointer(nil));
        Result := TCL_ERROR;
        Exit;
      end;
      Inc(i);
      idx := 0;
      if Tcl_GetIndexFromObj(interp, ObjvAt(objv, i), @azType[0],
                             PChar('type'), 0, @idx) <> TCL_OK then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
      { C:3437 eType++ : index 0(integer)->1 ... 4(any)->5(=SQLITE_NULL). }
      eType := idx + 1;
      Inc(i);
    end
    else
    begin
      Tcl_AppendResult(interp,
        PChar('bad option "'), z,
        PChar('": must be -argcount, -deterministic, -directonly,'
            + ' -innocuous, or -returntype'),
        Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
  end;

  zName   := Tcl_GetStringFromObj(ObjvAt(objv, 2), nil);
  pScript := ObjvAt(objv, objc - 1);

  { Allocate fresh TSqlFunc, chain it onto pDb^.pFunc.  Note: New()
    is safe — TSqlFunc has no managed fields (see
    feedback_new_record_ansistring). }
  New(pFn);
  pFn^.pDb     := pDb;
  pFn^.interp  := interp;
  pFn^.pScript := pScript;
  pFn^.eType   := eType;
  pFn^.useEvalObjv := SafeToUseEvalObjv(pScript);
  Tcl_IncrRefCount(pScript);
  pFn^.pNext   := pDb^.pFunc;
  pDb^.pFunc   := pFn;

  rc := sqlite3_create_function_v2(pDb^.db, zName, nArg, flags,
                                   Pointer(pFn), @DbSqlFunc, nil, nil,
                                   @DbSqlFuncDelete);
  if rc <> SQLITE_OK then
  begin
    { create_function_v2 invokes xDestroy itself on failure, per
      sqlite3.h:5572 — so pFn is already gone.  Unlink the head we
      just set; the previous head is still valid. }
    pDb^.pFunc := pFn^.pNext;
    Tcl_AppendResult(interp,
      PAnsiChar(sqlite3_errmsg(pDb^.db)), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
end;

{ ----------------------------------------------------------------------
  Tcl-callback collations — tclsqlite.c:163..168, 981..1008, 2749..2796.

  `db collate NAME script` registers a TSqlCollate via
  sqlite3_create_collation; the trampoline tclSqlCollate evals
  `script $lhs $rhs` and returns atoi() of the Tcl result.

  `db collation_needed script` registers tclCollateNeeded via
  sqlite3_collation_needed; that callback evals `script $collName`. }

{ DbSqlCollate — port of tclSqlCollate (tclsqlite.c:992..1008).  The
  per-collation comparison trampoline. }
function DbSqlCollate(pCtx: Pointer; nA: i32; zA: Pointer;
  nB: i32; zB: Pointer): i32; cdecl;
var
  p:    PSqlCollate;
  pCmd: PTclObj;
begin
  p := PSqlCollate(pCtx);
  pCmd := Tcl_NewStringObj(p^.zScript, -1);
  Tcl_IncrRefCount(pCmd);
  Tcl_ListObjAppendElement(p^.interp, pCmd, Tcl_NewStringObj(PChar(zA), nA));
  Tcl_ListObjAppendElement(p^.interp, pCmd, Tcl_NewStringObj(PChar(zB), nB));
  Tcl_EvalObjEx(p^.interp, pCmd, TCL_EVAL_DIRECT);
  Tcl_DecrRefCount(pCmd);
  Result := StrToIntDef(string(Tcl_GetStringResult(p^.interp)), 0);
end;

{ DbCollateNeeded — port of tclCollateNeeded (tclsqlite.c:976..988).
  The collation-needed factory callback. }
procedure DbCollateNeeded(pCtx: Pointer; db: PTsqlite3; enc: i32;
  zName: PAnsiChar); cdecl;
var
  pDb:     PSqliteDb;
  pScript: PTclObj;
begin
  pDb := PSqliteDb(pCtx);
  pScript := Tcl_DuplicateObj(pDb^.pCollateNeeded);
  Tcl_IncrRefCount(pScript);
  Tcl_ListObjAppendElement(nil, pScript, Tcl_NewStringObj(zName, -1));
  Tcl_EvalObjEx(pDb^.interp, pScript, 0);
  Tcl_DecrRefCount(pScript);
end;

{ DbCollateArm — port of the `collate` arm of DbObjCmd
  (tclsqlite.c:2754..2776).  `db collate NAME SCRIPT`. }
function DbCollateArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:      PSqliteDb;
  pCollate: PSqlCollate;
  zName:    PAnsiChar;
  zScript:  PAnsiChar;
  nScript:  cint;
begin
  pDb := PSqliteDb(clientData);
  if objc <> 4 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('NAME SCRIPT'));
    Result := TCL_ERROR;
    Exit;
  end;
  zName   := Tcl_GetStringFromObj(ObjvAt(objv, 2), nil);
  zScript := Tcl_GetStringFromObj(ObjvAt(objv, 3), @nScript);

  { Allocate fresh TSqlCollate + a separate Tcl_Alloc'd zScript copy.
    Upstream tacks zScript onto the same block via `&pCollate[1]`; we
    split it because TSqlCollate is New/Dispose-managed. }
  New(pCollate);
  pCollate^.interp  := interp;
  pCollate^.pNext   := pDb^.pCollate;
  pCollate^.zScript := Tcl_Alloc(nScript + 1);
  Move(zScript^, pCollate^.zScript^, nScript + 1);
  pDb^.pCollate := pCollate;

  if sqlite3_create_collation(pDb^.db, zName, SQLITE_UTF8,
       Pointer(pCollate), @DbSqlCollate) <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp,
      PAnsiChar(sqlite3_errmsg(pDb^.db)), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
end;

{ DbCollationNeededArm — port of the `collation_needed` arm of DbObjCmd
  (tclsqlite.c:2786..2797).  `db collation_needed SCRIPT`. }
function DbCollationNeededArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb: PSqliteDb;
begin
  pDb := PSqliteDb(clientData);
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('SCRIPT'));
    Result := TCL_ERROR;
    Exit;
  end;
  if pDb^.pCollateNeeded <> nil then
    Tcl_DecrRefCount(pDb^.pCollateNeeded);
  pDb^.pCollateNeeded := Tcl_DuplicateObj(ObjvAt(objv, 2));
  Tcl_IncrRefCount(pDb^.pCollateNeeded);
  pDb^.interp := interp;
  sqlite3_collation_needed(pDb^.db, Pointer(pDb), @DbCollateNeeded);
  Result := TCL_OK;
end;

{ ----------------------------------------------------------------------
  Trace / profile callback trampolines — tclsqlite.c:715..826.

  Each fires on prepared-statement events and evaluates the stored Tcl
  script with the per-event arguments appended as list elements. }

{ DbTraceHandler — legacy sqlite3_trace callback.  tclsqlite.c:710..727.
  Signature: void (*)(void *cd, const char *zSql). }
procedure DbTraceHandler(cd: Pointer; zSql: PAnsiChar); cdecl;
var
  pDb: PSqliteDb;
  str: TTclDString;
begin
  pDb := PSqliteDb(cd);
  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pDb^.zTrace, -1);
  Tcl_DStringAppendElement(@str, zSql);
  Tcl_Eval(pDb^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);
  Tcl_ResetResult(pDb^.interp);
end;

{ DbTraceV2Handler — sqlite3_trace_v2 callback.  tclsqlite.c:737..803.
  Signature: int (*)(unsigned type, void *cd, void *pd, void *xd). }
function DbTraceV2Handler(traceType: cuint;
  cd, pd, xd: Pointer): cint; cdecl;
var
  pDb:  PSqliteDb;
  pCmd: PTclObj;
  zSql: PAnsiChar;
  ns:   Int64;
begin
  pDb := PSqliteDb(cd);
  case traceType of
    SQLITE_TRACE_STMT:
      begin
        zSql := PAnsiChar(xd);
        pCmd := Tcl_NewStringObj(pDb^.zTraceV2, -1);
        Tcl_IncrRefCount(pCmd);
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(Int64(PtrUInt(pd))));
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewStringObj(zSql, -1));
        Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
        Tcl_DecrRefCount(pCmd);
        Tcl_ResetResult(pDb^.interp);
      end;
    SQLITE_TRACE_PROFILE:
      begin
        ns   := PInt64(xd)^;
        pCmd := Tcl_NewStringObj(pDb^.zTraceV2, -1);
        Tcl_IncrRefCount(pCmd);
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(Int64(PtrUInt(pd))));
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(ns));
        Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
        Tcl_DecrRefCount(pCmd);
        Tcl_ResetResult(pDb^.interp);
      end;
    SQLITE_TRACE_ROW:
      begin
        pCmd := Tcl_NewStringObj(pDb^.zTraceV2, -1);
        Tcl_IncrRefCount(pCmd);
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(Int64(PtrUInt(pd))));
        Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
        Tcl_DecrRefCount(pCmd);
        Tcl_ResetResult(pDb^.interp);
      end;
    SQLITE_TRACE_CLOSE:
      begin
        pCmd := Tcl_NewStringObj(pDb^.zTraceV2, -1);
        Tcl_IncrRefCount(pCmd);
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(Int64(PtrUInt(pd))));
        Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
        Tcl_DecrRefCount(pCmd);
        Tcl_ResetResult(pDb^.interp);
      end;
  end;
  Result := SQLITE_OK;
end;

{ DbProfileHandler — legacy sqlite3_profile callback.  tclsqlite.c:812..825.
  Signature: void (*)(void *cd, const char *zSql, sqlite_uint64 tm). }
procedure DbProfileHandler(cd: Pointer; zSql: PAnsiChar; tm: UInt64); cdecl;
var
  pDb: PSqliteDb;
  str: TTclDString;
  zTm: array[0..63] of AnsiChar;
begin
  pDb := PSqliteDb(cd);
  StrPCopy(zTm, IntToStr(tm));
  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pDb^.zProfile, -1);
  Tcl_DStringAppendElement(@str, zSql);
  Tcl_DStringAppendElement(@str, zTm);
  Tcl_Eval(pDb^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);
  Tcl_ResetResult(pDb^.interp);
end;

{ DbTraceArm — `db trace ?CALLBACK?`  tclsqlite.c:3831..3863. }
function DbTraceArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:    PSqliteDb;
  zTrace: PAnsiChar;
  len:    cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zTrace <> nil then
      Tcl_AppendResult(interp, pDb^.zTrace, Pointer(nil));
  end
  else
  begin
    if pDb^.zTrace <> nil then
      Tcl_Free(pDb^.zTrace);
    zTrace := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zTrace <> nil) and (len > 0) then
    begin
      pDb^.zTrace := Tcl_Alloc(len + 1);
      Move(zTrace^, pDb^.zTrace^, len + 1);
    end
    else
      pDb^.zTrace := nil;
    if pDb^.zTrace <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_trace(pDb^.db, @DbTraceHandler, pDb);
    end
    else
      sqlite3_trace(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbTraceV2Arm — `db trace_v2 ?CALLBACK? ?MASK?`  tclsqlite.c:3871..3945. }
function DbTraceV2Arm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  TTYPE_strs: array[0..4] of PChar =
    ('statement', 'profile', 'row', 'close', nil);
var
  pDb:      PSqliteDb;
  zTraceV2: PAnsiChar;
  len:      cint;
  wMask:    Int64;
  i:        cint;
  pObj:     PTclObj;
  ttype:    cint;
  wType:    Int64;
  pError:   PTclObj;
begin
  pDb := PSqliteDb(clientData);
  if objc > 4 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK? ?MASK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zTraceV2 <> nil then
      Tcl_AppendResult(interp, pDb^.zTraceV2, Pointer(nil));
  end
  else
  begin
    wMask := 0;
    if objc = 4 then
    begin
      if Tcl_ListObjLength(interp, ObjvAt(objv, 3), @len) <> TCL_OK then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
      for i := 0 to len - 1 do
      begin
        if Tcl_ListObjIndex(interp, ObjvAt(objv, 3), i, @pObj) <> TCL_OK then
        begin
          Result := TCL_ERROR;
          Exit;
        end;
        if Tcl_GetIndexFromObj(interp, pObj, @TTYPE_strs[0],
             PChar('trace type'), 0, @ttype) <> TCL_OK then
        begin
          pError := Tcl_DuplicateObj(Tcl_GetObjResult(interp));
          Tcl_IncrRefCount(pError);
          if Tcl_GetWideIntFromObj(interp, pObj, @wType) = TCL_OK then
          begin
            Tcl_DecrRefCount(pError);
            wMask := wMask or wType;
          end
          else
          begin
            Tcl_SetObjResult(interp, pError);
            Tcl_DecrRefCount(pError);
            Result := TCL_ERROR;
            Exit;
          end;
        end
        else
        begin
          case ttype of
            0: wMask := wMask or SQLITE_TRACE_STMT;
            1: wMask := wMask or SQLITE_TRACE_PROFILE;
            2: wMask := wMask or SQLITE_TRACE_ROW;
            3: wMask := wMask or SQLITE_TRACE_CLOSE;
          end;
        end;
      end;
    end
    else
      wMask := SQLITE_TRACE_STMT;  { the "legacy" default }
    if pDb^.zTraceV2 <> nil then
      Tcl_Free(pDb^.zTraceV2);
    zTraceV2 := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zTraceV2 <> nil) and (len > 0) then
    begin
      pDb^.zTraceV2 := Tcl_Alloc(len + 1);
      Move(zTraceV2^, pDb^.zTraceV2^, len + 1);
    end
    else
      pDb^.zTraceV2 := nil;
    if pDb^.zTraceV2 <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_trace_v2(pDb^.db, cuint(wMask), @DbTraceV2Handler, pDb);
    end
    else
      sqlite3_trace_v2(pDb^.db, 0, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbProfileArm — `db profile ?CALLBACK?`  tclsqlite.c:3620..3651. }
function DbProfileArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:      PSqliteDb;
  zProfile: PAnsiChar;
  len:      cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zProfile <> nil then
      Tcl_AppendResult(interp, pDb^.zProfile, Pointer(nil));
  end
  else
  begin
    if pDb^.zProfile <> nil then
      Tcl_Free(pDb^.zProfile);
    zProfile := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zProfile <> nil) and (len > 0) then
    begin
      pDb^.zProfile := Tcl_Alloc(len + 1);
      Move(zProfile^, pDb^.zProfile^, len + 1);
    end
    else
      pDb^.zProfile := nil;
    if pDb^.zProfile <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_profile(pDb^.db, @DbProfileHandler, pDb);
    end
    else
      sqlite3_profile(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbAuthHandler — the sqlite3_set_authorizer callback trampoline.
  Port of auth_callback (tclsqlite.c:1170..1248).  Maps the integer
  action code to its symbolic string, appends the symbolic code plus
  the four string args as Tcl list elements to the stored callback
  script, GlobalEval's it, then maps the result string back to an
  integer rc.  Signature:
    int (*)(void*, int, const char*, const char*,
            const char*, const char*). }
function DbAuthHandler(pArg: Pointer; code: cint;
  zArg1, zArg2, zArg3, zArg4: PAnsiChar): cint; cdecl;
var
  pDb:    PSqliteDb;
  zCode:  PAnsiChar;
  str:    TTclDString;
  rc:     cint;
  zReply: PAnsiChar;
begin
  pDb := PSqliteDb(pArg);

  { EVIDENCE-OF: R-56518-44310 — the second parameter to the callback
    is an integer action code that specifies the action to authorize. }
  case code of
    0                          : zCode := 'SQLITE_COPY';
    SQLITE_CREATE_INDEX        : zCode := 'SQLITE_CREATE_INDEX';
    SQLITE_CREATE_TABLE        : zCode := 'SQLITE_CREATE_TABLE';
    SQLITE_CREATE_TEMP_INDEX   : zCode := 'SQLITE_CREATE_TEMP_INDEX';
    SQLITE_CREATE_TEMP_TABLE   : zCode := 'SQLITE_CREATE_TEMP_TABLE';
    SQLITE_CREATE_TEMP_TRIGGER : zCode := 'SQLITE_CREATE_TEMP_TRIGGER';
    SQLITE_CREATE_TEMP_VIEW    : zCode := 'SQLITE_CREATE_TEMP_VIEW';
    SQLITE_CREATE_TRIGGER      : zCode := 'SQLITE_CREATE_TRIGGER';
    SQLITE_CREATE_VIEW         : zCode := 'SQLITE_CREATE_VIEW';
    SQLITE_DELETE_AUTH         : zCode := 'SQLITE_DELETE';
    SQLITE_DROP_INDEX          : zCode := 'SQLITE_DROP_INDEX';
    SQLITE_DROP_TABLE          : zCode := 'SQLITE_DROP_TABLE';
    SQLITE_DROP_TEMP_INDEX     : zCode := 'SQLITE_DROP_TEMP_INDEX';
    SQLITE_DROP_TEMP_TABLE     : zCode := 'SQLITE_DROP_TEMP_TABLE';
    SQLITE_DROP_TEMP_TRIGGER   : zCode := 'SQLITE_DROP_TEMP_TRIGGER';
    SQLITE_DROP_TEMP_VIEW      : zCode := 'SQLITE_DROP_TEMP_VIEW';
    SQLITE_DROP_TRIGGER        : zCode := 'SQLITE_DROP_TRIGGER';
    SQLITE_DROP_VIEW           : zCode := 'SQLITE_DROP_VIEW';
    SQLITE_INSERT_AUTH         : zCode := 'SQLITE_INSERT';
    SQLITE_PRAGMA_AUTH         : zCode := 'SQLITE_PRAGMA';
    SQLITE_READ_AUTH           : zCode := 'SQLITE_READ';
    SQLITE_SELECT_AUTH         : zCode := 'SQLITE_SELECT';
    SQLITE_TRANSACTION_AUTH    : zCode := 'SQLITE_TRANSACTION';
    SQLITE_UPDATE_AUTH         : zCode := 'SQLITE_UPDATE';
    SQLITE_ATTACH_AUTH         : zCode := 'SQLITE_ATTACH';
    SQLITE_DETACH_AUTH         : zCode := 'SQLITE_DETACH';
    SQLITE_ALTER_TABLE_AUTH    : zCode := 'SQLITE_ALTER_TABLE';
    SQLITE_REINDEX_AUTH        : zCode := 'SQLITE_REINDEX';
    SQLITE_ANALYZE_AUTH        : zCode := 'SQLITE_ANALYZE';
    SQLITE_CREATE_VTABLE       : zCode := 'SQLITE_CREATE_VTABLE';
    SQLITE_DROP_VTABLE         : zCode := 'SQLITE_DROP_VTABLE';
    SQLITE_FUNCTION_AUTH       : zCode := 'SQLITE_FUNCTION';
    SQLITE_SAVEPOINT_AUTH      : zCode := 'SQLITE_SAVEPOINT';
    SQLITE_RECURSIVE_AUTH      : zCode := 'SQLITE_RECURSIVE';
  else
    zCode := '????';
  end;

  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pDb^.zAuth, -1);
  Tcl_DStringAppendElement(@str, zCode);
  if zArg1 <> nil then Tcl_DStringAppendElement(@str, zArg1)
                  else Tcl_DStringAppendElement(@str, '');
  if zArg2 <> nil then Tcl_DStringAppendElement(@str, zArg2)
                  else Tcl_DStringAppendElement(@str, '');
  if zArg3 <> nil then Tcl_DStringAppendElement(@str, zArg3)
                  else Tcl_DStringAppendElement(@str, '');
  if zArg4 <> nil then Tcl_DStringAppendElement(@str, zArg4)
                  else Tcl_DStringAppendElement(@str, '');
  rc := Tcl_GlobalEval(pDb^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);

  if rc = TCL_OK then
    zReply := Tcl_GetStringResult(pDb^.interp)
  else
    zReply := 'SQLITE_DENY';

  if StrComp(zReply, 'SQLITE_OK') = 0 then
    rc := SQLITE_OK
  else if StrComp(zReply, 'SQLITE_DENY') = 0 then
    rc := SQLITE_DENY
  else if StrComp(zReply, 'SQLITE_IGNORE') = 0 then
    rc := SQLITE_IGNORE
  else
    rc := 999;
  Result := rc;
end;

{ DbAuthorizerArm — `db authorizer ?CALLBACK?`  tclsqlite.c:2503..2541.
  2-arg form reports the current callback; 3-arg form replaces it and
  (re)registers via sqlite3_set_authorizer (or clears it). }
function DbAuthorizerArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:   PSqliteDb;
  zAuth: PAnsiChar;
  len:   cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zAuth <> nil then
      Tcl_AppendResult(interp, pDb^.zAuth, Pointer(nil));
  end
  else
  begin
    if pDb^.zAuth <> nil then
      Tcl_Free(pDb^.zAuth);
    zAuth := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zAuth <> nil) and (len > 0) then
    begin
      pDb^.zAuth := Tcl_Alloc(len + 1);
      Move(zAuth^, pDb^.zAuth^, len + 1);
    end
    else
      pDb^.zAuth := nil;
    if pDb^.zAuth <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_set_authorizer(pDb^.db, @DbAuthHandler, pDb);
    end
    else
      sqlite3_set_authorizer(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbBusyHandler — the sqlite3_busy_handler callback trampoline.
  Port of DbBusyHandler (tclsqlite.c:681..692).  Builds "<zBusy> <n>"
  and evals it; a TCL error or a zero/non-integer result means
  "give up" (return 0), a non-zero integer result means "retry"
  (return 1).  Signature: int (*)(void*, int). }
function DbBusyHandler(cd: Pointer; nTries: cint): cint; cdecl;
var
  pDb:  PSqliteDb;
  str:  TTclDString;
  zVal: AnsiString;
  rc:   cint;
begin
  pDb  := PSqliteDb(cd);
  zVal := IntToStr(nTries);   { "%d" of nTries — tclsqlite.c:686 }
  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pDb^.zBusy, -1);
  Tcl_DStringAppend(@str, PChar(' '), 1);
  Tcl_DStringAppend(@str, PChar(zVal), -1);
  rc := Tcl_Eval(pDb^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);
  if (rc <> TCL_OK) or
     (StrToIntDef(string(Tcl_GetStringResult(pDb^.interp)), 0) <> 0) then
    Result := 0
  else
    Result := 1;
end;

{ DbBusyArm — `db busy ?CALLBACK?`  tclsqlite.c:2641..2670.
  2-arg form reports the current callback; 3-arg form replaces it and
  (re)registers via sqlite3_busy_handler (or clears it). }
function DbBusyArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:   PSqliteDb;
  zBusy: PAnsiChar;
  len:   cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('CALLBACK'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zBusy <> nil then
      Tcl_AppendResult(interp, pDb^.zBusy, Pointer(nil));
  end
  else
  begin
    if pDb^.zBusy <> nil then
      Tcl_Free(pDb^.zBusy);
    zBusy := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zBusy <> nil) and (len > 0) then
    begin
      pDb^.zBusy := Tcl_Alloc(len + 1);
      Move(zBusy^, pDb^.zBusy^, len + 1);
    end
    else
      pDb^.zBusy := nil;
    if pDb^.zBusy <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_busy_handler(pDb^.db, @DbBusyHandler, pDb);
    end
    else
      sqlite3_busy_handler(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbProgressHandler — the sqlite3_progress_handler callback trampoline.
  Port of DbProgressHandler (tclsqlite.c:698..708).  Evals the stored
  script; a TCL error or a non-zero/non-integer result interrupts the
  query (return 1), otherwise continue (return 0).
  Signature: int (*)(void*). }
function DbProgressHandler(cd: Pointer): cint; cdecl;
var
  pDb: PSqliteDb;
  rc:  cint;
begin
  pDb := PSqliteDb(cd);
  rc  := Tcl_Eval(pDb^.interp, pDb^.zProgress);
  if (rc <> TCL_OK) or
     (StrToIntDef(string(Tcl_GetStringResult(pDb^.interp)), 0) <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ DbProgressArm — `db progress ?N CALLBACK?`  tclsqlite.c:3574..3606.
  2-arg form reports the current callback and clears it; 4-arg form
  (re)registers a callback fired every N opcodes via
  sqlite3_progress_handler. }
function DbProgressArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:       PSqliteDb;
  zProgress: PAnsiChar;
  len:       cint;
  N:         cint;
begin
  pDb := PSqliteDb(clientData);
  if objc = 2 then
  begin
    if pDb^.zProgress <> nil then
      Tcl_AppendResult(interp, pDb^.zProgress, Pointer(nil));
    sqlite3_progress_handler(pDb^.db, 0, nil, nil);
  end
  else if objc = 4 then
  begin
    if Tcl_GetIntFromObj(interp, ObjvAt(objv, 2), @N) <> TCL_OK then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
    if pDb^.zProgress <> nil then
      Tcl_Free(pDb^.zProgress);
    zProgress := Tcl_GetStringFromObj(ObjvAt(objv, 3), @len);
    if (zProgress <> nil) and (len > 0) then
    begin
      pDb^.zProgress := Tcl_Alloc(len + 1);
      Move(zProgress^, pDb^.zProgress^, len + 1);
    end
    else
      pDb^.zProgress := nil;
    if pDb^.zProgress <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_progress_handler(pDb^.db, N, @DbProgressHandler, pDb);
    end
    else
      sqlite3_progress_handler(pDb^.db, 0, nil, nil);
  end
  else
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('N CALLBACK'));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
end;

{ ---- 9.4.2.l: change-notification hooks ---------------------------- }

{ DbCommitHandler — sqlite3_commit_hook trampoline.  tclsqlite.c:834..843.
  Evals pDb^.zCommit; a TCL error or a non-zero integer result aborts
  (rolls back) the transaction by returning 1.
  Signature: int (*)(void*). }
function DbCommitHandler(cd: Pointer): cint; cdecl;
var
  pDb: PSqliteDb;
  rc:  cint;
begin
  pDb := PSqliteDb(cd);
  rc  := Tcl_Eval(pDb^.interp, pDb^.zCommit);
  if (rc <> TCL_OK) or
     (StrToIntDef(string(Tcl_GetStringResult(pDb^.interp)), 0) <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ DbRollbackHandler — sqlite3_rollback_hook trampoline.  tclsqlite.c:845..852.
  Evals pDb^.pRollbackHook; result ignored, errors reported as background.
  Signature: void (*)(void*). }
procedure DbRollbackHandler(clientData: Pointer); cdecl;
var
  pDb: PSqliteDb;
begin
  pDb := PSqliteDb(clientData);
  if Tcl_EvalObjEx(pDb^.interp, pDb^.pRollbackHook, 0) <> TCL_OK then
    Tcl_BackgroundError(pDb^.interp);
end;

{ DbWalHandler — sqlite3_wal_hook trampoline.  tclsqlite.c:856..882.
  Appends (zDb, nEntry) to a duplicate of pDb^.pWalHook, evals it, and
  returns the integer result to sqlite3.
  Signature: int (*)(void*, sqlite3*, const char*, int). }
function DbWalHandler(clientData: Pointer; db: PTsqlite3;
  zDb: PAnsiChar; nEntry: cint): cint; cdecl;
var
  pDb:    PSqliteDb;
  interp: PTclInterp;
  p:      PTclObj;
  ret:    cint;
begin
  pDb    := PSqliteDb(clientData);
  interp := pDb^.interp;
  ret    := SQLITE_OK;
  p := Tcl_DuplicateObj(pDb^.pWalHook);
  Tcl_IncrRefCount(p);
  Tcl_ListObjAppendElement(interp, p, Tcl_NewStringObj(zDb, -1));
  Tcl_ListObjAppendElement(interp, p, Tcl_NewIntObj(nEntry));
  if (Tcl_EvalObjEx(interp, p, 0) <> TCL_OK) or
     (Tcl_GetIntFromObj(interp, Tcl_GetObjResult(interp), @ret) <> TCL_OK) then
    Tcl_BackgroundError(interp);
  Tcl_DecrRefCount(p);
  Result := ret;
end;

{ DbUpdateHandler — sqlite3_update_hook trampoline.  tclsqlite.c:946..971.
  Appends (op-as-string, zDb, zTbl, rowid) to a duplicate of
  pDb^.pUpdateHook and evals it.
  Signature: void (*)(void*, int, const char*, const char*, sqlite3_int64). }
procedure DbUpdateHandler(p: Pointer; op: cint;
  zDb, zTbl: PAnsiChar; rowid: Int64); cdecl;
const
  azStr: array[0..2] of PAnsiChar = ('DELETE', 'INSERT', 'UPDATE');
var
  pDb:  PSqliteDb;
  pCmd: PTclObj;
begin
  pDb  := PSqliteDb(p);
  pCmd := Tcl_DuplicateObj(pDb^.pUpdateHook);
  Tcl_IncrRefCount(pCmd);
  Tcl_ListObjAppendElement(nil, pCmd, Tcl_NewStringObj(azStr[(op - 1) div 9], -1));
  Tcl_ListObjAppendElement(nil, pCmd, Tcl_NewStringObj(zDb, -1));
  Tcl_ListObjAppendElement(nil, pCmd, Tcl_NewStringObj(zTbl, -1));
  Tcl_ListObjAppendElement(nil, pCmd, Tcl_NewWideIntObj(rowid));
  Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
  Tcl_DecrRefCount(pCmd);
end;

{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
{ DbPreUpdateHandler — sqlite3_preupdate_hook trampoline.  tclsqlite.c:910..944.
  Appends (op-as-string, zDb, zTbl, iKey1, iKey2) to a duplicate of
  pDb^.pPreUpdateHook and evals it.
  Signature: void (*)(void*, sqlite3*, int, const char*, const char*,
                      sqlite3_int64, sqlite3_int64). }
procedure DbPreUpdateHandler(p: Pointer; db: PTsqlite3; op: cint;
  zDb, zTbl: PAnsiChar; iKey1, iKey2: Int64); cdecl;
const
  azStr: array[0..2] of PAnsiChar = ('DELETE', 'INSERT', 'UPDATE');
var
  pDb:  PSqliteDb;
  pCmd: PTclObj;
begin
  pDb  := PSqliteDb(p);
  pCmd := Tcl_DuplicateObj(pDb^.pPreUpdateHook);
  Tcl_IncrRefCount(pCmd);
  Tcl_ListObjAppendElement(nil, pCmd,
    Tcl_NewStringObj(azStr[(op - 1) div 9], -1));
  Tcl_ListObjAppendElement(nil, pCmd, Tcl_NewStringObj(zDb, -1));
  Tcl_ListObjAppendElement(nil, pCmd, Tcl_NewStringObj(zTbl, -1));
  Tcl_ListObjAppendElement(nil, pCmd, Tcl_NewWideIntObj(iKey1));
  Tcl_ListObjAppendElement(nil, pCmd, Tcl_NewWideIntObj(iKey2));
  Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
  Tcl_DecrRefCount(pCmd);
end;
{$ENDIF}

{$IFDEF SQLITE_ENABLE_UNLOCK_NOTIFY}
{ DbUnlockNotify — sqlite3_unlock_notify trampoline.  tclsqlite.c:895..910.
  Each apArg[i] is the SqliteDb* that registered a callback; eval its
  stored pUnlockNotify script then drop the reference (one-shot). }
procedure DbUnlockNotify(apArg: PPointer; nArg: cint); cdecl;
var
  i:   cint;
  pDb: PSqliteDb;
begin
  for i := 0 to nArg - 1 do
  begin
    pDb := PSqliteDb(apArg[i]);
    Tcl_EvalObjEx(pDb^.interp, pDb^.pUnlockNotify,
      TCL_EVAL_GLOBAL or TCL_EVAL_DIRECT);
    Tcl_DecrRefCount(pDb^.pUnlockNotify);
    pDb^.pUnlockNotify := nil;
  end;
end;
{$ENDIF}

{ DbCommitHookArm — `db commit_hook ?CALLBACK?`  tclsqlite.c:2807..2839. }
function DbCommitHookArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:     PSqliteDb;
  zCommit: PAnsiChar;
  len:     cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zCommit <> nil then
      Tcl_AppendResult(interp, pDb^.zCommit, Pointer(nil));
  end
  else
  begin
    if pDb^.zCommit <> nil then
      Tcl_Free(pDb^.zCommit);
    zCommit := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zCommit <> nil) and (len > 0) then
    begin
      pDb^.zCommit := Tcl_Alloc(len + 1);
      Move(zCommit^, pDb^.zCommit^, len + 1);
    end
    else
      pDb^.zCommit := nil;
    if pDb^.zCommit <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_commit_hook(pDb^.db, @DbCommitHandler, pDb);
    end
    else
      sqlite3_commit_hook(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbHookCmd — shared helper for update_hook / rollback_hook / wal_hook.
  tclsqlite.c:2016..2046.  Reports the prior script, stores the new one
  (if non-empty), then (re)registers all three sqlite3 hooks. }
procedure DbHookCmd(interp: PTclInterp; pDb: PSqliteDb;
  pArg: PTclObj; ppHook: PPTclObj);
var
  db: PTsqlite3;
begin
  db := pDb^.db;
  if ppHook^ <> nil then
  begin
    Tcl_SetObjResult(interp, ppHook^);
    if pArg <> nil then
    begin
      Tcl_DecrRefCount(ppHook^);
      ppHook^ := nil;
    end;
  end;
  if pArg <> nil then
  begin
    if Tcl_GetString(pArg)[0] <> #0 then
    begin
      ppHook^ := pArg;
      Tcl_IncrRefCount(ppHook^);
    end;
  end;

{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
  if pDb^.pPreUpdateHook <> nil then
    sqlite3_preupdate_hook(db, @DbPreUpdateHandler, pDb)
  else
    sqlite3_preupdate_hook(db, nil, nil);
{$ENDIF}
  if pDb^.pUpdateHook <> nil then
    sqlite3_update_hook(db, @DbUpdateHandler, pDb)
  else
    sqlite3_update_hook(db, nil, nil);
  if pDb^.pRollbackHook <> nil then
    sqlite3_rollback_hook(db, @DbRollbackHandler, pDb)
  else
    sqlite3_rollback_hook(db, nil, nil);
  if pDb^.pWalHook <> nil then
    sqlite3_wal_hook(db, @DbWalHandler, pDb)
  else
    sqlite3_wal_hook(db, nil, nil);
end;

{ DbHookArm — `db wal_hook|update_hook|rollback_hook ?SCRIPT?`
  tclsqlite.c:4133..4154.  `which`: 0=wal 1=update 2=rollback. }
function DbHookArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj; which: cint): cint; cdecl;
var
  pDb:    PSqliteDb;
  ppHook: PPTclObj;
begin
  pDb := PSqliteDb(clientData);
  case which of
    0: ppHook := @pDb^.pWalHook;
    1: ppHook := @pDb^.pUpdateHook;
  else ppHook := @pDb^.pRollbackHook;
  end;
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?SCRIPT?'));
    Result := TCL_ERROR;
    Exit;
  end;
  pDb^.interp := interp;
  if objc = 3 then
    DbHookCmd(interp, pDb, ObjvAt(objv, 2), ppHook)
  else
    DbHookCmd(interp, pDb, nil, ppHook);
  Result := TCL_OK;
end;

{ DbPreUpdateArm — `db preupdate SUB-COMMAND ?ARGS?`  tclsqlite.c:4054..4131.
  Forms: `db preupdate count`, `db preupdate depth`,
         `db preupdate hook ?SCRIPT?`, `db preupdate new INDEX`,
         `db preupdate old INDEX`.
  When SQLITE_ENABLE_PREUPDATE_HOOK is not defined the whole subcommand
  reports the compile-time-omitted error, matching tclsqlite.c:4055..4058. }
function DbPreUpdateArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
const
  azSub: array[0..5] of PAnsiChar =
    ('count', 'depth', 'hook', 'new', 'old', nil);
  PRE_COUNT = 0; PRE_DEPTH = 1; PRE_HOOK = 2; PRE_NEW = 3; PRE_OLD = 4;
var
  pDb:    PSqliteDb;
  iSub:   cint;
  nCol:   cint;
  iIdx:   cint;
  rc:     cint;
  pValue: Psqlite3_value;
  pObj:   PTclObj;
begin
  pDb := PSqliteDb(clientData);
  if objc < 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('SUB-COMMAND ?ARGS?'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetIndexFromObj(interp, ObjvAt(objv, 2), @azSub[0],
       PChar('sub-command'), 0, @iSub) <> TCL_OK then
  begin
    Result := TCL_ERROR;
    Exit;
  end;

  case iSub of
    PRE_COUNT:
      begin
        nCol := sqlite3_preupdate_count(pDb^.db);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(nCol));
        Result := TCL_OK;
      end;

    PRE_HOOK:
      begin
        if objc > 4 then
        begin
          Tcl_WrongNumArgs(interp, 2, objv, PChar('hook ?SCRIPT?'));
          Result := TCL_ERROR;
          Exit;
        end;
        pDb^.interp := interp;
        if objc = 4 then
          DbHookCmd(interp, pDb, ObjvAt(objv, 3), @pDb^.pPreUpdateHook)
        else
          DbHookCmd(interp, pDb, nil, @pDb^.pPreUpdateHook);
        Result := TCL_OK;
      end;

    PRE_DEPTH:
      begin
        if objc <> 3 then
        begin
          Tcl_WrongNumArgs(interp, 3, objv, PChar(''));
          Result := TCL_ERROR;
          Exit;
        end;
        Tcl_SetObjResult(interp,
          Tcl_NewIntObj(sqlite3_preupdate_depth(pDb^.db)));
        Result := TCL_OK;
      end;

    PRE_NEW, PRE_OLD:
      begin
        if objc <> 4 then
        begin
          Tcl_WrongNumArgs(interp, 3, objv, PChar('INDEX'));
          Result := TCL_ERROR;
          Exit;
        end;
        if Tcl_GetIntFromObj(interp, ObjvAt(objv, 3), @iIdx) <> TCL_OK then
        begin
          Result := TCL_ERROR;
          Exit;
        end;
        pValue := nil;
        if iSub = PRE_OLD then
          rc := sqlite3_preupdate_old(pDb^.db, iIdx, @pValue)
        else
          rc := sqlite3_preupdate_new(pDb^.db, iIdx, @pValue);
        if rc = SQLITE_OK then
        begin
          pObj := Tcl_NewStringObj(PAnsiChar(sqlite3_value_text(pValue)), -1);
          Tcl_SetObjResult(interp, pObj);
          Result := TCL_OK;
        end
        else
        begin
          Tcl_AppendResult(interp, PAnsiChar(sqlite3_errmsg(pDb^.db)),
            Pointer(nil));
          Result := TCL_ERROR;
        end;
      end;
  else
    Result := TCL_OK;
  end;
end;
{$ELSE}
begin
  Tcl_AppendResult(interp,
    PChar('preupdate_hook was omitted at compile-time'), Pointer(nil));
  Result := TCL_ERROR;
end;
{$ENDIF}

{ DbUnlockNotifyArm — `db unlock_notify ?SCRIPT?`  tclsqlite.c:4012..4047.
  Registers a one-shot unlock-notify callback.  With no SCRIPT it cancels
  any prior registration.  When SQLITE_ENABLE_UNLOCK_NOTIFY is not
  defined the whole subcommand reports the compile-time-omitted error,
  matching tclsqlite.c:4015..4018. }
function DbUnlockNotifyArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
{$IFDEF SQLITE_ENABLE_UNLOCK_NOTIFY}
var
  pDb:        PSqliteDb;
  xNotify:    Tsqlite3_unlock_notify_cb;
  pNotifyArg: Pointer;
begin
  pDb := PSqliteDb(clientData);
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?SCRIPT?'));
    Result := TCL_ERROR;
    Exit;
  end;

  xNotify    := nil;
  pNotifyArg := nil;

  if pDb^.pUnlockNotify <> nil then
  begin
    Tcl_DecrRefCount(pDb^.pUnlockNotify);
    pDb^.pUnlockNotify := nil;
  end;

  if objc = 3 then
  begin
    xNotify    := @DbUnlockNotify;
    pNotifyArg := pDb;
    pDb^.interp := interp;
    pDb^.pUnlockNotify := ObjvAt(objv, 2);
    Tcl_IncrRefCount(pDb^.pUnlockNotify);
  end;

  if sqlite3_unlock_notify(pDb^.db, xNotify, pNotifyArg) <> 0 then
  begin
    Tcl_AppendResult(interp, PAnsiChar(sqlite3_errmsg(pDb^.db)),
      Pointer(nil));
    Result := TCL_ERROR;
  end
  else
    Result := TCL_OK;
end;
{$ELSE}
begin
  Tcl_AppendResult(interp,
    PChar('unlock_notify not available in this build'), Pointer(nil));
  Result := TCL_ERROR;
end;
{$ENDIF}

{ DbTransPostCmd — port of tclsqlite.c:1308..1349.  Invoked after the
  [transaction] script body has been evaluated; commits/releases on
  success or rolls back on error.  `result` is the rc of the body eval. }
function DbTransPostCmd(pDb: PSqliteDb; interp: PTclInterp;
  bodyRc: cint): cint;
const
  azEnd: array[0..3] of PChar = (
    'RELEASE _tcl_transaction',                        { rc==ERROR, nTrans!=0 }
    'COMMIT',                                          { rc!=ERROR, nTrans==0 }
    'ROLLBACK TO _tcl_transaction ; RELEASE _tcl_transaction',
    'ROLLBACK');                                       { rc==ERROR, nTrans==0 }
var
  rc:   cint;
  zEnd: PChar;
  idx:  cint;
begin
  rc := bodyRc;
  Dec(pDb^.nTransaction);
  idx := 0;
  if rc = TCL_ERROR then idx := idx + 2;
  if pDb^.nTransaction = 0 then idx := idx + 1;
  zEnd := azEnd[idx];

  if sqlite3_exec(pDb^.db, zEnd, nil, nil, nil) <> SQLITE_OK then
  begin
    { The most likely cause is a SQLITE_BUSY on the top-level COMMIT,
      or an IO error.  Throw a Tcl exception and roll back. }
    if rc <> TCL_ERROR then
    begin
      Tcl_AppendResult(interp, PAnsiChar(sqlite3_errmsg(pDb^.db)),
        Pointer(nil));
      rc := TCL_ERROR;
    end;
    sqlite3_exec(pDb^.db, PChar('ROLLBACK'), nil, nil, nil);
  end;

  Result := rc;
end;

{ DbTransPostCmdNRE — NRE-shaped wrapper around DbTransPostCmd.  Matches
  upstream's DbTransPostCmd Tcl_NRPostProc signature (tclsqlite.c:1308..1348)
  used as a continuation by tclsqlite.c:4003.  data[0] is the SqliteDb*;
  `result` is the body-eval rc supplied by the NRE trampoline. }
function DbTransPostCmdNRE(data: PClientDataArray; interp: PTclInterp;
  bodyRc: cint): cint; cdecl;
var
  pDb: PSqliteDb;
begin
  pDb := PSqliteDb(data^);
  Result := DbTransPostCmd(pDb, interp, bodyRc);
end;

{ DbTransactionArm — port of the DB_TRANSACTION arm (tclsqlite.c:3958..4009).
  `db transaction ?TYPE? SCRIPT` — opens a transaction (or, if nested,
  a SAVEPOINT), evaluates SCRIPT, then commits/releases on success or
  rolls back on error.  Nesting depth tracked via pDb^.nTransaction.
  When the linked Tcl supports NRE we wire the body via
  Tcl_NRAddCallback(DbTransPostCmdNRE, …) + Tcl_NREvalObj
  (tclsqlite.c:4002..4004); otherwise we keep the simple recursive
  Tcl_EvalObjEx form (tclsqlite.c:4005..4006). }
function DbTransactionArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  TTYPE_strs: array[0..3] of PChar = (
    'deferred', 'exclusive', 'immediate', nil);
var
  pDb:     PSqliteDb;
  pScript: PTclObj;
  zBegin:  PChar;
  ttype:   cint;
begin
  pDb := PSqliteDb(clientData);
  zBegin := 'SAVEPOINT _tcl_transaction';
  if (objc <> 3) and (objc <> 4) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('[TYPE] SCRIPT'));
    Result := TCL_ERROR;
    Exit;
  end;

  if (pDb^.nTransaction = 0) and (objc = 4) then
  begin
    if Tcl_GetIndexFromObj(interp, ObjvAt(objv, 2), @TTYPE_strs[0],
         PChar('transaction type'), 0, @ttype) <> TCL_OK then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
    case ttype of
      0: ;                                  { deferred — no-op }
      1: zBegin := 'BEGIN EXCLUSIVE';        { exclusive }
      2: zBegin := 'BEGIN IMMEDIATE';        { immediate }
    end;
  end;
  pScript := ObjvAt(objv, objc - 1);

  { Run the BEGIN/SAVEPOINT to open a transaction or savepoint. }
  if sqlite3_exec(pDb^.db, zBegin, nil, nil, nil) <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, PAnsiChar(sqlite3_errmsg(pDb^.db)),
      Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  Inc(pDb^.nTransaction);

  { Evaluate the body, then commit (or rollback) the transaction.  Port of
    tclsqlite.c:3996..4007 — under NRE, schedule DbTransPostCmd as a
    continuation and hand the body off to Tcl_NREvalObj so nested vwait
    can unwind cleanly; otherwise fall back to the recursive form. }
  pDb^.interp := interp;
  if DbUseNre then
  begin
    Tcl_NRAddCallback(interp, @DbTransPostCmdNRE,
      TClientData(pDb), nil, nil, nil);
    Result := Tcl_NREvalObj(interp, pScript, 0);
  end
  else
    Result := DbTransPostCmd(pDb, interp, Tcl_EvalObjEx(interp, pScript, 0));
end;

{ DbOneColumnExistsArm — port of the shared DB_EXISTS / DB_ONECOLUMN arm
  of DbObjCmd (tclsqlite.c:3259..3297).  `db onecolumn $sql` returns the
  first column of the first row (empty if no rows); `db exists $sql`
  returns 1 if any row, else 0.  Upstream uses dbEvalInit/dbEvalStep; we
  drive sqlite3_prepare_v2 + a single sqlite3_step directly.

  bExists=False -> onecolumn; bExists=True -> exists. }
function DbOneColumnExistsArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj; bExists: Boolean): cint; cdecl;
var
  pDb:      PSqliteDb;
  pResult:  PTclObj;
  sEval:    TDbEvalContext;
  rc:       cint;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('SQL'));
    Result := TCL_ERROR;
    Exit;
  end;

  pDb     := PSqliteDb(clientData);
  pResult := nil;

  { Faithful port of tclsqlite.c:3259..3286 (DB_EXISTS / DB_ONECOLUMN):
    iterate dbEvalStep so multi-statement scripts like
      "COMMIT; SELECT count(*) FROM t1"
    skip statements that produce no rows and return the first row of
    the first row-producing statement (or "" / 0 if none).  The previous
    single-prepare path only ever compiled the FIRST statement (pzTail
    discarded), so a leading COMMIT swallowed the trailing SELECT and
    `db one` returned empty — surfaces as btree02-110 expected 10 got [].
    (9.4.divbug.90.001.) }
  DbEvalInit(@sEval, pDb, ObjvAt(objv, 2), nil, 0);
  rc := DbEvalStep(@sEval);
  if not bExists then
  begin
    if rc = TCL_OK then
      pResult := DbEvalColumnValueCtx(@sEval, 0)
    else if rc = TCL_BREAK then
      Tcl_ResetResult(interp);
  end
  else if (rc = TCL_BREAK) or (rc = TCL_OK) then
    pResult := Tcl_NewBooleanObj(Ord(rc = TCL_OK));

  DbEvalFinalize(@sEval);
  if pResult <> nil then
    Tcl_SetObjResult(interp, pResult);

  if rc = TCL_BREAK then rc := TCL_OK;
  Result := rc;
end;

{ DbCacheArm — port of the DB_CACHE arm of DbObjCmd (tclsqlite.c:2678..
  2718).  `db cache flush` finalises the stmt cache; `db cache size N`
  bounds it.  This minimal bridge keeps no stmt cache, so `flush` is a
  no-op and `size N` simply records N in pDb^.maxStmt (clamped >= 0). }
function DbCacheArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:     PSqliteDb;
  zSubCmd: PAnsiChar;
  n:       cint;
begin
  pDb := PSqliteDb(clientData);
  if objc <= 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('cache option ?arg?'));
    Result := TCL_ERROR;
    Exit;
  end;
  zSubCmd := Tcl_GetStringFromObj(ObjvAt(objv, 2), nil);
  if (zSubCmd <> nil) and (zSubCmd^ = 'f') and
     (StrComp(zSubCmd, PAnsiChar('flush')) = 0) then
  begin
    if objc <> 3 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar('flush'));
      Result := TCL_ERROR;
      Exit;
    end;
    FlushStmtCache(pDb);   { tclsqlite.c:2690 }
  end
  else if (zSubCmd <> nil) and (zSubCmd^ = 's') and
          (StrComp(zSubCmd, PAnsiChar('size')) = 0) then
  begin
    if objc <> 4 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar('size n'));
      Result := TCL_ERROR;
      Exit;
    end;
    if Tcl_GetIntFromObj(interp, ObjvAt(objv, 3), @n) = TCL_ERROR then
    begin
      Tcl_AppendResult(interp, PChar('cannot convert "'),
        Tcl_GetStringFromObj(ObjvAt(objv, 3), nil),
        PChar('" to integer'), Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
    { tclsqlite.c:2704..2709 — n<0 flushes the cache then clamps to 0,
      n>MAX_PREPARED_STMTS clamps down. }
    if n < 0 then
    begin
      FlushStmtCache(pDb);
      n := 0;
    end
    else if n > MAX_PREPARED_STMTS then
      n := MAX_PREPARED_STMTS;
    pDb^.maxStmt := n;
  end
  else
  begin
    Tcl_AppendResult(interp, PChar('bad option "'),
      Tcl_GetStringFromObj(ObjvAt(objv, 2), nil),
      PChar('": must be flush or size'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
end;

{ DbConfigArm — port of the DB_CONFIG arm of DbObjCmd (tclsqlite.c:
  2864..2940).  With no args, lists every boolean DBCONFIG option and its
  current value; with `?OPTION? ?BOOLEAN?` reads or sets one.  Routes
  through sqlite3_db_config_int — the typed entry point for the boolean
  DBCONFIG ops in this port. }
function DbConfigArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  { Mirrors aDbConfig[] in tclsqlite.c:2865..2882. }
  cfgNames: array[0..15] of PChar = (
    'defensive', 'dqs_ddl', 'dqs_dml', 'enable_fkey', 'enable_qpsg',
    'enable_trigger', 'enable_view', 'fts3_tokenizer', 'legacy_alter_table',
    'legacy_file_format', 'load_extension', 'no_ckpt_on_close',
    'reset_database', 'trigger_eqp', 'trusted_schema', 'writable_schema');
  cfgOps: array[0..15] of i32 = (
    SQLITE_DBCONFIG_DEFENSIVE, SQLITE_DBCONFIG_DQS_DDL,
    SQLITE_DBCONFIG_DQS_DML, SQLITE_DBCONFIG_ENABLE_FKEY,
    SQLITE_DBCONFIG_ENABLE_QPSG, SQLITE_DBCONFIG_ENABLE_TRIGGER,
    SQLITE_DBCONFIG_ENABLE_VIEW, SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER,
    SQLITE_DBCONFIG_LEGACY_ALTER_TABLE, SQLITE_DBCONFIG_LEGACY_FILE_FORMAT,
    SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE,
    SQLITE_DBCONFIG_RESET_DATABASE, SQLITE_DBCONFIG_TRIGGER_EQP,
    SQLITE_DBCONFIG_TRUSTED_SCHEMA, SQLITE_DBCONFIG_WRITABLE_SCHEMA);
var
  pDb:     PSqliteDb;
  pResult: PTclObj;
  ii:      cint;
  v:       i32;
  zOpt:    PAnsiChar;
  onoff:   cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 4 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?OPTION? ?BOOLEAN?'));
    Result := TCL_ERROR;
    Exit;
  end;
  if objc = 2 then
  begin
    { No args — list every option with its current value. }
    pResult := Tcl_NewListObj(0, nil);
    for ii := 0 to High(cfgNames) do
    begin
      v := 0;
      sqlite3_db_config_int(pDb^.db, cfgOps[ii], -1, @v);
      Tcl_ListObjAppendElement(interp, pResult,
        Tcl_NewStringObj(cfgNames[ii], -1));
      Tcl_ListObjAppendElement(interp, pResult, Tcl_NewIntObj(v));
    end;
  end
  else
  begin
    zOpt := Tcl_GetString(ObjvAt(objv, 2));
    onoff := -1;
    v := 0;
    if (zOpt <> nil) and (zOpt^ = '-') then Inc(zOpt);
    ii := 0;
    while (ii <= High(cfgNames)) and
          (StrComp(cfgNames[ii], zOpt) <> 0) do
      Inc(ii);
    if ii > High(cfgNames) then
    begin
      Tcl_AppendResult(interp, PChar('unknown config option: "'),
        zOpt, PChar('"'), Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
    if objc = 4 then
    begin
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, 3), @onoff) <> TCL_OK then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
    end;
    sqlite3_db_config_int(pDb^.db, cfgOps[ii], onoff, @v);
    pResult := Tcl_NewIntObj(v);
  end;
  Tcl_SetObjResult(interp, pResult);
  Result := TCL_OK;
end;

{ QuoteSqlIdent — Pascal stand-in for sqlite3_mprintf's `%q` conversion
  (this port's sqlite3_mprintf has no C-ABI varargs).  Returns a new
  AnsiString with every single-quote doubled, suitable for embedding
  between '...' delimiters. }
function QuoteSqlIdent(const z: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(z) do
  begin
    if z[i] = '''' then Result := Result + '''''';
    Result := Result + z[i];
  end;
end;

{ DbCopyArm — port of the DB_COPY arm of DbObjCmd (tclsqlite.c:2946..
  3122).  `db copy CONFLICT TABLE FILENAME ?SEP? ?NULL?` — bulk-imports
  the PostgreSQL-COPY-format file into TABLE.  Returns the line count on
  success.  Faithful port; SQL strings are built with QuoteSqlIdent in
  place of sqlite3_mprintf("%q"). }
function DbCopyArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:       PSqliteDb;
  zTable:    PAnsiChar;
  zFile:     PAnsiChar;
  zConflict: PAnsiChar;
  pStmt:     Pointer;
  nCol:      cint;
  i:         cint;
  nSep:      cint;
  nNull:     cint;
  sqlStr:    AnsiString;
  rc:        i32;
  zLine:     PAnsiChar;
  byteLen:   cint;
  in_:       TTclChannel;
  lineno:    cint;
  str:       PTclObj;
  zCommit:   PChar;
  zSep:      PAnsiChar;
  zNull:     PAnsiChar;
  azCol:     array of PAnsiChar;
  z:         PAnsiChar;
  pResult:   PTclObj;
  zErr:      AnsiString;
begin
  pDb := PSqliteDb(clientData);
  if (objc < 5) or (objc > 7) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv,
      PChar('CONFLICT-ALGORITHM TABLE FILENAME ?SEPARATOR? ?NULLINDICATOR?'));
    Result := TCL_ERROR;
    Exit;
  end;
  if objc >= 6 then zSep := Tcl_GetStringFromObj(ObjvAt(objv, 5), nil)
  else zSep := PChar(#9);
  if objc >= 7 then zNull := Tcl_GetStringFromObj(ObjvAt(objv, 6), nil)
  else zNull := PChar('');
  zConflict := Tcl_GetStringFromObj(ObjvAt(objv, 2), nil);
  zTable    := Tcl_GetStringFromObj(ObjvAt(objv, 3), nil);
  zFile     := Tcl_GetStringFromObj(ObjvAt(objv, 4), nil);
  nSep  := StrLen(zSep);
  nNull := StrLen(zNull);
  if nSep = 0 then
  begin
    Tcl_AppendResult(interp,
      PChar('Error: non-null separator required for copy'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  if (StrComp(zConflict, PAnsiChar('rollback')) <> 0) and
     (StrComp(zConflict, PAnsiChar('abort'))    <> 0) and
     (StrComp(zConflict, PAnsiChar('fail'))     <> 0) and
     (StrComp(zConflict, PAnsiChar('ignore'))   <> 0) and
     (StrComp(zConflict, PAnsiChar('replace'))  <> 0) then
  begin
    Tcl_AppendResult(interp, PChar('Error: "'), zConflict,
      PChar('", conflict-algorithm must be one of: rollback, ' +
            'abort, fail, ignore, or replace'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;

  { Probe the table for its column count. }
  sqlStr := 'SELECT * FROM ''' + QuoteSqlIdent(zTable) + '''';
  pStmt := nil;
  rc := sqlite3_prepare(pDb^.db, PChar(sqlStr), -1, @pStmt, nil);
  if rc <> 0 then
  begin
    Tcl_AppendResult(interp, PChar('Error: '),
      PAnsiChar(sqlite3_errmsg(pDb^.db)), Pointer(nil));
    nCol := 0;
  end
  else
    nCol := sqlite3_column_count(pStmt);
  sqlite3_finalize(pStmt);
  if nCol = 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;

  { Build "INSERT OR <conflict> INTO '<table>' VALUES(?,?,...)". }
  sqlStr := 'INSERT OR ' + AnsiString(zConflict) + ' INTO ''' +
            QuoteSqlIdent(zTable) + ''' VALUES(?';
  for i := 1 to nCol - 1 do
    sqlStr := sqlStr + ',?';
  sqlStr := sqlStr + ')';
  pStmt := nil;
  rc := sqlite3_prepare(pDb^.db, PChar(sqlStr), -1, @pStmt, nil);
  if rc <> 0 then
  begin
    Tcl_AppendResult(interp, PChar('Error: '),
      PAnsiChar(sqlite3_errmsg(pDb^.db)), Pointer(nil));
    sqlite3_finalize(pStmt);
    Result := TCL_ERROR;
    Exit;
  end;

  in_ := Tcl_OpenFileChannel(interp, zFile, PChar('rb'), 0666);
  if in_ = nil then
  begin
    sqlite3_finalize(pStmt);
    Result := TCL_ERROR;
    Exit;
  end;
  Tcl_SetChannelOption(nil, in_, PChar('-translation'), PChar('auto'));
  SetLength(azCol, nCol + 1);

  str := Tcl_NewObj();
  Tcl_IncrRefCount(str);
  sqlite3_exec(pDb^.db, PChar('BEGIN'), nil, nil, nil);
  zCommit := 'COMMIT';
  lineno  := 0;

  while Tcl_GetsObj(in_, str) >= 0 do
  begin
    Inc(lineno);
    byteLen := 0;
    zLine := Tcl_GetByteArrayFromObj(str, @byteLen);
    azCol[0] := zLine;
    i := 0;
    z := zLine;
    while z^ <> #0 do
    begin
      if (z^ = zSep[0]) and (StrLComp(z, zSep, nSep) = 0) then
      begin
        z^ := #0;
        Inc(i);
        if i < nCol then
        begin
          azCol[i] := z + nSep;
          z := z + (nSep - 1);
        end;
      end;
      Inc(z);
    end;
    if i + 1 <> nCol then
    begin
      zErr := 'Error: ' + AnsiString(zFile) + ' line ' + IntToStr(lineno) +
        ': expected ' + IntToStr(nCol) + ' columns of data but found ' +
        IntToStr(i + 1);
      Tcl_AppendResult(interp, PChar(zErr), Pointer(nil));
      zCommit := 'ROLLBACK';
      break;
    end;
    for i := 0 to nCol - 1 do
    begin
      if ((nNull > 0) and (StrComp(azCol[i], zNull) = 0)) or
         (StrLen(azCol[i]) = 0) then
        sqlite3_bind_null(pStmt, i + 1)
      else
        sqlite3_bind_text(pStmt, i + 1, azCol[i], -1, SQLITE_STATIC);
    end;
    sqlite3_step(pStmt);
    rc := sqlite3_reset(pStmt);
    Tcl_SetObjLength(str, 0);
    if rc <> SQLITE_OK then
    begin
      Tcl_AppendResult(interp, PChar('Error: '),
        PAnsiChar(sqlite3_errmsg(pDb^.db)), Pointer(nil));
      zCommit := 'ROLLBACK';
      break;
    end;
  end;

  Tcl_DecrRefCount(str);
  azCol := nil;
  Tcl_Close(interp, in_);
  sqlite3_finalize(pStmt);
  sqlite3_exec(pDb^.db, zCommit, nil, nil, nil);

  if zCommit[0] = 'C' then
  begin
    pResult := Tcl_GetObjResult(interp);
    Tcl_SetIntObj(pResult, lineno);
    Result := TCL_OK;
  end
  else
  begin
    Tcl_AppendResult(interp, PChar(', failed while processing line: '),
      PChar(IntToStr(lineno)), Pointer(nil));
    Result := TCL_ERROR;
  end;
end;

{ DbBackupArm — port of the DB_BACKUP arm of DbObjCmd (tclsqlite.c:2549..
  2590).  `db backup ?SRCDB? FILENAME` — opens FILENAME read/write+create
  and copies SRCDB ("main" by default) into its "main".  Collapses onto
  sqlite3_backup_init / _step / _finish (9.4.2.q). }
function DbBackupArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:       PSqliteDb;
  zDestFile: PAnsiChar;
  zSrcDb:    PAnsiChar;
  pDest:     PTsqlite3;
  pBackup:   PSqlite3Backup;
  rc:        i32;
begin
  pDb := PSqliteDb(clientData);
  if objc = 3 then
  begin
    zSrcDb    := 'main';
    zDestFile := Tcl_GetString(ObjvAt(objv, 2));
  end
  else if objc = 4 then
  begin
    zSrcDb    := Tcl_GetString(ObjvAt(objv, 2));
    zDestFile := Tcl_GetString(ObjvAt(objv, 3));
  end
  else
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?DATABASE? FILENAME'));
    Result := TCL_ERROR;
    Exit;
  end;

  pDest := nil;
  rc := sqlite3_open_v2(zDestFile, @pDest,
          i32(SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE) or
          i32(pDb^.openFlags), nil);
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, PChar('cannot open target database: '),
      PAnsiChar(sqlite3_errmsg(pDest)), Pointer(nil));
    sqlite3_close(pDest);
    Result := TCL_ERROR;
    Exit;
  end;

  pBackup := sqlite3_backup_init(pDest, 'main', pDb^.db, zSrcDb);
  if pBackup = nil then
  begin
    Tcl_AppendResult(interp, PChar('backup failed: '),
      PAnsiChar(sqlite3_errmsg(pDest)), Pointer(nil));
    sqlite3_close(pDest);
    Result := TCL_ERROR;
    Exit;
  end;

  repeat
    rc := sqlite3_backup_step(pBackup, 100);
  until rc <> SQLITE_OK;
  sqlite3_backup_finish(pBackup);

  if rc = SQLITE_DONE then
    Result := TCL_OK
  else
  begin
    Tcl_AppendResult(interp, PChar('backup failed: '),
      PAnsiChar(sqlite3_errmsg(pDest)), Pointer(nil));
    Result := TCL_ERROR;
  end;
  sqlite3_close(pDest);
end;

{ DbRestoreArm — port of the DB_RESTORE arm of DbObjCmd (tclsqlite.c:3672..
  3722).  `db restore ?DESTDB? FILENAME` — opens FILENAME read-only and
  copies its "main" into DESTDB ("main" by default).  Retries SQLITE_BUSY
  up to 3 times with a 100ms sleep, matching upstream (9.4.2.q). }
function DbRestoreArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:      PSqliteDb;
  zSrcFile: PAnsiChar;
  zDestDb:  PAnsiChar;
  pSrc:     PTsqlite3;
  pBackup:  PSqlite3Backup;
  rc:       i32;
  nTimeout: cint;
begin
  pDb := PSqliteDb(clientData);
  nTimeout := 0;
  if objc = 3 then
  begin
    zDestDb  := 'main';
    zSrcFile := Tcl_GetString(ObjvAt(objv, 2));
  end
  else if objc = 4 then
  begin
    zDestDb  := Tcl_GetString(ObjvAt(objv, 2));
    zSrcFile := Tcl_GetString(ObjvAt(objv, 3));
  end
  else
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?DATABASE? FILENAME'));
    Result := TCL_ERROR;
    Exit;
  end;

  pSrc := nil;
  rc := sqlite3_open_v2(zSrcFile, @pSrc,
          i32(SQLITE_OPEN_READONLY) or i32(pDb^.openFlags), nil);
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, PChar('cannot open source database: '),
      PAnsiChar(sqlite3_errmsg(pSrc)), Pointer(nil));
    sqlite3_close(pSrc);
    Result := TCL_ERROR;
    Exit;
  end;

  pBackup := sqlite3_backup_init(pDb^.db, zDestDb, pSrc, 'main');
  if pBackup = nil then
  begin
    Tcl_AppendResult(interp, PChar('restore failed: '),
      PAnsiChar(sqlite3_errmsg(pDb^.db)), Pointer(nil));
    sqlite3_close(pSrc);
    Result := TCL_ERROR;
    Exit;
  end;

  repeat
    rc := sqlite3_backup_step(pBackup, 100);
    if rc = SQLITE_BUSY then
    begin
      if nTimeout >= 3 then Break;
      Inc(nTimeout);
      sqlite3_sleep(100);
    end;
  until (rc <> SQLITE_OK) and (rc <> SQLITE_BUSY);
  sqlite3_backup_finish(pBackup);

  if rc = SQLITE_DONE then
    Result := TCL_OK
  else if (rc = SQLITE_BUSY) or (rc = SQLITE_LOCKED) then
  begin
    Tcl_AppendResult(interp, PChar('restore failed: source database busy'),
      Pointer(nil));
    Result := TCL_ERROR;
  end
  else
  begin
    Tcl_AppendResult(interp, PChar('restore failed: '),
      PAnsiChar(sqlite3_errmsg(pDb^.db)), Pointer(nil));
    Result := TCL_ERROR;
  end;
  sqlite3_close(pSrc);
end;

{ DbSerializeArm — port of the DB_SERIALIZE arm of DbObjCmd (tclsqlite.c
  :3732..3756).  `db serialize ?DATABASE?` — returns a byte-array
  serialization of DATABASE ("main" by default).  Tries the NOCOPY fast
  path first, falling back to an owned buffer that is sqlite3_free'd after
  the byte-array copy (9.4.2.r). }
function DbSerializeArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:      PSqliteDb;
  zSchema:  PAnsiChar;
  sz:       i64;
  pData:    Pu8;
  needFree: Boolean;
begin
  pDb := PSqliteDb(clientData);
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?DATABASE?'));
    Result := TCL_ERROR;
    Exit;
  end;
  if objc >= 3 then
    zSchema := Tcl_GetString(ObjvAt(objv, 2))
  else
    zSchema := 'main';

  sz := 0;
  pData := sqlite3_serialize(pDb^.db, zSchema, @sz, SQLITE_SERIALIZE_NOCOPY);
  if pData <> nil then
    needFree := False
  else
  begin
    pData := sqlite3_serialize(pDb^.db, zSchema, @sz, 0);
    needFree := True;
  end;
  Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(pData, cint(sz)));
  if needFree then sqlite3_free(pData);
  Result := TCL_OK;
end;

{ DbDeserializeArm — port of the DB_DESERIALIZE arm of DbObjCmd
  (tclsqlite.c:3133..3203).  `db deserialize ?-maxsize N? ?-readonly BOOL?
  ?DATABASE? VALUE` — replaces the contents of DATABASE ("main" by
  default) with the byte-array VALUE via sqlite3_deserialize, transferring
  buffer ownership with FREEONCLOSE (9.4.2.r). }
function DbDeserializeArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  SQLITE_FCNTL_SIZE_LIMIT = 36;
var
  pDb:        PSqliteDb;
  zSchema:    PAnsiChar;
  pValue:     PTclObj;
  pBA:        PAnsiChar;
  pData:      Pu8;
  len:        cint;
  xrc:        i32;
  mxSize:     i64;
  isReadonly: cint;
  i:          cint;
  z:          PAnsiChar;
  wx:         Int64;
  flags:      u32;
begin
  pDb := PSqliteDb(clientData);
  zSchema    := nil;
  mxSize     := 0;
  isReadonly := 0;

  if objc < 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?DATABASE? VALUE'));
    Result := TCL_ERROR;
    Exit;
  end;

  i := 2;
  while i < objc - 1 do
  begin
    z := Tcl_GetString(ObjvAt(objv, i));
    if (StrComp(z, '-maxsize') = 0) and (i < objc - 2) then
    begin
      Inc(i);
      if Tcl_GetWideIntFromObj(interp, ObjvAt(objv, i), @wx) <> TCL_OK then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
      mxSize := wx;
      Inc(i);
      Continue;
    end;
    if (StrComp(z, '-readonly') = 0) and (i < objc - 2) then
    begin
      Inc(i);
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, i), @isReadonly) <> TCL_OK then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
      Inc(i);
      Continue;
    end;
    if (zSchema = nil) and (i = objc - 2) and (z[0] <> '-') then
    begin
      zSchema := z;
      Inc(i);
      Continue;
    end;
    Tcl_AppendResult(interp, PChar('unknown option: '), z, Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;

  pValue := ObjvAt(objv, objc - 1);
  len := 0;
  pBA := Tcl_GetByteArrayFromObj(pValue, @len);
  pData := Pu8(sqlite3_malloc64(u64(len)));
  if (pData = nil) and (len > 0) then
  begin
    Tcl_AppendResult(interp, PChar('out of memory'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;

  if len > 0 then Move(pBA^, pData^, len);
  if isReadonly <> 0 then
    flags := SQLITE_DESERIALIZE_FREEONCLOSE or SQLITE_DESERIALIZE_READONLY
  else
    flags := SQLITE_DESERIALIZE_FREEONCLOSE or SQLITE_DESERIALIZE_RESIZEABLE;

  Result := TCL_OK;
  xrc := sqlite3_deserialize(pDb^.db, zSchema, pData, len, len, flags);
  if xrc <> 0 then
  begin
    Tcl_AppendResult(interp, PChar('unable to set MEMDB content'),
      Pointer(nil));
    Result := TCL_ERROR;
  end;
  if mxSize > 0 then
    sqlite3_file_control(pDb^.db, zSchema, SQLITE_FCNTL_SIZE_LIMIT, @mxSize);
end;

{ DbObjCmdAdaptor — the per-connection dispatcher.  In 9.4.2.c only
  the "close" arm is wired; everything else returns TCL_ERROR with
  a stable "unknown subcommand" string so callers can grep it. }
function DbObjCmdAdaptor(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zSub:  PAnsiChar;
  zSelf: PAnsiChar;
  iBool: cint;
  zStatOp:  PAnsiChar;
  iStatVal: cint;
begin
  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SUBCOMMAND ...'));
    Result := TCL_ERROR;
    Exit;
  end;

  zSub := Tcl_GetStringFromObj(ObjvAt(objv, 1), nil);

  { close — tclsqlite.c:2743. }
  if (zSub <> nil) and (StrComp(zSub, 'close') = 0) then
  begin
    zSelf := Tcl_GetStringFromObj(ObjvAt(objv, 0), nil);
    Tcl_DeleteCommand(interp, zSelf);
    Result := TCL_OK;
    Exit;
  end;

  { eval — tclsqlite.c "eval" arm of DbObjCmd (~2700..2820, dispatch
    table at :2445).  This is a straight-line minimum port of
    dbEvalStep (tclsqlite.c:1766..1823): we drive
    sqlite3_prepare_v2 / sqlite3_step / sqlite3_finalize in-line and
    accumulate a flat Tcl list of column values.

    KNOWN DIVERGENCE from upstream's dbEvalColumnValue
    (tclsqlite.c:1850..1876): every column is stringified through
    sqlite3_column_text (UTF-8) and wrapped with Tcl_NewStringObj.
    Upstream returns typed Tcl_Obj (Int / WideInt / Double /
    ByteArray) per sqlite3_column_type.  Cite the Pascal feedback
    feedback_result_text_change_encoding.md re: text encoding —
    sqlite3_column_text always renders UTF-8, so Tcl_NewStringObj is
    safe here.  Typed-Obj marshalling lands as a follow-up (9.4.2.d.1
    if/when a .test file demands it; `puts [db eval ...]` stringifies
    anyway so the divergence is invisible to ~99% of tester.tcl
    call sites).

    Also deferred vs upstream:
      * 4-arg form `db eval sql arrayName script` — would require a
        sub-interpreter eval per row;
      * `$var` substitution in SQL (dbPrepareAndBind);
      * the prepared-statement cache (SqlPreparedStmt);
      * DbEvalContext / NRE machinery;
      * busy-handler retries on SQLITE_SCHEMA. }
  if (zSub <> nil) and (StrComp(zSub, 'eval') = 0) then
  begin
    Result := DbEvalArm(clientData, interp, objc, objv);
    Exit;
  end;

  { version — tclsqlite.c:4161. }
  if (zSub <> nil) and (StrComp(zSub, 'version') = 0) then
  begin
    Tcl_AppendResult(interp, sqlite3_libversion(), Pointer(nil));
    Result := TCL_OK;
    Exit;
  end;

  { changes — tclsqlite.c:2728.  We use sqlite3_changes64 (i64). }
  if (zSub <> nil) and (StrComp(zSub, 'changes') = 0) then
  begin
    if objc <> 2 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar(''));
      Result := TCL_ERROR;
      Exit;
    end;
    Tcl_SetObjResult(interp,
      Tcl_NewWideIntObj(sqlite3_changes64(PSqliteDb(clientData)^.db)));
    Result := TCL_OK;
    Exit;
  end;

  { last_insert_rowid — tclsqlite.c:3552. }
  if (zSub <> nil) and (StrComp(zSub, 'last_insert_rowid') = 0) then
  begin
    if objc <> 2 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar(''));
      Result := TCL_ERROR;
      Exit;
    end;
    Tcl_SetObjResult(interp,
      Tcl_NewWideIntObj(sqlite3_last_insert_rowid(PSqliteDb(clientData)^.db)));
    Result := TCL_OK;
    Exit;
  end;

  { errorcode — tclsqlite.c:3236. }
  if (zSub <> nil) and (StrComp(zSub, 'errorcode') = 0) then
  begin
    Tcl_SetObjResult(interp,
      Tcl_NewIntObj(sqlite3_errcode(PSqliteDb(clientData)^.db)));
    Result := TCL_OK;
    Exit;
  end;

  { nullvalue — tclsqlite.c:3524.  Mutates pDb^.zNull.

    9.4.divbug.88.040+: also accept `null` as a unique prefix.  Upstream
    DbObjCmd dispatch uses Tcl_GetIndexFromObj with flags=0
    (tclsqlite.c:2479), which does unambiguous-prefix matching; `null`
    uniquely prefixes `nullvalue` in the subcommand table
    (tclsqlite.c:2448).  Tests json102/json502/upfrom4/indexexpr1/join/
    joinH all rely on `db null ?value?`. }
  if (zSub <> nil) and
     ((StrComp(zSub, 'nullvalue') = 0) or (StrComp(zSub, 'null') = 0)) then
  begin
    Result := DbNullValueArm(clientData, interp, objc, objv);
    Exit;
  end;

  { function — tclsqlite.c:3386 (DB_FUNCTION).  Scalar UDF registration
    via sqlite3_create_function_v2; Tcl trampoline is DbSqlFunc.

    9.4.divbug.64: accept the `func` prefix as well.  Upstream's
    DbObjCmd dispatch goes through Tcl_GetIndexFromObj which does
    unambiguous prefix matching; `func` is unique to `function` in the
    subcommand table (tclsqlite.c:2446..2466) so `db func ...` lands
    here too.  Several tests (tkt-d11f09d36e, update2, tkt1514, ...)
    rely on this abbreviation. }
  if (zSub <> nil) and
     ((StrComp(zSub, 'function') = 0) or (StrComp(zSub, 'func') = 0)) then
  begin
    Result := DbFunctionArm(clientData, interp, objc, objv);
    Exit;
  end;

  { format — tclsqlite.c:3368 (DB_FORMAT).  Dispatches to dbQrf
    (tclsqlite.c:2111..), which itself is gated on SQLITE_QRF_H:
    when the QRF extension is not compiled in, upstream returns
    "QRF not available in this build" with TCL_ERROR.  This Pas port
    does not include QRF, so we mirror that error verbatim — qrf03..06
    suites then skip gracefully instead of hitting "unknown subcommand".
    9.4.divbug.64. }
  if (zSub <> nil) and (StrComp(zSub, 'format') = 0) then
  begin
    Tcl_SetResult(interp, PChar('QRF not available in this build'),
                  TCL_VOLATILE);
    Result := TCL_ERROR;
    Exit;
  end;

  { trace — tclsqlite.c:3831 (DB_TRACE).  Legacy sqlite3_trace shim. }
  if (zSub <> nil) and (StrComp(zSub, 'trace') = 0) then
  begin
    Result := DbTraceArm(clientData, interp, objc, objv);
    Exit;
  end;

  { trace_v2 — tclsqlite.c:3871 (DB_TRACE_V2).  sqlite3_trace_v2 shim. }
  if (zSub <> nil) and (StrComp(zSub, 'trace_v2') = 0) then
  begin
    Result := DbTraceV2Arm(clientData, interp, objc, objv);
    Exit;
  end;

  { profile — tclsqlite.c:3620 (DB_PROFILE).  Legacy sqlite3_profile shim. }
  if (zSub <> nil) and (StrComp(zSub, 'profile') = 0) then
  begin
    Result := DbProfileArm(clientData, interp, objc, objv);
    Exit;
  end;

  { authorizer — tclsqlite.c:2503 (DB_AUTHORIZER).  sqlite3_set_authorizer
    shim.  The `auth` short form is accepted as a unique prefix (C's
    Tcl_GetIndexFromObj does prefix matching; tests in alterauth*.test
    invoke `db auth xAuth`). }
  if (zSub <> nil) and ((StrComp(zSub, 'authorizer') = 0)
                    or  (StrComp(zSub, 'auth') = 0)) then
  begin
    Result := DbAuthorizerArm(clientData, interp, objc, objv);
    Exit;
  end;

  { busy — tclsqlite.c:2641 (DB_BUSY).  sqlite3_busy_handler shim. }
  if (zSub <> nil) and (StrComp(zSub, 'busy') = 0) then
  begin
    Result := DbBusyArm(clientData, interp, objc, objv);
    Exit;
  end;

  { progress — tclsqlite.c:3574 (DB_PROGRESS).  sqlite3_progress_handler
    shim. }
  if (zSub <> nil) and (StrComp(zSub, 'progress') = 0) then
  begin
    Result := DbProgressArm(clientData, interp, objc, objv);
    Exit;
  end;

  { interrupt — tclsqlite.c:3511 (DB_INTERRUPT).  Direct passthrough. }
  if (zSub <> nil) and (StrComp(zSub, 'interrupt') = 0) then
  begin
    sqlite3_interrupt(PSqliteDb(clientData)^.db);
    Result := TCL_OK;
    Exit;
  end;

  { incrblob — tclsqlite.c:3468 (DB_INCRBLOB).  Wraps an sqlite3_blob
    handle in a custom Tcl channel. }
  if (zSub <> nil) and (StrComp(zSub, 'incrblob') = 0) then
  begin
    Result := DbIncrblobArm(clientData, interp, objc, objv);
    Exit;
  end;

  { commit_hook — tclsqlite.c:2807 (DB_COMMIT_HOOK).  sqlite3_commit_hook
    shim. }
  if (zSub <> nil) and (StrComp(zSub, 'commit_hook') = 0) then
  begin
    Result := DbCommitHookArm(clientData, interp, objc, objv);
    Exit;
  end;

  { complete — tclsqlite.c:2844 (DB_COMPLETE).  `db complete SQL` returns
    1 iff SQL parses as a complete statement (trailing `;`), 0 otherwise.
    Faithful 1:1 port of the C arm. }
  if (zSub <> nil) and (StrComp(zSub, 'complete') = 0) then
  begin
    if objc <> 3 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar('SQL'));
      Result := TCL_ERROR;
      Exit;
    end;
    Tcl_SetObjResult(interp,
      Tcl_NewBooleanObj(sqlite3_complete(
        Tcl_GetStringFromObj(ObjvAt(objv, 2), nil))));
    Result := TCL_OK;
    Exit;
  end;

  { update_hook — tclsqlite.c:4139 (DB_UPDATE_HOOK).  sqlite3_update_hook
    shim. }
  if (zSub <> nil) and (StrComp(zSub, 'update_hook') = 0) then
  begin
    Result := DbHookArm(clientData, interp, objc, objv, 1);
    Exit;
  end;

  { rollback_hook — tclsqlite.c:4140 (DB_ROLLBACK_HOOK).
    sqlite3_rollback_hook shim. }
  if (zSub <> nil) and (StrComp(zSub, 'rollback_hook') = 0) then
  begin
    Result := DbHookArm(clientData, interp, objc, objv, 2);
    Exit;
  end;

  { wal_hook — tclsqlite.c:4138 (DB_WAL_HOOK).  sqlite3_wal_hook shim. }
  if (zSub <> nil) and (StrComp(zSub, 'wal_hook') = 0) then
  begin
    Result := DbHookArm(clientData, interp, objc, objv, 0);
    Exit;
  end;

  { preupdate — tclsqlite.c:4054 (DB_PREUPDATE).  sqlite3_preupdate_*
    shim; gated on SQLITE_ENABLE_PREUPDATE_HOOK (9.4.2.u). }
  if (zSub <> nil) and (StrComp(zSub, 'preupdate') = 0) then
  begin
    Result := DbPreUpdateArm(clientData, interp, objc, objv);
    Exit;
  end;

  { unlock_notify — tclsqlite.c:4012 (DB_UNLOCK_NOTIFY).
    sqlite3_unlock_notify shim; gated on SQLITE_ENABLE_UNLOCK_NOTIFY
    (9.4.2.v). }
  if (zSub <> nil) and (StrComp(zSub, 'unlock_notify') = 0) then
  begin
    Result := DbUnlockNotifyArm(clientData, interp, objc, objv);
    Exit;
  end;

  { collate — tclsqlite.c:2754 (DB_COLLATE).  Tcl-callback collation
    registration via sqlite3_create_collation. }
  if (zSub <> nil) and (StrComp(zSub, 'collate') = 0) then
  begin
    Result := DbCollateArm(clientData, interp, objc, objv);
    Exit;
  end;

  { collation_needed — tclsqlite.c:2786 (DB_COLLATION_NEEDED).
    sqlite3_collation_needed factory-callback shim. }
  if (zSub <> nil) and (StrComp(zSub, 'collation_needed') = 0) then
  begin
    Result := DbCollationNeededArm(clientData, interp, objc, objv);
    Exit;
  end;

  { transaction — tclsqlite.c:3958 (DB_TRANSACTION).  BEGIN/COMMIT or,
    when nested, SAVEPOINT/RELEASE around a Tcl script body. }
  if (zSub <> nil) and (StrComp(zSub, 'transaction') = 0) then
  begin
    Result := DbTransactionArm(clientData, interp, objc, objv);
    Exit;
  end;

  { total_changes — tclsqlite.c:3814 (DB_TOTAL_CHANGES). }
  if (zSub <> nil) and (StrComp(zSub, 'total_changes') = 0) then
  begin
    if objc <> 2 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar(''));
      Result := TCL_ERROR;
      Exit;
    end;
    Tcl_SetObjResult(interp,
      Tcl_NewWideIntObj(sqlite3_total_changes64(PSqliteDb(clientData)^.db)));
    Result := TCL_OK;
    Exit;
  end;

  { onecolumn — tclsqlite.c:3260 (DB_ONECOLUMN). }
  if (zSub <> nil) and (StrComp(zSub, 'onecolumn') = 0) then
  begin
    Result := DbOneColumnExistsArm(clientData, interp, objc, objv, False);
    Exit;
  end;

  { one — alias of onecolumn used by the test harness. }
  if (zSub <> nil) and (StrComp(zSub, 'one') = 0) then
  begin
    Result := DbOneColumnExistsArm(clientData, interp, objc, objv, False);
    Exit;
  end;

  { exists — tclsqlite.c:3259 (DB_EXISTS). }
  if (zSub <> nil) and (StrComp(zSub, 'exists') = 0) then
  begin
    Result := DbOneColumnExistsArm(clientData, interp, objc, objv, True);
    Exit;
  end;

  { cache — tclsqlite.c:2678 (DB_CACHE).  flush / size N. }
  if (zSub <> nil) and (StrComp(zSub, 'cache') = 0) then
  begin
    Result := DbCacheArm(clientData, interp, objc, objv);
    Exit;
  end;

  { backup — tclsqlite.c:2549 (DB_BACKUP).  sqlite3_backup_* to a file. }
  if (zSub <> nil) and (StrComp(zSub, 'backup') = 0) then
  begin
    Result := DbBackupArm(clientData, interp, objc, objv);
    Exit;
  end;

  { restore — tclsqlite.c:3672 (DB_RESTORE).  sqlite3_backup_* from a file. }
  if (zSub <> nil) and (StrComp(zSub, 'restore') = 0) then
  begin
    Result := DbRestoreArm(clientData, interp, objc, objv);
    Exit;
  end;

  { serialize — tclsqlite.c:3732 (DB_SERIALIZE).  sqlite3_serialize shim. }
  if (zSub <> nil) and (StrComp(zSub, 'serialize') = 0) then
  begin
    Result := DbSerializeArm(clientData, interp, objc, objv);
    Exit;
  end;

  { deserialize — tclsqlite.c:3133 (DB_DESERIALIZE).  sqlite3_deserialize
    shim. }
  if (zSub <> nil) and (StrComp(zSub, 'deserialize') = 0) then
  begin
    Result := DbDeserializeArm(clientData, interp, objc, objv);
    Exit;
  end;

  { status — tclsqlite.c:3766 (DB_STATUS).  Return a per-statement counter
    captured for the most recent `db eval` (9.4.6.c). }
  if (zSub <> nil) and (StrComp(zSub, 'status') = 0) then
  begin
    if objc <> 3 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar('(step|sort|autoindex|vmstep)'));
      Result := TCL_ERROR;
      Exit;
    end;
    zStatOp := Tcl_GetString(ObjvAt(objv, 2));
    if StrComp(zStatOp, 'step') = 0 then
      iStatVal := PSqliteDb(clientData)^.nStep
    else if StrComp(zStatOp, 'sort') = 0 then
      iStatVal := PSqliteDb(clientData)^.nSort
    else if StrComp(zStatOp, 'autoindex') = 0 then
      iStatVal := PSqliteDb(clientData)^.nIndex
    else if StrComp(zStatOp, 'vmstep') = 0 then
      iStatVal := PSqliteDb(clientData)^.nVMStep
    else
    begin
      Tcl_AppendResult(interp,
        PChar('bad argument: should be autoindex, step, sort or vmstep'),
        Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
    Tcl_SetObjResult(interp, Tcl_NewIntObj(iStatVal));
    Result := TCL_OK;
    Exit;
  end;

  { config — tclsqlite.c:2864 (DB_CONFIG).  sqlite3_db_config passthrough. }
  if (zSub <> nil) and (StrComp(zSub, 'config') = 0) then
  begin
    Result := DbConfigArm(clientData, interp, objc, objv);
    Exit;
  end;

  { copy — tclsqlite.c:2946 (DB_COPY).  Bulk CSV/COPY-format import. }
  if (zSub <> nil) and (StrComp(zSub, 'copy') = 0) then
  begin
    Result := DbCopyArm(clientData, interp, objc, objv);
    Exit;
  end;

  { enable_load_extension — tclsqlite.c:3211 (DB_ENABLE_LOAD_EXTENSION). }
  if (zSub <> nil) and (StrComp(zSub, 'enable_load_extension') = 0) then
  begin
    if objc <> 3 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar('BOOLEAN'));
      Result := TCL_ERROR;
      Exit;
    end;
    if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, 2), @iBool) <> TCL_OK then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
    sqlite3_enable_load_extension(PSqliteDb(clientData)^.db, iBool);
    Result := TCL_OK;
    Exit;
  end;

  { timeout — tclsqlite.c:3797 (DB_TIMEOUT).  sqlite3_busy_timeout. }
  if (zSub <> nil) and (StrComp(zSub, 'timeout') = 0) then
  begin
    if objc <> 3 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar('MILLISECONDS'));
      Result := TCL_ERROR;
      Exit;
    end;
    if Tcl_GetIntFromObj(interp, ObjvAt(objv, 2), @iBool) <> TCL_OK then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
    sqlite3_busy_timeout(PSqliteDb(clientData)^.db, iBool);
    Result := TCL_OK;
    Exit;
  end;

  Tcl_AppendResult(interp,
    PChar('unknown subcommand "'),
    zSub,
    PChar('" - implemented in 9.4.2.d..o'),
    Pointer(nil));
  Result := TCL_ERROR;
end;

{ DbUseNre — port of tclsqlite.c:1884..1890.  Runtime probe of the
  linked Tcl version: NRE (Non-Recursive Eval) command dispatch is only
  available on Tcl 8.6 or newer.  Even though we link directly against
  tcl8.6, upstream tests at runtime so a stubs-enabled build can load
  against an older library; we keep the same shape for faithfulness. }
function DbUseNre: Boolean;
var
  major, minor: cint;
begin
  major := 0;
  minor := 0;
  Tcl_GetVersion(@major, @minor, nil, nil);
  Result := ((major = 8) and (minor >= 6)) or (major > 8);
end;

{ DbObjCmdNRE — port of tclsqlite.c:4206..4219 (DbObjCmdAdaptor in
  upstream naming).  Thin NRE trampoline: when the `db` command is
  registered via Tcl_NRCreateCommand, Tcl invokes this objProc, which
  immediately bounces into the real dispatcher (our DbObjCmdAdaptor,
  which plays the role of upstream DbObjCmd) through Tcl_NRCallObjProc.
  This lets script bodies scheduled with Tcl_NREvalObj unwind cleanly.

  NOTE: the per-row [db eval] / [db transaction] bodies are still
  evaluated on the direct (recursive) Tcl_EvalObjEx path inside
  DbEvalArm / DbTransactionArm — equivalent to upstream's !DbUseNre()
  branch.  Converting those to genuine Tcl_NRAddCallback continuations
  needs the DbEvalContext continuation-machinery rewrite and is left as
  a follow-up; see the report for 9.4.2.x. }
function DbObjCmdNRE(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  Result := Tcl_NRCallObjProc(interp, @DbObjCmdAdaptor,
                              clientData, objc, objv);
end;

{ DbMain — constructor for the `sqlite3 db1 FILE ?OPTIONS?` Tcl command.
  Port of tclsqlite.c:4253..4410.  9.4.divbug.57: previously hard-coded
  RW|CREATE which silently ignored `-readonly 1` / `-create 0` so
  openv2-1.1 (missing file under -create 0) and openv2-1.4 (write to
  RO open of a writable file) returned OK instead of the documented
  errors.  Now parses -readonly/-create/-vfs/-nofollow/-nomutex/
  -fullmutex/-uri and propagates sqlite3_errmsg / sqlite3_errstr in the
  failure arm.

  objv[0]="sqlite3", objv[1]=dbname (e.g. "db1"), objv[2..]=FILE+OPTIONS. }
function DbMain(clientData: TClientData; interp: PTclInterp;
                objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:      PSqliteDb;
  zDbName:  PAnsiChar;
  zFile:    PAnsiChar;
  zVfs:     PAnsiChar;
  zArg:     PAnsiChar;
  zErr:     PAnsiChar;
  rc:       cint;
  pHandle:  PTsqlite3;
  flags:    cint;
  i:        cint;
  b:        cint;
  bTranslateFileName: cint;
  ds:       TTclDString;
  zTrans:   PAnsiChar;
  dqsCfg:   i32;

  function Usage: cint;
  begin
    { Port of sqliteCmdUsage (tclsqlite.c:4225..4235). }
    Tcl_WrongNumArgs(interp, 1, objv, PChar(
      'HANDLE ?FILENAME? ?-vfs VFSNAME? ?-readonly BOOLEAN? ?-create BOOLEAN?' +
      ' ?-nofollow BOOLEAN?' +
      ' ?-nomutex BOOLEAN? ?-fullmutex BOOLEAN? ?-uri BOOLEAN?'));
    Usage := TCL_ERROR;
  end;

begin
  flags   := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_NOMUTEX;
  zFile   := nil;
  zVfs    := nil;
  bTranslateFileName := 1;

  { Port of tclsqlite.c:4282..4297 — bare `sqlite3` plus the three
    `sqlite3 -flag` introspection forms (-version / -sourceid / -has-codec)
    used by pragma3.test:19 and similar.  Without these arms divbug.57
    rejected objc<3 outright with `wrong # args`. }
  if objc = 1 then
  begin
    Result := Usage;
    Exit;
  end;
  if objc = 2 then
  begin
    zArg := Tcl_GetStringFromObj(ObjvAt(objv, 1), nil);
    if StrComp(zArg, '-version') = 0 then
    begin
      Tcl_AppendResult(interp, sqlite3_libversion(), Pointer(nil));
      Result := TCL_OK; Exit;
    end;
    if StrComp(zArg, '-sourceid') = 0 then
    begin
      Tcl_AppendResult(interp, sqlite3_sourceid(), Pointer(nil));
      Result := TCL_OK; Exit;
    end;
    if StrComp(zArg, '-has-codec') = 0 then
    begin
      Tcl_AppendResult(interp, PChar('0'), Pointer(nil));
      Result := TCL_OK; Exit;
    end;
    if (zArg <> nil) and (zArg[0] = '-') then
    begin
      Result := Usage;
      Exit;
    end;
  end;

  zDbName := Tcl_GetStringFromObj(ObjvAt(objv, 1), nil);

  { Port of tclsqlite.c:4299..4372 — parse positional FILE plus key/value
    options. }
  i := 2;
  while i < objc do
  begin
    zArg := Tcl_GetString(ObjvAt(objv, i));
    if (zArg = nil) or (zArg[0] <> '-') then
    begin
      if zFile <> nil then
      begin
        Result := Usage;
        Exit;
      end;
      zFile := zArg;
      Inc(i);
      Continue;
    end;
    if i = objc - 1 then
    begin
      Result := Usage;
      Exit;
    end;
    Inc(i);
    if StrComp(zArg, '-key') = 0 then
    begin
      { no-op — encryption not supported }
    end
    else if StrComp(zArg, '-vfs') = 0 then
      zVfs := Tcl_GetString(ObjvAt(objv, i))
    else if StrComp(zArg, '-readonly') = 0 then
    begin
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, i), @b) <> TCL_OK then
      begin Result := TCL_ERROR; Exit; end;
      if b <> 0 then
      begin
        flags := flags and not (SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
        flags := flags or SQLITE_OPEN_READONLY;
      end
      else
      begin
        flags := flags and not SQLITE_OPEN_READONLY;
        flags := flags or SQLITE_OPEN_READWRITE;
      end;
    end
    else if StrComp(zArg, '-create') = 0 then
    begin
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, i), @b) <> TCL_OK then
      begin Result := TCL_ERROR; Exit; end;
      if (b <> 0) and ((flags and SQLITE_OPEN_READONLY) = 0) then
        flags := flags or SQLITE_OPEN_CREATE
      else
        flags := flags and not SQLITE_OPEN_CREATE;
    end
    else if StrComp(zArg, '-nofollow') = 0 then
    begin
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, i), @b) <> TCL_OK then
      begin Result := TCL_ERROR; Exit; end;
      if b <> 0 then
        flags := flags or SQLITE_OPEN_NOFOLLOW
      else
        flags := flags and not SQLITE_OPEN_NOFOLLOW;
    end
    else if StrComp(zArg, '-nomutex') = 0 then
    begin
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, i), @b) <> TCL_OK then
      begin Result := TCL_ERROR; Exit; end;
      if b <> 0 then
      begin
        flags := flags or SQLITE_OPEN_NOMUTEX;
        flags := flags and not SQLITE_OPEN_FULLMUTEX;
      end
      else
        flags := flags and not SQLITE_OPEN_NOMUTEX;
    end
    else if StrComp(zArg, '-fullmutex') = 0 then
    begin
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, i), @b) <> TCL_OK then
      begin Result := TCL_ERROR; Exit; end;
      if b <> 0 then
      begin
        flags := flags or SQLITE_OPEN_FULLMUTEX;
        flags := flags and not SQLITE_OPEN_NOMUTEX;
      end
      else
        flags := flags and not SQLITE_OPEN_FULLMUTEX;
    end
    else if StrComp(zArg, '-uri') = 0 then
    begin
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, i), @b) <> TCL_OK then
      begin Result := TCL_ERROR; Exit; end;
      if b <> 0 then
        flags := flags or SQLITE_OPEN_URI
      else
        flags := flags and not SQLITE_OPEN_URI;
    end
    else if StrComp(zArg, '-translatefilename') = 0 then
    begin
      { Port of tclsqlite.c:4364..4367 — toggles Tcl_TranslateFileName below. }
      if Tcl_GetBooleanFromObj(interp, ObjvAt(objv, i), @bTranslateFileName)
         <> TCL_OK then
      begin Result := TCL_ERROR; Exit; end;
    end
    else
    begin
      Tcl_AppendResult(interp, PChar('unknown option: '), zArg, Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
    Inc(i);
  end;

  if zFile = nil then zFile := '';

  { Port of tclsqlite.c:4377..4383 — apply ~user / env-var expansion when
    -translatefilename is not explicitly disabled. }
  if bTranslateFileName <> 0 then
  begin
    Tcl_DStringInit(@ds);
    zTrans := Tcl_TranslateFileName(interp, zFile, @ds);
    if zTrans <> nil then zFile := zTrans;
  end;

  pHandle := nil;
  rc := sqlite3_open_v2(zFile, @pHandle, flags, zVfs);
  if bTranslateFileName <> 0 then
    Tcl_DStringFree(@ds);
  { 9.4.divbug.66 — wire optional ext/misc extensions that the upstream
    test suite assumes are statically linked.  Mirrors the way the .so
    flavour calls each *_init in sqlite3_extension_init / shell.c:
      * percentile / median / percentile_cont / percentile_disc
        (ext/misc/percentile.c — required by percentile.test)
      * regexp / regexpi
        (ext/misc/regexp.c — required by regexp1/regexp2.test)
    Both Init functions are idempotent and tolerate being called even
    when sqlite3_open_v2 reported a non-OK rc (no-op on nil handle). }
  if pHandle <> nil then
  begin
    sqlite3PercentileInit(pHandle);
    sqlite3RegexpInit(pHandle);
    { 9.4.divbug.91 — register the md5sum() SQL aggregate on every new
      connection.  Upstream wires this via sqlite3_auto_extension() in
      autoinstall_test_functions (test_func.c:723..726); pas-sqlite3 has
      no auto-extension table, so we call Md5_Register directly here.
      Required by backup, backup_ioerr, fuzz3, interrupt, trans2 tests. }
    Md5_Register(pHandle, nil, nil);
    { DQS=3 testfixture flavour: the upstream Tcl test harness links a
      libsqlite3 built with the amalgamation default SQLITE_DQS=3 (both
      DBCONFIG_DQS_DDL and DBCONFIG_DQS_DML on), whereas the standalone
      shell oracle is built -DSQLITE_DQS=0.  pas-sqlite3 ships a single
      library whose default is DQS=0 (to match the shell oracle for
      .dbconfig parity), so re-enable the legacy double-quoted-string
      behaviour here on every Tcl connection to mirror the testfixture
      build.  Required by indexexpr1-2100..2140 (CREATE INDEX ON t1("y")
      demotes the bare double-quoted identifier to a string literal). }
    dqsCfg := 0;
    sqlite3_db_config_int(pHandle, SQLITE_DBCONFIG_DQS_DDL, 1, @dqsCfg);
    sqlite3_db_config_int(pHandle, SQLITE_DBCONFIG_DQS_DML, 1, @dqsCfg);
  end;
  if (rc <> SQLITE_OK) or (pHandle = nil) or
     (sqlite3_errcode(pHandle) <> SQLITE_OK) then
  begin
    { Port of tclsqlite.c:4384..4397 error arm: prefer sqlite3_errmsg
      when a handle exists, else fall back to sqlite3_errstr. }
    if pHandle <> nil then
    begin
      zErr := sqlite3_errmsg(pHandle);
      Tcl_AppendResult(interp, zErr, Pointer(nil));
      sqlite3_close_v2(pHandle);
    end
    else
    begin
      zErr := sqlite3_errstr(rc);
      Tcl_AppendResult(interp, zErr, Pointer(nil));
    end;
    Result := TCL_ERROR;
    Exit;
  end;

  { New() is safe here because TSqliteDb has no managed-type fields
    (zNull is a raw PAnsiChar, not an AnsiString).  See memory
    feedback_new_record_ansistring for the trap to avoid.

    9.4.divbug.21 (residual, 2026-05-17): FPC `New()` does NOT zero the
    record, and the individual field assignments below miss several
    pointer / counter fields (pIncrblob, nStep/nSort/nIndex/nVMStep).
    On a fresh heap those happen to be zero, but after busy.test's many
    `sqlite3 db2 test.db` cycles the heap recycles dirty bytes and the
    DbDeleteCmd → CloseIncrblobChannels walker dereferences garbage —
    SIGSEGV at finish_test inside the tcl shutdown.  Stock C tclsqlite.c
    uses `Tcl_Alloc` + explicit zeroing (`memset(p,0,sizeof(*p))` at
    tclsqlite.c:4396).  Mirror that here. }
  New(pDb);
  FillChar(pDb^, SizeOf(TSqliteDb), 0);
  pDb^.db       := pHandle;
  pDb^.interp   := interp;
  { tclsqlite.c:4400 — preserve the URI bit for backup/restore arms. }
  pDb^.openFlags := flags and SQLITE_OPEN_URI;
  pDb^.zNull    := nil;
  pDb^.pFunc    := nil;
  pDb^.zTrace   := nil;
  pDb^.zTraceV2 := nil;
  pDb^.zProfile := nil;
  pDb^.zAuth    := nil;
  pDb^.zBusy        := nil;
  pDb^.zProgress    := nil;
  pDb^.zCommit      := nil;
  pDb^.pUpdateHook  := nil;
  pDb^.pRollbackHook := nil;
  pDb^.pWalHook     := nil;
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
  pDb^.pPreUpdateHook := nil;
{$ENDIF}
  pDb^.pCollate       := nil;
  pDb^.pCollateNeeded := nil;
  pDb^.nTransaction   := 0;
  pDb^.maxStmt        := NUM_PREPARED_STMTS;  { tclsqlite.c:4399 }
  { tclsqlite.c:4409 — `p->nRef = 1`.  The cmd-delete proc holds the
    initial ref; each long-lived continuation (DbEvalNextCmd /
    DbTransPostCmd) adds another via AddDatabaseRef (9.4.2.x.1.b). }
  pDb^.nRef           := 1;
  pDb^.stmtList       := nil;
  pDb^.stmtLast       := nil;
  pDb^.nStmt          := 0;

  { tclsqlite.c:4403..4408 — register the per-connection command with
    the NRE trampoline when the linked Tcl supports it, else fall back
    to the plain objCmd path.  Both register the same dispatcher
    (DbObjCmdAdaptor) and teardown proc (DbDeleteCmd). }
  if DbUseNre then
    Tcl_NRCreateCommand(interp, zDbName,
      @DbObjCmdNRE, @DbObjCmdAdaptor, TClientData(pDb), @DbDeleteCmd)
  else
    Tcl_CreateObjCommand(interp, zDbName,
      @DbObjCmdAdaptor, TClientData(pDb), @DbDeleteCmd);

  Result := TCL_OK;
end;

{ TestRegisterDbstatVtab — Tcl `register_dbstat_vtab DB`.  Pas port of
  test_register_dbstat_vtab (test1.c:8583..8609).  Resolves the named
  `db` command back to its SqliteDb* via Tcl_GetCommandInfo, then calls
  sqlite3DbstatRegister to install the eponymous `dbstat` vtab on that
  connection.  Mirrors C: a non-existent command name is silently
  ignored (Tcl_GetCommandInfo returns 0), only objc!=2 is an error. }
function TestRegisterDbstatVtab(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zDb:     PAnsiChar;
  cmdInfo: TTclCmdInfo;
  pDb:     PSqliteDb;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR;
    Exit;
  end;

  zDb := Tcl_GetString(ObjvAt(objv, 1));
  if Tcl_GetCommandInfo(interp, zDb, @cmdInfo) <> 0 then
  begin
    pDb := PSqliteDb(cmdInfo.objClientData);
    if (pDb <> nil) and (pDb^.db <> nil) then
      sqlite3DbstatRegister(pDb^.db);
  end;
  Result := TCL_OK;
end;

{ 9.4.8.d — opcode coverage Tcl hooks.

  `pas_opcode_coverage_enable` flips gVdbeOpCoverageEnabled to 1 and
  zeroes the counter array, so the child tclsh records VDBE opcode
  hits for the rest of the test.  Costs one predictable branch per
  opcode step when active and is a no-op otherwise (default 0).

  `pas_opcode_coverage_dump <path>` walks gVdbeOpCoverage[] and writes
  one `<opcode>\t<name>\t<hits>` line per index to <path>.  TclTestDriver
  aggregates the per-test dump files in --coverage mode to compute the
  union-of-hits set across the corpus, then diffs against the 9.1.6 /
  9.2 snapshot to produce src/tests/tcl/COVERAGE_DELTA.md. }
function PasOpcodeCoverageEnable(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i: i32;
begin
  if objc <> 1 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR;
    Exit;
  end;
  gVdbeOpCoverageEnabled := 1;
  for i := 0 to SQLITE_NUM_OPCODES - 1 do gVdbeOpCoverage[i] := 0;
  Result := TCL_OK;
end;

function PasOpcodeCoverageDump(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zPath: PAnsiChar;
  f: TextFile;
  i: i32;
  name: PAnsiChar;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('PATH'));
    Result := TCL_ERROR;
    Exit;
  end;
  zPath := Tcl_GetString(ObjvAt(objv, 1));
  try
    AssignFile(f, AnsiString(zPath));
    Rewrite(f);
    try
      for i := 0 to SQLITE_NUM_OPCODES - 1 do begin
        name := sqlite3OpcodeName(i);
        if name = nil then name := PAnsiChar('?');
        WriteLn(f, i, #9, AnsiString(name), #9, gVdbeOpCoverage[i]);
      end;
    finally
      CloseFile(f);
    end;
  except
    on E: Exception do begin
      Tcl_SetObjResult(interp, Tcl_NewStringObj(
        PChar('pas_opcode_coverage_dump: ' + E.Message), -1));
      Result := TCL_ERROR;
      Exit;
    end;
  end;
  Result := TCL_OK;
end;

{ 9.4.divbug.88.012..020 — `nonzero_reserved_bytes` is defined in
  upstream tester.tcl:331 as `return [sqlite3 -has-codec]`.  We don't
  ship a codec, so the answer is always 0 — but the corrupt*.test
  prologue calls this command and bails with `invalid command name`
  if it's unregistered.  Provide a trivial C-side stub that mirrors
  the no-codec result, matching what the upstream Tcl proc returns
  against a no-codec build. }
function NonzeroReservedBytes(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  if objc <> 1 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR;
    Exit;
  end;
  Tcl_SetObjResult(interp, Tcl_NewIntObj(0));
  Result := TCL_OK;
end;

{ Tcl `sqlite3_test_control_pending_byte OFFSET`.  Pas port of
  test_control_pending_byte (test1.c) which calls
  sqlite3_test_control(SQLITE_TESTCTRL_PENDING_BYTE, offset).  tester.tcl:102
  invokes this at load time with 0x0010000 so the locking page is reachable
  in small test databases.  Returns the previous pending-byte value. }
function TestControlPendingByte(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  SQLITE_TESTCTRL_PENDING_BYTE = 11;
var
  wv:  Int64;
  old: i32;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('OFFSET'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetWideIntFromObj(interp, ObjvAt(objv, 1), @wv) <> TCL_OK then begin
    Result := TCL_ERROR;
    Exit;
  end;
  old := sqlite3_test_control(SQLITE_TESTCTRL_PENDING_BYTE, i32(wv));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(cint(old)));
  Result := TCL_OK;
end;

{ Tcl `save_prng_state` / `restore_prng_state`.  Pas port of save_prng_state /
  restore_prng_state (test1.c) which call
  sqlite3_test_control(SQLITE_TESTCTRL_PRNG_SAVE) and
  sqlite3_test_control(SQLITE_TESTCTRL_PRNG_RESTORE) respectively.  Tests such
  as rowid-12.x snapshot the PRNG, replay it across inserts, and rely on the
  random-rowid guesser colliding deterministically to drive SQLITE_FULL. }
function SavePrngState(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  SQLITE_TESTCTRL_PRNG_SAVE = 5;
begin
  sqlite3_test_control(SQLITE_TESTCTRL_PRNG_SAVE);
  Result := TCL_OK;
end;

function RestorePrngState(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  SQLITE_TESTCTRL_PRNG_RESTORE = 6;
begin
  sqlite3_test_control(SQLITE_TESTCTRL_PRNG_RESTORE);
  Result := TCL_OK;
end;

function Sqlite3_Init(interp: PTclInterp): cint; cdecl;
var
  rc: cint;
begin
  Tcl_CreateObjCommand(interp, PChar('sqlite3'),
    @DbMain, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite'),
    @DbMain, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('register_dbstat_vtab'),
    @TestRegisterDbstatVtab, nil, nil);
  { tester.tcl:102 — move the locking page into reach of small test DBs. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_test_control_pending_byte'),
    @TestControlPendingByte, nil, nil);
  { rowid-12.x and friends snapshot/replay the PRNG to drive deterministic
    random-rowid collisions; tester_min.tcl only shims these as no-ops. }
  Tcl_CreateObjCommand(interp, PChar('save_prng_state'),
    @SavePrngState, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('restore_prng_state'),
    @RestorePrngState, nil, nil);
  { 9.4.divbug.88.012..020 — corrupt*.test prologue requires this. }
  Tcl_CreateObjCommand(interp, PChar('nonzero_reserved_bytes'),
    @NonzeroReservedBytes, nil, nil);
  { 9.4.8.d — opcode coverage probes (see PasOpcodeCoverage{Enable,Dump}). }
  Tcl_CreateObjCommand(interp, PChar('pas_opcode_coverage_enable'),
    @PasOpcodeCoverageEnable, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('pas_opcode_coverage_dump'),
    @PasOpcodeCoverageDump, nil, nil);
  { 9.4.6.l.3 — test_md5.c: register md5 / md5-10x8 / md5file commands. }
  Md5_Init(interp);
  { 9.4.6.l.2 — test_tclvar.c: register the `register_tclvar_module` cmd. }
  Sqlitetesttclvar_Init(interp);
  { test_bestindex.c: register the `register_tcl_module` cmd. }
  Sqlitetesttcl_Init(interp);
  { 9.4.6.l.1 — test8.c: register_echo_module / sqlite3_declare_vtab. }
  Sqlitetest8_Init(interp);
  { test_schema.c: register_schema_module (vtab2.test). }
  Sqlitetestschema_Init(interp);
  { 9.4.6.q — test1.c: sqlite3_connection_pointer / sqlite3_db_config /
    atomic_batch_write / load_static_extension. }
  Sqlitetest1_Init(interp);
  { 9.4.6.l.4 — test_func.c: autoinstall_test_functions. }
  Sqlitetestfunc_Init(interp);
  { 9.4.6.n / 9.4.7.b — test_malloc.c: the malloc fault-injection layer
    (install_malloc_faultsim, sqlite3_memdebug_fail / _pending / _settitle,
    sqlite3_malloc / _realloc / _free, sqlite3_memory_used / _highwater). }
  Sqlitetest_malloc_Init(interp);
  { 9.4.7.c — test2.c: Tcl_LinkVar the I/O-error injection counters
    (sqlite_io_error_pending / _persist / _hit / _hardhit / _benign,
    sqlite_diskfull_pending / sqlite_diskfull) driven by do_ioerr_test. }
  Sqlitetest2_Init(interp);
  { 9.4.7.d / 9.4.2.g.11 — test6.c: crash-VFS Tcl bindings
    (sqlite3_crash_enable, sqlite3_crash_now, sqlite3_crashparams)
    used by the upstream `crashsql` Tcl proc. }
  Sqlitetest6_Init(interp);
  { 9.4.divbug.88.041 + 88.054 — test_vfs.c: register the `testvfs`
    Tcl command (wrapper VFS with filter/script callbacks) used by
    interrupt2.test, mjournal.test, e_wal.test, nolock.test, etc. }
  Sqlitetestvfs_Init(interp);
  { 6.40.1.o — fts3_test.c: register fts3_near_match / fts3_configure_incr_load
    / fts3_test_tokenizer / fts3_test_varint / sqlite3_fts3_may_be_corrupt and
    Tcl_LinkVar `sqlite_fts3_enable_parentheses` (test1.c:9447..9449) so the
    gated fts3*/fts4* .test files can drive the new-syntax query path. }
  Sqlitetestfts3_Init(interp);
  { 9.4.divbug.73 — test1.c:9366..9371 Tcl_LinkVar the optimiser/B-tree
    visit counters so regression tests (rowid-4.5/.5.1, where*/in*/minmax,
    between's `queryplan`) can read them.  Without this, $sqlite_search_count
    is undefined → Tcl reads 0 → expected {4 3} comes back as {4 0}. }
  Tcl_LinkVar(interp, PChar('sqlite_search_count'),
              @sqlite3_search_count, TCL_LINK_INT);
  { test1.c:9376..9377 Tcl_LinkVar( sqlite_interrupt_count ) — test-only
    countdown decremented per VDBE op; fires sqlite3_interrupt(db) at 0.
    interrupt.test section 3 sets it to simulate an interrupt after N steps. }
  Tcl_LinkVar(interp, PChar('sqlite_interrupt_count'),
              @sqlite3_interrupt_count, TCL_LINK_INT);
  { test1.c:9372 Tcl_LinkVar( sqlite3_max_blobsize ) — watermark of the
    largest string/blob materialised on the VDBE register stack.  zeroblob.test
    reads it to prove trailing zeroblobs are never instantiated. }
  Tcl_LinkVar(interp, PChar('sqlite3_max_blobsize'),
              @sqlite3_max_blobsize, TCL_LINK_INT);
  { with2-5.x — test1.c:9386 Tcl_LinkVar `sqlite3_xferopt_count`.  Counts
    successful INSERT-from-SELECT xfer optimization invocations
    (insert.c:3235). }
  Tcl_LinkVar(interp, PChar('sqlite3_xferopt_count'),
              @sqlite3_xferopt_count, TCL_LINK_INT);
  Tcl_LinkVar(interp, PChar('sqlite_sort_count'),
              @sqlite3_sort_count, TCL_LINK_INT);
  { test1.c:9374 Tcl_LinkVar( sqlite_like_count ) — LIKE/GLOB
    invocation counter (func.c:891) for like.test 3.x / 4.x / 5.x. }
  Tcl_LinkVar(interp, PChar('sqlite_like_count'),
              @sqlite3_like_count, TCL_LINK_INT);
  { test1.c:9378 Tcl_LinkVar( sqlite_open_file_count ) — the OS-layer
    open-file-handle counter (passqlite3os.pas), read by exclusive-5.x. }
  Tcl_LinkVar(interp, PChar('sqlite_open_file_count'),
              @sqlite3_open_file_count, TCL_LINK_INT);
  { test1.c:9439..9442 Tcl_LinkVar( sqlite_sync_count / sqlite_fullsync_count )
    — fsync()/FULLFSYNC counters from unixSync (passqlite3os.pas) read by
    sync.test / sync2.test / wal2.test. }
  Tcl_LinkVar(interp, PChar('sqlite_sync_count'),
              @sqlite3_sync_count, TCL_LINK_INT);
  Tcl_LinkVar(interp, PChar('sqlite_fullsync_count'),
              @sqlite3_fullsync_count, TCL_LINK_INT);
  { test1.c:9380..9381 Tcl_LinkVar($sqlite_current_time) — when set to a
    non-zero unix-seconds value, unixCurrentTimeInt64 (os_unix.c:7211) returns
    the pinned time so date/time tests (e_createtable-3.5/3.8, etc.) are
    deterministic. }
  Tcl_LinkVar(interp, PChar('sqlite_current_time'),
              @sqlite3_current_time, TCL_LINK_INT);
  { Shard 0 fix 2 — attach4.test / attach.test / sqllimits1.test / wal.test
    read $SQLITE_MAX_ATTACHED.  Mirror the C test_config.c:827 LINKVAR
    so the Tcl side sees the same compiled-in limit.  TCL_LINK_READ_ONLY
    matches the C macro semantics. }
  cv_max_attached := SQLITE_MAX_ATTACHED;
  Tcl_LinkVar(interp, PChar('SQLITE_MAX_ATTACHED'),
              @cv_max_attached, TCL_LINK_INT or TCL_LINK_READ_ONLY);
  { test_config.c:814 LINKVAR( MAX_COMPOUND_SELECT ) — select7.test reads
    $SQLITE_MAX_COMPOUND_SELECT.  Mirror the compiled-in limit (default 500). }
  cv_max_compound_select := SQLITE_MAX_COMPOUND_SELECT;
  Tcl_LinkVar(interp, PChar('SQLITE_MAX_COMPOUND_SELECT'),
              @cv_max_compound_select, TCL_LINK_INT or TCL_LINK_READ_ONLY);
  { test_config.c:811 LINKVAR( MAX_COLUMN ).  e_createtable-3-9.x reads
    $SQLITE_MAX_COLUMN to size a "columns X" expansion. }
  cv_max_column := SQLITE_MAX_COLUMN;
  Tcl_LinkVar(interp, PChar('SQLITE_MAX_COLUMN'),
              @cv_max_column, TCL_LINK_INT or TCL_LINK_READ_ONLY);
  rc := Tcl_PkgProvide(interp, PChar('sqlite3'), PChar(SQLITE_VERSION));
  Result := rc;
end;

function Sqlite3_SafeInit(interp: PTclInterp): cint; cdecl;
begin
  Result := TCL_ERROR;
end;

end.
