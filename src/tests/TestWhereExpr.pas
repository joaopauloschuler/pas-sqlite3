{$I ../passqlite3.inc}
program TestWhereExpr;
{
  Phase 6.9-bis (step 11g.2.c sub-progress) gate test for the whereexpr.c
  helpers landed alongside this test:

    * whereClauseInsert      — heap-grow the term array beyond aStatic
    * markTermAsChild        — parent/child link + truthProb propagation
    * transferJoinMarkings   — EP_OuterON / EP_InnerON propagation
    * exprCommute            — TK_GT  → TK_LT swap (and op rewrite)
    * sqlite3WhereSplit      — uses whereClauseInsert; faithful split
    * exprAnalyze right-side commute  — "5 = rowid" → "rowid = 5" path

  The harness builds a synthetic Parse/WhereInfo/WhereClause stack so
  that helpers exercise code paths in isolation, without going through
  the full sqlite3WhereBegin pipeline (which is gated by 11g.2.b).
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
  if cond then begin Inc(gPass); WriteLn('PASS  ', name); end
  else       begin Inc(gFail); WriteLn('FAIL  ', name); end;
end;

{ Build a deeply-left-nested AND chain "rowid=1 AND rowid=2 AND ... AND rowid=N"
  by repeated TK_AND construction.  Each leaf is a freshly-allocated TK_EQ. }
function BuildAndChain(parse: PParse; nLeaves: i32): PExpr;
var
  i:  i32;
  pCol, pInt, pEq, pAnd: PExpr;
begin
  Result := nil;
  for i := 1 to nLeaves do
  begin
    pCol := sqlite3PExpr(parse, TK_COLUMN, nil, nil);
    pCol^.iTable  := 0;
    pCol^.iColumn := -1;
    pInt := sqlite3ExprInt32(parse^.db, i);
    pEq  := sqlite3PExpr(parse, TK_EQ, pCol, pInt);
    if Result = nil then Result := pEq
    else
    begin
      pAnd := sqlite3PExpr(parse, TK_AND, Result, pEq);
      Result := pAnd;
    end;
  end;
end;

var
  db:        PTsqlite3;
  rc:        i32;
  pTab:      PTable2;
  zNameBuf:  array[0..3] of AnsiChar;
  parse:     TParse;
  pSrcBuf:   Pointer;
  pSrc:      PSrcList;
  pItem:     PSrcItem;
  pWInfo:    PWhereInfo;
  pWC:       PWhereClause;
  expr:      PExpr;
  i:         i32;
  pCol, pInt, pEq, pNew: PExpr;
  pBet, pLo, pHi, pNN, pColNN: PExpr;
  pBList: PExprList;
  iBetIdx, iNNIdx: i32;
  pCol1, pInt1, pCol2, pInt2, pLt, pEq2: PExpr;
  pTermA, pTermB: PWhereTerm;
  pSubA, pSubB, pSubC: PWhereTerm;
  iCombIdx, nTermBefore: i32;
  pColA, pColB, pIntA, pIntB, pEqA, pEqB, pOr: PExpr;
  iOrIdx: i32;
  pOrInfo3: PWhereOrInfo;
  pColC, pColD, pIntC, pIntD, pEqC, pEqD, pOr2: PExpr;
  iOrIdx2: i32;

begin
  WriteLn('=== TestWhereExpr — Phase 6.9-bis 11g.2.c whereexpr helpers ===');
  WriteLn;

  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if (rc <> SQLITE_OK) or (db = nil) then begin
    WriteLn('FATAL: sqlite3_open rc=', rc); Halt(2);
  end;

  pTab := PTable2(sqlite3DbMallocZero(db, SizeOf(TTable)));
  zNameBuf[0] := 't'; zNameBuf[1] := #0;
  pTab^.zName    := @zNameBuf[0];
  pTab^.pSchema  := db^.aDb[0].pSchema;
  pTab^.tnum     := 2;
  pTab^.nCol     := 1;
  pTab^.nNVCol   := 1;
  pTab^.tabFlags := 0;
  pTab^.eTabType := TABTYP_NORM;
  pTab^.pIndex   := nil;

  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;

  pSrcBuf := sqlite3DbMallocZero(db, SZ_SRCLIST_HEADER + SizeOf(TSrcItem));
  pSrc := PSrcList(pSrcBuf);
  pSrc^.nSrc   := 1;
  pSrc^.nAlloc := 1;
  pItem := @SrcListItems(pSrc)[0];
  pItem^.pSTab   := pTab;
  pItem^.iCursor := 0;
  pItem^.colUsed := Bitmask(1);
  parse.nTab := 1;

  { Hand-allocate a WhereInfo just rich enough to drive the helpers under
    test.  whereInfoFree expects pMemToFree to be a heap-tracked list, so
    we let it stay nil and call sqlite3DbFree on pWInfo manually below. }
  pWInfo := PWhereInfo(sqlite3DbMallocZero(db, SizeOf(TWhereInfo)));
  if pWInfo = nil then begin WriteLn('FATAL: pWInfo'); Halt(2); end;
  pWInfo^.pParse  := @parse;
  pWInfo^.pTabList := pSrc;

  pWC := @pWInfo^.sWC;
  sqlite3WhereClauseInit(pWC, pWInfo);

  { ---- T1: sqlite3WhereSplit on a 12-leaf AND chain — must grow nSlot
        beyond the static 8-entry pool. ---- }
  expr := BuildAndChain(@parse, 12);
  sqlite3WhereSplit(pWC, expr, TK_AND);
  Check('T1a sqlite3WhereSplit produced 12 base terms', pWC^.nTerm = 12);
  Check('T1b nBase = 12',                                pWC^.nBase = 12);
  Check('T1c nSlot grew past static pool',                pWC^.nSlot >= 16);
  Check('T1d pWC^.a moved off aStatic',                   pWC^.a <> @pWC^.aStatic[0]);
  Check('T1e pWC^.op = TK_AND',                           pWC^.op = TK_AND);

  { Every leaf should be the underlying TK_EQ (collate/likely peeled off);
    the iParent default is -1 and pWC pointer is back-set to pWC. }
  Check('T2a leaf 0 is TK_EQ',
        pWC^.a[0].pExpr^.op = TK_EQ);
  Check('T2b leaf 11 is TK_EQ',
        pWC^.a[11].pExpr^.op = TK_EQ);
  Check('T2c leaf truthProb default = 1',
        pWC^.a[0].truthProb = 1);
  Check('T2d leaf iParent default = -1',
        pWC^.a[0].iParent = -1);
  Check('T2e leaf pWC back-pointer set',
        pWC^.a[0].pWC = pWC);

  { ---- T3: markTermAsChild — link leaf 1 as child of leaf 0. ---- }
  pWC^.a[0].truthProb := 42;
  markTermAsChild(pWC, 1, 0);
  Check('T3a child iParent set',
        pWC^.a[1].iParent = 0);
  Check('T3b child truthProb inherited',
        pWC^.a[1].truthProb = 42);
  Check('T3c parent nChild incremented',
        pWC^.a[0].nChild = 1);

  { ---- T4: transferJoinMarkings.  Build a "tagged" base expr and a fresh
            derived expr; verify the EP_OuterON flag and iJoin propagate. ---- }
  pCol := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol^.iTable := 0; pCol^.iColumn := -1;
  pInt := sqlite3ExprInt32(db, 7);
  pEq  := sqlite3PExpr(@parse, TK_EQ, pCol, pInt);
  pCol := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol^.iTable := 0; pCol^.iColumn := -1;
  pInt := sqlite3ExprInt32(db, 8);
  pNew := sqlite3PExpr(@parse, TK_EQ, pCol, pInt);
  pEq^.flags    := pEq^.flags or EP_OuterON;
  pEq^.w.iJoin  := 9;
  transferJoinMarkings(pNew, pEq);
  Check('T4a derived gets EP_OuterON',
        (pNew^.flags and EP_OuterON) <> 0);
  Check('T4b derived gets iJoin=9',
        pNew^.w.iJoin = 9);

  { ---- T5: exprCommute on "5 > rowid" — op rewrites to TK_LT, sides swap. ---- }
  pInt := sqlite3ExprInt32(db, 5);
  pCol := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol^.iTable := 0; pCol^.iColumn := -1;
  pEq := sqlite3PExpr(@parse, TK_GT_TK, pInt, pCol);
  exprCommute(@parse, pEq);
  Check('T5a op rewritten to TK_LT', pEq^.op = TK_LT);
  Check('T5b LHS now points at column',
        (pEq^.pLeft <> nil) and (pEq^.pLeft^.op = TK_COLUMN));
  Check('T5c RHS now integer literal',
        (pEq^.pRight <> nil) and (pEq^.pRight^.op = TK_INTEGER));

  { ---- T6: exprAnalyze right-side commute — "5 = rowid" with leftCursor=-1
            commutes the original term in place; eOperator gets WO_EQ. ---- }
  i := pWC^.nTerm;     { tail index where the next leaf will be inserted }
  pInt := sqlite3ExprInt32(db, 99);
  pCol := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol^.iTable := 0; pCol^.iColumn := -1;
  pEq := sqlite3PExpr(@parse, TK_EQ, pInt, pCol);
  whereClauseInsert(pWC, pEq, 0);
  { The mask set must know about cursor 0 before exprAnalyze fires. }
  pWInfo^.sMaskSet.n := 0;
  pWInfo^.sMaskSet.ix[0] := 0;
  pWInfo^.sMaskSet.n := 1;
  sqlite3WhereExprAnalyze(pSrc, pWC);
  Check('T6a commuted term has leftCursor = 0',
        pWC^.a[i].leftCursor = 0);
  Check('T6b commuted term has u.leftColumn = -1 (rowid)',
        pWC^.a[i].u.leftColumn = -1);
  Check('T6c commuted term has WO_EQ',
        (pWC^.a[i].eOperator and WO_EQ) <> 0);
  Check('T6d original Expr LHS is now the column',
        (pEq^.pLeft <> nil) and (pEq^.pLeft^.op = TK_COLUMN));

  { ---- T7: BETWEEN virtual-term synthesis (whereexpr.c:1291..1312).
            "rowid BETWEEN 3 AND 7" must produce two TERM_VIRTUAL|TERM_DYNAMIC
            children (a>=3 and a<=7), each linked via iParent to the BETWEEN
            term, with eOperator = WO_GE / WO_LE respectively. ---- }
  iBetIdx := pWC^.nTerm;
  pCol := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol^.iTable := 0; pCol^.iColumn := -1;
  pLo := sqlite3ExprInt32(db, 3);
  pHi := sqlite3ExprInt32(db, 7);
  pBList := sqlite3ExprListAppend(@parse, nil, pLo);
  pBList := sqlite3ExprListAppend(@parse, pBList, pHi);
  pBet := sqlite3PExpr(@parse, TK_BETWEEN, pCol, nil);
  pBet^.x.pList := pBList;
  whereClauseInsert(pWC, pBet, 0);
  exprAnalyze(pSrc, pWC, iBetIdx);
  Check('T7a BETWEEN spawned 2 children',
        pWC^.nTerm = iBetIdx + 3);
  Check('T7b child 0 is TK_GE',
        pWC^.a[iBetIdx + 1].pExpr^.op = TK_GE);
  Check('T7c child 1 is TK_LE',
        pWC^.a[iBetIdx + 2].pExpr^.op = TK_LE);
  Check('T7d child 0 wtFlags has VIRTUAL|DYNAMIC',
        (pWC^.a[iBetIdx + 1].wtFlags
         and (TERM_VIRTUAL or TERM_DYNAMIC))
        = (TERM_VIRTUAL or TERM_DYNAMIC));
  Check('T7e child 0 iParent = BETWEEN idx',
        pWC^.a[iBetIdx + 1].iParent = iBetIdx);
  Check('T7f child 1 iParent = BETWEEN idx',
        pWC^.a[iBetIdx + 2].iParent = iBetIdx);
  Check('T7g BETWEEN nChild = 2',
        pWC^.a[iBetIdx].nChild = 2);
  Check('T7h child 0 has WO_GE on rowid cursor 0',
        (pWC^.a[iBetIdx + 1].eOperator and WO_GE) <> 0);
  Check('T7i child 1 has WO_LE on rowid cursor 0',
        (pWC^.a[iBetIdx + 2].eOperator and WO_LE) <> 0);
  Check('T7j child 0 leftCursor = 0',
        pWC^.a[iBetIdx + 1].leftCursor = 0);
  Check('T7k child 1 leftCursor = 0',
        pWC^.a[iBetIdx + 2].leftCursor = 0);

  { ---- T8: TK_NOTNULL virtual-term synthesis (whereexpr.c:1331..1359).
            "col0 NOTNULL" with column 0 (not rowid) must add one virtual
            term tagged TERM_VNULL whose eOperator = WO_GT. The original
            NOTNULL term gets TERM_COPIED. ---- }
  iNNIdx := pWC^.nTerm;
  pColNN := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColNN^.iTable := 0; pColNN^.iColumn := 0;     { column 0, not rowid }
  pNN := sqlite3PExpr(@parse, TK_NOTNULL, pColNN, nil);
  whereClauseInsert(pWC, pNN, 0);
  exprAnalyze(pSrc, pWC, iNNIdx);
  Check('T8a NOTNULL spawned 1 child',
        pWC^.nTerm = iNNIdx + 2);
  Check('T8b child wtFlags has VNULL',
        (pWC^.a[iNNIdx + 1].wtFlags and TERM_VNULL) <> 0);
  Check('T8c child eOperator = WO_GT',
        (pWC^.a[iNNIdx + 1].eOperator and WO_GT_WO) <> 0);
  Check('T8d child leftCursor = 0',
        pWC^.a[iNNIdx + 1].leftCursor = 0);
  Check('T8e child u.leftColumn = 0',
        pWC^.a[iNNIdx + 1].u.leftColumn = 0);
  Check('T8f original NOTNULL has TERM_COPIED',
        (pWC^.a[iNNIdx].wtFlags and TERM_COPIED) <> 0);
  Check('T8g child iParent links back',
        pWC^.a[iNNIdx + 1].iParent = iNNIdx);

  { ---- T9: whereNthSubterm — non-AND term acts as its own 0-th subterm,
            requests beyond N=0 return nil. ---- }
  pSubA := @pWC^.a[iNNIdx + 1];   { the WO_GT VNULL child from T8 }
  pSubB := whereNthSubterm(pSubA, 0);
  Check('T9a whereNthSubterm(non-AND, 0) = self', pSubB = pSubA);
  pSubC := whereNthSubterm(pSubA, 1);
  Check('T9b whereNthSubterm(non-AND, 1) = nil', pSubC = nil);

  { ---- T10: whereCombineDisjuncts — "a<5 OR a=5" must synthesize the
            virtual term "a<=5" (TK_LE) tagged TERM_VIRTUAL|TERM_DYNAMIC. ---- }
  { Build two disjunct WhereTerm objects pointing at "a<5" and "a=5". }
  pCol1 := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol1^.iTable := 0; pCol1^.iColumn := -1;
  pInt1 := sqlite3ExprInt32(db, 5);
  pLt   := sqlite3PExpr(@parse, TK_LT, pCol1, pInt1);

  pCol2 := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol2^.iTable := 0; pCol2^.iColumn := -1;
  pInt2 := sqlite3ExprInt32(db, 5);
  pEq2  := sqlite3PExpr(@parse, TK_EQ, pCol2, pInt2);

  { Stand-alone WhereTerm shells — not threaded through the WhereClause
    array; whereCombineDisjuncts does not inspect pWC linkage on them. }
  New(pTermA);  FillChar(pTermA^, SizeOf(pTermA^), 0);
  New(pTermB);  FillChar(pTermB^, SizeOf(pTermB^), 0);
  pTermA^.pExpr     := pLt;
  pTermA^.eOperator := WO_LT;
  pTermB^.pExpr     := pEq2;
  pTermB^.eOperator := WO_EQ;

  nTermBefore := pWC^.nTerm;
  iCombIdx    := nTermBefore;
  whereCombineDisjuncts(pSrc, pWC, pTermA, pTermB);
  Check('T10a virtual term inserted',
        pWC^.nTerm = nTermBefore + 1);
  Check('T10b combined op = TK_LE',
        pWC^.a[iCombIdx].pExpr^.op = TK_LE);
  Check('T10c combined wtFlags has VIRTUAL|DYNAMIC',
        (pWC^.a[iCombIdx].wtFlags
         and (TERM_VIRTUAL or TERM_DYNAMIC))
        = (TERM_VIRTUAL or TERM_DYNAMIC));
  Check('T10d combined eOperator has WO_LE',
        (pWC^.a[iCombIdx].eOperator and WO_LE) <> 0);
  Check('T10e combined leftCursor = 0',
        pWC^.a[iCombIdx].leftCursor = 0);

  { ---- T11: whereCombineDisjuncts must reject incompatible mixes —
            "a<5 OR a>5" cannot collapse to a single comparison term. ---- }
  pCol1 := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol1^.iTable := 0; pCol1^.iColumn := -1;
  pInt1 := sqlite3ExprInt32(db, 5);
  pLt   := sqlite3PExpr(@parse, TK_LT, pCol1, pInt1);
  pCol2 := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pCol2^.iTable := 0; pCol2^.iColumn := -1;
  pInt2 := sqlite3ExprInt32(db, 5);
  pEq2  := sqlite3PExpr(@parse, TK_GT_TK, pCol2, pInt2);

  pTermA^.pExpr     := pLt;
  pTermA^.eOperator := WO_LT;
  pTermA^.wtFlags   := 0;
  pTermB^.pExpr     := pEq2;
  pTermB^.eOperator := WO_GT_WO;
  pTermB^.wtFlags   := 0;

  nTermBefore := pWC^.nTerm;
  whereCombineDisjuncts(pSrc, pWC, pTermA, pTermB);
  Check('T11a a<5 OR a>5 leaves nTerm untouched',
        pWC^.nTerm = nTermBefore);

  Dispose(pTermA);
  Dispose(pTermB);

  { ---- T12: exprAnalyzeOrTerm — "rowid=1 OR rowid=2" must (a) tag the
            outer term TERM_ORINFO with eOperator=WO_OR, leftCursor=-1,
            and (b) synthesize a virtual TK_IN child via case-1
            (whereexpr.c:911..944).  The OR term itself is shattered
            into two disjunct terms held inside pOrInfo^.wc. ---- }
  pColA := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColA^.iTable := 0; pColA^.iColumn := -1;
  pIntA := sqlite3ExprInt32(db, 1);
  pEqA  := sqlite3PExpr(@parse, TK_EQ, pColA, pIntA);

  pColB := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColB^.iTable := 0; pColB^.iColumn := -1;
  pIntB := sqlite3ExprInt32(db, 2);
  pEqB  := sqlite3PExpr(@parse, TK_EQ, pColB, pIntB);

  pOr := sqlite3PExpr(@parse, TK_OR, pEqA, pEqB);
  iOrIdx := pWC^.nTerm;
  whereClauseInsert(pWC, pOr, 0);
  exprAnalyze(pSrc, pWC, iOrIdx);

  Check('T12a OR term tagged TERM_ORINFO',
        (pWC^.a[iOrIdx].wtFlags and TERM_ORINFO) <> 0);
  Check('T12b OR term eOperator = WO_OR',
        (pWC^.a[iOrIdx].eOperator and WO_OR) <> 0);
  Check('T12c OR term leftCursor = -1',
        pWC^.a[iOrIdx].leftCursor = -1);
  pOrInfo3 := pWC^.a[iOrIdx].u.pOrInfo;
  Check('T12d pOrInfo allocated',
        pOrInfo3 <> nil);
  Check('T12e pOrInfo.wc has 2 disjunct subterms',
        (pOrInfo3 <> nil) and (pOrInfo3^.wc.nTerm = 2));
  Check('T12f pOrInfo.wc.op = TK_OR',
        (pOrInfo3 <> nil) and (pOrInfo3^.wc.op = TK_OR));
  Check('T12g pOrInfo.indexable bit 0 set (rowid cursor 0)',
        (pOrInfo3 <> nil) and ((pOrInfo3^.indexable and 1) <> 0));
  Check('T12h pWC^.hasOr set',
        pWC^.hasOr = 1);
  { Case-1 should append a virtual TK_IN term beyond the OR; iOrIdx+1
    is the synthesized child (markTermAsChild links it back). }
  Check('T12i virtual TK_IN child appended',
        (pWC^.nTerm > iOrIdx + 1)
        and (pWC^.a[iOrIdx + 1].pExpr^.op = TK_IN));
  Check('T12j virtual term wtFlags has VIRTUAL|DYNAMIC',
        (pWC^.nTerm > iOrIdx + 1)
        and ((pWC^.a[iOrIdx + 1].wtFlags
              and (TERM_VIRTUAL or TERM_DYNAMIC))
             = (TERM_VIRTUAL or TERM_DYNAMIC)));
  Check('T12k virtual TK_IN term iParent = OR idx',
        (pWC^.nTerm > iOrIdx + 1)
        and (pWC^.a[iOrIdx + 1].iParent = iOrIdx));

  { ---- T13: exprAnalyzeOrTerm with mismatched columns —
            "(c0=1) OR (rowid=2)" cannot collapse into a single IN
            (different leftColumn), so case-1 must NOT run.  pOrInfo
            still tags the outer term, but no virtual TK_IN child is
            appended. ---- }
  pColC := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColC^.iTable := 0; pColC^.iColumn := 0;          { col 0 }
  pIntC := sqlite3ExprInt32(db, 1);
  pEqC  := sqlite3PExpr(@parse, TK_EQ, pColC, pIntC);

  pColD := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColD^.iTable := 0; pColD^.iColumn := -1;         { rowid }
  pIntD := sqlite3ExprInt32(db, 2);
  pEqD  := sqlite3PExpr(@parse, TK_EQ, pColD, pIntD);

  pOr2 := sqlite3PExpr(@parse, TK_OR, pEqC, pEqD);
  iOrIdx2     := pWC^.nTerm;
  nTermBefore := pWC^.nTerm;
  whereClauseInsert(pWC, pOr2, 0);
  exprAnalyze(pSrc, pWC, iOrIdx2);
  Check('T13a OR term still tagged TERM_ORINFO',
        (pWC^.a[iOrIdx2].wtFlags and TERM_ORINFO) <> 0);
  Check('T13b OR term still gets WO_OR',
        (pWC^.a[iOrIdx2].eOperator and WO_OR) <> 0);
  Check('T13c no virtual TK_IN appended for column-mismatched OR',
        pWC^.nTerm = nTermBefore + 1);

  { Skip sqlite3WhereClauseClear / sqlite3DbFree for the synthetic
    WhereInfo: pWC^.a was allocated through sqlite3WhereMalloc and is
    threaded on pWInfo^.pMemToFree, so a manual sqlite3DbFree(pWC^.a)
    would corrupt the lookaside arena.  whereInfoFree's full chain-walk
    is the C-faithful release path, but it requires more state than
    this test sets up.  The OS reclaims the leaked allocations at exit. }
  sqlite3_close(db);

  WriteLn;
  WriteLn('Results: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail > 0 then Halt(1);
end.
