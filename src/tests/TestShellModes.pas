{
  SPDX-License-Identifier: blessing

  TestShellModes — phase 10.1b gate.  Drives the passqlite3 CLI through
  every output mode (.mode list/line/column/csv/tabs/html/insert/quote/
  json/markdown/table/box/tcl/ascii) plus .headers / .separator /
  .nullvalue / .width / .print, and diffs the byte stream against the
  upstream sqlite3 binary (the same canon used by all other 10.1 gates).

  Fixed regressions:
    * MODE_Column / MODE_Table / MODE_Box left-aligned every cell.
      qrf.c:1514 right-aligns numeric (INTEGER/FLOAT) columns by
      default; mixing in any TEXT/BLOB cell flips the column back to
      left-align.  A negative .width N forces right-align regardless
      of types (qrf.c:1696).

  Skips cleanly with PASS if the upstream sqlite3 binary is unavailable
  on PATH or at $UPSTREAM_SQLITE3 — keeps build green on stripped CI
  while still gating locally.
}
{$I ../passqlite3.inc}
program TestShellModes;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util,
  TestShellCommon;

var
  failCount: i32 = 0;
  passCount: i32 = 0;

procedure DiffCase(const name, sql: AnsiString; upstream: AnsiString);
begin
  ShellDiffCase('pas_modes_', name, sql, upstream, passCount, failCount);
end;

const
  { Exercises every column-mode renderer plus .headers/.separator/
    .nullvalue/.width and .print formatting controls.  Three rows with
    INTEGER / TEXT / REAL columns so numeric right-align vs text
    left-align is visible in MODE_Column/Table/Box. }
  SCRIPT_AllModes =
    'CREATE TABLE t(a INTEGER, b TEXT, c REAL);'#10 +
    'INSERT INTO t VALUES(1,''one'',1.5),(2,''two'',NULL),'+
                       '(3,''three'',3.14);'#10 +
    '.headers on'#10 +
    '.mode list'#10     + 'SELECT * FROM t;'#10 +
    '.mode line'#10     + 'SELECT * FROM t;'#10 +
    '.mode column'#10   + 'SELECT * FROM t;'#10 +
    '.mode csv'#10      + 'SELECT * FROM t;'#10 +
    '.mode tabs'#10     + 'SELECT * FROM t;'#10 +
    '.mode html'#10     + 'SELECT * FROM t;'#10 +
    '.mode insert tt'#10+ 'SELECT * FROM t;'#10 +
    '.mode quote'#10    + 'SELECT * FROM t;'#10 +
    '.mode json'#10     + 'SELECT * FROM t;'#10 +
    '.mode markdown'#10 + 'SELECT * FROM t;'#10 +
    '.mode table'#10    + 'SELECT * FROM t;'#10 +
    '.mode box'#10      + 'SELECT * FROM t;'#10 +
    '.mode tcl'#10      + 'SELECT * FROM t;'#10 +
    '.mode ascii'#10    + 'SELECT * FROM t;'#10 +
    '.headers off'#10 +
    '.nullvalue NIL'#10 +
    '.separator |~| @'#10 +
    '.mode list'#10     + 'SELECT * FROM t;'#10 +
    '.separator | @'#10 +
    '.width 5 10 5'#10 +
    '.mode column'#10 +
    '.headers on'#10 +
    'SELECT * FROM t;'#10 +
    '.width -5 -10 -5'#10 +
    'SELECT * FROM t;'#10 +
    '.print Hello, World'#10;

  { Right-align is type-driven: a TEXT cell in the second column forces
    that column to left-align even though the first row's value would
    parse as a number on its own.  Catches the regression where the
    type-tracking only checked the first row. }
  SCRIPT_MixedTypes =
    'CREATE TABLE m(x);'#10 +
    'INSERT INTO m VALUES(1),(2),(''abc'');'#10 +
    '.mode column'#10 +
    '.headers on'#10 +
    'SELECT * FROM m;'#10;

var
  upstream: AnsiString;

begin
  upstream := FindUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestShellModes: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  WriteLn('Using upstream: ', upstream);

  DiffCase('all modes parity',  SCRIPT_AllModes,   upstream);
  DiffCase('mixed-type column', SCRIPT_MixedTypes, upstream);

  WriteLn;
  WriteLn(Format('TestShellModes: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
