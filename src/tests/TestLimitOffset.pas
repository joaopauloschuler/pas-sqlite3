{$I ../passqlite3.inc}
{
  TestLimitOffset — runtime gate for the LIMIT/OFFSET execution path.

  EXPLAIN parity for `SELECT a FROM t LIMIT 5 OFFSET 2` was closed in
  commit 2d2a0f3 (Phase 6.10 step 6, OFFSET arm of computeLimitRegisters).
  This test verifies the runtime executes the program correctly — i.e.
  bytecode parity translates to result parity.
}
program TestLimitOffset;

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

function CollectInts(const sql: AnsiString): AnsiString;
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

procedure Expect(const label_: AnsiString; const sql, want: AnsiString);
var
  got: AnsiString;
begin
  got := CollectInts(sql);
  if got = want then
    WriteLn('PASS  ', label_, ' -> ', got)
  else begin
    WriteLn('FAIL  ', label_, '  want=[', want, ']  got=[', got, ']');
    WriteLn('      sql: ', sql);
    Inc(failures);
  end;
end;

var
  i: i32;
begin
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then begin
    WriteLn('open failed');
    Halt(2);
  end;

  RunDdl('CREATE TABLE t(a INTEGER PRIMARY KEY, b)');
  for i := 1 to 10 do
    RunDdl('INSERT INTO t VALUES(' + IntToStr(i) + ',' + IntToStr(i*10) + ')');

  Expect('LIMIT 5 OFFSET 2', 'SELECT a FROM t LIMIT 5 OFFSET 2', '3,4,5,6,7');
  Expect('LIMIT 3',          'SELECT a FROM t LIMIT 3',           '1,2,3');
  Expect('LIMIT 3 OFFSET 0', 'SELECT a FROM t LIMIT 3 OFFSET 0',  '1,2,3');
  Expect('LIMIT 100',        'SELECT a FROM t LIMIT 100',         '1,2,3,4,5,6,7,8,9,10');
  Expect('LIMIT 0',          'SELECT a FROM t LIMIT 0',           '');
  Expect('LIMIT 5 OFFSET 8', 'SELECT a FROM t LIMIT 5 OFFSET 8',  '9,10');
  Expect('LIMIT 5 OFFSET 20','SELECT a FROM t LIMIT 5 OFFSET 20', '');
  Expect('LIMIT -1',         'SELECT a FROM t LIMIT -1',          '1,2,3,4,5,6,7,8,9,10');
  Expect('LIMIT -1 OFFSET 7','SELECT a FROM t LIMIT -1 OFFSET 7', '8,9,10');

  sqlite3_close(db);

  if failures = 0 then begin
    WriteLn;
    WriteLn('TestLimitOffset: ALL PASS');
    Halt(0);
  end else begin
    WriteLn;
    WriteLn('TestLimitOffset: ', failures, ' failure(s)');
    Halt(1);
  end;
end.
