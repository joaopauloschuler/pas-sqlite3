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
program TestPagerCrash;

{
  Phase 3.B.2c -- Atomic commit, savepoints, rollback-on-error gate tests.

  Tests crash recovery, savepoint behaviour, and rollback-on-error paths in
  the Pascal pager (journal_mode=DELETE).

  NOTE: Data checks always use page 2 (never page 1).  Page 1 is the database
  header page; on every commit the pager overwrites bytes 24-27, 92-95, 96-99
  of page 1 with the change-counter and version, so a uniform fill of page 1
  never survives a commit intact.  Page 2 is unmodified by pager infrastructure
  and is safe for byte-pattern verification.

    T1  Multi-page commit atomicity: pages 2 and 3 written in one transaction,
        committed, reopened — both carry the new data.
    T2  Fork-based crash recovery: child writes $FF to page 2 + CommitPhaseOne,
        then exits without CommitPhaseTwo; parent reopens and hot-journal
        playback reverts page 2 to $01.
    T3  Savepoint rollback reverts data: SP1 opened, page 2 modified to $02,
        ROLLBACK SP1, outer committed — page 2 = $01 after reopen.
    T4  Nested savepoint partial rollback: SP1 writes $AA to page 2, SP2 writes
        $BB to page 3, ROLLBACK SP2, commit — page 2 = $AA, page 3 = $20.
    T5  Savepoint release + outer rollback: SP1($BB on page 2) released,
        outer rolled back — page 2 = $01 after reopen.
    T6  Truncated journal (empty file) is safe: zero-byte journal left on
        disk, pager reopens without crash, page 2 unchanged ($CC).
    T7  Multiple transactions then crash: commit $AA, commit $BB, crash mid-$CC
        (CommitPhaseOne + fork-exit), reopen — page 2 = $BB.
    T8  C-reference differential after crash recovery: after hot-journal
        playback the resulting .db is openable by the C library.
    T9  Journal truncated mid-header: journal header cut to 8 bytes,
        pager reopens safely, page 2 unchanged ($55).
   T10  Rollback-on-error: pager put into errCode=SQLITE_IOERR state,
        sqlite3PagerRollback returns SQLITE_IOERR cleanly.

  Prints PASS/FAIL per test.  Exits 0 if ALL PASS, 1 on any failure.

  Run with:
    LD_LIBRARY_PATH=src/ bin/TestPagerCrash
}

uses
  SysUtils,
  BaseUnix,
  UnixType,
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  csqlite3;

const
  PAGE_SIZE = 4096;

var
  gAllPass: Boolean = True;

procedure Fail(const test, msg: string);
begin
  WriteLn('FAIL [', test, ']: ', msg);
  gAllPass := False;
end;

procedure Pass(const test: string);
begin
  WriteLn('PASS [', test, ']');
end;

procedure DummyReinit(pPg: PDbPage);
begin
end;

{ ------------------------------------------------------------------ helpers }

function OpenWritePager(const dbPath: string; out pPgr: PPager): i32;
var
  pVfs: Psqlite3_vfs;
  vfsFlags: i32;
  pageSize: u32;
begin
  pPgr := nil;
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Result := SQLITE_ERROR; Exit; end;
  vfsFlags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MAIN_DB;
  Result := sqlite3PagerOpen(pVfs, pPgr, PChar(dbPath), 0, 0, vfsFlags, @DummyReinit);
  if Result <> SQLITE_OK then Exit;
  pageSize := PAGE_SIZE;
  Result := sqlite3PagerSetPagesize(pPgr, @pageSize, -1);
end;

procedure FillPage(pPg: PDbPage; b: u8);
begin
  FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, b);
end;

{ Write fill byte b to page pgno, committing the transaction. Pager must
  already be in READER or OPEN state; SharedLock is called internally. }
function WriteAndCommit(pPgr: PPager; pgno: Pgno; b: u8): i32;
var
  pPg: PDbPage;
  rc: i32;
