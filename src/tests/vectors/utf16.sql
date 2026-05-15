-- utf16.db — UTF-16le encoding.  PRAGMA encoding must precede any
-- schema activity (it locks at first write).  File header byte
-- 56..59 (text encoding) ends up as 2 (UTF-16le).  Reference:
-- ../sqlite3/src/pragma.c (encoding pragma) + util.c (sqlite3VdbeMemSetStr
-- with SQLITE_UTF16LE).  Strings exercised include a non-BMP code
-- point (U+1F600 GRINNING FACE) so surrogate pairs are present.
PRAGMA encoding = 'UTF-16le';
PRAGMA page_size = 4096;
CREATE TABLE t(id INTEGER PRIMARY KEY, label TEXT);
INSERT INTO t VALUES(1, 'ascii');
INSERT INTO t VALUES(2, 'caf' || char(0xE9));
INSERT INTO t VALUES(3, char(0x4E2D, 0x6587));
INSERT INTO t VALUES(4, char(0x1F600));
