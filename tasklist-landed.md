# Landed-task archive (Phases 6–9)

Forensic record of completed task postmortems compressed out of
`tasklist.md` to keep agent context lean.  Each entry lists the task
ID, the original Landed/postmortem text verbatim, and the commit SHA
when known.  Cross-cutting lessons that future tasks need are also
mirrored into `~/.claude/projects/-home-bpsa-app-pas-sqlite3/memory/`
(MEMORY.md index).

---

## Phase 6 — Code generators

### 6.28.6.b — PRAGMA integrity_check higher-level walk

Higher-level `PRAGMA integrity_check` walk arms — pragma.c:1792..2194.
Landed: index-row-count cross-check, full row walk (NOT NULL + STRICT
exact-type + non-STRICT TEXT/numeric checks + WITHOUT-ROWID key-order
check), CHECK constraint arm, per-index validation (missing /
imprecise-float / rowid-position / collation-mismatch), UNIQUE
duplicate detection.  Vtab xIntegrity dispatch (the second-pass
`OP_VCheck` loop at pragma.c:2163..2193 under
`#ifndef SQLITE_OMIT_VIRTUALTABLE`) lives under **6.28.6.c**.  Full
integrity walk now reported for clean DBs, non-vtab corruption, and
vtab xIntegrity error rows.

### 6.28.6.c.1 — FK referential walk (DROPPED 2026-05-13)

Phantom cite. Audit of `../sqlite3/src/pragma.c` 1695..2230 (SQLite
3.53.0) shows `PragTyp_INTEGRITY_CHECK` carries no FK walk; the only
`pFKey` references in that file live inside `PragTyp_FOREIGN_KEY_LIST`
(1511) and `PragTyp_FOREIGN_KEY_CHECK` (1568..1600), which are separate
pragmas.  Lines 2156..2194 originally cited here are actually the
OP_Next loop tail + the vtab `OP_VCheck` arm (the real target of
6.28.6.c.2).  If `PRAGMA foreign_key_check` codegen turns out to be
unported, file it as a new bullet **6.28.6.d** with cite pragma.c:
1541..1651 — but that's a separate pragma, not part of integrity_check.

### 6.28.6.c.2 — vtab xIntegrity dispatch

vtab `xIntegrity` dispatch — per-table second-pass arm that emits
`OP_VCheck p1=iDb, p2=errReg, p3=isQuick, p4=pTab(P4_TABLEREF)`;
runtime body (vdbe.c:8409, already ported under 6.bis.3d) invokes
`pModule^.xIntegrity(pVTab, zSchema, zTabName, mFlags, &zErr)`.
Cite: pragma.c **2163..2193** (gated by `#ifndef SQLITE_OMIT_VIRTUALTABLE`);
ported faithfully into `passqlite3codegen.pas` after the 6.28.6.b
row/index walk.  Uses `eTabType=TABTYP_VTAB` for `IsVirtual`,
`tabFlags & TF_Imposter` for the skip predicate,
`sqlite3HashFind(@db^.aModule, …)` re-lookup when `nCol<=0`,
`sqlite3ViewGetColumnNames` to drive declaration, `iVersion>=4` +
non-NULL `xIntegrity` gates, then `OP_VCheck` + `Inc(nTabRef)` +
`OP_IsNull/ResultRow/IfPos/Halt` (integrityCheckResultRow inline at
pragma.c:385).  `xIntegrity` slot already lived on `TSqlite3Module`
(passqlite3vtab.pas:176).  Build clean; TestSQLCorpus delta = 0
(24 strict divergences identical to baseline).

---

## Phase 9.1 — TestSQLCorpus

### 9.1.3.followup — full MANIFEST coverage

Full MANIFEST coverage via `src/tests/SQLLiteralExtractor.pas` (parses
`Add(...)`/`Probe(...)` plus label-less anchors). 51 tier-1+tier-2
entries, 2259 scripts; first-pass surfaced 52 divergences cataloged to
`src/tests/DIVERGENCES.md` (skip-and-cite contract).

### 9.1.4 — Determinism scrub

`CorpusOracle.ApplyHeaderMask` zeros 4 verified byte ranges (24..27
change counter, 56..59 text encoding default, 92..95 version-valid-for,
96..99 SQLITE_VERSION_NUMBER); justifications in
`src/tests/corpus/MASK.md`. Mask flipped db-blob channel on; cumulative
divergence count 52 → 77, all in `DIVERGENCES.md`.

### 9.1.divbug.1..8 — corpus triage clusters

- **divbug.1** RELEASE-without-SAVEPOINT errmsg wording (44 sites) —
  OP_Savepoint not-found arm now formats `"no such savepoint: %s"` via
  sqlite3VdbeError variadic formatter (vdbe.c:3902 parity).
- **divbug.2** PRAGMA mmap_size / journal_mode output shape (3 sites)
  — default table seeds `mmap_size=0`; `journal_mode` read arm queries
  the actual pager instead of hard-coding `"memory"` (pragma.c:951..978
  / 734..771).
- **divbug.3** DROP INDEX errmsg truncation (1 site) — `"no such
  index: %s"` formatted via sqlite3MPrintf (build.c:4614 parity).
