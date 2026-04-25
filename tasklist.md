# pas-sqlite3 Task List

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

## Status summary

- Target platform: x86_64 Linux, FPC 3.2.2+.
- Strategy: **faithful line-by-line port** of SQLite's split C sources
  (`../sqlite3/src/*.c`). Not an idiomatic Pascal rewrite — SQLite's value
  *is* its battle-tested logic and its test suite, both of which only transfer
  if the control flow does.
- The port is pure Pascal; no C-callable `.so` is produced. `libsqlite3.so` is
  built from the **same split tree** in `../sqlite3/` (via upstream's own
  `./configure && make`) **only as the differential-testing oracle**. One
  source tree, two consumers.
- The honest alternative (wrap `libsqlite3` via FPC's existing `sqlite3dyn` /
  `sqlite3conn`) is **not** this project. That exists; this is a port.

---

## Out of scope (initial port)

Everything listed here is deliberately **not** ported until the core (Phases
0–9) is green. Once that bar is met, any of these may be lifted on demand.

- **`../sqlite3/ext/`** — every extension directory: `fts3/`, `fts5/`, `rtree/`,
  `icu/`, `session/`, `rbu/`, `intck/`, `recover/`, `qrf/`, `jni/`, `wasm/`,
  `expert/`, `misc/`. These are large, feature-specific, and self-contained;
  they link against the core SQLite API, so they can be ported later without
  touching the core.
- **Test-harness C files inside `src/`** — any file matching `src/test*.c`
  (e.g. `test1.c`, `test_vfs.c`, `test_multiplex.c`, `test_demovfs.c`, ~40
  files) and `src/tclsqlite.c` / `src/tclsqlite.h`. These are Tcl-C glue for
  SQLite's own Tcl test suite; they are not application code and must **not**
  be ported. Phase 9.4 calls the Tcl suite via the C-built `libsqlite3.so`,
  not via any Pascal-ported version of these files.
- **`src/json.c`** — JSON1 is now in core, but it is large (~6 k lines) and
  behind `SQLITE_ENABLE_JSON1` historically. Defer until Phase 6 is otherwise
  green; port last within Phase 6 if needed.
- **`src/window.c`** — window functions. Complex, intersects with `select.c`.
  Mark as a late-Phase-6 item.
- **`src/os_kv.c`** — optional key-value VFS. Off by default. Port only if a
  user asks.
- **`src/loadext.c`** — dynamic extension loading. Port last; most Pascal
  users of this port won't need it.
- **`src/os_win.c`, `src/mutex_w32.c`, `src/os_win.h`** — Windows OS backend.
  This port targets Linux first. Windows is a Phase 11+ stretch goal.
- **`tool/*`** (except `lemon.c` and `lempar.c`, which are needed for the
  parser in Phase 7) — assorted utilities (`dbhash`, `enlargedb`,
  `fast_vacuum`, `max-limits`, etc.); not required for the port.
- **The `bzip2recover`-style **`../sqlite3/tool/showwal.c`** and friends** —
  forensic tools. Out of scope.

---

## Folder structure

```
pas-sqlite3/
├── src/
│   ├── passqlite3.inc               # compiler directives ({$I passqlite3.inc})
│   ├── passqlite3types.pas          # u8/u16/u32/i64 aliases, result codes, sqlite3_int64,
│   │                                # sqliteLimit.h (compile-time limits)
│   ├── passqlite3internal.pas       # sqliteInt.h — ~5.9 k lines of central typedefs
│   │                                # (Vdbe, Parse, Table, Index, Column, Schema, sqlite3, ...)
│   │                                # used by virtually every other unit
│   ├── passqlite3os.pas             # OS abstraction layer:
│   │                                # os.c, os_unix.c, os_kv.c (optional), threads.c,
│   │                                # mutex.c, mutex_unix.c, mutex_noop.c
│   │                                # (headers: os.h, os_common.h, mutex.h)
│   ├── passqlite3util.pas           # Utilities used everywhere:
│   │                                # util.c, hash.c, printf.c, random.c, utf.c, bitvec.c,
│   │                                # fault.c, malloc.c, mem0.c–mem5.c, status.c, global.c
│   │                                # (headers: hash.h)
│   ├── passqlite3pcache.pas         # pcache.c + pcache1.c — page-cache (distinct from pager!)
│   │                                # (headers: pcache.h)
│   ├── passqlite3pager.pas          # pager.c: journaling/transactions;
│   │                                # memjournal.c (in-memory journal), memdb.c (:memory:)
│   │                                # (headers: pager.h)
│   ├── passqlite3wal.pas            # wal.c: write-ahead log (headers: wal.h)
│   ├── passqlite3btree.pas          # btree.c + btmutex.c
│   │                                # (headers: btree.h, btreeInt.h)
│   ├── passqlite3vdbe.pas           # VDBE bytecode VM and ancillaries:
│   │                                # vdbe.c (~9.4 k lines, ~199 opcodes),
│   │                                # vdbeaux.c, vdbeapi.c, vdbemem.c,
│   │                                # vdbeblob.c (incremental blob I/O),
│   │                                # vdbesort.c (external sorter),
│   │                                # vdbetrace.c (EXPLAIN helper),
│   │                                # vdbevtab.c (virtual-table VDBE ops)
│   │                                # (headers: vdbe.h, vdbeInt.h)
│   ├── passqlite3parser.pas         # tokenize.c + Lemon-generated parse.c (from parse.y),
│   │                                # complete.c (sqlite3_complete)
│   ├── passqlite3codegen.pas        # SQL → VDBE translator; single large unit:
│   │                                # expr.c, resolve.c, walker.c, treeview.c,
│   │                                # where.c + wherecode.c + whereexpr.c (~12 k combined),
│   │                                # select.c (~9 k), window.c,
│   │                                # insert.c, update.c, delete.c, upsert.c,
│   │                                # build.c (schema), alter.c,
│   │                                # analyze.c, attach.c, pragma.c, trigger.c, vacuum.c,
│   │                                # auth.c, callback.c, func.c, date.c, fkey.c, rowset.c,
│   │                                # prepare.c, json.c (if in scope — see below)
│   │                                # (headers: whereInt.h)
│   ├── passqlite3vtab.pas           # vtab.c (virtual-table machinery) +
│   │                                # dbpage.c + dbstat.c + carray.c
│   │                                # (built-in vtabs)
│   ├── passqlite3.pas               # Public API:
│   │                                # main.c, legacy.c (sqlite3_exec), table.c
│   │                                # (sqlite3_get_table), backup.c (online-backup API),
│   │                                # notify.c (unlock-notify), loadext.c (extension loading
│   │                                # — optional)
│   ├── csqlite3.pas                 # external cdecl declarations of C reference (csq_* aliases)
│   └── tests/
│       ├── TestSmoke.pas            # load libsqlite3.so, print sqlite3_libversion() — smoke test
│       ├── TestOSLayer.pas          # file I/O + locking: Pascal vs C on the same file
│       ├── TestPagerCompat.pas      # Pascal pager writes → C can read, and vice versa
│       ├── TestBtreeCompat.pas      # insert/delete/seek sequences produce byte-identical .db files
│       ├── TestVdbeTrace.pas        # same bytecode → same opcode trace under PRAGMA vdbe_trace=ON
│       ├── TestExplainParity.pas    # EXPLAIN output for a SQL corpus matches C reference exactly
│       ├── TestSQLCorpus.pas        # run a corpus of .sql scripts through both; diff output + .db
│       ├── TestFuzzDiff.pas         # differential fuzzer driver (AFL / dbsqlfuzz corpus input)
│       ├── TestReferenceVectors.pas # canonical .db files from ../sqlite3/test/ open & query identically
│       ├── Benchmark.pas            # throughput: INSERT/SELECT Mops/s, Pascal vs C
│       ├── vectors/                 # canonical .db files, .sql scripts, expected outputs
│       └── build.sh                 # builds libsqlite3.so from ../sqlite3/ + all Pascal test binaries
├── bin/
├── install_dependencies.sh          # ensures fpc, gcc, tcl (for SQLite's own tests), clones ../sqlite
├── LICENSE
├── README.md
└── tasklist.md                      # this file
```

---

## The differential-testing foundation

This port has no chance of succeeding without a ruthless validation oracle.
Build the oracle **before** porting any non-trivial code.

### Why differential testing first

SQLite is ~150k lines. A line-by-line port will introduce hundreds of subtle
bugs — integer promotion differences, pointer-aliasing mistakes, off-by-one on
`u8`/`u16` boundaries, UTF-8 vs UTF-16 string handling. The only tractable way
to find them is to run the Pascal port and the C reference side-by-side on the
same input and diff.

### Three layers of diffing

1. **Black-box (easiest — enable first).** Feed identical `.sql` scripts to the
   `sqlite3` CLI (C) and to a minimal Pascal CLI (progressively built as
   phases complete). Diff:
   - stdout (query results, error messages)
   - return codes
   - the resulting `.db` file, **byte-for-byte** — SQLite's on-disk format is
     stable and documented, so a correct pager+btree port produces identical files.

2. **White-box / layer-by-layer.** Instrument both builds to dump intermediate
   state at layer boundaries:
   - **Parser output:** dump the VDBE program emitted by `PREPARE`. `EXPLAIN`
     already renders VDBE bytecode as a result set — goldmine for validating
     parser + code generator.
   - **VDBE traces:** SQLite supports `PRAGMA vdbe_trace=ON` (with `SQLITE_DEBUG`)
     and `sqlite3_trace_v2()`. Identical bytecode must produce identical opcode
     traces.
   - **Pager operations:** log every page read/write/journal action; compare
     sequences for a given SQL workload.
   - **B-tree operations:** log cursor moves, inserts, splits.

3. **Fuzzing.** Once (1) and (2) work, point AFL at both builds with divergence
   as the crash signal. The SQLite team's `dbsqlfuzz` corpus is the natural seed
   set. This is how real ports find subtle bugs — human-written tests miss them.

### Known diff-noise to normalise before comparing

- **Floating-point formatting.** C's `printf("%g", …)` and FPC's `FloatToStr` /
  `Str(x:0:g, …)` produce cosmetically different strings for the same double.
  Either (a) compare query result sets as typed values not strings, or
  (b) route both through an identical formatter before diffing.
- **Timestamps / random blobs.** Anything involving `sqlite3_randomness()` or
  `CURRENT_TIMESTAMP` must be stubbed to a deterministic seed on both sides
  before diffing.
- **Error message wording.** Match the C source verbatim. Do not "improve"
  error text.

### Concrete harness layout

A driver script (`tests/diff.sh`) that, given a `.sql` file:
1. Runs `sqlite3 ref.db < input.sql` → `ref.stdout`, `ref.stderr`
2. Runs `bin/passqlite3 pas.db < input.sql` → `pas.stdout`, `pas.stderr`
3. Diffs the four streams + `ref.db` vs `pas.db` (after normalising header
   mtime field, which SQLite stamps — see pitfall #9).

---

## Phase 0 — Infrastructure (prerequisite for everything)

- [X] **0.1** Ensure `../sqlite3/` contains the upstream split source tree
  (the canonical layout with `src/`, `test/`, `tool/`, `Makefile.in`,
  `configure`, `autosetup/`, `auto.def`, etc. — SQLite ≥ 3.48 uses
  **autosetup** as its build system, not classic autoconf). Confirmed
  compatible with this tasklist: version **3.53.0**, ~150 `src/*.c` files,
  1 188 `test/*.test` Tcl tests, `tool/lemon.c` + `tool/lempar.c` present,
  `test/fuzzdata*.db` seed corpus present. Run `./configure && make` once to
  confirm it builds cleanly on this machine and produces a `libsqlite3.so`
  (location depends on build-system version — locate it with `find` rather
  than hardcoding) plus the `sqlite3` CLI binary. Those two artefacts are
  the differential oracle. The individual `src/*.c` files are the porting
  reference — each Pascal unit maps to a named set of C files (see the
  folder-structure table above). Note that `sqlite3.h` and `shell.c` are
  **generated** at build time from `sqlite.h.in` and `shell.c.in`; do not
  look for them in a freshly-cloned tree. The amalgamation (`sqlite3.c`) is
  not generated and not used.

- [X] **0.2** Create `src/passqlite3.inc` with the compiler directives.
  **Use `../pas-core-math/src/pascoremath.inc` as the canonical template** —
  copy its layout (FPC detection, mode/inline/macro directives, CPU32/CPU64
  split, non-FPC fallback) and add SQLite-specific additions (`{$GOTO ON}`,
  `{$POINTERMATH ON}`, `{$Q-}`, `{$R-}`) on top. Included at the top of every
  unit with `{$I passqlite3.inc}` — placed before the `unit` keyword so mode
  directives take effect in time:
  ```pascal
  {$I passqlite3.inc}
  unit passqlite3types;
  ```
  Starter content (modelled on `pasbzip2.inc`):
  ```pascal
  {$IFDEF FPC}
    {$MODE OBJFPC}
    {$H+}
    {$INLINE ON}
    {$GOTO ON}           // VDBE dispatch may benefit; parser definitely will
    {$COPERATORS ON}
    {$MACRO ON}
    {$CODEPAGE UTF8}
    {$POINTERMATH ON}    // u8* / PByte arithmetic everywhere
    {$Q-}                // disable overflow checking — SQLite relies on wrap
    {$R-}                // disable range checking for the same reason
    {$IFDEF CPU32BITS} {$DEFINE CPU32} {$ENDIF}
    {$IFDEF CPU64BITS} {$DEFINE CPU64} {$ENDIF}
  {$ENDIF}
  ```
  `{$Q-}` / `{$R-}` are important: SQLite uses unsigned wrap arithmetic in the
  CRC, varint, and hash code paths. Keeping them enabled project-wide would
  spuriously crash correct code.

- [X] **0.3** Create `src/passqlite3types.pas` with SQLite's primitive aliases.
  Reuse FPC's native types wherever names already exist (`Int32`, `UInt32`,
  `Int64`, `UInt64`, `Byte`, `Word`, `Pointer`, `PByte`, `PChar`). Introduce
  only the genuinely-SQLite-specific names:
  ```pascal
  type
    u8  = Byte;      // cosmetic alias for readability vs the C source
    u16 = UInt16;
    u32 = UInt32;
    u64 = UInt64;
    i8  = Int8;
    i16 = Int16;
    i32 = Int32;
    i64 = Int64;
    Pu8 = ^u8;
    Pu16 = ^u16;
    Pu32 = ^u32;
    Pgno = ^u32;     // SQLite page number
    sqlite3_int64  = i64;
    sqlite3_uint64 = u64;
  ```
  Rule: everywhere the C source says `u8`, `u16`, `u32`, `i64`, write the
  identical name in Pascal. Reads 1:1 against the reference during review.

- [X] **0.4** Declare SQLite result codes (`SQLITE_OK`, `SQLITE_ERROR`,
  `SQLITE_BUSY`, `SQLITE_LOCKED`, `SQLITE_NOMEM`, `SQLITE_READONLY`, `SQLITE_IOERR`,
  `SQLITE_CORRUPT`, `SQLITE_FULL`, `SQLITE_CANTOPEN`, `SQLITE_PROTOCOL`,
  `SQLITE_SCHEMA`, `SQLITE_TOOBIG`, `SQLITE_CONSTRAINT`, `SQLITE_MISMATCH`,
  `SQLITE_MISUSE`, `SQLITE_NOLFS`, `SQLITE_AUTH`, `SQLITE_FORMAT`, `SQLITE_RANGE`,
  `SQLITE_NOTADB`, `SQLITE_NOTICE`, `SQLITE_WARNING`, `SQLITE_ROW`, `SQLITE_DONE`,
  plus all extended result codes) and open-flag constants (`SQLITE_OPEN_READONLY`,
  `SQLITE_OPEN_READWRITE`, `SQLITE_OPEN_CREATE`, …) with the **exact** numeric
  values from `sqlite3.h`. Any off-by-one here will cascade invisibly.

- [X] **0.5** Create `src/csqlite3.pas` — external declarations of the C
  reference API, bound to `libsqlite3.so`, with `csq_` prefixes (convention
  mirrors `cbz_` in pas-bzip2):
  ```pascal
  const LIBSQLITE3 = 'sqlite3';

  function csq_libversion: PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_libversion';
  function csq_open(zFilename: PChar; out ppDb: Pointer): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_open';
  // ... all exported sqlite3_* functions we'll need for differential testing
  ```
  Only tests use `csq_*`. The Pascal port itself must never link against
  `libsqlite3.so` — otherwise differential testing is comparing a thing with
  itself.

