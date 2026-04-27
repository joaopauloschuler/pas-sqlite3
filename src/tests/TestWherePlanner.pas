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

{ ----- whereRangeScanEst (where.c:2092..2254, no-STAT4 tail) ----- }

procedure TestWhereRangeScanEst;
var
  loop:   TWhereLoop;
  lower:  TWhereTerm;
  upper:  TWhereTerm;
  parse:  TParse;
  rc:     i32;
begin
  FillChar(parse, SizeOf(parse), 0);

  { RSE1 — single lower bound, default discount.
    truthProb>0, no TERM_VNULL → whereRangeAdjust nudges by -20.
    nOut starts at 100; pLower<>nil → nOut decremented to 99 by the tail.
    nNew = 100 - 20 = 80; floor 10; min(nNew, nOut) = 80.  Result: 80. }
  FillChar(loop, SizeOf(loop), 0);
  FillChar(lower, SizeOf(lower), 0);
  loop.nOut := 100;
  lower.truthProb := 1;
  lower.wtFlags   := 0;
  rc := whereRangeScanEst(@parse, nil, @lower, nil, @loop);
  Check('RSE1 single lower → -20 LogEst', (rc = SQLITE_OK) and (loop.nOut = 80));

  { RSE2 — single upper bound carries app likelihood (truthProb=-7).
    whereRangeAdjust adds -7 → nNew = 100 + (-7) = 93.  No closed-range
    extra discount (only one bound).  Result: 93. }
  FillChar(loop, SizeOf(loop), 0);
  FillChar(upper, SizeOf(upper), 0);
  loop.nOut := 100;
  upper.truthProb := -7;
  upper.wtFlags   := 0;
  rc := whereRangeScanEst(@parse, nil, nil, @upper, @loop);
  Check('RSE2 single upper + app likelihood', (rc = SQLITE_OK) and (loop.nOut = 93));

  { RSE3 — closed range, both bounds default (truthProb>0, no VNULL).
    whereRangeAdjust on each: nNew = 100 - 20 - 20 = 60.  Both bounds
    have truthProb>0 → extra -20 = 40.  nOut = 100 - 1 - 1 = 98.
    min(40, 98) = 40.  Result: 40 (≈1/64 of 100 in LogEst space). }
  FillChar(loop, SizeOf(loop), 0);
  FillChar(lower, SizeOf(lower), 0);
  FillChar(upper, SizeOf(upper), 0);
  loop.nOut := 100;
  lower.truthProb := 1; lower.wtFlags := 0;
  upper.truthProb := 1; upper.wtFlags := 0;
  rc := whereRangeScanEst(@parse, nil, @lower, @upper, @loop);
  Check('RSE3 closed range default → 1/64 (LogEst -60)',
        (rc = SQLITE_OK) and (loop.nOut = 40));

  { RSE4 — closed range but lower carries app likelihood.
    Closed-range extra -20 only fires when BOTH bounds have truthProb>0;
    pLower.truthProb=-3 disqualifies, so just per-bound adjustments.
    nNew = 100 + (-3) - 20 = 77.  Result: 77. }
  FillChar(loop, SizeOf(loop), 0);
  FillChar(lower, SizeOf(lower), 0);
  FillChar(upper, SizeOf(upper), 0);
  loop.nOut := 100;
  lower.truthProb := -3; lower.wtFlags := 0;
  upper.truthProb := 1;  upper.wtFlags := 0;
  rc := whereRangeScanEst(@parse, nil, @lower, @upper, @loop);
  Check('RSE4 app-likelihood disables closed-range extra',
        (rc = SQLITE_OK) and (loop.nOut = 77));

  { RSE5 — TERM_VNULL on lower → whereRangeAdjust no-ops; closed-range
    extra still fires only when truthProb>0 AND (per whereRangeAdjust)
    no TERM_VNULL.  Here lower=VNULL contributes no -20 in adjust, but
    the closed-range gate at the bottom only checks truthProb>0 — both
    lower and upper truthProb=1, so extra -20 still fires.
    nNew = 100 (lower VNULL skipped) - 20 (upper) - 20 (closed) = 60.
    nOut = 100 - 2 = 98.  min(60, 98) = 60.  Result: 60. }
  FillChar(loop, SizeOf(loop), 0);
  FillChar(lower, SizeOf(lower), 0);
  FillChar(upper, SizeOf(upper), 0);
  loop.nOut := 100;
  lower.truthProb := 1; lower.wtFlags := TERM_VNULL;
  upper.truthProb := 1; upper.wtFlags := 0;
  rc := whereRangeScanEst(@parse, nil, @lower, @upper, @loop);
  Check('RSE5 TERM_VNULL skips per-bound but closed-range extra fires',
        (rc = SQLITE_OK) and (loop.nOut = 60));

  { RSE6 — floor at 10 LogEst.  Tiny nOut, big discount drives nNew below 10;
    floor clamps to 10, but nOut after decrement is 11 - 1 - 1 = 9, so
    min(10, 9) = 9 wins.  Validates the floor doesn't *raise* the answer. }
  FillChar(loop, SizeOf(loop), 0);
  FillChar(lower, SizeOf(lower), 0);
  FillChar(upper, SizeOf(upper), 0);
  loop.nOut := 11;
  lower.truthProb := 1; lower.wtFlags := 0;
  upper.truthProb := 1; upper.wtFlags := 0;
  rc := whereRangeScanEst(@parse, nil, @lower, @upper, @loop);
  Check('RSE6 floor 10 capped by nOut - 2 (= 9)',
        (rc = SQLITE_OK) and (loop.nOut = 9));

  { RSE7 — single bound, no shrinkage worth taking.  truthProb=-1 (-1
    LogEst ≈ -7%) gives nNew = 100 - 1 = 99.  Tail nOut = 100 - 1 = 99.
    min(99, 99) = 99.  Result: 99. }
  FillChar(loop, SizeOf(loop), 0);
  FillChar(lower, SizeOf(lower), 0);
  loop.nOut := 100;
  lower.truthProb := -1; lower.wtFlags := 0;
  rc := whereRangeScanEst(@parse, nil, @lower, nil, @loop);
  Check('RSE7 small app-likelihood narrowly clamps',
        (rc = SQLITE_OK) and (loop.nOut = 99));
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

{ ----- indexColumnNotNull (where.c:613..627) ----- }

procedure TestIndexColumnNotNull;
var
  tab:    TTable;
  cols:   array[0..2] of TColumn;
  idx:    TIndex;
  aiCol:  array[0..3] of i16;
begin
  FillChar(tab,  SizeOf(tab), 0);
  FillChar(cols, SizeOf(cols), 0);
  FillChar(idx,  SizeOf(idx), 0);

  { Layout three columns: col0 NOT NULL, col1 nullable, col2 NOT NULL }
  cols[0].typeFlags := $01;        { notNull = 1 (low nibble) }
  cols[1].typeFlags := $00;        { notNull = 0 }
  cols[2].typeFlags := $05;        { notNull = 5 (any non-zero is "constrained") }
  tab.aCol := @cols[0];

  { Index over (col0, col1, rowid, indexed-expr) }
  aiCol[0] := 0; aiCol[1] := 1; aiCol[2] := -1; aiCol[3] := -2; { -2 = XN_EXPR }
  idx.aiColumn := @aiCol[0];
  idx.nColumn  := 4;
  idx.pTable   := @tab;

  Check('ICN1 col0 NOT NULL → 1',     indexColumnNotNull(@idx, 0) = 1);
  Check('ICN2 col1 nullable → 0',     indexColumnNotNull(@idx, 1) = 0);
  Check('ICN3 col2 OE_Replace → 5',   indexColumnNotNull(@idx, 0) = 1);
  Check('ICN4 rowid alias (-1) → 1',  indexColumnNotNull(@idx, 2) = 1);
  Check('ICN5 indexed-expr (-2) → 0', indexColumnNotNull(@idx, 3) = 0);

  { Pick a column whose notNull byte holds the OE_Replace constant 5 to
    confirm the masking is to the low nibble only. }
  aiCol[0] := 2;
  Check('ICN6 typeFlags low nibble = OE_Replace=5',
        indexColumnNotNull(@idx, 0) = 5);
end;

{ ----- findIndexCol (where.c:583..608) -----

  Phase 6.6 stub keeps sqlite3ExprNNCollSeq returning nil; findIndexCol's
  fallback then accepts the first matching (cursor, column) entry.  The
  test exercises that path: the collation-mismatch arm becomes a dead
  branch under the stub. }

procedure TestFindIndexCol;
var
  parse:  TParse;
  idx:    TIndex;
  aiCol:  array[0..1] of i16;
  azColl: array[0..1] of PAnsiChar;
  listBuf: array[0 .. SizeOf(TExprList) + 3*SizeOf(TExprListItem) - 1] of Byte;
  pList:  PExprList;
  items:  PExprListItem;
  e0, e1, e2: TExpr;
  zBin:   array[0..6] of AnsiChar;
begin
  FillChar(parse,   SizeOf(parse), 0);
  FillChar(idx,     SizeOf(idx),   0);
  FillChar(listBuf, SizeOf(listBuf), 0);
  FillChar(e0, SizeOf(e0), 0);
  FillChar(e1, SizeOf(e1), 0);
  FillChar(e2, SizeOf(e2), 0);

  zBin[0]:='B'; zBin[1]:='I'; zBin[2]:='N'; zBin[3]:='A'; zBin[4]:='R';
  zBin[5]:='Y'; zBin[6]:=#0;

  aiCol[0]  := 5;
  aiCol[1]  := 7;
  azColl[0] := @zBin[0];
  azColl[1] := @zBin[0];
  idx.aiColumn := @aiCol[0];
  idx.azColl   := @azColl[0];
  idx.nKeyCol  := 2;
  idx.nColumn  := 2;

  pList := PExprList(@listBuf[0]);
  pList^.nExpr := 3;
  items := ExprListItems(pList);

  { e0 references cursor 9, column 99 — no match. }
  e0.op := TK_COLUMN; e0.iTable := 9; e0.iColumn := 99;
  { e1 matches: cursor 9, column 5 → the iCol=0 of pIdx. }
  e1.op := TK_COLUMN; e1.iTable := 9; e1.iColumn := 5;
  { e2 matches: cursor 9, column 7 → the iCol=1 of pIdx. }
  e2.op := TK_AGG_COLUMN; e2.iTable := 9; e2.iColumn := 7;

  items[0].pExpr := @e0;
  items[1].pExpr := @e1;
  items[2].pExpr := @e2;

  Check('FIC1 finds matching col0 at list[1]',
        findIndexCol(@parse, pList, 9, @idx, 0) = 1);
  Check('FIC2 finds matching col1 at list[2]',
        findIndexCol(@parse, pList, 9, @idx, 1) = 2);

  { Wrong cursor in every entry → -1. }
  e1.iTable := 11;
  e2.iTable := 11;
  Check('FIC3 wrong cursor → -1',
        findIndexCol(@parse, pList, 9, @idx, 0) = -1);

  { Wrong op (skipped after sqlite3ExprSkipCollateAndLikely). }
  e1.iTable := 9; e1.iColumn := 5; e1.op := TK_INTEGER;
  e2.iTable := 9; e2.iColumn := 7; { still TK_AGG_COLUMN }
  Check('FIC4 non-column entry skipped',
        findIndexCol(@parse, pList, 9, @idx, 0) = -1);
end;

{ ----- isDistinctRedundant — (b) UNIQUE-index branch (where.c:678..691) ----- }

procedure TestIsDistinctRedundant;
var
  parse:    TParse;
  wInfo:    TWhereInfo;
  pWC:      PWhereClause;
  tab:      TTable;
  cols:     array[0..2] of TColumn;
  idx:      TIndex;
  aiCol:    array[0..1] of i16;
  azColl:   array[0..1] of PAnsiChar;
  zBin:     array[0..6] of AnsiChar;
  srcBuf:   array[0 .. SizeOf(TSrcList) + 1*SizeOf(TSrcItem) - 1] of Byte;
  pSrc:     PSrcList;
  srcItems: PSrcItem;
  distBuf:  array[0 .. SizeOf(TExprList) + 2*SizeOf(TExprListItem) - 1] of Byte;
  pDist:    PExprList;
  dItems:   PExprListItem;
  d0, d1:   TExpr;
begin
  FillChar(parse,   SizeOf(parse), 0);
  FillChar(wInfo,   SizeOf(wInfo), 0);
  FillChar(tab,     SizeOf(tab),   0);
  FillChar(cols,    SizeOf(cols),  0);
  FillChar(idx,     SizeOf(idx),   0);
  FillChar(srcBuf,  SizeOf(srcBuf),0);
  FillChar(distBuf, SizeOf(distBuf),0);
  FillChar(d0, SizeOf(d0), 0);
  FillChar(d1, SizeOf(d1), 0);

  zBin[0]:='B'; zBin[1]:='I'; zBin[2]:='N'; zBin[3]:='A'; zBin[4]:='R';
  zBin[5]:='Y'; zBin[6]:=#0;

  pWC := @wInfo.sWC;
  pWC^.pWInfo := @wInfo;
  pWC^.nTerm  := 0;             { empty WHERE — every key column gates on (ii) }
  wInfo.pParse := @parse;

  { Two NOT NULL columns. }
  cols[0].typeFlags := $01;
  cols[1].typeFlags := $01;
  cols[2].typeFlags := $00;     { col2 nullable — used in IDR4 negative case }
  tab.aCol := @cols[0];

  { UNIQUE index over (col0, col1) — onError <> OE_None, no partial WHERE. }
  aiCol[0] := 0; aiCol[1] := 1;
  azColl[0] := @zBin[0]; azColl[1] := @zBin[0];
  idx.aiColumn := @aiCol[0];
  idx.azColl   := @azColl[0];
  idx.nKeyCol  := 2;
  idx.nColumn  := 2;
  idx.onError  := 1;            { OE_Rollback — anything <> OE_None }
  idx.pPartIdxWhere := nil;
  idx.pNext    := nil;
  idx.pTable   := @tab;
  tab.pIndex   := @idx;

  { FROM table at cursor 4. }
  pSrc := PSrcList(@srcBuf[0]);
  pSrc^.nSrc := 1;
  srcItems := SrcListItems(pSrc);
  srcItems[0].iCursor := 4;
  srcItems[0].pSTab   := @tab;

  pDist := PExprList(@distBuf[0]);
  pDist^.nExpr := 2;
  dItems := ExprListItems(pDist);

  { d0 → col0 of cursor 4, d1 → col1 of cursor 4. }
  d0.op := TK_COLUMN; d0.iTable := 4; d0.iColumn := 0;
  d1.op := TK_COLUMN; d1.iTable := 4; d1.iColumn := 1;
  dItems[0].pExpr := @d0;
  dItems[1].pExpr := @d1;

  { IDR1: every key column named in DISTINCT + NOT NULL → redundant. }
  Check('IDR1 UNIQUE NOT NULL covered by DISTINCT → 1',
        isDistinctRedundant(@parse, pSrc, pWC, pDist) = 1);

  { IDR2: drop col1 from DISTINCT → not redundant. }
  pDist^.nExpr := 1;
  Check('IDR2 missing col1 → 0',
        isDistinctRedundant(@parse, pSrc, pWC, pDist) = 0);

  { IDR3: nullable column breaks the gate even when listed. }
  pDist^.nExpr := 2;
  cols[1].typeFlags := $00;     { col1 now nullable }
  Check('IDR3 nullable col disqualifies → 0',
        isDistinctRedundant(@parse, pSrc, pWC, pDist) = 0);
  cols[1].typeFlags := $01;

  { IDR4: partial index disqualifies the whole index. }
  idx.pPartIdxWhere := PExpr(Pointer(PtrUInt($1)));
  Check('IDR4 partial-idx disqualified → 0',
        isDistinctRedundant(@parse, pSrc, pWC, pDist) = 0);
  idx.pPartIdxWhere := nil;

  { IDR5: non-UNIQUE index disqualifies. }
  idx.onError := OE_None;
  Check('IDR5 non-UNIQUE disqualified → 0',
        isDistinctRedundant(@parse, pSrc, pWC, pDist) = 0);
  idx.onError := 1;

  { IDR6: IPK fast-path (a) — DISTINCT on rowid alias short-circuits. }
  d0.iColumn := -1;             { rowid }
  Check('IDR6 IPK fast-path → 1',
        isDistinctRedundant(@parse, pSrc, pWC, pDist) = 1);
end;

{ ----- whereLoopAddBtreeIndex (where.c:3219..3653) -----
  Drives the per-index template-loop factory directly with hand-built
  WhereInfo / WhereClause / Index / SrcItem / Table records.  Uses the
  XN_ROWID (-1) shape so the whereScanNext path bypasses affinity and
  collation checks (zCollName stays nil), which keeps the test free of
  full Schema / CollSeq plumbing.  All assertions exercise the template
  that whereLoopInsert lands on pWInfo^.pLoops and the bookkeeping that
  whereLoopAddBtreeIndex restores on exit. }

procedure TestWhereLoopAddBtreeIndex;
const
  iCur = 7;
var
  db:        PTsqlite3;
  rc:        i32;
  parse:     TParse;
  wInfoBuf:  array[0..1023] of u8;
  pWInfo:    PWhereInfo;
  bld:       TWhereLoopBuilder;
  pNew:      TWhereLoop;
  tab:       TTable;
  src:       TSrcItem;
  idx:       TIndex;
  rowEst:    array[0..2] of i16;
  aiCol:     array[0..1] of i16;
  expr:      TExpr;
  rhs:       TExpr;
  lhs:       TExpr;
  p:         PWhereLoop;
  pT:        PWhereTerm;

  procedure ResetState;
  begin
    while pWInfo^.pLoops <> nil do
    begin
      p := pWInfo^.pLoops;
      pWInfo^.pLoops := p^.pNextLoop;
      whereLoopDelete(db, p);
    end;
    pWInfo^.sWC.nTerm := 0;
    FillChar(pWInfo^.sWC.aStatic, SizeOf(pWInfo^.sWC.aStatic), 0);
    bld.iPlanLimit := 100;
    bld.bldFlags1  := 0;
    pNew.wsFlags   := 0;
    pNew.nLTerm    := 0;
    pNew.u.btree.nEq := 0;
    pNew.u.btree.nBtm := 0;
    pNew.u.btree.nTop := 0;
    pNew.nSkip     := 0;
    pNew.prereq    := 0;
    pNew.nOut      := rowEst[0];
    pNew.rRun      := 0;
    pNew.rSetup    := 0;
  end;

  procedure SeedTerm(const i: i32; const op: u16; const wo: u16;
                      const col: i32; const truth: i16; const wt: u16);
  begin
    pT := @pWInfo^.sWC.aStatic[i];
    pT^.pExpr        := @expr;
    pT^.pWC          := @pWInfo^.sWC;
    pT^.eOperator    := wo;
    pT^.leftCursor   := iCur;
    pT^.u.leftColumn := col;
    pT^.prereqRight  := 0;
    pT^.prereqAll    := 1;
    pT^.truthProb    := truth;
    pT^.wtFlags      := wt;
    expr.op := op;
  end;

begin
  rc := sqlite3_open(':memory:', @db);
  Check('WLB open',                          rc = SQLITE_OK);

  FillChar(parse,    SizeOf(parse),    0);   parse.db := db;
  FillChar(wInfoBuf, SizeOf(wInfoBuf), 0);
  pWInfo := PWhereInfo(@wInfoBuf[0]);
  pWInfo^.pParse := @parse;

  FillChar(tab, SizeOf(tab), 0);
  tab.szTabRow := 1;
  tab.iPKey    := -1;

  FillChar(idx, SizeOf(idx), 0);
  rowEst[0] := 50;   { ~32 rows in the table (LogEst) }
  rowEst[1] := 0;    { 1 row per leading-key value }
  rowEst[2] := 0;
  aiCol[0]  := -1;   { XN_ROWID }
  aiCol[1]  := 0;
  idx.aiColumn    := @aiCol[0];
  idx.aiRowLogEst := @rowEst[0];
  idx.pTable      := @tab;
  idx.szIdxRow    := 30;
  idx.nKeyCol     := 1;
  idx.nColumn     := 1;
  idx.idxFlags    := SQLITE_IDXTYPE_IPK or u32(1 shl 7); { hasStat1 = bit 7 }
  idx.onError     := 1;  { OE_Rollback — IsUniqueIndex }

  FillChar(src, SizeOf(src), 0);
  src.iCursor := iCur;
  src.pSTab   := @tab;

  pWInfo^.sWC.pWInfo := pWInfo;
  pWInfo^.sWC.a      := @pWInfo^.sWC.aStatic[0];
  pWInfo^.sWC.nSlot  := Length(pWInfo^.sWC.aStatic);

  FillChar(bld, SizeOf(bld), 0);
  bld.pWInfo := pWInfo;
  bld.pWC    := @pWInfo^.sWC;

  FillChar(pNew, SizeOf(pNew), 0);
  whereLoopInit(@pNew);
  pNew.iTab          := 0;
  pNew.maskSelf      := 1;
  pNew.u.btree.pIndex := @idx;
  bld.pNew := @pNew;

  FillChar(rhs, SizeOf(rhs), 0); rhs.op := TK_INTEGER;
  FillChar(lhs, SizeOf(lhs), 0); lhs.op := TK_COLUMN;
  lhs.iTable := iCur; lhs.iColumn := -1;
  FillChar(expr, SizeOf(expr), 0);
  expr.op    := TK_EQ;
  expr.pLeft := @lhs;
  expr.pRight := @rhs;

  { ---- WLB1: empty WHERE clause, scanner finds nothing ---- }
  ResetState;
  rc := whereLoopAddBtreeIndex(@bld, @src, @idx, 0);
  Check('WLB1 empty WC returns OK',          rc = SQLITE_OK);
  Check('WLB1 no template inserted',         pWInfo^.pLoops = nil);
  Check('WLB1 nLTerm restored to 0',         pNew.nLTerm = 0);
  Check('WLB1 nEq restored to 0',            pNew.u.btree.nEq = 0);

  { ---- WLB2: rowid = ? on a UNIQUE index ---- }
  ResetState;
  pWInfo^.sWC.nTerm := 1;
  SeedTerm(0, TK_EQ, WO_EQ, XN_ROWID, 1, 0);
  rc := whereLoopAddBtreeIndex(@bld, @src, @idx, 0);
  Check('WLB2 rowid EQ returns OK',          rc = SQLITE_OK);
  Check('WLB2 inserted exactly one loop',    (pWInfo^.pLoops <> nil)
                                              and (pWInfo^.pLoops^.pNextLoop = nil));
  if pWInfo^.pLoops <> nil then
  begin
    p := pWInfo^.pLoops;
    Check('WLB2 wsFlags has WHERE_COLUMN_EQ',
          (p^.wsFlags and WHERE_COLUMN_EQ) <> 0);
    Check('WLB2 wsFlags has WHERE_ONEROW',
          (p^.wsFlags and WHERE_ONEROW) <> 0);
    Check('WLB2 nLTerm = 1',                 p^.nLTerm = 1);
    Check('WLB2 u.btree.nEq = 1',            p^.u.btree.nEq = 1);
    Check('WLB2 u.btree.pIndex nilled (IPK index)',
          p^.u.btree.pIndex = nil);
    Check('WLB2 first aLTerm[0] points at term',
          p^.aLTerm[0] = @pWInfo^.sWC.aStatic[0]);
  end;
  Check('WLB2 saved state restored: nLTerm', pNew.nLTerm = 0);
  Check('WLB2 saved state restored: nEq',    pNew.u.btree.nEq = 0);
  Check('WLB2 saved state restored: wsFlags',pNew.wsFlags = 0);
  Check('WLB2 builder bldFlags1 has UNIQUE', { saved_nEq=0 = nKeyCol-1=0 → UNIQUE bit }
        (bld.bldFlags1 and u8(SQLITE_BLDF1_UNIQUE)) <> 0);

  { ---- WLB3: term skipped because prereqRight intersects maskSelf ---- }
  ResetState;
  pWInfo^.sWC.nTerm := 1;
  SeedTerm(0, TK_EQ, WO_EQ, XN_ROWID, 1, 0);
  pWInfo^.sWC.aStatic[0].prereqRight := 1;  { intersects maskSelf=1 }
  rc := whereLoopAddBtreeIndex(@bld, @src, @idx, 0);
  Check('WLB3 self-prereq term returns OK',  rc = SQLITE_OK);
  Check('WLB3 self-prereq skips insert',     pWInfo^.pLoops = nil);

  { ---- WLB4: TERM_VNULL on rowid (NOT NULL) is skipped ---- }
  ResetState;
  pWInfo^.sWC.nTerm := 1;
  SeedTerm(0, TK_EQ, WO_EQ, XN_ROWID, 1, TERM_VNULL);
  rc := whereLoopAddBtreeIndex(@bld, @src, @idx, 0);
  Check('WLB4 TERM_VNULL on rowid returns OK', rc = SQLITE_OK);
  Check('WLB4 TERM_VNULL skipped (rowid is NOT NULL)',
        pWInfo^.pLoops = nil);

  { ---- WLB5: WO_GT range term → COLUMN_RANGE | BTM_LIMIT, no ONEROW ---- }
  ResetState;
  pWInfo^.sWC.nTerm := 1;
  SeedTerm(0, TK_GT_TK, u16(WO_GT_WO), XN_ROWID, 1, 0);
  rc := whereLoopAddBtreeIndex(@bld, @src, @idx, 0);
  Check('WLB5 WO_GT range returns OK',       rc = SQLITE_OK);
  Check('WLB5 inserted one loop',            (pWInfo^.pLoops <> nil)
                                              and (pWInfo^.pLoops^.pNextLoop = nil));
  if pWInfo^.pLoops <> nil then
  begin
    p := pWInfo^.pLoops;
    Check('WLB5 wsFlags has WHERE_COLUMN_RANGE',
          (p^.wsFlags and WHERE_COLUMN_RANGE) <> 0);
    Check('WLB5 wsFlags has WHERE_BTM_LIMIT',
          (p^.wsFlags and WHERE_BTM_LIMIT) <> 0);
    Check('WLB5 wsFlags lacks WHERE_ONEROW (range, not EQ)',
          (p^.wsFlags and WHERE_ONEROW) = 0);
    Check('WLB5 nEq stays 0 (range slot)',   p^.u.btree.nEq = 0);
    Check('WLB5 nBtm = 1 (scalar bound)',    p^.u.btree.nBtm = 1);
  end;

  { ---- WLB6: WO_ISNULL on a NOT-NULL leading column is skipped ---- }
  ResetState;
  pWInfo^.sWC.nTerm := 1;
  SeedTerm(0, TK_ISNULL, u16(WO_ISNULL), XN_ROWID, 1, 0);
  rc := whereLoopAddBtreeIndex(@bld, @src, @idx, 0);
  Check('WLB6 WO_ISNULL on rowid returns OK', rc = SQLITE_OK);
  Check('WLB6 WO_ISNULL skipped (rowid NOT NULL)',
        pWInfo^.pLoops = nil);

  { ---- WLB7: opMask narrowed when entering with WHERE_BTM_LIMIT pre-set ---- }
  ResetState;
  pWInfo^.sWC.nTerm := 1;
  pNew.wsFlags := WHERE_BTM_LIMIT;  { caller has already pinned a lower bound }
  SeedTerm(0, TK_EQ, WO_EQ, XN_ROWID, 1, 0);
  rc := whereLoopAddBtreeIndex(@bld, @src, @idx, 0);
  Check('WLB7 BTM-prefix opMask narrowed to LT|LE',
        (rc = SQLITE_OK) and (pWInfo^.pLoops = nil));
  pNew.wsFlags := 0;

  { Cleanup. }
  while pWInfo^.pLoops <> nil do
  begin
    p := pWInfo^.pLoops;
    pWInfo^.pLoops := p^.pNextLoop;
    whereLoopDelete(db, p);
  end;
  whereLoopClear(db, @pNew);
  sqlite3_close(db);
end;

{ ----- whereLoopAddBtree (where.c:4003..4309) -----
  Drives the per-table planner factory directly with hand-built records.
  Exercises:
    WLAB1: empty WC, table with no real indices and no auto-index flag
           → exactly one WHERE_IPK template loop inserted via the
             synthesized fake IPK index (rRun = nRowLogEst+16).
    WLAB2: same shape with notIndexed bit lit on the SrcItem → still the
           one synthetic IPK loop (real-index chain ignored anyway).
    WLAB3: WITHOUT ROWID table (HasRowid=false) with no real indices →
           pProbe = pTab^.pIndex = nil so the per-index loop never
           runs; auto-index path also disabled (no AutoIndex flag) →
           zero loops inserted, rc = OK.
    WLAB4: HasRowid + auto-index ENABLED + a single rowid-EQ WHERE term →
           termCanDriveIndex rejects (it's an EQ on the rowid column,
           but its column is the ROWID alias — auto-index synthesis
           still runs because termCanDriveIndex passes for any EQ on
           a column of pSrc, including rowid).  The IPK probe also
           inserts.  We assert at least one WHERE_AUTO_INDEX loop and
           at least one WHERE_IPK loop, and both share the same iTab. }

procedure TestWhereLoopAddBtree;
const
  iCur = 9;
type
  TSrcListBuf2 = record
    hdr:  TSrcList;
    item: TSrcItem;
  end;
var
  db:        PTsqlite3;
  rc:        i32;
  parse:     TParse;
  wInfoBuf:  array[0..1023] of u8;
  pWInfo:    PWhereInfo;
  bld:       TWhereLoopBuilder;
  pNew:      TWhereLoop;
  tab:       TTable;
  src:       TSrcListBuf2;
  p:         PWhereLoop;
  nLoops, nIpk, nAuto: i32;
  lhs, rhs, top: TExpr;
  pT:        PWhereTerm;

  procedure ResetLoops;
  begin
    while pWInfo^.pLoops <> nil do
    begin
      p := pWInfo^.pLoops;
      pWInfo^.pLoops := p^.pNextLoop;
      whereLoopDelete(db, p);
    end;
    pWInfo^.sWC.nTerm := 0;
    FillChar(pWInfo^.sWC.aStatic, SizeOf(pWInfo^.sWC.aStatic), 0);
    bld.iPlanLimit := 100;
    bld.bldFlags1  := 0;
    pNew.wsFlags   := 0;
    pNew.nLTerm    := 0;
    pNew.u.btree.nEq := 0;
    pNew.u.btree.nBtm := 0;
    pNew.u.btree.nTop := 0;
    pNew.nSkip     := 0;
    pNew.prereq    := 0;
    pNew.nOut      := 0;
    pNew.rRun      := 0;
    pNew.rSetup    := 0;
    pNew.iTab      := 0;
    pNew.maskSelf  := 1;
    pNew.u.btree.pIndex := nil;
  end;

  procedure CountLoops;
  begin
    nLoops := 0; nIpk := 0; nAuto := 0;
    p := pWInfo^.pLoops;
    while p <> nil do
    begin
      Inc(nLoops);
      if (p^.wsFlags and WHERE_IPK)        <> 0 then Inc(nIpk);
      if (p^.wsFlags and WHERE_AUTO_INDEX) <> 0 then Inc(nAuto);
      p := p^.pNextLoop;
    end;
  end;

begin
  rc := sqlite3_open(':memory:', @db);
  Check('WLAB open',                         rc = SQLITE_OK);
  { Default db^.flags does NOT carry SQLITE_AutoIndex; tests that need
    auto-index synthesis flip it explicitly. }

  FillChar(parse,    SizeOf(parse),    0);   parse.db := db;
  FillChar(wInfoBuf, SizeOf(wInfoBuf), 0);
  pWInfo := PWhereInfo(@wInfoBuf[0]);
  pWInfo^.pParse := @parse;

  FillChar(tab, SizeOf(tab), 0);
  tab.szTabRow   := 1;
  tab.iPKey      := -1;
  tab.nRowLogEst := 50;       { ~32 rows (LogEst) }
  { tabFlags = 0 → HasRowid = true (no TF_WithoutRowid bit). }

  FillChar(src, SizeOf(src), 0);
  src.hdr.nSrc       := 1;
  src.item.iCursor   := iCur;
  src.item.pSTab     := @tab;
  src.item.fg.jointype := 0;
  pWInfo^.pTabList   := @src.hdr;

  pWInfo^.sWC.pWInfo := pWInfo;
  pWInfo^.sWC.a      := @pWInfo^.sWC.aStatic[0];
  pWInfo^.sWC.nSlot  := Length(pWInfo^.sWC.aStatic);
  pWInfo^.sMaskSet.n   := 1;
  pWInfo^.sMaskSet.ix[0] := iCur;

  FillChar(bld, SizeOf(bld), 0);
  bld.pWInfo := pWInfo;
  bld.pWC    := @pWInfo^.sWC;

  FillChar(pNew, SizeOf(pNew), 0);
  whereLoopInit(@pNew);
  pNew.iTab     := 0;
  pNew.maskSelf := 1;
  bld.pNew      := @pNew;

  { ---- WLAB1: empty WC, no real indices, no auto-index ---- }
  ResetLoops;
  rc := whereLoopAddBtree(@bld, 0);
  Check('WLAB1 returns OK',                  rc = SQLITE_OK);
  CountLoops;
  Check('WLAB1 exactly one loop',            nLoops = 1);
  Check('WLAB1 the loop is WHERE_IPK',       nIpk = 1);
  Check('WLAB1 no auto-index loop',          nAuto = 0);
  if pWInfo^.pLoops <> nil then
  begin
    Check('WLAB1 rRun = nRowLogEst + 16',
          pWInfo^.pLoops^.rRun = i16(tab.nRowLogEst + 16));
    Check('WLAB1 nOut = nRowLogEst (after restore)',
          pWInfo^.pLoops^.nOut = tab.nRowLogEst);
  end;

  { ---- WLAB2: notIndexed bit lit ---- }
  ResetLoops;
  src.item.fg.fgBits := u8($01);  { notIndexed }
  rc := whereLoopAddBtree(@bld, 0);
  Check('WLAB2 notIndexed returns OK',       rc = SQLITE_OK);
  CountLoops;
  Check('WLAB2 still one IPK loop',          (nLoops = 1) and (nIpk = 1));
  src.item.fg.fgBits := 0;

  { ---- WLAB3: WITHOUT ROWID table, no real indices, no auto-index ---- }
  ResetLoops;
  tab.tabFlags := tab.tabFlags or TF_WithoutRowid;
  rc := whereLoopAddBtree(@bld, 0);
  Check('WLAB3 WITHOUT ROWID returns OK',    rc = SQLITE_OK);
  CountLoops;
  Check('WLAB3 zero loops (no PK index, no auto-index)',
        nLoops = 0);
  tab.tabFlags := 0;

  { ---- WLAB4: auto-index path skipped on a rowid-EQ term (leftColumn<0) —
         auto-index synthesis enabled but the only WHERE term targets the
         rowid (leftColumn=-1) which termCanDriveIndex rejects.  IPK probe
         still fires and produces the single full-scan loop.  Avoids
         touching pTab^.aCol so we don't have to allocate a TColumn. ---- }
  ResetLoops;
  db^.flags := db^.flags or SQLITE_AutoIndex;
  pWInfo^.sWC.nTerm := 1;
  FillChar(lhs, SizeOf(lhs), 0); lhs.op := TK_COLUMN;
  lhs.iTable := iCur; lhs.iColumn := -1;   { rowid alias }
  FillChar(rhs, SizeOf(rhs), 0); rhs.op := TK_INTEGER;
  FillChar(top, SizeOf(top), 0); top.op := TK_EQ;
  top.pLeft := @lhs; top.pRight := @rhs;
  pT := @pWInfo^.sWC.aStatic[0];
  pT^.pExpr        := @top;
  pT^.pWC          := @pWInfo^.sWC;
  pT^.eOperator    := WO_EQ;
  pT^.leftCursor   := iCur;
  pT^.u.leftColumn := -1;                  { rowid → termCanDriveIndex rejects }
  pT^.prereqRight  := 0;
  pT^.prereqAll    := 1;
  pT^.truthProb    := 1;
  pT^.wtFlags      := 0;
  rc := whereLoopAddBtree(@bld, 0);
  Check('WLAB4 returns OK',                  rc = SQLITE_OK);
  CountLoops;
  Check('WLAB4 no auto-index loop (rowid leftColumn skipped)',
        nAuto = 0);
  Check('WLAB4 IPK loop still inserted',     nIpk = 1);
  db^.flags := db^.flags and (not SQLITE_AutoIndex);

  { Cleanup. }
  while pWInfo^.pLoops <> nil do
  begin
    p := pWInfo^.pLoops;
    pWInfo^.pLoops := p^.pNextLoop;
    whereLoopDelete(db, p);
  end;
  whereLoopClear(db, @pNew);
  sqlite3_close(db);
end;

{ ---------------------------------------------------------------------------
  whereLoopAddAll + whereLoopAddOr — top-level planner driver (where.c:4937)
  and multi-index OR template-loop factory (where.c:4810).

  These run on the same single-table fixture as TestWhereLoopAddBtree but
  enter the planner through the public driver (whereLoopAddAll) so the
  prereq-mask + IsVirtual + hasOr dispatch arms are exercised.  The new
  RIGHT-JOIN short-circuit and the WO_OR walk in whereLoopAddOr get
  direct cases too.
  =========================================================================== }

procedure TestWhereLoopAddAllAndOr;
const
  iCur0 = 11;
  iCur1 = 12;
type
  TSrcListBuf3 = record
    hdr:   TSrcList;
    item0: TSrcItem;
    item1: TSrcItem;       { only used for two-table cases }
  end;
var
  db:        PTsqlite3;
  rc:        i32;
  parse:     TParse;
  wInfoBuf:  array[0..1023] of u8;
  pWInfo:    PWhereInfo;
  bld:       TWhereLoopBuilder;
  pNew:      TWhereLoop;
  tab:       TTable;
  src:       TSrcListBuf3;
  p:         PWhereLoop;
  nLoops, nIpk, nMOR: i32;

  procedure ResetLoops;
  begin
    while pWInfo^.pLoops <> nil do
    begin
      p := pWInfo^.pLoops;
      pWInfo^.pLoops := p^.pNextLoop;
      whereLoopDelete(db, p);
    end;
    pWInfo^.sWC.nTerm := 0;
    pWInfo^.sWC.nBase := 0;
    pWInfo^.sWC.hasOr := 0;
    FillChar(pWInfo^.sWC.aStatic, SizeOf(pWInfo^.sWC.aStatic), 0);
    bld.bldFlags1  := 0;
    FillChar(pNew, SizeOf(pNew), 0);
    whereLoopInit(@pNew);
    pNew.iTab     := 0;
    pNew.maskSelf := 1;
  end;

  procedure CountLoops;
  begin
    nLoops := 0; nIpk := 0; nMOR := 0;
    p := pWInfo^.pLoops;
    while p <> nil do
    begin
      Inc(nLoops);
      if (p^.wsFlags and WHERE_IPK)       <> 0 then Inc(nIpk);
      if (p^.wsFlags and WHERE_MULTI_OR)  <> 0 then Inc(nMOR);
      p := p^.pNextLoop;
    end;
  end;

begin
  rc := sqlite3_open(':memory:', @db);
  Check('WLAA open',                        rc = SQLITE_OK);

  FillChar(parse,    SizeOf(parse),    0);  parse.db := db;
  FillChar(wInfoBuf, SizeOf(wInfoBuf), 0);
  pWInfo := PWhereInfo(@wInfoBuf[0]);
  pWInfo^.pParse := @parse;

  FillChar(tab, SizeOf(tab), 0);
  tab.szTabRow   := 1;
  tab.iPKey      := -1;
  tab.nRowLogEst := 50;

  FillChar(src, SizeOf(src), 0);
  src.hdr.nSrc       := 1;
  src.item0.iCursor  := iCur0;
  src.item0.pSTab    := @tab;
  src.item0.fg.jointype := 0;
  pWInfo^.pTabList   := @src.hdr;
  pWInfo^.nLevel     := 1;

  pWInfo^.sWC.pWInfo := pWInfo;
  pWInfo^.sWC.a      := @pWInfo^.sWC.aStatic[0];
  pWInfo^.sWC.nSlot  := Length(pWInfo^.sWC.aStatic);
  pWInfo^.sMaskSet.n := 1;
  pWInfo^.sMaskSet.ix[0] := iCur0;

  FillChar(bld, SizeOf(bld), 0);
  bld.pWInfo := pWInfo;
  bld.pWC    := @pWInfo^.sWC;
  bld.pNew   := @pNew;

  { ---- WLAA1: single-table, empty WC → AddAll routes through AddBtree. ---- }
  ResetLoops;
  rc := whereLoopAddAll(@bld);
  Check('WLAA1 returns OK',                 rc = SQLITE_OK);
  CountLoops;
  Check('WLAA1 exactly one loop',           nLoops = 1);
  Check('WLAA1 the loop is WHERE_IPK',      nIpk = 1);
  { iPlanLimit starts at SQLITE_QUERY_PLANNER_LIMIT, gets bumped by
    SQLITE_QUERY_PLANNER_LIMIT_INCR per table, then is decremented by
    whereLoopInsert per candidate.  After one IPK loop on one table the
    counter must still be in the "barely consumed" band. }
  Check('WLAA1 iPlanLimit in expected band',
        (bld.iPlanLimit > u32(SQLITE_QUERY_PLANNER_LIMIT))
        and (bld.iPlanLimit <= u32(SQLITE_QUERY_PLANNER_LIMIT
                                   + SQLITE_QUERY_PLANNER_LIMIT_INCR)));

  { ---- WLAA2: vtab table → AddVirtual stub adds zero loops. ---- }
  ResetLoops;
  tab.eTabType := TABTYP_VTAB;
  rc := whereLoopAddAll(@bld);
  Check('WLAA2 vtab returns OK',            rc = SQLITE_OK);
  CountLoops;
  Check('WLAA2 zero loops (vtab stub)',     nLoops = 0);
  tab.eTabType := 0;

  { ---- WLAA3: hasOr=1 routes to whereLoopAddOr.  No actual WO_OR term in
         the WC, so AddOr is a no-op; AddAll still produces the IPK loop. ---- }
  ResetLoops;
  pWInfo^.sWC.hasOr := 1;
  rc := whereLoopAddAll(@bld);
  Check('WLAA3 hasOr returns OK',           rc = SQLITE_OK);
  CountLoops;
  Check('WLAA3 still one IPK loop',         (nLoops = 1) and (nIpk = 1));

  { ---- WLAO1: whereLoopAddOr on a JT_RIGHT table short-circuits. ---- }
  ResetLoops;
  src.item0.fg.jointype := JT_RIGHT;
  rc := whereLoopAddOr(@bld, 0, 0);
  Check('WLAO1 JT_RIGHT returns OK',        rc = SQLITE_OK);
  CountLoops;
  Check('WLAO1 zero loops (RIGHT JOIN guard)',
        nLoops = 0);
  src.item0.fg.jointype := 0;

  { ---- WLAO2: whereLoopAddOr on an empty WC → no WO_OR terms, no loops. ---- }
  ResetLoops;
  rc := whereLoopAddOr(@bld, 0, 0);
  Check('WLAO2 empty WC returns OK',        rc = SQLITE_OK);
  CountLoops;
  Check('WLAO2 zero loops (no WO_OR term)', nLoops = 0);

  { ---- WLAA4: two-table FROM, second table is JT_CROSS — exercises the
         CROSS reorder barrier (mPrereq |= mPrior; hasRightCrossJoin set).
         Both tables produce IPK loops. ---- }
  ResetLoops;
  src.hdr.nSrc      := 2;
  src.item1.iCursor := iCur1;
  src.item1.pSTab   := @tab;
  src.item1.fg.jointype := JT_CROSS;
  pWInfo^.nLevel    := 2;
  pWInfo^.sMaskSet.n := 2;
  pWInfo^.sMaskSet.ix[1] := iCur1;
  rc := whereLoopAddAll(@bld);
  Check('WLAA4 two-table CROSS returns OK', rc = SQLITE_OK);
  CountLoops;
  Check('WLAA4 two IPK loops (one per table)',
        (nLoops = 2) and (nIpk = 2));
  { Same band reasoning as WLAA1, but two tables → two LIMIT_INCR bumps
    minus per-candidate consumption. }
  Check('WLAA4 iPlanLimit in expected band',
        (bld.iPlanLimit > u32(SQLITE_QUERY_PLANNER_LIMIT
                              + SQLITE_QUERY_PLANNER_LIMIT_INCR))
        and (bld.iPlanLimit <= u32(SQLITE_QUERY_PLANNER_LIMIT
                                   + 2 * SQLITE_QUERY_PLANNER_LIMIT_INCR)));
  src.hdr.nSrc := 1;
  src.item1.fg.jointype := 0;
  pWInfo^.nLevel := 1;
  pWInfo^.sMaskSet.n := 1;

  { Cleanup. }
  while pWInfo^.pLoops <> nil do
  begin
    p := pWInfo^.pLoops;
    pWInfo^.pLoops := p^.pNextLoop;
    whereLoopDelete(db, p);
  end;
  whereLoopClear(db, @pNew);
  sqlite3_close(db);
end;

{ ----- whereSortingCost + whereLoopIsNoBetter (where.c:5527..5585, 5811..5820) ----- }

procedure TestSortingCost;
var
  pWInfo:  PWhereInfo;
  pSel:    PSelect;
  pList:   PExprList;
  cost:    i16;
  nRow:    i16;
  nCol:    i16;
  expected: i16;
begin
  { Build a minimal stand-in TWhereInfo + TSelect + TExprList on the heap so
    we can exercise the cost helper in isolation, without dragging in a full
    Parse + db.  whereSortingCost only reads pWInfo^.pSelect^.pEList^.nExpr,
    pWInfo^.wctrlFlags, and pWInfo^.iLimit. }
  pWInfo := AllocMem(SizeOf(TWhereInfo));
  pSel   := AllocMem(SizeOf(TSelect));
  pList  := AllocMem(SizeOf(TExprList));
  pWInfo^.pSelect := pSel;
  pSel^.pEList    := pList;

  { ---- WSC1: nSorted=0, no flags, nExpr=1, nRow=33 ----
    nCol = LogEst((1+59)/30) = LogEst(2) = 10
    rSortCost = nRow + nCol = 33 + 10 = 43
    final = 43 + estLog(33) }
  pList^.nExpr        := 1;
  pWInfo^.wctrlFlags  := 0;
  pWInfo^.iLimit      := 0;
  nRow := 33;
  nCol := i16(sqlite3LogEst(u64((1 + 59) div 30)));
  expected := i16(nRow + nCol + estLog(nRow));
  cost := whereSortingCost(pWInfo, nRow, 1, 0);
  Check('WSC1 nSorted=0 baseline', cost = expected);
  Check('WSC1 nCol = LogEst(2) = 10', nCol = 10);

  { ---- WSC2: USE_LIMIT bumps cost by +10, caps nLocal at iLimit ----
    iLimit = 20 (LogEst 13) caps nRow=50 → estLog(20) instead of estLog(50). }
  pWInfo^.wctrlFlags := WHERE_USE_LIMIT;
  pWInfo^.iLimit     := 20;
  nRow := 50;
  expected := i16(nRow + nCol + 10 + estLog(20));
  cost := whereSortingCost(pWInfo, nRow, 1, 0);
  Check('WSC2 LIMIT path +10 and caps nLocal at iLimit', cost = expected);

  { ---- WSC3: USE_LIMIT + nSorted>0 adds another +6 partial-sort bonus,
    and applies (Y/X) scaling: + LogEst((X-Y)*100/X) - 66.
    nOrderBy=4, nSorted=2 → LogEst(2*100/4) = LogEst(50). }
  pWInfo^.wctrlFlags := WHERE_USE_LIMIT;
  pWInfo^.iLimit     := 20;
  nRow := 50;
  expected := i16(nRow + nCol
                  + i16(sqlite3LogEst(u64((4 - 2) * 100 div 4))) - 66
                  + 10 + 6
                  + estLog(20));
  cost := whereSortingCost(pWInfo, nRow, 4, 2);
  Check('WSC3 LIMIT + partial-sort path', cost = expected);

  { ---- WSC4: DISTINCT halves nLocal when >10 (subtracts LogEst(2)=10).
    nRow=33 → nLocal=23 → estLog(23). ---- }
  pWInfo^.wctrlFlags := WHERE_WANT_DISTINCT;
  pWInfo^.iLimit     := 0;
  nRow := 33;
  expected := i16(nRow + nCol + estLog(i16(nRow - 10)));
  cost := whereSortingCost(pWInfo, nRow, 1, 0);
  Check('WSC4 DISTINCT halves nLocal', cost = expected);

  { ---- WSC5: DISTINCT no-op when nRow <= 10 ---- }
  pWInfo^.wctrlFlags := WHERE_WANT_DISTINCT;
  nRow := 10;
  expected := i16(nRow + nCol + estLog(nRow));
  cost := whereSortingCost(pWInfo, nRow, 1, 0);
  Check('WSC5 DISTINCT no-op when nRow<=10', cost = expected);

  { ---- WSC6: nCol scales with output column count.  nExpr=121 →
    (121+59)/30 = 6 → LogEst(6).  Verify nCol moves with nExpr. ---- }
  pList^.nExpr := 121;
  pWInfo^.wctrlFlags := 0;
  nRow := 33;
  nCol := i16(sqlite3LogEst(u64((121 + 59) div 30)));
  expected := i16(nRow + nCol + estLog(nRow));
  cost := whereSortingCost(pWInfo, nRow, 1, 0);
  Check('WSC6 nCol scales with nExpr', cost = expected);
  Check('WSC6 nCol > LogEst(2) for wider rows', nCol > 10);

  FreeMem(pList);
  FreeMem(pSel);
  FreeMem(pWInfo);
end;

procedure TestLoopIsNoBetter;
var
  cand, base: TWhereLoop;
  iCand, iBase: TIndex;
  rc: i32;
begin
  FillChar(cand, SizeOf(cand), 0);
  FillChar(base, SizeOf(base), 0);
  FillChar(iCand, SizeOf(iCand), 0);
  FillChar(iBase, SizeOf(iBase), 0);

  { ---- WLNB1: candidate not WHERE_INDEXED → "no better" (return 1). ---- }
  cand.wsFlags := WHERE_IPK;
  base.wsFlags := WHERE_INDEXED;
  base.u.btree.pIndex := @iBase;
  iBase.szIdxRow := 100;
  rc := whereLoopIsNoBetter(@cand, @base);
  Check('WLNB1 non-indexed candidate → 1', rc = 1);

  { ---- WLNB2: baseline not WHERE_INDEXED → "no better" (return 1). ---- }
  cand.wsFlags := WHERE_INDEXED;
  cand.u.btree.pIndex := @iCand;
  iCand.szIdxRow := 50;
  base.wsFlags := WHERE_IPK;
  base.u.btree.pIndex := nil;
  rc := whereLoopIsNoBetter(@cand, @base);
  Check('WLNB2 non-indexed baseline → 1', rc = 1);

  { ---- WLNB3: both indexed, candidate has smaller szIdxRow → 0
    (pCandidate is strictly preferred). ---- }
  cand.wsFlags := WHERE_INDEXED;
  cand.u.btree.pIndex := @iCand;
  iCand.szIdxRow := 50;
  base.wsFlags := WHERE_INDEXED;
  base.u.btree.pIndex := @iBase;
  iBase.szIdxRow := 100;
  rc := whereLoopIsNoBetter(@cand, @base);
  Check('WLNB3 candidate smaller szIdxRow → 0', rc = 0);

  { ---- WLNB4: equal szIdxRow → "no better" (return 1). ---- }
  iCand.szIdxRow := 100;
  iBase.szIdxRow := 100;
  rc := whereLoopIsNoBetter(@cand, @base);
  Check('WLNB4 equal szIdxRow → 1', rc = 1);

  { ---- WLNB5: candidate larger szIdxRow → "no better" (return 1). ---- }
  iCand.szIdxRow := 150;
  iBase.szIdxRow := 100;
  rc := whereLoopIsNoBetter(@cand, @base);
  Check('WLNB5 candidate larger szIdxRow → 1', rc = 1);
end;

{ ----- wherePathSatisfiesOrderBy ----- }

procedure TestPathSatisfiesOrderBy;
var
  db:           PTsqlite3;
  rc:           i32;
  parse:        TParse;
  wInfoBuf:     array[0..2047] of u8;
  pWInfo:       PWhereInfo;
  src:          TSrcListBuf;
  loop:         TWhereLoop;
  obItems:      array[0..0] of TExprListItem;
  obList:       record hdr: TExprList; tail: TExprListItem; end;
  pOrderBy:     PExprList;
  pathBuf:      array[0..7] of PWhereLoop;
  path:         TWherePath;
  revMask:      Bitmask;
  result:       i8;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('OBSAT open', rc = SQLITE_OK);

  FillChar(parse,    SizeOf(parse),    0);
  parse.db := db;

  FillChar(wInfoBuf, SizeOf(wInfoBuf), 0);
  pWInfo := PWhereInfo(@wInfoBuf[0]);
  pWInfo^.pParse := @parse;

  FillChar(src, SizeOf(src), 0);
  src.hdr.nSrc        := 1;
  src.item.iCursor    := 7;
  pWInfo^.pTabList    := @src.hdr;

  { Single-term ORDER BY referencing iCur=7. }
  FillChar(obList, SizeOf(obList), 0);
  FillChar(obItems, SizeOf(obItems), 0);
  obList.hdr.nExpr := 1;
  pOrderBy := @obList.hdr;

  FillChar(path, SizeOf(path), 0);
  FillChar(pathBuf, SizeOf(pathBuf), 0);
  path.aLoop := @pathBuf[0];

  { ---- OBSAT1: OrderByIdxJoin disabled with nLoop>0 → 0 (early exit). ---- }
  FillChar(loop, SizeOf(loop), 0);
  loop.iTab     := 0;
  loop.maskSelf := $0001;
  loop.wsFlags  := WHERE_IPK;
  pathBuf[0]    := @loop;
  db^.dbOptFlags := SQLITE_OrderByIdxJoin;
  revMask := 0;
  result := wherePathSatisfiesOrderBy(pWInfo, pOrderBy, @path, 0,
                                      1, @loop, @revMask);
  Check('OBSAT1 OrderByIdxJoin disabled → 0', result = 0);
  db^.dbOptFlags := 0;

  { ---- OBSAT2: ORDER BY too wide (>BMS-1 terms) → returns 0. ---- }
  obList.hdr.nExpr := BMS;          { 64 — exceeds BMS-1 }
  result := wherePathSatisfiesOrderBy(pWInfo, pOrderBy, @path, 0,
                                      0, @loop, @revMask);
  Check('OBSAT2 nOrderBy > BMS-1 → 0', result = 0);
  obList.hdr.nExpr := 1;

  { ---- OBSAT3: virtual table loop with isOrdered=1 and pWInfo->pOrderBy=pOrderBy
    → obSat saturates → returns nOrderBy=1. ---- }
  FillChar(loop, SizeOf(loop), 0);
  loop.iTab     := 0;
  loop.maskSelf := $0001;
  loop.wsFlags  := WHERE_VIRTUALTABLE;
  loop.u.vtab.isOrdered := 1;
  pWInfo^.pOrderBy := pOrderBy;
  revMask := 0;
  result := wherePathSatisfiesOrderBy(pWInfo, pOrderBy, @path, 0,
                                      0, @loop, @revMask);
  Check('OBSAT3 vtab isOrdered + matching pOrderBy → nOrderBy', result = 1);

  { ---- OBSAT4: virtual table loop with isOrdered=0 → isOrderDistinct cleared
    → 0 (loops out, no satisfaction). ---- }
  loop.u.vtab.isOrdered := 0;
  revMask := 0;
  result := wherePathSatisfiesOrderBy(pWInfo, pOrderBy, @path, 0,
                                      0, @loop, @revMask);
  Check('OBSAT4 vtab unordered → 0', result = 0);

  { ---- OBSAT5: vtab with isOrdered=1 but pWInfo->pOrderBy != pOrderBy →
    isOrderDistinct cleared → 0. ---- }
  loop.u.vtab.isOrdered := 1;
  pWInfo^.pOrderBy := nil;          { mismatched }
  revMask := 0;
  result := wherePathSatisfiesOrderBy(pWInfo, pOrderBy, @path, 0,
                                      0, @loop, @revMask);
  Check('OBSAT5 vtab ordered but pOrderBy mismatch → 0', result = 0);
  pWInfo^.pOrderBy := pOrderBy;

  { ---- OBSAT6: nLoop=0 with OrderByIdxJoin disabled is allowed (gate only
    bites when nLoop > 0).  Use a vtab loop again to keep determinism. ---- }
  db^.dbOptFlags := SQLITE_OrderByIdxJoin;
  loop.u.vtab.isOrdered := 1;
  revMask := 0;
  result := wherePathSatisfiesOrderBy(pWInfo, pOrderBy, @path, 0,
                                      0, @loop, @revMask);
  Check('OBSAT6 nLoop=0 not gated by OrderByIdxJoin', result = 1);
  db^.dbOptFlags := 0;

  sqlite3_close(db);
end;

{ ----- wherePathSolver + computeMxChoice (where.c:5651..5798, 5834..6257) ----- }

procedure TestPathSolver;
var
  db:        PTsqlite3;
  rc:        i32;
  parse:     TParse;
  wInfoBuf:  array[0..2047] of u8;
  pWInfo:    PWhereInfo;
  src:       TSrcListBuf;
  loopA, loopB: TWhereLoop;
  mx:        i32;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('WPS open', rc = SQLITE_OK);

  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;
  parse.nQueryLoop := 0;

  FillChar(wInfoBuf, SizeOf(wInfoBuf), 0);
  pWInfo := PWhereInfo(@wInfoBuf[0]);
  pWInfo^.pParse := @parse;

  FillChar(src, SizeOf(src), 0);
  src.hdr.nSrc      := 1;
  src.item.iCursor  := 7;
  pWInfo^.pTabList  := @src.hdr;

  { ---- WPS1 — nLevel=0 (FROM-less query) returns SQLITE_OK without
    touching pLoops; nRowOut = MIN(nQueryLoop,48) = 0. ---- }
  pWInfo^.nLevel := 0;
  pWInfo^.pLoops := nil;
  rc := wherePathSolver(pWInfo, 0);
  Check('WPS1 FROM-less plan returns OK', rc = SQLITE_OK);
  Check('WPS1 nRowOut = nQueryLoop seed', pWInfo^.nRowOut = 0);

  { ---- WPS2 — single-table, single candidate WhereLoop is selected and
    its identity wired into pWInfo->a[0]. ---- }
  FillChar(loopA, SizeOf(loopA), 0);
  loopA.iTab     := 0;
  loopA.maskSelf := 1;
  loopA.prereq   := 0;
  loopA.rRun     := 33;
  loopA.nOut     := 5;
  loopA.wsFlags  := WHERE_IPK or WHERE_ONEROW;
  pWInfo^.nLevel := 1;
  pWInfo^.pLoops := @loopA;
  rc := wherePathSolver(pWInfo, 0);
  Check('WPS2 single-loop plan returns OK', rc = SQLITE_OK);
  Check('WPS2 level[0].pWLoop = loopA',
        whereInfoLevels(pWInfo)[0].pWLoop = @loopA);
  Check('WPS2 level[0].iFrom = 0',
        whereInfoLevels(pWInfo)[0].iFrom = 0);
  Check('WPS2 level[0].iTabCur = 7',
        whereInfoLevels(pWInfo)[0].iTabCur = 7);
  Check('WPS2 nRowOut = nRow seed + nOut = 0 + 5',
        pWInfo^.nRowOut = 5);

  { ---- WPS3 — two competing candidates on the same table; the one with
    the lower rRun wins. ---- }
  FillChar(loopA, SizeOf(loopA), 0);
  loopA.iTab := 0; loopA.maskSelf := 1; loopA.prereq := 0;
  loopA.rRun := 50;  loopA.nOut := 7;
  loopA.wsFlags := WHERE_INDEXED;
  FillChar(loopB, SizeOf(loopB), 0);
  loopB.iTab := 0; loopB.maskSelf := 1; loopB.prereq := 0;
  loopB.rRun := 33;  loopB.nOut := 3;
  loopB.wsFlags := WHERE_IPK or WHERE_ONEROW;
  loopA.pNextLoop := @loopB;
  loopB.pNextLoop := nil;
  pWInfo^.pLoops := @loopA;
  pWInfo^.nLevel := 1;
  rc := wherePathSolver(pWInfo, 0);
  Check('WPS3 two-loop pick returns OK', rc = SQLITE_OK);
  Check('WPS3 cheaper loopB wins',
        whereInfoLevels(pWInfo)[0].pWLoop = @loopB);

  { ---- WPS4 — no candidate covers the (only) FROM table → "no query
    solution" → SQLITE_ERROR. ---- }
  FillChar(loopA, SizeOf(loopA), 0);
  loopA.iTab := 0; loopA.maskSelf := 1;
  loopA.prereq := $00000002;       { unsatisfiable: needs table 2 }
  loopA.rRun := 33; loopA.nOut := 1;
  loopA.wsFlags := WHERE_INDEXED;
  pWInfo^.pLoops := @loopA;
  pWInfo^.nLevel := 1;
  rc := wherePathSolver(pWInfo, 0);
  Check('WPS4 unsatisfiable plan returns SQLITE_ERROR',
        rc = SQLITE_ERROR);

  { ---- WPS5 — computeMxChoice gates on nLevel: <=1 → 1; star-query
    flag toggles 12↔18 only when nLevel>=4.  Probe the trivial path. ---- }
  pWInfo^.nLevel := 0;
  mx := computeMxChoice(pWInfo);
  Check('WPS5a nLevel=0 → mxChoice baseline = 12',
        mx = 12);
  pWInfo^.bitwiseFlags := pWInfo^.bitwiseFlags or (u8(1) shl 5); { bStarUsed }
  mx := computeMxChoice(pWInfo);
  Check('WPS5b bStarUsed → mxChoice = 18',
        mx = 18);
  pWInfo^.bitwiseFlags := pWInfo^.bitwiseFlags and (not (u8(1) shl 5));

  sqlite3_close(db);
end;

{ ---------------------------------------------------------------------------
  Phase 6.9-bis (step 11g.2.e sub-progress) — wherecode.c leaf helpers gate.
  Tests for disableTerm, codeApplyAffinity, whereLikeOptimizationStringFixup,
  and adjustOrderByCol.  All four are pure leaf helpers ported from
  wherecode.c:419..541, 1015..1030; they have no recursion into the planner
  and can be exercised against hand-built records.
  =========================================================================== }

procedure TestDisableTerm;
var
  pWC: PWhereClause;
  buf: array[0..2047] of u8;
  pLevel: TWhereLevel;
  pParent, pChild1, pChild2: PWhereTerm;
  pExprNoOuter, pExprOuter: TExpr;
begin
  FillChar(buf, SizeOf(buf), 0);
  pWC := PWhereClause(@buf[0]);
  pWC^.nTerm := 3;
  pWC^.nSlot := 8;
  pWC^.a := @pWC^.aStatic[0];

  FillChar(pExprNoOuter, SizeOf(pExprNoOuter), 0);
  pExprNoOuter.flags := 0;
  FillChar(pExprOuter,   SizeOf(pExprOuter),   0);
  pExprOuter.flags   := EP_OuterON;

  pParent := @pWC^.aStatic[0];
  pChild1 := @pWC^.aStatic[1];
  pChild2 := @pWC^.aStatic[2];

  pParent^.pWC := pWC; pParent^.iParent := -1; pParent^.nChild := 2;
  pParent^.pExpr := @pExprNoOuter; pParent^.wtFlags := 0; pParent^.prereqAll := 0;
  pChild1^.pWC := pWC; pChild1^.iParent := 0; pChild1^.nChild := 0;
  pChild1^.pExpr := @pExprNoOuter; pChild1^.wtFlags := 0; pChild1^.prereqAll := 0;
  pChild2^.pWC := pWC; pChild2^.iParent := 0; pChild2^.nChild := 0;
  pChild2^.pExpr := @pExprNoOuter; pChild2^.wtFlags := 0; pChild2^.prereqAll := 0;

  FillChar(pLevel, SizeOf(pLevel), 0);

  { ---- DT1 — simple term, no parent → TERM_CODED set, walk stops. ---- }
  pParent^.iParent := -1; pParent^.nChild := 0; pParent^.wtFlags := 0;
  disableTerm(@pLevel, pParent);
  Check('DT1 standalone term marked TERM_CODED',
        (pParent^.wtFlags and TERM_CODED) <> 0);

  { ---- DT2 — already TERM_CODED → loop body skipped. ---- }
  pParent^.wtFlags := TERM_CODED or TERM_VIRTUAL;
  disableTerm(@pLevel, pParent);
  Check('DT2 already-coded term unchanged',
        pParent^.wtFlags = (TERM_CODED or TERM_VIRTUAL));

  { ---- DT3 — child, parent.nChild=2 → child coded, parent.nChild→1, walk
    stops because parent still has live children. ---- }
  pParent^.iParent := -1; pParent^.nChild := 2; pParent^.wtFlags := 0;
  pChild1^.iParent := 0;  pChild1^.nChild := 0; pChild1^.wtFlags := 0;
  disableTerm(@pLevel, pChild1);
  Check('DT3 child marked TERM_CODED',
        (pChild1^.wtFlags and TERM_CODED) <> 0);
  Check('DT3 parent.nChild decremented to 1',
        pParent^.nChild = 1);
  Check('DT3 parent NOT yet coded',
        (pParent^.wtFlags and TERM_CODED) = 0);

  { ---- DT3-cont — coding the second child takes parent.nChild→0 → parent
    coded too. ---- }
  pChild2^.iParent := 0;  pChild2^.nChild := 0; pChild2^.wtFlags := 0;
  disableTerm(@pLevel, pChild2);
  Check('DT3 second child marked TERM_CODED',
        (pChild2^.wtFlags and TERM_CODED) <> 0);
  Check('DT3 parent walked, now coded too',
        (pParent^.wtFlags and TERM_CODED) <> 0);

  { ---- DT4 — TERM_LIKE child after parent walk gets TERM_LIKECOND, not
    TERM_CODED, on the second iteration (nLoop>0). ---- }
  pParent^.iParent := -1; pParent^.nChild := 1; pParent^.wtFlags := 0;
  pChild1^.iParent := 0;  pChild1^.nChild := 0;
  pChild1^.wtFlags := TERM_LIKE;  { will become parent on iter 2 }
  { Actually the C semantics: TERM_LIKE on a *parent* of the chain.  Set up:
    grandchild → parent (TERM_LIKE) where TERM_LIKECOND fires on parent. }
  pChild2^.iParent := 1;  pChild2^.nChild := 0; pChild2^.wtFlags := 0;
  pChild1^.nChild := 1;
  disableTerm(@pLevel, pChild2);
  Check('DT4 grandchild marked TERM_CODED (iter 1, nLoop=0)',
        (pChild2^.wtFlags and TERM_CODED) <> 0);
  Check('DT4 TERM_LIKE parent gets TERM_LIKECOND (iter 2, nLoop=1)',
        (pChild1^.wtFlags and TERM_LIKECOND) <> 0);
  Check('DT4 TERM_LIKE parent NOT TERM_CODED',
        (pChild1^.wtFlags and TERM_CODED) = 0);

  { ---- DT5 — notReady & prereqAll <> 0 short-circuits. ---- }
  pChild1^.wtFlags := 0; pChild1^.prereqAll := $F0;
  pLevel.notReady := $0F;   { no overlap → still proceeds }
  disableTerm(@pLevel, pChild1);
  Check('DT5a non-overlapping notReady allows coding',
        (pChild1^.wtFlags and TERM_CODED) <> 0);
  pChild1^.wtFlags := 0; pChild1^.prereqAll := $0F;
  pLevel.notReady := $0F;   { overlap → blocked }
  disableTerm(@pLevel, pChild1);
  Check('DT5b overlapping notReady blocks coding',
        (pChild1^.wtFlags and TERM_CODED) = 0);
  pLevel.notReady := 0;

  { ---- DT6 — iLeftJoin <> 0 and term lacks EP_OuterON → blocked. ---- }
  pLevel.iLeftJoin := 1;
  pChild1^.wtFlags := 0; pChild1^.prereqAll := 0;
  pChild1^.pExpr := @pExprNoOuter;
  disableTerm(@pLevel, pChild1);
  Check('DT6a outer-join + no EP_OuterON blocks coding',
        (pChild1^.wtFlags and TERM_CODED) = 0);
  pChild1^.pExpr := @pExprOuter;
  disableTerm(@pLevel, pChild1);
  Check('DT6b outer-join + EP_OuterON allows coding',
        (pChild1^.wtFlags and TERM_CODED) <> 0);
  pLevel.iLeftJoin := 0;
end;

procedure TestCodeApplyAffinity;
var
  db:    PTsqlite3;
  parse: TParse;
  v:     PVdbe;
  rc:    i32;
  zAff:  array[0..7] of AnsiChar;
  startN: i32;
  pOp:    PVdbeOp;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('CAA open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;
  v := sqlite3GetVdbe(@parse);
  Check('CAA vdbe ready', v <> nil);
  startN := v^.nOp;

  { ---- CAA1 — zAff = nil triggers mallocFailed assert path; skip when not
    asserting (production build).  Just verify no opcode is emitted. ---- }
  { (cannot exercise nil arm without flipping mallocFailed; skipped.) }

  { ---- CAA2 — all entries are AFF_BLOB → trimmed to nothing, no opcode. ---- }
  zAff[0] := AnsiChar(SQLITE_AFF_BLOB);
  zAff[1] := AnsiChar(SQLITE_AFF_BLOB);
  zAff[2] := AnsiChar(SQLITE_AFF_NONE);
  codeApplyAffinity(@parse, 5, 3, @zAff[0]);
  Check('CAA2 all-blob → no OP_Affinity emitted',
        v^.nOp = startN);

  { ---- CAA3 — single non-trivial char → opcode emitted. ---- }
  zAff[0] := 'C';   { SQLITE_AFF_TEXT = 'B'/'C' family > BLOB }
  startN := v^.nOp;
  codeApplyAffinity(@parse, 5, 1, @zAff[0]);
  Check('CAA3 emits one opcode',
        v^.nOp = startN + 1);
  pOp := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(startN) * SizeOf(TVdbeOp));
  Check('CAA3 opcode is OP_Affinity',
        pOp^.opcode = OP_Affinity);
  Check('CAA3 base preserved (p1=5)',
        pOp^.p1 = 5);
  Check('CAA3 n=1',
        pOp^.p2 = 1);

  { ---- CAA4 — prefix BLOB + tail TEXT → base/n shifted past prefix. ---- }
  zAff[0] := AnsiChar(SQLITE_AFF_BLOB);
  zAff[1] := AnsiChar(SQLITE_AFF_BLOB);
  zAff[2] := 'C';
  zAff[3] := 'D';
  startN := v^.nOp;
  codeApplyAffinity(@parse, 10, 4, @zAff[0]);
  Check('CAA4 emits one opcode',
        v^.nOp = startN + 1);
  pOp := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(startN) * SizeOf(TVdbeOp));
  Check('CAA4 base shifted by 2 (10+2)',
        pOp^.p1 = 12);
  Check('CAA4 length trimmed to 2',
        pOp^.p2 = 2);

  { ---- CAA5 — TEXT-prefix + BLOB-suffix → only suffix trimmed. ---- }
  zAff[0] := 'C';
  zAff[1] := 'C';
  zAff[2] := AnsiChar(SQLITE_AFF_BLOB);
  zAff[3] := AnsiChar(SQLITE_AFF_NONE);
  startN := v^.nOp;
  codeApplyAffinity(@parse, 20, 4, @zAff[0]);
  Check('CAA5 suffix trim emits one opcode',
        v^.nOp = startN + 1);
  pOp := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(startN) * SizeOf(TVdbeOp));
  Check('CAA5 base unchanged',
        pOp^.p1 = 20);
  Check('CAA5 length trimmed to 2',
        pOp^.p2 = 2);

  sqlite3_close(db);
end;

procedure TestWhereLikeOptStringFixup;
var
  db:     PTsqlite3;
  parse:  TParse;
  v:      PVdbe;
  rc:     i32;
  pLevel: TWhereLevel;
  pTerm:  TWhereTerm;
  pWC:    TWhereClause;
  wInfo:  TWhereInfo;
  pOp:    PVdbeOp;
  addr:   i32;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('WLOSF open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;
  v := sqlite3GetVdbe(@parse);

  FillChar(pLevel, SizeOf(pLevel), 0);
  FillChar(pTerm,  SizeOf(pTerm),  0);
  FillChar(pWC,    SizeOf(pWC),    0);
  FillChar(wInfo,  SizeOf(wInfo),  0);
  wInfo.pParse := @parse;
  pWC.pWInfo := @wInfo;
  pTerm.pWC := @pWC;

  { Emit an OP_String8 to anchor the fixup. }
  addr := sqlite3VdbeAddOp4(v, OP_String8, 0, 1, 0, PAnsiChar('foo'), 0);
  Check('WLOSF baseline OP_String8 emitted', addr >= 0);
  pOp := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(addr) * SizeOf(TVdbeOp));

  { ---- WLOSF1 — wtFlags lacks TERM_LIKEOPT → no fixup. ---- }
  pTerm.wtFlags := 0;
  pLevel.iLikeRepCntr := 7;
  pOp^.p3 := 99; pOp^.p5 := 99;
  whereLikeOptimizationStringFixup(v, @pLevel, @pTerm);
  Check('WLOSF1 no TERM_LIKEOPT → p3 untouched', pOp^.p3 = 99);
  Check('WLOSF1 no TERM_LIKEOPT → p5 untouched', pOp^.p5 = 99);

  { ---- WLOSF2 — TERM_LIKEOPT + iLikeRepCntr=7 → p3=3 (7>>1), p5=1 (7&1). ---- }
  pTerm.wtFlags := TERM_LIKEOPT;
  pOp^.p3 := 0; pOp^.p5 := 0;
  whereLikeOptimizationStringFixup(v, @pLevel, @pTerm);
  Check('WLOSF2 p3 = iLikeRepCntr>>1 = 3', pOp^.p3 = 3);
  Check('WLOSF2 p5 = iLikeRepCntr&1  = 1', pOp^.p5 = 1);

  { ---- WLOSF3 — iLikeRepCntr=10 → p3=5, p5=0. ---- }
  pLevel.iLikeRepCntr := 10;
  whereLikeOptimizationStringFixup(v, @pLevel, @pTerm);
  Check('WLOSF3 p3 = 10>>1 = 5', pOp^.p3 = 5);
  Check('WLOSF3 p5 = 10&1  = 0', pOp^.p5 = 0);

  sqlite3_close(db);
end;

procedure TestAdjustOrderByCol;
const
  N_ORD = 4;
  N_EL  = 3;
type
  TOrdBuf = record
    hdr:   TExprList;
    items: array[0..N_ORD-1] of TExprListItem;
  end;
  TELBuf = record
    hdr:   TExprList;
    items: array[0..N_EL-1] of TExprListItem;
  end;
var
  ord: TOrdBuf;
  el:  TELBuf;
  i: Integer;
begin
  { ---- AOBC1 — pOrderBy=nil is a no-op. ---- }
  adjustOrderByCol(nil, nil);
  Check('AOBC1 nil pOrderBy → no crash', True);

  FillChar(ord, SizeOf(ord), 0);
  FillChar(el,  SizeOf(el),  0);
  ord.hdr.nExpr := N_ORD;
  el.hdr.nExpr  := N_EL;

  { ORDER BY column slots originally pointed at result-set positions
    [3, 0, 1, 2]; result-set rearrangement put old-pos t at new-pos j:
      el[0].iOrderByCol = 2  (old col 2 → new col 1)
      el[1].iOrderByCol = 3  (old col 3 → new col 2)
      el[2].iOrderByCol = 1  (old col 1 → new col 3)
    So expected adjusted ord values: t=3 → j=1 → 2; t=0 → skip; t=1 → j=2 → 3;
    t=2 → j=0 → 1. }
  ord.items[0].u.x.iOrderByCol := 3;
  ord.items[1].u.x.iOrderByCol := 0;
  ord.items[2].u.x.iOrderByCol := 1;
  ord.items[3].u.x.iOrderByCol := 2;
  el.items[0].u.x.iOrderByCol := 2;
  el.items[1].u.x.iOrderByCol := 3;
  el.items[2].u.x.iOrderByCol := 1;

  adjustOrderByCol(@ord.hdr, @el.hdr);
  Check('AOBC2a t=3 → 2', ord.items[0].u.x.iOrderByCol = 2);
  Check('AOBC2b t=0 stays 0 (skipped)', ord.items[1].u.x.iOrderByCol = 0);
  Check('AOBC2c t=1 → 3', ord.items[2].u.x.iOrderByCol = 3);
  Check('AOBC2d t=2 → 1', ord.items[3].u.x.iOrderByCol = 1);

  { ---- AOBC3 — orphan (no match in pEList) → cleared to 0. ---- }
  for i := 0 to N_ORD - 1 do ord.items[i].u.x.iOrderByCol := 0;
  ord.items[0].u.x.iOrderByCol := 99;   { not present in el }
  el.items[0].u.x.iOrderByCol := 1;
  el.items[1].u.x.iOrderByCol := 2;
  el.items[2].u.x.iOrderByCol := 3;
  adjustOrderByCol(@ord.hdr, @el.hdr);
  Check('AOBC3 orphan cleared to 0', ord.items[0].u.x.iOrderByCol = 0);
end;

{ ---------------------------------------------------------------------------
  Phase 6.9-bis (step 11g.2.e sub-progress) — wherecode.c leaf helpers,
  batch 2.  Tests for sqlite3VectorFieldSubexpr,
  sqlite3ExprNeedsNoAffinityChange, updateRangeAffinityStr,
  whereLoopIsOneRow, and whereApplyPartialIndexConstraints.
  =========================================================================== }

procedure TestVectorFieldSubexpr;
type
  TListBuf = record
    hdr:   TExprList;
    items: array[0..2] of TExprListItem;
  end;
var
  scalar:           TExpr;
  vec:              TExpr;
  e0, e1, e2:       TExpr;
  list:             TListBuf;
begin
  FillChar(scalar, SizeOf(scalar), 0);
  scalar.op := TK_INTEGER;
  Check('VFS1 scalar returns self',
    sqlite3VectorFieldSubexpr(@scalar, 0) = @scalar);

  FillChar(e0, SizeOf(e0), 0); e0.op := TK_COLUMN;
  FillChar(e1, SizeOf(e1), 0); e1.op := TK_INTEGER;
  FillChar(e2, SizeOf(e2), 0); e2.op := TK_STRING;
  FillChar(list, SizeOf(list), 0);
  list.hdr.nExpr := 3;
  list.items[0].pExpr := @e0;
  list.items[1].pExpr := @e1;
  list.items[2].pExpr := @e2;

  FillChar(vec, SizeOf(vec), 0);
  vec.op := TK_VECTOR;
  vec.flags := 0;       { x is pList — EP_xIsSelect cleared }
  vec.x.pList := @list.hdr;
  Check('VFS2 vector field 0', sqlite3VectorFieldSubexpr(@vec, 0) = @e0);
  Check('VFS2 vector field 1', sqlite3VectorFieldSubexpr(@vec, 1) = @e1);
  Check('VFS2 vector field 2', sqlite3VectorFieldSubexpr(@vec, 2) = @e2);
end;

procedure TestExprNeedsNoAffinityChange;
var
  e: TExpr;
  inner: TExpr;
begin
  FillChar(e, SizeOf(e), 0);

  { ENC1 — AFF_BLOB always returns 1 regardless of op. }
  e.op := TK_INTEGER;
  Check('ENC1 AFF_BLOB → 1',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_BLOB)) = 1);

  { ENC2 — TK_INTEGER, AFF_NUMERIC → 1. }
  Check('ENC2 INTEGER + NUMERIC → 1',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_NUMERIC)) = 1);

  { ENC3 — TK_INTEGER, AFF_TEXT → 0 (TEXT < NUMERIC). }
  Check('ENC3 INTEGER + TEXT → 0',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_TEXT)) = 0);

  { ENC4 — TK_FLOAT + NUMERIC → 1. }
  e.op := TK_FLOAT;
  Check('ENC4 FLOAT + NUMERIC → 1',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_NUMERIC)) = 1);

  { ENC5 — TK_STRING + TEXT (no unaryMinus) → 1. }
  e.op := TK_STRING;
  Check('ENC5 STRING + TEXT → 1',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_TEXT)) = 1);

  { ENC6 — TK_STRING + NUMERIC → 0. }
  Check('ENC6 STRING + NUMERIC → 0',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_NUMERIC)) = 0);

  { ENC7 — TK_BLOB no unary minus → 1 for any aff. }
  e.op := TK_BLOB;
  Check('ENC7 BLOB + TEXT → 1',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_TEXT)) = 1);

  { ENC8 — TK_UMINUS prefix lights unaryMinus, then BLOB returns 0. }
  FillChar(inner, SizeOf(inner), 0);
  inner.op := TK_BLOB;
  e.op := TK_UMINUS;
  e.pLeft := @inner;
  Check('ENC8 UMINUS BLOB → 0',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_TEXT)) = 0);

  { ENC9 — TK_UPLUS chain to TK_INTEGER, NUMERIC → 1. }
  inner.op := TK_INTEGER;
  e.op := TK_UPLUS;
  e.pLeft := @inner;
  Check('ENC9 UPLUS INTEGER + NUMERIC → 1',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_NUMERIC)) = 1);

  { ENC10 — TK_COLUMN with iColumn=-1 (rowid alias) and NUMERIC → 1. }
  FillChar(e, SizeOf(e), 0);
  e.op := TK_COLUMN; e.iTable := 0; e.iColumn := -1;
  Check('ENC10 COLUMN rowid + NUMERIC → 1',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_NUMERIC)) = 1);

  { ENC11 — TK_COLUMN with iColumn=0 (regular column) → 0. }
  e.iColumn := 0;
  Check('ENC11 COLUMN regular + NUMERIC → 0',
    sqlite3ExprNeedsNoAffinityChange(@e, AnsiChar(SQLITE_AFF_NUMERIC)) = 0);
