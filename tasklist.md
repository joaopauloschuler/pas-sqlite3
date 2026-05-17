# pas-sqlite3 — Remaining Task List

Port of **SQLite 3** (D. Richard Hipp et al., public domain) from C to Free Pascal.
Source of truth: `../sqlite3/` (the original C reference — the upstream split
source tree under `../sqlite3/src/*.c`). The amalgamation is **not used** by
this project, neither as a porting reference nor as an oracle build input.
Inspiration for structure, tone, and workflow: `../pas-core-math/`, `../pas-bzip2/`.

REMEMBER: You are porting code. DO NOT RANDOMLY ADD TESTS unless you are looking for a specific bug. If you are porting existing tests in C, mention the origin of the test that you are porting.

If you don't have a house, you wont have a water leak in your house. If you build a house, you will not destroy the house because it has a water leak. If you can not solve the water leak, you'll keep the house and take note to fix it in a day that you can fix.

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

> Closed tasks/bugs are intentionally terse — full postmortems live in git
> history. Re-open a bullet (flip `[X]` → `[ ]`) and re-add detail only if the
> symptom returns.

---

## Working on this codebase (orientation for new contributors)

Correctness is defined **differentially against the C oracle**, not by hand-written
assertions.  Two gates matter:

* `bin/TestExplainParity` — the **bytecode** gate.  **1026/1026** SQL
  statements emit byte-identical VDBE vs C as of 2026-05-06 (a3).
* `src/tests/Diag*.pas` (`DiagOps`, `DiagCast`, `DiagFunctions`, `DiagWindow`,
  `DiagTxn`, `DiagFeatureProbe`, …) — the **runtime** gates.  Each probe pins a
  narrow runtime divergence to a numbered "Open Bugs" bullet.  When a Diag
  starts passing, tick the bullet.

Build with `src/tests/build.sh`; run binaries with
`LD_LIBRARY_PATH=src/ bin/<TestName>`.

FPC porting traps that recur often enough to call out up-front:

* Free Pascal identifiers are case-insensitive, so `var pPager: PPager` collides
  with the type name — rename the local (e.g. `pPgr`).  Same pattern with
  `pgno: Pgno` → `pg: Pgno`.
* `pager_error` collides with the `PAGER_ERROR` constant — always call
  `pagerSetError`.
* `var pTrigger: PTrigger` shadows a record field — rename to `pTrg`.
* The token `TK_GT` collides; use `TK_GT_TK` (and `WO_GT_WO`) when porting C arms.
* Never commit binaries from `bin/` (or `*.o`, `*.ppu`); `git rm --cached` if
  one slipped in.

---

> Closed-task postmortems for Phases 6–9 archived in
> [`tasklist-landed.md`](tasklist-landed.md).  This file keeps task IDs +
> one-line outcomes + key cites only.

## Phase 5 — Deferred carry-overs

- [ ] **5.7.b** `sqlite3VdbeSorter*` PMA disk-spill — STUB_INVENTORY #13 DRIFTED-XL (~2400 lines C, vdbesort.c).  In-memory mergesort is real and 1:1; PMA (Packed Memory Array) on-disk merge for sorts larger than the in-memory buffer is not yet ported.  Symptom when missed: large ORDER BY / GROUP BY / CREATE INDEX over multi-page data will fail or silently degrade once the sort buffer overflows.  Complexity: XL.  Blockers: none (self-contained — driver and PMA writer/reader port without touching the VDBE dispatch).

---

## Phase 6 — Code generators (close the EXPLAIN gate)

> TestExplainParity reports **1026 / 1026 PASS** as of 2026-05-06 (a3).

