# pas-sqlite3 — Remaining Task List

Port of **SQLite 3** (D. Richard Hipp et al., public domain) from C to Free Pascal.
Source of truth: `../sqlite3/` (the original C reference — the upstream split
source tree under `../sqlite3/src/*.c`). The amalgamation is **not used** by
this project, neither as a porting reference nor as an oracle build input.
Inspiration for structure, tone, and workflow: `../pas-core-math/`, `../pas-bzip2/`.

REMEMBER: You are porting code. DO NOT RANDOMLY ADD TESTS unless you are looking for a specific bug. If you are porting existing tests in C, mention the origin of the test that you are porting.

DO NOT default to the same work pattern as recent commits without questioning whether actually move the project forward.

BEFORE TRYING TO FIX A BUG, LOOK AT THE ORIGINAL C IMPLEMENTATION!!!

BEFORE STARTING TO PORT A NEW FUNCTION OR PROCEDURE, CHECK IF THIS FUNCTION ALREADY EXISTS AND IS NOT A STUB.

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

- [ ] **6.9-bis 11g.2.b** Port `sqlite3WhereBegin` / `sqlite3WhereEnd` in full.  
    Bookkeeping primitives, prologue,
    cleanup contract, and several leaf helpers (codeCompare cluster,
    sqlite3ExprCanBeNull, sqlite3ExprCodeTemp + 6 unary arms,
    TK_COLLATE/TK_SPAN/TK_UPLUS arms, whereShortCut, allowedOp +
    operatorMask + exprMightBeIndexed + minimal-viable exprAnalyze)
    are already ported.
      - [ ] port in full or re-enable `sqlite3Update`
      - [ ] port in full or re-enable `sqlite3GenerateConstraintChecks`
      - [X] port in full `sqlite3CompleteInsertion` (insert.c:2782..2847).
        Function is ported and compiles; not yet wired into `sqlite3Insert`
        (still inline-emits the OP_Insert path) so does not move Δ until
        `sqlite3GenerateConstraintChecks` lands and call-site swaps over.
- [ ] **6.9-complete** complete the porting of `sqlite3VdbeRecordCompare` and
  `sqlite3VdbeFindCompare` in FULL in `passqlite3btree.pas`.  Handles MEM_Int / MEM_IntReal - currently insufficient for general index lookup.

- [ ] **6.9-bis 11g.2.f** Audit + regression.        
        Note: tests must be run with `LD_LIBRARY_PATH=$PWD/src` so the
        `csq_*` oracle resolves to the project's `src/libsqlite3.so`, not
        the system one.

    - [ ] Port in full `sqlite3Update` body (skeleton-only today;
      blocks DROP TABLE Δ=21 destroyRootPage path and UPDATE rowid=1
      Δ=14).

