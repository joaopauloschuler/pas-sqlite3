-- view-cte.db.queries.sql — 9.2.2 read-only parity probe.
-- Exercises a plain VIEW + a re-evaluated WITH RECURSIVE alongside
-- the materialised cte_seed snapshot.
SELECT id, n FROM base ORDER BY id;
SELECT id, n2 FROM v_doubled ORDER BY id;
SELECT x FROM cte_seed ORDER BY x;
WITH RECURSIVE cnt(x) AS (
  SELECT 1 UNION ALL SELECT x+1 FROM cnt WHERE x<5
)
SELECT x FROM cnt;
SELECT name, type FROM sqlite_master ORDER BY type, name;
