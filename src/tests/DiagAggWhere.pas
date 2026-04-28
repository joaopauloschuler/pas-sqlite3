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
  DiagAggWhere — bytecode diff probe for tasklist 6.10 step 7(c).
  Dumps Pas + C VDBE for SELECT count(*) FROM t WHERE a IS NULL
  to localise where the aggregate-with-WHERE codegen path diverges.
}
program DiagAggWhere;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

procedure DumpPas(const ddl, sql: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs, i: i32;
  pop: PVdbeOp;
  nm: PAnsiChar;
begin
  WriteLn('=== Pas: ', sql);
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  pStmt := nil; pTail := nil;
  if (sqlite3_prepare_v2(db, PAnsiChar(ddl), -1, @pStmt, @pTail) = 0)
     and (pStmt <> nil) then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
  pStmt := nil; pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if pStmt = nil then begin WriteLn('  prepare rc=', rcs); sqlite3_close(db); Exit; end;
  for i := 0 to pStmt^.nOp - 1 do begin
    pop := PVdbeOp(PtrUInt(pStmt^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    nm  := sqlite3OpcodeName(pop^.opcode);
    WriteLn('  [', i, '] ', AnsiString(nm),
            ' p1=', pop^.p1, ' p2=', pop^.p2, ' p3=', pop^.p3,
            ' p5=', pop^.p5);
  end;
  sqlite3_finalize(pStmt);
  sqlite3_close(db);
end;

procedure DumpC(const ddl, sql: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail, pErr: PAnsiChar;
  rcs, i, n: Int32;
  exp: AnsiString;
  txt: PAnsiChar;
begin
  WriteLn('=== C  : ', sql);
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pErr := nil;
  csq_exec(db, PAnsiChar(ddl), nil, nil, pErr);
  exp := 'EXPLAIN ' + sql;
  pStmt := nil; pTail := nil;
  rcs := csq_prepare_v2(db, PAnsiChar(exp), -1, pStmt, pTail);
  if pStmt = nil then begin WriteLn('  prepare rc=', rcs); csq_close(db); Exit; end;
  i := 0;
  while csq_step(pStmt) = SQLITE_ROW do begin
    n := csq_column_int(pStmt, 0);
    txt := csq_column_text(pStmt, 1);
    WriteLn('  [', n, '] ', AnsiString(txt),
            ' p1=', csq_column_int(pStmt, 2),
            ' p2=', csq_column_int(pStmt, 3),
            ' p3=', csq_column_int(pStmt, 4),
            ' p5=', csq_column_int(pStmt, 6));
    Inc(i);
  end;
  csq_finalize(pStmt);
  csq_close(db);
end;

procedure Compare(const ddl, sql: AnsiString);
begin
  WriteLn('--- ', sql);
  DumpPas(ddl, sql);
  DumpC  (ddl, sql);
  WriteLn;
end;

begin
  Compare('CREATE TABLE t(a)',
          'SELECT count(*) FROM t');
  Compare('CREATE TABLE t(a)',
          'SELECT count(*) FROM t WHERE a IS NULL');
end.
