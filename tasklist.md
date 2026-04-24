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

- [ ] **5.4** Port `vdbe.c` — the `sqlite3VdbeExec` loop. **~199 opcodes**.
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
  - **5.4c** Record I/O: `OP_Column`, `OP_MakeRecord`, `OP_Insert`, `OP_Delete`.
  - **5.4d** Arithmetic / comparison: `OP_Add`, `OP_Subtract`, `OP_Multiply`,
    `OP_Divide`, `OP_Remainder`, `OP_Eq`, `OP_Ne`, `OP_Lt`, `OP_Le`, `OP_Gt`,
    `OP_Ge`, `OP_BitAnd`, `OP_BitOr`, `OP_ShiftLeft`, `OP_ShiftRight`.
  - **5.4e** String/blob: `OP_String8`, `OP_Blob`, `OP_Concat`, `OP_Length`.
  - **5.4f** Aggregate: `OP_AggStep`, `OP_AggFinal`, `OP_AggInverse`,
    `OP_AggValue`.
  - **5.4g** Transaction control: `OP_Transaction`, `OP_Savepoint`,
    `OP_AutoCommit`.
  - **5.4h** Everything else: sorter ops, virtual table ops, function calls.

- [ ] **5.5** Port `vdbeapi.c`: public API — `sqlite3_step`, `sqlite3_column_*`,
  `sqlite3_bind_*`, `sqlite3_reset`, `sqlite3_finalize`.

- [ ] **5.6** Port `vdbeblob.c`: incremental blob I/O API
  (`sqlite3_blob_open`, `sqlite3_blob_read`, `sqlite3_blob_write`,
  `sqlite3_blob_bytes`, `sqlite3_blob_reopen`, `sqlite3_blob_close`).

- [ ] **5.7** Port `vdbesort.c`: the external sorter (used for ORDER BY /
  GROUP BY on large result sets that don't fit in memory). Spills to temp
  files; correctness depends on deterministic tie-breaking.

- [ ] **5.8** Port `vdbetrace.c`: the `EXPLAIN` / `EXPLAIN QUERY PLAN`
  rendering helper. Small (~300 lines).

- [ ] **5.9** Port `vdbevtab.c`: VDBE-side support for virtual-table opcodes
  (`OP_VOpen`, `OP_VFilter`, `OP_VNext`, `OP_VColumn`, `OP_VUpdate`). Depends
  on `vtab.c` (Phase 6.bis) being ported first — reorder if needed.

- [ ] **5.10** `TestVdbeTrace.pas`: for every VDBE program produced by the C
  reference from the SQL corpus, run the program on the Pascal VDBE and on the
  C VDBE, with `PRAGMA vdbe_trace=ON`, and diff the resulting trace logs.
  **Any divergence halts the phase.**

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

- [ ] **6.1** Port the **expression layer** first — every other codegen unit
  calls into it: `expr.c`, `resolve.c`, `walker.c`, `treeview.c`.

- [ ] **6.2** Port the **query planner**: `where.c` + `wherecode.c` +
  `whereexpr.c` + `whereInt.h`. `WhereInfo`, `WhereLoop`, `WhereTerm`;
  cost model. The most algorithmically rich group in the codebase after
  `vdbe.c`. Port faithfully — heuristic constants must match exactly or the
  planner will choose different indexes and EXPLAIN diff will fail.

- [ ] **6.3** Port `select.c`: `sqlite3Select`, aggregation, GROUP BY, HAVING,
  ORDER BY, LIMIT/OFFSET, compound SELECT (UNION / INTERSECT / EXCEPT),
  common table expressions, recursive queries.

- [ ] **6.4** Port **DML**: `insert.c`, `update.c`, `delete.c`, `upsert.c`,
  `trigger.c`. Each is ~1–2 k lines.

- [ ] **6.5** Port **schema management**: `build.c` (CREATE/DROP + parsing
  `sqlite_master` at open), `alter.c` (ALTER TABLE), `prepare.c` (schema
  parsing + `sqlite3_prepare` internals), `analyze.c`, `attach.c`,
  `pragma.c`, `vacuum.c`.

- [ ] **6.6** Port **auth and built-in functions**: `auth.c`, `callback.c`,
  `func.c` (scalars: `abs`, `coalesce`, `like`, `substr`, `lower`, etc.),
  `date.c` (`date()`, `time()`, `julianday()`, `strftime()`, `datetime()`),
  `fkey.c` (foreign-key enforcement), `rowset.c`.

- [ ] **6.7** Port `window.c`: SQL window functions (`OVER`, `PARTITION BY`,
  `ROWS BETWEEN`, …). Intersects with `select.c` — port last within the
  codegen phase so `select.c` is stable when window integration starts.

- [ ] **6.8** (Optional, defer-able) Port `json.c`: JSON1 scalar functions,
  `json_each`, `json_tree`. Only if users need it in v1.

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

- [ ] **7.1** Port `tokenize.c` (the lexer) to `passqlite3parser.pas`. Hand
  port — it is a single function (`sqlite3GetToken`) of ~400 lines driven by
  character classification tables. `complete.c` is a small companion
  (~280 lines) and ports in the same unit.

- [ ] **7.2** **Strategy for `parse.y`:** *regenerate* with Lemon targeting
  Pascal, rather than hand-porting the generated `parse.c` (which is ~6k lines
  of Lemon-emitted boilerplate). This requires:
  - A Pascal code-emitter for Lemon (`tool/lempar.c` equivalent in Pascal),
    patched into the `lemon` tool itself.
  - The grammar file `parse.y` is used unchanged.
  Fallback if Pascal-Lemon is too expensive: hand-port `parse.c` as a one-time
  transliteration; it is auto-generated so as long as the grammar doesn't
  change it won't need re-porting.

- [ ] **7.3** Port parse-tree action routines that Lemon calls (these live in
  `build.c` and friends from Phase 6, so they are already available).

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
