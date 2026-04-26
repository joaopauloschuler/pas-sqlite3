{$I passqlite3.inc}
unit passqlite3dbpage;

{
  Phase 6.bis.2c — port of ../sqlite3/src/dbpage.c (the sqlite_dbpage
  table-valued virtual table; 502 lines in C).

  sqlite_dbpage is an eponymous-only vtab that exposes whole raw
  database pages.  Schema is:

      CREATE TABLE x(pgno INTEGER PRIMARY KEY, data BLOB, schema HIDDEN);

  Module is v2 (iVersion=2) and wires the full transactional set:
    xConnect/xDisconnect (no xCreate/xDestroy — eponymous),
    xBestIndex, xOpen/xClose, xFilter, xNext, xEof, xColumn, xRowid,
    xUpdate (writable), xBegin, xSync, xRollbackTo.

  Pager-side dependencies (all already ported):
    sqlite3PagerGet, sqlite3PagerWrite, sqlite3PagerUnref,
    sqlite3PagerUnrefPageOne, sqlite3PagerGetData,
    sqlite3PagerTruncateImage, sqlite3BtreePager, sqlite3BtreeGetPageSize,
    sqlite3BtreeLastPage, sqlite3BtreeBeginTrans, sqlite3BtreeEnter,
    sqlite3BtreeLeave, sqlite3FindDbName, PENDING_BYTE.

  Notes for future steps:
    * sqlite3_context_db_handle is not yet ported; xColumn instead
      derives `db` from cursor's vtab back-pointer (DbpageTable.db).
      Both paths are equivalent in C — context_db_handle just walks
      ctx->pVdbe->db; ours walks cursor->base.pVtab->db.
    * sqlite3_result_zeroblob is bridged via the existing
      sqlite3_result_zeroblob64 (cast to u64); zero-arity overload is
      not otherwise exposed.
    * sqlite3_mprintf for the zErrMsg path is bridged through a small
      dbpageFmtMsg shim (mirrors carrayFmtMsg from 6.bis.2b).

  Gate: src/tests/TestDbpage.pas exercises module registration,
  xBestIndex constraint dispatch (idxNum 0/1/2/3, including the
  CONSTRAINT failure when schema= is unusable), xOpen/xClose, and the
  cursor state machine via manual setup (xColumn/xUpdate require a
  live db with a real Btree open and are exercised indirectly).
}

interface

uses
  SysUtils,
  Strings,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pager,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3codegen;

const
  { sqliteInt.h:1859 — db.flags "SQLITE_Defensive" bit.  Mirrored from
    passqlite3vtab where it's defined in the implementation section
    (not exported); kept private here too. }
  SQLITE_Defensive_Bit = u64($10000000);

  { dbpage.c:65..67 — column ordinals. }
  DBPAGE_COLUMN_PGNO   = 0;
  DBPAGE_COLUMN_DATA   = 1;
  DBPAGE_COLUMN_SCHEMA = 2;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { dbpage.c:57 — DbpageTable.  First field MUST be Tsqlite3_vtab. }
  PDbpageTable = ^TDbpageTable;
  TDbpageTable = record
    base     : Tsqlite3_vtab;
    db       : PTsqlite3;
    iDbTrunc : i32;
    pgnoTrunc: Pgno;
  end;

  { dbpage.c:47 — DbpageCursor.  First field MUST be Tsqlite3_vtab_cursor. }
  PDbpageCursor = ^TDbpageCursor;
  TDbpageCursor = record
    base    : Tsqlite3_vtab_cursor;
    pgno    : Pgno;
    mxPgno  : Pgno;
    pPgr  : PPager;
    pPage1  : PDbPage;
    iDb     : i32;
    szPage  : i32;
  end;

{ Module entry point — dbpage.c:470.  Installs the module on db under
  the name "sqlite_dbpage" and returns the registry slot. }
function sqlite3DbpageRegister(db: PTsqlite3): PVtabModule;

{ Public Tsqlite3_module record (dbpage_module, dbpage.c:471).  Exposed
  so gate tests can read its slot pointers without going through the
  registry. }
var
  dbpageModule: Tsqlite3_module;

implementation

{ ============================================================
  Local shims
  ============================================================ }

