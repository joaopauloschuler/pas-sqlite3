-- kitchen sink: mode switching mid-stream
CREATE TABLE k(id INTEGER PRIMARY KEY, label TEXT, v REAL);
INSERT INTO k VALUES(1,'one',1.1),(2,'two',2.2),(3,'three',3.3);
.headers on
.mode csv
SELECT * FROM k WHERE id < 3;
.mode json
SELECT * FROM k WHERE id >= 2;
.mode line
SELECT id, label FROM k ORDER BY id DESC LIMIT 2;
.mode markdown
SELECT label, v FROM k;
.mode list
.separator ::
SELECT id, label, v FROM k;
