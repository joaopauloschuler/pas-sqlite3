{
  SPDX-License-Identifier: blessing

  TestShellSchema — phase 10.1c gate.  Drives the passqlite3 CLI through
  the schema-introspection dot-commands (.schema, .tables, .indexes,
  .databases, .fullschema) and diffs the byte stream against the
  upstream sqlite3 binary.

  Fixed regressions exercised by this gate:
    * sqlite3EndTable wrote `CREATE view ...` (lowercase) into
      sqlite_schema.sql for VIEW objects because zType2 was 'view'.
      Upstream uses 'VIEW' (build.c:2814).  The lowercase keyword broke
      shell_add_schema's prefix match in turn, so .schema for views
      never gained the `/* viewname(col,...) */` annotation either.

  .lint fkey-indexes (10.1c.6) is now exercised here — bug 6.16 (and
  the underlying bug 6.13 sub-bug B family) closed, so the lateral
  pragma_foreign_key_list join runs byte-identical with upstream.
  .expert (10.1c.7) is still a stub and stays out of the gate.

  Skips cleanly with PASS if the upstream sqlite3 binary is unavailable
  on PATH or at $UPSTREAM_SQLITE3 — keeps build green on stripped CI
  while still gating locally.
}
{$I ../passqlite3.inc}
program TestShellSchema;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util,
  TestShellCommon;

var
  failCount: i32 = 0;
  passCount: i32 = 0;

procedure DiffCase(const name, sql: AnsiString; upstream: AnsiString);
begin
  ShellDiffCase('pas_schema_', name, sql, upstream, passCount, failCount);
end;

const
  { Mixed schema: TABLE + INDEX + VIEW + TRIGGER.  Exercises .schema's
    shell_add_schema VIEW/TRIGGER annotations and .indexes filtering by
    table.  .tables and .indexes (no arg) deliberately get their own
    single-result scripts below — upstream's MODE_Split column widening
    differs from our hand-rolled column renderer on multi-result rows,
    and `.indexes` (no arg) materializes the temp schema on upstream
    only.  Both are pre-existing divergences (tracked separately) and
    are not part of the 10.1c gate's intent. }
  SCRIPT_BasicSchema =
    'CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT);'#10 +
    'CREATE TABLE child(id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES parent);'#10 +
    'CREATE INDEX child_p ON child(p_id);'#10 +
    'CREATE VIEW v_names AS SELECT name FROM parent;'#10 +
    'CREATE TRIGGER trg AFTER INSERT ON parent BEGIN'#10 +
    '  UPDATE parent SET name = NEW.name WHERE id = NEW.id;'#10 +
    'END;'#10 +
    '.schema'#10 +
    '.indexes child'#10;

  { .databases alone — running it after .indexes opens the temp schema
    upstream (a pre-existing port divergence). }
  SCRIPT_Databases =
    'CREATE TABLE only(x);'#10 +
    '.databases'#10;

  { .tables with a single result avoids the MODE_Split column-width
    divergence on multi-result rows. }
  SCRIPT_TablesSingle =
    'CREATE TABLE only_one(x);'#10 +
    '.tables'#10 +
    '.tables only_one'#10;

  { .schema with a LIKE pattern. }
  SCRIPT_SchemaPattern =
    'CREATE TABLE alpha(x);'#10 +
    'CREATE TABLE beta(x);'#10 +
    'CREATE TABLE gamma(x);'#10 +
    '.schema alpha'#10 +
    '.schema a%'#10;

  { .schema --indent on a real CREATE TABLE so the pretty-printer is
    exercised end to end. }
  SCRIPT_SchemaIndent =
    'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT NOT NULL,'#10 +
    '               c REAL, d BLOB, UNIQUE(b,c));'#10 +
    'CREATE INDEX ti ON t(b);'#10 +
    '.schema --indent'#10;

  { .schema --nosys keeps sqlite_* internal tables off the wire. }
  SCRIPT_SchemaNoSys =
    'CREATE TABLE foo(x INTEGER PRIMARY KEY AUTOINCREMENT, y TEXT);'#10 +
    'INSERT INTO foo(y) VALUES (''a''),(''b'');'#10 +
    '.schema'#10 +
    '.schema --nosys'#10;

  { .fullschema (no STAT tables, so it tails the canonical
    "/* No STAT tables available */" trailer). }
  SCRIPT_FullSchema =
    'CREATE TABLE t(a,b);'#10 +
    'CREATE INDEX ti ON t(a);'#10 +
    '.fullschema'#10;

  { .lint fkey-indexes — child has an FK to parent and a covering
    index; orphan has an FK to parent and no covering index.  Upstream
    emits a CREATE INDEX suggestion for orphan only.  Exercises the
    lateral `pragma_foreign_key_list(s.name)` join end-to-end (bug 6.13
    sub-bug B + bug 6.16). }
  SCRIPT_LintFkeyIndexes =
    'CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT);'#10 +
    'CREATE TABLE child(aid INTEGER REFERENCES parent(id));'#10 +
    'CREATE INDEX child_aid ON child(aid);'#10 +
    'CREATE TABLE orphan(aid INTEGER REFERENCES parent(id));'#10 +
    '.lint fkey-indexes'#10;

  { Multi-column FK locks in the sorter tie-stability fix (bug 6.13
    residual): with two FK columns sharing identical (s.name, f.id) sort
    keys, group_concat must emit them in seq order (x, y) — the
    pre-fix port reversed them to (y, x) because vdbeSorterCompareRec
    left UnpackedRecord.default_rc uninitialized and the in-memory list
    walked head→tail in reverse insertion order. }
  SCRIPT_LintFkeyIndexesMulti =
    'CREATE TABLE parent(a PRIMARY KEY, b);'#10 +
    'CREATE TABLE child(x, y, FOREIGN KEY(x,y) REFERENCES parent);'#10 +
    '.lint fkey-indexes'#10;

  { Empty database edges: .tables / .schema on a fresh DB.  Skip
    .indexes / .databases here — both side-effects from upstream
    temp-schema materialization (port divergence). }
  SCRIPT_Empty =
    '.tables'#10 +
    '.schema'#10;

var
  upstream: AnsiString;

begin
  upstream := FindUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestShellSchema: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  WriteLn('Using upstream: ', upstream);

  DiffCase('basic schema',                SCRIPT_BasicSchema,   upstream);
  DiffCase('.tables single-result',       SCRIPT_TablesSingle,  upstream);
  DiffCase('.schema pattern',             SCRIPT_SchemaPattern, upstream);
  DiffCase('.schema --indent',            SCRIPT_SchemaIndent,  upstream);
  DiffCase('.schema --nosys',             SCRIPT_SchemaNoSys,   upstream);
  DiffCase('.fullschema',                 SCRIPT_FullSchema,    upstream);
  DiffCase('.databases',                  SCRIPT_Databases,     upstream);
  DiffCase('.lint fkey-indexes',          SCRIPT_LintFkeyIndexes, upstream);
  DiffCase('.lint fkey-indexes multi-col',SCRIPT_LintFkeyIndexesMulti, upstream);
  DiffCase('empty database',              SCRIPT_Empty,         upstream);

  WriteLn;
  WriteLn(Format('TestShellSchema: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
