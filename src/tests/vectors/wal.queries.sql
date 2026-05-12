-- wal.db.queries.sql — 9.2.2 read-only parity probe.
-- Reads the WAL-mode db (header bytes 18..19 = 02 02) without the
-- .db-wal sidecar; the C shell's clean shutdown final-checkpointed
-- and removed the sidecar so all rows are now in the main file.
PRAGMA page_size;
SELECT id, length(val) FROM t ORDER BY id;
SELECT count(*) FROM t;
SELECT name, type FROM sqlite_master WHERE type='table';
