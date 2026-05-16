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
| `afl-driver.pas`     | Stdin→tmpfile shim that execs `bin/TestFuzzDiff`.        |
| `build-afl.sh`       | Detects AFL, picks instrumentation route, compiles.       |
| `classify-crash.sh`  | Phase 13.2 triage helper — sorts AFL findings into 4 buckets. |
| `seeds/`             | 8 `fuzzdataN.db` files from upstream (~62 MiB total).    |
| `crashes/`           | Triaged AFL findings, bucketed by classifier (4 subdirs). |
| `.afl-route`         | One-line note recording which route the last build used. |

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

## Triage workflow (Phase 13.2)

`classify-crash.sh` is a pure-bash triage helper: feed it an AFL
`findings/default/crashes/` directory (or any list of suspect inputs)
and it sorts each input into one of four buckets under `crashes/`:

| Bucket          | Trigger condition                                              |
|-----------------|----------------------------------------------------------------|
| `pas-crash/`    | Harness died on signal AND stderr contains an FPC `Runtime error` / `EAccessViolation` / `External: SIG` marker. |
| `c-crash/`      | Harness died on signal AND stderr is silent (no FPC backtrace — only the preamble line printed before death). |
| `divergence/`   | Harness exited rc=2 — both backends ran to completion but at least one channel (stdout / stderr / rc / db-blob) differs. |
| `timeout/`      | Harness exceeded `TIMEOUT_S` wall-clock (default 30s) and was SIGTERM'd by `timeout(1)` — surfaces as rc=124. |

`PASS` inputs (rc=0) and `rc∈{1,3}` (I/O error / malformed dbsqlfuzz
frame) are silently skipped — they don't represent a defect.

Each placed input gets a `<input>.meta.txt` sidecar containing:
classification, original path, harness path + rc + signal, wall-clock,
diverged-channel list (for divergence), hex-prefix first-diff hints
(for divergence), and the first 4 KiB of the captured stderr.

```sh
# Default — point at AFL's per-session crash bucket
bash src/tests/fuzz/classify-crash.sh

# Or any directory / explicit file list, with --copy to preserve
# originals instead of moving:
bash src/tests/fuzz/classify-crash.sh --copy /path/to/inputs/

# Knobs:
TIMEOUT_S=60                         bash src/tests/fuzz/classify-crash.sh ...
PAS_FUZZDIFF_BIN=/alt/TestFuzzDiff   bash src/tests/fuzz/classify-crash.sh ...
```

Exit code: `0` if nothing bucketed (all PASS / skipped); `2` if at
least one input landed in a bucket — useful for CI gating.

**Crash-side disambiguation caveat.**  TestFuzzDiff runs both oracles
in a single process (C first, then Pas — `TestFuzzDiff.pas:RunBoth`).
On signal-death we can't tell from rc alone which oracle was active,
so we use the stderr heuristic above.  FPC's RTL reliably prints a
`Runtime error <n> at <addr>` preamble + backtrace on any uncaught
Pascal exception or SIGSEGV inside Pascal code (SysUtils installs
the SIGSEGV → RunError 216 hook); `libsqlite3.so` SIGSEGV emits
nothing.  Override in `<input>.meta.txt` if you have evidence the
heuristic misclassified a finding.

**Smoke baseline.**  Running the classifier across the 8 upstream
seeds yields 8/8 PASS, 0 bucketed — matching the Phase 9.3.2 sweep.

## Soak workflow (Phase 13.3)

`fuzz-soak.sh` is the long-running manual gate.  Default is a 24-hour
run that bails on first divergence so the operator (or a cron job)
can hand findings straight to `classify-crash.sh`.

```sh
# Default: 24h, stop on first crash/hang.
bash src/tests/fuzz/fuzz-soak.sh

# Shorter run, don't bail (stress soak):
bash src/tests/fuzz/fuzz-soak.sh --duration 2h --no-stop

# Anything timeout(1) accepts works: 30s, 30m, 2h, 24h, 7d.
```

Flow:

1. Pre-flight: reruns `build-afl.sh` to make sure `bin/afl-driver`
   matches the current tree, picks the route from `.afl-route`.
2. Launches `afl-fuzz` (with `-Q`/`-n` per route) under GNU
   `timeout(1)` so the wall-clock budget is hard.
3. Polls `findings/default/{crashes,hangs}/` every 5 min.  On first
   finding (with the default `--stop-on-first-divergence`): SIGTERMs
   `afl-fuzz`, runs `classify-crash.sh` on the new findings, prints
   the bucket summary.
4. Appends one row to `SOAK_LOG.md`: date, target, actual duration,
   seed count, route, `CLEAN` / `FOUND-N-BUGS`, git SHA.

Exit codes: `0` clean (timeout reached without findings), `2`
stopped on first finding, `1` setup failure.  If `afl-fuzz` is
missing the script self-reports and exits `0` — same convention as
`build-afl.sh`.

`SOAK_LOG.md` is the cumulative ledger.  We want N CLEAN 24h rows
visible before declaring Phase 13 finished; the ledger is evidence
for the manual gate, not a CI gate.

## Seed minimisation (Phase 13.4)

`minimize-corpus.sh` runs the standard AFL two-step:

1. `afl-cmin` — drop seeds whose AFL bitmap is a strict subset of
   another seed (no unique edges).
2. `afl-tmin` — shrink each surviving seed to the smallest byte
   sequence that still hits its bitmap.

```sh
# Dry-run: produces seeds.cmin/ next to seeds/ for inspection.
bash src/tests/fuzz/minimize-corpus.sh

# After eyeballing seeds.cmin/, swap it in + stage the change.
# (The script never auto-commits; it prints the suggested invocation.)
bash src/tests/fuzz/minimize-corpus.sh --commit
```

If `afl-cmin` / `afl-tmin` are missing the script self-reports and
exits `0` — same convention as `build-afl.sh`.

The minimised corpus is meaningful only when the driver was built
with real instrumentation (route 1 or 2).  Route 3 (black-box) has
no bitmap to minimise against; the script will run but warns and
the reduction will be trivial.

## Status

Phase 13.1: AFL driver wiring landed.  The build script self-reports
"AFL missing" on machines without `afl-fuzz` and exits cleanly; the
13.1.unverified follow-up tracks running the end-to-end build on a
host that has AFL installed.

Phase 13.2: `classify-crash.sh` triage helper landed (8/8 PASS on
the seed corpus, four-bucket synthetic smoke).

Phase 13.3 + 13.4: `fuzz-soak.sh` + `minimize-corpus.sh` landed.
Both self-report on AFL-missing hosts.  No real soak has run yet
(`SOAK_LOG.md` empty); the 13.3.unverified / 13.4.unverified
followups track running them on an AFL-equipped host.
