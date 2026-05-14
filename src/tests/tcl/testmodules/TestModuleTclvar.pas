{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/src/test_tclvar.c (563 lines in C).

  The TCLVAR eponymous virtual table exposes the Tcl global variable
  namespace as a SQL table:

    CREATE TABLE x(
      name TEXT,        -- base name of the variable:  "x" in "$x(y)"
      arrayname TEXT,   -- array index name: "y" in "$x(y)"
      value TEXT,       -- the value of the variable
      fullname TEXT PRIMARY KEY
    ) WITHOUT ROWID;

  SELECT walks [info vars] (and [array names] for arrays); DELETE /
  INSERT / UPDATE operate on Tcl variables through "fullname"/"value".

  Public entry: Sqlitetesttclvar_Init(interp) — registers the
  `register_tclvar_module DB` Tcl command, which installs the module
  on the named connection and defines the supporting Tcl procs.
}
{$I passqlite3.inc}
unit TestModuleTclvar;

interface

uses
  ctypes,
  strings,
  PasTclBridge,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function Sqlitetesttclvar_Init(interp: PTclInterp): cint; cdecl;

implementation

{ test_tclvar.c:48..52 — characters that make up idxStr. }
const
  TCLVAR_NAME_EQ      = 'e';
  TCLVAR_NAME_MATCH   = 'm';
  TCLVAR_VALUE_GLOB   = 'g';
  TCLVAR_VALUE_REGEXP = 'r';
  TCLVAR_VALUE_LIKE   = 'l';

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { test_tclvar.c:60..63 — tclvar_vtab. }
  PTclvarVtab = ^TTclvarVtab;
  TTclvarVtab = record
    base   : Tsqlite3_vtab;
    interp : PTclInterp;
  end;

  { test_tclvar.c:66..73 — tclvar_cursor. }
  PTclvarCursor = ^TTclvarCursor;
  TTclvarCursor = record
    base   : Tsqlite3_vtab_cursor;
    pList1 : PTclObj;   { Result of [info vars ?pattern?] }
    pList2 : PTclObj;   { Result of [array names ...] }
    i1     : cint;      { Current item in pList1 }
    i2     : cint;      { Current item (if any) in pList2 }
  end;

var
  tclvarModule: Tsqlite3_module;

{ test_tclvar.c:76..97 — tclvarConnect / tclvarCreate (identical). }
function tclvarConnect(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
const
  zSchema =
    'CREATE TABLE x(' +
    '  name TEXT,' +
    '  arrayname TEXT,' +
    '  value TEXT,' +
    '  fullname TEXT PRIMARY KEY' +
    ') WITHOUT ROWID';
var
  pVtab: PTclvarVtab;
begin
  pVtab := PTclvarVtab(sqlite3MallocZero(SizeOf(TTclvarVtab)));
  if pVtab = nil then begin Result := SQLITE_NOMEM; Exit; end;
  ppVtab^ := @pVtab^.base;
  pVtab^.interp := PTclInterp(pAux);
  sqlite3_declare_vtab(db, zSchema);
  Result := SQLITE_OK;
end;

{ test_tclvar.c:101..104 — tclvarDisconnect / tclvarDestroy. }
function tclvarDisconnect(pVtab: PSqlite3Vtab): cint; cdecl;
begin
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

{ test_tclvar.c:110..115 — tclvarOpen. }
function tclvarOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): cint; cdecl;
var
  pCur: PTclvarCursor;
