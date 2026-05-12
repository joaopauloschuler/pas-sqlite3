-- partial-index.db — partial index with a WHERE clause.  Reference:
-- ../sqlite3/src/build.c (sqlite3CreateIndex partial-index arm) and
-- where.c (whereLoopAddBtreeIndex partial-index match).  Tracked in
-- sqlite_master via the index's "WHERE" suffix; the index b-tree only
-- stores rows that satisfy the predicate.
PRAGMA page_size = 4096;
CREATE TABLE t(id INTEGER PRIMARY KEY, status TEXT, val INTEGER);
INSERT INTO t VALUES(1,'active',10);
INSERT INTO t VALUES(2,'archived',20);
INSERT INTO t VALUES(3,'active',30);
INSERT INTO t VALUES(4,'pending',40);
INSERT INTO t VALUES(5,'active',50);
CREATE INDEX idx_active_val ON t(val) WHERE status='active';
