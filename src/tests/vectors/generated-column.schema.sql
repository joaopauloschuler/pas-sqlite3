-- generated-column.db.schema.sql — 9.2.4 schema-change probe.
-- ALTER TABLE on a table with VIRTUAL/STORED generated cols.  build.c
-- sqlite3AlterFinishAddColumn permits ADD COLUMN with a constant default
-- and another VIRTUAL generated column (STORED is rejected on ADD; see
-- alter.c sqlite3AlterFinishAddColumn).  CREATE INDEX over the virtual
-- col, then VACUUM.
BEGIN;
ALTER TABLE t ADD COLUMN extra TEXT DEFAULT 'x';
ALTER TABLE t ADD COLUMN e INTEGER GENERATED ALWAYS AS (a - b) VIRTUAL;
CREATE INDEX idx_c ON t(c);
COMMIT;
