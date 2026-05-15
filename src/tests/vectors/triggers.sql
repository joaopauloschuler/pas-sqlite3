-- triggers.db — BEFORE/AFTER row triggers on INSERT/UPDATE/DELETE,
-- plus an INSTEAD OF trigger on a view.  Reference: ../sqlite3/src/trigger.c
-- (sqlite3CodeRowTrigger), build.c (sqlite3FinishTrigger).
PRAGMA page_size = 4096;
CREATE TABLE src(id INTEGER PRIMARY KEY, val TEXT);
CREATE TABLE log(seq INTEGER PRIMARY KEY AUTOINCREMENT, evt TEXT);
CREATE TRIGGER trg_ins AFTER INSERT ON src BEGIN
  INSERT INTO log(evt) VALUES('ins:' || NEW.id);
END;
CREATE TRIGGER trg_upd AFTER UPDATE ON src BEGIN
  INSERT INTO log(evt) VALUES('upd:' || OLD.id || '->' || NEW.val);
END;
CREATE TRIGGER trg_del BEFORE DELETE ON src BEGIN
  INSERT INTO log(evt) VALUES('del:' || OLD.id);
END;
CREATE VIEW v AS SELECT id, val FROM src;
CREATE TRIGGER trg_v INSTEAD OF INSERT ON v BEGIN
  INSERT INTO src VALUES(NEW.id, 'via-view:' || NEW.val);
END;
INSERT INTO src VALUES(1,'a');
INSERT INTO src VALUES(2,'b');
UPDATE src SET val='B' WHERE id=2;
INSERT INTO v VALUES(3,'c');
DELETE FROM src WHERE id=1;
