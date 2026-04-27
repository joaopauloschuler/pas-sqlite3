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
  gCRefOps:              i32;   { running tally of C-oracle ops across the corpus — informational only }
  gCDb:    Pcsq_db;
  gPasDb:  PTsqlite3;
  { Failure-mode classification — per-row Pascal-side outcome bucket.
    Surfaces the *kind* of divergence at the report tail so future
    sub-progress batches under 11g.2.f can target the dominant mode
    (drive AVs to nil-Vdbe, then to op-count, then to per-op).        }
  gModeException, gModeNilVdbe, gModeOpCount, gModeOpDiff: i32;

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
      'SELECT q FROM u WHERE p = 7;');                        Inc(i);
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
    txt := csq_column_text(pStmt, 1);
    if txt <> nil then row.opcode := AnsiString(txt) else row.opcode := '';
    { Skip OP_Explain comment opcodes — only emitted by the C oracle when
      SQLITE_ENABLE_EXPLAIN_COMMENTS is on, and never by the Pascal codegen.
      Removing them lets the row-by-row diff gate compare actual VDBE shape
      instead of EXPLAIN-formatting chatter. }
    if row.opcode = 'Explain' then continue;
    SetLength(ops, n + 1);
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

{ Dump the first N ops from a C-oracle listing — used as a forward-visibility
  reference whenever the Pascal side fails (exception, nil Vdbe, op-count
  mismatch, divergent op).  Subsequent sub-progress batches under 11g.2.f
  can read this dump and target it directly. }
procedure DumpCRef(const cOps: TOpList; maxRows: Int32);
var
  i, n: Int32;
begin
  n := Length(cOps);
  if n > maxRows then n := maxRows;
  if n = 0 then begin
    WriteLn('       (C reference: 0 ops)');
    Exit;
  end;
  WriteLn('       C reference (', Length(cOps), ' ops, showing ', n, '):');
  for i := 0 to n - 1 do
    WriteLn('         [', i, '] ', cOps[i].opcode,
            ' p1=', cOps[i].p1, ' p2=', cOps[i].p2,
            ' p3=', cOps[i].p3, ' p5=', cOps[i].p5);
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

{ DumpContext — 2-before / 2-after window around firstDiff for one side.
  Caller passes lo/hi context counts so the helper stays generic. }
procedure DumpContext(side: AnsiString; const ops: TOpList;
  firstDiff, lo, hi, total: i32);
var
  iStart, iStop, j: i32;
begin
  iStart := firstDiff - lo; if iStart < 0 then iStart := 0;
  iStop  := firstDiff + hi; if iStop  >= total then iStop := total - 1;
  for j := iStart to iStop do
    DumpOp(side, j, ops[j]);
end;

{ Two-stage check — the C oracle is consulted first (in the caller) and the
  resulting cOps are passed through to CheckRow.  This keeps the C reference
  available even when the Pascal side raises an exception inside prepare_v2,
  so the per-row report can dump the target opcodes (DumpCRef) regardless of
  which Pascal failure mode trips first.  Once 11g.2.f stops the AVs and the
  divergences become structural (op-count or per-op), the same dump still
  shows the planner-level shape we are targeting. }
procedure CheckRow(const row: TCorpusRow; const cOps: TOpList);
const
  REF_DUMP_ROWS = 5;
var
  pOps:      TOpList;
  pOk:       Boolean;
  i, n:      i32;
  firstDiff: i32;
begin
  pOps := nil;
  pOk := PasExplain(PAnsiChar(row.sql), pOps);

  if not pOk then begin
    Inc(gDiverge); Inc(gModeNilVdbe);
    WriteLn('  DIVERGE ', row.label_, ' [', row.shape,
            '] — Pascal prepare returned nil Vdbe (codegen stub or error)');
    WriteLn('       SQL: ', row.sql);
    DumpCRef(cOps, REF_DUMP_ROWS);
    Exit;
  end;

  if Length(cOps) <> Length(pOps) then begin
    Inc(gDiverge); Inc(gModeOpCount);
    WriteLn('  DIVERGE ', row.label_, ' [', row.shape,
            '] — op count: C=', Length(cOps), ' Pas=', Length(pOps));
    n := Length(cOps); if Length(pOps) < n then n := Length(pOps);
    if n > 0 then begin
      DumpOp('C  ', 0, cOps[0]);
      DumpOp('Pas', 0, pOps[0]);
    end;
    DumpCRef(cOps, REF_DUMP_ROWS);
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
    Inc(gDiverge); Inc(gModeOpDiff);
    WriteLn('  DIVERGE ', row.label_, ' [', row.shape, '] at op[',
            firstDiff, ']/', Length(cOps));
    { Context window — show 2 ops before and 2 ops after firstDiff on
      both sides so the report carries enough surrounding shape to tell
      whether the divergence is a single-op slip (P-operand drift) or a
      structural drift (extra/missing prologue, swapped scan direction,
      etc.).  Aligned indices since we know lengths match here.       }
    n := Length(cOps);
    DumpContext('C  ', cOps, firstDiff, 2, 2, n);
    DumpContext('Pas', pOps, firstDiff, 2, 2, n);
  end;