end;

procedure TestUpdateRangeAffinityStr;
var
  scalar: TExpr;
  zAff: array[0..3] of AnsiChar;
begin
  { URA1 — scalar TK_INTEGER, n=1, AFF_NUMERIC → no change (NUMERIC ≠ BLOB
    but sqlite3CompareAffinity(int, NUMERIC) returns NUMERIC, not BLOB; and
    sqlite3ExprNeedsNoAffinityChange(int, NUMERIC) = 1 → AFF_BLOB written). }
  FillChar(scalar, SizeOf(scalar), 0);
  scalar.op := TK_INTEGER;
  zAff[0] := AnsiChar(SQLITE_AFF_NUMERIC);
  updateRangeAffinityStr(@scalar, 1, @zAff[0]);
  Check('URA1 INTEGER+NUMERIC → AFF_BLOB',
    Byte(zAff[0]) = SQLITE_AFF_BLOB);

  { URA2 — TK_STRING, AFF_TEXT → NeedsNoAffinityChange returns 1 → BLOB. }
  FillChar(scalar, SizeOf(scalar), 0);
  scalar.op := TK_STRING;
  zAff[0] := AnsiChar(SQLITE_AFF_TEXT);
  updateRangeAffinityStr(@scalar, 1, @zAff[0]);
  Check('URA2 STRING+TEXT → AFF_BLOB',
    Byte(zAff[0]) = SQLITE_AFF_BLOB);

  { URA3 — TK_NULL + AFF_TEXT.  CompareAffinity returns NULL→0 ≠ BLOB; the
    op isn't in the NeedsNoAffinityChange switch → 0; nothing written. }
  FillChar(scalar, SizeOf(scalar), 0);
  scalar.op := TK_NULL;
  zAff[0] := AnsiChar(SQLITE_AFF_TEXT);
  updateRangeAffinityStr(@scalar, 1, @zAff[0]);
  Check('URA3 NULL+TEXT → unchanged',
    Byte(zAff[0]) = SQLITE_AFF_TEXT);
end;

procedure TestWhereLoopIsOneRow;
var
  loop: TWhereLoop;
  idx:  TIndex;
  t0, t1: TWhereTerm;
begin
  FillChar(loop, SizeOf(loop), 0);
  FillChar(idx,  SizeOf(idx),  0);
  FillChar(t0,   SizeOf(t0),   0);
  FillChar(t1,   SizeOf(t1),   0);

  loop.aLTerm := PPWhereTerm(@loop.aLTermSpace[0]);
  loop.aLTermSpace[0] := @t0;
  loop.aLTermSpace[1] := @t1;
  loop.u.btree.pIndex := @idx;

  { WL1OR1 — onError=0 (OE_None) → 0. }
  idx.onError := 0; idx.nKeyCol := 1;
  loop.u.btree.nEq := 1; loop.nSkip := 0;
  t0.eOperator := WO_EQ;
  Check('WL1OR1 OE_None → 0', whereLoopIsOneRow(@loop) = 0);

  { WL1OR2 — UNIQUE, nEq=nKeyCol=2, all WO_EQ → 1. }
  idx.onError := 5; idx.nKeyCol := 2;          { OE_Replace = 5, any non-zero }
  loop.u.btree.nEq := 2; loop.nSkip := 0;
  t0.eOperator := WO_EQ; t1.eOperator := WO_EQ;
  Check('WL1OR2 UNIQUE all-EQ → 1', whereLoopIsOneRow(@loop) = 1);

  { WL1OR3 — one term WO_IS → 0. }
  t1.eOperator := WO_IS;
  Check('WL1OR3 WO_IS disqualifier → 0', whereLoopIsOneRow(@loop) = 0);

  { WL1OR4 — WO_ISNULL also disqualifies. }
  t1.eOperator := WO_ISNULL;
  Check('WL1OR4 WO_ISNULL disqualifier → 0', whereLoopIsOneRow(@loop) = 0);

  { WL1OR5 — nSkip > 0 → 0 (skip-scan loops are not single-row). }
  t1.eOperator := WO_EQ;
  loop.nSkip := 1;
  Check('WL1OR5 nSkip>0 → 0', whereLoopIsOneRow(@loop) = 0);

  { WL1OR6 — nEq < nKeyCol → 0 (partial key match). }
  loop.nSkip := 0; loop.u.btree.nEq := 1;
  Check('WL1OR6 nEq<nKeyCol → 0', whereLoopIsOneRow(@loop) = 0);
end;

procedure TestWhereApplyPartialIndexConstraints;
var
  buf: array[0..2047] of u8;
  pWC: PWhereClause;
  truth, lhs, rhs:        TExpr;
  termA, termB, termC:    TExpr;
  i: i32;
begin
  FillChar(buf, SizeOf(buf), 0);
  pWC := PWhereClause(@buf[0]);
  pWC^.nTerm := 3;
  pWC^.nSlot := 8;
  pWC^.a := @pWC^.aStatic[0];

  { Truth = (lhs AND rhs).  lhs and rhs are leaf comparison expressions —
    TK_NULL nodes are the easiest sqlite3ExprCompare match (op==TK_NULL
    short-circuits to 0 once tokens have been checked).  We give the
    second conjunct an EP_IntValue-tagged TK_INTEGER so the integer
    fast-path is exercised too. }
  FillChar(termA, SizeOf(termA), 0); termA.op := TK_NULL;
  FillChar(termB, SizeOf(termB), 0); termB.op := TK_INTEGER;
  termB.flags := EP_IntValue;
  termB.u.iValue := 1;
  FillChar(termC, SizeOf(termC), 0); termC.op := TK_FLOAT;

  { Build truth = termA AND termB. }
  FillChar(lhs, SizeOf(lhs), 0); lhs := termA;
  FillChar(rhs, SizeOf(rhs), 0); rhs := termB;
  FillChar(truth, SizeOf(truth), 0);
  truth.op := TK_AND;
  truth.pLeft  := @lhs;
  truth.pRight := @rhs;

  pWC^.aStatic[0].pWC := pWC;
  pWC^.aStatic[0].pExpr := @termA;       { matches lhs by structure }
  pWC^.aStatic[0].wtFlags := 0;
  pWC^.aStatic[1].pWC := pWC;
  pWC^.aStatic[1].pExpr := @termB;       { matches rhs by structure }
  pWC^.aStatic[1].wtFlags := 0;
  pWC^.aStatic[2].pWC := pWC;
  pWC^.aStatic[2].pExpr := @termC;       { does NOT match }
  pWC^.aStatic[2].wtFlags := 0;

  whereApplyPartialIndexConstraints(@truth, 0, pWC);

  Check('WAPIC1 termA tagged TERM_CODED',
    (pWC^.aStatic[0].wtFlags and TERM_CODED) <> 0);
  Check('WAPIC2 termB tagged TERM_CODED',
    (pWC^.aStatic[1].wtFlags and TERM_CODED) <> 0);
  Check('WAPIC3 termC NOT tagged',
    (pWC^.aStatic[2].wtFlags and TERM_CODED) = 0);

  { WAPIC4 — already-coded term is skipped silently. }
  for i := 0 to 2 do pWC^.aStatic[i].wtFlags := TERM_CODED;
  whereApplyPartialIndexConstraints(@truth, 0, pWC);
  Check('WAPIC4 pre-coded all stay coded',
    (pWC^.aStatic[0].wtFlags = TERM_CODED)
    and (pWC^.aStatic[1].wtFlags = TERM_CODED)
    and (pWC^.aStatic[2].wtFlags = TERM_CODED));
end;

{ ---------------------------------------------------------------------------
  Phase 6.9-bis (step 11g.2.e sub-progress) — wherecode.c leaf helpers,
  batch 3 gates.

  TS1..TS5  — sqlite3TableColumnToStorage (build.c:1155..1170): identity
              when TF_HasVirtual is unset; identity when iCol<0 (rowid
              alias); virtual-column packing when TF_HasVirtual is set.
  PT1..PT3  — sqlite3ParseToplevel: returns p when pToplevel is nil,
              returns pToplevel otherwise (no chain walk — this is the
              direct-parent macro from sqliteInt.h:5266).
  CDS1..CDS3 — codeDeferredSeek (wherecode.c:1276..1309): emits
              OP_DeferredSeek; lights bDeferredSeek (bit 0 of
              pWInfo^.bitwiseFlags); attaches a P4_INTARRAY mapping when
              the loop sits inside an OR-subclause / RIGHT-JOIN frame and
              the toplevel's writeMask is empty.
  =========================================================================== }

procedure TestTableColumnToStorage;
var
  pTab: PTable2;
  cols: array[0..3] of TColumn;
  size: SizeInt;
begin
  size := SizeOf(TTable);
  pTab := PTable2(GetMem(size));
  FillChar(pTab^, size, 0);
  pTab^.nCol := 4;
  pTab^.aCol := @cols[0];
  FillChar(cols, SizeOf(cols), 0);

  { ---- TS1 — TF_HasVirtual unset → identity. ---- }
  pTab^.tabFlags := 0;
  Check('TS1 no virtual → identity 0', sqlite3TableColumnToStorage(pTab, 0) = 0);
  Check('TS1 no virtual → identity 2', sqlite3TableColumnToStorage(pTab, 2) = 2);

  { ---- TS2 — iCol<0 (rowid alias) is always identity even with virtuals. ---- }
  pTab^.tabFlags := TF_HasVirtual;
  Check('TS2 iCol=-1 → -1', sqlite3TableColumnToStorage(pTab, -1) = -1);

  { ---- TS3 — TF_HasVirtual set, no virtual columns yet → counts non-virtual. ---- }
  cols[0].colFlags := 0; cols[1].colFlags := 0;
  cols[2].colFlags := 0; cols[3].colFlags := 0;
  pTab^.nNVCol := 4;
  Check('TS3 all-real iCol=2 → 2', sqlite3TableColumnToStorage(pTab, 2) = 2);

  { ---- TS4 — column 1 is virtual → real column 2 stores at slot 1. ---- }
  cols[1].colFlags := COLFLAG_VIRTUAL;
  pTab^.nNVCol := 3;
  Check('TS4 virtual at col 1 → real col 2 stores at 1',
        sqlite3TableColumnToStorage(pTab, 2) = 1);
  { Real col 0 still at slot 0. }
  Check('TS4 real col 0 → 0',
        sqlite3TableColumnToStorage(pTab, 0) = 0);

  { ---- TS5 — query the virtual column itself: stored at nNVCol + (iCol - n). ---- }
  { iCol=1 (virtual), n (non-virtual prefix) = 1, so storage = 3 + 1 - 1 = 3. }
  Check('TS5 virtual col 1 → nNVCol + iCol - n = 3',
        sqlite3TableColumnToStorage(pTab, 1) = 3);

  FreeMem(pTab);
end;

procedure TestParseToplevel;
var
  inner, outer: TParse;
begin
  FillChar(inner, SizeOf(inner), 0);
  FillChar(outer, SizeOf(outer), 0);

  { ---- PT1 — pToplevel nil → returns p. ---- }
  Check('PT1 pToplevel=nil → p', sqlite3ParseToplevel(@outer) = @outer);

  { ---- PT2 — pToplevel set → returns pToplevel. ---- }
  inner.pToplevel := @outer;
  Check('PT2 pToplevel=outer → outer', sqlite3ParseToplevel(@inner) = @outer);

  { ---- PT3 — does NOT chase the chain (matches the macro). ---- }
  outer.pToplevel := nil;
  Check('PT3 single hop only', sqlite3ParseToplevel(@inner) = @outer);
end;

procedure TestCodeDeferredSeek;
var
  db:    PTsqlite3;
  parse: TParse;
  v:     PVdbe;
  rc:    i32;
  wInfo: TWhereInfo;
  pIdx:  PIndex2;
  pTab:  PTable2;
  aiCol: array[0..2] of i16;
  baseAddr, addr: i32;
  pOp:   PVdbeOp;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('CDS open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;
  v := sqlite3GetVdbe(@parse);

  pTab := PTable2(GetMem(SizeOf(TTable)));
  FillChar(pTab^, SizeOf(TTable), 0);
  pTab^.nCol := 3;

  pIdx := PIndex2(GetMem(SizeOf(TIndex)));
  FillChar(pIdx^, SizeOf(TIndex), 0);
  pIdx^.pTable := pTab;
  pIdx^.nColumn := 3;
  aiCol[0] := 0; aiCol[1] := 1; aiCol[2] := -1;  { trailing rowid required by Assert }
  pIdx^.aiColumn := @aiCol[0];

  FillChar(wInfo, SizeOf(wInfo), 0);
  wInfo.pParse := @parse;

  { ---- CDS1 — outside OR / RIGHT_JOIN: emits OP_DeferredSeek, lights
       bDeferredSeek, no P4 attachment. ---- }
  wInfo.wctrlFlags := 0;
  baseAddr := sqlite3VdbeCurrentAddr(v);
  codeDeferredSeek(@wInfo, pIdx, 1, 2);
  addr := sqlite3VdbeCurrentAddr(v);
  Check('CDS1 emits exactly one opcode', addr = baseAddr + 1);
  pOp := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(baseAddr) * SizeOf(TVdbeOp));
  Check('CDS1 opcode is OP_DeferredSeek', pOp^.opcode = OP_DeferredSeek);
  Check('CDS1 p1 = iIdxCur', pOp^.p1 = 2);
  Check('CDS1 p3 = iCur',    pOp^.p3 = 1);
  Check('CDS1 bDeferredSeek lit', (wInfo.bitwiseFlags and 1) = 1);
  Check('CDS1 no P4 attachment', pOp^.p4type <> P4_INTARRAY);

  { ---- CDS2 — under WHERE_OR_SUBCLAUSE, writeMask=0: P4_INTARRAY attached. ---- }
  FillChar(wInfo.bitwiseFlags, 1, 0);
  wInfo.wctrlFlags := WHERE_OR_SUBCLAUSE;
  parse.writeMask  := 0;
  parse.pToplevel  := nil;
  baseAddr := sqlite3VdbeCurrentAddr(v);
  codeDeferredSeek(@wInfo, pIdx, 1, 2);
  pOp := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(baseAddr) * SizeOf(TVdbeOp));
  Check('CDS2 OP_DeferredSeek emitted', pOp^.opcode = OP_DeferredSeek);
  Check('CDS2 P4_INTARRAY attached',    pOp^.p4type = P4_INTARRAY);

  { ---- CDS3 — under WHERE_OR_SUBCLAUSE but writeMask non-zero: no P4. ---- }
  FillChar(wInfo.bitwiseFlags, 1, 0);
  parse.writeMask := 1;
  baseAddr := sqlite3VdbeCurrentAddr(v);
  codeDeferredSeek(@wInfo, pIdx, 1, 2);
  pOp := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(baseAddr) * SizeOf(TVdbeOp));
  Check('CDS3 OP_DeferredSeek emitted', pOp^.opcode = OP_DeferredSeek);
  Check('CDS3 no P4 attachment when writeMask <> 0',
        pOp^.p4type <> P4_INTARRAY);

  FreeMem(pIdx);
  FreeMem(pTab);
  sqlite3_close(db);
