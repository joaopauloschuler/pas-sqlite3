# pas-sqlite3

A faithful **AI made** port of **SQLite 3.53.0** (D. Richard Hipp et al.)
from C to **Free Pascal (FPC 3.2.2+)** targeting x86-64 Linux.

> **Status: Phases 0–5 complete; Phases 6–8 ported — in testing.**  The Pascal port now opens databases, parses SQL,
> generates VDBE bytecode, and runs queries end-to-end against its own
> pager / B-tree / VDBE.  `TestExplainParity` reports **1026 / 1026** SQL
> statements producing byte-identical VDBE bytecode versus the C reference.
> Differential probes (`DiagOps`, `DiagCast`,
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

## Regression testing

The formal regression gate runs every `Test*` binary under `bin/` and treats
each binary's exit code as its pass/fail signal (exit 0 = pass, non-zero =
fail).  All `Test*` binaries follow this convention, so the gate auto-discovers
new tests by construction — adding a `Test*.pas` to `src/tests/build.sh` is
enough to put it under the gate.

`Diag*` binaries are *differential probes* (port vs. C oracle) rather than
pass/fail tests, and many legitimately emit non-zero divergence counts while
the port matures.  They are deliberately **not** part of the binary
pass/fail gate; their divergence counts are tracked in `tasklist.md`
instead.

To run the test:

```bash
src/tests/run_regression.sh    # run every bin/Test* and aggregate results
```

Each test runs in its own temporary working directory under a per-test
timeout (default 60s, override with `REGRESSION_TIMEOUT=<seconds>`).

Per-test logs are retained under a temporary directory only when at least
one binary fails; an all-green run cleans them up.  The script exits
non-zero if any binary fails, so it can be wired into CI directly.

- **Known failures** (tracked, not regressions introduced by the gate):
  - `TestPagerReadOnly` — 1 / 10 sub-tests pass; `sqlite3PagerOpen` returns
    `SQLITE_CANTOPEN` (rc=14) for cases T1–T9.  Phase 3.B.2a fixture work
    pending.

Failures are deliberately left visible rather than quarantined so they
cannot be silently ignored.

### Full SQL corpus differential (`TestSQLCorpus`)

The broadest single gate: `bin/TestSQLCorpus` harvests SQL string literals
embedded in every `Diag*.pas` / `Test*.pas` source file (the existing
differential probes), then runs each statement through both oracles in
isolated workdirs and byte-compares stdout, stderr, rc, and the on-disk
db blob (with documented non-deterministic bytes masked).

```bash
LD_LIBRARY_PATH=src/ bin/TestSQLCorpus
```

The summary line reports `scripts run / ok / diverge`.  Any divergence is
catalogued in `src/tests/DIVERGENCES.md` (per-file rollup + first 16-byte
window for db-blob mismatches) so each one is bisectable against the C
oracle — see Phase 9.1 in `tasklist.md` for the workflow.  Supporting
artefacts:

- `src/tests/corpus/MANIFEST.txt` — tier-1 / tier-2 source-file inventory
- `src/tests/corpus/MASK.md` — masked db-header byte ranges + C cites
- `src/tests/SQLLiteralExtractor.pas` — the literal-extraction scanner
- `src/tests/CorpusOracle.pas` — Pascal-port + libsqlite3 oracle plumbing

The harness exits rc=0 even when divergences exist (catalogue-only by
design); promotion to a hard CI gate is tracked under `9.1.5`.

---

## Quick start examples

Two ways to drive the Pascal port: link against the `passqlite3*` units
from your own program, or pipe SQL through the `passqlite3` shell binary.
Both examples match the canonical SQLite quickstart at
<https://www.sqlite.org/quickstart.html>; see
[`src/tests/DiagSampleProg.pas`](src/tests/DiagSampleProg.pas) for a fuller
sample (prepare/step, bind, callback) that is run side-by-side against the
C reference for byte-identical transcripts.

### 1. From Pascal code

```pascal
{$I passqlite3.inc}
program QuickStart;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3os,
  passqlite3pcache, passqlite3pager, passqlite3wal,
  passqlite3btree, passqlite3vdbe, passqlite3codegen,
  passqlite3parser, passqlite3vtab,
  passqlite3main;

function PrintRow(pArg: Pointer; nCol: i32;
  argv, colv: PPAnsiChar): i32; cdecl;
var
  i: i32;
  pCol, pVal: PPAnsiChar;
begin
  pCol := colv; pVal := argv;
  for i := 0 to nCol - 1 do begin
    if pVal^ = nil then
      WriteLn(pCol^, ' = NULL')
    else
      WriteLn(pCol^, ' = ', pVal^);
    Inc(pCol); Inc(pVal);
  end;
  WriteLn;
  Result := 0;
end;

var
  db: PTsqlite3;
  pErr: PAnsiChar;
begin
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then Halt(1);
  pErr := nil;

  sqlite3_exec(db,
    'CREATE TABLE t(a INTEGER, b TEXT);'#10 +
    'INSERT INTO t VALUES(1, ''one''), (2, ''two''), (3, NULL);',
    nil, nil, @pErr);
  if pErr <> nil then begin sqlite3_free(pErr); pErr := nil; end;

  sqlite3_exec(db, 'SELECT a, b FROM t ORDER BY a;',
               @PrintRow, nil, @pErr);
  if pErr <> nil then sqlite3_free(pErr);

  sqlite3_close(db);
end.
```

Compile alongside the rest of the suite via `src/tests/build.sh`, or copy
the `fpc` invocation from there. No `libsqlite3.so` is required at run
time — the binary is pure Pascal.

For a prepared-statement / bind / step variant, see
`RunSample_Pas_BindInsert` in `src/tests/DiagSampleProg.pas:186`.

### 2. From the CLI

`src/tests/build.sh` produces `bin/passqlite3`, the Pascal port of
SQLite's `shell.c` (Phase 10 — basic skeleton; meta-commands beyond
`-help` / `-version` are still being landed):

```bash
# Run a one-shot SQL string against an on-disk database:
bin/passqlite3 demo.db \
  "CREATE TABLE t(a INTEGER, b TEXT);
   INSERT INTO t VALUES(1,'one'),(2,'two'),(3,NULL);
   SELECT * FROM t;"
```

Output:

```
1|one
2|two
3|
```

Or pipe SQL into an in-memory database:

```bash
echo "SELECT 1+1, 'hello';" | bin/passqlite3 :memory:
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
| 6 | Code generators (SQL → VDBE) | 🧪 Ported — in testing |
| 7 | Parser (tokenizer + Lemon grammar) | 🧪 Ported — in testing |
| 8 | Public API | 🧪 Ported — in testing |
| 9 | Acceptance: differential + fuzz testing | 🔲 Pending |
| 10 | CLI tool (`shell.c` → `passqlite3shell.pas`) | 🚧 In progress |
| 11 | Benchmarks (Pascal `speedtest1` port) | 🔲 Pending |
| 12 | Performance optimisation | 🔲 Pending |

See `tasklist.md` for the full per-task breakdown.

---

## References

- SQLite upstream: <https://sqlite.org/src/>
- SQLite file format: <https://sqlite.org/fileformat.html>
- SQLite VDBE opcodes: <https://sqlite.org/opcode.html>
- D. Richard Hipp et al., SQLite, public domain.
