{$I passqlite3.inc}
unit passqlite3json;

{
  Phase 6.8.a/b — JSON foundation + JsonString accumulator
  (port of sqlite3/src/json.c).

  This is the first chunk of the optional `json.c` port flagged as 6.8 in
  the project task list.  json.c is ~5680 lines of C; the port lands in
  chunks, each individually testable.  6.8.a establishes the foundation:
  types, constants, the four byte-classification lookup tables
  (jsonbType, jsonIsSpace, jsonSpaces, jsonIsOk), and the pure
  byte-level helpers that have no external dependencies (jsonHexToInt,
  jsonHexToInt4, jsonIs2Hex, jsonIs4Hex, jsonIsspace, json5Whitespace,
  aNanInfName).

  Subsequent chunks (planned):
    * 6.8.b — JsonString accumulator (jsonStringInit/Reset/Grow/
      AppendRaw/Char/Separator/ControlChar/String/SqlValue/Terminate/
      ReturnString); requires sqlite3RCStr* helpers.
    * 6.8.c — JsonParse blob primitives (BlobExpand, BlobAppendNode,
      BlobChangePayloadSize, jsonbValidityCheck, jsonbPayloadSize).
    * 6.8.d — Text-to-blob translator (jsonTranslateTextToBlob,
      jsonConvertTextToBlob).
    * 6.8.e — Blob-to-text + pretty (jsonTranslateBlobToText,
      jsonTranslateBlobToPrettyText, jsonReturnTextJsonFromBlob).
    * 6.8.f — Path lookup + edit (jsonLookupStep, jsonBlobEdit,
      jsonAfterEditSizeAdjust).
    * 6.8.g — JSON cache (jsonCacheInsert/Search) — requires
      sqlite3_set_auxdata / sqlite3_get_auxdata.
    * 6.8.h — Function dispatch (json/jsonb/json_array/_object/_extract/
      _set/_remove/_patch/_each/_tree/_valid/_type/_quote/_group_array/
      _group_object/_pretty/_error_position) + sqlite3RegisterJsonFunctions.

  The JSONB on-disk format is documented in detail at the top of
  json.c; no need to repeat here.

  Allocation contract: same as printf — db-malloc for db-bound
  intermediates, libc malloc for sqlite3_value /sqlite3_context-bound
  output strings.  Callsites mirror the C reference.
}

interface

uses
  passqlite3types,
  passqlite3os,
  passqlite3util;

{ ===========================================================================
  Constants
  =========================================================================== }

const
  { JSONB element types — lower 4 bits of the first header byte. }
  JSONB_NULL    = 0;   { "null" }
  JSONB_TRUE    = 1;   { "true" }
  JSONB_FALSE   = 2;   { "false" }
  JSONB_INT     = 3;   { integer acceptable to JSON and SQL }
  JSONB_INT5    = 4;   { integer in 0x000 notation }
  JSONB_FLOAT   = 5;   { float acceptable to JSON and SQL }
  JSONB_FLOAT5  = 6;   { float with JSON5 extensions }
  JSONB_TEXT    = 7;   { Text compatible with both JSON and SQL }
  JSONB_TEXTJ   = 8;   { Text with JSON escapes }
  JSONB_TEXT5   = 9;   { Text with JSON-5 escape }
  JSONB_TEXTRAW = 10;  { SQL text that needs escaping for JSON }
  JSONB_ARRAY   = 11;  { An array }
  JSONB_OBJECT  = 12;  { An object }

  { Magic number used for the JSON parse cache in sqlite3_get_auxdata() }
  JSON_CACHE_ID    = -429938;
  JSON_CACHE_SIZE  = 4;

  { jsonUnescapeOneChar() returns this invalid code point on syntax error. }
  JSON_INVALID_CHAR = $99999;

  { Values for JsonString.eErr }
  JSTRING_OOM       = $01;   { Out of memory }
  JSTRING_MALFORMED = $02;   { Malformed JSONB }
  JSTRING_TOODEEP   = $04;   { JSON nested too deep }
  JSTRING_ERR       = $08;   { Error already sent to sqlite3_result }

  { The "subtype" set for text JSON values (Ascii for "J"). }
  JSON_SUBTYPE = 74;

  { Bit values for the flags passed via sqlite3_user_data(). }
  JSON_JSON   = $01;        { Result is always JSON }
  JSON_SQL    = $02;        { Result is always SQL }
  JSON_ABPATH = $03;        { Allow abbreviated JSON path specs }
  JSON_ISSET  = $04;        { json_set(), not json_insert() }
  JSON_AINS   = $08;        { json_array_insert(), not json_insert() }
  JSON_BLOB   = $10;        { Use the BLOB output format }

  { Values for JsonParse.eEdit }
  JEDIT_DEL  = 1;   { Delete if exists }
  JEDIT_REPL = 2;   { Overwrite if exists }
  JEDIT_INS  = 3;   { Insert if not exists }
  JEDIT_SET  = 4;   { Insert or overwrite }
  JEDIT_AINS = 5;   { array_insert() }

  { Maximum JSON nesting depth (recursive descent stack guard). }
  JSON_MAX_DEPTH = 1000;

  { Flags for jsonParseFuncArg() }
  JSON_EDITABLE  = $01;   { Generate a writable JsonParse object }
  JSON_KEEPERROR = $02;   { Return non-NULL even if there is an error }