begin
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  rc := sqlite3PagerBegin(pPgr, 0, 0);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  pPg := nil;
  rc := sqlite3PagerGet(pPgr, pgno, @pPg, 0);
  if (rc <> SQLITE_OK) or (pPg = nil) then begin Result := rc; Exit; end;
  rc := sqlite3PagerWrite(pPg);
  if rc = SQLITE_OK then FillPage(pPg, b);
  sqlite3PagerUnref(pPg);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  Result := rc;
end;

{ Verify that all PAGE_SIZE bytes of page pgno equal b. }
function PageIs(pPgr: PPager; pgno: Pgno; b: u8): Boolean;
var
  pPg: PDbPage;
  rc: i32;
  pData: Pu8;
  i: i32;
begin
  Result := False;
  pPg := nil;
  rc := sqlite3PagerGet(pPgr, pgno, @pPg, 0);
  if (rc <> SQLITE_OK) or (pPg = nil) then Exit;
  pData := Pu8(sqlite3PagerGetData(pPg));
  Result := True;
  for i := 0 to PAGE_SIZE - 1 do
    if (pData + i)^ <> b then begin Result := False; Break; end;
  sqlite3PagerUnref(pPg);
end;

{ ------------------------------------------------------------------ T1 }
{ Multi-page commit: write to pages 2 and 3, commit, reopen, verify. }
procedure T1_MultiPageCommit;
var
  pPgr: PPager;
  rc: i32;
  path: string;
  pPg2, pPg3: PDbPage;
  ok: Boolean;
begin
  path := '/tmp/pas_crash_t1.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T1', 'open failed ' + IntToStr(rc)); Exit; end;

  sqlite3PagerSharedLock(pPgr);
  rc := sqlite3PagerBegin(pPgr, 0, 0);
  if rc <> SQLITE_OK then begin Fail('T1', 'begin failed'); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;

  pPg2 := nil; pPg3 := nil;
  sqlite3PagerGet(pPgr, 2, @pPg2, 0); sqlite3PagerWrite(pPg2); FillPage(pPg2, $22);
  sqlite3PagerGet(pPgr, 3, @pPg3, 0); sqlite3PagerWrite(pPg3); FillPage(pPg3, $33);
  sqlite3PagerUnref(pPg2);
  sqlite3PagerUnref(pPg3);

  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);

  if rc <> SQLITE_OK then
  begin Fail('T1', 'commit failed ' + IntToStr(rc)); FpUnlink(PChar(path)); Exit; end;

  { Reopen and verify pages 2 and 3 (page 1 has change-counter, skip it) }
  rc := OpenWritePager(path, pPgr);
  sqlite3PagerSharedLock(pPgr);
  ok := PageIs(pPgr, 2, $22) and PageIs(pPgr, 3, $33);
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  if ok then Pass('T1') else Fail('T1', 'page 2 or 3 data mismatch after reopen');
end;

{ ------------------------------------------------------------------ T2 }
{ Fork-based crash recovery.  Child writes $FF to page 2, CommitPhaseOne,
  then exits (crash) without CommitPhaseTwo.  Parent reopens, hot-journal
  playback restores page 2 to $01. }
procedure T2_ForkCrashRecovery;
var
  pPgr: PPager;
  rc: i32;
  path: string;
  pid: TPid;
  status: cint;
  pPg: PDbPage;
