-- partial-index.db.queries.sql — 9.2.2 read-only parity probe.
-- Exercises the partial index predicate (status='active') so the
-- planner picks idx_active_val for the matching arms and the table
-- scan for the non-matching ones.
SELECT id, status, val FROM t ORDER BY id;
SELECT id, val FROM t WHERE status='active' AND val>=20 ORDER BY val;
SELECT id FROM t WHERE status='archived';
SELECT count(*) FROM t WHERE status='active';
PRAGMA index_list(t);
SELECT name, sql FROM sqlite_master WHERE type='index' ORDER BY name;
