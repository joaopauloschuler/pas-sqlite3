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
unit passqlite3fts3;

{
  Phase 6.40.1.a / 6.40.1.b — foundation of the FTS3/FTS4 full-text-search
  port.  This unit is the new home for the entire ext/fts3/ cluster
  (tasklist 6.40.1); subsequent sub-tasks (.c .. .o) extend it.

  6.40.1.a — ABI type/record declarations:
    * fts3.h                (../sqlite3/ext/fts3/fts3.h, 26L) — declares only
      sqlite3Fts3Init(); ported as a forward (not yet implemented, 6.40.1.o).
    * fts3_tokenizer.h      (../sqlite3/ext/fts3/fts3_tokenizer.h) — the
      public tokenizer interface: sqlite3_tokenizer, sqlite3_tokenizer_module
      (a C-ABI vtable of cdecl function pointers) and
      sqlite3_tokenizer_cursor.
    * fts3_hash.h           (../sqlite3/ext/fts3/fts3_hash.h) — Fts3Hash,
      Fts3HashElem, the FTS3_HASH_* constants and the macro-style accessors.

  6.40.1.b — fts3_hash.c (../sqlite3/ext/fts3/fts3_hash.c, 383L): the
    standalone string/binary hash table used throughout FTS3
    (sqlite3Fts3HashInit / Insert / Find / Clear / FindElem plus the static
    helpers).  Allocates only through sqlite3_malloc64 / sqlite3_free.

  Gate: src/tests/TestFts3Hash.pas exercises init / insert / find /
  overwrite / delete-via-NULL / rehash / clear of a FTS3_HASH_STRING table.

  NOTE on FPC porting: the FTS3 hash stores raw void* keys/data; the records
  below keep all key/data fields as plain Pointer so no managed-string
  ref-counting ever runs over the GetMem'd blocks (the New()-on-managed-record
  hazard documented in MEMORY.md does not apply).
}

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os;

const
  { fts3_hash.h:68..69 — key-class modes. }
  FTS3_HASH_STRING = 1;
  FTS3_HASH_BINARY = 2;

  { fts3_tokenizer.h — tokenizer-module structure version sentinel; the
    xLanguageid slot is only present/used for iVersion>=1. }
  FTS3_TOKENIZER_IVERSION0 = 0;
  FTS3_TOKENIZER_IVERSION1 = 1;

type
  { ===================================================================== }
  { fts3_tokenizer.h — public tokenizer interface (C ABI).                }
  { ===================================================================== }

  Psqlite3_tokenizer        = ^Tsqlite3_tokenizer;
  Psqlite3_tokenizer_module = ^Tsqlite3_tokenizer_module;
  Psqlite3_tokenizer_cursor = ^Tsqlite3_tokenizer_cursor;

  PPsqlite3_tokenizer        = ^Psqlite3_tokenizer;
  PPsqlite3_tokenizer_cursor = ^Psqlite3_tokenizer_cursor;
  PPsqlite3_tokenizer_module = ^Psqlite3_tokenizer_module;

  { fts3_tokenizer.h:76..80 — xCreate.
    int (*xCreate)(int argc, const char *const*argv,
                   sqlite3_tokenizer **ppTokenizer) }
  TFts3TokXCreate = function(argc: cint; const argv: PPChar;
    ppTokenizer: PPsqlite3_tokenizer): cint; cdecl;

  { fts3_tokenizer.h:86 — int (*xDestroy)(sqlite3_tokenizer *pTokenizer) }
  TFts3TokXDestroy = function(pTokenizer: Psqlite3_tokenizer): cint; cdecl;

  { fts3_tokenizer.h:93..97 — xOpen.
    int (*xOpen)(sqlite3_tokenizer *pTokenizer, const char *pInput,
                 int nBytes, sqlite3_tokenizer_cursor **ppCursor) }
  TFts3TokXOpen = function(pTokenizer: Psqlite3_tokenizer; const pInput: PChar;
    nBytes: cint; ppCursor: PPsqlite3_tokenizer_cursor): cint; cdecl;

  { fts3_tokenizer.h:103 — int (*xClose)(sqlite3_tokenizer_cursor *pCursor) }
  TFts3TokXClose = function(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;

  { fts3_tokenizer.h:129..135 — xNext.
    int (*xNext)(sqlite3_tokenizer_cursor *pCursor,
                 const char **ppToken, int *pnBytes,
                 int *piStartOffset, int *piEndOffset, int *piPosition) }
  TFts3TokXNext = function(pCursor: Psqlite3_tokenizer_cursor;
    ppToken: PPChar; pnBytes: Pcint;
    piStartOffset: Pcint; piEndOffset: Pcint; piPosition: Pcint): cint; cdecl;

  { fts3_tokenizer.h:144 — only available when iVersion>=1.
    int (*xLanguageid)(sqlite3_tokenizer_cursor *pCsr, int iLangid) }
  TFts3TokXLanguageid = function(pCsr: Psqlite3_tokenizer_cursor;
    iLangid: cint): cint; cdecl;

  { fts3_tokenizer.h:52..145 — struct sqlite3_tokenizer_module.
    The class structure (vtable) for tokenizers. }
  Tsqlite3_tokenizer_module = record
    iVersion    : cint;            { Should always be set to 0 or 1. }
    xCreate     : TFts3TokXCreate;
    xDestroy    : TFts3TokXDestroy;
    xOpen       : TFts3TokXOpen;
    xClose      : TFts3TokXClose;
    xNext       : TFts3TokXNext;
    { Methods below this point are only available if iVersion>=1. }
    xLanguageid : TFts3TokXLanguageid;
  end;

  { fts3_tokenizer.h:147..150 — struct sqlite3_tokenizer.
    Tokenizer implementations typically append additional fields. }
  Tsqlite3_tokenizer = record
    pModule : Psqlite3_tokenizer_module;  { The module for this tokenizer }
  end;

  { fts3_tokenizer.h:152..155 — struct sqlite3_tokenizer_cursor.
    Tokenizer implementations typically append additional fields. }
  Tsqlite3_tokenizer_cursor = record
    pTokenizer : Psqlite3_tokenizer;      { Tokenizer for this cursor. }
  end;

  { ===================================================================== }
  { fts3_hash.h — standalone hash table.                                  }
  { ===================================================================== }

  PFts3Hash     = ^TFts3Hash;
  PFts3HashElem = ^TFts3HashElem;
  PPFts3HashElem = ^PFts3HashElem;

  { fts3_hash.h:38..41 — struct _fts3ht (one hash bucket). }
  PFts3Ht = ^TFts3Ht;
  TFts3Ht = record
    count : cint;            { Number of entries with this hash }
    chain : PFts3HashElem;   { Pointer to first entry with this hash }
  end;

  { fts3_hash.h:50..54 — struct Fts3HashElem.
    All elements are stored on a single doubly-linked list.  Keys/data are
    raw void* (kept as Pointer; never managed). }
  TFts3HashElem = record
    next : PFts3HashElem;    { Next element in the table }
    prev : PFts3HashElem;    { Previous element in the table }
    data : Pointer;          { Data associated with this element }
    pKey : Pointer;          { Key associated with this element }
    nKey : cint;
  end;

  { fts3_hash.h:32..42 — struct Fts3Hash. }
  TFts3Hash = record
    keyClass : cchar;        { HASH_INT, _POINTER, _STRING, _BINARY }
    copyKey  : cchar;        { True if copy of key made on insert }
    count    : cint;         { Number of entries in this table }
    first    : PFts3HashElem; { The first element of the array }
    htsize   : cint;         { Number of buckets in the hash table }
    ht       : PFts3Ht;      { the hash table }
  end;

{ --------------------------------------------------------------------- }
{ fts3.h:22 — declares the FTS3 library entry point.  Implemented in    }
{ task 6.40.1.o; here only as the public signature the cluster targets. }
{ --------------------------------------------------------------------- }
{ function sqlite3Fts3Init(db: Psqlite3): cint;  -- forward, see 6.40.1.o }

{ --------------------------------------------------------------------- }
{ fts3_hash.h:74..78 — access routines.  To delete, insert a NULL ptr.  }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3HashInit(pNew: PFts3Hash; keyClass: cchar; copyKey: cchar);
function  sqlite3Fts3HashInsert(pH: PFts3Hash; const pKey: Pointer; nKey: cint;
  data: Pointer): Pointer;
function  sqlite3Fts3HashFind(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint): Pointer;
procedure sqlite3Fts3HashClear(pH: PFts3Hash);
function  sqlite3Fts3HashFindElem(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint): PFts3HashElem;

{ fts3_hash.h:101..110 — macro-style accessors, ported as inline helpers. }
function fts3HashFirst(const H: PFts3Hash): PFts3HashElem; inline;
function fts3HashNext(const E: PFts3HashElem): PFts3HashElem; inline;
function fts3HashData(const E: PFts3HashElem): Pointer; inline;
function fts3HashKey(const E: PFts3HashElem): Pointer; inline;
function fts3HashKeysize(const E: PFts3HashElem): cint; inline;
function fts3HashCount(const H: PFts3Hash): cint; inline;

{ --------------------------------------------------------------------- }
{ 6.40.1.c — fts3_tokenizer1.c:228..232 — the built-in "simple"         }
{ tokenizer module entry point.                                          }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3SimpleTokenizerModule(ppModule: PPsqlite3_tokenizer_module);

{ --------------------------------------------------------------------- }
{ 6.40.1.d — fts3_porter.c:656..660 — the "porter" stemmer tokenizer    }
{ module entry point.                                                    }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3PorterTokenizerModule(ppModule: PPsqlite3_tokenizer_module);

{ --------------------------------------------------------------------- }
{ 6.40.1.e — fts3_unicode2.c — Unicode codepoint classification.         }
{ --------------------------------------------------------------------- }
function sqlite3FtsUnicodeIsalnum(c: cint): cint;
function sqlite3FtsUnicodeIsdiacritic(c: cint): cint;
function sqlite3FtsUnicodeFold(c: cint; eRemoveDiacritic: cint): cint;

{ --------------------------------------------------------------------- }
{ 6.40.1.f — fts3_unicode.c:383..394 — the "unicode61" tokenizer module  }
{ entry point.                                                           }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3UnicodeTokenizer(ppModule: PPsqlite3_tokenizer_module);

implementation

{ libc bindings (match the amatch/fuzzer pattern; avoids depending on a
  csize_t alias from elsewhere). }
function libc_strlen(s: PChar): NativeUInt; cdecl; external 'c' name 'strlen';
function libc_memcpy(dst, src: Pointer; n: NativeUInt): Pointer; cdecl;
  external 'c' name 'memcpy';
procedure libc_memset(dst: Pointer; c: cint; n: NativeUInt); cdecl;
  external 'c' name 'memset';
function libc_strncmp(a, b: PChar; n: NativeUInt): cint; cdecl;
  external 'c' name 'strncmp';
function libc_memcmp(a, b: Pointer; n: NativeUInt): cint; cdecl;
  external 'c' name 'memcmp';

{ Function-pointer types for the key-class-selected hash/compare fns. }
type
  TFts3HashFn    = function(const pKey: Pointer; nKey: cint): cint;
  TFts3CompareFn = function(const pKey1: Pointer; n1: cint;
    const pKey2: Pointer; n2: cint): cint;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:38..47 — Malloc and Free functions.                       }
{ --------------------------------------------------------------------- }
function fts3HashMalloc(n: sqlite3_int64): Pointer;
begin
  Result := sqlite3_malloc64(u64(n));
  if Result <> nil then
    libc_memset(Result, 0, NativeUInt(n));
