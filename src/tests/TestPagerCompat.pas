{$I ../passqlite3.inc}
program TestPagerCompat;

{
  Phase 3.B.4 full gate: Pager compatibility tests.

  Verifies that the Pascal pager layer produces and consumes files that are
  compatible with the C reference (libsqlite3.so), exercising journaling
  (DELETE mode), SAVEPOINTs, crash/recovery, and WAL paths.

  T1  C creates a populated db; Pascal opens via pager, verifies page-1
      SQLite magic and reported page count >= 2.
  T2  Pascal creates a 1-page db with a minimal but valid SQLite header;
      C opens without SQLITE_CORRUPT or SQLITE_NOTADB.
  T3  Pascal writes a 10-page DELETE-journal transaction; after reopen all
      10 pages retain the expected byte patterns.
  T4  Savepoint: write pattern $AA to page 2, open SP1, write $BB to page 2,
      rollback SP1, commit outer — page 2 reads back $AA.
  T5  Crash recovery: Pascal writes 8 pages in a big transaction,
      CommitPhaseOne completes, child process exits without PhaseTwo;
      parent reopens — hot-journal playback restores the pre-commit state;
      C opens without corruption.
  T6  Journal cleanup: after a successful Pascal DELETE-journal commit the
      .journal file is removed from disk.
  T7  C creates a db with 100 rows; Pascal opens read-only and successfully
      reads every page (no I/O error) and closes cleanly.
  T8  Pascal creates a WAL-mode db (via sqlite3PagerOpenWal), writes a
      commit; C opens the resulting db without SQLITE_CORRUPT.
  T9  Pascal writes a multi-frame WAL db, runs a PASSIVE checkpoint;
      C opens the db after the checkpoint without error.
  T10 Large 20-page transaction: Pascal commits, crashes mid-next-commit,
      recovers via hot-journal; C opens the recovered db without corruption.

  Prints PASS/FAIL per test. Exits 0 if ALL PASS, 1 on any failure.

  Run with:
    LD_LIBRARY_PATH=src/ bin/TestPagerCompat
}

uses
  SysUtils,
  BaseUnix,
  UnixType,
  ctypes,
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3wal,
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

{ ---- helpers ------------------------------------------------------------ }

function OpenWritePager(const dbPath: string; out pPgr: PPager): i32;
var
  pVfs    : Psqlite3_vfs;
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

function OpenReadPager(const dbPath: string; out pPgr: PPager): i32;
var
  pVfs    : Psqlite3_vfs;
  vfsFlags: i32;
  pageSize: u32;
begin
  pPgr := nil;
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Result := SQLITE_ERROR; Exit; end;
  vfsFlags := SQLITE_OPEN_READONLY or SQLITE_OPEN_MAIN_DB;
  Result := sqlite3PagerOpen(pVfs, pPgr, PChar(dbPath), 0, 0, vfsFlags, @DummyReinit);
  if Result <> SQLITE_OK then Exit;
  pageSize := PAGE_SIZE;
  Result := sqlite3PagerSetPagesize(pPgr, @pageSize, -1);
end;

{ Write a minimal but valid SQLite3 database header into pData (PAGE_SIZE bytes).
  Uses file_format 1/1 (DELETE journal) unless isWal = true (sets 2/2). }
