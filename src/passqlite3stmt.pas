{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/stmt.c (347 lines in C).

  Eponymous virtual table that returns information about all prepared
  statements for the current database connection.  Schema:

      CREATE TABLE sqlite_stmt(
         sql,    ncol,  ro,    busy,  nscan,
         nsort,  naidx, nstep, reprep, run,  mem
      );

  One row per still-open prepared statement on the connection.  All
  numeric columns come from sqlite3_stmt_status() with reset=0.

  Public entry: sqlite3StmtVtabInit(db) — equivalent to
  sqlite3_stmt_init() in C.
}
{$I passqlite3.inc}
unit passqlite3stmt;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3StmtVtabInit(db: PTsqlite3): i32;

implementation

const
  STMT_NUM_INTEGER_COLUMN = 10;

  { stmt.c:87..97 — column ordinals.  Column 0 is sql; 1..10 map to
    aCol[1..10]. }
  STMT_COLUMN_SQL    = 0;
  STMT_COLUMN_NCOL   = 1;
  STMT_COLUMN_RO     = 2;
  STMT_COLUMN_BUSY   = 3;
  STMT_COLUMN_NSCAN  = 4;
  STMT_COLUMN_NSORT  = 5;
  STMT_COLUMN_NAIDX  = 6;
  STMT_COLUMN_NSTEP  = 7;
  STMT_COLUMN_REPREP = 8;
  STMT_COLUMN_RUN    = 9;
  STMT_COLUMN_MEM    = 10;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { stmt.c:35..41 — StmtRow.  zSql is allocated as a tail of the row
    buffer, exactly as upstream does (sqlite3_malloc64(sizeof+nSql)). }
  PStmtRow = ^TStmtRow;
  TStmtRow = record
    iRowid : i64;
    zSql   : PAnsiChar;
    aCol   : array[0..STMT_NUM_INTEGER_COLUMN] of i32;
    pNext  : PStmtRow;
  end;

  { stmt.c:46..50 — stmt_vtab. }
  PStmtVtab = ^TStmtVtab;
  TStmtVtab = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
  end;

  { stmt.c:56..61 — stmt_cursor. }
  PStmtCursor = ^TStmtCursor;
  TStmtCursor = record
    base : Tsqlite3_vtab_cursor;
    db   : PTsqlite3;
    pRow : PStmtRow;
  end;

var
  stmtModule: Tsqlite3_module;

{ stmt.c:76..115 — stmtConnect. }
function stmtConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PStmtVtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE x(sql,ncol,ro,busy,nscan,nsort,naidx,nstep,'
    + 'reprep,run,mem)');
  if rc = SQLITE_OK then begin
    pNew := PStmtVtab(sqlite3Malloc(SizeOf(TStmtVtab)));
    ppVtab^ := PSqlite3Vtab(pNew);
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(TStmtVtab), 0);
    pNew^.db := db;
  end;
  Result := rc;
end;

{ stmt.c:120..123 — stmtDisconnect. }
function stmtDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ stmt.c:128..136 — stmtOpen. }
function stmtOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pCur: PStmtCursor;
begin
  pCur := PStmtCursor(sqlite3Malloc(SizeOf(TStmtCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TStmtCursor), 0);
  pCur^.db := PStmtVtab(p)^.db;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ stmt.c:138..146 — stmtCsrReset.  Walks the linked list of buffered
  StmtRow records and frees each one. }
procedure stmtCsrReset(pCur: PStmtCursor);
var
  pRow, pNext: PStmtRow;
begin
  pRow := pCur^.pRow;
  while pRow <> nil do begin
    pNext := pRow^.pNext;
    sqlite3_free(pRow);
    pRow := pNext;
  end;
  pCur^.pRow := nil;
end;

{ stmt.c:151..155 — stmtClose. }
function stmtClose(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  stmtCsrReset(PStmtCursor(cur));
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ stmt.c:161..167 — stmtNext.  Pop the head row from the buffered list. }
function stmtNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur:  PStmtCursor;
  pNext: PStmtRow;
begin
  pCur := PStmtCursor(cur);
  pNext := pCur^.pRow^.pNext;
  sqlite3_free(pCur^.pRow);
  pCur^.pRow := pNext;
  Result := SQLITE_OK;
end;

{ stmt.c:173..186 — stmtColumn. }
function stmtColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur: PStmtCursor;
  pRow: PStmtRow;
begin
  pCur := PStmtCursor(cur);
  pRow := pCur^.pRow;
  if i = STMT_COLUMN_SQL then
    sqlite3_result_text(ctx, pRow^.zSql, -1, SQLITE_TRANSIENT)
  else
    sqlite3_result_int(ctx, pRow^.aCol[i]);
  Result := SQLITE_OK;
end;

{ stmt.c:192..196 — stmtRowid. }
function stmtRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PStmtCursor;
begin
  pCur := PStmtCursor(cur);
  pRowid^ := pCur^.pRow^.iRowid;
  Result := SQLITE_OK;
