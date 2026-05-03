{
  SPDX-License-Identifier: blessing

  Pascal port of SQLite — DiagPredicates probe.
  Exercises predicate / comparison surface that other Diag* probes miss:
  IS / IS NOT, IS [NOT] DISTINCT FROM, BETWEEN / NOT BETWEEN,
  IN (list), NOT IN (list), boolean literals (TRUE/FALSE),
  CASE expressions (multi-WHEN, no-base, with NULLs), COALESCE chains,
  NULLIF, IIF nested, and operator precedence around NULL.

  Goal: surface previously-unknown silent-result divergences.
}
{$I ../passqlite3.inc}
program DiagPredicates;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure PasRunSeed(const seed, sql: AnsiString;
                     out prepRc, stepRc: i32;
                     out concat: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs, ncols, i: i32;
  zT: PAnsiChar;
  s: AnsiString;
begin
  prepRc := -1; stepRc := -1; concat := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  if seed <> '' then
    sqlite3_exec(db, PAnsiChar(seed), nil, nil, nil{%H-});
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    repeat
      rcs := sqlite3_step(pStmt);
      stepRc := rcs;
      if rcs = SQLITE_ROW then begin
        ncols := sqlite3_column_count(pStmt);
        s := '[';
        for i := 0 to ncols - 1 do begin
          if i > 0 then s := s + ',';
          zT := PAnsiChar(sqlite3_column_text(pStmt, i));
          if zT = nil then s := s + 'null'
          else s := s + AnsiString(zT);
        end;
        s := s + ']';
        if concat <> '' then concat := concat + ';';
        concat := concat + s;
      end;
    until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRunSeed(const seed, sql: AnsiString;
                   out prepRc, stepRc: i32;
                   out concat: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rcs, ncols, i: Int32;
  zT: PChar;
  s: AnsiString;
  pErr: PChar;
begin
  prepRc := -1; stepRc := -1; concat := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pErr := nil;
  if seed <> '' then
    csq_exec(db, PAnsiChar(seed), nil, nil, pErr);
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    repeat
      rcs := csq_step(pStmt);
      stepRc := rcs;
      if rcs = SQLITE_ROW then begin
        ncols := csq_column_count(pStmt);
        s := '[';
        for i := 0 to ncols - 1 do begin
          if i > 0 then s := s + ',';
          zT := csq_column_text(pStmt, i);
          if zT = nil then s := s + 'null'
          else s := s + AnsiString(zT);
        end;
        s := s + ']';
        if concat <> '' then concat := concat + ';';
        concat := concat + s;
      end;
    until rcs <> SQLITE_ROW;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure Probe(const lbl, sql: AnsiString); overload;
var
  pPrep, pStep, cPrep, cStep: i32;
  pCat, cCat: AnsiString;
  ok: Boolean;
begin
  PasRunSeed('', sql, pPrep, pStep, pCat);
  CRunSeed  ('', sql, cPrep, cStep, cCat);
  ok := (pPrep = cPrep) and (pStep = cStep) and (pCat = cCat);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql  =', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep, ' rows="', pCat, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep, ' rows="', cCat, '"');
  end;
end;

begin
  // --- Boolean literals (true/false keywords) ---
  Probe('select true',         'SELECT true');
  Probe('select false',        'SELECT false');
  Probe('not true',            'SELECT NOT true');
  Probe('true and false',      'SELECT true AND false');
  Probe('true or null',        'SELECT true OR null');
  Probe('false and null',      'SELECT false AND null');
  Probe('true and null',       'SELECT true AND null');
  Probe('false or null',       'SELECT false OR null');

  // --- IS / IS NOT distinctness ---
  Probe('null is null',        'SELECT null IS null');
  Probe('null is not null',    'SELECT null IS NOT null');
  Probe('1 is null',           'SELECT 1 IS null');
  Probe('1 is 1',              'SELECT 1 IS 1');
  Probe('1 is 2',              'SELECT 1 IS 2');
  Probe('null is 1',           'SELECT null IS 1');
  Probe('text is text',        'SELECT ''abc'' IS ''abc''');
  Probe('text is not text',    'SELECT ''abc'' IS NOT ''abd''');

  // --- IS [NOT] DISTINCT FROM (alias of IS NOT / IS) ---
  Probe('null distinct null',  'SELECT null IS DISTINCT FROM null');
  Probe('1 distinct null',     'SELECT 1 IS DISTINCT FROM null');
  Probe('1 not distinct 1',    'SELECT 1 IS NOT DISTINCT FROM 1');
  Probe('null not distinct',   'SELECT null IS NOT DISTINCT FROM null');

  // --- BETWEEN / NOT BETWEEN ---
  Probe('between hit',         'SELECT 5 BETWEEN 1 AND 10');
  Probe('between miss',        'SELECT 11 BETWEEN 1 AND 10');
  Probe('between equal lo',    'SELECT 1 BETWEEN 1 AND 10');
  Probe('between equal hi',    'SELECT 10 BETWEEN 1 AND 10');
  Probe('between null lhs',    'SELECT null BETWEEN 1 AND 10');
  Probe('between null lo',     'SELECT 5 BETWEEN null AND 10');
  Probe('between null hi',     'SELECT 5 BETWEEN 1 AND null');
  Probe('not between hit',     'SELECT 5 NOT BETWEEN 1 AND 10');
  Probe('not between miss',    'SELECT 11 NOT BETWEEN 1 AND 10');
  Probe('between text',        'SELECT ''b'' BETWEEN ''a'' AND ''c''');

  // --- IN (list) ---
  Probe('in hit',              'SELECT 2 IN (1,2,3)');
  Probe('in miss',              'SELECT 4 IN (1,2,3)');
  Probe('in null lhs',          'SELECT null IN (1,2,3)');
  Probe('in null in list',      'SELECT 1 IN (null,2,3)');
  Probe('in null match',        'SELECT 2 IN (null,2,3)');
  Probe('in empty miss',        'SELECT 1 IN (2)');
  Probe('not in hit',           'SELECT 4 NOT IN (1,2,3)');
  Probe('not in miss',          'SELECT 2 NOT IN (1,2,3)');
  Probe('not in null',          'SELECT null NOT IN (1,2,3)');
  Probe('not in null elem',     'SELECT 4 NOT IN (1,null,3)');
  Probe('in text',              'SELECT ''a'' IN (''a'',''b'')');
  Probe('in mixed',             'SELECT 1 IN (''1'',2,3)');

  // --- CASE expressions ---
  Probe('case simple match',    'SELECT CASE 1 WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' END');
  Probe('case simple miss',     'SELECT CASE 5 WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' END');
  Probe('case simple else',     'SELECT CASE 5 WHEN 1 THEN ''a'' ELSE ''z'' END');
  Probe('case search match',    'SELECT CASE WHEN 1=1 THEN ''yes'' ELSE ''no'' END');
  Probe('case multi when',      'SELECT CASE WHEN 0=1 THEN ''a'' WHEN 1=1 THEN ''b'' ELSE ''c'' END');
  Probe('case null when',       'SELECT CASE null WHEN null THEN ''eq'' ELSE ''ne'' END');
  Probe('case all null',        'SELECT CASE WHEN null THEN ''a'' END');
  Probe('case nested',          'SELECT CASE WHEN 1 THEN CASE WHEN 0 THEN ''x'' ELSE ''y'' END END');

  // --- COALESCE chains ---
  Probe('coalesce 2 args first','SELECT coalesce(1,2)');
  Probe('coalesce 2 args null', 'SELECT coalesce(null,2)');
  Probe('coalesce 3 args',      'SELECT coalesce(null,null,3)');
  Probe('coalesce all null',    'SELECT coalesce(null,null,null)');
  Probe('coalesce mixed',       'SELECT coalesce(null,'''',null,1)');

  // --- NULLIF ---
  Probe('nullif eq',            'SELECT nullif(5,5)');
  Probe('nullif ne',            'SELECT nullif(5,6)');
  Probe('nullif text eq',       'SELECT nullif(''a'',''a'')');
  Probe('nullif null',          'SELECT nullif(null,null)');
  Probe('nullif null lhs',      'SELECT nullif(null,1)');

  // --- IIF nested ---
  Probe('iif nested',           'SELECT iif(1,iif(0,''x'',''y''),''z'')');
  Probe('iif null',             'SELECT iif(null,''a'',''b'')');

  // --- LIKE / GLOB edges ---
  Probe('like pct',             'SELECT ''abcdef'' LIKE ''abc%''');
  Probe('like underscore',      'SELECT ''abc'' LIKE ''a_c''');
  Probe('like underscore_2',    'SELECT ''ac'' LIKE ''a_c''');
  Probe('like case insens',     'SELECT ''ABC'' LIKE ''abc''');
  Probe('like null lhs',        'SELECT null LIKE ''a''');
  Probe('like escape',          'SELECT ''a%b'' LIKE ''a\%b'' ESCAPE ''\''');
  Probe('glob star',            'SELECT ''abc'' GLOB ''a*''');
  Probe('glob class',           'SELECT ''abc'' GLOB ''a[bx]c''');
  Probe('glob neg class',       'SELECT ''abc'' GLOB ''a[!x]c''');
  Probe('glob case sens',       'SELECT ''ABC'' GLOB ''abc''');

  // --- Operator precedence around NULL ---
  Probe('null+1',               'SELECT null + 1');
  Probe('1+null',               'SELECT 1 + null');
  Probe('null*0',               'SELECT null * 0');
  Probe('null||x',              'SELECT null || ''x''');
  Probe('x||null',              'SELECT ''x'' || null');
  Probe('null=null',            'SELECT null = null');
  Probe('null<>null',           'SELECT null <> null');
  Probe('1<null',               'SELECT 1 < null');
  Probe('null<1',               'SELECT null < 1');
  Probe('not null',             'SELECT NOT null');

  // --- Integer/real coercion at compare ---
  Probe('1=1.0',                'SELECT 1 = 1.0');
  Probe('1=''1''',              'SELECT 1 = ''1''');
  Probe('1<''2''',              'SELECT 1 < ''2''');
  Probe('''1''<2',              'SELECT ''1'' < 2');
  Probe('1.0=''1.0''',          'SELECT 1.0 = ''1.0''');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
