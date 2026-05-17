#!/usr/bin/env bash
# build-afl.sh — Phase 13.1 build script for the AFL wrapper around
# TestFuzzDiff.  Picks an instrumentation route per tasklist.md Phase 13
# header (lines ~1699-1728):
#
#   (1) afl-as assembler wedge — fpc -al -Aas -FD<dir>             (~2x)
#   (2) QEMU mode  — build vanilla, run with afl-fuzz -Q           (~5-10x)
#   (3) Black-box — build vanilla, run with afl-fuzz -n            (last resort)
#
# If afl-fuzz isn't installed at all, self-report and exit 0 so the
# project-wide build doesn't fail on machines that lack AFL.

set -u  # NB: not -e — we want to chain fallbacks on failure.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../.."                  # pas-sqlite3/src/
TESTS_DIR="$SCRIPT_DIR/.."                   # pas-sqlite3/src/tests/
ROOT_DIR="$SRC_DIR/.."                       # pas-sqlite3/
BIN_DIR="$ROOT_DIR/bin"

DRIVER_SRC="$SCRIPT_DIR/afl-driver.pas"
DRIVER_BIN="$BIN_DIR/afl-driver"
ROUTE_NOTE="$SCRIPT_DIR/.afl-route"

mkdir -p "$BIN_DIR"

# ---- 0. AFL presence check ----------------------------------------------
if ! command -v afl-fuzz >/dev/null 2>&1; then
  cat <<EOF
afl-driver: afl-fuzz not found on this machine.

  AFL is not installed.  Install with one of:
    apt install afl++              # Debian / Ubuntu / Mint
    dnf install american-fuzzy-lop # Fedora / RHEL
    pacman -S afl++                # Arch
  Or build from source: https://github.com/AFLplusplus/AFLplusplus

  Skipping instrumentation route selection.  The afl-driver source
  itself can still be compiled in route-3 (black-box) mode for
  verification; pass FORCE_BUILD=1 to do so.
EOF
  echo "self-report: AFL missing, no route selected" > "$ROUTE_NOTE"
  if [ "${FORCE_BUILD:-0}" = "1" ]; then
    echo "FORCE_BUILD=1 — compiling driver without instrumentation."
  else
    exit 0
  fi
fi

# The driver doesn't actually use any of the engine units, so FPC defaults
# the ELF interpreter to /lib/ld64.so.1 (FPC's historical baseline) which
# doesn't exist on modern glibc systems.  Force the real interpreter.
DYNLINKER="$(readlink -f /lib64/ld-linux-x86-64.so.2 2>/dev/null \
             || readlink -f /lib/ld-linux-x86-64.so.2 2>/dev/null \
             || echo /lib64/ld-linux-x86-64.so.2)"
FPC_FLAGS="-O2 -Fu$SRC_DIR -Fu$TESTS_DIR -Fi$SRC_DIR -FE$BIN_DIR -Fl$SRC_DIR -k-lm -k-lz -k--dynamic-linker=$DYNLINKER"

try_compile() {
  # $@ = extra fpc flags
  fpc $FPC_FLAGS "$@" "$DRIVER_SRC" -oafl-driver
}

ROUTE=""
ROUTE_DESC=""

# ---- 1. Route (1): afl-as assembler wedge --------------------------------
if command -v afl-as >/dev/null 2>&1; then
  AFL_BIN_DIR="$(dirname "$(command -v afl-as)")"
  echo "afl-driver: attempting route (1) — afl-as wedge from $AFL_BIN_DIR"
  rm -f "$DRIVER_BIN"
  if try_compile -al -Aas -FD"$AFL_BIN_DIR" 2>/tmp/afl-driver-route1.log; then
    if [ -x "$DRIVER_BIN" ]; then
      # Smoke-verify: feed empty stdin.  Driver should exit non-fatal.
      if echo -n "" | "$DRIVER_BIN" >/dev/null 2>&1; rc=$?; [ "$rc" -lt 128 ]; then
        ROUTE="1"
        ROUTE_DESC="afl-as assembler wedge (fpc -al -Aas -FD$AFL_BIN_DIR); ~2x slowdown"
      else
        echo "afl-driver: route (1) compiled but smoke failed (rc=$rc); falling through"
      fi
    fi
  else
    echo "afl-driver: route (1) compile failed (see /tmp/afl-driver-route1.log) — likely FPC GAS dialect / afl-as version mismatch.  Falling through."
  fi
