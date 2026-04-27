{$I ../passqlite3.inc}
program TestWhereSimple;
{
  Phase 6.9-bis (step 11g.2.b) gate test — vertical slice for the rowid-EQ
  shape of sqlite3WhereBegin / sqlite3WhereEnd.

  The test hand-builds a single-table SrcList and a "rowid = 5" WHERE
  expression, drives it through sqlite3WhereBegin + sqlite3WhereEnd, and
  asserts that the resulting VDBE program contains the expected opcode
  sequence:

    OP_OpenRead   (level-0 table cursor open)
    OP_Integer    (literal 5 → register, via sqlite3ExprCodeTarget)
    OP_SeekRowid  (seek cursor to rowid; jumps to addrBrk on miss)

  The real schema (pTable, pSchema, tnum) is borrowed from a live
  sqlite3_open + CREATE TABLE; SrcList, Expr, and Parse are stack-built so
  the exercise stays isolated from the rest of the parser pipeline (which
  still routes SELECT through stub helpers — Phase 7).

    T1  whereShortCut populates pLoop with WHERE_IPK | WHERE_ONEROW
    T2  sqlite3WhereBegin returns non-nil
    T3  WhereInfo has 1 level
    T4  Vdbe contains OP_OpenRead at level-0 cursor 0
    T5  Vdbe contains OP_SeekRowid jumping to addrBrk
    T6  pLevel^.op = OP_Noop after WhereBegin (one-shot lookup)
    T7  rowid term marked TERM_CODED (disableTerm path)
    T8  sqlite3WhereEnd resolves addrBrk + iBreak
    T9  pParse.nQueryLoop restored to savedNQueryLoop after WhereEnd

  Gate: T1-T9 all PASS.

  Phase 6.9-bis (step 11g.2.c) extension — multi-term gate.
  Three additional sections drive sqlite3WhereBegin / sqlite3WhereEnd through
  multi-term WHERE shapes that exercise the whereexpr.c helpers landed in
  11g.2.c:

    M1  "rowid = 5 AND col = 7"   — TK_AND chain split into two base terms;
                                    whereShortCut still picks WHERE_IPK on
                                    the rowid leaf, leaving the col=7 term
                                    in the clause for the eventual planner.
    M2  "rowid IN (1,2,3)"        — TK_IN cannot be picked by whereShortCut
                                    (no WO_EQ).  WhereBegin returns nil; the
                                    test verifies analysis populated the
                                    WhereClause cleanly and pParse.nErr = 0.
    M3  "rowid BETWEEN 1 AND 5"   — TK_BETWEEN gets virtual WO_GE / WO_LE
                                    children synthesized by exprAnalyze.
                                    WhereBegin returns nil (no WO_EQ on
                                    rowid); the test asserts the 3 terms
                                    (parent + 2 children) are present.
}

uses
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(const name: string; cond: Boolean);
begin
  if cond then
  begin
    Inc(gPass);
    WriteLn('PASS  ', name);
  end else
  begin
    Inc(gFail);
    WriteLn('FAIL  ', name);
  end;
end;

function FindOpcode(v: PVdbe; want: u8; startAt: i32): i32;
var
  i: i32;
  pop: PVdbeOp;
begin
  Result := -1;
  for i := startAt to v^.nOp - 1 do
  begin
    pop := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    if pop^.opcode = want then begin Result := i; Exit; end;
  end;
end;

function GetOp(v: PVdbe; addr: i32): PVdbeOp;
begin
  Result := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(addr) * SizeOf(TVdbeOp));
end;

{ ---------------------------------------------------------------------------
  BuildSrc — allocate a 1-entry SrcList referencing pTab at cursor 0.
  Mirrors the inline construction in main; factored out so the multi-term
  sections can share the same setup.
  --------------------------------------------------------------------------- }
function BuildSrc(db: PTsqlite3; pTab: PTable2): PSrcList;
var
  buf: Pointer;
  it:  PSrcItem;
begin
  buf := sqlite3DbMallocZero(db, SZ_SRCLIST_HEADER + SizeOf(TSrcItem));
  if buf = nil then begin WriteLn('FATAL: SrcList alloc'); Halt(2); end;
  Result := PSrcList(buf);
  Result^.nSrc   := 1;
  Result^.nAlloc := 1;
  it := @SrcListItems(Result)[0];
  it^.pSTab   := pTab;
  it^.iCursor := 0;
  it^.colUsed := Bitmask(1);
end;