- [X] **6.8.0..6.8.6** Pragma vtab register, GenerateConstraintChecks, CompleteInsertion, WhereBegin, WhereEnd, Insert (incl. multi-row VALUES coroutine arm).
- [X] **6.8.1** sqlite3Update — single-table, UPDATE FROM, vtab dispatch, RETURNING.
- [X] **6.9** sqlite3VdbeRecordCompare / FindCompare full bodies in btree.pas.
- [X] **6.24** Aggregate-with-ORDER-BY codegen.
- [~] **6.26** Window functions (window.c). DiagWindow: 0 divergences. Reopen if DiagWindow regresses.
- [X] **6.27** schema-mutation + statistics. Analyze, Vacuum, RunVacuum, FkCheck/FkActions.
- [~] **6.28** sweep — re-search for "stub" in the pascal source code and port from C to pascal in full any function or procedure still marked as "stub" that was missed (catch-all). OP_Vacuum, BtreeIncrVacuum done; incrVacuumStep / relocatePage / modifyPagePointer not ported (gated on productive ptrmap). Inventory landed at `src/tests/STUB_INVENTORY.md` (21 actionable entries: 7 high / 6 med / 8 low). One small high-priority entry ported in 6.28 commit (`pas_openDirectory`, os_unix.c:3874..3894 → src/passqlite3os.pas:2331). Doable subtasks for the remaining six high-priority stubs (each cites the open Phase-6/9 bullet it blocks; see STUB_INVENTORY.md for full Pascal/C citations):
  - [X] **6.28.1** `whereLoopAddVirtual` deeper arms — stub-was-real (1:1 port of where.c:4681..4803).
  - [X] **6.28.2** `sqlite3OpenTableAndIndices` full body — stub-was-real (1:1 port of insert.c:2870..2925).
  - [X] **6.28.3** `sqlite3NestedParse` body ported (build.c:293..323) via gNestedRunParser hook.
  - [X] **6.28.4** `sqlite3AddColumn` drift arms — three small dequote/strip arms ported 1:1 (build.c:1507/1513/1530).
  - [X] **6.28.5** `sqlite3LimitWhere` — stub-was-real (1:1 port of delete.c:182..277).
  - [X] **6.28.6** `OP_IntegrityCk` body + `sqlite3BtreeIntegrityCheck` — stub-was-real.
  - [X] **6.28.6.b** Higher-level `PRAGMA integrity_check` walk arms — pragma.c:1792..2194 (row walk, CHECK, per-index validation, UNIQUE duplicate detection). Archive.
  - [X] **6.28.6.a** PRAGMA integrity_check/quick_check wired to emit real OP_IntegrityCk plan (pragma.c:1695..1820 + 2195..2217).
  - [X] **6.28.6.c** vtab xIntegrity dispatch:
    - [~] **6.28.6.c.1** ~~FK referential walk~~ DROPPED 2026-05-13 — phantom cite (integrity_check carries no FK walk; PRAGMA foreign_key_check is separate). Archive.
    - [X] **6.28.6.c.2** vtab `xIntegrity` dispatch — emits `OP_VCheck p1=iDb, p2=errReg, p3=isQuick, p4=pTab(P4_TABLEREF)`. Cite: pragma.c:2163..2193. Archive.
  - [X] **6.28.7** `getRowTrigger` / `codeRowTrigger` / `sqlite3TriggerColmask` — stub-was-real (1:1 with trigger.c:1347 / 1231).
  - [X] **6.28.8** Audit pass on high-priority STUB_INVENTORY entries (#1/#2/#5/#6 CLOSED was-real, #4 DRIFTED-S done in 6.28.4).
  - [X] **6.28.9** Medium-priority audit pass — 5 stub-was-real, 1 DRIFTED-XL (#13 sorter PMA-spill deferred to 5.7.b).
  - [X] **6.28.10** Low-priority audit pass — 5 intentional no-ops faithful to C preprocessor-gated empty macros, 2 was-real with banner refresh.

### Closed bugs (kept as ticked stubs)

- [X] **6.10** TestExplainParity closed.
- [X] **6.11** PRAGMA page_count + DROP TABLE remaining gap closed.
- [X] **6.12** sqlite3Pragma full port; DiagPragma all PASS.
- [X] **6.13** `pragma_foreign_key_list(s.name)` (and other table-valued PRAGMA functions).
- [X] **6.14** Compound `SELECT … FROM sqlite_schema … UNION ALL …` — compound dispatch + selectExpander/resolveSelectNames walk pPrior.
- [X] **6.15** TestExplainParity transient regression — resolved on clean rebuild.
- [X] **6.16** Multi-vtab LEFT-JOIN + multi-aggregate AV — fixed by `sqlite3VdbeMakeReady` zero-init (see feedback memory `vdbemakeready_zero_init`).
- [X] **6.17** OR-decomposed Case-5 codegen + LIKE/GLOB range-bound prefix truncation (sub-bugs 6.17.A/B).
- [X] **6.18** pcachetrace / memtrace trampoline AV when sink is non-nil (SQLITE_CONFIG_GETPCACHE2/GETMALLOC arms now call SetDefault before copying methods).
- [X] **6.19** `.open --deserialize` — `sqlite3AppendvfsInit` was FillChar-zeroing apnd_vfs.pNext on every call, severing the VFS chain.
- [X] **6.20** Shim-VFS re-init chain corruption — same FillChar pattern in cksm/vstat/tmstmp/vlog VFS shims; all gated by initialised-Boolean now.
- [X] **6.21** `-memtrace` silent — `sqlite3Malloc` now routes through `sqlite3GlobalConfig.m.xMalloc`; libc bindings renamed to `libc_*`.
- [X] **6.22** Safe-mode error-prefix gap (`data.zErrPrefix = zErrCtx`) — argv-prefix swap ported to `processCommandLine`.
- [X] **6.23** `sqlite3_open_v2` doesn't honor `file:` URI filenames — wired `sqlite3ParseUri` into `openDatabase`; CLI calls `sqlite3_config(SQLITE_CONFIG_URI, 1)`.
- [X] **6.29 / 6.29.followup** `sum(b) OVER ()` / `avg(b) OVER ()` — colUsed propagation across window-rewrite boundary in sqlite3WindowRewrite.
- [X] **6.30** unix VFS iVersion bumped to 3 — ported `aSyscall[]` table + `unixSetSystemCall`/`unixGetSystemCall`/`unixNextSystemCall` in `passqlite3os.pas`, wired into `unixVfsObj`.
- [X] **6.31** unix-VFS locking-style shims — `unix-none`/`unix-dotfile`/`unix-excl` siblings auto-registered (os_unix.c:8499..8542).
- [X] **6.13.B.11** `.expert` `(no new indexes)` — eponymous-vtab fast arm in `sqlite3Select` was firing for every single-source vtab SELECT, suppressing WHERE/ORDER BY pushdown.

### Open Bugs (re-opened 2026-05-11)

- [X] **6.32** DiagTxn savepoint-rollback hang — closed 2026-05-12 as no-longer-reproduces (likely fixed in-passing by 6.10/6.11 OP_Savepoint work + 6.16 VdbeMakeReady zero-init).

---

## Phase 7 — Parser

- [X] **7.1.1** Schema initialisation (prepare.c) + ATTACH reload.
- [X] **7.1.2** sqlite3NestedParse full driver.
- [X] **7.1.8** ATTACH / DETACH (attach.c).
- [X] **7.1.9** ALTER TABLE (alter.c) — all five entry points + nine SQL helpers.
- [X] **7.4b** TestBytecodeParity gate landed; sub-tasks 7.4b.1..7.4b.6 closed.
- [X] **7.4c** TestVdbeTrace differential opcode-trace gate.
- [X] **7.4d** WITHOUT ROWID runtime corruption — closed by 10.1.bug.16.
- [X] **7.4e** Bare-bareword INSERT → no-such-column error wired in resolver.

---

## Phase 8 — Public API

Public-API gap analysis: `../sqlite3/src/sqlite.h.in` exports
~238 `sqlite3_*` symbols; the Pascal port currently exposes ~156.
Windows-only entry points (`sqlite3_win32_*`) and pure typedefs are excluded.

- [X] **8.4.1** sqlite3_test_control full varargs coverage (overload-based dispatcher; PRNG_*, FK_NO_ACTION, OPTIMIZATIONS, GETOPT, PENDING_BYTE, ASSERT/ALWAYS, LOCALTIME_FAULT, INTERNAL_FUNCTIONS, NEVER_CORRUPT, EXTRA_SCHEMA_CHECKS, ONCE_RESET_THRESHOLD, SORTER_MMAP, BYTEORDER, ISINIT, TRACEFLAGS, JSON_SELFCHECK).
- [X] **8.2.1** sqlite3VdbeScanStatus + ScanStatusRange + ScanStatusCounters ported (vdbeaux.c:1186..1274); sqlite3_stmt_scanstatus_v2 reader covers NLOOP/NVISIT/EST/NAME/EXPLAIN/SELECTID/PARENTID. NCYCLE landed in 10.1.39.d.
- [X] **8.1.1** sqlite3_config / sqlite3_db_config full varargs coverage (overload-based; LOOKASIDE, LOG, PAGECACHE, MMAP_SIZE/MEMDB_MAXSIZE, PMASZ; db-config typed entry points _text/_lookaside/_int cover MAINDBNAME, LOOKASIDE, FP_DIGITS, flag-toggle ops).
- [X] **8.9.2** Carray / shared-cache / misc (sqlite3_carray_bind).
- [X] **8.x** unixCurrentTimeInt64; VFS iVersion bumped 1→2.
- [X] **8.10** Public-API sample-program gate (DiagSampleProg 6 PASS / 0 FAIL).
- [X] **8.x.colneed** sqlite3_collation_needed callback fires.
- [X] **8.x.memused** db^.pnBytesFreed dry-run accounting honoured.

---

## Phase 9 — Acceptance: differential + fuzz

Each 9.x lands a self-contained gate.  All four use the same C oracle:
`libsqlite3.so` from `../sqlite3/` (already built by `src/tests/build.sh`).
Pascal output → C output diff is the only pass criterion; any deviation
is a port bug (see top of file).  All gates must run unattended under
`src/tests/build.sh` and exit non-zero on first divergence so CI catches
regressions without human triage.

### 9.1 `TestSQLCorpus.pas` — full SQL corpus differential

- [X] **9.1.1** Corpus inventory.  Enumerate every `.sql` referenced by
  existing Diag*/Test* gates (TestSQLCorpus shares the source files —
  do not copy).  Land `src/tests/corpus/MANIFEST.txt` listing each
  file with a one-line tag (`ddl`, `dml`, `dql`, `pragma`, `txn`,
  `trigger`, `view`, `cte`, `window`, `json`, `alter`, `vacuum`).
  Cross-reference against the 1026-statement TestExplainParity input
  so nothing already covered is duplicated.

- [X] **9.1.2** Oracle runner helper.  `src/tests/CorpusOracle.pas`:
  given a `.sql` path and an empty workdir, runs the C reference via
  `libsqlite3.so` (in-process, not the `sqlite3` shell — avoid Phase
  10 dependency) and captures `(stdout, stderr, rc, db-blob)`.
  Wire the same plumbing for the Pascal port via passqlite3.

- [~] **9.1.3** `TestSQLCorpus.pas` skeleton — iterate MANIFEST, run both oracles, byte-compare all four channels; first diverging file prints summary and exits non-zero. Gate: `bin/TestSQLCorpus` rc=0. Skeleton landed 2026-05-12; full coverage delivered by 9.1.3.followup.

- [X] **9.1.3.followup** Full MANIFEST coverage via `SQLLiteralExtractor.pas`; 51 tier-1+2 entries, 2259 scripts; 52 divergences cataloged to `DIVERGENCES.md`. Archive.

- [X] **9.1.4** Determinism scrub — `ApplyHeaderMask` zeros 4 verified byte ranges (24..27, 56..59, 92..95, 96..99); see `src/tests/corpus/MASK.md`. Cumulative diverge 52 → 77. Archive.

- Triage of `DIVERGENCES.md` clusters (~7 root causes; archive has full details):
  - [X] **9.1.divbug.1** RELEASE-without-SAVEPOINT errmsg (44 sites) — OP_Savepoint not-found arm formats via sqlite3VdbeError (vdbe.c:3902).
  - [X] **9.1.divbug.2** PRAGMA mmap_size / journal_mode output shape (3 sites) — pragma.c:951..978 / 734..771.
  - [X] **9.1.divbug.3** DROP INDEX errmsg truncation (build.c:4614).
  - [X] **9.1.divbug.4..8** Five sites, single root cause: `sqlite3WritableSchema` mask bit was `0x20` (SQLITE_CacheSpill) instead of `0x01` (SQLITE_WriteSchema, sqliteInt.h:1829). Fix: codegen.pas:36421 + shell.c.in:2964 toggle.

- [X] **9.1.5** Corpus status tags landed in `src/tests/corpus/STATUS.txt` (`pas-strict`/`pas-soft`/`pas-skip` with cite); strict gate fires `Halt(1)` on any pas-strict divergence. Current: 35 pas-strict / 0 diverge.

- [X] **9.1.6** Coverage check — `bin/TestSQLCorpus --coverage` + `gVdbeOpCoverage[]`. Snapshot: 145 hot / 47 catalogued in `src/tests/corpus/COVERAGE_GAPS.md` / 0 real cold. Archive.

### 9.2 `TestReferenceVectors.pas` — canonical `.db` snapshots

- [X] **9.2.1** Vector inventory — 9 new `.sql`+`.db` pairs under `src/tests/vectors/` (autovacuum, incrvacuum, utf16, withoutrowid, generated-column, triggers, view-cte, partial-index, wal); fts5+rtree `.sql`-only [SKIP]; legacy simple/multipage tagged [~] (3.45.x vintage, EQUIV_LIST in regen.sh). wal.db carries journal_mode=WAL in header bytes 18..19; .db-wal sidecar non-deterministic (random salt) and not committed.

- [~] **9.2.2** Read-only parity probe — `bin/TestVectorReadOnly` + per-vector `*.queries.sql` (11 vectors). Bucket-A FIXED in 9.2.divbug.A (btreeBeginTrans wrflag gate); the unioned pas-skip list now covers bucket-F (autovacuum/incrvacuum), bucket-G (utf16), bucket-H (withoutrowid), bucket-I (wal/multipage/generated-column round-trip drift) and bucket-J (triggers round-trip crash) plus bucket-C/E for view-cte/partial-index — but those buckets affect 9.2.3/9.2.4 only.  RO probe today: gated=1 ok=1 diverged=0 skipped=10 rc=0; the actual fix lifted SQLITE_READONLY for every vector and the remaining skips are pre-existing non-RO bugs surfaced after bucket-A was lifted.

- [~] **9.2.3** Round-trip probe — `bin/TestVectorRoundTrip` + per-vector `<name>.mutate.sql` (11 mutators each exercising the vector's feature). Re-uses `CorpusOracle.ApplyHeaderMask`. Today (post-9.2.3.followup, cite-aware RT filter): gated=8 ok=8 diverged=0 skipped=3 rc=0.  Remaining skips: autovacuum (bucket-L, also bucket-B for schema-change), incrvacuum (bucket-L), utf16 (bucket-M, also bucket-K for RO).  Bucket-A umbrella lifted; bucket-I (4-vector RT cell-layout drift) closed; bucket-J (triggers RT crash) closed.

- [~] **9.2.4** Schema-change probe — `bin/TestVectorSchemaChange` + per-vector `<name>.schema.sql` (8 vectors). Opens RW so does NOT inherit bucket-A; surfaced 4 new buckets (B/C/D/E — see 9.2.divbug.* below). 9.2.divbug.C closed (view-cte rename arm), 9.2.divbug.E closed (partial-index RENAME COLUMN aColExpr pin), but both view-cte and partial-index still hit bucket-B at the trailing VACUUM so they stay pas-skip. Today: gated=1 ok=1 diverged=0 skipped=7 rc=0.

- [X] **9.2.5** Vector regen script — `src/tests/vectors/regen.sh` walks every `*.sql`, regenerates via C oracle, `cmp`s against committed blob.

- Triage of `src/tests/vectors/DIVERGENCES.md` clusters surfaced by
  9.2.2 / 9.2.3 / 9.2.4 (5 buckets, each a Pascal-only port bug
  bisectable against the C oracle — skip-and-cite per the corpus
  contract; mirrors the `9.1.divbug.*` pattern):
  - [X] **9.2.divbug.A** RO-open trips `SQLITE_READONLY` — `btreeBeginTrans` missing `wrflag<>0` conjunct (btree.c:3622). Memory: `feedback_btree_readonly_wrflag_gate`. Lifting this umbrella surfaced buckets F/G/H/I/J. Archive.
  - [X] **9.2.divbug.F** PRAGMA auto_vacuum returns 0 on RO-open — `sqlite3Pragma` stubbed auto_vacuum as constant `OP_Integer 0`; fix calls `sqlite3BtreeGetAutoVacuum(pBt)` per pragma.c:801. Archive.
  - [X] **9.2.divbug.G** PRAGMA encoding garbled on UTF-16 RO — two causes: encoding arm hardwired 'UTF-8'; OP_String8 mis-tagged literal bytes. Fix per vdbe.c:1419..1436. Archive.
  - [X] **9.2.divbug.H** WITHOUT ROWID count(*) fast path → CORRUPT — codegen missing P4_KEYINFO on the PK index cursor (select.c:8793..8814). Archive.
  - [X] **9.2.divbug.I** Round-trip cell-layout drift (4 sites: wal/multipage/generated-column/triggers) — TWO bugs: (1) generated-column STORED expr referencing IPK column read SoftNull slot, fix aliases `iColumn==iPKey` to rowid reg (codegen.pas:5689, expr.c:5026..5074); (2) `printf('%.*c',N,'X')` ignored precision-as-repeat-count, fix in printf.pas:1255 + codegen.pas:50334 (printf.c:769..790). Archive.
  - [X] **9.2.divbug.J** Round-trip trigger-fire EAV — `sqlite3VdbeClearObject` released aMem/aVar/pVList/pFree on sub-vdbes still in VDBE_INIT_STATE (raw-malloc garbage). Gate on `eVdbeState != VDBE_INIT_STATE` per vdbeaux.c:3747..3751. Archive.
  - [X] **9.2.divbug.B** Bare `VACUUM;` `EAccessViolation` — root cause was `sqlite3_config` writing the address of a stack parameter slot into `GlobalConfig.xLog`, plus three `SQLITE_OMIT_AUTOVACUUM`-stubbed btree arms (`btreeCreateTable` root relocation, `allocateBtreePage` ptrmap-page skip, `sqlite3BtreeInsert` PTRMAP_OVERFLOW1).
  - [X] **9.2.divbug.C** ALTER TABLE RENAME on VIEW-dependent table → EAV — `sqlite3CreateView` reduced pSelect under IN_RENAME_OBJECT; resolver wrote past EP_TokenOnly/EP_Reduced allocations.
  - [X] **9.2.divbug.D** CREATE INDEX on WITHOUT ROWID byte-different — `sqlite3CreateIndex` missing pPk arm (build.c:4278..4292) that copies PK columns into index-key suffix. Archive.
  - [X] **9.2.divbug.E** RENAME COLUMN on partial-index byte-different — missing IN_RENAME_OBJECT arm pinning `pIndex^.aColExpr` (build.c:4209, alter.c:1639). Archive.
  - [X] **9.2.divbug.K** UTF-16 `hex()` byte-swapped — `sqlite3_result_text*`/`_blob*` skipped `sqlite3VdbeChangeEncoding(pOut, pCtx->enc)` from `setResultStrOrError` (vdbeapi.c:387..427).
  - [X] **9.2.divbug.L** Auto-vacuum round-trip page-count drift — fixed `finalDbSize` (exact `ptrmapPageno` walk + `PTRMAP_ISPAGE` guard, btree.c:4135) and ported the missing `PRAGMA incremental_vacuum` codegen arm (pragma.c:854).
  - [X] **9.2.divbug.L.1** Port `incrVacuumStep` (btree.c:4034..4128) + prerequisite ptrmap stubs (`ptrmapPageno`/`Put`/`Get`, `setChildPtrmaps`). Wired into `sqlite3BtreeIncrVacuum`. Archive.
  - [X] **9.2.divbug.L.2** Port `relocatePage` + `modifyPagePointer` (btree.c:3876..4012). Archive.
  - [X] **9.2.divbug.L.3** Wire `autoVacuumCommit` body (btree.c:4194..4277) + CommitPhaseOne caller. incrvacuum.db now truncates freelist correctly; autovacuum.db still drifts on page-cleanup hygiene (bucket-L stays open on narrowed symptom). Archive.
  - [X] **9.2.divbug.M** ~~UTF-16 INSERT raw-UTF-8~~ CLOSED — subsumed by divbug.K (commit 6fd9ec2). Re-filed residual as divbug.N. Archive.
  - [X] **9.2.divbug.N** ~~Freeblock zeroing~~ CLOSED — audit artefact, not a defect. Distro libsqlite3 has SECURE_DELETE; harness needs `LD_LIBRARY_PATH=src`. After fix: gated=9 ok=9 diverged=0 skipped=2. Archive.

- [X] **9.2.3.followup** Round-trip parser cite-aware — only RT-relevant bucket cites trigger skips. 3 vectors un-masked (partial-index, view-cte, withoutrowid); 3 RT-only divergences triaged into buckets L and M.

- [X] **9.1.6.followup** Categorize 47 cold opcodes — split: 45 (a)-gated + 2 (b)-drivable + 4 newly-discovered real-cold all closed. Coverage drivers 14 → 18. Final: 147 hot / 45 cold-allow / 0 cold-real. Archive.

### 9.3 `TestFuzzDiff.pas` — differential fuzzer

- [X] **9.3.1** In-process harness — `bin/TestFuzzDiff <input.dbsqlfuzz>` 1:1 ports `fuzzcheck.c:decodeDatabase` (hex/`[NNNN]`/`\n--\n` frame). Four-channel diff via `CorpusOracle` + `ApplyHeaderMask`. Exit codes: 0/1/2/3. Smoke gate PASS. Archive.

- [X] **9.3.2** Seed corpus import — 8 seeds (`fuzzdata1..8.db`, ~62 MiB) imported to `src/tests/fuzz/seeds/`.

AFL wiring and downstream coverage-guided fuzzing work moved to
**Phase 13** (post-acceptance, parallel with Phase 12).  9.3.1 and
9.3.2 (in-process harness + seed corpus) remain the Phase-9
acceptance gate for this section.

### 9.4 SQLite Tcl test suite as alternate target

> Reorganised 2026-05-13: each umbrella bullet (9.4.1 .. 9.4.5) is
> immediately followed by its decomposed sub-arms; trailing
> `9.4.divbug.N` cluster bullets sit at the end in numeric order
> (matching `src/tests/tcl/DIVERGENCES.md`).
>
> **Timing & timeout rules (read before launching a run — 2026-05-16).**
> The driver applies a **20 s per-test watchdog**; the full MANIFEST
> (~959 entries) takes ~25 min unsharded and will be killed by any
> 20-min outer wall-clock (CI, `timeout`, agent harnesses).  Always
> shard 4-way — but **run the shards sequentially, never in parallel**:
> concurrent shards OOM-kill each other (silent partial results) due to
> stacked page caches + per-shard `libpassqlite3tcl.so` + tclsh
> footprints on a typical workstation.  Sequential 4-shard cost is
> ~25–60 min wall-clock.  See `README.md` → "Upstream Tcl test suite"
> for the exact command.  The same rule applies to running multiple
> `bin/Test*` binaries — `run_regression.sh` is already sequential;
> keep manual invocations the same way.  Three test files currently exceed the
> watchdog and **burn the entire shard-2 budget** if left in:
> `pragma4.test`, `printf.test`, `securedel.test` (tracked as
> `9.4.divbug.86`; sibling `.84` covers `select4.test` /
> `writecrash.test` / `securedel2.test`).  Until those are fixed or
> moved to `src/tests/tcl/SKIP.md`, shard 2 will not complete under
> 25 min — accept the partial result or skip them.  Most `FAIL` lines
> in shard logs are `pas-soft` and already cited in `STATUS.txt`; the
> only signal that matters is `REGRESSION (pas-strict FAIL): <path>`
> from `src/tests/tcl/check_status_regression.sh`.

- [X] **9.4.1** Inventory.  Walk `../sqlite3/test/*.test` and tag each
  file `tcl-feature` (uses only public API — candidate), `tcl-internal`
  (touches `sqlite3_test_control` / private symbols — skip), or
  `tcl-perf` (defer to Phase 11).  Land `src/tests/tcl/MANIFEST.txt`.
  - [X] **9.4.1.a** Inventory script — `src/tests/tcl/inventory.sh`
    walks `../sqlite3/test/*.test`, greps each file for
    `sqlite3_test_control` / `db_test_init` / `register_dbstat_vtab`
    /etc. (full tag list: tcl-internal markers, tcl-perf markers),
    emits `src/tests/tcl/MANIFEST.txt` one line per file:
    `<tag>\t<path>`.  Snapshot: 946 tcl-feature / 225 tcl-internal /
    17 tcl-perf (total 1188).

- [~] **9.4.2** Tcl binding shim.  Reuse / port the minimum of
  `../sqlite3/src/tclsqlite.c` (~6000 C lines total, but only a
  small subset is needed) so the upstream `interp` can attach to
  passqlite3 via the same `sqlite3` Tcl command.  Realistic complexity:
  **M** for the minimal `sqlite3 db1 :memory:` + `db eval` + `db close`
  trio that unblocks ~80% of `tcl-feature`; **L** if `db function` /
  `db trace` / `db authorizer` callbacks also need wiring (many
  feature tests use them).  Pre-requisite: a working
  FPC↔Tcl bridge (likely `tcl.pp` from fpc-extras or a hand-rolled
  cdecl binding to libtcl).  Sub-step before any porting: port
  `../sqlite3/test/tester.tcl` dependencies — it's the common harness
  every `.test` file loads via `source $testdir/tester.tcl`, and it
  pulls in `do_test` / `do_execsql_test` / `expected` / etc.  Without
  tester.tcl no `.test` file runs.
  - [X] **9.4.2.0** Plan doc — `src/tests/tcl/PLAN.md` summarises
    the FPC↔Tcl bridge approach, list of Tcl C ABI symbols needed
    (Tcl_CreateInterp, Tcl_Eval, Tcl_CreateObjCommand, Tcl_GetStringResult,
    Tcl_DeleteInterp, Tcl_NewStringObj, Tcl_SetObjResult, Tcl_GetString,
    Tcl_ListObjAppendElement, Tcl_NewListObj, Tcl_PkgProvide,
    Tcl_FindExecutable), and the staged plan 9.4.2.a..9.4.2.g.
  - [X] **9.4.2.a** Bridge unit — `src/tests/tcl/PasTclBridge.pas`
    with cdecl externs for the symbols listed in 9.4.2.0 PLAN
    (link via `-k-ltcl8.6` or `-k-ltcl`).  Smoke gate
    `src/tests/TestTclBridgeSmoke.pas` creates a Tcl interp,
    evals `expr 2+2`, asserts result == "4", deletes interp.
    C ref: `tclsqlite.c:4276` (Tclsqlite3_Init shape) — this task
    is only the bare bridge, no sqlite3 command yet.
  - [X] **9.4.2.b** `Sqlite3_Init` exporter — minimal port of
    `tclsqlite.c:Sqlite3_Init` (registers the `sqlite3` Tcl object
    command and calls `Tcl_PkgProvide`).  Body still routes through
    `DbMain` (constructor) and `DbObjCmd` (per-instance dispatcher),
    both of which were stubs at this stage that returned TCL_ERROR with
    "not implemented".  Built as `bin/libpassqlite3tcl.so` so
    `load ./bin/libpassqlite3tcl.so Sqlite3` works in tclsh.
    Smoke gate `bin/TestTclSqliteInit` confirms the load+package-require
    cycle.
  - [X] **9.4.2.c** `sqlite3 db1 :memory:` constructor — implemented
    `DbMain` arm that calls `sqlite3_open_v2` against passqlite3 and
    stores the resulting handle on a `SqliteDb*`-equivalent struct
    attached to the Tcl object command.  `db close` arm of DbObjCmd
    (only).  Smoke gate `bin/TestTclSqliteOpen` evals
    `sqlite3 db1 :memory:; db1 close` and asserts no error.
    C ref: `tclsqlite.c:DbMain` (4253..), `DbObjCmd close` (2480..).
  - [X] **9.4.2.d** `db eval $sql` — minimum arm of DbObjCmd that
    prepares/steps/finalises and returns rows as a flat Tcl list
    (no column-name binding, no var-bind callback, no script-body
    arg).  Smoke: `sqlite3 db1 :memory:; db1 eval {create table t(x);
    insert into t values (1),(2),(3); select x from t}` returns
    `1 2 3`.  C ref: `tclsqlite.c:dbEvalStep` (1766..) +
    `DbObjCmd eval` arm (2700..).
  - [X] **9.4.2.e** `db version`, `db changes`, `db last_insert_rowid`,
    `db errorcode`, `db nullvalue ?value?` — trivial passthroughs to
    sqlite3_libversion / sqlite3_changes / sqlite3_last_insert_rowid /
    sqlite3_errcode plus the `zNull` field on SqliteDb.  Smoke gate
    `bin/TestTclSqliteMeta`.  C ref: respective arms of DbObjCmd.
  - [X] **9.4.2.f** `db function NAME ?-argcount N? proc` — registered
    a scalar UDF via sqlite3_create_function_v2 with a Tcl trampoline
    (DbSqlFunc).  Required by ~30% of tcl-feature tests including
    the simplest ones in tester.tcl bootstrap.  C ref:
    `tclsqlite.c:DbSqlFunc` (~1118) + `function` arm of DbObjCmd
    (~2730).
  - [~] **9.4.2.g** `tester_min.tcl` — `src/tests/tcl/tester_min.tcl`
    re-exports just `do_test`, `do_execsql_test`, `execsql`,
    `expected`, `set_test_counter`, `finalize_testing`, and the global
    `db` handle — enough to source a hand-picked simple `.test` file.
    Body adapted from `../sqlite3/test/tester.tcl:703..` and `941..`.
    Smoke gate `bin/TestTclTesterMin` sources tester_min.tcl + runs
    `do_test foo-1.0 {expr 1+1} 2`.  Remaining helpers tracked in
    9.4.2.g.1.
  - [X] **9.4.2.g.1** `ifcapable` — gates a test (file-level or
    block-level) on `SQLITE_OMIT_*` / `SQLITE_ENABLE_*` compile flags.
    Single biggest unlock — ~70% of tcl-feature tests open with
    `ifcapable !foreignkey { finish_test ; return }` or similar.
    Landed as an unconditional `uplevel 1 $code` stub matching our
    default build (all caps enabled); real `sqlite3_compileoption_used` /
    `sqlite3_compileoption_get` wiring deferred to 9.4.6.a.  Smoke gate
    extended in `TestTclTesterMin` (foo-4.0 verifies BODY runs even on
    a bogus EXPR).  C ref: `tester.tcl:1725..1739`.
  - [X] **9.4.2.g.2** `catchsql` + `do_catchsql_test` — runs SQL,
    captures `(rc, errmsg)` as a 2-list.  Unblocks every error-path
    test (~30% of total).  C ref: `tester.tcl:1460..1465`, `973..976`.
    Verbatim port; smoke gate in `TestTclTesterMin` (`catchsql
    {select 1+1}` -> `0 2`, `catchsql {select * from nosuchtable}`
    -> `1 {no such table: nosuchtable}`, `do_catchsql_test fail-1`
    PASS).
  - [X] **9.4.2.g.3** `finish_test` + `forcedelete` + `delete_file` —
    per-test teardown convention; tests source-include them at the
    end.  C ref: `tester.tcl:1234..1280`, `1696..1714`.  Landed:
    `finish_test` collapses to `catch {db close}` + `finalize_testing`
    (no test-VFS deregistration, no $argv extra-script loop, no
    ::SLAVE gate beyond the `info exists` skip); `delete_file` /
    `forcedelete` share `do_delete_file` with Linux fast-path (zero
    retries by default, overridable via TEST_FILE_RETRIES /
    TEST_FILE_RETRY_DELAY env vars).  Smoke gated by
    `bin/TestTclTesterMin` (in-proc forcedelete + missing-path
    delete_file) plus a sub-tclsh run that exercises finish_test ->
    finalize_testing -> exit 0.
  - [X] **9.4.2.g.4** `integrity_check` — wrapper that runs
    `PRAGMA integrity_check` and asserts "ok".  C ref:
    `tester.tcl:1674..1678` (verbatim port: `ifcapable integrityck`
    guard + `do_test NAME [list execsql {PRAGMA integrity_check} $db]
    {ok}`).  Smoke gated by `bin/TestTclTesterMin` ic-1 case (create
    table + insert + integrity_check; nTest+=1, nErr unchanged on
    healthy db).
  - [X] **9.4.2.g.5** `working_64bit_int` + `presql` + `omit_test` —
    capability/permutation helpers.  C ref: `tester.tcl:593..599`
    (`omit_test`), `tester.tcl:2334..2338` (`presql`), and the C-side
    build-cap probe in tclsqlite.c (`working_64bit_int`; no
    `proc working_64bit_int` exists in upstream tester.tcl — the
    probe is registered native and always returns 1 on x86_64).
    Ported as: `working_64bit_int` -> constant `return 1` (probe is
    always true on x86_64), `presql` -> verbatim catch around
    `::G(perm:presql)`, `omit_test` -> verbatim append to TC(omit_list).
    Smoke gated by `bin/TestTclTesterMin` step 9c (working_64bit_int=1,
    presql=[] when unset, omit_test myskip records
    `{myskip {reason text}}`).
  - [X] **9.4.2.g.6** `do_eqp_test` — EXPLAIN QUERY PLAN comparison;
    needs `db eval` 3-arg form (9.4.2.h) for row→list flattening.
    C ref: `tester.tcl:1064..1098`.
  - [X] **9.4.2.g.7** `do_test` glob/regexp/numeric-range forms
    + `do_realnum_test`.  Ported the upstream prefix-driven match
    dispatch (`/RE/`, `~/RE/`, `#A..B#`, `*GLOB*`, `~*GLOB*`, else
    exact compare) into tester_min.tcl's do_test, plus verbatim
    `realnum_normalize` / `do_realnum_test`.  Smoke gated by
    `bin/TestTclTesterMin` step 9d/9e (glob-1, re-1/re-2, num-1,
    exact-1, rn-1, all expected to PASS with nErr unchanged at 1).
    C ref: `tester.tcl:739..793`, `888..896`.
    `do_test_with_ansi_output` (tester.tcl:815..819) is a Windows-only
    slave-interp gate; pas-sqlite3 targets Linux so it remains
    deliberately unported.
  - [X] **9.4.2.g.8** `permutations.tcl` skip-shim — tester.tcl's
    permutation matrix re-runs each test under ~30 build-flag
    combinations.  For full-corpus first cut, land a stub that
    runs *only* the baseline permutation; full matrix gated under
    9.4.7.e.  C ref: `permutations.tcl:1..400`.
  - [X] **9.4.2.g.9** `do_malloc_test` ported verbatim into `tester_min.tcl` (malloc_common.tcl:416..538); drives the memdebug `sqlite3_memdebug_fail` / `install_malloc_faultsim` primitives.
  - [X] **9.4.2.g.10** `do_ioerr_test` + `run_ioerr_prep` ported verbatim into `tester_min.tcl` (tester.tcl:1890..2118); drives the 9.4.7.c counters.  Runs end-to-end (fault fires, engine recovers, terminates cleanly).
  - [X] **9.4.2.g.11** `crashsql` Tcl proc — verbatim port of
    `tester.tcl:1752..1840` into `tester_min.tcl` (Agent 6, 2026-05-16).
    Spawns a child `tclsh` that loads the pas library, registers the
    crash VFS (9.4.7.d), runs the supplied SQL under `-vfs crash`, and
    is killed by `_exit(-1)` inside `cfSync` once `iCrash` decrements
    to 0; parent catches `child process exited abnormally`, reopens db,
    integrity is preserved (verified end-to-end in driver via a
    hand-rolled manifest entry).  Followups:
    * **9.4.7.d.followup.1** flip the `ifcapable` shim to honour
      `crashtest` so the upstream `crash{,2..8,M}.test` files
      transition from "early-return PASS" to actually exercising the
      harness.  Held back here to avoid pulling unrelated divbug
      regressions into this agent's change-set.
    * **9.4.7.d.followup.2** WAL crash support (`xShm*` methods on
      `CrashFileVtab` are currently nil — sufficient for rollback-
      journal `crash.test`, insufficient for `walcrash*.test`).
    * **9.4.7.d.followup.3** `unixVfsObjFoo := unixVfsObj` in
      `passqlite3os.pas:2890..2891` clobbers a wrapper VFS's `pNext`
      when one is interleaved between unix and unix-none across an
      init/shutdown cycle.  Worked around in `crashEnableCmd` by
      forcing `sqlite3_initialize` before `sqlite3_vfs_register`, so
      no later open re-runs `sqlite3_os_init`; the upstream pattern
      should still be tightened (record-copy of an in-list singleton
      mutates its `pNext` to whatever the source's `pNext` currently
      points at).
  - [X] **9.4.2.g.12** `db_save_and_close` / `db_restore_and_reopen`
    + `forcecopy` — snapshot helpers for tests that mutate then
    revert.  C ref: `tester.tcl:1714..1760`.
  - [X] **9.4.2.g.13** `*_common.tcl` source-include shims —
    `malloc_common.tcl`, `lock_common.tcl`, `incrblob_common.tcl`,
    `wal_common.tcl`, `fts3_common.tcl`.  Each is a shared helper
    file sourced by tens of tests.  Audit each; copy verbatim where
    no internal hooks; SKIP-cite per file where they call
    `sqlite3_test_control` opcodes we haven't wired.
    Outcome: audited all 7 `../sqlite3/test/*_common.tcl` (no
    `incrblob_common.tcl` exists upstream).  Driver sets `::testdir`
    at `src/tests/tcl/`, so copies ARE needed.  Copied verbatim:
    `wal_common.tcl`, `fuzz_common.tcl` (pure Tcl, no internal
    hooks).  SKIP-cited: `malloc_common.tcl`, `lock_common.tcl`,
    `bc_common.tcl`, `fts3_common.tcl`, `pg_common.tcl`,
    `thread_common.tcl` (need testvfs / testfixture / sqlthread /
    sqlite3_memdebug_* / Pgtcl — unported).
  - [X] **9.4.2.g.14** `tester_min.tcl` config vars — added `AUTOVACUUM 0`, `TEMP_STORE 1`, `SQLITE_DEFAULT_SYNCHRONOUS 2`, `SQLITE_DEFAULT_WAL_SYNCHRONOUS 2`, `SQLITE_DEFAULT_FILE_FORMAT 4`, `MEMORY_MANAGEMENT 0` + a minimal `sqlite_options()` array, all derived from this port's actual build config.
  - [X] **9.4.2.h** `db eval` 3-arg form (`db eval $sql arrayName
    { script }`) — per-row callback with column-name `Tcl_TraceVar`
    binding into the named array.  Used by ~30% of tcl-feature tests.
    Also: typed-Obj marshalling for column values (Int via
    sqlite3_column_int64 → Tcl_NewWideIntObj; Real → Tcl_NewDoubleObj;
    Blob → Tcl_NewByteArrayObj).  C ref: `tclsqlite.c:dbEvalStep`
    (1766..) + 4-arg eval arm.
  - [X] **9.4.2.i** `db trace` / `db trace_v2` / `db profile` —
    callbacks fired on each prepared statement.  Many error-path
    tests diff against the trace stream.  C ref: `tclsqlite.c:737..833`
    (DbTraceV2Handler) + `2900..2970` (dispatch).
  - [X] **9.4.2.j** `db authorizer` — Tcl callback invoked by
    sqlite3_set_authorizer with 5-tuple action codes.  Engine port
    in 9.4.6.e.  C ref: `tclsqlite.c:984..1070` (auth_callback) +
    `2740..2780` (dispatch).
  - [X] **9.4.2.k** `db busy` + `db progress` + `db interrupt` —
    busy-handler / progress-callback / interrupt wiring.  C ref:
    `tclsqlite.c:681..737` (DbBusyHandler, DbProgressHandler) +
    `2810..2860` (dispatch).
  - [X] **9.4.2.l** `db update_hook` / `db commit_hook` /
    `db rollback_hook` / `db wal_hook` — change-notification
    callbacks.  C ref: `tclsqlite.c:834..980` (4 handlers) +
    `2980..3070` (dispatch).
  - [X] **9.4.2.m** `db collate` + `db collation_needed` — Tcl
    callback registered via sqlite3_create_collation_v2.  Engine
    port already exists (8.x.colneed in tasklist); Tcl shim needs
    DbCollateNeeded + per-collation trampoline.  C ref:
    `tclsqlite.c:1175..1240` + `3100..3140` (dispatch).
  - [X] **9.4.2.n** `db transaction { script }` — savepoint-nested
    transaction with rollback-on-error.  C ref:
    `tclsqlite.c:1308..1410` (DbTransPostCmd, NRE arm) +
    `3170..3240` (dispatch).
  - [X] **9.4.2.o** `db total_changes` / `db onecolumn` /
    `db exists` / `db status` / `db cache flush|size` /
    `db enable_load_extension` / `db config` / `db timeout` /
    `db copy` — the remaining ~10 trivial-passthrough arms.
    C ref: respective `tclsqlite.c` arms.
  - [X] **9.4.2.p** `db incrblob` — incremental blob I/O subcommand.
    Engine port in 9.4.6.g (sqlite3_blob_open/read/write/close).
    Tcl shim creates a child object command `dbX_blobN` with
    read/write/seek/tell/close methods.  C ref:
    `tclsqlite.c:2520..2645` (DbIncrblobHandler) +
    `3290..3330` (dispatch).
  - [X] **9.4.2.q** `db backup` / `db restore` — sqlite3_backup_*
    family (engine already ported under 10.1.43..45).  Tcl shim is
    a 1-arg form (`db backup file.db` / `db restore file.db`).
    C ref: `tclsqlite.c:3340..3410` + `3420..3470`.
  - [X] **9.4.2.r** `db serialize` / `db deserialize` —
    sqlite3_serialize / _deserialize.  Engine `_deserialize` already
    ported under 10.1.102; `_serialize` audit + Tcl shim.  C ref:
    `tclsqlite.c:3490..3550`.
  - [X] **9.4.2.s** `db function` enhancements: `-returntype`,
    `-directonly`, `-innocuous` flags + result-type routing (eType),
    full typed argv marshalling (blob branch + int/wideint split).
    NOTE: there is no aggregate UDF in `tclsqlite.c` — the `DB_FUNCTION`
    arm only ever calls `sqlite3_create_function(... tclSqlFunc,0,0)`;
    no `DbFuncStep`/`DbFuncFinal` exist.  Nothing C-faithful to port
    for an aggregate `db function` form.  C ref: `tclsqlite.c:1013..1163`
    (tclSqlFunc), `:3386..3460` (DB_FUNCTION arm).
  - [X] **9.4.2.s.1** `DbSqlFunc` script-body forms — the ported
    `tclSqlFunc` always dispatches the callback via `Tcl_EvalObjv`
    when argc>0, so a `db function` whose proc body is anything but
    a bare command name (e.g. `{apply {{x} ...}}` or a multi-word
    script) fails.  Port C's `useEvalObjv` decision + the
    list-copy / `Tcl_EvalObjEx` fallback path (`tclsqlite.c` in
    `tclSqlFunc`).  Surfaced by the 9.4.2.s agent.
  - [X] **9.4.2.t** `db nullvalue` follow-ups + `db errorcode`
    extended-code arm (sqlite3_extended_errcode).  Coupled with
    9.4.6.j.
  - [X] **9.4.2.u** `db preupdate_hook` (`-DSQLITE_ENABLE_PREUPDATE_HOOK`
    build only).  Used by ~10 tests.  Gate on env-var build flag in
    `build_tcl_lib.sh`.  C ref: `tclsqlite.c:880..980` (DbPreUpdateHook).
    Done: engine plumbing (`sqlite3VdbePreUpdateHook` + OP_Insert/
    OP_Delete call sites + 6 public `sqlite3_preupdate_*`) and the
    Tcl shim, both behind `{$ifdef SQLITE_ENABLE_PREUPDATE_HOOK}`;
    `PREUPDATE=1` env toggle in `build_tcl_lib.sh`.  Compiles flag
    on/off; NOT yet runtime-exercised — see 9.4.2.u.1.
  - [X] **9.4.2.u.1** Runtime-exercise the preupdate hook — ported `src/tests/tcl/preupdate.test` (subset of upstream `hook.test` hook-7.*; this SQLite version has no standalone preupdate.test).
  - [X] **9.4.2.v** `db unlock_notify` (`-DSQLITE_ENABLE_UNLOCK_NOTIFY`
    build only).  Engine port in 9.4.6.k.  Tcl shim is a 1-arg
    callback registration.  C ref: `tclsqlite.c:2820..2870`.
  - [X] **9.4.2.w** Bridge symbol-table audit — re-grep `tclsqlite.c`
    after 9.4.2.h..v all land; verify every `Tcl_*` symbol it calls
    has an extern in `PasTclBridge.pas`.  Close gaps.
    Audit result: no gaps — every `Tcl_*` symbol used by ported arms is
    declared with a `cdecl` signature matching the Tcl 8.6 C ABI
    (`int`-width length params correct for 8.6; varargs on
    `Tcl_AppendResult`; refcount macros bound via `Tcl_Db*RefCount`).
    Unported-arm symbols (NRE, channels-create, dict, GetVersion,
    InitStubs, etc.) correctly left undeclared.
  - [~] **9.4.2.x** NRE (Non-Recursive Eval) support — `db eval`
    with a script body and `db transaction` need
    `Tcl_NRCreateCommand` + `Tcl_NREvalObj` arms to interrupt
    cleanly across nested `vwait`.  Optional for first cut; many
    tests pass without it.  C ref: `tclsqlite.c:1888..1915`
    Done: command-dispatch NRE trampoline (`Tcl_NRCreateCommand` +
    `DbObjCmdNRE` + `DbUseNre` version probe) + the NRE externs in
    `PasTclBridge.pas`.  Non-NRE paths left intact.
  - [~] **9.4.2.x.1** NRE continuations — convert `DbEvalArm` and
    `DbTransactionArm` script bodies from the recursive
    `Tcl_EvalObjEx` path to genuine `Tcl_NRAddCallback` /
    `Tcl_NREvalObj` continuations (`DbEvalNextCmd` / `DbTransPostCmd`
    as `TTclNRPostProc`s).  C ref: `tclsqlite.c` `DbEvalNextCmd` /
    `DbTransPostCmd`.
    Done (transaction half): added `DbTransPostCmdNRE` matching the
    `TTclNRPostProc` shape (tclsqlite.c:1308..1348) and wired
    `DbTransactionArm` to take the NRE branch (tclsqlite.c:4002..4004)
    when `DbUseNre` is true.  Recursive `Tcl_EvalObjEx` path retained as
    the `!DbUseNre` fallback (tclsqlite.c:4005..4006).
    Eval half left as sub-arms because the Pascal `DbEvalArm` differs
    structurally from upstream and cannot be wholesale-converted (per
    9.4.2.x.1's "surface the gap" guidance):
    - [X] **9.4.2.x.1.a** Port `SqlPreparedStmt` cache +
      `DbPrepareAndBind` / `DbReleaseStmt` / `FlushStmtCache`
      (tclsqlite.c:1356..1614).  Landed:
      `src/tests/tcl/PasTclSqlite.pas:84..98` (TSqlPreparedStmt record),
      `:710..839` (DbPrepareAndBind, DbReleaseStmt, DbFreeStmt,
      FlushStmtCache).  Cache nodes are Tcl_Alloc'd with apParm
      trailing the record (matches upstream `&pPreStmt[1]`); text-only
      bind path (upstream's typed-binding shortcuts elided — same
      coverage as the prior DbEvalArm).
    - [X] **9.4.2.x.1.b** Port `AddDatabaseRef` / `DelDatabaseRef`
      (tclsqlite.c:601..666) — landed at
      `src/tests/tcl/PasTclSqlite.pas:680..708`.  `nRef:=1` set at
      construction (`:3920`); `DbDeleteCmd` is now a thin wrapper
      (`:530..538`) that just decrements the ref.  The teardown body
      (sqlite3_close_v2, hook script frees, collation chain) moved
      into `DelDatabaseRef`.
    - [X] **9.4.2.x.1.c** Introduce a Pascal `TDbEvalContext` record
      mirroring tclsqlite.c:1626..1636 and split the existing
      `DbEvalArm` row loop into `DbEvalInit` / `DbEvalStep` /
      `DbEvalRowInfo` / `DbEvalFinalize` / `DbEvalColumnValueCtx`
      (tclsqlite.c:1669..1876).  Landed at
      `src/tests/tcl/PasTclSqlite.pas:868..1064`.  Behaviour-identical
      to the upstream split; the existing `DbEvalArm` flat-list
      path (objc==3) stays on its direct prepare/step loop per the
      task brief.
    - [X] **9.4.2.x.1.d** Implement `DbEvalNextCmd: TTclNRPostProc`
      (tclsqlite.c:1915..2005) and wire the 3/4/5-arg script-body
      branch of `DbEvalArm` (tclsqlite.c:3340..3360) through
      `Tcl_NRAddCallback` + `Tcl_NREvalObj`.  Landed at
      `src/tests/tcl/PasTclSqlite.pas:1066..1196`
      (DbEvalNextCmd + DbEvalScriptArm).  `DbEvalArm` dispatches
      objc>=4 into DbEvalScriptArm (which Tcl_Alloc's the
      DbEvalContext, runs DbEvalInit, then enters DbEvalNextCmd via
      the cd2[2] hop matching upstream's `cd2[0]=p; cd2[1]=pScript`
      pattern).  Non-NRE Tcls fall back to the recursive
      `Tcl_EvalObjEx` path inside DbEvalNextCmd.  The 2-arg flat
      list form (tclsqlite.c:3320..3338) keeps its direct loop.
      Smoke gates green: TestTclSqliteOpen / Function / Eval /
      TclTesterMin all pass; `TclTestDriver --limit 10` shows the
      same 5-pass/5-fail pattern as pre-landing (no regression).

- [~] **9.4.3** Driver `src/tests/TclTestDriver.pas`.  Spawns
  `tclsh` against each manifest entry with the port's shim
  preloaded; collects pass/fail/skip per test.  Output format:
  one line per test (`PASS|FAIL|SKIP <path> <assertions> <duration>`),
  matching upstream's `make test` log shape.  The gate is "every
  `tcl-feature` test exits 0 or matches the upstream skip list".
  Per the skip-and-cite contract from 9.1.3.followup, divergences
  surface into `src/tests/tcl/DIVERGENCES.md` rather than blocking
  the driver — each cluster becomes a `9.4.divbug.N` follow-up
  bullet for triage.
  - [X] **9.4.3.a** Driver skeleton `src/tests/TclTestDriver.pas` —
    reads `src/tests/tcl/MANIFEST.txt`, for each `tcl-feature` entry
    forks `tclsh` with `-c "load .../libpassqlite3tcl.so Sqlite3;
    source .../tester_min.tcl; source <path>"`, captures rc + timing,
    emits `PASS|FAIL|SKIP <path> <assertions> <duration>` to stdout.
    `bin/TclTestDriver` lands (no gate yet — gate comes in 9.4.4.a).
  - [X] **9.4.3.b** Fix the driver polling race — `TclTestDriver`
    under-reports per-test duration (noted in the 9.4.4.b sweep,
    which fell back to direct `tclsh + tester_min` invocations with
    a `timeout` wrapper).  Audit the child-process wait/poll loop in
    `TclTestDriver.pas`; replace the busy-poll with a blocking
    `WaitOnExit` + a wall-clock delta captured around it.  Also
    rebuild `bin/TclTestDriver` (the binary was stale after the
    9.4.divbug.3 `:memory:`→`./test.db` edit landed in the source).
  - [X] **9.4.3.c** Per-test `testdir` wiring — confirm the driver
    sets `::testdir` to `src/tests/tcl` so the `*_common.tcl` shims
    copied under 9.4.2.g.13 (`wal_common.tcl`, `fuzz_common.tcl`)
    resolve, and upstream `source $testdir/<x>_common.tcl` lines
    find them.  Smoke a test that source-includes one.

- [~] **9.4.4** Skip-list curation.  Tests that depend on
  `sqlite3_test_control`, `PRAGMA legacy_*`, or other internal
  knobs land in `src/tests/tcl/SKIP.md` with a citation to the
  Phase 6/7/8 bullet that gates them.  Empty skip-list is the
  long-term goal; closed bullets prune entries here.
  - [X] **9.4.4.a** First 10-test sweep — 10 simplest tcl-feature
    tests run via TclTestDriver, classified into PASS / FAIL /
    SKIP; populated `src/tests/tcl/SKIP.md` (with citations to existing
    Phase-6/7/8 bullets) and `src/tests/tcl/DIVERGENCES.md` (new
    `9.4.divbug.*` bucket per cluster).  Triage convention bootstrapped.
  - [X] **9.4.4.b** Re-ran 10-test sweep after g.1..g.5 + g.7 +
    divbug.6 landed: PASS 2 / FAIL 5 / CRASH 3.  cast.test +
    reindex.test promoted to PASS (shim-skip via `ifcapable !cast`
    / `!reindex` running BODY); pruned from SKIP.md.  Surfaced
    four new divbug buckets: **9.4.divbug.7** insert.test hang,
    **9.4.divbug.8** index-3.3 crash, **9.4.divbug.9** lastinsert
    rowid-after-INSERT crash, **9.4.divbug.10** boundary1.test
    SELECT returning empty for large rowid ranges.  delete /
    update / boundary1 now run further (helpers landed) but still
    fail on existing divbug.2/3/4 + missing `db one` / `reset_db`
    sub-commands.
  - [X] **9.4.4.b.2** Re-sweep the same 10 tests after the
    2026-05-14 landing wave: divbug.1/3/4/7/8/9/10 all FIXED, plus
    14 bridge arms (`db eval` 3-arg, function/typed-argv,
    trace/profile, authorizer, busy/progress/interrupt, the four
    change hooks, collate, transaction, the trivial-passthrough
    arms incl. `db one`/`onecolumn`/`exists`, `db status`,
    `reset_db`).  Expectation: most of the 10 flip to PASS; record
    the new PASS/FAIL/CRASH split, prune SKIP.md entries that the
    landed arms unblocked, and open any genuinely new
    `9.4.divbug.N`.  Prerequisite for 9.4.4.c being meaningful.
    Use direct `tclsh + tester_min` with a `timeout` wrapper until
    9.4.3.b fixes the driver.
  - [X] **9.4.4.c** Broaden sweep to first 50 tcl-feature tests
    (ranked by filesize / probable simplicity).  Continue
    skip-and-cite convention.  Triage new divbug.* clusters.
    Do this only after 9.4.4.b.2 confirms the 10-test baseline.
  - [X] **9.4.4.d** Broaden sweep to first 100 tcl-feature tests — **72 PASS / 28 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 100`).
  - [X] **9.4.4.e** Broaden sweep to 250 tests (~25% of corpus) — **147 PASS / 103 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 250`, 138 s).
  - [X] **9.4.4.f** Broaden sweep to 500 tests — **280 PASS / 220 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 500`, 149.2 s).
  - [X] **9.4.4.g** Full tcl-feature sweep — **593 PASS / 366 FAIL / 0 SKIP** across 959 tests in 334.8 s (`bin/TclTestDriver` against MANIFEST.txt; three 20 s timeouts on `select4.test`, `writecrash.test`, `securedel2.test` counted as FAIL and bucketed under 9.4.divbug.84).  Cites: 6b834c8, 705d27e.
  - [X] **9.4.4.h** tcl-internal re-evaluation — re-walked the 225
    `tcl-internal` rows against the trimmed trigger set (dropped
    `register_dbstat_vtab` / `db_save` / `db_save_and_close`, now
    ported via 9.4.6.b + 9.4.6.q.2).  Promoted **12** tests to
    `tcl-feature` (cksumvfs, corruptF, crash7, fts3conf,
    incrcorrupt, interrupt2, io, pendingrace, snapshot_fault,
    spellfix, stat, walcrash3).  10-test smoke probe under
    `bin/TclTestDriver`: 5 PASS / 5 FAIL / 0 CRASH (FAILs
    are deeper-layer divergences, not the missing-symbol short-
    circuits that earned the original `tcl-internal` tag).
    Updated `inventory.sh` INTERNAL_PATTERN to match.  Manifest
    totals: 947→959 tcl-feature, 225→213 tcl-internal, 17 tcl-perf.

- [X] **9.4.5** Linux-only nightly.  Cites: 3b0b96a.
  - [X] **9.4.5.a** CI config — `.github/workflows/tcl-nightly.yml` runs `bin/TclTestDriver --gate strict` against full MANIFEST, exits non-zero on any pas-strict regression vs `STATUS.txt`.
  - [X] **9.4.5.b** Sharding — driver flag `--shard I/N` (TclTestDriver.pas) slices the filtered manifest into N contiguous chunks; 4 parallel shard jobs in `tcl-nightly.yml`.
  - [X] **9.4.5.c** Failure-report artefact — per-shard `--fail-log-dir` captures `<basename>.{out,err}` for every FAIL; uploaded as `tcl-failure-logs-shard-N` artefact; aggregate job concatenates + diffs against STATUS.txt via `src/tests/tcl/check_status_regression.sh`.

- [~] **9.4.6** Test-only public-API export delta.  Many `.test`
  files call into the C ABI beyond the "publicly documented" subset.
  Each bullet here adds the engine port + Tcl shim required by some
  number of `.test` files.  Audit current `src/*.pas` first — many
  of these already exist with partial coverage.
  - [X] **9.4.6.a** `sqlite3_compileoption_used` /
    `sqlite3_compileoption_get` — backend for `ifcapable` (9.4.2.g.1).
    Probably already partly exported; audit + ensure every
    `SQLITE_OMIT_*` / `SQLITE_ENABLE_*` compile-time symbol on the
    Pascal side reports correctly via the runtime API.  C ref:
    `../sqlite3/src/main.c:sqlite3_compileoption_*`.
  - [X] **9.4.6.b** `register_dbstat_vtab` — Tcl-side registration
    of the dbstat eponymous vtab.  Engine likely already ported
    under 10.1.7x.  Add Tcl bridge call.  C ref:
    `../sqlite3/src/dbstat.c`.
  - [X] **9.4.6.c** `sqlite3_db_status` / `sqlite3_stmt_status` /
    `sqlite3_status64` audit — extend export coverage so every
    `_STATUS_*` opcode used by tests works.  C ref:
    `../sqlite3/src/status.c`.
  - [X] **9.4.6.d** `sqlite3_table_column_metadata` — used by ~20
    tests + by `.expert`.  Audit if already exported.  C ref:
    `../sqlite3/src/main.c:sqlite3_table_column_metadata`.
  - [X] **9.4.6.e** `sqlite3_set_authorizer` — engine port +
    pairs with 9.4.2.j Tcl shim.  C ref:
    `../sqlite3/src/auth.c` (entire file, ~250 lines).
  - [X] **9.4.6.f** `sqlite3_create_collation` /
    `sqlite3_create_collation_v2` — engine surface audit
    (`8.x.colneed` already partial).  Pairs with 9.4.2.m.
  - [X] **9.4.6.g** `sqlite3_blob_open` / `_read` / `_write` /
    `_close` / `_bytes` / `_reopen` — incrblob engine port.
    Substantial: ~800 lines from `../sqlite3/src/vdbeblob.c`.
    Pairs with 9.4.2.p.
  - [X] **9.4.6.h** `sqlite3_soft_heap_limit64` /
    `sqlite3_hard_heap_limit64` / `sqlite3_db_release_memory` /
    `sqlite3_release_memory` — memory-pressure entry points.
    C ref: `../sqlite3/src/malloc.c`.
  - [X] **9.4.6.i** `sqlite3_user_data` / `sqlite3_aggregate_context`
    / `sqlite3_get_auxdata` / `sqlite3_set_auxdata` — UDF helpers.
    Many already exported; audit + close gaps.  C ref:
    `../sqlite3/src/vdbeapi.c`.
  - [X] **9.4.6.j** `sqlite3_extended_result_codes` /
    `sqlite3_extended_errcode` — extended-rc plumbing audit; some
    error tests assert on the extended (3-byte) form.  C ref:
    `../sqlite3/src/main.c:sqlite3_extended_*`.
  - [X] **9.4.6.k** `sqlite3_unlock_notify` — engine port.
    Gated on `SQLITE_ENABLE_UNLOCK_NOTIFY` build flag.  Pairs
    with 9.4.2.v.  C ref: `../sqlite3/src/notify.c`.
  - [~] **9.4.6.l** Test-only modules — landed as
    `src/tests/tcl/testmodules/` unit per file.
    Done: `register_tcl_module` (test_tclvar.c → `TestModuleTclvar.pas`),
    `Md5_Register` + md5/md5file Tcl cmds (test_md5.c →
    `TestModuleMd5.pas`).  `register_wholenumber_module` already
    done in 10.1.69.  Remaining sub-tasks below.
    - [X] **9.4.6.l.1** `register_echo_module` — 1:1 port of `test8.c` into `src/tests/tcl/testmodules/TestModuleEcho.pas` (full read/write proxy vtab: xCreate/xConnect/xBestIndex/xFilter/xUpdate/xFindFunction/xRename/savepoints; registers `echo` + `echo_v2`).
    - [X] **9.4.6.l.4** `registerTestFunction` — ported `test_func.c` scalar/aggregate test UDFs + `autoinstall_test_functions` into `src/tests/tcl/testmodules/TestModuleFunc.pas`.
    - [X] **9.4.6.l.5** `register_async_vtab` — DROPPED.
  - [X] **9.4.6.m** `sqlite3_log` (already wired in 10.1.36) +
    `sqlite3_io_trace` — Tcl bindings + assert hooks.
  - [X] **9.4.6.n** `sqlite3_memdebug_*` set — ported the `test_malloc.c` fault-injection allocator + Tcl commands (`sqlite3_memdebug_fail`/`_pending`/`_settitle`/`_backtrace`/`_malloc_count`, `install_malloc_faultsim`, …) into `src/tests/tcl/testmodules/TestModuleMalloc.pas`.
  - [X] **9.4.6.o** File-control opcodes — PERSIST_WAL, LOCKSTATE,
    CHUNK_SIZE, SIZE_LIMIT, POWERSAFE_OVERWRITE, ZIPVFS, BUSYHANDLER,
    TEMPFILENAME, MMAP_SIZE.  Many already partly wired via Phase
    10.1f.8 (.filectrl).  Audit + close gaps.  C ref:
    `../sqlite3/src/os_unix.c:unixFileControl`.
  - [X] **9.4.6.p** `sqlite3_busy_timeout` / `sqlite3_busy_handler` —
    audit; pair with 9.4.2.k.
  - [X] **9.4.6.q** Unported test-only Tcl commands — ported the `test1.c` subset (`sqlite3_connection_pointer`, `sqlite3_db_config`, `atomic_batch_write`, `load_static_extension`) into `src/tests/tcl/testmodules/TestModuleTest1.pas`; `real2hex` SQL func + `faultsim_save_and_close` family into the test modules / `tester_min.tcl`.
    - [X] **9.4.6.q.1** test1.c prepared-statement C-API subset — `sqlite3_prepare(_v2)`, `sqlite3_exec`, `sqlite3_backup`, `sqlite3_errmsg`, `sqlite3_transfer_bindings` ported into `src/tests/tcl/testmodules/TestModuleTest1.pas` (test1.c:417/4910/5035/5092/3145; test_backup.c:26..150).
    - [X] **9.4.6.q.2** Remaining 9.4.4.d-surfaced test commands.
  - [X] **9.4.6.r** Faithful `fcntlSizeHint` port — ported `fcntlSizeHint` (os_unix.c:4049) into `src/passqlite3os.pas`: `SQLITE_FCNTL_SIZE_HINT` now pre-grows via `posix_fallocate` with chunk-size rounding instead of being a no-op.

- [~] **9.4.7** Build-matrix / harness infrastructure.  Many tests
  require a *different* build of libpassqlite3 than the default.
  Each profile lives as its own `bin/libpassqlite3tcl-<profile>.so`
  and the driver picks one via `--build`.
  - [X] **9.4.7.a** Compile-flag introspection finishing — for
    `ifcapable` to work, every `SQLITE_OMIT_*` / `SQLITE_ENABLE_*`
    symbol on the Pascal side must report through
    `sqlite3_compileoption_used`.  Walk `src/passqlite3.inc` to
    enumerate them; add to the registry.  Pairs with 9.4.6.a.
  - [X] **9.4.7.b** Memdebug build profile — `src/tests/build_tcl_lib_memdebug.sh` adds `-dSQLITE_MEMDEBUG` and produces `bin/libpassqlite3tcl-memdebug.so` (private staging dir so its `.ppu`/`.o` don't clobber the default build).
  - [X] **9.4.7.c** I/O-error injection — ported the `os_common.h` `SQLITE_TEST` machinery (the `SimulateIOError`/`SimulateDiskfullError` counter checks) directly into the Pascal unix VFS read/write/sync/truncate rather than a `test_devsym.c` wrapper VFS (the wrong tool — `do_ioerr_test` drives global counters).
  - [~] **9.4.7.c.old** ~~test_devsym.c wrapper VFS~~ — superseded by the counter-instrumentation approach above; kept only if a future test needs a real device-characteristics shim.  Registers via
    `sqlite3_vfs_register`.
  - [~] **9.4.7.d** Crash-test harness — faithful port of `test6.c`
    landed as `src/tests/tcl/testmodules/TestModuleCrash.pas` (Agent
    6, 2026-05-16).  The "crash" VFS wraps the system default unix
    VFS, queues every `xWrite`/`xTruncate` in an in-memory write
    list, and on the `iCrash`'th `xSync` of the configured
    `zCrashFile` calls `_exit(-1)` — exactly the upstream power-loss
    semantics.  Tcl bindings `sqlite3_crash_enable`,
    `sqlite3_crash_now`, `sqlite3_crashparams` registered via
    `Sqlitetest6_Init` from `PasTclSqlite.pas:Sqlite3_Init`.
    `crashsql` Tcl proc landed under 9.4.2.g.11.  Verified
    end-to-end through `bin/TclTestDriver`: a hand-rolled .test
    using `crashsql -delay 1 -file test.db-journal { INSERT ... }`
    runs, the child crashes mid-journal-sync, the parent reopens
    and confirms recovery + integrity_check ok.  Marked [~] (not
    [X]) because three followups remain — see 9.4.2.g.11 for the
    list (`ifcapable crashtest`, WAL shm methods, the upstream
    `unixVfsObjFoo := unixVfsObj` record-copy issue).
  - [ ] **9.4.7.e** `permutations.tcl` matrix — full upstream re-runs
    each test under ~30 build-flag combinations.  Land as
    optional second-tier gate (not in baseline CI).  Requires:
    a build matrix generator script that emits one .so per
    permutation + driver flag `--permutation NAME` to pick.
    C ref: `../sqlite3/test/permutations.tcl`.
  - [X] **9.4.7.f** Per-test isolation — currently `TclTestDriver`
    runs every test against the same CWD.  Refactor to:
    (1) create a tmpdir per test, (2) `cd` tclsh there before
    sourcing, (3) cleanup on exit.  Prevents test cross-pollution
    via leaked `test.db`.
  - [X] **9.4.7.g** Driver concurrency — `--jobs N` flag spawns
    N tclsh processes in parallel; aggregates results.  Mirrors
    upstream's `make -j` testing.
    Outcome: cthreads + TCriticalSection worker pool in
    `src/tests/TclTestDriver.pas:993..1156` (TJobSlot/TJobWorker
    types + RunParallel) with parallel-safe `RunOneCapture` core
    extracted from RunOne (lines 481..594); serial `--jobs 1`
    path stays byte-identical (modulo per-test ms timing).
    50-test smoke: 11010 ms serial vs 4812 ms with `--jobs 4`
    (~2.3x), identical 45 pass / 5 fail counts.  Per-test
    isolation (9.4.7.f tmpdir) already prevents CWD races.
  - [X] **9.4.7.h** `tclsqlite3_Init` package-config — drop our
    `Sqlite3_Init` so `package require sqlite3` works without
    the explicit `load` line.  Generate a Tcl `pkgIndex.tcl`
    pointing at `libpassqlite3tcl.so` and install into
    `auto_path`.  Quality-of-life; lets us run upstream tests
    verbatim (which assume the package is loadable by name).
  - [X] **9.4.7.i** Threading build (`-dSQLITE_THREADSAFE=1`) —
    some tests assume the threadsafe build.  Audit which tests
    + which sqlite3 mutex hooks need real implementations vs.
    no-op stubs.  Gate this profile behind its own .so.
    Outcome: pas-sqlite3 is pinned threadsafe-by-default
    (`SQLITE_THREADSAFE = 1` const in passqlite3internal.pas:59,
    unconditional pthread backend in passqlite3os.pas), so the
    `-dSQLITE_THREADSAFE` define is a no-op for generated code.
    Landed `src/tests/build_tcl_lib_threadsafe.sh` producing
    `bin/libpassqlite3tcl-threadsafe.so` plus a `--build PROFILE`
    flag in TclTestDriver.pas that loads
    `bin/libpassqlite3tcl-<profile>.so` via explicit `load`
    bypassing pkgIndex.tcl.  Full audit + C-reference comparison +
    test inventory (ctime/mutex1/mutex2/tkt3793 pas-strict;
    sort/sortfault pas-skip-unswept) in
    `src/tests/tcl/THREADSAFE_AUDIT.md`.  Smoke: mutex1, mutex2,
    tkt3793 PASS against the threadsafe .so via `--build threadsafe`.

- [~] **9.4.8** Full-corpus parity gate.
  - [X] **9.4.8.a** Per-test status tags — adopt the pas-strict /
    pas-soft / pas-skip convention from 9.1.5.  Land
    `src/tests/tcl/STATUS.txt` with one line per MANIFEST entry:
    `<status>\t<path>\t<cite>`.
  - [X] **9.4.8.b** STATUS.txt seeded from current sweeps —
    populate after 9.4.4.g lands.  Default: every test that
    PASSes is pas-strict; FAIL with citation is pas-soft;
    SKIP is pas-skip with mandatory cite.
  - [X] **9.4.8.c** Strict gate — `bin/TclTestDriver --gate strict`
    is now the sole exit-code decider when set: it diffs results
    against STATUS.txt inline (mirroring check_status_regression.sh)
    and exits non-zero iff any pas-strict row regressed to FAIL.
    Verified locally: `--gate strict --limit 50` exits 0 today;
    flipping one pas-soft row to pas-strict flips exit to 1.
  - [X] **9.4.8.d** Coverage check — `bin/TclTestDriver --coverage`
    injects `pas_opcode_coverage_{enable,dump}` Tcl cmds (registered
    by PasTclSqlite.Sqlite3_Init) into each per-test script, dumps
    per-test gVdbeOpCoverage[] snapshots to a tmpdir, aggregates,
    and writes `src/tests/tcl/COVERAGE_DELTA.md` listing opcodes
    hit ONLY by the tcl corpus (cold per `src/tests/corpus/
    COVERAGE_GAPS.md`).  Wrap is finalize_testing-aware and re-
    applies after every tester.tcl re-source.  Default-off so the
    normal sweep pays zero extra cost.
  - [X] **9.4.8.e** Regression archive — `src/tests/tcl/
    regression_bisect.sh` walks `git bisect` between a known-good
    baseline and a known-broken commit, using TclTestDriver as the
    test predicate (PASS=good, anything else=bad, build-fail=125).
    Ready for use once the corpus gate flips green.

#### 9.4 divergence buckets (cite `src/tests/tcl/DIVERGENCES.md`)

- [X] **9.4.divbug.1** `select1.test select1-4.4` (`ORDER BY min(f1)`)
  triggered a Pascal-side segfault.  Root cause: the pas resolver never
  rewrote aggregate `TK_FUNCTION` calls in ORDER BY of a non-aggregate
  query to `TK_AGG_FUNCTION` (resolve.c:1330), so codegen emitted a
  scalar `OP_Function` and `minStep` crashed in `sqlite3_aggregate_context`.
  Fixed by tagging those nodes in `sqlite3ResolveSelectNames` after
  ORDER BY resolution; codegen's `TK_AGG_FUNCTION` misuse arm now raises
  `misuse of aggregate: min()` matching the C oracle.
- [X] **9.4.divbug.2** SQL error messages drop their format-arg
  tails: `misuse of aggregate function` should read
  `misuse of aggregate function min()`; `table has wrong number
  of values for INSERT` should carry the column counts.  Likely
  cause: a `sqlite3ErrorMsg` call site in the port isn't threading
  through `sqlite3VMPrintf` and `%s` / `%d` substitutions are
  swallowed.  Audit all `sqlite3ErrorMsg` call sites in `src/*.pas`
  against `../sqlite3/src/parse.y` / `resolve.c` shaped error texts.
- [X] **9.4.divbug.3** Schema introspection result columns reordered
  / missing — `index.test` sub-tests `index-1.1c` / `index-1.1d`.
  Not an engine bug: `tester_min.tcl` never opened `db`, and the
  driver hardcoded `sqlite3 db :memory:`, so sub-tests that do
  `db close; sqlite3 db test.db` to re-read the schema from disk
  saw an empty database.  Fix: add a `reset_db` proc to
  `tester_min.tcl` (forcedelete test.db family + `sqlite3 db
  ./test.db`), call it at shim load, and drop the driver's
  `:memory:` open.  index-1.1c/1.1d/1.2 now PASS.
- [X] **9.4.divbug.4** `update.test` sub-test `update-10.1` reported
  spurious `out of memory`.  Real root cause: `sqlite3CreateIndex`
  auto-name path hardcoded `sqlite_autoindex_<tab>_1` instead of
  counting `pTab^.pIndex` (build.c:4097..4101).  A table with two
  implicit UNIQUE indexes got two identically-named auto-indexes,
  and the schema-hash collision surfaced as NOMEM.  Fixed by porting
  the C `for(pLoop=pTab->pIndex,n=1; ...)` count loop.
- [X] **9.4.divbug.5** `numcast.test` 0/51 → 51/51 Ok.  Root cause was
  *not* engine-side: `sqlite3VdbeMemCast` / `MemRealValueRC` slow path
  already handle UTF-16LE/BE.  Two bridge-side bugs: (a) `DbEvalArm` in
  `PasTclSqlite.pas` never bound `$var`/`:var`/`@var` placeholders, so
  every CAST input arrived NULL → `{}`; (b) `PRAGMA encoding='...'` in
  `passqlite3codegen.pas` lacked a write arm, so the test's encoding
  preamble silently no-op'd.  Fix: minimal port of `dbPrepareAndBind`'s
  param loop + the `PragTyp_ENCODING` write arm (pragma.c:2267..2286).
- [X] **9.4.divbug.6** Doubled error string in `db1 eval`'s error
  return — surfaced by 9.4.2.f gate `tcl_err()` returning
  `boomboom` instead of `boom`.  Root cause: `DbEvalArm`
  (PasTclSqlite.pas) appended `sqlite3_errmsg(db)` on top of the
  already-populated Tcl interp result string (the UDF trampoline
  already routed `error "boom"` to `sqlite3_result_error`, which
  propagates verbatim).  Fix: both error tails in `DbEvalArm` now
  call `Tcl_SetObjResult(interp, Tcl_NewStringObj(sqlite3_errmsg(db),-1))`,
  matching upstream `tclsqlite.c:dbEvalStep` line 1812.
  `bin/TestTclSqliteFunction` now reports
  `PASS: tcl_err -> rc=1 msg=[boom]` (was `[boomboom]`).
- [X] **9.4.divbug.7** `insert.test` hangs (tclsh wedges past 60s)
  shortly after `insert-1.3`.  9.4.4.a saw it crash here; 9.4.4.b
  re-sweep promoted the symptom to a hang.  Likely an infinite
  loop in INSERT codegen / VDBE step for the larger-table variant
  the sub-test exercises.  See `src/tests/tcl/DIVERGENCES.md`.
- [X] **9.4.divbug.8** `index.test` segfaults at `index-3.3` — the
  sub-test is `DROP TABLE test1` after 99 indexes were created.
  Root cause: `sqlite3BtreeDelete` set `bPreserve := flags and
  BTREE_SAVEPOSITION` (= 2) instead of C's boolean
  `(flags & BTREE_SAVEPOSITION)!=0` (= 1).  On the saveCursorKey
  rebalance path the stale `2` made the final `bPreserve > 1` arm
  wrongly take the CURSOR_SKIPNEXT branch (instead of moveToRoot +
  CURSOR_REQUIRESEEK), leaving the schema-table cursor on a
  balanced-away page → OP_Column fetched a NULL payload → SIGSEGV.
  Fixed by coercing bPreserve to a 0/1 boolean.  See DIVERGENCES.md.
- [X] **9.4.divbug.9** `lastinsert.test` segfaults right after
  `lastinsert-1.1` (the `1.1w` variant uses a 64-bit rowid).
  Likely overflow in `sqlite3_last_insert_rowid` path or a stale
  pointer in the `db last_insert_rowid` sub-command shim.
  See DIVERGENCES.md.
- [X] **9.4.divbug.10** `boundary1.test` SELECTs returned `{}` not
  because of WhereCode, but because `boundary1-1.1`'s 64 `INSERT INTO
  t1(oid,a,x) VALUES(...)` rows all failed: sqlite3Insert's IDLIST
  loop errored on any name not a real column, never honouring the
  rowid-alias branch (C insert.c:1097).  Table stayed empty so every
  downstream query returned `{}`.  Fixed by porting the `ipkColumn`
  rowid-alias arm.  See DIVERGENCES.md.
- [X] **9.4.divbug.11** Compound `SELECT ... ORDER BY` `iOrderByCol<=0` assert — ported `resolveCompoundOrderBy` (resolve.c:1589); select1.test runs past 6.22.
- [X] **9.4.divbug.12** `update-17.10` segfault — actually a constant-expr `CREATE INDEX` crash; gated `sqlite3CreateIndex` column lookup to identifier tokens (build.c:4220).
- [X] **9.4.divbug.13** Inequality-scan row ordering — gated `whereShortCut` `nOBSat:=nExpr` to `WHERE_ONEROW` plans so IPK range scans get a sorter; boundary1.test 1511/1511.
- [X] **9.4.divbug.14** SQL errors drop object name — routed scattered `sqlite3ErrorMsg` sites through upstream `%s`/`%S`/`%T` formats (build.c / resolve.c).  Residual 2026-05-16: closed — (a) aggerror-1.4 needed t1CountStep v=41 UTF-16 arm (test1.c:1286, TestModuleTest1.pas:985); (b) aggorderby-1.3 needed `ORDER BY may not be used with non-aggregate %T()` raise in resolver TK_FUNCTION arm (resolve.c:1288, codegen.pas:10336); (c) aggorderby-4.1 sticky-row min/max needed minmax skipFlag magnet + OP_AggStep1 wiring (func.c:2103/2121 + vdbe.c:7933, codegen.pas:54714/maxStep + vdbe.pas:9685).
- [X] **9.4.divbug.15** `no such function` not raised at prepare — ported the `resolveExprStep` TK_FUNCTION error arm (resolve.c:1129..1276).
- [X] **9.4.divbug.16** `affinity3.test` segfault — `sqlite3WhereBegin` skipped opening a RIGHT JOIN table cursor scanned index-only; ported the `JT_LTORJ|JT_RIGHT` gate (where.c:7252).  Residual 2026-05-16: closed — fully ported `sqlite3SubqueryColumnTypes` compound-arm walk + BLOB downgrade (select.c:2378..2398); UNION view col affinity downgrades to BLOB when arms mix text/numeric, giving the JOIN comparison P5 affinity AFF_BLOB (was AFF_NUMERIC) so `'1' (text) ≠ 1 (int)` (codegen.pas:25560).
- [X] **9.4.divbug.17** Subquery-nested aggregate evaluated row-wise — ported the resolver's outward AggInfo-binding arm (resolve.c:1337..1352).  aggnested-3.x residue tracked as divbug.24.
- [X] **9.4.divbug.18** WITHOUT ROWID vtab `xUpdate` — DELETE now emits `OP_Column` for argv[0]; `updateVirtualTable` routed through `sqlite3WhereBegin` so `xBestIndex` runs.
- [ ] **9.4.divbug.19** Table-qualified `rowid` alias (`t1.rowid`, `sp.rowid`) — ported the qualified-case rowid arm from lookupName (resolve.c:471..503 + 623..638) into the TK_DOT branch of `ResolveExpr`: when `sqlite3ColumnIndex` misses and `zCol` ∈ {rowid,oid,_rowid_} and the matched source `HasRowid`, bind `iColumn=-1` / AFF_INTEGER.  Cites: 3fd04ef.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. autoindex5).  Triage 2026-05-16: autoindex5-1.1 needs `SEARCH debian_cve USING AUTOMATIC COVERING INDEX (bug_name=?)` but Pas emits a flat `SCAN debian_cve` with an unopened cursor (Rewind p1=3 with no preceding OpenRead) — view materialisation as co-routine inside a correlated subquery is not wired and `constructAutomaticIndex` Asserts out on the viaCoroutine arm (codegen.pas:20830).  Out-of-scope for this pass; needs porting where.c:1191..1234 viaCoroutine arm + EQP CO-ROUTINE emission + the SrcItem.viaCoroutine set on materialised views.
- [X] **9.4.divbug.20** BETWEEN-on-indexed-column planner — fixed by porting exprAnalyze's trailing `prereqRight |= extraRight` (whereexpr.c:1566..1570) so ON-clause BETWEEN children of outer-join left tables get filtered out by the prereqRight gate.  Cites: 2f8d92a, d7ceaf3, 5dba89a.
- [ ] **9.4.divbug.21** Cross-connection EXCLUSIVE lock detection + busy-handler firing — fixed.  Commits `45593de`, `a8e63c3`.  Residual 2026-05-16: PRAGMA optimize was a silent no-op (no PragTyp_OPTIMIZE arm), so busy-3.2/3.3/3.4/3.5/3.7 never engaged the busy handler.  Ported a reduced pragma.c:2517..2640 arm at codegen.pas:51258 that emits CodeVerifySchema + BeginWriteOperation on every non-temp attached DB so the busy handler fires for both EXCLUSIVE (3.2) and SHARED-blocks-write (3.5/3.7) scenarios.  All 14 sub-tests now pass under the in-process tclsh — driver still reports FAIL because the tcl interpreter SIGSEGVs after finalize_testing's `exit 0` (only under TProcess capture, not standalone), an unrelated shutdown issue.
- [ ] **9.4.divbug.22** Large row / `PRAGMA page_size=65536` overflow — two fixes: `fillInCell` overflow-path nil-pBt deref (`45a1fbb`) and `accessPayload` passing `Ord(eOp=0)=1` as pager flag colliding with `PAGER_GET_NOCONTENT` (`9744b0f`).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. bigrow, btree01); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.23** Correlated FROM-subquery EQP shape — emitted `SETUP` / `RECURSIVE STEP` nodes inside `generateWithRecursiveQuery` (select.c:2781, 2813) and a `CO-ROUTINE %!S` + `SCAN %!S` wrapper around the aggregate-on-subquery materialise arm (select.c:8054 / where.c sqlite3WhereExplainOneScan).
- [ ] **9.4.divbug.24** `sqlite_sequence` double-created for AUTOINCREMENT — ported build.c:2967..2972 (pin `pSchema^.pSeqTab` when init.busy adds a table named `sqlite_sequence`) at codegen.pas:40916.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. aggnested); reopened per failing-pas-soft-with-closed-cite rule.  Investigation 2026-05-16 (agent5): aggnested fail is NOT a sequence/AUTOINCREMENT residual — it is a SIGSEGV that hits between aggnested-2.0 and aggnested-3.0 on the `db2 close` at aggnested.test:70.  Minimal repro (no AUTOINCREMENT involved):  open `db` on test.db with 3+ rows feeding a correlated `SELECT (SELECT group_concat(a1) FROM u2) FROM u1`, then open separate `db2 :memory:` with PRIMARY KEY tables, run any SELECT in db2, call `db2 close` → crash.  Requires (a) ≥2 outer rows in the db1 correlated subquery, (b) group_concat or string_agg in the inner agg (sum / count are fine), (c) db2 must have at least one PRIMARY KEY table (without the PRIMARY KEY no crash).  Crash is on `db2 close` even though group_concat ran in db1.  TGroupConcatCtx (codegen.pas:54840) contains no managed Pascal types so the "New() on record with AnsiString" trap (MEMORY.md) is not the cause.  Likely a function-context / aggregate-context residue on the shared db schema that gets re-entered during cross-DB close.  Needs valgrind / address-sanitizer; deferred — out of agent scope.
- [X] **9.4.divbug.24.b** aggnested-3.3 wrong scalar-subquery value + aggnested-3.11 SIGSEGV — fully fixed.
- [X] **9.4.divbug.25** `update-19.10` `AssertH FAILED: idxColIsBeingUpdated rowid` — fixed by stopping IPK index-column rewrite to XN_ROWID in CreateIndex.  Commit `04d98cf`.
- [X] **9.4.divbug.26** Echo vtab INSERT fails — `echoUpdate` emits `%Q`-quoted column names.
- [X] **9.4.divbug.27** Engine OOM-recovery path segfaults under an injected malloc failure (memdebug build) — blocked `do_malloc_test` from being fully useful.  Cites: `passqlite3util.pas:2529..2587`.
- [X] **9.4.divbug.28** EXPLAIN QUERY PLAN segfaults on multi-table queries after first row (eqp2/cost/fordelete/delete2).
- [ ] **9.4.divbug.41** EQP detail-text omits LAST-N-TERMS-OF when nOBSat>0 (eqp2/cost/fordelete/delete2).  Fixed at codegen.pas:31663 by porting select.c:1702..1711 nOBSat/nKey branch (LAST TERM OF / LAST n TERMS OF / plain ORDER BY).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. cost, fordelete); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.29** TEXT-affinity column stores `'0x119'` literal as INTEGER 281 (collate1).
- [ ] **9.4.divbug.30** ORDER BY with non-default collation (NOCASE) mis-orders.  Residual 2026-05-16: 3 pas-soft test(s) still fail (e.g. collate4, collate8); reopened per failing-pas-soft-with-closed-cite rule.  Progress 2026-05-16 (agent5): collate8.test now PASS (23/23) and collate4 advances past 6.1/6.2 (sort-vs-nosort).  Three Pas-level resolver/planner bugs ported from resolve.c + where.c:  (a) `sqlite3CreateColumnExpr` IPK aliasing missing in both expandStar (codegen.pas:25942..25956) and bare-TK_ID lookupName arm (codegen.pas:9977..9998); both now set iColumn=-1 when matchCol==iPKey so wherePathSatisfiesOrderBy can match ORDER BY <ipk> against XN_ROWID (resolve.c:863..887).  (b) NC_UEList alias fallback for ORDER BY (resolve.c:658..698) was only invoked for bare TK_ID via ResolveAsName; expressions like `ORDER BY +x` referencing AS-alias never resolved.  Reuse ResolveAliasInHaving walker on each pOrderBy item where iOrderByCol=0 (codegen.pas:11142..11156).  (c) whereShortCut's Pas-only full-table-scan fallback (codegen.pas:20533..20593) bypasses wherePathSolver entirely, so ORDER BY on a plain SCAN was forced through an external sorter; gate the fallback off when caller passed pOrderBy / WHERE_GROUPBY / WHERE_DISTINCTBY / WHERE_WANT_DISTINCT (matches C whereShortCut at where.c:6350..6417 which only succeeds on WHERE_ONEROW).  Net: 5190/9 (was 5180/18) in build.sh regression.  Residual collate4 failures (2.1.7/2.1.8 NOCASE index for IN-list; 4.3 min(a)/max(a) using TEXT index; 4.10/4.13/4.14 scalar max(b,a) collation) are distinct collation-propagation bugs not addressed here.
- [ ] **9.4.divbug.31** Spurious `database disk image is malformed` for non-corrupt errors (collate3 `no such collation sequence: …`, count-1.2.4/5).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. collate3, count); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.32** Readonly-DB DELETE returns `unknown error` instead of `attempt to write a readonly database` (delete-8.x).  Verified 2026-05-16: delete-8.0..8.7 all pass; original symptom resolved by 845de2a (unixOpen RO-retry, os_unix.c:6692).  Residual delete-12.0 (forumpost/e61252062c9d286d short-circuit-subquery) is a separate bug — bComplex/NC_Subquery gate now matches C 1:1 via exprHasSubquery walker (codegen.pas:35148, delete.c:497) but the actual two-pass codegen still mis-orders the deletions; tracked under unbucketed.
- [X] **9.4.divbug.33** `count(DISTINCT …)` returns 1 instead of 0 for an empty set (distinctagg-3.x).  Closed 2026-05-16: distinctagg.test 70/70 passes; root cause was the GROUP-BY aggregate arm in sqlite3Select not mirroring select.c:8466..8481 (build pDistinct = pGroupBy ++ argExpr), select.c:8531 (eDist = sqlite3WhereIsDistinct), select.c:8692 (pass eDist into updateAccumulator) or select.c:8750..8753 (fixDistinctOpenEph after addrReset).  Without those four hooks the per-Func iDistinct OP_OpenEphemeral was never noop'd even when an existing index already delivered uniqueness, so the EXPLAIN-shape probes for 4.1.1 / 4.4.1 / 4.6.1 (`OpenEphemeral absent?`) all reported the wrong shape.  Fix at codegen.pas:29662..29697 (build pAggDistinct + distFlag), 29723..29742 (WhereBegin passes distFlag + reads eDistResult via sqlite3WhereIsDistinct), 29852 (updateAccumulatorSimple now receives eDistResult), 29964..29972 (fixDistinctOpenEph + sqlite3ExprListDelete).
- [X] **9.4.divbug.34** `PRAGMA page_size` reports build default (8192) regardless of per-test write (createtab-0.2 expects 4096, format4-1.1 expects 2048).  Closed 2026-05-16: format4.test 3/3 passes; root cause was two-fold.  (a) `passqlite3os.pas` `unixDeviceCharacteristics_impl` returned 0 unconditionally — stock os_unix.c:4480..4484 ORs in SQLITE_IOCAP_POWERSAFE_OVERWRITE when the per-file UNIXFILE_PSOW bit is set, and that bit is on by default (os_unix.c:6105 `pNew->ctrlFlags |= UNIXFILE_PSOW`).  Without PSOW the pager's setSectorSize (pager.c:2728) saw the raw FS sector size (4096+ on ext4) and clamped szPageDflt up to it, making `SQLITE_DEFAULT_PAGE_SIZE` unreachable.  Fix at passqlite3os.pas:2181..2200 (return IOCAP_POWERSAFE_OVERWRITE when UNIXFILE_PSOW set) + 2308..2314 (default PSOW on, off via `psow=0` URI).  (b) Stock testfixture compiles with `-DSQLITE_DEFAULT_PAGE_SIZE=1024` (main.mk:1781) — Pas equivalent is `{$IFDEF SQLITE_TEST} SQLITE_DEFAULT_PAGE_SIZE=1024 {$ELSE} 4096 {$ENDIF}` in passqlite3types.pas:284..294.  Residual createtab-1.2 (auto_vacuum=1, expects 5120 = 1024×5, gets 4096 = 1024×4) is an unrelated auto_vacuum-pointer-map-page bookkeeping bug — av=0 path passes all 30 sub-tests.
- [X] **9.4.divbug.35** Float-to-text precision artefacts: `-1.11` → `-1.1099999999999999`; large doubles get an extra mantissa digit (fpconv1, default-3.3).  Cites: `tester.tcl:789..792`, 22337203685478e, 223372036854776e.
- [X] **9.4.divbug.36** `PRAGMA journal_mode=off` silently ignored — keeps prior mode `delete` (changes-1.1.0).  Verified 2026-05-16: changes.test now passes 66/66 (all 6 nRow buckets including WITHOUT ROWID 50k); resolved by 47e5cb7 (PragTyp_JOURNAL_MODE write arm).
- [ ] **9.4.divbug.37** WAL `wal_hook` callback reports 0 frames where upstream reports >0 (e_walhook-1.3+).  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. e_walhook); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.38.a** Malformed `REFERENCES … ON` parser error message.  Cites: `passqlite3parser.pas:2872..2898`.
- [ ] **9.4.divbug.38.b** FK-cascade picks wrong target row (e_fkey-2.1/3.1).  Cites: `src/tests/tcl/tester_min.tcl:244`.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. e_fkey); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.39** `CREATE TABLE AS SELECT` (CTAS) unsupported in this build (errofst1, distinct2-100, delete-7.6).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. distinct2, errofst1); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.40** `DEFAULT` clause: error text drops column-name (default-1.3 `default value of column is not constant` missing `[y]`); DEFAULT-derived affinity reported in wrong order (default-3.1).
- [X] **9.4.divbug.42** Mis-triaged: root was an engine SIGSEGV on `collate1.test` 8.2, not harness pollution (TclTestDriver already spawns a fresh tclsh per test).  Cites: bba7b69f.
- [X] **9.4.divbug.43** `ORDER BY … NULLS FIRST` / `NULLS LAST` clause ignored when an index could satisfy the sort — fixed by refusing the BIGNULL_SORT index-match in wherePathSolver (codegen.pas:18567..18585) so the planner falls back to the external sorter (which already honours sortFlags via VdbeRecordCompare).
- [X] **9.4.divbug.44** Misclassified cluster — root was `IN (SELECT ...
- [X] **9.4.divbug.45** `HAVING` with non-aggregate predicate over-filters: having-3.2 expects different bytecode (optimisation skipped for non-deterministic `randomblob(a)`), pas matched (incorrectly hoisted into WHERE).
- [X] **9.4.divbug.46** `LIMIT N` combined with subquery / DESC clamps wrong number of rows (limit-1.2.3 expects 5 rows got 3; limit-2.1 expects 2 got 32; limit2-100.3).  Cites: `pIn3->u.i>0?pIn3->u.i:0`.
- [X] **9.4.divbug.47** Numeric `_` digit-separator literals not parsed: `1_000`, `1.1_1`, `0x1_2` raise `unrecognized token: "1_000"` (literal-3.x, literal2).  Cites: 1000000.
- [X] **9.4.divbug.48** Hex-literal overflow detection: error text drops the literal value (hexlit-400 expects `hex literal too big: 0x10000000000000000` got `hex literal too big`); some too-big inputs silently accepted (hexlit-401/402 expected error, pas returns OK).
- [X] **9.4.divbug.49** Generated-column (`GENERATED ALWAYS AS ...` VIRTUAL/STORED) codegen drops value and type — gencol1-100 expects `[integer 0]` got `[text null]`; gencol1-2.2.x rows return empty cells.
- [X] **9.4.divbug.50** JSON output float formatting: integer-valued JSON numbers render as `1` instead of `1.0`; very-large doubles render as `1E99` instead of `1.0e+99` (json101-1.4/1.4b first-row diff).
- [X] **9.4.divbug.51** JSON error-message text divergences: `json103-101` reports generic `SQL logic error` instead of `JSON cannot hold BLOB values`; `json109-2.1` reports `not an array element: $.a` (missing surrounding single quotes); `json105-6.10` reports differently-quoted bad-path string.
- [X] **9.4.divbug.52** JSON `subtype()` / `sqlite_subtype()` function unported — `json102-1600` reports `no such function: subtype`; downstream subtype-aware JSON tests cascade.
- [X] **9.4.divbug.53** Parser error reports `near token: syntax error` (placeholder) instead of `near "<actual-token>": syntax error` (fuzz2-6.1 expects `near "#0"`).
- [X] **9.4.divbug.54** ORDER BY DESC + LIMIT+OFFSET on a partially-satisfied block-sort (orderby6-1.12..1.14: `ORDER BY b DESC, a LIMIT 10 OFFSET 20/45`) dropped one row per block boundary and substituted a stray row from the next block.
- [X] **9.4.divbug.55** EXPLAIN QUERY PLAN detail-string divergences (sibling-of 41): orderby5-1.1 reports `USE TEMP B-TREE FOR DISTINCT` where C does not; indexedby-7.1/index8-1.1eqp report `COVERING INDEX` where C reports plain `INDEX`; indexexpr1-110eqp omits `USING INDEX t1a1` detail.
- [X] **9.4.divbug.56** Default `LIKE` collation matches both cases when single-case expected (like-1.5.2 expects `[abc]` got `[ABC abc]`).
- [X] **9.4.divbug.57** `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)` not enforced — openv2-1.1 expects `unable to open database file` for missing-db RO open got OK; openv2-1.4 expects `attempt to write a readonly database` got OK.
- [X] **9.4.divbug.58** `CREATE INDEX … (missing_col)` error gate fires late — index-2.1b expects `no such column: f4` on the CREATE INDEX statement, pas returns OK and only complains on the following `index1 already exists` (index-2.2).
- [X] **9.4.divbug.59** JOIN USING/NATURAL: prefix-qualified column reference (`t2.a` where `a` is the USING column) raises `no such column: t2.a` (joinC-1..3); upstream resolves to the USING-shared column.
- [X] **9.4.divbug.60** Tcl bridge coerces integer values bound through `db eval` to REAL: keyword1-database.1 expects `[1 2 3 99]` got `[1.0 2.0 3.0 99.0]` (partial overlap with gencol1-100 `[integer 0]→[text null]` integer-vs-text path).
- [X] **9.4.divbug.61** Harness gap: `fts3_common.tcl` not staged in `src/tests/tcl/` — every `fts3*.test` / `fts4*.test` that begins with `source $::testdir/fts3_common.tcl` aborts with `SOURCE-ERROR: couldn't read file ".../fts3_common.tcl"` (~15 tests).
- [ ] **9.4.divbug.62** Harness gap: test1.c `sqlite3_*` Tcl commands unported — tests fail with `invalid command name "sqlite3_mprintf_int"` / `"sqlite3_column_count"` / `"sqlite3_finalize"` / `"sqlite3_bind_*"` / `"sqlite3_status"` / `"sqlite3_release_memory"` / `"sqlite3_limit"` / `"sqlite3_rekey"` / `"sqlite3_create_function"` / `"sqlite3_simulate_device"` / `"sqlite3_config_pmasz"` / `"sqlite3_config_uri"` / `"sqlite3_config_alt_pcache"` / `"sqlite3_reset_auto_extension"` (~50 tests incl. printf, printf2, pragma4, tkt2213, tkt-752e1646fc, tkt-99378177930f87bd, tkt-b75a9ca6b0, tkt-385a5b56b9, tkt2565, shortread1, vacuum, vacuum-into, uri, upfrom2, upfromfault, upsert5, values, wal9, zeroblobfault, pcache2, tpch01, pendingrace, reservebytes, rowvalue7).  Residual 2026-05-16: 17 pas-soft test(s) still fail (e.g. pcache2, pendingrace); reopened per failing-pas-soft-with-closed-cite rule.
  - [X] **9.4.divbug.62.a** `sqlite3_mprintf_*` family (`sqlite3_mprintf_int`, `_str`, `_double`, `_long`, `_int64`, `_z_test`, `_n_test`, `_stronly`, `_hexdouble`, `_scaled`) — printf trampoline Tcl commands.  Cites: `src/tests/tcl/testmodules/TestModuleTest1.pas:1180..1450`, 1234567890123, 4000000000000000.
  - [X] **9.4.divbug.62.b** Statement-level introspection: `sqlite3_column_count`, `sqlite3_column_name`, `sqlite3_column_decltype`, `sqlite3_column_type`, `sqlite3_column_text`, `sqlite3_column_int`, `sqlite3_column_int64`, `sqlite3_column_double`, `sqlite3_column_blob`, `sqlite3_column_bytes`, `sqlite3_column_bytes16`, `sqlite3_data_count`, `sqlite3_finalize`, `sqlite3_reset`, `sqlite3_step`, `sqlite3_sql`, `sqlite3_expanded_sql`, `sqlite3_normalized_sql`, `sqlite3_stmt_status`, `sqlite3_stmt_busy`, `sqlite3_stmt_readonly`, `sqlite3_stmt_isexplain`.
  - [X] **9.4.divbug.62.c** Binding API: `sqlite3_bind_int`, `sqlite3_bind_int64`, `sqlite3_bind_double`, `sqlite3_bind_text`, `sqlite3_bind_text16`, `sqlite3_bind_null`, `sqlite3_bind_blob`, `sqlite3_bind_zeroblob`, `sqlite3_bind_zeroblob64`, `sqlite3_bind_value_from_select`, `sqlite3_bind_parameter_count`, `sqlite3_bind_parameter_name`, `sqlite3_bind_parameter_index`, `sqlite3_clear_bindings`.  Cites: `src/tests/tcl/testmodules/TestModuleTest1.pas:1953..2393`.
  - [X] **9.4.divbug.62.d** Resource accounting: `sqlite3_status`, `sqlite3_db_status`, `sqlite3_release_memory`, `sqlite3_soft_heap_limit`, `sqlite3_soft_heap_limit64`, `sqlite3_hard_heap_limit64`, `sqlite3_limit`.  Cites: 1048576, 1000000000.
  - [X] **9.4.divbug.62.e** Function / extension management: `sqlite3_create_function`, `sqlite3_create_function_v2`, `sqlite3_create_window_function`, `sqlite3_reset_auto_extension`, `sqlite3_load_extension`, `sqlite3_simulate_device`, `sqlite3_user_version`.
  - [X] **9.4.divbug.62.f** Config & legacy: `sqlite3_config_pmasz`, `sqlite3_config_uri`, `sqlite3_config_alt_pcache`, `sqlite3_rekey`, `sqlite3_rekey_v2`, `sqlite3_key`, `sqlite3_key_v2`.
- [ ] **9.4.divbug.63** Harness gap: tcl-shim helper commands unported — tests fail with `invalid command name "run_thread_tests"` / `"test_cli_invocation"` / `"test_find_cli"` / `"test_find_sqldiff"` / `"tcl_variable_type"` / `"breakpoint"` / `"database_may_be_corrupt"` / `"explain_no_trace"` / `"file_control_reservebytes"` / `"faultsim_test_result"` (~25 tests incl. thread001..005, thread1, thread2, tempdb2, shell1..9/A/B, select9, selectC/E/H, sharedA/B, sqldiff1, skipscan2, sort4, types3, unique, unique2, unionallfault, quota-glob, pragma6, parser1).  Cites: 7be23b7, 1800d46, 8de8be5.  Residual 2026-05-16: 5 pas-soft test(s) still fail (e.g. pragma6, quota-glob); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.64** `db func` and `db format` subcommands unported — tests fail at the first `db func name argcount body` or `db format` call with `unknown subcommand "func" - implemented in 9.4.2.d..o` (~12 tests incl. tkt1514, tkt-d11f09d36e, tkt-7bbfb7d442, tkt35xx, update, update2, unordered, windowD, whereD, pushdown, savepoint7, schema2/4/6, rowvalue3, rdonly, qrf03..06).  Cites: 3b37eed.  Residual 2026-05-16: 16 pas-soft test(s) still fail (e.g. pushdown, qrf03); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.65** Tester Tcl globals `::DB` / `::STMT` (sqlite3 + sqlite3_stmt opaque pointers) not exported by tester_min.tcl — schema.test family aborts at `can't read "::DB": no such variable`.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. schema); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.66** SQL functions / extensions unregistered: `zeroblob`, `regexp`, `regexpi`, `percentile`, `percentile_cont`, `randstr`, `if` — `no such function: zeroblob` (zeroblob, without_rowid1/6/7); `no such function: percentile` (percentile); `no such extension: regexp` (regexp1/2); `no such function: randstr` (tkt3918); `no such function: if` (tkt-9d68c883).  Cites: 51de8ba.  Residual 2026-05-16: 6 pas-soft test(s) still fail (e.g. percentile, regexp2); reopened per failing-pas-soft-with-closed-cite rule.
  - [X] **9.4.divbug.66.a** Register `randstr(N,M)` from test_func.c:40 + `if(c,a,b)` (3-arg ternary scalar) as built-in scalar functions surfaced even without `autoinstall_test_functions`.
- [X] **9.4.divbug.67** `stmtrand` SQL extension unported — `no such extension: stmtrand` (stmtrand, stmt, sqllimits1, starschema1).  Cites: 46d8e3d.
- [ ] **9.4.divbug.68** `PRAGMA module_list` does not include `fts5` row — pragma5-2.1 expects `[fts5]` got `[]`.  Cite: pragma.c PragTyp_MODULE_LIST + virtual-table module registration of fts5.  Surfaced 9.4.4.g.  Triage 2026-05-16: `PragTyp_MODULE_LIST` handler itself is correct (codegen.pas:51139..51148 walks `db^.aModule` HASH; pas currently emits 23 modules incl. dbstat, sqlite_dbpage, generate_series, json_each, json_tree, sqlite_stmt, fsdir, completion, zipfile, etc. — strictly more than the C oracle's 16 in this build).  The pragma5-2.1 case is gated by `ifcapable fts5` (pragma5.test:49), so the only real gap is the unported fts5 module itself — see sub-task .68.a.  Do not flip [X] until .68.a lands.
  - [ ] **9.4.divbug.68.a** Port fts5 vtab module (ext/fts5/*.c) — blocker for `PRAGMA module_list` containing `fts5`.  XL.
- [ ] **9.4.divbug.69** `PRAGMA temp.<header_value>` SIGSEGV — originally triaged as a Tcl-bridge `sqlite3 HANDLE FILENAME ?OPTIONS?` parser-stub mismatch (residue of divbug.57), but inspection showed `DbMain` (PasTclSqlite.pas:4455..4718) already covers the option set; pragma3 was crashing the interpreter long before any option parsing happened.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. pragma3); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.70** Error-text divergences (parser/resolver hints):  Residual 2026-05-16: 4 pas-soft test(s) still fail (e.g. quote, select1); reopened per failing-pas-soft-with-closed-cite rule.
  - `syntax error after column name "<x>"` drops the quoted column name (parser1, tokenize).
  - `no such column: "<id>" - should this be a string literal in single-quotes?` hint omitted (quote-2.1.x).
  - `misuse of aggregate function min()` vs C `misuse of aggregate: min()`; `misuse of aliased aggregate <m>` vs C `misuse of aggregate: <fn>()` (select1-2.20..23, tkt3508).
  - `unknown table option: unknown2` drops the offending name (tableopts, strict1).
  - `1st ORDER BY term out of range - should be between 1 and 2` not produced (select1-4.10.2).
  - `a JOIN clause is required before ON` not detected (tkt3935.5/7).
  Cite: parse.y `%syntax_error` (divbug.53 partial overlap), build.c `markAllShadowTablesOf`/AddColumnError, resolve.c aggregate-misuse messages, select.c ORDER BY index range check.  Surfaced 9.4.4.g.  Outcome: ported error-text hints (parse.y:1671/240, build.c:5080, resolve.c:789/1812) plus nested/aliased aggregate misuse (codegen.pas:10625-10720, 10921-10985, 11038); a/b/d/e/f pre-existing.  Commits 1a0629b, d04edb5.
- [ ] **9.4.divbug.71** STRICT-typed table mis-error path: `INSERT INTO strict t1(a) VALUES('x')` reports `*** in database main ***` framing (integrity-check output) instead of `non-INT value in t1.a` (strict1, strict2); aborted-stmt rollback reports `unknown error` instead of `abort due to ROLLBACK` (tkt2817, tkt2820, savepoint7).  Cites: be8a29b.  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. tkt2817, tkt2820); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.72** Row-value misuse detection missing — `SELECT (1,2)` and `SELECT … WHERE (a,b)=...` constructs accepted silently when C raises `row value misused` (rowvalue-3.1.x, rowvalue4-1.x; cascades to rowvalue2/3/7/8/9/A).  Cites: 7eb9851, 8618b87.  Residual 2026-05-16: 7 pas-soft test(s) still fail (e.g. rowvalue2, rowvalue4); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.73** `rowid` post-INSERT resolution returns 0 — rowid-4.5 expects last_insert_rowid()=3 got 0; sibling rowid-4.5.1 expected `[3 3]`.  Cites: 524dbb1.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. rowid); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.74** UPSERT `ON CONFLICT DO UPDATE` increments target row count off by one — upsert3-200 expected row matrix `[1 2 2 x 3 4 1 x 5 6 0 x]` got `[1 2 1 x …]` (the "2" is the conflict-incremented col).  Cites: e2a5f6c.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. upsertfault); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.75** select7 correlated/derived `no such column: P.pk` — `SELECT … FROM (SELECT pk FROM t) P WHERE P.pk = ...` resolver misses the wrapper-qualified column; sub-select "expected N columns" error text also diverges.  Cites: 74e00c2.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. select3); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.76** View-column resolution `no such column: y` — tkt3346-1.x: `INSERT INTO t SELECT y FROM v` where `v` is a view exposing `y` raises `no such column: y`.  Cites: f09bb72.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. tkt3346); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.77** Cross-schema trigger validation error text — triggerupfrom-2.4 expects `malformed database schema (tr3) - trigger tr3 cannot reference objects in database main` got `unable to open database: test.db`; trustschema1 same family.  Cites: d7f1dd1.  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. triggerupfrom, trustschema1); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.78** Wide-table SCAN+predicate mis-count — widetab1-340: `SELECT count(*) FROM t WHERE col=…` expected 7 got 10 on a table with many columns (likely planner picks wrong index or skips predicate eval on overflow page).  Cites: a3e2335.
- [ ] **9.4.divbug.79** windowE ROWS-framing produces permuted output — windowE-1.3 expected `[5 5,4 5,4,1 5,4,1,6 5,4,1,6,3 5,4,1,6,3,2]` got `[2 2,3 2,3,6 2,3,6,1 2,3,6,1,4 2,3,6,1,4,5]`.  Cites: 041da7c.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. windowE); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.80** `ORDER BY without LIMIT on DELETE`/UPDATE not detected — wherelimit-0.1 expects `ORDER BY without LIMIT on DELETE` got plain `near "ORDER": syntax error` from the grammar; same for wherelimit3.  Cites: 031f065.  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. wherelimit3, wherelimit); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.81** Attached / `query_only` DB readonly enforcement (residue of divbug.57) — queryonly-1.4/.5 expects `attempt to write a readonly database` got `0 {}`; pager4-1.3/.4 same family; rdonly.test cascade.  Cites: 5e01244.  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. pager4, rdonly); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.82** INSERT…RETURNING / scalar-function eval returns empty row — tkt-31338-3.1 expected `[4 1 2 3 4 {}]` got `[]`; tkt-26ff-1.x and tkt-5e10420e8d cascade.  Cites: 4324004.
- [ ] **9.4.divbug.83** Planner row-order divergence across where* family — whereA-1.2 expected `[3 4.53 {} 2 hello world 1 2 3]` got `[1 2 3 2 hello world 3 4.53 {}]`; whereG-1.3 expected detail-string regex `/.*track.*composer.*album.*/` got order with composer scanned first (EQP residue of divbug.55); whereB/F/I/N, where2/6/8, orderbyB show similar ordering / EQP-shape divergences.  Cites: eab96c2.  Residual 2026-05-16: 8 pas-soft test(s) still fail (e.g. orderbyB, where2); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.84** Long-running tests hit the 20 s per-test driver timeout — `select4.test`, `writecrash.test`, `securedel2.test` all aborted by the timeout watchdog and counted as FAIL.  Cites: c8f1af4.  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. securedel2, writecrash); reopened per failing-pas-soft-with-closed-cite rule.
- [ ] **9.4.divbug.85** `collate5.test` pas-strict regression — 6 errors / 159 ran on shard 0/4 surfaced 2026-05-16; STATUS.txt:172 lists the file as `pas-strict` with no cite, so the strict gate now fires `REGRESSION (pas-strict FAIL): ../sqlite3/test/collate5.test`.  Triage: bisect against the last known-green run (shard-0 log at `/tmp/tcl-shard0.log`, per-test dump in `bin/tcl-failure-logs/collate5.test.{out,err}`); likely a collation-driver regression introduced after the file was baselined.  Blocks the tcl-nightly aggregate gate from passing.
- [ ] **9.4.divbug.86** Sibling-of-.84 driver-timeout family — `pragma4.test`, `printf.test`, `securedel.test` all exceed the 20 s per-test watchdog under shard 2/4 (2026-05-16 run), consuming the entire shard budget and preventing it from completing 240 entries (only 99 done before the 25-min outer timeout).  STATUS.txt currently lists them as `pas-soft` citing the closed `9.4.divbug.62` / `9.4.4.g-unbucketed` — those cites covered the original failure mode, not the new hang.  Action: same as .84 — either raise the per-test budget, port the missing functionality, or move the entries to `SKIP.md` so shard 2 can finish and the strict gate becomes meaningful.
- [ ] **9.4.divbug.87** Result divergence cluster (carved from `9.4.4.g-unbucketed` 2026-05-16) — **73 pas-soft tests** emit `got:` lines that do not match the C oracle.  Subdivided into `result-divergence` (68: e.g. `backup5`, `badutf`, `capi2`, `colmeta`, …) and `malformed-corrupt-vector` (5: `backup4`, `corruptM`, `in2`, `rowhash`, …).  Each test needs an individual bisect; this single bullet placeholds until root-cause splits emerge.  Full list classified in `/tmp/unbk_sig2.tsv` from the 2026-05-16 sweep.
  - [X] **9.4.divbug.87.001** `backup4` — ! backup4-1.2 error: database disk image is malformed.  Fixed: OP_Transaction schema-cookie check (vdbe.c:4163..4198) + sqlite3_step reprepare-on-SCHEMA wrapper (vdbeapi.c:911..960) — both were stubs; backup-induced schema changes now surface as SQLITE_SCHEMA→reprepare instead of stale-cursor CORRUPT.
  - [X] **9.4.divbug.87.002** `backup5` — ! backup5-1.6 got: [SQLITE_CORRUPT SQLITE_CORRUPT].  Same fix as .001 (shared root cause); backup5-1.6/.1.7 now report SQLITE_ERROR / "no such table: t2".
  - [ ] **9.4.divbug.87.003** `badutf` — ! badutf-1.1 got: [0 {{253830}}].  Partial: 32/36 sub-tests now PASS — test_exec Tcl shim now performs the `%HH` → raw-byte decode pass and uses Tcl_DString/AppendElement for proper list-element escaping (test1.c:421..460 + exec_printf_cb test1.c:195..208).  Residual 4 failures (badutf-4.4..4.7) are real `trim()` UTF-8 boundary bugs — distinct root cause, separate port work.
  - [X] **9.4.divbug.87.004** `capi2` — ! capi2-1.5 got: [name rowid {} {}].  Fixed: port `generateColumnTypes` + `columnType` (select.c:2070..2107 + select.c:1918..2064, NON-SQLITE_ENABLE_COLUMN_METADATA arms) into codegen.pas and call from `sqlite3GenerateColumnNames` end (select.c:2202).  Before: COLNAME_DECLTYPE slots all empty → `sqlite3_column_decltype` returned ""; after: real table columns + rowid alias + sub-select recursion all yield proper decl-types.  Failures down from 168 → 136.  Residual: sqlite_master columns still report empty decltype because the init.busy re-prepare path drops the column type for the synthetic `CREATE TABLE x(type text,name text,...)` (prepare.c:230) — root cause is separate (init-callback path), not in the column-type code; surfaces only on `SELECT … FROM sqlite_master`.
  - [X] **9.4.divbug.87.005** `colmeta` — ! colmeta-1.1 got: [1 {invalid command name "sqlite3_table_column_metadata"}].  Fixed: Tcl-bridge gap — engine `sqlite3_table_column_metadata` (passqlite3main.pas:3593, main.c:4009) was already ported, only the test1.c Tcl shim was missing.  Ported `test_table_column_metadata` (test1.c:1740..1791) into TestModuleTest1.pas with its Tcl_CreateObjCommand registration (test1.c:9279).  colmeta.test now PASS (51 sub-tests, 106 ms).
  - [X] **9.4.divbug.87.006** `corruptC` — ! corruptC-2.1 got: [0 {{*** in database main ***  Partial: corruptC-2.1/.3/.4/.6/.7/.10/.11/.13/.14 now PASS (22→9 sub-test failures).  Fixed by porting the missing `PragFlg_NeedSchema` upfront gate in `sqlite3Pragma` (pragma.c:521..524 → passqlite3codegen.pas:51175..51187) — first `PRAGMA integrity_check` on a fresh handle now triggers `sqlite3ReadSchema` before codegen instead of running against an empty pSchema and letting the cookie mismatch surface mid-step as `database schema has changed`.  Residual: 2.5/2.9/2.12/2.15 show different error-text divergences (separate root causes — distinct corruption-detection arms not yet ported); 2.2 hits CORRUPT during UPDATE that C handles silently.
  - [X] **9.4.divbug.87.007** `corruptM` — malformed database schema (t1)}].  Same root cause + fix as .006.  Verified via standalone tclsh repros that 102/111/113/114/121/131/141/151/161/171/181/191/193 each now return the expected `[1 {malformed database schema (X)}]`.  Residual: when the full corruptM.test is sourced end-to-end the tcl shim SIGSEGVs at corruptM-102 cleanup inside `Tcl_DeleteCommandFromToken` (db2 close after writable_schema-modified sqlite_master state) — a pre-existing memory-management bug in the db-cmd teardown path that the surfaced real error returns now expose; needs separate triage.
  - [X] **9.4.divbug.87.008** `delete4` — ! delete4-6.0 got: [1 3 5].  Already fixed by 22e77fa (divbug.32+36 bComplex/NC_Subquery walker): `sqlite3DeleteFrom` now calls `exprHasSubquery(pWhere)` and sets `bComplex:=1` when WHERE contains TK_SELECT/TK_EXISTS/TK_IN sub-SELECT, stripping `WHERE_ONEPASS_MULTIROW` from `wcf` so the planner uses the two-pass rowset path (delete.c:497 `if( sNC.ncFlags & NC_Subquery ) bComplex = 1;`).  Re-run post-build: delete4.test PASS 28/28 in ~1.4s; stale failure-log timestamped pre-22e77fa.
  - [X] **9.4.divbug.87.009** `descidx1` — ! descidx1-2.1 got: [4 5 6].  Fixed: `sqlite3CreateIndex` per-column loop was hard-coding `aSortOrder[i] := 0` instead of copying the ASC/DESC bit from the parser's `pListItem->fg.sortFlags` (build.c:4270..4271).  Ported `sortOrderMask` gate (build.c:4190..4196 — honour DESC only when `pDb->pSchema->file_format>=4`).  Without the per-column DESC bit, `KeyInfo.aSortFlags` was all-ASC, `PRAGMA index_xinfo` reported `desc=0` for every column, and `wherecode.c:1959` swap-bounds arm never fired — forward scan of a DESC index produced ASC row order.  Failure count for `descidx1.test` 14 → 1 (residual 6.1 is the `legacyformat` ifcapable gating, separate concern).
  - [X] **9.4.divbug.87.010** `diskfull` — ! diskfull-2.2.2 got: [{*** in database main ***  Already fixed by 2944378 (divbug.87.006/.007 — PragFlg_NeedSchema upfront `sqlite3ReadSchema` gate at pragma.c:521..524 → passqlite3codegen.pas:51175..51187).  After VACUUM aborts under simulated SQLITE_FULL (os_unix.c:3707..3708 SimulateDiskfullError → passqlite3os.pas:1710..1714), the test does `db close; sqlite3 db test.db; integrity_check`; without the upfront ReadSchema the first `PRAGMA integrity_check` on the fresh handle codegen'd against an empty pSchema and integrity_check synthesised "*** in database main *** Page N: never used" lines.  Re-run post-build: diskfull.test PASS 744 sub-tests in ~2.4 s; stale failure-log timestamped 2026-05-16 21:54 (pre-2944378).
  - [X] **9.4.divbug.87.011** `eval` — ! eval-2.3 got: [1 {} {} 2 {} {} 3 {} {} 4 {} {}].  Already fixed by b318b57 (divbug.87.009 — `sqlite3CreateIndex` sortOrderMask + per-column DESC bit copy; build.c:4190..4196, 4270..4271).  eval-2.3 is `SELECT … FROM t2 ORDER BY rowid DESC`; before the fix the auto-PK index lost the DESC bit and rows came out in ASC rowid order (1 2 3 4) instead of DESC (4 3 2 1).  Re-run post-build: eval.test PASS 8/8 sub-tests in ~410 ms.
  - [X] **9.4.divbug.87.012** `exec` — ! exec-1.2 got: [0 {{1} {2}}].  Fixed as side-effect of .003 (test_exec Tcl shim: %HH decode + Tcl_DString list elements; test1.c:421..460 + 195..208).  exec.test PASS 3/3 sub-tests in 44 ms.
  - [X] **9.4.divbug.87.013** `exprfault` — FIXED: tester_min.tcl do_faultsim_test mis-quoted `\;` separator collapsed `set {}` into zero-arg `set`. Port verbatim from malloc_common.tcl:347,378..380 (proc faultsim_test_proc wrap).
  - [X] **9.4.divbug.87.014** `exprfault2` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.015** `func3` — ! func3-1.2 got: [1].  Fixed: port the missing SQLITE_ANY encoding-fanout arm (main.c:1984..1999), the "delete non-existent function is a no-op" gate (main.c:2027..2030), and the active-VM busy/expire gate (main.c:2012..2026) into `sqlite3CreateFunc` (codegen.pas:53380).  Before: `sqlite3_create_function_v2 db f2 -1 any … -destroy destroy` only registered one UTF8 slot (encByte was `enc and $03`, dropping SQLITE_ANY=$05 back to UTF8) with destructor nRef=1; the very next utf8 re-registration in 1.2 found the matching slot, decremented nRef 1→0, and fired the destroy callback prematurely.  After: ANY recurses into UTF8+UTF16LE+UTF16BE so pDestructor->nRef=3, 1.2 only takes it to 2 (no fire), 1.3 to 1 (no fire), 1.4 to 0 (fire) — matches expected `0 0 0 1`.  func3.test errors 8 → 4 (residuals 3.2 / 5.8 / 5.9 / 5.10 are unrelated likelihood / arg-validation arms).
  - [X] **9.4.divbug.87.016** `fuzz-oss1` — ! fuzz-oss1-skrooge error: no such column: v_operation_tmp1.id.  Two-part fix: (a) port select.c:6131..6136 — `expandStar` (codegen.pas:25977) was zeroing the new ExprList entry when carrying a non-`*` result column past a `*` neighbour, dropping `zEName` + `fg.eEName`; without these `SELECT *, expr AS q FROM t` lost the AS-name and CREATE VIEW stored the alias as `columnN` so cross-view refs failed.  (b) extend `ResolveOuterRefs` (codegen.pas:9303) to recurse into `x.pSelect` of an expression-subquery node — mirrors C `sqlite3WalkExpr` → `sqlite3WalkSelect` descent + lookupName pNC->pNext climb (resolve.c:341..706, 1378..1390).  Without the deeper walk a doubly-nested correlated TK_DOT (e.g. innermost `t3.x=t1.id` inside a sub whose own pSrc is t2) was never pre-resolved against the grand-outer pSrc and parsed as "no such column".  fuzz-oss1.test PASS 1/1 in 2.76 s.
  - [X] **9.4.divbug.87.017** `gcfault` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.018** `gencol1` — ! gencol1-2.1.150 error: table t1 has 6 columns but 3 values were supplied.  Fixed: port the NOINSERT (= GENERATED | HIDDEN) tally arm of insert.c:1241..1254 into the no-IDLIST count check at codegen.pas:38574.  Before, the Pas site reduced to `nColumn <> pTab^.nCol` and rejected `INSERT INTO t1 VALUES(a,b,c)` on the 3-real + 3-generated schema 1; now it subtracts NOINSERT cols (gated on `TF_HasGenerated | TF_HasHidden`) so the expected count matches the user-supplied positional count.  gencol1-2.1.150 PASS; ipkColumn left untouched to preserve the downstream `ipkColumn = -1` invariant for the no-IDLIST path.  Residual gencol1-2.{2,3,6}.x failures are unrelated generated-column expression-eval / typeof divergences.
  - [X] **9.4.divbug.87.019** `having` — ! having-5.2 error: no such column: Col0.  Fixed (two-part): (a) extract the existing FROM-subquery interior outer-ref walker (codegen.pas:10279..10305) into a recursive helper `WalkDeepFromSubqueries` so every level of nested FROM-subquery has its pEList/pWhere/pHaving/pGroupBy/pOrderBy pre-bound against the outermost pSrc (resolve.c:341..706 lookupName pNC->pNext climb).  (b) ALSO invoke that walker BEFORE `sqlite3SelectExpand(pInner)` (codegen.pas:10202 region).  having-5.2's EXISTS subquery wraps a FROM-subquery whose own pSelect has a WHERE clause that references the outer `Col0`; sqlite3SelectExpand recursively calls sqlite3SelectPrep on every FROM-subquery body (codegen.pas:26617) which runs the per-Select resolver — and that resolver raised "no such column: Col0" on the deep WHERE before the post-expand WalkDeep arm ever ran.  Pre-binding the bare TK_ID to TK_COLUMN against the outermost pSrc fixes it.  Safe even though pDeep^.pSrc items haven't been expanded yet: ColumnInSrcList loops items and Continues on pSTab=nil so the inner-scope test still returns false.  having.test PASS 1/1 (was 0/1); no select1/exists/subquery/tkt3346 regressions.
  - [X] **9.4.divbug.87.020** `hexlit` — ! hexlist-401 got: [0 {}].  Fixed: strip SF_Distinct on no-FROM SELECT before the no-FROM fast-path gate at codegen.pas:29420.  `SELECT DISTINCT 0x10000000000000000;` was hitting the SF_Distinct exclusion in that gate, then no later codegen arm (GROUP BY / Aggregate / WHERE-loop) matches a no-FROM source so sqlite3Select returned SQLITE_OK without coding any expression — codeInteger never ran so the "hex literal too big" error never fired.  Stripping SF_Distinct is sound: a no-FROM body emits exactly one row, DISTINCT is trivially a no-op.  Mirrors C select.c:8253..8263 where WhereBegin still drives sqlite3ExprCode → codeInteger → sqlite3ErrorMsg for the same query.  hexlit.test PASS 1/1.
  - [ ] **9.4.divbug.87.021** `in2` — ! in2-{286..571} error: database disk image is malformed (209 of 1997 sub-tests fail).  Triage notes (4 h, deferred): Repro is `tclsh ./bin/libpassqlite3tcl.so` + the in2.test seed (2000 ints + '' + 2000 short text rows in table `a`), then `SELECT 1 IN (SELECT a FROM a WHERE i<N OR i>=2000)` for various N; passes in `bin/passqlite3` shell, fails only under the Tcl binding because the testfixture build forces SQLITE_DEFAULT_PAGE_SIZE=1024 (types.pas:290) so balancing fires sooner.  Bug surfaces inside the **IN-subquery ephemeral b-tree** when `defragmentPage` slow path runs on a leaf index page (e.g. pgno=4) and the post-rebuild invariant `data[hdr+7]+cbrk-iCellFirst != pPage^.nFree` trips → `CORRUPT_PAGE` at btree.pas:1488..1490 (port of btree.c:1721).  Instrumented dump shows pPage^.nFree=11 but actual page physical free is 8 (top=292, freeblocks=[], nFrag=0, iCellFirst=284) AND `sum(xCellSize)` over the 138 cell pointers comes to 725 bytes so cbrk=299 and post-defrag free should be 15 (a 7-byte and a 4-byte mismatch).  Cells are 12×size-8 ("xNNNN" text records), 1×size-4 (the empty-string row), 125×size-5 (integers 128..285).  All cell varint heads decode cleanly; xCellSize_IdxLeaf returns the same min-4 bumped size that fillInCell/sqlite3BtreeInsert padded to.  The +3 inconsistency originates **upstream of defrag** — likely a previous balance_nonroot iteration set `apNew[iPg]^.nFree := usableSpace - szNew[iPg]` (btree.pas:6066) using a szNew that was 3 bytes short, propagating from an older sibling whose nFree was already 3 high (cumulative bias from the apDiv padding loop at btree.pas:5774-5778 interacting with the `b.szCell[j]==4 → sz := xCellSize(pParent, pCell)` interior re-parse arm at btree.pas:5957-5960; both arms are 1:1 with C btree.c:8496-8503 and 8855-8858, yet C oracle passes — suggesting Pas-side allocation/buffer-layout subtlety that's not yet identified).  Need deeper trace correlating szNew[i] computation against insertCell/insertCellFast sites over the whole 138-cell life of pgno=4.  Deferred.
  - [X] **9.4.divbug.87.022** `in5` — FIXED (already passing).  The failure log was stale from a prior pre-fix run; current build passes 44/44 in5-* sub-tests (incl. in5-2.3 / in5-3.3 / in5-4.3 / in5-5.3 OpenEphemeral negative-match probes).  Confirmed by deleting `bin/tcl-failure-logs/in5.test.*` and re-running `TclTestDriver --filter in5.test` — 0 errors, no log regenerated.
  - [ ] **9.4.divbug.87.023** `in6` — ! in6-1.5 got: [104].  Partial work landed: ported where.c:7637..7664 IN-tail WHERE_IN_EARLYOUT/iLeftJoin arm into sqlite3WhereEnd (codegen.pas:22653) so OP_IfNoHope + OP_IfNotOpen now emit when the planner sets WHERE_IN_EARLYOUT.  But the real blocker is upstream: the Pas `whereLoopAddBtreeIndex` (codegen.pas:16770) never extends the index-key equality chain through WO_IN terms on inner key columns — e.g. `WHERE a IN (1,2,3) AND b=1` on `INDEX(a,b)` falls back to SCAN instead of `SEARCH … (a=? AND b=?)`.  Without IN being chosen as the loop driver, IN_EARLYOUT is never set and the new IfNoHope code never fires.  Root cause is in the IN-arm cost gate or nEq increment path; needs deeper planner port (where.c:3343..3409 + whereLoopAddBtreeIndex recursion).  Deferred.
  - [ ] **9.4.divbug.87.024** `in7` — ! in7-1.1.6 got: [1] (also 1.1.7 / 1.1.10 / 1.1.12 / 4.0).  Same root cause as 023: the Pas planner picks SCAN instead of an IN-driven SEARCH plan for `WHERE c IN (SELECT z FROM t2)` (c is PK) and the UNIQUE-INDEX variants — so per-IN-value Next is emitted on the t1 cursor when C oracle uses SeekGE+DeferredSeek with no t1.Next.  Plus in7-4.0 is a separate NATURAL JOIN error.  Same fix path as 023.  Deferred.
  - [X] **9.4.divbug.87.025** `index` — index-16.{1,2,3,4} now pass.  Root cause: equivalent-constraint dedup loop (build.c:4315..4379) was deferred in sqlite3CreateIndex — `CREATE TABLE t7(c UNIQUE PRIMARY KEY)` and the UNIQUE(c)+PRIMARY KEY(c) variants published two redundant auto-indices.  Ported the `pTab==pParse->pNewTable` dedup arm in passqlite3codegen.pas:sqlite3CreateIndex (right before the codegen/hash-publish phase): walk pTab->pIndex, match nKeyCol + aiColumn + collation, reconcile onError per OE_Default precedence, promote idxType to PRIMARYKEY if applicable, IN_RENAME_OBJECT pin to pNewIndex, then goto exit_create_index.  Remaining index.test divergences are unrelated (index-21.1 error-message text, index-23.0 separate UNIQUE-trigger bug).
  - [X] **9.4.divbug.87.026** `index3` — index3-1.4 now passes.  Root cause: aborted CREATE UNIQUE INDEX inside BEGIN…COMMIT left a freelist orphan ("Page 3: never used") because the Pas Vdbe never set `usesStmtJournal` (vdbeaux.c:2694) and never opened the per-statement btree savepoint (vdbe.c:4140..4161 inside OP_Transaction).  Without the savepoint, the abort at OP_Halt(OE_Abort, 'UNIQUE constraint failed') still rolled back row changes via the VM error path but the sqlite_master insert + freshly allocated index root page survived the eventual COMMIT.  Ported both arms: (a) VdbeMakeReady now sets VDBF_UsesStmtJournal from `isMultiWrite && mayAbort` (passqlite3vdbe.pas:3900..3905, byte-offset Parse access since vdbe.pas can't see TParse), and (b) OP_Transaction now opens the stmt journal via sqlite3VtabSavepoint+sqlite3BtreeBeginStmt and snapshots nDeferredCons/Imm into the Vdbe (passqlite3vdbe.pas:10156..10186).  vdbeCloseStatement already handled the matching RELEASE/ROLLBACK once `iStatement!=0`.
  - [ ] **9.4.divbug.87.027** `index8` — 1.1eqp: planner picks t1abd index even when it cannot cover c=4 (expected `~/USING INDEX/` — fall back to SCAN).  Triage: deeper cost-model arithmetic (covering vs ORDER-BY-LIMIT-helping); left for separate sweep.
  - [ ] **9.4.divbug.87.028** `index9` — partial-index with bound-variable WHERE not selected.  exprCompareVariable port landed (codegen.pas:59736..59774) and exits 0 when bound value equals partial-WHERE literal.  Full fix also needs vdbeUnbind55 to set Vdbe.expired when expmask bit is set, plus the step-side reprepare cycle that passes pReprepare = old vdbe so bound values flow into the partial-index implication test on re-prepare.  Triage: requires expmask plumbing + reprepare cycle.
  - [ ] **9.4.divbug.87.029** `indexA` — partial-index with literal WHERE not selected.  whereShortCut's fall-through SCAN branch (codegen.pas:20680..20686) bypasses the full planner when all indexes are partial, so whereLoopAddBtree → whereUsablePartialIndex is never reached.  Deferring to the full planner here exposes a latent gap: WhereEnd's Index→table column rewrite (where.c:7732..7886) is still unported (codegen.pas:22584), so any WHERE_IDX_ONLY plan crashes at runtime when codegen reads OP_Column from an unopened table cursor.  Both must land in tandem.
  - [~] **9.4.divbug.87.030** `indexedby` — indexedby-8.1 and 8.3 fixed (`UPDATE ... SET rowid=...` now reports COVERING INDEX).  Root cause: divbug.55's early WHERE_IDX_ONLY clear was guarded only on WHERE_ONEPASS_DESIRED, but C's clear (where.c:7218..7237) is gated on bOnerow OR (WHERE_ONEPASS_MULTIROW && !vtab && !MULTI_OR && SQLITE_OnePass enabled).  UPDATE plans that change the rowid (chngKey=1) don't get MULTIROW, so the IDX_ONLY bit must stay → "COVERING INDEX" EQP.  Restored the full C gate at codegen.pas:21740..21766.  indexedby-11.10 (SELECT IPK col): pas resolveExprAgainstSrcList (codegen.pas:8444 / 8467) accumulates colUsed bit for IPK alias column, defeating coverage detection.  C resolve.c:826..831 skips that bit (`if pExpr->iColumn>=0`); pas's resolver hasn't done the IPK→XN_ROWID rewrite yet when colUsed is set.  Narrow `if iCol <> iPKey` fix tried but regressed unrelated tests, reverted; tracked separately.
  - [X] **9.4.divbug.87.031** `indexexpr3-1.1` — port XN_EXPR arm of sqlite3ExprCodeLoadIndexColumn (expr.c:4367..4372) so CREATE INDEX populates the expression column; port whereAddIndexedExpr (where.c:6668..6716) + sqlite3IndexedExprLookup (expr.c:4746..4807) + sqlite3ExprCanReturnSubtype (expr.c:4730) and wire the WhereBegin gate (where.c:7348) and ExprCodeTarget pre-dispatch (expr.c:4946) so expr-index substitution removes the Function opcode.  1.5/1.6 still diverge (need EP_SubtArg flagging in resolver) and 2.3/2.5 still diverge (covering-index EQP wording) — separate sub-tasks.
  - [~] **9.4.divbug.87.032** `insert` — three root causes ported (insert.test now 83 PASS, was 0).  (a) IDLIST per-column resolution must run BEFORE the SELECT coroutine is emitted so destCoro.iSdst is initialised from the IDLIST-resolved bIdListInOrder; pre-pass added at codegen.pas:38731..38770, late count-mismatch check stays.  (b) SRT_Coroutine disposal arm was missing the post-row DecrJumpZero (select.c:1522..1524), so `INSERT INTO t SELECT … FROM src LIMIT N` ingested every row of src — added at codegen.pas:33135..33140.  (c) useTempTable Template-4 IPK pre-load read `OP_Column srcTab, iPKey, regRowid` unconditionally; C insert.c:1505..1509 reads it via `srcTab, ipkColumn` when the IDLIST names the IPK, or via storage column iPKey when there is no IDLIST — fixed at codegen.pas:39089..39105.  Remaining 4 fails (4.3/4.4/4.6/7.3) are pre-existing resolver gaps unrelated to .032 root cause.
  - [X] **9.4.divbug.87.033** `insert2` — fixed by 87.032 (a)+(b) above (shared root cause).  insert2-2.1/2.2/2.3 (IDLIST column-shuffle) and insert2 LIMIT-bypass arms now pass; insert2 went from 22 fail to 6 fail.  Remaining 1.2.1/1.2.2/1.3.2 are EXCEPT/INTERSECT compound-SELECT-as-source (separate Phase-6.8.6 gap, not the .033 IDLIST issue), 6.1 is order divergence on a different INSERT shape, 6.2/6.3 are fts4/missing-module gaps.
  - [X] **9.4.divbug.87.034** `insert3` — fixed by 87.032 (c) above.  insert3-2.2 root cause: the useTempTable IPK pre-load at codegen.pas:39089 read `OP_Column srcTab, iPKey, regRowid` unconditionally, so for `INSERT INTO t2(b) SELECT … FROM t1 LIMIT 1` (where IPK `a` is NOT in IDLIST) the IDLIST's first value 987 was treated as the rowid → spurious UNIQUE failure on subsequent inserts.  Gated on `pColumn=nil ? iPKey : ipkColumn` per C insert.c:1505..1509.  Remaining 3.2/3.4 are trigger WHEN-clause column resolution (separate resolver gap).
  - [X] **9.4.divbug.87.035** `insertfault` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.036** `instrfault` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.037** `intpkey` — Fixed.  Root cause: whereShortCut's Pas-only IPK-range arm (codegen.pas:20713..20772) took Exit(1) for any `WHERE rowid>k` even when a far better non-rowid index was available (e.g. i3(c,a) for `WHERE c='world' AND a>7`), bypassing whereLoopAddBtree/wherePathSolver entirely.  C's whereShortCut (where.c:6350..6440) only short-circuits on WHERE_ONEROW.  Fix at codegen.pas:20713: gate the IPK-range arm on `pTab^.pIndex = nil` (no non-partial indices) so any table with another candidate index falls through to the cost-based planner.  intpkey-3.8 now picks `INDEX i3 (c=? AND a>?)` matching the C oracle, search_count=3.  Side-benefit: 8 other regression binaries (TestBtreeCompat, TestCliParity, TestPagerReadOnly, TestShellBackup/Dbinfo/IO, TestSQLCorpus, TestVectorSchemaChange) also moved from FAIL→PASS.
  - [X] **9.4.divbug.87.038** `intreal` — already passes (20/20).  Failure log at bin/tcl-failure-logs/intreal.test.out (May 16 21:53) was stale; fresh runs PASS deterministically (3x verified, ~150ms each).  Likely cured by one of the .032..037 commits (esp. .032-034 INSERT IDLIST + IPK-from-srcTab and .037 whereShortCut IPK-range gate — intreal-3.0 uses UPDATE OR REPLACE on a UNIQUE INDEX with expression column).  No code change needed.
  - [X] **9.4.divbug.87.039** `istrue` — Fixed (5 sub-tests recovered: 520, 521, 522, 523, 524, 700).  Root cause: sqlite3ResolveExprNames gated the TK_ID→TK_TRUEFALSE and TK_IS/TK_ISNOT+TK_TRUEFALSE→TK_TRUTH rewrites behind `pSrcList<>nil and nSrc>0` (via flagUnresolvedTKID), so contexts with no SrcList (single-row INSERT VALUES at codegen.pas:38930, CHECK at 43447) silently skipped the rewrites.  Single-row `INSERT INTO t(b) VALUES(true)` therefore left `true` as TK_ID — sqlite3ExprCode emitted no Integer for the column slot, leaving b NULL.  Any `CHECK(b IS TRUE)` then fired even on legitimate inserts.  Fix at codegen.pas:9101: added rewriteTrueFalseAndTruth() helper that *only* performs the TK_TRUEFALSE/TK_TRUTH rewrites (no error emission), invoked unconditionally inside sqlite3ResolveExprNames before the err-emitting leftover-sweep gate.  Mirrors C resolve.c:1402..1415 + resolve.c lookupName tail which always runs these promotions.  Remaining istrue-710 / istrue-800 are unrelated pre-existing failures (COLLATE-wrapped TK_TRUEFALSE in ExprTruthValue; bare TK_DOT not flagging "no such column" in IN-list).  No regression in --limit 50 (1 baseline FAIL = aggnested) or full Pascal regression (1 baseline FAIL = TestFuzzDiff).
  - [X] **9.4.divbug.87.040** `join5` — join5-3.1 (and 3.2) now PASS.  Root cause: Pas `lookupName`-equivalent resolver in codegen.pas (ResolveExpr + ResolveNestedFromDot) never set `EP_CanBeNull` on TK_COLUMN exprs whose matched SrcItem had `JT_LEFT|JT_LTORJ` — C resolve.c:509..511 does this unconditionally.  Without the flag, `sqlite3ExprCanBeNull` (expr.c:2982) returned 0 for `x2.b` (notNull=1) in the ON clause `x3.d = x2.b` of `x1 LEFT JOIN x2 LEFT JOIN x3 ON x3.d = x2.b`, so `codeAllEqualityTerms` (wherecode.c:976..981 → codegen.pas:62550..62555) skipped the `OP_IsNull regBase+j, addrBrk` skip-search guard.  The seek then used the post-NullRow NULL value of x2.b but the equality match against the auto-index for x3.d (NULLs) spuriously matched all three x3 rows.  Fix: added the C resolve.c:509 EP_CanBeNull set at all 6 main-resolver iTable assignment sites in ResolveExpr (qualified-DOT match, qualified-rowid, nested-from helper, TK_ROW pseudo, bare-TK_ID single match, bare-rowid).  Residual join5-5.2/5.3/5.4 and 7.x are unrelated (push-down + page-size-induced corrupt).
  - [X] **9.4.divbug.87.041** `join7` — join7-1.20 (and ~64 sibling tests across cases 1,2,3,5 / 1.20,1.30,1.40,1.60,1.80,1.81,1.100,1.101,1.115,1.120,1.140,1.141 + 10.x variants) now PASS.  join7.test error count dropped from 75 → 10 (residual 10 are unrelated "no such table: t1" — sub-tests *.70).  Root cause: in sqlite3WhereEnd's per-level index-rewrite block (codegen.pas:23036..23082 = where.c:7779..7886), Pas did NOT skip the OP_Column iTabCur→iIdxCur rewrite when `pLevel^.pRJ <> nil`.  C does (where.c:7745..7748: `if(pLevel->pRJ){ sqlite3WhereRightJoinLoop(...); continue; }`).  Effect: for `FULL OUTER JOIN t2 ON b=c` with index `t2c(c)`, Pas rewrote the addrSubrtn body's `Column iTabCur,0 → c-reg` to `Column iIdxCur(=t2c),0 → c-reg`.  In sqlite3WhereRightJoinLoop (codegen.pas:24475) the outer iIdxCur is OP_NullRow'd before the unmatched-rows sub-scan; the sub-scan repositions only the table cursor.  So during the unmatched pass, every result column served by the index came back NULL (e.g. `c=NULL` instead of 5 for the right-unmatched t2 row).  Fix at codegen.pas:23029..23048: gate pIdxR selection on `pLevel^.pRJ = nil`, mirroring C's early-continue.  Body OP_Column then stays against iTabCur, which the inner sub-WhereBegin's OP_DeferredSeek/table cursor positions correctly during the RJ unmatched-rows scan.  --limit 50 regression: only baseline aggnested FAIL.
  - [X] **9.4.divbug.87.042** `join9` — join9-1.200/1.201 (and ~5 sibling RIGHT-JOIN cases per case 1/2/3/4/5; total errors 175→170) now PASS.  Root cause: Pas bare-TK_ID lookup at codegen.pas:10116..10123 only ported the LEFT/INNER USING-coalesce arm of resolve.c:438..462 — when `cnt>0` and a *RIGHT JOIN* SrcItem matched the same USING column it `Inc(cnt)`d unconditionally, triggering "ambiguous column name: id" for `SELECT id ... FROM t5 NATURAL RIGHT JOIN t4 NATURAL LEFT JOIN t6`.  C resolve.c:453..457 instead clears cnt to use the right-most table.  Fix: split the existing test into RIGHT (JT_RIGHT & ~JT_LEFT: `cnt := 0` then fall through to Inc) vs LEFT/INNER (continue) arms, mirroring resolve.c:440..461.  FULL JOIN (.400+ NATURAL FULL) still ambig — needs extendFJMatch port (tracked separately).  Joins .300/.301 (RIGHT/RIGHT NATURAL) now reach codegen but order/value diverge — separate ORDER BY rowid bug.  --filter join: joinA 1287→1267, joinB 1395→1260, joinC 238→165, joinD 1482→1277 failed-assertions; no PASS→FAIL regressions.  --limit 50: baseline aggnested only.
  - [ ] **9.4.divbug.87.043** `joinC` — ! joinC-34 got: [15 15 15 15 15 15] (and ~24 sibling cases 34..56).  Triage (~1h, deferred): the failing pattern is `t1 INNER JOIN (t2 RIGHT JOIN (...) USING(a)) USING(a)`; expected `[11 11 - 11 11 - 15 15 15 15 15 15]` but unmatched-RHS rows are dropped because the outer USING-coalesced `a` of the (t2 RIGHT JOIN ...) FROM-subquery binds to t2.a (cursor 2) which becomes NULL on t2 NullRow, so the autoindex SeekGE on the outer t1.a=subq.a never matches.  C oracle reads `Column 3,0` (the inner subquery cursor) for the (join-3)'s first emitted column — i.e. the USING-coalesce flips to the right operand on RIGHT JOIN.  Pas expandStar (codegen.pas:26396..26560) pre-binds TK_COLUMN to (pItem.iCursor, j) so the resolver's USING-coalesce arm at codegen.pas:10131..10138 (already ported as part of .042) never fires for the materialized inner pEList of an SF_NestedFrom subquery.  Attempted minimal fix: re-target pColExpr to the right operand's cursor when (i<nSrc-1) and base[i+1] is USING+JT_RIGHT+~JT_LEFT — passes build but breaks outer `t2.a` resolution ("no such column: t2.a") because ResolveNestedFromDot walks pNestedFrom and now no item exposes column `a` under the t2 alias.  Proper fix requires either (a) full port of C's expandStar pattern: emit bare TK_ID at select.c:6260 (or TK_DOT under SF_NestedFrom) and let lookupName apply the USING-coalesce + extendFJMatch FULL-JOIN coalesce() builder; (b) keep the t2.a binding for metadata but synthesise a coalesce(t2.a, inner.a) wrapper expression for the materialized pEList value while preserving zEName='t2.a.a' for outer dotted-name resolution.  Both touch SF_NestedFrom + pNestedFrom + ResolveNestedFromDot interactions.  Deferred — same architectural cluster as the `extendFJMatch not yet ported` gap called out in 87.042.
  - [X] **9.4.divbug.87.044** `joinI` — joinI.test PASS (28/355). Already cured by the JOIN-cluster fixes in .040 (EP_CanBeNull on JT_LEFT/JT_LTORJ TK_COLUMN, resolve.c:509..511) and .041 (skip iTabCur→iIdxCur rewrite when pLevel^.pRJ<>nil, where.c:7745..7748). joinI-7.1 `[{} {} 555]` was the same RIGHT/LEFT-OUTER NullRow + index-rewrite class as join7-1.20. Verified with `--filter joinI.test` (PASS 28 0 fail). --limit 50 regression: baseline aggnested only, no new FAILs. No code change needed.
  - [X] **9.4.divbug.87.045** `limit` — limit-2.2 (`CREATE TABLE t2 AS SELECT * FROM t1 LIMIT 2; SELECT count(*) FROM t2`) now PASS.  Already cured by the .032..034 INSERT…SELECT + LIMIT cluster (SRT_Coroutine post-row DecrJumpZero at codegen.pas:33135..33140 + IDLIST pre-resolution + useTempTable IPK pre-load).  CTAS lowers to an INSERT…SELECT against the new table, which is the same coroutine path that previously ingested every source row on `LIMIT N`; the count of 32 (size of t1) collapsed to the expected 2 once the LIMIT decrement fired.  limit-2.1/2.2/2.3 verified PASS via `--filter limit.test`.  Residual limit.test failures (5.5, 7.x, 8.2/8.3, 10.x, 11.x) are unrelated clusters (page-size corrupt + compound-SELECT LIMIT error wording + ORDER BY descending — separate divbugs).  --limit 50 regression: baseline aggnested only.  No code change needed.
  - [ ] **9.4.divbug.87.046** `limit2` — ! limit2-100.{3,110.3,120.3} got: [0].  Triage (deferred — same architectural gap as 87.023/87.024): test computes `expr {$fast_count < 0.02*$slow_count}` where fast_count is sqlite_search_count for `SELECT a,b FROM t1 WHERE a IN (2,4,5,3,1) ORDER BY b LIMIT 5` and slow_count is the same with `ORDER BY +b` (blocks index-order LIMIT opt).  C oracle EQP picks `SEARCH t1 USING COVERING INDEX t1ab (a=?)` (IN-driven WO_IN equality probe in whereLoopAddBtreeIndex, where.c:3343..3409) so fast_count ≈ 50 vs slow_count ≈ 1004 (ratio 0.05 < 0.02 * slow).  Pas EQP picks `SCAN t1 USING COVERING INDEX t1ab + USE TEMP B-TREE FOR ORDER BY` for BOTH fast and slow → identical search_count → ratio ≈ 1.0 ≫ 0.02.  Root cause same as 87.023 / 87.024 deferred notes: Pas `whereLoopAddBtreeIndex` (codegen.pas:16770) never extends the index-key equality chain through WO_IN terms on the leading key column, so the IN-driven SEARCH plan is never costed.  Fix requires full port of where.c:3343..3409 IN-arm + whereLoopAddBtreeIndex recursion (deeper planner work, same as 87.023/87.024).  Deferred.
  - [X] **9.4.divbug.87.047** `lock` — lock-2.8b and lock-2.11b (sibling) now PASS.  Root cause: `PragTyp_BUSY_TIMEOUT` had a constant of 5 declared but **no case-arm handler** in sqlite3Pragma — it fell through to the "constant-default integer pragmas" stub at codegen.pas:52361 which hard-coded `iVal := 0`.  So `PRAGMA busy_timeout` always returned 0 (ignoring writes via `PRAGMA busy_timeout(N)`) and never reflected `sqlite3_busy_timeout(db, N)` Tcl-API calls (the test uses both: `db2 timeout 400` then expects 400 back, and `db2 eval {PRAGMA busy_timeout(400)}` then expects 400 back).  Fix at codegen.pas:52349..52364: added a proper PragTyp_BUSY_TIMEOUT arm (pragma.c:2651..2657) that on write SetString's zRight, atoi's it, and calls sqlite3_busy_timeout via a new `gBusyTimeout` hook (codegen.pas:3030 TBusyTimeoutFn — needed because codegen cannot `uses passqlite3main`); read arm always emits `OP_Integer db^.busyTimeout / OP_ResultRow`.  Hook wired in passqlite3main.pas:6229..6234 initialization.  Removed the stale `else if SameText(zName, 'busy_timeout') then iVal := 0` from the constant-default block.  lock.test FAIL count 6→2 (residual lock-7.2 `db filename {main,shared,temp,unknown}` returns empty — separate cluster, db filename multi-arg unsupported).  --limit 50: baseline aggnested only, no regression.
  - [X] **9.4.divbug.87.048** `lock7` — lock7.test now PASS (8/0 fail).  Root cause: `PRAGMA lock_status` had `PragTyp_LOCK_STATUS = 44` declared but (a) no entry in the `aPragmaName[]` lookup table and (b) no case-arm in sqlite3Pragma — `pragmaLocate('lock_status')` returned nil so the pragma was silently dropped, the prepared statement produced zero rows, and the Tcl `execsql` returned `[]` instead of `{main unlocked temp closed}`.  Fix: added the missing `aPragmaName[]` entry between `legacy_alter_table` and `locking_mode` (codegen.pas:51459..51462, ColNames slot 53='database'/54='status' per pragma.h:411..415, gated SQLITE_DEBUG||SQLITE_TEST in C, always-on here), bumped array bound 0..65 → 0..66, and added the matching `PragTyp_LOCK_STATUS` case arm (codegen.pas:51994..52022) porting pragma.c:2743..2764 — walks db^.aDb, classifies each as 'closed' (pBt=nil or no pager), 'unknown' (fctl rc<>OK), or one of {unlocked,shared,reserved,pending,exclusive} via `sqlite3OsFileControl(sqlite3PagerFile(sqlite3BtreePager(pBt)), SQLITE_FCNTL_LOCKSTATE)`.  Inlined the file-control path (rather than calling `sqlite3_file_control` which lives in passqlite3main and would be a circular `uses`) — codegen already uses passqlite3pager+passqlite3os.  Added const-pool `azLockName` array at codegen.pas:51697..51699.  --filter lock7.test: PASS 8/0 fail (was 4 errors out of 8).  --limit 50 regression: baseline aggnested only.
  - [ ] **9.4.divbug.87.049** `minmax` — ! minmax-1.6 got: [19] (and -2.1/-2.3/-3.1/-3.3/-6.4/-6.6/-6.7 sibling regressions).  Triage (deferred — same architectural gap as 87.043 BIGNULL two-pass codegen).  Root cause: `SELECT min(x) FROM t1` on nullable column `x` with index `t1i1(x)` should ride the min/max early-out (`sqlite3WhereMinMaxOptEarlyOut` → Goto past Next loop), search_count=1 (1 seek).  Pas instead full-scans the covering index, search_count=19.  Trace (probe `SELECT min(x) FROM t1`, t1=2 rows): `wherePathSatisfiesOrderBy` (codegen.pas:19150) matches j=0/iColumn=0 against pOBExpr (TK_AGG_COLUMN op=170, iTable=0/iCol=0, BINARY=BINARY coll), isMatch=1, then **the BIGNULL refusal arm at codegen.pas:19410..19425 resets isMatch=0** because `minMaxQuery` (codegen.pas:28043..28044) sets `sortFlags := KEYINFO_ORDER_BIGNULL` when `sqlite3ExprCanBeNull(arg)<>0`.  Result: pFrom.isOrdered=0, pWInfo.nOBSat=0, bOrderedInnerLoop=0, `sqlite3WhereMinMaxOptEarlyOut` (codegen.pas:14746) early-Exits, no Goto emitted, full scan.  C oracle differs at where.c:5425..5430 — when `j == pLoop->u.btree.nEq` (no preceding equality terms), C **sets `pLoop->wsFlags |= WHERE_BIGNULL_SORT` and keeps isMatch=1**, only refuses when `j != nEq`.  C then emits the BIGNULL two-pass codegen at wherecode.c:1933..1953+2030..2086+2134..2164 + where.c:7616..7620 (`Null regBase; Integer 1 regCounter; SeekGT cur,fail,regBase,1; Goto body; Rewind cur,fail; If counter,body; IdxGT cur,fail,regBase,1; Column; AggStep; Goto early; Next cur,body,1; DecrJumpZero counter,addrRewind`).  The divbug.43 deferral note at codegen.pas:19412..19424 explicitly chose conservative refusal until the two-pass codegen lands.  Fix requires porting the two-pass codegen (WHERE_BIGNULL_SORT honour) — substantial wherecode.c work, deferred as the cluster .43 + .87.049/050 root.  Probe details: ../sqlite3/test/minmax.test:70..72 reads `sqlite_search_count` after CREATE INDEX + SELECT min(x); the SELECT result is correct (1), only the visit-count diverges.
  - [ ] **9.4.divbug.87.050** `minmax2` — ! minmax2-1.6 got: [19] (and -2.1/-2.3/-3.1/-3.3/-6.4/-6.6/-6.7 sibling regressions).  **Shared root cause with 87.049** — identical test shape with `CREATE INDEX t1i1 ON t1(x DESC)` (descending) instead of ascending.  C oracle still picks the index-driven min/max plan (now with revIdx=1 in the BIGNULL arm).  Pas wherePathSatisfiesOrderBy hits the same KEYINFO_ORDER_BIGNULL refusal at codegen.pas:19410..19425 because `minMaxQuery` sets BIGNULL whenever `sqlite3ExprCanBeNull(arg)<>0`, regardless of index direction.  Fix is identical to 87.049 (port BIGNULL two-pass codegen).  Both cured by a single landing of the WHERE_BIGNULL_SORT honour at where.c:5425..5430 + wherecode.c BIGNULL emit arms.
  - [ ] **9.4.divbug.87.051** `minmax3` — ! minmax3-1.2.3 got: [II 5] (and siblings 1.2.4, 1.3.2, 1.3.3).  Triage (deferred — **same architectural gap as 87.049/87.050 BIGNULL two-pass codegen cluster**).  Test: `SELECT min(y) FROM t1 WHERE x='2'` with `CREATE INDEX i2 ON t1(x,y)` should ride min/max early-out (1 seek → search_count=1) but Pas gives 5 (full equality range scan).  C oracle: where.c:5425..5430 sets `WHERE_BIGNULL_SORT` and keeps `isMatch=1` when `j == pLoop->u.btree.nEq` (here j=1 for the trailing `y` MIN column, nEq=1 for the `x='2'` equality); wherecode.c:1933..1953+2030..2086+2134..2164 then emits the two-pass `Null/Integer/SeekGT/Goto-body/Rewind/If/IdxGT/Column/AggStep/Goto-early/Next/DecrJumpZero` template that early-exits after the first non-NULL.  Pas wherePathSatisfiesOrderBy at codegen.pas:19410..19425 instead resets `isMatch=0` on the KEYINFO_ORDER_BIGNULL sortFlag set by `minMaxQuery` (codegen.pas:28043..28044) whenever `sqlite3ExprCanBeNull(y)<>0`, so pWInfo.nOBSat=0 and `sqlite3WhereMinMaxOptEarlyOut` (codegen.pas:14746) early-Exits without emitting the Goto, causing the full equality-range scan.  Fix is the same single landing as 87.049/050: port `WHERE_BIGNULL_SORT` honour at where.c:5425..5430 + wherecode.c BIGNULL emit arms.  Sibling minmax3-1.2.4 (DESC y), 1.3.2 (no WHERE, ASC), 1.3.3 (no WHERE, DESC) all collapse to the same gap.  minmax3-4.x are a separate cluster (NOCASE collation min/max — `[abc BCD]` vs `[BCD abc]` swap) and are NOT this divbug.  Deferred.
  - [X] **9.4.divbug.87.052** `misc2` — misc2-1.2 (BEFORE-INSERT trigger `SELECT CASE WHEN ... THEN RAISE(ROLLBACK,'aiieee') END`) now PASS.  Three interlocking bugs:  (1) **No TK_RAISE arm in codegen** — `sqlite3ExprCodeTarget` fell through to default `OP_Null` for TK_RAISE expressions, so `RAISE(ROLLBACK,'aiieee')` inside any trigger body emitted no opcodes (silently no-op).  Ported expr.c:5727..5752 at codegen.pas:6567..6601 (TK_RAISE arm): outside trigger sub-program raises "RAISE() may only be used within a trigger-program"; inside, OE_Ignore emits `OP_Halt SQLITE_OK, OE_Ignore` and OE_Rollback/Abort/Fail emit `OP_Halt SQLITE_CONSTRAINT_TRIGGER, affExpr, regMsg` after coding pLeft into regMsg via `sqlite3ExprCodeTemp`; OE_Abort also calls `sqlite3MayAbort(pParse)`.  (2) **No-FROM fast path gate excluded SRT_Discard** — `sqlite3Select` at codegen.pas:29685..29707 bailed early with SQLITE_OK for any eDest not in {Output,Set,Mem,EphemTab,Coroutine,Fifo,DistFifo,Queue,DistQueue,Upfrom,Exists}; the trigger SELECT step uses SRT_Discard (codeTriggerProgram at codegen.pas:35357), so the result-list (including RAISE) was never coded.  Added SRT_Discard to the gate AND to the no-FROM fast-path destination set (codegen.pas:29875) AND added an explicit SRT_Discard no-op dispatch arm at codegen.pas:29977..29985 (mirrors selectInnerLoop's SRT_Discard arm at select.c:1377..1380) so the fast-path's else-arm doesn't fall through to the SRT_EphemTab MakeRecord/NewRowid/Insert template.  (3) **OP_Program frame mis-sized nProgMem** — vdbe.pas:11124..11125 computed `nProgMem := nMem + nCsr; if nProgMem=0 then nProgMem:=1;` but C vdbe.c:7521..7523 is `nMem += nCsr; if pProgram->nCsr==0 nMem++` — the bump is gated on nCsr=0, NOT nProgMem=0.  With our fix in place the trigger body now allocates real registers (nMem=1) but nCsr=0; nProgMem stayed at 1 so `v^.apCsr := @aMem[nMem]` collided with `aMem[1]` and the first OP_Integer/OP_String8 write trashed the apCsr region → "malloc(): corrupted top size" on commit.  Fixed at vdbe.pas:11124..11129 to mirror C: `if pProgSub^.nCsr = 0 then Inc(nProgMem)`.  Verified misc2-1.2 PASS; --filter misc2.test now fails later (misc2-2.2 — separate `SELECT rowid, * FROM (SELECT...)` subquery-rowid cluster, unrelated).  Full Pascal regression: 100 binaries pass, 1 baseline TestFuzzDiff fail; 8 TclTestDriver binaries that previously failed now pass.  --limit 50: baseline aggnested only.
  - [X] **9.4.divbug.87.053** `misc3` — misc3-6.11-utf8 now PASS.  Root cause: parser arm 37 `ccons ::= DEFAULT scantok ID|INDEXED` at passqlite3parser.pas:2965..2972 called `sqlite3ExprAlloc(..., TK_STRING, ..., 0)` with `dequote=0`, so a `DEFAULT "hello"` clause stored the literal token text `"hello"` (with embedded double-quotes) into the DEFAULT expression's `u.zToken`.  C oracle parse.y:400..407 routes this through `tokenExpr(pParse, TK_STRING, X)` which **always dequotes** (parse.y:1160..1162).  The leaked quotes then surfaced in OP_Column P4_MEM rendering during EXPLAIN as `"hello"` instead of `hello`, breaking the `regexp { hello } $x` check in misc3-6.11-utf8.  Fix: change the last arg of sqlite3ExprAlloc from `0` to `1` (matches C tokenExpr semantics — sqlite3ExprAlloc dequotes when first char is one of `" ' [ \``).  After fix, the wrapping TK_SPAN node's u.zToken still contains the verbatim source `"hello"` (correct — it's the source-text span for ALTER/EXPLAIN recovery), but the inner TK_STRING's u.zToken is dequoted to `hello`, which is what valueFromExpr converts to the P4_MEM Mem value.  Full regression clean: --limit 50 baseline aggnested only.
  - [X] **9.4.divbug.87.054** `misc4` — misc4-1.2.1 (and siblings 1.2.2, 1.3, 1.4, 1.5, 1.6) now PASS.  Root cause: Pas `sqlite3StepInternal` (passqlite3vdbe.pas:5938..5960) lacked the expired-stmt short-circuit at the READY→RUN transition that C's `sqlite3Step` (vdbeapi.c:779..792) performs unconditionally.  When a `BEGIN; CREATE TABLE; ...; ROLLBACK;` cycle bumps DBFLAG_SchemaChange (OP_SetCookie at vdbe.c:4265 → Pas vdbe.pas:10831) the ROLLBACK path (`sqlite3RollbackAll`, vdbe.pas:7647..7664) correctly calls `sqlite3ExpirePreparedStatements(db, 0)` which sets `VDBF_EXPIRED_MASK=1` on every Vdbe in `db^.pVdbe`.  C then makes `sqlite3_step` on the expired stmt set `p->rc = SQLITE_SCHEMA` and return `SQLITE_ERROR` *before* counter bumps / pc reset / VdbeExec dispatch — so `sqlite3_finalize` (which returns `p->rc` via `sqlite3VdbeReset`) reports SCHEMA while the step itself reports ERROR.  Without the gate Pas instead ran the prepared `CREATE TEMP TABLE t2 AS SELECT * FROM t1` straight through, returned DONE, and the *next* test prep (`sqlite3_prepare` of the same SQL) failed with "table t2 already exists" because the stmt was never supposed to execute.  Fix at passqlite3vdbe.pas:5939..5957: pre-READY arm checks `(eVdbeState=READY) and (vdbeFlags and VDBF_EXPIRED_MASK)<>0`, sets `pStmt^.rc := SQLITE_SCHEMA`, defaults `rc := SQLITE_ERROR`, and only when `SQLITE_PREPARE_SAVESQL` is set does it override via `sqlite3VdbeTransferError` (mirrors vdbeapi.c:783..790).  Routes through `db^.errMask` fold before returning.  misc4-3.1 fails next (pre-existing: `aggregate functions are not allowed in the GROUP BY clause` not raised for `GROUP BY 1, 2` — separate resolver gap, not this divbug).  --limit 50: baseline aggnested only, no regression.
  - [ ] **9.4.divbug.87.055** `misc5` — ! misc5-3.1 got: [] (deferred — architectural: DISTINCT+Aggregate codegen gap).  Root cause: both the aggregate-no-GROUP-BY arm (codegen.pas:31310..31317) and the GROUP-BY-aggregate arm (codegen.pas:30136..30137) gate on `(selFlags and (SF_Distinct or SF_Compound)) = 0`, so **any** `SELECT DISTINCT <agg>` or `SELECT DISTINCT <cols>, <agg> ... GROUP BY ...` falls through every later arm and `sqlite3Select` returns SQLITE_OK without coding any opcodes -> bytecode is bare Init/Halt/Goto and the stmt yields zero rows.  Minimal repro: `CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3); SELECT DISTINCT sum(x) FROM t;` returns [] (should be [6]).  Drilling into misc5-3.1: the deeply-nested query bottoms out in `SELECT DISTINCT artist, sum(timesplayed) AS total FROM songs GROUP BY LOWER(artist) ORDER BY total DESC LIMIT 10` which returns []; everything above it then chains to [].  Test header explicitly notes the result is indeterminate (one/two/three all valid) but Pas gives [] instead of any of them.  C oracle select.c:8142..8263 sets `sDistinct.isTnct = (selFlags & SF_Distinct)!=0`, runs the agg path unchanged, then at 8253..8263 opens an ephemeral KEYINFO index (`sDistinct.tabTnct`, eTnctType=WHERE_DISTINCT_UNORDERED) and selectInnerLoop's ResultRow body (select.c:1218..1240) does `OP_Found jump-if-already-seen / IdxInsert otherwise` before emitting ResultRow.  For aggregate-no-GROUP-BY case DISTINCT is **always** trivially redundant (one row) -- could be cheaply stripped (mirror codegen.pas:29847..29865's no-FROM strip) but doesn't help misc5-3.1.  For GROUP-BY-agg case (misc5-3.1 inner shape), would need either: (a) port C's distinct-ephem-table + per-row Found/IdxInsert gate into the GROUP-BY agg emit body (codegen.pas:~30150..30900 -- substantial, needs sDistinct.tabTnct/addrTnct allocation + selectInnerLoop ResultRow rewrite); OR (b) port `isDistinctRedundant`-style analysis to drop SF_Distinct when GROUP BY keys are a superset of result-set (where.c:636 is already ported at codegen.pas:17444 but never invoked from the codegen agg gates).  Path (b) is the smaller change but still ~hour because the redundancy check needs the resolved column-set comparison + GroupBy-keys-cover-result-set logic.  Deferred to a DISTINCT-codegen cluster fix (likely also affects siblings in other tests).  Infrastructure already present: WHERE_DISTINCT_* constants, isDistinctRedundant (codegen.pas:17444), and the no-FROM DISTINCT-strip precedent (codegen.pas:29859..29865, divbug.87.020).
  - [ ] **9.4.divbug.87.056** `mmapwarm` — ! mmapwarm-1.0 expected: [507], Pas got: [506], C-sqlite3 reference (via stdin redirect) got: [127].  Triage (deferred — **two unrelated gaps**: per-row leaf-page packing + missing `sqlite3_mmap_warm` Tcl command).  (1) **Page-count divergence is environmental + a packing bug**.  Test source ../sqlite3/test/mmapwarm.test:29..38 creates 500 rows of `(randomblob(400), randomblob(500))` after `PRAGMA auto_vacuum=0` and asserts `PRAGMA page_count == 507`.  The expected `507` assumes a page_size of 1024 (historical testfixture default).  With the current SQLITE_DEFAULT_PAGE_SIZE=4096 (sqliteLimit.h:213..214) C-sqlite3 packs ~4 rows/leaf via overflow chains for a count of 127.  Pas instead emits **one page per row** (506) — each ~900-byte row spills its entire payload to overflow despite maxLocal≈1024 on a 4096 page.  Stale log showed [127] (matches C) because pre-.032-.034 the INSERT…SELECT cluster bug truncated the CTE early at 125 rows × 1 leaf-page each ≈ 127 pages; now CTE delivers all 500 rows, exposing the packing bug.  Root cause likely in `btreeComputeFreeSpace`/`fillInCell` payload-threshold math at passqlite3btree.pas:859..895 (`surplus := minLocal + (nPayload-minLocal) mod (usableSize-4)`); C btree.c:1131..1147 same algebra but Pas signed/u16 mixing around lines 859..869 may cause the `surplus <= maxLocal` branch to mis-fire for nPayload=903 (after rowid+hdr), driving nLocal=minLocal (~50) and the rest to overflow → one overflow chain per row but those overflow pages also get one row each since the leaf cell is full.  Even with a packing fix, mmapwarm-1.0 still won't match [507] without forcing `PRAGMA page_size=1024` (test relies on legacy default).  (2) **Tests 1.1–3.x fail with `invalid command name "sqlite3_mmap_warm"`** — the Tcl-side helper backing `sqlite3_test_mmap_warm` (sqlite3.c `sqlite3_test_control(SQLITE_TESTCTRL_*)` + tclsqlite.c `Sqlitemmapwarm_Init` / `sqlite3_mmap_warm` exposure) is not wired in `bin/libpassqlite3tcl.so`.  Need to (a) port `sqlite3_mmap_warm(db, zSchema)` from main.c (~30 lines: walk pager pages, sqlite3PagerGet+PagerUnref to pre-fault mmap), and (b) register it in the Pas Tcl binding alongside the existing test commands.  Faultsim test 3 also requires `do_faultsim_test` infra (oom* faults) which is a much larger gap.  Both 1.0 packing + sqlite3_mmap_warm wiring deferred — neither is a 45-min fix; sqlite3_mmap_warm + page_size=1024 test override would clear 1.1/1.2/1.3/1.4/2.0 but 1.0 needs the btree packing investigation independently.
  - [X] **9.4.divbug.87.057** `notnullfault` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.058** `null` — null-6.4 now PASS.  Root cause: Pascal `ResolveExpr` TK_DOT arm (codegen.pas:10022..10134) only matched the 2-part shape `TK_DOT(TK_ID, TK_ID)` and fell through to the "no such column" error for the 3-part `db.tab.col` shape `TK_DOT(TK_ID, TK_DOT(TK_ID, TK_ID))` that the parser emits for `main.t1.b`.  C's `sqlite3ResolveExprNames` TK_DOT arm (resolve.c:1083..1107) peels the inner TK_DOT into zDb/zTable/zColumn then calls `lookupName(pParse, zDb, zTable, pRight, …)`; lookupName at resolve.c:309..337 looks up the schema by name (with the "main" alias fallback at :330..335) and at :420..425 skips SrcItems whose `pTab->pSchema` doesn't match.  In the resolveCompoundOrderBy path (resolve.c:1644..1652) the failure of resolveOrderByTermToExprList → sqlite3ResolveExprNames left iOrderByCol=0 so the term raised the matching-error tail at :1682.  Fix at codegen.pas:10022..10074: pre-arm checks for the 3-part shape, walks `pParse^.db^.aDb[]` matching `zDbSName` case-insensitively (with the "main"→aDb[0] alias) to obtain pDbSchema, then collapses pE in place to the 2-part shape (drops the outer pLeft/pRight wrappers) and threads pDbSchema into the per-SrcItem loop with a `pItem^.pSTab^.pSchema <> pDbSchema → Continue` filter (mirrors resolve.c:420..425).  Unknown schema names still hit the original "no such column" tail.  null.test now 41 PASS.  --limit 50: baseline aggnested only, no regression.
  - [ ] **9.4.divbug.87.059** `nulls1` — ! nulls1-5.3 got: TEMP B-TREE plan (deferred — same BIGNULL_SORT cluster as .043/.049/.050/.051).  Test issues `SELECT * FROM t4 WHERE a IN (1,2,3) ORDER BY a, b NULLS LAST` over `CREATE INDEX t4ab ON t4(a,b)`; expected EQP is `SEARCH t4 USING INDEX t4ab (a=?)` (index satisfies the ORDER BY).  Pas emits `SCAN t4 USING INDEX t4ab` + `USE TEMP B-TREE FOR LAST TERM OF ORDER BY` because wherePathSatisfiesOrderBy (codegen.pas:19486..19488) explicitly refuses any isMatch when `KEYINFO_ORDER_BIGNULL` is set on an ORDER BY term — see divbug.43's deferral comment at 19489..19494.  C planner (where.c:5425..5430) keeps isMatch=1 and flags WHERE_BIGNULL_SORT, then wherecode.c:1933..1953 + 2030..2086 + 2134..2164 + where.c:7616..7620 emit the two-pass NULL-then-non-NULL scan around regBignull/addrSeekScan.  Pas codegen.pas:23744 still asserts `(pLoop^.wsFlags and WHERE_BIGNULL_SORT) = 0` — substantial port needed.  Same gap blocks nulls1-5.5 (DESC NULLS FIRST mirror), nulls1-6.1.2 & 6.2.2 (t5 covering index), and nulls1-9.3 (returns half the rows — NULL-partition skipped on first pass).  Awaits BIGNULL_SORT codegen cluster fix (.043/.049/.050/.051 root).
  - [ ] **9.4.divbug.87.060** `orderby5` — ! orderby5-3.0 got: [4 0 59 {SEARCH t3 USING INDEX t3bcde (b=? AND c=?)} 18 0 0 {USE TEMP B-TREE FOR LAST TERM OF ORDER BY}]
  - [ ] **9.4.divbug.87.061** `orderbyA` — ! orderbyA-1.1.2.1.1 got: [1]
  - [ ] **9.4.divbug.87.062** `quickcheck` — ! quickcheck-1.0 error: table t1 has 3 columns but 2 values were supplied
  - [ ] **9.4.divbug.87.063** `resolver01` — ! resolver01-3.5 got: [1 {no such column: yy}]
  - [ ] **9.4.divbug.87.064** `rowhash` — SOURCE-ERROR: database disk image is malformed
  - [ ] **9.4.divbug.87.065** `savepoint6` — ! savepoint6-normal.8.2 error: database disk image is malformed
  - [ ] **9.4.divbug.87.066** `securedel` — ! securedel-1.0 got: [0]
  - [ ] **9.4.divbug.87.067** `tkt2920` — ! tkt2920-1.3 got: [0 {}]
  - [ ] **9.4.divbug.87.068** `tkt3442` — ! tkt3442-1.3 error: no such column: "5000" - should this be a string literal in single-quotes?
  - [ ] **9.4.divbug.87.069** `tkt3718` — ! tkt3718-2.2 got: [1 2 3 4 5 6 7 8 9 10 11 12]
  - [ ] **9.4.divbug.87.070** `transitive1` — ! transitive1-410 got: []
  - [ ] **9.4.divbug.87.071** `upfrom1` — ! upfrom1-1.1.4 got: [1 {} {} 4 5 6 7 {} {}]
  - [X] **9.4.divbug.87.072** `upsert1` — ! upsert1-200 got: [1 {ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint}].  Fixed: `sqlite3CreateIndex` per-column loop was gating `sqlite3StringToId` + `sqlite3ResolveSelfReference(..NC_IdxExpr..)` on `db^.init.busy = 0`; C build.c:4217..4219 runs both UNCONDITIONALLY.  On schema reload from sqlite_master the expression-index `aColExpr` retained raw TK_ID/TK_STRING tokens, so `sqlite3UpsertAnalyzeTarget` (upsert.c:181 → sqlite3ExprCompare) compared the upsert target's resolved TK_COLUMN(a+b) against the index's unresolved TK_ID(a)+TK_ID(b) and never matched → spurious "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint".  upsert1-200/-201 now PASS; upsert3.test also flips to PASS (related divbug.74).  Residual: upsert1-400 (count_changes), upsert1-800 (disk image malformed) — separate root causes unrelated to expression-index resolution.
  - [ ] **9.4.divbug.87.073** `upsert4` — ! upsert4-1.1.7 got: [1 {} one 2 {} {} 3 {} three]
- [ ] **9.4.divbug.88** Tcl-bridge command/subcommand long-tail (carved from `9.4.4.g-unbucketed` 2026-05-16) — **62 pas-soft tests** still hit bridge gaps after `9.4.divbug.62/.63/.64/.65` closed the high-frequency surface.  Subdivided into `invalid/unknown command` (55: `badutf2`, `bindxfer`, `cacheflush`, `capi3d`, …) and `unknown subcommand "null"` / `db <other-subcmd>` (7: `indexexpr1`, `joinH`, `join`, `json102`, …).  Port the remaining `db ?subcommand?` and top-level Tcl-bridge entry points until the cluster drains.
  - [ ] **9.4.divbug.88.001** `badutf2` — ! badutf2-4.0 error: invalid command name "sqlite3_expired"
  - [ ] **9.4.divbug.88.002** `bindxfer` — ! bindxfer-1.5 error: invalid command name "sqlite_bind"
  - [ ] **9.4.divbug.88.003** `cacheflush` — ! cacheflush-1.1.2 error: invalid command name "sqlite3_db_cacheflush"
  - [ ] **9.4.divbug.88.004** `capi3d` — SOURCE-ERROR: invalid command name "sqlite3_prepare16"
  - [ ] **9.4.divbug.88.005** `capi3e` — ! capi3e-1.1.1 error: invalid command name "sqlite3_open"
  - [ ] **9.4.divbug.88.006** `chunksize` — SOURCE-ERROR: invalid command name "file_control_chunksize_test"
  - [ ] **9.4.divbug.88.007** `cksumvfs` — SOURCE-ERROR: invalid command name "sqlite3_register_cksumvfs"
  - [ ] **9.4.divbug.88.008** `close` — ! close-1.1 error: invalid command name "sqlite3_open"
  - [ ] **9.4.divbug.88.009** `collate7` — ! collate7-1.1 error: invalid command name "sqlite3_create_collation_v2"
  - [ ] **9.4.divbug.88.010** `colname` — ! colname-2.1 error: invalid command name "execsql2"
  - [ ] **9.4.divbug.88.011** `corrupt` — ! corrupt-2.1.8 error: invalid command name "btree_from_db"
  - [ ] **9.4.divbug.88.012** `corrupt2` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.013** `corrupt3` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.014** `corrupt4` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.015** `corrupt6` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.016** `corrupt7` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.017** `corruptE` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.018** `corruptG` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.019** `corruptH` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.020** `corruptI` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.021** `corruptJ` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.022** `corruptK` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.023** `corruptN` — ! corruptN-1.0 error: invalid command name "decode_hexdb"
  - [ ] **9.4.divbug.88.024** `dataversion1` — SOURCE-ERROR: invalid command name "file_control_data_version"
  - [ ] **9.4.divbug.88.025** `delete_db` — SOURCE-ERROR: invalid command name "sqlite3_multiplex_initialize"
  - [ ] **9.4.divbug.88.026** `e_createtable` — SOURCE-ERROR: invalid command name "do_select_tests"
  - [ ] **9.4.divbug.88.027** `e_dropview` — SOURCE-ERROR: invalid command name "do_select_tests"
  - [ ] **9.4.divbug.88.028** `e_reindex` — SOURCE-ERROR: invalid command name "do_select_tests"
  - [ ] **9.4.divbug.88.029** `e_select2` — SOURCE-ERROR: invalid command name "drop_all_tables"
  - [ ] **9.4.divbug.88.030** `e_update` — SOURCE-ERROR: invalid command name "do_select_tests"
  - [ ] **9.4.divbug.88.031** `e_uri` — SOURCE-ERROR: invalid command name "sqlite3_close"
  - [ ] **9.4.divbug.88.032** `e_wal` — SOURCE-ERROR: invalid command name "testvfs"
  - [ ] **9.4.divbug.88.033** `e_walauto` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.034** `enc3` — SOURCE-ERROR: invalid command name "sqlite3_enable_shared_cache"
  - [ ] **9.4.divbug.88.035** `errmsg` — SOURCE-ERROR: invalid command name "verify_ex_errcode"
  - [ ] **9.4.divbug.88.036** `fallocate` — SOURCE-ERROR: invalid command name "file_control_chunksize_test"
  - [ ] **9.4.divbug.88.037** `filectrl` — ! filectrl-1.1 error: invalid command name "file_control_test"
  - [ ] **9.4.divbug.88.038** `filefmt` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.039** `hook` — SOURCE-ERROR: invalid command name "verify_ex_errcode"
  - [ ] **9.4.divbug.88.040** `indexexpr1` — SOURCE-ERROR: unknown subcommand "null" - implemented in 9.4.2.d..o
  - [ ] **9.4.divbug.88.041** `interrupt2` — SOURCE-ERROR: invalid command name "testvfs"
  - [ ] **9.4.divbug.88.042** `ioerr` — SOURCE-ERROR: invalid command name "sqlite3_get_autocommit"
  - [ ] **9.4.divbug.88.043** `join` — SOURCE-ERROR: unknown subcommand "null" - implemented in 9.4.2.d..o
  - [ ] **9.4.divbug.88.044** `joinH` — SOURCE-ERROR: unknown subcommand "null" - implemented in 9.4.2.d..o
  - [ ] **9.4.divbug.88.045** `json102` — SOURCE-ERROR: unknown subcommand "null" - implemented in 9.4.2.d..o
  - [ ] **9.4.divbug.88.046** `json502` — SOURCE-ERROR: unknown subcommand "null" - implemented in 9.4.2.d..o
  - [ ] **9.4.divbug.88.047** `laststmtchanges` — ! laststmtchanges-1.2.1 error: invalid command name "sqlite3_exec_printf"
  - [ ] **9.4.divbug.88.048** `lock5` — SOURCE-ERROR: invalid command name "db2"
  - [ ] **9.4.divbug.88.049** `main` — ! main-1.1 error: unknown subcommand "complete" - implemented in 9.4.2.d..o
  - [ ] **9.4.divbug.88.050** `memsubsys1` — SOURCE-ERROR: invalid command name "sqlite3_config_lookaside"
  - [ ] **9.4.divbug.88.051** `memsubsys2` — SOURCE-ERROR: invalid command name "sqlite3_config_memstatus"
  - [ ] **9.4.divbug.88.052** `misc6` — ! misc6-1.1 error: invalid command name "sqlite_bind"
  - [ ] **9.4.divbug.88.053** `misuse` — SOURCE-ERROR: invalid command name "clang_sanitize_address"
  - [ ] **9.4.divbug.88.054** `mjournal` — SOURCE-ERROR: invalid command name "testvfs"
  - [ ] **9.4.divbug.88.055** `multiplex4` — SOURCE-ERROR: invalid command name "sqlite3_multiplex_initialize"
  - [ ] **9.4.divbug.88.056** `nan` — SOURCE-ERROR: invalid command name "nonzero_reserved_bytes"
  - [ ] **9.4.divbug.88.057** `nolock` — SOURCE-ERROR: invalid command name "testvfs"
  - [ ] **9.4.divbug.88.058** `normalize` — ! normalize-100 error: invalid command name "sqlite3_normalize"
  - [ ] **9.4.divbug.88.059** `notnull2` — SOURCE-ERROR: invalid command name "do_vmstep_test"
  - [ ] **9.4.divbug.88.060** `trans3` — ! trans3-1.3.1 error: invalid command name "sqlite3_get_autocommit"
  - [ ] **9.4.divbug.88.061** `upfrom4` — SOURCE-ERROR: unknown subcommand "null" - implemented in 9.4.2.d..o
  - [ ] **9.4.divbug.88.062** `varint` — ! varint-1.1 error: invalid command name "btree_varint_test"
- [ ] **9.4.divbug.89** Empty driver diagnostic (carved from `9.4.4.g-unbucketed` 2026-05-16) — **12 pas-soft tests** (`corruptB`, `e_changes`, `e_totalchanges`, `fuzz`, `index4`, `index5`, `join6`, `joinA`, `joinB`, `joinD`, `manydb`, `tkt3080`) FAIL but `bin/tcl-failure-logs/<base>.{err,out}` capture no diagnostic — driver swallows the message or the tests abort outside `tcltest`.  Action: instrument `TclTestDriver` to dump the last N lines of stdout/stderr on any non-PASS exit so these become triageable.
  - [ ] **9.4.divbug.89.001** `corruptB` — malformed}]
  - [ ] **9.4.divbug.89.002** `e_changes` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.003** `e_totalchanges` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.004** `fuzz` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.005** `index4` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.006** `index5` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.007** `join6` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.008** `joinA` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.009** `joinB` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.010** `joinD` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.011** `manydb` — (UNKNOWN-empty-log, no log captured)
  - [ ] **9.4.divbug.89.012** `tkt3080` — SOURCE-ERROR:
