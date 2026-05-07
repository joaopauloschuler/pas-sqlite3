{
  SPDX-License-Identifier: blessing

  Faithful 1:1 port of ../sqlite3/ext/misc/vtshim.c (553 lines in C).

  vtshim is a thin wrapper that sits between SQLite's virtual-table
  interface and a "child" sqlite3_module supplied by the caller, adding
  a single bit of bookkeeping: every vtab and every cursor created
  through the shim is linked into a per-aux list, and a one-shot
  `sqlite3_dispose_module` walk closes / disconnects them all in bulk
  without waiting on the SQLite teardown.  The shim flips a `bDisposed`
  flag so subsequent SQL calls return SQLITE_ERROR rather than calling
  through dangling child callbacks.  Originally written for runtimes
  with garbage-collected memory management (e.g. JavaScript-bound
  modules) where xDisconnect / xClose finalisation order is not
  guaranteed.

  Public entry points (mirroring the C source verbatim):

    function sqlite3_create_disposable_module(db, zName, p, pClientData,
                                              xDestroy): Pointer; cdecl;
    procedure sqlite3_dispose_module(pX: Pointer); cdecl;

  No auto-registration: callers wire the shim explicitly.
}
{$I passqlite3.inc}
unit passqlite3vtshim;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3printf,
  passqlite3main;

{ vtshim.c:457..516 — install a disposable shim module on db.  Returns
  an opaque vtshim_aux handle (which `sqlite3_dispose_module` consumes)
  or nil on failure. }
function sqlite3_create_disposable_module(db: PTsqlite3; zName: PAnsiChar;
  p: PSqlite3Module; pClientData: Pointer;
  xDestroy: TxModuleDestroy): Pointer; cdecl;

{ vtshim.c:521..538 — close every vtab and cursor that this shim owns. }
procedure sqlite3_dispose_module(pX: Pointer); cdecl;

implementation