begin
  path := '/tmp/pas_crash_t2.db';
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));

  { Initial commit: page 2 = $01 }
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T2', 'initial open failed'); Exit; end;
  rc := WriteAndCommit(pPgr, 2, $01);
  sqlite3PagerClose(pPgr, nil);
  if rc <> SQLITE_OK then begin Fail('T2', 'initial commit failed'); FpUnlink(PChar(path)); Exit; end;

  { Fork: child opens pager, writes $FF to page 2, CommitPhaseOne, exits }
  pid := FpFork;
  if pid < 0 then begin Fail('T2', 'fork failed'); FpUnlink(PChar(path)); Exit; end;

  if pid = 0 then
  begin
    rc := OpenWritePager(path, pPgr);
    if rc = SQLITE_OK then
    begin
      sqlite3PagerSharedLock(pPgr);
      sqlite3PagerBegin(pPgr, 0, 0);
      pPg := nil;
      sqlite3PagerGet(pPgr, 2, @pPg, 0);
      sqlite3PagerWrite(pPg);
      FillPage(pPg, $FF);
      sqlite3PagerUnref(pPg);
      sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
      { Crash: close raw FDs so journal stays on disk }
      sqlite3OsClose(pPgr^.jfd);
      sqlite3OsClose(pPgr^.fd);
    end;
    FpExit(0);
  end;

  FpWaitPid(pid, @status, 0);

  { Parent reopens: SharedLock detects hot journal, playback restores page 2 }
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then
  begin Fail('T2', 'reopen after crash failed ' + IntToStr(rc)); FpUnlink(PChar(path)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T2', 'SharedLock after crash returned ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit;
  end;

  if PageIs(pPgr, 2, $01) then
    Pass('T2')
  else if PageIs(pPgr, 2, $FF) then
    Fail('T2', 'hot journal NOT replayed: crashed $FF write still present')
  else
    Fail('T2', 'unexpected page 2 content after crash recovery');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ------------------------------------------------------------------ T3 }
{ Savepoint rollback: SP1 writes $02 to page 2, ROLLBACK SP1, commit outer.
  After reopen page 2 = $01 (initial). }
procedure T3_SavepointRollbackReverts;
var
  pPgr: PPager;
  rc: i32;
  path: string;
  pPg: PDbPage;
begin
  path := '/tmp/pas_crash_t3.db';
  FpUnlink(PChar(path));

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T3', 'open failed'); Exit; end;
  WriteAndCommit(pPgr, 2, $01);

  { Outer begin }
  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);
  rc := sqlite3PagerOpenSavepoint(pPgr, 1);
  if rc <> SQLITE_OK then
  begin Fail('T3', 'OpenSavepoint failed'); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;

  pPg := nil;
  sqlite3PagerGet(pPgr, 2, @pPg, 0);
  sqlite3PagerWrite(pPg);
  FillPage(pPg, $02);
  sqlite3PagerUnref(pPg);

  rc := sqlite3PagerSavepoint(pPgr, SAVEPOINT_ROLLBACK, 0);
  if rc <> SQLITE_OK then
  begin Fail('T3', 'ROLLBACK SP failed ' + IntToStr(rc)); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);

  rc := OpenWritePager(path, pPgr);
  sqlite3PagerSharedLock(pPgr);
  if PageIs(pPgr, 2, $01) then
    Pass('T3')
  else
    Fail('T3', 'page 2 not $01 after savepoint rollback');
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ------------------------------------------------------------------ T4 }
{ Nested savepoint partial rollback.
  Initial: page2=$10, page3=$20.
  SP1: page2=$AA.  SP2: page3=$BB.
  ROLLBACK SP2.  Commit outer.
  After reopen: page2=$AA (SP1 committed), page3=$20 (SP2 rolled back). }
procedure T4_NestedSavepointPartialRollback;
var
  pPgr: PPager;
  rc: i32;
  path: string;
  pPg: PDbPage;
