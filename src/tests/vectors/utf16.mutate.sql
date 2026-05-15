-- utf16.db.mutate.sql — 9.2.3 round-trip probe.
-- UTF-16le encoding (locked at create); mutators traverse the
-- SQLITE_UTF8→SQLITE_UTF16LE conversion path in sqlite3VdbeMemSetStr.
BEGIN;
INSERT INTO t VALUES(5, 'plain');
INSERT INTO t VALUES(6, 'caf' || char(0xE9) || '-x');
UPDATE t SET label='ASCII' WHERE id=1;
DELETE FROM t WHERE id=2;
COMMIT;
