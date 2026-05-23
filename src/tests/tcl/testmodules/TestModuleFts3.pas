{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/fts3/fts3_test.c (the SQLITE_TEST-only
  Tcl harness for FTS3/FTS4, Sqlitetestfts3_Init at fts3_test.c:603).

  Registers the Tcl commands the gated fts3*/fts4* .test files invoke:

    * sqlite_fts3_enable_parentheses   — Tcl_LinkVar (test1.c:9447..9449)
        bound to passqlite3fts3.sqlite3_fts3_enable_parentheses so a test can
        flip the query syntax between legacy and the parenthesised grammar.
    * fts3_near_match DOC EXPR ?-phrasecountvar VAR?
        (fts3_test.c:146) — NEAR matcher used by fts3auto.test.
    * fts3_configure_incr_load ?CHUNKSIZE THRESHOLD?
        (fts3_test.c:285) — reads/overrides the incremental-load tunables.
    * fts3_test_varint INTEGER
        (fts3_test.c:524) — round-trips an integer through the FTS3 varint
        codecs (used by fts3varint.test).
    * fts3_test_tokenizer
        (fts3_test.c:495) — returns the address of a v1 test tokenizer that
        honours xLanguageid (used by fts4langid.test).
    * sqlite3_fts3_may_be_corrupt ?BOOLEAN?
        (fts3_test.c:579) — under a non-DEBUG build (this port's reality,
        matching the oracle's autosetup default) this is a no-op returning
        an empty result, exactly as the C #ifdef SQLITE_DEBUG body compiles
        away.

  6.40.1.o.  Public entry: Sqlitetestfts3_Init(interp).
}
{$I passqlite3.inc}
unit TestModuleFts3;

interface

uses
  ctypes,
  Strings,           { StrLen — FPC RTL, replaces libc strlen (6.40.1.p) }
  PasTclBridge,
  passqlite3types,
  passqlite3os,      { sqlite3_malloc / sqlite3_malloc64 / sqlite3_free }
  passqlite3util,    { sqlite3_free }
  passqlite3printf,  { sqlite3PfMprintf — Pascal-side varargs formatter }
  passqlite3fts3;    { varint codecs + the test globals }

function Sqlitetestfts3_Init(interp: PTclInterp): cint; cdecl;

implementation

{ libc bindings (mirrors the implementation-private set in passqlite3fts3.pas;
  re-declared here because those are not exported from the unit's interface).
  6.40.1.p — strlen/memset/memcmp now use FPC RTL (StrLen/FillChar/CompareByte);
  strcmp retained. }
function libc_strcmp(a, b: PChar): cint; cdecl; external 'c' name 'strcmp';

const
  NM_MAX_TOKEN = 12;

type
  { fts3_test.c:42..45 — struct NearToken. }
  TNearToken = record
    n : cint;            { Length of token in bytes }
    z : PChar;           { Pointer to token string }
  end;
  PNearToken = ^TNearToken;
  TNearTokenArray = array[0..MaxInt div SizeOf(TNearToken) - 1] of TNearToken;
  PNearTokenArray = ^TNearTokenArray;

  { fts3_test.c:37..40 — struct NearDocument. }
  TNearDocument = record
    nToken : cint;
    aToken : PNearTokenArray;
  end;
  PNearDocument = ^TNearDocument;

  { fts3_test.c:47..51 — struct NearPhrase. }
  TNearPhrase = record
    nNear  : cint;
    nToken : cint;
    aToken : array[0..NM_MAX_TOKEN-1] of TNearToken;
  end;
  PNearPhrase = ^TNearPhrase;
  TNearPhraseArray = array[0..MaxInt div SizeOf(TNearPhrase) - 1] of TNearPhrase;
  PNearPhraseArray = ^TNearPhraseArray;

{ Helper: index into a Tcl_Obj* C array. }
function ObjElem(ap: PPTclObj; idx: cint): PTclObj; inline;
begin
  Result := PPTclObj(PByte(ap) + idx*SizeOf(Pointer))^;
end;

{ fts3_test.c:53..71 — nm_phrase_match. }
function nm_phrase_match(p: PNearPhrase; aToken: PNearTokenArray): cint;
var
  ii: cint;
  pToken: PNearToken;
begin
  for ii := 0 to p^.nToken-1 do begin
    pToken := @p^.aToken[ii];
    if (pToken^.n > 0) and (pToken^.z[pToken^.n-1] = '*') then begin
      if aToken^[ii].n < (pToken^.n-1) then begin Result := 0; Exit; end;
      if CompareByte((aToken^[ii].z)^, (pToken^.z)^, pToken^.n-1) <> 0 then begin
        Result := 0; Exit;
      end;
    end else begin
      if aToken^[ii].n <> pToken^.n then begin Result := 0; Exit; end;
      if CompareByte((aToken^[ii].z)^, (pToken^.z)^, pToken^.n) <> 0 then begin
        Result := 0; Exit;
      end;
    end;
  end;
  Result := 1;
end;

{ fts3_test.c:73..115 — nm_near_chain. }
function nm_near_chain(iDir: cint; pDoc: PNearDocument; iPos: cint;
  nPhrase: cint; aPhrase: PNearPhraseArray; iPhrase: cint): cint;
var
  iStart, iStop, ii, nNear, iPhrase2: cint;
  p, pPrev: PNearPhrase;
begin
  if iDir = 1 then begin
    if (iPhrase+1) = nPhrase then begin Result := 1; Exit; end;
    nNear := aPhrase^[iPhrase+1].nNear;
  end else begin
    if iPhrase = 0 then begin Result := 1; Exit; end;
    nNear := aPhrase^[iPhrase].nNear;
  end;
  pPrev := @aPhrase^[iPhrase];
  iPhrase2 := iPhrase+iDir;
  p := @aPhrase^[iPhrase2];

  iStart := iPos - nNear - p^.nToken;
  iStop  := iPos + nNear + pPrev^.nToken;

  if iStart < 0 then iStart := 0;
  if iStop > pDoc^.nToken - p^.nToken then iStop := pDoc^.nToken - p^.nToken;

  ii := iStart;
  while ii <= iStop do begin
    if nm_phrase_match(p, @pDoc^.aToken^[ii]) <> 0 then begin
      if nm_near_chain(iDir, pDoc, ii, nPhrase, aPhrase, iPhrase2) <> 0 then begin
        Result := 1; Exit;
      end;
    end;
    Inc(ii);
  end;
  Result := 0;
end;

{ fts3_test.c:117..141 — nm_match_count. }
function nm_match_count(pDoc: PNearDocument; nPhrase: cint;
  aPhrase: PNearPhraseArray; iPhrase: cint): cint;
var
  nOcc, ii: cint;
  p: PNearPhrase;
begin
  nOcc := 0;
  p := @aPhrase^[iPhrase];
  ii := 0;
  while ii < (pDoc^.nToken + 1 - p^.nToken) do begin
    if nm_phrase_match(p, @pDoc^.aToken^[ii]) <> 0 then begin
      if nm_near_chain(1, pDoc, ii, nPhrase, aPhrase, iPhrase) = 0 then begin
        Inc(ii); Continue;
      end;
      if nm_near_chain(-1, pDoc, ii, nPhrase, aPhrase, iPhrase) = 0 then begin
        Inc(ii); Continue;
      end;
      Inc(nOcc);
    end;
    Inc(ii);
  end;
  Result := nOcc;
end;

{ fts3_test.c:143..258 — fts3_near_match.
  Tclcmd: fts3_near_match DOCUMENT EXPR ?OPTION VALUE?... }
function fts3_near_match_cmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
label near_match_out;
var
  nTotal, rc, ii: cint;
  nPhrase: cint;
  aPhrase: PNearPhraseArray;
  doc: TNearDocument;
  apDocToken: PPTclObj;
  pRet: PTclObj;
  pPhrasecount: PTclObj;
  apExprToken: PPTclObj;
  nExprToken, nn: cint;
  pPhrase: PTclObj;
  apToken: PPTclObj;
  nToken, jj: cint;
  pT: PNearToken;
  pNear: PTclObj;
  nNear, nOcc: cint;
  zOpt: PChar;
begin
  nTotal := 0;
  aPhrase := nil;
  doc.nToken := 0;
  doc.aToken := nil;
  pPhrasecount := nil;
  rc := TCL_OK;

  { Must have 3 or more arguments, odd objc. }
  if (objc < 3) or ((objc mod 2) = 0) then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DOCUMENT EXPR ?OPTION VALUE?...'));
    rc := TCL_ERROR;
    goto near_match_out;
  end;

  ii := 3;
  while ii < objc do begin
    zOpt := Tcl_GetStringFromObj(ObjElem(objv, ii), nil);
    if libc_strcmp(zOpt, PChar('-phrasecountvar')) = 0 then
      pPhrasecount := ObjElem(objv, ii+1)
    else begin
      Tcl_ResetResult(interp);
      Tcl_AppendResult(interp, PChar('bad option "'), zOpt,
        PChar('": must be -phrasecountvar'), nil);
      rc := TCL_ERROR;
      goto near_match_out;
    end;
    Inc(ii, 2);
  end;

  rc := Tcl_ListObjGetElements(interp, ObjElem(objv, 1), @nn, @apDocToken);
  doc.nToken := nn;
  if rc <> TCL_OK then goto near_match_out;
  doc.aToken := PNearTokenArray(Tcl_Alloc(cuint(doc.nToken*SizeOf(TNearToken))));
  for ii := 0 to doc.nToken-1 do begin
    doc.aToken^[ii].z := Tcl_GetStringFromObj(ObjElem(apDocToken, ii), @nn);
    doc.aToken^[ii].n := nn;
  end;

  rc := Tcl_ListObjGetElements(interp, ObjElem(objv, 2), @nExprToken, @apExprToken);
  if rc <> TCL_OK then goto near_match_out;

  nPhrase := (nExprToken + 1) div 2;
  aPhrase := PNearPhraseArray(Tcl_Alloc(cuint(nPhrase*SizeOf(TNearPhrase))));
  FillChar((aPhrase)^, NativeUInt(nPhrase*SizeOf(TNearPhrase)), Byte(0));
  for ii := 0 to nPhrase-1 do begin
    pPhrase := ObjElem(apExprToken, ii*2);
    rc := Tcl_ListObjGetElements(interp, pPhrase, @nToken, @apToken);
    if rc <> TCL_OK then goto near_match_out;
    if nToken > NM_MAX_TOKEN then begin
      Tcl_AppendResult(interp, PChar('Too many tokens in phrase'), nil);
      rc := TCL_ERROR;
      goto near_match_out;
    end;
    for jj := 0 to nToken-1 do begin
      pT := @aPhrase^[ii].aToken[jj];
      pT^.z := Tcl_GetStringFromObj(ObjElem(apToken, jj), @nn);
      pT^.n := nn;
    end;
    aPhrase^[ii].nToken := nToken;
  end;
  for ii := 1 to nPhrase-1 do begin
    pNear := ObjElem(apExprToken, 2*ii-1);
    rc := Tcl_GetIntFromObj(interp, pNear, @nNear);
    if rc <> TCL_OK then goto near_match_out;
    aPhrase^[ii].nNear := nNear;
  end;

  pRet := Tcl_NewObj();
  Tcl_IncrRefCount(pRet);
  for ii := 0 to nPhrase-1 do begin
    nOcc := nm_match_count(@doc, nPhrase, aPhrase, ii);
    Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(nOcc));
    Inc(nTotal, nOcc);
  end;
  if pPhrasecount <> nil then
    Tcl_ObjSetVar2(interp, pPhrasecount, nil, pRet, 0);
  Tcl_DecrRefCount(pRet);
  Tcl_SetObjResult(interp, Tcl_NewBooleanObj(cint(Ord(nTotal > 0))));

near_match_out:
  if aPhrase <> nil then Tcl_Free(PChar(aPhrase));
  if doc.aToken <> nil then Tcl_Free(PChar(doc.aToken));
  Result := rc;
end;

{ fts3_test.c:260..326 — fts3_configure_incr_load.
  Tclcmd: fts3_configure_incr_load ?CHUNKSIZE THRESHOLD? }
function fts3_configure_incr_load_cmd(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  pRet: PTclObj;
  iArg1, iArg2: cint;
begin
  if (objc <> 1) and (objc <> 3) then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?CHUNKSIZE THRESHOLD?'));
    Result := TCL_ERROR;
    Exit;
  end;

  pRet := Tcl_NewObj();
  Tcl_IncrRefCount(pRet);
  Tcl_ListObjAppendElement(interp, pRet,
    Tcl_NewIntObj(test_fts3_node_chunksize));
  Tcl_ListObjAppendElement(interp, pRet,
    Tcl_NewIntObj(test_fts3_node_chunk_threshold));

  if objc = 3 then begin
    if (Tcl_GetIntFromObj(interp, ObjElem(objv, 1), @iArg1) <> TCL_OK)
    or (Tcl_GetIntFromObj(interp, ObjElem(objv, 2), @iArg2) <> TCL_OK) then begin
      Tcl_DecrRefCount(pRet);
      Result := TCL_ERROR;
      Exit;
    end;
    test_fts3_node_chunksize := iArg1;
    test_fts3_node_chunk_threshold := iArg2;
  end;

  Tcl_SetObjResult(interp, pRet);
  Tcl_DecrRefCount(pRet);
  Result := TCL_OK;
end;

{ ====================================================================== }
{ fts3_test.c:343..492 — the v1 "test" tokenizer (xLanguageid-aware).    }
{ ====================================================================== }

type
  { fts3_test.c:343..345. }
  TTestTokenizer = record
    base : Tsqlite3_tokenizer;
  end;
  PTestTokenizer = ^TTestTokenizer;

  { fts3_test.c:347..356. }
  TTestTokenizerCursor = record
    base    : Tsqlite3_tokenizer_cursor;
    aInput  : PChar;
    nInput  : cint;
    iInput  : cint;
    iToken  : cint;
    aBuffer : PChar;
    nBuffer : cint;
    iLangid : cint;
  end;
  PTestTokenizerCursor = ^TTestTokenizerCursor;

function testTokenizerCreate(argc: cint; const argv: PPChar;
  ppTokenizer: PPsqlite3_tokenizer): cint; cdecl;
var
  pNew: PTestTokenizer;
begin
  pNew := PTestTokenizer(sqlite3_malloc(cint(SizeOf(TTestTokenizer))));
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar((pNew)^, SizeOf(TTestTokenizer), Byte(0));
  ppTokenizer^ := Psqlite3_tokenizer(pNew);
  Result := SQLITE_OK;
end;

function testTokenizerDestroy(pTokenizer: Psqlite3_tokenizer): cint; cdecl;
begin
  sqlite3_free(pTokenizer);
  Result := SQLITE_OK;
end;

function testTokenizerOpen(pTokenizer: Psqlite3_tokenizer; const pInput: PChar;
  nBytes: cint; ppCursor: PPsqlite3_tokenizer_cursor): cint; cdecl;
var
  rc: cint;
  pCsr: PTestTokenizerCursor;
begin
  rc := SQLITE_OK;
  pCsr := PTestTokenizerCursor(
            sqlite3_malloc(cint(SizeOf(TTestTokenizerCursor))));
  if pCsr = nil then
    rc := SQLITE_NOMEM
  else begin
    FillChar((pCsr)^, SizeOf(TTestTokenizerCursor), Byte(0));
    pCsr^.aInput := pInput;
    if nBytes < 0 then
      pCsr^.nInput := cint(StrLen(pInput))
    else
      pCsr^.nInput := nBytes;
  end;
  ppCursor^ := Psqlite3_tokenizer_cursor(pCsr);
  Result := rc;
end;

function testTokenizerClose(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;
var
  pCsr: PTestTokenizerCursor;
begin
  pCsr := PTestTokenizerCursor(pCursor);
  sqlite3_free(pCsr^.aBuffer);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

function testIsTokenChar(c: Char): cint; inline;
begin
  if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) then
    Result := 1
  else
    Result := 0;
end;

function testTolower(c: Char): Char; inline;
begin
  Result := c;
  if (Result >= 'A') and (Result <= 'Z') then
    Result := Char(Ord(Result) - (Ord('A') - Ord('a')));
end;

function testTokenizerNext(pCursor: Psqlite3_tokenizer_cursor;
  ppToken: PPChar; pnBytes: Pcint;
  piStartOffset: Pcint; piEndOffset: Pcint; piPosition: Pcint): cint; cdecl;
var
  pCsr: PTestTokenizerCursor;
  rc: cint;
  p, pEnd, pToken: PChar;
  nToken: sqlite3_int64;
  i: cint;
begin
  pCsr := PTestTokenizerCursor(pCursor);
  rc := SQLITE_OK;

  p := @pCsr^.aInput[pCsr^.iInput];
  pEnd := @pCsr^.aInput[pCsr^.nInput];

  { Skip past any non-token characters. }
  while (p < pEnd) and (testIsTokenChar(p^) = 0) do Inc(p);

  if p = pEnd then
    rc := SQLITE_DONE
  else begin
    pToken := p;
    while (p < pEnd) and (testIsTokenChar(p^) <> 0) do Inc(p);
    nToken := sqlite3_int64(p - pToken);

    if nToken > pCsr^.nBuffer then begin
      sqlite3_free(pCsr^.aBuffer);
      pCsr^.aBuffer := PChar(sqlite3_malloc64(u64(nToken)));
    end;
    if pCsr^.aBuffer = nil then
      rc := SQLITE_NOMEM
    else begin
      if (pCsr^.iLangid and $00000001) <> 0 then begin
        for i := 0 to cint(nToken)-1 do pCsr^.aBuffer[i] := pToken[i];
      end else begin
        for i := 0 to cint(nToken)-1 do
          pCsr^.aBuffer[i] := testTolower(pToken[i]);
      end;
      Inc(pCsr^.iToken);
      pCsr^.iInput := cint(p - pCsr^.aInput);

      ppToken^ := pCsr^.aBuffer;
      pnBytes^ := cint(nToken);
      piStartOffset^ := cint(pToken - pCsr^.aInput);
      piEndOffset^ := cint(p - pCsr^.aInput);
      piPosition^ := pCsr^.iToken;
    end;
  end;

  Result := rc;
end;

function testTokenizerLanguage(pCursor: Psqlite3_tokenizer_cursor;
  iLangid: cint): cint; cdecl;
var
  pCsr: PTestTokenizerCursor;
begin
  pCsr := PTestTokenizerCursor(pCursor);
  pCsr^.iLangid := iLangid;
  if pCsr^.iLangid >= 100 then
    Result := SQLITE_ERROR
  else
    Result := SQLITE_OK;
end;

var
  { fts3_test.c:502..510 — the static v1 test tokenizer module. }
  testTokenizerModule: Tsqlite3_tokenizer_module;
  pTestTokModule: Psqlite3_tokenizer_module;

{ fts3_test.c:495..522 — fts3_test_tokenizer.
  Returns the address of testTokenizerModule as a byte array. }
function fts3_test_tokenizer_cmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  if objc <> 1 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR;
    Exit;
  end;
  pTestTokModule := @testTokenizerModule;
  Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(
    @pTestTokModule, cint(SizeOf(Pointer))));
  Result := TCL_OK;
end;

{ fts3_test.c:524..568 — fts3_test_varint INTEGER. }
function fts3_test_varint_cmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  aBuf: array[0..23] of Char;
  rc: cint;
  w, w2: Int64;
  nByte, nByte2: cint;
  i: cint;
  zErr: PChar;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('INTEGER'));
    Result := TCL_ERROR;
    Exit;
  end;

  rc := Tcl_GetWideIntFromObj(interp, ObjElem(objv, 1), @w);
  if rc <> TCL_OK then begin Result := rc; Exit; end;

  nByte := sqlite3Fts3PutVarint(@aBuf[0], w);
  nByte2 := sqlite3Fts3GetVarint(@aBuf[0], @w2);
  if (w <> w2) or (nByte <> nByte2) then begin
    zErr := PChar(sqlite3PfMprintf(PAnsiChar('error testing %lld'), [w]));
    Tcl_ResetResult(interp);
    Tcl_AppendResult(interp, zErr, nil);
    sqlite3_free(zErr);
    Result := TCL_ERROR;
    Exit;
  end;

  if (w <= 2147483647) and (w >= 0) then begin
    nByte2 := sqlite3Fts3GetVarint32(@aBuf[0], @i);
    if (cint(w) <> i) or (nByte <> nByte2) then begin
      zErr := PChar(sqlite3PfMprintf(PAnsiChar('error testing %lld (32-bit)'), [w]));
      Tcl_ResetResult(interp);
      Tcl_AppendResult(interp, zErr, nil);
      sqlite3_free(zErr);
      Result := TCL_ERROR;
      Exit;
    end;
  end;

  Result := TCL_OK;
