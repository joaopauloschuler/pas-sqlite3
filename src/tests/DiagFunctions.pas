{$I ../passqlite3.inc}
{
  DiagFunctions — exploratory probe for built-in scalar functions and
  type-affinity / coercion edge cases.  Goal: surface bugs not yet
  captured in tasklist.md.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagFunctions.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagFunctions
}
program DiagFunctions;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

{ Run a single SELECT that returns one column.  Capture either an
  integer (asInt) or text (asText) form for comparison. }
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
  // --- typeof ---
  Probe('typeof int',     'SELECT typeof(5)');
  Probe('typeof real',    'SELECT typeof(5.0)');
  Probe('typeof text',    'SELECT typeof(''hi'')');
  Probe('typeof null',    'SELECT typeof(NULL)');
  Probe('typeof blob',    'SELECT typeof(X''00ff'')');

  // --- length ---
  Probe('length text',    'SELECT length(''abc'')');
  Probe('length empty',   'SELECT length('''')');
  Probe('length null',    'SELECT length(NULL)');
  Probe('length blob',    'SELECT length(X''0102'')');

  // --- substr ---
  Probe('substr basic',   'SELECT substr(''hello'', 2, 3)');
  Probe('substr neg',     'SELECT substr(''hello'', -3, 2)');
  Probe('substr 2arg',    'SELECT substr(''hello'', 3)');
  Probe('substr past',    'SELECT substr(''abc'', 5)');
  Probe('substr utf8 1',  'SELECT substr(''café'', 4, 1)');
  Probe('substr utf8 2',  'SELECT substr(''日本語'', 2, 1)');
  Probe('substr utf8 neg','SELECT substr(''日本語'', -2, 1)');

  // --- case conversion ---
  Probe('lower',          'SELECT lower(''ABC'')');
  Probe('upper',          'SELECT upper(''abc'')');

  // --- trim ---
  Probe('trim default',   'SELECT trim(''   x   '')');
  Probe('ltrim',          'SELECT ltrim(''   x   '')');
  Probe('rtrim',          'SELECT rtrim(''   x   '')');
  Probe('trim chars',     'SELECT trim(''xxhelloxx'', ''x'')');

  // --- replace / instr ---
  Probe('replace',        'SELECT replace(''abc'', ''b'', ''XY'')');
  Probe('instr found',    'SELECT instr(''abcde'', ''cd'')');
  Probe('instr not',      'SELECT instr(''abcde'', ''zz'')');

  // --- hex / unhex ---
  Probe('hex int',        'SELECT hex(0)');
  Probe('hex blob',       'SELECT hex(X''ab12'')');
  Probe('hex text',       'SELECT hex(''abc'')');

  // --- char / unicode ---
  Probe('char(65,66)',    'SELECT char(65,66)');
  Probe('unicode',        'SELECT unicode(''A'')');

  // --- abs / nullif / ifnull ---
  Probe('abs neg',        'SELECT abs(-7)');
  Probe('abs null',       'SELECT abs(NULL)');
  Probe('abs real',       'SELECT abs(-3.14)');
  Probe('nullif eq',      'SELECT nullif(1, 1)');
  Probe('nullif ne',      'SELECT nullif(1, 2)');
  Probe('ifnull',         'SELECT ifnull(NULL, 7)');

  // --- min/max scalar (variadic) ---
  Probe('min2',           'SELECT min(3, 5)');
  Probe('max2',           'SELECT max(3, 5)');
  Probe('min3 with null', 'SELECT min(3, NULL, 5)');

  // --- arithmetic / coercion ---
  Probe('text+int',       'SELECT ''5''+3');
  Probe('int=real',       'SELECT 1=1.0');
  Probe('div by zero',    'SELECT 5/0');
  Probe('mod',            'SELECT 7 % 3');
  Probe('shift left',     'SELECT 1 << 4');
  Probe('shift right',    'SELECT 16 >> 2');
  Probe('bitand',         'SELECT 12 & 10');
  Probe('bitor',          'SELECT 12 | 1');
  Probe('bitnot',         'SELECT ~0');

  // --- CAST edge cases ---
  Probe('cast real to int',  'SELECT CAST(3.7 AS INTEGER)');
  Probe('cast text to real', 'SELECT CAST(''3.5'' AS REAL)');
  Probe('cast text empty',   'SELECT CAST('''' AS INTEGER)');
  Probe('cast null',         'SELECT CAST(NULL AS INTEGER)');

  // --- BLOB literal & X'' ---
  Probe('blob literal',  'SELECT X''0102''');
  Probe('blob length',   'SELECT length(X''00112233'')');

  // --- printf ---
  Probe('printf %d',     'SELECT printf(''%d'', 42)');
  Probe('printf %s',     'SELECT printf(''%s'', ''hi'')');
  Probe('printf %.2f',   'SELECT printf(''%.2f'', 3.14159)');

  // --- coalesce edges ---
  Probe('coalesce all null', 'SELECT coalesce(NULL,NULL)');
  Probe('coalesce mixed',    'SELECT coalesce(NULL,2,NULL)');

  // --- random / randomblob ---
  // Don't compare values (non-deterministic), just typeof.
  Probe('typeof random',     'SELECT typeof(random())');

  // --- LIKE / GLOB without table ---
  Probe('LIKE literal',      'SELECT ''abc'' LIKE ''a%''');
  Probe('GLOB literal',      'SELECT ''abc'' GLOB ''a*''');

  // --- Integer overflow / extremes ---
  Probe('max int',           'SELECT 9223372036854775807');
  Probe('min int',           'SELECT -9223372036854775808');
  Probe('overflow add',      'SELECT 9223372036854775807 + 1');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
