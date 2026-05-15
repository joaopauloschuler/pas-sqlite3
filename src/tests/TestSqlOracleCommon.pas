{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  TestSqlOracleCommon — shared SQL-oracle scaffold for resolver/regression
  probes that just need to (a) exec DDL/DML, (b) read back a single scalar
  and string-compare it against an expected literal.

  jscpd flagged a 70-line clone between TestCteOuterID and
  TestUpdateCorrelated: identical `Run` (sqlite3_exec wrapper) and
  `CheckScalar` (sqlite3_prepare_v2 + step + column_text + compare)
  bodies, plus identical failCount/passCount globals.

  Hoisted verbatim — every WriteLn string and Halt/Inc placement matches
  the originals byte-for-byte so stdout of each test binary stays
  unchanged.  Names prefixed `Oracle` to avoid clashing with TestShell*
  helpers (which run an out-of-process upstream-sqlite3 oracle, a
  different shape).
}
unit TestSqlOracleCommon;

interface

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3os, passqlite3main, passqlite3vdbe;

var
  gOraclePass: i32 = 0;
  gOracleFail: i32 = 0;

{ Exec `sql` via sqlite3_exec; on error print FAIL+errmsg, free, Halt(1).
  Matches the inline `Run` proc in both probes verbatim. }
procedure OracleRun(db: PTsqlite3; const sql: AnsiString);

{ Prepare `sql`, step once, read column 0 as text, string-compare against
  `expect`.  PASS/FAIL line uses `what` as the label.  Matches the inline
  `CheckScalar` proc in both probes verbatim. }
procedure OracleCheckScalar(db: PTsqlite3;
                            const sql, expect, what: AnsiString);

implementation

procedure OracleRun(db: PTsqlite3; const sql: AnsiString);
var
  rc: i32;
  pErr: PAnsiChar;
begin
  pErr := nil;
  rc := sqlite3_exec(db, PAnsiChar(sql), nil, nil, @pErr);
  if rc <> SQLITE_OK then begin
    if pErr <> nil then begin
      WriteLn('FAIL exec: ', AnsiString(pErr));
      sqlite3_free(pErr);
    end else
      WriteLn('FAIL exec rc=', rc, ': ', sql);
    Inc(gOracleFail);
    Halt(1);
  end;
end;

procedure OracleCheckScalar(db: PTsqlite3;
                            const sql, expect, what: AnsiString);
var
  pStmt: PVdbe;
  rc:    i32;
  pTail: PAnsiChar;
  got:   AnsiString;
  z:     PAnsiChar;
begin
  pStmt := nil; pTail := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if rc <> SQLITE_OK then begin
    WriteLn('FAIL ', what, ' prepare rc=', rc, ' err="',
            AnsiString(sqlite3_errmsg(db)), '"');
    Inc(gOracleFail); Exit;
  end;
  got := '';
  if sqlite3_step(pStmt) = SQLITE_ROW then begin
    z := sqlite3_column_text(pStmt, 0);
    if z <> nil then got := AnsiString(z);
  end;
  sqlite3_finalize(pStmt);
  if got = expect then begin
    WriteLn('PASS ', what, ' = "', got, '"');
    Inc(gOraclePass);
  end else begin
    WriteLn('FAIL ', what, ' expected="', expect, '" got="', got, '"');
    Inc(gOracleFail);
  end;
end;

end.
