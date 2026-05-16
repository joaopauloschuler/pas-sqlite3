-- 10.1b modes: mixed-type column (TestShellModes.SCRIPT_MixedTypes)
CREATE TABLE m(x);
INSERT INTO m VALUES(1),(2),('abc');
.mode column
.headers on
SELECT * FROM m;