{ ===========================================================================
  Types
  =========================================================================== }

type
  PJsonCache  = ^TJsonCache;
  PJsonString = ^TJsonString;
  PJsonParse  = ^TJsonParse;
  PPJsonParse = ^PJsonParse;

  {
    A cache mapping JSON text into JSONB blobs.  Each slot is a JsonParse
    object with bReadOnly set, owned aBlob[], eEdit=delta=0, and zJson
    backed by an RCStr.
  }
  TJsonCache = record
    db    : Pointer;                          { Psqlite3 — DB connection }
    nUsed : i32;                              { Number of active entries }
    a     : array[0..JSON_CACHE_SIZE - 1] of PJsonParse;
  end;

  {
    A JSON string under construction.  Acts as a generic string
    accumulator; if the result outgrows the inline zSpace[100] buffer,
    it spills onto an RCStr-backed heap allocation so large JSON outputs
    can be cached cheaply.
  }
  TJsonString = record
    pCtx    : Pointer;                  { Psqlite3_context — error sink }
    zBuf    : PAnsiChar;                { Append target }
    nAlloc  : u64;                      { Bytes available in zBuf[] }
    nUsed   : u64;                      { Bytes of zBuf[] currently used }
    bStatic : u8;                       { 1 if zBuf points at zSpace[] }
    eErr    : u8;                       { JSTRING_* bitmask }
    zSpace  : array[0..99] of AnsiChar; { Inline static space (100 bytes) }
  end;

  {
    A parsed JSON value.  Lifecycle:
      1. JSON text in → parsed into JSONB in aBlob[]; original text in
         zJson.  Step skipped when input is JSONB already.
      2. aBlob[] is searched via JSON path notation, if needed.
      3. Edits applied (json_remove / _replace / _patch / etc.).
      4. New JSON text generated from aBlob[] for output (skipped for
         jsonb_* functions returning JSONB).
  }
  TJsonParse = record
    aBlob         : PByte;     { JSONB representation of JSON value }
    nBlob         : u32;       { Bytes of aBlob[] actually used }
    nBlobAlloc    : u32;       { Bytes allocated to aBlob[]; 0 if external }
    zJson         : PAnsiChar; { JSON text used for parsing }
    db            : Pointer;   { Psqlite3 — owning DB }
    nJson         : i32;       { Length of zJson in bytes }
    nJPRef        : u32;       { Reference count }
    iErr          : u32;       { Error location in zJson[] }
    iDepth        : u16;       { Current nesting depth }
    nErr          : u8;        { Number of errors seen }
    oom           : u8;        { Set on OOM }
    bJsonIsRCStr  : u8;        { True if zJson is an RCStr }
    hasNonstd     : u8;        { Input uses non-standard (JSON5) features }
    bReadOnly     : u8;        { Do not modify }
    { Search and edit information (set up by jsonLookupStep) }
    eEdit         : u8;        { JEDIT_* opcode }
    delta         : i32;       { Size change due to the edit }
    nIns          : u32;       { Bytes to insert }
    iLabel        : u32;       { Location of label if landed on object value }
    aIns          : PByte;     { Content to be inserted }
  end;

  {
    Float-literal substitution table for the JSON5 NaN/Infinity surface.
    Indexed by `aNanInfName`; jsonTranslateTextToBlob consults this
    when it sees an alphabetic prefix while parsing a number.
  }
  TNanInfName = record
    c1    : AnsiChar;     { primary first-char (lowercase) }
    c2    : AnsiChar;     { alternate first-char (uppercase) }
    n     : i8;           { length of zMatch }
    eType : i8;           { JSONB_* type the literal expands to }
    nRepl : i8;           { length of zRepl }
    zMatch: PAnsiChar;
    zRepl : PAnsiChar;
  end;