type
  PPSqlite3Module = ^PSqlite3Module;
  PVtshimAux    = ^TVtshimAux;
  PVtshimVtab   = ^TVtshimVtab;
  PPVtshimVtab  = ^PVtshimVtab;
  PVtshimCursor = ^TVtshimCursor;
  PPVtshimCursor= ^PVtshimCursor;

  { vtshim.c:32..41 — auxiliary parameter handed back from
    sqlite3_create_module_v2(). }
  TVtshimAux = record
    pChildAux     : Pointer;          { pAux for child virtual tables }
    xChildDestroy : TxModuleDestroy;  { Destructor for pChildAux }
    pMod          : PSqlite3Module;   { Methods for child virtual tables }
    db            : PTsqlite3;        { The database to which we are attached }
    zName         : PAnsiChar;        { Name of the module }
    bDisposed     : i32;              { True if disposed }
    pAllVtab      : PVtshimVtab;      { List of all vtshim_vtab objects }
    sSelf         : Tsqlite3_module;  { Methods used by this shim }
  end;

  { vtshim.c:44..51 — vtab object. base must be first. }
  TVtshimVtab = record
    base    : Tsqlite3_vtab;
    pChild  : PSqlite3Vtab;
    pAux    : PVtshimAux;
    pAllCur : PVtshimCursor;
    ppPrev  : PPVtshimVtab;
    pNext   : PVtshimVtab;
  end;

  { vtshim.c:54..59 — cursor object. base must be first. }
  TVtshimCursor = record
    base    : Tsqlite3_vtab_cursor;
    pChild  : PSqlite3VtabCursor;
    ppPrev  : PPVtshimCursor;
    pNext   : PVtshimCursor;
  end;

  { Function-pointer typedefs for casting child sqlite3_module slots
    (which are declared as `Pointer` on the Pascal side). }
  TFnCreate     = function(db: PTsqlite3; pAux: Pointer;
                           argc: i32; argv: PPAnsiChar;
                           ppVtab: PPSqlite3Vtab;
                           pzErr: PPAnsiChar): i32; cdecl;
  TFnConnect    = TFnCreate;
  TFnBestIndex  = function(p: PSqlite3Vtab; pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
  TFnDisconnect = function(p: PSqlite3Vtab): i32; cdecl;
  TFnDestroy    = TFnDisconnect;
  TFnOpen       = function(p: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): i32; cdecl;
  TFnClose      = function(c: PSqlite3VtabCursor): i32; cdecl;
  TFnFilter     = function(c: PSqlite3VtabCursor; idxNum: i32; idxStr: PAnsiChar;
                           argc: i32; argv: PPsqlite3_value): i32; cdecl;
  TFnNext       = TFnClose;
  TFnEof        = TFnClose;
  TFnColumn     = function(c: PSqlite3VtabCursor; ctx: Psqlite3_context; i: i32): i32; cdecl;
  TFnRowid      = function(c: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
  TFnUpdate     = function(p: PSqlite3Vtab; argc: i32; argv: PPsqlite3_value;
                           pRowid: Pi64): i32; cdecl;
  TFnXact       = TFnDisconnect;
  TFnFindFn     = function(p: PSqlite3Vtab; nArg: i32; zName: PAnsiChar;
                           pxFunc: PPointer; ppArg: PPointer): i32; cdecl;
  TFnRename     = function(p: PSqlite3Vtab; zNewName: PAnsiChar): i32; cdecl;
  TFnSavept     = function(p: PSqlite3Vtab; n: i32): i32; cdecl;

{ vtshim.c:62..66 — VTSHIM_COPY_ERRMSG: clone child errmsg into outer vtab. }
procedure vtshimCopyErrmsg(pVtab: PVtshimVtab); inline;
begin
  sqlite3_free(pVtab^.base.zErrMsg);
  if (pVtab^.pChild <> nil) and (pVtab^.pChild^.zErrMsg <> nil) then
    pVtab^.base.zErrMsg := sqlite3PfMprintf('%s', [pVtab^.pChild^.zErrMsg])
  else
    pVtab^.base.zErrMsg := nil;
end;

{ Allocate-and-zero shorthand. }
function vtshimZalloc(n: PtrUInt): Pointer; inline;
begin
  Result := sqlite3Malloc(i32(n));
  if Result <> nil then FillChar(Result^, n, 0);
end;

{ vtshim.c:69..106 — xCreate. }
function vtshimCreate(db: PTsqlite3; ppAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pAux : PVtshimAux;
  pNew : PVtshimVtab;
  rc   : i32;
begin
  pAux := PVtshimAux(ppAux);
  if pAux^.bDisposed <> 0 then begin
    if pzErr <> nil then
      pzErr^ := sqlite3PfMprintf('virtual table was disposed: "%s"', [pAux^.zName]);
    Result := SQLITE_ERROR; Exit;
  end;
  pNew := PVtshimVtab(vtshimZalloc(SizeOf(TVtshimVtab)));
  ppVtab^ := PSqlite3Vtab(pNew);
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  rc := TFnCreate(pAux^.pMod^.xCreate)(db, pAux^.pChildAux, argc, argv,
                                       @pNew^.pChild, pzErr);
  if rc <> 0 then begin
    sqlite3_free(pNew);
    ppVtab^ := nil;
    Result := rc; Exit;
  end;
  pNew^.pAux := pAux;
  pNew^.ppPrev := @pAux^.pAllVtab;
  pNew^.pNext := pAux^.pAllVtab;
  if pAux^.pAllVtab <> nil then pAux^.pAllVtab^.ppPrev := @pNew^.pNext;
  pAux^.pAllVtab := pNew;
  Result := rc;
end;

{ vtshim.c:108..145 — xConnect. }
function vtshimConnect(db: PTsqlite3; ppAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pAux : PVtshimAux;
  pNew : PVtshimVtab;
  rc   : i32;
begin
  pAux := PVtshimAux(ppAux);
  if pAux^.bDisposed <> 0 then begin
    if pzErr <> nil then
      pzErr^ := sqlite3PfMprintf('virtual table was disposed: "%s"', [pAux^.zName]);
    Result := SQLITE_ERROR; Exit;
  end;
  pNew := PVtshimVtab(vtshimZalloc(SizeOf(TVtshimVtab)));
  ppVtab^ := PSqlite3Vtab(pNew);
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  rc := TFnConnect(pAux^.pMod^.xConnect)(db, pAux^.pChildAux, argc, argv,
                                         @pNew^.pChild, pzErr);
  if rc <> 0 then begin
    sqlite3_free(pNew);
    ppVtab^ := nil;
    Result := rc; Exit;
  end;
  pNew^.pAux := pAux;
  pNew^.ppPrev := @pAux^.pAllVtab;
  pNew^.pNext := pAux^.pAllVtab;
  if pAux^.pAllVtab <> nil then pAux^.pAllVtab^.ppPrev := @pNew^.pNext;
  pAux^.pAllVtab := pNew;
  Result := rc;
end;

{ vtshim.c:147..160 — xBestIndex. }
function vtshimBestIndex(pBase: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnBestIndex(pAux^.pMod^.xBestIndex)(pVtab^.pChild, pIdxInfo);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:162..173 — xDisconnect. }
function vtshimDisconnect(pBase: PSqlite3Vtab): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  rc := SQLITE_OK;
  if pAux^.bDisposed = 0 then
    rc := pAux^.pMod^.xDisconnect(pVtab^.pChild);
  if pVtab^.pNext <> nil then pVtab^.pNext^.ppPrev := pVtab^.ppPrev;
  pVtab^.ppPrev^ := pVtab^.pNext;
  sqlite3_free(pVtab);
  Result := rc;
end;

{ vtshim.c:175..186 — xDestroy. }
function vtshimDestroy(pBase: PSqlite3Vtab): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  rc := SQLITE_OK;
  if pAux^.bDisposed = 0 then
    rc := pAux^.pMod^.xDestroy(pVtab^.pChild);
  if pVtab^.pNext <> nil then pVtab^.pNext^.ppPrev := pVtab^.ppPrev;
  pVtab^.ppPrev^ := pVtab^.pNext;
  sqlite3_free(pVtab);
  Result := rc;
end;

{ vtshim.c:188..211 — xOpen. }
function vtshimOpen(pBase: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  pCur : PVtshimCursor;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  ppCursor^ := nil;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  pCur := PVtshimCursor(vtshimZalloc(SizeOf(TVtshimCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  rc := TFnOpen(pAux^.pMod^.xOpen)(pVtab^.pChild, @pCur^.pChild);
  if rc <> 0 then begin
    sqlite3_free(pCur);
    vtshimCopyErrmsg(pVtab);
    Result := rc; Exit;
  end;
  pCur^.pChild^.pVtab := pVtab^.pChild;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  pCur^.ppPrev := @pVtab^.pAllCur;
  if pVtab^.pAllCur <> nil then pVtab^.pAllCur^.ppPrev := @pCur^.pNext;
  pCur^.pNext := pVtab^.pAllCur;
  pVtab^.pAllCur := pCur;
  Result := SQLITE_OK;
end;

{ vtshim.c:213..228 — xClose. }
function vtshimClose(pX: PSqlite3VtabCursor): i32; cdecl;
var
  pCur : PVtshimCursor;
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pCur := PVtshimCursor(pX);
  pVtab := PVtshimVtab(pCur^.base.pVtab);
  pAux := pVtab^.pAux;
  rc := SQLITE_OK;
  if pAux^.bDisposed = 0 then begin
    rc := TFnClose(pAux^.pMod^.xClose)(pCur^.pChild);
    if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  end;
  if pCur^.pNext <> nil then pCur^.pNext^.ppPrev := pCur^.ppPrev;
  pCur^.ppPrev^ := pCur^.pNext;
  sqlite3_free(pCur);
  Result := rc;
end;

{ vtshim.c:230..247 — xFilter. }
function vtshimFilter(pX: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur : PVtshimCursor;
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pCur := PVtshimCursor(pX);
  pVtab := PVtshimVtab(pCur^.base.pVtab);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnFilter(pAux^.pMod^.xFilter)(pCur^.pChild, idxNum, idxStr, argc, argv);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:249..260 — xNext. }
function vtshimNext(pX: PSqlite3VtabCursor): i32; cdecl;
var
  pCur : PVtshimCursor;
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pCur := PVtshimCursor(pX);
  pVtab := PVtshimVtab(pCur^.base.pVtab);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnNext(pAux^.pMod^.xNext)(pCur^.pChild);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:262..271 — xEof. }
function vtshimEof(pX: PSqlite3VtabCursor): i32; cdecl;
var
  pCur : PVtshimCursor;
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pCur := PVtshimCursor(pX);
  pVtab := PVtshimVtab(pCur^.base.pVtab);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := 1; Exit; end;
  rc := TFnEof(pAux^.pMod^.xEof)(pCur^.pChild);
  vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:273..284 — xColumn. }
function vtshimColumn(pX: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur : PVtshimCursor;
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pCur := PVtshimCursor(pX);
  pVtab := PVtshimVtab(pCur^.base.pVtab);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnColumn(pAux^.pMod^.xColumn)(pCur^.pChild, ctx, i);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:286..297 — xRowid. }
function vtshimRowid(pX: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var
  pCur : PVtshimCursor;
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pCur := PVtshimCursor(pX);
  pVtab := PVtshimVtab(pCur^.base.pVtab);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnRowid(pAux^.pMod^.xRowid)(pCur^.pChild, pRowid);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:299..314 — xUpdate. }
function vtshimUpdate(pBase: PSqlite3Vtab;
  argc: i32; argv: PPsqlite3_value; pRowid: Pi64): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnUpdate(pAux^.pMod^.xUpdate)(pVtab^.pChild, argc, argv, pRowid);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:316..326 — xBegin. }
function vtshimBegin(pBase: PSqlite3Vtab): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnXact(pAux^.pMod^.xBegin)(pVtab^.pChild);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:328..338 — xSync. }
function vtshimSync(pBase: PSqlite3Vtab): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnXact(pAux^.pMod^.xSync)(pVtab^.pChild);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:340..350 — xCommit. }
function vtshimCommit(pBase: PSqlite3Vtab): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnXact(pAux^.pMod^.xCommit)(pVtab^.pChild);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:352..362 — xRollback. }
function vtshimRollback(pBase: PSqlite3Vtab): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnXact(pAux^.pMod^.xRollback)(pVtab^.pChild);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:364..378 — xFindFunction. }
function vtshimFindFunction(pBase: PSqlite3Vtab; nArg: i32; zName: PAnsiChar;
  pxFunc: PPointer; ppArg: PPointer): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := 0; Exit; end;
  rc := TFnFindFn(pAux^.pMod^.xFindFunction)(pVtab^.pChild, nArg, zName, pxFunc, ppArg);
  vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:380..390 — xRename. }