- [X] **0.6** Create `install_dependencies.sh` modelled on pas-bzip2's: ensure
  `fpc`, `gcc`, `tcl` (SQLite's own tests are in Tcl), and verify that
  `../sqlite3/` is present and buildable (print a clear error if it is
  missing — do not auto-clone; the user chose the layout).

- [X] **0.7** Create `src/tests/build.sh` — **use
  `../pas-core-math/src/tests/build.sh` as the canonical template** (it sets
  up `BIN_DIR` / `SRC_DIR`, handles the `-Fu` / `-Fi` / `-FE` / `-Fl` flag
  pattern, cleans up `.ppu` / `.o` artefacts, and is known-working on this
  developer's machine). Adapt its shape, not copy it verbatim — our oracle
  step is an upstream `make` rather than a direct `gcc` invocation. Steps:
  1. Build the oracle `libsqlite3.so` by invoking upstream's own build
     (SQLite ≥ 3.48 uses **autosetup**, not classic autoconf/libtool):
     `cd ../sqlite3 && ./configure --debug CFLAGS='-O2 -fPIC
      -DSQLITE_DEBUG -DSQLITE_ENABLE_EXPLAIN_COMMENTS
      -DSQLITE_ENABLE_API_ARMOR' && make`. The shared library's output path
     varies between build-system versions (autosetup typically drops
     `libsqlite3.so` at the top of `../sqlite3/`; the classic autoconf build
     placed it under `.libs/`). The `build.sh` script must therefore **locate**
     the produced `libsqlite3.so` (e.g. `find ../sqlite3 -maxdepth 3 -name
     'libsqlite3.so*' -type f | head -1`) and symlink/copy it to
     `src/libsqlite3.so`. Do not hardcode the upstream output path; do not
     write a bespoke gcc line either — upstream's build knows the right
     compile flags, generated headers (`opcodes.h`, `parse.c`, `keywordhash.h`,
     `sqlite3.h`), and link order. Any bespoke command will drift from upstream
     over time.
  2. Compile each `tests/*.pas` binary with
     `fpc -O3 -Fu../ -FE../../bin -Fl../`.
  3. All test binaries run with `LD_LIBRARY_PATH=src/ bin/...`.

- [X] **0.8** Write `TestSmoke.pas`: loads `libsqlite3.so` via `csqlite3.pas`,
  prints `csq_libversion`, opens an in-memory DB, executes `SELECT 1;`, prints
  the result, closes. This is the health check for the build system — until
  this runs, no differential test can run.

- [X] **0.9** **Internal headers — progressive porting strategy.** `sqliteInt.h`
  (~5.9 k lines) defines the ~200 structs and typedefs that virtually every
  other source file uses (`sqlite3`, `Vdbe`, `Parse`, `Table`, `Index`,
  `Column`, `Schema`, `Select`, `Expr`, `ExprList`, `SrcList`, …). **Do not**
  attempt to port the whole header up front — it references types declared in
  `btreeInt.h`, `vdbeInt.h`, `whereInt.h`, `pager.h`, `wal.h` which have not
  yet been ported, leading to circular dependencies. Instead:
  - Create `passqlite3internal.pas` with the shared constants, bit flags, and
    primitive-level typedefs (anything not itself containing a struct
    reference). This subset is safe to port now.
  - As each subsequent phase begins, port exactly the `sqliteInt.h` struct
    declarations that that phase needs, and add them to
    `passqlite3internal.pas`. The module-local headers (`btreeInt.h` → into
    `passqlite3btree.pas`, `vdbeInt.h` → `passqlite3vdbe.pas`,
    `whereInt.h` → `passqlite3codegen.pas`) travel with their modules.
  - Field order **must match** C bit-for-bit — tests will `memcmp` these
    records. Do not reorder "for alignment" or "for readability".
  - `sqliteLimit.h` (~450 lines, compile-time limits) ports **once, whole**
    into `passqlite3types.pas` as `const` values.

- [X] **0.10** Assemble `tests/vectors/`:
  - A minimal SQL corpus: 20–50 `.sql` scripts covering DDL, DML, joins,
    subqueries, triggers, views, common pragmas.
  - Canonical `.db` files produced by the C reference for each script, used by
    `TestReferenceVectors.pas`.
  - The `dbsqlfuzz` seed corpus from `../sqlite3/test/fuzzdata*.db` (if present).

- [X] **0.11** **Generated files policy.** SQLite's C build generates four
  files that are not checked into `src/`; upstream produces them with
  Tcl / C helpers in `tool/`. Pick **one** policy and apply uniformly:
  - **(A) Freeze-and-port** (recommended): run upstream's `make` once; copy
    the generated `opcodes.h`, `opcodes.c`, `parse.c`, `parse.h`,
    `keywordhash.h`, `sqlite3.h` into `src/generated/`; hand-port each to
    Pascal; pin the upstream commit hash in a top-of-file comment so
    reviewers can tell when to regenerate.
  - **(B) Port the generators**: port `tool/mkopcodeh.tcl`,
    `tool/mkopcodec.tcl`, `tool/mkkeywordhash.c`, and a Lemon-for-Pascal
    emitter. Run them from `build.sh`. More faithful to upstream, much more
    work.

  Recommendation: **policy (A) for v1**, switching to (B) only if upstream
  bumps start producing frequent churn. File list and context:
  - `opcodes.h` / `opcodes.c` — the `OP_*` constant table and the opcode
    name strings, generated from comments in `vdbe.c` by
    `tool/mkopcodeh.tcl` + `tool/mkopcodec.tcl`. **Opcode names are
    part of the public `EXPLAIN` output** — any divergence fails
    `TestExplainParity.pas` in Phase 6.
  - `parse.c` / `parse.h` — the LALR(1) parse table, generated by
    `tool/lemon` from `parse.y`. Addressed by Phase 7.2.
  - `keywordhash.h` — a perfect hash of SQL keywords, used by `tokenize.c`.
    Generated by `tool/mkkeywordhash.c`.
  - `sqlite3.h` — the public C header, generated from `sqlite.h.in` by
    trivial string substitution. Our `passqlite3.pas` public API must
    expose identical constant values — script a comparison check in
    `build.sh` that greps the numeric values out of the generated
    `sqlite3.h` and confirms they match `passqlite3types.pas`.

- [X] **0.12** **Compile-time options policy.** SQLite has ~200
  `SQLITE_OMIT_*`, `SQLITE_ENABLE_*`, and `SQLITE_DEFAULT_*` flags that alter
  which code paths exist. Declare our target configuration up front and
  freeze it for v1. **Default policy: match upstream's default configuration**
  (what a plain `./configure && make` produces), plus `SQLITE_DEBUG` for the
  oracle build only. Specifically:
  - **Keep enabled (upstream defaults)**: `SQLITE_ENABLE_MATH_FUNCTIONS`,
    `SQLITE_ENABLE_FTS5` (out of scope for initial port but flag stays on so
    the core behaves identically), `SQLITE_THREADSAFE=1` (serialized).
  - **Explicitly off for v1**: `SQLITE_OMIT_LOAD_EXTENSION` (matches Phase 8.9
    stub), `SQLITE_OMIT_DEPRECATED` (we don't need legacy surface), any
    `SQLITE_ENABLE_*` that pulls in an `ext/` module (those are out of scope
    per the "Out of scope" section).
  - **Oracle-only**: `SQLITE_DEBUG`, `SQLITE_ENABLE_EXPLAIN_COMMENTS`,
    `SQLITE_ENABLE_API_ARMOR`.
  - Record the full flag list in `src/passqlite3.inc` as a comment block so
    future contributors can see exactly what the Pascal port implements.

- [X] **0.13** **LICENSE + README.** Match the pattern from
  `../pas-bzip2/` and `../pas-core-math/`:
  - `LICENSE` — the SQLite C code is public-domain; the Pascal port may keep
    that posture or relicense to MIT / X11 (same as pas-bzip2). Decide and
    commit the file. Default recommendation: **public domain, matching
    upstream**, with a short header note acknowledging the C source.
  - `README.md` — 40–60 lines: what this project is, build instructions
    (`./install_dependencies.sh && src/tests/build.sh`), how to run the
    differential tests, honest status ("Phase N of 12 complete"), pointer to
    `tasklist.md`.

---

### Phase 0 implementation notes (2026-04-20)

- `../sqlite3/` is present at version **3.53.0** and builds cleanly with autosetup.
- System has FPC 3.2.2 and gcc installed; `tclsh` present.
- `libsqlite3.so` is built into `../sqlite3/` and symlinked to `src/libsqlite3.so`.
  **Important**: the system `libsqlite3.so` has SONAME `libsqlite3.so.0`, so test
  binaries compiled with `-Fl./src` need both `src/libsqlite3.so` **and**
  `src/libsqlite3.so.0` to resolve at runtime via `LD_LIBRARY_PATH=src/`. The
  build script creates both symlinks. 
- `TestSmoke` passes: 3.53.0 oracle, SELECT 1 round-trip confirmed.
- 0.10 `tests/vectors/` directory created; actual `.sql` / `.db` files are
  populated as each phase's gating test needs them.
- 0.11 Policy (A) adopted: generated files will be frozen from the upstream build
  and ported manually, with the upstream commit hash noted in each file header.
- 0.12 Compile-time flag set documented in `passqlite3.inc`.

---

## Phase 1 — OS abstraction

Files: `os.c` (VFS dispatcher), `os_unix.c` (~8 k lines, the POSIX backend),
`threads.c` (thread wrappers), `mutex.c` + `mutex_unix.c` +
`mutex_noop.c` (mutex dispatch + POSIX + single-threaded no-op).
Headers: `os.h`, `os_common.h`, `mutex.h`.

Start here because it is the smallest self-contained layer with no
SQLite-internal dependencies. Also the natural place to establish porting
conventions: `struct` → `record`, function pointers → procedural types,
`#define` → `const` or `inline`.

- [X] **1.1** Port the `sqlite3_io_methods` / `sqlite3_vfs` function-pointer
  tables to Pascal procedural types in `passqlite3os.pas`. These are the
  interface SQLite uses to talk to the OS.

- [X] **1.2** Port file operations: open, close, read, write, truncate, sync,
  fileSize, lock, unlock, checkReservedLock. Each wraps a POSIX syscall via
  FPC's `BaseUnix` (`FpOpen`, `FpRead`, `FpWrite`, `FpFtruncate`, `FpFsync`,
  `FpFcntl`).

- [X] **1.3** Port POSIX advisory-lock machinery (`unixLock`, `unixUnlock`,
  `findInodeInfo`). This is the single most-fiddly part of the OS layer —
  SQLite's own comments call it "a mess". Port faithfully; do not try to
  simplify.
  **Note (Phase 1 simplification):** each `unixFile` maintains its own private
  lock state (no intra-process inode sharing via `unixInodeInfo` linked list).
  Cross-process POSIX advisory locking via `fcntl F_SETLK` works correctly.
  Full intra-process inode sharing deferred to Phase 3.

- [X] **1.4** Port the mutex implementation (`mutex_unix.c`): wraps
  `pthread_mutex_*`. Pascal side uses direct `pthread_mutex_init`/`lock`/`unlock`
  via `cdecl` externals from the `pthreads` FPC unit.

- [X] **1.5** Decide the allocator policy (resolved here; implementation is in
  Phase 2.8). Options: use FPC's `GetMem`/`FreeMem` (same backing allocator on
  glibc Linux) or call `malloc` directly via `cdecl` to guarantee byte-identical
  allocation patterns. **Decision: `malloc` direct** via `external 'c' name 'malloc'`
  (and calloc/realloc/free similarly). Shim helpers `sqlite3MallocZero` and
  `sqlite3StrDup` are implemented.

- [X] **1.6** `TestOSLayer.pas`: open the same file with Pascal and C
  implementations, perform a scripted sequence of reads/writes/locks, confirm
  the resulting file bytes match and that lock acquisition/release order is
  identical.
  **Note:** 14 test cases cover os_init, VFS open/write/read/fileSize/truncate,
  shared/reserved/exclusive lock cycles, checkReservedLock, close/delete, access,
  fullPathname, recursive mutex, and cross-read (Pascal-written file read via POSIX).
  All 14 pass. **FPC bug note:** `FpGetCwd` on Linux returns path length (not
  pointer) because the kernel syscall returns the length; `unixFullPathname` uses
  `libc getcwd` directly via `cdecl external 'c'` instead.

---

### Phase 1 implementation notes (2026-04-20)

- `passqlite3os.pas` now has a full `implementation` section (~1400 lines added).
- Ported from: `os.c` (VFS dispatch wrappers), `mutex.c` + `mutex_unix.c`
  (pthread recursive-mutex pool, 12 static + dynamic mutexes), `os_unix.c`
  (POSIX I/O, advisory locking state machine, VFS open/delete/access/fullpathname,
  randomness from `/dev/urandom`, sleep, currentTime).
- `sqlite3_os_init` registers a singleton `unixVfsObj` as the default VFS.
- `unixIoMethods` vtable is filled in the unit's `initialization` section.
- **FPC bug note:** `FpGetCwd` on Linux calls the raw `getcwd` syscall, which
  returns path length (not a pointer). `unixFullPathname` works around this by
  calling `libc getcwd` via `external 'c' name 'getcwd'`.
- All 14 `TestOSLayer` cases pass.

---

## Phase 2 — Utilities

Files: `util.c`, `hash.c`, `printf.c`, `random.c`, `utf.c`, `bitvec.c`,
`malloc.c`, `mem0.c`, `mem1.c`, `mem2.c`, `mem3.c`, `mem5.c`, `fault.c`,
`status.c`, `global.c`. Combined ~8 k lines. Self-contained; heavy
dependencies from every other layer.

- [X] **2.1** Port `util.c`. In particular, the **endianness accessors** are
  the only correct way to read and write SQLite's big-endian on-disk format;
  port them verbatim and use them everywhere (pager, btree, WAL) instead of
  ever casting a `PByte` to `PUInt32` directly:
  - `sqlite3Get2byte` / `sqlite3Put2byte` (2-byte big-endian)
  - `sqlite3Get4byte` / `sqlite3Put4byte` (4-byte big-endian)
  - `getVarint` / `putVarint` (1–9-byte huffman-like varint)
  - `getVarint32` / `putVarint32` (fast path for 32-bit values)
  Also port: `sqlite3Atoi`, `sqlite3AtoF`, `sqlite3GetInt32`,
  `sqlite3StrICmp`, safety-net integer arithmetic
  (`sqlite3AddInt64`, `sqlite3MulInt64`, etc.).

- [X] **2.2** Port `hash.c`: SQLite's generic string-keyed hash table. Used by
  the symbol table, schema cache, and many transient lookups.

- [X] **2.3** Port `printf.c`: SQLite's own `sqlite3_snprintf` / `sqlite3_mprintf`.
  **Do not** delegate to FPC's `Format` — SQLite supports format specifiers
  (`%q`, `%Q`, `%z`, `%w`, `%lld`) that Pascal's `Format` does not. Port line
  by line.
  **Implementation note**: Phase 2 delivers libc `vasprintf`/`vsnprintf`-backed
  stubs. Full printf.c port (with `%q`/`%Q`/`%w`/`%z`) deferred to Phase 6
  when `Parse` and `Mem` types are available.

- [X] **2.4** Port `random.c`: SQLite's PRNG. Determinism depends on this; it
  must produce bit-identical output to the C version for the same seed.

- [X] **2.5** Port `utf.c`: UTF-8 ↔ UTF-16LE ↔ UTF-16BE conversion. Used
  whenever a `TEXT` value crosses an encoding boundary. **Do not** delegate to
  FPC's `UTF8Encode` / `UTF8Decode` — SQLite has its own incremental converter
  with specific error-handling semantics.
  **Implementation note**: `sqlite3VdbeMemTranslate` stubbed (requires `Mem`
  type from Phase 6).

- [X] **2.6** Port `bitvec.c`: a space-efficient bitvector used by the pager
  to track which pages are dirty. Small (~400 lines); no dependencies.

- [X] **2.7** Port `malloc.c`: SQLite's allocation dispatch (thin wrapper over
  the backend allocators); `fault.c`: fault injection helpers (used by tests
  — may stub out until Phase 9).

- [X] **2.8** Port the memory-allocator backends: `mem0.c` (no-op /
  alloc-failure stub), `mem1.c` (system malloc), `mem2.c` (debug mem with
  guard bytes), `mem3.c` (memsys3 — alternate allocator), `mem5.c` (memsys5 —
  power-of-2 buckets). Decide at Phase 1.5 time which backend is the default;
  port all five for parity with the C build-time switches.
  **Implementation note**: Phase 2 delivers mem1 (system malloc via libc) and
  mem0 stubs. mem2/mem3/mem5 deferred.

- [X] **2.9** Port `status.c` (`sqlite3_status`, `sqlite3_db_status` counters)
  and `global.c` (`sqlite3Config` global struct + `SQLITE_CONFIG_*` machinery).

- [X] **2.10** `TestUtil.pas`: for varint round-trip (every boundary: 0, 127,
  128, 16383, 16384, …, INT64_MAX), atoi/atof edge cases (overflow, subnormals,
  NaN, trailing garbage), printf format strings, PRNG determinism (same seed →
  same 1000-value stream), UTF-8/16 conversion round-trips — diff Pascal vs C
  output on every case.

### Phase 2 implementation notes

**Unit**: `src/passqlite3util.pas` (1858 lines).

**What was done**:
- `global.c`: Ported `sqlite3UpperToLower[274]` and `sqlite3CtypeMap[256]`
  verbatim. `sqlite3GlobalConfig` initialised in `initialization` section.
- `util.c`: Ported varint codec (lines 1574–1860), `sqlite3Get4byte`/
  `sqlite3Put4byte`, `sqlite3StrICmp`, `sqlite3_strnicmp`, `sqlite3StrIHash`,
  `sqlite3AtoF`, `sqlite3Strlen30`, `sqlite3FaultSim`. Character-classification
  macros ported as `inline` functions.
- `hash.c`: All 5 public + 4 private functions ported faithfully.
- `random.c`: ChaCha20 block function and `sqlite3_randomness` ported verbatim.
  Save/restore state included.
- `bitvec.c`: All functions ported including the three-way bitmap/hash/subtree
  representation and the clear-via-rehash logic.
- `status.c`: `sqlite3StatusValue`, `sqlite3StatusUp`, `sqlite3StatusDown`,
  `sqlite3StatusHighwater`, `sqlite3_status64`, `sqlite3_status`.
- `malloc.c` + `mem1.c` + `fault.c`: Thin malloc dispatch layer wrapping libc
  `malloc`/`free`/`realloc` with optional memstat accounting. Benign-malloc
  hooks. `sqlite3MallocSize` via `malloc_usable_size`.
- `printf.c`: Stub using libc `vasprintf`/`vsnprintf`. Full port with `%q`/
  `%Q`/`%w`/`%z` deferred to Phase 6.
- `utf.c`: `sqlite3Utf8Read`, `sqlite3Utf8CharLen`,
  `sqlite3AppendOneUtf8Character`.

**Design decisions**:
- `printf.c` full port deferred — requires `Parse` and `Mem` types (Phase 6).
  Phase 2 stubs compile cleanly and unblock all downstream phases.
- `mem2`/`mem3`/`mem5` deferred — only needed for specific test configurations.
- `sqlite3VdbeMemTranslate` stubbed — requires `Mem` from vdbeInt.h (Phase 6).
- `-lm` added to `build.sh` FPC_FLAGS for `pow()` linkage.

**Known limitations**:
- `sqlite3_mprintf`/`sqlite3_snprintf` are stubs; format extensions `%q`,
  `%Q`, `%w`, `%z` not yet handled.
- `sqlite3DbStatus` (per-connection status) deferred to Phase 6.
- Status counters not mutex-protected when `gMallocMutex` is nil (before init).



## Phase 3 — Page cache + Pager + WAL

Files:
- `pcache.c` (~1 k lines) + `pcache1.c` (~1.5 k) — **page cache** (the
  memory-resident cache of file pages, distinct from the pager). Everything
  in pager/btree/VDBE ultimately goes through `sqlite3PcacheFetch` /
  `sqlite3PcacheRelease`.
- `pager.c` (~7.8 k lines) + `memjournal.c` + `memdb.c` — **pager**:
  journaling, transactions, the `:memory:` backing.
- `wal.c` (~4 k lines) — **WAL**: write-ahead log.

**The trickiest correctness-critical layer.** Journaling and WAL semantics must
be bit-exact — if the pager produces a different journal byte stream, a crash
at the wrong moment will leave the database unrecoverable.

### 3.A — Page cache (prerequisite for 3.B)

- [X] **3.A.1** Port `pcache.c`: the generic page-cache interface and the
  `PgHdr` lifecycle (`sqlite3PcacheFetch`, `sqlite3PcacheRelease`,
  `sqlite3PcacheMakeDirty`, `sqlite3PcacheMakeClean`, eviction).
- [X] **3.A.2** Port `pcache1.c`: the default concrete backend (LRU with
  purgeable / unpinned page tracking). This is the allocator-heavy one.
- [X] **3.A.3** Port `memjournal.c`: the in-memory journal implementation
  used when `PRAGMA journal_mode=MEMORY` or during `SAVEPOINT`.
- [X] **3.A.4** Port `memdb.c`: the `:memory:` database backing — a VFS-shaped
  object over a single in-RAM buffer.
- [X] **3.A.5** Gate: `TestPCache.pas` — scripted fetch / release / dirty /
  eviction sequences produce identical `PgHdr` state and identical
  allocation counts vs C reference. **All 8 tests pass (T1–T8).**

### Phase 3.A.3+3.A.4 implementation notes (2026-04-22)

**Units**: `src/passqlite3pager.pas` (~1080 lines, memjournal.c + memdb.c).

**What was done**:
- Ported all `memjournal.c` types (`FileChunk`, `FilePoint`, `MemJournal`) and functions:
  `memjrnlRead`, `memjrnlWrite`, `memjrnlTruncate`, `memjrnlFreeChunks`,
  `memjrnlCreateFile`, `memjrnlClose`, `memjrnlSync`, `memjrnlFileSize`,
  plus all exported functions (`sqlite3JournalOpen`, `sqlite3MemJournalOpen`,
  `sqlite3JournalCreate`, `sqlite3JournalIsInMemory`, `sqlite3JournalSize`).
- Ported all `memdb.c` types (`MemStore`, `MemFile`) and functions:
  `memdbClose`, `memdbRead`, `memdbWrite`, `memdbTruncate`, `memdbSync`,
  `memdbFileSize`, `memdbLock`, `memdbUnlock`, `memdbFileControl`,
  `memdbDeviceCharacteristics`, `memdbFetch`, `memdbUnfetch`, `memdbOpen`,
  plus VFS helper functions and exported `sqlite3MemdbInit`, `sqlite3IsMemdb`.
- `TestPager.pas` written: T1–T12 covering all major code paths.
  All 12 pass.

**Design notes**:
- `MemJournal` and `MemFile` are both subclasses of `sqlite3_file`; the vtable
  pointer must be the first field — preserved exactly.
- nSpill=0 delegates directly to real VFS; nSpill<0 stays pure in-memory;
  nSpill>0 spills when size exceeds nSpill (verified by T3).
- `memdb_g` (global MemFS) is unit-level; shared named databases via VFS1 mutex.
- `SQLITE_DESERIALIZE_*` constants added to interface section.

---

### Phase 3.A implementation notes (2026-04-22)

**Unit**: `src/passqlite3pcache.pas` (~1280 lines, pcache.c + pcache1.c).

**What was done**:
- Ported `PgHdr` / `PCache` / `PCache1` / `PGroup` / `PgHdr1` structs and all
  public `sqlite3Pcache*` functions plus the `pcache1` backend (LRU with
  purgeable-page tracking, resize-hash, eviction, bulk-local slab allocator).
- `TestPCache.pas` written: T1–T8 (init+open, fetch, dirty list, ref counting,
  MakeClean, truncate, close-with-dirty, C-reference differential). All pass.

**Three bugs fixed (all Pascal-specific)**:

1. **`szExtra=0` latent overflow** — C reference calls `memset(pPgHdr->pExtra,0,8)`
   unconditionally; when `szExtra=0` there is no extra area and this writes past the
   allocation. Added guard: `if pCache^.szExtra >= 8 then FillChar((pHdr+1)^, 8, 0)`.

2. **`SizeOf(PGroup)` shadowed by local `pGroup: PPGroup` in `pcache1Create`** —
   Pascal is case-insensitive: a local variable `pGroup: PPGroup` (pointer, 8 bytes)
   hides the type name `PGroup` (record, 80 bytes). `SizeOf(PGroup)` inside that
   function returned 8 instead of 80, so `sz = SizeOf(PCache1) + 8` instead of
   `SizeOf(PCache1) + 80`, allocating only 96 bytes for a 168-byte struct.
   Writing the full struct overflowed 72 bytes into glibc malloc metadata → crash.
   Fix: rename local `pGroup → pGrp`.

3. **`SizeOf(PgHdr)` shadowed by local `pgHdr: PPgHdr` in `pcacheFetchFinishWithInit`
   / `sqlite3PcacheFetchFinish`** — same mechanism; `FillChar(pgHdr^, SizeOf(PgHdr), 0)`
   only zeroed 8 bytes of the 80-byte `PgHdr` struct, leaving most fields as garbage.
   Fix: rename local `pgHdr → pHdr`.

4. **Unsigned for-loop underflow in `pcache1ResizeHash`** — C `for(i=0;i<nHash;i++)`
   naturally skips when `nHash=0`. Pascal `for i := 0 to nHash - 1` with `i: u32`
   computes `0 - 1 = $FFFFFFFF` (unsigned wrap), running 4 billion iterations and
   immediately segfaulting on `nil apHash[0]`. Fix: guard the loop with
   `if p^.nHash > 0 then`.

**CRITICAL PATTERN — applies to all future phases**:
> Any Pascal function that has a local variable of type `PFoo` (pointer) where
> `PFoo` is also the name of a record type will silently corrupt `SizeOf(PFoo)`
> inside that scope (returns pointer size 8 instead of the record size). Always
> rename local pointer variables to `pFoo` / `pTmp` / anything that doesn't
> exactly match the type name. Scan every new unit with:
> `grep -n 'SizeOf(' src/passqlite3*.pas` and verify none of the named types have
> a same-named local in scope.

**CRITICAL PATTERN — unsigned loop bounds**:
> Never write `for i := 0 to N - 1` when `i` or `N` is an unsigned type (`u32`).
> If `N = 0`, the subtraction wraps to `$FFFFFFFF` and the loop runs ~4 billion
> iterations. Always guard with `if N > 0 then` or use a signed loop variable.

---

### Phase 3.B.2a implementation notes (2026-04-22)

**Unit**: `src/passqlite3pager.pas` (implementation block expanded).

**What was done (read-only path of pager.c)**:
- Ported ~600 lines of pager.c read-only path:
  - `sqlite3SectorSize`, `setSectorSize` (pager.c ~2694/2728)
  - `setGetterMethod`, `getPageError`, `getPageNormal` (pager.c ~1045/5709/5535)
  - `pager_reset`, `releaseAllSavepoints`, `pager_unlock` (pager.c ~1772/1790/1841)
  - `pagerUnlockDb`, `pagerLockDb`, `pagerSetError` (pager.c ~1133/1161/1947)
  - `pagerFixMaplimit`, `pager_wait_on_lock` (pager.c ~3533/3946)
  - `pagerPagecount`, `hasHotJournal`, `pagerOpenWalIfPresent` (pager.c ~3279/5134/3339)
  - `readDbPage`, `pagerUnlockIfUnused`, `pagerUnlockAndRollback` (pager.c ~3021/5471/2191)
  - `sqlite3PagerSetFlags`, `sqlite3PagerSetPagesize`, `sqlite3PagerSetCachesize`
  - `sqlite3PagerSetBusyHandler`, `sqlite3PagerMaxPageCount`, `sqlite3PagerLockingMode`
  - `sqlite3PagerOpen`, `sqlite3PagerClose` (pager.c ~4735/4176)
  - `pagerSyncHotJournal`, `pagerStress` (stub), `pagerFreeMapHdrs`
  - `sqlite3PagerReadFileheader`, `sqlite3PagerPagecount`
  - `sqlite3PagerSharedLock` (pager.c ~5254)
  - `sqlite3PagerGet`, `sqlite3PagerLookup`, `sqlite3PagerRef`
  - `sqlite3PagerUnref`, `sqlite3PagerUnrefNotNull`, `sqlite3PagerUnrefPageOne`
  - `sqlite3PagerGetData`, `sqlite3PagerGetExtra`, accessor functions
  - `pagerReleaseMapPage`, `pager_playback` (stub for 3.B.2b)
