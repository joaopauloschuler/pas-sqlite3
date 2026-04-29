{
  SPDX-License-Identifier: blessing

  DiagPrintfFmt — exploratory probe for SQL printf() format-specifier
  edge cases not covered by DiagFunctions / TestPrintf.  Goal: surface
  any divergence between the Pas port and the C reference for less-
  common conversions, width/precision, flags, and signed/unsigned arms.

  Build by adding to src/tests/build.sh; run with
    LD_LIBRARY_PATH=$PWD/src bin/DiagPrintfFmt
}
{$I ../passqlite3.inc}

program DiagPrintfFmt;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure PasRun1(const sql: AnsiString; out prepRc, stepRc: i32;
                  out asText: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  zT: PAnsiChar;
begin
  prepRc := -1; stepRc := -1; asText := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    rcs := sqlite3_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      zT := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if zT <> nil then asText := AnsiString(zT);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRun1(const sql: AnsiString; out prepRc, stepRc: i32;
                out asText: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rcs: Int32;
  zT: PChar;
begin
  prepRc := -1; stepRc := -1; asText := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    rcs := csq_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      zT := csq_column_text(pStmt, 0);
      if zT <> nil then asText := AnsiString(zT);
    end;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure Probe(const lbl, sql: AnsiString);
var
  pPrep, pStep, cPrep, cStep: i32;
  pTxt, cTxt: AnsiString;
begin
  PasRun1(sql, pPrep, pStep, pTxt);
  CRun1  (sql, cPrep, cStep, cTxt);
  if (pPrep = cPrep) and (pStep = cStep) and (pTxt = cTxt) then
    WriteLn('PASS    ', lbl, ' -> [', cTxt, ']')
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql =', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep, ' txt="', cTxt, '"');
  end;
end;

begin
  // --- width / padding ---
  Probe('width pad',     'SELECT printf(''[%5d]'', 42)');
  Probe('width zero',    'SELECT printf(''[%05d]'', 42)');
  Probe('width left',    'SELECT printf(''[%-5d]'', 42)');
  Probe('width plus',    'SELECT printf(''[%+d]'', 42)');
  Probe('width space',   'SELECT printf(''[% d]'', 42)');
  Probe('precision int', 'SELECT printf(''[%.5d]'', 42)');
  Probe('width text',    'SELECT printf(''[%-10s]'', ''hi'')');
  Probe('prec text',     'SELECT printf(''[%.3s]'', ''hello'')');
  Probe('prec wide',     'SELECT printf(''[%10.3s]'', ''hello'')');

  // --- hex / oct / unsigned ---
  Probe('hex lower',     'SELECT printf(''%x'', 255)');
  Probe('hex upper',     'SELECT printf(''%X'', 255)');
  Probe('hex with #',    'SELECT printf(''%#x'', 255)');
  Probe('octal',         'SELECT printf(''%o'', 8)');
  Probe('octal #',       'SELECT printf(''%#o'', 8)');
  Probe('unsigned',      'SELECT printf(''%u'', -1)');

  // --- char ---
  Probe('char A',        'SELECT printf(''%c'', 65)');
  Probe('char zero',     'SELECT printf(''[%c]'', 0)');

  // --- floats ---
  Probe('e small',       'SELECT printf(''%e'', 0.000123)');
  Probe('E upper',       'SELECT printf(''%E'', 1234.5)');
  Probe('g small',       'SELECT printf(''%g'', 0.0001)');
  Probe('g large',       'SELECT printf(''%g'', 1234567.0)');
  Probe('f neg',         'SELECT printf(''%.2f'', -3.14)');
  Probe('f zero pad',    'SELECT printf(''[%08.2f]'', 3.14)');

  // --- percent / literal ---
  Probe('percent lit',   'SELECT printf(''100%%'')');
  Probe('no args',       'SELECT printf(''hello'')');

  // --- SQLite-specific %q %Q %w %s NULL ---
  Probe('q simple',      'SELECT printf(''%q'', ''it''''s'')');
  Probe('Q simple',      'SELECT printf(''%Q'', ''it''''s'')');
  Probe('Q null',        'SELECT printf(''%Q'', NULL)');
  Probe('q null',        'SELECT printf(''%q'', NULL)');
  Probe('s null',        'SELECT printf(''[%s]'', NULL)');
  Probe('w identifier',  'SELECT printf(''%w'', ''ab"cd'')');

  // --- explicit positional / star width ---
  Probe('star width',    'SELECT printf(''[%*d]'', 6, 42)');
  Probe('star prec',     'SELECT printf(''[%.*f]'', 3, 3.14159)');

  // --- !g (alternative-form g, sqlite extension) ---
  Probe('!g full',       'SELECT printf(''%!g'', 3.14159265358979)');

  // --- big int / negative formats ---
  Probe('lld max',       'SELECT printf(''%lld'', 9223372036854775807)');
  Probe('lld min',       'SELECT printf(''%lld'', -9223372036854775808)');
  Probe('hex big',       'SELECT printf(''%llx'', 4294967295)');

  // --- multi-arg ---
  Probe('three',         'SELECT printf(''%d-%s-%g'', 1, ''x'', 2.5)');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
  if diverged > 0 then Halt(1);
end.
