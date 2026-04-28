{$I ../passqlite3.inc}
{
  DiagMisc — exploratory probe.  Run a small set of less-covered SQL
  statements through both the Pas port and the C reference and report
  divergences (prepare rc, step rc, COUNT(*) result for INSERTs,
  first-column value for SELECTs).  Goal: surface bugs not already
  captured in tasklist.md so they can be filed.
}
program DiagMisc;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

type
  TProbe = record
    setup: AnsiString;
    sql:   AnsiString;
    check: AnsiString; // SELECT that returns one int summarising the state
    label_: AnsiString;
  end;

var
  diverged: i32 = 0;

function PasRun(const setup, sql, check: AnsiString;
                out prepRc, stepRc, val, checkPrep: i32): i32;
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  s, stmt2: AnsiString;
  p: i32;
begin
  Result := 0;
  prepRc := -1; stepRc := -1; val := -1; checkPrep := -1;
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin Result := -1; Exit; end;
  if setup <> '' then begin
    s := setup;
    while s <> '' do begin
      p := Pos(';', s);
      if p = 0 then begin stmt2 := s; s := ''; end
      else begin stmt2 := Copy(s, 1, p - 1); s := Copy(s, p + 1, MaxInt); end;
      stmt2 := Trim(stmt2);
      if stmt2 = '' then continue;
      pStmt := nil;
      if (sqlite3_prepare_v2(db, PAnsiChar(stmt2), -1, @pStmt, nil) = 0)
        and (pStmt <> nil) then begin
        repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
        sqlite3_finalize(pStmt);
      end;
    end;
  end;
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    rcs := sqlite3_step(pStmt);
    while rcs = SQLITE_ROW do rcs := sqlite3_step(pStmt);
    stepRc := rcs;
    sqlite3_finalize(pStmt);
  end;
  if check <> '' then begin
    pStmt := nil;
    checkPrep := sqlite3_prepare_v2(db, PAnsiChar(check), -1, @pStmt, nil);
    if (checkPrep = 0) and (pStmt <> nil) then begin
      if sqlite3_step(pStmt) = SQLITE_ROW then
        val := sqlite3_column_int(pStmt, 0);
      sqlite3_finalize(pStmt);
    end;
  end;
  sqlite3_close(db);
end;

function CRun(const setup, sql, check: AnsiString;
              out prepRc, stepRc, val, checkPrep: i32): i32;
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail, pErr: PChar;
  rcs: Int32;
begin
  Result := 0;
  prepRc := -1; stepRc := -1; val := -1; checkPrep := -1;
  db := nil;
  if csq_open(':memory:', db) <> 0 then begin Result := -1; Exit; end;
  if setup <> '' then begin
    pErr := nil;
    csq_exec(db, PAnsiChar(setup), nil, nil, pErr);
  end;
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    rcs := csq_step(pStmt);
    while rcs = SQLITE_ROW do rcs := csq_step(pStmt);
    stepRc := rcs;
    csq_finalize(pStmt);
  end;
  if check <> '' then begin
    pStmt := nil; pTail := nil;
    checkPrep := csq_prepare_v2(db, PAnsiChar(check), -1, pStmt, pTail);
    if (checkPrep = 0) and (pStmt <> nil) then begin
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
  ok: Boolean;
begin
  PasRun(setup, sql, check, pPrep, pStep, pVal, pChkP);
  CRun  (setup, sql, check, cPrep, cStep, cVal, cChkP);
  ok := (pPrep = cPrep) and (pStep = cStep) and (pVal = cVal) and (pChkP = cChkP);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   setup=', setup);
    WriteLn('   sql  =', sql);
    WriteLn('   check=', check);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep, ' chkPrep=', pChkP, ' val=', pVal);
    WriteLn('   C  : prep=', cPrep, ' step=', cStep, ' chkPrep=', cChkP, ' val=', cVal);
  end;
end;