else
  echo "afl-driver: route (1) unavailable — afl-as not in PATH"
fi

# ---- 2. Route (2): QEMU mode --------------------------------------------
if [ -z "$ROUTE" ]; then
  if command -v afl-qemu-trace >/dev/null 2>&1 || [ -x "$(command -v afl-fuzz 2>/dev/null)" ]; then
    # afl-fuzz -Q needs afl-qemu-trace; some packages ship it separately
    # (afl++-qemu).  If only afl-fuzz is around, try a vanilla build and
    # leave the operator to install the qemu helper.
    echo "afl-driver: attempting route (2) — vanilla build for afl-fuzz -Q"
    rm -f "$DRIVER_BIN"
    if try_compile 2>/tmp/afl-driver-route2.log; then
      if [ -x "$DRIVER_BIN" ]; then
        ROUTE="2"
        if command -v afl-qemu-trace >/dev/null 2>&1; then
          ROUTE_DESC="QEMU mode (afl-fuzz -Q); ~5-10x slowdown"
        else
          ROUTE_DESC="QEMU mode (afl-fuzz -Q); ~5-10x slowdown.  WARNING: afl-qemu-trace not detected — install the afl++-qemu helper package before running -Q."
        fi
      fi
    fi
  fi
fi

# ---- 3. Route (3): black-box --------------------------------------------
if [ -z "$ROUTE" ]; then
  echo "afl-driver: falling back to route (3) — black-box afl-fuzz -n"
  rm -f "$DRIVER_BIN"
  if try_compile 2>/tmp/afl-driver-route3.log; then
    if [ -x "$DRIVER_BIN" ]; then
      ROUTE="3"
      ROUTE_DESC="Black-box (afl-fuzz -n); no instrumentation, dumb mutation only"
    fi
  fi
fi

if [ -z "$ROUTE" ]; then
  echo "afl-driver: ERROR — no route succeeded."
  echo "  Route 1 log: /tmp/afl-driver-route1.log"
  echo "  Route 2 log: /tmp/afl-driver-route2.log"
  echo "  Route 3 log: /tmp/afl-driver-route3.log"
  exit 1
fi

echo "route ($ROUTE): $ROUTE_DESC" > "$ROUTE_NOTE"

# Strip transient *.o / *.s / *.ppu the wedge leaves behind.
find "$SCRIPT_DIR" -maxdepth 1 \( -name '*.o' -o -name '*.ppu' -o -name '*.s' -o -name '*.compiled' \) -delete

cat <<EOF

afl-driver: build OK
  binary    : $DRIVER_BIN
  route     : ($ROUTE) $ROUTE_DESC
  seeds dir : $SCRIPT_DIR/seeds
  harness   : $BIN_DIR/TestFuzzDiff  (Phase 9.3.1)

Run a fuzzing session:
  mkdir -p $SCRIPT_DIR/findings
EOF
case "$ROUTE" in
  1) echo "  afl-fuzz -i $SCRIPT_DIR/seeds -o $SCRIPT_DIR/findings -- $DRIVER_BIN" ;;
  2) echo "  afl-fuzz -Q -i $SCRIPT_DIR/seeds -o $SCRIPT_DIR/findings -- $DRIVER_BIN" ;;
  3) echo "  afl-fuzz -n -i $SCRIPT_DIR/seeds -o $SCRIPT_DIR/findings -- $DRIVER_BIN" ;;
esac
echo
