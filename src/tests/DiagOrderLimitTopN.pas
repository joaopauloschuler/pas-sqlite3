{ DiagOrderLimitTopN — verify Top-N sorter correctness for
  ORDER BY ... LIMIT queries.  Compares Pas results against C oracle. }
program DiagOrderLimitTopN;
{$mode objfpc}{$H+}
uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure RunOne(const lbl, setup, sql: AnsiString);
var
  pasDb: PTsqlite3;
  cDb: Pcsq_db;
  pasStmt: Pointer;
  cStmt: Pcsq_stmt;
  pasOut, cOut: AnsiString;
  rc: Integer;
  pErr: PChar;
  pTail: PChar;
begin
  pasDb := nil; cDb := nil;
  pasOut := ''; cOut := '';
  if sqlite3_open(':memory:', @pasDb) <> 0 then begin Inc(diverged); Exit; end;
  if csq_open(':memory:', cDb) <> 0 then begin Inc(diverged); Exit; end;
  if setup <> '' then begin
    sqlite3_exec(pasDb, PAnsiChar(setup), nil, nil, nil);
    csq_exec(cDb, PAnsiChar(setup), nil, nil, pErr);
  end;
  pasStmt := nil; cStmt := nil;
  rc := sqlite3_prepare_v2(pasDb, PAnsiChar(sql), -1, @pasStmt, nil);
  if rc <> 0 then pasOut := 'PREP_ERR'
  else
    while sqlite3_step(pasStmt) = 100 do
      pasOut := pasOut + IntToStr(sqlite3_column_int(pasStmt, 0)) + ',';
  if pasStmt <> nil then sqlite3_finalize(pasStmt);

  rc := csq_prepare_v2(cDb, PAnsiChar(sql), -1, cStmt, pTail);
  if rc <> 0 then cOut := 'PREP_ERR'
  else
    while csq_step(cStmt) = 100 do
      cOut := cOut + IntToStr(csq_column_int(cStmt, 0)) + ',';
  if cStmt <> nil then csq_finalize(cStmt);

  if pasOut = cOut then
    WriteLn('PASS    ', lbl, ' -> ', pasOut)
  else begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('  Pas=', pasOut);
    WriteLn('  C  =', cOut);
  end;
  sqlite3_close(pasDb);
  csq_close(cDb);
end;

const
  Setup =
    'CREATE TABLE t(a INTEGER);' +
    'INSERT INTO t VALUES(5),(2),(8),(1),(9),(3),(7),(4),(6),(10);';
begin
  WriteLn('Top-N sorter checks:');
  RunOne('ORDER BY a LIMIT 3',     Setup, 'SELECT a FROM t ORDER BY a LIMIT 3');
  RunOne('ORDER BY a DESC LIMIT 3',Setup, 'SELECT a FROM t ORDER BY a DESC LIMIT 3');
  RunOne('ORDER BY a LIMIT 5 OFFSET 2', Setup,
                                    'SELECT a FROM t ORDER BY a LIMIT 5 OFFSET 2');
  RunOne('ORDER BY a LIMIT 100',   Setup, 'SELECT a FROM t ORDER BY a LIMIT 100');
  RunOne('ORDER BY a LIMIT 1',     Setup, 'SELECT a FROM t ORDER BY a LIMIT 1');
  RunOne('ORDER BY a (no LIMIT)',  Setup, 'SELECT a FROM t ORDER BY a');
  RunOne('ORDER BY a LIMIT 0',     Setup, 'SELECT a FROM t ORDER BY a LIMIT 0');
  RunOne('ORDER BY a DESC LIMIT 0',Setup, 'SELECT a FROM t ORDER BY a DESC LIMIT 0');
  RunOne('ORDER BY a LIMIT 2 (small)', Setup, 'SELECT a FROM t ORDER BY a LIMIT 2');
  RunOne('ORDER BY a LIMIT 8 (large)', Setup, 'SELECT a FROM t ORDER BY a LIMIT 8');
  RunOne('ORDER BY a LIMIT 11 (over)', Setup, 'SELECT a FROM t ORDER BY a LIMIT 11');
  WriteLn('Total divergences: ', diverged);
  if diverged > 0 then Halt(1);
end.
