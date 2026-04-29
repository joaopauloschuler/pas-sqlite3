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
  DiagLikeGlob — exploratory probe for LIKE / GLOB / NOT LIKE / NOT GLOB /
  ESCAPE / case-sensitivity edges.  Goal: surface bugs not yet captured in
  tasklist.md.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagLikeGlob.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagLikeGlob
}
program DiagLikeGlob;

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
  // --- LIKE: simple wildcards ---
  Probe('like %suffix',     'SELECT ''hello world'' LIKE ''%world''');
  Probe('like prefix%',     'SELECT ''hello world'' LIKE ''hello%''');
  Probe('like %mid%',       'SELECT ''hello world'' LIKE ''%lo wo%''');
  Probe('like _ single',    'SELECT ''cat'' LIKE ''c_t''');
  Probe('like _ no match',  'SELECT ''cart'' LIKE ''c_t''');
  Probe('like multi _',     'SELECT ''abcd'' LIKE ''_b_d''');
  Probe('like literal eq',  'SELECT ''abc'' LIKE ''abc''');
  Probe('like empty pat',   'SELECT ''a'' LIKE ''''');
  Probe('like empty all',   'SELECT '''' LIKE ''''');
  Probe('like empty %',     'SELECT '''' LIKE ''%''');

  // --- LIKE: ASCII case-insensitive (default) ---
  Probe('like ascii ci',    'SELECT ''ABC'' LIKE ''abc''');
  Probe('like ascii ci %',  'SELECT ''ABCdef'' LIKE ''ab%EF''');

  // --- LIKE: NOT LIKE ---
  Probe('not like neg',     'SELECT ''abc'' NOT LIKE ''xyz''');
  Probe('not like pos',     'SELECT ''abc'' NOT LIKE ''abc''');

  // --- LIKE: ESCAPE clause ---
  Probe('like escape pct',  'SELECT ''50%'' LIKE ''50\%'' ESCAPE ''\''');
  Probe('like escape und',  'SELECT ''a_b'' LIKE ''a\_b'' ESCAPE ''\''');
  Probe('like escape no',   'SELECT ''50x'' LIKE ''50\%'' ESCAPE ''\''');
  Probe('like escape esc',  'SELECT ''a\b'' LIKE ''a\\b'' ESCAPE ''\''');

  // --- LIKE: NULL semantics ---
  Probe('like null lhs',    'SELECT NULL LIKE ''abc''');
  Probe('like null rhs',    'SELECT ''abc'' LIKE NULL');
  Probe('like null escape', 'SELECT ''a'' LIKE ''a'' ESCAPE NULL');

  // --- LIKE: typeof ---
  Probe('typeof like',      'SELECT typeof(''abc'' LIKE ''a%'')');
  Probe('typeof like null', 'SELECT typeof(NULL LIKE ''a'')');

  // --- LIKE: numbers (LIKE coerces to TEXT) ---
  Probe('like int->text',   'SELECT 12345 LIKE ''123%''');
  Probe('like real->text',  'SELECT 3.14 LIKE ''3.%''');

  // --- GLOB: simple wildcards ---
  Probe('glob *suffix',     'SELECT ''hello'' GLOB ''*llo''');
  Probe('glob prefix*',     'SELECT ''hello'' GLOB ''he*''');
  Probe('glob ? single',    'SELECT ''cat'' GLOB ''c?t''');
  Probe('glob no match',    'SELECT ''cat'' GLOB ''d?t''');
  Probe('glob literal',     'SELECT ''abc'' GLOB ''abc''');

  // --- GLOB: case sensitivity (GLOB is case-sensitive!) ---
  Probe('glob cs neg',      'SELECT ''ABC'' GLOB ''abc''');
  Probe('glob cs pos',      'SELECT ''abc'' GLOB ''abc''');

  // --- GLOB: character class ---
  Probe('glob class pos',   'SELECT ''a'' GLOB ''[abc]''');
  Probe('glob class neg',   'SELECT ''d'' GLOB ''[abc]''');
  Probe('glob class range', 'SELECT ''m'' GLOB ''[a-z]''');
  Probe('glob class neg2',  'SELECT ''A'' GLOB ''[a-z]''');
  Probe('glob class invert','SELECT ''d'' GLOB ''[^abc]''');
  Probe('glob class invert no','SELECT ''a'' GLOB ''[^abc]''');

  // --- GLOB: NOT GLOB ---
  Probe('not glob neg',     'SELECT ''abc'' NOT GLOB ''xyz''');
  Probe('not glob pos',     'SELECT ''abc'' NOT GLOB ''abc''');

  // --- GLOB: NULL semantics ---
  Probe('glob null lhs',    'SELECT NULL GLOB ''*''');
  Probe('glob null rhs',    'SELECT ''abc'' GLOB NULL');

  // --- like() / glob() function form ---
  Probe('like() func',      'SELECT like(''a%c'',''abc'')');
  Probe('glob() func',      'SELECT glob(''a*c'',''abc'')');
  Probe('like() func esc',  'SELECT like(''a\%c'',''a%c'',''\'')');

  // --- LIKE with literal % and _ via ESCAPE in pattern ---
  Probe('like 100%lit',     'SELECT ''100%'' LIKE ''100\%'' ESCAPE ''\''');
  Probe('like 100abc neg',  'SELECT ''100abc'' LIKE ''100\%'' ESCAPE ''\''');

  // --- Multi-byte (UTF-8) input — LIKE should be case-insensitive only for
  //     ASCII by default; non-ASCII bytes compare by byte ---
  Probe('like utf8 same',   'SELECT ''café'' LIKE ''café''');
  Probe('like utf8 ci asc', 'SELECT ''CAFÉ'' LIKE ''café''');     // É vs é byte-different
  Probe('like utf8 wild',   'SELECT ''café'' LIKE ''ca%''');

  // --- Empty pattern and empty subject ---
  Probe('glob empty pat',   'SELECT ''abc'' GLOB ''''');
  Probe('glob empty all',   'SELECT '''' GLOB ''''');
  Probe('glob empty *',     'SELECT '''' GLOB ''*''');

  // --- LIKE optimization: rowid range conversion gates - "LIKE ''abc%''" ---
  // (Result-set behavior; planner choice not tested here.)
  Probe('like prefix only', 'SELECT ''abcdef'' LIKE ''abc%''');
  Probe('like prefix neg',  'SELECT ''abx''    LIKE ''abc%''');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
