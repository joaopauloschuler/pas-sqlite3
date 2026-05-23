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
program TestFts3TokRegistry;

{
  Phase 6.40.1.g gate — the generic tokenizer registry (fts3_tokenizer.c)
  plus the minimal sqlite3Fts3Init wiring hook (down-payment on 6.40.1.o).

  Asserts that opening a :memory: connection now installs the
  `fts3_tokenizer` SQL function backed by a per-connection hash preloaded
  with the simple/porter/unicode61 built-ins, and that
  sqlite3Fts3InitTokenizer resolves a name against that same hash.

    1.  SELECT fts3_tokenizer('simple')  returns an 8-byte blob (the
        module pointer); SELECT fts3_tokenizer('nosuchtokenizer') errors
        with "unknown tokenizer: nosuchtokenizer".
    2.  sqlite3Fts3InitTokenizer(<hash>, 'simple', ...) resolves to the
        same module sqlite3Fts3SimpleTokenizerModule() reports, and
        'nosuchtokenizer' returns SQLITE_ERROR + a malloced message.

  Exit 0 = PASS.  No oracle build needed; the assertions are intrinsic.
}

uses
  ctypes,
  SysUtils,
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

{ Open a :memory: db and verify the fts3_tokenizer SQL function is live. }
procedure TestSqlFunction;
var
  db:    PTsqlite3;
  pStmt: Pointer;
  rc:    i32;
begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Check(rc = SQLITE_OK, 'open :memory:');

  { With SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER on, a single-arg lookup with
    a *literal* name returns the module pointer as a blob (when off, a
    literal name yields NULL — see fts3_tokenizer.c:109). }
  rc := sqlite3_db_config_int(db, SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER, 1, nil);
  Check(rc = SQLITE_OK, 'enable ENABLE_FTS3_TOKENIZER');

  { Single-arg lookup of a built-in tokenizer returns an 8-byte blob. }
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT fts3_tokenizer(''simple'')', -1,
          @pStmt, nil);
  Check(rc = SQLITE_OK, 'prepare fts3_tokenizer(simple)');
  if rc = SQLITE_OK then begin
    Check(sqlite3_step(pStmt) = SQLITE_ROW, 'step returns a row');
    Check(sqlite3_column_type(pStmt, 0) = SQLITE_BLOB, 'result is a blob');
    Check(sqlite3_column_bytes(pStmt, 0) = i32(SizeOf(Pointer)),
      'blob is one pointer wide');
    sqlite3_finalize(pStmt);
  end;

  { Unknown tokenizer name errors out. }
  pStmt := nil;
  rc := sqlite3_prepare_v2(db,
          'SELECT fts3_tokenizer(''nosuchtokenizer'')', -1, @pStmt, nil);
  Check(rc = SQLITE_OK, 'prepare fts3_tokenizer(nosuchtokenizer)');
  if rc = SQLITE_OK then begin
    Check(sqlite3_step(pStmt) = SQLITE_ERROR, 'unknown tokenizer step errors');
    Check(StrComp(sqlite3_errmsg(db),
      'unknown tokenizer: nosuchtokenizer') = 0,
      'errmsg is "unknown tokenizer: nosuchtokenizer"');
    sqlite3_finalize(pStmt);
  end;

  sqlite3_close(db);
end;

{ Drive sqlite3Fts3InitTokenizer directly against a freshly-loaded hash. }
procedure TestInitTokenizer;
var
  hash:    TFts3Hash;
  pSimple: Psqlite3_tokenizer_module;
  pTok:    Psqlite3_tokenizer;
  zErr:    PChar;
  rc:      cint;
begin
  pSimple := nil;
  sqlite3Fts3SimpleTokenizerModule(@pSimple);

  sqlite3Fts3HashInit(@hash, FTS3_HASH_STRING, 1);
  sqlite3Fts3HashInsert(@hash, PChar('simple'), 7, pSimple);

  { Resolve "simple" -> a tokenizer whose module is the simple module. }
  pTok := nil;
  zErr := nil;
  rc := sqlite3Fts3InitTokenizer(@hash, 'simple', @pTok, @zErr);
  Check(rc = SQLITE_OK, 'InitTokenizer(simple) returns SQLITE_OK');
  Check(pTok <> nil, 'InitTokenizer(simple) sets *ppTok');
  if pTok <> nil then begin
    Check(pTok^.pModule = pSimple, 'tokenizer module is the simple module');
    pSimple^.xDestroy(pTok);
  end;

  { Resolve an unknown name -> SQLITE_ERROR + a malloced message. }
  pTok := nil;
  zErr := nil;
  rc := sqlite3Fts3InitTokenizer(@hash, 'nosuchtokenizer', @pTok, @zErr);
  Check(rc = SQLITE_ERROR, 'InitTokenizer(nosuchtokenizer) returns SQLITE_ERROR');
  Check(zErr <> nil, 'InitTokenizer(nosuchtokenizer) sets *pzErr');
  if zErr <> nil then begin
    Check(StrComp(zErr, 'unknown tokenizer: nosuchtokenizer') = 0,
      'pzErr is "unknown tokenizer: nosuchtokenizer"');
    sqlite3_free(zErr);
  end;

  sqlite3Fts3HashClear(@hash);
end;

begin
  TestSqlFunction;
  TestInitTokenizer;
  if g_fail = 0 then begin
    WriteLn('TestFts3TokRegistry: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3TokRegistry: FAIL (', g_fail, ' assertions)');
    Halt(1);
  end;
end.
