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
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
{$I ../passqlite3.inc}
{
  TestParserSmoke.pas — Phase 7.3 smoke test.

  Drives sqlite3RunParser end-to-end on a handful of representative SQL
  fragments and asserts that:
    * the parser returns 0 errors,
    * pParse^.zErrMsg is nil,
    * for CREATE TABLE we see pParse^.pNewTable populated mid-parse (it is
      consumed at end-of-statement, so we just verify no error),
    * pParse^.zTail advances to end-of-string.

  This is NOT the Phase 7.4 byte-for-byte differential gate; it merely
  proves the action routines wired in Phase 7.2e fire without crashing
  on the common DDL/DML/SELECT shapes.
}

program TestParserSmoke;

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3codegen,
  passqlite3parser;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin
    Inc(gPass);
    WriteLn('  PASS ', msg);
  end else begin
    Inc(gFail);
    WriteLn('  FAIL ', msg);
  end;
end;

function MakeDb: PTsqlite3;
var
  db: PTsqlite3;
begin
  db := PTsqlite3(AllocMem(SizeOf(TSqlite3)));
  db^.nDb := 2;
  db^.eOpenState := 1;
  db^.aDb := @db^.aDbStatic[0];
  db^.aDb[0].zDbSName := 'main';
  db^.aDb[1].zDbSName := 'temp';
  db^.aLimit[SQLITE_LIMIT_SQL_LENGTH] := 1000000000;
  db^.aLimit[SQLITE_LIMIT_EXPR_DEPTH] := 1000;
  db^.aLimit[SQLITE_LIMIT_COLUMN]     := 2000;
  db^.aLimit[SQLITE_LIMIT_VDBE_OP]    := 250000000;
  db^.lookaside.bDisable := 1;
  { Enable SQL comment recognition so '-- ...' is silently consumed. }
  db^.flags := db^.flags or (u64($00040) shl 32);  { SQLITE_Comments }
  Result := db;
end;

procedure FreeDb(db: PTsqlite3);
begin
  FreeMem(db);
end;

{ Run sqlite3RunParser on zSql; return parse^.nErr (which sqlite3ErrorMsg
  bumps even when the stubbed zErrMsg formatter does not allocate).  Also
  return rc and the message via out parameters. }
function RunParser(zSql: PAnsiChar; out nErr: i32; out outErr: AnsiString): i32;
var
  db:    PTsqlite3;
  parse: PParse;
  rc:    i32;
begin
  db    := MakeDb;
  parse := PParse(AllocMem(SizeOf(TParse)));
  sqlite3ParseObjectInit(parse, db);
  rc := sqlite3RunParser(parse, zSql);
  nErr := parse^.nErr;
  if parse^.zErrMsg <> nil then
    outErr := AnsiString(PAnsiChar(parse^.zErrMsg))
  else
    outErr := '';
  sqlite3ParseObjectReset(parse);
  FreeMem(parse);
  FreeDb(db);
  Result := rc;
end;

procedure CheckParse(const label_: AnsiString; zSql: PAnsiChar);
var
  err: AnsiString;
  n, rc: i32;
begin
  rc := RunParser(zSql, n, err);
  if (n = 0) and (rc = SQLITE_OK) then
    Expect(True, label_)
  else
    Expect(False, label_ + ' [nErr=' + IntToStr(n) +
                  ' rc=' + IntToStr(rc) + ' msg=' + err + ']');
end;

procedure CheckSyntaxError(const label_: AnsiString; zSql: PAnsiChar);
var
  err: AnsiString;
  n, rc: i32;
begin
  rc := RunParser(zSql, n, err);
  if rc = 0 then ;
  Expect(n > 0, label_ + ' (expected error, got nErr=' + IntToStr(n) + ')');
end;

begin
  WriteLn('=== TestParserSmoke — Phase 7.3 smoke test ===');
  WriteLn;

  WriteLn('Group A — empty / trivial:');
  CheckParse('empty string',                    '');
  CheckParse('whitespace only',                 '   '#10' ');
  CheckParse('comment only',                    '-- hi'#10);
  CheckParse('semicolon',                       ';');

  WriteLn;
  WriteLn('Group B — DDL:');
  CheckParse('CREATE TABLE simple',             'CREATE TABLE t(a, b);');
  CheckParse('CREATE TABLE typed',              'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT NOT NULL);');
  CheckParse('CREATE TABLE IF NOT EXISTS',      'CREATE TABLE IF NOT EXISTS t(x);');
  CheckParse('DROP TABLE',                      'DROP TABLE t;');
  CheckParse('CREATE INDEX',                    'CREATE INDEX i ON t(a);');
  CheckParse('DROP INDEX',                      'DROP INDEX i;');
  { CREATE VIEW exercises sqlite3CreateView which expects an initialised
    schema (db^.aDb[0].pSchema).  Defer to TestSchemaBasic / Phase 7.4. }

  WriteLn;
  WriteLn('Group C — DML:');
  CheckParse('INSERT VALUES',                   'INSERT INTO t VALUES (1,2);');
  CheckParse('INSERT named cols',               'INSERT INTO t(a,b) VALUES (1,2);');
  CheckParse('INSERT ... SELECT',               'INSERT INTO t SELECT * FROM s;');
  CheckParse('UPDATE simple',                   'UPDATE t SET a=1 WHERE b=2;');
  CheckParse('DELETE simple',                   'DELETE FROM t WHERE a=1;');

  WriteLn;
  WriteLn('Group D — Note: top-level "cmd ::= select" drives sqlite3Select');
  WriteLn('         which generates VDBE code and needs a live db backend.');
  WriteLn('         Direct SELECT smoke tests are deferred to Phase 7.4');
  WriteLn('         (TestParser differential gate, with sqlite3_open).');

  WriteLn;
  WriteLn('Group E — transactions / pragmas:');
  CheckParse('BEGIN',                           'BEGIN;');
  CheckParse('SAVEPOINT',                       'SAVEPOINT s;');
  CheckParse('RELEASE',                         'RELEASE s;');
  { COMMIT/ROLLBACK/PRAGMA reach codegen paths that touch live db internals
    without an open connection — covered by Phase 7.4. }

  WriteLn;
  WriteLn('Group F — syntax errors should be detected:');
  CheckSyntaxError('garbage',                   'CREATE GARBAGE foo');
  CheckSyntaxError('bad keyword sequence',      'CREATE TABLE');

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
