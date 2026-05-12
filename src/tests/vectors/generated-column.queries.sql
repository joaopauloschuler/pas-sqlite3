-- generated-column.db.queries.sql — 9.2.2 read-only parity probe.
-- Reads back both VIRTUAL (c) and STORED (d) generated columns.
SELECT a, b, c, d FROM t ORDER BY a;
SELECT a, c FROM t WHERE c=22;
SELECT a, d FROM t WHERE d=60;
PRAGMA table_xinfo(t);
