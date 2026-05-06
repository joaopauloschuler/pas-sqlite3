{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/memstat.c (435 lines in C).

  Eponymous virtual table that exposes the global sqlite3_status64()
  counters and the per-connection sqlite3_db_status() counters as a
  uniform table:

      SELECT name, schema, value, hiwtr FROM sqlite_memstat;

  Schema names come from PRAGMA database_list (per cursor open).

  ZIPVFS rows from the C source are dropped (Pascal port has no ZIPVFS
  build).  Everything else mirrors the C 1:1, including the mNull
  bitmask trick that suppresses per-schema iteration for global rows.

  Public entry: sqlite3MemstatVtabInit(db) — equivalent to
  sqlite3_memstat_init() in C.
}
{$I passqlite3.inc}
unit passqlite3memstat;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3MemstatVtabInit(db: PTsqlite3): i32;

implementation

const
  MSV_COLUMN_NAME    = 0;
  MSV_COLUMN_SCHEMA  = 1;
  MSV_COLUMN_VALUE   = 2;
  MSV_COLUMN_HIWTR   = 3;

  MSV_GSTAT  = 0;
  MSV_DB     = 1;
  { MSV_ZIPVFS not ported. }

type
  PCharArray = ^TCharArray;
  TCharArray = array[0..1024*1024 - 1] of PAnsiChar;

  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { memstat.c:36..40 — memstat_vtab. }
  PMemstatVtab = ^TMemstatVtab;
  TMemstatVtab = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
  end;

  { memstat.c:46..55 — memstat_cursor. }
  PMemstatCursor = ^TMemstatCursor;
  TMemstatCursor = record
    base   : Tsqlite3_vtab_cursor;
    db     : PTsqlite3;
    iRowid : i32;
    iDb    : i32;
    nDb    : i32;
    azDb   : PCharArray;
    aVal   : array[0..1] of i64;
  end;

  { memstat.c:187..193 — MemstatColumns row. }
  TMemstatColumn = record
    zName : PAnsiChar;
    eType : Byte;
    mNull : Byte;
    eOp   : i32;
  end;

const
  aMemstatColumn: array[0..17] of TMemstatColumn = (
    (zName: 'MEMORY_USED';            eType: MSV_GSTAT; mNull: 2; eOp: SQLITE_STATUS_MEMORY_USED),
    (zName: 'MALLOC_SIZE';            eType: MSV_GSTAT; mNull: 6; eOp: SQLITE_STATUS_MALLOC_SIZE),
    (zName: 'MALLOC_COUNT';           eType: MSV_GSTAT; mNull: 2; eOp: SQLITE_STATUS_MALLOC_COUNT),
    (zName: 'PAGECACHE_USED';         eType: MSV_GSTAT; mNull: 2; eOp: SQLITE_STATUS_PAGECACHE_USED),
    (zName: 'PAGECACHE_OVERFLOW';     eType: MSV_GSTAT; mNull: 2; eOp: SQLITE_STATUS_PAGECACHE_OVERFLOW),
    (zName: 'PAGECACHE_SIZE';         eType: MSV_GSTAT; mNull: 6; eOp: SQLITE_STATUS_PAGECACHE_SIZE),
    (zName: 'PARSER_STACK';           eType: MSV_GSTAT; mNull: 6; eOp: SQLITE_STATUS_PARSER_STACK),
    (zName: 'DB_LOOKASIDE_USED';      eType: MSV_DB;    mNull: 2; eOp: 0),
    (zName: 'DB_LOOKASIDE_HIT';       eType: MSV_DB;    mNull: 6; eOp: 4),
    (zName: 'DB_LOOKASIDE_MISS_SIZE'; eType: MSV_DB;    mNull: 6; eOp: 5),
    (zName: 'DB_LOOKASIDE_MISS_FULL'; eType: MSV_DB;    mNull: 6; eOp: 6),
    (zName: 'DB_CACHE_USED';          eType: MSV_DB;    mNull: 10; eOp: 1),
    { DB_CACHE_USED_SHARED gated on SQLITE_VERSION_NUMBER >= 3140000 in
      C; the (slightly oddly-numbered) constant excludes 3.53 — match C. }
    (zName: 'DB_SCHEMA_USED';         eType: MSV_DB;    mNull: 10; eOp: 2),
    (zName: 'DB_STMT_USED';           eType: MSV_DB;    mNull: 10; eOp: 3),
    (zName: 'DB_CACHE_HIT';           eType: MSV_DB;    mNull: 10; eOp: 7),
    (zName: 'DB_CACHE_MISS';          eType: MSV_DB;    mNull: 10; eOp: 8),
    (zName: 'DB_CACHE_WRITE';         eType: MSV_DB;    mNull: 10; eOp: 9),
    (zName: 'DB_DEFERRED_FKS';        eType: MSV_DB;    mNull: 10; eOp: 10)
  );
  MSV_NROW = Length(aMemstatColumn);

