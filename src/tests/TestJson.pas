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
  passqlite3os,
  passqlite3util,
  passqlite3vdbe,
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

{ ----- Phase 6.8.c blob primitive tests ----- }

procedure InitParse(out p: TJsonParse);
begin
  FillChar(p, SizeOf(p), 0);
end;

procedure FreeParse(var p: TJsonParse);
begin
  if p.aBlob <> nil then sqlite3_free(p.aBlob);
  p.aBlob := nil;
  p.nBlob := 0;
  p.nBlobAlloc := 0;
end;

procedure TestBlobExpand;
var p: TJsonParse; rc: i32;
begin
  InitParse(p);
  rc := jsonBlobExpand(@p, 50);
  CheckEqI('T140 blobExpand initial rc', rc, 0);
  CheckEqI('T141 blobExpand alloc>=100', i64(p.nBlobAlloc), 100);
  rc := jsonBlobExpand(@p, 200);
  CheckEqI('T142 blobExpand grow rc', rc, 0);
  CheckTrue('T143 blobExpand alloc>=200', p.nBlobAlloc >= 200);
  FreeParse(p);
end;

procedure TestBlobMakeEditable;
var
  p: TJsonParse;
  raw: array[0..4] of u8 = ($11, $22, $33, $44, $55);
  rc: i32;
begin
  InitParse(p);
  p.aBlob := @raw[0];
  p.nBlob := 5;
  p.nBlobAlloc := 0;  { external, not editable }
  rc := jsonBlobMakeEditable(@p, 3);
  CheckEqI('T144 makeEditable rc', rc, 1);
  CheckTrue('T145 makeEditable alloc>=8', p.nBlobAlloc >= 8);
  CheckTrue('T146 makeEditable copied byte0', p.aBlob[0] = $11);
  CheckTrue('T147 makeEditable copied byte4', p.aBlob[4] = $55);
  FreeParse(p);
end;

procedure TestBlobAppendOneByte;
var p: TJsonParse; i: i32;
begin
  InitParse(p);
  for i := 0 to 9 do
    jsonBlobAppendOneByte(@p, u8(i + $A0));
  CheckEqI('T148 append10 nBlob', p.nBlob, 10);
  CheckTrue('T149 append10 byte0', p.aBlob[0] = $A0);
  CheckTrue('T150 append10 byte9', p.aBlob[9] = $A9);
  FreeParse(p);
end;

procedure TestBlobAppendNode;
var p: TJsonParse;
begin
  InitParse(p);
  { tiny payload (sz<=11) → 1-byte hdr }
  jsonBlobAppendNode(@p, JSONB_INT, 3, PAnsiChar('123'));
  CheckEqI('T151 small nBlob=4',  p.nBlob, 4);
  CheckTrue('T152 small hdr',      p.aBlob[0] = (JSONB_INT or (3 shl 4)));
  CheckTrue('T153 small p[0]',     p.aBlob[1] = Ord('1'));
  FreeParse(p);

  { 1-byte sz extension (12..255) }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_TEXT, 100, nil);
  CheckEqI('T154 mid hdr len',     p.nBlob, 2);
  CheckTrue('T155 mid hdr0',       p.aBlob[0] = (JSONB_TEXT or $C0));
  CheckTrue('T156 mid hdr1',       p.aBlob[1] = 100);
  FreeParse(p);

  { 2-byte sz extension (256..65535) }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_ARRAY, 1000, nil);
  CheckEqI('T157 d hdr len',       p.nBlob, 3);
  CheckTrue('T158 d hdr0',         p.aBlob[0] = (JSONB_ARRAY or $D0));
  CheckTrue('T159 d hi',           p.aBlob[1] = ((1000 shr 8) and $FF));
  CheckTrue('T160 d lo',           p.aBlob[2] = (1000 and $FF));
  FreeParse(p);

  { 4-byte sz extension (>65535) }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_OBJECT, 100000, nil);
  CheckEqI('T161 e hdr len',       p.nBlob, 5);
  CheckTrue('T162 e hdr0',         p.aBlob[0] = (JSONB_OBJECT or $E0));
  CheckTrue('T163 e b1', p.aBlob[1] = ((100000 shr 24) and $FF));
  CheckTrue('T164 e b2', p.aBlob[2] = ((100000 shr 16) and $FF));
  CheckTrue('T165 e b3', p.aBlob[3] = ((100000 shr 8) and $FF));
  CheckTrue('T166 e b4', p.aBlob[4] = (100000 and $FF));
  FreeParse(p);
end;

procedure TestPayloadSize;
var p: TJsonParse; sz, n: u32;
begin
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_INT, 5, PAnsiChar('12345'));
  n := jsonbPayloadSize(@p, 0, sz);
  CheckEqI('T167 ps small n',  n, 1);
  CheckEqI('T168 ps small sz', sz, 5);
  FreeParse(p);

  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_TEXT, 200, nil);
  { Append 200 zero payload bytes by extending nBlob: }
  if p.nBlobAlloc < p.nBlob + 200 then jsonBlobExpand(@p, p.nBlob + 200);
  p.nBlob := p.nBlob + 200;
  n := jsonbPayloadSize(@p, 0, sz);
  CheckEqI('T169 ps mid n',  n, 2);
  CheckEqI('T170 ps mid sz', sz, 200);
  FreeParse(p);

  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_ARRAY, 1000, nil);
  if p.nBlobAlloc < p.nBlob + 1000 then jsonBlobExpand(@p, p.nBlob + 1000);
  p.nBlob := p.nBlob + 1000;
  n := jsonbPayloadSize(@p, 0, sz);
  CheckEqI('T171 ps d n',  n, 3);
  CheckEqI('T172 ps d sz', sz, 1000);
  FreeParse(p);
end;