- [ ] **9.4.divbug.90** Extension / SQL function / VFS registration residue (sibling of `9.4.divbug.66`, carved from `9.4.4.g-unbucketed` 2026-05-16) — **8 pas-soft tests**: 6 `no such extension` (`btree02`, `extension01`, `func4`, `indexexpr2`, …), 1 `no such function` (`func9`), 1 `no such vfs: devsym` (`io`).  Each pin in the C build is a known extension/function/VFS shim; port or auto-register at db-open following the `.66` template.
  - [ ] **9.4.divbug.90.001** `btree02` — SOURCE-ERROR: no such extension: eval
  - [ ] **9.4.divbug.90.002** `extension01` — SOURCE-ERROR: no such extension: fileio
  - [ ] **9.4.divbug.90.003** `func4` — SOURCE-ERROR: no such extension: totype
  - [ ] **9.4.divbug.90.004** `func9` — ! func9-210 error: no such function: unistr_quote
  - [ ] **9.4.divbug.90.005** `indexexpr2` — SOURCE-ERROR: no such extension: explain
  - [ ] **9.4.divbug.90.006** `io` — SOURCE-ERROR: no such vfs: devsym
  - [ ] **9.4.divbug.90.007** `memdb` — ! memdb-7.1 error: no such extension: wholenumber
  - [ ] **9.4.divbug.90.008** `misc8` — SOURCE-ERROR: no such extension: eval
