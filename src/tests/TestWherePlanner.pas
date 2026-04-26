{$I ../passqlite3.inc}
program TestWherePlanner;
{
  Phase 6.9-bis (step 11g.2.d sub-progress) gate test for the planner-core
  leaf helpers landed alongside this test:

    * whereOrMove                  — where.c:196..199
    * whereOrInsert                — where.c:208..239
    * whereLoopCheaperProperSubset — where.c:2657..2687
    * whereLoopAdjustCost          — where.c:2703..2728
    * whereLoopFindLesser          — where.c:2744..2806
    * whereLoopInsert              — where.c:2832..2938

  Tests build TWhereLoop / TWhereOrSet stacks directly; nothing here goes
  through sqlite3WhereBegin.  Together these helpers are the bookkeeping
  underneath whereLoopAddBtree / whereLoopAddOr / whereLoopAddAll, which
  land in subsequent 11g.2.d sub-progress.
}

uses
  SysUtils,
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

{ ----- whereOrMove + whereOrInsert ----- }

procedure TestOrSet;
var
  src, dst: TWhereOrSet;
  rc: i32;
begin
  FillChar(src, SizeOf(src), 0);
  FillChar(dst, SizeOf(dst), 0);

  { Empty whereOrInsert: appends entry. }
  rc := whereOrInsert(@src, $0001, 30, 10);
  Check('OR1 first insert returns 1',         rc = 1);
  Check('OR1 n=1',                            src.n = 1);
  Check('OR1 a[0].prereq=1',                  src.a[0].prereq = $0001);
  Check('OR1 a[0].rRun=30',                   src.a[0].rRun = 30);
  Check('OR1 a[0].nOut=10',                   src.a[0].nOut = 10);

  { Same prereq, lower rRun → overwrites in place (rRun<=p->rRun + prereq subset). }
  rc := whereOrInsert(@src, $0001, 25, 12);
  Check('OR2 dominating insert returns 1',    rc = 1);
  Check('OR2 still n=1',                      src.n = 1);
  Check('OR2 rRun updated',                   src.a[0].rRun = 25);
  Check('OR2 nOut min',                       src.a[0].nOut = 10); { min(10,12)=10 }

  { Subsumed candidate (existing dominates) → return 0, no insert. }
  rc := whereOrInsert(@src, $0003, 30, 14);
  Check('OR3 subsumed returns 0',             rc = 0);
  Check('OR3 still n=1',                      src.n = 1);

  { Different prereq, different cost → appended. }
  rc := whereOrInsert(@src, $0002, 28, 11);
  Check('OR4 distinct insert returns 1',      rc = 1);
  Check('OR4 n=2',                            src.n = 2);

  { Push past N_OR_COST=3 → fills up. }
  rc := whereOrInsert(@src, $0004, 26, 9);
  Check('OR5 third distinct insert returns 1', rc = 1);
  Check('OR5 n=3',                             src.n = 3);

  { Now full (n=N_OR_COST).  A cheaper-than-worst entry should evict. }
  rc := whereOrInsert(@src, $0008, 20, 7);
  Check('OR6 eviction returns 1',              rc = 1);
  Check('OR6 still n=3',                       src.n = 3);

  { whereOrMove copy. }
  whereOrMove(@dst, @src);
  Check('OR7 move n',                         dst.n = src.n);
  Check('OR7 move slot0 prereq',              dst.a[0].prereq = src.a[0].prereq);
  Check('OR7 move slot1 rRun',                dst.a[1].rRun   = src.a[1].rRun);
  Check('OR7 move slot2 nOut',                dst.a[2].nOut   = src.a[2].nOut);
end;

{ ----- whereLoopCheaperProperSubset ----- }

procedure InitLoopBare(p: PWhereLoop);
begin
  FillChar(p^, SizeOf(TWhereLoop), 0);
  whereLoopInit(p);
end;

procedure TestCheaperProperSubset;
var
  pX, pY: TWhereLoop;
  tX1, tX2, tY1, tY2, tY3: TWhereTerm;