- **divbug.4..8** Five DiagAnalyze/FeatureProbe/Dml/DropTable/Bloom
  sites — single root cause: `sqlite3WritableSchema` was reading bit
  `0x20` (SQLITE_CacheSpill) instead of `0x01` (SQLITE_WriteSchema,
  sqliteInt.h:1829), so `sqlite3CheckObjectName` short-circuited on
  writable_schema=ON. Bit-mask fix at codegen.pas:36421 + companion
  shell `paramTableInit` toggle of SQLITE_DBCONFIG_WRITABLE_SCHEMA
  around `CREATE TABLE IF NOT EXISTS temp.sqlite_parameters`
  (shell.c.in:2964).

### 9.1.6 — Coverage check

Coverage hook lives in `passqlite3vdbe.pas:gVdbeOpCoverage[]` /
`gVdbeOpCoverageEnabled` (single predictable branch in the dispatcher,
default-off zero cost).  `bin/TestSQLCorpus --coverage` flips the flag,
runs the corpus + 14-script coverage-driver inline set, then asserts
every cold opcode is allow-listed in `IsCoverageGap`.  Snapshot: 145
hot / 47 catalogued in `src/tests/corpus/COVERAGE_GAPS.md` / 0 real
cold.  Allow-list entries each cite the planner shape that gates them.

### 9.1.6.followup — categorize cold opcodes

Categorize the 47 cold opcodes currently allow-listed in
`src/tests/corpus/COVERAGE_GAPS.md` into either (a) gated on an
unported feature → cite the Phase 6/7/8 bullet (e.g. FTS5, R-tree,
STAT4, PMA disk-spill 5.7.b) and keep allow-listed; or (b) reachable
from current `passqlite3codegen.pas` paths → land a targeted `.sql`
driver and drop from the allow-list.  Goal: shrink the allow-list to
(a)-only so it stops being a silent escape hatch for new gaps.  Split:
45 (a) gated + 2 (b) driven hot (`OP_IsTrue` via `v IS TRUE`/`v IS
FALSE` in result list → cv17; `OP_MemMax` via `INTEGER PRIMARY KEY
AUTOINCREMENT` INSERT → cv17).  Four additional REAL-cold opcodes
surfaced during triage and were closed in the same pass: `OP_String`
(cv14 multi-row string-literal SELECT), `OP_RealAffinity` (cv15 REAL
column read), `OP_Pagecount` and `OP_MaxPgcnt` (cv16 PRAGMA page_count
/ max_page_count).  Coverage drivers grew 14 → 18.  Every (a) row in
`COVERAGE_GAPS.md` now carries a per-opcode citation
(CoverageGapReason in TestSQLCorpus.pas) pointing at the gating Phase
bullet (6.8 vtab, 6.28 vacuum, 6.28.6.b integrity walk, 10.1.42.b.7
STAT4, planner-shape heuristic, shared-cache / cursor-hints
build-disabled, etc.).  Coverage report now also runs even on
pre-existing strict divergences (ReportCoverage moved above the
strict-gate Halt) so the coverage gate keeps surfacing new gaps when
other buckets are open.  Final: 147 hot / 45 cold-allow / 0 cold-real.

---

## Phase 9.2 — TestReferenceVectors

### 9.2.divbug.A — Read-only open trips SQLITE_READONLY

Root cause: `btreeBeginTrans` (`passqlite3btree.pas:6341`) gated
SQLITE_READONLY on `BTS_READ_ONLY` alone, omitting the `wrflag <> 0`
conjunct present in `../sqlite3/src/btree.c:3622`.  Fix: add the
`wrflag` conjunct so read transactions on read-only btrees succeed.
Lifting the bucket-A umbrella surfaced bucket-F (PRAGMA auto_vacuum RO
returns 0 instead of 1/2), bucket-G (PRAGMA encoding RO garbled),
bucket-H (WITHOUT ROWID RO sweep aborts mid-schema), bucket-I
(round-trip cell-layout drift on wal/multipage/generated-column) and
bucket-J (round-trip trigger-fire EAccessViolation), all triaged below.
Memory: `feedback_btree_readonly_wrflag_gate`.

### 9.2.divbug.F — PRAGMA auto_vacuum RO returns 0

Sites: autovacuum.db, incrvacuum.db.  Root cause:
`passqlite3codegen.pas` `sqlite3Pragma` stubbed auto_vacuum to a
constant `OP_Integer 0` (the "constant-default integer pragmas"
fallback) and never called into the btree layer, so even though
`lockBtree` populated `pBt^.autoVacuum` from header bytes 36..39
correctly, the pragma codegen ignored it.  Fix: drop auto_vacuum from
the constant-stub table and add a proper read arm that runs
`sqlite3ReadSchema` then `sqlite3BtreeGetAutoVacuum(pBt)`, mirroring
`pragma.c:801`.  incrvacuum.db now passes TestVectorReadOnly;
autovacuum.db still pas-skips on bucket-B (script-trailing VACUUM).

### 9.2.divbug.G — PRAGMA encoding RO garbled UTF-8

