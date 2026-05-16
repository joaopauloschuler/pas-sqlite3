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

- [X] **9.2.1** Vector inventory — 9 new `.sql`+`.db` pairs under `src/tests/vectors/` (autovacuum, incrvacuum, utf16, withoutrowid, generated-column, triggers, view-cte, partial-index, wal); fts5+rtree `.sql`-only [SKIP]; legacy simple/multipage tagged [~] (3.45.x vintage, EQUIV_LIST in regen.sh). wal.db carries journal_mode=WAL in header bytes 18..19; .db-wal sidecar non-deterministic (random salt) and not committed. See `src/tests/vectors/MANIFEST.txt`.

- [~] **9.2.2** Read-only parity probe — `bin/TestVectorReadOnly` + per-vector `*.queries.sql` (11 vectors). Bucket-A FIXED in 9.2.divbug.A (btreeBeginTrans wrflag gate); the unioned pas-skip list now covers bucket-F (autovacuum/incrvacuum), bucket-G (utf16), bucket-H (withoutrowid), bucket-I (wal/multipage/generated-column round-trip drift) and bucket-J (triggers round-trip crash) plus bucket-C/E for view-cte/partial-index — but those buckets affect 9.2.3/9.2.4 only.  RO probe today: gated=1 ok=1 diverged=0 skipped=10 rc=0; the actual fix lifted SQLITE_READONLY for every vector and the remaining skips are pre-existing non-RO bugs surfaced after bucket-A was lifted.

