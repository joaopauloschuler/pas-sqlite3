{ DiagDropTable — runtime probe for the DROP TABLE schema-row deletion gap.

  Compares Pascal-port behaviour against the C reference for the
  CREATE / INSERT / DROP / re-CREATE / SELECT cycle.  Phase 6.11
  tracks this as the only remaining DROP TABLE divergence. }
program DiagDropTable;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe, passqlite3main, csqlite3;

var
  gDiverge: Int32 = 0;
  gPass:    Int32 = 0;

procedure RunPas(const sql: AnsiString; var rc: i32; var errOut: AnsiString);
var
  db: PTsqlite3;
  err: PAnsiChar;
begin
  db := nil; err := nil; rc := SQLITE_OK; errOut := '';
  if sqlite3_open(':memory:', @db) <> 0 then begin rc := -1; Exit; end;
  rc := sqlite3_exec(db, PAnsiChar(sql), nil, nil, @err);
  if err <> nil then errOut := AnsiString(err);
  sqlite3_close(db);
end;

procedure RunC(const sql: AnsiString; var rc: i32; var errOut: AnsiString);
var
  db: Pcsq_db;
  err: PChar;
begin
  db := nil; err := nil; rc := SQLITE_OK; errOut := '';
  if csq_open(':memory:', db) <> 0 then begin rc := -1; Exit; end;
  rc := csq_exec(db, PAnsiChar(sql), nil, nil, err);
  if err <> nil then errOut := AnsiString(err);
  csq_close(db);
end;

procedure Probe(const label_, sql: AnsiString);
var
  cRc, pRc: i32;
  cErr, pErr: AnsiString;
begin
  RunC(sql, cRc, cErr);
  RunPas(sql, pRc, pErr);
  if (cRc = pRc) and (cErr = pErr) then begin
    Inc(gPass);
    WriteLn('  PASS  ', label_, '  rc=', cRc);
  end else begin
    Inc(gDiverge);
    WriteLn('  DIVERGE ', label_);
    WriteLn('    C   rc=', cRc, ' err="', cErr, '"');
    WriteLn('    Pas rc=', pRc, ' err="', pErr, '"');
  end;
end;

procedure RunPasQ(const sql: AnsiString; var rc: i32; var v: Int64;
                  var nrow: Int32);
var
  db: PTsqlite3;
  st: PVdbe;
begin
  db := nil; rc := -1; v := -99999; nrow := 0;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  rc := sqlite3_exec(db, PAnsiChar(sql), nil, nil, nil);
  st := nil;
  if sqlite3_prepare_v2(db, 'SELECT a FROM t ORDER BY a', -1,
                        @st, nil) = 0 then begin
    while sqlite3_step(st) = SQLITE_ROW do begin
      v := sqlite3_column_int64(st, 0); Inc(nrow);
    end;
    sqlite3_finalize(st);
  end;
  sqlite3_close(db);
end;

procedure RunCQ(const sql: AnsiString; var rc: i32; var v: Int64;
                var nrow: Int32);
var
  db: Pcsq_db;
  st: Pcsq_stmt;
  pTail, errC: PChar;
begin
  db := nil; rc := -1; v := -99999; nrow := 0; errC := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  rc := csq_exec(db, PAnsiChar(sql), nil, nil, errC);
  st := nil; pTail := nil;
  if csq_prepare_v2(db, 'SELECT a FROM t ORDER BY a', -1, st, pTail) = 0
  then begin
    while csq_step(st) = SQLITE_ROW do begin
      v := csq_column_int64(st, 0); Inc(nrow);
    end;
    csq_finalize(st);
  end;
  csq_close(db);
end;

procedure ProbeQ(const label_, sql: AnsiString);
var
  cRc, pRc, cN, pN: Int32;
  cV, pV: Int64;
begin
  RunCQ(sql, cRc, cV, cN);
  RunPasQ(sql, pRc, pV, pN);
  if (cRc = pRc) and (cV = pV) and (cN = pN) then begin
    Inc(gPass);
    WriteLn('  PASS  ', label_, ' rc=', cRc, ' nrow=', cN, ' v=', cV);
  end else begin
    Inc(gDiverge);
    WriteLn('  DIVERGE ', label_);
    WriteLn('    C   rc=', cRc, ' nrow=', cN, ' v=', cV);
    WriteLn('    Pas rc=', pRc, ' nrow=', pN, ' v=', pV);
  end;
end;

begin
  WriteLn('=== DiagDropTable — Phase 6.11 runtime probe ===');
  Probe('drop+reselect',
    'CREATE TABLE t(a,b); INSERT INTO t VALUES(1,2); ' +
    'DROP TABLE t; SELECT * FROM t;');
  Probe('drop+recreate',
    'CREATE TABLE t(a,b); INSERT INTO t VALUES(1,2); ' +
    'DROP TABLE t; CREATE TABLE t(x,y);');
  Probe('drop+recreate+insert',
    'CREATE TABLE t(a,b); INSERT INTO t VALUES(1,2); ' +
    'DROP TABLE t; CREATE TABLE t(x,y); INSERT INTO t VALUES(3,4);');
  Probe('drop only',
    'CREATE TABLE t(a,b); INSERT INTO t VALUES(1,2); DROP TABLE t;');
  Probe('drop+select schema',
    'CREATE TABLE t(a,b); DROP TABLE t; ' +
    'SELECT count(*) FROM sqlite_master WHERE name=''t'';');
  Probe('drop indexed',
    'CREATE TABLE t(a,b); CREATE INDEX i ON t(a); ' +
    'INSERT INTO t VALUES(1,2); DROP TABLE t; CREATE TABLE t(x);');
  ProbeQ('recreate-then-insert content',
    'CREATE TABLE t(a,b); INSERT INTO t VALUES(1,2),(3,4); ' +
    'DROP TABLE t; CREATE TABLE t(a,b); INSERT INTO t VALUES(99,0);');
  ProbeQ('drop two tables, one survives',
    'CREATE TABLE x(a); INSERT INTO x VALUES(7); ' +
    'CREATE TABLE t(a,b); INSERT INTO t VALUES(1,2); ' +
    'DROP TABLE x; INSERT INTO t VALUES(5,6);');
  ProbeQ('drop indexed table then recreate+insert',
    'CREATE TABLE t(a,b); CREATE INDEX i ON t(a); ' +
    'INSERT INTO t VALUES(11,22); DROP TABLE t; ' +
    'CREATE TABLE t(a,b); INSERT INTO t VALUES(33,44);');
  WriteLn;
  WriteLn('Results: ', gPass, ' pass, ', gDiverge, ' diverge');
  if gDiverge > 0 then Halt(1);
end.
