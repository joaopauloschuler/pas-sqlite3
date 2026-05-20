{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/src/test_bestindex.c (981 lines in C).

  The "tcl" virtual-table module is a test vtab whose xConnect /
  xBestIndex / xFilter (etc.) callbacks marshal their arguments into a
  Tcl SCRIPT command and parse the Tcl result back into the
  sqlite3_index_info / cursor rows.  Used by the bestindex*.test corpus.

    CREATE VIRTUAL TABLE x1 USING tcl(tcl_command);

  The command [tcl_command] is invoked as:
    tcl_command xConnect
    tcl_command xBestIndex HANDLE
    tcl_command xFilter IDXNUM IDXSTR ARGLIST
    tcl_command xFindFunction NARG NAME
    tcl_command function NAME ARGS...
    tcl_command xUpdate

  Two modules are registered behind the single name "tcl": one without
  an xUpdate method, one with (tclModuleUpdate, used when a DEFAULT-CMD
  is supplied to register_tcl_module).

  Public entry: Sqlitetesttcl_Init(interp) — registers the Tcl command
  `register_tcl_module DB ?DEFAULT-CMD?`.
}
{$I passqlite3.inc}
unit TestModuleBestindex;

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

function Sqlitetesttcl_Init(interp: PTclInterp): cint; cdecl;

implementation

const
  TCL_GLOBAL_ONLY = 1;        { tcl.h }
  TCL_EVAL_GLOBAL = $20000;   { tcl.h — TCL_EVAL_GLOBAL }

type
  PPSqlite3Vtab       = ^PSqlite3Vtab;
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  PTclVtab        = ^TTclVtab;
  PTestFindFunction = ^TTestFindFunction;

  { test_bestindex.c:109..115 — struct tcl_vtab. }
  TTclVtab = record
    base              : Tsqlite3_vtab;
    interp            : PTclInterp;
    pCmd              : PTclObj;
    pFindFunctionList : PTestFindFunction;
    db                : PTsqlite3;
  end;

  { test_bestindex.c:118..121 — struct tcl_cursor. }
  PTclCursor = ^TTclCursor;
  TTclCursor = record
    base  : Tsqlite3_vtab_cursor;
    pStmt : Pointer;            { sqlite3_stmt* — read data from here }
  end;

  { test_bestindex.c:123..127 — struct TestFindFunction. }
  TTestFindFunction = record
    pTab  : PTclVtab;
    zName : PAnsiChar;
    pNext : PTestFindFunction;
  end;

  { test_bestindex.c:129..132 — struct TestVtabContext. }
  PTestVtabContext = ^TTestVtabContext;
  TTestVtabContext = record
    interp   : PTclInterp;
    pDefault : PTclObj;
  end;

var
  tclModule       : Tsqlite3_module;
  tclModuleUpdate : Tsqlite3_module;
  iNextHdl        : cint = 43;   { test_bestindex.c:646 — static int iNext }

{ Minimal sqlite3ErrName subset for the rc values rhs_value can surface. }
function tclErrName(rc: cint): PAnsiChar;
begin
  case rc of
    SQLITE_OK:        Result := PChar('SQLITE_OK');
    SQLITE_ERROR:     Result := PChar('SQLITE_ERROR');
    SQLITE_NOMEM:     Result := PChar('SQLITE_NOMEM');
    SQLITE_MISUSE:    Result := PChar('SQLITE_MISUSE');
    SQLITE_NOTFOUND:  Result := PChar('SQLITE_NOTFOUND');
    SQLITE_RANGE:     Result := PChar('SQLITE_RANGE');
  else
    Result := PChar('SQLITE_ERROR');
  end;
end;

{ test_bestindex.c:137..166 — tclDequote.  Dequote string z in place. }
procedure tclDequote(z: PAnsiChar);
var
  q          : AnsiChar;
  iIn, iOut  : cint;
