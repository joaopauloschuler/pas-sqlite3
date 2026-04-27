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
  N_CORPUS = 198;

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
