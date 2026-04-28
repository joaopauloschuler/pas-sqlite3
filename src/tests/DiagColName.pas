{$I ../passqlite3.inc}
{
  DiagColName — verify sqlite3_column_name now returns the actual
  column name for prepared SELECTs (was NULL with the prior
  sqlite3VdbeSetColName / sqlite3VdbeSetNumCols stubs).
}
program DiagColName;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main;

var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs, i, n: i32;
  nm: PAnsiChar;
  ok: i32 = 0;
  total: i32 = 0;

procedure Probe(const sql, expectCol0: AnsiString);
begin
  Inc(total);
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if (rcs <> 0) or (pStmt = nil) then begin
    WriteLn('FAIL prep ', sql, ' rc=', rcs); Exit;
  end;
  n := sqlite3_column_count(pStmt);
  WriteLn(sql, ' nCol=', n);
  for i := 0 to n - 1 do begin
    nm := sqlite3_column_name(pStmt, i);
    if nm = nil then WriteLn('  [', i, '] <NIL>')
    else WriteLn('  [', i, '] "', AnsiString(nm), '"');
  end;
  if (n >= 1) then begin
    nm := sqlite3_column_name(pStmt, 0);
    if (nm <> nil) and (AnsiString(nm) = expectCol0) then Inc(ok)
    else WriteLn('   MISMATCH: expected "', expectCol0, '"');
  end;
  sqlite3_finalize(pStmt);
end;

begin
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Halt(1);
  pStmt := nil;
  if sqlite3_prepare_v2(db, 'CREATE TABLE t(a, b, c)', -1, @pStmt, nil) = 0 then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
  Probe('SELECT a FROM t', 'a');
  Probe('SELECT a, b FROM t', 'a');
  Probe('SELECT a AS xyz FROM t', 'xyz');
  Probe('SELECT count(*) FROM t', 'count(*)');
  WriteLn;
  WriteLn('Passed col-name match: ', ok, '/', total);
  sqlite3_close(db);
  if ok <> total then Halt(2);
end.