end;

procedure fts3HashFree(p: Pointer);
begin
  sqlite3_free(p);
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:59..68 — sqlite3Fts3HashInit.                             }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3HashInit(pNew: PFts3Hash; keyClass: cchar; copyKey: cchar);
begin
  Assert(pNew <> nil);
  Assert((keyClass >= FTS3_HASH_STRING) and (keyClass <= FTS3_HASH_BINARY));
  pNew^.keyClass := keyClass;
  pNew^.copyKey := copyKey;
  pNew^.first := nil;
  pNew^.count := 0;
  pNew^.htsize := 0;
  pNew^.ht := nil;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:74..92 — sqlite3Fts3HashClear.  Remove all entries and    }
{ reclaim all memory.                                                   }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3HashClear(pH: PFts3Hash);
var
  elem, next_elem: PFts3HashElem;
begin
  Assert(pH <> nil);
  elem := pH^.first;
  pH^.first := nil;
  fts3HashFree(pH^.ht);
  pH^.ht := nil;
  pH^.htsize := 0;
  while elem <> nil do begin
    next_elem := elem^.next;
    if (pH^.copyKey <> 0) and (elem^.pKey <> nil) then
      fts3HashFree(elem^.pKey);
    fts3HashFree(elem);
    elem := next_elem;
  end;
  pH^.count := 0;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:97..106 — fts3StrHash (FTS3_HASH_STRING).                  }
{ --------------------------------------------------------------------- }
function fts3StrHash(const pKey: Pointer; nKey: cint): cint;
var
  z: PByte;
  h: cuint;
begin
  z := PByte(pKey);
  h := 0;
  if nKey <= 0 then nKey := cint(libc_strlen(PChar(pKey)));
  while nKey > 0 do begin
    h := (h shl 3) xor h xor cuint(z^);
    Inc(z);
    Dec(nKey);
  end;
  Result := cint(h and $7fffffff);
end;

{ fts3_hash.c:107..110 — fts3StrCompare. }
function fts3StrCompare(const pKey1: Pointer; n1: cint;
  const pKey2: Pointer; n2: cint): cint;
begin
  if n1 <> n2 then Exit(1);
  Result := libc_strncmp(PChar(pKey1), PChar(pKey2), NativeUInt(n1));
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:115..122 — fts3BinHash (FTS3_HASH_BINARY).                 }
{ --------------------------------------------------------------------- }
function fts3BinHash(const pKey: Pointer; nKey: cint): cint;
var
  h: cint;
  z: PByte;
begin
  h := 0;
  z := PByte(pKey);
  while nKey > 0 do begin
    Dec(nKey);                 { C: while( nKey-- > 0 ) — test then decrement }
    h := (h shl 3) xor h xor cint(z^);
    Inc(z);
  end;
  Result := h and $7fffffff;
end;

{ fts3_hash.c:123..126 — fts3BinCompare. }
function fts3BinCompare(const pKey1: Pointer; n1: cint;
  const pKey2: Pointer; n2: cint): cint;
begin
  if n1 <> n2 then Exit(1);
  Result := libc_memcmp(pKey1, pKey2, NativeUInt(n1));
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:140..147 — ftsHashFunction: pick hash fn by key class.    }
{ --------------------------------------------------------------------- }
function ftsHashFunction(keyClass: cint): TFts3HashFn;
begin
  if keyClass = FTS3_HASH_STRING then
    Result := @fts3StrHash
  else begin
    Assert(keyClass = FTS3_HASH_BINARY);
    Result := @fts3BinHash;
  end;
end;

{ fts3_hash.c:155..162 — ftsCompareFunction: pick compare fn by key class. }
function ftsCompareFunction(keyClass: cint): TFts3CompareFn;
begin
  if keyClass = FTS3_HASH_STRING then
    Result := @fts3StrCompare
  else begin
    Assert(keyClass = FTS3_HASH_BINARY);
    Result := @fts3BinCompare;
  end;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:166..187 — fts3HashInsertElement: link an element in.     }
{ --------------------------------------------------------------------- }
procedure fts3HashInsertElement(pH: PFts3Hash; pEntry: PFts3Ht;
  pNew: PFts3HashElem);
var
  pHead: PFts3HashElem;
begin
  pHead := pEntry^.chain;
  if pHead <> nil then begin
    pNew^.next := pHead;
    pNew^.prev := pHead^.prev;
    if pHead^.prev <> nil then
      pHead^.prev^.next := pNew
    else
      pH^.first := pNew;
    pHead^.prev := pNew;
  end else begin
    pNew^.next := pH^.first;
    if pH^.first <> nil then
      pH^.first^.prev := pNew;
    pNew^.prev := nil;
    pH^.first := pNew;
  end;
  Inc(pEntry^.count);
  pEntry^.chain := pNew;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:196..214 — fts3Rehash: resize the table to new_size       }
{ buckets (a power of 2).  Returns non-zero on malloc failure.          }
{ --------------------------------------------------------------------- }
function fts3Rehash(pH: PFts3Hash; new_size: cint): cint;
var
  new_ht: PFts3Ht;
  elem, next_elem: PFts3HashElem;
  xHash: TFts3HashFn;
  h: cint;
begin
  Assert((new_size and (new_size - 1)) = 0);
  new_ht := PFts3Ht(fts3HashMalloc(sqlite3_int64(new_size) * SizeOf(TFts3Ht)));
  if new_ht = nil then Exit(1);
  fts3HashFree(pH^.ht);
  pH^.ht := new_ht;
  pH^.htsize := new_size;
  xHash := ftsHashFunction(pH^.keyClass);
  elem := pH^.first;
  pH^.first := nil;
  while elem <> nil do begin
    h := xHash(elem^.pKey, elem^.nKey) and (new_size - 1);
    next_elem := elem^.next;
    fts3HashInsertElement(pH, @new_ht[h], elem);
    elem := next_elem;
  end;
  Result := 0;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:220..243 — fts3FindElementByHash.                         }
{ --------------------------------------------------------------------- }
function fts3FindElementByHash(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint; h: cint): PFts3HashElem;
var
  elem: PFts3HashElem;
  count: cint;
  xCompare: TFts3CompareFn;
  pEntry: PFts3Ht;
begin
  if pH^.ht <> nil then begin
    pEntry := @pH^.ht[h];
    elem := pEntry^.chain;
    count := pEntry^.count;
    xCompare := ftsCompareFunction(pH^.keyClass);
    { C: while( count-- && elem ) — post-decrement, short-circuit }
    while (count > 0) and (elem <> nil) do begin
      Dec(count);
      if xCompare(elem^.pKey, elem^.nKey, pKey, nKey) = 0 then
        Exit(elem);
      elem := elem^.next;
    end;
  end;
  Result := nil;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:248..280 — fts3RemoveElementByHash.                       }
{ --------------------------------------------------------------------- }
procedure fts3RemoveElementByHash(pH: PFts3Hash; elem: PFts3HashElem; h: cint);
var
  pEntry: PFts3Ht;
begin
  if elem^.prev <> nil then
    elem^.prev^.next := elem^.next
  else
    pH^.first := elem^.next;
  if elem^.next <> nil then
    elem^.next^.prev := elem^.prev;
  pEntry := @pH^.ht[h];
  if pEntry^.chain = elem then
    pEntry^.chain := elem^.next;
  Dec(pEntry^.count);
  if pEntry^.count <= 0 then
    pEntry^.chain := nil;
  if (pH^.copyKey <> 0) and (elem^.pKey <> nil) then
    fts3HashFree(elem^.pKey);
  fts3HashFree(elem);
  Dec(pH^.count);
  if pH^.count <= 0 then begin
    Assert(pH^.first = nil);
    Assert(pH^.count = 0);
    sqlite3Fts3HashClear(pH);
  end;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:282..296 — sqlite3Fts3HashFindElem.                       }
{ --------------------------------------------------------------------- }
function sqlite3Fts3HashFindElem(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint): PFts3HashElem;
var
  h: cint;
  xHash: TFts3HashFn;
begin
  if (pH = nil) or (pH^.ht = nil) then Exit(nil);
  xHash := ftsHashFunction(pH^.keyClass);
  Assert(xHash <> nil);
  h := xHash(pKey, nKey);
  Assert((pH^.htsize and (pH^.htsize - 1)) = 0);
  Result := fts3FindElementByHash(pH, pKey, nKey, h and (pH^.htsize - 1));
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:303..308 — sqlite3Fts3HashFind.                           }
{ --------------------------------------------------------------------- }
function sqlite3Fts3HashFind(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint): Pointer;
var
  pElem: PFts3HashElem;
begin
  pElem := sqlite3Fts3HashFindElem(pH, pKey, nKey);
  if pElem <> nil then
    Result := pElem^.data
  else
    Result := nil;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:325..381 — sqlite3Fts3HashInsert.                         }
{ --------------------------------------------------------------------- }
function sqlite3Fts3HashInsert(pH: PFts3Hash; const pKey: Pointer; nKey: cint;
  data: Pointer): Pointer;
var
  hraw: cint;             { Raw hash value of the key }
  h: cint;                { the hash of the key modulo hash table size }
  elem: PFts3HashElem;
  new_elem: PFts3HashElem;
  xHash: TFts3HashFn;
  old_data: Pointer;
begin
  Assert(pH <> nil);
  xHash := ftsHashFunction(pH^.keyClass);
  Assert(xHash <> nil);
  hraw := xHash(pKey, nKey);
  Assert((pH^.htsize and (pH^.htsize - 1)) = 0);
  h := hraw and (pH^.htsize - 1);
  elem := fts3FindElementByHash(pH, pKey, nKey, h);
  if elem <> nil then begin
    old_data := elem^.data;
    if data = nil then
      fts3RemoveElementByHash(pH, elem, h)
    else
      elem^.data := data;
    Exit(old_data);
  end;
  if data = nil then Exit(nil);
  if ((pH^.htsize = 0) and (fts3Rehash(pH, 8) <> 0))
  or ((pH^.count >= pH^.htsize) and (fts3Rehash(pH, pH^.htsize * 2) <> 0)) then
  begin
    pH^.count := 0;
    Exit(data);
  end;
  Assert(pH^.htsize > 0);
  new_elem := PFts3HashElem(fts3HashMalloc(SizeOf(TFts3HashElem)));
  if new_elem = nil then Exit(data);
  if (pH^.copyKey <> 0) and (pKey <> nil) then begin
    new_elem^.pKey := fts3HashMalloc(nKey);
    if new_elem^.pKey = nil then begin
      fts3HashFree(new_elem);
      Exit(data);
    end;
    libc_memcpy(new_elem^.pKey, pKey, NativeUInt(nKey));
  end else
    new_elem^.pKey := pKey;
  new_elem^.nKey := nKey;
  Inc(pH^.count);
  Assert(pH^.htsize > 0);
  Assert((pH^.htsize and (pH^.htsize - 1)) = 0);
  h := hraw and (pH^.htsize - 1);
  fts3HashInsertElement(pH, @pH^.ht[h], new_elem);
  new_elem^.data := data;
  Result := nil;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.h:101..110 — macro-style accessors.                         }
{ --------------------------------------------------------------------- }
function fts3HashFirst(const H: PFts3Hash): PFts3HashElem;
begin
  Result := H^.first;
