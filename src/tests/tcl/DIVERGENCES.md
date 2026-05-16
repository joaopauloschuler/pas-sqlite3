# DIVERGENCES.md — engine divergences surfaced by the 9.4 tcl-feature sweep

Bootstrapped under task **9.4.4.a**.  Each bucket clusters one symptom
across multiple `.test` files; counts reflect tests where the bucket
fires at least once.  Buckets are not root-caused here — that work
belongs to Phase 6 / 7 / 8 follow-ups.  Format:

    ## 9.4.divbug.N — <one-line symptom>
    Affects: <count> tests (<paths>).
    Symptom: ...
    Likely cause: ...

- [X] ## 9.4.divbug.1 — `select1.test` segfaults inside libpassqlite3tcl.so — FIXED
- [X] ## 9.4.divbug.2 — Truncated SQL error messages drop the function name — FIXED
- [X] ## 9.4.divbug.3 — Schema introspection result columns reordered / missing — FIXED
- [X] ## 9.4.divbug.4 — auto-index name collision yields `out of memory` — FIXED
- [X] ## 9.4.divbug.5 — UTF-16 numcast (`numcast-utf16*`) returns empty string — FIXED
- [X] ## 9.4.divbug.7 — `insert.test` wedges past `insert-1.3` — FIXED (9.4.divbug.7)
- [X] ## 9.4.divbug.8 — `index.test` segfaults at `index-3.3` — FIXED
- [X] ## 9.4.divbug.9 — `lastinsert.test` segfaults at `lastinsert-1.1w` — FIXED
- [X] ## 9.4.divbug.10 — `boundary1.test` empty results — FIXED
- [X] ## 9.4.divbug.11 — `multiSelectByMerge: iOrderByCol<=0` assert (compound SELECT ORDER BY) — FIXED
- [X] ## 9.4.divbug.12 — `update.test` segfaults at `update-17.10` — FIXED
- [X] ## 9.4.divbug.13 — Result-set row ORDER for inequality scans is unstable — FIXED
- [X] ## 9.4.divbug.14 — SQL error messages still drop the object name — FIXED
- [X] ## 9.4.divbug.15 — `no such function` not raised at prepare time — FIXED
- [X] ## 9.4.divbug.16 — `affinity3.test` segfaults — FIXED
- [X] ## 9.4.divbug.17 — nested aggregate produces row-wise instead of folded result, then segfaults — FIXED
- [X] ## 9.4.divbug.18 — WITHOUT ROWID virtual-table xUpdate codegen mis-handles DELETE (no-op) and UPDATE (segfault) — FIXED
### 9.4.6.q follow-up — test1.c command subset ported
### 9.4.6.l.5 follow-up — `register_async_vtab` investigated → drop the bullet
- [X] ## 9.4.divbug.19 — table-qualified `rowid` alias not resolved — FIXED (tasklist.md:954, commit 3fd04ef)
- [X] ## 9.4.divbug.20 — BETWEEN-on-indexed-column planner picks `nosort` / drops rows — FIXED (tasklist.md:955, commits 2f8d92a/d7ceaf3/5dba89a)
- [X] ## 9.4.divbug.21 — cross-connection EXCLUSIVE lock not detected — FIXED (tasklist.md:956, commits 45593de/a8e63c3)
- [X] ## 9.4.divbug.22 — large row payload / 64KB page_size overflow handling segfaults — FIXED (tasklist.md:957, commits 45a1fbb/9744b0f)
- [X] ## 9.4.divbug.23 — co-routine materialisation of correlated subquery not chosen (EXPLAIN QUERY PLAN drift) — FIXED (tasklist.md:958)
- [X] ## 9.4.divbug.24 — AUTOINCREMENT / `sqlite_sequence` double-create — FIXED
- [X] ## 9.4.divbug.24.b — aggregate sub-query in correlated GROUP BY mis-folds + segfault — FIXED (tasklist.md:960)
- [X] ## 9.4.divbug.28 — EXPLAIN QUERY PLAN multi-table segfault — FIXED
- [X] ## 9.4.divbug.41 — EQP "TEMP B-TREE FOR ORDER BY" omits LAST-N-TERMS — FIXED
- [X] ## 9.4.divbug.29 — TEXT-affinity column stores hex literal `0x...` as INTEGER — FIXED
- [X] ## 9.4.divbug.30 — ORDER BY with non-default collation mis-orders — FIXED
- [X] ## 9.4.divbug.31 — Spurious `database disk image is malformed` for non-corrupt errors — FIXED (tasklist.md:968)
- [X] ## 9.4.divbug.33 — `count(DISTINCT …)` wrong result
- [X] ## 9.4.divbug.34 — `PRAGMA page_size` default mismatch — RESOLVED
- [X] ## 9.4.divbug.35 — Float-to-text precision artifacts — FIXED
- [X] ## 9.4.divbug.36 — `PRAGMA journal_mode=off` silently ignored — FIXED
- [X] ## 9.4.divbug.37 — WAL `wal_hook` callback count = 0
- [X] ## 9.4.divbug.38 — FK ON-clause syntax error not raised + row mis-pick — FIXED (tasklist.md:975-976, split into 38.a/38.b)
- [X] ## 9.4.divbug.39 — `CREATE TABLE AS SELECT` unsupported — FIXED
- [X] ## 9.4.divbug.40 — `DEFAULT` literal type + error-msg column-name drop
