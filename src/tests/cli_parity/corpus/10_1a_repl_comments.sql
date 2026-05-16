-- 10.1a REPL: comments (extracted from TestShellRepl.SCRIPT_Comments)
-- single-line comment before SQL
SELECT 1; -- trailing single-line
/* block comment */ SELECT 2;
SELECT /* mid */ 3;
/* multi
   line
   block */
SELECT 4;
