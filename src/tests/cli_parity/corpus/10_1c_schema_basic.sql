-- 10.1c schema: basic schema introspection (TestShellSchema.SCRIPT_BasicSchema)
CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE child(id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES parent);
CREATE INDEX child_p ON child(p_id);
CREATE VIEW v_names AS SELECT name FROM parent;
CREATE TRIGGER trg AFTER INSERT ON parent BEGIN
  UPDATE parent SET name = NEW.name WHERE id = NEW.id;
END;
.schema
.indexes child
