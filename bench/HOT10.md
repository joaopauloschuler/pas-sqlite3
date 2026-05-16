# HOT10 — Top hot functions in pas-sqlite3 (Phase 12.1)

**Date:** 2026-05-16
**Workload:** `bin/passpeedtest1 --testset main --size 1`
**Backend:** Pascal port (passqlite3*.pas → bin/passpeedtest1, FPC -gl -gw3)
**Profiler:** `valgrind --tool=callgrind` (perf was unavailable —
`/proc/sys/kernel/perf_event_paranoid = 4`, no CAP_PERFMON, no sudo,
`perf record` returns *"Access to performance monitoring and
observability operations is limited"*).  Callgrind delivers
instruction-count self-time which is the requested signal.
**Command:** `PROFILE_SIZE=1 PROFILE_TESTSET=main bash bench/profile_callgrind.sh`
**Raw report:** `callgrind_annotate --threshold=99.9 --auto=no bench/callgrind.out`
**Totals:** 248,304,740 Ir (instruction refs) across the full
testset 100…990; wall time 4.110 s under callgrind.

Self-time ranking (instruction refs).  Pure-libc/runtime entries
(memcpy/Move, FillChar, _int_malloc, pthread_mutex_*, FPC
unicodestring helpers) are **not** scored as top-10 hits — they are
called by every Pascal routine — but each is attributed to its
nearest Pascal caller in the *opportunity* column.

---

## Top 10 by self time

### 1. `sqlite3VdbeExec` — 17.94 %
- **File:line:** `src/passqlite3vdbe.pas:7605` (implementation;
  forward at line 1838).
- **What it does:** The VDBE bytecode interpreter — one giant
  `case op of` over OP_* covering every opcode the planner emits.
- **Port status:** Honest port of `vdbe.c:sqlite3VdbeExec`.
  *Opportunity:* exactly the case 12.3 was written for —
  threaded-dispatch (`{$GOTO ON}` jump table indexed by opcode).
  Secondary opportunity: split the hot `OP_Column`, `OP_Next`,
  `OP_Goto`, `OP_Integer`, `OP_AggStep` arms into separate
  `inline` helpers so the outer dispatch loop stays cache-warm.
  Note the FPC restriction: any `asm` block inside the case
  forbids inlining the *whole* function, but per-arm helpers
  bypass that.

### 2. `sqlite3VdbeRecordCompare` — 8.70 %
- **File:line:** `src/passqlite3btree.pas:3188` (forward
  `passqlite3btree.pas:529`; second copy lives in
  `passqlite3vdbe.pas:2337`).  *Note*: the btree-side definition
  is the one the profiler hits, called from
  `sqlite3BtreeIndexMoveto`.
- **What it does:** Per-cell record-vs-key comparator for index
  seeks; decodes serial types, dispatches int / real / text /
  blob comparisons.
- **Port status:** Faithful port of `vdbeaux.c:sqlite3VdbeRecordCompare`.
  *Opportunity:* C uses a function pointer chosen at unpack time
  (`xRecordCompare`) that specialises to the int-key fast path
  (`vdbeRecordCompareInt`) and string-key fast path
  (`vdbeRecordCompareString`).  The Pascal side appears to take
  the generic path for everything — wiring the specialisation
  would cut this in ~half on integer-keyed indexes (testset
  160/161/410).  Sub-target for **12.2.candidate.2**.

### 3. `System.Move` — 5.05 %
- **File:line:** FPC RTL (`???`).  Top Pascal callers (from
  callgrind back-trace, not annotated here): `insertCellFast`,
  `freeSpace`, `fillInCell`, `sqlite3VdbeMemGrow`,
  `sqlite3VdbeSerialGet` (for text/blob payload copies).
- **What it does:** Generic memmove.
- **Port status:** RTL.  *Opportunity:* not Move itself — but
  trim Move *calls*.  C's `cellSizePtr` short-circuits when
  `info.nLocal == info.nPayload`; verify Pas `fillInCell` /
  `insertCellFast` aren't always copying when a varint header
  could be patched in place.  Likely a 1–2 % win at best — keep
  as **12.2.candidate.9** (low priority).

### 4. `sqlite3BtreeIndexMoveto` — 4.95 %
- **File:line:** `src/passqlite3btree.pas:3452`.
- **What it does:** Binary-search descent of an index b-tree for
  an unpacked key; calls `sqlite3VdbeRecordCompare` per cell.
- **Port status:** Port of `btree.c:sqlite3BtreeIndexMoveto`.
  *Opportunity:* the inner `while lwr <= upr` loop allocates
  nothing in C but FPC may be spilling locals; verify with
  `-al` asm dump.  Also: cache `pCur^.pPage^.aData`,
  `pCur^.pPage^.maskPage`, `pCur^.pPage^.aCellIdx` in locals
  once per descent — Pas re-dereferences each iteration.
  **12.2.candidate.3**.

### 5. `sqlite3BtreeTableMoveto` — 1.95 %
- **File:line:** `src/passqlite3btree.pas:2909`.
- **What it does:** Integer-rowid b-tree seek (the IPK fast
  path).
- **Port status:** Honest port of
  `btree.c:sqlite3BtreeTableMoveto`.  *Opportunity:* same
  per-iteration field-cache trick as #4.  C also has a separate
  "hit the same page as last time" early-exit gated on
  `pCur->iPage`; confirm Pas keeps that gate (it should — bug if
  not). **12.2.candidate.4**.

### 6. `System.CompareByte` — 1.81 %
- **File:line:** FPC RTL (`???`).  Top Pascal caller:
  `sqlite3VdbeRecordCompare` for TEXT/BLOB tie-breaks; also
  `patternCompare` (LIKE).
- **What it does:** memcmp-equivalent.
- **Port status:** RTL.  *Opportunity:* none directly; reducing
  calls falls out of #2's specialised int/string compare paths.

### 7. `patternCompare` — 1.60 % (+ 0.69 % second-instance =
**2.29 %** combined)
- **File:line:** `src/passqlite3codegen.pas:54136` and
  `src/passqlite3codegen.pas:58452` (duplicate — see note below).
