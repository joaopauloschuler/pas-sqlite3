{$I ../passqlite3.inc}
{
  DiagMoreFunc — second-wave probe targeting built-in functions and
  expression edges not yet covered by DiagFunctions / DiagDate / DiagMisc /
  DiagFeatureProbe.  Goal: surface bugs not already on the tasklist.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagMoreFunc.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagMoreFunc
}
program DiagMoreFunc;

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
    WriteLn('   sql  = ', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep,
            ' type=', pType, ' int=', pInt, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep,
            ' type=', cType, ' int=', cInt, ' txt="', cTxt, '"');
  end;
end;

begin
  // --- iif / nullif edge cases ---
  Probe('iif true',           'SELECT iif(1,''A'',''B'')');
  Probe('iif false',          'SELECT iif(0,''A'',''B'')');
  Probe('iif null cond',      'SELECT iif(NULL,''A'',''B'')');

  // --- format alias of printf ---
  Probe('format %d',          'SELECT format(''%d'',42)');
  Probe('format %05d',        'SELECT format(''%05d'',7)');
  Probe('format %x',          'SELECT format(''%x'',255)');
  Probe('format %X',          'SELECT format(''%X'',255)');
  Probe('format %o',          'SELECT format(''%o'',8)');
  Probe('format %%',          'SELECT format(''%%'')');
  Probe('format %c',          'SELECT format(''%c'',65)');
  Probe('format %-5d|',       'SELECT format(''|%-5d|'',7)');
  Probe('format %+d pos',     'SELECT format(''%+d'',7)');
  Probe('format %+d neg',     'SELECT format(''%+d'',-7)');
  Probe('format %e',          'SELECT format(''%e'',1234.5)');
  Probe('format %g',          'SELECT format(''%g'',1234.5)');

  // --- math functions (registered via build flag SQLITE_ENABLE_MATH_FUNCTIONS) ---
  // C upstream may or may not have it; both should agree on availability.
  Probe('sqrt 4',             'SELECT sqrt(4)');
  Probe('exp 0',              'SELECT exp(0)');
  Probe('ln 1',               'SELECT ln(1)');
  Probe('pow 2 10',           'SELECT pow(2,10)');
  Probe('sin 0',              'SELECT sin(0)');
  Probe('cos 0',              'SELECT cos(0)');
  Probe('floor 3.7',          'SELECT floor(3.7)');
  Probe('ceil 3.2',           'SELECT ceil(3.2)');
  Probe('pi',                 'SELECT pi()');

  // --- BLOB helpers ---
  Probe('zeroblob length',    'SELECT length(zeroblob(8))');
  Probe('typeof zeroblob',    'SELECT typeof(zeroblob(4))');
  Probe('typeof randomblob',  'SELECT typeof(randomblob(4))');
  Probe('length randomblob',  'SELECT length(randomblob(8))');

  // --- unhex (newer fn) ---
  Probe('unhex',              'SELECT length(unhex(''abcd''))');
  Probe('unhex odd',          'SELECT typeof(unhex(''abc''))');

  // --- string concatenation operator ---
  Probe('|| basic',           'SELECT ''a''||''b''');
  Probe('|| with NULL',       'SELECT ''a''||NULL');
  Probe('|| with int',        'SELECT ''x=''||5');

  // --- expression edges ---
  Probe('NOT 0',              'SELECT NOT 0');
  Probe('NOT NULL expr',      'SELECT typeof(NOT NULL)');
  Probe('IS NULL',            'SELECT NULL IS NULL');
  Probe('IS NOT NULL',        'SELECT 1 IS NOT NULL');
  Probe('IS distinct',        'SELECT 1 IS NOT DISTINCT FROM 1');
  Probe('BETWEEN true',       'SELECT 5 BETWEEN 1 AND 10');
  Probe('BETWEEN false',      'SELECT 5 BETWEEN 6 AND 10');
  Probe('NOT BETWEEN',        'SELECT 5 NOT BETWEEN 6 AND 10');
  Probe('IN literal yes',     'SELECT 3 IN (1,2,3)');
  Probe('IN literal no',      'SELECT 9 IN (1,2,3)');
  Probe('NOT IN literal',     'SELECT 9 NOT IN (1,2,3)');
  Probe('CASE simple',        'SELECT CASE 2 WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' ELSE ''c'' END');
  Probe('CASE searched',      'SELECT CASE WHEN 1>0 THEN ''pos'' ELSE ''neg'' END');
  Probe('CASE no else',       'SELECT typeof(CASE 5 WHEN 1 THEN ''a'' END)');

  // --- LIKE with ESCAPE ---
  Probe('LIKE escape',        'SELECT ''100%'' LIKE ''100\%'' ESCAPE ''\''');
  Probe('LIKE underscore',    'SELECT ''abc'' LIKE ''a_c''');
  Probe('LIKE percent',       'SELECT ''abc'' LIKE ''a%''');
  Probe('LIKE case-insens',   'SELECT ''ABC'' LIKE ''abc''');

  // --- printf %q / %Q (SQL-quoting specifiers) ---
  Probe('printf %q',          'SELECT printf(''%q'',''it''''s'')');
  Probe('printf %Q str',      'SELECT printf(''%Q'',''hi'')');
  Probe('printf %Q null',     'SELECT printf(''%Q'',NULL)');
  Probe('printf %w',          'SELECT printf(''%w'',''col"name'')');
  Probe('printf %w null',     'SELECT printf(''%w'',NULL)');

  // --- unistr Unicode escape decoder (func.c:1174) ---
  Probe('unistr 4hex',        'SELECT unistr(''a\0041b'')');
  Probe('unistr backslash',   'SELECT unistr(''a\\b'')');
  Probe('unistr u',           'SELECT unistr(''é'')');
  Probe('unistr U',           'SELECT unistr(''\U0001F600'')');
  Probe('unistr +',           'SELECT unistr(''\+01F600'')');
  Probe('unistr null',        'SELECT unistr(NULL)');

  // --- Numeric coerce edges ---
  Probe('concat number',      'SELECT 1+''2''');
  Probe('text-as-int leading','SELECT ''  3 abc''+0');
  Probe('text-as-int empty',  'SELECT ''''+0');

  // --- Boolean keyword literals (TRUE/FALSE) ---
  Probe('TRUE',               'SELECT TRUE');
  Probe('FALSE',              'SELECT FALSE');
  Probe('TRUE+FALSE',         'SELECT TRUE+FALSE');

  // --- Modulo on floats ---
  Probe('mod float',          'SELECT 7.5 % 2');

  // --- Negative shift (undefined in C but documented in sqlite) ---
  Probe('shift big',          'SELECT 1 << 63');
  Probe('shift overflow',     'SELECT 1 << 64');

  // --- Aggregate as scalar (without GROUP BY, on no-FROM) ---
  // C: returns 5 (single-row aggregate); Pas may diverge.
  Probe('count() no-FROM',    'SELECT count(*)');
  Probe('sum literal',        'SELECT sum(5)');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
