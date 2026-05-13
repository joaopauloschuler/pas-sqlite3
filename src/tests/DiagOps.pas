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
  DiagOps — exploratory probe.  Exercises operators, string/numeric edge
  cases, and common scalar fns that are NOT covered by the other Diag*
  probes, to surface previously unknown bugs.
}
program DiagOps;

uses
  DiagCommon;

begin
  // --- bitwise operators ---
  ProbeSetupCheck('bit AND',  '', 'SELECT 6 & 3');             // 2
  ProbeSetupCheck('bit OR',   '', 'SELECT 6 | 3');             // 7
  ProbeSetupCheck('bit XOR(via ~&|)','', 'SELECT (6 | 3) - (6 & 3)'); // 5
  ProbeSetupCheck('bit NOT',  '', 'SELECT ~0');                // -1
  ProbeSetupCheck('bit SHL',  '', 'SELECT 1 << 4');            // 16
  ProbeSetupCheck('bit SHR',  '', 'SELECT 256 >> 3');          // 32
  ProbeSetupCheck('mod op',   '', 'SELECT 17 % 5');            // 2
  ProbeSetupCheck('int div',  '', 'SELECT 17 / 5');            // 3
  ProbeSetupCheck('div by 0', '', 'SELECT typeof(1/0)');       // null
  ProbeSetupCheck('neg unary','', 'SELECT -(-7)');             // 7
  ProbeSetupCheck('not unary','', 'SELECT NOT 0');             // 1
  ProbeSetupCheck('not unary 1','', 'SELECT NOT 1');           // 0
  ProbeSetupCheck('and bool', '', 'SELECT 1 AND 1');           // 1
  ProbeSetupCheck('or bool',  '', 'SELECT 0 OR 1');            // 1
  ProbeSetupCheck('compare lt','', 'SELECT 3 < 5');            // 1
  ProbeSetupCheck('compare ge','', 'SELECT 5 >= 5');           // 1
  ProbeSetupCheck('null cmp', '', 'SELECT typeof(1 = NULL)');  // null
  ProbeSetupCheck('is null',  '', 'SELECT NULL IS NULL');      // 1
  ProbeSetupCheck('is not null','', 'SELECT 1 IS NOT NULL');   // 1

  // --- string functions ---
  ProbeSetupCheck('lower asc','', 'SELECT lower(''ABCdef'')');  // abcdef (txt)
  ProbeSetupCheck('upper asc','', 'SELECT upper(''ABCdef'')');  // ABCDEF
  ProbeSetupCheck('length',   '', 'SELECT length(''hello'')');  // 5
  ProbeSetupCheck('length utf8','', 'SELECT length(''café'')'); // 4
  ProbeSetupCheck('trim default','', 'SELECT trim(''  hi  '')');// hi
  ProbeSetupCheck('ltrim',    '', 'SELECT ltrim(''xxxhi'',''x'')'); // hi
  ProbeSetupCheck('rtrim',    '', 'SELECT rtrim(''hixxx'',''x'')'); // hi
  ProbeSetupCheck('replace',  '', 'SELECT replace(''abcabc'',''b'',''Z'')'); // aZcaZc
  ProbeSetupCheck('instr',    '', 'SELECT instr(''hello world'',''world'')'); // 7
  ProbeSetupCheck('hex',      '', 'SELECT hex(X''4142'')');     // 4142
  ProbeSetupCheck('typeof int','', 'SELECT typeof(1)');         // integer
  ProbeSetupCheck('typeof real','', 'SELECT typeof(1.5)');      // real
  ProbeSetupCheck('typeof text','', 'SELECT typeof(''x'')');    // text
  ProbeSetupCheck('typeof null','', 'SELECT typeof(NULL)');     // null
  ProbeSetupCheck('typeof blob','', 'SELECT typeof(X''00'')');  // blob

  // --- numeric edges ---
  ProbeSetupCheck('max int', '', 'SELECT 9223372036854775807');
  ProbeSetupCheck('big add overflow', '', 'SELECT typeof(9223372036854775807 + 1)');  // real
  ProbeSetupCheck('real arith', '', 'SELECT 1.5 * 2');          // 3.0 (txt)
  ProbeSetupCheck('round zero', '', 'SELECT round(0.5)');       // 1.0 (txt; round half away)
  ProbeSetupCheck('cast str int', '', 'SELECT CAST(''  42abc'' AS INT)'); // 42

  // --- ifnull / nullif ---
  ProbeSetupCheck('ifnull null', '', 'SELECT ifnull(NULL,7)'); // 7
  ProbeSetupCheck('ifnull val',  '', 'SELECT ifnull(3,7)');    // 3
  ProbeSetupCheck('nullif eq',   '', 'SELECT typeof(nullif(3,3))'); // null
  ProbeSetupCheck('nullif ne',   '', 'SELECT nullif(3,4)');    // 3
  ProbeSetupCheck('iif',         '', 'SELECT iif(1<2,''yes'',''no'')'); // yes

  // --- ORDER BY / LIMIT in inline SELECT ---
  ProbeSetupCheck('select inline order',
        'CREATE TABLE t(a); INSERT INTO t VALUES(3); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2)',
        'SELECT a FROM t ORDER BY a LIMIT 1');         // 1
  ProbeSetupCheck('select inline order desc',
        'CREATE TABLE t(a); INSERT INTO t VALUES(3); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2)',
        'SELECT a FROM t ORDER BY a DESC LIMIT 1');    // 3
  ProbeSetupCheck('select inline distinct count',
        'CREATE TABLE t(a); INSERT INTO t VALUES(3); INSERT INTO t VALUES(1); INSERT INTO t VALUES(3)',
        'SELECT count(DISTINCT a) FROM t');            // 2

  // --- HAVING ---
  ProbeSetupCheck('having',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); INSERT INTO t VALUES(2)',
        'SELECT count(*) FROM t GROUP BY a HAVING count(*)>1'); // 2

  // --- LIMIT/OFFSET ---
  ProbeSetupCheck('limit offset',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); INSERT INTO t VALUES(3)',
        'SELECT a FROM t ORDER BY a LIMIT 1 OFFSET 1'); // 2
  ProbeSetupCheck('limit no order',
        'CREATE TABLE t(a); INSERT INTO t VALUES(7); INSERT INTO t VALUES(8); INSERT INTO t VALUES(9)',
        'SELECT a FROM t LIMIT 1'); // 7
  ProbeSetupCheck('multi-row insert select count',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1),(2),(3)',
        'SELECT count(*) FROM t'); // 3 vs 1
  ProbeSetupCheck('select with NOT EXISTS',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1)',
        'SELECT count(*) FROM t WHERE NOT EXISTS (SELECT 1 FROM t WHERE a=99)'); // 1
  ProbeSetupCheck('select where with OR',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); INSERT INTO t VALUES(3)',
        'SELECT count(*) FROM t WHERE a=1 OR a=3'); // 2
  ProbeSetupCheck('select where with AND chained',
        'CREATE TABLE t(a,b); INSERT INTO t VALUES(1,1); INSERT INTO t VALUES(1,2); INSERT INTO t VALUES(2,2)',
        'SELECT count(*) FROM t WHERE a=1 AND b=2'); // 1
  ProbeSetupCheck('substr 3-arg',
        '',
        'SELECT substr(''abcdefg'',2,3)'); // 'bcd'
  ProbeSetupCheck('substr 2-arg',
        '',
        'SELECT substr(''abcdefg'',3)'); // 'cdefg'
  ProbeSetupCheck('group_concat',
        'CREATE TABLE t(a); INSERT INTO t VALUES(''x''); INSERT INTO t VALUES(''y'')',
        'SELECT group_concat(a) FROM t'); // x,y
  ProbeSetupCheck('group_concat sep',
        'CREATE TABLE t(a); INSERT INTO t VALUES(''x''); INSERT INTO t VALUES(''y'')',
        'SELECT group_concat(a,''-'') FROM t'); // x-y
  ProbeSetupCheck('avg result type',
        'CREATE TABLE t(a); INSERT INTO t VALUES(2); INSERT INTO t VALUES(4)',
        'SELECT typeof(avg(a)) FROM t'); // real
  ProbeSetupCheck('total result type',
        'CREATE TABLE t(a); INSERT INTO t VALUES(2); INSERT INTO t VALUES(4)',
        'SELECT typeof(total(a)) FROM t'); // real
  ProbeSetupCheck('like ESCAPE',
        '',
        'SELECT ''a%b'' LIKE ''a\%b'' ESCAPE ''\'''); // 1
  ProbeSetupCheck('REGEXP missing',
        '',
        'SELECT ''abc'' GLOB ''a*''');  // 1
  ProbeSetupCheck('CASE no else',
        '',
        'SELECT typeof(CASE 1 WHEN 2 THEN 3 END)');  // null
  ProbeSetupCheck('CASE matches',
        '',
        'SELECT CASE 2 WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' END');  // 'b'

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
