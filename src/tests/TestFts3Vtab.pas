{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  This is a faithful port of SQLite 3.53 (https://sqlite.org/) from C to
  Free Pascal, authored by Dr. Joao Paulo Schwarz Schuler and contributors
  (see commit history).
}
{$I ../passqlite3.inc}
program TestFts3Vtab;

{
  Phase 6.40.1.k integration keystone — drives REAL SQL against the now-
  registered fts3/fts4 vtab modules: CREATE VIRTUAL TABLE, INSERT, MATCH
  (single term, AND, OR, phrase, NEAR, column-scoped), xColumn reads,
  DELETE/UPDATE re-query, FTS4 prefix=/notindexed= options.

  Asserts the matching rowids for each query against the expected sets.
  A DIFFERENTIAL section shells out to ../sqlite3/sqlite3 (the C oracle,
  which has FTS4) running the SAME script and byte-compares the output.

  Exit 0 = PASS.
}

uses
  ctypes,
  SysUtils,
  StrUtils,
  Strings,
  Process,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3main,
  passqlite3fts3;

var
  g_fail: Integer = 0;

procedure Check(cond: Boolean; const msg: string);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(g_fail);
  end;
end;

procedure ExecOK(db: PTsqlite3; const zSql: string; const what: string);
var
  rc: i32;
  zErr: PAnsiChar;
begin
  zErr := nil;
  rc := sqlite3_exec(db, PAnsiChar(zSql), nil, nil, @zErr);
  Check(rc = SQLITE_OK, what + ' (rc=' + IntToStr(rc) + ')');
  if zErr <> nil then begin
    if rc <> SQLITE_OK then WriteLn('   exec err: ', zErr);
    sqlite3_free(zErr);
  end;
end;

{ Run a query that selects a single integer column (a rowid) per row and
  return the comma-joined list of values in row order. }
function QueryRowids(db: PTsqlite3; const zSql: string): string;
var
  pStmt: Pointer;
  rc: i32;
begin
  Result := '';
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin
    WriteLn('   prepare err: ', sqlite3_errmsg(db), '  sql=', zSql);
    Result := 'ERR'; Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    if Result <> '' then Result := Result + ',';
    Result := Result + IntToStr(sqlite3_column_int64(pStmt, 0));
  end;
  sqlite3_finalize(pStmt);
end;

{ Return the text of a single-row, single-column query. }
function QueryText(db: PTsqlite3; const zSql: string): string;
var
  pStmt: Pointer;
  rc: i32;
  z: PAnsiChar;
begin
  Result := '';
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin Result := 'ERR'; Exit; end;
  if sqlite3_step(pStmt) = SQLITE_ROW then begin
    z := sqlite3_column_text(pStmt, 0);
    if z <> nil then Result := StrPas(z);
  end;
  sqlite3_finalize(pStmt);
end;

procedure CheckQ(db: PTsqlite3; const zSql, exp, what: string);
var got: string;
begin
  got := QueryRowids(db, zSql);
  Check(got = exp, what + ': expected [' + exp + '] got [' + got + ']');
end;

{ Run an SQL script through the C oracle shell (single :memory: arg) and
  capture stdout, normalising newlines to commas in row order. }
function OracleRun(const zScript: string): string;
var
  outp: AnsiString;
begin
  outp := '';
  if not RunCommand('../sqlite3/sqlite3', [':memory:', zScript], outp) then begin
    Result := 'ORACLE_ERR'; Exit;
  end;
  outp := StringReplace(Trim(string(outp)), #13, '', [rfReplaceAll]);
  Result := StringReplace(string(outp), #10, ',', [rfReplaceAll]);
end;

procedure PopulateBasic(db: PTsqlite3);
begin
  { rowid 1..4 }
  ExecOK(db, 'INSERT INTO t(content) VALUES(''hello world'')', 'ins 1');
  ExecOK(db, 'INSERT INTO t(content) VALUES(''goodbye world'')', 'ins 2');
  ExecOK(db, 'INSERT INTO t(content) VALUES(''hello there friend'')', 'ins 3');
  ExecOK(db, 'INSERT INTO t(content) VALUES(''a quick brown fox'')', 'ins 4');
end;

var
  db: PTsqlite3;
  rc: i32;
  oracleOut, mineOut: string;
  haveOracle: Boolean;
begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Check(rc = SQLITE_OK, 'open :memory:');

  { ---- FTS4 single-column table + MATCH queries ---- }
  ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(content)', 'create fts4(content)');
  PopulateBasic(db);

  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''world''', '1,2', 'MATCH world');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''hello''', '1,3', 'MATCH hello');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''hello world''', '1', 'AND hello world');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''hello OR fox''', '1,3,4', 'OR hello fox');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''"hello world"''', '1', 'phrase "hello world"');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''"hello there"''', '3', 'phrase "hello there"');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''hello NEAR/2 friend''', '3', 'NEAR/2');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''world NOT goodbye''', '1', 'NOT goodbye');

  { ---- xColumn read ---- }
  Check(QueryText(db, 'SELECT content FROM t WHERE rowid=2') = 'goodbye world',
    'xColumn content rowid=2');

  { ---- DELETE + UPDATE re-query ---- }
  ExecOK(db, 'DELETE FROM t WHERE rowid=1', 'delete rowid 1');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''world''', '2', 'MATCH world after delete');
  ExecOK(db, 'UPDATE t SET content=''hello again world'' WHERE rowid=3', 'update rowid 3');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''world''', '2,3', 'MATCH world after update');
  CheckQ(db, 'SELECT rowid FROM t WHERE t MATCH ''again''', '3', 'MATCH again after update');

  { ---- FTS3 multi-column + column-scoped MATCH ---- }
  ExecOK(db, 'CREATE VIRTUAL TABLE m USING fts3(a, b)', 'create fts3(a,b)');
  ExecOK(db, 'INSERT INTO m(a,b) VALUES(''foo cat'', ''bar dog'')', 'ins m1');
  ExecOK(db, 'INSERT INTO m(a,b) VALUES(''bar bird'', ''foo fish'')', 'ins m2');
  CheckQ(db, 'SELECT rowid FROM m WHERE m MATCH ''a:foo''', '1', 'column-scoped a:foo');
  CheckQ(db, 'SELECT rowid FROM m WHERE m MATCH ''b:foo''', '2', 'column-scoped b:foo');
  CheckQ(db, 'SELECT rowid FROM m WHERE m MATCH ''foo''', '1,2', 'unscoped foo (both cols)');

  { ---- FTS4 prefix= + notindexed= options ---- }
  ExecOK(db, 'CREATE VIRTUAL TABLE px USING fts4(content, tag, prefix="2,3", notindexed=tag)',
    'create fts4 prefix=2,3 notindexed=tag');
  ExecOK(db, 'INSERT INTO px(content,tag) VALUES(''application program'', ''ignored'')', 'ins px1');
  ExecOK(db, 'INSERT INTO px(content,tag) VALUES(''apple pie'', ''skip'')', 'ins px2');
  CheckQ(db, 'SELECT rowid FROM px WHERE px MATCH ''app*''', '1,2', 'prefix app*');
  { both "application" and "apple" start with "appl" }
  CheckQ(db, 'SELECT rowid FROM px WHERE px MATCH ''appl*''', '1,2', 'prefix appl*');
  { notindexed column should not match in the index }
  CheckQ(db, 'SELECT rowid FROM px WHERE px MATCH ''ignored''', '', 'notindexed tag not in index');

  sqlite3_close(db);

  { ---- DIFFERENTIAL: same script through the C oracle (which has FTS4) ---- }
  oracleOut := OracleRun(
    'CREATE VIRTUAL TABLE t USING fts4(content);'
   +'INSERT INTO t(content) VALUES(''hello world'');'
   +'INSERT INTO t(content) VALUES(''goodbye world'');'
   +'INSERT INTO t(content) VALUES(''hello there friend'');'
   +'INSERT INTO t(content) VALUES(''a quick brown fox'');'
   +'SELECT rowid FROM t WHERE t MATCH ''world'';'
   +'SELECT rowid FROM t WHERE t MATCH ''hello OR fox'';'
   +'SELECT rowid FROM t WHERE t MATCH ''"hello world"'';'
   +'SELECT rowid FROM t WHERE t MATCH ''hello NEAR/2 friend'';');
  haveOracle := (oracleOut <> 'ORACLE_ERR') and (oracleOut <> '');
  if haveOracle then begin
    { Build the same result (comma-joined across the 4 queries) from us. }
    db := nil;
    sqlite3_open(':memory:', @db);
    ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(content)', 'diff create');
    PopulateBasic(db);
    mineOut := QueryRowids(db, 'SELECT rowid FROM t WHERE t MATCH ''world''') + ','
             + QueryRowids(db, 'SELECT rowid FROM t WHERE t MATCH ''hello OR fox''') + ','
             + QueryRowids(db, 'SELECT rowid FROM t WHERE t MATCH ''"hello world"''') + ','
             + QueryRowids(db, 'SELECT rowid FROM t WHERE t MATCH ''hello NEAR/2 friend''');
    sqlite3_close(db);
    Check(mineOut = oracleOut,
      'differential parity vs C oracle: mine=[' + mineOut + '] oracle=[' + oracleOut + ']');
  end else
    WriteLn('NOTE: oracle shell not available; differential check skipped.');

  if g_fail = 0 then begin
    WriteLn('TestFts3Vtab: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3Vtab: FAIL (', g_fail, ' checks)');
    Halt(1);
  end;
end.
