#!/usr/bin/env bash
# classify-crash.sh — Phase 13.2 crash-vs-divergence triage helper.
#
# Walks one or more AFL-style "interesting" input files through the
# Phase 9.3.1 differential harness (bin/TestFuzzDiff) and sorts each
# input into one of four buckets under src/tests/fuzz/crashes/:
#
#   pas-crash/    Pascal port SIGSEGV'd or hit an FPC Runtime error.
#   c-crash/      C oracle (libsqlite3.so) died on signal.
#   divergence/   Both backends completed but at least one channel
#                 (stdout / stderr / rc / db-blob) differs.
#   timeout/      Harness exceeded TIMEOUT_S wall-clock (default 30s).
#
# Inputs that PASS (rc=0, all four channels byte-identical) are
# silently skipped — they don't belong in any bucket.  Malformed
# dbsqlfuzz frames (rc=3) and CLI/IO errors (rc=1) are also skipped
# with a stderr note; they don't represent a defect to triage.
#
# Usage:
#   bash classify-crash.sh [--copy] [--quiet] <input | dir> [...]
#
# Defaults to src/tests/fuzz/findings/default/crashes/ (the AFL
# crash-bucket convention) when called with no arguments.
#
# Crash-side disambiguation strategy:
#   TestFuzzDiff runs both oracles inside one process (C first, then
#   Pas — see TestFuzzDiff.pas:RunBoth).  When signal-death happens
#   we can't tell from rc alone which oracle was active, so we
#   heuristically inspect stderr:
#     * stderr contains "Runtime error"  → pas-crash (FPC's RTL
#       panic preamble — only the Pascal port emits this).
#     * stderr is empty / only contains the harness preamble → assume
#       the still-running oracle was Pas (C oracle is sqlite3.so which
#       crashes ~never in practice; default to the higher-prior bucket).
#       This is a heuristic — override by inspecting <input>.meta.txt.
#
# Constraints:
#   * Pure bash + POSIX utils — no AFL dependency.
#   * Read-only w.r.t. engine source; only touches files under
#     src/tests/fuzz/crashes/ and a per-invocation tmp scratch dir.
#
# Cite: README.md "Triage workflow"; afl-driver.pas exit-code table.

set -u  # NB: no -e; we want to keep going across batches of inputs.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FUZZ_DIR="$SCRIPT_DIR"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Allow PAS_FUZZDIFF_BIN override (same env knob afl-driver.pas honours).
HARNESS="${PAS_FUZZDIFF_BIN:-$ROOT_DIR/bin/TestFuzzDiff}"

TIMEOUT_S="${TIMEOUT_S:-30}"

CRASHES_DIR="$FUZZ_DIR/crashes"
BUCKET_PAS="$CRASHES_DIR/pas-crash"
BUCKET_C="$CRASHES_DIR/c-crash"
BUCKET_DIV="$CRASHES_DIR/divergence"
BUCKET_TO="$CRASHES_DIR/timeout"

MODE="move"     # or "copy"
QUIET=0

usage() {
  cat <<EOF
classify-crash.sh — Phase 13.2 triage helper

Usage:
  bash $0 [--copy] [--quiet] <input | dir> [...]

Defaults the input list to src/tests/fuzz/findings/default/crashes/
(AFL convention) when no arguments are given.

Buckets land under:
  $CRASHES_DIR/{pas-crash,c-crash,divergence,timeout}/

Env knobs:
  PAS_FUZZDIFF_BIN  override path to bin/TestFuzzDiff
  TIMEOUT_S         per-input wall-clock budget (default 30)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --copy)  MODE="copy"; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  DEFAULT_DIR="$FUZZ_DIR/findings/default/crashes"
  if [ -d "$DEFAULT_DIR" ]; then
    set -- "$DEFAULT_DIR"
  else
    echo "classify-crash: no inputs given and $DEFAULT_DIR not present" >&2
    usage
    exit 1
  fi
fi

if [ ! -x "$HARNESS" ]; then
  echo "classify-crash: harness not executable at $HARNESS" >&2
  echo "  Build first: bash $ROOT_DIR/src/tests/build_fuzzdiff.sh (or src/tests/build.sh)" >&2
  exit 1
