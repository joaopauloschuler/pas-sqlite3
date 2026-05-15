-- withoutrowid.db.schema.sql — 9.2.4 schema-change probe.
-- WITHOUT ROWID + composite PK.  ALTER TABLE ADD COLUMN works even on
-- WITHOUT ROWID tables (build.c sqlite3AlterFinishAddColumn doesn't gate
-- on HasRowid).  CREATE INDEX over the non-PK col then VACUUM.
BEGIN;
ALTER TABLE t ADD COLUMN d INTEGER DEFAULT 7;
CREATE INDEX idx_c ON t(c);
CREATE VIEW v_t AS SELECT a, b FROM t WHERE d = 7;
COMMIT;
VACUUM;
