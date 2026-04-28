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
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
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
  passqlite3util,
  passqlite3vdbe;

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

{ ===========================================================================
  Path lookup + edit (Phase 6.8.f)

  Faithful port of json.c:2977 (jsonLookupStep) and 2928
  (jsonCreateEditSubstructure).  Walks a `$.a.b[3]`-style path against a
  JSONB blob held in pParse^.aBlob[]; if pParse^.eEdit is non-zero the
  matched element is mutated in place via jsonBlobEdit.

  Sentinel return codes (any value >= JSON_LOOKUP_PATHERROR is an error):
    JSON_LOOKUP_ERROR     — malformed JSONB
    JSON_LOOKUP_NOTFOUND  — path did not match
    JSON_LOOKUP_NOTARRAY  — JEDIT_AINS used on a non-array path
    JSON_LOOKUP_TOODEEP   — exceeded JSON_MAX_DEPTH
    JSON_LOOKUP_PATHERROR — malformed path string
  =========================================================================== }

const
  JSON_LOOKUP_ERROR     : u32 = $FFFFFFFF;
  JSON_LOOKUP_NOTFOUND  : u32 = $FFFFFFFE;
  JSON_LOOKUP_NOTARRAY  : u32 = $FFFFFFFD;
  JSON_LOOKUP_TOODEEP   : u32 = $FFFFFFFC;
  JSON_LOOKUP_PATHERROR : u32 = $FFFFFFFB;

function jsonLookupIsError(x: u32): Boolean; inline;
function jsonLookupStep(pParse: PJsonParse; iRoot: u32; zPath: PAnsiChar;
                        iLabel: u32): u32;
function jsonCreateEditSubstructure(pParse: PJsonParse; pIns: PJsonParse;
                                    zTail: PAnsiChar): u32;

{ ===========================================================================
  Function-arg cache + jsonParseFuncArg (Phase 6.8.g)

  Faithful port of json.c:421 (jsonCacheDelete), 428 (jsonCacheDeleteGeneric),
  439 (jsonCacheInsert), 483 (jsonCacheSearch), 926 (jsonParseFree),
  3619 (jsonArgIsJsonb), 3658 (jsonParseFuncArg).

  pCtx and pArg are kept as opaque Pointers in the interface (consistent
  with jsonStringInit's existing convention) — the implementation casts to
  Psqlite3_context / Psqlite3_value via passqlite3vdbe in the implementation
  uses clause.

  Caveat: sqlite3RCStr is not yet ported.  jsonParseFuncArg therefore
  copies the JSON text into a fresh sqlite3_malloc'd buffer (set
  bJsonIsRCStr=1 to mark "owned by libc malloc"); jsonParseReset frees it
  via sqlite3_free.  When 6.8.h lands sqlite3RCStr proper, swap the
  malloc/copy/free triple for sqlite3RCStrNew/Ref/Unref — every other
  cache invariant is identical.
  =========================================================================== }

procedure jsonParseFree(pParse: PJsonParse);
function  jsonArgIsJsonb(pArg: Pointer; p: PJsonParse): i32;
function  jsonCacheInsert(pCtx: Pointer; pParse: PJsonParse): i32;
function  jsonCacheSearch(pCtx: Pointer; pArg: Pointer): PJsonParse;
function  jsonParseFuncArg(pCtx: Pointer; pArg: Pointer; flgs: u32): PJsonParse;

{ ===========================================================================
  SQL-result helpers (Phase 6.8.h.1)

  Faithful port of the json.c routines that translate JSON state into
  sqlite3_result_* on the surrounding function context:
    json.c:803  jsonAppendSqlValue
    json.c:856  jsonReturnString
    json.c:1134 jsonWrongNumArgs
    json.c:2100 jsonReturnStringAsBlob
    json.c:3191 jsonReturnTextJsonFromBlob
    json.c:3224 jsonReturnFromBlob
    json.c:3411 jsonFunctionArgToBlob
    json.c:3500 jsonBadPathError
    json.c:3775 jsonReturnParse

  pCtx is the opaque (Psqlite3_context) from the surrounding SQL function
  call, kept as Pointer in the interface for the same dep-cycle reasons as
  jsonStringInit / jsonParseFuncArg.

  RCStr is still unported, so jsonReturnString currently uses
  SQLITE_TRANSIENT for the non-static heap case — the result text is
  copied once and then jsonStringReset frees the original.  When 6.8.h.x
  lands sqlite3RCStr, swap to the sqlite3RCStrRef/Unref ownership pair
  per json.c:884.
  =========================================================================== }

procedure jsonAppendSqlValue(p: PJsonString; pValue: Pointer);
procedure jsonReturnString(p: PJsonString; pParse: PJsonParse; pCtx: Pointer);
procedure jsonReturnStringAsBlob(pStr: PJsonString);
procedure jsonReturnTextJsonFromBlob(pCtx: Pointer; aBlob: PByte; nBlob: u32);
procedure jsonReturnFromBlob(pParse: PJsonParse; i: u32; pCtx: Pointer;
                             eMode: i32);
procedure jsonReturnParse(pCtx: Pointer; p: PJsonParse);
procedure jsonWrongNumArgs(pCtx: Pointer; zFuncName: PAnsiChar);
function  jsonBadPathError(pCtx: Pointer; zPath: PAnsiChar; rc: i32): PAnsiChar;
function  jsonFunctionArgToBlob(pCtx: Pointer; pArg: Pointer;
                                pParse: PJsonParse): i32;

{ ===========================================================================
  Simple scalar SQL functions (Phase 6.8.h.2)

  Faithful port of the body-only json.c routines:
    json.c:3960 jsonQuoteFunc        — json_quote(VALUE)
    json.c:4005 jsonArrayLengthFunc  — json_array_length(JSON [, PATH])
    json.c:4044 jsonAllAlphanum      — internal helper used by .h.3
    json.c:4573 jsonTypeFunc         — json_type(JSON [, PATH])
    json.c:4618 jsonPrettyFunc       — json_pretty(JSON [, INDENT])
    json.c:4699 jsonValidFunc        — json_valid(JSON [, FLAGS])
    json.c:4781 jsonErrorFunc        — json_error_position(JSON)

  Signatures match TxSFuncProc (cdecl) so .h.6 can drop them straight into
  TFuncDef tables.  Tests in TestJson.pas call them directly on a stack
  Tsqlite3_context with a TVdbe-backed pOut Mem; no DB engine required.
  =========================================================================== }

function  jsonAllAlphanum(z: PAnsiChar; n: i32): i32;
procedure jsonQuoteFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonArrayFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonObjectFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonArrayLengthFunc(pCtx: Psqlite3_context; argc: i32;
                              argv: PPMem); cdecl;
procedure jsonTypeFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonPrettyFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonValidFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonErrorFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;

{ ===========================================================================
  Phase 6.8.h.3 — Path-driven scalar SQL functions.

  json_extract / json_set / json_replace / json_insert /
  json_array_insert / json_remove / json_patch.  All exported with the
  TxSFuncProc cdecl shape so 6.8.h.6 can drop them straight into
  TFuncDef tables.

  json_set / json_replace / json_insert / json_array_insert all share a
  single private driver (jsonInsertIntoBlob — implementation-only).
  json_patch uses jsonMergePatch (also implementation-only).
  =========================================================================== }

procedure jsonExtractFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonRemoveFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonReplaceFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonSetFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonPatchFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;

{ ===========================================================================
  Phase 6.8.h.4 — Aggregate SQL functions

    json_group_array(VALUE)        — JSON array of all stepped values.
    json_group_object(NAME, VALUE) — JSON object of all stepped name/value
                                     pairs.

  All four entry points (Step / Final / Value / Inverse) share an
  aggregate context allocated via sqlite3_aggregate_context; that
  context is a TJsonString accumulator that records the comma-separated
  body up to (but not including) the final closing bracket.
  Final/Value closes the bracket, terminates, and emits the result;
  Value preserves the trailing-bracket-trim invariant so the next
  Step can resume.
  Inverse strips the first element by scanning forward to the first
  comma not inside a string or sub-container.

  flags from sqlite3_user_data: JSON_BLOB switches the result to JSONB.
  =========================================================================== }

