{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  DiagScalarFunc — scalar built-in function probe.  Targets edges not
  already covered by DiagFunctions / DiagPrintfFmt / DiagDate /
  DiagSumOverflow / DiagMisc.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagScalarFunc.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagScalarFunc
}
program DiagScalarFunc;

uses
  DiagCommon;

begin
  // --- printf SQL-escape specifiers ---
  ProbeOne('printf %q simple',  'SELECT printf(''%q'', ''it''''s'')');
  ProbeOne('printf %Q simple',  'SELECT printf(''%Q'', ''ab'')');
  ProbeOne('printf %Q null',    'SELECT printf(''%Q'', NULL)');
  ProbeOne('printf %w',         'SELECT printf(''%w'', ''a"b'')');
  ProbeOne('printf %s null',    'SELECT printf(''%s'', NULL)');
  ProbeOne('printf %i',         'SELECT printf(''%i'', 42)');
  ProbeOne('printf %u',         'SELECT printf(''%u'', -1)');

  // --- format() alias ---
  ProbeOne('format alias',      'SELECT format(''%d-%s'', 5, ''x'')');

  // --- iif / nullif / coalesce edges ---
  ProbeOne('iif true',          'SELECT iif(1<2, ''y'', ''n'')');
  ProbeOne('iif false',         'SELECT iif(1>2, ''y'', ''n'')');
  ProbeOne('iif null cond',     'SELECT iif(NULL, ''y'', ''n'')');
  ProbeOne('coalesce 1 arg',    'SELECT coalesce(NULL, NULL, 7, NULL)');
  ProbeOne('nullif null lhs',   'SELECT nullif(NULL, 1)');

  // --- substr / substring edges ---
  ProbeOne('substr 0 start',    'SELECT substr(''hello'', 0, 3)');
  ProbeOne('substr neg len',    'SELECT substr(''hello'', 2, -2)');
  ProbeOne('substr 0 len',      'SELECT substr(''hello'', 2, 0)');
  ProbeOne('substring alias',   'SELECT substring(''abcdef'', 2, 3)');
  ProbeOne('substr blob',       'SELECT length(substr(X''0102030405'', 2, 3))');

  // --- trim with custom multi-char list ---
  ProbeOne('trim multi',        'SELECT trim(''xyhellooxx'', ''xyo'')');
  ProbeOne('ltrim chars',       'SELECT ltrim(''xxhelloxx'', ''x'')');
  ProbeOne('rtrim chars',       'SELECT rtrim(''xxhelloxx'', ''x'')');

  // --- replace edges ---
  ProbeOne('replace empty pat', 'SELECT replace(''abc'', '''', ''X'')');
  ProbeOne('replace empty rep', 'SELECT replace(''abacab'', ''a'', '''')');
  ProbeOne('replace overlap',   'SELECT replace(''aaaa'', ''aa'', ''b'')');

  // --- instr edges ---
  ProbeOne('instr empty needle','SELECT instr(''abc'', '''')');
  ProbeOne('instr empty hay',   'SELECT instr('''', ''a'')');
  ProbeOne('instr blob',        'SELECT instr(X''aabbcc'', X''bb'')');

  // --- hex / unhex ---
  ProbeOne('hex empty',         'SELECT hex('''')');
  ProbeOne('hex null',          'SELECT typeof(hex(NULL)) || ''|'' || hex(NULL)');
  ProbeOne('hex empty blob',    'SELECT typeof(hex(X'''')) || ''|'' || hex(X'''')');
  ProbeOne('unhex 4',           'SELECT hex(unhex(''DEADBEEF''))');
  ProbeOne('unhex odd',         'SELECT typeof(unhex(''DEAD1''))');
  ProbeOne('unhex bad',         'SELECT typeof(unhex(''XX''))');
  ProbeOne('unhex with ws',     'SELECT typeof(unhex(''DE AD'', '' ''))');

  // --- char / unicode edges ---
  ProbeOne('char empty',        'SELECT char()');
  ProbeOne('char bmp',          'SELECT char(0x4E2D)');
  ProbeOne('unicode multi',     'SELECT unicode(''中'')');
  ProbeOne('unicode empty',     'SELECT unicode('''')');

  // --- abs INT64 boundary ---
  ProbeOne('abs minint',        'SELECT typeof(abs(-9223372036854775808))');
  ProbeOne('abs i64 max',       'SELECT abs(9223372036854775807)');

  // --- round precision ---
  ProbeOne('round half',        'SELECT round(0.5)');
  ProbeOne('round neg half',    'SELECT round(-0.5)');
  ProbeOne('round to 2',        'SELECT round(3.14159, 2)');
  ProbeOne('round to 0',        'SELECT round(3.7, 0)');
  ProbeOne('round neg prec',    'SELECT round(1234.5, -2)');

  // --- randomblob / zeroblob ---
  ProbeOne('zeroblob len',      'SELECT length(zeroblob(8))');
  ProbeOne('randomblob len',    'SELECT length(randomblob(16))');
  ProbeOne('zeroblob 0',        'SELECT length(zeroblob(0))');
  ProbeOne('zeroblob neg',      'SELECT length(zeroblob(-3))');

  // --- quote ---
  ProbeOne('quote int',         'SELECT quote(7)');
  ProbeOne('quote text',        'SELECT quote(''it''''s'')');
  ProbeOne('quote null',        'SELECT quote(NULL)');
  ProbeOne('quote blob',        'SELECT quote(X''ab12'')');
  ProbeOne('quote real',        'SELECT quote(1.5)');

  // --- LIKE edges ---
  ProbeOne('like underscore',   'SELECT ''abc'' LIKE ''a_c''');
  ProbeOne('like percent',      'SELECT ''abc'' LIKE ''a%''');
  ProbeOne('like escape',       'SELECT ''a%b'' LIKE ''a\%b'' ESCAPE ''\''');
  ProbeOne('like ci',           'SELECT ''ABC'' LIKE ''abc''');
  ProbeOne('like null pat',     'SELECT typeof(''a'' LIKE NULL)');
  ProbeOne('not like',          'SELECT ''abc'' NOT LIKE ''d%''');

  // --- GLOB edges ---
  ProbeOne('glob class',        'SELECT ''abc'' GLOB ''[a-c]bc''');
  ProbeOne('glob neg class',    'SELECT ''xbc'' GLOB ''[^a]bc''');
  ProbeOne('glob star',         'SELECT ''abcdef'' GLOB ''abc*''');
  ProbeOne('glob qmark',        'SELECT ''abc'' GLOB ''a?c''');

  // --- typeof on big int ---
  ProbeOne('typeof big int',    'SELECT typeof(9223372036854775807)');
  ProbeOne('typeof hex int',    'SELECT typeof(0x7FFFFFFF)');
  ProbeOne('typeof hex real',   'SELECT typeof(1e300)');

  // --- last_insert_rowid / changes / total_changes (init state) ---
  ProbeOne('changes init',      'SELECT changes()');
  ProbeOne('total_changes init','SELECT total_changes()');
  ProbeOne('last_rowid init',   'SELECT last_insert_rowid()');

  // --- sqlite_version / sqlite_source_id (compare structure only via length) ---
  // Skip exact compare: version strings differ by build.  Check typeof.
  ProbeOne('typeof version',    'SELECT typeof(sqlite_version())');
  ProbeOne('typeof source_id',  'SELECT typeof(sqlite_source_id())');

  // --- soundex (gated on SQLITE_SOUNDEX in C; in this build, may be missing) ---
  ProbeOne('soundex',           'SELECT soundex(''Robert'')');

  // --- json edges (very basic) ---
  ProbeOne('json_valid yes',    'SELECT json_valid(''[1,2,3]'')');
  ProbeOne('json_valid no',     'SELECT json_valid(''xx'')');
  ProbeOne('json_array',        'SELECT json_array(1, ''a'', 3.5)');
  ProbeOne('json_type',         'SELECT json_type(''{"a":1}'')');

  // --- date/time edges (a couple, light) ---
  ProbeOne('date julianday',    'SELECT date(2440587.5)');
  ProbeOne('strftime YMD',      'SELECT strftime(''%Y-%m-%d'', ''2026-04-29 12:34:56'')');
  ProbeOne('time HMS',          'SELECT time(''2026-04-29 12:34:56'')');

  // --- arithmetic edges ---
  ProbeOne('int / int',         'SELECT 10 / 3');
  ProbeOne('real / int',        'SELECT 10.0 / 3');
  ProbeOne('mod neg',           'SELECT -7 % 3');
  ProbeOne('mod by zero',       'SELECT typeof(7 % 0)');
  ProbeOne('add overflow',      'SELECT 9223372036854775807 + 1');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
  if diverged > 0 then Halt(1) else Halt(0);
end.
