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

Source of truth for definitions, scope notes, gates, and discoveries
remains `history.md`.  This file is the punch list.

---

## Phase 5 — VDBE (one item open)

- [ ] **5.10** `TestVdbeTrace.pas` differential opcode-trace gate.
  Deferred behind Phase 6.9 / 7.4b: needs SQL → VDBE end-to-end
  through the Pascal pipeline so per-opcode traces can be diffed
  against the C reference under `PRAGMA vdbe_trace=ON`.  Re-open
  once 6.9-bis flips TestExplainParity to all-PASS.

---

## Phase 6 — Code generators (close the EXPLAIN gate)

- [~] **6.9** `TestExplainParity.pas` — full SQL corpus EXPLAIN diff.
  Scaffold is landed (10-row DDL/transaction corpus, report-only).
  Status 2026-04-26: **2 PASS / 8 DIVERGE / 0 ERROR**.  Drive to
  all-PASS, then expand corpus to DML / SELECT / pragma / trigger
  forms (same exclusion list as TestParser).  Promote from
  report-only to hard gate when the full corpus is green.

- [~] **6.9-bis** Drive the diverge/error counts to zero.  All earlier
  sub-steps (11a–11g.1) are in.  Remaining work is the WHERE-engine
  port — the largest single chunk of porting still ahead.

  - [~] **6.9-bis 11g.2.b** Vertical slice — minimal-viable
    `sqlite3WhereBegin` / `sqlite3WhereEnd` for the single-table,
    single-rowid-EQ-predicate case.  Bookkeeping primitives, prologue,
    cleanup contract, and several leaf helpers (codeCompare cluster,
    sqlite3ExprCanBeNull, sqlite3ExprCodeTemp + 6 unary arms,
    TK_COLLATE/TK_SPAN/TK_UPLUS arms) are already landed.
    Outstanding sub-progress before this slice closes:
    - [X] Port `exprComputeOperands` (expr.c:2417..2464) and land
      the comparison cluster (TK_IS/TK_ISNOT/TK_LT..TK_EQ) plus the
      arithmetic cluster (TK_PLUS..TK_CONCAT, incl. TK_STAR/TK_REM/
      TK_BITAND/TK_BITOR/TK_SLASH/TK_LSHIFT/TK_RSHIFT) in
      `sqlite3ExprCodeTarget`.  (Done — codegen.pas:3859..3979.)
      Note: `exprCodeBetween` deferred — depends on the still-unported
      `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` recursive jump pair;
      track separately under the IfTrue/IfFalse sub-bullet below.
      Also note: vector-comparison fast path (`codeVectorCompare`)
      stubbed to OP_Null inside the comparison arm — vector EQ inside
      a non-row-value WHERE clause does not arise on the corpus this
      slice gates on, so the stub is acceptable until 11g.2.e.
    - [ ] Port the recursive jump pair `sqlite3ExprIfTrue` /
      `sqlite3ExprIfFalse` (expr.c:6100..6500-ish, ~400 lines).
    - [ ] Port the False-WHERE-Term-Bypass loop in `sqlite3WhereBegin`
      (where.c:6995..7036).
    - [ ] Implement the trimmed planner pick + `OP_NotExists` emission
      for the rowid-EQ shape (hard-code the cost selection; defer
      `whereLoopAddBtree` etc.).
    - [ ] Implement the loop-tail half of `sqlite3WhereEnd`
      (Goto continue + Resolve break label + cursor close).
    - [ ] Re-enable productive tails in `sqlite3DeleteFrom`
      (codegen.pas:5460..5471) and `sqlite3Update`
      (codegen.pas:5660..5670); drop the step-11f skeleton-only
      error-state guard at codegen.pas:5401..5410 + 5577..5599.
    - [ ] Promote the five `WHERE_*` `_C`-suffixed file-private flag
      constants (ONEPASS_DESIRED, ONEPASS_MULTIROW, OR_SUBCLAUSE,
      KEEP_ALL_JOINS, USE_LIMIT) to the public const block
      (codegen.pas:1392..1407) and drop the `_C` suffix.
    - [ ] Land the eDistinct=WHERE_DISTINCT_UNIQUE branch (currently
      TODO defaulting to WHERE_DISTINCT_NOOP) once
      `OptimizationEnabled` / `SQLITE_DistinctOpt` is ported.
    - [ ] New gate `TestWhereSimple.pas` — hand-built SrcList +
      rowid-EQ Expr; assert OP_NotExists / OP_Goto / labels emitted
      in expected order.
    Expected TestExplainParity bump after this slice lands:
    2 PASS / 8 DIVERGE → 7 PASS / 3 DIVERGE.

  - [ ] **6.9-bis 11g.2.c** Port `whereexpr.c` (~1944 lines) —
    WHERE-clause term decomposition + analysis.  Public surface:
    `sqlite3WhereSplit`, `sqlite3WhereClauseInit`,
    `sqlite3WhereClauseClear`, `sqlite3WhereExprAnalyze`,
    `sqlite3WhereTabFuncArgs`, `sqlite3WhereFindTerm`.  Internal:
    `exprAnalyze`, `exprAnalyzeAll`, `exprAnalyzeOrTerm`, `whereSplit`,
    `markTermAsChild`, `whereCombineDisjuncts`, `whereNthSubterm`,
    `transferJoinMarkings`, `isLikeOrGlob`, `whereCommuteOperator`.
    Gate: extend `TestWhereSimple.pas` with multi-term cases
    (a=1 AND b=2, a IN (1,2,3), a BETWEEN 1 AND 5).

  - [ ] **6.9-bis 11g.2.d** Port the planner core in `where.c`
    (~5000 lines): `whereLoopAddBtree`, `whereLoopAddBtreeIndex`,
    `whereLoopAddVirtual*`, `whereLoopAddOr`, `whereLoopAddAll`,
    `whereLoopOutputAdjust`, `whereLoopFindLesser`, `whereLoopInsert`,
    `whereLoopCheaperProperSubset`, `whereLoopAdjustCost`, the N-best
    path search in `wherePathSolver`.  Replaces the hard-coded rowid-
    EQ pick from 11g.2.b with real N-way join planning, index
    selection, and ORDER BY consumption.  May need further
    sub-splitting once 11g.2.a..c reveal field-shape requirements.
    Defer `xBestIndex`-style virtual-table costing until vtab corpus
    is exercised.

  - [ ] **6.9-bis 11g.2.e** Port `wherecode.c` (~2945 lines) —
    per-loop inner-body codegen.  Public surface:
    `sqlite3WhereCodeOneLoopStart`, `sqlite3WhereRightJoinLoop`,
    `sqlite3WhereExplainOneScan`, `sqlite3WhereAddScanStatus`,
    `disableTerm`, `codeApplyAffinity`, `codeEqualityTerm`,
    `codeAllEqualityTerms`, `whereLikeOptimizationStringFixup`,
    `codeCursorHint`.  Replaces the inlined NotExists emission from
    11g.2.b with full index-key construction, range-scan setup,
    virtual-table xFilter glue, and per-row body dispatch.

  - [ ] **6.9-bis 11g.2.f** Audit + regression.  Land
    `TestWhereCorpus.pas` covering the full WHERE shape matrix
    (single rowid-EQ, multi-AND, OR-decomposed, LIKE, IN-subselect,
    composite index range-scan, LEFT JOIN, virtual table xFilter).
    Verify byte-identical bytecode emission against C via
    TestExplainParity expansion.  Re-enable any disabled assertion /
    safety-net guards left in place during 11g.2.b..e.

---

## Phase 7 — Parser (one gate open)

- [ ] **7.4b** Bytecode-diff scope of `TestParser.pas`.  Now that
  Phase 8.2 wires `sqlite3_prepare_v2` end-to-end, extend `TestParser`
  to dump and diff the resulting VDBE program (opcode + p1 + p2 + p3
  + p4 + p5) byte-for-byte against `csq_prepare_v2`.  Reuses the 7.4a
  corpus plus the SELECT / pragma / explain / commit / rollback /
  analyze / vacuum / reindex statements currently excluded.  Becomes
  feasible once 6.9 / 6.9-bis flip the EXPLAIN parity to PASS.

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
