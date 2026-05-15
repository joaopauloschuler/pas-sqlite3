-- view-cte.db.mutate.sql — 9.2.3 round-trip probe.
-- Mutates base (the underlying table of v_doubled) + the cte_seed
-- snapshot.  View v_doubled is read-only (no INSTEAD OF trigger);
-- this drives select.c selectExpander on schema reload.
BEGIN;
INSERT INTO base VALUES(6,60),(7,70);
UPDATE base SET n=999 WHERE id=3;
DELETE FROM base WHERE id=1;
INSERT INTO cte_seed VALUES(9);
DELETE FROM cte_seed WHERE x=1;
COMMIT;
