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
  TestLimitOffset — runtime gate for the LIMIT/OFFSET execution path.

  EXPLAIN parity for `SELECT a FROM t LIMIT 5 OFFSET 2` was closed in
  commit 2d2a0f3 (Phase 6.10 step 6, OFFSET arm of computeLimitRegisters).
  This test verifies the runtime executes the program correctly — i.e.
  bytecode parity translates to result parity.
}
program TestLimitOffset;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main,
  TestRowCollectCommon;

var
  db: PTsqlite3;
  failures: i32 = 0;
  i: i32;
begin
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then begin
    WriteLn('open failed');
    Halt(2);
  end;

  RcRunDdl(db,'CREATE TABLE t(a INTEGER PRIMARY KEY, b)');
  for i := 1 to 10 do
    RcRunDdl(db,'INSERT INTO t VALUES(' + IntToStr(i) + ',' + IntToStr(i*10) + ')');

  RcExpect(db,'LIMIT 5 OFFSET 2', 'SELECT a FROM t LIMIT 5 OFFSET 2', '3,4,5,6,7', failures);
  RcExpect(db,'LIMIT 3',          'SELECT a FROM t LIMIT 3',           '1,2,3', failures);
  RcExpect(db,'LIMIT 3 OFFSET 0', 'SELECT a FROM t LIMIT 3 OFFSET 0',  '1,2,3', failures);
  RcExpect(db,'LIMIT 100',        'SELECT a FROM t LIMIT 100',         '1,2,3,4,5,6,7,8,9,10', failures);
  RcExpect(db,'LIMIT 0',          'SELECT a FROM t LIMIT 0',           '', failures);
  RcExpect(db,'LIMIT 5 OFFSET 8', 'SELECT a FROM t LIMIT 5 OFFSET 8',  '9,10', failures);
  RcExpect(db,'LIMIT 5 OFFSET 20','SELECT a FROM t LIMIT 5 OFFSET 20', '', failures);
  RcExpect(db,'LIMIT -1',         'SELECT a FROM t LIMIT -1',          '1,2,3,4,5,6,7,8,9,10', failures);
  RcExpect(db,'LIMIT -1 OFFSET 7','SELECT a FROM t LIMIT -1 OFFSET 7', '8,9,10', failures);

  sqlite3_close(db);

  if failures = 0 then begin
    WriteLn;
    WriteLn('TestLimitOffset: ALL PASS');
    Halt(0);
  end else begin
    WriteLn;
    WriteLn('TestLimitOffset: ', failures, ' failure(s)');
    Halt(1);
  end;
end.