1 site: utf16.db.  Two root causes: (a) `passqlite3codegen.pas`
`sqlite3Pragma` encoding read arm hard-wired `'UTF-8'` regardless of
`db^.enc`; (b) `OP_String8` in `passqlite3vdbe.pas` tagged the literal
UTF-8 bytes with `pOut^.enc := enc` (db's enc) without converting
them, so when db^.enc=UTF-16LE every string literal carried mis-tagged
bytes and column_text returned garbled output.  Fix: (a) make the
encoding arm read `db^.enc` and emit `UTF-16le` / `UTF-16be` / `UTF-8`;
(b) port the `vdbe.c:1419..1436` arm — when `enc != SQLITE_UTF8`,
`sqlite3VdbeMemSetStr(SQLITE_UTF8) + sqlite3VdbeChangeEncoding(enc)`
then rewrite `pOp^.p4.z` to the converted buffer (P4_DYNAMIC).
PRAGMA encoding now returns `UTF-16le` correctly; utf16.db still
pas-skips on a separate `hex(<utf16-text>)` byte-order bug (now tracked
as bucket-K, unrelated).

### 9.2.divbug.H — WITHOUT ROWID count(*) fast path CORRUPT

WITHOUT ROWID RO sweep emits first 5 rows then errors `database disk
image is malformed` (rc=11) — fixed.  Root cause: the simple-`count(*)`
codegen fast path in `sqlite3Select` opened `pTab^.tnum` with no
P4_KEYINFO; for a WITHOUT ROWID table that root IS the PK index
(mxRecord-keyed), and a table-cursor without KeyInfo decoded the cells
as intkey and aborted with SQLITE_CORRUPT.  Ported select.c:8793..8814:
when `not HasRowid(pTab)` force `pBest := sqlite3PrimaryKeyIndex` and
attach `sqlite3KeyInfoOfIndex` via `sqlite3VdbeChangeP4(..., P4_KEYINFO)`.
Verified: `bin/TestVectorReadOnly` / `bin/TestVectorRoundTrip` both
byte-identical on withoutrowid.db (130 / 8192 bytes).  Schema-change
still pas-skips on bucket-D (adjacent CREATE INDEX byte divergence,
unrelated codegen).

### 9.2.divbug.I — Round-trip cell-layout drift (4 sites)

wal / multipage / generated-column / triggers.  Root cause was TWO bugs
masquerading as cell-packing drift:

1. Generated-column STORED expressions referencing the IPK column
   (`d INTEGER AS (a*b) STORED` where `a` is INTEGER PRIMARY KEY) read
   from the SoftNull'd row-storage slot for `a` instead of the rowid
   register, so `d` persisted NULL.  C's resolve.c lookupName maps
   iPKey column refs to iColumn=-1; the Pascal resolver leaves the
   raw column index in place.  Fixed by extending the iSelfTab<0 arm
   in codegen.pas:5689 to alias `iColumn == y.pTab^.iPKey` to the
   rowid register (same slot the existing iColumn<0 case already
   returns).  Faithful surface for expr.c:5026..5074.
2. `printf('%.*c', N, 'X')` in both `sqlite3VXPrintf` and the
   `printfFunc` scalar ignored precision and emitted one character.
   C's printf.c:769..790 etCHARX arm treats precision >1 as a repeat
   count.  WAL / multipage / triggers mutators build 1000-byte rows
   via `printf('%.*c',1000,...)`; without the repeat fix Pas stored
   1-byte rows and the cell-content area diverged by 1000+ bytes per
   page.  Fixed in printf.pas:1255 and codegen.pas:50334.

All four vectors now round-trip byte-identical against upstream
`../sqlite3/sqlite3`.  `bin/TestVectorRoundTrip` gated=5 ok=5
diverged=0; RO probe gated=5 ok=5; schema-change probe gated=4 ok=4.

### 9.2.divbug.J — Round-trip trigger-fire EAccessViolation

triggers.db crashes with EAccessViolation when the BEFORE/AFTER row
triggers fire.  FIXED: `sqlite3VdbeClearObject` released
`aMem`/`aVar`/`pVList`/`pFree` unconditionally, but trigger sub-vdbes
(`codeRowTrigger`) never transit `VdbeMakeReady` and are deleted while
still in `VDBE_INIT_STATE`, so those fields hold raw-malloc garbage
(`VdbeCreate` only zeroes from `aOp` onwards — vdbeaux.c:30).  Gated
the release block on `eVdbeState != VDBE_INIT_STATE` to mirror
vdbeaux.c:3747..3751.  triggers.db now runs cleanly; its remaining
db-blob divergence (byte 8185) is bucket-I cell-layout drift,
re-classified in MANIFEST.

### 9.2.divbug.C — ALTER TABLE RENAME on VIEW-dependent table AV

Root cause: `sqlite3CreateView` always reduced the stored view body
(`EXPRDUP_REDUCE`); when `renameTableTest` / `renameColumnFunc` later
ran `sqlite3SelectPrep` on it, the resolver wrote
`iColumn`/`iTable`/`y.pTab` past the end of EP_TokenOnly/EP_Reduced
allocations and trashed the heap.  Fix: under IN_RENAME_OBJECT keep
the FULL-size pSelect (build.c:3041..3046) and call
`sqlite3RenameExprlistUnmap` on pCNames in the failure cleanup; also
gate `ResolveExpr`'s pLeft/pRight recursion behind
`EP_TokenOnly|EP_Leaf` (walker.c:71); finally wire the parser
`expr ::= ID` rule to call `sqlite3RenameTokenMap` on the freshly
allocated Expr (parse.y:1166 tokenExpr) so renameColumnExprCb can
locate the source slice for renameEditSql to rewrite.  view-cte vector
now reaches the trailing VACUUM (bucket-B) cleanly.  Memory:
`feedback_view_body_in_rename_object_must_be_full`.

### 9.2.divbug.D — CREATE INDEX on WITHOUT ROWID byte-different

FIXED: Pas `sqlite3CreateIndex` skipped C build.c:4278..4292's `pPk`
arm that copies the WITHOUT ROWID table's PRIMARY KEY columns into the
index-key suffix.  Only the `pPk==nil` (rowid) tail was wired, so
WITHOUT-ROWID indexes left the PK-suffix
`aiColumn[]`/`azColl[]`/`aSortOrder[]` slots zero-init and every cell
encoded `(c, table[0], table[0])` instead of `(c, a, b)`.  Faithful
port adds the missing arm with inline `isDupColumn` (build.c:2274) so
duplicate PK columns shrink `nColumn` rather than double-encoding.
withoutrowid vector still pas-skips for bucket-B (trailing VACUUM
EAccessViolation), now retagged.

### 9.2.divbug.E — RENAME COLUMN on partial-index byte-different

FIXED: Pas `sqlite3CreateIndex` lacked C build.c:4209
`IN_RENAME_OBJECT` arm that pins `pIndex^.aColExpr := pList` and the
per-column `sqlite3StringToId`/`sqlite3ResolveSelfReference` calls that
rewrite TK_ID → TK_COLUMN.  Without the pin renameColumnFunc's
`else if sParse.pNewIndex` walker (alter.c:1639) walked an empty
aColExpr and never tagged the indexed-column span, so renameEditSql
emitted stale `ON t(val)` text. After fix the partial-index vector is
byte-identical post-RENAME COLUMN; the schema-script still pas-skips
for bucket-B (trailing VACUUM EAccessViolation, unrelated).

### 9.2.divbug.K — UTF-16 hex() byte-swapped pairs

`utf16.db`.  FIXED: Pas `sqlite3_result_text` (+ `_text64`,
`_text16{,le,be}`, `_blob`, `_blob64`) called `sqlite3VdbeMemSetStr`
but never reproduced the post-set `sqlite3VdbeChangeEncoding(pOut,
pCtx->enc)` call from C `setResultStrOrError` (vdbeapi.c:423).  In a
UTF-16 database `pCtx^.enc = SQLITE_UTF16LE`, so the hex digits emitted
by `hexFunc` stayed tagged SQLITE_UTF8 in `pCtx^.pOut`;
`sqlite3_column_text` then handed those raw ASCII bytes back wearing
the UTF-16 label, and the harness re-decoded them as UTF-16 (each pair
of hex digits surfaced as one CJK glyph).  Fix: ported
`setResultStrOrError` faithfully and routed every text/blob result
setter through it (passqlite3vdbe.pas).  Cite: vdbeapi.c:387..427.
`hex(label)` on `utf16.db` now byte-matches the C oracle.  Synthetic
JSON-aggregate tests (TestJson SetupCtx) updated to seed
`ctx.enc := SQLITE_UTF8`, mirroring the C OP_Function init
(vdbe.c:8865).  bucket-M (INSERT round-trip enc bypass) still gated
the vector under pas-skip; K no longer cited.

### 9.2.divbug.L.1 — Port incrVacuumStep

1:1 port of btree.c:4034..4128 (`incrVacuumStep`) added in
passqlite3btree.pas just before `finalDbSize`.  Wired into
`sqlite3BtreeIncrVacuum` (OP_IncrVacuum dispatcher entry) replacing
the previous SQLITE_DONE stub.  Three upstream prerequisite stubs
un-stubbed as part of L.1 (originally flagged by L.2): `ptrmapPageno`
(btree.c:1036..1048, new), `ptrmapPut` (btree.c:1060..1110),
`ptrmapGet` (btree.c:1119..1148), `setChildPtrmaps`
(btree.c:3831..3860); helpers `PTRMAP_PTROFFSET` / `PTRMAP_ISPAGE`
added inline.  FPC quirks: var `pDbPage: PDbPage` collides
case-insensitively with the type → renamed to `pDbPg`; `pPager: PPager`
already renamed to `pPgr` in L.2.  Helpers used: `sqlite3PagerGet` /
`Write` / `Unref` / `GetData` / `GetExtra`, `btreeGetPage`,
`btreeInitPage`, `btreePagecount`, `allocateBtreePage`, `releasePage`,
`relocatePage`, `findCell`, `ptrmapPutOvflPtr`, `saveAllCursors`,
`invalidateAllOverflowCache`, `get4byte`/`put4byte`.  Build clean (92
binaries / 5177 assertions); TestSQLCorpus strict diverge unchanged at
24; TestVectorRoundTrip unchanged (incrvacuum.db remains
pas-skip:bucket-L since auto-vacuum-at-COMMIT is L.3); TestVectorReadOnly
clean.  Bucket-L itself stays open pending L.3 (`autoVacuumCommit`
body).

### 9.2.divbug.L.2 — Port relocatePage + modifyPagePointer

1:1 port of btree.c:3876..3928 (modifyPagePointer) and 3940..4012
(relocatePage) added unit-local (mirroring `static SQLITE_NOINLINE`) in
passqlite3btree.pas right after `setChildPtrmaps`.  Helpers used:
`findCell`, `btreeInitPage`, `xParseCell`, `get4byte`/`put4byte`,
`sqlite3PagerMovepage`, `sqlite3PagerWrite`, `sqlite3PagerIswriteable`,
`btreeGetPage`, `releasePage`, `setChildPtrmaps`, `ptrmapPut`.  FPC
quirk: renamed `pPager`→`pPgr` to avoid type collision.  Note:
`ptrmapPut`, `ptrmapGet`, `setChildPtrmaps` remain runtime stubs — the
new code calls them faithfully and becomes effective once those
un-stub (separate L.x bullets / STUB_INVENTORY).  Build clean; 92
binaries pass 5177 assertions; TestSQLCorpus strict divergence count
unchanged at 24 (no new call sites yet).

### 9.2.divbug.L.3 — Wire autoVacuumCommit body

1:1 port of btree.c:4194..4277 (`autoVacuumCommit`) added in
passqlite3btree.pas right before `sqlite3BtreeIncrVacuum`, with a
forward declaration near the previous stub so
`sqlite3BtreeCommitPhaseOne` can call it.  CommitPhaseOne wiring
(btree.c:4314..4324) now invokes `autoVacuumCommit` when
`pBt^.autoVacuum<>0` and follows up with
`sqlite3PagerTruncateImage(pPager, pBt^.nPage)` when `bDoTruncate` is
armed.  `btreeEndTransaction` un-stubbed to clear `pBt^.bDoTruncate`
per btree.c:4342.  Helpers exercised: `invalidateAllOverflowCache`,
`btreePagecount`, `PTRMAP_ISPAGE`/`PENDING_BYTE_PAGE`, `finalDbSize`,
`incrVacuumStep`, `saveAllCursors`, `sqlite3PagerWrite`/`PagerRollback`,
`put4byte`, plus the `db^.xAutovacPages` callback cast via local
`TxAutovacPagesProc`.  Build clean (92 binaries / 5177 assertions);
TestSQLCorpus strict diverge unchanged at 24.  Round-trip evidence:
incrvacuum.db now truncates the trailing freelist page on
PRAGMA incremental_vacuum (28 672→24 576 bytes, matching C size);
autovacuum.db's auto-vacuum-at-COMMIT path executes and produces
matching page count, but full byte parity still blocked by residual
stale-slot/ptrmap-cell scratch bytes (page-cleanup hygiene; unrelated
to L wiring), so parent bucket-L stays open on that narrowed
page-cleanup symptom.  Bucket-B unchanged: bare `VACUUM;` on
autovacuum.db still EAccessViolations inside the existing
`runVacuumImpl`/auto-vacuum-target path; per L.3 task scope this is
filed as a separate diagnosis (runVacuum-side, not commit-side).

### 9.2.divbug.M — UTF-16 INSERT raw-UTF-8 (CLOSED 2026-05-13)

CLOSED — no longer reproducible after **9.2.divbug.K** (commit 6fd9ec2
routed all `sqlite3_result_text*`/`_blob*` setters through
`setResultStrOrError`, which now calls
`sqlite3VdbeChangeEncoding(pOut, pCtx^.enc)` per vdbeapi.c:387..427).
Verified: active cells in utf16.db cell-content area are byte-identical
to C oracle (`café-x` → `63 00 61 00 66 00 e9 00 2d 00 78 00`);
file-header enc tag = UTF-16LE. Residual round-trip divergence on
utf16.db is unrelated and re-filed as **9.2.divbug.N**.

### 9.2.divbug.N — Freeblock/dead-cell zeroing (CLOSED 2026-05-13)

NOT a code defect, audit artefact.  Cite: `btree.c:1992..1996`
(`freeSpace` `memset(&data[iStart], 0, iSize)` gated on
`pBt->btsFlags & BTS_FAST_SECURE`) and `btree.c:2695..2699`
(`BTS_SECURE_DELETE` set at open ONLY when `-DSQLITE_SECURE_DELETE` /
`-DSQLITE_FAST_SECURE_DELETE` is defined).  Upstream's plain
`./configure && make` (and the project's `src/tests/build.sh` building
`../sqlite3/libsqlite3.so`) defines NEITHER, so `BTS_FAST_SECURE` stays
clear and the freeblock zero-fill never fires — matching
`passqlite3btree.pas:1346..1350`, which already gates `FillChar` on the
same flag.  The reported `1d 63 00 61 00 66 00 e9 00 0d` ghost at bytes
0x1fe9..0x1ff0 only appeared when `bin/TestVectorRoundTrip` was run
WITHOUT `LD_LIBRARY_PATH=src`, so it loaded
`/lib/x86_64-linux-gnu/libsqlite3.so.0` — the distro-built libsqlite3
which IS compiled with `SQLITE_SECURE_DELETE` (verified
`PRAGMA compile_options` → `SECURE_DELETE`).  Under the regression
harness's `run_regression.sh:15` (which already exports
`LD_LIBRARY_PATH=$SRC_DIR`), both oracles produce byte-identical
post-mutator blobs.  Verification: `LD_LIBRARY_PATH=src
bin/TestVectorRoundTrip` lifts utf16.db from skip → OK, summary
`gated=9 ok=9 diverged=0 skipped=2` (was
`gated=8 ok=8 ... skipped=3`).  No code change; MANIFEST + DIVERGENCES
updated to lift the `pas-skip utf16.db` entry and document the
artefact.  No cross-link benefit to bucket-L: autovacuum.db /
incrvacuum.db diverge on ptrmap / page-count drift, not freeblock
contents — confirmed unchanged by re-running the full regression.

