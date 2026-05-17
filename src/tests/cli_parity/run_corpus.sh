#!/usr/bin/env bash
# 10.2 CLI integration parity gate.
#
# For each corpus/*.sql, run the script through BOTH
#   - upstream sqlite3 binary  (UPSTREAM_SQLITE3 env, default
#     /home/bpsa/app/sqlite3/sqlite3 then /usr/bin/sqlite3)
#   - in-tree bin/passqlite3   (LD_LIBRARY_PATH=src/ so libsqlite3.so
#     resolves to the port build)
# capture stdout / stderr / rc, byte-diff stdout AND stderr AND rc.
# Any divergence is a hard failure (rc=1).  pas-soft divergences cited
# in DIVERGENCES.md are skipped via the SOFT_SKIP set below.
#
# Usage:
#   bash src/tests/cli_parity/run_corpus.sh
#
# Honours $UPSTREAM_SQLITE3 to override the upstream binary path.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CORPUS="$HERE/corpus"
PAS_BIN="$REPO/bin/passqlite3"
PAS_LIB="$REPO/src"

UPSTREAM="${UPSTREAM_SQLITE3:-}"
if [ -z "$UPSTREAM" ]; then
  for c in /home/bpsa/app/sqlite3/sqlite3 /usr/local/bin/sqlite3 /usr/bin/sqlite3; do
    if [ -x "$c" ]; then UPSTREAM="$c"; break; fi
  done
fi
if [ -z "$UPSTREAM" ] || [ ! -x "$UPSTREAM" ]; then
  echo "SKIP    run_corpus.sh: upstream sqlite3 binary not found"
  echo "        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable."
  exit 0
fi
if [ ! -x "$PAS_BIN" ]; then
  echo "FAIL    run_corpus.sh: $PAS_BIN missing (build it first)"
  exit 2
fi

echo "Upstream : $UPSTREAM"
echo "Port     : $PAS_BIN"
echo "LD libs  : $PAS_LIB"
echo

# Soft-skip set — scripts citing an open 10.2.divbug.N. Keep one per line.
SOFT_SKIP=$(cat <<'EOF'
sink_mode_switching
EOF
)
is_soft() {
  local b="$1"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ "$b" = "$line" ] && return 0
  done <<< "$SOFT_SKIP"
  return 1
}

pass=0
fail=0
soft=0
total=0

TMP="$(mktemp -d -t pas_cli_parity_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

shopt -s nullglob
for sql in "$CORPUS"/*.sql; do
  total=$((total+1))
  base="$(basename "$sql" .sql)"

  expOut="$TMP/${base}.exp.out"; expErr="$TMP/${base}.exp.err"
  actOut="$TMP/${base}.act.out"; actErr="$TMP/${base}.act.err"

  "$UPSTREAM" :memory: <"$sql" >"$expOut" 2>"$expErr"
  rcExp=$?

  LD_LIBRARY_PATH="$PAS_LIB" "$PAS_BIN" :memory: <"$sql" >"$actOut" 2>"$actErr"
  rcAct=$?

  ok=1
  if [ "$rcExp" != "$rcAct" ]; then ok=0; fi
  if ! cmp -s "$expOut" "$actOut"; then ok=0; fi
  if ! cmp -s "$expErr" "$actErr"; then ok=0; fi

  if [ "$ok" = "1" ]; then
    echo "PASS    $base (rc=$rcAct)"
    pass=$((pass+1))
  elif is_soft "$base"; then
    echo "SOFT    $base (rcExp=$rcExp rcAct=$rcAct) — cited divergence"
    soft=$((soft+1))
  else
    echo "FAIL    $base (rcExp=$rcExp rcAct=$rcAct)"
    if [ "$rcExp" != "$rcAct" ]; then
      echo "  rc:      exp=$rcExp act=$rcAct"
    fi
    if ! cmp -s "$expOut" "$actOut"; then
      echo "  stdout diff (- expected / + actual), first 80 lines:"
      diff -u "$expOut" "$actOut" | sed -n '1,80p' | sed 's/^/    /'
    fi
    if ! cmp -s "$expErr" "$actErr"; then
      echo "  stderr diff (- expected / + actual), first 40 lines:"
      diff -u "$expErr" "$actErr" | sed -n '1,40p' | sed 's/^/    /'
    fi
    fail=$((fail+1))
  fi
done

echo
echo "run_corpus.sh: $pass PASS / $soft SOFT / $fail FAIL  ($total total)"
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
