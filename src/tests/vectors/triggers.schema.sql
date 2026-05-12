-- triggers.db.schema.sql — 9.2.4 schema-change probe.
-- ALTER TABLE on the trigger-source table.  We avoid renaming `val`
-- because INSTEAD OF trigger trg_v references NEW.val (alter.c
-- renameColumnFunc would propagate the rename through the view
-- definition but the view exposes col `val` so the trigger body would
-- need a corresponding rewrite — a divergence vector for a future
-- ticket, not for this gate).  We exercise ADD COLUMN on src and log,
-- a CREATE INDEX, and VACUUM (which rewrites trigger bodies via
-- sqlite_schema rewrite).
BEGIN;
ALTER TABLE src ADD COLUMN aux TEXT;
ALTER TABLE log ADD COLUMN ts INTEGER DEFAULT 0;
CREATE INDEX idx_log_evt ON log(evt);
COMMIT;
