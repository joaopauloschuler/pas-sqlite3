{
  SPDX-License-Identifier: blessing

  Faithful port of the scalar SQL functions from
  ../sqlite3/ext/misc/spellfix.c (3076 lines in C, of which this unit
  ports lines 38..538, 1243..1830, and 1848..1896 — phoneticHash,
  editdist1, the costing helpers, scriptCode, and the full
  transliterate machinery including the 389-row translit[] table).

  Provides the SQL functions:

    spellfix1_phonehash(X)   — phonetic hash over an ASCII string,
                               omitting double letters, vowels beside
                               R/L, the silent letters T/W/D/K/G in
                               their documented contexts, etc.
    spellfix1_editdist(A, B) — Wagner edit distance with consonant-class
                               costing.  Returns the cost of transforming
                               A into B.  If A ends with '*' it is treated
                               as a prefix.
    spellfix1_scriptcode(X)  — heuristic numeric script identifier
                               (215 Latin / 220 Cyrillic / 200 Greek /
                                125 Hebrew / 160 Arabic / 999 unknown /
                                998 mixed).
    spellfix1_translit(X)    — convert a UTF-8 string with non-ASCII
                               Roman characters into pure ASCII via
                               the upstream translit[] map (covers
                               Latin extended, Cyrillic, Greek, plus
                               selected Latin-extended-additional
                               and ligature points).

  The full spellfix1 virtual table (vocabulary fuzzy-search) and the
  configurable-cost editdist3 family are NOT ported by this unit —
  they require ~1800 additional C lines worth of state-machine code
  (EditDist3* cost-mergesort, the spellfix1_vocab shadow-table CRUD
  path) and will land separately.

  Public entry: sqlite3SpellfixInit(db) — equivalent to the head of
  spellfix1Register() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3spellfix;

interface

uses
  passqlite3types,
  passqlite3internal,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3SpellfixInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os,
  passqlite3printf;

{$POINTERMATH ON}

function strlen(s: PAnsiChar): SizeUInt; cdecl; external 'c' name 'strlen';
function strncmp(a, b: PAnsiChar; n: SizeUInt): i32; cdecl;
  external 'c' name 'strncmp';

{ Character classes — spellfix.c:42..70.  Identical numeric values so
  the const tables below carry over byte-for-byte. }
const
  CCLASS_SILENT = 0;
  CCLASS_VOWEL  = 1;
  CCLASS_B      = 2;
  CCLASS_C      = 3;
  CCLASS_D      = 4;
  CCLASS_H      = 5;
  CCLASS_L      = 6;
  CCLASS_R      = 7;
  CCLASS_M      = 8;
  CCLASS_Y      = 9;
  CCLASS_DIGIT  = 10;
  CCLASS_SPACE  = 11;
  CCLASS_OTHER  = 12;

{ Mapping from character class number to symbol — spellfix.c:176. }
const
  className: array[0..12] of AnsiChar =
    ('.','A','B','C','D','H','L','R','M','Y','9',' ','?');

{ Character class for non-initial ASCII characters — spellfix.c:75..119.
  128 entries, indexed by zIn[i] & $7f. }
const
  midClass: array[0..127] of Byte = (
    { 0x00..0x07 }
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x08..0x0f }
    CCLASS_OTHER, CCLASS_SPACE, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_SPACE, CCLASS_SPACE, CCLASS_OTHER, CCLASS_OTHER,
    { 0x10..0x17 }
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x18..0x1f }
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x20..0x27 ' ' '!' '"' '#' '$' '%' '&' "'" }
    CCLASS_SPACE,  CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER,  CCLASS_OTHER, CCLASS_OTHER, CCLASS_SILENT,
    { 0x28..0x2f '(' ')' '*' '+' ',' '-' '.' '/' }
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x30..0x37 '0'..'7' }
    CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_DIGIT,
    CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_DIGIT,
    { 0x38..0x3f '8' '9' ':' ';' '<' '=' '>' '?' }
    CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x40..0x47 '@' A B C D E F G }
    CCLASS_OTHER, CCLASS_VOWEL, CCLASS_B,     CCLASS_C,
    CCLASS_D,     CCLASS_VOWEL, CCLASS_B,     CCLASS_C,
    { 0x48..0x4f H I J K L M N O }
    CCLASS_SILENT, CCLASS_VOWEL, CCLASS_C, CCLASS_C,
    CCLASS_L,      CCLASS_M,     CCLASS_M, CCLASS_VOWEL,
    { 0x50..0x57 P Q R S T U V W }
    CCLASS_B, CCLASS_C, CCLASS_R, CCLASS_C,
    CCLASS_D, CCLASS_VOWEL, CCLASS_B, CCLASS_B,
    { 0x58..0x5f X Y Z '[' '\' ']' '^' '_' }
    CCLASS_C, CCLASS_VOWEL, CCLASS_C, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x60..0x67 '`' a b c d e f g }
    CCLASS_OTHER, CCLASS_VOWEL, CCLASS_B, CCLASS_C,
    CCLASS_D,     CCLASS_VOWEL, CCLASS_B, CCLASS_C,
    { 0x68..0x6f h i j k l m n o }
    CCLASS_SILENT, CCLASS_VOWEL, CCLASS_C, CCLASS_C,
    CCLASS_L,      CCLASS_M,     CCLASS_M, CCLASS_VOWEL,
    { 0x70..0x77 p q r s t u v w }
    CCLASS_B, CCLASS_C, CCLASS_R, CCLASS_C,
    CCLASS_D, CCLASS_VOWEL, CCLASS_B, CCLASS_B,
    { 0x78..0x7f x y z '{' '|' '}' '~' DEL }
    CCLASS_C, CCLASS_VOWEL, CCLASS_C, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER
  );

{ Character class for the initial character of a word —
  spellfix.c:125..168.  Differs from midClass only at H/W/Y.
  H is SILENT mid-word but has its own class index 5 here?  No — the
  C source still maps H to CCLASS_SILENT in initClass, same as
  midClass; the only documented change is that initClass maps Y to
  CCLASS_Y while midClass maps Y to CCLASS_VOWEL.  W in midClass is
  CCLASS_B; in initClass W is also CCLASS_B (per the source).  Match
  the C table verbatim. }
const
  initClass: array[0..127] of Byte = (
    { 0x00..0x07 }
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x08..0x0f }
    CCLASS_OTHER, CCLASS_SPACE, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_SPACE, CCLASS_SPACE, CCLASS_OTHER, CCLASS_OTHER,
    { 0x10..0x17 }
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x18..0x1f }
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x20..0x27 ' ' '!' '"' '#' '$' '%' '&' "'" }
    CCLASS_SPACE, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x28..0x2f '(' ')' '*' '+' ',' '-' '.' '/' }
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x30..0x37 '0'..'7' }
    CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_DIGIT,
    CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_DIGIT,
    { 0x38..0x3f '8' '9' ':' ';' '<' '=' '>' '?' }
    CCLASS_DIGIT, CCLASS_DIGIT, CCLASS_OTHER, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x40..0x47 '@' A B C D E F G }
    CCLASS_OTHER, CCLASS_VOWEL, CCLASS_B, CCLASS_C,
    CCLASS_D,     CCLASS_VOWEL, CCLASS_B, CCLASS_C,
    { 0x48..0x4f H I J K L M N O }
    CCLASS_SILENT, CCLASS_VOWEL, CCLASS_C, CCLASS_C,
    CCLASS_L,      CCLASS_M,     CCLASS_M, CCLASS_VOWEL,
    { 0x50..0x57 P Q R S T U V W }
    CCLASS_B, CCLASS_C, CCLASS_R, CCLASS_C,
    CCLASS_D, CCLASS_VOWEL, CCLASS_B, CCLASS_B,
    { 0x58..0x5f X Y Z '[' '\' ']' '^' '_' }
    CCLASS_C, CCLASS_Y, CCLASS_C, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER,
    { 0x60..0x67 '`' a b c d e f g }
    CCLASS_OTHER, CCLASS_VOWEL, CCLASS_B, CCLASS_C,
    CCLASS_D,     CCLASS_VOWEL, CCLASS_B, CCLASS_C,
    { 0x68..0x6f h i j k l m n o }
    CCLASS_SILENT, CCLASS_VOWEL, CCLASS_C, CCLASS_C,
    CCLASS_L,      CCLASS_M,     CCLASS_M, CCLASS_VOWEL,
    { 0x70..0x77 p q r s t u v w }
    CCLASS_B, CCLASS_C, CCLASS_R, CCLASS_C,
    CCLASS_D, CCLASS_VOWEL, CCLASS_B, CCLASS_B,
    { 0x78..0x7f x y z '{' '|' '}' '~' DEL }
    CCLASS_C, CCLASS_Y, CCLASS_C, CCLASS_OTHER,
    CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER, CCLASS_OTHER
  );

{ phoneticHash — spellfix.c:194..240.

  Builds a phonetic hash of the ASCII input.  The C source uses
  `aClass = initClass` for the first emitted character and switches to
  `aClass = midClass` after the first non-skipped character.  Output
  buffer length is bounded by nIn + 1; we return a fresh AnsiString.
  Pre-emptive `gn` / `kn` strip at the beginning matches the C arm. }
function phoneticHash(zIn: PAnsiChar; nIn: i32): AnsiString;
var
  zOut: array of Byte;
  i, nOut: i32;
  c: Byte;
  cPrev, cPrevX: Byte;
  pAClass: PByte;
  pIn: PAnsiChar;
begin
  Result := '';
  if (zIn = nil) or (nIn <= 0) then Exit;

  SetLength(zOut, nIn + 1);
  pIn := zIn;
  cPrev  := $77;  { matches C: char cPrev = 0x77 }
  cPrevX := $77;
  pAClass := @initClass[0];

  if nIn > 2 then
  begin
    case pIn[0] of
      'g', 'k':
        if pIn[1] = 'n' then begin Inc(pIn); Dec(nIn); end;
    end;
  end;

  nOut := 0;
  i := 0;
  while i < nIn do
  begin
    c := Byte(pIn[i]);
    if i + 1 < nIn then
    begin
      if (c = Byte('w')) and (pIn[i + 1] = 'r') then
      begin
        Inc(i); Continue;
      end;
      if (c = Byte('d')) and ((pIn[i + 1] = 'j') or (pIn[i + 1] = 'g')) then
      begin
        Inc(i); Continue;
      end;
      if i + 2 < nIn then
      begin
        if (c = Byte('t')) and (pIn[i + 1] = 'c') and (pIn[i + 2] = 'h') then
        begin
          Inc(i); Continue;
        end;
      end;
    end;

    c := pAClass[c and $7f];
    if c = CCLASS_SPACE then begin Inc(i); Continue; end;
    if (c = CCLASS_OTHER) and (cPrev <> CCLASS_DIGIT) then
    begin
      Inc(i); Continue;
    end;
    pAClass := @midClass[0];

    if (c = CCLASS_VOWEL)
       and ((cPrevX = CCLASS_R) or (cPrevX = CCLASS_L)) then
    begin
      Inc(i); Continue;     { No vowels beside L or R }
    end;
    if ((c = CCLASS_R) or (c = CCLASS_L))
       and (cPrevX = CCLASS_VOWEL) then
    begin
      Dec(nOut);            { No vowels beside L or R — pop the vowel }
    end;
    cPrev := c;
    if c = CCLASS_SILENT then begin Inc(i); Continue; end;
    cPrevX := c;
    c := Byte(className[c]);
    AssertH(nOut >= 0, 'phoneticHash nOut');
    if (nOut = 0) or (c <> zOut[nOut - 1]) then
    begin
      zOut[nOut] := c;
      Inc(nOut);
    end;
    Inc(i);
  end;

  if nOut > 0 then
  begin
    SetLength(Result, nOut);
    Move(zOut[0], Result[1], nOut);
  end;
