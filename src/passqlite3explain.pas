{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/explain.c (323 lines in C).

  Eponymous virtual table that returns the EXPLAIN output rows for an
  SQL statement.  Schema:

      CREATE TABLE explain(
         addr,opcode,p1,p2,p3,p4,p5,comment,
         sql HIDDEN
      );

  Suggested usage:

      SELECT p2 FROM explain('SELECT * FROM sqlite_schema')
       WHERE opcode='OpenRead';

  Public entry: sqlite3ExplainVtabInit(db) — equivalent to
  sqlite3_explain_init() in C.
}
{$I passqlite3.inc}
unit passqlite3explain;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3ExplainVtabInit(db: PTsqlite3): i32;

implementation

const
  { explain.c:81..89 — column ordinals.  SQL is hidden; the rest mirror
    the upstream EXPLAIN output (addr/opcode/p1..p5/comment). }
  EXPLN_COLUMN_ADDR    = 0;
  EXPLN_COLUMN_OPCODE  = 1;
  EXPLN_COLUMN_P1      = 2;
  EXPLN_COLUMN_P2      = 3;
  EXPLN_COLUMN_P3      = 4;
  EXPLN_COLUMN_P4      = 5;
  EXPLN_COLUMN_P5      = 6;
  EXPLN_COLUMN_COMMENT = 7;
  EXPLN_COLUMN_SQL     = 8;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { explain.c:38..42 — explain_vtab. }
  PExplainVtab = ^TExplainVtab;
  TExplainVtab = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
  end;

  { explain.c:48..55 — explain_cursor. }
  PExplainCursor = ^TExplainCursor;
  TExplainCursor = record
    base     : Tsqlite3_vtab_cursor;
    db       : PTsqlite3;
    zSql     : PAnsiChar;
    pExplain : PVdbe;
    rc       : i32;
  end;

var
  explainModule: Tsqlite3_module;

{ explain.c:70..102 — explainConnect. }
function explainConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PExplainVtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE x(addr,opcode,p1,p2,p3,p4,p5,comment,sql HIDDEN)');
  if rc = SQLITE_OK then begin
    pNew := PExplainVtab(sqlite3Malloc(SizeOf(TExplainVtab)));
    ppVtab^ := PSqlite3Vtab(pNew);
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(TExplainVtab), 0);
    pNew^.db := db;
  end;
  Result := rc;
end;

{ explain.c:107..110 — explainDisconnect. }
function explainDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ explain.c:115..123 — explainOpen. }
function explainOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pCur: PExplainCursor;
begin
  pCur := PExplainCursor(sqlite3Malloc(SizeOf(TExplainCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TExplainCursor), 0);
  pCur^.db := PExplainVtab(p)^.db;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ explain.c:128..134 — explainClose. }
function explainClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PExplainCursor;
begin
  pCur := PExplainCursor(cur);
  sqlite3_finalize(pCur^.pExplain);
  sqlite3_free(pCur^.zSql);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ explain.c:140..145 — explainNext.  Steps the inner EXPLAIN statement;
  caches the rc on the cursor for explainEof. }