begin
  FillChar(tX1, SizeOf(tX1), 0); FillChar(tX2, SizeOf(tX2), 0);
  FillChar(tY1, SizeOf(tY1), 0); FillChar(tY2, SizeOf(tY2), 0);
  FillChar(tY3, SizeOf(tY3), 0);

  { Case 2: X is proper subset of Y, X cheaper → returns 1.
    X uses {tX1, tX2}, Y uses {tX1, tX2, tY3}. }
  InitLoopBare(@pX);
  InitLoopBare(@pY);
  pX.iTab := 1; pY.iTab := 1;
  pX.rRun := 30; pX.nOut := 10;
  pY.rRun := 40; pY.nOut := 20;
  pX.aLTerm[0] := @tX1; pX.aLTerm[1] := @tX2; pX.nLTerm := 2;
  pY.aLTerm[0] := @tX1; pY.aLTerm[1] := @tX2; pY.aLTerm[2] := @tY3;
  pY.nLTerm := 3;
  Check('CPS1 case2 X subset of Y',          whereLoopCheaperProperSubset(@pX, @pY) = 1);

  { Reverse direction — Y is not a proper subset of X. }
  Check('CPS2 not(Y subset of X)',           whereLoopCheaperProperSubset(@pY, @pX) = 0);

  { Cost guard (1d)/(2a): X both costlier than Y → return 0. }
  pX.rRun := 50; pX.nOut := 30;
  Check('CPS3 cost guard',                   whereLoopCheaperProperSubset(@pX, @pY) = 0);

  { Same nLTerm → not proper subset. }
  pX.rRun := 30; pX.nOut := 10;
  pY.nLTerm := 2;
  Check('CPS4 same nLTerm not subset',       whereLoopCheaperProperSubset(@pX, @pY) = 0);

  { (2c) miss — X has term Y does not. }
  pY.aLTerm[0] := @tY1; pY.aLTerm[1] := @tY2; pY.nLTerm := 3;
  pY.aLTerm[2] := @tY3;
  Check('CPS5 (2c) term mismatch',           whereLoopCheaperProperSubset(@pX, @pY) = 0);
end;

{ ----- whereLoopFindLesser + whereLoopInsert ----- }

procedure TestFindLesser;
var
  pHead: PWhereLoop;
  loop1: TWhereLoop;
  template: TWhereLoop;
  ppRet: PPWhereLoop;
begin
  pHead := nil;
  InitLoopBare(@loop1);
  loop1.iTab := 2; loop1.iSortIdx := 0;
  loop1.prereq := $0001;
  loop1.rRun := 20; loop1.nOut := 5;
  pHead := @loop1;

  { Empty/Append: a template that is unrelated finds the tail link slot. }
  InitLoopBare(@template);
  template.iTab := 9; template.iSortIdx := 0;
  template.prereq := $0010; template.rRun := 30; template.nOut := 8;
  ppRet := whereLoopFindLesser(@pHead, @template);
  Check('FL1 unrelated → tail slot',         (ppRet <> nil) and (ppRet^ = nil));

  { Discard: existing has fewer prereqs and lower cost. }
  template.iTab := 2; template.prereq := $0003; template.rRun := 30; template.nOut := 10;
  ppRet := whereLoopFindLesser(@pHead, @template);
  Check('FL2 discard',                       ppRet = nil);

  { Replace candidate: template better → returns slot pointing at loop1. }
  template.prereq := $0001; template.rRun := 10; template.nOut := 4;
  ppRet := whereLoopFindLesser(@pHead, @template);
  Check('FL3 replace slot points at loop1',  (ppRet <> nil) and (ppRet^ = @loop1));
end;

