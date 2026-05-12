-- partial-index.db.mutate.sql — 9.2.3 round-trip probe.
-- Each mutator either crosses the WHERE status='active' predicate
-- (so the partial index must (de)index the row) or stays out of it.
-- Reference: ../sqlite3/src/where.c (whereLoopAddBtreeIndex
-- partial-index match) + insert.c (IndexedWhereClauseMatched).
BEGIN;
INSERT INTO t VALUES(6,'active',60);       -- adds to partial idx
INSERT INTO t VALUES(7,'archived',70);     -- excluded by predicate
UPDATE t SET status='archived' WHERE id=1; -- removes from partial idx
UPDATE t SET status='active'   WHERE id=4; -- adds to partial idx
DELETE FROM t WHERE id=3;                  -- removes from partial idx
COMMIT;
