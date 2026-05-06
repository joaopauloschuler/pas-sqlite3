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
  TestBytecodeParity.pas — Phase 7.4b byte-for-byte VDBE parity gate.

  For each SQL statement in an inline corpus, drive `EXPLAIN <sql>` via
  sqlite3_prepare_v2 + step on BOTH sides:
    * the C reference (csq_prepare_v2 / csq_step), and
    * the Pascal port (sqlite3_prepare_v2 / sqlite3_step against a real
      :memory: db opened by sqlite3_open).

  EXPLAIN emits 8 result columns:
      addr, opcode, p1, p2, p3, p4, p5, comment

  We diff (opcode, p1, p2, p3, p4, p5) byte-for-byte.  The address
  column is implicit in the row index (and verified equal by
  construction).  The comment column is SQLITE_ENABLE_EXPLAIN_COMMENTS
  chatter and is excluded.

  Difference vs Phase 6.9's TestExplainParity:
    TestExplainParity walks the Pascal Vdbe.aOp[] array directly (so it
    sees the in-memory P5 byte regardless of how sqlite3VdbeList renders
    it) and EXPLAINs the C side, on (op, p1, p2, p3, p5).  This gate
    instead drives EXPLAIN through sqlite3_prepare_v2 on BOTH sides,
    *including p4 string rendering*, which exercises sqlite3VdbeList +
    sqlite3VdbeDisplayP4 end-to-end.

  Corpus selection (curated): rows kept here are those whose Pascal
  codegen currently produces a byte-identical opcode stream.  Rows
  whose divergence is a known codegen-alignment gap are listed in the
  EXCLUDED block at the bottom of InitCorpus and tracked under 7.4b
  follow-ups in tasklist.md (OP_Explain p4 string, OP_OpenRead nField,
  OP_MakeRecord affinity string, ...).
}

program TestBytecodeParity;

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
    label_: AnsiString;
    sql:    AnsiString;
  end;

  TOpRow = record
    opcode: AnsiString;
    p4:     AnsiString;
    p1, p2, p3, p5: i32;
  end;

  TOpList = array of TOpRow;

var
  gPass, gFail: i32;
  gCDb:   Pcsq_db;
  gPasDb: PTsqlite3;

{ -------------------------------------------------------------------------- }
{ EXPLAIN drivers.  Pull columns 1..6 = (opcode, p1, p2, p3, p4, p5).        }
{ -------------------------------------------------------------------------- }

function CExplain(zSql: PAnsiChar; out ops: TOpList): Boolean;
var
  zExp:  AnsiString;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rc, n: i32;
  txt:   PChar;
  row:   TOpRow;
