{$I passqlite3.inc}
program TestJson;
{
  Phase 6.8.a gate — passqlite3json foundation.

  Exercises the lookup tables (jsonbType, jsonIsSpace, jsonSpaces,
  jsonIsOk, aNanInfName) and the pure helpers (jsonIsspace,
  jsonHexToInt, jsonHexToInt4, jsonIs2Hex, jsonIs4Hex,
  json5Whitespace).  All tests are self-contained — no DB or
  sqlite3_context required at this layer.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3json;

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure CheckEqI(name: AnsiString; got, want: i64);
begin
  if got = want then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name, ' got=', got, ' want=', want);
    Inc(gFail);
  end;
end;

procedure CheckEqS(name, got, want: AnsiString);
begin
  if got = want then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name, ' got="', got, '" want="', want, '"');
    Inc(gFail);
  end;
end;

procedure CheckTrue(name: AnsiString; cond: Boolean);
begin
  if cond then begin WriteLn('  PASS ', name); Inc(gPass); end
  else        begin WriteLn('  FAIL ', name); Inc(gFail); end;
end;

{ ------------ Test groups ------------ }

procedure TestTypeNames;
begin
  CheckEqS('T1 jsonbType[NULL]',    StrPas(jsonbType[JSONB_NULL]),   'null');
  CheckEqS('T2 jsonbType[TRUE]',    StrPas(jsonbType[JSONB_TRUE]),   'true');
  CheckEqS('T3 jsonbType[FALSE]',   StrPas(jsonbType[JSONB_FALSE]),  'false');
  CheckEqS('T4 jsonbType[INT]',     StrPas(jsonbType[JSONB_INT]),    'integer');
  CheckEqS('T5 jsonbType[INT5]',    StrPas(jsonbType[JSONB_INT5]),   'integer');
  CheckEqS('T6 jsonbType[FLOAT]',   StrPas(jsonbType[JSONB_FLOAT]),  'real');
  CheckEqS('T7 jsonbType[FLOAT5]',  StrPas(jsonbType[JSONB_FLOAT5]), 'real');
  CheckEqS('T8 jsonbType[TEXT]',    StrPas(jsonbType[JSONB_TEXT]),   'text');
  CheckEqS('T9 jsonbType[TEXTJ]',   StrPas(jsonbType[JSONB_TEXTJ]),  'text');
  CheckEqS('T10 jsonbType[TEXT5]',  StrPas(jsonbType[JSONB_TEXT5]),  'text');
  CheckEqS('T11 jsonbType[TEXTRAW]', StrPas(jsonbType[JSONB_TEXTRAW]), 'text');
  CheckEqS('T12 jsonbType[ARRAY]',  StrPas(jsonbType[JSONB_ARRAY]),  'array');
  CheckEqS('T13 jsonbType[OBJECT]', StrPas(jsonbType[JSONB_OBJECT]), 'object');
  CheckEqS('T14 jsonbType[13] reserved', StrPas(jsonbType[13]), '');
  CheckEqS('T15 jsonbType[16] reserved', StrPas(jsonbType[16]), '');
end;

