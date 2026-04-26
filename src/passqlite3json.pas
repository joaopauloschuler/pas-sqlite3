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

  {
    Context for jsonTranslateBlobToPrettyText (json_pretty()).  Mirrors
    json.c:2418.
  }
  PJsonPretty = ^TJsonPretty;
  TJsonPretty = record
    pParse   : PJsonParse;    { The BLOB being rendered }
    pOut     : PJsonString;   { Generate pretty output into this string }
    zIndent  : PAnsiChar;     { Use this text for indentation }
    szIndent : u32;           { Bytes in zIndent[] }
    nIndent  : u32;           { Current level of indentation }
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

{ ===========================================================================
  JsonParse blob primitives (Phase 6.8.c)

  Editing primitives for the JSONB on-disk representation held in
  TJsonParse.aBlob[].  All allocations go through sqlite3DbRealloc on
  pParse^.db so they share the connection-bound pool with the rest of
  the JSON unit; on OOM, pParse^.oom is set and writes silently no-op.

  Note: jsonbValidityCheck deferred to 6.8.d since its JSONB_TEXT5
  branch needs jsonUnescapeOneChar (also a 6.8.d helper). The blob
  *editing* surface here is fully self-contained.
  =========================================================================== }

function  jsonBlobExpand(pParse: PJsonParse; N: u32): i32;
function  jsonBlobMakeEditable(pParse: PJsonParse; nExtra: u32): i32;
procedure jsonBlobAppendOneByte(pParse: PJsonParse; c: u8);
procedure jsonBlobAppendNode(pParse: PJsonParse; eType: u8; szPayload: u64;
                             aPayload: Pointer);
function  jsonBlobChangePayloadSize(pParse: PJsonParse; i: u32;
                                    szPayload: u32): i32;
function  jsonbPayloadSize(pParse: PJsonParse; i: u32; out pSz: u32): u32;
function  jsonbArrayCount(pParse: PJsonParse; iRoot: u32): u32;
procedure jsonAfterEditSizeAdjust(pParse: PJsonParse; iRoot: u32);
function  jsonBlobOverwrite(aOut: PByte; aIns: PByte; nIns: u32;
                            d: u32): i32;
procedure jsonBlobEdit(pParse: PJsonParse; iDel, nDel: u32;
                       aIns: PByte; nIns: u32);

{ ===========================================================================
  Text→blob translator and supporting helpers (Phase 6.8.d)

  Faithful port of json.c:1355 (jsonIs4HexB), 1372 (jsonbValidityCheck),
  1581 (jsonTranslateTextToBlob), 2055 (jsonConvertTextToBlob),
  2689 (jsonBytesToBypass), 2727 (jsonUnescapeOneChar),
  2820 (jsonLabelCompareEscaped), 2876 (jsonLabelCompare),
  906 (jsonParseReset).

  All rely on `sqlite3Utf8ReadLimited` newly added to passqlite3util.

  Error sinking via pCtx (sqlite3_result_error / _nomem) is deferred to
  6.8.h since it would pull passqlite3vdbe in.  jsonConvertTextToBlob
  records oom/malformed via pParse^.oom and the JSTRING bits on the caller's
  JsonString; the SQL surface in 6.8.h will translate those to result
  errors at the dispatch layer.
  =========================================================================== }

procedure jsonParseReset(pParse: PJsonParse);
function  jsonIs4HexB(z: PAnsiChar; var pOp: i32): i32;
function  jsonBytesToBypass(z: PAnsiChar; n: u32): u32;
function  jsonUnescapeOneChar(z: PAnsiChar; n: u32; out piOut: u32): u32;
function  jsonbValidityCheck(pParse: PJsonParse;
                             i, iEnd, iDepth: u32): u32;
function  jsonLabelCompare(zLeft: PAnsiChar; nLeft: u32; rawLeft: i32;
                           zRight: PAnsiChar; nRight: u32; rawRight: i32): i32;
function  jsonTranslateTextToBlob(pParse: PJsonParse; i: u32): i32;
function  jsonConvertTextToBlob(pParse: PJsonParse; pCtx: Pointer): i32;

{ ===========================================================================
  Blob→text + pretty (Phase 6.8.e)

  Faithful port of json.c:2192 (jsonTranslateBlobToText), 2428
  (jsonPrettyIndent), 2452 (jsonTranslateBlobToPrettyText).

  `jsonReturnTextJsonFromBlob` (json.c:3191) and `jsonReturnParse`
  (json.c:3775) are the SQL-result wrappers — both call
  `jsonReturnString` / `sqlite3_result_*` which would pull
  passqlite3vdbe into the JSON unit.  Deferred to 6.8.h alongside the
  other SQL dispatch.

  `jsonPrintf` is implemented privately for the single jsonTranslateBlobToText
  use-case (INT5 hex overflow → emit "9.0e999" / decimal u64).
  =========================================================================== }

function  jsonTranslateBlobToText(pParse: PJsonParse; i: u32;
                                  pOut: PJsonString): u32;
procedure jsonPrettyIndent(pPretty: PJsonPretty);
function  jsonTranslateBlobToPrettyText(pPretty: PJsonPretty; i: u32): u32;

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

{ ===========================================================================
  JsonParse blob primitives — Phase 6.8.c implementation
  =========================================================================== }

function jsonBlobExpand(pParse: PJsonParse; N: u32): i32;
var
  aNew : PByte;
  t    : u64;
begin
  { assert N>nBlobAlloc }
  if pParse^.nBlobAlloc = 0 then
    t := 100
  else
    t := u64(pParse^.nBlobAlloc) * 2;
  if t < N then t := u64(N) + 100;
  aNew := PByte(sqlite3DbRealloc(pParse^.db, pParse^.aBlob, t));
  if aNew = nil then
  begin
    pParse^.oom := 1;
    Result := 1;
    Exit;
  end;
  pParse^.aBlob := aNew;
  pParse^.nBlobAlloc := u32(t);
  Result := 0;
end;

function jsonBlobMakeEditable(pParse: PJsonParse; nExtra: u32): i32;
var
  aOld  : PByte;
  nSize : u32;
begin
  if pParse^.oom <> 0 then begin Result := 0; Exit; end;
  if pParse^.nBlobAlloc > 0 then begin Result := 1; Exit; end;
  aOld := pParse^.aBlob;
  nSize := pParse^.nBlob + nExtra;
  pParse^.aBlob := nil;
  if jsonBlobExpand(pParse, nSize) <> 0 then
  begin
    Result := 0;
    Exit;
  end;
  if pParse^.nBlob > 0 then
    Move(aOld^, pParse^.aBlob^, pParse^.nBlob);
  Result := 1;
end;

procedure jsonBlobAppendOneByte(pParse: PJsonParse; c: u8);
begin
  if pParse^.nBlob >= pParse^.nBlobAlloc then
    if jsonBlobExpand(pParse, pParse^.nBlob + 1) <> 0 then Exit;
  pParse^.aBlob[pParse^.nBlob] := c;
  pParse^.nBlob := pParse^.nBlob + 1;
end;

procedure jsonBlobAppendNode(pParse: PJsonParse; eType: u8; szPayload: u64;
                             aPayload: Pointer);
var
  a : PByte;
begin
  if u64(pParse^.nBlob) + szPayload + 9 > u64(pParse^.nBlobAlloc) then
    if jsonBlobExpand(pParse, u32(u64(pParse^.nBlob) + szPayload + 9)) <> 0 then
      Exit;
  a := @pParse^.aBlob[pParse^.nBlob];
  if szPayload <= 11 then
  begin
    a[0] := eType or u8(szPayload shl 4);
    pParse^.nBlob := pParse^.nBlob + 1;
  end
  else if szPayload <= $FF then
  begin
    a[0] := eType or $C0;
    a[1] := u8(szPayload and $FF);
    pParse^.nBlob := pParse^.nBlob + 2;
  end
  else if szPayload <= $FFFF then
  begin
    a[0] := eType or $D0;
    a[1] := u8((szPayload shr 8) and $FF);
    a[2] := u8(szPayload and $FF);
    pParse^.nBlob := pParse^.nBlob + 3;
  end
  else
  begin
    a[0] := eType or $E0;
    a[1] := u8((szPayload shr 24) and $FF);
    a[2] := u8((szPayload shr 16) and $FF);
    a[3] := u8((szPayload shr 8) and $FF);
    a[4] := u8(szPayload and $FF);
    pParse^.nBlob := pParse^.nBlob + 5;
  end;
  if aPayload <> nil then
  begin
    pParse^.nBlob := pParse^.nBlob + u32(szPayload);
    Move(aPayload^, pParse^.aBlob[pParse^.nBlob - u32(szPayload)],
         szPayload);
  end;
