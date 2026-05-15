-- simple.db.queries.sql — 9.2.2 read-only parity probe.
-- Exercises the 2-row rowid table.
SELECT id, val FROM t ORDER BY id;
SELECT count(*) FROM t;
SELECT typeof(id), typeof(val) FROM t WHERE id=1;
PRAGMA table_info(t);
