{$I ../passqlite3.inc}
{
  TestExplainParity.pas — Phase 6.9 differential bytecode-diff gate.

  For every SQL statement in the inline corpus, prepare it on both:
    * the C reference (csq_prepare_v2 with the literal SQL); the C-side
      bytecode listing comes from `EXPLAIN <sql>` stepped row by row;
    * the Pascal port (sqlite3_prepare_v2); the Pascal listing comes from
      walking the returned PVdbe.aOp[0..nOp-1] array directly (the
      Pascal sqlite3VdbeList stub does not yet drive OP_Explain).

  The two listings are diffed on (opcode-name, p1, p2, p3, p5).  P4 and
  comment columns are excluded for now — P4 string formatting depends on
  KeyInfo / Func / Coll heap layouts that are not byte-stable yet, and
  comments are SQLITE_ENABLE_EXPLAIN_COMMENTS-only chatter.

  Scope note (2026-04-26): this lands the scaffold and a small DDL-only
  corpus — the most reliable surface today, given that
  Phase 6.5-bis (sqlite3FinishCoding) was the keystone that lets DDL
  prepare_v2 actually return a stepable Vdbe.  SELECT / DML / pragma /
  trigger forms remain Phase 7.4b territory (TestParser corpus exclusion
  list) and should be folded back in as their codegen helpers come up.

  This is the diff-finder, not a "must-pass" gate yet — the test reports
  per-row PASS / DIVERGE and exits non-zero only on outright errors
  (prepare failure on the C side, runtime crashes).  Bytecode divergence
  is reported but tolerated; the running tally is the actionable signal
  for Phase 6.x bytecode-alignment work.
}

program TestExplainParity;

uses
  SysUtils,
  csqlite3,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

const
  FIXTURE_SCHEMA: PAnsiChar =
    'CREATE TABLE t(a, b, c);' +
    'CREATE TABLE s(x, y, z);' +
    'CREATE TABLE u(p PRIMARY KEY, q);';

type
  TCorpusRow = record
    label_:   AnsiString;
    sql:      AnsiString;
  end;

  TOpRow = record
    opcode: AnsiString;
    p1, p2, p3: i32;
    p5: i32;
  end;

  TOpList = array of TOpRow;

var
  gPass, gDiverge, gErr: i32;
  gCDb:    Pcsq_db;
  gPasDb:  PTsqlite3;

{ -------------------------------------------------------------------------- }
{ Corpus.                                                                    }
{ -------------------------------------------------------------------------- }

const
  N_CORPUS = 862;

var
  CORPUS: array[0..N_CORPUS - 1] of TCorpusRow;

procedure InitCorpus;
  procedure Add(i: Int32; const lbl, sql: AnsiString);
  begin
    CORPUS[i].label_ := lbl;
    CORPUS[i].sql    := sql;
  end;
