{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.
}
{$I ../passqlite3.inc}
{
  DiagDml — runtime probe for under-tested DML extensions:
    UPSERT (ON CONFLICT ... DO {NOTHING,UPDATE SET ...}),
    RETURNING (INSERT/UPDATE/DELETE),
    INSERT INTO t SELECT ... (cross-table copy),
    UPDATE ... FROM (3.33+ extension),
    INSERT with column list reorder,
    multi-row VALUES with non-constant expressions.

  Symptom-only: each case prepares + steps both Pas and C, captures
  rc + a witness count/value, and prints DIVERGE if they disagree.
  Findings feed into tasklist.md.

  Build: src/tests/build.sh
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagDml
}
program DiagDml;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  gDiverge: Int32 = 0;
  gPass: Int32 = 0;

procedure RunPasSetup(const setup: array of AnsiString; out db: PTsqlite3);
var
  i: Int32;
  st: PVdbe;
  rc: i32;
begin
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  for i := 0 to High(setup) do begin
    st := nil;
    rc := sqlite3_prepare_v2(db, PAnsiChar(setup[i]), -1, @st, nil);
    if (rc = 0) and (st <> nil) then begin
      while sqlite3_step(st) = SQLITE_ROW do ;
      sqlite3_finalize(st);
    end else if st <> nil then sqlite3_finalize(st);
  end;
end;

procedure RunCSetup(const setup: array of AnsiString; out db: Pcsq_db);
var
  i: Int32;
  st: Pcsq_stmt;
  pTail: PChar;
begin
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  for i := 0 to High(setup) do begin
    st := nil; pTail := nil;
    if (csq_prepare_v2(db, PAnsiChar(setup[i]), -1, st, pTail) = 0)
       and (st <> nil) then begin
      while csq_step(st) = SQLITE_ROW do ;
      csq_finalize(st);
    end;
  end;
end;

{ run sql, return prep-rc, step-rc, witness column0 of "SELECT ..." or -99999 }
procedure RunPas(const setup: array of AnsiString;
                 const sql, witness: AnsiString;
                 out prep, step, val: Int32);
var
  db: PTsqlite3;
  st: PVdbe;
  rc: i32;
begin
  prep := -1; step := -1; val := -99999;
  RunPasSetup(setup, db);
  if db = nil then Exit;
  st := nil;
  prep := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @st, nil);
  if st <> nil then begin
    rc := sqlite3_step(st);
    while rc = SQLITE_ROW do rc := sqlite3_step(st);
    step := rc;
    sqlite3_finalize(st);
  end;
  if witness <> '' then begin
    st := nil;
    if (sqlite3_prepare_v2(db, PAnsiChar(witness), -1, @st, nil) = 0)
       and (st <> nil) then begin
      if sqlite3_step(st) = SQLITE_ROW then
        val := sqlite3_column_int(st, 0);
      sqlite3_finalize(st);
    end;
  end;
  sqlite3_close(db);
end;

procedure RunC(const setup: array of AnsiString;
               const sql, witness: AnsiString;
               out prep, step, val: Int32);
var
  db: Pcsq_db;
  st: Pcsq_stmt;
  pTail: PChar;
  rc: Int32;
begin
  prep := -1; step := -1; val := -99999;
  RunCSetup(setup, db);
  if db = nil then Exit;
  st := nil; pTail := nil;
  prep := csq_prepare_v2(db, PAnsiChar(sql), -1, st, pTail);
  if st <> nil then begin
    rc := csq_step(st);
    while rc = SQLITE_ROW do rc := csq_step(st);
    step := rc;
    csq_finalize(st);
  end;
  if witness <> '' then begin
    st := nil; pTail := nil;
    if (csq_prepare_v2(db, PAnsiChar(witness), -1, st, pTail) = 0)
       and (st <> nil) then begin
      if csq_step(st) = SQLITE_ROW then
        val := csq_column_int(st, 0);
      csq_finalize(st);
    end;
  end;
  csq_close(db);
end;

procedure Probe(const tag: AnsiString;
                const setup: array of AnsiString;
                const sql, witness: AnsiString);
var
  pP, pS, pV, cP, cS, cV: Int32;
