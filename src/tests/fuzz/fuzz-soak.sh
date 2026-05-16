#!/usr/bin/env bash
# fuzz-soak.sh — Phase 13.3 long-running fuzz wrapper.
#
# Drives a wall-clock-bounded `afl-fuzz` session over the Phase 9.3.1
# differential harness via the route picked by build-afl.sh.  Default
# duration is 24h.  Stops on first divergence (crash or hang) so the
# operator (or a cron job) can hand the finding to classify-crash.sh
# without burning the rest of the wall-clock budget.
#
# Not a CI gate — this is a manual / nightly gate (see README "Soak
# workflow").  Each clean soak appends one row to SOAK_LOG.md to prove
# the cumulative wallclock budget over time.
#
# Usage:
#   bash fuzz-soak.sh [--duration TIME] [--no-stop] [--quiet]
#
#   --duration TIME   Anything `timeout(1)` accepts: 30s, 30m, 2h,
#                     24h (default), 7d.
#   --no-stop         Don't bail on first finding (stress soak).
#                     Default is stop-on-first-divergence.
#   --quiet           Suppress per-poll status lines.
#
# Exit codes:
#   0  Soak completed clean (timeout reached, no findings).
#   1  Setup/pre-flight error (AFL missing, driver build failed, etc.).
#   2  Stopped early on first finding (with --stop-on-first-divergence).
#
# Constraints:
#   * Read-only w.r.t. engine source; only touches files under
#     src/tests/fuzz/findings/ and the SOAK_LOG.md ledger.
#   * Self-reports + exits 0 if AFL is missing — same convention as
#     build-afl.sh.
#
# Cite: README.md "Soak workflow"; build-afl.sh route selection.

set -u  # NB: no -e; we manage failure modes manually.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BIN_DIR="$ROOT_DIR/bin"
DRIVER_BIN="$BIN_DIR/afl-driver"
SEEDS_DIR="$SCRIPT_DIR/seeds"
FINDINGS_DIR="$SCRIPT_DIR/findings"
ROUTE_NOTE="$SCRIPT_DIR/.afl-route"
SOAK_LOG="$SCRIPT_DIR/SOAK_LOG.md"
CLASSIFY="$SCRIPT_DIR/classify-crash.sh"

DURATION="24h"
STOP_ON_FIRST=1
QUIET=0
POLL_INTERVAL="${POLL_INTERVAL:-300}"   # 5 min default

usage() {
  sed -n '2,30p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --duration)              DURATION="$2"; shift 2 ;;
    --duration=*)            DURATION="${1#*=}"; shift ;;
    --no-stop|--no-stop-on-first-divergence)
                             STOP_ON_FIRST=0; shift ;;
    --stop-on-first-divergence)
                             STOP_ON_FIRST=1; shift ;;
    --quiet)                 QUIET=1; shift ;;
    -h|--help)               usage; exit 0 ;;
    *) echo "fuzz-soak: unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

log() { if [ "$QUIET" -eq 0 ]; then printf '[fuzz-soak] %s\n' "$*"; fi; }

# ---- 0. AFL presence check (self-report + exit 0 if missing) ------------
if ! command -v afl-fuzz >/dev/null 2>&1; then
  cat <<EOF
fuzz-soak: afl-fuzz not found on this machine.

  This script is a manual/nightly soak gate; it needs a real AFL
  install.  See src/tests/fuzz/README.md "Installing AFL" for
  instructions.  Self-reporting and exiting 0 (same convention as
  build-afl.sh) so a project-wide harness doesn't fail on hosts
  without AFL.
EOF
  exit 0
fi

# ---- 1. Pre-flight: rebuild driver --------------------------------------
log "pre-flight: refreshing afl-driver via build-afl.sh"
if ! bash "$SCRIPT_DIR/build-afl.sh" >/tmp/fuzz-soak-build.log 2>&1; then
  echo "fuzz-soak: build-afl.sh failed — see /tmp/fuzz-soak-build.log" >&2
  tail -n 20 /tmp/fuzz-soak-build.log >&2 || true
  exit 1
fi

if [ ! -x "$DRIVER_BIN" ]; then
  echo "fuzz-soak: $DRIVER_BIN missing after build (route note: $(cat "$ROUTE_NOTE" 2>/dev/null))" >&2
  exit 1
fi

ROUTE_LINE="$(cat "$ROUTE_NOTE" 2>/dev/null || echo "route unknown")"
ROUTE_NUM="$(echo "$ROUTE_LINE" | grep -oE '\([1-3]\)' | tr -d '()' | head -n1)"
case "$ROUTE_NUM" in
  1) AFL_EXTRA=() ;;
  2) AFL_EXTRA=(-Q) ;;
  3) AFL_EXTRA=(-n) ;;
  *) echo "fuzz-soak: cannot parse route from $ROUTE_NOTE ($ROUTE_LINE)" >&2; exit 1 ;;
esac

mkdir -p "$FINDINGS_DIR"

# ---- 2. Launch afl-fuzz in background, timeout-bounded ------------------
N_SEEDS="$(find "$SEEDS_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"
GIT_SHA="$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
START_EPOCH="$(date +%s)"
START_STAMP="$(date -u +%FT%TZ)"