### 9.2.3.followup — cite-aware RT filter

Round-trip parser now cite-aware (mirrors TestVectorSchemaChange's
filter): only `pas-skip` cites that name an RT-relevant bucket trigger
a skip.  Bucket-A (RO umbrella) plus bucket-B/C/D/E/F/G/H/K
(schema-change-only or RO-only) are filtered out.  Result: 3 vectors
previously masked behind bucket-A (`partial-index`, `view-cte`,
`withoutrowid`) now run and pass byte-identically; 3 new RT-only
divergences surfaced and were triaged into bucket-L (auto-vacuum
page-count drift, hits autovacuum + incrvacuum — cross-link to 6.28's
incrVacuumStep) and bucket-M (UTF-16 INSERT stores raw UTF-8 bytes,
utf16.db).  Probe today: gated=8 ok=8 diverged=0 skipped=3 rc=0 (RO
gated=5 ok=5; schema-change gated=4 ok=4 — both still rc=0).  See
`src/tests/vectors/DIVERGENCES.md` bucket-L / bucket-M.

---

## Phase 9.3 — TestFuzzDiff

### 9.3.1 — In-process harness

`src/tests/TestFuzzDiff.pas` is a one-shot CLI
`bin/TestFuzzDiff <input.dbsqlfuzz>`.  `DecodeDatabase` ports
`fuzzcheck.c:decodeDatabase` (+ `isOffset`) faithfully: hex-pair text
decode, `[NNNN]` half-byte cursor jump, `\n--\n` db/SQL split, 4
KiB-aligned `mx` rounding.  CorpusOracle.pas was extended with
`RunCOracleSeeded` / `RunPasOracleSeeded` (same signature as the bare
entry points but skip the workdir wipe so the harness can plant a
non-empty `test.db` first).  Four-channel compare contract: stdout,
stderr, rc, db-blob — db-blob fed through `ApplyHeaderMask` (9.1.4)
before diff.  Exit codes: 0 = identical, 1 = usage/IO, 2 = divergence,
3 = malformed frame.  Smoke gate on hand-built `\n--\nSELECT 1;` and
`\n--\nCREATE TABLE t(x); INSERT ...; SELECT * FROM t;` both PASS
(db_bytes=0 / sql_bytes=10 and =69; all four channels byte-identical).
Seed-corpus sweep is 9.3.2; AFL wiring is 13.1.