procedure TestInsert;
var
  db:       PTsqlite3;
  rc:       i32;
  parse:    TParse;
  wInfoBuf: array[0..1023] of u8;
  pWInfo:   PWhereInfo;
  bld:      TWhereLoopBuilder;
  template: TWhereLoop;
  pLoops:   PWhereLoop;
  count:    i32;
  p:        PWhereLoop;
  orset:    TWhereOrSet;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('INS open',                          rc = SQLITE_OK);

  FillChar(parse,    SizeOf(parse),    0);
  parse.db := db;

  FillChar(wInfoBuf, SizeOf(wInfoBuf), 0);
  pWInfo := PWhereInfo(@wInfoBuf[0]);
  pWInfo^.pParse := @parse;

  FillChar(bld, SizeOf(bld), 0);
  bld.pWInfo := pWInfo;
  bld.iPlanLimit := 100;

  FillChar(template, SizeOf(template), 0);
  whereLoopInit(@template);
  template.iTab := 1; template.iSortIdx := 0;
  template.prereq := $0001;
  template.rRun := 25; template.nOut := 10;
  template.wsFlags := 0;

  rc := whereLoopInsert(@bld, @template);
  Check('INS1 first insert OK',              rc = SQLITE_OK);
  Check('INS1 list has one loop',            (pWInfo^.pLoops <> nil)
                                             and (pWInfo^.pLoops^.pNextLoop = nil));
  Check('INS1 iPlanLimit decremented',       bld.iPlanLimit = 99);
  Check('INS1 entry rRun',                   pWInfo^.pLoops^.rRun = 25);

  { Identical-iTab worse template → discarded; list still has 1. }
  template.rRun := 50; template.nOut := 20;
  rc := whereLoopInsert(@bld, @template);
  Check('INS2 worse discarded OK',           rc = SQLITE_OK);
  count := 0; p := pWInfo^.pLoops;
  while p <> nil do begin Inc(count); p := p^.pNextLoop; end;
  Check('INS2 list still 1 entry',           count = 1);

  { Better template → overwrites slot. }
  template.rRun := 10; template.nOut := 5;
  rc := whereLoopInsert(@bld, @template);
  Check('INS3 better overwrites OK',         rc = SQLITE_OK);
  count := 0; p := pWInfo^.pLoops;
  while p <> nil do begin Inc(count); p := p^.pNextLoop; end;
  Check('INS3 list still 1 entry',           count = 1);
  Check('INS3 entry rRun=10',                pWInfo^.pLoops^.rRun = 10);

  { Distinct iTab → appended. }
  template.iTab := 2; template.prereq := $0002;
  template.rRun := 18; template.nOut := 7;
  rc := whereLoopInsert(@bld, @template);
  Check('INS4 distinct iTab inserts OK',     rc = SQLITE_OK);
  count := 0; p := pWInfo^.pLoops;
  while p <> nil do begin Inc(count); p := p^.pNextLoop; end;
  Check('INS4 list grew to 2',               count = 2);

  { OrSet path: when pOrSet != nil, only OR-set updated; pLoops untouched. }
  FillChar(orset, SizeOf(orset), 0);
  bld.pOrSet := @orset;
  template.iTab := 3; template.prereq := $0004;
  template.rRun := 22; template.nOut := 8;
  template.nLTerm := 1; { needed for whereOrInsert call }
  rc := whereLoopInsert(@bld, @template);
  Check('INS5 OrSet path OK',              rc = SQLITE_OK);
  Check('INS5 OrSet recorded',             orset.n = 1);
  Check('INS5 OrSet prereq',               orset.a[0].prereq = $0004);
  bld.pOrSet := nil;

  { Plan-limit exhaustion: setting limit to 0 yields SQLITE_DONE. }
  bld.iPlanLimit := 0;
  rc := whereLoopInsert(@bld, @template);
  Check('INS6 plan-limit DONE',              rc = SQLITE_DONE);

  { Cleanup: walk pLoops and delete each. }
  pLoops := pWInfo^.pLoops;
  while pLoops <> nil do
  begin
    p := pLoops; pLoops := p^.pNextLoop;
    whereLoopDelete(db, p);
  end;
  pWInfo^.pLoops := nil;

  sqlite3_close(db);
end;

{ ----- whereLoopAdjustCost ----- }

