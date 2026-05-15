-- rtree.db — R*Tree spatial-index virtual table.  SKIP-TAGGED in the
-- MANIFEST: ../sqlite3/ext/rtree/rtree.c has not been ported.  Script
-- committed so regen.sh produces the blob once the extension lands.
--
-- Reference: ../sqlite3/ext/rtree/rtree.c (sqlite3RtreeInit).
PRAGMA page_size = 4096;
CREATE VIRTUAL TABLE shapes USING rtree(id, minX, maxX, minY, maxY);
INSERT INTO shapes VALUES(1, 0.0, 1.0, 0.0, 1.0);
INSERT INTO shapes VALUES(2, 1.5, 2.5, 1.5, 2.5);
INSERT INTO shapes VALUES(3, -1.0, 0.5, -1.0, 0.5);