var
  memstatModule: Tsqlite3_module;

function strlen(s: PAnsiChar): SizeUInt;
var p: PAnsiChar;
begin
  if s = nil then begin Result := 0; Exit; end;
  p := s;
  while p^ <> #0 do Inc(p);
  Result := SizeUInt(p - s);
end;

function strDupZ(z: PAnsiChar): PAnsiChar;
var n: SizeUInt;
begin
  if z = nil then begin Result := nil; Exit; end;
  n := strlen(z);
  Result := PAnsiChar(sqlite3Malloc(i64(n) + 1));
  if Result = nil then Exit;
  if n > 0 then Move(z^, Result^, n);
  Result[n] := #0;
end;

{ memstat.c:70..95 — xConnect. }
function memstatConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PMemstatVtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db, 'CREATE TABLE x(name,schema,value,hiwtr)');
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  pNew := PMemstatVtab(sqlite3Malloc(SizeOf(TMemstatVtab)));
  ppVtab^ := PSqlite3Vtab(pNew);
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pNew^, SizeOf(TMemstatVtab), 0);
  pNew^.db := db;
  Result := SQLITE_OK;
end;

{ memstat.c:100..103 — xDisconnect. }
function memstatDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ memstat.c:108..116 — xOpen. }
function memstatOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PMemstatCursor;
begin
  pCur := PMemstatCursor(sqlite3Malloc(SizeOf(TMemstatCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TMemstatCursor), 0);
  pCur^.db := PMemstatVtab(p)^.db;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ memstat.c:121..130 — clear schema list. }
procedure memstatClearSchema(pCur: PMemstatCursor);
var i: i32;
begin
  if pCur^.azDb = nil then Exit;
  for i := 0 to pCur^.nDb - 1 do
    sqlite3_free(pCur^.azDb^[i]);
  sqlite3_free(pCur^.azDb);
  pCur^.azDb := nil;
  pCur^.nDb  := 0;
end;

{ memstat.c:135..162 — populate azDb[] from PRAGMA database_list. }
function memstatFindSchemas(pCur: PMemstatCursor): i32;
var
  pStmt: PVdbe;
  rc:    i32;
  az:    PCharArray;
  z:     PAnsiChar;
  pTail: PAnsiChar;
begin
  if pCur^.nDb <> 0 then begin Result := SQLITE_OK; Exit; end;
  pStmt := nil;
  rc := sqlite3_prepare_v2(pCur^.db, 'PRAGMA database_list', -1, @pStmt, @pTail);
  if rc <> SQLITE_OK then begin
    sqlite3_finalize(pStmt);
    Result := rc;
    Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    az := PCharArray(sqlite3_realloc64(pCur^.azDb,
            u64(SizeOf(PAnsiChar)) * u64(pCur^.nDb + 1)));
    if az = nil then begin
      memstatClearSchema(pCur);
      sqlite3_finalize(pStmt);
      Result := SQLITE_NOMEM;
      Exit;
    end;
    pCur^.azDb := az;
    z := strDupZ(sqlite3_column_text(pStmt, 1));
    if z = nil then begin
      memstatClearSchema(pCur);
      sqlite3_finalize(pStmt);
      Result := SQLITE_NOMEM;
      Exit;
    end;
    pCur^.azDb^[pCur^.nDb] := z;
    Inc(pCur^.nDb);
  end;
  sqlite3_finalize(pStmt);
  Result := SQLITE_OK;
end;

{ memstat.c:168..173 — xClose. }
function memstatClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PMemstatCursor;
begin
  pCur := PMemstatCursor(cur);
  memstatClearSchema(pCur);
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ memstat.c:232..277 — xNext.  Walks aMemstatColumn[] applying mNull
  bit 1 to skip per-schema iteration on global rows. }
function memstatNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur:  PMemstatCursor;
  i:     i32;
  xC, xH: i32;
  done:  Boolean;
