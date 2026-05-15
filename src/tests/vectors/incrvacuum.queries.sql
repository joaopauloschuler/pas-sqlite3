-- incrvacuum.db.queries.sql — 9.2.2 read-only parity probe.
-- Exercises auto_vacuum=INCREMENTAL header (52..55=2) and remaining
-- rows after the freelist delete + incremental_vacuum step.
PRAGMA auto_vacuum;
PRAGMA page_size;
SELECT id, length(payload) FROM t ORDER BY id;
SELECT count(*) FROM t;
