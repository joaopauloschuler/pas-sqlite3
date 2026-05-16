-- 10.1a REPL: strings + quoted identifiers (TestShellRepl.SCRIPT_Strings)
SELECT 'foo''bar' AS "col with spaces";
CREATE TABLE q("c 1", "c 2");
INSERT INTO q VALUES('a''b', 'x"y');
SELECT "c 1", "c 2" FROM q;
