{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/src/test_schema.c (367 lines in C).

  The "schema" virtual table module provides a read-only view of the
  current database schema.  There is one row per column of every table
  in the connection.  It is used by vtab2.test.

  Public entry: Sqlitetestschema_Init(interp) — registers the Tcl
  command `register_schema_module DB`.
}
{$I passqlite3.inc}
unit TestModuleSchema;

interface

uses
  ctypes,
  strings,
  PasTclBridge,
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function Sqlitetestschema_Init(interp: PTclInterp): cint; cdecl;

implementation

type
  PPSqlite3Vtab       = ^PSqlite3Vtab;
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;
  Psqlite_int64       = ^Tsqlite_int64;
  Tsqlite_int64       = i64;

  { test_schema.c:52..56 — struct schema_vtab. }
  PSchemaVtab = ^TSchemaVtab;
  TSchemaVtab = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
  end;

  { test_schema.c:58..65 — struct schema_cursor. }
  PSchemaCursor = ^TSchemaCursor;
  TSchemaCursor = record
    base        : Tsqlite3_vtab_cursor;
    pDbList     : PVdbe;
    pTableList  : PVdbe;
    pColumnList : PVdbe;
    rowid       : cint;
  end;

const
  { test_schema.c:21..31 — #define SCHEMA. }
  SCHEMA =
    'CREATE TABLE x(' +
      'database,' +
      'tablename,' +
      'cid,' +
      'name,' +
      'type,' +
      'not_null,' +
      'dflt_value,' +
      'pk' +
    ')';

var
  schemaModule : Tsqlite3_module;

{ test_schema.c:75..78 — schemaDestroy. }
function schemaDestroy(pVtab: PSqlite3Vtab): cint; cdecl;
begin
  sqlite3_free(pVtab);
  Result := 0;
end;

{ test_schema.c:83..101 — schemaCreate. }
function schemaCreate(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
var
  rc    : cint;
  pVtab : PSchemaVtab;
begin
  rc := SQLITE_NOMEM;
  pVtab := PSchemaVtab(sqlite3_malloc(SizeOf(TSchemaVtab)));
  if pVtab <> nil then
  begin
    FillChar(pVtab^, SizeOf(TSchemaVtab), 0);
    pVtab^.db := db;
    rc := sqlite3_declare_vtab(db, PChar(SCHEMA));
  end;
  ppVtab^ := PSqlite3Vtab(pVtab);
  Result := rc;
end;

{ test_schema.c:106..116 — schemaOpen. }
function schemaOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): cint; cdecl;
var
  rc   : cint;
  pCur : PSchemaCursor;
begin
  rc := SQLITE_NOMEM;
  pCur := PSchemaCursor(sqlite3_malloc(SizeOf(TSchemaCursor)));
  if pCur <> nil then
  begin
    FillChar(pCur^, SizeOf(TSchemaCursor), 0);
    ppCursor^ := PSqlite3VtabCursor(pCur);
    rc := SQLITE_OK;
  end;
  Result := rc;
end;

{ test_schema.c:121..128 — schemaClose. }
function schemaClose(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur : PSchemaCursor;
begin
  pCur := PSchemaCursor(cur);
  sqlite3_finalize(pCur^.pDbList);
  sqlite3_finalize(pCur^.pTableList);
  sqlite3_finalize(pCur^.pColumnList);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ test_schema.c:133..147 — schemaColumn. }
function schemaColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: cint): cint; cdecl;
var
  pCur : PSchemaCursor;
begin
  pCur := PSchemaCursor(cur);
  case i of
    0:
      sqlite3_result_value(ctx, sqlite3_column_value(pCur^.pDbList, 1));
    1:
      sqlite3_result_value(ctx, sqlite3_column_value(pCur^.pTableList, 0));
  else
    sqlite3_result_value(ctx, sqlite3_column_value(pCur^.pColumnList, i - 2));
  end;
  Result := SQLITE_OK;
end;

{ test_schema.c:152..156 — schemaRowid. }
function schemaRowid(cur: PSqlite3VtabCursor; pRowid: Psqlite_int64): cint; cdecl;
var
  pCur : PSchemaCursor;
begin
  pCur := PSchemaCursor(cur);
  pRowid^ := pCur^.rowid;
  Result := SQLITE_OK;
end;

{ test_schema.c:158..162 — finalize helper. }
function schemaFinalizeStmt(ppStmt: PPointer): cint;
begin
  Result := sqlite3_finalize(PVdbe(ppStmt^));
  ppStmt^ := nil;
end;

