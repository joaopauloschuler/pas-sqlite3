-- autovacuum.db.queries.sql — 9.2.2 read-only parity probe.
-- Exercises auto_vacuum=FULL header byte (52..55=1) + remaining rows
-- after the freelist-creating delete.
PRAGMA auto_vacuum;
PRAGMA page_size;
SELECT id, length(payload) FROM t ORDER BY id;
SELECT count(*) FROM t;