{ Tiny mprintf replacement for the xUpdate error path.  Mirrors
  carrayFmtMsg (6.bis.2b).  Allocated via sqlite3Malloc so the caller
  can release it with sqlite3_free. }
function dbpageFmtMsg(const fmt: AnsiString; const arg: AnsiString): PAnsiChar;
var
  s: AnsiString;
  z: PAnsiChar;
  n: i32;
begin
  if Pos('%', fmt) > 0 then
    s := SysUtils.Format(string(fmt), [string(arg)])
  else
    s := fmt;
  n := Length(s);
  z := PAnsiChar(sqlite3Malloc(n + 1));
  if z = nil then begin Result := nil; Exit; end;
  if n > 0 then Move(PAnsiChar(s)^, z^, n);
  z[n] := #0;
  Result := z;
end;

{ ============================================================
  Static module callbacks
  ============================================================ }

{ dbpage.c:73 — xConnect (also used as xCreate per dbpage_module slot). }
function dbpageConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pTab: PDbpageTable;
  rc:   i32;
begin
  pTab := nil;
  rc   := SQLITE_OK;

  sqlite3_vtab_config(db, SQLITE_VTAB_DIRECTONLY, 0);
  sqlite3_vtab_config(db, SQLITE_VTAB_USES_ALL_SCHEMAS, 0);
  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE x(pgno INTEGER PRIMARY KEY, data BLOB, schema HIDDEN)');
  if rc = SQLITE_OK then begin
    pTab := PDbpageTable(sqlite3Malloc(SizeOf(TDbpageTable)));
    if pTab = nil then rc := SQLITE_NOMEM;
  end;
  if rc = SQLITE_OK then begin
    FillChar(pTab^, SizeOf(TDbpageTable), 0);
    pTab^.db := db;
  end;
  ppVtab^ := PSqlite3Vtab(pTab);
  Result  := rc;
end;

{ dbpage.c:109 — xDisconnect (also xDestroy slot). }
function dbpageDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ dbpage.c:122 — xBestIndex.

  idxNum encoding:
    0  schema=main, full table scan
    1  schema=main, pgno=?1
    2  schema=?1,   full table scan
    3  schema=?1,   pgno=?2 }
function dbpageBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i, iPlan: i32;
  pC:       PSqlite3IndexConstraint;
  pUse:     PSqlite3IndexConstraintUsage;
  pOrder:   PSqlite3IndexOrderBy;
begin
  iPlan := 0;

  { Schema constraint must be honored if present. }
  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if (pC^.iColumn = DBPAGE_COLUMN_SCHEMA)
       and (pC^.op = SQLITE_INDEX_CONSTRAINT_EQ) then begin
      if pC^.usable = 0 then begin
        Result := SQLITE_CONSTRAINT; Exit;
      end;
      iPlan := 2;
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, i);
      pUse^.argvIndex := 1;
      pUse^.omit      := 1;
      Break;
    end;
    Inc(pC);
  end;

  pIdxInfo^.estimatedCost := 1.0e6;

  { Check for pgno constraint (column 0 — pgno is the rowid alias, so
    iColumn<=0 catches both the explicit column and the implicit ROWID). }
  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if (pC^.usable <> 0) and (pC^.iColumn <= 0)
       and (pC^.op = SQLITE_INDEX_CONSTRAINT_EQ) then begin
      pIdxInfo^.estimatedRows := 1;
      pIdxInfo^.idxFlags      := SQLITE_INDEX_SCAN_UNIQUE;
      pIdxInfo^.estimatedCost := 1.0;
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, i);
      if iPlan <> 0 then pUse^.argvIndex := 2 else pUse^.argvIndex := 1;
      pUse^.omit      := 1;
      iPlan := iPlan or 1;
      Break;
    end;
    Inc(pC);
  end;
  pIdxInfo^.idxNum := iPlan;

  if pIdxInfo^.nOrderBy >= 1 then begin
    pOrder := pIdxInfo^.aOrderBy;
    if (pOrder^.iColumn <= 0) and (pOrder^.desc = 0) then
      pIdxInfo^.orderByConsumed := 1;
  end;
  Result := SQLITE_OK;
end;