end;

{ test_hexio.c:363..389 — read_fts3varint BLOB VARNAME.
  Decode a single fts3 varint from the front of BLOB, store the value into
  Tcl variable VARNAME, and return the number of bytes consumed.  Used by
  fts3_common.tcl (fts3c.test / fts3d.test / fts3cov.test). }
function read_fts3varint_cmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zBlob: PChar;
  nBlob: cint;
  iVal: Int64;
  nVal: cint;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BLOB VARNAME'));
    Result := TCL_ERROR;
    Exit;
  end;
  nBlob := 0;
  zBlob := Tcl_GetByteArrayFromObj(ObjElem(objv, 1), @nBlob);
  iVal := 0;
  nVal := sqlite3Fts3GetVarint(zBlob, @iVal);
  Tcl_ObjSetVar2(interp, ObjElem(objv, 2), nil, Tcl_NewWideIntObj(iVal), 0);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(nVal));
  Result := TCL_OK;
  if (clientData = nil) and (nBlob = 0) then ;
end;

{ fts3_test.c:574..601 — sqlite3_fts3_may_be_corrupt.
  This port (and the oracle's autosetup build) is non-DEBUG, so the C body
  compiles away to a bare `return TCL_OK` with an empty result. }
function fts3_may_be_corrupt_cmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  Result := TCL_OK;
end;

{ fts3_test.c:603..618 — Sqlitetestfts3_Init, plus the
  sqlite_fts3_enable_parentheses Tcl_LinkVar from test1.c:9447..9449. }
function Sqlitetestfts3_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('fts3_near_match'),
    @fts3_near_match_cmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('fts3_configure_incr_load'),
    @fts3_configure_incr_load_cmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('fts3_test_tokenizer'),
    @fts3_test_tokenizer_cmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('fts3_test_varint'),
    @fts3_test_varint_cmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_fts3_may_be_corrupt'),
    @fts3_may_be_corrupt_cmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('read_fts3varint'),
    @read_fts3varint_cmd, nil, nil);
  { test1.c:9447..9449 — link the query-syntax toggle so the gated fts3*.test
    files can flip between legacy and parenthesised grammar. }
  Tcl_LinkVar(interp, PChar('sqlite_fts3_enable_parentheses'),
    @sqlite3_fts3_enable_parentheses, TCL_LINK_INT);
  Result := TCL_OK;
end;

initialization
  testTokenizerModule.iVersion    := 1;
  testTokenizerModule.xCreate     := @testTokenizerCreate;
  testTokenizerModule.xDestroy    := @testTokenizerDestroy;
  testTokenizerModule.xOpen       := @testTokenizerOpen;
  testTokenizerModule.xClose      := @testTokenizerClose;
  testTokenizerModule.xNext       := @testTokenizerNext;
  testTokenizerModule.xLanguageid := @testTokenizerLanguage;
end.
