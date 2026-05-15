-- autovacuum.db.schema.sql — 9.2.4 schema-change probe.
-- auto_vacuum=FULL vector.  Add an index, rename a column, then VACUUM
-- (under auto_vacuum the freelist is already ptrmap-backed so VACUUM
-- still rewrites the entire DB but preserves the auto_vacuum header).
BEGIN;
ALTER TABLE t ADD COLUMN tag INTEGER DEFAULT 0;
CREATE INDEX idx_tag ON t(tag);
COMMIT;
VACUUM;
