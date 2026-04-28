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
  ReproOrRowid — runtime repro driver for the IPK-IN execution bug
  documented under tasklist.md → 6.10 step 6.IPK-IN.

  Exercises four shapes against an in-memory database and prints
  the row count + a bytecode dump.  Demonstrates:
    1. `WHERE rowid IN (1,2)`        — returns 0 rows (silent miss).
    2. `WHERE rowid=1 OR rowid=2`    — returns 0 rows (OR-rewrite to IN).
    3. `WHERE rowid IN (1,2,3)`      — crashes in btreeParseCell during
       sqlite3_step (eph IdxInsert).
    4. `WHERE rowid=1`               — works (rowid-EQ shortcut).

  This driver is intentionally NOT compiled by build.sh; pick it up
  with: `fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm src/tests/ReproOrRowid.pas`
  and run with `LD_LIBRARY_PATH=$PWD/src bin/ReproOrRowid`.
}
program ReproOrRowid;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main;

var
  db: PTsqlite3;
  rc: i32;

procedure RunDdl(const sql: AnsiString);
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs: i32;
begin
  pStmt := nil;
  pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if pStmt <> nil then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
end;

procedure DumpBytecode(const sql: AnsiString);
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs, i: i32;
  pop: PVdbeOp;
  nm: PAnsiChar;
begin
  WriteLn('=== ', sql);
  pStmt := nil;
  pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if pStmt = nil then begin WriteLn('  prepare rc=', rcs); Exit; end;
  for i := 0 to pStmt^.nOp - 1 do begin
    pop := PVdbeOp(PtrUInt(pStmt^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    nm  := sqlite3OpcodeName(pop^.opcode);
    WriteLn('  [', i, '] ', AnsiString(nm),
            ' p1=', pop^.p1, ' p2=', pop^.p2, ' p3=', pop^.p3,
            ' p5=', pop^.p5);
  end;
  sqlite3_finalize(pStmt);
end;

procedure RunSql(const sql: AnsiString);
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs: i32;
  rowCount: i32;
begin
  WriteLn('--- ', sql);
  pStmt := nil;
  pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if pStmt = nil then begin WriteLn('  prepare rc=', rcs); Exit; end;
  rowCount := 0;
  while True do begin
    rcs := sqlite3_step(pStmt);
    if rcs = SQLITE_ROW then begin
      Inc(rowCount);
      WriteLn('  row a=', sqlite3_column_int(pStmt, 0));
    end else
      break;
  end;
  WriteLn('  rows=', rowCount);
  sqlite3_finalize(pStmt);
end;

begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if rc <> 0 then Halt(1);

  RunDdl('CREATE TABLE t(a,b,c)');
  RunDdl('INSERT INTO t VALUES(10,1,1)');
  RunDdl('INSERT INTO t VALUES(20,2,2)');
  RunDdl('INSERT INTO t VALUES(30,3,3)');

  WriteLn('# expect 10,20  (currently empty — hoist-gate skip)');
  RunSql('SELECT a FROM t WHERE rowid IN (1,2)');

  WriteLn('# expect 10,20  (OR rewritten to IN(1,2) — same bug)');
  RunSql('SELECT a FROM t WHERE rowid=1 OR rowid=2');

  WriteLn('# expect 10  (rowid-EQ shortcut — works)');
  RunSql('SELECT a FROM t WHERE rowid=1');

  WriteLn;
  WriteLn('# bytecode dumps');
  DumpBytecode('SELECT a FROM t WHERE rowid IN (1,2)');
  DumpBytecode('SELECT a FROM t WHERE rowid=1 OR rowid=2');

  WriteLn;
  WriteLn('# expect 10,20,30');
  RunSql('SELECT a FROM t WHERE rowid IN (1,2,3)');

  WriteLn('# expect 10,20,30,40 (4-entry list)');
  RunSql('SELECT a FROM t WHERE rowid IN (1,2,3,4)');

  sqlite3_close(db);
end.