procedure TestAdjustCost;
var
  p, tpl: TWhereLoop;
  t1, t2, t3: TWhereTerm;
  oldRRun, oldNOut: LogEst;
begin
  FillChar(t1, SizeOf(t1), 0); FillChar(t2, SizeOf(t2), 0); FillChar(t3, SizeOf(t3), 0);

  { template not WHERE_INDEXED → no-op. }
  InitLoopBare(@p); InitLoopBare(@tpl);
  tpl.wsFlags := 0;
  tpl.rRun := 50; tpl.nOut := 20;
  oldRRun := tpl.rRun; oldNOut := tpl.nOut;
  whereLoopAdjustCost(@p, @tpl);
  Check('ADJ1 not-indexed unchanged',        (tpl.rRun = oldRRun) and (tpl.nOut = oldNOut));

  { p is proper subset of tpl, p cheaper → tpl rRun & nOut adjusted DOWN. }
  InitLoopBare(@p); InitLoopBare(@tpl);
  p.iTab := 1; tpl.iTab := 1;
  p.wsFlags := WHERE_INDEXED; tpl.wsFlags := WHERE_INDEXED;
  p.rRun := 20; p.nOut := 5;
  tpl.rRun := 50; tpl.nOut := 20;
  p.aLTerm[0] := @t1; p.nLTerm := 1;
  tpl.aLTerm[0] := @t1; tpl.aLTerm[1] := @t2; tpl.nLTerm := 2;
  p.pNextLoop := nil;
  whereLoopAdjustCost(@p, @tpl);
  Check('ADJ2 tpl rRun adjusted down',       tpl.rRun = 20);
  Check('ADJ2 tpl nOut adjusted down',       tpl.nOut <= 4);
end;

{ ----- estLog (where.c:700) ----- }

procedure TestEstLog;
begin
  Check('EL1 estLog(0)=0',          estLog(0) = 0);
  Check('EL2 estLog(10)=0',         estLog(10) = 0);
  Check('EL3 estLog(11)>0',         estLog(11) > 0);
  Check('EL4 estLog(100) sane',     estLog(100) >= 30);  { LogEst(100)-33 ≈ 33 }
end;

{ ----- sqlite3ExprIsLikeOperator + estLikePatternLength
        (whereexpr.c:353, where.c:2988) ----- }

procedure TestExprIsLikeOperator;
var
  e:        TExpr;
  zLike:    array[0..7] of AnsiChar;
  zGlob:    array[0..7] of AnsiChar;
  zMatch:   array[0..7] of AnsiChar;
  zRegexp:  array[0..7] of AnsiChar;
  zFoo:     array[0..7] of AnsiChar;
begin
  StrCopy(zLike,   'like');
  StrCopy(zGlob,   'GLOB');     { case-insensitive }
  StrCopy(zMatch,  'match');
  StrCopy(zRegexp, 'regexp');
  StrCopy(zFoo,    'foo');

  FillChar(e, SizeOf(e), 0);
  e.op    := TK_FUNCTION;
  e.flags := 0;     { no EP_IntValue }
  e.u.zToken := zLike;
  Check('LO1 like  → 65', sqlite3ExprIsLikeOperator(@e) = 65);

  e.u.zToken := zGlob;
  Check('LO2 GLOB  → 66', sqlite3ExprIsLikeOperator(@e) = 66);

  e.u.zToken := zMatch;
  Check('LO3 match → 64', sqlite3ExprIsLikeOperator(@e) = 64);

  e.u.zToken := zRegexp;
  Check('LO4 regexp → 67', sqlite3ExprIsLikeOperator(@e) = 67);

  e.u.zToken := zFoo;
  Check('LO5 other → 0',  sqlite3ExprIsLikeOperator(@e) = 0);
end;

procedure TestEstLikePatternLength;
var
  e:        TExpr;
  zPlain:   array[0..15] of AnsiChar;
  zLikePat: array[0..15] of AnsiChar;
  zGlobPat: array[0..15] of AnsiChar;
  zClass:   array[0..15] of AnsiChar;
