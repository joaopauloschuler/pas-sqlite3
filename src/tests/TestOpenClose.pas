{$I ../passqlite3.inc}
program TestOpenClose;

{
  Phase 8.1 gate — exercise the Pascal sqlite3_open_v2 / sqlite3_close{,_v2}
  connection-lifecycle scaffolding.

  Coverage:
    T1  open(":memory:") + close — basic happy path
    T2  open_v2(":memory:", flags, nil) — explicit flags
    T3  open_v2 then close_v2 — alternate close path
    T4  open of an on-disk temp file (READWRITE|CREATE), then close
    T5  open + close on the same path twice (re-opens cleanly)
    T6  close(nil) is a harmless no-op (SQLITE_OK)
    T7  invalid flags combination → SQLITE_MISUSE, ppDb stays nil
    T8  ppDb=nil on input → SQLITE_MISUSE (no crash)

  Each case prints PASS or FAIL.  Exit code is non-zero on any failure.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3main;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin
    Inc(gPass);
    WriteLn('  PASS ', msg);
  end else begin
    Inc(gFail);
    WriteLn('  FAIL ', msg);
  end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

var
  db, db2: PTsqlite3;
  rc:      i32;
  tmpFile: AnsiString;

begin
  gPass := 0;
  gFail := 0;

  WriteLn('TestOpenClose — Phase 8.1 connection lifecycle');

  { T1 — open + close on :memory: }
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  ExpectEq(rc, SQLITE_OK,             'T1 open(:memory:) rc=SQLITE_OK');
  Expect(db <> nil,                   'T1 open(:memory:) ppDb non-nil');
  if db <> nil then
    ExpectEq(sqlite3_close(db), SQLITE_OK, 'T1 close rc=SQLITE_OK');

  { T2 — open_v2 with explicit flags }
  db := nil;
  rc := sqlite3_open_v2(':memory:', @db,
                        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK,             'T2 open_v2(:memory:) rc=SQLITE_OK');
  Expect(db <> nil,                   'T2 open_v2 ppDb non-nil');
  if db <> nil then
    ExpectEq(sqlite3_close(db), SQLITE_OK, 'T2 close rc=SQLITE_OK');

  { T3 — open_v2 then close_v2 }
  db := nil;
  rc := sqlite3_open_v2(':memory:', @db,
                        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK,             'T3 open_v2(:memory:) rc=SQLITE_OK');
  if db <> nil then
    ExpectEq(sqlite3_close_v2(db), SQLITE_OK, 'T3 close_v2 rc=SQLITE_OK');

  { T4 — open an on-disk temp file }
  tmpFile := GetTempDir + 'pas_sqlite3_open_close_test.db';
  if FileExists(tmpFile) then DeleteFile(tmpFile);
  db := nil;
  rc := sqlite3_open_v2(PAnsiChar(tmpFile), @db,
                        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK,             'T4 open_v2(file) rc=SQLITE_OK');
  Expect(db <> nil,                   'T4 open_v2(file) ppDb non-nil');
  if db <> nil then
    ExpectEq(sqlite3_close(db), SQLITE_OK, 'T4 close rc=SQLITE_OK');

  { T5 — re-open the same path }
  db2 := nil;
  rc := sqlite3_open_v2(PAnsiChar(tmpFile), @db2,
                        SQLITE_OPEN_READWRITE, nil);
  ExpectEq(rc, SQLITE_OK,             'T5 reopen rc=SQLITE_OK');
  if db2 <> nil then
    ExpectEq(sqlite3_close(db2), SQLITE_OK, 'T5 close rc=SQLITE_OK');
  if FileExists(tmpFile) then DeleteFile(tmpFile);

  { T6 — close(nil) is a harmless no-op }
  ExpectEq(sqlite3_close(nil),    SQLITE_OK, 'T6 close(nil)=SQLITE_OK');
  ExpectEq(sqlite3_close_v2(nil), SQLITE_OK, 'T6 close_v2(nil)=SQLITE_OK');

  { T7 — invalid flags (no R/W bits set) -> SQLITE_MISUSE }
  db := nil;
  rc := sqlite3_open_v2(':memory:', @db, 0, nil);
  ExpectEq(rc, SQLITE_MISUSE,         'T7 open_v2(flags=0) rc=SQLITE_MISUSE');
  { db will be in SICK state; calling close_v2 to free }
  if db <> nil then sqlite3_close_v2(db);

  { T8 — ppDb=nil on input → SQLITE_MISUSE }
  rc := sqlite3_open_v2(':memory:', nil,
                        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_MISUSE,         'T8 open_v2(ppDb=nil) rc=SQLITE_MISUSE');

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed.');
  if gFail = 0 then
    Halt(0)
  else
    Halt(1);
end.
