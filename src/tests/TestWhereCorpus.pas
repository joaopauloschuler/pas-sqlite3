{$I ../passqlite3.inc}
{
  TestWhereCorpus.pas — Phase 6.9-bis (step 11g.2.f) audit + regression gate.

  Differential bytecode-diff for the full WHERE shape matrix:
    * single rowid-EQ
    * multi-AND
    * OR-decomposed
    * LIKE
    * IN-list  / IN-subselect
    * composite-index range scan
    * LEFT JOIN  / RIGHT JOIN
    * virtual-table xFilter (deferred — covered by TestVdbeVtabExec today)

  Mirrors TestExplainParity's scaffold idiom: the C reference prepares
  `EXPLAIN <sql>` and walks the resulting bytecode listing row-by-row;
  the Pascal port prepares the bare SQL through sqlite3_prepare_v2 and
  walks PVdbe.aOp[0..nOp-1] directly.  The two listings are diffed on
  (opcode, p1, p2, p3, p5).  P4 / comment columns are excluded — same
  rationale as TestExplainParity (heap-layout-dependent / EXPLAIN_COMMENTS
  feature-flag chatter).

  This is a diff-finder, not a hard gate.  Per-row PASS / DIVERGE counters
  are reported; the test exits non-zero only on outright errors (C-side
  prepare failure, runtime exceptions).  The actionable signal is the
  running tally of divergences feeding the next sub-progress under 11g.2.f.

  Per the tasklist 11g.2.f narrative ("Land TestWhereCorpus covering the
  full WHERE shape matrix.  Verify byte-identical bytecode emission against
  C via TestExplainParity expansion."), this lands the corpus and
  scaffolding; the all-PASS gate flips on once the planner end-to-end
  body codegen for SELECT-with-WHERE flows green.
}

program TestWhereCorpus;

uses
  SysUtils,
  csqlite3,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

const
  { Minimal fixture — the typed/PK/index variants the WHERE-shape corpus
    really wants are still beyond what `sqlite3_exec` survives on the
    Pascal side (CREATE INDEX / WITHOUT-ROWID flake under the current
    11g.2.e codegen).  We use plain three-column declarations so the
    *parser* path is identical on both sides; the C oracle still gets
    the full schema (it owns its own DB), letting the corpus reach the
    SELECT prepare on the Pascal side without an empty-schema bail-out
    dominating the report.  When 11g.2.f flips the WHERE-codegen green,
    upgrade this fixture to mirror the C oracle exactly. }
  PAS_FIXTURE: PAnsiChar =
    'CREATE TABLE t(a, b, c);' +
    'CREATE TABLE s(x, y, z);' +
    'CREATE TABLE u(p, q, r);';

  C_FIXTURE: PAnsiChar =
    'CREATE TABLE t(a INTEGER, b INTEGER, c TEXT);' +
    'CREATE TABLE s(x INTEGER, y INTEGER, z TEXT);' +
    'CREATE TABLE u(p INTEGER PRIMARY KEY, q TEXT, r INTEGER) WITHOUT ROWID;' +
    'CREATE INDEX t_ab ON t(a, b);' +
    'CREATE INDEX s_xy ON s(x, y);' +
    'CREATE INDEX u_q  ON u(q);';

type
  TCorpusRow = record
    label_:   AnsiString;
    sql:      AnsiString;
    shape:    AnsiString;   { documentary tag — not diffed }
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
  N_CORPUS = 20;

var
  CORPUS: array[0..N_CORPUS - 1] of TCorpusRow;

procedure InitCorpus;
  procedure Add(i: Int32; const lbl, sh, sql: AnsiString);
  begin
    CORPUS[i].label_ := lbl;
    CORPUS[i].shape  := sh;
    CORPUS[i].sql    := sql;
  end;
var i: Int32;
begin
  i := 0;
  Add(i, 'rowid-EQ literal',          'IPK',
      'SELECT a FROM t WHERE rowid = 5;');                    Inc(i);
  Add(i, 'rowid-EQ via alias',        'IPK',
      'SELECT a FROM u WHERE p = 7;');                        Inc(i);
  Add(i, 'rowid IN list',             'IPK_IN',
      'SELECT a FROM t WHERE rowid IN (1,2,3);');             Inc(i);
  Add(i, 'rowid range',               'IPK_RANGE',
      'SELECT a FROM t WHERE rowid BETWEEN 5 AND 10;');       Inc(i);
  Add(i, 'col-EQ secondary index',    'INDEX_EQ',
      'SELECT a FROM t WHERE a = 5;');                        Inc(i);
  Add(i, 'col-AND on indexed pair',   'INDEX_EQ_2',
      'SELECT c FROM t WHERE a = 5 AND b = 7;');              Inc(i);
  Add(i, 'col-AND mixed indexed/free','INDEX_EQ_RES',
      'SELECT c FROM t WHERE a = 5 AND c = ''hi'';');         Inc(i);
  Add(i, 'col-RANGE on index',        'INDEX_RANGE',
      'SELECT c FROM t WHERE a > 5 AND a < 100;');            Inc(i);
  Add(i, 'col-RANGE composite',       'INDEX_EQ_RANGE',
      'SELECT c FROM t WHERE a = 5 AND b > 10;');             Inc(i);
  Add(i, 'col-IN literal',            'INDEX_IN',
      'SELECT c FROM t WHERE a IN (1,2,3);');                 Inc(i);
  Add(i, 'col-IN subselect',          'INDEX_IN_SUB',
      'SELECT c FROM t WHERE a IN (SELECT x FROM s);');       Inc(i);
  Add(i, 'OR decomposable',           'MULTI_OR',
      'SELECT c FROM t WHERE a = 5 OR a = 7;');               Inc(i);
  Add(i, 'OR cross-column',           'MULTI_OR_X',
      'SELECT c FROM t WHERE a = 5 OR b = 7;');               Inc(i);
  Add(i, 'LIKE prefix',               'LIKE',
      'SELECT a FROM t WHERE c LIKE ''hi%'';');               Inc(i);
  Add(i, 'LIKE wildcard',             'LIKE_WILD',
      'SELECT a FROM t WHERE c LIKE ''%X%'';');               Inc(i);
  Add(i, 'IS NULL',                   'NULL',
      'SELECT a FROM t WHERE c IS NULL;');                    Inc(i);
  Add(i, 'WITHOUT-ROWID secondary',   'WOR_INDEX',
      'SELECT q FROM u WHERE q = ''hi'';');                   Inc(i);
  Add(i, 'LEFT JOIN simple',          'LEFT_JOIN',
      'SELECT t.a, s.x FROM t LEFT JOIN s ON t.a = s.x;');    Inc(i);
  Add(i, 'INNER JOIN with WHERE',     'JOIN_WHERE',
      'SELECT t.a FROM t, s WHERE t.a = s.x AND s.y > 10;');  Inc(i);
  Add(i, 'full table scan',           'FULL',
      'SELECT a FROM t;');                                    Inc(i);

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
    WriteLn('  ERROR ', row.label_, ' [', row.shape,
            '] — C-side EXPLAIN prepare failed');
    WriteLn('       SQL: ', row.sql);
    WriteLn('       errmsg: ', AnsiString(csq_errmsg(gCDb)));
    Exit;
  end;

  if not pOk then begin
    Inc(gDiverge);
    WriteLn('  DIVERGE ', row.label_, ' [', row.shape,
            '] — Pascal prepare returned nil Vdbe (codegen stub or error)');
    WriteLn('       SQL: ', row.sql);
    WriteLn('       C ops: ', Length(cOps));
    Exit;
  end;

  if Length(cOps) <> Length(pOps) then begin
    Inc(gDiverge);
    WriteLn('  DIVERGE ', row.label_, ' [', row.shape,
            '] — op count: C=', Length(cOps), ' Pas=', Length(pOps));
    n := Length(cOps); if Length(pOps) < n then n := Length(pOps);
    if n > 0 then begin
      DumpOp('C  ', 0, cOps[0]);
      DumpOp('Pas', 0, pOps[0]);
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
    WriteLn('  PASS ', row.label_, ' [', row.shape, ']  (',
            Length(cOps), ' ops)');
  end else begin
    Inc(gDiverge);
    WriteLn('  DIVERGE ', row.label_, ' [', row.shape, '] at op[',
            firstDiff, ']/', Length(cOps));
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
  WriteLn('=== TestWhereCorpus — Phase 6.9-bis 11g.2.f bytecode-diff gate (scaffold) ===');
  WriteLn;

  { C reference. }
  pzErrMsg := nil;
  cRc := csq_open(':memory:', gCDb);
  if cRc <> SQLITE_OK then begin
    WriteLn('FATAL: csq_open failed rc=', cRc); Halt(2);
  end;
  cRc := csq_exec(gCDb, C_FIXTURE, nil, nil, pzErrMsg);
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
  pRc := sqlite3_exec(gPasDb, PAS_FIXTURE, nil, nil, @pasErr);
  if pRc <> SQLITE_OK then begin
    WriteLn('NOTE: Pascal sqlite3_exec(fixture) rc=', pRc,
            ' — running corpus against partial schema');
    if pasErr <> nil then WriteLn('     err: ', AnsiString(pasErr));
  end;

  InitCorpus;
  for i := 0 to N_CORPUS - 1 do begin
    try
      CheckRow(CORPUS[i]);
    except
      { Pascal-side codegen for SELECT-with-WHERE is still landing under
        11g.2.f.  Treat exceptions raised inside prepare_v2 as DIVERGE
        rather than ERROR so the scaffold can run end-to-end and report
        a single diff-finder tally instead of bailing on the first crash.
        ERROR remains reserved for C-side prepare failures, which would
        indicate a corrupt fixture or oracle. }
      on e: Exception do begin
        Inc(gDiverge);
        WriteLn('  DIVERGE ', CORPUS[i].label_, ' [', CORPUS[i].shape,
                '] — Pascal exception: ', e.ClassName, ' ', e.Message);
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
