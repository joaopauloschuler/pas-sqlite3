{
  DiagTmstmpvfs — smoke test for the tmstmpvfs VFS shim
  (passqlite3tmstmpvfs.pas, port of ../sqlite3/ext/misc/tmstmpvfs.c).

  The shim only writes timestamp tags into pages when the database has
  reserve_bytes=16.  This test exercises both code paths:

    (1) Register the shim, open a default-reserve (=0) DB; the shim
        passes through and the DB still works end-to-end.
    (2) Open another DB with reserve_bytes=16 (set via the page header)
        — the shim activates and creates a per-connection log file in
        the sibling "<db>-tmstmp/" directory if it exists.

  We don't try to decode the binary log format here; we just verify the
  basic VFS plumbing works and the shim does not corrupt user data.
}
{$I passqlite3.inc}
program DiagTmstmpvfs;

uses
  SysUtils, BaseUnix,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser,
  passqlite3vtab,
  passqlite3main,
  passqlite3tmstmpvfs;

const
  TestPath  = '/tmp/diag_tmstmp_test.db';
  TestPath2 = '/tmp/diag_tmstmp_test2.db';
  LogDir    = '/tmp/diag_tmstmp_test2.db-tmstmp';

var
  fail: Integer = 0;

procedure Check(cond: Boolean; const msg: AnsiString);
begin
  if cond then WriteLn('ok  : ', msg)
  else begin
    WriteLn('FAIL: ', msg);
    Inc(fail);
  end;
end;

function ExecOk(db: PTsqlite3; const sql: AnsiString): Boolean;
var pErr: PAnsiChar;
begin
  pErr := nil;
  Result := sqlite3_exec(db, PAnsiChar(sql), nil, nil, @pErr) = SQLITE_OK;
  if pErr <> nil then begin
    WriteLn('  exec err: ', pErr);
    sqlite3_free(pErr);
  end;
end;

procedure RunPassthrough;
var
  db   : PTsqlite3;
  pStmt: Pointer;
  rc   : i32;
  cnt  : Integer;
begin
  if FileExists(TestPath) then DeleteFile(TestPath);
  rc := sqlite3_open(TestPath, @db);
  Check(rc = SQLITE_OK, 'open default-reserve DB through tmstmpvfs');
  Check(ExecOk(db, 'CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3);'),
        'CREATE+INSERT pass-through');
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT count(*) FROM t', -1, @pStmt, nil);
  Check(rc = SQLITE_OK, 'prepare count');
  if rc = SQLITE_OK then begin
    Check(sqlite3_step(pStmt) = SQLITE_ROW, 'step yields row');
    cnt := sqlite3_column_int(pStmt, 0);
    Check(cnt = 3, 'count = 3');
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
  if FileExists(TestPath) then DeleteFile(TestPath);
end;

procedure RunWithReserve;
var
  db   : PTsqlite3;
  pStmt: Pointer;
  rc   : i32;
begin
  if FileExists(TestPath2) then DeleteFile(TestPath2);
  { Pre-create the sibling log dir so the shim is willing to log. }
  if not DirectoryExists(LogDir) then
    fpMkdir(LogDir, &755);
  rc := sqlite3_open(TestPath2, @db);
  Check(rc = SQLITE_OK, 'open reserve-16 DB through tmstmpvfs');
  { reserve_bytes pragma must run before any table is created. }
  Check(ExecOk(db, 'PRAGMA page_size=4096; PRAGMA journal_mode=DELETE;'),
        'set page_size');
  Check(ExecOk(db, 'PRAGMA reserve_bytes=16;'), 'set reserve_bytes=16');
  Check(ExecOk(db,
        'CREATE TABLE t(x); INSERT INTO t VALUES(''hello''),(''world'');'),
        'CREATE+INSERT with reserve=16');
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT count(*) FROM t', -1, @pStmt, nil);
  if rc = SQLITE_OK then begin
    sqlite3_step(pStmt);
    Check(sqlite3_column_int(pStmt, 0) = 2, 'count=2 with reserve=16');
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
  if FileExists(TestPath2) then DeleteFile(TestPath2);
end;

var
  rc: i32;

begin
  WriteLn('DiagTmstmpvfs');
  WriteLn('-------------');
  rc := sqlite3_initialize;
  Check(rc = SQLITE_OK, 'sqlite3_initialize');

  rc := sqlite3_register_tmstmpvfs(nil);
  Check(rc = SQLITE_OK, 'sqlite3_register_tmstmpvfs ok');

  { After registration tmstmpvfs is the new default VFS; subsequent
    sqlite3_open() goes through it.  Make sure the basic open/CRUD
    pipeline survives. }
  RunPassthrough;
  RunWithReserve;

  Check(sqlite3_unregister_tmstmpvfs = SQLITE_OK,
        'unregister returns SQLITE_OK');

  if fail = 0 then begin
    WriteLn;
    WriteLn('DiagTmstmpvfs PASSED.');
    Halt(0);
  end else begin
    WriteLn;
    WriteLn('DiagTmstmpvfs FAILED (', fail, ' check(s)).');
    Halt(1);
  end;
end.
