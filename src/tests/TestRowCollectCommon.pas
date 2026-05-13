{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  TestRowCollectCommon — shared scaffold for SELECT-result probes that
  collect every row's first column as a comma-joined IntToStr list and
  string-compare against an expected literal.

  jscpd flagged a 66-line clone between TestLimitOffset and TestRowidIn:
  identical `RunDdl` (prepare/step DDL/DML driver, no errmsg), identical
  `CollectInts` (column-0 int accumulator), and identical `Expect`
  (PASS/FAIL with `label -> got`).  Shape differs from
  TestSqlOracleCommon (which uses sqlite3_exec + single-scalar-text
  compare with a different WriteLn format) so this lives as its own unit.

  Hoisted verbatim — every WriteLn string and Inc placement matches the
  originals byte-for-byte so each probe's stdout stays unchanged.  The
  caller owns the `db` handle and the `failures` counter (passed by var)
  to preserve the exact prologue/epilogue lines of both originals.
}
unit TestRowCollectCommon;

interface

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe, passqlite3main;

{ Prepare `sql`, step until non-ROW, finalize.  Silent on error — both
  originals trusted DDL/DML to succeed and ignored rc. }
procedure RcRunDdl(db: PTsqlite3; const sql: AnsiString);

{ Prepare `sql`, step every row, accumulate column-0 as IntToStr joined
  by ','.  On prepare-fail returns the sentinel `<prepare-failed rc=N>`
  string (matches original behaviour exactly). }
function RcCollectInts(db: PTsqlite3; const sql: AnsiString): AnsiString;

{ Compare CollectInts(sql) to `want`; PASS writes `label -> got`, FAIL
  writes want/got + sql echo and bumps `failures`. }
procedure RcExpect(db: PTsqlite3;
                   const label_, sql, want: AnsiString;
                   var failures: i32);

implementation

procedure RcRunDdl(db: PTsqlite3; const sql: AnsiString);
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

function RcCollectInts(db: PTsqlite3; const sql: AnsiString): AnsiString;
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

procedure RcExpect(db: PTsqlite3;
                   const label_, sql, want: AnsiString;
                   var failures: i32);
var
  got: AnsiString;
begin
  got := RcCollectInts(db, sql);
  if got = want then
    WriteLn('PASS  ', label_, ' -> ', got)
  else begin
    WriteLn('FAIL  ', label_, '  want=[', want, ']  got=[', got, ']');
    WriteLn('      sql: ', sql);
    Inc(failures);
  end;
end;

end.
