{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/btreeinfo.c (434 lines in C).

  Eponymous-only read-only virtual table that surfaces information about
  every btree in an SQLite database file:

      CREATE TABLE sqlite_btreeinfo(
         type      TEXT,    -- "table" or "index"
         name      TEXT,    -- Name of table or index for this btree
         tbl_name  TEXT,    -- Associated table
         rootpage  INT,     -- The root page of the btree
         sql       TEXT,    -- SQL for this btree from sqlite_schema
         hasRowid  BOOLEAN, -- True if the btree has a rowid
         nEntry    INT,     -- Estimated number of entries
         nPage     INT,     -- Estimated number of pages
         depth     INT,     -- Depth of the btree
         szPage    INT,     -- Size of each page in bytes
         zSchema   TEXT HIDDEN
      );

  Reads pages through the sqlite_dbpage virtual table; auto-registered
  by shell openDb.  The first 5 columns mirror sqlite_schema (omitting
  triggers / views which have rootpage 0); the remaining 5 are computed
  by walking from the root page to a leaf, recording the fanout at each
  level.  See btreeinfo.c:269..332 for the estimation algorithm.

  Public entry: sqlite3BinfoRegister(db) — equivalent to
  sqlite3_btreeinfo_init() in C.
}
{$I passqlite3.inc}
unit passqlite3btreeinfo;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3BinfoRegister(db: PTsqlite3): i32;

implementation

const
  BINFO_COLUMN_TYPE     = 0;
  BINFO_COLUMN_NAME     = 1;
  BINFO_COLUMN_TBL_NAME = 2;
  BINFO_COLUMN_ROOTPAGE = 3;
  BINFO_COLUMN_SQL      = 4;
  BINFO_COLUMN_HASROWID = 5;
  BINFO_COLUMN_NENTRY   = 6;
  BINFO_COLUMN_NPAGE    = 7;
  BINFO_COLUMN_DEPTH    = 8;
  BINFO_COLUMN_SZPAGE   = 9;
  BINFO_COLUMN_SCHEMA   = 10;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { btreeinfo.c:101..105 — BinfoTable. }
  PBinfoTable = ^TBinfoTable;
  TBinfoTable = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
  end;

  { btreeinfo.c:88..99 — BinfoCursor. }
  PBinfoCursor = ^TBinfoCursor;
  TBinfoCursor = record
    base     : Tsqlite3_vtab_cursor;
    pStmt    : PVdbe;
    rc       : i32;
    hasRowid : i32;
    nEntry   : i64;
    nPage    : i32;
    depth    : i32;
    szPage   : i32;
    zSchema  : PAnsiChar;
  end;

  PByteArr = ^TByteArr;
  TByteArr = array[0..1024*1024 - 1] of Byte;

var
  binfoModule: Tsqlite3_module;

{ btreeinfo.c:262..264 — get_uint16. }
function getUint16(a: PByteArr): u32; inline;
begin
  Result := (u32(a^[0]) shl 8) or u32(a^[1]);
end;

{ btreeinfo.c:265..267 — get_uint32. }
function getUint32(a: PByteArr): u32; inline;
begin
  Result := (u32(a^[0]) shl 24) or (u32(a^[1]) shl 16)
         or (u32(a^[2]) shl  8) or  u32(a^[3]);
end;

{ btreeinfo.c:110..143 — binfoConnect. }
function binfoConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pTab: PBinfoTable;
  rc:   i32;
begin
  pTab := nil;
  rc := sqlite3_declare_vtab(db,
      'CREATE TABLE x('
    + ' type TEXT,'
    + ' name TEXT,'
    + ' tbl_name TEXT,'
    + ' rootpage INT,'
    + ' sql TEXT,'
    + ' hasRowid BOOLEAN,'
    + ' nEntry INT,'
    + ' nPage INT,'
    + ' depth INT,'
    + ' szPage INT,'
    + ' zSchema TEXT HIDDEN'
    + ')');
  if rc = SQLITE_OK then begin
    pTab := PBinfoTable(sqlite3Malloc(SizeOf(TBinfoTable)));
    if pTab = nil then rc := SQLITE_NOMEM;
  end;
  if pTab <> nil then begin
    FillChar(pTab^, SizeOf(TBinfoTable), 0);
    pTab^.db := db;
  end;
  ppVtab^ := PSqlite3Vtab(pTab);
  Result := rc;
end;

{ btreeinfo.c:148..151 — binfoDisconnect. }
function binfoDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ btreeinfo.c:159..177 — binfoBestIndex. idxNum=1 when WHERE zSchema=?. }
function binfoBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i: i32;
  pC: PSqlite3IndexConstraint;
  pUse: PSqlite3IndexConstraintUsage;
