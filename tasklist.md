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

> Closed-task postmortems live in git history.  This file keeps task IDs +
> one-line outcomes + key cites only.

## Phase 5 — carry-overs

- [X] **5.7.b** PMA disk-spill port COMPLETE
  - [X] **5.7.b.1** Sorter struct decls
  - [X] **5.7.b.2** Temp-file plumbing
  - [X] **5.7.b.3** `PmaWriter`
  - [X] **5.7.b.4** `PmaReader` read primitives
  - [X] **5.7.b.5** In-memory engine rebased 1:1 onto C
  - [X] **5.7.b.6** `MergeEngine` aTree[] tournament
  - [X] **5.7.b.7** Single-threaded `IncrMerger`
  - [X] **5.7.b.8** Tree build + merge setup
  - [X] **5.7.b.9** Public-API PMA arms wired
  - [X] **5.7.b.10** Verify

---

## Phase 6 — Code generators (close the EXPLAIN gate)

> TestExplainParity reports **1026 / 1026 PASS** as of 2026-05-06 (a3).

- [X] **6.8.0..6.8.6** Pragma vtab register, GenerateConstraintChecks
- [X] **6.8.1** sqlite3Update
- [X] **6.9** sqlite3VdbeRecordCompare / FindCompare full bodies in btree.pas
- [X] **6.24** Aggregate-with-ORDER-BY codegen
- [~] **6.26** Window functions (window.c). DiagWindow: 0 divergences. Reopen if DiagWindow regresses.
- [X] **6.27** schema-mutation + statistics
- [~] **6.28** sweep — re-search for "stub" in the pascal source code and port from C to pascal in full any function or procedure still marked as "stub" that was missed (catch-all). OP_Vacuum, BtreeIncrVacuum done; incrVacuumStep / relocatePage / modifyPagePointer not ported (gated on productive ptrmap). Inventory landed at `src/tests/STUB_INVENTORY.md` (21 actionable entries: 7 high / 6 med / 8 low). One small high-priority entry ported in 6.28 commit (`pas_openDirectory`, os_unix.c:3874..3894 → src/passqlite3os.pas:2331). Doable subtasks for the remaining six high-priority stubs (each cites the open Phase-6/9 bullet it blocks; see STUB_INVENTORY.md for full Pascal/C citations):
  - [X] **6.28.1** `whereLoopAddVirtual` deeper arms
  - [X] **6.28.2** `sqlite3OpenTableAndIndices` full body
  - [X] **6.28.3** `sqlite3NestedParse` body ported
  - [X] **6.28.4** `sqlite3AddColumn` drift arms
  - [X] **6.28.5** `sqlite3LimitWhere`
  - [X] **6.28.6** `OP_IntegrityCk` body + `sqlite3BtreeIntegrityCheck`
  - [X] **6.28.6.b** Higher-level `PRAGMA integrity_check` walk arms
  - [X] **6.28.6.a** PRAGMA integrity_check/quick_check wired to emit real
  - [X] **6.28.6.c** vtab xIntegrity dispatch
    - [~] **6.28.6.c.1** ~~FK referential walk~~ DROPPED 2026-05-13 — phantom cite (integrity_check carries no FK walk; PRAGMA foreign_key_check is separate). Archive.
    - [X] **6.28.6.c.2** vtab `xIntegrity` dispatch
  - [X] **6.28.7** `getRowTrigger` / `codeRowTrigger`
  - [X] **6.28.8** Audit pass on high-priority STUB_INVENTORY entries
  - [X] **6.28.9** Medium-priority audit pass
  - [X] **6.28.10** Low-priority audit pass

### Closed bugs (kept as ticked stubs)

- [X] **6.10** TestExplainParity closed
- [X] **6.11** PRAGMA page_count + DROP TABLE remaining gap closed
- [X] **6.12** sqlite3Pragma full port
- [X] **6.13** `pragma_foreign_key_list(s.name)`
- [X] **6.14** Compound `SELECT … FROM sqlite_schema … UNION ALL …`
- [X] **6.15** TestExplainParity transient regression
- [X] **6.16** Multi-vtab LEFT-JOIN + multi-aggregate AV
- [X] **6.17** OR-decomposed Case-5 codegen + LIKE/GLOB range-bound prefix
- [X] **6.18** pcachetrace / memtrace trampoline AV when sink is non-nil
- [X] **6.19** `.open --deserialize`
- [X] **6.20** Shim-VFS re-init chain corruption
- [X] **6.21** `-memtrace` silent
- [X] **6.22** Safe-mode error-prefix gap
- [X] **6.23** `sqlite3_open_v2` doesn't honor `file:` URI filenames
- [X] **6.29 / 6.29.followup** `sum(b) OVER
- [X] **6.30** unix VFS iVersion bumped to 3
- [X] **6.31** unix-VFS locking-style shims
- [X] **6.13.B.11** `.expert` `(no new indexes)`

### Open Bugs (re-opened 2026-05-11)

- [X] **6.32** DiagTxn savepoint-rollback hang

### 6.40 — Unported feature/extension gaps surfaced by Tcl sweep (2026-05-22)

> Each bullet is a Tcl `.test` failure whose *root cause is a missing ported
> feature*, not a runtime divergence. Counts are occurrences across the
> 2026-05-22 full-suite run (612 pass / 347 fail). "ENGINE" = real library
> feature to port; "EXT" = loadable/test extension to register; "HARNESS" =
> testfixture-only Tcl command. Port the C source 1:1 as usual; for HARNESS
> entries the C lives in `../sqlite3/src/test*.c` and is registered through the
> Tcl bridge (`src/tests/tcl/testmodules/`), not the engine.

- [~] **6.40.1** **FTS3/FTS4 full-text search** (ENGINE/EXT, XL; ~21 kLOC across `../sqlite3/ext/fts3/`). All of fts3.c/fts3_*.c ported into `src/passqlite3fts3.pas` and auto-registered from `sqlite3Fts3Init` at openDatabase (.a..o all DONE). fts3/fts4/fts4aux/fts3tokenize modules + fts3_tokenizer(_test) funcs + the fts3_test.c Tcl harness all live; the `fts3` capability is flipped on. Core FTS works (35 fts .test files PASS pas-strict + basic MATCH/phrase/NEAR/snippet/offsets/matchinfo/prefix/aux all green, oracle-diff'd). STAYS `[~]`: ~50 fts files remain pas-soft on three documented residual classes — (1) order=desc doclist hang/corruption (6.40.1.o.1), (2) heavy-segment-merge build perf timeouts (6.40.1.o.2), (3) assorted per-file edge cases (6.40.1.o.3). Reopen-to-strict as those residuals close.
  - **Cluster A — tokenizer subsystem (the easy wins; entirely independent of the 12 kLOC segment/vtab core).** Each item drives the `sqlite3_tokenizer_module` vtable directly, so each is unit-testable in isolation against the C oracle via a small `DiagFts3Tok` probe — no FTS vtab needed. Landing all of Cluster A flips the two biggest buckets: `fts3_tokenizer_test` (77) and `fts3tokenize` (2).
    - [X] **6.40.1.a** ABI skeleton landed in new unit
    - [X] **6.40.1.b** `fts3_hash.c` ported
    - [X] **6.40.1.c** `fts3_tokenizer1.c` 1:1
    - [X] **6.40.1.d** `fts3_porter.c` 1:1
    - [X] **6.40.1.e** `fts3_unicode2.c` ported verbatim
    - [X] **6.40.1.f** `fts3_unicode.c` "unicode61" tokenizer ported
    - [X] **6.40.1.g** fts3_tokenizer.c ported into passqlite3fts3.pas
    - [X] **6.40.1.h** `fts3_tokenize_vtab.c` ported into passqlite3fts3.pas
    - [X] **6.40.1.i** `fts3_expr.c` ported into passqlite3fts3.pas
    - [X] **6.40.1.j** `fts3_write.c`
    - [X] **6.40.1.k** fts3.c fts3/fts4 vtab module ported into
      - [X] **6.40.1.k.1** FTS4 key=value option parser ported
      - [X] **6.40.1.k.2** %_docsize/%_stat DDL in fts3CreateTables
      - [X] **6.40.1.k.3** FTS4 feature tests run under the cap flip
    - [X] **6.40.1.l** `fts3_snippet.c` ported into passqlite3fts3.pas
    - [X] **6.40.1.m** `fts3_aux.c` ported into passqlite3fts3.pas
    - [X] **6.40.1.n** `fts3_term.c` ported
    - [X] **6.40.1.o** Wiring + cap flip + sweep DONE
      - [X] **6.40.1.o.1** order=desc / docid-update doclist residual CLOSED
        - [X] **6.40.1.o.1.1** TestFts3DescUpdate.pas added
        - [X] **6.40.1.o.1.2** Reverse-poslist reader, not pending arm: final
        - [X] **6.40.1.o.1.3** Fixed `fts3ReversePoslist`
        - [X] **6.40.1.o.1.4** Promoted fts4docid + tkt-bdc6bbbb38 + orderby7
        - [X] **6.40.1.o.1.5** fts3aa-10.1 fixed → pas-strict
      - [X] **6.40.1.o.3** misc per-file FTS edge-case fails
        - [X] **6.40.1.o.3.1** corruption-detection: fts3corrupt +
        - [X] **6.40.1.o.3.2** fault-injection/OOM: all three demoted with
        - [X] **6.40.1.o.3.3** eval output: fts3snippet + fts3rank PASS
        - [X] **6.40.1.o.3.4** content/notindexed/external-content: all
        - [X] **6.40.1.o.3.5** DDL: fts3drop + fts3dropmod PASS
        - [X] **6.40.1.o.3.6** conflict/upsert + misc: all demoted with cause
        - [X] **6.40.1.o.3.7** fts3 acceptance-suite chunks
        - [X] **6.40.1.o.3.8** fts3shared
    - [X] **6.40.1.p** Replaced 5 libc externals in passqlite3fts3.pas with
    - [X] **6.40.1.p.2** DONE
      - [X] **6.40.1.p.2.1** `passqlite3util.pas`: removed
      - [X] **6.40.1.p.2.2** Removed `libc_strcmp`/`libc_atoi`
      - [X] **6.40.1.p.2.3** Removed strlenC/strcmpC/strncmpC/memcmpC
      - [X] **6.40.1.p.2.4** Removed strlenC/strcmpC/memcmpC externals
      - [X] **6.40.1.p.2.5** spellfix: strlen→StrLen
      - [X] **6.40.1.p.2.6** Replaced libc_qsort external with `fts3Qsort`
- [X] **6.40.2** ICU extension
- [X] **6.40.3** preupdate_hook
- [~] **6.40.4** Loadable extensions for `load_static_extension` — DONE: extended the existing aExtension[] table (TestModuleTest1.pas:581 tclLoadStaticExtensionCmd, mirrors test1.c:8406) from 11→23 names by wiring the already-ported sqlite3*Init shims: series/spellfix/closure/csv/fuzzer/prefixes/randomjson/appendvfs/amatch/nextchar/remember/unionvtab. All now load (was "no such extension"). prefixes/fuzzer1/fuzzer2/json108 now PASS; series/csv/spellfix/closure/randomjson/appendvfs load OK but tests still FAIL on deeper pre-existing engine bugs (tabfunc01 hangs at 1.7 4-arg series-arg rejection; join8 SIGSEGV at 9000; csv01/spellfix2/json106 deeper). All flagged tests were baseline-FAIL (errored on the first `load_static_extension` line), so no NEW pas-strict regression. DEFERRED: `echo` already works (register_echo_module, test8.c; swarmvtab2 PASS); `register_fs_module` (vtabH, test_fs.c 920L) + `register_schema_module` (test_schema.c 367L) are full vtab-module ports — not done.
- [X] **6.40.5** `sqlite3_prepare_v3` Tcl trampoline
- [~] **6.40.6** Crash/pager/IO harness cmds. DONE: `btree_pager_stats` (test3.c:147→TestModuleTest1; needed engine `sqlite3PagerStats` pager.c:6854 + `sqlite3PcacheGetCachesize` pcache.c:855 + new `Pager.nRead` field & PAGER_INCR at pager.c:3068); `sqlite3_pager_refcounts` (test1.c:6558); `pcache_stats` (test1.c:7573 + engine `sqlite3PcacheStats` pcache1.c:1261); `uses_stmt_journal` (test1.c:3060); `extra_schema_checks` (test1.c:7522); `file_control_powersafe_overwrite` (test1.c:7190); pure-Tcl `catchcmd`/`catchsafecmd`/`catchcmdex`/`dumpbytes` (tester.tcl:821-871) + `allcksum` (tester.tcl:2145) into tester_min.tcl. Results: cache.test 2→189 subtests (4 residual = pre-existing PRAGMA cache_size=0 readback bug), incrblob 12→7 err, pcache.test/fkey8.test PASS, ioerr2 now runs 3528 subtests (1 residual = unrelated dir-perms test). No NEW pas-strict regression (cache/incrblob were already baseline-FAIL stale-strict; both improved). DEFERRED: `crash_on_write` (test6.c:984 needs devsym VFS port, test_devsym.c); `btree_open` (test3.c:36 standalone Btree harness); `sqlite3_config_heap`/`mutex_counters`/`sorter_test_*`/`clock_seconds`/`isquick` (separate subsystems / low count).
- [X] **6.40.7** Snapshot Tcl trampolines NOT registered
- [X] **6.40.8** Misc test SQL fns: added test_setsubtype/test_getsubtype to
- [~] **6.40.9** WAL/blob harness cmds: ported blob_reopen, wal_checkpoint_v2, mmap_warm, interrupt, is_interrupted, utf8_to_utf8 + utf8To8Inplace (TestModuleTest1.pas; test1.c:1824/5984/6005/7685/8734, test_hexio.c:306). incrblob3 29→4 err, badutf2/mmapwarm cmds pass. quota_glob (test_quota.c VFS shim) DEFERRED — large.

> NOTE (2026-05-22): securedel.test failures are NOT an engine porting gap — the
> engine returns the correct `secure_delete` propagation when driven via the CLI;
> the residual `{1 0}` is a Tcl-bridge prepared-statement-caching interaction with
> codegen-time pragma side effects. Track separately if pursued.

---

## Phase 7 — Parser

- [X] **7.1.1** Schema initialisation
- [X] **7.1.2** sqlite3NestedParse full driver
- [X] **7.1.8** ATTACH / DETACH
- [X] **7.1.9** ALTER TABLE
- [X] **7.4b** TestBytecodeParity gate landed
- [X] **7.4c** TestVdbeTrace differential opcode-trace gate
- [X] **7.4d** WITHOUT ROWID runtime corruption
- [X] **7.4e** Bare-bareword INSERT → no-such-column error wired in resolver

---

## Phase 8 — Public API

Public-API gap analysis: `../sqlite3/src/sqlite.h.in` exports
~238 `sqlite3_*` symbols; the Pascal port currently exposes ~156.
Windows-only entry points (`sqlite3_win32_*`) and pure typedefs are excluded.

- [X] **8.4.1** sqlite3_test_control full varargs coverage
- [X] **8.2.1** sqlite3VdbeScanStatus + ScanStatusRange + ScanStatusCounters
- [X] **8.1.1** sqlite3_config / sqlite3_db_config full varargs coverage
- [X] **8.9.2** Carray / shared-cache / misc
- [X] **8.x** unixCurrentTimeInt64
- [X] **8.10** Public-API sample-program gate
- [X] **8.x.colneed** sqlite3_collation_needed callback fires
- [X] **8.x.memused** db^.pnBytesFreed dry-run accounting honoured

---

## Phase 9 — Acceptance: differential + fuzz

> **a4 session 2026-06-04 (pas-soft sweep):** Verified-and-FIXED — `reservebytes` 3→0
> (full `sqlite3BtreeSetPageSize` port incl. `nReserveWanted`, btree.c:3069..3100; 7b5c5e0);
> `shell2` 10→3 / `shell3` 1→0 (CLI: `.header` abbrev, case-insens on/off, `-safe` auth,
> hexdb `%x` parse; c39a82a — NOTE shell tests need `TESTFIXTURE_HOME=$(pwd)/bin` or
> runtest.sh measures /usr/bin/sqlite3); `corrupt2` 3→1 (dup-index schema via INITFLAG_FreshLoad
> + flipped-page-type seek leaving *pRes=0, btree.c:5945; cd9b1ca); `e_fkey` 10→4
> (INSERT…SELECT into parent must keep isMultiWrite so sqlite3FkLocateIndex runs, insert.c:1018;
> 583ecfc).  WATER-LEAKS (root-caused, reverted, do NOT re-pick as quick wins):
> `pushdown-6.x` needs IN-RHS subroutine-dedup/bloom machinery (deferred at codegen 74088);
> `pushdown-3.6`/`select9-4.5` flatten a compound view C keeps as CO-ROUTINE (affinity restriction-17h);
> `aggnested-10.1` needs NameContext `pNC->nRef` correlation accounting (port uses bespoke passes
> that don't descend into expr-subqueries); `update-21.12` flattens a windowed CTE (no auto-idx/bloom);
> `corruptN-6.3`/`corruptK-3.3` need deeper btree cell-overflow / cursor-save corruption checks.
> Many other pas-soft files now pass (joinC, windowE, collate4, count, etc.) — tasklist notes stale.

Each 9.x lands a self-contained gate.  All four use the same C oracle:
`libsqlite3.so` from `../sqlite3/` (already built by `src/tests/build.sh`).
Pascal output → C output diff is the only pass criterion; any deviation
is a port bug (see top of file).  All gates must run unattended under
`src/tests/build.sh` and exit non-zero on first divergence so CI catches
regressions without human triage.

### 9.1 `TestSQLCorpus.pas` — full SQL corpus differential

- [X] **9.1.1** Corpus inventory

- [X] **9.1.2** Oracle runner helper

- [~] **9.1.3** `TestSQLCorpus.pas` skeleton — iterate MANIFEST, run both oracles, byte-compare all four channels; first diverging file prints summary and exits non-zero. Gate: `bin/TestSQLCorpus` rc=0. Skeleton landed 2026-05-12; full coverage delivered by 9.1.3.followup.

- [X] **9.1.3.followup** Full MANIFEST coverage via `SQLLiteralExtractor.pas`

- [X] **9.1.4** Determinism scrub
  - [X] **9.1.divbug.1** RELEASE-without-SAVEPOINT errmsg
  - [X] **9.1.divbug.2** PRAGMA mmap_size / journal_mode output shape
  - [X] **9.1.divbug.3** DROP INDEX errmsg truncation
  - [X] **9.1.divbug.4..8** Five sites, single root cause

- [X] **9.1.5** Corpus status tags landed in `src/tests/corpus/STATUS.txt`

- [X] **9.1.6** Coverage check

### 9.2 `TestReferenceVectors.pas` — canonical `.db` snapshots

- [X] **9.2.1** Vector inventory

- [~] **9.2.2** Read-only parity probe — `bin/TestVectorReadOnly` + per-vector `*.queries.sql` (11 vectors). Bucket-A FIXED in 9.2.divbug.A (btreeBeginTrans wrflag gate); the unioned pas-skip list now covers bucket-F (autovacuum/incrvacuum), bucket-G (utf16), bucket-H (withoutrowid), bucket-I (wal/multipage/generated-column round-trip drift) and bucket-J (triggers round-trip crash) plus bucket-C/E for view-cte/partial-index — but those buckets affect 9.2.3/9.2.4 only.  RO probe today: gated=1 ok=1 diverged=0 skipped=10 rc=0; the actual fix lifted SQLITE_READONLY for every vector and the remaining skips are pre-existing non-RO bugs surfaced after bucket-A was lifted.

- [~] **9.2.3** Round-trip probe — `bin/TestVectorRoundTrip` + per-vector `<name>.mutate.sql` (11 mutators each exercising the vector's feature). Re-uses `CorpusOracle.ApplyHeaderMask`. Today (post-9.2.3.followup, cite-aware RT filter): gated=8 ok=8 diverged=0 skipped=3 rc=0.  Remaining skips: autovacuum (bucket-L, also bucket-B for schema-change), incrvacuum (bucket-L), utf16 (bucket-M, also bucket-K for RO).  Bucket-A umbrella lifted; bucket-I (4-vector RT cell-layout drift) closed; bucket-J (triggers RT crash) closed.

- [~] **9.2.4** Schema-change probe — `bin/TestVectorSchemaChange` + per-vector `<name>.schema.sql` (8 vectors). Opens RW so does NOT inherit bucket-A; surfaced 4 new buckets (B/C/D/E — see 9.2.divbug.* below). 9.2.divbug.C closed (view-cte rename arm), 9.2.divbug.E closed (partial-index RENAME COLUMN aColExpr pin), but both view-cte and partial-index still hit bucket-B at the trailing VACUUM so they stay pas-skip. Today: gated=1 ok=1 diverged=0 skipped=7 rc=0.

- [X] **9.2.5** Vector regen script
  - [X] **9.2.divbug.A** RO-open trips `SQLITE_READONLY`
  - [X] **9.2.divbug.F** PRAGMA auto_vacuum returns 0 on RO-open
  - [X] **9.2.divbug.G** PRAGMA encoding garbled on UTF-16 RO
  - [X] **9.2.divbug.H** WITHOUT ROWID count(*) fast path → CORRUPT
  - [X] **9.2.divbug.I** Round-trip cell-layout drift
  - [X] **9.2.divbug.J** Round-trip trigger-fire EAV
  - [X] **9.2.divbug.B** Bare `VACUUM;` EAccessViolation
  - [X] **9.2.divbug.C** ALTER TABLE RENAME on VIEW-dependent table → EAV
  - [X] **9.2.divbug.D** CREATE INDEX on WITHOUT ROWID byte-different
  - [X] **9.2.divbug.E** RENAME COLUMN on partial-index byte-different
  - [X] **9.2.divbug.K** UTF-16 `hex()` byte-swapped
  - [X] **9.2.divbug.L** Auto-vacuum round-trip page-count drift
  - [X] **9.2.divbug.L.1** Port `incrVacuumStep`
  - [X] **9.2.divbug.L.2** Port `relocatePage` + `modifyPagePointer`
  - [X] **9.2.divbug.L.3** Wire `autoVacuumCommit` body
  - [X] **9.2.divbug.M** ~~UTF-16 INSERT raw-UTF-8~~ CLOSED
  - [X] **9.2.divbug.N** ~~Freeblock zeroing~~ CLOSED

- [X] **9.2.3.followup** Round-trip parser cite-aware

- [X] **9.1.6.followup** Categorize 47 cold opcodes

### 9.3 `TestFuzzDiff.pas` — differential fuzzer

- [X] **9.3.1** In-process harness

- [X] **9.3.2** Seed corpus import

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

- [X] **9.4.1** Inventory
  - [X] **9.4.1.a** Inventory script `src/tests/tcl/inventory.sh`

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
  - [X] **9.4.2.0** Plan doc `src/tests/tcl/PLAN.md`
  - [X] **9.4.2.a** Bridge unit
  - [X] **9.4.2.b** `Sqlite3_Init` exporter
  - [X] **9.4.2.c** `sqlite3 db1 :memory:` constructor
  - [X] **9.4.2.d** `db eval $sql`
  - [X] **9.4.2.e** `db version` / `changes` / `last_insert_rowid`
  - [X] **9.4.2.f** `db function NAME ?-argcount N? proc`
  - [~] **9.4.2.g** `tester_min.tcl` — `src/tests/tcl/tester_min.tcl`
    re-exports just `do_test`, `do_execsql_test`, `execsql`,
    `expected`, `set_test_counter`, `finalize_testing`, and the global
    `db` handle — enough to source a hand-picked simple `.test` file.
    Body adapted from `../sqlite3/test/tester.tcl:703..` and `941..`.
    Smoke gate `bin/TestTclTesterMin` sources tester_min.tcl + runs
    `do_test foo-1.0 {expr 1+1} 2`.  Remaining helpers tracked in
    9.4.2.g.1.
  - [X] **9.4.2.g.1** `ifcapable`
  - [X] **9.4.2.g.2** `catchsql` + `do_catchsql_test`
  - [X] **9.4.2.g.3** `finish_test` + `forcedelete` + `delete_file`
  - [X] **9.4.2.g.4** `integrity_check`
  - [X] **9.4.2.g.5** `working_64bit_int` + `presql` + `omit_test`
  - [X] **9.4.2.g.6** `do_eqp_test`
  - [X] **9.4.2.g.7** `do_test` glob/regexp/numeric-range forms +
  - [X] **9.4.2.g.8** `permutations.tcl` skip-shim
  - [X] **9.4.2.g.9** `do_malloc_test` ported verbatim into `tester_min.tcl`
  - [X] **9.4.2.g.10** `do_ioerr_test` + `run_ioerr_prep` ported verbatim into
  - [X] **9.4.2.g.11** `crashsql` Tcl proc
  - [X] **9.4.2.g.12** `db_save_and_close` / `db_restore_and_reopen` +
  - [X] **9.4.2.g.13** `*_common.tcl` source-include shims
  - [X] **9.4.2.g.14** `tester_min.tcl` config vars
  - [X] **9.4.2.h** `db eval` 3-arg form
  - [X] **9.4.2.i** `db trace` / `db trace_v2` / `db profile`
  - [X] **9.4.2.j** `db authorizer`
  - [X] **9.4.2.k** `db busy` + `db progress` + `db interrupt`
  - [X] **9.4.2.l** `db update_hook` / `db commit_hook` / `db rollback_hook`
  - [X] **9.4.2.m** `db collate` + `db collation_needed`
  - [X] **9.4.2.n** `db transaction { script }`
  - [X] **9.4.2.o** `db total_changes` / `db onecolumn
  - [X] **9.4.2.p** `db incrblob`
  - [X] **9.4.2.q** `db backup` / `db restore`
  - [X] **9.4.2.r** `db serialize` / `db deserialize`
  - [X] **9.4.2.s** `db function` enhancements: `-returntype`, `-directonly`
  - [X] **9.4.2.s.1** `DbSqlFunc` script-body forms
  - [X] **9.4.2.t** `db nullvalue` follow-ups + `db errorcode` extended-code
  - [X] **9.4.2.u** `db preupdate_hook`
  - [X] **9.4.2.u.1** Runtime-exercise the preupdate hook
  - [X] **9.4.2.v** `db unlock_notify`
  - [X] **9.4.2.w** Bridge symbol-table audit
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
    - [X] **9.4.2.x.1.a** Port `SqlPreparedStmt` cache + `DbPrepareAndBind`
    - [X] **9.4.2.x.1.b** Port `AddDatabaseRef` / `DelDatabaseRef`
    - [X] **9.4.2.x.1.c** `TDbEvalContext` record
    - [X] **9.4.2.x.1.d** Implement `DbEvalNextCmd: TTclNRPostProc`
    - [X] **9.4.2.x.1.e** Closed 2026-06-05

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
  - [X] **9.4.3.a** Driver skeleton `src/tests/TclTestDriver.pas`
  - [X] **9.4.3.b** Fix the driver polling race
  - [X] **9.4.3.c** Per-test `testdir` wiring

