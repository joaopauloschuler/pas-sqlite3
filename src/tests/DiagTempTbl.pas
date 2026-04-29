{$I ../passqlite3.inc}
program DiagTempTbl;
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

procedure RunPas;
var
  db: PTsqlite3;
  rc: i32;
  err: PAnsiChar;
  pStmt: PVdbe;
  s: AnsiString;
begin
  WriteLn('=== Pas ===');
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin WriteLn('open fail'); Exit; end;
  err := nil;
  rc := sqlite3_exec(db, 'CREATE TEMP TABLE t(x INTEGER)', nil, nil, @err);
  WriteLn('CREATE TEMP rc=', rc);
  if err <> nil then WriteLn('  err=', AnsiString(err));

  rc := sqlite3_exec(db, 'INSERT INTO t VALUES(42)', nil, nil, @err);
  WriteLn('INSERT t rc=', rc);
  if err <> nil then WriteLn('  err=', AnsiString(err));

  rc := sqlite3_exec(db, 'INSERT INTO temp.t VALUES(43)', nil, nil, @err);
  WriteLn('INSERT temp.t rc=', rc);
  if err <> nil then WriteLn('  err=', AnsiString(err));

  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT count(*) FROM t', -1, @pStmt, nil);
  WriteLn('prep SELECT rc=', rc);
  if (pStmt <> nil) then begin
    rc := sqlite3_step(pStmt);
    WriteLn('step rc=', rc, '  count=', sqlite3_column_int(pStmt, 0));
    sqlite3_finalize(pStmt);
  end;

  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT type, name, tbl_name FROM sqlite_temp_schema', -1, @pStmt, nil);
  WriteLn('prep sqlite_temp_schema rc=', rc);
  if (pStmt <> nil) then begin
    while sqlite3_step(pStmt) = 100 do begin
      s := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 1)));
      WriteLn('  row: ', s);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure RunC;
var
  db: Pcsq_db;
  rc: i32;
  err: PChar;
  pStmt: Pcsq_stmt;
  pzTail: PChar;
begin
  WriteLn('=== C ===');
  db := nil;
  if csq_open(':memory:', db) <> 0 then begin WriteLn('open fail'); Exit; end;
  err := nil;
  rc := csq_exec(db, 'CREATE TEMP TABLE t(x INTEGER)', nil, nil, err);
  WriteLn('CREATE TEMP rc=', rc);
  if err <> nil then WriteLn('  err=', AnsiString(err));
  rc := csq_exec(db, 'INSERT INTO t VALUES(42)', nil, nil, err);
  WriteLn('INSERT rc=', rc);
  if err <> nil then WriteLn('  err=', AnsiString(err));
  pStmt := nil;
  rc := csq_prepare_v2(db, 'SELECT count(*) FROM t', -1, pStmt, pzTail);
  WriteLn('prep rc=', rc);
  if (pStmt <> nil) then begin
    rc := csq_step(pStmt);
    WriteLn('step rc=', rc, '  count=', csq_column_int(pStmt, 0));
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

begin
  RunPas;
  WriteLn;
  RunC;
end.
