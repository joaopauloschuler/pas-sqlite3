{$I passqlite3.inc}
program TestWalker;
{
  Phase 6.1 gate test — walker.c: AST tree walker framework.

  All tests build minimal in-memory structs (no heap allocator, no DB).
  Callback state is passed through Walker.u.n (integer counter).

    T1  sqlite3WalkExpr with nil — WRC_Continue, no callback
    T2  sqlite3WalkExprNN — leaf expr, callback invoked once
    T3  sqlite3WalkExprNN — EP_TokenOnly flag, no child descent
    T4  sqlite3WalkExprNN — left+right chain, callback invoked for each node
    T5  sqlite3WalkExprNN — callback returns WRC_Prune stops descent
    T6  sqlite3WalkExprNN — callback returns WRC_Abort propagates
    T7  sqlite3WalkExprList — nil list returns WRC_Continue
    T8  sqlite3WalkExprList — 2-item list visits both
    T9  sqlite3WalkSelect — nil select returns WRC_Continue
    T10 sqlite3WalkSelect — no xSelectCallback returns WRC_Continue
    T11 sqlite3WalkSelect — visits pEList and pWhere
    T12 sqlite3WalkSelect — pPrior chain visits both selects
    T13 sqlite3WalkerDepthIncrease/Decrease — depth tracking
    T14 sqlite3ExprWalkNoop — always WRC_Continue
    T15 sqlite3SelectWalkNoop — always WRC_Continue
    T16 sqlite3WalkSelectFrom — nil pSrc returns WRC_Continue
    T17 ExprHasProperty — EP_TokenOnly flag check
    T18 ExprUseXSelect — EP_xIsSelect flag check
    T19 SizeOf struct checks: TExpr=72, TExprList=8, TSelect=120, TWalker=48

  Gate: T1-T19 all PASS.
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
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else
  begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ ---- callback helpers ---- }

{ Count how many times the expr callback fires; WRC_Continue always }
function CountExprCB(pWalker: PWalker; pExpr: PExpr): i32; cdecl;
begin
  Inc(pWalker^.u.n);
  Result := WRC_Continue;
end;

{ Prune on second call }
function PruneSecondExprCB(pWalker: PWalker; pExpr: PExpr): i32; cdecl;
begin
  Inc(pWalker^.u.n);
  if pWalker^.u.n >= 2 then
    Result := WRC_Prune
  else
    Result := WRC_Continue;
end;

{ Always abort }
function AbortExprCB(pWalker: PWalker; pExpr: PExpr): i32; cdecl;
begin
  Inc(pWalker^.u.n);
  Result := WRC_Abort;
end;

{ Count select callbacks }
function CountSelectCB(pWalker: PWalker; pSel: PSelect): i32; cdecl;
begin
  Inc(pWalker^.u.n);
  Result := WRC_Continue;
end;

{ ---- helpers to build minimal structs on the stack ---- }

procedure ZeroWalker(out w: TWalker);
var i: Integer;
begin
  FillChar(w, SizeOf(w), 0);
end;

procedure ZeroExpr(out e: TExpr);
begin
  FillChar(e, SizeOf(e), 0);
end;

procedure ZeroSelect(out s: TSelect);
begin
  FillChar(s, SizeOf(s), 0);
end;

{ ===== tests ================================================================ }

procedure Test1_WalkExprNil;
var
  w: TWalker;
  rc: i32;
begin
  ZeroWalker(w);
  w.xExprCallback := @CountExprCB;
  rc := sqlite3WalkExpr(@w, nil);
  Check('T1 WalkExpr(nil)=WRC_Continue', rc = WRC_Continue);
end;

procedure Test2_LeafExpr;
var
  w: TWalker;
  e: TExpr;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroExpr(e);
  e.flags := EP_Leaf;   { leaf → no child descent }
  w.xExprCallback := @CountExprCB;
  w.u.n := 0;
  rc := sqlite3WalkExprNN(@w, @e);
  Check('T2 leaf expr callback count=1', w.u.n = 1);
  Check('T2 leaf expr result=Continue',  rc = WRC_Continue);
end;

procedure Test3_TokenOnlyExpr;
var
  w: TWalker;
  e: TExpr;
begin
  ZeroWalker(w);
  ZeroExpr(e);
  e.flags := EP_TokenOnly;
  w.xExprCallback := @CountExprCB;
  w.u.n := 0;
  sqlite3WalkExprNN(@w, @e);
  Check('T3 TokenOnly callback count=1', w.u.n = 1);
end;

