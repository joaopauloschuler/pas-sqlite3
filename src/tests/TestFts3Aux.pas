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
program TestFts3Aux;

{
  Phase 6.40.1.m — drives the fts4aux virtual table (fts3_aux.c) against a
  populated fts4 table:
    CREATE VIRTUAL TABLE terms USING fts4aux(t);
    SELECT term, documents, occurrences FROM terms WHERE col='*';
    term-range queries (term>='h' AND term<'w'), term='hello' equality,
    multi-column col breakdown.

  Each query's rows are asserted against expected values.  A DIFFERENTIAL
  section shells out to ../sqlite3/sqlite3 (the C oracle, which has fts4aux)
  running the SAME script and byte-compares the output.

  Note: fts4term is the SQLITE_TEST-only sibling module; it is NOT registered
  in this plain engine build (no -dSQLITE_TEST), so it is exercised through
  the Tcl bridge (.o) — here we only cover fts4aux.

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

{ Run a query, joining each row's columns with '|' and rows with ';'. }
function QueryRows(db: PTsqlite3; const zSql: string): string;
var
  pStmt: Pointer;
  rc, i, n: i32;
  z: PAnsiChar;
  row: string;
begin
  Result := '';
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin
    WriteLn('   prepare err: ', sqlite3_errmsg(db), '  sql=', zSql);
    Result := 'ERR'; Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    n := sqlite3_column_count(pStmt);
    row := '';
    for i := 0 to n - 1 do begin
      if i > 0 then row := row + '|';
      z := sqlite3_column_text(pStmt, i);
      if z <> nil then row := row + StrPas(z);
    end;
    if Result <> '' then Result := Result + ';';
    Result := Result + row;
  end;
  sqlite3_finalize(pStmt);
end;

procedure CheckQ(db: PTsqlite3; const zSql, exp, what: string);
var got: string;
begin
  got := QueryRows(db, zSql);
  Check(got = exp, what + ': expected [' + exp + '] got [' + got + ']');
end;

{ Run an SQL script through the C oracle shell and capture stdout, joining
  shell '|'-separated rows by ';' (the shell already uses '|' for columns). }
function OracleRun(const zScript: string): string;
var
  outp: AnsiString;
begin
  outp := '';
  if not RunCommand('../sqlite3/sqlite3', [':memory:', zScript], outp) then begin
    Result := 'ORACLE_ERR'; Exit;
  end;
  outp := StringReplace(Trim(string(outp)), #13, '', [rfReplaceAll]);
  Result := StringReplace(string(outp), #10, ';', [rfReplaceAll]);
end;

procedure PopulateBasic(db: PTsqlite3);
begin
  ExecOK(db, 'INSERT INTO t(content) VALUES(''hello world hello'')', 'ins 1');
  ExecOK(db, 'INSERT INTO t(content) VALUES(''goodbye world'')', 'ins 2');
  ExecOK(db, 'INSERT INTO t(content) VALUES(''hello there friend'')', 'ins 3');
end;

var
  db: PTsqlite3;
  rc: i32;
  oracleOut, mineOut: string;
  haveOracle: Boolean;
  diffScript: string;
begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Check(rc = SQLITE_OK, 'open :memory:');

  { ---- single-column fts4 + fts4aux ---- }
  ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(content)', 'create fts4(content)');
  PopulateBasic(db);
  ExecOK(db, 'CREATE VIRTUAL TABLE terms USING fts4aux(t)', 'create fts4aux(t)');

  { col='*' rows — natural ORDER BY term ASC.  hello appears in docs 1 & 3
    (documents=2) and 3 times total (occurrences=3). }
  CheckQ(db, 'SELECT term, documents, occurrences FROM terms WHERE col=''*''',
    'friend|1|1;goodbye|1|1;hello|2|3;there|1|1;world|2|2',
    'col=* all terms');

  { term range: term>=''h'' AND term<''w'' }
  CheckQ(db,
    'SELECT term, documents, occurrences FROM terms WHERE col=''*'' AND term>=''h'' AND term<''w''',
    'hello|2|3;there|1|1', 'term range [h,w)');

  { term equality (FTS4AUX_EQ_CONSTRAINT path) }
  CheckQ(db, 'SELECT term, documents, occurrences FROM terms WHERE col=''*'' AND term=''hello''',
    'hello|2|3', 'term=hello');

  { lower bound only: term>=''t'' }
  CheckQ(db, 'SELECT term, documents, occurrences FROM terms WHERE col=''*'' AND term>=''t''',
    'there|1|1;world|2|2', 'term>=t');

  { upper bound only: term<''h'' }
  CheckQ(db, 'SELECT term, documents, occurrences FROM terms WHERE col=''*'' AND term<''h''',
    'friend|1|1;goodbye|1|1', 'term<h');

  { ---- multi-column fts4: per-column col breakdown ---- }
  ExecOK(db, 'CREATE VIRTUAL TABLE m USING fts4(a, b)', 'create fts4(a,b)');
  ExecOK(db, 'INSERT INTO m(a,b) VALUES(''foo cat'', ''bar foo'')', 'ins m1');
  ExecOK(db, 'CREATE VIRTUAL TABLE mt USING fts4aux(m)', 'create fts4aux(m)');
  { foo: total (col *) docs=1 occ=2; col 0 docs=1 occ=1; col 1 docs=1 occ=1 }
  CheckQ(db, 'SELECT term, col, documents, occurrences FROM mt WHERE term=''foo''',
    'foo|*|1|2;foo|0|1|1;foo|1|1|1', 'foo per-column breakdown');

  sqlite3_close(db);

  { ---- DIFFERENTIAL: same fts4aux script through the C oracle ---- }
  diffScript :=
     'CREATE VIRTUAL TABLE t USING fts4(content);'
    +'INSERT INTO t(content) VALUES(''hello world hello'');'
    +'INSERT INTO t(content) VALUES(''goodbye world'');'
    +'INSERT INTO t(content) VALUES(''hello there friend'');'
    +'CREATE VIRTUAL TABLE terms USING fts4aux(t);'
    +'SELECT term, documents, occurrences FROM terms WHERE col=''*'';'
    +'SELECT term, documents, occurrences FROM terms WHERE col=''*'' AND term>=''h'' AND term<''w'';'
    +'SELECT term, documents, occurrences FROM terms WHERE col=''*'' AND term=''hello'';';
  oracleOut := OracleRun(diffScript);
  haveOracle := (oracleOut <> 'ORACLE_ERR') and (oracleOut <> '');
  if haveOracle then begin
    db := nil;
    sqlite3_open(':memory:', @db);
    ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(content)', 'diff create');
    PopulateBasic(db);
    ExecOK(db, 'CREATE VIRTUAL TABLE terms USING fts4aux(t)', 'diff create aux');
    mineOut := QueryRows(db, 'SELECT term, documents, occurrences FROM terms WHERE col=''*''') + ';'
             + QueryRows(db, 'SELECT term, documents, occurrences FROM terms WHERE col=''*'' AND term>=''h'' AND term<''w''') + ';'
             + QueryRows(db, 'SELECT term, documents, occurrences FROM terms WHERE col=''*'' AND term=''hello''');
    sqlite3_close(db);
    Check(mineOut = oracleOut,
      'differential parity vs C oracle: mine=[' + mineOut + '] oracle=[' + oracleOut + ']');
  end else
    WriteLn('NOTE: oracle shell not available; differential check skipped.');

  if g_fail = 0 then begin
    WriteLn('TestFts3Aux: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3Aux: FAIL (', g_fail, ' checks)');
    Halt(1);
  end;
end.
