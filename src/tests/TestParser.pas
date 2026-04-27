{$I ../passqlite3.inc}
{
  TestParser.pas — Phase 7.4 differential parser gate.

  For each SQL fragment in an inline corpus, drive both:
    * the C reference parser via csq_prepare_v2 / csq_finalize, and
    * the Pascal port's sqlite3RunParser
  and assert that they agree on syntactic validity (rc=SQLITE_OK
  iff nErr=0).

  Scope note: the original Phase 7.4 wording asks for byte-for-byte VDBE
  diff.  That requires the Pascal sqlite3_prepare_v2 to actually wire the
  parser into codegen + emit a Vdbe — which is currently a Phase 6.x stub
  awaiting Phase 8.2 (sqlite3_prepare_v2 port from main.c).  Until that
  lands the only differential signal we can compare is parser-level
  validity — which is exactly what this test does.  The bytecode diff
  half is tracked in tasklist.md as "Phase 7.4b" and will reuse the same
  corpus once Phase 8.2 is complete.

  Corpus selection: a Pascal-side parse drives the Lemon reduce actions,
  which immediately call the codegen helpers in passqlite3codegen for
  most non-DDL forms.  Several of those helpers still depend on a fully
  open db (sqlite3Select, sqlite3Pragma, sqlite3CreateView,
  sqlite3FinishCoding under EXPLAIN, COMMIT/ROLLBACK, ANALYZE, VACUUM,
  REINDEX, CTE-bearing DML).  Calling them with the lightweight stub
  database used by this test crashes mid-parse.  Those forms are
  deliberately excluded here — the same exclusion list is applied in
  TestParserSmoke — and will be folded back into the corpus in 7.4b
  once Phase 8 ships sqlite3_open_v2.

  The shared C database is opened on ":memory:" with a small fixture
  schema (t/s/u) so DML/SELECT against those names compile cleanly on
  the C side; the Pascal parser does not consult schema state during
  parse, so the same statements parse on both sides.
}

program TestParser;

uses
  SysUtils,
  csqlite3,
  passqlite3types,
  passqlite3util,
  passqlite3codegen,
  passqlite3parser;

const
  FIXTURE_SCHEMA: PChar =
    'CREATE TABLE t(a, b, c);' +
    'CREATE TABLE s(x, y, z);' +
    'CREATE TABLE u(p PRIMARY KEY, q);';

type
  TCorpusRow = record
    label_:    AnsiString;
    sql:       AnsiString;
    expectOk:  Boolean;   { True = expected to parse cleanly on both sides }
  end;

var
  gPass, gFail: i32;
  gCDb:         Pcsq_db;

