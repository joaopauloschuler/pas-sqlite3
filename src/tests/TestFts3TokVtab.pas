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
program TestFts3TokVtab;

{
  Phase 6.40.1.h gate — the "fts3tokenize" virtual-table module
  (fts3_tokenize_vtab.c), registered from the minimal sqlite3Fts3Init hook.

  Opening a :memory: connection now installs the fts3tokenize module.  A
  CREATE VIRTUAL TABLE ... USING fts3tokenize(<tok>) table, when queried
  with `WHERE input = <string>`, returns one row per token produced by the
  named FTS3 tokenizer, with the columns

      CREATE TABLE x(input, token, start, end, position)

  Asserts (all values derived from the simple/porter tokenizer behaviour):

    1.  fts3tokenize('simple') over 'This is a test sentence' yields the
        5 lowercased tokens with their byte offsets and positions.
    2.  fts3tokenize() with no argument defaults to 'simple' (identical
        output).
    3.  fts3tokenize('porter') over 'running runs' yields the porter-stemmed
        tokens ('run','run') while start/end offsets track the input.
    4.  the `input` column echoes the query string.

  Exit 0 = PASS.  No oracle build needed; the assertions are intrinsic.
}

uses
  ctypes,
  SysUtils,
  StrUtils,
  Strings,
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

{ Run a tokenize query over `zInput` against virtual table `zTab` and
  verify the produced rows match the four parallel expected arrays. }
procedure CheckTokens(db: PTsqlite3; const zSql: string; const zInput: string;
  const expTok: array of string; const expStart: array of Integer;
  const expEnd: array of Integer; const expPos: array of Integer;
  const what: string);
var
  pStmt: Pointer;
  rc: i32;
  i: Integer;
  zCol1: PAnsiChar;
begin
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  Check(rc = SQLITE_OK, what + ': prepare');
  if rc <> SQLITE_OK then begin
    WriteLn('   prepare err: ', sqlite3_errmsg(db));
    Exit;
  end;

  i := 0;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    if i < Length(expTok) then begin
      { columns: input, token, start, end, position }
      zCol1 := sqlite3_column_text(pStmt, 0);
      Check(StrComp(zCol1, PAnsiChar(zInput)) = 0,
        what + ': row ' + IntToStr(i) + ' input echoes query string');
      Check(StrComp(sqlite3_column_text(pStmt, 1), PAnsiChar(expTok[i])) = 0,
        what + ': row ' + IntToStr(i) + ' token = "' + expTok[i] + '" got "'
          + StrPas(sqlite3_column_text(pStmt, 1)) + '"');
      Check(sqlite3_column_int(pStmt, 2) = expStart[i],
        what + ': row ' + IntToStr(i) + ' start = ' + IntToStr(expStart[i]));
      Check(sqlite3_column_int(pStmt, 3) = expEnd[i],
        what + ': row ' + IntToStr(i) + ' end = ' + IntToStr(expEnd[i]));
      Check(sqlite3_column_int(pStmt, 4) = expPos[i],
        what + ': row ' + IntToStr(i) + ' position = ' + IntToStr(expPos[i]));
    end;
    Inc(i);
  end;
  Check(i = Length(expTok),
    what + ': produced ' + IntToStr(i) + ' rows, expected '
      + IntToStr(Length(expTok)));
  sqlite3_finalize(pStmt);
end;

var
  db: PTsqlite3;
  rc: i32;
  inp: string;
begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Check(rc = SQLITE_OK, 'open :memory:');

  { 1 — explicit 'simple' tokenizer. }
  ExecOK(db, 'CREATE VIRTUAL TABLE t1 USING fts3tokenize(''simple'')',
    'create fts3tokenize(simple)');
  inp := 'This is a test sentence';
  CheckTokens(db,
    'SELECT input, token, start, end, position FROM t1 '
      + 'WHERE input = ''This is a test sentence''',
    inp,
    ['this', 'is', 'a', 'test', 'sentence'],
    [0, 5, 8, 10, 15],
    [4, 7, 9, 14, 23],
    [0, 1, 2, 3, 4],
    'simple');

  { 2 — no-argument form defaults to 'simple'. }
  ExecOK(db, 'CREATE VIRTUAL TABLE t2 USING fts3tokenize()',
    'create fts3tokenize() default');
  CheckTokens(db,
    'SELECT input, token, start, end, position FROM t2 '
      + 'WHERE input = ''This is a test sentence''',
    inp,
    ['this', 'is', 'a', 'test', 'sentence'],
    [0, 5, 8, 10, 15],
    [4, 7, 9, 14, 23],
    [0, 1, 2, 3, 4],
    'default-simple');

  { 3 — porter stemmer.  'running' -> 'run', 'runs' -> 'run'.
    The simple-stage tokenization gives the same byte offsets/positions; the
    porter stage stems the token text. }
  ExecOK(db, 'CREATE VIRTUAL TABLE t3 USING fts3tokenize(''porter'')',
    'create fts3tokenize(porter)');
  inp := 'running runs';
  CheckTokens(db,
    'SELECT input, token, start, end, position FROM t3 '
      + 'WHERE input = ''running runs''',
    inp,
    ['run', 'run'],
    [0, 8],
    [7, 12],
    [0, 1],
    'porter');

  sqlite3_close(db);

  if g_fail = 0 then begin
    WriteLn('TestFts3TokVtab: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3TokVtab: FAIL (', g_fail, ' assertions)');
    Halt(1);
  end;
end.
