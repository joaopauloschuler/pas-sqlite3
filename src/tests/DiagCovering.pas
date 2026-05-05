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
  DiagCovering — tripwire for the WHERE covering-index pick noted under
  tasklist 6.8.4 (covering-index arm).

  Repro shape from the tasklist note:
      CREATE INDEX i1 ON t(a,b);  SELECT a,b FROM t WHERE a > 0;
  C picks "SEARCH t USING COVERING INDEX i1 (a>?)" — first op after
  Init/Transaction is OpenRead on the index cursor with an SeekGT seek.
  Pas (pre-fix) emitted OpenRead on the table + Rewind, walking every
  row.  This probe asserts the Pas planner now opens the index cursor
  and emits SeekGT, mirroring the existing TestExplainParity coverage
  for shorter shapes (e.g. "SELECT a FROM t WHERE a=5" with i1 ON t(a)).
}
program DiagCovering;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main;

var
  db: PTsqlite3;
  rc: i32;
  nOpenRead, nSeekGT, nIdxGT, nRewind, nColumnIdx: i32;
  divergences: i32;

procedure RunDdl(const sql: AnsiString);
var
  pStmt: PVdbe;
  rcs:   i32;
begin
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
end;

procedure DumpAndTally(const lbl, sql: AnsiString;
                      expectIndexedPlan: Boolean);
var
  pStmt: PVdbe;
  k:     i32;
  pop:   PVdbeOp;
  nm:    PAnsiChar;
  name:  AnsiString;
begin
  WriteLn('=== ', lbl, ' :: ', sql);
  nOpenRead := 0; nSeekGT := 0; nIdxGT := 0; nRewind := 0; nColumnIdx := 0;
  pStmt := nil;
  if (sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil) <> 0)
     or (pStmt = nil) then begin
    WriteLn('  prepare failed'); Inc(divergences); Exit;
  end;
  for k := 0 to pStmt^.nOp - 1 do begin
    pop  := PVdbeOp(PtrUInt(pStmt^.aOp) + PtrUInt(k) * SizeOf(TVdbeOp));
    nm   := sqlite3OpcodeName(pop^.opcode);
    name := AnsiString(nm);
    if name = 'OpenRead' then Inc(nOpenRead)
    else if name = 'SeekGT' then Inc(nSeekGT)
    else if name = 'IdxGT'  then Inc(nIdxGT)
    else if name = 'Rewind' then Inc(nRewind);
    WriteLn('  [', k, '] ', name,
            ' p1=', pop^.p1, ' p2=', pop^.p2, ' p3=', pop^.p3,
            ' p5=', pop^.p5);
  end;
  sqlite3_finalize(pStmt);
  WriteLn('  tally: OpenRead=', nOpenRead, ' SeekGT=', nSeekGT,
          ' IdxGT=', nIdxGT, ' Rewind=', nRewind);
  if expectIndexedPlan then begin
    { An indexed plan opens an index cursor and seeks: either SeekGT (for
      strict-range), SeekGE+IdxGT (for equality / inclusive range), or
      similar.  The diagnostic for failure is OP_Rewind on the table —
      that means the planner picked a heap SCAN. }
    if (nRewind <> 0) or ((nSeekGT = 0) and (nIdxGT = 0)) then begin
      WriteLn('  DIVERGE: expected indexed seek, got Rewind/SCAN');
      Inc(divergences);
    end else
      WriteLn('  PASS    indexed plan picked');
  end;
end;

begin
  divergences := 0;
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if rc <> 0 then begin WriteLn('open rc=', rc); Halt(1); end;

  RunDdl('CREATE TABLE t(a, b, c)');
  RunDdl('CREATE INDEX i1 ON t(a,b)');
  WriteLn('--- Single-col index baseline (matches TestExplainParity case 130):');
  RunDdl('CREATE TABLE u(a, b, c)');
  RunDdl('CREATE INDEX iu ON u(a)');
  DumpAndTally('SELECT a FROM u WHERE a=5 (covering iu(a))',
               'SELECT a FROM u WHERE a = 5',
               True);

  { Canonical repro from tasklist 6.8.4: range scan, covering index. }
  DumpAndTally('range a>0 (covering i1(a,b))',
               'SELECT a,b FROM t WHERE a > 0',
               True);

  { Equality variant — same expectation. }
  DumpAndTally('eq a=4 (covering i1(a,b))',
               'SELECT a,b FROM t WHERE a = 4',
               True);

  WriteLn;
  WriteLn('Total divergences: ', divergences);
  sqlite3_close(db);
  if divergences <> 0 then Halt(1);
end.
