-- simple.db.mutate.sql — 9.2.3 round-trip probe.
-- Exercises plain INSERT/UPDATE/DELETE on the 2-row rowid table.
BEGIN;
INSERT INTO t VALUES(3,'foxtrot');
INSERT INTO t VALUES(4,'golf');
UPDATE t SET val='WORLD' WHERE id=2;
DELETE FROM t WHERE id=1;
COMMIT;