begin
  path := '/tmp/pas_crash_t4.db';
  FpUnlink(PChar(path));

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T4', 'open failed'); Exit; end;

  { Initial: page2=$10, page3=$20 }
  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);
  pPg := nil;
  sqlite3PagerGet(pPgr, 2, @pPg, 0); sqlite3PagerWrite(pPg); FillPage(pPg, $10); sqlite3PagerUnref(pPg);
  pPg := nil;
  sqlite3PagerGet(pPgr, 3, @pPg, 0); sqlite3PagerWrite(pPg); FillPage(pPg, $20); sqlite3PagerUnref(pPg);
  sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  sqlite3PagerCommitPhaseTwo(pPgr);

  { Outer begin }
  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);

  { SP1: page2=$AA }
  sqlite3PagerOpenSavepoint(pPgr, 1);
  pPg := nil;
  sqlite3PagerGet(pPgr, 2, @pPg, 0); sqlite3PagerWrite(pPg); FillPage(pPg, $AA); sqlite3PagerUnref(pPg);

  { SP2: page3=$BB }
  sqlite3PagerOpenSavepoint(pPgr, 2);
  pPg := nil;
  sqlite3PagerGet(pPgr, 3, @pPg, 0); sqlite3PagerWrite(pPg); FillPage(pPg, $BB); sqlite3PagerUnref(pPg);

  { ROLLBACK SP2 (iSavepoint=1 = savepoint index 1) }
  rc := sqlite3PagerSavepoint(pPgr, SAVEPOINT_ROLLBACK, 1);
  if rc <> SQLITE_OK then
  begin Fail('T4', 'ROLLBACK SP2 failed ' + IntToStr(rc)); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);

  rc := OpenWritePager(path, pPgr);
  sqlite3PagerSharedLock(pPgr);
  if not PageIs(pPgr, 2, $AA) then
    Fail('T4', 'page 2 should be $AA (SP1 committed)')
  else if not PageIs(pPgr, 3, $20) then
    Fail('T4', 'page 3 should be $20 (SP2 rolled back)')
  else
    Pass('T4');
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ------------------------------------------------------------------ T5 }
{ Savepoint release then outer rollback.
  SP1 writes $BB to page 2, RELEASE SP1, then ROLLBACK outer.
  SP1 release merges its changes into outer; outer rollback undoes all.
  After reopen: page 2 = $01. }
procedure T5_SavepointReleaseThenOuterRollback;
var
  pPgr: PPager;
  rc: i32;
  path: string;
  pPg: PDbPage;
begin
  path := '/tmp/pas_crash_t5.db';
  FpUnlink(PChar(path));

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T5', 'open failed'); Exit; end;
  WriteAndCommit(pPgr, 2, $01);

  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);
  sqlite3PagerOpenSavepoint(pPgr, 1);

  pPg := nil;
  sqlite3PagerGet(pPgr, 2, @pPg, 0);
  sqlite3PagerWrite(pPg);
  FillPage(pPg, $BB);
  sqlite3PagerUnref(pPg);

  { RELEASE SP1 — merges SP1 into outer transaction }
  rc := sqlite3PagerSavepoint(pPgr, SAVEPOINT_RELEASE, 0);
  if rc <> SQLITE_OK then
  begin Fail('T5', 'RELEASE SP1 failed ' + IntToStr(rc)); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;

  { ROLLBACK outer }
  rc := sqlite3PagerRollback(pPgr);
  if rc <> SQLITE_OK then
  begin Fail('T5', 'outer ROLLBACK failed ' + IntToStr(rc)); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerClose(pPgr, nil);

  rc := OpenWritePager(path, pPgr);
  sqlite3PagerSharedLock(pPgr);
  if PageIs(pPgr, 2, $01) then
    Pass('T5')
  else
    Fail('T5', 'page 2 should be $01 after outer rollback');
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ------------------------------------------------------------------ T6 }
{ Empty journal file is handled safely: page 2 = $CC unchanged. }
procedure T6_EmptyJournalSafe;
var
  pPgr: PPager;
  rc: i32;
  path, jrnl: string;
  fd: cint;
begin
  path := '/tmp/pas_crash_t6.db';
  jrnl := path + '-journal';
  FpUnlink(PChar(path));
  FpUnlink(PChar(jrnl));

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T6', 'open failed'); Exit; end;
  WriteAndCommit(pPgr, 2, $CC);
  sqlite3PagerClose(pPgr, nil);

  { Create empty journal file }
  fd := FpOpen(PChar(jrnl), O_WRONLY or O_CREAT or O_TRUNC, $1B6);
  if fd >= 0 then FpClose(fd);

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then
  begin Fail('T6', 'reopen failed ' + IntToStr(rc)); FpUnlink(PChar(path)); FpUnlink(PChar(jrnl)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T6', 'SharedLock with empty journal returned ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil);
    FpUnlink(PChar(path)); FpUnlink(PChar(jrnl)); Exit;
  end;

  if PageIs(pPgr, 2, $CC) then
    Pass('T6')
  else
    Fail('T6', 'page 2 corrupted by empty-journal handling');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(jrnl));
