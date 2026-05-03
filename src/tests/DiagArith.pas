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
  domain, authored by D. Richard Hipp and contributors.
}
{$I ../passqlite3.inc}
{
  DiagArith — exploratory probe for arithmetic, NULL propagation,
  comparison coercion, string built-in edges.  Goal: surface bugs not
  yet captured in tasklist.md.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm src/tests/DiagArith.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagArith
}
program DiagArith;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;
  passed:   i32 = 0;

procedure PasRun1(const sql: AnsiString;
                  out prepRc, stepRc, colType: i32;
                  out asText: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  zT: PAnsiChar;
begin
  prepRc := -1; stepRc := -1; colType := -1; asText := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    rcs := sqlite3_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      colType := sqlite3_column_type(pStmt, 0);
      zT := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if zT <> nil then asText := AnsiString(zT);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRun1(const sql: AnsiString;
                out prepRc, stepRc, colType: i32;
                out asText: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rcs: Int32;
  zT: PChar;
begin
  prepRc := -1; stepRc := -1; colType := -1; asText := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    rcs := csq_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      colType := csq_column_type(pStmt, 0);
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
  pTxt, cTxt: AnsiString;
  ok: Boolean;
begin
  PasRun1(sql, pPrep, pStep, pType, pTxt);
  CRun1  (sql, cPrep, cStep, cType, cTxt);
  ok := (pPrep = cPrep) and (pStep = cStep)
        and (pType = cType) and (pTxt = cTxt);
  if ok then begin
    Inc(passed);
    WriteLn('PASS    ', lbl);
  end
  else begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql=', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep,
            ' type=', pType, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep,
            ' type=', cType, ' txt="', cTxt, '"');
  end;
end;

begin
  // -- integer arithmetic edges ------------------------------------
  Probe('add max+1',           'SELECT 9223372036854775807 + 1');
  Probe('sub min-1',           'SELECT -9223372036854775808 - 1');
  Probe('mul max*2',           'SELECT 9223372036854775807 * 2');
  Probe('mul min*-1',          'SELECT -9223372036854775808 * -1');
  Probe('div by zero',         'SELECT 5/0');
  Probe('mod by zero',         'SELECT 5%0');
  Probe('real div by zero',    'SELECT 5.0/0');
  Probe('div neg int',         'SELECT -7/2');
  Probe('mod neg',             'SELECT -7%3');
  Probe('mod neg2',            'SELECT 7%-3');

  // -- NULL propagation -------------------------------------------
  Probe('null + 1',            'SELECT NULL + 1');
  Probe('null * 0',            'SELECT NULL * 0');
  Probe('null || abc',         'SELECT NULL || ''abc''');
  Probe('null = null',         'SELECT NULL = NULL');
  Probe('null is null',        'SELECT NULL IS NULL');
  Probe('null is not null',    'SELECT NULL IS NOT NULL');
  Probe('null in list',        'SELECT NULL IN (1,2,3)');
  Probe('null in (null)',      'SELECT NULL IN (NULL)');
  Probe('1 in (null)',         'SELECT 1 IN (NULL)');
  Probe('and null false',      'SELECT NULL AND 0');
  Probe('and null true',       'SELECT NULL AND 1');
  Probe('or  null false',      'SELECT NULL OR 0');
  Probe('or  null true',       'SELECT NULL OR 1');

  // -- coalesce / nullif / iif -------------------------------------
  Probe('coalesce 3 args',     'SELECT coalesce(NULL,NULL,7)');
  Probe('coalesce all null',   'SELECT coalesce(NULL,NULL)');
  Probe('nullif equal',        'SELECT nullif(5,5)');
  Probe('nullif differ',       'SELECT nullif(5,6)');
  Probe('iif true',            'SELECT iif(1,''a'',''b'')');
  Probe('iif false',           'SELECT iif(0,''a'',''b'')');
  Probe('iif null cond',       'SELECT iif(NULL,''a'',''b'')');

  // -- comparison coercion ----------------------------------------
  Probe('text vs int eq',      'SELECT ''1''=1');
  Probe('text num vs int',     'SELECT ''1''+0=1');
  Probe('text vs int lt',      'SELECT ''2''<10');
  Probe('blob vs text',        'SELECT X''4142''=''AB''');
  Probe('between int',         'SELECT 5 BETWEEN 1 AND 10');
  Probe('between text',        'SELECT ''b'' BETWEEN ''a'' AND ''c''');
  Probe('between mixed',       'SELECT ''5'' BETWEEN 1 AND 10');

  // -- string built-ins -------------------------------------------
  Probe('substr neg',          'SELECT substr(''abcdef'',-2)');
  Probe('substr neg len',      'SELECT substr(''abcdef'',2,-2)');
  Probe('substr zero',         'SELECT substr(''abcdef'',0,3)');
  Probe('substr beyond',       'SELECT substr(''abc'',10,5)');
  Probe('replace empty',       'SELECT replace(''aaa'','''',''b'')');
  Probe('replace shrink',      'SELECT replace(''aaa'',''aa'',''b'')');
  Probe('replace grow',        'SELECT replace(''aaa'',''a'',''bb'')');
  Probe('instr basic',         'SELECT instr(''abcdef'',''cd'')');
  Probe('instr none',          'SELECT instr(''abcdef'',''zz'')');
  Probe('instr empty',         'SELECT instr(''abc'','''')');
  Probe('upper utf8',          'SELECT upper(''ábc'')');
  Probe('lower utf8',          'SELECT lower(''ÁBC'')');
  Probe('length utf8',         'SELECT length(''ábc'')');
  Probe('length blob',         'SELECT length(X''0102'')');
  Probe('trim ws',             'SELECT trim(''  hi  '')');
  Probe('trim chars',          'SELECT trim(''xxhixx'',''x'')');
  Probe('rtrim',               'SELECT rtrim(''  hi  '')');
  Probe('ltrim',               'SELECT ltrim(''  hi  '')');
  Probe('printf %d',           'SELECT printf(''%d'',42)');
  Probe('printf %.2f',         'SELECT printf(''%.2f'',3.14159)');
  Probe('printf %s',           'SELECT printf(''%s'',''hi'')');
  Probe('printf %%',           'SELECT printf(''%%'')');

  // -- LIKE / GLOB --------------------------------------------------
  Probe('like simple',         'SELECT ''abc'' LIKE ''ab%''');
  Probe('like underscore',     'SELECT ''abc'' LIKE ''a_c''');
  Probe('like nocase',         'SELECT ''ABC'' LIKE ''abc''');
  Probe('like escape',         'SELECT ''a%b'' LIKE ''a\%b'' ESCAPE ''\''');
  Probe('glob basic',          'SELECT ''abc'' GLOB ''ab?''');
  Probe('glob star',           'SELECT ''abcd'' GLOB ''a*d''');
  Probe('glob class',          'SELECT ''b''   GLOB ''[abc]''');
  Probe('glob neg class',      'SELECT ''d''   GLOB ''[^abc]''');

  // -- bitwise ------------------------------------------------------
  Probe('bit and',             'SELECT 12 & 10');
  Probe('bit or',              'SELECT 12 | 10');
  Probe('bit xor',             'SELECT 12 | 10 & ~(12 & 10)');
  Probe('bit shl',             'SELECT 1 << 4');
  Probe('bit shr',             'SELECT 256 >> 4');
  Probe('bit not',             'SELECT ~0');

  // -- numeric round / abs ------------------------------------------
  Probe('round neg',           'SELECT round(-3.5)');
  Probe('round halfeven?',     'SELECT round(0.5)');
  Probe('round prec',          'SELECT round(3.14159,2)');
  Probe('abs int',             'SELECT abs(-7)');
  Probe('abs real',            'SELECT abs(-3.5)');
  Probe('abs null',            'SELECT abs(NULL)');

  // -- unary ops ----------------------------------------------------
  Probe('neg neg int',         'SELECT - -7');
  Probe('not null',            'SELECT NOT NULL');
  Probe('not 0',               'SELECT NOT 0');
  Probe('not 5',               'SELECT NOT 5');

  // -- typeof + dyntyped -------------------------------------------
  Probe('typeof int',          'SELECT typeof(7)');
  Probe('typeof real',         'SELECT typeof(7.0)');
  Probe('typeof text',         'SELECT typeof(''x'')');
  Probe('typeof null',         'SELECT typeof(NULL)');
  Probe('typeof blob',         'SELECT typeof(X''00'')');
  Probe('typeof sum int',      'SELECT typeof(1+2)');
  Probe('typeof sum mix',      'SELECT typeof(1+2.0)');

  // -- session/connection scalars ----------------------------------
  Probe('changes() init',      'SELECT changes()');
  Probe('total_changes init',  'SELECT total_changes()');
  Probe('last_insert_rowid 0', 'SELECT last_insert_rowid()');
  Probe('sqlite_source_id len','SELECT length(sqlite_source_id())>20');
  Probe('sqlite_version dot',  'SELECT instr(sqlite_version(),''.'') > 0');

  // -- hex / unhex / quote -----------------------------------------
  Probe('hex blob',            'SELECT hex(X''0102fe'')');
  Probe('hex int',             'SELECT hex(255)');
  Probe('hex text',            'SELECT hex(''AB'')');
  Probe('unhex 4142',          'SELECT CAST(unhex(''4142'') AS TEXT)');
  Probe('unhex bad',           'SELECT unhex(''zz'')');
  Probe('quote int',           'SELECT quote(7)');
  Probe('quote text',          'SELECT quote(''it''''s'')');
  Probe('quote null',          'SELECT quote(NULL)');
  Probe('quote blob',          'SELECT quote(X''4142'')');
  Probe('char 65 66',          'SELECT char(65,66)');
  Probe('unicode A',           'SELECT unicode(''A'')');

  // -- char-class / format -----------------------------------------
  Probe('format %05d',         'SELECT format(''%05d'',7)');
  Probe('format %-5d|',        'SELECT format(''%-5d|'',7)');
  Probe('format %x',           'SELECT format(''%x'',255)');
  Probe('format %q',           'SELECT format(''%q'',''it''''s'')');
  Probe('format %Q null',      'SELECT format(''%Q'',NULL)');

  // -- date functions tail ------------------------------------------
  Probe('date now type',       'SELECT typeof(date(''now''))');
  Probe('strftime fmt',        'SELECT strftime(''%Y'',''2025-01-01'')');
  Probe('strftime epoch',      'SELECT strftime(''%s'',''1970-01-01 00:00:01'')');
  Probe('date plus mod',       'SELECT date(''2025-01-31'',''+1 month'')');
  Probe('time mod',            'SELECT time(''12:00:00'',''+90 minutes'')');
  Probe('julianday epoch',     'SELECT julianday(''1970-01-01'')');

  // -- aggregate scalars no FROM -----------------------------------
  Probe('agg max scalar',      'SELECT max(1,5,3)');
  Probe('agg min scalar',      'SELECT min(1,5,3)');
  Probe('agg max text',        'SELECT max(''b'',''a'',''c'')');
  Probe('agg min mixed',       'SELECT min(1,''2'',3)');

  // -- random / randomblob -----------------------------------------
  Probe('typeof random',       'SELECT typeof(random())');
  Probe('typeof randomblob',   'SELECT typeof(randomblob(8))');
  Probe('length randomblob',   'SELECT length(randomblob(16))');

  WriteLn('---');
  WriteLn('PASS=', passed, ' DIVERGE=', diverged);
end.
