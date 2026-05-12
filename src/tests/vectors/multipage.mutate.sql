-- multipage.db.mutate.sql — 9.2.3 round-trip probe.
-- Mutates a few rows scattered across multiple b-tree pages.
BEGIN;
INSERT INTO t VALUES(200, printf('%.*c',100,'y'));
INSERT INTO t VALUES(201, printf('%.*c',100,'z'));
UPDATE t SET val=printf('%.*c',100,'Z') WHERE id IN (50,100,150);
DELETE FROM t WHERE id IN (10,20,30);
COMMIT;