begin
  pCur := PTclvarCursor(sqlite3MallocZero(SizeOf(TTclvarCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  ppCursor^ := @pCur^.base;
  Result := SQLITE_OK;
end;

{ test_tclvar.c:120..130 — tclvarClose. }
function tclvarClose(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: PTclvarCursor;
begin
  pCur := PTclvarCursor(cur);
  if pCur^.pList1 <> nil then Tcl_DecrRefCount(pCur^.pList1);
  if pCur^.pList2 <> nil then Tcl_DecrRefCount(pCur^.pList2);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ test_tclvar.c:135..162 — next2.  Returns 1 if data is ready, else 0. }
function next2(interp: PTclInterp; pCur: PTclvarCursor;
  pObj: PTclObj): cint;
var
  p: PTclObj;
  n: cint;
begin
  if pObj <> nil then
  begin
    if pCur^.pList2 = nil then
    begin
      p := Tcl_NewStringObj(PChar('array names'), -1);
      Tcl_IncrRefCount(p);
      Tcl_ListObjAppendElement(nil, p, pObj);
      Tcl_EvalObjEx(interp, p, TCL_EVAL_GLOBAL);
      Tcl_DecrRefCount(p);
      pCur^.pList2 := Tcl_GetObjResult(interp);
      Tcl_IncrRefCount(pCur^.pList2);
      { assert( pCur->i2==0 ) }
    end
    else
    begin
      n := 0;
      Inc(pCur^.i2);
      Tcl_ListObjLength(nil, pCur^.pList2, @n);
      if pCur^.i2 >= n then
      begin
        Tcl_DecrRefCount(pCur^.pList2);
        pCur^.pList2 := nil;
        pCur^.i2 := 0;
        Result := 0;
        Exit;
      end;
    end;
  end;
  Result := 1;
end;

{ test_tclvar.c:164..182 — tclvarNext. }
function tclvarNext(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pObj: PTclObj;
  n:    cint;
  ok:   cint;
  pCur: PTclvarCursor;
  interp: PTclInterp;
begin
  n := 0;
  ok := 0;
  pCur := PTclvarCursor(cur);
  interp := PTclvarVtab(cur^.pVtab)^.interp;

  Tcl_ListObjLength(nil, pCur^.pList1, @n);
  while (ok = 0) and (pCur^.i1 < n) do
  begin
    Tcl_ListObjIndex(nil, pCur^.pList1, pCur^.i1, @pObj);
    ok := next2(interp, pCur, pObj);
    if ok = 0 then Inc(pCur^.i1);
  end;
  Result := SQLITE_OK;
end;

{ test_tclvar.c:184..244 — tclvarFilter. }
function tclvarFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PAnsiChar;
  argc: cint; argv: PPsqlite3_value): cint; cdecl;
var
  pCur:   PTclvarCursor;
  interp: PTclInterp;
  p:      PTclObj;
  zEq, zMatch, zGlob, zRegexp, zLike: PAnsiChar;
  i:      cint;
  apArg:  PPsqlite3_value;
  emptyZ: AnsiChar;
begin
  pCur := PTclvarCursor(pVtabCursor);
  interp := PTclvarVtab(pVtabCursor^.pVtab)^.interp;
  p := Tcl_NewStringObj(PChar('tclvar_filter_cmd'), -1);
  emptyZ := #0;
  zEq     := @emptyZ;
  zMatch  := @emptyZ;
  zGlob   := @emptyZ;
  zRegexp := @emptyZ;
  zLike   := @emptyZ;
  apArg   := argv;

  i := 0;
  while idxStr[i] <> #0 do
  begin
    case idxStr[i] of
      TCLVAR_NAME_EQ:
        zEq := PAnsiChar(sqlite3_value_text(apArg[i]));
      TCLVAR_NAME_MATCH:
        zMatch := PAnsiChar(sqlite3_value_text(apArg[i]));
      TCLVAR_VALUE_GLOB:
        zGlob := PAnsiChar(sqlite3_value_text(apArg[i]));
      TCLVAR_VALUE_REGEXP:
        zRegexp := PAnsiChar(sqlite3_value_text(apArg[i]));
      TCLVAR_VALUE_LIKE:
        zLike := PAnsiChar(sqlite3_value_text(apArg[i]));
    end;
    Inc(i);
  end;

  Tcl_IncrRefCount(p);
  Tcl_ListObjAppendElement(nil, p, Tcl_NewStringObj(PChar(zEq), -1));
  Tcl_ListObjAppendElement(nil, p, Tcl_NewStringObj(PChar(zMatch), -1));
  Tcl_ListObjAppendElement(nil, p, Tcl_NewStringObj(PChar(zGlob), -1));
  Tcl_ListObjAppendElement(nil, p, Tcl_NewStringObj(PChar(zRegexp), -1));
  Tcl_ListObjAppendElement(nil, p, Tcl_NewStringObj(PChar(zLike), -1));

  Tcl_EvalObjEx(interp, p, TCL_EVAL_GLOBAL);
  if pCur^.pList1 <> nil then Tcl_DecrRefCount(pCur^.pList1);
  if pCur^.pList2 <> nil then
  begin
    Tcl_DecrRefCount(pCur^.pList2);
    pCur^.pList2 := nil;
  end;
  pCur^.i1 := 0;
  pCur^.i2 := 0;
  pCur^.pList1 := Tcl_GetObjResult(interp);
  Tcl_IncrRefCount(pCur^.pList1);

  Tcl_DecrRefCount(p);
  Result := tclvarNext(pVtabCursor);
end;

{ test_tclvar.c:246..286 — tclvarColumn. }
function tclvarColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: cint): cint; cdecl;
var
  p1, p2: PTclObj;
  z1, z2: PAnsiChar;
  emptyZ: AnsiChar;
  pCur:   PTclvarCursor;
  interp: PTclInterp;
  pVal:   PTclObj;
  z3:     PAnsiChar;
  zJoin:  AnsiString;
begin
  emptyZ := #0;
  z2 := @emptyZ;
  pCur := PTclvarCursor(cur);
  interp := PTclvarVtab(cur^.pVtab)^.interp;

  Tcl_ListObjIndex(interp, pCur^.pList1, pCur^.i1, @p1);
  Tcl_ListObjIndex(interp, pCur^.pList2, pCur^.i2, @p2);
  z1 := PAnsiChar(Tcl_GetString(p1));
  if p2 <> nil then
    z2 := PAnsiChar(Tcl_GetString(p2));
  case i of
    0:
      sqlite3_result_text(ctx, z1, -1, SQLITE_TRANSIENT);
    1:
      sqlite3_result_text(ctx, z2, -1, SQLITE_TRANSIENT);
    2:
      begin
        if z2[0] <> #0 then
          pVal := Tcl_GetVar2Ex(interp, PChar(z1), PChar(z2), TCL_GLOBAL_ONLY)
        else
          pVal := Tcl_GetVar2Ex(interp, PChar(z1), nil, TCL_GLOBAL_ONLY);
        sqlite3_result_text(ctx, PAnsiChar(Tcl_GetString(pVal)), -1,
          SQLITE_TRANSIENT);
      end;
    3:
      begin
        if p2 <> nil then
        begin
          zJoin := string(z1) + '(' + string(z2) + ')';
          z3 := sqlite3StrDup(PChar(zJoin));
          sqlite3_result_text(ctx, z3, -1, SQLITE_DYNAMIC);
        end
        else
          sqlite3_result_text(ctx, z1, -1, SQLITE_TRANSIENT);
      end;
  end;
  Result := SQLITE_OK;
end;

{ test_tclvar.c:288..291 — tclvarRowid. }
function tclvarRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): cint; cdecl;
begin
  pRowid^ := 0;
  Result := SQLITE_OK;
end;

{ test_tclvar.c:293..296 — tclvarEof. }
function tclvarEof(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: PTclvarCursor;
begin
  pCur := PTclvarCursor(cur);
  if pCur^.pList2 <> nil then Result := 0 else Result := 1;
end;

{ test_tclvar.c:306..314 — tclvarAddToIdxstr.  Append x to zStr if not
  already present; return 1 if it was already there, else 0. }
function tclvarAddToIdxstr(zStr: PAnsiChar; x: AnsiChar): cint;
var
  i: cint;
begin
  i := 0;
  while zStr[i] <> #0 do
  begin
    if zStr[i] = x then begin Result := 1; Exit; end;
    Inc(i);
  end;
  zStr[i] := x;
  zStr[i + 1] := #0;
  Result := 0;
end;

{ test_tclvar.c:320..332 — tclvarSetOmit.  True iff $::tclvar_set_omit
  exists and is true. }
function tclvarSetOmit(interp: PTclInterp): cint; cdecl;
var
  rc:  cint;
  res: cint;
  pRes: PTclObj;
begin
  res := 0;
  rc := Tcl_Eval(interp,
    PChar('expr {[info exists ::tclvar_set_omit] && $::tclvar_set_omit}'));
  if rc = TCL_OK then
  begin
    pRes := Tcl_GetObjResult(interp);
    rc := Tcl_GetBooleanFromObj(nil, pRes, @res);
  end;
  if (rc = TCL_OK) and (res <> 0) then Result := 1 else Result := 0;
end;

{ test_tclvar.c:347..407 — tclvarBestIndex. }
function tclvarBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): cint; cdecl;
var
  pTab:  PTclvarVtab;
  ii:    cint;
  zStr:  PAnsiChar;
  iStr:  cint;
  pCons: PSqlite3IndexConstraint;
  pUsage: PSqlite3IndexConstraintUsage;
begin
  pTab := PTclvarVtab(tab);
  iStr := 0;
  zStr := PAnsiChar(sqlite3Malloc(32));
  if zStr = nil then begin Result := SQLITE_NOMEM; Exit; end;
  zStr[0] := #0;

  for ii := 0 to pIdxInfo^.nConstraint - 1 do
  begin
    pCons := pIdxInfo^.aConstraint;
    Inc(pCons, ii);
    pUsage := pIdxInfo^.aConstraintUsage;
    Inc(pUsage, ii);
    if pCons^.usable <> 0 then
    begin
      { name = ? }
      if (pCons^.op = SQLITE_INDEX_CONSTRAINT_EQ) and (pCons^.iColumn = 0) then
        if tclvarAddToIdxstr(zStr, TCLVAR_NAME_EQ) = 0 then
        begin
          Inc(iStr);
          pUsage^.argvIndex := iStr;
          pUsage^.omit := 0;
        end;
      { name MATCH ? }
      if (pCons^.op = SQLITE_INDEX_CONSTRAINT_MATCH) and (pCons^.iColumn = 0) then
        if tclvarAddToIdxstr(zStr, TCLVAR_NAME_MATCH) = 0 then
        begin
          Inc(iStr);
          pUsage^.argvIndex := iStr;
          pUsage^.omit := 1;
        end;
      { value GLOB ? }
      if (pCons^.op = SQLITE_INDEX_CONSTRAINT_GLOB) and (pCons^.iColumn = 2) then
        if tclvarAddToIdxstr(zStr, TCLVAR_VALUE_GLOB) = 0 then
        begin
          Inc(iStr);
          pUsage^.argvIndex := iStr;
          pUsage^.omit := u8(tclvarSetOmit(pTab^.interp));
        end;
      { value REGEXP ? }
      if (pCons^.op = SQLITE_INDEX_CONSTRAINT_REGEXP) and (pCons^.iColumn = 2) then
        if tclvarAddToIdxstr(zStr, TCLVAR_VALUE_REGEXP) = 0 then
        begin
          Inc(iStr);
          pUsage^.argvIndex := iStr;
          pUsage^.omit := u8(tclvarSetOmit(pTab^.interp));
        end;
      { value LIKE ? }
      if (pCons^.op = SQLITE_INDEX_CONSTRAINT_LIKE) and (pCons^.iColumn = 2) then
        if tclvarAddToIdxstr(zStr, TCLVAR_VALUE_LIKE) = 0 then
        begin
          Inc(iStr);
          pUsage^.argvIndex := iStr;
          pUsage^.omit := u8(tclvarSetOmit(pTab^.interp));
        end;
    end;
  end;

  pIdxInfo^.idxStr := zStr;
  pIdxInfo^.needToFreeIdxStr := 1;
  Result := SQLITE_OK;
end;

{ test_tclvar.c:412..459 — tclvarUpdate.  INSERT / DELETE / UPDATE on
  Tcl variables. }
function tclvarUpdate(tab: PSqlite3Vtab; argc: cint;
  argv: PPsqlite3_value; pRowid: Pi64): cint; cdecl;
var
  pTab:  PTclvarVtab;
  apArg: PPsqlite3_value;
  zVar, zValue, zName, zOldName, zNewName: PAnsiChar;
begin
  pTab := PTclvarVtab(tab);
  apArg := argv;
  if argc = 1 then
  begin
    { A DELETE operation. }
    zVar := PAnsiChar(sqlite3_value_text(apArg[0]));
    Tcl_UnsetVar(pTab^.interp, PChar(zVar), TCL_GLOBAL_ONLY);
    Result := SQLITE_OK;
    Exit;
  end;
  if sqlite3_value_type(apArg[0]) = SQLITE_NULL then
  begin
    { An INSERT operation. }
    zValue := PAnsiChar(sqlite3_value_text(apArg[4]));
    if sqlite3_value_type(apArg[5]) <> SQLITE_TEXT then
    begin
      tab^.zErrMsg := sqlite3_mprintf(
        PChar('the ''fullname'' column must be TEXT'));
      Result := SQLITE_ERROR;
      Exit;
    end;
    zName := PAnsiChar(sqlite3_value_text(apArg[5]));
    if zValue <> nil then
      Tcl_SetVar(pTab^.interp, PChar(zName), PChar(zValue), TCL_GLOBAL_ONLY)
    else
      Tcl_UnsetVar(pTab^.interp, PChar(zName), TCL_GLOBAL_ONLY);
    Result := SQLITE_OK;
    Exit;
  end;
  if (sqlite3_value_type(apArg[0]) = SQLITE_TEXT) and
     (sqlite3_value_type(apArg[1]) = SQLITE_TEXT) then
  begin
    { An UPDATE operation. }
    zOldName := PAnsiChar(sqlite3_value_text(apArg[0]));
    zNewName := PAnsiChar(sqlite3_value_text(apArg[1]));
    zValue   := PAnsiChar(sqlite3_value_text(apArg[4]));
    if (StrComp(zOldName, zNewName) <> 0) or (zValue = nil) then
      Tcl_UnsetVar(pTab^.interp, PChar(zOldName), TCL_GLOBAL_ONLY);
    if zValue <> nil then
      Tcl_SetVar(pTab^.interp, PChar(zNewName), PChar(zValue), TCL_GLOBAL_ONLY);
    Result := SQLITE_OK;
    Exit;
  end;
  tab^.zErrMsg := sqlite3_mprintf(PChar('prohibited TCL variable change'));
  Result := SQLITE_ERROR;
end;

{ test_tclvar.c:494..496 — getDbPointer.  Recover the sqlite3* behind a
  `db` Tcl command.  TSqliteDb's first field is the sqlite3* handle
  (tclsqlite.c:216), so objClientData dereferenced as a pointer yields
  it directly.  The raw-pointer-string fallback (sqlite3TestTextToPtr)
  is not needed by the .test corpus paths that drive this module. }
function getDbPointer(interp: PTclInterp; zA: PAnsiChar;
  ppDb: PPTsqlite3): cint;
var
  cmdInfo: TTclCmdInfo;
begin
  if Tcl_GetCommandInfo(interp, PChar(zA), @cmdInfo) <> 0 then
    ppDb^ := PPTsqlite3(cmdInfo.objClientData)^
  else
    ppDb^ := nil;
  Result := TCL_OK;
end;

{ test_tclvar.c:501..539 — register_tclvar_module.  `register_tclvar_module DB`. }
function register_tclvar_module(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  zProcs =
    'proc like {pattern str} {'#10 +
    '  set p [string map {% * _ ?} $pattern]'#10 +
    '  string match $p $str'#10 +
    '}'#10 +
    'proc tclvar_filter_cmd {eq match glob regexp like} {'#10 +
    '  set res {}'#10 +
    '  set pattern $eq'#10 +
    '  if {$pattern=={}} { set pattern $match }'#10 +
    '  if {$pattern=={}} { set pattern * }'#10 +
    '  foreach v [uplevel #0 info vars $pattern] {'#10 +
    '    if {($glob=={} || [string match $glob [uplevel #0 set $v]])'#10 +
    '     && ($like=={} || [like $like [uplevel #0 set $v]])'#10 +
    '     && ($regexp=={} || [regexp $regexp [uplevel #0 set $v]])'#10 +
    '    } {'#10 +
    '      lappend res $v'#10 +
    '    }'#10 +
    '  }'#10 +
    '  set res'#10 +
    '}'#10;
var
  rc: cint;
  db: PTsqlite3;
begin
  rc := TCL_OK;
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, PAnsiChar(Tcl_GetString(objv[1])), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if db = nil then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  sqlite3_create_module(db, PAnsiChar('tclvar'), @tclvarModule, interp);
  rc := Tcl_Eval(interp, PChar(zProcs));
  Result := rc;
end;

{ test_tclvar.c:547..563 — Sqlitetesttclvar_Init. }
function Sqlitetesttclvar_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('register_tclvar_module'),
    @register_tclvar_module, nil, nil);
  Result := TCL_OK;
end;

initialization
  { test_tclvar.c:465..491 — tclvarModule.  xCreate == xConnect,
    xDestroy == xDisconnect. }
  FillChar(tclvarModule, SizeOf(tclvarModule), 0);
  tclvarModule.iVersion    := 0;
  tclvarModule.xCreate     := @tclvarConnect;
  tclvarModule.xConnect    := @tclvarConnect;
  tclvarModule.xBestIndex  := @tclvarBestIndex;
  tclvarModule.xDisconnect := @tclvarDisconnect;
  tclvarModule.xDestroy    := @tclvarDisconnect;
  tclvarModule.xOpen       := @tclvarOpen;
  tclvarModule.xClose      := @tclvarClose;
  tclvarModule.xFilter     := @tclvarFilter;
  tclvarModule.xNext       := @tclvarNext;
  tclvarModule.xEof        := @tclvarEof;
  tclvarModule.xColumn     := @tclvarColumn;
  tclvarModule.xRowid      := @tclvarRowid;
  tclvarModule.xUpdate     := @tclvarUpdate;
end.
