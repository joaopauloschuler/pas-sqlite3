{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/src/test_intarray.c (391 lines in C) and its
  header test_intarray.h.

  Implements a read-only eponymous-ish virtual table module "intarray" whose
  content is a C-language array of 64-bit integers, plus the C API
  sqlite3_intarray_create / sqlite3_intarray_bind, plus the SQLITE_TEST Tcl
  test commands sqlite3_intarray_create / sqlite3_intarray_bind.

  Public entry: Sqlitetestintarray_Init(interp) — registers the two Tcl
  commands (intarray.test).
}
{$I passqlite3.inc}
unit TestModuleIntarray;

interface

uses
  ctypes,
  strings,
  sysutils,
  PasTclBridge,
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function Sqlitetestintarray_Init(interp: PTclInterp): cint; cdecl;

implementation

type
  PPSqlite3Vtab       = ^PSqlite3Vtab;
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { test_intarray.c:34..38 — struct sqlite3_intarray (opaque object). }
  PSqlite3Intarray = ^TSqlite3Intarray;
  TSqlite3Intarray = record
    n     : cint;        { Number of elements in the array }
    a     : Pi64;        { Contents of the array }
    xFree : TxDelProc;   { Function used to free a[] }
  end;
  PPSqlite3Intarray = ^PSqlite3Intarray;

  { test_intarray.c:45..48 — struct intarray_vtab. }
  PIntarrayVtab = ^TIntarrayVtab;
  TIntarrayVtab = record
    base     : Tsqlite3_vtab;     { Base class }
    pContent : PSqlite3Intarray;  { Content of the integer array }
  end;

  { test_intarray.c:51..54 — struct intarray_cursor. }
  PIntarrayCursor = ^TIntarrayCursor;
  TIntarrayCursor = record
    base : Tsqlite3_vtab_cursor;  { Base class }
    i    : cint;                  { Current cursor position }
  end;

var
  intarrayModule: Tsqlite3_module;

{ test_intarray.c:64..70 — intarrayFree.  Free an sqlite3_intarray object. }
procedure intarrayFree(pX: Pointer); cdecl;
var
  p: PSqlite3Intarray;
begin
  p := PSqlite3Intarray(pX);
  if p^.xFree <> nil then
    p^.xFree(p^.a);
  sqlite3_free(p);
end;

{ test_intarray.c:75..79 — intarrayDestroy.  Table destructor. }
function intarrayDestroy(p: PSqlite3Vtab): cint; cdecl;
var
  pVtab: PIntarrayVtab;
begin
  pVtab := PIntarrayVtab(p);
  sqlite3_free(pVtab);
  Result := 0;
end;

{ test_intarray.c:84..102 — intarrayCreate.  Table constructor (also xConnect). }
function intarrayCreate(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
var
  rc    : cint;
  pVtab : PIntarrayVtab;
begin
  rc := SQLITE_NOMEM;
  pVtab := PIntarrayVtab(sqlite3_malloc64(SizeOf(TIntarrayVtab)));

  if pVtab <> nil then
  begin
    FillChar(pVtab^, SizeOf(TIntarrayVtab), 0);
    pVtab^.pContent := PSqlite3Intarray(pAux);
    rc := sqlite3_declare_vtab(db, PChar('CREATE TABLE x(value INTEGER PRIMARY KEY)'));
  end;
  ppVtab^ := PSqlite3Vtab(pVtab);
  Result := rc;
end;

{ test_intarray.c:107..117 — intarrayOpen.  Open a new cursor. }
function intarrayOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): cint; cdecl;
var
  rc   : cint;
  pCur : PIntarrayCursor;
begin
  rc := SQLITE_NOMEM;
  pCur := PIntarrayCursor(sqlite3_malloc64(SizeOf(TIntarrayCursor)));
  if pCur <> nil then
  begin
    FillChar(pCur^, SizeOf(TIntarrayCursor), 0);
    ppCursor^ := PSqlite3VtabCursor(pCur);
    rc := SQLITE_OK;
  end;
  Result := rc;
end;

{ test_intarray.c:122..126 — intarrayClose.  Close a cursor. }
function intarrayClose(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: PIntarrayCursor;
begin
  pCur := PIntarrayCursor(cur);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ test_intarray.c:131..138 — intarrayColumn.  Retrieve a column of data. }
function intarrayColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: cint): cint; cdecl;
var
  pCur  : PIntarrayCursor;
  pVtab : PIntarrayVtab;
  pa    : Pi64;
begin
  pCur := PIntarrayCursor(cur);
  pVtab := PIntarrayVtab(cur^.pVtab);
  if (pCur^.i >= 0) and (pCur^.i < pVtab^.pContent^.n) then
  begin
    pa := pVtab^.pContent^.a;
    sqlite3_result_int64(ctx, pa[pCur^.i]);
  end;
  Result := SQLITE_OK;
end;

