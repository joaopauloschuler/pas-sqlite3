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
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

function PasRun(const setup, check: AnsiString;
                out checkPrep, val: i32; out txt: AnsiString): i32;
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  s, stmt2: AnsiString;
  p: i32;
  pTxt: PAnsiChar;
begin
  Result := 0;
  checkPrep := -1; val := -99999; txt := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin Result := -1; Exit; end;
  if setup <> '' then begin
    s := setup;
    while s <> '' do begin
      p := Pos(';', s);
      if p = 0 then begin stmt2 := s; s := ''; end
      else begin stmt2 := Copy(s, 1, p - 1); s := Copy(s, p + 1, MaxInt); end;
      stmt2 := Trim(stmt2);
      if stmt2 = '' then continue;
      pStmt := nil;
      if (sqlite3_prepare_v2(db, PAnsiChar(stmt2), -1, @pStmt, nil) = 0)
        and (pStmt <> nil) then begin
        repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
        sqlite3_finalize(pStmt);
      end;
    end;
  end;
  pStmt := nil;
  checkPrep := sqlite3_prepare_v2(db, PAnsiChar(check), -1, @pStmt, nil);
  if (checkPrep = 0) and (pStmt <> nil) then begin
    if sqlite3_step(pStmt) = SQLITE_ROW then begin
      val := sqlite3_column_int(pStmt, 0);
      pTxt := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if pTxt <> nil then txt := AnsiString(pTxt);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

function CRun(const setup, check: AnsiString;
              out checkPrep, val: i32; out txt: AnsiString): i32;
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail, pErr: PChar;
  pTxt: PAnsiChar;
begin
  Result := 0;
  checkPrep := -1; val := -99999; txt := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then begin Result := -1; Exit; end;
  if setup <> '' then begin
    pErr := nil;
    csq_exec(db, PAnsiChar(setup), nil, nil, pErr);
  end;
  pStmt := nil; pTail := nil;
  checkPrep := csq_prepare_v2(db, PAnsiChar(check), -1, pStmt, pTail);
  if (checkPrep = 0) and (pStmt <> nil) then begin
    if csq_step(pStmt) = SQLITE_ROW then begin
      val := csq_column_int(pStmt, 0);
      pTxt := PAnsiChar(csq_column_text(pStmt, 0));
      if pTxt <> nil then txt := AnsiString(pTxt);
    end;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure Probe(const lbl, setup, check: AnsiString);
var
  pPrep, pVal: i32;
  cPrep, cVal: i32;
  pTxt, cTxt: AnsiString;
  ok: Boolean;
begin
  PasRun(setup, check, pPrep, pVal, pTxt);
  CRun  (setup, check, cPrep, cVal, cTxt);
  ok := (pPrep = cPrep) and (pVal = cVal) and (pTxt = cTxt);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   check=', check);
    WriteLn('   Pas: prep=', pPrep, ' val=', pVal, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' val=', cVal, ' txt="', cTxt, '"');
  end;
end;