var i: Int32;
begin
  i := 0;
  Add(i, 'CREATE TABLE simple',         'CREATE TABLE z1(a,b);');             Inc(i);
  Add(i, 'CREATE TABLE typed',          'CREATE TABLE z2(a INTEGER PRIMARY KEY, b TEXT);'); Inc(i);
  Add(i, 'CREATE TABLE IF NOT EXISTS',  'CREATE TABLE IF NOT EXISTS z3(x);'); Inc(i);
  Add(i, 'CREATE TABLE composite PK',   'CREATE TABLE z7(a,b, PRIMARY KEY(a,b));'); Inc(i);
  Add(i, 'CREATE TABLE WITHOUT ROWID',  'CREATE TABLE z8(a PRIMARY KEY, b) WITHOUT ROWID;'); Inc(i);
  Add(i, 'CREATE INDEX',                'CREATE INDEX i1 ON t(a);');          Inc(i);
  Add(i, 'CREATE UNIQUE INDEX',         'CREATE UNIQUE INDEX i2 ON t(b);');   Inc(i);
  Add(i, 'DROP TABLE',                  'DROP TABLE t;');                     Inc(i);
  Add(i, 'DROP INDEX IF EXISTS',        'DROP INDEX IF EXISTS i_nope;');      Inc(i);
  Add(i, 'BEGIN',                       'BEGIN;');                            Inc(i);

  { SELECT / DML probe rows — expand bytecode-diff coverage beyond DDL.
    Uses fixture tables t(a,b,c), s(x,y,z), u(p PRIMARY KEY, q). }
  Add(i, 'SELECT literal',              'SELECT 1;');                            Inc(i);
  Add(i, 'SELECT col scan',             'SELECT a FROM t;');                     Inc(i);
  Add(i, 'SELECT rowid EQ',             'SELECT a FROM t WHERE rowid=5;');       Inc(i);
  Add(i, 'SELECT * scan',               'SELECT * FROM t;');                     Inc(i);
  Add(i, 'DELETE rowid EQ',             'DELETE FROM t WHERE rowid=5;');         Inc(i);
  Add(i, 'INSERT VALUES',               'INSERT INTO t VALUES (1,2,3);');        Inc(i);
  Add(i, 'COMMIT',                      'COMMIT;');                              Inc(i);

  { Step 6 corpus expansion — additional shapes confirmed PASS. }
  Add(i, 'SELECT multi-col scan',       'SELECT a, b FROM t;');                  Inc(i);
  Add(i, 'SELECT col WHERE',            'SELECT a FROM t WHERE a=5;');           Inc(i);
  Add(i, 'SELECT arith literal',        'SELECT 1+2;');                          Inc(i);
  Add(i, 'SELECT string literal',       'SELECT ''hello'';');                    Inc(i);
  Add(i, 'SELECT multi literal',        'SELECT 1, 2, 3;');                      Inc(i);
  Add(i, 'BEGIN IMMEDIATE',             'BEGIN IMMEDIATE;');                     Inc(i);
  Add(i, 'BEGIN EXCLUSIVE',             'BEGIN EXCLUSIVE;');                     Inc(i);
  Add(i, 'ROLLBACK',                    'ROLLBACK;');                            Inc(i);
  Add(i, 'SAVEPOINT',                   'SAVEPOINT s1;');                        Inc(i);

  { Step 6 sub-progress — DEFAULT VALUES now factors OP_Null into prologue. }
  Add(i, 'INSERT DEFAULT VALUES',       'INSERT INTO t DEFAULT VALUES;');        Inc(i);

  { Step 6 sub-progress (probe sweep #2) — additional shapes confirmed PASS. }
  Add(i, 'CREATE INDEX 2col',           'CREATE INDEX i3 ON t(a,b);');           Inc(i);
  Add(i, 'RELEASE',                     'RELEASE s1;');                          Inc(i);
  Add(i, 'SELECT multi-col rowid EQ',   'SELECT a,b FROM t WHERE rowid=5;');     Inc(i);
  Add(i, 'SELECT * rowid EQ',           'SELECT * FROM t WHERE rowid=5;');       Inc(i);
  Add(i, 'SELECT col WHERE multi-AND',  'SELECT a FROM t WHERE a=5 AND b=7;');   Inc(i);
  Add(i, 'SELECT NULL',                 'SELECT NULL;');                         Inc(i);
  Add(i, 'DELETE rowid EQ AND col',     'DELETE FROM t WHERE rowid=5 AND a=1;'); Inc(i);
  Add(i, 'SAVEPOINT 2',                 'SAVEPOINT s2;');                        Inc(i);
  Add(i, 'SELECT col arith',            'SELECT a+b FROM t;');                   Inc(i);
  Add(i, 'SELECT col mul',              'SELECT a*2 FROM t;');                   Inc(i);

  { Step 6 sub-progress (probe sweep #3) — additional shapes confirmed PASS. }
  Add(i, 'SELECT 3-col scan',           'SELECT a,b,c FROM t;');                 Inc(i);
  Add(i, 'SELECT other table',          'SELECT x FROM s;');                     Inc(i);
  Add(i, 'BEGIN DEFERRED',              'BEGIN DEFERRED;');                      Inc(i);
  Add(i, 'BEGIN TRANSACTION',           'BEGIN TRANSACTION;');                   Inc(i);
  Add(i, 'COMMIT TRANSACTION',          'COMMIT TRANSACTION;');                  Inc(i);
  Add(i, 'END',                         'END;');                                 Inc(i);
  Add(i, 'END TRANSACTION',             'END TRANSACTION;');                     Inc(i);
  Add(i, 'ROLLBACK TRANSACTION',        'ROLLBACK TRANSACTION;');                Inc(i);
  Add(i, 'ROLLBACK TO',                 'ROLLBACK TO s1;');                      Inc(i);
  Add(i, 'ROLLBACK TO SAVEPOINT',       'ROLLBACK TO SAVEPOINT s1;');            Inc(i);
  Add(i, 'RELEASE SAVEPOINT',           'RELEASE SAVEPOINT s1;');                Inc(i);
  Add(i, 'SELECT col WHERE 3-AND',      'SELECT a FROM t WHERE a=5 AND b=7 AND c=9;'); Inc(i);
  Add(i, 'SELECT rowid scan',           'SELECT rowid FROM t;');                 Inc(i);
  Add(i, 'SELECT rowid WHERE',          'SELECT rowid FROM t WHERE rowid=5;');   Inc(i);
  Add(i, 'SELECT col arith literal',    'SELECT 1+2*3;');                        Inc(i);
  Add(i, 'SELECT col negate',           'SELECT -a FROM t;');                    Inc(i);
  Add(i, 'SELECT col concat',           'SELECT a||b FROM t;');                  Inc(i);
  Add(i, 'INSERT VALUES s',             'INSERT INTO s VALUES (1,2,3);');        Inc(i);
  Add(i, 'INSERT DEFAULT VALUES s',     'INSERT INTO s DEFAULT VALUES;');        Inc(i);

  { Step 6 sub-progress — constant-integer LIMIT codegen now emits
    OP_Integer + OP_DecrJumpZero in sqlite3Select. }
  Add(i, 'SELECT col LIMIT',            'SELECT a FROM t LIMIT 3;');             Inc(i);
  Add(i, 'SELECT col WHERE LIMIT',      'SELECT a FROM t WHERE a=5 LIMIT 2;');   Inc(i);

  { Step 6 sub-progress (probe sweep #4) — comparison / arith / DELETE-all
    shapes confirmed PASS. }
  Add(i, 'SELECT col WHERE a<5',        'SELECT a FROM t WHERE a<5;');           Inc(i);
  Add(i, 'SELECT col WHERE a<>5',       'SELECT a FROM t WHERE a<>5;');          Inc(i);
  Add(i, 'SELECT col WHERE a<=5',       'SELECT a FROM t WHERE a<=5;');          Inc(i);
  Add(i, 'SELECT col WHERE a>=5',       'SELECT a FROM t WHERE a>=5;');          Inc(i);
  Add(i, 'SELECT col WHERE a>5',        'SELECT a FROM t WHERE a>5;');           Inc(i);
  Add(i, 'SELECT 1+2-3',                'SELECT 1+2-3;');                        Inc(i);
  Add(i, 'SELECT -1',                   'SELECT -1;');                           Inc(i);
  Add(i, 'SELECT concat literal',       'SELECT ''abc''||''def'';');             Inc(i);
  Add(i, 'SELECT col sub',              'SELECT a-b FROM t;');                   Inc(i);
  Add(i, 'SELECT col div',              'SELECT a/2 FROM t;');                   Inc(i);
  Add(i, 'DELETE all',                  'DELETE FROM t;');                       Inc(i);

  { Probe sweep #5 — candidate rows. }
  Add(i, 'SELECT 2*3',                  'SELECT 2*3;');                          Inc(i);
  Add(i, 'SELECT 6/2',                  'SELECT 6/2;');                          Inc(i);
  Add(i, 'SELECT 7-3',                  'SELECT 7-3;');                          Inc(i);
  Add(i, 'SELECT 5%2',                  'SELECT 5%2;');                          Inc(i);
  Add(i, 'SELECT col +lit',             'SELECT a+1 FROM t;');                   Inc(i);
  Add(i, 'SELECT col *col',             'SELECT a*b FROM t;');                   Inc(i);
  Add(i, 'SELECT 3-col rowid EQ',       'SELECT a,b,c FROM t WHERE rowid=5;');   Inc(i);
  Add(i, 'SELECT alt-tbl WHERE',        'SELECT x FROM s WHERE x=5;');           Inc(i);
  Add(i, 'SELECT col WHERE col',        'SELECT a FROM t WHERE b=7;');           Inc(i);
  Add(i, 'INSERT NULL value',           'INSERT INTO t VALUES (NULL,1,2);');     Inc(i);
  Add(i, 'INSERT mixed types',          'INSERT INTO t VALUES (1,''abc'',2);');  Inc(i);
  Add(i, 'INSERT negative',             'INSERT INTO t VALUES (-1,2,3);');       Inc(i);
  Add(i, 'SELECT 2*3+4',                'SELECT 2*3+4;');                        Inc(i);
  Add(i, 'SELECT 3-col arith',          'SELECT a+b+c FROM t;');                 Inc(i);
  Add(i, 'SAVEPOINT s3',                'SAVEPOINT s3;');                        Inc(i);
  Add(i, 'RELEASE s2',                  'RELEASE s2;');                          Inc(i);
  Add(i, 'SELECT alias',                'SELECT 1 AS x;');                       Inc(i);
  Add(i, 'SELECT col alias',            'SELECT a AS aa FROM t;');               Inc(i);
  Add(i, 'SELECT col WHERE neg',        'SELECT a FROM t WHERE a=-5;');          Inc(i);
  Add(i, 'SELECT col WHERE str',        'SELECT a FROM t WHERE a=''x'';');       Inc(i);
  Add(i, 'SELECT col MOD',              'SELECT a%2 FROM t;');                   Inc(i);
  Add(i, 'DELETE WHERE rowid neg',      'DELETE FROM t WHERE rowid=-1;');        Inc(i);
  Add(i, 'INSERT 2nd table',            'INSERT INTO s VALUES(4,5,6);');         Inc(i);
  Add(i, 'SELECT * other',              'SELECT * FROM s;');                     Inc(i);
  Add(i, 'SELECT col AND col WHERE',    'SELECT b FROM t WHERE a=5;');           Inc(i);
  Add(i, 'CREATE INDEX 3col',           'CREATE INDEX i4 ON t(a,b,c);');         Inc(i);
  Add(i, 'CREATE UNIQUE INDEX 2',       'CREATE UNIQUE INDEX i5 ON s(x);');      Inc(i);
  Add(i, 'SAVEPOINT sxy',               'SAVEPOINT sxy;');                       Inc(i);
  Add(i, 'COMMIT vs END',               'COMMIT;');                              Inc(i);

  { Probe sweep #6 — candidate rows. }
  Add(i, 'SELECT 1*2*3',                'SELECT 1*2*3;');                        Inc(i);
  Add(i, 'SELECT 10+20',                'SELECT 10+20;');                        Inc(i);
  Add(i, 'SELECT a+1+b',                'SELECT a+1+b FROM t;');                 Inc(i);
  Add(i, 'SELECT a+b+1',                'SELECT a+b+1 FROM t;');                 Inc(i);
  Add(i, 'SELECT a*b+c',                'SELECT a*b+c FROM t;');                 Inc(i);
  Add(i, 'SELECT a-b-c',                'SELECT a-b-c FROM t;');                 Inc(i);
  Add(i, 'SELECT NULL,NULL',            'SELECT NULL, NULL;');                   Inc(i);
  Add(i, 'SELECT 1,NULL',               'SELECT 1, NULL;');                      Inc(i);
  Add(i, 'SELECT 1+NULL',               'SELECT 1+NULL;');                       Inc(i);
  Add(i, 'SELECT a,b,c',                'SELECT a,b,c FROM t;');                 Inc(i);
  Add(i, 'SELECT a,a',                  'SELECT a, a FROM t;');                  Inc(i);
  Add(i, 'SELECT col+col rowid EQ',     'SELECT a+b FROM t WHERE rowid=1;');     Inc(i);
  Add(i, 'SELECT col-1',                'SELECT a-1 FROM t;');                   Inc(i);
  Add(i, 'SELECT col*0',                'SELECT a*0 FROM t;');                   Inc(i);
  Add(i, 'SELECT col WHERE rowid<>5',   'SELECT a FROM t WHERE rowid<>5;');      Inc(i);
  Add(i, 'INSERT alt VALUES neg',       'INSERT INTO s VALUES(-1,-2,-3);');      Inc(i);
  Add(i, 'INSERT alt VALUES str',       'INSERT INTO s VALUES(''a'',''b'',''c'');'); Inc(i);
  Add(i, 'DELETE alt all',              'DELETE FROM s;');                       Inc(i);
  Add(i, 'DELETE alt rowid EQ',         'DELETE FROM s WHERE rowid=1;');         Inc(i);
  Add(i, 'SELECT 1+2+3+4',              'SELECT 1+2+3+4;');                      Inc(i);
  Add(i, 'SELECT 100',                  'SELECT 100;');                          Inc(i);
  Add(i, 'SELECT -100',                 'SELECT -100;');                         Inc(i);
  Add(i, 'SELECT empty str',            'SELECT '''';');                         Inc(i);
  Add(i, 'SAVEPOINT s7',                'SAVEPOINT s7;');                        Inc(i);
  Add(i, 'RELEASE s7',                  'RELEASE s7;');                          Inc(i);
  Add(i, 'CREATE TABLE 4col',           'CREATE TABLE z9(a,b,c,d);');            Inc(i);
  Add(i, 'CREATE INDEX alt',            'CREATE INDEX i6 ON s(y);');             Inc(i);
  Add(i, 'CREATE INDEX alt 2col',       'CREATE INDEX i7 ON s(y,z);');           Inc(i);

  { Probe sweep #7 — candidate rows. }
  Add(i, 'SELECT 0',                    'SELECT 0;');                            Inc(i);
  Add(i, 'SELECT 1+1+1+1+1',            'SELECT 1+1+1+1+1;');                    Inc(i);
  Add(i, 'SELECT a*b*c',                'SELECT a*b*c FROM t;');                 Inc(i);
  Add(i, 'SELECT a-b+c',                'SELECT a-b+c FROM t;');                 Inc(i);
  Add(i, 'SELECT a||b||c',              'SELECT a||b||c FROM t;');               Inc(i);
  Add(i, 'SELECT col,lit',              'SELECT a, 1 FROM t;');                  Inc(i);
  Add(i, 'SELECT lit,col',              'SELECT 1, a FROM t;');                  Inc(i);
  Add(i, 'SELECT col,col arith',        'SELECT a+1, b+1 FROM t;');              Inc(i);
  Add(i, 'SELECT col,col arith2',       'SELECT a, b+c FROM t;');                Inc(i);
  Add(i, 'SELECT col arith,col',        'SELECT a+b, c FROM t;');                Inc(i);
  Add(i, 'SELECT a+b*c',                'SELECT a+b*c FROM t;');                 Inc(i);
  Add(i, 'SELECT (a+b)*c',              'SELECT (a+b)*c FROM t;');               Inc(i);
  Add(i, 'INSERT NULL middle',          'INSERT INTO t VALUES(1,NULL,3);');      Inc(i);
  Add(i, 'INSERT all NULL',             'INSERT INTO t VALUES(NULL,NULL,NULL);'); Inc(i);
  Add(i, 'INSERT zeros',                'INSERT INTO t VALUES(0,0,0);');         Inc(i);
  Add(i, 'DELETE alt rowid 2',          'DELETE FROM s WHERE rowid=2;');         Inc(i);
  Add(i, 'DELETE rowid large',          'DELETE FROM t WHERE rowid=10;');        Inc(i);
  Add(i, 'SAVEPOINT s8',                'SAVEPOINT s8;');                        Inc(i);
  Add(i, 'RELEASE s8',                  'RELEASE s8;');                          Inc(i);
  Add(i, 'SELECT col WHERE a=0',        'SELECT a FROM t WHERE a=0;');           Inc(i);
  Add(i, 'SELECT col WHERE a=big',      'SELECT a FROM t WHERE a=1000000;');     Inc(i);
  Add(i, 'SELECT col WHERE a=empty',    'SELECT a FROM t WHERE a='''';');        Inc(i);
  Add(i, 'SELECT 1.5',                  'SELECT 1.5;');                          Inc(i);
  Add(i, 'SELECT a,b,a',                'SELECT a, b, a FROM t;');               Inc(i);
  Add(i, 'SELECT b,a',                  'SELECT b, a FROM t;');                  Inc(i);
  Add(i, 'SELECT char str',             'SELECT ''multi word'';');               Inc(i);
  Add(i, 'BEGIN DEFERRED TRANSACTION',  'BEGIN DEFERRED TRANSACTION;');          Inc(i);
  Add(i, 'BEGIN IMM TRANSACTION',       'BEGIN IMMEDIATE TRANSACTION;');         Inc(i);
  Add(i, 'BEGIN EXCL TRANSACTION',      'BEGIN EXCLUSIVE TRANSACTION;');         Inc(i);
  Add(i, 'CREATE TABLE typed mixed',    'CREATE TABLE z10(x INTEGER, y TEXT, z BLOB);'); Inc(i);
  Add(i, 'SELECT col-col',              'SELECT a-c FROM t;');                   Inc(i);
  Add(i, 'SELECT col+col rowid 2',      'SELECT a+b FROM t WHERE rowid=2;');     Inc(i);
  Add(i, 'SELECT col WHERE rowid=0',    'SELECT a FROM t WHERE rowid=0;');       Inc(i);
  Add(i, 'SELECT col WHERE rowid=big',  'SELECT a FROM t WHERE rowid=1000;');    Inc(i);
  Add(i, 'SELECT *,1',                  'SELECT *, 1 FROM t;');                  Inc(i);

  { Probe sweep #7 (cont.) — predicate / unary / function shapes. }
  Add(i, 'SELECT IS NULL',              'SELECT a FROM t WHERE a IS NULL;');     Inc(i);
  Add(i, 'SELECT IS NOT NULL',          'SELECT a FROM t WHERE a IS NOT NULL;'); Inc(i);
  Add(i, 'SELECT NOT a',                'SELECT NOT a FROM t;');                 Inc(i);
  Add(i, 'SELECT a IS 1',               'SELECT a IS 1 FROM t;');                Inc(i);
  Add(i, 'SELECT a IS NOT 1',           'SELECT a IS NOT 1 FROM t;');            Inc(i);
  Add(i, 'SELECT BETWEEN',              'SELECT a FROM t WHERE a BETWEEN 1 AND 5;'); Inc(i);
  Add(i, 'SELECT CAST',                 'SELECT CAST(1 AS TEXT);');              Inc(i);
  Add(i, 'SELECT COALESCE',             'SELECT COALESCE(a, 0) FROM t;');        Inc(i);
  Add(i, 'SELECT CASE',                 'SELECT CASE WHEN a=1 THEN 1 ELSE 0 END FROM t;'); Inc(i);

  { Probe sweep #8 — bitwise / unary / extra function / CASE / literal shapes. }
  Add(i, 'SELECT a&b',                  'SELECT a&b FROM t;');                   Inc(i);
  Add(i, 'SELECT a|b',                  'SELECT a|b FROM t;');                   Inc(i);
  Add(i, 'SELECT a<<1',                 'SELECT a<<1 FROM t;');                  Inc(i);
  Add(i, 'SELECT a>>1',                 'SELECT a>>1 FROM t;');                  Inc(i);
  Add(i, 'SELECT ~a',                   'SELECT ~a FROM t;');                    Inc(i);
  Add(i, 'SELECT +a',                   'SELECT +a FROM t;');                    Inc(i);
  Add(i, 'SELECT 1&3',                  'SELECT 1&3;');                          Inc(i);
  Add(i, 'SELECT 1|2',                  'SELECT 1|2;');                          Inc(i);
  Add(i, 'SELECT 4>>1',                 'SELECT 4>>1;');                         Inc(i);
  Add(i, 'SELECT IFNULL',               'SELECT IFNULL(a, 0) FROM t;');          Inc(i);
  Add(i, 'SELECT NULLIF',               'SELECT NULLIF(a, 0) FROM t;');          Inc(i);
  Add(i, 'SELECT COALESCE 3-arg',       'SELECT COALESCE(a, b, 0) FROM t;');     Inc(i);
  Add(i, 'SELECT CASE simple',          'SELECT CASE a WHEN 1 THEN 1 ELSE 0 END FROM t;'); Inc(i);
  Add(i, 'SELECT CAST a INT',           'SELECT CAST(a AS INTEGER) FROM t;');    Inc(i);
  Add(i, 'SELECT CAST a REAL',          'SELECT CAST(a AS REAL) FROM t;');       Inc(i);
  Add(i, 'SELECT CAST str INT',         'SELECT CAST(''5'' AS INTEGER);');       Inc(i);
  Add(i, 'SELECT NOT 0',                'SELECT NOT 0;');                        Inc(i);
  Add(i, 'SELECT NOT 1',                'SELECT NOT 1;');                        Inc(i);
  Add(i, 'SELECT a IS b',               'SELECT a IS b FROM t;');                Inc(i);
  Add(i, 'SELECT a IS NOT b',           'SELECT a IS NOT b FROM t;');            Inc(i);
  Add(i, 'SELECT 1.0',                  'SELECT 1.0;');                          Inc(i);
  Add(i, 'SELECT 0.1',                  'SELECT 0.1;');                          Inc(i);
  Add(i, 'SELECT col WHERE multi-AND2', 'SELECT a FROM t WHERE a=1 AND b=2 AND c=3;'); Inc(i);
  Add(i, 'INSERT large',                'INSERT INTO t VALUES (10,20,30);');     Inc(i);
  Add(i, 'INSERT alt mixed',            'INSERT INTO s VALUES (1,''x'',NULL);'); Inc(i);
  Add(i, 'SAVEPOINT s9',                'SAVEPOINT s9;');                        Inc(i);
  Add(i, 'RELEASE s9',                  'RELEASE s9;');                          Inc(i);
  Add(i, 'DROP INDEX IF EXISTS 2',      'DROP INDEX IF EXISTS i_other;');        Inc(i);

  { Probe sweep #9 — candidate rows. }
  Add(i, 'SELECT CAST a TEXT',          'SELECT CAST(a AS TEXT) FROM t;');       Inc(i);
  Add(i, 'SELECT CAST a NUMERIC',       'SELECT CAST(a AS NUMERIC) FROM t;');    Inc(i);
  Add(i, 'SELECT CAST a BLOB',          'SELECT CAST(a AS BLOB) FROM t;');       Inc(i);
  Add(i, 'SELECT CAST NULL INT',        'SELECT CAST(NULL AS INTEGER);');        Inc(i);
  Add(i, 'SELECT CAST 1.5 INT',         'SELECT CAST(1.5 AS INTEGER);');         Inc(i);
  Add(i, 'SELECT 1.5+2.5',              'SELECT 1.5+2.5;');                      Inc(i);
  Add(i, 'SELECT 1.0*2',                'SELECT 1.0*2;');                        Inc(i);
  Add(i, 'SELECT 1+2+3',                'SELECT 1+2+3;');                        Inc(i);
  Add(i, 'SELECT 1-2-3',                'SELECT 1-2-3;');                        Inc(i);
  Add(i, 'SELECT (1+2)',                'SELECT (1+2);');                        Inc(i);
  Add(i, 'SELECT (a) col',              'SELECT (a) FROM t;');                   Inc(i);
  Add(i, 'SELECT a*a',                  'SELECT a*a FROM t;');                   Inc(i);
  Add(i, 'SELECT a+a',                  'SELECT a+a FROM t;');                   Inc(i);
  Add(i, 'SELECT a IS NULL expr',       'SELECT a IS NULL FROM t;');             Inc(i);
  Add(i, 'SELECT a IS NOT NULL expr',   'SELECT a IS NOT NULL FROM t;');         Inc(i);
  Add(i, 'SELECT a%b',                  'SELECT a%b FROM t;');                   Inc(i);
  Add(i, 'SELECT a, b AS y',            'SELECT a, b AS y FROM t;');             Inc(i);
  Add(i, 'SELECT 1 AS x, 2 AS y',       'SELECT 1 AS x, 2 AS y;');               Inc(i);
  Add(i, 'SELECT a*-1',                 'SELECT a*-1 FROM t;');                  Inc(i);
  Add(i, 'SELECT a, NULL',              'SELECT a, NULL FROM t;');               Inc(i);
  Add(i, 'SELECT NULL, a',              'SELECT NULL, a FROM t;');               Inc(i);
  Add(i, 'SELECT NOT NOT 1',            'SELECT NOT NOT 1;');                    Inc(i);
  Add(i, 'SELECT 1 IS 1',               'SELECT 1 IS 1;');                       Inc(i);
  Add(i, 'SELECT NULL IS NULL',         'SELECT NULL IS NULL;');                 Inc(i);
  Add(i, 'SELECT a||lit',               'SELECT a||''x'' FROM t;');              Inc(i);
  Add(i, 'SAVEPOINT spA',               'SAVEPOINT spA;');                       Inc(i);
  Add(i, 'RELEASE spA',                 'RELEASE spA;');                         Inc(i);

  { Probe sweep #10 — candidate rows. }
  Add(i, 'SELECT a&1',                  'SELECT a&1 FROM t;');                   Inc(i);
  Add(i, 'SELECT a|1',                  'SELECT a|1 FROM t;');                   Inc(i);
  Add(i, 'SELECT 1<<2',                 'SELECT 1<<2;');                         Inc(i);
  Add(i, 'SELECT 8>>2',                 'SELECT 8>>2;');                         Inc(i);
  Add(i, 'SELECT ~1',                   'SELECT ~1;');                           Inc(i);
  Add(i, 'SELECT +1',                   'SELECT +1;');                           Inc(i);
  Add(i, 'SELECT IFNULL col',           'SELECT IFNULL(a, b) FROM t;');          Inc(i);
  Add(i, 'SELECT NULLIF col',           'SELECT NULLIF(a, b) FROM t;');          Inc(i);
  Add(i, 'SELECT COALESCE 3 col',       'SELECT COALESCE(a, b, c) FROM t;');     Inc(i);
  Add(i, 'SELECT CASE WHEN str',        'SELECT CASE WHEN a=1 THEN ''a'' ELSE ''b'' END FROM t;'); Inc(i);
  Add(i, 'SELECT CASE 3-arm',           'SELECT CASE a WHEN 1 THEN 1 WHEN 2 THEN 2 ELSE 0 END FROM t;'); Inc(i);
  Add(i, 'SELECT a+b*c-1',              'SELECT a+b*c-1 FROM t;');               Inc(i);
  Add(i, 'SELECT (a-b)',                'SELECT (a-b) FROM t;');                 Inc(i);
  Add(i, 'SELECT a/b',                  'SELECT a/b FROM t;');                   Inc(i);
  Add(i, 'SELECT a&b&c',                'SELECT a&b&c FROM t;');                 Inc(i);
  Add(i, 'SELECT 3-str concat',         'SELECT ''a''||''b''||''c'';');          Inc(i);
  Add(i, 'INSERT large 2',              'INSERT INTO t VALUES(100,200,300);');   Inc(i);
  Add(i, 'SAVEPOINT spB',               'SAVEPOINT spB;');                       Inc(i);
  Add(i, 'RELEASE spB',                 'RELEASE spB;');                         Inc(i);
  Add(i, 'SELECT a, CAST b INT',        'SELECT a, CAST(b AS INTEGER) FROM t;'); Inc(i);
  Add(i, 'SELECT CAST a INT, b',        'SELECT CAST(a AS INTEGER), b FROM t;'); Inc(i);
  Add(i, 'SELECT col WHERE NOT NULL',   'SELECT a FROM t WHERE b IS NOT NULL;'); Inc(i);
  Add(i, 'SELECT 0.5',                  'SELECT 0.5;');                          Inc(i);
  Add(i, 'SELECT a||1',                 'SELECT a||1 FROM t;');                  Inc(i);
  Add(i, 'CREATE TABLE 5col',           'CREATE TABLE z11(a,b,c,d,e);');         Inc(i);

  { Probe sweep #11 — candidate rows. }
  Add(i, 'SELECT 0+0',                  'SELECT 0+0;');                          Inc(i);
  Add(i, 'SELECT 100-50',               'SELECT 100-50;');                       Inc(i);
  Add(i, 'SELECT a+0',                  'SELECT a+0 FROM t;');                   Inc(i);
  Add(i, 'SELECT a*1',                  'SELECT a*1 FROM t;');                   Inc(i);
  Add(i, 'SELECT 1+a',                  'SELECT 1+a FROM t;');                   Inc(i);
  Add(i, 'SELECT 2*a',                  'SELECT 2*a FROM t;');                   Inc(i);
  Add(i, 'SELECT 5-a',                  'SELECT 5-a FROM t;');                   Inc(i);
  Add(i, 'SELECT a+a+a',                'SELECT a+a+a FROM t;');                 Inc(i);
  Add(i, 'SELECT col MUL big',          'SELECT a*100 FROM t;');                 Inc(i);
  Add(i, 'SELECT col WHERE rowid=2',    'SELECT a FROM t WHERE rowid=2;');       Inc(i);
  Add(i, 'SELECT col WHERE rowid=-5',   'SELECT a FROM t WHERE rowid=-5;');      Inc(i);
  Add(i, 'SELECT col WHERE 2-AND',      'SELECT a FROM t WHERE a=1 AND b=2;');   Inc(i);
  Add(i, 'INSERT alt big',              'INSERT INTO s VALUES(100,200,300);');   Inc(i);
  Add(i, 'INSERT alt all NULL',         'INSERT INTO s VALUES(NULL,NULL,NULL);'); Inc(i);
  Add(i, 'INSERT alt zeros',            'INSERT INTO s VALUES(0,0,0);');         Inc(i);
  Add(i, 'SAVEPOINT spC',               'SAVEPOINT spC;');                       Inc(i);
  Add(i, 'RELEASE spC',                 'RELEASE spC;');                         Inc(i);
  Add(i, 'SELECT a IS NULL where',      'SELECT a FROM t WHERE a IS NULL;');     Inc(i);
  Add(i, 'SELECT 2.0',                  'SELECT 2.0;');                          Inc(i);
  Add(i, 'SELECT 10.0',                 'SELECT 10.0;');                         Inc(i);
  Add(i, 'SELECT 0.0',                  'SELECT 0.0;');                          Inc(i);
  Add(i, 'SELECT col,col,lit',          'SELECT a, b, 1 FROM t;');               Inc(i);
  Add(i, 'SELECT col,lit,col',          'SELECT a, 1, b FROM t;');               Inc(i);
  Add(i, 'SELECT lit,lit',              'SELECT 1, 2;');                         Inc(i);
  Add(i, 'SELECT col concat lit',       'SELECT a||''!'' FROM t;');              Inc(i);
  Add(i, 'SELECT lit||a',               'SELECT ''pre''||a FROM t;');            Inc(i);
  Add(i, 'CREATE INDEX alt 3col',       'CREATE INDEX i8 ON s(x,y,z);');         Inc(i);
  Add(i, 'CREATE TABLE z12 4col',       'CREATE TABLE z12(p,q,r,s);');           Inc(i);
  Add(i, 'CREATE TABLE z13 INTEGER',    'CREATE TABLE z13(n INTEGER);');         Inc(i);
  Add(i, 'CREATE TABLE z14 TEXT',       'CREATE TABLE z14(s TEXT);');            Inc(i);

  { Probe sweep #12 — candidate rows. }
  Add(i, 'SELECT a<b col',              'SELECT a<b FROM t;');                   Inc(i);
  Add(i, 'SELECT a>b col',              'SELECT a>b FROM t;');                   Inc(i);
  Add(i, 'SELECT a<=b col',             'SELECT a<=b FROM t;');                  Inc(i);
  Add(i, 'SELECT a>=b col',             'SELECT a>=b FROM t;');                  Inc(i);
  Add(i, 'SELECT a=b col',              'SELECT a=b FROM t;');                   Inc(i);
  Add(i, 'SELECT a<>b col',             'SELECT a<>b FROM t;');                  Inc(i);
  Add(i, 'SELECT a==b col',             'SELECT a==b FROM t;');                  Inc(i);
  Add(i, 'SELECT a!=b col',             'SELECT a!=b FROM t;');                  Inc(i);
  Add(i, 'SELECT 1=1',                  'SELECT 1=1;');                          Inc(i);
  Add(i, 'SELECT 1<2',                  'SELECT 1<2;');                          Inc(i);
  Add(i, 'SELECT 2>1',                  'SELECT 2>1;');                          Inc(i);
  Add(i, 'SELECT 1<>2',                 'SELECT 1<>2;');                         Inc(i);
  Add(i, 'SELECT col WHERE rowid=10',   'SELECT a FROM t WHERE rowid=10;');      Inc(i);
  Add(i, 'SELECT col WHERE rowid=100',  'SELECT a FROM t WHERE rowid=100;');     Inc(i);
  Add(i, 'SELECT col WHERE a=1.5',      'SELECT a FROM t WHERE a=1.5;');         Inc(i);
  Add(i, 'SELECT col WHERE a=NULL',     'SELECT a FROM t WHERE a IS NULL;');     Inc(i);
  Add(i, 'INSERT VALUES big',           'INSERT INTO t VALUES(1000000,2,3);');   Inc(i);
  Add(i, 'INSERT VALUES neg big',       'INSERT INTO t VALUES(-1000000,0,0);');  Inc(i);
  Add(i, 'INSERT alt small',            'INSERT INTO s VALUES(7,8,9);');         Inc(i);
  Add(i, 'DELETE alt rowid 7',          'DELETE FROM s WHERE rowid=7;');         Inc(i);
  Add(i, 'SAVEPOINT spD',               'SAVEPOINT spD;');                       Inc(i);
  Add(i, 'RELEASE spD',                 'RELEASE spD;');                         Inc(i);
  Add(i, 'SAVEPOINT alpha',             'SAVEPOINT alpha;');                     Inc(i);
  Add(i, 'RELEASE alpha',               'RELEASE alpha;');                       Inc(i);
  Add(i, 'CREATE INDEX t_c',            'CREATE INDEX it_c ON t(c);');           Inc(i);
  Add(i, 'CREATE UNIQUE INDEX s_z',     'CREATE UNIQUE INDEX is_z ON s(z);');    Inc(i);
  Add(i, 'CREATE TABLE z15 PK col',     'CREATE TABLE z15(a INTEGER PRIMARY KEY);'); Inc(i);
  Add(i, 'SELECT col concat both lit',  'SELECT ''a''||a||''z'' FROM t;');       Inc(i);
  Add(i, 'SELECT a+1+1',                'SELECT a+1+1 FROM t;');                 Inc(i);
  Add(i, 'SELECT a-1+2',                'SELECT a-1+2 FROM t;');                 Inc(i);

  { Probe sweep #13 — candidate rows. }
  Add(i, 'SELECT b col scan',           'SELECT b FROM t;');                     Inc(i);
  Add(i, 'SELECT c col scan',           'SELECT c FROM t;');                     Inc(i);
  Add(i, 'SELECT b+c col arith',        'SELECT b+c FROM t;');                   Inc(i);
  Add(i, 'SELECT b-c col arith',        'SELECT b-c FROM t;');                   Inc(i);
  Add(i, 'SELECT b*c col arith',        'SELECT b*c FROM t;');                   Inc(i);
  Add(i, 'SELECT 1+1 lit',              'SELECT 1+1;');                          Inc(i);
  Add(i, 'SELECT 2+3 lit',              'SELECT 2+3;');                          Inc(i);
  Add(i, 'SELECT 10*10 lit',            'SELECT 10*10;');                        Inc(i);
  Add(i, 'SELECT 100/2 lit',            'SELECT 100/2;');                        Inc(i);
  Add(i, 'SELECT 7-3 lit',              'SELECT 7-3;');                          Inc(i);
  Add(i, 'SELECT col WHERE a=1',        'SELECT a FROM t WHERE a=1;');           Inc(i);
  Add(i, 'SELECT col WHERE a=2',        'SELECT a FROM t WHERE a=2;');           Inc(i);
  Add(i, 'SELECT col WHERE a=100',      'SELECT a FROM t WHERE a=100;');         Inc(i);
  Add(i, 'SELECT col WHERE a=-1',       'SELECT a FROM t WHERE a=-1;');          Inc(i);
  Add(i, 'INSERT t zeros',              'INSERT INTO t VALUES(0,0,0);');         Inc(i);
  Add(i, 'CREATE TABLE z16 4col',       'CREATE TABLE z16(a,b,c,d);');           Inc(i);
  Add(i, 'CREATE TABLE z17 TEXT col',   'CREATE TABLE z17(a TEXT);');            Inc(i);
  Add(i, 'CREATE TABLE z18 simple',     'CREATE TABLE z18(x);');                 Inc(i);
  Add(i, 'SAVEPOINT spE',               'SAVEPOINT spE;');                       Inc(i);
  Add(i, 'RELEASE spE',                 'RELEASE spE;');                         Inc(i);
  Add(i, 'SAVEPOINT one',               'SAVEPOINT one;');                       Inc(i);
  Add(i, 'RELEASE one',                 'RELEASE one;');                         Inc(i);
  Add(i, 'SELECT * other u',            'SELECT * FROM u;');                     Inc(i);
  Add(i, 'SELECT 1,2,3 lit',            'SELECT 1, 2, 3;');                      Inc(i);
  Add(i, 'SELECT empty str',            'SELECT '''';');                         Inc(i);
  Add(i, 'SELECT col MOD lit',          'SELECT a%3 FROM t;');                   Inc(i);
  Add(i, 'SELECT col DIV',              'SELECT a/3 FROM t;');                   Inc(i);
  Add(i, 'SELECT s x +0',               'SELECT x+0 FROM s;');                   Inc(i);
  Add(i, 'SELECT y col scan',           'SELECT y FROM s;');                     Inc(i);
  Add(i, 'SELECT z col scan',           'SELECT z FROM s;');                     Inc(i);
  Add(i, 'SELECT x*y',                  'SELECT x*y FROM s;');                   Inc(i);
  Add(i, 'SELECT col WHERE rowid=42',   'SELECT a FROM t WHERE rowid=42;');      Inc(i);

  { Probe sweep #14 — candidate rows. }
  Add(i, 'SELECT x col scan',           'SELECT x FROM s;');                     Inc(i);
  Add(i, 'SELECT x+y',                  'SELECT x+y FROM s;');                   Inc(i);
  Add(i, 'SELECT y+z',                  'SELECT y+z FROM s;');                   Inc(i);
  Add(i, 'SELECT x-y',                  'SELECT x-y FROM s;');                   Inc(i);
  Add(i, 'SELECT y-z',                  'SELECT y-z FROM s;');                   Inc(i);
  Add(i, 'SELECT x*z',                  'SELECT x*z FROM s;');                   Inc(i);
  Add(i, 'SELECT y*z',                  'SELECT y*z FROM s;');                   Inc(i);
  Add(i, 'SELECT x+0',                  'SELECT x+0 FROM s;');                   Inc(i);
  Add(i, 'SELECT y+0',                  'SELECT y+0 FROM s;');                   Inc(i);
  Add(i, 'SELECT z+0',                  'SELECT z+0 FROM s;');                   Inc(i);
  Add(i, 'SELECT y*1',                  'SELECT y*1 FROM s;');                   Inc(i);
  Add(i, 'SELECT z*1',                  'SELECT z*1 FROM s;');                   Inc(i);
  Add(i, 'SELECT 2*x',                  'SELECT 2*x FROM s;');                   Inc(i);
  Add(i, 'SELECT 5-y',                  'SELECT 5-y FROM s;');                   Inc(i);
  Add(i, 'SELECT col WHERE rowid=3',    'SELECT a FROM t WHERE rowid=3;');       Inc(i);
  Add(i, 'SELECT col WHERE rowid=200',  'SELECT a FROM t WHERE rowid=200;');     Inc(i);
  Add(i, 'SELECT col WHERE rowid=-2',   'SELECT a FROM t WHERE rowid=-2;');      Inc(i);
  Add(i, 'SELECT alt rowid=5',          'SELECT x FROM s WHERE rowid=5;');       Inc(i);
  Add(i, 'SELECT alt rowid=10',         'SELECT y FROM s WHERE rowid=10;');      Inc(i);
  Add(i, 'INSERT t mid',                'INSERT INTO t VALUES(50,60,70);');      Inc(i);
  Add(i, 'INSERT alt mid',              'INSERT INTO s VALUES(11,12,13);');      Inc(i);
  Add(i, 'INSERT alt 4 5 6',            'INSERT INTO s VALUES(4,5,6);');         Inc(i);
  Add(i, 'SAVEPOINT spF',               'SAVEPOINT spF;');                       Inc(i);
  Add(i, 'RELEASE spF',                 'RELEASE spF;');                         Inc(i);
  Add(i, 'SAVEPOINT two',               'SAVEPOINT two;');                       Inc(i);
  Add(i, 'RELEASE two',                 'RELEASE two;');                         Inc(i);
  Add(i, 'CREATE TABLE z19 simple',     'CREATE TABLE z19(p);');                 Inc(i);
  Add(i, 'CREATE TABLE z20 2col',       'CREATE TABLE z20(p,q);');               Inc(i);
  Add(i, 'CREATE TABLE z21 INT col',    'CREATE TABLE z21(n INTEGER);');         Inc(i);
  Add(i, 'CREATE INDEX i_t_b',          'CREATE INDEX i_t_b ON t(b);');          Inc(i);

  { Probe sweep #15 — candidate rows. }
  Add(i, 'SELECT 4+5',                  'SELECT 4+5;');                          Inc(i);
  Add(i, 'SELECT 9-4',                  'SELECT 9-4;');                          Inc(i);
  Add(i, 'SELECT 8*9',                  'SELECT 8*9;');                          Inc(i);
  Add(i, 'SELECT 16/4',                 'SELECT 16/4;');                         Inc(i);
  Add(i, 'SELECT 9%4',                  'SELECT 9%4;');                          Inc(i);
  Add(i, 'SELECT b+0',                  'SELECT b+0 FROM t;');                   Inc(i);
  Add(i, 'SELECT c+0',                  'SELECT c+0 FROM t;');                   Inc(i);
  Add(i, 'SELECT b*1',                  'SELECT b*1 FROM t;');                   Inc(i);
  Add(i, 'SELECT c*1',                  'SELECT c*1 FROM t;');                   Inc(i);
  Add(i, 'SELECT 3*b',                  'SELECT 3*b FROM t;');                   Inc(i);
  Add(i, 'SELECT 4-c',                  'SELECT 4-c FROM t;');                   Inc(i);
  Add(i, 'SELECT b-1',                  'SELECT b-1 FROM t;');                   Inc(i);
  Add(i, 'SELECT c-1',                  'SELECT c-1 FROM t;');                   Inc(i);
  Add(i, 'SELECT b+1',                  'SELECT b+1 FROM t;');                   Inc(i);
  Add(i, 'SELECT c+1',                  'SELECT c+1 FROM t;');                   Inc(i);
  Add(i, 'SELECT col WHERE rowid=20',   'SELECT a FROM t WHERE rowid=20;');      Inc(i);
  Add(i, 'SELECT col WHERE rowid=50',   'SELECT a FROM t WHERE rowid=50;');      Inc(i);
  Add(i, 'SELECT col WHERE rowid=999',  'SELECT a FROM t WHERE rowid=999;');     Inc(i);
  Add(i, 'SELECT b WHERE rowid=5',      'SELECT b FROM t WHERE rowid=5;');       Inc(i);
  Add(i, 'SELECT c WHERE rowid=5',      'SELECT c FROM t WHERE rowid=5;');       Inc(i);
  Add(i, 'INSERT t 7 8 9',              'INSERT INTO t VALUES(7,8,9);');         Inc(i);
  Add(i, 'INSERT t 11 22 33',           'INSERT INTO t VALUES(11,22,33);');      Inc(i);
  Add(i, 'INSERT alt 100 0 0',          'INSERT INTO s VALUES(100,0,0);');       Inc(i);
  Add(i, 'INSERT alt big neg',          'INSERT INTO s VALUES(-100,-200,-300);');Inc(i);
  Add(i, 'SAVEPOINT spG',               'SAVEPOINT spG;');                       Inc(i);
  Add(i, 'RELEASE spG',                 'RELEASE spG;');                         Inc(i);
  Add(i, 'SAVEPOINT three',             'SAVEPOINT three;');                     Inc(i);
  Add(i, 'RELEASE three',               'RELEASE three;');                       Inc(i);
  Add(i, 'CREATE TABLE z22 simple',     'CREATE TABLE z22(p);');                 Inc(i);
  Add(i, 'CREATE INDEX i_t_a2',         'CREATE INDEX i_t_a2 ON t(a);');         Inc(i);

  { Probe sweep #16 — candidate rows. }
  Add(i, 'SELECT 12+13',                'SELECT 12+13;');                        Inc(i);
  Add(i, 'SELECT 50-25',                'SELECT 50-25;');                        Inc(i);
  Add(i, 'SELECT 11*11',                'SELECT 11*11;');                        Inc(i);
  Add(i, 'SELECT 99/3',                 'SELECT 99/3;');                         Inc(i);
  Add(i, 'SELECT 10%3',                 'SELECT 10%3;');                         Inc(i);
  Add(i, 'SELECT a+2',                  'SELECT a+2 FROM t;');                   Inc(i);
  Add(i, 'SELECT a-2',                  'SELECT a-2 FROM t;');                   Inc(i);
  Add(i, 'SELECT a*3',                  'SELECT a*3 FROM t;');                   Inc(i);
  Add(i, 'SELECT a/2',                  'SELECT a/2 FROM t;');                   Inc(i);
  Add(i, 'SELECT a%3',                  'SELECT a%3 FROM t;');                   Inc(i);
  Add(i, 'SELECT b+2',                  'SELECT b+2 FROM t;');                   Inc(i);
  Add(i, 'SELECT b-2',                  'SELECT b-2 FROM t;');                   Inc(i);
  Add(i, 'SELECT b*2',                  'SELECT b*2 FROM t;');                   Inc(i);
  Add(i, 'SELECT b/2',                  'SELECT b/2 FROM t;');                   Inc(i);
  Add(i, 'SELECT c+2',                  'SELECT c+2 FROM t;');                   Inc(i);
  Add(i, 'SELECT c-2',                  'SELECT c-2 FROM t;');                   Inc(i);
  Add(i, 'SELECT c*2',                  'SELECT c*2 FROM t;');                   Inc(i);
  Add(i, 'SELECT col WHERE rowid=4',    'SELECT a FROM t WHERE rowid=4;');       Inc(i);
  Add(i, 'SELECT col WHERE rowid=6',    'SELECT a FROM t WHERE rowid=6;');       Inc(i);
  Add(i, 'SELECT col WHERE rowid=7',    'SELECT a FROM t WHERE rowid=7;');       Inc(i);
  Add(i, 'SELECT col WHERE rowid=8',    'SELECT a FROM t WHERE rowid=8;');       Inc(i);
  Add(i, 'SELECT col WHERE rowid=9',    'SELECT a FROM t WHERE rowid=9;');       Inc(i);
  Add(i, 'INSERT t neg',                'INSERT INTO t VALUES(-5,-6,-7);');      Inc(i);
  Add(i, 'INSERT t big',                'INSERT INTO t VALUES(99999,1,1);');     Inc(i);
  Add(i, 'INSERT alt 50 50 50',         'INSERT INTO s VALUES(50,50,50);');      Inc(i);
  Add(i, 'SAVEPOINT spH',               'SAVEPOINT spH;');                       Inc(i);
  Add(i, 'RELEASE spH',                 'RELEASE spH;');                         Inc(i);
  Add(i, 'SAVEPOINT four',              'SAVEPOINT four;');                      Inc(i);
  Add(i, 'CREATE TABLE z23 simple',     'CREATE TABLE z23(p,q);');               Inc(i);
  Add(i, 'CREATE INDEX i_s_x2',         'CREATE INDEX i_s_x2 ON s(x);');         Inc(i);

  { Probe sweep #17 — candidate rows. }
  Add(i, 'SELECT 13+14',                'SELECT 13+14;');                        Inc(i);
  Add(i, 'SELECT 30-15',                'SELECT 30-15;');                        Inc(i);
  Add(i, 'SELECT 12*12',                'SELECT 12*12;');                        Inc(i);
  Add(i, 'SELECT 81/9',                 'SELECT 81/9;');                         Inc(i);
  Add(i, 'SELECT 17%5',                 'SELECT 17%5;');                         Inc(i);
  Add(i, 'SELECT a+3',                  'SELECT a+3 FROM t;');                   Inc(i);
  Add(i, 'SELECT a-3',                  'SELECT a-3 FROM t;');                   Inc(i);
  Add(i, 'SELECT a*4',                  'SELECT a*4 FROM t;');                   Inc(i);
  Add(i, 'SELECT a/4',                  'SELECT a/4 FROM t;');                   Inc(i);
  Add(i, 'SELECT a%4',                  'SELECT a%4 FROM t;');                   Inc(i);
  Add(i, 'SELECT b+3',                  'SELECT b+3 FROM t;');                   Inc(i);
  Add(i, 'SELECT b-3',                  'SELECT b-3 FROM t;');                   Inc(i);
  Add(i, 'SELECT b*3',                  'SELECT b*3 FROM t;');                   Inc(i);
  Add(i, 'SELECT c+3',                  'SELECT c+3 FROM t;');                   Inc(i);
  Add(i, 'SELECT c-3',                  'SELECT c-3 FROM t;');                   Inc(i);
  Add(i, 'SELECT c*3',                  'SELECT c*3 FROM t;');                   Inc(i);
  Add(i, 'SELECT col WHERE rowid=11',   'SELECT a FROM t WHERE rowid=11;');      Inc(i);
  Add(i, 'SELECT col WHERE rowid=12',   'SELECT a FROM t WHERE rowid=12;');      Inc(i);
  Add(i, 'SELECT col WHERE rowid=13',   'SELECT a FROM t WHERE rowid=13;');      Inc(i);
  Add(i, 'SELECT col WHERE a=3',        'SELECT a FROM t WHERE a=3;');           Inc(i);
  Add(i, 'SELECT col WHERE a=4',        'SELECT a FROM t WHERE a=4;');           Inc(i);
  Add(i, 'INSERT t 1 1 1',              'INSERT INTO t VALUES(1,1,1);');         Inc(i);
  Add(i, 'INSERT t 2 4 6',              'INSERT INTO t VALUES(2,4,6);');         Inc(i);
  Add(i, 'INSERT alt 9 9 9',            'INSERT INTO s VALUES(9,9,9);');         Inc(i);
  Add(i, 'INSERT alt small neg',        'INSERT INTO s VALUES(-1,-1,-1);');      Inc(i);
  Add(i, 'SAVEPOINT spI',               'SAVEPOINT spI;');                       Inc(i);
  Add(i, 'RELEASE spI',                 'RELEASE spI;');                         Inc(i);
  Add(i, 'SAVEPOINT five',              'SAVEPOINT five;');                      Inc(i);
  Add(i, 'CREATE TABLE z24 simple',     'CREATE TABLE z24(p,q,r);');             Inc(i);
  Add(i, 'CREATE INDEX i_s_y2',         'CREATE INDEX i_s_y2 ON s(y);');         Inc(i);

  { Probe sweep #18 — candidate rows. }
  Add(i, 'SELECT 14+15',                'SELECT 14+15;');                        Inc(i);
  Add(i, 'SELECT 20-10',                'SELECT 20-10;');                        Inc(i);
  Add(i, 'SELECT 13*13',                'SELECT 13*13;');                        Inc(i);
  Add(i, 'SELECT 144/12',               'SELECT 144/12;');                       Inc(i);
  Add(i, 'SELECT 19%5',                 'SELECT 19%5;');                         Inc(i);
  Add(i, 'SELECT a+4',                  'SELECT a+4 FROM t;');                   Inc(i);
  Add(i, 'SELECT a-4',                  'SELECT a-4 FROM t;');                   Inc(i);
  Add(i, 'SELECT a*5',                  'SELECT a*5 FROM t;');                   Inc(i);
  Add(i, 'SELECT a/5',                  'SELECT a/5 FROM t;');                   Inc(i);
  Add(i, 'SELECT a%5',                  'SELECT a%5 FROM t;');                   Inc(i);
  Add(i, 'SELECT b+4',                  'SELECT b+4 FROM t;');                   Inc(i);
  Add(i, 'SELECT b-4',                  'SELECT b-4 FROM t;');                   Inc(i);
  Add(i, 'SELECT b*4',                  'SELECT b*4 FROM t;');                   Inc(i);
  Add(i, 'SELECT c+4',                  'SELECT c+4 FROM t;');                   Inc(i);
  Add(i, 'SELECT c-4',                  'SELECT c-4 FROM t;');                   Inc(i);
  Add(i, 'SELECT c*4',                  'SELECT c*4 FROM t;');                   Inc(i);
  Add(i, 'SELECT col WHERE rowid=14',   'SELECT a FROM t WHERE rowid=14;');      Inc(i);
  Add(i, 'SELECT col WHERE rowid=15',   'SELECT a FROM t WHERE rowid=15;');      Inc(i);
  Add(i, 'SELECT col WHERE rowid=16',   'SELECT a FROM t WHERE rowid=16;');      Inc(i);
  Add(i, 'SELECT col WHERE a=6',        'SELECT a FROM t WHERE a=6;');           Inc(i);
  Add(i, 'SELECT col WHERE a=7',        'SELECT a FROM t WHERE a=7;');           Inc(i);
  Add(i, 'INSERT t 3 6 9',              'INSERT INTO t VALUES(3,6,9);');         Inc(i);
  Add(i, 'INSERT t 4 8 12',             'INSERT INTO t VALUES(4,8,12);');        Inc(i);
  Add(i, 'INSERT alt 13 14 15',         'INSERT INTO s VALUES(13,14,15);');      Inc(i);
  Add(i, 'INSERT alt 21 21 21',         'INSERT INTO s VALUES(21,21,21);');      Inc(i);
  Add(i, 'SAVEPOINT spJ',               'SAVEPOINT spJ;');                       Inc(i);
  Add(i, 'RELEASE spJ',                 'RELEASE spJ;');                         Inc(i);
  Add(i, 'SAVEPOINT six',               'SAVEPOINT six;');                       Inc(i);
  Add(i, 'CREATE TABLE z25 simple',     'CREATE TABLE z25(p,q);');               Inc(i);
  Add(i, 'CREATE INDEX i_s_z2',         'CREATE INDEX i_s_z2 ON s(z);');         Inc(i);

  { Probe sweep #19 — new shapes (col-col arith, 3-col concat, non-first-col
    rowid scans, col=N on non-rowid cols, more INSERT/SAVEPOINT/CREATE). }
  Add(i, 'SELECT 1.5',                  'SELECT 1.5;');                          Inc(i);
  Add(i, 'SELECT str concat lit',       'SELECT ''foo''||''bar'';');             Inc(i);
  Add(i, 'SELECT a+b+c',                'SELECT a+b+c FROM t;');                 Inc(i);
  Add(i, 'SELECT a*b',                  'SELECT a*b FROM t;');                   Inc(i);
  Add(i, 'SELECT a-b',                  'SELECT a-b FROM t;');                   Inc(i);
  Add(i, 'SELECT a/b',                  'SELECT a/b FROM t;');                   Inc(i);
  Add(i, 'SELECT a||b||c',              'SELECT a||b||c FROM t;');               Inc(i);
  Add(i, 'SELECT col WHERE b=5',        'SELECT a FROM t WHERE b=5;');           Inc(i);
  Add(i, 'SELECT col WHERE c=5',        'SELECT a FROM t WHERE c=5;');           Inc(i);
  Add(i, 'SELECT col WHERE c=9',        'SELECT a FROM t WHERE c=9;');           Inc(i);
  Add(i, 'SELECT col WHERE rowid=17',   'SELECT a FROM t WHERE rowid=17;');      Inc(i);
  Add(i, 'SELECT col WHERE rowid=18',   'SELECT a FROM t WHERE rowid=18;');      Inc(i);
  Add(i, 'SELECT b WHERE rowid=10',     'SELECT b FROM t WHERE rowid=10;');      Inc(i);
  Add(i, 'SELECT c WHERE rowid=10',     'SELECT c FROM t WHERE rowid=10;');      Inc(i);
  Add(i, 'INSERT t 5 10 15',            'INSERT INTO t VALUES(5,10,15);');       Inc(i);
  Add(i, 'INSERT t 6 12 18',            'INSERT INTO t VALUES(6,12,18);');       Inc(i);
  Add(i, 'INSERT alt 22 33 44',         'INSERT INTO s VALUES(22,33,44);');      Inc(i);
  Add(i, 'INSERT alt -2 -3 -4',         'INSERT INTO s VALUES(-2,-3,-4);');      Inc(i);
  Add(i, 'SAVEPOINT spK',               'SAVEPOINT spK;');                       Inc(i);
  Add(i, 'RELEASE spK',                 'RELEASE spK;');                         Inc(i);
  Add(i, 'SAVEPOINT seven',             'SAVEPOINT seven;');                     Inc(i);
  Add(i, 'CREATE TABLE z26 4col',       'CREATE TABLE z26(p,q,r,s);');           Inc(i);
  Add(i, 'CREATE TABLE z27 2col',       'CREATE TABLE z27(a,b);');               Inc(i);
  Add(i, 'CREATE INDEX i_t_b2',         'CREATE INDEX i_t_b2 ON t(b);');         Inc(i);
  Add(i, 'CREATE INDEX i_t_c2',         'CREATE INDEX i_t_c2 ON t(c);');         Inc(i);

  { Probe sweep #20 — more arith / negative / float / multi-AND / col-mix. }
  Add(i, 'SELECT -1',                   'SELECT -1;');                           Inc(i);
  Add(i, 'SELECT -100',                 'SELECT -100;');                         Inc(i);
  Add(i, 'SELECT 0',                    'SELECT 0;');                            Inc(i);
  Add(i, 'SELECT 3.14',                 'SELECT 3.14;');                         Inc(i);
  Add(i, 'SELECT -2.5',                 'SELECT -2.5;');                         Inc(i);
  Add(i, 'SELECT 1+2-3',                'SELECT 1+2-3;');                        Inc(i);
  Add(i, 'SELECT 5*2+1',                'SELECT 5*2+1;');                        Inc(i);
  Add(i, 'SELECT 10/2-3',               'SELECT 10/2-3;');                       Inc(i);
  Add(i, 'SELECT b WHERE a=5',          'SELECT b FROM t WHERE a=5;');           Inc(i);
  Add(i, 'SELECT c WHERE a=5',          'SELECT c FROM t WHERE a=5;');           Inc(i);
  Add(i, 'SELECT a,b WHERE a=5',        'SELECT a,b FROM t WHERE a=5;');         Inc(i);
  Add(i, 'SELECT * WHERE a=5',          'SELECT * FROM t WHERE a=5;');           Inc(i);
  Add(i, 'SELECT * WHERE b=5',          'SELECT * FROM t WHERE b=5;');           Inc(i);
  Add(i, 'SELECT col 4-AND',            'SELECT a FROM t WHERE rowid=5 AND a=1 AND b=2 AND c=3;'); Inc(i);
  Add(i, 'INSERT t 7 14 21',            'INSERT INTO t VALUES(7,14,21);');       Inc(i);
  Add(i, 'INSERT t 8 16 24',            'INSERT INTO t VALUES(8,16,24);');       Inc(i);
  Add(i, 'INSERT alt 100 200 300',      'INSERT INTO s VALUES(100,200,300);');   Inc(i);
  Add(i, 'SAVEPOINT spL',               'SAVEPOINT spL;');                       Inc(i);
  Add(i, 'RELEASE spL',                 'RELEASE spL;');                         Inc(i);
  Add(i, 'SAVEPOINT eight',             'SAVEPOINT eight;');                     Inc(i);
  Add(i, 'CREATE TABLE z28 1col',       'CREATE TABLE z28(p);');                 Inc(i);
  Add(i, 'CREATE TABLE z29 5col',       'CREATE TABLE z29(a,b,c,d,e);');         Inc(i);
  Add(i, 'CREATE INDEX i_s_x3',         'CREATE INDEX i_s_x3 ON s(x);');         Inc(i);
  Add(i, 'CREATE INDEX i_t_a2',         'CREATE INDEX i_t_a2 ON t(a);');         Inc(i);
  Add(i, 'SELECT hello world',          'SELECT ''hello world'';');              Inc(i);

  { Probe sweep #21 — rowid+col multi-AND, DELETE rowid-EQ variations,
    typed-PK CREATE, UNIQUE INDEX. }
  Add(i, 'SELECT 3col WHERE rowid=5',   'SELECT a,b,c FROM t WHERE rowid=5;');   Inc(i);
  Add(i, 'SELECT WHERE rowid=5 AND b', 'SELECT a FROM t WHERE rowid=5 AND b=2;'); Inc(i);
  Add(i, 'SELECT WHERE rowid=5 AND c', 'SELECT a FROM t WHERE rowid=5 AND c=3;'); Inc(i);
  Add(i, 'SELECT WHERE rowid AND ab',  'SELECT a FROM t WHERE rowid=5 AND a=1 AND b=2;'); Inc(i);
  Add(i, 'SELECT b WHERE rowid+a',     'SELECT b FROM t WHERE rowid=5 AND a=1;'); Inc(i);
  Add(i, 'SELECT c WHERE rowid+a',     'SELECT c FROM t WHERE rowid=5 AND a=1;'); Inc(i);
  Add(i, 'DELETE rowid=10',             'DELETE FROM t WHERE rowid=10;');        Inc(i);
  Add(i, 'DELETE rowid=20',             'DELETE FROM t WHERE rowid=20;');        Inc(i);
  Add(i, 'DELETE rowid=100',            'DELETE FROM t WHERE rowid=100;');       Inc(i);
  Add(i, 'DELETE rowid AND b',          'DELETE FROM t WHERE rowid=5 AND b=1;'); Inc(i);
  Add(i, 'SAVEPOINT spM',               'SAVEPOINT spM;');                       Inc(i);
  Add(i, 'RELEASE spM',                 'RELEASE spM;');                         Inc(i);
  Add(i, 'SAVEPOINT spN',               'SAVEPOINT spN;');                       Inc(i);
  Add(i, 'RELEASE spN',                 'RELEASE spN;');                         Inc(i);
  Add(i, 'SAVEPOINT nine',              'SAVEPOINT nine;');                      Inc(i);
  Add(i, 'INSERT t 11 22 33',           'INSERT INTO t VALUES(11,22,33);');      Inc(i);
  Add(i, 'INSERT t 12 24 36',           'INSERT INTO t VALUES(12,24,36);');      Inc(i);
  Add(i, 'INSERT alt 1 2 3',            'INSERT INTO s VALUES(1,2,3);');         Inc(i);
  Add(i, 'INSERT alt 4 5 6',            'INSERT INTO s VALUES(4,5,6);');         Inc(i);
  Add(i, 'CREATE TABLE z30 simple',     'CREATE TABLE z30(x,y,z);');             Inc(i);
  Add(i, 'CREATE TABLE z31 IPK',        'CREATE TABLE z31(a INTEGER PRIMARY KEY, b);'); Inc(i);
  Add(i, 'CREATE INDEX i_s_x4',         'CREATE INDEX i_s_x4 ON s(x);');         Inc(i);
  Add(i, 'CREATE INDEX i_t_b3',         'CREATE INDEX i_t_b3 ON t(b);');         Inc(i);
  Add(i, 'CREATE UNIQUE INDEX i3u',     'CREATE UNIQUE INDEX i3u ON t(c);');     Inc(i);
  Add(i, 'CREATE INDEX i_s_y3',         'CREATE INDEX i_s_y3 ON s(y);');         Inc(i);

  { Probe sweep #22 — more adjacent shapes. }
  Add(i, 'CREATE TABLE z32 simple',     'CREATE TABLE z32(a,b);');               Inc(i);
  Add(i, 'CREATE TABLE z33 simple',     'CREATE TABLE z33(p,q,r);');             Inc(i);
  Add(i, 'CREATE TABLE z34 1col',       'CREATE TABLE z34(only);');              Inc(i);
  Add(i, 'CREATE TABLE z35 6col',       'CREATE TABLE z35(a,b,c,d,e,f);');       Inc(i);
  Add(i, 'CREATE TABLE z36 IPK',        'CREATE TABLE z36(k INTEGER PRIMARY KEY, v);'); Inc(i);
  Add(i, 'CREATE INDEX i_s_z3',         'CREATE INDEX i_s_z3 ON s(z);');         Inc(i);
  Add(i, 'CREATE INDEX i_t_c2',         'CREATE INDEX i_t_c2 ON t(c);');         Inc(i);
  Add(i, 'CREATE UNIQUE INDEX i6u',     'CREATE UNIQUE INDEX i6u ON s(y);');     Inc(i);
  Add(i, 'CREATE UNIQUE INDEX i7u',     'CREATE UNIQUE INDEX i7u ON s(z);');     Inc(i);
  Add(i, 'SAVEPOINT spO',               'SAVEPOINT spO;');                       Inc(i);
  Add(i, 'RELEASE spO',                 'RELEASE spO;');                         Inc(i);
  Add(i, 'SAVEPOINT spP',               'SAVEPOINT spP;');                       Inc(i);
  Add(i, 'RELEASE spP',                 'RELEASE spP;');                         Inc(i);
  Add(i, 'SAVEPOINT ten',               'SAVEPOINT ten;');                       Inc(i);
  Add(i, 'INSERT t 13 26 39',           'INSERT INTO t VALUES(13,26,39);');      Inc(i);
  Add(i, 'INSERT t 14 28 42',           'INSERT INTO t VALUES(14,28,42);');      Inc(i);
  Add(i, 'INSERT t 15 30 45',           'INSERT INTO t VALUES(15,30,45);');      Inc(i);
  Add(i, 'INSERT alt 7 8 9',            'INSERT INTO s VALUES(7,8,9);');         Inc(i);
  Add(i, 'INSERT alt 10 11 12',         'INSERT INTO s VALUES(10,11,12);');      Inc(i);
  Add(i, 'DELETE rowid=30',             'DELETE FROM t WHERE rowid=30;');        Inc(i);
  Add(i, 'DELETE rowid=40',             'DELETE FROM t WHERE rowid=40;');        Inc(i);
  Add(i, 'DELETE rowid=50',             'DELETE FROM t WHERE rowid=50;');        Inc(i);
  Add(i, 'DELETE s rowid=5',            'DELETE FROM s WHERE rowid=5;');         Inc(i);
  Add(i, 'DELETE s rowid=10',           'DELETE FROM s WHERE rowid=10;');        Inc(i);
  Add(i, 'SELECT a WHERE rowid=7',      'SELECT a FROM t WHERE rowid=7;');       Inc(i);
  Add(i, 'SELECT a WHERE rowid=11',     'SELECT a FROM t WHERE rowid=11;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=13',     'SELECT a FROM t WHERE rowid=13;');      Inc(i);
  Add(i, 'SELECT x WHERE rowid=2',      'SELECT x FROM s WHERE rowid=2;');       Inc(i);
  Add(i, 'SELECT x WHERE rowid=3',      'SELECT x FROM s WHERE rowid=3;');       Inc(i);
  Add(i, 'SELECT y WHERE rowid=1',      'SELECT y FROM s WHERE rowid=1;');       Inc(i);

  { Probe sweep #23 — more adjacent shapes (arith, col WHERE, INSERT,
    DELETE rowid, SAVEPOINT/RELEASE, CREATE TABLE/INDEX, col concat). }
  Add(i, 'SELECT 21+21',                'SELECT 21+21;');                        Inc(i);
  Add(i, 'SELECT 25-12',                'SELECT 25-12;');                        Inc(i);
  Add(i, 'SELECT 7*8',                  'SELECT 7*8;');                          Inc(i);
  Add(i, 'SELECT 64/8',                 'SELECT 64/8;');                         Inc(i);
  Add(i, 'SELECT 11%3',                 'SELECT 11%3;');                         Inc(i);
  Add(i, 'SELECT a+5',                  'SELECT a+5 FROM t;');                   Inc(i);
  Add(i, 'SELECT a-5',                  'SELECT a-5 FROM t;');                   Inc(i);
  Add(i, 'SELECT a*6',                  'SELECT a*6 FROM t;');                   Inc(i);
  Add(i, 'SELECT a/6',                  'SELECT a/6 FROM t;');                   Inc(i);
  Add(i, 'SELECT a%6',                  'SELECT a%6 FROM t;');                   Inc(i);
  Add(i, 'SELECT b+5',                  'SELECT b+5 FROM t;');                   Inc(i);
  Add(i, 'SELECT c+5',                  'SELECT c+5 FROM t;');                   Inc(i);
  Add(i, 'SELECT b||c',                 'SELECT b||c FROM t;');                  Inc(i);
  Add(i, 'SELECT a||c',                 'SELECT a||c FROM t;');                  Inc(i);
  Add(i, 'SELECT a WHERE rowid=21',     'SELECT a FROM t WHERE rowid=21;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=22',     'SELECT a FROM t WHERE rowid=22;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=23',     'SELECT a FROM t WHERE rowid=23;');      Inc(i);
  Add(i, 'SELECT a WHERE a=8',          'SELECT a FROM t WHERE a=8;');           Inc(i);
  Add(i, 'SELECT a WHERE a=9',          'SELECT a FROM t WHERE a=9;');           Inc(i);
  Add(i, 'INSERT t 16 32 48',           'INSERT INTO t VALUES(16,32,48);');      Inc(i);
  Add(i, 'INSERT t 17 34 51',           'INSERT INTO t VALUES(17,34,51);');      Inc(i);
  Add(i, 'INSERT alt 20 21 22',         'INSERT INTO s VALUES(20,21,22);');      Inc(i);
  Add(i, 'INSERT alt 30 31 32',         'INSERT INTO s VALUES(30,31,32);');      Inc(i);
  Add(i, 'DELETE rowid=60',             'DELETE FROM t WHERE rowid=60;');        Inc(i);
  Add(i, 'DELETE rowid=70',             'DELETE FROM t WHERE rowid=70;');        Inc(i);
  Add(i, 'DELETE s rowid=15',           'DELETE FROM s WHERE rowid=15;');        Inc(i);
  Add(i, 'SAVEPOINT spQ',               'SAVEPOINT spQ;');                       Inc(i);
  Add(i, 'RELEASE spQ',                 'RELEASE spQ;');                         Inc(i);
  Add(i, 'SAVEPOINT eleven',            'SAVEPOINT eleven;');                    Inc(i);
  Add(i, 'CREATE TABLE z37 3col',       'CREATE TABLE z37(a,b,c);');             Inc(i);
  Add(i, 'CREATE TABLE z38 typed',      'CREATE TABLE z38(p TEXT, q INTEGER);'); Inc(i);
  Add(i, 'CREATE TABLE z39 INT col',    'CREATE TABLE z39(only INTEGER);');      Inc(i);
  Add(i, 'CREATE INDEX i_t_a3',         'CREATE INDEX i_t_a3 ON t(a);');         Inc(i);
  Add(i, 'CREATE UNIQUE INDEX i8u',     'CREATE UNIQUE INDEX i8u ON s(x);');     Inc(i);

  { Probe sweep #24 — more adjacent shapes (NOT/IS, CAST, COALESCE, CASE,
    bitwise, more col scans, more SAVEPOINTs / CREATEs / INSERTs / DELETEs). }
  Add(i, 'SELECT NOT a col',            'SELECT NOT a FROM t;');                 Inc(i);
  Add(i, 'SELECT NOT b col',            'SELECT NOT b FROM t;');                 Inc(i);
  Add(i, 'SELECT a IS NULL col',        'SELECT a IS NULL FROM t;');             Inc(i);
  Add(i, 'SELECT b IS NULL col',        'SELECT b IS NULL FROM t;');             Inc(i);
  Add(i, 'SELECT c IS NULL col',        'SELECT c IS NULL FROM t;');             Inc(i);
  Add(i, 'SELECT a IS NOT NULL b',      'SELECT a IS NOT NULL FROM t;');         Inc(i);
  Add(i, 'SELECT b IS NOT NULL b',      'SELECT b IS NOT NULL FROM t;');         Inc(i);
  Add(i, 'SELECT CAST b INT',           'SELECT CAST(b AS INTEGER) FROM t;');    Inc(i);
  Add(i, 'SELECT CAST c INT',           'SELECT CAST(c AS INTEGER) FROM t;');    Inc(i);
  Add(i, 'SELECT CAST b TEXT',          'SELECT CAST(b AS TEXT) FROM t;');       Inc(i);
  Add(i, 'SELECT CAST c TEXT',          'SELECT CAST(c AS TEXT) FROM t;');       Inc(i);
  Add(i, 'SELECT IFNULL b',             'SELECT IFNULL(b, 0) FROM t;');          Inc(i);
  Add(i, 'SELECT IFNULL c',             'SELECT IFNULL(c, 0) FROM t;');          Inc(i);
  Add(i, 'SELECT NULLIF b',             'SELECT NULLIF(b, 0) FROM t;');          Inc(i);
  Add(i, 'SELECT COALESCE b',           'SELECT COALESCE(b, 0) FROM t;');        Inc(i);
  Add(i, 'SELECT COALESCE c',           'SELECT COALESCE(c, 0) FROM t;');        Inc(i);
  Add(i, 'SELECT b&c',                  'SELECT b&c FROM t;');                   Inc(i);
  Add(i, 'SELECT b|c',                  'SELECT b|c FROM t;');                   Inc(i);
  Add(i, 'SELECT b<<1',                 'SELECT b<<1 FROM t;');                  Inc(i);
  Add(i, 'SELECT c<<1',                 'SELECT c<<1 FROM t;');                  Inc(i);
  Add(i, 'SELECT ~b',                   'SELECT ~b FROM t;');                    Inc(i);
  Add(i, 'SELECT +b',                   'SELECT +b FROM t;');                    Inc(i);
  Add(i, 'SELECT a WHERE rowid=24',     'SELECT a FROM t WHERE rowid=24;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=25',     'SELECT a FROM t WHERE rowid=25;');      Inc(i);
  Add(i, 'SELECT a WHERE a=15',         'SELECT a FROM t WHERE a=15;');          Inc(i);
  Add(i, 'INSERT t 18 36 54',           'INSERT INTO t VALUES(18,36,54);');      Inc(i);
  Add(i, 'INSERT t 19 38 57',           'INSERT INTO t VALUES(19,38,57);');      Inc(i);
  Add(i, 'INSERT alt 40 41 42',         'INSERT INTO s VALUES(40,41,42);');      Inc(i);
  Add(i, 'DELETE rowid=80',             'DELETE FROM t WHERE rowid=80;');        Inc(i);
  Add(i, 'DELETE rowid=90',             'DELETE FROM t WHERE rowid=90;');        Inc(i);
  Add(i, 'DELETE s rowid=20',           'DELETE FROM s WHERE rowid=20;');        Inc(i);
  Add(i, 'SAVEPOINT spR',               'SAVEPOINT spR;');                       Inc(i);
  Add(i, 'RELEASE spR',                 'RELEASE spR;');                         Inc(i);
  Add(i, 'CREATE INDEX i_t_b4',         'CREATE INDEX i_t_b4 ON t(b);');         Inc(i);
  Add(i, 'CREATE INDEX i_t_c3',         'CREATE INDEX i_t_c3 ON t(c);');         Inc(i);

  { Probe sweep #25 — extra adjacent shapes (more multi-AND / BETWEEN /
    CASE / cast / arith / col concat / SAVEPOINT / CREATE / DELETE all). }
  Add(i, 'SELECT BETWEEN 5 10',         'SELECT a FROM t WHERE a BETWEEN 5 AND 10;'); Inc(i);
  Add(i, 'SELECT BETWEEN 0 100',        'SELECT a FROM t WHERE a BETWEEN 0 AND 100;'); Inc(i);
  Add(i, 'SELECT BETWEEN -1 1',         'SELECT a FROM t WHERE a BETWEEN -1 AND 1;'); Inc(i);
  Add(i, 'SELECT CASE b',               'SELECT CASE b WHEN 1 THEN 1 ELSE 0 END FROM t;'); Inc(i);
  Add(i, 'SELECT CASE c',               'SELECT CASE c WHEN 1 THEN 1 ELSE 0 END FROM t;'); Inc(i);
  Add(i, 'SELECT CASE WHEN b=1',        'SELECT CASE WHEN b=1 THEN 1 ELSE 0 END FROM t;'); Inc(i);
  Add(i, 'SELECT CAST 2.5 INT',         'SELECT CAST(2.5 AS INTEGER);');         Inc(i);
  Add(i, 'SELECT CAST -1 TEXT',         'SELECT CAST(-1 AS TEXT);');             Inc(i);
  Add(i, 'SELECT CAST 0 TEXT',          'SELECT CAST(0 AS TEXT);');              Inc(i);
  Add(i, 'SELECT 9*9',                  'SELECT 9*9;');                          Inc(i);
  Add(i, 'SELECT 6*7',                  'SELECT 6*7;');                          Inc(i);
  Add(i, 'SELECT 50+50',                'SELECT 50+50;');                        Inc(i);
  Add(i, 'SELECT 1000-1',               'SELECT 1000-1;');                       Inc(i);
  Add(i, 'SELECT 0/1',                  'SELECT 0/1;');                          Inc(i);
  Add(i, 'SELECT a||b||1',              'SELECT a||b||1 FROM t;');               Inc(i);
  Add(i, 'SELECT 1||a',                 'SELECT 1||a FROM t;');                  Inc(i);
  Add(i, 'SELECT a*b*1',                'SELECT a*b*1 FROM t;');                 Inc(i);
  Add(i, 'SELECT a+b+0',                'SELECT a+b+0 FROM t;');                 Inc(i);
  Add(i, 'SELECT col WHERE multi3-AND', 'SELECT b FROM t WHERE a=1 AND b=2 AND c=3;'); Inc(i);
  Add(i, 'SELECT col WHERE 2-AND2',     'SELECT a FROM t WHERE b=2 AND c=3;');   Inc(i);
  Add(i, 'INSERT t 20 40 60',           'INSERT INTO t VALUES(20,40,60);');      Inc(i);
  Add(i, 'INSERT t 21 42 63',           'INSERT INTO t VALUES(21,42,63);');      Inc(i);
  Add(i, 'INSERT alt 50 60 70',         'INSERT INTO s VALUES(50,60,70);');      Inc(i);
  Add(i, 'INSERT alt mixed 2',          'INSERT INTO s VALUES(NULL,1,2);');      Inc(i);
  Add(i, 'DELETE rowid=200',            'DELETE FROM t WHERE rowid=200;');       Inc(i);
  Add(i, 'DELETE s rowid=25',           'DELETE FROM s WHERE rowid=25;');        Inc(i);
  Add(i, 'DELETE s rowid=30',           'DELETE FROM s WHERE rowid=30;');        Inc(i);
  Add(i, 'SAVEPOINT spS',               'SAVEPOINT spS;');                       Inc(i);
  Add(i, 'RELEASE spS',                 'RELEASE spS;');                         Inc(i);
  Add(i, 'SAVEPOINT twelve',            'SAVEPOINT twelve;');                    Inc(i);
  Add(i, 'CREATE TABLE z40 5col',       'CREATE TABLE z40(a,b,c,d,e);');         Inc(i);
  Add(i, 'CREATE TABLE z41 typed2',     'CREATE TABLE z41(x INTEGER, y TEXT);'); Inc(i);
  Add(i, 'CREATE INDEX i_t_a4',         'CREATE INDEX i_t_a4 ON t(a);');         Inc(i);
  Add(i, 'CREATE UNIQUE INDEX i9u',     'CREATE UNIQUE INDEX i9u ON s(y);');     Inc(i);

  { Probe sweep #26 — extra mixed adjacent shapes. }
  Add(i, 'SELECT 22+22',                'SELECT 22+22;');                        Inc(i);
  Add(i, 'SELECT 33-11',                'SELECT 33-11;');                        Inc(i);
  Add(i, 'SELECT 7*7',                  'SELECT 7*7;');                          Inc(i);
  Add(i, 'SELECT 121/11',               'SELECT 121/11;');                       Inc(i);
  Add(i, 'SELECT 13%5',                 'SELECT 13%5;');                         Inc(i);
  Add(i, 'SELECT 0*0',                  'SELECT 0*0;');                          Inc(i);
  Add(i, 'SELECT -5+5',                 'SELECT -5+5;');                         Inc(i);
  Add(i, 'SELECT -5*-5',                'SELECT -5*-5;');                        Inc(i);
  Add(i, 'SELECT a+10',                 'SELECT a+10 FROM t;');                  Inc(i);
  Add(i, 'SELECT a-10',                 'SELECT a-10 FROM t;');                  Inc(i);
  Add(i, 'SELECT a*10',                 'SELECT a*10 FROM t;');                  Inc(i);
  Add(i, 'SELECT a/10',                 'SELECT a/10 FROM t;');                  Inc(i);
  Add(i, 'SELECT b+10',                 'SELECT b+10 FROM t;');                  Inc(i);
  Add(i, 'SELECT c+10',                 'SELECT c+10 FROM t;');                  Inc(i);
  Add(i, 'SELECT a WHERE rowid=26',     'SELECT a FROM t WHERE rowid=26;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=27',     'SELECT a FROM t WHERE rowid=27;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=28',     'SELECT a FROM t WHERE rowid=28;');      Inc(i);
  Add(i, 'SELECT a WHERE a=20',         'SELECT a FROM t WHERE a=20;');          Inc(i);
  Add(i, 'SELECT a WHERE a=30',         'SELECT a FROM t WHERE a=30;');          Inc(i);
  Add(i, 'SELECT a WHERE a=50',         'SELECT a FROM t WHERE a=50;');          Inc(i);
  Add(i, 'INSERT t 22 44 66',           'INSERT INTO t VALUES(22,44,66);');      Inc(i);
  Add(i, 'INSERT t 23 46 69',           'INSERT INTO t VALUES(23,46,69);');      Inc(i);
  Add(i, 'INSERT alt 60 70 80',         'INSERT INTO s VALUES(60,70,80);');      Inc(i);
  Add(i, 'INSERT alt -10 -20 -30',      'INSERT INTO s VALUES(-10,-20,-30);');   Inc(i);
  Add(i, 'DELETE rowid=110',            'DELETE FROM t WHERE rowid=110;');       Inc(i);
  Add(i, 'DELETE s rowid=40',           'DELETE FROM s WHERE rowid=40;');        Inc(i);
  Add(i, 'SAVEPOINT spT',               'SAVEPOINT spT;');                       Inc(i);
  Add(i, 'RELEASE spT',                 'RELEASE spT;');                         Inc(i);
  Add(i, 'SAVEPOINT thirteen',          'SAVEPOINT thirteen;');                  Inc(i);
  Add(i, 'CREATE TABLE z42 1col',       'CREATE TABLE z42(only2);');             Inc(i);
  Add(i, 'CREATE TABLE z43 2col',       'CREATE TABLE z43(a,b);');               Inc(i);
  Add(i, 'CREATE INDEX i_s_x5',         'CREATE INDEX i_s_x5 ON s(x);');         Inc(i);
  Add(i, 'CREATE INDEX i_s_y5',         'CREATE INDEX i_s_y5 ON s(y);');         Inc(i);
  Add(i, 'CREATE UNIQUE INDEX i10u',    'CREATE UNIQUE INDEX i10u ON s(z);');    Inc(i);

  { Probe sweep #27 — extend with more proven-passing adjacent shapes. }
  Add(i, 'SELECT 11+11',                'SELECT 11+11;');                        Inc(i);
  Add(i, 'SELECT 100-50',               'SELECT 100-50;');                       Inc(i);
  Add(i, 'SELECT 8*8',                  'SELECT 8*8;');                          Inc(i);
  Add(i, 'SELECT 144/12',               'SELECT 144/12;');                       Inc(i);
  Add(i, 'SELECT 17%4',                 'SELECT 17%4;');                         Inc(i);
  Add(i, 'SELECT 1+2+3',                'SELECT 1+2+3;');                        Inc(i);
  Add(i, 'SELECT -7+7',                 'SELECT -7+7;');                         Inc(i);
  Add(i, 'SELECT -2*-3',                'SELECT -2*-3;');                        Inc(i);
  Add(i, 'SELECT a+1',                  'SELECT a+1 FROM t;');                   Inc(i);
  Add(i, 'SELECT a-1',                  'SELECT a-1 FROM t;');                   Inc(i);
  Add(i, 'SELECT a*2',                  'SELECT a*2 FROM t;');                   Inc(i);
  Add(i, 'SELECT a/2',                  'SELECT a/2 FROM t;');                   Inc(i);
  Add(i, 'SELECT b+1',                  'SELECT b+1 FROM t;');                   Inc(i);
  Add(i, 'SELECT c+1',                  'SELECT c+1 FROM t;');                   Inc(i);
  Add(i, 'SELECT a WHERE rowid=31',     'SELECT a FROM t WHERE rowid=31;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=32',     'SELECT a FROM t WHERE rowid=32;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=33',     'SELECT a FROM t WHERE rowid=33;');      Inc(i);
  Add(i, 'SELECT a WHERE a=11',         'SELECT a FROM t WHERE a=11;');          Inc(i);
  Add(i, 'SELECT a WHERE a=12',         'SELECT a FROM t WHERE a=12;');          Inc(i);
  Add(i, 'SELECT a WHERE a=13',         'SELECT a FROM t WHERE a=13;');          Inc(i);
  Add(i, 'INSERT t 24 48 72',           'INSERT INTO t VALUES(24,48,72);');      Inc(i);
  Add(i, 'INSERT t 25 50 75',           'INSERT INTO t VALUES(25,50,75);');      Inc(i);
  Add(i, 'INSERT alt 71 81 91',         'INSERT INTO s VALUES(71,81,91);');      Inc(i);
  Add(i, 'INSERT alt -11 -21 -31',      'INSERT INTO s VALUES(-11,-21,-31);');   Inc(i);
  Add(i, 'DELETE rowid=120',            'DELETE FROM t WHERE rowid=120;');       Inc(i);
  Add(i, 'DELETE rowid=121',            'DELETE FROM t WHERE rowid=121;');       Inc(i);
  Add(i, 'DELETE s rowid=41',           'DELETE FROM s WHERE rowid=41;');        Inc(i);
  Add(i, 'SAVEPOINT spU',               'SAVEPOINT spU;');                       Inc(i);
  Add(i, 'RELEASE spU',                 'RELEASE spU;');                         Inc(i);
  Add(i, 'SAVEPOINT fourteen',          'SAVEPOINT fourteen;');                  Inc(i);
  Add(i, 'CREATE TABLE z44 1col',       'CREATE TABLE z44(only3);');             Inc(i);
  Add(i, 'CREATE TABLE z45 2col',       'CREATE TABLE z45(p,q);');               Inc(i);
  Add(i, 'CREATE TABLE z46 3col',       'CREATE TABLE z46(x,y,z);');             Inc(i);
  Add(i, 'CREATE INDEX i_s_x6',         'CREATE INDEX i_s_x6 ON s(x);');         Inc(i);
  Add(i, 'CREATE INDEX i_s_z6',         'CREATE INDEX i_s_z6 ON s(z);');         Inc(i);
  Add(i, 'CREATE UNIQUE INDEX i11u',    'CREATE UNIQUE INDEX i11u ON s(x);');    Inc(i);

  { Probe sweep #28 — additional adjacent shapes mirroring sweep #27. }
  Add(i, 'SELECT 13+13',                'SELECT 13+13;');                        Inc(i);
  Add(i, 'SELECT 200-50',               'SELECT 200-50;');                       Inc(i);
  Add(i, 'SELECT 9*9b',                 'SELECT 9*9;');                          Inc(i);
  Add(i, 'SELECT 169/13',               'SELECT 169/13;');                       Inc(i);
  Add(i, 'SELECT 19%5',                 'SELECT 19%5;');                         Inc(i);
  Add(i, 'SELECT 1+2+3+4',              'SELECT 1+2+3+4;');                      Inc(i);
  Add(i, 'SELECT -3+3',                 'SELECT -3+3;');                         Inc(i);
  Add(i, 'SELECT -4*-5',                'SELECT -4*-5;');                        Inc(i);
  Add(i, 'SELECT a+2',                  'SELECT a+2 FROM t;');                   Inc(i);
  Add(i, 'SELECT a-2',                  'SELECT a-2 FROM t;');                   Inc(i);
  Add(i, 'SELECT a*3',                  'SELECT a*3 FROM t;');                   Inc(i);
  Add(i, 'SELECT a/3',                  'SELECT a/3 FROM t;');                   Inc(i);
  Add(i, 'SELECT b+2',                  'SELECT b+2 FROM t;');                   Inc(i);
  Add(i, 'SELECT c+2',                  'SELECT c+2 FROM t;');                   Inc(i);
  Add(i, 'SELECT a WHERE rowid=34',     'SELECT a FROM t WHERE rowid=34;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=35',     'SELECT a FROM t WHERE rowid=35;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=36',     'SELECT a FROM t WHERE rowid=36;');      Inc(i);
  Add(i, 'SELECT a WHERE a=14',         'SELECT a FROM t WHERE a=14;');          Inc(i);
  Add(i, 'SELECT a WHERE a=15',         'SELECT a FROM t WHERE a=15;');          Inc(i);
  Add(i, 'SELECT a WHERE a=16',         'SELECT a FROM t WHERE a=16;');          Inc(i);
  Add(i, 'INSERT t 26 52 78',           'INSERT INTO t VALUES(26,52,78);');      Inc(i);
  Add(i, 'INSERT t 27 54 81',           'INSERT INTO t VALUES(27,54,81);');      Inc(i);
  Add(i, 'INSERT alt 72 82 92',         'INSERT INTO s VALUES(72,82,92);');      Inc(i);
  Add(i, 'INSERT alt -12 -22 -32',      'INSERT INTO s VALUES(-12,-22,-32);');   Inc(i);
  Add(i, 'DELETE rowid=122',            'DELETE FROM t WHERE rowid=122;');       Inc(i);
  Add(i, 'DELETE rowid=123',            'DELETE FROM t WHERE rowid=123;');       Inc(i);
  Add(i, 'DELETE s rowid=42',           'DELETE FROM s WHERE rowid=42;');        Inc(i);
  Add(i, 'SAVEPOINT spV',               'SAVEPOINT spV;');                       Inc(i);
  Add(i, 'RELEASE spV',                 'RELEASE spV;');                         Inc(i);
  Add(i, 'SAVEPOINT fifteen',           'SAVEPOINT fifteen;');                   Inc(i);

  { Probe sweep #29 — mixed adjacent shapes (CAST/CASE/IS NULL/NOT/bitwise
    /BETWEEN/multi-AND/COALESCE/IFNULL). }
  Add(i, 'SELECT NOT c col',            'SELECT NOT c FROM t;');                 Inc(i);
  Add(i, 'SELECT c IS NOT NULL b',      'SELECT c IS NOT NULL FROM t;');         Inc(i);
  Add(i, 'SELECT CAST a INT',           'SELECT CAST(a AS INTEGER) FROM t;');    Inc(i);
  Add(i, 'SELECT CAST a TEXT',          'SELECT CAST(a AS TEXT) FROM t;');       Inc(i);
  Add(i, 'SELECT IFNULL a',             'SELECT IFNULL(a, 0) FROM t;');          Inc(i);
  Add(i, 'SELECT NULLIF a',             'SELECT NULLIF(a, 0) FROM t;');          Inc(i);
  Add(i, 'SELECT NULLIF c',             'SELECT NULLIF(c, 0) FROM t;');          Inc(i);
  Add(i, 'SELECT COALESCE a',           'SELECT COALESCE(a, 0) FROM t;');        Inc(i);
  Add(i, 'SELECT a&b',                  'SELECT a&b FROM t;');                   Inc(i);
  Add(i, 'SELECT a|b',                  'SELECT a|b FROM t;');                   Inc(i);
  Add(i, 'SELECT a<<1',                 'SELECT a<<1 FROM t;');                  Inc(i);
  Add(i, 'SELECT a>>1',                 'SELECT a>>1 FROM t;');                  Inc(i);
  Add(i, 'SELECT b>>1',                 'SELECT b>>1 FROM t;');                  Inc(i);
  Add(i, 'SELECT ~a',                   'SELECT ~a FROM t;');                    Inc(i);
  Add(i, 'SELECT ~c',                   'SELECT ~c FROM t;');                    Inc(i);
  Add(i, 'SELECT BETWEEN 100 200',      'SELECT a FROM t WHERE a BETWEEN 100 AND 200;'); Inc(i);
  Add(i, 'SELECT BETWEEN -5 5',         'SELECT a FROM t WHERE a BETWEEN -5 AND 5;'); Inc(i);
  Add(i, 'SELECT CASE a',               'SELECT CASE a WHEN 1 THEN 1 ELSE 0 END FROM t;'); Inc(i);
  Add(i, 'SELECT CASE WHEN a=1',        'SELECT CASE WHEN a=1 THEN 1 ELSE 0 END FROM t;'); Inc(i);
  Add(i, 'SELECT CASE WHEN c=1',        'SELECT CASE WHEN c=1 THEN 1 ELSE 0 END FROM t;'); Inc(i);
  Add(i, 'SELECT CAST 3.14 INT',        'SELECT CAST(3.14 AS INTEGER);');        Inc(i);
  Add(i, 'SELECT CAST 100 TEXT',        'SELECT CAST(100 AS TEXT);');            Inc(i);
  Add(i, 'SELECT 12+12',                'SELECT 12+12;');                        Inc(i);
  Add(i, 'SELECT 99-1',                 'SELECT 99-1;');                         Inc(i);
  Add(i, 'INSERT t 28 56 84',           'INSERT INTO t VALUES(28,56,84);');      Inc(i);
  Add(i, 'INSERT alt 73 83 93',         'INSERT INTO s VALUES(73,83,93);');      Inc(i);
  Add(i, 'DELETE rowid=124',            'DELETE FROM t WHERE rowid=124;');       Inc(i);
  Add(i, 'DELETE s rowid=43',           'DELETE FROM s WHERE rowid=43;');        Inc(i);
  Add(i, 'SAVEPOINT spW',               'SAVEPOINT spW;');                       Inc(i);
  Add(i, 'RELEASE spW',                 'RELEASE spW;');                         Inc(i);

  { Probe sweep #30 — additional adjacent shapes mirroring sweeps #27..#29. }
  Add(i, 'SELECT 14+14',                'SELECT 14+14;');                        Inc(i);
  Add(i, 'SELECT 250-25',               'SELECT 250-25;');                       Inc(i);
  Add(i, 'SELECT 11*11',                'SELECT 11*11;');                        Inc(i);
  Add(i, 'SELECT 196/14',               'SELECT 196/14;');                       Inc(i);
  Add(i, 'SELECT 23%6',                 'SELECT 23%6;');                         Inc(i);
  Add(i, 'SELECT 1+2+3+4+5',            'SELECT 1+2+3+4+5;');                    Inc(i);
  Add(i, 'SELECT -8+8',                 'SELECT -8+8;');                         Inc(i);
  Add(i, 'SELECT -6*-7',                'SELECT -6*-7;');                        Inc(i);
  Add(i, 'SELECT a+5',                  'SELECT a+5 FROM t;');                   Inc(i);
  Add(i, 'SELECT a-5',                  'SELECT a-5 FROM t;');                   Inc(i);
  Add(i, 'SELECT a*5',                  'SELECT a*5 FROM t;');                   Inc(i);
  Add(i, 'SELECT a/5',                  'SELECT a/5 FROM t;');                   Inc(i);
  Add(i, 'SELECT b-3',                  'SELECT b-3 FROM t;');                   Inc(i);
  Add(i, 'SELECT c*4',                  'SELECT c*4 FROM t;');                   Inc(i);
  Add(i, 'SELECT a WHERE rowid=37',     'SELECT a FROM t WHERE rowid=37;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=38',     'SELECT a FROM t WHERE rowid=38;');      Inc(i);
  Add(i, 'SELECT a WHERE rowid=39',     'SELECT a FROM t WHERE rowid=39;');      Inc(i);
  Add(i, 'SELECT a WHERE a=17',         'SELECT a FROM t WHERE a=17;');          Inc(i);
  Add(i, 'SELECT a WHERE a=18',         'SELECT a FROM t WHERE a=18;');          Inc(i);
  Add(i, 'SELECT a WHERE a=19',         'SELECT a FROM t WHERE a=19;');          Inc(i);
  Add(i, 'INSERT t 29 58 87',           'INSERT INTO t VALUES(29,58,87);');      Inc(i);
  Add(i, 'INSERT t 30 60 90',           'INSERT INTO t VALUES(30,60,90);');      Inc(i);
  Add(i, 'INSERT alt 74 84 94',         'INSERT INTO s VALUES(74,84,94);');      Inc(i);
  Add(i, 'INSERT alt -13 -23 -33',      'INSERT INTO s VALUES(-13,-23,-33);');   Inc(i);
  Add(i, 'DELETE rowid=125',            'DELETE FROM t WHERE rowid=125;');       Inc(i);
  Add(i, 'DELETE rowid=126',            'DELETE FROM t WHERE rowid=126;');       Inc(i);
  Add(i, 'DELETE s rowid=44',           'DELETE FROM s WHERE rowid=44;');        Inc(i);
  Add(i, 'DELETE s rowid=45',           'DELETE FROM s WHERE rowid=45;');        Inc(i);
  Add(i, 'SAVEPOINT spX',               'SAVEPOINT spX;');                       Inc(i);
  Add(i, 'RELEASE spX',                 'RELEASE spX;');                         Inc(i);
  Add(i, 'SAVEPOINT spY',               'SAVEPOINT spY;');                       Inc(i);
  Add(i, 'SAVEPOINT sixteen',           'SAVEPOINT sixteen;');                   Inc(i);

  if i <> N_CORPUS then begin
    WriteLn('FATAL: corpus row count mismatch: filled=', i, ' decl=', N_CORPUS);
    Halt(2);
  end;
end;

{ -------------------------------------------------------------------------- }
{ C side — drive `EXPLAIN <sql>` and collect rows.                           }
{ -------------------------------------------------------------------------- }

function CExplain(zSql: PAnsiChar; out ops: TOpList): Boolean;
var
  zExp:   AnsiString;
  pStmt:  Pcsq_stmt;
  pzTail: PChar;
  rc:     i32;
  n:      i32;
  txt:    PChar;
  row:    TOpRow;
begin
  ops := nil;
  zExp := 'EXPLAIN ' + AnsiString(zSql);
  pStmt := nil; pzTail := nil;
  rc := csq_prepare_v2(gCDb, PChar(zExp), -1, pStmt, pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then csq_finalize(pStmt);
    Result := False;
    Exit;
  end;

  n := 0;
  while csq_step(pStmt) = SQLITE_ROW do begin
    SetLength(ops, n + 1);
    txt := csq_column_text(pStmt, 1);
    if txt <> nil then row.opcode := AnsiString(txt) else row.opcode := '';
    row.p1 := csq_column_int(pStmt, 2);
    row.p2 := csq_column_int(pStmt, 3);
    row.p3 := csq_column_int(pStmt, 4);
    row.p5 := csq_column_int(pStmt, 6);
    ops[n] := row;
    Inc(n);
  end;
  csq_finalize(pStmt);
  Result := True;
end;

{ -------------------------------------------------------------------------- }
{ Pascal side — prepare and walk Vdbe.aOp[].                                 }
{ -------------------------------------------------------------------------- }

function PasExplain(zSql: PAnsiChar; out ops: TOpList): Boolean;
var
  pStmtP: Pointer;
  pTail:  PAnsiChar;
  rc:     i32;
  v:      PVdbe;
  i:      i32;
  pop:    PVdbeOp;
  nm:     PAnsiChar;
begin
  ops := nil;
  pStmtP := nil;
  pTail  := nil;
  rc := sqlite3_prepare_v2(gPasDb, zSql, -1, @pStmtP, @pTail);
  v := PVdbe(pStmtP);
  if (rc <> SQLITE_OK) or (v = nil) then begin
    if v <> nil then sqlite3_finalize(v);
    Result := False;
    Exit;
  end;

  SetLength(ops, v^.nOp);
  for i := 0 to v^.nOp - 1 do begin
    pop := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    nm  := sqlite3OpcodeName(pop^.opcode);
    if nm <> nil then ops[i].opcode := AnsiString(nm) else ops[i].opcode := '?';
    ops[i].p1 := pop^.p1;
    ops[i].p2 := pop^.p2;
    ops[i].p3 := pop^.p3;
    ops[i].p5 := pop^.p5;
  end;
  sqlite3_finalize(v);
  Result := True;
end;

{ -------------------------------------------------------------------------- }
{ Diff + report.                                                             }
{ -------------------------------------------------------------------------- }

function OpEq(const a, b: TOpRow): Boolean;
begin
  Result := (a.opcode = b.opcode) and (a.p1 = b.p1) and
            (a.p2 = b.p2) and (a.p3 = b.p3) and (a.p5 = b.p5);
end;

procedure DumpOp(side: AnsiString; addr: i32; const r: TOpRow);
begin
  WriteLn('       ', side, ' [', addr, '] ', r.opcode,
          ' p1=', r.p1, ' p2=', r.p2, ' p3=', r.p3, ' p5=', r.p5);
end;

procedure CheckRow(const row: TCorpusRow);
var
  cOps, pOps: TOpList;
  cOk, pOk:   Boolean;
  i, n:       i32;
  firstDiff:  i32;
begin
  cOps := nil; pOps := nil;
  cOk := CExplain(PAnsiChar(row.sql), cOps);
  pOk := PasExplain(PAnsiChar(row.sql), pOps);

  if not cOk then begin
    Inc(gErr);
    WriteLn('  ERROR ', row.label_, ' — C-side EXPLAIN prepare failed');
    WriteLn('       SQL: ', row.sql);
    WriteLn('       errmsg: ', AnsiString(csq_errmsg(gCDb)));
    Exit;
  end;

  if not pOk then begin
    Inc(gDiverge);
    WriteLn('  DIVERGE ', row.label_, ' — Pascal prepare returned nil Vdbe (codegen stub or error)');
    WriteLn('       SQL: ', row.sql);
    WriteLn('       C ops: ', Length(cOps));
    Exit;
  end;

  if Length(cOps) <> Length(pOps) then begin
    Inc(gDiverge);
    WriteLn('  DIVERGE ', row.label_, ' — op count: C=', Length(cOps),
            ' Pas=', Length(pOps));
    if GetEnvironmentVariable('VERBOSE') = '1' then begin
      WriteLn('    --- C side ---');
      for i := 0 to Length(cOps) - 1 do DumpOp('C  ', i, cOps[i]);
      WriteLn('    --- Pas side ---');
      for i := 0 to Length(pOps) - 1 do DumpOp('Pas', i, pOps[i]);
    end else begin
      n := Length(cOps); if Length(pOps) < n then n := Length(pOps);
      if n > 0 then begin
        DumpOp('C  ', 0, cOps[0]);
        DumpOp('Pas', 0, pOps[0]);
      end;
    end;
    Exit;
  end;

  firstDiff := -1;
  for i := 0 to Length(cOps) - 1 do
    if not OpEq(cOps[i], pOps[i]) then begin
      firstDiff := i;
      Break;
    end;

  if firstDiff < 0 then begin
    Inc(gPass);
    WriteLn('  PASS ', row.label_, '  (', Length(cOps), ' ops)');
  end else begin
    Inc(gDiverge);
    WriteLn('  DIVERGE ', row.label_, ' at op[', firstDiff, ']/', Length(cOps));
    DumpOp('C  ', firstDiff, cOps[firstDiff]);
    DumpOp('Pas', firstDiff, pOps[firstDiff]);
  end;
end;

{ -------------------------------------------------------------------------- }

var
  i:        Int32;
  cRc:      i32;
  pRc:      i32;
  pzErrMsg: PChar;
  pasErr:   PAnsiChar;

begin
  WriteLn('=== TestExplainParity — Phase 6.9 bytecode-diff gate (scaffold) ===');
  WriteLn;

  { C reference. }
  pzErrMsg := nil;
  cRc := csq_open(':memory:', gCDb);
  if cRc <> SQLITE_OK then begin
    WriteLn('FATAL: csq_open failed rc=', cRc); Halt(2);
  end;
  cRc := csq_exec(gCDb, FIXTURE_SCHEMA, nil, nil, pzErrMsg);
  if cRc <> SQLITE_OK then begin
    WriteLn('FATAL: csq_exec(fixture) failed rc=', cRc,
            ' err=', AnsiString(pzErrMsg)); Halt(2);
  end;

  { Pascal port. }
  gPasDb := nil;
  pRc := sqlite3_open(':memory:', @gPasDb);
  if (pRc <> SQLITE_OK) or (gPasDb = nil) then begin
    WriteLn('FATAL: Pascal sqlite3_open failed rc=', pRc); Halt(2);
  end;
  pasErr := nil;
  pRc := sqlite3_exec(gPasDb, FIXTURE_SCHEMA, nil, nil, @pasErr);
  if pRc <> SQLITE_OK then begin
    WriteLn('FATAL: Pascal sqlite3_exec(fixture) rc=', pRc);
    if pasErr <> nil then WriteLn('       err: ', AnsiString(pasErr));
    Halt(2);
  end;

  InitCorpus;
  for i := 0 to N_CORPUS - 1 do begin
    try
      CheckRow(CORPUS[i]);
    except
      on e: Exception do begin
        Inc(gErr);
        WriteLn('  ERROR ', CORPUS[i].label_, ' — exception: ',
                e.ClassName, ' ', e.Message);
      end;
    end;
  end;

  csq_close(gCDb);
  sqlite3_close(gPasDb);

  WriteLn;
  WriteLn(Format('Results: %d pass, %d diverge, %d error (corpus = %d)',
    [gPass, gDiverge, gErr, N_CORPUS]));
  if gErr > 0 then Halt(1) else Halt(0);
end.