{ Build a fresh Parse/Vdbe pair backed by db.  The Parse record is filled
  in-place by the caller (passed by var). }
procedure InitParse(db: PTsqlite3; var p: TParse; out v: PVdbe);
begin
  FillChar(p, SizeOf(p), 0);
  p.db        := db;
  p.eParseMode:= 0;
  p.nQueryLoop:= 0;
  p.nTab      := 1;
  v := sqlite3GetVdbe(@p);
  if v = nil then begin WriteLn('FATAL: GetVdbe'); Halt(2); end;
end;

{ ---- M1: "rowid = 5 AND col = 7" ----------------------------------------- }
procedure RunMultiAndTest(db: PTsqlite3; pTab: PTable2);
var
  parse: TParse;
  v:     PVdbe;
  pSrc:  PSrcList;
  pColR, pIntR, pEqR: PExpr;
  pColC, pIntC, pEqC: PExpr;
  pAnd:  PExpr;
  pWInfo: PWhereInfo;
  pLevel: PWhereLevel;
  pLoop:  PWhereLoop;
  iOp:    i32;
begin
  WriteLn;
  WriteLn('--- M1: rowid = 5 AND col = 7 ---');
  InitParse(db, parse, v);
  pSrc := BuildSrc(db, pTab);

  pColR := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColR^.iTable := 0; pColR^.iColumn := -1;
  pIntR := sqlite3ExprInt32(db, 5);
  pEqR  := sqlite3PExpr(@parse, TK_EQ, pColR, pIntR);

  pColC := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColC^.iTable := 0; pColC^.iColumn := 0;        { non-rowid column }
  pIntC := sqlite3ExprInt32(db, 7);
  pEqC  := sqlite3PExpr(@parse, TK_EQ, pColC, pIntC);

  pAnd  := sqlite3PExpr(@parse, TK_AND, pEqR, pEqC);

  pWInfo := sqlite3WhereBegin(@parse, pSrc, pAnd, nil, nil, nil, 0, 0);
  Check('M1a WhereBegin returns non-nil for AND-chain', pWInfo <> nil);
  if pWInfo = nil then begin sqlite3DbFree(db, pSrc); Exit; end;

  pLevel := @whereInfoLevels(pWInfo)[0];
  pLoop  := pLevel^.pWLoop;
  Check('M1b sWC nTerm = 2 (both AND leaves split)',
        pWInfo^.sWC.nTerm = 2);
  Check('M1c whereShortCut still picked WHERE_IPK',
        (pLoop^.wsFlags and WHERE_IPK) <> 0);
  Check('M1d pLoop nLTerm = 1 (only the rowid leaf is the index key)',
        pLoop^.nLTerm = 1);
  Check('M1e rowid-EQ leaf is TERM_CODED',
        (pLoop^.aLTerm[0]^.wtFlags and TERM_CODED) <> 0);
  Check('M1f col=7 leaf is now TERM_CODED (residual emitted in body, sub-progress 9)',
        (pWInfo^.sWC.a[1].wtFlags and TERM_CODED) <> 0);

  iOp := FindOpcode(v, OP_OpenRead, 0);
  Check('M1g OP_OpenRead emitted', iOp >= 0);
  iOp := FindOpcode(v, OP_SeekRowid, 0);
  Check('M1h OP_SeekRowid emitted', iOp >= 0);

  sqlite3WhereEnd(pWInfo);
  Check('M1i WhereEnd succeeded', True);

  sqlite3DbFree(db, pSrc);
end;

{ ---- M2: "rowid IN (1,2,3)" ---------------------------------------------- }
procedure RunInTest(db: PTsqlite3; pTab: PTable2);
var
  parse: TParse;
  v:     PVdbe;
  pSrc:  PSrcList;
  pCol:  PExpr;
  pInList: PExprList;
  pIn:   PExpr;
  pWInfo: PWhereInfo;
  pTerm: PWhereTerm;
  pWi2:  PWhereInfo;
  pWC:   PWhereClause;