- [~] **9.4.4** Skip-list curation.  Tests that depend on
  `sqlite3_test_control`, `PRAGMA legacy_*`, or other internal
  knobs land in `src/tests/tcl/SKIP.md` with a citation to the
  Phase 6/7/8 bullet that gates them.  Empty skip-list is the
  long-term goal; closed bullets prune entries here.
  - [X] **9.4.4.a** First 10-test sweep
  - [X] **9.4.4.b** Re-ran 10-test sweep after g.1..g.5 + g.7 + divbug.6
  - [X] **9.4.4.b.2** Re-sweep of the first 10 tests after the 2026-05-14 wave
  - [X] **9.4.4.c** Broaden sweep to first 50 tcl-feature tests
  - [X] **9.4.4.d** Broaden sweep to first 100 tcl-feature tests
  - [X] **9.4.4.e** Broaden sweep to 250 tests
  - [X] **9.4.4.f** Broaden sweep to 500 tests
  - [X] **9.4.4.g** Full tcl-feature sweep
  - [X] **9.4.4.h** tcl-internal re-evaluation

- [X] **9.4.5** Linux-only nightly
  - [X] **9.4.5.a** CI config
  - [X] **9.4.5.b** Sharding
  - [X] **9.4.5.c** Failure-report artefact

- [~] **9.4.6** Test-only public-API export delta.  Many `.test`
  files call into the C ABI beyond the "publicly documented" subset.
  Each bullet here adds the engine port + Tcl shim required by some
  number of `.test` files.  Audit current `src/*.pas` first — many
  of these already exist with partial coverage.
  - [X] **9.4.6.a** `sqlite3_compileoption_used` / `sqlite3_compileoption_get`
  - [X] **9.4.6.b** `register_dbstat_vtab`
  - [X] **9.4.6.c** `sqlite3_db_status` / `sqlite3_stmt_status`
  - [X] **9.4.6.d** `sqlite3_table_column_metadata`
  - [X] **9.4.6.e** `sqlite3_set_authorizer`
  - [X] **9.4.6.f** `sqlite3_create_collation` / `sqlite3_create_collation_v2`
  - [X] **9.4.6.g** `sqlite3_blob_open` / `_read` / `_write` / `_close`
  - [X] **9.4.6.h** `sqlite3_soft_heap_limit64` / `sqlite3_hard_heap_limit64`
  - [X] **9.4.6.i** `sqlite3_user_data` / `sqlite3_aggregate_context`
  - [X] **9.4.6.j** `sqlite3_extended_result_codes`
  - [X] **9.4.6.k** `sqlite3_unlock_notify`
  - [~] **9.4.6.l** Test-only modules — landed as
    `src/tests/tcl/testmodules/` unit per file.
    Done: `register_tcl_module` (test_tclvar.c → `TestModuleTclvar.pas`),
    `Md5_Register` + md5/md5file Tcl cmds (test_md5.c →
    `TestModuleMd5.pas`).  `register_wholenumber_module` already
    done in 10.1.69.  Remaining sub-tasks below.
    - [X] **9.4.6.l.1** `register_echo_module`
    - [X] **9.4.6.l.4** `registerTestFunction`
    - [X] **9.4.6.l.5** `register_async_vtab`
  - [X] **9.4.6.m** `sqlite3_log`
  - [X] **9.4.6.n** `sqlite3_memdebug_*`
  - [X] **9.4.6.o** File-control opcodes
  - [X] **9.4.6.p** `sqlite3_busy_timeout` / `sqlite3_busy_handler`
  - [X] **9.4.6.q** Unported test-only Tcl commands
    - [X] **9.4.6.q.1** test1.c prepared-statement C-API subset
    - [X] **9.4.6.q.2** Remaining 9.4.4.d-surfaced test commands
  - [X] **9.4.6.r** Faithful `fcntlSizeHint` port