- **What it does:** GLOB / LIKE pattern engine.
- **Port status:** Port of `func.c:patternCompare`.  *First
  opportunity:* there are **two definitions** in
  passqlite3codegen.pas — confirm whether 58452 is dead code
  (forward duplicate?) or actively reachable; if dead, drop it
  to shrink the binary.  *Second opportunity:* the inner char-
  by-char loop is a textbook candidate for hand-rolled AVX2
  byte-search when `noCase=0` and `esc=0` (the 99 % case).
  **12.2.candidate.5**.

### 8. `System.FillChar` — 1.58 %
- **File:line:** FPC RTL.  Top Pascal callers (per back-trace):
  `sqlite3DbMallocZero`, `VdbeMakeReady` zero-fill,
  `pcache1FetchNoMutex` page initialisation.
- **What it does:** memset.
- **Port status:** RTL.  *Opportunity:* C SQLite uses
  `sqlite3MallocZero` plus `memset(p,0,sz)` similarly, so this
  is parity work; no engine change.  Reducing **calls** by
  reusing zeroed cache lines (e.g. `aMem` reuse across
  statement re-prepare) is **12.2.candidate.6** but expected
  small.

### 9. `sqlite3VdbeSerialGet` — 1.20 %
- **File:line:** `src/passqlite3vdbe.pas:2050` (forward at 1442).
- **What it does:** Decode one record-format serial value
  (varint, int, real, string, blob) into a `Mem`.
