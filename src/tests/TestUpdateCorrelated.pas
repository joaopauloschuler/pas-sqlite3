{
  SPDX-License-Identifier: blessing

  TestUpdateCorrelated — regression for 10.1.bug.130: UPDATE T AS t
  SET col=(SELECT … WHERE inner.col=t.col) used to fail with
  "no such column: t.col" because sqlite3ResolveExprNames (the resolver
  entry point used by UPDATE / DELETE / nested clauses) did not pre-
  resolve outer-alias TK_DOTs inside SET-expression subqueries.

  The SELECT path works because it routes through the heavier
  sqlite3ResolveSelectNames walker which performs the bCorr +
  ResolveOuterRefs pass.  This regression exercises both arms.
}
{$I ../passqlite3.inc}
program TestUpdateCorrelated;

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
    'INSERT INTO T VALUES(1,10),(2,20),(2,30),(3,40);');

  { Baseline: SELECT path with the same correlation already works. }
  OracleCheckScalar(db,
    'SELECT (SELECT count(*) FROM T d WHERE d.a=t.a) FROM T AS t WHERE t.b=10',
    '1', 'select-correlated baseline');

  { Regression: UPDATE … AS t SET … (SELECT … WHERE d.a=t.a). }
  OracleRun(db, 'UPDATE T AS t SET b=(SELECT count(*) FROM T d WHERE d.a=t.a)');
  OracleCheckScalar(db, 'SELECT b FROM T WHERE a=1', '1',
              'update-correlated a=1 → count=1');
  OracleCheckScalar(db, 'SELECT count(*) FROM T WHERE a=2 AND b=2', '2',
              'update-correlated a=2 → count=2 (two rows)');
  OracleCheckScalar(db, 'SELECT b FROM T WHERE a=3', '1',
              'update-correlated a=3 → count=1');

  { Nested expression form — subquery inside an iif() inside SET. }
  OracleRun(db, 'UPDATE T AS t SET b=iif(t.a=1,' +
          ' (SELECT max(d.b) FROM T d WHERE d.a<>t.a), t.b)');
  OracleCheckScalar(db, 'SELECT b FROM T WHERE a=1', '2',
              'iif-wrapped subquery sees t.a');

  { Outer alias visible across two levels of subquery nesting. }
  OracleRun(db, 'UPDATE T AS t SET b=' +
          '(SELECT (SELECT count(*) FROM T e WHERE e.a=t.a) FROM T d' +
          ' WHERE d.a=t.a LIMIT 1)');
  OracleCheckScalar(db, 'SELECT b FROM T WHERE a=1', '1',
              'two-level nested subquery sees t.a');

  sqlite3_close(db);
  WriteLn;
  WriteLn(Format('TestUpdateCorrelated: %d PASS / %d FAIL',
                 [gOraclePass, gOracleFail]));
  if gOracleFail > 0 then Halt(1);
end.
