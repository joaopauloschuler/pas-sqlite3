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
  (see commit history).
}
{$I ../passqlite3.inc}
program TestFts3BuildPerf;

{
  Task 12.4.1 — FTS3/4 segment-merge build-performance micro-bench.

  Inserts N=100 and N=1000 documents into an FTS4 table, timing ms/row for
  the port, and (via the perf counters in passqlite3fts3.pas) reporting, per
  INSERT:
    * sqlite3Fts3PendingTermsFlush() invocations
    * %_segdir write-statement requests (REPLACE/DELETE/UPDATE)
    * actual SQL prepares (fts3SqlStmt cache misses)
  It also times the C oracle (../sqlite3/sqlite3) doing the identical inserts
  for the ms/row baseline, and verifies on-disk parity: integrity-check passes
  and the term/doclist content (via fts4aux) matches the oracle.

  Exit 0 = PASS (parity preserved). Perf numbers are printed for the human /
  tasklist record; the test does not FAIL on a slow ms/row by itself.
}

uses
  ctypes,
  SysUtils,
  StrUtils,
  Strings,
  Process,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3main,
  passqlite3fts3;

var
  g_fail: Integer = 0;

procedure Check(cond: Boolean; const msg: string);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(g_fail);
  end;
end;

procedure ExecOK(db: PTsqlite3; const zSql: string; const what: string);
var
  rc: i32;
  zErr: PAnsiChar;
begin
  zErr := nil;
  rc := sqlite3_exec(db, PAnsiChar(zSql), nil, nil, @zErr);
  Check(rc = SQLITE_OK, what + ' (rc=' + IntToStr(rc) + ')');
  if zErr <> nil then begin
    if rc <> SQLITE_OK then WriteLn('   exec err: ', zErr);
    sqlite3_free(zErr);
  end;
end;