### 9.3.2 — Seed corpus import

8 seeds imported into `src/tests/fuzz/seeds/` (`fuzzdata1.db` ..
`fuzzdata8.db`, total ~62 MiB, copied verbatim from
`../sqlite3/test/`).  Sweep results: **8/8 PASS, 0 divergences, 0
buckets**.  Each archive is itself an SQLite db (header `SQLite format
3`) wrapping a fuzz-case row table; the one-shot driver treats each
file as a single dbsqlfuzz frame and decodes the
hex/`[NNNN]`/`\n--\n` structure.  Frame-decode summary: seeds 1/2/3/4/8
yielded non-empty SQL tails (sql_bytes 2.0M..13.7M); seeds 5/6/7
decoded to db-only frames (sql_bytes=0) — both oracles agree
byte-for-byte on all four channels in every case.  No `9.3.divbug.*`
follow-up bullets created (none warranted).  Per-seed run log appended
to `src/tests/DIVERGENCES.md` under a new *TestFuzzDiff seed corpus
sweep* section.  Multi-frame archive splitting (one row per fuzz case
rather than treating the whole archive as one frame) is out of scope
for the one-shot driver; belongs in 13.1 (AFL wiring) or a dedicated
harness.

---

## Phase 10 — CLI shell

### 10.1.40 — .testcase / .check

