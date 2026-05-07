{
  SPDX-License-Identifier: blessing

  Faithful port of the scalar SQL functions from
  ../sqlite3/ext/misc/spellfix.c (3076 lines in C, of which this unit
  ports lines 38..538 and 1848..1896 — phoneticHash, editdist1, the
  costing helpers, and scriptCode).

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

  The full spellfix1 virtual table (vocabulary fuzzy-search), the
  configurable-cost editdist3 family, and the transliterate machinery
  are NOT ported by this unit — they require ~2500 additional C lines
  worth of state-machine code (Transliteration table, EditDist3*
  cost-mergesort, the spellfix1_vocab shadow-table CRUD path) and will
  land separately.

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
  passqlite3printf;

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
  Result := rc;
end;

end.
