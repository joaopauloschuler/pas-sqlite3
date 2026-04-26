{$I passqlite3.inc}
unit passqlite3jsoneach;

{
  Phase 6.8.h.5 — json_each / json_tree virtual tables.

  Faithful port of the table-valued virtual tables exported by
  ../sqlite3/src/json.c lines 5020..5680.  Kept in a unit of its own
  (rather than appended to passqlite3json.pas) so the json core does
  not have to depend on passqlite3vtab — the same pattern used by
  passqlite3carray / passqlite3dbpage / passqlite3dbstat for the other
  in-tree vtab modules.

  Public surface:
    * jsonEachModule — Tsqlite3_module record (json.c:5566).
    * sqlite3JsonVtabRegister(db, zName) — install the module under
      one of "json_each" / "json_tree" / "jsonb_each" / "jsonb_tree"
      (json.c:5667).  Plumbed into sqlite3RegisterBuiltinFunctions
      by the upcoming 6.8.h.6 chunk.

  All callbacks have Pascal cdecl signatures and live behind opaque
  Pointer slots in Tsqlite3_module so the same record literal works
  whether xCreate / xRowid etc are typed or not.

  Helpers borrowed from passqlite3json:
    jsonStringInit/Reset/Zero, jsonAppendRaw, jsonAppendChar,
    jsonbPayloadSize, jsonReturnFromBlob, jsonbType, jsonArgIsJsonb,
    jsonConvertTextToBlob, jsonBadPathError, jsonParseReset,
    jsonLookupStep, jsonLookupIsError, JSON_LOOKUP_NOTFOUND,
    JSON_SUBTYPE.

  jsonPrintf is private in json.c; the only place jsonAppendPathName
  uses it is to format a tiny `[%lld]`, `."%.*s"` or `.%.*s` chunk.
  We inline that logic via the local jeFmtArrayKey / jeFmtObjectKey
  helpers to avoid promoting jsonPrintf to public API.

  Tests: src/tests/TestJsonEach.pas.  Module shape, BestIndex
  constraint dispatch, xOpen/xClose, and a Filter+Next+Column round
  trip on a small json_each invocation against a fabricated
  sqlite3_context.
}

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3json;

const
  { Column ordinals — json.c:5069..5081.  JSON and ROOT are HIDDEN. }
  JEACH_KEY     = 0;
  JEACH_VALUE   = 1;
  JEACH_TYPE    = 2;
  JEACH_ATOM    = 3;
  JEACH_ID      = 4;
  JEACH_PARENT  = 5;
  JEACH_FULLKEY = 6;
  JEACH_PATH    = 7;
  JEACH_JSON    = 8;
  JEACH_ROOT    = 9;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { json.c:5022 — JsonParent: parent-frame entry on the recursion stack
    used by json_tree(). }
  PJsonParent = ^TJsonParent;
  TJsonParent = record
    iHead  : u32;   { Start of object or array }
    iValue : u32;   { Start of the value }
    iEnd   : u32;   { First byte past the end }
    nPath  : u32;   { Length of path }
    iKey   : i64;   { Key for JSONB_ARRAY (-1 sentinel) }
  end;

  { json.c:5048 — per-vtab connection state (one per CREATE VIRTUAL TABLE). }
  PJsonEachConnection = ^TJsonEachConnection;
  TJsonEachConnection = record
    base       : Tsqlite3_vtab;     { MUST be first }
    db         : Pointer;           { Psqlite3 }
    eMode      : u8;                { 1=json_*; 2=jsonb_* }
    bRecursive : u8;                { 1=*_tree; 0=*_each }
    _pad       : array[0..5] of u8;
  end;

  { json.c:5031 — per-cursor scan state.  base must be first for the
    pointer-cast contract used by every vtab callback. }
  PJsonEachCursor = ^TJsonEachCursor;
  TJsonEachCursor = record
    base         : Tsqlite3_vtab_cursor;   { MUST be first }
    iRowid       : u32;
    i            : u32;
    iEnd         : u32;
    nRoot        : u32;
    eType        : u8;
    bRecursive   : u8;
    eMode        : u8;
    _pad0        : u8;
    nParent      : u32;
    nParentAlloc : u32;
    aParent      : PJsonParent;
    db           : Pointer;                { Psqlite3 }
    path         : TJsonString;
    sParse       : TJsonParse;
  end;