fi

mkdir -p "$BUCKET_PAS" "$BUCKET_C" "$BUCKET_DIV" "$BUCKET_TO"

# Flatten arguments into a file list.
INPUTS=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    while IFS= read -r -d '' f; do INPUTS+=("$f"); done < \
      <(find "$arg" -maxdepth 1 -type f -print0)
  elif [ -f "$arg" ]; then
    INPUTS+=("$arg")
  else
    echo "classify-crash: skipping non-existent input $arg" >&2
  fi
done

if [ "${#INPUTS[@]}" -eq 0 ]; then
  echo "classify-crash: input list empty after expansion" >&2
  exit 0
fi

TMP_DIR="$(mktemp -d /tmp/classify-crash.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  if [ "$QUIET" -eq 0 ]; then printf '%s\n' "$*"; fi
}

# Extract per-channel divergence info from stderr.  Returns lines like:
#   stdout c_len=X pas_len=Y
#   rc c=A pas=B
parse_diverge() {
  local errfile="$1"
  grep -E '^DIVERGE channel=' "$errfile" 2>/dev/null || true
}

# Find the first differing byte offset between two strings, if both
# logged on stderr.  We only have hex-prefix snippets in TestFuzzDiff's
# stderr (HexHead, first 64 bytes), so this is a best-effort hint.
first_diff_hint() {
  local errfile="$1"
  awk '
    /^DIVERGE channel=/ { chan=$0; next }
    /^  c   = /         { c=$0 }
    /^  pas = / {
      pas=$0
      if (c != "" && chan != "") {
        printf "  %s\n    %s\n    %s\n", chan, c, pas
        chan=""; c=""
      }
    }
  ' "$errfile" 2>/dev/null
}

place_file() {
  local src="$1" dest_dir="$2"
  local base
  base="$(basename "$src")"
  local dst="$dest_dir/$base"
  # Avoid clobbering: append .N if the bucket already has a same-named
  # input from a different source path.
  if [ -e "$dst" ]; then
    local n=1
    while [ -e "${dst}.${n}" ]; do n=$((n+1)); done
    dst="${dst}.${n}"
  fi
  if [ "$MODE" = "copy" ]; then
    cp "$src" "$dst"
  else
    mv "$src" "$dst"
  fi
  printf '%s' "$dst"
}

write_meta() {
  local dst="$1" bucket="$2" rc="$3" signal="$4" \
        orig="$5" stderr_file="$6" elapsed="$7" \
        last_err side
  if [ -s "$stderr_file" ]; then
    last_err="$(tail -n 1 "$stderr_file" 2>/dev/null | cut -c1-200)"
  else
    last_err=""
  fi
  case "$bucket" in
    pas-crash) side="pascal port" ;;
    c-crash)   side="c oracle (libsqlite3.so)" ;;
    divergence) side="both ran to completion" ;;
    timeout)   side="killed after ${TIMEOUT_S}s" ;;
    *)         side="unknown" ;;
  esac
  {
    echo "classification: $bucket"
    echo "original-path: $orig"
    echo "harness: $HARNESS"
    echo "harness-rc: $rc"
    echo "harness-signal: $signal"
    echo "wall-clock-s: $elapsed"
    echo "side: $side"
    echo "timestamp-utc: $(date -u +%FT%TZ)"
    echo "last-stderr-line: $last_err"
    if [ "$bucket" = "divergence" ]; then
      echo "diverged-channels:"
      parse_diverge "$stderr_file" | sed 's/^/  /'
      echo "first-diff-hints:"
      first_diff_hint "$stderr_file"
    fi
    echo "--- full stderr (first 4 KiB) ---"
    head -c 4096 "$stderr_file" 2>/dev/null || true
  } > "${dst}.meta.txt"
}

declare -i n_total=0 n_pass=0 n_pas=0 n_c=0 n_div=0 n_to=0 n_skip=0

