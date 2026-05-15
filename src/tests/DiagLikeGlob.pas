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
  DiagLikeGlob — exploratory probe for LIKE / GLOB / NOT LIKE / NOT GLOB /
  ESCAPE / case-sensitivity edges.  Goal: surface bugs not yet captured in
  tasklist.md.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagLikeGlob.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagLikeGlob
}
program DiagLikeGlob;


uses
  DiagCommon;

begin
  // --- LIKE: simple wildcards ---
  ProbeOne('like %suffix',     'SELECT ''hello world'' LIKE ''%world''');
  ProbeOne('like prefix%',     'SELECT ''hello world'' LIKE ''hello%''');
  ProbeOne('like %mid%',       'SELECT ''hello world'' LIKE ''%lo wo%''');
  ProbeOne('like _ single',    'SELECT ''cat'' LIKE ''c_t''');
  ProbeOne('like _ no match',  'SELECT ''cart'' LIKE ''c_t''');
  ProbeOne('like multi _',     'SELECT ''abcd'' LIKE ''_b_d''');
  ProbeOne('like literal eq',  'SELECT ''abc'' LIKE ''abc''');
  ProbeOne('like empty pat',   'SELECT ''a'' LIKE ''''');
  ProbeOne('like empty all',   'SELECT '''' LIKE ''''');
  ProbeOne('like empty %',     'SELECT '''' LIKE ''%''');

  // --- LIKE: ASCII case-insensitive (default) ---
  ProbeOne('like ascii ci',    'SELECT ''ABC'' LIKE ''abc''');
  ProbeOne('like ascii ci %',  'SELECT ''ABCdef'' LIKE ''ab%EF''');

  // --- LIKE: NOT LIKE ---
  ProbeOne('not like neg',     'SELECT ''abc'' NOT LIKE ''xyz''');
  ProbeOne('not like pos',     'SELECT ''abc'' NOT LIKE ''abc''');

  // --- LIKE: ESCAPE clause ---
  ProbeOne('like escape pct',  'SELECT ''50%'' LIKE ''50\%'' ESCAPE ''\''');
  ProbeOne('like escape und',  'SELECT ''a_b'' LIKE ''a\_b'' ESCAPE ''\''');
  ProbeOne('like escape no',   'SELECT ''50x'' LIKE ''50\%'' ESCAPE ''\''');
  ProbeOne('like escape esc',  'SELECT ''a\b'' LIKE ''a\\b'' ESCAPE ''\''');

  // --- LIKE: NULL semantics ---
  ProbeOne('like null lhs',    'SELECT NULL LIKE ''abc''');
  ProbeOne('like null rhs',    'SELECT ''abc'' LIKE NULL');
  ProbeOne('like null escape', 'SELECT ''a'' LIKE ''a'' ESCAPE NULL');

  // --- LIKE: typeof ---
  ProbeOne('typeof like',      'SELECT typeof(''abc'' LIKE ''a%'')');
  ProbeOne('typeof like null', 'SELECT typeof(NULL LIKE ''a'')');

  // --- LIKE: numbers (LIKE coerces to TEXT) ---
  ProbeOne('like int->text',   'SELECT 12345 LIKE ''123%''');
  ProbeOne('like real->text',  'SELECT 3.14 LIKE ''3.%''');

  // --- GLOB: simple wildcards ---
  ProbeOne('glob *suffix',     'SELECT ''hello'' GLOB ''*llo''');
  ProbeOne('glob prefix*',     'SELECT ''hello'' GLOB ''he*''');
  ProbeOne('glob ? single',    'SELECT ''cat'' GLOB ''c?t''');
  ProbeOne('glob no match',    'SELECT ''cat'' GLOB ''d?t''');
  ProbeOne('glob literal',     'SELECT ''abc'' GLOB ''abc''');

  // --- GLOB: case sensitivity (GLOB is case-sensitive!) ---
  ProbeOne('glob cs neg',      'SELECT ''ABC'' GLOB ''abc''');
  ProbeOne('glob cs pos',      'SELECT ''abc'' GLOB ''abc''');

  // --- GLOB: character class ---
  ProbeOne('glob class pos',   'SELECT ''a'' GLOB ''[abc]''');
  ProbeOne('glob class neg',   'SELECT ''d'' GLOB ''[abc]''');
  ProbeOne('glob class range', 'SELECT ''m'' GLOB ''[a-z]''');
  ProbeOne('glob class neg2',  'SELECT ''A'' GLOB ''[a-z]''');
  ProbeOne('glob class invert','SELECT ''d'' GLOB ''[^abc]''');
  ProbeOne('glob class invert no','SELECT ''a'' GLOB ''[^abc]''');

  // --- GLOB: NOT GLOB ---
  ProbeOne('not glob neg',     'SELECT ''abc'' NOT GLOB ''xyz''');
  ProbeOne('not glob pos',     'SELECT ''abc'' NOT GLOB ''abc''');

  // --- GLOB: NULL semantics ---
  ProbeOne('glob null lhs',    'SELECT NULL GLOB ''*''');
  ProbeOne('glob null rhs',    'SELECT ''abc'' GLOB NULL');

  // --- like() / glob() function form ---
  ProbeOne('like() func',      'SELECT like(''a%c'',''abc'')');
  ProbeOne('glob() func',      'SELECT glob(''a*c'',''abc'')');
  ProbeOne('like() func esc',  'SELECT like(''a\%c'',''a%c'',''\'')');

  // --- LIKE with literal % and _ via ESCAPE in pattern ---
  ProbeOne('like 100%lit',     'SELECT ''100%'' LIKE ''100\%'' ESCAPE ''\''');
  ProbeOne('like 100abc neg',  'SELECT ''100abc'' LIKE ''100\%'' ESCAPE ''\''');

  // --- Multi-byte (UTF-8) input — LIKE should be case-insensitive only for
  //     ASCII by default; non-ASCII bytes compare by byte ---
  ProbeOne('like utf8 same',   'SELECT ''café'' LIKE ''café''');
  ProbeOne('like utf8 ci asc', 'SELECT ''CAFÉ'' LIKE ''café''');     // É vs é byte-different
  ProbeOne('like utf8 wild',   'SELECT ''café'' LIKE ''ca%''');

  // --- Empty pattern and empty subject ---
  ProbeOne('glob empty pat',   'SELECT ''abc'' GLOB ''''');
  ProbeOne('glob empty all',   'SELECT '''' GLOB ''''');
  ProbeOne('glob empty *',     'SELECT '''' GLOB ''*''');

  // --- LIKE optimization: rowid range conversion gates - "LIKE ''abc%''" ---
  // (Result-set behavior; planner choice not tested here.)
  ProbeOne('like prefix only', 'SELECT ''abcdef'' LIKE ''abc%''');
  ProbeOne('like prefix neg',  'SELECT ''abx''    LIKE ''abc%''');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