{ json.c:5566 — the module record.  Slot pointers are exposed so the
  6.8.h.6 registration chunk and gate tests can inspect them without
  going through the per-db registry. }
var
  jsonEachModule: Tsqlite3_module;

{ json.c:5667 — register one of "json_each" / "json_tree" / "jsonb_each"
  / "jsonb_tree" against db^.aModule and return the registry entry. }
function sqlite3JsonVtabRegister(db: PTsqlite3; zName: PAnsiChar): PVtabModule;

implementation

{ ===========================================================================
  Local formatting helpers (stand-ins for the private jsonPrintf in json.c
  used by jsonAppendPathName).
  =========================================================================== }

{ Append the decimal repr of a signed i64 to a TJsonString. }
procedure jeAppendInt64(p: PJsonString; v: i64);
var
  buf : array[0..23] of AnsiChar;
  rev : array[0..23] of AnsiChar;
  n   : i32;
  k   : i32;
  uv  : u64;
  neg : Boolean;
begin
  neg := v < 0;
  if neg then
    uv := u64(-(v + 1)) + 1
  else
    uv := u64(v);
  if uv = 0 then
  begin
    buf[0] := '0';
    jsonAppendRaw(p, @buf[0], 1);
    Exit;
  end;
  n := 0;
  while uv > 0 do
  begin
    rev[n] := AnsiChar(Ord('0') + (uv mod 10));
    uv := uv div 10;
    Inc(n);
  end;
  k := 0;
  if neg then
  begin
    buf[0] := '-';
    k := 1;
  end;
  while n > 0 do
  begin
    Dec(n);
    buf[k] := rev[n];
    Inc(k);
  end;
  jsonAppendRaw(p, @buf[0], u32(k));
end;

{ json.c:5178 — append "[<int>]" to the path buffer. }
procedure jeFmtArrayKey(p: PJsonString; v: i64);
var c: AnsiChar;
begin
  c := '[';
  jsonAppendRaw(p, @c, 1);
  jeAppendInt64(p, v);
  c := ']';
  jsonAppendRaw(p, @c, 1);
end;

{ json.c:5197 — append `."abc"` (or `."abc.def"`) when the label needs
  quoting (any non-alphanumeric byte or non-alpha first byte). }
procedure jeFmtObjectKeyQuoted(p: PJsonString; z: PAnsiChar; n: u32);
var c: AnsiChar;
begin
  c := '.'; jsonAppendRaw(p, @c, 1);
  c := '"'; jsonAppendRaw(p, @c, 1);
  jsonAppendRaw(p, z, n);
  c := '"'; jsonAppendRaw(p, @c, 1);
end;

{ json.c:5199 — append `.<bareword>`. }
procedure jeFmtObjectKey(p: PJsonString; z: PAnsiChar; n: u32);
var c: AnsiChar;
begin
  c := '.'; jsonAppendRaw(p, @c, 1);
  jsonAppendRaw(p, z, n);
end;

{ ===========================================================================
  Path / cursor helpers — direct ports
  =========================================================================== }

{ json.c:5161 — when the cursor is parked on an object label, return the
  index of the value it labels; otherwise return the current i. }
function jsonSkipLabel(p: PJsonEachCursor): u32;
var
  sz, n: u32;
begin
  if p^.eType = JSONB_OBJECT then
  begin
    sz := 0;
    n  := jsonbPayloadSize(@p^.sParse, p^.i, sz);
    Result := p^.i + n + sz;
  end
  else
    Result := p^.i;
end;

{ json.c:5174 — append the path component for the current element. }
procedure jsonAppendPathName(p: PJsonEachCursor);
var
  n, sz, k, i: u32;
  z: PAnsiChar;
  needQuote: i32;
begin
  Assert(p^.nParent > 0, 'jsonAppendPathName: nParent=0');
  Assert((p^.eType = JSONB_ARRAY) or (p^.eType = JSONB_OBJECT),
         'jsonAppendPathName: unexpected eType');
  if p^.eType = JSONB_ARRAY then
  begin
    jeFmtArrayKey(@p^.path, p^.aParent[p^.nParent - 1].iKey);
  end
  else
  begin
    sz := 0;
    n  := jsonbPayloadSize(@p^.sParse, p^.i, sz);
    k  := p^.i + n;
    z  := PAnsiChar(p^.sParse.aBlob) + k;
    needQuote := 0;
    if (sz = 0) or (sqlite3Isalpha(u8(z[0])) = 0) then
      needQuote := 1
    else
    begin
      i := 0;
      while i < sz do
      begin
        if sqlite3Isalnum(u8(z[i])) = 0 then
        begin
          needQuote := 1;
          Break;
        end;
        Inc(i);
      end;
    end;
    if needQuote <> 0 then
      jeFmtObjectKeyQuoted(@p^.path, z, sz)
    else
      jeFmtObjectKey(@p^.path, z, sz);
  end;