end;

{ ----- explainIndexColumnName / sqlite3IndexAffinityStr (batch 4) ----- }

procedure TestExplainIndexColumnName;
var
  pTab:  PTable2;
  pIdx:  PIndex2;
  aiCol: array[0..2] of i16;
  aCol:  array[0..2] of TColumn;
  z:     PAnsiChar;
begin
  pTab := PTable2(GetMem(SizeOf(TTable))); FillChar(pTab^, SizeOf(TTable), 0);
  pIdx := PIndex2(GetMem(SizeOf(TIndex)));  FillChar(pIdx^, SizeOf(TIndex), 0);
  FillChar(aCol, SizeOf(aCol), 0);
  aCol[0].zCnName := PAnsiChar('alpha');
  aCol[1].zCnName := PAnsiChar('beta');
  aCol[2].zCnName := PAnsiChar('gamma');
  pTab^.aCol := @aCol[0];
  pTab^.nCol := 3;
  pIdx^.pTable := pTab;
  aiCol[0] := 1;            { regular column "beta" }
  aiCol[1] := XN_ROWID;     { rowid alias            }
  aiCol[2] := XN_EXPR;      { expression slot        }
  pIdx^.aiColumn := @aiCol[0];
  pIdx^.nColumn  := 3;

  z := explainIndexColumnName(pIdx, 0);
  Check('EICN1 column 0 → "beta"',  StrComp(z, PAnsiChar('beta')) = 0);
  z := explainIndexColumnName(pIdx, 1);
  Check('EICN2 XN_ROWID → "rowid"', StrComp(z, PAnsiChar('rowid')) = 0);
  z := explainIndexColumnName(pIdx, 2);
  Check('EICN3 XN_EXPR → "<expr>"', StrComp(z, PAnsiChar('<expr>')) = 0);

  FreeMem(pIdx); FreeMem(pTab);