begin
  // --- bitwise operators ---
  Probe('bit AND',  '', 'SELECT 6 & 3');             // 2
  Probe('bit OR',   '', 'SELECT 6 | 3');             // 7
  Probe('bit XOR(via ~&|)','', 'SELECT (6 | 3) - (6 & 3)'); // 5
  Probe('bit NOT',  '', 'SELECT ~0');                // -1
  Probe('bit SHL',  '', 'SELECT 1 << 4');            // 16
  Probe('bit SHR',  '', 'SELECT 256 >> 3');          // 32
  Probe('mod op',   '', 'SELECT 17 % 5');            // 2
  Probe('int div',  '', 'SELECT 17 / 5');            // 3
  Probe('div by 0', '', 'SELECT typeof(1/0)');       // null
  Probe('neg unary','', 'SELECT -(-7)');             // 7
  Probe('not unary','', 'SELECT NOT 0');             // 1
  Probe('not unary 1','', 'SELECT NOT 1');           // 0
  Probe('and bool', '', 'SELECT 1 AND 1');           // 1
  Probe('or bool',  '', 'SELECT 0 OR 1');            // 1
  Probe('compare lt','', 'SELECT 3 < 5');            // 1
  Probe('compare ge','', 'SELECT 5 >= 5');           // 1
  Probe('null cmp', '', 'SELECT typeof(1 = NULL)');  // null
  Probe('is null',  '', 'SELECT NULL IS NULL');      // 1
  Probe('is not null','', 'SELECT 1 IS NOT NULL');   // 1

  // --- string functions ---
  Probe('lower asc','', 'SELECT lower(''ABCdef'')');  // abcdef (txt)
  Probe('upper asc','', 'SELECT upper(''ABCdef'')');  // ABCDEF
  Probe('length',   '', 'SELECT length(''hello'')');  // 5
  Probe('length utf8','', 'SELECT length(''café'')'); // 4
  Probe('trim default','', 'SELECT trim(''  hi  '')');// hi
  Probe('ltrim',    '', 'SELECT ltrim(''xxxhi'',''x'')'); // hi
  Probe('rtrim',    '', 'SELECT rtrim(''hixxx'',''x'')'); // hi
  Probe('replace',  '', 'SELECT replace(''abcabc'',''b'',''Z'')'); // aZcaZc
  Probe('instr',    '', 'SELECT instr(''hello world'',''world'')'); // 7
  Probe('hex',      '', 'SELECT hex(X''4142'')');     // 4142
  Probe('typeof int','', 'SELECT typeof(1)');         // integer
  Probe('typeof real','', 'SELECT typeof(1.5)');      // real
  Probe('typeof text','', 'SELECT typeof(''x'')');    // text
  Probe('typeof null','', 'SELECT typeof(NULL)');     // null
  Probe('typeof blob','', 'SELECT typeof(X''00'')');  // blob

  // --- numeric edges ---
  Probe('max int', '', 'SELECT 9223372036854775807');
  Probe('big add overflow', '', 'SELECT typeof(9223372036854775807 + 1)');  // real
  Probe('real arith', '', 'SELECT 1.5 * 2');          // 3.0 (txt)
  Probe('round zero', '', 'SELECT round(0.5)');       // 1.0 (txt; round half away)
  Probe('cast str int', '', 'SELECT CAST(''  42abc'' AS INT)'); // 42

  // --- ifnull / nullif ---
  Probe('ifnull null', '', 'SELECT ifnull(NULL,7)'); // 7
  Probe('ifnull val',  '', 'SELECT ifnull(3,7)');    // 3
  Probe('nullif eq',   '', 'SELECT typeof(nullif(3,3))'); // null
  Probe('nullif ne',   '', 'SELECT nullif(3,4)');    // 3
  Probe('iif',         '', 'SELECT iif(1<2,''yes'',''no'')'); // yes

  // --- ORDER BY / LIMIT in inline SELECT ---
  Probe('select inline order',
        'CREATE TABLE t(a); INSERT INTO t VALUES(3); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2)',
        'SELECT a FROM t ORDER BY a LIMIT 1');         // 1
  Probe('select inline order desc',
        'CREATE TABLE t(a); INSERT INTO t VALUES(3); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2)',
        'SELECT a FROM t ORDER BY a DESC LIMIT 1');    // 3
  Probe('select inline distinct count',
        'CREATE TABLE t(a); INSERT INTO t VALUES(3); INSERT INTO t VALUES(1); INSERT INTO t VALUES(3)',
        'SELECT count(DISTINCT a) FROM t');            // 2

  // --- HAVING ---
  Probe('having',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); INSERT INTO t VALUES(2)',
        'SELECT count(*) FROM t GROUP BY a HAVING count(*)>1'); // 2

  // --- LIMIT/OFFSET ---
  Probe('limit offset',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); INSERT INTO t VALUES(3)',
        'SELECT a FROM t ORDER BY a LIMIT 1 OFFSET 1'); // 2
  Probe('limit no order',
        'CREATE TABLE t(a); INSERT INTO t VALUES(7); INSERT INTO t VALUES(8); INSERT INTO t VALUES(9)',
        'SELECT a FROM t LIMIT 1'); // 7
  Probe('multi-row insert select count',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1),(2),(3)',
        'SELECT count(*) FROM t'); // 3 vs 1
  Probe('select with NOT EXISTS',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1)',
        'SELECT count(*) FROM t WHERE NOT EXISTS (SELECT 1 FROM t WHERE a=99)'); // 1
  Probe('select where with OR',
        'CREATE TABLE t(a); INSERT INTO t VALUES(1); INSERT INTO t VALUES(2); INSERT INTO t VALUES(3)',
        'SELECT count(*) FROM t WHERE a=1 OR a=3'); // 2
  Probe('select where with AND chained',
        'CREATE TABLE t(a,b); INSERT INTO t VALUES(1,1); INSERT INTO t VALUES(1,2); INSERT INTO t VALUES(2,2)',
        'SELECT count(*) FROM t WHERE a=1 AND b=2'); // 1
  Probe('substr 3-arg',
        '',
        'SELECT substr(''abcdefg'',2,3)'); // 'bcd'
  Probe('substr 2-arg',
        '',
        'SELECT substr(''abcdefg'',3)'); // 'cdefg'
  Probe('group_concat',
        'CREATE TABLE t(a); INSERT INTO t VALUES(''x''); INSERT INTO t VALUES(''y'')',
        'SELECT group_concat(a) FROM t'); // x,y
  Probe('group_concat sep',
        'CREATE TABLE t(a); INSERT INTO t VALUES(''x''); INSERT INTO t VALUES(''y'')',
        'SELECT group_concat(a,''-'') FROM t'); // x-y
  Probe('avg result type',
        'CREATE TABLE t(a); INSERT INTO t VALUES(2); INSERT INTO t VALUES(4)',
        'SELECT typeof(avg(a)) FROM t'); // real
  Probe('total result type',
        'CREATE TABLE t(a); INSERT INTO t VALUES(2); INSERT INTO t VALUES(4)',
        'SELECT typeof(total(a)) FROM t'); // real
  Probe('like ESCAPE',
        '',
        'SELECT ''a%b'' LIKE ''a\%b'' ESCAPE ''\'''); // 1
  Probe('REGEXP missing',
        '',
        'SELECT ''abc'' GLOB ''a*''');  // 1
  Probe('CASE no else',
        '',
        'SELECT typeof(CASE 1 WHEN 2 THEN 3 END)');  // null
  Probe('CASE matches',
        '',
        'SELECT CASE 2 WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' END');  // 'b'

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
