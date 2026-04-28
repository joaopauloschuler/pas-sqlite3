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
  DiagMultiValues — runtime probe for the multi-row VALUES gap
  (tasklist 6.10 step 6).  sqlite3MultiValues is a stub that drops
  every row past the first.  Verify the runtime symptom: does
  INSERT INTO t VALUES(1,2),(3,4),(5,6) silently insert only one
  row, error out, or crash?  Compare against the C reference via
  csqlite3 in the same process.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagMultiValues.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagMultiValues
}
program DiagMultiValues;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

procedure RunSql(db: PTsqlite3; const sql: AnsiString);
var
  pStmt: PVdbe;
  rcs: i32;
begin
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
end;

procedure RunPas(const sql: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcOut, rcs: i32;
begin
  db := nil;
  rcOut := sqlite3_open(':memory:', @db);
  if rcOut <> 0 then begin WriteLn('  Pas open rc=', rcOut); Exit; end;
  RunSql(db, 'CREATE TABLE t(a,b)');
  pStmt := nil;
  rcOut := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  WriteLn('  Pas prepare rc=', rcOut);
  if pStmt <> nil then begin
    rcs := sqlite3_step(pStmt);
    while rcs = SQLITE_ROW do rcs := sqlite3_step(pStmt);
    WriteLn('  Pas step rc=', rcs);
    sqlite3_finalize(pStmt);
  end;
  pStmt := nil;
  if (sqlite3_prepare_v2(db, 'SELECT COUNT(*) FROM t', -1, @pStmt, nil) = 0)
    and (pStmt <> nil) then begin
    if sqlite3_step(pStmt) = SQLITE_ROW then
      WriteLn('  Pas count = ', sqlite3_column_int(pStmt, 0));
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure RunC(const sql: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  pErr: PChar;
  rcs: Int32;
begin
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pErr := nil;
  csq_exec(db, 'CREATE TABLE t(a,b)', nil, nil, pErr);
  pStmt := nil; pTail := nil;
  rcs := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  WriteLn('  C   prepare rc=', rcs);
  if pStmt <> nil then begin
    rcs := csq_step(pStmt);
    while rcs = SQLITE_ROW do rcs := csq_step(pStmt);
    WriteLn('  C   step rc=', rcs);
    csq_finalize(pStmt);
  end;
  pStmt := nil; pTail := nil;
  if (csq_prepare_v2(db, 'SELECT COUNT(*) FROM t', -1, pStmt, pTail) = 0)
    and (pStmt <> nil) then begin
    if csq_step(pStmt) = SQLITE_ROW then
      WriteLn('  C   count = ', csq_column_int(pStmt, 0));
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

const
  SQL = 'INSERT INTO t VALUES(1,2),(3,4),(5,6)';
begin
  WriteLn('--- ', SQL);
  WriteLn('Pascal:');
  RunPas(SQL);
  WriteLn('C reference:');
  RunC(SQL);
end.
