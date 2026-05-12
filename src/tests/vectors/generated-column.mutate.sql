-- generated-column.db.mutate.sql — 9.2.3 round-trip probe.
-- Generated columns: only a,b are writable; c (VIRTUAL) and d (STORED)
-- are populated by the codegen path.  STORED column 'd' is recomputed
-- on UPDATE and persisted, exercising build.c sqlite3AddGenerated.
BEGIN;
INSERT INTO t(a,b) VALUES(4, 40);
INSERT INTO t(a,b) VALUES(5, 50);
UPDATE t SET b=100 WHERE a=1;
DELETE FROM t WHERE a=2;
COMMIT;