- [ ] **6.10** `TestExplainParity.pas`
    - [ ] **6.10 step 4** DROP TABLE schema-row deletion does not run.
      `sqlite3CodeDropTable` itself is fully ported (build.c:3387) and
      calls `sqlite3NestedParse(... DELETE FROM sqlite_schema ...)`
      identically to C.  The actual blocker is that
      `sqlite3RunParser` (passqlite3codegen.pas) is still a Phase-7
      stub — `sqlite3NestedParse` formats the SQL and hands it to
      `gNestedRunParser`, which never compiles it, so no schema-row
      deletion ops are emitted.  OP_DropTable then destroys the btree
      root while the sqlite_schema row survives pointing at the
      now-invalid rootpage.
      **Runtime impact (verified 2026-04-27):**
      `DROP TABLE t` followed by `CREATE TABLE t(...)` or
      `SELECT * FROM t` on the same connection returns
      `SQLITE_CORRUPT` (rc=11) / `SQLITE_ERROR` (rc=1) on Pas; C
      returns no-such-table cleanly and lets re-CREATE succeed.
      Repro: `sqlite3_open(":memory:")` → CREATE / INSERT / DROP /
      CREATE.  Closing this row requires Phase 7 `sqlite3RunParser`.

    - [ ] **6.10 step 6** Make these to work (port code when required):
        [ ] `INSERT INTO t VALUES(1,2,3),(4,5,6)` — Δ=11 (multi-row
          VALUES path).
        [ ] **IPK-IN execution path**
            [ ] **6.10 step 6.IPK-IN.b.full** Port 
                `sqlite3VdbeRecordCompare` in full to cover string (collation
                + encoding-change), blob (with MEM_Zero), and real
                RHS arms.  Required before any non-IPK ephemeral
                index lookup (column IN with text keys, ORDER BY
                sorter materialisation, etc.) executes correctly.
                Layout note: btree's slim `TUnpackedRecord` does
                NOT mirror the C `UnpackedRecord` (no errCode/r1/r2,
                nField is i32 not u16, default_rc is i32 not i8) —
                reconcile that vs. codegen.pas's bigger
                TUnpackedRecord before porting the corruption /
                BIGNULL / DESC arms.
        [ ] `SELECT DISTINCT a FROM t` — Δ=13 (DISTINCT codegen,
          ephemeral-table dedup not yet wired in `sqlite3Select`).
        [ ] `SELECT a FROM t ORDER BY a` (asc/desc/multi-col) —
          Δ=16..18 (ORDER BY sorter / ephemeral-key path: Pas emits
          only 3 ops, no sorter open / KeyInfo / sort-finalise loop).
        [ ] `SELECT a FROM t GROUP BY a` — Δ=42 (aggregate-group
          path, not yet ported).
        [ ] `SELECT SUM/MIN/MAX(a)` — Δ=12..13 (aggregate-no-GROUP
          path).  Needs AggStep + AggFinal codegen
          (select.c:8819+).  The `selectMarkAggregate` walker keeps
          the runtime stub safe until that lands.
        [ ] `SELECT a FROM (SELECT a FROM t)` — Δ=7 (sub-FROM
          materialise / co-routine path not ported).
        [ ] `UPDATE t SET a=5 WHERE rowid=1` — Δ=14 (`sqlite3Update`
          still skeleton-only — see 11g.2.f open follow-on).
        [ ] `INSERT INTO u VALUES(1, 2);` (u declared `p PRIMARY KEY,
          q` — non-INTEGER PK, so NOT a rowid alias) — Δ=11.  Diag
          (`src/tests/DiagAutoIdx.pas`) confirms the implicit
          `sqlite_autoindex_u_1` *is* registered at parse time
          (sqlite_schema row, rootpage 5), so the gap is downstream:
          the INSERT codegen does not maintain the autoindex because
          `sqlite3GenerateConstraintChecks` + `sqlite3CompleteInsertion`
          are still stubs (see 6.9-bis 11g.2.b open items).  Closing
          those will close this row.
        [ ] `SELECT p FROM u;` — per-op divergence at op[1]
          (`OpenRead p1=1 p2=5` in C vs `p1=0 p2=4` in Pas).  Same
          fixture: u has the implicit autoindex on `p`.  C planner
          picks the autoindex for a covering scan (rootpage 5);
          Pas planner falls through to the table scan (rootpage 4).
          Root cause: `whereLoopAddBtree` / `bestIndex` cost model
          not yet considering covering indexes when no WHERE clause
          exists.  Distinct from the INSERT row above — needs planner
          work, not insert.c work.
  
  [ ] **6.11** DROP TABLE remaining gap (current Δ=26, was Δ=21):
    (a) [X] ONEPASS_MULTI promotion landed in sqlite3WhereBegin,
        the sqlite_schema scrub now uses one-pass inline delete.
    (b) [ ] Pas elides the destroyRootPage autovacuum follow-on (~26 ops)
        because `destroyRootPage` calls `sqlite3NestedParse(UPDATE
        sqlite_schema ...)` and productive `sqlite3Update` is still
        skeleton-only.  This is the only remaining contributor.
  [ ] **6.12** port sqlite3Pragma in full
  [ ] **6.13** port sqlite3Vacuum in full
  [X] **6.14** port sqlite3WhereTabFuncArgs in full (whereexpr.c:1899..1944).
  [X] **6.15** port sqlite3WhereAddLimit + whereAddLimitExpr in full
       (whereexpr.c:1620..1736).
  [X] **6.16** port btree.pas stubs in full: `ptrmapPutOvflPtr`,
       `invalidateIncrblobCursors`.
  [X] **6.17** port pager.pas stubs in full: `pager_reset`,
       `pagerReleaseMapPage`, `sqlite3_log`.
  [X] **6.18** port wal.pas stub `sqlite3_log_wal` in full.
  [X] **6.19** port util.pas stubs `sqlite3_mprintf` / `sqlite3_snprintf`
       in full.
  [ ] **6.20** port remaining parser.pas stubs in full:
       `sqlite3ExprListAppendVector` (blocked on
       `sqlite3ExprForVectorField`, expr.c:1893),
       `sqlite3TriggerUpdateStep` + Insert/Delete/Select step
       siblings (blocked on trigger.c step-builder port),
       `sqlite3CteNew`, `sqlite3WithAdd` (blocked on full TCte
       record definition; current TWith is a 64-byte opaque stub).
       (`addModuleArgument` already fully ported — parser.pas:2020.
       `sqlite3Reindex` ported in full — parser.pas:1821.)
  [ ] **6.21** port vdbe.pas stubs in full from C to pascal:
       `sqlite3VdbeMultiLoad`, `sqlite3VdbeScanStatus`,
       `sqlite3VdbeScanStatusRange`, `sqlite3VdbeSetP4KeyInfo`,
       `sqlite3VdbeExplainParent`, `sqlite3ExplainBreakpoint`,
       `sqlite3VdbeIncrWriteCounter`, `sqlite3VdbeDisplayComment`,
       `sqlite3VdbeDisplayP4`, `sqlite3VdbeEnter`,
       `sqlite3VdbeFrameMemDel`, `sqlite3VdbeNextOpcode`,
       `sqlite3VdbeFrameRestore`, `sqlite3VdbeSetColName`,
       `sqlite3VdbeCloseStatement`, `sqlite3VdbeList`,
       `sqlite3VdbePrintSql`, `sqlite3VdbeError`,
       `sqlite3_blob_open`, `sqlite3VdbeLogAbort`,
       `sqlite3VdbeSetChanges`, `sqlite3SystemError`,
       `sqlite3ResetOneSchema`, `sqlite3VdbeMemTranslate`,
       `sqlite3VdbeMemHandleBom`, `sqlite3ExpirePreparedStatements`,
       `sqlite3AnalysisLoad`, `sqlite3UnlinkAndDeleteTable`,
       `sqlite3UnlinkAndDeleteIndex`, `sqlite3UnlinkAndDeleteTrigger`,
       `sqlite3RootPageMoved`, `sqlite3FkClearTriggerCache`,
       `sqlite3ResetAllSchemasOfConnection`, `sqlite3Stat4ProbeFree`.
  [ ] **6.22** port codegen.pas rename / error-offset stubs in full from C
       to pascal: `sqlite3RenameExprUnmap`, `sqlite3RenameTokenMap`,
       `sqlite3VdbeAddDblquoteStr`, `sqlite3RecordErrorOffsetOfExpr`.
  [ ] **6.23** port codegen.pas trigger stubs in full from C to pascal:
       `sqlite3TriggerList`, `sqlite3BeginTrigger`, `sqlite3FinishTrigger`,
       `sqlite3DropTrigger`, `sqlite3DropTriggerPtr`,
       `sqlite3UnlinkAndDeleteTrigger`, `sqlite3TriggersExist`,
       `sqlite3CodeRowTriggerDirect`, `sqlite3CodeRowTrigger`,
       `sqlite3TriggerStepSrc`, `sqlite3TriggerColmask`.
  [ ] **6.24** port codegen.pas DML / insert stubs in full from C to pascal:
       `sqlite3UpsertAnalyzeTarget`, `sqlite3UpsertDoUpdate`,
       `sqlite3MaterializeView`, `sqlite3LimitWhere`,
       `sqlite3ColumnDefault`, `sqlite3TableAffinity`,
       `sqlite3ComputeGeneratedColumns`, `sqlite3AutoincrementBegin`,
       `sqlite3AutoincrementEnd`, `sqlite3MultiValuesEnd`,
       `sqlite3MultiValues`, `autoIncBegin`,
       `sqlite3ExprReferencesUpdatedColumn`,
       `sqlite3GenerateConstraintChecks`.
       (`sqlite3CompleteInsertion` is now fully ported — see 6.9-bis 11g.2.b.)
  [ ] **6.25** port codegen.pas schema / index stubs in full from C to pascal:
       `sqlite3ReadSchema`, `sqlite3PrimaryKeyIndex`,
       `sqlite3CheckObjectName`, `sqlite3FreeIndex`,
       `sqlite3AddNotNull`, `sqlite3RunParser`.
  [ ] **6.26** port codegen.pas where / select / window stubs in full from C
       to pascal: `sqlite3MatchEName`, `sqlite3SelectPopWith`,
       `whereRightSubexprIsColumn`, `sqlite3WhereMinMaxOptEarlyOut`,
       `wherePathMatchSubqueryOB`, `sqlite3KeyInfoFromExprList`,
       `sqlite3SelectWalkAssert2`, `sqlite3SelectAddTypeInfo`,
       `sqlite3SelectCheckOnClauses`, `sqlite3ExprNNCollSeq`,
       `sqlite3ExprCollSeq`,
       `sqlite3WhereExplainBloomFilter`, `sqlite3WhereAddExplainText`,
       `sqlite3WindowCodeInit`, `sqlite3WindowCodeStep`,
       `sqlite3BtreeHoldsAllMutexes`.
  [ ] **6.27** port codegen.pas alter / attach / analyze / vacuum / FK /
       extension / scalar-function stubs in full from C to pascal:
       `sqlite3AlterRenameTable`, `sqlite3AlterFinishAddColumn`,
       `sqlite3AlterAddConstraint`, `sqlite3Detach`, `sqlite3Attach`,
       `sqlite3Analyze`, `sqlite3DeleteIndexSamples`, `sqlite3Vacuum`,
       `sqlite3AutoLoadExtensions`, `errlogFunc`, `unlikelyFunc`,
       `sqlite3FkCheck`, `sqlite3FkActions`.
  [ ] **6.28** sweep — re-search for "stub" in the pascal source code and
       port from C to pascal in full any function or procedure still
       marked as "stub" that was missed by 6.16..6.27 (catch-all).
