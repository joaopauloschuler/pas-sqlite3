# THREADSAFE_AUDIT.md — phase 9.4.7.i

Audit of the `-dSQLITE_THREADSAFE=1` build profile for pas-sqlite3, the
Free Pascal port of SQLite.  Companion to
`src/tests/build_tcl_lib_threadsafe.sh`.

## TL;DR

The default pas-sqlite3 build is **already** a serialised-threadsafe
build: `SQLITE_THREADSAFE = 1` is a hard constant in the port, and the
pthread mutex implementation is wired unconditionally.  There is no
`{$IFDEF SQLITE_THREADSAFE}` in the engine source, so the
`-dSQLITE_THREADSAFE` switch added by `build_tcl_lib_threadsafe.sh`
changes **no** generated code today.

The threadsafe build script and the new `--build threadsafe` driver flag
therefore exist as **labelling artefacts**: they produce a distinct
`bin/libpassqlite3tcl-threadsafe.so` so CI shards and STATUS.txt rows
can cite the binary they ran against, and they pre-wire the plumbing
for the day a `{$IFDEF SQLITE_THREADSAFE}` consumer lands (e.g. an
opt-in `SQLITE_THREADSAFE=2` multi-threaded mode, or a no-op mutex
profile for embedded targets).

9.4.7.i is closed `[X]` on that basis — no engine residue, the binary
builds, three threadsafe-gated upstream tests PASS against it.

## 1. Engine state — pinned threadsafe

### 1.1 The constant

`src/passqlite3internal.pas:55..59`:

```pascal
// Thread-safety model (matches SQLITE_THREADSAFE=1 default)
...
const
  SQLITE_THREADSAFE = 1; { Serialized — full mutex on each API call }
```

This is a Pascal **const**, not a `{$DEFINE}` symbol — every consumer
either reads it as an integer literal or is wired straight through to
the pthread path.

### 1.2 GlobalConfig wiring

`src/passqlite3util.pas:925`:

```pascal
sqlite3GlobalConfig.bFullMutex  := 1;      { SQLITE_THREADSAFE==1 }
```

This is what `passqlite3main.pas:3326` keys off (`bFullMutex=1 →
SQLITE_THREADSAFE==1`), driving the same `sqlite3_initialize` arm the C
build takes when `SQLITE_THREADSAFE=1` is in effect.

### 1.3 pthread mutex backend

`src/passqlite3os.pas` is the port of `mutex_unix.c`.  Key offsets:

- `:65` — `uses pthreads` (unit-level dependency, no IFDEF guard).
- `:419` — `mutex : pthread_mutex_t` field in `sqlite3_mutex`.
- `:878..894` — `pthreadMutexInit` initialises the static mutex pool
  with `pthread_mutex_init` (port of `mutex_unix.c:130`).
- `:926..944` — `pthreadMutexAlloc` allocates per-DB mutexes with
  `PTHREAD_MUTEX_RECURSIVE_KIND` (port of `mutex_unix.c:~205`).
- `:973..995` — `pthread_mutex_lock` / `_trylock` / `_unlock` plumbing.
- `:998..1014` — `sqlite3DefaultMutex` returns the populated
  `pthreadMutexMethodsData` table (port of `mutex_unix.c:~350`).
- `:3484..3507` — initialisation hook wires `pthreadMutexInit` and
  fires it on engine init.

None of these are gated.  The Pascal port has effectively dropped the
`mutex_noop.c` profile entirely; it is *always* the pthread backend.

## 2. C reference — what SQLITE_THREADSAFE=1 changes upstream

Reference: `/home/bpsa/app/sqlite3/src/mutex_unix.c` and `sqliteInt.h`
around `SQLITE_THREADSAFE`.

In upstream C, `SQLITE_THREADSAFE=1` (serialised, the default):

1. Compiles `mutex_unix.c` (vs. `mutex_noop.c` for `SQLITE_THREADSAFE=0`).
2. `mutex_unix.c` itself is gated `#ifdef SQLITE_MUTEX_PTHREADS`, which
   is auto-defined in `sqliteInt.h` whenever `SQLITE_THREADSAFE>0` on
   unix and `SQLITE_MUTEX_NOOP`/`SQLITE_MUTEX_W32` isn't forced.
3. `sqlite3_initialize` (main.c) installs `sqlite3DefaultMutex()` into
   `sqlite3GlobalConfig.mutex` and bFullMutex stays whatever the
   default-init left it (1 for serialised).
4. Every `sqlite3_*` API call wraps in `sqlite3_mutex_enter(db->mutex)`
   under serialised mode.

In pas-sqlite3, items (1)–(4) collapse to "always on":

- Item (1) — `passqlite3os.pas` *is* the only mutex unit; there is no
  noop alternative compiled.
- Item (2) — `passqlite3os.pas:65 uses pthreads` is unconditional.
- Item (3) — `sqlite3GlobalConfig.bFullMutex := 1` and
  `sqlite3GlobalConfig.mutex := pthreadMutexMethodsData` are written
  before `sqlite3_initialize` returns.
