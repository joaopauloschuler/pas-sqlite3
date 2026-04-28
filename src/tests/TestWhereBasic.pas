{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  This is a faithful port of SQLite 3.53 (https://sqlite.org/) from C to
  Free Pascal, authored by Dr. Joao Paulo Schwarz Schuler and contributors
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
{$I passqlite3.inc}
program TestWhereBasic;
{
  Phase 6.2 gate test — whereInt.h / whereexpr.c: struct layout, constants,
  WhereClause management, WhereExprUsage bitmask helpers.

  All tests run without a live database connection.

    T1  SizeOf(TWhereMemBlock)   = 16
    T2  SizeOf(TWhereRightJoin)  = 20
    T3  SizeOf(TInLoop)          = 20
    T4  SizeOf(TWhereTerm)       = 56
    T5  SizeOf(TWhereClause)     = 488
    T6  SizeOf(TWhereOrInfo)     >= 496  (TWhereClause + Bitmask)
    T7  SizeOf(TWhereAndInfo)    = 488
    T8  SizeOf(TWhereMaskSet)    = 264
    T9  SizeOf(TWhereOrCost)     = 16
    T10 SizeOf(TWhereOrSet)      = 56
    T11 SizeOf(TWherePath)       = 32
    T12 SizeOf(TWhereScan)       = 112
    T13 SizeOf(TWhereLoopBtree)  = 24
    T14 SizeOf(TWhereLoopVtab)   = 24
    T15 SizeOf(TWhereLoop)       = 104
    T16 SizeOf(TWhereLevel)      = 120
    T17 SizeOf(TWhereLoopBuilder)= 40
    T18 WO_LT = $10, WO_LE = $08, WO_GT_WO = $04, WO_GE = $20
    T19 SZ_WHERETERM_STATIC = 8 (TWhereClause.aStatic array size)
    T20 WhereClauseInit zeroes fields correctly
    T21 WhereGetMask finds cursor in populated MaskSet
    T22 WhereGetMask returns 0 for unknown cursor
    T23 WhereExprUsage returns 0 for nil expr
    T24 WhereExprListUsage returns 0 for nil list
    T25 WhereSplit splits AND-expression into two terms
    T26 SizeOf(TColumn) = 16
    T27 SizeOf(TTable)  = 120
    T28 SizeOf(TIndex)  = 112
    T29 SizeOf(TKeyInfo)= 32
    T30 WHERE_COLUMN_EQ constant = 1
    T31 TF_WithoutRowid constant = $80
    T32 COLFLAG_PRIMKEY constant = 1
    T33 XN_ROWID = -1, XN_EXPR = -2
    T34 sqlite3WhereContinueLabel / BreakLabel return correct iContinue/iBreak
    T35 sqlite3WhereIsDistinct returns eDistinct field
    T36 sqlite3WhereIsOrdered returns nOBSat field
    T37 sqlite3WhereOkOnePass copies aiCurOnePass correctly
    T38 sqlite3WhereUsesDeferredSeek reads bit 0 of bitwiseFlags
    T39 sqlite3WhereOutputRowCount returns nRowOut field
    T40 SizeOf(TWhereInfo) base = 856 (before FlexArray)

  Gate: T1-T40 all PASS.
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
  passqlite3codegen;

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

{ Build a minimal TWhereInfo on the stack for accessor tests }
procedure FillWhereInfo(var wi: TWhereInfo);
begin
  FillChar(wi, SizeOf(TWhereInfo), 0);
  wi.iContinue        := 42;
  wi.iBreak           := 99;
  wi.eDistinct        := 2;
  wi.nOBSat           := 3;
  wi.nRowOut          := 100;
  wi.aiCurOnePass[0]  := 7;
  wi.aiCurOnePass[1]  := 8;
  wi.bitwiseFlags     := 1; { bit 0 = bDeferredSeek }
end;

var
  wi:      TWhereInfo;
  wc:      TWhereClause;
  ms:      TWhereMaskSet;
  curArr:  array[0..1] of i32;
  pExprA, pExprB, pExprAnd: PExpr;
  exprA, exprB, exprAnd: TExpr;

begin
  { --- T1-T17: struct sizes --- }
  Check('T1  SizeOf(TWhereMemBlock)=16',    SizeOf(TWhereMemBlock)    = 16);
  Check('T2  SizeOf(TWhereRightJoin)=20',   SizeOf(TWhereRightJoin)   = 20);
  Check('T3  SizeOf(TInLoop)=20',           SizeOf(TInLoop)           = 20);
  Check('T4  SizeOf(TWhereTerm)=56',        SizeOf(TWhereTerm)        = 56);
  Check('T5  SizeOf(TWhereClause)=488',     SizeOf(TWhereClause)      = 488);
  Check('T6  SizeOf(TWhereOrInfo)>=496',    SizeOf(TWhereOrInfo)      >= 496);
  Check('T7  SizeOf(TWhereAndInfo)=488',    SizeOf(TWhereAndInfo)     = 488);
  Check('T8  SizeOf(TWhereMaskSet)=264',    SizeOf(TWhereMaskSet)     = 264);
  Check('T9  SizeOf(TWhereOrCost)=16',      SizeOf(TWhereOrCost)      = 16);
  Check('T10 SizeOf(TWhereOrSet)=56',       SizeOf(TWhereOrSet)       = 56);
  Check('T11 SizeOf(TWherePath)=32',        SizeOf(TWherePath)        = 32);
  Check('T12 SizeOf(TWhereScan)=112',       SizeOf(TWhereScan)        = 112);
  Check('T13 SizeOf(TWhereLoopBtree)=24',   SizeOf(TWhereLoopBtree)   = 24);
  Check('T14 SizeOf(TWhereLoopVtab)=24',    SizeOf(TWhereLoopVtab)    = 24);
  Check('T15 SizeOf(TWhereLoop)=104',       SizeOf(TWhereLoop)        = 104);
  Check('T16 SizeOf(TWhereLevel)=120',      SizeOf(TWhereLevel)       = 120);
  Check('T17 SizeOf(TWhereLoopBuilder)=40', SizeOf(TWhereLoopBuilder) = 40);

  { --- T18: WO_* constant values --- }
  Check('T18a WO_LT=$10',    WO_LT    = $10);
  Check('T18b WO_LE=$08',    WO_LE    = $08);
  Check('T18c WO_GT_WO=$04', WO_GT_WO = $04);
  Check('T18d WO_GE=$20',    WO_GE    = $20);

  { --- T19: static slot count --- }
  Check('T19 SZ_WHERETERM_STATIC=8', SZ_WHERETERM_STATIC = 8);

  { --- T20: WhereClauseInit --- }
  FillChar(wi, SizeOf(TWhereInfo), 0);
  FillChar(wc, SizeOf(TWhereClause), $FF);  { poison }
  sqlite3WhereClauseInit(@wc, @wi);
  Check('T20a WhereClauseInit pWInfo',  wc.pWInfo  = @wi);
  Check('T20b WhereClauseInit hasOr=0', wc.hasOr   = 0);
  Check('T20c WhereClauseInit nTerm=0', wc.nTerm   = 0);
  Check('T20d WhereClauseInit nSlot=8', wc.nSlot   = SZ_WHERETERM_STATIC);
  Check('T20e WhereClauseInit a=aStatic', wc.a = @wc.aStatic[0]);

  { --- T21-T22: WhereGetMask --- }
  FillChar(ms, SizeOf(TWhereMaskSet), 0);
  ms.n    := 3;
  ms.ix[0]:= 5;
  ms.ix[1]:= 10;
  ms.ix[2]:= 17;
  Check('T21 WhereGetMask cursor 10 = bit 1', sqlite3WhereGetMask(@ms, 10) = Bitmask(2));
  Check('T22 WhereGetMask unknown cursor = 0', sqlite3WhereGetMask(@ms, 99) = 0);

  { --- T23-T24: WhereExprUsage with nil --- }
  Check('T23 WhereExprUsage nil expr = 0', sqlite3WhereExprUsage(@ms, nil) = 0);
  Check('T24 WhereExprListUsage nil list = 0', sqlite3WhereExprListUsage(@ms, nil) = 0);

  { --- T25: WhereSplit splits AND into 2 terms --- }
  FillChar(wi, SizeOf(TWhereInfo), 0);
  FillChar(wc, SizeOf(TWhereClause), 0);
  sqlite3WhereClauseInit(@wc, @wi);

  FillChar(exprA, SizeOf(TExpr), 0);
  FillChar(exprB, SizeOf(TExpr), 0);
  FillChar(exprAnd, SizeOf(TExpr), 0);
  pExprA   := @exprA;
  pExprB   := @exprB;
  pExprAnd := @exprAnd;

  exprA.op    := TK_INTEGER;
  exprB.op    := TK_INTEGER;
  exprAnd.op  := TK_AND;
  exprAnd.pLeft  := pExprA;
  exprAnd.pRight := pExprB;

  sqlite3WhereSplit(@wc, pExprAnd, TK_AND);
  Check('T25a WhereSplit: nTerm=2', wc.nTerm = 2);
  Check('T25b WhereSplit: term[0].pExpr=exprA', wc.a[0].pExpr = pExprA);
  Check('T25c WhereSplit: term[1].pExpr=exprB', wc.a[1].pExpr = pExprB);

  { --- T26-T29: Table/Index/Column/KeyInfo sizes --- }
  Check('T26 SizeOf(TColumn)=16',   SizeOf(TColumn)   = 16);
  Check('T27 SizeOf(TTable)=120',   SizeOf(TTable)    = 120);
  Check('T28 SizeOf(TIndex)=112',   SizeOf(TIndex)    = 112);
  Check('T29 SizeOf(TKeyInfo)=32',  SizeOf(TKeyInfo)  = 32);

  { --- T30-T33: selected constants --- }
  Check('T30 WHERE_COLUMN_EQ=1',    WHERE_COLUMN_EQ   = 1);
  Check('T31 TF_WithoutRowid=$80',  TF_WithoutRowid   = $80);
  Check('T32 COLFLAG_PRIMKEY=1',    COLFLAG_PRIMKEY   = 1);
  Check('T33a XN_ROWID=-1',         XN_ROWID          = -1);
  Check('T33b XN_EXPR=-2',          XN_EXPR           = -2);

  { --- T34-T40: WhereInfo accessor stubs --- }
  FillWhereInfo(wi);
  Check('T34a WhereContinueLabel=42', sqlite3WhereContinueLabel(@wi)  = 42);
  Check('T34b WhereBreakLabel=99',    sqlite3WhereBreakLabel(@wi)     = 99);
  Check('T35 WhereIsDistinct=2',      sqlite3WhereIsDistinct(@wi)     = 2);
  Check('T36 WhereIsOrdered=3',       sqlite3WhereIsOrdered(@wi)      = 3);

  curArr[0] := 0; curArr[1] := 0;
  sqlite3WhereOkOnePass(@wi, @curArr[0]);
  Check('T37a WhereOkOnePass cur[0]=7', curArr[0] = 7);
  Check('T37b WhereOkOnePass cur[1]=8', curArr[1] = 8);

  Check('T38 WhereUsesDeferredSeek=1', sqlite3WhereUsesDeferredSeek(@wi) = 1);
  Check('T39 WhereOutputRowCount=100', sqlite3WhereOutputRowCount(@wi)   = 100);
  Check('T40 SizeOf(TWhereInfo)=856',  SizeOf(TWhereInfo) = 856);

  WriteLn;
  WriteLn('Results: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail > 0 then Halt(1);
end.
