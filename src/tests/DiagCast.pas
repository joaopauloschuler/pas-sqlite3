{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  This is a faithful port of SQLite 3.53 (https://sqlite.org/) from C to
  Free Pascal, authored by Dr. Joao Paulo Schwarz Schuler and contributors
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
{$I ../passqlite3.inc}
{
  DiagCast — exploratory probe for CAST expressions and type-affinity
  coercion edges.  Goal: surface bugs not yet captured in tasklist.md.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagCast.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagCast
}
program DiagCast;


uses
  DiagCommon;

begin
  // --- CAST AS INTEGER ---
  ProbeOne('cast text->int',    'SELECT CAST(''42'' AS INTEGER)');
  ProbeOne('cast text->int neg','SELECT CAST(''-17'' AS INTEGER)');
  ProbeOne('cast text->int trail','SELECT CAST(''42abc'' AS INTEGER)');
  ProbeOne('cast text->int empty','SELECT CAST('''' AS INTEGER)');
  ProbeOne('cast text->int hex', 'SELECT CAST(''0x10'' AS INTEGER)');
  ProbeOne('cast real->int',     'SELECT CAST(3.7 AS INTEGER)');
  ProbeOne('cast real->int neg', 'SELECT CAST(-3.7 AS INTEGER)');
  ProbeOne('cast real->int huge','SELECT CAST(9.0e18 AS INTEGER)');
  ProbeOne('cast null->int',     'SELECT CAST(NULL AS INTEGER)');

  // --- CAST AS TEXT ---
  ProbeOne('cast int->text',     'SELECT CAST(42 AS TEXT)');
  ProbeOne('cast real->text',    'SELECT CAST(3.5 AS TEXT)');
  ProbeOne('cast null->text',    'SELECT CAST(NULL AS TEXT)');
  ProbeOne('cast blob->text',    'SELECT CAST(X''4142'' AS TEXT)');

  // --- CAST AS REAL ---
  ProbeOne('cast int->real',     'SELECT CAST(7 AS REAL)');
  ProbeOne('cast text->real',    'SELECT CAST(''3.14'' AS REAL)');
  ProbeOne('cast text->real bad','SELECT CAST(''abc'' AS REAL)');
  ProbeOne('cast null->real',    'SELECT CAST(NULL AS REAL)');

  // --- CAST AS NUMERIC ---
  ProbeOne('cast text num int',  'SELECT CAST(''42'' AS NUMERIC)');
  ProbeOne('cast text num real', 'SELECT CAST(''3.14'' AS NUMERIC)');
  ProbeOne('cast text num bad',  'SELECT CAST(''hi'' AS NUMERIC)');

  // --- CAST AS BLOB ---
  ProbeOne('cast text->blob',    'SELECT length(CAST(''abc'' AS BLOB))');
  ProbeOne('cast int->blob len', 'SELECT length(CAST(42 AS BLOB))');
  ProbeOne('cast typeof blob',   'SELECT typeof(CAST(''hi'' AS BLOB))');

  // --- typeof on CAST ---
  ProbeOne('typeof cast int',    'SELECT typeof(CAST(''3'' AS INTEGER))');
  ProbeOne('typeof cast real',   'SELECT typeof(CAST(3 AS REAL))');
  ProbeOne('typeof cast text',   'SELECT typeof(CAST(3.0 AS TEXT))');
  ProbeOne('typeof cast num int','SELECT typeof(CAST(''3'' AS NUMERIC))');
  ProbeOne('typeof cast num real','SELECT typeof(CAST(''3.5'' AS NUMERIC))');

  // --- arithmetic coercion ---
  ProbeOne('text + int',         'SELECT ''3''+4');
  ProbeOne('text * int',         'SELECT ''2''*3');
  ProbeOne('null + int',         'SELECT NULL+1');
  ProbeOne('int / 0',            'SELECT 5/0');
  ProbeOne('real / 0',           'SELECT 5.0/0.0');
  ProbeOne('mod neg',            'SELECT -7%3');
  ProbeOne('div neg',            'SELECT -7/3');
  ProbeOne('large int overflow', 'SELECT 9223372036854775807+1');

  // --- comparison coercion ---
  ProbeOne('text=int',           'SELECT ''1''=1');
  ProbeOne('text<int',           'SELECT ''9''<10');
  ProbeOne('null=null',          'SELECT NULL=NULL');
  ProbeOne('null IS null',       'SELECT NULL IS NULL');

  // --- abs / + - unary ---
  ProbeOne('abs neg int',        'SELECT abs(-5)');
  ProbeOne('abs neg real',       'SELECT abs(-3.5)');
  ProbeOne('abs text',           'SELECT abs(''3.5'')');
  ProbeOne('abs null',           'SELECT abs(NULL)');
  ProbeOne('abs INT_MIN',        'SELECT abs(-9223372036854775808)');

  // --- coalesce / ifnull / nullif ---
  ProbeOne('coalesce 1',         'SELECT coalesce(NULL,NULL,3,4)');
  ProbeOne('ifnull null',        'SELECT ifnull(NULL,7)');
  ProbeOne('ifnull val',         'SELECT ifnull(2,7)');
  ProbeOne('nullif eq',          'SELECT nullif(3,3)');
  ProbeOne('nullif neq',         'SELECT nullif(3,4)');

  // --- iif / case ---
  ProbeOne('iif true',           'SELECT iif(1,''a'',''b'')');
  ProbeOne('iif false',          'SELECT iif(0,''a'',''b'')');
  ProbeOne('case simple',        'SELECT CASE 2 WHEN 1 THEN ''x'' WHEN 2 THEN ''y'' ELSE ''z'' END');
  ProbeOne('case search',        'SELECT CASE WHEN 1>2 THEN ''a'' ELSE ''b'' END');
  ProbeOne('case null else',     'SELECT CASE WHEN 0 THEN ''a'' END');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