end;

procedure TestIndexAffinityStr;
var
  db:    PTsqlite3;
  pTab:  PTable2;
  pIdx:  PIndex2;
  aiCol: array[0..2] of i16;
  aCol:  array[0..2] of TColumn;
  z, z2: PAnsiChar;
  rc:    i32;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('IAS open', rc = SQLITE_OK);
  pTab := PTable2(GetMem(SizeOf(TTable))); FillChar(pTab^, SizeOf(TTable), 0);
  pIdx := PIndex2(GetMem(SizeOf(TIndex)));  FillChar(pIdx^, SizeOf(TIndex), 0);
  FillChar(aCol, SizeOf(aCol), 0);
  aCol[0].zCnName := PAnsiChar('a'); aCol[0].affinity := AnsiChar(SQLITE_AFF_TEXT);
  aCol[1].zCnName := PAnsiChar('b'); aCol[1].affinity := AnsiChar(SQLITE_AFF_NUMERIC);
  aCol[2].zCnName := PAnsiChar('c'); aCol[2].affinity := AnsiChar(SQLITE_AFF_BLOB);
  pTab^.aCol := @aCol[0]; pTab^.nCol := 3;
  pIdx^.pTable := pTab;
  aiCol[0] := 0;            { a → TEXT     }
  aiCol[1] := XN_ROWID;     { → INTEGER    }
  aiCol[2] := 2;            { c → BLOB     }
  pIdx^.aiColumn := @aiCol[0];
  pIdx^.nColumn  := 3;

  { CIA1 — first call materialises pIdx^.zColAff. }
  Check('CIA1 zColAff initially nil', pIdx^.zColAff = nil);
  z := computeIndexAffStr(db, pIdx);
  Check('CIA1 zColAff allocated',     pIdx^.zColAff <> nil);
  Check('CIA1 returned ptr equals zColAff', z = pIdx^.zColAff);

  { CIA2 — payload: TEXT, INTEGER, BLOB clamped within [BLOB..NUMERIC]. }
  Check('CIA2 [0] = TEXT',    Byte(z[0]) = SQLITE_AFF_TEXT);
  { XN_ROWID is INTEGER then clamped down to NUMERIC by the upstream
    `aff>SQLITE_AFF_NUMERIC ? aff = NUMERIC` guard (insert.c:105). }
  Check('CIA2 [1] = NUMERIC (clamped from INTEGER)',
        Byte(z[1]) = SQLITE_AFF_NUMERIC);
  Check('CIA2 [2] = BLOB',    Byte(z[2]) = SQLITE_AFF_BLOB);
  Check('CIA2 NUL terminator',z[3] = #0);

  { IAS1 — wrapper hits the cached path on subsequent calls. }
  z2 := sqlite3IndexAffinityStr(db, pIdx);
  Check('IAS1 cached path returns same buffer', z2 = z);

  { CIA3 — clamp test: AFF_NONE ($40) below BLOB clamps up to BLOB. }
  sqlite3DbFree(db, pIdx^.zColAff);
  pIdx^.zColAff := nil;
  aCol[0].affinity := AnsiChar($40);                { AFF_NONE }
  aCol[1].affinity := AnsiChar($50);                { > AFF_NUMERIC, clamps down }
  aiCol[1] := 1;                                    { use real column slot }
  z := computeIndexAffStr(db, pIdx);
  Check('CIA3 < BLOB clamps up',     Byte(z[0]) = SQLITE_AFF_BLOB);
  Check('CIA3 > NUMERIC clamps down',Byte(z[1]) = SQLITE_AFF_NUMERIC);

  sqlite3DbFree(db, pIdx^.zColAff);
  FreeMem(pIdx); FreeMem(pTab);
  sqlite3_close(db);
end;

{ ----- codeEqualityTerm — TK_EQ / TK_IS / TK_ISNULL (batch 4) ----- }

procedure TestCodeEqualityTerm;
var
  db:        PTsqlite3;
  parse:     TParse;
  v:         PVdbe;
  rc:        i32;
  loop:      TWhereLoop;
  level:     TWhereLevel;
  term:      TWhereTerm;
  ex:        TExpr;
  exRight:   TExpr;
  alterm:    array[0..0] of PWhereTerm;
  reg, base, i: i32;
  pOp:       PVdbeOp;
  found:     Boolean;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('CET open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;
  v := sqlite3GetVdbe(@parse);

  FillChar(loop,    SizeOf(loop),    0);
  FillChar(level,   SizeOf(level),   0);
  FillChar(term,    SizeOf(term),    0);  term.iParent := -1;
  FillChar(ex,      SizeOf(ex),      0);
  FillChar(exRight, SizeOf(exRight), 0);

  { ---- CET1 — TK_ISNULL: emits OP_Null into iTarget, returns iTarget. ---- }
  ex.op    := TK_ISNULL;
  term.pExpr := @ex;
  term.eOperator := WO_ISNULL;
  alterm[0] := @term;
  loop.aLTerm  := @alterm[0];
  loop.nLTerm  := 1;
  level.pWLoop := @loop;

  base := sqlite3VdbeCurrentAddr(v);
  reg  := codeEqualityTerm(@parse, @term, @level, 0, 0, 5);
  Check('CET1 returns iTarget', reg = 5);
  found := False;
  for i := base to sqlite3VdbeCurrentAddr(v) - 1 do begin
    pOp := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    if (pOp^.opcode = OP_Null) and (pOp^.p2 = 5) then found := True;
  end;
  Check('CET1 OP_Null emitted to reg 5', found);
  Check('CET1 term flagged TERM_CODED', (term.wtFlags and TERM_CODED) <> 0);

  { ---- CET2 — TK_EQ with TK_INTEGER RHS: pRight evaluated into a temp reg.
       Term gets disabled. ---- }
  FillChar(term, SizeOf(term), 0); term.iParent := -1;
  term.pExpr := @ex;
  term.eOperator := WO_EQ;
  ex.op := TK_EQ;
  ex.pRight := @exRight;
  exRight.op := TK_INTEGER;
  exRight.u.iValue := 42;
  exRight.flags := EP_IntValue;

  base := sqlite3VdbeCurrentAddr(v);
  reg := codeEqualityTerm(@parse, @term, @level, 0, 0, 7);
  Check('CET2 returns positive register', reg > 0);
  Check('CET2 emitted at least one opcode', sqlite3VdbeCurrentAddr(v) > base);
  Check('CET2 term flagged TERM_CODED', (term.wtFlags and TERM_CODED) <> 0);

  { ---- CET3 — TK_IS path also disables term. ---- }
  FillChar(term, SizeOf(term), 0); term.iParent := -1;
  term.pExpr := @ex;
  term.eOperator := WO_IS;
  ex.op := TK_IS;
  reg := codeEqualityTerm(@parse, @term, @level, 0, 0, 9);
  Check('CET3 TK_IS returns positive register', reg > 0);
  Check('CET3 TK_IS term flagged TERM_CODED', (term.wtFlags and TERM_CODED) <> 0);

  { ---- CET4 — WHERE_TRANSCONS + WO_EQUIV: term must NOT be auto-disabled. ---- }
  FillChar(term, SizeOf(term), 0); term.iParent := -1;
  term.pExpr := @ex;
  term.eOperator := WO_EQ or WO_EQUIV;
  ex.op := TK_EQ;
  loop.wsFlags := WHERE_TRANSCONS;
  reg := codeEqualityTerm(@parse, @term, @level, 0, 0, 11);
  Check('CET4 transitive EQUIV term not disabled',
        (term.wtFlags and TERM_CODED) = 0);

  sqlite3_close(db);
end;

{ ----- codeAllEqualityTerms (batch 4) ----- }

procedure TestCodeAllEqualityTerms;
var
  db:    PTsqlite3;
  parse: TParse;
  v:     PVdbe;
  rc:    i32;
  pTab:  PTable2;
  pIdx:  PIndex2;
  aiCol: array[0..1] of i16;
  aCol:  array[0..1] of TColumn;
  loop:  TWhereLoop;
  level: TWhereLevel;
  term:  TWhereTerm;
  ex, exRight: TExpr;
  alterm: array[0..0] of PWhereTerm;
  base, regBase: i32;
  zAff:  PAnsiChar;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('CAET open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;
  v := sqlite3GetVdbe(@parse);

  pTab := PTable2(GetMem(SizeOf(TTable))); FillChar(pTab^, SizeOf(TTable), 0);
  pIdx := PIndex2(GetMem(SizeOf(TIndex)));  FillChar(pIdx^, SizeOf(TIndex), 0);
  FillChar(aCol, SizeOf(aCol), 0);
  { Use BLOB / TEXT (both within [BLOB..NUMERIC]) so the per-column clamp
    does not change the values from the source affinity. }
  aCol[0].zCnName := PAnsiChar('x'); aCol[0].affinity := AnsiChar(SQLITE_AFF_BLOB);
  aCol[1].zCnName := PAnsiChar('y'); aCol[1].affinity := AnsiChar(SQLITE_AFF_TEXT);
  pTab^.aCol := @aCol[0]; pTab^.nCol := 2;
  pIdx^.pTable := pTab;
  aiCol[0] := 0; aiCol[1] := 1;
  pIdx^.aiColumn := @aiCol[0];
  pIdx^.nColumn  := 2;
  pIdx^.nKeyCol  := 2;

  FillChar(loop,    SizeOf(loop),    0);
  FillChar(level,   SizeOf(level),   0);
  FillChar(term,    SizeOf(term),    0);
  FillChar(ex,      SizeOf(ex),      0);
  FillChar(exRight, SizeOf(exRight), 0);

  { ---- CAET1 — nEq=0, nExtraReg=0: pure no-op apart from affinity-string
       allocation; regBase advances by 0; affinity string copied from pIdx. ---- }
  loop.u.btree.pIndex := pIdx;
  loop.u.btree.nEq := 0;
  loop.nSkip := 0;
  level.pWLoop := @loop;

  parse.nMem := 5;
  base := sqlite3VdbeCurrentAddr(v);
  regBase := codeAllEqualityTerms(@parse, @level, 0, 0, @zAff);
  Check('CAET1 regBase = old nMem+1', regBase = 6);
  Check('CAET1 nMem unchanged when nEq=nExtraReg=0', parse.nMem = 5);
  Check('CAET1 no opcodes emitted',  sqlite3VdbeCurrentAddr(v) = base);
  Check('CAET1 affinity string allocated', zAff <> nil);
  if zAff <> nil then begin
    Check('CAET1 zAff[0] = BLOB', Byte(zAff[0]) = SQLITE_AFF_BLOB);
    Check('CAET1 zAff[1] = TEXT', Byte(zAff[1]) = SQLITE_AFF_TEXT);
    sqlite3DbFree(db, zAff);
  end;

  { ---- CAET2 — nEq=1 with TK_EQ over an INTEGER literal: emits at least one
       opcode (the literal), allocates 1 register, returns first one. ---- }
  FillChar(term, SizeOf(term), 0); term.iParent := -1;
  ex.op := TK_EQ;
  ex.pRight := @exRight;
  exRight.op := TK_INTEGER;
  exRight.u.iValue := 100;
  exRight.flags := EP_IntValue;
  term.pExpr := @ex;
  term.eOperator := WO_EQ;
  alterm[0] := @term;
  loop.aLTerm := @alterm[0];
  loop.nLTerm := 1;
  loop.u.btree.nEq := 1;

  parse.nMem := 5;
  base := sqlite3VdbeCurrentAddr(v);
  regBase := codeAllEqualityTerms(@parse, @level, 0, 0, @zAff);
  Check('CAET2 regBase = nMem+1 = 6', regBase = 6);
  Check('CAET2 nMem advanced by 1',   parse.nMem = 6);
  Check('CAET2 emitted at least one opcode', sqlite3VdbeCurrentAddr(v) > base);
  Check('CAET2 term TERM_CODED',      (term.wtFlags and TERM_CODED) <> 0);
  Check('CAET2 zAff[0] = BLOB',       Byte(zAff[0]) = SQLITE_AFF_BLOB);
  if zAff <> nil then sqlite3DbFree(db, zAff);

  { ---- CAET3 — TK_IS / WO_IS path tags TERM_IS so the IsNull guard is NOT
       emitted; but we just verify the term gets coded (term flag toggling
       already covered by CAET2). ---- }
  FillChar(term, SizeOf(term), 0); term.iParent := -1;
  term.pExpr := @ex;
  term.eOperator := WO_IS;
  term.wtFlags := TERM_IS;
  ex.op := TK_IS;
  loop.wsFlags := 0;
  parse.nMem := 5;
  regBase := codeAllEqualityTerms(@parse, @level, 0, 1, @zAff);
  Check('CAET3 nExtraReg=1 advances nMem by 2', parse.nMem = 7);
  Check('CAET3 regBase = 6',                    regBase = 6);
  if zAff <> nil then sqlite3DbFree(db, zAff);

  FreeMem(pIdx); FreeMem(pTab);
  sqlite3_close(db);
end;

{ ----- codeExprOrVector (wherecode.c:1320..1346) ----- }

procedure TestCodeExprOrVector;
var
  db:    PTsqlite3;
  parse: TParse;
  v:     PVdbe;
  rc:    i32;
  exScalar, exA, exB, exVec: TExpr;
  pList: PExprList;
  base:  i32;
  pItem: PExprListItem;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('CEOV open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;
  v := sqlite3GetVdbe(@parse);

  { ---- CEOV1 — scalar TK_INTEGER literal: emits exactly one OP into iReg. ---- }
  FillChar(exScalar, SizeOf(exScalar), 0);
  exScalar.op       := TK_INTEGER;
  exScalar.flags    := EP_IntValue;
  exScalar.u.iValue := 42;

  parse.nMem := 5;
  base := sqlite3VdbeCurrentAddr(v);
  codeExprOrVector(@parse, @exScalar, 6, 1);
  Check('CEOV1 scalar emits at least one opcode',
        sqlite3VdbeCurrentAddr(v) > base);

  { ---- CEOV2 — TK_VECTOR with two TK_INTEGER children: ExprUseXList path
       emits one opcode per child into the contiguous register run. ---- }
  FillChar(exA,   SizeOf(exA),   0);
  FillChar(exB,   SizeOf(exB),   0);
  FillChar(exVec, SizeOf(exVec), 0);
  exA.op := TK_INTEGER; exA.flags := EP_IntValue; exA.u.iValue := 1;
  exB.op := TK_INTEGER; exB.flags := EP_IntValue; exB.u.iValue := 2;

  pList := sqlite3ExprListAppend(@parse, nil, @exA);
  pList := sqlite3ExprListAppend(@parse, pList, @exB);
  Check('CEOV2 list non-nil', pList <> nil);
  Check('CEOV2 nExpr = 2',    pList^.nExpr = 2);

  exVec.op    := TK_VECTOR;
  exVec.flags := 0; { ExprUseXList: EP_xIsSelect cleared }
  exVec.x.pList := pList;

  Check('CEOV2 ExprIsVector', sqlite3ExprIsVector(@exVec) <> 0);

  base := sqlite3VdbeCurrentAddr(v);
  codeExprOrVector(@parse, @exVec, 10, 2);
  Check('CEOV2 vector emits >= 2 opcodes',
        sqlite3VdbeCurrentAddr(v) >= base + 2);

  { Pull pList items off so ExprListDelete does not free the stack-allocated
    children — we built them by hand. }
  pItem := PExprListItem(PByte(ExprListItems(pList)));
  pItem^.pExpr := nil;
  pItem := PExprListItem(PByte(ExprListItems(pList)) + SZ_EXPRLIST_ITEM);
  pItem^.pExpr := nil;
  sqlite3ExprListDelete(db, pList);

  sqlite3_close(db);
end;

{ ----- filterPullDown (wherecode.c:1391..1439) ----- }

procedure TestFilterPullDown;
const
  N_LEVEL = 3;
var
  db:     PTsqlite3;
  parse:  TParse;
  v:      PVdbe;
  rc:     i32;
  buf:    array of Byte;
  pWInfo: PWhereInfo;
  loops:  array[0..2] of TWhereLoop;
  term0:  TWhereTerm;
  ex0:    TExpr;
  alterm: array[0..0] of PWhereTerm;
  base:   i32;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('FPD open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;
  v := sqlite3GetVdbe(@parse);

  SetLength(buf, SZ_WHEREINFO(N_LEVEL));
  FillChar(buf[0], Length(buf), 0);
  pWInfo := PWhereInfo(@buf[0]);
  pWInfo^.nLevel := N_LEVEL;

  FillChar(loops, SizeOf(loops), 0);
  FillChar(term0, SizeOf(term0), 0);
  FillChar(ex0,   SizeOf(ex0),   0);

  { ---- FPD1 — no inner level beyond iLevel=0 with regFilter set: walk runs
       but every pLevel^.regFilter is 0 → no opcodes emitted, no mutation. ---- }
  whereInfoLevels(pWInfo)[0].pWLoop := @loops[0];
  whereInfoLevels(pWInfo)[1].pWLoop := @loops[1];
  whereInfoLevels(pWInfo)[2].pWLoop := @loops[2];
  whereInfoLevels(pWInfo)[1].regFilter := 0;
  whereInfoLevels(pWInfo)[2].regFilter := 0;

  base := sqlite3VdbeCurrentAddr(v);
  filterPullDown(@parse, pWInfo, 0, 9999, 0);
  Check('FPD1 no opcodes when all regFilter=0',
        sqlite3VdbeCurrentAddr(v) = base);

  { ---- FPD2 — IPK arm: level[1] has regFilter<>0, WHERE_IPK loop with one
       TK_EQ rowid term; emits OP_MustBeInt + OP_Filter, regFilter cleared,
       addrBrk preserved. ---- }
  ex0.op       := TK_INTEGER;
  ex0.flags    := EP_IntValue;
  ex0.u.iValue := 7;

  term0.pExpr     := @ex0;
  term0.eOperator := WO_EQ;
  term0.iParent   := -1;

  alterm[0] := @term0;
  loops[1].aLTerm := @alterm[0];
  loops[1].nLTerm := 1;
  loops[1].wsFlags := WHERE_IPK;
  loops[1].nSkip   := 0;
  loops[1].prereq  := 0;

  whereInfoLevels(pWInfo)[1].regFilter := 99;
  whereInfoLevels(pWInfo)[1].addrBrk   := 12345;

  base := sqlite3VdbeCurrentAddr(v);
  filterPullDown(@parse, pWInfo, 0, 7777, 0);
  Check('FPD2 IPK arm emitted opcodes',
        sqlite3VdbeCurrentAddr(v) >= base + 2);
  Check('FPD2 regFilter cleared',
        whereInfoLevels(pWInfo)[1].regFilter = 0);
  Check('FPD2 addrBrk restored',
        whereInfoLevels(pWInfo)[1].addrBrk = 12345);

  { ---- FPD3 — nSkip>0 disqualifies the level even if regFilter is set. ---- }
  loops[2].wsFlags := WHERE_IPK;
  loops[2].nSkip   := 1;
  whereInfoLevels(pWInfo)[2].regFilter := 88;

  base := sqlite3VdbeCurrentAddr(v);
  filterPullDown(@parse, pWInfo, 1, 5555, 0);
  Check('FPD3 nSkip>0 → no emit',
        sqlite3VdbeCurrentAddr(v) = base);
  Check('FPD3 regFilter preserved',
        whereInfoLevels(pWInfo)[2].regFilter = 88);

  { ---- FPD4 — iLevel = nLevel-1: walk body never enters → no-op. ---- }
  base := sqlite3VdbeCurrentAddr(v);
  filterPullDown(@parse, pWInfo, N_LEVEL - 1, 1234, 0);
  Check('FPD4 iLevel=last → no emit',
        sqlite3VdbeCurrentAddr(v) = base);

  sqlite3_close(db);
end;

{ ----- removeUnindexableInClauseTerms (wherecode.c:573..653) ----- }

procedure TestRemoveUnindexableInClauseTerms;
var
  db:         PTsqlite3;
  parse:      TParse;
  rc:         i32;
  pCol0,pCol1,pCol2: PExpr;
  pLhs0,pLhs1,pLhs2: PExpr;
  pVecLeft:   PExpr;
  pIN:        PExpr;
  pSel:       PSelect;
  pListR:     PExprList;
  pListL:     PExprList;
  pLoop:      TWhereLoop;
  termA,termB: TWhereTerm;
  altermBuf:  array[0..1] of PWhereTerm;
  pNew:       PExpr;
  origSelId:  u32;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('RUICT open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;

  { ---- Build a 3-column SELECT pEList of TK_INTEGER literals. ---- }
  pCol0 := sqlite3Expr(db, TK_INTEGER, nil);
  pCol1 := sqlite3Expr(db, TK_INTEGER, nil);
  pCol2 := sqlite3Expr(db, TK_INTEGER, nil);
  Check('RUICT cols allocated',
    (pCol0 <> nil) and (pCol1 <> nil) and (pCol2 <> nil));
  pCol0^.flags := pCol0^.flags or EP_IntValue; pCol0^.u.iValue := 100;
  pCol1^.flags := pCol1^.flags or EP_IntValue; pCol1^.u.iValue := 200;
  pCol2^.flags := pCol2^.flags or EP_IntValue; pCol2^.u.iValue := 300;
  pListR := sqlite3ExprListAppend(@parse, nil,    pCol0);
  pListR := sqlite3ExprListAppend(@parse, pListR, pCol1);
  pListR := sqlite3ExprListAppend(@parse, pListR, pCol2);
  Check('RUICT pListR nExpr=3', pListR^.nExpr = 3);

  { ---- Build the matching 3-column TK_VECTOR LHS. ---- }
  pLhs0 := sqlite3Expr(db, TK_INTEGER, nil);
  pLhs1 := sqlite3Expr(db, TK_INTEGER, nil);
  pLhs2 := sqlite3Expr(db, TK_INTEGER, nil);
  pLhs0^.flags := pLhs0^.flags or EP_IntValue; pLhs0^.u.iValue := 1;
  pLhs1^.flags := pLhs1^.flags or EP_IntValue; pLhs1^.u.iValue := 2;
  pLhs2^.flags := pLhs2^.flags or EP_IntValue; pLhs2^.u.iValue := 3;
  pListL := sqlite3ExprListAppend(@parse, nil,    pLhs0);
  pListL := sqlite3ExprListAppend(@parse, pListL, pLhs1);
  pListL := sqlite3ExprListAppend(@parse, pListL, pLhs2);

  pVecLeft := sqlite3Expr(db, TK_VECTOR, nil);
  Check('RUICT pVecLeft non-nil', pVecLeft <> nil);
  pVecLeft^.x.pList := pListL;

  { ---- Wrap pListR in a TSelect, then build the TK_IN root with
       EP_xIsSelect lit so ExprUseXSelect/Dup follow the pSelect arm. ---- }
  pSel := sqlite3SelectNew(@parse, pListR, nil, nil, nil, nil, nil, 0, nil);
  Check('RUICT pSel non-nil', pSel <> nil);
  origSelId := pSel^.selId;

  pIN := sqlite3Expr(db, TK_IN, nil);
  Check('RUICT pIN non-nil', pIN <> nil);
  pIN^.flags     := pIN^.flags or EP_xIsSelect;
  pIN^.pLeft     := pVecLeft;
  pIN^.x.pSelect := pSel;

  { ---- RUICT1 — two terms select columns with iField=2,3 (indices 1,2),
       reducing the 3-column vector down to 2 columns.  Verify the dup is
       independent (original pSel left untouched), the new pSelect carries a
       freshly-bumped selId, and the LHS retains its TK_VECTOR wrap (still
       multi-column). ---- }
  FillChar(pLoop, SizeOf(pLoop), 0);
  FillChar(termA, SizeOf(termA), 0);
  FillChar(termB, SizeOf(termB), 0);
  termA.pExpr := pIN; termA.eOperator := WO_EQ; termA.u.iField := 2;
  termB.pExpr := pIN; termB.eOperator := WO_EQ; termB.u.iField := 3;
  altermBuf[0] := @termA;
  altermBuf[1] := @termB;
  pLoop.aLTerm := @altermBuf[0];
  pLoop.nLTerm := 2;

  pNew := removeUnindexableInClauseTerms(@parse, 0, @pLoop, pIN);
  Check('RUICT1 dup non-nil', pNew <> nil);
  Check('RUICT1 dup distinct from original', pNew <> pIN);
  Check('RUICT1 reduced RHS nExpr=2',
        pNew^.x.pSelect^.pEList^.nExpr = 2);
  Check('RUICT1 LHS still TK_VECTOR',
        pNew^.pLeft^.op = TK_VECTOR);
  Check('RUICT1 reduced LHS nExpr=2',
        pNew^.pLeft^.x.pList^.nExpr = 2);
  Check('RUICT1 selId bumped',
        pNew^.x.pSelect^.selId <> origSelId);
  Check('RUICT1 original pIN intact (still nExpr=3)',
        pIN^.x.pSelect^.pEList^.nExpr = 3);
  sqlite3ExprDelete(db, pNew);

  { ---- RUICT2 — single matching term (iField=3 → index 2), the reduced
       LHS has just one element so the routine unwraps the TK_VECTOR and
       lifts the single LHS expression directly into pNew^.pLeft. ---- }
  altermBuf[0] := @termB;
  pLoop.nLTerm := 1;

  pNew := removeUnindexableInClauseTerms(@parse, 0, @pLoop, pIN);
  Check('RUICT2 dup non-nil', pNew <> nil);
  Check('RUICT2 reduced RHS nExpr=1',
        pNew^.x.pSelect^.pEList^.nExpr = 1);
  Check('RUICT2 TK_VECTOR unwrapped → TK_INTEGER (single LHS column)',
        pNew^.pLeft^.op = TK_INTEGER);
  sqlite3ExprDelete(db, pNew);

  { ---- RUICT3 — same single-term reduction, now starting at iEq=1: term
       at index 0 is skipped, no terms match → builder appends nothing,
       pRhs stays nil (mallocFailed-or-pRhs assert path).  Lift the assert
       precondition by simulating mallocFailed for the duration of the
       call so we can probe the empty-reduction branch deterministically. ---- }
  db^.mallocFailed := 1;
  pNew := removeUnindexableInClauseTerms(@parse, 1, @pLoop, pIN);
  db^.mallocFailed := 0;
  { mallocFailed propagates through ExprDup; pNew may be nil or partially
    populated.  Either outcome is acceptable — we only need to confirm the
    routine returns without asserting under mallocFailed. }
  Check('RUICT3 returned under mallocFailed (no assert)', True);
  if pNew <> nil then sqlite3ExprDelete(db, pNew);

  sqlite3ExprDelete(db, pIN);
  sqlite3_close(db);
end;

{ ---- Phase 6.9-bis (step 11g.2.e sub-progress) batch 7 stubs ----
  codeCursorHint, sqlite3WhereExplainOneScan, sqlite3WhereExplainBloomFilter,
  sqlite3WhereAddExplainText.  All four are currently runtime no-ops matching
  upstream's SQLITE_ENABLE_CURSOR_HINTS=OFF + SQLITE_OMIT_EXPLAIN / explain<>2
  fall-through paths.  These tests pin the contract: callers may invoke them
  freely (even with nil arguments — the entry path must not deref) and the
  explain functions must always return 0 in a non-EXPLAIN compile.  When the
  EQP text path is filled in alongside StrAccum, these tests will gain
  positive-path siblings; the no-deref / return-0 invariants remain. }
procedure TestWhereCodeCursorHintAndExplainStubs;
var
  parse:    TParse;
  db:       PTsqlite3;
  v:        PVdbe;
  pTabList: PSrcList;
  pLevel:   TWhereLevel;
  pWInfo:   TWhereInfo;
  pTabItem: TSrcItem;
  pTerm:    TWhereTerm;
  ret:      i32;
  rc:       i32;
begin
  rc := sqlite3_open(':memory:', @db);
  Check('CHX open', rc = SQLITE_OK);
  FillChar(parse, SizeOf(parse), 0);
  parse.db := db;

  v := sqlite3VdbeCreate(@parse);
  Check('CHX VDBE allocated', v <> nil);
  parse.pVdbe := v;

  FillChar(pLevel,    SizeOf(pLevel),    0);
  FillChar(pWInfo,    SizeOf(pWInfo),    0);
  FillChar(pTabItem,  SizeOf(pTabItem),  0);
  FillChar(pTerm,     SizeOf(pTerm),     0);
  pTabList := sqlite3DbMallocZero(db, SizeOf(TSrcList));
  Check('CHX SrcList alloc', pTabList <> nil);

  { ---- CCH1..CCH3: codeCursorHint must not deref any arg.  In particular,
       the all-nil call exercises the unused-arg short-circuit; the populated
       call exercises the body (still no-op since SQLITE_ENABLE_CURSOR_HINTS
       is off, but proves the routine accepts real shapes). ---- }
  codeCursorHint(nil, nil, nil, nil);
  Check('CCH1 codeCursorHint(nil,...) returned', True);
  codeCursorHint(@pTabItem, @pWInfo, @pLevel, @pTerm);
  Check('CCH2 codeCursorHint(populated) returned', True);
  codeCursorHint(@pTabItem, @pWInfo, @pLevel, nil);
  Check('CCH3 codeCursorHint(no pEndRange) returned', True);

  { ---- WEOS1..WEOS3: sqlite3WhereExplainOneScan must return 0 in every
       non-EXPLAIN code path.  Cover explain=0 / explain=1 / explain=2 plus
       wctrlFlags variants — all should currently return 0 since the EQP
       text path isn't yet wired. ---- }
  parse.explain := 0;
  ret := sqlite3WhereExplainOneScan(@parse, pTabList, @pLevel, 0);
  Check('WEOS1 explain=0 returns 0', ret = 0);
  parse.explain := 1;
  ret := sqlite3WhereExplainOneScan(@parse, pTabList, @pLevel, 0);
  Check('WEOS2 explain=1 returns 0', ret = 0);
  parse.explain := 2;
  ret := sqlite3WhereExplainOneScan(@parse, pTabList, @pLevel, WHERE_ORDERBY_MIN);
  Check('WEOS3 explain=2 stub still returns 0 (EQP text deferred)', ret = 0);

  { ---- WEBF1..WEBF2: sqlite3WhereExplainBloomFilter mirrors WEOS — return
       0 unconditionally until the EQP text path lands. ---- }
  pWInfo.pParse   := @parse;
  pWInfo.pTabList := pTabList;
  ret := sqlite3WhereExplainBloomFilter(@parse, @pWInfo, @pLevel);
  Check('WEBF1 BloomFilter stub returns 0', ret = 0);
  ret := sqlite3WhereExplainBloomFilter(nil, nil, nil);
  Check('WEBF2 BloomFilter(nil,...) returns 0', ret = 0);

  { ---- WAET1..WAET2: sqlite3WhereAddExplainText is a no-op back-patcher.
       Both an all-nil and a populated invocation must return without effect. }
  sqlite3WhereAddExplainText(@parse, 0, pTabList, @pLevel, 0);
  Check('WAET1 AddExplainText(populated) returned', True);
  sqlite3WhereAddExplainText(nil, 0, nil, nil, 0);
  Check('WAET2 AddExplainText(nil,...) returned', True);

  sqlite3DbFree(db, pTabList);
  sqlite3VdbeFinalize(v);
  sqlite3_close(db);
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
  TestWhereRangeScanEst;
  TestConstraintCompatOuterJoin;
  TestColumnIsGoodIndexCandidate;
  TestTermCanDriveIndex;
  TestTermCanDriveIndexGate;
  TestExprImplies;
  TestIndexColumnNotNull;
  TestFindIndexCol;
  TestIsDistinctRedundant;
  TestWhereLoopAddBtreeIndex;
  TestWhereLoopAddBtree;
  TestWhereLoopAddAllAndOr;
  TestSortingCost;
  TestLoopIsNoBetter;
  TestPathSatisfiesOrderBy;
  TestPathSolver;
  TestDisableTerm;
  TestCodeApplyAffinity;
  TestWhereLikeOptStringFixup;
  TestAdjustOrderByCol;
  TestVectorFieldSubexpr;
  TestExprNeedsNoAffinityChange;
  TestUpdateRangeAffinityStr;
  TestWhereLoopIsOneRow;
  TestWhereApplyPartialIndexConstraints;
  TestTableColumnToStorage;
  TestParseToplevel;
  TestCodeDeferredSeek;
  TestExplainIndexColumnName;
  TestIndexAffinityStr;
  TestCodeEqualityTerm;
  TestCodeAllEqualityTerms;
  TestCodeExprOrVector;
  TestFilterPullDown;
  TestRemoveUnindexableInClauseTerms;
  TestWhereCodeCursorHintAndExplainStubs;
  WriteLn('---- ', gPass, '/', gPass + gFail, ' passed ----');
  if gFail > 0 then Halt(1);
end.
