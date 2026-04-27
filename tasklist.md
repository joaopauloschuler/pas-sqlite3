# pas-sqlite3 — Remaining Task List

Port of **SQLite 3** (D. Richard Hipp et al., public domain) from C to Free Pascal.
Source of truth: `../sqlite3/` (the original C reference — the upstream split
source tree under `../sqlite3/src/*.c`). The amalgamation is **not used** by
this project, neither as a porting reference nor as an oracle build input.
Inspiration for structure, tone, and workflow: `../pas-core-math/`, `../pas-bzip2/`.

Goal: **behavioural and on-disk parity with the C reference.** The Pascal build
must (a) produce byte-identical `.db` files for the same SQL input, (b) return
identical query results, and (c) emit the same VDBE bytecode for the same SQL.
Any deviation is a bug in the port, never an improvement.

Important: At the end of this document, please find:
* Architectural notes and known pitfalls
* Per-function porting checklist
* Key rules for the developer

---

## Phase 6 — Code generators (close the EXPLAIN gate)

- [ ] **6.9-bis 11g.2.b** Vertical slice — minimal-viable
    `sqlite3WhereBegin` / `sqlite3WhereEnd` for the single-table,
    single-rowid-EQ-predicate case.  Bookkeeping primitives, prologue,
    cleanup contract, and several leaf helpers (codeCompare cluster,
    sqlite3ExprCanBeNull, sqlite3ExprCodeTemp + 6 unary arms,
    TK_COLLATE/TK_SPAN/TK_UPLUS arms, whereShortCut, allowedOp +
    operatorMask + exprMightBeIndexed + minimal-viable exprAnalyze)
    are already landed.
    - [X] Trimmed planner pick + per-loop emission for the rowid-EQ
      shape — `whereShortCut` wired into `sqlite3WhereBegin` after
      the WHERE_WANT_DISTINCT block; level-0 cursor open via
      `sqlite3OpenTable(OP_OpenRead)` + Case-2 body via
      `sqlite3ExprCodeTarget` + `OP_SeekRowid` to addrBrk.
    - [X] Loop-tail half of `sqlite3WhereEnd` — per-level
      ResolveLabel(addrCont) + iteration-opcode emission +
      ResolveLabel(addrBrk), final ResolveLabel(iBreak), nQueryLoop
      restore, then `whereInfoFree`.  Deferred arms (RIGHT JOIN,
      SKIPAHEAD_DISTINCT, IN-loop unwind, LEFT JOIN null-row,
      addrSkip, index→table column rewrite) gated to 11g.2.e.
    - [X] `TestWhereSimple.pas` gate — hand-built SrcList +
      rowid-EQ Expr; asserts `whereShortCut` populates
      WHERE_IPK | WHERE_ONEROW, OP_OpenRead + OP_SeekRowid emit at
      expected cursors / labels, `pLevel^.op = OP_Noop`, term
      flagged TERM_CODED, and `pParse.nQueryLoop` is restored
      across `WhereBegin`/`WhereEnd`.
    - [ ] Re-enable productive tails — `sqlite3Update` skeleton-only
      and `sqlite3DeleteFrom` vtab `OP_VUpdate` arm still open (tracked
      under 11g.2.f "Open follow-on").  `sqlite3GenerateRowDelete`,
      `sqlite3GenerateConstraintChecks` are landed; productive truncate
      arm + where-loop arm of DeleteFrom landed in 11g.2.f sub-progress
      48–49.  `sqlite3CompleteInsertion` still a stub but only used by
      Update productive tail.

