{$I ../passqlite3.inc}
program TestExecGetTable;

{
  Phase 8.6 gate — exercise sqlite3_exec / sqlite3_get_table /
  sqlite3_free_table.

  Phase 8.6 scope: legacy.c and table.c are ported in full.  But the
  per-statement codegen (CREATE/INSERT/SELECT) is still Phase 6/7 —
  prepare typically returns ppStmt = nil for non-trivial SQL.  These
  tests therefore focus on the surface API contract:

    T1  exec(db, "")                 — rc=OK,  pzErrMsg=nil
    T2  exec(db, ";  ;")             — rc=OK   (whitespace/empty path)
    T3  exec(db=nil)                 — rc=SQLITE_MISUSE
    T4  exec(zSql=nil)               — coerced to "", rc=OK
    T5  exec(syntax-error SQL)       — rc<>OK, pzErrMsg populated and
                                       sqlite3_free()-able
    T6  exec(pzErrMsg=nil) on error  — does not crash
    T7  get_table(blank)             — rc=OK, *pazResult non-nil with
                                       a single zero-length row vector
    T8  get_table(syntax-error)      — rc<>OK, pzErrMsg populated
    T9  free_table(get_table result) — round-trip frees cleanly
    T10 get_table(db=nil)            — rc=SQLITE_MISUSE
    T11 get_table(pazResult=nil)     — rc=SQLITE_MISUSE
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,   { sqlite3_free }
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

var
  db:      PTsqlite3;
  rc:      i32;
  zErr:    PAnsiChar;
  azRes:   PPAnsiChar;
  nRow, nCol: i32;

const
  SQL_BLANK : PAnsiChar = '';
  SQL_SEMIS : PAnsiChar = ';  ;';
  SQL_BAD   : PAnsiChar = 'SELEKT 1';

begin
  gPass := 0; gFail := 0;
  WriteLn('TestExecGetTable — Phase 8.6 sqlite3_exec / get_table');

  db := nil;
  rc := sqlite3_open(':memory:', @db);
  ExpectEq(rc, SQLITE_OK, 'open(:memory:)');
  if (rc <> SQLITE_OK) or (db = nil) then begin
    WriteLn('  open failed — aborting'); Halt(1);
  end;

  { T1 — empty SQL. }
  zErr := PAnsiChar(PtrUInt($DEAD));
  rc := sqlite3_exec(db, SQL_BLANK, nil, nil, @zErr);
  ExpectEq(rc, SQLITE_OK, 'T1 exec(empty) rc');
  Expect(zErr = nil,      'T1 exec(empty) pzErrMsg=nil');

  { T2 — whitespace + semicolons only. }
  zErr := PAnsiChar(PtrUInt($DEAD));
  rc := sqlite3_exec(db, SQL_SEMIS, nil, nil, @zErr);
  ExpectEq(rc, SQLITE_OK, 'T2 exec(";  ;") rc');
  Expect(zErr = nil,      'T2 exec(";  ;") pzErrMsg=nil');

  { T3 — db=nil. }
  rc := sqlite3_exec(nil, SQL_BLANK, nil, nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T3 exec(db=nil)');

  { T4 — zSql=nil coerces to "". }
  rc := sqlite3_exec(db, nil, nil, nil, nil);
  ExpectEq(rc, SQLITE_OK, 'T4 exec(zSql=nil)');

  { T5 — parse error populates pzErrMsg. }
  zErr := nil;
  rc := sqlite3_exec(db, SQL_BAD, nil, nil, @zErr);
  Expect(rc <> SQLITE_OK, 'T5 exec(SELEKT) returns non-OK');
  Expect(zErr <> nil,     'T5 exec(SELEKT) populates pzErrMsg');
  if zErr <> nil then sqlite3_free(zErr);

  { T6 — pzErrMsg=nil on error must not crash. }
  rc := sqlite3_exec(db, SQL_BAD, nil, nil, nil);
  Expect(rc <> SQLITE_OK, 'T6 exec(SELEKT, pzErrMsg=nil) survives');

  { T7 — get_table on blank SQL. }
  azRes := nil; nRow := -1; nCol := -1; zErr := nil;
  rc := sqlite3_get_table(db, SQL_BLANK, @azRes, @nRow, @nCol, @zErr);
  ExpectEq(rc, SQLITE_OK, 'T7 get_table(blank) rc');
  ExpectEq(nRow, 0, 'T7 nRow=0');
  ExpectEq(nCol, 0, 'T7 nCol=0');
  Expect(azRes <> nil, 'T7 azResult non-nil');
  Expect(zErr = nil,   'T7 pzErrMsg=nil');
  sqlite3_free_table(azRes);

  { T8 — get_table on syntax error. }
  azRes := nil; nRow := -1; nCol := -1; zErr := nil;
  rc := sqlite3_get_table(db, SQL_BAD, @azRes, @nRow, @nCol, @zErr);
  Expect(rc <> SQLITE_OK, 'T8 get_table(SELEKT) returns non-OK');
  Expect(zErr <> nil,     'T8 pzErrMsg populated');
  if zErr <> nil then sqlite3_free(zErr);

  { T9 — free_table accepts a freshly-allocated table. }
  azRes := nil;
  rc := sqlite3_get_table(db, SQL_BLANK, @azRes, nil, nil, nil);
  ExpectEq(rc, SQLITE_OK, 'T9 get_table(blank) rc');
  Expect(azRes <> nil, 'T9 azResult non-nil');
  sqlite3_free_table(azRes);
  Expect(True, 'T9 free_table did not crash');

  { T10 — db=nil. }
  azRes := nil;
  rc := sqlite3_get_table(nil, SQL_BLANK, @azRes, nil, nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T10 get_table(db=nil)');

  { T11 — pazResult=nil. }
  rc := sqlite3_get_table(db, SQL_BLANK, nil, nil, nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T11 get_table(pazResult=nil)');

  ExpectEq(sqlite3_close(db), SQLITE_OK, 'close');

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed.');
  if gFail = 0 then Halt(0) else Halt(1);
end.