- [ ] **9.4.divbug.91** Tcl harness helper gaps (carved from `9.4.4.g-unbucketed` 2026-05-16) — **16 pas-soft tests** on missing test-harness plumbing (engine behaviour not exercised): `md5sum` Tcl command (5: `backup_ioerr`, `backup`, `fuzz3`, `interrupt`, …); arbitrary missing tclvars (4: `join3`, `savepoint2`, `tkt3992`, `types`); `cmdlinearg(soft-heap-limit)` array (2: `avtrans`, `capi3b`); `SQLITE_MAX_VARIABLE_NUMBER` tcl-const (1: `bind`); `QRF not available in this build` build-flag gap (2: `qrf01`, `qrf02`); `no files matched glob "*malloc*.test"` (1: `mallocAll`); `couldn't read file "-"` stdin input (1: `memleak`).  Wire each helper in `tester_min.tcl` (or upstream the missing testfixture commands) to drain the cluster.
  - [ ] **9.4.divbug.91.001** `avtrans` — SOURCE-ERROR: can't read "cmdlinearg(soft-heap-limit)": no such variable
  - [ ] **9.4.divbug.91.002** `backup` — SOURCE-ERROR: no such function: md5sum
  - [ ] **9.4.divbug.91.003** `backup_ioerr` — SOURCE-ERROR: no such function: md5sum
  - [ ] **9.4.divbug.91.004** `bind` — SOURCE-ERROR: can't read "SQLITE_MAX_VARIABLE_NUMBER": no such variable
  - [ ] **9.4.divbug.91.005** `capi3b` — SOURCE-ERROR: can't read "cmdlinearg(soft-heap-limit)": no such variable
  - [ ] **9.4.divbug.91.006** `fuzz3` — SOURCE-ERROR: no such function: md5sum
  - [ ] **9.4.divbug.91.007** `interrupt` — SOURCE-ERROR: no such function: md5sum
  - [ ] **9.4.divbug.91.008** `join3` — SOURCE-ERROR: can't read "bitmask_size": no such variable
  - [ ] **9.4.divbug.91.009** `mallocAll` — SOURCE-ERROR: no files matched glob pattern "/home/bpsa/app/pas-sqlite3/src/tests/tcl/*malloc*.test"
  - [ ] **9.4.divbug.91.010** `memleak` — SOURCE-ERROR: couldn't read file "-": no such file or directory
  - [ ] **9.4.divbug.91.011** `qrf01` — ! qrf01-1.10 error: QRF not available in this build
  - [ ] **9.4.divbug.91.012** `qrf02` — SOURCE-ERROR: QRF not available in this build
  - [ ] **9.4.divbug.91.013** `savepoint2` — SOURCE-ERROR: can't read "::sig(one)": no such variable
  - [ ] **9.4.divbug.91.014** `tkt3992` — ! tkt3992-2.3 error: can't read "res": no such variable
  - [ ] **9.4.divbug.91.015** `trans2` — ! trans2-1.1 error: no such function: md5sum
  - [ ] **9.4.divbug.91.016** `types` — SOURCE-ERROR: can't read "sqlite_options(utf16)": no such element in array

