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
  DiagMoreFunc — second-wave probe targeting built-in functions and
  expression edges not yet covered by DiagFunctions / DiagDate / DiagMisc /
  DiagFeatureProbe.  Goal: surface bugs not already on the tasklist.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagMoreFunc.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagMoreFunc
}
program DiagMoreFunc;


uses
  DiagCommon;

begin
  // --- iif / nullif edge cases ---
  ProbeOne('iif true',           'SELECT iif(1,''A'',''B'')');
  ProbeOne('iif false',          'SELECT iif(0,''A'',''B'')');
  ProbeOne('iif null cond',      'SELECT iif(NULL,''A'',''B'')');

  // --- format alias of printf ---
  ProbeOne('format %d',          'SELECT format(''%d'',42)');
  ProbeOne('format %05d',        'SELECT format(''%05d'',7)');
  ProbeOne('format %x',          'SELECT format(''%x'',255)');
  ProbeOne('format %X',          'SELECT format(''%X'',255)');
  ProbeOne('format %o',          'SELECT format(''%o'',8)');
  ProbeOne('format %%',          'SELECT format(''%%'')');
  ProbeOne('format %c',          'SELECT format(''%c'',65)');
  ProbeOne('format %-5d|',       'SELECT format(''|%-5d|'',7)');
  ProbeOne('format %+d pos',     'SELECT format(''%+d'',7)');
  ProbeOne('format %+d neg',     'SELECT format(''%+d'',-7)');
  ProbeOne('format %e',          'SELECT format(''%e'',1234.5)');
  ProbeOne('format %g',          'SELECT format(''%g'',1234.5)');

  // --- math functions (registered via build flag SQLITE_ENABLE_MATH_FUNCTIONS) ---
  // C upstream may or may not have it; both should agree on availability.
  ProbeOne('sqrt 4',             'SELECT sqrt(4)');
  ProbeOne('exp 0',              'SELECT exp(0)');
  ProbeOne('ln 1',               'SELECT ln(1)');
  ProbeOne('pow 2 10',           'SELECT pow(2,10)');
  ProbeOne('sin 0',              'SELECT sin(0)');
  ProbeOne('cos 0',              'SELECT cos(0)');
  ProbeOne('floor 3.7',          'SELECT floor(3.7)');
  ProbeOne('ceil 3.2',           'SELECT ceil(3.2)');
  ProbeOne('pi',                 'SELECT pi()');

  // --- BLOB helpers ---
  ProbeOne('zeroblob length',    'SELECT length(zeroblob(8))');
  ProbeOne('typeof zeroblob',    'SELECT typeof(zeroblob(4))');
  ProbeOne('typeof randomblob',  'SELECT typeof(randomblob(4))');
  ProbeOne('length randomblob',  'SELECT length(randomblob(8))');

  // --- unhex (newer fn) ---
  ProbeOne('unhex',              'SELECT length(unhex(''abcd''))');
  ProbeOne('unhex odd',          'SELECT typeof(unhex(''abc''))');

  // --- string concatenation operator ---
  ProbeOne('|| basic',           'SELECT ''a''||''b''');
  ProbeOne('|| with NULL',       'SELECT ''a''||NULL');
  ProbeOne('|| with int',        'SELECT ''x=''||5');

  // --- expression edges ---
  ProbeOne('NOT 0',              'SELECT NOT 0');
  ProbeOne('NOT NULL expr',      'SELECT typeof(NOT NULL)');
  ProbeOne('IS NULL',            'SELECT NULL IS NULL');
  ProbeOne('IS NOT NULL',        'SELECT 1 IS NOT NULL');
  ProbeOne('IS distinct',        'SELECT 1 IS NOT DISTINCT FROM 1');
  ProbeOne('BETWEEN true',       'SELECT 5 BETWEEN 1 AND 10');
  ProbeOne('BETWEEN false',      'SELECT 5 BETWEEN 6 AND 10');
  ProbeOne('NOT BETWEEN',        'SELECT 5 NOT BETWEEN 6 AND 10');
  ProbeOne('IN literal yes',     'SELECT 3 IN (1,2,3)');
  ProbeOne('IN literal no',      'SELECT 9 IN (1,2,3)');
  ProbeOne('NOT IN literal',     'SELECT 9 NOT IN (1,2,3)');
  ProbeOne('CASE simple',        'SELECT CASE 2 WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' ELSE ''c'' END');
  ProbeOne('CASE searched',      'SELECT CASE WHEN 1>0 THEN ''pos'' ELSE ''neg'' END');
  ProbeOne('CASE no else',       'SELECT typeof(CASE 5 WHEN 1 THEN ''a'' END)');

  // --- LIKE with ESCAPE ---
  ProbeOne('LIKE escape',        'SELECT ''100%'' LIKE ''100\%'' ESCAPE ''\''');
  ProbeOne('LIKE underscore',    'SELECT ''abc'' LIKE ''a_c''');
  ProbeOne('LIKE percent',       'SELECT ''abc'' LIKE ''a%''');
  ProbeOne('LIKE case-insens',   'SELECT ''ABC'' LIKE ''abc''');

  // --- printf %q / %Q (SQL-quoting specifiers) ---
  ProbeOne('printf %q',          'SELECT printf(''%q'',''it''''s'')');
  ProbeOne('printf %Q str',      'SELECT printf(''%Q'',''hi'')');
  ProbeOne('printf %Q null',     'SELECT printf(''%Q'',NULL)');
  ProbeOne('printf %w',          'SELECT printf(''%w'',''col"name'')');
  ProbeOne('printf %w null',     'SELECT printf(''%w'',NULL)');

  // --- unistr Unicode escape decoder (func.c:1174) ---
  ProbeOne('unistr 4hex',        'SELECT unistr(''a\0041b'')');
  ProbeOne('unistr backslash',   'SELECT unistr(''a\\b'')');
  ProbeOne('unistr u',           'SELECT unistr(''é'')');
  ProbeOne('unistr U',           'SELECT unistr(''\U0001F600'')');
  ProbeOne('unistr +',           'SELECT unistr(''\+01F600'')');
  ProbeOne('unistr null',        'SELECT unistr(NULL)');

  // --- Numeric coerce edges ---
  ProbeOne('concat number',      'SELECT 1+''2''');
  ProbeOne('text-as-int leading','SELECT ''  3 abc''+0');
  ProbeOne('text-as-int empty',  'SELECT ''''+0');

  // --- Boolean keyword literals (TRUE/FALSE) ---
  ProbeOne('TRUE',               'SELECT TRUE');
  ProbeOne('FALSE',              'SELECT FALSE');
  ProbeOne('TRUE+FALSE',         'SELECT TRUE+FALSE');

  // --- Modulo on floats ---
  ProbeOne('mod float',          'SELECT 7.5 % 2');

  // --- Negative shift (undefined in C but documented in sqlite) ---
  ProbeOne('shift big',          'SELECT 1 << 63');
  ProbeOne('shift overflow',     'SELECT 1 << 64');

  // --- Aggregate as scalar (without GROUP BY, on no-FROM) ---
  // C: returns 5 (single-row aggregate); Pas may diverge.
  ProbeOne('count() no-FROM',    'SELECT count(*)');
  ProbeOne('sum literal',        'SELECT sum(5)');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
