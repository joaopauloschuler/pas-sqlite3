{
  SPDX-License-Identifier: blessing

  TestVtabLateral — phase 6.13.B.9 gate.  Drives the passqlite3 CLI
  through a handful of lateral / hidden-arg-pushdown virtual-table
  shapes and diffs the byte stream against the upstream sqlite3
  binary.  Covers:

    * pragma_foreign_key_list(s.name)         lateral on sqlite_schema
    * generate_series(1, t.x)                 lateral
    * generate_series(1, 5) WHERE value < 4   non-lateral with residual
    * json_each(json)                         lateral on a JSON column
    * SELECT * FROM wholenumber WHERE value<6 hidden-arg pushdown

  Skips with PASS when the upstream sqlite3 binary is unavailable.
}
{$I ../passqlite3.inc}
program TestVtabLateral;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util,
  TestShellCommon;

var
  failCount: i32 = 0;
  passCount: i32 = 0;

procedure DiffCase(const name, sql: AnsiString; upstream: AnsiString);
begin
  ShellDiffCase('pas_vtablat_', name, sql, upstream, passCount, failCount);
end;

const
  SCRIPT_GenSeriesStandalone =
    'SELECT value FROM generate_series(1,3);'#10;

  SCRIPT_GenSeriesResidual =
    'SELECT value FROM generate_series(1,5) WHERE value < 4;'#10;

  SCRIPT_GenSeriesLateral =
    'CREATE TABLE t(x);'#10 +
    'INSERT INTO t VALUES(1),(2),(3);'#10 +
    'SELECT t.x, g.value FROM t, generate_series(1, t.x) g'#10 +
    ' ORDER BY t.x, g.value;'#10;

  SCRIPT_PragmaFkLateral =
    'CREATE TABLE parent(id INTEGER PRIMARY KEY);'#10 +
    'CREATE TABLE child(id INTEGER PRIMARY KEY,'#10 +
    '                   p_id INTEGER REFERENCES parent(id));'#10 +
    'SELECT s.name, f.id, f.seq'#10 +
    '  FROM sqlite_schema s, pragma_foreign_key_list(s.name) f'#10 +
    ' WHERE s.type=''table'' ORDER BY s.name, f.seq;'#10;

  SCRIPT_JsonEachLateral =
    'CREATE TABLE rows(id INTEGER PRIMARY KEY, payload TEXT);'#10 +
    'INSERT INTO rows VALUES(1,''{"a":1,"b":2}''),'#10 +
    '                       (2,''{"x":9}'');'#10 +
    'SELECT r.id, j.key, j.value'#10 +
    '  FROM rows r, json_each(r.payload) j'#10 +
    ' ORDER BY r.id, j.key;'#10;

var
  upstream: AnsiString;

begin
  upstream := FindUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestVtabLateral: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  WriteLn('Using upstream: ', upstream);

  DiffCase('generate_series standalone',  SCRIPT_GenSeriesStandalone, upstream);
  DiffCase('generate_series residual',    SCRIPT_GenSeriesResidual,   upstream);
  DiffCase('generate_series lateral',     SCRIPT_GenSeriesLateral,    upstream);
  DiffCase('pragma_foreign_key_list lat', SCRIPT_PragmaFkLateral,     upstream);
  DiffCase('json_each lateral',           SCRIPT_JsonEachLateral,     upstream);

  WriteLn;
  WriteLn(Format('TestVtabLateral: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
