{$I passqlite3.inc}
program TestTokenizer;
{
  Phase 7.1 gate test — SQL tokenizer (sqlite3GetToken) and
  statement-complete helper (sqlite3_complete).

  T1  Single-char tokens: ( ) , ; . + - * / % & ~ |
  T2  Multi-char operators: == <> != <= >= << >> || ->  ->>
  T3  Integer literals: 0  42  999
  T4  Float literals:  3.14  .5  1e10  2.5E-3
  T5  Hex literal: 0xDEAD
  T6  String literal: 'hello'  'it''s'  unterminated
  T7  Quoted identifier: "foo"  [bar]  `baz`
  T8  BLOB literal: x'CAFE'  X'00'  odd-digit illegal
  T9  Keyword recognition: SELECT CREATE TABLE etc.
  T10 Identifier: my_table  _x  T123
  T11 Variables: ?  ?42  :name  @var  $x
  T12 Comments: -- line comment  /* block */
  T13 Whitespace: spaces, tabs, newlines
  T14 sqlite3_complete: complete/incomplete statements
  T15 sqlite3_complete: CREATE TRIGGER with nested semicolons
  T16 sqlite3KeywordCode round-trip
  T17 sqlite3_keyword_name / sqlite3_keyword_count
  T18 Window-function keywords: WINDOW OVER FILTER

  Gate: all T1–T18 PASS.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3parser;

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(name: string; cond: Boolean);
begin
  if cond then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ Tokenise the whole string zSql and return the list of token codes
  (ignoring TK_SPACE and TK_COMMENT).  Result is a space-separated
  string of decimal codes for easy comparison. }
function TokeniseAll(zSql: PAnsiChar): string;
var
  z:  PByte;
  n:  i64;
  tt: i32;
  s:  string;
begin
  z := PByte(zSql);
  s := '';
  while z^ <> 0 do begin
    n := sqlite3GetToken(z, @tt);
    if n = 0 then Break;
    if (tt <> TK_SPACE) and (tt <> TK_COMMENT) then begin
      if s <> '' then s := s + ' ';
      s := s + IntToStr(tt);
    end;
    z := z + n;
  end;
  Result := s;
end;

{ Return the token code for the first non-space token in zSql }
function FirstTok(zSql: PAnsiChar): i32;
var
  z:  PByte;
  n:  i64;
  tt: i32;
begin
  z := PByte(zSql);
  repeat
    n := sqlite3GetToken(z, @tt);
    if n = 0 then begin Result := TK_ILLEGAL; Exit; end;
    z := z + n;
  until tt <> TK_SPACE;
  Result := tt;
end;

{ Return the length of the first token in zSql }
function FirstTokLen(zSql: PAnsiChar): i64;
var
  z:  PByte;
  n:  i64;
  tt: i32;
begin
  z := PByte(zSql);
  n := sqlite3GetToken(z, @tt);
  Result := n;
end;

{ =========================================================================== }
{ T1 — single-character tokens                                                }
{ =========================================================================== }
procedure TestT1;
begin
  WriteLn('T1: single-char tokens');
  Check('LP',      FirstTok('(')  = TK_LP);
  Check('RP',      FirstTok(')')  = TK_RP);
  Check('COMMA',   FirstTok(',')  = TK_COMMA);
  Check('SEMI',    FirstTok(';')  = TK_SEMI);
  Check('PLUS',    FirstTok('+')  = TK_PLUS);
  Check('STAR',    FirstTok('*')  = TK_STAR);
  Check('PERCENT', FirstTok('%')  = TK_REM);
  Check('AND',     FirstTok('&')  = TK_BITAND);
  Check('TILDA',   FirstTok('~')  = TK_BITNOT);
  Check('SLASH',   FirstTok('/')  = TK_SLASH);
  Check('MINUS',   FirstTok('-a') = TK_MINUS);   { '-' not followed by '-' or '>' }
  Check('DOT',     FirstTok('.')  = TK_DOT);