for input in "${INPUTS[@]}"; do
  n_total=$((n_total + 1))
  base="$(basename "$input")"
  out_log="$TMP_DIR/${base}.out"
  err_log="$TMP_DIR/${base}.err"

  t_start=$(date +%s)
  # Plain `timeout(1)` returns rc=124 on its own SIGTERM kill, and
  # passes child signal-death through as rc=128+N — which is exactly
  # what we need to distinguish a wall-clock kill from a real crash.
  # (NOTE: do NOT add --preserve-status here; that maps the timeout
  # kill to 128+15, indistinguishable from a child SIGTERM.)
  timeout -k 2 "${TIMEOUT_S}" \
    "$HARNESS" "$input" >"$out_log" 2>"$err_log"
  rc=$?
  t_end=$(date +%s)
  elapsed=$((t_end - t_start))

  signal=""
  if [ "$rc" -ge 128 ] && [ "$rc" -lt 165 ]; then
    signal=$((rc - 128))
  fi

  case "$rc" in
    0)
      n_pass=$((n_pass + 1))
      log "PASS    $base (rc=0)"
      continue
      ;;
    1|3)
      n_skip=$((n_skip + 1))
      log "SKIP    $base (rc=$rc — I/O or malformed dbsqlfuzz frame)"
      continue
      ;;
    124)
      # timeout(1) sends SIGTERM (124) on expiry.
      n_to=$((n_to + 1))
      dst="$(place_file "$input" "$BUCKET_TO")"
      write_meta "$dst" "timeout" "$rc" "TERM" \
                 "$input" "$err_log" "$elapsed"
      log "TIMEOUT $base → $dst"
      ;;
    2)
      n_div=$((n_div + 1))
      dst="$(place_file "$input" "$BUCKET_DIV")"
      write_meta "$dst" "divergence" "$rc" "" \
                 "$input" "$err_log" "$elapsed"
      log "DIVERGE $base → $dst"
      ;;
    *)
      if [ "$rc" -ge 128 ]; then
        # Signal-death — heuristically pick the side.  FPC RTL prints
        # "Runtime error <n> at <addr>" on uncaught Pascal exceptions;
        # libsqlite3.so SIGSEGV produces no stderr.
        # FPC's RTL prints "Runtime error <n> at <addr>" + a backtrace
        # on any uncaught Pascal exception / SIGSEGV inside Pascal code
        # (default SysUtils install hooks SIGSEGV → RunError 216).
        # libsqlite3.so's bare SIGSEGV produces nothing on stderr.
        # Therefore: stderr has FPC markers → pas-crash; stderr is
        # silent (only the harness preamble was printed before death)
        # → c-crash.  Override by inspecting <input>.meta.txt if the
        # heuristic misfires.
        if grep -q -E 'Runtime error|RunError|EAccessViolation|External: SIG|An unhandled exception' "$err_log" 2>/dev/null; then
          bucket="pas-crash"; bucket_dir="$BUCKET_PAS"
        else
          bucket="c-crash"; bucket_dir="$BUCKET_C"
        fi
        dst="$(place_file "$input" "$bucket_dir")"
        write_meta "$dst" "$bucket" "$rc" "$signal" \
                   "$input" "$err_log" "$elapsed"
        if [ "$bucket" = "pas-crash" ]; then n_pas=$((n_pas + 1));
        else n_c=$((n_c + 1)); fi
        log "CRASH   $base (sig=$signal) → $dst [$bucket]"
      else
        # Unexpected rc — bucket with crashes as a generic crash and
        # flag in meta for review.
        n_skip=$((n_skip + 1))
        log "SKIP    $base (rc=$rc — unexpected; stderr:" \
            "$(tail -n 1 "$err_log" 2>/dev/null))"
      fi
      ;;
  esac
done

cat <<EOF

classify-crash summary
  inputs scanned : $n_total
  PASS           : $n_pass  (no bucket)
  pas-crash      : $n_pas  → $BUCKET_PAS
  c-crash        : $n_c  → $BUCKET_C
  divergence     : $n_div  → $BUCKET_DIV
  timeout        : $n_to  → $BUCKET_TO
  skipped        : $n_skip  (rc 1/3/unexpected — not a triage bucket)
EOF

# Non-zero exit if anything bucketed — useful for CI gating.
total_bucketed=$((n_pas + n_c + n_div + n_to))
if [ "$total_bucketed" -gt 0 ]; then exit 2; fi
exit 0