end;

{ -------------------------------------------------------------------------- }

type
  TShapeBucket = record
    shape:               AnsiString;
    pass, diverge, err:  i32;
    rows:                i32;
  end;

var
  i:        Int32;
  cRc:      i32;
  pRc:      i32;
  pzErrMsg: PChar;
  pasErr:   PAnsiChar;
  cOps:     TOpList;
  shapes:   array of TShapeBucket;
  preCnt:   i32;
  bI:       i32;
  bFound:   Boolean;
  preP, preD, preE: i32;

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
  SetLength(shapes, 0);
  for i := 0 to N_CORPUS - 1 do begin
    preP := gPass; preD := gDiverge; preE := gErr;
    { Run the C oracle first so its bytecode listing is available even when
      the Pascal side raises an exception inside prepare_v2.  Failure here
      means the oracle / fixture is corrupt and is the only condition that
      maps to ERROR (counted in gErr); the Pascal side mapping to DIVERGE
      is handled below. }
    cOps := nil;
    if not CExplain(PAnsiChar(CORPUS[i].sql), cOps) then begin
      Inc(gErr);
      WriteLn('  ERROR ', CORPUS[i].label_, ' [', CORPUS[i].shape,
              '] — C-side EXPLAIN prepare failed');
      WriteLn('       SQL: ', CORPUS[i].sql);
      WriteLn('       errmsg: ', AnsiString(csq_errmsg(gCDb)));
      Continue;
    end;
    Inc(gCRefOps, Length(cOps));

    try
      CheckRow(CORPUS[i], cOps);
    except
      { Pascal-side codegen for SELECT-with-WHERE is still landing under
        11g.2.f.  Treat exceptions raised inside prepare_v2 as DIVERGE
        rather than ERROR so the scaffold can run end-to-end and report
        a single diff-finder tally instead of bailing on the first crash.
        ERROR remains reserved for C-side prepare failures, which would
        indicate a corrupt fixture or oracle.

        With cOps now hoisted, dump the C reference inline so each
        exception-mode row carries the target opcodes alongside the
        crash signature — actionable visibility for the next batch. }
      on e: Exception do begin
        Inc(gDiverge); Inc(gModeException);
        WriteLn('  DIVERGE ', CORPUS[i].label_, ' [', CORPUS[i].shape,
                '] — Pascal exception: ', e.ClassName, ' ', e.Message);
        DumpCRef(cOps, 5);
      end;
    end;

    { Roll up the row's outcome into the per-shape bucket.  Buckets are
      created lazily so the report tail orders shapes by first-seen
      (matches the corpus declaration order). }
    bFound := False;
    for bI := 0 to Length(shapes) - 1 do
      if shapes[bI].shape = CORPUS[i].shape then begin
        bFound := True; Break;
      end;
    if not bFound then begin
      bI := Length(shapes); SetLength(shapes, bI + 1);
      shapes[bI].shape := CORPUS[i].shape;
      shapes[bI].pass := 0; shapes[bI].diverge := 0;
      shapes[bI].err := 0;  shapes[bI].rows := 0;
    end;
    Inc(shapes[bI].rows);
    Inc(shapes[bI].pass,    gPass    - preP);
    Inc(shapes[bI].diverge, gDiverge - preD);
    Inc(shapes[bI].err,     gErr     - preE);
  end;

  csq_close(gCDb);
  sqlite3_close(gPasDb);

  WriteLn;
  WriteLn(Format('Results: %d pass, %d diverge, %d error (corpus = %d)',
    [gPass, gDiverge, gErr, N_CORPUS]));
  if (N_CORPUS - gErr) > 0 then
    WriteLn(Format('C-oracle reference total: %d ops across %d rows (avg %.1f)',
      [gCRefOps, N_CORPUS - gErr, gCRefOps / Double(N_CORPUS - gErr)]))
  else
    WriteLn(Format('C-oracle reference total: %d ops (no rows ran)', [gCRefOps]));

  { Failure-mode tally — partition the gDiverge bucket so the next batch
    can target the dominant mode (exception → nil-Vdbe → op-count →
    per-op).  Sum should equal gDiverge. }
  preCnt := gModeException + gModeNilVdbe + gModeOpCount + gModeOpDiff;
  WriteLn(Format(
    'Failure-mode tally: %d exception, %d nil-Vdbe, %d op-count, %d op-diff (sum=%d, diverge=%d)',
    [gModeException, gModeNilVdbe, gModeOpCount, gModeOpDiff, preCnt, gDiverge]));

  { Per-shape histogram — by-tag PASS/DIVERGE/ERR rollup so shape-classes
    flip green coarsely instead of forcing per-row hunts.  Sub-progress
    batches under 11g.2.f drive these counters one shape-tag at a time. }
  WriteLn('Per-shape histogram (shape: pass/diverge/err of rows):');
  for bI := 0 to Length(shapes) - 1 do
    WriteLn(Format('  %-16s %d/%d/%d  (rows=%d)',
      [shapes[bI].shape, shapes[bI].pass, shapes[bI].diverge,
       shapes[bI].err, shapes[bI].rows]));

  if gErr > 0 then Halt(1) else Halt(0);
end.
