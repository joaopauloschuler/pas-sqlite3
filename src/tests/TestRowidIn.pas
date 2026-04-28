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
  TestRowidIn — runtime gate for the IPK-IN execution path
  (tasklist.md → 6.10 step 6.IPK-IN.c).

  Asserts end-to-end SELECT semantics for shapes that exercise the
  rowid-aliased PRIMARY KEY + ephemeral-index lookup path:

    1. WHERE rowid IN (1,2)
    2. WHERE rowid IN (1,2,3)
    3. WHERE rowid IN (1,2,3,4)        -- 4-entry list, 3 matching rows
    4. WHERE rowid=1 OR rowid=2        -- OR rewritten to IN by exprAnalyzeOrTerm
    5. WHERE rowid=1                   -- rowid-EQ shortcut (control)

  Regressions in any of these surface as missing rows or btree crashes
  during sqlite3_step.  Each shape maps to a tri-bug fixed at
  6.IPK-IN.a (hoist-gate / BtreePayloadFetch index offset) and
  6.IPK-IN.e (OR-to-IN verify-loop skipping the candidate term).
}
program TestRowidIn;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main;

var
  db: PTsqlite3;
  failures: i32 = 0;

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

function CollectInts(const sql: AnsiString): AnsiString;
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs: i32;
begin
  Result := '';
  pStmt := nil;
  pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if pStmt = nil then begin
    Result := '<prepare-failed rc=' + IntToStr(rcs) + '>';
    Exit;
  end;
  while True do begin
    rcs := sqlite3_step(pStmt);
    if rcs = SQLITE_ROW then begin
      if Result <> '' then Result := Result + ',';
      Result := Result + IntToStr(sqlite3_column_int(pStmt, 0));
    end else
      break;
  end;
  sqlite3_finalize(pStmt);
end;

procedure Expect(const label_: AnsiString; const sql, want: AnsiString);
var
  got: AnsiString;
begin
  got := CollectInts(sql);
  if got = want then
    WriteLn('PASS  ', label_, ' -> ', got)
  else begin
    WriteLn('FAIL  ', label_, '  want=[', want, ']  got=[', got, ']');
    WriteLn('      sql: ', sql);
    Inc(failures);
  end;
end;

{ XFail — known-broken probe.  Surfaces the divergence each run but does
  NOT fail the gate; flips to a hard FAIL the day Pas catches up to C
  (the unexpected-PASS becomes a signal to remove the XFail wrapper). }
procedure XFail(const label_: AnsiString;
                const sql, wantC, gotPasNow: AnsiString);
var
  got: AnsiString;
begin
  got := CollectInts(sql);
  if got = gotPasNow then
    WriteLn('XFAIL ', label_, '  pas=[', got, ']  c=[', wantC, ']')
  else if got = wantC then begin
    WriteLn('UPASS ', label_, ' (now matches C; remove XFail) -> ', got);
    Inc(failures);
  end else
    WriteLn('XFAIL ', label_, '  pas=[', got, ']  c=[', wantC,
            ']  (drift from prior pas=[', gotPasNow, '])');
end;

begin
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin
    WriteLn('FAIL  open :memory:');
    Halt(1);
  end;

  RunDdl('CREATE TABLE t(a,b,c)');
  RunDdl('INSERT INTO t VALUES(10,1,1)');
  RunDdl('INSERT INTO t VALUES(20,2,2)');
  RunDdl('INSERT INTO t VALUES(30,3,3)');

  Expect('rowid IN (1,2)',
         'SELECT a FROM t WHERE rowid IN (1,2)', '10,20');
  Expect('rowid IN (1,2,3)',
         'SELECT a FROM t WHERE rowid IN (1,2,3)', '10,20,30');
  Expect('rowid IN (1,2,3,4) (3 matches)',
         'SELECT a FROM t WHERE rowid IN (1,2,3,4)', '10,20,30');
  Expect('rowid=1 OR rowid=2 (OR-to-IN)',
         'SELECT a FROM t WHERE rowid=1 OR rowid=2', '10,20');
  Expect('rowid=1 (control)',
         'SELECT a FROM t WHERE rowid=1', '10');

  { ---- Hardening probes — edge cases of IPK-IN / OR-to-IN. }

  { Single-element IN list: degenerates to rowid=K shortcut in C. }
  Expect('rowid IN (2) (singleton)',
         'SELECT a FROM t WHERE rowid IN (2)', '20');

  { No-match IN list. }
  Expect('rowid IN (99,100) (no match)',
         'SELECT a FROM t WHERE rowid IN (99,100)', '');

  { Out-of-order IN keys — output should follow rowid scan order, not
    list order. }
  Expect('rowid IN (3,1,2) (out of order)',
         'SELECT a FROM t WHERE rowid IN (3,1,2)', '10,20,30');

  { Duplicate keys in IN list. }
  Expect('rowid IN (1,1,1) (duplicates)',
         'SELECT a FROM t WHERE rowid IN (1,1,1)', '10');

  { Negative rowids in list — must not match anything. }
  Expect('rowid IN (-1,-2,1) (mixed sign)',
         'SELECT a FROM t WHERE rowid IN (-1,-2,1)', '10');

  { 3-way OR-to-IN. }
  Expect('rowid=1 OR rowid=2 OR rowid=3 (3-way OR)',
         'SELECT a FROM t WHERE rowid=1 OR rowid=2 OR rowid=3',
         '10,20,30');

  { OR with one non-matching arm. }
  Expect('rowid=1 OR rowid=99 (one miss)',
         'SELECT a FROM t WHERE rowid=1 OR rowid=99', '10');

  { Combined IN + extra AND filter on non-rowid column. }
  Expect('rowid IN (1,2,3) AND b>=2',
         'SELECT a FROM t WHERE rowid IN (1,2,3) AND b>=2', '20,30');

  { NOT IN — full-scan exclusion path. }
  Expect('rowid NOT IN (2)',
         'SELECT a FROM t WHERE rowid NOT IN (2)', '10,30');

  { IN with a SELECT subquery — fixed by 6.IPK-IN.f
    (sqlite3BtreeIndexMoveto skip-to-root short-circuit was firing on any
    cursor cell, not just the last cell — masked all but the first IN
    membership probe). }
  Expect('rowid IN (SELECT b FROM t)',
         'SELECT a FROM t WHERE rowid IN (SELECT b FROM t)',
         '10,20,30');
  Expect('a IN (SELECT b*10 FROM t) (general column)',
         'SELECT a FROM t WHERE a IN (SELECT b*10 FROM t)',
         '10,20,30');

  sqlite3_close(db);

  WriteLn;
  if failures = 0 then begin
    WriteLn('TestRowidIn: ALL PASS');
    Halt(0);
  end else begin
    WriteLn('TestRowidIn: ', failures, ' FAILURE(S)');
    Halt(1);
  end;
end.