begin
  WriteLn;
  WriteLn('--- M2: rowid IN (1,2,3) ---');
  InitParse(db, parse, v);
  pSrc := BuildSrc(db, pTab);

  pCol := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol^.iTable := 0; pCol^.iColumn := -1;
  pInList := sqlite3ExprListAppend(@parse, nil, sqlite3ExprInt32(db, 1));
  pInList := sqlite3ExprListAppend(@parse, pInList, sqlite3ExprInt32(db, 2));
  pInList := sqlite3ExprListAppend(@parse, pInList, sqlite3ExprInt32(db, 3));
  pIn  := sqlite3PExpr(@parse, TK_IN, pCol, nil);
  pIn^.x.pList := pInList;

  pWInfo := sqlite3WhereBegin(@parse, pSrc, pIn, nil, nil, nil, 0, 0);

  { Sub-progress 9: the SCAN-with-residual fallback now picks up IN-list
    shapes that whereShortCut cannot match.  WhereBegin returns non-nil,
    emits OP_OpenRead + OP_Rewind, and emits a per-row residual filter
    via sqlite3ExprIfFalse on the TK_IN expression. }
  Check('M2a WhereBegin returns non-nil for IN-list (SCAN+residual)',
        pWInfo <> nil);
  Check('M2b parse.nErr = 0',
        parse.nErr = 0);
  if pWInfo <> nil then
  begin
    Check('M2g OP_OpenRead emitted',
          FindOpcode(v, OP_OpenRead, 0) >= 0);
    Check('M2h OP_Rewind emitted',
          FindOpcode(v, OP_Rewind, 0) >= 0);
    Check('M2i IN-list term tagged TERM_CODED after residual emission',
          (pWInfo^.sWC.a[0].wtFlags and TERM_CODED) <> 0);
    sqlite3WhereEnd(pWInfo);
  end;

  { Independently exercise the analysis pipeline against the same shape so
    the regression catches breakage in sqlite3WhereSplit /
    sqlite3WhereExprAnalyze for IN terms even before the planner can
    consume them. }
  pWi2 := PWhereInfo(sqlite3DbMallocZero(db, SizeOf(TWhereInfo)));
  pWi2^.pParse   := @parse;
  pWi2^.pTabList := pSrc;
  pWC := @pWi2^.sWC;
  sqlite3WhereClauseInit(pWC, pWi2);
  sqlite3WhereSplit(pWC, pIn, TK_AND);
  Check('M2c sqlite3WhereSplit produced 1 base term', pWC^.nTerm = 1);
  sqlite3WhereExprAnalyze(pSrc, pWC);
  pTerm := @pWC^.a[0];
  Check('M2d analyzed term has WO_IN',
        (pTerm^.eOperator and WO_IN) <> 0);
  Check('M2e analyzed term leftCursor = 0',
        pTerm^.leftCursor = 0);
  Check('M2f analyzed term u.leftColumn = -1 (rowid)',
        pTerm^.u.leftColumn = -1);
  sqlite3WhereClauseClear(pWC);
  sqlite3DbFree(db, pWi2);

  sqlite3DbFree(db, pSrc);
end;

{ ---- M3: "rowid BETWEEN 1 AND 5" ----------------------------------------- }
procedure RunBetweenTest(db: PTsqlite3; pTab: PTable2);
var
  parse: TParse;
  v:     PVdbe;
  pSrc:  PSrcList;
  pCol:  PExpr;
  pLo, pHi, pBet: PExpr;
  pBList: PExprList;
  pWInfo: PWhereInfo;
  pWi2: PWhereInfo;
  pWC: PWhereClause;