begin
  // --- DEFAULT clause ---
  Probe('INSERT default literal',
        'CREATE TABLE t(a, b DEFAULT 7)',
        'INSERT INTO t(a) VALUES(1)',
        'SELECT b FROM t');
  // --- CAST ---
  Probe('SELECT CAST(text AS INT)',
        'CREATE TABLE t(a)',
        'INSERT INTO t VALUES(''42'')',
        'SELECT CAST(a AS INTEGER) FROM t');
  // --- IS NULL ---
  Probe('SELECT count IS NULL',
        'CREATE TABLE t(a); INSERT INTO t VALUES(NULL)',
        'SELECT 1',
        'SELECT count(*) FROM t WHERE a IS NULL');
  // --- HEX literal ---
  Probe('INSERT hex literal',
        'CREATE TABLE t(a)',
        'INSERT INTO t VALUES(0x1F)',
        'SELECT a FROM t');
  // --- negative literal ---
  Probe('INSERT negative literal',
        'CREATE TABLE t(a)',
        'INSERT INTO t VALUES(-5)',
        'SELECT a FROM t');
  // --- arithmetic ---
  Probe('SELECT 2+3',
        '',
        'SELECT 1',
        'SELECT 2+3');
  // --- string concat ---
  Probe('SELECT ''a''||''b''',
        '',
        'SELECT 1',
        'SELECT length(''a''||''b'')');
  // --- LIKE ---
  Probe('SELECT LIKE pattern',
        'CREATE TABLE t(a); INSERT INTO t VALUES(''hello'')',
        'SELECT 1',
        'SELECT count(*) FROM t WHERE a LIKE ''hel%''');
  // --- BETWEEN ---
  Probe('SELECT BETWEEN',
        'CREATE TABLE t(a); INSERT INTO t VALUES(5)',
        'SELECT 1',
        'SELECT count(*) FROM t WHERE a BETWEEN 1 AND 10');
  // --- IN list ---
  Probe('SELECT IN list',
        'CREATE TABLE t(a); INSERT INTO t VALUES(2)',
        'SELECT 1',
        'SELECT count(*) FROM t WHERE a IN (1,2,3)');
  // --- COALESCE ---
  Probe('SELECT COALESCE',
        '',
        'SELECT 1',
        'SELECT COALESCE(NULL, NULL, 42)');
  // --- abs/typeof tests ---
  Probe('SELECT abs(-7)',
        '',
        'SELECT 1',
        'SELECT abs(-7)');
  // --- NULL inserts and is-not-null counts ---
  Probe('INSERT NULL count not-null',
        'CREATE TABLE t(a); INSERT INTO t VALUES(NULL); INSERT INTO t VALUES(1)',
        'SELECT 1',
        'SELECT count(*) FROM t WHERE a IS NOT NULL');
  // --- expr with parameters not bound (should yield NULL) ---
  // Narrow: do these work without WHERE / aggregate?
  Probe('count(*) on empty table',
        'CREATE TABLE t(a)',
        'SELECT 1',
        'SELECT count(*) FROM t');
  Probe('count(*) where a=NULL via setup INSERT',
        'CREATE TABLE t(a); INSERT INTO t VALUES(NULL)',
        'SELECT 1',
        'SELECT count(*) FROM t');
  Probe('SELECT a FROM t WHERE a IN (1,2,3) (no aggregate)',
        'CREATE TABLE t(a); INSERT INTO t VALUES(2)',
        'SELECT 1',
        'SELECT a FROM t WHERE a IN (1,2,3)');
  Probe('SELECT a FROM t WHERE a IS NULL (no aggregate)',
        'CREATE TABLE t(a); INSERT INTO t VALUES(NULL)',
        'SELECT 1',
        'SELECT count(*) FROM (SELECT a FROM t WHERE a IS NULL)');
  Probe('SELECT CASE WHEN 1=1 THEN 7 ELSE 9 END',
        '',
        'SELECT 1',
        'SELECT CASE WHEN 1=1 THEN 7 ELSE 9 END');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