{ Run a query, joining each row's columns with '|' and rows with ';'. }
function QueryRows(db: PTsqlite3; const zSql: string): string;
var
  pStmt: Pointer;
  rc, i, n: i32;
  z: PAnsiChar;
  row: string;
begin
  Result := '';
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin
    WriteLn('   prepare err: ', sqlite3_errmsg(db), '  sql=', zSql);
    Result := 'ERR'; Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    n := sqlite3_column_count(pStmt);
    row := '';
    for i := 0 to n - 1 do begin
      if i > 0 then row := row + '|';
      z := sqlite3_column_text(pStmt, i);
      if z <> nil then row := row + StrPas(z);
    end;
    if Result <> '' then Result := Result + ';';
    Result := Result + row;
  end;
  sqlite3_finalize(pStmt);
end;

{ Deterministic pseudo-document of nWords tokens drawn from a small fixed
  vocabulary, so terms recur across rows (a realistic FTS build workload). }
function MakeDoc(seed, nWords: Integer): string;
const
  Vocab: array[0..15] of string = (
    'alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf',
    'hotel', 'india', 'juliet', 'kilo', 'lima', 'mike', 'november',
    'oscar', 'papa');
var
  i, r: Integer;
begin
  Result := '';
  r := seed * 2654435761;  { Knuth multiplicative hash, wraps on 32-bit }
  for i := 0 to nWords - 1 do begin
    r := (r * 1103515245 + 12345) and $7fffffff;
    if i > 0 then Result := Result + ' ';
    Result := Result + Vocab[(r shr 8) and 15];
  end;
end;

{ Insert N rows into FTS4 table 't' on db, return elapsed milliseconds. }
function RunInserts(db: PTsqlite3; N, nWords: Integer): Double;
var
  i: Integer;
  t0, t1: TDateTime;
  doc: string;
begin
  t0 := Now;
  for i := 1 to N do begin
    doc := MakeDoc(i, nWords);
    ExecOK(db, 'INSERT INTO t(content) VALUES(''' + doc + ''')',
      'ins ' + IntToStr(i));
  end;
  t1 := Now;
  Result := (t1 - t0) * 24 * 60 * 60 * 1000;  { days -> ms }
end;

{ Write a script to a temp .sql file and run the oracle reading it from
  stdin (via sh -c redirection, so embedded dot-commands work). }
function OracleRunScript(const script: string; out outp: AnsiString): Boolean;
var
  fn: string;
  f: TextFile;
begin
  fn := GetTempDir + 'pas_fts3perf_' + IntToStr(GetProcessID) + '.sql';
  AssignFile(f, fn);
  Rewrite(f);
  Write(f, script);
  CloseFile(f);
  outp := '';
  Result := RunCommand('/bin/sh',
    ['-c', '../sqlite3/sqlite3 :memory: < ' + fn], outp);
  DeleteFile(fn);
end;

{ Time the C oracle doing the same N inserts, returning ms/row (or -1). }
function OracleMsPerRow(N, nWords: Integer): Double;
var
  script: string;
  i: Integer;
  t0, t1: TDateTime;
  outp: AnsiString;
begin
  Result := -1;
  { No explicit transaction: each insert autocommits, so the oracle flushes
    pending terms each row too -- mirrors the port's autocommit inserts. }
  script := 'CREATE VIRTUAL TABLE t USING fts4(content);' + #10;
  for i := 1 to N do
    script := script + 'INSERT INTO t(content) VALUES(''' +
              MakeDoc(i, nWords) + ''');' + #10;
  t0 := Now;
  if not OracleRunScript(script, outp) then Exit;
  t1 := Now;
  Result := ((t1 - t0) * 24 * 60 * 60 * 1000) / N;
end;

{ Reference fts4aux content (term|documents|occurrences;...) from the oracle
  for the same N inserts, for on-disk/content parity. }
function OracleAuxContent(N, nWords: Integer): string;
var
  script: string;
  i: Integer;
  outp: AnsiString;
begin
  script := 'CREATE VIRTUAL TABLE t USING fts4(content);' + #10;
  for i := 1 to N do
    script := script + 'INSERT INTO t(content) VALUES(''' +
              MakeDoc(i, nWords) + ''');' + #10;
  script := script + 'CREATE VIRTUAL TABLE terms USING fts4aux(t);' + #10 +
            '.mode list' + #10 + '.separator "|"' + #10 +
            'SELECT term, documents, occurrences FROM terms WHERE col=''*'';' + #10;
  if not OracleRunScript(script, outp) then Exit('ORACLE_ERR');
  outp := StringReplace(Trim(string(outp)), #13, '', [rfReplaceAll]);
  Result := StringReplace(string(outp), #10, '', [rfReplaceAll]);
end;

{ Run the port over N inserts on a fresh in-memory db, print the perf line,
  and return ms/row + the perf counters. }
procedure BenchPort(N, nWords: Integer; out msPerRow: Double;
  out flushes, segdir, prepares: Int64);
var
  db: PTsqlite3;
  rc: i32;
  ms: Double;
begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Check(rc = SQLITE_OK, 'open :memory:');
  ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(content)', 'create fts4');
  fts3PerfReset;
  ms := RunInserts(db, N, nWords);
  flushes  := gFts3PerfFlushCalls;
  segdir   := gFts3PerfSegdirOps;
  prepares := gFts3PerfPrepares;
  msPerRow := ms / N;
  { integrity-check: on-disk structure must be sound }
  ExecOK(db, 'INSERT INTO t(t) VALUES(''integrity-check'')',
    'integrity-check N=' + IntToStr(N));
  sqlite3_close(db);
end;

{ Content-parity: port fts4aux output must equal the oracle's. }
function PortAuxContent(N, nWords: Integer): string;
var
  db: PTsqlite3;
  rc: i32;
  i: Integer;
begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Check(rc = SQLITE_OK, 'open :memory: aux');
  ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(content)', 'create fts4 aux');
  for i := 1 to N do
    ExecOK(db, 'INSERT INTO t(content) VALUES(''' + MakeDoc(i, nWords) + ''')',
      'ins aux ' + IntToStr(i));
  ExecOK(db, 'CREATE VIRTUAL TABLE terms USING fts4aux(t)', 'create fts4aux');
  Result := QueryRows(db,
    'SELECT term, documents, occurrences FROM terms WHERE col=''*''');
  Result := StringReplace(Result, ';', '', [rfReplaceAll]);
  sqlite3_close(db);
end;

const
  NWORDS = 20;

procedure RunOne(N: Integer);
var
  msPort, msOracle, ratio: Double;
  flushes, segdir, prepares: Int64;
  portAux, oraAux: string;
begin
  BenchPort(N, NWORDS, msPort, flushes, segdir, prepares);
  msOracle := OracleMsPerRow(N, NWORDS);
  WriteLn(Format('N=%-5d  port=%7.3f ms/row   oracle=%7.3f ms/row   ratio=%5.2fx',
    [N, msPort, msOracle, msPort / msOracle]));
  WriteLn(Format('         per-INSERT: flushes=%.3f  segdir-ops=%.3f  prepares=%.3f  (totals: %d/%d/%d)',
    [flushes / N, segdir / N, prepares / N, flushes, segdir, prepares]));
  { content / on-disk parity vs oracle }
  portAux := PortAuxContent(N, NWORDS);
  oraAux := OracleAuxContent(N, NWORDS);
  Check(portAux = oraAux, 'fts4aux content parity N=' + IntToStr(N));
  if portAux <> oraAux then begin
    WriteLn('   port=', Copy(portAux, 1, 120));
    WriteLn('   ora =', Copy(oraAux, 1, 120));
  end;
  if msOracle > 0 then begin
    ratio := msPort / msOracle;
    WriteLn(Format('         DoD ratio <= 3x : %s (%.2fx)',
      [BoolToStr(ratio <= 3.0, 'PASS', 'OVER'), ratio]));
  end;
end;

begin
  WriteLn('=== TestFts3BuildPerf (task 12.4) ===');
  sqlite3_initialize;
  RunOne(100);
  RunOne(1000);
  WriteLn;
  if g_fail = 0 then
    WriteLn('PASS (parity preserved)')
  else
    WriteLn('FAIL: ', g_fail, ' check(s) failed');
  Halt(Ord(g_fail <> 0));
end.