function explainNext(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PExplainCursor;
begin
  pCur := PExplainCursor(cur);
  pCur^.rc := sqlite3_step(pCur^.pExplain);
  if (pCur^.rc <> SQLITE_DONE) and (pCur^.rc <> SQLITE_ROW) then begin
    Result := pCur^.rc; Exit;
  end;
  Result := SQLITE_OK;
end;

{ explain.c:151..163 — explainColumn.  Hidden SQL column returns the
  cached input text; data columns delegate to sqlite3_column_value on
  the inner EXPLAIN cursor. }
function explainColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var pCur: PExplainCursor;
begin
  pCur := PExplainCursor(cur);
  if i = EXPLN_COLUMN_SQL then
    sqlite3_result_text(ctx, pCur^.zSql, -1, SQLITE_TRANSIENT)
  else
    sqlite3_result_value(ctx, sqlite3_column_value(pCur^.pExplain, i));
  Result := SQLITE_OK;
end;

{ explain.c:169..173 — explainRowid.  Reuses the EXPLAIN-output addr
  column as the rowid. }
function explainRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PExplainCursor;
begin
  pCur := PExplainCursor(cur);
  pRowid^ := sqlite3_column_int64(pCur^.pExplain, 0);
  Result := SQLITE_OK;
end;

{ explain.c:179..182 — explainEof. }
function explainEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PExplainCursor;
begin
  pCur := PExplainCursor(cur);
  if pCur^.rc <> SQLITE_ROW then Result := 1 else Result := 0;
end;

{ explain.c:192..227 — explainFilter.  argv[0] is the SQL string to be
  EXPLAINed.  Wraps it in `EXPLAIN <sql>` and prepares it; rc is then
  stepped once to prime explainEof / explainColumn. }
function explainFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PExplainCursor;
  zSql: PAnsiChar;
  rc:   i32;
  pArr: ^Psqlite3_value;
  pVal: Psqlite3_value;
begin
  pCur := PExplainCursor(pVtabCursor);
  zSql := nil;
  sqlite3_finalize(pCur^.pExplain);
  pCur^.pExplain := nil;
  pArr := Pointer(argv);
  pVal := pArr^;
  if sqlite3_value_type(pVal) <> SQLITE_TEXT then begin
    pCur^.rc := SQLITE_DONE;
    Result := SQLITE_OK; Exit;
  end;
  sqlite3_free(pCur^.zSql);
  pCur^.zSql := sqlite3PfMprintf('%s', [sqlite3_value_text(pVal)]);
  if pCur^.zSql <> nil then
    zSql := sqlite3PfMprintf('EXPLAIN %s', [pCur^.zSql]);
  if zSql = nil then
    rc := SQLITE_NOMEM
  else begin
    rc := sqlite3_prepare_v2(pCur^.db, zSql, -1,
                             PPointer(@pCur^.pExplain), nil);
    sqlite3_free(zSql);
  end;
  if rc <> SQLITE_OK then begin
    sqlite3_finalize(pCur^.pExplain);
    pCur^.pExplain := nil;
    sqlite3_free(pCur^.zSql);
    pCur^.zSql := nil;
  end else begin
    pCur^.rc := sqlite3_step(pCur^.pExplain);
    if (pCur^.rc = SQLITE_DONE) or (pCur^.rc = SQLITE_ROW) then
      rc := SQLITE_OK
    else
      rc := pCur^.rc;
  end;
  Result := rc;
end;

{ explain.c:235..265 — explainBestIndex.  Looks for an `==` constraint
  against the hidden SQL column; rejects plans with unusable constraints
  on it. }
function explainBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i:        i32;
  idx:      i32;
  unusable: i32;
  pC:       PSqlite3IndexConstraint;
  pUse:     PSqlite3IndexConstraintUsage;
begin
  idx := -1;
  unusable := 0;
  pIdxInfo^.estimatedRows := 500;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    pC := pIdxInfo^.aConstraint;
    Inc(pC, i);
    if pC^.iColumn <> EXPLN_COLUMN_SQL then Continue;
    if pC^.usable = 0 then
      unusable := 1
    else if pC^.op = SQLITE_INDEX_CONSTRAINT_EQ then
      idx := i;
  end;
  if idx >= 0 then begin
    pIdxInfo^.estimatedCost := 10.0;
    pIdxInfo^.idxNum := 1;
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, idx);
    pUse^.argvIndex := 1;
    pUse^.omit := 1;
  end else if unusable <> 0 then begin
    Result := SQLITE_CONSTRAINT; Exit;
  end;
  Result := SQLITE_OK;
end;

function sqlite3ExplainVtabInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'explain', @explainModule, nil);
end;

initialization
  FillChar(explainModule, SizeOf(explainModule), 0);
  explainModule.iVersion    := 0;
  { xCreate intentionally left nil — eponymous-only. }
  explainModule.xConnect    := @explainConnect;
  explainModule.xBestIndex  := @explainBestIndex;
  explainModule.xDisconnect := @explainDisconnect;
  explainModule.xOpen       := @explainOpen;
  explainModule.xClose      := @explainClose;
  explainModule.xFilter     := @explainFilter;
  explainModule.xNext       := @explainNext;
  explainModule.xEof        := @explainEof;
  explainModule.xColumn     := @explainColumn;
  explainModule.xRowid      := @explainRowid;
end.
