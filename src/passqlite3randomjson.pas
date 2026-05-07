{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/randomjson.c (240 lines in C).

  Implements two SQL functions:

    random_json(SEED)    -> deterministic pseudo-random JSON document
    random_json5(SEED)   -> deterministic pseudo-random JSON5 document

  Both are SQLITE_DETERMINISTIC + SQLITE_INNOCUOUS: the same seed
  always yields the same output, intended for use in tests / fuzzers.

  Public entry: sqlite3RandomJsonInit(db) — equivalent to
  sqlite3_randomjson_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3randomjson;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3RandomJsonInit(db: PTsqlite3): i32;

implementation

uses SysUtils;

const
  STRSZ = 10000;

type
  TPrng = record
    x, y: u32;
  end;

{ randomjson.c:46..50 — seed the PRNG from a single u32 seed. }
procedure prngSeed(var p: TPrng; iSeed: u32); inline;
begin
  p.x := iSeed or 1;
  p.y := iSeed;
end;

{ randomjson.c:52..57 — extract one u32 from the LFSR/LCG combination. }
function prngInt(var p: TPrng): u32; inline;
var mask: u32;
begin
  { C: p->x = (p->x>>1) ^ ((1+~(p->x&1)) & 0xd0000001).
    The (1+~(x&1)) trick yields 0xFFFFFFFF when (x&1)=1 and 0 when 0,
    masking 0xd0000001 in or out.  We expand the branch explicitly so
    FPC's overflow / range checks never see the deliberate u32 wrap. }
  if (p.x and 1) <> 0 then mask := $d0000001 else mask := 0;
  p.x := (p.x shr 1) xor mask;
  p.y := p.y * 1103515245 + 12345;
  Result := p.x xor p.y;
end;

{ The C source uses a single static char* azJsonAtoms[] array that
  alternates between JSON and JSON5 literal pairs (eType selects which
  half of each pair).  We keep the same layout: index k*2 is JSON,
  index k*2+1 is JSON5. }
const
  azJsonAtoms: array[0..83] of PAnsiChar = (
    '0',                       '0',
    '1',                       '1',
    '-1',                      '-1',
    '2',                       '+2',
    '3DDDD',                   '3DDDD',
    '2.5DD',                   '2.5DD',
    '0.75',                    '.75',
    '-4.0e2',                  '-4.e2',
    '5.0e-3',                  '+5e-3',
    '6.DDe+0DD',               '6.DDe+0DD',
    '0',                       '0x0',
    '512',                     '0x200',
    '256',                     '+0x100',
    '-2748',                   '-0xabc',
    'true',                    'true',
    'false',                   'false',
    'null',                    'null',
    '9.0e999',                 'Infinity',
    '-9.0e999',                '-Infinity',
    '9.0e999',                 '+Infinity',
    'null',                    'NaN',
    '-0.0005DD',               '-0.0005DD',
    '4.35e-3',                 '+4.35e-3',
    '"gem\"hay"',              '"gem\"hay"',
    '"icy''joy"',              '''icy\''joy''',
    '"keylog"',                '"key\'#10'log"',
    '"mix\\\tnet"',            '"mix\\\tnet"',
    '"oat\r\n"',               '"oat\r\n"',
    '"\fpan\b"',               '"\fpan\b"',
    '{}',                      '{}',
    '[]',                      '[]',
    '[]',                      '[/*empty*/]',
    '{}',                      '{//empty'#10'}',
    '"ask"',                   '"ask"',
    '"bag"',                   '"bag"',
    '"can"',                   '"can"',
    '"day"',                   '"day"',
    '"end"',                   '''end''',
    '"fly"',                   '"fly"',
    '"\u00XX\u00XX"',          '"\xXX\xXX"',
    '"y\uXXXXz"',              '"y\uXXXXz"',
    '""',                      '""'
  );

  azJsonTemplate: array[0..27] of PAnsiChar = (
    '{"a":%,"b":%,"cDD":%}',                  '{a:%,b:%,cDD:%}',
    '{"a":%,"b":%,"c":%,"d":%,"e":%}',        '{a:%,b:%,c:%,d:%,e:%}',
    '{"a":%,"b":%,"c":%,"d":%,"":%}',         '{a:%,b:%,c:%,d:%,'''':%}',
    '{"d":%}',                                '{d:%}',
    '{"eeee":%, "ffff":%}',                   '{eeee:% /*and*/, ffff:%}',
    '{"$g":%,"_h_":%,"a b c d":%}',           '{$g:%,_h_:%,"a b c d":%}',
    '{"x":%,'#10'  "y":%}',                   '{"x":%,'#10'  "y":%}',
    '{"\u00XX":%,"\uXXXX":%}',                '{"\xXX":%,"\uXXXX":%}',
    '{"Z":%}',                                '{Z:%,}',
    '[%]',                                    '[%,]',
    '[%,%]',                                  '[%,%]',
    '[%,%,%]',                                '[%,%,%,]',
    '[%,%,%,%]',                              '[%,%,%,%]',
    '[%,%,%,%,%]',                            '[%,%,%,%,%]'
  );

const
  HEXDIGITS: array[0..15] of AnsiChar = '0123456789abcdef';
  DECDIGITS: array[0..9]  of AnsiChar = '0123456789';

{ Helper: locate the first occurrence of a 2-char tag ('XX' or 'DD')
  inside a NUL-terminated buffer, starting at offset `from`.  Returns
  -1 if not present.  Equivalent to strstr() with a 2-byte needle. }
function find2(z: PAnsiChar; tag0, tag1: AnsiChar; from: PtrInt): PtrInt;
var i: PtrInt;
begin
  i := from;
  while z[i] <> #0 do
  begin
    if (z[i] = tag0) and (z[i + 1] = tag1) then
    begin
      Result := i;
      Exit;
    end;
    Inc(i);
  end;
  Result := -1;
end;

{ randomjson.c:126..193 — jsonExpand.  Walks zSrc and, for each '%'
  encountered, splices in a random atom (when r=0 or coin-flip says
  so) or a random template (which itself contains more '%' that the
  next pass will fill in).  Templates may carry "XX" / "DD" placeholders
  that get rewritten to random hex / decimal digits in-place. }
procedure jsonExpand(zSrc, zDest: PAnsiChar; var p: TPrng;
                     eType: i32; r: u32);
var
  i, j: PtrInt;
  k: u32;
  z: PAnsiChar;
  zBuf: array[0..199] of AnsiChar;
  n: PtrInt;
  zXi: PtrInt;
  y: u32;
  ch: AnsiChar;
  cnt: u32;
begin
  j := 0;
  if zSrc = nil then zSrc := '%';
  if StrLen(zSrc) >= STRSZ div 10 then r := 0;
  i := 0;
  while zSrc[i] <> #0 do
  begin
    ch := zSrc[i];
    if ch <> '%' then
    begin
      if j < STRSZ then
      begin
        zDest[j] := ch;
        Inc(j);
      end;
      Inc(i);
      Continue;
    end;
    Inc(i);
    cnt := u32(Length(azJsonAtoms)) div 2;
    if (r = 0) or ((r < 1000) and ((prngInt(p) mod 1000) <= r)) then
    begin
      k := prngInt(p) mod cnt;
      k := k * 2 + u32(eType);
      z := azJsonAtoms[k];
    end
    else
    begin
      cnt := u32(Length(azJsonTemplate)) div 2;
      k := prngInt(p) mod cnt;
      k := k * 2 + u32(eType);
      z := azJsonTemplate[k];
    end;
    n := PtrInt(StrLen(z));
    zXi := find2(z, 'X', 'X', 0);
    if zXi >= 0 then
    begin
      y := prngInt(p);
      if (y and $ff) = ((y shr 8) and $ff) then y := y + $100;
      while ((y and $ff) = ((y shr 16) and $ff))
         or (((y shr 8) and $ff) = ((y shr 16) and $ff)) do
        y := y + $10000;
      Move(z^, zBuf[0], n + 1);
      z := @zBuf[0];
      zXi := find2(z, 'X', 'X', 0);
      while zXi >= 0 do
      begin
        z[zXi]     := HEXDIGITS[y and $f]; y := y shr 4;
        z[zXi + 1] := HEXDIGITS[y and $f]; y := y shr 4;
        zXi := find2(z, 'X', 'X', zXi + 2);
      end;
    end
    else
    begin
      zXi := find2(z, 'D', 'D', 0);
      if zXi >= 0 then
      begin
        y := prngInt(p);
        Move(z^, zBuf[0], n + 1);
        z := @zBuf[0];
        zXi := find2(z, 'D', 'D', 0);
        while zXi >= 0 do
        begin
          z[zXi]     := DECDIGITS[y mod 10]; y := y div 10;
          z[zXi + 1] := DECDIGITS[y mod 10]; y := y div 10;
          zXi := find2(z, 'D', 'D', zXi + 2);
        end;
      end;
    end;
    if j + n < STRSZ then
    begin
      Move(z^, zDest[j], n);
      Inc(j, n);
    end;
  end;
  zDest[STRSZ - 1] := #0;
  if j < STRSZ then zDest[j] := #0;
end;

{ randomjson.c:195..212 — randJsonFunc.  Four expansion passes with
  decreasing growth probability so the document fills out without
  unbounded recursion.  The branch between JSON and JSON5 sits in the
  user_data: the registration table passes &cZero or &cOne and we
  read it back here. }
procedure randJsonFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  iSeed: u32;
  eType: i32;
  prng: TPrng;
  z1, z2: array[0..STRSZ] of AnsiChar;
  pAux: ^i32;
begin
  pAux := sqlite3_user_data(pCtx);
  eType := pAux^;
  iSeed := u32(sqlite3_value_int(argv[0]));
  prngSeed(prng, iSeed);
  jsonExpand(nil,    @z2[0], prng, eType, 1000);
  jsonExpand(@z2[0], @z1[0], prng, eType, 1000);
  jsonExpand(@z1[0], @z2[0], prng, eType, 100);
  jsonExpand(@z2[0], @z1[0], prng, eType, 0);
  sqlite3_result_text(pCtx, @z1[0], -1, SQLITE_TRANSIENT);
end;

var
  rjZero: i32 = 0;  { selects the JSON   half of azJsonAtoms[] / azJsonTemplate[] }
  rjOne:  i32 = 1;  { selects the JSON5  half }

function sqlite3RandomJsonInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_INNOCUOUS or SQLITE_DETERMINISTIC;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'random_json', 1, Flags, @rjZero,
                                @randJsonFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'random_json5', 1, Flags, @rjOne,
                                  @randJsonFunc, nil, nil);
  Result := rc;
end;

end.
