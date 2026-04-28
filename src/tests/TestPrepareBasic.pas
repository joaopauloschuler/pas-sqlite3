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
program TestPrepareBasic;

{
  Phase 8.2 gate — exercise the Pascal sqlite3_prepare / _v2 / _v3 wiring.

  Scope note: in this Phase 8.2 cut, the prepare entry points wire
  open-database -> parser -> codegen end-to-end, but several top-level
  codegen entry points (notably sqlite3Select, sqlite3FinishTable,
  sqlite3PragmaParse, sqlite3BeginTransaction) are still Phase 6/7
  stubs that do not actually emit a Vdbe.  As a result, valid SQL
  statements typically return rc=SQLITE_OK with ppStmt=nil — exactly
  the same surface behaviour that SQLite's C reference exhibits when
  given an empty statement.  The byte-for-byte VDBE diff is gated on
  Phase 6.x completion (TestParser comment), not Phase 8.2.

  Coverage:
    T1  prepare_v2(empty / blank text)        — rc=OK, ppStmt=nil
    T2  prepare_v2(';' lone semicolon)        — rc=OK, ppStmt=nil
    T3  prepare_v2(syntax-error SQL)          — rc=SQLITE_ERROR, ppStmt=nil
    T4  prepare_v2(db=nil)                    — rc=SQLITE_MISUSE, ppStmt=nil
    T5  prepare_v2(zSql=nil)                  — rc=SQLITE_MISUSE, ppStmt=nil
    T6  prepare_v2(ppStmt=nil)                — rc=SQLITE_MISUSE
    T7  prepare_v2 advances pzTail to end of buffer when nBytes=-1
    T8  prepare_v2 with explicit nBytes copies SQL into a NUL-terminated
        scratch (long-statement path) and translates pzTail back into
        the caller's buffer
    T9  prepare_v3(prepFlags=0) is identical to prepare_v2
    T10 prepare_v2 with two trailing statements: pzTail points past the
        first ';' so a caller can iterate
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

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

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

var
  db:    PTsqlite3;
  pStmt: Pointer;
  pTail: PAnsiChar;
  rc:    i32;
  buf:   array[0..31] of AnsiChar;

const
  SQL_SEMI : PAnsiChar = ';';
  SQL_BAD  : PAnsiChar = 'SELEKT 1';
  SQL_TWO  : PAnsiChar = 'CREATE TABLE a(x); CREATE TABLE b(y);';
  SQL_ONE  : PAnsiChar = 'CREATE TABLE z(x)';

begin
  gPass := 0; gFail := 0;
  WriteLn('TestPrepareBasic — Phase 8.2 sqlite3_prepare family');

  db := nil;
  rc := sqlite3_open(':memory:', @db);
  ExpectEq(rc, SQLITE_OK, 'open(:memory:)');
  if (rc <> SQLITE_OK) or (db = nil) then begin
    WriteLn('  open failed — aborting'); Halt(1);
  end;

  { T1 — blank text. }
  pStmt := Pointer(PtrUInt($DEAD));
  pTail := nil;
  rc := sqlite3_prepare_v2(db, '   ', -1, @pStmt, @pTail);
  ExpectEq(rc, SQLITE_OK, 'T1 prepare_v2(blank) rc');
  Expect(pStmt = nil,     'T1 ppStmt nil for blank text');

  { T2 — lone ';'. }
  pStmt := Pointer(PtrUInt($DEAD));
  rc := sqlite3_prepare_v2(db, SQL_SEMI, -1, @pStmt, nil);
  ExpectEq(rc, SQLITE_OK, 'T2 prepare_v2(;) rc');
  Expect(pStmt = nil,     'T2 ppStmt nil for ;');

  { T3 — syntax error. }
  pStmt := Pointer(PtrUInt($DEAD));
  rc := sqlite3_prepare_v2(db, SQL_BAD, -1, @pStmt, nil);
  Expect(rc <> SQLITE_OK, 'T3 prepare_v2(SELEKT 1) returns non-OK');
  Expect(pStmt = nil,     'T3 ppStmt nil on parse error');

  { T4 — db=nil. }
  pStmt := Pointer(PtrUInt($DEAD));
  rc := sqlite3_prepare_v2(nil, SQL_ONE, -1, @pStmt, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T4 prepare_v2(db=nil)');
  Expect(pStmt = nil,         'T4 ppStmt cleared');

  { T5 — zSql=nil. }
  pStmt := Pointer(PtrUInt($DEAD));
  rc := sqlite3_prepare_v2(db, nil, -1, @pStmt, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T5 prepare_v2(zSql=nil)');
  Expect(pStmt = nil,         'T5 ppStmt cleared');

  { T6 — ppStmt=nil. }
  rc := sqlite3_prepare_v2(db, SQL_ONE, -1, nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T6 prepare_v2(ppStmt=nil)');

  { T7 — pzTail at end-of-string when nBytes=-1. }
  pStmt := nil; pTail := nil;
  rc := sqlite3_prepare_v2(db, SQL_ONE, -1, @pStmt, @pTail);
  ExpectEq(rc, SQLITE_OK, 'T7 prepare_v2(CREATE) rc');
  Expect((pTail <> nil) and (pTail[0] = #0), 'T7 pzTail at NUL');
  if pStmt <> nil then sqlite3_finalize(pStmt);

  { T8 — explicit nBytes path: copy buffer, translate zTail. }
  Move(SQL_ONE^, buf, 17);  { 'CREATE TABLE z(x)' = 17 chars, no NUL }
  pStmt := nil; pTail := nil;
  rc := sqlite3_prepare_v2(db, @buf[0], 17, @pStmt, @pTail);
  ExpectEq(rc, SQLITE_OK, 'T8 prepare_v2(explicit nBytes) rc');
  Expect((pTail >= @buf[0]) and (pTail <= @buf[17]),
         'T8 pzTail lies inside caller buffer');
  if pStmt <> nil then sqlite3_finalize(pStmt);

  { T9 — prepare_v3 with prepFlags=0. }
  pStmt := nil;
  rc := sqlite3_prepare_v3(db, SQL_ONE, -1, 0, @pStmt, nil);
  ExpectEq(rc, SQLITE_OK, 'T9 prepare_v3(prepFlags=0) rc');
  if pStmt <> nil then sqlite3_finalize(pStmt);

  { T10 — multi-statement: pzTail past first ';'. }
  pStmt := nil; pTail := nil;
  rc := sqlite3_prepare_v2(db, SQL_TWO, -1, @pStmt, @pTail);
  ExpectEq(rc, SQLITE_OK, 'T10 prepare_v2(two CREATE) rc');
  Expect(pTail > SQL_TWO, 'T10 pzTail advanced past first stmt');
  if pStmt <> nil then sqlite3_finalize(pStmt);

  ExpectEq(sqlite3_close(db), SQLITE_OK, 'close');

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed.');
  if gFail = 0 then Halt(0) else Halt(1);
end.
