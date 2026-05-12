{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/expert/sqlite3expert.c
  (2236 lines C → ~1900 lines Pascal) + ext/expert/sqlite3expert.h.

  Drives the .expert dot command: given one or more SQL queries the
  module proposes candidate indexes by mirroring the user schema into
  a side database whose tables are virtual.  The xBestIndex hook of
  the synthetic vtab harvests WHERE / ORDER BY column references, and
  the analysis pass formulates CREATE INDEX statements, optionally
  builds sqlite_stat1 samples, and reports the planner's preferred
  indexes via EXPLAIN QUERY PLAN.

  Public surface (mirrors sqlite3expert.h):

    sqlite3_expert_new(db, *pzErr) -> Psqlite3expert
    sqlite3_expert_config(p, op, iArg) -> int      (variadic shim)
    sqlite3_expert_sql(p, zSql, *pzErr) -> int
    sqlite3_expert_analyze(p, *pzErr) -> int
    sqlite3_expert_count(p) -> int
    sqlite3_expert_report(p, iStmt, eReport) -> PAnsiChar
    sqlite3_expert_destroy(p)

  Pascal-port adaptations:

    * No C varargs: sqlite3_expert_config takes a single int argument
      (the only operation EXPERT_CONFIG_SAMPLE consumes one int).
    * printf-style helpers go through sqlite3PfMprintf and consume
      Pascal `array of const`.
    * The vtab module slots are typed as Pointer (matching
      Tsqlite3_module from passqlite3vtab) so trampoline cdecl entries
      can be assigned without casts.

  (closed by 6.13.B.11)

    Earlier bisects pointed at an eTabType-after-OP_ParseSchema reload
    bug.  Tracing showed eTabType for the re-published vtab is in fact
    TABTYP_VTAB at hash-insert time; the actual surface was the
    eponymous-vtab fast arm in sqlite3Select firing unconditionally for
    every single-source vtab SELECT.  That arm has no WHERE/ORDER BY
    pushdown — it emits OP_VOpen + OP_VFilter(idxNum=0, argc=0) and
    relies on post-filter — so xBestIndex never saw the constraints and
    pScan stayed empty.  The fix in passqlite3codegen.sqlite3Select
    restricts the fast arm to the simple "SELECT ... FROM <vtab>" shape
    (no pWhere/pOrderBy/pGroupBy/pHaving/pLimit) and lets every other
    shape fall through to sqlite3WhereBegin → whereLoopAddVirtual
    (Phase 6.13.B.7), which drives vtabBestIndex productively.
}
{$I passqlite3.inc}
unit passqlite3expert;

interface

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main,
  passqlite3parser,    { sqlite3_keyword_check }
  passqlite3codegen;   { sqlite3_set_authorizer }

type
  Psqlite3expert  = ^Tsqlite3expert;
  PPsqlite3expert = ^Psqlite3expert;
  Tsqlite3expert = record
    iSample:     i32;            { Percentage of tables to sample for stat1 }
    db:          PTsqlite3;      { User database }
    dbm:         PTsqlite3;      { In-memory db for this analysis }
    dbv:         PTsqlite3;      { Vtab schema for this analysis }
    pTable:      Pointer;        { PIdxTable — list of IdxTable }
    pScan:       Pointer;        { PIdxScan  — list of scan objects }
    pWrite:      Pointer;        { PIdxWrite — list of write objects }
    pStatement:  Pointer;        { PIdxStatement — list }
    bRun:        i32;
    pzErrmsg:    PPAnsiChar;
    rc:          i32;            { Error code from whereinfo hook }
    hIdxFirst:   Pointer;        { hIdx.pFirst — IdxHashEntry* }
    hIdxBuckets: array[0..1022] of Pointer;   { hIdx.aHash[IDX_HASH_SIZE] }
    zCandidates: PAnsiChar;
  end;

const
  EXPERT_CONFIG_SAMPLE      = 1;

  EXPERT_REPORT_SQL         = 1;
  EXPERT_REPORT_INDEXES     = 2;
  EXPERT_REPORT_PLAN        = 3;
  EXPERT_REPORT_CANDIDATES  = 4;

function sqlite3_expert_new(db: PTsqlite3; pzErrmsg: PPAnsiChar): Psqlite3expert;
function sqlite3_expert_config(p: Psqlite3expert; op: i32; iArg: i32): i32;
function sqlite3_expert_sql(p: Psqlite3expert; zSql: PAnsiChar;
  pzErr: PPAnsiChar): i32;
function sqlite3_expert_analyze(p: Psqlite3expert; pzErr: PPAnsiChar): i32;
function sqlite3_expert_count(p: Psqlite3expert): i32;
function sqlite3_expert_report(p: Psqlite3expert; iStmt: i32;
  eReport: i32): PAnsiChar;
procedure sqlite3_expert_destroy(p: Psqlite3expert);

implementation

const
  IDX_HASH_SIZE     = 1023;
  UNIQUE_TABLE_NAME = 't592690916721053953805701627921227776';

type
  PIdxColumn     = ^TIdxColumn;
  PIdxConstraint = ^TIdxConstraint;
  PIdxScan       = ^TIdxScan;
  PIdxStatement  = ^TIdxStatement;
  PIdxTable      = ^TIdxTable;
  PIdxWrite      = ^TIdxWrite;
  PIdxHashEntry  = ^TIdxHashEntry;
  PExpertVtab    = ^TExpertVtab;
  PExpertCsr     = ^TExpertCsr;
  PIdxSampleCtx  = ^TIdxSampleCtx;
  PIdxRemSlot    = ^TIdxRemSlot;
  PIdxRemCtx     = ^TIdxRemCtx;

  TIdxConstraint = record
    zColl:  PAnsiChar;    { Collation sequence }
    bRange: i32;
    iCol:   i32;
    bFlag:  i32;
    bDesc:  i32;
    pNext:  PIdxConstraint;
    pLink:  PIdxConstraint;
  end;

  TIdxScan = record
    pTab:      PIdxTable;
    iDb:       i32;
    covering:  i64;
    pOrder:    PIdxConstraint;
    pEq:       PIdxConstraint;
    pRange:    PIdxConstraint;
    pNextScan: PIdxScan;
  end;

  TIdxColumn = record
    zName: PAnsiChar;
    zColl: PAnsiChar;
    iPk:   i32;
  end;

  TIdxTable = record
    nCol:  i32;
    zName: PAnsiChar;
    aCol:  PIdxColumn;
    pNext: PIdxTable;
  end;

  TIdxWrite = record
    pTab:  PIdxTable;
    eOp:   i32;
    pNext: PIdxWrite;
  end;

  TIdxStatement = record
    iId:   i32;
    zSql:  PAnsiChar;
    zIdx:  PAnsiChar;
    zEQP:  PAnsiChar;
    pNext: PIdxStatement;
  end;

  TIdxHashEntry = record
    zKey:      PAnsiChar;
    zVal:      PAnsiChar;
    zVal2:     PAnsiChar;
    pHashNext: PIdxHashEntry;
    pNext:     PIdxHashEntry;
  end;

  TExpertVtab = record
    base:    Tsqlite3_vtab;
    pTab:    PIdxTable;
    pExpert: Psqlite3expert;
  end;

  TExpertCsr = record
    base:  Tsqlite3_vtab_cursor;
    pData: PVdbe;
  end;

  TIdxSampleCtx = record
    iTarget: i32;
    target:  Double;
    nRow:    Double;
    nRet:    Double;
  end;

  TIdxRemSlot = record
    eType: i32;
    iVal:  i64;
    rVal:  Double;
    nByte: i64;
    n:     i64;
    z:     PAnsiChar;
  end;

  TIdxRemCtx = record
    nSlot: i32;
    aSlot: array[0..0] of TIdxRemSlot;
  end;

var
  expertModule: Tsqlite3_module;

{ ----- forward declarations ----- }
procedure sqlite3_expert_destroy_(p: Psqlite3expert); forward;
function expertNext(cur: PSqlite3VtabCursor): i32; cdecl; forward;

{ ---------------------------------------------------------------
  Memory helpers
  --------------------------------------------------------------- }

function idxMalloc(pRc: Pi32; nByte: i64): Pointer;
begin
  Assert(pRc^ = SQLITE_OK);
  Assert(nByte > 0);
  Result := sqlite3_malloc64(u64(nByte));
  if Result <> nil then
    FillChar(Result^, nByte, 0)
  else
    pRc^ := SQLITE_NOMEM;
end;

{ ---------------------------------------------------------------
  Hash table — implemented as a freestanding helper on an entry list
  + 1023-bucket pHash[] embedded in Tsqlite3expert.  Mirrors C
  idxHash.* but operates against an explicit (pFirst, aHash) pair
  so we can also drive a local IdxHash inside idxFindIndexes.
  --------------------------------------------------------------- }

procedure idxHashClear(var pFirst: PIdxHashEntry; var aHash: array of Pointer);
var
  i: i32;
  pEntry, pNext: PIdxHashEntry;
begin
  for i := 0 to IDX_HASH_SIZE-1 do begin
    pEntry := PIdxHashEntry(aHash[i]);
    while pEntry <> nil do begin
      pNext := pEntry^.pHashNext;
      sqlite3_free(pEntry^.zVal2);
      sqlite3_free(pEntry);
      pEntry := pNext;
    end;
    aHash[i] := nil;
  end;
  pFirst := nil;
end;

function idxHashString(z: PAnsiChar; n: i32): i32;
var
  ret: u32;
  i: i32;
begin
  ret := 0;
  for i := 0 to n-1 do
    ret := ret + (ret shl 3) + u32(Byte(z[i]));
  Result := i32(ret mod IDX_HASH_SIZE);
end;

function idxHashAdd(pRc: Pi32; var pFirst: PIdxHashEntry;
  var aHash: array of Pointer; zKey: PAnsiChar; zVal: PAnsiChar): i32;
var
  nKey, iHash, nVal: i32;
  pEntry: PIdxHashEntry;
