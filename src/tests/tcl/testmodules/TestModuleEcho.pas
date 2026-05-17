{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/src/test8.c (~1453 lines in C).

  The "echo" virtual table module is a test vtab that proxies a real
  database table (like an SQL VIEW, but read/write).  It is used by the
  vtab*.test corpus.  Two modules are registered: "echo" (iVersion 1)
  and "echo_v2" (iVersion 2, with savepoint methods).

  Public entry: Sqlitetest8_Init(interp) — registers the Tcl commands
  `register_echo_module DB` and `sqlite3_declare_vtab DB SQL`.
}
{$I passqlite3.inc}
unit TestModuleEcho;

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

function Sqlitetest8_Init(interp: PTclInterp): cint; cdecl;

implementation

const
  { tcl.h variable-set flag bits used by appendToEchoModule. }
  TCL_APPEND_VALUE  = 4;
  TCL_LIST_ELEMENT  = 8;

type
  PPSqlite3Vtab       = ^PSqlite3Vtab;
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;
  PPAnsiCharConst     = ^PAnsiChar;
  PCInt               = ^cint;
  PPCInt              = ^PCInt;
  PPPAnsiChar         = ^PPAnsiChar;

  { test8.c:72..85 — struct echo_vtab. }
  PEchoVtab = ^TEchoVtab;
  TEchoVtab = record
    base          : Tsqlite3_vtab;
    interp        : PTclInterp;
    db            : PTsqlite3;
    isPattern     : cint;
    inTransaction : cint;
    zThis         : PAnsiChar;
    zTableName    : PAnsiChar;
    zLogName      : PAnsiChar;
    nCol          : cint;
    aIndex        : PCInt;
    aCol          : PPAnsiChar;
  end;

  { test8.c:88..91 — struct echo_cursor. }
  PEchoCursor = ^TEchoCursor;
  TEchoCursor = record
    base  : Tsqlite3_vtab_cursor;
    pStmt : PVdbe;
  end;

  { test8.c:385..389 — struct EchoModule. }
  PEchoModule = ^TEchoModule;
  TEchoModule = record
    interp : PTclInterp;
    db     : PTsqlite3;
  end;

var
  echoModule   : Tsqlite3_module;
  echoModuleV2 : Tsqlite3_module;

{ test8.c:93..103 — simulateVtabError. }
function simulateVtabError(p: PEchoVtab; zMethod: PAnsiChar): cint;
var
  zErr     : PAnsiChar;
  zVarname : array[0..127] of AnsiChar;
begin
  zVarname[127] := #0;
  sqlite3PfSnprintf(127, @zVarname[0], 'echo_module_fail(%s,%s)',
    [zMethod, p^.zTableName]);
  zErr := Tcl_GetVar(p^.interp, @zVarname[0], TCL_GLOBAL_ONLY);
  if zErr <> nil then
    p^.base.zErrMsg := sqlite3PfMprintf('echo-vtab-error: %s', [zErr]);
  if zErr <> nil then Result := 1 else Result := 0;
end;

{ test8.c:118..143 — dequoteString.  In-place quote removal. }
procedure dequoteString(z: PAnsiChar);
var
  quote : AnsiChar;
  i, j  : cint;
