-- withoutrowid.db — WITHOUT ROWID table.  Reference: ../sqlite3/src/build.c
-- (sqlite3CreateTable WITHOUT ROWID arm) and insert.c (HasRowid path).
-- Table is keyed by composite PRIMARY KEY so the index b-tree carries
-- the payload directly (no rowid skiplist).
PRAGMA page_size = 4096;
CREATE TABLE t(a TEXT, b INTEGER, c TEXT, PRIMARY KEY(a, b)) WITHOUT ROWID;
INSERT INTO t VALUES('alpha', 1, 'one');
INSERT INTO t VALUES('alpha', 2, 'two');
INSERT INTO t VALUES('beta', 1, 'three');
INSERT INTO t VALUES('beta', 2, 'four');
INSERT INTO t VALUES('gamma', 1, 'five');