begin
  nKey := i32(strlen(zKey));
  iHash := idxHashString(zKey, nKey);
  if zVal <> nil then nVal := i32(strlen(zVal)) else nVal := 0;
  Assert(iHash >= 0);
  pEntry := PIdxHashEntry(aHash[iHash]);
  while pEntry <> nil do begin
    if (i32(strlen(pEntry^.zKey)) = nKey)
       and (CompareByte(pEntry^.zKey^, zKey^, nKey) = 0) then begin
      Result := 1; Exit;
    end;
    pEntry := pEntry^.pHashNext;
  end;
  pEntry := PIdxHashEntry(idxMalloc(pRc,
    i64(SizeOf(TIdxHashEntry)) + i64(nKey)+1 + i64(nVal)+1));
  if pEntry <> nil then begin
    pEntry^.zKey := PAnsiChar(@pEntry[1]);
    Move(zKey^, pEntry^.zKey^, nKey);
    if zVal <> nil then begin
      pEntry^.zVal := PAnsiChar(@pEntry^.zKey[nKey+1]);
      Move(zVal^, pEntry^.zVal^, nVal);
    end;
    pEntry^.pHashNext := PIdxHashEntry(aHash[iHash]);
    aHash[iHash] := pEntry;

    pEntry^.pNext := pFirst;
    pFirst := pEntry;
  end;
  Result := 0;
end;

function idxHashFind(var aHash: array of Pointer;
  zKey: PAnsiChar; nKey: i32): PIdxHashEntry;
var iHash: i32; pEntry: PIdxHashEntry;
begin
  if nKey < 0 then nKey := i32(strlen(zKey));
  iHash := idxHashString(zKey, nKey);
  Assert(iHash >= 0);
  pEntry := PIdxHashEntry(aHash[iHash]);
  while pEntry <> nil do begin
    if (i32(strlen(pEntry^.zKey)) = nKey)
       and (CompareByte(pEntry^.zKey^, zKey^, nKey) = 0) then begin
      Result := pEntry; Exit;
    end;
    pEntry := pEntry^.pHashNext;
  end;
  Result := nil;
end;

function idxHashSearch(var aHash: array of Pointer;
  zKey: PAnsiChar; nKey: i32): PAnsiChar;
var pEntry: PIdxHashEntry;
begin
  pEntry := idxHashFind(aHash, zKey, nKey);
  if pEntry <> nil then Result := pEntry^.zVal else Result := nil;
end;

{ Wrappers that operate on Tsqlite3expert.hIdx* fields }
procedure peHashClear(p: Psqlite3expert);
begin
  idxHashClear(PIdxHashEntry(p^.hIdxFirst), p^.hIdxBuckets);
end;

function peHashAdd(p: Psqlite3expert; pRc: Pi32;
  zKey, zVal: PAnsiChar): i32;
begin
  Result := idxHashAdd(pRc, PIdxHashEntry(p^.hIdxFirst),
    p^.hIdxBuckets, zKey, zVal);
end;

function peHashFind(p: Psqlite3expert; zKey: PAnsiChar; nKey: i32): PIdxHashEntry;
begin
  Result := idxHashFind(p^.hIdxBuckets, zKey, nKey);
end;

function peHashSearch(p: Psqlite3expert; zKey: PAnsiChar; nKey: i32): PAnsiChar;
begin
  Result := idxHashSearch(p^.hIdxBuckets, zKey, nKey);
end;

{ ---------------------------------------------------------------
  Misc helpers
  --------------------------------------------------------------- }

function idxNewConstraint(pRc: Pi32; zColl: PAnsiChar): PIdxConstraint;
var
  nColl: i32;
  pNew: PIdxConstraint;