end;

{ json.c:5271 — length of the path prefix for rowid==0 in bRecursive mode.
  Trims the trailing `[i]` / `.x` so the rendered "path" column reports the
  parent path rather than the current key. }
function jsonEachPathLength(p: PJsonEachCursor): i32;
var
  n  : u32;
  z  : PAnsiChar;
  x  : u32;
  sz : u32;
  cSaved : AnsiChar;
begin
  n := u32(p^.path.nUsed);
  z := p^.path.zBuf;
  if (p^.iRowid = 0) and (p^.bRecursive <> 0) and (n >= 2) then
  begin
    while n > 1 do
    begin
      Dec(n);
      if (z[n] = '[') or (z[n] = '.') then
      begin
        sz := 0;
        cSaved := z[n];
        z[n] := #0;
        Assert(p^.sParse.eEdit = 0, 'jsonEachPathLength: eEdit set');
        x := jsonLookupStep(@p^.sParse, 0, z + 1, 0);
        z[n] := cSaved;
        if jsonLookupIsError(x) then Continue;
        if x + jsonbPayloadSize(@p^.sParse, x, sz) = p^.i then Break;
      end;
    end;
  end;
  Result := i32(n);
end;

{ ===========================================================================
  Module callbacks
  =========================================================================== }

{ json.c:5057 — xConnect.  argv[0] is the module name; eMode/bRecursive
  follow the spelling ("jsonb_*" → eMode=2; "*_tree" → bRecursive=1). }
function jsonEachConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew : PJsonEachConnection;
  rc   : i32;
  zNm  : PAnsiChar;
begin
  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE x(key,value,type,atom,id,parent,fullkey,path,'
    + 'json HIDDEN,root HIDDEN)');
  if rc = SQLITE_OK then
  begin
    pNew := PJsonEachConnection(sqlite3DbMallocZero(db,
      SizeOf(TJsonEachConnection)));
    ppVtab^ := PSqlite3Vtab(pNew);
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS, 0);
    pNew^.db := db;
    { Spelling check on argv[0]:
        bytes 0..3 are always "json"; byte 4 is either 'b' (jsonb_*) or
        '_' (json_*).  When eMode=2 (jsonb), the "tree"/"each" letter is
        at byte 6; otherwise byte 5. }
    zNm := argv[0];
    if zNm[4] = 'b' then pNew^.eMode := 2 else pNew^.eMode := 1;
    if zNm[4 + pNew^.eMode] = 't' then
      pNew^.bRecursive := 1
    else
      pNew^.bRecursive := 0;
  end;
  Result := rc;
end;

{ json.c:5103 — xDisconnect. }
function jsonEachDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
var
  p: PJsonEachConnection;
begin
  p := PJsonEachConnection(pVtab);
  sqlite3DbFree(p^.db, pVtab);
  Result := SQLITE_OK;
end;

