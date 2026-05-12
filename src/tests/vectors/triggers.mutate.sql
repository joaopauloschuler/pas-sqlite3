-- triggers.db.mutate.sql — 9.2.3 round-trip probe.
-- Each mutator trips one of the BEFORE/AFTER/INSTEAD OF triggers and
-- appends to the log table.  Reference: ../sqlite3/src/trigger.c
-- (sqlite3CodeRowTrigger).
BEGIN;
INSERT INTO src VALUES(10,'x');           -- fires trg_ins
UPDATE src SET val='Z' WHERE id=10;        -- fires trg_upd
INSERT INTO v VALUES(11,'y');              -- fires trg_v (INSTEAD OF) → trg_ins
DELETE FROM src WHERE id=2;                -- fires trg_del (BEFORE)
COMMIT;
