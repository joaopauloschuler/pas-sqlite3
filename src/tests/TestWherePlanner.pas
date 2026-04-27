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

{ ----- whereRangeVectorLen ----- }

procedure TestRangeVectorLen;
var
  exLeftScalar: TExpr;
  exRoot:       TExpr;
  exVecLeft:    TExpr;
  exVecRight:   TExpr;
  lhsBuf:       array[0 .. SizeOf(TExprList) + 2*SizeOf(TExprListItem) - 1] of Byte;
  rhsBuf:       array[0 .. SizeOf(TExprList) + 2*SizeOf(TExprListItem) - 1] of Byte;
  pLhsList:     PExprList;
  pRhsList:     PExprList;
  pLhsItems:    PExprListItem;
  pRhsItems:    PExprListItem;
  exLhs0,exLhs1,exRhs0,exRhs1: TExpr;
  pTerm:        TWhereTerm;
  idx:          TIndex;
  aiCols:       array[0..2] of i16;
  aSort:        array[0..2] of u8;
  rc:           i32;
begin
  { ----- RV1: scalar (non-vector) pTerm — returns 1 unconditionally. ----- }
  FillChar(exLeftScalar, SizeOf(TExpr), 0);
  FillChar(exRoot,       SizeOf(TExpr), 0);
  FillChar(idx,          SizeOf(TIndex), 0);
  FillChar(pTerm,        SizeOf(TWhereTerm), 0);

  exLeftScalar.op := TK_COLUMN;
  exRoot.op       := TK_GT_TK;
  exRoot.pLeft    := @exLeftScalar;
  exRoot.pRight   := nil;
  pTerm.pExpr     := @exRoot;

  aiCols[0] := 0; aiCols[1] := 1; aiCols[2] := 2;
  aSort[0]  := 0; aSort[1] := 0;  aSort[2] := 0;
  idx.aiColumn   := @aiCols[0];
  idx.aSortOrder := @aSort[0];
  idx.nColumn    := 3;

  rc := whereRangeVectorLen(nil, 7, @idx, 0, @pTerm);
  Check('RV1 scalar non-vector returns 1', rc = 1);

  { ----- RV2: 2-component vector LHS, but the i=1 LHS column lives on a
    different cursor than iCur — the inner loop breaks immediately and
    the function returns 1. ----- }
  FillChar(exLhs0,    SizeOf(TExpr), 0);
  FillChar(exLhs1,    SizeOf(TExpr), 0);
  FillChar(exRhs0,    SizeOf(TExpr), 0);
  FillChar(exRhs1,    SizeOf(TExpr), 0);
  FillChar(exVecLeft, SizeOf(TExpr), 0);
  FillChar(exVecRight,SizeOf(TExpr), 0);
  FillChar(lhsBuf, SizeOf(lhsBuf), 0);
  FillChar(rhsBuf, SizeOf(rhsBuf), 0);

  exLhs0.op := TK_COLUMN; exLhs0.iTable := 7; exLhs0.iColumn := 0;
  exLhs1.op := TK_COLUMN; exLhs1.iTable := 99; exLhs1.iColumn := 1; { wrong cursor }

  pLhsList := PExprList(@lhsBuf[0]);
  pLhsList^.nExpr := 2;
  pLhsItems := ExprListItems(pLhsList);
  pLhsItems[0].pExpr := @exLhs0;
  pLhsItems[1].pExpr := @exLhs1;

  exVecLeft.op := TK_VECTOR;
  exVecLeft.flags := 0; { ExprUseXList → EP_xIsSelect must be clear }
  exVecLeft.x.pList := pLhsList;

  exRhs0.op := TK_INTEGER;
  exRhs1.op := TK_INTEGER;
  pRhsList := PExprList(@rhsBuf[0]);
  pRhsList^.nExpr := 2;
  pRhsItems := ExprListItems(pRhsList);
  pRhsItems[0].pExpr := @exRhs0;
  pRhsItems[1].pExpr := @exRhs1;
  exVecRight.op    := TK_VECTOR;
  exVecRight.flags := 0;
  exVecRight.x.pList := pRhsList;

  exRoot.pLeft  := @exVecLeft;
  exRoot.pRight := @exVecRight;
  pTerm.pExpr   := @exRoot;

  rc := whereRangeVectorLen(nil, 7, @idx, 0, @pTerm);
  Check('RV2 vector — wrong-cursor LHS at i=1 → 1', rc = 1);

  { ----- RV3: same vector shape but the i=1 LHS sort order differs from
    nEq=0's sort order — break at the sort-order check. ----- }
  exLhs1.iTable  := 7;       { correct cursor now }
  exLhs1.iColumn := 1;       { matches aiColumn[1] }
  aSort[0] := 0;
  aSort[1] := 1;             { mismatch with aSort[nEq=0]=0 }

  rc := whereRangeVectorLen(nil, 7, @idx, 0, @pTerm);
  Check('RV3 vector — mismatched sort order at i=1 → 1', rc = 1);

  { ----- RV4: nCmp capped by (nColumn - nEq).  nColumn=3, nEq=2 → cap=1
    so the i=1 loop iteration never starts even with valid columns. ----- }
  rc := whereRangeVectorLen(nil, 7, @idx, 2, @pTerm);
  Check('RV4 vector — cap by (nColumn - nEq) → 1', rc = 1);
end;

{ ----- indexMightHelpWithOrderBy + exprIsCoveredByIndex ----- }

procedure TestIndexHelpers;
var
  wInfo:    TWhereInfo;
  builder:  TWhereLoopBuilder;
  idx:      TIndex;
  aiCols:   array[0..2] of i16;
  obBuf:    array[0 .. SizeOf(TExprList) + 2*SizeOf(TExprListItem) - 1] of Byte;
  aceBuf:   array[0 .. SizeOf(TExprList) + 2*SizeOf(TExprListItem) - 1] of Byte;
  pOB:      PExprList;
  pAce:     PExprList;
  obItems:  PExprListItem;
  aceItems: PExprListItem;
  obE0,obE1: TExpr;
  aceE0:    TExpr;
  rc:       i32;
begin
  FillChar(wInfo,   SizeOf(wInfo), 0);
  FillChar(builder, SizeOf(builder), 0);
  FillChar(idx,     SizeOf(idx),   0);
  FillChar(obBuf,   SizeOf(obBuf), 0);
  FillChar(aceBuf,  SizeOf(aceBuf), 0);
  FillChar(obE0, SizeOf(obE0), 0); FillChar(obE1, SizeOf(obE1), 0);
  FillChar(aceE0, SizeOf(aceE0), 0);

  builder.pWInfo := @wInfo;
  aiCols[0] := 0; aiCols[1] := 5; aiCols[2] := XN_EXPR;
  idx.aiColumn := @aiCols[0];
  idx.nKeyCol  := 3;
  idx.nColumn  := 3;

  { ----- IMHO1: pOrderBy = nil → 0. ----- }
  wInfo.pOrderBy := nil;
  rc := indexMightHelpWithOrderBy(@builder, @idx, 7);
  Check('IMHO1 pOrderBy nil returns 0', rc = 0);

  { ----- IMHO2: bUnordered=1 → 0 even with matching ORDER BY. ----- }
  pOB := PExprList(@obBuf[0]);
  pOB^.nExpr := 1;
  obItems := ExprListItems(pOB);
  obE0.op := TK_COLUMN; obE0.iTable := 7; obE0.iColumn := -1; { rowid }
  obItems[0].pExpr := @obE0;
  wInfo.pOrderBy := pOB;
  idx.idxFlags := idx.idxFlags or u32(1) shl 2; { bUnordered }
  rc := indexMightHelpWithOrderBy(@builder, @idx, 7);
  Check('IMHO2 bUnordered short-circuits', rc = 0);
  idx.idxFlags := idx.idxFlags and (not (u32(1) shl 2));

  { ----- IMHO3: ORDER BY rowid (iColumn<0) on the right cursor → 1. ----- }
  rc := indexMightHelpWithOrderBy(@builder, @idx, 7);
  Check('IMHO3 ORDER BY rowid returns 1', rc = 1);

  { ----- IMHO4: ORDER BY column matches a key column (5). ----- }
  obE0.iColumn := 5;
  rc := indexMightHelpWithOrderBy(@builder, @idx, 7);
  Check('IMHO4 ORDER BY key-col returns 1', rc = 1);

  { ----- IMHO5: ORDER BY column does not match any key column → 0. ----- }
  obE0.iColumn := 9;  { not in {0,5,XN_EXPR} }
  rc := indexMightHelpWithOrderBy(@builder, @idx, 7);
  Check('IMHO5 ORDER BY unrelated col returns 0', rc = 0);

  { ----- IMHO6: ORDER BY column on a different cursor → 0. ----- }
  obE0.iColumn := 0; obE0.iTable := 99;
  rc := indexMightHelpWithOrderBy(@builder, @idx, 7);
  Check('IMHO6 wrong cursor returns 0', rc = 0);

  { ----- ECI1: aColExpr = nil → 0. ----- }
  rc := exprIsCoveredByIndex(@obE0, @idx, 7);
  Check('ECI1 aColExpr nil returns 0', rc = 0);

  { ----- ECI2: aColExpr supplied, slot 2 is XN_EXPR and matches the
    expression node by reference (sqlite3ExprCompare returns 0 for the
    same node).  Returns 1. ----- }
  pAce := PExprList(@aceBuf[0]);
  pAce^.nExpr := 3;
  aceItems := ExprListItems(pAce);
  aceItems[0].pExpr := nil;
  aceItems[1].pExpr := nil;
  aceE0.op := TK_COLUMN; aceE0.iTable := 7; aceE0.iColumn := 4;
  aceItems[2].pExpr := @aceE0;
  idx.aColExpr := pAce;
  rc := exprIsCoveredByIndex(@aceE0, @idx, 7);
  Check('ECI2 XN_EXPR slot matches → 1', rc = 1);

  { ----- ECI3: aColExpr supplied but no slot is XN_EXPR → 0. ----- }
  aiCols[0] := 0; aiCols[1] := 5; aiCols[2] := 7;  { no XN_EXPR }
  rc := exprIsCoveredByIndex(@aceE0, @idx, 7);
  Check('ECI3 no XN_EXPR slot returns 0', rc = 0);
  aiCols[2] := XN_EXPR;
end;

{ ----- whereIsCoveringIndex ----- }

procedure TestWhereIsCoveringIndex;
var
  wInfo:   TWhereInfo;
  idx:     TIndex;
  aiCols:  array[0..2] of i16;
  sel:     TSelect;
  rc:      u32;
begin
  FillChar(wInfo, SizeOf(wInfo), 0);
  FillChar(idx,   SizeOf(idx),   0);
  FillChar(sel,   SizeOf(sel),   0);

  aiCols[0] := 0; aiCols[1] := 1; aiCols[2] := 2;
  idx.aiColumn := @aiCols[0];
  idx.nColumn  := 3;

  { ----- WIC1: pSelect = nil → 0 (cannot determine coverage). ----- }
  wInfo.pSelect := nil;
  rc := whereIsCoveringIndex(@wInfo, @idx, 4);
  Check('WIC1 pSelect=nil returns 0', rc = 0);

  { ----- WIC2: bHasExpr=0 and every aiColumn[i] < BMS-1 → 0
    (loop runs to completion with no aiColumn[i] >= BMS-1). ----- }
  wInfo.pSelect := @sel;
  rc := whereIsCoveringIndex(@wInfo, @idx, 4);
  Check('WIC2 no high-column slot returns 0', rc = 0);

  { ----- WIC3: at least one aiColumn[i] >= BMS-1 lets us proceed.  Empty
    select walks cleanly → no column refs → bUnidx=0, bExpr=0 → returns
    WHERE_IDX_ONLY. ----- }
  aiCols[1] := i16(BMS - 1);
  rc := whereIsCoveringIndex(@wInfo, @idx, 4);
  Check('WIC3 empty select → WHERE_IDX_ONLY', rc = WHERE_IDX_ONLY);
end;

{ ----- whereIndexedExprCleanup ----- }

procedure TestIndexedExprCleanup;
var
  e1, e2, e3: PIndexedExpr;
  pHead: PIndexedExpr;
begin
  { Heap-alloc the nodes — sqlite3DbFreeNN(nil, ...) routes to sqlite3_free
    and so requires sqlite3_malloc'd storage.  pExpr stays nil so the
    sqlite3ExprDelete arm is a no-op. }
  e1 := PIndexedExpr(sqlite3_malloc(SizeOf(TIndexedExpr)));
  e2 := PIndexedExpr(sqlite3_malloc(SizeOf(TIndexedExpr)));
  e3 := PIndexedExpr(sqlite3_malloc(SizeOf(TIndexedExpr)));
  FillChar(e1^, SizeOf(TIndexedExpr), 0);
  FillChar(e2^, SizeOf(TIndexedExpr), 0);
  FillChar(e3^, SizeOf(TIndexedExpr), 0);
  e1^.pIENext := e2;
  e2^.pIENext := e3;
  e3^.pIENext := nil;
  pHead := e1;
  whereIndexedExprCleanup(nil, @pHead);
  Check('WIEC list head emptied', pHead = nil);
end;

{ ----- wherePartIdxExpr (mask path) ----- }

procedure TestPartIdxExprMask;
var
  idx:     TIndex;
  aff:     TColumn;
  cols:    array[0..3] of TColumn;
  tab:     TTable;
  exEq:    TExpr;
  exLeft:  TExpr;
  exRight: TExpr;
  exRoot:  TExpr;
  mask:    Bitmask;
begin
  FillChar(idx,    SizeOf(idx),    0);
  FillChar(aff,    SizeOf(aff),    0);
  FillChar(cols,   SizeOf(cols),   0);
  FillChar(tab,    SizeOf(tab),    0);
  FillChar(exEq,   SizeOf(exEq),   0);
  FillChar(exLeft, SizeOf(exLeft), 0);
  FillChar(exRight,SizeOf(exRight),0);
  FillChar(exRoot, SizeOf(exRoot), 0);

  { ----- WPIE1: non-EQ root pPart is a no-op.  mask preserved. ----- }
  exRoot.op := TK_COLUMN;
  mask := $00FF;
  wherePartIdxExpr(nil, @idx, @exRoot, @mask, 1, nil);
  Check('WPIE1 non-EQ no-op', mask = $00FF);

  { ----- WPIE2: TK_EQ + non-column LHS → no-op. ----- }
  exRoot.op := TK_EQ; exRoot.pLeft := @exLeft; exRoot.pRight := @exRight;
  exLeft.op := TK_INTEGER;
  exRight.op := TK_INTEGER;
  wherePartIdxExpr(nil, @idx, @exRoot, @mask, 1, nil);
  Check('WPIE2 non-column LHS no-op', mask = $00FF);

  { ----- WPIE3: pLeft^.iColumn < 0 (rowid) → no-op even with TK_COLUMN. ----- }
  exLeft.op := TK_COLUMN; exLeft.iColumn := -1;
  wherePartIdxExpr(nil, @idx, @exRoot, @mask, 1, nil);
  Check('WPIE3 iColumn<0 no-op', mask = $00FF);

  { ----- WPIE4: TK_AND walk — left-side TK_EQ still fires under same
    no-op conditions; right is pPart^.pRight set to a fresh TK_COLUMN-LHS
    branch.  Just verify that TK_AND doesn't crash and mask is preserved
    when both sides are no-ops. ----- }
  exEq.op := TK_AND; exEq.pLeft := @exRoot; exEq.pRight := @exRoot;
  wherePartIdxExpr(nil, @idx, @exEq, @mask, 1, nil);
  Check('WPIE4 TK_AND walk preserves mask', mask = $00FF);

  { ----- WPIE5: column LHS with affinity = TEXT, rhs constant integer,
    coll = nil (BINARY).  iColumn=3 < BMS-1 → bit 3 cleared. ----- }
  cols[3].affinity := AnsiChar(SQLITE_AFF_TEXT);
  tab.aCol  := @cols[0];
  idx.pTable := @tab;
  exLeft.op := TK_COLUMN; exLeft.iColumn := 3;
  exRight.op := TK_INTEGER; { sqlite3ExprIsConstant TK_INTEGER → 1 }
  exRoot.op := TK_EQ;
  mask := Bitmask($FF);
  wherePartIdxExpr(nil, @idx, @exRoot, @mask, 1, nil);
  Check('WPIE5 mask bit 3 cleared', mask = (Bitmask($FF) and not (Bitmask(1) shl 3)));
end;

{ ----- whereRangeAdjust (where.c:1916..1926) ----- }

procedure TestWhereRangeAdjust;
var
  t: TWhereTerm;
begin
  FillChar(t, SizeOf(t), 0);

  Check('RA1 nil pTerm passthrough', whereRangeAdjust(nil, 33) = 33);

  { truthProb<=0 → nNew + truthProb (additive likelihood). }
  t.truthProb := -7;
  t.wtFlags   := 0;
  Check('RA2 truthProb<=0 added', whereRangeAdjust(@t, 100) = 93);

  { truthProb>0 + non-VNULL → -20 default discount. }
  t.truthProb := 5;
  t.wtFlags   := 0;
  Check('RA3 truthProb>0 default -20', whereRangeAdjust(@t, 100) = 80);

  { truthProb>0 + TERM_VNULL → no discount (selectivity owned by VNULL synth). }
  t.truthProb := 5;
  t.wtFlags   := TERM_VNULL;
  Check('RA4 TERM_VNULL skips discount', whereRangeAdjust(@t, 100) = 100);

  { truthProb=0 hits the "<=0" arm with additive 0. }
  t.truthProb := 0;
  t.wtFlags   := 0;
  Check('RA5 truthProb=0 no change', whereRangeAdjust(@t, 42) = 42);
end;

{ ----- constraintCompatibleWithOuterJoin (where.c:832..852) ----- }

procedure TestConstraintCompatOuterJoin;
var
  t:    TWhereTerm;
  src:  TSrcItem;
  e:    TExpr;
begin
  FillChar(t, SizeOf(t), 0);
  FillChar(src, SizeOf(src), 0);
  FillChar(e, SizeOf(e), 0);
  t.pExpr := @e;

  { CC1: LEFT join, term has no ON-bit → 0 (not an outer-driving term). }
  src.fg.jointype := JT_LEFT;
  src.iCursor     := 7;
  e.flags         := 0;
  e.w.iJoin       := 7;
  Check('CC1 no OuterON/InnerON → 0',
        constraintCompatibleWithOuterJoin(@t, @src) = 0);

  { CC2: OuterON but iJoin mismatches cursor → 0. }
  e.flags   := EP_OuterON;
  e.w.iJoin := 99;
  Check('CC2 iJoin mismatch → 0',
        constraintCompatibleWithOuterJoin(@t, @src) = 0);

  { CC3: OuterON + matching cursor on a LEFT side → 1. }
  e.flags   := EP_OuterON;
  e.w.iJoin := 7;
  Check('CC3 OuterON+match LEFT → 1',
        constraintCompatibleWithOuterJoin(@t, @src) = 1);

  { CC4: InnerON on a LEFT join → forbidden (cannot drive outer side). }
  e.flags := EP_InnerON;
  Check('CC4 InnerON on LEFT → 0',
        constraintCompatibleWithOuterJoin(@t, @src) = 0);

  { CC5: InnerON on a pure LTORJ (no LEFT/RIGHT bit) → 1. }
  src.fg.jointype := JT_LTORJ;
  e.flags         := EP_InnerON;
  Check('CC5 InnerON on LTORJ-only → 1',
        constraintCompatibleWithOuterJoin(@t, @src) = 1);

  { CC6: OuterON on RIGHT join → 1. }
  src.fg.jointype := JT_RIGHT;
  e.flags         := EP_OuterON;
  Check('CC6 OuterON on RIGHT → 1',
        constraintCompatibleWithOuterJoin(@t, @src) = 1);
end;

{ ----- indexHasStat1 (idxFlags bit 7) + columnIsGoodIndexCandidate ----- }

procedure TestColumnIsGoodIndexCandidate;
var
  tab:        TTable;
  idx1, idx2: TIndex;
  cols1:      array[0..2] of i16;
  cols2:      array[0..2] of i16;
  rowEst1:    array[0..3] of i16;
begin
  FillChar(tab,   SizeOf(tab),   0);
  FillChar(idx1,  SizeOf(idx1),  0);
  FillChar(idx2,  SizeOf(idx2),  0);

  { CG0: indexHasStat1 reads bit 7 of idxFlags. }
  idx1.idxFlags := u32(1) shl 7;
  Check('CG0 indexHasStat1 bit 7', indexHasStat1(@idx1) = 1);
  idx1.idxFlags := 0;
  Check('CG0b indexHasStat1 cleared', indexHasStat1(@idx1) = 0);

  { No indexes at all → every column is "good". }
  tab.pIndex := nil;
  Check('CG1 empty pIndex → 1', columnIsGoodIndexCandidate(@tab, 0) = 1);

  { idx1 covers (col0). col0 is leading → not a good auto-index candidate. }
  cols1[0] := 0;  cols1[1] := 1;
  idx1.aiColumn := @cols1[0];
  idx1.nKeyCol  := 2;
  idx1.idxFlags := 0;          { hasStat1 = 0 }
  idx1.pNext    := nil;
  tab.pIndex    := @idx1;
  Check('CG2 leading col → 0', columnIsGoodIndexCandidate(@tab, 0) = 0);

  { col1 is non-leading; hasStat1=0 means we don't reject on stat1, so 1. }
  Check('CG3 non-leading + no stat1 → 1', columnIsGoodIndexCandidate(@tab, 1) = 1);

  { Turn on hasStat1 and make aiRowLogEst[2] (j=1, j+1=2) > 20 → 0. }
  rowEst1[0] := 100;  rowEst1[1] := 50;  rowEst1[2] := 25;  rowEst1[3] := 10;
  idx1.aiRowLogEst := @rowEst1[0];
  idx1.idxFlags    := u32(1) shl 7;  { hasStat1 = 1 }
  Check('CG4 hasStat1 + bad selectivity → 0',
        columnIsGoodIndexCandidate(@tab, 1) = 0);

  { With selective stat1 (≤20), we keep returning 1. }
  rowEst1[2] := 15;
  Check('CG5 hasStat1 + good selectivity → 1',
        columnIsGoodIndexCandidate(@tab, 1) = 1);

  { Column not in any existing index → 1. }
  Check('CG6 col not in any index → 1',
        columnIsGoodIndexCandidate(@tab, 2) = 1);

  { Walk the pNext chain: idx2 lists col 5 as leading → reject col 5. }
  cols2[0] := 5;
  idx2.aiColumn := @cols2[0];
  idx2.nKeyCol  := 1;
  idx2.idxFlags := 0;
  idx2.pNext    := nil;
  idx1.pNext    := @idx2;
  Check('CG7 chained idx2 leading col 5 → 0',
        columnIsGoodIndexCandidate(@tab, 5) = 0);
end;

{ ----- termCanDriveIndex (where.c:901..924) ----- }

procedure TestTermCanDriveIndex;
var
  t:    TWhereTerm;
  src:  TSrcItem;
  tab:  TTable;
  idx:  TIndex;
  cols: array[0..3] of TColumn;
  e, eL, eR: TExpr;
begin
  FillChar(t,    SizeOf(t),    0);
  FillChar(src,  SizeOf(src),  0);
  FillChar(tab,  SizeOf(tab),  0);
  FillChar(idx,  SizeOf(idx),  0);
  FillChar(cols, SizeOf(cols), 0);
  FillChar(e,    SizeOf(e),    0);
  FillChar(eL,   SizeOf(eL),   0);
  FillChar(eR,   SizeOf(eR),   0);

  cols[0].affinity := AnsiChar(SQLITE_AFF_BLOB);
  cols[1].affinity := AnsiChar(SQLITE_AFF_BLOB);
  cols[2].affinity := AnsiChar(SQLITE_AFF_BLOB);
  tab.aCol         := @cols[0];
  tab.nCol         := 4;
  tab.pIndex       := nil;       { no preexisting indexes }

  src.iCursor      := 4;
  src.pSTab        := @tab;
  src.fg.jointype  := 0;

  { TK_EQ Expr with column LHS (iColumn=1) and TK_INTEGER RHS. }
  e.op    := TK_EQ;
  e.pLeft := @eL;
  e.pRight:= @eR;
  eL.op   := TK_COLUMN;
  eL.iColumn := 1;
  eR.op   := TK_INTEGER;

  t.pExpr        := @e;
  t.eOperator    := WO_EQ;
  t.leftCursor   := 4;
  t.u.leftColumn := 1;
  t.prereqRight  := 0;
  t.wtFlags      := 0;

  Check('TC1 EQ on col 1 → 1', termCanDriveIndex(@t, @src, 0) = 1);

  { Wrong cursor → 0. }
  t.leftCursor := 99;
  Check('TC2 wrong cursor → 0', termCanDriveIndex(@t, @src, 0) = 0);
  t.leftCursor := 4;

  { Non-EQ/IS operator → 0. }
  t.eOperator := WO_LT;
  Check('TC3 non-EQ → 0', termCanDriveIndex(@t, @src, 0) = 0);
  t.eOperator := WO_IS;
  Check('TC3b WO_IS accepted', termCanDriveIndex(@t, @src, 0) = 1);
  t.eOperator := WO_EQ;

  { prereqRight ∩ notReady → 0. }
  t.prereqRight := $0F;
  Check('TC4 prereqRight blocked → 0', termCanDriveIndex(@t, @src, $03) = 0);
  t.prereqRight := 0;

  { leftColumn<0 (rowid) → 0. }
  t.u.leftColumn := -1;
  Check('TC5 rowid leftColumn → 0', termCanDriveIndex(@t, @src, 0) = 0);
  t.u.leftColumn := 1;

end;

{ Compose a more focused test for the existing-index gating to keep the
  stack-allocated probe array alive in scope. }
procedure TestTermCanDriveIndexGate;
var
  t:    TWhereTerm;
  src:  TSrcItem;
  tab:  TTable;
  idx:  TIndex;
  cols: array[0..3] of TColumn;
  aiCol: array[0..1] of i16;
  e, eL, eR: TExpr;
begin
  FillChar(t,    SizeOf(t),    0);
  FillChar(src,  SizeOf(src),  0);
  FillChar(tab,  SizeOf(tab),  0);
  FillChar(idx,  SizeOf(idx),  0);
  FillChar(cols, SizeOf(cols), 0);
  FillChar(e,    SizeOf(e),    0);
  FillChar(eL,   SizeOf(eL),   0);
  FillChar(eR,   SizeOf(eR),   0);

  cols[1].affinity := AnsiChar(SQLITE_AFF_BLOB);
  tab.aCol         := @cols[0];
  tab.nCol         := 4;

  aiCol[0] := 1;
  idx.aiColumn := @aiCol[0];
  idx.nKeyCol  := 1;
  idx.idxFlags := 0;
  idx.pNext    := nil;
  tab.pIndex   := @idx;

  src.iCursor     := 4;
  src.pSTab       := @tab;
  src.fg.jointype := 0;

  e.op := TK_EQ; e.pLeft := @eL; e.pRight := @eR;
  eL.op := TK_COLUMN; eL.iColumn := 1;
  eR.op := TK_INTEGER;

  t.pExpr        := @e;
  t.eOperator    := WO_EQ;
  t.leftCursor   := 4;
  t.u.leftColumn := 1;

  { Existing index has col 1 as the leading key, so columnIsGoodIndexCandidate
    rejects col 1 → termCanDriveIndex returns 0 even though everything else
    matches. }
  Check('TC7 existing leading idx → 0', termCanDriveIndex(@t, @src, 0) = 0);
end;

{ ----- ExprImpliesExpr / ExprIsNotTrue / ExprIsIIF / whereUsablePartialIndex ----- }

procedure TestExprImplies;
var
  rc:    i32;
  db:    PTsqlite3;
  parse: TParse;
  pTab:  PTable2;
  zNm:   array[0..3] of AnsiChar;
  pSrcBuf: Pointer;
  pSrc:    PSrcList;
  pItem:   PSrcItem;
  pWInfo:  PWhereInfo;
  pWC:     PWhereClause;
  pNull, pTrueE, pFalseE, pOne, pZero: PExpr;
  pColA, pInt5, pEqA1, pEqA2: PExpr;
  pColA2, pInt5b, pEqA2same: PExpr;
  pColB, pInt7, pEqB, pOrAB: PExpr;
  pColC, pNotnullC: PExpr;
  pColC2, pEqC5, pInt5c: PExpr;
  pColUnequal, pInt9, pEqU: PExpr;
  pCaseList: PExprList;
  pCase2arg, pCase3argNull, pCase3argFalse, pCase3argTrue: PExpr;
  pColPart, pNotnullPart: PExpr;
  pTmpInt5: PExpr;
  pPartCol, pPart5, pPartEq: PExpr;
  pColMain, pIntMain, pEqMain: PExpr;
  tokI: TToken;
begin
  rc := sqlite3_initialize;
  if rc <> SQLITE_OK then begin
    WriteLn('FATAL: sqlite3_initialize rc=', rc); Halt(2);
  end;
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if (rc <> SQLITE_OK) or (db = nil) then begin
    WriteLn('FATAL: sqlite3_open rc=', rc); Halt(2);
  end;

  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;

  { sqlite3ExprIsNotTrue — TK_NULL. }
  pNull := sqlite3ExprAlloc(db, TK_NULL, nil, 0);
  Check('EINT1 TK_NULL is not-true',
        sqlite3ExprIsNotTrue(pNull) = 1);

  { TK_TRUEFALSE 'true' / 'false'. }
  tokI.z := 'true';  tokI.n := 4;
  pTrueE := sqlite3ExprAlloc(db, TK_TRUEFALSE, @tokI, 0);
  pTrueE^.flags := pTrueE^.flags or EP_IsTrue;
  Check('EINT2 TK_TRUEFALSE true is true',
        sqlite3ExprIsNotTrue(pTrueE) = 0);
  tokI.z := 'false'; tokI.n := 5;
  pFalseE := sqlite3ExprAlloc(db, TK_TRUEFALSE, @tokI, 0);
  pFalseE^.flags := pFalseE^.flags or EP_IsFalse;
  Check('EINT3 TK_TRUEFALSE false is not-true',
        sqlite3ExprIsNotTrue(pFalseE) = 1);

  { TK_INTEGER 0 → not-true; TK_INTEGER 1 → true. }
  pZero := sqlite3ExprInt32(db, 0);
  pOne  := sqlite3ExprInt32(db, 1);
  Check('EINT4 integer 0 is not-true', sqlite3ExprIsNotTrue(pZero) = 1);
  Check('EINT5 integer 1 is true',     sqlite3ExprIsNotTrue(pOne)  = 0);

  { sqlite3ExprIsIIF — TK_CASE with two-element pList → IIF. }
  pCaseList := sqlite3ExprListAppend(@parse, nil, sqlite3ExprInt32(db, 1));
  pCaseList := sqlite3ExprListAppend(@parse, pCaseList, sqlite3ExprInt32(db, 2));
  pCase2arg := sqlite3ExprAlloc(db, TK_CASE, nil, 0);
  pCase2arg^.x.pList := pCaseList;
  Check('EIIF1 TK_CASE 2-arg is IIF', sqlite3ExprIsIIF(db, pCase2arg) = 1);

  { TK_CASE with pLeft set → not IIF. }
  pCase2arg^.pLeft := sqlite3ExprInt32(db, 0);
  Check('EIIF2 TK_CASE with pLeft is NOT IIF', sqlite3ExprIsIIF(db, pCase2arg) = 0);
  pCase2arg^.pLeft := nil;

  { TK_CASE with three-arg, ELSE = NULL → IIF. }
  pCaseList := sqlite3ExprListAppend(@parse, nil, sqlite3ExprInt32(db, 1));
  pCaseList := sqlite3ExprListAppend(@parse, pCaseList, sqlite3ExprInt32(db, 2));
  pCaseList := sqlite3ExprListAppend(@parse, pCaseList,
                  sqlite3ExprAlloc(db, TK_NULL, nil, 0));
  pCase3argNull := sqlite3ExprAlloc(db, TK_CASE, nil, 0);
  pCase3argNull^.x.pList := pCaseList;
  Check('EIIF3 TK_CASE 3-arg ELSE NULL is IIF',
        sqlite3ExprIsIIF(db, pCase3argNull) = 1);

  { TK_CASE three-arg ELSE 0 → IIF (literal 0 is not-true). }
  pCaseList := sqlite3ExprListAppend(@parse, nil, sqlite3ExprInt32(db, 1));
  pCaseList := sqlite3ExprListAppend(@parse, pCaseList, sqlite3ExprInt32(db, 2));
  pCaseList := sqlite3ExprListAppend(@parse, pCaseList, sqlite3ExprInt32(db, 0));
  pCase3argFalse := sqlite3ExprAlloc(db, TK_CASE, nil, 0);
  pCase3argFalse^.x.pList := pCaseList;
  Check('EIIF4 TK_CASE 3-arg ELSE 0 is IIF',
        sqlite3ExprIsIIF(db, pCase3argFalse) = 1);

  { TK_CASE three-arg ELSE non-zero → NOT IIF. }
  pCaseList := sqlite3ExprListAppend(@parse, nil, sqlite3ExprInt32(db, 1));
  pCaseList := sqlite3ExprListAppend(@parse, pCaseList, sqlite3ExprInt32(db, 2));
  pCaseList := sqlite3ExprListAppend(@parse, pCaseList, sqlite3ExprInt32(db, 5));
  pCase3argTrue := sqlite3ExprAlloc(db, TK_CASE, nil, 0);
  pCase3argTrue^.x.pList := pCaseList;
  Check('EIIF5 TK_CASE 3-arg ELSE 5 is NOT IIF',
        sqlite3ExprIsIIF(db, pCase3argTrue) = 0);

  { sqlite3ExprImpliesExpr — equivalent (compare path). }
  pColA := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColA^.iTable := 0; pColA^.iColumn := 1;
  pInt5 := sqlite3ExprInt32(db, 5);
  pEqA1 := sqlite3PExpr(@parse, TK_EQ, pColA, pInt5);

  pColA2 := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColA2^.iTable := 0; pColA2^.iColumn := 1;
  pInt5b := sqlite3ExprInt32(db, 5);
  pEqA2same := sqlite3PExpr(@parse, TK_EQ, pColA2, pInt5b);
  Check('EIE1 x=5 implies x=5 (compare path)',
        sqlite3ExprImpliesExpr(@parse, pEqA1, pEqA2same, -1) = 1);

  { TK_OR right-hand side: x=5 implies (x=5 OR y=7). }
  pColB := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColB^.iTable := 0; pColB^.iColumn := 2;
  pInt7 := sqlite3ExprInt32(db, 7);
  pEqB  := sqlite3PExpr(@parse, TK_EQ, pColB, pInt7);
  pColA2 := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColA2^.iTable := 0; pColA2^.iColumn := 1;
  pTmpInt5 := sqlite3ExprInt32(db, 5);
  pEqA2 := sqlite3PExpr(@parse, TK_EQ, pColA2, pTmpInt5);
  pOrAB := sqlite3PExpr(@parse, TK_OR, pEqA2, pEqB);
  Check('EIE2 x=5 implies (x=5 OR y=7) (TK_OR path)',
        sqlite3ExprImpliesExpr(@parse, pEqA1, pOrAB, -1) = 1);

  { TK_NOTNULL via exprImpliesNotNull: x=5 implies x NOTNULL. }
  pColC := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColC^.iTable := 0; pColC^.iColumn := 1;
  pNotnullC := sqlite3PExpr(@parse, TK_NOTNULL, pColC, nil);
  pColC2 := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColC2^.iTable := 0; pColC2^.iColumn := 1;
  pInt5c := sqlite3ExprInt32(db, 5);
  pEqC5 := sqlite3PExpr(@parse, TK_EQ, pColC2, pInt5c);
  Check('EIE3 x=5 implies x NOTNULL',
        sqlite3ExprImpliesExpr(@parse, pEqC5, pNotnullC, -1) = 1);

  { Mismatched columns: y=9 does NOT imply x=5. }
  pColUnequal := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColUnequal^.iTable := 0; pColUnequal^.iColumn := 9;
  pInt9 := sqlite3ExprInt32(db, 9);
  pEqU  := sqlite3PExpr(@parse, TK_EQ, pColUnequal, pInt9);
  Check('EIE4 y=9 does NOT imply x=5',
        sqlite3ExprImpliesExpr(@parse, pEqU, pEqA1, -1) = 0);

  { whereUsablePartialIndex — partial index predicate "x NOTNULL" gets
    served by a WHERE clause containing "x=5".  Build a tiny WhereClause
    whose only term is x=5, then ask whether a partial-index whose
    creation predicate is "x NOTNULL" is usable. }

  pTab := PTable2(sqlite3DbMallocZero(db, SizeOf(TTable)));
  zNm[0] := 't'; zNm[1] := #0;
  pTab^.zName := @zNm[0];
  pTab^.pSchema := db^.aDb[0].pSchema;
  pTab^.tnum := 2;
  pTab^.nCol := 2;
  pTab^.nNVCol := 2;
  pTab^.tabFlags := 0;
  pTab^.eTabType := TABTYP_NORM;
  pTab^.pIndex := nil;

  pSrcBuf := sqlite3DbMallocZero(db, SZ_SRCLIST_HEADER + SizeOf(TSrcItem));
  pSrc := PSrcList(pSrcBuf);
  pSrc^.nSrc := 1;
  pSrc^.nAlloc := 1;
  pItem := @SrcListItems(pSrc)[0];
  pItem^.pSTab := pTab;
  pItem^.iCursor := 0;
  pItem^.colUsed := Bitmask($3);
  parse.nTab := 1;

  pWInfo := PWhereInfo(sqlite3DbMallocZero(db, SizeOf(TWhereInfo)));
  if pWInfo = nil then begin WriteLn('FATAL: pWInfo'); Halt(2); end;
  pWInfo^.pParse := @parse;
  pWInfo^.pTabList := pSrc;

  pWC := @pWInfo^.sWC;
  sqlite3WhereClauseInit(pWC, pWInfo);

  { WHERE term:  t.col1 = 5  (analyzed via WhereSplit + ExprAnalyze). }
  pColMain := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColMain^.iTable := 0; pColMain^.iColumn := 1;
  pIntMain := sqlite3ExprInt32(db, 5);
  pEqMain  := sqlite3PExpr(@parse, TK_EQ, pColMain, pIntMain);
  sqlite3WhereSplit(pWC, pEqMain, TK_AND);

  { Partial-index predicate:  col1 NOTNULL.  Use iTable=-1 so the iTab
    parameter substitutes (per sqlite3ExprCompare semantics for partial
    indexes), and so the iTab=-1 sentinel call returns 0 — i.e. the
    predicate is truly conditional on the table being bound. }
  pColPart := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pColPart^.iTable := -1; pColPart^.iColumn := 1;
  pNotnullPart := sqlite3PExpr(@parse, TK_NOTNULL, pColPart, nil);
  Check('WUPI1 partial-idx "col1 NOTNULL" usable when WHERE has col1=5',
        whereUsablePartialIndex(0, 0, pWC, pNotnullPart) = 1);

  { Same partial predicate but JT_LTORJ → unconditional refusal. }
  Check('WUPI2 JT_LTORJ short-circuits to 0',
        whereUsablePartialIndex(0, JT_LTORJ, pWC, pNotnullPart) = 0);

  { Partial predicate that the WHERE term cannot prove (col1 = 99). }
  pPartCol := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  pPartCol^.iTable := -1; pPartCol^.iColumn := 1;
  pPart5 := sqlite3ExprInt32(db, 99);
  pPartEq := sqlite3PExpr(@parse, TK_EQ, pPartCol, pPart5);
  Check('WUPI3 partial-idx "col1=99" NOT usable when WHERE has col1=5',
        whereUsablePartialIndex(0, 0, pWC, pPartEq) = 0);
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
  TestRangeVectorLen;
  TestIndexHelpers;
  TestWhereIsCoveringIndex;
  TestIndexedExprCleanup;
  TestPartIdxExprMask;
  TestWhereRangeAdjust;
  TestConstraintCompatOuterJoin;
  TestColumnIsGoodIndexCandidate;
  TestTermCanDriveIndex;
  TestTermCanDriveIndexGate;
  TestExprImplies;
  WriteLn('---- ', gPass, '/', gPass + gFail, ' passed ----');
  if gFail > 0 then Halt(1);
end.