end;

{ =========================================================================== }
{ T2 — multi-char operators                                                   }
{ =========================================================================== }
procedure TestT2;
begin
  WriteLn('T2: multi-char operators');
  Check('EQ  ==', FirstTok('==') = TK_EQ);
  Check('EQ  =',  FirstTok('=')  = TK_EQ);
  Check('NE  <>',  FirstTok('<>') = TK_NE);
  Check('NE  !=',  FirstTok('!=') = TK_NE);
  Check('LE  <=',  FirstTok('<=') = TK_LE);
  Check('GE  >=',  FirstTok('>=') = TK_GE);
  Check('LT  <',   FirstTok('<')  = TK_LT);
  Check('GT  >',   FirstTok('>')  = TK_GT);
  Check('LSHIFT',  FirstTok('<<') = TK_LSHIFT);
  Check('RSHIFT',  FirstTok('>>') = TK_RSHIFT);
  Check('CONCAT',  FirstTok('||') = TK_CONCAT);
  Check('BITOR',   FirstTok('|a') = TK_BITOR);
  Check('PTR1 ->', FirstTok('->x') = TK_PTR);
  Check('PTR2 ->>', FirstTokLen('->>') = 3);  { ->> is 3 bytes }
  Check('BANG_ill', FirstTok('!x') = TK_ILLEGAL);
end;

{ =========================================================================== }
{ T3 — integer literals                                                        }
{ =========================================================================== }
procedure TestT3;
begin
  WriteLn('T3: integer literals');
  Check('0',   FirstTok('0')   = TK_INTEGER);
  Check('42',  FirstTok('42')  = TK_INTEGER);
  Check('999', FirstTok('999') = TK_INTEGER);
  Check('len0',  FirstTokLen('0')   = 1);
  Check('len42', FirstTokLen('42')  = 2);
  Check('len999',FirstTokLen('999') = 3);
  { Letter after digit → TK_ILLEGAL }
  Check('1a ill', FirstTok('1a') = TK_ILLEGAL);
end;

{ =========================================================================== }
{ T4 — float literals                                                          }
{ =========================================================================== }
procedure TestT4;
begin
  WriteLn('T4: float literals');
  Check('3.14',    FirstTok('3.14')   = TK_FLOAT);
  Check('.5',      FirstTok('.5')     = TK_FLOAT);
  Check('1e10',    FirstTok('1e10')   = TK_FLOAT);
  Check('2.5E-3',  FirstTok('2.5E-3') = TK_FLOAT);
  Check('1E+2',    FirstTok('1E+2')   = TK_FLOAT);
  Check('3.14 len',FirstTokLen('3.14') = 4);
  Check('.5 len',  FirstTokLen('.5')   = 2);
end;

{ =========================================================================== }
{ T5 — hex integer literals                                                    }
{ =========================================================================== }
procedure TestT5;
begin
  WriteLn('T5: hex literals');
  Check('0xDEAD',  FirstTok('0xDEAD')  = TK_INTEGER);
  Check('0XCAFE',  FirstTok('0XCAFE')  = TK_INTEGER);
  Check('len hex', FirstTokLen('0xFF')  = 4);
  { 0x without hex digits: tokenizer lumps '0x' + alpha as one TK_ILLEGAL token }
  Check('0x_nohex', FirstTok('0x ') = TK_ILLEGAL);
end;