{ test_intarray.c:143..147 — intarrayRowid.  Retrieve the current rowid. }
function intarrayRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): cint; cdecl;
var
  pCur: PIntarrayCursor;
begin
  pCur := PIntarrayCursor(cur);
  pRowid^ := pCur^.i;
  Result := SQLITE_OK;
end;

{ test_intarray.c:149..153 — intarrayEof. }
function intarrayEof(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur  : PIntarrayCursor;
  pVtab : PIntarrayVtab;
begin
  pCur := PIntarrayCursor(cur);
  pVtab := PIntarrayVtab(cur^.pVtab);
  if pCur^.i >= pVtab^.pContent^.n then Result := 1 else Result := 0;
end;

{ test_intarray.c:158..162 — intarrayNext.  Advance the cursor. }
function intarrayNext(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: PIntarrayCursor;
begin
  pCur := PIntarrayCursor(cur);
  Inc(pCur^.i);
  Result := SQLITE_OK;
end;

{ test_intarray.c:167..175 — intarrayFilter.  Reset the cursor. }
function intarrayFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PAnsiChar;
  argc: cint; argv: PPsqlite3_value): cint; cdecl;
var
  pCur: PIntarrayCursor;
begin
  pCur := PIntarrayCursor(pVtabCursor);
  pCur^.i := 0;
  Result := SQLITE_OK;
end;

{ test_intarray.c:180..182 — intarrayBestIndex.  Analyse the WHERE condition. }
function intarrayBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): cint; cdecl;
begin
  Result := SQLITE_OK;
end;

{ test_intarray.c:229..254 — sqlite3_intarray_create.
  Create a specific instance of an intarray object as a TEMP virtual table. }
function sqlite3_intarray_create(db: PTsqlite3; zName: PAnsiChar;
  ppReturn: PPSqlite3Intarray): cint;
var
  rc   : cint;
  p    : PSqlite3Intarray;
  zSql : PAnsiChar;
begin
  rc := SQLITE_OK;
  p := PSqlite3Intarray(sqlite3_malloc64(SizeOf(TSqlite3Intarray)));
  ppReturn^ := p;
  if p = nil then
  begin
    Result := SQLITE_NOMEM;
    Exit;
  end;
  FillChar(p^, SizeOf(TSqlite3Intarray), 0);
  rc := sqlite3_create_module_v2(db, zName, @intarrayModule, p, @intarrayFree);
  if rc = SQLITE_OK then
  begin
    zSql := sqlite3PfMprintf('CREATE VIRTUAL TABLE temp.%Q USING %Q',
      [zName, zName]);
    rc := sqlite3_exec(db, zSql, nil, nil, nil);
    sqlite3_free(zSql);
  end;
  Result := rc;
end;

{ test_intarray.c:263..276 — sqlite3_intarray_bind.
  Bind a new array of integers to a specific intarray object. }
function sqlite3_intarray_bind(pIntArray: PSqlite3Intarray;
  nElements: cint; aElements: Pi64; xFree: TxDelProc): cint;
begin
  if pIntArray^.xFree <> nil then
    pIntArray^.xFree(pIntArray^.a);
  pIntArray^.n := nElements;
  pIntArray^.a := aElements;
  pIntArray^.xFree := xFree;
  Result := SQLITE_OK;
end;