begin
  RunPas(setup, sql, witness, pP, pS, pV);
  RunC  (setup, sql, witness, cP, cS, cV);
  if (pP = cP) and (pS = cS) and (pV = cV) then begin
    Inc(gPass);
    WriteLn('PASS    ', tag);
  end else begin
    Inc(gDiverge);
    WriteLn('DIVERGE ', tag);
    WriteLn('   sql = ', sql);
    WriteLn('   wit = ', witness);
    WriteLn('   Pas: prep=', pP, ' step=', pS, ' val=', pV);
    WriteLn('   C  : prep=', cP, ' step=', cS, ' val=', cV);
  end;
end;

const
  CT_T2  : array[0..0] of AnsiString = ('CREATE TABLE t(a INTEGER PRIMARY KEY, b)');
  CT_TQ  : array[0..0] of AnsiString = ('CREATE TABLE t(a, b UNIQUE)');
  CT_SRC : array[0..1] of AnsiString = ('CREATE TABLE s(x,y)',
                                        'CREATE TABLE d(x,y)');
  CT_TBL : array[0..0] of AnsiString = ('CREATE TABLE t(a,b)');

begin
  WriteLn('=== DiagDml ===');

  // --- UPSERT ---
  Probe('upsert do nothing on pk',
        CT_T2,
        'INSERT INTO t VALUES(1,''x''); INSERT INTO t VALUES(1,''y'') ON CONFLICT(a) DO NOTHING',
        'SELECT count(*) FROM t WHERE b=''x''');
  Probe('upsert do update on pk',
        CT_T2,
        'INSERT INTO t VALUES(1,''x''); INSERT INTO t VALUES(1,''y'') ON CONFLICT(a) DO UPDATE SET b=''z''',
        'SELECT (b=''z'') FROM t WHERE a=1');
  Probe('upsert do update with excluded',
        CT_T2,
        'INSERT INTO t VALUES(1,''x''); INSERT INTO t VALUES(1,''y'') ON CONFLICT(a) DO UPDATE SET b=excluded.b',
        'SELECT (b=''y'') FROM t WHERE a=1');
  Probe('upsert do nothing on unique',
        CT_TQ,
        'INSERT INTO t VALUES(1,''k''); INSERT INTO t VALUES(2,''k'') ON CONFLICT(b) DO NOTHING',
        'SELECT count(*) FROM t');

  // --- RETURNING ---
  Probe('insert returning rowid',
        CT_T2,
        'INSERT INTO t(b) VALUES(''r1'') RETURNING a',
        'SELECT count(*) FROM t');
  Probe('update returning val',
        CT_T2,
        'INSERT INTO t VALUES(1,''x''); UPDATE t SET b=''y'' WHERE a=1 RETURNING b',
        'SELECT count(*) FROM t WHERE b=''y''');
  Probe('delete returning',
        CT_T2,
        'INSERT INTO t VALUES(1,''x''); DELETE FROM t WHERE a=1 RETURNING b',
        'SELECT count(*) FROM t');

  // --- INSERT-FROM-SELECT ---
  Probe('insert select cross table',
        CT_SRC,
        'INSERT INTO s VALUES(1,2),(3,4); INSERT INTO d SELECT * FROM s',
        'SELECT count(*) FROM d');
  Probe('insert select with where',
        CT_SRC,
        'INSERT INTO s VALUES(1,2),(3,4),(5,6); INSERT INTO d SELECT x,y FROM s WHERE x>1',
        'SELECT count(*) FROM d');
  Probe('insert select const',
        CT_TBL,
        'INSERT INTO t SELECT 1,2 UNION ALL SELECT 3,4',
        'SELECT count(*) FROM t');

  // --- UPDATE-FROM ---
  Probe('update from',
        CT_SRC,
        'INSERT INTO s VALUES(1,10),(2,20); INSERT INTO d VALUES(1,0),(2,0); '
        + 'UPDATE d SET y=s.y FROM s WHERE d.x=s.x',
        'SELECT sum(y) FROM d');

  // --- INSERT column-list reorder ---
  Probe('insert column reorder',
        CT_TBL,
        'INSERT INTO t(b,a) VALUES(99,7)',
        'SELECT a FROM t');

  // --- multi-row VALUES with non-constant expression ---
  Probe('multi-row values expr',
        CT_TBL,
        'INSERT INTO t VALUES(1,1+1),(2,2*2),(3,3+3)',
        'SELECT count(*) FROM t');

  // --- DEFAULT clause edge ---
  Probe('default with expr',
        ['CREATE TABLE t(a, b DEFAULT (1+1))'],
        'INSERT INTO t(a) VALUES(0)',
        'SELECT b FROM t');

  WriteLn;
  WriteLn('Total: ', gPass, ' pass, ', gDiverge, ' diverge');
end.
