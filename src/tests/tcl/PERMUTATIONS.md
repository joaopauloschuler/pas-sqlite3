# Permutations matrix — 9.4.7.e first cut

Upstream SQLite re-runs every .test file under ~30 build/runtime
permutations defined in `sqlite3/test/permutations.test`.  pas-sqlite3
wires a first-cut subset here, with the full matrix as a known
follow-up (not in baseline CI).

## How to drive

```
bin/TclTestDriver --permutation NAME [--limit N] [--filter ...] [--build P]
src/tests/tcl/permutations_matrix.sh list
src/tests/tcl/permutations_matrix.sh run wal --limit 10
src/tests/tcl/permutations_matrix.sh all  --limit 10
```

`--permutation NAME` either applies a runtime PRAGMA via `reset_db`
(`tester_min.tcl:reset_db`, hooked through `presql` /
`::G(perm:presql)` exactly as upstream tester.tcl:2334..2338), or maps
to a pre-built shared object via `--build PROFILE` (e.g.
`serialized` → `libpassqlite3tcl-threadsafe.so`).

Without `--permutation`, behaviour is byte-identical to the legacy
baseline run (no extra cost — no pragma emitted, no .so swap).

## Wired (10 permutations)

| Name                 | Mechanism                                | C ref                          |
|----------------------|------------------------------------------|--------------------------------|
| `wal`                | `PRAGMA journal_mode=WAL`                | permutations.test:1019         |
| `inmemory_journal`   | `PRAGMA journal_mode=MEMORY`             | permutations.test:774          |
| `persistent_journal` | `PRAGMA journal_mode=PERSIST`            | permutations.test:704          |
| `truncate_journal`   | `PRAGMA journal_mode=TRUNCATE`           | permutations.test:715          |
| `no_journal`         | `PRAGMA journal_mode=OFF`                | permutations.test:737          |
| `exclusive`          | `PRAGMA locking_mode=EXCLUSIVE`          | permutations.test:681          |
| `exclusive-truncate` | locking_mode=EXCLUSIVE + journal_mode=TRUNCATE | permutations.test:692    |
| `utf16`              | `PRAGMA encoding='UTF-16'`               | permutations.test:655          |
| `serialized`         | alias → `--build threadsafe`             | permutations.test:578 (closest) |
| `multithread`        | alias → `--build threadsafe`             | permutations.test:610 (closest) |

The eight pragma-only permutations cost zero rebuild — each just
emits the SQL string in `reset_db` after every fresh `db` handle.
The two build-alias permutations swap to the existing
`bin/libpassqlite3tcl-threadsafe.so` (built by
`src/tests/build_tcl_lib_threadsafe.sh`).

## Deferred (~20 permutations)

These need either Tcl commands not yet exposed (`sqlite3_config_*`,
`sqlite3_install_memsysN`, `install_malloc_faultsim`,
`sqlite3_config_lookaside`, `optimization_control`) or an
`-initialize` block that reconfigures the engine before each `.test`.
None of them are reachable through `presql` alone.

| Bucket               | Names                                                | Blocker                                       |
|----------------------|------------------------------------------------------|-----------------------------------------------|
| memsubsys / heap     | memsys3, memsys5, memsys5-2, memsubsys1, memsubsys2  | `sqlite3_install_memsys3`, `sqlite3_config_heap` |
| mutex config         | singlethread, fullmutex, nomutex, no_mutex_try       | `sqlite3_config singlethread/multithread/...`     |
| lookaside / faultsim | nolookaside, nofaultsim                              | `sqlite3_config_lookaside`, `install_malloc_faultsim` |
| journal injection    | journaltest, safe_append, persistent_journal_error, no_journal_error | crash-vfs / `jt_*` Tcl shim            |
| io fault             | autovacuum_crash, autovacuum_ioerr                   | crash-vfs registered as `-vfs crash`              |
| coverage             | coverage-wal/-pager/-analyze/-sorter, valgrind, valgrind-nolookaside | external tooling / build flags        |
| optimizer            | no_optimization, prepare, sorterref, queryplanner    | `optimization_control`, legacy `-use-legacy-prepare`, SQLITE_CONFIG_SORTERREF_SIZE |
| onefile / mmap       | onefile, mmap, atomic-batch-write, win_unc_locking   | extra VFS shims                                   |
| session / rbu / rtree| session, session_eec, session_strm, rbu, rtree, lsm1 | upstream ext/ modules not built into pas .so      |
| misc                 | sorterref, maindbname, vfslog                        | `set ::G(perm:dbconfig)` / `set ::G(perm:sqlite3_args)` not honoured by `sqlite3 db ...` shim |

When the underlying Tcl shims land, append to the `PERMUTATIONS[]`
table in `src/tests/TclTestDriver.pas` and to `WIRED` in
`src/tests/tcl/permutations_matrix.sh`.

## Smoke test

The first-cut wiring is verified by running the existing baseline
corpus with `--permutation wal --limit 10`: the per-test counts must
match the baseline run, because none of these orthogonal toggles
should regress an idempotent .test.  Strict-gate regressions surface
the same way as baseline (`--gate strict`).

## Out of scope (first cut)

* Per-permutation .test exclusion lists from upstream
  (`test_set $::allquicktests -exclude {...}`) — the driver currently
  runs the same MANIFEST.txt for every permutation.
* `-initialize` / `-shutdown` blocks beyond pragmas.
* `set ::G(perm:sqlite3_args)` / `set ::G(perm:dbconfig)` — both are
  no-ops because the `sqlite3 db ...` Tcl command does not yet thread
  through extra args.