end;

function jsonBlobChangePayloadSize(pParse: PJsonParse; i: u32;
                                   szPayload: u32): i32;
var
  a       : PByte;
  szType  : u8;
  nExtra  : u8;
  nNeeded : u8;
  delta   : i32;
  newSize : u32;
begin
  if pParse^.oom <> 0 then begin Result := 0; Exit; end;
  a := @pParse^.aBlob[i];
  szType := a[0] shr 4;
  if szType <= 11 then nExtra := 0
  else if szType = 12 then nExtra := 1
  else if szType = 13 then nExtra := 2
  else if szType = 14 then nExtra := 4
  else nExtra := 8;
  if szPayload <= 11 then nNeeded := 0
  else if szPayload <= $FF then nNeeded := 1
  else if szPayload <= $FFFF then nNeeded := 2
  else nNeeded := 4;
  delta := i32(nNeeded) - i32(nExtra);
  if delta <> 0 then
  begin
    newSize := u32(i64(pParse^.nBlob) + delta);
    if delta > 0 then
    begin
      if (newSize > pParse^.nBlobAlloc)
         and (jsonBlobExpand(pParse, newSize) <> 0) then
      begin
        Result := 0;
        Exit;
      end;
      a := @pParse^.aBlob[i];
      Move(a[1], a[1 + delta], pParse^.nBlob - (i + 1));
    end
    else
    begin
      Move(a[1 - delta], a[1], pParse^.nBlob - (i + 1 - u32(-delta)));
    end;
    pParse^.nBlob := newSize;
  end;
  if nNeeded = 0 then
    a[0] := (a[0] and $0F) or u8(szPayload shl 4)
  else if nNeeded = 1 then
  begin
    a[0] := (a[0] and $0F) or $C0;
    a[1] := u8(szPayload and $FF);
  end
  else if nNeeded = 2 then
  begin
    a[0] := (a[0] and $0F) or $D0;
    a[1] := u8((szPayload shr 8) and $FF);
    a[2] := u8(szPayload and $FF);
  end
  else
  begin
    a[0] := (a[0] and $0F) or $E0;
    a[1] := u8((szPayload shr 24) and $FF);
    a[2] := u8((szPayload shr 16) and $FF);
    a[3] := u8((szPayload shr 8) and $FF);
    a[4] := u8(szPayload and $FF);
  end;
  Result := delta;
end;

function jsonbPayloadSize(pParse: PJsonParse; i: u32; out pSz: u32): u32;
var
  x  : u8;
  sz : u32;
  n  : u32;
begin
  x := pParse^.aBlob[i] shr 4;
  if x <= 11 then
  begin
    sz := x;
    n := 1;
  end
  else if x = 12 then
  begin
    if i + 1 >= pParse^.nBlob then
    begin
      pSz := 0;
      Result := 0;
      Exit;
    end;
    sz := pParse^.aBlob[i + 1];
    n := 2;
  end
  else if x = 13 then
  begin
    if i + 2 >= pParse^.nBlob then
    begin
      pSz := 0;
      Result := 0;
      Exit;
    end;
    sz := (u32(pParse^.aBlob[i + 1]) shl 8) + pParse^.aBlob[i + 2];
    n := 3;
  end
  else if x = 14 then
  begin
    if i + 4 >= pParse^.nBlob then
    begin
      pSz := 0;
      Result := 0;
      Exit;
    end;
    sz := (u32(pParse^.aBlob[i + 1]) shl 24)
        + (u32(pParse^.aBlob[i + 2]) shl 16)
        + (u32(pParse^.aBlob[i + 3]) shl 8)
        +  u32(pParse^.aBlob[i + 4]);
    n := 5;
  end
  else
  begin
    if (i + 8 >= pParse^.nBlob)
       or (pParse^.aBlob[i + 1] <> 0)
       or (pParse^.aBlob[i + 2] <> 0)
       or (pParse^.aBlob[i + 3] <> 0)
       or (pParse^.aBlob[i + 4] <> 0) then
    begin
      pSz := 0;
      Result := 0;
      Exit;
    end;
    sz := (u32(pParse^.aBlob[i + 5]) shl 24)
        + (u32(pParse^.aBlob[i + 6]) shl 16)
        + (u32(pParse^.aBlob[i + 7]) shl 8)
        +  u32(pParse^.aBlob[i + 8]);
    n := 9;
  end;
  if (i64(i) + sz + n > i64(pParse^.nBlob))
     and (i64(i) + sz + n > i64(pParse^.nBlob) - i64(pParse^.delta)) then
  begin
    pSz := 0;
    Result := 0;
    Exit;
  end;
  pSz := sz;
  Result := n;
end;

function jsonbArrayCount(pParse: PJsonParse; iRoot: u32): u32;
var
  n, sz, i, iEnd, k : u32;
begin
  k := 0;
  sz := 0;
  n := jsonbPayloadSize(pParse, iRoot, sz);
  iEnd := iRoot + n + sz;
  i := iRoot + n;
  while (n > 0) and (i < iEnd) do
  begin
    n := jsonbPayloadSize(pParse, i, sz);
    i := i + sz + n;
    Inc(k);
  end;
  Result := k;
end;

procedure jsonAfterEditSizeAdjust(pParse: PJsonParse; iRoot: u32);
var
  sz, nBlob : u32;
begin
  sz := 0;
  nBlob := pParse^.nBlob;
  pParse^.nBlob := pParse^.nBlobAlloc;
  jsonbPayloadSize(pParse, iRoot, sz);
  pParse^.nBlob := nBlob;
  sz := u32(i64(sz) + i64(pParse^.delta));
  pParse^.delta := pParse^.delta
                 + jsonBlobChangePayloadSize(pParse, iRoot, sz);
end;

function jsonBlobOverwrite(aOut: PByte; aIns: PByte; nIns: u32;
                           d: u32): i32;
const
  aType : array[0..7] of u8 = ($C0, $D0, 0, $E0, 0, 0, 0, $F0);
var
  szPayload : u32;
  i         : u32;
  szHdr     : u8;
begin
  if (aIns[0] and $0F) <= 2 then begin Result := 0; Exit; end;
  case aIns[0] shr 4 of
    12:
    begin
      if ((1 shl d) and $8A) = 0 then begin Result := 0; Exit; end;
      i := d + 2;
      szHdr := 2;
    end;
    13:
    begin
      if (d <> 2) and (d <> 6) then begin Result := 0; Exit; end;
      i := d + 3;
      szHdr := 3;
    end;
    14:
    begin
      if d <> 4 then begin Result := 0; Exit; end;
      i := 9;
      szHdr := 5;
    end;
    15:
    begin
      Result := 0;
      Exit;
    end;
  else
    begin
      if ((1 shl d) and $116) = 0 then begin Result := 0; Exit; end;
      i := d + 1;
      szHdr := 1;
    end;
  end;
  aOut[0] := (aIns[0] and $0F) or aType[i - 2];
  Move(aIns[szHdr], aOut[i], nIns - szHdr);
  szPayload := nIns - szHdr;
  while True do
  begin
    Dec(i);
    aOut[i] := u8(szPayload and $FF);
    if i = 1 then Break;
    szPayload := szPayload shr 8;
  end;
  Result := 1;