{ ============================================================
  Tcl test commands (test_intarray.c #ifdef SQLITE_TEST)
  ============================================================ }

{ main.c:1533 — sqlite3ErrName (compact subset for the rc values
  sqlite3_intarray_create / _bind can return through these commands). }
function intarrayErrName(rc: cint): PAnsiChar;
begin
  case (rc and $ff) of
    SQLITE_OK:       Result := PChar('SQLITE_OK');
    SQLITE_ERROR:    Result := PChar('SQLITE_ERROR');
    SQLITE_NOMEM:    Result := PChar('SQLITE_NOMEM');
    SQLITE_MISUSE:   Result := PChar('SQLITE_MISUSE');
    SQLITE_BUSY:     Result := PChar('SQLITE_BUSY');
    SQLITE_LOCKED:   Result := PChar('SQLITE_LOCKED');
    SQLITE_CONSTRAINT: Result := PChar('SQLITE_CONSTRAINT');
  else
    Result := PChar('SQLITE_ERROR');
  end;
end;

{ getDbPointer — recover the sqlite3* behind a `db` Tcl command, or decode a
  hex "%p" string.  Mirrors TestModuleEcho/test1.c getDbPointer. }
function getDbPointer(interp: PTclInterp; zA: PAnsiChar;
  ppDb: PPTsqlite3): cint;
var
  cmdInfo : TTclCmdInfo;
  z       : PAnsiChar;
  v       : QWord;
  c       : cint;
begin
  if Tcl_GetCommandInfo(interp, PChar(zA), @cmdInfo) <> 0 then
    ppDb^ := PPTsqlite3(cmdInfo.objClientData)^
  else
  begin
    z := zA;
    if (z <> nil) and (z[0] = '0') and (z[1] = 'x') then
      Inc(z, 2);
    v := 0;
    while (z <> nil) and (z^ <> #0) do
    begin
      c := Ord(z^);
      if (c >= Ord('0')) and (c <= Ord('9')) then
        v := (v shl 4) + QWord(c - Ord('0'))
      else if (c >= Ord('a')) and (c <= Ord('f')) then
        v := (v shl 4) + QWord(c - Ord('a') + 10)
      else if (c >= Ord('A')) and (c <= Ord('F')) then
        v := (v shl 4) + QWord(c - Ord('A') + 10)
      else
        Break;
      Inc(z);
    end;
    ppDb^ := PTsqlite3(PtrUInt(v));
  end;
  Result := TCL_OK;
end;

{ test1.c:57..76 — sqlite3TestTextToPtr.  Decode a "%p" hex string. }
function intarrayTextToPtr(z: PAnsiChar): Pointer;
var
  v : QWord;
  c : cint;
begin
  if (z[0] = '0') and (z[1] = 'x') then
    Inc(z, 2);
  v := 0;
  while z^ <> #0 do
  begin
    c := Ord(z^);
    if (c >= Ord('0')) and (c <= Ord('9')) then
      v := (v shl 4) + QWord(c - Ord('0'))
    else if (c >= Ord('a')) and (c <= Ord('f')) then
      v := (v shl 4) + QWord(c - Ord('a') + 10)
    else if (c >= Ord('A')) and (c <= Ord('F')) then
      v := (v shl 4) + QWord(c - Ord('A') + 10)
    else
      Break;
    Inc(z);
  end;
  Result := Pointer(PtrUInt(v));
end;

{ test_intarray.c:299..327 — test_intarray_create.
  Usage: sqlite3_intarray_create DB NAME }
function test_intarray_create(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db     : PTsqlite3;
  zName  : PAnsiChar;
  pArray : PSqlite3Intarray;
  rc     : cint;
  zPtr   : AnsiString;
begin
  rc := SQLITE_OK;
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  zName := Tcl_GetString(objv[2]);
  pArray := nil;
  rc := sqlite3_intarray_create(db, zName, @pArray);
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, intarrayErrName(rc), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  { sqlite3TestMakePointerStr — SQLite's %p renders bare lowercase hex. }
  zPtr := LowerCase(IntToHex(PtrUInt(pArray), 1));
  Tcl_AppendResult(interp, PChar(zPtr), Pointer(nil));
  Result := TCL_OK;
end;

{ test_intarray.c:334..369 — test_intarray_bind.
  Usage: sqlite3_intarray_bind INTARRAY ?VALUE ...? }
function test_intarray_bind(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pArray : PSqlite3Intarray;
  rc     : cint;
  i, n   : cint;
  a      : Pi64;
  x      : Int64;
begin
  rc := SQLITE_OK;
  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('INTARRAY'));
    Result := TCL_ERROR;
    Exit;
  end;
  pArray := PSqlite3Intarray(intarrayTextToPtr(Tcl_GetString(objv[1])));
  n := objc - 2;
  a := Pi64(sqlite3_malloc64(SizeOf(i64) * n));
  if a = nil then
  begin
    Tcl_AppendResult(interp, PChar('SQLITE_NOMEM'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  for i := 0 to n - 1 do
  begin
    x := 0;
    Tcl_GetWideIntFromObj(nil, PPTclObj(objv)[i + 2], @x);
    a[i] := x;
  end;
  rc := sqlite3_intarray_bind(pArray, n, a, @sqlite3_free);
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, intarrayErrName(rc), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
end;

{ test_intarray.c:374..389 — Sqlitetestintarray_Init. }
function Sqlitetestintarray_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('sqlite3_intarray_create'),
    @test_intarray_create, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_intarray_bind'),
    @test_intarray_bind, nil, nil);
  Result := TCL_OK;
end;

initialization
  { test_intarray.c:188..214 — intarrayModule. }
  FillChar(intarrayModule, SizeOf(intarrayModule), 0);
  intarrayModule.iVersion    := 0;
  intarrayModule.xCreate     := @intarrayCreate;
  intarrayModule.xConnect    := @intarrayCreate;
  intarrayModule.xBestIndex  := @intarrayBestIndex;
  intarrayModule.xDisconnect := @intarrayDestroy;
  intarrayModule.xDestroy    := @intarrayDestroy;
  intarrayModule.xOpen       := @intarrayOpen;
  intarrayModule.xClose      := @intarrayClose;
  intarrayModule.xFilter     := @intarrayFilter;
  intarrayModule.xNext       := @intarrayNext;
  intarrayModule.xEof        := @intarrayEof;
  intarrayModule.xColumn     := @intarrayColumn;
  intarrayModule.xRowid      := @intarrayRowid;
end.