begin
  pIdxInfo^.estimatedCost := 10000.0;
  pIdxInfo^.estimatedRows := 100;
  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if (pC^.usable <> 0)
      and (pC^.iColumn = BINFO_COLUMN_SCHEMA)
      and (pC^.op = SQLITE_INDEX_CONSTRAINT_EQ) then begin
      pIdxInfo^.estimatedCost := 1000.0;
      pIdxInfo^.idxNum := 1;
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, i);
      pUse^.argvIndex := 1;
      pUse^.omit      := 1;
      Break;
    end;
    Inc(pC);
  end;
  Result := SQLITE_OK;
end;

{ btreeinfo.c:182..195 — binfoOpen. }
function binfoOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCsr: PBinfoCursor;
begin
  pCsr := PBinfoCursor(sqlite3Malloc(SizeOf(TBinfoCursor)));
  if pCsr = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCsr^, SizeOf(TBinfoCursor), 0);
  pCsr^.base.pVtab := p;
  ppCursor^ := PSqlite3VtabCursor(@pCsr^.base);
  Result := SQLITE_OK;
end;

{ btreeinfo.c:200..206 — binfoClose. }
function binfoClose(pCursor: PSqlite3VtabCursor): i32; cdecl;
var pCsr: PBinfoCursor;
begin
  pCsr := PBinfoCursor(pCursor);
  if pCsr^.pStmt <> nil then sqlite3_finalize(pCsr^.pStmt);
  sqlite3_free(pCsr^.zSchema);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ btreeinfo.c:211..216 — binfoNext. }
function binfoNext(pCursor: PSqlite3VtabCursor): i32; cdecl;
var pCsr: PBinfoCursor;
begin
  pCsr := PBinfoCursor(pCursor);
  pCsr^.rc := sqlite3_step(pCsr^.pStmt);
  pCsr^.hasRowid := -1;
  if pCsr^.rc = SQLITE_ERROR then Result := SQLITE_ERROR
                              else Result := SQLITE_OK;
end;

{ btreeinfo.c:221..224 — binfoEof. }
function binfoEof(pCursor: PSqlite3VtabCursor): i32; cdecl;
var pCsr: PBinfoCursor;
begin
  pCsr := PBinfoCursor(pCursor);
  if pCsr^.rc <> SQLITE_ROW then Result := 1 else Result := 0;
end;

