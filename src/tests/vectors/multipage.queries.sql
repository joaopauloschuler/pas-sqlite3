-- multipage.db.queries.sql — 9.2.2 read-only parity probe.
-- Exercises range scans across multi-page b-tree.
SELECT count(*) FROM t;
SELECT id, length(val) FROM t WHERE id BETWEEN 50 AND 55 ORDER BY id;
SELECT min(id), max(id) FROM t;
SELECT id FROM t WHERE id IN (1, 100, 199) ORDER BY id;
PRAGMA page_size;