procedure jsonArrayStep(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonArrayValue(pCtx: Psqlite3_context); cdecl;
procedure jsonArrayFinal(pCtx: Psqlite3_context); cdecl;
procedure jsonObjectStep(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
procedure jsonObjectValue(pCtx: Psqlite3_context); cdecl;
procedure jsonObjectFinal(pCtx: Psqlite3_context); cdecl;
procedure jsonGroupInverse(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;

implementation

uses
  SysUtils;

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
    sqlite3RCStrUnref(p^.zBuf);
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
    zNew := sqlite3RCStrNew(nTotal);
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
    p^.zBuf := sqlite3RCStrResize(p^.zBuf, nTotal);
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
  { json.c:906 — when bJsonIsRCStr=1, zJson is shared via RCStr (the cache
    holds one ref, every consumer holds another).  Drop our reference via
    sqlite3RCStrUnref; the buffer is freed once the last consumer drops it.
    For non-cached parses bJsonIsRCStr stays 0 and zJson is borrowed. }
  if pParse^.bJsonIsRCStr <> 0 then
  begin
    if pParse^.zJson <> nil then sqlite3RCStrUnref(pParse^.zJson);
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

{ ===========================================================================
  Phase 6.8.f implementation — path lookup + edit
  =========================================================================== }

function jsonLookupIsError(x: u32): Boolean; inline;
begin
  Result := x >= JSON_LOOKUP_PATHERROR;
end;

{ Helper: returns 1 if the NUL-terminated zTail ends with ']', else 0.
  Stand-in for json.c's `sqlite3_strglob("*]", zTail)==0` test.  Empty
  tail is not a match. }
function jsonPathTailIsBracket(zTail: PAnsiChar): i32;
var
  p, last: PAnsiChar;
begin
  if (zTail = nil) or (zTail[0] = #0) then begin Result := 0; Exit; end;
  last := zTail;
  p := zTail;
  while p^ <> #0 do begin last := p; Inc(p); end;
  if last^ = ']' then Result := 1 else Result := 0;
end;

function jsonCreateEditSubstructure(pParse: PJsonParse; pIns: PJsonParse;
                                    zTail: PAnsiChar): u32;
const
  emptyObject: array[0..1] of u8 = (JSONB_ARRAY, JSONB_OBJECT);
var
  rc  : u32;
  idx : i32;
begin
  FillChar(pIns^, SizeOf(pIns^), 0);
  pIns^.db := pParse^.db;
  if zTail[0] = #0 then
  begin
    { No substructure.  Just insert what is given in pParse. }
    pIns^.aBlob := pParse^.aIns;
    pIns^.nBlob := pParse^.nIns;
    rc := 0;
  end
  else
  begin
    { Construct the binary substructure: a singleton header byte that
      starts an empty ARRAY (for "[..." tails) or an empty OBJECT (for
      ".xxx" tails).  Recursive jsonLookupStep then fills it in. }
    pIns^.nBlob := 1;
    if zTail[0] = '.' then idx := 1 else idx := 0;
    pIns^.aBlob := PByte(@emptyObject[idx]);
    pIns^.eEdit := pParse^.eEdit;
    pIns^.nIns  := pParse^.nIns;
    pIns^.aIns  := pParse^.aIns;
    pIns^.iDepth := pParse^.iDepth + 1;
    if pIns^.iDepth >= JSON_MAX_DEPTH then
    begin
      Result := JSON_LOOKUP_TOODEEP;
      Exit;
    end;
    rc := jsonLookupStep(pIns, 0, zTail, 0);
    pParse^.iDepth := pParse^.iDepth - 1;
    pParse^.oom := pParse^.oom or pIns^.oom;
  end;
  Result := rc;
end;

function jsonLookupStep(pParse: PJsonParse; iRoot: u32; zPath: PAnsiChar;
                        iLabel: u32): u32;
var
  i, j, k, nKey, sz, n, iEnd, rc : u32;
  zKey                           : PAnsiChar;
  x                              : u8;
  rawKey, rawLabel               : i32;
  kk, nn                         : u64;
  zLabel                         : PAnsiChar;
  v                              : u32;
  nIns                           : u32;
  vSub, ix                       : TJsonParse;
begin
  if zPath[0] = #0 then
  begin
    if (pParse^.eEdit <> 0)
       and (jsonBlobMakeEditable(pParse, pParse^.nIns) <> 0) then
    begin
      n := jsonbPayloadSize(pParse, iRoot, sz);
      sz := sz + n;
      if pParse^.eEdit = JEDIT_DEL then
      begin
        if iLabel > 0 then
        begin
          sz := sz + (iRoot - iLabel);
          iRoot := iLabel;
        end;
        jsonBlobEdit(pParse, iRoot, sz, nil, 0);
      end
      else if pParse^.eEdit = JEDIT_INS then
      begin
        { Already exists: json_insert() is a no-op. }
      end
      else if pParse^.eEdit = JEDIT_AINS then
      begin
        { json_array_insert() — only legal if the path landed via "[N]". }
        if (zPath - 1)^ <> ']' then
        begin
          Result := JSON_LOOKUP_NOTARRAY;
          Exit;
        end
        else
        begin
          jsonBlobEdit(pParse, iRoot, 0, pParse^.aIns, pParse^.nIns);
        end;
      end
      else
      begin
        { json_set() or json_replace() }
        jsonBlobEdit(pParse, iRoot, sz, pParse^.aIns, pParse^.nIns);
      end;
    end;
    pParse^.iLabel := iLabel;
    Result := iRoot;
    Exit;
  end;

  if zPath[0] = '.' then
  begin
    { ----- Object key lookup ----- }
    rawKey := 1;
    x := pParse^.aBlob[iRoot];
    Inc(zPath);
    if zPath[0] = '"' then
    begin
      zKey := zPath + 1;
      i := 1;
      while (zPath[i] <> #0) and (zPath[i] <> '"') do
      begin
        if (zPath[i] = '\') and (zPath[i + 1] <> #0) then Inc(i);
        Inc(i);
      end;
      nKey := i - 1;
      if zPath[i] <> #0 then
        Inc(i)
      else
      begin
        Result := JSON_LOOKUP_PATHERROR;
        Exit;
      end;
      { rawKey = 1 iff there is no '\' in the first nKey bytes }
      rawKey := 1;
      j := 0;
      while j < nKey do
      begin
        if zKey[j] = '\' then begin rawKey := 0; Break; end;
        Inc(j);
      end;
    end
    else
    begin
      zKey := zPath;
      i := 0;
      while (zPath[i] <> #0) and (zPath[i] <> '.') and (zPath[i] <> '[') do
        Inc(i);
      nKey := i;
      if nKey = 0 then
      begin
        Result := JSON_LOOKUP_PATHERROR;
        Exit;
      end;
    end;

    if (x and $0F) <> JSONB_OBJECT then
    begin
      Result := JSON_LOOKUP_NOTFOUND;
      Exit;
    end;

    n := jsonbPayloadSize(pParse, iRoot, sz);
    j := iRoot + n;       { j is the index of a label }
    iEnd := j + sz;
    while j < iEnd do
    begin
      x := pParse^.aBlob[j] and $0F;
      if (x < JSONB_TEXT) or (x > JSONB_TEXTRAW) then
      begin
        Result := JSON_LOOKUP_ERROR;
        Exit;
      end;
      n := jsonbPayloadSize(pParse, j, sz);
      if n = 0 then begin Result := JSON_LOOKUP_ERROR; Exit; end;
      k := j + n;          { k is the index of the label text }
      if k + sz >= iEnd then begin Result := JSON_LOOKUP_ERROR; Exit; end;
      zLabel := PAnsiChar(@pParse^.aBlob[k]);
      if (x = JSONB_TEXT) or (x = JSONB_TEXTRAW) then
        rawLabel := 1
      else
        rawLabel := 0;
      if jsonLabelCompare(zKey, nKey, rawKey, zLabel, sz, rawLabel) <> 0 then
      begin
        v := k + sz;        { v is the index of the value }
        if (pParse^.aBlob[v] and $0F) > JSONB_OBJECT then
        begin
          Result := JSON_LOOKUP_ERROR;
          Exit;
        end;
        n := jsonbPayloadSize(pParse, v, sz);
        if (n = 0) or (v + n + sz > iEnd) then
        begin
          Result := JSON_LOOKUP_ERROR;
          Exit;
        end;
        Inc(pParse^.iDepth);
        if pParse^.iDepth >= JSON_MAX_DEPTH then
        begin
          Result := JSON_LOOKUP_TOODEEP;
          Exit;
        end;
        rc := jsonLookupStep(pParse, v, zPath + i, j);
        pParse^.iDepth := pParse^.iDepth - 1;
        if pParse^.delta <> 0 then jsonAfterEditSizeAdjust(pParse, iRoot);
        Result := rc;
        Exit;
      end;
      j := k + sz;
      if (pParse^.aBlob[j] and $0F) > JSONB_OBJECT then
      begin
        Result := JSON_LOOKUP_ERROR;
        Exit;
      end;
      n := jsonbPayloadSize(pParse, j, sz);
      if n = 0 then begin Result := JSON_LOOKUP_ERROR; Exit; end;
      j := j + n + sz;
    end;
    if j > iEnd then
    begin
      Result := JSON_LOOKUP_ERROR;
      Exit;
    end;
    if pParse^.eEdit >= JEDIT_INS then
    begin
      if (pParse^.eEdit = JEDIT_AINS)
         and (jsonPathTailIsBracket(zPath + i) = 0) then
      begin
        Result := JSON_LOOKUP_NOTARRAY;
        Exit;
      end;
      FillChar(ix, SizeOf(ix), 0);
      ix.db := pParse^.db;
      if rawKey <> 0 then
        jsonBlobAppendNode(@ix, JSONB_TEXTRAW, nKey, nil)
      else
        jsonBlobAppendNode(@ix, JSONB_TEXT5, nKey, nil);
      pParse^.oom := pParse^.oom or ix.oom;
      rc := jsonCreateEditSubstructure(pParse, @vSub, zPath + i);
      if (not jsonLookupIsError(rc))
         and (jsonBlobMakeEditable(pParse, ix.nBlob + nKey + vSub.nBlob) <> 0) then
      begin
        nIns := ix.nBlob + nKey + vSub.nBlob;
        jsonBlobEdit(pParse, j, 0, nil, nIns);
        if pParse^.oom = 0 then
        begin
          Move(ix.aBlob^, pParse^.aBlob[j], ix.nBlob);
          k := j + ix.nBlob;
          Move(zKey^, pParse^.aBlob[k], nKey);
          k := k + nKey;
          Move(vSub.aBlob^, pParse^.aBlob[k], vSub.nBlob);
          if pParse^.delta <> 0 then jsonAfterEditSizeAdjust(pParse, iRoot);
        end;
      end;
      jsonParseReset(@vSub);
      jsonParseReset(@ix);
      Result := rc;
      Exit;
    end;
  end
  else if zPath[0] = '[' then
  begin
    { ----- Array index lookup ----- }
    kk := 0;
    x := pParse^.aBlob[iRoot] and $0F;
    if x <> JSONB_ARRAY then
    begin
      Result := JSON_LOOKUP_NOTFOUND;
      Exit;
    end;
    n := jsonbPayloadSize(pParse, iRoot, sz);
    i := 1;
    while sqlite3Isdigit(u8(zPath[i])) <> 0 do
    begin
      if kk < $FFFFFFFF then
        kk := kk * 10 + (u64(Ord(zPath[i])) - Ord('0'));
      Inc(i);
    end;
    if (i < 2) or (zPath[i] <> ']') then
    begin
      if zPath[1] = '#' then
      begin
        kk := jsonbArrayCount(pParse, iRoot);
        i := 2;
        if (zPath[2] = '-') and (sqlite3Isdigit(u8(zPath[3])) <> 0) then
        begin
          nn := 0;
          i := 3;
          repeat
            if nn < $FFFFFFFF then
              nn := nn * 10 + (u64(Ord(zPath[i])) - Ord('0'));
            Inc(i);
          until sqlite3Isdigit(u8(zPath[i])) = 0;
          if nn > kk then
          begin
            Result := JSON_LOOKUP_NOTFOUND;
            Exit;
          end;
          kk := kk - nn;
        end;
        if zPath[i] <> ']' then
        begin
          Result := JSON_LOOKUP_PATHERROR;
          Exit;
        end;
      end
      else
      begin
        Result := JSON_LOOKUP_PATHERROR;
        Exit;
      end;
    end;
    j := iRoot + n;
    iEnd := j + sz;
    while j < iEnd do
    begin
      if kk = 0 then
      begin
        Inc(pParse^.iDepth);
        if pParse^.iDepth >= JSON_MAX_DEPTH then
        begin
          Result := JSON_LOOKUP_TOODEEP;
          Exit;
        end;
        rc := jsonLookupStep(pParse, j, zPath + i + 1, 0);
        pParse^.iDepth := pParse^.iDepth - 1;
        if pParse^.delta <> 0 then jsonAfterEditSizeAdjust(pParse, iRoot);
        Result := rc;
        Exit;
      end;
      Dec(kk);
      n := jsonbPayloadSize(pParse, j, sz);
      if n = 0 then
      begin
        Result := JSON_LOOKUP_ERROR;
        Exit;
      end;
      j := j + n + sz;
    end;
    if j > iEnd then
    begin
      Result := JSON_LOOKUP_ERROR;
      Exit;
    end;
    if kk > 0 then
    begin
      Result := JSON_LOOKUP_NOTFOUND;
      Exit;
    end;
    if pParse^.eEdit >= JEDIT_INS then
    begin
      rc := jsonCreateEditSubstructure(pParse, @vSub, zPath + i + 1);
      if (not jsonLookupIsError(rc))
         and (jsonBlobMakeEditable(pParse, vSub.nBlob) <> 0) then
      begin
        jsonBlobEdit(pParse, j, 0, vSub.aBlob, vSub.nBlob);
      end;
      jsonParseReset(@vSub);
      if pParse^.delta <> 0 then jsonAfterEditSizeAdjust(pParse, iRoot);
      Result := rc;
      Exit;
    end;
  end
  else
  begin
    Result := JSON_LOOKUP_PATHERROR;
    Exit;
  end;
  Result := JSON_LOOKUP_NOTFOUND;
end;

{ ===========================================================================
  Phase 6.8.g implementation
  =========================================================================== }

procedure jsonParseFree(pParse: PJsonParse);
begin
  if pParse = nil then Exit;
  if pParse^.nJPRef > 1 then
    Dec(pParse^.nJPRef)
  else
  begin
    jsonParseReset(pParse);
    sqlite3DbFree(pParse^.db, pParse);
  end;
end;

procedure jsonCacheDelete(p: PJsonCache);
var
  i: i32;
begin
  for i := 0 to p^.nUsed - 1 do
    jsonParseFree(p^.a[i]);
  sqlite3DbFree(p^.db, p);
end;

procedure jsonCacheDeleteGeneric(p: Pointer); cdecl;
begin
  jsonCacheDelete(PJsonCache(p));
end;

function jsonArgIsJsonb(pArg: Pointer; p: PJsonParse): i32;
var
  n, sz: u32;
  c: u8;
begin
  if sqlite3_value_type(Psqlite3_value(pArg)) <> SQLITE_BLOB then
  begin
    Result := 0;
    Exit;
  end;
  p^.aBlob := PByte(sqlite3_value_blob(Psqlite3_value(pArg)));
  p^.nBlob := u32(sqlite3_value_bytes(Psqlite3_value(pArg)));
  sz := 0;
  if (p^.nBlob > 0) and (p^.aBlob <> nil) then
  begin
    c := p^.aBlob[0];
    if (c and $0F) <= JSONB_OBJECT then
    begin
      n := jsonbPayloadSize(p, 0, sz);
      if (n > 0) and ((sz + n) = p^.nBlob)
         and (((c and $0F) > JSONB_FALSE) or (sz = 0))
         and ((sz > 7)
              or ((c <> $7B) and (c <> $5B) and (sqlite3Isdigit(c) = 0))
              or (jsonbValidityCheck(p, 0, p^.nBlob, 1) = 0)) then
      begin
        Result := 1;
        Exit;
      end;
    end;
  end;
  p^.aBlob := nil;
  p^.nBlob := 0;
  Result := 0;
end;

function jsonCacheInsert(pCtx: Pointer; pParse: PJsonParse): i32;
var
  p:  PJsonCache;
  db: Pointer;
begin
  p := PJsonCache(sqlite3_get_auxdata(Psqlite3_context(pCtx), JSON_CACHE_ID));
  if p = nil then
  begin
    db := sqlite3_context_db_handle(Psqlite3_context(pCtx));
    p := PJsonCache(sqlite3DbMallocZero(db, SizeOf(TJsonCache)));
    if p = nil then begin Result := SQLITE_NOMEM; Exit; end;
    p^.db := db;
    sqlite3_set_auxdata(Psqlite3_context(pCtx), JSON_CACHE_ID, p,
                        @jsonCacheDeleteGeneric);
    p := PJsonCache(sqlite3_get_auxdata(Psqlite3_context(pCtx), JSON_CACHE_ID));
    if p = nil then begin Result := SQLITE_NOMEM; Exit; end;
  end;
  if p^.nUsed >= JSON_CACHE_SIZE then
  begin
    jsonParseFree(p^.a[0]);
    Move(p^.a[1], p^.a[0], (JSON_CACHE_SIZE - 1) * SizeOf(PJsonParse));
    p^.nUsed := JSON_CACHE_SIZE - 1;
  end;
  pParse^.eEdit := 0;
  Inc(pParse^.nJPRef);
  pParse^.bReadOnly := 1;
  p^.a[p^.nUsed] := pParse;
  Inc(p^.nUsed);
  Result := SQLITE_OK;
end;

function jsonCacheSearch(pCtx: Pointer; pArg: Pointer): PJsonParse;
var
  p:     PJsonCache;
  i:     i32;
  zJson: PAnsiChar;
  nJson: i32;
  tmp:   PJsonParse;
begin
  if sqlite3_value_type(Psqlite3_value(pArg)) <> SQLITE_TEXT then
  begin
    Result := nil;
    Exit;
  end;
  zJson := PAnsiChar(sqlite3_value_text(Psqlite3_value(pArg)));
  if zJson = nil then begin Result := nil; Exit; end;
  nJson := sqlite3_value_bytes(Psqlite3_value(pArg));

  p := PJsonCache(sqlite3_get_auxdata(Psqlite3_context(pCtx), JSON_CACHE_ID));
  if p = nil then begin Result := nil; Exit; end;

  { First pass: pointer equality (fast path for repeated identical args). }
  i := 0;
  while i < p^.nUsed do
  begin
    if p^.a[i]^.zJson = zJson then Break;
    Inc(i);
  end;
  if i >= p^.nUsed then
  begin
    { Second pass: byte-compare. }
    i := 0;
    while i < p^.nUsed do
    begin
      if (p^.a[i]^.nJson = nJson)
         and (CompareByte(p^.a[i]^.zJson^, zJson^, nJson) = 0) then
        Break;
      Inc(i);
    end;
  end;
  if i < p^.nUsed then
  begin
    if i < p^.nUsed - 1 then
    begin
      { Promote matched entry to most-recently-used (end of array). }
      tmp := p^.a[i];
      Move(p^.a[i + 1], p^.a[i], (p^.nUsed - i - 1) * SizeOf(PJsonParse));
      p^.a[p^.nUsed - 1] := tmp;
      i := p^.nUsed - 1;
    end;
    Result := p^.a[i];
  end
  else
    Result := nil;
end;

function jsonParseFuncArg(pCtx: Pointer; pArg: Pointer;
                          flgs: u32): PJsonParse;
label
  rebuild_from_cache, json_pfa_oom, json_pfa_malformed;
var
  eType:      i32;
  p, pCache:  PJsonParse;
  db:         Pointer;
  nBlob:      u32;
  zNew:       PAnsiChar;
  rc:         i32;
begin
  p := nil;
  pCache := nil;
  eType := sqlite3_value_type(Psqlite3_value(pArg));
  if eType = SQLITE_NULL then begin Result := nil; Exit; end;
  pCache := jsonCacheSearch(pCtx, pArg);
  if pCache <> nil then
  begin
    Inc(pCache^.nJPRef);
    if (flgs and JSON_EDITABLE) = 0 then
    begin
      Result := pCache;
      Exit;
    end;
  end;
  db := sqlite3_context_db_handle(Psqlite3_context(pCtx));
rebuild_from_cache:
  p := PJsonParse(sqlite3DbMallocZero(db, SizeOf(TJsonParse)));
  if p = nil then goto json_pfa_oom;
  p^.db := db;
  p^.nJPRef := 1;
  if pCache <> nil then
  begin
    nBlob := pCache^.nBlob;
    p^.aBlob := PByte(sqlite3DbMallocRaw(db, nBlob));
    if p^.aBlob = nil then goto json_pfa_oom;
    Move(pCache^.aBlob^, p^.aBlob^, nBlob);
    p^.nBlobAlloc := nBlob;
    p^.nBlob := nBlob;
    p^.hasNonstd := pCache^.hasNonstd;
    jsonParseFree(pCache);
    Result := p;
    Exit;
  end;
  if eType = SQLITE_BLOB then
  begin
    if jsonArgIsJsonb(pArg, p) <> 0 then
    begin
      if ((flgs and JSON_EDITABLE) <> 0)
         and (jsonBlobMakeEditable(p, 0) = 0) then
        goto json_pfa_oom;
      Result := p;
      Exit;
    end;
    { Not valid JSONB — fall through and try the bytes as JSON text
      (tag-20240123-a in json.c). }
  end;
  p^.zJson := PAnsiChar(sqlite3_value_text(Psqlite3_value(pArg)));
  p^.nJson := sqlite3_value_bytes(Psqlite3_value(pArg));
  if p^.nJson = 0 then goto json_pfa_malformed;
  if p^.zJson = nil then goto json_pfa_oom;
  if jsonConvertTextToBlob(p, pCtx) <> 0 then
  begin
    if (flgs and JSON_KEEPERROR) <> 0 then
    begin
      p^.nErr := 1;
      Result := p;
      Exit;
    end
    else
    begin
      jsonParseFree(p);
      Result := nil;
      Exit;
    end;
  end
  else
  begin
    { Heap-copy zJson into a fresh RCStr so the cache outlives the SQL
      value.  bJsonIsRCStr=1 marks the copy as RCStr-owned; jsonParseReset
      drops the reference via sqlite3RCStrUnref. }
    zNew := sqlite3RCStrNew(p^.nJson);
    if zNew = nil then goto json_pfa_oom;
    Move(p^.zJson^, zNew^, p^.nJson);
    zNew[p^.nJson] := #0;
    p^.zJson := zNew;
    p^.bJsonIsRCStr := 1;
    rc := jsonCacheInsert(pCtx, p);
    if rc = SQLITE_NOMEM then goto json_pfa_oom;
    if (flgs and JSON_EDITABLE) <> 0 then
    begin
      pCache := p;
      p := nil;
      goto rebuild_from_cache;
    end;
  end;
  Result := p;
  Exit;

json_pfa_malformed:
  if (flgs and JSON_KEEPERROR) <> 0 then
  begin
    p^.nErr := 1;
    Result := p;
    Exit;
  end
  else
  begin
    jsonParseFree(p);
    { sqlite3_result_error("malformed JSON",-1) deferred to 6.8.h. }
    Result := nil;
    Exit;
  end;

json_pfa_oom:
  jsonParseFree(pCache);
  jsonParseFree(p);
  { sqlite3_result_error_nomem(ctx) deferred to 6.8.h. }
  Result := nil;
end;

{ ===========================================================================
  SQL-result helpers — Phase 6.8.h.1 implementation
  =========================================================================== }

{ json.c:803 — append an sqlite3_value to the JSON string under construction. }
procedure jsonAppendSqlValue(p: PJsonString; pValue: Pointer);
var
  pVal: Psqlite3_value;
  z:    PAnsiChar;
  n:    u32;
  px:   TJsonParse;
begin
  pVal := Psqlite3_value(pValue);
  case sqlite3_value_type(pVal) of
    SQLITE_NULL:
      jsonAppendRawNZ(p, PAnsiChar('null'), 4);
    SQLITE_FLOAT:
      begin
        { json.c uses jsonPrintf(100, p, "%!0.15g", …); RealStr is good
          enough until 6.8.h.x ports the json-flavoured printf. }
        z := PAnsiChar(AnsiString(FloatToStr(sqlite3_value_double(pVal))));
        jsonAppendRaw(p, z, u32(StrLen(z)));
      end;
    SQLITE_INTEGER:
      begin
        z := PAnsiChar(sqlite3_value_text(pVal));
        n := u32(sqlite3_value_bytes(pVal));
        jsonAppendRaw(p, z, n);
      end;
    SQLITE_TEXT:
      begin
        z := PAnsiChar(sqlite3_value_text(pVal));
        n := u32(sqlite3_value_bytes(pVal));
        if sqlite3_value_subtype(pVal) = JSON_SUBTYPE then
          jsonAppendRaw(p, z, n)
        else
          jsonAppendString(p, z, n);
      end;
    else
      begin
        FillChar(px, SizeOf(px), 0);
        if jsonArgIsJsonb(pValue, @px) <> 0 then
          jsonTranslateBlobToText(@px, 0, p)
        else if p^.eErr = 0 then
        begin
          sqlite3_result_error(Psqlite3_context(p^.pCtx),
            'JSON cannot hold BLOB values', -1);
          p^.eErr := p^.eErr or JSTRING_ERR;
          jsonStringReset(p);
        end;
      end;
  end;
end;

{ json.c:856 — finalise a JSON string and return it as the SQL result. }
procedure jsonReturnString(p: PJsonString; pParse: PJsonParse; pCtx: Pointer);
var
  ctx:   Psqlite3_context;
  flags: PtrInt;
begin
  ctx := Psqlite3_context(pCtx);
  Assert((pParse <> nil) = (ctx <> nil));
  Assert((ctx = nil) or (Pointer(ctx) = p^.pCtx));
  jsonStringTerminate(p);
  if p^.eErr = 0 then
  begin
    flags := PtrInt(sqlite3_user_data(Psqlite3_context(p^.pCtx)));
    if (flags and JSON_BLOB) <> 0 then
      jsonReturnStringAsBlob(p)
    else if p^.bStatic <> 0 then
      sqlite3_result_text64(Psqlite3_context(p^.pCtx),
        p^.zBuf, p^.nUsed, SQLITE_TRANSIENT, SQLITE_UTF8)
    else
    begin
      { json.c:872 — if the source JsonParse has a JSONB blob (nBlobAlloc>0)
        but no cached text yet (bJsonIsRCStr=0), publish the freshly built
        zBuf into the cache via RCStr-Ref so subsequent calls on the same
        ctx hit the cache.  Then hand the buffer to the SQL value with a
        second Ref + sqlite3RCStrUnref destructor (zero-copy ownership
        transfer). }
      if (pParse <> nil)
         and (pParse^.bJsonIsRCStr = 0)
         and (pParse^.nBlobAlloc > 0) then
      begin
        pParse^.zJson := sqlite3RCStrRef(p^.zBuf);
        pParse^.nJson := p^.nUsed;
        pParse^.bJsonIsRCStr := 1;
        if jsonCacheInsert(ctx, pParse) = SQLITE_NOMEM then
        begin
          sqlite3_result_error_nomem(Psqlite3_context(p^.pCtx));
          jsonStringReset(p);
          Exit;
        end;
      end;
      sqlite3_result_text64(Psqlite3_context(p^.pCtx),
        sqlite3RCStrRef(p^.zBuf), p^.nUsed,
        TxDelProc(@sqlite3RCStrUnref), SQLITE_UTF8);
    end;
  end
  else if (p^.eErr and JSTRING_OOM) <> 0 then
    sqlite3_result_error_nomem(Psqlite3_context(p^.pCtx))
  else if (p^.eErr and JSTRING_TOODEEP) <> 0 then
    { error already in p^.pCtx }
  else if (p^.eErr and JSTRING_MALFORMED) <> 0 then
    sqlite3_result_error(Psqlite3_context(p^.pCtx),
      PAnsiChar('malformed JSON'), -1);
  jsonStringReset(p);
end;

{ json.c:2100 — convert a (text) JsonString back into JSONB and return that. }
procedure jsonReturnStringAsBlob(pStr: PJsonString);
var
  px: TJsonParse;
begin
  Assert(pStr^.eErr = 0);
  FillChar(px, SizeOf(px), 0);
  px.zJson := pStr^.zBuf;
  px.nJson := u32(pStr^.nUsed);
  px.db    := sqlite3_context_db_handle(Psqlite3_context(pStr^.pCtx));
  jsonTranslateTextToBlob(@px, 0);
  if px.oom <> 0 then
  begin
    sqlite3DbFree(Psqlite3db(px.db), px.aBlob);
    sqlite3_result_error_nomem(Psqlite3_context(pStr^.pCtx));
  end
  else
  begin
    Assert(px.nBlobAlloc > 0);
    Assert(px.bReadOnly = 0);
    sqlite3_result_blob(Psqlite3_context(pStr^.pCtx),
      px.aBlob, i32(px.nBlob), TxDelProc(SQLITE_DYNAMIC));
  end;
end;

{ json.c:3191 — convert a JSON BLOB to text and return as SQL value. }
procedure jsonReturnTextJsonFromBlob(pCtx: Pointer; aBlob: PByte; nBlob: u32);
var
  x: TJsonParse;
  s: TJsonString;
begin
  if aBlob = nil then Exit;
  FillChar(x, SizeOf(x), 0);
  x.aBlob := aBlob;
  x.nBlob := nBlob;
  jsonStringInit(@s, pCtx);
  jsonTranslateBlobToText(@x, 0, @s);
  jsonReturnString(@s, nil, nil);
end;

{ json.c:3224 — return a single BLOB node as an SQL value.
  eMode:
    0 → JSONB if JSON_BLOB user flag, else text (containers only)
    1 → text
    2 → JSONB }
procedure jsonReturnFromBlob(pParse: PJsonParse; i: u32; pCtx: Pointer;
                             eMode: i32);
label
  to_double, returnfromblob_oom, returnfromblob_malformed;
var
  ctx:    Psqlite3_context;
  db:     Psqlite3db;
  n, sz:  u32;
  rc:     i32;
  iRes:   i64;
  z, zOut:PAnsiChar;
  bNeg:   i32;
  x:      AnsiChar;
  r:      Double;
  iIn,iOut,nOut,v,szEsc: u32;
  c:      AnsiChar;
  flags:  PtrInt;
begin
  ctx := Psqlite3_context(pCtx);
  Assert((eMode >= 0) and (eMode <= 2));
  db := sqlite3_context_db_handle(ctx);
  n := jsonbPayloadSize(pParse, i, sz);
  if n = 0 then
  begin
    sqlite3_result_error(ctx, PAnsiChar('malformed JSON'), -1);
    Exit;
  end;
  case pParse^.aBlob[i] and $0F of
    JSONB_NULL:
      begin
        if sz <> 0 then goto returnfromblob_malformed;
        sqlite3_result_null(ctx);
      end;
    JSONB_TRUE:
      begin
        if sz <> 0 then goto returnfromblob_malformed;
        sqlite3_result_int(ctx, 1);
      end;
    JSONB_FALSE:
      begin
        if sz <> 0 then goto returnfromblob_malformed;
        sqlite3_result_int(ctx, 0);
      end;
    JSONB_INT5, JSONB_INT:
      begin
        iRes := 0;
        bNeg := 0;
        if sz = 0 then goto returnfromblob_malformed;
        x := AnsiChar(pParse^.aBlob[i + n]);
        if x = '-' then
        begin
          if sz < 2 then goto returnfromblob_malformed;
          Inc(n); Dec(sz);
          bNeg := 1;
        end;
        z := sqlite3DbStrNDup(db, PChar(@pParse^.aBlob[i + n]), u64(sz));
        if z = nil then goto returnfromblob_oom;
        rc := sqlite3DecOrHexToI64(z, iRes);
        sqlite3DbFree(db, z);
        if rc = 0 then
        begin
          if iRes < 0 then
          begin
            { 16-digit hex with high bit set → positive in JSON, too
              large for i64 so promote to double. }
            r := Double(u64(iRes));
            if bNeg <> 0 then r := -r;
            sqlite3_result_double(ctx, r);
          end
          else
          begin
            if bNeg <> 0 then iRes := -iRes;
            sqlite3_result_int64(ctx, iRes);
          end;
        end
        else if (rc = 3) and (bNeg <> 0) then
          sqlite3_result_int64(ctx, SMALLEST_INT64)
        else if rc = 1 then
          goto returnfromblob_malformed
        else
        begin
          if bNeg <> 0 then begin Dec(n); Inc(sz); end;
          goto to_double;
        end;
      end;
    JSONB_FLOAT5, JSONB_FLOAT:
      begin
        if sz = 0 then goto returnfromblob_malformed;
to_double:
        z := sqlite3DbStrNDup(db, PChar(@pParse^.aBlob[i + n]), u64(sz));
        if z = nil then goto returnfromblob_oom;
        rc := sqlite3AtoF(z, r);
        sqlite3DbFree(db, z);
        if rc <= 0 then goto returnfromblob_malformed;
        sqlite3_result_double(ctx, r);
      end;
    JSONB_TEXTRAW, JSONB_TEXT:
      sqlite3_result_text(ctx, PAnsiChar(@pParse^.aBlob[i + n]),
        i32(sz), TxDelProc(SQLITE_TRANSIENT));
    JSONB_TEXT5, JSONB_TEXTJ:
      begin
        nOut := sz;
        z    := PAnsiChar(@pParse^.aBlob[i + n]);
        zOut := PAnsiChar(sqlite3DbMallocRaw(db, u64(nOut) + 1));
        if zOut = nil then goto returnfromblob_oom;
        iIn  := 0;
        iOut := 0;
        while iIn < sz do
        begin
          c := z[iIn];
          if c = '\' then
          begin
            szEsc := jsonUnescapeOneChar(@z[iIn], sz - iIn, v);
            if v <= $7F then
            begin
              zOut[iOut] := AnsiChar(v);
              Inc(iOut);
            end
            else if v <= $7FF then
            begin
              Assert(szEsc >= 2);
              zOut[iOut]     := AnsiChar($C0 or (v shr 6));
              zOut[iOut + 1] := AnsiChar($80 or (v and $3F));
              Inc(iOut, 2);
            end
            else if v < $10000 then
            begin
              Assert(szEsc >= 3);
              zOut[iOut]     := AnsiChar($E0 or (v shr 12));
              zOut[iOut + 1] := AnsiChar($80 or ((v shr 6) and $3F));
              zOut[iOut + 2] := AnsiChar($80 or (v and $3F));
              Inc(iOut, 3);
            end
            else if v = JSON_INVALID_CHAR then
              { silently drop illegal codepoint }
            else
            begin
              Assert(szEsc >= 4);
              zOut[iOut]     := AnsiChar($F0 or (v shr 18));
              zOut[iOut + 1] := AnsiChar($80 or ((v shr 12) and $3F));
              zOut[iOut + 2] := AnsiChar($80 or ((v shr 6) and $3F));
              zOut[iOut + 3] := AnsiChar($80 or (v and $3F));
              Inc(iOut, 4);
            end;
            Inc(iIn, szEsc - 1);
          end
          else
          begin
            zOut[iOut] := c;
            Inc(iOut);
          end;
          Inc(iIn);
        end;
        Assert(iOut <= nOut);
        zOut[iOut] := #0;
        sqlite3_result_text(ctx, zOut, i32(iOut), TxDelProc(SQLITE_DYNAMIC));
      end;
    JSONB_ARRAY, JSONB_OBJECT:
      begin
        if eMode = 0 then
        begin
          flags := PtrInt(sqlite3_user_data(ctx));
          if (flags and JSON_BLOB) <> 0 then eMode := 2 else eMode := 1;
        end;
        if eMode = 2 then
          sqlite3_result_blob(ctx, @pParse^.aBlob[i], i32(sz + n),
            TxDelProc(SQLITE_TRANSIENT))
        else
          jsonReturnTextJsonFromBlob(pCtx, @pParse^.aBlob[i], sz + n);
      end;
    else
      goto returnfromblob_malformed;
  end;
  Exit;

returnfromblob_oom:
  sqlite3_result_error_nomem(ctx);
  Exit;

returnfromblob_malformed:
  sqlite3_result_error(ctx, PAnsiChar('malformed JSON'), -1);
end;

{ json.c:3775 — return a JsonParse as the SQL result.  Honours the
  JSON_BLOB user flag: BLOB output skips the text translator entirely. }
procedure jsonReturnParse(pCtx: Pointer; p: PJsonParse);
var
  ctx:   Psqlite3_context;
  flgs:  PtrInt;
  s:     TJsonString;
begin
  ctx := Psqlite3_context(pCtx);
  if p^.oom <> 0 then
  begin
    sqlite3_result_error_nomem(ctx);
    Exit;
  end;
  flgs := PtrInt(sqlite3_user_data(ctx));
  if (flgs and JSON_BLOB) <> 0 then
  begin
    if (p^.nBlobAlloc > 0) and (p^.bReadOnly = 0) then
    begin
      sqlite3_result_blob(ctx, p^.aBlob, i32(p^.nBlob),
        TxDelProc(SQLITE_DYNAMIC));
      p^.nBlobAlloc := 0;
    end
    else
      sqlite3_result_blob(ctx, p^.aBlob, i32(p^.nBlob),
        TxDelProc(SQLITE_TRANSIENT));
  end
  else
  begin
    jsonStringInit(@s, pCtx);
    p^.delta := 0;
    jsonTranslateBlobToText(p, 0, @s);
    jsonReturnString(@s, p, pCtx);
    sqlite3_result_subtype(ctx, JSON_SUBTYPE);
  end;
end;

{ json.c:1134 — odd-arg-count error on json_insert/replace/set. }
procedure jsonWrongNumArgs(pCtx: Pointer; zFuncName: PAnsiChar);
var
  msg: AnsiString;
begin
  msg := AnsiString('json_') + AnsiString(zFuncName) +
    AnsiString('() needs an odd number of arguments');
  sqlite3_result_error(Psqlite3_context(pCtx), PAnsiChar(msg), -1);
end;

{ json.c:3500 — JSON-path lookup error → SQL error or returned message.
  rc is one of JSON_LOOKUP_NOTARRAY / ERROR / TOODEEP, anything else is
  treated as "bad JSON path". }
function jsonBadPathError(pCtx: Pointer; zPath: PAnsiChar; rc: i32): PAnsiChar;
var
  msg: AnsiString;
  ctx: Psqlite3_context;
begin
  ctx := Psqlite3_context(pCtx);
  if u32(rc) = JSON_LOOKUP_NOTARRAY then
    msg := 'not an array element: ' + AnsiString(zPath)
  else if u32(rc) = JSON_LOOKUP_ERROR then
    msg := 'malformed JSON'
  else if u32(rc) = JSON_LOOKUP_TOODEEP then
    msg := 'JSON path too deep'
  else
    msg := 'bad JSON path: ' + AnsiString(zPath);
  if ctx = nil then
  begin
    Result := PAnsiChar(StrAlloc(Length(msg) + 1));
    if Result <> nil then StrPCopy(Result, msg);
    Exit;
  end;
  sqlite3_result_error(ctx, PAnsiChar(msg), -1);
  Result := nil;
end;

{ json.c:3411 — encode a function arg as JSONB inside pParse.
  Returns 0 on success, 1 on error (with a result-error already pushed). }
function jsonFunctionArgToBlob(pCtx: Pointer; pArg: Pointer;
                               pParse: PJsonParse): i32;
const
  aNull: array[0..0] of u8 = (0);
var
  ctx:   Psqlite3_context;
  pVal:  Psqlite3_value;
  eType: i32;
  zJson: PAnsiChar;
  nJson: i32;
  r:     Double;
  z:     PAnsiChar;
  n:     i32;
begin
  ctx   := Psqlite3_context(pCtx);
  pVal  := Psqlite3_value(pArg);
  eType := sqlite3_value_type(pVal);
  FillChar(pParse^, SizeOf(pParse^), 0);
  pParse^.db := sqlite3_context_db_handle(ctx);
  case eType of
    SQLITE_BLOB:
      begin
        if jsonArgIsJsonb(pArg, pParse) = 0 then
        begin
          sqlite3_result_error(ctx,
            PAnsiChar('JSON cannot hold BLOB values'), -1);
          Result := 1;
          Exit;
        end;
      end;
    SQLITE_TEXT:
      begin
        zJson := PAnsiChar(sqlite3_value_text(pVal));
        nJson := sqlite3_value_bytes(pVal);
        if zJson = nil then begin Result := 1; Exit; end;
        if sqlite3_value_subtype(pVal) = JSON_SUBTYPE then
        begin
          pParse^.zJson := zJson;
          pParse^.nJson := nJson;
          if jsonConvertTextToBlob(pParse, pCtx) <> 0 then
          begin
            sqlite3_result_error(ctx, PAnsiChar('malformed JSON'), -1);
            sqlite3DbFree(Psqlite3db(pParse^.db), pParse^.aBlob);
            FillChar(pParse^, SizeOf(pParse^), 0);
            Result := 1;
            Exit;
          end;
        end
        else
          jsonBlobAppendNode(pParse, JSONB_TEXTRAW, u64(nJson), zJson);
      end;
    SQLITE_FLOAT:
      begin
        r := sqlite3_value_double(pVal);
        if r <> r then
          jsonBlobAppendNode(pParse, JSONB_NULL, 0, nil)
        else
        begin
          n := sqlite3_value_bytes(pVal);
          z := PAnsiChar(sqlite3_value_text(pVal));
          if z = nil then begin Result := 1; Exit; end;
          if z[0] = 'I' then
            jsonBlobAppendNode(pParse, JSONB_FLOAT, 5, PAnsiChar('9e999'))
          else if (z[0] = '-') and (z[1] = 'I') then
            jsonBlobAppendNode(pParse, JSONB_FLOAT, 6, PAnsiChar('-9e999'))
          else
            jsonBlobAppendNode(pParse, JSONB_FLOAT, u64(n), z);
        end;
      end;
    SQLITE_INTEGER:
      begin
        n := sqlite3_value_bytes(pVal);
        z := PAnsiChar(sqlite3_value_text(pVal));
        if z = nil then begin Result := 1; Exit; end;
        jsonBlobAppendNode(pParse, JSONB_INT, u64(n), z);
      end;
    else
      begin
        pParse^.aBlob := @aNull[0];
        pParse^.nBlob := 1;
        Result := 0;
        Exit;
      end;
  end;
  if pParse^.oom <> 0 then
  begin
    sqlite3_result_error_nomem(ctx);
    Result := 1;
  end
  else
    Result := 0;
end;

{ ===========================================================================
  Phase 6.8.h.2 — Simple scalar SQL functions
  =========================================================================== }

{ json.c:4044 — true if z[0..n-1] is alphanumeric or underscores. }
function jsonAllAlphanum(z: PAnsiChar; n: i32): i32;
var
  i: i32;
begin
  i := 0;
  while (i < n) and ((sqlite3Isalnum(u8(z[i])) <> 0) or (z[i] = '_')) do
    Inc(i);
  if i = n then Result := 1 else Result := 0;
end;

{ json.c:3960 — json_quote(VALUE).  Render any SQL value as JSON. }
procedure jsonQuoteFunc(pCtx: Psqlite3_context; argc: i32;
                        argv: PPMem); cdecl;
var
  jx: TJsonString;
begin
  if argc < 1 then Exit;
  jsonStringInit(@jx, pCtx);
  jsonAppendSqlValue(@jx, argv[0]);
  jsonReturnString(@jx, nil, nil);
  sqlite3_result_subtype(pCtx, JSON_SUBTYPE);
end;

{ json.c:3979 — json_array(VAL,...).  Build a JSON array from arbitrary
  SQL arguments (json[b]_array; subtype on result is JSON). }
procedure jsonArrayFunc(pCtx: Psqlite3_context; argc: i32;
                        argv: PPMem); cdecl;
var
  i:  i32;
  jx: TJsonString;
begin
  jsonStringInit(@jx, pCtx);
  jsonAppendChar(@jx, '[');
  for i := 0 to argc - 1 do
  begin
    jsonAppendSeparator(@jx);
    jsonAppendSqlValue(@jx, argv[i]);
  end;
  jsonAppendChar(@jx, ']');
  jsonReturnString(@jx, nil, pCtx);
  sqlite3_result_subtype(pCtx, JSON_SUBTYPE);
end;

{ json.c:4424 — json_object(NAME,VALUE,...).  Build a JSON object from
  alternating TEXT/value pairs.  argc must be even. }
procedure jsonObjectFunc(pCtx: Psqlite3_context; argc: i32;
                         argv: PPMem); cdecl;
var
  i:  i32;
  jx: TJsonString;
  z:  PAnsiChar;
  n:  u32;
begin
  if (argc and 1) <> 0 then
  begin
    sqlite3_result_error(pCtx,
      'json_object() requires an even number of arguments', -1);
    Exit;
  end;
  jsonStringInit(@jx, pCtx);
  jsonAppendChar(@jx, '{');
  i := 0;
  while i < argc do
  begin
    if sqlite3_value_type(Psqlite3_value(argv[i])) <> SQLITE_TEXT then
    begin
      sqlite3_result_error(pCtx,
        'json_object() labels must be TEXT', -1);
      jsonStringReset(@jx);
      Exit;
    end;
    jsonAppendSeparator(@jx);
    z := sqlite3_value_text(Psqlite3_value(argv[i]));
    n := u32(sqlite3_value_bytes(Psqlite3_value(argv[i])));
    jsonAppendString(@jx, z, n);
    jsonAppendChar(@jx, ':');
    jsonAppendSqlValue(@jx, argv[i+1]);
    Inc(i, 2);
  end;
  jsonAppendChar(@jx, '}');
  jsonReturnString(@jx, nil, pCtx);
  sqlite3_result_subtype(pCtx, JSON_SUBTYPE);
end;

{ json.c:4005 — json_array_length(JSON [, PATH]).  Element count of the
  top-level array (or array at PATH); 0 if input is not an array. }
procedure jsonArrayLengthFunc(pCtx: Psqlite3_context; argc: i32;
                              argv: PPMem); cdecl;
var
  p:    PJsonParse;
  cnt:  i64;
  i:    u32;
  eErr: u8;
  zPath: PAnsiChar;
begin
  cnt  := 0;
  eErr := 0;
  p := jsonParseFuncArg(pCtx, argv[0], 0);
  if p = nil then Exit;
  if argc = 2 then
  begin
    zPath := PAnsiChar(sqlite3_value_text(argv[1]));
    if zPath = nil then begin jsonParseFree(p); Exit; end;
    if zPath[0] = '$' then
      i := jsonLookupStep(p, 0, zPath + 1, 0)
    else
      i := jsonLookupStep(p, 0, PAnsiChar('@'), 0);
    if jsonLookupIsError(i) then
    begin
      if i <> JSON_LOOKUP_NOTFOUND then
        jsonBadPathError(pCtx, zPath, i32(i));
      eErr := 1;
      i := 0;
    end;
  end
  else
    i := 0;
  if (p^.aBlob[i] and $0F) = JSONB_ARRAY then
    cnt := i64(jsonbArrayCount(p, i));
  if eErr = 0 then
    sqlite3_result_int64(pCtx, cnt);
  jsonParseFree(p);
end;

{ json.c:4573 — json_type(JSON [, PATH]).  Return JSON-type name. }
procedure jsonTypeFunc(pCtx: Psqlite3_context; argc: i32;
                       argv: PPMem); cdecl;
label
  json_type_done;
var
  p:     PJsonParse;
  zPath: PAnsiChar;
  i:     u32;
begin
  p := jsonParseFuncArg(pCtx, argv[0], 0);
  if p = nil then Exit;
  if argc = 2 then
  begin
    zPath := PAnsiChar(sqlite3_value_text(argv[1]));
    if zPath = nil then goto json_type_done;
    if zPath[0] <> '$' then
    begin
      jsonBadPathError(pCtx, zPath, 0);
      goto json_type_done;
    end;
    i := jsonLookupStep(p, 0, zPath + 1, 0);
    if jsonLookupIsError(i) then
    begin
      if i <> JSON_LOOKUP_NOTFOUND then
        jsonBadPathError(pCtx, zPath, i32(i));
      goto json_type_done;
    end;
  end
  else
    i := 0;
  sqlite3_result_text(pCtx, jsonbType[p^.aBlob[i] and $0F], -1, SQLITE_STATIC);
json_type_done:
  jsonParseFree(p);
end;

{ json.c:4618 — json_pretty(JSON [, INDENT]).  Pretty-printed text rendering. }
procedure jsonPrettyFunc(pCtx: Psqlite3_context; argc: i32;
                         argv: PPMem); cdecl;
var
  s: TJsonString;
  x: TJsonPretty;
begin
  FillChar(x, SizeOf(x), 0);
  x.pParse := jsonParseFuncArg(pCtx, argv[0], 0);
  if x.pParse = nil then Exit;
  x.pOut := @s;
  jsonStringInit(@s, pCtx);
  if argc = 1 then
  begin
    x.zIndent  := PAnsiChar('    ');
    x.szIndent := 4;
  end
  else
  begin
    x.zIndent := PAnsiChar(sqlite3_value_text(argv[1]));
    if x.zIndent = nil then
    begin
      x.zIndent  := PAnsiChar('    ');
      x.szIndent := 4;
    end
    else
      x.szIndent := u32(StrLen(x.zIndent));
  end;
  jsonTranslateBlobToPrettyText(@x, 0);
  jsonReturnString(@s, nil, nil);
  jsonParseFree(x.pParse);
end;

{ json.c:4699 — json_valid(JSON [, FLAGS]).  Return 1 if JSON is well-formed. }
procedure jsonValidFunc(pCtx: Psqlite3_context; argc: i32;
                        argv: PPMem); cdecl;
var
  p:     PJsonParse;
  flags: u8;
  res:   u8;
  f:     i64;
  py:    TJsonParse;
begin
  flags := 1;
  res   := 0;
  if argc = 2 then
  begin
    f := sqlite3_value_int64(argv[1]);
    if (f < 1) or (f > 15) then
    begin
      sqlite3_result_error(pCtx,
        PAnsiChar('FLAGS parameter to json_valid() must be between 1 and 15'),
        -1);
      Exit;
    end;
    flags := u8(f and $0F);
  end;
  case sqlite3_value_type(argv[0]) of
    SQLITE_NULL:
      Exit;
    SQLITE_BLOB:
      begin
        FillChar(py, SizeOf(py), 0);
        if jsonArgIsJsonb(argv[0], @py) <> 0 then
        begin
          if (flags and $04) <> 0 then
            res := 1
          else if (flags and $08) <> 0 then
          begin
            if jsonbValidityCheck(@py, 0, py.nBlob, 1) = 0 then
              res := 1;
          end;
          sqlite3_result_int(pCtx, res);
          Exit;
        end;
        { Fall through into text interpretation. }
        if (flags and $03) = 0 then
        begin
          sqlite3_result_int(pCtx, 0);
          Exit;
        end;
        p := jsonParseFuncArg(pCtx, argv[0], JSON_KEEPERROR);
        if p <> nil then
        begin
          if p^.oom <> 0 then
            sqlite3_result_error_nomem(pCtx)
          else if p^.nErr = 0 then
            if ((flags and $02) <> 0) or (p^.hasNonstd = 0) then
              res := 1;
          jsonParseFree(p);
        end
        else
          sqlite3_result_error_nomem(pCtx);
      end;
  else
    begin
      if (flags and $03) = 0 then
      begin
        sqlite3_result_int(pCtx, 0);
        Exit;
      end;
      p := jsonParseFuncArg(pCtx, argv[0], JSON_KEEPERROR);
      if p <> nil then
      begin
        if p^.oom <> 0 then
          sqlite3_result_error_nomem(pCtx)
        else if p^.nErr = 0 then
          if ((flags and $02) <> 0) or (p^.hasNonstd = 0) then
            res := 1;
        jsonParseFree(p);
      end
      else
        sqlite3_result_error_nomem(pCtx);
    end;
  end;
  sqlite3_result_int(pCtx, res);
end;

{ json.c:4781 — json_error_position(JSON).  1-based offset of first parse
  error, 0 if JSON is well-formed, NULL on NULL input. }
procedure jsonErrorFunc(pCtx: Psqlite3_context; argc: i32;
                        argv: PPMem); cdecl;
var
  iErrPos: i64;
  s:       TJsonParse;
  k:       u32;
begin
  if argc <> 1 then Exit;
  iErrPos := 0;
  FillChar(s, SizeOf(s), 0);
  s.db := sqlite3_context_db_handle(pCtx);
  if jsonArgIsJsonb(argv[0], @s) <> 0 then
    iErrPos := i64(jsonbValidityCheck(@s, 0, s.nBlob, 1))
  else
  begin
    s.zJson := PAnsiChar(sqlite3_value_text(argv[0]));
    if s.zJson = nil then Exit;  { NULL input or OOM }
    s.nJson := sqlite3_value_bytes(argv[0]);
    if jsonConvertTextToBlob(@s, nil) <> 0 then
    begin
      if s.oom <> 0 then
        iErrPos := -1
      else
      begin
        { Convert byte-offset s.iErr into a character offset (count
          non-continuation UTF-8 bytes up to s.iErr). }
        k := 0;
        while (k < s.iErr) and (s.zJson[k] <> #0) do
        begin
          if (Byte(s.zJson[k]) and $C0) <> $80 then Inc(iErrPos);
          Inc(k);
        end;
        Inc(iErrPos);
      end;
    end;
  end;
  jsonParseReset(@s);
  if iErrPos < 0 then
    sqlite3_result_error_nomem(pCtx)
  else
    sqlite3_result_int64(pCtx, iErrPos);
end;

{ ===========================================================================
  Phase 6.8.h.3 — Path-driven scalar SQL functions.
  =========================================================================== }

const
  { json.c:4181..4187 — return codes for jsonMergePatch. }
  JSON_MERGE_OK        = 0;
  JSON_MERGE_BADTARGET = 1;
  JSON_MERGE_BADPATCH  = 2;
  JSON_MERGE_OOM       = 3;
  JSON_MERGE_TOODEEP   = 4;

{ json.c:3533 — driver for json_set/_replace/_insert/_array_insert.
  Iterates path/value pairs, applies the requested edit on each, and
  hands the resulting JsonParse to jsonReturnParse for SQL output. }
procedure jsonInsertIntoBlob(pCtx: Psqlite3_context; argc: i32;
                             argv: PPMem; eEdit: i32);
label
  patherror;
var
  i:    i32;
  rc:   u32;
  zPath: PAnsiChar;
  flgs: i32;
  p:    PJsonParse;
  ax:   TJsonParse;
begin
  Assert((argc and 1) = 1);
  zPath := nil;
  rc    := 0;
  if argc = 1 then flgs := 0 else flgs := JSON_EDITABLE;
  p := jsonParseFuncArg(pCtx, argv[0], u32(flgs));
  if p = nil then Exit;
  i := 1;
  while i < argc - 1 do
  begin
    if sqlite3_value_type(argv[i]) = SQLITE_NULL then
    begin
      Inc(i, 2);
      Continue;
    end;
    zPath := PAnsiChar(sqlite3_value_text(argv[i]));
    if zPath = nil then
    begin
      sqlite3_result_error_nomem(pCtx);
      jsonParseFree(p);
      Exit;
    end;
    if zPath[0] <> '$' then goto patherror;
    FillChar(ax, SizeOf(ax), 0);
    if jsonFunctionArgToBlob(pCtx, argv[i + 1], @ax) <> 0 then
    begin
      jsonParseReset(@ax);
      jsonParseFree(p);
      Exit;
    end;
    if zPath[1] = #0 then
    begin
      if (eEdit = JEDIT_REPL) or (eEdit = JEDIT_SET) then
        jsonBlobEdit(p, 0, p^.nBlob, ax.aBlob, ax.nBlob);
      rc := 0;
    end
    else
    begin
      p^.eEdit  := u8(eEdit);
      p^.nIns   := ax.nBlob;
      p^.aIns   := ax.aBlob;
      p^.delta  := 0;
      p^.iDepth := 0;
      rc := jsonLookupStep(p, 0, zPath + 1, 0);
    end;
    jsonParseReset(@ax);
    if rc = JSON_LOOKUP_NOTFOUND then
    begin
      Inc(i, 2);
      Continue;
    end;
    if jsonLookupIsError(rc) then goto patherror;
    Inc(i, 2);
  end;
  jsonReturnParse(pCtx, p);
  jsonParseFree(p);
  Exit;

patherror:
  jsonParseFree(p);
  jsonBadPathError(pCtx, zPath, i32(rc));
end;

{ json.c:4070 — json_extract(JSON, PATH, ...).  Multi-path returns a
  JSON array of the lookups; single-path returns the value itself with
  flag-controlled JSON-vs-SQL rendering for -> / ->>. }
procedure jsonExtractFunc(pCtx: Psqlite3_context; argc: i32;
                          argv: PPMem); cdecl;
label
  json_extract_error;
var
  p:     PJsonParse;
  flags: PtrInt;
  i:     i32;
  jx:    TJsonString;
  zPath: PAnsiChar;
  nPath: i32;
  j:     u32;
begin
  if argc < 2 then Exit;
  p := jsonParseFuncArg(pCtx, argv[0], 0);
  if p = nil then Exit;
  flags := PtrInt(sqlite3_user_data(pCtx));
  jsonStringInit(@jx, pCtx);
  if argc > 2 then jsonAppendChar(@jx, '[');
  for i := 1 to argc - 1 do
  begin
    zPath := PAnsiChar(sqlite3_value_text(argv[i]));
    if zPath = nil then goto json_extract_error;
    nPath := i32(StrLen(zPath));
    if zPath[0] = '$' then
      j := jsonLookupStep(p, 0, zPath + 1, 0)
    else if (flags and JSON_ABPATH) <> 0 then
    begin
      { Abbreviated path forms used by -> / ->>. }
      jsonStringInit(@jx, pCtx);
      if sqlite3_value_type(argv[i]) = SQLITE_INTEGER then
      begin
        jsonAppendRawNZ(@jx, PAnsiChar('['), 1);
        if zPath[0] = '-' then jsonAppendRawNZ(@jx, PAnsiChar('#'), 1);
        jsonAppendRaw(@jx, zPath, u32(nPath));
        jsonAppendRawNZ(@jx, PAnsiChar(']'), 2);
      end
      else if jsonAllAlphanum(zPath, nPath) <> 0 then
      begin
        jsonAppendRawNZ(@jx, PAnsiChar('.'), 1);
        jsonAppendRaw(@jx, zPath, u32(nPath));
      end
      else if (zPath[0] = '[') and (nPath >= 3) and (zPath[nPath - 1] = ']') then
        jsonAppendRaw(@jx, zPath, u32(nPath))
      else
      begin
        jsonAppendRawNZ(@jx, PAnsiChar('."'), 2);
        jsonAppendRaw(@jx, zPath, u32(nPath));
        jsonAppendRawNZ(@jx, PAnsiChar('"'), 1);
      end;
      jsonStringTerminate(@jx);
      j := jsonLookupStep(p, 0, jx.zBuf, 0);
      jsonStringReset(@jx);
    end
    else
    begin
      jsonBadPathError(pCtx, zPath, 0);
      goto json_extract_error;
    end;
    if j < p^.nBlob then
    begin
      if argc = 2 then
      begin
        if (flags and JSON_JSON) <> 0 then
        begin
          jsonStringInit(@jx, pCtx);
          jsonTranslateBlobToText(p, j, @jx);
          jsonReturnString(@jx, nil, nil);
          jsonStringReset(@jx);
          Assert((flags and JSON_BLOB) = 0);
          sqlite3_result_subtype(pCtx, JSON_SUBTYPE);
        end
        else
        begin
          jsonReturnFromBlob(p, j, pCtx, 0);
          if ((flags and (JSON_SQL or JSON_BLOB)) = 0)
             and ((p^.aBlob[j] and $0F) >= JSONB_ARRAY) then
            sqlite3_result_subtype(pCtx, JSON_SUBTYPE);
        end;
      end
      else
      begin
        jsonAppendSeparator(@jx);
        jsonTranslateBlobToText(p, j, @jx);
      end;
    end
    else if j = JSON_LOOKUP_NOTFOUND then
    begin
      if argc = 2 then
        goto json_extract_error
      else
      begin
        jsonAppendSeparator(@jx);
        jsonAppendRawNZ(@jx, PAnsiChar('null'), 4);
      end;
    end
    else
    begin
      jsonBadPathError(pCtx, zPath, i32(j));
      goto json_extract_error;
    end;
  end;
  if argc > 2 then
  begin
    jsonAppendChar(@jx, ']');
    jsonReturnString(@jx, nil, nil);
    if (flags and JSON_BLOB) = 0 then
      sqlite3_result_subtype(pCtx, JSON_SUBTYPE);
  end;
json_extract_error:
  jsonStringReset(@jx);
  jsonParseFree(p);
end;

{ json.c:4466 — json_remove(JSON, PATH, ...).  Each PATH is removed
  in-place; missing paths are silent no-ops. }
procedure jsonRemoveFunc(pCtx: Psqlite3_context; argc: i32;
                         argv: PPMem); cdecl;
label
  json_remove_patherror, json_remove_done;
var
  p:     PJsonParse;
  zPath: PAnsiChar;
  i:     i32;
  rc:    u32;
  flgs:  u32;
begin
  if argc < 1 then Exit;
  zPath := nil;
  if argc > 1 then flgs := JSON_EDITABLE else flgs := 0;
  p := jsonParseFuncArg(pCtx, argv[0], flgs);
  if p = nil then Exit;
  i := 1;
  while i < argc do
  begin
    zPath := PAnsiChar(sqlite3_value_text(argv[i]));
    if zPath = nil then goto json_remove_done;
    if zPath[0] <> '$' then goto json_remove_patherror;
    if zPath[1] = #0 then
    begin
      { json_remove(j,'$') returns NULL. }
      goto json_remove_done;
    end;
    p^.eEdit := JEDIT_DEL;
    p^.delta := 0;
    rc := jsonLookupStep(p, 0, zPath + 1, 0);
    if jsonLookupIsError(rc) then
    begin
      if rc = JSON_LOOKUP_NOTFOUND then
      begin
        Inc(i);
        Continue;
      end
      else
        jsonBadPathError(pCtx, zPath, i32(rc));
      goto json_remove_done;
    end;
    Inc(i);
  end;
  jsonReturnParse(pCtx, p);
  jsonParseFree(p);
  Exit;

json_remove_patherror:
  jsonBadPathError(pCtx, zPath, 0);

json_remove_done:
  jsonParseFree(p);
end;

{ json.c:4521 — json_replace(JSON, PATH, VALUE, ...).  Thin dispatcher. }
procedure jsonReplaceFunc(pCtx: Psqlite3_context; argc: i32;
                          argv: PPMem); cdecl;
begin
  if argc < 1 then Exit;
  if (argc and 1) = 0 then
  begin
    jsonWrongNumArgs(pCtx, PAnsiChar('replace'));
    Exit;
  end;
  jsonInsertIntoBlob(pCtx, argc, argv, JEDIT_REPL);
end;

{ json.c:4547 — json_set / json_insert / json_array_insert dispatcher.
  The discrimination comes from sqlite3_user_data flags. }
procedure jsonSetFunc(pCtx: Psqlite3_context; argc: i32;
                      argv: PPMem); cdecl;
const
  azInsType: array[0..2] of PAnsiChar = ('insert', 'set', 'array_insert');
  aEditType: array[0..2] of u8        = (JEDIT_INS, JEDIT_SET, JEDIT_AINS);
var
  flags:    PtrInt;
  eInsType: i32;
begin
  flags    := PtrInt(sqlite3_user_data(pCtx));
  eInsType := (i32(flags) and $0C) shr 2;   { JSON_INSERT_TYPE(flags) }
  if argc < 1 then Exit;
  Assert((eInsType >= 0) and (eInsType <= 2));
  if (argc and 1) = 0 then
  begin
    jsonWrongNumArgs(pCtx, azInsType[eInsType]);
    Exit;
  end;
  jsonInsertIntoBlob(pCtx, argc, argv, aEditType[eInsType]);
end;

{ json.c:4235 — RFC-7396 MergePatch over two JSONB blobs.  pTarget is
  edited in-place; pPatch is read-only.  See the algorithm comment in
  the C reference for the line-numbered structure mirrored below. }
function jsonMergePatch(pTarget: PJsonParse; iTarget: u32;
                        pPatch: PJsonParse; iPatch: u32;
                        iDepth: u32): i32;
var
  x:        u8;
  n, sz:    u32;
  iTCursor: u32;
  iTStart:  u32;
  iTEndBE:  u32;
  iTEnd:    u32;
  eTLabel:  u8;
  iTLabel, nTLabel, szTLabel: u32;
  iTValue, nTValue, szTValue: u32;
  iPCursor, iPEnd: u32;
  ePLabel: u8;
  iPLabel, nPLabel, szPLabel: u32;
  iPValue, nPValue, szPValue: u32;
  szPatch, szTarget: u32;
  isEqual: i32;
  rc, savedDelta: i32;
  szNew: u32;
begin
  Assert(iTarget < pTarget^.nBlob);
  Assert(iPatch  < pPatch^.nBlob);
  sz := 0;
  x := pPatch^.aBlob[iPatch] and $0F;
  if x <> JSONB_OBJECT then
  begin
    { Algorithm line 02 / 03 — patch is not an Object: replace target. }
    n := jsonbPayloadSize(pPatch, iPatch, sz);
    szPatch := n + sz;
    sz := 0;
    n := jsonbPayloadSize(pTarget, iTarget, sz);
    szTarget := n + sz;
    jsonBlobEdit(pTarget, iTarget, szTarget,
                 PByte(pPatch^.aBlob) + iPatch, szPatch);
    if pTarget^.oom <> 0 then Result := JSON_MERGE_OOM
    else                     Result := JSON_MERGE_OK;
    Exit;
  end;
  x := pTarget^.aBlob[iTarget] and $0F;
  if x <> JSONB_OBJECT then
  begin
    { Algorithm line 05 — coerce target to {}. }
    n := jsonbPayloadSize(pTarget, iTarget, sz);
    jsonBlobEdit(pTarget, iTarget + n, sz, nil, 0);
    x := pTarget^.aBlob[iTarget];
    pTarget^.aBlob[iTarget] := (x and $F0) or JSONB_OBJECT;
  end;
  n := jsonbPayloadSize(pPatch, iPatch, sz);
  if n = 0 then begin Result := JSON_MERGE_BADPATCH; Exit; end;
  iPCursor := iPatch + n;
  iPEnd    := iPCursor + sz;
  n := jsonbPayloadSize(pTarget, iTarget, sz);
  if n = 0 then begin Result := JSON_MERGE_BADTARGET; Exit; end;
  iTStart  := iTarget + n;
  iTEndBE  := iTStart + sz;

  while iPCursor < iPEnd do
  begin
    iPLabel := iPCursor;
    ePLabel := pPatch^.aBlob[iPCursor] and $0F;
    if (ePLabel < JSONB_TEXT) or (ePLabel > JSONB_TEXTRAW) then
    begin Result := JSON_MERGE_BADPATCH; Exit; end;
    nPLabel := jsonbPayloadSize(pPatch, iPCursor, szPLabel);
    if nPLabel = 0 then begin Result := JSON_MERGE_BADPATCH; Exit; end;
    iPValue := iPCursor + nPLabel + szPLabel;
    if iPValue >= iPEnd then begin Result := JSON_MERGE_BADPATCH; Exit; end;
    nPValue := jsonbPayloadSize(pPatch, iPValue, szPValue);
    if nPValue = 0 then begin Result := JSON_MERGE_BADPATCH; Exit; end;
    iPCursor := iPValue + nPValue + szPValue;
    if iPCursor > iPEnd then begin Result := JSON_MERGE_BADPATCH; Exit; end;

    iTCursor := iTStart;
    iTEnd    := iTEndBE + u32(pTarget^.delta);
    iTLabel  := 0; nTLabel := 0; szTLabel := 0;
    iTValue  := 0; nTValue := 0; szTValue := 0;
    eTLabel  := 0;
    isEqual  := 0;
    while iTCursor < iTEnd do
    begin
      iTLabel := iTCursor;
      eTLabel := pTarget^.aBlob[iTCursor] and $0F;
      if (eTLabel < JSONB_TEXT) or (eTLabel > JSONB_TEXTRAW) then
      begin Result := JSON_MERGE_BADTARGET; Exit; end;
      nTLabel := jsonbPayloadSize(pTarget, iTCursor, szTLabel);
      if nTLabel = 0 then begin Result := JSON_MERGE_BADTARGET; Exit; end;
      iTValue := iTLabel + nTLabel + szTLabel;
      if iTValue >= iTEnd then
      begin Result := JSON_MERGE_BADTARGET; Exit; end;
      nTValue := jsonbPayloadSize(pTarget, iTValue, szTValue);
      if nTValue = 0 then begin Result := JSON_MERGE_BADTARGET; Exit; end;
      if iTValue + nTValue + szTValue > iTEnd then
      begin Result := JSON_MERGE_BADTARGET; Exit; end;
      isEqual := jsonLabelCompare(
        PAnsiChar(PByte(pPatch^.aBlob) + iPLabel + nPLabel),
        szPLabel,
        Ord((ePLabel = JSONB_TEXT) or (ePLabel = JSONB_TEXTRAW)),
        PAnsiChar(PByte(pTarget^.aBlob) + iTLabel + nTLabel),
        szTLabel,
        Ord((eTLabel = JSONB_TEXT) or (eTLabel = JSONB_TEXTRAW)));
      if isEqual <> 0 then Break;
      iTCursor := iTValue + nTValue + szTValue;
    end;
    x := pPatch^.aBlob[iPValue] and $0F;
    if iTCursor < iTEnd then
    begin
      { Match found — algorithm line 08. }
      if x = 0 then
      begin
        { Patch value is null — algorithm line 09 — delete the pair. }
        jsonBlobEdit(pTarget, iTLabel,
                     nTLabel + szTLabel + nTValue + szTValue, nil, 0);
        if pTarget^.oom <> 0 then begin Result := JSON_MERGE_OOM; Exit; end;
      end
      else
      begin
        { Algorithm line 12 — recurse on the existing value. }
        savedDelta := pTarget^.delta;
        pTarget^.delta := 0;
        if iDepth >= JSON_MAX_DEPTH then
        begin Result := JSON_MERGE_TOODEEP; Exit; end;
        rc := jsonMergePatch(pTarget, iTValue, pPatch, iPValue, iDepth + 1);
        if rc <> 0 then begin Result := rc; Exit; end;
        pTarget^.delta := pTarget^.delta + savedDelta;
      end;
    end
    else if x > 0 then
    begin
      { Algorithm line 13 — no match and value not null. }
      szNew := szPLabel + nPLabel;
      if (pPatch^.aBlob[iPValue] and $0F) <> JSONB_OBJECT then
      begin
        { Line 14 — append label + non-object value. }
        jsonBlobEdit(pTarget, iTEnd, 0, nil, szPValue + nPValue + szNew);
        if pTarget^.oom <> 0 then begin Result := JSON_MERGE_OOM; Exit; end;
        Move((PByte(pPatch^.aBlob) + iPLabel)^,
             (PByte(pTarget^.aBlob) + iTEnd)^, szNew);
        Move((PByte(pPatch^.aBlob) + iPValue)^,
             (PByte(pTarget^.aBlob) + iTEnd + szNew)^,
             szPValue + nPValue);
      end
      else
      begin
        { Line 17 — append label + empty {} placeholder, then recurse. }
        jsonBlobEdit(pTarget, iTEnd, 0, nil, szNew + 1);
        if pTarget^.oom <> 0 then begin Result := JSON_MERGE_OOM; Exit; end;
        Move((PByte(pPatch^.aBlob) + iPLabel)^,
             (PByte(pTarget^.aBlob) + iTEnd)^, szNew);
        pTarget^.aBlob[iTEnd + szNew] := $00;
        savedDelta := pTarget^.delta;
        pTarget^.delta := 0;
        if iDepth >= JSON_MAX_DEPTH then
        begin Result := JSON_MERGE_TOODEEP; Exit; end;
        rc := jsonMergePatch(pTarget, iTEnd + szNew, pPatch, iPValue,
                             iDepth + 1);
        if rc <> 0 then begin Result := rc; Exit; end;
        pTarget^.delta := pTarget^.delta + savedDelta;
      end;
    end;
  end;
  if pTarget^.delta <> 0 then jsonAfterEditSizeAdjust(pTarget, iTarget);
  if pTarget^.oom <> 0 then Result := JSON_MERGE_OOM
  else                     Result := JSON_MERGE_OK;
end;

{ json.c:4388 — json_patch(TARGET, PATCH).  RFC-7396 wrapper. }
procedure jsonPatchFunc(pCtx: Psqlite3_context; argc: i32;
                        argv: PPMem); cdecl;
var
  pTarget, pPatch: PJsonParse;
  rc:              i32;
begin
  Assert(argc = 2);
  if argc <> 2 then Exit;
  pTarget := jsonParseFuncArg(pCtx, argv[0], JSON_EDITABLE);
  if pTarget = nil then Exit;
  pPatch := jsonParseFuncArg(pCtx, argv[1], 0);
  if pPatch <> nil then
  begin
    rc := jsonMergePatch(pTarget, 0, pPatch, 0, 0);
    if rc = JSON_MERGE_OK then
      jsonReturnParse(pCtx, pTarget)
    else if rc = JSON_MERGE_OOM then
      sqlite3_result_error_nomem(pCtx)
    else if rc = JSON_MERGE_TOODEEP then
      sqlite3_result_error(pCtx, PAnsiChar('JSON nested too deep'), -1)
    else
      sqlite3_result_error(pCtx, PAnsiChar('malformed JSON'), -1);
    jsonParseFree(pPatch);
  end;
  jsonParseFree(pTarget);
end;

{ ===========================================================================
  Phase 6.8.h.4 — Aggregate SQL function implementations
  =========================================================================== }

{ json.c:4829 — json_group_array(VALUE) Step.

  The aggregate context is a zero-initialised TJsonString.  On the first
  call zBuf is nil so we run jsonStringInit (which points zBuf at the
  inline zSpace[]) and seed the buffer with '['.  On every subsequent
  call we drop a ',' separator (provided we already have payload past
  the leading '[' — i.e. nUsed>1) before appending the new value. }
procedure jsonArrayStep(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pStr: PJsonString;
begin
  pStr := PJsonString(sqlite3_aggregate_context(pCtx, SizeOf(TJsonString)));
  if pStr = nil then Exit;
  if pStr^.zBuf = nil then
  begin
    jsonStringInit(pStr, pCtx);
    jsonAppendChar(pStr, '[');
  end
  else if pStr^.nUsed > 1 then
    jsonAppendChar(pStr, ',');
  pStr^.pCtx := pCtx;
  jsonAppendSqlValue(pStr, argv[0]);
end;

{ json.c:4848 — json_group_array Compute (shared by Value/Final).

  Closes the array with ']' and trims to terminate.  isFinal=0 (Value)
  preserves the un-bracketed accumulator state so the next Step can
  resume; isFinal=1 (Final) hands ownership to the SQL value.
  Without sqlite3RCStr we always emit TRANSIENT and let jsonStringReset
  free the spill buffer (jsonReturnString uses the same convention). }
procedure jsonArrayCompute(pCtx: Psqlite3_context; isFinal: i32);
var
  pStr  : PJsonString;
  flags : PtrInt;
  emptyArr : array[0..0] of u8;
begin
  flags := PtrInt(sqlite3_user_data(pCtx));
  pStr := PJsonString(sqlite3_aggregate_context(pCtx, 0));
  if pStr <> nil then
  begin
    pStr^.pCtx := pCtx;
    jsonAppendRawNZ(pStr, PAnsiChar(']'), 2);
    jsonStringTrimOneChar(pStr);
    if pStr^.eErr <> 0 then
    begin
      jsonReturnString(pStr, nil, nil);
      Exit;
    end
    else if (flags and JSON_BLOB) <> 0 then
    begin
      jsonReturnStringAsBlob(pStr);
      if isFinal <> 0 then
      begin
        if pStr^.bStatic = 0 then
          sqlite3RCStrUnref(pStr^.zBuf);
      end
      else
        jsonStringTrimOneChar(pStr);
      Exit;
    end
    else if isFinal <> 0 then
    begin
      if pStr^.bStatic <> 0 then
        sqlite3_result_text(pCtx, pStr^.zBuf, i32(pStr^.nUsed), SQLITE_TRANSIENT)
      else
        sqlite3_result_text(pCtx, pStr^.zBuf, i32(pStr^.nUsed),
          TxDelProc(@sqlite3RCStrUnref));
      pStr^.bStatic := 1;  { ownership transferred — don't double-free }
    end
    else
    begin
      sqlite3_result_text(pCtx, pStr^.zBuf, i32(pStr^.nUsed), SQLITE_TRANSIENT);
      jsonStringTrimOneChar(pStr);
    end;
  end
  else if (flags and JSON_BLOB) <> 0 then
  begin
    emptyArr[0] := $0B;  { JSONB_ARRAY, payload size 0 }
    sqlite3_result_blob(pCtx, @emptyArr[0], 1, SQLITE_TRANSIENT);
  end
  else
    sqlite3_result_text(pCtx, PAnsiChar('[]'), 2, SQLITE_STATIC);
  sqlite3_result_subtype(pCtx, JSON_SUBTYPE);
end;

procedure jsonArrayValue(pCtx: Psqlite3_context); cdecl;
begin
  jsonArrayCompute(pCtx, 0);
end;

procedure jsonArrayFinal(pCtx: Psqlite3_context); cdecl;
begin
  jsonArrayCompute(pCtx, 1);
end;

(* json.c:4898 — jsonGroupInverse: drop the first stepped element.

  Walks forward from the leading '[' / '{' (zBuf[0]) until it finds an
  unquoted, top-level comma, then memmoves the tail back over it.
  When the search runs off the end the entire body is empty so we
  collapse nUsed back to 1 (just the leading bracket). *)
procedure jsonGroupInverse(pCtx: Psqlite3_context;
                           argc: i32; argv: PPMem); cdecl;
var
  pStr  : PJsonString;
  i     : u32;
  inStr : i32;
  nNest : i32;
  z     : PAnsiChar;
  c     : AnsiChar;
begin
  pStr := PJsonString(sqlite3_aggregate_context(pCtx, 0));
  if pStr = nil then Exit;
  z := pStr^.zBuf;
  inStr := 0;
  nNest := 0;
  i := 1;
  while i < pStr^.nUsed do
  begin
    c := z[i];
    if (c = ',') and (inStr = 0) and (nNest = 0) then Break;
    if c = '"' then
      inStr := 1 - inStr
    else if c = #$5C then  { backslash — skip the escaped byte }
      Inc(i)
    else if inStr = 0 then
    begin
      if (c = '{') or (c = '[') then Inc(nNest);
      if (c = '}') or (c = ']') then Dec(nNest);
    end;
    Inc(i);
  end;
  if i < pStr^.nUsed then
  begin
    pStr^.nUsed := pStr^.nUsed - i;
    Move(z[i + 1], z[1], pStr^.nUsed - 1);
    z[pStr^.nUsed] := #0;
  end
  else
    pStr^.nUsed := 1;
end;

(* json.c:4946 — json_group_object(NAME, VALUE) Step.

  Same pattern as jsonArrayStep, but seeds with brace-open instead of
  bracket-open and appends NAME (escaped JSON string), ':', then VALUE.
  When NAME is SQL NULL (z=nil from sqlite3_value_text) we silently
  skip the row — matches C, which only ever appends ',' before
  observing the NAME value.  Note: C still drops a stray ',' even
  when z=nil; we mirror that exactly. *)
procedure jsonObjectStep(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pStr : PJsonString;
  z    : PAnsiChar;
  n    : u32;
begin
  pStr := PJsonString(sqlite3_aggregate_context(pCtx, SizeOf(TJsonString)));
  if pStr = nil then Exit;
  z := PAnsiChar(sqlite3_value_text(Psqlite3_value(argv[0])));
  if z <> nil then
    n := u32(StrLen(z))
  else
    n := 0;
  if pStr^.zBuf = nil then
  begin
    jsonStringInit(pStr, pCtx);
    jsonAppendChar(pStr, '{');
  end
  else if (pStr^.nUsed > 1) and (z <> nil) then
    jsonAppendChar(pStr, ',');
  pStr^.pCtx := pCtx;
  if z <> nil then
  begin
    jsonAppendString(pStr, z, n);
    jsonAppendChar(pStr, ':');
    jsonAppendSqlValue(pStr, argv[1]);
  end;
end;

procedure jsonObjectCompute(pCtx: Psqlite3_context; isFinal: i32);
var
  pStr  : PJsonString;
  flags : PtrInt;
  emptyObj : array[0..0] of u8;
begin
  flags := PtrInt(sqlite3_user_data(pCtx));
  pStr := PJsonString(sqlite3_aggregate_context(pCtx, 0));
  if pStr <> nil then
  begin
    jsonAppendRawNZ(pStr, PAnsiChar('}'), 2);
    jsonStringTrimOneChar(pStr);
    pStr^.pCtx := pCtx;
    if pStr^.eErr <> 0 then
    begin
      jsonReturnString(pStr, nil, nil);
      Exit;
    end
    else if (flags and JSON_BLOB) <> 0 then
    begin
      jsonReturnStringAsBlob(pStr);
      if isFinal <> 0 then
      begin
        if pStr^.bStatic = 0 then
          sqlite3RCStrUnref(pStr^.zBuf);
      end
      else
        jsonStringTrimOneChar(pStr);
      Exit;
    end
    else if isFinal <> 0 then
    begin
      if pStr^.bStatic <> 0 then
        sqlite3_result_text(pCtx, pStr^.zBuf, i32(pStr^.nUsed), SQLITE_TRANSIENT)
      else
        sqlite3_result_text(pCtx, pStr^.zBuf, i32(pStr^.nUsed),
          TxDelProc(@sqlite3RCStrUnref));
      pStr^.bStatic := 1;  { ownership transferred — don't double-free }
    end
    else
    begin
      sqlite3_result_text(pCtx, pStr^.zBuf, i32(pStr^.nUsed), SQLITE_TRANSIENT);
      jsonStringTrimOneChar(pStr);
    end;
  end
  else if (flags and JSON_BLOB) <> 0 then
  begin
    emptyObj[0] := $0C;  { JSONB_OBJECT, payload size 0 }
    sqlite3_result_blob(pCtx, @emptyObj[0], 1, SQLITE_TRANSIENT);
  end
  else
    sqlite3_result_text(pCtx, PAnsiChar('{}'), 2, SQLITE_STATIC);
  sqlite3_result_subtype(pCtx, JSON_SUBTYPE);
end;

procedure jsonObjectValue(pCtx: Psqlite3_context); cdecl;
begin
  jsonObjectCompute(pCtx, 0);
end;

procedure jsonObjectFinal(pCtx: Psqlite3_context); cdecl;
begin
  jsonObjectCompute(pCtx, 1);
end;

end.
