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
  DiagWindow — exploratory probe for window-function and aggregate edge
  cases (row_number, rank, sum() OVER, FILTER, DISTINCT in agg, HAVING,
  ORDER BY in aggregate).  Goal: surface bugs not yet captured in
  tasklist.md.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagWindow.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagWindow
}
program DiagWindow;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure PasRunSeed(const seed, sql: AnsiString;
                     out prepRc, stepRc: i32;
                     out concat: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs, ncols, i: i32;
  zT: PAnsiChar;
  s: AnsiString;
begin
  prepRc := -1; stepRc := -1; concat := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  if seed <> '' then
    sqlite3_exec(db, PAnsiChar(seed), nil, nil, nil{%H-});
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    repeat
      rcs := sqlite3_step(pStmt);
      stepRc := rcs;
      if rcs = SQLITE_ROW then begin
        ncols := sqlite3_column_count(pStmt);
        s := '[';
        for i := 0 to ncols - 1 do begin
          if i > 0 then s := s + ',';
          zT := PAnsiChar(sqlite3_column_text(pStmt, i));
          if zT = nil then s := s + 'null'
          else s := s + AnsiString(zT);
        end;
        s := s + ']';
        if concat <> '' then concat := concat + ';';
        concat := concat + s;
      end;
    until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRunSeed(const seed, sql: AnsiString;
                   out prepRc, stepRc: i32;
                   out concat: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rcs, ncols, i: Int32;
  zT: PChar;
  s: AnsiString;
  pErr: PChar;
begin
  prepRc := -1; stepRc := -1; concat := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pErr := nil;
  if seed <> '' then
    csq_exec(db, PAnsiChar(seed), nil, nil, pErr);
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    repeat
      rcs := csq_step(pStmt);
      stepRc := rcs;
      if rcs = SQLITE_ROW then begin
        ncols := csq_column_count(pStmt);
        s := '[';
        for i := 0 to ncols - 1 do begin
          if i > 0 then s := s + ',';
          zT := csq_column_text(pStmt, i);
          if zT = nil then s := s + 'null'
          else s := s + AnsiString(zT);
        end;
        s := s + ']';
        if concat <> '' then concat := concat + ';';
        concat := concat + s;
      end;
    until rcs <> SQLITE_ROW;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure Probe(const lbl, seed, sql: AnsiString);
var
  pPrep, pStep, cPrep, cStep: i32;
  pCat, cCat: AnsiString;
  ok: Boolean;
begin
  PasRunSeed(seed, sql, pPrep, pStep, pCat);
  CRunSeed  (seed, sql, cPrep, cStep, cCat);
  ok := (pPrep = cPrep) and (pStep = cStep) and (pCat = cCat);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql  =', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep, ' rows="', pCat, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep, ' rows="', cCat, '"');
  end;
end;

const
  Seed1 = 'CREATE TABLE t(a INTEGER, b INTEGER);' +
          'INSERT INTO t VALUES(1,10);' +
          'INSERT INTO t VALUES(2,20);' +
          'INSERT INTO t VALUES(3,30);';

  Seed2 = 'CREATE TABLE g(grp TEXT, val INTEGER);' +
          'INSERT INTO g VALUES(''A'',1);' +
          'INSERT INTO g VALUES(''A'',2);' +
          'INSERT INTO g VALUES(''B'',3);' +
          'INSERT INTO g VALUES(''B'',4);' +
          'INSERT INTO g VALUES(''B'',5);';

begin
  // --- Window functions: row_number / rank / dense_rank ---
  Probe('row_number basic',  Seed1,
    'SELECT a, row_number() OVER (ORDER BY a) FROM t');
  Probe('rank basic',        Seed1,
    'SELECT a, rank() OVER (ORDER BY a) FROM t');
  Probe('dense_rank',        Seed1,
    'SELECT a, dense_rank() OVER (ORDER BY a) FROM t');

  // --- Window aggregates ---
  Probe('sum() OVER all',    Seed1,
    'SELECT a, sum(b) OVER () FROM t');
  Probe('sum() running',     Seed1,
    'SELECT a, sum(b) OVER (ORDER BY a) FROM t');
  Probe('avg() OVER',        Seed1,
    'SELECT avg(b) OVER () FROM t');

  // --- PARTITION BY ---
  Probe('partition row_num', Seed2,
    'SELECT grp, val, row_number() OVER (PARTITION BY grp ORDER BY val) FROM g');
  Probe('partition sum',     Seed2,
    'SELECT grp, sum(val) OVER (PARTITION BY grp) FROM g');

  // --- LAG / LEAD ---
  Probe('lag basic',         Seed1,
    'SELECT a, lag(b,1,0) OVER (ORDER BY a) FROM t');
  Probe('lead basic',        Seed1,
    'SELECT a, lead(b,1,0) OVER (ORDER BY a) FROM t');

  // --- FIRST_VALUE / LAST_VALUE / NTH_VALUE ---
  Probe('first_value',       Seed1,
    'SELECT first_value(b) OVER (ORDER BY a) FROM t');
  Probe('ntile 2',           Seed1,
    'SELECT ntile(2) OVER (ORDER BY a) FROM t');

  // --- Aggregate with FILTER ---
  Probe('count filter',      Seed1,
    'SELECT count(*) FILTER (WHERE a>1) FROM t');
  Probe('sum filter',        Seed1,
    'SELECT sum(b) FILTER (WHERE a>1) FROM t');

  // --- DISTINCT in aggregate ---
  Probe('count distinct',    Seed2,
    'SELECT count(DISTINCT grp) FROM g');
  Probe('sum distinct',      Seed2,
    'SELECT sum(DISTINCT val) FROM g');

  // --- GROUP BY + HAVING ---
  Probe('group having',      Seed2,
    'SELECT grp, sum(val) FROM g GROUP BY grp HAVING sum(val) > 5');
  Probe('group order',       Seed2,
    'SELECT grp, sum(val) FROM g GROUP BY grp ORDER BY grp DESC');

  // --- group_concat with ORDER BY ---
  Probe('group_concat',      Seed2,
    'SELECT group_concat(val,'','') FROM g WHERE grp=''A''');
  Probe('group_concat order',Seed2,
    'SELECT group_concat(val,'','' ORDER BY val DESC) FROM g WHERE grp=''B''');

  // --- min/max with non-trivial input ---
  Probe('min agg',           Seed2, 'SELECT min(val) FROM g');
  Probe('max agg',           Seed2, 'SELECT max(val) FROM g');
  Probe('total agg',         Seed2, 'SELECT total(val) FROM g');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