function vtshimRename(pBase: PSqlite3Vtab; zNewName: PAnsiChar): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnRename(pAux^.pMod^.xRename)(pVtab^.pChild, zNewName);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:392..402 — xSavepoint. }
function vtshimSavepoint(pBase: PSqlite3Vtab; n: i32): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnSavept(pAux^.pMod^.xSavepoint)(pVtab^.pChild, n);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:404..414 — xRelease. }
function vtshimRelease(pBase: PSqlite3Vtab; n: i32): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnSavept(pAux^.pMod^.xRelease)(pVtab^.pChild, n);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:416..426 — xRollbackTo. }
function vtshimRollbackTo(pBase: PSqlite3Vtab; n: i32): i32; cdecl;
var
  pVtab: PVtshimVtab;
  pAux : PVtshimAux;
  rc   : i32;
begin
  pVtab := PVtshimVtab(pBase);
  pAux := pVtab^.pAux;
  if pAux^.bDisposed <> 0 then begin Result := SQLITE_ERROR; Exit; end;
  rc := TFnSavept(pAux^.pMod^.xRollbackTo)(pVtab^.pChild, n);
  if rc <> SQLITE_OK then vtshimCopyErrmsg(pVtab);
  Result := rc;
end;

{ vtshim.c:428..439 — destructor handed to sqlite3_create_module_v2. }
procedure vtshimAuxDestructor(pXAux: Pointer); cdecl;
var pAux: PVtshimAux;
begin
  pAux := PVtshimAux(pXAux);
  Assert(pAux^.pAllVtab = nil);
  if (pAux^.bDisposed = 0) and Assigned(pAux^.xChildDestroy) then begin
    pAux^.xChildDestroy(pAux^.pChildAux);
    pAux^.xChildDestroy := nil;
  end;
  sqlite3_free(pAux^.zName);
  sqlite3_free(pAux^.pMod);
  sqlite3_free(pAux);
