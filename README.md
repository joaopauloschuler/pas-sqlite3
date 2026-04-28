# pas-sqlite3

A faithful line-by-line port of **SQLite 3.53.0** (D. Richard Hipp et al.)
from C to **Free Pascal (FPC 3.2.2+)** targeting x86-64 Linux.

> **Status: Phases 0–5 complete; Phase 6 in flight; Phases 7–8
> largely landed.**  The Pascal port now opens databases, parses SQL,
> generates VDBE bytecode, and runs queries end-to-end against its own
> pager / B-tree / VDBE.  `TestExplainParity` reports **1016 / 1026** SQL
> statements producing byte-identical VDBE bytecode versus the C reference,
> with the remaining 10 divergences enumerated in `tasklist.md` (mostly
> ORDER BY sorter, GROUP BY, multi-row VALUES, sub-FROM materialisation,
> the autovacuum DROP TABLE follow-on, and the `INNER JOIN` aggregate
> bloom-filter KeyInfo gap).  Differential probes (`DiagOps`, `DiagCast`,
> `DiagDate`, `DiagFunctions`, `DiagMoreFunc`, `DiagFeatureProbe`, ...)
> drive the remaining runtime gaps.

---

## What this is

A behavioural and on-disk-parity port of SQLite.  The Pascal build must:

- produce byte-identical `.db` files for the same SQL input as the C reference,
- return identical query results, and
- emit the same VDBE bytecode for the same SQL.

This is **not** a wrapper around `libsqlite3.so` (FPC already ships
`sqlite3dyn` / `sqlite3conn` for that).  The goal is a pure-Pascal
implementation for study, hardening, and embedded use cases where a C
toolchain is unavailable.

---

## Prerequisites

