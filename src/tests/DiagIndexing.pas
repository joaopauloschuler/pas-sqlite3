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
  DiagCommon;

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
  ProbeRows('schema after create idx', SeedIdx,
    'SELECT type, name, tbl_name FROM sqlite_schema ORDER BY rowid');

  // --- Query that should use the index (result-set parity, not bytecode) ---
  ProbeRows('select via idx',          SeedIdx,
    'SELECT b FROM t WHERE a = 2');
  ProbeRows('select range via idx',    SeedIdx,
    'SELECT b FROM t WHERE a >= 1 AND a <= 2 ORDER BY a');

  // --- UNIQUE constraint enforcement ---
  ProbeRows('unique violation',        SeedUniq,
    'INSERT INTO t VALUES(1,''dup'')');
  ProbeRows('unique ok new',           SeedUniq,
    'INSERT INTO t VALUES(3,''ok'')');

  // --- Partial index (WHERE clause on index) ---
  ProbeRows('partial idx create',      Seed1,
    'CREATE INDEX ix_t_part ON t(a) WHERE b=''y''');

  // --- Expression index ---
  ProbeRows('expr idx create',         Seed1,
    'CREATE INDEX ix_t_expr ON t(a*2)');

  // --- DROP INDEX ---
  ProbeRows('drop idx then list',      SeedIdx + 'DROP INDEX ix_t_a;',
    'SELECT name FROM sqlite_schema WHERE type=''index''');

  // --- INDEXED BY / NOT INDEXED ---
  ProbeRows('indexed by ok',           SeedIdx,
    'SELECT b FROM t INDEXED BY ix_t_a WHERE a=1');
  ProbeRows('not indexed',             SeedIdx,
    'SELECT b FROM t NOT INDEXED WHERE a=1');

  // --- ROWID + IPK alias edges (DiagTxn covers AUTO; this is read side) ---
  ProbeRows('rowid select',            Seed1,
    'SELECT rowid, a FROM t ORDER BY rowid');
  ProbeRows('rowid alias custom',
    'CREATE TABLE u(id INTEGER PRIMARY KEY, x);' +
    'INSERT INTO u VALUES(7,''a'');' +
    'INSERT INTO u VALUES(9,''b'');',
    'SELECT id, x FROM u ORDER BY id');

  // --- INSERT with column list reorder ---
  ProbeRows('insert col reorder',
    'CREATE TABLE r(a, b, c);' +
    'INSERT INTO r(c,a,b) VALUES(3,1,2);',
    'SELECT a,b,c FROM r');

  // --- INSERT with missing column gets NULL ---
  ProbeRows('insert missing col null',
    'CREATE TABLE m(a, b, c);' +
    'INSERT INTO m(a) VALUES(1);',
    'SELECT a, b IS NULL, c IS NULL FROM m');

  // --- Affinity round-trip ---
  ProbeRows('affinity int store',
    'CREATE TABLE af(a INTEGER);' +
    'INSERT INTO af VALUES(''42'');',
    'SELECT a, typeof(a) FROM af');
  ProbeRows('affinity text store',
    'CREATE TABLE af(a TEXT);' +
    'INSERT INTO af VALUES(42);',
    'SELECT a, typeof(a) FROM af');
  ProbeRows('affinity real store',
    'CREATE TABLE af(a REAL);' +
    'INSERT INTO af VALUES(42);',
    'SELECT a, typeof(a) FROM af');
  ProbeRows('affinity blob keeps',
    'CREATE TABLE af(a BLOB);' +
    'INSERT INTO af VALUES(42);',
    'SELECT typeof(a) FROM af');
  ProbeRows('affinity numeric int',
    'CREATE TABLE af(a NUMERIC);' +
    'INSERT INTO af VALUES(''42'');',
    'SELECT a, typeof(a) FROM af');
  ProbeRows('affinity numeric real',
    'CREATE TABLE af(a NUMERIC);' +
    'INSERT INTO af VALUES(''42.5'');',
    'SELECT a, typeof(a) FROM af');

  // --- Type conversion via CAST in INSERT ---
  ProbeRows('cast int as text',        '',
    'SELECT CAST(42 AS TEXT)');
  ProbeRows('cast text as int',        '',
    'SELECT CAST(''42abc'' AS INTEGER)');
  ProbeRows('cast text as real',       '',
    'SELECT CAST(''3.14xyz'' AS REAL)');
  ProbeRows('cast null as int',        '',
    'SELECT CAST(null AS INTEGER)');

  // --- typeof / quote edge cases ---
  ProbeRows('typeof null',             '', 'SELECT typeof(null)');
  ProbeRows('typeof empty blob',       '', 'SELECT typeof(x'''')');
  ProbeRows('quote int',               '', 'SELECT quote(42)');
  ProbeRows('quote text quote',        '', 'SELECT quote(''a''''b'')');
  ProbeRows('quote blob',              '', 'SELECT quote(x''41420A'')');
  ProbeRows('quote null',              '', 'SELECT quote(null)');
  ProbeRows('quote real',              '', 'SELECT quote(1.5)');

  // --- BLOB literal round-trip ---
  ProbeRows('hex literal',             '', 'SELECT length(x''DEADBEEF'')');
  ProbeRows('hex literal val',         '', 'SELECT hex(x''DEADBEEF'')');
  ProbeRows('empty hex',               '', 'SELECT length(x'''')');

  // --- length() of different types ---
  ProbeRows('length text',             '', 'SELECT length(''hello'')');
  ProbeRows('length int',              '', 'SELECT length(12345)');
  ProbeRows('length real',             '', 'SELECT length(3.14)');
  ProbeRows('length null',             '', 'SELECT length(null)');
  ProbeRows('length blob',             '', 'SELECT length(x''0102030405'')');
  ProbeRows('length unicode',          '', 'SELECT length(''café'')');
  ProbeRows('octet_length unicode',    '', 'SELECT octet_length(''café'')');
  ProbeRows('octet_length null',       '', 'SELECT octet_length(null)');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