{ -------------------------------------------------------------------------- }
{ Pascal-side parse driver — mirrors TestParserSmoke's RunParser.            }
{ -------------------------------------------------------------------------- }

function MakePascalDb: PTsqlite3;
var
  db: PTsqlite3;
begin
  db := PTsqlite3(AllocMem(SizeOf(TSqlite3)));
  db^.nDb := 2;
  db^.eOpenState := 1;
  db^.aDb := @db^.aDbStatic[0];
  db^.aDb[0].zDbSName := 'main';
  db^.aDb[1].zDbSName := 'temp';
  db^.aLimit[SQLITE_LIMIT_SQL_LENGTH] := 1000000000;
  db^.aLimit[SQLITE_LIMIT_EXPR_DEPTH] := 1000;
  db^.aLimit[SQLITE_LIMIT_COLUMN]     := 2000;
  db^.aLimit[SQLITE_LIMIT_VDBE_OP]    := 250000000;
  db^.lookaside.bDisable := 1;
  db^.flags := db^.flags or (u64($00040) shl 32);  { SQLITE_Comments }
  Result := db;
end;

function PascalParseOk(zSql: PAnsiChar): Boolean;
var
  db:    PTsqlite3;
  parse: PParse;
  nErr:  i32;
begin
  db    := MakePascalDb;
  parse := PParse(AllocMem(SizeOf(TParse)));
  sqlite3ParseObjectInit(parse, db);
  sqlite3RunParser(parse, zSql);
  nErr := parse^.nErr;
  sqlite3ParseObjectReset(parse);
  FreeMem(parse);
  FreeMem(db);
  Result := (nErr = 0);
end;

{ -------------------------------------------------------------------------- }
{ C-side parse driver — prepare_v2 against shared in-memory db.             }
{ -------------------------------------------------------------------------- }

function CParseOk(zSql: PAnsiChar): Boolean;
var
  pStmt:  Pcsq_stmt;
  pzTail: PChar;
  rc:     i32;
begin
  pStmt  := nil;
  pzTail := nil;
  rc := csq_prepare_v2(gCDb, zSql, -1, pStmt, pzTail);
  if pStmt <> nil then csq_finalize(pStmt);
  Result := (rc = SQLITE_OK);
end;

{ -------------------------------------------------------------------------- }

procedure CheckRow(const row: TCorpusRow);
var
  cOk, pOk: Boolean;
  detail:   AnsiString;
begin
  cOk := CParseOk(PAnsiChar(row.sql));
  pOk := PascalParseOk(PAnsiChar(row.sql));

  if (cOk = pOk) and (cOk = row.expectOk) then begin
    Inc(gPass);
    WriteLn('  PASS ', row.label_);
  end else begin
    Inc(gFail);
    detail := '[expect=' + BoolToStr(row.expectOk, True) +
              ' c=' + BoolToStr(cOk, True) +
              ' pas=' + BoolToStr(pOk, True) + ']';
    WriteLn('  FAIL ', row.label_, ' ', detail);
    WriteLn('       SQL: ', row.sql);
    if not cOk then
      WriteLn('       C errmsg: ', AnsiString(csq_errmsg(gCDb)));
  end;
end;

{ -------------------------------------------------------------------------- }
{ Inline corpus.                                                             }
{ -------------------------------------------------------------------------- }

const
  N_CORPUS = 45;

var
  CORPUS: array[0..N_CORPUS - 1] of TCorpusRow;

procedure InitCorpus;
  procedure Add(i: Int32; const lbl, sql: AnsiString; ok: Boolean);
  begin
    CORPUS[i].label_   := lbl;
    CORPUS[i].sql      := sql;
    CORPUS[i].expectOk := ok;
  end;
var i: Int32;
begin
  i := 0;

  { Group A — empty / trivial. }
  Add(i, 'empty string',                '',                                                  True); Inc(i);
  Add(i, 'whitespace',                  '   '#10' ',                                         True); Inc(i);
  Add(i, 'line comment only',           '-- a comment'#10,                                   True); Inc(i);
  Add(i, 'block comment only',          '/* hi */',                                          True); Inc(i);
  Add(i, 'semicolon',                   ';',                                                 True); Inc(i);

  { Group B — DDL. }
  Add(i, 'CREATE TABLE simple',         'CREATE TABLE z1(a,b);',                             True); Inc(i);
  Add(i, 'CREATE TABLE typed',          'CREATE TABLE z2(a INTEGER PRIMARY KEY, b TEXT NOT NULL);', True); Inc(i);
  Add(i, 'CREATE TABLE IF NOT EXISTS',  'CREATE TABLE IF NOT EXISTS z3(x);',                 True); Inc(i);
  Add(i, 'CREATE TABLE w/ default',     'CREATE TABLE z4(a INT DEFAULT 0, b TEXT DEFAULT '''');', True); Inc(i);
  Add(i, 'CREATE TABLE check',          'CREATE TABLE z5(a INT CHECK(a > 0));',              True); Inc(i);
  Add(i, 'CREATE TABLE FK',             'CREATE TABLE z6(a INT REFERENCES t(a));',           True); Inc(i);
  Add(i, 'CREATE TABLE composite PK',   'CREATE TABLE z7(a,b, PRIMARY KEY(a,b));',           True); Inc(i);
  Add(i, 'CREATE TABLE WITHOUT ROWID',  'CREATE TABLE z8(a PRIMARY KEY, b) WITHOUT ROWID;',  True); Inc(i);
  Add(i, 'CREATE TEMP TABLE',           'CREATE TEMP TABLE z9(a);',                          True); Inc(i);
  Add(i, 'CREATE INDEX',                'CREATE INDEX i1 ON t(a);',                          True); Inc(i);
  Add(i, 'CREATE UNIQUE INDEX',         'CREATE UNIQUE INDEX i2 ON t(b);',                   True); Inc(i);
  Add(i, 'CREATE INDEX partial',        'CREATE INDEX i3 ON t(c) WHERE c IS NOT NULL;',      True); Inc(i);
  Add(i, 'DROP TABLE',                  'DROP TABLE t;',                                     True); Inc(i);
  Add(i, 'DROP TABLE IF EXISTS',        'DROP TABLE IF EXISTS nope;',                        True); Inc(i);
  Add(i, 'DROP INDEX IF EXISTS',        'DROP INDEX IF EXISTS i_nope;',                      True); Inc(i);
  Add(i, 'ALTER TABLE rename',          'ALTER TABLE t RENAME TO tt;',                       True); Inc(i);
  Add(i, 'ALTER TABLE add column',      'ALTER TABLE t ADD COLUMN d INT;',                   True); Inc(i);

  { Group C — DML.  Excluded from this round: forms that route through
    sqlite3Select / sqlite3SelectNew during reduce (INSERT...SELECT,
    UPDATE FROM, DELETE WHERE-IN-SELECT, CTE DML).  See header note. }
  Add(i, 'INSERT VALUES',               'INSERT INTO t VALUES (1,2,3);',                     True); Inc(i);
  Add(i, 'INSERT cols',                 'INSERT INTO t(a,b) VALUES (1,2);',                  True); Inc(i);
  Add(i, 'INSERT default',              'INSERT INTO t DEFAULT VALUES;',                     True); Inc(i);
  Add(i, 'INSERT multi-row',            'INSERT INTO t VALUES (1,2,3),(4,5,6);',             True); Inc(i);
  Add(i, 'INSERT OR REPLACE',           'INSERT OR REPLACE INTO t VALUES (1,2,3);',          True); Inc(i);
  Add(i, 'INSERT INTO SELECT *',        'INSERT INTO t SELECT * FROM s;',                    True); Inc(i);
  Add(i, 'UPDATE simple',               'UPDATE t SET a=1 WHERE b=2;',                       True); Inc(i);
  Add(i, 'UPDATE multi',                'UPDATE t SET a=a+1, b=b||''x'' WHERE c IS NULL;',   True); Inc(i);
  Add(i, 'UPDATE OR IGNORE',            'UPDATE OR IGNORE t SET a=1;',                       True); Inc(i);
  Add(i, 'DELETE simple',               'DELETE FROM t WHERE a=1;',                          True); Inc(i);
  Add(i, 'DELETE all',                  'DELETE FROM t;',                                    True); Inc(i);

  { Group D — transactions and savepoints (codegen-safe subset). }
  Add(i, 'BEGIN',                       'BEGIN;',                                            True); Inc(i);
  Add(i, 'BEGIN IMMEDIATE',             'BEGIN IMMEDIATE;',                                  True); Inc(i);
  Add(i, 'BEGIN EXCLUSIVE',             'BEGIN EXCLUSIVE TRANSACTION;',                      True); Inc(i);
  Add(i, 'SAVEPOINT',                   'SAVEPOINT sp1;',                                    True); Inc(i);
  Add(i, 'RELEASE',                     'RELEASE sp1;',                                      True); Inc(i);
  Add(i, 'ROLLBACK TO SAVEPOINT',       'ROLLBACK TO SAVEPOINT sp1;',                        True); Inc(i);

  { Group E — syntax errors.  Both implementations must reject. }
  Add(i, 'err: bare CREATE',            'CREATE',                                            False); Inc(i);
  Add(i, 'err: CREATE TABLE no body',   'CREATE TABLE',                                      False); Inc(i);
  Add(i, 'err: garbage word',           'CREATE GARBAGE foo',                                False); Inc(i);
  Add(i, 'err: INSERT trailing comma',  'INSERT INTO t VALUES (1,2,);',                      False); Inc(i);
  Add(i, 'err: unbalanced parens',      'CREATE TABLE z(a INT CHECK(a > 0;',                 False); Inc(i);
  Add(i, 'err: bad keyword sequence',   'INSERT t VALUES (1);',                              False); Inc(i);

  if i <> N_CORPUS then begin
    WriteLn('FATAL: corpus row count mismatch: filled=', i, ' decl=', N_CORPUS);
    Halt(2);
  end;
end;

var
  i:        Int32;
  cRc:      i32;
  pzErrMsg: PChar;

begin
  WriteLn('=== TestParser — Phase 7.4 differential parser gate ===');
  WriteLn;

  { Open shared C reference db and install the fixture schema. }
  pzErrMsg := nil;
  cRc := csq_open(':memory:', gCDb);
  if cRc <> SQLITE_OK then begin
    WriteLn('FATAL: csq_open failed rc=', cRc);
    Halt(2);
  end;
  cRc := csq_exec(gCDb, FIXTURE_SCHEMA, nil, nil, pzErrMsg);
  if cRc <> SQLITE_OK then begin
    WriteLn('FATAL: csq_exec(fixture) failed rc=', cRc, ' err=', AnsiString(pzErrMsg));
    Halt(2);
  end;

  InitCorpus;

  for i := 0 to N_CORPUS - 1 do
    CheckRow(CORPUS[i]);

  csq_close(gCDb);

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed (corpus = %d)', [gPass, gFail, N_CORPUS]));
  if gFail > 0 then Halt(1);
end.
