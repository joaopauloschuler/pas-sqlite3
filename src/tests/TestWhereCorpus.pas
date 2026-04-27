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
  { Aligned fixture (sub-progress 13) — both sides use the same bare
    three-column declarations.  Earlier sub-progresses ran the C oracle
    against a typed/INTEGER PRIMARY KEY/WITHOUT ROWID/CREATE INDEX schema
    so the planner could pick "realistic" plans (covering-index scan,
    PK seek, etc.), but the Pascal port has none of the index machinery
    yet (CREATE INDEX still flakes through sqlite3_exec under the
    current 11g.2.e codegen, AddPrimaryKey is a stub, no covering-index
    detection in the planner).  The result was wholesale fixture-driven
    divergence — every IPK/INDEX_* row's OpenRead p1 (cursor-1 vs
    cursor-0), p2 (rootpage 5+ vs 2-4), and Transaction.p3 (cookie 6
    vs 3) drifted from typed-vs-bare schema, masking actual codegen
    parity.  Both sides now use identical bare CREATE TABLE shapes;
    rows that genuinely require index-based plans (INDEX_*) will keep
    op-count differences against the C SCAN-with-residual baseline,
    but the IPK / FULL / NULL / IS NULL / etc. rows that are within
    Pascal's current codegen reach can flip to PASS.  When CREATE INDEX
    + AddPrimaryKey + covering-index detection land in a future
    sub-progress, the fixture can be upgraded back to typed/indexed and
    the realistic-planner aspirations resume. }
  PAS_FIXTURE: PAnsiChar =
    'CREATE TABLE t(a, b, c);' +
    'CREATE TABLE s(x, y, z);' +
    'CREATE TABLE u(p, q, r);';

  C_FIXTURE: PAnsiChar =
    'CREATE TABLE t(a, b, c);' +
    'CREATE TABLE s(x, y, z);' +
    'CREATE TABLE u(p, q, r);';

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
  N_CORPUS = 60;

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

  { Phase 6.9-bis 11g.2.f sub-progress 25 — single-table shape extension.
    Five new shapes that exercise edge-cases of the EXISTING (single-table)
    planner machinery: IS NOT NULL, != literal, NOT IN literal-list,
    composite BETWEEN on a non-rowid column, and OR mixed with AND.
    These all degrade to SCAN-with-residual on the un-indexed fixture,
    so the Pascal port should produce the same byte-shape as C if the
    residual-codegen for each operator is wired through. }
  Add(i, 'IS NOT NULL',               'NOTNULL',
      'SELECT a FROM t WHERE c IS NOT NULL;');                Inc(i);
  Add(i, 'col-NE literal',            'NEQ',
      'SELECT a FROM t WHERE a <> 5;');                       Inc(i);
  Add(i, 'rowid NOT IN literal',      'IPK_NOT_IN',
      'SELECT a FROM t WHERE rowid NOT IN (1,2,3);');         Inc(i);
  Add(i, 'col BETWEEN literal',       'COL_BETWEEN',
      'SELECT a FROM t WHERE b BETWEEN 5 AND 10;');           Inc(i);
  Add(i, 'AND-of-OR mixed',           'AND_OR',
      'SELECT a FROM t WHERE (a = 5 OR a = 7) AND b > 0;');   Inc(i);

  { Phase 6.9-bis 11g.2.f sub-progress 27 — single-table corpus extension #2.
    Eight new shapes that exercise codegen paths the prior 25 rows did not
    cover: parameter binding (TK_VARIABLE) on the IPK, column, and LIKE
    operands; negated EQ via TK_NOT; column-vs-column comparison (no
    constant on either side); a string-IN literal list (different operand
    affinity from numeric IN); RHS arithmetic expression on the IPK
    constant; LHS unary-minus on the column; and the constant-true WHERE
    predicate (`WHERE 1`, planner-folded to no-op). }
  Add(i, 'IPK param bind',            'IPK_PARAM',
      'SELECT a FROM t WHERE rowid = ?;');                    Inc(i);
  Add(i, 'col param bind',            'COL_PARAM',
      'SELECT a FROM t WHERE a = ?;');                        Inc(i);
  Add(i, 'LIKE param bind',           'LIKE_PARAM',
      'SELECT a FROM t WHERE c LIKE ?;');                     Inc(i);
  Add(i, 'NOT (a = 5)',               'NOT_EQ',
      'SELECT a FROM t WHERE NOT (a = 5);');                  Inc(i);
  Add(i, 'col-vs-col',                'COL_COL',
      'SELECT a FROM t WHERE a = b;');                        Inc(i);
  Add(i, 'string-IN literal',         'INDEX_IN_STR',
      'SELECT a FROM t WHERE c IN (''x'',''y'',''z'');');     Inc(i);
  Add(i, 'IPK RHS arith',             'IPK_RHS_EXPR',
      'SELECT a FROM t WHERE rowid = 5+1;');                  Inc(i);
  Add(i, 'WHERE constant true',       'CONST_TRUE',
      'SELECT a FROM t WHERE 1;');                            Inc(i);

  { Phase 6.9-bis 11g.2.f sub-progress 27 — extended single-table corpus
    (group #2).  Eight further shapes that exercise built-in scalar
    functions, parameterised IN-list, string-BETWEEN, parenthesised
    grouping, NOT IS NULL, OR-of-AND, duplicate predicates, and a
    nested OR. }
  Add(i, 'string BETWEEN',            'COL_BETWEEN_STR',
      'SELECT a FROM t WHERE c BETWEEN ''a'' AND ''z'';');    Inc(i);
  Add(i, 'NOT IS NULL',               'NOT_NULL_PAREN',
      'SELECT a FROM t WHERE NOT (c IS NULL);');              Inc(i);
  Add(i, 'OR-of-AND',                 'OR_OF_AND',
      'SELECT a FROM t WHERE (a=1 AND b=2) OR (a=3 AND b=4);'); Inc(i);
  Add(i, 'param IN-list',             'INDEX_IN_PARAM',
      'SELECT a FROM t WHERE a IN (?, ?, ?);');               Inc(i);
  Add(i, 'parenthesised IPK-EQ',      'IPK_PAREN',
      'SELECT a FROM t WHERE (rowid = 5);');                  Inc(i);
  Add(i, 'duplicate AND',             'DUP_AND',
      'SELECT a FROM t WHERE a = 5 AND a = 5;');              Inc(i);
  Add(i, 'abs() in WHERE',            'FUNC_ABS',
      'SELECT a FROM t WHERE abs(a) = 5;');                   Inc(i);
  Add(i, 'length() in WHERE',         'FUNC_LENGTH',
      'SELECT a FROM t WHERE length(c) > 0;');                Inc(i);

  { Phase 6.9-bis 11g.2.f sub-progress 28 — single-table corpus extension #4.
    Ten further shapes that exercise additional codegen paths:
    open-ended range comparisons (>=, <=), the IS / IS NOT operators
    against a literal (TK_IS / TK_ISNOT), the GLOB pattern match,
    NOT BETWEEN, scalar coalesce() / lower() / cast(), triple-AND and
    triple-OR chains, and an LHS arithmetic expression. }
  Add(i, 'col-GE literal',            'COL_GE',
      'SELECT a FROM t WHERE a >= 5;');                       Inc(i);
  Add(i, 'col-LE literal',            'COL_LE',
      'SELECT a FROM t WHERE a <= 5;');                       Inc(i);
  Add(i, 'col IS literal',            'IS_LIT',
      'SELECT a FROM t WHERE a IS 5;');                       Inc(i);
  Add(i, 'col IS NOT literal',        'ISNOT_LIT',
      'SELECT a FROM t WHERE a IS NOT 5;');                   Inc(i);
  Add(i, 'GLOB prefix',               'GLOB',
      'SELECT a FROM t WHERE c GLOB ''X*'';');                Inc(i);
  Add(i, 'NOT BETWEEN literal',       'NOT_BETWEEN',
      'SELECT a FROM t WHERE b NOT BETWEEN 1 AND 10;');       Inc(i);
  Add(i, 'coalesce() in WHERE',       'COALESCE',
      'SELECT a FROM t WHERE coalesce(a, 0) > 0;');           Inc(i);
  Add(i, 'triple OR',                 'TRIPLE_OR',
      'SELECT a FROM t WHERE a = 5 OR a = 7 OR a = 9;');      Inc(i);
  Add(i, 'triple AND',                'TRIPLE_AND',
      'SELECT a FROM t WHERE a = 5 AND b = 7 AND c = ''x'';'); Inc(i);
  Add(i, 'LHS arith',                 'LHS_ARITH',
      'SELECT a FROM t WHERE a + 1 = 5;');                    Inc(i);

  { Phase 6.9-bis 11g.2.f sub-progress 29 — iif() inline codegen.
    Three shapes that exercise the INLINEFUNC_iif expansion: a simple
    iif(cond,1,0) filter, iif with a column-comparison condition, and
    iif with a NULL ELSE branch (2-arg form is not registered inline
    so we use the explicit 3-arg form with an explicit NULL).  All
    degrade to SCAN-with-residual on the un-indexed fixture. }
  Add(i, 'iif(a>5,1,0)=1',           'IIF_GT',
      'SELECT a FROM t WHERE iif(a > 5, 1, 0) = 1;');         Inc(i);
  Add(i, 'iif col-eq branch',        'IIF_COL_EQ',
      'SELECT a FROM t WHERE iif(a = b, a, b) > 3;');          Inc(i);
  Add(i, 'iif null else',            'IIF_NULL_ELSE',
      'SELECT a FROM t WHERE iif(a > 0, a, NULL) IS NOT NULL;'); Inc(i);

  { Phase 6.9-bis 11g.2.f sub-progress 30 — unlikely()/likely() no-op
    fast-path and nullif() runtime path.
    unlikely(expr) and likely(expr) fold to a bare codegen of their first
    argument (INLINEFUNC_unlikely default arm); the probability hint is
    consumed by the planner and no OP_Function is emitted.
    nullif(a,0) IS NOT NULL exercises the OP_Function runtime path for
    nullifFunc; there is no INLINEFUNC_nullif in upstream C — nullif is
    intentionally left as a runtime call (FUNCTION macro, not INLINE_FUNC). }
  Add(i, 'unlikely(a>5)',           'UNLIKELY',
      'SELECT a FROM t WHERE unlikely(a > 5);');                 Inc(i);
  Add(i, 'likely(a=5)',             'LIKELY',
      'SELECT a FROM t WHERE likely(a = 5);');                   Inc(i);
  Add(i, 'nullif(a,0) IS NOT NULL', 'NULLIF',
      'SELECT a FROM t WHERE nullif(a, 0) IS NOT NULL;');        Inc(i);

  { Phase 6.9-bis 11g.2.f sub-progress 32 — CAST(... AS ...) codegen.
    Three shapes that exercise the TK_CAST arm in sqlite3ExprCodeTarget:
    CAST to INTEGER (OP_Cast with SQLITE_AFF_INTEGER), CAST to TEXT
    (SQLITE_AFF_TEXT), and CAST to REAL (SQLITE_AFF_REAL) with a range
    filter.  All degrade to SCAN-with-residual on the un-indexed fixture.
    The TK_CAST arm was already ported (passqlite3codegen.pas:4693); these
    rows confirm byte-identical EXPLAIN VDBE output against the C oracle. }
  Add(i, 'cast(a AS INTEGER)=5',   'CAST_INT',
      'SELECT a FROM t WHERE cast(a AS INTEGER) = 5;');          Inc(i);
  Add(i, 'cast(a AS TEXT)=''5''', 'CAST_TEXT',
      'SELECT a FROM t WHERE cast(a AS TEXT) = ''5'';');         Inc(i);
  Add(i, 'cast(a AS REAL)>3.0',   'CAST_REAL',
      'SELECT a FROM t WHERE cast(a AS REAL) > 3.0;');           Inc(i);

  if i <> N_CORPUS then begin
    WriteLn('FATAL: corpus row count mismatch: filled=', i, ' decl=', N_CORPUS);
    Halt(2);
  end;
end;

{ -------------------------------------------------------------------------- }
{ C side — drive `EXPLAIN <sql>` and collect rows.                           }
{ -------------------------------------------------------------------------- }

{ Build-flag chatter opcodes filtered out of the C oracle EXPLAIN listing
  before the diff against the Pascal port.  Each entry is a name the upstream
  EXPLAIN_COMMENTS / SQLITE_DEBUG / SHARED_CACHE feature flags can produce
  but the Pascal codegen never emits in any code path: filtering keeps the
  diff focused on actual VDBE shape rather than build-flag noise.

    'Explain'    — SQLITE_ENABLE_EXPLAIN_COMMENTS structured-narrative tag
    'ReleaseReg' — SQLITE_DEBUG register-pressure debug hint
    'TableLock'  — SQLITE_OMIT_SHARED_CACHE=off shared-cache table-lock op

  Filtering is index-aware: every retained op's p2 (the universal jump
  target field) is decremented by the number of filtered ops at strictly
  lower original addresses, so post-filter `Init.p2 = 7` actually points
  at the post-filter `Transaction` instead of the now-shifted-out
  `Goto`.  Without this fix-up every row diverged at op[0] with a
  bogus single-op p2 mismatch even when the underlying shape was
  identical, masking real structural divergences further down the
  listing. }
