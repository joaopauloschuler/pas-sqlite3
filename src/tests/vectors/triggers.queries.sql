-- triggers.db.queries.sql — 9.2.2 read-only parity probe.
-- Exercises trigger-managed columns: src + log were both populated
-- by the BEFORE/AFTER + INSTEAD OF triggers during build.
SELECT id, val FROM src ORDER BY id;
SELECT seq, evt FROM log ORDER BY seq;
SELECT id, val FROM v ORDER BY id;
SELECT count(*) FROM src;
SELECT count(*) FROM log;
SELECT name, type FROM sqlite_master WHERE type='trigger' ORDER BY name;
