{$I ../passqlite3.inc}
{
  DiagExclLock — probe for 9.4.divbug.21: cross-connection EXCLUSIVE lock
  detection.  Opens two sqlite3 handles on the SAME on-disk file in one
  process.  db2 takes BEGIN EXCLUSIVE; db then attempts BEGIN IMMEDIATE,
  which must fail SQLITE_BUSY (matching the C reference / busy.test).
}
program DiagExclLock;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

function ExecRc(db: PTsqlite3; const sql: AnsiString): i32;
var
  pStmt: PVdbe;
  rcs: i32;
begin
  pStmt := nil;
  Result := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if (Result = 0) and (pStmt <> nil) then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    if (rcs <> SQLITE_DONE) and (rcs <> SQLITE_OK) then Result := rcs;
    sqlite3_finalize(pStmt);
  end;
end;

var
  db, db2: PTsqlite3;
  rc: i32;
  fn: AnsiString;
begin
  fn := 'diag_excllock.db';
  DeleteFile(fn);

  if sqlite3_open(PAnsiChar(fn), @db) <> 0 then begin
    WriteLn('FAIL: cannot open db'); Halt(1);
  end;
  WriteLn('opened db'); Flush(Output);
  ExecRc(db, 'CREATE TABLE t(x)');
  WriteLn('created table'); Flush(Output);

  if sqlite3_open(PAnsiChar(fn), @db2) <> 0 then begin
    WriteLn('FAIL: cannot open db2'); Halt(1);
  end;
  WriteLn('opened db2'); Flush(Output);

  rc := ExecRc(db2, 'BEGIN EXCLUSIVE');
  WriteLn('db2 BEGIN EXCLUSIVE          -> rc=', rc, ' (expect 0)');
  Flush(Output);

  rc := ExecRc(db, 'BEGIN IMMEDIATE');
  WriteLn('db  BEGIN IMMEDIATE          -> rc=', rc,
          ' (expect ', SQLITE_BUSY, ' SQLITE_BUSY)');
  Flush(Output);

  if rc = SQLITE_BUSY then
    WriteLn('PASS: cross-connection EXCLUSIVE lock detected')
  else
    WriteLn('FAIL: second connection was not blocked');

  ExecRc(db2, 'COMMIT');
  sqlite3_close(db);
  sqlite3_close(db2);
  DeleteFile(fn);
  if rc <> SQLITE_BUSY then Halt(1);
end.