procedure TestChangePayloadSize;
var p: TJsonParse; delta: i32; sz, n: u32;
begin
  { Grow header from 1 → 2 byte sz: append a small node, then grow it. }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_TEXT, 5, PAnsiChar('hello'));
  CheckEqI('T173 cps init nBlob', p.nBlob, 6);
  delta := jsonBlobChangePayloadSize(@p, 0, 200);
  CheckEqI('T174 cps delta=+1',   delta, 1);
  CheckEqI('T175 cps new nBlob',  p.nBlob, 7);
  CheckTrue('T176 cps new hdr0',  p.aBlob[0] = (JSONB_TEXT or $C0));
  CheckTrue('T177 cps new hdr1',  p.aBlob[1] = 200);
  { Original payload preserved at new offset }
  CheckTrue('T178 cps payload moved', p.aBlob[2] = Ord('h'));

  { Now check jsonbPayloadSize parses the new header. nBlob doesn't reflect
    actual paylod size 200; we need to fake it via nBlobAlloc check. }
  if p.nBlobAlloc < p.nBlob + 200 then jsonBlobExpand(@p, p.nBlob + 200);
  p.nBlob := 2 + 200;
  n := jsonbPayloadSize(@p, 0, sz);
  CheckEqI('T179 cps reads sz', sz, 200);
  CheckEqI('T180 cps reads n',  n,  2);
  FreeParse(p);

  { Shrink header: 2 → 1 byte sz }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_TEXT, 100, nil);
  if p.nBlobAlloc < p.nBlob + 100 then jsonBlobExpand(@p, p.nBlob + 100);
  p.aBlob[2] := Ord('A');
  p.nBlob := 2 + 100;
  delta := jsonBlobChangePayloadSize(@p, 0, 5);
  CheckEqI('T181 cps shrink delta=-1', delta, -1);
  CheckTrue('T182 cps shrink hdr',
            p.aBlob[0] = (JSONB_TEXT or (5 shl 4)));
  CheckTrue('T183 cps shrink moved A',  p.aBlob[1] = Ord('A'));
  FreeParse(p);
end;

procedure TestArrayCount;
var p: TJsonParse; cnt, sz: u32;
begin
  { Build [1,2,3] in JSONB:
    JSONB_ARRAY hdr (sz=3 small) + 3 INT entries each 1-byte hdr+1-byte payload }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_ARRAY, 6, nil);  { sz=6: 3*(hdr+payload) }
  jsonBlobAppendNode(@p, JSONB_INT,   1, PAnsiChar('1'));
  jsonBlobAppendNode(@p, JSONB_INT,   1, PAnsiChar('2'));
  jsonBlobAppendNode(@p, JSONB_INT,   1, PAnsiChar('3'));
  cnt := jsonbArrayCount(@p, 0);
  CheckEqI('T184 arrayCount=3', cnt, 3);
  { sentinel: array hdr decoded ok }
  jsonbPayloadSize(@p, 0, sz);
  CheckEqI('T185 arrayCount sz=6', sz, 6);
  FreeParse(p);
end;

procedure TestBlobEdit;
var
  p: TJsonParse;
  payload: array[0..2] of u8 = (Ord('A'), Ord('B'), Ord('C'));
begin
  { Pure delete (aIns=nil bypasses overwrite-fast-path): drop bytes 1..2
    of "hello" → "hlo". }
  InitParse(p);
  jsonBlobExpand(@p, 5);
  Move(PAnsiChar('hello')^, p.aBlob^, 5);
  p.nBlob := 5;
  jsonBlobEdit(@p, 1, 2, nil, 0);
  CheckEqI('T186 del nBlob',       p.nBlob, 3);
  CheckTrue('T187 del byte0',      p.aBlob[0] = Ord('h'));
  CheckTrue('T188 del byte1',      p.aBlob[1] = Ord('l'));
  CheckTrue('T189 del byte2',      p.aBlob[2] = Ord('o'));
  CheckEqI('T190 del delta=-2',    p.delta, -2);
  FreeParse(p);

  { Insert: replace 0 bytes at index 2 with 3 bytes "ABC" }
  InitParse(p);
  jsonBlobExpand(@p, 5);
  Move(PAnsiChar('hello')^, p.aBlob^, 5);
  p.nBlob := 5;
  jsonBlobEdit(@p, 2, 0, @payload[0], 3);
  CheckEqI('T192 ins nBlob', p.nBlob, 8);
  CheckTrue('T193 ins b0',   p.aBlob[0] = Ord('h'));
  CheckTrue('T194 ins b2',   p.aBlob[2] = Ord('A'));
  CheckTrue('T195 ins b4',   p.aBlob[4] = Ord('C'));
  CheckTrue('T196 ins b5',   p.aBlob[5] = Ord('l'));
  CheckEqI('T197 ins delta=+3', p.delta, 3);
  FreeParse(p);
end;

procedure TestAfterEditSizeAdjust;
var
  p: TJsonParse;
  sz: u32;
  n: u32;
begin
  { Build array hdr with sz=6, then simulate that an edit shrunk the
    contents by 2 — afterEditSizeAdjust must update the header. }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_ARRAY, 6, nil);
  if p.nBlobAlloc < p.nBlob + 6 then jsonBlobExpand(@p, p.nBlob + 6);
  p.nBlob := 1 + 6;
  p.delta := -2;
  { Pretend nBlob is post-edit (=5). }
  p.nBlob := 5;
  jsonAfterEditSizeAdjust(@p, 0);
  n := jsonbPayloadSize(@p, 0, sz);
  CheckEqI('T198 aesa sz=4',  sz, 4);
  CheckEqI('T199 aesa n=1',   n, 1);
  FreeParse(p);
end;

{ ----- Phase 6.8.d text→blob tests ----- }

procedure InitParseFromText(out p: TJsonParse; const s: AnsiString);
begin
  FillChar(p, SizeOf(p), 0);
  p.zJson := PAnsiChar(s);
  p.nJson := Length(s);
end;