{ btreeinfo.c:228..259 — binfoFilter. }
function binfoFilter(pCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCsr: PBinfoCursor;
  pTab: PBinfoTable;
  zSql: PAnsiChar;
  rc:   i32;
begin
  pCsr := PBinfoCursor(pCursor);
  pTab := PBinfoTable(pCursor^.pVtab);
  sqlite3_free(pCsr^.zSchema);
  if (idxNum = 1) and (sqlite3_value_type(argv[0]) <> SQLITE_NULL) then begin
    pCsr^.zSchema := sqlite3MPrintf(nil, '%s',
      [sqlite3_value_text(argv[0])]);
  end else begin
    pCsr^.zSchema := sqlite3MPrintf(nil, 'main', []);
  end;
  zSql := sqlite3MPrintf(nil,
      'SELECT 0, ''table'',''sqlite_schema'',''sqlite_schema'',1,NULL '
    + 'UNION ALL '
    + 'SELECT rowid, type, name, tbl_name, rootpage, sql'
    + ' FROM "%w".sqlite_schema WHERE rootpage>=1',
    [pCsr^.zSchema]);
  if pCsr^.pStmt <> nil then sqlite3_finalize(pCsr^.pStmt);
  pCsr^.pStmt := nil;
  pCsr^.hasRowid := -1;
  rc := sqlite3_prepare_v2(pTab^.db, zSql, -1, PPointer(@pCsr^.pStmt), nil);
  sqlite3_free(zSql);
  if rc = SQLITE_OK then
    rc := binfoNext(pCursor);
  Result := rc;
end;

{ btreeinfo.c:272..332 — binfoCompute.  Walks btree from root to a leaf
  through sqlite_dbpage; multiplies cell counts at each interior level
  to estimate nEntry / nPage; records depth + page size. }
function binfoCompute(db: PTsqlite3; pgno: i32; pCsr: PBinfoCursor): i32;
var
  nEntry: i64;
  nPage:  i32;
  aData:  PByteArr;
  aBase:  PByteArr;
  pStmt:  PVdbe;
  rc:     i32;
  pgsz:   i32;
  nCell:  i32;
  iCell:  i32;
begin
  nEntry := 1;
  nPage  := 1;
  pStmt  := nil;
  rc := sqlite3_prepare_v2(db,
    'SELECT data FROM sqlite_dbpage(''main'') WHERE pgno=?1', -1,
    PPointer(@pStmt), nil);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  pCsr^.depth := 1;
  while True do begin
    sqlite3_bind_int(pStmt, 1, pgno);
    rc := sqlite3_step(pStmt);
    if rc <> SQLITE_ROW then begin
      rc := SQLITE_ERROR;
      Break;
    end;
    pgsz := sqlite3_column_bytes(pStmt, 0);
    pCsr^.szPage := pgsz;
    aBase := PByteArr(sqlite3_column_blob(pStmt, 0));
    if aBase = nil then begin rc := SQLITE_NOMEM; Break; end;
    if pgno = 1 then begin
      aData := PByteArr(PAnsiChar(aBase) + 100);
      pgsz := pgsz - 100;
    end else
      aData := aBase;
    if (aData^[0] <> 2) and (aData^[0] <> 10) then
      pCsr^.hasRowid := 1
    else
      pCsr^.hasRowid := 0;
    nCell := i32(getUint16(PByteArr(PAnsiChar(aData) + 3)));
    nEntry := nEntry * (nCell + 1);
    if (aData^[0] = 10) or (aData^[0] = 13) then Break;
    nPage := nPage * (nCell + 1);
    if 14 + 2 * (nCell div 2) >= pgsz then begin
      rc := SQLITE_CORRUPT;
      Break;
    end;
    if nCell <= 1 then begin
      pgno := i32(getUint32(PByteArr(PAnsiChar(aData) + 8)));
    end else begin
      iCell := i32(getUint16(PByteArr(PAnsiChar(aData) + 12 + 2 * (nCell div 2))));
      if pgno = 1 then iCell := iCell - 100;
      if (iCell <= 12) or (iCell >= pgsz - 4) then begin
        rc := SQLITE_CORRUPT;
        Break;
      end;
      pgno := i32(getUint32(PByteArr(PAnsiChar(aData) + iCell)));
    end;
    Inc(pCsr^.depth);
    sqlite3_reset(pStmt);
  end;
  sqlite3_finalize(pStmt);
  pCsr^.nPage  := nPage;
  pCsr^.nEntry := nEntry;
  if rc = SQLITE_ROW then rc := SQLITE_OK;
  Result := rc;
end;

{ btreeinfo.c:335..381 — binfoColumn. }
function binfoColumn(pCursor: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCsr: PBinfoCursor;
  pgno: i32;
  rc:   i32;
  db:   PTsqlite3;
begin
  pCsr := PBinfoCursor(pCursor);
  if (i >= BINFO_COLUMN_HASROWID) and (i <= BINFO_COLUMN_SZPAGE)
    and (pCsr^.hasRowid < 0) then begin
    pgno := sqlite3_column_int(pCsr^.pStmt, BINFO_COLUMN_ROOTPAGE + 1);
    db := sqlite3_context_db_handle(ctx);
    rc := binfoCompute(db, pgno, pCsr);
    if rc <> SQLITE_OK then begin
      pCursor^.pVtab^.zErrMsg := sqlite3MPrintf(nil, '%s',
        [sqlite3_errstr(rc)]);
      Result := SQLITE_ERROR;
      Exit;
    end;
  end;
  case i of
    BINFO_COLUMN_NAME, BINFO_COLUMN_TYPE, BINFO_COLUMN_TBL_NAME,
    BINFO_COLUMN_ROOTPAGE, BINFO_COLUMN_SQL:
      sqlite3_result_value(ctx,
        sqlite3_column_value(pCsr^.pStmt, i + 1));
    BINFO_COLUMN_HASROWID:
      sqlite3_result_int(ctx, pCsr^.hasRowid);
    BINFO_COLUMN_NENTRY:
      sqlite3_result_int64(ctx, pCsr^.nEntry);
    BINFO_COLUMN_NPAGE:
      sqlite3_result_int(ctx, pCsr^.nPage);
    BINFO_COLUMN_DEPTH:
      sqlite3_result_int(ctx, pCsr^.depth);
    BINFO_COLUMN_SCHEMA:
      sqlite3_result_text(ctx, pCsr^.zSchema, -1, SQLITE_STATIC);
  end;
  Result := SQLITE_OK;
end;

{ btreeinfo.c:384..388 — binfoRowid. }
function binfoRowid(pCursor: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCsr: PBinfoCursor;
begin
  pCsr := PBinfoCursor(pCursor);
  pRowid^ := sqlite3_column_int64(pCsr^.pStmt, 0);
  Result := SQLITE_OK;
end;

function sqlite3BinfoRegister(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'sqlite_btreeinfo',
    @binfoModule, nil);
end;

initialization
  FillChar(binfoModule, SizeOf(binfoModule), 0);
  binfoModule.iVersion    := 0;
  { xCreate intentionally nil — eponymous-only. }
  binfoModule.xConnect    := @binfoConnect;
  binfoModule.xBestIndex  := @binfoBestIndex;
  binfoModule.xDisconnect := @binfoDisconnect;
  binfoModule.xOpen       := @binfoOpen;
  binfoModule.xClose      := @binfoClose;
  binfoModule.xFilter     := @binfoFilter;
  binfoModule.xNext       := @binfoNext;
  binfoModule.xEof        := @binfoEof;
  binfoModule.xColumn     := @binfoColumn;
  binfoModule.xRowid      := @binfoRowid;
end.
