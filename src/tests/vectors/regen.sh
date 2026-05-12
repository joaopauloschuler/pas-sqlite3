#!/usr/bin/env bash
# regen.sh — tasklist 9.2.5 vector deterministic-rebuild gate.
#
# Walk every *.sql under this directory, run it through the C
# reference shell (../../../sqlite3/sqlite3), and `cmp` the
# regenerated .db against the committed blob.  Any mismatch is a
# hard failure (rc != 0).  Vectors flagged [SKIP] in MANIFEST.txt
# (currently fts5.sql and rtree.sql) are skipped gracefully.
#
# Reference oracle: ../sqlite3/ (the original C tree).  We never
# use the Pascal port for vector regen — the port is the device
# under test, not the source of truth.

set -u
set -o pipefail

VEC_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$VEC_DIR/../../.." && pwd)"
ORACLE="$REPO_ROOT/../sqlite3/sqlite3"

# Vectors whose .db is intentionally NOT committed (extensions not
# ported yet).  Keep in sync with MANIFEST.txt [SKIP] rows.
SKIP_LIST=("fts5" "rtree")

# Vectors where the committed .db predates the current oracle and the
# byte layout differs (sqlite_version_number stamp at bytes 96..99
# always; for multi-page tables the cell packing also drifted between
# 3.45.x and 3.53.x).  For these we fall back to a "schema-equivalence"
# check via the C oracle: rebuild from .sql, then verify schema +
# row-by-row content match the committed blob.  Per Phase 9.2.1 the
# committed blobs are left untouched.  Keep in sync with MANIFEST.txt
# [~] rows.
EQUIV_LIST=("simple" "multipage")

is_skipped() {
  local name="$1"
  local s
  for s in "${SKIP_LIST[@]}"; do
    if [ "$name" = "$s" ]; then
      return 0
    fi
  done
  return 1
}

is_equiv_only() {
  local name="$1"
  local s
  for s in "${EQUIV_LIST[@]}"; do
    if [ "$name" = "$s" ]; then
      return 0
    fi
  done
  return 1
}

# Schema + data equivalence check via the C oracle: dump both blobs
# with `.dump` and diff the resulting SQL.  Returns 0 on match.  Used
# for legacy vectors whose on-disk byte layout drifted between SQLite
# versions (see EQUIV_LIST commentary).
equiv_db() {
  local name="$1" actual="$2" expected="$3"
  local da db
  da="$TMPDIR/$name.actual.dump"
  db="$TMPDIR/$name.expected.dump"
  "$ORACLE" "$actual"   ".dump" > "$da" 2>/dev/null || return 1
  "$ORACLE" "$expected" ".dump" > "$db" 2>/dev/null || return 1
  diff -q "$da" "$db" >/dev/null
}

if [ ! -x "$ORACLE" ]; then
  echo "regen.sh: ERROR — C oracle not found at $ORACLE" >&2
  echo "  Build it via the upstream tree (../sqlite3/) before running this script." >&2
  exit 2
fi

ORACLE_VER="$("$ORACLE" --version 2>/dev/null | awk '{print $1}')"
echo "regen.sh: oracle = $ORACLE ($ORACLE_VER)"

TMPDIR="$(mktemp -d -t pas-sqlite3-vectors-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

rc=0
ok=0
skipped=0
mismatch=()

shopt -s nullglob
for sql in "$VEC_DIR"/*.sql; do
  name="$(basename "$sql" .sql)"
  expected="$VEC_DIR/$name.db"

  if is_skipped "$name"; then
    echo "  SKIP   $name (extension not ported; .db intentionally absent)"
    skipped=$((skipped + 1))
    continue
  fi

  if [ ! -f "$expected" ]; then
    echo "  FAIL   $name (no committed .db blob — neither generated nor in SKIP_LIST)"
    rc=1
    mismatch+=("$name (missing committed blob)")
    continue
  fi

  out="$TMPDIR/$name.db"
  rm -f "$out" "$out-wal" "$out-shm"
  if ! "$ORACLE" "$out" < "$sql" >"$TMPDIR/$name.stdout" 2>"$TMPDIR/$name.stderr"; then
    echo "  FAIL   $name (oracle non-zero exit; stderr below)"
    sed 's/^/         | /' "$TMPDIR/$name.stderr" >&2
    rc=1
    mismatch+=("$name (oracle error)")
    continue
  fi
  # Drop sidecars so the .db comparison is clean.  The script may
  # produce a -wal sidecar (e.g. wal.sql), but we only commit the
  # main .db — the sidecar carries a random salt and is not
  # reproducible.  See MANIFEST.txt notes on wal.db.
  rm -f "$out-wal" "$out-shm"

  if is_equiv_only "$name"; then
    if equiv_db "$name" "$out" "$expected"; then
      echo "  OK~    $name (.dump-equivalent; legacy blob vintage, see MANIFEST [~])"
      ok=$((ok + 1))
    else
      echo "  FAIL   $name (.dump diff between regenerated and committed blob)"
      diff "$TMPDIR/$name.actual.dump" "$TMPDIR/$name.expected.dump" 2>&1 | head -20 | sed 's/^/         | /' >&2
      rc=1
      mismatch+=("$name (.dump differs)")
    fi
    continue
  fi

  if cmp -s "$out" "$expected"; then
    echo "  OK     $name"
    ok=$((ok + 1))
  else
    echo "  FAIL   $name (byte mismatch vs committed blob)"
    sz_a="$(stat -c %s "$expected" 2>/dev/null || echo ?)"
    sz_b="$(stat -c %s "$out" 2>/dev/null || echo ?)"
    echo "         committed=$sz_a bytes  regenerated=$sz_b bytes"
    diff_off="$(cmp "$out" "$expected" 2>&1 | head -1)"
    echo "         $diff_off"
    rc=1
    mismatch+=("$name")
  fi
done

echo
echo "regen.sh: $ok OK, $skipped skipped, ${#mismatch[@]} mismatch"
if [ "$rc" -ne 0 ]; then
  echo "regen.sh: FAILED — committed vectors are NOT reproducible from .sql." >&2
  for m in "${mismatch[@]}"; do
    echo "  - $m" >&2
  done
fi
exit $rc
