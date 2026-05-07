{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/normalize.c (717 lines in C).

  Implements `sqlite3_normalize(zSql)` which converts an SQL string to a
  canonical form by:
    (1) replacing every literal (string / blob / numeric / NULL) with '?',
    (2) collapsing whitespace and comments to single spaces,
    (3) lower-casing ASCII letters, and
    (4) rewriting `IN (v1, v2, ...)` lists to `IN (?,?,?)`.

  Mirrors normalize.c byte-for-byte; the tokenizer is a verbatim copy of
  the slimmed-down sqlite3GetToken from tokenize.c that ext/misc/normalize
  ships.

  Public entries:
    - sqlite3_normalize(zSql) — string-in/string-out helper.  Caller frees
      the returned buffer with sqlite3_free.  Returns nil on OOM or
      tokenizer error.
    - sqlite3NormalizeInit(db) — registers the SQL function
      `sqlite3_normalize(X)` (UTF-8, deterministic, innocuous) so the
      helper is reachable from SQL/CLI for differential testing.  This
      registration is a port convenience; the C source only ships the
      bare function and the optional -DSQLITE_NORMALIZE_CLI program.
}
{$I passqlite3.inc}
unit passqlite3normalize;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3_normalize(zSql: PAnsiChar): PAnsiChar;
function sqlite3NormalizeInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os; { sqlite3_malloc64 / sqlite3_realloc64 / sqlite3_free }

{ Character classes — verbatim from normalize.c:77..104. }
const
  CC_X        = 0;
  CC_KYWD     = 1;
  CC_ID       = 2;
  CC_DIGIT    = 3;
  CC_DOLLAR   = 4;
  CC_VARALPHA = 5;
  CC_VARNUM   = 6;
  CC_SPACE    = 7;
  CC_QUOTE    = 8;
  CC_QUOTE2   = 9;
  CC_PIPE     = 10;
  CC_MINUS    = 11;
  CC_LT       = 12;
  CC_GT       = 13;
  CC_EQ       = 14;
  CC_BANG     = 15;
  CC_SLASH    = 16;
  CC_LP       = 17;
  CC_RP       = 18;
  CC_SEMI     = 19;
  CC_PLUS     = 20;
  CC_STAR     = 21;
  CC_PERCENT  = 22;
  CC_COMMA    = 23;
  CC_AND      = 24;
  CC_TILDA    = 25;
  CC_DOT      = 26;
  CC_ILLEGAL  = 27;

{ Lookup table — verbatim from normalize.c:106..124. }
const
  aiClass: array[0..255] of Byte = (
    27, 27, 27, 27, 27, 27, 27, 27, 27,  7,  7, 27,  7,  7, 27, 27,
    27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
     7, 15,  8,  5,  4, 22, 24,  8, 17, 18, 21, 20, 23, 11, 26, 16,
     3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  5, 19, 12, 14, 13,  6,
     5,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
     1,  1,  1,  1,  1,  1,  1,  1,  0,  1,  1,  9, 27, 27, 27,  1,
     8,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
     1,  1,  1,  1,  1,  1,  1,  1,  0,  1,  1, 27, 10, 27, 25, 27,
     2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
     2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
     2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
     2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
     2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
     2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
     2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
     2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2
  );

{ ASCII upper→lower table — verbatim from normalize.c:133..149. }
const
  upperToLower: array[0..255] of Byte = (
      0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16, 17,
     18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
     36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53,
     54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 97, 98, 99,100,101,102,103,
    104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,
    122, 91, 92, 93, 94, 95, 96, 97, 98, 99,100,101,102,103,104,105,106,107,
    108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,123,124,125,
    126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
    144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,160,161,
    162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179,
    180,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,196,197,
    198,199,200,201,202,203,204,205,206,207,208,209,210,211,212,213,214,215,
    216,217,218,219,220,221,222,223,224,225,226,227,228,229,230,231,232,233,
    234,235,236,237,238,239,240,241,242,243,244,245,246,247,248,249,250,251,
    252,253,254,255
  );

{ Ctype map — verbatim from normalize.c:179..215.  Bit 0x01=isspace,
  0x02=isalpha, 0x04=isdigit, 0x06=isalnum, 0x08=isxdigit, 0x40=identifier,
  0x80=quote, 0x46=any-id-char. }