{ json.c:5110 — xOpen. }
function jsonEachOpen(pVtab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pTab: PJsonEachConnection;
  pCur: PJsonEachCursor;
begin
  pTab := PJsonEachConnection(pVtab);
  pCur := PJsonEachCursor(sqlite3DbMallocZero(pTab^.db,
    SizeOf(TJsonEachCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  pCur^.db         := pTab^.db;
  pCur^.eMode      := pTab^.eMode;
  pCur^.bRecursive := pTab^.bRecursive;
  jsonStringZero(@pCur^.path);
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ json.c:5127 — reset cursor state to "no scan in progress". }
procedure jsonEachCursorReset(p: PJsonEachCursor);
begin
  jsonParseReset(@p^.sParse);
  jsonStringReset(@p^.path);
  sqlite3DbFree(p^.db, p^.aParent);
  p^.iRowid       := 0;
  p^.i            := 0;
  p^.aParent      := nil;
  p^.nParent      := 0;
  p^.nParentAlloc := 0;
  p^.iEnd         := 0;
  p^.eType        := 0;
end;

{ json.c:5141 — xClose. }
function jsonEachClose(cur: PSqlite3VtabCursor): i32; cdecl;
var
  p: PJsonEachCursor;
begin
  p := PJsonEachCursor(cur);
  jsonEachCursorReset(p);
  sqlite3DbFree(p^.db, cur);
  Result := SQLITE_OK;
end;

{ json.c:5151 — xEof. }
function jsonEachEof(cur: PSqlite3VtabCursor): i32; cdecl;
var
  p: PJsonEachCursor;
begin
  p := PJsonEachCursor(cur);
  if p^.i >= p^.iEnd then Result := 1 else Result := 0;
end;

{ json.c:5205 — xNext.  Two control paths: recursive (json_tree) and flat
  (json_each).  In the recursive case we also maintain the parent stack
  so xColumn knows the full path. }
function jsonEachNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  p           : PJsonEachCursor;
  rc          : i32;
  x           : u8;
  levelChange : u8;
  n, sz       : u32;
  i           : u32;
  pParent     : PJsonParent;
  pNew        : PJsonParent;
  nNew        : u64;
  iVal        : u32;
begin
  p  := PJsonEachCursor(cur);
  rc := SQLITE_OK;
  if p^.bRecursive <> 0 then
  begin
    levelChange := 0;
    sz := 0;
    i  := jsonSkipLabel(p);
    x  := p^.sParse.aBlob[i] and $0F;
    n  := jsonbPayloadSize(@p^.sParse, i, sz);
    if (x = JSONB_OBJECT) or (x = JSONB_ARRAY) then
    begin
      if p^.nParent >= p^.nParentAlloc then
      begin
        nNew := u64(p^.nParentAlloc) * 2 + 3;
        pNew := PJsonParent(sqlite3DbRealloc(p^.db, p^.aParent,
          SizeOf(TJsonParent) * nNew));
        if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
        p^.nParentAlloc := u32(nNew);
        p^.aParent      := pNew;
      end;
      levelChange := 1;
      pParent := @p^.aParent[p^.nParent];
      pParent^.iHead  := p^.i;
      pParent^.iValue := i;
      pParent^.iEnd   := i + n + sz;
      pParent^.iKey   := -1;
      pParent^.nPath  := u32(p^.path.nUsed);
      if (p^.eType <> 0) and (p^.nParent <> 0) then
      begin
        jsonAppendPathName(p);
        if p^.path.eErr <> 0 then rc := SQLITE_NOMEM;
      end;
      Inc(p^.nParent);
      p^.i := i + n;
    end
    else
      p^.i := i + n + sz;
    while (p^.nParent > 0)
      and (p^.i >= p^.aParent[p^.nParent - 1].iEnd) do
    begin
      Dec(p^.nParent);
      p^.path.nUsed := p^.aParent[p^.nParent].nPath;
      levelChange := 1;
    end;
    if levelChange <> 0 then
    begin
      if p^.nParent > 0 then
      begin
        pParent := @p^.aParent[p^.nParent - 1];
        iVal := pParent^.iValue;
        p^.eType := p^.sParse.aBlob[iVal] and $0F;
      end
      else
        p^.eType := 0;
    end;
  end
  else
  begin
    sz := 0;
    i  := jsonSkipLabel(p);
    n  := jsonbPayloadSize(@p^.sParse, i, sz);
    p^.i := i + n + sz;
  end;
  if (p^.eType = JSONB_ARRAY) and (p^.nParent <> 0) then
    Inc(p^.aParent[p^.nParent - 1].iKey);
  Inc(p^.iRowid);
  Result := rc;
end;

{ json.c:5293 — xColumn. }
function jsonEachColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; iColumn: i32): i32; cdecl;
var
  p     : PJsonEachCursor;
  i, n  : u32;
  j     : i32;
  eType : u8;
  x     : i64;
  nBase : u64;
begin
  p := PJsonEachCursor(cur);
  case iColumn of
    JEACH_KEY: begin
      if p^.nParent = 0 then
      begin
        if p^.nRoot = 1 then
        begin
          Result := SQLITE_OK; Exit;
        end;
        j := jsonEachPathLength(p);
        n := p^.nRoot - u32(j);
        if n = 0 then
        begin
          { fallthrough — produce no value (NULL) }
        end
        else if p^.path.zBuf[j] = '[' then
        begin
          x := 0;
          sqlite3Atoi64(p^.path.zBuf + j + 1, x, i32(n) - 1, SQLITE_UTF8);
          sqlite3_result_int64(ctx, x);
        end
        else if p^.path.zBuf[j + 1] = '"' then
        begin
          sqlite3_result_text(ctx, p^.path.zBuf + j + 2, i32(n) - 3,
            SQLITE_TRANSIENT);
        end
        else
        begin
          sqlite3_result_text(ctx, p^.path.zBuf + j + 1, i32(n) - 1,
            SQLITE_TRANSIENT);
        end;
        Result := SQLITE_OK; Exit;
      end;
      if p^.eType = JSONB_OBJECT then
        jsonReturnFromBlob(@p^.sParse, p^.i, ctx, 1)
      else
      begin
        Assert(p^.eType = JSONB_ARRAY, 'jsonEachColumn: KEY non-array');
        sqlite3_result_int64(ctx, p^.aParent[p^.nParent - 1].iKey);
      end;
    end;
    JEACH_VALUE: begin
      i := jsonSkipLabel(p);
      jsonReturnFromBlob(@p^.sParse, i, ctx, p^.eMode);
      if (p^.sParse.aBlob[i] and $0F) >= JSONB_ARRAY then
        sqlite3_result_subtype(ctx, JSON_SUBTYPE);
    end;
    JEACH_TYPE: begin
      i := jsonSkipLabel(p);
      eType := p^.sParse.aBlob[i] and $0F;
      sqlite3_result_text(ctx, jsonbType[eType], -1, SQLITE_STATIC);
    end;
    JEACH_ATOM: begin
      i := jsonSkipLabel(p);
      if (p^.sParse.aBlob[i] and $0F) < JSONB_ARRAY then
        jsonReturnFromBlob(@p^.sParse, i, ctx, 1);
    end;
    JEACH_ID: begin
      sqlite3_result_int64(ctx, i64(p^.i));
    end;
    JEACH_PARENT: begin
      if (p^.nParent > 0) and (p^.bRecursive <> 0) then
        sqlite3_result_int64(ctx, i64(p^.aParent[p^.nParent - 1].iHead));
    end;
    JEACH_FULLKEY: begin
      nBase := p^.path.nUsed;
      if p^.nParent <> 0 then jsonAppendPathName(p);
      sqlite3_result_text64(ctx, p^.path.zBuf, p^.path.nUsed,
        SQLITE_TRANSIENT, SQLITE_UTF8);
      p^.path.nUsed := nBase;
    end;
    JEACH_PATH: begin
      n := u32(jsonEachPathLength(p));
      sqlite3_result_text64(ctx, p^.path.zBuf, n,
        SQLITE_TRANSIENT, SQLITE_UTF8);
    end;
    JEACH_JSON: begin
      if p^.sParse.zJson = nil then
        sqlite3_result_blob(ctx, p^.sParse.aBlob, i32(p^.sParse.nBlob),
          SQLITE_TRANSIENT)
      else
        sqlite3_result_text(ctx, p^.sParse.zJson, -1, SQLITE_TRANSIENT);
    end;
  else
    { Default arm — including JEACH_ROOT — emits the "$" anchor. }
    sqlite3_result_text(ctx, p^.path.zBuf, i32(p^.nRoot), SQLITE_STATIC);
  end;
  Result := SQLITE_OK;
end;

{ json.c:5390 — xRowid. }
function jsonEachRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var
  p: PJsonEachCursor;
begin
  p := PJsonEachCursor(cur);
  pRowid^ := i64(p^.iRowid);
  Result := SQLITE_OK;
end;

{ json.c:5401 — xBestIndex.  We expect EQ constraints on the JSON and
  ROOT hidden columns (the last two).  idxNum:
    0 — no usable JSON constraint (full-table-scan, prohibitive cost)
    1 — JSON only
    3 — JSON + ROOT path }
function jsonEachBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i           : i32;
  aIdx        : array[0..1] of i32;
  unusableMask: i32;
  idxMask     : i32;
  pConstraint : PSqlite3IndexConstraint;
  pUse        : PSqlite3IndexConstraintUsage;
  iCol        : i32;
  iMask       : i32;
begin
  Assert(JEACH_ROOT = JEACH_JSON + 1, 'jsonEachBestIndex: column ordering');
  aIdx[0] := -1; aIdx[1] := -1;
  unusableMask := 0;
  idxMask := 0;
  pConstraint := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do
  begin
    if pConstraint^.iColumn >= JEACH_JSON then
    begin
      iCol := pConstraint^.iColumn - JEACH_JSON;
      Assert((iCol = 0) or (iCol = 1), 'jsonEachBestIndex: iCol oob');
      iMask := 1 shl iCol;
      if pConstraint^.usable = 0 then
        unusableMask := unusableMask or iMask
      else if pConstraint^.op = SQLITE_INDEX_CONSTRAINT_EQ then
      begin
        aIdx[iCol] := i;
        idxMask := idxMask or iMask;
      end;
    end;
    Inc(pConstraint);
  end;
  if (pIdxInfo^.nOrderBy > 0)
    and (pIdxInfo^.aOrderBy^.iColumn < 0)
    and (pIdxInfo^.aOrderBy^.desc = 0) then
    pIdxInfo^.orderByConsumed := 1;

  if (unusableMask and (not idxMask)) <> 0 then
  begin
    Result := SQLITE_CONSTRAINT; Exit;
  end;
  if aIdx[0] < 0 then
  begin
    pIdxInfo^.idxNum := 0;
  end
  else
  begin
    pIdxInfo^.estimatedCost := 1.0;
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, aIdx[0]);
    pUse^.argvIndex := 1;
    pUse^.omit      := 1;
    if aIdx[1] < 0 then
      pIdxInfo^.idxNum := 1
    else
    begin
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, aIdx[1]);
      pUse^.argvIndex := 2;
      pUse^.omit      := 1;
      pIdxInfo^.idxNum := 3;
    end;
  end;
  Result := SQLITE_OK;