end;

function fts3HashNext(const E: PFts3HashElem): PFts3HashElem;
begin
  Result := E^.next;
end;

function fts3HashData(const E: PFts3HashElem): Pointer;
begin
  Result := E^.data;
end;

function fts3HashKey(const E: PFts3HashElem): Pointer;
begin
  Result := E^.pKey;
end;

function fts3HashKeysize(const E: PFts3HashElem): cint;
begin
  Result := E^.nKey;
end;

function fts3HashCount(const H: PFts3Hash): cint;
begin
  Result := H^.count;
end;

{ ===================================================================== }
{ 6.40.1.c — fts3_tokenizer1.c — the built-in "simple" tokenizer.        }
{ ===================================================================== }

type
  { fts3_tokenizer1.c:35..38 — struct simple_tokenizer.
    Derives from sqlite3_tokenizer; appends a 128-byte ASCII delimiter
    flag array.  delim[c] is non-zero when c is a delimiter. }
  Psimple_tokenizer = ^Tsimple_tokenizer;
  Tsimple_tokenizer = record
    base  : Tsqlite3_tokenizer;
    delim : array[0..127] of cchar;   { flag ASCII delimiters }
  end;

  { fts3_tokenizer1.c:40..48 — struct simple_tokenizer_cursor. }
  Psimple_tokenizer_cursor = ^Tsimple_tokenizer_cursor;
  Tsimple_tokenizer_cursor = record
    base            : Tsqlite3_tokenizer_cursor;
    pInput          : PChar;  { input we are tokenizing }
    nBytes          : cint;   { size of the input }
    iOffset         : cint;   { current position in pInput }
    iToken          : cint;   { index of next token to be returned }
    pToken          : PChar;  { storage for current token }
    nTokenAllocated : cint;   { space allocated to zToken buffer }
  end;

{ fts3_tokenizer1.c:51..53 — simpleDelim. }
function simpleDelim(t: Psimple_tokenizer; c: Byte): cint;
begin
  if (c < $80) and (t^.delim[c] <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_tokenizer1.c:54..56 — fts3_isalnum. }
function fts3_isalnum(x: cint): cint;
begin
  if ((x >= Ord('0')) and (x <= Ord('9')))
  or ((x >= Ord('A')) and (x <= Ord('Z')))
  or ((x >= Ord('a')) and (x <= Ord('z'))) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_tokenizer1.c:61..97 — simpleCreate. }
function simpleCreate(argc: cint; const argv: PPChar;
  ppTokenizer: PPsqlite3_tokenizer): cint; cdecl;
var
  t  : Psimple_tokenizer;
  i, n : cint;
  ch : Byte;
  pArg : PChar;
