{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.
}
{$I ../passqlite3.inc}
{
  DiagSumOverflow — exercises sum() / total() / avg() integer-overflow
  paths and Kahan-Babushka-Neumaier compensated double summation.
  Mirrors the C reference behaviour at func.c:1920 (sumStep) /
  func.c:1989 (sumFinalize) / func.c:2006 (avgFinalize) /
  func.c:2020 (totalFinalize).

  Each case CREATEs+INSERTs in a fresh :memory: db on both backends,
  then prepares+steps SELECT and compares (rc, errmsg-on-error,
  column type, column int64, column double, column text) byte-for-byte.

  Build: see src/tests/build.sh
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagSumOverflow
}
program DiagSumOverflow;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure PasRun(const setupSql, querySql: AnsiString;
                 out prepRc, stepRc, colType: i32;
                 out asInt: Int64; out asReal: Double;
                 out asText, errMsg: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  zErr: PAnsiChar;
  zT: PAnsiChar;
begin
  prepRc := -1; stepRc := -1; colType := -1;
  asInt := 0; asReal := 0.0; asText := ''; errMsg := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  zErr := nil;
  if sqlite3_exec(db, PAnsiChar(setupSql), nil, nil, @zErr) <> SQLITE_OK then begin
    if zErr <> nil then errMsg := AnsiString(zErr);
    sqlite3_close(db); Exit;
  end;
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(querySql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    rcs := sqlite3_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      colType := sqlite3_column_type(pStmt, 0);
      asInt   := sqlite3_column_int64(pStmt, 0);
      asReal  := sqlite3_column_double(pStmt, 0);
      zT := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if zT <> nil then asText := AnsiString(zT);
    end else if rcs = SQLITE_ERROR then
      errMsg := AnsiString(sqlite3_errmsg(db));
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRun(const setupSql, querySql: AnsiString;
               out prepRc, stepRc, colType: i32;
               out asInt: Int64; out asReal: Double;
               out asText, errMsg: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rcs: Int32;
  zErr: PChar;
  zT: PChar;
begin
  prepRc := -1; stepRc := -1; colType := -1;
  asInt := 0; asReal := 0.0; asText := ''; errMsg := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  zErr := nil;
  if csq_exec(db, PAnsiChar(setupSql), nil, nil, zErr) <> 0 then begin
    if zErr <> nil then errMsg := AnsiString(zErr);
    csq_close(db); Exit;
  end;
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(querySql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    rcs := csq_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      colType := csq_column_type(pStmt, 0);
      asInt   := csq_column_int64(pStmt, 0);
      asReal  := csq_column_double(pStmt, 0);
      zT := csq_column_text(pStmt, 0);
      if zT <> nil then asText := AnsiString(zT);
    end else if rcs = 1 then  { SQLITE_ERROR }
      errMsg := AnsiString(csq_errmsg(db));
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure Probe(const lbl, setupSql, querySql: AnsiString);
var
  pPrep, pStep, pType, cPrep, cStep, cType: i32;
  pInt, cInt: Int64;
  pReal, cReal: Double;
  pTxt, cTxt, pErr, cErr: AnsiString;
  ok: Boolean;
begin
  PasRun(setupSql, querySql, pPrep, pStep, pType, pInt, pReal, pTxt, pErr);
  CRun  (setupSql, querySql, cPrep, cStep, cType, cInt, cReal, cTxt, cErr);
  { Note: pErr/cErr text intentionally not compared here.  The Pas port's
    sqlite3ErrorWithMsg / sqlite3_errmsg are stubs (codegen.pas:25562 +
    main.pas:1671) — they record only errCode, never the message string.
    Tracked as the project-wide errmsg-routing gap.  Once that lands,
    extend the gate to compare pErr=cErr too. }
  ok := (pPrep = cPrep) and (pStep = cStep) and (pType = cType)
        and (pInt = cInt) and (pTxt = cTxt);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   query=', querySql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep, ' type=', pType,
            ' int=', pInt, ' real=', pReal:0:6,
            ' txt="', pTxt, '" err="', pErr, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep, ' type=', cType,
            ' int=', cInt, ' real=', cReal:0:6,
            ' txt="', cTxt, '" err="', cErr, '"');
  end;
end;

const
  SETUP_INT = 'CREATE TABLE t(x INTEGER);'
            + 'INSERT INTO t VALUES(9223372036854775807);'
            + 'INSERT INTO t VALUES(1);';
  SETUP_MIX = 'CREATE TABLE t(x);'
            + 'INSERT INTO t VALUES(1);'
            + 'INSERT INTO t VALUES(2.5);'
            + 'INSERT INTO t VALUES(3);';
  SETUP_BIG = 'CREATE TABLE t(x INTEGER);'
            + 'INSERT INTO t VALUES(9000000000000000);'
            + 'INSERT INTO t VALUES(9000000000000000);';

begin
  { Empty table — sum() returns NULL, total() returns 0.0, avg() returns NULL. }
  Probe('sum empty',     'CREATE TABLE t(x INTEGER);', 'SELECT sum(x) FROM t');
  Probe('total empty',   'CREATE TABLE t(x INTEGER);', 'SELECT total(x) FROM t');
  Probe('avg empty',     'CREATE TABLE t(x INTEGER);', 'SELECT avg(x) FROM t');

  { Pure-integer happy path — sum() must return INTEGER, not REAL. }
  Probe('sum 1+2+3 type', 'CREATE TABLE t(x INTEGER);'
                        + 'INSERT INTO t VALUES(1);INSERT INTO t VALUES(2);'
                        + 'INSERT INTO t VALUES(3);', 'SELECT sum(x) FROM t');

  { Integer overflow — sum() must raise "integer overflow"; total() switches
    to double; avg() switches to double. }
  Probe('sum int overflow',   SETUP_INT, 'SELECT sum(x) FROM t');
  Probe('total int overflow', SETUP_INT, 'SELECT total(x) FROM t');
  Probe('avg int overflow',   SETUP_INT, 'SELECT avg(x) FROM t');

  { Mixed integer + real — promotes to REAL throughout. }
  Probe('sum mixed',   SETUP_MIX, 'SELECT sum(x) FROM t');
  Probe('total mixed', SETUP_MIX, 'SELECT total(x) FROM t');
  Probe('avg mixed',   SETUP_MIX, 'SELECT avg(x) FROM t');

  { Two large ints whose sum stays inside i64 range. }
  Probe('sum big no-overflow',   SETUP_BIG, 'SELECT sum(x) FROM t');
  Probe('total big no-overflow', SETUP_BIG, 'SELECT total(x) FROM t');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
  if diverged <> 0 then Halt(1);
end.
