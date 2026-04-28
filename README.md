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

```
pas-sqlite3/
├── src/
│   ├── passqlite3.inc          compiler directives (included first in every unit)
│   ├── passqlite3types.pas     primitive types, result codes, open flags, limits
│   ├── passqlite3internal.pas  shared constants from sqliteInt.h
│   ├── passqlite3util.pas      hash, varint, printf glue, mprintf, UTF helpers
│   ├── passqlite3printf.pas    sqlite3_snprintf / %!.*g / sqlite3RenderNumF
│   ├── passqlite3os.pas        VFS, POSIX file locks, mutexes
│   ├── passqlite3pcache.pas    page cache
│   ├── passqlite3pager.pas     pager + journal
│   ├── passqlite3wal.pas       write-ahead log
│   ├── passqlite3btree.pas     B-tree
│   ├── passqlite3vdbe.pas      VDBE bytecode interpreter
│   ├── passqlite3codegen.pas   SQL → VDBE code generators (build/select/expr/where/...)
│   ├── passqlite3parser.pas    tokenizer + Lemon grammar
│   ├── passqlite3main.pas      public sqlite3_* API surface
│   ├── passqlite3backup.pas    online backup API
│   ├── passqlite3vtab.pas      virtual-table interface
│   ├── passqlite3json.pas      JSON1 extension
│   ├── passqlite3jsoneach.pas  json_each / json_tree table-valued fns
│   ├── passqlite3carray.pas    carray() table-valued function
│   ├── passqlite3dbpage.pas    sqlite_dbpage virtual table
│   ├── passqlite3dbstat.pas    sqlite_dbstat virtual table
│   ├── csqlite3.pas            cdecl bindings to libsqlite3.so (tests only)
│   └── tests/
│       ├── build.sh            build script
│       ├── vectors/            canonical .db files and .sql scripts
│       ├── TestSmoke.pas       build-system health check
│       ├── TestExplainParity.pas   primary VDBE-bytecode parity gate
│       ├── TestParser.pas / TestSelectBasic.pas / TestDMLBasic.pas /
│       │   TestWhereBasic.pas / TestVdbeAgg.pas / TestSchemaBasic.pas /
│       │   TestVdbeRecord.pas / TestBtreeCompat.pas / TestPager*.pas /
│       │   TestPCache.pas / TestOSLayer.pas / TestPrepareBasic.pas / ...
│       │   per-layer differential tests
│       └── Diag*.pas               focused runtime-divergence probes
│                                   (DiagOps, DiagCast, DiagDate, DiagFunctions,
│                                    DiagMoreFunc, DiagFeatureProbe, ...)
├── bin/                        compiled test binaries
├── install_dependencies.sh
├── LICENSE                     public domain (matching upstream SQLite)
├── README.md                   this file
└── tasklist.md                 detailed phase-by-phase task list
```

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
| 6 | Code generators (SQL → VDBE) | 🚧 In progress |
| 7 | Parser (tokenizer + Lemon grammar) | 🚧 In progress |
| 8 | Public API | 🚧 In progress |
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
