{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  DiagScalarFunc — scalar built-in function probe.  Targets edges not
  already covered by DiagFunctions / DiagPrintfFmt / DiagDate /
  DiagSumOverflow / DiagMisc.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagScalarFunc.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagScalarFunc
}
program DiagScalarFunc;

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
  // --- printf SQL-escape specifiers ---
  Probe('printf %q simple',  'SELECT printf(''%q'', ''it''''s'')');
  Probe('printf %Q simple',  'SELECT printf(''%Q'', ''ab'')');
  Probe('printf %Q null',    'SELECT printf(''%Q'', NULL)');
  Probe('printf %w',         'SELECT printf(''%w'', ''a"b'')');
  Probe('printf %s null',    'SELECT printf(''%s'', NULL)');
  Probe('printf %i',         'SELECT printf(''%i'', 42)');
  Probe('printf %u',         'SELECT printf(''%u'', -1)');

  // --- format() alias ---
  Probe('format alias',      'SELECT format(''%d-%s'', 5, ''x'')');

  // --- iif / nullif / coalesce edges ---
  Probe('iif true',          'SELECT iif(1<2, ''y'', ''n'')');
  Probe('iif false',         'SELECT iif(1>2, ''y'', ''n'')');
  Probe('iif null cond',     'SELECT iif(NULL, ''y'', ''n'')');
  Probe('coalesce 1 arg',    'SELECT coalesce(NULL, NULL, 7, NULL)');
  Probe('nullif null lhs',   'SELECT nullif(NULL, 1)');

  // --- substr / substring edges ---
  Probe('substr 0 start',    'SELECT substr(''hello'', 0, 3)');
  Probe('substr neg len',    'SELECT substr(''hello'', 2, -2)');
  Probe('substr 0 len',      'SELECT substr(''hello'', 2, 0)');
  Probe('substring alias',   'SELECT substring(''abcdef'', 2, 3)');
  Probe('substr blob',       'SELECT length(substr(X''0102030405'', 2, 3))');

  // --- trim with custom multi-char list ---
  Probe('trim multi',        'SELECT trim(''xyhellooxx'', ''xyo'')');
  Probe('ltrim chars',       'SELECT ltrim(''xxhelloxx'', ''x'')');
  Probe('rtrim chars',       'SELECT rtrim(''xxhelloxx'', ''x'')');

  // --- replace edges ---
  Probe('replace empty pat', 'SELECT replace(''abc'', '''', ''X'')');
  Probe('replace empty rep', 'SELECT replace(''abacab'', ''a'', '''')');
  Probe('replace overlap',   'SELECT replace(''aaaa'', ''aa'', ''b'')');

  // --- instr edges ---
  Probe('instr empty needle','SELECT instr(''abc'', '''')');
  Probe('instr empty hay',   'SELECT instr('''', ''a'')');
  Probe('instr blob',        'SELECT instr(X''aabbcc'', X''bb'')');

  // --- hex / unhex ---
  Probe('hex empty',         'SELECT hex('''')');
  Probe('unhex 4',           'SELECT hex(unhex(''DEADBEEF''))');
  Probe('unhex odd',         'SELECT typeof(unhex(''DEAD1''))');
  Probe('unhex bad',         'SELECT typeof(unhex(''XX''))');
  Probe('unhex with ws',     'SELECT typeof(unhex(''DE AD'', '' ''))');

  // --- char / unicode edges ---
  Probe('char empty',        'SELECT char()');
  Probe('char bmp',          'SELECT char(0x4E2D)');
  Probe('unicode multi',     'SELECT unicode(''中'')');
  Probe('unicode empty',     'SELECT unicode('''')');

  // --- abs INT64 boundary ---
  Probe('abs minint',        'SELECT typeof(abs(-9223372036854775808))');
  Probe('abs i64 max',       'SELECT abs(9223372036854775807)');

  // --- round precision ---
  Probe('round half',        'SELECT round(0.5)');
  Probe('round neg half',    'SELECT round(-0.5)');
  Probe('round to 2',        'SELECT round(3.14159, 2)');
  Probe('round to 0',        'SELECT round(3.7, 0)');
  Probe('round neg prec',    'SELECT round(1234.5, -2)');

  // --- randomblob / zeroblob ---
  Probe('zeroblob len',      'SELECT length(zeroblob(8))');
  Probe('randomblob len',    'SELECT length(randomblob(16))');
  Probe('zeroblob 0',        'SELECT length(zeroblob(0))');
  Probe('zeroblob neg',      'SELECT length(zeroblob(-3))');

  // --- quote ---
  Probe('quote int',         'SELECT quote(7)');
  Probe('quote text',        'SELECT quote(''it''''s'')');
  Probe('quote null',        'SELECT quote(NULL)');
  Probe('quote blob',        'SELECT quote(X''ab12'')');
  Probe('quote real',        'SELECT quote(1.5)');

  // --- LIKE edges ---
  Probe('like underscore',   'SELECT ''abc'' LIKE ''a_c''');
  Probe('like percent',      'SELECT ''abc'' LIKE ''a%''');
  Probe('like escape',       'SELECT ''a%b'' LIKE ''a\%b'' ESCAPE ''\''');
  Probe('like ci',           'SELECT ''ABC'' LIKE ''abc''');
  Probe('like null pat',     'SELECT typeof(''a'' LIKE NULL)');
  Probe('not like',          'SELECT ''abc'' NOT LIKE ''d%''');

  // --- GLOB edges ---
  Probe('glob class',        'SELECT ''abc'' GLOB ''[a-c]bc''');
  Probe('glob neg class',    'SELECT ''xbc'' GLOB ''[^a]bc''');
  Probe('glob star',         'SELECT ''abcdef'' GLOB ''abc*''');
  Probe('glob qmark',        'SELECT ''abc'' GLOB ''a?c''');

  // --- typeof on big int ---
  Probe('typeof big int',    'SELECT typeof(9223372036854775807)');
  Probe('typeof hex int',    'SELECT typeof(0x7FFFFFFF)');
  Probe('typeof hex real',   'SELECT typeof(1e300)');

  // --- last_insert_rowid / changes / total_changes (init state) ---
  Probe('changes init',      'SELECT changes()');
  Probe('total_changes init','SELECT total_changes()');
  Probe('last_rowid init',   'SELECT last_insert_rowid()');

  // --- sqlite_version / sqlite_source_id (compare structure only via length) ---
  // Skip exact compare: version strings differ by build.  Check typeof.
  Probe('typeof version',    'SELECT typeof(sqlite_version())');
  Probe('typeof source_id',  'SELECT typeof(sqlite_source_id())');

  // --- soundex (gated on SQLITE_SOUNDEX in C; in this build, may be missing) ---
  Probe('soundex',           'SELECT soundex(''Robert'')');

  // --- json edges (very basic) ---
  Probe('json_valid yes',    'SELECT json_valid(''[1,2,3]'')');
  Probe('json_valid no',     'SELECT json_valid(''xx'')');
  Probe('json_array',        'SELECT json_array(1, ''a'', 3.5)');
  Probe('json_type',         'SELECT json_type(''{"a":1}'')');

  // --- date/time edges (a couple, light) ---
  Probe('date julianday',    'SELECT date(2440587.5)');
  Probe('strftime YMD',      'SELECT strftime(''%Y-%m-%d'', ''2026-04-29 12:34:56'')');
  Probe('time HMS',          'SELECT time(''2026-04-29 12:34:56'')');

  // --- arithmetic edges ---
  Probe('int / int',         'SELECT 10 / 3');
  Probe('real / int',        'SELECT 10.0 / 3');
  Probe('mod neg',           'SELECT -7 % 3');
  Probe('mod by zero',       'SELECT typeof(7 % 0)');
  Probe('add overflow',      'SELECT 9223372036854775807 + 1');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
  if diverged > 0 then Halt(1) else Halt(0);
end.
