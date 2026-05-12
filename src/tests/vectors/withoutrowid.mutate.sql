-- withoutrowid.db.mutate.sql — 9.2.3 round-trip probe.
-- WITHOUT ROWID + composite PK: hits the PK-index b-tree directly.
BEGIN;
INSERT INTO t VALUES('delta', 1, 'six');
INSERT INTO t VALUES('alpha', 3, 'three-prime');
UPDATE t SET c='ONE' WHERE a='alpha' AND b=1;
DELETE FROM t WHERE a='beta' AND b=1;
COMMIT;