end;

{ ------------------------------------------------------------------ T7 }
{ Multiple transactions then crash.
  Commit $AA, commit $BB to page 2, crash mid-$CC.
  After recovery: page 2 = $BB. }
procedure T7_MultiCommitThenCrash;
var
  pPgr: PPager;
  rc: i32;
  path: string;
  pid: TPid;
  status: cint;
  pPg: PDbPage;
begin
  path := '/tmp/pas_crash_t7.db';
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T7', 'open failed'); Exit; end;
  WriteAndCommit(pPgr, 2, $AA);
  WriteAndCommit(pPgr, 2, $BB);
  sqlite3PagerClose(pPgr, nil);

  { Fork: child starts $CC write, CommitPhaseOne, then crashes }
  pid := FpFork;
  if pid < 0 then begin Fail('T7', 'fork failed'); FpUnlink(PChar(path)); Exit; end;
  if pid = 0 then
  begin
    rc := OpenWritePager(path, pPgr);
    if rc = SQLITE_OK then
    begin
      sqlite3PagerSharedLock(pPgr);
      sqlite3PagerBegin(pPgr, 0, 0);
      pPg := nil;
      sqlite3PagerGet(pPgr, 2, @pPg, 0);
      sqlite3PagerWrite(pPg);
      FillPage(pPg, $CC);
      sqlite3PagerUnref(pPg);
      sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
      { Crash }
      sqlite3OsClose(pPgr^.jfd);
      sqlite3OsClose(pPgr^.fd);
    end;
    FpExit(0);
  end;
  FpWaitPid(pid, @status, 0);

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T7', 'reopen failed ' + IntToStr(rc)); FpUnlink(PChar(path)); Exit; end;
  sqlite3PagerSharedLock(pPgr);
  if PageIs(pPgr, 2, $BB) then
    Pass('T7')
  else if PageIs(pPgr, 2, $CC) then
    Fail('T7', 'hot journal not replayed: crashed $CC still present')
  else
    Fail('T7', 'unexpected page 2 content after multi-commit crash');
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ------------------------------------------------------------------ T8 }
{ Differential with C reference: after Pascal crash recovery, the .db is
  openable by the C reference library (no SQLITE_CORRUPT). }
procedure T8_CRefDiffAfterCrash;
var
  pPgr: PPager;
  rc: i32;
  path: string;
  pid: TPid;
  status: cint;
  cdb: Pcsq_db;
  crc: i32;
  pPg: PDbPage;
begin
  path := '/tmp/pas_crash_t8.db';
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T8', 'setup open failed'); Exit; end;
  WriteAndCommit(pPgr, 2, $01);
  sqlite3PagerClose(pPgr, nil);

  pid := FpFork;
  if pid < 0 then begin Fail('T8', 'fork failed'); FpUnlink(PChar(path)); Exit; end;
  if pid = 0 then
  begin
    rc := OpenWritePager(path, pPgr);
    if rc = SQLITE_OK then
    begin
      sqlite3PagerSharedLock(pPgr);
      sqlite3PagerBegin(pPgr, 0, 0);
      pPg := nil;
      sqlite3PagerGet(pPgr, 2, @pPg, 0);
      sqlite3PagerWrite(pPg);
      FillPage(pPg, $FF);
      sqlite3PagerUnref(pPg);
      sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
      sqlite3OsClose(pPgr^.jfd);
      sqlite3OsClose(pPgr^.fd);
    end;
    FpExit(0);
  end;
  FpWaitPid(pid, @status, 0);

  { Pascal recovery }
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T8', 'recovery open failed'); FpUnlink(PChar(path)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin Fail('T8', 'recovery SharedLock failed ' + IntToStr(rc)); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;
  if not PageIs(pPgr, 2, $01) then
  begin
    Fail('T8', 'Pascal recovery did not restore $01');
    sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit;
  end;
  sqlite3PagerClose(pPgr, nil);

  { Open recovered .db with C reference — must not return SQLITE_CORRUPT }
  cdb := nil;
  crc := csq_open(PChar(path), cdb);
  if crc <> 0 then
  begin
    Fail('T8', 'C reference csq_open returned ' + IntToStr(crc));
    FpUnlink(PChar(path)); Exit;
  end;
  csq_close(cdb);

  if crc = 11 { SQLITE_CORRUPT } then
    Fail('T8', 'C reference sees SQLITE_CORRUPT after Pascal crash recovery')
  else
    Pass('T8');

  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ------------------------------------------------------------------ T9 }
{ Journal truncated mid-header (8 bytes = only magic, missing nRec etc).
  Pager must reopen safely without crashing; page 2 = $55 unchanged. }