begin
  StrCopy(zPlain,   'hello');         { 5 literal chars, no wildcards }
  StrCopy(zLikePat, 'ab_cd%');        { LIKE: 'ab','cd' = 4 literal chars }
  StrCopy(zGlobPat, 'ab*cd?ef');      { GLOB: 'ab','cd','ef' = 6 literal chars }
  StrCopy(zClass,   'a[xy]z');        { GLOB: 'a' + ']' + 'z' literals = 3
                                        (mirrors C: pattern walker counts the
                                        terminating ']' once it leaves the class) }

  FillChar(e, SizeOf(e), 0);
  e.op := TK_STRING;
  e.u.zToken := zPlain;
  Check('LP1 plain LIKE',   estLikePatternLength(@e, 1) = 5);
  Check('LP2 plain GLOB',   estLikePatternLength(@e, 0) = 5);

  e.u.zToken := zLikePat;
  Check('LP3 LIKE wildcards', estLikePatternLength(@e, 1) = 4);

  e.u.zToken := zGlobPat;
  Check('LP4 GLOB wildcards', estLikePatternLength(@e, 0) = 6);

  e.u.zToken := zClass;
  Check('LP5 GLOB char class', estLikePatternLength(@e, 0) = 3);
end;

{ ----- whereLoopOutputAdjust (where.c:3037) -----

  Build a minimal pWInfo + pWC + pTabList with one TSrcItem and a small
  array of WhereTerms allocated in a local buffer.  Drive the function
  end-to-end and assert nOut/wsFlags/wtFlags transitions. }

type
  TSrcListBuf = record
    hdr:  TSrcList;
    item: TSrcItem;
  end;

procedure SeedTermBase(pT: PWhereTerm; mask: Bitmask);
begin
  FillChar(pT^, SizeOf(TWhereTerm), 0);
  pT^.iParent    := -1;
  pT^.prereqAll  := mask;
  pT^.truthProb  := 1;          { positive: heuristic path }
  pT^.eOperator  := 0;
  pT^.wtFlags    := 0;
end;

