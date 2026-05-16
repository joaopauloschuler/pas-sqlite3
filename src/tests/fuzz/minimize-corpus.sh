#!/usr/bin/env bash
# minimize-corpus.sh — Phase 13.4 coverage-guided seed minimisation.
#
# Two-step pipeline over src/tests/fuzz/seeds/:
#
#   1. afl-cmin   — drop seeds whose AFL bitmap is a strict subset of
#                   another seed (i.e. they don't add edges).
#   2. afl-tmin   — shrink each surviving seed to the minimum byte
#                   sequence that still hits the same bitmap.
#
# Output lands in src/tests/fuzz/seeds.cmin/ for review.  Pass --commit
# to swap it in over seeds/ and stage the change; the script prints the
# `git commit` command for the user to execute (we don't auto-commit).
#
# Usage:
#   bash minimize-corpus.sh [--commit] [--quiet]
#
# Constraints:
#   * Read-only w.r.t. engine source; only touches files under
#     src/tests/fuzz/seeds*.
#   * Self-reports + exits 0 if afl-cmin/afl-tmin are missing — same
#     convention as build-afl.sh / fuzz-soak.sh.
#
# Cite: README.md "Seed minimisation"; build-afl.sh route selection.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BIN_DIR="$ROOT_DIR/bin"
DRIVER_BIN="$BIN_DIR/afl-driver"
SEEDS_DIR="$SCRIPT_DIR/seeds"
CMIN_DIR="$SCRIPT_DIR/seeds.cmin"
TMIN_TMP="$SCRIPT_DIR/.seeds.tmin.tmp"
ROUTE_NOTE="$SCRIPT_DIR/.afl-route"

COMMIT=0
QUIET=0

usage() { sed -n '2,25p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --commit)   COMMIT=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "minimize-corpus: unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

log() { if [ "$QUIET" -eq 0 ]; then printf '[minimize] %s\n' "$*"; fi; }

# ---- 0. AFL tooling presence --------------------------------------------
MISSING=""
for t in afl-cmin afl-tmin; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
  cat <<EOF
minimize-corpus: required tools missing:$MISSING

  Coverage-guided seed minimisation needs both afl-cmin and afl-tmin.
  Install AFL++ first — see src/tests/fuzz/README.md "Installing AFL".
  Self-reporting and exiting 0 (same convention as build-afl.sh) so a
  project-wide harness doesn't fail on hosts without AFL.
EOF
  exit 0
fi

# ---- 1. Pre-flight: refresh driver --------------------------------------
log "pre-flight: refreshing afl-driver via build-afl.sh"
if ! bash "$SCRIPT_DIR/build-afl.sh" >/tmp/minimize-build.log 2>&1; then
  echo "minimize-corpus: build-afl.sh failed — see /tmp/minimize-build.log" >&2
  tail -n 20 /tmp/minimize-build.log >&2 || true
  exit 1
fi
if [ ! -x "$DRIVER_BIN" ]; then
  echo "minimize-corpus: $DRIVER_BIN missing after build" >&2
  exit 1
fi

ROUTE_NUM="$(grep -oE '\([1-3]\)' "$ROUTE_NOTE" 2>/dev/null | tr -d '()' | head -n1)"
case "$ROUTE_NUM" in
  1) AFL_EXTRA=() ;;
  2) AFL_EXTRA=(-Q) ;;
  3) AFL_EXTRA=(-n)
     log "WARNING: route 3 (black-box) — afl-cmin/tmin have no bitmap to minimise against."
     log "         The pipeline will still run but reduction will be trivial.  Install"
     log "         afl-as or afl++-qemu for meaningful seed minimisation."
     ;;
  *) echo "minimize-corpus: cannot parse route from $ROUTE_NOTE" >&2; exit 1 ;;
esac

# ---- 2. Measure before --------------------------------------------------
before_count="$(find "$SEEDS_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"
before_bytes="$(find "$SEEDS_DIR" -maxdepth 1 -type f -printf '%s\n' \
                 | awk 'BEGIN{s=0}{s+=$1}END{print s}')"
