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

end.
