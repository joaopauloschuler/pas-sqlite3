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
  DiagCollate — dump bytecode for the COLLATE NOCASE compare.
  Compares the OP_Eq emitted by Pas vs C for
    SELECT 'ABC' = 'abc' COLLATE NOCASE
}
program DiagCollate;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

procedure DumpPas(const sql: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  v: PVdbe;
  i: i32;
  pop: PVdbeOp;
  nm: PAnsiChar;
  rc: i32;
begin
  WriteLn('--- Pas: ', sql);
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin WriteLn('open fail'); Exit; end;
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if (rc <> 0) or (pStmt = nil) then begin
    WriteLn('prepare rc=', rc);
    sqlite3_close(db); Exit;
  end;
  v := pStmt;
  for i := 0 to v^.nOp - 1 do begin
    pop := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    nm := sqlite3OpcodeName(pop^.opcode);
    Write(Format('  [%d] %-12s p1=%-3d p2=%-3d p3=%-3d p5=%-3d p4t=%d',
                 [i, AnsiString(nm), pop^.p1, pop^.p2, pop^.p3, pop^.p5,
                  pop^.p4type]));
    if pop^.p4type = P4_COLLSEQ then begin
      if pop^.p4.pColl <> nil then
        Write(' p4=COLLSEQ(', AnsiString(PTCollSeq(pop^.p4.pColl)^.zName), ')')
      else
        Write(' p4=COLLSEQ(nil)');
    end else if pop^.p4type = P4_DYNAMIC then begin
      if pop^.p4.z <> nil then
        Write(' p4=DYN(', AnsiString(pop^.p4.z), ')');
    end else if pop^.p4type = P4_STATIC then begin
      if pop^.p4.z <> nil then
        Write(' p4=STA(', AnsiString(pop^.p4.z), ')');
    end;
    WriteLn;
  end;
  sqlite3_finalize(v);
  sqlite3_close(db);
end;

procedure DumpC(const sql: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rc: i32;
  i, n: i32;
  expSql: AnsiString;
  zRow: PAnsiChar;
begin
  WriteLn('--- C  : ', sql);
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pStmt := nil;
  pTail := nil;
  expSql := 'EXPLAIN ' + sql;
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
      Write(Format('%-12s ', [AnsiString(zRow)]));
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
  DumpPas('SELECT ''ABC'' = ''abc'' COLLATE NOCASE');
  WriteLn;
  DumpC('SELECT ''ABC'' = ''abc'' COLLATE NOCASE');
end.
