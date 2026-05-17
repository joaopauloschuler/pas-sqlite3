-- kitchen sink: .dump of a populated schema (round-trip via .read is tested
-- in the run_corpus.sh `dump_read_roundtrip` step which dumps DB-A to a file
-- and .reads it into DB-B, then diffs schema+rows).
CREATE TABLE u(id INTEGER PRIMARY KEY, t TEXT);
CREATE INDEX ui ON u(t);
CREATE VIEW vu AS SELECT id FROM u;
INSERT INTO u VALUES(1,'alpha'),(2,'beta'),(3,'gamma');
.dump