{ dbpage.c:178 — xOpen. }
function dbpageOpen(p: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PDbpageCursor;
begin
  pCsr := PDbpageCursor(sqlite3Malloc(SizeOf(TDbpageCursor)));
  if pCsr = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCsr^, SizeOf(TDbpageCursor), 0);
  pCsr^.base.pVtab := p;
  pCsr^.pgno       := 0;
  ppCursor^        := PSqlite3VtabCursor(@pCsr^.base);
  Result := SQLITE_OK;
end;

{ dbpage.c:197 — xClose. }
function dbpageClose(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PDbpageCursor;
begin
  pCsr := PDbpageCursor(cur);
  if pCsr^.pPage1 <> nil then sqlite3PagerUnrefPageOne(pCsr^.pPage1);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ dbpage.c:207 — xNext. }
function dbpageNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PDbpageCursor;
begin
  pCsr := PDbpageCursor(cur);
  Inc(pCsr^.pgno);
  Result := SQLITE_OK;
end;

{ dbpage.c:214 — xEof. }
function dbpageEof(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PDbpageCursor;
begin
  pCsr := PDbpageCursor(cur);
  if pCsr^.pgno > pCsr^.mxPgno then Result := 1 else Result := 0;
end;

{ dbpage.c:229 — xFilter. }
function dbpageFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCsr:    PDbpageCursor;
  pTab:    PDbpageTable;
  db:      PTsqlite3;
  pBt:     PBtree;
  zSchema: PAnsiChar;
  rc:      i32;
begin
  pCsr := PDbpageCursor(cur);
  pTab := PDbpageTable(pCsr^.base.pVtab);
  db   := pTab^.db;

  { Default: no rows. }
  pCsr^.pgno   := 1;
  pCsr^.mxPgno := 0;

  if (idxNum and 2) <> 0 then begin
    Assert(argc >= 1, 'dbpageFilter: schema arg expected');
    zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
    pCsr^.iDb := sqlite3FindDbName(db, zSchema);
    if pCsr^.iDb < 0 then begin Result := SQLITE_OK; Exit; end;
  end else begin
    pCsr^.iDb := 0;
  end;
  pBt := PBtree(db^.aDb[pCsr^.iDb].pBt);
  if pBt = nil then begin Result := SQLITE_OK; Exit; end;
  pCsr^.pPgr := sqlite3BtreePager(pBt);
  pCsr^.szPage := sqlite3BtreeGetPageSize(pBt);
  pCsr^.mxPgno := sqlite3BtreeLastPage(pBt);
  if (idxNum and 1) <> 0 then begin
    Assert(argc > (idxNum shr 1), 'dbpageFilter: pgno arg expected');
    pCsr^.pgno := Pgno(sqlite3_value_int(argv[idxNum shr 1]));
    if (pCsr^.pgno < 1) or (pCsr^.pgno > pCsr^.mxPgno) then begin
      pCsr^.pgno   := 1;
      pCsr^.mxPgno := 0;
    end else begin
      pCsr^.mxPgno := pCsr^.pgno;
    end;
  end else begin
    Assert(pCsr^.pgno = 1, 'dbpageFilter: pgno default 1');
  end;
  if pCsr^.pPage1 <> nil then sqlite3PagerUnrefPageOne(pCsr^.pPage1);
  rc := sqlite3PagerGet(pCsr^.pPgr, 1, @pCsr^.pPage1, 0);
  Result := rc;
end;

{ dbpage.c:278 — xColumn. }
function dbpageColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: i32): i32; cdecl;
var
  pCsr:    PDbpageCursor;
  pTab:    PDbpageTable;
  rc:      i32;
  pDbPg: PDbPage;
  pendingPg: Pgno;
begin
  pCsr := PDbpageCursor(cur);
  rc   := SQLITE_OK;
  case i of
    DBPAGE_COLUMN_PGNO: begin
      sqlite3_result_int64(ctx, i64(pCsr^.pgno));
    end;
    DBPAGE_COLUMN_DATA: begin
      pDbPg  := nil;
      pendingPg := Pgno(PENDING_BYTE div u32(pCsr^.szPage)) + 1;
      if pCsr^.pgno = pendingPg then begin
        { Pending-byte page — assume zeroed; reading via the pager
          would be SQLITE_CORRUPT. }
        sqlite3_result_zeroblob64(ctx, u64(pCsr^.szPage));
      end else begin
        rc := sqlite3PagerGet(pCsr^.pPgr, pCsr^.pgno, @pDbPg, 0);
        if rc = SQLITE_OK then
          sqlite3_result_blob(ctx, sqlite3PagerGetData(pDbPg),
            pCsr^.szPage, SQLITE_TRANSIENT);
        sqlite3PagerUnref(pDbPg);
      end;
    end;
  else
    { schema column. }
    pTab := PDbpageTable(pCsr^.base.pVtab);
    sqlite3_result_text(ctx, pTab^.db^.aDb[pCsr^.iDb].zDbSName, -1,
      SQLITE_STATIC);
  end;
  Result := rc;