{ ===========================================================================
  Lookup tables
  =========================================================================== }

const
  {
    Human-readable type name per JSONB_*.  Index 13..16 are reserved for
    future enhancements and resolve to empty strings (mirrors C array
    zero-fill on out-of-range JSONB element types).
  }
  jsonbType: array[0..16] of PAnsiChar = (
    'null', 'true', 'false', 'integer', 'integer',
    'real', 'real', 'text',  'text',    'text',
    'text', 'array', 'object', '', '', '', ''
  );

  {
    1 if the byte is a JSON whitespace character (RFC-8259 strict set:
    HT, LF, CR, SPACE) under SQLITE_ASCII; otherwise 0.
  }
  { Name differs from C's `jsonIsSpace` to avoid FPC's case-insensitive
    collision with the inline function `jsonIsspace` below; the C macro
    `jsonIsspace(x)` keeps its idiomatic spelling. }
  aJsonIsSpace: array[0..255] of Byte = (
  { 0  1  2  3  4  5  6  7   8  9  a  b  c  d  e  f  }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 1, 1, 0, 0, 1, 0, 0,  { 0 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 1 }
    1, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 2 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 3 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 4 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 5 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 6 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 7 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 8 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 9 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { a }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { b }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { c }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { d }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { e }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0   { f }
  );

  {
    The set of JSON whitespace characters as a NUL-terminated string —
    HT (\011), LF (\012), CR (\015), SPACE (\040).  Useful as the
    second argument to a strspn-style helper.
  }
  jsonSpaces: PAnsiChar = #$09#$0A#$0D#$20;

  {
    1 if the byte is "ok" inside a JSON string body (i.e. need not be
    escaped): excludes control bytes 0..0x1f, '"' (0x22), '\\' (0x5c)
    and '\'' (0x27 — JSON5 special).  Bytes 0x80+ pass through as
    UTF-8 continuation bytes.
  }
  jsonIsOk: array[0..255] of Byte = (
  { 0  1  2  3  4  5  6  7   8  9  a  b  c  d  e  f  }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 0 }
    0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,  { 1 }
    1, 1, 0, 1, 1, 1, 1, 0,  1, 1, 1, 1, 1, 1, 1, 1,  { 2 }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { 3 }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { 4 }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 0, 1, 1, 1,  { 5 }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { 6 }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { 7 }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { 8 }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { 9 }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { a }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { b }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { c }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { d }
    0, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1,  { e }
    1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1   { f }
  );

  {
    Extra floating-point literals to allow in JSON.  Mirror of
    json.c:1113 aNanInfName.
  }
  aNanInfName: array[0..4] of TNanInfName = (
    (c1: 'i'; c2: 'I'; n: 3; eType: JSONB_FLOAT; nRepl: 7;
     zMatch: 'inf';      zRepl: '9.0e999'),
    (c1: 'i'; c2: 'I'; n: 8; eType: JSONB_FLOAT; nRepl: 7;
     zMatch: 'infinity'; zRepl: '9.0e999'),
    (c1: 'n'; c2: 'N'; n: 3; eType: JSONB_NULL;  nRepl: 4;
     zMatch: 'NaN';      zRepl: 'null'),
    (c1: 'q'; c2: 'Q'; n: 4; eType: JSONB_NULL;  nRepl: 4;
     zMatch: 'QNaN';     zRepl: 'null'),
    (c1: 's'; c2: 'S'; n: 4; eType: JSONB_NULL;  nRepl: 4;
     zMatch: 'SNaN';     zRepl: 'null')
  );

