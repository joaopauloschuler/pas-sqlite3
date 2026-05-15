{
  SPDX-License-Identifier: blessing

  May you do good and not evil.
  May you find forgiveness for yourself and forgive others.
  May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful Pascal port of SQLite 3.53 — public-domain posture.
}
{$I ../passqlite3.inc}
{
  TestJoinNatural — runtime gate for NATURAL JOIN and JOIN USING(...).

  Phase 10.1.bug.77 ported sqlite3ProcessJoin so NATURAL JOIN no longer
  degenerates to a Cartesian product and JOIN USING(col) stops crashing.
  Coverage was Diag-only; this binary makes the cases part of the formal
  pass/fail gate.

  RunDdl/CollectRows/Expect hoisted to TestRowJoinCommon (shared with
  TestGroupOrder — jscpd 55-line clone).
}
program TestJoinNatural;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main,
  TestRowJoinCommon;

var
  db: PTsqlite3;
  failures: i32 = 0;

begin
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then begin
    WriteLn('open failed'); Halt(2);
  end;

  RjRunDdl(db, 'CREATE TABLE a(id INTEGER, name TEXT)');
  RjRunDdl(db, 'CREATE TABLE b(id INTEGER, val INTEGER)');
  RjRunDdl(db, 'INSERT INTO a VALUES(1,''one''),(2,''two''),(3,''three'')');
  RjRunDdl(db, 'INSERT INTO b VALUES(1,10),(2,20),(4,40)');

  { --- NATURAL JOIN: must filter to id-matching rows, not Cartesian --- }
  RjExpect(db, 'T1  NATURAL JOIN filters by shared column',
           'SELECT a.id, name, val FROM a NATURAL JOIN b ORDER BY a.id',
           '1|one|10;2|two|20', failures);

  { --- JOIN USING(col): coalesces shared col, returns matching rows --- }
  RjExpect(db, 'T2  JOIN USING(id) returns matching rows',
           'SELECT id, name, val FROM a JOIN b USING(id) ORDER BY id',
           '1|one|10;2|two|20', failures);

  { --- LEFT JOIN USING(col): unmatched left rows have NULL right side --- }
  RjExpect(db, 'T3  LEFT JOIN USING(id) preserves unmatched left rows',
           'SELECT a.id, name, val FROM a LEFT JOIN b USING(id) ORDER BY a.id',
           '1|one|10;2|two|20;3|three|NULL', failures);

  { --- NATURAL LEFT JOIN: same as USING + LEFT --- }
  RjExpect(db, 'T4  NATURAL LEFT JOIN preserves unmatched left rows',
           'SELECT a.id, name, val FROM a NATURAL LEFT JOIN b ORDER BY a.id',
           '1|one|10;2|two|20;3|three|NULL', failures);

  { --- 3-way NATURAL JOIN chain --- }
  RjRunDdl(db, 'CREATE TABLE c(id INTEGER, tag TEXT)');
  RjRunDdl(db, 'INSERT INTO c VALUES(1,''X''),(2,''Y''),(5,''Z'')');
  RjExpect(db, 'T5  3-way NATURAL JOIN intersects all shared keys',
           'SELECT a.id, name, val, tag FROM a NATURAL JOIN b NATURAL JOIN c ORDER BY a.id',
           '1|one|10|X;2|two|20|Y', failures);

  { --- USING with explicit qualified column reference still works --- }
  RjExpect(db, 'T6  JOIN USING then SELECT via qualified RHS column',
           'SELECT a.id, b.val FROM a JOIN b USING(id) ORDER BY a.id',
           '1|10;2|20', failures);

  sqlite3_close(db);

  if failures = 0 then begin
    WriteLn; WriteLn('TestJoinNatural: ALL PASS'); Halt(0);
  end else begin
    WriteLn; WriteLn('TestJoinNatural: ', failures, ' failure(s)'); Halt(1);
  end;
end.
