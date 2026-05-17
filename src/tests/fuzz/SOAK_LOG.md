# AFL soak ledger (Phase 13.3)

Append-only record of `fuzz-soak.sh` runs.  Each invocation appends
one row so we can prove the cumulative wallclock fuzz budget over
time without trusting external CI state.

The ledger is **not** a CI gate.  It's evidence for the manual gate
documented in `README.md` "Soak workflow": before declaring Phase 13
finished, we want some number of CLEAN 24h soaks visible here, each
tied to a git SHA so a reviewer can confirm the runs happened against
the as-shipped engine.

## Columns

| Column         | Meaning                                                  |
|----------------|----------------------------------------------------------|
| date           | UTC ISO-8601 timestamp at session start.                 |
| duration target| `--duration` value as passed (e.g. `24h`, `30m`).        |
| actual         | Wall-clock time the soak actually ran (may be shorter if `--stop-on-first-divergence` fired, or longer than target by the SIGTERM grace window). |
| seeds          | Count of files in `seeds/` at launch.                    |
| route          | Instrumentation route (1 = `afl-as`, 2 = QEMU, 3 = black-box) — read from `.afl-route`. |
| result         | `CLEAN` (no findings) or `FOUND-N-BUGS` (N is crashes+hangs). |
| git SHA        | `git rev-parse --short HEAD` at launch.                  |

## Runs

| date | duration target | actual | seeds | route | result | git sha |
|------|-----------------|--------|-------|-------|--------|---------|
<!-- no soak runs yet — fuzz-soak.sh appends rows below this marker -->