begin
  q := z[0];
  if (q = '[') or (q = '''') or (q = '"') or (q = '`') then
  begin
    iIn := 1;
    iOut := 0;
    if q = '[' then q := ']';

    while z[iIn] <> #0 do
    begin
      if z[iIn] = q then
      begin
        if z[iIn + 1] <> q then
        begin
          { Character iIn was the close quote. }
          Inc(iIn);
          Break;
        end
        else
        begin
          { Escaped quote character — skip both, emit one. }
          Inc(iIn, 2);
          z[iOut] := q; Inc(iOut);
        end;
      end
      else
      begin
        z[iOut] := z[iIn]; Inc(iOut); Inc(iIn);
      end;
    end;

    z[iOut] := #0;
  end;
end;

{ Forward decls. }
function tclNext(pVtabCursor: PSqlite3VtabCursor): cint; cdecl; forward;
procedure tclFunction(pCtx: Psqlite3_context; nArg: cint;
  apArg: PPsqlite3_value); cdecl; forward;

{ test_bestindex.c:179..247 — tclConnect (xConnect == xCreate). }
function tclConnect(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
var
  pCtx    : PTestVtabContext;
  interp  : PTclInterp;
  pTab    : PTclVtab;
  zCmd    : PAnsiChar;
  pScript : PTclObj;
  rc      : cint;
  n       : PtrUInt;
begin
  pCtx    := PTestVtabContext(pAux);
  interp  := pCtx^.interp;
  pTab    := nil;
  zCmd    := nil;
  pScript := nil;
  rc      := SQLITE_OK;

  if (argc <> 4) and ((argc <> 3) or (pCtx^.pDefault = nil)) then
  begin
    pzErr^ := sqlite3_mprintf(PChar('wrong number of arguments'));
    Result := SQLITE_ERROR;
    Exit;
  end;

  if argc = 4 then
  begin
    n := StrLen(argv[3]) + 1;
    zCmd := PAnsiChar(sqlite3_malloc64(n));
  end;
  pTab := PTclVtab(sqlite3_malloc64(SizeOf(TTclVtab)));
  if ((zCmd <> nil) or (argc = 3)) and (pTab <> nil) then
  begin
    FillChar(pTab^, SizeOf(TTclVtab), 0);

    if zCmd <> nil then
    begin
      Move(argv[3]^, zCmd^, StrLen(argv[3]) + 1);
      tclDequote(zCmd);
      pTab^.pCmd := Tcl_NewStringObj(zCmd, -1);
    end
    else
      pTab^.pCmd := Tcl_DuplicateObj(pCtx^.pDefault);

    pTab^.interp := interp;
    pTab^.db := db;
    Tcl_IncrRefCount(pTab^.pCmd);

    pScript := Tcl_DuplicateObj(pTab^.pCmd);
    Tcl_IncrRefCount(pScript);
    Tcl_ListObjAppendElement(interp, pScript,
      Tcl_NewStringObj(PChar('xConnect'), -1));

    rc := Tcl_EvalObjEx(interp, pScript, TCL_EVAL_GLOBAL);
    if rc <> TCL_OK then
    begin
      pzErr^ := sqlite3PfMprintf('%s', [Tcl_GetStringResult(interp)]);
      if sqlite3_stricmp(pzErr^, PChar('database schema has changed')) = 0 then
        rc := SQLITE_SCHEMA
      else
        rc := SQLITE_ERROR;
    end
    else
    begin
      rc := sqlite3_declare_vtab(db, Tcl_GetStringResult(interp));
      if rc <> SQLITE_OK then
        pzErr^ := sqlite3PfMprintf('declare_vtab: %s',
          [sqlite3_errmsg(db)]);
    end;

    { Note: the dup'd pScript is leaked here exactly as in the C source
      (Tcl_EvalObjEx does not consume the reference; the C code never
      DecrRefCounts pScript in tclConnect). }

    if rc <> SQLITE_OK then
    begin
      sqlite3_free(pTab);
      pTab := nil;
    end;
  end
  else
    rc := SQLITE_NOMEM;

  sqlite3_free(zCmd);
  if pTab <> nil then ppVtab^ := @pTab^.base
  else ppVtab^ := nil;
  Result := rc;
end;

{ test_bestindex.c:250..260 — tclDisconnect (xDisconnect == xDestroy). }
function tclDisconnect(pVtab: PSqlite3Vtab): cint; cdecl;
var
  pTab : PTclVtab;
  p    : PTestFindFunction;
begin
  pTab := PTclVtab(pVtab);
  while pTab^.pFindFunctionList <> nil do
  begin
    p := pTab^.pFindFunctionList;
    pTab^.pFindFunctionList := p^.pNext;
    sqlite3_free(p);
  end;
  Tcl_DecrRefCount(pTab^.pCmd);
  sqlite3_free(pTab);
  Result := SQLITE_OK;
end;

{ test_bestindex.c:265..272 — tclOpen. }
function tclOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): cint; cdecl;
var
  pCur: PTclCursor;
begin
  pCur := PTclCursor(sqlite3_malloc(SizeOf(TTclCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TTclCursor), 0);
  ppCursor^ := @pCur^.base;
  Result := SQLITE_OK;
end;

{ test_bestindex.c:277..284 — tclClose. }
function tclClose(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: PTclCursor;
begin
  pCur := PTclCursor(cur);
  if pCur <> nil then
  begin
    sqlite3_finalize(pCur^.pStmt);
    sqlite3_free(pCur);
  end;
  Result := SQLITE_OK;
end;

{ test_bestindex.c:286..302 — tclNext. }
function tclNext(pVtabCursor: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr : PTclCursor;
  pTab : PTclVtab;
  rc   : cint;
  zErr : PAnsiChar;
begin
  pCsr := PTclCursor(pVtabCursor);
  if pCsr^.pStmt <> nil then
  begin
    pTab := PTclVtab(pVtabCursor^.pVtab);
    rc := sqlite3_step(pCsr^.pStmt);
    if rc <> SQLITE_ROW then
    begin
      rc := sqlite3_finalize(pCsr^.pStmt);
      pCsr^.pStmt := nil;
      if rc <> SQLITE_OK then
      begin
        zErr := sqlite3_errmsg(pTab^.db);
        pTab^.base.zErrMsg := sqlite3PfMprintf('%s', [zErr]);
      end;
    end;
  end;
  Result := SQLITE_OK;
end;

{ test_bestindex.c:304..397 — tclFilter. }
function tclFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PAnsiChar;
  argc: cint; argv: PPsqlite3_value): cint; cdecl;
var
  pCsr    : PTclCursor;
  pTab    : PTclVtab;
  interp  : PTclInterp;
  pScript : PTclObj;
  pArg    : PTclObj;
  ii      : cint;
  rc      : cint;
  zVal    : PAnsiChar;
  pVal    : PTclObj;
  pVal2   : PTclObj;
  pMem    : passqlite3vdbe.PMem;
  pRes    : PTclObj;
  apElem  : PPTclObj;
  nElem   : cint;
  zCmd    : PAnsiChar;
  p       : PTclObj;
  zSql    : PAnsiChar;
  zErr    : PAnsiChar;
begin
  pCsr   := PTclCursor(pVtabCursor);
  pTab   := PTclVtab(pVtabCursor^.pVtab);
  interp := pTab^.interp;

  pScript := Tcl_DuplicateObj(pTab^.pCmd);
  Tcl_IncrRefCount(pScript);
  Tcl_ListObjAppendElement(interp, pScript,
    Tcl_NewStringObj(PChar('xFilter'), -1));
  Tcl_ListObjAppendElement(interp, pScript, Tcl_NewIntObj(idxNum));
  if idxStr <> nil then
    Tcl_ListObjAppendElement(interp, pScript, Tcl_NewStringObj(idxStr, -1))
  else
    Tcl_ListObjAppendElement(interp, pScript, Tcl_NewStringObj(PChar(''), -1));

  pArg := Tcl_NewObj();
  Tcl_IncrRefCount(pArg);
  for ii := 0 to argc - 1 do
  begin
    zVal := PAnsiChar(sqlite3_value_text(argv[ii]));
    if zVal = nil then
    begin
      pVal := Tcl_NewObj();
      rc := sqlite3_vtab_in_first(argv[ii], @pMem);
      while (rc = SQLITE_OK) and (pMem <> nil) do
      begin
        zVal := PAnsiChar(sqlite3_value_text(pMem));
        if zVal <> nil then
          pVal2 := Tcl_NewStringObj(zVal, -1)
        else
          pVal2 := Tcl_NewObj();
        Tcl_ListObjAppendElement(interp, pVal, pVal2);
        rc := sqlite3_vtab_in_next(argv[ii], @pMem);
      end;
    end
    else
      pVal := Tcl_NewStringObj(zVal, -1);
    Tcl_ListObjAppendElement(interp, pArg, pVal);
  end;
  Tcl_ListObjAppendElement(interp, pScript, pArg);
  Tcl_DecrRefCount(pArg);

  rc := Tcl_EvalObjEx(interp, pScript, TCL_EVAL_GLOBAL);
  if rc <> TCL_OK then
  begin
    zErr := Tcl_GetStringResult(interp);
    rc := SQLITE_ERROR;
    pTab^.base.zErrMsg := sqlite3PfMprintf('%s', [zErr]);
  end
  else
  begin
    pRes := Tcl_GetObjResult(interp);
    apElem := nil;
    nElem := 0;
    rc := Tcl_ListObjGetElements(interp, pRes, @nElem, @apElem);
    if rc <> TCL_OK then
    begin
      zErr := Tcl_GetStringResult(interp);
      rc := SQLITE_ERROR;
      pTab^.base.zErrMsg := sqlite3PfMprintf('%s', [zErr]);
    end
    else
    begin
      ii := 0;
      while (rc = SQLITE_OK) and (ii < nElem) do
      begin
        zCmd := Tcl_GetString(apElem[ii]);
        p := apElem[ii + 1];
        if sqlite3_stricmp(PChar('sql'), zCmd) = 0 then
        begin
          zSql := Tcl_GetString(p);
          rc := sqlite3_prepare_v2(pTab^.db, zSql, -1, @pCsr^.pStmt, nil);
          if rc <> SQLITE_OK then
          begin
            zErr := sqlite3_errmsg(pTab^.db);
            pTab^.base.zErrMsg := sqlite3PfMprintf('unexpected: %s', [zErr]);
          end;
        end
        else
        begin
          rc := SQLITE_ERROR;
          pTab^.base.zErrMsg := sqlite3PfMprintf('unexpected: %s', [zCmd]);
        end;
        Inc(ii, 2);
      end;
    end;
  end;

  Tcl_DecrRefCount(pScript);

  if rc = SQLITE_OK then
    rc := tclNext(pVtabCursor);
  Result := rc;
end;

{ test_bestindex.c:399..407 — tclColumn. }
function tclColumn(pVtabCursor: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: cint): cint; cdecl;
var
  pCsr: PTclCursor;
begin
  pCsr := PTclCursor(pVtabCursor);
  sqlite3_result_value(ctx, sqlite3_column_value(pCsr^.pStmt, i + 1));
  Result := SQLITE_OK;
end;

{ test_bestindex.c:409..413 — tclRowid. }
function tclRowid(pVtabCursor: PSqlite3VtabCursor; pRowid: Pi64): cint; cdecl;
var
  pCsr: PTclCursor;
begin
  pCsr := PTclCursor(pVtabCursor);
  pRowid^ := sqlite3_column_int64(pCsr^.pStmt, 0);
  Result := SQLITE_OK;
end;

{ test_bestindex.c:415..418 — tclEof. }
function tclEof(pVtabCursor: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PTclCursor;
begin
  pCsr := PTclCursor(pVtabCursor);
  if pCsr^.pStmt = nil then Result := 1 else Result := 0;
end;

{ test_bestindex.c:420..486 — testBestIndexObjConstraints. }
procedure testBestIndexObjConstraints(interp: PTclInterp;
  pIdxInfo: PSqlite3IndexInfo);
var
  ii    : cint;
  pRes  : PTclObj;
  pCons : PSqlite3IndexConstraint;
  pElem : PTclObj;
  zOp   : PAnsiChar;
begin
  pRes := Tcl_NewObj();
  Tcl_IncrRefCount(pRes);
  for ii := 0 to pIdxInfo^.nConstraint - 1 do
  begin
    pCons := pIdxInfo^.aConstraint;
    Inc(pCons, ii);
    pElem := Tcl_NewObj();
    zOp := nil;

    Tcl_IncrRefCount(pElem);

    case pCons^.op of
      SQLITE_INDEX_CONSTRAINT_EQ:        zOp := PChar('eq');
      SQLITE_INDEX_CONSTRAINT_GT:        zOp := PChar('gt');
      SQLITE_INDEX_CONSTRAINT_LE:        zOp := PChar('le');
      SQLITE_INDEX_CONSTRAINT_LT:        zOp := PChar('lt');
      SQLITE_INDEX_CONSTRAINT_GE:        zOp := PChar('ge');
      SQLITE_INDEX_CONSTRAINT_MATCH:     zOp := PChar('match');
      SQLITE_INDEX_CONSTRAINT_LIKE:      zOp := PChar('like');
      SQLITE_INDEX_CONSTRAINT_GLOB:      zOp := PChar('glob');
      SQLITE_INDEX_CONSTRAINT_REGEXP:    zOp := PChar('regexp');
      SQLITE_INDEX_CONSTRAINT_NE:        zOp := PChar('ne');
      SQLITE_INDEX_CONSTRAINT_ISNOT:     zOp := PChar('isnot');
      SQLITE_INDEX_CONSTRAINT_ISNOTNULL: zOp := PChar('isnotnull');
      SQLITE_INDEX_CONSTRAINT_ISNULL:    zOp := PChar('isnull');
      SQLITE_INDEX_CONSTRAINT_IS:        zOp := PChar('is');
      SQLITE_INDEX_CONSTRAINT_LIMIT:     zOp := PChar('limit');
      SQLITE_INDEX_CONSTRAINT_OFFSET:    zOp := PChar('offset');
    end;

    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewStringObj(PChar('op'), -1));
    if zOp <> nil then
      Tcl_ListObjAppendElement(nil, pElem, Tcl_NewStringObj(zOp, -1))
    else
      Tcl_ListObjAppendElement(nil, pElem, Tcl_NewIntObj(pCons^.op));
    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewStringObj(PChar('column'), -1));
    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewIntObj(pCons^.iColumn));
    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewStringObj(PChar('usable'), -1));
    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewIntObj(pCons^.usable));

    Tcl_ListObjAppendElement(nil, pRes, pElem);
    Tcl_DecrRefCount(pElem);
  end;

  Tcl_SetObjResult(interp, pRes);
  Tcl_DecrRefCount(pRes);
end;

{ test_bestindex.c:488..511 — testBestIndexObjOrderby. }
procedure testBestIndexObjOrderby(interp: PTclInterp;
  pIdxInfo: PSqlite3IndexInfo);
var
  ii     : cint;
  pRes   : PTclObj;
  pOrder : PSqlite3IndexOrderBy;
  pElem  : PTclObj;
begin
  pRes := Tcl_NewObj();
  Tcl_IncrRefCount(pRes);
  for ii := 0 to pIdxInfo^.nOrderBy - 1 do
  begin
    pOrder := pIdxInfo^.aOrderBy;
    Inc(pOrder, ii);
    pElem := Tcl_NewObj();
    Tcl_IncrRefCount(pElem);

    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewStringObj(PChar('column'), -1));
    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewIntObj(pOrder^.iColumn));
    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewStringObj(PChar('desc'), -1));
    Tcl_ListObjAppendElement(nil, pElem, Tcl_NewIntObj(pOrder^.desc));

    Tcl_ListObjAppendElement(nil, pRes, pElem);
    Tcl_DecrRefCount(pElem);
  end;

  Tcl_SetObjResult(interp, pRes);
  Tcl_DecrRefCount(pRes);
end;

{ test_bestindex.c:531..639 — testBestIndexObj.  The $hdl handle command. }
function testBestIndexObj(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  azSub: array[0..7] of PChar = (
    'constraints',   { 0 }
    'orderby',       { 1 }
    'mask',          { 2 }
    'distinct',      { 3 }
    'in',            { 4 }
    'rhs_value',     { 5 }
    'collation',     { 6 }
    nil
  );
var
  ii        : cint;
  pIdxInfo  : PSqlite3IndexInfo;
  bDistinct : cint;
  iCons     : cint;
  bHandle   : cint;
  rc        : cint;
  pVal      : passqlite3vdbe.PMem;
  zVal      : PAnsiChar;
  zColl     : PAnsiChar;
begin
  pIdxInfo := PSqlite3IndexInfo(clientData);

  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SUB-COMMAND'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetIndexFromObj(interp, objv[1], @azSub[0], PChar('sub-command'),
       0, @ii) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;

  if (ii < 4) and (objc <> 2) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar(''));
    Result := TCL_ERROR;
    Exit;
  end;
  if (ii = 4) and (objc <> 4) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('INDEX BOOLEAN'));
    Result := TCL_ERROR;
    Exit;
  end;
  if (ii = 5) and (objc <> 3) and (objc <> 4) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('INDEX ?DEFAULT?'));
    Result := TCL_ERROR;
    Exit;
  end;

  case ii of
    0:
      testBestIndexObjConstraints(interp, pIdxInfo);

    1:
      testBestIndexObjOrderby(interp, pIdxInfo);

    2:
      Tcl_SetObjResult(interp, Tcl_NewWideIntObj(Int64(pIdxInfo^.colUsed)));

    3:
      begin
        bDistinct := sqlite3_vtab_distinct(pIdxInfo);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(bDistinct));
      end;

    4:
      begin
        iCons := 0;
        bHandle := 0;
        if (Tcl_GetIntFromObj(interp, objv[2], @iCons) <> 0) or
           (Tcl_GetBooleanFromObj(interp, objv[3], @bHandle) <> 0) then
        begin
          Result := TCL_ERROR;
          Exit;
        end;
        Tcl_SetObjResult(interp,
          Tcl_NewIntObj(sqlite3_vtab_in(pIdxInfo, iCons, bHandle)));
      end;

    5:
      begin
        iCons := 0;
        pVal := nil;
        zVal := PChar('');
        if Tcl_GetIntFromObj(interp, objv[2], @iCons) <> 0 then
        begin
          Result := TCL_ERROR;
          Exit;
        end;
        rc := sqlite3_vtab_rhs_value(pIdxInfo, iCons, @pVal);
        if (rc <> SQLITE_OK) and (rc <> SQLITE_NOTFOUND) then
        begin
          Tcl_SetResult(interp, tclErrName(rc), Pointer(1)); { TCL_VOLATILE }
          Result := TCL_ERROR;
          Exit;
        end;
        if pVal <> nil then
          zVal := PAnsiChar(sqlite3_value_text(pVal))
        else if objc = 4 then
          zVal := Tcl_GetString(objv[3]);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(zVal, -1));
      end;

    6:
      begin
        iCons := 0;
        zColl := PChar('');
        if Tcl_GetIntFromObj(interp, objv[2], @iCons) <> 0 then
        begin
          Result := TCL_ERROR;
          Exit;
        end;
        zColl := sqlite3_vtab_collation(pIdxInfo, iCons);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(zColl, -1));
      end;
  end;

  Result := TCL_OK;
end;

{ test_bestindex.c:641..743 — tclBestIndex. }
function tclBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): cint; cdecl;
var
  pTab    : PTclVtab;
  interp  : PTclInterp;
  rc      : cint;
  zHdl    : array[0..23] of AnsiChar;
  pScript : PTclObj;
  pRes    : PTclObj;
  apElem  : PPTclObj;
  nElem   : cint;
  ii      : cint;
  iArgv   : cint;
  zCmd    : PAnsiChar;
  p       : PTclObj;
  x       : Int64;
  iCons   : cint;
  bOmit   : cint;
  pUsage  : PSqlite3IndexConstraintUsage;
  zErr    : PAnsiChar;
begin
  pTab   := PTclVtab(tab);
  interp := pTab^.interp;
  rc     := SQLITE_OK;

  pScript := Tcl_DuplicateObj(pTab^.pCmd);
  Tcl_IncrRefCount(pScript);
  Tcl_ListObjAppendElement(interp, pScript,
    Tcl_NewStringObj(PChar('xBestIndex'), -1));

  sqlite3PfSnprintf(SizeOf(zHdl), @zHdl[0], 'bestindex%d', [iNextHdl]);
  Inc(iNextHdl);
  Tcl_CreateObjCommand(interp, @zHdl[0], @testBestIndexObj, pIdxInfo, nil);
  Tcl_ListObjAppendElement(interp, pScript, Tcl_NewStringObj(@zHdl[0], -1));
  rc := Tcl_EvalObjEx(interp, pScript, TCL_EVAL_GLOBAL);
  Tcl_DeleteCommand(interp, @zHdl[0]);
  Tcl_DecrRefCount(pScript);

  if rc <> TCL_OK then
  begin
    zErr := Tcl_GetStringResult(interp);
    rc := SQLITE_ERROR;
    pTab^.base.zErrMsg := sqlite3PfMprintf('%s', [zErr]);
  end
  else
  begin
    pRes := Tcl_GetObjResult(interp);
    apElem := nil;
    nElem := 0;
    rc := Tcl_ListObjGetElements(interp, pRes, @nElem, @apElem);
    if rc <> TCL_OK then
    begin
      zErr := Tcl_GetStringResult(interp);
      rc := SQLITE_ERROR;
      pTab^.base.zErrMsg := sqlite3PfMprintf('%s', [zErr]);
    end
    else
    begin
      iArgv := 1;
      ii := 0;
      while (rc = SQLITE_OK) and (ii < nElem) do
      begin
        zCmd := Tcl_GetString(apElem[ii]);
        p := apElem[ii + 1];
        if sqlite3_stricmp(PChar('cost'), zCmd) = 0 then
          rc := Tcl_GetDoubleFromObj(interp, p, @pIdxInfo^.estimatedCost)
        else if sqlite3_stricmp(PChar('orderby'), zCmd) = 0 then
          rc := Tcl_GetIntFromObj(interp, p, @pIdxInfo^.orderByConsumed)
        else if sqlite3_stricmp(PChar('idxnum'), zCmd) = 0 then
          rc := Tcl_GetIntFromObj(interp, p, @pIdxInfo^.idxNum)
        else if sqlite3_stricmp(PChar('idxstr'), zCmd) = 0 then
        begin
          sqlite3_free(pIdxInfo^.idxStr);
          pIdxInfo^.idxStr := sqlite3PfMprintf('%s', [Tcl_GetString(p)]);
          pIdxInfo^.needToFreeIdxStr := 1;
        end
        else if sqlite3_stricmp(PChar('rows'), zCmd) = 0 then
        begin
          x := 0;
          rc := Tcl_GetWideIntFromObj(interp, p, @x);
          pIdxInfo^.estimatedRows := x;
        end
        else if (sqlite3_stricmp(PChar('use'), zCmd) = 0) or
                (sqlite3_stricmp(PChar('omit'), zCmd) = 0) then
        begin
          iCons := 0;
          rc := Tcl_GetIntFromObj(interp, p, @iCons);
          if rc = SQLITE_OK then
          begin
            if (iCons < 0) or (iCons >= pIdxInfo^.nConstraint) then
            begin
              rc := SQLITE_ERROR;
              pTab^.base.zErrMsg := sqlite3PfMprintf('unexpected: %d',
                [iCons]);
            end
            else
            begin
              if (zCmd[0] = 'o') or (zCmd[0] = 'O') then bOmit := 1
              else bOmit := 0;
              pUsage := pIdxInfo^.aConstraintUsage;
              Inc(pUsage, iCons);
              pUsage^.argvIndex := iArgv;
              Inc(iArgv);
              pUsage^.omit := u8(bOmit);
            end;
          end;
        end
        else if sqlite3_stricmp(PChar('constraint'), zCmd) = 0 then
        begin
          rc := SQLITE_CONSTRAINT;
          pTab^.base.zErrMsg := sqlite3PfMprintf('%s', [Tcl_GetString(p)]);
        end
        else
        begin
          rc := SQLITE_ERROR;
          pTab^.base.zErrMsg := sqlite3PfMprintf('unexpected: %s', [zCmd]);
        end;
        if (rc <> SQLITE_OK) and (pTab^.base.zErrMsg = nil) then
        begin
          zErr := Tcl_GetStringResult(interp);
          pTab^.base.zErrMsg := sqlite3PfMprintf('%s', [zErr]);
        end;
        Inc(ii, 2);
      end;
    end;
  end;

  Result := rc;
end;

{ test_bestindex.c:745..768 — tclFunction. }
procedure tclFunction(pCtx: Psqlite3_context; nArg: cint;
  apArg: PPsqlite3_value); cdecl;
var
  p       : PTestFindFunction;
  interp  : PTclInterp;
  pScript : PTclObj;
  pRet    : PTclObj;
  ii      : cint;
  zArg    : PAnsiChar;
begin
  p := PTestFindFunction(sqlite3_user_data(pCtx));
  interp := p^.pTab^.interp;

  pScript := Tcl_DuplicateObj(p^.pTab^.pCmd);
  Tcl_IncrRefCount(pScript);
  Tcl_ListObjAppendElement(interp, pScript,
    Tcl_NewStringObj(PChar('function'), -1));
  Tcl_ListObjAppendElement(interp, pScript,
    Tcl_NewStringObj(p^.zName, -1));

  for ii := 0 to nArg - 1 do
  begin
    zArg := PAnsiChar(sqlite3_value_text(apArg[ii]));
    if zArg <> nil then
      Tcl_ListObjAppendElement(interp, pScript, Tcl_NewStringObj(zArg, -1))
    else
      Tcl_ListObjAppendElement(interp, pScript, Tcl_NewObj());
  end;
  Tcl_EvalObjEx(interp, pScript, TCL_EVAL_GLOBAL);
  Tcl_DecrRefCount(pScript);

  pRet := Tcl_GetObjResult(interp);
  sqlite3_result_text(pCtx, Tcl_GetString(pRet), -1, SQLITE_TRANSIENT);
end;

{ test_bestindex.c:770..820 — tclFindFunction. }
function tclFindFunction(tab: PSqlite3Vtab; nArg: cint;
  zName: PAnsiChar; pxFunc: PPointer; ppArg: PPointer): cint; cdecl;
var
  iRet    : cint;
  pTab    : PTclVtab;
  interp  : PTclInterp;
  pScript : PTclObj;
  rc      : cint;
  pObj    : PTclObj;
  nName   : i64;
  nByte   : i64;
  pNew    : PTestFindFunction;
begin
  iRet := 0;
  pTab := PTclVtab(tab);
  interp := pTab^.interp;
  rc := SQLITE_OK;

  pScript := Tcl_DuplicateObj(pTab^.pCmd);
  Tcl_IncrRefCount(pScript);
  Tcl_ListObjAppendElement(interp, pScript,
    Tcl_NewStringObj(PChar('xFindFunction'), -1));
  Tcl_ListObjAppendElement(interp, pScript, Tcl_NewIntObj(nArg));
  Tcl_ListObjAppendElement(interp, pScript, Tcl_NewStringObj(zName, -1));
  rc := Tcl_EvalObjEx(interp, pScript, TCL_EVAL_GLOBAL);
  Tcl_DecrRefCount(pScript);

  if rc = SQLITE_OK then
  begin
    pObj := Tcl_GetObjResult(interp);

    if Tcl_GetIntFromObj(interp, pObj, @iRet) <> 0 then
      rc := SQLITE_ERROR
    else if iRet > 0 then
    begin
      nName := StrLen(zName);
      nByte := nName + 1 + SizeOf(TTestFindFunction);
      pNew := PTestFindFunction(sqlite3_malloc64(nByte));
      if pNew = nil then
        iRet := 0
      else
      begin
        FillChar(pNew^, nByte, 0);
        pNew^.zName := PAnsiChar(pNew) + SizeOf(TTestFindFunction);
        Move(zName^, pNew^.zName^, nName);
        pNew^.pTab := pTab;
        pNew^.pNext := pTab^.pFindFunctionList;
        pTab^.pFindFunctionList := pNew;
        ppArg^ := Pointer(pNew);
        pxFunc^ := @tclFunction;
      end;
    end;
  end;

  Result := iRet;
end;

{ test_bestindex.c:822..852 — tclUpdate. }
function tclUpdate(tab: PSqlite3Vtab; nArg: cint;
  apVal: PPsqlite3_value; piRowid: Pi64): cint; cdecl;
var
  pTab   : PTclVtab;
  interp : PTclInterp;
  pEval  : PTclObj;
  rc     : cint;
  pRes   : PTclObj;
  v      : Int64;
begin
  pTab := PTclVtab(tab);
  interp := pTab^.interp;
  pEval := Tcl_DuplicateObj(pTab^.pCmd);
  rc := TCL_OK;

  Tcl_IncrRefCount(pEval);
  Tcl_ListObjAppendElement(interp, pEval,
    Tcl_NewStringObj(PChar('xUpdate'), -1));

  rc := Tcl_EvalObjEx(interp, pEval, TCL_EVAL_GLOBAL);
  Tcl_DecrRefCount(pEval);

  if rc = TCL_OK then
  begin
    pRes := Tcl_GetObjResult(interp);
    v := 0;
    rc := Tcl_GetWideIntFromObj(interp, pRes, @v);
    piRowid^ := v;
  end;

  if rc <> TCL_OK then
  begin
    tab^.zErrMsg := sqlite3PfMprintf('%s',
      [Tcl_GetStringResult(pTab^.interp)]);
    Result := rc;
    Exit;
  end;

  Result := SQLITE_OK;
end;

{ getDbPointer — recover the sqlite3* behind a `db` Tcl command, or
  decode a hex pointer string.  Mirrors test1.c / TestModuleEcho. }
function getDbPointer(interp: PTclInterp; zA: PAnsiChar;
  ppDb: PPTsqlite3): cint;
var
  cmdInfo: TTclCmdInfo;
  z      : PAnsiChar;
  v      : QWord;
  c      : cint;
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

{ test_bestindex.c:918..924 — delTestVtabCtx. }
procedure delTestVtabCtx(p: Pointer); cdecl;
var
  pCtx: PTestVtabContext;
begin
  pCtx := PTestVtabContext(p);
  if pCtx^.pDefault <> nil then
    Tcl_DecrRefCount(pCtx^.pDefault);
  Tcl_Free(PChar(p));
end;

{ test_bestindex.c:929..957 — register_tcl_module. }
function register_tcl_module(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db   : PTsqlite3;
  pMod : Pointer;
  pCtx : PTestVtabContext;
begin
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB ?DEFAULT-CMD?'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;

  pMod := @tclModule;
  pCtx := PTestVtabContext(Tcl_Alloc(SizeOf(TTestVtabContext)));
  pCtx^.interp := interp;
  pCtx^.pDefault := nil;
  if objc = 3 then
  begin
    pCtx^.pDefault := objv[2];
    Tcl_IncrRefCount(pCtx^.pDefault);
  end;

  if objc = 3 then pMod := @tclModuleUpdate;
  sqlite3_create_module_v2(db, PChar('tcl'), pMod, Pointer(pCtx),
    @delTestVtabCtx);

  Result := TCL_OK;
end;

{ test_bestindex.c:965..981 — Sqlitetesttcl_Init. }
function Sqlitetesttcl_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('register_tcl_module'),
    @register_tcl_module, nil, nil);
  Result := TCL_OK;
end;

initialization
  { test_bestindex.c:858..884 — tclModule (no xUpdate). }
  FillChar(tclModule, SizeOf(tclModule), 0);
  tclModule.iVersion      := 0;
  tclModule.xCreate       := @tclConnect;
  tclModule.xConnect      := @tclConnect;
  tclModule.xBestIndex    := @tclBestIndex;
  tclModule.xDisconnect   := @tclDisconnect;
  tclModule.xDestroy      := @tclDisconnect;
  tclModule.xOpen         := @tclOpen;
  tclModule.xClose        := @tclClose;
  tclModule.xFilter       := @tclFilter;
  tclModule.xNext         := @tclNext;
  tclModule.xEof          := @tclEof;
  tclModule.xColumn       := @tclColumn;
  tclModule.xRowid        := @tclRowid;
  tclModule.xFindFunction := @tclFindFunction;

  { test_bestindex.c:885..911 — tclModuleUpdate (with xUpdate). }
  tclModuleUpdate := tclModule;
  tclModuleUpdate.xUpdate := @tclUpdate;
end.