Capture via fd-level dup2 onto a temp file (same plumbing as `.output`);
`.check` reads it back and compares under default (CR/LF-stripped
memcmp) / --glob / --notglob / --exact.  Fail diagnostic and shellMain
summary line ("%d test(s) run with %d error(s)\n") match upstream
byte-for-byte; rc becomes nTestErr>0.  Tested by TestShellMeta
`check-*` arms.  Deferred: dotCmdError caret-formatted location prefix
(richer than our "Error: ...\n") — kept out of the byte-diff for the
error paths, and the "<<ENDMARK" multi-line PATTERN form (needs
seekable PFILE input).

- **10.1.40.a** `shellDotError` helper landed (caret-formatted location
  prefix mirroring dotCmdError shell.c.in:1815..1844). Two `.check`
  sites routed through it; TestShellMeta `dotcmd-error-caret` arm
  byte-diffs against upstream.
- **10.1.40.a.followup** Remaining `.check`/`.testcase` cluster Error
  sites routed through `shellDotError`. Caveat: upstream's
  cli_output_capture swallows stdout+stderr while a testcase is armed;
  our fd-level capture only redirects fd 1, so cmdCheck cluster errors
  leak to real stderr (extending capture to fd 2 is a separate
  follow-up).
- **10.1.40.b** `<<MARK` heredoc PATTERN form for `.check`
  (shell.c.in:8790..8802); 3 new TestShellMeta arms byte-diffed against
  upstream.

### 10.1.41 — .testctrl

Dispatcher routes through 8.4.1 overloads for OPTIMIZATIONS,
FK_NO_ACTION, PRNG_SEED, PENDING_BYTE, SORTER_MMAP, ASSERT/ALWAYS,
LOCALTIME_FAULT, NEVER_CORRUPT, EXTRA_SCHEMA_CHECKS,
INTERNAL_FUNCTIONS, JSON_SELFCHECK, plus the existing PRNG/BYTEORDER.
Remaining opcodes (BITVEC_TEST, FAULT_INSTALL, IMPOSTER, TUNE,
PARSER_COVERAGE) fall through to the generic isOk=3 stub — those need
callback / coverage infrastructure not yet ported.