procedure TestOutputAdjust;
var
  db:       PTsqlite3;
  rc:       i32;
  parse:    TParse;
  wInfoBuf: array[0..1023] of u8;
  pWInfo:   PWhereInfo;
  src:      TSrcListBuf;
  pWC:      PWhereClause;
  loop:     TWhereLoop;
  terms:    array[0..3] of TWhereTerm;
  pRight:   TExpr;
  pTermExp: TExpr;
  pNullExp: TExpr;       { generic non-nil pExpr for terms that should
                           hit only the H1 (-1) path }
  before:   i16;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('OUT open', rc = SQLITE_OK);

  FillChar(parse,    SizeOf(parse),    0);
  parse.db := db;

  FillChar(wInfoBuf, SizeOf(wInfoBuf), 0);
  pWInfo := PWhereInfo(@wInfoBuf[0]);
  pWInfo^.pParse := @parse;

  FillChar(src, SizeOf(src), 0);
  src.hdr.nSrc        := 1;
  src.item.fg.jointype := 0;     { plain INNER }
  pWInfo^.pTabList    := @src.hdr;

  pWC := @pWInfo^.sWC;
  pWC^.pWInfo := pWInfo;
  pWC^.a      := @pWC^.aStatic[0];
  pWC^.nTerm  := 1;
  pWC^.nBase  := 1;

  { Generic pExpr for H1-only terms (op=TK_NULL → no H2 / H3 fallthrough). }
  FillChar(pNullExp, SizeOf(pNullExp), 0);
  pNullExp.op    := TK_NULL;
  pNullExp.flags := 0;

  { Test OUT1 — generic predicate not served by index → nOut -= 1.
    Term independent of every other table; truthProb=1 forces heuristic path. }
  FillChar(loop, SizeOf(loop), 0);
  whereLoopInit(@loop);
  loop.iTab     := 0;
  loop.maskSelf := $0001;
  loop.prereq   := $0000;
  loop.wsFlags  := 0;
  loop.nOut     := 20;
  loop.nLTerm   := 0;            { nothing in aLTerm[] }

  SeedTermBase(@terms[0], $0001); { prereqAll = maskSelf so the term hits us }
  terms[0].pExpr := @pNullExp;
  pWC^.a      := @terms[0];
  before := loop.nOut;
  whereLoopOutputAdjust(pWC, @loop, 100);
  Check('OUT1 H1 generic -1',     loop.nOut = before - 1);
  { Self-cull also fires: prereqAll == maskSelf, eOperator=0, jointype=0. }
  Check('OUT1 SELFCULL set',      (loop.wsFlags and WHERE_SELFCULL) <> 0);

  { Test OUT2 — TERM_VIRTUAL skipped entirely. }
  FillChar(loop, SizeOf(loop), 0);
  whereLoopInit(@loop);
  loop.iTab     := 0;
  loop.maskSelf := $0001;
  loop.nOut     := 20;
  SeedTermBase(@terms[0], $0001);
  terms[0].wtFlags := TERM_VIRTUAL;
  before := loop.nOut;
  whereLoopOutputAdjust(pWC, @loop, 100);
  Check('OUT2 virtual skipped',   loop.nOut = before);

  { Test OUT3 — H2 small-constant equality:
    eOperator=WO_EQ, pRight is integer 0  → iReduce=10,
    nOut capped at nRow - iReduce = 100 - 10 = 90, TERM_HEURTRUTH set. }
  FillChar(loop, SizeOf(loop), 0);
  whereLoopInit(@loop);
  loop.iTab     := 0;
  loop.maskSelf := $0001;
  loop.nOut     := 200;          { force the cap to bite }

  FillChar(pRight,   SizeOf(pRight),   0);
  pRight.op    := TK_INTEGER;
  pRight.flags := EP_IntValue;
  pRight.u.iValue := 0;          { in {-1,0,1} → small bucket }

  FillChar(pTermExp, SizeOf(pTermExp), 0);
  pTermExp.op    := TK_EQ;
  pTermExp.pRight := @pRight;

  SeedTermBase(@terms[0], $0001);
  terms[0].eOperator := WO_EQ;
  terms[0].pExpr     := @pTermExp;
  whereLoopOutputAdjust(pWC, @loop, 100);
  Check('OUT3 H2 small-const cap',  loop.nOut = 100 - 10);
  Check('OUT3 TERM_HEURTRUTH set',  (terms[0].wtFlags and TERM_HEURTRUTH) <> 0);

  { Test OUT4 — H2 large constant (k=42) → iReduce=20. }
  FillChar(loop, SizeOf(loop), 0);
  whereLoopInit(@loop);
  loop.iTab     := 0;
  loop.maskSelf := $0001;
  loop.nOut     := 200;
  pRight.u.iValue := 42;
  SeedTermBase(@terms[0], $0001);
  terms[0].eOperator := WO_EQ;
  terms[0].pExpr     := @pTermExp;
  whereLoopOutputAdjust(pWC, @loop, 100);
  Check('OUT4 H2 large-const cap',  loop.nOut = 100 - 20);

  { Test OUT5 — term IS served by index (in aLTerm) → not adjusted. }
  FillChar(loop, SizeOf(loop), 0);
  whereLoopInit(@loop);
  loop.iTab     := 0;
  loop.maskSelf := $0001;
  loop.nOut     := 25;
  SeedTermBase(@terms[0], $0001);
  terms[0].pExpr := @pNullExp;
  loop.aLTerm[0] := @terms[0];
  loop.nLTerm    := 1;
  before := loop.nOut;
  whereLoopOutputAdjust(pWC, @loop, 100);
  Check('OUT5 served-by-index untouched', loop.nOut = before);

  { Test OUT6 — application-supplied likelihood() (truthProb<=0):
    nOut += truthProb (negative) instead of -1 heuristic. }
  FillChar(loop, SizeOf(loop), 0);
  whereLoopInit(@loop);
  loop.iTab     := 0;
  loop.maskSelf := $0001;
  loop.nOut     := 50;
  SeedTermBase(@terms[0], $0001);
  terms[0].pExpr := @pNullExp;
  terms[0].truthProb := -7;
  before := loop.nOut;
  whereLoopOutputAdjust(pWC, @loop, 100);
  Check('OUT6 app-truthProb',    loop.nOut = before + (-7));

  sqlite3_close(db);