- [X] **6.9-bis 11g.2.c** Port `whereexpr.c` (~1944 lines) —
    WHERE-clause term decomposition + analysis.  Public surface:
    `sqlite3WhereSplit`, `sqlite3WhereClauseInit`,
    `sqlite3WhereClauseClear`, `sqlite3WhereExprAnalyze`,
    `sqlite3WhereTabFuncArgs`, `sqlite3WhereFindTerm`.  Internal:
    `exprAnalyze`, `exprAnalyzeAll`, `exprAnalyzeOrTerm`, `whereSplit`,
    `markTermAsChild`, `whereCombineDisjuncts`, `whereNthSubterm`,
    `transferJoinMarkings`, `isLikeOrGlob`, `whereCommuteOperator`.
    Gate: extend `TestWhereSimple.pas` with multi-term cases
    (a=1 AND b=2, a IN (1,2,3), a BETWEEN 1 AND 5).
    - [X] `whereClauseInsert` (heap-grow term array beyond aStatic),
      `markTermAsChild`, `transferJoinMarkings`, `exprCommute` ported;
      `sqlite3WhereSplit` rewritten to use `whereClauseInsert`;
      `exprAnalyze` extended with the right-side commute path
      (whereexpr.c:1222..1261) and the TK_ISNULL→TK_TRUEFALSE rewrite
      (whereexpr.c:1262..1272).  Gate: `TestWhereExpr.pas` (22/22).
    - [X] BETWEEN virtual-term synthesis (whereexpr.c:1291..1313) —
      "a BETWEEN b AND c" → (a>=b) AND (a<=c) virtual children with
      TERM_VIRTUAL|TERM_DYNAMIC and recursive exprAnalyze on each new
      term.  Gate: `TestWhereExpr.pas` T7a..T7k (33/33).
    - [X] NOTNULL virtual-term synthesis (whereexpr.c:1331..1359) —
      "x IS NOT NULL" on a non-rowid column gets a virtual "x>NULL"
      companion tagged TERM_VNULL with WO_GT.  Gate:
      `TestWhereExpr.pas` T8a..T8g (40/40).
    - [X] `whereNthSubterm` (whereexpr.c:521..534) and
      `whereCombineDisjuncts` (whereexpr.c:556..599) ported as
      collation-independent helpers for the eventual OR-term path.
      Gate: `TestWhereExpr.pas` T9a..T9b (whereNthSubterm), T10a..T10e
      ("a<5 OR a=5" → virtual TK_LE term), T11a (incompatible
      "a<5 OR a>5" leaves pWC untouched). 48/48.
    - [X] `exprAnalyzeOrTerm` (whereexpr.c:689..945) — TK_OR shatter
      into disjuncts, per-disjunct AND-decomposition, indexable bitmask
      synthesis (case 3), two-way disjunct collapse via
      `whereCombineDisjuncts` (case 2), and case-1 conversion of
      "col=A OR col=B …" into a virtual `col IN (A,B,…)` term tagged
      TERM_VIRTUAL|TERM_DYNAMIC.  Wired into `exprAnalyze`'s top-level
      OR-arm.  Gate: `TestWhereExpr.pas` T12a..T12k (case-1 IN
      synthesis on rowid OR), T13a..T13c (column-mismatched OR keeps
      ORINFO but skips the IN promotion).  62/62.
    - [X] LIKE / GLOB virtual-term synthesis (whereexpr.c:1362..1455) +
      `isLikeOrGlob` (whereexpr.c:178..343).  "x LIKE 'aBc%'" gets two
      TERM_LIKEOPT|TERM_VIRTUAL|TERM_DYNAMIC children — `x>='ABC'` (TK_GE)
      and `x<'abd'` (TK_LT) — so the pattern can be served by an index
      range scan; original LIKE term gets TERM_LIKE when noCase, plus
      isComplete-gated parent/child links.
      `termIsEquivalence` (still deferred) needs `sqlite3ExprCollSeqMatch`
      + `SQLITE_Transitive` and only affects join-graph WO_EQUIV
      propagation, never correctness.  `whereCommuteOperator` is the
      C-side `exprCommute`, already landed in 11g.2.b sub-progress.
      Gate: `TestWhereExpr.pas` T14a..T14l (LIKE on rowid → range scan
      synthesis), T15a..T15b (numeric-prefix bailout).  76/76.
    - [X] TK_VARIABLE bound-parameter LIKE path
      (whereexpr.c:208..216, 316..334).  `sqlite3VdbeSetVarmask` and
      `sqlite3VdbeGetBoundValue` ported in `passqlite3vdbe.pas`
      (vdbeaux.c:5366..5398).  `isLikeOrGlob` consults the current bound
      TEXT value of `?N` via `pParse^.pReprepare`, runs the prefix /
      numeric / wildcard scan against it, and synthesizes the same
      range-scan virtual children as the literal-string path; rebinding
      the parameter triggers reoptimize() reprepare via the expmask bit
      set on `pParse^.pVdbe`.  The QPSG gate (`SQLITE_EnableQPSG`) is
      respected — when the connection has Query-Planner Stability
      Guarantee enabled, the optimization is skipped (matches C).
      Gate: `TestWhereExpr.pas` T16a..T16g (`x LIKE ?1` with ?1 bound to
      'aBc%' synthesizes `>='ABC'` and `<'abd'` children, expmask bit 0
      set on rebind).  84/84.
    - [X] Multi-term gate extension on `TestWhereSimple.pas` — drives
      `sqlite3WhereBegin` / `sqlite3WhereEnd` and the analysis pipeline
      across three multi-term shapes:
      M1 "rowid = 5 AND col = 7" (whereShortCut still picks WHERE_IPK
      with the col=7 leaf left in `sWC` for the eventual planner;
      OP_OpenRead + OP_SeekRowid emitted; rowid leaf TERM_CODED, col=7
      leaf not TERM_CODED).
      M2 "rowid IN (1,2,3)" (whereShortCut returns 0 → WhereBegin
      returns nil cleanly; isolated `sqlite3WhereSplit` +
      `sqlite3WhereExprAnalyze` exercise tags the term with WO_IN and
      leftCursor/leftColumn set to rowid).
      M3 "rowid BETWEEN 1 AND 5" (WhereBegin returns nil; analysis in
      isolation spawns the two TERM_VIRTUAL|TERM_DYNAMIC WO_GE / WO_LE
      children, parent nChild=2, iParent links back).  39/39.

- [X] **6.9-bis 11g.2.d** Planner core in `where.c` (~5000 lines):
    `whereLoopAddBtree*`, `whereLoopAddVirtual*`, `whereLoopAddOr`,
    `whereLoopAddAll`, `wherePathSolver` + `computeMxChoice`,
    `whereRangeScanEst` (no-STAT4 tail), and ORDER BY consumption all
    ported.  `TestWherePlanner` 675/675; multi-table corpus rows
    (LEFT_JOIN, JOIN_WHERE, EXISTS_SUB, NOT_EXISTS) PASS in
    TestWhereCorpus.  vtab `xBestIndex`-style costing deferred until
    vtab corpus is exercised.
