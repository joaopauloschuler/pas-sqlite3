{
  SPDX-License-Identifier: blessing

  Pascal port of SQLite — DiagIndexing probe.
  Surveys CREATE INDEX / DROP INDEX / partial indexes / expression
  indexes / unique constraint enforcement / INDEXED BY hint /
  schema introspection that other Diag* probes do not exercise.

  Goal: surface previously-unknown silent-result divergences.
}
{$I ../passqlite3.inc}
program DiagIndexing;

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
  Seed1 = 'CREATE TABLE t(a INTEGER, b TEXT);' +
          'INSERT INTO t VALUES(1,''x'');' +
          'INSERT INTO t VALUES(2,''y'');' +
          'INSERT INTO t VALUES(3,''z'');';

  // For UNIQUE / CREATE INDEX prep tests
  SeedIdx = 'CREATE TABLE t(a INTEGER, b TEXT);' +
            'CREATE INDEX ix_t_a ON t(a);' +
            'INSERT INTO t VALUES(1,''x'');' +
            'INSERT INTO t VALUES(2,''y'');';

  SeedUniq = 'CREATE TABLE t(a INTEGER UNIQUE, b TEXT);' +
             'INSERT INTO t VALUES(1,''x'');' +
             'INSERT INTO t VALUES(2,''y'');';

begin
  // --- CREATE INDEX schema-row checks ---
  Probe('schema after create idx', SeedIdx,
    'SELECT type, name, tbl_name FROM sqlite_schema ORDER BY rowid');

  // --- Query that should use the index (result-set parity, not bytecode) ---
  Probe('select via idx',          SeedIdx,
    'SELECT b FROM t WHERE a = 2');
  Probe('select range via idx',    SeedIdx,
    'SELECT b FROM t WHERE a >= 1 AND a <= 2 ORDER BY a');

  // --- UNIQUE constraint enforcement ---
  Probe('unique violation',        SeedUniq,
    'INSERT INTO t VALUES(1,''dup'')');
  Probe('unique ok new',           SeedUniq,
    'INSERT INTO t VALUES(3,''ok'')');

  // --- Partial index (WHERE clause on index) ---
  Probe('partial idx create',      Seed1,
    'CREATE INDEX ix_t_part ON t(a) WHERE b=''y''');

  // --- Expression index ---
  Probe('expr idx create',         Seed1,
    'CREATE INDEX ix_t_expr ON t(a*2)');

  // --- DROP INDEX ---
  Probe('drop idx then list',      SeedIdx + 'DROP INDEX ix_t_a;',
    'SELECT name FROM sqlite_schema WHERE type=''index''');

  // --- INDEXED BY / NOT INDEXED ---
  Probe('indexed by ok',           SeedIdx,
    'SELECT b FROM t INDEXED BY ix_t_a WHERE a=1');
  Probe('not indexed',             SeedIdx,
    'SELECT b FROM t NOT INDEXED WHERE a=1');

  // --- ROWID + IPK alias edges (DiagTxn covers AUTO; this is read side) ---
  Probe('rowid select',            Seed1,
    'SELECT rowid, a FROM t ORDER BY rowid');
  Probe('rowid alias custom',
    'CREATE TABLE u(id INTEGER PRIMARY KEY, x);' +
    'INSERT INTO u VALUES(7,''a'');' +
    'INSERT INTO u VALUES(9,''b'');',
    'SELECT id, x FROM u ORDER BY id');

  // --- INSERT with column list reorder ---
  Probe('insert col reorder',
    'CREATE TABLE r(a, b, c);' +
    'INSERT INTO r(c,a,b) VALUES(3,1,2);',
    'SELECT a,b,c FROM r');

  // --- INSERT with missing column gets NULL ---
  Probe('insert missing col null',
    'CREATE TABLE m(a, b, c);' +
    'INSERT INTO m(a) VALUES(1);',
    'SELECT a, b IS NULL, c IS NULL FROM m');

  // --- Affinity round-trip ---
  Probe('affinity int store',
    'CREATE TABLE af(a INTEGER);' +
    'INSERT INTO af VALUES(''42'');',
    'SELECT a, typeof(a) FROM af');
  Probe('affinity text store',
    'CREATE TABLE af(a TEXT);' +
    'INSERT INTO af VALUES(42);',
    'SELECT a, typeof(a) FROM af');
  Probe('affinity real store',
    'CREATE TABLE af(a REAL);' +
    'INSERT INTO af VALUES(42);',
    'SELECT a, typeof(a) FROM af');
  Probe('affinity blob keeps',
    'CREATE TABLE af(a BLOB);' +
    'INSERT INTO af VALUES(42);',
    'SELECT typeof(a) FROM af');
  Probe('affinity numeric int',
    'CREATE TABLE af(a NUMERIC);' +
    'INSERT INTO af VALUES(''42'');',
    'SELECT a, typeof(a) FROM af');
  Probe('affinity numeric real',
    'CREATE TABLE af(a NUMERIC);' +
    'INSERT INTO af VALUES(''42.5'');',
    'SELECT a, typeof(a) FROM af');

  // --- Type conversion via CAST in INSERT ---
  Probe('cast int as text',        '',
    'SELECT CAST(42 AS TEXT)');
  Probe('cast text as int',        '',
    'SELECT CAST(''42abc'' AS INTEGER)');
  Probe('cast text as real',       '',
    'SELECT CAST(''3.14xyz'' AS REAL)');
  Probe('cast null as int',        '',
    'SELECT CAST(null AS INTEGER)');

  // --- typeof / quote edge cases ---
  Probe('typeof null',             '', 'SELECT typeof(null)');
  Probe('typeof empty blob',       '', 'SELECT typeof(x'''')');
  Probe('quote int',               '', 'SELECT quote(42)');
  Probe('quote text quote',        '', 'SELECT quote(''a''''b'')');
  Probe('quote blob',              '', 'SELECT quote(x''41420A'')');
  Probe('quote null',              '', 'SELECT quote(null)');
  Probe('quote real',              '', 'SELECT quote(1.5)');

  // --- BLOB literal round-trip ---
  Probe('hex literal',             '', 'SELECT length(x''DEADBEEF'')');
  Probe('hex literal val',         '', 'SELECT hex(x''DEADBEEF'')');
  Probe('empty hex',               '', 'SELECT length(x'''')');

  // --- length() of different types ---
  Probe('length text',             '', 'SELECT length(''hello'')');
  Probe('length int',              '', 'SELECT length(12345)');
  Probe('length real',             '', 'SELECT length(3.14)');
  Probe('length null',             '', 'SELECT length(null)');
  Probe('length blob',             '', 'SELECT length(x''0102030405'')');
  Probe('length unicode',          '', 'SELECT length(''café'')');
  Probe('octet_length unicode',    '', 'SELECT octet_length(''café'')');
  Probe('octet_length null',       '', 'SELECT octet_length(null)');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
