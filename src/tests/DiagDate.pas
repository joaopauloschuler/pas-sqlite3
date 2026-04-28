{$I ../passqlite3.inc}
program DiagDate;
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe,
     passqlite3codegen, passqlite3main, csqlite3;
var diverged: i32 = 0;

procedure PasRun1(const sql: AnsiString; out prepRc, stepRc: i32;
                  out asInt: Int64; out asText: AnsiString; out colType: i32);
var db: PTsqlite3; pStmt: PVdbe; rcs: i32; zT: PAnsiChar;
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
                out asInt: Int64; out asText: AnsiString; out colType: i32);
var db: Pcsq_db; pStmt: Pcsq_stmt; pTail: PChar; rcs: Int32; zT: PChar;
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
var pPrep,pStep,pType,cPrep,cStep,cType: i32;
    pInt,cInt: Int64; pTxt,cTxt: AnsiString; ok: Boolean;
begin
  PasRun1(sql, pPrep, pStep, pInt, pTxt, pType);
  CRun1  (sql, cPrep, cStep, cInt, cTxt, cType);
  ok := (pPrep = cPrep) and (pStep = cStep) and (pType = cType)
        and (pInt = cInt) and (pTxt = cTxt);
  if ok then WriteLn('PASS    ', lbl)
  else begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql  =', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep, ' type=', pType, ' int=', pInt, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep, ' type=', cType, ' int=', cInt, ' txt="', cTxt, '"');
  end;
end;

begin
  // Date / time
  Probe('date literal',     'SELECT date(''2024-01-15'')');
  Probe('time literal',     'SELECT time(''13:45:00'')');
  Probe('datetime literal', 'SELECT datetime(''2024-01-15 13:45:00'')');
  Probe('strftime ymd',     'SELECT strftime(''%Y-%m-%d'',''2024-06-30'')');
  Probe('julianday epoch',  'SELECT julianday(''2000-01-01 12:00:00'')');
  Probe('date plus days',   'SELECT date(''2024-01-15'',''+5 days'')');
  Probe('date minus mo',    'SELECT date(''2024-03-15'',''-1 month'')');
  Probe('date start mo',    'SELECT date(''2024-03-15'',''start of month'')');
  Probe('strftime weekday', 'SELECT strftime(''%w'',''2024-01-15'')');
  Probe('unixepoch',        'SELECT unixepoch(''2024-01-01'')');
  Probe('time HM',          'SELECT time(''13:45'')');

  // Numeric / scalar variants
  Probe('round 0',          'SELECT round(3.5)');
  Probe('round 2',          'SELECT round(3.14159, 2)');
  Probe('round neg',        'SELECT round(-2.5)');
  Probe('sign pos',         'SELECT sign(5)');
  Probe('sign neg',         'SELECT sign(-3.14)');
  Probe('sign zero',        'SELECT sign(0)');
  Probe('iif true',         'SELECT iif(1, ''a'', ''b'')');
  Probe('iif false',        'SELECT iif(0, ''a'', ''b'')');
  Probe('format like %d',   'SELECT format(''%d'', 42)');
  Probe('quote text',       'SELECT quote(''it''''s'')');
  Probe('quote null',       'SELECT quote(NULL)');
  Probe('quote blob',       'SELECT quote(X''ff'')');
  Probe('quote int',        'SELECT quote(123)');
  Probe('quote real',       'SELECT quote(1.5)');

  // last_insert_rowid / changes (no setup, expect 0)
  Probe('last_insert_rowid', 'SELECT last_insert_rowid()');
  Probe('changes',           'SELECT changes()');
  Probe('total_changes',     'SELECT total_changes()');

  // sqlite_version etc
  Probe('typeof sqlite_ver', 'SELECT typeof(sqlite_version())');
  Probe('typeof sqlite_src', 'SELECT typeof(sqlite_source_id())');

  // soundex / etc.
  Probe('like escape',       'SELECT ''100%'' LIKE ''100\%'' ESCAPE ''\''');
  Probe('like _',            'SELECT ''abc'' LIKE ''a_c''');
  Probe('glob ?',            'SELECT ''abc'' GLOB ''a?c''');
  Probe('glob []',           'SELECT ''abc'' GLOB ''[ab]bc''');

  // String comparisons
  Probe('cmp text',          'SELECT ''b''>''a''');
  Probe('cmp num text',      'SELECT 1>''a''');
  Probe('coalesce of types', 'SELECT typeof(coalesce(NULL, 1.5))');
  Probe('null is null',      'SELECT NULL IS NULL');
  Probe('null = null',       'SELECT NULL = NULL');

  // Arithmetic with text
  Probe('text*int',          'SELECT ''3''*2');
  Probe('empty text+int',    'SELECT ''''+5');
  Probe('text float coerce', 'SELECT ''1.5''+0');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
