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
program TestFts3Tok;

{
  Phase 6.40.1.c / 6.40.1.d gate — fts3_tokenizer1.c (simple) +
  fts3_porter.c (porter) tokenizer modules (passqlite3fts3).

  Self-contained: drives the sqlite3_tokenizer_module vtable directly
  (xCreate / xOpen / xNext* / xClose / xDestroy); no FTS index core and no
  oracle build is needed at test time.

    * simple  — tokenizes "A test, of THE tokenizer!", asserting that the
      module lowercases each token and splits on non-alphanumeric ASCII with
      the correct (token, startOffset, endOffset, position) tuples.

    * porter  — feeds a word list through the porter cursor and asserts the
      stemmed output against the stems produced by the ORIGINAL C
      porter_stemmer (fts3_porter.c:131..572), captured offline:
          caresses->caress  ponies->poni     ties->ti      caress->caress
          cats->cat         feed->feed       agreed->agre  plastered->plaster
          motoring->motor   sing->sing       happy->happi  relational->relat
          conditional->condit  rational->ration  valenci->valenc
          running->run      runs->run        the->the      tokenizer->token
          test->test
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

{ Collected token record from one xNext call. }
type
  TTok = record
    text  : AnsiString;
    sOfs  : cint;
    eOfs  : cint;
    pos   : cint;
  end;

{ Run the full vtable cycle of pModule over zInput, returning the token list
  in toks[0..n-1] and the count in n.  Returns the final xNext rc. }
function Tokenize(pModule: Psqlite3_tokenizer_module; const zInput: AnsiString;
  var toks: array of TTok; var n: Integer): cint;
var
  pTok: Psqlite3_tokenizer;
  pCsr: Psqlite3_tokenizer_cursor;
  rc: cint;
  pzToken: PChar;
  nBytes, sOfs, eOfs, pos: cint;
  buf: AnsiString;
begin
  n := 0;
  pTok := nil;
  rc := pModule^.xCreate(0, nil, @pTok);
  Check(rc = SQLITE_OK, 'xCreate returns SQLITE_OK');
  Check(pTok <> nil, 'xCreate sets pTokenizer');
  if (rc <> SQLITE_OK) or (pTok = nil) then Exit(rc);
  { The registry normally fills in pModule; do it here so xNext can reach the
    tokenizer instance via pCursor^.pTokenizer^.pModule if needed. }
  pTok^.pModule := pModule;

  pCsr := nil;
  rc := pModule^.xOpen(pTok, PChar(zInput), cint(Length(zInput)), @pCsr);
  Check(rc = SQLITE_OK, 'xOpen returns SQLITE_OK');
  Check(pCsr <> nil, 'xOpen sets pCursor');
  if (rc <> SQLITE_OK) or (pCsr = nil) then begin
    pModule^.xDestroy(pTok);
    Exit(rc);
  end;
  { xOpen does not set pCursor^.pTokenizer; the registry does. }
  pCsr^.pTokenizer := pTok;

  repeat
    pzToken := nil; nBytes := 0; sOfs := 0; eOfs := 0; pos := 0;
    rc := pModule^.xNext(pCsr, @pzToken, @nBytes, @sOfs, @eOfs, @pos);
    if rc = SQLITE_OK then begin
      SetString(buf, pzToken, nBytes);
      if n <= High(toks) then begin
        toks[n].text := buf;
        toks[n].sOfs := sOfs;
        toks[n].eOfs := eOfs;
        toks[n].pos  := pos;
        Inc(n);
      end;
    end;
  until rc <> SQLITE_OK;

  Check(rc = SQLITE_DONE, 'xNext terminates with SQLITE_DONE');
  Check(pModule^.xClose(pCsr) = SQLITE_OK, 'xClose returns SQLITE_OK');
  Check(pModule^.xDestroy(pTok) = SQLITE_OK, 'xDestroy returns SQLITE_OK');
  Result := rc;
end;

procedure TestSimple;
var
  pModule: Psqlite3_tokenizer_module;
  toks: array[0..15] of TTok;
  n: Integer;
const
  { "A test, of THE tokenizer!"
     0123456789...                       }
  S = 'A test, of THE tokenizer!';
begin
  pModule := nil;
  sqlite3Fts3SimpleTokenizerModule(@pModule);
  Check(pModule <> nil, 'simple: module pointer set');
  Check(pModule^.iVersion = 0, 'simple: iVersion 0');

  Tokenize(pModule, S, toks, n);

  Check(n = 5, 'simple: 5 tokens, got ' + IntToStr(n));
  if n = 5 then begin
    { token 0: "A" -> "a" at [0,1) }
    Check(toks[0].text = 'a',         'simple: tok0 = a');
    Check(toks[0].sOfs = 0,           'simple: tok0 sOfs 0');
    Check(toks[0].eOfs = 1,           'simple: tok0 eOfs 1');
    Check(toks[0].pos  = 0,           'simple: tok0 pos 0');
    { token 1: "test" at [2,6) }
    Check(toks[1].text = 'test',      'simple: tok1 = test');
    Check(toks[1].sOfs = 2,           'simple: tok1 sOfs 2');
    Check(toks[1].eOfs = 6,           'simple: tok1 eOfs 6');
    Check(toks[1].pos  = 1,           'simple: tok1 pos 1');
    { token 2: "of" at [8,10) }
    Check(toks[2].text = 'of',        'simple: tok2 = of');
    Check(toks[2].sOfs = 8,           'simple: tok2 sOfs 8');
    Check(toks[2].eOfs = 10,          'simple: tok2 eOfs 10');
    { token 3: "THE" -> "the" at [11,14) }
    Check(toks[3].text = 'the',       'simple: tok3 = the (lowercased)');
    Check(toks[3].sOfs = 11,          'simple: tok3 sOfs 11');
    Check(toks[3].eOfs = 14,          'simple: tok3 eOfs 14');
    { token 4: "tokenizer" at [15,24) }
    Check(toks[4].text = 'tokenizer', 'simple: tok4 = tokenizer');
    Check(toks[4].sOfs = 15,          'simple: tok4 sOfs 15');
    Check(toks[4].eOfs = 24,          'simple: tok4 eOfs 24');
    Check(toks[4].pos  = 4,           'simple: tok4 pos 4');
  end;
end;

procedure TestPorter;
var
  pModule: Psqlite3_tokenizer_module;
  toks: array[0..63] of TTok;
  n, i: Integer;
const
  { Input words, space-separated (the porter delimiter set treats space as a
    delimiter), and the expected stems from the C porter_stemmer. }
  WORDS: array[0..19] of AnsiString = (
    'caresses', 'ponies', 'ties', 'caress', 'cats', 'feed', 'agreed',
    'plastered', 'motoring', 'sing', 'happy', 'relational', 'conditional',
    'rational', 'valenci', 'running', 'runs', 'the', 'tokenizer', 'test');
  STEMS: array[0..19] of AnsiString = (
    'caress', 'poni', 'ti', 'caress', 'cat', 'feed', 'agre',
    'plaster', 'motor', 'sing', 'happi', 'relat', 'condit',
    'ration', 'valenc', 'run', 'run', 'the', 'token', 'test');
var
  S: AnsiString;
begin
  pModule := nil;
  sqlite3Fts3PorterTokenizerModule(@pModule);
  Check(pModule <> nil, 'porter: module pointer set');
  Check(pModule^.iVersion = 0, 'porter: iVersion 0');

  S := '';
  for i := 0 to High(WORDS) do begin
    if i > 0 then S := S + ' ';
    S := S + WORDS[i];
  end;

  Tokenize(pModule, S, toks, n);

  Check(n = Length(WORDS), 'porter: token count = ' + IntToStr(Length(WORDS))
    + ', got ' + IntToStr(n));
  if n = Length(WORDS) then begin
    for i := 0 to n - 1 do begin
      Check(toks[i].text = STEMS[i],
        'porter: ' + WORDS[i] + ' -> ' + STEMS[i] + ', got ' + toks[i].text);
      Check(toks[i].pos = cint(i), 'porter: position ' + IntToStr(i));
    end;
  end;
end;

begin
  TestSimple;
  TestPorter;
  if g_fail = 0 then begin
    WriteLn('TestFts3Tok: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3Tok: FAIL (', g_fail, ' assertions)');
    Halt(1);
  end;
end.
