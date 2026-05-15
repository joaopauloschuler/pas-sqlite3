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
  DiagCommon;

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
  ProbeRows('row_number basic',  Seed1,
    'SELECT a, row_number() OVER (ORDER BY a) FROM t');
  ProbeRows('rank basic',        Seed1,
    'SELECT a, rank() OVER (ORDER BY a) FROM t');
  ProbeRows('dense_rank',        Seed1,
    'SELECT a, dense_rank() OVER (ORDER BY a) FROM t');

  // --- Window aggregates ---
  ProbeRows('sum() OVER all',    Seed1,
    'SELECT a, sum(b) OVER () FROM t');
  ProbeRows('sum() running',     Seed1,
    'SELECT a, sum(b) OVER (ORDER BY a) FROM t');
  ProbeRows('avg() OVER',        Seed1,
    'SELECT avg(b) OVER () FROM t');

  // --- PARTITION BY ---
  ProbeRows('partition row_num', Seed2,
    'SELECT grp, val, row_number() OVER (PARTITION BY grp ORDER BY val) FROM g');
  ProbeRows('partition sum',     Seed2,
    'SELECT grp, sum(val) OVER (PARTITION BY grp) FROM g');

  // --- LAG / LEAD ---
  ProbeRows('lag basic',         Seed1,
    'SELECT a, lag(b,1,0) OVER (ORDER BY a) FROM t');
  ProbeRows('lead basic',        Seed1,
    'SELECT a, lead(b,1,0) OVER (ORDER BY a) FROM t');

  // --- FIRST_VALUE / LAST_VALUE / NTH_VALUE ---
  ProbeRows('first_value',       Seed1,
    'SELECT first_value(b) OVER (ORDER BY a) FROM t');
  ProbeRows('ntile 2',           Seed1,
    'SELECT ntile(2) OVER (ORDER BY a) FROM t');

  // --- Aggregate with FILTER ---
  ProbeRows('count filter',      Seed1,
    'SELECT count(*) FILTER (WHERE a>1) FROM t');
  ProbeRows('sum filter',        Seed1,
    'SELECT sum(b) FILTER (WHERE a>1) FROM t');

  // --- DISTINCT in aggregate ---
  ProbeRows('count distinct',    Seed2,
    'SELECT count(DISTINCT grp) FROM g');
  ProbeRows('sum distinct',      Seed2,
    'SELECT sum(DISTINCT val) FROM g');

  // --- GROUP BY + HAVING ---
  ProbeRows('group having',      Seed2,
    'SELECT grp, sum(val) FROM g GROUP BY grp HAVING sum(val) > 5');
  ProbeRows('group order',       Seed2,
    'SELECT grp, sum(val) FROM g GROUP BY grp ORDER BY grp DESC');

  // --- group_concat with ORDER BY ---
  ProbeRows('group_concat',      Seed2,
    'SELECT group_concat(val,'','') FROM g WHERE grp=''A''');
  ProbeRows('group_concat order',Seed2,
    'SELECT group_concat(val,'','' ORDER BY val DESC) FROM g WHERE grp=''B''');

  // --- min/max with non-trivial input ---
  ProbeRows('min agg',           Seed2, 'SELECT min(val) FROM g');
  ProbeRows('max agg',           Seed2, 'SELECT max(val) FROM g');
  ProbeRows('total agg',         Seed2, 'SELECT total(val) FROM g');

  // --- Built-in window functions not yet exercised ---
  ProbeRows('percent_rank',      Seed1,
    'SELECT a, percent_rank() OVER (ORDER BY a) FROM t');
  ProbeRows('cume_dist',         Seed1,
    'SELECT a, cume_dist() OVER (ORDER BY a) FROM t');
  ProbeRows('last_value',        Seed1,
    'SELECT a, last_value(b) OVER (ORDER BY a) FROM t');
  ProbeRows('nth_value 2',       Seed1,
    'SELECT a, nth_value(b,2) OVER (ORDER BY a) FROM t');

  // --- Multi-window: several distinct OVER clauses in one SELECT ---
  ProbeRows('multi window',      Seed2,
    'SELECT grp, val,' +
    ' row_number() OVER (PARTITION BY grp ORDER BY val),' +
    ' sum(val) OVER (PARTITION BY grp),' +
    ' rank() OVER (ORDER BY val) FROM g');
  ProbeRows('multi window same partition', Seed2,
    'SELECT grp,' +
    ' sum(val) OVER (PARTITION BY grp ORDER BY val),' +
    ' avg(val) OVER (PARTITION BY grp ORDER BY val) FROM g');

  // --- Frame-spec emission: ROWS/RANGE/GROUPS with bounds ---
  ProbeRows('rows preceding',    Seed1,
    'SELECT a, sum(b) OVER (ORDER BY a ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t');
  ProbeRows('rows following',    Seed1,
    'SELECT a, sum(b) OVER (ORDER BY a ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING) FROM t');
  ProbeRows('rows unbounded',    Seed1,
    'SELECT a, sum(b) OVER (ORDER BY a ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM t');
  ProbeRows('range current',     Seed1,
    'SELECT a, sum(b) OVER (ORDER BY a RANGE BETWEEN CURRENT ROW AND CURRENT ROW) FROM t');
  ProbeRows('range preceding',   Seed1,
    'SELECT a, sum(b) OVER (ORDER BY a RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t');
  ProbeRows('groups',            Seed2,
    'SELECT grp, val, sum(val) OVER (ORDER BY val GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM g');
  ProbeRows('exclude current',   Seed1,
    'SELECT a, sum(b) OVER (ORDER BY a ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW) FROM t');
  ProbeRows('exclude group',     Seed2,
    'SELECT grp, val, sum(val) OVER (PARTITION BY grp ORDER BY val ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP) FROM g');
  ProbeRows('exclude ties',      Seed2,
    'SELECT grp, val, sum(val) OVER (PARTITION BY grp ORDER BY val ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE TIES) FROM g');

  // --- Subset-gate lifts: outer ORDER BY / LIMIT / DISTINCT with windows ---
  ProbeRows('window outer order alias', Seed2,
    'SELECT grp, row_number() OVER (PARTITION BY grp ORDER BY val) AS rn FROM g ORDER BY grp DESC, rn');
  ProbeRows('window outer order',  Seed2,
    'SELECT grp, row_number() OVER (PARTITION BY grp ORDER BY val) FROM g ORDER BY grp DESC, val');
  ProbeRows('window outer limit', Seed1,
    'SELECT a, row_number() OVER (ORDER BY a) FROM t LIMIT 2');
  ProbeRows('window outer offset',Seed1,
    'SELECT a, row_number() OVER (ORDER BY a) FROM t LIMIT 2 OFFSET 1');
  ProbeRows('window outer distinct', Seed2,
    'SELECT DISTINCT sum(val) OVER (PARTITION BY grp) FROM g');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
