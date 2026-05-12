-- withoutrowid.db.queries.sql — 9.2.2 read-only parity probe.
-- Range-scans the composite PK on a WITHOUT ROWID table.
SELECT a, b, c FROM t ORDER BY a, b;
SELECT a, b, c FROM t WHERE a='alpha' ORDER BY b;
SELECT a, b, c FROM t WHERE a='beta' AND b=2;
SELECT count(*) FROM t;
PRAGMA index_list(t);
