{
  SPDX-License-Identifier: blessing

  Smoke probe for passqlite3scrub.sqlite3_scrub_backup.

  Creates a small db, inserts/deletes a row, then scrub-backs-up to a
  fresh file.  Asserts the destination opens cleanly and PRAGMA
  integrity_check returns 'ok' with the expected surviving row count.
}
{$I ../passqlite3.inc}
program DiagScrub;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3os, passqlite3pcache,
  passqlite3pager, passqlite3wal, passqlite3btree, passqlite3vdbe,
  passqlite3codegen, passqlite3parser, passqlite3vtab, passqlite3main,
  passqlite3scrub;

var
  db:    PTsqlite3;
  pStmt: Pointer;
  rc:    i32;
  zErr:  PAnsiChar;
  srcPath, dstPath: AnsiString;

procedure must(rc: i32; const tag: AnsiString);
begin
  if rc <> SQLITE_OK then begin
    WriteLn('FAIL ', tag, ' rc=', rc, ' err=', sqlite3_errmsg(db));
    Halt(1);
  end;
end;

begin
  srcPath := '/tmp/diag-scrub-src.db';
  dstPath := '/tmp/diag-scrub-dst.db';
  if FileExists(srcPath) then DeleteFile(srcPath);
  if FileExists(dstPath) then DeleteFile(dstPath);

  must(sqlite3_open_v2(PAnsiChar(srcPath), @db,
       SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil), 'open src');
  must(sqlite3_exec(db,
       'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);'#10 +
       'INSERT INTO t VALUES(1,''alpha''),(2,''beta''),(3,''gamma'');'#10 +
       'DELETE FROM t WHERE a=2;',
       nil, nil, nil), 'populate');
  must(sqlite3_close(db), 'close src');

  zErr := nil;
  rc := sqlite3_scrub_backup(PAnsiChar(srcPath), PAnsiChar(dstPath), @zErr);
  if rc <> SQLITE_OK then begin
    WriteLn('FAIL scrub_backup rc=', rc, ' err=',
            AnsiString(zErr));
    if zErr <> nil then sqlite3_free(zErr);
    Halt(1);
  end;

  must(sqlite3_open_v2(PAnsiChar(dstPath), @db,
       SQLITE_OPEN_READWRITE, nil), 'open dst');
  pStmt := nil;
  must(sqlite3_prepare_v2(db, 'SELECT count(*) FROM t', -1,
                          @pStmt, nil), 'prepare count');
  rc := sqlite3_step(pStmt);
  if rc <> SQLITE_ROW then begin
    WriteLn('FAIL count step rc=', rc); Halt(1);
  end;
  if sqlite3_column_int(pStmt, 0) <> 2 then begin
    WriteLn('FAIL count expected 2 got ', sqlite3_column_int(pStmt, 0));
    Halt(1);
  end;
  sqlite3_finalize(pStmt);

  must(sqlite3_prepare_v2(db, 'PRAGMA integrity_check', -1,
                          @pStmt, nil), 'prepare integ');
  rc := sqlite3_step(pStmt);
  if rc <> SQLITE_ROW then begin
    WriteLn('FAIL integ step rc=', rc); Halt(1);
  end;
  if AnsiString(sqlite3_column_text(PVdbe(pStmt), 0)) <> 'ok' then begin
    WriteLn('FAIL integ_check = ',
            AnsiString(sqlite3_column_text(PVdbe(pStmt), 0)));
    Halt(1);
  end;
  sqlite3_finalize(pStmt);
  sqlite3_close(db);

  WriteLn('DiagScrub PASSED.');
end.
