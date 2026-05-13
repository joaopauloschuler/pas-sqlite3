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
program DiagDate;

uses
  DiagCommon;

begin
  // Date / time
  ProbeOne('date literal',     'SELECT date(''2024-01-15'')');
  ProbeOne('time literal',     'SELECT time(''13:45:00'')');
  ProbeOne('datetime literal', 'SELECT datetime(''2024-01-15 13:45:00'')');
  ProbeOne('strftime ymd',     'SELECT strftime(''%Y-%m-%d'',''2024-06-30'')');
  ProbeOne('julianday epoch',  'SELECT julianday(''2000-01-01 12:00:00'')');
  ProbeOne('date plus days',   'SELECT date(''2024-01-15'',''+5 days'')');
  ProbeOne('date minus mo',    'SELECT date(''2024-03-15'',''-1 month'')');
  ProbeOne('date start mo',    'SELECT date(''2024-03-15'',''start of month'')');
  ProbeOne('strftime weekday', 'SELECT strftime(''%w'',''2024-01-15'')');
  ProbeOne('strftime %u Sat',  'SELECT strftime(''%u'',''2024-06-15'')');
  ProbeOne('strftime %u Sun',  'SELECT strftime(''%u'',''2024-06-16'')');
  ProbeOne('strftime %u Mon',  'SELECT strftime(''%u'',''2024-06-17'')');
  ProbeOne('unixepoch',        'SELECT unixepoch(''2024-01-01'')');
  ProbeOne('time HM',          'SELECT time(''13:45'')');
  ProbeOne('tz +01:30',        'SELECT datetime(''2024-06-15 12:00:00+01:30'')');
  ProbeOne('tz -05:00',        'SELECT datetime(''2024-06-15 12:00:00-05:00'')');
  ProbeOne('tz Z',             'SELECT datetime(''2024-06-15T12:00:00Z'')');
  ProbeOne('tz time-only',     'SELECT time(''12:00:00+02:00'')');
  ProbeOne('tz date rollover', 'SELECT date(''2024-06-15T23:00:00-05:00'')');

  // localtime / utc modifiers (10.1.bug.106).  Round-trip is identity;
  // use the round-trip form so the test is timezone-independent.
  ProbeOne('utc/local roundtrip',
        'SELECT datetime(''2024-06-15 12:00:00'',''utc'',''localtime'')');
  ProbeOne('local/utc roundtrip',
        'SELECT datetime(''2024-06-15 12:00:00'',''localtime'',''utc'')');
  ProbeOne('localtime not null',
        'SELECT datetime(''2024-06-15 12:00:00'',''localtime'') IS NOT NULL');
  ProbeOne('utc not null',
        'SELECT datetime(''2024-06-15 12:00:00'',''utc'') IS NOT NULL');
  ProbeOne('time localtime',
        'SELECT time(''2024-06-15 12:00:00'',''utc'',''localtime'')');

  // Numeric / scalar variants
  ProbeOne('round 0',          'SELECT round(3.5)');
  ProbeOne('round 2',          'SELECT round(3.14159, 2)');
  ProbeOne('round neg',        'SELECT round(-2.5)');
  ProbeOne('sign pos',         'SELECT sign(5)');
  ProbeOne('sign neg',         'SELECT sign(-3.14)');
  ProbeOne('sign zero',        'SELECT sign(0)');
  ProbeOne('iif true',         'SELECT iif(1, ''a'', ''b'')');
  ProbeOne('iif false',        'SELECT iif(0, ''a'', ''b'')');
  ProbeOne('format like %d',   'SELECT format(''%d'', 42)');
  ProbeOne('quote text',       'SELECT quote(''it''''s'')');
  ProbeOne('quote null',       'SELECT quote(NULL)');
  ProbeOne('quote blob',       'SELECT quote(X''ff'')');
  ProbeOne('quote int',        'SELECT quote(123)');
  ProbeOne('quote real',       'SELECT quote(1.5)');

  // last_insert_rowid / changes (no setup, expect 0)
  ProbeOne('last_insert_rowid', 'SELECT last_insert_rowid()');
  ProbeOne('changes',           'SELECT changes()');
  ProbeOne('total_changes',     'SELECT total_changes()');

  // sqlite_version etc
  ProbeOne('typeof sqlite_ver', 'SELECT typeof(sqlite_version())');
  ProbeOne('typeof sqlite_src', 'SELECT typeof(sqlite_source_id())');

  // soundex / etc.
  ProbeOne('like escape',       'SELECT ''100%'' LIKE ''100\%'' ESCAPE ''\''');
  ProbeOne('like _',            'SELECT ''abc'' LIKE ''a_c''');
  ProbeOne('glob ?',            'SELECT ''abc'' GLOB ''a?c''');
  ProbeOne('glob []',           'SELECT ''abc'' GLOB ''[ab]bc''');

  // String comparisons
  ProbeOne('cmp text',          'SELECT ''b''>''a''');
  ProbeOne('cmp num text',      'SELECT 1>''a''');
  ProbeOne('coalesce of types', 'SELECT typeof(coalesce(NULL, 1.5))');
  ProbeOne('null is null',      'SELECT NULL IS NULL');
  ProbeOne('null = null',       'SELECT NULL = NULL');

  // Arithmetic with text
  ProbeOne('text*int',          'SELECT ''3''*2');
  ProbeOne('empty text+int',    'SELECT ''''+5');
  ProbeOne('text float coerce', 'SELECT ''1.5''+0');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