log "before: $before_count seeds, $before_bytes bytes"

rm -rf "$CMIN_DIR" "$TMIN_TMP"
mkdir -p "$CMIN_DIR" "$TMIN_TMP"

# ---- 3. afl-cmin --------------------------------------------------------
log "afl-cmin: pruning seeds that don't add edges"
if ! afl-cmin "${AFL_EXTRA[@]}" -i "$SEEDS_DIR" -o "$TMIN_TMP" \
       -- "$DRIVER_BIN" >/tmp/minimize-cmin.log 2>&1; then
  echo "minimize-corpus: afl-cmin failed — see /tmp/minimize-cmin.log" >&2
  tail -n 20 /tmp/minimize-cmin.log >&2 || true
  exit 1
fi

cmin_count="$(find "$TMIN_TMP" -maxdepth 1 -type f | wc -l | tr -d ' ')"
log "afl-cmin: kept $cmin_count / $before_count seeds"

# ---- 4. afl-tmin (per surviving seed) -----------------------------------
log "afl-tmin: shrinking each surviving seed"
i=0
for f in "$TMIN_TMP"/*; do
  [ -f "$f" ] || continue
  i=$((i + 1))
  name="$(basename "$f")"
  out="$CMIN_DIR/$name"
  if afl-tmin "${AFL_EXTRA[@]}" -i "$f" -o "$out" \
       -- "$DRIVER_BIN" >>/tmp/minimize-tmin.log 2>&1; then
    log "  [$i/$cmin_count] $name : $(stat -c%s "$f") → $(stat -c%s "$out") bytes"
  else
    # tmin failure: preserve the cmin-survivor as-is.
    cp "$f" "$out"
    log "  [$i/$cmin_count] $name : tmin failed; kept cmin output as-is"
  fi
done

rm -rf "$TMIN_TMP"

# ---- 5. Measure after + diff --------------------------------------------
after_count="$(find "$CMIN_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"
after_bytes="$(find "$CMIN_DIR" -maxdepth 1 -type f -printf '%s\n' \
                | awk 'BEGIN{s=0}{s+=$1}END{print s}')"

cat <<EOF

minimize-corpus summary
  before : $before_count seeds, $before_bytes bytes
  after  : $after_count seeds, $after_bytes bytes
  delta  : $((before_count - after_count)) seeds dropped, \
$((before_bytes - after_bytes)) bytes saved
  output : $CMIN_DIR
EOF

# ---- 6. --commit hand-off -----------------------------------------------
if [ "$COMMIT" -eq 1 ]; then
  if [ "$after_count" -eq 0 ]; then
    echo "minimize-corpus: refusing --commit — after-count is 0 (something went wrong)" >&2
    exit 1
  fi
  log "--commit: swapping seeds.cmin/ over seeds/ and staging"
  rm -rf "$SEEDS_DIR.bak"
  mv "$SEEDS_DIR" "$SEEDS_DIR.bak"
  mv "$CMIN_DIR" "$SEEDS_DIR"
  ( cd "$ROOT_DIR" && git add -A "src/tests/fuzz/seeds" )
  cat <<EOF

Staged.  Review with:
  cd $ROOT_DIR && git status src/tests/fuzz/seeds
  cd $ROOT_DIR && git diff --cached --stat src/tests/fuzz/seeds

Backup of original seeds in: $SEEDS_DIR.bak  (delete once you're happy).

Commit when ready:
  cd $ROOT_DIR && git commit -m "13.4: minimise AFL seed corpus ($before_count→$after_count, $before_bytes→$after_bytes B)"
EOF
else
  cat <<EOF

Re-run with --commit to swap seeds.cmin/ over seeds/ and stage the
change.  (The script will print the suggested git commit invocation;
it never auto-commits.)
EOF
fi

exit 0
