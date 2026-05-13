{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  TestRowJoinCommon — shared scaffold for SELECT-result probes that
  collect every row's columns as '|'-joined text and rows as ';'-joined
  strings, then string-compare against an expected literal.

  jscpd flagged a 55-line clone between TestGroupOrder and TestJoinNatural:
  identical RunDdl (prepare/step DDL/DML driver), identical CollectRows
  (multi-column text-cell accumulator with NULL sentinel), and identical
  Expect (PASS/FAIL with 'sql:'/'want:'/'got:' echo).  Shape differs from
  TestRowCollectCommon (single-int column-0, comma-joined, no NULL/sql
  echo) and TestSqlOracleCommon (sqlite3_exec + single scalar) so this
  lives as its own unit.

  Hoisted verbatim — every WriteLn string and Inc placement matches the
  originals byte-for-byte so each probe's stdout stays unchanged.  The
  caller owns the `db` handle and the `failures` counter (passed by var).
}
unit TestRowJoinCommon;

interface

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe, passqlite3main;

{ Prepare `sql`, step until non-ROW, finalize.  Silent on error — both
  originals trusted DDL/DML to succeed and ignored rc. }
procedure RjRunDdl(db: PTsqlite3; const sql: AnsiString);

{ Collect every result row as 'col0|col1|...;col0|col1|...' (text values,
  nil column_text → 'NULL').  On prepare-fail returns sentinel
  '<prepare-failed rc=N>'; on step-fail returns '<step-failed rc=N>'. }
function RjCollectRows(db: PTsqlite3; const sql: AnsiString): AnsiString;

{ Compare RjCollectRows(sql) to `want`; PASS writes 'PASS  label -> got',
  FAIL writes label + sql/want/got echo and bumps `failures`. }
procedure RjExpect(db: PTsqlite3;
                   const label_, sql, want: AnsiString;
                   var failures: i32);

implementation

procedure RjRunDdl(db: PTsqlite3; const sql: AnsiString);
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

function RjCollectRows(db: PTsqlite3; const sql: AnsiString): AnsiString;
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

procedure RjExpect(db: PTsqlite3;
                   const label_, sql, want: AnsiString;
                   var failures: i32);
var
  got: AnsiString;
begin
  got := RjCollectRows(db, sql);
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

end.