### 10.1.42 — .selecttrace / .wheretrace / .treetrace preamble

Command shape + TRACEFLAGS toggle landed: sqlite3TreeTrace /
sqlite3WhereTrace u32 globals now mutate through
sqlite3_test_control(TRACEFLAGS, …).  Trace-emission still gated on
consumer-side blocks in codegen.

**Mask hint convention (verified the hard way across the b.* / a.*
rounds):** mask numbers written into the subtask bodies were HINTS
only — they are often bundle IDs (the planning grouping) rather than
the literal C bit.  Always verify against `sqliteInt.h` (`TREETRACE_*`)
or `whereInt.h` (`WHERETRACE_*`) before stamping a new arm.

### 10.1.42.a — TREETRACE batch postmortems

- **a (batch 1)** select.c: begin/end processing (0x1), after name
  resolution (0x10), generating column names (0x80), flatten (0x4),
  constant propagation (0x2000), WhereBegin/End breadcrumbs (0x2).
  Gated by `{$IFDEF SQLITE_DEBUG}`.
- **a.1** multiSelect / compound flattener — UNION ALL left/right
  (select.c:3011, 3030, mask 0x200).
- **a.2** Post-flatten (select.c:4706, 0x4) + wildcard expansion
  (select.c:6339, 0x8).
- **a.3** Landed: EXISTS-to-JOIN (select.c:7368, 0x100000) inside
  existsToJoin's hoist tail, and "After aggregate analysis %p:"
  (select.c:8442, 0x20).  Upstream masks are 0x20 / 0x100 / 0x200 /
  0x100000 (tasklist's "0x40 / 0x400" were bundle IDs).  Deferred (no
  Pas counterpart yet): havingToWhere (7047, 0x100),
  countOfViewOptimization (7199, 0x200), AggInfo-adjusted prints —
  closed under a.6.
- **a.4** ORDER BY / window-rewrite / DISTINCT→GROUP BY (VERIFIED:
  0x800 "dropping ORDER BY" select.c:7631, 0x40 "after window rewrite"
  :7693, 0x20000 "Transform DISTINCT into GROUP BY" :8192).
- **a.5** Outer-join + FROM-subquery arms (VERIFIED masks: 0x1000
  FULL/LEFT/RIGHT simplifies :7737..7756 — landed a.7; 0x800 omit
  FROM-subquery ORDER BY :7832 — a.8; 0x4000 push-down :8011 +
  unused-result-columns :8030 — a.9; 0x8000 all-FROM analysis :8146
  — a.10; 0x20 Finished-with-AggInfo :8937 — a.6.5).
  flattenSubquery arm + IgnorableOrderby drop deferred.
- **a.6** All 5 sub-arms a.6.1..a.6.5 landed:
  - **a.6.1** `havingToWhere` + `havingToWhereExprCb` (select.c:7047)
    with prerequisite `sqlite3ExprIsConstantOrGroupBy` pair; wired in
    SF_Aggregate+GROUP-BY path (select.c:8422..8431). 0x100.
  - **a.6.2** `countOfViewOptimization` (select.c:7128..7204); wired
    after propagateConstants (7924..7930). 0x200. SQLITE_CountOfView
    constant added.
  - **a.6.3** `optimizeAggregateUseOfIndexedExpr` (select.c:6549..6586);
    wired between sqlite3WhereBegin and assignAggregateRegisters
    (8527..8529, gated on pParse^.pIdxEpr). 0x20.
  - **a.6.4** `aggregateConvertIndexedExprRefToColumn` + walker
    (select.c:6591..6623); wired after sqlite3WhereEnd (8600..8615).
    0x20.
  - **a.6.5** "Finished with AggInfo" 0x20 at sqlite3Select tail
    (select.c:8933..8945); pAggI2 pre-zeroed at entry; printAggInfo +
    aCol/aFunc self-asserts deferred (no host).
- **a.7** Outer-join strength-reduction inline loop (select.c:
  7708..7770) + prerequisites `sqlite3ExprImpliesNonNullRow` /
  `impliesNotNullRow` / `bothImplyNotNullRow` (expr.c:6857..7031) and
  `unsetJoinExpr` (select.c:471..494).  All 4× 0x1000 TREETRACE
  (FULL→RIGHT, LEFT→JOIN, FULL→LEFT, RIGHT→JOIN) under
  `{$IFDEF SQLITE_DEBUG}`.  Wired between linkWindowsForSelect and
  existsToJoin.  SQLITE_SimplifyJoin (0x2000) added.
- **a.8** FROM-clause subquery superfluous-ORDER-BY drop
  (select.c:7822..7838, tag-select-0230).  Honours all 6 C conditions
  plus MATERIALIZED CTE fence + SF_Aggregate skip.  SQLITE_OmitOrderBy
  (0x40000) added; 0x800 prints `omit superfluous ORDER BY on N
  FROM-clause subquery`.  Drops via sqlite3ParserAddCleanup.
- **a.9** `pushDownWhereTerms` (select.c:5125..5286) +
  `disableUnusedSubqueryResultColumns` (5296..5358); wired into FROM-loop
  body after omit-ORDER-BY.  0x4000 arms.  SQLITE_PushDown ($1000) +
  SQLITE_NullUnusedCols ($04000000) added.  Restriction (6c) for
  partition-less window functions conservatively bailed.
