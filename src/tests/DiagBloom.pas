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
  DiagBloom — exploratory probe for the WHERE Bloom-filter optimisation
  (where.c:1273..1390 + 6622..6655) ported to passqlite3codegen.

  Sets up a small "fact JOIN dim" with skewed analyzed row counts, then
  EXPLAINs the join and reports whether the planner emitted the
  OP_Blob / OP_FilterAdd / OP_Filter triple that a Bloom-filter plan
  produces.  The probe is corpus-quiet for now: TestExplainParity does
  not exercise ANALYZE-driven plans, so this is the first place where
  the new sqlite3ConstructBloomFilter body actually executes.

  Build: src/tests/build.sh   (autopicked by the standard list)
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagBloom
}
program DiagBloom;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main;

var
  db: PTsqlite3;
  rc: i32;
  nFilterAdd, nFilter, nBlob: i32;

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
  if rcs <> SQLITE_OK then
    if (rcs <> SQLITE_DONE) and (rcs <> SQLITE_ROW) then
      WriteLn('  [ddl rc=', rcs, '] ', sql);
end;

procedure DumpBytecode(const sql: AnsiString);
var
  pStmt: PVdbe;
  i:     i32;
  pop:   PVdbeOp;
  nm:    PAnsiChar;
  name:  AnsiString;
begin
  WriteLn('=== EXPLAIN ', sql);
  nFilterAdd := 0; nFilter := 0; nBlob := 0;
  pStmt := nil;
  if (sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil) <> 0)
     or (pStmt = nil) then begin
    WriteLn('  prepare failed'); Exit;
  end;
  for i := 0 to pStmt^.nOp - 1 do begin
    pop  := PVdbeOp(PtrUInt(pStmt^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    nm   := sqlite3OpcodeName(pop^.opcode);
    name := AnsiString(nm);
    if name = 'FilterAdd' then Inc(nFilterAdd)
    else if name = 'Filter' then Inc(nFilter)
    else if name = 'Blob' then Inc(nBlob);
    WriteLn('  [', i, '] ', name,
            ' p1=', pop^.p1, ' p2=', pop^.p2, ' p3=', pop^.p3,
            ' p5=', pop^.p5);
  end;
  sqlite3_finalize(pStmt);
end;

procedure ReportTally(const label_: AnsiString);
begin
  WriteLn(label_,
          ': OP_Blob=', nBlob,
          ' OP_FilterAdd=', nFilterAdd,
          ' OP_Filter=', nFilter);
end;

var
  i: i32;
  buf: AnsiString;

begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if rc <> 0 then begin WriteLn('open rc=', rc); Halt(1); end;

  RunDdl('CREATE TABLE dim(k INTEGER PRIMARY KEY, v)');
  RunDdl('CREATE TABLE fact(k INTEGER, val INTEGER)');

  for i := 1 to 8 do begin
    Str(i, buf);
    RunDdl('INSERT INTO dim VALUES(' + buf + ',' + buf + ')');
  end;
  for i := 1 to 200 do begin
    Str((i mod 8) + 1, buf);
    RunDdl('INSERT INTO fact VALUES(' + buf + ',' + buf + ')');
  end;

  { Pre-create sqlite_stat1 (DiagAnalyze workaround for the schema-reload
    gap noted in tasklist 6.27 step "ANALYZE on fresh DB"). }
  RunDdl('CREATE TABLE sqlite_stat1(tbl,idx,stat)');
  RunDdl('ANALYZE');

  WriteLn('--- sqlite_stat1 contents:');
  DumpBytecode('SELECT tbl,idx,stat FROM sqlite_stat1');

  WriteLn;
  WriteLn('--- Inner-join shape (eligible for Bloom on dim):');
  DumpBytecode('SELECT fact.val FROM fact JOIN dim ON dim.k = fact.k');
  ReportTally('inner-join');

  WriteLn;
  WriteLn('--- Single-table baseline (must NOT trigger Bloom):');
  DumpBytecode('SELECT v FROM dim WHERE k = 3');
  ReportTally('single-table');

  WriteLn;
  WriteLn('--- Three-way join (more chances for inner Bloom):');
  RunDdl('CREATE TABLE side(k INTEGER PRIMARY KEY, w)');
  for i := 1 to 4 do begin
    Str(i, buf);
    RunDdl('INSERT INTO side VALUES(' + buf + ',' + buf + ')');
  end;
  RunDdl('ANALYZE');
  DumpBytecode(
    'SELECT fact.val FROM fact ' +
    'JOIN dim  ON dim.k  = fact.k ' +
    'JOIN side ON side.k = dim.k');
  ReportTally('three-way');

  sqlite3_close(db);
end.
