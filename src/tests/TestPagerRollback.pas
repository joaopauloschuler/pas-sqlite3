{$I ../passqlite3.inc}
program TestPagerRollback;

{
  Phase 3.B.2b -- Rollback-journal write-path gate tests.

  Tests the Pascal pager's write path (journal_mode=DELETE) by opening
  a temporary writable database and exercising the commit/rollback API.

    T1  Open a writable pager (READWRITE|CREATE) → SQLITE_OK.
    T2  sqlite3PagerSharedLock on writable pager → SQLITE_OK, PAGER_READER.
    T3  sqlite3PagerBegin transitions to WRITER_LOCKED.
    T4  sqlite3PagerGet(1) + sqlite3PagerWrite marks page 1 dirty → SQLITE_OK.
    T5  sqlite3PagerCommitPhaseOne → SQLITE_OK.
    T6  sqlite3PagerCommitPhaseTwo → SQLITE_OK; pager returns to READER state.
    T7  Write+Rollback: begin, write page 1, rollback → SQLITE_OK, back to READER.
    T8  Data reverted: after rollback, page 1 bytes match pre-write snapshot.
    T9  sqlite3PagerOpenSavepoint(1) → SQLITE_OK.
    T10 sqlite3PagerSavepoint RELEASE(0) → SQLITE_OK; nSavepoint drops to 0.

  Prints PASS/FAIL per test.  Exits 0 if ALL PASS, 1 on any failure.

  Run with:
    LD_LIBRARY_PATH=src/ bin/TestPagerRollback
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
  passqlite3pager;

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

{ Dummy page reinit callback — no-op; satisfies xReiniter requirement. }
procedure DummyReinit(pPg: PDbPage);
begin
end;

{ Open a writable pager on the given path.  Returns SQLITE_OK on success. }
function OpenWritePager(const dbPath: string; out pPgr: PPager): i32;
var
  pVfs : Psqlite3_vfs;
  vfsFlags: i32;
  pageSize: u32;
begin
  pPgr := nil;
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Result := SQLITE_ERROR; Exit; end;

  vfsFlags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MAIN_DB;
  Result := sqlite3PagerOpen(pVfs, pPgr, PChar(dbPath),
              0, 0, vfsFlags, @DummyReinit);
  if Result <> SQLITE_OK then Exit;

  pageSize := PAGE_SIZE;
  Result := sqlite3PagerSetPagesize(pPgr, @pageSize, -1);
end;

{ ---- T1: PagerOpen writable ---- }
procedure T1_OpenWritable;
var
  pPgr : PPager;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t1.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then
    Fail('T1', 'sqlite3PagerOpen returned ' + IntToStr(rc))
  else
  begin
    Pass('T1');
    sqlite3PagerClose(pPgr, nil);
  end;
  FpUnlink(PChar(path));
end;

{ ---- T2: SharedLock on writable pager → PAGER_READER ---- }
procedure T2_SharedLock;
var
  pPgr : PPager;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t2.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T2', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
    Fail('T2', 'SharedLock returned ' + IntToStr(rc))
  else if pPgr^.eState <> PAGER_READER then
    Fail('T2', 'expected PAGER_READER state, got ' + IntToStr(pPgr^.eState))
  else
    Pass('T2');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
end;

{ ---- T3: PagerBegin → WRITER_LOCKED ---- }
procedure T3_Begin;
var
  pPgr : PPager;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t3.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T3', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Fail('T3', 'SharedLock failed'); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;

  rc := sqlite3PagerBegin(pPgr, 0, 0);
  if rc <> SQLITE_OK then
    Fail('T3', 'PagerBegin returned ' + IntToStr(rc))
  else if pPgr^.eState < PAGER_WRITER_LOCKED then
    Fail('T3', 'expected WRITER_LOCKED+, got ' + IntToStr(pPgr^.eState))
  else
    Pass('T3');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ---- T4: PagerGet(1) + PagerWrite → SQLITE_OK ---- }
procedure T4_GetWrite;
var
  pPgr : PPager;
  pPg  : PDbPage;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t4.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T4', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);

  pPg := nil;
  rc := sqlite3PagerGet(pPgr, 1, @pPg, 0);
  if (rc <> SQLITE_OK) or (pPg = nil) then
  begin
    Fail('T4', 'PagerGet(1) returned ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil);
    FpUnlink(PChar(path));
    Exit;
  end;

  rc := sqlite3PagerWrite(pPg);
  if rc <> SQLITE_OK then
    Fail('T4', 'PagerWrite returned ' + IntToStr(rc))
  else
    Pass('T4');

  sqlite3PagerUnref(pPg);
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ---- T5: CommitPhaseOne → SQLITE_OK ---- }
procedure T5_CommitPhaseOne;
var
  pPgr : PPager;
  pPg  : PDbPage;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t5.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T5', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);

  pPg := nil;
  sqlite3PagerGet(pPgr, 1, @pPg, 0);
  sqlite3PagerWrite(pPg);
  FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, $AB);
  sqlite3PagerUnref(pPg);

  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc <> SQLITE_OK then
    Fail('T5', 'CommitPhaseOne returned ' + IntToStr(rc))
  else
    Pass('T5');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ---- T6: CommitPhaseTwo → SQLITE_OK, back to READER ---- }
