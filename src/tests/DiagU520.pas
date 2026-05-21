program diag520;
{$mode objfpc}{$H+}
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe, passqlite3codegen, passqlite3main, csqlite3;
var db, st: Pointer; rc: Integer; tail: PAnsiChar;
procedure Exec(const sql: AnsiString);
begin
  st := nil;
  if (sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @st, nil)=0) and (st<>nil) then begin
    while sqlite3_step(st)=SQLITE_ROW do
      WriteLn('  row: ', AnsiString(PAnsiChar(sqlite3_column_text(st,0))));
    sqlite3_finalize(st);
  end else WriteLn('PREP FAIL: ', AnsiString(PAnsiChar(sqlite3_errmsg(db))));
end;
procedure ExpLn(const sql: AnsiString);
begin
  st := nil;
  if (sqlite3_prepare_v2(db, PAnsiChar('EXPLAIN '+sql), -1, @st, nil)=0) and (st<>nil) then begin
    while sqlite3_step(st)=SQLITE_ROW do
      WriteLn(Format('%3s %-16s %3s %3s %3s  %s',
        [AnsiString(PAnsiChar(sqlite3_column_text(st,0))),
         AnsiString(PAnsiChar(sqlite3_column_text(st,1))),
         AnsiString(PAnsiChar(sqlite3_column_text(st,2))),
         AnsiString(PAnsiChar(sqlite3_column_text(st,3))),
         AnsiString(PAnsiChar(sqlite3_column_text(st,4))),
         AnsiString(PAnsiChar(sqlite3_column_text(st,5)))]));
    sqlite3_finalize(st);
  end else WriteLn('EXPLAIN PREP FAIL: ', AnsiString(PAnsiChar(sqlite3_errmsg(db))));
end;
begin
  WriteLn('start'); Flush(Output);
  if sqlite3_open(':memory:', @db)<>0 then halt(1);
  WriteLn('opened'); Flush(Output);
  Exec('CREATE TABLE t1(abc INT, def INT)');
  Exec('INSERT INTO t1 VALUES(0,0)');
  Exec('INSERT INTO t1 VALUES(0,0)');
  Exec('INSERT INTO t1 VALUES(0,0)');
  Exec('CREATE TABLE dual(dummy TEXT)');
  Exec('INSERT INTO dual(dummy) VALUES(''X'')');
  WriteLn('--- EXPLAIN UPDATE ---');
  ExpLn('UPDATE t1 SET (abc,def)=(SELECT x,123) FROM dual LEFT JOIN (SELECT 789 AS ''x'' FROM dual) AS d2 LIMIT 2');
  WriteLn('--- RUN UPDATE ---');
  Exec('UPDATE t1 SET (abc,def)=(SELECT x,123) FROM dual LEFT JOIN (SELECT 789 AS ''x'' FROM dual) AS d2 LIMIT 2');
  WriteLn('--- RESULT ---');
  Exec('SELECT ''[''||abc||'' ''||def||'']'' FROM t1');
  sqlite3_close(db);
end.
