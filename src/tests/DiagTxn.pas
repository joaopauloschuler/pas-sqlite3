{$I ../passqlite3.inc}
{
  DiagTxn — exploratory probe for transactions, savepoints, conflict
  resolution, INSERT OR REPLACE/IGNORE/ABORT/FAIL semantics, ROWID and
  INTEGER PRIMARY KEY edges, BLOB literal handling, and PRAGMA round-trips
  that should be productive even before sqlite3Pragma is fully ported.
  Intended to surface previously-unknown silent bugs.
}
program DiagTxn;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure RunStmts(db: PTsqlite3; const sql: AnsiString);
var
  pStmt: PVdbe;
  s, stmt2: AnsiString;
  p, rcs: i32;
begin
  s := sql;
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

procedure CRunStmts(db: Pcsq_db; const sql: AnsiString);
var pErr: PChar;
begin
  pErr := nil;
  csq_exec(db, PAnsiChar(sql), nil, nil, pErr);
end;

function PasRun(const setup, check: AnsiString;
                out checkPrep, val: i32; out txt: AnsiString): i32;
var
  db: PTsqlite3;
  pStmt: PVdbe;
  pTxt: PAnsiChar;
begin
  Result := 0;
  checkPrep := -1; val := -99999; txt := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin Result := -1; Exit; end;
  if setup <> '' then RunStmts(db, setup);
  pStmt := nil;
  checkPrep := sqlite3_prepare_v2(db, PAnsiChar(check), -1, @pStmt, nil);
  if (checkPrep = 0) and (pStmt <> nil) then begin
    if sqlite3_step(pStmt) = SQLITE_ROW then begin
      val := sqlite3_column_int(pStmt, 0);
      pTxt := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if pTxt <> nil then txt := AnsiString(pTxt);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

function CRun(const setup, check: AnsiString;
              out checkPrep, val: i32; out txt: AnsiString): i32;
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  pTxt: PAnsiChar;
begin
  Result := 0;
  checkPrep := -1; val := -99999; txt := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then begin Result := -1; Exit; end;
  if setup <> '' then CRunStmts(db, setup);
  pStmt := nil; pTail := nil;
  checkPrep := csq_prepare_v2(db, PAnsiChar(check), -1, pStmt, pTail);
  if (checkPrep = 0) and (pStmt <> nil) then begin
    if csq_step(pStmt) = SQLITE_ROW then begin
      val := csq_column_int(pStmt, 0);
      pTxt := PAnsiChar(csq_column_text(pStmt, 0));
      if pTxt <> nil then txt := AnsiString(pTxt);
    end;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure Probe(const lbl, setup, check: AnsiString);
var
  pPrep, pVal: i32;
  cPrep, cVal: i32;
  pTxt, cTxt: AnsiString;
  ok: Boolean;
begin
  PasRun(setup, check, pPrep, pVal, pTxt);
  CRun  (setup, check, cPrep, cVal, cTxt);
  ok := (pPrep = cPrep) and (pVal = cVal) and (pTxt = cTxt);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   check=', check);
    WriteLn('   Pas: prep=', pPrep, ' val=', pVal, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' val=', cVal, ' txt="', cTxt, '"');
  end;
end;

