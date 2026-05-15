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
  passqlite3codegen, passqlite3main,
  TestRowCollectCommon;

var
  db: PTsqlite3;
  failures: i32 = 0;

{ XFail — known-broken probe.  Surfaces the divergence each run but does
  NOT fail the gate; flips to a hard FAIL the day Pas catches up to C
  (the unexpected-PASS becomes a signal to remove the XFail wrapper). }
procedure XFail(const label_: AnsiString;
                const sql, wantC, gotPasNow: AnsiString);
var
  got: AnsiString;
begin
  got := RcCollectInts(db, sql);
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

  RcRunDdl(db,'CREATE TABLE t(a,b,c)');
  RcRunDdl(db,'INSERT INTO t VALUES(10,1,1)');
  RcRunDdl(db,'INSERT INTO t VALUES(20,2,2)');
  RcRunDdl(db,'INSERT INTO t VALUES(30,3,3)');

  RcExpect(db,'rowid IN (1,2)',
         'SELECT a FROM t WHERE rowid IN (1,2)', '10,20', failures);
  RcExpect(db,'rowid IN (1,2,3)',
         'SELECT a FROM t WHERE rowid IN (1,2,3)', '10,20,30', failures);
  RcExpect(db,'rowid IN (1,2,3,4) (3 matches)',
         'SELECT a FROM t WHERE rowid IN (1,2,3,4)', '10,20,30', failures);
  RcExpect(db,'rowid=1 OR rowid=2 (OR-to-IN)',
         'SELECT a FROM t WHERE rowid=1 OR rowid=2', '10,20', failures);
  RcExpect(db,'rowid=1 (control)',
         'SELECT a FROM t WHERE rowid=1', '10', failures);

  { ---- Hardening probes — edge cases of IPK-IN / OR-to-IN. }

  { Single-element IN list: degenerates to rowid=K shortcut in C. }
  RcExpect(db,'rowid IN (2) (singleton)',
         'SELECT a FROM t WHERE rowid IN (2)', '20', failures);

  { No-match IN list. }
  RcExpect(db,'rowid IN (99,100) (no match)',
         'SELECT a FROM t WHERE rowid IN (99,100)', '', failures);

  { Out-of-order IN keys — output should follow rowid scan order, not
    list order. }
  RcExpect(db,'rowid IN (3,1,2) (out of order)',
         'SELECT a FROM t WHERE rowid IN (3,1,2)', '10,20,30', failures);

  { Duplicate keys in IN list. }
  RcExpect(db,'rowid IN (1,1,1) (duplicates)',
         'SELECT a FROM t WHERE rowid IN (1,1,1)', '10', failures);

  { Negative rowids in list — must not match anything. }
  RcExpect(db,'rowid IN (-1,-2,1) (mixed sign)',
         'SELECT a FROM t WHERE rowid IN (-1,-2,1)', '10', failures);

  { 3-way OR-to-IN. }
  RcExpect(db,'rowid=1 OR rowid=2 OR rowid=3 (3-way OR)',
         'SELECT a FROM t WHERE rowid=1 OR rowid=2 OR rowid=3',
         '10,20,30', failures);

  { OR with one non-matching arm. }
  RcExpect(db,'rowid=1 OR rowid=99 (one miss)',
         'SELECT a FROM t WHERE rowid=1 OR rowid=99', '10', failures);

  { Combined IN + extra AND filter on non-rowid column. }
  RcExpect(db,'rowid IN (1,2,3) AND b>=2',
         'SELECT a FROM t WHERE rowid IN (1,2,3) AND b>=2', '20,30', failures);

  { NOT IN — full-scan exclusion path. }
  RcExpect(db,'rowid NOT IN (2)',
         'SELECT a FROM t WHERE rowid NOT IN (2)', '10,30', failures);

  { IN with a SELECT subquery — fixed by 6.IPK-IN.f
    (sqlite3BtreeIndexMoveto skip-to-root short-circuit was firing on any
    cursor cell, not just the last cell — masked all but the first IN
    membership probe). }
  RcExpect(db,'rowid IN (SELECT b FROM t)',
         'SELECT a FROM t WHERE rowid IN (SELECT b FROM t)',
         '10,20,30', failures);
  RcExpect(db,'a IN (SELECT b*10 FROM t) (general column)',
         'SELECT a FROM t WHERE a IN (SELECT b*10 FROM t)',
         '10,20,30', failures);

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