{ ===========================================================================
  Pure helpers
  =========================================================================== }

{
  jsonIsspace — 1 if c is JSON whitespace, else 0.
  Mirrors json.c:196 macro: jsonIsSpace[(unsigned char)x].
}
function jsonIsspace(c: AnsiChar): i32; inline;

{
  jsonHexToInt — translate one hex byte to its 0..15 value.  Caller
  must already know c is a valid hex digit; behaviour on non-hex input
  is undefined (mirrors C version which omits the assert).
}
function jsonHexToInt(c: i32): u8; inline;

{
  jsonHexToInt4 — convert 4 hex bytes into a u16-range integer.
  z must point to at least 4 valid hex digits (caller checks via
  jsonIs4Hex).
}
function jsonHexToInt4(z: PAnsiChar): u32;

{ True if z[] begins with at least 2 hex digits. }
function jsonIs2Hex(z: PAnsiChar): i32;

{ True if z[] begins with at least 4 hex digits. }
function jsonIs4Hex(z: PAnsiChar): i32;

{
  json5Whitespace — return the number of bytes of JSON5 whitespace at
  the beginning of z[].  Recognises ASCII whitespace, several Unicode
  spaces (NBSP, ogham, ems, en, fig, NNBSP, MMSP, ideographic, BOM),
  /*..*/ block comments, and //..EOL line comments.  Caller-string
  must be NUL-terminated.
}
function json5Whitespace(zIn: PAnsiChar): i32;

{ ===========================================================================
  JsonString accumulator (Phase 6.8.b)

  Append-only string builder backed by an inline 100-byte zSpace[] buffer
  with libc-malloc spill on overflow.  All writes are gated on eErr — once
  any error bit is set, further append calls become no-ops.

  Spill memory is allocated with sqlite3_malloc/realloc/free (libc), not
  sqlite3RCStr*, since RCStr is not yet ported.  When 6.8.h lands, the
  spill buffer can be lifted to RCStr if jsonReturnString needs to hand a
  shared reference into a result_text64 callback chain.

  Error sinking: jsonStringOom and jsonStringTooDeep set eErr but do *not*
  call sqlite3_result_error_nomem / sqlite3_result_error.  Pulling
  passqlite3vdbe in here would create a heavy dep cycle with codegen; the
  6.8.h dispatch chunk will surface the eErr bits to the SQL caller when
  it wires up jsonReturnString.  Within json.c-internals, eErr is the
  authoritative signal and downstream callers all check it.
  =========================================================================== }

procedure jsonStringZero(p: PJsonString);
procedure jsonStringInit(p: PJsonString; pCtx: Pointer);
procedure jsonStringReset(p: PJsonString);
procedure jsonStringOom(p: PJsonString);
procedure jsonStringTooDeep(p: PJsonString);
function  jsonStringGrow(p: PJsonString; N: u32): i32;
procedure jsonStringExpandAndAppend(p: PJsonString; zIn: PAnsiChar; N: u32);
procedure jsonAppendRaw(p: PJsonString; zIn: PAnsiChar; N: u32);
procedure jsonAppendRawNZ(p: PJsonString; zIn: PAnsiChar; N: u32);
procedure jsonAppendCharExpand(p: PJsonString; c: AnsiChar);
procedure jsonAppendChar(p: PJsonString; c: AnsiChar);
procedure jsonStringTrimOneChar(p: PJsonString);
function  jsonStringTerminate(p: PJsonString): i32;
procedure jsonAppendSeparator(p: PJsonString);
procedure jsonAppendControlChar(p: PJsonString; c: u8);
procedure jsonAppendString(p: PJsonString; zIn: PAnsiChar; N: u32);

implementation

function jsonIsspace(c: AnsiChar): i32; inline;
begin
  Result := aJsonIsSpace[Ord(c)];
end;