- **a.10** all-FROM-clause final-analysis snapshot
  (select.c:8144..8149, mask 0x8000) post count-of-view / pre
  DISTINCT→GROUP BY; prints via sqlite3TreeViewSelect.
- **a.11** top-level superfluous-ORDER-BY drop (select.c:7625..7644,
  IgnorableDistinct, mask 0x800); clears p^.pOrderBy and masks off
  SF_Distinct.
- **a.12** DISTINCT→GROUP BY transform (select.c:8151..8196, mask
  0x20000).  Gates on `selFlags & (SF_Distinct|SF_Aggregate) ==
  SF_Distinct`, inline sqlite3CopySortOrder, ExprListCompare=0,
  SQLITE_GroupByOrder, pWin=nil; on hit: clear SF_Distinct, pGroupBy :=
  Dup(pEList), seed iOrderByCol = i+1, set SF_Aggregate.  Closes a.4
  last deferred arm.

### 10.1.42.b — WHERETRACE batch postmortems

- **b (batch 1)** where*.c: BEGIN/END `addBtreeIdx(%s)`
  (`whereLoopAddBtreeIndex`, 0x800), BEGIN/END `addVirtual()`
  (`whereLoopAddVirtual`, 0x800), Begin/End OR-clause
  (`whereLoopAddOr`, 0x400).  Gated by `{$IFDEF SQLITE_DEBUG}`.
- **b.1** Range-scan cost-estimate (target tasklist mask 0x10; upstream
  actual 0x20).  Landed `Range scan lowers nOut from %d to %d`
  (where.c:2247..2250) at tail of Pas `whereRangeScanEst` — the only
  WHERETRACE arm reachable in the no-STAT4 build this project compiles
  against.  Deferred (STAT4-only): range skip-scan regions (2036),
  STAT4 range scan (2215), equality scan regions (2313), IN row
  estimate (2363) — live inside helpers gated behind
  `SQLITE_ENABLE_STAT4`.  Folds in once b.7 STAT4 family ports.
- **b.2** Subset-cost adjustment in `whereLoopAdjustCost` (mask 0x80,
  where.c:2711/2720) + 4 covering-index decision arms in
  `whereLoopAddBtree` (mask 0x200, where.c:4203/4210/4216/4224).
- **b.3** Vtab constraint enumeration — 5 arms in
  `whereLoopAddVirtual` (mask 0x800, where.c:4720..4794) + 2 in
  `whereLoopAddVirtualOne` (mask 0xffffffff, where.c:4416/4531).
- **b.4** Solver progress in `wherePathSolver` (mask **0x002 / 0x004**,
  NOT 0x80 — verified against sqliteInt.h:1181 / where.c:5857 / :5988 /
  :6032 / :6129).  Landed mask-0x002 arms: "---- begin solver"
  (5857) + sort-cost increase (5988..5991).  mask-0x004 Skip/New/Update/vs
  (6032..6101) + mask-0x002 "---- after round %d" (6129) re-enabled
  in b.8 once wherePathName landed.
- **b.5** OR-vs-AND in `whereLoopAddOr` (mask **0x400** verified,
  matches sqliteInt.h:1191 OR optimization).  Landed per-subterm
  breadcrumb at where.c:4866..4867: `"OR-term %d of %p has %d
  subterms:"`.  Begin/End were in batch b.  Tasklist title mentioned
  "cost compares, pseudo-index selection" — where.c review shows
  whereLoopAddOr itself carries only mask-0x400 breadcrumbs.  The
  0x20000 sub-arm `sqlite3WhereClausePrint(sSubBuild.pWC)`
  (where.c:4868..4870) re-enabled in b.8.
- **b.6** DISTINCT reduction + optimizer-finished epilogue in
  `sqlite3WhereBegin`.  Mask divergence vs tasklist hint: actual
  literals are **0x0080** (sqliteInt.h:1188) for the DISTINCT-reduction
  print (where.c:7118) and **0xffffffff** (any-trace) for the
  "*** Optimizer Finished ***" line (7195).  Block also carries the
  `nRowOut -= 30` body (tag-20250414a).  Build green pre/post both ways.
  Two trailing arms (Solution cost / WHERE clause at end of analysis)
  re-enabled in b.8.
- **b.8** Ported `wherePathName`, `sqlite3WhereTermPrint`,
  `sqlite3WhereClausePrint`, `sqlite3WhereLoopPrint`, helper
  `showAllWhereLoops` (where.c:2375..2520 / 5512..5519 / 6469..6488)
  under `{$IFDEF SQLITE_DEBUG}`.  Added debug-only `cId` +
  `rStarDelta` fields to TWhereLoop (carved from pre-existing
  _pad58..63 region so SizeOf stays at 104 — TestWhereBasic T15 +
  TestWhereStructs WhereLoop.aLTerm@64 untouched).  Stamped cId in
  whereShortCut (6430), template-loop init (6933) and showAllWhereLoops
  (6480).  Seeded `sqlite3WhereDbgRTotalCost` unit shadow
  (TWhereInfo.rTotalCost is WHERETRACE-only in C; adding the field
  would shift TWhereInfo offsets).  Re-enabled 7 deferred arms (closing
  b.4/b.5/b.6 + WHERETRACE_ALL_LOOPS after whereLoopAddAll
  (where.c:7103)).  Build green both ways (default + SQLITE_DEBUG=1,
  5177 assertions); WhereTrace=0x0FFFF on a 2-table EQ-join produced
  expected Skip/New/Update/vs progression matching C oracle.
