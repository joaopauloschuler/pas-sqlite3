-- partial-index.db.schema.sql — 9.2.4 schema-change probe.
-- Already has idx_active_val WHERE status='active'.  Add a second partial
-- index, rename a column, drop a column (sqlite_drop_column path), then
-- VACUUM rewrites all index b-trees.
BEGIN;
CREATE INDEX idx_pending_val ON t(val) WHERE status='pending';
ALTER TABLE t ADD COLUMN note TEXT;
ALTER TABLE t RENAME COLUMN val TO amount;
COMMIT;
VACUUM;