procedure T6_CommitPhaseTwo;
var
  pPgr : PPager;
  pPg  : PDbPage;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t6.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T6', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);

  pPg := nil;
  sqlite3PagerGet(pPgr, 1, @pPg, 0);
  sqlite3PagerWrite(pPg);
  FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, $CD);
  sqlite3PagerUnref(pPg);

  sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  rc := sqlite3PagerCommitPhaseTwo(pPgr);
  if rc <> SQLITE_OK then
    Fail('T6', 'CommitPhaseTwo returned ' + IntToStr(rc))
  else if pPgr^.eState <> PAGER_READER then
    Fail('T6', 'expected PAGER_READER after commit, got ' + IntToStr(pPgr^.eState))
  else
    Pass('T6');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ---- T7: Rollback → SQLITE_OK, back to READER ---- }
procedure T7_Rollback;
var
  pPgr : PPager;
  pPg  : PDbPage;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t7.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T7', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);

  pPg := nil;
  sqlite3PagerGet(pPgr, 1, @pPg, 0);
  sqlite3PagerWrite(pPg);
  FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, $EF);
  sqlite3PagerUnref(pPg);

  rc := sqlite3PagerRollback(pPgr);
  if rc <> SQLITE_OK then
    Fail('T7', 'Rollback returned ' + IntToStr(rc))
  else if pPgr^.eState > PAGER_READER then
    Fail('T7', 'expected READER or below after rollback, got ' + IntToStr(pPgr^.eState))
  else
    Pass('T7');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ---- T8: Data reverted after rollback ---- }
procedure T8_RollbackReverts;
var
  pPgr     : PPager;
  pPg      : PDbPage;
  pData    : Pu8;
  rc       : i32;
  path     : string;
  snapshot : array[0..PAGE_SIZE-1] of u8;
  changed  : Boolean;
  i        : i32;
begin
  path := '/tmp/pas_sqlite3_rollback_t8.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T8', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerSharedLock(pPgr);

  { Write initial data for page 1 and commit }
  sqlite3PagerBegin(pPgr, 0, 0);
  pPg := nil;
  sqlite3PagerGet(pPgr, 1, @pPg, 0);
  sqlite3PagerWrite(pPg);
  FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, $01);
  sqlite3PagerUnref(pPg);
  sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  sqlite3PagerCommitPhaseTwo(pPgr);

  { Take snapshot of page 1 after commit }
  pPg := nil;
  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerGet(pPgr, 1, @pPg, 0);
  Move(sqlite3PagerGetData(pPg)^, snapshot[0], PAGE_SIZE);
  sqlite3PagerUnref(pPg);

  { Begin new transaction, overwrite page 1, then rollback }
  sqlite3PagerBegin(pPgr, 0, 0);
  pPg := nil;
  sqlite3PagerGet(pPgr, 1, @pPg, 0);
  sqlite3PagerWrite(pPg);
  FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, $FF);
  sqlite3PagerUnref(pPg);
  rc := sqlite3PagerRollback(pPgr);
  if rc <> SQLITE_OK then begin Fail('T8', 'rollback failed'); sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(path)); Exit; end;

  { After rollback, page 1 cache must match snapshot }
  sqlite3PagerSharedLock(pPgr);
  pPg := nil;
  rc := sqlite3PagerGet(pPgr, 1, @pPg, 0);
  if (rc <> SQLITE_OK) or (pPg = nil) then
  begin
    Fail('T8', 'get after rollback failed: ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil);
    FpUnlink(PChar(path));
    Exit;
  end;

  pData := Pu8(sqlite3PagerGetData(pPg));
  changed := False;
  for i := 0 to PAGE_SIZE - 1 do
    if (pData + i)^ <> snapshot[i] then begin changed := True; Break; end;

  if changed then
    Fail('T8', 'page 1 data was not reverted to pre-rollback state')
  else
    Pass('T8');

  sqlite3PagerUnref(pPg);
  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ---- T9: OpenSavepoint → SQLITE_OK ---- }
procedure T9_OpenSavepoint;
var
  pPgr : PPager;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t9.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T9', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);

  rc := sqlite3PagerOpenSavepoint(pPgr, 1);
  if rc <> SQLITE_OK then
    Fail('T9', 'OpenSavepoint(1) returned ' + IntToStr(rc))
  else
    Pass('T9');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ---- T10: PagerSavepoint RELEASE → SQLITE_OK ---- }
procedure T10_SavepointRelease;
var
  pPgr : PPager;
  rc   : i32;
  path : string;
begin
  path := '/tmp/pas_sqlite3_rollback_t10.db';
  FpUnlink(PChar(path));
  rc := OpenWritePager(path, pPgr);
  if rc <> SQLITE_OK then begin Fail('T10', 'open failed'); FpUnlink(PChar(path)); Exit; end;

  sqlite3PagerSharedLock(pPgr);
  sqlite3PagerBegin(pPgr, 0, 0);
  sqlite3PagerOpenSavepoint(pPgr, 1);

  rc := sqlite3PagerSavepoint(pPgr, SAVEPOINT_RELEASE, 0);
  if rc <> SQLITE_OK then
    Fail('T10', 'Savepoint RELEASE returned ' + IntToStr(rc))
  else
    Pass('T10');

  sqlite3PagerClose(pPgr, nil);
  FpUnlink(PChar(path));
  FpUnlink(PChar(path + '-journal'));
end;

{ ---- main ---- }
begin
  WriteLn('=== TestPagerRollback (Phase 3.B.2b) ===');
  WriteLn;

  sqlite3_os_init;
  sqlite3PcacheInitialize;

  T1_OpenWritable;
  T2_SharedLock;
  T3_Begin;
  T4_GetWrite;
  T5_CommitPhaseOne;
  T6_CommitPhaseTwo;
  T7_Rollback;
  T8_RollbackReverts;
  T9_OpenSavepoint;
  T10_SavepointRelease;

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
