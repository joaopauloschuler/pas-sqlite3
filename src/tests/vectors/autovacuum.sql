-- autovacuum.db — auto_vacuum FULL with a freelist-creating delete.
-- PRAGMA auto_vacuum must precede any CREATE TABLE for the setting to
-- bake into the header (auto_vacuum byte at offset 52..55 = 1).
-- See ../sqlite3/src/btree.c (autoVacuumCommit) for the on-disk effect.
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 4096;
CREATE TABLE t(id INTEGER PRIMARY KEY, payload BLOB);
INSERT INTO t VALUES(1, zeroblob(0));
INSERT INTO t VALUES(2, zeroblob(3500));
INSERT INTO t VALUES(3, zeroblob(3500));
INSERT INTO t VALUES(4, zeroblob(3500));
INSERT INTO t VALUES(5, zeroblob(3500));
DELETE FROM t WHERE id IN (2,3,4);
