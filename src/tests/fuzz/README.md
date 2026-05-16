# AFL fuzzing wrapper (Phase 13)

This directory hosts the `afl-fuzz` wiring around the Phase 9.3.1
in-process differential harness `src/tests/TestFuzzDiff.pas`.  The
harness drives both the C oracle (`libsqlite3.so`) and the Pascal
port (`passqlite3main`) over a single `dbsqlfuzz`-format input, then
byte-compares `stdout / stderr / rc / db-blob`.  AFL feeds inputs;
the harness reports divergences; the driver maps results to AFL exit
codes so the fuzzer can bucket findings.

## Files

| File              | Purpose                                                  |
|-------------------|----------------------------------------------------------|
| `afl-driver.pas`  | Stdin→tmpfile shim that execs `bin/TestFuzzDiff`.        |
| `build-afl.sh`    | Detects AFL, picks instrumentation route, compiles.       |
| `seeds/`          | 8 `fuzzdataN.db` files from upstream (~62 MiB total).    |
| `.afl-route`      | One-line note recording which route the last build used. |

## Instrumentation routes

FPC has no `afl-clang-fast` equivalent.  Three viable routes (priority
order, per `tasklist.md` Phase 13 header lines ~1699-1728):

1. **`afl-as` assembler wedge (preferred).**
   `fpc -al -Aas -FD<afl-bin-dir> afl-driver.pas`
   `-al` keeps `.s` files, `-Aas` selects GNU `as`, `-FD` points FPC's
   assembler search path at the directory containing `afl-as`, which
   rewrites every branch site with the AFL tramp + shared-memory
   bitmap update.  ~2x slowdown.  May fall through on older AFL
   versions whose pattern matcher doesn't accept FPC's GAS dialect.
2. **QEMU mode (`afl-fuzz -Q`).**
   No compiler cooperation; instrumentation is inserted at translation
   time inside patched user-mode QEMU.  ~5-10x slowdown but
   bulletproof.  Requires the `afl-qemu-trace` helper (often packaged
   as `afl++-qemu`).
3. **Black-box (`afl-fuzz -n`).**
   No instrumentation, dumb mutation only.  Last resort.

Not viable: a pure C shim built with `afl-clang-fast` — the shim is
instrumented but the Pascal callee isn't, so the bitmap stays empty
for the code under test.

`build-afl.sh` tries the three routes in order and writes the chosen
route to `.afl-route`.

## Building

```sh
bash src/tests/fuzz/build-afl.sh
```

If `afl-fuzz` is missing the script self-reports and exits 0 (so a
project-wide `build.sh` doesn't fail on machines without AFL).  Pass
`FORCE_BUILD=1` to compile the driver in route-3 form anyway.

## Installing AFL

```sh
apt install afl++              # Debian / Ubuntu / Mint
dnf install american-fuzzy-lop # Fedora / RHEL
pacman -S afl++                # Arch
```

Or build AFL++ from source: <https://github.com/AFLplusplus/AFLplusplus>.

Before launching, AFL typically requires:

```sh
echo core | sudo tee /proc/sys/kernel/core_pattern
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

## Running a fuzzing session

`build-afl.sh` prints the exact command for the route it picked.  Example
(route 1):

```sh
mkdir -p src/tests/fuzz/findings
afl-fuzz -i src/tests/fuzz/seeds \
         -o src/tests/fuzz/findings \
         -- bin/afl-driver
```

For routes 2 and 3 add `-Q` or `-n` respectively.

## Smoke baseline

Phase 9.3.2 swept all 8 seeds through `TestFuzzDiff` and reported
**8/8 PASS, 0 divergences, 0 buckets** — see `tasklist.md` line ~241.
That sweep is the divergence-free baseline AFL extends from; any
crash or new-divergence bucket discovered by an AFL session is, by
construction, an input the seed sweep didn't already cover.

## Exit-code contract

| Code  | Meaning                                          |
|-------|--------------------------------------------------|
| 0     | PASS — byte-identical across both oracles.       |
| 1     | I/O error (stdin read, tmpfile, exec).           |
| 2     | Divergence — AFL marks input as interesting.     |
| 3     | Malformed dbsqlfuzz frame.                       |
| 128+N | Child died on signal N (typically SIGSEGV).      |

`afl-fuzz` treats signal-death as a crash; codes 2/3 surface through
the bitmap as new edges and are queued for later triage by Phase 13.2.

## Status

Phase 13.1: AFL driver wiring landed.  The build script self-reports
"AFL missing" on machines without `afl-fuzz` and exits cleanly; the
13.1.unverified follow-up tracks running the end-to-end build on a
host that has AFL installed.
