-- utf16.db.queries.sql — 9.2.2 read-only parity probe.
-- Exercises text-encoding=UTF-16le header (56..59=2) + non-BMP
-- code-point round-trip through the UTF-8 callback contract.
PRAGMA encoding;
SELECT id, label, length(label), hex(label) FROM t ORDER BY id;
SELECT count(*) FROM t WHERE label LIKE 'caf%';