end;

{ stmt.c:202..205 — stmtEof. }
function stmtEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PStmtCursor;
begin
  pCur := PStmtCursor(cur);
  if pCur^.pRow = nil then Result := 1 else Result := 0;
end;

{ stmt.c:213..270 — stmtFilter.  Walk every prepared statement on the
  connection (sqlite3_next_stmt) and snapshot its sqlite3_sql plus the
  status counters into a fresh StmtRow.  Linked list is built in
  enumeration order; iRowid starts at 1. }
function stmtFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur:    PStmtCursor;
  p:       Pointer;
  iRowid:  i64;
  ppRow:   ^PStmtRow;
  zSql:    PAnsiChar;
  nSql:    SizeInt;
  pNew:    PStmtRow;
  totSize: u64;
begin
  pCur := PStmtCursor(pVtabCursor);
  iRowid := 1;
  stmtCsrReset(pCur);
  ppRow := @pCur^.pRow;
  p := sqlite3_next_stmt(pCur^.db, nil);
  while p <> nil do begin
    zSql := sqlite3_sql(p);
    if zSql <> nil then
      nSql := StrLen(zSql) + 1
    else
      nSql := 0;
    totSize := u64(SizeOf(TStmtRow)) + u64(nSql);
    pNew := PStmtRow(sqlite3_malloc64(totSize));
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(TStmtRow), 0);
    if zSql <> nil then begin
      pNew^.zSql := PAnsiChar(pNew) + SizeOf(TStmtRow);
      Move(zSql^, pNew^.zSql^, nSql);
    end;
    pNew^.aCol[STMT_COLUMN_NCOL]   := sqlite3_column_count(PVdbe(p));
    pNew^.aCol[STMT_COLUMN_RO]     := sqlite3_stmt_readonly(p);
    pNew^.aCol[STMT_COLUMN_BUSY]   := sqlite3_stmt_busy(p);
    pNew^.aCol[STMT_COLUMN_NSCAN]  :=
      sqlite3_stmt_status(p, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0);
    pNew^.aCol[STMT_COLUMN_NSORT]  :=
      sqlite3_stmt_status(p, SQLITE_STMTSTATUS_SORT, 0);
    pNew^.aCol[STMT_COLUMN_NAIDX]  :=
      sqlite3_stmt_status(p, SQLITE_STMTSTATUS_AUTOINDEX, 0);
    pNew^.aCol[STMT_COLUMN_NSTEP]  :=
      sqlite3_stmt_status(p, SQLITE_STMTSTATUS_VM_STEP, 0);
    pNew^.aCol[STMT_COLUMN_REPREP] :=
      sqlite3_stmt_status(p, SQLITE_STMTSTATUS_REPREPARE, 0);
    pNew^.aCol[STMT_COLUMN_RUN]    :=
      sqlite3_stmt_status(p, SQLITE_STMTSTATUS_RUN, 0);
    { Pascal-port limitation: sqlite3_stmt_status(.., MEMUSED, 0) currently
      calls sqlite3VdbeDelete on the live statement instead of running it
      under the pnBytesFreed accounting mode (passqlite3main.pas:3480..).
      Issuing the call from inside an active scan over sqlite3_next_stmt()
      destroys the running vdbe and segfaults.  Report 0 until the
      pnBytesFreed dry-run path is wired through sqlite3DbFree. }
    pNew^.aCol[STMT_COLUMN_MEM]    := 0;
    pNew^.iRowid := iRowid;
    Inc(iRowid);
    ppRow^ := pNew;
    ppRow := @pNew^.pNext;
    p := sqlite3_next_stmt(pCur^.db, p);
  end;
  Result := SQLITE_OK;
end;

{ stmt.c:278..286 — stmtBestIndex.  Constant cost estimate. }
function stmtBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
begin
  pIdxInfo^.estimatedCost := 500.0;
  pIdxInfo^.estimatedRows := 500;
  Result := SQLITE_OK;
end;

function sqlite3StmtVtabInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'sqlite_stmt', @stmtModule, nil);
end;

initialization
  FillChar(stmtModule, SizeOf(stmtModule), 0);
  stmtModule.iVersion    := 0;
  { xCreate intentionally left nil — eponymous-only. }
  stmtModule.xConnect    := @stmtConnect;
  stmtModule.xBestIndex  := @stmtBestIndex;
  stmtModule.xDisconnect := @stmtDisconnect;
  stmtModule.xOpen       := @stmtOpen;
  stmtModule.xClose      := @stmtClose;
  stmtModule.xFilter     := @stmtFilter;
  stmtModule.xNext       := @stmtNext;
  stmtModule.xEof        := @stmtEof;
  stmtModule.xColumn     := @stmtColumn;
  stmtModule.xRowid      := @stmtRowid;
end.