begin
  t := Psimple_tokenizer(sqlite3_malloc(i32(SizeOf(Tsimple_tokenizer))));
  if t = nil then Exit(SQLITE_NOMEM);
  libc_memset(t, 0, NativeUInt(SizeOf(Tsimple_tokenizer)));

  { TODO(shess) Delimiters need to remain the same from run to run, else
    we need to reindex. }
  if argc > 1 then begin
    pArg := PPChar(argv)[1];
    n := cint(libc_strlen(pArg));
    i := 0;
    while i < n do begin
      ch := Byte(pArg[i]);
      { We explicitly don't support UTF-8 delimiters for now. }
      if ch >= $80 then begin
        sqlite3_free(t);
        Exit(SQLITE_ERROR);
      end;
      t^.delim[ch] := 1;
      Inc(i);
    end;
  end else begin
    { Mark non-alphanumeric ASCII characters as delimiters }
    i := 1;
    while i < $80 do begin
      if fts3_isalnum(i) = 0 then
        t^.delim[i] := cchar(-1)
      else
        t^.delim[i] := 0;
      Inc(i);
    end;
  end;

  ppTokenizer^ := @t^.base;
  Result := SQLITE_OK;
end;

{ fts3_tokenizer1.c:102..105 — simpleDestroy. }
function simpleDestroy(pTokenizer: Psqlite3_tokenizer): cint; cdecl;
begin
  sqlite3_free(pTokenizer);
  Result := SQLITE_OK;
end;

{ fts3_tokenizer1.c:113..140 — simpleOpen. }
function simpleOpen(pTokenizer: Psqlite3_tokenizer; const pInput: PChar;
  nBytes: cint; ppCursor: PPsqlite3_tokenizer_cursor): cint; cdecl;
var
  c: Psimple_tokenizer_cursor;
begin
  { UNUSED_PARAMETER(pTokenizer) }
  c := Psimple_tokenizer_cursor(sqlite3_malloc(i32(SizeOf(Tsimple_tokenizer_cursor))));
  if c = nil then Exit(SQLITE_NOMEM);

  c^.pInput := pInput;
  if pInput = nil then
    c^.nBytes := 0
  else if nBytes < 0 then
    c^.nBytes := cint(libc_strlen(pInput))
  else
    c^.nBytes := nBytes;
  c^.iOffset := 0;                 { start tokenizing at the beginning }
  c^.iToken := 0;
  c^.pToken := nil;                { no space allocated, yet. }
  c^.nTokenAllocated := 0;

  ppCursor^ := @c^.base;
  Result := SQLITE_OK;
end;

{ fts3_tokenizer1.c:146..151 — simpleClose. }
function simpleClose(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;
var
  c: Psimple_tokenizer_cursor;
begin
  c := Psimple_tokenizer_cursor(pCursor);
  sqlite3_free(c^.pToken);
  sqlite3_free(c);
  Result := SQLITE_OK;
end;

{ fts3_tokenizer1.c:157..209 — simpleNext. }
function simpleNext(pCursor: Psqlite3_tokenizer_cursor;
  ppToken: PPChar; pnBytes: Pcint;
  piStartOffset: Pcint; piEndOffset: Pcint; piPosition: Pcint): cint; cdecl;
var
  c: Psimple_tokenizer_cursor;
  t: Psimple_tokenizer;
  p: PByte;
  iStartOffset, i, n: cint;
  pNew: PChar;
  ch: Byte;
begin
  c := Psimple_tokenizer_cursor(pCursor);
  t := Psimple_tokenizer(pCursor^.pTokenizer);
  p := PByte(c^.pInput);

  while c^.iOffset < c^.nBytes do begin
    { Scan past delimiter characters }
    while (c^.iOffset < c^.nBytes) and (simpleDelim(t, p[c^.iOffset]) <> 0) do
      Inc(c^.iOffset);

    { Count non-delimiter characters. }
    iStartOffset := c^.iOffset;
    while (c^.iOffset < c^.nBytes) and (simpleDelim(t, p[c^.iOffset]) = 0) do
      Inc(c^.iOffset);

    if c^.iOffset > iStartOffset then begin
      n := c^.iOffset - iStartOffset;
      if n > c^.nTokenAllocated then begin
        c^.nTokenAllocated := n + 20;
        pNew := PChar(sqlite3_realloc64(c^.pToken, u64(c^.nTokenAllocated)));
        if pNew = nil then Exit(SQLITE_NOMEM);
        c^.pToken := pNew;
      end;
      for i := 0 to n - 1 do begin
        { TODO(shess) UTF-8 case-insensitivity. }
        ch := p[iStartOffset + i];
        if (ch >= Ord('A')) and (ch <= Ord('Z')) then
          c^.pToken[i] := Chr(ch - Ord('A') + Ord('a'))
        else
          c^.pToken[i] := Chr(ch);
      end;
      ppToken^ := c^.pToken;
      pnBytes^ := n;
      piStartOffset^ := iStartOffset;
      piEndOffset^ := c^.iOffset;
      piPosition^ := c^.iToken;
      Inc(c^.iToken);
      Exit(SQLITE_OK);
    end;
  end;
  Result := SQLITE_DONE;
end;

{ fts3_tokenizer1.c:214..222 — the static simpleTokenizerModule record. }
const
  simpleTokenizerModule: Tsqlite3_tokenizer_module = (
    iVersion    : 0;
    xCreate     : @simpleCreate;
    xDestroy    : @simpleDestroy;
    xOpen       : @simpleOpen;
    xClose      : @simpleClose;
    xNext       : @simpleNext;
    xLanguageid : nil;
  );

{ fts3_tokenizer1.c:228..232 — sqlite3Fts3SimpleTokenizerModule. }
procedure sqlite3Fts3SimpleTokenizerModule(ppModule: PPsqlite3_tokenizer_module);
begin
  ppModule^ := @simpleTokenizerModule;
end;

{ ===================================================================== }
{ 6.40.1.d — fts3_porter.c — the "porter" stemmer tokenizer.            }
{ ===================================================================== }

type
  { fts3_porter.c:38..40 — struct porter_tokenizer. }
  Pporter_tokenizer = ^Tporter_tokenizer;
  Tporter_tokenizer = record
    base : Tsqlite3_tokenizer;   { Base class }
  end;

  { fts3_porter.c:45..53 — struct porter_tokenizer_cursor. }
  Pporter_tokenizer_cursor = ^Tporter_tokenizer_cursor;
  Tporter_tokenizer_cursor = record
    base       : Tsqlite3_tokenizer_cursor;
    zInput     : PChar;   { input we are tokenizing }
    nInput     : cint;    { size of the input }
    iOffset    : cint;    { current position in zInput }
    iToken     : cint;    { index of next token to be returned }
    zToken     : PChar;   { storage for current token }
    nAllocated : cint;    { space allocated to zToken buffer }
  end;

{ fts3_porter.c:59..73 — porterCreate. }
function porterCreate(argc: cint; const argv: PPChar;
  ppTokenizer: PPsqlite3_tokenizer): cint; cdecl;
var
  t: Pporter_tokenizer;
begin
  { UNUSED_PARAMETER(argc); UNUSED_PARAMETER(argv) }
  t := Pporter_tokenizer(sqlite3_malloc(i32(SizeOf(Tporter_tokenizer))));
  if t = nil then Exit(SQLITE_NOMEM);
  libc_memset(t, 0, NativeUInt(SizeOf(Tporter_tokenizer)));
  ppTokenizer^ := @t^.base;
  Result := SQLITE_OK;
end;

{ fts3_porter.c:78..81 — porterDestroy. }
function porterDestroy(pTokenizer: Psqlite3_tokenizer): cint; cdecl;
begin
  sqlite3_free(pTokenizer);
  Result := SQLITE_OK;
end;

{ fts3_porter.c:89..116 — porterOpen. }
function porterOpen(pTokenizer: Psqlite3_tokenizer; const zInput: PChar;
  nInput: cint; ppCursor: PPsqlite3_tokenizer_cursor): cint; cdecl;
var
  c: Pporter_tokenizer_cursor;
begin
  { UNUSED_PARAMETER(pTokenizer) }
  c := Pporter_tokenizer_cursor(sqlite3_malloc(i32(SizeOf(Tporter_tokenizer_cursor))));
  if c = nil then Exit(SQLITE_NOMEM);

  c^.zInput := zInput;
  if zInput = nil then
    c^.nInput := 0
  else if nInput < 0 then
    c^.nInput := cint(libc_strlen(zInput))
  else
    c^.nInput := nInput;
  c^.iOffset := 0;                 { start tokenizing at the beginning }
  c^.iToken := 0;
  c^.zToken := nil;                { no space allocated, yet. }
  c^.nAllocated := 0;

  ppCursor^ := @c^.base;
  Result := SQLITE_OK;
end;

{ fts3_porter.c:122..127 — porterClose. }
function porterClose(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;
var
  c: Pporter_tokenizer_cursor;
begin
  c := Pporter_tokenizer_cursor(pCursor);
  sqlite3_free(c^.zToken);
  sqlite3_free(c);
  Result := SQLITE_OK;
end;

{ fts3_porter.c:131..134 — Vowel or consonant table.
  Indexed by letter-'a' (0..25); value 0=vowel,1=consonant,2='y'. }
const
  cType: array[0..25] of cint = (
     0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0,
     1, 1, 1, 2, 1
  );

{ Forward declaration (fts3_porter.c:149: static int isVowel(const char*)). }
function isVowel(const z: PChar): cint; forward;

{ fts3_porter.c:150..158 — isConsonant.  z[] is in reverse order. }
function isConsonant(const z: PChar): cint;
var
  j: cint;
  x: Char;
begin
  x := z^;
  if x = #0 then Exit(0);
  Assert((x >= 'a') and (x <= 'z'));
  j := cType[Ord(x) - Ord('a')];
  if j < 2 then Exit(j);
  if (z[1] = #0) or (isVowel(z + 1) <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_porter.c:159..167 — isVowel. }
function isVowel(const z: PChar): cint;
var
  j: cint;
  x: Char;
begin
  x := z^;
  if x = #0 then Exit(0);
  Assert((x >= 'a') and (x <= 'z'));
  j := cType[Ord(x) - Ord('a')];
  if j < 2 then Exit(1 - j);
  Result := isConsonant(z + 1);
end;

{ fts3_porter.c:188..193 — m_gt_0: true if m-value is 1 or more. }
function m_gt_0(const z: PChar): cint;
var
  p: PChar;
begin
  p := z;
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ <> #0 then Result := 1 else Result := 0;
end;

{ fts3_porter.c:198..207 — m_eq_1: true if m-value is exactly 1. }
function m_eq_1(const z: PChar): cint;
var
  p: PChar;
begin
  p := z;
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(1);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ = #0 then Result := 1 else Result := 0;
end;

{ fts3_porter.c:212..221 — m_gt_1: true if m-value is greater than 1. }
function m_gt_1(const z: PChar): cint;
var
  p: PChar;
begin
  p := z;
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ <> #0 then Result := 1 else Result := 0;
end;

{ fts3_porter.c:226..229 — hasVowel. }
function hasVowel(const z: PChar): cint;
var
  p: PChar;
begin
  p := z;
  while isConsonant(p) <> 0 do Inc(p);
  if p^ <> #0 then Result := 1 else Result := 0;
end;

{ fts3_porter.c:237..239 — doubleConsonant.  Text is reversed. }
function doubleConsonant(const z: PChar): cint;
begin
  if (isConsonant(z) <> 0) and (z[0] = z[1]) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_porter.c:249..255 — star_oh.  Word is reversed. }
function star_oh(const z: PChar): cint;
begin
  if (isConsonant(z) <> 0)
  and (z[0] <> 'w') and (z[0] <> 'x') and (z[0] <> 'y')
  and (isVowel(z + 1) <> 0)
  and (isConsonant(z + 2) <> 0) then
    Result := 1
  else
    Result := 0;
end;

type
  { fts3_porter.c:273 — int (*xCond)(const char*). }
  TPorterCond = function(const z: PChar): cint;

{ fts3_porter.c:269..284 — stem.  *pz and zFrom are reversed; zTo is normal.
  Returns TRUE if zFrom matches (even when xCond fails and no substitution
  occurs). }
function stem(pz: PPChar; const zFrom: PChar; const zTo: PChar;
  xCond: TPorterCond): cint;
var
  z, pF, pT: PChar;
begin
  z := pz^;
  pF := zFrom;
  while (pF^ <> #0) and (pF^ = z^) do begin
    Inc(z);
    Inc(pF);
  end;
  if pF^ <> #0 then Exit(0);
  if (xCond <> nil) and (xCond(z) = 0) then Exit(1);
  pT := zTo;
  while pT^ <> #0 do begin
    Dec(z);
    z^ := pT^;
    Inc(pT);
  end;
  pz^ := z;
  Result := 1;
end;

{ fts3_porter.c:294..315 — copy_stemmer.  Fallback US-ASCII case-fold copy
  with long-word truncation. }
procedure copy_stemmer(const zIn: PChar; nIn: cint; zOut: PChar; pnOut: Pcint);
var
  i, mx, j: cint;
  hasDigit: cint;
  c: Char;
begin
  hasDigit := 0;
  for i := 0 to nIn - 1 do begin
    c := zIn[i];
    if (c >= 'A') and (c <= 'Z') then
      zOut[i] := Chr(Ord(c) - Ord('A') + Ord('a'))
    else begin
      if (c >= '0') and (c <= '9') then hasDigit := 1;
      zOut[i] := c;
    end;
  end;
  if hasDigit <> 0 then mx := 3 else mx := 10;
  i := nIn;
  if nIn > mx * 2 then begin
    j := mx;
    i := nIn - mx;
    while i < nIn do begin
      zOut[j] := zOut[i];
      Inc(i);
      Inc(j);
    end;
    i := j;
  end;
  zOut[i] := #0;
  pnOut^ := i;
end;

{ fts3_porter.c:341..572 — porter_stemmer. }
procedure porter_stemmer(const zIn: PChar; nIn: cint; zOut: PChar; pnOut: Pcint);
var
  i, j: cint;
  zReverse: array[0..27] of Char;
  z, z2: PChar;
  c: Char;
begin
  if (nIn < 3) or (nIn >= cint(SizeOf(zReverse)) - 7) then begin
    { Too big or too small for the porter stemmer; fall back to copy. }
    copy_stemmer(zIn, nIn, zOut, pnOut);
    Exit;
  end;
  i := 0;
  j := cint(SizeOf(zReverse)) - 6;
  while i < nIn do begin
    c := zIn[i];
    if (c >= 'A') and (c <= 'Z') then
      zReverse[j] := Chr(Ord(c) + Ord('a') - Ord('A'))
    else if (c >= 'a') and (c <= 'z') then
      zReverse[j] := c
    else begin
      { A character not in [a-zA-Z] → fall back to the copy stemmer. }
      copy_stemmer(zIn, nIn, zOut, pnOut);
      Exit;
    end;
    Inc(i);
    Dec(j);
  end;
  libc_memset(@zReverse[SizeOf(zReverse) - 5], 0, 5);
  z := @zReverse[j + 1];

  { Step 1a }
  if z[0] = 's' then begin
    if (stem(@z, 'sess', 'ss', nil) = 0)
    and (stem(@z, 'sei', 'i', nil) = 0)
    and (stem(@z, 'ss', 'ss', nil) = 0) then
      Inc(z);
  end;

  { Step 1b }
  z2 := z;
  if stem(@z, 'dee', 'ee', @m_gt_0) <> 0 then begin
    { Do nothing.  The work was all in the test }
  end else if ((stem(@z, 'gni', '', @hasVowel) <> 0)
            or (stem(@z, 'de', '', @hasVowel) <> 0))
           and (z <> z2) then begin
    if (stem(@z, 'ta', 'ate', nil) <> 0)
    or (stem(@z, 'lb', 'ble', nil) <> 0)
    or (stem(@z, 'zi', 'ize', nil) <> 0) then begin
      { Do nothing.  The work was all in the test }
    end else if (doubleConsonant(z) <> 0)
            and ((z^ <> 'l') and (z^ <> 's') and (z^ <> 'z')) then
      Inc(z)
    else if (m_eq_1(z) <> 0) and (star_oh(z) <> 0) then begin
      Dec(z);
      z^ := 'e';
    end;
  end;

  { Step 1c }
  if (z[0] = 'y') and (hasVowel(z + 1) <> 0) then
    z[0] := 'i';

  { Step 2 }
  case z[1] of
   'a':
     if stem(@z, 'lanoita', 'ate', @m_gt_0) = 0 then
       stem(@z, 'lanoit', 'tion', @m_gt_0);
   'c':
     if stem(@z, 'icne', 'ence', @m_gt_0) = 0 then
       stem(@z, 'icna', 'ance', @m_gt_0);
   'e':
     stem(@z, 'rezi', 'ize', @m_gt_0);
   'g':
     stem(@z, 'igol', 'log', @m_gt_0);
   'l':
     if (stem(@z, 'ilb', 'ble', @m_gt_0) = 0)
     and (stem(@z, 'illa', 'al', @m_gt_0) = 0)
     and (stem(@z, 'iltne', 'ent', @m_gt_0) = 0)
     and (stem(@z, 'ile', 'e', @m_gt_0) = 0) then
       stem(@z, 'ilsuo', 'ous', @m_gt_0);
   'o':
     if (stem(@z, 'noitazi', 'ize', @m_gt_0) = 0)
     and (stem(@z, 'noita', 'ate', @m_gt_0) = 0) then
       stem(@z, 'rota', 'ate', @m_gt_0);
   's':
     if (stem(@z, 'msila', 'al', @m_gt_0) = 0)
     and (stem(@z, 'ssenevi', 'ive', @m_gt_0) = 0)
     and (stem(@z, 'ssenluf', 'ful', @m_gt_0) = 0) then
       stem(@z, 'ssensuo', 'ous', @m_gt_0);
   't':
     if (stem(@z, 'itila', 'al', @m_gt_0) = 0)
     and (stem(@z, 'itivi', 'ive', @m_gt_0) = 0) then
       stem(@z, 'itilib', 'ble', @m_gt_0);
  end;

  { Step 3 }
  case z[0] of
   'e':
     if (stem(@z, 'etaci', 'ic', @m_gt_0) = 0)
     and (stem(@z, 'evita', '', @m_gt_0) = 0) then
       stem(@z, 'ezila', 'al', @m_gt_0);
   'i':
     stem(@z, 'itici', 'ic', @m_gt_0);
   'l':
     if stem(@z, 'laci', 'ic', @m_gt_0) = 0 then
       stem(@z, 'luf', '', @m_gt_0);
   's':
     stem(@z, 'ssen', '', @m_gt_0);
  end;

  { Step 4 }
  case z[1] of
   'a':
     if (z[0] = 'l') and (m_gt_1(z + 2) <> 0) then
       Inc(z, 2);
   'c':
     if (z[0] = 'e') and (z[2] = 'n')
     and ((z[3] = 'a') or (z[3] = 'e')) and (m_gt_1(z + 4) <> 0) then
       Inc(z, 4);
   'e':
     if (z[0] = 'r') and (m_gt_1(z + 2) <> 0) then
       Inc(z, 2);
   'i':
     if (z[0] = 'c') and (m_gt_1(z + 2) <> 0) then
       Inc(z, 2);
   'l':
     if (z[0] = 'e') and (z[2] = 'b')
     and ((z[3] = 'a') or (z[3] = 'i')) and (m_gt_1(z + 4) <> 0) then
       Inc(z, 4);
   'n':
     if z[0] = 't' then begin
       if z[2] = 'a' then begin
         if m_gt_1(z + 3) <> 0 then
           Inc(z, 3);
       end else if z[2] = 'e' then begin
         if (stem(@z, 'tneme', '', @m_gt_1) = 0)
         and (stem(@z, 'tnem', '', @m_gt_1) = 0) then
           stem(@z, 'tne', '', @m_gt_1);
       end;
     end;
   'o':
     if z[0] = 'u' then begin
       if m_gt_1(z + 2) <> 0 then
         Inc(z, 2);
     end else if (z[3] = 's') or (z[3] = 't') then
       stem(@z, 'noi', '', @m_gt_1);
   's':
     if (z[0] = 'm') and (z[2] = 'i') and (m_gt_1(z + 3) <> 0) then
       Inc(z, 3);
   't':
     if stem(@z, 'eta', '', @m_gt_1) = 0 then
       stem(@z, 'iti', '', @m_gt_1);
   'u':
     if (z[0] = 's') and (z[2] = 'o') and (m_gt_1(z + 3) <> 0) then
       Inc(z, 3);
   'v', 'z':
     if (z[0] = 'e') and (z[2] = 'i') and (m_gt_1(z + 3) <> 0) then
       Inc(z, 3);
  end;

  { Step 5a }
  if z[0] = 'e' then begin
    if m_gt_1(z + 1) <> 0 then
      Inc(z)
    else if (m_eq_1(z + 1) <> 0) and (star_oh(z + 1) = 0) then
      Inc(z);
  end;

  { Step 5b }
  if (m_gt_1(z) <> 0) and (z[0] = 'l') and (z[1] = 'l') then
    Inc(z);

  { z[] is now the stemmed word in reverse order.  Flip it back. }
  i := cint(libc_strlen(z));
  pnOut^ := i;
  zOut[i] := #0;
  while z^ <> #0 do begin
    Dec(i);
    zOut[i] := z^;
    Inc(z);
  end;
end;

{ fts3_porter.c:580..587 — porterIdChar table (indexed by ch-0x30). }
const
  porterIdChar: array[0..79] of cchar = (
{ x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 xA xB xC xD xE xF }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0,  { 3x }
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  { 4x }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1,  { 5x }
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  { 6x }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0   { 7x }
  );

{ fts3_porter.c:588 — #define isDelim(C).  Ported as a helper taking the
  raw byte; C: ((ch=C)&0x80)==0 && (ch<0x30 || !porterIdChar[ch-0x30]). }
function porterIsDelim(ch: Byte): Boolean; inline;
begin
  Result := ((ch and $80) = 0)
        and ((ch < $30) or (porterIdChar[ch - $30] = 0));
end;

{ fts3_porter.c:594..637 — porterNext. }
function porterNext(pCursor: Psqlite3_tokenizer_cursor;
  pzToken: PPChar; pnBytes: Pcint;
  piStartOffset: Pcint; piEndOffset: Pcint; piPosition: Pcint): cint; cdecl;
var
  c: Pporter_tokenizer_cursor;
  z: PChar;
  iStartOffset, n: cint;
  pNew: PChar;
begin
  c := Pporter_tokenizer_cursor(pCursor);
  z := c^.zInput;

  while c^.iOffset < c^.nInput do begin
    { Scan past delimiter characters }
    while (c^.iOffset < c^.nInput) and porterIsDelim(Byte(z[c^.iOffset])) do
      Inc(c^.iOffset);

    { Count non-delimiter characters. }
    iStartOffset := c^.iOffset;
    while (c^.iOffset < c^.nInput) and (not porterIsDelim(Byte(z[c^.iOffset]))) do
      Inc(c^.iOffset);

    if c^.iOffset > iStartOffset then begin
      n := c^.iOffset - iStartOffset;
      if n > c^.nAllocated then begin
        c^.nAllocated := n + 20;
        pNew := PChar(sqlite3_realloc64(c^.zToken, u64(c^.nAllocated)));
        if pNew = nil then Exit(SQLITE_NOMEM);
        c^.zToken := pNew;
      end;
      porter_stemmer(@z[iStartOffset], n, c^.zToken, pnBytes);
      pzToken^ := c^.zToken;
      piStartOffset^ := iStartOffset;
      piEndOffset^ := c^.iOffset;
      piPosition^ := c^.iToken;
      Inc(c^.iToken);
      Exit(SQLITE_OK);
    end;
  end;
  Result := SQLITE_DONE;
end;

{ fts3_porter.c:642..650 — the static porterTokenizerModule record. }
const
  porterTokenizerModule: Tsqlite3_tokenizer_module = (
    iVersion    : 0;
    xCreate     : @porterCreate;
    xDestroy    : @porterDestroy;
    xOpen       : @porterOpen;
    xClose      : @porterClose;
    xNext       : @porterNext;
    xLanguageid : nil;
  );

{ fts3_porter.c:656..660 — sqlite3Fts3PorterTokenizerModule. }
procedure sqlite3Fts3PorterTokenizerModule(ppModule: PPsqlite3_tokenizer_module);
begin
  ppModule^ := @porterTokenizerModule;
end;

{ ===================================================================== }
{ 6.40.1.e — fts3_unicode2.c — auto-generated Unicode category data.     }
{ DO NOT EDIT the tables: ported verbatim from the machine-generated C.  }
{ ===================================================================== }

{ fts3_unicode2.c:30..151 — sqlite3FtsUnicodeIsalnum.
  Return true if the argument corresponds to a unicode codepoint
  classified as either a letter or a number; otherwise false. }
function sqlite3FtsUnicodeIsalnum(c: cint): cint;
const
  { fts3_unicode2.c:42..125 — aEntry[].  Each value ((C<<22)+N) represents a
    range of N codepoints (that are NOT letters/numbers) starting at C. }
  aEntry: array[0..405] of cuint = (
    $00000030, $0000E807, $00016C06, $0001EC2F, $0002AC07,
    $0002D001, $0002D803, $0002EC01, $0002FC01, $00035C01,
    $0003DC01, $000B0804, $000B480E, $000B9407, $000BB401,
    $000BBC81, $000DD401, $000DF801, $000E1002, $000E1C01,
    $000FD801, $00120808, $00156806, $00162402, $00163C01,
    $00164437, $0017CC02, $00180005, $00181816, $00187802,
    $00192C15, $0019A804, $0019C001, $001B5001, $001B580F,
    $001B9C07, $001BF402, $001C000E, $001C3C01, $001C4401,
    $001CC01B, $001E980B, $001FAC09, $001FD804, $00205804,
    $00206C09, $00209403, $0020A405, $0020C00F, $00216403,
    $00217801, $0023901B, $00240004, $0024E803, $0024F812,
    $00254407, $00258804, $0025C001, $00260403, $0026F001,
    $0026F807, $00271C02, $00272C03, $00275C01, $00278802,
    $0027C802, $0027E802, $00280403, $0028F001, $0028F805,
    $00291C02, $00292C03, $00294401, $0029C002, $0029D401,
    $002A0403, $002AF001, $002AF808, $002B1C03, $002B2C03,
    $002B8802, $002BC002, $002C0403, $002CF001, $002CF807,
    $002D1C02, $002D2C03, $002D5802, $002D8802, $002DC001,
    $002E0801, $002EF805, $002F1803, $002F2804, $002F5C01,
    $002FCC08, $00300403, $0030F807, $00311803, $00312804,
    $00315402, $00318802, $0031FC01, $00320802, $0032F001,
    $0032F807, $00331803, $00332804, $00335402, $00338802,
    $00340802, $0034F807, $00351803, $00352804, $00355C01,
    $00358802, $0035E401, $00360802, $00372801, $00373C06,
    $00375801, $00376008, $0037C803, $0038C401, $0038D007,
    $0038FC01, $00391C09, $00396802, $003AC401, $003AD006,
    $003AEC02, $003B2006, $003C041F, $003CD00C, $003DC417,
    $003E340B, $003E6424, $003EF80F, $003F380D, $0040AC14,
    $00412806, $00415804, $00417803, $00418803, $00419C07,
    $0041C404, $0042080C, $00423C01, $00426806, $0043EC01,
    $004D740C, $004E400A, $00500001, $0059B402, $005A0001,
    $005A6C02, $005BAC03, $005C4803, $005CC805, $005D4802,
    $005DC802, $005ED023, $005F6004, $005F7401, $0060000F,
    $0062A401, $0064800C, $0064C00C, $00650001, $00651002,
    $0066C011, $00672002, $00677822, $00685C05, $00687802,
    $0069540A, $0069801D, $0069FC01, $006A8007, $006AA006,
    $006C0005, $006CD011, $006D6823, $006E0003, $006E840D,
    $006F980E, $006FF004, $00709014, $0070EC05, $0071F802,
    $00730008, $00734019, $0073B401, $0073C803, $00770027,
    $0077F004, $007EF401, $007EFC03, $007F3403, $007F7403,
    $007FB403, $007FF402, $00800065, $0081A806, $0081E805,
    $00822805, $0082801A, $00834021, $00840002, $00840C04,
    $00842002, $00845001, $00845803, $00847806, $00849401,
    $00849C01, $0084A401, $0084B801, $0084E802, $00850005,
    $00852804, $00853C01, $00864264, $00900027, $0091000B,
    $0092704E, $00940200, $009C0475, $009E53B9, $00AD400A,
    $00B39406, $00B3BC03, $00B3E404, $00B3F802, $00B5C001,
    $00B5FC01, $00B7804F, $00B8C00C, $00BA001A, $00BA6C59,
    $00BC00D6, $00BFC00C, $00C00005, $00C02019, $00C0A807,
    $00C0D802, $00C0F403, $00C26404, $00C28001, $00C3EC01,
    $00C64002, $00C6580A, $00C70024, $00C8001F, $00C8A81E,
    $00C94001, $00C98020, $00CA2827, $00CB003F, $00CC0100,
    $01370040, $02924037, $0293F802, $02983403, $0299BC10,
    $029A7C01, $029BC008, $029C0017, $029C8002, $029E2402,
    $02A00801, $02A01801, $02A02C01, $02A08C09, $02A0D804,
    $02A1D004, $02A20002, $02A2D011, $02A33802, $02A38012,
    $02A3E003, $02A4980A, $02A51C0D, $02A57C01, $02A60004,
    $02A6CC1B, $02A77802, $02A8A40E, $02A90C01, $02A93002,
    $02A97004, $02A9DC03, $02A9EC01, $02AAC001, $02AAC803,
    $02AADC02, $02AAF802, $02AB0401, $02AB7802, $02ABAC07,
    $02ABD402, $02AF8C0B, $03600001, $036DFC02, $036FFC02,
    $037FFC01, $03EC7801, $03ECA401, $03EEC810, $03F4F802,
    $03F7F002, $03F8001A, $03F88007, $03F8C023, $03F95013,
    $03F9A004, $03FBFC01, $03FC040F, $03FC6807, $03FCEC06,
    $03FD6C0B, $03FF8007, $03FFA007, $03FFE405, $04040003,
    $0404DC09, $0405E411, $0406400C, $0407402E, $040E7C01,
    $040F4001, $04215C01, $04247C01, $0424FC01, $04280403,
    $04281402, $04283004, $0428E003, $0428FC01, $04294009,
    $0429FC01, $042CE407, $04400003, $0440E016, $04420003,
    $0442C012, $04440003, $04449C0E, $04450004, $04460003,
    $0446CC0E, $04471404, $045AAC0D, $0491C004, $05BD442E,
    $05BE3C04, $074000F6, $07440027, $0744A4B5, $07480046,
    $074C0057, $075B0401, $075B6C01, $075BEC01, $075C5401,
    $075CD401, $075D3C01, $075DBC01, $075E2401, $075EA401,
    $075F0C01, $07BBC002, $07C0002C, $07C0C064, $07C2800F,
    $07C2C40E, $07C3040F, $07C3440F, $07C4401F, $07C4C03C,
    $07C5C02B, $07C7981D, $07C8402B, $07C90009, $07C94002,
    $07CC0021, $07CCC006, $07CCDC46, $07CE0014, $07CE8025,
    $07CF1805, $07CF8011, $07D0003F, $07D10001, $07D108B6,
    $07D3E404, $07D4003E, $07D50004, $07D54018, $07D7EC46,
    $07D9140B, $07DA0046, $07DC0074, $38000401, $38008060,
    $380400F0
  );
  { fts3_unicode2.c:126..128 — aAscii[4]. }
  aAscii: array[0..3] of cuint = (
    $FFFFFFFF, $FC00FFFF, $F8000001, $F8000001
  );
var
  key: cuint;
  iRes, iHi, iLo, iTest: cint;
begin
  if cuint(c) < 128 then begin
    if (aAscii[c shr 5] and (cuint(1) shl (c and $001F))) = 0 then
      Result := 1
    else
      Result := 0;
    Exit;
  end else if cuint(c) < (1 shl 22) then begin
    key := (cuint(c) shl 10) or $000003FF;
    iRes := 0;
    iHi := (SizeOf(aEntry) div SizeOf(aEntry[0])) - 1;
    iLo := 0;
    while iHi >= iLo do begin
      iTest := (iHi + iLo) div 2;
      if key >= aEntry[iTest] then begin
        iRes := iTest;
        iLo := iTest + 1;
      end else
        iHi := iTest - 1;
    end;
    Assert(aEntry[0] < key);
    Assert(key >= aEntry[iRes]);
    if cuint(c) >= ((aEntry[iRes] shr 10) + (aEntry[iRes] and $3FF)) then
      Result := 1
    else
      Result := 0;
    Exit;
  end;
  Result := 1;
end;

{ fts3_unicode2.c:162..222 — remove_diacritic. }
function remove_diacritic(c: cint; bComplex: cint): cint;
const
  { fts3_unicode2.c:163..180 — aDia[].  Unsigned 16-bit. }
  aDia: array[0..125] of cushort = (
        0,  1797,  1848,  1859,  1891,  1928,  1940,  1995,
     2024,  2040,  2060,  2110,  2168,  2206,  2264,  2286,
     2344,  2383,  2472,  2488,  2516,  2596,  2668,  2732,
     2782,  2842,  2894,  2954,  2984,  3000,  3028,  3336,
     3456,  3696,  3712,  3728,  3744,  3766,  3832,  3896,
     3912,  3928,  3944,  3968,  4008,  4040,  4056,  4106,
     4138,  4170,  4202,  4234,  4266,  4296,  4312,  4344,
     4408,  4424,  4442,  4472,  4488,  4504,  6148,  6198,
     6264,  6280,  6360,  6429,  6505,  6529, 61448, 61468,
    61512, 61534, 61592, 61610, 61642, 61672, 61688, 61704,
    61726, 61784, 61800, 61816, 61836, 61880, 61896, 61914,
    61948, 61998, 62062, 62122, 62154, 62184, 62200, 62218,
    62252, 62302, 62364, 62410, 62442, 62478, 62536, 62554,
    62584, 62604, 62640, 62648, 62656, 62664, 62730, 62766,
    62830, 62890, 62924, 62974, 63032, 63050, 63082, 63118,
    63182, 63242, 63274, 63310, 63368, 63390
  );
  { fts3_unicode2.c:181 — #define HIBIT ((unsigned char)0x80) }
  HIBIT = $80;
  { fts3_unicode2.c:182..204 — aChar[].  ASCII letter (low 7 bits) plus the
    HIBIT "complex" flag for codepoints only folded when bComplex!=0. }
  aChar: array[0..125] of cuchar = (
    Ord(#0),         Ord('a'),        Ord('c'),        Ord('e'),
    Ord('i'),        Ord('n'),
    Ord('o'),        Ord('u'),        Ord('y'),        Ord('y'),
    Ord('a'),        Ord('c'),
    Ord('d'),        Ord('e'),        Ord('e'),        Ord('g'),
    Ord('h'),        Ord('i'),
    Ord('j'),        Ord('k'),        Ord('l'),        Ord('n'),
    Ord('o'),        Ord('r'),
    Ord('s'),        Ord('t'),        Ord('u'),        Ord('u'),
    Ord('w'),        Ord('y'),
    Ord('z'),        Ord('o'),        Ord('u'),        Ord('a'),
    Ord('i'),        Ord('o'),
    Ord('u'),        Ord('u') or HIBIT, Ord('a') or HIBIT, Ord('g'),
    Ord('k'),        Ord('o'),
    Ord('o') or HIBIT, Ord('j'),      Ord('g'),        Ord('n'),
    Ord('a') or HIBIT, Ord('a'),
    Ord('e'),        Ord('i'),        Ord('o'),        Ord('r'),
    Ord('u'),        Ord('s'),
    Ord('t'),        Ord('h'),        Ord('a'),        Ord('e'),
    Ord('o') or HIBIT, Ord('o'),
    Ord('o') or HIBIT, Ord('y'),      Ord(#0),         Ord(#0),
    Ord(#0),         Ord(#0),
    Ord(#0),         Ord(#0),         Ord(#0),         Ord(#0),
    Ord('a'),        Ord('b'),
    Ord('c') or HIBIT, Ord('d'),      Ord('d'),        Ord('e') or HIBIT,
    Ord('e'),        Ord('e') or HIBIT,
    Ord('f'),        Ord('g'),        Ord('h'),        Ord('h'),
    Ord('i'),        Ord('i') or HIBIT,
    Ord('k'),        Ord('l'),        Ord('l') or HIBIT, Ord('l'),
    Ord('m'),        Ord('n'),
    Ord('o') or HIBIT, Ord('p'),      Ord('r'),        Ord('r') or HIBIT,
    Ord('r'),        Ord('s'),
    Ord('s') or HIBIT, Ord('t'),      Ord('u'),        Ord('u') or HIBIT,
    Ord('v'),        Ord('w'),
    Ord('w'),        Ord('x'),        Ord('y'),        Ord('z'),
    Ord('h'),        Ord('t'),
    Ord('w'),        Ord('y'),        Ord('a'),        Ord('a') or HIBIT,
    Ord('a') or HIBIT, Ord('a') or HIBIT,
    Ord('e'),        Ord('e') or HIBIT, Ord('e') or HIBIT, Ord('i'),
    Ord('o'),        Ord('o') or HIBIT,
    Ord('o') or HIBIT, Ord('o') or HIBIT, Ord('u'),     Ord('u') or HIBIT,
    Ord('u') or HIBIT, Ord('y')
  );
var
  key: cuint;
  iRes, iHi, iLo, iTest: cint;
begin
  key := (cuint(c) shl 3) or $00000007;
  iRes := 0;
  iHi := (SizeOf(aDia) div SizeOf(aDia[0])) - 1;
  iLo := 0;
  while iHi >= iLo do begin
    iTest := (iHi + iLo) div 2;
    if key >= aDia[iTest] then begin
      iRes := iTest;
      iLo := iTest + 1;
    end else
      iHi := iTest - 1;
  end;
  Assert(key >= aDia[iRes]);
  if (bComplex = 0) and ((aChar[iRes] and $80) <> 0) then Exit(c);
  if cuint(c) > ((aDia[iRes] shr 3) + (aDia[iRes] and $07)) then
    Result := c
  else
    Result := cint(aChar[iRes]) and $7F;
end;

{ fts3_unicode2.c:229..236 — sqlite3FtsUnicodeIsdiacritic. }
function sqlite3FtsUnicodeIsdiacritic(c: cint): cint;
var
  mask0, mask1: cuint;
begin
  mask0 := $08029FDF;
  mask1 := $000361F8;
  if (c < 768) or (c > 817) then Exit(0);
  if c < 768 + 32 then
    Result := cint(mask0 and (cuint(1) shl (c - 768)))
  else
    Result := cint(mask1 and (cuint(1) shl (c - 768 - 32)));
end;

type
  { fts3_unicode2.c:266..270 — struct TableEntry. }
  TFtsUFoldEntry = record
    iCode  : cushort;
    flags  : cuchar;
    nRange : cuchar;
  end;

{ fts3_unicode2.c:248..381 — sqlite3FtsUnicodeFold. }
function sqlite3FtsUnicodeFold(c: cint; eRemoveDiacritic: cint): cint;
const
  { fts3_unicode2.c:271..326 — aEntry[] (TableEntry).  Verbatim. }
  aEntry: array[0..162] of TFtsUFoldEntry = (
    (iCode:65;    flags:14;  nRange:26),  (iCode:181;   flags:64;  nRange:1),  (iCode:192;   flags:14;  nRange:23),
    (iCode:216;   flags:14;  nRange:7),   (iCode:256;   flags:1;   nRange:48), (iCode:306;   flags:1;   nRange:6),
    (iCode:313;   flags:1;   nRange:16),  (iCode:330;   flags:1;   nRange:46), (iCode:376;   flags:116; nRange:1),
    (iCode:377;   flags:1;   nRange:6),   (iCode:383;   flags:104; nRange:1),  (iCode:385;   flags:50;  nRange:1),
    (iCode:386;   flags:1;   nRange:4),   (iCode:390;   flags:44;  nRange:1),  (iCode:391;   flags:0;   nRange:1),
    (iCode:393;   flags:42;  nRange:2),   (iCode:395;   flags:0;   nRange:1),  (iCode:398;   flags:32;  nRange:1),
    (iCode:399;   flags:38;  nRange:1),   (iCode:400;   flags:40;  nRange:1),  (iCode:401;   flags:0;   nRange:1),
    (iCode:403;   flags:42;  nRange:1),   (iCode:404;   flags:46;  nRange:1),  (iCode:406;   flags:52;  nRange:1),
    (iCode:407;   flags:48;  nRange:1),   (iCode:408;   flags:0;   nRange:1),  (iCode:412;   flags:52;  nRange:1),
    (iCode:413;   flags:54;  nRange:1),   (iCode:415;   flags:56;  nRange:1),  (iCode:416;   flags:1;   nRange:6),
    (iCode:422;   flags:60;  nRange:1),   (iCode:423;   flags:0;   nRange:1),  (iCode:425;   flags:60;  nRange:1),
    (iCode:428;   flags:0;   nRange:1),   (iCode:430;   flags:60;  nRange:1),  (iCode:431;   flags:0;   nRange:1),
    (iCode:433;   flags:58;  nRange:2),   (iCode:435;   flags:1;   nRange:4),  (iCode:439;   flags:62;  nRange:1),
    (iCode:440;   flags:0;   nRange:1),   (iCode:444;   flags:0;   nRange:1),  (iCode:452;   flags:2;   nRange:1),
    (iCode:453;   flags:0;   nRange:1),   (iCode:455;   flags:2;   nRange:1),  (iCode:456;   flags:0;   nRange:1),
    (iCode:458;   flags:2;   nRange:1),   (iCode:459;   flags:1;   nRange:18), (iCode:478;   flags:1;   nRange:18),
    (iCode:497;   flags:2;   nRange:1),   (iCode:498;   flags:1;   nRange:4),  (iCode:502;   flags:122; nRange:1),
    (iCode:503;   flags:134; nRange:1),   (iCode:504;   flags:1;   nRange:40), (iCode:544;   flags:110; nRange:1),
    (iCode:546;   flags:1;   nRange:18),  (iCode:570;   flags:70;  nRange:1),  (iCode:571;   flags:0;   nRange:1),
    (iCode:573;   flags:108; nRange:1),   (iCode:574;   flags:68;  nRange:1),  (iCode:577;   flags:0;   nRange:1),
    (iCode:579;   flags:106; nRange:1),   (iCode:580;   flags:28;  nRange:1),  (iCode:581;   flags:30;  nRange:1),
    (iCode:582;   flags:1;   nRange:10),  (iCode:837;   flags:36;  nRange:1),  (iCode:880;   flags:1;   nRange:4),
    (iCode:886;   flags:0;   nRange:1),   (iCode:902;   flags:18;  nRange:1),  (iCode:904;   flags:16;  nRange:3),
    (iCode:908;   flags:26;  nRange:1),   (iCode:910;   flags:24;  nRange:2),  (iCode:913;   flags:14;  nRange:17),
    (iCode:931;   flags:14;  nRange:9),   (iCode:962;   flags:0;   nRange:1),  (iCode:975;   flags:4;   nRange:1),
    (iCode:976;   flags:140; nRange:1),   (iCode:977;   flags:142; nRange:1),  (iCode:981;   flags:146; nRange:1),
    (iCode:982;   flags:144; nRange:1),   (iCode:984;   flags:1;   nRange:24), (iCode:1008;  flags:136; nRange:1),
    (iCode:1009;  flags:138; nRange:1),   (iCode:1012;  flags:130; nRange:1),  (iCode:1013;  flags:128; nRange:1),
    (iCode:1015;  flags:0;   nRange:1),   (iCode:1017;  flags:152; nRange:1),  (iCode:1018;  flags:0;   nRange:1),
    (iCode:1021;  flags:110; nRange:3),   (iCode:1024;  flags:34;  nRange:16), (iCode:1040;  flags:14;  nRange:32),
    (iCode:1120;  flags:1;   nRange:34),  (iCode:1162;  flags:1;   nRange:54), (iCode:1216;  flags:6;   nRange:1),
    (iCode:1217;  flags:1;   nRange:14),  (iCode:1232;  flags:1;   nRange:88), (iCode:1329;  flags:22;  nRange:38),
    (iCode:4256;  flags:66;  nRange:38),  (iCode:4295;  flags:66;  nRange:1),  (iCode:4301;  flags:66;  nRange:1),
    (iCode:7680;  flags:1;   nRange:150), (iCode:7835;  flags:132; nRange:1),  (iCode:7838;  flags:96;  nRange:1),
    (iCode:7840;  flags:1;   nRange:96),  (iCode:7944;  flags:150; nRange:8),  (iCode:7960;  flags:150; nRange:6),
    (iCode:7976;  flags:150; nRange:8),   (iCode:7992;  flags:150; nRange:8),  (iCode:8008;  flags:150; nRange:6),
    (iCode:8025;  flags:151; nRange:8),   (iCode:8040;  flags:150; nRange:8),  (iCode:8072;  flags:150; nRange:8),
    (iCode:8088;  flags:150; nRange:8),   (iCode:8104;  flags:150; nRange:8),  (iCode:8120;  flags:150; nRange:2),
    (iCode:8122;  flags:126; nRange:2),   (iCode:8124;  flags:148; nRange:1),  (iCode:8126;  flags:100; nRange:1),
    (iCode:8136;  flags:124; nRange:4),   (iCode:8140;  flags:148; nRange:1),  (iCode:8152;  flags:150; nRange:2),
    (iCode:8154;  flags:120; nRange:2),   (iCode:8168;  flags:150; nRange:2),  (iCode:8170;  flags:118; nRange:2),
    (iCode:8172;  flags:152; nRange:1),   (iCode:8184;  flags:112; nRange:2),  (iCode:8186;  flags:114; nRange:2),
    (iCode:8188;  flags:148; nRange:1),   (iCode:8486;  flags:98;  nRange:1),  (iCode:8490;  flags:92;  nRange:1),
    (iCode:8491;  flags:94;  nRange:1),   (iCode:8498;  flags:12;  nRange:1),  (iCode:8544;  flags:8;   nRange:16),
    (iCode:8579;  flags:0;   nRange:1),   (iCode:9398;  flags:10;  nRange:26), (iCode:11264; flags:22;  nRange:47),
    (iCode:11360; flags:0;   nRange:1),   (iCode:11362; flags:88;  nRange:1),  (iCode:11363; flags:102; nRange:1),
    (iCode:11364; flags:90;  nRange:1),   (iCode:11367; flags:1;   nRange:6),  (iCode:11373; flags:84;  nRange:1),
    (iCode:11374; flags:86;  nRange:1),   (iCode:11375; flags:80;  nRange:1),  (iCode:11376; flags:82;  nRange:1),
    (iCode:11378; flags:0;   nRange:1),   (iCode:11381; flags:0;   nRange:1),  (iCode:11390; flags:78;  nRange:2),
    (iCode:11392; flags:1;   nRange:100), (iCode:11499; flags:1;   nRange:4),  (iCode:11506; flags:0;   nRange:1),
    (iCode:42560; flags:1;   nRange:46),  (iCode:42624; flags:1;   nRange:24), (iCode:42786; flags:1;   nRange:14),
    (iCode:42802; flags:1;   nRange:62),  (iCode:42873; flags:1;   nRange:4),  (iCode:42877; flags:76;  nRange:1),
    (iCode:42878; flags:1;   nRange:10),  (iCode:42891; flags:0;   nRange:1),  (iCode:42893; flags:74;  nRange:1),
    (iCode:42896; flags:1;   nRange:4),   (iCode:42912; flags:1;   nRange:10), (iCode:42922; flags:72;  nRange:1),
    (iCode:65313; flags:14;  nRange:26)
  );
  { fts3_unicode2.c:327..338 — aiOff[].  Unsigned 16-bit. }
  aiOff: array[0..76] of cushort = (
    1,     2,     8,     15,    16,    26,    28,    32,
    37,    38,    40,    48,    63,    64,    69,    71,
    79,    80,    116,   202,   203,   205,   206,   207,
    209,   210,   211,   213,   214,   217,   218,   219,
    775,   7264,  10792, 10795, 23228, 23256, 30204, 54721,
    54753, 54754, 54756, 54787, 54793, 54809, 57153, 57274,
    57921, 58019, 58363, 61722, 65268, 65341, 65373, 65406,
    65408, 65410, 65415, 65424, 65436, 65439, 65450, 65462,
    65472, 65476, 65478, 65480, 65482, 65488, 65506, 65511,
    65514, 65521, 65527, 65528, 65529
  );
var
  ret: cint;
  p: ^TFtsUFoldEntry;
  iHi, iLo, iRes, iTest, cmp: cint;
begin
  ret := c;
  if c < 128 then begin
    if (c >= Ord('A')) and (c <= Ord('Z')) then
      ret := c + (Ord('a') - Ord('A'));
  end else if c < 65536 then begin
    iHi := (SizeOf(aEntry) div SizeOf(aEntry[0])) - 1;
    iLo := 0;
    iRes := -1;
    Assert(c > aEntry[0].iCode);
    while iHi >= iLo do begin
      iTest := (iHi + iLo) div 2;
      cmp := c - aEntry[iTest].iCode;
      if cmp >= 0 then begin
        iRes := iTest;
        iLo := iTest + 1;
      end else
        iHi := iTest - 1;
    end;
    Assert((iRes >= 0) and (c >= aEntry[iRes].iCode));
    p := @aEntry[iRes];
    if (c < (p^.iCode + p^.nRange))
    and ((($01 and p^.flags) and (cint(p^.iCode) xor c)) = 0) then begin
      ret := (c + cint(aiOff[p^.flags shr 1])) and $0000FFFF;
      Assert(ret > 0);
    end;
    if eRemoveDiacritic <> 0 then begin
      if eRemoveDiacritic = 2 then
        ret := remove_diacritic(ret, 1)
      else
        ret := remove_diacritic(ret, 0);
    end;
  end
  else if (c >= 66560) and (c < 66600) then
    ret := c + 40;
  Result := ret;
end;

{ ===================================================================== }
{ 6.40.1.f — fts3_unicode.c — the "unicode61" tokenizer.                 }
{ ===================================================================== }

type
  { fts3_unicode.c:83..88 — struct unicode_tokenizer. }
  Punicode_tokenizer = ^Tunicode_tokenizer;
  Tunicode_tokenizer = record
    base            : Tsqlite3_tokenizer;
    eRemoveDiacritic : cint;
    nException       : cint;
    aiException       : Pcint;
  end;

  { fts3_unicode.c:90..98 — struct unicode_cursor. }
  Punicode_cursor = ^Tunicode_cursor;
  Tunicode_cursor = record
    base   : Tsqlite3_tokenizer_cursor;
    aInput : PByte;        { Input text being tokenized }
    nInput : cint;         { Size of aInput[] in bytes }
    iOff   : cint;         { Current offset within aInput[] }
    iToken : cint;         { Index of next token to be returned }
    zToken : PChar;        { storage for current token }
    nAlloc : cint;         { space allocated at zToken }
  end;

const
  { fts3_unicode.c:35..44 — sqlite3Utf8Trans1[] (lead-byte offset table). }
  sqlite3Utf8Trans1: array[0..63] of cuchar = (
    $00, $01, $02, $03, $04, $05, $06, $07,
    $08, $09, $0a, $0b, $0c, $0d, $0e, $0f,
    $10, $11, $12, $13, $14, $15, $16, $17,
    $18, $19, $1a, $1b, $1c, $1d, $1e, $1f,
    $00, $01, $02, $03, $04, $05, $06, $07,
    $08, $09, $0a, $0b, $0c, $0d, $0e, $0f,
    $00, $01, $02, $03, $04, $05, $06, $07,
    $00, $01, $02, $03, $00, $01, $00, $00
  );

{ fts3_unicode.c:46..56 — READ_UTF8 macro, ported as a procedure.
  Reads one codepoint at z (PByte), advancing z, stopping before zTerm. }
procedure fts3ReadUtf8(var z: PByte; const zTerm: PByte; var c: cuint); inline;
begin
  c := z^;            { c = *(zIn++) }
  Inc(z);
  if c >= $c0 then begin
    c := sqlite3Utf8Trans1[c - $c0];
    while (z <> zTerm) and ((z^ and $c0) = $80) do begin
      c := (c shl 6) + (cuint($3f) and z^);   { c = (c<<6) + (0x3f & *(zIn++)) }
      Inc(z);
    end;
    if (c < $80)
    or ((c and $FFFFF800) = $D800)
    or ((c and $FFFFFFFE) = $FFFE) then
      c := $FFFD;
  end;
end;

{ fts3_unicode.c:58..76 — WRITE_UTF8 macro, ported as a procedure.
  Writes codepoint c at zOut (PByte), advancing zOut. }
procedure fts3WriteUtf8(var zOut: PByte; c: cuint); inline;
begin
  if c < $00080 then begin
    zOut^ := cuchar(c and $FF);            Inc(zOut);
  end else if c < $00800 then begin
    zOut^ := cuchar($C0 + ((c shr 6) and $1F));  Inc(zOut);
    zOut^ := cuchar($80 + (c and $3F));          Inc(zOut);
  end else if c < $10000 then begin
    zOut^ := cuchar($E0 + ((c shr 12) and $0F)); Inc(zOut);
    zOut^ := cuchar($80 + ((c shr 6) and $3F));  Inc(zOut);
    zOut^ := cuchar($80 + (c and $3F));          Inc(zOut);
  end else begin
    zOut^ := cuchar($F0 + ((c shr 18) and $07)); Inc(zOut);
    zOut^ := cuchar($80 + ((c shr 12) and $3F)); Inc(zOut);
    zOut^ := cuchar($80 + ((c shr 6) and $3F));  Inc(zOut);
    zOut^ := cuchar($80 + (c and $3F));          Inc(zOut);
  end;
end;

{ fts3_unicode.c:104..111 — unicodeDestroy. }
function unicodeDestroy(pTokenizer: Psqlite3_tokenizer): cint; cdecl;
var
  p: Punicode_tokenizer;
begin
  if pTokenizer <> nil then begin
    p := Punicode_tokenizer(pTokenizer);
    sqlite3_free(p^.aiException);
    sqlite3_free(p);
  end;
  Result := SQLITE_OK;
end;

{ fts3_unicode.c:131..180 — unicodeAddExceptions. }
function unicodeAddExceptions(p: Punicode_tokenizer; bAlnum: cint;
  const zIn: PChar; nIn: cint): cint;
var
  z, zTerm: PByte;
  iCode: cuint;
  nEntry: cint;
  aNew: Pcint;
  nNew, i, j: cint;
begin
  z := PByte(zIn);
  zTerm := @z[nIn];
  nEntry := 0;
  Assert((bAlnum = 0) or (bAlnum = 1));

  while PtrUInt(z) < PtrUInt(zTerm) do begin
    fts3ReadUtf8(z, zTerm, iCode);
    Assert((sqlite3FtsUnicodeIsalnum(cint(iCode)) and $FFFFFFFE) = 0);
    if (sqlite3FtsUnicodeIsalnum(cint(iCode)) <> bAlnum)
    and (sqlite3FtsUnicodeIsdiacritic(cint(iCode)) = 0) then
      Inc(nEntry);
  end;

  if nEntry <> 0 then begin
    aNew := Pcint(sqlite3_realloc64(p^.aiException,
      u64((p^.nException + nEntry) * cint(SizeOf(cint)))));
    if aNew = nil then Exit(SQLITE_NOMEM);
    nNew := p^.nException;

    z := PByte(zIn);
    while PtrUInt(z) < PtrUInt(zTerm) do begin
      fts3ReadUtf8(z, zTerm, iCode);
      if (sqlite3FtsUnicodeIsalnum(cint(iCode)) <> bAlnum)
      and (sqlite3FtsUnicodeIsdiacritic(cint(iCode)) = 0) then begin
        i := 0;
        while (i < nNew) and (aNew[i] < cint(iCode)) do Inc(i);
        j := nNew;
        while j > i do begin
          aNew[j] := aNew[j - 1];
          Dec(j);
        end;
        aNew[i] := cint(iCode);
        Inc(nNew);
      end;
    end;
    p^.aiException := aNew;
    p^.nException := nNew;
  end;

  Result := SQLITE_OK;
end;

{ fts3_unicode.c:185..204 — unicodeIsException. }
function unicodeIsException(p: Punicode_tokenizer; iCode: cint): cint;
var
  a: Pcint;
  iLo, iHi, iTest: cint;
begin
  if p^.nException > 0 then begin
    a := p^.aiException;
    iLo := 0;
    iHi := p^.nException - 1;
    while iHi >= iLo do begin
      iTest := (iHi + iLo) div 2;
      if iCode = a[iTest] then
        Exit(1)
      else if iCode > a[iTest] then
        iLo := iTest + 1
      else
        iHi := iTest - 1;
    end;
  end;
  Result := 0;
end;

{ fts3_unicode.c:210..213 — unicodeIsAlnum. }
function unicodeIsAlnum(p: Punicode_tokenizer; iCode: cint): cint;
begin
  Assert((sqlite3FtsUnicodeIsalnum(iCode) and $FFFFFFFE) = 0);
  Result := sqlite3FtsUnicodeIsalnum(iCode) xor unicodeIsException(p, iCode);
end;

{ fts3_unicode.c:218..263 — unicodeCreate. }
function unicodeCreate(nArg: cint; const azArg: PPChar;
  pp: PPsqlite3_tokenizer): cint; cdecl;
var
  pNew: Punicode_tokenizer;
  i, n, rc: cint;
  z: PChar;
begin
  rc := SQLITE_OK;
  pNew := Punicode_tokenizer(sqlite3_malloc(i32(SizeOf(Tunicode_tokenizer))));
  if pNew = nil then Exit(SQLITE_NOMEM);
  libc_memset(pNew, 0, NativeUInt(SizeOf(Tunicode_tokenizer)));
  pNew^.eRemoveDiacritic := 1;

  i := 0;
  while (rc = SQLITE_OK) and (i < nArg) do begin
    z := PPChar(azArg)[i];
    n := cint(libc_strlen(z));

    if (n = 19) and (libc_memcmp(PChar('remove_diacritics=1'), z, 19) = 0) then
      pNew^.eRemoveDiacritic := 1
    else if (n = 19) and (libc_memcmp(PChar('remove_diacritics=0'), z, 19) = 0) then
      pNew^.eRemoveDiacritic := 0
    else if (n = 19) and (libc_memcmp(PChar('remove_diacritics=2'), z, 19) = 0) then
      pNew^.eRemoveDiacritic := 2
    else if (n >= 11) and (libc_memcmp(PChar('tokenchars='), z, 11) = 0) then
      rc := unicodeAddExceptions(pNew, 1, @z[11], n - 11)
    else if (n >= 11) and (libc_memcmp(PChar('separators='), z, 11) = 0) then
      rc := unicodeAddExceptions(pNew, 0, @z[11], n - 11)
    else
      rc := SQLITE_ERROR;   { Unrecognized argument }
    Inc(i);
  end;

  if rc <> SQLITE_OK then begin
    unicodeDestroy(Psqlite3_tokenizer(pNew));
    pNew := nil;
  end;
  pp^ := Psqlite3_tokenizer(pNew);
  Result := rc;
end;

{ fts3_unicode.c:271..298 — unicodeOpen. }
const
  unicodeEmptyInput: cuchar = 0;   { stands in for C's (const u8*)"" }

function unicodeOpen(p: Psqlite3_tokenizer; const aInput: PChar;
  nInput: cint; pp: PPsqlite3_tokenizer_cursor): cint; cdecl;
var
  pCsr: Punicode_cursor;
begin
  pCsr := Punicode_cursor(sqlite3_malloc(i32(SizeOf(Tunicode_cursor))));
  if pCsr = nil then Exit(SQLITE_NOMEM);
  libc_memset(pCsr, 0, NativeUInt(SizeOf(Tunicode_cursor)));

  pCsr^.aInput := PByte(aInput);
  if aInput = nil then begin
    pCsr^.nInput := 0;
    pCsr^.aInput := @unicodeEmptyInput;
  end else if nInput < 0 then
    pCsr^.nInput := cint(libc_strlen(aInput))
  else
    pCsr^.nInput := nInput;

  pp^ := @pCsr^.base;
  { UNUSED_PARAMETER(p) }
  if p = nil then ;
  Result := SQLITE_OK;
end;

{ fts3_unicode.c:304..309 — unicodeClose. }
function unicodeClose(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;
var
  pCsr: Punicode_cursor;
begin
  pCsr := Punicode_cursor(pCursor);
  sqlite3_free(pCsr^.zToken);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ fts3_unicode.c:315..377 — unicodeNext. }
function unicodeNext(pC: Psqlite3_tokenizer_cursor;
  paToken: PPChar; pnToken: Pcint;
  piStart: Pcint; piEnd: Pcint; piPos: Pcint): cint; cdecl;
var
  pCsr: Punicode_cursor;
  p: Punicode_tokenizer;
  iCode: cuint;
  zOut: PByte;
  z, zStart, zEnd, zTerm: PByte;
  iOut: cint;
  zNew: PChar;
begin
  pCsr := Punicode_cursor(pC);
  p := Punicode_tokenizer(pCsr^.base.pTokenizer);
  iCode := 0;
  z := @pCsr^.aInput[pCsr^.iOff];
  zStart := z;
  zEnd := z;
  zTerm := @pCsr^.aInput[pCsr^.nInput];

  { Scan past any delimiter characters before the start of the next token. }
  while PtrUInt(z) < PtrUInt(zTerm) do begin
    fts3ReadUtf8(z, zTerm, iCode);
    if unicodeIsAlnum(p, cint(iCode)) <> 0 then Break;
    zStart := z;
  end;
  if PtrUInt(zStart) >= PtrUInt(zTerm) then Exit(SQLITE_DONE);

  zOut := PByte(pCsr^.zToken);
  repeat
    { Grow the output buffer if required. }
    if (PtrInt(zOut) - PtrInt(pCsr^.zToken)) >= (pCsr^.nAlloc - 4) then begin
      zNew := PChar(sqlite3_realloc64(pCsr^.zToken, u64(pCsr^.nAlloc + 64)));
      if zNew = nil then Exit(SQLITE_NOMEM);
      zOut := @PByte(zNew)[PtrInt(zOut) - PtrInt(pCsr^.zToken)];
      pCsr^.zToken := zNew;
      Inc(pCsr^.nAlloc, 64);
    end;

    { Write the folded case of the last character read to the output }
    zEnd := z;
    iOut := sqlite3FtsUnicodeFold(cint(iCode), p^.eRemoveDiacritic);
    if iOut <> 0 then
      fts3WriteUtf8(zOut, cuint(iOut));

    { If the cursor is not at EOF, read the next character }
    if PtrUInt(z) >= PtrUInt(zTerm) then Break;
    fts3ReadUtf8(z, zTerm, iCode);
  until not ((unicodeIsAlnum(p, cint(iCode)) <> 0)
          or (sqlite3FtsUnicodeIsdiacritic(cint(iCode)) <> 0));

  { Set the output variables and return. }
  pCsr^.iOff := cint(PtrInt(z) - PtrInt(pCsr^.aInput));
  paToken^ := pCsr^.zToken;
  pnToken^ := cint(PtrInt(zOut) - PtrInt(pCsr^.zToken));
  piStart^ := cint(PtrInt(zStart) - PtrInt(pCsr^.aInput));
  piEnd^ := cint(PtrInt(zEnd) - PtrInt(pCsr^.aInput));
  piPos^ := pCsr^.iToken;
  Inc(pCsr^.iToken);
  Result := SQLITE_OK;
end;

{ fts3_unicode.c:384..392 — the static unicode tokenizer module record. }
const
  unicodeTokenizerModule: Tsqlite3_tokenizer_module = (
    iVersion    : 0;
    xCreate     : @unicodeCreate;
    xDestroy    : @unicodeDestroy;
    xOpen       : @unicodeOpen;
    xClose      : @unicodeClose;
    xNext       : @unicodeNext;
    xLanguageid : nil;
  );

{ fts3_unicode.c:383..394 — sqlite3Fts3UnicodeTokenizer. }
procedure sqlite3Fts3UnicodeTokenizer(ppModule: PPsqlite3_tokenizer_module);
begin
  ppModule^ := @unicodeTokenizerModule;
end;

end.
