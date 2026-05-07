{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/prefixes.c (321 lines in C).

  Provides:
    * Eponymous table-valued function `prefixes(STR)` — yields all
      prefixes of STR from longest to shortest (including STR itself
      and the empty string).  Hidden `original_string` column holds
      the input.
    * Scalar `prefix_length(L,R)` — returns the length in UTF-8
      characters of the longest shared prefix.

  Public entry: sqlite3PrefixesInit(db) — equivalent to
  sqlite3_prefixes_init() in C.
}
{$I passqlite3.inc}
unit passqlite3prefixes;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3PrefixesInit(db: PTsqlite3): i32;

implementation

function strlen(s: PAnsiChar): SizeUInt;
var p: PAnsiChar;
begin
  if s = nil then begin Result := 0; Exit; end;
  p := s;
  while p^ <> #0 do Inc(p);
  Result := SizeUInt(p - s);
end;

function strDupZ(z: PAnsiChar): PAnsiChar;
var n: SizeUInt;
begin
  if z = nil then begin Result := nil; Exit; end;
  n := strlen(z);
  Result := PAnsiChar(sqlite3Malloc(i64(n) + 1));
  if Result = nil then Exit;
  if n > 0 then Move(z^, Result^, n);
  Result[n] := #0;
end;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { prefixes.c:43..49 — prefixes_cursor. }
  PPrefixesCursor = ^TPrefixesCursor;
  TPrefixesCursor = record
    base   : Tsqlite3_vtab_cursor;
    iRowid : i64;
    zStr   : PAnsiChar;
    nStr   : i32;
  end;

var
  prefixesModule: Tsqlite3_module;

{ prefixes.c:64..85 — xConnect. }
function prefixesConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PSqlite3Vtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE prefixes(prefix TEXT, original_string TEXT HIDDEN)');
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  pNew := PSqlite3Vtab(sqlite3Malloc(SizeOf(Tsqlite3_vtab)));
  ppVtab^ := pNew;
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pNew^, SizeOf(Tsqlite3_vtab), 0);
  sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS, 0);
  Result := SQLITE_OK;
end;

{ prefixes.c:90..94 — xDisconnect. }
function prefixesDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ prefixes.c:99..106 — xOpen. }
function prefixesOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PPrefixesCursor;
begin
  pCur := PPrefixesCursor(sqlite3Malloc(SizeOf(TPrefixesCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TPrefixesCursor), 0);
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ prefixes.c:111..116 — xClose. }
function prefixesClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PPrefixesCursor;
begin
  pCur := PPrefixesCursor(cur);
  sqlite3_free(pCur^.zStr);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ prefixes.c:122..126 — xNext. }