- [~] **9.4.7** Build-matrix / harness infrastructure.  Many tests
  require a *different* build of libpassqlite3 than the default.
  Each profile lives as its own `bin/libpassqlite3tcl-<profile>.so`
  and the driver picks one via `--build`.
  - [X] **9.4.7.a** Compile-flag introspection finishing
  - [X] **9.4.7.b** Memdebug build profile
  - [X] **9.4.7.c** I/O-error injection
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
  - [X] **9.4.7.f** Per-test isolation
  - [X] **9.4.7.g** Driver concurrency
  - [X] **9.4.7.h** `tclsqlite3_Init` package-config
  - [X] **9.4.7.i** Threading build

- [~] **9.4.8** Full-corpus parity gate.
  - [X] **9.4.8.a** Per-test status tags
  - [X] **9.4.8.b** STATUS.txt seeded from current sweeps
  - [X] **9.4.8.c** Strict gate
  - [X] **9.4.8.d** Coverage check
  - [X] **9.4.8.e** Regression archive

#### 9.4 divergence buckets (cite `src/tests/tcl/DIVERGENCES.md`)

- [X] **9.4.divbug.1** `select1.test select1-4.4`
- [X] **9.4.divbug.2** SQL error messages drop their format-arg tails
- [X] **9.4.divbug.3** Schema introspection result columns reordered / missing
- [X] **9.4.divbug.4** `update.test` sub-test `update-10.1` reported spurious
- [X] **9.4.divbug.5** `numcast.test` 0/51 → 51/51 Ok
- [X] **9.4.divbug.6** Doubled error string in `db1 eval`'s error return
- [X] **9.4.divbug.7** `insert.test` hangs
- [X] **9.4.divbug.8** `index.test` segfaults at `index-3.3`
- [X] **9.4.divbug.9** `lastinsert.test` segfaults right after
- [X] **9.4.divbug.10** `boundary1.test` SELECTs returned `{}`
- [X] **9.4.divbug.11** Compound
- [X] **9.4.divbug.12** `update-17.10` segfault
- [X] **9.4.divbug.13** Inequality-scan row ordering
- [X] **9.4.divbug.14** SQL errors drop object name
- [X] **9.4.divbug.15** `no such function` not raised at prepare
- [X] **9.4.divbug.16** `affinity3.test` segfault
- [X] **9.4.divbug.17** Subquery-nested aggregate evaluated row-wise
- [X] **9.4.divbug.18** WITHOUT ROWID vtab `xUpdate`
- [ ] **9.4.divbug.19** Table-qualified `rowid` alias (`t1.rowid`, `sp.rowid`) — ported the qualified-case rowid arm from lookupName (resolve.c:471..503 + 623..638) into the TK_DOT branch of `ResolveExpr`: when `sqlite3ColumnIndex` misses and `zCol` ∈ {rowid,oid,_rowid_} and the matched source `HasRowid`, bind `iColumn=-1` / AFF_INTEGER.  Cites: 3fd04ef.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. autoindex5).  Triage 2026-05-16: autoindex5-1.1 needs `SEARCH debian_cve USING AUTOMATIC COVERING INDEX (bug_name=?)` but Pas emits a flat `SCAN debian_cve` with an unopened cursor (Rewind p1=3 with no preceding OpenRead) — view materialisation as co-routine inside a correlated subquery is not wired and `constructAutomaticIndex` Asserts out on the viaCoroutine arm (codegen.pas:20830).  Out-of-scope for this pass; needs porting where.c:1191..1234 viaCoroutine arm + EQP CO-ROUTINE emission + the SrcItem.viaCoroutine set on materialised views.  Triage 2026-05-17 (agent): tests 1.0, 1.1, 2.1 now actually PASS (likely fixed transitively by other divbug commits); the SIGSEGV-causing block is test 2.2 (`SELECT (SELECT aaa FROM t1 GROUP BY (SELECT bbb FROM (SELECT ccc AS bbb FROM (SELECT 1 ccc) WHERE rowid IS NOT 1) WHERE bbb=1))`).  Root cause is architectural, not the constructAutomaticIndex assert: the C oracle EXPLAIN shows a CO-ROUTINE feeding an AUTOMATIC PARTIAL COVERING INDEX (subquery-1)(ccc=?), but Pas emits a flat SCAN over an unopened cursor 2 → Rewind p1=2 segfaults at run time (codegen.pas:32228 FROM-coroutine arm and codegen.pas:32520 materialise arm both gate on pDest^.eDest ∈ {SRT_Output, SRT_EphemTab, SRT_Coroutine}; scalar subqueries use SRT_Mem so neither arm fires for FROM-subqueries embedded inside a scalar-subquery WHERE clause).  C does FROM-subquery codegen up front in `selectExpander` (select.c:7945..8120) regardless of outer eDest; Pas does it lazily inline and so misses SRT_Mem.  Sub-tasks needed:  (a) port the up-front FROM-subquery generation loop from select.c:7945..8120 into the Pas `sqlite3Select` prologue (so coroutine + addrFillSub get populated before any eDest gate); (b) port the viaCoroutine arm of `constructAutomaticIndex` (where.c:1191..1234) — currently a hard Assert at codegen.pas:21420; (c) wire `EXPLAIN QUERY PLAN BLOOM FILTER ON %!S (col=?)` banner emission inside `constructAutomaticIndex` (where.c:1183..1187 + the explain helper); none of which is doable inside a single safe pass.  Leaving code untouched.
- [X] **9.4.divbug.20** BETWEEN-on-indexed-column planner
- [X] **9.4.divbug.21** Cross-connection EXCLUSIVE lock detection +
- [ ] **9.4.divbug.22** Large row / `PRAGMA page_size=65536` overflow — two fixes: `fillInCell` overflow-path nil-pBt deref (`45a1fbb`) and `accessPayload` passing `Ord(eOp=0)=1` as pager flag colliding with `PAGER_GET_NOCONTENT` (`9744b0f`).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. bigrow, btree01); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.23** Correlated FROM-subquery EQP shape
- [ ] **9.4.divbug.24** `sqlite_sequence` double-created for AUTOINCREMENT — ported build.c:2967..2972 (pin `pSchema^.pSeqTab` when init.busy adds a table named `sqlite_sequence`) at codegen.pas:40916.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. aggnested); reopened per failing-pas-soft-with-closed-cite rule.  Investigation 2026-05-16 (agent5): aggnested fail is NOT a sequence/AUTOINCREMENT residual — it is a SIGSEGV that hits between aggnested-2.0 and aggnested-3.0 on the `db2 close` at aggnested.test:70.  Minimal repro (no AUTOINCREMENT involved):  open `db` on test.db with 3+ rows feeding a correlated `SELECT (SELECT group_concat(a1) FROM u2) FROM u1`, then open separate `db2 :memory:` with PRIMARY KEY tables, run any SELECT in db2, call `db2 close` → crash.  Requires (a) ≥2 outer rows in the db1 correlated subquery, (b) group_concat or string_agg in the inner agg (sum / count are fine), (c) db2 must have at least one PRIMARY KEY table (without the PRIMARY KEY no crash).  Crash is on `db2 close` even though group_concat ran in db1.  TGroupConcatCtx (codegen.pas:54840) contains no managed Pascal types so the "New() on record with AnsiString" trap (MEMORY.md) is not the cause.  Likely a function-context / aggregate-context residue on the shared db schema that gets re-entered during cross-DB close.  Needs valgrind / address-sanitizer.
- [X] **9.4.divbug.24.b** aggnested-3.3 wrong scalar-subquery value +
- [X] **9.4.divbug.24.b.4** aggnested-3.11 "misuse of aggregate: max()"
- [X] **9.4.divbug.25** `update-19.10
- [X] **9.4.divbug.26** Echo vtab INSERT fails
- [X] **9.4.divbug.27** Engine OOM-recovery path segfaults under an injected
- [X] **9.4.divbug.28** EXPLAIN QUERY PLAN segfaults on multi-table queries
- [ ] **9.4.divbug.41** EQP detail-text omits LAST-N-TERMS-OF when nOBSat>0 (eqp2/cost/fordelete/delete2).  Fixed at codegen.pas:31663 by porting select.c:1702..1711 nOBSat/nKey branch (LAST TERM OF / LAST n TERMS OF / plain ORDER BY).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. cost, fordelete); reopened per failing-pas-soft-with-closed-cite rule.  Triage 2026-05-17 (agent): residual failures are NOT EQP detail-text issues — they are out-of-scope per the divbug.41 cite.  cost.test residuals are planner-cost / index-selection divergences: cost-3.2/6.2/7.2 expect a `MULTI-INDEX OR` shape (two-arm OR-to-IN-set planner re-write) that the Pas where.c equivalent never emits; cost-4.3/9.3.x.2 pick the wrong covering index (i1 a=? vs i2 b-range) — cost-estimator delta in `whereLoopAddBtreeIndex` / `estLog` rather than text rendering.  cost-8.2 expects `USE TEMP B-TREE FOR DISTINCT` which is a separate distinct-eph arm.  fordelete.test residuals are about OPFLAG_FORDELETE placement on OP_OpenWrite p5 (asterisk should land on the table cursor, not the autoindex) and the rowid-delete `+` marker on OP_Delete p5 — i.e. delete.c sqlite3GenerateRowIndexDelete / OPFLAG_FORDELETE propagation through sqlite3OpenTableAndIndices, not EQP rendering at all.  fordelete-3.x also requires the `btree_cursor` Tcl test command (testfixture-only; not registered in libpassqlite3tcl).  Per task step 6 (planner-choice → annotate, don't touch cost logic), leaving the .41 detail-text fix in place and NOT modifying planner cost or OPFLAG_FORDELETE codegen in this pass.  Should be re-bucketed: cost residuals → new "MULTI-INDEX OR planner shape" + "covering-index cost-estimator delta" bullets; fordelete residuals → new "OPFLAG_FORDELETE p5 propagation" bullet; btree_cursor → divbug.91 (Tcl harness helpers).
- [X] **9.4.divbug.29** TEXT-affinity column stores `'0x119'` literal as
- [ ] **9.4.divbug.30** ORDER BY with non-default collation (NOCASE) mis-orders.  Residual 2026-05-16: 3 pas-soft test(s) still fail (e.g. collate4, collate8); reopened per failing-pas-soft-with-closed-cite rule.  Progress 2026-05-16 (agent5): collate8.test now PASS (23/23) and collate4 advances past 6.1/6.2 (sort-vs-nosort).  Three Pas-level resolver/planner bugs ported from resolve.c + where.c:  (a) `sqlite3CreateColumnExpr` IPK aliasing missing in both expandStar (codegen.pas:25942..25956) and bare-TK_ID lookupName arm (codegen.pas:9977..9998); both now set iColumn=-1 when matchCol==iPKey so wherePathSatisfiesOrderBy can match ORDER BY <ipk> against XN_ROWID (resolve.c:863..887).  (b) NC_UEList alias fallback for ORDER BY (resolve.c:658..698) was only invoked for bare TK_ID via ResolveAsName; expressions like `ORDER BY +x` referencing AS-alias never resolved.  Reuse ResolveAliasInHaving walker on each pOrderBy item where iOrderByCol=0 (codegen.pas:11142..11156).  (c) whereShortCut's Pas-only full-table-scan fallback (codegen.pas:20533..20593) bypasses wherePathSolver entirely, so ORDER BY on a plain SCAN was forced through an external sorter; gate the fallback off when caller passed pOrderBy / WHERE_GROUPBY / WHERE_DISTINCTBY / WHERE_WANT_DISTINCT (matches C whereShortCut at where.c:6350..6417 which only succeeds on WHERE_ONEROW).  Net: 5190/9 (was 5180/18) in build.sh regression.  Residual collate4 failures (2.1.7/2.1.8 NOCASE index for IN-list; 4.3 min(a)/max(a) using TEXT index; 4.10/4.13/4.14 scalar max(b,a) collation) are distinct collation-propagation bugs not addressed here.  Progress 2026-05-18 (agent): 2.1.7/2.1.8 plan now matches C reference (SEARCH ... USING COVERING INDEX collate4i1 (a=?)).  Root cause was two stubs in codegen.pas — sqlite3IndexAffinityOk and indexInAffinityOk — that returned 1 / nil unconditionally; whereScanNext's WO_IN arm therefore rejected every IN term and the planner fell back to full SCAN.  Ported expr.c:387..396 and where.c:319..344 (plus comparisonAffinity helper, expr.c:364..379) 1:1.  TestWherePlanner TC1/TC3b fixtures updated to attach a real pTab so the now-real comparisonAffinity can resolve column affinity.  Collate4 file still FAILs on residual 4.x cases; collate1/collate7 untouched.  Progress 2026-05-18 (agent): 4.10/4.13/4.14 (scalar `max(b,a)` / `max('101',b)` collation) fixed by two coordinated edits: (1) emitScalarFunctionCall (codegen.pas:5594..5615) now mirrors expr.c:5375..5382 and collects pColl from the first arg with a non-default `sqlite3ExprCollSeq` rather than hard-coding `db^.pDfltColl` — drives the correct OP_CollSeq P4; (2) minmaxScalarFunc (codegen.pas:56652..56685) ports func.c:27..34 `sqlite3GetFuncCollSeq` to read `pCtx^.pVdbe^.aOp[iOp-1].p4.pColl` and pass it to `sqlite3MemCompare` instead of nil.  Residual 4.3 (`min(a)`/`max(a)` using TEXT index, expects search_count=1 but gets 3): root cause is BIGNULL ordering refused by Pas wherePathSatisfiesOrderBy (codegen.pas:19899..19913 explicit `isMatch:=0` per divbug.43).  `min(a)` triggers BIGNULL because `sqlite3ExprCanBeNull` returns true; index can no longer satisfy ORDER BY so bOrderedInnerLoop=0 and sqlite3WhereMinMaxOptEarlyOut bails before emitting the early-out OP_Goto.  Fix requires porting the BIGNULL two-pass scan emitter (wherecode.c:1933..2164 + where.c:7616..7620 regBignull/addrBignull) — non-trivial.  `max(a)` (4.4) is unaffected since BIGNULL is not set there.
- [ ] **9.4.divbug.31** Spurious `database disk image is malformed` for non-corrupt errors (collate3 `no such collation sequence: …`, count-1.2.4/5).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. collate3, count); reopened per failing-pas-soft-with-closed-cite rule.  Triage 2026-05-17 (agent): collate3.test now PASSES 72/72 (resolved transitively).  count.test failure is NOT spurious tagging — the "malformed" error is REAL: with `PRAGMA page_size=1024` (the SQLITE_TEST default), as soon as the table grows past ~32k rows of 2-int payload the next `INSERT INTO t1 SELECT * FROM t1` (or any walk: count(*), count(a)) trips `SQLITE_CORRUPT_BKPT` in the btree.  Confirmed with stock /usr/bin/sqlite3 succeeding on identical input.  Test minimised: `CREATE TABLE t1(a,b); INSERT VALUES(1,2),(3,4); for i in 0..13: INSERT INTO t1 SELECT * FROM t1` — succeeds through 16384 rows, errors at 32768.  Disappears with `PRAGMA page_size=4096`.  Triggers on the 3rd or 4th level of the b-tree at 1024-byte pages; max(rowid) still works (backward seek) while forward walks fail.  This is a genuine b-tree balancing / page-split bug, not a vdbe rc-mistagging issue.  Out of scope for a single safe pass; likely related to divbug.22 (bigrow/page_size=65536 cluster).  Needs a balance_nonroot or split-overflow audit at passqlite3btree.pas.  Leaving code untouched.
- [X] **9.4.divbug.32** Readonly-DB DELETE returns `unknown error` instead of
- [X] **9.4.divbug.33** `count(DISTINCT …)` returns 1 instead of 0 for an
- [X] **9.4.divbug.34** `PRAGMA page_size` reports build default
- [X] **9.4.divbug.35** Float-to-text precision artefacts: `-1.11` →
- [X] **9.4.divbug.36** `PRAGMA journal_mode=off` silently ignored
- [X] **9.4.divbug.37** WAL `wal_hook` callback reports 0 frames where
- [X] **9.4.divbug.38.a** Malformed `REFERENCES … ON` parser error message
- [X] **9.4.divbug.38.b** FK-cascade picks wrong target row
- [X] **9.4.divbug.39** `CREATE TABLE AS SELECT`
- [X] **9.4.divbug.40** `DEFAULT` clause: error text drops column-name
- [X] **9.4.divbug.42** Mis-triaged: root was an engine SIGSEGV on
- [X] **9.4.divbug.43** `ORDER BY
- [X] **9.4.divbug.44** Misclassified cluster
- [X] **9.4.divbug.45** `HAVING` with non-aggregate predicate over-filters
- [X] **9.4.divbug.46** `LIMIT N` combined with subquery / DESC clamps wrong
- [X] **9.4.divbug.47** Numeric `_` digit-separator literals not parsed
- [X] **9.4.divbug.48** Hex-literal overflow detection: error text drops the
- [X] **9.4.divbug.49** Generated-column
- [X] **9.4.divbug.50** JSON output float formatting: integer-valued JSON
- [X] **9.4.divbug.51** JSON error-message text divergences
- [X] **9.4.divbug.52** JSON `subtype()` / `sqlite_subtype()` function
- [X] **9.4.divbug.53** Parser error reports `near token: syntax error`
- [X] **9.4.divbug.54** ORDER BY DESC + LIMIT+OFFSET on a partially-satisfied
- [X] **9.4.divbug.55** EQP detail-string divergences
- [X] **9.4.divbug.56** Default `LIKE` collation matches both cases when
- [X] **9.4.divbug.57** `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)` not
- [X] **9.4.divbug.58** `CREATE INDEX …
- [X] **9.4.divbug.59** JOIN USING/NATURAL: prefix-qualified column reference
- [X] **9.4.divbug.60** Tcl bridge coerces integer values bound through
- [X] **9.4.divbug.61** Harness gap: `fts3_common.tcl` not staged in
- [X] **9.4.divbug.62** test1.c `sqlite3_*` Tcl trampolines
  - [X] **9.4.divbug.62.a** `sqlite3_mprintf_*` family
  - [X] **9.4.divbug.62.b** Statement-level introspection
  - [X] **9.4.divbug.62.c** Binding API
  - [X] **9.4.divbug.62.d** Resource accounting: `sqlite3_status`
  - [X] **9.4.divbug.62.e** Function/extension management
  - [X] **9.4.divbug.62.f** Config & legacy: `sqlite3_config_pmasz`
- [X] **9.4.divbug.63** tcl-shim helper cmds
- [X] **9.4.divbug.63.sweep** Full live-driver bridge sweep
- [X] **9.4.divbug.64** `db func` and `db format` subcommands unported
- [X] **9.4.divbug.65** Tester Tcl globals `::DB` / `::STMT`
- [X] **9.4.divbug.66** SQL functions/extensions unregistered
  - [X] **9.4.divbug.66.a** Register `randstr(N,M)` from test_func.c:40 +
- [X] **9.4.divbug.67** `stmtrand` SQL extension unported
- [ ] **9.4.divbug.68** `PRAGMA module_list` does not include `fts5` row — pragma5-2.1 expects `[fts5]` got `[]`.  Cite: pragma.c PragTyp_MODULE_LIST + virtual-table module registration of fts5.  Surfaced 9.4.4.g.  Triage 2026-05-16: `PragTyp_MODULE_LIST` handler itself is correct (codegen.pas:51139..51148 walks `db^.aModule` HASH; pas currently emits 23 modules incl. dbstat, sqlite_dbpage, generate_series, json_each, json_tree, sqlite_stmt, fsdir, completion, zipfile, etc. — strictly more than the C oracle's 16 in this build).  The pragma5-2.1 case is gated by `ifcapable fts5` (pragma5.test:49), so the only real gap is the unported fts5 module itself — see sub-task .68.a.  Do not flip [X] until .68.a lands.
  - [ ] **9.4.divbug.68.a** Port fts5 vtab module (ext/fts5/*.c) — blocker for `PRAGMA module_list` containing `fts5`.  XL.
- [X] **9.4.divbug.69** `PRAGMA temp.<header_value>` SIGSEGV
- [ ] **9.4.divbug.70** Error-text divergences (parser/resolver hints) — partial progress 2026-05-17.  Originally-cited string-tweak hints (parser1, tokenize, quote-2.1.x, select1-2.20..23, tableopts, strict1, select1-4.10.2, tkt3508, tkt3935.5/7) all verified `PASS` post earlier commits 1a0629b / d04edb5.  This pass ports `areDoubleQuotedStringsEnabled` (resolve.c:161..172) into `flagUnresolvedTKID` (codegen.pas:8683..8745) so the bare-TK_ID error path mirrors C's DDL-context formula (`writable_schema && DqsDML`) or `DqsDDL` bit before emitting the "no such column" hint; landed quote-2.2 + quote-3.0/3.1/3.2/3.3/3.4/3.5 (previously failing).  Residual 2026-05-17: 4 pas-soft test(s) still fail — quote-2.3.1/2.3.2/2.4/2.5 (schema-reload cascade after `db close; sqlite3 db test.db` re-init.busy=1 reparse of `CHECK(c!="null")` — C's `if(db->init.busy) return 1` arm in areDoubleQuotedStringsEnabled would demote, but adding the same demotion in Pas flagU breaks ALTER TABLE DROP COLUMN reparse-via-sqlite_rename_test (debug showed init.busy=1 there too, but the demotion turns ALTER's "after drop column" error path into a SEGV — suggests Pas sets init.busy spuriously inside the rename validation path where C leaves it 0; needs a deeper alter-codegen audit, not a string tweak).  select1 has multiple distinct ARCHITECTURAL divergences (column-name `test1.f1` aliasing in TclTestDriver, `ambiguous column name: f2` resolution order, ORDER BY-of-aliased 6.10, aliased-aggregate 11.14/15, GenColumn 12.10, USING-NATURAL 18.3) — none are single-hint tweaks; track separately.  Cites: codegen.pas:8683..8745 (flagUnresolvedTKID DQS demote arm), parse.y `%syntax_error` (divbug.53), build.c `markAllShadowTablesOf`/AddColumnError, resolve.c aggregate-misuse messages, select.c ORDER BY index range check.  Commits 1a0629b, d04edb5, (this).
- [X] **9.4.divbug.71** STRICT-typed table mis-error path
- [X] **9.4.divbug.71.b** PRAGMA quick_check/integrity_check single-table form
- [X] **9.4.divbug.71.c** ALTER ADD COLUMN error wrapper
- [ ] **9.4.divbug.72** Row-value misuse detection missing — `SELECT (1,2)` and `SELECT … WHERE (a,b)=...` constructs accepted silently when C raises `row value misused` (rowvalue-3.1.x, rowvalue4-1.x; cascades to rowvalue2/3/7/8/9/A).  Cites: 7eb9851, 8618b87.  Partial close 2026-05-17: ported `checkRowValueMisuse` walker (codegen.pas:9254..9319), the comparison/BETWEEN arm of resolve.c:1420..1453 the Pas resolver's "structurally lighter walk" was skipping.  Wired into sqlite3ResolveExprNames + sqlite3ResolveSelectNames after the SELECT WHERE / HAVING / LIMIT / ORDER BY / GROUP BY / pEList resolution arms.  Closes the rowvalue4-2.8 SIGSEGV bisect: `WHERE (b,b) <= 1` on an indexed leading column previously slipped through resolution and segfaulted inside whereRangeVectorLen (codegen.pas:15834..15882; dereferences pRight^.x.pList[i] expecting a vector RHS).  rowvalue4 advances 0 → 13 sub-tests `Ok`, 0 errors (single remaining FAIL is the `drop_all_indexes` tester-harness gap, unrelated).  No regressions in the rowvalue2/3/5/7/8/9/A/vtab/rowvalue.test counts (all unchanged from baseline).  Residual 2026-05-17: ARCHITECTURAL — the rowvalue2/3/7/8/9/A/vtab failures are NOT row-value-misuse detection bugs; they are separate vector codegen / planner-shape divergences (e.g. rowvalue9-9.5e: planner picks `SCAN t1 USING COVERING INDEX i2` instead of `SEARCH`; rowvaluevtab-1.3-BETWEEN: pre-existing Pas BETWEEN-on-vector emits "row value misused" because the Pas codegen lacks the whereexpr.c:1291..1313 BETWEEN→GE+LE virtual-term rewrite for vector LHS — sqlite3ExprCodeTarget hits the TK_VECTOR scalar-context arm at codegen.pas:6593..6600).  Track BETWEEN-rewrite under a new sub-ticket if reopened.  Cites: 7eb9851, 8618b87, (this).  **BETWEEN-on-vector FIXED 2026-05-23 (commit 2b35ec3): rowvaluevtab.test FAIL→PASS.** Root cause was codegen, not the (already-faithful) exprAnalyze rewrite: `exprCodeBetween` (codegen.pas:8222) took a scalar fast-path (sqlite3ExprCodeTemp) instead of C's `exprCodeVector` (expr.c:6058), collapsing the row-value LHS so the synthesised GE/LE arms hit the scalar-context "row value misused" error. One-line swap. ExplainParity 1026/1026. Remaining rowvalue2/3/9/A residuals are the separate vector-codegen/planner-shape divergences noted above (several files also time out under the 2000ms cap). **rowvalue3-1.4 FIXED 2026-05-28: vector-IN with index-reuse + reordered SELECT projection (`(5,4) IN (SELECT b,a FROM t1)` over `INDEX i1(a,b)`) returned empty because `sqlite3ExprCodeIN` (codegen.pas:70630) called `sqlite3FindInIndex` with `aiMap=nil` and the LHS-reorder block at expr.c:4165..4174 was unported (comment "not reached on the shapes this port codes" was wrong). Added aiMap alloc + OP_Copy reorder into a fresh range; aiMap freed on all exit paths. Engine subtests now 35/35 (0 errors); residual driver FAIL is harness `drop_all_indexes` SOURCE-ERROR for 3.x/4.x/5.x blocks. ExplainParity 1026/1026 unchanged; in2/in5/join4/join5 PASS.
- [X] **9.4.divbug.73** `rowid` post-INSERT resolution returns 0
- [X] **9.4.divbug.74** UPSERT `ON CONFLICT DO UPDATE` increments target row
- [X] **9.4.divbug.75** select7 correlated `no such column: P.pk`
- [X] **9.4.divbug.76** View-column resolution / no-FROM-inside-FROM-subquery
- [X] **9.4.divbug.77** Cross-schema trigger validation error text
- [X] **9.4.divbug.78** Wide-table SCAN+predicate mis-count
- [ ] **9.4.divbug.79** windowE ROWS-framing produces permuted output — windowE-1.3 expected `[5 5,4 5,4,1 5,4,1,6 5,4,1,6,3 5,4,1,6,3,2]`.  Cites: 041da7c.  Residual 2026-05-17 (refined): row-ordering portion is now CORRECT after 041da7c (each row's first `a` value matches the expected sequence 5,4,1,6,3,2); current observed output is `[5 4 1 6 3 2]` — single-element frames instead of the expected cumulative aggregate.  The remaining divergence is in **frame-extent computation** under a redefined custom collation, not row order.  Theory: `windowCodeRangeTest` (codegen.pas:62047) emits an OP_Gt/OP_Ge with a P4_COLLSEQ pointer to `sqlite3ExprNNCollSeq` of the ORDER BY expression; for TEXT peer values the arithmetic add/subtract is skipped (the `reg1 >= ''` gate), so the per-row frame loop reduces to a raw collated compare `end.peer vs current.peer`.  Under the redefined-reverse `custom`, this comparison should cause the AGGSTEP loop to walk to EOF on each row (yielding cumulative frames), but in the Pas port end cursor advances exactly one step.  Suspected deeper cause: either (a) `windowReadPeerValues` reads from the wrong column on the end/current cursor when ORDER BY references a non-leading column of the ephemeral table; (b) the OP_Gt at windowCodeRangeTest reg1-arithmetic path (codegen.pas:62110..62117) is being entered for the start-cursor's peer pre-rewind state (leaves reg1 NULL/MEM_Null, so `reg1 >= ''` is false and arithmetic on NULL keeps it NULL, then `OP_Gt reg2,lbl,reg1` with NULL reg1 + SQLITE_NULLEQ flag→jump-on-null short-circuits the frame to a single row); (c) the pre-arithmetic guard at codegen.pas:62110 emits `OP_Ge regString,0,reg1` with no P4 collation — vs C window.c:2199 same — but the post-arithmetic `op` at codegen.pas:62119 sets P4_COLLSEQ correctly.  Per STOP-and-report constraint (multiple deep arms diverge: peer-value read, range-test arithmetic gate, NULLEQ interaction with redefined collation pointer identity), no narrow port lands here.  Next-session entry point: enable EXPLAIN dump for the 1.3 prepared statement and diff against C's VDBE listing for the same SQL; mismatch will localize to one of windowReadPeerValues / windowCodeRangeTest / sqlite3ExprNNCollSeq pColl caching.  Residual 2026-05-17.
- [X] **9.4.divbug.80** `ORDER BY without LIMIT on DELETE/UPDATE` not detected
- [ ] **9.4.divbug.80.a** Port DELETE/UPDATE LIMIT/ORDER BY codegen (SQLITE_ENABLE_UPDATE_DELETE_LIMIT runtime arm) — currently the Pascal grammar's rules 152/159 don't shift `orderby_opt limit_opt`, so the only legal use of trailing ORDER BY on DELETE/UPDATE is the error path from 9.4.divbug.80.  Wherelimit-1.2..3.13 (40 tests) need: (1) grammar extension to accept `orderby_opt limit_opt` in cmd::=DELETE/UPDATE arms; (2) sqlite3DeleteFrom / sqlite3Update signature already takes pOrderBy/pLimit but the generic-coroutine path in delete.c:300..420 / update.c:340..500 must rewrite to `WHERE rowid IN (SELECT rowid … ORDER BY … LIMIT …)`.
- [ ] **9.4.divbug.80.b** wherelimit3-1.2 planner EQP divergence — `SELECT … FROM t1 WHERE a BETWEEN ? AND ? ORDER BY b` should choose `INDEX t1b` (ORDER-BY-eliminating covering scan) but picks `t1a` range + TEMP B-TREE.  Likely cost-model regression in wherePathSolver / sqlite3WhereBegin's ORDER BY satisfiability scoring (where.c:6800+).
- [X] **9.4.divbug.81** Attached / `query_only` DB readonly enforcement
- [X] **9.4.divbug.82** INSERT…RETURNING / scalar-function eval returns empty
- [ ] **9.4.divbug.83** Planner row-order divergence across where* family — whereA-1.2 expected `[3 4.53 {} 2 hello world 1 2 3]` got `[1 2 3 2 hello world 3 4.53 {}]`; whereG-1.3 expected detail-string regex `/.*track.*composer.*album.*/` got order with composer scanned first (EQP residue of divbug.55); whereB/F/I/N, where2/6/8, orderbyB show similar ordering / EQP-shape divergences.  Cites: eab96c2.  Residual 2026-05-16: 8 pas-soft test(s) still fail (e.g. orderbyB, where2); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.84** Long-running tests hit the 20 s per-test driver
- [X] **9.4.divbug.85** `collate5.test`
- [X] **9.4.divbug.86** Sibling-of-.84 driver-timeout family
- [ ] **9.4.divbug.87** Result divergence cluster (carved from `9.4.4.g-unbucketed` 2026-05-16) — **73 pas-soft tests** emit `got:` lines that do not match the C oracle.  Subdivided into `result-divergence` (68: e.g. `backup5`, `badutf`, `capi2`, `colmeta`, …) and `malformed-corrupt-vector` (5: `backup4`, `corruptM`, `in2`, `rowhash`, …).  Each test needs an individual bisect; this single bullet placeholds until root-cause splits emerge.  Full list classified in `/tmp/unbk_sig2.tsv` from the 2026-05-16 sweep.
  - [X] **9.4.divbug.87.001** `backup4`
  - [X] **9.4.divbug.87.002** `backup5`
  - [X] **9.4.divbug.87.003** `badutf`
  - [X] **9.4.divbug.87.004** `capi2`
  - [X] **9.4.divbug.87.005** `colmeta`
  - [X] **9.4.divbug.87.006** `corruptC`
  - [X] **9.4.divbug.87.007** `corruptM`
  - [X] **9.4.divbug.87.008** `delete4`
  - [X] **9.4.divbug.87.009** `descidx1`
  - [X] **9.4.divbug.87.010** `diskfull`
  - [X] **9.4.divbug.87.011** `eval`
  - [X] **9.4.divbug.87.012** `exec`
  - [X] **9.4.divbug.87.013** `exprfault`
  - [X] **9.4.divbug.87.014** `exprfault2`
  - [X] **9.4.divbug.87.015** `func3`
  - [X] **9.4.divbug.87.016** `fuzz-oss1`
  - [X] **9.4.divbug.87.017** `gcfault`
  - [X] **9.4.divbug.87.018** `gencol1`
  - [X] **9.4.divbug.87.019** `having`
  - [X] **9.4.divbug.87.020** `hexlit`
  - [ ] **9.4.divbug.87.021** `in2` — ! in2-{286..571} error: database disk image is malformed (209 of 1997 sub-tests fail).  Triage notes (4 h): Repro is `tclsh ./bin/libpassqlite3tcl.so` + the in2.test seed (2000 ints + '' + 2000 short text rows in table `a`), then `SELECT 1 IN (SELECT a FROM a WHERE i<N OR i>=2000)` for various N; passes in `bin/passqlite3` shell, fails only under the Tcl binding because the testfixture build forces SQLITE_DEFAULT_PAGE_SIZE=1024 (types.pas:290) so balancing fires sooner.  Bug surfaces inside the **IN-subquery ephemeral b-tree** when `defragmentPage` slow path runs on a leaf index page (e.g. pgno=4) and the post-rebuild invariant `data[hdr+7]+cbrk-iCellFirst != pPage^.nFree` trips → `CORRUPT_PAGE` at btree.pas:1488..1490 (port of btree.c:1721).  Instrumented dump shows pPage^.nFree=11 but actual page physical free is 8 (top=292, freeblocks=[], nFrag=0, iCellFirst=284) AND `sum(xCellSize)` over the 138 cell pointers comes to 725 bytes so cbrk=299 and post-defrag free should be 15 (a 7-byte and a 4-byte mismatch).  Cells are 12×size-8 ("xNNNN" text records), 1×size-4 (the empty-string row), 125×size-5 (integers 128..285).  All cell varint heads decode cleanly; xCellSize_IdxLeaf returns the same min-4 bumped size that fillInCell/sqlite3BtreeInsert padded to.  The +3 inconsistency originates **upstream of defrag** — likely a previous balance_nonroot iteration set `apNew[iPg]^.nFree := usableSpace - szNew[iPg]` (btree.pas:6066) using a szNew that was 3 bytes short, propagating from an older sibling whose nFree was already 3 high (cumulative bias from the apDiv padding loop at btree.pas:5774-5778 interacting with the `b.szCell[j]==4 → sz := xCellSize(pParent, pCell)` interior re-parse arm at btree.pas:5957-5960; both arms are 1:1 with C btree.c:8496-8503 and 8855-8858, yet C oracle passes — suggesting Pas-side allocation/buffer-layout subtlety that's not yet identified).  Need deeper trace correlating szNew[i] computation against insertCell/insertCellFast sites over the whole 138-cell life of pgno=4.
  - [X] **9.4.divbug.87.022** `in5`
  - [X] **9.4.divbug.87.023** `in6`
  - [~] **9.4.divbug.87.024** `in7` — in7-1.1.6 now PASS after the OBLopt early-out fix (commit 941597f). Residual: in7 file times out under the 2000ms driver cap; remaining in7-1.1.3 divergence + in7-2.1 crash are pre-existing/unrelated, and in7-4.0 is a separate NATURAL JOIN error. WO_IN arm was already ported (stale diagnosis).
  - [X] **9.4.divbug.87.025** `index`
  - [X] **9.4.divbug.87.026** `index3`
  - [X] **9.4.divbug.87.027** `index8`
  - [~] **9.4.divbug.87.028** `index9` — partial-index with bound-variable WHERE: still deferred (6 errors, unchanged from baseline).  The literal-WHERE structural fix (87.029) does not help bound `?`/`$var` cases: whereUsablePartialIndex needs the bound value at prepare time, which requires vdbeUnbind to set Vdbe.expired on the expmask bit + a reprepare cycle passing pReprepare=old vdbe (vdbeapi.c sqlite3VdbeUnbind / sqlite3Reprepare / prepare.c) so bound values flow into exprCompareVariable on re-prepare.  Pure statement-lifecycle subsystem; no overlap with the 87.029 codegen fix.
  - [X] **9.4.divbug.87.029** `indexA`
  - [X] **9.4.divbug.87.030** `indexedby`
  - [X] **9.4.divbug.87.031** `indexexpr3-1.1`
  - [~] **9.4.divbug.87.032** `insert` — three root causes ported (insert.test now 83 PASS, was 0).  (a) IDLIST per-column resolution must run BEFORE the SELECT coroutine is emitted so destCoro.iSdst is initialised from the IDLIST-resolved bIdListInOrder; pre-pass added at codegen.pas:38731..38770, late count-mismatch check stays.  (b) SRT_Coroutine disposal arm was missing the post-row DecrJumpZero (select.c:1522..1524), so `INSERT INTO t SELECT … FROM src LIMIT N` ingested every row of src — added at codegen.pas:33135..33140.  (c) useTempTable Template-4 IPK pre-load read `OP_Column srcTab, iPKey, regRowid` unconditionally; C insert.c:1505..1509 reads it via `srcTab, ipkColumn` when the IDLIST names the IPK, or via storage column iPKey when there is no IDLIST — fixed at codegen.pas:39089..39105.  Remaining 4 fails (4.3/4.4/4.6/7.3) are pre-existing resolver gaps unrelated to .032 root cause.
  - [X] **9.4.divbug.87.033** `insert2`
  - [X] **9.4.divbug.87.034** `insert3`
  - [X] **9.4.divbug.87.035** `insertfault`
  - [X] **9.4.divbug.87.036** `instrfault`
  - [X] **9.4.divbug.87.037** `intpkey`
  - [X] **9.4.divbug.87.038** `intreal`
  - [X] **9.4.divbug.87.039** `istrue`
  - [X] **9.4.divbug.87.040** `join5`
  - [X] **9.4.divbug.87.041** `join7`
  - [X] **9.4.divbug.87.042** `join9`
  - [ ] **9.4.divbug.87.043** `joinC` — RE-TRIAGED 2026-05-24 (prior note was STALE/wrong): joinC does NOT fail at joinC-34 with a RIGHT-JOIN USING-coalesce operand-flip. It fails from joinC-1 with `no such column: t4.a` / `t3.a` on 3+-level-deep nested-from chains like `t1 JOIN (t2 JOIN (t3 JOIN (t4 JOIN t5 USING(a)) USING(a)) USING(a)) USING(a)`. The QUALIFIED ref `t4.a` cannot descend the multi-level wrapper chain — a resolver/`FindWrapperEListIdx` descent bug (the USING `a` column's pEList entry only reverse-maps to the LEFT operand, so deeper operands are unreachable). NOT an expandStar `T.*` or RIGHT-JOIN-flip problem. Still 281 fails. Companion fix landed for the `T.*` (star) case in 87.041 below. Cite: select.c expandStar SF_NestedFrom + resolve.c lookupName/extendFJMatch.
  - [X] **9.4.divbug.87.044** `joinI`
  - [X] **9.4.divbug.87.045** `limit`
  - [X] **9.4.divbug.87.046** `limit2`
  - [X] **9.4.divbug.87.047** `lock`
  - [X] **9.4.divbug.87.048** `lock7`
  - [X] **9.4.divbug.87.049** `minmax`
  - [X] **9.4.divbug.87.050** `minmax2`
  - [X] **9.4.divbug.87.051** `minmax3`
  - [X] **9.4.divbug.87.052** `misc2`
  - [X] **9.4.divbug.87.053** `misc3`
  - [X] **9.4.divbug.87.054** `misc4`
  - [X] **9.4.divbug.87.055** `misc5`
  - [ ] **9.4.divbug.87.056** `mmapwarm` — ! mmapwarm-1.0 expected: [507], Pas got: [506], C-sqlite3 reference (via stdin redirect) got: [127].  Triage (**two unrelated gaps**: per-row leaf-page packing + missing `sqlite3_mmap_warm` Tcl command).  (1) **Page-count divergence is environmental + a packing bug**.  Test source ../sqlite3/test/mmapwarm.test:29..38 creates 500 rows of `(randomblob(400), randomblob(500))` after `PRAGMA auto_vacuum=0` and asserts `PRAGMA page_count == 507`.  The expected `507` assumes a page_size of 1024 (historical testfixture default).  With the current SQLITE_DEFAULT_PAGE_SIZE=4096 (sqliteLimit.h:213..214) C-sqlite3 packs ~4 rows/leaf via overflow chains for a count of 127.  Pas instead emits **one page per row** (506) — each ~900-byte row spills its entire payload to overflow despite maxLocal≈1024 on a 4096 page.  Stale log showed [127] (matches C) because pre-.032-.034 the INSERT…SELECT cluster bug truncated the CTE early at 125 rows × 1 leaf-page each ≈ 127 pages; now CTE delivers all 500 rows, exposing the packing bug.  Root cause likely in `btreeComputeFreeSpace`/`fillInCell` payload-threshold math at passqlite3btree.pas:859..895 (`surplus := minLocal + (nPayload-minLocal) mod (usableSize-4)`); C btree.c:1131..1147 same algebra but Pas signed/u16 mixing around lines 859..869 may cause the `surplus <= maxLocal` branch to mis-fire for nPayload=903 (after rowid+hdr), driving nLocal=minLocal (~50) and the rest to overflow → one overflow chain per row but those overflow pages also get one row each since the leaf cell is full.  Even with a packing fix, mmapwarm-1.0 still won't match [507] without forcing `PRAGMA page_size=1024` (test relies on legacy default).  (2) **Tests 1.1–3.x fail with `invalid command name "sqlite3_mmap_warm"`** — the Tcl-side helper backing `sqlite3_test_mmap_warm` (sqlite3.c `sqlite3_test_control(SQLITE_TESTCTRL_*)` + tclsqlite.c `Sqlitemmapwarm_Init` / `sqlite3_mmap_warm` exposure) is not wired in `bin/libpassqlite3tcl.so`.  Need to (a) port `sqlite3_mmap_warm(db, zSchema)` from main.c (~30 lines: walk pager pages, sqlite3PagerGet+PagerUnref to pre-fault mmap), and (b) register it in the Pas Tcl binding alongside the existing test commands.  Faultsim test 3 also requires `do_faultsim_test` infra (oom* faults) which is a much larger gap.  Both 1.0 packing + sqlite3_mmap_warm wiring remain — neither is a 45-min fix; sqlite3_mmap_warm + page_size=1024 test override would clear 1.1/1.2/1.3/1.4/2.0 but 1.0 needs the btree packing investigation independently.
  - [X] **9.4.divbug.87.057** `notnullfault`
  - [X] **9.4.divbug.87.058** `null`
  - [~] **9.4.divbug.87.059** `nulls1` — BIGNULL_SORT planner+codegen confirmed already fully ported (stale note corrected 2026-05-23): wherePathSatisfiesOrderBy keeps isMatch + sets WHERE_BIGNULL_SORT (codegen.pas:21563, =where.c:5425..5431), two-pass scan emits (codegen.pas:25935..26173), no surviving refusal/assert. nulls1 72/73 (5.3/5.5/6.1.2/6.2.2 PASS); collate4-4.3 PASS. Lone residual nulls1-9.3: skip-scan `ANY(c1)` + BIGNULL two-pass on c3 interaction drops the 2nd skip-scan group — distinct planner/codegen path, separate triage.
  - [X] **9.4.divbug.87.060** `orderby5`
  - [X] **9.4.divbug.87.061** `orderbyA`
  - [X] **9.4.divbug.87.062** `quickcheck`
  - [X] **9.4.divbug.87.063** `resolver01` 5.1
  - [X] **9.4.divbug.87.064** `rowhash`
  - [ ] **9.4.divbug.87.065** `savepoint6` — ! savepoint6-normal.8.2 error: database disk image is malformed.  Triage: full run 8006 sub-tests, 3750 errors — across both `savepoint6-normal.*` and `savepoint6-smallcache.*` permutations.  Failure pattern is alternating `.1 error: string or blob too big` followed by `.2 error: database disk image is malformed` at nearly every iteration past .8 (~3750/4003 in each permutation).  Test setup uses `PRAGMA auto_vacuum=incremental` + `CREATE TABLE t1(x,y)` with UNIQUE INDEX i1(x) + INDEX i2(y), then runs 1000 random SAVEPOINT/RELEASE/ROLLBACK iterations (savepoint6.test:36..37, body :150..240) with periodic `PRAGMA incremental_vacuum` (:190, :226).  The "string or blob too big" symptom (SQLITE_TOOBIG) on `.1` typically signals a btree cell length-field that has been overwritten with garbage (cell->nKey or nData mis-decoded), which is then detected as `SQLITE_CORRUPT` on the very next access (`.2`).  Sibling cluster of 87.064 (same SQLITE_CORRUPT family).  Root cause is in the savepoint-rollback / incremental-vacuum interaction — likely the freelist or auto-vacuum pointer-map (PTRMAP_*) is not restored correctly on `ROLLBACK TO SAVEPOINT`.  C reference: ../sqlite3/src/pager.c:6063..6225 (sqlite3PagerSavepoint / pagerPlaybackSavepoint) and ../sqlite3/src/btree.c:62300..62410 (sqlite3BtreeSavepoint + setSharedCacheTableLocks).  Needs a savepoint-rollback / autovacuum-ptrmap reconciliation port.
  - [X] **9.4.divbug.87.066** `securedel`
  - [X] **9.4.divbug.87.067** `tkt2920`
  - [X] **9.4.divbug.87.068** `tkt3442` `no such column: 5000`
  - [X] **9.4.divbug.87.069** `tkt3718`
  - [X] **9.4.divbug.87.070** `transitive1`
  - [X] **9.4.divbug.87.071** `upfrom1`
  - [X] **9.4.divbug.87.072** `upsert1`
  - [X] **9.4.divbug.87.073** `upsert4`
- [ ] **9.4.divbug.88** Tcl-bridge command/subcommand long-tail (carved from `9.4.4.g-unbucketed` 2026-05-16) — **62 pas-soft tests** still hit bridge gaps after `9.4.divbug.62/.63/.64/.65` closed the high-frequency surface.  Subdivided into `invalid/unknown command` (55: `badutf2`, `bindxfer`, `cacheflush`, `capi3d`, …) and `unknown subcommand "null"` / `db <other-subcmd>` (7: `indexexpr1`, `joinH`, `join`, `json102`, …).  Port the remaining `db ?subcommand?` and top-level Tcl-bridge entry points until the cluster drains.  **BRIDGE SURFACE FULLY DRAINED a4 2026-06-04** — all 60+ children [X]; sole remaining open child is `88.068.b` (multi-overflow-page reopen SIGSEGV = ENGINE, not bridge). Parent stays `[ ]` only to track that engine carve-out.
  - [X] **9.4.divbug.88.001** `badutf2`
  - [X] **9.4.divbug.88.002** `bindxfer`
  - [X] **9.4.divbug.88.003** `cacheflush`
  - [X] **9.4.divbug.88.004** `capi3d`
  - [X] **9.4.divbug.88.005** `capi3e`
  - [X] **9.4.divbug.88.006** `chunksize`
  - [X] **9.4.divbug.88.007** `cksumvfs`
  - [X] **9.4.divbug.88.008** `close`
  - [X] **9.4.divbug.88.009** `collate7`
  - [X] **9.4.divbug.88.010** `colname`
  - [X] **9.4.divbug.88.011** `corrupt`
  - [X] **9.4.divbug.88.012** `corrupt2`
      - [X] **`{SQLITE_CORRUPT}` symbolic vs `11` numeric** (10.2)
  - [X] **9.4.divbug.88.013** `corrupt3`
  - [X] **9.4.divbug.88.014** `corrupt4`
  - [X] **9.4.divbug.88.015** `corrupt6`
  - [X] **9.4.divbug.88.016** `corrupt7`
  - [X] **9.4.divbug.88.017** `corruptE`
  - [X] **9.4.divbug.88.018** `corruptG`
  - [X] **9.4.divbug.88.019** `corruptH`
  - [X] **9.4.divbug.88.020** `corruptI`
  - [X] **9.4.divbug.88.021** `corruptJ`
  - [X] **9.4.divbug.88.022** `corruptK`
  - [X] **9.4.divbug.88.023** `corruptN`
  - [X] **9.4.divbug.88.024** `dataversion1`
  - [X] **9.4.divbug.88.025** `delete_db`
  - [X] **9.4.divbug.88.026** `e_createtable`
  - [X] **9.4.divbug.88.027** `e_dropview`
  - [X] **9.4.divbug.88.028** `e_reindex`
  - [X] **9.4.divbug.88.029** `e_select2`
  - [X] **e_select-0.2.0001.1 family** no-FROM GROUP BY admitted by aggregate
  - [X] **9.4.divbug.88.030** `e_update`
  - [X] **9.4.divbug.88.031** `e_uri`
  - [X] **9.4.divbug.88.032** `e_wal`
  - [X] **9.4.divbug.88.033** `e_walauto`
  - [X] **9.4.divbug.88.034** `enc3`
  - [X] **9.4.divbug.88.035** `errmsg`
  - [X] **9.4.divbug.88.036** `fallocate`
  - [X] **9.4.divbug.88.037** `filectrl`
  - [X] **9.4.divbug.88.038** `filefmt`
  - [X] **9.4.divbug.88.039** `hook`
  - [X] **9.4.divbug.88.040** `indexexpr1`
  - [X] **9.4.divbug.88.041** `interrupt2`
  - [X] **9.4.divbug.88.042** `ioerr`
  - [X] **9.4.divbug.88.043** `join`
  - [X] **9.4.divbug.88.044** `joinH`
  - [X] **9.4.divbug.88.045** `json102`
  - [X] **9.4.divbug.88.046** `json502`
  - [X] **9.4.divbug.88.047** `laststmtchanges`
  - [X] **9.4.divbug.88.048** `lock5`
  - [X] **9.4.divbug.88.049** `main`
  - [X] **9.4.divbug.88.050** `memsubsys1`
  - [X] **9.4.divbug.88.051** `memsubsys2`
  - [X] **9.4.divbug.88.052** `misc6`
  - [X] **9.4.divbug.88.053** `misuse`
  - [X] **9.4.divbug.88.054** `mjournal`
  - [X] **9.4.divbug.88.055** `multiplex4`
  - [X] **9.4.divbug.88.056** `nan`
  - [X] **9.4.divbug.88.057** `nolock`
  - [X] **9.4.divbug.88.058** `normalize`
  - [X] **9.4.divbug.88.059** `notnull2`
  - [X] **9.4.divbug.88.060** `trans3`
  - [X] **9.4.divbug.88.061** `upfrom4`
  - [X] **9.4.divbug.88.062** `varint`
  - [X] **9.4.divbug.88.063** `capi3d` follow-up
  - [X] **9.4.divbug.88.064** `capi3d` engine bug
  - [X] **9.4.divbug.88.065** `filectrl` follow-ups
  - [X] **9.4.divbug.88.066** `varint` engine bug
  - [X] **9.4.divbug.88.067** `filectrl` follow-up
  - [~] **9.4.divbug.88.068** `cksumvfs` full port — full 1:1 Pascal port of `../sqlite3/ext/misc/cksumvfs.c` (820 C lines → 751 line `src/passqlite3cksumvfs.pas`, already existed pre-task in mostly-complete form) is now wired to the Tcl trampolines (`TestModuleTest1.pas:2329..2354` now call the real `sqlite3_register_cksumvfs` / `_unregister_cksumvfs` instead of returning SQLITE_OK stubs).  Auto-extension `cksmRegisterFunc` ported (cksumvfs.c:767..783) so `verify_checksum()` registers on every new connection.  Smoke confirms `sqlite3_vfs_find('cksmvfs')` returns the shim and `verify_checksum(blob)` evaluates.  cksumvfs.test still SIGSEGVs at 1.3 (3 sub-asserts pass, was 3 before) — independent engine bugs broken out into sub-buckets .068.a and .068.b below.
    - [X] **9.4.divbug.88.068.a** `PRAGMA <unknown>` must dispatch to
    - [ ] **9.4.divbug.88.068.b** Multi-overflow-page INSERT after `db close; sqlite3 db file.db` reopen SIGSEGVs.  **Bisected (divbug.88.068.b investigation, branch a4)**: the original tasklist diagnosis ("reload after reopen") was incorrect.  Crash happens on the *first* `db close` after one overflow-page INSERT, NOT on reopen.  Minimal repro (tclsh under bin/libpassqlite3tcl.so, fails with SIGSEGV `munmap_chunk(): invalid pointer`):
```
package require sqlite3
sqlite3 db test.db
file_control_reservebytes db 8   ;# REQUIRED — without this, no crash
db eval { PRAGMA page_size = 4096 }   ;# REQUIRED — implicit default doesn't trigger
db eval { CREATE TABLE t1(a INTEGER PRIMARY KEY, b, c) }
db eval { INSERT INTO t1 VALUES(1, randomblob(5000), randomblob(1500)) }   ;# REQUIRED — overflow chain
db close   ;# crashes here in __malloc_usable_size from sqlite3_close_v2 → DelDatabaseRef
```
Independent of cksumvfs (does NOT need `sqlite3_register_cksumvfs`).  Reduced positives: `passqlite3` shell `PRAGMA reserve_bytes=8` / `.filectrl reserve_bytes 8` paths do NOT apply the reserve so cannot repro through the shell; the Tcl wrapper `file_control_reservebytes` (TestModuleTest1.pas:4421) DOES wire it via `sqlite3_file_control(db,"main",SQLITE_FCNTL_RESERVE_BYTES,&n)`.  Crash backtrace lives entirely inside `libpassqlite3tcl.so` (stripped, 2 dyn-syms) and ends in glibc `__malloc_usable_size(m=<garbage>)` — i.e. a wild pointer is passed to `free` during `sqlite3PagerClose`/`sqlite3BtreeClose` teardown of the pager-page cache.  The corruption pre-conditions are:
  * `sqlite3BtreeSetPageSize(pBt, 0, 8, 0)` (from FCNTL_RESERVE_BYTES at main.pas:4750) followed by
  * explicit `PRAGMA page_size=4096` (probably re-invokes SetPageSize and reallocates internal page buffer with mismatched `usableSize` vs `pageSize` accounting)
  * one overflow-chain insert that triggers an `aOvfl`/`sqlite3PagerWrite` allocation with the stale sizing
Crash never fires without the explicit page_size PRAGMA after RESERVE_BYTES, nor without an overflow-producing insert, nor without `db close`.  Likely fix area: `sqlite3BtreeSetPageSize` in passqlite3btree.pas — ensure that when `nReserve` was set first, a subsequent page-size change re-aligns/reallocates `pBt^.pTmpSpace` / pager page buffers to `pageSize` (not `usableSize`).  Cite: `../sqlite3/src/btree.c` sqlite3BtreeSetPageSize + `../sqlite3/src/pager.c` sqlite3PagerSetPagesize.  Stopped at ~1.5h budget — minimal repro saved at `/tmp/repro_rb2.tcl`; deeper fix needs a `-g`/non-stripped libpassqlite3tcl.so rebuild for symbolic gdb backtrace.
  - [~] **9.4.divbug.88.069** `multiplex` full port — landed `src/passqlite3multiplex.pas` (917 Pascal lines from the ~1370-line `../sqlite3/src/test_multiplex.c`).  Real chunk-file shim VFS: multiplexOpen / multiplexRead / multiplexWrite split I/O across `foo.db`, `foo.db001`, … chunks; multiplexDelete sweeps journal/wal chunks; multiplexFileControl exposes MULTIPLEX_CTRL_* and the `multiplex_truncate / _enabled / _chunksize / _filecount` pragmas; multiplexFuncInit auto-extension registers the `multiplex_control()` SQL fn.  Tcl trampolines `sqlite3_multiplex_initialize / _shutdown / _control` rewired in TestModuleTest1.pas (88.025 / 88.055 STUBs replaced).  Counts: `delete_db` 4→18 sub-tests reached (4× deeper; remaining 14 fail on the unrelated `sqlite3_delete_database` Tcl command and the `SQLITE_ENABLE_8_3_NAMES` URI gate, both out of scope); `multiplex4` 4 pass + 10 fail (most failures are the 8_3_NAMES `.db001` vs `.001` rename and pragma `multiplex_truncate` echo).  Regression gate: 100/101 (TestFuzzDiff red as expected, 5264/5264 assertions).  Open sub-buckets:
    - [X] **9.4.divbug.88.069.a** `SQLITE_ENABLE_8_3_NAMES` arms in
    - [X] **9.4.divbug.88.069.b** `sqlite3_delete_database` Tcl command
- [~] **9.4.divbug.89** Empty driver diagnostic (carved from `9.4.4.g-unbucketed` 2026-05-16) — **12 pas-soft tests** (`corruptB`, `e_changes`, `e_totalchanges`, `fuzz`, `index4`, `index5`, `join6`, `joinA`, `joinB`, `joinD`, `manydb`, `tkt3080`) FAIL but `bin/tcl-failure-logs/<base>.{err,out}` capture no diagnostic — driver swallows the message or the tests abort outside `tcltest`.  Action: instrument `TclTestDriver` to dump the last N lines of stdout/stderr on any non-PASS exit so these become triageable.  Instrumentation landed (TclTestDriver.pas: `WriteFailLogs` now emits a header — test path, spawn cmd, exit-code, byte counts — and appends a 50-line tail block; empty streams write `(empty)`).  Smoke: join6 now reveals `exit-code: 134` + `double free or corruption (!prev)`; e_changes/manydb reveal `exit-code: 139` (SIGSEGV) past the last `Ok` line.  Per-test root-causing of .001..012 remains TODO.
  - [X] **9.4.divbug.89.001** `corruptB`
  - [X] **9.4.divbug.89.002** `e_changes`
  - [X] **9.4.divbug.89.003** `e_totalchanges`
  - [X] **9.4.divbug.89.004** `fuzz`
  - [X] **9.4.divbug.89.005** `index4`
  - [X] **9.4.divbug.89.006** `index5`
  - [X] **9.4.divbug.89.007** `join6`
  - [X] **9.4.divbug.89.008** `joinA`
  - [X] **9.4.divbug.89.009** `joinB`
  - [X] **9.4.divbug.89.010** `joinD`
  - [X] **9.4.divbug.89.011** `manydb`
  - [X] **9.4.divbug.89.012** `tkt3080`
  - [X] **9.4.divbug.89.013** `joinA`
  - [~] **9.4.divbug.89.014** `joinB` residual (carved from .009 close 2026-05-17, partial close 2026-05-17) — joinB residual errors **368→32 / 512** (480 subtests now PASS, was 144).  Root cause: Pas port of `sqlite3ProcessJoin` (passqlite3codegen.pas:27412..27488, mirrors select.c:516..668) was missing the JT_LTORJ coalesce arm at select.c:596..633.  When the FROM clause contains *any* RIGHT/FULL JOIN, the USING-emitted left side `pE1` must be `coalesce(t1.col, t2.col, ..., tN.col)` over EVERY prior FROM term that has the column (gated by `pSrc->a[0].fg.jointype & JT_LTORJ`).  Without it, the RIGHT JOIN's unmatched-right scan emits a row where the first matched left-table's column is NULL, and the subsequent USING-eq `t1.a = t5.a` drops what should be a match (e.g. joinB-17: t4.a=19 unmatched-right + `INNER JOIN t5 USING(a)` lost the t5.a=19 row entirely).  Fix: port the `while tableAndColumnIndex(... iLeft+1, i-1 ...) != 0` loop that accumulates non-ambiguous matches into pFuncArgs, then wraps as a TK_FUNCTION 'coalesce' with affExpr=SQLITE_AFF_DEFER.  Also raise "ambiguous reference to X in USING()" when an interior match is NOT also USING-masked (mirrors select.c:619).  No regressions: joinA 42/42, joinC unchanged (152 err), joinD/E/F PASS, in-tree regression 100/101 (baseline).  Residual 32 errors in joinB form a different shape (e.g. joinB-84: expected `11 31 - 31 31 -` got `11 - - - 31 -`) — a separate downstream issue with column-2 (`t1.a`) projection on RIGHT-JOIN unmatched-right rows; tracked as 89.014-tail.

      89.014-tail triage 2026-05-18 (no code landed — architectural):
      All 32 residuals are subtests whose FROM clause contains a parens-
      wrapped sub-join like `(t2 RIGHT JOIN t3 USING(a))` or `(t2 FULL JOIN
      t3 USING(a))` (joinB-68/76/84/92/100/108/.../508).  EXPLAIN diff for
      joinB-84 shows the divergence is in the INNER subroutine that
      materialises the parens-wrapped sub-FROM into an ephemeral table:
      C emits `Column 3 0` (read `a` from cursor t3) for the column-0
      projection, Pas emits `Column 2 0` (read `a` from cursor t2).
      C's inner subroutine also has 8 projection slots vs Pas's 6.

      Root cause: Pas's `expandStar` (passqlite3codegen.pas:26821..27026)
      directly emits resolved `TK_COLUMN(iCursor, iColumn)` while C's
      `selectExpander` star arm (select.c:6160..6313) emits `TK_ID` /
      `TK_DOT(TK_ID,TK_ID)` and relies on the *resolver* (`lookupName`,
      resolve.c:370..461) to apply the JT_LTORJ + USING-shared
      column-rewrite rule: when later FROM items USING-share the column
      and are plain RIGHT JOIN (JT_RIGHT and not JT_LEFT), re-target
      pMatch to the right-most table (rules at resolve.c:386..394 and
      449..457); for FULL JOIN, synthesise a coalesce() via
      `extendFJMatch` (already ported as 89.013 for the resolver, but
      89.013 only covers bare TK_ID, not the expandStar/NestedFrom path).
      In addition, the C SF_NestedFrom path at select.c:6184..6202
      synthesises a leading `..colname` TK_ID with `bUsingTerm=1` for
      each USING column before emitting that table's regular columns,
      and (with VisibleRowid) appends a `rowid` alias per table at
      select.c:6207..6208 — accounting for the extra 2 slots in C's
      inner pEList.

      Two attempted patches today: (1) port the resolver rescan loop
      into expandStar with `pTgtItem`/`jTgt` redirect + FULL-JOIN
      coalesce wrap, gated `SF_NestedFrom==0` — joinB-84 unchanged
      (the divergence is *inside* the NestedFrom sub-expand, so the
      gate excluded it).  (2) Same patch without the SF_NestedFrom
      gate — joinB-84 fixed but joinB went from 32 fails to 211 fails
      (regression on cases that rely on the existing 1-to-1 pEList /
      pTab->nCol invariant, see assert at select.c:6174).  Reverted
      both, repo back to clean baseline (32 fails / 480 pass).

      Path forward (architectural — STOP per task guidance): port the
      full SF_NestedFrom branch of `selectExpander` star arm
      (select.c:6160..6313) including the `..colname` USING-prefix
      synthesis, the `rowid` alias append, the qualified
      TK_DOT-wrap policy, AND the resolver rescan-loop redirect for
      plain RIGHT JOIN.  Or alternatively, switch Pas expandStar to
      emit `TK_ID`/`TK_DOT` and ensure `sqlite3ResolveSelectNames`
      re-runs over the expanded pEList so the existing lookupName
      port (which already has the JT_RIGHT / extendFJMatch arms from
      89.013) handles the redirect.  Either is a >1h port that
      touches resolver invariants for every `SELECT *`.
      Reproducer:
        CREATE TABLE t1(a INT,b INT,c INT);
        CREATE TABLE t2(a INT,b INT,d INT);
        CREATE TABLE t3(a INT,b INT,e INT);
        CREATE TABLE t4(a INT,b INT,f INT);
        CREATE TABLE t5(a INT,b INT,g INT);
        INSERT INTO t1 VALUES(11,21,31);
        INSERT INTO t3 VALUES(11,21,31);
        INSERT INTO t4 VALUES(11,21,31);
        SELECT a, c, d, e, f, g FROM t1
          INNER JOIN (t2 RIGHT JOIN t3 USING(a)) USING(a)
          RIGHT JOIN (t4 LEFT JOIN t5 USING(a)) USING(a);
        -- expected: 11|31||31|31|
        -- pas got:  11||||31|
  - [X] **9.4.divbug.89.015** `joinD`
  - [X] **9.4.divbug.89.016** `fuzz` residual
- [ ] **9.4.divbug.90** Extension / SQL function / VFS registration residue (sibling of `9.4.divbug.66`, carved from `9.4.4.g-unbucketed` 2026-05-16) — **8 pas-soft tests**: 6 `no such extension` (`btree02`, `extension01`, `func4`, `indexexpr2`, …), 1 `no such function` (`func9`), 1 `no such vfs: devsym` (`io`).  Each pin in the C build is a known extension/function/VFS shim; port or auto-register at db-open following the `.66` template.  Progress 2026-05-17: 7/8 registration shims landed (5 aExtension[] rows in TestModuleTest1.pas — eval/fileio/totype/explain/wholenumber, all Pas ports already existed; unistr_quote builtin in passqlite3codegen.pas via quoteFunc + pUserData=1, mirrors func.c:3340).  3/8 now PASS via driver (`extension01`, `func4`, `func9`); 4/8 reach the engine post-shim and re-bucket as non-registration engine bugs (`btree02`, `indexexpr2`, `memdb`, `misc8`); 1/8 (`io`) still wants the full `test_devsym.c` VFS port — out of scope for the registration drain.
  - [X] **9.4.divbug.90.001** `btree02`
  - [X] **9.4.divbug.90.002** `extension01`
  - [X] **9.4.divbug.90.003** `func4`
  - [X] **9.4.divbug.90.004** `func9`
  - [X] **9.4.divbug.90.005** `indexexpr2` PASS 126/126
  - [ ] **9.4.divbug.90.006** `io` — `no such vfs: devsym` still open; needs full `src/test_devsym.c` VFS port (a fresh sqlite3_vfs with shadow + I/O-error injection — non-trivial new port, not a registration-shim drop-in).
  - [X] **9.4.divbug.90.007** `memdb`
  - [X] **9.4.divbug.90.008** `misc8-3.0` SIGSEGV
- [ ] **9.4.divbug.91** Tcl harness helper gaps (carved from `9.4.4.g-unbucketed` 2026-05-16) — **16 pas-soft tests** on missing test-harness plumbing (engine behaviour not exercised): `md5sum` Tcl command (5: `backup_ioerr`, `backup`, `fuzz3`, `interrupt`, `trans2`); arbitrary missing tclvars (4: `join3`, `savepoint2`, `tkt3992`, `types`); `cmdlinearg(soft-heap-limit)` array (2: `avtrans`, `capi3b`); `SQLITE_MAX_VARIABLE_NUMBER` tcl-const (1: `bind`); `QRF not available in this build` build-flag gap (2: `qrf01`, `qrf02`); `no files matched glob "*malloc*.test"` (1: `mallocAll`); `couldn't read file "-"` stdin input (1: `memleak`).  Progress 2026-05-17: md5sum SQL aggregate now auto-registered on every connection (PasTclSqlite.pas DbMain — calls Md5_Register after sqlite3_open_v2, mirrors test_func.c:723..726 autoinstall_test_functions / auto_extension), and tester_min.tcl seeds `bitmask_size=64` (test1.c:9335..9438), `SQLITE_MAX_VARIABLE_NUMBER=32766` (test_config.c:817), `cmdlinearg(soft-heap-limit)=0` (tester.tcl:378), `sqlite_options(utf16)=1` (test_config.c:705).  3/16 closed; 10/16 now reach the engine (residuals are not harness gaps and re-bucket below); 3/16 remain genuine harness gaps (backup family, qrf, mallocAll/memleak).
  - [X] a4 2026-06-05: strftime/sqlite3_libversion_number/save_prng_state/reset_
  - [X] **9.4.divbug.92** incrvacuum `no such column: t2.oid`
  - [X] **9.4.divbug.91.001** `avtrans`
  - [X] **9.4.divbug.91.002** `backup`
  - [X] **9.4.divbug.91.003** `backup_ioerr`
  - [X] **9.4.divbug.91.004** `bind`
  - [X] **9.4.divbug.91.005** `capi3b`
  - [X] **9.4.divbug.91.006** `fuzz3`
  - [X] **9.4.divbug.91.007** `interrupt`
  - [X] **9.4.divbug.91.008** `join3`
  - [X] **9.4.divbug.91.009** `mallocAll`
  - [X] **9.4.divbug.91.010** `memleak`
  - [ ] **9.4.divbug.91.011** `qrf01` — QRF (Query Result Formatter) is a tclsqlite.c-internal feature not ported.  Genuine build-flag gap (port out of scope for harness drain).
  - [ ] **9.4.divbug.91.012** `qrf02` — same as .011.
  - [X] **9.4.divbug.91.013** `savepoint2`
  - [X] **9.4.divbug.91.014** `tkt3992`
  - [X] **9.4.divbug.91.015** `trans2`
  - [X] **9.4.divbug.91.016** `types`
  - [X] **9.4.divbug.92.001** `filter1-3.3/3.5`
  - [X] **9.4.divbug.92.002** `json101-19.3`
  - [X] **9.4.divbug.92.003** `gencol1-23.5`
  - [X] **9.4.divbug.92.004** `gencol1-20.2`
  - [X] **9.4.divbug.92.005** `gencol1-8.20`
  - [ ] **9.4.divbug.92.006** `gencol1-9.20/13.10` "internal query planner error" — bb-UNIQUE auto-index on a VIRTUAL gen col gets WHERE_IDX_ONLY because colNotIdxed bit for the virtual col is 0 (UNIQUE auto-index created BEFORE AS clause sets COLFLAG_VIRTUAL); whereIndexExprTrans then sees OP_Column for the base column on the table cursor and trips the planner-error gate (codegen.pas:26250). C exhibits same parse order yet picks table-scan — root-cause mechanism differs (cost / IPK preference); needs deeper trace before a faithful fix.
  - [X] **9.4.divbug.92.007** `vtab2-5.3`
  - [X] **9.4.divbug.92.008** `with1-22.1`
  - [ ] **9.4.divbug.92.009** `with5-310` — recursive-CTE outer ORDER BY wrongly eliminated (dup outer SELECT binds result col iColumn=-1/rowid → WHERE_IPK ordered match drops sorter); pre-existing, deep materialise/dup fix. See memory project_with5_310_recursive_cte_orderby.

