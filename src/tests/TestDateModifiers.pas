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
  TestDateModifiers — runtime gate for date()/datetime()/julianday()/timediff().

  Recent Phase 10.1 fixes that lacked Test* coverage:
    - bug.53  weekday/start-of-day/subsec date modifiers
    - bug.69  add timediff(); fix proleptic-Gregorian fromJulianDay
    - bug.70  integer-arithmetic toJulianDay
    - bug.71  +/-YYYY-MM-DD [HH:MM:SS.SSS] applyModifier arm

  Expected values were obtained from upstream sqlite3 3.53 (the C oracle).
}
program TestDateModifiers;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main;

var
  db: PTsqlite3;
  failures: i32 = 0;

function Scalar(const sql: AnsiString): AnsiString;
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs: i32;
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
  rcs := sqlite3_step(pStmt);
  if rcs = SQLITE_ROW then begin
    pText := PAnsiChar(sqlite3_column_text(pStmt, 0));
    if pText = nil then Result := 'NULL'
    else Result := AnsiString(pText);
  end else
    Result := '<step rc=' + IntToStr(rcs) + '>';
  sqlite3_finalize(pStmt);
end;

procedure Expect(const label_, sql, want: AnsiString);
var
  got: AnsiString;
begin
  got := Scalar(sql);
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

  { --- bug.71: ±YYYY-MM-DD modifier --- }
  Expect('T1  date +YYYY-MM-DD modifier',
         'SELECT date(''2024-01-15'',''+0001-02-03'')',
         '2025-03-18');

  { --- Basic absolute/relative arithmetic (regression sanity) --- }
  Expect('T2  date +1 day',
         'SELECT date(''2024-01-15'',''+1 day'')',
         '2024-01-16');

  Expect('T3  date -1 month',
         'SELECT date(''2024-01-15'',''-1 month'')',
         '2023-12-15');

  Expect('T4  leap-year +1 year normalises Feb 29',
         'SELECT date(''2024-02-29'',''+1 year'')',
         '2025-03-01');

  { --- bug.53: weekday modifier --- }
  Expect('T5  weekday 0 (Sunday) — 2024-01-15 is Mon, next Sun is 21st',
         'SELECT date(''2024-01-15'',''weekday 0'')',
         '2024-01-21');

  Expect('T6  weekday 1 — already Mon, returns same date',
         'SELECT date(''2024-01-15'',''weekday 1'')',
         '2024-01-15');

  { --- bug.53: start of day modifier --- }
  Expect('T7  datetime start of day truncates time',
         'SELECT datetime(''2024-01-15 12:34:56'',''start of day'')',
         '2024-01-15 00:00:00');

  { --- bug.69: julianday round-trip and proleptic-Gregorian --- }
  Expect('T8  julianday(2000-01-01) = 2451544.5',
         'SELECT julianday(''2000-01-01'')',
         '2451544.5');

  Expect('T9  date(julianday(X)) = X (round-trip)',
         'SELECT date(julianday(''2000-01-01''))',
         '2000-01-01');

  Expect('T10 julianday round-trip across 1582 cutover (proleptic)',
         'SELECT date(julianday(''1500-01-01''))',
         '1500-01-01');

  { --- bug.69: timediff() --- }
  Expect('T11 timediff: +1 day +1 hour',
         'SELECT timediff(''2024-12-25 10:00:00'',''2024-12-24 09:00:00'')',
         '+0000-00-01 01:00:00.000');

  Expect('T12 timediff: zero',
         'SELECT timediff(''2024-12-25 10:00:00'',''2024-12-25 10:00:00'')',
         '+0000-00-00 00:00:00.000');

  Expect('T13 timediff: negative',
         'SELECT timediff(''2024-12-24 09:00:00'',''2024-12-25 10:00:00'')',
         '-0000-00-01 01:00:00.000');

  sqlite3_close(db);

  if failures = 0 then begin
    WriteLn; WriteLn('TestDateModifiers: ALL PASS'); Halt(0);
  end else begin
    WriteLn; WriteLn('TestDateModifiers: ', failures, ' failure(s)'); Halt(1);
  end;
end.