---

## Phase 7 — Parser (one gate open)

- [ ] **7.4b** Bytecode-diff scope of `TestParser.pas`.  Now that
  Phase 8.2 wires `sqlite3_prepare_v2` end-to-end, extend `TestParser`
  to dump and diff the resulting VDBE program (opcode + p1 + p2 + p3
  + p4 + p5) byte-for-byte against `csq_prepare_v2`.  Reuses the 
  corpus plus the SELECT / pragma / explain / commit / rollback /
  analyze / vacuum / reindex statements.

- [ ] **7.4c** `TestVdbeTrace.pas` differential opcode-trace gate.
  Needs SQL → VDBE end-to-end
  through the Pascal pipeline so per-opcode traces can be diffed
  against the C reference under `PRAGMA vdbe_trace=ON`.

---

## Phase 8 — Public API (one gate open)

- [ ] **8.10** Public-API sample-program gate.  Pascal
  transliterations of the sample programs in `../sqlite3/src/shell.c.in`
  (and the SQLite documentation) compile and run against the port
  with results identical to the C reference.  `sqlite3.h` is
  generated by upstream `make`; reference it only after a successful
  upstream build.

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

## Phase 12 — Acceptance: differential + fuzz

- [ ] **12.1** `TestSQLCorpus.pas`: full SQL corpus (Phase 0.10 + any
  additions) runs end-to-end.  stdout, stderr, return code, and the
  resulting `.db` byte-identical to the C reference.

- [ ] **12.2** `TestReferenceVectors.pas`: every canonical `.db` in
  `vectors/` opens, queries, and reports results identically.

- [ ] **12.3** `TestFuzzDiff.pas`: AFL-driven differential fuzzer.
  Seed from the `dbsqlfuzz` corpus.  Run for ≥24 h.  Any divergence
  is a bug.

- [ ] **12.4** SQLite's own Tcl test suite (`../sqlite3/test/*.test`):
  wire the Pascal port in as an alternate target where feasible.
  Internal-API tests will not apply; the "TCL" feature tests should.

---

## Phase 13 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [ ] **13.1** `perf record` on benchmark workloads; identify the
  top 10 hot functions.

- [ ] **13.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.

- [ ] **13.3** Consider replacing the VDBE big `case` with threaded
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
