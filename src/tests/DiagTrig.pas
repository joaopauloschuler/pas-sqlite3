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
  DiagTrig — runtime probe for AFTER INSERT trigger fire.

  Tasklist 6.23 ("BEFORE / AFTER INSERT triggers") landed the trigger
  body compiler (codeRowTrigger / codeTriggerProgram / transferParseError)
  plus parse-time fixes for sqlite3FinishTrigger.  CREATE TRIGGER now
  parses cleanly and the structural call into sqlite3CodeRowTrigger
  from sqlite3Insert is wired.

  KNOWN BUG (open): an INSERT that actually fires an AFTER trigger
  crashes during sqlite3_finalize with `free(): double free detected
  in tcache 2`.  gdb backtrace shows the parent VDBE's aOp/nOp seen by
  vdbeFreeOpArray are corrupted (small bogus pointer + huge nOp).
  Suspect: sub-vdbe / parent-vdbe lifecycle interaction in
  codeRowTrigger or in nested sqlite3Insert codegen against the
  sub-Parse.

  This program intentionally exercises the failing path so the bug
  is visible in the test tree.  Until the bisect lands, running
  this binary is expected to print the C-reference outcome and
  abort with the double-free on the Pascal side.

  Build: bash src/tests/build.sh
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagTrig
}
program DiagTrig;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3main, csqlite3;

procedure RunPas;
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
begin
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin
    WriteLn('  open failed'); Exit;
  end;

  pStmt := nil;
  sqlite3_prepare_v2(db, 'CREATE TABLE t(a)', -1, @pStmt, nil);
  if pStmt <> nil then begin
    while sqlite3_step(pStmt) = SQLITE_ROW do;
    sqlite3_finalize(pStmt);
  end;
  pStmt := nil;
  sqlite3_prepare_v2(db, 'CREATE TABLE log(n)', -1, @pStmt, nil);
  if pStmt <> nil then begin
    while sqlite3_step(pStmt) = SQLITE_ROW do;
    sqlite3_finalize(pStmt);
  end;

  pStmt := nil;
  rcs := sqlite3_prepare_v2(db,
    'CREATE TRIGGER tr AFTER INSERT ON t BEGIN '
    + '  INSERT INTO log VALUES(NEW.a); '
    + 'END',
    -1, @pStmt, nil);
  WriteLn('  Pas CREATE TRIGGER prepare rc=', rcs);
  if pStmt <> nil then begin
    while sqlite3_step(pStmt) = SQLITE_ROW do;
    sqlite3_finalize(pStmt);
  end;

  WriteLn('  Pas about to INSERT — KNOWN-CRASH path:');
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'INSERT INTO t VALUES(7)', -1, @pStmt, nil);
  WriteLn('  Pas INSERT prepare rc=', rcs);
  if pStmt <> nil then begin
    rcs := sqlite3_step(pStmt);
    WriteLn('  Pas INSERT step rc=', rcs);
    sqlite3_finalize(pStmt);     { ← double-free triggers here today }
  end;

  pStmt := nil;
  if (sqlite3_prepare_v2(db, 'SELECT n FROM log', -1, @pStmt, nil) = 0)
    and (pStmt <> nil) then begin
    if sqlite3_step(pStmt) = SQLITE_ROW then
      WriteLn('  Pas log.n = ', sqlite3_column_int(pStmt, 0))
    else
      WriteLn('  Pas log empty (trigger did not fire)');
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure RunC;
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  pErr: PChar;
begin
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pErr := nil;
  csq_exec(db, 'CREATE TABLE t(a)', nil, nil, pErr);
  csq_exec(db, 'CREATE TABLE log(n)', nil, nil, pErr);
  csq_exec(db,
    'CREATE TRIGGER tr AFTER INSERT ON t BEGIN '
    + '  INSERT INTO log VALUES(NEW.a); '
    + 'END',
    nil, nil, pErr);
  csq_exec(db, 'INSERT INTO t VALUES(7)', nil, nil, pErr);

  pStmt := nil; pTail := nil;
  if (csq_prepare_v2(db, 'SELECT n FROM log', -1, pStmt, pTail) = 0)
    and (pStmt <> nil) then begin
    if csq_step(pStmt) = SQLITE_ROW then
      WriteLn('  C   log.n = ', csq_column_int(pStmt, 0))
    else
      WriteLn('  C   log empty');
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

begin
  WriteLn('=== DiagTrig: AFTER INSERT trigger fire ===');
  WriteLn('Expected: log.n = 7 on both sides.');
  WriteLn('Status:   Pas KNOWN-CRASH on the INSERT finalize.');
  WriteLn;
  WriteLn('C reference:');
  RunC;
  WriteLn;
  WriteLn('Pascal:');
  RunPas;       { may abort here with double-free }
  WriteLn;
  WriteLn('If this line printed, the leak is fixed — flip 6.23 [~] to [X].');
end.
