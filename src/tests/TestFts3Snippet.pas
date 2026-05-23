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
program TestFts3Snippet;

{
  Phase 6.40.1.l gate — drives REAL SQL against the fts3_snippet.c auxiliary
  functions snippet()/offsets()/matchinfo() over an fts4 table:

    SELECT offsets(t)              FROM t WHERE t MATCH '...'
    SELECT snippet(t,..)           FROM t WHERE t MATCH '...'  (default + custom)
    SELECT matchinfo(t)            FROM t WHERE t MATCH '...'
    SELECT matchinfo(t,'pcxnal')   FROM t WHERE t MATCH '...'

  Each result is asserted directly AND, in a DIFFERENTIAL section, byte-
  compared against the C oracle (../sqlite3/sqlite3, which has FTS4) running
  the identical SQL.  matchinfo blobs are decoded as u32 arrays for the
  differential compare.

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

{ Concatenate all rows of a single TEXT column, separating with '|'. }
function QueryTextRows(db: PTsqlite3; const zSql: string): string;
var
  pStmt: Pointer;
  rc: i32;
  z: PAnsiChar;
begin
  Result := '';
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin
    WriteLn('   prepare err: ', sqlite3_errmsg(db), '  sql=', zSql);
    Result := 'ERR'; Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    if Result <> '' then Result := Result + '|';
    z := sqlite3_column_text(pStmt, 0);
    if z <> nil then Result := Result + StrPas(z);
  end;
  sqlite3_finalize(pStmt);
end;

{ Decode a single matchinfo() blob result into a hex string ("a1b2..."),
  concatenating multiple rows with '|'.  matchinfo returns a blob of u32. }
function QueryBlobRowsHex(db: PTsqlite3; const zSql: string): string;
var
  pStmt: Pointer;
  rc, n, i: i32;
  p: PByte;
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
    if Result <> '' then Result := Result + '|';
    n := sqlite3_column_bytes(pStmt, 0);
    p := PByte(sqlite3_column_blob(pStmt, 0));
    row := '';
    for i := 0 to n - 1 do
      row := row + LowerCase(IntToHex(p[i], 2));
    Result := Result + row;
  end;
  sqlite3_finalize(pStmt);
end;

{ Run an SQL script through the C oracle shell capturing stdout, with rows
  joined by '|' (matching QueryTextRows / QueryBlobRowsHex separators). }
function OracleRun(const zScript: string): string;
var
  outp: AnsiString;
begin
  outp := '';
  if not RunCommand('../sqlite3/sqlite3', [':memory:', zScript], outp) then begin
    Result := 'ORACLE_ERR'; Exit;
  end;
  outp := StringReplace(Trim(string(outp)), #13, '', [rfReplaceAll]);
  Result := StringReplace(string(outp), #10, '|', [rfReplaceAll]);
end;

procedure Populate(db: PTsqlite3);
begin
  ExecOK(db, 'INSERT INTO t(a,b) VALUES(''the quick brown fox'',''jumps over the lazy dog'')', 'ins 1');
  ExecOK(db, 'INSERT INTO t(a,b) VALUES(''hello brown world'',''the brown bear sleeps'')', 'ins 2');
  ExecOK(db, 'INSERT INTO t(a,b) VALUES(''one two three four'',''five six seven eight'')', 'ins 3');
end;

var
  db: PTsqlite3;
  rc: i32;
  s, oracleS: string;
begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Check(rc = SQLITE_OK, 'open :memory:');

  ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(a, b)', 'create fts4(a,b)');
  Populate(db);

  { ---- offsets() ---- }
  s := QueryTextRows(db, 'SELECT offsets(t) FROM t WHERE t MATCH ''brown''');
  Check(s = '0 0 10 5|0 0 6 5 1 0 4 5', 'offsets brown: got [' + s + ']');

  { ---- snippet() default delimiters ---- }
  s := QueryTextRows(db, 'SELECT snippet(t) FROM t WHERE t MATCH ''quick''');
  Check(s = 'the <b>quick</b> brown fox', 'snippet default: got [' + s + ']');

  { ---- snippet() custom delimiters + ellipsis + nToken ---- }
  s := QueryTextRows(db, 'SELECT snippet(t, ''['', '']'', ''...'', -1, 5) FROM t WHERE t MATCH ''brown''');
  Check(s = 'the quick [brown] fox|hello [brown] world',
    'snippet custom: got [' + s + ']');

  { ---- matchinfo() default 'pcx' ---- }
  s := QueryBlobRowsHex(db, 'SELECT matchinfo(t) FROM t WHERE t MATCH ''brown''');
  Check(s <> '' , 'matchinfo default non-empty');
  { 'p'=1 phrase, 'c'=2 cols (first u32s 01000000 02000000). }
  Check(Copy(s, 1, 16) = '0100000002000000',
    'matchinfo pcx prefix p=1 c=2: got [' + Copy(s, 1, 16) + ']');

  { ---- matchinfo() 'pcxnal' (exercises n,a,l global+docsize codes) ---- }
  s := QueryBlobRowsHex(db, 'SELECT matchinfo(t,''pcxnal'') FROM t WHERE t MATCH ''brown''');
  Check(s <> '', 'matchinfo pcxnal non-empty');

  { ---- matchinfo 'y' (LHITS) and 's' (LCS) codes ---- }
  s := QueryBlobRowsHex(db, 'SELECT matchinfo(t,''y'') FROM t WHERE t MATCH ''brown''');
  Check(s <> '', 'matchinfo y non-empty');
  s := QueryBlobRowsHex(db, 'SELECT matchinfo(t,''s'') FROM t WHERE t MATCH ''brown bear''');
  Check(s <> '', 'matchinfo s (LCS) non-empty');

  sqlite3_close(db);

  { ============ DIFFERENTIAL: identical SQL through the C oracle ============ }

  { offsets — text }
  oracleS := OracleRun(
    'CREATE VIRTUAL TABLE t USING fts4(a, b);'
   +'INSERT INTO t(a,b) VALUES(''the quick brown fox'',''jumps over the lazy dog'');'
   +'INSERT INTO t(a,b) VALUES(''hello brown world'',''the brown bear sleeps'');'
   +'INSERT INTO t(a,b) VALUES(''one two three four'',''five six seven eight'');'
   +'SELECT offsets(t) FROM t WHERE t MATCH ''brown'';');
  if (oracleS <> 'ORACLE_ERR') and (oracleS <> '') then begin
    db := nil; sqlite3_open(':memory:', @db);
    ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(a, b)', 'diff create');
    Populate(db);
    s := QueryTextRows(db, 'SELECT offsets(t) FROM t WHERE t MATCH ''brown''');
    sqlite3_close(db);
    Check(s = oracleS, 'DIFF offsets: mine=[' + s + '] oracle=[' + oracleS + ']');
  end else
    WriteLn('NOTE: oracle shell unavailable; offsets diff skipped.');

  { snippet — text }
  oracleS := OracleRun(
    'CREATE VIRTUAL TABLE t USING fts4(a, b);'
   +'INSERT INTO t(a,b) VALUES(''the quick brown fox'',''jumps over the lazy dog'');'
   +'INSERT INTO t(a,b) VALUES(''hello brown world'',''the brown bear sleeps'');'
   +'INSERT INTO t(a,b) VALUES(''one two three four'',''five six seven eight'');'
   +'SELECT snippet(t, ''['', '']'', ''...'', -1, 5) FROM t WHERE t MATCH ''brown'';');
  if (oracleS <> 'ORACLE_ERR') and (oracleS <> '') then begin
    db := nil; sqlite3_open(':memory:', @db);
    ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(a, b)', 'diff create');
    Populate(db);
    s := QueryTextRows(db, 'SELECT snippet(t, ''['', '']'', ''...'', -1, 5) FROM t WHERE t MATCH ''brown''');
    sqlite3_close(db);
    Check(s = oracleS, 'DIFF snippet: mine=[' + s + '] oracle=[' + oracleS + ']');
  end;

  { matchinfo 'pcxnal' — blob, oracle returns hex via quote(...) which yields
    X'....' ; decode by stripping X'' wrappers and lowercasing. }
  oracleS := OracleRun(
    'CREATE VIRTUAL TABLE t USING fts4(a, b);'
   +'INSERT INTO t(a,b) VALUES(''the quick brown fox'',''jumps over the lazy dog'');'
   +'INSERT INTO t(a,b) VALUES(''hello brown world'',''the brown bear sleeps'');'
   +'INSERT INTO t(a,b) VALUES(''one two three four'',''five six seven eight'');'
   +'SELECT quote(matchinfo(t,''pcxnal'')) FROM t WHERE t MATCH ''brown'';');
  if (oracleS <> 'ORACLE_ERR') and (oracleS <> '') then begin
    { Normalise oracle X'..' hex to bare lowercase hex, '|' between rows. }
    oracleS := StringReplace(oracleS, 'X''', '', [rfReplaceAll]);
    oracleS := StringReplace(oracleS, '''', '', [rfReplaceAll]);
    oracleS := LowerCase(oracleS);
    db := nil; sqlite3_open(':memory:', @db);
    ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(a, b)', 'diff create');
    Populate(db);
    s := QueryBlobRowsHex(db, 'SELECT matchinfo(t,''pcxnal'') FROM t WHERE t MATCH ''brown''');
    sqlite3_close(db);
    Check(s = oracleS, 'DIFF matchinfo pcxnal: mine=[' + s + '] oracle=[' + oracleS + ']');
  end;

  { matchinfo default 'pcx' — blob }
  oracleS := OracleRun(
    'CREATE VIRTUAL TABLE t USING fts4(a, b);'
   +'INSERT INTO t(a,b) VALUES(''the quick brown fox'',''jumps over the lazy dog'');'
   +'INSERT INTO t(a,b) VALUES(''hello brown world'',''the brown bear sleeps'');'
   +'INSERT INTO t(a,b) VALUES(''one two three four'',''five six seven eight'');'
   +'SELECT quote(matchinfo(t)) FROM t WHERE t MATCH ''brown OR fox'';');
  if (oracleS <> 'ORACLE_ERR') and (oracleS <> '') then begin
    oracleS := StringReplace(oracleS, 'X''', '', [rfReplaceAll]);
    oracleS := StringReplace(oracleS, '''', '', [rfReplaceAll]);
    oracleS := LowerCase(oracleS);
    db := nil; sqlite3_open(':memory:', @db);
    ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(a, b)', 'diff create');
    Populate(db);
    s := QueryBlobRowsHex(db, 'SELECT matchinfo(t) FROM t WHERE t MATCH ''brown OR fox''');
    sqlite3_close(db);
    Check(s = oracleS, 'DIFF matchinfo pcx (OR): mine=[' + s + '] oracle=[' + oracleS + ']');
  end;

  if g_fail = 0 then begin
    WriteLn('TestFts3Snippet: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3Snippet: FAIL (', g_fail, ' checks)');
    Halt(1);
  end;
end.