begin
  pCur := PMemstatCursor(cur);
  done := False;
  while not done do begin
    i := pCur^.iRowid - 1;
    if (i < 0) or ((aMemstatColumn[i].mNull and 2) <> 0) then begin
      Inc(pCur^.iRowid);
      if pCur^.iRowid > MSV_NROW then begin Result := SQLITE_OK; Exit; end;
      pCur^.iDb := 0;
      Inc(i);
    end else begin
      Inc(pCur^.iDb);
      if pCur^.iDb >= pCur^.nDb then begin
        Inc(pCur^.iRowid);
        if pCur^.iRowid > MSV_NROW then begin Result := SQLITE_OK; Exit; end;
        pCur^.iDb := 0;
        Inc(i);
      end;
    end;
    pCur^.aVal[0] := 0;
    pCur^.aVal[1] := 0;
    case aMemstatColumn[i].eType of
      MSV_GSTAT:
        sqlite3_status64(aMemstatColumn[i].eOp,
          @pCur^.aVal[0], @pCur^.aVal[1], 0);
      MSV_DB: begin
        xC := 0; xH := 0;
        sqlite3_db_status(pCur^.db, aMemstatColumn[i].eOp, @xC, @xH, 0);
        pCur^.aVal[0] := xC;
        pCur^.aVal[1] := xH;
      end;
    end;
    done := True;
  end;
  Result := SQLITE_OK;
end;

{ memstat.c:284..315 — xColumn. }
function memstatColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; iCol: i32): i32; cdecl;
var
  pCur: PMemstatCursor;
  i:    i32;
begin
  pCur := PMemstatCursor(cur);
  i := pCur^.iRowid - 1;
  if (aMemstatColumn[i].mNull and (1 shl iCol)) <> 0 then begin
    Result := SQLITE_OK;
    Exit;
  end;
  case iCol of
    MSV_COLUMN_NAME:
      sqlite3_result_text(ctx, aMemstatColumn[i].zName, -1, SQLITE_STATIC);
    MSV_COLUMN_SCHEMA:
      sqlite3_result_text(ctx, pCur^.azDb^[pCur^.iDb], -1, nil);
    MSV_COLUMN_VALUE:
      sqlite3_result_int64(ctx, pCur^.aVal[0]);
    MSV_COLUMN_HIWTR:
      sqlite3_result_int64(ctx, pCur^.aVal[1]);
  end;
  Result := SQLITE_OK;
end;

{ memstat.c:321..325 — xRowid. }
function memstatRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PMemstatCursor;
begin
  pCur := PMemstatCursor(cur);
  pRowid^ := i64(pCur^.iRowid) * 1000 + i64(pCur^.iDb);
  Result := SQLITE_OK;
end;

{ memstat.c:331..334 — xEof. }
function memstatEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PMemstatCursor;
begin
  pCur := PMemstatCursor(cur);
  if pCur^.iRowid > MSV_NROW then Result := 1 else Result := 0;
end;

{ memstat.c:342..353 — xFilter. }
function memstatFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PMemstatCursor;
  rc:   i32;
begin
  pCur := PMemstatCursor(cur);
  rc := memstatFindSchemas(pCur);
  if rc <> 0 then begin Result := rc; Exit; end;
  pCur^.iRowid := 0;
  pCur^.iDb    := 0;
  Result := memstatNext(cur);
end;

{ memstat.c:361..368 — xBestIndex. }
function memstatBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
begin
  pIdxInfo^.estimatedCost := 500.0;
  pIdxInfo^.estimatedRows := 500;
  Result := SQLITE_OK;
end;

function sqlite3MemstatVtabInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'sqlite_memstat',
    @memstatModule, nil);
end;

initialization
  FillChar(memstatModule, SizeOf(memstatModule), 0);
  memstatModule.iVersion    := 0;
  memstatModule.xConnect    := @memstatConnect;
  memstatModule.xBestIndex  := @memstatBestIndex;
  memstatModule.xDisconnect := @memstatDisconnect;
  memstatModule.xOpen       := @memstatOpen;
  memstatModule.xClose      := @memstatClose;
  memstatModule.xFilter     := @memstatFilter;
  memstatModule.xNext       := @memstatNext;
  memstatModule.xEof        := @memstatEof;
  memstatModule.xColumn     := @memstatColumn;
  memstatModule.xRowid      := @memstatRowid;
end.