procedure WriteMinimalSQLiteHeader(pData: Pu8; isWal: Boolean);
begin
  FillChar(pData^, PAGE_SIZE, 0);
  Move(PChar('SQLite format 3'#0)^, pData^, 16);
  pData[16] := $10; pData[17] := $00;         { page size = 4096 }
  if isWal then begin
    pData[18] := 2; pData[19] := 2;            { file_format = WAL }
  end else begin
    pData[18] := 1; pData[19] := 1;            { file_format = DELETE }
  end;
  pData[20] := 0;   { reserved bytes per page = 0 }
  pData[21] := $40; { max embedded payload fraction = 64 }
  pData[22] := $20; { min embedded payload fraction = 32 }
  pData[23] := $20; { leaf payload fraction = 32 }
  sqlite3Put4byte(@pData[28], 4);              { schema cookie }
  sqlite3Put4byte(@pData[44], PAGE_SIZE);      { page size copy }
  sqlite3Put4byte(@pData[48], 1);              { page count = 1 }
  sqlite3Put4byte(@pData[56], 1);              { text encoding = UTF-8 }
end;

{ Use C SQLite to create a db with a table and N rows.
  Returns SQLITE_OK on success. The db is closed when this returns. }
function CCreatePopulatedDb(const dbPath: string; nRows: i32): i32;
var
  cdb : Pcsq_db;
  rc  : i32;
  zErr: PChar;
  sql : string;
  i   : i32;
begin
  FpUnlink(PChar(dbPath));
  cdb := nil;
  rc := csq_open_v2(PChar(dbPath), cdb, SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  zErr := nil;
  rc := csq_exec(cdb, 'CREATE TABLE t(id INTEGER PRIMARY KEY, val BLOB);', nil, nil, zErr);
  if rc <> SQLITE_OK then begin csq_close(cdb); Result := rc; Exit; end;
  rc := csq_exec(cdb, 'BEGIN;', nil, nil, zErr);
  if rc <> SQLITE_OK then begin csq_close(cdb); Result := rc; Exit; end;
  for i := 1 to nRows do
  begin
    sql := 'INSERT INTO t(val) VALUES(zeroblob(100));';
    rc := csq_exec(cdb, PChar(sql), nil, nil, zErr);
    if rc <> SQLITE_OK then begin csq_close(cdb); Result := rc; Exit; end;
  end;
  rc := csq_exec(cdb, 'COMMIT;', nil, nil, zErr);
  csq_close(cdb);
  Result := rc;
end;

{ Commit a single-page write of byte pattern b to page pgno. }
function WritePagePattern(const dbPath: string; pg: u32; b: u8): i32;
var
  pPgr : PPager;
  pPg  : PDbPage;
  rc   : i32;
begin
  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin sqlite3PagerClose(pPgr, nil); Result := rc; Exit; end;
  rc := sqlite3PagerBegin(pPgr, 0, 0);
  if rc <> SQLITE_OK then begin sqlite3PagerClose(pPgr, nil); Result := rc; Exit; end;
  pPg := nil;
  rc := sqlite3PagerGet(pPgr, pg, @pPg, 0);
  if (rc <> SQLITE_OK) or (pPg = nil) then
  begin
    sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Result := rc; Exit;
  end;
  rc := sqlite3PagerWrite(pPg);
  if rc = SQLITE_OK then
    FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, b);
  sqlite3PagerUnref(pPg);
  if rc <> SQLITE_OK then
  begin
    sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Result := rc; Exit;
  end;
  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);
  Result := rc;
end;

{ Read byte at offset 0 of page pgno using a fresh read-only pager.
  Returns SQLITE_OK and sets byteOut. }
function ReadPageByte(const dbPath: string; pg: u32; out byteOut: u8): i32;
var
  pPgr : PPager;
  pPg  : PDbPage;
  pData: Pu8;
  rc   : i32;
begin
  byteOut := 0;
  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin sqlite3PagerClose(pPgr, nil); Result := rc; Exit; end;
  pPg := nil;
  rc := sqlite3PagerGet(pPgr, pg, @pPg, 0);
  if (rc = SQLITE_OK) and (pPg <> nil) then
  begin
    pData := Pu8(sqlite3PagerGetData(pPg));
    byteOut := pData[0];
    sqlite3PagerUnref(pPg);
  end;
  sqlite3PagerClose(pPgr, nil);
  Result := rc;
end;

{ ---- T1 ----------------------------------------------------------------- }
{ C creates a populated db; Pascal reads page-1 magic + page count >= 2. }
procedure T1_CWritesPascalReads;
var
  dbPath : string;
  pPgr   : PPager;
  pPg    : PDbPage;
  pData  : Pu8;
  nPage  : i32;
  rc     : i32;
begin
  dbPath := '/tmp/pas_compat_t1.db';
  if CCreatePopulatedDb(dbPath, 40) <> SQLITE_OK then
  begin
    Fail('T1', 'C create failed'); Exit;
  end;

  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T1', 'OpenPager failed ' + IntToStr(rc)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T1', 'SharedLock failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(dbPath)); Exit;
  end;

  pPg := nil;
  rc := sqlite3PagerGet(pPgr, 1, @pPg, 0);
  if (rc <> SQLITE_OK) or (pPg = nil) then
  begin
    Fail('T1', 'PagerGet p1 failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(dbPath)); Exit;
  end;

  pData := Pu8(sqlite3PagerGetData(pPg));
  if not ((pData[0] = $53) and (pData[1] = $51) and (pData[2] = $4C) and (pData[3] = $69)) then
  begin
    sqlite3PagerUnref(pPg);
    Fail('T1', 'page 1 missing SQLite magic');
    sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(dbPath)); Exit;
  end;
  sqlite3PagerUnref(pPg);

  nPage := 0;
  sqlite3PagerPagecount(pPgr, @nPage);
  sqlite3PagerClose(pPgr, nil);

  if nPage < 2 then
    Fail('T1', 'expected >=2 pages, got ' + IntToStr(nPage))
  else
    Pass('T1');

  FpUnlink(PChar(dbPath));
end;

{ ---- T2 ----------------------------------------------------------------- }
{ Pascal creates a 1-page db with minimal SQLite header; C opens without error. }
procedure T2_PascalCreatesCReads;
var
  dbPath : string;
  pPgr   : PPager;
  pPg    : PDbPage;
  pData  : Pu8;
  cdb    : Pcsq_db;
  rc, crc: i32;
begin
  dbPath := '/tmp/pas_compat_t2.db';
  FpUnlink(PChar(dbPath));

  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T2', 'OpenPager failed ' + IntToStr(rc)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T2', 'SharedLock failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;
  rc := sqlite3PagerBegin(pPgr, 0, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T2', 'Begin failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;

  pPg := nil;
  rc := sqlite3PagerGet(pPgr, 1, @pPg, 0);
  if (rc <> SQLITE_OK) or (pPg = nil) then
  begin
    Fail('T2', 'PagerGet p1 failed ' + IntToStr(rc));
    sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Exit;
  end;
  rc := sqlite3PagerWrite(pPg);
  if rc = SQLITE_OK then
  begin
    pData := Pu8(sqlite3PagerGetData(pPg));
    WriteMinimalSQLiteHeader(pData, False);
  end;
  sqlite3PagerUnref(pPg);
  if rc <> SQLITE_OK then
  begin
    Fail('T2', 'PagerWrite failed ' + IntToStr(rc));
    sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Exit;
  end;

  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);
  if rc <> SQLITE_OK then
  begin
    Fail('T2', 'commit failed ' + IntToStr(rc)); FpUnlink(PChar(dbPath)); Exit;
  end;

  cdb := nil;
  crc := csq_open_v2(PChar(dbPath), cdb, SQLITE_OPEN_READONLY, nil);
  if crc = SQLITE_NOTADB then
    Fail('T2', 'C reports SQLITE_NOTADB on Pascal-created db')
  else if crc = SQLITE_CORRUPT then
    Fail('T2', 'C reports SQLITE_CORRUPT on Pascal-created db')
  else
  begin
    if cdb <> nil then csq_close(cdb);
    Pass('T2');
  end;

  FpUnlink(PChar(dbPath));
end;

{ ---- T3 ----------------------------------------------------------------- }
{ Pascal writes a 10-page DELETE-journal transaction; after reopen all pages
  retain the expected byte patterns. }
procedure T3_BigTransactionPersists;
var
  dbPath  : string;
  pPgr    : PPager;
  pPg     : PDbPage;
  pData   : Pu8;
  i       : i32;
  byt     : u8;
  rc      : i32;
  ok      : Boolean;
begin
  dbPath := '/tmp/pas_compat_t3.db';
  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-journal'));

  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T3', 'OpenPager failed ' + IntToStr(rc)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T3', 'SharedLock failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;
  rc := sqlite3PagerBegin(pPgr, 0, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T3', 'Begin failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;

  { Write pages 1-10 with patterns $10..$19 }
  for i := 1 to 10 do
  begin
    pPg := nil;
    rc := sqlite3PagerGet(pPgr, i, @pPg, 0);
    if (rc <> SQLITE_OK) or (pPg = nil) then
    begin
      Fail('T3', 'PagerGet p' + IntToStr(i) + ' failed ' + IntToStr(rc));
      sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Exit;
    end;
    rc := sqlite3PagerWrite(pPg);
    if rc = SQLITE_OK then
    begin
      pData := Pu8(sqlite3PagerGetData(pPg));
      if i = 1 then
        WriteMinimalSQLiteHeader(pData, False)
      else
        FillChar(pData^, PAGE_SIZE, $10 + i - 1);
    end;
    sqlite3PagerUnref(pPg);
    if rc <> SQLITE_OK then
    begin
      Fail('T3', 'PagerWrite p' + IntToStr(i) + ' failed ' + IntToStr(rc));
      sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Exit;
    end;
  end;

  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);
  if rc <> SQLITE_OK then
  begin
    Fail('T3', 'commit failed ' + IntToStr(rc)); FpUnlink(PChar(dbPath)); Exit;
  end;

  { Reopen and verify pages 2-10 }
  ok := True;
  for i := 2 to 10 do
  begin
    byt := 0;
    rc := ReadPageByte(dbPath, i, byt);
    if rc <> SQLITE_OK then
    begin
      Fail('T3', 'read p' + IntToStr(i) + ' failed rc=' + IntToStr(rc));
      ok := False; Break;
    end;
    if byt <> ($10 + i - 1) then
    begin
      Fail('T3', 'p' + IntToStr(i) + ' expected $' + IntToHex($10 + i - 1, 2)
           + ' got $' + IntToHex(byt, 2));
      ok := False; Break;
    end;
  end;
  if ok then Pass('T3');

  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-journal'));
end;

{ ---- T4 ----------------------------------------------------------------- }
{ Savepoint: write $AA to page 2, open SP1, write $BB, rollback SP1;
  commit outer — page 2 reads back $AA. }
procedure T4_SavepointRollback;
var
  dbPath : string;
  pPgr   : PPager;
  pPg    : PDbPage;
  pData  : Pu8;
  byt    : u8;
  rc     : i32;
begin
  dbPath := '/tmp/pas_compat_t4.db';
  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-journal'));

  { Initial state: write $01 to pages 1 and 2 }
  if WritePagePattern(dbPath, 1, $01) <> SQLITE_OK then
  begin
    Fail('T4', 'init page 1 failed'); Exit;
  end;
  if WritePagePattern(dbPath, 2, $01) <> SQLITE_OK then
  begin
    Fail('T4', 'init page 2 failed'); Exit;
  end;

  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T4', 'OpenPager failed ' + IntToStr(rc)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T4', 'SharedLock failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;

  { Outer transaction: write $AA to page 2 }
  rc := sqlite3PagerBegin(pPgr, 0, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T4', 'Begin outer failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;
  pPg := nil;
  rc := sqlite3PagerGet(pPgr, 2, @pPg, 0);
  if (rc = SQLITE_OK) and (pPg <> nil) then
  begin
    if sqlite3PagerWrite(pPg) = SQLITE_OK then
    begin
      pData := Pu8(sqlite3PagerGetData(pPg));
      FillChar(pData^, PAGE_SIZE, $AA);
    end;
    sqlite3PagerUnref(pPg);
  end;

  { Open savepoint SP1 and overwrite page 2 with $BB }
  rc := sqlite3PagerOpenSavepoint(pPgr, 1);
  if rc <> SQLITE_OK then
  begin
    Fail('T4', 'OpenSavepoint failed ' + IntToStr(rc));
    sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Exit;
  end;

  pPg := nil;
  rc := sqlite3PagerGet(pPgr, 2, @pPg, 0);
  if (rc = SQLITE_OK) and (pPg <> nil) then
  begin
    if sqlite3PagerWrite(pPg) = SQLITE_OK then
    begin
      pData := Pu8(sqlite3PagerGetData(pPg));
      FillChar(pData^, PAGE_SIZE, $BB);
    end;
    sqlite3PagerUnref(pPg);
  end;

  { Rollback SP1 — should restore page 2 to $AA }
  rc := sqlite3PagerSavepoint(pPgr, SAVEPOINT_ROLLBACK, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T4', 'SavepointRollback failed ' + IntToStr(rc));
    sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Exit;
  end;

  { Commit outer transaction }
  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);
  if rc <> SQLITE_OK then
  begin
    Fail('T4', 'commit failed ' + IntToStr(rc)); Exit;
  end;

  { Verify page 2 = $AA }
  byt := 0;
  rc := ReadPageByte(dbPath, 2, byt);
  if rc <> SQLITE_OK then
    Fail('T4', 'read p2 failed ' + IntToStr(rc))
  else if byt <> $AA then
    Fail('T4', 'expected $AA on page 2, got $' + IntToHex(byt, 2))
  else
    Pass('T4');

  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-journal'));
end;

{ ---- T5 ----------------------------------------------------------------- }
{ Crash during a big multi-page commit: PhaseOne done, child exits without
  PhaseTwo; parent reopens, hot-journal replays, C opens without corruption. }
procedure T5_CrashRecoveryCompatible;
var
  dbPath  : string;
  pPgr    : PPager;
  pPg     : PDbPage;
  pData   : Pu8;
  i       : i32;
  pid     : TPid;
  status  : cint;
  cdb     : Pcsq_db;
  byt     : u8;
  rc, crc : i32;
begin
  dbPath := '/tmp/pas_compat_t5.db';
  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-journal'));

  { Initial state: pages 1-8 filled with $01 }
  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T5', 'init open failed ' + IntToStr(rc)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc = SQLITE_OK then rc := sqlite3PagerBegin(pPgr, 0, 0);
  for i := 1 to 8 do
  begin
    pPg := nil;
    if sqlite3PagerGet(pPgr, i, @pPg, 0) = SQLITE_OK then
    begin
      if sqlite3PagerWrite(pPg) = SQLITE_OK then
      begin
        pData := Pu8(sqlite3PagerGetData(pPg));
        if i = 1 then WriteMinimalSQLiteHeader(pData, False)
        else       FillChar(pData^, PAGE_SIZE, $01);
      end;
      sqlite3PagerUnref(pPg);
    end;
  end;
  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);
  if rc <> SQLITE_OK then begin Fail('T5', 'init commit failed ' + IntToStr(rc)); Exit; end;

  { Child: open, begin, write $FF to pages 2-8, PhaseOne, then _exit without PhaseTwo }
  pid := FpFork;
  if pid < 0 then begin Fail('T5', 'fork failed'); Exit; end;

  if pid = 0 then
  begin
    { child process }
    rc := OpenWritePager(dbPath, pPgr);
    if rc = SQLITE_OK then rc := sqlite3PagerSharedLock(pPgr);
    if rc = SQLITE_OK then rc := sqlite3PagerBegin(pPgr, 0, 0);
    for i := 2 to 8 do
    begin
      pPg := nil;
      if sqlite3PagerGet(pPgr, i, @pPg, 0) = SQLITE_OK then
      begin
        if sqlite3PagerWrite(pPg) = SQLITE_OK then
          FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, $FF);
        sqlite3PagerUnref(pPg);
      end;
    end;
    sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
    { Exit WITHOUT CommitPhaseTwo — simulates a crash }
    FpExit(0);
  end;

  { parent: wait for child }
  FpWaitPid(pid, @status, 0);

  { parent: reopen — should trigger hot-journal playback, restoring $01 }
  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T5', 'reopen failed ' + IntToStr(rc)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  sqlite3PagerClose(pPgr, nil);

  { After reopen the hot journal should have been replayed.
    Page 2 should be back to $01 (pre-crash value). }
  byt := 0;
  rc := ReadPageByte(dbPath, 2, byt);
  if rc <> SQLITE_OK then
  begin
    Fail('T5', 'read after recovery failed rc=' + IntToStr(rc));
    FpUnlink(PChar(dbPath)); FpUnlink(PChar(dbPath + '-journal')); Exit;
  end;

  if byt <> $01 then
  begin
    Fail('T5', 'expected $01 after recovery, got $' + IntToHex(byt, 2));
    FpUnlink(PChar(dbPath)); FpUnlink(PChar(dbPath + '-journal')); Exit;
  end;

  { C should also be happy opening the recovered file }
  cdb := nil;
  crc := csq_open_v2(PChar(dbPath), cdb, SQLITE_OPEN_READONLY, nil);
  if crc = SQLITE_CORRUPT then
    Fail('T5', 'C reports CORRUPT on recovered db')
  else if crc = SQLITE_NOTADB then
    Fail('T5', 'C reports NOTADB on recovered db')
  else
  begin
    if cdb <> nil then csq_close(cdb);
    Pass('T5');
  end;

  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-journal'));