---

## Phase 10 — CLI tool (`shell.c`, ~12k lines → `passqlite3shell.pas`)

Each chunk lands with a scripted parity gate that diffs `bin/passqlite3`
against the upstream `sqlite3` binary.  Unported dot-commands must return
the upstream `Error: unknown command or invalid arguments: ".foo"` so
partial landings cannot silently no-op.

### 10.1a Skeleton + arg parsing + REPL loop

- [X] **10.1a** Skeleton landed; gate `tests/cli/10a_repl/` green.
- [X] **10.1.1** ShellState record + global state.
- [X] **10.1.2** processInput / oneInputLine REPL core; quickscan + line-is-terminator + continue-prompt all wired.
- [X] **10.1.3** main + process_command_line two-pass arg parser; `~/.sqliterc`/`-init` loading + `-memtrace`/`-pcachetrace` stderr sinks wired.
- [X] **10.1.4** Line reader (basic LF/CRLF). GNU readline integration deferred.
- [X] **10.1.5** Exit-code mapping + interrupt_handler + SIGINT wiring.
- [X] **10.1.6** do_meta_command dispatcher skeleton.
- [X] **10.1a.G** Gate `src/tests/TestShellRepl.pas` 8/8 PASS. One deferred section: `~/.sqliterc` auto-load (FPC base RTL has no getpwuid; port resolves $HOME only).