begin
  // --- transactions: BEGIN/COMMIT/ROLLBACK ---
  Probe('begin commit insert',
    'CREATE TABLE t(a); BEGIN; INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); COMMIT',
    'SELECT count(*) FROM t');                        // 2
  Probe('begin rollback insert',
    'CREATE TABLE t(a); INSERT INTO t VALUES(1); BEGIN; INSERT INTO t VALUES(2); ROLLBACK',
    'SELECT count(*) FROM t');                        // 1
  Probe('begin no tx pending',
    'CREATE TABLE t(a); BEGIN; INSERT INTO t VALUES(1)',
    'SELECT count(*) FROM t');                        // 1 (still inside tx; visible)

  // --- savepoints ---
  Probe('savepoint release',
    'CREATE TABLE t(a); INSERT INTO t VALUES(1); SAVEPOINT s1; INSERT INTO t VALUES(2); RELEASE s1',
    'SELECT count(*) FROM t');                        // 2
  Probe('savepoint rollback',
    'CREATE TABLE t(a); INSERT INTO t VALUES(1); SAVEPOINT s1; INSERT INTO t VALUES(2); ROLLBACK TO s1; RELEASE s1',
    'SELECT count(*) FROM t');                        // 1

  // --- conflict resolution ---
  Probe('insert or ignore unique',
    'CREATE TABLE t(a UNIQUE); INSERT INTO t VALUES(1); INSERT OR IGNORE INTO t VALUES(1); INSERT OR IGNORE INTO t VALUES(2)',
    'SELECT count(*) FROM t');                        // 2
  Probe('insert or replace unique',
    'CREATE TABLE t(a UNIQUE, b); INSERT INTO t VALUES(1,10); INSERT OR REPLACE INTO t VALUES(1,20)',
    'SELECT b FROM t WHERE a=1');                     // 20
  Probe('insert or fail returns err',
    'CREATE TABLE t(a UNIQUE); INSERT INTO t VALUES(1); INSERT OR FAIL INTO t VALUES(1)',
    'SELECT count(*) FROM t');                        // 1

  // --- ROWID semantics ---
  Probe('rowid pseudo column',
    'CREATE TABLE t(a); INSERT INTO t VALUES(11); INSERT INTO t VALUES(22)',
    'SELECT rowid FROM t WHERE a=22');                // 2
  Probe('integer primary key alias',
    'CREATE TABLE t(id INTEGER PRIMARY KEY, x); INSERT INTO t VALUES(7, ''a''); INSERT INTO t VALUES(NULL, ''b'')',
    'SELECT id FROM t WHERE x=''b''');                // 8
  Probe('last_insert_rowid after insert',
    'CREATE TABLE t(a INTEGER PRIMARY KEY); INSERT INTO t VALUES(NULL); INSERT INTO t VALUES(NULL)',
    'SELECT last_insert_rowid()');                    // 2
  Probe('changes() after update',
    'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); UPDATE t SET a=99',
    'SELECT changes()');                              // 2
  Probe('total_changes()',
    'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); INSERT INTO t VALUES(3)',
    'SELECT total_changes()');                        // 3

  // --- BLOB literal & hex ---
  Probe('hex blob length',
    '', 'SELECT length(X''DEADBEEF'')');              // 4
  Probe('hex blob hex roundtrip',
    '', 'SELECT hex(X''00FF'')');                     // 00FF
  Probe('zeroblob',
    '', 'SELECT length(zeroblob(8))');                // 8
  Probe('randomblob length',
    '', 'SELECT length(randomblob(16))');             // 16

  // --- PRAGMAs that should be productive at parse-time ---
  Probe('pragma user_version default', '', 'PRAGMA user_version');           // 0
  Probe('pragma user_version set',
    'PRAGMA user_version = 42', 'PRAGMA user_version');                       // 42
  Probe('pragma application_id default', '', 'PRAGMA application_id');        // 0
  Probe('pragma encoding default', '', 'PRAGMA encoding');                    // UTF-8
  Probe('pragma page_size default', '', 'PRAGMA page_size');                  // 4096
  Probe('pragma cache_size default', '', 'PRAGMA cache_size');
  Probe('pragma journal_mode memory default mem',
    '', 'PRAGMA journal_mode');                                               // memory
  Probe('pragma synchronous default', '', 'PRAGMA synchronous');              // 2

  // --- typeof boundary cases ---
  Probe('typeof aff text after cast', '', 'SELECT typeof(CAST(42 AS TEXT))'); // text
  Probe('typeof aff num after cast', '', 'SELECT typeof(CAST(''42'' AS NUMERIC))'); // integer
  Probe('typeof aff real after cast', '', 'SELECT typeof(CAST(''1.5'' AS REAL))');   // real

  // --- NULL propagation through arithmetic & functions ---
  Probe('null + int', '', 'SELECT typeof(NULL + 1)');           // null
  Probe('null in coalesce', '', 'SELECT coalesce(NULL, NULL, 7)'); // 7
  Probe('null in min', '', 'SELECT min(1, NULL)');              // null
  Probe('null in max', '', 'SELECT max(1, NULL)');              // null
  Probe('iif true', '', 'SELECT iif(1, ''yes'', ''no'')');      // yes
  Probe('iif false', '', 'SELECT iif(0, ''yes'', ''no'')');     // no

  // --- common-but-easy-to-miss expression cases ---
  Probe('cast neg real to int', '', 'SELECT CAST(-1.7 AS INTEGER)'); // -1 (trunc toward 0)
  Probe('abs negative', '', 'SELECT abs(-7)');                   // 7
  Probe('abs null',     '', 'SELECT typeof(abs(NULL))');         // null
  Probe('cast empty str int', '', 'SELECT CAST('''' AS INT)');   // 0
  Probe('cast garbage int', '', 'SELECT CAST(''xyz'' AS INT)');  // 0
  Probe('hex str leading zeros', '', 'SELECT hex(CAST(0 AS BLOB))'); // 30 (ascii '0')

  WriteLn;
  WriteLn('Total divergences: ', diverged);
  if diverged > 0 then ExitCode := 1;
end.