const
  ctypeMap: array[0..255] of Byte = (
    $00, $00, $00, $00, $00, $00, $00, $00,
    $00, $01, $01, $01, $01, $01, $00, $00,
    $00, $00, $00, $00, $00, $00, $00, $00,
    $00, $00, $00, $00, $00, $00, $00, $00,
    $01, $00, $80, $00, $40, $00, $00, $80,
    $00, $00, $00, $00, $00, $00, $00, $00,
    $0c, $0c, $0c, $0c, $0c, $0c, $0c, $0c,
    $0c, $0c, $00, $00, $00, $00, $00, $00,

    $00, $0a, $0a, $0a, $0a, $0a, $0a, $02,
    $02, $02, $02, $02, $02, $02, $02, $02,
    $02, $02, $02, $02, $02, $02, $02, $02,
    $02, $02, $02, $80, $00, $00, $00, $40,
    $80, $2a, $2a, $2a, $2a, $2a, $2a, $22,
    $22, $22, $22, $22, $22, $22, $22, $22,
    $22, $22, $22, $22, $22, $22, $22, $22,
    $22, $22, $22, $00, $00, $00, $00, $00,

    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,

    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40,
    $40, $40, $40, $40, $40, $40, $40, $40
  );

{ Token classes used by normalize — see normalize.c:252..287.  All
  punct/keyword/literal aliases collapse to TK_PUNCT/TK_NAME/TK_LITERAL. }
const
  TK_SPACE   = 0;
  TK_NAME    = 1;
  TK_LITERAL = 2;
  TK_PUNCT   = 3;
  TK_ERROR   = 4;

function isSpace(c: Byte): Boolean; inline;
begin
  Result := (ctypeMap[c] and $01) <> 0;
end;

function isDigit(c: Byte): Boolean; inline;
begin
  Result := (ctypeMap[c] and $04) <> 0;
end;

function isXDigit(c: Byte): Boolean; inline;
begin
  Result := (ctypeMap[c] and $08) <> 0;
end;

function isIdChar(c: Byte): Boolean; inline;
begin
  Result := (ctypeMap[c] and $46) <> 0;
end;

function toLower(c: Byte): Byte; inline;
begin
  Result := upperToLower[c];
end;

{ Faithful port of sqlite3GetToken (normalize.c:300..554).  z is a 0-
  terminated byte buffer; returns the length of the token starting at
  z[0] and writes the token type to tokenType^.  The break-out of the
  CC_KYWD / CC_X / CC_ID arms drops into the trailing "while IdChar"
  loop just like the C source. }
function nzGetToken(z: PByte; tokenType: PInt32): SizeInt;
var
  i: SizeInt;
  c: i32;
  delim: i32;
  n: i32;
