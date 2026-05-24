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
  (see commit history).
}
{$I ../passqlite3.inc}
program TestFts3Unicode;

{
  Phase 6.40.1.e / 6.40.1.f gate — fts3_unicode2.c (codepoint classifier)
  + fts3_unicode.c (the "unicode61" tokenizer module), passqlite3fts3.

  Part 1 asserts sqlite3FtsUnicodeIsalnum / Isdiacritic / Fold against exact
  values read off the C tables (verified by compiling fts3_unicode2.c as an
  oracle):
     c=0x0041 'A'  alnum=1 fold=97 ('a')
     c=0x0061 'a'  alnum=1 fold=97
     c=0x00C0 'À'  alnum=1 fold(0)=224 ('à')   fold(1)=fold(2)=97 ('a')
     c=0x00E9 'é'  alnum=1 fold(0)=233         fold(1)=fold(2)=101 ('e')
     c=0x0100 'Ā'  alnum=1 fold(0)=257 ('ā')   fold(1)=fold(2)=97 ('a')
     c=0x0399 'Ι'  alnum=1 fold=953 ('ι')
     c=0x03A9 'Ω'  alnum=1 fold=969 ('ω')
     c=0x4E2D 中    alnum=1 fold=20013 (unchanged CJK)
     c=0x0020 ' '  alnum=0
     c=0x0021 '!'  alnum=0
     c=0x0030 '0'  alnum=1
     c=768 combining grave accent: diacritic=1

  Part 2 drives the unicode61 tokenizer vtable directly over a mixed
  ASCII + multibyte string "Héllo 中文! Ω" and asserts the tokens, byte
  offsets, and that the default remove_diacritics=1 strips diacritics
  (é -> e) while CJK is preserved and Ω folds to ω.  Expected outputs were
  captured from a faithful reimplementation of unicodeNext driven by the C
  fts3_unicode2.c oracle:
     token0 [0,6)  "hello"          (68 65 6C 6C 6F)
     token1 [7,13) 中文              (E4 B8 AD E6 96 87)
     token2 [15,17) ω               (CF 89)
}

uses
  ctypes,
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3fts3;

var
  g_fail: Integer = 0;

procedure Check(cond: Boolean; const msg: string);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(g_fail);
  end;
end;

procedure CheckEq(got, expected: cint; const msg: string);
begin
  if got <> expected then begin
    WriteLn('FAIL: ', msg, ' (got ', got, ', expected ', expected, ')');
    Inc(g_fail);
  end;
end;

procedure TestClassifier;
begin
  { sqlite3FtsUnicodeIsalnum }
  CheckEq(sqlite3FtsUnicodeIsalnum($41), 1, 'isalnum A');
  CheckEq(sqlite3FtsUnicodeIsalnum($61), 1, 'isalnum a');
  CheckEq(sqlite3FtsUnicodeIsalnum($30), 1, 'isalnum 0');
  CheckEq(sqlite3FtsUnicodeIsalnum($C0), 1, 'isalnum A-grave');
  CheckEq(sqlite3FtsUnicodeIsalnum($4E2D), 1, 'isalnum CJK 中');
  CheckEq(sqlite3FtsUnicodeIsalnum($20), 0, 'isalnum space');
  CheckEq(sqlite3FtsUnicodeIsalnum($21), 0, 'isalnum bang');

  { sqlite3FtsUnicodeIsdiacritic }
  CheckEq(sqlite3FtsUnicodeIsdiacritic($41), 0, 'isdiacritic A');
  Check(sqlite3FtsUnicodeIsdiacritic(768) <> 0, 'isdiacritic U+0300 combining grave');
  CheckEq(sqlite3FtsUnicodeIsdiacritic(767), 0, 'isdiacritic 767 (below range)');
  CheckEq(sqlite3FtsUnicodeIsdiacritic(818), 0, 'isdiacritic 818 (above range)');

  { sqlite3FtsUnicodeFold — ASCII fast path }
  CheckEq(sqlite3FtsUnicodeFold($41, 0), $61, 'fold A->a');
  CheckEq(sqlite3FtsUnicodeFold($61, 0), $61, 'fold a->a');

  { fold pairs read off the C tables }
  CheckEq(sqlite3FtsUnicodeFold($C0, 0), 224, 'fold A-grave->a-grave (no diacritic strip)');
  CheckEq(sqlite3FtsUnicodeFold($C0, 1), 97,  'fold A-grave->a (strip)');
  CheckEq(sqlite3FtsUnicodeFold($C0, 2), 97,  'fold A-grave->a (complex strip)');
  CheckEq(sqlite3FtsUnicodeFold($E9, 0), 233, 'fold e-acute (no strip)');
  CheckEq(sqlite3FtsUnicodeFold($E9, 1), 101, 'fold e-acute->e (strip)');
  CheckEq(sqlite3FtsUnicodeFold($100, 0), 257, 'fold A-macron->a-macron');
  CheckEq(sqlite3FtsUnicodeFold($100, 1), 97,  'fold A-macron->a (strip)');
  CheckEq(sqlite3FtsUnicodeFold($399, 0), 953, 'fold Greek Iota->iota');
  CheckEq(sqlite3FtsUnicodeFold($3A9, 0), 969, 'fold Greek Omega->omega');
  CheckEq(sqlite3FtsUnicodeFold($4E2D, 1), $4E2D, 'fold CJK unchanged');