end;

procedure jsonBlobEdit(pParse: PJsonParse; iDel, nDel: u32;
                       aIns: PByte; nIns: u32);
var
  d : i64;
begin
  d := i64(nIns) - i64(nDel);
  if (d < 0) and (d >= -8) and (aIns <> nil)
     and (jsonBlobOverwrite(@pParse^.aBlob[iDel], aIns, nIns, u32(-d)) <> 0)
  then Exit;
  if d <> 0 then
  begin
    if i64(pParse^.nBlob) + d > i64(pParse^.nBlobAlloc) then
    begin
      jsonBlobExpand(pParse, u32(i64(pParse^.nBlob) + d));
      if pParse^.oom <> 0 then Exit;
    end;
    Move(pParse^.aBlob[iDel + nDel],
         pParse^.aBlob[iDel + nIns],
         pParse^.nBlob - (iDel + nDel));
    pParse^.nBlob := u32(i64(pParse^.nBlob) + d);
    pParse^.delta := pParse^.delta + i32(d);
  end;
  if (nIns <> 0) and (aIns <> nil) then
    Move(aIns^, pParse^.aBlob[iDel], nIns);
end;

{ ===========================================================================
  Phase 6.8.d implementation
  =========================================================================== }

procedure jsonParseReset(pParse: PJsonParse);
begin
  { RCStr branch deferred (sqlite3RCStrUnref not yet ported).  zJson
    ownership for non-RCStr inputs is the caller's; we only release the
    JSONB allocation here. }
  if pParse^.bJsonIsRCStr <> 0 then
  begin
    { TODO 6.8.h: sqlite3RCStrUnref(pParse^.zJson) when RCStr lands. }
    pParse^.zJson := nil;
    pParse^.nJson := 0;
    pParse^.bJsonIsRCStr := 0;
  end;
  if pParse^.nBlobAlloc <> 0 then
  begin
    sqlite3DbFree(pParse^.db, pParse^.aBlob);
    pParse^.aBlob := nil;
    pParse^.nBlob := 0;
    pParse^.nBlobAlloc := 0;
  end;
end;

function jsonIs4HexB(z: PAnsiChar; var pOp: i32): i32;
begin
  if z[0] <> 'u' then begin Result := 0; Exit; end;
  if jsonIs4Hex(z + 1) = 0 then begin Result := 0; Exit; end;
  pOp := JSONB_TEXTJ;
  Result := 1;
end;

function jsonBytesToBypass(z: PAnsiChar; n: u32): u32;
var
  i : u32;
  zb: PByte;