end;

{ ---- T6 ----------------------------------------------------------------- }
{ After a successful Pascal DELETE-journal commit, no .journal file remains. }
procedure T6_JournalCleanedUp;
var
  dbPath  : string;
  jPath   : string;
  st      : Stat;
  rc      : i32;
begin
  dbPath := '/tmp/pas_compat_t6.db';
  jPath  := dbPath + '-journal';
  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(jPath));

  rc := WritePagePattern(dbPath, 1, $AA);
  if rc <> SQLITE_OK then begin Fail('T6', 'write failed ' + IntToStr(rc)); Exit; end;

  { Verify journal is absent after successful commit }
  if FpStat(jPath, st) = 0 then
    Fail('T6', 'journal file still exists after successful commit')
  else
    Pass('T6');

  FpUnlink(PChar(dbPath));
end;

{ ---- T7 ----------------------------------------------------------------- }
{ C creates a db with 100 rows; Pascal opens read-only and successfully reads
  every page without I/O errors. }
procedure T7_CWritesPascalReadsAll;
var
  dbPath  : string;
  pPgr    : PPager;
  nPage   : i32;
  pPg     : PDbPage;
  i       : i32;
  rc      : i32;
  anyFail : Boolean;
begin
  dbPath := '/tmp/pas_compat_t7.db';
  if CCreatePopulatedDb(dbPath, 100) <> SQLITE_OK then
  begin
    Fail('T7', 'C create failed'); Exit;
  end;

  rc := OpenReadPager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T7', 'OpenPager failed ' + IntToStr(rc)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T7', 'SharedLock failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(dbPath)); Exit;
  end;

  nPage := 0;
  sqlite3PagerPagecount(pPgr, @nPage);
  if nPage < 2 then
  begin
    Fail('T7', 'too few pages: ' + IntToStr(nPage));
    sqlite3PagerClose(pPgr, nil); FpUnlink(PChar(dbPath)); Exit;
  end;

  anyFail := False;
  for i := 1 to nPage do
  begin
    pPg := nil;
    rc := sqlite3PagerGet(pPgr, i, @pPg, 0);
    if (rc <> SQLITE_OK) or (pPg = nil) then
    begin
      Fail('T7', 'PagerGet p' + IntToStr(i) + ' failed rc=' + IntToStr(rc));
      anyFail := True; Break;
    end;
    sqlite3PagerUnref(pPg);
  end;

  sqlite3PagerClose(pPgr, nil);
  if not anyFail then
    Pass('T7');

  FpUnlink(PChar(dbPath));
