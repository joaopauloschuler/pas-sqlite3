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
  DiagFunctions — exploratory probe for built-in scalar functions and
  type-affinity / coercion edge cases.  Goal: surface bugs not yet
  captured in tasklist.md.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagFunctions.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagFunctions
}
program DiagFunctions;


uses
  DiagCommon;

begin
  // --- typeof ---
  ProbeOne('typeof int',     'SELECT typeof(5)');
  ProbeOne('typeof real',    'SELECT typeof(5.0)');
  ProbeOne('typeof text',    'SELECT typeof(''hi'')');
  ProbeOne('typeof null',    'SELECT typeof(NULL)');
  ProbeOne('typeof blob',    'SELECT typeof(X''00ff'')');

  // --- length ---
  ProbeOne('length text',    'SELECT length(''abc'')');
  ProbeOne('length empty',   'SELECT length('''')');
  ProbeOne('length null',    'SELECT length(NULL)');
  ProbeOne('length blob',    'SELECT length(X''0102'')');

  // --- substr ---
  ProbeOne('substr basic',   'SELECT substr(''hello'', 2, 3)');
  ProbeOne('substr neg',     'SELECT substr(''hello'', -3, 2)');
  ProbeOne('substr 2arg',    'SELECT substr(''hello'', 3)');
  ProbeOne('substr past',    'SELECT substr(''abc'', 5)');
  ProbeOne('substr utf8 1',  'SELECT substr(''café'', 4, 1)');
  ProbeOne('substr utf8 2',  'SELECT substr(''日本語'', 2, 1)');
  ProbeOne('substr utf8 neg','SELECT substr(''日本語'', -2, 1)');

  // --- case conversion ---
  ProbeOne('lower',          'SELECT lower(''ABC'')');
  ProbeOne('upper',          'SELECT upper(''abc'')');

  // --- trim ---
  ProbeOne('trim default',   'SELECT trim(''   x   '')');
  ProbeOne('ltrim',          'SELECT ltrim(''   x   '')');
  ProbeOne('rtrim',          'SELECT rtrim(''   x   '')');
  ProbeOne('trim chars',     'SELECT trim(''xxhelloxx'', ''x'')');

  // --- replace / instr ---
  ProbeOne('replace',        'SELECT replace(''abc'', ''b'', ''XY'')');
  ProbeOne('replace null pat',  'SELECT replace(''abc'', NULL, ''b'')');
  ProbeOne('replace null rep',  'SELECT replace(''abc'', ''a'', NULL)');
  ProbeOne('replace null str',  'SELECT replace(NULL, ''a'', ''b'')');
  ProbeOne('replace empty pat', 'SELECT replace(''abc'', '''', ''XY'')');
  ProbeOne('instr found',    'SELECT instr(''abcde'', ''cd'')');
  ProbeOne('instr not',      'SELECT instr(''abcde'', ''zz'')');

  // --- hex / unhex ---
  ProbeOne('hex int',        'SELECT hex(0)');
  ProbeOne('hex blob',       'SELECT hex(X''ab12'')');
  ProbeOne('hex text',       'SELECT hex(''abc'')');

  // --- char / unicode ---
  ProbeOne('char(65,66)',    'SELECT char(65,66)');
  ProbeOne('unicode',        'SELECT unicode(''A'')');

  // --- abs / nullif / ifnull ---
  ProbeOne('abs neg',        'SELECT abs(-7)');
  ProbeOne('abs null',       'SELECT abs(NULL)');
  ProbeOne('abs real',       'SELECT abs(-3.14)');
  ProbeOne('nullif eq',      'SELECT nullif(1, 1)');
  ProbeOne('nullif ne',      'SELECT nullif(1, 2)');
  ProbeOne('ifnull',         'SELECT ifnull(NULL, 7)');

  // --- min/max scalar (variadic) ---
  ProbeOne('min2',           'SELECT min(3, 5)');
  ProbeOne('max2',           'SELECT max(3, 5)');
  ProbeOne('min3 with null', 'SELECT min(3, NULL, 5)');

  // --- min/max aggregate over only-NULL rows (10.1.bug.117 regression) ---
  ProbeOne('agg min all null',
    'SELECT typeof(min(x)), min(x) FROM (SELECT NULL AS x)');
  ProbeOne('agg max all null',
    'SELECT typeof(max(x)), max(x) FROM (SELECT NULL AS x)');
  ProbeOne('agg min mix null',
    'SELECT min(x), max(x) FROM (SELECT NULL AS x UNION ALL SELECT 5)');

  // --- arithmetic / coercion ---
  ProbeOne('text+int',       'SELECT ''5''+3');
  ProbeOne('int=real',       'SELECT 1=1.0');
  ProbeOne('div by zero',    'SELECT 5/0');
  ProbeOne('mod',            'SELECT 7 % 3');
  ProbeOne('shift left',     'SELECT 1 << 4');
  ProbeOne('shift right',    'SELECT 16 >> 2');
  ProbeOne('bitand',         'SELECT 12 & 10');
  ProbeOne('bitor',          'SELECT 12 | 1');
  ProbeOne('bitnot',         'SELECT ~0');

  // --- CAST edge cases ---
  ProbeOne('cast real to int',  'SELECT CAST(3.7 AS INTEGER)');
  ProbeOne('cast text to real', 'SELECT CAST(''3.5'' AS REAL)');
  ProbeOne('cast text empty',   'SELECT CAST('''' AS INTEGER)');
  ProbeOne('cast null',         'SELECT CAST(NULL AS INTEGER)');

  // --- BLOB literal & X'' ---
  ProbeOne('blob literal',  'SELECT X''0102''');
  ProbeOne('blob length',   'SELECT length(X''00112233'')');

  // --- printf ---
  ProbeOne('printf %d',     'SELECT printf(''%d'', 42)');
  ProbeOne('printf %s',     'SELECT printf(''%s'', ''hi'')');
  ProbeOne('printf %.2f',   'SELECT printf(''%.2f'', 3.14159)');

  // --- coalesce edges ---
  ProbeOne('coalesce all null', 'SELECT coalesce(NULL,NULL)');
  ProbeOne('coalesce mixed',    'SELECT coalesce(NULL,2,NULL)');

  // --- random / randomblob ---
  // Don't compare values (non-deterministic), just typeof.
  ProbeOne('typeof random',     'SELECT typeof(random())');

  // --- LIKE / GLOB without table ---
  ProbeOne('LIKE literal',      'SELECT ''abc'' LIKE ''a%''');
  ProbeOne('GLOB literal',      'SELECT ''abc'' GLOB ''a*''');

  // --- Integer overflow / extremes ---
  ProbeOne('max int',           'SELECT 9223372036854775807');
  ProbeOne('min int',           'SELECT -9223372036854775808');
  ProbeOne('overflow add',      'SELECT 9223372036854775807 + 1');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