begin
  i := 0;
  zb := PByte(z);
  while i + 1 < n do
  begin
    if zb[i] <> Ord('\') then begin Result := i; Exit; end;
    if zb[i + 1] = $0A then       { '\n' }
    begin
      i := i + 2;
      Continue;
    end;
    if zb[i + 1] = $0D then       { '\r' }
    begin
      if (i + 2 < n) and (zb[i + 2] = $0A) then
        i := i + 3
      else
        i := i + 2;
      Continue;
    end;
    if (zb[i + 1] = $E2) and (i + 3 < n) and (zb[i + 2] = $80)
       and ((zb[i + 3] = $A8) or (zb[i + 3] = $A9)) then
    begin
      i := i + 4;
      Continue;
    end;
    Break;
  end;
  Result := i;
end;

function jsonUnescapeOneChar(z: PAnsiChar; n: u32; out piOut: u32): u32;
var
  v, vlo : u32;
  nSkip  : u32;
  sz     : i32;
  zb     : PByte;
begin
  if n < 2 then
  begin
    piOut := JSON_INVALID_CHAR;
    Result := n;
    Exit;
  end;
  zb := PByte(z);
  case zb[1] of
    Ord('u'):
    begin
      if n < 6 then
      begin
        piOut := JSON_INVALID_CHAR;
        Result := n;
        Exit;
      end;
      v := jsonHexToInt4(z + 2);
      if ((v and $FC00) = $D800)
         and (n >= 12)
         and (zb[6] = Ord('\'))
         and (zb[7] = Ord('u')) then
      begin
        vlo := jsonHexToInt4(z + 8);
        if (vlo and $FC00) = $DC00 then
        begin
          piOut := ((v and $3FF) shl 10) + (vlo and $3FF) + $10000;
          Result := 12;
          Exit;
        end;
      end;
      piOut := v;
      Result := 6;
    end;
    Ord('b'): begin piOut := $08; Result := 2; end;
    Ord('f'): begin piOut := $0C; Result := 2; end;
    Ord('n'): begin piOut := $0A; Result := 2; end;
    Ord('r'): begin piOut := $0D; Result := 2; end;
    Ord('t'): begin piOut := $09; Result := 2; end;
    Ord('v'): begin piOut := $0B; Result := 2; end;
    Ord('0'):
    begin
      { Correct (non-bug-compatible) JSON5 \0: invalid if next is digit. }
      if (n > 2) and (sqlite3Isdigit(PByte(z)[2]) <> 0) then
        piOut := JSON_INVALID_CHAR
      else
        piOut := 0;
      Result := 2;
    end;
    Ord(''''), Ord('"'), Ord('/'), Ord('\'):
    begin
      piOut := zb[1];
      Result := 2;
    end;
    Ord('x'):
    begin
      if n < 4 then
      begin
        piOut := JSON_INVALID_CHAR;
        Result := n;
        Exit;
      end;
      piOut := (u32(jsonHexToInt(zb[2])) shl 4) or jsonHexToInt(zb[3]);
      Result := 4;
    end;
    $E2, $0D, $0A:
    begin
      nSkip := jsonBytesToBypass(z, n);
      if nSkip = 0 then
      begin
        piOut := JSON_INVALID_CHAR;
        Result := n;
      end
      else if nSkip = n then
      begin
        piOut := 0;
        Result := n;
      end
      else if PByte(z)[nSkip] = Ord('\') then
        Result := nSkip
                + jsonUnescapeOneChar(z + nSkip, n - nSkip, piOut)
      else
      begin
        sz := sqlite3Utf8ReadLimited(Pu8(z + nSkip),
                                     i32(n - nSkip), piOut);
        Result := nSkip + u32(sz);
      end;
    end;
    else
    begin
      piOut := JSON_INVALID_CHAR;
      Result := 2;
    end;
  end;
end;

function jsonbValidityCheck(pParse: PJsonParse;
                            i, iEnd, iDepth: u32): u32;
var
  n, sz, j, k, sub, cnt, c, szC : u32;
  z   : PByte;
  x   : u8;
  seen: u8;
begin
  if iDepth > JSON_MAX_DEPTH then begin Result := i + 1; Exit; end;
  sz := 0;
  n := jsonbPayloadSize(pParse, i, sz);
  if n = 0 then begin Result := i + 1; Exit; end;
  if i + n + sz <> iEnd then begin Result := i + 1; Exit; end;
  z := pParse^.aBlob;
  x := z[i] and $0F;
  case x of
    JSONB_NULL, JSONB_TRUE, JSONB_FALSE:
    begin
      if n + sz = 1 then Result := 0 else Result := i + 1;
      Exit;
    end;
    JSONB_INT:
    begin
      if sz < 1 then begin Result := i + 1; Exit; end;
      j := i + n;
      if z[j] = Ord('-') then
      begin
        Inc(j);
        if sz < 2 then begin Result := i + 1; Exit; end;
      end;
      k := i + n + sz;
      while j < k do
      begin
        if sqlite3Isdigit(z[j]) <> 0 then
          Inc(j)
        else
        begin
          Result := j + 1;
          Exit;
        end;
      end;
      Result := 0;
    end;
    JSONB_INT5:
    begin
      if sz < 3 then begin Result := i + 1; Exit; end;
      j := i + n;
      if z[j] = Ord('-') then
      begin
        if sz < 4 then begin Result := i + 1; Exit; end;
        Inc(j);
      end;
      if z[j] <> Ord('0') then begin Result := i + 1; Exit; end;
      if (z[j + 1] <> Ord('x')) and (z[j + 1] <> Ord('X')) then
      begin
        Result := j + 2;
        Exit;
      end;
      j := j + 2;
      k := i + n + sz;
      while j < k do
      begin
        if sqlite3Isxdigit(z[j]) <> 0 then
          Inc(j)
        else
        begin
          Result := j + 1;
          Exit;
        end;
      end;
      Result := 0;
    end;
    JSONB_FLOAT, JSONB_FLOAT5:
    begin
      seen := 0;
      if sz < 2 then begin Result := i + 1; Exit; end;
      j := i + n;
      k := j + sz;
      if z[j] = Ord('-') then
      begin
        Inc(j);
        if sz < 3 then begin Result := i + 1; Exit; end;
      end;
      if z[j] = Ord('.') then
      begin
        if x = JSONB_FLOAT then begin Result := j + 1; Exit; end;
        if sqlite3Isdigit(z[j + 1]) = 0 then begin Result := j + 1; Exit; end;
        j := j + 2;
        seen := 1;
      end
      else if (z[j] = Ord('0')) and (x = JSONB_FLOAT) then
      begin
        if j + 3 > k then begin Result := j + 1; Exit; end;
        if (z[j + 1] <> Ord('.'))
           and (z[j + 1] <> Ord('e'))
           and (z[j + 1] <> Ord('E')) then
        begin
          Result := j + 1;
          Exit;
        end;
        Inc(j);
      end;
      while j < k do
      begin
        if sqlite3Isdigit(z[j]) <> 0 then begin Inc(j); Continue; end;
        if z[j] = Ord('.') then
        begin
          if seen > 0 then begin Result := j + 1; Exit; end;
          if (x = JSONB_FLOAT)
             and ((j = k - 1) or (sqlite3Isdigit(z[j + 1]) = 0)) then
          begin
            Result := j + 1;
            Exit;
          end;
          seen := 1;
          Inc(j);
          Continue;
        end;
        if (z[j] = Ord('e')) or (z[j] = Ord('E')) then
        begin
          if seen = 2 then begin Result := j + 1; Exit; end;
          if j = k - 1 then begin Result := j + 1; Exit; end;
          if (z[j + 1] = Ord('+')) or (z[j + 1] = Ord('-')) then
          begin
            Inc(j);
            if j = k - 1 then begin Result := j + 1; Exit; end;
          end;
          seen := 2;
          Inc(j);
          Continue;
        end;
        Result := j + 1;
        Exit;
      end;
      if seen = 0 then begin Result := i + 1; Exit; end;
      Result := 0;
    end;
    JSONB_TEXT:
    begin
      j := i + n;
      k := j + sz;
      while j < k do
      begin
        if (jsonIsOk[z[j]] = 0) and (z[j] <> Ord('''')) then
        begin
          Result := j + 1;
          Exit;
        end;
        Inc(j);
      end;
      Result := 0;
    end;
    JSONB_TEXTJ, JSONB_TEXT5:
    begin
      j := i + n;
      k := j + sz;
      while j < k do
      begin
        if (jsonIsOk[z[j]] = 0) and (z[j] <> Ord('''')) then
        begin
          if z[j] = Ord('"') then
          begin
            if x = JSONB_TEXTJ then begin Result := j + 1; Exit; end;
          end
          else if z[j] <= $1F then
          begin
            if x = JSONB_TEXTJ then begin Result := j + 1; Exit; end;
          end
          else if (z[j] <> Ord('\')) or (j + 1 >= k) then
          begin
            Result := j + 1;
            Exit;
          end
          else if (z[j + 1] = Ord('"')) or (z[j + 1] = Ord('\'))
               or (z[j + 1] = Ord('/'))
               or (z[j + 1] = Ord('b')) or (z[j + 1] = Ord('f'))
               or (z[j + 1] = Ord('n')) or (z[j + 1] = Ord('r'))
               or (z[j + 1] = Ord('t')) then
            Inc(j)
          else if z[j + 1] = Ord('u') then
          begin
            if j + 5 >= k then begin Result := j + 1; Exit; end;
            if jsonIs4Hex(PAnsiChar(@z[j + 2])) = 0 then
            begin
              Result := j + 1;
              Exit;
            end;
            Inc(j);
          end
          else if x <> JSONB_TEXT5 then
          begin
            Result := j + 1;
            Exit;
          end
          else
          begin
            c := 0;
            szC := jsonUnescapeOneChar(PAnsiChar(@z[j]), k - j, c);
            if c = JSON_INVALID_CHAR then
            begin
              Result := j + 1;
              Exit;
            end;
            j := j + szC - 1;
          end;
        end;
        Inc(j);
      end;
      Result := 0;
    end;
    JSONB_TEXTRAW:
    begin
      Result := 0;
    end;
    JSONB_ARRAY:
    begin
      j := i + n;
      k := j + sz;
      while j < k do
      begin
        sz := 0;
        n := jsonbPayloadSize(pParse, j, sz);
        if n = 0 then begin Result := j + 1; Exit; end;
        if j + n + sz > k then begin Result := j + 1; Exit; end;
        sub := jsonbValidityCheck(pParse, j, j + n + sz, iDepth + 1);
        if sub <> 0 then begin Result := sub; Exit; end;
        j := j + n + sz;
      end;
      Result := 0;
    end;
    JSONB_OBJECT:
    begin
      cnt := 0;
      j := i + n;
      k := j + sz;
      while j < k do
      begin
        sz := 0;
        n := jsonbPayloadSize(pParse, j, sz);
        if n = 0 then begin Result := j + 1; Exit; end;
        if j + n + sz > k then begin Result := j + 1; Exit; end;
        if (cnt and 1) = 0 then
        begin
          x := z[j] and $0F;
          if (x < JSONB_TEXT) or (x > JSONB_TEXTRAW) then
          begin
            Result := j + 1;
            Exit;
          end;
        end;
        sub := jsonbValidityCheck(pParse, j, j + n + sz, iDepth + 1);
        if sub <> 0 then begin Result := sub; Exit; end;
        Inc(cnt);
        j := j + n + sz;
      end;
      if (cnt and 1) <> 0 then begin Result := j + 1; Exit; end;
      Result := 0;
    end;
    else
      Result := i + 1;
  end;
end;

function jsonLabelCompareEscaped(zLeft: PAnsiChar; nLeft: u32; rawLeft: i32;
                                 zRight: PAnsiChar; nRight: u32;
                                 rawRight: i32): i32;
var
  cLeft, cRight : u32;
  sz            : i32;
  n             : u32;
begin
  while True do
  begin
    if nLeft = 0 then
      cLeft := 0
    else if (rawLeft <> 0) or (zLeft[0] <> '\') then
    begin
      cLeft := PByte(zLeft)[0];
      if cLeft >= $C0 then
      begin
        sz := sqlite3Utf8ReadLimited(Pu8(zLeft), i32(nLeft), cLeft);
        zLeft := zLeft + sz;
        nLeft := nLeft - u32(sz);
      end
      else
      begin
        Inc(zLeft);
        Dec(nLeft);
      end;
    end
    else
    begin
      n := jsonUnescapeOneChar(zLeft, nLeft, cLeft);
      zLeft := zLeft + n;
      nLeft := nLeft - n;
    end;
    if nRight = 0 then
      cRight := 0
    else if (rawRight <> 0) or (zRight[0] <> '\') then
    begin
      cRight := PByte(zRight)[0];
      if cRight >= $C0 then
      begin
        sz := sqlite3Utf8ReadLimited(Pu8(zRight), i32(nRight), cRight);
        zRight := zRight + sz;
        nRight := nRight - u32(sz);
      end
      else
      begin
        Inc(zRight);
        Dec(nRight);
      end;
    end
    else
    begin
      n := jsonUnescapeOneChar(zRight, nRight, cRight);
      zRight := zRight + n;
      nRight := nRight - n;
    end;
    if cLeft <> cRight then begin Result := 0; Exit; end;
    if cLeft = 0 then begin Result := 1; Exit; end;
  end;
end;

function jsonLabelCompare(zLeft: PAnsiChar; nLeft: u32; rawLeft: i32;
                          zRight: PAnsiChar; nRight: u32; rawRight: i32): i32;
begin
  if (rawLeft <> 0) and (rawRight <> 0) then
  begin
    if nLeft <> nRight then begin Result := 0; Exit; end;
    if (nLeft = 0) or (CompareByte(zLeft^, zRight^, nLeft) = 0) then
      Result := 1
    else
      Result := 0;
  end
  else
    Result := jsonLabelCompareEscaped(zLeft, nLeft, rawLeft,
                                      zRight, nRight, rawRight);
end;

function jsonTranslateTextToBlob(pParse: PJsonParse; i: u32): i32;
label
  json_parse_restart, parse_number,
  parse_number_2, parse_number_finish, parse_object_value;
var
  c       : AnsiChar;
  j, k, kk: u32;
  iThis,
  iStart,
  iBlob   : u32;
  x       : i32;
  t       : u8;
  z       : PAnsiChar;
  zb      : PByte;
  opcode  : u8;
  cDelim  : AnsiChar;
  seenE   : u8;
  nn      : i32;
  op      : i32;
begin
  z  := pParse^.zJson;
  zb := PByte(z);

json_parse_restart:
  case zb[i] of
    Ord('{'):
    begin
      iThis := pParse^.nBlob;
      jsonBlobAppendNode(pParse, JSONB_OBJECT, u64(pParse^.nJson) - i, nil);
      Inc(pParse^.iDepth);
      if pParse^.iDepth > JSON_MAX_DEPTH then
      begin
        pParse^.iErr := i;
        Result := -1;
        Exit;
      end;
      iStart := pParse^.nBlob;
      j := i + 1;
      while True do
      begin
        iBlob := pParse^.nBlob;
        x := jsonTranslateTextToBlob(pParse, j);
        if x <= 0 then
        begin
          if x = -2 then
          begin
            j := pParse^.iErr;
            if pParse^.nBlob <> iStart then pParse^.hasNonstd := 1;
            Break;
          end;
          j := j + u32(json5Whitespace(z + j));
          op := JSONB_TEXT;
          if (sqlite3CtypeMap[zb[j]] and $42) <> 0 then
          begin
            { sqlite3JsonId1 hit — fall through to identifier scan }
          end
          else if not ((z[j] = '\') and (jsonIs4HexB(z + j + 1, op) <> 0)) then
          begin
            if x <> -1 then pParse^.iErr := j;
            Result := -1;
            Exit;
          end;
          k := j + 1;
          while ((sqlite3CtypeMap[zb[k]] and $46) <> 0)
                and (json5Whitespace(z + k) = 0)
             or ((z[k] = '\') and (jsonIs4HexB(z + k + 1, op) <> 0))
          do
            Inc(k);
          jsonBlobAppendNode(pParse, op, k - j, z + j);
          pParse^.hasNonstd := 1;
          x := i32(k);
        end;
        if pParse^.oom <> 0 then begin Result := -1; Exit; end;
        t := pParse^.aBlob[iBlob] and $0F;
        if (t < JSONB_TEXT) or (t > JSONB_TEXTRAW) then
        begin
          pParse^.iErr := j;
          Result := -1;
          Exit;
        end;
        j := u32(x);
        if z[j] = ':' then
          Inc(j)
        else
        begin
          if jsonIsspace(z[j]) <> 0 then
          begin
            repeat Inc(j); until jsonIsspace(z[j]) = 0;
            if z[j] = ':' then
            begin
              Inc(j);
              goto parse_object_value;
            end;
          end;
          x := jsonTranslateTextToBlob(pParse, j);
          if x <> -5 then
          begin
            if x <> -1 then pParse^.iErr := j;
            Result := -1;
            Exit;
          end;
          j := pParse^.iErr + 1;
        end;
      parse_object_value:
        x := jsonTranslateTextToBlob(pParse, j);
        if x <= 0 then
        begin
          if x <> -1 then pParse^.iErr := j;
          Result := -1;
          Exit;
        end;
        j := u32(x);
        if z[j] = ',' then
        begin
          Inc(j);
          Continue;
        end
        else if z[j] = '}' then
          Break
        else
        begin
          if jsonIsspace(z[j]) <> 0 then
          begin
            Inc(j);
            while aJsonIsSpace[zb[j]] <> 0 do Inc(j);
            if z[j] = ',' then begin Inc(j); Continue; end;
            if z[j] = '}' then Break;
          end;
          x := jsonTranslateTextToBlob(pParse, j);
          if x = -4 then
          begin
            j := pParse^.iErr + 1;
            Continue;
          end;
          if x = -2 then
          begin
            j := pParse^.iErr;
            Break;
          end;
        end;
        pParse^.iErr := j;
        Result := -1;
        Exit;
      end;
      jsonBlobChangePayloadSize(pParse, iThis, pParse^.nBlob - iStart);
      Dec(pParse^.iDepth);
      Result := i32(j + 1);
      Exit;
    end;
    Ord('['):
    begin
      iThis := pParse^.nBlob;
      jsonBlobAppendNode(pParse, JSONB_ARRAY, u64(pParse^.nJson) - i, nil);
      iStart := pParse^.nBlob;
      if pParse^.oom <> 0 then begin Result := -1; Exit; end;
      Inc(pParse^.iDepth);
      if pParse^.iDepth > JSON_MAX_DEPTH then
      begin
        pParse^.iErr := i;
        Result := -1;
        Exit;
      end;
      j := i + 1;
      while True do
      begin
        x := jsonTranslateTextToBlob(pParse, j);
        if x <= 0 then
        begin
          if x = -3 then
          begin
            j := pParse^.iErr;
            if pParse^.nBlob <> iStart then pParse^.hasNonstd := 1;
            Break;
          end;
          if x <> -1 then pParse^.iErr := j;
          Result := -1;
          Exit;
        end;
        j := u32(x);
        if z[j] = ',' then
        begin
          Inc(j);
          Continue;
        end
        else if z[j] = ']' then
          Break
        else
        begin
          if jsonIsspace(z[j]) <> 0 then
          begin
            Inc(j);
            while aJsonIsSpace[zb[j]] <> 0 do Inc(j);
            if z[j] = ',' then begin Inc(j); Continue; end;
            if z[j] = ']' then Break;
          end;
          x := jsonTranslateTextToBlob(pParse, j);
          if x = -4 then
          begin
            j := pParse^.iErr + 1;
            Continue;
          end;
          if x = -3 then
          begin
            j := pParse^.iErr;
            Break;
          end;
        end;
        pParse^.iErr := j;
        Result := -1;
        Exit;
      end;
      jsonBlobChangePayloadSize(pParse, iThis, pParse^.nBlob - iStart);
      Dec(pParse^.iDepth);
      Result := i32(j + 1);
      Exit;
    end;
    Ord(''''), Ord('"'):
    begin
      if z[i] = '''' then pParse^.hasNonstd := 1;
      opcode := JSONB_TEXT;
      cDelim := z[i];
      j := i + 1;
      while True do
      begin
        if jsonIsOk[zb[j]] <> 0 then
        begin
          if jsonIsOk[zb[j + 1]] = 0 then
            j := j + 1
          else if jsonIsOk[zb[j + 2]] = 0 then
            j := j + 2
          else
          begin
            j := j + 3;
            Continue;
          end;
        end;
        c := z[j];
        if c = cDelim then
          Break
        else if c = '\' then
        begin
          Inc(j);
          c := z[j];
          if (c = '"') or (c = '\') or (c = '/') or (c = 'b') or (c = 'f')
             or (c = 'n') or (c = 'r') or (c = 't')
             or ((c = 'u') and (jsonIs4Hex(z + j + 1) <> 0)) then
          begin
            if opcode = JSONB_TEXT then opcode := JSONB_TEXTJ;
          end
          else if (c = '''') or (c = 'v') or (c = #10)
               or ((c = '0') and (sqlite3Isdigit(zb[j + 1]) = 0))
               or ((zb[j] = $E2) and (zb[j + 1] = $80)
                   and ((zb[j + 2] = $A8) or (zb[j + 2] = $A9)))
               or ((c = 'x') and (jsonIs2Hex(z + j + 1) <> 0)) then
          begin
            opcode := JSONB_TEXT5;
            pParse^.hasNonstd := 1;
          end
          else if c = #13 then
          begin
            if z[j + 1] = #10 then Inc(j);
            opcode := JSONB_TEXT5;
            pParse^.hasNonstd := 1;
          end
          else
          begin
            pParse^.iErr := j;
            Result := -1;
            Exit;
          end;
        end
        else if zb[j] <= $1F then
        begin
          if zb[j] = 0 then
          begin
            pParse^.iErr := j;
            Result := -1;
            Exit;
          end;
          opcode := JSONB_TEXT5;
          pParse^.hasNonstd := 1;
        end
        else if c = '"' then
        begin
          opcode := JSONB_TEXT5;
        end;
        Inc(j);
      end;
      jsonBlobAppendNode(pParse, opcode, j - 1 - i, z + i + 1);
      Result := i32(j + 1);
      Exit;
    end;
    Ord('t'):
    begin
      if (CompareByte((z + i)^, 'true', 4) = 0)
         and (sqlite3Isalnum(zb[i + 4]) = 0) then
      begin
        jsonBlobAppendOneByte(pParse, JSONB_TRUE);
        Result := i32(i + 4);
        Exit;
      end;
      pParse^.iErr := i;
      Result := -1;
      Exit;
    end;
    Ord('f'):
    begin
      if (CompareByte((z + i)^, 'false', 5) = 0)
         and (sqlite3Isalnum(zb[i + 5]) = 0) then
      begin
        jsonBlobAppendOneByte(pParse, JSONB_FALSE);
        Result := i32(i + 5);
        Exit;
      end;
      pParse^.iErr := i;
      Result := -1;
      Exit;
    end;
    Ord('+'), Ord('.'),
    Ord('-'), Ord('0'), Ord('1'), Ord('2'), Ord('3'), Ord('4'),
    Ord('5'), Ord('6'), Ord('7'), Ord('8'), Ord('9'):
    begin
      if z[i] = '+' then
      begin
        pParse^.hasNonstd := 1;
        t := $00;
        goto parse_number;
      end
      else if z[i] = '.' then
      begin
        if sqlite3Isdigit(zb[i + 1]) <> 0 then
        begin
          pParse^.hasNonstd := 1;
          t := $03;
          seenE := 0;
          goto parse_number_2;
        end;
        pParse^.iErr := i;
        Result := -1;
        Exit;
      end;
      t := $00;
parse_number:
      seenE := 0;
      c := z[i];
      if c <= '0' then
      begin
        if c = '0' then
        begin
          if ((z[i + 1] = 'x') or (z[i + 1] = 'X'))
             and (sqlite3Isxdigit(zb[i + 2]) <> 0) then
          begin
            pParse^.hasNonstd := 1;
            t := $01;
            j := i + 3;
            while sqlite3Isxdigit(zb[j]) <> 0 do Inc(j);
            goto parse_number_finish;
          end
          else if sqlite3Isdigit(zb[i + 1]) <> 0 then
          begin
            pParse^.iErr := i + 1;
            Result := -1;
            Exit;
          end;
        end
        else
        begin
          if sqlite3Isdigit(zb[i + 1]) = 0 then
          begin
            if ((z[i + 1] = 'I') or (z[i + 1] = 'i'))
               and (sqlite3_strnicmp(z + i + 1, 'inf', 3) = 0) then
            begin
              pParse^.hasNonstd := 1;
              if z[i] = '-' then
                jsonBlobAppendNode(pParse, JSONB_FLOAT, 6, PAnsiChar('-9e999'))
              else
                jsonBlobAppendNode(pParse, JSONB_FLOAT, 5, PAnsiChar('9e999'));
              if sqlite3_strnicmp(z + i + 4, 'inity', 5) = 0 then
                Result := i32(i + 9)
              else
                Result := i32(i + 4);
              Exit;
            end;
            if z[i + 1] = '.' then
            begin
              pParse^.hasNonstd := 1;
              t := t or $01;
              goto parse_number_2;
            end;
            pParse^.iErr := i;
            Result := -1;
            Exit;
          end;
          if z[i + 1] = '0' then
          begin
            if sqlite3Isdigit(zb[i + 2]) <> 0 then
            begin
              pParse^.iErr := i + 1;
              Result := -1;
              Exit;
            end
            else if ((z[i + 2] = 'x') or (z[i + 2] = 'X'))
                 and (sqlite3Isxdigit(zb[i + 3]) <> 0) then
            begin
              pParse^.hasNonstd := 1;
              t := t or $01;
              j := i + 4;
              while sqlite3Isxdigit(zb[j]) <> 0 do Inc(j);
              goto parse_number_finish;
            end;
          end;
        end;
      end;
parse_number_2:
      j := i + 1;
      while True do
      begin
        c := z[j];
        if sqlite3Isdigit(zb[j]) <> 0 then begin Inc(j); Continue; end;
        if c = '.' then
        begin
          if (t and $02) <> 0 then
          begin
            pParse^.iErr := j;
            Result := -1;
            Exit;
          end;
          t := t or $02;
          Inc(j);
          Continue;
        end;
        if (c = 'e') or (c = 'E') then
        begin
          if zb[j - 1] < Ord('0') then
          begin
            if (z[j - 1] = '.') and (j - 2 >= i)
               and (sqlite3Isdigit(zb[j - 2]) <> 0) then
            begin
              pParse^.hasNonstd := 1;
              t := t or $01;
            end
            else
            begin
              pParse^.iErr := j;
              Result := -1;
              Exit;
            end;
          end;
          if seenE <> 0 then
          begin
            pParse^.iErr := j;
            Result := -1;
            Exit;
          end;
          t := t or $02;
          seenE := 1;
          c := z[j + 1];
          if (c = '+') or (c = '-') then
          begin
            Inc(j);
            c := z[j + 1];
          end;
          if (c < '0') or (c > '9') then
          begin
            pParse^.iErr := j;
            Result := -1;
            Exit;
          end;
          Inc(j);
          Continue;
        end;
        Break;
      end;
      if zb[j - 1] < Ord('0') then
      begin
        if (z[j - 1] = '.') and (j - 2 >= i)
           and (sqlite3Isdigit(zb[j - 2]) <> 0) then
        begin
          pParse^.hasNonstd := 1;
          t := t or $01;
        end
        else
        begin
          pParse^.iErr := j;
          Result := -1;
          Exit;
        end;
      end;
parse_number_finish:
      if z[i] = '+' then Inc(i);
      jsonBlobAppendNode(pParse, JSONB_INT + t, j - i, z + i);
      Result := i32(j);
      Exit;
    end;
    Ord('}'):
    begin
      pParse^.iErr := i;
      Result := -2;
      Exit;
    end;
    Ord(']'):
    begin
      pParse^.iErr := i;
      Result := -3;
      Exit;
    end;
    Ord(','):
    begin
      pParse^.iErr := i;
      Result := -4;
      Exit;
    end;
    Ord(':'):
    begin
      pParse^.iErr := i;
      Result := -5;
      Exit;
    end;
    0:
    begin
      Result := 0;
      Exit;
    end;
    $09, $0A, $0D, $20:
    begin
      Inc(i);
      while aJsonIsSpace[zb[i]] <> 0 do Inc(i);
      goto json_parse_restart;
    end;
    $0B, $0C, Ord('/'), $C2, $E1, $E2, $E3, $EF:
    begin
      j := u32(json5Whitespace(z + i));
      if j > 0 then
      begin
        i := i + j;
        pParse^.hasNonstd := 1;
        goto json_parse_restart;
      end;
      pParse^.iErr := i;
      Result := -1;
      Exit;
    end;
    Ord('n'):
    begin
      if (CompareByte((z + i)^, 'null', 4) = 0)
         and (sqlite3Isalnum(zb[i + 4]) = 0) then
      begin
        jsonBlobAppendOneByte(pParse, JSONB_NULL);
        Result := i32(i + 4);
        Exit;
      end;
      { fall-through into NaN/Inf scan }
      c := z[i];
      for kk := 0 to High(aNanInfName) do
      begin
        if (c <> aNanInfName[kk].c1) and (c <> aNanInfName[kk].c2) then
          Continue;
        nn := aNanInfName[kk].n;
        if sqlite3_strnicmp(z + i, aNanInfName[kk].zMatch, nn) <> 0 then
          Continue;
        if sqlite3Isalnum(zb[i + u32(nn)]) <> 0 then Continue;
        if aNanInfName[kk].eType = JSONB_FLOAT then
          jsonBlobAppendNode(pParse, JSONB_FLOAT, 5, PAnsiChar('9e999'))
        else
          jsonBlobAppendOneByte(pParse, JSONB_NULL);
        pParse^.hasNonstd := 1;
        Result := i32(i + u32(nn));
        Exit;
      end;
      pParse^.iErr := i;
      Result := -1;
      Exit;
    end;
    else
    begin
      c := z[i];
      for kk := 0 to High(aNanInfName) do
      begin
        if (c <> aNanInfName[kk].c1) and (c <> aNanInfName[kk].c2) then
          Continue;
        nn := aNanInfName[kk].n;
        if sqlite3_strnicmp(z + i, aNanInfName[kk].zMatch, nn) <> 0 then
          Continue;
        if sqlite3Isalnum(zb[i + u32(nn)]) <> 0 then Continue;
        if aNanInfName[kk].eType = JSONB_FLOAT then
          jsonBlobAppendNode(pParse, JSONB_FLOAT, 5, PAnsiChar('9e999'))
        else
          jsonBlobAppendOneByte(pParse, JSONB_NULL);
        pParse^.hasNonstd := 1;
        Result := i32(i + u32(nn));
        Exit;
      end;
      pParse^.iErr := i;
      Result := -1;
      Exit;
    end;
  end;
end;

function jsonConvertTextToBlob(pParse: PJsonParse; pCtx: Pointer): i32;
var
  i     : i32;
  zJson : PAnsiChar;
begin
  zJson := pParse^.zJson;
  i := jsonTranslateTextToBlob(pParse, 0);
  if pParse^.oom <> 0 then i := -1;
  if i > 0 then
  begin
    while jsonIsspace(zJson[i]) <> 0 do Inc(i);
    if zJson[i] <> #0 then
    begin
      i := i + json5Whitespace(zJson + i);
      if zJson[i] <> #0 then
      begin
        { TODO 6.8.h: sqlite3_result_error(pCtx, 'malformed JSON', -1). }
        if pCtx <> nil then ;
        jsonParseReset(pParse);
        Result := 1;
        Exit;
      end;
      pParse^.hasNonstd := 1;
    end;
  end;
  if i <= 0 then
  begin
    { TODO 6.8.h: surface oom / 'malformed JSON' on pCtx. }
    if pCtx <> nil then ;
    jsonParseReset(pParse);
    Result := 1;
    Exit;
  end;
  Result := 0;
end;

{ ===========================================================================
  Phase 6.8.e implementation — blob→text + pretty
  =========================================================================== }

{
  Append decimal repr of u (or "9.0e999" if bOverflow) to the JsonString.
  Stand-in for json.c's jsonPrintf(100, pOut, ...) used in the INT5 arm of
  jsonTranslateBlobToText — that's the only call-site relevant to 6.8.e.
}
procedure jsonAppendU64Decimal(p: PJsonString; u: u64; bOverflow: i32);
var
  buf : array[0..31] of AnsiChar;
  k   : i32;
  rev : array[0..31] of AnsiChar;
  n   : i32;
begin
  if bOverflow <> 0 then
  begin
    jsonAppendRawNZ(p, '9.0e999', 7);
    Exit;
  end;
  if u = 0 then
  begin
    buf[0] := '0';
    jsonAppendRawNZ(p, @buf[0], 1);
    Exit;
  end;
  n := 0;
  while u > 0 do
  begin
    rev[n] := AnsiChar(Ord('0') + (u mod 10));
    u := u div 10;
    Inc(n);
  end;
  for k := 0 to n - 1 do
    buf[k] := rev[n - 1 - k];
  jsonAppendRawNZ(p, @buf[0], u32(n));
end;

function jsonTranslateBlobToText(pParse: PJsonParse; i: u32;
                                 pOut: PJsonString): u32;
label
  malformed_jsonb;
var
  sz, n, j, iEnd : u32;
  k              : u32;
  u              : u64;
  zIn            : PAnsiChar;
  bOverflow      : i32;
  sz2            : u32;
  x              : i32;
  b              : u8;
begin
  n := jsonbPayloadSize(pParse, i, sz);
  if n = 0 then
  begin
    pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
    Result := pParse^.nBlob + 1;
    Exit;
  end;
  case pParse^.aBlob[i] and $0F of
    JSONB_NULL:
    begin
      jsonAppendRawNZ(pOut, 'null', 4);
      Result := i + 1;
      Exit;
    end;
    JSONB_TRUE:
    begin
      jsonAppendRawNZ(pOut, 'true', 4);
      Result := i + 1;
      Exit;
    end;
    JSONB_FALSE:
    begin
      jsonAppendRawNZ(pOut, 'false', 5);
      Result := i + 1;
      Exit;
    end;
    JSONB_INT, JSONB_FLOAT:
    begin
      if sz = 0 then goto malformed_jsonb;
      jsonAppendRaw(pOut, PAnsiChar(@pParse^.aBlob[i + n]), sz);
    end;
    JSONB_INT5:  { Integer literal in hexadecimal notation }
    begin
      if sz = 0 then goto malformed_jsonb;
      k := 2;
      u := 0;
      bOverflow := 0;
      zIn := PAnsiChar(@pParse^.aBlob[i + n]);
      if zIn[0] = '-' then
      begin
        jsonAppendChar(pOut, '-');
        Inc(k);
      end
      else if zIn[0] = '+' then
        Inc(k);
      while k < sz do
      begin
        if sqlite3Isxdigit(u8(zIn[k])) = 0 then
        begin
          pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
          Break;
        end
        else if (u shr 60) <> 0 then
          bOverflow := 1
        else
          u := u * 16 + u64(sqlite3HexToInt(u8(zIn[k])));
        Inc(k);
      end;
      jsonAppendU64Decimal(pOut, u, bOverflow);
    end;
    JSONB_FLOAT5:  { Float literal missing digits beside "." }
    begin
      if sz = 0 then goto malformed_jsonb;
      k := 0;
      zIn := PAnsiChar(@pParse^.aBlob[i + n]);
      if zIn[0] = '-' then
      begin
        jsonAppendChar(pOut, '-');
        Inc(k);
      end;
      if zIn[k] = '.' then
        jsonAppendChar(pOut, '0');
      while k < sz do
      begin
        jsonAppendChar(pOut, zIn[k]);
        if (zIn[k] = '.')
           and ((k + 1 = sz) or (sqlite3Isdigit(u8(zIn[k + 1])) = 0)) then
          jsonAppendChar(pOut, '0');
        Inc(k);
      end;
    end;
    JSONB_TEXT, JSONB_TEXTJ:
    begin
      if (pOut^.nUsed + sz + 2 <= pOut^.nAlloc)
         or (jsonStringGrow(pOut, sz + 2) = 0) then
      begin
        pOut^.zBuf[pOut^.nUsed] := '"';
        if sz > 0 then
          Move(pParse^.aBlob[i + n], pOut^.zBuf[pOut^.nUsed + 1], sz);
        pOut^.zBuf[pOut^.nUsed + sz + 1] := '"';
        pOut^.nUsed := pOut^.nUsed + sz + 2;
      end;
    end;
    JSONB_TEXT5:
    begin
      sz2 := sz;
      zIn := PAnsiChar(@pParse^.aBlob[i + n]);
      jsonAppendChar(pOut, '"');
      while sz2 > 0 do
      begin
        k := 0;
        while (k < sz2) and ((jsonIsOk[u8(zIn[k])] <> 0)
                             or (zIn[k] = '''')) do
          Inc(k);
        if k > 0 then
        begin
          jsonAppendRawNZ(pOut, zIn, k);
          if k >= sz2 then Break;
          zIn := zIn + k;
          sz2 := sz2 - k;
        end;
        if zIn[0] = '"' then
        begin
          jsonAppendRawNZ(pOut, PAnsiChar(#$5C'"'), 2);
          Inc(zIn);
          Dec(sz2);
          Continue;
        end;
        if u8(zIn[0]) <= $1F then
        begin
          if (pOut^.nUsed + 7 > pOut^.nAlloc)
             and (jsonStringGrow(pOut, 7) <> 0) then Break;
          jsonAppendControlChar(pOut, u8(zIn[0]));
          Inc(zIn);
          Dec(sz2);
          Continue;
        end;
        { assert zIn[0] = '\' and sz2 >= 1 }
        if sz2 < 2 then
        begin
          pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
          Break;
        end;
        b := u8(zIn[1]);
        case b of
          Ord(''''): jsonAppendChar(pOut, '''');
          Ord('v'):  jsonAppendRawNZ(pOut, #$5C+'u000b', 6);
          Ord('x'):
            begin
              if sz2 < 4 then
              begin
                pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
                sz2 := 2;
              end
              else
              begin
                jsonAppendRawNZ(pOut, '\u00', 4);
                jsonAppendRawNZ(pOut, @zIn[2], 2);
                zIn := zIn + 2;
                sz2 := sz2 - 2;
              end;
            end;
          Ord('0'):  jsonAppendRawNZ(pOut, #$5C+'u0000', 6);
          $0D {CR}:
            begin
              if (sz2 > 2) and (zIn[2] = #$0A) then
              begin
                Inc(zIn);
                Dec(sz2);
              end;
            end;
          $0A {LF}: ;  { skip }
          $E2:
            begin
              { '\' followed by U+2028 / U+2029 (UTF-8 e2 80 a8/a9) is whitespace }
              if (sz2 < 4)
                 or (u8(zIn[2]) <> $80)
                 or ((u8(zIn[3]) <> $A8) and (u8(zIn[3]) <> $A9)) then
              begin
                pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
                sz2 := 2;
              end
              else
              begin
                zIn := zIn + 2;
                sz2 := sz2 - 2;
              end;
            end;
        else
          jsonAppendRawNZ(pOut, zIn, 2);
        end;
        { sz2>=2 here }
        zIn := zIn + 2;
        sz2 := sz2 - 2;
      end;
      jsonAppendChar(pOut, '"');
    end;
    JSONB_TEXTRAW:
    begin
      jsonAppendString(pOut, PAnsiChar(@pParse^.aBlob[i + n]), sz);
    end;
    JSONB_ARRAY:
    begin
      jsonAppendChar(pOut, '[');
      j := i + n;
      iEnd := j + sz;
      Inc(pParse^.iDepth);
      if pParse^.iDepth > JSON_MAX_DEPTH then
        jsonStringTooDeep(pOut);
      while (j < iEnd) and (pOut^.eErr = 0) do
      begin
        j := jsonTranslateBlobToText(pParse, j, pOut);
        jsonAppendChar(pOut, ',');
      end;
      Dec(pParse^.iDepth);
      if j > iEnd then
        pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
      if sz > 0 then jsonStringTrimOneChar(pOut);
      jsonAppendChar(pOut, ']');
    end;
    JSONB_OBJECT:
    begin
      x := 0;
      jsonAppendChar(pOut, '{');
      j := i + n;
      iEnd := j + sz;
      Inc(pParse^.iDepth);
      if pParse^.iDepth > JSON_MAX_DEPTH then
        jsonStringTooDeep(pOut);
      while (j < iEnd) and (pOut^.eErr = 0) do
      begin
        j := jsonTranslateBlobToText(pParse, j, pOut);
        if (x and 1) <> 0 then
          jsonAppendChar(pOut, ',')
        else
          jsonAppendChar(pOut, ':');
        Inc(x);
      end;
      Dec(pParse^.iDepth);
      if ((x and 1) <> 0) or (j > iEnd) then
        pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
      if sz > 0 then jsonStringTrimOneChar(pOut);
      jsonAppendChar(pOut, '}');
    end;
  else
    malformed_jsonb:
    pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
  end;
  Result := i + n + sz;
end;

procedure jsonPrettyIndent(pPretty: PJsonPretty);
var
  jj : u32;
begin
  jj := 0;
  while jj < pPretty^.nIndent do
  begin
    jsonAppendRaw(pPretty^.pOut, pPretty^.zIndent, pPretty^.szIndent);
    Inc(jj);
  end;
end;

function jsonTranslateBlobToPrettyText(pPretty: PJsonPretty; i: u32): u32;
var
  sz, n, j, iEnd : u32;
  pParse         : PJsonParse;
  pOut           : PJsonString;
begin
  pParse := pPretty^.pParse;
  pOut := pPretty^.pOut;
  n := jsonbPayloadSize(pParse, i, sz);
  if n = 0 then
  begin
    pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
    Result := pParse^.nBlob + 1;
    Exit;
  end;
  case pParse^.aBlob[i] and $0F of
    JSONB_ARRAY:
    begin
      j := i + n;
      iEnd := j + sz;
      jsonAppendChar(pOut, '[');
      if j < iEnd then
      begin
        jsonAppendChar(pOut, #$0A);
        Inc(pPretty^.nIndent);
        if pPretty^.nIndent >= JSON_MAX_DEPTH then
          jsonStringTooDeep(pOut);
        while pOut^.eErr = 0 do
        begin
          jsonPrettyIndent(pPretty);
          j := jsonTranslateBlobToPrettyText(pPretty, j);
          if j >= iEnd then Break;
          jsonAppendChar(pOut, ',');
          jsonAppendChar(pOut, #$0A);
        end;
        jsonAppendChar(pOut, #$0A);
        Dec(pPretty^.nIndent);
        jsonPrettyIndent(pPretty);
      end;
      jsonAppendChar(pOut, ']');
      i := iEnd;
    end;
    JSONB_OBJECT:
    begin
      j := i + n;
      iEnd := j + sz;
      jsonAppendChar(pOut, '{');
      if j < iEnd then
      begin
        jsonAppendChar(pOut, #$0A);
        Inc(pPretty^.nIndent);
        if pPretty^.nIndent >= JSON_MAX_DEPTH then
          jsonStringTooDeep(pOut);
        pParse^.iDepth := u16(pPretty^.nIndent);
        while pOut^.eErr = 0 do
        begin
          jsonPrettyIndent(pPretty);
          j := jsonTranslateBlobToText(pParse, j, pOut);
          if j > iEnd then
          begin
            pOut^.eErr := pOut^.eErr or JSTRING_MALFORMED;
            Break;
          end;
          jsonAppendRawNZ(pOut, ': ', 2);
          j := jsonTranslateBlobToPrettyText(pPretty, j);
          if j >= iEnd then Break;
          jsonAppendChar(pOut, ',');
          jsonAppendChar(pOut, #$0A);
        end;
        jsonAppendChar(pOut, #$0A);
        Dec(pPretty^.nIndent);
        jsonPrettyIndent(pPretty);
      end;
      jsonAppendChar(pOut, '}');
      i := iEnd;
    end;
  else
    i := jsonTranslateBlobToText(pParse, i, pOut);
  end;
  Result := i;
end;

end.
