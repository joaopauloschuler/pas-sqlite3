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
  - [ ] **6.28.6.b** Higher-level `PRAGMA integrity_check` walk arms — pragma.c:1792..2194 (~430 lines C): index-row-count cross-check, full row walk, CHECK / STRICT / UNIQUE / FK / vtab.xIntegrity per-table arms.  6.28.6.a wired the b-tree slice; this slot lands the schema-level integrity arms.  Complexity: L.
  - [X] **6.28.6.a** PRAGMA integrity_check/quick_check wired to emit real OP_IntegrityCk plan (per-attached-db root-page enumeration; pragma.c:1695..1820 + 2195..2217).
  - [X] **6.28.7** `getRowTrigger` / `codeRowTrigger` / `sqlite3TriggerColmask` — stub-was-real (1:1 with trigger.c:1347 / 1231).
  - [X] **6.28.8** Audit pass on high-priority STUB_INVENTORY entries (#1/#2/#5/#6 CLOSED was-real, #4 DRIFTED-S done in 6.28.4).
  - [X] **6.28.9** Medium-priority audit pass — 5 stub-was-real, 1 DRIFTED-XL (#13 sorter PMA-spill deferred to 5.7.b).
  - [X] **6.28.10** Low-priority audit pass — 5 intentional no-ops faithful to C preprocessor-gated empty macros, 2 was-real with banner refresh.

### Closed bugs (kept as ticked stubs)

- [X] **6.10** TestExplainParity closed.
- [X] **6.11** PRAGMA page_count + DROP TABLE remaining gap closed.
- [X] **6.12** sqlite3Pragma full port; DiagPragma all PASS.
- [X] **6.13** `pragma_foreign_key_list(s.name)` (and other table-valued PRAGMA functions). Sub-bugs A/B/C all closed; lateral join with hidden-arg pushdown wired through `whereLoopAddVirtual` + Case-1 codegen + WhereBegin OP_VOpen. See also subtasks 6.13.B.1..B.10 (all closed).
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
- [X] **6.31** unix-VFS locking-style shims — `unix-none`/`unix-dotfile`/`unix-excl` siblings auto-registered (os_unix.c:8499..8542). Limitation: 4 VFS records share one `xOpen`; `pAppData`→finder dispatch not yet wired through `unixOpen` (sibling names use base posix `unixIoMethods` rather than nolock/dotlock locking). Functional locking-style dispatch + dotlock machinery is a follow-up.
- [X] **6.13.B.11** `.expert` `(no new indexes)` — eponymous-vtab fast arm in `sqlite3Select` was firing for every single-source vtab SELECT, suppressing WHERE/ORDER BY pushdown. Fast arm now restricted to bare `SELECT … FROM <vtab>` shape; other shapes fall through to `sqlite3WhereBegin → whereLoopAddVirtual`.

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

- [X] **9.1.3.followup** Full MANIFEST coverage via `src/tests/SQLLiteralExtractor.pas` (parses `Add(...)`/`Probe(...)` plus label-less anchors). 51 tier-1+tier-2 entries, 2259 scripts; first-pass surfaced 52 divergences cataloged to `src/tests/DIVERGENCES.md` (skip-and-cite contract).

- [X] **9.1.4** Determinism scrub — `CorpusOracle.ApplyHeaderMask` zeros 4 verified byte ranges (24..27 change counter, 56..59 text encoding default, 92..95 version-valid-for, 96..99 SQLITE_VERSION_NUMBER); justifications in `src/tests/corpus/MASK.md`. Mask flipped db-blob channel on; cumulative divergence count 52 → 77, all in `DIVERGENCES.md`.

- Triage of `DIVERGENCES.md` clusters surfaced by 9.1.3.followup + 9.1.4
  (77 cataloged sites, ~7 distinct root causes — each a Pascal-only bug
  bisectable against the C oracle, skip-and-cite per the corpus contract):
  - [X] **9.1.divbug.1** RELEASE-without-SAVEPOINT errmsg wording (44 sites) — OP_Savepoint not-found arm now formats `"no such savepoint: %s"` via sqlite3VdbeError variadic formatter (vdbe.c:3902 parity).
  - [X] **9.1.divbug.2** PRAGMA mmap_size / journal_mode output shape (3 sites) — default table seeds `mmap_size=0`; `journal_mode` read arm queries the actual pager instead of hard-coding `"memory"` (pragma.c:951..978 / 734..771).
  - [X] **9.1.divbug.3** DROP INDEX errmsg truncation (1 site) — `"no such index: %s"` formatted via sqlite3MPrintf (build.c:4614 parity).
  - [X] **9.1.divbug.4 / .5 / .6 / .7 / .8** Five DiagAnalyze/FeatureProbe/Dml/DropTable/Bloom sites — single root cause: `sqlite3WritableSchema` was reading bit `0x20` (SQLITE_CacheSpill) instead of `0x01` (SQLITE_WriteSchema, sqliteInt.h:1829), so `sqlite3CheckObjectName` short-circuited on writable_schema=ON. Bit-mask fix at codegen.pas:36421 + companion shell `paramTableInit` toggle of SQLITE_DBCONFIG_WRITABLE_SCHEMA around `CREATE TABLE IF NOT EXISTS temp.sqlite_parameters` (shell.c.in:2964).

- [X] **9.1.5** Corpus status tags landed in `src/tests/corpus/STATUS.txt` (`pas-strict`/`pas-soft`/`pas-skip` with cite); strict gate fires `Halt(1)` on any pas-strict divergence. Current: 35 pas-strict / 0 diverge.

- [X] **9.1.6** Coverage check.
  *Coverage hook lives in `passqlite3vdbe.pas:gVdbeOpCoverage[]` /
  `gVdbeOpCoverageEnabled` (single predictable branch in the
  dispatcher, default-off zero cost).  `bin/TestSQLCorpus --coverage`
  flips the flag, runs the corpus + 14-script coverage-driver inline
  set, then asserts every cold opcode is allow-listed in
  `IsCoverageGap`.  Snapshot: 145 hot / 47 catalogued in
  `src/tests/corpus/COVERAGE_GAPS.md` / 0 real cold.  Allow-list
  entries each cite the planner shape that gates them.*

### 9.2 `TestReferenceVectors.pas` — canonical `.db` snapshots

- [X] **9.2.1** Vector inventory — 9 new `.sql`+`.db` pairs under `src/tests/vectors/` (autovacuum, incrvacuum, utf16, withoutrowid, generated-column, triggers, view-cte, partial-index, wal); fts5+rtree `.sql`-only [SKIP]; legacy simple/multipage tagged [~] (3.45.x vintage, EQUIV_LIST in regen.sh). wal.db carries journal_mode=WAL in header bytes 18..19; .db-wal sidecar non-deterministic (random salt) and not committed. See `src/tests/vectors/MANIFEST.txt`.

- [~] **9.2.2** Read-only parity probe — `bin/TestVectorReadOnly` + per-vector `*.queries.sql` (11 vectors). Bucket-A FIXED in 9.2.divbug.A (btreeBeginTrans wrflag gate); the unioned pas-skip list now covers bucket-F (autovacuum/incrvacuum), bucket-G (utf16), bucket-H (withoutrowid), bucket-I (wal/multipage/generated-column round-trip drift) and bucket-J (triggers round-trip crash) plus bucket-C/E for view-cte/partial-index — but those buckets affect 9.2.3/9.2.4 only.  RO probe today: gated=1 ok=1 diverged=0 skipped=10 rc=0; the actual fix lifted SQLITE_READONLY for every vector and the remaining skips are pre-existing non-RO bugs surfaced after bucket-A was lifted.

- [~] **9.2.3** Round-trip probe — `bin/TestVectorRoundTrip` + per-vector `<name>.mutate.sql` (11 mutators each exercising the vector's feature). Re-uses `CorpusOracle.ApplyHeaderMask`. Today: gated=1 ok=1 diverged=0 skipped=10 rc=0 (bucket-A umbrella lifted; the 3 round-trip cell-layout divergences it was masking are now triaged under bucket-I, and the triggers round-trip crash under bucket-J).

- [~] **9.2.4** Schema-change probe — `bin/TestVectorSchemaChange` + per-vector `<name>.schema.sql` (8 vectors). Opens RW so does NOT inherit bucket-A; surfaced 4 new buckets (B/C/D/E — see 9.2.divbug.* below). Today: gated=4 ok=4 diverged=0 skipped=4 rc=0; the 4 OK vectors (simple/multipage/generated-column/triggers) exercise AddColumn + OP_ParseSchema byte-identically against C.

- [X] **9.2.5** Vector regen script — `src/tests/vectors/regen.sh` walks every `*.sql`, regenerates via C oracle, `cmp`s against committed blob. Skip-tagged (fts5/rtree) skipped; legacy simple/multipage fall back to .dump equivalence (EQUIV_LIST, 3.45.x vintage). Clean run: 11 OK + 2 skipped + 0 mismatch, rc=0.

- Triage of `src/tests/vectors/DIVERGENCES.md` clusters surfaced by
  9.2.2 / 9.2.3 / 9.2.4 (5 buckets, each a Pascal-only port bug
  bisectable against the C oracle — skip-and-cite per the corpus
  contract; mirrors the `9.1.divbug.*` pattern):
  - [X] **9.2.divbug.A** Read-only open trips `SQLITE_READONLY` on
    first SELECT.  Root cause: `btreeBeginTrans`
    (`passqlite3btree.pas:6341`) gated SQLITE_READONLY on `BTS_READ_ONLY`
    alone, omitting the `wrflag <> 0` conjunct present in
    `../sqlite3/src/btree.c:3622`.  Fix: add the `wrflag` conjunct so
    read transactions on read-only btrees succeed.  Lifting the
    bucket-A umbrella surfaced bucket-F (PRAGMA auto_vacuum RO returns
    0 instead of 1/2), bucket-G (PRAGMA encoding RO garbled), bucket-H
    (WITHOUT ROWID RO sweep aborts mid-schema), bucket-I (round-trip
    cell-layout drift on wal/multipage/generated-column) and bucket-J
    (round-trip trigger-fire EAccessViolation), all triaged below.
  - [ ] **9.2.divbug.F** PRAGMA auto_vacuum returns 0 on RO-open while
    C oracle returns 1/2 (sites: autovacuum.db, incrvacuum.db).  Likely
    surface: `pBt^.autoVacuum` not populated from page-1 header bytes
    36..39 under the readonly lockBtree arm.  C ref:
    `../sqlite3/src/btree.c lockBtree`.
  - [ ] **9.2.divbug.G** PRAGMA encoding returns garbled UTF-8 of the
    UTF-16 cookie on RO-open (1 site: utf16.db).  Likely surface:
    `sqlite3InitOne` text-encoding arm not propagating cookie encoding
    into `db^.enc` under the RO path.  C ref:
    `../sqlite3/src/prepare.c sqlite3InitOne`.
  - [ ] **9.2.divbug.H** WITHOUT ROWID RO sweep emits first 5 rows
    then errors `database disk image is malformed` (rc=11) (1 site:
    withoutrowid.db).  Likely surface: page-key decode in read cursor.
    Adjacent to bucket-D (CREATE INDEX byte divergence on WITHOUT
    ROWID).  C ref: `../sqlite3/src/btree.c` cell-key decode for
    WITHOUT ROWID indexes.
  - [ ] **9.2.divbug.I** Round-trip mutator produces byte-different
    `.db` blob — leaf-cell area divergence (3 sites: wal/multipage/
    generated-column).  Likely surface: cell-packing / freeblock /
    freelist ordering mismatch.  C ref:
    `../sqlite3/src/btree.c dropCell / insertCell / allocateSpace`.
  - [ ] **9.2.divbug.J** Round-trip mutator on triggers.db crashes
    with EAccessViolation when the BEFORE/AFTER row triggers fire (1
    site).  Likely surface: NULL deref in `codeRowTrigger` /
    NEW-OLD column reference codegen.  C ref:
    `../sqlite3/src/trigger.c codeRowTrigger`.
  - [ ] **9.2.divbug.B** Bare `VACUUM;` raises `EAccessViolation` on
    the Pascal port (1 site: autovacuum vector).  Almost certainly the
    unported `incrVacuumStep` / `relocatePage` / `modifyPagePointer`
    arms enumerated in **6.28** (gated on productive ptrmap).  Cross-
    link: closing 6.28's incremental-vacuum step closes this bucket.
  - [ ] **9.2.divbug.C** `ALTER TABLE … RENAME COLUMN/TABLE` on tables
    with a dependent VIEW or CTAS-derived table raises
    `EAccessViolation` in `renameColumnFunc` → `renameTokenFind` NULL
    deref (1 site: view-cte vector).  Cross-check against
    `../sqlite3/src/alter.c renameTokenFind` and the
    `addcolumn_renametokenmap` memory note.
  - [ ] **9.2.divbug.D** `CREATE INDEX` on a WITHOUT ROWID table
    produces byte-different b-tree page payload vs the C oracle (1
    site: withoutrowid vector).  Cross-check
    `../sqlite3/src/build.c sqlite3CreateIndex` + `btree.c` cell
    packing for index-on-WITHOUT-ROWID-with-PK-suffix.
  - [ ] **9.2.divbug.E** `ALTER TABLE … RENAME COLUMN` on a table
    referenced by a partial index produces byte-different
    `sqlite_master` row (1 site: partial-index vector).  Cross-check
    `../sqlite3/src/alter.c sqlite3AlterRenameColumn` for the partial-
    index DDL rewrite arm.

- [ ] **9.2.3.followup** `bin/TestVectorRoundTrip` currently inherits
  the bucket-A `pas-skip` block from MANIFEST and therefore skips all
  11 vectors — but bucket-A is a *read-only* open bug; round-trip
  opens RW and could exercise these vectors for real.  Fix the gate
  to consult only buckets that actually apply to RW round-trip
  (drop the bucket-A inheritance for this specific binary), re-run,
  and triage whatever new buckets surface into 9.2.divbug.* slots
  above.  Without this, 9.2.3 is a silent no-op gate.

- [ ] **9.1.6.followup** Categorize the 47 cold opcodes currently
  allow-listed in `src/tests/corpus/COVERAGE_GAPS.md` into either
  (a) gated on an unported feature → cite the Phase 6/7/8 bullet
  (e.g. FTS5, R-tree, STAT4, PMA disk-spill 5.7.b) and keep
  allow-listed; or (b) reachable from current `passqlite3codegen.pas`
  paths → land a targeted `.sql` driver and drop from the allow-list.
  Goal: shrink the allow-list to (a)-only so it stops being a silent
  escape hatch for new gaps.

### 9.3 `TestFuzzDiff.pas` — differential fuzzer

- [ ] **9.3.1** In-process harness.  `TestFuzzDiff.pas` reads a single
  `dbsqlfuzz`-format input (db prefix + SQL tail per upstream
  `test/fuzzcheck.c` — read its `ossfuzz_set_data` / db-prefix parser
  for the exact frame layout before implementing), runs it under both
  oracles in isolated workdirs, byte-diffs all four output channels
  (stdout, stderr, rc, db-blob — reuse `src/tests/CorpusOracle.pas`
  plumbing rather than re-implementing).  Apply the existing
  `ApplyHeaderMask` from 9.1.4 to the db-blob channel.  No AFL yet —
  just the one-shot driver that AFL will later call.

- [ ] **9.3.2** Seed corpus import.  Pull the upstream `dbsqlfuzz`
  seed set from `../sqlite3/test/fuzzdata*.db` (8 seed files as of
  2026-05-12) into `src/tests/fuzz/seeds/`.  Run the one-shot driver
  across every seed.  Any divergence is catalogued in
  `src/tests/DIVERGENCES.md` per the skip-and-cite contract
  established by 9.1.3.followup — do **not** chase fixes during this
  task; just surface and bucket each cluster.  Each cluster then
  becomes a `9.3.divbug.N` follow-up bullet (mirroring the
  `9.1.divbug.*` pattern).

- [ ] **9.3.3** AFL wiring.  `src/tests/fuzz/afl-driver.pas` wraps
  9.3.1 for `afl-fuzz` (read input from stdin, write to a tmp file,
  invoke the in-process harness, return AFL-compatible exit codes).
  **FPC-AFL gotcha:** FPC has no `afl-clang-fast` equivalent (no LLVM
  instrumentation pass).  Realistic options: (a) `afl-gcc` with
  deferred instrumentation via FPC's `{$LINKLIB}` + a small C
  shim that hosts the `__AFL_LOOP` macro; (b) black-box
  `afl-fuzz -n` (no instrumentation, dumb-fuzz only — much lower
  coverage but always works); (c) port the persistent-mode entry
  to a thin C wrapper that calls into the Pascal harness via
  `cdecl`.  Pick whichever the first agent can stand up cleanly;
  document the choice in `src/tests/fuzz/README.md`.  Skip
  gracefully if AFL isn't installed — script must self-report.

- [ ] **9.3.4** Crash-vs-divergence classifier.  Triage helper that
  separates (a) Pascal crash, (b) C crash, (c) silent divergence,
  (d) timeout.  Each gets its own bucket under `src/tests/fuzz/crashes/`.

- [ ] **9.3.5** ≥24 h soak target.  Wrapper script `fuzz-soak.sh`
  with `--duration` (default 24h) and stop-on-first-divergence.
  Not a CI gate — a manual gate documented in README.  Each clean
  soak bumps a counter in `src/tests/fuzz/SOAK_LOG.md` so we can
  prove the wallclock budget over time.

- [ ] **9.3.6** Coverage-guided seed minimisation.  `afl-cmin` +
  `afl-tmin` pipeline pruning the seed set to the smallest input set
  that still hits every covered branch.  Re-commit the minimised
  seeds when they shrink.

### 9.4 SQLite Tcl test suite as alternate target

- [ ] **9.4.1** Inventory.  Walk `../sqlite3/test/*.test` and tag each
  file `tcl-feature` (uses only public API — candidate), `tcl-internal`
  (touches `sqlite3_test_control` / private symbols — skip), or
  `tcl-perf` (defer to Phase 11).  Land `src/tests/tcl/MANIFEST.txt`.

- [ ] **9.4.2** Tcl binding shim.  Reuse / port the minimum of
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

- [ ] **9.4.3** Driver `src/tests/TclTestDriver.pas`.  Spawns
  `tclsh` against each manifest entry with the port's shim
  preloaded; collects pass/fail/skip per test.  Output format:
  one line per test (`PASS|FAIL|SKIP <path> <assertions> <duration>`),
  matching upstream's `make test` log shape.  The gate is "every
  `tcl-feature` test exits 0 or matches the upstream skip list".
  Per the skip-and-cite contract from 9.1.3.followup, divergences
  surface into `src/tests/tcl/DIVERGENCES.md` rather than blocking
  the driver — each cluster becomes a `9.4.divbug.N` follow-up
  bullet for triage.

- [ ] **9.4.4** Skip-list curation.  Tests that depend on
  `sqlite3_test_control`, `PRAGMA legacy_*`, or other internal
  knobs land in `src/tests/tcl/SKIP.md` with a citation to the
  Phase 6/7/8 bullet that gates them.  Empty skip-list is the
  long-term goal; closed bullets prune entries here.

- [ ] **9.4.5** Linux-only nightly.  Wire into CI as a *nightly*
  job (not per-commit — the Tcl suite is ~hours).  PR gate stays
  on 9.1 / 9.2 / 9.3.1's seed-set sweep.

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

- [X] **10.1e** Gate: src/tests/TestShellMeta.pas (10.1e.G, 48/48 PASS) across .help/.show/.eqp/.explain/.cd/.shell/.system/.stats/.trace/.testcase/.testctrl/.iotrace/.scanstats/.selecttrace/.wheretrace/.timer/.log within their deterministic scope. Non-debug-build arms (`.iotrace`, `.selecttrace`, `.wheretrace`) are silent rc=0/rc=1 fall-through to match the undefined SQLITE_DEBUG / SQLITE_ENABLE_IOTRACE / SQLITE_ENABLE_SELECTTRACE C build.
- [X] **10.1.28..10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`, `.show`, `.help`, `.cd`, `.shell`/`.system`, `.trace` landed.
- [X] **10.1.36** `.log` — destination recorded and SQLITE_CONFIG_LOG xLog trampoline installed (8.1.1 landed).
- [X] **10.1.38** `.iotrace` — stub; full sqlite3IoTrace fanout gated on sqlite3VdbeIOTraceSql arm (currently a stub at passqlite3vdbe.pas:4122).
- [~] **10.1.39** `.scanstats` — basic per-loop dump landed via 8.2.1 (NAME/EXPLAIN/EST/SELECTID/PARENTID emitted). Sub-arms a..e all closed:
  - [X] **10.1.39.a** TWhereLevel.addrVisit field added; NVISIT unblocked (port of wherecode.c:333..374).
  - [X] **10.1.39.b** NLOOP/nExec confirmed; removed two stale addrBody overrides inside sqlite3WhereCodeOneLoopStart.
  - [X] **10.1.39.c** qrfEqpStats EQP-tree formatter ported (ext/qrf/qrf.c:162..454); `|--`/`` `--`` connectors + qrfApproxInt64 K/M/G/T/P/E suffix.
  - [X] **10.1.39.d** NCYCLE / hwtime sampling — `nCycle: u64` on TVdbeOp; `sqlite3Hwtime` ported (rdtsc on x86_64, mrs cntvct_el0 on aarch64, clock_gettime fallback); dispatch-loop bracket gated on `{$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}` (env-var enabled in build.sh; default-off zero overhead). Sub-arms d.1..d.5 closed.
  - [X] **10.1.39.e** EXPLAIN text re-enabled: SCANSTAT_EXPLAIN gates on p4type=P4_DYNAMIC; displayScanstats prefers EXPLAIN string over zName.

  Upstream's "Warning: .scanstats not available in this build." is still echoed verbatim to keep TestShellMeta golden diff clean.
- [X] **10.1.40** `.testcase NAME` / `.check ANSWER` — capture via fd-level
  dup2 onto a temp file (same plumbing as `.output`); `.check` reads it
  back and compares under default (CR/LF-stripped memcmp) / --glob /
  --notglob / --exact.  Fail diagnostic and shellMain summary line
  ("%d test(s) run with %d error(s)\n") match upstream byte-for-byte;
  rc becomes nTestErr>0.  Tested by TestShellMeta `check-*` arms.
  Deferred: dotCmdError caret-formatted location prefix (richer than our
  "Error: ...\n") — kept out of the byte-diff for the error paths, and
  the "<<ENDMARK" multi-line PATTERN form (needs seekable PFILE input).
  Doable follow-up subtasks:
  - [X] **10.1.40.a** `shellDotError` helper landed (caret-formatted location prefix mirroring dotCmdError shell.c.in:1815..1844). Two `.check` sites routed through it; TestShellMeta `dotcmd-error-caret` arm byte-diffs against upstream.
  - [X] **10.1.40.a.followup** Remaining `.check`/`.testcase` cluster Error sites routed through `shellDotError`. Caveat: upstream's cli_output_capture swallows stdout+stderr while a testcase is armed; our fd-level capture only redirects fd 1, so cmdCheck cluster errors leak to real stderr (extending capture to fd 2 is a separate follow-up).
  - [X] **10.1.40.b** `<<MARK` heredoc PATTERN form for `.check` (shell.c.in:8790..8802); 3 new TestShellMeta arms byte-diffed against upstream.
- [X] **10.1.41** `.testctrl` — dispatcher routes through 8.4.1 overloads
  for OPTIMIZATIONS, FK_NO_ACTION, PRNG_SEED, PENDING_BYTE, SORTER_MMAP,
  ASSERT/ALWAYS, LOCALTIME_FAULT, NEVER_CORRUPT, EXTRA_SCHEMA_CHECKS,
  INTERNAL_FUNCTIONS, JSON_SELFCHECK, plus the existing PRNG/BYTEORDER.
  Remaining opcodes (BITVEC_TEST, FAULT_INSTALL, IMPOSTER, TUNE,
  PARSER_COVERAGE) fall through to the generic isOk=3 stub — those need
  callback / coverage infrastructure not yet ported.
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — command
  shape + TRACEFLAGS toggle landed: sqlite3TreeTrace/sqlite3WhereTrace
  u32 globals now mutate through sqlite3_test_control(TRACEFLAGS, …).
  Trace-emission still gated on consumer-side blocks in codegen.
  **Mask hint convention (verified the hard way across the b.* / a.*
  rounds):** mask numbers written into the subtask bodies below are
  HINTS only — they are often bundle IDs (the planning grouping)
  rather than the literal C bit.  Always verify against
  `../sqlite3/src/sqliteInt.h` (`TREETRACE_*`) or
  `../sqlite3/src/whereInt.h` (`WHERETRACE_*`) before stamping a new
  arm, and note divergences in the commit body.
  Remaining subtasks:
  - [X] **10.1.42.a** TREETRACE first batch landed in select.c → passqlite3codegen.pas: begin/end processing (0x1), after name resolution (0x10), generating column names (0x80), flatten (0x4), constant propagation (0x2000), WhereBegin/End breadcrumbs (0x2). Gated by `{$IFDEF SQLITE_DEBUG}`. Deferred sub-arms enumerated at tail of sqlite3Select. Follow-up subtasks below:
    - [X] **10.1.42.a.1** multiSelect / compound flattener — UNION ALL left/right (select.c:3011, 3030, mask 0x200) landed inline in sqlite3Select.
    - [X] **10.1.42.a.2** Post-flatten / wildcard-expansion — "After flattening" (select.c:4706, 0x4) and "After result-set wildcard expansion" (select.c:6339, 0x8) landed in sqlite3Select body.
    - [~] **10.1.42.a.3** AggInfo / HAVING→WHERE / count-of-view /
      EXISTS→JOIN TREETRACE arms (mask 0x40 / 0x400): `AggInfo`
      adjustments, `HAVING moves to WHERE`, count-of-view rewrite,
      `EXISTS-to-IN` and `EXISTS-to-JOIN` traces in optimizer arms.
      Landed: select.c:7368 ("After EXISTS-to-JOIN optimization:",
      mask 0x100000) inside existsToJoin's hoist tail, and
      select.c:8442 ("After aggregate analysis %p:", mask 0x20) at
      the tail of the main GROUP BY analyzeAggFuncArgs.  Upstream
      C masks are 0x20 / 0x100 / 0x200 / 0x100000 (the tasklist's
      "0x40 / 0x400" referred to the bundle ID, not C bits).
      Deferred (no Pas counterpart yet): havingToWhere (select.c:7047,
      mask 0x100), countOfViewOptimization (select.c:7199, mask 0x200),
      "AggInfo adjusted for Indexed Exprs" (6572) /
      "function expressions converted to reference index" (8609) /
      "Finished with AggInfo" (8937) — none of
      optimizeAggregateUseOfIndexedExpr /
      aggregateConvertIndexedExprRefToColumn / late select_end
      AggInfo teardown are ported yet.
    - [X] **10.1.42.a.4** ORDER BY / window-rewrite / DISTINCT→GROUP BY
      TREETRACE arms (VERIFIED C masks: 0x800 "dropping ORDER BY"
      select.c:7631, 0x40 "after window rewrite" select.c:7693, 0x20000
      "Transform DISTINCT into GROUP BY" select.c:8192).  All three
      landed: "after window rewrite" (mask 0x40) at codegen.pas after
      the sqlite3WindowRewrite call in the window-arm gate; "dropping
      superfluous ORDER BY" (mask 0x800) under 10.1.42.a.11 post `begin
      processing` / pre `sqlite3SelectPrep`; "Transform DISTINCT into
      GROUP BY" (mask 0x20000) under 10.1.42.a.12 post FROM-clause
      analyses / pre trivial-gate guards.
    - [~] **10.1.42.a.5** Outer-join simplification + FROM-subquery
      TREETRACE arms (VERIFIED C masks: 0x1000 FULL/LEFT/RIGHT
      simplifies select.c:7737..7756 — LANDED under 10.1.42.a.7;
      0x800 omit FROM-subquery ORDER BY :7832; 0x4000 WHERE push-down
      :8011 and Change-unused-result-columns :8030; 0x8000 all-FROM
      analysis :8146; 0x20 Finished-with-AggInfo :8937).  Remaining
      four arms deferred:
      - select.c:7708..7877 outer FROM-clause optimization loop:
        JT_LEFT/RIGHT/LTORJ simplifier portion is now ported (a.7);
        the IgnorableOrderby FROM-subquery pOrderBy drop + the
        flattenSubquery arm remain deferred.
      - pushDownWhereTerms + disableUnusedSubqueryResultColumns +
        their 0x4000 TREETRACE arms — LANDED under 10.1.42.a.9.
      - select.c:8136..8149 (the post-FROM-loop snapshot, mask 0x8000)
        — LANDED under 10.1.42.a.10 after count-of-view / pre DISTINCT→
        GROUP BY transform.
      - "Finished with AggInfo" (select.c:8937, mask 0x20) lives in
        the late select_end AggInfo teardown that's already listed
        deferred under 10.1.42.a.6 (a.6.5).
      Land in lock-step with the host ports under 10.1.42.a.6 / future
      optimizer-pass batches.
    - [ ] **10.1.42.a.6** Port the host optimizer helpers gating the
      remaining 10.1.42.a.3 sub-arms: `havingToWhere` (select.c:7047),
      `countOfViewOptimization` (:7199), `optimizeAggregateUseOfIndexedExpr`
      (:6572), `aggregateConvertIndexedExprRefToColumn` (:8609), and the
      `select_end` AggInfo teardown print (:8937).  Each is a host function
      not yet ported; once any one lands, drop its `{$IFDEF SQLITE_DEBUG}`
      TREETRACE arm at the same call site.  Treat as 5 independent
      micro-tasks (a.6.1..a.6.5) when work begins — file as needed.
  - [~] **10.1.42.b** WHERETRACE first batch landed in where*.c → passqlite3codegen.pas: BEGIN/END `addBtreeIdx(%s)` in `whereLoopAddBtreeIndex` (0x800), BEGIN/END `addVirtual()` in `whereLoopAddVirtual` (0x800), Begin/End OR-clause in `whereLoopAddOr` (0x400). Gated by `{$IFDEF SQLITE_DEBUG}`. Follow-up subtasks below:
    - [~] **10.1.42.b.1** Range-scan cost-estimate WHERETRACE arms in
      `whereRangeScanEst` / `whereRangeSkipScanEst` (target tasklist mask
      0x10; upstream actual mask 0x20).  Landed: `Range scan lowers nOut
      from %d to %d` (where.c:2247..2250) at the tail of the Pas
      `whereRangeScanEst` — the only WHERETRACE arm reachable in the
      no-STAT4 build that this project compiles against.  Deferred
      (STAT4-only, no Pas counterpart): `range skip-scan regions`
      (where.c:2036), `STAT4 range scan` (2215), `equality scan regions`
      (2313), `IN row estimate` (2363) — these live inside
      `whereRangeSkipScanEst` / `whereEqualScanEst` / `whereInScanEst`
      which are gated behind `SQLITE_ENABLE_STAT4` and have no Pascal
      port.  Will fold them in once the STAT4 family is ported.
    - [X] **10.1.42.b.2** Subset-cost adjustment in `whereLoopAdjustCost` (mask 0x80, where.c:2711/2720) + 4 covering-index decision arms in `whereLoopAddBtree` (mask 0x200, where.c:4203/4210/4216/4224).
    - [X] **10.1.42.b.3** Virtual-table constraint enumeration — 5 arms in `whereLoopAddVirtual` (mask 0x800, where.c:4720..4794) + 2 in `whereLoopAddVirtualOne` (mask 0xffffffff, where.c:4416/4531).
    - [~] **10.1.42.b.4** Query-planner solver progress WHERETRACE in
      `wherePathSolver` (mask **0x002 / 0x004**, NOT 0x80 — verified against
      sqliteInt.h:1181 / where.c:5857 / :5988 / :6032 / :6129).  Landed the
      two mask-0x002 arms: "---- begin solver" (where.c:5857) and the
      sort-cost increase line (where.c:5988..5991).  The four mask-0x004
      candidate prints (Skip / New / Update / `vs`) at where.c:6032..6101
      and the mask-0x002 "---- after round %d" summary at where.c:6129
      are deferred behind a `TODO 10.1.42.b.4` marker in
      passqlite3codegen.pas — they consume `wherePathName(WherePath*,iLoop,
      WhereLoop*)` which is not yet ported.  Land once wherePathName drops.
    - [~] **10.1.42.b.5** OR-vs-AND / pseudo-index decision WHERETRACE
      in `whereLoopAddOr` (mask **0x400** verified, matches tasklist hint
      and sqliteInt.h:1191 — OR optimization).  Landed the per-subterm
      breadcrumb at where.c:4866..4867: `"OR-term %d of %p has %d
      subterms:"`.  The "Begin processing OR-clause" / "End processing
      OR-clause" arms were already ported in batch 10.1.42.b.
      Deferral note: the tasklist title mentioned "cost compares, pseudo-
      index selection" but where.c review shows whereLoopAddOr itself
      carries only mask-0x400 breadcrumbs — no cost-compare or pseudo-
      index 0x400 arms exist in this function.  The 0x40 (IN-operator)
      and 0x80 (cost-adjustment) arms live in `whereLoopAddBtreeIndex`,
      not `whereLoopAddOr`, and are tracked separately under earlier
      10.1.42.b sub-tasks.  Also deferred behind a `TODO 10.1.42.b.5`
      marker: the companion mask-0x20000 sub-arm `sqlite3WhereClausePrint
      (sSubBuild.pWC)` at where.c:4868..4870 — host helper not yet ported.
    - [~] **10.1.42.b.6** DISTINCT reduction + optimizer-finished
      trailing WHERETRACE in `sqlite3WhereBegin` epilogue.  Mask divergence
      vs tasklist hint: tasklist suggested 0x1 (code generation per
      sqliteInt.h:1180); the actual upstream literals are
      **0x0080** (WhereLoop cost adjustments, sqliteInt.h:1188) for the
      DISTINCT-reduction print at where.c:7118 and **0xffffffff**
      (any-trace) for the "*** Optimizer Finished ***" line at
      where.c:7195.  Both landed in passqlite3codegen.pas — the DISTINCT
      block also carries the `nRowOut -= 30` body that the WHERETRACE
      bracket calls out (tag-20250414a).  Build green pre/post both
      ways: -30 nRowOut shift does not change any TestExplainParity or
      TestWhereCorpus row.  Deferred behind `TODO 10.1.42.b.6`:
        * "---- Solution cost=%d, nRow=%d ... DISTINCT=..." summary
          block at where.c:7132..7157 (consumes sqlite3WhereLoopPrint).
        * mask-0x4000 "---- WHERE clause at end of analysis:" dump at
          where.c:7190..7194 (consumes sqlite3WhereClausePrint).
      Land both once their host printers drop.
    - [ ] **10.1.42.b.7** Port the STAT4 cost-estimator helpers that
      gate the 4 deferred 10.1.42.b.1 arms: `whereRangeSkipScanEst`
      (where.c:2036), `whereEqualScanEst` (:2215 / :2313),
      `whereInScanEst` (:2363).  Each is a STAT4-driven planner helper
      not yet present in passqlite3codegen.pas.  Mask: 0x20 (verified
      against whereInt.h, NOT 0x10 as tasklist initially suggested).
      Treat as 3 independent micro-tasks; drop the WHERETRACE call at
      each host function as it lands.
    - [ ] **10.1.42.b.8** Port the WHERE-clause / where-loop / path
      debug-printer helpers that gate ~7 deferred WHERETRACE arms
      across 10.1.42.b.4/5/6: `wherePathName` (where.c — grep for the
      definition, prints `wherePath` letters), `sqlite3WhereLoopPrint`
      (where.c), `sqlite3WhereClausePrint` (where.c).  All three are
      `#ifdef WHERETRACE_ENABLED` helpers in C.  Port under
      `{$IFDEF SQLITE_DEBUG}` into passqlite3codegen.pas.  High
      leverage: lands `Skip/New/Update/vs` rows in solver progress,
      `Solution cost=` summary, `OR-term sub-WHERE-clause` print,
      `WHERE clause at end of analysis` print.
    - [X] **10.1.42.a.6.1** Ported `havingToWhere` + `havingToWhereExprCb` (select.c:7047) with prerequisite `sqlite3ExprIsConstantOrGroupBy` pair; wired in SF_Aggregate+GROUP-BY path (select.c:8422..8431). 0x100 TREETRACE arm at tail.
    - [X] **10.1.42.a.6.2** Ported `countOfViewOptimization` (select.c:7128..7204); wired after propagateConstants (select.c:7924..7930). 0x200 TREETRACE arm. SQLITE_CountOfView constant added.
    - [X] **10.1.42.a.6.3** Ported `optimizeAggregateUseOfIndexedExpr` (select.c:6549..6586); wired between sqlite3WhereBegin and assignAggregateRegisters (select.c:8527..8529, gated on pParse^.pIdxEpr). 0x20 TREETRACE arm.
    - [X] **10.1.42.a.6.4** Ported `aggregateConvertIndexedExprRefToColumn` + walker callback (select.c:6591..6623); wired after sqlite3WhereEnd (select.c:8600..8615, gated on pParse^.pIdxEpr). 0x20 TREETRACE arm.
    - [X] **10.1.42.a.6.5** Ported "Finished with AggInfo" 0x20 TREETRACE arm at sqlite3Select tail (select.c:8933..8945); pAggI2 pre-zeroed at entry, printAggInfo + aCol/aFunc self-asserts deferred (no host).
      (select.c:8937) so the "Finished with AggInfo" trailing print can land.
    - [X] **10.1.42.a.7** Ported the outer-join strength-reduction inline
      loop (select.c:7708..7770) + prerequisites `sqlite3ExprImpliesNonNullRow`
      / `impliesNotNullRow` / `bothImplyNotNullRow` (expr.c:6857..7031) and
      `unsetJoinExpr` (select.c:471..494).  All four 0x1000 TREETRACE arms
      (FULL→RIGHT, LEFT→JOIN, FULL→LEFT, RIGHT→JOIN) now live under
      `{$IFDEF SQLITE_DEBUG}`.  Wired in sqlite3Select between
      linkWindowsForSelect and existsToJoin.  Added SQLITE_SimplifyJoin
      (0x2000) constant.  flattenSubquery/ORDER-BY-drop arms of the FROM
      loop remain deferred under 10.1.42.a.5 (flattenSubquery itself);
      ORDER-BY-drop landed under 10.1.42.a.8.
    - [X] **10.1.42.a.8** Ported the FROM-clause subquery superfluous-ORDER-BY
      drop (select.c:7822..7838, tag-select-0230) inside the outer FROM-loop
      from 10.1.42.a.7.  Honours all six C conditions plus the MATERIALIZED
      CTE fence and SF_Aggregate skip.  Adds SQLITE_OmitOrderBy (0x40000)
      constant; 0x800 TREETRACE arm prints `omit superfluous ORDER BY on N
      FROM-clause subquery` under `{$IFDEF SQLITE_DEBUG}`.  Drops via
      sqlite3ParserAddCleanup(@sqlite3ExprListDeleteGeneric, pOrderBy).
      Note: this is the FROM-subquery arm — the top-level `IgnorableOrderby`
      drop (select.c:7631, also 0x800) remains under 10.1.42.a.11.
    - [X] **10.1.42.a.9** Ported `pushDownWhereTerms` (select.c:5125..5286)
      and `disableUnusedSubqueryResultColumns` (select.c:5296..5358); wired
      into the FROM-loop body in sqlite3Select right after the omit-ORDER-BY
      arm.  Both 0x4000 TREETRACE arms (`After WHERE-clause push-down into
      subquery N` and `Change unused result columns to NULL for subquery N`)
      land under `{$IFDEF SQLITE_DEBUG}` plus the `WHERE-clause push-down
      not possible` else arm.  Adds SQLITE_PushDown ($1000) and
      SQLITE_NullUnusedCols ($04000000) constants.  Restriction (6c) for
      partition-less window functions is conservatively bailed (no
      pushDownWindowCheck helper port).  TestExplainParity 1026/1026.
    - [X] **10.1.42.a.10** Ported the all-FROM-clause final analysis
      snapshot (select.c:8144..8149, mask 0x8000) post count-of-view /
      pre DISTINCT→GROUP BY transform; wrapped under `{$IFDEF
      SQLITE_DEBUG}` and prints via sqlite3TreeViewSelect.
      TestExplainParity 1026/1026.
    - [X] **10.1.42.a.11** Ported the top-level superfluous-ORDER-BY drop
      (select.c:7625..7644, IgnorableDistinct, mask 0x800) post `begin
      processing` / pre `sqlite3SelectPrep`; clears p^.pOrderBy via
      sqlite3ParserAddCleanup(@sqlite3ExprListDeleteGeneric, ...) and masks
      off SF_Distinct, with 0x800 TREETRACE `dropping superfluous ORDER BY`.
    - [X] **10.1.42.a.12** Ported the DISTINCT→GROUP BY transform
      (select.c:8151..8196, mask 0x20000) post FROM-clause analyses
      (count-of-view) / pre trivial-gate guards.  Gates exactly on
      `(selFlags & (SF_Distinct|SF_Aggregate)) == SF_Distinct`,
      inline sqlite3CopySortOrder over pEList/pOrderBy with matching
      nExpr, sqlite3ExprListCompare = 0, SQLITE_GroupByOrder enabled,
      and pWin = nil.  On hit: clear SF_Distinct, pGroupBy :=
      sqlite3ExprListDup(pEList), seed each new slot's iOrderByCol = i+1,
      set SF_Aggregate.  0x20000 TREETRACE prints `Transform DISTINCT
      into GROUP BY:`.  Closes the last deferred sub-arm of 10.1.42.a.4.
  - [X] **10.1.42.c** `sqlite3DebugPrintf` ported (printf.c:1514..1532) into passqlite3printf.pas; routes through sqlite3FormatStr → stdout+fflush.
  - [X] **10.1.42.d** Build-flag gating: `src/tests/build.sh` honours `SQLITE_DEBUG=1` env var (forwards `-dSQLITE_DEBUG` to fpc); default leaves `{$IFDEF SQLITE_DEBUG}` blocks compiled out. Gate documented in `src/passqlite3.inc`.

### 10.1f Long-tail / specialised dot-commands

- [ ] **10.1f** Out-of-scope dependencies (session, archive, recover) may stub with the upstream `SQLITE_OMIT_*` "feature not compiled in" message. Gate: `tests/cli/10f_misc/`.
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

- [ ] **10.1a.1** fill the next porting chunk here.

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
- [X] **10.1.bug.134** CLI `.parameter set` populated temp.sqlite_parameters but `bind_prepared_stmt` was never ported. Also wired echo_group_input emissions at the four matching processInput cut points. Regression: bin/TestShellParameter, bin/TestShellEcho.
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

- [ ] **11.9** Profiling hand-off to Phase 9.  Wrapper scripts that
  run `passpeedtest1` under `perf record` and
  `valgrind --tool=callgrind`, plus a small Pascal helper that
  annotates the resulting reports against `passqlite3*.pas` source
  lines.  Output of this task is the input of 9.1.

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
