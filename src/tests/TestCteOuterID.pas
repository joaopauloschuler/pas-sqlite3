{
  SPDX-License-Identifier: blessing

  TestCteOuterID — regression for 10.1.bug.131.

  Bare-TK_ID (unqualified column) outer references from inside a
  correlated EXISTS / scalar subquery used to fail with
  "no such column: X" because the SELECT-prep correlation walker
  only handled qualified TK_DOT outer refs.  Mirrors C SQLite's
  lookupName NameContext.pNext climb (resolve.c:393..489).

  The hero case is the .import duplicate-column-rename path
  (shell.c.in:7219..7250): a WITH RECURSIVE step references the
  recursive CTE column from inside an EXISTS subquery nested inside
  printf().  Without this fix, the EXISTS subselect's inner resolver
  saw only `FROM T t` and rejected the outer CTE column reference.
}
{$I ../passqlite3.inc}
program TestCteOuterID;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3main, passqlite3vdbe,
  passqlite3os,
  TestSqlOracleCommon;

var
  db: PTsqlite3;
begin
  db := nil;
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then begin
    WriteLn('FAIL open'); Halt(1);
  end;

  OracleRun(db,
    'CREATE TABLE T(a INT, b INT);' +
    'INSERT INTO T VALUES(1,10),(2,20);');

  { Baseline: outer-FROM bare-ID inside a correlated EXISTS. }
  OracleCheckScalar(db,
    'SELECT count(*) FROM T t WHERE EXISTS(SELECT 1 FROM T u WHERE u.b=10*a)',
    '2', 'EXISTS sees outer bare-ID `a`');

  { Inner FROM has same column name → inner scope wins (resolve.c
    lookupName climbs only when innermost is empty). }
  OracleCheckScalar(db,
    'SELECT (SELECT count(*) FROM T u WHERE u.a<>a) FROM T t WHERE a=1',
    '0', 'inner u.a shadows outer t.a (inner wins, count=0)');
  OracleCheckScalar(db,
    'SELECT (SELECT count(*) FROM T u WHERE a=u.a) FROM T t WHERE t.a=1',
    '2', 'inner `a` shadows outer (inner-scope wins, all rows)');

  { Hero case: WITH RECURSIVE … step references the CTE column from
    inside an EXISTS nested inside printf().  The recursion fires only
    when printf('%d', nlz)='1', which never matches for nlz=0, so the
    iterator yields only the base row and count=1. }
  OracleCheckScalar(db,
    'WITH RECURSIVE Lzn(nlz) AS (SELECT 0 UNION SELECT nlz+1 FROM Lzn'
    + ' WHERE EXISTS(SELECT 1 FROM T t WHERE printf(''%d'',nlz)=''1''))'
    + ' SELECT count(*) FROM Lzn',
    '1', 'recursive CTE: EXISTS sees outer CTE column nlz');

  { Variation: arithmetic on the outer CTE column inside EXISTS. }
  OracleCheckScalar(db,
    'WITH RECURSIVE C(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM C'
    + ' WHERE EXISTS(SELECT 1 FROM T t WHERE i<3))'
    + ' SELECT count(*) FROM C',
    '3', 'recursive CTE: bare-ID `i` inside EXISTS WHERE');

  sqlite3_close(db);
  WriteLn;
  WriteLn(Format('TestCteOuterID: %d PASS / %d FAIL',
                 [gOraclePass, gOracleFail]));
  if gOracleFail > 0 then Halt(1);
end.
