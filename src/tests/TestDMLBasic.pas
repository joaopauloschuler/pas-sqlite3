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
{$I ../passqlite3.inc}
{
  TestDMLBasic.pas — Phase 6.4 gate test.

  Tests type sizes and struct offsets for DML types (TTrigger, TTriggerStep,
  TAutoincInfo, TTriggerPrg, TReturning, TUpsert) and exercises the upsert.c
  public API stubs (sqlite3UpsertNew, sqlite3UpsertDup, sqlite3UpsertDelete,
  sqlite3UpsertNextIsIPK, sqlite3UpsertOfIndex, sqlite3UpsertOfIndex).

  Does NOT require a live database — all tests run against the struct layout
  and the stub API only.

  Expected: Results: N passed, 0 failed.
}

program TestDMLBasic;

uses
  passqlite3types, passqlite3util, passqlite3os,
  passqlite3pcache, passqlite3vdbe, passqlite3codegen;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin
    Inc(gPass);
    WriteLn('  PASS ', msg);
  end else begin
    Inc(gFail);
    WriteLn('  FAIL ', msg);
  end;
end;

// ---------------------------------------------------------------------------
// T1–T8: struct size checks (verified against GCC x86-64)
// ---------------------------------------------------------------------------

procedure TestStructSizes;
begin
  Expect(SizeOf(TUpsert)      = 88,  'SizeOf(TUpsert)=88');
  Expect(SizeOf(TAutoincInfo) = 24,  'SizeOf(TAutoincInfo)=24');
  Expect(SizeOf(TTriggerPrg)  = 40,  'SizeOf(TTriggerPrg)=40');
  Expect(SizeOf(TTrigger)     = 72,  'SizeOf(TTrigger)=72');
  Expect(SizeOf(TTriggerStep) = 88,  'SizeOf(TTriggerStep)=88');
  Expect(SizeOf(TReturning)   = 232, 'SizeOf(TReturning)=232');
end;

// ---------------------------------------------------------------------------
// T9–T16: field offset checks via field-address arithmetic
// ---------------------------------------------------------------------------

procedure TestFieldOffsets;
var
  u: TUpsert;
  t: TTrigger;
  s: TTriggerStep;
  a: TAutoincInfo;
  p: TTriggerPrg;
  r: TReturning;
begin
  { TUpsert }
  FillChar(u, SizeOf(u), 0);
  Expect(PByte(@u.pNextUpsert) - PByte(@u)  = 32, 'TUpsert.pNextUpsert@32');
  Expect(PByte(@u.isDoUpdate)  - PByte(@u)  = 40, 'TUpsert.isDoUpdate@40');
  Expect(PByte(@u.pToFree)     - PByte(@u)  = 48, 'TUpsert.pToFree@48');
  Expect(PByte(@u.pUpsertIdx)  - PByte(@u)  = 56, 'TUpsert.pUpsertIdx@56');
  Expect(PByte(@u.pUpsertSrc)  - PByte(@u)  = 64, 'TUpsert.pUpsertSrc@64');
  Expect(PByte(@u.regData)     - PByte(@u)  = 72, 'TUpsert.regData@72');

  { TTrigger }
  FillChar(t, SizeOf(t), 0);
  Expect(PByte(@t.op)          - PByte(@t)  = 16, 'TTrigger.op@16');
  Expect(PByte(@t.pWhen)       - PByte(@t)  = 24, 'TTrigger.pWhen@24');
  Expect(PByte(@t.step_list)   - PByte(@t)  = 56, 'TTrigger.step_list@56');
  Expect(PByte(@t.pNext)       - PByte(@t)  = 64, 'TTrigger.pNext@64');

  { TTriggerStep }
  FillChar(s, SizeOf(s), 0);
  Expect(PByte(@s.pTrig)       - PByte(@s)  = 8,  'TTriggerStep.pTrig@8');
  Expect(PByte(@s.pUpsert)     - PByte(@s)  = 56, 'TTriggerStep.pUpsert@56');
  Expect(PByte(@s.pNext)       - PByte(@s)  = 72, 'TTriggerStep.pNext@72');
  Expect(PByte(@s.pLast)       - PByte(@s)  = 80, 'TTriggerStep.pLast@80');

  { TAutoincInfo }
  FillChar(a, SizeOf(a), 0);
  Expect(PByte(@a.pTab)        - PByte(@a)  = 8,  'TAutoincInfo.pTab@8');
  Expect(PByte(@a.iDb)         - PByte(@a)  = 16, 'TAutoincInfo.iDb@16');
  Expect(PByte(@a.regCtr)      - PByte(@a)  = 20, 'TAutoincInfo.regCtr@20');

  { TTriggerPrg }
  FillChar(p, SizeOf(p), 0);
  Expect(PByte(@p.pNext)       - PByte(@p)  = 8,  'TTriggerPrg.pNext@8');
  Expect(PByte(@p.orconf)      - PByte(@p)  = 24, 'TTriggerPrg.orconf@24');
  Expect(PByte(@p.aColmask)    - PByte(@p)  = 28, 'TTriggerPrg.aColmask@28');

  { TReturning }
  FillChar(r, SizeOf(r), 0);
  Expect(PByte(@r.retTrig)     - PByte(@r)  = 16,  'TReturning.retTrig@16');
  Expect(PByte(@r.retTStep)    - PByte(@r)  = 88,  'TReturning.retTStep@88');
  Expect(PByte(@r.iRetCur)     - PByte(@r)  = 176, 'TReturning.iRetCur@176');
  Expect(PByte(@r.zName)       - PByte(@r)  = 188, 'TReturning.zName@188');