---

## Phase 10 — CLI tool (`shell.c`, ~12k lines → `passqlite3shell.pas`)

Each chunk lands with a scripted parity gate that diffs `bin/passqlite3`
against the upstream `sqlite3` binary.  Unported dot-commands must return
the upstream `Error: unknown command or invalid arguments: ".foo"` so
partial landings cannot silently no-op.

### 10.1a Skeleton + arg parsing + REPL loop

- [X] **10.1a** Skeleton landed
- [X] **10.1.1** ShellState record + global state
- [X] **10.1.2** processInput / oneInputLine REPL core
- [X] **10.1.3** main + process_command_line two-pass arg parser
- [X] **10.1.4** Line reader
- [X] **10.1.5** Exit-code mapping + interrupt_handler + SIGINT wiring
- [X] **10.1.6** do_meta_command dispatcher skeleton
- [X] **10.1a.G** Gate `src/tests/TestShellRepl.pas` 8/8 PASS

### 10.1b Output modes + formatting controls

- [X] **10.1b** Output modes + formatting controls
- [X] **10.1.7..10.1.14** `.mode` dispatcher, shell_callback row dispatcher

### 10.1c Schema introspection dot-commands

- [~] **10.1c** Gate: `bin/TestShellSchema`. Multi-result `.tables` / `.indexes`-no-arg / temp-schema side-effects on `.databases` after `.indexes` are pre-existing port divergences and stay out of the gate.
  - [X] **10.1c.1** `.schema`
  - [X] **10.1c.2** `.tables`
  - [X] **10.1c.3** `.indexes`
  - [X] **10.1c.4** `.databases`
  - [X] **10.1c.5** `.fullschema`
  - [X] **10.1c.6** `.lint fkey-indexes`
  - [X] **10.1c.7** `.expert`