begin
  nColl := i32(strlen(zColl));
  Assert(pRc^ = SQLITE_OK);
  { Mirror C: sizeof(IdxConstraint) * nColl + 1 (note: C bug-equivalent over-allocation;
    we allocate sizeof(IdxConstraint) + nColl + 1 which is sufficient. }
  pNew := PIdxConstraint(idxMalloc(pRc,
    i64(SizeOf(TIdxConstraint)) + i64(nColl) + 1));
  if pNew <> nil then begin
    pNew^.zColl := PAnsiChar(@pNew[1]);
    Move(zColl^, pNew^.zColl^, nColl+1);
  end;
  Result := pNew;
end;

procedure idxDatabaseError(db: PTsqlite3; pzErrmsg: PPAnsiChar);
begin
  if pzErrmsg <> nil then
    pzErrmsg^ := sqlite3PfMprintf('%s', [AnsiString(sqlite3_errmsg(db))]);
end;

function idxPrepareStmt(db: PTsqlite3; ppStmt: PPointer;
  pzErrmsg: PPAnsiChar; zSql: PAnsiChar): i32;
var rc: i32;
begin
  rc := sqlite3_prepare_v2(db, zSql, -1, ppStmt, nil);
  if rc <> SQLITE_OK then begin
    ppStmt^ := nil;
    idxDatabaseError(db, pzErrmsg);
  end;
  Result := rc;
end;

function idxPrintfPrepareStmt(db: PTsqlite3; ppStmt: PPointer;
  pzErrmsg: PPAnsiChar; zFmt: PAnsiChar;
  const args: array of const): i32;
var
  rc: i32;
  zSql: PAnsiChar;
begin
  zSql := sqlite3PfMprintf(zFmt, args);
  if zSql = nil then begin
    Result := SQLITE_NOMEM; Exit;
  end;
  rc := idxPrepareStmt(db, ppStmt, pzErrmsg, zSql);
  sqlite3_free(zSql);
  Result := rc;
end;

{ ===============================================================
  Beginning of virtual table implementation
  =============================================================== }

function expertDequote(zIn: PAnsiChar): PAnsiChar;
var
  n, iOut, iIn: i64;
  zRet: PAnsiChar;
begin
  n := strlen(zIn);
  zRet := PAnsiChar(sqlite3_malloc64(u64(n)));
  Assert(zIn[0] = '''');
  Assert(zIn[n-1] = '''');
  if zRet <> nil then begin
    iOut := 0;
    iIn := 1;
    while iIn < n-1 do begin
      if zIn[iIn] = '''' then begin
        Assert(zIn[iIn+1] = '''');
        Inc(iIn);
      end;
      zRet[iOut] := zIn[iIn]; Inc(iOut);
      Inc(iIn);
    end;
    zRet[iOut] := #0;
  end;
  Result := zRet;
end;

function expertConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; const argv: PPAnsiChar;
  ppVtab: PPSqlite3Vtab; pzErr: PPAnsiChar): i32; cdecl;
var
  pExpert: Psqlite3expert;
  p: PExpertVtab;
  rc: i32;
  zCreateTable: PAnsiChar;
  azArgv: PPAnsiChar;
begin
  pExpert := Psqlite3expert(pAux);
  p := nil;
  azArgv := argv;
  if argc <> 4 then begin
    pzErr^ := sqlite3PfMprintf('internal error!', []);
    rc := SQLITE_ERROR;
  end else begin
    zCreateTable := expertDequote(azArgv[3]);
    if zCreateTable <> nil then begin
      rc := sqlite3_declare_vtab(db, zCreateTable);
      if rc = SQLITE_OK then
        p := PExpertVtab(idxMalloc(@rc, SizeOf(TExpertVtab)));
      if rc = SQLITE_OK then begin
        p^.pExpert := pExpert;
        p^.pTab := pExpert^.pTable;
        Assert(sqlite3_stricmp(p^.pTab^.zName, azArgv[2]) = 0);
      end;
      sqlite3_free(zCreateTable);
    end else
      rc := SQLITE_NOMEM;
  end;
  ppVtab^ := PSqlite3Vtab(p);
  Result := rc;
end;

function expertDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

function expertBestIndex(pVtab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  p: PExpertVtab;
  rc, n, i, iCol: i32;
  pScan: PIdxScan;
  pCons: PSqlite3IndexConstraint;
  pNew: PIdxConstraint;
  zColl: PAnsiChar;
const
  opmask =
    SQLITE_INDEX_CONSTRAINT_EQ or SQLITE_INDEX_CONSTRAINT_GT or
    SQLITE_INDEX_CONSTRAINT_LT or SQLITE_INDEX_CONSTRAINT_GE or
    SQLITE_INDEX_CONSTRAINT_LE;
begin
  p := PExpertVtab(pVtab);
  rc := SQLITE_OK;
  n := 0;
  pScan := PIdxScan(idxMalloc(@rc, SizeOf(TIdxScan)));
  if pScan <> nil then begin
    pScan^.pTab := p^.pTab;
    pScan^.pNextScan := PIdxScan(p^.pExpert^.pScan);
    p^.pExpert^.pScan := pScan;

    for i := 0 to pIdxInfo^.nConstraint-1 do begin
      pCons := PSqlite3IndexConstraint(PtrUInt(pIdxInfo^.aConstraint)
                 + PtrUInt(i) * SizeOf(Tsqlite3_index_constraint));
      if (pCons^.usable <> 0)
         and (pCons^.iColumn >= 0)
         and (p^.pTab^.aCol[pCons^.iColumn].iPk = 0)
         and ((pCons^.op and opmask) <> 0) then begin
        zColl := sqlite3_vtab_collation(pIdxInfo, i);
        pNew := idxNewConstraint(@rc, zColl);
        if pNew <> nil then begin
          pNew^.iCol := pCons^.iColumn;
          if pCons^.op = SQLITE_INDEX_CONSTRAINT_EQ then begin
            pNew^.pNext := pScan^.pEq; pScan^.pEq := pNew;
          end else begin
            pNew^.bRange := 1;
            pNew^.pNext := pScan^.pRange; pScan^.pRange := pNew;
          end;
        end;
        Inc(n);
        with PSqlite3IndexConstraintUsage(PtrUInt(pIdxInfo^.aConstraintUsage)
               + PtrUInt(i) * SizeOf(Tsqlite3_index_constraint_usage))^ do
          argvIndex := n;
      end;
    end;

    for i := pIdxInfo^.nOrderBy-1 downto 0 do begin
      iCol := PSqlite3IndexOrderBy(PtrUInt(pIdxInfo^.aOrderBy)
                + PtrUInt(i) * SizeOf(Tsqlite3_index_orderby))^.iColumn;
      if iCol >= 0 then begin
        pNew := idxNewConstraint(@rc, p^.pTab^.aCol[iCol].zColl);
        if pNew <> nil then begin
          pNew^.iCol := iCol;
          pNew^.bDesc := PSqlite3IndexOrderBy(PtrUInt(pIdxInfo^.aOrderBy)
                           + PtrUInt(i) * SizeOf(Tsqlite3_index_orderby))^.desc;
          pNew^.pNext := pScan^.pOrder;
          pNew^.pLink := pScan^.pOrder;
          pScan^.pOrder := pNew;
          Inc(n);
        end;
      end;
    end;
  end;
  pIdxInfo^.estimatedCost := 1000000.0 / (n+1);
  Result := rc;
end;

function expertUpdate(pVtab: PSqlite3Vtab; nData: i32;
  azData: PPointer; pRowid: Pi64): i32; cdecl;
begin
  Result := SQLITE_OK;
end;

function expertOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  rc: i32;
  pCsr: PExpertCsr;
begin
  rc := SQLITE_OK;
  pCsr := PExpertCsr(idxMalloc(@rc, SizeOf(TExpertCsr)));
  ppCursor^ := PSqlite3VtabCursor(pCsr);
  Result := rc;
end;

function expertClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCsr: PExpertCsr;
begin
  pCsr := PExpertCsr(cur);
  sqlite3_finalize(pCsr^.pData);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

function expertEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCsr: PExpertCsr;
begin
  pCsr := PExpertCsr(cur);
  if pCsr^.pData = nil then Result := 1 else Result := 0;
end;

function expertNext(cur: PSqlite3VtabCursor): i32; cdecl;
var pCsr: PExpertCsr; rc: i32;
begin
  pCsr := PExpertCsr(cur);
  Assert(pCsr^.pData <> nil);
  rc := sqlite3_step(pCsr^.pData);
  if rc <> SQLITE_ROW then begin
    rc := sqlite3_finalize(pCsr^.pData);
    pCsr^.pData := nil;
  end else
    rc := SQLITE_OK;
  Result := rc;
end;

function expertRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
begin
  pRowid^ := 0;
  Result := SQLITE_OK;
end;

function expertColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCsr: PExpertCsr;
  pVal: Psqlite3_value;
begin
  pCsr := PExpertCsr(cur);
  pVal := sqlite3_column_value(pCsr^.pData, i);
  if pVal <> nil then
    sqlite3_result_value(ctx, pVal);
  Result := SQLITE_OK;
end;

function expertFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPointer): i32; cdecl;
var
  pCsr: PExpertCsr;
  pVtab: PExpertVtab;
  pExpert: Psqlite3expert;
  rc: i32;
begin
  pCsr := PExpertCsr(cur);
  pVtab := PExpertVtab(cur^.pVtab);
  pExpert := pVtab^.pExpert;
  rc := sqlite3_finalize(pCsr^.pData);
  pCsr^.pData := nil;
  if rc = SQLITE_OK then
    rc := idxPrintfPrepareStmt(pExpert^.db, @pCsr^.pData,
      @pVtab^.base.zErrMsg,
      'SELECT * FROM main.%Q WHERE sqlite_expert_sample()',
      [AnsiString(pVtab^.pTab^.zName)]);
  if rc = SQLITE_OK then
    rc := expertNext(cur);
  Result := rc;
end;

function idxRegisterVtab(p: Psqlite3expert): i32;
begin
  expertModule.iVersion       := 2;
  expertModule.xCreate        := @expertConnect;
  expertModule.xConnect       := @expertConnect;
  expertModule.xBestIndex     := @expertBestIndex;
  expertModule.xDisconnect    := @expertDisconnect;
  expertModule.xDestroy       := @expertDisconnect;
  expertModule.xOpen          := @expertOpen;
  expertModule.xClose         := @expertClose;
  expertModule.xFilter        := @expertFilter;
  expertModule.xNext          := @expertNext;
  expertModule.xEof           := @expertEof;
  expertModule.xColumn        := @expertColumn;
  expertModule.xRowid         := @expertRowid;
  expertModule.xUpdate        := @expertUpdate;
  expertModule.xBegin         := nil;
  expertModule.xSync          := nil;
  expertModule.xCommit        := nil;
  expertModule.xRollback      := nil;
  expertModule.xFindFunction  := nil;
  expertModule.xRename        := nil;
  expertModule.xSavepoint     := nil;
  expertModule.xRelease       := nil;
  expertModule.xRollbackTo    := nil;
  expertModule.xShadowName    := nil;
  expertModule.xIntegrity     := nil;
  Result := sqlite3_create_module(p^.dbv, 'expert', @expertModule, p);
end;

{ ===============================================================
  End of virtual table implementation
  =============================================================== }

procedure idxFinalize(pRc: Pi32; pStmt: PVdbe);
var rc: i32;
begin
  rc := sqlite3_finalize(pStmt);
  if pRc^ = SQLITE_OK then pRc^ := rc;
end;

function idxGetTableInfo(db: PTsqlite3; zTab: PAnsiChar;
  ppOut: PPointer; pzErrmsg: PPAnsiChar): i32;
var
  p1: PVdbe;
  nCol, nTab, nPk, rc, rc2, nCopy: i32;
  nByte: i64;
  pNew: PIdxTable;
  pCsr: PAnsiChar;
  zCol, zColSeq: PAnsiChar;
begin
  ppOut^ := nil;
  if zTab = nil then begin Result := SQLITE_ERROR; Exit; end;
  p1 := nil;
  nCol := 0; nPk := 0;
  pNew := nil; pCsr := nil;
  nTab := i32(strlen(zTab));
  nByte := SizeOf(TIdxTable) + nTab + 1;
  rc := idxPrintfPrepareStmt(db, @p1, pzErrmsg, 'PRAGMA table_xinfo=%Q',
    [AnsiString(zTab)]);
  while (rc = SQLITE_OK) and (sqlite3_step(p1) = SQLITE_ROW) do begin
    zCol := sqlite3_column_text(p1, 1);
    zColSeq := nil;
    if zCol = nil then begin rc := SQLITE_ERROR; Break; end;
    nByte := nByte + 1 + strlen(zCol);
    rc := sqlite3_table_column_metadata(db, 'main', zTab, zCol,
      nil, @zColSeq, nil, nil, nil);
    if zColSeq = nil then zColSeq := 'binary';
    nByte := nByte + 1 + strlen(zColSeq);
    Inc(nCol);
    if sqlite3_column_int(p1, 5) > 0 then Inc(nPk);
  end;
  rc2 := sqlite3_reset(p1);
  if rc = SQLITE_OK then rc := rc2;

  nByte := nByte + SizeOf(TIdxColumn) * nCol;
  if rc = SQLITE_OK then
    pNew := PIdxTable(idxMalloc(@rc, nByte));
  if rc = SQLITE_OK then begin
    pNew^.aCol := PIdxColumn(@pNew[1]);
    pNew^.nCol := nCol;
    pCsr := PAnsiChar(@pNew^.aCol[nCol]);
  end;

  nCol := 0;
  while (rc = SQLITE_OK) and (sqlite3_step(p1) = SQLITE_ROW) do begin
    zCol := sqlite3_column_text(p1, 1);
    zColSeq := nil;
    if zCol = nil then Continue;
    nCopy := i32(strlen(zCol)) + 1;
    pNew^.aCol[nCol].zName := pCsr;
    if (sqlite3_column_int(p1, 5) = 1) and (nPk = 1) then
      pNew^.aCol[nCol].iPk := 1
    else
      pNew^.aCol[nCol].iPk := 0;
    Move(zCol^, pCsr^, nCopy);
    Inc(pCsr, nCopy);

    rc := sqlite3_table_column_metadata(db, 'main', zTab, zCol,
      nil, @zColSeq, nil, nil, nil);
    if rc = SQLITE_OK then begin
      if zColSeq = nil then zColSeq := 'binary';
      nCopy := i32(strlen(zColSeq)) + 1;
      pNew^.aCol[nCol].zColl := pCsr;
      Move(zColSeq^, pCsr^, nCopy);
      Inc(pCsr, nCopy);
    end;
    Inc(nCol);
  end;
  idxFinalize(@rc, p1);

  if rc <> SQLITE_OK then begin
    sqlite3_free(pNew);
    pNew := nil;
  end else if pNew <> nil then begin
    pNew^.zName := pCsr;
    Move(zTab^, pNew^.zName^, nTab+1);
  end;

  ppOut^ := pNew;
  Result := rc;
end;

function idxAppendText(pRc: Pi32; zIn: PAnsiChar;
  zFmt: PAnsiChar; const args: array of const): PAnsiChar;
var
  zAppend, zRet: PAnsiChar;
  nIn, nAppend: i64;
begin
  zAppend := nil; zRet := nil;
  if zIn <> nil then nIn := strlen(zIn) else nIn := 0;
  nAppend := 0;
  if pRc^ = SQLITE_OK then begin
    zAppend := sqlite3PfMprintf(zFmt, args);
    if zAppend <> nil then begin
      nAppend := strlen(zAppend);
      zRet := PAnsiChar(sqlite3_malloc64(u64(nIn + nAppend + 1)));
    end;
    if (zAppend <> nil) and (zRet <> nil) then begin
      if nIn <> 0 then Move(zIn^, zRet^, nIn);
      Move(zAppend^, zRet[nIn], nAppend+1);
    end else begin
      sqlite3_free(zRet);
      zRet := nil;
      pRc^ := SQLITE_NOMEM;
    end;
    sqlite3_free(zAppend);
    sqlite3_free(zIn);
  end;
  Result := zRet;
end;

function idxIdentifierRequiresQuotes(zId: PAnsiChar): i32;
var i, nId: i32; c: AnsiChar;
begin
  nId := i32(strlen(zId));
  if sqlite3_keyword_check(zId, nId) <> 0 then begin Result := 1; Exit; end;
  i := 0;
  while zId[i] <> #0 do begin
    c := zId[i];
    if not ((c = '_')
            or ((c >= '0') and (c <= '9'))
            or ((c >= 'a') and (c <= 'z'))
            or ((c >= 'A') and (c <= 'Z'))) then begin
      Result := 1; Exit;
    end;
    Inc(i);
  end;
  Result := 0;
end;

function idxAppendColDefn(pRc: Pi32; zIn: PAnsiChar;
  pTab: PIdxTable; pCons: PIdxConstraint): PAnsiChar;
var zRet: PAnsiChar; p: PIdxColumn;
begin
  zRet := zIn;
  p := @pTab^.aCol[pCons^.iCol];
  if zRet <> nil then
    zRet := idxAppendText(pRc, zRet, ', ', []);
  if idxIdentifierRequiresQuotes(p^.zName) <> 0 then
    zRet := idxAppendText(pRc, zRet, '%Q', [AnsiString(p^.zName)])
  else
    zRet := idxAppendText(pRc, zRet, '%s', [AnsiString(p^.zName)]);
  if sqlite3_stricmp(p^.zColl, pCons^.zColl) <> 0 then begin
    if idxIdentifierRequiresQuotes(pCons^.zColl) <> 0 then
      zRet := idxAppendText(pRc, zRet, ' COLLATE %Q', [AnsiString(pCons^.zColl)])
    else
      zRet := idxAppendText(pRc, zRet, ' COLLATE %s', [AnsiString(pCons^.zColl)]);
  end;
  if pCons^.bDesc <> 0 then
    zRet := idxAppendText(pRc, zRet, ' DESC', []);
  Result := zRet;
end;

function idxFindCompatible(pRc: Pi32; dbm: PTsqlite3;
  pScan: PIdxScan; pEq, pTail: PIdxConstraint): i32;
var
  zTbl, zIdx, zColl: PAnsiChar;
  pIdxList, pInfo: PVdbe;
  pIter, pT: PIdxConstraint;
  nEq, rc, iIdx, iCol, bMatch: i32;
begin
  zTbl := pScan^.pTab^.zName;
  pIdxList := nil;
  nEq := 0;

  pIter := pEq;
  while pIter <> nil do begin Inc(nEq); pIter := pIter^.pLink; end;

  rc := idxPrintfPrepareStmt(dbm, @pIdxList, nil, 'PRAGMA index_list=%Q',
    [AnsiString(zTbl)]);
  while (rc = SQLITE_OK) and (sqlite3_step(pIdxList) = SQLITE_ROW) do begin
    bMatch := 1;
    pT := pTail;
    pInfo := nil;
    zIdx := sqlite3_column_text(pIdxList, 1);
    if zIdx = nil then Continue;

    pIter := pEq;
    while pIter <> nil do begin pIter^.bFlag := 0; pIter := pIter^.pLink; end;

    rc := idxPrintfPrepareStmt(dbm, @pInfo, nil, 'PRAGMA index_xInfo=%Q',
      [AnsiString(zIdx)]);
    while (rc = SQLITE_OK) and (sqlite3_step(pInfo) = SQLITE_ROW) do begin
      iIdx := sqlite3_column_int(pInfo, 0);
      iCol := sqlite3_column_int(pInfo, 1);
      zColl := sqlite3_column_text(pInfo, 4);
      if iIdx < nEq then begin
        pIter := pEq;
        while pIter <> nil do begin
          if pIter^.bFlag <> 0 then begin pIter := pIter^.pLink; Continue; end;
          if pIter^.iCol <> iCol then begin pIter := pIter^.pLink; Continue; end;
          if sqlite3_stricmp(pIter^.zColl, zColl) <> 0 then begin
            pIter := pIter^.pLink; Continue;
          end;
          pIter^.bFlag := 1;
          Break;
        end;
        if pIter = nil then begin bMatch := 0; Break; end;
      end else begin
        if pT <> nil then begin
          if (pT^.iCol <> iCol)
             or (sqlite3_stricmp(pT^.zColl, zColl) <> 0) then begin
            bMatch := 0; Break;
          end;
          pT := pT^.pLink;
        end;
      end;
    end;
    idxFinalize(@rc, pInfo);

    if (rc = SQLITE_OK) and (bMatch <> 0) then begin
      sqlite3_finalize(pIdxList);
      Result := 1; Exit;
    end;
  end;
  idxFinalize(@rc, pIdxList);
  pRc^ := rc;
  Result := 0;
end;

function countNonzeros(pCount: Pointer; nc: i32;
  azResults: PPAnsiChar; azColumns: PPAnsiChar): i32; cdecl;
begin
  if (nc > 0)
     and ((azResults[0][0] <> '0') or (azResults[0][1] <> #0)) then
    Inc(Pi32(pCount)^);
  Result := 0;
end;

function idxCreateFromCons(p: Psqlite3expert; pScan: PIdxScan;
  pEq, pTail: PIdxConstraint): i32;
var
  dbm: PTsqlite3;
  rc: i32;
  pTab: PIdxTable;
  zCols, zIdx, zName, zFind: PAnsiChar;
  zFmt: PAnsiChar;
  pCons: PIdxConstraint;
  h: u32;
  i, quoteTable, collisions: i32;
  zTable: PAnsiChar;
begin
  dbm := p^.dbm;
  rc := SQLITE_OK;
  if ((pEq <> nil) or (pTail <> nil))
     and (idxFindCompatible(@rc, dbm, pScan, pEq, pTail) = 0) then begin
    pTab := pScan^.pTab;
    zCols := nil; zIdx := nil; h := 0;

    pCons := pEq;
    while pCons <> nil do begin
      zCols := idxAppendColDefn(@rc, zCols, pTab, pCons);
      pCons := pCons^.pLink;
    end;
    pCons := pTail;
    while pCons <> nil do begin
      zCols := idxAppendColDefn(@rc, zCols, pTab, pCons);
      pCons := pCons^.pLink;
    end;

    if rc = SQLITE_OK then begin
      zTable := pScan^.pTab^.zName;
      quoteTable := idxIdentifierRequiresQuotes(zTable);
      zName := nil;
      collisions := 0;
      repeat
        i := 0;
        while zCols[i] <> #0 do begin
          h := h + ((h shl 3) + u32(Byte(zCols[i])));
          Inc(i);
        end;
        sqlite3_free(zName);
        zName := sqlite3PfMprintf('%s_idx_%08x',
          [AnsiString(zTable), Integer(h)]);
        if zName = nil then Break;
        zFmt := 'SELECT count(*) FROM sqlite_schema WHERE name=%Q'
              + ' AND type in (''index'',''table'',''view'')';
        zFind := sqlite3PfMprintf(zFmt, [AnsiString(zName)]);
        i := 0;
        rc := sqlite3_exec(dbm, zFind, @countNonzeros, @i, nil);
        Assert(rc = SQLITE_OK);
        sqlite3_free(zFind);
        if i = 0 then begin collisions := 0; Break; end;
        Inc(collisions);
      until (collisions >= 50) or (zName = nil);
      if collisions <> 0 then
        rc := SQLITE_BUSY_TIMEOUT
      else if zName = nil then
        rc := SQLITE_NOMEM
      else begin
        if quoteTable <> 0 then
          zFmt := 'CREATE INDEX "%w" ON "%w"(%s)'
        else
          zFmt := 'CREATE INDEX %s ON %s(%s)';
        zIdx := sqlite3PfMprintf(zFmt,
          [AnsiString(zName), AnsiString(zTable), AnsiString(zCols)]);
        if zIdx = nil then
          rc := SQLITE_NOMEM
        else begin
          rc := sqlite3_exec(dbm, zIdx, nil, nil, p^.pzErrmsg);
          if rc <> SQLITE_OK then
            rc := SQLITE_BUSY_TIMEOUT
          else
            peHashAdd(p, @rc, zName, zIdx);
        end;
        sqlite3_free(zName);
        sqlite3_free(zIdx);
      end;
    end;
    sqlite3_free(zCols);
  end;
  Result := rc;
end;

function idxFindConstraint(pList: PIdxConstraint; p: PIdxConstraint): i32;
var pCmp: PIdxConstraint;
begin
  pCmp := pList;
  while pCmp <> nil do begin
    if p^.iCol = pCmp^.iCol then begin Result := 1; Exit; end;
    pCmp := pCmp^.pLink;
  end;
  Result := 0;
end;

function idxCreateFromWhere(p: Psqlite3expert;
  pScan: PIdxScan; pTail: PIdxConstraint): i32;
var p1, pCon: PIdxConstraint; rc: i32;
begin
  p1 := nil;
  pCon := pScan^.pEq;
  while pCon <> nil do begin
    if (idxFindConstraint(p1, pCon) = 0)
       and (idxFindConstraint(pTail, pCon) = 0) then begin
      pCon^.pLink := p1;
      p1 := pCon;
    end;
    pCon := pCon^.pNext;
  end;
  rc := idxCreateFromCons(p, pScan, p1, pTail);
  if pTail = nil then begin
    pCon := pScan^.pRange;
    while (rc = SQLITE_OK) and (pCon <> nil) do begin
      Assert(pCon^.pLink = nil);
      if (idxFindConstraint(p1, pCon) = 0)
         and (idxFindConstraint(pTail, pCon) = 0) then
        rc := idxCreateFromCons(p, pScan, p1, pCon);
      pCon := pCon^.pNext;
    end;
  end;
  Result := rc;
end;

function idxCreateCandidates(p: Psqlite3expert): i32;
var rc: i32; pIter: PIdxScan;
begin
  rc := SQLITE_OK;
  pIter := PIdxScan(p^.pScan);
  while (pIter <> nil) and (rc = SQLITE_OK) do begin
    rc := idxCreateFromWhere(p, pIter, nil);
    if (rc = SQLITE_OK) and (pIter^.pOrder <> nil) then
      rc := idxCreateFromWhere(p, pIter, pIter^.pOrder);
    pIter := pIter^.pNextScan;
  end;
  Result := rc;
end;

procedure idxConstraintFree(pConstraint: PIdxConstraint);
var p, pNext: PIdxConstraint;
begin
  p := pConstraint;
  while p <> nil do begin
    pNext := p^.pNext;
    sqlite3_free(p);
    p := pNext;
  end;
end;

procedure idxScanFree(pScan, pLast: PIdxScan);
var p, pNext: PIdxScan;
begin
  p := pScan;
  while p <> pLast do begin
    pNext := p^.pNextScan;
    idxConstraintFree(p^.pOrder);
    idxConstraintFree(p^.pEq);
    idxConstraintFree(p^.pRange);
    sqlite3_free(p);
    p := pNext;
  end;
end;

procedure idxStatementFree(pStatement, pLast: PIdxStatement);
var p, pNext: PIdxStatement;
begin
  p := pStatement;
  while p <> pLast do begin
    pNext := p^.pNext;
    sqlite3_free(p^.zEQP);
    sqlite3_free(p^.zIdx);
    sqlite3_free(p);
    p := pNext;
  end;
end;

procedure idxTableFree(pTab: PIdxTable);
var pIter, pNext: PIdxTable;
begin
  pIter := pTab;
  while pIter <> nil do begin
    pNext := pIter^.pNext;
    sqlite3_free(pIter);
    pIter := pNext;
  end;
end;

procedure idxWriteFree(pTab: PIdxWrite);
var pIter, pNext: PIdxWrite;
begin
  pIter := pTab;
  while pIter <> nil do begin
    pNext := pIter^.pNext;
    sqlite3_free(pIter);
    pIter := pNext;
  end;
end;

function idxFindIndexes(p: Psqlite3expert; pzErr: PPAnsiChar): i32;
label find_indexes_out;
var
  pStmt: PIdxStatement;
  dbm: PTsqlite3;
  rc, nDetail, i, nIdx: i32;
  pEntry: PIdxHashEntry;
  pExplain: PVdbe;
  zDetail, zIdx, zSql: PAnsiChar;
  localFirst: PIdxHashEntry;
  localBuckets: array[0..IDX_HASH_SIZE-1] of Pointer;
begin
  dbm := p^.dbm;
  rc := SQLITE_OK;
  localFirst := nil;
  FillChar(localBuckets, SizeOf(localBuckets), 0);

  pStmt := PIdxStatement(p^.pStatement);
  while (rc = SQLITE_OK) and (pStmt <> nil) do begin
    pExplain := nil;
    idxHashClear(localFirst, localBuckets);
    rc := idxPrintfPrepareStmt(dbm, @pExplain, pzErr,
      'EXPLAIN QUERY PLAN %s', [AnsiString(pStmt^.zSql)]);
    while (rc = SQLITE_OK) and (sqlite3_step(pExplain) = SQLITE_ROW) do begin
      zDetail := sqlite3_column_text(pExplain, 3);
      if zDetail = nil then Continue;
      nDetail := i32(strlen(zDetail));
      i := 0;
      while i < nDetail do begin
        zIdx := nil;
        if (i+13 < nDetail)
           and (CompareByte(zDetail[i], PAnsiChar(' USING INDEX ')^, 13) = 0) then
          zIdx := @zDetail[i+13]
        else if (i+22 < nDetail)
           and (CompareByte(zDetail[i],
                            PAnsiChar(' USING COVERING INDEX ')^, 22) = 0) then
          zIdx := @zDetail[i+22];
        if zIdx <> nil then begin
          nIdx := 0;
          while (zIdx[nIdx] <> #0)
                and ((zIdx[nIdx] <> ' ') or (zIdx[nIdx+1] <> '(')) do
            Inc(nIdx);
          zSql := peHashSearch(p, zIdx, nIdx);
          if zSql <> nil then begin
            idxHashAdd(@rc, localFirst, localBuckets, zSql, nil);
            if rc <> 0 then goto find_indexes_out;
          end;
          Break;
        end;
        Inc(i);
      end;
      if zDetail[0] <> '-' then
        pStmt^.zEQP := idxAppendText(@rc, pStmt^.zEQP, '%s'#10,
          [AnsiString(zDetail)]);
    end;

    pEntry := localFirst;
    while pEntry <> nil do begin
      pStmt^.zIdx := idxAppendText(@rc, pStmt^.zIdx, '%s;'#10,
        [AnsiString(pEntry^.zKey)]);
      pEntry := pEntry^.pNext;
    end;
    idxFinalize(@rc, pExplain);
    pStmt := pStmt^.pNext;
  end;

find_indexes_out:
  idxHashClear(localFirst, localBuckets);
  Result := rc;
end;

function idxAuthCallback(pCtx: Pointer; eOp: i32;
  z3, z4, zDb, zTrigger: PAnsiChar): i32; cdecl;
var
  rc: i32;
  p: Psqlite3expert;
  pTab: PIdxTable;
  pWrite: PIdxWrite;
begin
  rc := SQLITE_OK;
  if (eOp = SQLITE_INSERT_AUTH) or (eOp = SQLITE_UPDATE_AUTH)
     or (eOp = SQLITE_DELETE_AUTH) then begin
    if sqlite3_stricmp(zDb, 'main') = 0 then begin
      p := Psqlite3expert(pCtx);
      pTab := PIdxTable(p^.pTable);
      while pTab <> nil do begin
        if sqlite3_stricmp(z3, pTab^.zName) = 0 then Break;
        pTab := pTab^.pNext;
      end;
      if pTab <> nil then begin
        pWrite := PIdxWrite(p^.pWrite);
        while pWrite <> nil do begin
          if (pWrite^.pTab = pTab) and (pWrite^.eOp = eOp) then Break;
          pWrite := pWrite^.pNext;
        end;
        if pWrite = nil then begin
          pWrite := PIdxWrite(idxMalloc(@rc, SizeOf(TIdxWrite)));
          if rc = SQLITE_OK then begin
            pWrite^.pTab := pTab;
            pWrite^.eOp := eOp;
            pWrite^.pNext := PIdxWrite(p^.pWrite);
            p^.pWrite := pWrite;
          end;
        end;
      end;
    end;
  end;
  Result := rc;
end;

function idxProcessOneTrigger(p: Psqlite3expert; pWrite: PIdxWrite;
  pzErr: PPAnsiChar): i32;
const
  zInt: PAnsiChar = UNIQUE_TABLE_NAME;
  zDrop: PAnsiChar = 'DROP TABLE ' + UNIQUE_TABLE_NAME;
var
  pTab: PIdxTable;
  zTab: PAnsiChar;
  zSql: PAnsiChar;
  pSelect, pX: PVdbe;
  rc, i: i32;
  zWrite, z, zCreate: PAnsiChar;
begin
  pTab := pWrite^.pTab;
  zTab := pTab^.zName;
  zSql := 'SELECT ''CREATE TEMP'' || substr(sql, 7) FROM sqlite_schema '
        + 'WHERE tbl_name = %Q AND type IN (''table'', ''trigger'') '
        + 'ORDER BY type;';
  pSelect := nil;
  rc := SQLITE_OK;
  zWrite := nil;

  rc := idxPrintfPrepareStmt(p^.db, @pSelect, pzErr, zSql,
    [AnsiString(zTab)]);
  while (rc = SQLITE_OK) and (sqlite3_step(pSelect) = SQLITE_ROW) do begin
    zCreate := sqlite3_column_text(pSelect, 0);
    if zCreate = nil then Continue;
    rc := sqlite3_exec(p^.dbv, zCreate, nil, nil, pzErr);
  end;
  idxFinalize(@rc, pSelect);

  if rc = SQLITE_OK then begin
    z := sqlite3PfMprintf('ALTER TABLE temp.%Q RENAME TO %Q',
      [AnsiString(zTab), AnsiString(zInt)]);
    if z = nil then rc := SQLITE_NOMEM
    else begin
      rc := sqlite3_exec(p^.dbv, z, nil, nil, pzErr);
      sqlite3_free(z);
    end;
  end;

  case pWrite^.eOp of
    SQLITE_INSERT_AUTH: begin
      zWrite := idxAppendText(@rc, zWrite, 'INSERT INTO %Q VALUES(',
        [AnsiString(zInt)]);
      for i := 0 to pTab^.nCol-1 do begin
        if i = 0 then
          zWrite := idxAppendText(@rc, zWrite, '?', [])
        else
          zWrite := idxAppendText(@rc, zWrite, ', ?', []);
      end;
      zWrite := idxAppendText(@rc, zWrite, ')', []);
    end;
    SQLITE_UPDATE_AUTH: begin
      zWrite := idxAppendText(@rc, zWrite, 'UPDATE %Q SET ', [AnsiString(zInt)]);
      for i := 0 to pTab^.nCol-1 do begin
        if i = 0 then
          zWrite := idxAppendText(@rc, zWrite, '%Q=?',
            [AnsiString(pTab^.aCol[i].zName)])
        else
          zWrite := idxAppendText(@rc, zWrite, ', %Q=?',
            [AnsiString(pTab^.aCol[i].zName)]);
      end;
    end;
  else
    Assert(pWrite^.eOp = SQLITE_DELETE_AUTH);
    if rc = SQLITE_OK then begin
      zWrite := sqlite3PfMprintf('DELETE FROM %Q', [AnsiString(zInt)]);
      if zWrite = nil then rc := SQLITE_NOMEM;
    end;
  end;

  if rc = SQLITE_OK then begin
    pX := nil;
    rc := sqlite3_prepare_v2(p^.dbv, zWrite, -1, @pX, nil);
    idxFinalize(@rc, pX);
    if rc <> SQLITE_OK then
      idxDatabaseError(p^.dbv, pzErr);
  end;
  sqlite3_free(zWrite);

  if rc = SQLITE_OK then
    rc := sqlite3_exec(p^.dbv, zDrop, nil, nil, pzErr);

  Result := rc;
end;

function idxProcessTriggers(p: Psqlite3expert; pzErr: PPAnsiChar): i32;
var rc: i32; pEnd, pFirst, pIter: PIdxWrite;
begin
  rc := SQLITE_OK;
  pEnd := nil;
  pFirst := PIdxWrite(p^.pWrite);
  while (rc = SQLITE_OK) and (pFirst <> pEnd) do begin
    pIter := pFirst;
    while (rc = SQLITE_OK) and (pIter <> pEnd) do begin
      rc := idxProcessOneTrigger(p, pIter, pzErr);
      pIter := pIter^.pNext;
    end;
    pEnd := pFirst;
    pFirst := PIdxWrite(p^.pWrite);
  end;
  Result := rc;
end;

function expertDbContainsObject(db: PTsqlite3; zTab: PAnsiChar;
  pbContains: Pi32): i32;
var
  zSql: PAnsiChar;
  pSql: PVdbe;
  rc, ret: i32;
begin
  zSql := 'SELECT 1 FROM sqlite_schema WHERE name = ?';
  pSql := nil; ret := 0;
  rc := sqlite3_prepare_v2(db, zSql, -1, @pSql, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_text(pSql, 1, zTab, -1, SQLITE_STATIC);
    if sqlite3_step(pSql) = SQLITE_ROW then ret := 1;
    rc := sqlite3_finalize(pSql);
  end;
  pbContains^ := ret;
  Result := rc;
end;

function expertSchemaSql(db: PTsqlite3; zSql: PAnsiChar;
  pzErr: PPAnsiChar): i32;
var rc, nErr: i32; zErr: PAnsiChar;
begin
  zErr := nil;
  rc := sqlite3_exec(db, zSql, nil, nil, @zErr);
  if (rc <> SQLITE_OK) and (zErr <> nil) then begin
    nErr := i32(strlen(zErr));
    if (nErr >= 15)
       and (CompareByte(zErr^, PAnsiChar('no such module:')^, 15) = 0) then begin
      sqlite3_free(zErr);
      rc := SQLITE_OK;
      zErr := nil;
    end;
  end;
  pzErr^ := zErr;
  Result := rc;
end;

function idxCreateVtabSchema(p: Psqlite3expert; pzErrmsg: PPAnsiChar): i32;
var
  rc, bVirtual, bExists, i: i32;
  pSchema: PVdbe;
  zType, zName, zSql: PAnsiChar;
  pTab: PIdxTable;
  zInner, zOuter: PAnsiChar;
begin
  rc := idxRegisterVtab(p);
  pSchema := nil;
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  rc := idxPrepareStmt(p^.db, @pSchema, pzErrmsg,
      'SELECT type, name, sql, 1, '
    + '       substr(sql,1,14)==''create virtual'' COLLATE nocase '
    + 'FROM sqlite_schema '
    + 'WHERE type IN (''table'',''view'') AND '
    + '      substr(name,1,7)!=''sqlite_'' COLLATE nocase '
    + ' UNION ALL '
    + 'SELECT type, name, sql, 2, 0 FROM sqlite_schema '
    + 'WHERE type = ''trigger'''
    + '  AND tbl_name IN(SELECT name FROM sqlite_schema WHERE type = ''view'') '
    + 'ORDER BY 4, 5 DESC, 1');
  while (rc = SQLITE_OK) and (sqlite3_step(pSchema) = SQLITE_ROW) do begin
    zType := sqlite3_column_text(pSchema, 0);
    zName := sqlite3_column_text(pSchema, 1);
    zSql  := sqlite3_column_text(pSchema, 2);
    bVirtual := sqlite3_column_int(pSchema, 4);
    bExists := 0;
    if (zType = nil) or (zName = nil) then Continue;
    rc := expertDbContainsObject(p^.dbv, zName, @bExists);
    if (rc <> 0) or (bExists <> 0) then Continue;

    if (zType[0] = 'v') or (zType[1] = 'r') or (bVirtual <> 0) then begin
      if zSql <> nil then
        rc := expertSchemaSql(p^.dbv, zSql, pzErrmsg);
    end else begin
      pTab := nil;
      rc := idxGetTableInfo(p^.db, zName, PPointer(@pTab), pzErrmsg);
      if (rc = SQLITE_OK) and (pTab <> nil) then begin
        zInner := nil; zOuter := nil;
        pTab^.pNext := PIdxTable(p^.pTable);
        p^.pTable := pTab;

        zInner := idxAppendText(@rc, nil, 'CREATE TABLE x(', []);
        for i := 0 to pTab^.nCol-1 do begin
          if i = 0 then
            zInner := idxAppendText(@rc, zInner, '%Q COLLATE %s',
              [AnsiString(pTab^.aCol[i].zName), AnsiString(pTab^.aCol[i].zColl)])
          else
            zInner := idxAppendText(@rc, zInner, ', %Q COLLATE %s',
              [AnsiString(pTab^.aCol[i].zName), AnsiString(pTab^.aCol[i].zColl)]);
        end;
        zInner := idxAppendText(@rc, zInner, ')', []);

        zOuter := idxAppendText(@rc, nil,
          'CREATE VIRTUAL TABLE %Q USING expert(%Q)',
          [AnsiString(zName), AnsiString(zInner)]);
        if rc = SQLITE_OK then
          rc := sqlite3_exec(p^.dbv, zOuter, nil, nil, pzErrmsg);
        sqlite3_free(zInner);
        sqlite3_free(zOuter);
      end;
    end;
  end;
  idxFinalize(@rc, pSchema);
  Result := rc;
end;

procedure idxSampleFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPointer); cdecl;
var
  p: PIdxSampleCtx;
  bRet: i32;
  rnd: Word;
begin
  p := PIdxSampleCtx(sqlite3_user_data(pCtx));
  if p^.nRow = 0.0 then
    bRet := 1
  else begin
    if (p^.nRet / p^.nRow) <= p^.target then bRet := 1 else bRet := 0;
    if bRet = 0 then begin
      sqlite3_randomness(2, @rnd);
      if (i32(rnd) mod 100) <= p^.iTarget then bRet := 1 else bRet := 0;
    end;
  end;
  sqlite3_result_int(pCtx, bRet);
  p^.nRow := p^.nRow + 1.0;
  p^.nRet := p^.nRet + Double(bRet);
end;

procedure idxRemFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPointer); cdecl;
var
  p: PIdxRemCtx;
  pSlot: PIdxRemSlot;
  iSlot: i32;
  nByte: i64;
  pData: Pointer;
  zNew: PAnsiChar;
  argv0, argv1: Psqlite3_value;
begin
  p := PIdxRemCtx(sqlite3_user_data(pCtx));
  Assert(argc = 2);
  argv0 := Psqlite3_value(argv[0]);
  argv1 := Psqlite3_value(argv[1]);
  iSlot := sqlite3_value_int(argv0);
  Assert(iSlot < p^.nSlot);
  pSlot := @p^.aSlot[iSlot];

  case pSlot^.eType of
    SQLITE_NULL: ;
    SQLITE_INTEGER: sqlite3_result_int64(pCtx, pSlot^.iVal);
    SQLITE_FLOAT:   sqlite3_result_double(pCtx, pSlot^.rVal);
    SQLITE_BLOB:    sqlite3_result_blob(pCtx, pSlot^.z, i32(pSlot^.n),
                       SQLITE_TRANSIENT);
    SQLITE_TEXT:    sqlite3_result_text(pCtx, pSlot^.z, i32(pSlot^.n),
                       SQLITE_TRANSIENT);
  end;

  pSlot^.eType := sqlite3_value_type(argv1);
  case pSlot^.eType of
    SQLITE_NULL: ;
    SQLITE_INTEGER: pSlot^.iVal := sqlite3_value_int64(argv1);
    SQLITE_FLOAT:   pSlot^.rVal := sqlite3_value_double(argv1);
    SQLITE_BLOB, SQLITE_TEXT: begin
      nByte := sqlite3_value_bytes(argv1);
      pData := nil;
      if nByte > pSlot^.nByte then begin
        zNew := PAnsiChar(sqlite3_realloc64(pSlot^.z, u64(nByte*2)));
        if zNew = nil then begin
          sqlite3_result_error_nomem(pCtx); Exit;
        end;
        pSlot^.nByte := nByte*2;
        pSlot^.z := zNew;
      end;
      pSlot^.n := nByte;
      if pSlot^.eType = SQLITE_BLOB then begin
        pData := sqlite3_value_blob(argv1);
        if pData <> nil then Move(pData^, pSlot^.z^, nByte);
      end else begin
        pData := sqlite3_value_text(argv1);
        Move(pData^, pSlot^.z^, nByte);
      end;
    end;
  end;
end;

function idxLargestIndex(db: PTsqlite3; pnMax: Pi32;
  pzErr: PPAnsiChar): i32;
var
  rc: i32; pMax: PVdbe;
const
  zMax: PAnsiChar =
    'SELECT max(i.seqno) FROM '
  + '  sqlite_schema AS s, '
  + '  pragma_index_list(s.name) AS l, '
  + '  pragma_index_info(l.name) AS i '
  + 'WHERE s.type = ''table''';
begin
  pMax := nil;
  pnMax^ := 0;
  rc := idxPrepareStmt(db, @pMax, pzErr, zMax);
  if (rc = SQLITE_OK) and (sqlite3_step(pMax) = SQLITE_ROW) then
    pnMax^ := sqlite3_column_int(pMax, 0) + 1;
  idxFinalize(@rc, pMax);
  Result := rc;
end;

function idxPopulateOneStat1(p: Psqlite3expert; pIndexXInfo, pWriteStat: PVdbe;
  zTab, zIdx: PAnsiChar; pzErr: PPAnsiChar): i32;
var
  zCols, zOrder, zQuery, zComma, zName, zColl: PAnsiChar;
  nCol, i, rc: i32;
  pQuery: PVdbe;
  aStat: ^i64;
  pEntry: PIdxHashEntry;
  zStat: PAnsiChar;
  dbrem: PTsqlite3;
  s0: i64;
begin
  zCols := nil; zOrder := nil; zQuery := nil;
  nCol := 0;
  pQuery := nil; aStat := nil;
  rc := SQLITE_OK;
  Assert(p^.iSample > 0);

  sqlite3_bind_text(pIndexXInfo, 1, zIdx, -1, SQLITE_STATIC);
  while (rc = SQLITE_OK) and (sqlite3_step(pIndexXInfo) = SQLITE_ROW) do begin
    if zCols = nil then zComma := '' else zComma := ', ';
    zName := sqlite3_column_text(pIndexXInfo, 0);
    zColl := sqlite3_column_text(pIndexXInfo, 1);
    if zName = nil then begin
      sqlite3_free(zCols); sqlite3_free(zOrder);
      Result := sqlite3_reset(pIndexXInfo); Exit;
    end;
    zCols := idxAppendText(@rc, zCols,
      '%sx.%Q IS sqlite_expert_rem(%d, x.%Q) COLLATE %s',
      [AnsiString(zComma), AnsiString(zName), Integer(nCol),
       AnsiString(zName), AnsiString(zColl)]);
    Inc(nCol);
    zOrder := idxAppendText(@rc, zOrder, '%s%d',
      [AnsiString(zComma), Integer(nCol)]);
  end;
  sqlite3_reset(pIndexXInfo);
  if rc = SQLITE_OK then begin
    if p^.iSample = 100 then
      zQuery := sqlite3PfMprintf('SELECT %s FROM %Q x ORDER BY %s',
        [AnsiString(zCols), AnsiString(zTab), AnsiString(zOrder)])
    else
      zQuery := sqlite3PfMprintf(
        'SELECT %s FROM temp.' + UNIQUE_TABLE_NAME + ' x ORDER BY %s',
        [AnsiString(zCols), AnsiString(zOrder)]);
  end;
  sqlite3_free(zCols); sqlite3_free(zOrder);

  if rc = SQLITE_OK then begin
    if p^.iSample = 100 then dbrem := p^.db else dbrem := p^.dbv;
    rc := idxPrepareStmt(dbrem, @pQuery, pzErr, zQuery);
  end;
  sqlite3_free(zQuery);

  if rc = SQLITE_OK then
    aStat := idxMalloc(@rc, SizeOf(i64)*(nCol+1));
  if (rc = SQLITE_OK) and (sqlite3_step(pQuery) = SQLITE_ROW) then begin
    zStat := nil;
    for i := 0 to nCol do (aStat + i)^ := 1;
    while (rc = SQLITE_OK) and (sqlite3_step(pQuery) = SQLITE_ROW) do begin
      Inc((aStat + 0)^);
      i := 0;
      while i < nCol do begin
        if sqlite3_column_int(pQuery, i) = 0 then Break;
        Inc(i);
      end;
      while i < nCol do begin
        Inc((aStat + i + 1)^);
        Inc(i);
      end;
    end;
    if rc = SQLITE_OK then begin
      s0 := (aStat + 0)^;
      zStat := sqlite3PfMprintf('%lld', [Int64(s0)]);
      if zStat = nil then rc := SQLITE_NOMEM;
      i := 1;
      while (rc = SQLITE_OK) and (i <= nCol) do begin
        zStat := idxAppendText(@rc, zStat, ' %lld',
          [Int64((s0 + (aStat + i)^ div 2) div (aStat + i)^)]);
        Inc(i);
      end;
    end;
    if rc = SQLITE_OK then begin
      sqlite3_bind_text(pWriteStat, 1, zTab, -1, SQLITE_STATIC);
      sqlite3_bind_text(pWriteStat, 2, zIdx, -1, SQLITE_STATIC);
      sqlite3_bind_text(pWriteStat, 3, zStat, -1, SQLITE_STATIC);
      sqlite3_step(pWriteStat);
      rc := sqlite3_reset(pWriteStat);
    end;
    pEntry := peHashFind(p, zIdx, i32(strlen(zIdx)));
    if pEntry <> nil then begin
      Assert(pEntry^.zVal2 = nil);
      pEntry^.zVal2 := zStat;
    end else
      sqlite3_free(zStat);
  end;
  sqlite3_free(aStat);
  idxFinalize(@rc, pQuery);
  Result := rc;
end;

function idxBuildSampleTable(p: Psqlite3expert; zTab: PAnsiChar): i32;
var rc: i32; zSql: PAnsiChar;
begin
  rc := sqlite3_exec(p^.dbv,
    'DROP TABLE IF EXISTS temp.' + UNIQUE_TABLE_NAME,
    nil, nil, nil);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  zSql := sqlite3PfMprintf(
    'CREATE TABLE temp.' + UNIQUE_TABLE_NAME + ' AS SELECT * FROM %Q',
    [AnsiString(zTab)]);
  if zSql = nil then begin Result := SQLITE_NOMEM; Exit; end;
  rc := sqlite3_exec(p^.dbv, zSql, nil, nil, nil);
  sqlite3_free(zSql);
  Result := rc;
end;

function idxPopulateStat1(p: Psqlite3expert; pzErr: PPAnsiChar): i32;
const
  zAllIndex: PAnsiChar =
      'SELECT s.rowid, s.name, l.name FROM '
    + '  sqlite_schema AS s, '
    + '  pragma_index_list(s.name) AS l '
    + 'WHERE s.type = ''table''';
  zIndexXInfoSql: PAnsiChar =
    'SELECT name, coll FROM pragma_index_xinfo(?) WHERE key';
  zWriteSql: PAnsiChar = 'INSERT INTO sqlite_stat1 VALUES(?, ?, ?)';
var
  rc, nMax, i: i32;
  pCtx: PIdxRemCtx;
  samplectx: TIdxSampleCtx;
  iPrev: i64;
  iRowid: i64;
  pAllIndex, pIndexXInfo, pWrite: PVdbe;
  zTab, zIdx: PAnsiChar;
  dbrem: PTsqlite3;
  nByte: i64;
begin
  rc := SQLITE_OK;
  nMax := 0;
  pCtx := nil;
  iPrev := -100000;
  pAllIndex := nil; pIndexXInfo := nil; pWrite := nil;
  FillChar(samplectx, SizeOf(samplectx), 0);

  if p^.iSample = 0 then begin Result := SQLITE_OK; Exit; end;
  rc := idxLargestIndex(p^.dbm, @nMax, pzErr);
  if (nMax <= 0) or (rc <> SQLITE_OK) then begin Result := rc; Exit; end;

  rc := sqlite3_exec(p^.dbm, 'ANALYZE; PRAGMA writable_schema=1',
    nil, nil, nil);
  if rc = SQLITE_OK then begin
    nByte := SizeOf(TIdxRemCtx) + SizeOf(TIdxRemSlot)*nMax;
    pCtx := PIdxRemCtx(idxMalloc(@rc, nByte));
  end;
  if rc = SQLITE_OK then begin
    if p^.iSample = 100 then dbrem := p^.db else dbrem := p^.dbv;
    rc := sqlite3_create_function(dbrem, 'sqlite_expert_rem',
      2, SQLITE_UTF8, pCtx, @idxRemFunc, nil, nil);
  end;
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(p^.db, 'sqlite_expert_sample',
      0, SQLITE_UTF8, @samplectx, @idxSampleFunc, nil, nil);

  if rc = SQLITE_OK then begin
    pCtx^.nSlot := i32(nMax + 1);
    rc := idxPrepareStmt(p^.dbm, @pAllIndex, pzErr, zAllIndex);
  end;
  if rc = SQLITE_OK then
    rc := idxPrepareStmt(p^.dbm, @pIndexXInfo, pzErr, zIndexXInfoSql);
  if rc = SQLITE_OK then
    rc := idxPrepareStmt(p^.dbm, @pWrite, pzErr, zWriteSql);

  while (rc = SQLITE_OK) and (sqlite3_step(pAllIndex) = SQLITE_ROW) do begin
    iRowid := sqlite3_column_int64(pAllIndex, 0);
    zTab := sqlite3_column_text(pAllIndex, 1);
    zIdx := sqlite3_column_text(pAllIndex, 2);
    if (zTab = nil) or (zIdx = nil) then Continue;
    if (p^.iSample < 100) and (iPrev <> iRowid) then begin
      samplectx.target := Double(p^.iSample) / 100.0;
      samplectx.iTarget := p^.iSample;
      samplectx.nRow := 0.0;
      samplectx.nRet := 0.0;
      rc := idxBuildSampleTable(p, zTab);
      if rc <> SQLITE_OK then Break;
    end;
    rc := idxPopulateOneStat1(p, pIndexXInfo, pWrite, zTab, zIdx, pzErr);
    iPrev := iRowid;
  end;
  if (rc = SQLITE_OK) and (p^.iSample < 100) then
    rc := sqlite3_exec(p^.dbv,
      'DROP TABLE IF EXISTS temp.' + UNIQUE_TABLE_NAME, nil, nil, nil);

  idxFinalize(@rc, pAllIndex);
  idxFinalize(@rc, pIndexXInfo);
  idxFinalize(@rc, pWrite);

  if pCtx <> nil then begin
    for i := 0 to pCtx^.nSlot-1 do
      sqlite3_free(pCtx^.aSlot[i].z);
    sqlite3_free(pCtx);
  end;
  if rc = SQLITE_OK then
    rc := sqlite3_exec(p^.dbm, 'ANALYZE sqlite_schema', nil, nil, nil);

  sqlite3_create_function(p^.db, 'sqlite_expert_rem',
    2, SQLITE_UTF8, nil, nil, nil, nil);
  sqlite3_create_function(p^.db, 'sqlite_expert_sample',
    0, SQLITE_UTF8, nil, nil, nil, nil);

  sqlite3_exec(p^.db,
    'DROP TABLE IF EXISTS temp.' + UNIQUE_TABLE_NAME, nil, nil, nil);
  Result := rc;
end;

{ ===============================================================
  Dummy collations + UDFs so expert can prepare SQL that references
  custom collations / functions present only in the user database.
  =============================================================== }

function dummyCompare(up1: Pointer; up2: i32; up3: Pointer; up4: i32;
  up5: Pointer): i32; cdecl;
begin
  Assert(False);  { VDBE should never be run on dbm/dbv prepares }
  Result := 0;
end;

procedure useDummyCS(up1: Pointer; db: PTsqlite3; etr: i32;
  zName: PAnsiChar); cdecl;
begin
  sqlite3_create_collation_v2(db, zName, etr, nil, @dummyCompare, nil);
end;

procedure dummyUDF(pCtx: Psqlite3_context; argc: i32;
  argv: PPointer); cdecl;
begin
  Assert(False);
end;

procedure dummyUDFvalue(pCtx: Psqlite3_context); cdecl;
begin
  Assert(False);
end;

function registerUDFs(dbSrc, dbDst: PTsqlite3): i32;
var
  pStmt: PVdbe;
  rc, rcf, nargs, flags, ienc: i32;
  name, ftype, enc: PAnsiChar;
begin
  rc := sqlite3_prepare_v2(dbSrc,
    'SELECT name,type,enc,narg,flags '
  + 'FROM pragma_function_list() '
  + 'WHERE builtin==0', -1, @pStmt, nil);
  if rc = SQLITE_OK then begin
    repeat
      rc := sqlite3_step(pStmt);
      if rc = SQLITE_ROW then begin
        nargs := sqlite3_column_int(pStmt, 3);
        flags := sqlite3_column_int(pStmt, 4);
        name  := sqlite3_column_text(pStmt, 0);
        ftype := sqlite3_column_text(pStmt, 1);
        enc   := sqlite3_column_text(pStmt, 2);
        if (name = nil) or (ftype = nil) or (enc = nil) then
          { OOM, skip }
        else begin
          ienc := SQLITE_UTF8;
          rcf := SQLITE_ERROR;
          if StrComp(enc, 'utf16le') = 0 then ienc := SQLITE_UTF16LE
          else if StrComp(enc, 'utf16be') = 0 then ienc := SQLITE_UTF16BE;
          ienc := ienc or (flags and (SQLITE_DETERMINISTIC or SQLITE_DIRECTONLY));
          if StrComp(ftype, 'w') = 0 then
            rcf := sqlite3_create_window_function(dbDst, name, nargs, ienc, nil,
              @dummyUDF, @dummyUDFvalue, nil, nil, nil)
          else if StrComp(ftype, 'a') = 0 then
            rcf := sqlite3_create_function(dbDst, name, nargs, ienc, nil,
              nil, @dummyUDF, @dummyUDFvalue)
          else if StrComp(ftype, 's') = 0 then
            rcf := sqlite3_create_function(dbDst, name, nargs, ienc, nil,
              @dummyUDF, nil, nil);
          if rcf <> SQLITE_OK then begin
            rc := rcf; Break;
          end;
        end;
      end;
    until rc <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
    if rc = SQLITE_DONE then rc := SQLITE_OK;
  end;
  Result := rc;
end;

{ ===============================================================
  Public API
  =============================================================== }

function sqlite3_expert_new(db: PTsqlite3; pzErrmsg: PPAnsiChar): Psqlite3expert;
var
  rc, bExists: i32;
  pNew: Psqlite3expert;
  pSql: PVdbe;
  zSql, zName: PAnsiChar;
begin
  rc := SQLITE_OK;
  pNew := Psqlite3expert(idxMalloc(@rc, SizeOf(Tsqlite3expert)));

  if rc = SQLITE_OK then begin
    pNew^.db := db;
    pNew^.iSample := 100;
    rc := sqlite3_open(':memory:', @pNew^.dbv);
  end;
  if rc = SQLITE_OK then begin
    rc := sqlite3_open(':memory:', @pNew^.dbm);
    if rc = SQLITE_OK then
      sqlite3_db_config_int(pNew^.dbm, SQLITE_DBCONFIG_TRIGGER_EQP, 1, nil);
  end;

  if rc = SQLITE_OK then rc := sqlite3_collation_needed(pNew^.dbm, nil, @useDummyCS);
  if rc = SQLITE_OK then rc := sqlite3_collation_needed(pNew^.dbv, nil, @useDummyCS);

  if rc = SQLITE_OK then rc := registerUDFs(pNew^.db, pNew^.dbm);
  if rc = SQLITE_OK then rc := registerUDFs(pNew^.db, pNew^.dbv);

  if rc = SQLITE_OK then begin
    pSql := nil;
    rc := idxPrintfPrepareStmt(pNew^.db, @pSql, pzErrmsg,
      'SELECT sql, name, substr(sql,1,14)==''create virtual'' COLLATE nocase'
    + ' FROM sqlite_schema WHERE substr(name,1,7)!=''sqlite_'' COLLATE nocase'
    + ' ORDER BY 3 DESC, rowid', []);
    while (rc = SQLITE_OK) and (sqlite3_step(pSql) = SQLITE_ROW) do begin
      zSql  := sqlite3_column_text(pSql, 0);
      zName := sqlite3_column_text(pSql, 1);
      bExists := 0;
      rc := expertDbContainsObject(pNew^.dbm, zName, @bExists);
      if (rc = SQLITE_OK) and (zSql <> nil) and (bExists = 0) then
        rc := expertSchemaSql(pNew^.dbm, zSql, pzErrmsg);
    end;
    idxFinalize(@rc, pSql);
  end;

  if rc = SQLITE_OK then rc := idxCreateVtabSchema(pNew, pzErrmsg);
  if rc = SQLITE_OK then
    sqlite3_set_authorizer(pNew^.dbv, @idxAuthCallback, pNew);

  if rc <> SQLITE_OK then begin
    sqlite3_expert_destroy_(pNew);
    pNew := nil;
  end;
  Result := pNew;
end;

function sqlite3_expert_config(p: Psqlite3expert; op: i32; iArg: i32): i32;
var v: i32;
begin
  case op of
    EXPERT_CONFIG_SAMPLE: begin
      v := iArg;
      if v < 0 then v := 0;
      if v > 100 then v := 100;
      p^.iSample := v;
      Result := SQLITE_OK;
    end;
  else
    Result := SQLITE_NOTFOUND;
  end;
end;

function sqlite3_expert_sql(p: Psqlite3expert; zSql: PAnsiChar;
  pzErr: PPAnsiChar): i32;
var
  pScanOrig: PIdxScan;
  pStmtOrig: PIdxStatement;
  rc: i32;
  zStmt: PAnsiChar;
  pStmt: PVdbe;
  pNew: PIdxStatement;
  z: PAnsiChar;
  n: i64;
  pzTail: PAnsiChar;
begin
  pScanOrig := PIdxScan(p^.pScan);
  pStmtOrig := PIdxStatement(p^.pStatement);
  rc := SQLITE_OK;
  zStmt := zSql;

  if p^.bRun <> 0 then begin Result := SQLITE_MISUSE; Exit; end;

  while (rc = SQLITE_OK) and (zStmt <> nil) and (zStmt[0] <> #0) do begin
    pStmt := nil;
    rc := idxPrepareStmt(p^.db, @pStmt, pzErr, zStmt);
    if rc <> SQLITE_OK then Break;
    sqlite3_finalize(pStmt);
    pzTail := nil;
    rc := sqlite3_prepare_v2(p^.dbv, zStmt, -1, @pStmt, @pzTail);
    if rc = SQLITE_OK then begin
      if pStmt <> nil then begin
        z := sqlite3_sql(pStmt);
        n := strlen(z);
        pNew := PIdxStatement(idxMalloc(@rc, SizeOf(TIdxStatement) + n + 1));
        if rc = SQLITE_OK then begin
          pNew^.zSql := PAnsiChar(@pNew[1]);
          Move(z^, pNew^.zSql^, n+1);
          pNew^.pNext := PIdxStatement(p^.pStatement);
          if p^.pStatement <> nil then
            pNew^.iId := PIdxStatement(p^.pStatement)^.iId + 1;
          p^.pStatement := pNew;
        end;
        sqlite3_finalize(pStmt);
      end;
    end else
      idxDatabaseError(p^.dbv, pzErr);
    zStmt := pzTail;
  end;

  if rc <> SQLITE_OK then begin
    idxScanFree(PIdxScan(p^.pScan), pScanOrig);
    idxStatementFree(PIdxStatement(p^.pStatement), pStmtOrig);
    p^.pScan := pScanOrig;
    p^.pStatement := pStmtOrig;
  end;
  Result := rc;
end;

function sqlite3_expert_analyze(p: Psqlite3expert; pzErr: PPAnsiChar): i32;
var rc: i32; pEntry: PIdxHashEntry; z2: PAnsiChar;
begin
  rc := idxProcessTriggers(p, pzErr);

  if rc = SQLITE_OK then
    rc := idxCreateCandidates(p)
  else if rc = SQLITE_BUSY_TIMEOUT then begin
    if pzErr <> nil then
      pzErr^ := sqlite3PfMprintf(
        'Cannot find a unique index name to propose.', []);
    Result := rc; Exit;
  end;

  if rc = SQLITE_OK then rc := idxPopulateStat1(p, pzErr);

  pEntry := PIdxHashEntry(p^.hIdxFirst);
  while pEntry <> nil do begin
    if pEntry^.zVal2 <> nil then z2 := ' -- stat1: ' else z2 := '';
    if pEntry^.zVal2 = nil then
      p^.zCandidates := idxAppendText(@rc, p^.zCandidates, '%s;'#10,
        [AnsiString(pEntry^.zVal)])
    else
      p^.zCandidates := idxAppendText(@rc, p^.zCandidates, '%s;%s%s'#10,
        [AnsiString(pEntry^.zVal), AnsiString(z2),
         AnsiString(pEntry^.zVal2)]);
    pEntry := pEntry^.pNext;
  end;

  if rc = SQLITE_OK then rc := idxFindIndexes(p, pzErr);
  if rc = SQLITE_OK then p^.bRun := 1;
  Result := rc;
end;

function sqlite3_expert_count(p: Psqlite3expert): i32;
var nRet: i32;
begin
  nRet := 0;
  if p^.pStatement <> nil then
    nRet := PIdxStatement(p^.pStatement)^.iId + 1;
  Result := nRet;
end;

function sqlite3_expert_report(p: Psqlite3expert; iStmt: i32;
  eReport: i32): PAnsiChar;
var zRet: PAnsiChar; pStmt: PIdxStatement;
begin
  zRet := nil;
  if p^.bRun = 0 then begin Result := nil; Exit; end;
  pStmt := PIdxStatement(p^.pStatement);
  while (pStmt <> nil) and (pStmt^.iId <> iStmt) do
    pStmt := pStmt^.pNext;
  case eReport of
    EXPERT_REPORT_SQL:        if pStmt <> nil then zRet := pStmt^.zSql;
    EXPERT_REPORT_INDEXES:    if pStmt <> nil then zRet := pStmt^.zIdx;
    EXPERT_REPORT_PLAN:       if pStmt <> nil then zRet := pStmt^.zEQP;
    EXPERT_REPORT_CANDIDATES: zRet := p^.zCandidates;
  end;
  Result := zRet;
end;

procedure sqlite3_expert_destroy_(p: Psqlite3expert);
begin
  if p <> nil then begin
    sqlite3_close(p^.dbm);
    sqlite3_close(p^.dbv);
    idxScanFree(PIdxScan(p^.pScan), nil);
    idxStatementFree(PIdxStatement(p^.pStatement), nil);
    idxTableFree(PIdxTable(p^.pTable));
    idxWriteFree(PIdxWrite(p^.pWrite));
    peHashClear(p);
    sqlite3_free(p^.zCandidates);
    sqlite3_free(p);
  end;
end;

procedure sqlite3_expert_destroy(p: Psqlite3expert);
begin
  sqlite3_expert_destroy_(p);
end;

end.