function prefixesNext(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PPrefixesCursor;
begin
  pCur := PPrefixesCursor(cur);
  Inc(pCur^.iRowid);
  Result := SQLITE_OK;
end;

{ prefixes.c:132..148 — xColumn.
  Column 0: prefix of length (nStr - iRowid).
  Column 1 (HIDDEN original_string): the full input string. }
function prefixesColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var pCur: PPrefixesCursor;
begin
  pCur := PPrefixesCursor(cur);
  case i of
    0: sqlite3_result_text(ctx, pCur^.zStr,
                           pCur^.nStr - i32(pCur^.iRowid), nil);
  else
    sqlite3_result_text(ctx, pCur^.zStr, pCur^.nStr, nil);
  end;
  Result := SQLITE_OK;
end;

{ prefixes.c:154..158 — xRowid. }
function prefixesRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PPrefixesCursor;
begin
  pCur := PPrefixesCursor(cur);
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

{ prefixes.c:164..167 — xEof.  Iteration ends when iRowid > nStr
  (covers all prefixes from the full string down to the empty string). }
function prefixesEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PPrefixesCursor;
begin
  pCur := PPrefixesCursor(cur);
  if pCur^.iRowid > pCur^.nStr then Result := 1 else Result := 0;
end;

{ prefixes.c:175..191 — xFilter.  Re-snapshot the input string. }
function prefixesFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PPrefixesCursor;
  pVals: ^Psqlite3_value;
begin
  pCur := PPrefixesCursor(cur);
  sqlite3_free(pCur^.zStr);
  if argc > 0 then begin
    pVals := Pointer(argv);
    pCur^.zStr := strDupZ(PAnsiChar(sqlite3_value_text(pVals^)));
    if pCur^.zStr <> nil then
      pCur^.nStr := i32(strlen(pCur^.zStr))
    else
      pCur^.nStr := 0;
  end else begin
    pCur^.zStr := nil;
    pCur^.nStr := 0;
  end;
  pCur^.iRowid := 0;
  Result := SQLITE_OK;
end;

{ prefixes.c:199..221 — xBestIndex.  Honour an `original_string =`
  constraint by binding it as argv[0] and omitting the runtime check. }
function prefixesBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i: i32;
  p: PSqlite3IndexConstraint;
  pUse: PSqlite3IndexConstraintUsage;
begin
  p := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if (p^.iColumn = 1) and (p^.op = SQLITE_INDEX_CONSTRAINT_EQ)
       and (p^.usable <> 0) then begin
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, i);
      pUse^.argvIndex     := 1;
      pUse^.omit          := 1;
      pIdxInfo^.estimatedCost := 10.0;
      pIdxInfo^.estimatedRows := 10;
      Result := SQLITE_OK;
      Exit;
    end;
    Inc(p);
  end;
  pIdxInfo^.estimatedCost := 1.0e9;
  pIdxInfo^.estimatedRows := 1000000000;
  Result := SQLITE_OK;
end;

{ prefixes.c:280..301 — prefix_length(L,R) scalar.
  Counts UTF-8 characters in the longest shared byte prefix.
  Bytes whose top two bits are 10 are continuation bytes and do not
  bump the count; if the divergence falls inside a multi-byte sequence
  we back the count off by one (matches the C source's tail-correction). }
procedure prefixLengthFunc(ctx: Psqlite3_context;
  nVal: i32; apVal: PPsqlite3_value); cdecl;
var
  zL, zR: PAnsiChar;
  nL, nR: i32;
  nByte:  i32;
  nRet:   i32;
  i:      i32;
  pVals:  ^Psqlite3_value;
begin
  pVals := Pointer(apVal);
  zL := PAnsiChar(sqlite3_value_text(pVals^));
  Inc(pVals);
  zR := PAnsiChar(sqlite3_value_text(pVals^));
  pVals := Pointer(apVal);
  nL := sqlite3_value_bytes(pVals^);
  Inc(pVals);
  nR := sqlite3_value_bytes(pVals^);

  nRet := 0;
  if nL > nR then nByte := nL else nByte := nR;
  i := 0;
  while i < nByte do begin
    if (zL = nil) or (zR = nil) then break;
    if zL[i] <> zR[i] then break;
    if (Byte(zL[i]) and $C0) <> $80 then Inc(nRet);
    Inc(i);
  end;
  if (zL <> nil) and (i < nL) and ((Byte(zL[i]) and $C0) = $80) then
    Dec(nRet);
  sqlite3_result_int(ctx, nRet);
end;

function sqlite3PrefixesInit(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_module(db, 'prefixes', @prefixesModule, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'prefix_length', 2, SQLITE_UTF8,
      nil, @prefixLengthFunc, nil, nil);
  Result := rc;
end;

initialization
  FillChar(prefixesModule, SizeOf(prefixesModule), 0);
  prefixesModule.iVersion    := 0;
  prefixesModule.xConnect    := @prefixesConnect;
  prefixesModule.xBestIndex  := @prefixesBestIndex;
  prefixesModule.xDisconnect := @prefixesDisconnect;
  prefixesModule.xOpen       := @prefixesOpen;
  prefixesModule.xClose      := @prefixesClose;
  prefixesModule.xFilter     := @prefixesFilter;
  prefixesModule.xNext       := @prefixesNext;
  prefixesModule.xEof        := @prefixesEof;
  prefixesModule.xColumn     := @prefixesColumn;
  prefixesModule.xRowid      := @prefixesRowid;
end.