end;

{ ----- whereInterstageHeuristic ----- }

procedure TestInterstageHeuristic;
const
  N_LEVEL = 3;
var
  buf:    array of Byte;
  pWInfo: PWhereInfo;
  loops:  array[0..5] of TWhereLoop;
  i:      i32;
  ALL:    Bitmask;
begin
  ALL := not Bitmask(0);

  { ----- T1: outer EQ on iTab=0 disables full-scan rival on iTab=0;
    constrained rival left intact. ----- }
  for i := 0 to High(loops) do
    FillChar(loops[i], SizeOf(TWhereLoop), 0);

  { Chosen plan: level 0 → loops[0] (WHERE_COLUMN_EQ, iTab=0). }
  loops[0].wsFlags := WHERE_COLUMN_EQ;
  loops[0].iTab    := 0;
  loops[0].prereq  := 0;

  { Rivals on the pLoops chain. }
  loops[1].wsFlags := 0;          { full scan on iTab=0 — should be disabled }
  loops[1].iTab    := 0;
  loops[1].prereq  := 0;
  loops[2].wsFlags := WHERE_COLUMN_RANGE; { WHERE_CONSTRAINT subset → kept }
  loops[2].iTab    := 0;
  loops[2].prereq  := 0;
  loops[3].wsFlags := WHERE_AUTO_INDEX;   { auto-index → kept }
  loops[3].iTab    := 0;
  loops[3].prereq  := 0;
  loops[4].wsFlags := 0;          { full scan on iTab=1 — wrong table, untouched }
  loops[4].iTab    := 1;
  loops[4].prereq  := 0;

  loops[0].pNextLoop := @loops[1];
  loops[1].pNextLoop := @loops[2];
  loops[2].pNextLoop := @loops[3];
  loops[3].pNextLoop := @loops[4];
  loops[4].pNextLoop := nil;

  SetLength(buf, SZ_WHEREINFO(N_LEVEL));
  FillChar(buf[0], Length(buf), 0);
  pWInfo := PWhereInfo(@buf[0]);
  pWInfo^.nLevel := N_LEVEL;
  pWInfo^.pLoops := @loops[0];
  whereInfoLevels(pWInfo)[0].pWLoop := @loops[0];
  whereInfoLevels(pWInfo)[1].pWLoop := nil; { cuts walk }
  whereInfoLevels(pWInfo)[2].pWLoop := nil;

  whereInterstageHeuristic(pWInfo);

  Check('IH1 chosen loop unchanged',           loops[0].prereq = 0);
  Check('IH1 rival full-scan disabled',        loops[1].prereq = ALL);
  Check('IH1 constrained rival kept',          loops[2].prereq = 0);
  Check('IH1 auto-index rival kept',           loops[3].prereq = 0);
  Check('IH1 wrong-table rival untouched',     loops[4].prereq = 0);

  { ----- T2: walk stops at virtual-table outer loop. ----- }
  for i := 0 to High(loops) do
    FillChar(loops[i], SizeOf(TWhereLoop), 0);

  loops[0].wsFlags := WHERE_VIRTUALTABLE;
  loops[0].iTab    := 0;
  loops[1].wsFlags := WHERE_COLUMN_EQ;     { would fire if reached }
  loops[1].iTab    := 1;
  loops[2].wsFlags := 0;                   { rival on iTab=1 — must NOT be disabled }
  loops[2].iTab    := 1;

  loops[0].pNextLoop := @loops[2];
  loops[2].pNextLoop := nil;

  pWInfo^.pLoops := @loops[0];
  whereInfoLevels(pWInfo)[0].pWLoop := @loops[0];
  whereInfoLevels(pWInfo)[1].pWLoop := @loops[1];
  whereInfoLevels(pWInfo)[2].pWLoop := nil;

  whereInterstageHeuristic(pWInfo);

  Check('IH2 vtab break — inner level not processed', loops[2].prereq = 0);

  { ----- T3: walk stops at unconstrained loop (no EQ/IN/NULL). ----- }
  for i := 0 to High(loops) do
    FillChar(loops[i], SizeOf(TWhereLoop), 0);

  loops[0].wsFlags := WHERE_COLUMN_EQ;
  loops[0].iTab    := 0;
  loops[1].wsFlags := WHERE_COLUMN_RANGE;  { not EQ/IN/NULL → break }
  loops[1].iTab    := 1;
  loops[2].wsFlags := 0;                   { rival on iTab=2 }
  loops[2].iTab    := 2;
  loops[3].wsFlags := 0;                   { rival on iTab=0 — should be disabled }
  loops[3].iTab    := 0;

  loops[0].pNextLoop := @loops[3];
  loops[3].pNextLoop := @loops[2];
  loops[2].pNextLoop := nil;

  pWInfo^.pLoops := @loops[0];
  whereInfoLevels(pWInfo)[0].pWLoop := @loops[0];
  whereInfoLevels(pWInfo)[1].pWLoop := @loops[1];
  whereInfoLevels(pWInfo)[2].pWLoop := @loops[2];

  whereInterstageHeuristic(pWInfo);

  Check('IH3 outer EQ disabled rival on iTab=0',   loops[3].prereq = ALL);
  Check('IH3 inner-level break — iTab=2 untouched', loops[2].prereq = 0);

  { ----- T4: nil pWLoop terminates walk early. ----- }
  for i := 0 to High(loops) do
    FillChar(loops[i], SizeOf(TWhereLoop), 0);

  loops[0].wsFlags := WHERE_COLUMN_IN;
  loops[0].iTab    := 0;
  loops[1].wsFlags := 0;
  loops[1].iTab    := 0;

  loops[0].pNextLoop := @loops[1];
  loops[1].pNextLoop := nil;

  pWInfo^.pLoops := @loops[0];
  whereInfoLevels(pWInfo)[0].pWLoop := @loops[0];
  whereInfoLevels(pWInfo)[1].pWLoop := nil; { stops walk after level 0 }
  whereInfoLevels(pWInfo)[2].pWLoop := nil;

  whereInterstageHeuristic(pWInfo);

  Check('IH4 WHERE_COLUMN_IN trips disable',  loops[1].prereq = ALL);

  { ----- T5: WHERE_COLUMN_NULL trips disable too. ----- }
  for i := 0 to High(loops) do
    FillChar(loops[i], SizeOf(TWhereLoop), 0);

  loops[0].wsFlags := WHERE_COLUMN_NULL;
  loops[0].iTab    := 7;
  loops[1].wsFlags := 0;
  loops[1].iTab    := 7;

  loops[0].pNextLoop := @loops[1];
  loops[1].pNextLoop := nil;

  pWInfo^.pLoops := @loops[0];
  whereInfoLevels(pWInfo)[0].pWLoop := @loops[0];
  whereInfoLevels(pWInfo)[1].pWLoop := nil;
  whereInfoLevels(pWInfo)[2].pWLoop := nil;

  whereInterstageHeuristic(pWInfo);

  Check('IH5 WHERE_COLUMN_NULL trips disable', loops[1].prereq = ALL);
end;

begin
  WriteLn('---- TestWherePlanner ----');
  TestOrSet;
  TestCheaperProperSubset;
  TestFindLesser;
  TestInsert;
  TestAdjustCost;
  TestEstLog;
  TestExprIsLikeOperator;
  TestEstLikePatternLength;
  TestOutputAdjust;
  TestInterstageHeuristic;
  WriteLn('---- ', gPass, '/', gPass + gFail, ' passed ----');
  if gFail > 0 then Halt(1);
end.