- [X] **6.9-bis 11g.2.e** `wherecode.c` (~2945 lines) per-loop
    inner-body codegen — `sqlite3WhereCodeOneLoopStart` public surface
    (prologue, IPK rowid-EQ/RANGE, INDEX_EQ/RANGE, OR-loop, scan tail,
    LEFT JOIN null-row, deferred-seek, WITHOUT-ROWID gating,
    EXPLAIN/scan-status hooks) plus leaf helpers ported.
    `TestWherePlanner` green.  `sqlite3WhereRightJoinLoop` lands with
    any future RIGHT JOIN corpus expansion.
- [ ] **6.9-bis 11g.2.f** Audit + regression.  Land
    `TestWhereCorpus.pas` covering the full WHERE shape matrix
    (single rowid-EQ, multi-AND, OR-decomposed, LIKE, IN-subselect,
    composite index range-scan, LEFT JOIN, virtual table xFilter).
    Verify byte-identical bytecode emission against C via
    TestExplainParity expansion.  Re-enable any disabled assertion /
    safety-net guards left in place during 11g.2.b..e.
    Current baseline (2026-04-27): **TestWhereCorpus 92 PASS / 0
    DIVERGE / 0 ERROR (corpus = 92); TestExplainParity 25 PASS / 1
    DIVERGE / 0 ERROR (corpus = 26); TestWherePlanner 675/675.**
    Note: tests must be run with `LD_LIBRARY_PATH=$PWD/src` so the
    `csq_*` oracle resolves to the project's `src/libsqlite3.so`, not
    the system one.

    **Open follow-on:** Re-enable productive tails:
      * `sqlite3DeleteFrom` (`passqlite3codegen.pas:17339`): truncate
        arm and where-loop / one-pass arm both productive.  vtab
        `OP_VUpdate` arm still TODO (out of current corpus).
      * `sqlite3Update` (`passqlite3codegen.pas:17835`): skeleton-only
        with snapshot/restore guard at 17890..17893 / 17965..17970;
        blocks NestedParse UPDATE of the placeholder sqlite_master row.

    The 3 TestExplainParity DIVERGEs are CREATE TABLE composite PK /
    WITHOUT ROWID (auto-index pass) and DROP TABLE op-count rows —
    structural (extra C-side scan/reinsert pre-Destroy pass that Pas
    elides; rows still materialise correctly).  Tracked under 6.10
    steps 4 and 5.

- [X] **6.9-bis 11g.2.g** TestWhereCorpus startup EAccessViolation —
    fixed by porting `exprSelectUsage` (whereexpr.c:998..1024) so
    `prereqRight` masks no longer drive inner-subselect codegen into
    mis-keyed cursor probes (commit `b94ddc1`).

- [X] **6.9-bis 11g.2.h** Standalone `DELETE FROM <tbl>` prepare —
    fixed `sqlite3SrcListIndexedBy` (always-set IS_INDEXED_BY flag) and
    `sqlite3SrcListAppend` (db/table arg swap + dequote) to mirror
    build.c:4908..5132.  Commit `df93287`.