### 10.1b Output modes + formatting controls

- [X] **10.1b** Output modes + formatting controls. Gate: `bin/TestShellModes`.
- [X] **10.1.7..10.1.14** `.mode` dispatcher, shell_callback row dispatcher, columnar renderers, `.headers/.separator/.nullvalue/.echo/.changes/.width`, `.print/.parameter`, CSV/JSON/HTML writer helpers all landed.

### 10.1c Schema introspection dot-commands

- [~] **10.1c** Gate: `bin/TestShellSchema`. Multi-result `.tables` / `.indexes`-no-arg / temp-schema side-effects on `.databases` after `.indexes` are pre-existing port divergences and stay out of the gate.
  - [X] **10.1c.1** `.schema` (basic + pattern + `--indent` + `--nosys`)
  - [X] **10.1c.2** `.tables` (single-result + pattern)
  - [X] **10.1c.3** `.indexes` (with table arg)
  - [X] **10.1c.4** `.databases`
  - [X] **10.1c.5** `.fullschema`
  - [X] **10.1c.6** `.lint fkey-indexes` — closed via 6.13.B and 6.16.
  - [X] **10.1c.7** `.expert` (read-only subset) — engine ported in 10.1.101; productive recommendations restored by 6.13.B.11.
- [X] **10.1.15..10.1.21** `.schema --indent`, `.tables`, `.indexes`, `.databases`, `.fullschema`, `.lint fkey-indexes`, `.expert` all landed.

### 10.1d Data I/O dot-commands

- [X] **10.1d** Subcommands 10.1.22..10.1.27 landed; gate `src/tests/TestShellIO.pas` 11/11 PASS. One sub-arm deferred: **open-hexdb** (cmdOpen --hexdb still rejects empty filename — TODO inline in TestShellIO.pas).
  - [X] **10.1d.1** `.read`
  - [X] **10.1d.2** `.dump`
  - [X] **10.1d.3** `.import` — auto-create-from-header + duplicate-column renaming + heredoc input (10.1d.3.a) + pipe input (10.1d.3.b) all landed.
  - [X] **10.1d.4** `.output` / `.once` — editor/spreadsheet/browser (`-e`/`-x`/`-w`) variants and `|cmd` pipe targets intentionally not gated; future xdg-open / TProcess follow-up.
  - [X] **10.1d.5** `.save`
  - [X] **10.1d.6** `.open` (full flag set: 10.1d.6.a/b closed).
- [X] **10.1.22..10.1.27** `.read`, `.dump`, `.import`, `.output`/`.once`, `.save`, `.open` (all sub-arms a..g) landed.

### 10.1e Meta / diagnostic dot-commands

- [X] **10.1e** Gate: src/tests/TestShellMeta.pas (10.1e.G, 48/48 PASS) across .help/.show/.eqp/.explain/.cd/.shell/.system/.stats/.trace/.testcase/.testctrl/.iotrace/.scanstats/.selecttrace/.wheretrace/.timer/.log within their deterministic scope.
- [X] **10.1.28..10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`, `.show`, `.help`, `.cd`, `.shell`/`.system`, `.trace` landed.
- [X] **10.1.36** `.log` — destination recorded and SQLITE_CONFIG_LOG xLog trampoline installed (8.1.1 landed).
- [X] **10.1.38** `.iotrace` — stub; full sqlite3IoTrace fanout gated on sqlite3VdbeIOTraceSql arm (currently a stub at passqlite3vdbe.pas:4122).
- [~] **10.1.39** `.scanstats` — basic per-loop dump landed via 8.2.1 (NAME/EXPLAIN/EST/SELECTID/PARENTID emitted). Sub-arms a..e all closed:
  - [X] **10.1.39.a** TWhereLevel.addrVisit field added; NVISIT unblocked (port of wherecode.c:333..374).
  - [X] **10.1.39.b** NLOOP/nExec confirmed; removed two stale addrBody overrides inside sqlite3WhereCodeOneLoopStart.
  - [X] **10.1.39.c** qrfEqpStats EQP-tree formatter ported (ext/qrf/qrf.c:162..454); `|--`/`` `--`` connectors + qrfApproxInt64 K/M/G/T/P/E suffix.
  - [X] **10.1.39.d** NCYCLE / hwtime sampling — `nCycle: u64` on TVdbeOp; `sqlite3Hwtime` ported (rdtsc on x86_64, mrs cntvct_el0 on aarch64, clock_gettime fallback); dispatch-loop bracket gated on `{$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}` (env-var enabled in build.sh; default-off zero overhead).
  - [X] **10.1.39.e** EXPLAIN text re-enabled: SCANSTAT_EXPLAIN gates on p4type=P4_DYNAMIC; displayScanstats prefers EXPLAIN string over zName.

  Upstream's "Warning: .scanstats not available in this build." is still echoed verbatim to keep TestShellMeta golden diff clean.