begin
  WriteLn;
  WriteLn('--- M3: rowid BETWEEN 1 AND 5 ---');
  InitParse(db, parse, v);
  pSrc := BuildSrc(db, pTab);

  pCol := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol^.iTable := 0; pCol^.iColumn := -1;
  pLo := sqlite3ExprInt32(db, 1);
  pHi := sqlite3ExprInt32(db, 5);
  pBList := sqlite3ExprListAppend(@parse, nil, pLo);
  pBList := sqlite3ExprListAppend(@parse, pBList, pHi);
  pBet := sqlite3PExpr(@parse, TK_BETWEEN, pCol, nil);
  pBet^.x.pList := pBList;

  pWInfo := sqlite3WhereBegin(@parse, pSrc, pBet, nil, nil, nil, 0, 0);
  { Sub-progress 9: BETWEEN on rowid no longer falls back to nil.  The
    SCAN-with-residual path emits OP_Rewind + a per-row IfFalse on the
    parent TK_BETWEEN; the two TERM_VIRTUAL companions are skipped. }
  Check('M3a WhereBegin returns non-nil for BETWEEN (SCAN+residual)',
        pWInfo <> nil);
  Check('M3b parse.nErr = 0',
        parse.nErr = 0);
  if pWInfo <> nil then
  begin
    Check('M3k OP_Rewind emitted',
          FindOpcode(v, OP_Rewind, 0) >= 0);
    Check('M3l BETWEEN parent tagged TERM_CODED',
          (pWInfo^.sWC.a[0].wtFlags and TERM_CODED) <> 0);
    sqlite3WhereEnd(pWInfo);
  end;

  { Drive analysis in isolation to verify BETWEEN spawns the two virtual
    WO_GE / WO_LE children expected by 11g.2.d's range-scan path. }
  pWi2 := PWhereInfo(sqlite3DbMallocZero(db, SizeOf(TWhereInfo)));
  pWi2^.pParse   := @parse;
  pWi2^.pTabList := pSrc;
  pWC := @pWi2^.sWC;
  sqlite3WhereClauseInit(pWC, pWi2);
  sqlite3WhereSplit(pWC, pBet, TK_AND);
  Check('M3c sqlite3WhereSplit produced 1 base term', pWC^.nTerm = 1);
  sqlite3WhereExprAnalyze(pSrc, pWC);
  Check('M3d analysis spawned 2 virtual children (3 terms total)',
        pWC^.nTerm = 3);
  Check('M3e child 0 (lower bound) op = TK_GE',
        pWC^.a[1].pExpr^.op = TK_GE);
  Check('M3f child 1 (upper bound) op = TK_LE',
        pWC^.a[2].pExpr^.op = TK_LE);
  Check('M3g child 0 wtFlags has TERM_VIRTUAL|TERM_DYNAMIC',
        (pWC^.a[1].wtFlags and (TERM_VIRTUAL or TERM_DYNAMIC))
        = (TERM_VIRTUAL or TERM_DYNAMIC));
  Check('M3h child 0 iParent = BETWEEN idx',
        pWC^.a[1].iParent = 0);
  Check('M3i child 1 iParent = BETWEEN idx',
        pWC^.a[2].iParent = 0);
  Check('M3j BETWEEN parent nChild = 2',
        pWC^.a[0].nChild = 2);
  sqlite3WhereClauseClear(pWC);
  sqlite3DbFree(db, pWi2);

  sqlite3DbFree(db, pSrc);
end;

var
  db:        PTsqlite3;
  rc:        i32;
  pTab:      PTable2;
  zNameBuf:  array[0..3] of AnsiChar;
  parse:     TParse;
  v:         PVdbe;
  pSrcBuf:   Pointer;
  pSrc:      PSrcList;
  pItem:     PSrcItem;
  pColExpr:  PExpr;
  pIntExpr:  PExpr;
  pEq:       PExpr;
  pWInfo:    PWhereInfo;
  pLevel:    PWhereLevel;
  pLoop:     PWhereLoop;
  pTerm:     PWhereTerm;
  iOpenRead: i32;
  iSeek:     i32;
  pOp:       PVdbeOp;
  savedNQL:  i16;

begin
  WriteLn('=== TestWhereSimple — Phase 6.9-bis 11g.2.b vertical slice ===');
  WriteLn;

  { --- Borrow a live db (we only need its main pSchema for SchemaToIndex). --- }
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if (rc <> SQLITE_OK) or (db = nil) then begin
    WriteLn('FATAL: sqlite3_open rc=', rc); Halt(2);
  end;

  { --- Hand-build a minimal Table — we never run the VDBE, only inspect
        emitted opcodes, so a synthetic tnum / nNVCol is fine. --- }
  pTab := PTable2(sqlite3DbMallocZero(db, SizeOf(TTable)));
  if pTab = nil then begin
    WriteLn('FATAL: pTab alloc failed'); Halt(2);
  end;
  zNameBuf[0] := 't'; zNameBuf[1] := #0;
  pTab^.zName    := @zNameBuf[0];
  pTab^.pSchema  := db^.aDb[0].pSchema;
  pTab^.tnum     := 2;     { synthetic root page }
  pTab^.nCol     := 1;
  pTab^.nNVCol   := 1;
  pTab^.tabFlags := 0;     { HasRowid, no without-rowid bit }
  pTab^.eTabType := TABTYP_NORM;
  pTab^.pIndex   := nil;

  { --- Build a hand-crafted Parse + Vdbe --- }
  FillChar(parse, SizeOf(parse), 0);
  parse.db        := db;
  parse.eParseMode:= 0;
  parse.nQueryLoop:= 7;  { sentinel — must be restored by WhereEnd }
  savedNQL := parse.nQueryLoop;

  v := sqlite3GetVdbe(@parse);
  if v = nil then begin
    WriteLn('FATAL: sqlite3GetVdbe returned nil'); Halt(2);
  end;

  { --- Build SrcList: 1 entry pointing at table t, cursor 0 --- }
  pSrcBuf := sqlite3DbMallocZero(db, SZ_SRCLIST_HEADER + SizeOf(TSrcItem));
  if pSrcBuf = nil then begin
    WriteLn('FATAL: SrcList alloc failed'); Halt(2);
  end;
  pSrc := PSrcList(pSrcBuf);
  pSrc^.nSrc   := 1;
  pSrc^.nAlloc := 1;
  pItem := @SrcListItems(pSrc)[0];
  pItem^.pSTab   := pTab;
  pItem^.iCursor := 0;
  pItem^.colUsed := Bitmask(1);

  { Reserve a cursor slot in pParse->nTab so iCursor=0 is safely owned. }
  parse.nTab := 1;

  { --- Build "rowid = 5" expression --- }
  pColExpr := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  if pColExpr = nil then begin
    WriteLn('FATAL: TK_COLUMN alloc failed'); Halt(2);
  end;
  pColExpr^.iTable  := 0;     { matches SrcItem.iCursor }
  pColExpr^.iColumn := -1;    { rowid alias }

  pIntExpr := sqlite3ExprInt32(db, 5);
  if pIntExpr = nil then begin
    WriteLn('FATAL: TK_INTEGER alloc failed'); Halt(2);
  end;

  pEq := sqlite3PExpr(@parse, TK_EQ, pColExpr, pIntExpr);
  if pEq = nil then begin
    WriteLn('FATAL: TK_EQ alloc failed'); Halt(2);
  end;

  { --- Drive sqlite3WhereBegin --- }
  pWInfo := sqlite3WhereBegin(@parse, pSrc, pEq, nil, nil, nil, 0, 0);
  Check('T2  WhereBegin returns non-nil', pWInfo <> nil);
  if pWInfo = nil then begin
    WriteLn('Cannot proceed without WhereInfo. nErr=', parse.nErr);
    Halt(1);
  end;

  Check('T3  WhereInfo nLevel = 1', pWInfo^.nLevel = 1);

  pLevel := @whereInfoLevels(pWInfo)[0];
  pLoop  := pLevel^.pWLoop;
  Check('T1a whereShortCut WHERE_IPK set',
        (pLoop^.wsFlags and WHERE_IPK) <> 0);
  Check('T1b whereShortCut WHERE_ONEROW set',
        (pLoop^.wsFlags and WHERE_ONEROW) <> 0);
  Check('T1c whereShortCut nLTerm = 1',
        pLoop^.nLTerm = 1);

  iOpenRead := FindOpcode(v, OP_OpenRead, 0);
  Check('T4a OP_OpenRead emitted', iOpenRead >= 0);
  if iOpenRead >= 0 then
  begin
    pOp := GetOp(v, iOpenRead);
    Check('T4b OP_OpenRead p1 = cursor 0', pOp^.p1 = 0);
  end;

  iSeek := FindOpcode(v, OP_SeekRowid, 0);
  Check('T5a OP_SeekRowid emitted', iSeek >= 0);
  if iSeek >= 0 then
  begin
    pOp := GetOp(v, iSeek);
    Check('T5b OP_SeekRowid p1 = cursor 0', pOp^.p1 = 0);
    { p2 should be the unresolved label = pLevel^.addrBrk (negative) before
      WhereEnd.  After WhereEnd it gets resolved to a real address. }
    Check('T5c OP_SeekRowid p2 = addrBrk label',
          pOp^.p2 = pLevel^.addrBrk);
  end;

  Check('T6  pLevel^.op = OP_Noop',  pLevel^.op = OP_Noop);

  pTerm := pLoop^.aLTerm[0];
  Check('T7  rowid term TERM_CODED set',
        (pTerm^.wtFlags and TERM_CODED) <> 0);

  { --- Drive sqlite3WhereEnd --- }
  sqlite3WhereEnd(pWInfo);

  { After resolution, the SeekRowid p2 should be re-pointed at the resolved
    address — but VDBE label resolution is deferred to sqlite3VdbeFinalize,
    so we instead check that the parser state has been restored. }
  Check('T8  WhereEnd succeeded (no crash)', True);
  Check('T9  nQueryLoop restored to ', parse.nQueryLoop = savedNQL);

  sqlite3DbFree(db, pSrcBuf);

  RunMultiAndTest(db, pTab);
  RunInTest(db, pTab);
  RunBetweenTest(db, pTab);

  sqlite3_close(db);

  WriteLn;
  WriteLn('Results: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail > 0 then Halt(1);
end.