end;

{ vtshim.c:441..452 — clone the caller's sqlite3_module into shim-owned
  memory so the shim keeps a stable pointer for child dispatch. }
function vtshimCopyModule(pMod: PSqlite3Module;
  ppMod: PPSqlite3Module): i32;
var p: PSqlite3Module;
begin
  if (pMod = nil) or (ppMod = nil) then begin Result := SQLITE_ERROR; Exit; end;
  p := PSqlite3Module(sqlite3Malloc(SizeOf(Tsqlite3_module)));
  if p = nil then begin Result := SQLITE_NOMEM; Exit; end;
  Move(pMod^, p^, SizeOf(Tsqlite3_module));
  ppMod^ := p;
  Result := SQLITE_OK;
end;

{ vtshim.c:457..516 — public entry. }
function sqlite3_create_disposable_module(db: PTsqlite3; zName: PAnsiChar;
  p: PSqlite3Module; pClientData: Pointer;
  xDestroy: TxModuleDestroy): Pointer; cdecl;
var
  pAux : PVtshimAux;
  pMod : PSqlite3Module;
  rc   : i32;
begin
  pAux := PVtshimAux(sqlite3Malloc(SizeOf(TVtshimAux)));
  if pAux = nil then begin
    if Assigned(xDestroy) then xDestroy(pClientData);
    Result := nil; Exit;
  end;
  FillChar(pAux^, SizeOf(TVtshimAux), 0);
  rc := vtshimCopyModule(p, @pMod);
  if rc <> SQLITE_OK then begin
    sqlite3_free(pAux);
    Result := nil; Exit;
  end;
  pAux^.pChildAux := pClientData;
  pAux^.xChildDestroy := xDestroy;
  pAux^.pMod := pMod;
  pAux^.db := db;
  pAux^.zName := sqlite3PfMprintf('%s', [zName]);
  pAux^.bDisposed := 0;
  pAux^.pAllVtab := nil;

  if p^.iVersion <= 2 then
    pAux^.sSelf.iVersion := p^.iVersion
  else
    pAux^.sSelf.iVersion := 2;

  if p^.xCreate     <> nil then pAux^.sSelf.xCreate     := @vtshimCreate     else pAux^.sSelf.xCreate     := nil;
  if p^.xConnect    <> nil then pAux^.sSelf.xConnect    := @vtshimConnect    else pAux^.sSelf.xConnect    := nil;
  if p^.xBestIndex  <> nil then pAux^.sSelf.xBestIndex  := @vtshimBestIndex  else pAux^.sSelf.xBestIndex  := nil;
  if Assigned(p^.xDisconnect) then pAux^.sSelf.xDisconnect := @vtshimDisconnect else pAux^.sSelf.xDisconnect := nil;
  if Assigned(p^.xDestroy)    then pAux^.sSelf.xDestroy    := @vtshimDestroy    else pAux^.sSelf.xDestroy    := nil;
  if p^.xOpen       <> nil then pAux^.sSelf.xOpen       := @vtshimOpen       else pAux^.sSelf.xOpen       := nil;
  if p^.xClose      <> nil then pAux^.sSelf.xClose      := @vtshimClose      else pAux^.sSelf.xClose      := nil;
  if p^.xFilter     <> nil then pAux^.sSelf.xFilter     := @vtshimFilter     else pAux^.sSelf.xFilter     := nil;
  if p^.xNext       <> nil then pAux^.sSelf.xNext       := @vtshimNext       else pAux^.sSelf.xNext       := nil;
  if p^.xEof        <> nil then pAux^.sSelf.xEof        := @vtshimEof        else pAux^.sSelf.xEof        := nil;
  if p^.xColumn     <> nil then pAux^.sSelf.xColumn     := @vtshimColumn     else pAux^.sSelf.xColumn     := nil;
  if p^.xRowid      <> nil then pAux^.sSelf.xRowid      := @vtshimRowid      else pAux^.sSelf.xRowid      := nil;
  if p^.xUpdate     <> nil then pAux^.sSelf.xUpdate     := @vtshimUpdate     else pAux^.sSelf.xUpdate     := nil;
  if p^.xBegin      <> nil then pAux^.sSelf.xBegin      := @vtshimBegin      else pAux^.sSelf.xBegin      := nil;
  if p^.xSync       <> nil then pAux^.sSelf.xSync       := @vtshimSync       else pAux^.sSelf.xSync       := nil;
  if p^.xCommit     <> nil then pAux^.sSelf.xCommit     := @vtshimCommit     else pAux^.sSelf.xCommit     := nil;
  if p^.xRollback   <> nil then pAux^.sSelf.xRollback   := @vtshimRollback   else pAux^.sSelf.xRollback   := nil;
  if p^.xFindFunction <> nil then pAux^.sSelf.xFindFunction := @vtshimFindFunction else pAux^.sSelf.xFindFunction := nil;
  if p^.xRename     <> nil then pAux^.sSelf.xRename     := @vtshimRename     else pAux^.sSelf.xRename     := nil;
  if p^.iVersion >= 2 then begin
    if p^.xSavepoint  <> nil then pAux^.sSelf.xSavepoint  := @vtshimSavepoint  else pAux^.sSelf.xSavepoint  := nil;
    if p^.xRelease    <> nil then pAux^.sSelf.xRelease    := @vtshimRelease    else pAux^.sSelf.xRelease    := nil;
    if p^.xRollbackTo <> nil then pAux^.sSelf.xRollbackTo := @vtshimRollbackTo else pAux^.sSelf.xRollbackTo := nil;
  end else begin
    pAux^.sSelf.xSavepoint  := nil;
    pAux^.sSelf.xRelease    := nil;
    pAux^.sSelf.xRollbackTo := nil;
  end;

  rc := sqlite3_create_module_v2(db, zName, @pAux^.sSelf, pAux,
                                 @vtshimAuxDestructor);
  if rc = SQLITE_OK then
    Result := Pointer(pAux)
  else
    Result := nil;
end;

{ vtshim.c:521..538 — close every cursor and disconnect every vtab the
  shim owns, then flip bDisposed so subsequent SQL routes return error. }
procedure sqlite3_dispose_module(pX: Pointer); cdecl;
var
  pAux : PVtshimAux;
  pVtab: PVtshimVtab;
  pCur : PVtshimCursor;
begin
  pAux := PVtshimAux(pX);
  if pAux^.bDisposed = 0 then begin
    pVtab := pAux^.pAllVtab;
    while pVtab <> nil do begin
      pCur := pVtab^.pAllCur;
      while pCur <> nil do begin
        TFnClose(pAux^.pMod^.xClose)(pCur^.pChild);
        pCur := pCur^.pNext;
      end;
      pAux^.pMod^.xDisconnect(pVtab^.pChild);
      pVtab := pVtab^.pNext;
    end;
    pAux^.bDisposed := 1;
    if Assigned(pAux^.xChildDestroy) then begin
      pAux^.xChildDestroy(pAux^.pChildAux);
      pAux^.xChildDestroy := nil;
    end;
  end;
end;

end.
