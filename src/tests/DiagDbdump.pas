{
  SPDX-License-Identifier: blessing

  Smoke probe for passqlite3dbdump.sqlite3_db_dump.

  Builds a small in-memory database, dumps it via sqlite3_db_dump into
  an AnsiString accumulator, and verifies the canonical statements
  appear in the output (CREATE TABLE, INSERT INTO, etc.).  Then opens
  a fresh :memory: connection and replays the dumped script — must
  reproduce the row counts.
}
{$I ../passqlite3.inc}
program DiagDbdump;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3os, passqlite3pcache,
  passqlite3pager, passqlite3wal, passqlite3btree, passqlite3vdbe,
  passqlite3codegen, passqlite3parser, passqlite3vtab, passqlite3main,
  passqlite3dbdump;

var
  buf: AnsiString;
  db, db2: PTsqlite3;
  pStmt:   Pointer;
  rc:      i32;

function dumpSink(z: PAnsiChar; pArg: Pointer): i32; cdecl;
begin
  if z <> nil then buf := buf + AnsiString(z);
  Result := 0;
end;

procedure must(rc: i32; const tag: AnsiString);
begin
  if rc <> SQLITE_OK then begin
    WriteLn('FAIL ', tag, ' rc=', rc, ' err=', sqlite3_errmsg(db));
    Halt(1);
  end;
end;

procedure expect(const needle: AnsiString);
begin
  if Pos(needle, buf) = 0 then begin
    WriteLn('FAIL: dump missing "', needle, '"');
    WriteLn('--- dump follows ---');
    WriteLn(buf);
    Halt(1);
  end;
end;

begin
  buf := '';
  must(sqlite3_open(':memory:', @db), 'open src');
  must(sqlite3_exec(db,
    'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);'#10 +
    'INSERT INTO t VALUES(1,''alpha'', x''00ff'');'#10 +
    'INSERT INTO t VALUES(2,''line1'' || char(10) || ''line2'', NULL);'#10 +
    'INSERT INTO t VALUES(3,''quoted '''' inside'', NULL);'#10 +
    'CREATE INDEX t_b ON t(b);'#10,
    nil, nil, nil), 'populate');

  rc := sqlite3_db_dump(db, 'main', nil, @dumpSink, nil);
  if rc <> SQLITE_OK then begin
    WriteLn('FAIL sqlite3_db_dump rc=', rc); Halt(1);
  end;

  expect('PRAGMA foreign_keys=OFF;');
  expect('BEGIN TRANSACTION;');
  expect('CREATE TABLE t(');
  expect('INSERT INTO t');
  expect('CREATE INDEX t_b ON t(b)');
  expect('COMMIT;');
  expect('x''00ff''');
  expect('replace(');  { embedded \n triggers replace() wrapping }

  { Replay against a fresh in-memory connection. }
  must(sqlite3_open(':memory:', @db2), 'open dst');
  must(sqlite3_exec(db2, PAnsiChar(buf), nil, nil, nil), 'replay');

  pStmt := nil;
  must(sqlite3_prepare_v2(db2, 'SELECT count(*) FROM t', -1,
                          @pStmt, nil), 'prepare count');
  rc := sqlite3_step(pStmt);
  if rc <> SQLITE_ROW then begin
    WriteLn('FAIL count step rc=', rc); Halt(1);
  end;
  if sqlite3_column_int(pStmt, 0) <> 3 then begin
    WriteLn('FAIL count expected 3 got ', sqlite3_column_int(pStmt, 0));
    Halt(1);
  end;
  sqlite3_finalize(pStmt);

  sqlite3_close(db2);
  sqlite3_close(db);
  WriteLn('DiagDbdump PASSED.');
end.
