{$I ../passqlite3.inc}
program ISO;
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe, passqlite3codegen, passqlite3main;
procedure R(db: PTsqlite3; const sql: AnsiString);
var pStmt: PVdbe; rcs, ncols, i: i32; z: PAnsiChar;
begin
  pStmt := nil; sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  WriteLn('SQL: ', sql);
  if pStmt = nil then begin WriteLn('  prepare nil'); Exit; end;
  repeat
    rcs := sqlite3_step(pStmt);
    if rcs = SQLITE_ROW then begin
      ncols := sqlite3_column_count(pStmt);
      Write('  row:');
      for i := 0 to ncols - 1 do begin
        z := sqlite3_column_text(pStmt, i);
        Write(' |'); if z <> nil then Write(z) else Write('NULL');
      end; WriteLn;
    end;
  until rcs <> SQLITE_ROW;
  WriteLn('  rc=', rcs);
  sqlite3_finalize(pStmt);
end;
var db: PTsqlite3;
begin
  sqlite3_open(':memory:', @db);
  sqlite3_exec(db, 'CREATE TABLE src(p);INSERT INTO src VALUES(1),(2),(3);', nil, nil, nil{%H-});
  { 1. Recursive CTE alone in plain SELECT }
  R(db, 'WITH RECURSIVE pages(p) AS (SELECT 1 UNION ALL SELECT p+1 FROM pages WHERE p<3) SELECT p FROM pages');
  { 2. Recursive CTE referenced from regular WHERE/IN (SRT_Output) }
  R(db, 'WITH RECURSIVE pages(p) AS (SELECT 1 UNION ALL SELECT p+1 FROM pages WHERE p<2) SELECT p FROM src WHERE p IN (SELECT p FROM pages)');
  { 3. Same shape inside a coroutine consumer: a CREATE AS SELECT — uses SRT_Table }
  R(db, 'CREATE TABLE x AS WITH RECURSIVE pages(p) AS (SELECT 1 UNION ALL SELECT p+1 FROM pages WHERE p<2) SELECT p FROM src WHERE p IN (SELECT p FROM pages)');
  R(db, 'SELECT * FROM x');
  { 4. INSERT INTO ... SELECT ... with non-recursive CTE in coroutine context }
  R(db, 'DROP TABLE IF EXISTS y');
  R(db, 'CREATE TABLE y(p)');
  R(db, 'INSERT INTO y WITH pages(p) AS (SELECT 1 UNION ALL SELECT 2) SELECT p FROM src WHERE p IN (SELECT p FROM pages)');
  R(db, 'SELECT * FROM y');
  sqlite3_close(db);
end.
