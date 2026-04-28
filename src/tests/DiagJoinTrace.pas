{$I ../passqlite3.inc}
program DiagJoinTrace;
{ Probe several variants of the INNER JOIN aggregate to localise the
  silent count=0 bug to either auto-index population or to the SeekGE
  arm of OP_SeekGE. }
uses SysUtils, passqlite3types, passqlite3util, passqlite3main, passqlite3vdbe, passqlite3codegen;

procedure run(const setup, q: AnsiString);
var db: PTsqlite3; pStmt: PVdbe; pTail: PAnsiChar; rcs: Int32;
begin
  db := nil; sqlite3_open(':memory:', @db);
  pStmt := nil; pTail := nil;
  sqlite3_prepare_v2(db, PAnsiChar(setup), -1, @pStmt, @pTail);
  if pStmt <> nil then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
  while (pTail <> nil) and (pTail^ <> #0) do begin
    pStmt := nil;
    if (sqlite3_prepare_v2(db, pTail, -1, @pStmt, @pTail) = 0) and (pStmt <> nil) then begin
      repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
      sqlite3_finalize(pStmt);
    end else break;
  end;
  pStmt := nil; pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(q), -1, @pStmt, @pTail);
  WriteLn('Q="', q, '"  prep=', rcs);
  if pStmt = nil then begin sqlite3_close(db); Exit; end;
  rcs := sqlite3_step(pStmt);
  WriteLn('  step=', rcs, '  val=', sqlite3_column_int(pStmt, 0));
  sqlite3_finalize(pStmt);
  sqlite3_close(db);
end;

const SETUP =
  'CREATE TABLE t(a); CREATE TABLE u(b);' +
  'INSERT INTO t VALUES(1); INSERT INTO u VALUES(1)';
begin
  run(SETUP, 'SELECT count(*) FROM t INNER JOIN u ON t.a=u.b');
  run(SETUP, 'SELECT count(*) FROM t, u WHERE t.a=u.b');
  run(SETUP, 'SELECT count(*) FROM t, u');
  { simple non-join sanity }
  run(SETUP, 'SELECT count(*) FROM u WHERE b=1');
  { Probe whether autoindex is actually the issue: query u directly with a row }
  run(SETUP, 'SELECT b FROM u WHERE b=1');
  run(SETUP, 'SELECT count(*) FROM t CROSS JOIN u ON t.a=u.b');
  run(SETUP, 'SELECT count(*) FROM t CROSS JOIN u WHERE t.a=u.b');
  { Non-aggregate join: returns rows? }
  run(SETUP, 'SELECT t.a FROM t INNER JOIN u ON t.a=u.b');
  run(SETUP, 'SELECT t.a FROM t, u WHERE t.a=u.b');
  { More rows; bigger fanout could change planner choice. }
  run(SETUP +
      ';INSERT INTO t VALUES(2);INSERT INTO t VALUES(3);'+
      'INSERT INTO u VALUES(2);INSERT INTO u VALUES(3)',
      'SELECT count(*) FROM t INNER JOIN u ON t.a=u.b');
end.