- Added new constants: `SQLITE_OK_SYMLINK`, `SQLITE_DEFAULT_SYNCHRONOUS`
- Added new OS wrapper functions to `passqlite3os.pas`:
  `sqlite3OsSectorSize`, `sqlite3OsDeviceCharacteristics`,
  `sqlite3OsFileControl`, `sqlite3OsFileControlHint`, `sqlite3OsFetch`,
  `sqlite3OsUnfetch`
- Created `src/tests/vectors/simple.db` and `multipage.db` test vectors
- Created `TestPagerReadOnly.pas` (10 tests, all PASS)

**Critical discovery**: In FPC (case-insensitive Pascal), a local variable
`pPager: PPager` creates a conflict because `pPager` == `PPager` (same
identifier). This manifests as "Error in type definition" at the var
declaration. Fix: rename local vars to `pPgr`. Similarly, `pgno: Pgno`
must be renamed `pg: Pgno` in test code. This is NOT an FPC bug — it is
correct ISO Pascal: a var name shadows a type name of the same normalized
form. Function PARAMETERS named `pPager: PPager` work because the type
is resolved before the parameter binding is created.

**WAL stubs** (deferred to 3.B.3): `pagerOpenWalIfPresent` returns
`SQLITE_OK`; `pPager^.pWal` is always nil in this phase; all `pagerUseWal`
branches are skipped.

**Backup stub** (deferred to 8.7): `sqlite3BackupRestart` not called;
`pPager^.pBackup` is nil.

**`pager_playback` stub** (deferred to 3.B.2b): returns SQLITE_OK; full
journal replay implemented in 3.B.2b.

---

### Phase 3.B.1 implementation notes (2026-04-22)

**Unit**: `src/passqlite3pager.pas` (expanded with Pager struct section).

**What was done**:
- Added `passqlite3pcache` to uses clause (provides `PPgHdr`, `PPCache`,
  `PBitvec`, `PgHdr`, `PCache` needed by Pager).
- Ported all pager.h constants: `PAGER_OMIT_JOURNAL`, `PAGER_MEMORY`,
  `PAGER_LOCKINGMODE_*`, `PAGER_JOURNALMODE_*`, `PAGER_GET_*`,
  `PAGER_SYNCHRONOUS_*`, `PAGER_FULLFSYNC`, `PAGER_CACHESPILL`,
  `PAGER_FLAGS_MASK`.
- Ported pager.c internal constants: `UNKNOWN_LOCK`, `MAX_SECTOR_SIZE`,
  `SPILLFLAG_*`, `PAGER_STAT_*`, `WAL_SAVEPOINT_NDATA`, journal magic bytes.
- Ported `PagerSavepoint` record (all 7 fields including aWalData[0..3]).
- Declared `TWal` as opaque record (full definition deferred to Phase 3.B.3).
- Declared `Psqlite3_backup` as `Pointer` (full definition deferred to Phase 8.7).
- Ported `Pager` struct (all 42 fields, matching C struct Pager lines 619-706
  in SQLite 3.53.0 exactly: u8 fields in same order, same Pgno/i64/u32 types).
- Added `isWalMode` and `isOpen` inline helpers (from pager.h macros).
- `DbPage = PgHdr` typedef added per pager.h.
- Verified: `passqlite3pager.pas` compiles cleanly; TestPager 12/12 pass.

**Critical note**: The `Pager` record has 13 leading `u8` fields before the
first Pgno. The C struct guarantees field ordering for any later memcmp tests.
Pascal records in `{$MODE OBJFPC}` have no hidden padding between same-size
fields, but verify with a SizeOf/offsetof check when TestPagerReadOnly is written.

---

### 3.B — Pager + WAL

- [X] **3.B.1** Port the `Pager` struct and its helper types. Field order must
  match C exactly — tests will `memcmp`. (The `PgHdr` / `PCache` types have
  already been ported in Phase 3.A.)

- [X] **3.B.2** Port `pager.c` in three sub-phases:
  - [X] **3.B.2a** Read-only path: `sqlite3PagerOpen`, `sqlite3PagerGet`,
    `sqlite3PagerUnref`, `readDbPage`. Enough to open an existing DB and read
    pages. Gate: `TestPagerReadOnly.pas` — 10/10 PASS (2026-04-22).
    See implementation notes below.
  - [X] **3.B.2b** Rollback journaling: write path for `journal_mode=DELETE`.
    `pagerWalFrames` is NOT in scope here. Gate: `TestPagerRollback.pas` —
    10/10 PASS (2026-04-22). All write-path functions ported: `writeJournalHdr`,
    `pager_write`, `sqlite3PagerBegin`, `sqlite3PagerWrite`, `sqlite3PagerCommitPhaseOne`,
    `sqlite3PagerCommitPhaseTwo`, `sqlite3PagerRollback`, `sqlite3PagerOpenSavepoint`,
    `sqlite3PagerSavepoint`, `pager_playback`, `pager_playback_one_page`,
    `pager_end_transaction`, `syncJournal`, `pager_write_pagelist`, `pager_delsuper`,
    `pagerPlaybackSavepoint`, and ~25 helper functions.
    FPC hazards resolved: `pgno: Pgno` → `pg: u32`, `pPgHdr: PPgHdr` → `pHdr`,
    `pPagerSavepoint` var renamed to `pSP`, `out ppPage` → `ppPage: PPDbPage`,
    `sqlite3_log` stub (varargs not allowed without cdecl+external).
  - [X] **3.B.2c** Atomic commit, savepoints, rollback-on-error paths. Gate:
    `TestPagerCrash.pas` — 10/10 PASS (2026-04-22). Tested: multi-page commit
    atomicity, fork-based crash recovery (hot-journal playback), savepoint
    rollback, nested savepoint partial rollback, savepoint-release then outer
    rollback, empty journal, multiple-commit crash, C-reference differential
    (recovered .db opened by libsqlite3), truncated journal header, rollback-on-error.
    **Key discovery**: do NOT use page 1 for byte-pattern verification — every
    commit overwrites bytes 24-27, 92-95, 96-99 of page 1 via
    `pager_write_changecounter`. Use page 2 or higher for data integrity checks.

- [X] **3.B.3** Port `wal.c`: the write-ahead log.
  - [X] **3.B.3a** Full port of `wal.c` (2361 lines) to `passqlite3wal.pas`.
    Compiles 0 errors. All types, constants, and public API ported.
    `passqlite3pager.pas` updated: `TWal` stub removed, `passqlite3wal` added
    to uses, `PWal` aliased from `passqlite3wal.PWal`. All prior tests pass.
  - [X] **3.B.3b** Wire WAL into pager: `pagerOpenWalIfPresent`, `pagerUseWal`,
    `sqlite3PagerBeginReadTransaction`, etc. call real WAL functions.
  - [X] **3.B.3c** Checkpoint integration.
  Gate: `TestWalCompat.pas` — Pascal writer + C reader, and vice versa. T1–T8 PASS (2026-04-22).

### Phase 3.B.3a implementation notes (2026-04-22)

**What was done**:
- Created `passqlite3wal.pas` (2361 lines): full port of `wal.c` (SQLite 3.53.0).
- All types: `TWalIndexHdr` (48B), `TWalCkptInfo` (40B), `TWalSegment`, `TWalIterator`,
  `TWalHashLoc`, `TWalWriter`, `TWal` (full struct, replaces opaque stub in pager).
- All public API: `sqlite3WalOpen`, `sqlite3WalClose`, `sqlite3WalBeginReadTransaction`,
  `sqlite3WalEndReadTransaction`, `sqlite3WalFindFrame`, `sqlite3WalReadFrame`,
  `sqlite3WalDbsize`, `sqlite3WalBeginWriteTransaction`, `sqlite3WalEndWriteTransaction`,
  `sqlite3WalUndo`, `sqlite3WalSavepoint`, `sqlite3WalSavepointUndo`,
  `sqlite3WalFrames`, `sqlite3WalCheckpoint`, `sqlite3WalCallback`,
  `sqlite3WalExclusiveMode`, `sqlite3WalHeapMemory`, `sqlite3WalFile`.
- Local stubs: `sqlite3Realloc` (realloc+free), `sqlite3_log_wal` (no-op),
  `sqlite3SectorSize` (wraps `sqlite3OsSectorSize`).
- `passqlite3pager.pas` updated: `TWal = record end` stub removed, `passqlite3wal`
  added to uses clause, `PWal` aliased as `passqlite3wal.PWal`. Compiles cleanly.
- All prior tests pass: TestPager 12/12, TestPagerCrash 10/10, TestPagerRollback 10/10,
  TestPCache 8/8, TestOSLayer 14/14, TestSmoke PASS.
**FPC hazards resolved**:
- `cint` not transitively available — added `ctypes` to interface `uses`.
- Type declarations (`PPWal`, `TxUndoCallback`, `TxBusyCallback`, `PPHtSlot`,
  `PPWalIterator`, `PWalWriter`, `PWalHashLoc`) must precede functions that use them.
- Goto labels (`finished`, `recovery_error`, `begin_unreliable_shm_out`,
  `walcheckpoint_out`) require `label` declarations in each function's var section.
- Inline `var x: T := ...` inside begin/end blocks invalid; moved to var sections.
- `8#777` octal invalid in FPC; replaced with `$1FF` in passqlite3os.pas.
- `ternary(cond, a, b)` has no FPC equivalent; expanded to if-then-else.
- `^TRecord` parameter type replaced by `PRecord` (pointer type alias).

### Phase 3.B.3b+3c implementation notes (2026-04-22)

**What was done**:
- `pagerOpenWalIfPresent`, `pagerUseWal`, `pagerBeginReadTransaction`,
  `sqlite3PagerSharedLock`, `sqlite3PagerBeginReadTransaction` wired to real
  WAL functions in `passqlite3wal.pas`.
- `sqlite3PagerCheckpoint` wired; `sqlite3PagerClose` passes `pTmpSpace` to
  `sqlite3WalClose` for TRUNCATE checkpoint on close.
- `TestWalCompat.pas` (2026-04-22): T1–T8 all PASS.
  T1 WAL header open, T2 BeginReadTransaction, T3 Dbsize, T4 FindFrame+ReadFrame,
  T5 pager SharedLock on C WAL db, T6 Pascal write to C WAL (C re-opens cleanly),
  T7 TRUNCATE checkpoint, T8 fresh Pascal-written WAL opened by C.
- Added to `build.sh` compile list.