end;

{ json.c:5467 — xFilter.  Handles three idxNum branches:
    0 → leave cursor empty (no JSON arg)
    1 → JSON only; scan the full doc
    3 → JSON + ROOT; resolve the path before iterating. }
function jsonEachFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  p     : PJsonEachCursor;
  zRoot : PAnsiChar;
  i, n, sz : u32;
  arg0, arg1: Psqlite3_value;
  pVtab : PSqlite3Vtab;
  cDollar: AnsiChar;
label
  json_each_malformed_input;
begin
  p := PJsonEachCursor(cur);
  zRoot := nil;
  jsonEachCursorReset(p);
  if idxNum = 0 then begin Result := SQLITE_OK; Exit; end;
  arg0 := argv[0];
  FillChar(p^.sParse, SizeOf(p^.sParse), 0);
  p^.sParse.nJPRef := 1;
  p^.sParse.db := p^.db;
  if jsonArgIsJsonb(arg0, @p^.sParse) <> 0 then
  begin
    { JSONB input — sParse populated by jsonArgIsJsonb. }
  end
  else
  begin
    p^.sParse.zJson := PAnsiChar(sqlite3_value_text(arg0));
    p^.sParse.nJson := sqlite3_value_bytes(arg0);
    if p^.sParse.zJson = nil then
    begin
      p^.i := 0;
      p^.iEnd := 0;
      Result := SQLITE_OK; Exit;
    end;
    if jsonConvertTextToBlob(@p^.sParse, nil) <> 0 then
    begin
      if p^.sParse.oom <> 0 then begin Result := SQLITE_NOMEM; Exit; end;
      goto json_each_malformed_input;
    end;
  end;
  if idxNum = 3 then
  begin
    arg1 := argv[1];
    zRoot := PAnsiChar(sqlite3_value_text(arg1));
    if zRoot = nil then begin Result := SQLITE_OK; Exit; end;
    if zRoot[0] <> '$' then
    begin
      pVtab := cur^.pVtab;
      sqlite3_free(pVtab^.zErrMsg);
      pVtab^.zErrMsg := jsonBadPathError(nil, zRoot, 0);
      jsonEachCursorReset(p);
      if pVtab^.zErrMsg <> nil then Result := SQLITE_ERROR
      else Result := SQLITE_NOMEM;
      Exit;
    end;
    p^.nRoot := u32(sqlite3Strlen30(zRoot));
    if zRoot[1] = #0 then
    begin
      i := 0; p^.i := 0; p^.eType := 0;
    end
    else
    begin
      i := jsonLookupStep(@p^.sParse, 0, zRoot + 1, 0);
      if jsonLookupIsError(i) then
      begin
        if i = JSON_LOOKUP_NOTFOUND then
        begin
          p^.i := 0; p^.eType := 0; p^.iEnd := 0;
          Result := SQLITE_OK; Exit;
        end;
        pVtab := cur^.pVtab;
        sqlite3_free(pVtab^.zErrMsg);
        pVtab^.zErrMsg := jsonBadPathError(nil, zRoot, 0);
        jsonEachCursorReset(p);
        if pVtab^.zErrMsg <> nil then Result := SQLITE_ERROR
        else Result := SQLITE_NOMEM;
        Exit;
      end;
      if p^.sParse.iLabel <> 0 then
      begin
        p^.i := p^.sParse.iLabel;
        p^.eType := JSONB_OBJECT;
      end
      else
      begin
        p^.i := i;
        p^.eType := JSONB_ARRAY;
      end;
    end;
    jsonAppendRaw(@p^.path, zRoot, p^.nRoot);
  end
  else
  begin
    i := 0; p^.i := 0; p^.eType := 0;
    p^.nRoot := 1;
    cDollar := '$';
    jsonAppendRaw(@p^.path, @cDollar, 1);
  end;
  p^.nParent := 0;
  sz := 0;
  n := jsonbPayloadSize(@p^.sParse, i, sz);
  p^.iEnd := i + n + sz;
  if ((p^.sParse.aBlob[i] and $0F) >= JSONB_ARRAY)
    and (p^.bRecursive = 0) then
  begin
    p^.i := i + n;
    p^.eType := p^.sParse.aBlob[i] and $0F;
    p^.aParent := PJsonParent(sqlite3DbMallocZero(p^.db,
      SizeOf(TJsonParent)));
    if p^.aParent = nil then begin Result := SQLITE_NOMEM; Exit; end;
    p^.nParent      := 1;
    p^.nParentAlloc := 1;
    p^.aParent[0].iKey   := 0;
    p^.aParent[0].iEnd   := p^.iEnd;
    p^.aParent[0].iHead  := p^.i;
    p^.aParent[0].iValue := i;
  end;
  Result := SQLITE_OK;
  Exit;

