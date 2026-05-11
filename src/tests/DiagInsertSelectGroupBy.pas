{$I ../passqlite3.inc}
program DiagInsertSelectGroupBy;
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe, passqlite3codegen, passqlite3main;

procedure RunStep(db: PTsqlite3; const sql: AnsiString);
var
  pStmt: PVdbe;
  rcs, ncols, i: i32;
  z: PAnsiChar;
begin
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  WriteLn('prepare rc=', rcs, ' sql=', sql);
  if pStmt = nil then Exit;
  repeat
    rcs := sqlite3_step(pStmt);
    if rcs = SQLITE_ROW then begin
      ncols := sqlite3_column_count(pStmt);
      Write('  row:');
      for i := 0 to ncols - 1 do begin
        z := sqlite3_column_text(pStmt, i);
        Write(' |');
        if z <> nil then Write(z) else Write('NULL');
      end;
      WriteLn;
    end;
  until rcs <> SQLITE_ROW;
  WriteLn('  done rc=', rcs);
  sqlite3_finalize(pStmt);
end;

var
  db: PTsqlite3;
  rc: i32;
  z: PAnsiChar;
begin
  z := nil;
  rc := sqlite3_open(':memory:', @db);
  WriteLn('open rc=', rc);
  rc := sqlite3_exec(db,
    'CREATE TABLE src(pg, cell, field, val);' +
    'INSERT INTO src VALUES(1,1,0,''a''),(1,1,1,''b''),(1,2,0,''c''),(2,1,0,''d''),(3,1,0,''e'');' +
    'CREATE TABLE keep(p);' +
    'INSERT INTO keep VALUES(1),(2);' +
    'CREATE TABLE dst(pg, cell, m);',
    nil, nil, @z);
  WriteLn('setup rc=', rc);
  if z <> nil then begin WriteLn('errmsg=', z); halt(1); end;

  { 10.1.48.a covers basic INSERT ... SELECT ... GROUP BY }
  RunStep(db, 'INSERT INTO dst SELECT pg, cell, max(val) FROM src GROUP BY pg, cell');
  RunStep(db, 'SELECT pg, cell, m FROM dst ORDER BY pg, cell');

  RunStep(db, 'DELETE FROM dst');

  { 10.1.48.b — IN-RHS subquery inside SRT_Coroutine producer.  Mirrors the
    .recover shape: INSERT ... SELECT ... WHERE pgno IN (SELECT p FROM cte)
    GROUP BY ... }
  RunStep(db,
    'INSERT INTO dst SELECT pg, cell, max(val) FROM src '+
    'WHERE pg IN (SELECT p FROM keep) GROUP BY pg, cell');
  RunStep(db, 'SELECT pg, cell, m FROM dst ORDER BY pg, cell');

  RunStep(db, 'DELETE FROM dst');

  { 10.1.48.b — IN-RHS over a recursive CTE }
  RunStep(db,
    'INSERT INTO dst '+
    'WITH RECURSIVE pages(p) AS ( '+
    '  SELECT 1 UNION ALL SELECT p+1 FROM pages WHERE p < 2 '+
    ') '+
    'SELECT pg, cell, max(val) FROM src '+
    'WHERE pg IN (SELECT p FROM pages) GROUP BY pg, cell');
  RunStep(db, 'SELECT pg, cell, m FROM dst ORDER BY pg, cell');

  sqlite3_close(db);
end.
