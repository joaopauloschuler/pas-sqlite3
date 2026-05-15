-- fts5.db — full-text-search v5 virtual table.  SKIP-TAGGED in the
-- MANIFEST: the FTS5 extension (../sqlite3/ext/fts5/*) has not been
-- ported to Pascal yet, so producing a vector that the port could not
-- read back would be misleading.  Script is committed so once the
-- extension lands, regen.sh can mint the .db blob.
--
-- Reference: ../sqlite3/ext/fts5/fts5.h (sqlite3Fts5Init),
-- ../sqlite3/ext/fts5/fts5_main.c (CREATE VIRTUAL TABLE USING fts5).
PRAGMA page_size = 4096;
CREATE VIRTUAL TABLE docs USING fts5(title, body);
INSERT INTO docs(title, body) VALUES('alpha', 'the quick brown fox');
INSERT INTO docs(title, body) VALUES('beta', 'jumps over the lazy dog');
INSERT INTO docs(title, body) VALUES('gamma', 'sphinx of black quartz');
