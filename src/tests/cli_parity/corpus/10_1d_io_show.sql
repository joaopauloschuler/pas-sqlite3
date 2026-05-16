-- 10.1d I/O: .show and .changes (no external file deps for hermeticity)
CREATE TABLE t(a);
INSERT INTO t VALUES(1),(2),(3);
.changes on
UPDATE t SET a=a*10;
.changes off
.show