- Free Pascal Compiler ≥ 3.2.2
- GCC (to build the C reference oracle `libsqlite3.so`)
- GNU Make
- Tcl (for SQLite's own Tcl test suite in Phase 9)
- The upstream SQLite split source tree at `../sqlite3/` (version 3.53.0 or
  later; **not** the amalgamation)

Run the dependency checker:

```bash
./install_dependencies.sh
```

---

## Build

```bash
src/tests/build.sh
```

This will:

1. Build `libsqlite3.so` from `../sqlite3/` via upstream's own build system
   (with `SQLITE_DEBUG`, `SQLITE_ENABLE_EXPLAIN_COMMENTS`, and
   `SQLITE_ENABLE_API_ARMOR` for differential-testing fidelity).
2. Compile all Pascal test binaries into `bin/`.

---

## Running the smoke test

```bash
LD_LIBRARY_PATH=src/ bin/TestSmoke
```

Expected output:

```
sqlite3 version : 3.53.0
csq_open_v2     : OK
csq_prepare_v2  : OK
csq_step        : SQLITE_ROW
column value    : 1
csq_step (done) : SQLITE_DONE
csq_finalize    : OK
csq_close       : OK

TestSmoke PASSED.
```

---

## Project layout

<pre>
pas-sqlite3/
├── <a href="src/">src/</a>
│   ├── <a href="src/passqlite3.inc">passqlite3.inc</a>          # compiler directives (included first in every unit)
│   ├── <a href="src/passqlite3types.pas">passqlite3types.pas</a>     # primitive types, result codes, open flags, limits
│   ├── <a href="src/passqlite3internal.pas">passqlite3internal.pas</a>  # shared constants from sqliteInt.h
│   ├── <a href="src/passqlite3util.pas">passqlite3util.pas</a>      # hash, varint, printf glue, mprintf, UTF helpers
│   ├── <a href="src/passqlite3printf.pas">passqlite3printf.pas</a>    # sqlite3_snprintf / %!.*g / sqlite3RenderNumF
│   ├── <a href="src/passqlite3os.pas">passqlite3os.pas</a>        # VFS, POSIX file locks, mutexes
│   ├── <a href="src/passqlite3pcache.pas">passqlite3pcache.pas</a>    # page cache
│   ├── <a href="src/passqlite3pager.pas">passqlite3pager.pas</a>     # pager + journal
│   ├── <a href="src/passqlite3wal.pas">passqlite3wal.pas</a>       # write-ahead log
│   ├── <a href="src/passqlite3btree.pas">passqlite3btree.pas</a>     # B-tree
│   ├── <a href="src/passqlite3vdbe.pas">passqlite3vdbe.pas</a>      # VDBE bytecode interpreter
│   ├── <a href="src/passqlite3codegen.pas">passqlite3codegen.pas</a>   # SQL → VDBE code generators (build/select/expr/where/...)
│   ├── <a href="src/passqlite3parser.pas">passqlite3parser.pas</a>    # tokenizer + Lemon grammar
│   ├── <a href="src/passqlite3main.pas">passqlite3main.pas</a>      # public sqlite3_* API surface
│   ├── <a href="src/passqlite3backup.pas">passqlite3backup.pas</a>    # online backup API
│   ├── <a href="src/passqlite3vtab.pas">passqlite3vtab.pas</a>      # virtual-table interface
│   ├── <a href="src/passqlite3json.pas">passqlite3json.pas</a>      # JSON1 extension
│   ├── <a href="src/passqlite3jsoneach.pas">passqlite3jsoneach.pas</a>  # json_each / json_tree table-valued fns
│   ├── <a href="src/passqlite3carray.pas">passqlite3carray.pas</a>    # carray() table-valued function
│   ├── <a href="src/passqlite3dbpage.pas">passqlite3dbpage.pas</a>    # sqlite_dbpage virtual table
│   ├── <a href="src/passqlite3dbstat.pas">passqlite3dbstat.pas</a>    # sqlite_dbstat virtual table
│   ├── <a href="src/csqlite3.pas">csqlite3.pas</a>            # cdecl bindings to libsqlite3.so (tests only)
│   └── <a href="src/tests/">tests/</a>
│       ├── <a href="src/tests/build.sh">build.sh</a>                  # build script
│       ├── <a href="src/tests/vectors/">vectors/</a>                  # canonical .db files and .sql scripts
│       ├── <a href="src/tests/TestSmoke.pas">TestSmoke.pas</a>             # build-system health check
│       ├── <a href="src/tests/TestExplainParity.pas">TestExplainParity.pas</a>     # primary VDBE-bytecode parity gate
│       ├── <a href="src/tests/TestParser.pas">TestParser.pas</a> / <a href="src/tests/TestSelectBasic.pas">TestSelectBasic.pas</a> / <a href="src/tests/TestDMLBasic.pas">TestDMLBasic.pas</a> /
│       │   <a href="src/tests/TestWhereBasic.pas">TestWhereBasic.pas</a> / <a href="src/tests/TestVdbeAgg.pas">TestVdbeAgg.pas</a> / <a href="src/tests/TestSchemaBasic.pas">TestSchemaBasic.pas</a> /
│       │   <a href="src/tests/TestVdbeRecord.pas">TestVdbeRecord.pas</a> / <a href="src/tests/TestBtreeCompat.pas">TestBtreeCompat.pas</a> / <a href="src/tests/TestPager.pas">TestPager*.pas</a> /
│       │   <a href="src/tests/TestPCache.pas">TestPCache.pas</a> / <a href="src/tests/TestOSLayer.pas">TestOSLayer.pas</a> / <a href="src/tests/TestPrepareBasic.pas">TestPrepareBasic.pas</a> / ...
│       │     per-layer differential tests
│       └── <a href="src/tests/DiagOps.pas">Diag*.pas</a>                 # focused runtime-divergence probes
│                                     (<a href="src/tests/DiagOps.pas">DiagOps</a>, <a href="src/tests/DiagCast.pas">DiagCast</a>, <a href="src/tests/DiagDate.pas">DiagDate</a>, <a href="src/tests/DiagFunctions.pas">DiagFunctions</a>,
│                                      <a href="src/tests/DiagMoreFunc.pas">DiagMoreFunc</a>, <a href="src/tests/DiagFeatureProbe.pas">DiagFeatureProbe</a>, ...)
├── bin/                        # compiled test binaries (git-ignored)
├── <a href="install_dependencies.sh">install_dependencies.sh</a>
├── <a href="LICENSE">LICENSE</a>                      # public domain (matching upstream SQLite)
├── <a href="README.md">README.md</a>                    # this file
└── <a href="tasklist.md">tasklist.md</a>                  # detailed phase-by-phase task list
</pre>

---

## Porting phases

| Phase | Contents | Status |
|-------|----------|--------|
| 0 | Infrastructure (inc, types, csqlite3, build scripts) | ✅ Done |
| 1 | OS abstraction (VFS, POSIX locks, mutexes) | ✅ Done |
| 2 | Utilities (varint, hash, printf, random, UTF) | ✅ Done |
| 3 | Page cache + Pager + WAL | ✅ Done |
| 4 | B-tree | ✅ Done |
| 5 | VDBE bytecode interpreter | ✅ Done |
| 6 | Code generators (SQL → VDBE) | 🚧 In progress (1016/1026 EXPLAIN parity; runtime sweeps 6.10..6.27) |
| 7 | Parser (tokenizer + Lemon grammar) | 🚧 In progress (7.4b/7.4c bytecode-/trace-diff gates open) |
| 8 | Public API | 🚧 In progress (8.10 sample-program gate open) |
| 10 | CLI tool (`shell.c` → `passqlite3shell.pas`) | 🔲 Pending |
| 11 | Benchmarks (Pascal `speedtest1` port) | 🔲 Pending |
| 12 | Acceptance: differential + fuzz testing | 🔲 Pending |
| 13 | Performance optimisation | 🔲 Pending |

See `tasklist.md` for the full per-task breakdown.

---

## References

- SQLite upstream: <https://sqlite.org/src/>
- SQLite file format: <https://sqlite.org/fileformat.html>
- SQLite VDBE opcodes: <https://sqlite.org/opcode.html>
- D. Richard Hipp et al., SQLite, public domain.
