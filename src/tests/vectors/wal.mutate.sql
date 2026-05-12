-- wal.db.mutate.sql — 9.2.3 round-trip probe.
-- Mutates the WAL-mode db (already passive-checkpointed; sidecar absent).
BEGIN;
INSERT INTO t VALUES(6, printf('%.*c',1000,'f'));
INSERT INTO t VALUES(7, printf('%.*c',1000,'g'));
UPDATE t SET val=printf('%.*c',1000,'A') WHERE id=1;
DELETE FROM t WHERE id=3;
COMMIT;
