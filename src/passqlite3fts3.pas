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

end.
