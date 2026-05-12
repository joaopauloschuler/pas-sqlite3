-- simple.db — minimal rowid table with two rows.
-- Origin: pre-existing vector (Phase 3 pager tests). Documented here so
-- regen.sh can rebuild it byte-identically from source.
-- Each statement on its own line so the C shell commits a separate
-- transaction per statement (file change counter == 3).
CREATE TABLE t(id INTEGER PRIMARY KEY, val TEXT);
INSERT INTO t VALUES(1,'hello');
INSERT INTO t VALUES(2,'world');
