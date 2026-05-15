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
    - [ ] **9.4.2.x.1.a** Port `SqlPreparedStmt` cache +
      `dbPrepareAndBind` / `dbReleaseStmt` / `dbReleaseStmtCache`
      (tclsqlite.c:1356..1614).  Required so the eval continuation
      can own a long-lived `pPreStmt` across NRE re-entries instead of
      finalising at the end of each Pascal stack frame.
    - [ ] **9.4.2.x.1.b** Port `addDatabaseRef` / `delDatabaseRef`
      (tclsqlite.c around 1308/1686/1842) — the continuation
      lifecycle straddles arbitrary nested `vwait`s so the SqliteDb*
      must be refcount-pinned.
    - [ ] **9.4.2.x.1.c** Introduce a Pascal `TDbEvalContext` record
      mirroring tclsqlite.c:1626..1636 and split the existing
      `DbEvalArm` row loop into `dbEvalInit` / `dbEvalStep` /
      `dbEvalRowInfo` / `dbEvalFinalize` / `dbEvalColumnValue`
      (tclsqlite.c:1669..1876) keeping behaviour identical.
    - [ ] **9.4.2.x.1.d** Implement `DbEvalNextCmd: TTclNRPostProc`
      (tclsqlite.c:1915..2005) and wire the 3/4/5-arg
      script-body branch of `DbEvalArm` (tclsqlite.c:3340..3360)
      through `Tcl_NRAddCallback` + `Tcl_NREvalObj`.  Keep the
      2-arg (`db eval SQL`) flat-list path on the direct
      `sEval`-on-stack code (tclsqlite.c:3262..3320).

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
  - [ ] **9.4.4.e** Broaden sweep to 250 tests (~25% of corpus).
    Expected to surface the bulk of port-side divbugs.
  - [ ] **9.4.4.f** Broaden sweep to 500 tests.
  - [ ] **9.4.4.g** Full 946 tcl-feature sweep; gate aims for
    `pas-strict diverged == 0` per 9.4.8.c.
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
- [ ] **9.4.divbug.24.b** aggnested-3.2/3.3 row-wise instead of folded result + aggnested-3.11 SIGSEGV — independent of sqlite_sequence (no AUTOINCREMENT in 3.2/3.3); see DIVERGENCES.md.
- [X] **9.4.divbug.25** `update-19.10` `AssertH FAILED: idxColIsBeingUpdated rowid` — fixed by stopping IPK index-column rewrite to XN_ROWID in CreateIndex.  Commit `04d98cf`.
- [X] **9.4.divbug.26** Echo vtab INSERT fails — `echoUpdate` emits `%Q`-quoted column names.  Parser correctly reduces `STRING` via `nm ::= STRING` (parse.y:340) into `idlist` (parse.y:1126), but Pascal `sqlite3IdListAppend` (codegen.pas:42536) stored raw token text via `sqlite3DbStrNDup` without dequoting — so resolver saw `'a'` (with single quotes) and reported "no column named 'a'".  C `sqlite3IdListAppend` (build.c:4726) routes through `sqlite3NameFromToken` which dequotes.  Fix: inline `sqlite3DbStrNDup + sqlite3Dequote` (parser-unit `sqlite3NameFromToken` not visible from codegen).
- [X] **9.4.divbug.27** Engine OOM-recovery path segfaults under an injected malloc failure (memdebug build) — blocked `do_malloc_test` from being fully useful.  Surfaced by 9.4.2.g.9.  Root cause: Pascal `sqlite3DbMallocRaw{,NN,Zero}` / `sqlite3DbRealloc` / `sqlite3DbStrNDup` wrappers in `passqlite3util.pas:2529..2587` returned the raw `sqlite3_malloc*` result without calling `sqlite3OomFault(db)` on failure (cf. C `dbMallocRawFinish` malloc.c:604..612, `dbReallocFinish` malloc.c:715..739, `sqlite3DbStrNDup` malloc.c:774..785), and `sqlite3OomFault` itself never propagated the fault to `db->pParse` (skipped the C malloc.c:834..842 walk that bumps `pParse->nErr` / `pParse->rc` along `pOuterParse`).  Net effect: a fault-injected OOM left `db->mallocFailed=0` *and* `pParse->nErr=0`, so codegen paths like `sqlite3FinishCoding` (build.c:267, codegen.pas:43177) reached `sqlite3VdbeMakeReady(NULL,…)` and segfaulted.  Fixed in `passqlite3util.pas` by mirroring the C `OomFault` post-condition in every db-malloc wrapper and porting the Parse-walk into `sqlite3OomFault`.  `tclsh /tmp/oom_probe.tcl` (do_malloc_test with -sqlbody `SELECT 1;`) now completes 94 sub-tests without SIGSEGV.

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
    - [ ] **10.1.42.b.7** Port the STAT4 cost-estimator helpers that
      gate the 4 deferred 10.1.42.b.1 arms: `whereRangeSkipScanEst`
      (where.c:2036), `whereEqualScanEst` (:2215 / :2313),
      `whereInScanEst` (:2363).  Each is a STAT4-driven planner helper
      not yet present in passqlite3codegen.pas.  Mask: 0x20 (verified
      against whereInt.h, NOT 0x10 as tasklist initially suggested).
      Treat as 3 independent micro-tasks; drop the WHERETRACE call at
      each host function as it lands.
      **BLOCKED 2026-05-13** on prerequisite **10.1.42.b.7.prereq** —
      the three helpers consume `sqlite3Stat4ProbeSetValue` (where.c:2002, 2169, 2306)
      and `sqlite3Stat4ValueFromExpr` (where.c:2006, 2186) which are
      unported in passqlite3.  Audit found zero references to either symbol
      in `src/*.pas`; only `sqlite3Stat4Column` (vdbe.pas:13356) and
      `sqlite3Stat4ProbeFree` (vdbe.pas:13409) exist as Phase-6 stubs.
      `SQLITE_ENABLE_STAT4` is not set in `src/passqlite3.inc` /
      `src/tests/build.sh`; pas-sqlite3 is a default non-STAT4 build.
    - [ ] **10.1.42.b.7.prereq** Port `sqlite3Stat4ProbeSetValue` and
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
    - [ ] **10.1.42.b.7.prereq.a** Record-shape + scaffolding.  Add
      `SQLITE_ENABLE_STAT4` to `src/passqlite3.inc` (default off) +
      `STAT4=1` arm to `src/tests/build.sh`.  Port the bare `IndexSample`
      record (analyze.c near :1660) and the 5 `Index2` STAT4 fields
      (`aSample`, `nSample`, `mxSample`, `nSampleCol`, `aAvgEq`), all
      `{$IFDEF SQLITE_ENABLE_STAT4}`-gated.  Audit `SizeOf(Index2)` /
      `FillChar(pIdx^, SizeOf...)` call sites (`sqlite3AllocateIndexObject`
      central).  Verify byte-identical default-build TestExplainParity +
      TestSQLCorpus.  ~250 LOC + audit.
    - [ ] **10.1.42.b.7.prereq.b** analyze.c STAT4 collection.  Port
      StatSample/StatAccum STAT4 fields, sampleClear / SetRowid×2 /
      Copy, sampleIsBetter, sampleInsert STAT4 branches, statInit STAT4
      alloc arm, statPush / statGet STAT4 branches, sqlite3DeleteIndexSamples
      real body, loadStat4 reader, analyzeOneTable STAT4 column wiring.
      ~900 LOC.  STAT4 build smoke: `STAT4=1 src/tests/build.sh` + ANALYZE
      on test table emits sqlite_stat4 rows.
    - [ ] **10.1.42.b.7.prereq.c** Consumers (rolls in 10.1.42.b.7
      itself).  Port vdbemem.c STAT4 layer (ValueNewStat4Ctx + valueNew +
      valueFromFunction + stat4ValueFromExpr + 2 publics + valueFromExpr
      STAT4 branches).  Replace `sqlite3Stat4ProbeFree` / `sqlite3Stat4Column`
      stubs with ported bodies.  Then port `whereKeyStats` + the 3
      estimators (`whereRangeSkipScanEst` / `whereEqualScanEst` /
      `whereInScanEst`) in `passqlite3codegen.pas`; drop the 4 WHERETRACE
      0x20 arms at the host sites.  ~950 LOC.
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
