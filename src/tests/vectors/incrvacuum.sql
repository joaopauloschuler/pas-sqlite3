-- incrvacuum.db — auto_vacuum INCREMENTAL plus an explicit
-- incremental_vacuum step.  Header byte 64..67 (incrVacuum) = 1, byte
-- 52..55 (auto_vacuum) = 2 ("incremental").  See btree.c
-- (incrVacuumStep) and pragma.c (PRAGMA incremental_vacuum) for the
-- C-side touchpoints.
PRAGMA auto_vacuum = INCREMENTAL;
PRAGMA page_size = 4096;
CREATE TABLE t(id INTEGER PRIMARY KEY, payload BLOB);
INSERT INTO t VALUES(1, zeroblob(3500));
INSERT INTO t VALUES(2, zeroblob(3500));
INSERT INTO t VALUES(3, zeroblob(3500));
INSERT INTO t VALUES(4, zeroblob(3500));
INSERT INTO t VALUES(5, zeroblob(3500));
DELETE FROM t WHERE id IN (2,3,4);
PRAGMA incremental_vacuum(2);