begin
  if z = nil then Exit;
  quote := z[0];
  case quote of
    '''' : ;
    '"'  : ;
    '`'  : ;
    '['  : quote := ']';
  else
    Exit;
  end;
  i := 1; j := 0;
  while z[i] <> #0 do
  begin
    if z[i] = quote then
    begin
      if z[i + 1] = quote then
      begin
        z[j] := quote; Inc(j);
        Inc(i);
      end
      else
      begin
        z[j] := #0; Inc(j);
        Break;
      end;
    end
    else
    begin
      z[j] := z[i]; Inc(j);
    end;
    Inc(i);
  end;
end;

{ test8.c:155..221 — getColumnNames. }
function getColumnNames(db: PTsqlite3; zTab: PAnsiChar;
  paCol: PPPAnsiChar; pnCol: PCInt): cint;
var
  aCol   : PPAnsiChar;
  zSql   : PAnsiChar;
  pStmt  : PVdbe;
  rc     : cint;
  nCol   : cint;
  ii     : cint;
  nBytes : cint;
  zSpace : PAnsiChar;
  zName  : PAnsiChar;
begin
  aCol  := nil;
  pStmt := nil;
  rc    := SQLITE_OK;
  nCol  := 0;

  zSql := sqlite3PfMprintf('SELECT * FROM %Q', [zTab]);
  if zSql = nil then
  begin
    rc := SQLITE_NOMEM;
  end
  else
  begin
    rc := sqlite3_prepare(db, zSql, -1, @pStmt, nil);
    sqlite3_free(zSql);

    if rc = SQLITE_OK then
    begin
      nCol := sqlite3_column_count(pStmt);

      nBytes := SizeOf(PAnsiChar) * nCol;
      ii := 0;
      while ii < nCol do
      begin
        zName := sqlite3_column_name(pStmt, ii);
        if zName = nil then
        begin
          rc := SQLITE_NOMEM;
          Break;
        end;
        nBytes := nBytes + cint(StrLen(zName)) + 1;
        Inc(ii);
      end;

      if rc = SQLITE_OK then
      begin
        aCol := PPAnsiChar(sqlite3MallocZero(nBytes));
        if aCol = nil then
          rc := SQLITE_NOMEM
        else
        begin
          zSpace := PAnsiChar(@aCol[nCol]);
          for ii := 0 to nCol - 1 do
          begin
            aCol[ii] := zSpace;
            sqlite3PfSnprintf(nBytes, zSpace, '%s',
              [sqlite3_column_name(pStmt, ii)]);
            zSpace := zSpace + cint(StrLen(zSpace)) + 1;
          end;
        end;
      end;
    end;
  end;

  paCol^ := aCol;
  pnCol^ := nCol;
  sqlite3_finalize(pStmt);
  Result := rc;
end;

{ test8.c:235..303 — getIndexArray. }
function getIndexArray(db: PTsqlite3; zTab: PAnsiChar;
  nCol: cint; paIndex: PPCInt): cint;
var
  pStmt  : PVdbe;
  aIndex : PCInt;
  rc     : cint;
  rc2    : cint;
  zSql   : PAnsiChar;
  zIdx   : PAnsiChar;
  pStmt2 : PVdbe;
  cid    : cint;
begin
  pStmt  := nil;
  aIndex := nil;
  rc     := SQLITE_OK;

  aIndex := PCInt(sqlite3MallocZero(SizeOf(cint) * nCol));
  if aIndex = nil then
  begin
    rc := SQLITE_NOMEM;
  end
  else
  begin
    zSql := sqlite3PfMprintf('PRAGMA index_list(%s)', [zTab]);
    if zSql = nil then
      rc := SQLITE_NOMEM
    else
    begin
      rc := sqlite3_prepare(db, zSql, -1, @pStmt, nil);
      sqlite3_free(zSql);

      while (pStmt <> nil) and (sqlite3_step(pStmt) = SQLITE_ROW) do
      begin
        zIdx := sqlite3_column_text(pStmt, 1);
        pStmt2 := nil;
        if zIdx = nil then Continue;
        zSql := sqlite3PfMprintf('PRAGMA index_info(%s)', [zIdx]);
        if zSql = nil then
        begin
          rc := SQLITE_NOMEM;
          Break;
        end;
        rc := sqlite3_prepare(db, zSql, -1, @pStmt2, nil);
        sqlite3_free(zSql);
        if (pStmt2 <> nil) and (sqlite3_step(pStmt2) = SQLITE_ROW) then
        begin
          cid := sqlite3_column_int(pStmt2, 1);
          aIndex[cid] := 1;
        end;
        if pStmt2 <> nil then
          rc := sqlite3_finalize(pStmt2);
        if rc <> SQLITE_OK then Break;
      end;
    end;
  end;

  if pStmt <> nil then
  begin
    rc2 := sqlite3_finalize(pStmt);
    if rc = SQLITE_OK then rc := rc2;
  end;
  if rc <> SQLITE_OK then
  begin
    sqlite3_free(aIndex);
    aIndex := nil;
  end;
  paIndex^ := aIndex;
  Result := rc;
end;

{ test8.c:309..312 — appendToEchoModule. }
procedure appendToEchoModule(interp: PTclInterp; zArg: PAnsiChar);
const
  flags = TCL_APPEND_VALUE or TCL_LIST_ELEMENT or TCL_GLOBAL_ONLY;
var
  z: PAnsiChar;
begin
  if zArg <> nil then z := zArg else z := PChar('');
  Tcl_SetVar(interp, PChar('echo_module'), z, flags);
end;

{ test8.c:331..368 — echoDeclareVtab. }
function echoDeclareVtab(pVtab: PEchoVtab; db: PTsqlite3): cint;
var
  rc           : cint;
  rc2          : cint;
  pStmt        : PVdbe;
  zCreateTable : PAnsiChar;
begin
  rc := SQLITE_OK;
  if pVtab^.zTableName <> nil then
  begin
    pStmt := nil;
    rc := sqlite3_prepare(db,
      PChar('SELECT sql FROM sqlite_schema WHERE type = ''table'' AND name = ?'),
      -1, @pStmt, nil);
    if rc = SQLITE_OK then
    begin
      sqlite3_bind_text(pStmt, 1, pVtab^.zTableName, -1, nil);
      if sqlite3_step(pStmt) = SQLITE_ROW then
      begin
        zCreateTable := sqlite3_column_text(pStmt, 0);
        rc := sqlite3_declare_vtab(db, zCreateTable);
        rc2 := sqlite3_finalize(pStmt);
        if rc = SQLITE_OK then rc := rc2;
      end
      else
      begin
        rc := sqlite3_finalize(pStmt);
        if rc = SQLITE_OK then rc := SQLITE_ERROR;
      end;
      if rc = SQLITE_OK then
        rc := getColumnNames(db, pVtab^.zTableName,
          @pVtab^.aCol, @pVtab^.nCol);
      if rc = SQLITE_OK then
        rc := getIndexArray(db, pVtab^.zTableName, pVtab^.nCol,
          @pVtab^.aIndex);
    end;
  end;
  Result := rc;
end;

{ test8.c:374..383 — echoDestructor. }
function echoDestructor(pVtab: PSqlite3Vtab): cint; cdecl;
var
  p: PEchoVtab;
begin
  p := PEchoVtab(pVtab);
  sqlite3_free(p^.aIndex);
  sqlite3_free(p^.aCol);
  sqlite3_free(p^.zThis);
  sqlite3_free(p^.zTableName);
  sqlite3_free(p^.zLogName);
  sqlite3_free(p);
  Result := 0;
end;

{ test8.c:396..456 — echoConstructor. }
function echoConstructor(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint;
var
  rc    : cint;
  i     : cint;
  pVtab : PEchoVtab;
  z     : PAnsiChar;
begin
  pVtab := PEchoVtab(sqlite3MallocZero(SizeOf(TEchoVtab)));
  if pVtab = nil then begin Result := SQLITE_NOMEM; Exit; end;
  pVtab^.interp := PEchoModule(pAux)^.interp;
  pVtab^.db := db;

  pVtab^.zThis := sqlite3PfMprintf('%s', [argv[2]]);
  if pVtab^.zThis = nil then
  begin
    echoDestructor(PSqlite3Vtab(pVtab));
    Result := SQLITE_NOMEM;
    Exit;
  end;

  if argc > 3 then
  begin
    pVtab^.zTableName := sqlite3PfMprintf('%s', [argv[3]]);
    dequoteString(pVtab^.zTableName);
    if (pVtab^.zTableName <> nil) and (pVtab^.zTableName[0] = '*') then
    begin
      z := sqlite3PfMprintf('%s%s', [argv[2], @pVtab^.zTableName[1]]);
      sqlite3_free(pVtab^.zTableName);
      pVtab^.zTableName := z;
      pVtab^.isPattern := 1;
    end;
    if pVtab^.zTableName = nil then
    begin
      echoDestructor(PSqlite3Vtab(pVtab));
      Result := SQLITE_NOMEM;
      Exit;
    end;
  end;

  for i := 0 to argc - 1 do
    appendToEchoModule(pVtab^.interp, argv[i]);

  rc := echoDeclareVtab(pVtab, db);
  if rc <> SQLITE_OK then
  begin
    echoDestructor(PSqlite3Vtab(pVtab));
    Result := rc;
    Exit;
  end;

  ppVtab^ := @pVtab^.base;
  Result := SQLITE_OK;
end;

{ test8.c:461..504 — echoCreate. }
function echoCreate(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
var
  rc    : cint;
  zSql  : PAnsiChar;
  pVtab : PEchoVtab;
begin
  rc := SQLITE_OK;
  appendToEchoModule(PEchoModule(pAux)^.interp, PChar('xCreate'));
  rc := echoConstructor(db, pAux, argc, argv, ppVtab, pzErr);

  if (rc = SQLITE_OK) and (argc = 5) then
  begin
    pVtab := PEchoVtab(ppVtab^);
    pVtab^.zLogName := sqlite3PfMprintf('%s', [argv[4]]);
    zSql := sqlite3PfMprintf('CREATE TABLE %Q(logmsg)', [pVtab^.zLogName]);
    rc := sqlite3_exec(db, zSql, nil, nil, nil);
    sqlite3_free(zSql);
    if rc <> SQLITE_OK then
      pzErr^ := sqlite3PfMprintf('%s', [sqlite3_errmsg(db)]);
  end;

  if (ppVtab^ <> nil) and (rc <> SQLITE_OK) then
  begin
    echoDestructor(ppVtab^);
    ppVtab^ := nil;
  end;

  if rc = SQLITE_OK then
    PEchoVtab(ppVtab^)^.inTransaction := 1;

  Result := rc;
end;

{ test8.c:509..518 — echoConnect. }
function echoConnect(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
begin
  appendToEchoModule(PEchoModule(pAux)^.interp, PChar('xConnect'));
  Result := echoConstructor(db, pAux, argc, argv, ppVtab, pzErr);
end;

{ test8.c:523..526 — echoDisconnect. }
function echoDisconnect(pVtab: PSqlite3Vtab): cint; cdecl;
begin
  appendToEchoModule(PEchoVtab(pVtab)^.interp, PChar('xDisconnect'));
  Result := echoDestructor(pVtab);
end;

{ test8.c:531..548 — echoDestroy. }
function echoDestroy(pVtab: PSqlite3Vtab): cint; cdecl;
var
  rc   : cint;
  p    : PEchoVtab;
  zSql : PAnsiChar;
begin
  rc := SQLITE_OK;
  p := PEchoVtab(pVtab);
  appendToEchoModule(PEchoVtab(pVtab)^.interp, PChar('xDestroy'));

  if (p <> nil) and (p^.zLogName <> nil) then
  begin
    zSql := sqlite3PfMprintf('DROP TABLE %Q', [p^.zLogName]);
    rc := sqlite3_exec(p^.db, zSql, nil, nil, nil);
    sqlite3_free(zSql);
  end;

  if rc = SQLITE_OK then
    rc := echoDestructor(pVtab);
  Result := rc;
end;

{ test8.c:553..561 — echoOpen. }
function echoOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): cint; cdecl;
var
  pCur: PEchoCursor;
begin
  if simulateVtabError(PEchoVtab(pVTab), PChar('xOpen')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;
  pCur := PEchoCursor(sqlite3MallocZero(SizeOf(TEchoCursor)));
  ppCursor^ := PSqlite3VtabCursor(pCur);
  if pCur <> nil then Result := SQLITE_OK else Result := SQLITE_NOMEM;
end;

{ test8.c:566..574 — echoClose. }
function echoClose(cur: PSqlite3VtabCursor): cint; cdecl;
var
  rc    : cint;
  pCur  : PEchoCursor;
  pStmt : PVdbe;
begin
  pCur := PEchoCursor(cur);
  pStmt := pCur^.pStmt;
  pCur^.pStmt := nil;
  sqlite3_free(pCur);
  rc := sqlite3_finalize(pStmt);
  Result := rc;
end;

{ test8.c:580..582 — echoEof. }
function echoEof(cur: PSqlite3VtabCursor): cint; cdecl;
begin
  if PEchoCursor(cur)^.pStmt <> nil then Result := 0 else Result := 1;
end;

{ test8.c:587..606 — echoNext. }
function echoNext(cur: PSqlite3VtabCursor): cint; cdecl;
var
  rc   : cint;
  pCur : PEchoCursor;
begin
  rc := SQLITE_OK;
  pCur := PEchoCursor(cur);

  if simulateVtabError(PEchoVtab(cur^.pVtab), PChar('xNext')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  if pCur^.pStmt <> nil then
  begin
    rc := sqlite3_step(pCur^.pStmt);
    if rc = SQLITE_ROW then
      rc := SQLITE_OK
    else
    begin
      rc := sqlite3_finalize(pCur^.pStmt);
      pCur^.pStmt := nil;
    end;
  end;

  Result := rc;
end;

{ test8.c:611..626 — echoColumn. }
function echoColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: cint): cint; cdecl;
var
  iCol  : cint;
  pStmt : PVdbe;
begin
  iCol := i + 1;
  pStmt := PEchoCursor(cur)^.pStmt;

  if simulateVtabError(PEchoVtab(cur^.pVtab), PChar('xColumn')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  if pStmt = nil then
    sqlite3_result_null(ctx)
  else
    sqlite3_result_value(ctx, sqlite3_column_value(pStmt, iCol));
  Result := SQLITE_OK;
end;

{ test8.c:631..640 — echoRowid. }
function echoRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): cint; cdecl;
var
  pStmt: PVdbe;
begin
  pStmt := PEchoCursor(cur)^.pStmt;

  if simulateVtabError(PEchoVtab(cur^.pVtab), PChar('xRowid')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  pRowid^ := sqlite3_column_int64(pStmt, 0);
  Result := SQLITE_OK;
end;

{ test8.c:651..658 — hashString. }
function hashString(zString: PAnsiChar): cint;
var
  val : u32;
  ii  : cint;
begin
  val := 0;
  ii := 0;
  while zString[ii] <> #0 do
  begin
    val := (val shl 3) + u32(cint(Ord(zString[ii])));
    Inc(ii);
  end;
  Result := cint(val and $7fffffff);
end;

{ test8.c:663..707 — echoFilter. }
function echoFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PAnsiChar;
  argc: cint; argv: PPsqlite3_value): cint; cdecl;
var
  rc    : cint;
  i     : cint;
  pCur  : PEchoCursor;
  pVtab : PEchoVtab;
  db    : PTsqlite3;
begin
  pCur := PEchoCursor(pVtabCursor);
  pVtab := PEchoVtab(pVtabCursor^.pVtab);
  db := pVtab^.db;

  if simulateVtabError(pVtab, PChar('xFilter')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  appendToEchoModule(pVtab^.interp, PChar('xFilter'));
  appendToEchoModule(pVtab^.interp, idxStr);
  for i := 0 to argc - 1 do
    appendToEchoModule(pVtab^.interp, sqlite3_value_text(argv[i]));

  sqlite3_finalize(pCur^.pStmt);
  pCur^.pStmt := nil;

  rc := sqlite3_prepare(db, idxStr, -1, @pCur^.pStmt, nil);
  i := 0;
  while (rc = SQLITE_OK) and (i < argc) do
  begin
    rc := sqlite3_bind_value(pCur^.pStmt, i + 1, argv[i]);
    Inc(i);
  end;

  if rc = SQLITE_OK then
    rc := echoNext(pVtabCursor);

  Result := rc;
end;

{ test8.c:723..747 — string_concat. }
procedure string_concat(pzStr: PPAnsiChar; zAppend: PAnsiChar;
  doFree: cint; pRc: PCInt);
var
  zIn   : PAnsiChar;
  zTemp : PAnsiChar;
begin
  zIn := pzStr^;
  if (zAppend = nil) and (doFree <> 0) and (pRc^ = SQLITE_OK) then
    pRc^ := SQLITE_NOMEM;
  if pRc^ <> SQLITE_OK then
  begin
    sqlite3_free(zIn);
    zIn := nil;
  end
  else
  begin
    if zIn <> nil then
    begin
      zTemp := zIn;
      zIn := sqlite3PfMprintf('%s%s', [zIn, zAppend]);
      sqlite3_free(zTemp);
    end
    else
      zIn := sqlite3PfMprintf('%s', [zAppend]);
    if zIn = nil then
      pRc^ := SQLITE_NOMEM;
  end;
  pzStr^ := zIn;
  if doFree <> 0 then
    sqlite3_free(zAppend);
end;

{ test8.c:759..775 — echoSelectList. }
function echoSelectList(pTab: PEchoVtab;
  pIdxInfo: PSqlite3IndexInfo): PAnsiChar;
var
  zRet  : PAnsiChar;
  zPrev : PAnsiChar;
  i     : cint;
  bit   : cint;
begin
  zRet := nil;
  if sqlite3_libversion_number < 3010000 then
    zRet := sqlite3PfMprintf(', *', [])
  else
  begin
    for i := 0 to pTab^.nCol - 1 do
    begin
      if i >= 63 then bit := 63 else bit := i;
      zPrev := zRet;
      { Pascal %z does not free its arg (unlike C); do it explicitly. }
      if (pIdxInfo^.colUsed and (u64(1) shl bit)) <> 0 then
        zRet := sqlite3PfMprintf('%z, %s', [zRet, pTab^.aCol[i]])
      else
        zRet := sqlite3PfMprintf('%z, NULL', [zRet]);
      sqlite3_free(zPrev);
      if zRet = nil then Break;
    end;
  end;
  Result := zRet;
end;

{ test8.c:799..949 — echoBestIndex. }
function echoBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): cint; cdecl;
var
  ii            : cint;
  zQuery        : PAnsiChar;
  zCol          : PAnsiChar;
  zNew          : PAnsiChar;
  nArg          : cint;
  zSep          : PAnsiChar;
  pVtab         : PEchoVtab;
  pStmt         : PVdbe;
  interp        : PTclInterp;
  nRow          : cint;
  useIdx        : cint;
  rc            : cint;
  useCost       : cint;
  cost          : Double;
  isIgnoreUsable: cint;
  pConstraint   : PSqlite3IndexConstraint;
  pUsage        : PSqlite3IndexConstraintUsage;
  iCol          : cint;
  zNewCol       : PAnsiChar;
  zOp           : PAnsiChar;
  zDir          : PAnsiChar;
  pOrderBy      : PSqlite3IndexOrderBy;
begin
  zQuery := nil;
  zCol := nil;
  nArg := 0;
  zSep := PChar('WHERE');
  pVtab := PEchoVtab(tab);
  pStmt := nil;
  interp := pVtab^.interp;
  nRow := 0;
  useIdx := 0;
  rc := SQLITE_OK;
  useCost := 0;
  cost := 0;
  isIgnoreUsable := 0;
  if Tcl_GetVar(interp, PChar('echo_module_ignore_usable'),
       TCL_GLOBAL_ONLY) <> nil then
    isIgnoreUsable := 1;

  if simulateVtabError(pVtab, PChar('xBestIndex')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  if Tcl_GetVar(interp, PChar('echo_module_cost'), TCL_GLOBAL_ONLY) <> nil then
  begin
    cost := StrToFloatDef(string(Tcl_GetVar(interp,
      PChar('echo_module_cost'), TCL_GLOBAL_ONLY)), 0);
    useCost := 1;
  end
  else
  begin
    zQuery := sqlite3PfMprintf('SELECT count(*) FROM %Q',
      [pVtab^.zTableName]);
    if zQuery = nil then begin Result := SQLITE_NOMEM; Exit; end;
    rc := sqlite3_prepare(pVtab^.db, zQuery, -1, @pStmt, nil);
    sqlite3_free(zQuery);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    sqlite3_step(pStmt);
    nRow := sqlite3_column_int(pStmt, 0);
    rc := sqlite3_finalize(pStmt);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  zCol := echoSelectList(pVtab, pIdxInfo);
  if zCol = nil then begin Result := SQLITE_NOMEM; Exit; end;
  { Pascal %z does not free its arg (unlike C); free zCol explicitly. }
  zQuery := sqlite3PfMprintf('SELECT rowid%z FROM %Q', [zCol,
    pVtab^.zTableName]);
  sqlite3_free(zCol);
  if zQuery = nil then begin Result := SQLITE_NOMEM; Exit; end;

  for ii := 0 to pIdxInfo^.nConstraint - 1 do
  begin
    pConstraint := pIdxInfo^.aConstraint;
    Inc(pConstraint, ii);
    pUsage := pIdxInfo^.aConstraintUsage;
    Inc(pUsage, ii);

    if (isIgnoreUsable = 0) and (pConstraint^.usable = 0) then Continue;

    iCol := pConstraint^.iColumn;
    if (iCol < 0) or (pVtab^.aIndex[iCol] <> 0) then
    begin
      if iCol >= 0 then zNewCol := pVtab^.aCol[iCol]
      else zNewCol := PChar('rowid');
      zOp := nil;
      useIdx := 1;
      case pConstraint^.op of
        SQLITE_INDEX_CONSTRAINT_EQ:     zOp := PChar('=');
        SQLITE_INDEX_CONSTRAINT_LT:     zOp := PChar('<');
        SQLITE_INDEX_CONSTRAINT_GT:     zOp := PChar('>');
        SQLITE_INDEX_CONSTRAINT_LE:     zOp := PChar('<=');
        SQLITE_INDEX_CONSTRAINT_GE:     zOp := PChar('>=');
        SQLITE_INDEX_CONSTRAINT_MATCH:  zOp := PChar('LIKE');
        SQLITE_INDEX_CONSTRAINT_LIKE:   zOp := PChar('like');
        SQLITE_INDEX_CONSTRAINT_GLOB:   zOp := PChar('glob');
        SQLITE_INDEX_CONSTRAINT_REGEXP: zOp := PChar('regexp');
      end;
      if zOp <> nil then
      begin
        if zOp[0] = 'L' then
          zNew := sqlite3PfMprintf(
            ' %s %s LIKE (SELECT ''%%''||?||''%%'')', [zSep, zNewCol])
        else
          zNew := sqlite3PfMprintf(' %s %s %s ?', [zSep, zNewCol, zOp]);
        string_concat(@zQuery, zNew, 1, @rc);
        zSep := PChar('AND');
        Inc(nArg);
        pUsage^.argvIndex := nArg;
        pUsage^.omit := 1;
      end;
    end;
  end;

  if (pIdxInfo^.nOrderBy = 1) then
  begin
    pOrderBy := pIdxInfo^.aOrderBy;
    if (pOrderBy^.iColumn < 0) or (pVtab^.aIndex[pOrderBy^.iColumn] <> 0) then
    begin
      iCol := pOrderBy^.iColumn;
      if iCol >= 0 then zNewCol := pVtab^.aCol[iCol]
      else zNewCol := PChar('rowid');
      if pOrderBy^.desc <> 0 then zDir := PChar('DESC')
      else zDir := PChar('ASC');
      zNew := sqlite3PfMprintf(' ORDER BY %s %s', [zNewCol, zDir]);
      string_concat(@zQuery, zNew, 1, @rc);
      pIdxInfo^.orderByConsumed := 1;
    end;
  end;

  appendToEchoModule(pVtab^.interp, PChar('xBestIndex'));
  appendToEchoModule(pVtab^.interp, zQuery);

  if zQuery = nil then begin Result := rc; Exit; end;
  pIdxInfo^.idxNum := hashString(zQuery);
  pIdxInfo^.idxStr := zQuery;
  pIdxInfo^.needToFreeIdxStr := 1;
  if useCost <> 0 then
    pIdxInfo^.estimatedCost := cost
  else if useIdx <> 0 then
  begin
    for ii := 0 to (SizeOf(cint) * 8) - 2 do
      if (nRow and (1 shl ii)) <> 0 then
        pIdxInfo^.estimatedCost := Double(ii);
  end
  else
    pIdxInfo^.estimatedCost := Double(nRow);
  Result := rc;
end;

{ test8.c:965..1091 — echoUpdate. }
function echoUpdate(tab: PSqlite3Vtab; nData: cint;
  apData: PPsqlite3_value; pRowid: Pi64): cint; cdecl;
var
  pVtab       : PEchoVtab;
  db          : PTsqlite3;
  rc          : cint;
  pStmt       : PVdbe;
  z           : PAnsiChar;
  bindArgZero : cint;
  bindArgOne  : cint;
  i           : cint;
  zSep        : PAnsiChar;
  ii          : cint;
  zInsert     : PAnsiChar;
  zValues     : PAnsiChar;
begin
  pVtab := PEchoVtab(tab);
  db := pVtab^.db;
  rc := SQLITE_OK;
  pStmt := nil;
  z := nil;
  bindArgZero := 0;
  bindArgOne := 0;

  if simulateVtabError(pVtab, PChar('xUpdate')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  { UPDATE }
  if (nData > 1) and (sqlite3_value_type(apData[0]) = SQLITE_INTEGER) then
  begin
    zSep := PChar(' SET');
    z := sqlite3PfMprintf('UPDATE %Q', [pVtab^.zTableName]);
    if z = nil then rc := SQLITE_NOMEM;

    if (apData[1] <> nil) and
       (sqlite3_value_type(apData[1]) = SQLITE_INTEGER) then
      bindArgOne := 1
    else
      bindArgOne := 0;
    bindArgZero := 1;

    if bindArgOne <> 0 then
    begin
      string_concat(@z, PChar(' SET rowid=?1 '), 0, @rc);
      zSep := PChar(',');
    end;
    for i := 2 to nData - 1 do
    begin
      if apData[i] = nil then Continue;
      string_concat(@z, sqlite3PfMprintf('%s %Q=?%d',
        [zSep, pVtab^.aCol[i - 2], i]), 1, @rc);
      zSep := PChar(',');
    end;
    string_concat(@z, sqlite3PfMprintf(' WHERE rowid=?%d', [nData]),
      1, @rc);
  end

  { DELETE }
  else if (nData = 1) and
          (sqlite3_value_type(apData[0]) = SQLITE_INTEGER) then
  begin
    z := sqlite3PfMprintf('DELETE FROM %Q WHERE rowid = ?1',
      [pVtab^.zTableName]);
    if z = nil then rc := SQLITE_NOMEM;
    bindArgZero := 1;
  end

  { INSERT }
  else if (nData > 2) and (sqlite3_value_type(apData[0]) = SQLITE_NULL) then
  begin
    zInsert := nil;
    zValues := nil;

    zInsert := sqlite3PfMprintf('INSERT INTO %Q (', [pVtab^.zTableName]);
    if zInsert = nil then rc := SQLITE_NOMEM;
    if sqlite3_value_type(apData[1]) = SQLITE_INTEGER then
    begin
      bindArgOne := 1;
      zValues := sqlite3PfMprintf('?', []);
      string_concat(@zInsert, PChar('rowid'), 0, @rc);
    end;

    for ii := 2 to nData - 1 do
    begin
      if zValues <> nil then
        string_concat(@zInsert, sqlite3PfMprintf('%s%Q',
          [PChar(', '), pVtab^.aCol[ii - 2]]), 1, @rc)
      else
        string_concat(@zInsert, sqlite3PfMprintf('%s%Q',
          [PChar(''), pVtab^.aCol[ii - 2]]), 1, @rc);
      if zValues <> nil then
        string_concat(@zValues, sqlite3PfMprintf('%s?%d',
          [PChar(', '), ii]), 1, @rc)
      else
        string_concat(@zValues, sqlite3PfMprintf('%s?%d',
          [PChar(''), ii]), 1, @rc);
    end;

    string_concat(@z, zInsert, 1, @rc);
    string_concat(@z, PChar(') VALUES('), 0, @rc);
    string_concat(@z, zValues, 1, @rc);
    string_concat(@z, PChar(')'), 0, @rc);
  end

  { Anything else is an error }
  else
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  if rc = SQLITE_OK then
    rc := sqlite3_prepare(db, z, -1, @pStmt, nil);
  sqlite3_free(z);
  if rc = SQLITE_OK then
  begin
    if bindArgZero <> 0 then
      sqlite3_bind_value(pStmt, nData, apData[0]);
    if bindArgOne <> 0 then
      sqlite3_bind_value(pStmt, 1, apData[1]);
    i := 2;
    while (i < nData) and (rc = SQLITE_OK) do
    begin
      if apData[i] <> nil then
        rc := sqlite3_bind_value(pStmt, i, apData[i]);
      Inc(i);
    end;
    if rc = SQLITE_OK then
    begin
      sqlite3_step(pStmt);
      rc := sqlite3_finalize(pStmt);
    end
    else
      sqlite3_finalize(pStmt);
  end;

  if (pRowid <> nil) and (rc = SQLITE_OK) then
    pRowid^ := sqlite3_last_insert_rowid(db);
  if rc <> SQLITE_OK then
    tab^.zErrMsg := sqlite3PfMprintf('echo-vtab-error: %s',
      [sqlite3_errmsg(db)]);

  Result := rc;
end;

{ test8.c:1098..1107 — echoTransactionCall. }
function echoTransactionCall(tab: PSqlite3Vtab; zCall: PAnsiChar): cint;
var
  z     : PAnsiChar;
  pVtab : PEchoVtab;
begin
  pVtab := PEchoVtab(tab);
  z := sqlite3PfMprintf('echo(%s)', [pVtab^.zTableName]);
  if z = nil then begin Result := SQLITE_NOMEM; Exit; end;
  appendToEchoModule(pVtab^.interp, zCall);
  appendToEchoModule(pVtab^.interp, z);
  sqlite3_free(z);
  Result := SQLITE_OK;
end;

{ test8.c:1108..1138 — echoBegin. }
function echoBegin(tab: PSqlite3Vtab): cint; cdecl;
var
  rc     : cint;
  pVtab  : PEchoVtab;
  interp : PTclInterp;
  zVal   : PAnsiChar;
begin
  pVtab := PEchoVtab(tab);
  interp := pVtab^.interp;

  if simulateVtabError(pVtab, PChar('xBegin')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  rc := echoTransactionCall(tab, PChar('xBegin'));

  if rc = SQLITE_OK then
  begin
    zVal := Tcl_GetVar(interp, PChar('echo_module_begin_fail'),
      TCL_GLOBAL_ONLY);
    if (zVal <> nil) and (StrComp(zVal, pVtab^.zTableName) = 0) then
      rc := SQLITE_ERROR;
  end;
  if rc = SQLITE_OK then
    pVtab^.inTransaction := 1;
  Result := rc;
end;

{ test8.c:1139..1166 — echoSync. }
function echoSync(tab: PSqlite3Vtab): cint; cdecl;
var
  rc     : cint;
  pVtab  : PEchoVtab;
  interp : PTclInterp;
  zVal   : PAnsiChar;
begin
  pVtab := PEchoVtab(tab);
  interp := pVtab^.interp;

  if simulateVtabError(pVtab, PChar('xSync')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  rc := echoTransactionCall(tab, PChar('xSync'));

  if rc = SQLITE_OK then
  begin
    zVal := Tcl_GetVar(interp, PChar('echo_module_sync_fail'),
      TCL_GLOBAL_ONLY);
    if (zVal <> nil) and (StrComp(zVal, pVtab^.zTableName) = 0) then
      rc := -1;
  end;
  Result := rc;
end;

{ test8.c:1167..1184 — echoCommit. }
function echoCommit(tab: PSqlite3Vtab): cint; cdecl;
var
  pVtab : PEchoVtab;
  rc    : cint;
begin
  pVtab := PEchoVtab(tab);

  if simulateVtabError(pVtab, PChar('xCommit')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  rc := echoTransactionCall(tab, PChar('xCommit'));
  pVtab^.inTransaction := 0;
  Result := rc;
end;

{ test8.c:1185..1196 — echoRollback. }
function echoRollback(tab: PSqlite3Vtab): cint; cdecl;
var
  rc    : cint;
  pVtab : PEchoVtab;
begin
  pVtab := PEchoVtab(tab);
  rc := echoTransactionCall(tab, PChar('xRollback'));
  pVtab^.inTransaction := 0;
  Result := rc;
end;

{ test8.c:1203..1226 — overloadedGlobFunction. }
procedure overloadedGlobFunction(pContext: Psqlite3_context;
  nArg: cint; apArg: PPsqlite3_value); cdecl;
var
  interp : PTclInterp;
  str    : TTclDString;
  i      : cint;
  rc     : cint;
begin
  interp := PTclInterp(sqlite3_user_data(pContext));
  Tcl_DStringInit(@str);
  Tcl_DStringAppendElement(@str, PChar('::echo_glob_overload'));
  for i := 0 to nArg - 1 do
    Tcl_DStringAppendElement(@str, sqlite3_value_text(apArg[i]));
  rc := Tcl_Eval(interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);
  if rc <> 0 then
    sqlite3_result_error(pContext, Tcl_GetStringResult(interp), -1)
  else
    sqlite3_result_text(pContext, Tcl_GetStringResult(interp), -1,
      SQLITE_TRANSIENT);
  Tcl_ResetResult(interp);
end;

{ test8.c:1236..1255 — echoFindFunction. }
function echoFindFunction(vtab: PSqlite3Vtab; nArg: cint;
  zFuncName: PAnsiChar; pxFunc: PPointer; ppArg: PPointer): cint; cdecl;
var
  pVtab  : PEchoVtab;
  interp : PTclInterp;
  info   : TTclCmdInfo;
begin
  pVtab := PEchoVtab(vtab);
  interp := pVtab^.interp;
  if StrComp(zFuncName, PChar('glob')) <> 0 then
  begin
    Result := 0;
    Exit;
  end;
  if Tcl_GetCommandInfo(interp, PChar('::echo_glob_overload'), @info) = 0 then
  begin
    Result := 0;
    Exit;
  end;
  pxFunc^ := @overloadedGlobFunction;
  ppArg^ := interp;
  Result := 1;
end;

{ test8.c:1257..1275 — echoRename. }
function echoRename(vtab: PSqlite3Vtab; zNewName: PAnsiChar): cint; cdecl;
var
  rc    : cint;
  p     : PEchoVtab;
  nThis : cint;
  zSql  : PAnsiChar;
begin
  rc := SQLITE_OK;
  p := PEchoVtab(vtab);

  if simulateVtabError(p, PChar('xRename')) <> 0 then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  if p^.isPattern <> 0 then
  begin
    nThis := cint(StrLen(p^.zThis));
    zSql := sqlite3PfMprintf('ALTER TABLE %s RENAME TO %s%s',
      [p^.zTableName, zNewName, @p^.zTableName[nThis]]);
    rc := sqlite3_exec(p^.db, zSql, nil, nil, nil);
    sqlite3_free(zSql);
  end;

  Result := rc;
end;

{ test8.c:1277..1290 — echoSavepoint / echoRelease / echoRollbackTo. }
function echoSavepoint(pVTab: PSqlite3Vtab; iSavepoint: cint): cint; cdecl;
begin
  Result := SQLITE_OK;
end;

function echoRelease(pVTab: PSqlite3Vtab; iSavepoint: cint): cint; cdecl;
begin
  Result := SQLITE_OK;
end;

function echoRollbackTo(pVTab: PSqlite3Vtab; iSavepoint: cint): cint; cdecl;
begin
  Result := SQLITE_OK;
end;

{ test8.c:1356.. — sqlite3ErrName.  Minimal subset for the rc values the
  echo module can return through register_echo_module. }
function echoErrName(rc: cint): PAnsiChar;
begin
  case rc of
    SQLITE_OK:       Result := PChar('SQLITE_OK');
    SQLITE_ERROR:    Result := PChar('SQLITE_ERROR');
    SQLITE_NOMEM:    Result := PChar('SQLITE_NOMEM');
    SQLITE_MISUSE:   Result := PChar('SQLITE_MISUSE');
    SQLITE_BUSY:     Result := PChar('SQLITE_BUSY');
  else
    Result := PChar('SQLITE_ERROR');
  end;
end;

{ test8.c:1358..1363 — moduleDestroy. }
procedure moduleDestroy(p: Pointer); cdecl;
var
  pMod: PEchoModule;
begin
  pMod := PEchoModule(p);
  sqlite3_create_function(pMod^.db,
    PChar('function_that_does_not_exist_0982ma98'),
    1, SQLITE_ANY, nil, nil, nil, nil);
  sqlite3_free(p);
end;

{ getDbPointer — recover the sqlite3* behind a `db` Tcl command, or
  decode a "%p" hex string into a sqlite3* pointer.  Mirrors test1.c
  getDbPointer (test1.c:112..123): tkt3080.test passes the connection
  via `register_echo_module [sqlite3_connection_pointer db]`, which
  hands a hex string — without the hex fallback we silently failed
  with no diagnostic, killing ifcapable-vtab tail (9.4.divbug.89.012). }
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
    { test1.c:57..76 sqlite3TestTextToPtr — decode 0x-prefixed hex. }
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

{ test8.c:1368..1403 — register_echo_module. }
function register_echo_module(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc   : cint;
  db   : PTsqlite3;
  pMod : PEchoModule;
begin
  if objc <> 2 then
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
  if db = nil then begin Result := TCL_ERROR; Exit; end;

  pMod := PEchoModule(sqlite3_malloc(SizeOf(TEchoModule)));
  pMod^.interp := interp;
  pMod^.db := db;
  rc := sqlite3_create_module_v2(db, PChar('echo'), @echoModule,
    pMod, @moduleDestroy);

  if rc = SQLITE_OK then
  begin
    pMod := PEchoModule(sqlite3_malloc(SizeOf(TEchoModule)));
    pMod^.interp := interp;
    pMod^.db := db;
    rc := sqlite3_create_module_v2(db, PChar('echo_v2'), @echoModuleV2,
      pMod, @moduleDestroy);
  end;

  Tcl_SetResult(interp, echoErrName(rc), TCL_STATIC);
  Result := TCL_OK;
end;

{ test8.c:1410..1429 — declare_vtab. }
function declare_vtab(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db : PTsqlite3;
  rc : cint;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB SQL'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  rc := sqlite3_declare_vtab(db, Tcl_GetString(objv[2]));
  if rc <> SQLITE_OK then
  begin
    Tcl_SetResult(interp, sqlite3_errmsg(db), Pointer(1));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
end;

{ test8.c:1436..1453 — Sqlitetest8_Init. }
function Sqlitetest8_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('register_echo_module'),
    @register_echo_module, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_declare_vtab'),
    @declare_vtab, nil, nil);
  Result := TCL_OK;
end;

initialization
  { test8.c:1296..1322 — echoModule (iVersion 1). }
  FillChar(echoModule, SizeOf(echoModule), 0);
  echoModule.iVersion      := 1;
  echoModule.xCreate       := @echoCreate;
  echoModule.xConnect      := @echoConnect;
  echoModule.xBestIndex    := @echoBestIndex;
  echoModule.xDisconnect   := @echoDisconnect;
  echoModule.xDestroy      := @echoDestroy;
  echoModule.xOpen         := @echoOpen;
  echoModule.xClose        := @echoClose;
  echoModule.xFilter       := @echoFilter;
  echoModule.xNext         := @echoNext;
  echoModule.xEof          := @echoEof;
  echoModule.xColumn       := @echoColumn;
  echoModule.xRowid        := @echoRowid;
  echoModule.xUpdate       := @echoUpdate;
  echoModule.xBegin        := @echoBegin;
  echoModule.xSync         := @echoSync;
  echoModule.xCommit       := @echoCommit;
  echoModule.xRollback     := @echoRollback;
  echoModule.xFindFunction := @echoFindFunction;
  echoModule.xRename       := @echoRename;

  { test8.c:1324..1350 — echoModuleV2 (iVersion 2, with savepoints). }
  echoModuleV2 := echoModule;
  echoModuleV2.iVersion    := 2;
  echoModuleV2.xSavepoint  := @echoSavepoint;
  echoModuleV2.xRelease    := @echoRelease;
  echoModuleV2.xRollbackTo := @echoRollbackTo;
end.
</content>
</invoke>