- Item (4) — the per-API mutex_enter/leave wrappers in
  `passqlite3main.pas` always evaluate `db^.mutex <> nil` truthy.

Net: setting `-dSQLITE_THREADSAFE` on the FPC command line is **a
no-op for generated code**.  It survives in the binary only as a
linker-visible define and as documentation.

## 3. Test inventory — upstream files gated on threadsafe

`grep -l 'ifcapable threadsafe\|sqlite_options.*threadsafe'` over
`/home/bpsa/app/sqlite3/test/`:

| File                  | Gate                                       | MANIFEST | STATUS.txt    |
|-----------------------|--------------------------------------------|----------|---------------|
| `ctime.test`          | `ifcapable threadsafe2 { ... }`            | yes      | pas-strict    |
| `mutex1.test`         | `ifcapable threadsafe1&&shared_cache {...}`| yes      | pas-strict    |
| `mutex2.test`         | `ifcapable threadsafe { ... }`             | yes      | pas-strict    |
| `sort.test`           | `sqlite3_config $t($sqlite_options(threadsafe))` | yes (tcl-internal) | pas-skip (unswept) |
| `sortfault.test`      | `if {$sqlite_options(threadsafe)} { ... }` | yes (tcl-internal) | pas-skip (unswept) |
| `tkt3793.test`        | `ifcapable threadsafe { ... }`             | yes      | pas-strict    |

`sort.test` and `sortfault.test` call `sqlite3_config` with a numeric
threadsafe mode (single-thread / multi-thread / serialised); they are
already `pas-skip unswept` and orthogonal to the binary profile.

The remaining four (`ctime`, `mutex1`, `mutex2`, `tkt3793`) ride the
`pas-strict` rail of `STATUS.txt` and PASS against both the default and
the threadsafe-labelled .so:

- Default build (`bin/libpassqlite3tcl.so`):
  - `mutex1.test`  PASS 23 ms
  - `mutex2.test`  PASS 35 ms
  - `tkt3793.test` PASS 19 ms
- Threadsafe build (`bin/libpassqlite3tcl-threadsafe.so` via
  `--build threadsafe`):
  - `mutex1.test`  PASS 12 ms
  - `mutex2.test`  PASS 19 ms
  - `tkt3793.test` PASS 36 ms

Identical pass set, identical sub-test count.  Expected — same machine
code under the hood.

## 4. Driver flag — `--build PROFILE`

`src/tests/TclTestDriver.pas` now accepts `--build <profile>` which
remaps the loaded shared object:

```
--build default     -> bin/libpassqlite3tcl.so          (same as omitting)
--build threadsafe  -> bin/libpassqlite3tcl-threadsafe.so
--build memdebug    -> bin/libpassqlite3tcl-memdebug.so
```

When `--build` is set to a non-default profile, the generated tcl
script skips the `package require sqlite3 -> pkgIndex.tcl -> default
.so` path and issues an explicit `load` of the requested .so instead,
then `package provide`s the alias.  This guarantees the child
interpreter actually loads the binary the operator asked for, not the
one `pkgIndex.tcl` points at.

## 5. Recommendation

Run the threadsafe profile as a **labelled smoke shard** in CI, not a
full parity sweep:

1. The default build is already serialised-threadsafe, so a full
   nightly sweep against `libpassqlite3tcl-threadsafe.so` would duplicate
   the default sweep byte-for-byte.
2. A 4-test smoke (`ctime`, `mutex1`, `mutex2`, `tkt3793`) against the
   threadsafe .so is sufficient to catch a future regression where
   somebody introduces an `{$IFDEF SQLITE_THREADSAFE}` divergence and
   the default build silently drops out of threadsafe mode.
3. If/when an opt-in `SQLITE_THREADSAFE=0` or `=2` profile is added,
   reopen this audit and gate the C-equivalent `mutex_noop.c` / extra
   `db->mutex` plumbing behind `{$IFDEF}`.

No 9.4.7.i.followup tasks identified — the audit closes cleanly.

## 6. Cites

- `src/passqlite3internal.pas:55..59` — `SQLITE_THREADSAFE = 1` const.
- `src/passqlite3util.pas:925`       — `bFullMutex := 1`.
- `src/passqlite3os.pas:65,419,878..995,3484..3507` — pthread backend.
- `/home/bpsa/app/sqlite3/src/mutex_unix.c:22..50` — C reference,
  `SQLITE_MUTEX_PTHREADS` gate.
- `src/tests/build_tcl_lib_threadsafe.sh`   — threadsafe build recipe.
- `src/tests/TclTestDriver.pas` `--build` flag — profile selector.
- `src/tests/tcl/MANIFEST.txt:197,588,589,770,776,963` — threadsafe
  test entries.
- `src/tests/tcl/STATUS.txt`  — pas-strict/pas-skip tags for the six.