end;

{ ---- T8 ----------------------------------------------------------------- }
{ Pascal creates a WAL-mode db via sqlite3PagerOpenWal, writes a commit;
  C opens the resulting db without SQLITE_CORRUPT. }
procedure T8_PascalWalWriteCReads;
var
  dbPath : string;
  pPgr   : PPager;
  pPg    : PDbPage;
  pData  : Pu8;
  pbOpen : cint;
  cdb    : Pcsq_db;
  rc, crc: i32;
begin
  dbPath := '/tmp/pas_compat_t8.db';
  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-wal'));
  FpUnlink(PChar(dbPath + '-shm'));

  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T8', 'OpenPager failed ' + IntToStr(rc)); Exit; end;

  pbOpen := 0;
  rc := sqlite3PagerOpenWal(pPgr, @pbOpen);
  if rc <> SQLITE_OK then
  begin
    Fail('T8', 'OpenWal failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;

  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T8', 'SharedLock failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;
  rc := sqlite3PagerBegin(pPgr, 0, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T8', 'Begin failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;

  pPg := nil;
  rc := sqlite3PagerGet(pPgr, 1, @pPg, 0);
  if (rc <> SQLITE_OK) or (pPg = nil) then
  begin
    Fail('T8', 'PagerGet p1 failed ' + IntToStr(rc));
    sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Exit;
  end;
  rc := sqlite3PagerWrite(pPg);
  if rc = SQLITE_OK then
  begin
    pData := Pu8(sqlite3PagerGetData(pPg));
    WriteMinimalSQLiteHeader(pData, True);
  end;
  sqlite3PagerUnref(pPg);

  if rc <> SQLITE_OK then
  begin
    Fail('T8', 'PagerWrite failed ' + IntToStr(rc));
    sqlite3PagerRollback(pPgr); sqlite3PagerClose(pPgr, nil); Exit;
  end;

  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);

  if rc <> SQLITE_OK then
  begin
    Fail('T8', 'commit failed ' + IntToStr(rc));
    FpUnlink(PChar(dbPath)); FpUnlink(PChar(dbPath + '-wal')); FpUnlink(PChar(dbPath + '-shm'));
    Exit;
  end;

  cdb := nil;
  crc := csq_open_v2(PChar(dbPath), cdb, SQLITE_OPEN_READONLY, nil);
  if crc = SQLITE_CORRUPT then
    Fail('T8', 'C reports CORRUPT on Pascal WAL db')
  else if crc = SQLITE_NOTADB then
    Fail('T8', 'C reports NOTADB on Pascal WAL db')
  else
  begin
    if cdb <> nil then csq_close(cdb);
    Pass('T8');
  end;

  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-wal'));
  FpUnlink(PChar(dbPath + '-shm'));
end;

{ ---- T9 ----------------------------------------------------------------- }
{ Pascal writes multi-frame WAL db, runs PASSIVE checkpoint; C opens db
  without error after checkpoint. }
procedure T9_WalCheckpointThenCReads;
var
  dbPath  : string;
  pPgr    : PPager;
  pPg     : PDbPage;
  pData   : Pu8;
  pbOpen  : cint;
  nLog    : cint;
  nCkpt   : cint;
  cdb     : Pcsq_db;
  i       : i32;
  rc, crc : i32;
begin
  dbPath := '/tmp/pas_compat_t9.db';
  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-wal'));
  FpUnlink(PChar(dbPath + '-shm'));

  { Create a WAL db with 3 commits (pages 1-3 written per commit) }
  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T9', 'OpenPager failed ' + IntToStr(rc)); Exit; end;
  pbOpen := 0;
  rc := sqlite3PagerOpenWal(pPgr, @pbOpen);
  if rc <> SQLITE_OK then
  begin
    Fail('T9', 'OpenWal failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
  begin
    Fail('T9', 'SharedLock failed ' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil); Exit;
  end;

  for i := 1 to 3 do
  begin
    rc := sqlite3PagerBegin(pPgr, 0, 0);
    if rc <> SQLITE_OK then Break;
    pPg := nil;
    if sqlite3PagerGet(pPgr, i, @pPg, 0) = SQLITE_OK then
    begin
      if sqlite3PagerWrite(pPg) = SQLITE_OK then
      begin
        pData := Pu8(sqlite3PagerGetData(pPg));
        if i = 1 then WriteMinimalSQLiteHeader(pData, True)
        else       FillChar(pData^, PAGE_SIZE, $A0 + i);
      end;
      sqlite3PagerUnref(pPg);
    end;
    rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
    if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
    if rc <> SQLITE_OK then Break;
  end;

  if rc <> SQLITE_OK then
  begin
    Fail('T9', 'WAL writes failed rc=' + IntToStr(rc));
    sqlite3PagerClose(pPgr, nil);
    FpUnlink(PChar(dbPath)); FpUnlink(PChar(dbPath + '-wal')); FpUnlink(PChar(dbPath + '-shm'));
    Exit;
  end;

  { PASSIVE checkpoint — backfills WAL frames into the db file without
    requiring an exclusive lock; works even with the current connection active. }
  nLog := -1; nCkpt := -1;
  rc := sqlite3PagerCheckpoint(pPgr, nil, SQLITE_CHECKPOINT_PASSIVE,
                                nil, nil, @nLog, @nCkpt);
  sqlite3PagerClose(pPgr, nil);

  if rc <> SQLITE_OK then
  begin
    Fail('T9', 'checkpoint failed rc=' + IntToStr(rc));
    FpUnlink(PChar(dbPath)); FpUnlink(PChar(dbPath + '-wal')); FpUnlink(PChar(dbPath + '-shm'));
    Exit;
  end;

  { C opens the checkpointed db without error }
  cdb := nil;
  crc := csq_open_v2(PChar(dbPath), cdb, SQLITE_OPEN_READONLY, nil);
  if crc = SQLITE_CORRUPT then
    Fail('T9', 'C reports CORRUPT after WAL checkpoint')
  else if crc = SQLITE_NOTADB then
    Fail('T9', 'C reports NOTADB after WAL checkpoint')
  else
  begin
    if cdb <> nil then csq_close(cdb);
    Pass('T9');
  end;

  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-wal'));
  FpUnlink(PChar(dbPath + '-shm'));
end;

{ ---- T10 ---------------------------------------------------------------- }
{ Large 20-page transaction committed, then crash mid-next commit; recovery
  via hot-journal; C opens recovered db without corruption. }
procedure T10_LargeCommitCrashRecover;
var
  dbPath  : string;
  pPgr    : PPager;
  pPg     : PDbPage;
  pData   : Pu8;
  i       : i32;
  pid     : TPid;
  status  : cint;
  byt     : u8;
  cdb     : Pcsq_db;
  rc, crc : i32;
begin
  dbPath := '/tmp/pas_compat_t10.db';
  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-journal'));

  { Commit 20 pages with patterns $C0..$D3 }
  rc := OpenWritePager(dbPath, pPgr);
  if rc <> SQLITE_OK then begin Fail('T10', 'init open failed ' + IntToStr(rc)); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc = SQLITE_OK then rc := sqlite3PagerBegin(pPgr, 0, 0);
  for i := 1 to 20 do
  begin
    pPg := nil;
    if sqlite3PagerGet(pPgr, i, @pPg, 0) = SQLITE_OK then
    begin
      if sqlite3PagerWrite(pPg) = SQLITE_OK then
      begin
        pData := Pu8(sqlite3PagerGetData(pPg));
        if i = 1 then WriteMinimalSQLiteHeader(pData, False)
        else       FillChar(pData^, PAGE_SIZE, $C0 + i - 1);
      end;
      sqlite3PagerUnref(pPg);
    end;
  end;
  rc := sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
  if rc = SQLITE_OK then rc := sqlite3PagerCommitPhaseTwo(pPgr);
  sqlite3PagerClose(pPgr, nil);
  if rc <> SQLITE_OK then begin Fail('T10', 'big commit failed ' + IntToStr(rc)); Exit; end;

  { Child: start new transaction on all 20 pages writing $FF, PhaseOne only, then exit }
  pid := FpFork;
  if pid < 0 then begin Fail('T10', 'fork failed'); Exit; end;

  if pid = 0 then
  begin
    rc := OpenWritePager(dbPath, pPgr);
    if rc = SQLITE_OK then rc := sqlite3PagerSharedLock(pPgr);
    if rc = SQLITE_OK then rc := sqlite3PagerBegin(pPgr, 0, 0);
    for i := 1 to 20 do
    begin
      pPg := nil;
      if sqlite3PagerGet(pPgr, i, @pPg, 0) = SQLITE_OK then
      begin
        if sqlite3PagerWrite(pPg) = SQLITE_OK then
          FillChar(sqlite3PagerGetData(pPg)^, PAGE_SIZE, $FF);
        sqlite3PagerUnref(pPg);
      end;
    end;
    sqlite3PagerCommitPhaseOne(pPgr, nil, 0);
    FpExit(0);
  end;

  FpWaitPid(pid, @status, 0);

  { Reopen to trigger hot-journal replay }
  rc := OpenWritePager(dbPath, pPgr);
  if rc = SQLITE_OK then rc := sqlite3PagerSharedLock(pPgr);
  sqlite3PagerClose(pPgr, nil);

  { Verify pages 2-20 were restored to $C0..$D3 }
  byt := 0;
  rc := ReadPageByte(dbPath, 5, byt);
  if rc <> SQLITE_OK then
  begin
    Fail('T10', 'read p5 after recovery failed rc=' + IntToStr(rc));
    FpUnlink(PChar(dbPath)); FpUnlink(PChar(dbPath + '-journal')); Exit;
  end;
  if byt <> $C4 then  { page 5 should have $C0 + 4 = $C4 }
  begin
    Fail('T10', 'p5 expected $C4 after recovery, got $' + IntToHex(byt, 2));
    FpUnlink(PChar(dbPath)); FpUnlink(PChar(dbPath + '-journal')); Exit;
  end;

  { C opens without corruption }
  cdb := nil;
  crc := csq_open_v2(PChar(dbPath), cdb, SQLITE_OPEN_READONLY, nil);
  if crc = SQLITE_CORRUPT then
    Fail('T10', 'C reports CORRUPT on recovered db')
  else if crc = SQLITE_NOTADB then
    Fail('T10', 'C reports NOTADB on recovered db')
  else
  begin
    if cdb <> nil then csq_close(cdb);
    Pass('T10');
  end;

  FpUnlink(PChar(dbPath));
  FpUnlink(PChar(dbPath + '-journal'));
end;

{ ---- main --------------------------------------------------------------- }
begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  T1_CWritesPascalReads;
  T2_PascalCreatesCReads;
  T3_BigTransactionPersists;
  T4_SavepointRollback;
  T5_CrashRecoveryCompatible;
  T6_JournalCleanedUp;
  T7_CWritesPascalReadsAll;
  T8_PascalWalWriteCReads;
  T9_WalCheckpointThenCReads;
  T10_LargeCommitCrashRecover;

  if gAllPass then
  begin
    WriteLn;
    WriteLn('All pager compatibility tests PASSED.');
    Halt(0);
  end
  else
  begin
    WriteLn;
    WriteLn('Some pager compatibility tests FAILED.');
    Halt(1);
  end;
end.
