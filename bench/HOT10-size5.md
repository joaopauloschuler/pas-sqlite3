# HOT10 (bigger-sample re-run) — Phase 12.1.followup

**Date:** 2026-05-16
**Workload:** `bin/passpeedtest1 --testset main --size 2`
**Backend:** Pascal port, same binary as `HOT10.md`.
**Profiler:** `valgrind --tool=callgrind`.
**Command:** `PROFILE_SIZE=2 PROFILE_TESTSET=main bash bench/profile_callgrind.sh`
**Raw report:** `callgrind_annotate --threshold=99.9 --auto=no bench/callgrind.out`
**Totals:** 341,389,500 Ir across testset 100..290 (29 of 30 tests).

## Why not `--size 5` (or 3/4)?

Re-confirmed the SQLITE_CORRUPT note from `bench/profile_perf.sh`
applies to the engine itself, not the profiler.  Native runs
(`LD_LIBRARY_PATH=src bin/passpeedtest1 --testset main --size N`) fail
at progressively earlier tests as N grows:

| size | first failing test                                  | exit |
|------|-----------------------------------------------------|------|
| 1    | (none — full run completes)                         | 0    |
| 2    | 300  `Refill a 1000-row table using (b&1)==(a&1)`   | 1    |
| 3    | 180  `INSERT INTO t4 SELECT * FROM z1` (3 indexes)  | 1    |
| 4    | 180  same                                           | 1    |
| 5    | 120  `INSERT INTO t3 VALUES(?1,?2,?3)` (unord IPK)  | 1    |

Reproducer (any size > 1):

```
LD_LIBRARY_PATH=src bin/passpeedtest1 --testset main --size 5
# → "Error code 11: database disk image is malformed" at test 120
```

The pattern (size-correlated, hits unordered IPK insert / multi-index
insert / `DELETE FROM z2;`) points at a balance / cell-overflow bug
provoked by larger b-trees.  Out of scope for 12.1.followup — filed as
a future engine bug for a dedicated phase; tracking it here lets 12.2
candidates proceed without re-investigating.