procedure T9_TruncatedJournalHeader;
var
  pPgr: PPager;
  rc: i32;
  path, jrnl: string;
  fd: cint;
  magic8: array[0..7] of u8;
begin
  path := '/tmp/pas_crash_t9.db';
  jrnl := path + '-journal';
  FpUnlink(PChar(path));
  FpUnlink(PChar(jrnl));

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T9', 'open failed'); Exit; end;
  WriteAndCommit(pPgr, 2, $55);
  sqlite3PagerClose(pPgr, nil);

  { Write only the journal magic (first 8 bytes) — no nRec, mxPg, etc. }
  magic8[0] := $D9; magic8[1] := $D5; magic8[2] := $05; magic8[3] := $F9;
  magic8[4] := $20; magic8[5] := $A1; magic8[6] := $63; magic8[7] := $D7;
  fd := FpOpen(PChar(jrnl), O_WRONLY or O_CREAT or O_TRUNC, $1B6);
  if fd >= 0 then begin FpWrite(fd, magic8[0], 8); FpClose(fd); end;

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then
  begin Fail('T9', 'reopen failed ' + IntToStr(rc)); FpUnlink(PChar(path)); FpUnlink(PChar(jrnl)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T9', 'SharedLock with truncated journal returned ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); FpUnlink(PChar(jrnl)); Exit;
  end;

  if PageIs(pPgr, 2, $55) then
    Pass('T9')
  else
    Fail('T9', 'page 2 changed after truncated-journal open');
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(jrnl));
end;

{ ------------------------------------------------------------------ T10 }
{ Rollback-on-error: inject SQLITE_IOERR into pager, verify
  sqlite3PagerRollback returns SQLITE_IOERR cleanly. }
procedure T10_RollbackOnError;
var
  pPgr: PPager;
  rc: i32;
  path: string;
begin
  path := '/tmp/pas_crash_t10.db';
  FpUnlink(PChar(path));

  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T10', 'open failed'); Exit; end;
  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);

  { Inject error }
  pPgr^.errCode := SQLITE_IOERR;
  pPgr^.eState  := PAGER_ERROR;

  rc := sqlite3PagerRollback(pPgr);
  if rc = SQLITE_IOERR then
    Pass('T10')
  else
    Fail('T10', 'expected SQLITE_IOERR from Rollback-on-error, got ' + IntToStr(rc));

  { Reset so Close doesn't loop }
  pPgr^.errCode := SQLITE_OK;
  pPgr^.eState  := PAGER_OPEN;
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ------------------------------------------------------------------ main }
begin
  WriteLn('=== TestPagerCrash (Phase 3.B.2c) ===');
  WriteLn;

  sqlite3_os_init;
  sqlite3PcacheInitialize;

  T1_MultiPageCommit;
  T2_ForkCrashRecovery;
  T3_SavepointRollbackReverts;
  T4_NestedSavepointPartialRollback;
  T5_SavepointReleaseThenOuterRollback;
  T6_EmptyJournalSafe;
  T7_MultiCommitThenCrash;
  T8_CRefDiffAfterCrash;
  T9_TruncatedJournalHeader;
  T10_RollbackOnError;

  WriteLn;
  if gAllPass then
  begin
    WriteLn('All tests PASSED.');
    Halt(0);
  end
  else
  begin
    WriteLn('Some tests FAILED.');
    Halt(1);
  end;
end.
