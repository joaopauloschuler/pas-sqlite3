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
}
program TestJoinNatural;

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

function CollectRows(const sql: AnsiString): AnsiString;
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs, nCol, i: i32;
  row, cell: AnsiString;
  pText: PAnsiChar;
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
      nCol := sqlite3_column_count(pStmt);
      row := '';
      for i := 0 to nCol - 1 do begin
        pText := PAnsiChar(sqlite3_column_text(pStmt, i));
        if pText = nil then cell := 'NULL' else cell := AnsiString(pText);
        if i = 0 then row := cell else row := row + '|' + cell;
      end;
      if Result <> '' then Result := Result + ';';
      Result := Result + row;
    end else if rcs = SQLITE_DONE then break
    else begin
      Result := '<step-failed rc=' + IntToStr(rcs) + '>';
      break;
    end;
  end;
  sqlite3_finalize(pStmt);
end;

procedure Expect(const label_, sql, want: AnsiString);
var
  got: AnsiString;
begin
  got := CollectRows(sql);
  if got = want then
    WriteLn('PASS  ', label_, ' -> ', got)
  else begin
    WriteLn('FAIL  ', label_);
    WriteLn('      sql:  ', sql);
    WriteLn('      want: [', want, ']');
    WriteLn('      got:  [', got, ']');
    Inc(failures);
  end;
end;

begin
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then begin
    WriteLn('open failed'); Halt(2);
  end;

  RunDdl('CREATE TABLE a(id INTEGER, name TEXT)');
  RunDdl('CREATE TABLE b(id INTEGER, val INTEGER)');
  RunDdl('INSERT INTO a VALUES(1,''one''),(2,''two''),(3,''three'')');
  RunDdl('INSERT INTO b VALUES(1,10),(2,20),(4,40)');

  { --- NATURAL JOIN: must filter to id-matching rows, not Cartesian --- }
  Expect('T1  NATURAL JOIN filters by shared column',
         'SELECT a.id, name, val FROM a NATURAL JOIN b ORDER BY a.id',
         '1|one|10;2|two|20');

  { --- JOIN USING(col): coalesces shared col, returns matching rows --- }
  Expect('T2  JOIN USING(id) returns matching rows',
         'SELECT id, name, val FROM a JOIN b USING(id) ORDER BY id',
         '1|one|10;2|two|20');

  { --- LEFT JOIN USING(col): unmatched left rows have NULL right side --- }
  Expect('T3  LEFT JOIN USING(id) preserves unmatched left rows',
         'SELECT a.id, name, val FROM a LEFT JOIN b USING(id) ORDER BY a.id',
         '1|one|10;2|two|20;3|three|NULL');

  { --- NATURAL LEFT JOIN: same as USING + LEFT --- }
  Expect('T4  NATURAL LEFT JOIN preserves unmatched left rows',
         'SELECT a.id, name, val FROM a NATURAL LEFT JOIN b ORDER BY a.id',
         '1|one|10;2|two|20;3|three|NULL');

  { --- 3-way NATURAL JOIN chain --- }
  RunDdl('CREATE TABLE c(id INTEGER, tag TEXT)');
  RunDdl('INSERT INTO c VALUES(1,''X''),(2,''Y''),(5,''Z'')');
  Expect('T5  3-way NATURAL JOIN intersects all shared keys',
         'SELECT a.id, name, val, tag FROM a NATURAL JOIN b NATURAL JOIN c ORDER BY a.id',
         '1|one|10|X;2|two|20|Y');

  { --- USING with explicit qualified column reference still works --- }
  Expect('T6  JOIN USING then SELECT via qualified RHS column',
         'SELECT a.id, b.val FROM a JOIN b USING(id) ORDER BY a.id',
         '1|10;2|20');

  sqlite3_close(db);

  if failures = 0 then begin
    WriteLn; WriteLn('TestJoinNatural: ALL PASS'); Halt(0);
  end else begin
    WriteLn; WriteLn('TestJoinNatural: ', failures, ' failure(s)'); Halt(1);
  end;
end.
