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
  TestGroupOrder — runtime gate for GROUP BY / ORDER BY / HAVING combinations.

  These were exercised only by Diag* probes (DiagGroupOrder, DiagOps) and
  by recent Phase 10.1 bug fixes that did not have a pass/fail Test* gate:

    - bug.51  HAVING by SELECT-list column alias
    - bug.52  HAVING in non-GROUP-BY aggregate query
    - bug.73  agg-no-GROUP-BY allows ORDER BY
    - bug.74  HAVING on non-aggregate must error
    - DiagGroupOrder: GROUP BY ... ORDER BY {ASC,DESC}

  This binary makes them part of the formal regression gate.
}
program TestGroupOrder;

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

{ Collect every result row as 'col0|col1|...;col0|col1|...' (text values). }
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
    end else if rcs = SQLITE_DONE then
      break
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

{ ExpectError: prepare or step must fail (rc <> OK and <> ROW/DONE). }
procedure ExpectError(const label_, sql: AnsiString);
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs: i32;
  errored: Boolean;
begin
  pStmt := nil;
  pTail := nil;
  errored := False;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if rcs <> SQLITE_OK then errored := True;
  if pStmt <> nil then begin
    repeat
      rcs := sqlite3_step(pStmt);
      if (rcs <> SQLITE_ROW) and (rcs <> SQLITE_DONE) then errored := True;
    until (rcs <> SQLITE_ROW);
    sqlite3_finalize(pStmt);
  end;
  if errored then
    WriteLn('PASS  ', label_, ' (rejected as expected)')
  else begin
    WriteLn('FAIL  ', label_, ' (expected error, statement succeeded)');
    WriteLn('      sql:  ', sql);
    Inc(failures);
  end;
end;

begin
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then begin
    WriteLn('open failed');
    Halt(2);
  end;

  RunDdl('CREATE TABLE g(grp TEXT, val INTEGER)');
  RunDdl('INSERT INTO g VALUES (''a'',1),(''a'',2),(''b'',10),(''b'',20),(''c'',100)');

  { --- GROUP BY + ORDER BY (DiagGroupOrder cases) --- }
  Expect('T1  GROUP BY grp ORDER BY grp ASC',
         'SELECT grp, sum(val) FROM g GROUP BY grp ORDER BY grp ASC',
         'a|3;b|30;c|100');

  Expect('T2  GROUP BY grp ORDER BY grp DESC',
         'SELECT grp, sum(val) FROM g GROUP BY grp ORDER BY grp DESC',
         'c|100;b|30;a|3');

  Expect('T3  GROUP BY grp ORDER BY sum(val) DESC',
         'SELECT grp, sum(val) FROM g GROUP BY grp ORDER BY sum(val) DESC',
         'c|100;b|30;a|3');

  Expect('T4  GROUP BY grp ORDER BY 2 ASC (positional)',
         'SELECT grp, sum(val) FROM g GROUP BY grp ORDER BY 2 ASC',
         'a|3;b|30;c|100');

  { --- bug.73: aggregate w/o GROUP BY + ORDER BY --- }
  Expect('T5  SELECT count(*)/sum(val) FROM g ORDER BY 1',
         'SELECT count(*), sum(val) FROM g ORDER BY 1',
         '5|133');

  { --- bug.52: HAVING in non-GROUP-BY aggregate query --- }
  Expect('T6  HAVING on non-GROUP-BY aggregate (true)',
         'SELECT sum(val) FROM g HAVING sum(val) > 100',
         '133');

  Expect('T7  HAVING on non-GROUP-BY aggregate (false → no rows)',
         'SELECT sum(val) FROM g HAVING sum(val) > 1000',
         '');

  { --- HAVING with GROUP BY (sanity) --- }
  Expect('T8  GROUP BY ... HAVING count(*) >= 2',
         'SELECT grp, count(*) FROM g GROUP BY grp HAVING count(*) >= 2 ORDER BY grp',
         'a|2;b|2');

  { --- bug.51: HAVING by SELECT-list column alias --- }
  Expect('T9  HAVING references SELECT-list alias',
         'SELECT grp AS x, sum(val) AS s FROM g GROUP BY x HAVING s >= 30 ORDER BY x',
         'b|30;c|100');

  { --- bug.74: HAVING on non-aggregate must error --- }
  ExpectError('T10 HAVING on non-aggregate, no GROUP BY',
              'SELECT grp FROM g HAVING grp = ''a''');

  sqlite3_close(db);

  if failures = 0 then begin
    WriteLn;
    WriteLn('TestGroupOrder: ALL PASS');
    Halt(0);
  end else begin
    WriteLn;
    WriteLn('TestGroupOrder: ', failures, ' failure(s)');
    Halt(1);
  end;
end.
