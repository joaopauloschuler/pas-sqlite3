-- simple.db.schema.sql — 9.2.4 schema-change probe.
-- Exercises ALTER TABLE (ADD/RENAME COLUMN, RENAME TABLE),
-- CREATE INDEX, CREATE VIEW inside a single txn, then VACUUM
-- outside (vacuum.c:170 forbids VACUUM inside a transaction).
BEGIN;
ALTER TABLE t ADD COLUMN extra TEXT DEFAULT 'unset';
ALTER TABLE t RENAME COLUMN val TO label;
ALTER TABLE t RENAME TO t_renamed;
CREATE INDEX idx_label ON t_renamed(label);
CREATE VIEW v_simple AS SELECT id, label FROM t_renamed;
COMMIT;