end;

procedure phoneticHashSqlFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPMem); cdecl;
var
  zIn: PAnsiChar;
  s: AnsiString;
begin
  zIn := PAnsiChar(sqlite3_value_text(argv[0]));
  if zIn = nil then Exit;
  s := phoneticHash(zIn, sqlite3_value_bytes(argv[0]));
  if s = '' then
    sqlite3_result_text(pCtx, '', 0, SQLITE_TRANSIENT)
  else
    sqlite3_result_text(pCtx, PAnsiChar(s), Length(s), SQLITE_TRANSIENT);
end;

{ characterClass — spellfix.c:268..270. }
function characterClass(cPrev, c: Byte): Byte; inline;
begin
  if cPrev = 0 then
    Result := initClass[c and $7f]
  else
    Result := midClass[c and $7f];
end;

{ insertOrDeleteCost — spellfix.c:277..305. }
function insertOrDeleteCost(cPrev, c, cNext: Byte): i32;
var
  classC, classCprev: Byte;
begin
  classC := characterClass(cPrev, c);

  if classC = CCLASS_SILENT then begin Result := 1; Exit; end;
  if cPrev = c then begin Result := 10; Exit; end;
  if (classC = CCLASS_VOWEL)
     and ((cPrev = Byte('r')) or (cNext = Byte('r'))) then
  begin
    Result := 20; Exit;
  end;
  classCprev := characterClass(cPrev, cPrev);
  if classC = classCprev then
  begin
    if classC = CCLASS_VOWEL then Result := 15 else Result := 50;
    Exit;
  end;
  Result := 100;
end;

{ Divide insertion cost by this factor when appending to the end of
  the word — spellfix.c:311. }
const
  FINAL_INS_COST_DIV = 4;

{ substituteCost — spellfix.c:318..341. }
function substituteCost(cPrev, cFrom, cTo: Byte): i32;
var
  classFrom, classTo: Byte;
begin
  if cFrom = cTo then begin Result := 0; Exit; end;
  if (cFrom = (cTo xor $20))
     and (((cTo >= Byte('A')) and (cTo <= Byte('Z')))
          or ((cTo >= Byte('a')) and (cTo <= Byte('z')))) then
  begin
    Result := 0; Exit;
  end;
  classFrom := characterClass(cPrev, cFrom);
  classTo   := characterClass(cPrev, cTo);
  if classFrom = classTo then begin Result := 40; Exit; end;
  if (classFrom >= CCLASS_B) and (classFrom <= CCLASS_Y)
     and (classTo >= CCLASS_B) and (classTo <= CCLASS_Y) then
  begin
    Result := 75; Exit;
  end;
  Result := 100;
end;

{ editdist1 — spellfix.c:362..508.

  Returns the cost of transforming zA into zB.  If zA ends with '*' it
  is treated as a prefix of zB; pnMatch (when non-NULL) is set to the
  number of bytes of zB matched.  Negative return codes:
    -1   one of the inputs was NULL
    -2   non-ASCII character in input
    -3   memory allocation failed (we use a heap-array for the matrix
         in the Pascal port; OOM here is signalled by an exception
         from FPC's SetLength so we never actually return -3 — kept
         as a sentinel for API parity). }
function editdist1(zA, zB: PAnsiChar; pnMatch: Pi32): i32;
var
  nA, nB, xA, xB: u32;
  cA, cB: Byte;
  cAprev, cBprev, cAnext, cBnext: Byte;
  d, dc: i32;
  res: i32;
  m: array of i32;
  cx: array of Byte;
  nMatch: i32;
  i: u32;
  insCost, delCost, subCost, totalCost, ncx: i32;
  lastA: Boolean;
