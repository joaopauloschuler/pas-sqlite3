{$I passqlite3.inc}
unit passqlite3dbstat;

{
  Phase 6.bis.2d — port of ../sqlite3/src/dbstat.c (the dbstat virtual
  table; 906 lines in C).  Largest of the three in-tree vtabs.

  dbstat exposes B-tree storage statistics: cell counts, payload sizes,
  page paths, page offsets — used by the sqlite3_analyzer utility.

  Schema (dbstat.c:68..82):

      CREATE TABLE x(
        name TEXT, path TEXT, pageno INTEGER, pagetype TEXT,
        ncell INTEGER, payload INTEGER, unused INTEGER,
        mx_payload INTEGER, pgoffset INTEGER, pgsize INTEGER,
        schema TEXT HIDDEN, aggregate BOOLEAN HIDDEN
      );

  Module is v1 (iVersion=0); read-only — xUpdate/xBegin/etc are nil.
  xCreate==xConnect makes it both eponymous-able and CREATE-able.

  Carry-overs / shims:
    * `sqlite3_mprintf` is still not ported.  Local `statFmtMsg` /
      `statFmtPath` mirror the dbpage / carray pattern and now make the
      FOURTH copy of this shim — promote to a shared helper when the
      printf sub-phase lands.
    * `sqlite3_str_new` / `sqlite3_str_appendf` / `sqlite3_str_finish`
      are NOT ported.  statFilter builds its query through a small local
      `statBuildSql` AnsiString concatenator with manual escaping of
      identifier (`%w` doubles ") and literal (`%Q` quotes ') patterns,
      sufficient for dbstat.c:776..788.  Replace with the real
      sqlite3_str_* family when the printf sub-phase lands.
    * `sqlite3TokenInit` is not exposed.  statConnect calls
      sqlite3FindDbName directly with argv[3] as a C string instead of
      synthesising a Token.  Equivalent semantics for the non-quoted
      schema-name case (which is the normal one).
    * `sqlite3_context_db_handle` is not ported (carry-over from dbpage).
      statColumn derives `db` via cursor->base.pVtab->db, matching the
      dbpage workaround.
    * `SQLITE_VTAB_DIRECTONLY` is wired via sqlite3_vtab_config (already
      ported in 6.bis.1e).

  Gate: src/tests/TestDbstat.pas exercises module registration,
  the static slot layout (v1 — only read-side slots wired), all four
  statBestIndex constraint dispatch branches plus the SQLITE_CONSTRAINT
  failure path, and the cursor open/close/reset state machine.  Live-db
  paths (statFilter, statNext page-walk, statColumn) are deferred to the
  end-to-end SQL gate (6.9) — they require a real Btree-backed
  connection and a working sqlite3_prepare_v2 path through the parser.
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
  passqlite3main,
  passqlite3codegen;

const
  { dbstat.c:35 — over-read padding bytes appended to each page buffer. }
  DBSTAT_PAGE_PADDING_BYTES = 256;

  { dbstat.c:125 — depth of the page-stack array on the cursor. }
  STAT_PAGE_NEST = 32;

  { dbstat.c column ordinals (positions in zDbstatSchema). }
  DBSTAT_COLUMN_NAME       = 0;
  DBSTAT_COLUMN_PATH       = 1;
  DBSTAT_COLUMN_PAGENO     = 2;
  DBSTAT_COLUMN_PAGETYPE   = 3;
  DBSTAT_COLUMN_NCELL      = 4;
  DBSTAT_COLUMN_PAYLOAD    = 5;
  DBSTAT_COLUMN_UNUSED     = 6;
  DBSTAT_COLUMN_MX_PAYLOAD = 7;
  DBSTAT_COLUMN_PGOFFSET   = 8;
  DBSTAT_COLUMN_PGSIZE     = 9;
  DBSTAT_COLUMN_SCHEMA     = 10;
  DBSTAT_COLUMN_AGGREGATE  = 11;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { dbstat.c:92 — StatCell. }
  PStatCell = ^TStatCell;
  TStatCell = record
    nLocal     : i32;     { Bytes of local payload }
    iChildPg   : u32;     { Child node (or 0 if this is a leaf) }
    nOvfl      : i32;     { Entries in aOvfl[] }
    aOvfl      : ^u32;    { Array of overflow page numbers }
    nLastOvfl  : i32;     { Bytes of payload on final overflow page }
    iOvfl      : i32;     { Iterates through aOvfl[] }
  end;

  { dbstat.c:102 — StatPage. }
  PStatPage = ^TStatPage;
  TStatPage = record
    iPgno         : u32;
    aPg           : Pu8;
    iCell         : i32;
    zPath         : PAnsiChar;
    { Variables populated by statDecodePage(): }
    flags         : u8;
    _pad0         : u8;
    _pad1         : u16;
    nCell         : i32;
    nUnused       : i32;
    aCell         : PStatCell;
    iRightChildPg : u32;
    nMxPayload    : i32;
  end;

  { dbstat.c:118 — StatCursor.  First field MUST be Tsqlite3_vtab_cursor. }
  PStatCursor = ^TStatCursor;
  TStatCursor = record
    base       : Tsqlite3_vtab_cursor;
    pStmt      : Pointer;        { sqlite3_stmt* — iterates root pages }
    isEof      : u8;
    isAgg      : u8;
    _pad0      : u16;
    iDb        : i32;

    aPage      : array[0..STAT_PAGE_NEST-1] of TStatPage;
    iPage      : i32;

    { Values to return. }
    iPageno    : u32;
    zName      : PAnsiChar;
    zPath      : PAnsiChar;
    zPagetype  : PAnsiChar;
    nPage      : i32;
    nCell      : i32;
    nMxPayload : i32;
    nUnused    : i64;
    nPayload   : i64;
    iOffset    : i64;
    szPage     : i64;
  end;

  { dbstat.c:143 — StatTable.  First field MUST be Tsqlite3_vtab. }
  PStatTable = ^TStatTable;
  TStatTable = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
    iDb  : i32;
  end;

{ Module entry point — dbstat.c:874.  Installs `dbstat` on db. }
function sqlite3DbstatRegister(db: PTsqlite3): PVtabModule;

{ Public Tsqlite3_module record so gate tests can read its slot pointers. }
var
  dbstatModule: Tsqlite3_module;

implementation

{ ============================================================
  Schema (dbstat.c:68)
  ============================================================ }
const
  zDbstatSchema: PAnsiChar =
    'CREATE TABLE x('
    + ' name       TEXT,'
    + ' path       TEXT,'
    + ' pageno     INTEGER,'
    + ' pagetype   TEXT,'
    + ' ncell      INTEGER,'
    + ' payload    INTEGER,'
    + ' unused     INTEGER,'
    + ' mx_payload INTEGER,'
    + ' pgoffset   INTEGER,'
    + ' pgsize     INTEGER,'
    + ' schema     TEXT HIDDEN,'
    + ' aggregate  BOOLEAN HIDDEN'
    + ')';

{ ============================================================
  Local shims — printf-family and SQL-builder
  ============================================================ }

{ Phase 6.bis follow-up (2026-04-26): error-message %s shim now delegates
  to the shared sqlite3VtabFmtMsg1Libc helper in passqlite3vtab. }

{ Build "/<3hex>/" or "/<3hex>+<6hex>" path strings (dbstat.c:599, 670, 707).
  Returns sqlite3Malloc'd PAnsiChar; nil on OOM. }
function statFmtPath(const tmpl: AnsiString; zPath: PAnsiChar;
  i, j: i32): PAnsiChar;
var
  s, prefix: AnsiString;
  z: PAnsiChar;
  n: i32;
begin
  if zPath = nil then prefix := '' else prefix := AnsiString(zPath);
  if tmpl = '/' then
    s := '/'
  else if tmpl = '%s%.3x/' then
    s := prefix + AnsiString(LowerCase(IntToHex(i, 3)) + '/')
  else if tmpl = '%s%.3x+%.6x' then
    s := prefix + AnsiString(LowerCase(IntToHex(i, 3) + '+' + IntToHex(j, 6)))
  else if tmpl = '%s' then
    s := prefix
  else
    s := prefix;
  n := Length(s);
  z := PAnsiChar(sqlite3Malloc(n + 1));
  if z = nil then begin Result := nil; Exit; end;
  if n > 0 then Move(PAnsiChar(s)^, z^, n);
  z[n] := #0;
  Result := z;
end;

{ Escape an identifier per sqlite3 %w (double any embedded "). }
function escIdent(const s: AnsiString): AnsiString;
var i: i32;
begin
  Result := '';
  for i := 1 to Length(s) do begin
    if s[i] = '"' then Result := Result + '""'
    else Result := Result + s[i];
  end;
end;

{ Escape a string literal per sqlite3 %Q (quote with ', double any
  embedded ').  NULL → 'NULL' (no quotes). }
function escLiteral(zVal: PAnsiChar): AnsiString;
var s: AnsiString; i: i32;
begin
  if zVal = nil then begin Result := 'NULL'; Exit; end;
  s := AnsiString(zVal);
  Result := '''';
  for i := 1 to Length(s) do begin
    if s[i] = '''' then Result := Result + ''''''
    else Result := Result + s[i];
  end;
  Result := Result + '''';
end;

{ Build the dbstat WHERE-walking SELECT (dbstat.c:776..788).  Returns
  sqlite3Malloc'd null-terminated string, or nil on OOM. }
function statBuildSql(zSchema: PAnsiChar; zName: PAnsiChar;
  bOrder: Boolean): PAnsiChar;
var
  s: AnsiString;
  n: i32;
  z: PAnsiChar;
begin
  s := 'SELECT * FROM ('
     + 'SELECT ''sqlite_schema'' AS name,1 AS rootpage,''table'' AS type'
     + ' UNION ALL '
     + 'SELECT name,rootpage,type'
     + ' FROM "' + escIdent(AnsiString(zSchema)) + '".sqlite_schema'
     + ' WHERE rootpage!=0)';
  if zName <> nil then
    s := s + 'WHERE name=' + escLiteral(zName);
  if bOrder then
    s := s + ' ORDER BY name';
  n := Length(s);
  z := PAnsiChar(sqlite3Malloc(n + 1));
  if z = nil then begin Result := nil; Exit; end;
  if n > 0 then Move(PAnsiChar(s)^, z^, n);
  z[n] := #0;
  Result := z;
end;

{ ============================================================
  StatPage helpers — dbstat.c:307..353
  ============================================================ }

procedure statClearCells(p: PStatPage);
var
  i: i32;
begin
  if p^.aCell <> nil then begin
    for i := 0 to p^.nCell - 1 do begin
      sqlite3_free((p^.aCell + i)^.aOvfl);
    end;
    sqlite3_free(p^.aCell);
  end;
  p^.nCell := 0;
  p^.aCell := nil;
end;

procedure statClearPage(p: PStatPage);
var
  aPg: Pu8;
begin
  aPg := p^.aPg;
  statClearCells(p);
  sqlite3_free(p^.zPath);
  FillChar(p^, SizeOf(TStatPage), 0);
  p^.aPg := aPg;
end;

procedure statResetCsr(pCsr: PStatCursor);
var i: i32;
begin
  for i := 0 to STAT_PAGE_NEST - 1 do begin
    statClearPage(@pCsr^.aPage[i]);
    sqlite3_free(pCsr^.aPage[i].aPg);
    pCsr^.aPage[i].aPg := nil;
  end;
  if pCsr^.pStmt <> nil then
    sqlite3_reset(PVdbe(pCsr^.pStmt));
  pCsr^.iPage := 0;
  sqlite3_free(pCsr^.zPath);
  pCsr^.zPath := nil;
  pCsr^.isEof := 0;
end;

procedure statResetCounts(pCsr: PStatCursor);
begin
  pCsr^.nCell      := 0;
  pCsr^.nMxPayload := 0;
  pCsr^.nUnused    := 0;
  pCsr^.nPayload   := 0;
  pCsr^.szPage     := 0;
  pCsr^.nPage      := 0;
end;

{ ============================================================
  Static module callbacks — dbstat.c:156..869
  ============================================================ }

{ dbstat.c:156 — xConnect (also xCreate per dbstat_module slot). }
function statConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pTab: PStatTable;
  rc:   i32;
  iDb:  i32;
  zDb:  PAnsiChar;
  argvArr: ^PAnsiChar;
begin
  pTab := nil;
  rc   := SQLITE_OK;

  if argc >= 4 then begin
    argvArr := Pointer(argv);
    zDb := (argvArr + 3)^;
    iDb := sqlite3FindDbName(db, zDb);
    if iDb < 0 then begin
      pzErr^ := sqlite3VtabFmtMsg1Libc('no such database: %s', AnsiString(zDb));
      Result := SQLITE_ERROR; Exit;
    end;
  end else begin
    iDb := 0;
  end;
  sqlite3_vtab_config(db, SQLITE_VTAB_DIRECTONLY, 0);
  rc := sqlite3_declare_vtab(db, zDbstatSchema);
  if rc = SQLITE_OK then begin
    pTab := PStatTable(sqlite3Malloc(SizeOf(TStatTable)));
    if pTab = nil then rc := SQLITE_NOMEM;
  end;
  Assert((rc = SQLITE_OK) or (pTab = nil), 'statConnect alloc invariant');
  if rc = SQLITE_OK then begin
    FillChar(pTab^, SizeOf(TStatTable), 0);
    pTab^.db  := db;
    pTab^.iDb := iDb;
  end;
  ppVtab^ := PSqlite3Vtab(pTab);
  Result  := rc;
end;

{ dbstat.c:200 — xDisconnect (also xDestroy slot). }
function statDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ dbstat.c:215 — xBestIndex. }
function statBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i, idx: i32;
  iSchema, iName, iAgg: i32;
  pC:    PSqlite3IndexConstraint;
  pUse:  PSqlite3IndexConstraintUsage;
  pOrd0, pOrd1: PSqlite3IndexOrderBy;
  consumeOrder: Boolean;
begin
  iSchema := -1;
  iName   := -1;
  iAgg    := -1;

  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if pC^.op = SQLITE_INDEX_CONSTRAINT_EQ then begin
      if pC^.usable = 0 then begin
        Result := SQLITE_CONSTRAINT; Exit;
      end;
      case pC^.iColumn of
        DBSTAT_COLUMN_NAME:      iName   := i;
        DBSTAT_COLUMN_SCHEMA:    iSchema := i;
        DBSTAT_COLUMN_AGGREGATE: iAgg    := i;
      end;
    end;
    Inc(pC);
  end;

  idx := 0;
  if iSchema >= 0 then begin
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, iSchema);
    Inc(idx);
    pUse^.argvIndex := idx;
    pUse^.omit      := 1;
    pIdxInfo^.idxNum := pIdxInfo^.idxNum or $01;
  end;
  if iName >= 0 then begin
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, iName);
    Inc(idx);
    pUse^.argvIndex := idx;
    pIdxInfo^.idxNum := pIdxInfo^.idxNum or $02;
  end;
  if iAgg >= 0 then begin
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, iAgg);
    Inc(idx);
    pUse^.argvIndex := idx;
    pIdxInfo^.idxNum := pIdxInfo^.idxNum or $04;
  end;
  pIdxInfo^.estimatedCost := 1.0;

  consumeOrder := False;
  if pIdxInfo^.nOrderBy = 1 then begin
    pOrd0 := pIdxInfo^.aOrderBy;
    if (pOrd0^.iColumn = 0) and (pOrd0^.desc = 0) then
      consumeOrder := True;
  end else if pIdxInfo^.nOrderBy = 2 then begin
    pOrd0 := pIdxInfo^.aOrderBy;
    pOrd1 := pIdxInfo^.aOrderBy; Inc(pOrd1);
    if (pOrd0^.iColumn = 0) and (pOrd0^.desc = 0)
       and (pOrd1^.iColumn = 1) and (pOrd1^.desc = 0) then
      consumeOrder := True;
  end;
  if consumeOrder then begin
    pIdxInfo^.orderByConsumed := 1;
    pIdxInfo^.idxNum := pIdxInfo^.idxNum or $08;
  end;
  pIdxInfo^.idxFlags := pIdxInfo^.idxFlags or SQLITE_INDEX_SCAN_HEX;

  Result := SQLITE_OK;
end;

{ dbstat.c:290 — xOpen. }
function statOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pTab: PStatTable;
  pCsr: PStatCursor;
begin
  pTab := PStatTable(pVTab);
  pCsr := PStatCursor(sqlite3Malloc(SizeOf(TStatCursor)));
  if pCsr = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCsr^, SizeOf(TStatCursor), 0);
  pCsr^.base.pVtab := pVTab;
  pCsr^.iDb        := pTab^.iDb;
  ppCursor^        := PSqlite3VtabCursor(@pCsr^.base);
  Result := SQLITE_OK;
end;

{ dbstat.c:358 — xClose. }
function statClose(pCursor: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PStatCursor;
begin
  pCsr := PStatCursor(pCursor);
  statResetCsr(pCsr);
  if pCsr^.pStmt <> nil then sqlite3_finalize(PVdbe(pCsr^.pStmt));
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ dbstat.c:371 — getLocalPayload. }
function getLocalPayload(nUsable: i32; flags: u8; nTotal: i32): i32;
var
  nLocal, nMinLocal, nMaxLocal: i32;
begin
  if flags = $0D then begin
    nMinLocal := (nUsable - 12) * 32 div 255 - 23;
    nMaxLocal := nUsable - 35;
  end else begin
    nMinLocal := (nUsable - 12) * 32 div 255 - 23;
    nMaxLocal := (nUsable - 12) * 64 div 255 - 23;
  end;
  nLocal := nMinLocal + (nTotal - nMinLocal) mod (nUsable - 4);
  if nLocal > nMaxLocal then nLocal := nMinLocal;
  Result := nLocal;
end;

{ dbstat.c:396 — statDecodePage. }
function statDecodePage(pBt: PBtree; p: PStatPage): i32;
var
  nUnused, iOff, nHdr, isLeaf, szPage: i32;
  aData, aHdr: Pu8;
  iNext: i32;
  i, nUsable: i32;
  pCell: PStatCell;
  nPayload32: u32;
  nLocal: i32;
  dummy: u64;
  nOvfl, jj: i32;
  iPrev: u32;
  pDbPg: PDbPage;
  rc: i32;
label
  statPageIsCorrupt;
begin
  aData := p^.aPg;
  if p^.iPgno = 1 then aHdr := aData + 100 else aHdr := aData;

  p^.flags := aHdr[0];
  if (p^.flags = $0A) or (p^.flags = $0D) then begin
    isLeaf := 1; nHdr := 8;
  end else if (p^.flags = $05) or (p^.flags = $02) then begin
    isLeaf := 0; nHdr := 12;
  end else begin
    goto statPageIsCorrupt;
  end;
  if p^.iPgno = 1 then nHdr := nHdr + 100;
  p^.nCell := (i32(aHdr[3]) shl 8) or i32(aHdr[4]);
  p^.nMxPayload := 0;
  szPage := sqlite3BtreeGetPageSize(pBt);

  nUnused := ((i32(aHdr[5]) shl 8) or i32(aHdr[6])) - nHdr - 2 * p^.nCell;
  nUnused := nUnused + i32(aHdr[7]);
  iOff := (i32(aHdr[1]) shl 8) or i32(aHdr[2]);
  while iOff <> 0 do begin
    if iOff >= szPage then goto statPageIsCorrupt;
    nUnused := nUnused + ((i32((aData + iOff + 2)^) shl 8)
                         or i32((aData + iOff + 3)^));
    iNext := (i32((aData + iOff)^) shl 8) or i32((aData + iOff + 1)^);
    if (iNext < iOff + 4) and (iNext > 0) then goto statPageIsCorrupt;
    iOff := iNext;
  end;
  p^.nUnused := nUnused;
  if isLeaf <> 0 then p^.iRightChildPg := 0
  else p^.iRightChildPg := sqlite3Get4byte(aHdr + 8);

  if p^.nCell <> 0 then begin
    sqlite3BtreeEnter(pBt);
    nUsable := szPage - sqlite3BtreeGetReserveNoMutex(pBt);
    sqlite3BtreeLeave(pBt);
    p^.aCell := PStatCell(sqlite3Malloc((p^.nCell + 1) * SizeOf(TStatCell)));
    if p^.aCell = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(p^.aCell^, (p^.nCell + 1) * SizeOf(TStatCell), 0);

    for i := 0 to p^.nCell - 1 do begin
      pCell := p^.aCell; Inc(pCell, i);
      iOff := (i32((aData + nHdr + i*2)^) shl 8)
              or i32((aData + nHdr + i*2 + 1)^);
      if (iOff < nHdr) or (iOff >= szPage) then goto statPageIsCorrupt;
      if isLeaf = 0 then begin
        pCell^.iChildPg := sqlite3Get4byte(aData + iOff);
        iOff := iOff + 4;
      end;
      if p^.flags = $05 then begin
        { table interior — nPayload==0 }
      end else begin
        iOff := iOff + i32(sqlite3GetVarint32(aData + iOff, nPayload32));
        if p^.flags = $0D then
          iOff := iOff + i32(sqlite3GetVarint(aData + iOff, dummy));
        if i32(nPayload32) > p^.nMxPayload then
          p^.nMxPayload := i32(nPayload32);
        nLocal := getLocalPayload(nUsable, p^.flags, i32(nPayload32));
        if nLocal < 0 then goto statPageIsCorrupt;
        pCell^.nLocal := nLocal;
        Assert(nPayload32 >= u32(nLocal), 'statDecodePage: nPayload>=nLocal');
        Assert(nLocal <= nUsable - 35, 'statDecodePage: nLocal<=nUsable-35');
        if nPayload32 > u32(nLocal) then begin
          nOvfl := (i32(nPayload32) - nLocal + nUsable - 4 - 1) div (nUsable - 4);
          if (iOff + nLocal + 4 > nUsable) or (nPayload32 > $7FFFFFFF) then
            goto statPageIsCorrupt;
          pCell^.nLastOvfl := (i32(nPayload32) - nLocal) - (nOvfl - 1) * (nUsable - 4);
          pCell^.nOvfl := nOvfl;
          pCell^.aOvfl := sqlite3Malloc(SizeOf(u32) * nOvfl);
          if pCell^.aOvfl = nil then begin Result := SQLITE_NOMEM; Exit; end;
          pCell^.aOvfl^ := sqlite3Get4byte(aData + iOff + nLocal);
          for jj := 1 to nOvfl - 1 do begin
            iPrev := (pCell^.aOvfl + (jj - 1))^;
            pDbPg := nil;
            rc := sqlite3PagerGet(sqlite3BtreePager(pBt), iPrev, @pDbPg, 0);
            if rc <> SQLITE_OK then begin
              Assert(pDbPg = nil, 'statDecodePage: PagerGet leaks');
              Result := rc; Exit;
            end;
            (pCell^.aOvfl + jj)^ := sqlite3Get4byte(Pu8(sqlite3PagerGetData(pDbPg)));
            sqlite3PagerUnref(pDbPg);
          end;
        end;
      end;
    end;
  end;
  Result := SQLITE_OK; Exit;

statPageIsCorrupt:
  p^.flags := 0;
  statClearCells(p);
  Result := SQLITE_OK;
end;

{ dbstat.c:511 — statSizeAndOffset. }
procedure statSizeAndOffset(pCsr: PStatCursor);
var
  pTab:  PStatTable;
  pBt:   PBtree;
  pPgr:  PPager;
  fd:    Psqlite3_file;
  x:     array[0..1] of i64;
begin
  pTab := PStatTable(PSqlite3VtabCursor(pCsr)^.pVtab);
  pBt  := PBtree(pTab^.db^.aDb[pTab^.iDb].pBt);
  pPgr := sqlite3BtreePager(pBt);
  fd   := sqlite3PagerFile(pPgr);
  x[0] := pCsr^.iPageno;
  if sqlite3OsFileControl(fd, 230440, @x) = SQLITE_OK then begin
    pCsr^.iOffset := x[0];
    pCsr^.szPage  := pCsr^.szPage + x[1];
  end else begin
    pCsr^.szPage  := pCsr^.szPage + sqlite3BtreeGetPageSize(pBt);
    pCsr^.iOffset := i64(pCsr^.szPage) * (i64(pCsr^.iPageno) - 1);
  end;
end;

{ dbstat.c:538 — statGetPage. }
function statGetPage(pBt: PBtree; iPg: u32; pPg: PStatPage): i32;
var
  pgsz: i32;
  pDbPg: PDbPage;
  rc: i32;
  a: Pointer;
begin
  pgsz := sqlite3BtreeGetPageSize(pBt);
  pDbPg := nil;
  if pPg^.aPg = nil then begin
    pPg^.aPg := Pu8(sqlite3Malloc(pgsz + DBSTAT_PAGE_PADDING_BYTES));
    if pPg^.aPg = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar((pPg^.aPg + pgsz)^, DBSTAT_PAGE_PADDING_BYTES, 0);
  end;
  rc := sqlite3PagerGet(sqlite3BtreePager(pBt), iPg, @pDbPg, 0);
  if rc = SQLITE_OK then begin
    a := sqlite3PagerGetData(pDbPg);
    Move(a^, pPg^.aPg^, pgsz);
    sqlite3PagerUnref(pDbPg);
  end;
  Result := rc;
end;

{ dbstat.c:570 — statNext. }
function statNext(pCursor: PSqlite3VtabCursor): i32; cdecl;
var
  rc, nPayload, i, nUsable, iOvfl, nPg: i32;
  pCsr: PStatCursor;
  pTab: PStatTable;
  pBt:  PBtree;
  pPgr: PPager;
  iRoot: u32;
  p:    PStatPage;
  pCell: PStatCell;
  pNxt: PStatPage;
label
  statNextRestart;
begin
  pCsr := PStatCursor(pCursor);
  pTab := PStatTable(pCursor^.pVtab);
  pBt  := PBtree(pTab^.db^.aDb[pCsr^.iDb].pBt);
  pPgr := sqlite3BtreePager(pBt);
  rc := SQLITE_OK;

  sqlite3_free(pCsr^.zPath);
  pCsr^.zPath := nil;

statNextRestart:
  if pCsr^.iPage < 0 then begin
    statResetCounts(pCsr);
    rc := sqlite3_step(PVdbe(pCsr^.pStmt));
    if rc = SQLITE_ROW then begin
      iRoot := u32(sqlite3_column_int64(PVdbe(pCsr^.pStmt), 1));
      sqlite3PagerPagecount(pPgr, @nPg);
      if nPg = 0 then begin
        pCsr^.isEof := 1;
        Result := sqlite3_reset(PVdbe(pCsr^.pStmt)); Exit;
      end;
      rc := statGetPage(pBt, iRoot, @pCsr^.aPage[0]);
      pCsr^.aPage[0].iPgno := iRoot;
      pCsr^.aPage[0].iCell := 0;
      if pCsr^.isAgg = 0 then begin
        pCsr^.aPage[0].zPath := statFmtPath('/', nil, 0, 0);
        if pCsr^.aPage[0].zPath = nil then rc := SQLITE_NOMEM;
      end;
      pCsr^.iPage := 0;
      pCsr^.nPage := 1;
    end else begin
      pCsr^.isEof := 1;
      Result := sqlite3_reset(PVdbe(pCsr^.pStmt)); Exit;
    end;
  end else begin
    p := @pCsr^.aPage[pCsr^.iPage];
    if pCsr^.isAgg = 0 then statResetCounts(pCsr);
    while p^.iCell < p^.nCell do begin
      pCell := p^.aCell; Inc(pCell, p^.iCell);
      while pCell^.iOvfl < pCell^.nOvfl do begin
        sqlite3BtreeEnter(pBt);
        nUsable := sqlite3BtreeGetPageSize(pBt) - sqlite3BtreeGetReserveNoMutex(pBt);
        sqlite3BtreeLeave(pBt);
        Inc(pCsr^.nPage);
        statSizeAndOffset(pCsr);
        if pCell^.iOvfl < pCell^.nOvfl - 1 then
          pCsr^.nPayload := pCsr^.nPayload + (nUsable - 4)
        else begin
          pCsr^.nPayload := pCsr^.nPayload + pCell^.nLastOvfl;
          pCsr^.nUnused  := pCsr^.nUnused + (nUsable - 4 - pCell^.nLastOvfl);
        end;
        iOvfl := pCell^.iOvfl;
        Inc(pCell^.iOvfl);
        if pCsr^.isAgg = 0 then begin
          pCsr^.zName := PAnsiChar(sqlite3_column_text(PVdbe(pCsr^.pStmt), 0));
          pCsr^.iPageno := (pCell^.aOvfl + iOvfl)^;
          pCsr^.zPagetype := 'overflow';
          pCsr^.zPath := statFmtPath('%s%.3x+%.6x', p^.zPath, p^.iCell, iOvfl);
          if pCsr^.zPath = nil then Result := SQLITE_NOMEM
          else Result := SQLITE_OK;
          Exit;
        end;
      end;
      if p^.iRightChildPg <> 0 then Break;
      Inc(p^.iCell);
    end;

    if (p^.iRightChildPg = 0) or (p^.iCell > p^.nCell) then begin
      statClearPage(p);
      Dec(pCsr^.iPage);
      if (pCsr^.isAgg <> 0) and (pCsr^.iPage < 0) then begin
        Result := SQLITE_OK; Exit;
      end;
      goto statNextRestart;
    end;
    Inc(pCsr^.iPage);
    if pCsr^.iPage >= STAT_PAGE_NEST then begin
      statResetCsr(pCsr);
      Result := SQLITE_CORRUPT_BKPT; Exit;
    end;
    Assert(@pCsr^.aPage[pCsr^.iPage - 1] = p,
      'statNext: page-stack invariant');
    pNxt := @pCsr^.aPage[pCsr^.iPage];
    if p^.iCell = p^.nCell then
      pNxt^.iPgno := p^.iRightChildPg
    else begin
      pCell := p^.aCell; Inc(pCell, p^.iCell);
      pNxt^.iPgno := pCell^.iChildPg;
    end;
    rc := statGetPage(pBt, pNxt^.iPgno, pNxt);
    Inc(pCsr^.nPage);
    pNxt^.iCell := 0;
    if pCsr^.isAgg = 0 then begin
      pNxt^.zPath := statFmtPath('%s%.3x/', p^.zPath, p^.iCell, 0);
      if pNxt^.zPath = nil then rc := SQLITE_NOMEM;
    end;
    Inc(p^.iCell);
  end;

  if rc = SQLITE_OK then begin
    p := @pCsr^.aPage[pCsr^.iPage];
    pCsr^.zName := PAnsiChar(sqlite3_column_text(PVdbe(pCsr^.pStmt), 0));
    pCsr^.iPageno := p^.iPgno;
    rc := statDecodePage(pBt, p);
    if rc = SQLITE_OK then begin
      statSizeAndOffset(pCsr);
      case p^.flags of
        $05, $02: pCsr^.zPagetype := 'internal';
        $0D, $0A: pCsr^.zPagetype := 'leaf';
      else
        pCsr^.zPagetype := 'corrupted';
      end;
      pCsr^.nCell   := pCsr^.nCell + p^.nCell;
      pCsr^.nUnused := pCsr^.nUnused + p^.nUnused;
      if p^.nMxPayload > pCsr^.nMxPayload then
        pCsr^.nMxPayload := p^.nMxPayload;
      if pCsr^.isAgg = 0 then begin
        pCsr^.zPath := statFmtPath('%s', p^.zPath, 0, 0);
        if pCsr^.zPath = nil then rc := SQLITE_NOMEM;
      end;
      nPayload := 0;
      for i := 0 to p^.nCell - 1 do begin
        pCell := p^.aCell; Inc(pCell, i);
        nPayload := nPayload + pCell^.nLocal;
      end;
      pCsr^.nPayload := pCsr^.nPayload + nPayload;
      if pCsr^.isAgg <> 0 then goto statNextRestart;
    end;
  end;
  Result := rc;
end;

{ dbstat.c:726 — xEof. }
function statEof(pCursor: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PStatCursor;
begin
  pCsr := PStatCursor(pCursor);
  Result := pCsr^.isEof;
end;

{ dbstat.c:735 — xFilter.  Builds the inner SELECT and prepares it. }
function statFilter(pCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCsr:  PStatCursor;
  pTab:  PStatTable;
  zSql:  PAnsiChar;
  iArg:  i32;
  rc:    i32;
  zDbase: PAnsiChar;
  zName: PAnsiChar;
  argvArr: ^Psqlite3_value;
  pStmtNew: Pointer;
begin
  pCsr := PStatCursor(pCursor);
  pTab := PStatTable(pCursor^.pVtab);
  iArg := 0;
  rc   := SQLITE_OK;
  zName := nil;
  argvArr := Pointer(argv);

  statResetCsr(pCsr);
  if pCsr^.pStmt <> nil then begin
    sqlite3_finalize(PVdbe(pCsr^.pStmt));
    pCsr^.pStmt := nil;
  end;

  if (idxNum and $01) <> 0 then begin
    zDbase := PAnsiChar(sqlite3_value_text((argvArr + iArg)^));
    Inc(iArg);
    pCsr^.iDb := sqlite3FindDbName(pTab^.db, zDbase);
    if pCsr^.iDb < 0 then begin
      pCsr^.iDb := 0;
      pCsr^.isEof := 1;
      Result := SQLITE_OK; Exit;
    end;
  end else begin
    pCsr^.iDb := pTab^.iDb;
  end;
  if (idxNum and $02) <> 0 then begin
    zName := PAnsiChar(sqlite3_value_text((argvArr + iArg)^));
    Inc(iArg);
  end;
  if (idxNum and $04) <> 0 then begin
    if sqlite3_value_double((argvArr + iArg)^) <> 0.0 then pCsr^.isAgg := 1
    else pCsr^.isAgg := 0;
    Inc(iArg);
  end else begin
    pCsr^.isAgg := 0;
  end;

  zSql := statBuildSql(pTab^.db^.aDb[pCsr^.iDb].zDbSName, zName,
                       (idxNum and $08) <> 0);
  if zSql = nil then begin Result := SQLITE_NOMEM; Exit; end;
  pStmtNew := nil;
  rc := sqlite3_prepare_v2(pTab^.db, zSql, -1, @pStmtNew, nil);
  pCsr^.pStmt := pStmtNew;
  sqlite3_free(zSql);

  if rc = SQLITE_OK then begin
    pCsr^.iPage := -1;
    rc := statNext(pCursor);
  end;
  Result := rc;
end;

{ dbstat.c:804 — xColumn. }
function statColumn(pCursor: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCsr: PStatCursor;
  pTab: PStatTable;
begin
  pCsr := PStatCursor(pCursor);
  case i of
    DBSTAT_COLUMN_NAME:
      sqlite3_result_text(ctx, pCsr^.zName, -1, SQLITE_TRANSIENT);
    DBSTAT_COLUMN_PATH:
      if pCsr^.isAgg = 0 then
        sqlite3_result_text(ctx, pCsr^.zPath, -1, SQLITE_TRANSIENT);
    DBSTAT_COLUMN_PAGENO:
      if pCsr^.isAgg <> 0 then
        sqlite3_result_int64(ctx, pCsr^.nPage)
      else
        sqlite3_result_int64(ctx, i64(pCsr^.iPageno));
    DBSTAT_COLUMN_PAGETYPE:
      if pCsr^.isAgg = 0 then
        sqlite3_result_text(ctx, pCsr^.zPagetype, -1, SQLITE_STATIC);
    DBSTAT_COLUMN_NCELL:      sqlite3_result_int64(ctx, pCsr^.nCell);
    DBSTAT_COLUMN_PAYLOAD:    sqlite3_result_int64(ctx, pCsr^.nPayload);
    DBSTAT_COLUMN_UNUSED:     sqlite3_result_int64(ctx, pCsr^.nUnused);
    DBSTAT_COLUMN_MX_PAYLOAD: sqlite3_result_int64(ctx, pCsr^.nMxPayload);
    DBSTAT_COLUMN_PGOFFSET:
      if pCsr^.isAgg = 0 then sqlite3_result_int64(ctx, pCsr^.iOffset);
    DBSTAT_COLUMN_PGSIZE:     sqlite3_result_int64(ctx, pCsr^.szPage);
    DBSTAT_COLUMN_SCHEMA: begin
      pTab := PStatTable(pCsr^.base.pVtab);
      sqlite3_result_text(ctx, pTab^.db^.aDb[pCsr^.iDb].zDbSName, -1,
        SQLITE_STATIC);
    end;
  else
    { aggregate column. }
    sqlite3_result_int(ctx, pCsr^.isAgg);
  end;
  Result := SQLITE_OK;
end;

{ dbstat.c:865 — xRowid. }
function statRowid(pCursor: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var
  pCsr: PStatCursor;
begin
  pCsr := PStatCursor(pCursor);
  pRowid^ := i64(pCsr^.iPageno);
  Result := SQLITE_OK;
end;

{ ============================================================
  Module registration — dbstat.c:874
  ============================================================ }

function sqlite3DbstatRegister(db: PTsqlite3): PVtabModule;
begin
  Result := sqlite3VtabCreateModule(db, 'dbstat', @dbstatModule, nil, nil);
end;

initialization
  FillChar(dbstatModule, SizeOf(dbstatModule), 0);
  dbstatModule.iVersion    := 0;
  dbstatModule.xCreate     := @statConnect;
  dbstatModule.xConnect    := @statConnect;
  dbstatModule.xBestIndex  := @statBestIndex;
  dbstatModule.xDisconnect := @statDisconnect;
  dbstatModule.xDestroy    := @statDisconnect;
  dbstatModule.xOpen       := @statOpen;
  dbstatModule.xClose      := @statClose;
  dbstatModule.xFilter     := @statFilter;
  dbstatModule.xNext       := @statNext;
  dbstatModule.xEof        := @statEof;
  dbstatModule.xColumn     := @statColumn;
  dbstatModule.xRowid      := @statRowid;
end.