function jsonHexToInt(c: i32): u8; inline;
begin
  { json.c:947 — the +9 trick maps 'A'..'F' / 'a'..'f' (which have bit 6
    set: 0x40 / 0x60) onto 10..15; '0'..'9' (bit 6 clear) pass through. }
  c := c + 9 * (1 and (c shr 6));
  Result := u8(c and $0F);
end;

function jsonHexToInt4(z: PAnsiChar): u32;
begin
  Result := (u32(jsonHexToInt(Ord(z[0]))) shl 12)
          + (u32(jsonHexToInt(Ord(z[1]))) shl  8)
          + (u32(jsonHexToInt(Ord(z[2]))) shl  4)
          +  u32(jsonHexToInt(Ord(z[3])));
end;

function jsonIs2Hex(z: PAnsiChar): i32;
begin
  if (sqlite3Isxdigit(Ord(z[0])) <> 0)
     and (sqlite3Isxdigit(Ord(z[1])) <> 0) then
    Result := 1
  else
    Result := 0;
end;

function jsonIs4Hex(z: PAnsiChar): i32;
begin
  if (jsonIs2Hex(z) <> 0) and (jsonIs2Hex(z + 2) <> 0) then
    Result := 1
  else
    Result := 0;
end;

function json5Whitespace(zIn: PAnsiChar): i32;
var
  n, j  : i32;
  z     : PByte;
  c     : Byte;
  cN1   : Byte;
  done  : Boolean;