begin
  ops := nil;
  zExp  := 'EXPLAIN ' + AnsiString(zSql);
  pStmt := nil; pTail := nil;
  rc := csq_prepare_v2(gCDb, PChar(zExp), -1, pStmt, pTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then csq_finalize(pStmt);
    Exit(False);
  end;

  n := 0;
  while csq_step(pStmt) = SQLITE_ROW do begin
    SetLength(ops, n + 1);
    txt := csq_column_text(pStmt, 1);
    if txt <> nil then row.opcode := AnsiString(txt) else row.opcode := '';
    row.p1 := csq_column_int(pStmt, 2);
    row.p2 := csq_column_int(pStmt, 3);
    row.p3 := csq_column_int(pStmt, 4);
    txt := csq_column_text(pStmt, 5);
    if txt <> nil then row.p4 := AnsiString(txt) else row.p4 := '';
    row.p5 := csq_column_int(pStmt, 6);
    ops[n] := row;
    Inc(n);
  end;
  csq_finalize(pStmt);
  Result := True;
end;

function PasExplain(zSql: PAnsiChar; out ops: TOpList): Boolean;
var
  zExp:  AnsiString;
  pStmt: Pointer;
  pTail: PAnsiChar;
  rc, n: i32;
  txt:   PAnsiChar;
  row:   TOpRow;
begin
  ops := nil;
  zExp  := 'EXPLAIN ' + AnsiString(zSql);
  pStmt := nil; pTail := nil;
  rc := sqlite3_prepare_v2(gPasDb, PAnsiChar(zExp), -1, @pStmt, @pTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit(False);
  end;

  n := 0;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    SetLength(ops, n + 1);
    txt := PAnsiChar(sqlite3_column_text(pStmt, 1));
    if txt <> nil then row.opcode := AnsiString(txt) else row.opcode := '';
    row.p1 := sqlite3_column_int(pStmt, 2);
    row.p2 := sqlite3_column_int(pStmt, 3);
    row.p3 := sqlite3_column_int(pStmt, 4);
    txt := PAnsiChar(sqlite3_column_text(pStmt, 5));
    if txt <> nil then row.p4 := AnsiString(txt) else row.p4 := '';
    row.p5 := sqlite3_column_int(pStmt, 6);
    ops[n] := row;
    Inc(n);
  end;
  sqlite3_finalize(pStmt);
  Result := True;
end;

{ -------------------------------------------------------------------------- }
{ Diff + report.                                                             }
{ -------------------------------------------------------------------------- }

function OpEq(const a, b: TOpRow): Boolean;
begin
  Result := (a.opcode = b.opcode) and (a.p1 = b.p1) and (a.p2 = b.p2)
            and (a.p3 = b.p3) and (a.p4 = b.p4) and (a.p5 = b.p5);
end;

procedure DumpOp(const side: AnsiString; addr: i32; const r: TOpRow);
begin
  WriteLn('       ', side, ' [', addr, '] ', r.opcode,
          ' p1=', r.p1, ' p2=', r.p2, ' p3=', r.p3,
          ' p4="', r.p4, '" p5=', r.p5);
end;

procedure CheckRow(const row: TCorpusRow);
var
  cOps, pOps: TOpList;
  i, firstDiff: i32;
begin
  cOps := nil; pOps := nil;
  if not CExplain(PAnsiChar(row.sql), cOps) then begin
    Inc(gFail);
    WriteLn('  FAIL ', row.label_, ' — C-side EXPLAIN prepare failed');
    WriteLn('       SQL: ', row.sql);
    WriteLn('       errmsg: ', AnsiString(csq_errmsg(gCDb)));
    Exit;
  end;

  if not PasExplain(PAnsiChar(row.sql), pOps) then begin
    Inc(gFail);
    WriteLn('  FAIL ', row.label_, ' — Pascal EXPLAIN prepare failed');
    WriteLn('       SQL: ', row.sql);
    Exit;
  end;

  if Length(cOps) <> Length(pOps) then begin
    Inc(gFail);
    WriteLn('  FAIL ', row.label_, ' — op count: C=', Length(cOps),
            ' Pas=', Length(pOps));
    Exit;
  end;

  firstDiff := -1;
  for i := 0 to Length(cOps) - 1 do
    if not OpEq(cOps[i], pOps[i]) then begin
      firstDiff := i; Break;
    end;

  if firstDiff < 0 then begin
    Inc(gPass);
    WriteLn('  PASS ', row.label_, '  (', Length(cOps), ' ops)');
  end else begin
    Inc(gFail);
    WriteLn('  FAIL ', row.label_, ' at op[', firstDiff, ']/', Length(cOps));
    DumpOp('C  ', firstDiff, cOps[firstDiff]);
    DumpOp('Pas', firstDiff, pOps[firstDiff]);
  end;
end;

{ -------------------------------------------------------------------------- }
{ Curated corpus.  Each row produces a byte-identical EXPLAIN listing on
  both sides today.  Divergent shapes are listed in EXCLUDED comments
  with the alignment-gap class they fall under.                              }
{ -------------------------------------------------------------------------- }

const
  N_CORPUS = 32;

var
  CORPUS: array[0..N_CORPUS - 1] of TCorpusRow;

procedure InitCorpus;
  procedure Add(i: i32; const lbl, sql: AnsiString);
  begin
    CORPUS[i].label_ := lbl;
    CORPUS[i].sql    := sql;
  end;
var i: i32;
begin
  i := 0;

  { DDL — CREATE TABLE / DROP / CREATE INDEX shapes that align today. }
  Add(i, 'CREATE TABLE simple',          'CREATE TABLE z1(a,b);');                        Inc(i);
  Add(i, 'CREATE TABLE typed',           'CREATE TABLE z2(a INTEGER PRIMARY KEY, b TEXT);'); Inc(i);
  Add(i, 'DROP TABLE IF EXISTS znope',   'DROP TABLE IF EXISTS znope;');                  Inc(i);
  Add(i, 'DROP INDEX IF EXISTS i_nope',  'DROP INDEX IF EXISTS i_nope;');                 Inc(i);

  { DML — INSERT / UPDATE / DELETE shapes that align today. }
  Add(i, 'INSERT VALUES',                'INSERT INTO t VALUES (1,2,3);');                Inc(i);
  Add(i, 'INSERT DEFAULT VALUES',        'INSERT INTO t DEFAULT VALUES;');                Inc(i);
  Add(i, 'UPDATE simple',                'UPDATE t SET a=1 WHERE b=2;');                  Inc(i);
  Add(i, 'DELETE WHERE',                 'DELETE FROM t WHERE a=1;');                     Inc(i);

  { Transactions / savepoints — codegen-trivial, no p4 strings. }
  Add(i, 'BEGIN',                        'BEGIN;');                                       Inc(i);
  Add(i, 'BEGIN IMMEDIATE',              'BEGIN IMMEDIATE;');                             Inc(i);
  Add(i, 'BEGIN EXCLUSIVE',              'BEGIN EXCLUSIVE;');                             Inc(i);
  Add(i, 'COMMIT',                       'COMMIT;');                                      Inc(i);
  Add(i, 'ROLLBACK',                     'ROLLBACK;');                                    Inc(i);
  Add(i, 'SAVEPOINT',                    'SAVEPOINT s1;');                                Inc(i);
  Add(i, 'RELEASE',                      'RELEASE s1;');                                  Inc(i);
  Add(i, 'ROLLBACK TO SAVEPOINT',        'ROLLBACK TO SAVEPOINT s1;');                    Inc(i);
  Add(i, 'BEGIN DEFERRED',               'BEGIN DEFERRED;');                              Inc(i);

  { 7.4b.1 — no-FROM SELECT.  OP_Explain p4 narrator now matches. }
  Add(i, 'SELECT 1',                     'SELECT 1;');                                    Inc(i);
  Add(i, 'SELECT NULL',                  'SELECT NULL;');                                 Inc(i);
  Add(i, 'SELECT 1+2',                   'SELECT 1+2;');                                  Inc(i);
  Add(i, 'SELECT 1,2,3',                 'SELECT 1,2,3;');                                Inc(i);
  Add(i, 'SELECT abs(-7)',               'SELECT abs(-7);');                              Inc(i);
  Add(i, 'SELECT str literal',           'SELECT ''hello'';');                            Inc(i);

  { 7.4b.2 — table-scan SELECT.  OP_OpenRead p4 nField now matches. }
  Add(i, 'SELECT a FROM t',              'SELECT a FROM t;');                             Inc(i);
  Add(i, 'SELECT a,b FROM t',            'SELECT a,b FROM t;');                           Inc(i);
  Add(i, 'SELECT * FROM t',              'SELECT * FROM t;');                             Inc(i);
  Add(i, 'SELECT a WHERE rowid=5',       'SELECT a FROM t WHERE rowid=5;');               Inc(i);

  { 7.4b.3 — sqlite_master row affinity (BBBDB) on schema-row INSERT. }
  Add(i, 'CREATE INDEX',                 'CREATE INDEX i1 ON t(a);');                     Inc(i);
  Add(i, 'CREATE INDEX 2col',            'CREATE INDEX i3 ON t(a,b);');                   Inc(i);

  { 7.4b.4 — CREATE UNIQUE INDEX SorterOpen KeyInfo nKeyField now matches.
    Pascal's sqlite3CreateIndex now clears uniqNotNull when the indexed
    column is not declared NOT NULL, mirroring build.c:4241..4243. }
  Add(i, 'CREATE UNIQUE INDEX',          'CREATE UNIQUE INDEX i2 ON t(b);');              Inc(i);

  { 7.4b.5 — composite PK on rowid table / WITHOUT ROWID schema-row. }
  Add(i, 'CREATE TABLE composite PK',    'CREATE TABLE z7(a,b, PRIMARY KEY(a,b));');      Inc(i);
  Add(i, 'CREATE TABLE WITHOUT ROWID',   'CREATE TABLE z8(a PRIMARY KEY, b) WITHOUT ROWID;'); Inc(i);

  { ----- EXCLUDED — known 7.4b follow-up codegen gaps -----
    These rows produce identical (op, p1, p2, p3, p5) but diverge on p4
    rendering; they are tracked as 7.4b sub-items in tasklist.md.

    * 'SELECT 1', 'SELECT NULL', 'SELECT 1+2', any literal SELECT —
      OP_Explain p4 string empty on Pascal vs "SCAN CONSTANT ROW" on C.
      Pascal codegen does not feed the explain narrator on SELECTs.
    * 'SELECT a FROM t', 'SELECT * FROM t', any table-scan SELECT —
      OP_OpenRead p4 (P4_INT32 nField) is full-column-count on Pascal
      (3) vs nField-actually-used (1) on C.
    * 'CREATE TABLE ... PRIMARY KEY(a,b)', 'CREATE TABLE ... WITHOUT
      ROWID' — implicit-index OP_MakeRecord p4 affinity still empty.
      Distinct from 7.4b.3 (sqlite_master schema-row affinity), which
      has been fixed.
    * INSERT-from-SELECT / multi-row VALUES, UPDATE ... FROM — pending
      the same OP_OpenRead nField alignment.
    --------------------------------------------------------- }

  if i <> N_CORPUS then begin
    WriteLn('FATAL: corpus row count mismatch: filled=', i, ' decl=', N_CORPUS);
    Halt(2);
  end;
end;

{ -------------------------------------------------------------------------- }

var
  i:        i32;
  cRc:      i32;
  pRc:      i32;
  pzErrMsg: PChar;
  pasErr:   PAnsiChar;

begin
  WriteLn('=== TestBytecodeParity — Phase 7.4b byte-for-byte VDBE parity gate ===');
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
  for i := 0 to N_CORPUS - 1 do CheckRow(CORPUS[i]);

  csq_close(gCDb);
  sqlite3_close(gPasDb);

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed (corpus = %d)',
    [gPass, gFail, N_CORPUS]));
  if gFail > 0 then Halt(1);
end.
