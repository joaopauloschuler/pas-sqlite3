-- view-cte.db.schema.sql — 9.2.4 schema-change probe.
-- view-cte vector already has a VIEW (v_doubled) and a materialised CTE
-- table (cte_seed).  Exercise ALTER on the base table, drop a column,
-- create a partial index, then VACUUM.
BEGIN;
ALTER TABLE base ADD COLUMN label TEXT DEFAULT 'x';
ALTER TABLE base RENAME COLUMN n TO value;
CREATE INDEX idx_base_label ON base(label) WHERE label <> 'x';
ALTER TABLE cte_seed RENAME TO cte_snapshot;
COMMIT;
VACUUM;