- **Port status:** Faithful port of
  `vdbeaux.c:sqlite3VdbeSerialGet`.  *Opportunity:* prime
  inlining target — short function, called once per column on
  every cursor step.  C marks it as `static` and lets the
  compiler inline at `OP_Column`.  **12.2.candidate.1** (best
  single bet; the call lives inside the #1 hottest opcode arm).

### 10. `sqlite3VdbeRecordUnpack` — 1.10 %
- **File:line:** `src/passqlite3vdbe.pas:2263`.
- **What it does:** Unpack a serialised record into the
  `aMem[]` array of a `UnpackedRecord` (used by every index
  seek before #2).
- **Port status:** Faithful port.  *Opportunity:* it calls
  `sqlite3VdbeSerialGet` (#9) in a tight loop — once #9 is
  inlined this entry shrinks automatically.  Secondary: hoist
  `pKeyInfo^.nAllField` into a local. **12.2.candidate.7**.

---

## Honourable mentions (>= 0.5 % self, not in top-10)

| %    | symbol                                | file:line                          | note |
|------|---------------------------------------|------------------------------------|------|
| 0.98 | `freeSpace`                            | passqlite3btree.pas:1284           | page-cell free; arithmetic-heavy, candidate.10 |
| 0.97 | `sqlite3BtreeInsert`                   | passqlite3btree.pas:6053           | insert dispatch |
| 0.87 | `insertCellFast`                       | passqlite3btree.pas:1867           | Move-heavy (see #3) |
| 0.80 | `btreeParseCellPtr`                    | passqlite3btree.pas:918            | varint + record-header decode; **inline candidate.8** |
| 0.80 | `btreeDecodeInt`                       | passqlite3btree.pas:3156           | byte-swap big-endian int; AVX/bswap candidate |
| 0.74 | `getPageNormal`                        | passqlite3pager.pas                | pcache hit path |
| 0.71 | `allocateSpace`                        | passqlite3btree.pas                | page-cell alloc |
| 0.65 | `moveToRoot`                           | passqlite3btree.pas                | cursor reset |
| 0.61 | `sqlite3BtreeNext`                     | passqlite3btree.pas                | cursor advance |
| 0.60 | `balance_nonroot`                      | passqlite3btree.pas                | page split |
| 0.58 | `sqlite3Realloc`                       | passqlite3util.pas                 | wraps libc |
| 0.56 | `pageFindSlot`                         | passqlite3btree.pas                | freelist scan |
| 0.56 | `getCellInfo`                          | passqlite3btree.pas                | cached cell parser |
| 0.53 | `fillInCell`                           | passqlite3btree.pas                | Move-heavy |
| 0.53 | `getAndInitPage`                       | passqlite3btree.pas                | page init |
| 0.53 | `sqlite3BtreePayloadFetch`             | passqlite3btree.pas                | payload pointer |
| 0.52 | `pcache1FetchNoMutex`                  | passqlite3pcache.pas               | cache hash lookup |
| 0.52 | `btreeParseCell`                       | passqlite3btree.pas                | trampoline → btreeParseCellPtr |
| 0.50 | `btreeHeapPull`                        | passqlite3btree.pas                | incremental vacuum |
| 0.47 | `sqlite3VdbeIdxRowid`                  | passqlite3vdbe.pas                 | rowid extract from idx |
| 0.46 | `sqlite3GetVarint`                     | passqlite3util.pas                 | varint decode; **AVX/PEXT candidate.11** |

## Headline shape of the profile

- **VDBE dispatch + per-step record handling = ~30 %.**
  Items #1, #9, #10, plus `OP_Column`-adjacent paths.  Wins
  here have leverage across every workload.
- **B-tree comparison + traversal = ~15 %.**  Items #2, #4, #5,
  plus the 0.5–1 % btree tail.
- **Memory/RTL = ~10 %.**  Move + FillChar + CompareByte +
  malloc/free.  Mostly parity work; opportunity is to *avoid
  calls*, not to speed up RTL.
- **String marshalling = ~6 %.**  `DefaultUnicode2AnsiMove`,
  `DefaultAnsi2UnicodeMove`, `fpc_unicodestr_*`,
  `fpc_ansistr_to_unicodestr`.  Almost certainly extra vs C —
  C SQLite stores UTF-8 natively and never round-trips through
  UCS-2.  See `feedback_result_text_change_encoding.md` —
  encoding conversions are deliberate for UTF-16 DBs, but the
  *speedtest1* default is UTF-8, so any `UnicodeString` traffic
  is FPC-overhead in `passpeedtest1.pas` glue, not engine
  cost.  Track as **12.3.candidate.1** (separate from threaded
  dispatch).

## Methodology notes / caveats

- Callgrind counts **instructions**, not cycles.  Branchy
  varint code (#9, sqlite3GetVarint) is under-weighted vs
  cache-miss-heavy code (#1's case dispatch likely heavier in
  cycles than Ir suggests).
- `--size 1` was used to keep callgrind under five minutes.
  A re-run at `--size 5` may shift the ratios slightly toward
  the larger tables (testset 110, 120, 180) — but spot-check
  of `--size 5` was skipped here because the `--testset main
  --size 5` SQLITE_CORRUPT note in `profile_perf.sh` may apply
  to callgrind too; leave as 12.1.followup if 12.2 needs
  bigger sample.
- The `''2` suffix on some symbols (e.g.
  `SQLITE3VDBEEXEC$PVDBE$$LONGINT'2`,
  `PATTERNCOMPARE...$$LONGINT'2`) is FPC's clone suffix —
  inlined / specialised variants emitted alongside the
  original.  Both copies attributed to the same source line.

## 12.2.candidate.5.b evaluation

Considered: hand-rolled AVX2 PCMPEQB byte-search for the
`noCase=0 AND esc=0` arm of patternCompare (the wildcard
post-`%` scan at codegen.pas where the C reference uses
`zString += strcspn(zString, zStop)`).  Decision: **defer
(evaluation only, no asm added).**

Rationale.  (i) In the `noCase=0 esc=0` arm `zStop0==zStop1`,
so the inner scan looks for *one* byte (or NUL).  FPC's RTL
`IndexByte` is already a 16-byte-stride SSE2 PCMPEQB primitive
implemented in `rtl/x86_64/x86_64.inc` (verified: a 16-byte
buffer probe returns the correct index from a single call).
(ii) However `IndexByte` needs an explicit length; the input
is NUL-terminated and unknown-length, so a naive port would
need an `strlen` precursor (doubling the byte traffic) or a
sentinel-aware variant that does not exist in stock FPC.
(iii) The callgrind 2.29 % patternCompare share is split
across wildcard handling, recursive descent, UTF-8 decode, and
the inner scan; the scan itself is well under 1 % of total Ir.
Hand-written AVX2 with proper alignment + tail handling +
NUL-stop OR `zStop0` OR `zStop1` triple-compare would add
~60 lines of `{$ASMMODE INTEL}` asm plus a Pascal fallback for
sub-1 % gain, and the `noCase=0` case is *not* the LIKE
default (LIKE default is case-insensitive ⇒ noCase=1, which
goes through the two-byte stop path and would need a separate
asm kernel).  (iv) The simpler win — replacing the manual
scalar loop with `IndexByte` for the noCase=0 arm — also helps
the C-vs-Pas asymmetry but is gated on knowing the string
length; deferred together with (v) below.

Re-evaluate when: a profiling run shows LIKE/GLOB on long
TEXT columns (>=512 bytes) appearing in HOT10, OR when
12.3.candidate.2 lands a string-length cache on Mem* that
would make `IndexByte` cheap to wire in.

Closed as: evaluated, no implementation.
