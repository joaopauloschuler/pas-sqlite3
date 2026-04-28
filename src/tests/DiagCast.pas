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
  DiagCast — exploratory probe for CAST expressions and type-affinity
  coercion edges.  Goal: surface bugs not yet captured in tasklist.md.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagCast.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagCast
}
program DiagCast;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure PasRun1(const sql: AnsiString; out prepRc, stepRc: i32;
                  out asInt: Int64; out asText: AnsiString;
                  out colType: i32);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  zT: PAnsiChar;
begin
  prepRc := -1; stepRc := -1; asInt := 0; asText := ''; colType := -1;
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    rcs := sqlite3_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      colType := sqlite3_column_type(pStmt, 0);
      asInt := sqlite3_column_int64(pStmt, 0);
      zT := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if zT <> nil then asText := AnsiString(zT);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRun1(const sql: AnsiString; out prepRc, stepRc: i32;
                out asInt: Int64; out asText: AnsiString;
                out colType: i32);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rcs: Int32;
  zT: PChar;
begin
  prepRc := -1; stepRc := -1; asInt := 0; asText := ''; colType := -1;
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    rcs := csq_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      colType := csq_column_type(pStmt, 0);
      asInt := csq_column_int64(pStmt, 0);
      zT := csq_column_text(pStmt, 0);
      if zT <> nil then asText := AnsiString(zT);
    end;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure Probe(const lbl, sql: AnsiString);
var
  pPrep, pStep, pType, cPrep, cStep, cType: i32;
  pInt, cInt: Int64;
  pTxt, cTxt: AnsiString;
  ok: Boolean;
begin
  PasRun1(sql, pPrep, pStep, pInt, pTxt, pType);
  CRun1  (sql, cPrep, cStep, cInt, cTxt, cType);
  ok := (pPrep = cPrep) and (pStep = cStep) and (pType = cType)
        and (pInt = cInt) and (pTxt = cTxt);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql  =', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep,
            ' type=', pType, ' int=', pInt, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep,
            ' type=', cType, ' int=', cInt, ' txt="', cTxt, '"');
  end;
end;

begin
  // --- CAST AS INTEGER ---
  Probe('cast text->int',    'SELECT CAST(''42'' AS INTEGER)');
  Probe('cast text->int neg','SELECT CAST(''-17'' AS INTEGER)');
  Probe('cast text->int trail','SELECT CAST(''42abc'' AS INTEGER)');
  Probe('cast text->int empty','SELECT CAST('''' AS INTEGER)');
  Probe('cast text->int hex', 'SELECT CAST(''0x10'' AS INTEGER)');
  Probe('cast real->int',     'SELECT CAST(3.7 AS INTEGER)');
  Probe('cast real->int neg', 'SELECT CAST(-3.7 AS INTEGER)');
  Probe('cast real->int huge','SELECT CAST(9.0e18 AS INTEGER)');
  Probe('cast null->int',     'SELECT CAST(NULL AS INTEGER)');

  // --- CAST AS TEXT ---
  Probe('cast int->text',     'SELECT CAST(42 AS TEXT)');
  Probe('cast real->text',    'SELECT CAST(3.5 AS TEXT)');
  Probe('cast null->text',    'SELECT CAST(NULL AS TEXT)');
  Probe('cast blob->text',    'SELECT CAST(X''4142'' AS TEXT)');

  // --- CAST AS REAL ---
  Probe('cast int->real',     'SELECT CAST(7 AS REAL)');
  Probe('cast text->real',    'SELECT CAST(''3.14'' AS REAL)');
  Probe('cast text->real bad','SELECT CAST(''abc'' AS REAL)');
  Probe('cast null->real',    'SELECT CAST(NULL AS REAL)');

  // --- CAST AS NUMERIC ---
  Probe('cast text num int',  'SELECT CAST(''42'' AS NUMERIC)');
  Probe('cast text num real', 'SELECT CAST(''3.14'' AS NUMERIC)');
  Probe('cast text num bad',  'SELECT CAST(''hi'' AS NUMERIC)');

  // --- CAST AS BLOB ---
  Probe('cast text->blob',    'SELECT length(CAST(''abc'' AS BLOB))');
  Probe('cast int->blob len', 'SELECT length(CAST(42 AS BLOB))');
  Probe('cast typeof blob',   'SELECT typeof(CAST(''hi'' AS BLOB))');

  // --- typeof on CAST ---
  Probe('typeof cast int',    'SELECT typeof(CAST(''3'' AS INTEGER))');
  Probe('typeof cast real',   'SELECT typeof(CAST(3 AS REAL))');
  Probe('typeof cast text',   'SELECT typeof(CAST(3.0 AS TEXT))');
  Probe('typeof cast num int','SELECT typeof(CAST(''3'' AS NUMERIC))');
  Probe('typeof cast num real','SELECT typeof(CAST(''3.5'' AS NUMERIC))');

  // --- arithmetic coercion ---
  Probe('text + int',         'SELECT ''3''+4');
  Probe('text * int',         'SELECT ''2''*3');
  Probe('null + int',         'SELECT NULL+1');
  Probe('int / 0',            'SELECT 5/0');
  Probe('real / 0',           'SELECT 5.0/0.0');
  Probe('mod neg',            'SELECT -7%3');
  Probe('div neg',            'SELECT -7/3');
  Probe('large int overflow', 'SELECT 9223372036854775807+1');

  // --- comparison coercion ---
  Probe('text=int',           'SELECT ''1''=1');
  Probe('text<int',           'SELECT ''9''<10');
  Probe('null=null',          'SELECT NULL=NULL');
  Probe('null IS null',       'SELECT NULL IS NULL');

  // --- abs / + - unary ---
  Probe('abs neg int',        'SELECT abs(-5)');
  Probe('abs neg real',       'SELECT abs(-3.5)');
  Probe('abs text',           'SELECT abs(''3.5'')');
  Probe('abs null',           'SELECT abs(NULL)');
  Probe('abs INT_MIN',        'SELECT abs(-9223372036854775808)');

  // --- coalesce / ifnull / nullif ---
  Probe('coalesce 1',         'SELECT coalesce(NULL,NULL,3,4)');
  Probe('ifnull null',        'SELECT ifnull(NULL,7)');
  Probe('ifnull val',         'SELECT ifnull(2,7)');
  Probe('nullif eq',          'SELECT nullif(3,3)');
  Probe('nullif neq',         'SELECT nullif(3,4)');

  // --- iif / case ---
  Probe('iif true',           'SELECT iif(1,''a'',''b'')');
  Probe('iif false',          'SELECT iif(0,''a'',''b'')');
  Probe('case simple',        'SELECT CASE 2 WHEN 1 THEN ''x'' WHEN 2 THEN ''y'' ELSE ''z'' END');
  Probe('case search',        'SELECT CASE WHEN 1>2 THEN ''a'' ELSE ''b'' END');
  Probe('case null else',     'SELECT CASE WHEN 0 THEN ''a'' END');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
