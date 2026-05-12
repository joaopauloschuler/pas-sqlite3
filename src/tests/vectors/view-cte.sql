-- view-cte.db — plain VIEW + a recursive CTE materialised into a
-- secondary table.  Reference: ../sqlite3/src/select.c (selectExpander
-- for view inlining) and ../sqlite3/src/with.c (WITH RECURSIVE
-- compile path).  The cte_seed table snapshots the CTE result so the
-- on-disk artefact is more than a pure schema.
PRAGMA page_size = 4096;
CREATE TABLE base(id INTEGER PRIMARY KEY, n INTEGER);
INSERT INTO base VALUES(1,10),(2,20),(3,30),(4,40),(5,50);
CREATE VIEW v_doubled AS SELECT id, n*2 AS n2 FROM base;
CREATE TABLE cte_seed AS
  WITH RECURSIVE cnt(x) AS (
    SELECT 1 UNION ALL SELECT x+1 FROM cnt WHERE x<8
  )
  SELECT x FROM cnt;