end;

{ dbpage.c:315 — xRowid. }
function dbpageRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var
  pCsr: PDbpageCursor;
begin
  pCsr := PDbpageCursor(cur);
  pRowid^ := i64(pCsr^.pgno);
  Result := SQLITE_OK;
end;

{ dbpage.c:328 — open writable transactions on every attached db. }
function dbpageBeginTrans(pTab: PDbpageTable): i32;
var
  i, rc: i32;
  pBt:   PBtree;
begin
  rc := SQLITE_OK;
  i  := 0;
  while (rc = SQLITE_OK) and (i < pTab^.db^.nDb) do begin
    pBt := PBtree(pTab^.db^.aDb[i].pBt);
    if pBt <> nil then rc := sqlite3BtreeBeginTrans(pBt, 1, nil);
    Inc(i);
  end;
  Result := rc;
end;

{ dbpage.c:339 — xUpdate.  argv layout (vtab xUpdate convention):
    argv[0] : old rowid (NULL on INSERT)
    argv[1] : new rowid
    argv[2..] : new column values (pgno, data, schema) }
function dbpageUpdate(pVtab: PSqlite3Vtab;
  argc: i32; argv: PPsqlite3_value;
  pRowid: Pi64): i32; cdecl;
var
  pTab:    PDbpageTable;
  pg:      Pgno;
  pDbPg: PDbPage;
  rc:      i32;
  zErr:    AnsiString;
  iDb:     i32;
  pBt:     PBtree;
  pPgr:  PPager;
  szPage:  i32;
  isInsert:i32;
  zSchema: PAnsiChar;
  pData:   Pointer;
  aPage:   PAnsiChar;
label
  update_fail;
begin
  pTab    := PDbpageTable(pVtab);
  pDbPg := nil;
  rc      := SQLITE_OK;
  zErr    := '';
  pg      := 0;
  isInsert:= 0;

  if (pTab^.db^.flags and SQLITE_Defensive_Bit) <> 0 then begin
    zErr := 'read-only';
    goto update_fail;
  end;
  if argc = 1 then begin
    zErr := 'cannot delete';
    goto update_fail;
  end;
  if sqlite3_value_type(argv[0]) = SQLITE_NULL then begin
    pg       := Pgno(sqlite3_value_int64(argv[2]));
    isInsert := 1;
  end else begin
    pg := Pgno(sqlite3_value_int64(argv[0]));
    if Pgno(sqlite3_value_int(argv[1])) <> pg then begin
      zErr := 'cannot insert';
      goto update_fail;
    end;
    isInsert := 0;
  end;
  if sqlite3_value_type(argv[4]) = SQLITE_NULL then begin
    iDb := 0;
  end else begin
    zSchema := PAnsiChar(sqlite3_value_text(argv[4]));
    iDb := sqlite3FindDbName(pTab^.db, zSchema);
    if iDb < 0 then begin
      zErr := 'no such schema';
      goto update_fail;
    end;
  end;
  pBt := PBtree(pTab^.db^.aDb[iDb].pBt);
  if (pg < 1) or (pBt = nil) then begin
    zErr := 'bad page number';
    goto update_fail;
  end;
  szPage := sqlite3BtreeGetPageSize(pBt);
  if (sqlite3_value_type(argv[3]) <> SQLITE_BLOB)
     or (sqlite3_value_bytes(argv[3]) <> szPage) then begin
    if (sqlite3_value_type(argv[3]) = SQLITE_NULL)
       and (isInsert <> 0) and (pg > 1) then begin
      { "INSERT INTO sqlite_dbpage($PGNO, NULL)" → truncate from $PGNO. }
      pTab^.iDbTrunc  := iDb;
      pTab^.pgnoTrunc := pg - 1;
      pg := 1;
    end else begin
      zErr := 'bad page value';
      goto update_fail;
    end;
  end;

  if dbpageBeginTrans(pTab) <> SQLITE_OK then begin
    zErr := 'failed to open transaction';
    goto update_fail;
  end;

  pPgr := sqlite3BtreePager(pBt);
  rc := sqlite3PagerGet(pPgr, pg, @pDbPg, 0);
  if rc = SQLITE_OK then begin
    pData := sqlite3_value_blob(argv[3]);
    rc := sqlite3PagerWrite(pDbPg);
    if (rc = SQLITE_OK) and (pData <> nil) then begin
      aPage := PAnsiChar(sqlite3PagerGetData(pDbPg));
      Move(pData^, aPage^, szPage);
      pTab^.pgnoTrunc := 0;
    end;
  end;
  if rc <> SQLITE_OK then pTab^.pgnoTrunc := 0;
  sqlite3PagerUnref(pDbPg);
  Result := rc;
  Exit;