- [X] **10.1.40** `.testcase NAME` / `.check ANSWER` — fd-level capture, --glob/--notglob/--exact; shellMain summary byte-identical; rc = nTestErr>0. Sub-arms a/a.followup/b closed. Archive.
- [X] **10.1.41** `.testctrl` — dispatcher routes 12 opcodes through 8.4.1 overloads; BITVEC_TEST/FAULT_INSTALL/IMPOSTER/TUNE/PARSER_COVERAGE fall through to isOk=3 stub (need callback/coverage infra). Archive.
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — TRACEFLAGS toggle landed (via sqlite3_test_control). Mask-hint convention: subtask hints are bundle IDs, **always verify against** `sqliteInt.h:TREETRACE_*` / `whereInt.h:WHERETRACE_*`. Subtasks:
  - [X] **10.1.42.a** TREETRACE batch 1: begin/end (0x1), name resolution (0x10), column names (0x80), flatten (0x4), constant propagation (0x2000), WhereBegin/End (0x2). Archive.
    - [X] **10.1.42.a.1** UNION ALL left/right (select.c:3011/3030, 0x200).
    - [X] **10.1.42.a.2** Post-flatten (4706, 0x4) + wildcard expansion (6339, 0x8).
    - [~] **10.1.42.a.3** EXISTS-to-JOIN (7368, 0x100000) + aggregate analysis (8442, 0x20). Deferred: havingToWhere/countOfView/AggInfo-adjusted prints (closed under a.6). Archive.
    - [X] **10.1.42.a.4** "after window rewrite" (0x40), "dropping ORDER BY" (0x800, via a.11), "DISTINCT→GROUP BY" (0x20000, via a.12). Archive.
    - [~] **10.1.42.a.5** Outer-join + FROM-subquery (verified masks 0x1000/0x800/0x4000/0x8000/0x20); landed via a.7/a.8/a.9/a.10/a.6.5. Remaining: flattenSubquery + IgnorableOrderby drop. Archive.
    - [X] **10.1.42.a.6** All 5 sub-arms (a.6.1..a.6.5) landed 2026-05-13. Archive has individual citations.
  - [~] **10.1.42.b** WHERETRACE batch 1: addBtreeIdx (0x800), addVirtual (0x800), OR-clause Begin/End (0x400). Subtasks:
    - [~] **10.1.42.b.1** Range-scan cost estimate — landed `Range scan lowers nOut` (where.c:2247, 0x20) in `whereRangeScanEst`. Other 4 arms STAT4-only, gated on b.7. Archive.
    - [X] **10.1.42.b.2** Subset-cost in `whereLoopAdjustCost` (0x80, where.c:2711/2720) + 4 covering-index arms in `whereLoopAddBtree` (0x200, 4203/4210/4216/4224).
    - [X] **10.1.42.b.3** Vtab constraint enumeration — 5 arms in `whereLoopAddVirtual` (0x800, 4720..4794) + 2 in `whereLoopAddVirtualOne` (0xffffffff, 4416/4531).
    - [X] **10.1.42.b.4** Solver progress in `wherePathSolver` (masks **0x002/0x004**, NOT 0x80; sqliteInt.h:1181). Landed 0x002 arms; 0x004 + round-summary re-enabled in b.8. Archive.
    - [X] **10.1.42.b.5** OR-vs-AND per-subterm in `whereLoopAddOr` (0x400, where.c:4866). 0x20000 companion re-enabled in b.8. Archive.
    - [X] **10.1.42.b.6** DISTINCT reduction (0x0080, where.c:7118 + `nRowOut -= 30`) + optimizer-finished (0xffffffff, 7195). Trailing arms re-enabled in b.8. Archive.
    - [X] **10.1.42.b.7** Port the STAT4 cost-estimator helpers gating the
      4 deferred 10.1.42.b.1 arms: `whereRangeSkipScanEst` (c.8),
      `whereEqualScanEst` + `whereInScanEst` (c.9).  All 4 WHERETRACE 0x20
      arms re-enabled at host sites; STAT4 host wiring inside
      `whereRangeScanEst` (where.c:2215) and `whereLoopAddBtreeIndex`
      (where.c:3484..3531) landed under `{$IFDEF SQLITE_ENABLE_STAT4}`.
      Default build: TestExplainParity 1026/1026, 99/100 (TestFuzzDiff
      pre-existing).  STAT4=1: compiles clean, TestExplainParity 1026/1026.
      Unit-test fixtures in TestWherePlanner that pass `pBuilder=nil`
      to `whereRangeScanEst` crash under STAT4 (C would too — the input
      isn't a valid planner call); those tests now run only meaningfully
      on the default build.  Closed in c.9.
    - [X] **10.1.42.b.7.prereq** Port `sqlite3Stat4ProbeSetValue` and
      `sqlite3Stat4ValueFromExpr` (consumers of `IndexSample` /
      `sqlite3VdbeRecordCompare`) plus any sample-vector machinery they
      depend on (`sqlite3Stat4Init`, `analyzeOneTable` STAT4 arm, etc.).
      C ref: `../sqlite3/src/analyze.c` (STAT4 sample collection) +
      `../sqlite3/src/vdbeapi.c` (`sqlite3Stat4ProbeSetValue`).  Once
      landed, gate the new helpers + 10.1.42.b.7 behind
      `{$IFDEF SQLITE_ENABLE_STAT4}` and add the env-var wiring in
      `build.sh` (mirror the `SQLITE_ENABLE_STMT_SCANSTATUS` pattern).
      Complexity: L.  **Decomposed 2026-05-15** into three sub-arms
      (a/b/c) — survey commit none, ~2000-2500 LOC total; default-build
      byte-identical parity preserved at every sub-arm boundary.
      **Closed 2026-05-16**: all three sub-arms a/b/c landed in prior
      passes (prereq.a record-shape, prereq.b writer-side, prereq.c
      reader-side decomposed across c.1..c.9).  Reader-side bodies
      verified present: `sqlite3Stat4ProbeSetValue` /
      `sqlite3Stat4ValueFromExpr` interface forwards at
      `src/passqlite3codegen.pas:1957..1961`, `whereKeyStats` body at
      `:15687`, `whereRangeSkipScanEst` at `:15827`, `whereEqualScanEst`
      at `:15936`, `whereInScanEst` at `:15992`, `loadStat4` at `:41167`
      (wired into `analysisLoadTrampoline` at `:41270`).  All 4
      WHERETRACE 0x20 host arms re-enabled in `whereLoopAddBtreeIndex`
      (codegen.pas:16873..16875) + `whereRangeScanEst`
      (codegen.pas:16411..16495).  Default-build smoke confirmed:
      TestExplainParity 1026/1026, TestWherePlanner 679/679,
      regression 99/100 (sole TestFuzzDiff failure pre-existing).
    - [X] **10.1.42.b.7.prereq.a** Record-shape + scaffolding.  Added
      `SQLITE_ENABLE_STAT4` gate doc to `src/passqlite3.inc:75..96` +
      `STAT4=1` arm to `src/tests/build.sh:109..123` mirroring the
      `SQLITE_ENABLE_STMT_SCANSTATUS` pattern.  Ported the bare
      `TIndexSample` record (analyze.c:2856..2862 → passqlite3codegen.pas:1109..1126,
      sizeof=40 with tRowcnt=u64) and the 5 `TIndex` STAT4 tail fields
      `nSample` / `mxSample` / `nSampleCol` / `aAvgEq` / `aSample`
      (sqliteInt.h:2819..2825 → passqlite3codegen.pas:1163..1175), all
      `{$IFDEF SQLITE_ENABLE_STAT4}`-gated.  `PIndexSample` forward at
      passqlite3codegen.pas:406..408.  Audited `SizeOf(TIndex)` /
      `FillChar(pIdx^, SizeOf(TIndex), 0)` call sites
      (`sqlite3AllocateIndexObject` @ :38942..38964, plus 9 test
      `GetMem/FillChar` sites in TestWherePlanner) — all stay correct
      because SizeOf grows transparently under the gate; T28
      `SizeOf(TIndex)=112` in TestWhereBasic is the only hard-coded
      assertion and trips only under STAT4=1 (expected, refines in
      prereq.b).  **Default-build smoke: TestExplainParity PASS
      (1026/1026), TestSQLCorpus PASS, TestWhereBasic PASS (52/52),
      full regression 99/100 binaries (sole TestFuzzDiff failure is
      pre-existing baseline drift, not introduced here).**  STAT4=1
      smoke: same binaries green except TestWhereBasic T28 hard-coded
      size assertion (prereq.b will refresh).
    - [X] **10.1.42.b.7.prereq.b** analyze.c STAT4 collection (partial:
      writer-side complete; loadStat4 reader deferred to .b.7.prereq.c
      since whereKeyStats / value-from-expr consumers land there too).
      Landed under `{$IFDEF SQLITE_ENABLE_STAT4}`:
        * `TStatSample` full record (anEq/anLt/u.aRowid|iRowid/nRowid/
          isPSample/iCol/iHash) + `TStatAccum` STAT4 tail (nPSample/
          mxSample/iPrn/aBest/iMin/nSample/nMaxEqZero/iGet/a) at
          `passqlite3codegen.pas:47093..47129`.
        * `sampleClear` / `sampleSetRowid` / `sampleSetRowidInt64` /
          `sampleCopy` at `:47132..47175`.
        * `statAccumDestructor` STAT4 cleanup arm at `:47179..47204`.
        * `statInitImpl` STAT4 alloc + a[]/aBest[] layout at
          `:47230..47286` (analyze.c:429..477).
        * `sampleIsBetterPost` / `sampleIsBetter` / `sampleAt` / `bestAt`
          / `sampleInsert` / `samplePushPrevious` at `:47291..47416`
          (analyze.c:511..681).
        * `statPushImpl` STAT4 arms — anEq=1 init, anLt accumulation,
          rowid setter, periodic sample insert, aBest[] update — at
          `:47432..47498` (analyze.c:720..773).
        * `statGetImpl` STAT4 branches — STAT_GET_ROWID/_NEQ/_NLT/_NDLT
          via `sqlite3_str`-equivalent space-joined integers — at
          `:47517..47578` (analyze.c:818..917).
        * `sqlite3DeleteIndexSamples` real body at `:48168..48190`
          (analyze.c:1656..1676).
        * `openStatTable` extended to open `sqlite_stat4` (cNToOpen=2,
          cTabCols[1]='tbl,idx,neq,nlt,ndlt,sample') at `:47593..47604`.
        * `callStatGet` emits `OP_Integer iParam, regStat+1` and uses
          `1+IsStat4` arg count at `:47655..47668` (analyze.c:935..946).
        * `analyzeOneTable` STAT4 regRowid load (IdxRowid for rowid
          tables; MakeRecord-over-PK for WITHOUT ROWID) at `:48056..
          48075`, and the full STAT_GET_ROWID/NEQ/NLT/NDLT row-emit
          block with doOnce/mxCol/OP_NotExists|OP_NotFound at
          `:48097..48148` (analyze.c:1227..1351).
        * `IsStat4=1` / `SQLITE_STAT4_SAMPLES=24` const block hoisted
          before the StatAccum types so `aStatFuncs[*].nArg` and
          `sqlite3VdbeAddFunctionCall(..., 1|2+IsStat4, ...)` build.
      Default-build smoke: `src/tests/build.sh` — regression 99/100
      green (sole pre-existing TestFuzzDiff baseline drift), bytecode
      shape unchanged.  STAT4=1 build smoke: builds clean; ANALYZE on
      a 10-row INDEX(a,b) emits 10 sqlite_stat4 rows with correct nEq /
      nLt / nDLt (nEq=3 for the dup'd (1,*) prefix, monotonic nLt/nDLt,
      sample BLOBs matched).  C-oracle byte-compare deferred — the
      bundled `/home/bpsa/app/sqlite3/sqlite3` binary is non-STAT4 so
      direct diff requires a -DSQLITE_ENABLE_STAT4 rebuild of the
      oracle.  TestWhereBasic T28 trips under STAT4=1 (SizeOf(TIndex)
      grows by 40 bytes — refresh deferred to landed `IsStat4=1` build
      convention).  **Deferred to prereq.c**: `loadStat4` /
      `loadStatTbl` / `initAvgEq` / `findIndexOrPrimaryKey` (reader
      side; consumed by where.c estimators which already land there).
    - [X] **10.1.42.b.7.prereq.c** Consumers — vdbemem.c STAT4 layer +
      `whereKeyStats` + the 3 estimators landed across 9 sub-arms (.1..9).
      All 4 WHERETRACE 0x20 arms re-enabled.  Default build byte-identical
      at every sub-arm boundary; STAT4=1 compiles clean and
      TestExplainParity 1026/1026 under STAT4=1.  Closed in c.9.
    - [X] **10.1.42.b.7.prereq.c.1** Port `ValueNewStat4Ctx` struct
      (vdbemem.c:1611..1622) + `valueNew` STAT4-aware factory
      (vdbemem.c:1632..1700) into `src/passqlite3vdbe.pas` (or wherever
      `sqlite3ValueNew` already lives).  Default build untouched (STAT4
      branch hidden behind ifdef).  Smoke: STAT4=1 build still compiles +
      regression 99/100 green.
      **Outcome 2026-05-15**: landed at `src/passqlite3vdbe.pas` —
      `TValueNewStat4Ctx`/`PValueNewStat4Ctx` declared unconditionally
      (so signatures compile in both builds; only the STAT4 body
      consumes them), private `valueNew` placed right after
      `sqlite3ValueNew`.  Codegen-private dependencies (`pIdx^.nColumn`
      + `sqlite3KeyInfoOfIndex`) reached via new `gKeyInfoOfIndex` hook
      (declared under `{$IFDEF SQLITE_ENABLE_STAT4}`); trampoline wiring
      lands in c.5.  Default build: TestExplainParity 1026/1026, only
      pre-existing TestFuzzDiff fails.  STAT4=1: compiles clean; the
      three known STAT4=1 regressions (T28 TIndex sizeof, TestFuzzDiff,
      TestSQLCorpus) are pre-existing from prereq.a/b, not introduced
      here.
    - [X] **10.1.42.b.7.prereq.c.2** Port `valueFromFunction` STAT4 arm
      (vdbemem.c:1701..1799) — recursive const-folding through
      `sqlite3VdbeMemSetStr`/`sqlite3ValueApplyAffinity` to pre-evaluate
      function calls in stat4 probe inputs.
      **Outcome 2026-05-15**: landed via STAT4-gated trampoline —
      `valueFromFunction` shell + `gValueFromFunctionImpl` hook in
      `src/passqlite3vdbe.pas` (near `valueNew`), real body
      `valueFromFunctionImpl` in `src/passqlite3codegen.pas` (needs
      PExpr / PParse layout + `sqlite3FindFunction`).
      `sqlite3Stat4ValueFromExpr` forward-stubbed (real port = prereq.c.4).
      `valueNew` exposed in vdbe interface for the codegen call.  Default
      build: TestExplainParity 1026/1026, only pre-existing TestFuzzDiff
      fails.  STAT4=1: compiles clean; pre-existing 3 regressions only
      (T28 TIndex sizeof, TestFuzzDiff, TestSQLCorpus).
    - [X] **10.1.42.b.7.prereq.c.3** Port `valueFromExpr` STAT4 branches
      + `stat4ValueFromExpr` helper (vdbemem.c:1800..2080) — the dispatch
      that turns a constant Expr tree into a `sqlite3_value*` usable by
      whereKeyStats.
      Outcome: trampoline extended with pCtx (TK_CAST ExpandBlob, TK_FUNCTION
      arm, valueNew over sqlite3ValueNew, no_mem STAT4 ctx-aware branch);
      `stat4ValueFromExpr` static added + sqlite3Stat4ValueFromExpr now
      delegates to it.  Default build: TestExplainParity 1026/1026, no new
      regressions.  STAT4=1: compiles clean; same 3 pre-existing failures.
    - [X] **10.1.42.b.7.prereq.c.4** Port public entries
      `sqlite3Stat4ProbeSetValue` (vdbemem.c:2082..2117) +
      `sqlite3Stat4ValueFromExpr` (:2127..2147).  These are the API
      surface where.c calls.  Done: ProbeSetValue ported in
      passqlite3codegen.pas next to Stat4ValueFromExpr; alloc.ctx +
      per-column zColAff lookup mirror C inlined IndexColumnAffinity.
      Default build: 99/100 (TestFuzzDiff pre-existing).
      STAT4=1: compiles clean.
    - [X] **10.1.42.b.7.prereq.c.5** Replace `sqlite3Stat4Column`
      (vdbemem.c:2149..2190) + `sqlite3Stat4ProbeFree` (:2194..2210)
      Phase-6 stubs in `src/passqlite3vdbe.pas` with real bodies.
      Bodies were already real-form; gated under `{$IFDEF SQLITE_ENABLE_STAT4}`
      with non-STAT4 stub arms preserving the unit-interface signatures.
      Default: 99/100 (TestFuzzDiff pre-existing). STAT4=1: compiles clean
      (3 pre-existing fails unchanged).
    - [X] **10.1.42.b.7.prereq.c.6** Port `loadStat4` / `loadStatTbl` /
      `initAvgEq` / `findIndexOrPrimaryKey` reader side (analyze.c, the
      deferred half of prereq.b).  Required so STAT4 samples written by
      ANALYZE are loaded into `pIdx^.aSample[]` at schema-init.
      Outcome: landed in src/passqlite3codegen.pas with the four reader
      fns + `decodeStat4IntArray` raw-tRowcnt helper, all gated under
      `{$IFDEF SQLITE_ENABLE_STAT4}`.  Extended TIndex STAT4 tail by 16
      bytes to add `aiRowEst` / `nRowEst0` (sqliteInt.h:2825..2826) — pre-
      existing T28 SizeOf(TIndex)=112 assertion in TestWhereBasic remains
      stale under STAT4 (same FAIL count as baseline: 3).  Wired into
      `analysisLoadTrampoline`: clears `aSample` per index on entry,
      bumps `lookaside.bDisable` around `loadStat4`, then frees per-idx
      `aiRowEst`.  Default build: TestExplainParity 1026/1026, 99/100
      (TestFuzzDiff pre-existing).  STAT4=1: compiles clean, regression
      identical to prereq.c.5 baseline (3 pre-existing fails).
    - [X] **10.1.42.b.7.prereq.c.7** Port `whereKeyStats`
      (where.c:1718..1978) into `src/passqlite3codegen.pas`.  Binary
      search over `aSample[]` returning interpolated `aStat[3]`.
      Landed: STAT4-gated function added before `whereRangeAdjust`;
      `PRowCntArr`/`TRowCntArr` hoisted to interface type block so the
      signature is visible to (eventual) c.8/c.9 callers.  Default build:
      TestExplainParity 1026/1026, 99/100 (TestFuzzDiff pre-existing).
      STAT4=1: compiles clean, regression identical to prereq.c.5/c.6
      baseline (3 pre-existing fails).
    - [X] **10.1.42.b.7.prereq.c.8** Port `whereRangeSkipScanEst`
      (where.c:1980..2030) + re-enable its WHERETRACE 0x20 arm at host
      site (where.c:2002, 2006).  Body landed near whereKeyStats under
      `{$IFDEF SQLITE_ENABLE_STAT4}`; uses inlined IndexColumnAffinity via
      zColAff[nEq] with sqlite3IndexAffinityStr fallback; consumes
      sqlite3Stat4ValueFromExpr (c.4) + sqlite3Stat4Column (c.5) +
      sqlite3MemCompare + sqlite3LocateCollSeq.  Internal WHERETRACE(0x20)
      "range skip-scan regions: %u..%u  adjust=%d est=%d" wired under
      SQLITE_DEBUG.  Interface forward for sqlite3Stat4ValueFromExpr
      hoisted to the interface section so the consumer's call site
      compiles ahead of the body.  Call-site wiring inside
      whereRangeScanEst deferred to c.9 (depends on extending
      TWhereLoopBuilder with STAT4-only pRec/nRecValid fields together
      with whereEqualScanEst / whereInScanEst).  Default build:
      TestExplainParity 1026/1026, 99/100 (TestFuzzDiff pre-existing).
      STAT4=1: compiles clean, 97/100 == prereq.c.5..c.7 baseline (3
      pre-existing fails: TestFuzzDiff, TestSQLCorpus, TestWhereBasic).
    - [X] **10.1.42.b.7.prereq.c.9** Port `whereEqualScanEst`
      (where.c:2274..2330) + `whereInScanEst` (:2338..2380); re-enable
      the 4 deferred WHERETRACE 0x20 arms in `whereLoopAddBtree` host
      sites.  Closes 10.1.42.b.7 + prereq.c.
      **Outcome 2026-05-15**: ported both estimators near
      whereRangeSkipScanEst under `{$IFDEF SQLITE_ENABLE_STAT4}`;
      extended `TWhereLoopBuilder` with STAT4-only `pRec` /
      `nRecValid` (+16 bytes); restored the full STAT4 branch of
      `whereRangeScanEst` (where.c:2103..2223) including the 0x20
      "STAT4 range scan" trace; wired the STAT4 sample-driven equality/
      IN estimator inside `whereLoopAddBtreeIndex` (where.c:3484..3531)
      with the 0x20 "low selectivity" trace + `TERM_HIGHTRUTH` flag;
      added STAT4 probe reset (`sqlite3Stat4ProbeFree`) at
      `whereLoopAddBtree` tail.  Added `TERM_HIGHTRUTH = $4000`
      constant under STAT4.  Default build: TestExplainParity 1026/
      1026, 99/100 (TestFuzzDiff pre-existing).  STAT4=1: compiles
      clean, TestExplainParity 1026/1026 (the new STAT4 host wiring
      runs without producing bytecode regressions on the corpus).
      TestWherePlanner RA-test fixtures that pass `pBuilder=nil` crash
      under STAT4 (the STAT4 branch derefs `pLoop^.u.btree.pIndex`
      first); this matches C semantics — those fixtures only validate
      the no-STAT4 tail.
    - [X] **10.1.42.b.8** Port `wherePathName` + `sqlite3Where{Term,Clause,Loop}Print` + `showAllWhereLoops` (where.c:2375..2520/5512..5519/6469..6488).
    - [X] **10.1.42.a.6.1** `havingToWhere` + `havingToWhereExprCb` (select.c:7047) + `sqlite3ExprIsConstantOrGroupBy`; wired SF_Aggregate+GROUP-BY (8422..8431). 0x100.
    - [X] **10.1.42.a.6.2** `countOfViewOptimization` (select.c:7128..7204); wired after propagateConstants (7924..7930). 0x200. SQLITE_CountOfView added.
    - [X] **10.1.42.a.6.3** `optimizeAggregateUseOfIndexedExpr` (select.c:6549..6586); wired pre assignAggregateRegisters (8527..8529). 0x20.
    - [X] **10.1.42.a.6.4** `aggregateConvertIndexedExprRefToColumn` + walker (select.c:6591..6623); wired after sqlite3WhereEnd (8600..8615). 0x20.
    - [X] **10.1.42.a.6.5** "Finished with AggInfo" at sqlite3Select tail (select.c:8933..8945). 0x20.
    - [X] **10.1.42.a.7** Outer-join strength-reduction loop (select.c:7708..7770) + `sqlite3ExprImpliesNonNullRow`/`impliesNotNullRow`/`bothImplyNotNullRow` (expr.c:6857..7031) + `unsetJoinExpr` (471..494).
    - [X] **10.1.42.a.8** FROM-subquery superfluous-ORDER-BY drop (select.c:7822..7838, tag-select-0230). SQLITE_OmitOrderBy ($40000). 0x800. Archive.
    - [X] **10.1.42.a.9** `pushDownWhereTerms` (5125..5286) + `disableUnusedSubqueryResultColumns` (5296..5358). 0x4000.  Cites: 04000000.
    - [X] **10.1.42.a.10** all-FROM snapshot (select.c:8144..8149, 0x8000).
    - [X] **10.1.42.a.11** top-level ORDER-BY drop (select.c:7625..7644, 0x800).
    - [X] **10.1.42.a.12** DISTINCT→GROUP BY (select.c:8151..8196, 0x20000). Gates on selFlags == SF_Distinct + pWin=nil + ExprListCompare=0. Closes a.4. Archive.
  - [X] **10.1.42.c** `sqlite3DebugPrintf` (printf.c:1514..1532) → passqlite3printf.pas.
  - [X] **10.1.42.d** Build-flag gating: `build.sh` honours `SQLITE_DEBUG=1` → `-dSQLITE_DEBUG`. Documented in `src/passqlite3.inc`.

### 10.1f Long-tail / specialised dot-commands

- [X] **10.1f** Closed 2026-05-13 — every 10.1f.0..10.1f.16 sub-arm landed (.backup/.restore/.clone, .archive/.ar, .session stub, .recover, .dbinfo, .dbconfig, .filectrl, .sha3sum, .crnl/.binary/.connection/.unmodule, .vfsinfo/.vfslist/.vfsname).
  - [X] **10.1f.0..10.1f.2** `.backup` / `.restore` / `.clone` — gated by `src/tests/TestShellBackup.pas`.
  - [X] **10.1f.3** `.archive`/`.ar` — gated by `src/tests/TestShellArchive.pas`.
  - [X] **10.1f.4** `.session` — gated by `src/tests/TestShellArchive.pas` shape arm (stub per 10.1.47).
  - [X] **10.1f.5** `.recover` — gated by `src/tests/TestShellArchive.pas`.
  - [X] **10.1f.6** `.dbinfo` — gated by `src/tests/TestShellDbinfo.pas`. Side-fix: route positional dot-cmd rc through process exit (shell.c.in:13548).
  - [X] **10.1f.7** `.dbconfig` — gated by `src/tests/TestShellDbinfo.pas`. Counter/pointer DBCONFIG_* ops now reachable via the typed sqlite3_db_config_* entry points (8.1.1).
  - [X] **10.1f.8** `.filectrl` — gated by `src/tests/TestShellFilectrl.pas`. PERSIST_WAL/POWERSAFE_OVERWRITE skipped (port unix VFS xFileControl lacks those arms).
  - [X] **10.1f.9** `.sha3sum` — gated by `src/tests/TestShellFilectrl.pas`.
  - [X] **10.1f.10..10.1f.13** `.crnl`/`.binary`/`.connection`/`.unmodule` — gated by `src/tests/TestShellMisc.pas`.
  - [X] **10.1f.14..10.1f.16** `.vfsinfo`/`.vfslist`/`.vfsname` — handler-shape parity in `src/tests/TestShellMisc.pas`; success-path stdout byte-parity blocked by szOsFile=88 layout divergence (unixFile record padding), 6.30/6.31 fixed.

- [X] **10.1.43..10.1.45** `.backup`, `.restore`, `.clone` all landed.
- [X] **10.1.46** `.archive`/`.ar` — full port; closed via bugs 6.17.A/B for GLOB range-bound truncation.
- [X] **10.1.47** `.session` — stub (session extension not ported).
- [X] **10.1.48** `.recover` — full port (~957 lines + LAF arm + wrapper-VFS arm). Sub-arms 10.1.48.a/b/c/d all closed (related .expert surface tracked under 6.13.B.11, now closed).
- [X] **10.1.49** `.dbinfo`.
- [X] **10.1.50** `.dbconfig` — boolean DBCONFIG_* + FP_DIGITS dispatched; counter/pointer DBCONFIG_* (LOOKASIDE, MAINDBNAME) reachable via sqlite3_db_config_lookaside / sqlite3_db_config_text (8.1.1).
- [X] **10.1.51..10.1.59** `.filectrl`, `.sha3sum`, `.crnl`, `.binary`, `.connection`, `.unmodule`, `.vfsinfo`/`.vfslist`/`.vfsname`, `.dbtotxt`, `.breakpoint` all landed.

### 10.1.60..10.1.100 — ext/misc and ext/* extension ports (all landed)

All ported as new units under `src/`. Wired via per-unit `sqlite3<Name>Init`
in shell `openDb` unless noted. Common caveat across many eponymous-vtab
ports: bare table-valued or MATCH-style invocations are blocked by bug 6.13
(now closed via 6.13.B); the modules themselves are faithful end-to-end.

- [X] **10.1.60** sha1.c → passqlite3sha1.pas
- [X] **10.1.61** uuid.c → passqlite3uuid.pas
- [X] **10.1.62** ieee754.c → passqlite3ieee754.pas
- [X] **10.1.63** percentile.c → passqlite3percentile.pas
- [X] **10.1.64** rot13.c + uint.c + base64.c
- [X] **10.1.65** totype.c → passqlite3totype.pas
- [X] **10.1.66** base85.c + eval.c + urifuncs.c
- [X] **10.1.67** anycollseq.c + blobio.c + nextchar.c + remember.c + stmtrand.c
- [X] **10.1.68** noop.c + zorder.c + randomjson.c
- [X] **10.1.69** wholenumber.c + templatevtab.c + showauth.c + mmapwarm.c
- [X] **10.1.70** prefixes.c + memstat.c
- [X] **10.1.71** series.c → passqlite3series.pas
- [X] **10.1.72** completion.c → passqlite3completion.pas
- [X] **10.1.73** decimal.c → passqlite3decimal.pas
- [X] **10.1.74** normalize.c → passqlite3normalize.pas
- [X] **10.1.75** regexp.c → passqlite3regexp.pas
- [X] **10.1.76** stmt.c + explain.c
- [X] **10.1.77** qpvtab.c + memtrace.c + pcachetrace.c
- [X] **10.1.78** btreeinfo.c + vtablog.c
- [X] **10.1.79** scrub.c → passqlite3scrub.pas
- [X] **10.1.80** fossildelta.c → passqlite3fossildelta.pas
- [X] **10.1.81** dbdump.c → passqlite3dbdump.pas
- [X] **10.1.82** csv.c → passqlite3csv.pas
- [X] **10.1.83** closure.c → passqlite3closure.pas
- [X] **10.1.84** appendvfs.c → passqlite3appendvfs.pas
- [X] **10.1.85** vfslog.c → passqlite3vfslog.pas
- [X] **10.1.86** fileio.c → passqlite3fileio.pas
- [X] **10.1.87** vfsstat.c → passqlite3vfsstat.pas
- [X] **10.1.88** vfstrace.c → passqlite3vfstrace.pas
- [X] **10.1.89** vtshim.c → passqlite3vtshim.pas
- [X] **10.1.90** cksumvfs.c → passqlite3cksumvfs.pas (VFS shim exported but not auto-installed)
- [X] **10.1.91** unionvtab.c → passqlite3unionvtab.pas
- [X] **10.1.92** fuzzer.c → passqlite3fuzzer.pas
- [X] **10.1.93** tmstmpvfs.c → passqlite3tmstmpvfs.pas (NOT auto-installed)
- [X] **10.1.94** amatch.c → passqlite3amatch.pas
- [X] **10.1.95** compress.c + sqlar.c (libz via cdecl, `-k-lz`)
- [X] **10.1.96** ext/intck/sqlite3intck.c → passqlite3intck.pas
- [X] **10.1.97** ext/recover/dbdata.c → passqlite3dbdata.pas
- [X] **10.1.98** zipfile.c → passqlite3zipfile.pas
- [X] **10.1.99** spellfix.c → passqlite3spellfix.pas
- [X] **10.1.100** Built-in shell SQL UDFs: strtod, dtostr, shell_add_schema, shell_module_schema, shell_putsnl, usleep. editFunc deferred.
- [X] **10.1.101** `ext/expert/sqlite3expert.c` → `passqlite3expert.pas`. Productive recommendations confirmed once 6.13.B.11 was closed.
- [X] **10.1.102** `.open --zip` / `--deserialize` / `--hexdb` shell glue + faithful `sqlite3_deserialize` port.

- [~] **10.1a.1** Residual dot-command coverage gap surfaced by 2026-05-16 audit (Outcome B).  C `shell.c.in` help table (lines 3711..3962) lists 67 dot-commands; `doMetaCommand` in `src/passqlite3shell.pas:10342` routed 56 of them.  The 11 missing handlers all have working backing APIs in the engine and live entries in the Pas `azHelp[]` table (3704..3958).  Decomposed into bite-sized sub-arms 10.1a.1.1..10.1a.1.11; the 5 trivially-small ones (≤25 LOC each) landed inline 2026-05-16; the 6 medium ones are queued.  Gates: `bin/TestShellRepl` 8/8, `bin/TestShellModes` 2/2, `bin/TestShellSchema` 10/10, `bin/TestShellIO` 11/11, `bin/TestShellMeta` 60/60, `bin/TestCliParity` 20/1S/0 (== baseline).
  - [X] **10.1a.1.1** `.bail on|off` — bail_on_error toggle.  Cite: shell.c.in:9104..9110 (~7 lines).  Pas: `cmdBail` at `passqlite3shell.pas` + dispatcher route.
  - [X] **10.1a.1.2** `.timeout MS` — `sqlite3_busy_timeout` wrapper.  Cite: shell.c.in:11881..11884 (~4 lines).  Pas: `cmdTimeout`.
  - [X] **10.1a.1.3** `.version` — libversion + sourceid + compiler tag (fpc-X.Y.Z subbed for the C build's clang/gcc/msvc arm).  Cite: shell.c.in:11978..11996 (~18 lines).  Pas: `cmdVersion`.
  - [X] **10.1a.1.4** `.prompt MAIN ?CONTINUE?` — replace `mainPromptStr` / `continuePromptStr`.  Cite: shell.c.in:10438..10445 (~8 lines).  Pas: `cmdPrompt`.
  - [X] **10.1a.1.5** `.nonce STRING` — match-or-halt; clears bSafeMode on hit.  Cite: shell.c.in:10116..10128 (~13 lines).  Pas: `cmdNonce` (uses `Halt(1)` for the cli_exit(1) arm).
  - [X] **10.1a.1.6** `.limit ?NAME? ?VAL?` — `cmdLimit` landed (`passqlite3shell.pas`); 13-entry table, case-insensitive prefix match, ambiguity + unknown errors match upstream.
  - [ ] **10.1a.1.7** `.imposter INDEX IMPOSTER` / `.imposter off` — emits `CREATE TABLE` from `PRAGMA index_xinfo` + `SQLITE_TESTCTRL_IMPOSTER` wrap.  Cite: shell.c.in:9781..9962 (~180 lines).  Depends on `sqlite3_test_control(IMPOSTER, …)` arm being live; verify before porting.
  - [ ] **10.1a.1.8** `.progress N` — `sqlite3_progress_handler` plus `--quiet/--reset/--once/--timeout/--limit` flag parser.  Cite: shell.c.in:10380..10435 (~56 lines).  Needs `flgProgress` / `mxProgress` / `tmProgress` / `nProgress` ShellState fields (check whether already present) and a `progress_handler` callback trampoline.
  - [X] **10.1a.1.9** `.load FILE ?ENTRY?` — `cmdLoad` landed; safe-mode gate + arg parse + `sqlite3_load_extension` forward; surfaces engine OMIT "extension loading is disabled" on stderr.
  - [ ] **10.1a.1.10** `.auth ON|OFF` — `sqlite3_set_authorizer(shellAuth | safeModeAuth | nil)`.  Cite: shell.c.in:9007..9022 (~16 lines).  Needs `shellAuth` callback + `safeModeAuth` callback ported from shell.c.in:8901..8973 (~80 lines additional).  Total ~100 LOC.
  - [X] **10.1a.1.11** `.intck ?STEPS_PER_UNLOCK?` — `cmdIntck` landed; wraps `sqlite3_intck_open/_step/_message/_unlock/_error/_close`; emits `<N> steps, <M> errors` trailer per C.

### 10.1.bug.* — fixed bug ledger (kept as ticked stubs only)

> Closed bugs: history is in git. Each line below records the slot for
> regression-tracking purposes — re-open the slot if the symptom returns.

- [X] **10.1.bug.1** Header row leak in `.mode list` (QRF tri-state semantics).
- [X] **10.1.bug.103** strftime('%u') ISO weekday off-by-one.
- [X] **10.1.bug.105** ISO 8601 `[+-]HH:MM` timezone suffix dropped.
- [X] **10.1.bug.106** `'localtime'` / `'utc'` date modifiers were no-ops.
- [X] **10.1.bug.107** CREATE UNIQUE INDEX on pre-populated dups silently succeeded (sqlite3VdbeSorterCompare).
- [X] **10.1.bug.108** UNIQUE INDEX with COLLATE NOCASE ignored collation (sqlite3CreateIndex must peel TK_COLLATE).
- [X] **10.1.bug.109** `SELECT * FROM v ORDER BY a,b` with covering UNIQUE index returned `0.0|0.0` rows (nOBSat shortcut must reset bSortOmitRef/nPrefixReg).
- [X] **10.1.bug.110** current_date / current_time / current_timestamp not registered.
- [X] **10.1.bug.111** AUTOINCREMENT counter not consulted (OP_NewRowid missing P3 arm).
- [X] **10.1.bug.112** Star expansion skipped in prior arms of compound (selectExpander must walk pPrior).
- [X] **10.1.bug.113** FROM-subquery coroutine in compound MERGE arms.
- [X] **10.1.bug.114** Numeric-prefix coercion lost decimal/exponent (numericType missing `(rcM and 2)=0` guard).
- [X] **10.1.bug.115** WITH RECURSIVE … LIMIT inside body: ran forever / no rows.
- [X] **10.1.bug.116** Correlated subqueries with qualified outer refs failed (resolver order + ResolveOuterRefs walk).
- [X] **10.1.bug.117** min(x)/max(x) over all-NULL returned blob "0.0" (minMaxFinal flag check).
- [X] **10.1.bug.118** shellEPutZ stderr/stdout interleave order (drain Output first).
- [X] **10.1.bug.119** replace(s,p,r) with NULL p or r returned s instead of NULL.
- [X] **10.1.bug.120** Result-set column aliases not visible in WHERE (ResolveAliasInWhere walker).
- [X] **10.1.bug.121** LIMIT/OFFSET ignored on eponymous-vtab fast-arm.
- [X] **10.1.bug.122** Aggregates over eponymous-vtab returned empty (isVtabAgg must drive xBestIndex).
- [X] **10.1.bug.123** WITH RECURSIVE … ORDER BY dropped (SRT_Queue/SRT_DistQueue dispatch).
- [X] **10.1.bug.124** CLI `near line N` off-by-one with comment-interleaved scripts.
- [X] **10.1.bug.125** Step-error rc was extended code, missing " (rc)" suffix; sqlite3VdbeReset must apply errMask.
- [X] **10.1.bug.126** JSON-function malformed-input errors silently swallowed.
- [X] **10.1.bug.127** ORDER BY+LIMIT silently dropped sort on coroutine FROM. Bonus: signFunc must use numeric_type, not value_type.
- [X] **10.1.bug.128** CLI step-error prefix should be `Error near line N:` (no `Runtime error`, no `(rc)` suffix).
- [X] **10.1.bug.129** CLI openDb missed `sqlite3_db_config(TRUSTED_SCHEMA=0, DEFENSIVE=1, STMT_SCANSTATUS=0)`. Regression: bin/TestShellTrustedSchema.
- [X] **10.1.bug.130** `UPDATE T AS t SET col=(SELECT … WHERE inner.col=t.col)` errored "no such column: t.col". Regression: bin/TestUpdateCorrelated.
- [X] **10.1.bug.131** Bare-TK_ID outer ref from inside a correlated subquery errored. Regression: bin/TestCteOuterID.
- [X] **10.1.bug.132** CLI `processInput` cut-gate required `zSql[end]=';'` before sqlite3_complete; trailing `--` comment caused statement-merging. Regression: bin/TestShellSemiComment.
- [X] **10.1.bug.133** CLI `.echo on` was a silent no-op.
- [X] **10.1.bug.134** CLI `.parameter set` populated temp.sqlite_parameters but `bind_prepared_stmt` was never ported.
- [X] **10.1.bug.135** `.changes` / `.show` defects: per-SQL emission, `output:` line ordering, `output_c_string` escaping, `autoExplain` default. Regression: bin/TestShellChanges.
- [X] **10.1.bug.136** Meta dot-command dispatcher sweep (10.1e.G): `procedure→function: i32` conversions to propagate rc, wording/format/array-size drifts. Regression: bin/TestShellMeta.

---

## Known regression-test failures (auto-discovered by `run_regression.sh`)

> Ledger entries: when a binary returns to all-green, mark `[X]` and leave
> in place as a fixed-bug record (matching the convention used by 10.1.bug.*).
> Numbering is scoped to the phase that owns the root cause.

- [X] **3.B.regbug.1** TestPagerReadOnly — fixed 2026-05-10 (test-fixture path-resolution defect).
- [X] **6.regbug.1** TestWhereExpr — fixed 2026-05-10 (test-fixture: `pTab^.iPKey` left at 0, must stamp `-1` after `sqlite3DbMallocZero`).

---

## Phase 10.2 — CLI integration parity

- [X] **10.2** Integration parity: `bin/passqlite3 foo.db` ↔
  `sqlite3 foo.db` on a scripted corpus that unions all 10.1a..f
  golden files plus kitchen-sink multi-statement sessions (modes,
  attached DBs, triggers, dump+reload).  Diff stdout, stderr, exit
  code; any divergence is a hard failure.
  Landed: src/tests/TestCliParity.pas → bin/TestCliParity 20 PASS / 1 SOFT / 0 FAIL (21 total).

---

## Phase 11 — Benchmarks (Pascal-on-Pascal speedtest1 port)

Output format must be byte-identical to upstream `speedtest1` so the
existing `speedtest.tcl` diff workflow keeps working.  Lives in
`src/bench/passpeedtest1.pas`; the same binary swaps backends
(passqlite3 vs system libsqlite3) by `--backend`.

- [X] **11.1** Harness port (speedtest1.c lines 1..780): argument
  parser, `g` global state, `speedtest1_begin_test` /
  `speedtest1_end_test`, `speedtest1_random`, `speedtest1_numbername`,
  result-printing tail.  Gate: `bench/baseline/harness.txt`.
  Landed: src/bench/passpeedtest1.pas:1..750 (HashInit/fatal_error/integerValue/
  speedtest1_timestamp/_random/_numbername/_begin_test/_end_test/_final/_exec/
  _once/_prepare/_run) ports speedtest1.c:1..780; bench/check_harness.sh: PASS.

- [X] **11.2** `testset_main` port (lines 781..1248) — the ~30
  numbered cases (100..990) of the canonical OLTP corpus.  Primary
  regression gate.  Gate: `bench/baseline/testset_main.txt`.
  Landed: src/bench/passpeedtest1.pas:766..1233 (`procedure testset_main`)
  ports speedtest1.c:781..1248; rolled into bench/check_testsets.sh suite.

- [X] **11.3** Small / focused testsets (one chunk):
  `testset_cte` (1250..1414), `testset_fp` (1416..1485),
  `testset_parsenumber` (2875..end).  Gate:
  `bench/baseline/testset_{cte,fp,parsenumber}.txt`.
  Landed: passpeedtest1.pas:1234..1364 (testset_cte ← speedtest1.c:1250..1414),
  1365..1432 (testset_fp ← 1416..1485), 1433..1470 (testset_parsenumber ←
  2875..end); bench/check_testsets.sh: all three PASS.

- [X] **11.4** Schema-heavy testsets: `testset_star` (1487..2086),
  `testset_orm` (2272..2538), `testset_trigger` (2539..2740).
  Gate: `bench/baseline/testset_{star,orm,trigger}.txt`.
  Landed: passpeedtest1.pas:1471..1584 (testset_star ← 1487..2086),
  1585..1850 (testset_orm ← 2272..2538), 1851..2056 (testset_trigger ←
  2539..2740); bench/check_testsets.sh: all three PASS.

- [X] **11.5** Optional / extension-gated testsets: `testset_debug1`
  (2741..2756, lands with 11.4); `testset_json` (2758..2873, gated
  on Phase 6.8 — already in scope); `testset_rtree` (2088..2270,
  gated on R-tree extension port — currently unscheduled, stub with
  omit-style message until it lands).
  Landed: passpeedtest1.pas:2057..2077 (testset_debug1 ← 2741..2756),
  2078..2191 (testset_json ← 2758..2873), 2194..2204 (testset_rtree
  shell-style omit-stub for 2088..2270, per spec until R-tree extension
  port lands); bench/check_testsets.sh: all three PASS.

- [X] **11.6** Differential driver `bench/SpeedtestDiff.pas`.  Runs
  `passpeedtest1` twice (passqlite3 vs system libsqlite3 via the
  `--backend` flag) and emits a side-by-side ratio table; strips
  wall-clock timings so the *output* of both runs can also be diffed
  for byte-equality.
  Landed: src/bench/SpeedtestDiff.pas (639 lines); driver bench/run_diff.sh.

- [X] **11.7** Regression gate: commit `bench/baseline.json` (one
  row per `(testset, case-id, dataset-size)` carrying the expected
  pas/c ratio).  `bench/CheckRegression.pas` re-runs the suite,
  compares against baseline, exits non-zero on relative regression
  past `REGRESSION_THRESHOLD_PCT`.  Hooked into CI for small/medium
  tiers; the 10M-row tier stays a manual local gate.
  Landed: src/bench/CheckRegression.pas (645 lines); driver
  bench/check_regression.sh; pinned bench/baseline.json (50 cells).
  - [X] **11.7.repin** 2026-05-16: re-pinned baseline from MAX-of-9
    local runs.  Measured run-to-run noise across the 9-run window:
    median per-cell max/min = 3.3x, 75th-pct = 7.8x (size=1
    speedtest1 workloads are 1ms-quantised by GetTickCount64 so
    most cases take 1-50ms and quantisation dominates the signal).
    Decision = path (b) re-pin per task heuristic — all observed
    "regressions" flip status (FAIL ↔ BETTER) across consecutive
    runs of the *same* unmodified binary, none are concentrated on
    a recent commit, so the 13-18 cells the stale baseline flagged
    were pure measurement noise.  Also: (i) raised per-cell NOISE
    filter in CheckRegression.pas from <10ms to <25ms (10ms cells
    carry ±10% intrinsic quantisation per side ≈ ±20% combined
    ratio swing — outside the gate already), (ii) bumped default
    REGRESSION_THRESHOLD_PCT from 10 to 200 in check_regression.sh
    (gate now fires when a cell's ratio exceeds 3x the max
    observed across the pinning window — genuine perf regression).
    Verified 6 consecutive runs all PASS.
    Re-pin recipe: collect N≥9 runs of check_regression.sh into
    /tmp/regression_out{,2..N}.txt, then re-derive ratios using
    max-of-N (see baseline.json _comment).  Cite: bench/baseline.json
    _comment, bench/check_regression.sh header.

- [X] **11.8** Pragma / config matrix.  Re-run `testset_main` across
  the cartesian product `journal_mode ∈ {WAL, DELETE}`,
  `synchronous ∈ {NORMAL, FULL}`,
  `page_size ∈ {4096, 8192, 16384}`,
  `cache_size ∈ {default, 10× default}`.  Emit a single matrix
  table; the interesting result is *which knobs move the pas/c
  ratio*.
  Landed: src/bench/PragmaMatrix.pas (505 lines) → bench/pragma_matrix.txt
  (24-cell ratio table); driver bench/run_pragma_matrix.sh.

- [x] **11.9** Profiling hand-off to Phase 9.  Wrapper scripts that
  run `passpeedtest1` under `perf record` and
  `valgrind --tool=callgrind`, plus a small Pascal helper that
  annotates the resulting reports against `passqlite3*.pas` source
  lines.  Output of this task is the input of 9.1.
  Landed: bench/profile_perf.sh, bench/profile_callgrind.sh,
  src/bench/AnnotateProfile.pas (built via src/bench/build.sh).
  Harness now compiles with -gl -gw3 DWARF for symbol→line.
  Overrides: PROFILE_SIZE / PROFILE_TESTSET env vars.

---

## Phase 12 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [X] **12.1** `perf record` on benchmark workloads; identify the
  top 10 hot functions.
  - Profiler used: callgrind (perf unavailable —
    `perf_event_paranoid=4`, no CAP_PERFMON / sudo).
  - Workload: `passpeedtest1 --testset main --size 1`, 248 M Ir.
  - Report: `bench/HOT10.md`.
  - Top 3: `sqlite3VdbeExec` 17.94 %,
    `sqlite3VdbeRecordCompare` 8.70 %, `System.Move` 5.05 %.
  - [ ] **12.1.followup.bigger-sample** Re-run callgrind at
        `--size 5` once `--testset main --size 5` SQLITE_CORRUPT
        note in `profile_perf.sh` is cleared, to confirm
        ranking holds on larger tables.

- [~] **12.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.  Headline candidate.2 landed
  (xRecordCompare fast-path dispatch); secondary inline candidates
  (1, 3..11) still open.
  - [ ] **12.2.candidate.1** Inline `sqlite3VdbeSerialGet`
        (passqlite3vdbe.pas:2050) — 1.20 % self, called from
        every `OP_Column` step.
  - [X] **12.2.candidate.2** Specialise `sqlite3VdbeRecordCompare`
        on int-key + string-key fast paths — port of vdbeaux.c
        `vdbeRecordCompareInt` / `vdbeRecordCompareString` /
        `sqlite3VdbeFindCompare` (vdbeaux.c:4971..5181) landed at
        passqlite3btree.pas:3396..3568.  Callgrind self-time on
        the generic comparator dropped from 8.70 % (21.6 M Ir)
        to 1.95 % (4.65 M Ir); two new specialised entries cost
        2.22 % (Int) + 1.41 % (Str) for **combined 5.58 %** —
        a net 3.12 % cut and ~9 M total program Ir saved on the
        speedtest1 main testset (248.3 M → 239.3 M).  Bench
        regression sweep shows ~22 BETTER vs baseline (several
        sub-tests -50 % to -75 %).  Note: Pas merged
        `RecordCompareWithSkip` into the generic comparator,
        so the bSkip=1 trailing-field path falls back to the
        generic (correct, ~1 % win left on the table vs C).
  - [ ] **12.2.candidate.3** Cache `pPage^.aData` / `aCellIdx` /
        `maskPage` in locals at the top of
        `sqlite3BtreeIndexMoveto` (passqlite3btree.pas:3452) —
        4.95 % self.
  - [ ] **12.2.candidate.4** Same field-cache trick on
        `sqlite3BtreeTableMoveto` (passqlite3btree.pas:2909) —
        1.95 % self.
  - [ ] **12.2.candidate.5** Investigate the **two** definitions
        of `patternCompare` at passqlite3codegen.pas:54136 and
        :58452; dead-code-drop the duplicate, then evaluate
        AVX2 byte-search for the `noCase=0, esc=0` arm —
        combined 2.29 %.
  - [ ] **12.2.candidate.6** Reduce zero-fill churn: audit
        `sqlite3DbMallocZero` / `VdbeMakeReady` /
        `pcache1FetchNoMutex` for FillChar calls that could be
        replaced by reuse (low priority, ~1.5 %).
  - [ ] **12.2.candidate.7** Inline `sqlite3VdbeRecordUnpack`
        (passqlite3vdbe.pas:2263) and hoist `pKeyInfo^.nAllField`
        — 1.10 % self.
  - [ ] **12.2.candidate.8** Inline `btreeParseCellPtr`
        (passqlite3btree.pas:918) — 0.80 % self, called from
        every cell access.
  - [ ] **12.2.candidate.9** Audit `fillInCell` / `insertCellFast`
        for redundant payload Move calls (low priority).
  - [ ] **12.2.candidate.10** Inline `freeSpace`
        (passqlite3btree.pas:1284) — 0.98 % self.
  - [ ] **12.2.candidate.11** Hand-tune `sqlite3GetVarint`
        (passqlite3util.pas) — varint decode is in many hot
        paths, ~0.46 % self plus inclusive presence in #2/#10.

- [ ] **12.3** Consider replacing the VDBE big `case` with threaded
  dispatch (computed-goto-style) using `{$GOTO ON}`.  Land only if
  profiling shows the switch is a real bottleneck.
  - [ ] **12.3.candidate.1** Strip UnicodeString round-tripping
        in `passpeedtest1.pas` glue (DefaultUnicode2AnsiMove +
        DefaultAnsi2UnicodeMove + fpc_unicodestr_* together
        ~6 %).  Likely a *harness* fix, not engine — but it
        skews benchmarks vs C and should land before
        threaded-dispatch comparison.
  - [ ] **12.3.candidate.2** `{$GOTO ON}` jump-table dispatch
        for the top-10 hottest VDBE opcodes (`OP_Column`,
        `OP_Next`, `OP_Goto`, `OP_Integer`, `OP_AggStep`,
        `OP_ResultRow`, `OP_IdxGT`, `OP_SeekGE`, `OP_IfNot`,
        `OP_MakeRecord`) — sqlite3VdbeExec is 17.94 % self;
        even a 20 % cut here is ~3.5 % total.  Gate landing on
        measured cycle-level improvement, not Ir.

---

## Phase 13 — Coverage-guided fuzzing (AFL)

Enter after Phase 9 green; independent of Phase 12.  9.3.1 +
9.3.2 already provide the one-shot differential harness and an
8-seed clean sweep — this phase adds coverage-guided mutation on
top.  **FPC-AFL gotcha:** FPC has no `afl-clang-fast` equivalent
(no LLVM instrumentation pass).  Three viable instrumentation
routes — pick in this order:

1. **`afl-as` assembler wedge (preferred).**  Tell FPC to emit
   text assembly and route it through AFL's GAS wrapper:
   `fpc -al -Aas -FD<afl-bin-dir> ...`.  `-al` keeps `.s` files,
   `-Aas` selects GNU `as`, `-FD` points at the directory holding
   `afl-as`.  `afl-as` rewrites every branch site with the AFL
   tramp + shared-memory bitmap update — same mechanism `afl-gcc`
   used before `afl-clang-fast` existed.  ~2x slowdown.  May need
   minor tweaks if FPC's GAS dialect trips the wrapper's pattern
   matcher (older AFL versions assume gcc-style local labels).
2. **QEMU mode (`afl-fuzz -Q`).**  No compiler cooperation;
   instruments at translation time inside patched user-mode QEMU.
   ~5–10x slowdown but bulletproof.  Fallback if (1) fails.
3. **Black-box `afl-fuzz -n`.**  No instrumentation, dumb-fuzz
   only.  Last resort; documented for completeness.

Not viable: pure C shim with `afl-clang-fast` — the shim gets
instrumented but the Pascal callee doesn't, so the bitmap is
empty for the code under test.

Persistent-mode `__AFL_LOOP` is orthogonal to the choice above
and can be added later via a small C entry stub.

- [~] **13.1** AFL wiring.  `src/tests/fuzz/afl-driver.pas` wraps
  9.3.1 for `afl-fuzz` (read input from stdin, write to a tmp
  file, invoke the in-process harness, return AFL-compatible exit
  codes).  Stand up instrumentation route (1), (2), or (3) above;
  document the choice in `src/tests/fuzz/README.md`.  Skip
  gracefully if AFL isn't installed — script must self-report.
  Landed: src/tests/fuzz/afl-driver.pas (slurps stdin, mkstemp-equiv
  in /tmp, FpFork+FpExecv into bin/TestFuzzDiff, propagates rc /
  re-raises signal-death as 128+N for AFL crash bucketing), build-afl.sh
  (route-1 → route-2 → route-3 fallback chain, AFL-missing self-report
  → exit 0), README.md (route table + install + run recipe + 9.3.2
  smoke baseline citation).  Smoke verified on dev host (no AFL):
  default run prints self-report and exits 0; FORCE_BUILD=1 picks
  route (3) and compiles; driver returns rc=3 on empty stdin and
  rc=0 (PASS) on 4 KiB of fuzzdata1.db.  Tmp files cleaned up
  post-exec.  Cite: src/tests/fuzz/afl-driver.pas, build-afl.sh,
  README.md.
  - [ ] **13.1.unverified** Re-run build-afl.sh on a host with afl-fuzz
    installed and confirm route (1) `afl-as` wedge actually completes
    a smoke-fuzz iteration (`AFL_BENCH_JUST_ONE=1 afl-fuzz …`).  Today
    untested — dev host lacks afl-fuzz; only the AFL-missing self-report
    and the route-3 fallback compile path were exercised.

- [X] **13.2** Crash-vs-divergence classifier.  Triage helper
  that separates (a) Pascal crash, (b) C crash, (c) silent
  divergence, (d) timeout.  Each gets its own bucket under
  `src/tests/fuzz/crashes/`.
  Landed: src/tests/fuzz/classify-crash.sh (pure-bash, no AFL
  dependency).  Runs each input through bin/TestFuzzDiff under
  `timeout -k 2 ${TIMEOUT_S:-30}` and dispatches on rc:
    * rc=0       → PASS, skipped (no bucket).
    * rc=2       → `crashes/divergence/` + meta sidecar with the
                   diverged-channel list (parsed from "DIVERGE
                   channel=" stderr lines) + hex-prefix first-diff
                   hints.
    * rc=124     → `crashes/timeout/` (plain `timeout(1)` returns
                   124 on SIGTERM kill — NO `--preserve-status`
                   because that maps to 128+15 indistinguishably
                   from a child SIGTERM crash).
    * rc>=128    → crash bucket; pas-vs-c side picked by stderr
                   heuristic (FPC RTL emits "Runtime error <n>"
                   on Pascal-side death; libsqlite3.so SIGSEGV
                   is silent).  Heuristic documented in README +
                   the script header so operators can override.
    * rc=1/3     → I/O error / malformed dbsqlfuzz frame, skipped.
  Sidecar `<input>.meta.txt` captures: classification, original
  path, harness rc + signal, wall-clock, last stderr line, full
  stderr head (4 KiB).  Default input list = AFL's
  `findings/default/crashes/`; `--copy` preserves originals;
  `--quiet` suppresses per-input lines.  Script exits 2 if anything
  bucketed (CI-gateable), 0 if not.  Per-bucket `.gitkeep` plus
  `crashes/.gitkeep` so directories survive empty in git.
  Smoke-verified all four buckets via synthetic harness stubs
  (/tmp/cc-smoke/fake-*.sh): divergence (rc=2), pas-crash (sig=11
  with FPC stderr), c-crash (sig=11 silent stderr), timeout
  (TIMEOUT_S=2).  Real-corpus run on `src/tests/fuzz/seeds/`
  reports 8/8 PASS, 0 bucketed — matches the 9.3.2 baseline, no
  false positives.  README "Triage workflow" section added.
  Cite: src/tests/fuzz/classify-crash.sh,
  src/tests/fuzz/README.md "Triage workflow",
  src/tests/fuzz/crashes/{pas-crash,c-crash,divergence,timeout}/.gitkeep.
  - [ ] **13.2.unverified** No real-world AFL crash corpus has hit
    the classifier yet — the four-bucket smoke used synthetic
    bash stubs.  Once 13.3's 24h soak surfaces an actual finding,
    re-run `classify-crash.sh` on the AFL crashes/ dir and
    confirm the side-disambiguation heuristic holds (FPC RTL
    Runtime-error preamble is present on every Pascal SIGSEGV
    AFL surfaces).

- [~] **13.3** ≥24 h soak target.  Wrapper script `fuzz-soak.sh`
  with `--duration` (default 24h) and stop-on-first-divergence.
  Not a CI gate — a manual gate documented in README.  Each
  clean soak bumps a counter in `src/tests/fuzz/SOAK_LOG.md` so
  we can prove the wallclock budget over time.
  Landed: src/tests/fuzz/fuzz-soak.sh (--duration / --no-stop /
  --quiet), src/tests/fuzz/SOAK_LOG.md (header + empty ledger).
  Pre-flights via build-afl.sh, picks route from .afl-route, polls
  findings/default/{crashes,hangs}/ every 5 min, hands findings to
  classify-crash.sh on first detection.  Self-reports + exits 0
  when afl-fuzz is missing.  README "Soak workflow" section added.
  - [ ] **13.3.unverified** This host has no AFL install; the
    real-soak path (afl-fuzz launch, bitmap-driven mutation, ledger
    row from a non-trivial run) wasn't exercised — only the AFL-
    missing self-report path was smoke-verified locally.  Re-run
    on an AFL-equipped host with `--duration 30m` once to confirm
    the polling loop, classify-crash hand-off, and SOAK_LOG.md
    row format all behave as advertised.

- [~] **13.4** Coverage-guided seed minimisation.  `afl-cmin` +
  `afl-tmin` pipeline pruning the seed set to the smallest input
  set that still hits every covered branch.  Re-commit the
  minimised seeds when they shrink.
  Landed: src/tests/fuzz/minimize-corpus.sh (--commit / --quiet).
  Runs afl-cmin → seeds.cmin/, then afl-tmin per survivor; prints
  before/after counts + bytes; --commit swaps seeds.cmin/ over
  seeds/, stages, and emits the suggested `git commit` line (never
  auto-commits).  Self-reports + exits 0 when afl-cmin/afl-tmin
  are missing.  README "Seed minimisation" section added.
  - [ ] **13.4.unverified** AFL not installed on this host; only
    the missing-tools self-report path was smoke-verified.  On an
    AFL-equipped host (route 1 or 2 — route 3's empty bitmap makes
    the pipeline a no-op), run the pipeline against the current
    8-seed corpus and re-commit the minimised set when it shrinks.

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

---

## Finding code duplication (port-introduced vs. upstream)

Goal: identify Pascal blocks that repeat without an equivalent repetition in
the upstream C reference. The faithful-port rule means any duplication present
in C is allowed (it lives there for a reason), but duplication that exists
*only* in the Pascal tree is a refactor candidate.

Tooling: `jscpd` (Node-based, token-aware, supports Pascal and C). Requires
`node` + `npm`; no install needed if invoked via `npx`.

### Step 1 — generate JSON reports for both trees

Run from any directory; outputs land in `/tmp/jscpd-out/`.

```
npx --yes jscpd /home/bpsa/app/pas-sqlite3/src \
  --pattern "**/*.pas" \
  --min-tokens 50 --reporters json --output /tmp/jscpd-out/pas

npx --yes jscpd /home/bpsa/app/sqlite3 \
  --pattern "{src,ext}/**/*.{c,h}" \
  --ignore "**/sqlite3.c,**/sqlite3.h,**/tsrc/**,**/parse.c,**/opcodes.c,**/fts5.c,**/fts5parse.c,**/keywordhash.h" \
  --min-tokens 50 --reporters json --output /tmp/jscpd-out/c
```

Notes on the C invocation:
- The amalgamation (`sqlite3.c/h`, `tsrc/`) is excluded — it is a concatenation
  of the split sources and inflates duplication artificially.
- Lemon/awk-generated files (`parse.c`, `opcodes.c`, `fts5.c`, `fts5parse.c`,
  `keywordhash.h`) are excluded — their repetition is mechanical, not human.
- `--min-tokens 50` matches roughly 6–10 lines of body code; raise it to 80–100
  to focus only on substantial clones.

### Step 2 — cross-reference Pascal clones against C

A Pascal file `passqlite3<stem>.pas` is considered to have a C analogue at
`<stem>.c` or `<stem>.h`. A Pascal clone pair `(A.pas, B.pas)` has a "C
analogue" if the corresponding C files also clone with each other (or, for
intra-file clones, if the same C file clones against itself).

Script (paste into `python3 -`):

```python
import json, os, re
from collections import defaultdict

c = json.load(open('/tmp/jscpd-out/c/jscpd-report.json'))
p = json.load(open('/tmp/jscpd-out/pas/jscpd-report.json'))

c_pairs = defaultdict(set)
for d in c['duplicates']:
    a = os.path.basename(d['firstFile']['name'])
    b = os.path.basename(d['secondFile']['name'])
    c_pairs[a].add(b); c_pairs[b].add(a)

def pas_to_c(n):
    m = re.match(r'passqlite3(.+)\.pas$', n)
    return {m.group(1)+'.c', m.group(1)+'.h'} if m else set()

def is_test(path): return '/tests/' in path

tests_only=[]; port_only=[]; cross=[]
for d in p['duplicates']:
    fa, fb = d['firstFile']['name'], d['secondFile']['name']
    a, b   = os.path.basename(fa), os.path.basename(fb)
    ln     = d['lines']
    ta, tb = is_test(fa), is_test(fb)
    if ta and tb:        tests_only.append((ln,a,b)); continue
    if ta or tb:         cross.append((ln,a,b));      continue
    ca, cb = pas_to_c(a), pas_to_c(b)
    hit = any(y in c_pairs.get(x,set()) for x in ca for y in cb)
    if not hit: port_only.append((ln,a,b))

for lst in (tests_only, port_only, cross): lst.sort(reverse=True)
print("test<->test :", len(tests_only), "clones,", sum(x[0] for x in tests_only), "lines")
print("port<->port :", len(port_only),  "clones,", sum(x[0] for x in port_only),  "lines  (no C analogue)")
print("test<->port :", len(cross),      "clones,", sum(x[0] for x in cross),      "lines")
print("\nTop 20 port<->port (port-introduced):")
for ln,a,b in port_only[:20]: print(f"  {ln:3}  {a} <-> {b}")
print("\nTop 20 test<->test (refactor candidates):")
for ln,a,b in tests_only[:20]: print(f"  {ln:3}  {a} <-> {b}")
```

### Step 3 — interpret the output

Three buckets, each with a different meaning:

1. **`port <-> port` with no C analogue** — genuine port-introduced
   duplication. Open the listed line ranges (`jscpd` JSON has `firstFile.start`
   / `firstFile.end`) and check the corresponding C function. Common causes:
   - C used a macro that the Pascal port inlined two or three times.
   - C used a `static inline` helper that the port copy-pasted instead of
     hoisting into a top-level routine.
   Fix by extracting a shared procedure inside the same unit, mirroring the C
   macro/helper.

2. **`test <-> test`** — the test harness has no upstream counterpart, so any
   clone here is by definition port-only. These are the biggest deletion wins.
   Look for families that share boilerplate (open `:memory:`, prep, step,
   compare against `csq_*`); collapse them into a common unit under
   `src/tests/` (e.g. a `DiagCommon.pas` exposing `ProbeOne` / `ProbeRows`).

3. **`test <-> port`** — should be empty. If non-empty, a test is probably
   inlining production code rather than calling it; fix the test.

### Step 4 — don't refactor blindly

Before extracting a helper:

- Confirm the upstream C really has no equivalent repetition. Sometimes the C
  source uses a macro that `jscpd` did not flag because it expands at compile
  time; a Pascal extraction is still correct, but the framing changes from
  "port-introduced" to "missing macro analogue."
- Avoid eliminating duplication that exists because the two Pascal sites are
  intentionally allowed to diverge later (e.g. an extension VFS that may grow
  features the core VFS will not). When in doubt, leave a `// see also <other
  site>` comment instead of extracting.
- Never refactor across the port↔test boundary: tests must stay independent of
  internal helpers to remain a useful oracle.

### Current snapshot (informational, recompute before acting)

At the time this section was written:

| Bucket                              | Clones | Dup lines |
| ----------------------------------- | -----: | --------: |
| Pascal total (`src/**/*.pas`)       |    319 |     6 143 |
| C total (split sources, no amalg.)  |    166 |       — (2.73% of 83k) |
| Pascal `test <-> test`              |    256 |     5 725 |
| Pascal `port <-> port` (no C analog)|     22 |       259 |
| Pascal `test <-> port`              |      0 |         0 |

Headline: ~96% of Pascal's excess duplication lives in the test harness; core
port code only carries ~259 unjustified duplicated lines out of 67 k.