procedure TestBytesToBypass;
var n: u32;
begin
  n := jsonBytesToBypass('\' + #10 + 'x', 3);
  CheckEqI('T200 b2b CR-style \n', n, 2);
  n := jsonBytesToBypass('\' + #13 + #10 + 'x', 4);
  CheckEqI('T201 b2b \r\n', n, 3);
  n := jsonBytesToBypass('\' + #13 + 'x', 3);
  CheckEqI('T202 b2b \r alone', n, 2);
  n := jsonBytesToBypass('\\x', 3);   { not a newline-escape }
  CheckEqI('T203 b2b nope', n, 0);
  n := jsonBytesToBypass('hi', 2);
  CheckEqI('T204 b2b nonbslash', n, 0);
  n := jsonBytesToBypass('\' + #$E2 + #$80 + #$A8 + 'x', 5);
  CheckEqI('T205 b2b LS', n, 4);
end;

procedure TestUnescapeOneChar;
var v: u32; n: u32;
begin
  n := jsonUnescapeOneChar('\n', 2, v);
  CheckEqI('T206 \n n', n, 2); CheckEqI('T207 \n c', v, $0A);
  n := jsonUnescapeOneChar('\t', 2, v);
  CheckEqI('T208 \t n', n, 2); CheckEqI('T209 \t c', v, $09);
  n := jsonUnescapeOneChar('\b', 2, v);
  CheckEqI('T210 \b c', v, $08);
  { \u escape: BMP code point U+00AB.  Build literal explicitly to avoid
    UTF-8 encoding tricks in the source file. }
  n := jsonUnescapeOneChar(PAnsiChar(#92'u00AB'), 6, v);
  CheckEqI('T211 u-esc n', n, 6); CheckEqI('T212 u-esc c', v, $00AB);
  n := jsonUnescapeOneChar('\x4f', 4, v);
  CheckEqI('T213 \x4f n', n, 4); CheckEqI('T214 \x4f c', v, $4F);
  n := jsonUnescapeOneChar('\v', 2, v);
  CheckEqI('T215 \v c', v, $0B);
  n := jsonUnescapeOneChar('\0', 2, v);
  CheckEqI('T216 \0 c', v, 0);
  n := jsonUnescapeOneChar('\"', 2, v);
  CheckEqI('T217 \" c', v, Ord('"'));
  n := jsonUnescapeOneChar('\\', 2, v);
  CheckEqI('T218 \\ c', v, Ord('\'));
  n := jsonUnescapeOneChar('\q', 2, v);
  CheckEqI('T219 \q invalid', v, JSON_INVALID_CHAR);
  { surrogate-pair 😀 → U+1F600 (😀) }
  n := jsonUnescapeOneChar(PAnsiChar(#92'uD83D'#92'uDE00'), 12, v);
  CheckEqI('T220 surr n', n, 12);
  CheckEqI('T221 surr c', v, $1F600);
end;

procedure TestLabelCompare;
begin
  CheckEqI('T222 raw equal', jsonLabelCompare('foo', 3, 1, 'foo', 3, 1), 1);
  CheckEqI('T223 raw diff',  jsonLabelCompare('foo', 3, 1, 'bar', 3, 1), 0);
  CheckEqI('T224 len diff',  jsonLabelCompare('foo', 3, 1, 'foob', 4, 1), 0);
  { Escape on left: "A" matches "A" }
  CheckEqI('T225 esc=raw',
           jsonLabelCompare('A', 6, 0, 'A', 1, 1), 1);
  { Both escaped, same content }
  CheckEqI('T226 esc=esc',
           jsonLabelCompare('A', 6, 0, 'A', 6, 0), 1);
end;

procedure TestTranslateLiterals;
var p: TJsonParse; rc: i32;
begin
  InitParseFromText(p, 'true');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T227 true rc', rc, 4);
  CheckEqI('T228 true nBlob', p.nBlob, 1);
  CheckTrue('T229 true byte', p.aBlob[0] = JSONB_TRUE);
  FreeParse(p);

  InitParseFromText(p, 'false');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T230 false rc', rc, 5);
  CheckTrue('T231 false byte', p.aBlob[0] = JSONB_FALSE);
  FreeParse(p);

  InitParseFromText(p, 'null');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T232 null rc', rc, 4);
  CheckTrue('T233 null byte', p.aBlob[0] = JSONB_NULL);
  FreeParse(p);
end;

procedure TestTranslateNumber;
var p: TJsonParse; rc: i32; sz, n: u32;
begin
  InitParseFromText(p, '123');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T234 123 rc', rc, 3);
  n := jsonbPayloadSize(@p, 0, sz);
  CheckEqI('T235 123 type', p.aBlob[0] and $0F, JSONB_INT);
  CheckEqI('T236 123 sz',   sz, 3);
  CheckTrue('T237 123 b1',  p.aBlob[1] = Ord('1'));
  FreeParse(p);

  InitParseFromText(p, '-7');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T238 -7 rc', rc, 2);
  CheckEqI('T239 -7 type', p.aBlob[0] and $0F, JSONB_INT);
  CheckTrue('T240 -7 b1', p.aBlob[1] = Ord('-'));
  CheckTrue('T241 -7 b2', p.aBlob[2] = Ord('7'));
  FreeParse(p);

  InitParseFromText(p, '3.14');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T242 3.14 rc',   rc, 4);
  CheckEqI('T243 3.14 type', p.aBlob[0] and $0F, JSONB_FLOAT);
  FreeParse(p);

  InitParseFromText(p, '1e10');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T244 1e10 rc',   rc, 4);
  CheckEqI('T245 1e10 type', p.aBlob[0] and $0F, JSONB_FLOAT);
  FreeParse(p);
end;

procedure TestTranslateString;
var p: TJsonParse; rc: i32; sz: u32;
begin
  InitParseFromText(p, '"abc"');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T246 "abc" rc', rc, 5);
  CheckEqI('T247 type', p.aBlob[0] and $0F, JSONB_TEXT);
  jsonbPayloadSize(@p, 0, sz);
  CheckEqI('T248 sz', sz, 3);
  CheckTrue('T249 b1', p.aBlob[1] = Ord('a'));
  FreeParse(p);

  { string with \n escape → JSONB_TEXTJ }
  InitParseFromText(p, '"a\n"');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T250 \n rc', rc, 5);
  CheckEqI('T251 \n type', p.aBlob[0] and $0F, JSONB_TEXTJ);
  FreeParse(p);

  { JSON5 single-quoted string }
  InitParseFromText(p, '''hi''');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T252 sq rc', rc, 4);
  CheckEqI('T253 sq type', p.aBlob[0] and $0F, JSONB_TEXT);
  CheckEqI('T254 sq nonstd', p.hasNonstd, 1);
  FreeParse(p);
end;

procedure TestTranslateArrayObject;
var p: TJsonParse; rc: i32; cnt: u32;
begin
  InitParseFromText(p, '[1,2,3]');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T255 arr rc', rc, 7);
  CheckEqI('T256 arr type', p.aBlob[0] and $0F, JSONB_ARRAY);
  cnt := jsonbArrayCount(@p, 0);
  CheckEqI('T257 arr count', cnt, 3);
  FreeParse(p);

  InitParseFromText(p, '{"a":1,"b":2}');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T258 obj rc', rc, 13);
  CheckEqI('T259 obj type', p.aBlob[0] and $0F, JSONB_OBJECT);
  FreeParse(p);

  InitParseFromText(p, '[]');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T260 [] rc', rc, 2);
  CheckEqI('T261 [] type', p.aBlob[0] and $0F, JSONB_ARRAY);
  FreeParse(p);
end;

procedure TestTranslateNested;
var p: TJsonParse; rc: i32;
begin
  InitParseFromText(p, '[[1],{"k":[2,3]}]');
  rc := jsonTranslateTextToBlob(@p, 0);
  CheckEqI('T262 nested rc', rc, 17);
  CheckEqI('T263 nested type', p.aBlob[0] and $0F, JSONB_ARRAY);
  FreeParse(p);
end;

procedure TestConvertTextToBlob;
var p: TJsonParse; rc: i32;
begin
  { trailing whitespace OK }
  InitParseFromText(p, '  42  ');
  rc := jsonConvertTextToBlob(@p, nil);
  CheckEqI('T264 conv ok', rc, 0);
  CheckEqI('T265 conv type', p.aBlob[0] and $0F, JSONB_INT);
  FreeParse(p);

  { trailing garbage → error }
  InitParseFromText(p, '42 garbage');
  rc := jsonConvertTextToBlob(@p, nil);
  CheckEqI('T266 conv err', rc, 1);

  { malformed }
  InitParseFromText(p, '{');
  rc := jsonConvertTextToBlob(@p, nil);
  CheckEqI('T267 conv malformed', rc, 1);
end;

procedure TestValidityCheck;
var p: TJsonParse;
begin
  { Build [1,2,3] in JSONB then validate. }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_ARRAY, 6, nil);
  jsonBlobAppendNode(@p, JSONB_INT, 1, PAnsiChar('1'));
  jsonBlobAppendNode(@p, JSONB_INT, 1, PAnsiChar('2'));
  jsonBlobAppendNode(@p, JSONB_INT, 1, PAnsiChar('3'));
  CheckEqI('T268 valid array',
           jsonbValidityCheck(@p, 0, p.nBlob, 0), 0);
  FreeParse(p);

  { JSONB_TRUE has size 0; valid only if n+sz=1 i.e. single byte. }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_TRUE, 0, nil);
  CheckEqI('T269 valid true',
           jsonbValidityCheck(@p, 0, p.nBlob, 0), 0);
  FreeParse(p);

  { Validate INT body: single digit. }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_INT, 1, PAnsiChar('7'));
  CheckEqI('T270 valid int',
           jsonbValidityCheck(@p, 0, p.nBlob, 0), 0);
  FreeParse(p);

  { Bad INT: contains a non-digit. }
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_INT, 2, PAnsiChar('1x'));
  CheckTrue('T271 invalid int',
           jsonbValidityCheck(@p, 0, p.nBlob, 0) <> 0);
  FreeParse(p);
end;

procedure TestIs4HexB;
var op: i32;
begin
  op := JSONB_TEXT;
  CheckEqI('T272 4hexB ok',  jsonIs4HexB('u00ab', op), 1);
  CheckEqI('T273 4hexB op',  op, JSONB_TEXTJ);
  op := JSONB_TEXT;
  CheckEqI('T274 4hexB no-u', jsonIs4HexB('x00ab', op), 0);
  CheckEqI('T275 4hexB op-unchanged', op, JSONB_TEXT);
end;

{ ----- Phase 6.8.e blob→text tests ----- }

function StringFromAccum(var s: TJsonString): AnsiString;
begin
  if s.eErr <> 0 then begin Result := ''; Exit; end;
  if s.nUsed = 0 then begin Result := ''; Exit; end;
  SetLength(Result, s.nUsed);
  Move(s.zBuf^, Result[1], s.nUsed);
end;

{ Compile JSON text → JSONB → re-render to text and compare. }
function RoundTripText(const src: AnsiString): AnsiString;
var
  p  : TJsonParse;
  s  : TJsonString;
  rc : i32;
begin
  InitParseFromText(p, src);
  rc := jsonConvertTextToBlob(@p, nil);
  if rc <> 0 then begin FreeParse(p); Result := '<ERR>'; Exit; end;
  jsonStringInit(@s, nil);
  jsonTranslateBlobToText(@p, 0, @s);
  Result := StringFromAccum(s);
  jsonStringReset(@s);
  FreeParse(p);
end;

procedure TestBlobToText_Literals;
begin
  CheckEqS('T276 b2t null',  RoundTripText('null'),  'null');
  CheckEqS('T277 b2t true',  RoundTripText('true'),  'true');
  CheckEqS('T278 b2t false', RoundTripText('false'), 'false');
end;

procedure TestBlobToText_Numbers;
begin
  CheckEqS('T279 b2t int',    RoundTripText('42'),    '42');
  CheckEqS('T280 b2t neg',    RoundTripText('-7'),    '-7');
  CheckEqS('T281 b2t float',  RoundTripText('3.14'),  '3.14');
  { JSON5 hex int → decimal repr }
  CheckEqS('T282 b2t hex',    RoundTripText('0x1A'),  '26');
  { JSON5 leading-dot float → "0." prefix }
  CheckEqS('T283 b2t .5',     RoundTripText('.5'),    '0.5');
  CheckEqS('T284 b2t 5.',     RoundTripText('5.'),    '5.0');
end;

procedure TestBlobToText_Strings;
begin
  CheckEqS('T285 b2t plain',  RoundTripText('"abc"'), '"abc"');
  { JSON5 single-quote re-rendered as double-quoted JSON }
  CheckEqS('T286 b2t sq',     RoundTripText('''ab'''), '"ab"');
end;

procedure TestBlobToText_ArrayObject;
begin
  CheckEqS('T287 b2t arr',    RoundTripText('[1,2,3]'),         '[1,2,3]');
  CheckEqS('T288 b2t empty arr', RoundTripText('[]'),           '[]');
  CheckEqS('T289 b2t obj',    RoundTripText('{"a":1,"b":2}'),   '{"a":1,"b":2}');
  CheckEqS('T290 b2t empty obj', RoundTripText('{}'),           '{}');
  CheckEqS('T291 b2t nested',
           RoundTripText('[[1],{"k":[2,3]}]'),
           '[[1],{"k":[2,3]}]');
end;

procedure TestBlobToText_MalformedReturn;
var
  p  : TJsonParse;
  s  : TJsonString;
  rc : u32;
begin
  { Malformed: header byte with type 0x0F (invalid) — payloadSize parses
    but the case-arm hits malformed_jsonb. }
  InitParse(p);
  jsonBlobAppendOneByte(@p, $0F);
  jsonStringInit(@s, nil);
  rc := jsonTranslateBlobToText(@p, 0, @s);
  CheckTrue('T292 b2t malformed eErr',
            (s.eErr and JSTRING_MALFORMED) <> 0);
  CheckTrue('T293 b2t malformed rc',  rc >= 0);
  jsonStringReset(@s);
  FreeParse(p);
end;

procedure TestPrettyArray;
var
  p   : TJsonParse;
  s   : TJsonString;
  pp  : TJsonPretty;
  src : AnsiString;
  got : AnsiString;
begin
  src := '[1,2,3]';
  InitParseFromText(p, src);
  CheckEqI('T294 pretty parse', jsonConvertTextToBlob(@p, nil), 0);
  jsonStringInit(@s, nil);
  FillChar(pp, SizeOf(pp), 0);
  pp.pParse := @p;
  pp.pOut := @s;
  pp.zIndent := PAnsiChar('  ');
  pp.szIndent := 2;
  pp.nIndent := 0;
  jsonTranslateBlobToPrettyText(@pp, 0);
  got := StringFromAccum(s);
  CheckEqS('T295 pretty arr', got,
           '[' + #10 + '  1,' + #10 + '  2,' + #10 + '  3' + #10 + ']');
  jsonStringReset(@s);
  FreeParse(p);
end;

procedure TestPrettyObject;
var
  p   : TJsonParse;
  s   : TJsonString;
  pp  : TJsonPretty;
  got : AnsiString;
begin
  InitParseFromText(p, '{"a":1,"b":2}');
  CheckEqI('T296 pretty obj parse', jsonConvertTextToBlob(@p, nil), 0);
  jsonStringInit(@s, nil);
  FillChar(pp, SizeOf(pp), 0);
  pp.pParse := @p;
  pp.pOut := @s;
  pp.zIndent := PAnsiChar('  ');
  pp.szIndent := 2;
  pp.nIndent := 0;
  jsonTranslateBlobToPrettyText(@pp, 0);
  got := StringFromAccum(s);
  CheckEqS('T297 pretty obj', got,
           '{' + #10 + '  "a": 1,' + #10 + '  "b": 2' + #10 + '}');
  jsonStringReset(@s);
  FreeParse(p);
end;

procedure TestPrettyEmpty;
var
  p   : TJsonParse;
  s   : TJsonString;
  pp  : TJsonPretty;
  got : AnsiString;
begin
  InitParseFromText(p, '[]');
  CheckEqI('T298 pretty [] parse', jsonConvertTextToBlob(@p, nil), 0);
  jsonStringInit(@s, nil);
  FillChar(pp, SizeOf(pp), 0);
  pp.pParse := @p; pp.pOut := @s;
  pp.zIndent := PAnsiChar('  '); pp.szIndent := 2;
  jsonTranslateBlobToPrettyText(@pp, 0);
  got := StringFromAccum(s);
  CheckEqS('T299 pretty []', got, '[]');
  jsonStringReset(@s);
  FreeParse(p);

  InitParseFromText(p, '{}');
  CheckEqI('T300 pretty {} parse', jsonConvertTextToBlob(@p, nil), 0);
  jsonStringInit(@s, nil);
  FillChar(pp, SizeOf(pp), 0);
  pp.pParse := @p; pp.pOut := @s;
  pp.zIndent := PAnsiChar('  '); pp.szIndent := 2;
  jsonTranslateBlobToPrettyText(@pp, 0);
  got := StringFromAccum(s);
  CheckEqS('T301 pretty {}', got, '{}');
  jsonStringReset(@s);
  FreeParse(p);
end;

{ ----- Phase 6.8.f path lookup + edit tests ----- }

{ Build JSONB for {"a":1,"b":2}: OBJECT(sz=10) + TEXTRAW("a") + INT(1) +
  TEXTRAW("b") + INT(2).  Each label/int = 2 bytes (1B hdr + 1B payload),
  so payload size is 8.  Wait — sizing: textraw "a" is hdr(JSONB_TEXTRAW,
  sz=1) → small-form 1-byte hdr (since sz<=11) + 1 payload = 2 bytes.
  Ditto INT(1).  So 4 entries * 2 = 8.  Object hdr is 1 byte for sz=8. }
procedure BuildSimpleObject(out p: TJsonParse);
begin
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_OBJECT,  8, nil);
  jsonBlobAppendNode(@p, JSONB_TEXTRAW, 1, PAnsiChar('a'));
  jsonBlobAppendNode(@p, JSONB_INT,     1, PAnsiChar('1'));
  jsonBlobAppendNode(@p, JSONB_TEXTRAW, 1, PAnsiChar('b'));
  jsonBlobAppendNode(@p, JSONB_INT,     1, PAnsiChar('2'));
end;

{ Build JSONB for [10,20,30]. }
procedure BuildSimpleArray(out p: TJsonParse);
begin
  InitParse(p);
  jsonBlobAppendNode(@p, JSONB_ARRAY, 9,  nil);
  jsonBlobAppendNode(@p, JSONB_INT,   2, PAnsiChar('10'));
  jsonBlobAppendNode(@p, JSONB_INT,   2, PAnsiChar('20'));
  jsonBlobAppendNode(@p, JSONB_INT,   2, PAnsiChar('30'));
end;

procedure TestLookupPath;
var
  p  : TJsonParse;
  rc : u32;
begin
  { Object key '.a' lookup → returns index of value (3rd byte: hdr1=at 1
    "a"label hdr; payload at 2; next is value INT hdr at 3). }
  BuildSimpleObject(p);
  rc := jsonLookupStep(@p, 0, '.a', 0);
  CheckEqI('T302 obj .a found', i64(rc), 3);
  CheckTrue('T303 obj .a is INT', (p.aBlob[rc] and $0F) = JSONB_INT);
  FreeParse(p);

  { Object key '.b' lookup. }
  BuildSimpleObject(p);
  rc := jsonLookupStep(@p, 0, '.b', 0);
  CheckEqI('T304 obj .b found', i64(rc), 7);
  FreeParse(p);

  { Object miss. }
  BuildSimpleObject(p);
  rc := jsonLookupStep(@p, 0, '.zzz', 0);
  CheckEqI('T305 obj miss = NOTFOUND', i64(rc), i64(JSON_LOOKUP_NOTFOUND));
  FreeParse(p);

  { Object: empty path returns iRoot. }
  BuildSimpleObject(p);
  rc := jsonLookupStep(@p, 0, '', 0);
  CheckEqI('T306 empty path returns iRoot', i64(rc), 0);
  FreeParse(p);

  { Object key '.' alone is a path error. }
  BuildSimpleObject(p);
  rc := jsonLookupStep(@p, 0, '.', 0);
  CheckEqI('T307 lone . is PATHERROR',
           i64(rc), i64(JSON_LOOKUP_PATHERROR));
  FreeParse(p);

  { Object key '."a"' (quoted form). }
  BuildSimpleObject(p);
  rc := jsonLookupStep(@p, 0, '."a"', 0);
  CheckEqI('T308 obj quoted .a found', i64(rc), 3);
  FreeParse(p);

  { Array index '[1]' on [10,20,30] → second element. }
  BuildSimpleArray(p);
  rc := jsonLookupStep(@p, 0, '[1]', 0);
  CheckTrue('T309 arr [1] found',
            (rc <> JSON_LOOKUP_NOTFOUND) and (rc < $FFFFFFF0));
  CheckTrue('T310 arr [1] type=INT', (p.aBlob[rc] and $0F) = JSONB_INT);
  CheckTrue('T311 arr [1] payload=2',
            (p.aBlob[rc + 1] = Ord('2')) and (p.aBlob[rc + 2] = Ord('0')));
  FreeParse(p);

  { Array index '[0]'. }
  BuildSimpleArray(p);
  rc := jsonLookupStep(@p, 0, '[0]', 0);
  CheckTrue('T312 arr [0] found', rc < $FFFFFFF0);
  CheckTrue('T313 arr [0] payload=1',
            (p.aBlob[rc + 1] = Ord('1')) and (p.aBlob[rc + 2] = Ord('0')));
  FreeParse(p);

  { Array index out of range. }
  BuildSimpleArray(p);
  rc := jsonLookupStep(@p, 0, '[99]', 0);
  CheckEqI('T314 arr [99] NOTFOUND',
           i64(rc), i64(JSON_LOOKUP_NOTFOUND));
  FreeParse(p);

  { Array '[#-1]' = last element of N-element array. }
  BuildSimpleArray(p);
  rc := jsonLookupStep(@p, 0, '[#-1]', 0);
  CheckTrue('T315 arr [#-1] found', rc < $FFFFFFF0);
  CheckTrue('T316 arr [#-1] is 30',
            (p.aBlob[rc + 1] = Ord('3')) and (p.aBlob[rc + 2] = Ord('0')));
  FreeParse(p);

  { Array path on object → NOTFOUND. }
  BuildSimpleObject(p);
  rc := jsonLookupStep(@p, 0, '[0]', 0);
  CheckEqI('T317 [0] on object NOTFOUND',
           i64(rc), i64(JSON_LOOKUP_NOTFOUND));
  FreeParse(p);

  { Object path on array → NOTFOUND. }
  BuildSimpleArray(p);
  rc := jsonLookupStep(@p, 0, '.x', 0);
  CheckEqI('T318 .x on array NOTFOUND',
           i64(rc), i64(JSON_LOOKUP_NOTFOUND));
  FreeParse(p);

  { Bare path (no $ stripped here) → PATHERROR. }
  BuildSimpleObject(p);
  rc := jsonLookupStep(@p, 0, 'a', 0);
  CheckEqI('T319 bare label PATHERROR',
           i64(rc), i64(JSON_LOOKUP_PATHERROR));
  FreeParse(p);
end;

procedure TestLookupEdit;
var
  p  : TJsonParse;
  rc : u32;
  insBuf : array[0..1] of u8 = (JSONB_INT or (1 shl 4), Ord('9'));
begin
  { JEDIT_DEL on object key '.a': should remove "a":1 leaving {"b":2}.
    The remaining payload size is 4 bytes (label+value for "b").  After
    the edit, root header sz field updates to 4. }
  BuildSimpleObject(p);
  { Force aBlob ownership so jsonBlobMakeEditable is a no-op accept. }
  jsonBlobMakeEditable(@p, 8);  { 8 = pParse^.nIns guard, ignored on owned blob }
  p.eEdit := JEDIT_DEL;
  rc := jsonLookupStep(@p, 0, '.a', 0);
  CheckTrue('T320 del .a no error', rc < $FFFFFFF0);
  CheckEqI('T321 del .a delta=-4', p.delta, -4);
  CheckEqI('T322 del .a new nBlob', p.nBlob, 5);
  { Root header now reports payload sz = 4 ("b"+2). }
  CheckTrue('T323 del .a hdr is OBJECT',
            (p.aBlob[0] and $0F) = JSONB_OBJECT);
  CheckEqI('T324 del .a hdr sz nibble=4',
            (p.aBlob[0] shr 4), 4);
  FreeParse(p);

  { JEDIT_REPL on '.b' replacing INT(2) with INT(9). }
  BuildSimpleObject(p);
  jsonBlobMakeEditable(@p, 4);
  p.eEdit := JEDIT_REPL;
  p.aIns := @insBuf[0];
  p.nIns := 2;
  rc := jsonLookupStep(@p, 0, '.b', 0);
  CheckTrue('T325 repl .b no error', rc < $FFFFFFF0);
  { Old "b" value INT(2) was 2 bytes; new INT(9) is 2 bytes; same size. }
  CheckEqI('T326 repl .b delta=0', p.delta, 0);
  CheckTrue('T327 repl .b new payload',
            p.aBlob[p.nBlob - 1] = Ord('9'));
  FreeParse(p);

  { JEDIT_DEL miss → returns NOTFOUND, blob untouched. }
  BuildSimpleObject(p);
  jsonBlobMakeEditable(@p, 0);
  p.eEdit := JEDIT_DEL;
  rc := jsonLookupStep(@p, 0, '.zzz', 0);
  CheckEqI('T328 del miss NOTFOUND',
           i64(rc), i64(JSON_LOOKUP_NOTFOUND));
  CheckEqI('T329 del miss delta=0', p.delta, 0);
  FreeParse(p);
end;

procedure TestCreateEditSubstructure;
var
  p, ins : TJsonParse;
  rc     : u32;
  insBuf : array[0..1] of u8 = (JSONB_INT or (1 shl 4), Ord('5'));
begin
  { Empty tail: pIns just mirrors pParse->aIns. }
  InitParse(p);
  p.aIns := @insBuf[0];
  p.nIns := 2;
  rc := jsonCreateEditSubstructure(@p, @ins, '');
  CheckEqI('T330 cesub empty rc=0', i64(rc), 0);
  CheckTrue('T331 cesub empty aBlob=aIns', ins.aBlob = p.aIns);
  CheckEqI('T332 cesub empty nBlob=2', ins.nBlob, 2);
  FreeParse(p);
end;

{ ----- Phase 6.8.g — JSON cache + jsonParseFuncArg ----- }

procedure SetupTextValue(var v: TMem; z: PAnsiChar; n: i32);
begin
  FillChar(v, SizeOf(v), 0);
  v.z     := z;
  v.n     := n;
  v.enc   := SQLITE_UTF8;
  v.flags := MEM_Str or MEM_Term;
end;

procedure SetupBlobValue(var v: TMem; p: Pointer; n: i32);
begin
  FillChar(v, SizeOf(v), 0);
  v.z     := PAnsiChar(p);
  v.n     := n;
  v.enc   := SQLITE_UTF8;
  v.flags := MEM_Blob;
end;

procedure SetupCtx(var ctx: Tsqlite3_context; var vm: TVdbe; var pOut: TMem);
begin
  FillChar(ctx,  SizeOf(ctx),  0);
  FillChar(vm,   SizeOf(vm),   0);
  FillChar(pOut, SizeOf(pOut), 0);
  ctx.pOut  := @pOut;
  ctx.pVdbe := @vm;
  ctx.iOp   := 0;
  { vm.db = nil; sqlite3DbFree degrades to sqlite3_free → safe. }
end;

procedure TestJsonParseFreeRefcount;
var
  p: PJsonParse;
begin
  p := PJsonParse(sqlite3_malloc(SizeOf(TJsonParse)));
  FillChar(p^, SizeOf(TJsonParse), 0);
  p^.nJPRef := 2;
  jsonParseFree(p);
  CheckEqI('T333 jsonParseFree dec refcount',
           i64(p^.nJPRef), 1);
  jsonParseFree(p);
  CheckTrue('T334 jsonParseFree last ref freed (no crash)', True);
end;

procedure TestJsonArgIsJsonbBlob;
var
  p: TJsonParse;
  v: TMem;
  blob: array[0..1] of Byte;
begin
  { Header byte = (payload size 1 << 4) | JSONB_INT, payload is ASCII '5'. }
  blob[0] := (1 shl 4) or JSONB_INT;
  blob[1] := Ord('5');
  FillChar(p, SizeOf(p), 0);
  SetupBlobValue(v, @blob[0], 2);
  CheckEqI('T335 jsonArgIsJsonb int recognised',
           jsonArgIsJsonb(@v, @p), 1);
  CheckEqI('T336 nBlob = 2',  i64(p.nBlob), 2);
  CheckTrue('T337 aBlob points at supplied buffer', p.aBlob = @blob[0]);

  { Garbage header: nibble 0x0F > JSONB_OBJECT → reject. }
  blob[0] := $FF;
  FillChar(p, SizeOf(p), 0);
  CheckEqI('T338 jsonArgIsJsonb invalid nibble rejected',
           jsonArgIsJsonb(@v, @p), 0);
  CheckEqI('T339 nBlob cleared after reject',
           i64(p.nBlob), 0);
  CheckTrue('T340 aBlob nil after reject', p.aBlob = nil);

  { Non-blob input → 0 immediately. }
  v.flags := MEM_Str or MEM_Term;
  FillChar(p, SizeOf(p), 0);
  CheckEqI('T341 jsonArgIsJsonb non-blob → 0',
           jsonArgIsJsonb(@v, @p), 0);
end;

procedure TestJsonCacheSearchEmpty;
var
  ctx:  Tsqlite3_context;
  vm:   TVdbe;
  pOut: TMem;
  v:    TMem;
  zJ:   AnsiString;
begin
  SetupCtx(ctx, vm, pOut);
  zJ := '{"a":1}';
  SetupTextValue(v, PAnsiChar(zJ), Length(zJ));
  CheckTrue('T342 cacheSearch empty cache → nil',
            jsonCacheSearch(@ctx, @v) = nil);
  CheckTrue('T343 cacheSearch leaves auxdata untouched',
            sqlite3_get_auxdata(@ctx, JSON_CACHE_ID) = nil);
end;

procedure TestJsonParseFuncArgRoundtrip;
var
  ctx:    Tsqlite3_context;
  vm:     TVdbe;
  pOut:   TMem;
  v, v2:  TMem;
  zJ, z2: AnsiString;
  p, q:   PJsonParse;
  pCache: PJsonCache;
begin
  SetupCtx(ctx, vm, pOut);
  zJ := '{"x":42}';
  SetupTextValue(v, PAnsiChar(zJ), Length(zJ));
  p := jsonParseFuncArg(@ctx, @v, 0);
  CheckTrue('T344 jsonParseFuncArg returns non-nil', p <> nil);
  if p = nil then Exit;
  CheckTrue('T345 zJson copied into RCStr-marked buffer',
            (p^.bJsonIsRCStr = 1) and (p^.zJson <> nil));
  CheckEqI('T346 nJson preserved', i64(p^.nJson), Length(zJ));
  CheckTrue('T347 nBlob populated by ConvertTextToBlob', p^.nBlob > 0);
  pCache := PJsonCache(sqlite3_get_auxdata(@ctx, JSON_CACHE_ID));
  CheckTrue('T348 cache attached to ctx as auxdata', pCache <> nil);
  if pCache <> nil then
    CheckEqI('T349 cache nUsed = 1', pCache^.nUsed, 1);

  { Re-parse same text via a different value: should hit the cache and
    return the same JsonParse instance with refcount bumped. }
  z2 := zJ;  { distinct AnsiString → distinct buffer pointer }
  UniqueString(z2);
  SetupTextValue(v2, PAnsiChar(z2), Length(z2));
  q := jsonParseFuncArg(@ctx, @v2, 0);
  CheckTrue('T350 second parse → same cached object',
            (q <> nil) and (q = p));
  { Refcount accounting: 1 from initial parse, +1 from jsonCacheInsert
    (cache itself), +1 from cache-hit Inc → 3 total outstanding. }
  CheckEqI('T351 refcount bumped on cache hit',
           i64(p^.nJPRef), 3);

  { Drop the two outstanding references: the cache itself still owns one. }
  jsonParseFree(p);
  jsonParseFree(q);
  CheckEqI('T352 cache-owned refcount = 1',
           i64(pCache^.a[0]^.nJPRef), 1);

  { Tear down: free auxdata via the registered destructor. }
  sqlite3_set_auxdata(@ctx, JSON_CACHE_ID, nil, nil);
  CheckTrue('T353 auxdata cleared', sqlite3_get_auxdata(@ctx, JSON_CACHE_ID) = nil);
end;

procedure TestJsonParseFuncArgNullSqlNull;
var
  ctx:  Tsqlite3_context;
  vm:   TVdbe;
  pOut: TMem;
  v:    TMem;
begin
  SetupCtx(ctx, vm, pOut);
  FillChar(v, SizeOf(v), 0);
  v.flags := MEM_Null;
  CheckTrue('T354 jsonParseFuncArg(NULL) → nil',
            jsonParseFuncArg(@ctx, @v, 0) = nil);
end;

begin
  WriteLn('=== TestJson — Phase 6.8.a/b/c/d/e/f/g JSON port ===');
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
  TestBlobExpand;
  TestBlobMakeEditable;
  TestBlobAppendOneByte;
  TestBlobAppendNode;
  TestPayloadSize;
  TestChangePayloadSize;
  TestArrayCount;
  TestBlobEdit;
  TestAfterEditSizeAdjust;
  TestBytesToBypass;
  TestUnescapeOneChar;
  TestLabelCompare;
  TestTranslateLiterals;
  TestTranslateNumber;
  TestTranslateString;
  TestTranslateArrayObject;
  TestTranslateNested;
  TestConvertTextToBlob;
  TestValidityCheck;
  TestIs4HexB;
  TestBlobToText_Literals;
  TestBlobToText_Numbers;
  TestBlobToText_Strings;
  TestBlobToText_ArrayObject;
  TestBlobToText_MalformedReturn;
  TestPrettyArray;
  TestPrettyObject;
  TestPrettyEmpty;
  TestLookupPath;
  TestLookupEdit;
  TestCreateEditSubstructure;
  TestJsonParseFreeRefcount;
  TestJsonArgIsJsonbBlob;
  TestJsonCacheSearchEmpty;
  TestJsonParseFuncArgRoundtrip;
  TestJsonParseFuncArgNullSqlNull;
  WriteLn;
  WriteLn('=== Total: ', gPass, ' pass, ', gFail, ' fail ===');
  if gFail > 0 then Halt(1);
end.