update_fail:
  pTab^.pgnoTrunc := 0;
  sqlite3_free(pVtab^.zErrMsg);
  pVtab^.zErrMsg := dbpageFmtMsg('%s', zErr);
  Result := SQLITE_ERROR;
end;

{ dbpage.c:435 — xBegin. }
function dbpageBegin(pVtab: PSqlite3Vtab): i32; cdecl;
var
  pTab: PDbpageTable;
begin
  pTab := PDbpageTable(pVtab);
  pTab^.pgnoTrunc := 0;
  Result := SQLITE_OK;
end;

{ dbpage.c:443 — xSync.  Truncate just before COMMIT if requested. }
function dbpageSync(pVtab: PSqlite3Vtab): i32; cdecl;
var
  pTab:   PDbpageTable;
  pBt:    PBtree;
  pPgr: PPager;
begin
  pTab := PDbpageTable(pVtab);
  if pTab^.pgnoTrunc > 0 then begin
    pBt    := PBtree(pTab^.db^.aDb[pTab^.iDbTrunc].pBt);
    pPgr := sqlite3BtreePager(pBt);
    sqlite3BtreeEnter(pBt);
    if pTab^.pgnoTrunc < sqlite3BtreeLastPage(pBt) then
      sqlite3PagerTruncateImage(pPgr, pTab^.pgnoTrunc);
    sqlite3BtreeLeave(pBt);
  end;
  pTab^.pgnoTrunc := 0;
  Result := SQLITE_OK;
end;

{ dbpage.c:460 — xRollbackTo: cancel any pending truncate. }
function dbpageRollbackTo(pVtab: PSqlite3Vtab; notUsed1: i32): i32; cdecl;
var
  pTab: PDbpageTable;
begin
  pTab := PDbpageTable(pVtab);
  pTab^.pgnoTrunc := 0;
  Result := SQLITE_OK;
end;

{ ============================================================
  Module registration — dbpage.c:470
  ============================================================ }

function sqlite3DbpageRegister(db: PTsqlite3): PVtabModule;
begin
  Result := sqlite3VtabCreateModule(db, 'sqlite_dbpage', @dbpageModule, nil, nil);
end;

initialization
  FillChar(dbpageModule, SizeOf(dbpageModule), 0);
  dbpageModule.iVersion    := 2;
  dbpageModule.xCreate     := @dbpageConnect;
  dbpageModule.xConnect    := @dbpageConnect;
  dbpageModule.xBestIndex  := @dbpageBestIndex;
  dbpageModule.xDisconnect := @dbpageDisconnect;
  dbpageModule.xDestroy    := @dbpageDisconnect;
  dbpageModule.xOpen       := @dbpageOpen;
  dbpageModule.xClose      := @dbpageClose;
  dbpageModule.xFilter     := @dbpageFilter;
  dbpageModule.xNext       := @dbpageNext;
  dbpageModule.xEof        := @dbpageEof;
  dbpageModule.xColumn     := @dbpageColumn;
  dbpageModule.xRowid      := @dbpageRowid;
  dbpageModule.xUpdate     := @dbpageUpdate;
  dbpageModule.xBegin      := @dbpageBegin;
  dbpageModule.xSync       := @dbpageSync;
  dbpageModule.xRollbackTo := @dbpageRollbackTo;
end.
