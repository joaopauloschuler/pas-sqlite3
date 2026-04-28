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
program TestVdbeSort;
{
  Phase 5.7 gate test — vdbesort.c external sorter.

  The full sorter requires KeyInfo / UnpackedRecord (Phase 6+) and PMA merge
  logic.  This test exercises the null-guard and state-check behaviour of all
  eight public functions, plus the lifecycle: Init → Close.

    T1  sqlite3VdbeSorterInit with nil cursor → SQLITE_MISUSE
    T2  sqlite3VdbeSorterInit with nil pKeyInfo → SQLITE_ERROR (not panics)
    T3  sqlite3VdbeSorterReset(nil) → no crash
    T4  sqlite3VdbeSorterClose with cursor having nil pSorter → no crash
    T5  sqlite3VdbeSorterWrite(nil) → SQLITE_MISUSE
    T6  sqlite3VdbeSorterRewind(nil) → SQLITE_MISUSE; pbEof set to 1
    T7  sqlite3VdbeSorterNext(nil) → SQLITE_MISUSE
    T8  sqlite3VdbeSorterRowkey(nil) → SQLITE_MISUSE
    T9  sqlite3VdbeSorterCompare(nil) → SQLITE_MISUSE; pRes set to 0
    T10 Init→Close lifecycle (with real KeyInfo=nil cursor, confirms Close
        is safe after Init fails and leaves pSorter=nil)

  Gate: T1–T10 all PASS.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe;

{ ===== helpers ============================================================== }

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(name: string; cond: Boolean);
begin
  if cond then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ Build a minimal VdbeCursor in allocated memory — no btree, no KeyInfo. }
function MakeMinCursor(pDb: PTsqlite3): PVdbeCursor;
var
  pCsr: PVdbeCursor;
begin
  pCsr := PVdbeCursor(sqlite3DbMallocZero(pDb, SizeOf(TVdbeCursor)));
  if pCsr = nil then begin Result := nil; Exit; end;
  pCsr^.eCurType   := CURTYPE_SORTER;
  pCsr^.pKeyInfo   := nil;
  pCsr^.uc.pSorter := nil;
  Result := pCsr;
end;

{ ===== T1: SorterInit with nil cursor ====================================== }

procedure TestInitNilCursor;
var
  md: Tsqlite3;
  rc: i32;
begin
  WriteLn('T1: sqlite3VdbeSorterInit(nil cursor) → SQLITE_MISUSE');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;
  rc := sqlite3VdbeSorterInit(@md, 1, nil);
  Check('T1 rc=MISUSE', rc = SQLITE_MISUSE);
end;

{ ===== T2: SorterInit with nil pKeyInfo ==================================== }

procedure TestInitNilKeyInfo;
var
  md:  Tsqlite3;
  pCsr: PVdbeCursor;
  rc:  i32;
begin
  WriteLn('T2: sqlite3VdbeSorterInit(nil pKeyInfo) → SQLITE_ERROR');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;
  pCsr := MakeMinCursor(@md);
  if pCsr = nil then begin Check('T2 alloc', False); Exit; end;

  rc := sqlite3VdbeSorterInit(@md, 1, pCsr);
  Check('T2 rc=ERROR', rc = SQLITE_ERROR);
  Check('T2 pSorter=nil', pCsr^.uc.pSorter = nil);

  sqlite3DbFree(@md, pCsr);
end;

{ ===== T3: SorterReset(nil) ================================================ }

procedure TestResetNil;
var
  md: Tsqlite3;
begin
  WriteLn('T3: sqlite3VdbeSorterReset(nil) → no crash');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;
  sqlite3VdbeSorterReset(@md, nil);  { must not crash }
  Check('T3 no crash', True);
end;

{ ===== T4: SorterClose with nil pSorter in cursor ========================== }

procedure TestCloseNilSorter;
var
  md:  Tsqlite3;
  pCsr: PVdbeCursor;
begin
  WriteLn('T4: sqlite3VdbeSorterClose with nil pSorter → no crash');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;
  pCsr := MakeMinCursor(@md);
  if pCsr = nil then begin Check('T4 alloc', False); Exit; end;

  sqlite3VdbeSorterClose(@md, pCsr);  { pSorter=nil, must not crash }
  Check('T4 no crash', True);

  sqlite3DbFree(@md, pCsr);
end;

{ ===== T5–T9: nil cursor guards for all other functions ==================== }

procedure TestNilCursorGuards;
var
  md:  Tsqlite3;
  m:   TMem;
  res: i32;
  rc:  i32;
  eof: i32;
begin
  WriteLn('T5–T9: nil cursor → SQLITE_MISUSE for Write/Rewind/Next/Rowkey/Compare');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;
  FillChar(m, SizeOf(m), 0);

  rc := sqlite3VdbeSorterWrite(nil, @m);
  Check('T5 Write=MISUSE', rc = SQLITE_MISUSE);

  eof := 0;
  rc := sqlite3VdbeSorterRewind(nil, eof);
  Check('T6 Rewind=MISUSE', rc = SQLITE_MISUSE);
  Check('T6 pbEof=1', eof = 1);

  rc := sqlite3VdbeSorterNext(@md, nil);
  Check('T7 Next=MISUSE', rc = SQLITE_MISUSE);

  rc := sqlite3VdbeSorterRowkey(nil, @m);
  Check('T8 Rowkey=MISUSE', rc = SQLITE_MISUSE);

  res := 999;
  rc := sqlite3VdbeSorterCompare(nil, 0, nil, 0, res);
  Check('T9 Compare=MISUSE', rc = SQLITE_MISUSE);
  Check('T9 pRes=0', res = 0);
end;

{ ===== T10: Init(fails)→Close lifecycle ==================================== }

procedure TestInitCloseCycle;
var
  md:  Tsqlite3;
  pCsr: PVdbeCursor;
  rc:  i32;
begin
  WriteLn('T10: Init(fails) → Close is safe');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;
  pCsr := MakeMinCursor(@md);
  if pCsr = nil then begin Check('T10 alloc', False); Exit; end;

  rc := sqlite3VdbeSorterInit(@md, 1, pCsr);
  Check('T10 init fails', rc <> SQLITE_OK);  { pKeyInfo=nil → SQLITE_ERROR }

  { pSorter is still nil after failed init; Close must be safe }
  sqlite3VdbeSorterClose(@md, pCsr);
  Check('T10 close safe', True);

  sqlite3DbFree(@md, pCsr);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeSort — Phase 5.7 gate test ===');
  WriteLn;

  TestInitNilCursor;    WriteLn;
  TestInitNilKeyInfo;   WriteLn;
  TestResetNil;         WriteLn;
  TestCloseNilSorter;   WriteLn;
  TestNilCursorGuards;  WriteLn;
  TestInitCloseCycle;   WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