end;

// ---------------------------------------------------------------------------
// T17–T22: sqlite3UpsertNew / UpsertDelete / UpsertDup lifecycle
// ---------------------------------------------------------------------------

procedure TestUpsertLifecycle;
var
  u1, u2, u3: PUpsert;
begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;
  sqlite3MallocInit;

  { T17: sqlite3UpsertNew with nil args returns an Upsert with isDoUpdate=0 }
  u1 := sqlite3UpsertNew(nil, nil, nil, nil, nil, nil);
  Expect(u1 <> nil,            'UpsertNew: not nil');
  Expect(u1^.isDoUpdate = 0,   'UpsertNew: isDoUpdate=0 (DO NOTHING)');
  Expect(u1^.pNextUpsert = nil,'UpsertNew: pNextUpsert=nil');

  { T18: sqlite3UpsertDup produces an independent copy }
  u2 := sqlite3UpsertDup(nil, u1);
  Expect(u2 <> nil,            'UpsertDup: not nil');
  Expect(u2 <> u1,             'UpsertDup: different pointer');
  Expect(u2^.isDoUpdate = 0,   'UpsertDup: isDoUpdate preserved');

  { T19: sqlite3UpsertNextIsIPK: u1.pNextUpsert=nil → 0 }
  Expect(sqlite3UpsertNextIsIPK(u1) = 0, 'UpsertNextIsIPK: no next → 0');

  { T20: chain two upserts, second has pUpsertIdx=nil (= IPK) → NextIsIPK=1 }
  u3 := sqlite3UpsertNew(nil, nil, nil, nil, nil, nil);
  u3^.pUpsertIdx := nil;       { nil = INTEGER PRIMARY KEY }
  u1^.pNextUpsert := u3;
  Expect(sqlite3UpsertNextIsIPK(u1) = 1, 'UpsertNextIsIPK: next is IPK → 1');

  { T21: sqlite3UpsertOfIndex with nil index: u1.pUpsertIdx=nil (initialised
    to zero), so u1 itself matches pIdx=nil and is returned first }
  Expect(sqlite3UpsertOfIndex(u1, nil) = u1, 'UpsertOfIndex: nil idx → u1');

  { T22: sqlite3UpsertDelete frees the chain without crashing }
  u1^.pNextUpsert := u3;
  sqlite3UpsertDelete(nil, u1);
  sqlite3UpsertDelete(nil, u2);
  Expect(True, 'UpsertDelete: no crash');
end;

// ---------------------------------------------------------------------------
// T23–T26: trigger stub API (no crash, correct nil returns)
// ---------------------------------------------------------------------------

procedure TestTriggerStubs;
var
  mask: u32;
  pList: PTrigger;
  tabFixture: TTable;
begin
  FillChar(tabFixture, SizeOf(tabFixture), 0); { eTabType=0 → not VIEW }
  { T23: TriggerList returns nil for nil parse/table }
  pList := sqlite3TriggerList(nil, nil);
  Expect(pList = nil, 'TriggerList(nil,nil)=nil');

  { T24: TriggersExist returns nil }
  mask := $DEADBEEF;
  pList := sqlite3TriggersExist(nil, nil, TK_INSERT, nil, @mask);
  Expect(pList = nil,   'TriggersExist=nil');
  Expect(mask = 0,      'TriggersExist mask cleared');

  { T25: sqlite3DeleteTrigger(nil) is safe }
  sqlite3DeleteTrigger(nil, nil);
  Expect(True, 'DeleteTrigger(nil) no crash');

  { T26: TriggerColmask returns 0 with empty trigger list (uses a zeroed
    TTable fixture — non-VIEW — because the productive port now reads
    pTab^.eTabType, matching C trigger.c:1524 which also requires a real
    Table*).  Original stub-era call passed nil pTab and skipped the check. }
  Expect(sqlite3TriggerColmask(nil,nil,nil,0,0,@tabFixture,OE_Abort) = 0,
    'TriggerColmask=0');
end;

// ---------------------------------------------------------------------------
// T27–T30: OE_* / TRIGGER_* constant values
// ---------------------------------------------------------------------------

procedure TestConstants;
begin
  Expect(OE_None     = 0,  'OE_None=0');
  Expect(OE_Rollback = 1,  'OE_Rollback=1');
  Expect(OE_Abort    = 2,  'OE_Abort=2');
  Expect(OE_Ignore   = 4,  'OE_Ignore=4');
  Expect(OE_Replace  = 5,  'OE_Replace=5');
  Expect(TRIGGER_BEFORE = 1, 'TRIGGER_BEFORE=1');
  Expect(TRIGGER_AFTER  = 2, 'TRIGGER_AFTER=2');
  Expect(OPFLAG_NCHANGE = $01, 'OPFLAG_NCHANGE=$01');
  Expect(OPFLAG_LASTROWID = $20, 'OPFLAG_LASTROWID=$20');
end;

begin
  gPass := 0; gFail := 0;
  WriteLn('=== TestDMLBasic (Phase 6.4) ===');

  TestStructSizes;
  TestFieldOffsets;
  TestUpsertLifecycle;
  TestTriggerStubs;
  TestConstants;

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed.');
  if gFail > 0 then Halt(1);
end.
