-- 10.1b modes: every output mode (TestShellModes.SCRIPT_AllModes)
CREATE TABLE t(a INTEGER, b TEXT, c REAL);
INSERT INTO t VALUES(1,'one',1.5),(2,'two',NULL),(3,'three',3.14);
.headers on
.mode list
SELECT * FROM t;
.mode line
SELECT * FROM t;
.mode column
SELECT * FROM t;
.mode csv
SELECT * FROM t;
.mode tabs
SELECT * FROM t;
.mode html
SELECT * FROM t;
.mode insert tt
SELECT * FROM t;
.mode quote
SELECT * FROM t;
.mode json
SELECT * FROM t;
.mode markdown
SELECT * FROM t;
.mode table
SELECT * FROM t;
.mode box
SELECT * FROM t;
.mode tcl
SELECT * FROM t;
.mode ascii
SELECT * FROM t;
.headers off
.nullvalue NIL
.mode list
SELECT * FROM t;
.print Hello, World
