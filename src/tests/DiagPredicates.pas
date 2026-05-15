{
  SPDX-License-Identifier: blessing

  Pascal port of SQLite — DiagPredicates probe.
  Exercises predicate / comparison surface that other Diag* probes miss:
  IS / IS NOT, IS [NOT] DISTINCT FROM, BETWEEN / NOT BETWEEN,
  IN (list), NOT IN (list), boolean literals (TRUE/FALSE),
  CASE expressions (multi-WHEN, no-base, with NULLs), COALESCE chains,
  NULLIF, IIF nested, and operator precedence around NULL.

  Goal: surface previously-unknown silent-result divergences.
}
{$I ../passqlite3.inc}
program DiagPredicates;

uses
  DiagCommon;

begin
  // --- Boolean literals (true/false keywords) ---
  ProbeRows('select true',         '', 'SELECT true');
  ProbeRows('select false',        '', 'SELECT false');
  ProbeRows('not true',            '', 'SELECT NOT true');
  ProbeRows('true and false',      '', 'SELECT true AND false');
  ProbeRows('true or null',        '', 'SELECT true OR null');
  ProbeRows('false and null',      '', 'SELECT false AND null');
  ProbeRows('true and null',       '', 'SELECT true AND null');
  ProbeRows('false or null',       '', 'SELECT false OR null');

  // --- IS / IS NOT distinctness ---
  ProbeRows('null is null',        '', 'SELECT null IS null');
  ProbeRows('null is not null',    '', 'SELECT null IS NOT null');
  ProbeRows('1 is null',           '', 'SELECT 1 IS null');
  ProbeRows('1 is 1',              '', 'SELECT 1 IS 1');
  ProbeRows('1 is 2',              '', 'SELECT 1 IS 2');
  ProbeRows('null is 1',           '', 'SELECT null IS 1');
  ProbeRows('text is text',        '', 'SELECT ''abc'' IS ''abc''');
  ProbeRows('text is not text',    '', 'SELECT ''abc'' IS NOT ''abd''');

  // --- IS [NOT] DISTINCT FROM (alias of IS NOT / IS) ---
  ProbeRows('null distinct null',  '', 'SELECT null IS DISTINCT FROM null');
  ProbeRows('1 distinct null',     '', 'SELECT 1 IS DISTINCT FROM null');
  ProbeRows('1 not distinct 1',    '', 'SELECT 1 IS NOT DISTINCT FROM 1');
  ProbeRows('null not distinct',   '', 'SELECT null IS NOT DISTINCT FROM null');

  // --- BETWEEN / NOT BETWEEN ---
  ProbeRows('between hit',         '', 'SELECT 5 BETWEEN 1 AND 10');
  ProbeRows('between miss',        '', 'SELECT 11 BETWEEN 1 AND 10');
  ProbeRows('between equal lo',    '', 'SELECT 1 BETWEEN 1 AND 10');
  ProbeRows('between equal hi',    '', 'SELECT 10 BETWEEN 1 AND 10');
  ProbeRows('between null lhs',    '', 'SELECT null BETWEEN 1 AND 10');
  ProbeRows('between null lo',     '', 'SELECT 5 BETWEEN null AND 10');
  ProbeRows('between null hi',     '', 'SELECT 5 BETWEEN 1 AND null');
  ProbeRows('not between hit',     '', 'SELECT 5 NOT BETWEEN 1 AND 10');
  ProbeRows('not between miss',    '', 'SELECT 11 NOT BETWEEN 1 AND 10');
  ProbeRows('between text',        '', 'SELECT ''b'' BETWEEN ''a'' AND ''c''');

  // --- IN (list) ---
  ProbeRows('in hit',              '', 'SELECT 2 IN (1,2,3)');
  ProbeRows('in miss',              '', 'SELECT 4 IN (1,2,3)');
  ProbeRows('in null lhs',          '', 'SELECT null IN (1,2,3)');
  ProbeRows('in null in list',      '', 'SELECT 1 IN (null,2,3)');
  ProbeRows('in null match',        '', 'SELECT 2 IN (null,2,3)');
  ProbeRows('in empty miss',        '', 'SELECT 1 IN (2)');
  ProbeRows('not in hit',           '', 'SELECT 4 NOT IN (1,2,3)');
  ProbeRows('not in miss',          '', 'SELECT 2 NOT IN (1,2,3)');
  ProbeRows('not in null',          '', 'SELECT null NOT IN (1,2,3)');
  ProbeRows('not in null elem',     '', 'SELECT 4 NOT IN (1,null,3)');
  ProbeRows('in text',              '', 'SELECT ''a'' IN (''a'',''b'')');
  ProbeRows('in mixed',             '', 'SELECT 1 IN (''1'',2,3)');

  // --- CASE expressions ---
  ProbeRows('case simple match',    '', 'SELECT CASE 1 WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' END');
  ProbeRows('case simple miss',     '', 'SELECT CASE 5 WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' END');
  ProbeRows('case simple else',     '', 'SELECT CASE 5 WHEN 1 THEN ''a'' ELSE ''z'' END');
  ProbeRows('case search match',    '', 'SELECT CASE WHEN 1=1 THEN ''yes'' ELSE ''no'' END');
  ProbeRows('case multi when',      '', 'SELECT CASE WHEN 0=1 THEN ''a'' WHEN 1=1 THEN ''b'' ELSE ''c'' END');
  ProbeRows('case null when',       '', 'SELECT CASE null WHEN null THEN ''eq'' ELSE ''ne'' END');
  ProbeRows('case all null',        '', 'SELECT CASE WHEN null THEN ''a'' END');
  ProbeRows('case nested',          '', 'SELECT CASE WHEN 1 THEN CASE WHEN 0 THEN ''x'' ELSE ''y'' END END');

  // --- COALESCE chains ---
  ProbeRows('coalesce 2 args first','', 'SELECT coalesce(1,2)');
  ProbeRows('coalesce 2 args null', '', 'SELECT coalesce(null,2)');
  ProbeRows('coalesce 3 args',      '', 'SELECT coalesce(null,null,3)');
  ProbeRows('coalesce all null',    '', 'SELECT coalesce(null,null,null)');
  ProbeRows('coalesce mixed',       '', 'SELECT coalesce(null,'''',null,1)');

  // --- NULLIF ---
  ProbeRows('nullif eq',            '', 'SELECT nullif(5,5)');
  ProbeRows('nullif ne',            '', 'SELECT nullif(5,6)');
  ProbeRows('nullif text eq',       '', 'SELECT nullif(''a'',''a'')');
  ProbeRows('nullif null',          '', 'SELECT nullif(null,null)');
  ProbeRows('nullif null lhs',      '', 'SELECT nullif(null,1)');

  // --- IIF nested ---
  ProbeRows('iif nested',           '', 'SELECT iif(1,iif(0,''x'',''y''),''z'')');
  ProbeRows('iif null',             '', 'SELECT iif(null,''a'',''b'')');

  // --- LIKE / GLOB edges ---
  ProbeRows('like pct',             '', 'SELECT ''abcdef'' LIKE ''abc%''');
  ProbeRows('like underscore',      '', 'SELECT ''abc'' LIKE ''a_c''');
  ProbeRows('like underscore_2',    '', 'SELECT ''ac'' LIKE ''a_c''');
  ProbeRows('like case insens',     '', 'SELECT ''ABC'' LIKE ''abc''');
  ProbeRows('like null lhs',        '', 'SELECT null LIKE ''a''');
  ProbeRows('like escape',          '', 'SELECT ''a%b'' LIKE ''a\%b'' ESCAPE ''\''');
  ProbeRows('glob star',            '', 'SELECT ''abc'' GLOB ''a*''');
  ProbeRows('glob class',           '', 'SELECT ''abc'' GLOB ''a[bx]c''');
  ProbeRows('glob neg class',       '', 'SELECT ''abc'' GLOB ''a[!x]c''');
  ProbeRows('glob case sens',       '', 'SELECT ''ABC'' GLOB ''abc''');

  // --- Operator precedence around NULL ---
  ProbeRows('null+1',               '', 'SELECT null + 1');
  ProbeRows('1+null',               '', 'SELECT 1 + null');
  ProbeRows('null*0',               '', 'SELECT null * 0');
  ProbeRows('null||x',              '', 'SELECT null || ''x''');
  ProbeRows('x||null',              '', 'SELECT ''x'' || null');
  ProbeRows('null=null',            '', 'SELECT null = null');
  ProbeRows('null<>null',           '', 'SELECT null <> null');
  ProbeRows('1<null',               '', 'SELECT 1 < null');
  ProbeRows('null<1',               '', 'SELECT null < 1');
  ProbeRows('not null',             '', 'SELECT NOT null');

  // --- Integer/real coercion at compare ---
  ProbeRows('1=1.0',                '', 'SELECT 1 = 1.0');
  ProbeRows('1=''1''',              '', 'SELECT 1 = ''1''');
  ProbeRows('1<''2''',              '', 'SELECT 1 < ''2''');
  ProbeRows('''1''<2',              '', 'SELECT ''1'' < 2');
  ProbeRows('1.0=''1.0''',          '', 'SELECT 1.0 = ''1.0''');

  WriteLn('Total divergences: ', diverged);
  if diverged = 0 then Halt(0) else Halt(1);
end.