**Bigger sample chosen:** `--size 2` is the largest that still covers
the bulk of the testset (29/30 tests, 1000-row tables vs HOT10's
500-row, 341M Ir vs HOT10's 248M = 1.38× more instruction count).

## Top 10 by self time (size=2)

| Rank | %      | Symbol (Pascal-mangled trimmed)                    | File                              | HOT10 rank | Δ           |
|------|--------|----------------------------------------------------|-----------------------------------|------------|-------------|
| 1    | 18.90  | `sqlite3VdbeExec`                                  | passqlite3vdbe.pas                | 1 (17.94)  | unchanged   |
| 2    | 5.68   | `System.Move`                                      | RTL                               | 3 (5.05)   | up 1        |
| 3    | 3.97   | `sqlite3BtreeIndexMoveto`                          | passqlite3btree.pas               | 4 (4.95)   | up 1        |
| 4    | 2.43   | `patternCompare` (primary copy)                    | passqlite3codegen.pas:54136       | 7 (1.60)   | up 3        |
| 5    | 2.02   | `vdbeRecordCompareInt`                             | passqlite3btree.pas               | —          | NEW         |
| 6    | 2.02   | `sqlite3VdbeRecordCompare` (generic)               | passqlite3btree.pas               | 2 (8.70)   | down 4 (*)  |
| 7    | 1.83   | `sqlite3BtreeTableMoveto`                          | passqlite3btree.pas               | 5 (1.95)   | down 2      |
| 8    | 1.81   | `sqlite3VdbeRecordUnpack`                          | passqlite3vdbe.pas                | 10 (1.10)  | up 2        |
| 9    | 1.75   | `System.FillChar`                                  | RTL                               | 8 (1.58)   | up 1 / flat |
| 10   | 1.55   | `sqlite3VdbeSerialGet`                             | passqlite3vdbe.pas                | 9 (1.20)   | up 1 / flat |

Honourable mentions (>0.5 %, not in top-10):

| %    | symbol                                          | file                          |
|------|-------------------------------------------------|-------------------------------|
| 1.30 | `balance_nonroot`                               | passqlite3btree.pas           |
| 1.26 | `_int_malloc`                                   | libc                          |
| 1.23 | `System.CompareByte`                            | RTL                           |
| 1.19 | `sqlite3BtreeInsert`                            | passqlite3btree.pas           |
| 1.08 | `freeSpace`                                     | passqlite3btree.pas           |
| 1.08 | `insertCellFast`                                | passqlite3btree.pas           |
| 1.04 | `pthread_mutex_lock`                            | libc                          |
| 1.03 | `patternCompare` (clone copy)                   | passqlite3codegen.pas:58452   |
| 1.00 | `btreeParseCellPtr`                             | passqlite3btree.pas           |
| 0.99 | `sqlite3VdbeExec` (clone)                       | passqlite3vdbe.pas            |
| 0.94 | `sysGetMem_fixed`                               | RTL                           |
| 0.88 | `allocateSpace`                                 | passqlite3btree.pas           |
| 0.85 | `DefaultUnicode2AnsiMove`                       | RTL                           |
| 0.79 | `__memset_avx2_unaligned_erms`                  | libc                          |
| 0.75 | `sqlite3Realloc`                                | passqlite3util.pas            |
| 0.72 | `pageFindSlot`                                  | passqlite3btree.pas           |
| 0.71 | `vdbeRecordCompareString`                       | passqlite3btree.pas           |
| 0.71 | `getPageNormal`                                 | passqlite3pager.pas           |
| 0.67 | `vdbeSorterMergeSort` (clone)                   | passqlite3vdbe.pas            |
| 0.67 | `DefaultAnsi2UnicodeMove`                       | RTL                           |
| 0.66 | `sqlite3BtreeNext`                              | passqlite3btree.pas           |
| 0.62 | `fillInCell`                                    | passqlite3btree.pas           |
| 0.61 | `vdbeSorterCompareRec`                          | passqlite3vdbe.pas            |
| 0.58 | `sqlite3VdbeMemGrow`                            | passqlite3vdbe.pas            |
| 0.57 | `getCellInfo`                                   | passqlite3btree.pas           |
| 0.55 | `sqlite3PagerWrite`                             | passqlite3pager.pas           |
| 0.52 | `LikeFunc`                                      | passqlite3codegen.pas         |
| 0.52 | `getAndInitPage`                                | passqlite3btree.pas           |
| 0.52 | `sqlite3BtreePayloadFetch`                      | passqlite3btree.pas           |
| 0.51 | `btreeParseCell`                                | passqlite3btree.pas           |

(*) Important correction to HOT10.md commentary: at size=2 the
profile clearly shows `vdbeRecordCompareInt` (the integer-key
specialisation) accounting for 2.02 %, and the generic
`sqlite3VdbeRecordCompare` for another 2.02 %, plus
`vdbeRecordCompareString` 0.71 %.  Total record-compare cost is
therefore ~4.75 %, not 8.70 % "all generic" as HOT10 implied.  The
int-key fast path **is** wired in the Pascal port; HOT10 candidate
12.2.candidate.2 ("specialise int/string compare") is already partly
done.  The remaining opportunity is narrower than HOT10 suggested —
shaving the generic-path 2.02 %, not halving 8.70 %.

## Ranking shifts vs HOT10 (size=1)

- **#1 `sqlite3VdbeExec` unchanged** at the top; share grew slightly
  (17.94 → 18.90 %).  Reinforces 12.2.candidate.1 (split hot opcode
  arms) and 12.3 (threaded dispatch) as the highest-leverage targets.
- **`patternCompare` jumped sharply** (combined 2.29 → 3.46 %),
  driven by tests 140/142/145 (LIKE) processing 2× the rows.  If
  12.2 wants a quick win on a larger-table workload, patternCompare
  passes Move for second place.
- **`balance_nonroot`, `insertCellFast`, `freeSpace` all rose** into
  the 1.0–1.3 % band (each was 0.5–0.9 % at size=1).  Page-balance
  cost scales with table size; expect even more share at the sizes
  the CORRUPT bug currently blocks.  12.2 candidate list should
  reserve a slot for balance/insert path tuning.
- **Top-10 membership is otherwise stable.**  Same five files
  (`vdbe.pas`, `btree.pas`, `codegen.pas` + libc/RTL) dominate.  No
  new previously-unseen functions enter the top-10; the change is
  re-ranking within a known set.
- **Conclusion:** HOT10's selection of 12.2 candidates remains
  defensible.  Reweighting suggestion: promote
  `balance_nonroot`/`insertCellFast` from 12.2.candidate.10 to a
  higher slot when targeting INSERT-heavy workloads, and adjust the
  `sqlite3VdbeRecordCompare` opportunity description per the (*)
  note above.

## Methodology notes

- `set -e` in `bench/profile_callgrind.sh` propagates the binary's
  exit-1 (from the SQLITE_CORRUPT abort at test 300) but valgrind
  still flushes `callgrind.out` on program termination — the
  generated file covers tests 100..290 in full.
- The repeated `'2` clone suffix (e.g. `SQLITE3VDBEEXEC...'2`) is
  FPC's emitted second specialisation; HOT10 explains.
- 12.1.followup intentionally **does not** try to fix the
  SQLITE_CORRUPT bug; that is a separate engine bug worth its own
  reproducer-bisect phase.
