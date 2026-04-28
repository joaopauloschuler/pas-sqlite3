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
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
{$I ../passqlite3.inc}
{
  DiagSubsel — dump bytecode for `SELECT (SELECT a FROM t)` after
  populating t with INSERT INTO t VALUES(42).  Pas returns 0; C returns 42.
}
program DiagSubsel;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

const
  SETUP = 'CREATE TABLE t(a); INSERT INTO t VALUES(42);';
  QRY   = 'SELECT (SELECT a FROM t)';

procedure DumpPas;
var
  db: PTsqlite3;
  pStmt: PVdbe;
  v: PVdbe;
  i: i32;
  pop: PVdbeOp;
  nm: PAnsiChar;
  rc: i32;
  errMsg: PAnsiChar;
begin
  WriteLn('--- Pas: ', QRY);
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin WriteLn('open fail'); Exit; end;
  errMsg := nil;
  rc := sqlite3_exec(db, SETUP, nil, nil, @errMsg);
  if rc <> 0 then begin
    WriteLn('setup rc=', rc);
    if errMsg <> nil then WriteLn('  err=', AnsiString(errMsg));
    sqlite3_close(db); Exit;
  end;
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(QRY), -1, @pStmt, nil);
  if (rc <> 0) or (pStmt = nil) then begin
    WriteLn('prepare rc=', rc);
    sqlite3_close(db); Exit;
  end;
  v := pStmt;
  WriteLn('  nOp=', v^.nOp);
  for i := 0 to v^.nOp - 1 do begin
    pop := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    nm := sqlite3OpcodeName(pop^.opcode);
    WriteLn(Format('  [%2d] %-14s p1=%-3d p2=%-3d p3=%-3d p5=%-3d',
                 [i, AnsiString(nm), pop^.p1, pop^.p2, pop^.p3, pop^.p5]));
  end;
  rc := sqlite3_step(v);
  WriteLn('  step rc=', rc);
  if rc = 100 then
    WriteLn('  col0=', sqlite3_column_int(v, 0));
  sqlite3_finalize(v);
  sqlite3_close(db);
end;

procedure DumpC;
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rc: i32;
  i, n: i32;
  expSql: AnsiString;
  zRow: PAnsiChar;
  errMsg: PAnsiChar;
begin
  WriteLn('--- C  : ', QRY);
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  errMsg := nil;
  rc := csq_exec(db, SETUP, nil, nil, errMsg);
  if rc <> 0 then begin WriteLn('setup rc=', rc); csq_close(db); Exit; end;
  pStmt := nil;
  pTail := nil;
  expSql := 'EXPLAIN ' + QRY;
  rc := csq_prepare_v2(db, PAnsiChar(expSql), -1, pStmt, pTail);
  if (rc <> 0) or (pStmt = nil) then begin
    WriteLn('prepare rc=', rc); csq_close(db); Exit;
  end;
  i := 0;
  while csq_step(pStmt) = 100 do begin
    n := csq_column_count(pStmt);
    Write('  [', i, '] ');
    if n >= 2 then begin
      zRow := csq_column_text(pStmt, 1);
      Write(Format('%-14s ', [AnsiString(zRow)]));
    end;
    if n >= 6 then begin
      Write('p1=', csq_column_int(pStmt, 2),
            ' p2=', csq_column_int(pStmt, 3),
            ' p3=', csq_column_int(pStmt, 4));
      zRow := csq_column_text(pStmt, 5);
      if (zRow <> nil) and (zRow^ <> #0) then
        Write(' p4=', AnsiString(zRow));
      Write(' p5=', csq_column_int(pStmt, 6));
    end;
    WriteLn;
    Inc(i);
  end;
  csq_finalize(pStmt);
  csq_close(db);
end;

begin
  DumpPas;
  WriteLn;
  DumpC;
end.
