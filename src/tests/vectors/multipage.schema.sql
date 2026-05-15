-- multipage.db.schema.sql — 9.2.4 schema-change probe.
-- 199-row table; CREATE INDEX exercises the b-tree builder over multiple
-- pages.  ALTER TABLE ADD COLUMN with non-trivial default writes the
-- DEFAULT into sqlite_master, then VACUUM rewrites the entire database.
BEGIN;
ALTER TABLE t ADD COLUMN tag INTEGER DEFAULT 0;
CREATE INDEX idx_t_val ON t(val);
CREATE INDEX idx_t_tag ON t(tag) WHERE tag <> 0;
COMMIT;