begin
  case aiClass[z[0]] of
    CC_SPACE:
      begin
        i := 1;
        while isSpace(z[i]) do Inc(i);
        tokenType^ := TK_SPACE;
        Exit(i);
      end;
    CC_MINUS:
      begin
        if z[1] = Byte('-') then
        begin
          i := 2;
          c := z[i];
          while (c <> 0) and (c <> Byte(#10)) do
          begin
            Inc(i);
            c := z[i];
          end;
          tokenType^ := TK_SPACE;
          Exit(i);
        end;
        tokenType^ := TK_PUNCT;
        Exit(1);
      end;
    CC_LP, CC_RP, CC_SEMI, CC_PLUS, CC_STAR, CC_PERCENT,
    CC_COMMA, CC_AND, CC_TILDA:
      begin
        tokenType^ := TK_PUNCT;
        Exit(1);
      end;
    CC_SLASH:
      begin
        if (z[1] <> Byte('*')) or (z[2] = 0) then
        begin
          tokenType^ := TK_PUNCT;
          Exit(1);
        end;
        i := 3;
        c := z[2];
        while ((c <> Byte('*')) or (z[i] <> Byte('/'))) and (z[i] <> 0) do
        begin
          c := z[i];
          Inc(i);
        end;
        if c <> 0 then Inc(i);
        tokenType^ := TK_SPACE;
        Exit(i);
      end;
    CC_EQ:
      begin
        tokenType^ := TK_PUNCT;
        if z[1] = Byte('=') then Exit(2) else Exit(1);
      end;
    CC_LT:
      begin
        c := z[1];
        if c = Byte('=') then begin tokenType^ := TK_PUNCT; Exit(2); end
        else if c = Byte('>') then begin tokenType^ := TK_PUNCT; Exit(2); end
        else if c = Byte('<') then begin tokenType^ := TK_PUNCT; Exit(2); end
        else begin tokenType^ := TK_PUNCT; Exit(1); end;
      end;
    CC_GT:
      begin
        c := z[1];
        if c = Byte('=') then begin tokenType^ := TK_PUNCT; Exit(2); end
        else if c = Byte('>') then begin tokenType^ := TK_PUNCT; Exit(2); end
        else begin tokenType^ := TK_PUNCT; Exit(1); end;
      end;
    CC_BANG:
      begin
        if z[1] <> Byte('=') then
        begin
          tokenType^ := TK_ERROR;
          Exit(1);
        end;
        tokenType^ := TK_PUNCT;
        Exit(2);
      end;
    CC_PIPE:
      begin
        if z[1] <> Byte('|') then
        begin
          tokenType^ := TK_PUNCT;
          Exit(1);
        end;
        tokenType^ := TK_PUNCT;
        Exit(2);
      end;
    CC_QUOTE:
      begin
        delim := z[0];
        i := 1;
        c := z[i];
        while c <> 0 do
        begin
          if c = delim then
          begin
            if z[i + 1] = delim then
              Inc(i)
            else
              Break;
          end;
          Inc(i);
          c := z[i];
        end;
        if c = Byte('''') then
        begin
          tokenType^ := TK_LITERAL;
          Exit(i + 1);
        end
        else if c <> 0 then
        begin
          tokenType^ := TK_NAME;
          Exit(i + 1);
        end
        else
        begin
          tokenType^ := TK_ERROR;
          Exit(i);
        end;
      end;
    CC_DOT:
      begin
        if not isDigit(z[1]) then
        begin
          tokenType^ := TK_PUNCT;
          Exit(1);
        end;
        { Fall through into the digit branch below — mirrored as a
          duplicated body since Pascal's case has no fall-through. }
        tokenType^ := TK_LITERAL;
        i := 0;
        if (z[0] = Byte('0')) and ((z[1] = Byte('x')) or (z[1] = Byte('X')))
           and isXDigit(z[2]) then
        begin
          i := 3;
          while isXDigit(z[i]) do Inc(i);
          Exit(i);
        end;
        while isDigit(z[i]) do Inc(i);
        if z[i] = Byte('.') then
        begin
          Inc(i);
          while isDigit(z[i]) do Inc(i);
          tokenType^ := TK_LITERAL;
        end;
        if (z[i] = Byte('e')) or (z[i] = Byte('E')) then
        begin
          if isDigit(z[i + 1])
             or (((z[i + 1] = Byte('+')) or (z[i + 1] = Byte('-')))
                 and isDigit(z[i + 2])) then
          begin
            Inc(i, 2);
            while isDigit(z[i]) do Inc(i);
            tokenType^ := TK_LITERAL;
          end;
        end;
        while isIdChar(z[i]) do
        begin
          tokenType^ := TK_ERROR;
          Inc(i);
        end;
        Exit(i);
      end;
    CC_DIGIT:
      begin
        tokenType^ := TK_LITERAL;
        if (z[0] = Byte('0')) and ((z[1] = Byte('x')) or (z[1] = Byte('X')))
           and isXDigit(z[2]) then
        begin
          i := 3;
          while isXDigit(z[i]) do Inc(i);
          Exit(i);
        end;
        i := 0;
        while isDigit(z[i]) do Inc(i);
        if z[i] = Byte('.') then
        begin
          Inc(i);
          while isDigit(z[i]) do Inc(i);
          tokenType^ := TK_LITERAL;
        end;
        if (z[i] = Byte('e')) or (z[i] = Byte('E')) then
        begin
          if isDigit(z[i + 1])
             or (((z[i + 1] = Byte('+')) or (z[i + 1] = Byte('-')))
                 and isDigit(z[i + 2])) then
          begin
            Inc(i, 2);
            while isDigit(z[i]) do Inc(i);
            tokenType^ := TK_LITERAL;
          end;
        end;
        while isIdChar(z[i]) do
        begin
          tokenType^ := TK_ERROR;
          Inc(i);
        end;
        Exit(i);
      end;
    CC_QUOTE2:
      begin
        i := 1;
        c := z[0];
        while (c <> Byte(']')) and (z[i] <> 0) do
        begin
          c := z[i];
          Inc(i);
        end;
        if c = Byte(']') then tokenType^ := TK_NAME
        else tokenType^ := TK_ERROR;
        Exit(i);
      end;
    CC_VARNUM:
      begin
        tokenType^ := TK_LITERAL;
        i := 1;
        while isDigit(z[i]) do Inc(i);
        Exit(i);
      end;
    CC_DOLLAR, CC_VARALPHA:
      begin
        n := 0;
        tokenType^ := TK_LITERAL;
        i := 1;
        c := z[i];
        while c <> 0 do
        begin
          if isIdChar(c) then
            Inc(n)
          else if (c = Byte('(')) and (n > 0) then
          begin
            repeat
              Inc(i);
              c := z[i];
            until (c = 0) or isSpace(c) or (c = Byte(')'));
            if c = Byte(')') then
              Inc(i)
            else
              tokenType^ := TK_ERROR;
            Break;
          end
          else if (c = Byte(':')) and (z[i + 1] = Byte(':')) then
            Inc(i)
          else
            Break;
          Inc(i);
          c := z[i];
        end;
        if n = 0 then tokenType^ := TK_ERROR;
        Exit(i);
      end;
    CC_KYWD:
      begin
        i := 1;
        while aiClass[z[i]] <= CC_KYWD do Inc(i);
        if isIdChar(z[i]) then
        begin
          { Started as keyword chars but z[i] is a non-keyword identifier
            char — fall through to the trailing IdChar loop. }
          Inc(i);
          while isIdChar(z[i]) do Inc(i);
          tokenType^ := TK_NAME;
          Exit(i);
        end;
        tokenType^ := TK_NAME;
        Exit(i);
      end;
    CC_X:
      begin
        if z[1] = Byte('''') then
        begin
          tokenType^ := TK_LITERAL;
          i := 2;
          while isXDigit(z[i]) do Inc(i);
          if (z[i] <> Byte('''')) or ((i and 1) <> 0) then
          begin
            tokenType^ := TK_ERROR;
            while (z[i] <> 0) and (z[i] <> Byte('''')) do Inc(i);
          end;
          if z[i] <> 0 then Inc(i);
          Exit(i);
        end;
        { Fall-through to CC_ID. }
        i := 1;
        while isIdChar(z[i]) do Inc(i);
        tokenType^ := TK_NAME;
        Exit(i);
      end;
    CC_ID:
      begin
        i := 1;
        while isIdChar(z[i]) do Inc(i);
        tokenType^ := TK_NAME;
        Exit(i);
      end;
  else
    tokenType^ := TK_ERROR;
    Exit(1);
  end;
end;

{ Compare n bytes of two ASCII byte runs case-insensitively (lower-case
  using upperToLower).  Returns 0 on match. }
function lcStrnCmp(a, b: PAnsiChar; n: SizeInt): i32;
var
  i: SizeInt;
  ca, cb: Byte;
begin
  for i := 0 to n - 1 do
  begin
    ca := upperToLower[Byte(a[i])];
    cb := upperToLower[Byte(b[i])];
    if ca <> cb then Exit(i32(ca) - i32(cb));
  end;
  Result := 0;
end;

{ memcmp wrapper. }
function rawStrnCmp(a, b: PAnsiChar; n: SizeInt): i32;
var
  i: SizeInt;
begin
  for i := 0 to n - 1 do
    if a[i] <> b[i] then Exit(i32(Byte(a[i])) - i32(Byte(b[i])));
  Result := 0;
end;

{ strstr equivalent: returns pointer to first occurrence of needle in
  haystack, nil if not found.  needle is 0-terminated; haystack is
  bounded by the surrounding `j` length tracked by the caller. }
function rawStrStr(haystack: PAnsiChar; haystackLen: SizeInt;
  needle: PAnsiChar; needleLen: SizeInt): PAnsiChar;
var
  i: SizeInt;
begin
  if needleLen = 0 then Exit(haystack);
  if haystackLen < needleLen then Exit(nil);
  for i := 0 to haystackLen - needleLen do
  begin
    if rawStrnCmp(haystack + i, needle, needleLen) = 0 then
      Exit(haystack + i);
  end;
  Result := nil;
end;

{ Public helper — port of normalize.c:556..639. }
function sqlite3_normalize(zSql: PAnsiChar): PAnsiChar;
var
  z: PAnsiChar;
  nZ, nSql: SizeInt;
  i, j, k: SizeInt;
  tokenType: i32;
  n: SizeInt;
  zIn: PAnsiChar;
  nParen: i32;
  zNew: PAnsiChar;
begin
  if zSql = nil then Exit(nil);
  nSql := 0;
  while zSql[nSql] <> #0 do Inc(nSql);
  nZ := nSql;
  z := PAnsiChar(sqlite3_malloc64(u64(nZ + 2)));
  if z = nil then Exit(nil);

  i := 0;
  j := 0;
  while zSql[i] <> #0 do
  begin
    n := nzGetToken(PByte(zSql) + i, @tokenType);
    case tokenType of
      TK_SPACE: ; { skip }
      TK_ERROR:
        begin
          sqlite3_free(z);
          Exit(nil);
        end;
      TK_LITERAL:
        begin
          z[j] := '?';
          Inc(j);
        end;
      TK_PUNCT, TK_NAME:
        begin
          if (n = 4) and (sqlite3_strnicmp(zSql + i, PChar('NULL'), 4) = 0) then
          begin
            if ((j >= 3) and (rawStrnCmp(z + j - 2, 'is', 2) = 0)
                 and (not isIdChar(Byte(z[j - 3]))))
              or ((j >= 4) and (rawStrnCmp(z + j - 3, 'not', 3) = 0)
                 and (not isIdChar(Byte(z[j - 4])))) then
            begin
              { NULL is a keyword here, not a literal — fall through to
                the keyword copy path. }
            end
            else
            begin
              z[j] := '?';
              Inc(j);
              Inc(i, n);
              Continue;
            end;
          end;
          if (j > 0) and isIdChar(Byte(z[j - 1])) and isIdChar(Byte(zSql[i])) then
          begin
            z[j] := ' ';
            Inc(j);
          end;
          for k := 0 to n - 1 do
          begin
            z[j] := AnsiChar(toLower(Byte(zSql[i + k])));
            Inc(j);
          end;
        end;
    end;
    Inc(i, n);
  end;
  while (j > 0) and (z[j - 1] = ' ') do Dec(j);
  if (j > 0) and (z[j - 1] <> ';') then
  begin
    z[j] := ';';
    Inc(j);
  end;
  z[j] := #0;

  { Second pass: rewrite "in(...)" lists (when the inner is not SELECT/
    WITH) to "in(?,?,?)".  Mirrors normalize.c:611..637. }
  i := 0;
  while i < j do
  begin
    zIn := rawStrStr(z + i, j - i, 'in(', 3);
    if zIn = nil then Break;
    n := SizeInt(zIn - z) + 3;
    if (zIn > z) and isIdChar(Byte((zIn - 1)^)) then
    begin
      i := n;
      Continue;
    end;
    if rawStrnCmp(zIn, 'in(select', 9) = 0 then
    begin
      if not isIdChar(Byte(zIn[9])) then
      begin
        i := n;
        Continue;
      end;
    end;
    if rawStrnCmp(zIn, 'in(with', 7) = 0 then
    begin
      if not isIdChar(Byte(zIn[7])) then
      begin
        i := n;
        Continue;
      end;
    end;
    nParen := 1;
    k := 0;
    while z[n + k] <> #0 do
    begin
      if z[n + k] = '(' then Inc(nParen);
      if z[n + k] = ')' then
      begin
        Dec(nParen);
        if nParen = 0 then Break;
      end;
      Inc(k);
    end;
    if k < 5 then
    begin
      zNew := PAnsiChar(sqlite3_realloc64(z, u64(j + (5 - k) + 1)));
      if zNew = nil then
      begin
        sqlite3_free(z);
        Exit(nil);
      end;
      z := zNew;
      Move((z + n + k)^, (z + n + 5)^, j - (n + k));
    end
    else if k > 5 then
      Move((z + n + k)^, (z + n + 5)^, j - (n + k));
    j := j - k + 5;
    z[j] := #0;
    Move(PAnsiChar('?,?,?')^, (z + n)^, 5);
    i := n;
  end;
  Result := z;
end;

{ SQL function `sqlite3_normalize(X)`: returns normalize(X) as TEXT, or
  NULL when X is NULL or normalization fails.  Port-side convenience for
  differential testing — not present in the C source. }
procedure normalizeSqlFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPMem); cdecl;
var
  zIn, zOut: PAnsiChar;
begin
  if sqlite3_value_type(argv[0]) = SQLITE_NULL then
  begin
    sqlite3_result_null(pCtx);
    Exit;
  end;
  zIn := PAnsiChar(sqlite3_value_text(argv[0]));
  if zIn = nil then
  begin
    sqlite3_result_null(pCtx);
    Exit;
  end;
  zOut := sqlite3_normalize(zIn);
  if zOut = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  sqlite3_result_text(pCtx, zOut, -1, SQLITE_TRANSIENT);
  sqlite3_free(zOut);
end;

function sqlite3NormalizeInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_DETERMINISTIC or SQLITE_INNOCUOUS;
begin
  Result := sqlite3_create_function(db, 'sqlite3_normalize', 1, Flags, nil,
                                    @normalizeSqlFunc, nil, nil);
end;

end.