begin
  n := 0;
  z := PByte(zIn);
  done := False;
  while not done do
  begin
    case z[n] of
      $09, $0A, $0B, $0C, $0D, $20:
        Inc(n);
      Ord('/'):
      begin
        cN1 := z[n + 1];
        if (cN1 = Ord('*')) and (z[n + 2] <> 0) then
        begin
          j := n + 3;
          while (z[j] <> Ord('/')) or (z[j - 1] <> Ord('*')) do
          begin
            if z[j] = 0 then
            begin
              done := True;
              Break;
            end;
            Inc(j);
          end;
          if done then Continue;
          n := j + 1;
        end
        else if cN1 = Ord('/') then
        begin
          j := n + 2;
          while True do
          begin
            c := z[j];
            if c = 0 then Break;
            if (c = Ord(#10)) or (c = Ord(#13)) then Break;
            if (c = $E2) and (z[j + 1] = $80)
               and ((z[j + 2] = $A8) or (z[j + 2] = $A9)) then
            begin
              j := j + 2;
              Break;
            end;
            Inc(j);
          end;
          n := j;
          if z[n] <> 0 then Inc(n);
        end
        else
          done := True;
      end;
      $C2:
      begin
        if z[n + 1] = $A0 then
          n := n + 2
        else
          done := True;
      end;
      $E1:
      begin
        if (z[n + 1] = $9A) and (z[n + 2] = $80) then
          n := n + 3
        else
          done := True;
      end;
      $E2:
      begin
        if z[n + 1] = $80 then
        begin
          c := z[n + 2];
          if c < $80 then
            done := True
          else if (c <= $8A) or (c = $A8) or (c = $A9) or (c = $AF) then
            n := n + 3
          else
            done := True;
        end
        else if (z[n + 1] = $81) and (z[n + 2] = $9F) then
          n := n + 3
        else
          done := True;
      end;
      $E3:
      begin
        if (z[n + 1] = $80) and (z[n + 2] = $80) then
          n := n + 3
        else
          done := True;
      end;
      $EF:
      begin
        if (z[n + 1] = $BB) and (z[n + 2] = $BF) then
          n := n + 3
        else
          done := True;
      end;
      else
        done := True;
    end;
  end;
  Result := n;
end;

{ ===========================================================================
  JsonString accumulator implementation
  =========================================================================== }

procedure jsonStringZero(p: PJsonString);
begin
  p^.zBuf    := @p^.zSpace[0];
  p^.nAlloc  := SizeOf(p^.zSpace);
  p^.nUsed   := 0;
  p^.bStatic := 1;
end;

procedure jsonStringInit(p: PJsonString; pCtx: Pointer);
begin
  p^.pCtx := pCtx;
  p^.eErr := 0;
  jsonStringZero(p);
end;

procedure jsonStringReset(p: PJsonString);
begin
  if p^.bStatic = 0 then
    sqlite3_free(p^.zBuf);
  jsonStringZero(p);
end;

procedure jsonStringOom(p: PJsonString);
begin
  p^.eErr := p^.eErr or JSTRING_OOM;
  { Result-error sinking deferred to 6.8.h dispatch (see header note). }
  jsonStringReset(p);
end;

procedure jsonStringTooDeep(p: PJsonString);
begin
  p^.eErr := p^.eErr or JSTRING_TOODEEP;
  { Result-error sinking deferred to 6.8.h dispatch (see header note). }
  jsonStringReset(p);
end;

function jsonStringGrow(p: PJsonString; N: u32): i32;
var
  nTotal : u64;
  zNew   : PAnsiChar;
begin
  if N < p^.nAlloc then
    nTotal := p^.nAlloc * 2
  else
    nTotal := p^.nAlloc + N + 10;
  if p^.bStatic <> 0 then
  begin
    if p^.eErr <> 0 then
    begin
      Result := 1;
      Exit;
    end;
    zNew := PAnsiChar(sqlite3_malloc64(nTotal));
    if zNew = nil then
    begin
      jsonStringOom(p);
      Result := SQLITE_NOMEM;
      Exit;
    end;
    if p^.nUsed > 0 then
      Move(p^.zBuf^, zNew^, p^.nUsed);
    p^.zBuf    := zNew;
    p^.bStatic := 0;
  end
  else
  begin
    p^.zBuf := PAnsiChar(sqlite3_realloc64(p^.zBuf, nTotal));
    if p^.zBuf = nil then
    begin
      p^.eErr := p^.eErr or JSTRING_OOM;
      jsonStringZero(p);
      Result := SQLITE_NOMEM;
      Exit;
    end;
  end;
  p^.nAlloc := nTotal;
  Result := SQLITE_OK;
end;

procedure jsonStringExpandAndAppend(p: PJsonString; zIn: PAnsiChar; N: u32);
begin
  if jsonStringGrow(p, N) <> 0 then Exit;
  Move(zIn^, (p^.zBuf + p^.nUsed)^, N);
  p^.nUsed := p^.nUsed + N;
end;

procedure jsonAppendRaw(p: PJsonString; zIn: PAnsiChar; N: u32);
begin
  if N = 0 then Exit;
  if N + p^.nUsed >= p^.nAlloc then
    jsonStringExpandAndAppend(p, zIn, N)
  else
  begin
    Move(zIn^, (p^.zBuf + p^.nUsed)^, N);
    p^.nUsed := p^.nUsed + N;
  end;
end;

procedure jsonAppendRawNZ(p: PJsonString; zIn: PAnsiChar; N: u32);
begin
  if N + p^.nUsed >= p^.nAlloc then
    jsonStringExpandAndAppend(p, zIn, N)
  else
  begin
    Move(zIn^, (p^.zBuf + p^.nUsed)^, N);
    p^.nUsed := p^.nUsed + N;
  end;
end;

procedure jsonAppendCharExpand(p: PJsonString; c: AnsiChar);
begin
  if jsonStringGrow(p, 1) <> 0 then Exit;
  p^.zBuf[p^.nUsed] := c;
  p^.nUsed := p^.nUsed + 1;
end;

procedure jsonAppendChar(p: PJsonString; c: AnsiChar);
begin
  if p^.nUsed >= p^.nAlloc then
    jsonAppendCharExpand(p, c)
  else
  begin
    p^.zBuf[p^.nUsed] := c;
    p^.nUsed := p^.nUsed + 1;
  end;
end;

procedure jsonStringTrimOneChar(p: PJsonString);
begin
  if p^.eErr = 0 then
    p^.nUsed := p^.nUsed - 1;
end;

function jsonStringTerminate(p: PJsonString): i32;
begin
  jsonAppendChar(p, #0);
  jsonStringTrimOneChar(p);
  if p^.eErr = 0 then Result := 1 else Result := 0;
end;

procedure jsonAppendSeparator(p: PJsonString);
var c: AnsiChar;
begin
  if p^.nUsed = 0 then Exit;
  c := p^.zBuf[p^.nUsed - 1];
  if (c = '[') or (c = '{') then Exit;
  jsonAppendChar(p, ',');
end;

const
  { Mirror of json.c:697 aSpecial[] — \b\t\n\f\r short escapes for
    control bytes 0x08, 0x09, 0x0a, 0x0c, 0x0d. }
  jsonCtrlSpecial: array[0..31] of AnsiChar = (
    #0, #0, #0, #0, #0, #0, #0, #0, 'b', 't', 'n', #0, 'f', 'r', #0, #0,
    #0, #0, #0, #0, #0, #0, #0, #0, #0,  #0,  #0,  #0, #0,  #0,  #0, #0
  );
  jsonHexDigits: array[0..15] of AnsiChar = '0123456789abcdef';

procedure jsonAppendControlChar(p: PJsonString; c: u8);
var s: AnsiChar;
begin
  s := jsonCtrlSpecial[c];
  if s <> #0 then
  begin
    p^.zBuf[p^.nUsed]     := '\';
    p^.zBuf[p^.nUsed + 1] := s;
    p^.nUsed := p^.nUsed + 2;
  end
  else
  begin
    p^.zBuf[p^.nUsed]     := '\';
    p^.zBuf[p^.nUsed + 1] := 'u';
    p^.zBuf[p^.nUsed + 2] := '0';
    p^.zBuf[p^.nUsed + 3] := '0';
    p^.zBuf[p^.nUsed + 4] := jsonHexDigits[c shr 4];
    p^.zBuf[p^.nUsed + 5] := jsonHexDigits[c and $0F];
    p^.nUsed := p^.nUsed + 6;
  end;
end;

procedure jsonAppendString(p: PJsonString; zIn: PAnsiChar; N: u32);
var
  k    : u32;
  c    : u8;
  z    : PByte;
begin
  z := PByte(zIn);
  if z = nil then Exit;
  if (N + p^.nUsed + 2 >= p^.nAlloc)
     and (jsonStringGrow(p, N + 2) <> 0) then Exit;
  p^.zBuf[p^.nUsed] := '"';
  p^.nUsed := p^.nUsed + 1;
  while True do
  begin
    k := 0;
    { 4-way unwound equivalent of: while k<N and jsonIsOk[z[k]] do Inc(k). }
    while True do
    begin
      if k + 3 >= N then
      begin
        while (k < N) and (jsonIsOk[z[k]] <> 0) do Inc(k);
        Break;
      end;
      if jsonIsOk[z[k]] = 0 then Break;
      if jsonIsOk[z[k + 1]] = 0 then begin Inc(k); Break; end;
      if jsonIsOk[z[k + 2]] = 0 then begin k := k + 2; Break; end;
      if jsonIsOk[z[k + 3]] = 0 then begin k := k + 3; Break; end;
      k := k + 4;
    end;
    if k >= N then
    begin
      if k > 0 then
      begin
        Move(z^, (p^.zBuf + p^.nUsed)^, k);
        p^.nUsed := p^.nUsed + k;
      end;
      Break;
    end;
    if k > 0 then
    begin
      Move(z^, (p^.zBuf + p^.nUsed)^, k);
      p^.nUsed := p^.nUsed + k;
      z := z + k;
      N := N - k;
    end;
    c := z[0];
    if (c = Ord('"')) or (c = Ord('\')) then
    begin
      if (p^.nUsed + N + 3 > p^.nAlloc)
         and (jsonStringGrow(p, N + 3) <> 0) then Exit;
      p^.zBuf[p^.nUsed]     := '\';
      p^.zBuf[p^.nUsed + 1] := AnsiChar(c);
      p^.nUsed := p^.nUsed + 2;
    end
    else if c = Ord('''') then
    begin
      p^.zBuf[p^.nUsed] := AnsiChar(c);
      p^.nUsed := p^.nUsed + 1;
    end
    else
    begin
      if (p^.nUsed + N + 7 > p^.nAlloc)
         and (jsonStringGrow(p, N + 7) <> 0) then Exit;
      jsonAppendControlChar(p, c);
    end;
    z := z + 1;
    N := N - 1;
  end;
  p^.zBuf[p^.nUsed] := '"';
  p^.nUsed := p^.nUsed + 1;
end;

end.