procedure TestIsspace;
begin
  CheckEqI('T16 isspace HT',   jsonIsspace(#$09), 1);
  CheckEqI('T17 isspace LF',   jsonIsspace(#$0A), 1);
  CheckEqI('T18 isspace CR',   jsonIsspace(#$0D), 1);
  CheckEqI('T19 isspace SP',   jsonIsspace(' '),  1);
  CheckEqI('T20 isspace VT',   jsonIsspace(#$0B), 0);  { not JSON ws }
  CheckEqI('T21 isspace FF',   jsonIsspace(#$0C), 0);  { not JSON ws }
  CheckEqI('T22 isspace 0',    jsonIsspace(#0),   0);
  CheckEqI('T23 isspace A',    jsonIsspace('A'),  0);
  CheckEqI('T24 isspace high', jsonIsspace(#$80), 0);
  CheckEqI('T25 isspace 0xff', jsonIsspace(#$FF), 0);
end;

procedure TestSpacesString;
begin
  CheckTrue('T26 jsonSpaces length 4', StrLen(jsonSpaces) = 4);
  CheckTrue('T27 jsonSpaces[0]=HT',  jsonSpaces[0] = #$09);
  CheckTrue('T28 jsonSpaces[1]=LF',  jsonSpaces[1] = #$0A);
  CheckTrue('T29 jsonSpaces[2]=CR',  jsonSpaces[2] = #$0D);
  CheckTrue('T30 jsonSpaces[3]=SP',  jsonSpaces[3] = #$20);
end;

procedure TestIsOk;
var
  c: i32;
begin
  CheckEqI('T31 isOk NUL=0',     jsonIsOk[0],            0);
  CheckEqI('T32 isOk 0x1f=0',    jsonIsOk[$1F],          0);
  CheckEqI('T33 isOk SP=1',      jsonIsOk[$20],          1);
  CheckEqI('T34 isOk dquote=0',  jsonIsOk[Ord('"')],     0);
  CheckEqI('T35 isOk squote=0',  jsonIsOk[Ord('''')],    0);
  CheckEqI('T36 isOk bslash=0',  jsonIsOk[Ord('\')],     0);
  CheckEqI('T37 isOk A=1',       jsonIsOk[Ord('A')],     1);
  CheckEqI('T38 isOk z=1',       jsonIsOk[Ord('z')],     1);
  CheckEqI('T39 isOk 0xe0=0',    jsonIsOk[$E0],          0);
  CheckEqI('T40 isOk 0xe1=1',    jsonIsOk[$E1],          1);
  CheckEqI('T41 isOk 0x80=1',    jsonIsOk[$80],          1);
  { Spot-check: every byte not in {0..0x1f,0x22,0x27,0x5c,0xe0} should be 1. }
  for c := 0 to 255 do
  begin
    if (c <= $1F) or (c = $22) or (c = $27) or (c = $5C) or (c = $E0) then
    begin
      if jsonIsOk[c] <> 0 then
      begin
        WriteLn('  FAIL T42 isOk[', c, '] expected 0');
        Inc(gFail);
        Exit;
      end;
    end
    else
    begin
      if jsonIsOk[c] <> 1 then
      begin
        WriteLn('  FAIL T42 isOk[', c, '] expected 1');
        Inc(gFail);
        Exit;
      end;
    end;
  end;
  WriteLn('  PASS T42 isOk full 256-byte parity');
  Inc(gPass);
end;

procedure TestHexHelpers;
begin
  CheckEqI('T43 HexToInt(0)',  jsonHexToInt(Ord('0')), 0);
  CheckEqI('T44 HexToInt(9)',  jsonHexToInt(Ord('9')), 9);
  CheckEqI('T45 HexToInt(A)',  jsonHexToInt(Ord('A')), 10);
  CheckEqI('T46 HexToInt(F)',  jsonHexToInt(Ord('F')), 15);
  CheckEqI('T47 HexToInt(a)',  jsonHexToInt(Ord('a')), 10);
  CheckEqI('T48 HexToInt(f)',  jsonHexToInt(Ord('f')), 15);

  CheckEqI('T49 HexToInt4 0000', jsonHexToInt4('0000'), 0);
  CheckEqI('T50 HexToInt4 ffff', jsonHexToInt4('ffff'), $FFFF);
  CheckEqI('T51 HexToInt4 FFFF', jsonHexToInt4('FFFF'), $FFFF);
  CheckEqI('T52 HexToInt4 1234', jsonHexToInt4('1234'), $1234);
  CheckEqI('T53 HexToInt4 abcd', jsonHexToInt4('abcd'), $ABCD);
  CheckEqI('T54 HexToInt4 dEaD', jsonHexToInt4('dEaD'), $DEAD);

  CheckEqI('T55 Is2Hex 12',    jsonIs2Hex('12'), 1);
  CheckEqI('T56 Is2Hex 1g',    jsonIs2Hex('1g'), 0);
  CheckEqI('T57 Is2Hex g1',    jsonIs2Hex('g1'), 0);
  CheckEqI('T58 Is4Hex 1234',  jsonIs4Hex('1234'), 1);
  CheckEqI('T59 Is4Hex 123g',  jsonIs4Hex('123g'), 0);
  CheckEqI('T60 Is4Hex 12g4',  jsonIs4Hex('12g4'), 0);
  CheckEqI('T61 Is4Hex deadbeef', jsonIs4Hex('deadbeef'), 1);
end;

procedure TestJson5WS;
begin
  { ASCII whitespace cluster — HT LF VT FF CR SP. }
  CheckEqI('T62 ws empty',       json5Whitespace(''), 0);
  CheckEqI('T63 ws all-ASCII',   json5Whitespace(#$09#$0A#$0B#$0C#$0D#$20'x'), 6);
  CheckEqI('T64 ws no-ws head',  json5Whitespace('abc'), 0);
  CheckEqI('T65 ws sp+abc',      json5Whitespace('   abc'), 3);

  { Block comment. }
  CheckEqI('T66 ws /*..*/',      json5Whitespace('/* hi */abc'), 8);
  CheckEqI('T67 ws unterm /*',   json5Whitespace('/* no end here'), 0);

  { Line comment. }
  CheckEqI('T68 ws //EOL',       json5Whitespace('// foo'#10'rest'), 7);
  CheckEqI('T69 ws // CR',       json5Whitespace('// foo'#13'rest'), 7);
  CheckEqI('T70 ws // EOF',      json5Whitespace('// to-eof'), 9);

  { Bare slash that is not a comment is not whitespace. }
  CheckEqI('T71 ws bare /',      json5Whitespace('/abc'), 0);

  { Unicode whitespace: NBSP (U+00A0 = c2 a0). }
  CheckEqI('T72 ws NBSP',        json5Whitespace(#$C2#$A0'x'), 2);
  { Ogham (U+1680 = e1 9a 80). }
  CheckEqI('T73 ws Ogham',       json5Whitespace(#$E1#$9A#$80'x'), 3);
  { En quad (U+2000 = e2 80 80). }
  CheckEqI('T74 ws En quad',     json5Whitespace(#$E2#$80#$80'x'), 3);
  { Hair space (U+200A = e2 80 8a). }
  CheckEqI('T75 ws Hair',        json5Whitespace(#$E2#$80#$8A'x'), 3);
  { Line separator (U+2028 = e2 80 a8). }
  CheckEqI('T76 ws LineSep',     json5Whitespace(#$E2#$80#$A8'x'), 3);
  { Para separator (U+2029 = e2 80 a9). }
  CheckEqI('T77 ws ParaSep',     json5Whitespace(#$E2#$80#$A9'x'), 3);
  { NNBSP (U+202F = e2 80 af). }
  CheckEqI('T78 ws NNBSP',       json5Whitespace(#$E2#$80#$AF'x'), 3);
  { 0x8b — not a valid Unicode space; should stop. }
  CheckEqI('T79 ws E2 80 8b',    json5Whitespace(#$E2#$80#$8B'x'), 0);
  { MMSP (U+205F = e2 81 9f). }
  CheckEqI('T80 ws MMSP',        json5Whitespace(#$E2#$81#$9F'x'), 3);
  { Ideographic space (U+3000 = e3 80 80). }
  CheckEqI('T81 ws Ideographic', json5Whitespace(#$E3#$80#$80'x'), 3);
  { BOM (U+FEFF = ef bb bf). }
  CheckEqI('T82 ws BOM',         json5Whitespace(#$EF#$BB#$BF'x'), 3);

  { Combination: BOM + spaces + block comment + spaces + content. }
  CheckEqI('T83 ws combo',
           json5Whitespace(#$EF#$BB#$BF'  /*z*/  rest'),
           3 + 2 + 5 + 2);
end;

procedure TestNanInf;
begin
  CheckEqS('T84 NanInf[0].zMatch',  StrPas(aNanInfName[0].zMatch), 'inf');
  CheckEqS('T85 NanInf[0].zRepl',   StrPas(aNanInfName[0].zRepl),  '9.0e999');
  CheckEqI('T86 NanInf[0].n',       aNanInfName[0].n, 3);
  CheckEqI('T87 NanInf[0].eType',   aNanInfName[0].eType, JSONB_FLOAT);
  CheckEqI('T88 NanInf[0].nRepl',   aNanInfName[0].nRepl, 7);

  CheckEqS('T89 NanInf[1].zMatch',  StrPas(aNanInfName[1].zMatch), 'infinity');
  CheckEqI('T90 NanInf[1].n',       aNanInfName[1].n, 8);

  CheckEqS('T91 NanInf[2].zMatch',  StrPas(aNanInfName[2].zMatch), 'NaN');
  CheckEqS('T92 NanInf[2].zRepl',   StrPas(aNanInfName[2].zRepl),  'null');
  CheckEqI('T93 NanInf[2].eType',   aNanInfName[2].eType, JSONB_NULL);

  CheckEqS('T94 NanInf[3].zMatch',  StrPas(aNanInfName[3].zMatch), 'QNaN');
  CheckEqS('T95 NanInf[4].zMatch',  StrPas(aNanInfName[4].zMatch), 'SNaN');
end;

procedure TestSizes;
begin
  { Smoke-check the record sizes are sensible.  These are not byte-for-byte
    parity checks (FPC layout differs from gcc in alignment edge cases),
    just a tripwire against accidental record-shape regressions. }
  CheckTrue('T96 sizeof(JsonString) reasonable',
    (SizeOf(TJsonString) >= 100) and (SizeOf(TJsonString) <= 256));
  CheckTrue('T97 sizeof(JsonParse) reasonable',
    (SizeOf(TJsonParse) >= 60) and (SizeOf(TJsonParse) <= 96));
  CheckTrue('T98 sizeof(JsonCache) reasonable',
    (SizeOf(TJsonCache) >= 40) and (SizeOf(TJsonCache) <= 64));
end;

{ ------------ Phase 6.8.b — JsonString accumulator ------------ }

function StrFromJS(p: PJsonString): AnsiString;
begin
  SetString(Result, p^.zBuf, p^.nUsed);
end;

procedure TestStringInit;
var s: TJsonString;
begin
  jsonStringInit(@s, nil);
  CheckTrue('T99 init bStatic',  s.bStatic = 1);
  CheckTrue('T100 init nUsed=0', s.nUsed = 0);
  CheckTrue('T101 init nAlloc=100', s.nAlloc = 100);
  CheckTrue('T102 init eErr=0', s.eErr = 0);
  CheckTrue('T103 init zBuf=zSpace', s.zBuf = @s.zSpace[0]);
  jsonStringReset(@s);
  CheckTrue('T104 reset bStatic', s.bStatic = 1);
  CheckTrue('T105 reset nUsed=0', s.nUsed = 0);
end;

procedure TestAppendBasic;
var s: TJsonString;
begin
  jsonStringInit(@s, nil);
  jsonAppendRaw(@s, 'hello', 5);
  CheckEqS('T106 append hello',   StrFromJS(@s), 'hello');
  jsonAppendRaw(@s, ' world', 6);
  CheckEqS('T107 append world',   StrFromJS(@s), 'hello world');
  jsonAppendChar(@s, '!');
  CheckEqS('T108 append char',    StrFromJS(@s), 'hello world!');
  jsonStringReset(@s);
  CheckEqS('T109 reset empties',  StrFromJS(@s), '');
end;

procedure TestAppendSpill;
var
  s: TJsonString;
  i: i32;
  big: AnsiString;
begin
  jsonStringInit(@s, nil);
  big := '';
  for i := 1 to 50 do big := big + 'abcdefghij'; { 500 bytes — spills }
  jsonAppendRaw(@s, PAnsiChar(big), Length(big));
  CheckEqS('T110 spill content', StrFromJS(@s), big);
  CheckTrue('T111 spill bStatic=0', s.bStatic = 0);
  CheckTrue('T112 spill nAlloc grew', s.nAlloc >= 500);
  CheckTrue('T113 spill nUsed=500', s.nUsed = 500);
  jsonStringReset(@s);
  CheckTrue('T114 after-reset bStatic=1', s.bStatic = 1);
  CheckTrue('T115 after-reset nAlloc=100', s.nAlloc = 100);
end;

procedure TestAppendCharGrow;
var
  s: TJsonString;
  i: i32;
begin
  jsonStringInit(@s, nil);
  for i := 1 to 250 do jsonAppendChar(@s, 'x');
  CheckTrue('T116 char-grow nUsed=250', s.nUsed = 250);
  CheckTrue('T117 char-grow spilled', s.bStatic = 0);
  for i := 0 to 249 do
    if s.zBuf[i] <> 'x' then
    begin
      WriteLn('  FAIL T118 char-grow content');
      Inc(gFail);
      jsonStringReset(@s);
      Exit;
    end;
  WriteLn('  PASS T118 char-grow content');
  Inc(gPass);
  jsonStringReset(@s);
end;

procedure TestSeparator;
var s: TJsonString;
begin
  jsonStringInit(@s, nil);
  jsonAppendSeparator(@s);
  CheckEqS('T119 sep on empty no-op', StrFromJS(@s), '');
  jsonAppendChar(@s, '[');
  jsonAppendSeparator(@s);
  CheckEqS('T120 sep after [',  StrFromJS(@s), '[');
  jsonAppendChar(@s, '1');
  jsonAppendSeparator(@s);
  CheckEqS('T121 sep after 1',  StrFromJS(@s), '[1,');
  jsonStringReset(@s);
  jsonAppendChar(@s, '{');
  jsonAppendSeparator(@s);
  CheckEqS('T122 sep after {',  StrFromJS(@s), '{');
  jsonStringReset(@s);
end;

procedure TestTrimAndTerminate;
var
  s: TJsonString;
  rc: i32;
begin
  jsonStringInit(@s, nil);
  jsonAppendRaw(@s, 'abc', 3);
  jsonStringTrimOneChar(@s);
  CheckEqS('T123 trim',       StrFromJS(@s), 'ab');
  rc := jsonStringTerminate(@s);
  CheckEqI('T124 terminate ok',  rc, 1);
  CheckEqS('T125 nUsed unchanged', StrFromJS(@s), 'ab');
  CheckTrue('T126 nul placed', s.zBuf[s.nUsed] = #0);
  jsonStringReset(@s);
end;

procedure TestControlChar;
var s: TJsonString;
begin
  jsonStringInit(@s, nil);
  { Caller must reserve 7 bytes per spec.  100 inline is enough for 5 calls. }
  jsonAppendControlChar(@s, $08);  { \b }
  jsonAppendControlChar(@s, $09);  { \t }
  jsonAppendControlChar(@s, $0A);  { \n }
  jsonAppendControlChar(@s, $0C);  { \f }
  jsonAppendControlChar(@s, $0D);  { \r }
  CheckEqS('T127 short escapes', StrFromJS(@s), '\b\t\n\f\r');
  jsonStringReset(@s);
  jsonAppendControlChar(@s, $00);  {   }
  jsonAppendControlChar(@s, $01);  {  }
  jsonAppendControlChar(@s, $1F);  {  }
  CheckEqS('T128 long escapes',  StrFromJS(@s), '\u0000\u0001\u001f');
  jsonStringReset(@s);
end;

procedure TestAppendString;
var s: TJsonString;
begin
  jsonStringInit(@s, nil);
  jsonAppendString(@s, 'hello', 5);
  CheckEqS('T129 plain',         StrFromJS(@s), '"hello"');
  jsonStringReset(@s);
  jsonAppendString(@s, 'a"b', 3);
  CheckEqS('T130 dquote escape', StrFromJS(@s), '"a\"b"');
  jsonStringReset(@s);
  jsonAppendString(@s, 'a\b', 3);
  CheckEqS('T131 bslash escape', StrFromJS(@s), '"a\\b"');
  jsonStringReset(@s);
  jsonAppendString(@s, 'a'#10'b', 3);
  CheckEqS('T132 newline esc',   StrFromJS(@s), '"a\nb"');
  jsonStringReset(@s);
  jsonAppendString(@s, 'a'#1'b', 3);
  CheckEqS('T133 ctl esc',       StrFromJS(@s), '"a\u0001b"');
  jsonStringReset(@s);
  jsonAppendString(@s, '', 0);
  CheckEqS('T134 empty quoted',  StrFromJS(@s), '""');
  jsonStringReset(@s);
  { JSON5 single quote inside string is passed through unescaped per
    json.c:786-788 special case. }
  jsonAppendString(@s, 'it''s', 4);
  CheckEqS('T135 single quote', StrFromJS(@s), '"it''s"');
  jsonStringReset(@s);
  { 4-way unwound fast path covers k+3<N: ensure 8-byte plain run works. }
  jsonAppendString(@s, '01234567', 8);
  CheckEqS('T136 fast-path 8B', StrFromJS(@s), '"01234567"');
  jsonStringReset(@s);
end;

procedure TestStringSpill;
var
  s: TJsonString;
  i: i32;
  big: AnsiString;
  expected: AnsiString;
begin
  jsonStringInit(@s, nil);
  big := '';
  for i := 1 to 30 do big := big + 'abcdefghij'; { 300 bytes }
  jsonAppendString(@s, PAnsiChar(big), Length(big));
  expected := '"' + big + '"';
  CheckEqS('T137 string spill', StrFromJS(@s), expected);
  CheckTrue('T138 string spill bStatic=0', s.bStatic = 0);
  jsonStringReset(@s);
end;

procedure TestStringNil;
var s: TJsonString;
begin
  jsonStringInit(@s, nil);
  jsonAppendString(@s, nil, 0);
  CheckEqS('T139 nil ptr no-op', StrFromJS(@s), '');
  jsonStringReset(@s);
end;

begin
  WriteLn('=== TestJson — Phase 6.8.a/b JSON foundation + accumulator ===');
  TestTypeNames;
  TestIsspace;
  TestSpacesString;
  TestIsOk;
  TestHexHelpers;
  TestJson5WS;
  TestNanInf;
  TestSizes;
  TestStringInit;
  TestAppendBasic;
  TestAppendSpill;
  TestAppendCharGrow;
  TestSeparator;
  TestTrimAndTerminate;
  TestControlChar;
  TestAppendString;
  TestStringSpill;
  TestStringNil;
  WriteLn;
  WriteLn('=== Total: ', gPass, ' pass, ', gFail, ' fail ===');
  if gFail > 0 then Halt(1);
end.