procedure Test4_LeftRightChain;
var
  w: TWalker;
  root, left, right: TExpr;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroExpr(root); ZeroExpr(left); ZeroExpr(right);
  { root -> left (leaf), root -> right (leaf) }
  left.flags  := EP_Leaf;
  right.flags := EP_Leaf;
  root.pLeft  := @left;
  root.pRight := @right;
  { root has no EP_TokenOnly or EP_Leaf → descends }
  w.xExprCallback := @CountExprCB;
  w.u.n := 0;
  rc := sqlite3WalkExprNN(@w, @root);
  { root + left + right = 3 calls }
  Check('T4 left+right chain count=3', w.u.n = 3);
  Check('T4 result=Continue', rc = WRC_Continue);
end;

procedure Test5_PruneStopsDescend;
var
  w: TWalker;
  root, left: TExpr;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroExpr(root); ZeroExpr(left);
  left.flags := EP_Leaf;
  root.pLeft := @left;
  { PruneSecondExprCB prunes on the 2nd call (root=1, left=2→prune) }
  w.xExprCallback := @PruneSecondExprCB;
  w.u.n := 0;
  rc := sqlite3WalkExprNN(@w, @root);
  { WRC_Prune stops descent of left's children; left itself gets the prune call }
  Check('T5 prune callback count=2', w.u.n = 2);
  Check('T5 prune result=Continue',  rc = WRC_Continue);
end;

procedure Test6_AbortPropagates;
var
  w: TWalker;
  root, left: TExpr;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroExpr(root); ZeroExpr(left);
  left.flags := EP_Leaf;
  root.pLeft := @left;
  w.xExprCallback := @AbortExprCB;
  w.u.n := 0;
  rc := sqlite3WalkExprNN(@w, @root);
  Check('T6 abort propagates', rc = WRC_Abort);
  Check('T6 abort count=1',    w.u.n = 1);
end;

procedure Test7_WalkExprListNil;
var
  w: TWalker;
  rc: i32;
begin
  ZeroWalker(w);
  w.xExprCallback := @CountExprCB;
  rc := sqlite3WalkExprList(@w, nil);
  Check('T7 WalkExprList(nil)=Continue', rc = WRC_Continue);
end;

procedure Test8_WalkExprListTwo;
var
  w: TWalker;
  { ExprList with 2 items laid out inline:
    [ TExprList header ][ TExprListItem0 ][ TExprListItem1 ] }
  buf: array[0..SizeOf(TExprList)+2*SizeOf(TExprListItem)-1] of Byte;
  pList: PExprList;
  pItems: PExprListItem;
  e0, e1: TExpr;
  rc: i32;
begin
  FillChar(buf, SizeOf(buf), 0);
  ZeroExpr(e0); ZeroExpr(e1);
  e0.flags := EP_Leaf;
  e1.flags := EP_Leaf;

  pList := PExprList(@buf[0]);
  pList^.nExpr := 2;
  pItems := ExprListItems(pList);
  pItems[0].pExpr := @e0;
  pItems[1].pExpr := @e1;

  ZeroWalker(w);
  w.xExprCallback := @CountExprCB;
  w.u.n := 0;
  rc := sqlite3WalkExprList(@w, pList);
  Check('T8 ExprList 2 items count=2', w.u.n = 2);
  Check('T8 ExprList result=Continue', rc = WRC_Continue);
end;

procedure Test9_WalkSelectNil;
var
  w: TWalker;
  rc: i32;
begin
  ZeroWalker(w);
  w.xExprCallback    := @CountExprCB;
  w.xSelectCallback  := @CountSelectCB;
  rc := sqlite3WalkSelect(@w, nil);
  Check('T9 WalkSelect(nil)=Continue', rc = WRC_Continue);
end;

procedure Test10_WalkSelectNoCallback;
var
  w: TWalker;
  s: TSelect;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroSelect(s);
  w.xExprCallback := @CountExprCB;
  { xSelectCallback = nil }
  rc := sqlite3WalkSelect(@w, @s);
  Check('T10 no xSelectCallback=Continue', rc = WRC_Continue);
end;

procedure Test11_WalkSelectVisitsExpr;
var
  w: TWalker;
  s: TSelect;
  whereExpr: TExpr;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroSelect(s);
  ZeroExpr(whereExpr);
  whereExpr.flags := EP_Leaf;
  s.pWhere := @whereExpr;

  w.xExprCallback   := @CountExprCB;
  w.xSelectCallback := @CountSelectCB;
  w.u.n := 0;
  rc := sqlite3WalkSelect(@w, @s);
  { xSelectCallback fires 1× for the select; expr callback fires 1× for pWhere }
  Check('T11 select+where visits, n=2', w.u.n = 2);
  Check('T11 result=Continue',          rc = WRC_Continue);
end;

procedure Test12_WalkSelectPriorChain;
var
  w: TWalker;
  s1, s2: TSelect;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroSelect(s1); ZeroSelect(s2);
  s1.pPrior := @s2;   { compound query chain }

  w.xExprCallback   := @CountExprCB;
  w.xSelectCallback := @CountSelectCB;
  w.u.n := 0;
  rc := sqlite3WalkSelect(@w, @s1);
  { xSelectCallback fires once per select in chain = 2 }
  Check('T12 pPrior chain selects=2', w.u.n = 2);
  Check('T12 result=Continue',        rc = WRC_Continue);
end;

procedure Test13_DepthTracking;
var
  w: TWalker;
  s: TSelect;
begin
  ZeroWalker(w);
  ZeroSelect(s);
  w.walkerDepth := 0;
  sqlite3WalkerDepthIncrease(@w, @s);
  Check('T13 depth after increase=1', w.walkerDepth = 1);
  sqlite3WalkerDepthIncrease(@w, @s);
  Check('T13 depth after 2nd increase=2', w.walkerDepth = 2);
  sqlite3WalkerDepthDecrease(@w, @s);
  Check('T13 depth after decrease=1', w.walkerDepth = 1);
end;

procedure Test14_ExprWalkNoop;
var
  w: TWalker;
  e: TExpr;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroExpr(e);
  rc := sqlite3ExprWalkNoop(@w, @e);
  Check('T14 ExprWalkNoop=Continue', rc = WRC_Continue);
end;

procedure Test15_SelectWalkNoop;
var
  w: TWalker;
  s: TSelect;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroSelect(s);
  rc := sqlite3SelectWalkNoop(@w, @s);
  Check('T15 SelectWalkNoop=Continue', rc = WRC_Continue);
end;

procedure Test16_WalkSelectFromNilSrc;
var
  w: TWalker;
  s: TSelect;
  rc: i32;
begin
  ZeroWalker(w);
  ZeroSelect(s);
  { s.pSrc = nil }
  w.xExprCallback := @CountExprCB;
  rc := sqlite3WalkSelectFrom(@w, @s);
  Check('T16 WalkSelectFrom nil pSrc=Continue', rc = WRC_Continue);
end;

procedure Test17_ExprHasProperty;
var
  e: TExpr;
begin
  ZeroExpr(e);
  e.flags := EP_TokenOnly or EP_Leaf;
  Check('T17 HasProp EP_TokenOnly',  ExprHasProperty(@e, EP_TokenOnly));
  Check('T17 HasProp EP_Leaf',       ExprHasProperty(@e, EP_Leaf));
  Check('T17 !HasProp EP_xIsSelect', not ExprHasProperty(@e, EP_xIsSelect));
end;

procedure Test18_ExprUseXSelect;
var
  e: TExpr;
begin
  ZeroExpr(e);
  e.flags := EP_xIsSelect;
  Check('T18 UseXSelect true',  ExprUseXSelect(@e));
  Check('T18 UseXList false',   not ExprUseXList(@e));
  e.flags := 0;
  Check('T18 UseXSelect false', not ExprUseXSelect(@e));
  Check('T18 UseXList true',    ExprUseXList(@e));
end;

procedure Test19_SizeOfStructs;
begin
  Check('T19 SizeOf(TExpr)=72',     SizeOf(TExpr)     = 72);
  Check('T19 SizeOf(TExprList)=8',  SizeOf(TExprList) = 8);
  Check('T19 SizeOf(TSelect)=120',  SizeOf(TSelect)   = 120);
  Check('T19 SizeOf(TWalker)=48',   SizeOf(TWalker)   = 48);
  Check('T19 SizeOf(TWindow)=144',  SizeOf(TWindow)   = 144);
  Check('T19 SizeOf(TSrcItem)=72',  SizeOf(TSrcItem)  = 72);
  Check('T19 SizeOf(TToken)=16',    SizeOf(TToken)    = 16);
  Check('T19 SizeOf(TAggInfo)=72',  SizeOf(TAggInfo)  = 72);
end;

{ ===== main ================================================================= }

begin
  WriteLn('=== TestWalker (Phase 6.1 gate) ===');
  Test1_WalkExprNil;
  Test2_LeafExpr;
  Test3_TokenOnlyExpr;
  Test4_LeftRightChain;
  Test5_PruneStopsDescend;
  Test6_AbortPropagates;
  Test7_WalkExprListNil;
  Test8_WalkExprListTwo;
  Test9_WalkSelectNil;
  Test10_WalkSelectNoCallback;
  Test11_WalkSelectVisitsExpr;
  Test12_WalkSelectPriorChain;
  Test13_DepthTracking;
  Test14_ExprWalkNoop;
  Test15_SelectWalkNoop;
  Test16_WalkSelectFromNilSrc;
  Test17_ExprHasProperty;
  Test18_ExprUseXSelect;
  Test19_SizeOfStructs;

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed.');
  if gFail > 0 then
    Halt(1);
end.