{ =========================================================================== }
{ T6 — string literals                                                         }
{ =========================================================================== }
procedure TestT6;
begin
  WriteLn('T6: string literals');
  Check('simple',   FirstTok('''hello''')   = TK_STRING);
  Check('escaped',  FirstTok('''it''''s''') = TK_STRING);
  Check('len hello',FirstTokLen('''hello''') = 7);
  { Unterminated string → TK_ILLEGAL }
  Check('unterm',   FirstTok('''abc') = TK_ILLEGAL);
end;

{ =========================================================================== }
{ T7 — quoted identifiers                                                      }
{ =========================================================================== }
procedure TestT7;
begin
  WriteLn('T7: quoted identifiers');
  Check('"foo"',   FirstTok('"foo"')   = TK_ID);
  Check('[bar]',   FirstTok('[bar]')   = TK_ID);
  Check('`baz`',   FirstTok('`baz`')  = TK_ID);
  Check('[unterm]', FirstTok('[abc')   = TK_ILLEGAL);
end;

{ =========================================================================== }
{ T8 — BLOB literals                                                           }
{ =========================================================================== }
procedure TestT8;
begin
  WriteLn('T8: BLOB literals');
  Check('x''CAFE''',  FirstTok('x''CAFE''') = TK_BLOB);
  Check('X''00''',    FirstTok('X''00''')    = TK_BLOB);
  Check('len x''FF''',FirstTokLen('x''FF''') = 5);  { x ' F F ' = 5 bytes }
  { Odd number of hex digits → TK_ILLEGAL }
  Check('odd hex', FirstTok('x''ABC''') = TK_ILLEGAL);
  { x not followed by ' → identifier }
  Check('x_id',   FirstTok('xyz') = TK_ID);
end;

{ =========================================================================== }
{ T9 — keyword recognition                                                     }
{ =========================================================================== }
procedure TestT9;
begin
  WriteLn('T9: keyword recognition');
  Check('SELECT',  FirstTok('SELECT')  = TK_SELECT);
  Check('select',  FirstTok('select')  = TK_SELECT);  { case-insensitive }
  Check('CREATE',  FirstTok('CREATE')  = TK_CREATE);
  Check('TABLE',   FirstTok('TABLE')   = TK_TABLE);
  Check('INSERT',  FirstTok('INSERT')  = TK_INSERT);
  Check('WHERE',   FirstTok('WHERE')   = TK_WHERE);
  Check('FROM',    FirstTok('FROM')    = TK_FROM);
  Check('AND',     FirstTok('AND')     = TK_AND);
  Check('OR',      FirstTok('OR')      = TK_OR);
  Check('NOT',     FirstTok('NOT')     = TK_NOT);
  Check('NULL',    FirstTok('NULL')    = TK_NULL);
  Check('BEGIN',   FirstTok('BEGIN')   = TK_BEGIN);
  Check('COMMIT',  FirstTok('COMMIT')  = TK_COMMIT);
  Check('ROLLBACK',FirstTok('ROLLBACK')= TK_ROLLBACK);
end;

{ =========================================================================== }
{ T10 — identifiers                                                            }
{ =========================================================================== }
procedure TestT10;
begin
  WriteLn('T10: identifiers');
  Check('my_table', FirstTok('my_table') = TK_ID);
  Check('_x',       FirstTok('_x')       = TK_ID);
  Check('T123',     FirstTok('T123')     = TK_ID);
  Check('selecter', FirstTok('selecter') = TK_ID);  { prefix of keyword but longer }
end;

{ =========================================================================== }
{ T11 — SQL variables                                                          }
{ =========================================================================== }
procedure TestT11;
begin
  WriteLn('T11: SQL variables');
  Check('?',    FirstTok('?')    = TK_VARIABLE);
  Check('?42',  FirstTok('?42')  = TK_VARIABLE);
  Check(':name',FirstTok(':name')= TK_VARIABLE);
  Check('@var', FirstTok('@var') = TK_VARIABLE);
  Check('$x',   FirstTok('$x')  = TK_VARIABLE);
  { Bare @ with no chars → TK_ILLEGAL }
  Check('@ ill',FirstTok('@ ') = TK_ILLEGAL);
end;

{ =========================================================================== }
{ T12 — comments                                                               }
{ =========================================================================== }
procedure TestT12;
begin
  WriteLn('T12: comments');
  Check('-- comment', FirstTok('-- hello world'#10'x') = TK_COMMENT);
  Check('/* block */', FirstTok('/* block */') = TK_COMMENT);
  { After stripping comments, next token is correct }
  Check('tok after --',  TokeniseAll('-- hi'#10'SELECT') = IntToStr(TK_SELECT));
  Check('tok after /**/', TokeniseAll('/* x */ 42')       = IntToStr(TK_INTEGER));
end;

{ =========================================================================== }
{ T13 — whitespace                                                              }
{ =========================================================================== }
procedure TestT13;
var
  tt: i32;
  n:  i64;
begin
  WriteLn('T13: whitespace');
  { Call sqlite3GetToken directly — FirstTok skips spaces by design }
  n := sqlite3GetToken(PByte(PAnsiChar(' ')),  @tt); Check('space',  tt = TK_SPACE);
  n := sqlite3GetToken(PByte(PAnsiChar(#9)),   @tt); Check('tab',    tt = TK_SPACE);
  n := sqlite3GetToken(PByte(PAnsiChar(#10)),  @tt); Check('newline',tt = TK_SPACE);
  n := sqlite3GetToken(PByte(PAnsiChar(#13)),  @tt); Check('cr',     tt = TK_SPACE);
  { Multi-token: skip whitespace, get keyword }
  Check('ws+kw', TokeniseAll('  SELECT') = IntToStr(TK_SELECT));
end;

{ =========================================================================== }
{ T14 — sqlite3_complete                                                       }
{ =========================================================================== }
procedure TestT14;
begin
  WriteLn('T14: sqlite3_complete basic');
  Check('nil sql',    sqlite3_complete(nil) = 0);
  Check('empty',      sqlite3_complete('') = 0);
  Check('whitespace', sqlite3_complete('   ') = 0);
  Check('no semi',    sqlite3_complete('SELECT 1') = 0);
  Check('with semi',  sqlite3_complete('SELECT 1;') = 1);
  Check('two stmts',  sqlite3_complete('SELECT 1; SELECT 2;') = 1);
  Check('partial',    sqlite3_complete('SELECT 1; SELECT') = 0);
  Check('comment',    sqlite3_complete('-- comment'#10'SELECT 1;') = 1);
  Check('str w semi', sqlite3_complete('SELECT ''a;b'';') = 1);
end;

{ =========================================================================== }
{ T15 — sqlite3_complete with CREATE TRIGGER                                  }
{ =========================================================================== }
procedure TestT15;
begin
  WriteLn('T15: sqlite3_complete CREATE TRIGGER');
  { A trigger ends with ;END; }
  Check('trigger incomplete',
    sqlite3_complete(
      'CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; ') = 0);
  Check('trigger complete',
    sqlite3_complete(
      'CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END;') = 1);
  { EXPLAIN CREATE TRIGGER }
  Check('explain trigger',
    sqlite3_complete(
      'EXPLAIN CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END;') = 1);
  { TEMP TRIGGER }
  Check('temp trigger',
    sqlite3_complete(
      'CREATE TEMP TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END;') = 1);
end;

{ =========================================================================== }
{ T16 — sqlite3KeywordCode round-trip                                         }
{ =========================================================================== }
procedure TestT16;
begin
  WriteLn('T16: sqlite3KeywordCode');
  Check('SELECT', sqlite3KeywordCode(PByte(PAnsiChar('SELECT')), 6) = TK_SELECT);
  Check('select', sqlite3KeywordCode(PByte(PAnsiChar('select')), 6) = TK_SELECT);
  Check('table',  sqlite3KeywordCode(PByte(PAnsiChar('table')),  5) = TK_TABLE);
  Check('notkey', sqlite3KeywordCode(PByte(PAnsiChar('foobar')), 6) = TK_ID);
  Check('short',  sqlite3KeywordCode(PByte(PAnsiChar('s')),      1) = TK_ID);
end;

{ =========================================================================== }
{ T17 — sqlite3_keyword_name / sqlite3_keyword_count                          }
{ =========================================================================== }
procedure TestT17;
var
  pName: PAnsiChar;
  nName: i32;
  i, cnt: i32;
  found: Boolean;
begin
  WriteLn('T17: keyword API');
  cnt := sqlite3_keyword_count;
  Check('count = 147', cnt = 147);

  { First keyword in the table (index 0) must have nName in [2..20] }
  Check('kw0 ok',
    (sqlite3_keyword_name(0, pName, nName) = SQLITE_OK) and
    (nName >= 2) and (nName <= 20));

  { Out-of-range returns SQLITE_ERROR }
  Check('oob-1',   sqlite3_keyword_name(-1,  pName, nName) = SQLITE_ERROR);
  Check('oob-147', sqlite3_keyword_name(cnt, pName, nName) = SQLITE_ERROR);

  { sqlite3_keyword_check returns 1 for known keywords }
  Check('check SELECT', sqlite3_keyword_check('SELECT', 6) = 1);
  Check('check select', sqlite3_keyword_check('select', 6) = 1);
  Check('check foobar', sqlite3_keyword_check('foobar', 6) = 0);

  { Scan all keywords to ensure SELECT appears }
  found := False;
  for i := 0 to cnt - 1 do begin
    if sqlite3_keyword_name(i, pName, nName) = SQLITE_OK then begin
      if (nName = 6) and
         (sqlite3_strnicmp(pName, 'SELECT', 6) = 0) then
        found := True;
    end;
  end;
  Check('SELECT in table', found);
end;

{ =========================================================================== }
{ T18 — WINDOW / OVER / FILTER are recognised correctly                       }
{ =========================================================================== }
procedure TestT18;
var
  tt: i32;
  n:  i64;
  z:  PByte;
begin
  WriteLn('T18: WINDOW / OVER / FILTER tokens');

  { Raw tokeniser returns TK_WINDOW for "WINDOW" }
  z := PByte(PAnsiChar('WINDOW'));
  n := sqlite3GetToken(z, @tt);
  Check('WINDOW tok',  tt = TK_WINDOW);
  Check('WINDOW len',  n  = 6);

  z := PByte(PAnsiChar('OVER'));
  n := sqlite3GetToken(z, @tt);
  Check('OVER tok',    tt = TK_OVER);
  Check('OVER len',    n  = 4);

  z := PByte(PAnsiChar('FILTER'));
  n := sqlite3GetToken(z, @tt);
  Check('FILTER tok',  tt = TK_FILTER);
  Check('FILTER len',  n  = 6);

  { These tokens are in the range >= TK_WINDOW }
  Check('WINDOW >= TK_WINDOW', TK_WINDOW >= TK_WINDOW);
  Check('OVER   >= TK_WINDOW', TK_OVER   >= TK_WINDOW);
  Check('FILTER >= TK_WINDOW', TK_FILTER >= TK_WINDOW);

  { Tokenise a simple window expression fragment }
  Check('SELECT+OVER',
    TokeniseAll('SELECT OVER') =
      IntToStr(TK_SELECT) + ' ' + IntToStr(TK_OVER));
end;

{ =========================================================================== }
{ main                                                                         }
{ =========================================================================== }
begin
  WriteLn('=== TestTokenizer — Phase 7.1 gate test ===');
  WriteLn;

  TestT1;  WriteLn;
  TestT2;  WriteLn;
  TestT3;  WriteLn;
  TestT4;  WriteLn;
  TestT5;  WriteLn;
  TestT6;  WriteLn;
  TestT7;  WriteLn;
  TestT8;  WriteLn;
  TestT9;  WriteLn;
  TestT10; WriteLn;
  TestT11; WriteLn;
  TestT12; WriteLn;
  TestT13; WriteLn;
  TestT14; WriteLn;
  TestT15; WriteLn;
  TestT16; WriteLn;
  TestT17; WriteLn;
  TestT18; WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