- [ ] **6.10** `TestExplainParity.pas` — full SQL corpus EXPLAIN diff.
  Scaffold landed; corpus expanded to 26 rows (DDL + SELECT/DML/txn +
  SAVEPOINT).
  Current Status (2026-04-27): **25 PASS / 1 DIVERGE / 0 ERROR**.
  Drive to all-PASS, then expand corpus further (pragma / trigger /
  multi-table SELECT / aggregates / joins) and promote from report-only
  to hard gate.

  PASS rows: CREATE TABLE simple / typed / IF NOT EXISTS / composite PK
  / WITHOUT ROWID, CREATE INDEX, CREATE UNIQUE INDEX, DROP INDEX IF
  EXISTS, BEGIN, BEGIN IMMEDIATE, BEGIN EXCLUSIVE, COMMIT, ROLLBACK,
  SAVEPOINT, INSERT VALUES, SELECT literal, SELECT col scan, SELECT
  multi-col scan, SELECT col WHERE, SELECT rowid EQ, SELECT * scan,
  SELECT arith / string / multi literal, DELETE rowid EQ.

  DIVERGE rows + delta = (C ops − Pas ops):

  - DROP TABLE — Δ=21 (step 4)

  Root cause for DROP TABLE Δ=21 (re-analysis 2026-04-27 from
  bytecode dump):
    (a) Pas opens cursor 0 with `OP_OpenRead` and emits a 2-pass
        RowSet delete loop for the sqlite_schema scrub
        (`RowSetAdd` during scan, then `OpenWrite` + `RowSetRead` /
        `NotExists` / `Delete` / `Goto` cleanup), where C uses a
        single `OP_OpenWrite` and inline `Delete` during the scan
        (~+5 Pas ops vs C).  Tracked under 11g.2.f open follow-on:
        `sqlite3DeleteFrom` ONEPASS_MULTI promotion for non-rowid-EQ
        scans.
    (b) Pas elides the destroyRootPage autovacuum follow-on
        (`Null` / `OpenEphemeral` / `IfNot` / `OpenRead` / `Explain`
        / `Rewind` / `Column` / `ReleaseReg` / `Ne` / `ReleaseReg` /
        `Rowid` / `Insert` / `Next` / `OpenWrite` / `Rewind` /
        `Rowid` / `NotExists` / `Column`×3 / `Integer` / `Column` /
        `MakeRecord` / `Insert` / `Next` / `ReleaseReg` — ~26 ops)
        because `destroyRootPage` calls `sqlite3NestedParse(... UPDATE
        sqlite_schema SET rootpage=... WHERE ... AND rootpage=...)`
        and productive `sqlite3Update` is still skeleton-only
        (11g.2.f open follow-on).
  Net delta: −26 + 5 = −21 ✓.

  Decomposition (next-agent picklist — each is committable in
  isolation and shrinks Δ by a known amount):

    - [X] **6.10 step 2** 2-phase schema-write of `sqlite3EndTable`
      ported.  `sqlite3StartTable` now emits the placeholder
      `OpenSchemaTable` + `NewRowid` + `Blob` (6-byte nullRow) +
      `Insert(APPEND)` + `Close` (build.c:1378..1385); `sqlite3EndTable`
      emits `OP_Close 0` (build.c:2806) followed by
      `emitSchemaRowUpdate` — `Null/Noop/OpenWrite/SeekRowid/Rowid/
      IsNull/String8 ×3/Copy/String8/MakeRecord BBBDB/Delete (p2=
      OPFLAG_ISUPDATE|OPFLAG_ISNOOP)/Insert`.  CREATE INDEX path
      retains the old `emitSchemaRowInsert` direct-emit (still PASSes).
      Closed Δ=11 on three simple-CREATE rows and Δ=11 on composite-PK
      / WITHOUT-ROWID rows.  Touch points: `passqlite3codegen.pas`
      `sqlite3StartTable` (~19510), `emitSchemaRowUpdate` (~19790),
      `sqlite3EndTable` schema-row block (~19990).

    - [X] **6.10 step 3** Add `OP_Explain` + `OP_ReleaseReg` emission
      and drop the spurious `OPFLAG_ISNOOP` `OP_Delete` from
      `emitSchemaRowUpdate`.  The C oracle build (no
      `SQLITE_ENABLE_PREUPDATE_HOOK`) does not emit the pre-Insert
      Delete; it does emit the explain-comment scan op (under
      `SQLITE_ENABLE_EXPLAIN_COMMENTS`) and the `OP_ReleaseReg` debug
      op (under `SQLITE_DEBUG`) for the WHERE rowid=#N temp reg.  Net
      effect: `(+Explain +ReleaseReg −Delete) = +1`, closing Δ=1.
      Three simple-CREATE rows flip to PASS.

    - [ ] **6.10 step 4** Port `sqlite3CodeDropTable` pre-Destroy
      schema scan (build.c:3315..3445): the loop that walks
      sqlite_schema, deletes rows whose `tbl_name = 'X'`, and
      reinserts the surviving trigger rows.  Plus the trailing
      `OP_DropTable` p4=table-name + `String8` literal emissions.
      Closes Δ=22 on the DROP TABLE row.

    - [X] **6.10 step 5** Composite-PK / WITHOUT-ROWID auto-index
      bytecode pass — `convertToWithoutRowidTable` minimal viable
      (build.c:2376..2446) landed: BTREE_INTKEY→BTREE_BLOBKEY p3
      patch, OP_Noop→OP_Goto patch on the auto-index PK skip via
      sqlite3PrimaryKeyIndex(pTab) lookup, and contextual
      `OP_Noop p1=cur+1 p3=regNewRec` placeholder marker in
      `emitSchemaRowUpdate`.  Composite-PK and WITHOUT-ROWID rows
      flip to PASS.  Full helper (column reorder, repeated-PK-col
      collapse, UNIQUE-index rewrite to include PK key cols) is
      still deferred but not on any current corpus row.

    - [ ] **6.10 step 6** Expand corpus further and drive remaining
      DIVERGEs to PASS, then promote from report-only to hard gate.

      Sub-progress (2026-04-27): probe sweep added 8 PASS rows
      (multi-col / col-WHERE scans, arith / string / multi literals,
      BEGIN IMMEDIATE / EXCLUSIVE, ROLLBACK), then SAVEPOINT (port of
      sqlite3Savepoint).  Corpus now 25 PASS / 1 DIVERGE / 26 total.

      DIVERGE shapes discovered in the probe sweep (kept out of
      corpus until they flip — each is a committable next-agent
      ticket):
        * `SELECT a FROM t LIMIT 3` — Δ=9 (Pas elides LIMIT
          codegen path; needs `computeLimitRegisters` + IfPos /
          DecrJumpZero emission in `sqlite3Select`).
        * `INSERT INTO t(a) VALUES(1)` — Δ=7 (named-column INSERT
          path differs from positional; likely missing column-list
          permutation in `sqlite3Insert`).
        * `INSERT INTO t DEFAULT VALUES` — Δ=5 (no longer crashes —
          6.10b landed; Pas emits OP_Null inline per column whereas C
          uses `sqlite3ExprCodeFactorable` to hoist them into the
          OP_Init prologue so they're only evaluated once per stmt).
        * `SELECT a FROM t WHERE rowid=1 OR rowid=2` — Δ=5 (rowid
          OR-decomposed path; planner reaches multi-loop branch but
          counters disagree).
        * `DELETE FROM t WHERE a=5` — Δ=−5 (Pas heavier than C; same
          ONEPASS_MULTI gap as DROP TABLE arm (a)).
        * `PRAGMA user_version` — Δ=4 (read-pragma codegen is a stub:
          `sqlite3Pragma` in passqlite3codegen.pas:22374 returns
          immediately; needs ReadCookie / ResultRow tail at minimum).

- [X] **6.10b** Bug — `INSERT INTO <tbl> DEFAULT VALUES` raised
  EAccessViolation in `sqlite3Insert` (passqlite3codegen.pas:18974)
  because the single-row VALUES path dereferenced `pList^.nExpr`
  without guarding the `pList=nil` ⇔ DEFAULT VALUES case.  Fixed by
  mirroring insert.c:1213..1215: when pList is nil set nColumn=0 and
  emit `OP_Null` for each column slot so the subsequent OP_MakeRecord
  has well-defined inputs.  Bytecode-parity with the C reference
  (which hoists each default into the OP_Init prologue via
  `sqlite3ExprCodeFactorable`) is still off by a few ops; tracked as
  the new step-6 follow-on below.

    - [X] **6.10 step 7** SELECT/DML divergences exposed by the
      expanded corpus all closed:
        * [X] `sqlite3Select` no-FROM fast path — `SELECT <expr-list>;`
          with empty pSrc emits OP_Explain + per-col sqlite3ExprCode
          + OP_ResultRow.  SELECT literal flipped to PASS.
        * [X] `sqlite3SelectExpand` star-expansion (select.c:830..980,
          plain TK_ASTERISK only — T.\* form deferred): replaces top-
          level `*` with one TK_COLUMN per visible (non-HIDDEN /
          non-VIRTUAL) FROM-table column, populates colUsed.  Also
          fixed a latent double-advance bug in
          `sqlite3GenerateColumnNames` (Inc(items) plus items[i] index
          stepped by 2 — masked while every PASS row had nResultCol=1).
          SELECT \* scan flipped to PASS.
        * [X] OP_Explain emission landed in `sqlite3WhereExplainOneScan`
          (lower path + new multi-loop path of `sqlite3WhereBegin`).
        * [X] `sqlite3DeleteFrom` rowid-EQ → ONEPASS_SINGLE: when
          `sqlite3WhereBegin` sees `WHERE_ONEPASS_DESIRED` and the
          plan picked WHERE_ONEROW, it sets `pWInfo^.eOnePass =
          ONEPASS_SINGLE`, populates `aiCurOnePass[0]`, and opens
          the cursor with OP_OpenWrite.  DELETE rowid EQ flipped
          to PASS (in-loop Delete, no ROWSET detour).  Spurious
          memCnt-driven AddImm / FkCheck / ResultRow path closed by
          fixing the wrong default-flags bit in `passqlite3main.pas:507`
          (HI(0x00001)=SQLITE_CountRows was being set in place of the
          intended LO(0x40)=ShortColNames).
        * [X] False-WHERE-Term-Bypass spurious-fire on `rowid=5` —
          fixed by porting a productive `sqlite3ResolveExprNames`.

---

## Phase 7 — Parser (one gate open)

- [ ] **7.4b** Bytecode-diff scope of `TestParser.pas`.  Now that
  Phase 8.2 wires `sqlite3_prepare_v2` end-to-end, extend `TestParser`
  to dump and diff the resulting VDBE program (opcode + p1 + p2 + p3
  + p4 + p5) byte-for-byte against `csq_prepare_v2`.  Reuses the 7.4a
  corpus plus the SELECT / pragma / explain / commit / rollback /
  analyze / vacuum / reindex statements currently excluded.  Becomes
  feasible once 6.9 / 6.9-bis flip the EXPLAIN parity to PASS.

- [ ] **7.4c** `TestVdbeTrace.pas` differential opcode-trace gate.
  Needs SQL → VDBE end-to-end
  through the Pascal pipeline so per-opcode traces can be diffed
  against the C reference under `PRAGMA vdbe_trace=ON`.  Re-open
  once 6.9-bis flips TestExplainParity to all-PASS.

---

## Phase 8 — Public API (one gate open)

- [ ] **8.10** Public-API sample-program gate.  Pascal
  transliterations of the sample programs in `../sqlite3/src/shell.c.in`
  (and the SQLite documentation) compile and run against the port
  with results identical to the C reference.  `sqlite3.h` is
  generated by upstream `make`; reference it only after a successful
  upstream build.

---

## Phase 9 — Acceptance: differential + fuzz

- [ ] **9.1** `TestSQLCorpus.pas`: full SQL corpus (Phase 0.10 + any
  additions) runs end-to-end.  stdout, stderr, return code, and the
  resulting `.db` byte-identical to the C reference.

- [ ] **9.2** `TestReferenceVectors.pas`: every canonical `.db` in
  `vectors/` opens, queries, and reports results identically.

- [ ] **9.3** `TestFuzzDiff.pas`: AFL-driven differential fuzzer.
  Seed from the `dbsqlfuzz` corpus.  Run for ≥24 h.  Any divergence
  is a bug.

- [ ] **9.4** SQLite's own Tcl test suite (`../sqlite3/test/*.test`):
  wire the Pascal port in as an alternate target where feasible.
  Internal-API tests will not apply; the "TCL" feature tests should.

---

## Phase 10 — CLI tool (`shell.c`, ~12k lines → `passqlite3shell.pas`)

Each chunk lands with a scripted parity gate that diffs
`bin/passqlite3` against the upstream `sqlite3` binary.  Unported
dot-commands must return the upstream
`Error: unknown command or invalid arguments: ".foo"` so partial
landings cannot silently no-op.

- [ ] **10.1a** Skeleton + arg parsing + REPL loop.  Entry point,
  command-line flag parser, `ShellState` struct, line reader,
  prompts, the read-eval-print loop, statement-completeness via
  `sqlite3_complete`, exit codes.  Gate: `tests/cli/10a_repl/`.

- [ ] **10.1b** Output modes + formatting controls.  `.mode`
  (`list`, `line`, `column`, `csv`, `tabs`, `html`, `insert`, `quote`,
  `json`, `markdown`, `table`, `box`, `tcl`, `ascii`), `.headers`,
  `.separator`, `.nullvalue`, `.width`, `.echo`, `.changes`,
  `.print` / `.parameter` (formatting-only subset), Unicode-width
  helpers, box-drawing renderer.  Gate: `tests/cli/10b_modes/`.

- [ ] **10.1c** Schema introspection dot-commands.  `.schema`,
  `.tables`, `.indexes`, `.databases`, `.fullschema`,
  `.lint fkey-indexes`, `.expert` (read-only subset).  Gate:
  `tests/cli/10c_schema/`.

- [ ] **10.1d** Data I/O dot-commands.  `.read`, `.dump`, `.import`
  (CSV/ASCII), `.output` / `.once`, `.save`, `.open`.  Gate:
  `tests/cli/10d_io/`.

- [ ] **10.1e** Meta / diagnostic dot-commands.  `.stats`, `.timer`,
  `.eqp`, `.explain`, `.show`, `.help`, `.shell`/`.system`, `.cd`,
  `.log`, `.trace`, `.iotrace`, `.scanstats`, `.testcase`,
  `.testctrl`, `.selecttrace`, `.wheretrace`.  Gate:
  `tests/cli/10e_meta/`.

- [ ] **10.1f** Long-tail / specialised dot-commands.  `.backup`,
  `.restore`, `.clone`, `.archive`/`.ar`, `.session`, `.recover`,
  `.dbinfo`, `.dbconfig`, `.filectrl`, `.sha3sum`, `.crnl`,
  `.binary`, `.connection`, `.unmodule`, `.vfsinfo`, `.vfslist`,
  `.vfsname`.  Out-of-scope dependencies (session, archive, recover)
  may stub with the upstream `SQLITE_OMIT_*` "feature not compiled
  in" message.  Gate: `tests/cli/10f_misc/`.

- [ ] **10.2** Integration parity: `bin/passqlite3 foo.db` ↔
  `sqlite3 foo.db` on a scripted corpus that unions all 10.1a..f
  golden files plus kitchen-sink multi-statement sessions (modes,
  attached DBs, triggers, dump+reload).  Diff stdout, stderr, exit
  code; any divergence is a hard failure.

---

## Phase 11 — Benchmarks (Pascal-on-Pascal speedtest1 port)

Output format must be byte-identical to upstream `speedtest1` so the
existing `speedtest.tcl` diff workflow keeps working.  Lives in
`src/bench/passpeedtest1.pas`; the same binary swaps backends
(passqlite3 vs system libsqlite3) by `--backend`.

- [ ] **11.1** Harness port (speedtest1.c lines 1..780): argument
  parser, `g` global state, `speedtest1_begin_test` /
  `speedtest1_end_test`, `speedtest1_random`, `speedtest1_numbername`,
  result-printing tail.  Gate: `bench/baseline/harness.txt`.

- [ ] **11.2** `testset_main` port (lines 781..1248) — the ~30
  numbered cases (100..990) of the canonical OLTP corpus.  Primary
  regression gate.  Gate: `bench/baseline/testset_main.txt`.

- [ ] **11.3** Small / focused testsets (one chunk):
  `testset_cte` (1250..1414), `testset_fp` (1416..1485),
  `testset_parsenumber` (2875..end).  Gate:
  `bench/baseline/testset_{cte,fp,parsenumber}.txt`.

- [ ] **11.4** Schema-heavy testsets: `testset_star` (1487..2086),
  `testset_orm` (2272..2538), `testset_trigger` (2539..2740).
  Gate: `bench/baseline/testset_{star,orm,trigger}.txt`.

- [ ] **11.5** Optional / extension-gated testsets: `testset_debug1`
  (2741..2756, lands with 11.4); `testset_json` (2758..2873, gated
  on Phase 6.8 — already in scope); `testset_rtree` (2088..2270,
  gated on R-tree extension port — currently unscheduled, stub with
  omit-style message until it lands).

- [ ] **11.6** Differential driver `bench/SpeedtestDiff.pas`.  Runs
  `passpeedtest1` twice (passqlite3 vs system libsqlite3 via the
  `--backend` flag) and emits a side-by-side ratio table; strips
  wall-clock timings so the *output* of both runs can also be diffed
  for byte-equality.

- [ ] **11.7** Regression gate: commit `bench/baseline.json` (one
  row per `(testset, case-id, dataset-size)` carrying the expected
  pas/c ratio).  `bench/CheckRegression.pas` re-runs the suite,
  compares against baseline, exits non-zero on >10% relative
  regression.  Hooked into CI for small/medium tiers; the 10M-row
  tier stays a manual local gate.

- [ ] **11.8** Pragma / config matrix.  Re-run `testset_main` across
  the cartesian product `journal_mode ∈ {WAL, DELETE}`,
  `synchronous ∈ {NORMAL, FULL}`,
  `page_size ∈ {4096, 8192, 16384}`,
  `cache_size ∈ {default, 10× default}`.  Emit a single matrix
  table; the interesting result is *which knobs move the pas/c
  ratio*.

- [ ] **11.9** Profiling hand-off to Phase 12.  Wrapper scripts that
  run `passpeedtest1` under `perf record` and
  `valgrind --tool=callgrind`, plus a small Pascal helper that
  annotates the resulting reports against `passqlite3*.pas` source
  lines.  Output of this task is the input of 12.1.

---

## Phase 12 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [ ] **12.1** `perf record` on benchmark workloads; identify the
  top 10 hot functions.

- [ ] **12.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.

- [ ] **12.3** Consider replacing the VDBE big `case` with threaded
  dispatch (computed-goto-style) using `{$GOTO ON}`.  Land only if
  profiling shows the switch is a real bottleneck.

---

## Out of scope until core is green (carry-over from history.md)

These remain explicitly deferred and are **not** part of finishing
the port unless a user requests them after Phases 0–9 are green:

- `../sqlite3/ext/` — every extension directory (fts3/fts5, rtree,
  icu, session, rbu, intck, recover, qrf, jni, wasm, expert, misc).
- Test-harness C files inside `src/` (`src/test*.c`,
  `src/tclsqlite.{c,h}`).  Phase 9.4 calls the Tcl suite via the
  C-built `libsqlite3.so`, never via a Pascal port of these files.
- `src/os_kv.c` — optional key-value VFS.
- `src/os_win.c`, `src/mutex_w32.c`, `src/os_win.h` — Windows
  backend (Linux first; Windows is a Phase 11+ stretch).
- Forensic / one-off tools: `tool/showwal.c`, `dbhash`, `enlargedb`,
  `fast_vacuum`, `max-limits`, etc.  (`tool/lemon.c`,
  `tool/lempar.c` are in scope as Phase 7 inputs.)

---

## Per-function porting checklist (apply to every new function)

- [ ] Signature matches the C source (same argument order, same
  types — `u8` stays `u8`, not `Byte`).
- [ ] Field names inside structs match C exactly.
- [ ] No substitution of Pascal `Boolean` for C `int` flags — use
  `Int32` / `u8`.
- [ ] `static` C locals moved to unit-level `var` (thread-unsafe
  in C too — OK).
- [ ] `const` arrays moved verbatim; values unchanged.
- [ ] Macros expanded inline OR replaced with `inline` procedures
  of identical semantics.
- [ ] `assert()` calls retained; `AssertH` logs file/line and halts.
- [ ] Compiles `-O3` clean (no warnings in new code).
- [ ] A differential test exercises the function's layer.

---

## Design decisions

1. **Prefix convention.** Pascal port keeps `sqlite3_*` for public API
   (drop-in readable for anyone who knows the C API); C reference in
   `csqlite3.pas` is declared as `csq_*`. Tests are the only code that uses
   `csq_*`.

2. **No C-callable `.so` produced by the port.** Pascal consumers only. If
   someone later wants an ABI-compatible `.so`, revisit — it would constrain
   record layout and force `cdecl` / `export` everywhere for no current user
   demand.

3. **Split sources as the single source of truth.** `../sqlite3/src/*.c` is
   the authoritative reference **and** the oracle build input. The
   amalgamation is not generated, not checked in, not referenced. Reasons:
   (a) our Pascal unit split mirrors the C file split 1:1, so "port
   `btree.c` lines 2400–2600" is a natural commit unit; (b) grep in a 5 k-line
   file beats grep in a 250 k-line one; (c) upstream patches land in specific
   files — tracking what needs re-porting is trivial with split, painful with
   amalgamation; (d) using upstream's own `./configure && make` to build the
   oracle means compile flags, generated headers, and link order all stay
   correct by construction, without a bespoke gcc invocation that would drift.

4. **`{$MODE OBJFPC}`, not `{$MODE DELPHI}`.** Matches pas-core-math and
   pas-bzip2. Enables `inline`, operator overloading, and modern syntax.

5. **`{$GOTO ON}` project-wide.** Enabled in `passqlite3.inc`. Used (if at
   all) by the parser and possibly the VDBE dispatch. Enabling unit-by-unit
   adds noise.

6. **Differential testing is a first-class deliverable, not a QA afterthought.**
   The test harness is built before any non-trivial porting. See "The
   differential-testing foundation" above.

7. **The per-function checklist doubles as a PR template** (same convention
   as pas-core-math and pas-bzip2 — copy into each PR description).

---

## Key rules for the developer

1. **Do not change the algorithm.** This is a faithful port. The C source in
   `../sqlite3/` is the specification. If a `.db` file differs by one byte, it
   is a bug in the Pascal port, never an improvement.

2. **Port line-by-line.** Resist refactoring while porting. Refactor in a
   separate pass, after on-disk parity is proven.

3. **Every phase ends with a test that passes.** Do not advance to the next
   phase until the gating test (1.6, 2.10, 3.A.5, 3.B.4, 4.6, 5.10, 6.9, 7.4, 9.1–9.4)
   is green.

4. **Work sequentially within each phase.** Ordering is deliberate. Phase 3
   gates Phase 4 which gates Phase 5 which gates Phase 6.

5. **`libsqlite3.so` is the oracle, not a dependency.** The Pascal library
   does not link against it. Only the test binaries do, to compare outputs.

6. **No Pascal `Boolean` inside this port.** Use `Int32` or `u8`.

7. **Commit per function or per task.** Small commits with clear messages make
   bisecting an on-disk parity regression tractable.

8. **A faithful port is a multi-year effort.** The existing FPC bindings
   (`sqlite3dyn`, `sqlite3conn`) cover 99% of what most users need. This port
   is a learning and hardening exercise — scope accordingly.

---

## Architectural notes and known pitfalls

1. **No Pascal `Boolean`.** SQLite uses `int` or `u8` for flags. Pascal's
   `Boolean` is 1 byte but its canonical `True` is 255 on x86 — incompatible
   with C's `1`. Always use `Int32` or `u8` with explicit `0`/`1` literals.

2. **Overflow wrap is required.** Varint codec, hash functions, CRC, random
   number generation — all rely on unsigned 32-bit wrap. Keep `{$Q-}` and
   `{$R-}` on project-wide.

3. **Pointer arithmetic is everywhere.** Every page, cell, record, and varint
   is navigated via `u8*`. `{$POINTERMATH ON}` is required. `*p++` becomes
   `tmp := p^; Inc(p);`.

4. **UTF-8 vs UTF-16.** SQLite supports both internally. The encoding is a
   per-column property (text affinity) and a per-connection setting
   (`PRAGMA encoding`). Port the full encoding machinery; do not shortcut to
   UTF-8-only.

5. **Float formatting differs.** `printf("%g", x)` and FPC's `FloatToStr` can
   produce different strings for the same double (e.g. `1e-5` vs `0.00001`).
   Port SQLite's own `sqlite3_snprintf` (Phase 2.3) and use it; never use
   FPC's `Format`.

6. **Endianness.** SQLite stores multi-byte integers on disk in big-endian.
   FPC on x86_64 is little-endian. The varint codec handles this, but any
   direct cast `PInt32(p)^` is a portability bug on a big-endian target.
   Always go through the helpers.

7. **`longjmp` / `setjmp` absence.** SQLite does not use them. Good.

8. **Function pointers need `cdecl`.** The `sqlite3_vfs`, `sqlite3_io_methods`,
   `sqlite3_module` (virtual tables), and application-registered
   `sqlite3_create_function` / `sqlite3_create_collation` callbacks all need
   `cdecl` on their Pascal procedural types, so a C user of the port (if we
   ever ship one) can pass a C callback.

9. **`.db` header mtime.** Bytes 24–27 of the SQLite database file are a
   "change counter" updated on every write. Two binary-identical DBs from
   independent runs can differ in this field. The diff harness must
   normalise these bytes before comparing, OR (better) both runs must perform
   exactly the same number of writes, in which case the counters will match.

10. **Schema-cookie mismatch will cascade.** Bytes 40–59 of the header (the
    "schema cookie", "user version", "application ID", "text encoding", etc.)
    must be written in exactly the same order and with the same default values
    on connection open. A one-byte diff here invalidates every subsequent
    parity check.

11. **`sqlite3_randomness()` determinism.** Many corpora rely on random values
    (ROWID assignment, temp table names). The oracle must seed both the
    Pascal and C PRNGs identically for differential output to match.

12. **Algorithmic determinism is load-bearing.** Query-plan choice depends on
    `ANALYZE` statistics and on tie-breaking constants in `where.c`. If those
    constants differ by even 1%, the planner can pick a different index and
    every downstream EXPLAIN diff fails even though the result sets are
    correct. **Port the constants exactly.**

13. **Large records must be heap-allocated.** `sqlite3` (the connection),
    `Vdbe`, `Pager`, and `BtShared` are multi-KB records. Never stack-allocate.

14. **Thread safety.** Default SQLite build is serialized (full mutex).
    The Pascal port inherits the same model — every API entry point acquires
    the connection mutex. Do not try to port `SQLITE_THREADSAFE=0` first "for
    simplicity"; it changes too many code paths.

15. **`SizeOf` shadowed by same-named pointer local (Pascal case-insensitivity).**
    If a function has `var pGroup: PPGroup`, then `SizeOf(PGroup)` inside that
    function returns `SizeOf(PPGroup) = 8` (pointer) instead of the record size.
    Pascal is case-insensitive; the identifier lookup finds the local variable
    first. **Rule**: local pointer variables must NOT share their name with any
    type. Convention: use `pGrp`, `pTmp`, `pHdr`, never exactly `PPGroup → PGroup`.
    After porting any function, grep for `SizeOf(P` and verify the named type has
    no same-named local in scope.

16. **Unsigned for-loop underflow.** `for i := 0 to N - 1` is safe only when N > 0.
    When `i` or `N` is `u32` and `N = 0`, `N - 1 = $FFFFFFFF` → 4 billion
    iterations → instant crash. In C, `for(i=0; i<N; i++)` skips cleanly.
    **Rule**: always guard with `if N > 0 then` before such a loop, or rewrite
    as `i := 0; while i < N do begin ... Inc(i); end`.