{ test_schema.c:164..167 — schemaEof. }
function schemaEof(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur : PSchemaCursor;
begin
  pCur := PSchemaCursor(cur);
  if pCur^.pDbList <> nil then Result := 0 else Result := 1;
end;

{ test_schema.c:172..238 — schemaNext. }
function schemaNext(cur: PSqlite3VtabCursor): cint; cdecl;
var
  rc      : cint;
  pCur    : PSchemaCursor;
  pVtab   : PSchemaVtab;
  zSql    : PAnsiChar;
  pDbList : PVdbe;
  done    : Boolean;
label
  next_exit;
begin
  rc := SQLITE_OK;
  pCur := PSchemaCursor(cur);
  pVtab := PSchemaVtab(cur^.pVtab);
  zSql := nil;

  while (pCur^.pColumnList = nil) or
        (sqlite3_step(pCur^.pColumnList) <> SQLITE_ROW) do
  begin
    rc := schemaFinalizeStmt(@pCur^.pColumnList);
    if rc <> SQLITE_OK then goto next_exit;

    while (pCur^.pTableList = nil) or
          (sqlite3_step(pCur^.pTableList) <> SQLITE_ROW) do
    begin
      rc := schemaFinalizeStmt(@pCur^.pTableList);
      if rc <> SQLITE_OK then goto next_exit;

      { assert(pCur->pDbList); }
      done := False;
      while sqlite3_step(pCur^.pDbList) <> SQLITE_ROW do
      begin
        rc := schemaFinalizeStmt(@pCur^.pDbList);
        done := True;
        Break;
      end;
      if done then goto next_exit;

      { Set zSql to the SQL to pull the list of tables from the
        sqlite_schema (or sqlite_temp_schema) table of the database
        identified by the current pCur->pDbList row (a PRAGMA
        database_list iteration). }
      if sqlite3_column_int(pCur^.pDbList, 0) = 1 then
        zSql := sqlite3PfMprintf(
          'SELECT name FROM sqlite_temp_schema WHERE type=''table''', [])
      else
      begin
        pDbList := pCur^.pDbList;
        zSql := sqlite3PfMprintf(
          'SELECT name FROM %Q.sqlite_schema WHERE type=''table''',
          [sqlite3_column_text(pDbList, 1)]);
      end;
      if zSql = nil then
      begin
        rc := SQLITE_NOMEM;
        goto next_exit;
      end;

      rc := sqlite3_prepare(pVtab^.db, zSql, -1, @pCur^.pTableList, nil);
      sqlite3_free(zSql);
      if rc <> SQLITE_OK then goto next_exit;
    end;

    { Set zSql to the table_info pragma for the table currently
      identified by pCur->pDbList and pCur->pTableList. }
    zSql := sqlite3PfMprintf('PRAGMA %Q.table_info(%Q)',
      [sqlite3_column_text(pCur^.pDbList, 1),
       sqlite3_column_text(pCur^.pTableList, 0)]);

    if zSql = nil then
    begin
      rc := SQLITE_NOMEM;
      goto next_exit;
    end;
    rc := sqlite3_prepare(pVtab^.db, zSql, -1, @pCur^.pColumnList, nil);
    sqlite3_free(zSql);
    if rc <> SQLITE_OK then goto next_exit;
  end;
  Inc(pCur^.rowid);

next_exit:
  Result := rc;
end;

{ test_schema.c:243..257 — schemaFilter. }
function schemaFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PAnsiChar;
  argc: cint; argv: PPsqlite3_value): cint; cdecl;
var
  rc    : cint;
  pVtab : PSchemaVtab;
  pCur  : PSchemaCursor;
begin
  pVtab := PSchemaVtab(pVtabCursor^.pVtab);
  pCur := PSchemaCursor(pVtabCursor);
  pCur^.rowid := 0;
  schemaFinalizeStmt(@pCur^.pTableList);
  schemaFinalizeStmt(@pCur^.pColumnList);
  schemaFinalizeStmt(@pCur^.pDbList);
  rc := sqlite3_prepare(pVtab^.db, PChar('PRAGMA database_list'), -1,
    @pCur^.pDbList, nil);
  if rc = SQLITE_OK then
    Result := schemaNext(pVtabCursor)
  else
    Result := rc;
end;

{ test_schema.c:262..264 — schemaBestIndex. }
function schemaBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): cint; cdecl;
begin
  Result := SQLITE_OK;
end;

{ getDbPointer — recover the sqlite3* behind a `db` Tcl command, or
  decode a hex "%p" string into a sqlite3* pointer (test1.c:112..123).
  vtab2.test passes the connection via
  `register_schema_module [sqlite3_connection_pointer db]`. }
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

{ test_schema.c:310..326 — register_schema_module. }
function register_schema_module(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db : PTsqlite3;
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
  sqlite3_create_module(db, PChar('schema'), @schemaModule, nil);
  Result := TCL_OK;
end;

{ test_schema.c:331..345 — Sqlitetestschema_Init. }
function Sqlitetestschema_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('register_schema_module'),
    @register_schema_module, nil, nil);
  Result := TCL_OK;
end;

initialization
  { test_schema.c:270..296 — schemaModule. }
  FillChar(schemaModule, SizeOf(schemaModule), 0);
  schemaModule.iVersion    := 0;
  schemaModule.xCreate     := @schemaCreate;
  schemaModule.xConnect    := @schemaCreate;
  schemaModule.xBestIndex  := @schemaBestIndex;
  schemaModule.xDisconnect := @schemaDestroy;
  schemaModule.xDestroy    := @schemaDestroy;
  schemaModule.xOpen       := @schemaOpen;
  schemaModule.xClose      := @schemaClose;
  schemaModule.xFilter     := @schemaFilter;
  schemaModule.xNext       := @schemaNext;
  schemaModule.xEof        := @schemaEof;
  schemaModule.xColumn     := @schemaColumn;
  schemaModule.xRowid      := @schemaRowid;
end.