end;

type
  TTok = record
    bytes : array[0..63] of Byte;
    nByte : cint;
    sOfs  : cint;
    eOfs  : cint;
    pos   : cint;
  end;

function HexOf(const t: TTok): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to t.nByte - 1 do
    Result := Result + IntToHex(t.bytes[i], 2);
end;

procedure TestUnicode61;
var
  pModule: Psqlite3_tokenizer_module;
  pTok: Psqlite3_tokenizer;
  pCsr: Psqlite3_tokenizer_cursor;
  rc: cint;
  pzToken: PChar;
  nBytes, sOfs, eOfs, pos: cint;
  toks: array[0..7] of TTok;
  n, i: Integer;
const
  { "Héllo 中文! Ω" : H é(C3A9) l l o sp 中(E4B8AD) 文(E69687) ! sp Ω(CEA9) }
  S: array[0..16] of Byte = (
    $48, $C3, $A9, $6C, $6C, $6F, $20,
    $E4, $B8, $AD, $E6, $96, $87, $21, $20, $CE, $A9);
var
  zInput: array[0..16] of Char;
begin
  for i := 0 to 16 do zInput[i] := Chr(S[i]);

  pModule := nil;
  sqlite3Fts3UnicodeTokenizer(@pModule);
  Check(pModule <> nil, 'unicode61: module pointer set');
  Check(pModule^.iVersion = 0, 'unicode61: iVersion 0');

  pTok := nil;
  rc := pModule^.xCreate(0, nil, @pTok);
  CheckEq(rc, SQLITE_OK, 'unicode61: xCreate rc');
  Check(pTok <> nil, 'unicode61: xCreate sets tokenizer');
  pTok^.pModule := pModule;

  pCsr := nil;
  rc := pModule^.xOpen(pTok, @zInput[0], 17, @pCsr);
  CheckEq(rc, SQLITE_OK, 'unicode61: xOpen rc');
  Check(pCsr <> nil, 'unicode61: xOpen sets cursor');
  pCsr^.pTokenizer := pTok;

  n := 0;
  repeat
    pzToken := nil; nBytes := 0; sOfs := 0; eOfs := 0; pos := 0;
    rc := pModule^.xNext(pCsr, @pzToken, @nBytes, @sOfs, @eOfs, @pos);
    if (rc = SQLITE_OK) and (n <= High(toks)) then begin
      toks[n].nByte := nBytes;
      if nBytes <= 64 then
        Move(pzToken^, toks[n].bytes[0], nBytes);
      toks[n].sOfs := sOfs;
      toks[n].eOfs := eOfs;
      toks[n].pos := pos;
      Inc(n);
    end;
  until rc <> SQLITE_OK;
  CheckEq(rc, SQLITE_DONE, 'unicode61: terminates with SQLITE_DONE');

  CheckEq(cint(n), 3, 'unicode61: 3 tokens');
  if n = 3 then begin
    { token0 "Héllo" -> "hello" [0,6) (diacritic stripped, default rd=1) }
    Check(HexOf(toks[0]) = '68656C6C6F', 'unicode61: tok0 = hello, got ' + HexOf(toks[0]));
    CheckEq(toks[0].sOfs, 0, 'unicode61: tok0 sOfs');
    CheckEq(toks[0].eOfs, 6, 'unicode61: tok0 eOfs');
    CheckEq(toks[0].pos, 0, 'unicode61: tok0 pos');
    { token1 中文 [7,13) unchanged }
    Check(HexOf(toks[1]) = 'E4B8ADE69687', 'unicode61: tok1 = 中文, got ' + HexOf(toks[1]));
    CheckEq(toks[1].sOfs, 7, 'unicode61: tok1 sOfs');
    CheckEq(toks[1].eOfs, 13, 'unicode61: tok1 eOfs');
    CheckEq(toks[1].pos, 1, 'unicode61: tok1 pos');
    { token2 Ω -> ω [15,17) }
    Check(HexOf(toks[2]) = 'CF89', 'unicode61: tok2 = omega, got ' + HexOf(toks[2]));
    CheckEq(toks[2].sOfs, 15, 'unicode61: tok2 sOfs');
    CheckEq(toks[2].eOfs, 17, 'unicode61: tok2 eOfs');
    CheckEq(toks[2].pos, 2, 'unicode61: tok2 pos');
  end;

  CheckEq(pModule^.xClose(pCsr), SQLITE_OK, 'unicode61: xClose rc');
  CheckEq(pModule^.xDestroy(pTok), SQLITE_OK, 'unicode61: xDestroy rc');
