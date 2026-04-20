# pas-sqlite3

A faithful line-by-line port of **SQLite 3.53.0** (D. Richard Hipp et al.)
from C to **Free Pascal (FPC 3.2.2+)** targeting x86-64 Linux.

> **Status: Phase 0 of 12 complete** — infrastructure and build scaffolding
> in place.  No SQLite logic has been ported yet; the differential-testing
> oracle is the focus of the next phases.

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
│   ├── passqlite3internal.pas  shared constants from sqliteInt.h (built progressively)
│   ├── csqlite3.pas            cdecl bindings to libsqlite3.so (tests only)
│   └── tests/
│       ├── build.sh            build script
│       ├── vectors/            canonical .db files and .sql scripts
│       └── TestSmoke.pas       build-system health check
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
| 1 | OS abstraction (VFS, POSIX locks, mutexes) | 🔲 Pending |
| 2 | Utilities (varint, hash, printf, random, UTF) | 🔲 Pending |
| 3 | Page cache + Pager + WAL | 🔲 Pending |
| 4 | B-tree | 🔲 Pending |
| 5 | VDBE bytecode interpreter | 🔲 Pending |
| 6 | Code generators (SQL → VDBE) | 🔲 Pending |
| 7 | Parser (tokenizer + Lemon grammar) | 🔲 Pending |
| 8 | Public API | 🔲 Pending |
| 9 | Acceptance: differential + fuzz testing | 🔲 Pending |
| 10 | Benchmarks | 🔲 Pending |
| 11 | Performance optimisation | 🔲 Pending |
| 12 | CLI tool (shell.c) | 🔲 Pending |

See `tasklist.md` for the full per-task breakdown.

---

## References

- SQLite upstream: <https://sqlite.org/src/>
- SQLite file format: <https://sqlite.org/fileformat.html>
- SQLite VDBE opcodes: <https://sqlite.org/opcode.html>
- D. Richard Hipp et al., SQLite, public domain.
