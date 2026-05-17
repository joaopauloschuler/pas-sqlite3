-- kitchen sink: ATTACH/DETACH a second :memory: DB and cross-DB query
ATTACH DATABASE ':memory:' AS aux;
CREATE TABLE main.tm(id INTEGER PRIMARY KEY, m TEXT);
CREATE TABLE aux.ta (id INTEGER PRIMARY KEY, a TEXT);
INSERT INTO main.tm VALUES(1,'main-one'),(2,'main-two');
INSERT INTO aux.ta  VALUES(1,'aux-one'),(2,'aux-two');
.databases
.headers on
.mode list
SELECT m.id, m.m, a.a FROM main.tm m JOIN aux.ta a USING(id) ORDER BY m.id;
DETACH DATABASE aux;
.databases
