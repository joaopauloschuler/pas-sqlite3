{$I ../passqlite3.inc}
program TM;
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe, passqlite3codegen, passqlite3main;
var db: PTsqlite3; rc: i32; pStmt: PVdbe; z: PAnsiChar;
begin
  sqlite3_open(':memory:', @db);
  sqlite3_exec(db, 'CREATE TABLE t(g,v);INSERT INTO t VALUES(1,5),(1,7),(2,3),(2,9);', nil, nil, nil{%H-});
  sqlite3_prepare_v2(db, 'SELECT g, max(v) FROM t GROUP BY g', -1, @pStmt, nil);
  if pStmt = nil then begin WriteLn('prepare failed'); halt(1); end;
  repeat
    rc := sqlite3_step(pStmt);
    if rc = SQLITE_ROW then begin
      z := sqlite3_column_text(pStmt, 0); Write('g=', z);
      z := sqlite3_column_text(pStmt, 1); WriteLn(' max=', z);
    end;
  until rc <> SQLITE_ROW;
  WriteLn('done rc=', rc);
  sqlite3_finalize(pStmt);
  sqlite3_close(db);
end.