end;

procedure TestRemoveDiacriticsOption;
var
  pModule: Psqlite3_tokenizer_module;
  pTok: Psqlite3_tokenizer;
  pCsr: Psqlite3_tokenizer_cursor;
  rc: cint;
  pzToken: PChar;
  nBytes, sOfs, eOfs, pos: cint;
  hex: string;
  i: Integer;
  argv: array[0..0] of PChar;
const
  { "Hé" : H é(C3A9) }
  S: array[0..2] of Byte = ($48, $C3, $A9);
var
  zInput: array[0..2] of Char;
  opt: AnsiString;
begin
  for i := 0 to 2 do zInput[i] := Chr(S[i]);

  pModule := nil;
  sqlite3Fts3UnicodeTokenizer(@pModule);

  { remove_diacritics=0 : é must be PRESERVED (folds to é = C3 A9) }
  opt := 'remove_diacritics=0';
  argv[0] := PChar(opt);
  pTok := nil;
  rc := pModule^.xCreate(1, @argv[0], @pTok);
  CheckEq(rc, SQLITE_OK, 'rd0: xCreate rc');
  pTok^.pModule := pModule;

  pCsr := nil;
  rc := pModule^.xOpen(pTok, @zInput[0], 3, @pCsr);
  CheckEq(rc, SQLITE_OK, 'rd0: xOpen rc');
  pCsr^.pTokenizer := pTok;

  pzToken := nil; nBytes := 0; sOfs := 0; eOfs := 0; pos := 0;
  rc := pModule^.xNext(pCsr, @pzToken, @nBytes, @sOfs, @eOfs, @pos);
  CheckEq(rc, SQLITE_OK, 'rd0: first token rc');
  hex := '';
  for i := 0 to nBytes - 1 do hex := hex + IntToHex(Byte(pzToken[i]), 2);
  Check(hex = '68C3A9', 'rd0: tok = h + e-acute preserved, got ' + hex);

  pModule^.xClose(pCsr);
  pModule^.xDestroy(pTok);

  { An unrecognized option must make xCreate fail with SQLITE_ERROR. }
  opt := 'bogus=1';
  argv[0] := PChar(opt);
  pTok := nil;
  rc := pModule^.xCreate(1, @argv[0], @pTok);
  CheckEq(rc, SQLITE_ERROR, 'bad option: xCreate returns SQLITE_ERROR');
  Check(pTok = nil, 'bad option: tokenizer left nil');
end;

begin
  TestClassifier;
  TestUnicode61;
  TestRemoveDiacriticsOption;
  if g_fail = 0 then begin
    WriteLn('TestFts3Unicode: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3Unicode: FAIL (', g_fail, ' assertions)');
    Halt(1);
  end;
end.
