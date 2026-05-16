-- 10.1f long-tail: .dbinfo on a populated DB
CREATE TABLE t(a,b);
INSERT INTO t VALUES(1,'a'),(2,'b'),(3,'c');
CREATE INDEX ti ON t(a);
.dbinfo
