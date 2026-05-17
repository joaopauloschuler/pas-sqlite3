# 10.2 CLI integration parity gate — divergences

Gate harness: `run_corpus.sh` and `TestCliParity.pas` replay every `corpus/*.sql`
script against both the in-tree `bin/passqlite3` and the upstream `sqlite3`
binary at `/home/bpsa/app/sqlite3/sqlite3` (override with `UPSTREAM_SQLITE3`).
stdout, stderr and exit code must all byte-match. The gate's job is to *surface*
divergences — not fix them.

## Tally (initial landing 2026-05-16)

- corpus scripts:        21
- pas-strict PASS:       20
- pas-soft (cited):       0
- pas-skip:               0
- pas-strict FAIL:        1  (tracked via 10.2.divbug.1, see below)

## Open follow-ups

### 10.2.divbug.1 — `.mode line` does not right-pad column-name labels

Affected script: `corpus/sink_mode_switching.sql` (the only corpus member that
shells `.mode line` over a result whose column names differ in length).

Repro (minimal):

```
CREATE TABLE k(id INTEGER PRIMARY KEY, label TEXT);
INSERT INTO k VALUES(3,'three');
.mode line
SELECT id, label FROM k;
```

Upstream renders the column-name column right-padded to the widest header:

```
   id = 3
label = three
```

Port renders it flush-left, dropping the leading spaces:

```
id = 3
label = three
```

stdout differs byte-for-byte from upstream; rc and stderr match.

Likely site: `qrf.c` / the column-mode renderer fork — MODE_Line uses the
widest-column-name pad (upstream `shell.c.in` line-mode arm computes
`w = strlen(zCol)`/`w = pCol->w` and emits `%*s = %s`). The Pas port appears
to skip the pad path.

Tracked here as soft-fail; flip from FAIL → SOFT by appending
`sink_mode_switching` to the `SOFT_SKIP` heredoc in `run_corpus.sh` once
this bullet has a confirmed handler.

Not part of the 10.2 gate's job to fix (per task contract: surface, not fix).

## Soft-skip protocol

Entries appended to the `SOFT_SKIP` heredoc inside `run_corpus.sh` (one
basename per line, no `.sql` suffix) are downgraded from FAIL → SOFT in the
counters and do not poison `exit 1`. Each entry must point at a numbered
`10.2.divbug.N` bullet here.

## How to extend the corpus

Drop additional `corpus/*.sql` scripts in alphabetical order. They are picked
up automatically by both `run_corpus.sh` and `TestCliParity.pas`. Keep scripts
hermetic: no `.read` of external files, no FS writes outside `:memory:` (the
gate hands `:memory:` as the DB path to both shells).
