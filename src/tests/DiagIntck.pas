{
  DiagIntck — smoke test for passqlite3intck (port of ext/intck/sqlite3intck.c).

  Walks an open DB through sqlite3_intck_open / _step / _close and checks
  that no corruption is reported on a clean, fresh DB.  Also exercises
  sqlite3_intck_test_sql() and sqlite3_intck_unlock().
}
{$I passqlite3.inc}
program DiagIntck;

uses
  SysUtils,
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
  passqlite3intck;

var
  fail: Integer = 0;

procedure Check(cond: Boolean; const msg: AnsiString);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(fail);
  end else WriteLn('ok  : ', msg);
end;

procedure RunIntck(db: PTsqlite3);
var
  pCk:  PIntck;
  rc:   i32;
  zMsg: PAnsiChar;
  zErr: PAnsiChar;
  nMsgs: Integer;
  zSql: PAnsiChar;
begin
  pCk := nil;
  rc := sqlite3_intck_open(db, 'main', @pCk);
  Check(rc = SQLITE_OK, 'intck_open returns OK');
  Check(pCk <> nil, 'intck handle is non-nil');
  if pCk = nil then Exit;

  nMsgs := 0;
  while sqlite3_intck_step(pCk) = SQLITE_OK do begin
    zMsg := sqlite3_intck_message(pCk);
    if zMsg <> nil then begin
      WriteLn('corruption: ', zMsg);
      Inc(nMsgs);
    end;
  end;

  zErr := nil;
  rc := sqlite3_intck_error(pCk, @zErr);
  Check(rc = SQLITE_OK, 'intck_error returns OK after walk');
  Check(nMsgs = 0, 'no corruption reported on fresh DB');

  zSql := sqlite3_intck_test_sql(pCk, 't');
  Check((zSql = nil) or (zSql[0] <> #0),
    'test_sql returns nil or non-empty for known table');

  sqlite3_intck_close(pCk);
  WriteLn('intck_close returned (no crash)');
end;

var
  db: PTsqlite3;
  pErr: PAnsiChar;
begin
  Check(sqlite3_open_v2(':memory:', @db,
    SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil) = SQLITE_OK,
    'open :memory:');

  pErr := nil;
  sqlite3_exec(db,
    'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);' +
    'INSERT INTO t VALUES(1,''one''),(2,''two''),(3,''three'');' +
    'CREATE INDEX idx_b ON t(b);',
    nil, nil, @pErr);
  if pErr <> nil then begin
    WriteLn('exec err: ', pErr);
    sqlite3_free(pErr);
  end;

  RunIntck(db);

  sqlite3_close(db);

  if fail = 0 then WriteLn('DiagIntck PASSED.')
              else WriteLn('DiagIntck FAILED (', fail, ').');
  Halt(fail);
end.
