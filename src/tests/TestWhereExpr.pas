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

  sqlite3WhereClauseClear(pWC);
  sqlite3DbFree(db, pWInfo);
  sqlite3DbFree(db, pSrcBuf);
  sqlite3_close(db);

  WriteLn;
  WriteLn('Results: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail > 0 then Halt(1);
end.