log "launching: afl-fuzz ${AFL_EXTRA[*]} -i $SEEDS_DIR -o $FINDINGS_DIR -- $DRIVER_BIN"
log "duration target: $DURATION   stop-on-first-divergence: $STOP_ON_FIRST   seeds: $N_SEEDS   route: ${ROUTE_NUM}"

# `timeout` with --foreground so SIGINT can reach afl-fuzz; -k 10 sends
# SIGKILL 10s after SIGTERM if afl-fuzz ignores the polite signal.
( timeout --foreground -k 10 "$DURATION" \
    afl-fuzz "${AFL_EXTRA[@]}" -i "$SEEDS_DIR" -o "$FINDINGS_DIR" \
             -- "$DRIVER_BIN" \
    >/tmp/fuzz-soak-afl.log 2>&1 ) &
AFL_PID=$!

cleanup_afl() {
  if kill -0 "$AFL_PID" 2>/dev/null; then
    log "sending SIGTERM to afl-fuzz pid $AFL_PID"
    kill -TERM "$AFL_PID" 2>/dev/null || true
    # Give it a grace period to flush stats.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$AFL_PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$AFL_PID" 2>/dev/null || true
  fi
  wait "$AFL_PID" 2>/dev/null || true
}
trap 'cleanup_afl' INT TERM

CRASH_DIR="$FINDINGS_DIR/default/crashes"
HANG_DIR="$FINDINGS_DIR/default/hangs"

count_findings() {
  local d="$1" n=0
  if [ -d "$d" ]; then
    # AFL drops a README.txt in crashes/ and hangs/; exclude it.
    n="$(find "$d" -maxdepth 1 -type f ! -name 'README.txt' ! -name '.*' | wc -l | tr -d ' ')"
  fi
  echo "$n"
}

# ---- 3. Poll loop -------------------------------------------------------
RESULT="CLEAN"
N_CRASH=0
N_HANG=0
while kill -0 "$AFL_PID" 2>/dev/null; do
  sleep "$POLL_INTERVAL" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  if ! kill -0 "$AFL_PID" 2>/dev/null; then break; fi
  N_CRASH="$(count_findings "$CRASH_DIR")"
  N_HANG="$(count_findings "$HANG_DIR")"
  now=$(date +%s); elapsed=$((now - START_EPOCH))
  log "t=${elapsed}s  crashes=$N_CRASH  hangs=$N_HANG"
  if [ "$STOP_ON_FIRST" -eq 1 ] && { [ "$N_CRASH" -gt 0 ] || [ "$N_HANG" -gt 0 ]; }; then
    log "first finding detected (crashes=$N_CRASH hangs=$N_HANG) — stopping early"
    cleanup_afl
    RESULT="FOUND-$((N_CRASH + N_HANG))-BUGS"
    break
  fi
done

wait "$AFL_PID" 2>/dev/null
AFL_RC=$?

END_EPOCH="$(date +%s)"
ACTUAL_DURATION=$((END_EPOCH - START_EPOCH))

# Final finding tally — covers the case where AFL exited cleanly at
# wall-clock timeout but slipped a finding into the bucket between
# polls.
N_CRASH="$(count_findings "$CRASH_DIR")"
N_HANG="$(count_findings "$HANG_DIR")"
if [ "$N_CRASH" -gt 0 ] || [ "$N_HANG" -gt 0 ]; then
  RESULT="FOUND-$((N_CRASH + N_HANG))-BUGS"
fi

# ---- 4. Hand-off + ledger row -------------------------------------------
fmt_dur() {
  local s="$1"
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%02ds' $((s/60)) $((s%60))
  elif [ "$s" -lt 86400 ]; then printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
  else printf '%dd%02dh' $((s/86400)) $(((s%86400)/3600))
  fi
}
ACTUAL_FMT="$(fmt_dur "$ACTUAL_DURATION")"

if [ "$RESULT" != "CLEAN" ]; then
  log "running classify-crash.sh over findings"
  if [ -d "$CRASH_DIR" ]; then
    bash "$CLASSIFY" "$CRASH_DIR" || true
  fi
  if [ -d "$HANG_DIR" ]; then
    bash "$CLASSIFY" "$HANG_DIR" || true
  fi
fi

# Append ledger row.  Format documented in SOAK_LOG.md header.
{
  printf '| %s | %s | %s | %d | %s | %s | %s |\n' \
    "$START_STAMP" "$DURATION" "$ACTUAL_FMT" \
    "$N_SEEDS" "${ROUTE_NUM}" "$RESULT" "$GIT_SHA"
} >> "$SOAK_LOG"

cat <<EOF

fuzz-soak summary
  started        : $START_STAMP
  target         : $DURATION
  actual         : $ACTUAL_FMT  (${ACTUAL_DURATION}s)
  seeds          : $N_SEEDS
  route          : ($ROUTE_NUM)
  crashes        : $N_CRASH
  hangs          : $N_HANG
  result         : $RESULT
  git sha        : $GIT_SHA
  afl exit code  : $AFL_RC   (124 = timeout reached cleanly)
  ledger         : $SOAK_LOG
  afl log        : /tmp/fuzz-soak-afl.log
EOF

if [ "$RESULT" = "CLEAN" ]; then
  exit 0
else
  exit 2
fi
