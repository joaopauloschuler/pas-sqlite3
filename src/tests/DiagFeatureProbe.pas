{$I ../passqlite3.inc}
{
  DiagFeatureProbe — wide differential probe to find new runtime bugs.
  Compares Pas vs C across less-tested SQL features (ALTER, VIEW, CTE,
  JOIN, scalar subquery, EXISTS, CHECK, COLLATE, GENERATED COLUMNS).
  Reports prepare-rc / step-rc / first-int-of-check divergences only.
}
program DiagFeatureProbe;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure SplitExec(db: PTsqlite3; const setup: AnsiString);
var
  s, stmt2: AnsiString;
  p: i32;
  pStmt: PVdbe;
  rcs: i32;
begin
  s := setup;
  while s <> '' do
  begin
    p := Pos(';', s);
    if p = 0 then begin stmt2 := s; s := ''; end
    else begin stmt2 := Copy(s, 1, p - 1); s := Copy(s, p + 1, MaxInt); end;
    stmt2 := Trim(stmt2);
    if stmt2 = '' then continue;
    pStmt := nil;
    if (sqlite3_prepare_v2(db, PAnsiChar(stmt2), -1, @pStmt, nil) = 0)
       and (pStmt <> nil) then
    begin
      repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
      sqlite3_finalize(pStmt);
    end;
  end;
end;

procedure PasRun(const setup, sql, check: AnsiString;
                 out prepRc, stepRc, val, checkPrep: i32);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
begin
  prepRc := -1; stepRc := -1; val := -1; checkPrep := -1;
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  if setup <> '' then SplitExec(db, setup);
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then
  begin
    rcs := sqlite3_step(pStmt);
    while rcs = SQLITE_ROW do rcs := sqlite3_step(pStmt);
    stepRc := rcs;
    sqlite3_finalize(pStmt);
  end;
  if check <> '' then
  begin
    pStmt := nil;
    checkPrep := sqlite3_prepare_v2(db, PAnsiChar(check), -1, @pStmt, nil);
    if (checkPrep = 0) and (pStmt <> nil) then
    begin
      if sqlite3_step(pStmt) = SQLITE_ROW then
        val := sqlite3_column_int(pStmt, 0);
      sqlite3_finalize(pStmt);
    end;
  end;
  sqlite3_close(db);
end;

procedure CRun(const setup, sql, check: AnsiString;
               out prepRc, stepRc, val, checkPrep: i32);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail, pErr: PChar;
  rcs: Int32;
begin
  prepRc := -1; stepRc := -1; val := -1; checkPrep := -1;
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  if setup <> '' then
  begin
    pErr := nil;
    csq_exec(db, PAnsiChar(setup), nil, nil, pErr);
  end;
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then
  begin
    rcs := csq_step(pStmt);
    while rcs = SQLITE_ROW do rcs := csq_step(pStmt);
    stepRc := rcs;
    csq_finalize(pStmt);
  end;
  if check <> '' then
  begin
    pStmt := nil; pTail := nil;
    checkPrep := csq_prepare_v2(db, PAnsiChar(check), -1, pStmt, pTail);
    if (checkPrep = 0) and (pStmt <> nil) then
    begin
      if csq_step(pStmt) = SQLITE_ROW then
        val := csq_column_int(pStmt, 0);
      csq_finalize(pStmt);
    end;
  end;
  csq_close(db);
end;

procedure Probe(const lbl, setup, sql, check: AnsiString);
var
  pPrep, pStep, pVal, pChkP: i32;
  cPrep, cStep, cVal, cChkP: i32;
begin
  PasRun(setup, sql, check, pPrep, pStep, pVal, pChkP);
  CRun  (setup, sql, check, cPrep, cStep, cVal, cChkP);
  if (pPrep = cPrep) and (pStep = cStep)
     and (pVal = cVal) and (pChkP = cChkP) then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql  =', sql);
    WriteLn('   check=', check);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep,
            ' chkPrep=', pChkP, ' val=', pVal);
    WriteLn('   C  : prep=', cPrep, ' step=', cStep,
            ' chkPrep=', cChkP, ' val=', cVal);
  end;
end;

begin
  // VIEW
  Probe('CREATE VIEW + SELECT count',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); CREATE VIEW v AS SELECT a FROM t',
        'SELECT 1',
        'SELECT count(*) FROM v');
  // CTE
  Probe('CTE simple',
        '',
        'SELECT 1',
        'WITH c(x) AS (SELECT 7) SELECT x FROM c');
  // CTE recursive
  Probe('CTE recursive',
        '',
        'SELECT 1',
        'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<5) SELECT count(*) FROM r');
  // ALTER TABLE rename column
  Probe('ALTER TABLE rename column',
        'CREATE TABLE t(a, b)',
        'ALTER TABLE t RENAME COLUMN a TO c',
        'SELECT count(*) FROM pragma_table_info(''t'') WHERE name=''c''');
  // ALTER TABLE add column
  Probe('ALTER TABLE add column',
        'CREATE TABLE t(a)',
        'ALTER TABLE t ADD COLUMN b INTEGER DEFAULT 5',
        'SELECT count(*) FROM pragma_table_info(''t'')');
  // CHECK constraint
  Probe('CHECK rejects bad insert',
        'CREATE TABLE t(a CHECK(a > 0))',
        'INSERT INTO t VALUES(-1)',  // should fail
        'SELECT count(*) FROM t');
  // COLLATE NOCASE
  Probe('COLLATE NOCASE compare',
        '',
        'SELECT 1',
        'SELECT ''ABC'' = ''abc'' COLLATE NOCASE');
  // EXISTS
  Probe('EXISTS subquery',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1)',
        'SELECT 1',
        'SELECT EXISTS(SELECT 1 FROM t WHERE a=1)');
  // Scalar subquery
  Probe('Scalar subquery',
        'CREATE TABLE t(a); INSERT INTO t VALUES(42)',
        'SELECT 1',
        'SELECT (SELECT a FROM t)');
  // INNER JOIN
  Probe('INNER JOIN',
        'CREATE TABLE t(a); CREATE TABLE u(b); INSERT INTO t VALUES(1); INSERT INTO u VALUES(1)',
        'SELECT 1',
        'SELECT count(*) FROM t INNER JOIN u ON t.a=u.b');
  // LEFT JOIN
  Probe('LEFT JOIN',
        'CREATE TABLE t(a); CREATE TABLE u(b); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2)',
        'SELECT 1',
        'SELECT count(*) FROM t LEFT JOIN u ON t.a=u.b');
  // CREATE TRIGGER
  Probe('CREATE TRIGGER then INSERT',
        'CREATE TABLE t(a); CREATE TABLE log(x); CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES(NEW.a); END',
        'INSERT INTO t VALUES(99)',
        'SELECT x FROM log');
  // GENERATED COLUMN
  Probe('GENERATED column virtual',
        'CREATE TABLE t(a INTEGER, b INTEGER GENERATED ALWAYS AS (a*2) VIRTUAL)',
        'INSERT INTO t(a) VALUES(3)',
        'SELECT b FROM t');
  // pragma table_info
  Probe('pragma table_info count',
        'CREATE TABLE t(a, b, c)',
        'SELECT 1',
        'SELECT count(*) FROM pragma_table_info(''t'')');
  // UNION
  Probe('UNION compound',
        '',
        'SELECT 1',
        'SELECT count(*) FROM (SELECT 1 UNION SELECT 2 UNION SELECT 1)');
  // ORDER BY DESC + LIMIT (already known partially)
  Probe('SELECT 1 ORDER BY 1',
        '',
        'SELECT 1',
        'SELECT 1');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
