-- generated-column.db — both VIRTUAL and STORED generated columns.
-- Reference: ../sqlite3/src/build.c (sqlite3AddGenerated) and select.c
-- (resolveAlias for VIRTUAL columns) plus the PRAGMA table_xinfo arm.
PRAGMA page_size = 4096;
CREATE TABLE t(
  a INTEGER PRIMARY KEY,
  b INTEGER,
  c INTEGER GENERATED ALWAYS AS (a + b) VIRTUAL,
  d INTEGER GENERATED ALWAYS AS (a * b) STORED
);
INSERT INTO t(a, b) VALUES(1, 10);
INSERT INTO t(a, b) VALUES(2, 20);
INSERT INTO t(a, b) VALUES(3, 30);
