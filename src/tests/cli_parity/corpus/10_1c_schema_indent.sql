CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT NOT NULL,
               c REAL, d BLOB, UNIQUE(b,c));
CREATE INDEX ti ON t(b);
.schema --indent