begin
  if (zA = nil) or (zB = nil) then begin Result := -1; Exit; end;

  dc := 0;
  nMatch := 0;
  while (zA[0] <> #0) and (zA[0] = zB[0]) do
  begin
    dc := Byte(zA[0]);
    Inc(zA); Inc(zB); Inc(nMatch);
  end;
  if pnMatch <> nil then pnMatch^ := nMatch;
  if (zA[0] = #0) and (zB[0] = #0) then begin Result := 0; Exit; end;

  nA := 0;
  while zA[nA] <> #0 do
  begin
    if (Byte(zA[nA]) and $80) <> 0 then begin Result := -2; Exit; end;
    Inc(nA);
  end;
  nB := 0;
  while zB[nB] <> #0 do
  begin
    if (Byte(zB[nB]) and $80) <> 0 then begin Result := -2; Exit; end;
    Inc(nB);
  end;

  if nA = 0 then
  begin
    cBprev := Byte(dc);
    res := 0; xB := 0;
    while xB < nB do
    begin
      cB := Byte(zB[xB]);
      if xB + 1 < nB then cBnext := Byte(zB[xB + 1]) else cBnext := 0;
      Inc(res, insertOrDeleteCost(cBprev, cB, cBnext) div FINAL_INS_COST_DIV);
      cBprev := cB;
      Inc(xB);
    end;
    Result := res; Exit;
  end;
  if nB = 0 then
  begin
    cAprev := Byte(dc);
    res := 0; xA := 0;
    while xA < nA do
    begin
      cA := Byte(zA[xA]);
      if xA + 1 < nA then cAnext := Byte(zA[xA + 1]) else cAnext := 0;
      Inc(res, insertOrDeleteCost(cAprev, cA, cAnext));
      cAprev := cA;
      Inc(xA);
    end;
    Result := res; Exit;
  end;

  if (zA[0] = '*') and (zA[1] = #0) then begin Result := 0; Exit; end;

  SetLength(m,  nB + 1);
  SetLength(cx, nB + 1);

  m[0]  := 0;
  cx[0] := Byte(dc);
  cBprev := Byte(dc);
  xB := 1;
  while xB <= nB do
  begin
    if xB < nB then cBnext := Byte(zB[xB]) else cBnext := 0;
    cB := Byte(zB[xB - 1]);
    cx[xB] := cB;
    m[xB]  := m[xB - 1] + insertOrDeleteCost(cBprev, cB, cBnext);
    cBprev := cB;
    Inc(xB);
  end;

  cAprev := Byte(dc);
  cA := 0;
  xA := 1;
  while xA <= nA do
  begin
    lastA := (xA = nA);
    cA := Byte(zA[xA - 1]);
    if xA < nA then cAnext := Byte(zA[xA]) else cAnext := 0;
    if (cA = Byte('*')) and lastA then Break;
    d  := m[0];
    dc := cx[0];
    m[0] := d + insertOrDeleteCost(cAprev, cA, cAnext);
    cBprev := 0;
    xB := 1;
    while xB <= nB do
    begin
      cB := Byte(zB[xB - 1]);
      if xB < nB then cBnext := Byte(zB[xB]) else cBnext := 0;

      insCost := insertOrDeleteCost(cx[xB - 1], cB, cBnext);
      if lastA then insCost := insCost div FINAL_INS_COST_DIV;

      delCost := insertOrDeleteCost(cx[xB], cA, cBnext);

      subCost := substituteCost(cx[xB - 1], cA, cB);

      totalCost := insCost + m[xB - 1];
      ncx := cB;
      if (delCost + m[xB]) < totalCost then
      begin
        totalCost := delCost + m[xB];
        ncx := cA;
      end;
      if (subCost + d) < totalCost then
        totalCost := subCost + d;

      d  := m[xB];
      dc := cx[xB];
      m[xB]  := totalCost;
      cx[xB] := Byte(ncx);
      cBprev := cB;
      Inc(xB);
    end;
    cAprev := cA;
    Inc(xA);
  end;

  if cA = Byte('*') then
  begin
    res := m[1];
    i := 1;
    while i <= nB do
    begin
      if m[i] < res then
      begin
        res := m[i];
        if pnMatch <> nil then pnMatch^ := i32(i) + nMatch;
      end;
      Inc(i);
    end;
  end
  else
    res := m[nB];
  Result := res;
end;

procedure editdistSqlFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPMem); cdecl;
var
  res: i32;
begin
  res := editdist1(PAnsiChar(sqlite3_value_text(argv[0])),
                   PAnsiChar(sqlite3_value_text(argv[1])),
                   nil);
  if res < 0 then
  begin
    if res = -3 then
      sqlite3_result_error_nomem(pCtx)
    else if res = -2 then
      sqlite3_result_error(pCtx, 'non-ASCII input to editdist()', -1)
    else
      sqlite3_result_error(pCtx, 'NULL input to editdist()', -1);
  end
  else
    sqlite3_result_int(pCtx, res);
end;

{ Local copy of utf.c's aUtf8Trans1[64] table — kept here so this unit
  doesn't need a back-channel into passqlite3util's implementation
  section.  Values mirror passqlite3util.sqlite3Utf8Trans1. }
const
  spellfixUtf8Trans1: array[0..63] of Byte = (
    $00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$0a,$0b,$0c,$0d,$0e,$0f,
    $10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$1a,$1b,$1c,$1d,$1e,$1f,
    $00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$0a,$0b,$0c,$0d,$0e,$0f,
    $00,$01,$02,$03,$04,$05,$06,$07,$00,$01,$02,$03,$00,$01,$00,$00
  );

{ utf8Read — spellfix.c:1258..1277.  Walk one UTF-8 code point. }
function utf8Read(z: PByte; n: i32; pSize: Pi32): i32;
var
  c, i: i32;
begin
  if n = 0 then
  begin
    c := 0; i := 0;
  end
  else
  begin
    c := z[0];
    i := 1;
    if c >= $c0 then
    begin
      c := spellfixUtf8Trans1[c - $c0];
      while (i < n) and ((z[i] and $c0) = $80) do
      begin
        c := (c shl 6) + ($3f and z[i]);
        Inc(i);
      end;
    end;
  end;
  pSize^ := i;
  Result := c;
end;

{ scriptCodeSqlFunc — spellfix.c:1848..1896.

  Returns 215 (Latin), 220 (Cyrillic), 200 (Greek), 125 (Hebrew),
  160 (Arabic), 999 (no recognised script), or 998 (multi-script). }
const
  SCRIPT_LATIN    = $0001;
  SCRIPT_CYRILLIC = $0002;
  SCRIPT_GREEK    = $0004;
  SCRIPT_HEBREW   = $0008;
  SCRIPT_ARABIC   = $0010;

procedure scriptCodeSqlFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPMem); cdecl;
var
  zIn: PByte;
  nIn, c, sz: i32;
  scriptMask: i32;
  res: i32;
  seenDigit: Boolean;
begin
  zIn := PByte(sqlite3_value_text(argv[0]));
  nIn := sqlite3_value_bytes(argv[0]);
  scriptMask := 0;
  seenDigit  := False;

  while nIn > 0 do
  begin
    c := utf8Read(zIn, nIn, @sz);
    Inc(zIn, sz);
    Dec(nIn, sz);
    if c < $02af then
    begin
      if (c >= $80) or (midClass[c and $7f] < CCLASS_DIGIT) then
        scriptMask := scriptMask or SCRIPT_LATIN
      else if (c >= Ord('0')) and (c <= Ord('9')) then
        seenDigit := True;
    end
    else if (c >= $0400) and (c <= $04ff) then
      scriptMask := scriptMask or SCRIPT_CYRILLIC
    else if (c >= $0386) and (c <= $03ce) then
      scriptMask := scriptMask or SCRIPT_GREEK
    else if (c >= $0590) and (c <= $05ff) then
      scriptMask := scriptMask or SCRIPT_HEBREW
    else if (c >= $0600) and (c <= $06ff) then
      scriptMask := scriptMask or SCRIPT_ARABIC;
  end;

  if (scriptMask = 0) and seenDigit then scriptMask := SCRIPT_LATIN;
  case scriptMask of
    0:               res := 999;
    SCRIPT_LATIN:    res := 215;
    SCRIPT_CYRILLIC: res := 220;
    SCRIPT_GREEK:    res := 200;
    SCRIPT_HEBREW:   res := 125;
    SCRIPT_ARABIC:   res := 160;
  else
    res := 998;
  end;
  sqlite3_result_int(pCtx, res);
end;


{ ===== Transliteration table — spellfix.c:1294..1696. =====

  Provides the spellfix1_translit(X) SQL function and supporting
  utf8Charlen / spellfixFindTranslit / translen_to_charlen helpers.
  Faithful 1:1 port of the C source: the 389-row translit[] table
  is sorted by cFrom so transliterate() can binary-search per code
  point.  SQLITE_SPELLFIX_5BYTE_MAPPINGS is not defined upstream
  by default, so the cTo4 slot is omitted to match the default
  build. }

type
  TTransliteration = packed record
    cFrom: u16;
    cTo0, cTo1, cTo2, cTo3: Byte;
  end;
  PTransliteration = ^TTransliteration;

const
  TRANSLIT_COUNT = 389;
  translit: array[0..TRANSLIT_COUNT-1] of TTransliteration = (
    (cFrom: $00A0; cTo0: $20; cTo1: $00; cTo2: $00; cTo3: $00),  //   to  
    (cFrom: $00B5; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // µ to u
    (cFrom: $00C0; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // À to A
    (cFrom: $00C1; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // Á to A
    (cFrom: $00C2; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // Â to A
    (cFrom: $00C3; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // Ã to A
    (cFrom: $00C4; cTo0: $41; cTo1: $65; cTo2: $00; cTo3: $00),  // Ä to Ae
    (cFrom: $00C5; cTo0: $41; cTo1: $61; cTo2: $00; cTo3: $00),  // Å to Aa
    (cFrom: $00C6; cTo0: $41; cTo1: $45; cTo2: $00; cTo3: $00),  // Æ to AE
    (cFrom: $00C7; cTo0: $43; cTo1: $00; cTo2: $00; cTo3: $00),  // Ç to C
    (cFrom: $00C8; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // È to E
    (cFrom: $00C9; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // É to E
    (cFrom: $00CA; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ê to E
    (cFrom: $00CB; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ë to E
    (cFrom: $00CC; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ì to I
    (cFrom: $00CD; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Í to I
    (cFrom: $00CE; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Î to I
    (cFrom: $00CF; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ï to I
    (cFrom: $00D0; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Ð to D
    (cFrom: $00D1; cTo0: $4E; cTo1: $00; cTo2: $00; cTo3: $00),  // Ñ to N
    (cFrom: $00D2; cTo0: $4F; cTo1: $00; cTo2: $00; cTo3: $00),  // Ò to O
    (cFrom: $00D3; cTo0: $4F; cTo1: $00; cTo2: $00; cTo3: $00),  // Ó to O
    (cFrom: $00D4; cTo0: $4F; cTo1: $00; cTo2: $00; cTo3: $00),  // Ô to O
    (cFrom: $00D5; cTo0: $4F; cTo1: $00; cTo2: $00; cTo3: $00),  // Õ to O
    (cFrom: $00D6; cTo0: $4F; cTo1: $65; cTo2: $00; cTo3: $00),  // Ö to Oe
    (cFrom: $00D7; cTo0: $78; cTo1: $00; cTo2: $00; cTo3: $00),  // × to x
    (cFrom: $00D8; cTo0: $4F; cTo1: $00; cTo2: $00; cTo3: $00),  // Ø to O
    (cFrom: $00D9; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ù to U
    (cFrom: $00DA; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ú to U
    (cFrom: $00DB; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Û to U
    (cFrom: $00DC; cTo0: $55; cTo1: $65; cTo2: $00; cTo3: $00),  // Ü to Ue
    (cFrom: $00DD; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  // Ý to Y
    (cFrom: $00DE; cTo0: $54; cTo1: $68; cTo2: $00; cTo3: $00),  // Þ to Th
    (cFrom: $00DF; cTo0: $73; cTo1: $73; cTo2: $00; cTo3: $00),  // ß to ss
    (cFrom: $00E0; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // à to a
    (cFrom: $00E1; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // á to a
    (cFrom: $00E2; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // â to a
    (cFrom: $00E3; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // ã to a
    (cFrom: $00E4; cTo0: $61; cTo1: $65; cTo2: $00; cTo3: $00),  // ä to ae
    (cFrom: $00E5; cTo0: $61; cTo1: $61; cTo2: $00; cTo3: $00),  // å to aa
    (cFrom: $00E6; cTo0: $61; cTo1: $65; cTo2: $00; cTo3: $00),  // æ to ae
    (cFrom: $00E7; cTo0: $63; cTo1: $00; cTo2: $00; cTo3: $00),  // ç to c
    (cFrom: $00E8; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // è to e
    (cFrom: $00E9; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // é to e
    (cFrom: $00EA; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ê to e
    (cFrom: $00EB; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ë to e
    (cFrom: $00EC; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ì to i
    (cFrom: $00ED; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // í to i
    (cFrom: $00EE; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // î to i
    (cFrom: $00EF; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ï to i
    (cFrom: $00F0; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // ð to d
    (cFrom: $00F1; cTo0: $6E; cTo1: $00; cTo2: $00; cTo3: $00),  // ñ to n
    (cFrom: $00F2; cTo0: $6F; cTo1: $00; cTo2: $00; cTo3: $00),  // ò to o
    (cFrom: $00F3; cTo0: $6F; cTo1: $00; cTo2: $00; cTo3: $00),  // ó to o
    (cFrom: $00F4; cTo0: $6F; cTo1: $00; cTo2: $00; cTo3: $00),  // ô to o
    (cFrom: $00F5; cTo0: $6F; cTo1: $00; cTo2: $00; cTo3: $00),  // õ to o
    (cFrom: $00F6; cTo0: $6F; cTo1: $65; cTo2: $00; cTo3: $00),  // ö to oe
    (cFrom: $00F7; cTo0: $3A; cTo1: $00; cTo2: $00; cTo3: $00),  // ÷ to :
    (cFrom: $00F8; cTo0: $6F; cTo1: $00; cTo2: $00; cTo3: $00),  // ø to o
    (cFrom: $00F9; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ù to u
    (cFrom: $00FA; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ú to u
    (cFrom: $00FB; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // û to u
    (cFrom: $00FC; cTo0: $75; cTo1: $65; cTo2: $00; cTo3: $00),  // ü to ue
    (cFrom: $00FD; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  // ý to y
    (cFrom: $00FE; cTo0: $74; cTo1: $68; cTo2: $00; cTo3: $00),  // þ to th
    (cFrom: $00FF; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  // ÿ to y
    (cFrom: $0100; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // Ā to A
    (cFrom: $0101; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // ā to a
    (cFrom: $0102; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // Ă to A
    (cFrom: $0103; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // ă to a
    (cFrom: $0104; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // Ą to A
    (cFrom: $0105; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // ą to a
    (cFrom: $0106; cTo0: $43; cTo1: $00; cTo2: $00; cTo3: $00),  // Ć to C
    (cFrom: $0107; cTo0: $63; cTo1: $00; cTo2: $00; cTo3: $00),  // ć to c
    (cFrom: $0108; cTo0: $43; cTo1: $68; cTo2: $00; cTo3: $00),  // Ĉ to Ch
    (cFrom: $0109; cTo0: $63; cTo1: $68; cTo2: $00; cTo3: $00),  // ĉ to ch
    (cFrom: $010A; cTo0: $43; cTo1: $00; cTo2: $00; cTo3: $00),  // Ċ to C
    (cFrom: $010B; cTo0: $63; cTo1: $00; cTo2: $00; cTo3: $00),  // ċ to c
    (cFrom: $010C; cTo0: $43; cTo1: $00; cTo2: $00; cTo3: $00),  // Č to C
    (cFrom: $010D; cTo0: $63; cTo1: $00; cTo2: $00; cTo3: $00),  // č to c
    (cFrom: $010E; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Ď to D
    (cFrom: $010F; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // ď to d
    (cFrom: $0110; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Đ to D
    (cFrom: $0111; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // đ to d
    (cFrom: $0112; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ē to E
    (cFrom: $0113; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ē to e
    (cFrom: $0114; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ĕ to E
    (cFrom: $0115; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ĕ to e
    (cFrom: $0116; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ė to E
    (cFrom: $0117; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ė to e
    (cFrom: $0118; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ę to E
    (cFrom: $0119; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ę to e
    (cFrom: $011A; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ě to E
    (cFrom: $011B; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ě to e
    (cFrom: $011C; cTo0: $47; cTo1: $68; cTo2: $00; cTo3: $00),  // Ĝ to Gh
    (cFrom: $011D; cTo0: $67; cTo1: $68; cTo2: $00; cTo3: $00),  // ĝ to gh
    (cFrom: $011E; cTo0: $47; cTo1: $00; cTo2: $00; cTo3: $00),  // Ğ to G
    (cFrom: $011F; cTo0: $67; cTo1: $00; cTo2: $00; cTo3: $00),  // ğ to g
    (cFrom: $0120; cTo0: $47; cTo1: $00; cTo2: $00; cTo3: $00),  // Ġ to G
    (cFrom: $0121; cTo0: $67; cTo1: $00; cTo2: $00; cTo3: $00),  // ġ to g
    (cFrom: $0122; cTo0: $47; cTo1: $00; cTo2: $00; cTo3: $00),  // Ģ to G
    (cFrom: $0123; cTo0: $67; cTo1: $00; cTo2: $00; cTo3: $00),  // ģ to g
    (cFrom: $0124; cTo0: $48; cTo1: $68; cTo2: $00; cTo3: $00),  // Ĥ to Hh
    (cFrom: $0125; cTo0: $68; cTo1: $68; cTo2: $00; cTo3: $00),  // ĥ to hh
    (cFrom: $0126; cTo0: $48; cTo1: $00; cTo2: $00; cTo3: $00),  // Ħ to H
    (cFrom: $0127; cTo0: $68; cTo1: $00; cTo2: $00; cTo3: $00),  // ħ to h
    (cFrom: $0128; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ĩ to I
    (cFrom: $0129; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ĩ to i
    (cFrom: $012A; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ī to I
    (cFrom: $012B; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ī to i
    (cFrom: $012C; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ĭ to I
    (cFrom: $012D; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ĭ to i
    (cFrom: $012E; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Į to I
    (cFrom: $012F; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // į to i
    (cFrom: $0130; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // İ to I
    (cFrom: $0131; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ı to i
    (cFrom: $0132; cTo0: $49; cTo1: $4A; cTo2: $00; cTo3: $00),  // Ĳ to IJ
    (cFrom: $0133; cTo0: $69; cTo1: $6A; cTo2: $00; cTo3: $00),  // ĳ to ij
    (cFrom: $0134; cTo0: $4A; cTo1: $68; cTo2: $00; cTo3: $00),  // Ĵ to Jh
    (cFrom: $0135; cTo0: $6A; cTo1: $68; cTo2: $00; cTo3: $00),  // ĵ to jh
    (cFrom: $0136; cTo0: $4B; cTo1: $00; cTo2: $00; cTo3: $00),  // Ķ to K
    (cFrom: $0137; cTo0: $6B; cTo1: $00; cTo2: $00; cTo3: $00),  // ķ to k
    (cFrom: $0138; cTo0: $6B; cTo1: $00; cTo2: $00; cTo3: $00),  // ĸ to k
    (cFrom: $0139; cTo0: $4C; cTo1: $00; cTo2: $00; cTo3: $00),  // Ĺ to L
    (cFrom: $013A; cTo0: $6C; cTo1: $00; cTo2: $00; cTo3: $00),  // ĺ to l
    (cFrom: $013B; cTo0: $4C; cTo1: $00; cTo2: $00; cTo3: $00),  // Ļ to L
    (cFrom: $013C; cTo0: $6C; cTo1: $00; cTo2: $00; cTo3: $00),  // ļ to l
    (cFrom: $013D; cTo0: $4C; cTo1: $00; cTo2: $00; cTo3: $00),  // Ľ to L
    (cFrom: $013E; cTo0: $6C; cTo1: $00; cTo2: $00; cTo3: $00),  // ľ to l
    (cFrom: $013F; cTo0: $4C; cTo1: $2E; cTo2: $00; cTo3: $00),  // Ŀ to L.
    (cFrom: $0140; cTo0: $6C; cTo1: $2E; cTo2: $00; cTo3: $00),  // ŀ to l.
    (cFrom: $0141; cTo0: $4C; cTo1: $00; cTo2: $00; cTo3: $00),  // Ł to L
    (cFrom: $0142; cTo0: $6C; cTo1: $00; cTo2: $00; cTo3: $00),  // ł to l
    (cFrom: $0143; cTo0: $4E; cTo1: $00; cTo2: $00; cTo3: $00),  // Ń to N
    (cFrom: $0144; cTo0: $6E; cTo1: $00; cTo2: $00; cTo3: $00),  // ń to n
    (cFrom: $0145; cTo0: $4E; cTo1: $00; cTo2: $00; cTo3: $00),  // Ņ to N
    (cFrom: $0146; cTo0: $6E; cTo1: $00; cTo2: $00; cTo3: $00),  // ņ to n
    (cFrom: $0147; cTo0: $4E; cTo1: $00; cTo2: $00; cTo3: $00),  // Ň to N
    (cFrom: $0148; cTo0: $6E; cTo1: $00; cTo2: $00; cTo3: $00),  // ň to n
    (cFrom: $0149; cTo0: $27; cTo1: $6E; cTo2: $00; cTo3: $00),  // ŉ to 'n
    (cFrom: $014A; cTo0: $4E; cTo1: $47; cTo2: $00; cTo3: $00),  // Ŋ to NG
    (cFrom: $014B; cTo0: $6E; cTo1: $67; cTo2: $00; cTo3: $00),  // ŋ to ng
    (cFrom: $014C; cTo0: $4F; cTo1: $00; cTo2: $00; cTo3: $00),  // Ō to O
    (cFrom: $014D; cTo0: $6F; cTo1: $00; cTo2: $00; cTo3: $00),  // ō to o
    (cFrom: $014E; cTo0: $4F; cTo1: $00; cTo2: $00; cTo3: $00),  // Ŏ to O
    (cFrom: $014F; cTo0: $6F; cTo1: $00; cTo2: $00; cTo3: $00),  // ŏ to o
    (cFrom: $0150; cTo0: $4F; cTo1: $00; cTo2: $00; cTo3: $00),  // Ő to O
    (cFrom: $0151; cTo0: $6F; cTo1: $00; cTo2: $00; cTo3: $00),  // ő to o
    (cFrom: $0152; cTo0: $4F; cTo1: $45; cTo2: $00; cTo3: $00),  // Œ to OE
    (cFrom: $0153; cTo0: $6F; cTo1: $65; cTo2: $00; cTo3: $00),  // œ to oe
    (cFrom: $0154; cTo0: $52; cTo1: $00; cTo2: $00; cTo3: $00),  // Ŕ to R
    (cFrom: $0155; cTo0: $72; cTo1: $00; cTo2: $00; cTo3: $00),  // ŕ to r
    (cFrom: $0156; cTo0: $52; cTo1: $00; cTo2: $00; cTo3: $00),  // Ŗ to R
    (cFrom: $0157; cTo0: $72; cTo1: $00; cTo2: $00; cTo3: $00),  // ŗ to r
    (cFrom: $0158; cTo0: $52; cTo1: $00; cTo2: $00; cTo3: $00),  // Ř to R
    (cFrom: $0159; cTo0: $72; cTo1: $00; cTo2: $00; cTo3: $00),  // ř to r
    (cFrom: $015A; cTo0: $53; cTo1: $00; cTo2: $00; cTo3: $00),  // Ś to S
    (cFrom: $015B; cTo0: $73; cTo1: $00; cTo2: $00; cTo3: $00),  // ś to s
    (cFrom: $015C; cTo0: $53; cTo1: $68; cTo2: $00; cTo3: $00),  // Ŝ to Sh
    (cFrom: $015D; cTo0: $73; cTo1: $68; cTo2: $00; cTo3: $00),  // ŝ to sh
    (cFrom: $015E; cTo0: $53; cTo1: $00; cTo2: $00; cTo3: $00),  // Ş to S
    (cFrom: $015F; cTo0: $73; cTo1: $00; cTo2: $00; cTo3: $00),  // ş to s
    (cFrom: $0160; cTo0: $53; cTo1: $00; cTo2: $00; cTo3: $00),  // Š to S
    (cFrom: $0161; cTo0: $73; cTo1: $00; cTo2: $00; cTo3: $00),  // š to s
    (cFrom: $0162; cTo0: $54; cTo1: $00; cTo2: $00; cTo3: $00),  // Ţ to T
    (cFrom: $0163; cTo0: $74; cTo1: $00; cTo2: $00; cTo3: $00),  // ţ to t
    (cFrom: $0164; cTo0: $54; cTo1: $00; cTo2: $00; cTo3: $00),  // Ť to T
    (cFrom: $0165; cTo0: $74; cTo1: $00; cTo2: $00; cTo3: $00),  // ť to t
    (cFrom: $0166; cTo0: $54; cTo1: $00; cTo2: $00; cTo3: $00),  // Ŧ to T
    (cFrom: $0167; cTo0: $74; cTo1: $00; cTo2: $00; cTo3: $00),  // ŧ to t
    (cFrom: $0168; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ũ to U
    (cFrom: $0169; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ũ to u
    (cFrom: $016A; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ū to U
    (cFrom: $016B; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ū to u
    (cFrom: $016C; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ŭ to U
    (cFrom: $016D; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ŭ to u
    (cFrom: $016E; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ů to U
    (cFrom: $016F; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ů to u
    (cFrom: $0170; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ű to U
    (cFrom: $0171; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ű to u
    (cFrom: $0172; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ų to U
    (cFrom: $0173; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ų to u
    (cFrom: $0174; cTo0: $57; cTo1: $00; cTo2: $00; cTo3: $00),  // Ŵ to W
    (cFrom: $0175; cTo0: $77; cTo1: $00; cTo2: $00; cTo3: $00),  // ŵ to w
    (cFrom: $0176; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  // Ŷ to Y
    (cFrom: $0177; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  // ŷ to y
    (cFrom: $0178; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  // Ÿ to Y
    (cFrom: $0179; cTo0: $5A; cTo1: $00; cTo2: $00; cTo3: $00),  // Ź to Z
    (cFrom: $017A; cTo0: $7A; cTo1: $00; cTo2: $00; cTo3: $00),  // ź to z
    (cFrom: $017B; cTo0: $5A; cTo1: $00; cTo2: $00; cTo3: $00),  // Ż to Z
    (cFrom: $017C; cTo0: $7A; cTo1: $00; cTo2: $00; cTo3: $00),  // ż to z
    (cFrom: $017D; cTo0: $5A; cTo1: $00; cTo2: $00; cTo3: $00),  // Ž to Z
    (cFrom: $017E; cTo0: $7A; cTo1: $00; cTo2: $00; cTo3: $00),  // ž to z
    (cFrom: $017F; cTo0: $73; cTo1: $00; cTo2: $00; cTo3: $00),  // ſ to s
    (cFrom: $0192; cTo0: $66; cTo1: $00; cTo2: $00; cTo3: $00),  // ƒ to f
    (cFrom: $0218; cTo0: $53; cTo1: $00; cTo2: $00; cTo3: $00),  // Ș to S
    (cFrom: $0219; cTo0: $73; cTo1: $00; cTo2: $00; cTo3: $00),  // ș to s
    (cFrom: $021A; cTo0: $54; cTo1: $00; cTo2: $00; cTo3: $00),  // Ț to T
    (cFrom: $021B; cTo0: $74; cTo1: $00; cTo2: $00; cTo3: $00),  // ț to t
    (cFrom: $0386; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // Ά to A
    (cFrom: $0388; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Έ to E
    (cFrom: $0389; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ή to I
    (cFrom: $038A; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ί to I
    (cFrom: $038C; cTo0: $4f; cTo1: $00; cTo2: $00; cTo3: $00),  // Ό to O
    (cFrom: $038E; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  // Ύ to Y
    (cFrom: $038F; cTo0: $4f; cTo1: $00; cTo2: $00; cTo3: $00),  // Ώ to O
    (cFrom: $0390; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ΐ to i
    (cFrom: $0391; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // Α to A
    (cFrom: $0392; cTo0: $42; cTo1: $00; cTo2: $00; cTo3: $00),  // Β to B
    (cFrom: $0393; cTo0: $47; cTo1: $00; cTo2: $00; cTo3: $00),  // Γ to G
    (cFrom: $0394; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Δ to D
    (cFrom: $0395; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ε to E
    (cFrom: $0396; cTo0: $5a; cTo1: $00; cTo2: $00; cTo3: $00),  // Ζ to Z
    (cFrom: $0397; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Η to I
    (cFrom: $0398; cTo0: $54; cTo1: $68; cTo2: $00; cTo3: $00),  // Θ to Th
    (cFrom: $0399; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ι to I
    (cFrom: $039A; cTo0: $4b; cTo1: $00; cTo2: $00; cTo3: $00),  // Κ to K
    (cFrom: $039B; cTo0: $4c; cTo1: $00; cTo2: $00; cTo3: $00),  // Λ to L
    (cFrom: $039C; cTo0: $4d; cTo1: $00; cTo2: $00; cTo3: $00),  // Μ to M
    (cFrom: $039D; cTo0: $4e; cTo1: $00; cTo2: $00; cTo3: $00),  // Ν to N
    (cFrom: $039E; cTo0: $58; cTo1: $00; cTo2: $00; cTo3: $00),  // Ξ to X
    (cFrom: $039F; cTo0: $4f; cTo1: $00; cTo2: $00; cTo3: $00),  // Ο to O
    (cFrom: $03A0; cTo0: $50; cTo1: $00; cTo2: $00; cTo3: $00),  // Π to P
    (cFrom: $03A1; cTo0: $52; cTo1: $00; cTo2: $00; cTo3: $00),  // Ρ to R
    (cFrom: $03A3; cTo0: $53; cTo1: $00; cTo2: $00; cTo3: $00),  // Σ to S
    (cFrom: $03A4; cTo0: $54; cTo1: $00; cTo2: $00; cTo3: $00),  // Τ to T
    (cFrom: $03A5; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  // Υ to Y
    (cFrom: $03A6; cTo0: $46; cTo1: $00; cTo2: $00; cTo3: $00),  // Φ to F
    (cFrom: $03A7; cTo0: $43; cTo1: $68; cTo2: $00; cTo3: $00),  // Χ to Ch
    (cFrom: $03A8; cTo0: $50; cTo1: $73; cTo2: $00; cTo3: $00),  // Ψ to Ps
    (cFrom: $03A9; cTo0: $4f; cTo1: $00; cTo2: $00; cTo3: $00),  // Ω to O
    (cFrom: $03AA; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ϊ to I
    (cFrom: $03AB; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  // Ϋ to Y
    (cFrom: $03AC; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // ά to a
    (cFrom: $03AD; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // έ to e
    (cFrom: $03AE; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ή to i
    (cFrom: $03AF; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ί to i
    (cFrom: $03B1; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // α to a
    (cFrom: $03B2; cTo0: $62; cTo1: $00; cTo2: $00; cTo3: $00),  // β to b
    (cFrom: $03B3; cTo0: $67; cTo1: $00; cTo2: $00; cTo3: $00),  // γ to g
    (cFrom: $03B4; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // δ to d
    (cFrom: $03B5; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ε to e
    (cFrom: $03B6; cTo0: $7a; cTo1: $00; cTo2: $00; cTo3: $00),  // ζ to z
    (cFrom: $03B7; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // η to i
    (cFrom: $03B8; cTo0: $74; cTo1: $68; cTo2: $00; cTo3: $00),  // θ to th
    (cFrom: $03B9; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ι to i
    (cFrom: $03BA; cTo0: $6b; cTo1: $00; cTo2: $00; cTo3: $00),  // κ to k
    (cFrom: $03BB; cTo0: $6c; cTo1: $00; cTo2: $00; cTo3: $00),  // λ to l
    (cFrom: $03BC; cTo0: $6d; cTo1: $00; cTo2: $00; cTo3: $00),  // μ to m
    (cFrom: $03BD; cTo0: $6e; cTo1: $00; cTo2: $00; cTo3: $00),  // ν to n
    (cFrom: $03BE; cTo0: $78; cTo1: $00; cTo2: $00; cTo3: $00),  // ξ to x
    (cFrom: $03BF; cTo0: $6f; cTo1: $00; cTo2: $00; cTo3: $00),  // ο to o
    (cFrom: $03C0; cTo0: $70; cTo1: $00; cTo2: $00; cTo3: $00),  // π to p
    (cFrom: $03C1; cTo0: $72; cTo1: $00; cTo2: $00; cTo3: $00),  // ρ to r
    (cFrom: $03C3; cTo0: $73; cTo1: $00; cTo2: $00; cTo3: $00),  // σ to s
    (cFrom: $03C4; cTo0: $74; cTo1: $00; cTo2: $00; cTo3: $00),  // τ to t
    (cFrom: $03C5; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  // υ to y
    (cFrom: $03C6; cTo0: $66; cTo1: $00; cTo2: $00; cTo3: $00),  // φ to f
    (cFrom: $03C7; cTo0: $63; cTo1: $68; cTo2: $00; cTo3: $00),  // χ to ch
    (cFrom: $03C8; cTo0: $70; cTo1: $73; cTo2: $00; cTo3: $00),  // ψ to ps
    (cFrom: $03C9; cTo0: $6f; cTo1: $00; cTo2: $00; cTo3: $00),  // ω to o
    (cFrom: $03CA; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ϊ to i
    (cFrom: $03CB; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  // ϋ to y
    (cFrom: $03CC; cTo0: $6f; cTo1: $00; cTo2: $00; cTo3: $00),  // ό to o
    (cFrom: $03CD; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  // ύ to y
    (cFrom: $03CE; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ώ to i
    (cFrom: $0400; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ѐ to E
    (cFrom: $0401; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Ё to E
    (cFrom: $0402; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Ђ to D
    (cFrom: $0403; cTo0: $47; cTo1: $00; cTo2: $00; cTo3: $00),  // Ѓ to G
    (cFrom: $0404; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Є to E
    (cFrom: $0405; cTo0: $5a; cTo1: $00; cTo2: $00; cTo3: $00),  // Ѕ to Z
    (cFrom: $0406; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // І to I
    (cFrom: $0407; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ї to I
    (cFrom: $0408; cTo0: $4a; cTo1: $00; cTo2: $00; cTo3: $00),  // Ј to J
    (cFrom: $0409; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Љ to I
    (cFrom: $040A; cTo0: $4e; cTo1: $00; cTo2: $00; cTo3: $00),  // Њ to N
    (cFrom: $040B; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Ћ to D
    (cFrom: $040C; cTo0: $4b; cTo1: $00; cTo2: $00; cTo3: $00),  // Ќ to K
    (cFrom: $040D; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Ѝ to I
    (cFrom: $040E; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // Ў to U
    (cFrom: $040F; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Џ to D
    (cFrom: $0410; cTo0: $41; cTo1: $00; cTo2: $00; cTo3: $00),  // А to A
    (cFrom: $0411; cTo0: $42; cTo1: $00; cTo2: $00; cTo3: $00),  // Б to B
    (cFrom: $0412; cTo0: $56; cTo1: $00; cTo2: $00; cTo3: $00),  // В to V
    (cFrom: $0413; cTo0: $47; cTo1: $00; cTo2: $00; cTo3: $00),  // Г to G
    (cFrom: $0414; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Д to D
    (cFrom: $0415; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Е to E
    (cFrom: $0416; cTo0: $5a; cTo1: $68; cTo2: $00; cTo3: $00),  // Ж to Zh
    (cFrom: $0417; cTo0: $5a; cTo1: $00; cTo2: $00; cTo3: $00),  // З to Z
    (cFrom: $0418; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // И to I
    (cFrom: $0419; cTo0: $49; cTo1: $00; cTo2: $00; cTo3: $00),  // Й to I
    (cFrom: $041A; cTo0: $4b; cTo1: $00; cTo2: $00; cTo3: $00),  // К to K
    (cFrom: $041B; cTo0: $4c; cTo1: $00; cTo2: $00; cTo3: $00),  // Л to L
    (cFrom: $041C; cTo0: $4d; cTo1: $00; cTo2: $00; cTo3: $00),  // М to M
    (cFrom: $041D; cTo0: $4e; cTo1: $00; cTo2: $00; cTo3: $00),  // Н to N
    (cFrom: $041E; cTo0: $4f; cTo1: $00; cTo2: $00; cTo3: $00),  // О to O
    (cFrom: $041F; cTo0: $50; cTo1: $00; cTo2: $00; cTo3: $00),  // П to P
    (cFrom: $0420; cTo0: $52; cTo1: $00; cTo2: $00; cTo3: $00),  // Р to R
    (cFrom: $0421; cTo0: $53; cTo1: $00; cTo2: $00; cTo3: $00),  // С to S
    (cFrom: $0422; cTo0: $54; cTo1: $00; cTo2: $00; cTo3: $00),  // Т to T
    (cFrom: $0423; cTo0: $55; cTo1: $00; cTo2: $00; cTo3: $00),  // У to U
    (cFrom: $0424; cTo0: $46; cTo1: $00; cTo2: $00; cTo3: $00),  // Ф to F
    (cFrom: $0425; cTo0: $4b; cTo1: $68; cTo2: $00; cTo3: $00),  // Х to Kh
    (cFrom: $0426; cTo0: $54; cTo1: $63; cTo2: $00; cTo3: $00),  // Ц to Tc
    (cFrom: $0427; cTo0: $43; cTo1: $68; cTo2: $00; cTo3: $00),  // Ч to Ch
    (cFrom: $0428; cTo0: $53; cTo1: $68; cTo2: $00; cTo3: $00),  // Ш to Sh
    (cFrom: $0429; cTo0: $53; cTo1: $68; cTo2: $63; cTo3: $68),  // Щ to Shch
    (cFrom: $042A; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  //  to A
    (cFrom: $042B; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  // Ы to Y
    (cFrom: $042C; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  //  to Y
    (cFrom: $042D; cTo0: $45; cTo1: $00; cTo2: $00; cTo3: $00),  // Э to E
    (cFrom: $042E; cTo0: $49; cTo1: $75; cTo2: $00; cTo3: $00),  // Ю to Iu
    (cFrom: $042F; cTo0: $49; cTo1: $61; cTo2: $00; cTo3: $00),  // Я to Ia
    (cFrom: $0430; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  // а to a
    (cFrom: $0431; cTo0: $62; cTo1: $00; cTo2: $00; cTo3: $00),  // б to b
    (cFrom: $0432; cTo0: $76; cTo1: $00; cTo2: $00; cTo3: $00),  // в to v
    (cFrom: $0433; cTo0: $67; cTo1: $00; cTo2: $00; cTo3: $00),  // г to g
    (cFrom: $0434; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // д to d
    (cFrom: $0435; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // е to e
    (cFrom: $0436; cTo0: $7a; cTo1: $68; cTo2: $00; cTo3: $00),  // ж to zh
    (cFrom: $0437; cTo0: $7a; cTo1: $00; cTo2: $00; cTo3: $00),  // з to z
    (cFrom: $0438; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // и to i
    (cFrom: $0439; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // й to i
    (cFrom: $043A; cTo0: $6b; cTo1: $00; cTo2: $00; cTo3: $00),  // к to k
    (cFrom: $043B; cTo0: $6c; cTo1: $00; cTo2: $00; cTo3: $00),  // л to l
    (cFrom: $043C; cTo0: $6d; cTo1: $00; cTo2: $00; cTo3: $00),  // м to m
    (cFrom: $043D; cTo0: $6e; cTo1: $00; cTo2: $00; cTo3: $00),  // н to n
    (cFrom: $043E; cTo0: $6f; cTo1: $00; cTo2: $00; cTo3: $00),  // о to o
    (cFrom: $043F; cTo0: $70; cTo1: $00; cTo2: $00; cTo3: $00),  // п to p
    (cFrom: $0440; cTo0: $72; cTo1: $00; cTo2: $00; cTo3: $00),  // р to r
    (cFrom: $0441; cTo0: $73; cTo1: $00; cTo2: $00; cTo3: $00),  // с to s
    (cFrom: $0442; cTo0: $74; cTo1: $00; cTo2: $00; cTo3: $00),  // т to t
    (cFrom: $0443; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // у to u
    (cFrom: $0444; cTo0: $66; cTo1: $00; cTo2: $00; cTo3: $00),  // ф to f
    (cFrom: $0445; cTo0: $6b; cTo1: $68; cTo2: $00; cTo3: $00),  // х to kh
    (cFrom: $0446; cTo0: $74; cTo1: $63; cTo2: $00; cTo3: $00),  // ц to tc
    (cFrom: $0447; cTo0: $63; cTo1: $68; cTo2: $00; cTo3: $00),  // ч to ch
    (cFrom: $0448; cTo0: $73; cTo1: $68; cTo2: $00; cTo3: $00),  // ш to sh
    (cFrom: $0449; cTo0: $73; cTo1: $68; cTo2: $63; cTo3: $68),  // щ to shch
    (cFrom: $044A; cTo0: $61; cTo1: $00; cTo2: $00; cTo3: $00),  //  to a
    (cFrom: $044B; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  // ы to y
    (cFrom: $044C; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  //  to y
    (cFrom: $044D; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // э to e
    (cFrom: $044E; cTo0: $69; cTo1: $75; cTo2: $00; cTo3: $00),  // ю to iu
    (cFrom: $044F; cTo0: $69; cTo1: $61; cTo2: $00; cTo3: $00),  // я to ia
    (cFrom: $0450; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ѐ to e
    (cFrom: $0451; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // ё to e
    (cFrom: $0452; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // ђ to d
    (cFrom: $0453; cTo0: $67; cTo1: $00; cTo2: $00; cTo3: $00),  // ѓ to g
    (cFrom: $0454; cTo0: $65; cTo1: $00; cTo2: $00; cTo3: $00),  // є to e
    (cFrom: $0455; cTo0: $7a; cTo1: $00; cTo2: $00; cTo3: $00),  // ѕ to z
    (cFrom: $0456; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // і to i
    (cFrom: $0457; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ї to i
    (cFrom: $0458; cTo0: $6a; cTo1: $00; cTo2: $00; cTo3: $00),  // ј to j
    (cFrom: $0459; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // љ to i
    (cFrom: $045A; cTo0: $6e; cTo1: $00; cTo2: $00; cTo3: $00),  // њ to n
    (cFrom: $045B; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // ћ to d
    (cFrom: $045C; cTo0: $6b; cTo1: $00; cTo2: $00; cTo3: $00),  // ќ to k
    (cFrom: $045D; cTo0: $69; cTo1: $00; cTo2: $00; cTo3: $00),  // ѝ to i
    (cFrom: $045E; cTo0: $75; cTo1: $00; cTo2: $00; cTo3: $00),  // ў to u
    (cFrom: $045F; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // џ to d
    (cFrom: $1E02; cTo0: $42; cTo1: $00; cTo2: $00; cTo3: $00),  // Ḃ to B
    (cFrom: $1E03; cTo0: $62; cTo1: $00; cTo2: $00; cTo3: $00),  // ḃ to b
    (cFrom: $1E0A; cTo0: $44; cTo1: $00; cTo2: $00; cTo3: $00),  // Ḋ to D
    (cFrom: $1E0B; cTo0: $64; cTo1: $00; cTo2: $00; cTo3: $00),  // ḋ to d
    (cFrom: $1E1E; cTo0: $46; cTo1: $00; cTo2: $00; cTo3: $00),  // Ḟ to F
    (cFrom: $1E1F; cTo0: $66; cTo1: $00; cTo2: $00; cTo3: $00),  // ḟ to f
    (cFrom: $1E40; cTo0: $4D; cTo1: $00; cTo2: $00; cTo3: $00),  // Ṁ to M
    (cFrom: $1E41; cTo0: $6D; cTo1: $00; cTo2: $00; cTo3: $00),  // ṁ to m
    (cFrom: $1E56; cTo0: $50; cTo1: $00; cTo2: $00; cTo3: $00),  // Ṗ to P
    (cFrom: $1E57; cTo0: $70; cTo1: $00; cTo2: $00; cTo3: $00),  // ṗ to p
    (cFrom: $1E60; cTo0: $53; cTo1: $00; cTo2: $00; cTo3: $00),  // Ṡ to S
    (cFrom: $1E61; cTo0: $73; cTo1: $00; cTo2: $00; cTo3: $00),  // ṡ to s
    (cFrom: $1E6A; cTo0: $54; cTo1: $00; cTo2: $00; cTo3: $00),  // Ṫ to T
    (cFrom: $1E6B; cTo0: $74; cTo1: $00; cTo2: $00; cTo3: $00),  // ṫ to t
    (cFrom: $1E80; cTo0: $57; cTo1: $00; cTo2: $00; cTo3: $00),  // Ẁ to W
    (cFrom: $1E81; cTo0: $77; cTo1: $00; cTo2: $00; cTo3: $00),  // ẁ to w
    (cFrom: $1E82; cTo0: $57; cTo1: $00; cTo2: $00; cTo3: $00),  // Ẃ to W
    (cFrom: $1E83; cTo0: $77; cTo1: $00; cTo2: $00; cTo3: $00),  // ẃ to w
    (cFrom: $1E84; cTo0: $57; cTo1: $00; cTo2: $00; cTo3: $00),  // Ẅ to W
    (cFrom: $1E85; cTo0: $77; cTo1: $00; cTo2: $00; cTo3: $00),  // ẅ to w
    (cFrom: $1EF2; cTo0: $59; cTo1: $00; cTo2: $00; cTo3: $00),  // Ỳ to Y
    (cFrom: $1EF3; cTo0: $79; cTo1: $00; cTo2: $00; cTo3: $00),  // ỳ to y
    (cFrom: $FB00; cTo0: $66; cTo1: $66; cTo2: $00; cTo3: $00),  // ﬀ to ff
    (cFrom: $FB01; cTo0: $66; cTo1: $69; cTo2: $00; cTo3: $00),  // ﬁ to fi
    (cFrom: $FB02; cTo0: $66; cTo1: $6C; cTo2: $00; cTo3: $00),  // ﬂ to fl
    (cFrom: $FB05; cTo0: $73; cTo1: $74; cTo2: $00; cTo3: $00),  // ﬅ to st
    (cFrom: $FB06; cTo0: $73; cTo1: $74; cTo2: $00; cTo3: $00)   // ﬆ to st
  );

{ utf8Charlen — spellfix.c:1283..1292. }
function utf8Charlen(zIn: PAnsiChar; nIn: i32): i32;
var
  i, sz, nChar: i32;
begin
  i := 0;
  nChar := 0;
  while i < nIn do
  begin
    utf8Read(PByte(zIn) + i, nIn - i, @sz);
    Inc(i, sz);
    Inc(nChar);
  end;
  Result := nChar;
end;

{ spellfixFindTranslit — spellfix.c:1698..1701.  Upstream simply
  returns the full table; xTop receives the last index.  Kept as
  a function (rather than inlined) so any future range-narrowing
  optimisation can hook here. }
function spellfixFindTranslit(c: i32; out xTop: i32): PTransliteration;
begin
  xTop := TRANSLIT_COUNT - 1;
  Result := @translit[0];
end;

{ transliterate — spellfix.c:1713..1763.  Walks UTF-8 input one
  code point at a time, copies ASCII straight through, binary-
  searches the translit[] table for non-ASCII matches, emits '?'
  for unmappable code points.  Result is a sqlite3_malloc-backed
  NUL-terminated byte buffer; caller releases via sqlite3_free. }
function transliterate(zIn: PByte; nIn: i32): PByte;
var
  zOut: PByte;
  c, sz, nOut, xTop, xBtm, x: i32;
  tbl: PTransliteration;
  e: PTransliteration;
begin
  zOut := PByte(sqlite3_malloc64(u64(nIn) * 4 + 1));
  if zOut = nil then begin Result := nil; Exit; end;
  nOut := 0;
  while nIn > 0 do
  begin
    c := utf8Read(zIn, nIn, @sz);
    Inc(zIn, sz);
    Dec(nIn, sz);
    if c <= 127 then
    begin
      zOut[nOut] := Byte(c);
      Inc(nOut);
    end
    else
    begin
      tbl := spellfixFindTranslit(c, xTop);
      xBtm := 0;
      while xTop >= xBtm do
      begin
        x := (xTop + xBtm) div 2;
        e := tbl + x;
        if i32(e^.cFrom) = c then
        begin
          zOut[nOut] := e^.cTo0; Inc(nOut);
          if e^.cTo1 <> 0 then
          begin
            zOut[nOut] := e^.cTo1; Inc(nOut);
            if e^.cTo2 <> 0 then
            begin
              zOut[nOut] := e^.cTo2; Inc(nOut);
              if e^.cTo3 <> 0 then
              begin
                zOut[nOut] := e^.cTo3; Inc(nOut);
              end;
            end;
          end;
          c := 0;
          Break;
        end
        else if i32(e^.cFrom) > c then
          xTop := x - 1
        else
          xBtm := x + 1;
      end;
      if c <> 0 then
      begin
        zOut[nOut] := Byte(Ord('?'));
        Inc(nOut);
      end;
    end;
  end;
  zOut[nOut] := 0;
  Result := zOut;
end;

{ translen_to_charlen — spellfix.c:1771..1808.  Returns the number
  of characters in the shortest input prefix that transliterates to
  at least nTrans output bytes.  Used by the spellfix1 vtab when
  truncating row matches to fixed-width output. }
function translen_to_charlen(zIn: PAnsiChar; nIn, nTrans: i32): i32;
var
  i, c, sz, nOut, nChar, xTop, xBtm, x: i32;
  tbl: PTransliteration;
  e: PTransliteration;
begin
  i := 0;
  nOut := 0;
  nChar := 0;
  while (i < nIn) and (nOut < nTrans) do
  begin
    c := utf8Read(PByte(zIn) + i, nIn - i, @sz);
    Inc(i, sz);
    Inc(nOut);
    if c >= 128 then
    begin
      tbl := spellfixFindTranslit(c, xTop);
      xBtm := 0;
      while xTop >= xBtm do
      begin
        x := (xTop + xBtm) div 2;
        e := tbl + x;
        if i32(e^.cFrom) = c then
        begin
          if e^.cTo1 <> 0 then
          begin
            Inc(nOut);
            if e^.cTo2 <> 0 then
            begin
              Inc(nOut);
              if e^.cTo3 <> 0 then Inc(nOut);
            end;
          end;
          Break;
        end
        else if i32(e^.cFrom) > c then
          xTop := x - 1
        else
          xBtm := x + 1;
      end;
    end;
    Inc(nChar);
  end;
  Result := nChar;
end;

{ cdecl trampoline so the destructor pointer matches TxDelProc.
  Cannot reference @sqlite3_free directly because FPC propagates the
  external 'c' calling convention as register through `@`. }
procedure translitFreeDel(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

{ transliterateSqlFunc — spellfix.c:1817..1830.

    spellfix1_translit(X)

  Convert a UTF-8 string with non-ASCII Roman characters into pure
  ASCII via the translit[] map. }
procedure transliterateSqlFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPMem); cdecl;
var
  zIn: PByte;
  nIn: i32;
  zOut: PByte;
begin
  zIn := PByte(sqlite3_value_text(argv[0]));
  nIn := sqlite3_value_bytes(argv[0]);
  zOut := transliterate(zIn, nIn);
  if zOut = nil then
    sqlite3_result_error_nomem(pCtx)
  else
    sqlite3_result_text(pCtx, PAnsiChar(zOut), -1, @translitFreeDel);
end;

{ ===========================================================================
  Configurable-cost unicode edit distance (spellfix.c:540..1231).

  Provides the SQL function `editdist3()` with three forms:

    editdist3(zTable)         loads the cost table from `zTable`
                              (columns: iLang, cFrom, cTo, iCost)
    editdist3(A, B)           computes cost(A → B) using language 0
                              defaults (or table loaded earlier)
    editdist3(A, B, iLang)    computes cost(A → B) for language iLang

  All three registrations share the same EditDist3Config* user-data;
  the 1-arg registration owns the destroy callback so the config is
  freed on connection close.  Costs >= 10000 are treated as infinite
  per the upstream comment.  The translit() helper above is unrelated
  to this family — it carries its own fixed table.
  =========================================================================== }

type
  PEditDist3Cost       = ^TEditDist3Cost;
  PEditDist3Config     = ^TEditDist3Config;
  PEditDist3Lang       = ^TEditDist3Lang;
  PEditDist3FromString = ^TEditDist3FromString;
  PEditDist3From       = ^TEditDist3From;
  PEditDist3To         = ^TEditDist3To;

  PPEditDist3Cost = ^PEditDist3Cost;

  TEditDist3Cost = record
    pNext:  PEditDist3Cost;
    nFrom:  Byte;
    nTo:    Byte;
    iCost:  Word;
    a:      array[0..3] of AnsiChar; { FROM bytes followed by TO bytes,
                                       extended via sqlite3_malloc64 tail }
  end;

  TEditDist3Lang = record
    iLang:    i32;
    iInsCost: i32;
    iDelCost: i32;
    iSubCost: i32;
    pCost:    PEditDist3Cost;
  end;

  TEditDist3From = record
    nSubst:  i32;
    nDel:    i32;
    nByte:   i32;
    apSubst: PPEditDist3Cost;
    apDel:   PPEditDist3Cost;
  end;

  TEditDist3FromString = record
    z:        PAnsiChar;
    n:        i32;
    isPrefix: i32;
    a:        PEditDist3From;
  end;

  TEditDist3To = record
    nIns:   i32;
    nByte:  i32;
    apIns:  PPEditDist3Cost;
  end;

  TEditDist3Config = record
    nLang: i32;
    a:     PEditDist3Lang;
  end;

const
  editDist3LangDflt: TEditDist3Lang = (iLang: 0; iInsCost: 100;
                                       iDelCost: 100; iSubCost: 150;
                                       pCost: nil);

procedure editDist3ConfigClear(p: PEditDist3Config);
var
  i: i32;
  pCost, pNxt: PEditDist3Cost;
  pLang: PEditDist3Lang;
begin
  if p = nil then Exit;
  for i := 0 to p^.nLang - 1 do
  begin
    pLang := PEditDist3Lang(PtrUInt(p^.a) + PtrUInt(i)*SizeOf(TEditDist3Lang));
    pCost := pLang^.pCost;
    while pCost <> nil do
    begin
      pNxt := pCost^.pNext;
      sqlite3_free(pCost);
      pCost := pNxt;
    end;
  end;
  sqlite3_free(p^.a);
  FillChar(p^, SizeOf(p^), 0);
end;

procedure editDist3ConfigDelete(pIn: Pointer); cdecl;
begin
  editDist3ConfigClear(PEditDist3Config(pIn));
  sqlite3_free(pIn);
end;

function editDist3CostCompare(pA, pB: PEditDist3Cost): i32;
var n, rc: i32;
begin
  n := pA^.nFrom;
  if n > pB^.nFrom then n := pB^.nFrom;
  rc := 0;
  if n > 0 then
    rc := i32(strncmp(@pA^.a[0], @pB^.a[0], n));
  if rc = 0 then rc := i32(pA^.nFrom) - i32(pB^.nFrom);
  Result := rc;
end;

function editDist3CostMerge(pA, pB: PEditDist3Cost): PEditDist3Cost;
var
  pHead, p: PEditDist3Cost;
  ppTail: PPEditDist3Cost;
begin
  pHead := nil;
  ppTail := @pHead;
  while (pA <> nil) and (pB <> nil) do
  begin
    if editDist3CostCompare(pA, pB) <= 0 then
    begin
      p := pA;
      pA := pA^.pNext;
    end
    else
    begin
      p := pB;
      pB := pB^.pNext;
    end;
    ppTail^ := p;
    ppTail := @p^.pNext;
  end;
  if pA <> nil then ppTail^ := pA else ppTail^ := pB;
  Result := pHead;
end;

function editDist3CostSort(pList: PEditDist3Cost): PEditDist3Cost;
var
  ap: array[0..59] of PEditDist3Cost;
  p: PEditDist3Cost;
  i, mx: i32;
begin
  FillChar(ap, SizeOf(ap), 0);
  mx := 0;
  while pList <> nil do
  begin
    p := pList;
    pList := p^.pNext;
    p^.pNext := nil;
    i := 0;
    while ap[i] <> nil do
    begin
      p := editDist3CostMerge(ap[i], p);
      ap[i] := nil;
      Inc(i);
    end;
    ap[i] := p;
    if i > mx then mx := i;
  end;
  p := nil;
  for i := 0 to mx do
    if ap[i] <> nil then p := editDist3CostMerge(p, ap[i]);
  Result := p;
end;

function editDist3ConfigLoad(p: PEditDist3Config; db: PTsqlite3;
                             zTable: PAnsiChar): i32;
var
  pStmt: Pointer;
  rc, rc2: i32;
  zSql: PAnsiChar;
  iLangPrev: i32;
  pLang: PEditDist3Lang;
  iLang, nFrom, nTo, iCost, nExtra, iLangIdx: i32;
  zFrom, zTo: PAnsiChar;
  pNew: Pointer;
  pCost: PEditDist3Cost;
begin
  iLangPrev := -9999;
  pLang := nil;
  zSql := sqlite3PfMprintf(
            'SELECT iLang, cFrom, cTo, iCost FROM "%w"' +
            ' WHERE iLang>=0 ORDER BY iLang', [zTable]);
  if zSql = nil then Exit(SQLITE_NOMEM);
  pStmt := nil;
  rc := sqlite3_prepare(db, zSql, -1, @pStmt, nil);
  sqlite3_free(zSql);
  if rc <> SQLITE_OK then Exit(rc);
  editDist3ConfigClear(p);
  while sqlite3_step(PVdbe(pStmt)) = SQLITE_ROW do
  begin
    iLang := sqlite3_column_int(PVdbe(pStmt), 0);
    zFrom := PAnsiChar(sqlite3_column_text(PVdbe(pStmt), 1));
    if zFrom <> nil then
      nFrom := sqlite3_column_bytes(PVdbe(pStmt), 1)
    else
      nFrom := 0;
    zTo := PAnsiChar(sqlite3_column_text(PVdbe(pStmt), 2));
    if zTo <> nil then
      nTo := sqlite3_column_bytes(PVdbe(pStmt), 2)
    else
      nTo := 0;
    iCost := sqlite3_column_int(PVdbe(pStmt), 3);

    if (nFrom > 100) or (nTo > 100) then continue;
    if iCost < 0 then continue;
    if iCost >= 10000 then continue;

    if (pLang = nil) or (iLang <> iLangPrev) then
    begin
      pNew := sqlite3_realloc64(p^.a,
                u64(p^.nLang + 1) * SizeOf(TEditDist3Lang));
      if pNew = nil then begin rc := SQLITE_NOMEM; Break; end;
      p^.a := PEditDist3Lang(pNew);
      pLang := PEditDist3Lang(PtrUInt(p^.a)
                + PtrUInt(p^.nLang)*SizeOf(TEditDist3Lang));
      Inc(p^.nLang);
      pLang^.iLang := iLang;
      pLang^.iInsCost := 100;
      pLang^.iDelCost := 100;
      pLang^.iSubCost := 150;
      pLang^.pCost := nil;
      iLangPrev := iLang;
    end;

    if (nFrom = 1) and (zFrom[0] = '?') and (nTo = 0) then
      pLang^.iDelCost := iCost
    else if (nFrom = 0) and (nTo = 1) and (zTo[0] = '?') then
      pLang^.iInsCost := iCost
    else if (nFrom = 1) and (nTo = 1) and (zFrom[0] = '?')
            and (zTo[0] = '?') then
      pLang^.iSubCost := iCost
    else
    begin
      nExtra := nFrom + nTo - 4;
      if nExtra < 0 then nExtra := 0;
      pCost := PEditDist3Cost(sqlite3_malloc64(
                 u64(SizeOf(TEditDist3Cost) + nExtra)));
      if pCost = nil then begin rc := SQLITE_NOMEM; Break; end;
      pCost^.nFrom := Byte(nFrom);
      pCost^.nTo := Byte(nTo);
      pCost^.iCost := Word(iCost);
      if nFrom > 0 then Move(zFrom^, pCost^.a[0], nFrom);
      if nTo > 0 then Move(zTo^, pCost^.a[nFrom], nTo);
      pCost^.pNext := pLang^.pCost;
      pLang^.pCost := pCost;
    end;
  end;
  rc2 := sqlite3_finalize(PVdbe(pStmt));
  if rc = SQLITE_OK then rc := rc2;
  if rc = SQLITE_OK then
  begin
    for iLangIdx := 0 to p^.nLang - 1 do
    begin
      pLang := PEditDist3Lang(PtrUInt(p^.a)
               + PtrUInt(iLangIdx)*SizeOf(TEditDist3Lang));
      pLang^.pCost := editDist3CostSort(pLang^.pCost);
    end;
  end;
  Result := rc;
end;

function utf8Len(c: Byte; N: i32): i32;
var len: i32;
begin
  len := 1;
  if c > $7f then
  begin
    if (c and $e0) = $c0 then
      len := 2
    else if (c and $f0) = $e0 then
      len := 3
    else
      len := 4;
  end;
  if len > N then len := N;
  Result := len;
end;

function ed3MatchTo(p: PEditDist3Cost; z: PAnsiChar; n: i32): i32;
begin
  Assert(n > 0);
  if p^.a[p^.nFrom] <> z[0] then Exit(0);
  if p^.nTo > n then Exit(0);
  if strncmp(@p^.a[p^.nFrom], z, p^.nTo) <> 0 then Exit(0);
  Result := 1;
end;

function ed3MatchFrom(p: PEditDist3Cost; z: PAnsiChar; n: i32): i32;
begin
  Assert(p^.nFrom <= n);
  if p^.nFrom <> 0 then
  begin
    if p^.a[0] <> z[0] then Exit(0);
    if strncmp(@p^.a[0], z, p^.nFrom) <> 0 then Exit(0);
  end;
  Result := 1;
end;

function ed3MatchFromTo(pStr: PEditDist3FromString; n1: i32;
                        z2: PAnsiChar; n2: i32): i32;
var
  b1: i32;
  pa: PEditDist3From;
begin
  pa := PEditDist3From(PtrUInt(pStr^.a) + PtrUInt(n1)*SizeOf(TEditDist3From));
  b1 := pa^.nByte;
  if b1 > n2 then Exit(0);
  Assert(b1 > 0);
  if pStr^.z[n1] <> z2[0] then Exit(0);
  if strncmp(@pStr^.z[n1], z2, b1) <> 0 then Exit(0);
  Result := 1;
end;

procedure editDist3FromStringDelete(p: PEditDist3FromString);
var
  i: i32;
  pa: PEditDist3From;
begin
  if p = nil then Exit;
  for i := 0 to p^.n - 1 do
  begin
    pa := PEditDist3From(PtrUInt(p^.a) + PtrUInt(i)*SizeOf(TEditDist3From));
    sqlite3_free(pa^.apDel);
    sqlite3_free(pa^.apSubst);
  end;
  sqlite3_free(p);
end;

function editDist3FromStringNew(pLang: PEditDist3Lang;
                                z: PAnsiChar; n: i32): PEditDist3FromString;
var
  pStr: PEditDist3FromString;
  p: PEditDist3Cost;
  i: i32;
  pFrom: PEditDist3From;
  apNew: Pointer;
  bumped: Boolean;
begin
  if z = nil then Exit(nil);
  if n < 0 then n := i32(strlen(z));
  pStr := PEditDist3FromString(sqlite3_malloc64(
            u64(SizeOf(TEditDist3FromString)
                + SizeOf(TEditDist3From) * n
                + n + 1)));
  if pStr = nil then Exit(nil);
  pStr^.a := PEditDist3From(PtrUInt(pStr) + PtrUInt(SizeOf(TEditDist3FromString)));
  if n > 0 then
    FillChar(pStr^.a^, SizeOf(TEditDist3From) * n, 0);
  pStr^.n := n;
  pStr^.z := PAnsiChar(PtrUInt(pStr^.a) + PtrUInt(SizeOf(TEditDist3From)) * PtrUInt(n));
  Move(z^, pStr^.z^, n + 1);
  if (n > 0) and (pStr^.z[n - 1] = '*') then
  begin
    pStr^.isPrefix := 1;
    Dec(n);
    Dec(pStr^.n);
    pStr^.z[n] := #0;
  end
  else
    pStr^.isPrefix := 0;

  bumped := False;
  for i := 0 to n - 1 do
  begin
    pFrom := PEditDist3From(PtrUInt(pStr^.a) + PtrUInt(i)*SizeOf(TEditDist3From));
    FillChar(pFrom^, SizeOf(pFrom^), 0);
    pFrom^.nByte := utf8Len(Byte(z[i]), n - i);
    p := pLang^.pCost;
    while p <> nil do
    begin
      if i + p^.nFrom > n then begin p := p^.pNext; continue; end;
      if ed3MatchFrom(p, @z[i], n - i) = 0 then begin p := p^.pNext; continue; end;
      if p^.nTo = 0 then
      begin
        apNew := sqlite3_realloc64(pFrom^.apDel,
                   u64(SizeOf(PEditDist3Cost) * (pFrom^.nDel + 1)));
        if apNew = nil then Break;
        pFrom^.apDel := PPEditDist3Cost(apNew);
        PPEditDist3Cost(PtrUInt(apNew) + PtrUInt(pFrom^.nDel)*SizeOf(PEditDist3Cost))^ := p;
        Inc(pFrom^.nDel);
      end
      else
      begin
        apNew := sqlite3_realloc64(pFrom^.apSubst,
                   u64(SizeOf(PEditDist3Cost) * (pFrom^.nSubst + 1)));
        if apNew = nil then Break;
        pFrom^.apSubst := PPEditDist3Cost(apNew);
        PPEditDist3Cost(PtrUInt(apNew) + PtrUInt(pFrom^.nSubst)*SizeOf(PEditDist3Cost))^ := p;
        Inc(pFrom^.nSubst);
      end;
      p := p^.pNext;
    end;
    if p <> nil then begin bumped := True; Break; end;
  end;
  if bumped then
  begin
    editDist3FromStringDelete(pStr);
    Exit(nil);
  end;
  Result := pStr;
end;

procedure ed3UpdateCost(m: Pu32; i, j: i32; iCost: i32);
var
  b: u32;
  pi, pj: Pu32;
begin
  Assert(iCost >= 0);
  Assert(iCost < 10000);
  pj := Pu32(PtrUInt(m) + PtrUInt(j)*SizeOf(u32));
  pi := Pu32(PtrUInt(m) + PtrUInt(i)*SizeOf(u32));
  b := pj^ + u32(iCost);
  if b < pi^ then pi^ := b;
end;

const
  SQLITE_SPELLFIX_STACKALLOC_SZ = 1024;

function editDist3Core(pFrom: PEditDist3FromString; z2: PAnsiChar;
                       n2: i32; pLang: PEditDist3Lang;
                       pnMatch: Pi32): i32;
label
  Lbl_Abort;
var
  k, n, nMatch, nExtra: i32;
  i1, b1, i2, b2: i32;
  f: TEditDist3FromString;
  a2: PEditDist3To;
  m: Pu32;
  pToFree: Pu32;
  szRow: i32;
  p: PEditDist3Cost;
  res: i32;
  nByte: u64;
  stackSpace: array[0..(SQLITE_SPELLFIX_STACKALLOC_SZ div 4)-1] of u32;
  pa: PEditDist3From;
  pb: PEditDist3To;
  rx, rxp, cx, cxp, cxd, cxu: i32;
  apNew: Pointer;
  ix: i32;
begin
  f := pFrom^;
  n := (f.n + 1) * (n2 + 1);
  n := (n + 1) and not 1;
  nByte := u64(n) * SizeOf(u32) + u64(SizeOf(TEditDist3To)) * u64(n2);
  if nByte <= SizeOf(stackSpace) then
  begin
    m := @stackSpace[0];
    pToFree := nil;
  end
  else
  begin
    m := Pu32(sqlite3_malloc64(nByte));
    pToFree := m;
    if m = nil then Exit(-1);
  end;
  a2 := PEditDist3To(PtrUInt(m) + PtrUInt(n)*SizeOf(u32));
  if n2 > 0 then FillChar(a2^, SizeOf(TEditDist3To)*n2, 0);

  res := 0;
  for i2 := 0 to n2 - 1 do
  begin
    pb := PEditDist3To(PtrUInt(a2) + PtrUInt(i2)*SizeOf(TEditDist3To));
    pb^.nByte := utf8Len(Byte(z2[i2]), n2 - i2);
    p := pLang^.pCost;
    while p <> nil do
    begin
      if p^.nFrom > 0 then Break;
      if i2 + p^.nTo > n2 then begin p := p^.pNext; continue; end;
      if Byte(p^.a[0]) > Byte(z2[i2]) then Break;
      if ed3MatchTo(p, @z2[i2], n2 - i2) = 0 then begin p := p^.pNext; continue; end;
      Inc(pb^.nIns);
      apNew := sqlite3_realloc64(pb^.apIns,
                 u64(SizeOf(PEditDist3Cost) * pb^.nIns));
      if apNew = nil then begin res := -1; goto Lbl_Abort; end;
      pb^.apIns := PPEditDist3Cost(apNew);
      PPEditDist3Cost(PtrUInt(apNew)
        + PtrUInt(pb^.nIns - 1)*SizeOf(PEditDist3Cost))^ := p;
      p := p^.pNext;
    end;
  end;

  szRow := f.n + 1;
  FillChar(m^, u64(n2 + 1) * u64(szRow) * SizeOf(u32), $01);
  m^ := 0;

  i1 := 0;
  while i1 < f.n do
  begin
    pa := PEditDist3From(PtrUInt(f.a) + PtrUInt(i1)*SizeOf(TEditDist3From));
    b1 := pa^.nByte;
    ed3UpdateCost(m, i1 + b1, i1, pLang^.iDelCost);
    for k := 0 to pa^.nDel - 1 do
    begin
      p := PPEditDist3Cost(PtrUInt(pa^.apDel)
             + PtrUInt(k)*SizeOf(PEditDist3Cost))^;
      ed3UpdateCost(m, i1 + p^.nFrom, i1, p^.iCost);
    end;
    Inc(i1, b1);
  end;

  i2 := 0;
  while i2 < n2 do
  begin
    pb := PEditDist3To(PtrUInt(a2) + PtrUInt(i2)*SizeOf(TEditDist3To));
    b2 := pb^.nByte;
    rx := szRow * (i2 + b2);
    rxp := szRow * i2;
    ed3UpdateCost(m, rx, rxp, pLang^.iInsCost);
    for k := 0 to pb^.nIns - 1 do
    begin
      p := PPEditDist3Cost(PtrUInt(pb^.apIns)
             + PtrUInt(k)*SizeOf(PEditDist3Cost))^;
      ed3UpdateCost(m, szRow * (i2 + p^.nTo), rxp, p^.iCost);
    end;
    i1 := 0;
    while i1 < f.n do
    begin
      pa := PEditDist3From(PtrUInt(f.a) + PtrUInt(i1)*SizeOf(TEditDist3From));
      b1 := pa^.nByte;
      cxp := rx + i1;
      cx := cxp + b1;
      cxd := rxp + i1;
      cxu := cxd + b1;
      ed3UpdateCost(m, cx, cxp, pLang^.iDelCost);
      for k := 0 to pa^.nDel - 1 do
      begin
        p := PPEditDist3Cost(PtrUInt(pa^.apDel)
               + PtrUInt(k)*SizeOf(PEditDist3Cost))^;
        ed3UpdateCost(m, cxp + p^.nFrom, cxp, p^.iCost);
      end;
      ed3UpdateCost(m, cx, cxu, pLang^.iInsCost);
      if ed3MatchFromTo(@f, i1, @z2[i2], n2 - i2) <> 0 then
        ed3UpdateCost(m, cx, cxd, 0);
      ed3UpdateCost(m, cx, cxd, pLang^.iSubCost);
      for k := 0 to pa^.nSubst - 1 do
      begin
        p := PPEditDist3Cost(PtrUInt(pa^.apSubst)
               + PtrUInt(k)*SizeOf(PEditDist3Cost))^;
        if ed3MatchTo(p, @z2[i2], n2 - i2) <> 0 then
          ed3UpdateCost(m, cxd + p^.nFrom + szRow*p^.nTo, cxd, p^.iCost);
      end;
      Inc(i1, b1);
    end;
    Inc(i2, b2);
  end;

  res := i32(Pu32(PtrUInt(m) + PtrUInt(szRow*(n2+1) - 1)*SizeOf(u32))^);
  nMatch := n2;
  if f.isPrefix <> 0 then
  begin
    for i2 := 1 to n2 do
    begin
      ix := i32(Pu32(PtrUInt(m) + PtrUInt(szRow*i2 - 1)*SizeOf(u32))^);
      if ix <= res then
      begin
        res := ix;
        nMatch := i2 - 1;
      end;
    end;
  end;
  if pnMatch <> nil then
  begin
    nExtra := 0;
    for k := 0 to nMatch - 1 do
      if (Byte(z2[k]) and $c0) = $80 then Inc(nExtra);
    pnMatch^ := nMatch - nExtra;
  end;

Lbl_Abort:
  for i2 := 0 to n2 - 1 do
  begin
    pb := PEditDist3To(PtrUInt(a2) + PtrUInt(i2)*SizeOf(TEditDist3To));
    sqlite3_free(pb^.apIns);
  end;
  sqlite3_free(pToFree);
  Result := res;
end;

function editDist3FindLang(pConfig: PEditDist3Config;
                           iLang: i32): PEditDist3Lang;
var
  i: i32;
  pa: PEditDist3Lang;
begin
  for i := 0 to pConfig^.nLang - 1 do
  begin
    pa := PEditDist3Lang(PtrUInt(pConfig^.a)
            + PtrUInt(i)*SizeOf(TEditDist3Lang));
    if pa^.iLang = iLang then Exit(pa);
  end;
  Result := @editDist3LangDflt;
end;

procedure editDist3SqlFunc(pCtx: Psqlite3_context;
                           argc: i32; argv: PPMem); cdecl;
var
  pConfig: PEditDist3Config;
  db: PTsqlite3;
  rc: i32;
  zTable, zA, zB: PAnsiChar;
  nA, nB, iLang, dist: i32;
  pLang: PEditDist3Lang;
  pFrom: PEditDist3FromString;
begin
  pConfig := PEditDist3Config(sqlite3_user_data(pCtx));
  db := sqlite3_context_db_handle(pCtx);
  if argc = 1 then
  begin
    zTable := PAnsiChar(sqlite3_value_text(argv[0]));
    rc := editDist3ConfigLoad(pConfig, db, zTable);
    if rc <> SQLITE_OK then sqlite3_result_error_code(pCtx, rc);
  end
  else
  begin
    zA := PAnsiChar(sqlite3_value_text(argv[0]));
    zB := PAnsiChar(sqlite3_value_text(argv[1]));
    nA := sqlite3_value_bytes(argv[0]);
    nB := sqlite3_value_bytes(argv[1]);
    if argc = 3 then
      iLang := sqlite3_value_int(argv[2])
    else
      iLang := 0;
    pLang := editDist3FindLang(pConfig, iLang);
    pFrom := editDist3FromStringNew(pLang, zA, nA);
    if pFrom = nil then
    begin
      sqlite3_result_error_nomem(pCtx);
      Exit;
    end;
    dist := editDist3Core(pFrom, zB, nB, pLang, nil);
    editDist3FromStringDelete(pFrom);
    if dist = -1 then
      sqlite3_result_error_nomem(pCtx)
    else
      sqlite3_result_int(pCtx, dist);
  end;
end;

function editDist3Install(db: PTsqlite3): i32;
const
  FFlags = SQLITE_UTF8 or SQLITE_DETERMINISTIC;
var
  pConfig: PEditDist3Config;
  rc: i32;
begin
  pConfig := PEditDist3Config(sqlite3_malloc64(SizeOf(TEditDist3Config)));
  if pConfig = nil then Exit(SQLITE_NOMEM);
  FillChar(pConfig^, SizeOf(pConfig^), 0);
  rc := sqlite3_create_function_v2(db, 'editdist3', 2, FFlags, pConfig,
          @editDist3SqlFunc, nil, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function_v2(db, 'editdist3', 3, FFlags, pConfig,
            @editDist3SqlFunc, nil, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function_v2(db, 'editdist3', 1, FFlags, pConfig,
            @editDist3SqlFunc, nil, nil, @editDist3ConfigDelete)
  else
    sqlite3_free(pConfig);
  Result := rc;
end;

function sqlite3SpellfixInit(db: PTsqlite3): i32;
const
  FFlags = SQLITE_UTF8 or SQLITE_DETERMINISTIC;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'spellfix1_editdist', 2, FFlags, nil,
                                @editdistSqlFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'spellfix1_phonehash', 1, FFlags, nil,
                                  @phoneticHashSqlFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'spellfix1_scriptcode', 1, FFlags, nil,
                                  @scriptCodeSqlFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'spellfix1_translit', 1, FFlags, nil,
                                  @transliterateSqlFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := editDist3Install(db);
  Result := rc;
end;

end.