- [X] **10.1.15..10.1.21** `.schema --indent`, `.tables`, `.indexes`

### 10.1d Data I/O dot-commands

- [X] **10.1d** Subcommands 10.1.22..10.1.27 landed
  - [X] **10.1d.1** `.read`
  - [X] **10.1d.2** `.dump`
  - [X] **10.1d.3** `.import`
  - [X] **10.1d.4** `.output` / `.once`
  - [X] **10.1d.5** `.save`
  - [X] **10.1d.6** `.open`
- [X] **10.1.22..10.1.27** `.read`, `.dump`, `.import`, `.output`/`.once`

### 10.1e Meta / diagnostic dot-commands

- [X] **10.1e** Gate: src/tests/TestShellMeta.pas
- [X] **10.1.28..10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`
- [X] **10.1.36** `.log`
- [X] **10.1.38** `.iotrace`
- [~] **10.1.39** `.scanstats` — basic per-loop dump landed via 8.2.1 (NAME/EXPLAIN/EST/SELECTID/PARENTID emitted). Sub-arms a..e all closed:
  - [X] **10.1.39.a** TWhereLevel.addrVisit field added
  - [X] **10.1.39.b** NLOOP/nExec confirmed
  - [X] **10.1.39.c** qrfEqpStats EQP-tree formatter ported
  - [X] **10.1.39.d** NCYCLE / hwtime sampling
  - [X] **10.1.39.e** EXPLAIN text re-enabled: SCANSTAT_EXPLAIN gates on
- [X] **10.1.40** `.testcase NAME` / `.check ANSWER`
- [X] **10.1.41** `.testctrl`
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — TRACEFLAGS toggle landed (via sqlite3_test_control). Mask-hint convention: subtask hints are bundle IDs, **always verify against** `sqliteInt.h:TREETRACE_*` / `whereInt.h:WHERETRACE_*`. Subtasks:
  - [X] **10.1.42.a** TREETRACE batch 1: begin/end
    - [X] **10.1.42.a.1** UNION ALL left/right
    - [X] **10.1.42.a.2** Post-flatten
    - [~] **10.1.42.a.3** EXISTS-to-JOIN (7368, 0x100000) + aggregate analysis (8442, 0x20). havingToWhere/countOfView/AggInfo-adjusted prints closed under a.6. Archive.
    - [X] **10.1.42.a.4** "after window rewrite"
    - [~] **10.1.42.a.5** Outer-join + FROM-subquery (verified masks 0x1000/0x800/0x4000/0x8000/0x20); landed via a.7/a.8/a.9/a.10/a.6.5. Remaining: flattenSubquery + IgnorableOrderby drop. Archive.
    - [X] **10.1.42.a.6** All 5 sub-arms
  - [~] **10.1.42.b** WHERETRACE batch 1: addBtreeIdx (0x800), addVirtual (0x800), OR-clause Begin/End (0x400). Subtasks:
    - [~] **10.1.42.b.1** Range-scan cost estimate — landed `Range scan lowers nOut` (where.c:2247, 0x20) in `whereRangeScanEst`. Other 4 arms STAT4-only, gated on b.7. Archive.
    - [X] **10.1.42.b.2** Subset-cost in `whereLoopAdjustCost`
    - [X] **10.1.42.b.3** Vtab constraint enumeration
    - [X] **10.1.42.b.4** Solver progress in `wherePathSolver`
    - [X] **10.1.42.b.5** OR-vs-AND per-subterm in `whereLoopAddOr`
    - [X] **10.1.42.b.6** DISTINCT reduction
    - [X] **10.1.42.b.7** Port the STAT4 cost-estimator helpers gating the 4
    - [X] **10.1.42.b.7.prereq** Port sqlite3Stat4ProbeSetValue +
    - [X] **10.1.42.b.7.prereq.a** Record-shape + scaffolding
    - [X] **10.1.42.b.7.prereq.b** analyze.c STAT4 collection
    - [X] **10.1.42.b.7.prereq.c** Consumers
    - [X] **10.1.42.b.7.prereq.c.1** Port `ValueNewStat4Ctx` struct
    - [X] **10.1.42.b.7.prereq.c.2** Port `valueFromFunction` STAT4 arm
    - [X] **10.1.42.b.7.prereq.c.3** Port `valueFromExpr` STAT4 branches +
    - [X] **10.1.42.b.7.prereq.c.4** Port public entries
    - [X] **10.1.42.b.7.prereq.c.5** Replace `sqlite3Stat4Column`
    - [X] **10.1.42.b.7.prereq.c.6** Port `loadStat4` / `loadStatTbl`
    - [X] **10.1.42.b.7.prereq.c.7** Port `whereKeyStats`
    - [X] **10.1.42.b.7.prereq.c.8** Port `whereRangeSkipScanEst`
    - [X] **10.1.42.b.7.prereq.c.9** Port `whereEqualScanEst`
    - [X] **10.1.42.b.8** Port `wherePathName` +
    - [X] **10.1.42.a.6.1** `havingToWhere` + `havingToWhereExprCb`
    - [X] **10.1.42.a.6.2** `countOfViewOptimization`
    - [X] **10.1.42.a.6.3** `optimizeAggregateUseOfIndexedExpr`
    - [X] **10.1.42.a.6.4** `aggregateConvertIndexedExprRefToColumn` + walker
    - [X] **10.1.42.a.6.5** "Finished with AggInfo" at sqlite3Select tail
    - [X] **10.1.42.a.7** Outer-join strength-reduction loop
    - [X] **10.1.42.a.8** FROM-subquery superfluous-ORDER-BY drop
    - [X] **10.1.42.a.9** `pushDownWhereTerms`
    - [X] **10.1.42.a.10** all-FROM snapshot
    - [X] **10.1.42.a.11** top-level ORDER-BY drop
    - [X] **10.1.42.a.12** DISTINCT→GROUP BY
  - [X] **10.1.42.c** `sqlite3DebugPrintf`
  - [X] **10.1.42.d** Build-flag gating: `build.sh` honours `SQLITE_DEBUG=1` →

### 10.1f Long-tail / specialised dot-commands

- [X] **10.1f** Closed 2026-05-13
  - [X] **10.1f.0..10.1f.2** `.backup` / `.restore` / `.clone`
  - [X] **10.1f.3** `.archive`/`.ar`
  - [X] **10.1f.4** `.session`
  - [X] **10.1f.5** `.recover`
  - [X] **10.1f.6** `.dbinfo`
  - [X] **10.1f.7** `.dbconfig`
  - [X] **10.1f.8** `.filectrl`
  - [X] **10.1f.9** `.sha3sum`
  - [X] **10.1f.10..10.1f.13** `.crnl`/`.binary`/`.connection`/`.unmodule`
  - [X] **10.1f.14..10.1f.16** `.vfsinfo`/`.vfslist`/`.vfsname`

- [X] **10.1.43..10.1.45** `.backup`, `.restore`, `.clone` all landed
- [X] **10.1.46** `.archive`/`.ar`
- [X] **10.1.47** `.session`
- [X] **10.1.48** `.recover`
- [X] **10.1.49** `.dbinfo`
- [X] **10.1.50** `.dbconfig`
- [X] **10.1.51..10.1.59** `.filectrl`, `.sha3sum`, `.crnl`, `.binary`

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
- [X] **10.1.67** anycollseq.c + blobio.c + nextchar.c + remember.c +
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
- [X] **10.1.90** cksumvfs.c → passqlite3cksumvfs.pas
- [X] **10.1.91** unionvtab.c → passqlite3unionvtab.pas
- [X] **10.1.92** fuzzer.c → passqlite3fuzzer.pas
- [X] **10.1.93** tmstmpvfs.c → passqlite3tmstmpvfs.pas
- [X] **10.1.94** amatch.c → passqlite3amatch.pas
- [X] **10.1.95** compress.c + sqlar.c
- [X] **10.1.96** ext/intck/sqlite3intck.c → passqlite3intck.pas
- [X] **10.1.97** ext/recover/dbdata.c → passqlite3dbdata.pas
- [X] **10.1.98** zipfile.c → passqlite3zipfile.pas
- [X] **10.1.99** spellfix.c → passqlite3spellfix.pas
- [X] **10.1.100** Built-in shell SQL UDFs: strtod, dtostr, shell_add_schema
- [X] **10.1.101** `ext/expert/sqlite3expert.c` → `passqlite3expert.pas`
- [X] **10.1.102** `.open --zip` / `--deserialize` / `--hexdb` shell glue +

- [~] **10.1a.1** Residual dot-command coverage gap surfaced by 2026-05-16 audit (Outcome B).  C `shell.c.in` help table (lines 3711..3962) lists 67 dot-commands; `doMetaCommand` in `src/passqlite3shell.pas:10342` routed 56 of them.  The 11 missing handlers all have working backing APIs in the engine and live entries in the Pas `azHelp[]` table (3704..3958).  Decomposed into bite-sized sub-arms 10.1a.1.1..10.1a.1.11; the 5 trivially-small ones (≤25 LOC each) landed inline 2026-05-16; the 6 medium ones are queued.  Gates: `bin/TestShellRepl` 8/8, `bin/TestShellModes` 2/2, `bin/TestShellSchema` 10/10, `bin/TestShellIO` 11/11, `bin/TestShellMeta` 60/60, `bin/TestCliParity` 20/1S/0 (== baseline).
  - [X] **10.1a.1.1** `.bail on|off`
  - [X] **10.1a.1.2** `.timeout MS`
  - [X] **10.1a.1.3** `.version`
  - [X] **10.1a.1.4** `.prompt MAIN ?CONTINUE?`
  - [X] **10.1a.1.5** `.nonce STRING`
  - [X] **10.1a.1.6** `.limit ?NAME? ?VAL?`
  - [X] **10.1a.1.7** `.imposter INDEX IMPOSTER` / `.imposter off`
  - [X] **10.1a.1.8** `.progress N`

  - [X] **10.1a.1.9** `.load FILE ?ENTRY?`
  - [X] **10.1a.1.10** `.auth ON|OFF`
  - [X] **10.1a.1.11** `.intck ?STEPS_PER_UNLOCK?`

### 10.1.bug.* — fixed bug ledger (kept as ticked stubs only)

> Closed bugs: history is in git. Each line below records the slot for
> regression-tracking purposes — re-open the slot if the symptom returns.

- [X] **10.1.bug.1** Header row leak in `.mode list`
- [X] **10.1.bug.103** strftime('%u') ISO weekday off-by-one
- [X] **10.1.bug.105** ISO 8601 `[+-]HH:MM` timezone suffix dropped
- [X] **10.1.bug.106** `'localtime'` / `'utc'` date modifiers were no-ops
- [X] **10.1.bug.107** CREATE UNIQUE INDEX on pre-populated dups silently
- [X] **10.1.bug.108** UNIQUE INDEX with COLLATE NOCASE ignored collation
- [X] **10.1.bug.109** `SELECT * FROM v ORDER BY a,b` with covering UNIQUE
- [X] **10.1.bug.110** current_date / current_time / current_timestamp not
- [X] **10.1.bug.111** AUTOINCREMENT counter not consulted
- [X] **10.1.bug.112** Star expansion skipped in prior arms of compound
- [X] **10.1.bug.113** FROM-subquery coroutine in compound MERGE arms
- [X] **10.1.bug.114** Numeric-prefix coercion lost decimal/exponent
- [X] **10.1.bug.115** WITH RECURSIVE … LIMIT inside body: ran forever / no
- [X] **10.1.bug.116** Correlated subqueries with qualified outer refs failed
- [X] **10.1.bug.117** min(x)/max(x) over all-NULL returned blob "0.0"
- [X] **10.1.bug.118** shellEPutZ stderr/stdout interleave order
- [X] **10.1.bug.119** replace(s,p,r) with NULL p or r returned s instead of
- [X] **10.1.bug.120** Result-set column aliases not visible in WHERE
- [X] **10.1.bug.121** LIMIT/OFFSET ignored on eponymous-vtab fast-arm
- [X] **10.1.bug.122** Aggregates over eponymous-vtab returned empty
- [X] **10.1.bug.123** WITH RECURSIVE … ORDER BY dropped
- [X] **10.1.bug.124** CLI `near line N` off-by-one with comment-interleaved
- [X] **10.1.bug.125** Step-error rc was extended code, missing "
- [X] **10.1.bug.126** JSON-function malformed-input errors silently swallowed
- [X] **10.1.bug.127** ORDER BY+LIMIT silently dropped sort on coroutine FROM
- [X] **10.1.bug.128** CLI step-error prefix should be `Error near line N:`
- [X] **10.1.bug.129** CLI openDb missed
- [X] **10.1.bug.130** `UPDATE T AS t SET col=(SELECT … WHERE inner.col=t.col)`
- [X] **10.1.bug.131** Bare-TK_ID outer ref from inside a correlated subquery
- [X] **10.1.bug.132** CLI `processInput` cut-gate required `zSql[end]=';'`
- [X] **10.1.bug.133** CLI `.echo on` was a silent no-op
- [X] **10.1.bug.134** CLI `.parameter set` populated temp.sqlite_parameters
- [X] **10.1.bug.135** `.changes` / `.show` defects: per-SQL emission
- [X] **10.1.bug.136** Meta dot-command dispatcher sweep

---

## Known regression-test failures (auto-discovered by `run_regression.sh`)

> Ledger entries: when a binary returns to all-green, mark `[X]` and leave
> in place as a fixed-bug record (matching the convention used by 10.1.bug.*).
> Numbering is scoped to the phase that owns the root cause.

- [X] **3.B.regbug.1** TestPagerReadOnly
- [X] **6.regbug.1** TestWhereExpr
- [X] **trigger1.regbug.1** trigger1 same-name trigger 13→1 fail
- [X] **trigger1.regbug.2** trigger1-22.10 + trigger2 1.x.x cleared

---

## Phase 10.2 — CLI integration parity

- [X] **10.2** Integration parity: `bin/passqlite3 foo.db` ↔ `sqlite3 foo.db`

### Phase 10.3 — Interactive line-editor follow-ups

Baseline raw-mode editor with arrow-key history landed in
`src/passqlite3lineedit.pas` (Left/Right/Home/End/Up/Down,
Backspace/Delete, Ctrl-A/E/B/F/N/P/U/K/W/L/C/D, in-memory history
capped at 1000).  Optional enhancements on top of that baseline:

- [X] **10.3.a** On-disk history persistence at `~/.passqlite3_history`
- [ ] **10.3.b** Tab completion for `.dot` commands and for table /
  column names visible in the currently-open database (query
  `sqlite_schema` + `PRAGMA table_info`).
- [ ] **10.3.c** Multi-line wrap-aware rendering — current refresh
  assumes the line fits on one terminal row; long lines smear.  Needs
  column-count probe (`TIOCGWINSZ`) and a multi-row redraw that
  positions the cursor with `ESC[<n>A` / `ESC[<n>B`.
- [ ] **10.3.d** Reverse-incremental search (Ctrl-R) over the in-memory
  history, matching readline's `(reverse-i-search)`'pat': hit` UX.

---

## Phase 11 — Benchmarks (Pascal-on-Pascal speedtest1 port)

Output format must be byte-identical to upstream `speedtest1` so the
existing `speedtest.tcl` diff workflow keeps working.  Lives in
`src/bench/passpeedtest1.pas`; the same binary swaps backends
(passqlite3 vs system libsqlite3) by `--backend`.

- [X] **11.1** Harness port

- [X] **11.2** `testset_main` port

- [X] **11.3** Small / focused testsets

- [X] **11.4** Schema-heavy testsets: `testset_star`

- [X] **11.5** Optional/extension-gated testsets: testset_debug1, testset_json

- [X] **11.6** Differential driver `bench/SpeedtestDiff.pas`

- [X] **11.7** Regression gate: commit `bench/baseline.json`
  - [X] **11.7.repin** 2026-05-16: re-pinned baseline from MAX-of-9 local runs

- [X] **11.8** Pragma / config matrix

- [X] **11.9** Profiling hand-off to Phase 9

---

## Phase 12 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [X] **12.1** `perf record` on benchmark workloads
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
  - [X] **12.2.candidate.2** Specialise sqlite3VdbeRecordCompare on int-key +
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

- [ ] **12.4** FTS3/4 segment-merge build performance (moved from 6.40.1.o.2) — per-INSERT pending-terms flush runs ~28 ms/row so heavy builds blow the 30 s per-test wall clock. Suspected correct-but-slow (full `%_segdir`/`%_segments` rewrite per flush vs C's incremental path), NOT a correctness bug; on-disk parity must be preserved. Affected (pas-soft): fts4merge, fts4merge4, fts4merge5, fts4growth, fts4growth2, fts4opt, fts4langid, fts4check, fts3corrupt2, fts3corrupt6. **WON when each of those completes < 30 s (PASS, or any remaining fail has a non-timeout cause).** Profiling is bounded to producing committed artefacts, not open-ended "investigate":
  - [ ] **12.4.1** New `src/tests/TestFts3BuildPerf.pas` micro-bench: insert N=100/1000 docs; report ms/row for port vs `../sqlite3/sqlite3` AND count, per INSERT, the `%_segdir` UPDATE/DELETE ops + `fts3PendingTermsFlush` calls + SQL stmt re-prepares. **DoD:** bench committed + the baseline number table recorded in this task line.
  - [ ] **12.4.2** From 12.4.1 counts, give a yes/no verdict on each hypothesis: (a) flush fires per-row instead of at `nMaxPendingData`; (b) re-prepares instead of reusing `aStmt[40]`; (c) rewrites the whole segdir per flush. **DoD:** the three verdicts, each backed by a measured count.
  - [ ] **12.4.3** Apply only the fix(es) 12.4.2 confirmed (honour pending-data flush threshold / reuse stmt cache / incremental segdir append). **DoD:** 12.4.1 ms/row ≤ 3× the oracle baseline from 12.4.1.
  - [ ] **12.4.4** Re-run the 10 affected files; promote those that now finish to pas-strict in STATUS.txt. **DoD:** each completes < 30 s; any still-failing file has its remaining (non-timeout) cause noted in STATUS.txt.

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

- [X] **13.2** Crash-vs-divergence classifier
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

17. **`external 'c'` scalar params use the `ctypes` aliases, not ad-hoc Pascal
    widths.** Map C scalar types to the canonical aliases: `cint` ← `int`,
    `clong` ← `long`, `csize_t` ← `size_t`, `coff_t` ← `off_t`. Do NOT reach for
    `NativeInt`/`NativeUInt`/`i32`/`Integer` — on x86_64 LP64 they happen to be
    width-equivalent so it compiles, but it (a) silently drifts when the same C
    function is bound in two places and (b) is a portability bug off LP64.
    Concentrate shared libc bindings in **one** unit so there is a single source
    of truth — the FILE* stdio family (`fopen`/`fclose`/`fread`/`fwrite`/`fseek`/
    `ftell`/`fflush`/`rewind`/`fprintf`, plus `PFILE`/`stdout`) lives in
    `passqlite3os.pas` (interface), shared by the csv/fileio/zipfile/vfslog/
    tmstmpvfs extensions and the shell. `UnixType` (already used by os.pas)
    exports `cint`/`clong`/`csize_t`; do not add `ctypes` alongside it (the two
    units both define those names and will clash).

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
