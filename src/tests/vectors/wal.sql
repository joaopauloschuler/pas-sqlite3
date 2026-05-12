-- wal.db — database in journal_mode=WAL after a passive checkpoint.
--
-- Limitation: the truly "mid-checkpoint" sidecar (.db-wal) embeds a
-- random 64-bit salt header generated at WAL creation, so the WAL file
-- itself cannot be made byte-deterministic via the C shell.  We commit
-- only the .db blob; bytes 18..19 in the file header are 0x02 0x02
-- (read+write format = WAL).  See MANIFEST.txt entry for the full note
-- and ../sqlite3/src/wal.c (walIndexHdr / walRestartHdr) for why.
--
-- The persist_wal + wal_autocheckpoint=0 incantations ensure the .db
-- file's logical state reflects "passive-checkpointed but more frames
-- followed it" rather than the shell-shutdown final-checkpoint state.
PRAGMA page_size = 4096;
PRAGMA journal_mode = WAL;
PRAGMA wal_autocheckpoint = 0;
.filectrl persist_wal 1
CREATE TABLE t(id INTEGER PRIMARY KEY, val TEXT);
INSERT INTO t VALUES(1, printf('%.*c',1000,'a'));
INSERT INTO t VALUES(2, printf('%.*c',1000,'b'));
INSERT INTO t VALUES(3, printf('%.*c',1000,'c'));
PRAGMA wal_checkpoint(PASSIVE);
INSERT INTO t VALUES(4, printf('%.*c',1000,'d'));
INSERT INTO t VALUES(5, printf('%.*c',1000,'e'));