function isFilteredOpcode(const op: AnsiString): Boolean; inline;
begin
  Result := (op = 'Explain') or (op = 'ReleaseReg') or (op = 'TableLock');
end;

{ Opcodes whose p2 field encodes a jump target into the program addr space.
  Renumbering p2 after filtering is correct only for these — for ops like
  `Integer p1=N p2=R` the p2 is a destination register, not an address, and
  the fix-up must leave it alone or it will silently corrupt register-pool
  semantics (latent bug seen in sub-progress 14 follow-up: ReleaseReg
  filtering decremented the per-row factored-constant target register from
  3 to 2, masquerading as a real codegen divergence).

  This list covers every jump opcode the WHERE / SELECT codegen exercise
  hits in the corpus.  Outside-corpus jump opcodes (e.g. AggStep for
  GROUP BY, IdxRowid for covering-index walks) can be added when the
  corpus expands; until then they trivially fall through to "no
  renumber" which is the only-safe default. }
function isJumpOpcode(const op: AnsiString): Boolean; inline;
begin
  Result :=
    (op = 'Init') or (op = 'Goto') or
    (op = 'Rewind') or (op = 'Next') or (op = 'Prev') or
    (op = 'Eq') or (op = 'Ne') or
    (op = 'Lt') or (op = 'Le') or (op = 'Gt') or (op = 'Ge') or
    (op = 'If') or (op = 'IfNot') or (op = 'IfNullRow') or
    (op = 'IsNull') or (op = 'NotNull') or
    (op = 'IfPos') or (op = 'IfNeg') or (op = 'IfNotZero') or
    (op = 'IfSmaller') or (op = 'IfNullRow') or (op = 'IfNoHope') or
    (op = 'Found') or (op = 'NotFound') or
    (op = 'NotExists') or (op = 'SeekRowid') or
    (op = 'SeekGE') or (op = 'SeekGT') or
    (op = 'SeekLE') or (op = 'SeekLT') or
    (op = 'IdxGE') or (op = 'IdxGT') or
    (op = 'IdxLE') or (op = 'IdxLT') or
    (op = 'Once') or (op = 'Yield') or
    (op = 'BeginSubrtn') or (op = 'Return') or
    (op = 'NoConflict') or (op = 'NotInList') or
    (op = 'MustBeInt') or (op = 'IdxNoSeek') or
    (op = 'VFilter') or (op = 'VNext') or
    (op = 'Last') or (op = 'SorterNext') or (op = 'SorterSort') or
    (op = 'RowSetTest') or (op = 'RowSetRead') or
    (op = 'Program') or (op = 'FkIfZero') or
    (op = 'DecrJumpZero') or (op = 'OffsetLimit') or
    (op = 'AggStep') or (op = 'AggFinal') or
    (op = 'Filter') or (op = 'NotInList') or
    (op = 'ElseEq') or (op = 'ElseNotEq') or
    (op = 'IsType') or (op = 'TypeCheck') or
    (op = 'Gosub') or (op = 'InitCoroutine');
end;

function CExplain(zSql: PAnsiChar; out ops: TOpList): Boolean;
var
  zExp:   AnsiString;
  pStmt:  Pcsq_stmt;
  pzTail: PChar;
  rc:     i32;
  n:      i32;
  txt:    PChar;
  row:    TOpRow;
  rawOps: array of TOpRow;
  rawN:   i32;
  filtAt: array of Boolean;
  shift:  array of i32;
  delta:  i32;
  i:      i32;
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

  { First pass — collect all ops verbatim, marking which are filtered. }
  rawN := 0;
  while csq_step(pStmt) = SQLITE_ROW do begin
    SetLength(rawOps, rawN + 1);
    SetLength(filtAt,  rawN + 1);
    txt := csq_column_text(pStmt, 1);
    if txt <> nil then rawOps[rawN].opcode := AnsiString(txt)
    else               rawOps[rawN].opcode := '';
    rawOps[rawN].p1 := csq_column_int(pStmt, 2);
    rawOps[rawN].p2 := csq_column_int(pStmt, 3);
    rawOps[rawN].p3 := csq_column_int(pStmt, 4);
    rawOps[rawN].p5 := csq_column_int(pStmt, 6);
    filtAt[rawN] := isFilteredOpcode(rawOps[rawN].opcode);
    Inc(rawN);
  end;

  { Build a prefix-sum table: shift[i] = number of filtered ops at
    addresses < i.  Subtracting shift[op.p2] from each retained op's p2
    renumbers jump targets so they reference the post-filter index space. }
  SetLength(shift, rawN + 1);
  delta := 0;
  for i := 0 to rawN - 1 do begin
    shift[i] := delta;
    if filtAt[i] then Inc(delta);
  end;
  shift[rawN] := delta;

  { Second pass — emit retained ops with renumbered p2. }
  n := 0;
  for i := 0 to rawN - 1 do begin
    if filtAt[i] then continue;
    row := rawOps[i];
    if isJumpOpcode(row.opcode) and (row.p2 >= 0) and (row.p2 <= rawN) then
      row.p2 := row.p2 - shift[row.p2];
    SetLength(ops, n + 1);
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

{ Sub-progress 14 — dump both sides side-by-side on op-count mismatch so
  the per-row diff narrative tells us *which* op is missing on the Pascal
  side, not just that the totals differ.  Print up to maxN rows from each
  list; pad the shorter side with a placeholder so the column alignment
  survives even when one side runs out early. }
procedure DumpBothSides(const cOps, pOps: TOpList; maxN: Int32);
var
  i, nC, nP, nMax: Int32;
  cs, ps: AnsiString;
begin
  nC := Length(cOps); nP := Length(pOps);
  nMax := nC; if nP > nMax then nMax := nP;
  if nMax > maxN then nMax := maxN;
  WriteLn('       Side-by-side (C=', nC, ' Pas=', nP, ', showing ', nMax, '):');
  for i := 0 to nMax - 1 do begin
    if i < nC then
      cs := Format('%s p1=%d p2=%d p3=%d p5=%d',
        [cOps[i].opcode, cOps[i].p1, cOps[i].p2, cOps[i].p3, cOps[i].p5])
    else cs := '(none)';
    if i < nP then
      ps := Format('%s p1=%d p2=%d p3=%d p5=%d',
        [pOps[i].opcode, pOps[i].p1, pOps[i].p2, pOps[i].p3, pOps[i].p5])
    else ps := '(none)';
    WriteLn(Format('         [%2d] C=%-40s | Pas=%s', [i, cs, ps]));
  end;
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
    DumpBothSides(cOps, pOps, 16);
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
    { When the divergence is at op[0] (Init.p2 typically), the 2-before /
      2-after window collapses to the prologue head and elides the tail
      where the actual structural difference often lives (Goto position).
      Dump the full side-by-side too — same idiom as the op-count arm
      above so structural diffs at the head are visible end-to-end. }
    if firstDiff = 0 then
      DumpBothSides(cOps, pOps, 16);
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
