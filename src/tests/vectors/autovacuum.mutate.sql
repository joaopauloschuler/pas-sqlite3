-- autovacuum.db.mutate.sql — 9.2.3 round-trip probe.
-- Auto-vacuum=FULL: delete forces freelist truncation at COMMIT.
BEGIN;
INSERT INTO t VALUES(6, zeroblob(3500));
INSERT INTO t VALUES(7, zeroblob(3500));
UPDATE t SET payload=zeroblob(1000) WHERE id=5;
DELETE FROM t WHERE id IN (1,7);
COMMIT;