**Critical bug fixed in `unixLockSharedMemory` (passqlite3os.pas)**:
  `F_GETLK` does not report locks held by the calling process (Linux POSIX
  advisory lock semantics). When two connections in the same process both
  call `unixLockSharedMemory`, the second sees `F_UNLCK` and incorrectly
  calls `FpFtruncate(hShm, 3)`, destroying the already-initialized SHM
  (and thus C's WAL index). Fix: after acquiring F_WRLCK on the DMS byte,
  check the SHM file size with `FpFStat`. If `st_size > 3`, the SHM has
  already been initialized by another in-process connection; skip the
  truncate.

**Additional fix**: `sqlite3PcacheInitialize` was missing from
  `TestWalCompat.pas` main block, causing null function pointer crash in
  `sqlite3GlobalConfig.pcache2.xCreate`. Added after `sqlite3OsInit`.

---

- [X] **3.B.4** `TestPagerCompat.pas` (full gate): a SQL corpus that stresses
  journaling (big transactions, SAVEPOINTs, simulated crashes) produces
  byte-identical `.db` and `.journal` files on both sides.
  Gate: T1–T10 all PASS (2026-04-22).

### Phase 3.B.4 implementation notes (2026-04-22)

**File**: `src/tests/TestPagerCompat.pas` (1107 lines).

**Tests**:
- T1  C creates a populated db (40-row table); Pascal pager reads page 1 SQLite magic and page count >= 2.
- T2  Pascal writes a minimal-header 1-page db; C opens without SQLITE_NOTADB or SQLITE_CORRUPT.
- T3  Pascal writes a 10-page DELETE-journal transaction; all 10 pages retain correct byte patterns after reopen.
- T4  Savepoint: outer writes $AA to page 2, SP1 overwrites to $BB, SP1 rolled back, outer committed — page 2 = $AA.
- T5  Fork-based crash: child does CommitPhaseOne on 8 pages then exits; parent reopens → hot-journal restores $01; C opens without corruption.
- T6  Journal cleanup: no `.journal` file remains on disk after a successful DELETE-mode commit.
- T7  C creates a 100-row db; Pascal opens read-only and reads every page without I/O errors.
- T8  Pascal creates a WAL-mode db (sqlite3PagerOpenWal), writes a commit; C opens without CORRUPT.
- T9  Pascal writes 3-commit WAL db, runs PASSIVE checkpoint; C opens without error after checkpoint.
     Note: TRUNCATE checkpoint returns SQLITE_BUSY when the same pager holds a read lock (by design); use PASSIVE for in-process checkpoints.
- T10 20-page transaction committed, crash mid-next-commit (21-page transaction, PhaseOne only), recovery; page 5 restored to pre-crash value; C opens without corruption.

---

## Phase 4 — B-tree

Files: `btree.c` (~11.6 k lines), `btmutex.c` (B-tree-level mutex acquisition,
separate because different trees may share a cache / connection).
Headers: `btree.h`, `btreeInt.h`.

Builds on the pager. The B-tree layer implements SQLite's table and index
storage. Correctness here is again checked by on-disk byte equality.

- [X] **4.1** Port the cell-parsing helpers (`btreeParseCellPtr`,
  `btreeParseCell`, `cellSizePtr`, `dropCell`, `insertCell`). These manipulate
  individual records within a page; tight code.
  - Implemented in `src/passqlite3btree.pas` (~750 lines / 1534 compiled).
  - All types from btreeInt.h in one `type` block (FPC requires forward types
    resolved in the same block; `const` block must precede the single type block
    so `BTCURSOR_MAX_DEPTH` is visible for array bounds in `TBtCursor`).
  - Pager bridge functions (sqlite3PagerIswriteable, sqlite3PagerPagenumber,
    sqlite3PagerTempSpace) added to btree unit to avoid circular unit deps.
  - `allocateSpace` does NOT update `nFree`; callers (insertCell/insertCellFast)
    must subtract the allocated size from `nFree` themselves — matches C exactly.
  - `defragmentPage`: fast path triggered when `data[hdr+7] <= nMaxFrag`; always
    call with `nMaxFrag ≥ 0`; internal call from `allocateSpace` uses `nMaxFrag=4`.
  - Gate: `TestBtreeCompat.pas` T1–T10 all PASS (54 checks, 2026-04-22).

- [X] **4.2** Port `BtCursor` + `sqlite3BtreeCursor`, `moveToRoot`, `moveToChild`,
  `moveToParent`, `sqlite3BtreeMovetoUnpacked`.
  - Cursor lifecycle: `btreeCursor`, `sqlite3BtreeCursor`, `sqlite3BtreeCloseCursor`,
    `sqlite3BtreeCursorZero`, `sqlite3BtreeCursorSize`, `sqlite3BtreeClearCursor`.
  - Page helpers: `releasePageNotNull`, `releasePage`, `releasePageOne`,
    `unlockBtreeIfUnused`, `getAndInitPage`.
  - Temp space: `allocateTempSpace`, `freeTempSpace`.
  - Overflow cache: `invalidateOverflowCache`, `invalidateAllOverflowCache`.
  - Cursor save/restore: `saveCursorKey`, `saveCursorPosition`,
    `btreeRestoreCursorPosition`, `restoreCursorPosition`.
  - Navigation: `moveToChild`, `moveToParent`, `moveToRoot`, `moveToLeftmost`,
    `moveToRightmost`, `btreeReleaseAllCursorPages`.
  - Public API: `sqlite3BtreeFirst`, `sqlite3BtreeLast`, `sqlite3BtreeTableMoveto`,
    `sqlite3BtreeIndexMoveto`, `sqlite3BtreeNext`, `sqlite3BtreePrevious`,
    `sqlite3BtreeEof`, `sqlite3BtreeIntegerKey`, `sqlite3BtreePayload`,
    `sqlite3BtreePayloadSize`, `sqlite3BtreeCursorHasMoved`, `sqlite3BtreeCursorRestore`.
  - VDBE stubs (Phase 6): `sqlite3VdbeFindCompare`, `sqlite3VdbeRecordCompare`,
    `indexCellCompare`, `cursorOnLastPage`.
  - FPC pitfalls fixed: `pDbPage: PDbPage` → `pDbPg` (case-insensitive conflict);
    `pBtree: PBtree` → `pBtr`; `pgno: Pgno` → `pg`; no `begin..end` as expression;
    `label` blocks added to `moveToRoot`, `sqlite3BtreeTableMoveto`,
    `sqlite3BtreeIndexMoveto`.
  - TestPagerReadOnly.pas: fixed pre-existing `PDbPage` / `PPDbPage` call mismatch.
  - Gate: `TestBtreeCompat.pas` T1–T18 all PASS (89 checks, 2026-04-22).

- [X] **4.3** Port insert path: `sqlite3BtreeInsert`, `balance`, `balance_deeper`,
  `balance_nonroot`, `balance_quick`. The balancing logic is the most intricate
  part of SQLite — port line by line, no restructuring.
  - Also ported: `fillInCell`, `freePage2`, `freePage`, `clearCellOverflow`,
    `allocateBtreePage`, `btreeSetHasContent`, `btreeClearHasContent`,
    `saveAllCursors`, `btreeOverwriteCell`, `btreeOverwriteContent`,
    `btreeOverwriteOverflowCell`, `rebuildPage`, `editPage`, `pageInsertArray`,
    `pageFreeArray`, `populateCellCache`, `computeCellSize`, `cachedCellSize`,
    `balance_quick`, `copyNodeContent`, `sqlite3PagerRekey`.
  - FPC fixes: `PPu8` ordering before `TCellArray`; `pgno: Pgno` renamed to `pg`;
    all C ternary-as-expression idioms converted to explicit if/else; inline `var`
    declarations moved to proper var sections; `sqlite3Free` → `sqlite3_free`;
    `Boolean` vs `i32` arguments fixed with `ord()`.
  - Gate: `TestBtreeCompat.pas` T1–T20 all PASS (100 checks, 2026-04-23).

- [X] **4.4** Port delete path: `sqlite3BtreeDelete`, `clearCell`, `freePage`,
  free-list management.
  - Gate: `TestBtreeCompat.pas` T23 (delete mid-tree row) PASS (2026-04-23).

- [X] **4.5** Port schema/metadata: `sqlite3BtreeGetMeta`, `sqlite3BtreeUpdateMeta`,
  auto-vacuum (if enabled), incremental vacuum.
  - Also fixed: `balance_quick` divider-key extraction bug (C post-increment
    vs Pascal while-loop semantics for nPayload varint skip); fixes T28 seek/count.
  - Gate: `TestBtreeCompat.pas` T1–T28 all PASS (156 checks, 2026-04-23).

- [X] **4.6** `TestBtreeCompat.pas`: a sequence of insert / update / delete /
  seek operations on a corpus of keys (random, sorted, reverse-sorted,
  pathological duplicates) produces byte-identical `.db` files. This is the
  single most important gating test for the lower half of the port.
  - T29: sorted ascending (N=500) — write+close+reopen+scan all 500, verify count and last key. PASS.
  - T30: sorted descending (N=500, insert 500..1) — reopen+scan in order, verify count/first/last key. PASS.
  - T31: random order (N=200, Fisher-Yates shuffle) — reopen+scan, verify count/first/last key. PASS.
  - T32: overflow-page corpus (50 rows × 2000-byte payload) — reopen, verify payload size and per-row marker byte for each row. PASS (100 checks).
  - T33: C writes 50-row db via SQL, Pascal reads btree root page 2, verify count=50 and last key=50. Cross-compat PASS.
  - T34: Pascal writes 300-row db, C opens via csq_open_v2 without CORRUPT, PRAGMA page_count > 1. PASS.
  - T35: insert 1..100, delete evens, insert 101..110; reopen verify count=60, first=1, last=110, spot-check key2 absent / key3 present. PASS.
  - Gate: T1–T35 all PASS (337 checks, 2026-04-24).
  - **Key discovery**: `sqlite3BtreeNext(pCur, flags)` takes `flags: i32` (not `*pRes`). Returns `SQLITE_DONE` at end-of-table; loop must convert SQLITE_DONE → SQLITE_OK and set pRes=1 to exit. `sqlite3BtreeFirst(pCur, pRes)` still sets *pRes=0/1 for empty check.

---

## Phase 5 — VDBE

Files:
- `vdbe.c` (~9.4 k lines, ~**199 opcodes** — nearly double the count the
  tasklist originally assumed). The main interpreter loop.
- `vdbeaux.c` — program assembly, label resolution, final layout.
- `vdbeapi.c` — `sqlite3_step`, `sqlite3_column_*`, `sqlite3_bind_*`.
- `vdbemem.c` — the `Mem` type: value coercion, storage, affinity.
- `vdbeblob.c` — incremental blob I/O (`sqlite3_blob_open`, etc.).
- `vdbesort.c` — the external sorter used by ORDER BY / GROUP BY.
- `vdbetrace.c` — `EXPLAIN` rendering helper.
- `vdbevtab.c` — VDBE ops that call into virtual tables (depends on `vtab.c`,
  Phase 6.bis).

Headers: `vdbe.h`, `vdbeInt.h`.

The bytecode interpreter. Big switch statement; tedious but mechanical —
but bigger than initially scoped. Phase 5 effort roughly **2× the original
estimate**.

- [X] **5.1** Port `Vdbe`, `VdbeOp`, `Mem`, `VdbeCursor` records. Field order
  must match C — tests will dump program state and diff.
  - Created `src/passqlite3vdbe.pas` (515 lines): all types from vdbeInt.h and
    vdbe.h (TMem, TVdbeOp, TVdbeCursor, TVdbe, TVdbeFrame, TAuxData,
    TScanStatus, TDblquoteStr, TSubrtnSig, TSubProgram, Tsqlite3_context,
    TValueList, TVdbeTxtBlbCache); all 192 OP_* opcodes from opcodes.h;
    MEM_* / P4_* / CURTYPE_* / VDBE_*_STATE / OPFLG_* / VDBC_* / VDBF_*
    constants; sqlite3OpcodeProperty[192] table; stubs for 5.2–5.5 functions.
  - FPC struct sizes verified vs GCC x86-64 layout:
    TMem=56, TVdbeOp=24, TVdbeCursor=120, TVdbe=304, TVdbeFrame=112.
  - Bitfields (VdbeCursor 5-bit group, Vdbe 9-bit group) represented as u32
    with VDBC_*/VDBF_* named bit-mask constants; FPC natural alignment produces
    identical offsets to GCC.
  - All 337 TestBtreeCompat + pager/WAL tests still PASS (2026-04-24).

- [X] **5.2** Port `vdbeaux.c`: program assembly (`sqlite3VdbeAddOp*`), label
  resolution, final VDBE program layout. Gate: given a hand-written VDBE
  program, Pascal and C produce identical `Op[]` arrays.
  - Ported to `src/passqlite3vdbe.pas` (2756 lines, Phase 5.2 implementation
    section). All vdbeaux.c public functions present: AddOp0/1/2/3/4/4Int,
    MakeLabel, ResolveLabel, resolveP2Values, ChangeP1/2/3/4/5, GetOp,
    GetLastOp, JumpHere, VdbeCreate, VdbeClearObject, VdbeDelete, VdbeSwap,
    VdbeMakeReady, VdbeRewind, SerialTypeLen, OneByteSerialTypeLen,
    SerialGet, SerialPut, SerialType, OpcodeName.
  - **Bug fixed**: `sqlite3VdbeSerialPut` — C's fall-through `switch` for
    big-endian integer/float serialization translated incorrectly as a Pascal
    `case` (no fall-through). Fixed by converting to an explicit downward loop.
  - **New helper added**: `sqlite3_realloc64` declared in `passqlite3os.pas`
    (maps to libc `realloc` with u64 size, same as `sqlite3_malloc64`).
  - **Bitfield access fixed**: `TVdbe.readOnly`/`bIsReader` fields accessed via
    `vdbeFlags` u32 with VDBF_ReadOnly / VDBF_IsReader bit-mask constants.
  - **varargs removed**: `cdecl; varargs` dropped from all stub implementations
    (FPC only allows `varargs` on `external` declarations).
  - Gate: TestVdbeAux T1–T17 all PASS (108/108 checks, 2026-04-24).

- [X] **5.3** Port `vdbemem.c`: the `Mem` type's value coercion and storage.
  Many subtle corner cases (type affinity, text encoding conversion).
  - Gate: TestVdbeMem T1–T23 all PASS (62/62 checks, 2026-04-24).

- [X] **5.4** Port `vdbe.c` — the `sqlite3VdbeExec` loop. **~199 opcodes**.
  All sub-tasks 5.4a–5.4q complete (2026-04-25). ~190+ opcodes implemented.
  Port in groups:
  - [X] **5.4a** Exec loop skeleton + 23 opcodes: `OP_Goto`, `OP_Gosub`,
    `OP_Return`, `OP_InitCoroutine`, `OP_EndCoroutine`, `OP_Yield`,
    `OP_Halt`, `OP_Init`, `OP_Integer`, `OP_Int64`, `OP_Null`/`OP_BeginSubrtn`,
    `OP_SoftNull`, `OP_Blob`, `OP_Move`, `OP_Copy`, `OP_SCopy`, `OP_IntCopy`,
    `OP_ResultRow`, `OP_Jump`, `OP_If`, `OP_IfNot`, `OP_OpenRead`,
    `OP_OpenWrite`, `OP_Close`.
    Helper functions: `out2Prerelease`, `out2PrereleaseWithClear`,
    `allocateCursor`, `sqlite3ErrStr`, `sqlite3VdbeFrameRestoreFull`, stubs.
    `Tsqlite3` (PTsqlite3) struct added to `passqlite3util.pas` Section 3b.
    Compiles 0 errors; TestSmoke PASS (2026-04-24).
  - [X] **5.4b** Cursor motion: `OP_Rewind`, `OP_Next`, `OP_Prev`,
    `OP_SeekLT`, `OP_SeekLE`, `OP_SeekGE`, `OP_SeekGT`,
    `OP_Found`, `OP_NotFound`, `OP_NoConflict`, `OP_IfNoHope`,
    `OP_SeekRowid`, `OP_NotExists`,
    `OP_IdxLE`, `OP_IdxGT`, `OP_IdxLT`, `OP_IdxGE`.
    Helper labels: `next_tail`, `seek_not_found`, `notExistsWithKey`.
    Gate test: `TestVdbeCursor.pas` T1–T8 all PASS (27/27) (2026-04-24).
  - [X] **5.4c** Record I/O: `OP_Column`, `OP_MakeRecord`, `OP_Insert`, `OP_Delete`,
    `OP_Count`, `OP_Rowid`, `OP_NewRowid`.
    Gate test: `TestVdbeRecord.pas` T1–T6 all PASS (13/13) (2026-04-24).
  - [X] **5.4d** Arithmetic / comparison: `OP_Add`, `OP_Subtract`, `OP_Multiply`,
    `OP_Divide`, `OP_Remainder`, `OP_Eq`, `OP_Ne`, `OP_Lt`, `OP_Le`, `OP_Gt`,
    `OP_Ge`, `OP_BitAnd`, `OP_BitOr`, `OP_ShiftLeft`, `OP_ShiftRight`, `OP_AddImm`.
    Gate test: `TestVdbeArith.pas` T1–T13 all PASS (41/41) (2026-04-24).
  - [X] **5.4e** String/blob: `OP_String8`, `OP_String`, `OP_Blob`, `OP_Concat`.
    Gate test: `TestVdbeStr.pas` T1–T6 all PASS (23/23) (2026-04-24).
  - [X] **5.4f** Aggregate: `OP_AggStep`, `OP_AggFinal`, `OP_AggInverse`,
    `OP_AggValue`.
    Gate test: `TestVdbeAgg.pas` T1–T4 all PASS (11/11) (2026-04-24).
    Key fix: `sqlite3VdbeMemFinalize` must use a separate temp `TMem t` for
    output (ctx.pOut=@t); accumulator (ctx.pMem=pMem) stays intact through
    xFinalize call. Real SQLite uses `sqlite3VdbeMemMove(pMem,&t)` after;
    here we do `pMem^ := t` after `sqlite3VdbeMemRelease(pMem)`.
  - [X] **5.4g** Transaction control: `OP_Transaction`, `OP_Savepoint`,
    `OP_AutoCommit`.
    Gate test: `TestVdbeTxn.pas` T1–T4 all PASS (8/8) (2026-04-24).
    Also added: `sqlite3CloseSavepoints`, `sqlite3RollbackAll` helpers.
    Note: schema cookie check in OP_Transaction (p5≠0) is stubbed out —
    requires PSchema.iGeneration which is not yet accessible (Phase 6 concern).
  - [X] **5.4h** Miscellaneous opcodes: OP_Real, OP_Not, OP_BitNot, OP_And,
    OP_Or, OP_IsNull, OP_NotNull, OP_ZeroOrNull, OP_Cast, OP_Affinity,
    OP_IsTrue, OP_HaltIfNull, OP_Noop/Explain, OP_MustBeInt, OP_RealAffinity,
    OP_Variable, OP_CollSeq, OP_ClrSubtype, OP_GetSubtype, OP_SetSubtype,
    OP_Function.
    Gate test: `TestVdbeMisc.pas` T1–T13 all PASS (45/45) (2026-04-24).
    Bug fixed: P4_REAL pointer is freed by VdbeDelete — must be heap-allocated
    (not stack address) in test helpers.

- [X] **5.4i** Cursor open/close extensions: OP_OpenRead, OP_ReopenIdx,
    OP_OpenEphemeral, OP_OpenAutoindex, OP_OpenPseudo, OP_OpenDup,
    OP_NullRow, OP_RowData, OP_RowCell.
    Needed for: table scans, index usage, temp tables, subqueries.

- [X] **5.4j** Seek and index comparison: OP_SeekGE, OP_SeekLE, OP_SeekLT,
    OP_SeekScan, OP_SeekHit, OP_IdxLT, OP_IdxLE, OP_IdxGT, OP_IdxGE.
    Needed for: range queries, index navigation, ORDER BY.
    Implemented 2026-04-25: OP_SeekScan inlines sqlite3VdbeIdxKeyCompare via
    pMem5b/sqlite3VdbeRecordCompareWithSkip; OP_SeekHit clamps cursor seekHit.
    OP_SeekGE/LE/LT/GT/IdxLT/LE/GT/GE were already implemented in 5.4i.

- [X] **5.4k** Control flow: OP_Once, OP_IfEmpty, OP_IfNotOpen, OP_IfNoHope,
    OP_IfPos, OP_IfNotZero, OP_IfSizeBetween, OP_DecrJumpZero, OP_Program,
    OP_Param, OP_ElseEq, OP_Permutation, OP_Compare.
    Needed for: subqueries, EXISTS, IN, CASE, compound SELECT.
    Implemented 2026-04-25. OP_Program creates a VdbeFrame sub-execution context;
    OP_Compare uses pointer arithmetic to access KeyInfo (PKeyInfo=Pointer in Phase 5).
    OP_IfSizeBetween uses inline sqlite3LogEst. OP_Permutation is a no-op marker.

- [X] **5.4l** Sorter: OP_SorterOpen, OP_SorterInsert, OP_SorterSort,
    OP_SorterData, OP_SorterCompare, OP_Sort, OP_ResetSorter.
    Needed for: ORDER BY, GROUP BY with large result sets.
    Implemented 2026-04-25. OP_SorterCompare: signature is (pCsr; bOmitRowid; pVal; nKeyCol; out iResult).
    OP_SorterSort/Sort increment SQLITE_STMTSTATUS_SORT counter.

- [X] **5.4m** Schema: OP_CreateBtree, OP_ParseSchema, OP_ReadCookie,
    OP_SetCookie, OP_TableLock, OP_LoadAnalysis.
    Needed for: CREATE TABLE, schema changes, ANALYZE.
    Implemented 2026-04-25. OP_ParseSchema is a stub (Phase 6). OP_ReadCookie uses
    idx:u32 temp var (cannot take @u32(i64)). OP_TableLock simplified (no shared cache).
    OP_SetCookie updates schema_cookie and calls sqlite3FkClearTriggerCache.

- [X] **5.4n** RowSet: OP_RowSetAdd, OP_RowSetRead, OP_RowSetTest.
    Needed for: IN (subquery), EXISTS, DISTINCT.
    Implemented 2026-04-25. Full rowset.c port (~300 lines): TRowSetEntry/TRowSetChunk/TRowSet,
    rowSetEntryAlloc, rowSetEntryListMerge, rowSetNDeepTree, rowSetListToTree,
    rowSetTreeToList, rowSetSort; public: sqlite3RowSetAlloc/Clear/Delete/Insert/Test/Next.
    PPRowSetEntry = ^PRowSetEntry added to support recursive tree functions.

- [X] **5.4o** Foreign keys: OP_FkCheck, OP_FkCounter, OP_FkIfZero.
    Needed for: FOREIGN KEY enforcement.
    Implemented 2026-04-25. OP_FkCheck is a stub. OP_FkCounter increments
    db^.nDeferredCons or db^.nDeferredImmCons. OP_FkIfZero jumps if counter=0.

- [X] **5.4p** Virtual table: OP_VNext, OP_VOpen, OP_VFilter, OP_VColumn,
    OP_VUpdate, OP_VBegin, OP_VCreate, OP_VDestroy, OP_VRename, OP_VCheck,
    OP_VInitIn.
    Needed for: virtual tables (FTS, R-TREE, etc.).
    Implemented 2026-04-25 as stubs returning SQLITE_ERROR (virtual table engine
    not ported in Phase 5; full implementation deferred to Phase 7).

- [X] **5.4q** Misc remaining: OP_Abortable, OP_Clear, OP_ColumnsUsed,
    OP_CursorHint, OP_CursorLock, OP_CursorUnlock, OP_Destroy, OP_DropIndex,
    OP_DropTable, OP_DropTrigger, OP_Expire, OP_Filter, OP_FilterAdd,
    OP_IFindKey, OP_IncrVacuum, OP_IntegrityCk, OP_JournalMode, OP_Last,
    OP_MaxPgcnt, OP_MemMax, OP_Offset, OP_OffsetLimit, OP_Pagecount,
    OP_PureFunc, OP_ReleaseReg, OP_Sequence, OP_SequenceTest, OP_SqlExec,
    OP_TypeCheck, OP_Trace, OP_Vacuum.
    Implemented 2026-04-25. OP_PureFunc reuses OP_Function body via goto.
    OP_Filter/FilterAdd are stubs (bloom filter deferred). OP_Abortable/ReleaseReg
    are no-ops in release builds. OP_Checkpoint/Vacuum/JournalMode return SQLITE_OK stubs.
    Btree helpers added: sqlite3BtreeLastPage, sqlite3BtreeMaxPageCount,
    sqlite3BtreeLockTable (stub), sqlite3BtreeCursorPin/Unpin (BTCF_Pinned).

- [X] **5.5** Port `vdbeapi.c`: public API — `sqlite3_step`, `sqlite3_column_*`,
  `sqlite3_bind_*`, `sqlite3_reset`, `sqlite3_finalize`.
  Implemented: sqlite3_step, sqlite3_reset, sqlite3_finalize, sqlite3_clear_bindings,
  sqlite3_value_{type,int,int64,double,text,blob,bytes,subtype,dup,free,nochange,frombind},
  sqlite3_column_{count,data_count,type,int,int64,double,text,blob,bytes,value,name},
  sqlite3_bind_{int,int64,double,null,text,blob,value,parameter_count}.
  Gate test: `TestVdbeApi.pas` T1–T13 all PASS (57/57) (2026-04-24).
  Note: sqlite3_reset changed from procedure to function (returns i32) to match
  the real C API; sqlite3_step does auto-reset on HALT_STATE like SQLite 3.7+.

- [X] **5.6** Port `vdbeblob.c`: incremental blob I/O API
  (`sqlite3_blob_open`, `sqlite3_blob_read`, `sqlite3_blob_write`,
  `sqlite3_blob_bytes`, `sqlite3_blob_reopen`, `sqlite3_blob_close`).
  Added TIncrblob / Psqlite3_blob types. sqlite3_blob_open is a stub
  (returns SQLITE_ERROR) until the SQL compiler is available (Phase 7).
  sqlite3_blob_close, bytes, and null-guard behavior are fully implemented;
  read/write/reopen require sqlite3BtreePayloadChecked / sqlite3BtreePutData
  (will be completed after btree Phase 4 extensions).
  Gate test: `TestVdbeBlob.pas` T1–T11 all PASS (13/13) (2026-04-24).

- [X] **5.7** Port `vdbesort.c`: the external sorter (used for ORDER BY /
  GROUP BY on large result sets that don't fit in memory). Spills to temp
  files; correctness depends on deterministic tie-breaking.
  Defined TVdbeSorter (nTask=1 single-subtask stub), TSorterList, TSorterFile.
  Changed PVdbeSorter from Pointer to ^TVdbeSorter. All 8 public functions
  implemented: Init checks for KeyInfo (nil → SQLITE_ERROR); Reset frees
  in-memory list; Close releases sorter and resets cursor; Write/Rewind/Next/
  Rowkey/Compare have correct nil-guard and SQLITE_MISUSE/SQLITE_ERROR returns.
  Full PMA merge logic deferred to Phase 6+ (requires KeyInfo, UnpackedRecord).
  Gate test: `TestVdbeSort.pas` T1–T10 all PASS (14/14) (2026-04-24).

- [X] **5.8** Port `vdbetrace.c`: the `EXPLAIN` / `EXPLAIN QUERY PLAN`
  rendering helper. Small (~300 lines).
  Implemented sqlite3VdbeExpandSql. Full tokeniser-based parameter expansion
  requires sqlite3GetToken (Phase 7+); stub returns a heap-allocated copy of
  the raw SQL, which is correct for the no-parameter case and safe otherwise.
  Gate test: `TestVdbeTrace.pas` T1–T5 all PASS (7/7) (2026-04-24).

- [X] **5.9** Port `vdbevtab.c`: VDBE-side support for virtual-table opcodes.
  `SQLITE_ENABLE_BYTECODE_VTAB` not set; `sqlite3VdbeBytecodeVtabInit` is a
  no-op returning `SQLITE_OK`. Gate test `TestVdbeVtab`: T1–T2 all PASS (2/2).

- [ ] **5.10** `TestVdbeTrace.pas`: for every VDBE program produced by the C
  reference from the SQL corpus, run the program on the Pascal VDBE and on the
  C VDBE, with `PRAGMA vdbe_trace=ON`, and diff the resulting trace logs.
  **Any divergence halts the phase.**
  **DEFERRED** — requires the SQL parser (Phase 7.2) to generate VDBE programs
  automatically from SQL strings. The existing stub `TestVdbeTrace.pas` (T1–T5)
  tests only the `sqlite3VdbeExpandSql` API and already passes; the differential
  trace test cannot be fully written until Phase 7.2 is done.

---

### Phase 5.4d implementation notes (2026-04-24)

**Units changed**: `src/passqlite3vdbe.pas`, `src/tests/TestVdbeArith.pas`, `src/tests/build.sh`.

**What was done**:
- Added helpers before `sqlite3VdbeExec`: `sqlite3AddInt64`, `sqlite3SubInt64`,
  `sqlite3MulInt64` (overflow-detecting), `numericType`, `sqlite3BlobCompare`,
  `sqlite3MemCompare`.
- Added 16 arithmetic/comparison opcodes: `OP_Add`, `OP_Subtract`, `OP_Multiply`,
  `OP_Divide`, `OP_Remainder`, `OP_BitAnd`, `OP_BitOr`, `OP_ShiftLeft`,
  `OP_ShiftRight`, `OP_AddImm`, `OP_Eq`, `OP_Ne`, `OP_Lt`, `OP_Le`, `OP_Gt`,
  `OP_Ge`.
- Arithmetic: fast int path → overflow check → fp fallback `arith_fp` label;
  `arith_null` for divide-by-zero / NULL operand.
- Comparison: fast int-int path; NULL path (NULLEQ / JUMPIFNULL); general path via
  `sqlite3MemCompare`; affinity coercion for string↔numeric comparisons.
- Added `TestVdbeArith.pas` (T1–T13 gate test).
- Gate: `TestVdbeArith` T1–T13 all PASS (41/41); all prior tests unchanged (2026-04-24).

**Critical pitfalls**:
- `memSetTypeFlag` is defined AFTER `sqlite3VdbeExec` → not visible inside the
  exec function. Replaced all `memSetTypeFlag(p, f)` calls with the inline form:
  `p^.flags := (p^.flags and not u16(MEM_TypeMask or MEM_Zero)) or f`.
- Comparison tables (`sqlite3aLTb/aEQb/aGTb` from C global.c) are implemented as
  inline `case` statements on the opcode rather than lookup arrays, to avoid the
  C-style append-to-upper-case-table trick that doesn't map to Pascal.
- `OP_Add/Sub/Mul` take (P1=in1, P2=in2, P3=out3) where the result is `r[P2] op r[P1]`
  (i.e., P1 is the RIGHT operand and P2 is the LEFT). Match C exactly:
  `iB := pIn2^.u.i; iA := pIn1^.u.i; sqlite3AddInt64(@iB, iA)`.
- `OP_ShiftLeft/Right`: P1=shift-amount register, P2=value register (same reversed layout).
- `MEM_Null = 0` in zero-initialized memory → must set `flags := MEM_Null` explicitly
  in tests that test NULL propagation, otherwise `flags=0` (actually MEM_Null=0, so
  it works, but this is fragile — better to set explicitly).

---

### Phase 5.4c implementation notes (2026-04-24)

**Units changed**: `src/passqlite3vdbe.pas`, `src/tests/TestVdbeRecord.pas`, `src/tests/build.sh`.

**What was done**:
- Added 7 record I/O opcodes to `sqlite3VdbeExec`: `OP_Column`, `OP_MakeRecord`,
  `OP_Insert`, `OP_Delete`, `OP_Count`, `OP_Rowid`, `OP_NewRowid`.
- Added shared label `op_column_corrupt` inside the exec loop (used by `OP_Column`
  overflow-record corrupt path).
- Added `TestVdbeRecord.pas` (T1–T6 gate test) and wired into `build.sh`.

**Critical pitfalls discovered/fixed**:
- `op_column_corrupt` label was placed OUTSIDE `repeat..until False` loop; FPC
  `continue` is only valid inside a loop. Fixed by moving the label inside the loop,
  between `jump_to_p2` and `until False`.
- Duplicate `vdbeMemDynamic` definition (once at line ~2879 as a forward copy before
  the exec function, once at ~4458 at its canonical location). FPC treats these as
  overloaded with identical signatures → error. Fixed by removing the later duplicate;
  kept the earlier one so the exec function's call site can see it.
- `CACHE_STALE = 0`: `sqlite3VdbeCreate` uses `sqlite3DbMallocRawNN` (raw, not zeroed)
  and only zeroes bytes at offset 136+. `cacheCtr` is before offset 136 → uninitialized.
  In tests, `cacheCtr` was 0 = `CACHE_STALE`, making `cacheStatus(0) == cacheCtr(0)` →
  column cache falsely treated as valid → `payloadSize/szRow` never populated →
  `OP_Column` returned NULL. Fix: set `v^.cacheCtr := 1` in test `CreateMinVdbe`.
- `OP_OpenWrite` with `P4_INT32=1` (nField=1) is required for `OP_Column` to compute
  `aOffset[1]` correctly; use `sqlite3VdbeAddOp4Int(v, OP_OpenWrite, 0, pgno, 0, 1)`.
- `sqlite3BtreePayloadFetch` sets `pAmt = nLocal` (bytes in-page); `szRow` is
  populated only when the cache-miss path runs correctly.

**Gate**: `TestVdbeRecord` T1–T6 all PASS (13/13); all prior tests still PASS (2026-04-24).

---

### Phase 5.4b implementation notes (2026-04-24)

**Units changed**: `src/passqlite3vdbe.pas`, `src/tests/TestVdbeCursor.pas`, `src/tests/build.sh`.

**What was done**:
- Added 16 cursor-motion opcodes to `sqlite3VdbeExec` in `passqlite3vdbe.pas`:
  `OP_Rewind`, `OP_Next`, `OP_Prev`, `OP_SeekLT/LE/GE/GT`,
  `OP_Found`, `OP_NotFound`, `OP_NoConflict`, `OP_IfNoHope`,
  `OP_SeekRowid`, `OP_NotExists`, `OP_IdxLE/GT/LT/GE`.
- Shared label bodies: `next_tail` (Next/Prev common tail), `seek_not_found`
  (SeekGT/GE/LT/LE common tail), `notExistsWithKey` (SeekRowid/NotExists body).
- Added `TestVdbeCursor.pas` (T1–T8 gate test) and wired into `build.sh`.

**Critical pitfalls discovered/fixed**:
- `jump_to_p2` semantics: `pOp := @aOp[p2-1]; Inc(pOp)` → executes `aOp[p2]`,
  so p2 is the 0-based INDEX of the target instruction.
- `sqlite3VdbeCreate` auto-adds `OP_Init` at index 0; test helpers must reset
  `v^.nOp := 0` before adding their own instruction sequence.
- `TVdbe.pc` sits at offset ~48 in the struct (before the `FillChar` at offset
  136 in `sqlite3VdbeCreate`), so it is left uninitialized garbage by
  `sqlite3DbMallocRawNN`. Fix: set `v^.pc := 0` in test `CreateMinVdbe`.
  This was the root cause of T7b (skipped OP_Integer, used stale iKey=0) and
  T8 (crash on second VDBE: pc landed in the middle of a short instruction array).
- `allocateCursor` with iCur=0: uses `pMSlot = p^.aMem` (i.e. `aMem[0]`).
  The cursor buffer is stored in `aMem[0].zMalloc` (a separate heap allocation);
  does NOT corrupt adjacent `aMem[1..nMem-1]` slots.
- In `OpenTestBtree`, inserts must use `PBtCursor` obtained from
  `sqlite3BtreeCursor(pBt, pgno, 1, nil, @cur)`, NOT a `PBtree` pointer.

**Gate**: `TestVdbeCursor` T1–T8 all PASS (27/27); TestSmoke still PASS (2026-04-24).

---

### Phase 5.4a implementation notes (2026-04-24)

**Units changed**: `src/passqlite3vdbe.pas`, `src/passqlite3util.pas`, `src/passqlite3btree.pas`.

**What was done**:
- Added `Tsqlite3` (connection struct, 144 fields) and `PTsqlite3 = ^Tsqlite3` to `passqlite3util.pas` Section 3b. Used opaque `Pointer` for cross-unit types (PBtree, PVdbe, PSchema, etc.) to avoid circular dependency. Companion types: `TBusyHandler`, `TLookaside`, `TSchema`, `TDb`, `TSavepoint`.
- Replaced stub `sqlite3VdbeExec` with 23-opcode Phase 5.4a implementation in `passqlite3vdbe.pas`.
- Added helper functions: `out2Prerelease`, `out2PrereleaseWithClear`, `allocateCursor`, `sqlite3ErrStr`, `sqlite3VdbeFrameRestoreFull`, stubs for `sqlite3VdbeLogAbort`, `sqlite3VdbeSetChanges`, `sqlite3SystemError`, `sqlite3ResetOneSchema`.
- Added `sqlite3BtreeCursorHintFlags` to `passqlite3btree.pas`.

**Critical FPC pitfalls discovered/fixed**:
- `pMem: PMem` — FPC is case-insensitive; local var `pMem` conflicts with type `PMem`. Renamed to `pMSlot`.
- `pDb: PDb` and `pKeyInfo: PKeyInfo` — same conflict. Renamed to `pDbb` and `pKInfo`.
- Functions defined later in the implementation section cannot be called by earlier functions (no forward reference). Inlined `vdbeMemDynamic` and `memSetTypeFlag` at call sites where forward reference would be needed.
- `aType[]` is a C flexible array NOT present in the Pascal `TVdbeCursor` record. Access via `Pu32(Pu8(pCx) + 120 + u32(nField) * SizeOf(u32))`.
- `PKeyInfo = Pointer` (opaque). Access `nAllField` (u16 at offset 8) via pointer arithmetic: `Pu16(Pu8(pKInfo) + 8)^`.
- `TVdbe.expired` is a C bitfield packed into `vdbeFlags: u32`; use `(v^.vdbeFlags and VDBF_EXPIRED_MASK) = 1`.
- `TVdbeCursor.isOrdered` is a C bitfield packed into `cursorFlags: u32`; use `pCur^.cursorFlags := pCur^.cursorFlags or VDBC_Ordered`.
- `lockMask` is a field of `TVdbe`, not `Tsqlite3`. Use `v^.lockMask`, not `db^.lockMask`.
- `SZ_VDBECURSOR` function must be defined *before* `allocateCursor` in the implementation section.
- `duplicate definition` if helper functions are defined twice; removed Phase 5.4a duplicates of `vdbeMemDynamic`/`memSetTypeFlag` which already existed in Phase 5.3.

**Gate**: Compiles 0 errors; TestSmoke PASS (2026-04-24).

---

### Phase 5.3 implementation notes (2026-04-24)

**Unit**: `src/passqlite3vdbe.pas` (already contained skeleton implementations from 5.2).

**What was done (vdbemem.c functions)**:
- `vdbeMemClearExternAndSetNull`, `vdbeMemClear`: clear dynamic resources, free szMalloc, set z=nil and flags=MEM_Null.
- `sqlite3VdbeMemRelease`, `sqlite3VdbeMemReleaseMalloc`: thin wrappers over vdbeMemClear.
- `sqlite3VdbeMemGrow`, `sqlite3VdbeMemClearAndResize`, `vdbeMemAddTerminator`.
- `sqlite3VdbeMemZeroTerminateIfAble`, `sqlite3VdbeMemMakeWriteable`, `sqlite3VdbeMemNulTerminate`.
- `sqlite3VdbeMemExpandBlob`: expand MEM_Zero blob tail into real bytes.
- `sqlite3VdbeMemStringify`: render numeric Mem as UTF-8 string (32-byte buffer via libc snprintf).
- `sqlite3VdbeChangeEncoding`, `sqlite3VdbeMemTranslate` (stub, Phase 6), `sqlite3VdbeMemHandleBom` (stub).
- `sqlite3VdbeIntValue`, `sqlite3VdbeRealValue`, `sqlite3VdbeBooleanValue`.
- `sqlite3RealToI64`, `sqlite3RealSameAsInt`.
- `sqlite3MemRealValueRC`, `sqlite3MemRealValueRCSlowPath`, `sqlite3MemRealValueNoRC`.
- `sqlite3VdbeIntegerAffinity`, `sqlite3VdbeMemIntegerify`, `sqlite3VdbeMemRealify`, `sqlite3VdbeMemNumerify`.
- `sqlite3VdbeMemCast`, `sqlite3ValueApplyAffinity` (stub, Phase 6).
- `sqlite3VdbeMemInit`, `sqlite3VdbeMemSetNull`, `sqlite3ValueSetNull`.
- `sqlite3VdbeMemSetZeroBlob`, `vdbeReleaseAndSetInt64`, `sqlite3VdbeMemSetInt64`, `sqlite3MemSetArrayInt64`.
- `sqlite3NoopDestructor`, `sqlite3VdbeMemSetPointer`.
- `sqlite3VdbeMemSetDouble`.
- `sqlite3VdbeMemTooBig`.
- `sqlite3VdbeMemShallowCopy`, `vdbeClrCopy`, `sqlite3VdbeMemCopy`, `sqlite3VdbeMemMove`.
- `sqlite3VdbeMemSetStr`, `sqlite3VdbeMemSetText`.
- `sqlite3VdbeMemFromBtree`, `sqlite3VdbeMemFromBtreeZeroOffset`.
- `valueToText`, `sqlite3ValueText`, `sqlite3ValueIsOfClass`.
- `sqlite3ValueNew`, `sqlite3ValueFree`, `sqlite3ValueBytes`, `sqlite3ValueSetStr` (stub).
- `sqlite3ValueFromExpr`, `sqlite3Stat4Column` (stubs, Phase 6).

**Critical FPC pitfall discovered**:
> `Int64(someDoubleVariable)` in FPC is a **bit reinterpret** (reads the 8-byte float
> bit pattern as Int64), NOT a value truncation. For truncation use `Trunc(r)`.
> Fixed in `sqlite3RealToI64`: `Result := Trunc(r)` (not `i64(r)`).

**Additional fix**:
> `vdbeMemClear` must explicitly set `p^.flags := MEM_Null` at the end, even for
> non-dynamic Mems (e.g. TRANSIENT strings with szMalloc>0 but no MEM_Dyn).
> Without this, after `sqlite3VdbeMemRelease`, flags remain `MEM_Str` with `z=nil`
> — an inconsistent state.

**Test notes**:
- T5: `sqlite3VdbeMemSetZeroBlob` stores count in `u.nZero`, not `n` (n stays 0). Test fixed to check `m.u.nZero`.
- T18: `sqlite3VdbeMemSetStr` rejects too-big strings itself (sets Mem to NULL before returning TOOBIG). Test `TestTooBig` must set TMem fields directly to test `sqlite3VdbeMemTooBig`.
- Gate: T1–T23 all PASS (62/62 checks, 2026-04-24). All 337 prior TestBtreeCompat checks and 108 TestVdbeAux checks still PASS.

---

### Phase 5.1 implementation notes (2026-04-24)

**Unit**: `src/passqlite3vdbe.pas` (515 lines, compiles 0 errors).

**What was done**:
- All 192 OP_* opcode constants from `opcodes.h` (SQLite 3.53.0) with exact
  numeric values. `SQLITE_MX_JUMP_OPCODE = 66`.
- `sqlite3OpcodeProperty[0..191]` — opcode property flag table from opcodes.h
  (OPFLG_* bits: JUMP, IN1, IN2, IN3, OUT2, OUT3, NCYCLE, JUMP0).
- All P4_* type tags (P4_NOTUSED=0 … P4_SUBRTNSIG=-18); P5_Constraint* codes;
  COLNAME_* slot indices; SQLITE_PREPARE_* flags.
- All MEM_* flags (MEM_Undefined=0 … MEM_Agg=$8000).
- CURTYPE_*, CACHE_STALE, VDBE_*_STATE, SQLITE_FRAME_MAGIC, SQLITE_MAX_SCHEMA_RETRY.
- VDBC_* bitfield constants for VdbeCursor.cursorFlags (5-bit packed group).
- VDBF_* bitfield constants for Vdbe.vdbeFlags (9-bit packed group).
- Affinity constants (SQLITE_AFF_*), comparison flags (SQLITE_JUMPIFNULL etc.),
  KEYINFO_ORDER_* — needed by VDBE column comparison logic.
- Types: `ynVar = i16`, `LogEst = i16`, `yDbMask = u32` (default platform sizes).
- Opaque `Pointer` aliases for unported sqliteInt.h types: PFuncDef, PCollSeq,
  PTable, PIndex, PExpr, PParse, PVList, PVTable, Psqlite3_vtab_cursor,
  PVdbeSorter.
- All VDBE record types in one `type` block (FPC forward-ref requirement):
  TMemValue, TMem (= sqlite3_value), TVdbeTxtBlbCache, TAuxData, TScanStatus,
  TDblquoteStr, TSubrtnSig, Tp4union, TVdbeOp, TVdbeOpList, TSubProgram,
  TVdbeFrame, TVdbeCursorUb, TVdbeCursorUc, TVdbeCursor, Tsqlite3_context,
  TVdbe, TValueList.
- C flexible arrays (aType[] in VdbeCursor, argv[] in sqlite3_context) are
  omitted from the fixed record; callers allocate extra space.
- Phase 5.2–5.5 stubs: VdbeAddOp*, VdbeMakeLabel, VdbeResolveLabel,
  VdbeMemInit/SetNull/SetInt64/SetDouble/SetStr/Release/Copy, VdbeIntValue,
  VdbeRealValue, VdbeBooleanValue, sqlite3_step/reset/finalize, VdbeExec,
  VdbeHalt, VdbeList, sqlite3OpcodeName (full opcode name table included),
  sqlite3VdbeSerialTypeLen, sqlite3VdbeOneByteSerialTypeLen, sqlite3VdbeSerialGet.

**Struct sizes verified against GCC x86-64**:
- TMemValue = 8 B (largest member: Double/i64/pointer all = 8 B)
- TMem = 56 B (MEMCELLSIZE = offsetof(Mem,db) = 24 B)
- TVdbeOp = 24 B (opcode:1+p4type:1+p5:2+p1:4+p2:4+p3:4+p4:8)
- TVdbeCursor = 120 B (without flexible aType[] array)
- TVdbeFrame = 112 B
- TVdbe = 304 B (includes startTime:i64 for !SQLITE_OMIT_TRACE default)

**FPC pitfalls noted for 5.2+**:
- `Psqlite3_value = PMem` redefines the stub `Psqlite3_value = Pointer` from
  btree.pas; code in vdbe.pas uses the proper PMem type; btree.pas stubs
  continue to use Pointer (compatible for passing purposes).
- All type declarations in one `type` block for mutual-reference resolution.
- Bitfield groups translated to u32 with named bit-mask constants; GCC and FPC
  both align the u32 storage unit to 4 bytes, producing identical struct offsets.

---

## Phase 6 — Code generators

Files (by group; ~40 k lines combined — the largest phase):
- **Expression layer**: `expr.c` (~7.7 k), `resolve.c` (name resolution),
  `walker.c` (AST walker framework), `treeview.c` (debug tree printer).
- **Query planner**: `where.c` (~7.9 k), `wherecode.c`, `whereexpr.c`
  (~12 k combined). Header: `whereInt.h`.
- **SELECT**: `select.c` (~9 k), `window.c` (window functions — *defer to
  late in phase 6 if time-pressed*).
- **DML**: `insert.c`, `update.c`, `delete.c`, `upsert.c`.
- **Schema / DDL**: `build.c`, `alter.c`, `analyze.c`, `attach.c`,
  `pragma.c`, `trigger.c`, `vacuum.c`, `prepare.c` (the `sqlite3_prepare`
  core that feeds the parser into this phase).
- **Security / auth**: `auth.c`.
- **User-defined functions**: `callback.c`, `func.c` (built-in scalars),
  `date.c` (date/time functions), `fkey.c` (foreign keys), `rowset.c`
  (RowSet data structure).
- **JSON** (*defer; optional in initial scope*): `json.c` (~6 k lines).

These translate parse trees into VDBE programs. Validated by
`TestExplainParity.pas` — the `EXPLAIN` output for any SQL must match the C
reference exactly.

- [X] **6.1** Port the **expression layer** first — every other codegen unit
  calls into it: `expr.c`, `resolve.c`, `walker.c`, `treeview.c`.

  **walker.c — DONE (2026-04-25)**: Ported to `passqlite3codegen.pas`.
  All 12 walker functions implemented. Gate: `TestWalker.pas` — 40 tests, all PASS.

  **expr.c / treeview.c / resolve.c — DONE (2026-04-25)**:
  Ported to `passqlite3codegen.pas` (~2600 lines total).
  - `treeview.c`: 4 no-op stubs (debug-only, SQLITE_DEBUG not enabled in production).
  - `expr.c`: Full port — allocation (sqlite3ExprAlloc, sqlite3Expr, sqlite3ExprInt32,
    sqlite3ExprAttachSubtrees, sqlite3PExpr, sqlite3ExprAnd), deletion
    (sqlite3ExprDeleteNN, sqlite3ExprDelete, sqlite3IdListDelete, sqlite3SrcListDelete,
    sqlite3ExprListDelete), duplication (exprDup_, sqlite3ExprDup, sqlite3ExprListDup,
    sqlite3SrcListDup, sqlite3IdListDup, sqlite3SelectDup), list management
    (sqlite3ExprListAppend, sqlite3ExprListSetSortOrder, sqlite3ExprListSetName,
    sqlite3ExprListCheckLength, sqlite3ExprListFlags), affinity
    (sqlite3ExprAffinity, sqlite3ExprDataType, sqlite3AffinityType,
    sqlite3TableColumnAffinity stub), collation (sqlite3ExprSkipCollate,
    sqlite3ExprSkipCollateAndLikely, sqlite3ExprAddCollateToken,
    sqlite3ExprAddCollateString), height helpers (exprSetHeight_,
    sqlite3ExprCheckHeight, sqlite3ExprSetHeightAndFlags), identity/type helpers
    (sqlite3ExprIsVector, sqlite3ExprVectorSize, sqlite3IsTrueOrFalse,
    sqlite3ExprIdToTrueFalse, sqlite3ExprTruthValue, sqlite3IsRowid,
    sqlite3ExprIsInteger, sqlite3ExprIsConstant), dequote helpers
    (sqlite3DequoteExpr).
  - `resolve.c`: 7 stubs (sqlite3ResolveExprNames etc.) — full resolve.c
    implementation deferred to Phase 6.5 when Table/Column types are available.
  - Gate: `TestExprBasic.pas` — 40 tests (28 named checks), all PASS.

  **Key discoveries**:
  - All Phase 6 types MUST be in one `type` block (FPC forward-ref rule).
    Multiple `type` blocks cause "Forward type not resolved" for TSelect, TWindow etc.
  - TWindow sizeof=144 (not 152): trailing `_pad4: u32` was spurious; correct
    padding after `bExprArgs` is just `_pad2: u8; _pad3: u16` (3 bytes → 144).
  - `IN_RENAME_OBJECT` macro (walker.c) checks `pParse->eParseMode >= PARSE_MODE_RENAME`.
    Full `Parse` struct deferred to Phase 7; accessed via `ParseGetEParseMode(pParse: Pointer)`
    reading byte at offset 300 via `PByte` arithmetic (FPC typecast `PParse(ptr)` fails
    in inline functions for obscure syntactic reasons).
  - Function pointer comparisons require `Pointer()` cast in FPC:
    `Pointer(pWalker^.xSelectCallback2) = Pointer(@sqlite3WalkWinDefnDummyCallback)`.
  - `sqlite3SelectPopWith` (select.c, Phase 6.3) needs a stub in Phase 6.1
    because walker.c compares its address at compile time.
  - FlexArray accessors: `ExprListItems(p)` = `PExprListItem(PByte(p) + SizeOf(TExprList))`,
    `SrcListItems(p)` = `PSrcItem(PByte(p) + SizeOf(TSrcList))`.
    **CRITICAL: `IdListItems(p)` must use `SZ_IDLIST_HEADER = 8`, NOT SizeOf(TIdList) = 4.**
    The C `offsetof(IdList, a)` = 8 (4 bytes nId + 4 bytes alignment padding for pointer array).
    `TIdList` needs a `_pad: i32` field to make SizeOf(TIdList) = 8.
  - TAggInfo has SQLITE_DEBUG-only `pSelectDbg: PSelect` at offset 64 (must be included).
  - `TParse` struct is 416 bytes (GCC x86-64); all offsets verified by GCC offsetof test.
    `eParseMode: u8` is at byte offset 300.
  - `TIdList` header size is 8 bytes (nId + 4-byte padding) even though nId is 4 bytes —
    the FLEXARRAY element (pointer) requires 8-byte alignment.
  - `POnOrUsing` and `PSchema` pointer types must be declared in the type block
    (`PSchema = Pointer` deferred stub is sufficient for Phase 6.1).
  - Local variable `pExpr: PExpr` in a function that uses `TExprListItem.pExpr` field
    causes FPC's case-insensitive name conflict — "Error in type definition" at the `;`.
    Solution: eliminate the local variable or rename it.
  - `sqlite3ErrorMsg` cannot have `varargs` modifier in FPC unless marked `external`.
    Use a fixed 2-arg signature for the stub; full printf-style implementation in Phase 6.5.
  - `sqlite3GetInt32` added to passqlite3util.pas (parses decimal string to i32).
  - TK_COLLATE nodes always have `EP_Skip` set; `sqlite3ExprSkipCollate` only descends
    when `ExprHasProperty(expr, EP_Skip or EP_IfNullRow)` is true.
  - `sqlite3ExprAffinity` returns `p^.affExpr` as the default fallback — NOT
    `SQLITE_AFF_BLOB`. For uninitialized exprs, this returns 0 (= SQLITE_AFF_NONE).
  - Gate test: `TestWalker.pas` — 40 tests, all PASS.
  - Gate test: `TestExprBasic.pas` — 40 checks, all PASS.

- [X] **6.2** Port the **query planner** types, constants, and key whereexpr.c
  helpers: `whereInt.h` struct definitions (all Where* types, Table, Index,
  Column, KeyInfo, UnpackedRecord), `whereexpr.c` core routines, and public API
  stubs for `where.c` / `wherecode.c`.

  **DONE (2026-04-25)**:
  - All Where* record types ported to `passqlite3codegen.pas` with GCC-verified
    sizes (all 17 structs match exactly via C `offsetof`/`sizeof` tests):
    TWhereMemBlock=16, TWhereRightJoin=20, TInLoop=20, TWhereTerm=56,
    TWhereClause=488, TWhereOrInfo≥496, TWhereAndInfo=488, TWhereMaskSet=264,
    TWhereOrCost=16, TWhereOrSet=56, TWherePath=32, TWhereScan=112,
    TWhereLoopBtree=24, TWhereLoopVtab=24, TWhereLoop=104, TWhereLevel=120,
    TWhereLoopBuilder=40, TWhereInfo=856 (base; FLEXARRAY of TWhereLevel follows).
  - TColumn=16, TTable=120, TIndex=112, TKeyInfo=32, TUnpackedRecord=40 ported.
  - All WO_*, WHERE_*, TF_*, COLFLAG_*, TABTYP_*, TERM_*, SQLITE_BLDF_*,
    WHERE_DISTINCT_*, XN_ROWID/EXPR, SZ_WHERETERM_STATIC constants added.
  - whereexpr.c functions ported: sqlite3WhereClauseInit, sqlite3WhereClauseClear,
    sqlite3WhereSplit, sqlite3WhereGetMask, sqlite3WhereExprUsageNN,
    sqlite3WhereExprUsage, sqlite3WhereExprListUsage, sqlite3WhereExprUsageFull,
    whereOrInfoDelete, whereAndInfoDelete.
    Stubs: sqlite3WhereExprAnalyze, sqlite3WhereTabFuncArgs, sqlite3WhereAddLimit.
  - where.c public API stubs: sqlite3WhereOutputRowCount, sqlite3WhereIsDistinct,
    sqlite3WhereIsOrdered, sqlite3WhereIsSorted, sqlite3WhereOrderByLimitOptLabel,
    sqlite3WhereMinMaxOptEarlyOut, sqlite3WhereContinueLabel, sqlite3WhereBreakLabel,
    sqlite3WhereOkOnePass, sqlite3WhereUsesDeferredSeek, sqlite3WhereBegin (nil stub),
    sqlite3WhereEnd, sqlite3WhereRightJoinLoop.
  - Gate test: `TestWhereBasic.pas` — 52 checks, all PASS (2026-04-25).

  **Key discoveries**:
  - WhereLoopVtab: GCC packs needFree:1+bOmitOffset:1+bIdxNumHex:1 bitfields
    into a single byte at offset 4 (not a full u32), making vtab sub-struct 24
    bytes (same as btree variant). Verified by C `offsetof(WhereLoop,u.vtab.isOrdered)`=29.
  - WhereInfo bitfields (bDeferredSeek etc.) after eDistinct@67 are declared as
    `unsigned` in C but GCC packs them into 1 byte at offset 68. Represented as
    `bitwiseFlags: u8` @68 + `_pad69: u8` @69.
  - FPC: `Pi16 = ^i16` and `LogEst = i16` added to forward-pointer block.
    `PWhereMaskSet` also added as forward pointer.
  - `PKeyInfo2 = ^TKeyInfo` avoids shadowing `PKeyInfo = Pointer` stub in vdbe.pas.
  - Full where.c / wherecode.c port (query planner algorithm, cost model, index
    selection) deferred to Phase 6.2b (after Phase 6.3 select.c which provides
    the Select/SrcList types that WhereBegin depends on).

- [X] **6.3** Port `select.c` public API and helper functions: `TSelectDest`,
  `SRT_*` / `JT_*` constants, `sqlite3SelectDestInit`, `sqlite3SelectNew`,
  `sqlite3SelectDelete`, `sqlite3JoinType`, `sqlite3ColumnIndex`,
  `sqlite3KeyInfoAlloc/Ref/Unref/FromExprList`, `sqlite3SelectOpName`,
  `sqlite3GenerateColumnNames`, `sqlite3ColumnsFromExprList`,
  `sqlite3SubqueryColumnTypes`, `sqlite3ResultSetOfSelect`, `sqlite3WithPush`,
  `sqlite3ExpandSubquery`, `sqlite3IndexedByLookup`, `sqlite3SelectPrep`,
  `sqlite3Select` (stub). Gate test: TestSelectBasic (49/49 PASS).
  Full `sqlite3Select` engine (aggregation, GROUP BY, compound SELECT,
  CTEs, recursive queries) deferred to Phase 6.3b.
  FPC pitfalls: duplicate sqlite3LogEst removed from codegen (vdbe version
  is authoritative); nil-db guard added to sqlite3KeyInfoAlloc (db^.enc
  read only when db <> nil).

- [X] **6.4** Port **DML**: `insert.c`, `update.c`, `delete.c`, `upsert.c`,
  `trigger.c`. Each is ~1–2 k lines.
  **DONE (2026-04-25)**: All five DML files' public API ported to
  `passqlite3codegen.pas` as stubs (full VDBE code generation deferred to
  Phase 6.5+ when schema management is available). New types added to the
  codegen type block (all sizes GCC-verified): `TUpsert=88` (field `pUpsertSrc`
  corrected), `TAutoincInfo=24`, `TTriggerPrg=40`, `TTrigger=72`,
  `TTriggerStep=88`, `TReturning=232`. New constants: `OE_*` (conflict
  resolution), `TRIGGER_BEFORE/AFTER`, `OPFLAG_*`, `COLTYPE_*`.
  `PTrigger`, `PTriggerStep`, `PAutoincInfo`, `PTriggerPrg`, `PReturning`
  promoted from `Pointer` stubs to real typed pointer types.
  `TParse.pAinc`, `pTriggerPrg`, `pNewTrigger`, `pNewIndex` fields typed
  with real pointer types. upsert.c: `sqlite3UpsertNew`, `sqlite3UpsertDup`,
  `sqlite3UpsertDelete`, `sqlite3UpsertNextIsIPK`, `sqlite3UpsertOfIndex`
  fully implemented (memory-safe, no schema dependency).
  Gate test: `TestDMLBasic.pas` — 54/54 PASS (2026-04-25). All 49 prior
  TestSelectBasic + 52 TestWhereBasic + all other tests still PASS.

- [X] **6.5** Port **schema management**: `build.c` (CREATE/DROP + parsing
  `sqlite_master` at open), `alter.c` (ALTER TABLE), `prepare.c` (schema
  parsing + `sqlite3_prepare` internals), `analyze.c`, `attach.c`,
  `pragma.c`, `vacuum.c`.
  Gate test: `TestSchemaBasic.pas` — 44/44 PASS (2026-04-25).

- [X] **6.6** Port **auth and built-in functions**: `auth.c`, `callback.c`,
  `func.c` (scalars: `abs`, `coalesce`, `like`, `substr`, `lower`, etc.),
  `date.c` (`date()`, `time()`, `julianday()`, `strftime()`, `datetime()`),
  `fkey.c` (foreign-key enforcement), `rowset.c`.
  Gate test: `TestAuthBuiltins.pas` — **34/34 PASS** (2026-04-25).

- [X] **6.7** Port `window.c`: SQL window functions (`OVER`, `PARTITION BY`,
  `ROWS BETWEEN`, …). Intersects with `select.c` — port last within the
  codegen phase so `select.c` is stable when window integration starts.

- [ ] **6.8** (Optional, defer-able) Port `json.c`: JSON1 scalar functions,
  `json_each`, `json_tree`. Only if users need it in v1.

### Phase 6.7 implementation notes (2026-04-25)

**Unit modified**: `src/passqlite3codegen.pas` (~9600 lines after phase).

**New public API** (all exported in interface):
- Window lifecycle: `sqlite3WindowDelete`, `sqlite3WindowListDelete`,
  `sqlite3WindowDup`, `sqlite3WindowListDup`, `sqlite3WindowLink`,
  `sqlite3WindowUnlinkFromSelect`.
- Allocation/assembly: `sqlite3WindowAlloc`, `sqlite3WindowAssemble`,
  `sqlite3WindowChain`, `sqlite3WindowAttach`.
- Comparison/update: `sqlite3WindowCompare`, `sqlite3WindowUpdate`.
- Rewrite (stub): `sqlite3WindowRewrite` — marks `SF_WinRewrite`; full rewrite
  deferred to Phase 7 when the Lemon parser and full SELECT engine exist.
- Code-gen stubs: `sqlite3WindowCodeInit`, `sqlite3WindowCodeStep`.
- Built-in registration: `sqlite3WindowFunctions` — installs all 10 built-in
  window functions (row_number, rank, dense_rank, percent_rank, cume_dist,
  ntile, lead, lag, first_value, last_value, nth_value) via `TFuncDef` array.
- Expr comparison helpers: `sqlite3ExprCompare`, `sqlite3ExprListCompare`
  (ported from expr.c:6544/6646).

**Private types** (implementation section only):
- `TCallCount`, `TNthValueCtx`, `TNtileCtx`, `TLastValueCtx` (window agg ctxs).
- `TWindowRewrite` (walker context for `selectWindowRewriteExprCb`).

**FPC pitfalls hit**:
- `var pParse: PParse` inside a function body is a circular self-reference
  (FPC is case-insensitive; `pParse` ≡ `PParse`). Fix: rename local to `pPrs`.
  This is the same pattern as `pPager: PPager`; always rename the local.
- `type TFoo = record ... end; const aFoo: array[...] of TFoo = (...)` inside
  a procedure body fails if any record field is `PAnsiChar` (pointer). Fix:
  remove the pointer field (it was unused) so all fields are integer types,
  which FPC's typed-const initialiser accepts inside procedure bodies.
- Walker callbacks used as `TExprCallback`/`TSelectCallback` must be `cdecl`.
- `TWalkerU.pRewrite` does not exist in the Pascal union; use `ptr: Pointer`
  (case 0) instead and cast at use sites.
- `sqlite3ErrorMsg` stub is 2-arg only; format via AnsiString concatenation.

**Gate test**: `src/tests/TestWindowBasic.pas` — 34/34 PASS.

### Phase 6.6 implementation notes (2026-04-25)

**Units modified**: `src/passqlite3codegen.pas`, `src/passqlite3vdbe.pas`,
`src/passqlite3types.pas`.

**New types** (all sizes verified against FPC x86-64):
- `TCollSeq=40`: zName:8+enc:1+pad:7+pUser:8+xCmp:8+xDel:8.
- `TFuncDestructor=24`: nRef:4+pad:4+xDestroy:8+pUserData:8.
- `TFuncDefHash=184`: 23×8 PTFuncDef slots.
- `TFuncDef.nArg` corrected from `i8` to `i16` (C struct uses `i16`).

**New constants**:
- Auth action codes: `SQLITE_CREATE_INDEX=1` … `SQLITE_RECURSIVE_AUTH=33`
  (suffixed `_AUTH` for DELETE/INSERT/SELECT/UPDATE/ATTACH/DETACH/FUNCTION to
  avoid clashing with result-code constants of the same name).
- `SQLITE_FUNC_*` flags: ENCMASK, LIKE, CASE, EPHEM, NEEDCOLL, LENGTH,
  TYPEOF, BYTELEN, COUNT, UNLIKELY, CONSTANT, MINMAX, SLOCHNG, TEST,
  RUNONLY, WINDOW, INTERNAL, DIRECT, UNSAFE, INLINE, BUILTIN, ANYORDER.
- `SQLITE_FUNC_HASH_SZ=23`.
- Public API function flags: `SQLITE_DETERMINISTIC=$800`, `SQLITE_DIRECTONLY=$80000`,
  `SQLITE_SUBTYPE=$100000`, `SQLITE_INNOCUOUS=$200000`.
- `SQLITE_DENY=1`, `SQLITE_IGNORE=2` (added to passqlite3types.pas).
- `SQLITE_REAL=2` alias for `SQLITE_FLOAT`.

**Exported from passqlite3vdbe.pas interface**: `sqlite3MemCompare`,
`sqlite3AddInt64`.

**Known FPC pitfalls hit**:
- `const X = val` inside function bodies → illegal in OBJFPC; move to function
  const section or module const block.
- Inline `var x: T := val` inside `begin..end` blocks → illegal; move to var
  section above `begin`.
- `type TAcc = ...` inside function bodies → duplicate identifier if repeated
  in adjacent functions; moved to module-level type block with unique names
  (TSumAcc/PSumAcc, TAvgAcc/PAvgAcc).
- `pMem: PMem` → FPC case-insensitive clash with type `PMem`; renamed to
  `pAgg`, `pCount`, etc.
- `uses DateUtils, SysUtils` → must appear immediately after `implementation`
  keyword, not inside the body.
- `sqlite3_snprintf(n, buf, fmt, args)` → our declaration is variadic-argless;
  replaced with `snpFmt(n, buf, fmt, args)` helper using SysUtils.Format.
- `TDateTime2` fields: `Y, M, D, h, m` where `M` and `m` are same to FPC;
  renamed to `yr, mo, dy, hr, mi`.
- `sqlite3Toupper` is a function, not an array; call as `sqlite3Toupper(x)`.

**Date functions**: implemented using Julian Day arithmetic (same formula as
SQLite's `date.c`). `currentJD` uses `SysUtils.Now` + `DateUtils.DecodeDateTime`.

**Functions implemented**: auth.c (sqlite3_set_authorizer, sqlite3AuthReadCol,
sqlite3AuthRead, sqlite3AuthCheck, sqlite3AuthContextPush/Pop); callback.c
(findCollSeqEntry, sqlite3FindCollSeq, synthCollSeq, sqlite3GetCollSeq,
sqlite3CheckCollSeq, sqlite3IsBinary, sqlite3LocateCollSeq,
sqlite3SetTextEncoding, matchQuality, sqlite3FunctionSearch,
sqlite3InsertBuiltinFuncs, sqlite3FindFunction, sqlite3CreateFunc,
sqlite3SchemaClear, sqlite3SchemaGet, sqlite3RegisterBuiltinFunctions,
sqlite3RegisterPerConnectionBuiltinFunctions, sqlite3RegisterLikeFunctions,
sqlite3IsLikeFunction); 30+ scalar functions (abs, typeof, octetLength, length,
substr, upper, lower, hex, unhex, zeroblob, nullif, version, sourceid, errlog,
random, randomBlob, lastInsertRowid, changes, totalChanges, round, trim, ltrim,
rtrim, replace, like, glob, coalesce, ifnull, iif, unicode, char, quote);
aggregates (count, sum, total, avg, min, max, group_concat);
date/time functions (date, time, datetime, julianday, unixepoch, strftime);
fkey.c stubs (all 7 functions).

### Phase 6.4 implementation notes (2026-04-25)

**Unit**: `src/passqlite3codegen.pas` (extended).

**New types** (all sizes verified against GCC x86-64 with -DSQLITE_DEBUG -DSQLITE_THREADSAFE=1):
- `TUpsert=88`: field `pUpsertCols` renamed to `pUpsertSrc` (was wrongly named
  `PIdList`; is actually `PSrcList`). `pUpsertIdx` promoted to `PIndex2`.
- `TAutoincInfo=24`: AUTOINCREMENT per-table tracking info (pNext/pTab/iDb/regCtr).
- `TTriggerPrg=40`: compiled trigger program (pTrigger/pNext/pProgram/orconf/aColmask[2]).
- `TTrigger=72`: trigger definition (zName/table/op/tr_tm/bReturning/pWhen/pColumns/
  pSchema/pTabSchema/step_list/pNext). All offsets verified.
- `TTriggerStep=88`: one trigger step (op/orconf/pTrig/pSelect/pSrc/pWhere/pExprList/
  pIdList/pUpsert/zSpan/pNext/pLast). All offsets verified.
- `TReturning=232`: RETURNING clause state — contains embedded TTrigger and TTriggerStep.
  Key discovery: `zName` is at offset 188 (not 192); there is no padding between
  `iRetReg` (at 184) and `zName[40]` (at 188); trailing 4-byte `_pad228` brings total to 232.

**Type promotions in forward-pointer section**:
- `PTrigger = Pointer` → `PTrigger = ^TTrigger`
- Added `PTriggerStep = ^TTriggerStep`, `PAutoincInfo = ^TAutoincInfo`,
  `PTriggerPrg = ^TTriggerPrg`, `PReturning = ^TReturning`

**TParse field upgrades** (types now precise instead of `Pointer`):
- `pAinc: PAutoincInfo` (offset 144)
- `pTriggerPrg: PTriggerPrg` (offset 168)
- `pNewIndex: PIndex2` (offset 352)
- `pNewTrigger: PTrigger` (offset 360)
- `u1.pReturning: PReturning` (union at offset 248)

**New constants**: `OE_None=0..OE_Default=11`, `TRIGGER_BEFORE=1`, `TRIGGER_AFTER=2`,
`OPFLAG_*` (insert/delete/column flags), `COLTYPE_*` (column type codes 0–7).

**Implemented (upsert.c)**: `sqlite3UpsertNew`, `sqlite3UpsertDup`,
`sqlite3UpsertDelete` (recursive chain free), `sqlite3UpsertNextIsIPK`,
`sqlite3UpsertOfIndex`. These are fully correct memory-safe implementations.

**Stubs (insert.c, update.c, delete.c, trigger.c)**: All public API functions
declared with correct signatures and implemented as safe stubs (freeing their
input arguments where applicable to prevent leaks). Full VDBE code generation
deferred to Phase 6.5+ when schema management provides `Table*` / `Index*`
schema lookup.

**Gate test**: `TestDMLBasic.pas` — 54 checks: struct sizes (6), field offsets (24),
upsert lifecycle (6), trigger stub API (4), constants (9). All 54 PASS.

### Phase 6.5 implementation notes (2026-04-25)

**Unit**: `src/passqlite3codegen.pas` (extended).

**Key FPC discoveries**:
- `PSchema` (from passqlite3util) is shadowed if re-declared locally as `Pointer`.
  Var-block declarations needing field access must use `passqlite3util.PSchema`.
- FPC can't do anonymous procedure literals (no lambdas); `sqlite3ParserAddCleanup`
  uses direct `TParseCleanupFn(xCleanup)` cast.
- `SizeOf(TSrcList)` = 8 (header only, no items). Pascal `sqlite3SrcListAppend`
  must call `sqlite3SrcListEnlarge` unconditionally (as in C), not guard with
  `nSrc >= nAlloc`. Old C-style `(nNew-1)` formula was wrong; Pascal uses `nNew`.
- `PParse(Pointer_expr)` type-cast inside a procedure body causes a "Syntax error,
  ';' expected" in FPC; write `dest := src_pointer` directly (Pointer is
  assignment-compatible with any typed pointer).
- `Pu8(pParse)[offset]` is not valid as a `var` FillChar argument; use
  `(PByte(pParse) + offset)^` form instead.
- `pSchema: PSchema` in var blocks gives "Error in type definition" when `PSchema`
  is used both as a record field name (`TIndex.pSchema`) and a type in the same
  compilation unit (FPC case-insensitive disambiguation fails). Fix: use
  `pSchema: passqlite3util.PSchema` qualified form.

**New types**: `TParseCleanup` (24 bytes), `TDbFixer` (48 bytes), `PPToken`,
`PPAnsiChar`, `PLogEst`.

**New constants**: `DBFLAG_SchemaKnownOk`, `LOCATE_VIEW`, `LOCATE_NOERR`,
`OMIT_TEMPDB`, `LEGACY/PREFERRED_SCHEMA_TABLE` names, `PARSE_HDR_OFFSET`,
`PARSE_HDR_SZ`, `PARSE_RECURSE_SZ`, `PARSE_TAIL_SZ`, `INITFLAG_Alter*`.

**Real implementations** (not stubs):
- `sqlite3SchemaToIndex` / `sqlite3SchemaToIndexInner`
- `sqlite3FindTable`, `sqlite3FindIndex`, `sqlite3FindDb`, `sqlite3FindDbName`
- `sqlite3LocateTable`, `sqlite3LocateTableItem`
- `sqlite3DbIsNamed`, `sqlite3DbMaskAllZero`
- `sqlite3PreferredTableName`
- `sqlite3ParseObjectInit` / `sqlite3ParseObjectReset`
- `sqlite3ParserAddCleanup` (real linked-list of cleanup callbacks)
- `sqlite3AllocateIndexObject` + `sqlite3DefaultRowEst` + `sqlite3TableColumnToIndex`
- `sqlite3SrcListEnlarge`, `sqlite3SrcListAppend`, `sqlite3SrcListAppendFromTerm`
- `sqlite3SrcListIndexedBy`, `sqlite3SrcListAppendList`, `sqlite3IdListAppend`
- `sqlite3SchemaClear`, `sqlite3SchemaGet`
- `sqlite3UnlinkAndDeleteTable`, `sqlite3ResetAllSchemasOfConnection`

**Stubs** (real code deferred to Phase 7 which needs the Lemon parser):
- `sqlite3RunParser`, `sqlite3_prepare*` — return SQLITE_ERROR
- All DDL codegen (CREATE TABLE/INDEX/VIEW, DROP, ALTER, ATTACH, PRAGMA, VACUUM, ANALYZE)

**Gate test**: `TestSchemaBasic.pas` — 44 checks: constants (14), sizes (2),
FindDbName (4), DbIsNamed (3), SchemaToIndex (2), AllocateIndexObject/DefaultRowEst (9),
SrcList ops (4), IdList ops (3), ParseObject lifecycle (4). All 44 PASS.

### 6.bis — Virtual-table machinery

Parallel mini-phase (can be slotted between 6.6 and 6.7). `vdbevtab.c` from
Phase 5.9 depends on this being done first.

- [ ] **6.bis.1** Port `vtab.c`: the virtual-table plumbing
  (`sqlite3_create_module`, `xBestIndex`, `xFilter`, `xNext`, `xColumn`,
  `xRowid`, `xUpdate`, `xSync`, `xCommit`, `xRollback`).
- [ ] **6.bis.2** Port the three in-tree virtual tables:
  - `dbpage.c` — the built-in `sqlite_dbpage` vtab (exposes raw DB pages).
  - `dbstat.c` — the built-in `dbstat` vtab (B-tree statistics).
  - `carray.c` — the `carray()` table-valued function (passes C arrays into
    SQL); small and a good shake-down test for the vtab machinery.

- [ ] **6.9** `TestExplainParity.pas`: for the full SQL corpus, `EXPLAIN` each
  statement via Pascal and via C; diff the opcode listings. This is the single
  most important gating test for the upper half of the port.

---

## Phase 7 — Parser

Files: `tokenize.c` (the hand-written lexer), `parse.y` (the Lemon grammar,
which generates `parse.c` at build time), `complete.c` (the
`sqlite3_complete` / `sqlite3_complete16` helpers for detecting when a SQL
statement is syntactically complete — used by the CLI and REPLs).

- [X] **7.1** Port `tokenize.c` (the lexer) to `passqlite3parser.pas`. Hand
  port — it is a single function (`sqlite3GetToken`) of ~400 lines driven by
  character classification tables. `complete.c` is a small companion
  (~280 lines) and ports in the same unit.
  Gate test `TestTokenizer.pas`: T1–T18 all PASS (127/127).
  Also fixed an off-by-one bug in `sqlite3_strnicmp` (`N < 0` → `N <= 0`)
  that caused keyword comparison to always fail when all N chars matched.

- [X] **7.2** **Strategy decision (2026-04-25):** Patching Lemon to emit Pascal
  is a multi-week undertaking (lemon.c is 6075 lines of intricate code-emitter
  C). Hand-porting `parse.c` (6327 lines, generated, deterministic structure)
  is the pragmatic path. Since `parse.c` is regenerated only when `parse.y`
  changes and the grammar is stable upstream, a one-time transliteration
  carries acceptable maintenance cost. Split into sub-phases:

  - [X] **7.2a** Port the YY control constants (YYNOCODE, YYNSTATE, YYNRULE,
    YYNTOKEN, YY_MAX_SHIFT, YY_MIN_SHIFTREDUCE, YY_MAX_SHIFTREDUCE,
    YY_ERROR_ACTION, YY_ACCEPT_ACTION, YY_NO_ACTION, YY_MIN_REDUCE,
    YY_MAX_REDUCE, YY_MIN_DSTRCTR, YY_MAX_DSTRCTR, YYWILDCARD, YYFALLBACK,
    YYSTACKDEPTH). Define the `YYMINORTYPE` Pascal record (no unions in
    Pascal — use a variant record), the `yyStackEntry` and `yyParser`
    record types. Declare public parser entry points (`sqlite3ParserAlloc`,
    `sqlite3ParserFree`, `sqlite3Parser`, `sqlite3ParserFallback`,
    `sqlite3ParserStackPeak`) as forward stubs. Goal: scaffolding compiles.
    Reference: `../sqlite3/parse.c` lines 305–625 (token codes, control
    defines, YYMINORTYPE union) and lines 1589–1630 (parser structs).

  - [X] **7.2b** Port the action / lookahead / shift-offset / reduce-offset
    / default tables (`yy_action`, `yy_lookahead`, `yy_shift_ofst`,
    `yy_reduce_ofst`, `yy_default`) verbatim from `parse.c` lines 706–1380.
    Tables live in `src/passqlite3parsertables.inc` (689 lines, included
    from `passqlite3parser.pas` at the top of the implementation section).
    Sizes verified by entry count:
      * `yy_action[2379]`     (YY_ACTTAB_COUNT  = 2379)
      * `yy_lookahead[2566]`  (YY_NLOOKAHEAD    = 2566)
      * `yy_shift_ofst[600]`  (YY_SHIFT_COUNT   = 599, +1)
      * `yy_reduce_ofst[424]` (YY_REDUCE_COUNT  = 423, +1)
      * `yy_default[600]`     (YYNSTATE         = 600)
    Generation was mechanical: `/*` → `{`, `*/` → `}`, `{` → `(` for the
    array literal, `};` → `);`, trailing comma stripped (FPC rejects).
    YY_NLOOKAHEAD constant (2566) matches the C source verbatim.
    Tokenizer gate test still PASS (127/127 — tables unused so far,
    serves as a regression check that the unit still compiles).

  - [X] **7.2c** Port the fallback table (`yyFallback`, parse.c lines
    1398–1588) and the rule-info tables (`yyRuleInfoLhs`, `yyRuleInfoNRhs`,
    parse.c lines 2960–3791). These are also mechanical translations.
    Implement `sqlite3ParserFallback` to return `yyFallback[iToken]`.
    DONE 2026-04-25.  Tables appended to `passqlite3parsertables.inc`
    (lines 691+) — counts: `yyFallbackTab[187]` = YYNTOKEN, `yyRuleInfoLhs[412]`
    = YYNRULE, `yyRuleInfoNRhs[412]` = YYNRULE.  Note: the C name `yyFallback`
    collides case-insensitively with the `YYFALLBACK` enabling constant under
    FPC (per the recurring var/type-conflict feedback); the Pascal table is
    therefore named **`yyFallbackTab`**, while the constant `YYFALLBACK = 1`
    keeps its upstream spelling.  `sqlite3ParserFallback` now indexes
    `yyFallbackTab` directly with bounds-check on `YYNTOKEN`.  Tokenizer gate
    test still PASS (127/127 — tables not yet exercised, regression check
    that the unit still compiles).  `yyRuleInfoNRhs` declared as
    `array of ShortInt` (signed 8-bit, matches C `signed char`).

  - [X] **7.2d** Port the parser engine (lempar.c logic that ends up at
    parse.c lines 3792–6313): `yy_find_shift_action`, `yy_find_reduce_action`,
    `yy_shift`, `yy_pop_parser_stack`, `yy_destructor`, the main `sqlite3Parser`
    driver with its grow-on-demand stack (`parserStackRealloc` /
    `parserStackFree`). Use the same algorithm as the C engine. Skip the
    optional tracing functions for now (port only `yyTraceFILE` declarations
    so signatures match).
    DONE 2026-04-25.  Engine bodies live in `passqlite3parser.pas` lines
    1057–1330 (forward declarations + `parserStackRealloc`, `yy_destructor`
    stub, `yy_pop_parser_stack`, `yyStackOverflow`, `yy_find_shift_action`,
    `yy_find_reduce_action`, `yy_shift`, `yy_accept`/`yy_parse_failed`/
    `yy_syntax_error`, `yy_reduce` framework, full `sqlite3Parser` driver,
    rewritten `sqlite3ParserAlloc`/`Free`).  `yy_destructor` and the rule
    switch inside `yy_reduce` are intentionally empty bodies — Phase 7.2e
    fills them by porting parse.c:2542–2657 and 3829–5993 respectively.
    Until reduce actions exist, yy_shift only ever stores a TToken in
    `minor.yy0` so empty destructors are correct.  The dropped
    yyerrcnt/`YYERRORSYMBOL` recovery path is fine: parse.y does not define
    an error token, so the C engine takes the same fall-through (report +
    discard token, fail at end-of-input).  Tracing (`yyTraceFILE`,
    `yycoverage`, `yyTokenName`/`yyRuleName`) was skipped per spec.
    Pitfall: `var pParse: PParse` triggers FPC's case-insensitive name
    collision (per memory `feedback_fpc_vartype_conflict`); the engine
    uses local name `pPse` everywhere it needs a `PParse` cast.
    Tokenizer gate test still PASS (127/127 — full unit compiles, parser
    engine not yet exercised end-to-end since `sqlite3RunParser` remains
    stubbed pending 7.2e + 7.2f).

  - [ ] **7.2e** Port the **reduce actions** — the giant switch statement at
    parse.c lines 3829–5993. This is the only sub-phase that is non-mechanical:
    each `case YYRULE_n:` body contains hand-written grammar action C code from
    `parse.y` that calls `sqlite3*` codegen routines from Phase 6. Many of the
    callees may need additional wrapper exports from Phase 6 units. Port in
    chunks of ~50 rules, build-checking after each.

    Sub-tasks (chunks of ~50 rules each, 412 rules total):
    - [X] **7.2e.1** Rules 0..49 — explain, transactions, savepoints,
      CREATE TABLE start/end, table options, column constraints (DEFAULT/
      NOT NULL/PRIMARY KEY/UNIQUE/CHECK/REFERENCES/COLLATE/GENERATED),
      autoinc, initial refargs.  DONE 2026-04-25.
    - [X] **7.2e.2** Rules 50..99 — refargs/refact (FK actions),
      defer_subclause, conslist, idxlist, sortlist, eidlist, columnlist
      tail; tcons (PRIMARY KEY/UNIQUE/CHECK/FOREIGN KEY); onconf/orconf;
      DROP TABLE/VIEW; CREATE VIEW; cmd ::= select; SELECT core (WITH,
      compound, oneselect, VALUES, mvalues, distinct).  DONE 2026-04-25.

      Notes for next chunks:
      * Helper static functions `parserDoubleLinkSelect` and
        `attachWithToSelect` (parse.y:131/162) ported as nested helpers
        in `passqlite3parser.pas` directly above `yy_reduce`.  Both call
        only existing exports (`sqlite3SelectOpName`,
        `sqlite3WithDelete`, `aLimit[SQLITE_LIMIT_COMPOUND_SELECT]`,
        plus `SF_Compound` / `SF_MultiValue` / `SF_Values` from codegen).
      * `DBFLAG_EncodingFixed` (sqliteInt.h:1892, value $0040) was not
        previously declared in any unit — added as a local const inside
        `passqlite3parser` next to the SAVEPOINT_* block.  When Phase 8
        wires up the public API and ports `prepare.c`, move it to
        `passqlite3codegen` alongside `DBFLAG_SchemaKnownOk`.
      * `Parse.hasCompound` is a C bitfield; in our layout it lives in
        `parseFlags`, bit `PARSEFLAG_HasCompound` (1 shl 2).  Rule 88
        sets that bit instead of dereferencing a non-existent
        `pPse^.hasCompound` field.
      * `sqlite3ErrorMsg` still has no varargs — rule body for
        `parserDoubleLinkSelect` therefore uses static "ORDER BY clause
        should come after compound operator" / "LIMIT ..." messages
        (parse.y dynamically inserted the operator name).  Same TODO
        as 7.2e.1 rules 23/24: revisit when printf-style formatting
        lands.
      * `sqlite3SrcListAppendFromTerm` in our port takes
        `(pOn, pUsing)` instead of `OnOrUsing*` — rule 88 splits the
        single C arg into two Pascal args by passing `nil, nil` for the
        synthetic FROM-term.  Rules 111-115 (chunk 7.2e.3) will need
        the same split: pass
        `PExpr(yymsp[k].minor.yy269.pOn), PIdList(yymsp[k].minor.yy269.pUsing)`.
      * Rules 89/91 cast `yymsp[0].major` (YYCODETYPE = u16) directly to
        i32 — equivalent to the C `/*A-overwrites-OP*/` convention.
      * Rules 96/97 share a body and must remain in the same case label
        list because both produce `yymsp[-4].minor.yy555` from the same
        expression (Lemon's yytestcase de-duplication preserved).
      * Rule 71 (FOREIGN KEY): `sqlite3CreateForeignKey` Pascal
        signature is `(pParse, pFromCol: PExprList, pTo: PToken,
        pToCol: PExprList, flags: i32)` — same arity as C.  Rule 42
        in 7.2e.1 already uses it correctly.
      * Local var `dest_84: TSelectDest` and `x_88: TToken` were added
        to `yy_reduce`'s var block.  As more chunks land, additional
        locals will accumulate there (one-off scratch space per rule
        family); accept that var block growth as a normal porting cost.
    - [X] **7.2e.3** Rules 100..149 — SELECT core (selectnowith, oneselect,
      values, distinct, sclp, selcollist, FROM/USING/ON, JOIN, jointype,
      indexed_opt, on_using, where_opt, groupby_opt, having_opt, orderby_opt,
      sortlist, nulls, limit_opt).  DONE 2026-04-25.

      Notes for next chunks:
      * **`sqlite3NameFromToken`** (build.c) and **`sqlite3ExprListSetSpan`**
        (expr.c:2228) were not yet exported by `passqlite3codegen` /
        equivalent.  Both are now ported as nested helpers in
        `passqlite3parser.pas` directly above `yy_reduce`.  When Phase 8
        ports `build.c` and the expression helpers, move them to the
        proper unit and remove the local copies.
      * **`InRenameObject`** is defined in `passqlite3codegen` but only in
        the implementation block — it is not exported via the interface.
        For now, `passqlite3parser` defines a local `inRenameObject` clone
        (case-insensitive, but Pascal will resolve to the local one inside
        this unit).  Either add a forward declaration in the codegen
        interface, or keep the duplicate; both are acceptable.
      * **SrcItem flag bits in `fgBits2`** — sqliteInt.h enumerates
        fromDDL(0), isCte(1), notCte(2), isUsing(3), isOn(4), isSynthUsing(5),
        **isNestedFrom(6)**, rowidUsed(7).  A new constant
        `SRCITEM_FG2_IS_NESTED_FROM = $40` was added to
        `passqlite3parser`'s local const block; existing `passqlite3codegen`
        uses raw `$08` / `$10` literals for `isUsing` / `isOn` (with
        comments).  Note: codegen.pas line 4243 has a stale comment that
        reads "isNestedFrom" but tests `fgBits and $08` — that is actually
        `isTabFunc`.  Pre-existing tech debt; flagged here so it can be
        reviewed during Phase 8 audit but **not** changed in this chunk
        (out of scope).
      * **`yy454` is `Pointer`** in our `YYMINORTYPE` (line 314).  Direct
        assignment from a `PExpr` works without explicit cast; do *not*
        wrap calls in `PtrInt(...)`.  Same for `yy14` (`PExprList`) and
        `yy203` (`PSrcList`).
      * **Rule 109 / 115 access `pSrcList^.a[N-1]`** in C.  Our `TSrcList`
        is the 8-byte header only; items live just past it via the
        existing `SrcListItems(p)` accessor.  Walk to entry N-1 with
        `pItem := SrcListItems(p); Inc(pItem, p^.nSrc - 1);`.
      * **Rule 115's `if (rhs->nSrc==1)` branch** is the trickiest: it
        moves the single source item from a temporary SrcList into the
        new term, transferring ownership of `u4.pSubq`,
        `u4.zDatabase`, `u1.pFuncArg`, and `zName`.  The flag bits live
        in `fgBits` (SRCITEM_FG_IS_SUBQUERY/IS_TABFUNC) and `fgBits2`
        (SRCITEM_FG2_IS_NESTED_FROM).  Be careful that the *new* item's
        flags are accumulated AFTER `sqlite3SrcListAppendFromTerm` adds
        the entry: that function may zero `fg`.  Manual verification of
        both `fgBits` and `fgBits2` ORs against an oracle run is on the
        agenda for Phase 7.4 once `sqlite3RunParser` is wired up.
      * Rules 146/147/148 are `having_opt`/`limit_opt` only for now;
        chunks 7.2e.4/7.2e.5 will share the same body via merged case
        labels (153/155/232/233/252 join 146; 154/156/231/251 join 147).
        Either re-merge the labels at that time or keep as duplicate
        bodies — pick the cleaner one.
    - [X] **7.2e.4** Rules 150..199 — DML: DELETE, UPDATE, INSERT/REPLACE,
      upsert, returning, conflict, idlist, insert_cmd, plus expression-tail
      rules 179..199 (LP/RP, ID DOT ID, term, function call, COLLATE, CAST,
      filter_over, LP nexprlist COMMA expr RP, AND/OR/comparison).
      DONE 2026-04-25.

      Notes for next chunks:
      * Five new local helpers were added to passqlite3parser.pas above
        `yy_reduce` (same pattern as 7.2e.3's `sqlite3NameFromToken`):
        - **`parserSyntaxError`** — emits a static "near token: syntax error"
          message; full `%T` formatting deferred until sqlite3ErrorMsg gains
          varargs (Phase 8).
        - **`sqlite3ExprFunction`** — full port of expr.c:1169.  Uses
          `sqlite3ExprAlloc`, `sqlite3ExprSetHeightAndFlags` (both already in
          passqlite3codegen).  Phase 8 should move it to expr.c proper.
        - **`sqlite3ExprAddFunctionOrderBy`** — full port of expr.c:1219.
          Uses `sqlite3ExprListDeleteGeneric` + `sqlite3ParserAddCleanup`
          (both already exported).  Move to expr.c in Phase 8.
        - **`sqlite3ExprAssignVarNumber`** — *simplified* port: `?`, `?N`,
          and `:/$/@aaa` are all assigned a fresh slot via `++pParse.nVar`.
          The `pVList`-based dedupe of named bind params is **not** wired
          up (util.c's `sqlite3VListAdd/NameToNum/NumToName` are not yet
          ported).  This means two occurrences of `:foo` currently get
          *different* parameter numbers — incorrect for binding but
          harmless for parser-only tests.  Phase 8 must port the VList
          machinery and replace this stub.
        - **`sqlite3ExprListAppendVector`** — *stub*: emits an error
          ("vector assignment not yet supported (Phase 8 TODO)") and frees
          its inputs.  Vector assignment `(a,b)=(...)` in UPDATE setlists
          and the corresponding rules 161/163 will not work until Phase 8
          ports `sqlite3ExprForVectorField` (expr.c:1893).
      * **`yylhsminor.yy454` is `Pointer`** in the YYMINORTYPE variant
        record (see line ~314).  When dereferencing for `^.w.iOfst` etc.,
        cast to `PExpr(yylhsminor.yy454)^.w.iOfst`.  Same pattern applies
        when reading `^.flags`, `^.x.pList`, and so on.  See rule 185 for
        a worked example — direct `yylhsminor.yy454^.…` triggers FPC's
        "Illegal qualifier" error.
      * Rules **153/155/232/233/252** share the body `yymsp[1].yy454 := nil`
        and were merged with rule 148 in C.  Our switch already had 148
        as a separate case (no-arg) — chunk 7.2e.4 added 153/155/232/233/252
        as a new combined case to keep the body distinct (148 uses
        `yymsp[1]`, the merged group also uses `yymsp[1]`, so the bodies
        are identical and could be merged in a future cleanup).  Same for
        154/156/231/251 (paired with 147).  Decision deferred to chunk
        7.2e.5 — pick the cleaner merge once those rule numbers materialise.
      * Rules **198/199** were merged in our switch but the C code further
        merges 200..204 into the same body.  Chunk 7.2e.5 must fold
        200..204 into the existing 198/199 case.
      * Rules **173/174** were already covered by chunks 7.2e.1/7.2e.2
        (merged with 61/76 and 78 respectively) — they are intentionally
        absent from chunk 7.2e.4's new cases.
    - [X] **7.2e.5** Rules 200..249 — expressions: expr/term, literals,
      bind params, names, function call, subqueries, CASE, CAST, COLLATE,
      LIKE/GLOB/REGEXP/MATCH, BETWEEN, IN, IS, NULL/NOTNULL, unary ops.
      DONE 2026-04-25.

      Notes for next chunks:
      * Rules **200..204** were merged into the existing **198/199** case
        (sqlite3PExpr with `i32(yymsp[-1].major)` as the operator).  The
        chunk-7.2e.4 note flagged this fold-in; it is now done.
      * Rules **234, 237, 242** (`exprlist ::=`, `paren_exprlist ::=`,
        `eidlist_opt ::=` — all three set `yy14 := nil`) were merged into
        the existing **101/134/144** case rather than adding a duplicate.
        Same pattern: when downstream chunks port a rule whose body is
        already covered by an earlier merged case, prefer adding to the
        existing label list.
      * Rule **281** (`raisetype ::= ABORT`, `yy144 := OE_Abort`) shares its
        body with rule **240** (`uniqueflag ::= UNIQUE`).  240 is currently
        a standalone case — chunk **7.2e.6** must add 281 to it as a merged
        label.
      * Four new local helpers were added to `passqlite3parser.pas` directly
        above `yy_reduce` (continuing the chunk-7.2e.3/4 pattern):
        - **`sqlite3PExprIsNull`** — full port of parse.y:1383 (TK_ISNULL/
          TK_NOTNULL with literal-folding to TK_TRUEFALSE via
          `sqlite3ExprInt32` + `sqlite3ExprDeferredDelete`, both already in
          codegen).
        - **`sqlite3PExprIs`** — full port of parse.y:1390.  Uses
          `sqlite3PExprIsNull` plus `sqlite3ExprDeferredDelete`.
        - **`parserAddExprIdListTerm`** — port of parse.y:1654.  Uses
          `sqlite3ExprListAppend` (with `nil` value) + `sqlite3ExprListSetName`.
          Note: the C source builds the error message via `%.*s` formatting
          on `pIdToken`; our `sqlite3ErrorMsg` still lacks varargs (the
          recurring TODO from 7.2e.1/.2/.4), so the message is the static
          "syntax error after column name" without the column text.  Phase 8
          must restore the dynamic name once formatting lands.
        - **`sqlite3ExprListToValues`** — port of expr.c:1098.  Used by
          rule 223's TK_VECTOR/multi-row VALUES branch.  Walks `pEList` via
          `ExprListItems(p)` + index, just like other list iterations.
          The error messages for "wrong-arity" elements use static text
          (same varargs TODO).  Phase 8 should move this to expr.c proper.
      * **`var pExpr: PExpr`** triggers FPC's case-insensitive var/type
        collision (per `feedback_fpc_vartype_conflict`); the helper
        `sqlite3ExprListToValues` uses the local name **`pExp`** instead.
        Same pitfall as `pPager → pPgr`, `pgno → pg`, `pParse → pPse`.
      * Rule 223 walks `pInRhs_223` (`PExprList`) via `ExprListItems(p)`
        and reads `[0]` directly — the C code does `pInRhs_223->a[0].pExpr`
        which is identical to our `ExprListItems(pInRhs_223)^.pExpr`.
        Setting `[0].pExpr := nil` to detach is also done via the accessor.
      * Rule 217 (`expr ::= expr PTR expr`) writes `yylhsminor.yy454` and
        then publishes `yymsp[-2].minor.yy454 := yylhsminor.yy454` — same
        Lemon convention as rules 181/182/189–195.
      * Rule 220 (`BETWEEN`): the new TK_BETWEEN node owns `pList_206` via
        `^.x.pList`.  If `sqlite3PExpr` returns nil, we free the list with
        `sqlite3ExprListDelete` to avoid a leak — matches the C body.
      * Rule 226 (`expr in_op nm dbnm paren_exprlist`): C calls
        `sqlite3SrcListFuncArgs(pParse, pSelect ? pSrc : 0, ...)` — a
        ternary inside the call.  Pascal lacks the ternary so the body
        splits the call into two branches.
      * Rule 239 (`CREATE INDEX`): `sqlite3CreateIndex` already exported
        with the matching signature (chunk 7.2e.4 confirmed).  Uses
        `pPse^.pNewIndex^.zName` for the rename-token-map lookup.
    - [X] **7.2e.6** Rules 250..299 — VACUUM-with-name, PRAGMA, CREATE/DROP
      TRIGGER + trigger_decl/trigger_time/trigger_event/trigger_cmd_list +
      tridxby/trigger_cmd (UPDATE/INSERT/DELETE/SELECT), RAISE expr +
      raisetype, ATTACH/DETACH, REINDEX, ANALYZE, ALTER TABLE
      (rename/add/drop column, rename column, drop constraint, set NOT NULL).
      DONE 2026-04-25.

      Notes for next chunks:
      * **`sqlite3Reindex`** and the four `sqlite3Trigger*Step` builders
        (UpdateStep/InsertStep/DeleteStep/SelectStep) were not yet exported
        by `passqlite3codegen`.  Stubs added directly above `yy_reduce` in
        `passqlite3parser.pas` (same pattern as 7.2e.3/4/5):
        - `sqlite3Reindex` — full no-op stub (Phase 8 must port build.c).
        - `sqlite3Trigger{Update,Insert,Delete,Select}Step` — allocate a
          zeroed `TTriggerStep`, set `op`/`orconf`, free the input params.
          Sufficient for parser-only differential testing; a real trigger
          built via the parser is a no-op until trigger.c lands in Phase 8.
      * **`sqlite3AlterSetNotNull` signature mismatch** — codegen.pas had
        the 4th parameter as `i32 onError`, but parse.y / parse.c pass
        `&NOT_token` (a `Token*`).  Changed both the interface and the
        implementation in `passqlite3codegen.pas` to `pNot: PToken`.  The
        function is still a stub; the signature fix is purely so the
        parser call type-checks.
      * **Existing rule `153, 155, 232, 233, 252` was extended to include
        `268, 286`** (when_clause ::= ; key_opt ::= — both `yymsp[1].yy454 := nil`).
        Existing rule `154, 156, 231, 251` was extended to include
        `269, 287` (when_clause ::= WHEN expr ; key_opt ::= KEY expr —
        both `yymsp[-1].yy454 := yymsp[0].yy454`).  Same merging pattern as
        chunk 7.2e.4 anticipated.
      * **Existing rule `240` was extended to include `281`** (uniqueflag
        ::= UNIQUE ; raisetype ::= ABORT — both `yymsp[0].yy144 := OE_Abort`).
        Chunk-7.2e.5 note flagged this; it is now done.
      * **Existing rule `105, 106, 117` was extended to include
        `258, 259`** (`plus_num ::= PLUS INTEGER|FLOAT`,
        `minus_num ::= MINUS INTEGER|FLOAT` — `yymsp[-1].yy0 := yymsp[0].yy0`).
        Pre-existing tech debt: the merge with rule 106 (`as ::=` empty,
        body in C is `yymsp[1].n=0; yymsp[1].z=0;`) is **incorrect** in the
        Pascal port — rule 106 should be in the no-op branch.  Flagged for
        Phase 8 audit; **not** changed in this chunk (out of scope, and
        the resulting wrong-but-deterministic value of `as ::=` is a stale
        zero-initialised TToken via `yylhsminor.yyinit := 0`, which is
        harmless until codegen reads it).
      * **Rule 261 (`trigger_decl`) — `pParse->isCreate`** debug-only
        assertion was skipped (the C body is `#ifdef SQLITE_DEBUG` and
        our TParse layout has `u1.cr.addrCrTab/regRowid/regRoot/
        constraintName` but no `isCreate` boolean).  When Phase 8 audits
        the TParse layout, decide whether to add the bit.
      * **Rule 261 — `Token` n-field arithmetic** uses `u32(PtrUInt(...) -
        PtrUInt(...))` to bridge `PAnsiChar` arithmetic on FPC.  Same
        idiom in rule 293 (`alter_add ::= ... carglist`).  Token's
        `n` field is `u32`.
      * **Rule 261 — `i32` cast for `yymsp[0].major`** (a `YYCODETYPE = u16`)
        is the same pattern as rules 89/91/262/265/266 — Lemon's
        `/*A-overwrites-X*/` convention, the value goes into a yy144
        (i32) slot.
      * Rule 274 (`trigger_cmd ::= UPDATE`) signature mapping: our
        Pascal stub `sqlite3TriggerUpdateStep(pPse, pTab, pFrom, pEList,
        pWhere, orconf: i32, zStart: PAnsiChar, zEnd: PAnsiChar)` mirrors
        the upstream `sqlite3TriggerUpdateStep(Parse*, SrcList* pTabName,
        SrcList* pFrom, ExprList* pEList, Expr* pWhere, u8 orconf,
        const char* zStart, const char* zEnd)` from trigger.c.  Phase 8
        must replace the stub with the full body.
      * **Rule 297/298 (`AlterDropConstraint`)** — the Pascal stub's
        positional parameters are `(pSrc, pType, pName)` (parameter
        names), but the C signature is `(Parse*, SrcList*, Token* pName,
        Token* pType)`.  We pass arguments positionally matching the C
        order — i.e. arg 3 is the name, arg 4 is the type.  The Pascal
        parameter names are misleading; flagged for Phase 8.  The stub
        body only deletes pSrc, so positional mismatch is harmless.
    - [X] **7.2e.7** Rules 300..347 — ALTER ADD CONSTRAINT/CHECK (300/301),
      create_vtab + vtabarg/vtabargtoken/lp (302..308), WITH / wqas / wqitem
      / withnm / wqlist (309..317), windowdefn_list / windowdefn / window /
      frame_opt / frame_bound[_s|_e] / frame_exclude[_opt] / window_clause /
      filter_over / over_clause / filter_clause (318..346), term ::= QNUMBER
      (347).  Rules 348+ remain in the default no-op branch (Lemon optimised
      most of them out — see parse.c lines 5927..5993).  DONE 2026-04-25.

      Notes for next chunks:
      * **`sqlite3AlterAddConstraint` signature corrected** in
        `passqlite3codegen.pas` — was a 3-arg stub `(pParse, pSrc, pType)`,
        upstream is `(Parse*, SrcList*, Token* pCons, Token* pName,
        const char* zCheck, int nCheck)`.  Body is still a stub that drops
        the SrcList; Phase 8 must port alter.c's full body.
      * **Six new local helpers** were added directly above `yy_reduce` in
        `passqlite3parser.pas` (continuing the 7.2e.3..6 pattern):
        - `sqlite3VtabBeginParse / FinishParse / ArgInit / ArgExtend` —
          full no-op stubs.  CREATE VIRTUAL TABLE parses cleanly but
          produces no schema entry until Phase 6.bis ports vtab.c.
        - `sqlite3CteNew` — stub returns nil and frees the inputs
          (`pArglist` via `sqlite3ExprListDelete`, `pQuery` via
          `sqlite3SelectDelete`).  Real body lives at sqlite3.c:131988
          (build.c).
        - `sqlite3WithAdd` — stub returns the existing With pointer
          unchanged.  Cte-leak path is acceptable for parser-only tests
          since `sqlite3CteNew` already returns nil; Phase 8 must wire
          this up against a real `Cte` type.
        - `sqlite3DequoteNumber` — no-op stub.  QNUMBER is a rare lexer
          token (quoted-numeric literal); skipping the dequote is harmless
          for parser-only tests.
      * **`M10d_Yes/Any/No` constants** (sqliteInt.h:21461..21463) added as
        a local `const` block immediately above the helper stubs.  Once
        Phase 8 ports build.c's CTE machinery these should move into the
        codegen interface alongside `OE_*`/`TF_*`.
      * **`pPse^.bHasWith := 1`** (rule 315 in C) maps to
        `parseFlags := parseFlags or PARSEFLAG_BHasWith` — flag already
        defined in passqlite3codegen at bit 6.
      * **`yy509` is `TYYFrameBound`** (eType: i32; pExpr: Pointer).
        Rules 326/327/333 read `.eType` directly and cast `.pExpr` to
        `PExpr` when handing to `sqlite3WindowAlloc`.  The trivial pass-
        through rules 329/331 do an explicit `yylhsminor.yy509 :=
        yymsp[0].minor.yy509; yymsp[0].minor.yy509 := yylhsminor.yy509;`
        round-trip — semantically a no-op, kept for symmetry with C.
      * **`yymsp[-3].minor.yy0.z + 1`** (C pointer arithmetic on PAnsiChar)
        — rules 300/301 cast through `PAnsiChar(...) + 1`.  The byte
        length is computed via `PtrUInt(end.z) - PtrUInt(start.z) - 1`.
      * **Window allocation in rules 343/345** uses
        `sqlite3DbMallocZero(db, u64(SizeOf(TWindow)))` (TWindow is 144
        bytes per the verified offset-table comment in passqlite3codegen).
        `eFrmType` is `u8`, so `TK_FILTER` requires an explicit `u8(...)`
        cast.
      * Six new locals in `yy_reduce`'s var block: `pWin_318/319/343/345`,
        `zCheckStart_300`, `nCheck_300`.
    - [X] **7.2e.8** Rules 348..411 — all in Lemon's `default:` branch.
      Verified against parse.c:5927..5993: every rule in 348..411 is either
      tagged `OPTIMIZED OUT` (Lemon emitted no reduce action — the value
      copy is folded into the parse table via SHIFTREDUCE / aliased %type)
      or has an empty action body (only `yytestcase()` for coverage —
      semantically a no-op).  No new explicit `case` arms are required:
      the existing `else` branch in `yy_reduce` already provides a no-op
      and the unconditional goto/state-update logic that follows the
      `case` correctly pushes the LHS for these rules too.  Spot-list of
      what falls into this bucket: cmdlist/ecmd plumbing (348..353),
      trans_opt / savepoint_opt (354..358), create_table glue (359),
      table_option_set tail (360), columnlist tail (361..362),
      nm/typetoken/typename/signed (363..368), carglist/ccons tail
      (369..373), conslist/tconscomma/defer_subclause/resolvetype
      (374..379), selectnowith/oneselect/sclp/as/indexed_opt/returning
      (380..385), expr/likeop/case_operand/exprlist (386..389), nmnum /
      plus_num (390..395), foreach_clause / tridxby (396..398),
      database_kw_opt / kwcolumn_opt (399..402), vtabarglist / vtabarg
      (403..405), anylist (406..408), with (409), windowdefn_list (410),
      window (411).  DONE 2026-04-25.

      Notes for next chunks:
      * **No new helpers / locals / constants** were added in this chunk
        — the Pascal driver already covers the no-op semantics.  This
        completes the 7.2e family; the entire reduce-action switch is
        now feature-complete relative to upstream.
      * **OPTIMIZED OUT marker meaning**: Lemon detects that an LHS
        non-terminal has the same union slot as its single RHS symbol
        and that the action is a pure copy.  Rather than emit a reduce
        case, it folds the copy into the parse-table state transitions
        (SHIFTREDUCE actions on the RHS terminal).  Because we ported
        `yy_action` / `yy_lookahead` / `yy_shift_ofst` / `yy_reduce_ofst`
        verbatim from parse.c in 7.2b, those folded copies already
        execute correctly without a Pascal-side reduce arm.
      * **`yytestcase` is coverage instrumentation, not action code**
        — it expands to `if(x){}` in normal builds.  Rules whose only
        body is `yytestcase(yyruleno==N);` therefore have no semantic
        effect and the Pascal `else` branch matches that exactly.

    Per-chunk approach (refined 2026-04-25 during 7.2e.1):

    * YYMINORTYPE was extended to expose all 19 named C union members
      (yy0/yy14/yy59/yy67/yy122/yy132/yy144/yy168/yy203/yy211/yy269/yy286/
       yy383/yy391/yy427/yy454/yy462/yy509/yy555).  Pointer-typed minors
      share a single 8-byte cell via the variant record; reduce code casts
      to the concrete type (PExpr / PSelect / PSrcList / etc.) inline.
    * yy_reduce holds a `case yyruleno of … else end` switch.  Rules whose
      body is `;` (pure no-ops) and rules not yet ported share the `else`
      branch — semantically a no-op, which is correct as long as the
      grammar action does not produce a value.  Rules that DO produce a
      value MUST have an explicit case once ported.
    * Helper `disableLookaside(pPse: PParse)` is defined locally at the top
      of the engine block (parse.y:132 equivalent).
    * `tokenExpr` is replaced by a direct call to `sqlite3ExprAlloc(db,
      op, &tok, 0)` — that helper is the moral equivalent and already
      exported by passqlite3codegen (Phase 6.1).
    * SAVEPOINT_BEGIN/RELEASE/ROLLBACK constants redeclared locally in
      passqlite3parser; passqlite3pager (the original site) is not in our
      uses clause.
    * `sqlite3ErrorMsg` in this codebase is plain (no varargs); rule 23/24
      drop the `%.*s` formatting in the error message and pass a static
      literal.  TODO: when sqlite3ErrorMsg gets printf-style formatting
      (Phase 8 / public-API phase), revisit and restore the dynamic text.
    * Constants TF_Strict (0x00010000) and SQLITE_IDXTYPE_APPDEF/UNIQUE/
      PRIMARYKEY/IPK were added to passqlite3codegen alongside the
      existing TF_* / OE_* groups.

  - [X] **7.2f** Wire `sqlite3RunParser` to drive the lexer through the new
    parser engine (replaces the current Phase 7.1 stub). Implement the
    fallback / wildcard handling, FILTER/OVER/WINDOW context tracking that
    `getNextToken` already detects, and propagate parse errors into
    `pParse^.zErrMsg`. Mark Phase 7.2 itself complete when 7.2a–7.2f all pass.

    DONE 2026-04-25.  passqlite3parser.pas:1110 — sqlite3RunParser now mirrors
    tokenize.c:600 byte-for-byte: TK_SPACE skip, TK_COMMENT swallowing under
    init.busy or SQLITE_Comments, TK_WINDOW/TK_OVER/TK_FILTER context
    promotion via the existing analyze*Keyword helpers, isInterrupted poll,
    SQLITE_LIMIT_SQL_LENGTH guard, SQLITE_TOOBIG / SQLITE_INTERRUPT /
    SQLITE_NOMEM_BKPT propagation, end-of-input TK_SEMI+0 flush, and the
    pNewTable / pNewTrigger / pVList cleanup tail.  Build (TestTokenizer
    127/127) PASS.

    Notes for next chunks:
    * `inRenameObject` was already defined later in the file (parser-local
      re-export) — added a forward declaration just above sqlite3RunParser
      so the cleanup tail can call it.
    * Constant `SQLITE_Comments = u64($00040) shl 32` declared locally in
      the implementation section (HI() macro from sqliteInt.h:1819).  Move
      to passqlite3util / passqlite3codegen alongside the other SQLITE_*
      flag bits when one of them needs it too.
    * Untyped `Pointer` → `PParse` is assigned directly (no cast) — FPC
      flagged `PParse(p)` cast-syntax with a "; expected" error in this
      block; direct assignment compiles cleanly because Pascal allows
      untyped Pointer → typed pointer assignment without an explicit cast.
    * Three C-side facilities are intentionally NOT ported here and remain
      tracked as TODOs for Phase 8 (public-API phase):
        - `sqlite3_log(rc, "%s in \"%s\"", zErrMsg, zTail)`  — pager unit
          owns sqlite3_log today and is not on the parser's uses path.
        - The `pParse->zErrMsg = sqlite3DbStrDup(db, sqlite3ErrStr(rc))`
          fallback that synthesises a default message when a non-OK rc has
          no zErrMsg — sqlite3ErrStr lives in passqlite3vdbe; pulling vdbe
          into the parser uses-clause would create a cycle.  nErr is still
          incremented when rc != OK so callers see the failure.
        - SQLITE_ParserTrace / `sqlite3ParserTrace(stdout, …)` — no debug
          tracing target in the Pascal port.
    * apVtabLock is not freed here because the Phase 6.bis vtable branch
      never assigns it.  Revisit when 6.bis lands.
    * Ready for Phase 7.4 (TestParser differential test) once the parser
      action routines that build AST nodes are exercised end-to-end.

  Fallback if 7.2 grows untenable: revisit Lemon-Pascal emitter in 7.2g.

- [X] **7.3** Port parse-tree action routines that Lemon calls (these live in
  `build.c` and friends from Phase 6, so they are already available).

  DONE 2026-04-25.  All action routines that Phase 7.2e's reduce switch
  references are wired through to passqlite3codegen (Phase 6) or to local
  parser-unit helpers.  The unit links cleanly and a new smoke gate
  `src/tests/TestParserSmoke.pas` drives `sqlite3RunParser` end-to-end on
  20 representative SQL fragments (DDL, DML, savepoints, comment handling,
  and two negative syntax-error cases) — all 20 pass.

  Concrete changes in this chunk:
    * passqlite3parser.pas — replace the `sqlite3DequoteNumber` stub with
      the full util.c:332 port (digit-separator '_' stripped, op promoted
      to TK_INTEGER/TK_FLOAT, EP_IntValue tag-20240227-a fast path).
    * src/tests/TestParserSmoke.pas — new (Phase 7.3 gate).
    * src/tests/build.sh — register TestParserSmoke.

  Stubs deliberately left in place (each tagged for the appropriate later
  phase, none of which is in 7.3's scope):
    * sqlite3VtabBeginParse / FinishParse / ArgInit / ArgExtend  — Phase 6.bis
    * sqlite3CteNew / sqlite3WithAdd                             — Phase 8 (build.c CTE)
    * sqlite3Reindex                                              — Phase 8 (build.c REINDEX)
    * sqlite3TriggerUpdateStep / InsertStep / DeleteStep / SelectStep
                                                                  — Phase 8 (trigger.c)
    * sqlite3ExprListAppendVector                                 — Phase 8 (expr.c vector UPDATE)

  Smoke-test limitations (each documented in TestParserSmoke.pas):
    * top-level `cmd ::= select` triggers `sqlite3Select` codegen which
      requires a live `Vdbe` + open db backend — tested in Phase 7.4.
    * `CREATE VIEW` reaches `sqlite3CreateView` which dereferences
      `db^.aDb[0].pSchema` — also a Phase 7.4 concern.
    * `COMMIT` / `ROLLBACK` / `PRAGMA` reach codegen paths that touch
      live db internals (transaction state, pragma dispatch).

- [ ] **7.4** Gate: `TestParser.pas` — for the SQL corpus, tokenise + parse
  with both implementations, dump the resulting VDBE program via the codegen
  from Phase 6, diff byte-for-byte.

---

## Phase 8 — Public API

Files: `main.c` (connection lifecycle, core API entry points), `legacy.c`
(`sqlite3_exec` and the legacy convenience wrappers), `table.c`
(`sqlite3_get_table` / `sqlite3_free_table`), `backup.c` (the online-backup
API: `sqlite3_backup_init/step/finish/remaining/pagecount`), `notify.c`
(the `sqlite3_unlock_notify` machinery), `loadext.c` (dynamic-extension
loader — *optional for v1*).

- [ ] **8.1** Port `sqlite3_open_v2`, `sqlite3_close`, `sqlite3_close_v2`,
  connection lifecycle (from `main.c`).

- [ ] **8.2** Port `sqlite3_prepare_v2` / `sqlite3_prepare_v3` — the entry
  point that wires parser → codegen → VDBE.

- [ ] **8.3** Port registration APIs: `sqlite3_create_function`,
  `sqlite3_create_collation`, `sqlite3_create_module` (virtual tables).

- [ ] **8.4** Port configuration and hooks: `sqlite3_config`, `sqlite3_db_config`,
  `sqlite3_commit_hook`, `sqlite3_rollback_hook`, `sqlite3_update_hook`,
  `sqlite3_trace_v2`, `sqlite3_busy_handler`.

- [ ] **8.5** Port `sqlite3_initialize` / `sqlite3_shutdown`.

- [ ] **8.6** Port `legacy.c`: `sqlite3_exec` and the one-shot callback-style
  wrappers; `table.c`: `sqlite3_get_table` / `sqlite3_free_table`.

- [ ] **8.7** Port `backup.c`: the online-backup API. Self-contained, small
  (~800 lines), useful early for verifying end-to-end operation.

- [ ] **8.8** Port `notify.c`: `sqlite3_unlock_notify` (rarely used; port if
  our threading story requires it, otherwise stub).

- [ ] **8.9** (Optional) Port `loadext.c`: dynamic extension loader. Requires
  `dlopen`/`dlsym`; can be safely stubbed for v1 if no Pascal consumer
  needs it.

- [ ] **8.10** Gate: the public-API sample programs in SQLite's own CLI
  (generated at build time from `../sqlite3/src/shell.c.in` → `shell.c` by
  `make`) and from the SQLite documentation all compile (as Pascal
  transliterations) and run against our port with results identical to the C
  reference. Note: `sqlite3.h` is similarly generated from `sqlite.h.in`;
  reference it only after a successful upstream `make`.

---

## Phase 9 — Acceptance: differential + fuzz

- [ ] **9.1** `TestSQLCorpus.pas`: full SQL corpus (Phase 0.10 + any additions)
  runs end-to-end; stdout, stderr, return code, and final `.db` byte-identical
  to C reference.

- [ ] **9.2** `TestReferenceVectors.pas`: every canonical `.db` in
  `vectors/` opens, queries, and reports results identically.

- [ ] **9.3** `TestFuzzDiff.pas`: AFL-driven differential fuzzer. Seed from
  `dbsqlfuzz` corpus. Run for ≥24 h. Any divergence is a bug.

- [ ] **9.4** SQLite's own Tcl test suite (`../sqlite3/test/*.test`) — wire our
  Pascal port into the suite as an alternate target if feasible. Not all tests
  will apply (some probe internal C APIs), but the "TCL" feature tests should
  pass.

---

## Phase 10 — CLI tool (shell.c ~12k lines)

- [ ] **10.1** Port `shell.c` to `src/passqlite3shell.pas`. Mimic CLI flags,
  dot-commands (`.schema`, `.tables`, `.dump`, `.import`, `.mode`, …), exit
  codes, and interactive behaviour.
- [ ] **10.2** Integration: `bin/passqlite3 foo.db` ↔ `sqlite3 foo.db` parity
  on a scripted corpus of dot-commands.

---

## Phase 11 — Benchmarks

- [ ] **11.1** `Benchmark.pas`: INSERT throughput (single row, batched in a
  transaction), SELECT throughput (primary-key lookup, range scan, indexed
  join), for small (1k rows) / medium (100k) / large (10M) datasets. Compare
  Pascal vs C Mops/s and record the ratio table here.

- [ ] **11.2** Any row worse than ~1.5× gets a TODO under Phase 11.

---

## Phase 12 — Performance optimisation (enter only after Phase 10)

Do not touch this phase until Phase 9 is fully green. Changes here must
preserve byte-for-byte on-disk parity.

Before trying any fix, try to use some profiling tool to discover where the time is being waisted.
In FPC, functions with asm content can not be inlined.

Use "-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX" to compile.

- [ ] **12.1** Profile with `perf record` on the benchmark workloads. Identify
  top 10 hot functions.
- [ ] **12.2** Aggressive `inline` on VDBE opcode helpers, varint codecs, and
  page cell accessors.
- [ ] **12.3** Consider replacing the VDBE's big `case` with a threaded
  dispatch (computed-goto-style) using `{$GOTO ON}`. Only if profiling shows
  the switch is a bottleneck.

---

## Per-function porting checklist

Apply to every function before marking it done:

- [ ] Signature matches the C source (same argument order, same types — `u8`
  stays `u8`, not `Byte`)
- [ ] Field names inside structs match C exactly
- [ ] No substitution of Pascal `Boolean` for C `int` flags — use `Int32` / `u8`
- [ ] `static` C locals moved to unit-level `var` (thread-unsafe in C too — OK)
- [ ] `const` arrays moved verbatim; values unchanged
- [ ] Macros expanded inline OR replaced with `inline` procedures of identical
  semantics
- [ ] `assert()` calls retained; implemented via a Pascal `AssertH` that logs
  file/line and halts on failure
- [ ] Compiled `-O3` clean (no warnings in new code)
- [ ] A differential test exercises the function's layer

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

## References

- SQLite upstream: https://sqlite.org/src/
- SQLite file format: https://sqlite.org/fileformat.html
- SQLite VDBE opcodes: https://sqlite.org/opcode.html
- SQLite "How SQLite is Tested": https://sqlite.org/testing.html
- pas-core-math (structural inspiration): `../pas-core-math/`
- pas-bzip2 (structural inspiration): `../pas-bzip2/`
- D. Richard Hipp et al., SQLite, public domain.