json_each_malformed_input:
  pVtab := cur^.pVtab;
  sqlite3_free(pVtab^.zErrMsg);
  pVtab^.zErrMsg := sqlite3VtabFmtMsg1Libc('%s', AnsiString('malformed JSON'));
  jsonEachCursorReset(p);
  if pVtab^.zErrMsg <> nil then Result := SQLITE_ERROR
  else Result := SQLITE_NOMEM;
end;

{ ===========================================================================
  Module entry point
  =========================================================================== }

{ json.c:5667 — register one of the four spellings. }
function sqlite3JsonVtabRegister(db: PTsqlite3;
  zName: PAnsiChar): PVtabModule;
const
  azModule: array[0..3] of PAnsiChar = (
    'json_each', 'json_tree', 'jsonb_each', 'jsonb_tree'
  );
var
  i: i32;
begin
  for i := 0 to 3 do
  begin
    if sqlite3StrICmp(azModule[i], zName) = 0 then
    begin
      Result := sqlite3VtabCreateModule(db, azModule[i],
        @jsonEachModule, nil, nil);
      Exit;
    end;
  end;
  Result := nil;
end;

initialization
  FillChar(jsonEachModule, SizeOf(jsonEachModule), 0);
  jsonEachModule.iVersion    := 0;
  jsonEachModule.xCreate     := nil;
  jsonEachModule.xConnect    := @jsonEachConnect;
  jsonEachModule.xBestIndex  := @jsonEachBestIndex;
  jsonEachModule.xDisconnect := @jsonEachDisconnect;
  jsonEachModule.xDestroy    := nil;
  jsonEachModule.xOpen       := @jsonEachOpen;
  jsonEachModule.xClose      := @jsonEachClose;
  jsonEachModule.xFilter     := @jsonEachFilter;
  jsonEachModule.xNext       := @jsonEachNext;
  jsonEachModule.xEof        := @jsonEachEof;
  jsonEachModule.xColumn     := @jsonEachColumn;
  jsonEachModule.xRowid      := @jsonEachRowid;
end.