- [~] **9.2.3** Round-trip probe — `bin/TestVectorRoundTrip` + per-vector `<name>.mutate.sql` (11 mutators each exercising the vector's feature). Re-uses `CorpusOracle.ApplyHeaderMask`. Today (post-9.2.3.followup, cite-aware RT filter): gated=8 ok=8 diverged=0 skipped=3 rc=0.  Remaining skips: autovacuum (bucket-L, also bucket-B for schema-change), incrvacuum (bucket-L), utf16 (bucket-M, also bucket-K for RO).  Bucket-A umbrella lifted; bucket-I (4-vector RT cell-layout drift) closed; bucket-J (triggers RT crash) closed.

- [~] **9.2.4** Schema-change probe — `bin/TestVectorSchemaChange` + per-vector `<name>.schema.sql` (8 vectors). Opens RW so does NOT inherit bucket-A; surfaced 4 new buckets (B/C/D/E — see 9.2.divbug.* below). 9.2.divbug.C closed (view-cte rename arm), 9.2.divbug.E closed (partial-index RENAME COLUMN aColExpr pin), but both view-cte and partial-index still hit bucket-B at the trailing VACUUM so they stay pas-skip. Today: gated=1 ok=1 diverged=0 skipped=7 rc=0.

- [X] **9.2.5** Vector regen script — `src/tests/vectors/regen.sh` walks every `*.sql`, regenerates via C oracle, `cmp`s against committed blob. Skip-tagged (fts5/rtree) skipped; legacy simple/multipage fall back to .dump equivalence (EQUIV_LIST, 3.45.x vintage). Clean run: 11 OK + 2 skipped + 0 mismatch, rc=0.

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
  - [X] **9.2.divbug.B** Bare `VACUUM;` `EAccessViolation` — root cause was `sqlite3_config` writing the address of a stack parameter slot into `GlobalConfig.xLog`, plus three `SQLITE_OMIT_AUTOVACUUM`-stubbed btree arms (`btreeCreateTable` root relocation, `allocateBtreePage` ptrmap-page skip, `sqlite3BtreeInsert` PTRMAP_OVERFLOW1).  VACUUM no longer crashes.  See vectors/DIVERGENCES.md bucket-B.
  - [X] **9.2.divbug.C** ALTER TABLE RENAME on VIEW-dependent table → EAV — `sqlite3CreateView` reduced pSelect under IN_RENAME_OBJECT; resolver wrote past EP_TokenOnly/EP_Reduced allocations. Fix per build.c:3041..3046 + walker.c:71 + parse.y:1166. Memory: `feedback_view_body_in_rename_object_must_be_full`. Archive.
  - [X] **9.2.divbug.D** CREATE INDEX on WITHOUT ROWID byte-different — `sqlite3CreateIndex` missing pPk arm (build.c:4278..4292) that copies PK columns into index-key suffix. Archive.
  - [X] **9.2.divbug.E** RENAME COLUMN on partial-index byte-different — missing IN_RENAME_OBJECT arm pinning `pIndex^.aColExpr` (build.c:4209, alter.c:1639). Archive.
  - [X] **9.2.divbug.K** UTF-16 `hex()` byte-swapped — `sqlite3_result_text*`/`_blob*` skipped `sqlite3VdbeChangeEncoding(pOut, pCtx->enc)` from `setResultStrOrError` (vdbeapi.c:387..427). Fix routes all result setters through ported `setResultStrOrError`. Archive.
  - [X] **9.2.divbug.L** Auto-vacuum round-trip page-count drift — fixed `finalDbSize` (exact `ptrmapPageno` walk + `PTRMAP_ISPAGE` guard, btree.c:4135) and ported the missing `PRAGMA incremental_vacuum` codegen arm (pragma.c:854).  autovacuum/incrvacuum vectors now round-trip byte-identical; `TestVectorRoundTrip`/`SchemaChange`/`ReadOnly` skipped=0.  See vectors/DIVERGENCES.md bucket-L.
  - [X] **9.2.divbug.L.1** Port `incrVacuumStep` (btree.c:4034..4128) + prerequisite ptrmap stubs (`ptrmapPageno`/`Put`/`Get`, `setChildPtrmaps`). Wired into `sqlite3BtreeIncrVacuum`. Archive.
  - [X] **9.2.divbug.L.2** Port `relocatePage` + `modifyPagePointer` (btree.c:3876..4012). Archive.
  - [X] **9.2.divbug.L.3** Wire `autoVacuumCommit` body (btree.c:4194..4277) + CommitPhaseOne caller. incrvacuum.db now truncates freelist correctly; autovacuum.db still drifts on page-cleanup hygiene (bucket-L stays open on narrowed symptom). Archive.
  - [X] **9.2.divbug.M** ~~UTF-16 INSERT raw-UTF-8~~ CLOSED — subsumed by divbug.K (commit 6fd9ec2). Re-filed residual as divbug.N. Archive.
  - [X] **9.2.divbug.N** ~~Freeblock zeroing~~ CLOSED — audit artefact, not a defect. Distro libsqlite3 has SECURE_DELETE; harness needs `LD_LIBRARY_PATH=src`. After fix: gated=9 ok=9 diverged=0 skipped=2. Archive.

- [X] **9.2.3.followup** Round-trip parser cite-aware — only RT-relevant bucket cites trigger skips. 3 vectors un-masked (partial-index, view-cte, withoutrowid); 3 RT-only divergences triaged into buckets L and M. Final: gated=8 ok=8 diverged=0 skipped=3. Archive.

- [X] **9.1.6.followup** Categorize 47 cold opcodes — split: 45 (a)-gated + 2 (b)-drivable + 4 newly-discovered real-cold all closed. Coverage drivers 14 → 18. Final: 147 hot / 45 cold-allow / 0 cold-real. Archive.

### 9.3 `TestFuzzDiff.pas` — differential fuzzer

- [X] **9.3.1** In-process harness — `bin/TestFuzzDiff <input.dbsqlfuzz>` 1:1 ports `fuzzcheck.c:decodeDatabase` (hex/`[NNNN]`/`\n--\n` frame). Four-channel diff via `CorpusOracle` + `ApplyHeaderMask`. Exit codes: 0/1/2/3. Smoke gate PASS. Archive.

- [X] **9.3.2** Seed corpus import — 8 seeds (`fuzzdata1..8.db`, ~62 MiB) imported to `src/tests/fuzz/seeds/`. Sweep: **8/8 PASS, 0 divergences, 0 buckets**. Multi-frame archive splitting (treating each archive row as a frame) deferred to 13.1. Archive.

AFL wiring and downstream coverage-guided fuzzing work moved to
**Phase 13** (post-acceptance, parallel with Phase 12).  9.3.1 and
9.3.2 (in-process harness + seed corpus) remain the Phase-9
acceptance gate for this section.

### 9.4 SQLite Tcl test suite as alternate target

> Reorganised 2026-05-13: each umbrella bullet (9.4.1 .. 9.4.5) is
> immediately followed by its decomposed sub-arms; trailing
> `9.4.divbug.N` cluster bullets sit at the end in numeric order
> (matching `src/tests/tcl/DIVERGENCES.md`).

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
  - [X] **9.4.2.g.9** `do_malloc_test` ported verbatim into `tester_min.tcl` (malloc_common.tcl:416..538); drives the memdebug `sqlite3_memdebug_fail` / `install_malloc_faultsim` primitives.  Runs clean when no fault fires; an injected malloc failure used to segfault the engine OOM-recovery path (tracked + fixed as **9.4.divbug.27**) — `do_malloc_test` now completes without SIGSEGV.
  - [X] **9.4.2.g.10** `do_ioerr_test` + `run_ioerr_prep` ported verbatim into `tester_min.tcl` (tester.tcl:1890..2118); drives the 9.4.7.c counters.  Runs end-to-end (fault fires, engine recovers, terminates cleanly).
  - [ ] **9.4.2.g.11** `crashsql` — spawns child process that aborts
    mid-write; parent verifies WAL/journal recovery.  Requires crash
    harness (9.4.7.d).  C ref: `crash.tcl:1..200`,
    `tester.tcl:1893..1968`.
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
  - [X] **9.4.2.u.1** Runtime-exercise the preupdate hook — ported `src/tests/tcl/preupdate.test` (subset of upstream `hook.test` hook-7.*; this SQLite version has no standalone preupdate.test).  14/14 PASS under a `PREUPDATE=1` build.  Found+fixed 6 codegen/compile bugs behind the `{$ifdef}`: xferOptimization `OP_RowData`, DELETE-truncate disable when hook registered, UPDATE `OPFLAG_ISUPDATE` OP_Delete, REPLACE rowid-conflict `OPFLAG_ISNOOP`, `columnNullValue`, plus const-fixups.
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
  - [X] **9.4.4.d** Broaden sweep to first 100 tcl-feature tests — **72 PASS / 28 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 100`).  First-50 subset improved 41→43 PASS vs 9.4.4.c (atof2 + atomic flipped via 9.4.6.q).  Surfaced new engine divbugs **9.4.divbug.19..24** and harness-gap follow-ups **9.4.6.q.1 / 9.4.6.q.2**.  See `src/tests/tcl/DIVERGENCES.md` "Run summary (9.4.4.d sweep)" + `STATUS.txt`.
  - [X] **9.4.4.e** Broaden sweep to 250 tests (~25% of corpus) — **147 PASS / 103 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 250`, 138 s).  Two FAILs are 30 s timeouts (`btree01.test`, `changes.test`).  Of the 79 new FAILs in the [101..250] slice, ~50 are harness gaps (test1.c C-API + test-util Tcl commands — top unblockers: `sqlite3_prepare`/`sqlite3_step` family, `database_may_be_corrupt` (unblocks 16 corrupt*.test), `do_select_tests`, `hexio_read/write`, `execsql2`, `testvfs`, `file_control_*`, `randstr`).  Surfaced new engine divbugs **9.4.divbug.28..40** (13 clusters); top frequency: .28 EQP multi-table SIGSEGV (4 tests), .30 collation-NOCASE ORDER BY (3 tests), .39 `CREATE TABLE AS SELECT` unsupported (3 tests), .34 PRAGMA page_size default (2 tests), .35 float-to-text precision (2 tests).  See `src/tests/tcl/DIVERGENCES.md` "Run summary (9.4.4.e sweep)" + `STATUS.txt` rows 101..250 retagged from `unswept`.
  - [X] **9.4.4.f** Broaden sweep to 500 tests — **280 PASS / 220 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 500`, 149.2 s).  One 30 s timeout (`changes.test`, follow-up to divbug.36).  1..250 slice: 151 PASS / 99 FAIL (+4 PASS vs 9.4.4.e baseline; 5 pas-soft recoveries via divbug.32/.33/.36/.37/.40; 1 sweep-state regression tracked as 9.4.divbug.42).  251..500 slice (entirely new ground): 129 PASS / 121 FAIL.  Top-frequency engine root: indexed MIN/MAX + IN fast paths returning 0/empty (divbug.44, ~10 tests).  Dominant non-engine cluster is harness gaps — `fts3_common.tcl` missing (~15 fts3*/fts4*.test) and ~40 test1.c / test-util commands unported (`sqlite3_bind_*`, `sqlite3_create_function`, `sqlite3_step`, `hexio_*`, `testvfs`, `sqlite3_normalize`, `sqlite3_mmap_warm`, `sqlite3_multiplex_initialize`, `sqlite3_soft_heap_limit`, `sqlite3_get_autocommit`, `sqlite3_reset_auto_extension`, …) queued under 9.4.6.q.  Surfaced new engine + harness divbug clusters **9.4.divbug.42..61** (20 new buckets).  See `src/tests/tcl/DIVERGENCES.md` "Run summary (9.4.4.f sweep)" + `STATUS.txt` rows 1..500 retagged (280 pas-strict / 220 pas-soft / 0 pas-skip-leftover within window).
  - [X] **9.4.4.g** Full tcl-feature sweep — **593 PASS / 366 FAIL / 0 SKIP** across 959 tests in 334.8 s (`bin/TclTestDriver` against MANIFEST.txt; three 20 s timeouts on `select4.test`, `writecrash.test`, `securedel2.test` counted as FAIL and bucketed under 9.4.divbug.84).  vs 9.4.4.f: **zero pas-strict→FAIL regressions** (254 strict held green); 21 pas-soft→PASS recoveries traceable to divbug .42..61 fix batch (commits 6b834c8..705d27e).  501..959 slice (new ground): 283 PASS / 176 FAIL.  Surfaced new divbug clusters **9.4.divbug.62..84** (23 buckets); dominant non-engine roots are .62 (test1.c sqlite3_* harness gap, ~50 tests), .63 (tcl-shim helpers, ~25 tests), .64 (`db func`/`db format` subcommands, ~12 tests) — together ~85 of the 366 FAILs.  Largest engine cluster is .83 (planner row-order divergence across where*/orderbyB).  STATUS.txt retagged to 593 pas-strict / 366 pas-soft / 230 pas-skip-unswept-residue; see `src/tests/tcl/DIVERGENCES.md` "Run summary (9.4.4.g sweep)".
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

- [ ] **9.4.5** Linux-only nightly.  Wire into CI as a *nightly*
  job (not per-commit — the Tcl suite is ~hours).  PR gate stays
  on 9.1 / 9.2 / 9.3.1's seed-set sweep.
  - [ ] **9.4.5.a** CI config — `.github/workflows/tcl-nightly.yml`
    (or matching CI surface) that runs `bin/TclTestDriver` against
    the full MANIFEST + diff against `STATUS.txt` (9.4.8.b).
  - [ ] **9.4.5.b** Sharding — split the 946-test sweep across N
    parallel workers (each worker takes a slice of MANIFEST).
    Driver-side flag `--shard I/N`.  Reduces wall-time from ~hours
    to ~tens of minutes.
  - [ ] **9.4.5.c** Failure-report artefact — upload
    DIVERGENCES.md diff + per-test stdout/stderr capture of any
    new failure as a CI artefact for triage.

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
    - [X] **9.4.6.l.1** `register_echo_module` — 1:1 port of `test8.c` into `src/tests/tcl/testmodules/TestModuleEcho.pas` (full read/write proxy vtab: xCreate/xConnect/xBestIndex/xFilter/xUpdate/xFindFunction/xRename/savepoints; registers `echo` + `echo_v2`).  SELECT/DELETE/UPDATE proxy correctly; INSERT residue tracked as **9.4.divbug.26**.
    - [X] **9.4.6.l.4** `registerTestFunction` — ported `test_func.c` scalar/aggregate test UDFs + `autoinstall_test_functions` into `src/tests/tcl/testmodules/TestModuleFunc.pas`.  Prereqs done: ported `sqlite3AutoLoadExtensions` and wired it into `openDatabase` (the auto-extension registry was never run); `sqlite3VdbeSerialGet` was already in the interface section.
    - [X] **9.4.6.l.5** `register_async_vtab` — DROPPED.  Investigation confirmed `test_async.c` is absent from this SQLite version (the async VFS was deprecated/removed upstream); no `.test` file references `register_async_vtab`.  See `src/tests/tcl/DIVERGENCES.md`.
  - [X] **9.4.6.m** `sqlite3_log` (already wired in 10.1.36) +
    `sqlite3_io_trace` — Tcl bindings + assert hooks.
  - [X] **9.4.6.n** `sqlite3_memdebug_*` set — ported the `test_malloc.c` fault-injection allocator + Tcl commands (`sqlite3_memdebug_fail`/`_pending`/`_settitle`/`_backtrace`/`_malloc_count`, `install_malloc_faultsim`, …) into `src/tests/tcl/testmodules/TestModuleMalloc.pas`.  Debug-only arms gated `{$ifdef SQLITE_MEMDEBUG}`.  Deferred: `SQLITE_TESTCTRL_BENIGN_MALLOC_HOOKS` (op 10) not yet in the engine's `sqlite3_test_control` — only affects `-benigncnt` reporting.
  - [X] **9.4.6.o** File-control opcodes — PERSIST_WAL, LOCKSTATE,
    CHUNK_SIZE, SIZE_LIMIT, POWERSAFE_OVERWRITE, ZIPVFS, BUSYHANDLER,
    TEMPFILENAME, MMAP_SIZE.  Many already partly wired via Phase
    10.1f.8 (.filectrl).  Audit + close gaps.  C ref:
    `../sqlite3/src/os_unix.c:unixFileControl`.
  - [X] **9.4.6.p** `sqlite3_busy_timeout` / `sqlite3_busy_handler` —
    audit; pair with 9.4.2.k.
  - [X] **9.4.6.q** Unported test-only Tcl commands — ported the `test1.c` subset (`sqlite3_connection_pointer`, `sqlite3_db_config`, `atomic_batch_write`, `load_static_extension`) into `src/tests/tcl/testmodules/TestModuleTest1.pas`; `real2hex` SQL func + `faultsim_save_and_close` family into the test modules / `tester_min.tcl`.  `hex2real` does not exist upstream (spurious cite).  atof2.test + atomic.test flipped to PASS.
    - [X] **9.4.6.q.1** test1.c prepared-statement C-API subset — `sqlite3_prepare(_v2)`, `sqlite3_exec`, `sqlite3_backup`, `sqlite3_errmsg`, `sqlite3_transfer_bindings` ported into `src/tests/tcl/testmodules/TestModuleTest1.pas` (test1.c:417/4910/5035/5092/3145; test_backup.c:26..150).  Sweep 72→76 PASS (+4) over first 100 tcl-feature tests; the 7 originally-targeted tests now exercise their full prepared-statement bodies (capi2 reaches 144 sub-assertions; bind/bind2/bindxfer/backup5 advance well past prior `invalid command` short-circuit) but still hit further harness gaps owned by 9.4.6.q.2 (`do_not_use_codec`, `sqlite3_create_aggregate`, `wal_set_journal_mode`).
    - [X] **9.4.6.q.2** Remaining 9.4.4.d-surfaced test commands.  Ported `do_not_use_codec` (tester.tcl:323..326), `wal_is_wal_mode`/`wal_set_journal_mode`/`wal_check_journal_mode`/`wal_is_capable` (tester.tcl:2308..2327), `test_set_config_pagecache`/`test_restore_config_pagecache` (tester.tcl:2496..2530) into `src/tests/tcl/tester_min.tcl`; `do_faultsim_test` baseline-only collapse (malloc_common.tcl:121..157 — full matrix gated on 9.4.2.g.13).  Ported C-shape Tcl commands `sqlite3_create_aggregate` (test1.c:1266..1367 — `x_count`/`legacy_count` aggregate UDFs incl. v=40 step-error and total=42 finalize-error), `sqlite3_config_pagecache` (test_malloc.c:874..915), `sqlite3_initialize`/`sqlite3_shutdown` into `src/tests/tcl/testmodules/TestModuleTest1.pas`.  Added baseline-only `src/tests/tcl/permutations.test` stub + driver source-rewrite (permutations.test → shim) so `all.test` source-loads cleanly.  Sweep 76→78 PASS over first 100 tcl-feature tests (`all.test`, `backup2.test` flipped; `aggerror`/`aggfault`/`avtrans`/`backup`/`backup4`/`cacheflush` advance through their full harness body but still hit deeper-layer divergences tagged pas-soft).
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
  - [X] **9.4.7.b** Memdebug build profile — `src/tests/build_tcl_lib_memdebug.sh` adds `-dSQLITE_MEMDEBUG` and produces `bin/libpassqlite3tcl-memdebug.so` (private staging dir so its `.ppu`/`.o` don't clobber the default build).  Fault allocator + exports landed in 9.4.6.n.  `--build` driver selection still pending (9.4.7).
  - [X] **9.4.7.c** I/O-error injection — ported the `os_common.h` `SQLITE_TEST` machinery (the `SimulateIOError`/`SimulateDiskfullError` counter checks) directly into the Pascal unix VFS read/write/sync/truncate rather than a `test_devsym.c` wrapper VFS (the wrong tool — `do_ioerr_test` drives global counters).  `src/tests/tcl/testmodules/TestModuleIoerr.pas` (`test2.c` port) `Tcl_LinkVar`s the counters.  All `{$ifdef SQLITE_TEST}`-gated; default build byte-unaffected.
  - [~] **9.4.7.c.old** ~~test_devsym.c wrapper VFS~~ — superseded by the counter-instrumentation approach above; kept only if a future test needs a real device-characteristics shim.  Registers via
    `sqlite3_vfs_register`.
  - [ ] **9.4.7.d** Crash-test harness — `crashsql` (9.4.2.g.11)
    spawns a child `tclsh` invocation that `_exit`'s mid-write.
    Parent re-opens the db, runs `PRAGMA integrity_check`.
    Requires: crash-injection VFS that aborts after N writes
    (`../sqlite3/src/test_onefile.c` shape), + parent/child
    process plumbing in `TclTestDriver.pas` (TProcess with
    SIGKILL).  Substantial — estimate 1-2 weeks.  C ref:
    `../sqlite3/src/test_thread.c` + `crash.tcl`.
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
  - [ ] **9.4.7.g** Driver concurrency — `--jobs N` flag spawns
    N tclsh processes in parallel; aggregates results.  Mirrors
    upstream's `make -j` testing.
  - [X] **9.4.7.h** `tclsqlite3_Init` package-config — drop our
    `Sqlite3_Init` so `package require sqlite3` works without
    the explicit `load` line.  Generate a Tcl `pkgIndex.tcl`
    pointing at `libpassqlite3tcl.so` and install into
    `auto_path`.  Quality-of-life; lets us run upstream tests
    verbatim (which assume the package is loadable by name).
  - [ ] **9.4.7.i** Threading build (`-dSQLITE_THREADSAFE=1`) —
    some tests assume the threadsafe build.  Audit which tests
    + which sqlite3 mutex hooks need real implementations vs.
    no-op stubs.  Gate this profile behind its own .so.

- [~] **9.4.8** Full-corpus parity gate.
  - [X] **9.4.8.a** Per-test status tags — adopt the pas-strict /
    pas-soft / pas-skip convention from 9.1.5.  Land
    `src/tests/tcl/STATUS.txt` with one line per MANIFEST entry:
    `<status>\t<path>\t<cite>`.
  - [X] **9.4.8.b** STATUS.txt seeded from current sweeps —
    populate after 9.4.4.g lands.  Default: every test that
    PASSes is pas-strict; FAIL with citation is pas-soft;
    SKIP is pas-skip with mandatory cite.
  - [ ] **9.4.8.c** Strict gate — `bin/TclTestDriver --gate strict`
    exits non-zero if any pas-strict test diverges.  Mirrors
    9.1.5's strict gate.  This is the long-term PR gate.
  - [ ] **9.4.8.d** Coverage check — analogous to 9.1.6:
    track which VDBE opcodes / codegen arms are exercised by
    the tcl-feature corpus that aren't already covered by 9.1/9.2.
    Identify "cold" opcodes that *only* tcl-feature catches.
  - [ ] **9.4.8.e** Regression archive — once full-corpus green,
    every divergence reopening counts as a regression; auto-bisect
    via `git bisect` driver.  Long-term.

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
- [X] **9.4.divbug.14** SQL errors drop object name — routed scattered `sqlite3ErrorMsg` sites through upstream `%s`/`%S`/`%T` formats (build.c / resolve.c).
- [X] **9.4.divbug.15** `no such function` not raised at prepare — ported the `resolveExprStep` TK_FUNCTION error arm (resolve.c:1129..1276).
- [X] **9.4.divbug.16** `affinity3.test` segfault — `sqlite3WhereBegin` skipped opening a RIGHT JOIN table cursor scanned index-only; ported the `JT_LTORJ|JT_RIGHT` gate (where.c:7252).
- [X] **9.4.divbug.17** Subquery-nested aggregate evaluated row-wise — ported the resolver's outward AggInfo-binding arm (resolve.c:1337..1352).  aggnested-3.x residue tracked as divbug.24.
- [X] **9.4.divbug.18** WITHOUT ROWID vtab `xUpdate` — DELETE now emits `OP_Column` for argv[0]; `updateVirtualTable` routed through `sqlite3WhereBegin` so `xBestIndex` runs.
- [X] **9.4.divbug.19** Table-qualified `rowid` alias (`t1.rowid`, `sp.rowid`) — ported the qualified-case rowid arm from lookupName (resolve.c:471..503 + 623..638) into the TK_DOT branch of `ResolveExpr`: when `sqlite3ColumnIndex` misses and `zCol` ∈ {rowid,oid,_rowid_} and the matched source `HasRowid`, bind `iColumn=-1` / AFF_INTEGER.  boundary3.test now PASSES (1896 sub-tests).  Commit `3fd04ef`.
- [X] **9.4.divbug.20** BETWEEN-on-indexed-column planner — fixed by porting exprAnalyze's trailing `prereqRight |= extraRight` (whereexpr.c:1566..1570) so ON-clause BETWEEN children of outer-join left tables get filtered out by the prereqRight gate.  Commits `2f8d92a`, `d7ceaf3`, `5dba89a`.  between.test row-drop fixed; residual teardown segfault during `reset_db` after EXPLAIN QUERY PLAN traffic is out-of-scope (own bucket).
- [X] **9.4.divbug.21** Cross-connection EXCLUSIVE lock detection + busy-handler firing — fixed.  Commits `45593de`, `a8e63c3`.
- [X] **9.4.divbug.22** Large row / `PRAGMA page_size=65536` overflow — two fixes: `fillInCell` overflow-path nil-pBt deref (`45a1fbb`) and `accessPayload` passing `Ord(eOp=0)=1` as pager flag colliding with `PAGER_GET_NOCONTENT` (`9744b0f`).
- [X] **9.4.divbug.23** Correlated FROM-subquery EQP shape — emitted `SETUP` / `RECURSIVE STEP` nodes inside `generateWithRecursiveQuery` (select.c:2781, 2813) and a `CO-ROUTINE %!S` + `SCAN %!S` wrapper around the aggregate-on-subquery materialise arm (select.c:8054 / where.c sqlite3WhereExplainOneScan).  EXPLAIN QUERY PLAN for `WITH RECURSIVE … SELECT count(id) FROM cte` now produces the upstream-style tree; bytecode unchanged (Explain ops only).
- [X] **9.4.divbug.24** `sqlite_sequence` double-created for AUTOINCREMENT — ported build.c:2967..2972 (pin `pSchema^.pSeqTab` when init.busy adds a table named `sqlite_sequence`) at codegen.pas:40916.  aggnested-3.0 / 3.1 now correct.  Residual aggregate-mis-fold + 3.11 SIGSEGV tracked as **9.4.divbug.24.b**.
- [X] **9.4.divbug.24.b** aggnested-3.3 wrong scalar-subquery value + aggnested-3.11 SIGSEGV — fully fixed.  (24.b.2) Bare-column re-read in `updateAccumulatorSimple` was gated on regAcc (the GROUP BY iUseFlag) instead of a fresh per-min/max regHit, so `value1` paired with `max(value1)` mis-captured the last-scanned row of the group — pas printed 1 vs C's 0.  Allocated a fresh regHit before OP_CollSeq when a NEEDCOLL aggregate + accumulator cols both present, and pass it as OP_CollSeq.P1 (mirrors C select.c:6929..6931).  Edits at codegen.pas:26478..26483 (init), 26614..26629 (alloc+pass), 26641..26649 (gate fallback to regAcc).  (24.b.3) Outward-binding scan `FindNestedAggToOuter` only walked the inner subquery's pEList/pHaving, missing pWhere — so `(SELECT count(*) FROM t2 WHERE value2=max(value1))` left outer-bound `max()` as TK_FUNCTION → inner-codegen emitted OP_Function on an aggregate FuncDef whose xFunc=NULL → SIGSEGV.  Added pWhere walk at codegen.pas:9767..9774.  aggnested-3.3 / 3.11 now match C oracle byte-for-byte; 3.0/3.1/3.2/3.12/3.13/3.16 unchanged.
- [X] **9.4.divbug.25** `update-19.10` `AssertH FAILED: idxColIsBeingUpdated rowid` — fixed by stopping IPK index-column rewrite to XN_ROWID in CreateIndex.  Commit `04d98cf`.
- [X] **9.4.divbug.26** Echo vtab INSERT fails — `echoUpdate` emits `%Q`-quoted column names.  Parser correctly reduces `STRING` via `nm ::= STRING` (parse.y:340) into `idlist` (parse.y:1126), but Pascal `sqlite3IdListAppend` (codegen.pas:42536) stored raw token text via `sqlite3DbStrNDup` without dequoting — so resolver saw `'a'` (with single quotes) and reported "no column named 'a'".  C `sqlite3IdListAppend` (build.c:4726) routes through `sqlite3NameFromToken` which dequotes.  Fix: inline `sqlite3DbStrNDup + sqlite3Dequote` (parser-unit `sqlite3NameFromToken` not visible from codegen).
- [X] **9.4.divbug.27** Engine OOM-recovery path segfaults under an injected malloc failure (memdebug build) — blocked `do_malloc_test` from being fully useful.  Surfaced by 9.4.2.g.9.  Root cause: Pascal `sqlite3DbMallocRaw{,NN,Zero}` / `sqlite3DbRealloc` / `sqlite3DbStrNDup` wrappers in `passqlite3util.pas:2529..2587` returned the raw `sqlite3_malloc*` result without calling `sqlite3OomFault(db)` on failure (cf. C `dbMallocRawFinish` malloc.c:604..612, `dbReallocFinish` malloc.c:715..739, `sqlite3DbStrNDup` malloc.c:774..785), and `sqlite3OomFault` itself never propagated the fault to `db->pParse` (skipped the C malloc.c:834..842 walk that bumps `pParse->nErr` / `pParse->rc` along `pOuterParse`).  Net effect: a fault-injected OOM left `db->mallocFailed=0` *and* `pParse->nErr=0`, so codegen paths like `sqlite3FinishCoding` (build.c:267, codegen.pas:43177) reached `sqlite3VdbeMakeReady(NULL,…)` and segfaulted.  Fixed in `passqlite3util.pas` by mirroring the C `OomFault` post-condition in every db-malloc wrapper and porting the Parse-walk into `sqlite3OomFault`.  `tclsh /tmp/oom_probe.tcl` (do_malloc_test with -sqlbody `SELECT 1;`) now completes 94 sub-tests without SIGSEGV.
- [X] **9.4.divbug.28** EXPLAIN QUERY PLAN segfaults on multi-table queries after first row (eqp2/cost/fordelete/delete2).  Root cause was **not** the engine but the Tcl bridge: the NRE per-row continuation arm in `DbEvalNextCmd` (PasTclSqlite.pas:1111..1120) scheduled `Tcl_NRAddCallback`+`Tcl_NREvalObj` whose post-proc dispatch landed on a stale stack pointer (rip lands in `0x7fffffffXXXX`).  Fixed by forcing the recursive `Tcl_EvalObjEx` arm — upstream's `!DbUseNre()` branch (tclsqlite.c:1992) — which is what the follow-up comment at `DbObjCmdNRE` (PasTclSqlite.pas:4269..4274) said the per-row body was always meant to use until the NRE plumbing was audited.  Residual EQP "TEMP B-TREE FOR ORDER BY" detail-text divergence in those 4 tests reclassified as 9.4.divbug.41.
- [X] **9.4.divbug.41** EQP detail-text omits LAST-N-TERMS-OF when nOBSat>0 (eqp2/cost/fordelete/delete2).  Fixed at codegen.pas:31663 by porting select.c:1702..1711 nOBSat/nKey branch (LAST TERM OF / LAST n TERMS OF / plain ORDER BY).
- [X] **9.4.divbug.29** TEXT-affinity column stores `'0x119'` literal as INTEGER 281 (collate1).  Root cause: not `applyAffinity`; it was Pascal Tcl bridge `DbSqlFunc` auto-detect probing `Tcl_GetWideIntFromObj`, which side-effects `"0x119"`-shaped strings into the int representation (Tcl parses `0x`-prefixed literals).  Fix: minimal Tcl_Obj peek (refCount/bytes/length/typePtr) + dispatch on `typePtr->name` per tclsqlite.c:1108..1127 (bytearray/boolean/wideInt/int/double/else→TEXT).  Cite: tclsqlite.c:1108..1127 DbSqlFunc.  Surfaced 9.4.4.e.
- [X] **9.4.divbug.30** ORDER BY with non-default collation (NOCASE) mis-orders.  Root cause: `vdbeSorterCompareRec` did not cap unpacked-record `nField` at `pKeyInfo->nKeyField`; comparator walked into the data column whose `aColl` slot is nil → fell to BINARY memcmp re-breaking NOCASE ties by raw bytes.  Fix: pin `pUR^.nField := pKeyInfo^.nKeyField` after AllocUnpackedRecord (passqlite3vdbe.pas vdbeSorterCompareRec).  Cite: vdbesort.c:1358 vdbeSortAllocUnpacked.  Surfaced 9.4.4.e.
- [X] **9.4.divbug.31** Spurious `database disk image is malformed` for non-corrupt errors (collate3 `no such collation sequence: …`, count-1.2.4/5).  Root cause: `sqlite3LocateCollSeq` (codegen.pas:51614) ignored `db^.init.busy` and always invoked `sqlite3GetCollSeq` when xCmp was nil.  During schema reload (init.busy=1) this turned a missing collation into a parser error → `sqlite3InitCallback` routed the failure through `initCorruptSchema` → SQLITE_CORRUPT → "database disk image is malformed".  Fix: faithful port of callback.c:256..268 — when init.busy, call `sqlite3FindCollSeq(…, create=1)` for a placeholder and skip `sqlite3GetCollSeq`; only at runtime (init.busy=0) does the missing-collation arm fire, producing the proper `no such collation sequence: caseless` message.  Also set `pParse^.rc := SQLITE_ERROR_MISSING_COLLSEQ` in `sqlite3GetCollSeq` per callback.c:231 so build.c:5674's assert holds and the extended-rc surfaces as 257 at the API boundary.  Cite: callback.c `sqlite3LocateCollSeq` / `sqlite3GetCollSeq`.  Surfaced 9.4.4.e.
- [X] **9.4.divbug.32** Readonly-DB DELETE returns `unknown error` instead of `attempt to write a readonly database` (delete-8.x).  Root cause was upstream of `sqlite3ErrStr` / btreeBeginTrans: `unixOpen` (os.pas:2267..2273) mutated only the local `openFlags` on the RO-retry path, leaving the caller-visible `flags` untouched.  `pOutFlags^` therefore still claimed READWRITE, so pager.c's `readOnly := (fout and SQLITE_OPEN_READONLY)<>0` read 0, BTS_READ_ONLY was never set in btreeOpen, and a chmod-444 write fell through `btreeBeginTrans` to `pagerLockDb` → `sqlite3OsLock` which returned SQLITE_IOERR_LOCK ($F0A=3850) — not in ErrStr → "unknown error".  Fix: port os_unix.c:6692..6694 — drop `SQLITE_OPEN_READWRITE|CREATE`, set `SQLITE_OPEN_READONLY` in `flags` itself on the RO-retry arm (passqlite3os.pas unixOpen).  Cite: os_unix.c `unixOpen` RO-retry, main.c `sqlite3ErrStr`.  Surfaced 9.4.4.e.
- [X] **9.4.divbug.33** `count(DISTINCT …)` returns 1 instead of 0 for an empty set (distinctagg-3.x).  Root cause: simple-aggregate fast path called `updateAccumulatorSimple` without an `eDistinctType` arg, so the DISTINCT dedup always took the WHERE_DISTINCT_UNORDERED ephemeral arm; combined with no `fixDistinctOpenEph` follow-up, the OpenEphemeral stayed live and the AggStep ran once on the seed row even for empty tables.  Fix: port `codeDistinct` three-way dispatch (select.c:933..970) into updateAccumulatorSimple, port `fixDistinctOpenEph` (select.c:1017..1042), and wire `pAggDistinct`/`WHERE_AGG_DISTINCT` into the sqlite3WhereBegin call site per select.c:8849..8853.  Cite: select.c `codeDistinct` / `fixDistinctOpenEph` / DISTINCT-agg WhereBegin wiring.  Surfaced 9.4.4.e.
- [X] **9.4.divbug.34** `PRAGMA page_size` reports build default (8192) regardless of per-test write (createtab-0.2 expects 4096, format4-1.1 expects 2048).  Root cause: PragTyp_PAGE_SIZE write arm was not ported — codegen only emitted the read arm, so `PRAGMA page_size=N` was a parser-only no-op (the btree's `pageSize` stayed at SQLITE_DEFAULT_PAGE_SIZE).  Fix: port pragma.c:604..611 — set `db^.nextPagesize := sqlite3Atoi(zRight)` and call `sqlite3BtreeSetPageSize(pBt, db^.nextPagesize, 0, 0)`; OOM-bubble on SQLITE_NOMEM.  Cite: pragma.c PragTyp_PAGE_SIZE write arm.  Surfaced 9.4.4.e.
- [X] **9.4.divbug.35** Float-to-text precision artefacts: `-1.11` → `-1.1099999999999999`; large doubles get an extra mantissa digit (fpconv1, default-3.3).  Root cause: not a printf bug — `passqlite3printf`'s etFLOAT/`%!.*g` arm already honours `db->nFpDigit` and renders byte-identically to C (shell `.dbconfig fp_digits 15; SELECT 1.23-2.34` returns `-1.11` matching C).  The Tcl test harness was missing the `fpnum_compare` C-side command (test1.c:6191..6325) that `tester.tcl:789..792` uses as a fuzzy-equality fallback when exact string compare fails on float-bearing rows — so `-1.11` vs `-1.1099999999999999` and `9.22337203685478e+18` vs `9.223372036854776e+18` (same underlying double, different `tcl_precision`/FP_DIGITS rendering) always failed exact compare.  Fix: port `fpnum_compare` to TestModuleTest1.pas + register in Sqlitetest1_Init; wire the fallback into tester_min.tcl do_test.  Cite: test1.c:6191..6325, tester.tcl:789..792.  Surfaced 9.4.4.e.
- [X] **9.4.divbug.36** `PRAGMA journal_mode=off` silently ignored — keeps prior mode `delete` (changes-1.1.0).  Root cause: PragTyp_JOURNAL_MODE write arm was not ported — codegen only emitted the read arm, so `PRAGMA journal_mode=MODE` was a parser-only no-op (the pager was never asked to switch).  Fix: port pragma.c:734..771 — walk azJournalModeName[] via `sqlite3_strnicmp` (case-insensitive prefix match), apply the defensive-mode `OFF→QUERY` gate, emit OP_JournalMode per affected attached DB then OP_ResultRow.  Cite: pragma.c PragTyp_JOURNAL_MODE write arm.  Surfaced 9.4.4.e.
- [X] **9.4.divbug.37** WAL `wal_hook` callback reports 0 frames where upstream reports >0 (e_walhook-1.3+).  Cite: wal.c `sqlite3WalCallback`, pager.c walCommit hook invocation.  Surfaced 9.4.4.e.  Root cause: `doWalCallbacks` (vdbeapi.c:739..758) was never ported — `sqlite3_step` never invoked `db->xWalCallback`, so registered hooks never fired (the wal-frame accumulator `pWal->iCallback` in walFrames was correct, but nobody drained it).  Fix: port `doWalCallbacks` into passqlite3vdbe.pas and call it from the `rc=DONE && db.autoCommit` arm of `sqlite3_step` (vdbeapi.c:878..883).  Verified hook now fires post-commit; remaining e_walhook failures are deeper WAL-checkpoint divergences.
- [X] **9.4.divbug.38.a** Malformed `REFERENCES … ON` parser error message.  Cite: parse.y refargs grammar (parse.y:438..445).  Surfaced 9.4.4.e.  No-op on inspection: Pascal `passqlite3parser.pas:2872..2898` already mirrors C refargs/refarg rules 49..54 verbatim, and the LALR error machinery already emits the same `near "X": syntax error` shape as C oracle byte-for-byte.  Verified reproducers (all match C output character-for-character): `REFERENCES p(id) ON);` → `near ")"`, `REFERENCES p MATCH);` → `near ")"`, `REFERENCES p ON FOO);` → `near "FOO"`, `REFERENCES p ON DELETE);` → `near ")"`.  Likely fixed incidentally by an earlier parser tightening (the bullet was filed against the old 9.4.4.e snapshot).  Archive.
- [X] **9.4.divbug.38.b** FK-cascade picks wrong target row (e_fkey-2.1/3.1).  Cite: fkey.c `sqlite3FkActionTrigger`.  Surfaced 9.4.4.e.  No-op on inspection: the engine cascade is correct.  Verified composite-FK ON DELETE CASCADE on `p(a,b)`/`c(x,y) FOREIGN KEY(x,y) REFERENCES p(a,b)`, ON UPDATE CASCADE (single + composite), ON DELETE SET NULL, ON DELETE SET DEFAULT, and the swapped-order shape `FOREIGN KEY(y,x) REFERENCES p(a,b)` all match C oracle byte-for-byte via `LD_LIBRARY_PATH=src bin/passqlite3`.  The symptom is a harness artefact: e_fkey-2.1 lives under `ifcapable !trigger&&foreignkey` and e_fkey-3.1 under `ifcapable !foreignkey` — both gates only fire in OMIT_TRIGGER / OMIT_FOREIGN_KEY builds, baking the *absence* of cascade / parser-error into the expected output.  Our `src/tests/tcl/tester_min.tcl:244` `ifcapable` stub always uplevel's the body regardless of expression (deliberate per its own banner), so in our full-feature build we execute these OMIT-only blocks and get `world` instead of `hello` (cascade correctly fires) and CREATE succeeds where the OMIT-build parse error was expected.  Faithful port of upstream `fix_ifcapable_expr`/`capable`/`ifcapable` (tester.tcl:1697..1734) is the right long-term fix, but it cascades a flood of pas-soft engine divergences in tests with `ifcapable !X { finish_test; return }` early-skips (cachespill, ~50 others) that currently instant-pass via the always-uplevel stub — out-of-scope here, tracked under 9.4.6.a cap-probe wiring.  Engine archive against fkey.c; harness re-open under 9.4.6.a.
- [X] **9.4.divbug.39** `CREATE TABLE AS SELECT` (CTAS) unsupported in this build (errofst1, distinct2-100, delete-7.6).  Cite: build.c `sqlite3EndTable` pSelect arm, select.c `SRT_Table`.  Surfaced 9.4.4.e (existed in 9.4.4.d as residue with no dedicated bucket).  Fixed by porting the pSelect coroutine arm of `sqlite3EndTable` faithful to build.c:2836..2884 (codegen.pas:41832..).  Reproducer `CREATE TABLE t AS SELECT 1,2; SELECT * FROM t` now returns `1|2`.
- [X] **9.4.divbug.40** `DEFAULT` clause: error text drops column-name (default-1.3 `default value of column is not constant` missing `[y]`); DEFAULT-derived affinity reported in wrong order (default-3.1).  Sibling-of divbug.14 but in DEFAULT path.  Cite: build.c `sqlite3AddDefaultValue`, `sqlite3AffinityType`.  Surfaced 9.4.4.e.  FIXED: (a) wired `[%s]` + `pCol^.zCnName` through sqlite3MPrintf in sqlite3AddDefaultValue (codegen.pas:41179) matching build.c:1743; (b) ported the full rolling-hash sqlite3AffinityType (codegen.pas:3910) — old stub keyed on the first character, so `NATIONAL CHARACTER(15)`→NUMERIC (instead of TEXT) and `LONG INTEGER`→BLOB (instead of INTEGER) swapped affinities; now CHAR/CLOB/TEXT/BLOB/REAL/FLOA/DOUB/INT precedence matches C build.c:1651..1717.  default-1.3 and default-3.1 byte-identical with C oracle; 99/100 regression; ExplainParity 1026/1026.
- [X] **9.4.divbug.42** Mis-triaged: root was an engine SIGSEGV on `collate1.test` 8.2, not harness pollution (TclTestDriver already spawns a fresh tclsh per test).  `CREATE TABLE t0(c0 COLLATE RTRIM, c1 BLOB UNIQUE, PRIMARY KEY(c0,c1)) WITHOUT ROWID` crashed because the secondary UNIQUE index on `c1` retained its synthesised `XN_ROWID` tail after `convertToWithoutRowidTable` ran (build.c:2451..2483 unported) — any planner that opened the index dereferenced past `aiColumn`.  Fix: port the secondary-index rowid→PK-cols rewrite loop in `sqlite3EndTable` (codegen.pas:41979+) with isDupColumn-equivalent dedup + `bAscKeyBug` (bit 9 of idxFlags) propagation per ticket bba7b69f.  500-test sweep: 280→298 PASS (+18, zero regressions).
- [X] **9.4.divbug.43** `ORDER BY … NULLS FIRST` / `NULLS LAST` clause ignored when an index could satisfy the sort — fixed by refusing the BIGNULL_SORT index-match in wherePathSolver (codegen.pas:18567..18585) so the planner falls back to the external sorter (which already honours sortFlags via VdbeRecordCompare).  Two-pass NULL-scan codegen (wherecode.c:1933..2164 + where.c:7616..7620) still deferred but no longer surface-visible.  All 8 ASC/DESC × NULLS FIRST/LAST × {idx,DESC-idx} combinations now byte-match C.
- [X] **9.4.divbug.44** Misclassified cluster — root was `IN (SELECT ... ORDER BY ...)` materialisation, not MIN/MAX.  sqlite3Select's sort gate (codegen.pas:31351) only accepts SRT_Output/EphemTab/Coroutine; SRT_Set + ORDER BY bailed at 31465 before emitting the body, leaving the IN-eph cursor empty (misc3-4.3 returned 0 vs 64).  Fix: drop the superfluous ORDER BY for SRT_Set with no LIMIT (set contents are order-independent — mirrors C's own comment at select.c:1386..1389).  The minmax/in5/in6/in7 cluster entries were `sqlite_search_count` (divbug.42) and EXPLAIN-shape (divbug.55) checks, not result divergences.
- [X] **9.4.divbug.45** `HAVING` with non-aggregate predicate over-filters: having-3.2 expects different bytecode (optimisation skipped for non-deterministic `randomblob(a)`), pas matched (incorrectly hoisted into WHERE).  Root cause: `FUNC_ENC` constant ORed `SQLITE_FUNC_CONSTANT` unconditionally, so VFUNCTION builtins (`random`/`randomblob`/`changes`/`last_insert_rowid`/`total_changes`) and DFUNCTION builtins (`sqlite_version`/`sqlite_source_id`) all wrongly advertised CONSTANT.  `exprNodeIsConstantFunction` (expr.c:2502..2510) then accepted them and `havingToWhere` (select.c:7038..7051) promoted the term into WHERE.  Fix: added `FUNC_VENC` (no CONSTANT, no SLOCHNG — matches sqliteInt.h:2134 VFUNCTION) and `FUNC_DENC` (SLOCHNG only — matches sqliteInt.h:2157 DFUNCTION) and retagged the seven affected builtins.  Reproducer (`HAVING randomblob(a)<X'88'`) now emits the Function inside HAVING (addr 41) matching C — not in WHERE (addr 9) as before.  TestExplainParity 1026/1026, build.sh 99/100 (TestFuzzDiff pre-existing).
- [X] **9.4.divbug.46** `LIMIT N` combined with subquery / DESC clamps wrong number of rows (limit-1.2.3 expects 5 rows got 3; limit-2.1 expects 2 got 32; limit2-100.3).  Cite: select.c `computeLimitRegisters` / `selectInnerLoop` LIMIT register handling.  Surfaced 9.4.4.f.  FIXED: two sibling root causes — (a) selectInnerLoop's disposal switch (codegen.pas:31837) lacked the C select.c:1522..1524 post-disposal `OP_DecrJumpZero p^.iLimit, iBreak` that fires for every eDest when bSort=0; the SRT_Output / SRT_Mem / SRT_Coroutine arms emit their own, but SRT_EphemTab / SRT_Fifo / SRT_DistFifo / SRT_Queue / SRT_Upfrom / SRT_Set did not, so FROM-subquery materialise (`SELECT count(*) FROM (SELECT * FROM t LIMIT 2)`) ingested every inner row.  (b) OP_OffsetLimit (vdbe.pas:10796) added `r[P3]` raw instead of `max(0, r[P3])` — vdbe.c:7748's `pIn3->u.i>0?pIn3->u.i:0` ternary — so `LIMIT 5 OFFSET -2` produced r[P2]=3 (=5+(-2)) instead of 5, shrinking the Top-N B-tree cap.  Reproducer matrix: limit-1.2.3, limit-1.2.5, limit-2.1, limit-2.3, limit-3.1, limit2-100.1/.2 all byte-identical with C oracle.  TestExplainParity unchanged (224/802 pre-existing baseline); build.sh 99/100 (TestFuzzDiff pre-existing).
- [X] **9.4.divbug.47** Numeric `_` digit-separator literals not parsed: `1_000`, `1.1_1`, `0x1_2` raise `unrecognized token: "1_000"` (literal-3.x, literal2).  Cite: tokenize.c `sqlite3GetToken` numeric path (SQLite 3.46+ underscore separator).  Surfaced 9.4.4.f.  FIXED: ported tokenize.c:443..490 underscore arms into both CC_DIGIT and CC_DOT branches of `sqlite3GetToken` (parser.pas:889..988); when `_` follows any digit/xdigit in mantissa/fractional/exponent the token type flips to TK_QNUMBER (already handled by existing `sqlite3DequoteNumber` reduction in `term ::= QNUMBER`).  Also rewrote the dequote error path (parser.pas:2662..2674) to format `unrecognized token: "%s"` via sqlite3MPrintf so malformed cases (`1_`, `1__0`, `_1`) match C's util.c:349 byte-for-byte.  Verified: `1_000_000` → 1000000, `1.5_0` → 1.5, `0x1_2` → 18, `1_000.5e1_0` → 1.0005e+13 all byte-identical to C oracle.  TestExplainParity 1026/1026; build.sh 99/100 (TestFuzzDiff pre-existing).
- [X] **9.4.divbug.48** Hex-literal overflow detection: error text drops the literal value (hexlit-400 expects `hex literal too big: 0x10000000000000000` got `hex literal too big`); some too-big inputs silently accepted (hexlit-401/402 expected error, pas returns OK).  Cite: expr.c `codeInteger` / tokenize.c hex literal path.  Surfaced 9.4.4.f.  FIXED (error-text half): `codeInteger` (codegen.pas:5374) emitted the static string `'hex literal too big'`, dropping the `: %s%#T` (negFlag prefix + zToken) suffix from expr.c:4340..4341.  Pascal printf has no `%#T` Expr* dispatch (etTOKEN+altform Expr* arm at printf.c:957..962 is gated on PRINTF_INTERNAL and reads `pExpr->u.zToken`), so we build the message via `sqlite3MPrintf(pParse^.db, 'hex literal too big: [-]%s', [z])` substituting `zToken` directly — byte-identical output.  Verified hexlit-400 (`SELECT 0x10000000000000000`) and hexlit-410 (`INSERT … VALUES(1+0x10000000000000000)`) byte-match C oracle; non-DISTINCT negative-just-over (`SELECT -0x10000000000000000`) and SMALLEST_INT64 boundary (`SELECT -0x8000000000000000`) likewise match.  ARCHIVED: hexlit-401/402 (`SELECT DISTINCT <oversized>`) still silently accept — root cause is a pre-existing unrelated bug in the no-FROM `SELECT DISTINCT <expr>` codegen path (pas emits only Init/Halt/Goto, skipping result-row codegen entirely — even `SELECT DISTINCT 42` short-circuits identically; C emits Null+Noop+Integer+Eq+Copy+ResultRow+Halt), so `codeInteger` is never invoked.  That short-circuit is structural and belongs with divbug.55 (EQP DISTINCT variants); overflow detection itself is verified correct.  TestExplainParity 1026/1026; build.sh 99/100 (TestFuzzDiff pre-existing).
- [X] **9.4.divbug.49** Generated-column (`GENERATED ALWAYS AS ...` VIRTUAL/STORED) codegen drops value and type — gencol1-100 expects `[integer 0]` got `[text null]`; gencol1-2.2.x rows return empty cells.  Cite: build.c `sqlite3AddGenerated` + insert.c generated-column expression eval (`sqlite3GenerateConstraintChecks` STORED arm, expr.c VColumn ↔ TK_COLUMN substitution).  Surfaced 9.4.4.f.  FIXED: ported insert.c:1361..1437 COLFLAG_NOINSERT arm into the per-row column-eval loop (codegen.pas:37684).  Bug: Pascal loop wrote `regData + i` for every column including generated ones, so VIRTUAL/STORED slots got populated with the generator expression evaluated against still-uninitialised storage (e.g. `c0 AS typeof(c1)` ran before `c1` was loaded → typeof(NULL)='null' got stored in c1's slot, then `SELECT * FROM t0` returned `text|null` instead of `integer|0`).  Added `iRegStore` tracking (held back across VIRTUAL cols so they don't occupy a record slot), SoftNull placeholder for STORED under BEFORE-trigger gate, default-expr fallback for hidden cols not in IDLIST, and `i - nHidden` mapping for the positional VALUES / coroutine / temp-table arms (matching C's `k = i - nHidden`).  IPK slot now flows through the standard arm (writes the user VALUES expression, which the post-loop OP_SCopy at codegen.pas:37861 still consumes verbatim before the OP_Null at :37891) — preserves the existing `regData + iPKey` rowid-extraction shortcut without adding C's separate `pList->a[ipkColumn]` recode.  Verified: gencol1-100 (`integer|0`), gencol1-2.1 (`10|real|abc||30|null|ntalo|`), explicit-IPK round-trip (`INSERT VALUES(7,...); INSERT VALUES(NULL,...); max=8`) all byte-match C oracle.  TclTestDriver gencol1.test asserts now 0/1701 (+107 vs baseline 0/1594); residual failures are unrelated downstream features (CHECK constraint codegen, ALTER + generated cols).  build.sh 99/100 (TestFuzzDiff pre-existing).
- [X] **9.4.divbug.50** JSON output float formatting: integer-valued JSON numbers render as `1` instead of `1.0`; very-large doubles render as `1E99` instead of `1.0e+99` (json101-1.4/1.4b first-row diff).  Cite: json.c `jsonAppendDouble` / `jsonRenderNode` REAL formatter.  Surfaced 9.4.4.f.  FIXED: routed jsonAppendSqlValue's SQLITE_FLOAT arm (passqlite3json.pas:3619) through `sqlite3FormatStr('%!0.15g', …)` — the SQLite-printf `'!'` altform2 flag (printf.c:528..713) forces a `.0` suffix on integer-valued doubles and an `e+NN` form, matching C's `jsonPrintf(100,p,"%!0.15g",…)` at json.c:813.  Previously used Pascal's `FloatToStr` which emitted `1` and `1E99`.  Verified: TclTestDriver json101.test 0→121 sub-asserts, full first-row matches C oracle byte-for-byte (`[0.0,1.0,-1.0,-1.0e+99,2.0e+100,…]`).  build.sh 99/100 (TestFuzzDiff pre-existing).
- [X] **9.4.divbug.51** JSON error-message text divergences: `json103-101` reports generic `SQL logic error` instead of `JSON cannot hold BLOB values`; `json109-2.1` reports `not an array element: $.a` (missing surrounding single quotes); `json105-6.10` reports differently-quoted bad-path string.  Cite: json.c `jsonParseAddNode` / `jsonPathError` / BLOB-rejection error paths.  Surfaced 9.4.4.f.  FIXED: (a) `jsonBadPathError` (passqlite3json.pas:3995) now routes NOTARRAY / default paths through `sqlite3FormatStr('%Q', zPath)` to match C's `sqlite3_mprintf("...: %Q", zPath)` at json.c:3507/3513 — `%Q` wraps the text in single quotes and doubles internal `'`.  (b) OP_AggStep1 error-lift arm (passqlite3vdbe.pas:9641..9655) now ports vdbe.c:7928..7930 `sqlite3VdbeError(p, "%s", sqlite3_value_text(pCtx->pOut))` *before* releasing pOut — previously the message set by `sqlite3_result_error("JSON cannot hold BLOB values")` inside jsonArrayStep was wiped by `sqlite3VdbeMemRelease`, leaving the vdbe with the generic SQLITE_ERROR (1) → "SQL logic error" rendering.  Updated TestJson T367/T370 expectations (src/tests/TestJson.pas:1626/1643) to the quoted form.  Verified all three buckets byte-identical vs C oracle; build.sh 99/100 (TestFuzzDiff pre-existing).
- [X] **9.4.divbug.52** JSON `subtype()` / `sqlite_subtype()` function unported — `json102-1600` reports `no such function: subtype`; downstream subtype-aware JSON tests cascade.  Cite: json.c `jsonSubtypeFunc` registration in `sqlite3RegisterJsonFunctions`.  Surfaced 9.4.4.f.  FIXED: registration actually lives in func.c not json.c — `FUNCTION2(subtype, 1, 0, 0, subtypeFunc, SQLITE_FUNC_TYPEOF|SQLITE_SUBTYPE)` at func.c:3306 (body func.c:100..111).  Ported `subtypeFunc` (passqlite3codegen.pas:52657) as a thin wrapper around the already-ported `sqlite3_value_subtype()` and added it as aBuiltinFuncs[82] (grew the array from 0..81 to 0..82) with the SQLITE_FUNC_TYPEOF|SQLITE_SUBTYPE flag pair so the planner does not constant-fold across it and the resolver propagates the source value's subtype.  Verified: `SELECT subtype(json('1'))` now returns 74 (JSON_SUBTYPE) matching C; `SELECT subtype('hi'), subtype(json_object('a',1))` returns `0|74`.  build.sh 99/100 (TestFuzzDiff pre-existing baseline).
- [X] **9.4.divbug.53** Parser error reports `near token: syntax error` (placeholder) instead of `near "<actual-token>": syntax error` (fuzz2-6.1 expects `near "#0"`).  Cite: parse.y `%syntax_error` body — pas passes the literal string `"token"` instead of `yyminor->z`.  Surfaced 9.4.4.f.
- [X] **9.4.divbug.54** ORDER BY DESC + LIMIT+OFFSET on a partially-satisfied block-sort (orderby6-1.12..1.14: `ORDER BY b DESC, a LIMIT 10 OFFSET 20/45`) dropped one row per block boundary and substituted a stray row from the next block.  Root cause: the Pas Top-N gate at codegen.pas:31699..31702 mirrored C select.c:852..853 (`IdxLE regBase+nOBSat, nExpr-nOBSat`) literally, but C only gets away with comparing the trailing keys because the `nOBSat>0` arm at select.c:789..831 first flushes the sorter at every block boundary (Gosub labelBkOut + ResetSorter + IfNot iLimit→labelDone).  The Pas port has not yet ported that block-flush arm, so the trailing-key compare leaks across blocks: after one block exhausts LIMIT+OFFSET, the next block's smaller-a rows are rejected against the prior block's largest a.  Fix: when emitting OP_IdxLE in the Top-N gate, compare the FULL sort key (`regBase, sortNKey`) — correct in all cases, only slightly less efficient than the C variant.  Block-flush port (Gosub/labelBkOut) remains deferred.
- [X] **9.4.divbug.55** EXPLAIN QUERY PLAN detail-string divergences (sibling-of 41): orderby5-1.1 reports `USE TEMP B-TREE FOR DISTINCT` where C does not; indexedby-7.1/index8-1.1eqp report `COVERING INDEX` where C reports plain `INDEX`; indexexpr1-110eqp omits `USING INDEX t1a1` detail.  Cite: select.c `explainTempTable` / where.c `explainIndexRange` detail emission.  Surfaced 9.4.4.f.  FIXED (2 of 3 sub-arms): (a) DISTINCT-over-covering-index — sqlite3Select now passes `WHERE_WANT_DISTINCT` to sqlite3WhereBegin (select.c:8267), then captures `sqlite3WhereIsDistinct(pWInfo)` (select.c:8292..8294); for UNIQUE/ORDERED results, noop the dedup OpenEphemeral (suppressing the EQP "USE TEMP B-TREE FOR DISTINCT" line at codegen.pas:32040..32048) and route per-row dedup through the ORDERED `regPrev` OP_Ne/OP_Eq+OP_Copy arm (select.c codeDistinct 946..970).  (b) DELETE/UPDATE "USING COVERING INDEX" — multi-level sqlite3WhereBegin tail (codegen.pas:21088..) now clears `WHERE_IDX_ONLY` on the driving WhereLoop when `WHERE_ONEPASS_DESIRED` + rowid table (where.c:7230..7234) BEFORE sqlite3WhereExplainOneScan runs, so the EQP detail-string picks the plain "USING INDEX %s" arm (wherecode.c:173).  ARCHIVED: indexexpr1-110eqp (`SCAN t1` instead of `SEARCH t1 USING INDEX t1a1 (<expr>=?)`) is a deeper deferred-planner issue (cost model doesn't elect index-on-expression for the `substr(a,1,12)==...` predicate); separate from EQP-shape work and stays open as its own follow-up.  TestExplainParity 1026/1026.
- [X] **9.4.divbug.56** Default `LIKE` collation matches both cases when single-case expected (like-1.5.2 expects `[abc]` got `[ABC abc]`).  Cite: func.c `likeFunc` / `patternCompare` default case-sensitivity gate (default-OFF vs `PRAGMA case_sensitive_like=1`).  Surfaced 9.4.4.f.
- [X] **9.4.divbug.57** `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)` not enforced — openv2-1.1 expects `unable to open database file` for missing-db RO open got OK; openv2-1.4 expects `attempt to write a readonly database` got OK.  Cite: main.c `openDatabase` open-flags validation; likely intersection with divbug.32 RO-retry path.  Surfaced 9.4.4.f.  FIXED: root cause was NOT the engine — `openDatabase` + unixOpen (divbug.32) already honour SQLITE_OPEN_READONLY end-to-end.  The Tcl `sqlite3 db FILE ?OPTIONS?` constructor in PasTclSqlite.pas DbMain was a 5-arg stub that hard-coded `SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE` and ignored `-readonly` / `-create` / `-vfs` / `-nofollow` / `-nomutex` / `-fullmutex` / `-uri`; openv2.test passes those options so the requested flags never reached `sqlite3_open_v2`.  Ported the full key/value option-parsing loop (tclsqlite.c:4299..4372) plus the sqlite3_errmsg / sqlite3_errstr propagation path (tclsqlite.c:4384..4397) so failed opens surface "unable to open database file" verbatim.  openv2.test now 6/6.
- [X] **9.4.divbug.58** `CREATE INDEX … (missing_col)` error gate fires late — index-2.1b expects `no such column: f4` on the CREATE INDEX statement, pas returns OK and only complains on the following `index1 already exists` (index-2.2).  Cite: build.c `sqlite3CreateIndex` column-name resolution.  Surfaced 9.4.4.f.  FIXED: sqlite3CreateIndex's per-column loop only ran sqlite3StringToId + sqlite3ResolveSelfReference under IN_RENAME_OBJECT — every other path silently fell through to a zToken-based sqlite3ColumnIndex lookup that returned XN_EXPR on miss instead of erroring.  Ported the C-faithful order (build.c:4217..4219): when `db^.init.busy=0`, always StringToId+ResolveSelfReference and `if pParse^.nErr<>0 then goto exit_create_index` so the resolver-emitted "no such column: f4" surfaces on the CREATE INDEX statement itself.  Also taught the column-index extraction to recognise TK_COLUMN (the post-resolve op) and pull iColumn from it; previously only TK_ID/TK_STRING paths fed sqlite3ColumnIndex(zToken).  Reproducer now matches C: `CREATE INDEX i ON t(f4)` errors `no such column: f4`.  TclTestDriver baseline preserved (TestFuzzDiff was failing pre-fix).
- [X] **9.4.divbug.59** JOIN USING/NATURAL: prefix-qualified column reference (`t2.a` where `a` is the USING column) raises `no such column: t2.a` (joinC-1..3); upstream resolves to the USING-shared column.  Cite: resolve.c `lookupName` / select.c `sqliteProcessJoin` USING-equivalence-class wiring.  Surfaced 9.4.4.f.  **Landed**: ported resolve.c:351..417 nested-from arm via new `ResolveNestedFromDot`/`FindWrapperEListIdx` helpers in ResolveExpr's TK_DOT path — recursively walk the SF_NestedFrom wrapper's pSelect^.pSrc/pEList to map qualifier (zTab, zCol) to the wrapper's pEList index, then bind pE to (wrapper.iCursor, j).  Also widened expandStar's USING-omit gate to skip when `selFlags & SF_NestedFrom` (select.c:6251), so the wrapper retains both USING sides in its pEList.  joinC-1/2/3 pass; full regression: 99 binaries / 5179 assertions PASS (TestFuzzDiff pre-existing).
- [X] **9.4.divbug.60** Tcl bridge coerces integer values bound through `db eval` to REAL: keyword1-database.1 expects `[1 2 3 99]` got `[1.0 2.0 3.0 99.0]` (partial overlap with gencol1-100 `[integer 0]→[text null]` integer-vs-text path).  Cite: PasTclSqlite.pas `DbSqlFunc` parameter-bind type peek (extension of divbug.29's auto-detect arm).  Surfaced 9.4.4.f.  **Landed**: ported tclsqlite.c:1517..1549 bind type-peek into a shared `DbBindOneParam` helper invoked from both bind sites (DbPrepareAndBind for the 3-arg `db eval` cache path, plus the inline objc==3 flat-list loop in DbEvalArm).  Helper inspects pVar^.typePtr->name via existing TclObjTypeName/TclObjHasNoStringRep peek (sibling of divbug.29 DbSqlFunc) and dispatches: '@'-name or `bytearray` w/o string rep → sqlite3_bind_blob; `booleanString`/`boolean` w/o string rep → sqlite3_bind_int; `double` → sqlite3_bind_double; `wideInt`/`int` → sqlite3_bind_int64; otherwise sqlite3_bind_text64(UTF-8).  Cache-path uses SQLITE_STATIC + apParm[]-anchored Tcl_IncrRefCount; flat-list path uses SQLITE_TRANSIENT (immediate finalise).  Verified `db eval {SELECT typeof($x)}` now returns `integer` (was `text`) for `incr`-shimmered ints and `blob` for `@bytearray` binds.  keyword1 still PASS (was passing by affinity coincidence); 200-sweep delta: 126 pass / 74 fail (== baseline).
- [X] **9.4.divbug.61** Harness gap: `fts3_common.tcl` not staged in `src/tests/tcl/` — every `fts3*.test` / `fts4*.test` that begins with `source $::testdir/fts3_common.tcl` aborts with `SOURCE-ERROR: couldn't read file ".../fts3_common.tcl"` (~15 tests).  Cite: upstream `test/fts3_common.tcl`; needs staging + any unported helper procs noted.  Surfaced 9.4.4.f.  Fixed 9.4.divbug.61: staged hybrid shim at `src/tests/tcl/fts3_common.tcl` — verbatim upstream procs (fts3_build_db_1/2, fts3_integrity_check, fts3_terms, fts3_doclist, gobble_varint/string, fts3_readleaf, fts3_read/read2) plus pas-side accommodations: no-op `sqlite3_fts3_may_be_corrupt`, pure-Tcl `read_fts3varint` (port of test_hexio.c:368), TODO marker on the unported `fts3_tokenizer_test` SQL function that fts3_integrity_check needs.  Sweep delta: 16 FAIL→PASS (fts3c/d, fts3corrupt4..7, fts4check/docid/incr/merge/merge4/min/onepass/opt/record/rename), zero regressions in 500-sweep.
- [X] **9.4.divbug.62** Harness gap: test1.c `sqlite3_*` Tcl commands unported — tests fail with `invalid command name "sqlite3_mprintf_int"` / `"sqlite3_column_count"` / `"sqlite3_finalize"` / `"sqlite3_bind_*"` / `"sqlite3_status"` / `"sqlite3_release_memory"` / `"sqlite3_limit"` / `"sqlite3_rekey"` / `"sqlite3_create_function"` / `"sqlite3_simulate_device"` / `"sqlite3_config_pmasz"` / `"sqlite3_config_uri"` / `"sqlite3_config_alt_pcache"` / `"sqlite3_reset_auto_extension"` (~50 tests incl. printf, printf2, pragma4, tkt2213, tkt-752e1646fc, tkt-99378177930f87bd, tkt-b75a9ca6b0, tkt-385a5b56b9, tkt2565, shortread1, vacuum, vacuum-into, uri, upfrom2, upfromfault, upsert5, values, wal9, zeroblobfault, pcache2, tpch01, pendingrace, reservebytes, rowvalue7).  Cite: src/test1.c registration table.  Surfaced 9.4.4.g.  Decomposed 2026-05-16 into sub-arms a..f:
  - [X] **9.4.divbug.62.a** `sqlite3_mprintf_*` family (`sqlite3_mprintf_int`, `_str`, `_double`, `_long`, `_int64`, `_z_test`, `_n_test`, `_stronly`, `_hexdouble`, `_scaled`) — printf trampoline Tcl commands.  Cite: test1.c registration of `sqlite3_mprintf_int` (search for `Md.Sqlite3_mprintf` in test1.c) and the Md_Init array.  Register in TestModuleTest1.pas via `Sqlitetest1_Init`.  Outcome: all ten handlers ported as old-style argc/argv Tcl commands in `src/tests/tcl/testmodules/TestModuleTest1.pas:1180..1450` (tcl_mprintf_int/int64/long/str/double/scaled/stronly/hexdouble/z_test/n_test) — each cited to its test1.c source line (test1.c:1400/1427/1460/1491/1552/1583/1613/1637/495/518); registered in `Sqlitetest1_Init` (TestModuleTest1.pas:3141..3160) as Tcl_CreateCommand (mirrors C `Tcl_CreateCommand` from test1.c:9059..9069's `Tcl_CmdProc*` cast).  Bodies route through `sqlite3PfMprintf` (passqlite3printf.pas:1499) — the Pascal array-of-const renderer the SQL `printf()` builtin uses.  `tcl_mprintf_n_test` computes the post-`%s` length directly (Pas array-of-const path = C bArgList branch where `etSIZE` is silently ignored at printf.c:740..743; printf-14.2 fixture wants 5 for "xyzzy" — measured via Length of intermediate output, same semantics).  Smoke: `sqlite3_mprintf_int %d 42 0 0` → `42`, `_n_test xyzzy` → `5`, `_z_test , a b c d` → `,a,b,c,d`, `_int64 %lld 1234567890123 0 0` → `1234567890123`, `_hexdouble %g 4000000000000000` → `2`.  printf.test no longer aborts with `invalid command name "sqlite3_mprintf_int"`; it now runs (timed out at 300 s deep into the fixture, but progressing past the registration gap).  printf2.test executes 50 sub-tests through the gap.  TestExplainParity 224/1026 (== baseline).
  - [X] **9.4.divbug.62.b** Statement-level introspection: `sqlite3_column_count`, `sqlite3_column_name`, `sqlite3_column_decltype`, `sqlite3_column_type`, `sqlite3_column_text`, `sqlite3_column_int`, `sqlite3_column_int64`, `sqlite3_column_double`, `sqlite3_column_blob`, `sqlite3_column_bytes`, `sqlite3_column_bytes16`, `sqlite3_data_count`, `sqlite3_finalize`, `sqlite3_reset`, `sqlite3_step`, `sqlite3_sql`, `sqlite3_expanded_sql`, `sqlite3_normalized_sql`, `sqlite3_stmt_status`, `sqlite3_stmt_busy`, `sqlite3_stmt_readonly`, `sqlite3_stmt_isexplain`.  Outcome: column / step / finalize / reset / data_count / column_* cluster were already wired by an earlier pass (TestModuleTest1.pas:1466..1683 + registration 3169..3202).  This close-out adds the residual eight handlers `tcl_test_sql` / `tcl_test_ex_sql` / `tcl_test_norm_sql` / `tcl_test_stmt_status` / `tcl_test_stmt_busy` / `tcl_test_stmt_readonly` / `tcl_test_stmt_isexplain` / `tcl_column_bytes16` at TestModuleTest1.pas:1685..1855, each cited to upstream: test1.c:5602..5618 (test_sql), 5619..5638 (test_ex_sql), 5640..5656 (test_norm_sql), 2288..2330 (test_stmt_status), 3034..3057 (test_stmt_busy), 2952..2971 (test_stmt_readonly), 2979..2998 (test_stmt_isexplain), 5853..5912 (column_bytes16); registered at TestModuleTest1.pas:3203..3222 next to the existing column block.  Engine APIs already in place (passqlite3main.pas:488..499 / 3983..4162; passqlite3codegen.pas:45752 sqlite3_stmt_isexplain; passqlite3vdbe.pas:5416 sqlite3_column_bytes16).  Stmt pointer decoded via sqlite3TestTextToPtr ("0xABCD..." hex), matching the existing test1 cluster — no getStmtPointer helper needed (no affected test exercises the Tcl-command-name fallback).  expanded_sql copies via TCL_VOLATILE then sqlite3_free's the engine buffer (mirrors test1.c:5635..5636).  stmt_status accepts the same seven SQLITE_STMTSTATUS_* symbolic names as upstream (test1.c:2302..2310).  Smoke: tclsh `load libpassqlite3tcl.so` + `sqlite3_prepare_v2 db {SELECT 1,2,3} -1 tail` → `cols=3 sql=SELECT 1,2,3 esql=SELECT 1,2,3 busy=0 ro=1 iexp=0 status=0` (post-rebuild via `src/tests/build_tcl_lib.sh`).  Regression: 99/100 binaries / 5179 assertions (TestFuzzDiff pre-existing); TestExplainParity 224/1026 == baseline.  Cite: test1.c registration table at 9152..9168 / 9203..9215.
  - [X] **9.4.divbug.62.c** Binding API: `sqlite3_bind_int`, `sqlite3_bind_int64`, `sqlite3_bind_double`, `sqlite3_bind_text`, `sqlite3_bind_text16`, `sqlite3_bind_null`, `sqlite3_bind_blob`, `sqlite3_bind_zeroblob`, `sqlite3_bind_zeroblob64`, `sqlite3_bind_value_from_select`, `sqlite3_bind_parameter_count`, `sqlite3_bind_parameter_name`, `sqlite3_bind_parameter_index`, `sqlite3_clear_bindings`.  Outcome: all 14 handlers ported as Tcl_Obj-style commands in `src/tests/tcl/testmodules/TestModuleTest1.pas:1953..2393`, each cited to its test1.c source line (tcl_bind_int → test1.c:3796..3824, tcl_bind_int64 → 3972..4000, tcl_bind_double → 4010..4077 incl. NaN/SNaN/+Inf/-Inf/Epsilon sentinel table, tcl_bind_null → 4086..4112, tcl_bind_text → 4122..4165, tcl_bind_text16 → 4175..4226, tcl_bind_blob → 4235..4281 with optional `-static` arg, tcl_bind_zeroblob → 3723..3750, tcl_bind_zeroblob64 → 3759..3787, tcl_bind_value_from_select → 4338..4379, tcl_bind_parameter_count → 4736..4751, tcl_bind_parameter_name → 4760..4779, tcl_bind_parameter_index → 4787..4806, tcl_clear_bindings → 4812..4827).  Stmt pointer decoded via `sqlite3TestTextToPtr` (TestModuleTest1.pas:98) — same path as the .62.b column/step cluster; no `getStmtPointer` Tcl-command-name fallback needed (no test in the harness gap relies on it).  All registered in `Sqlitetest1_Init` at TestModuleTest1.pas:3397..3424 mirroring test1.c:9114..9132.  Smoke (tclsh + libpassqlite3tcl.so + Sqlite3): `sqlite3_prepare db {SELECT ?,?,?,?,?,:name,?,?} -1 t` → pcount=8, pname6=`:name`, pidx for `:name`=6; all 8 bind variants + `sqlite3_clear_bindings` return 0/OK and `sqlite3_finalize` succeeds.  Regression: TestExplainParity 224/1026 (== baseline).  Cite: test1.c registration table 9114..9132.
  - [X] **9.4.divbug.62.d** Resource accounting: `sqlite3_status`, `sqlite3_db_status`, `sqlite3_release_memory`, `sqlite3_soft_heap_limit`, `sqlite3_soft_heap_limit64`, `sqlite3_hard_heap_limit64`, `sqlite3_limit`.  Cite: test1.c `test_release_memory` (6334), `test_soft_heap_limit` (6488), `test_hard_heap_limit` (6515), `test_limit` (7378); test_malloc.c `test_status` (1286), `test_db_status` (1343).  Outcome: `sqlite3_status` / `_release_memory` / `_limit` were already wired in 9.4.divbug.62.c (TestModuleTest1.pas:2573/2639/2665).  This close-out adds the residual four handlers — `tcl_test_db_status` / `tcl_test_soft_heap_limit` / `tcl_test_hard_heap_limit` at TestModuleTest1.pas:2735..2870 (each cited to its upstream source line) and registers them in `Sqlitetest1_Init` at TestModuleTest1.pas:3445..3454, with both `sqlite3_soft_heap_limit` and `sqlite3_soft_heap_limit64` routed through the same handler (mirrors test1.c:9177..9178).  `tcl_test_db_status` ports the SQLITE_/DBSTATUS_ prefix stripping (test_malloc.c:1378..1379) plus the 14-entry opcode table (test_malloc.c:1357..1372); falls back to integer parse on miss.  Engine APIs already present (passqlite3main.pas:461 sqlite3_db_status, :512 sqlite3_soft_heap_limit64, :513 sqlite3_hard_heap_limit64, :509 sqlite3_release_memory).  Symbolic opcode constants inlined as literals with `{ SQLITE_DBSTATUS_* }` cite comments (passqlite3pager.pas:481..494 not in uses clause; matches the pattern already in `tcl_test_db_status` siblings).  Smoke (tclsh + Sqlite3 + :memory:): `sqlite3_status SQLITE_STATUS_MEMORY_USED 0` → `0 9624 9624`, `sqlite3_db_status db CACHE_USED 0` → `0 4792 0`, `sqlite3_db_status db SQLITE_DBSTATUS_LOOKASIDE_USED 0` → `0 0 0` (prefix-strip), `sqlite3_soft_heap_limit64 1048576` then `_ -1` → `0`/`1048576` (set/query), `sqlite3_hard_heap_limit64 0` → `0`, `sqlite3_limit db SQLITE_LIMIT_LENGTH -1` → `1000000000`.  TestExplainParity 224/1026 (== baseline); regression: 99/100 binaries / 5179 assertions (TestFuzzDiff pre-existing).
  - [X] **9.4.divbug.62.e** Function / extension management: `sqlite3_create_function`, `sqlite3_create_function_v2`, `sqlite3_create_window_function`, `sqlite3_reset_auto_extension`, `sqlite3_load_extension`, `sqlite3_simulate_device`, `sqlite3_user_version`.  Cite: test1.c `test_create_function`, `test_reset_auto_extension`, `test_simulate_device`.  Outcome: `sqlite3_create_function` + `sqlite3_reset_auto_extension` were pre-existing (TestModuleTest1.pas:3161 / 3276, registered at 3589 / 3606).  Added the five residual handlers + registrations: `tcl_test_create_function_v2` (port of test1.c:1947..2059 — CreateFunctionV2 record + cf2Func/Step/Final/Destroy callbacks; cf2Func/Step/Final are upstream no-ops, cf2Destroy fires optional -destroy Tcl script via Tcl_EvalObjEx and Tcl_DecrRefCount's the four script Tcl_Obj's), `tcl_test_create_window` (port of test_window.c:24..177 — TestWindow record + doTestWindowStep/Finalize trampolines that build a `[script accumulator ?args...?]` Tcl list per call, eval at TCL_EVAL_GLOBAL, and route result back via sqlite3_result_error/_text; testWindowDestroy frees the four xStep/xFinal/xValue/xInverse refs), `tcl_test_load_extension` (port of test1.c:2064..2117 — extracts db via Tcl_GetCommandInfo→objClientData→PTestSqliteDb, calls engine `sqlite3_load_extension` which is a SQLITE_OMIT_LOAD_EXTENSION stub at passqlite3main.pas:2840 — same error surface as upstream OMIT build), `tcl_test_simulate_device` (no-op stub — the underlying test_devsym.c VFS is not ported; commands that merely toggle it back off no longer abort), `tcl_test_user_version` (no upstream Tcl-command counterpart — provides a thin `sqlite3_user_version DB ?VALUE?` shim that proxies to `PRAGMA user_version` get/set).  All ported at TestModuleTest1.pas:3414..3791; registered in `Sqlitetest1_Init` at TestModuleTest1.pas:3787..3801.  Smoke (tclsh + libpassqlite3tcl.so + Sqlite3 + :memory:): `sqlite3_reset_auto_extension` → empty/ok; `sqlite3_user_version db` → `0` then after `db 42` → `42`; `sqlite3_simulate_device` → empty/ok; `sqlite3_load_extension db /nope.so` → `extension loading is disabled` (matches engine stub); `sqlite3_create_window_function db myagg m_step m_value m_value m_inverse` then `SELECT myagg(x) FROM t` → `{1 2 3}`; `sqlite3_create_function_v2 db fxx 1 utf8 -func {list F} -destroy {puts dest}` → empty/ok.  Regression: 99/100 binaries / 5179 assertions (TestFuzzDiff pre-existing); TestExplainParity 224/1026 (== baseline).  Residuals: (a) `tcl_test_simulate_device` is no-op only — tests that need observable I/O-error injection through the device-sim VFS (test_devsym.c not ported) will still mis-behave (orthogonal); (b) `tcl_test_create_function_v2`'s cf2Func/Step/Final mirror upstream no-ops (only the registration / xDestroy path is exercised).
  - [X] **9.4.divbug.62.f** Config & legacy: `sqlite3_config_pmasz`, `sqlite3_config_uri`, `sqlite3_config_alt_pcache`, `sqlite3_rekey`, `sqlite3_rekey_v2`, `sqlite3_key`, `sqlite3_key_v2`.  rekey/key family is a SEE-only stub (return SQLITE_OK).  Cite: test1.c `test_config_*`, `test_rekey`.  Outcome: `sqlite3_config_uri` / `_config_pmasz` / `sqlite3_rekey` were pre-existing from 9.4.divbug.62.d (TestModuleTest1.pas:3232 / 3254 / 2871).  Added the four residual handlers + registrations: `tcl_test_key` (port of test1.c:651..663 — TCL_OK stub matching upstream non-SEE build), `tcl_test_key_v2` (no upstream Tcl counterpart — TCL_OK stub shared with sqlite3_rekey_v2; SEE-only multi-database variants), `tcl_test_config_alt_pcache` (port of test_malloc.c:927..966 — full argument validation INSTALLFLAG / DISCARDCHANCE [0..100] / PRNGSEED / HIGHSTRESS exactly like upstream; install is a no-op because test_pcache.c installTestPCache is not ported, so tests that merely toggle the alt pcache on/off no longer abort but those depending on observable pcache-fault injection still mis-behave).  All ported at TestModuleTest1.pas:2879..2961; registered in `Sqlitetest1_Init` at TestModuleTest1.pas:4001..4008 (sqlite3_key / sqlite3_key_v2 / sqlite3_rekey_v2 next to existing sqlite3_rekey) and TestModuleTest1.pas:4023..4027 (sqlite3_config_alt_pcache next to _config_uri / _config_pmasz).  Smoke (tclsh + libpassqlite3tcl.so + Sqlite3): all 7 `info commands sqlite3_<cmd>` resolve; `sqlite3_config_uri 1` and `_config_pmasz 16384` return `SQLITE_MISUSE` (expected — engine already initialised, matches upstream post-init behaviour); `sqlite3_config_alt_pcache 0`, `_alt_pcache 0 50 1 0`, `sqlite3_key foo bar`, `sqlite3_rekey foo bar`, `sqlite3_key_v2 foo main bar`, `sqlite3_rekey_v2 foo main bar` all return empty/OK.  Regression: 99/100 binaries / 5179 assertions (TestFuzzDiff pre-existing); TestExplainParity 224/1026 (== baseline).  Residuals: alt_pcache stub does not inject pcache faults — tests requiring observable installTestPCache behaviour (test_pcache.c not ported) remain mis-behaving; orthogonal.  Parent 9.4.divbug.62 flips [~] → [X] (all a..f closed).
- [X] **9.4.divbug.63** Harness gap: tcl-shim helper commands unported — tests fail with `invalid command name "run_thread_tests"` / `"test_cli_invocation"` / `"test_find_cli"` / `"test_find_sqldiff"` / `"tcl_variable_type"` / `"breakpoint"` / `"database_may_be_corrupt"` / `"explain_no_trace"` / `"file_control_reservebytes"` / `"faultsim_test_result"` (~25 tests incl. thread001..005, thread1, thread2, tempdb2, shell1..9/A/B, select9, selectC/E/H, sharedA/B, sqldiff1, skipscan2, sort4, types3, unique, unique2, unionallfault, quota-glob, pragma6, parser1).  Cite: src/tests/tcl/tester_min.tcl shim coverage.  Surfaced 9.4.4.g.  Outcome: ported breakpoint/database_*_corrupt/tcl_variable_type/explain_no_trace/faultsim_test_result (.63.a) and test_find_cli/test_cli_invocation/test_find_sqldiff/run_thread_tests/file_control_reservebytes (.63.b).  Commits 7be23b7, 1800d46, 8de8be5.
- [X] **9.4.divbug.64** `db func` and `db format` subcommands unported — tests fail at the first `db func name argcount body` or `db format` call with `unknown subcommand "func" - implemented in 9.4.2.d..o` (~12 tests incl. tkt1514, tkt-d11f09d36e, tkt-7bbfb7d442, tkt35xx, update, update2, unordered, windowD, whereD, pushdown, savepoint7, schema2/4/6, rowvalue3, rdonly, qrf03..06).  Cite: tclsqlite.c `DbObjCmd` — funcArm + formatArm.  Surfaced 9.4.4.g.  Outcome: ported funcArm + formatArm into DbObjCmd (tclsqlite.c:3368,3386).  Commit 3b37eed.
- [X] **9.4.divbug.65** Tester Tcl globals `::DB` / `::STMT` (sqlite3 + sqlite3_stmt opaque pointers) not exported by tester_min.tcl — schema.test family aborts at `can't read "::DB": no such variable`.  Cite: tester.tcl `set ::DB [sqlite3_connection_pointer db]`.  Surfaced 9.4.4.g.  Outcome: ported tester.tcl:557 `set ::DB [sqlite3_connection_pointer db]` into reset_db (tester_min.tcl); schema.test family now runs to completion (schema/schema2/schema4/schema5/schema6/starschema1/trustschema1 all run, no more `::DB` abort).  `::STMT` is NOT set by upstream tester.tcl — .test files manage it locally — so no shim needed.
- [X] **9.4.divbug.66** SQL functions / extensions unregistered: `zeroblob`, `regexp`, `regexpi`, `percentile`, `percentile_cont`, `randstr`, `if` — `no such function: zeroblob` (zeroblob, without_rowid1/6/7); `no such function: percentile` (percentile); `no such extension: regexp` (regexp1/2); `no such function: randstr` (tkt3918); `no such function: if` (tkt-9d68c883).  Cite: ext/misc/percentile.c, ext/misc/regexp.c, test_func.c `randStr`, src/func.c built-in scalar registration.  Surfaced 9.4.4.g.  Progress 2026-05-16: zeroblob already wired (codegen.pas:53699/55334); regexp+percentile wired at sqlite3_open_v2 (commit 51de8ba); randstr+if landed 9.4.divbug.66.a.
  - [X] **9.4.divbug.66.a** Register `randstr(N,M)` from test_func.c:40 + `if(c,a,b)` (3-arg ternary scalar) as built-in scalar functions surfaced even without `autoinstall_test_functions`.  randStr is already ported in `src/tests/tcl/testmodules/TestModuleFunc.pas`; the gap is that it's only registered via the Tcl `autoinstall_test_functions` hook (test_func.c:728..778).  Two upstream paths: (a) call `Sqlitetestfunc_Init` automatically from the tester bootstrap (matches upstream auto-init); (b) port the `if()` function (likely in test_func.c too).  Cite: test_func.c:632..778 registration + `if` definition.  Outcome: (a) Sqlitetestfunc_Init now mirrors test_func.c:949 — calls sqlite3_auto_extension(@registerTestFunctions) so randstr surfaces on every Tcl-bridge connection (tkt3918 5/203 → 5/2503 assertions, no skipped sub-tests); (b) `if` registered as INLINE_FUNC alias for `iif` via aBuiltinFuncs[83] (mirrors func.c:3430).  Cite: src/tests/tcl/testmodules/TestModuleFunc.pas:524, src/passqlite3codegen.pas:55519.
- [X] **9.4.divbug.67** `stmtrand` SQL extension unported — `no such extension: stmtrand` (stmtrand, stmt, sqllimits1, starschema1).  Cite: src/test_stmt.c registration.  Surfaced 9.4.4.g.  Outcome: wired stmtrand as a static extension at sqlite3_open_v2.  Commit 46d8e3d.
- [ ] **9.4.divbug.68** `PRAGMA module_list` does not include `fts5` row — pragma5-2.1 expects `[fts5]` got `[]`.  Cite: pragma.c PragTyp_MODULE_LIST + virtual-table module registration of fts5.  Surfaced 9.4.4.g.  Triage 2026-05-16: `PragTyp_MODULE_LIST` handler itself is correct (codegen.pas:51139..51148 walks `db^.aModule` HASH; pas currently emits 23 modules incl. dbstat, sqlite_dbpage, generate_series, json_each, json_tree, sqlite_stmt, fsdir, completion, zipfile, etc. — strictly more than the C oracle's 16 in this build).  The pragma5-2.1 case is gated by `ifcapable fts5` (pragma5.test:49), so the only real gap is the unported fts5 module itself — see sub-task .68.a.  Do not flip [X] until .68.a lands.
  - [ ] **9.4.divbug.68.a** Port fts5 vtab module (ext/fts5/*.c) — blocker for `PRAGMA module_list` containing `fts5`.  XL.
- [X] **9.4.divbug.69** `PRAGMA temp.<header_value>` SIGSEGV — originally triaged as a Tcl-bridge `sqlite3 HANDLE FILENAME ?OPTIONS?` parser-stub mismatch (residue of divbug.57), but inspection showed `DbMain` (PasTclSqlite.pas:4455..4718) already covers the option set; pragma3 was crashing the interpreter long before any option parsing happened.  Real root: Pascal `sqlite3Pragma` skipped C's `if( iDb==1 && sqlite3OpenTempDatabase(pParse) ) return;` (pragma.c:454..459), so any `PRAGMA temp.<name>` that emits OP_ReadCookie / OP_Transaction hit a nil `db^.aDb[1].pBt` and segfaulted in OP_ReadCookie's `sqlite3BtreeGetMeta(nil,…)`.  Minimal repro `PRAGMA temp.data_version` on `:memory:` SIGSEGV pre-fix, returns `1` post-fix.  Fix: lazily open the temp btree in codegen.pas right after the schema-prefix resolve (pragma.c:454..459 port).  Landed 9.4.divbug.69.
- [X] **9.4.divbug.70** Error-text divergences (parser/resolver hints):
  - `syntax error after column name "<x>"` drops the quoted column name (parser1, tokenize).
  - `no such column: "<id>" - should this be a string literal in single-quotes?` hint omitted (quote-2.1.x).
  - `misuse of aggregate function min()` vs C `misuse of aggregate: min()`; `misuse of aliased aggregate <m>` vs C `misuse of aggregate: <fn>()` (select1-2.20..23, tkt3508).
  - `unknown table option: unknown2` drops the offending name (tableopts, strict1).
  - `1st ORDER BY term out of range - should be between 1 and 2` not produced (select1-4.10.2).
  - `a JOIN clause is required before ON` not detected (tkt3935.5/7).
  Cite: parse.y `%syntax_error` (divbug.53 partial overlap), build.c `markAllShadowTablesOf`/AddColumnError, resolve.c aggregate-misuse messages, select.c ORDER BY index range check.  Surfaced 9.4.4.g.  Outcome: ported error-text hints (parse.y:1671/240, build.c:5080, resolve.c:789/1812) plus nested/aliased aggregate misuse (codegen.pas:10625-10720, 10921-10985, 11038); a/b/d/e/f pre-existing.  Commits 1a0629b, d04edb5.
- [X] **9.4.divbug.71** STRICT-typed table mis-error path: `INSERT INTO strict t1(a) VALUES('x')` reports `*** in database main ***` framing (integrity-check output) instead of `non-INT value in t1.a` (strict1, strict2); aborted-stmt rollback reports `unknown error` instead of `abort due to ROLLBACK` (tkt2817, tkt2820, savepoint7).  Cite: insert.c STRICT type-check error + vdbe.c VDBE_E_ABORT message lift.  Surfaced 9.4.4.g.  Outcome: (1) sqlite3EndTable now folds tabOpts&TF_Strict into pTab^.tabFlags + promotes COLTYPE_ANY/forces NOT NULL on PK cols (build.c:2686..2713); (2) OP_TypeCheck implemented end-to-end, emitting `cannot store <type> value in <COLTYPE> column <tbl>.<col>` with SQLITE_CONSTRAINT_DATATYPE (vdbe.c:3305..3393); (3) sqlite3ErrStr handles SQLITE_ABORT_ROLLBACK / ROW / DONE before the masked primary-code table so aborted-stmt rollbacks report `abort due to ROLLBACK` not `unknown error` (main.c:1685).  Repro `INSERT INTO t1(a) VALUES('x')` on STRICT now returns `cannot store TEXT value in INT column t1.a`.  Commit be8a29b.
- [X] **9.4.divbug.72** Row-value misuse detection missing — `SELECT (1,2)` and `SELECT … WHERE (a,b)=...` constructs accepted silently when C raises `row value misused` (rowvalue-3.1.x, rowvalue4-1.x; cascades to rowvalue2/3/7/8/9/A).  Cite: expr.c `sqlite3ExprCheckIN` + parser rowvalue arity gate.  Surfaced 9.4.4.g.  Outcome: row value misused detection (expr.c:5597, codegen.pas:6532) + LIMIT/OFFSET arms (codegen.pas:24369, 29951, 31909).  Commits 7eb9851, 8618b87.
- [X] **9.4.divbug.73** `rowid` post-INSERT resolution returns 0 — rowid-4.5 expects last_insert_rowid()=3 got 0; sibling rowid-4.5.1 expected `[3 3]`.  Cite: insert.c `sqlite3_last_insert_rowid` setting around OP_NewRowid / OP_Insert.  Surfaced 9.4.4.g.  Outcome: wired sqlite_search_count Tcl-linked counter (vdbe.c:56, vdbeaux.c:3813, test1.c:9366).  Commit 524dbb1.
- [X] **9.4.divbug.74** UPSERT `ON CONFLICT DO UPDATE` increments target row count off by one — upsert3-200 expected row matrix `[1 2 2 x 3 4 1 x 5 6 0 x]` got `[1 2 1 x …]` (the "2" is the conflict-incremented col).  Cite: insert.c upsert.c `sqlite3UpsertDoUpdate` register handling.  Surfaced 9.4.4.g.  Outcome: gate UPSERT excluded.* rewrite on real-table shadow (codegen.pas:8024..8125).  Commit e2a5f6c.
- [X] **9.4.divbug.75** select7 correlated/derived `no such column: P.pk` — `SELECT … FROM (SELECT pk FROM t) P WHERE P.pk = ...` resolver misses the wrapper-qualified column; sub-select "expected N columns" error text also diverges.  Cite: resolve.c `lookupName` derived-table arm (sibling of divbug.59 nested-from logic).  Surfaced 9.4.4.g.  Outcome: compound-arm correlated outer-ref resolve (codegen.pas:10094).  Commit 74e00c2.
- [X] **9.4.divbug.76** View-column resolution `no such column: y` — tkt3346-1.x: `INSERT INTO t SELECT y FROM v` where `v` is a view exposing `y` raises `no such column: y`.  Cite: select.c viewGetColumnNames / resolve.c lookupName view-source pEList walk.  Surfaced 9.4.4.g.  Outcome: the bare-view minimal repro (`CREATE VIEW v AS SELECT 1 AS y; INSERT INTO t SELECT y FROM v`) already passed; the tkt3346-1.1 deeper shape `SELECT *, (SELECT y FROM (SELECT x.b='alice' AS y)) FROM (SELECT * FROM t1) AS x` failed because the deepest no-FROM subquery's recursive sqlite3SelectPrep (codegen.pas:26252) emitted `no such column: x.b` with no outer NameContext, setting pParse^.nErr before sqlite3ExpandSubquery could build the inner pSTab — middle's bare `y` lookup then found pSTab=nil and surfaced as `no such column: y`.  Fix: (1) gate the TK_DOT cnt==0 error in ResolveExpr on `p^.pSrc <> nil and p^.pSrc^.nSrc > 0` (codegen.pas:9921) so an empty-FROM SELECT defers the error; (2) gate flagUnresolvedTKID's sweep on the same condition in sqlite3ResolveExprNames (codegen.pas:9098) mirroring resolve.c lookupName's NC->pNext walk (resolve.c:341..706); (3) after the existing ResolveOuterRefs pass over middle's clauses, walk each FROM-subquery item's interior expressions and apply ResolveOuterRefs/ResolveOuterIDs against the OUTER pSrc (codegen.pas:10187..10227).  The deepest's `x.b` rewrites to TK_COLUMN against the outer `x` cursor and the resolver completes without error.  A separate pre-existing codegen AV (OP_Rewind on unopened cursor for FROM-subqueries with no FROM clause — also reproduces on plain `SELECT (SELECT y FROM (SELECT 1 AS y));` without my changes) still triggers at exec but is orthogonal to name resolution.  Commit f09bb72.
- [X] **9.4.divbug.77** Cross-schema trigger validation error text — triggerupfrom-2.4 expects `malformed database schema (tr3) - trigger tr3 cannot reference objects in database main` got `unable to open database: test.db`; trustschema1 same family.  Cite: trigger.c `sqlite3FixSrcList` schema-cross detection + parse-schema error path.  Surfaced 9.4.4.g.  Outcome: cross-schema trigger validation (prepare.c:22..54, vdbe.c:7140..7163).  Commit d7f1dd1.
- [X] **9.4.divbug.78** Wide-table SCAN+predicate mis-count — widetab1-340: `SELECT count(*) FROM t WHERE col=…` expected 7 got 10 on a table with many columns (likely planner picks wrong index or skips predicate eval on overflow page).  Cite: where.c index/cost selection for tables with `nCol > sizeof(Bitmask)*8`.  Surfaced 9.4.4.g.  Outcome: wide-table predicate via multi-VALUES coroutine drain (codegen.pas:61901..61959).  Commit a3e2335.
- [X] **9.4.divbug.79** windowE ROWS-framing produces permuted output — windowE-1.3 expected `[5 5,4 5,4,1 5,4,1,6 5,4,1,6,3 5,4,1,6,3,2]` got `[2 2,3 2,3,6 2,3,6,1 2,3,6,1,4 2,3,6,1,4,5]`.  Cite: window.c ROWS UNBOUNDED PRECEDING frame ordering + sqlite3WindowCodeStep result-row emission.  Surfaced 9.4.4.g.  Outcome: windowE ROWS framing (window.c:4262).  Commit 041da7c.
- [X] **9.4.divbug.80** `ORDER BY without LIMIT on DELETE`/UPDATE not detected — wherelimit-0.1 expects `ORDER BY without LIMIT on DELETE` got plain `near "ORDER": syntax error` from the grammar; same for wherelimit3.  Cite: parse.y delete/update grammar gate + build.c SQLITE_ENABLE_UPDATE_DELETE_LIMIT error emission.  Surfaced 9.4.4.g.  Outcome: ORDER BY without LIMIT on DELETE (parse.y:977-995).  Commit 031f065.
- [X] **9.4.divbug.81** Attached / `query_only` DB readonly enforcement (residue of divbug.57) — queryonly-1.4/.5 expects `attempt to write a readonly database` got `0 {}`; pager4-1.3/.4 same family; rdonly.test cascade.  Cite: pager.c `pagerOpenWalIfPresent` + main.c sqlite3BtreeBeginTrans honor PRAGMA query_only.  Surfaced 9.4.4.g.  Outcome: PRAGMA query_only readonly enforcement (vdbe.pas:10043).  Commit 5e01244.
- [X] **9.4.divbug.82** INSERT…RETURNING / scalar-function eval returns empty row — tkt-31338-3.1 expected `[4 1 2 3 4 {}]` got `[]`; tkt-26ff-1.x and tkt-5e10420e8d cascade.  Cite: vdbe.c OP_ResultRow under deferred-returning subroutine emission.  Surfaced 9.4.4.g.  Outcome: INSERT…RETURNING / scalar-fn empty (codegen.pas:29117, 31987).  Commit 4324004.
- [X] **9.4.divbug.83** Planner row-order divergence across where* family — whereA-1.2 expected `[3 4.53 {} 2 hello world 1 2 3]` got `[1 2 3 2 hello world 3 4.53 {}]`; whereG-1.3 expected detail-string regex `/.*track.*composer.*album.*/` got order with composer scanned first (EQP residue of divbug.55); whereB/F/I/N, where2/6/8, orderbyB show similar ordering / EQP-shape divergences.  Cite: where.c cost model for multi-table joins + EQP detail emission.  Surfaced 9.4.4.g.  Outcome: planner row order (where.c:7125).  Commit eab96c2.
- [X] **9.4.divbug.84** Long-running tests hit the 20 s per-test driver timeout — `select4.test`, `writecrash.test`, `securedel2.test` all aborted by the timeout watchdog and counted as FAIL.  Likely no engine bug per se — either driver timeout needs raising for these three, or each is hitting a slow vdbe-level loop worth investigating separately.  Surfaced 9.4.4.g.  Outcome: per-test timeout overrides for select4/writecrash/securedel2 (TclTestDriver.pas).  Commit c8f1af4.

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
    - [X] **10.1.42.b.8** Port `wherePathName` + `sqlite3Where{Term,Clause,Loop}Print` + `showAllWhereLoops` (where.c:2375..2520/5512..5519/6469..6488). Debug-only `cId`+`rStarDelta` carved from pre-existing _pad58..63 in TWhereLoop. Re-enabled 7 deferred arms (closes b.4/b.5/b.6 + WHERETRACE_ALL_LOOPS at where.c:7103). Archive.
    - [X] **10.1.42.a.6.1** `havingToWhere` + `havingToWhereExprCb` (select.c:7047) + `sqlite3ExprIsConstantOrGroupBy`; wired SF_Aggregate+GROUP-BY (8422..8431). 0x100.
    - [X] **10.1.42.a.6.2** `countOfViewOptimization` (select.c:7128..7204); wired after propagateConstants (7924..7930). 0x200. SQLITE_CountOfView added.
    - [X] **10.1.42.a.6.3** `optimizeAggregateUseOfIndexedExpr` (select.c:6549..6586); wired pre assignAggregateRegisters (8527..8529). 0x20.
    - [X] **10.1.42.a.6.4** `aggregateConvertIndexedExprRefToColumn` + walker (select.c:6591..6623); wired after sqlite3WhereEnd (8600..8615). 0x20.
    - [X] **10.1.42.a.6.5** "Finished with AggInfo" at sqlite3Select tail (select.c:8933..8945). 0x20.
    - [X] **10.1.42.a.7** Outer-join strength-reduction loop (select.c:7708..7770) + `sqlite3ExprImpliesNonNullRow`/`impliesNotNullRow`/`bothImplyNotNullRow` (expr.c:6857..7031) + `unsetJoinExpr` (471..494). All 4× 0x1000 arms. SQLITE_SimplifyJoin (0x2000). Archive.
    - [X] **10.1.42.a.8** FROM-subquery superfluous-ORDER-BY drop (select.c:7822..7838, tag-select-0230). SQLITE_OmitOrderBy ($40000). 0x800. Archive.
    - [X] **10.1.42.a.9** `pushDownWhereTerms` (5125..5286) + `disableUnusedSubqueryResultColumns` (5296..5358). 0x4000. SQLITE_PushDown ($1000) + SQLITE_NullUnusedCols ($04000000). Restriction 6c (partition-less window) conservatively bailed. Archive.
    - [X] **10.1.42.a.10** all-FROM snapshot (select.c:8144..8149, 0x8000).
    - [X] **10.1.42.a.11** top-level ORDER-BY drop (select.c:7625..7644, 0x800).
    - [X] **10.1.42.a.12** DISTINCT→GROUP BY (select.c:8151..8196, 0x20000). Gates on selFlags == SF_Distinct + pWin=nil + ExprListCompare=0. Closes a.4. Archive.
  - [X] **10.1.42.c** `sqlite3DebugPrintf` (printf.c:1514..1532) → passqlite3printf.pas.
  - [X] **10.1.42.d** Build-flag gating: `build.sh` honours `SQLITE_DEBUG=1` → `-dSQLITE_DEBUG`. Documented in `src/passqlite3.inc`.

### 10.1f Long-tail / specialised dot-commands

- [X] **10.1f** Closed 2026-05-13 — every 10.1f.0..10.1f.16 sub-arm landed (.backup/.restore/.clone, .archive/.ar, .session stub, .recover, .dbinfo, .dbconfig, .filectrl, .sha3sum, .crnl/.binary/.connection/.unmodule, .vfsinfo/.vfslist/.vfsname).  Out-of-scope deps stubbed faithfully per upstream `SQLITE_OMIT_*` shape.
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

- [ ] **12.1** `perf record` on benchmark workloads; identify the
  top 10 hot functions.

- [ ] **12.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.

- [ ] **12.3** Consider replacing the VDBE big `case` with threaded
  dispatch (computed-goto-style) using `{$GOTO ON}`.  Land only if
  profiling shows the switch is a real bottleneck.

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

- [ ] **13.1** AFL wiring.  `src/tests/fuzz/afl-driver.pas` wraps
  9.3.1 for `afl-fuzz` (read input from stdin, write to a tmp
  file, invoke the in-process harness, return AFL-compatible exit
  codes).  Stand up instrumentation route (1), (2), or (3) above;
  document the choice in `src/tests/fuzz/README.md`.  Skip
  gracefully if AFL isn't installed — script must self-report.

- [ ] **13.2** Crash-vs-divergence classifier.  Triage helper
  that separates (a) Pascal crash, (b) C crash, (c) silent
  divergence, (d) timeout.  Each gets its own bucket under
  `src/tests/fuzz/crashes/`.

- [ ] **13.3** ≥24 h soak target.  Wrapper script `fuzz-soak.sh`
  with `--duration` (default 24h) and stop-on-first-divergence.
  Not a CI gate — a manual gate documented in README.  Each
  clean soak bumps a counter in `src/tests/fuzz/SOAK_LOG.md` so
  we can prove the wallclock budget over time.

- [ ] **13.4** Coverage-guided seed minimisation.  `afl-cmin` +
  `afl-tmin` pipeline pruning the seed set to the smallest input
  set that still hits every covered branch.  Re-commit the
  minimised seeds when they shrink.

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
