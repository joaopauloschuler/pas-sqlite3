{
  SPDX-License-Identifier: blessing

  Partial port of ../sqlite3/src/test_func.c — the test scalar SQL
  user-functions registered via the auto-extension mechanism, plus the
  `autoinstall_test_functions` Tcl command (task 9.4.6.l.4).

  Ported scalar UDFs (test_func.c):
    * randstr               — randStr            (test_func.c:40)
    * test_destructor       — test_destructor     (test_func.c:91)
    * test_destructor_count — test_destructor_count (test_func.c:139)
    * test_error            — test_error          (test_func.c:212)
    * test_counter          — counterFunc         (test_func.c:233)
    * test_isolation        — test_isolation      (test_func.c:268)
    * test_eval             — test_eval           (test_func.c:289)
    * real2hex              — real2hex            (test_func.c:399)
    * test_extract          — test_extract        (test_func.c:441)
    * test_decode           — test_decode         (test_func.c:489)
    * test_zeroblob         — test_zeroblob       (test_func.c:566)
    * hex_to_utf16be        — testHexToUtf16be    (test_func.c:350)
    * hex_to_utf16le        — testHexToUtf16le    (test_func.c:404)
  Aggregate:
    * test_agg_errmsg16     — test_agg_errmsg16_*  (test_func.c:154) —
      no-op step + final returning sqlite3_errmsg (UTF-8 in this port,
      since SQLITE_OMIT_UTF16 is the build default).

  registerTestFunctions (test_func.c:572) is the auto-extension entry; it
  is registered via sqlite3_auto_extension() by autoinstall_test_funcs
  (test_func.c:632) and by Sqlitetest_func_Init (test_func.c:780).  This
  port wires sqlite3AutoLoadExtensions on db-open (task 9.4.6.l.4 prereq),
  so a registered auto-extension actually fires per connection.

  test_extract / test_decode use sqlite3VdbeSerialGet +
  sqlite3VdbeSerialTypeLen + sqlite3GetVarint, all exported from the
  engine (passqlite3vdbe / passqlite3util).

  Not ported (UTF-16 / FTS3 / abuse paths): test_destructor16,
  test_auxdata, test_frombind, abuse_create_function,
  install_fts3_rank_function.  test_getsubtype/test_setsubtype ported
  (task 6.40.8).
  Md5_Register is registered as an auto-extension elsewhere is N/A here.

  Public entry:
    Sqlitetestfunc_Init(interp) — register `autoinstall_test_functions`.

  C ref: test_func.c.
}
{$I passqlite3.inc}
unit TestModuleFunc;

interface

uses
  ctypes,
  SysUtils,
  PasTclBridge,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function Sqlitetestfunc_Init(interp: PTclInterp): cint; cdecl;

implementation

{ cdecl wrapper for sqlite3_free, usable as a result-text destructor.
  (Engine-internal sqlite3FreeXDel is not exported.) }
procedure testFreeXDel(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

{ test_func.c:25 testContextMalloc — allocate, signalling nomem to ctx. }
function testContextMalloc(context: Psqlite3_context; nByte: cint): Pointer;
begin
  Result := sqlite3_malloc(nByte);
  if (Result = nil) and (nByte > 0) then
    sqlite3_result_error_nomem(context);
end;

{ test_func.c:40 randStr — generate a string of random characters. }
procedure randStr(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
const
  zSrc: array[0..78] of AnsiChar =
    'abcdefghijklmnopqrstuvwxyz' +
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ' +
    '0123456789' +
    '.-!,:*^+=_|?/<> ';
var
  iMin, iMax, n, r, i: cint;
  zBuf: array[0..999] of Byte;
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  iMin := sqlite3_value_int(pArg[0]);
  if iMin < 0 then iMin := 0;
  if iMin >= SizeOf(zBuf) then iMin := SizeOf(zBuf) - 1;
  iMax := sqlite3_value_int(pArg[1]);
  if iMax < iMin then iMax := iMin;
  if iMax >= SizeOf(zBuf) then iMax := SizeOf(zBuf) - 1;
  n := iMin;
  if iMax > iMin then
  begin
    r := 0;
    sqlite3_randomness(SizeOf(r), @r);
    r := r and $7fffffff;
    n := n + r mod (iMax + 1 - iMin);
  end;
  sqlite3_randomness(n, @zBuf[0]);
  for i := 0 to n - 1 do
    zBuf[i] := Byte(zSrc[zBuf[i] mod (SizeOf(zSrc) - 1)]);
  zBuf[n] := 0;
  sqlite3_result_text(context, PAnsiChar(@zBuf[0]), n, SQLITE_TRANSIENT);
end;

{ test_func.c:75..107 test_destructor — return arg as TEXT with a
  destructor; test_destructor_count tracks outstanding allocations.
  The C destructor stashes a leading length byte; we mirror that. }
var
  test_destructor_count_var: cint = 0;

procedure testDestructor(p: Pointer); cdecl;
var
  zVal: PAnsiChar;
begin
  zVal := PAnsiChar(p);
  Dec(zVal);
  sqlite3_free(zVal);
  Dec(test_destructor_count_var);
end;

procedure test_destructor(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  zVal: PAnsiChar;
  len:  cint;
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  Inc(test_destructor_count_var);
  if sqlite3_value_type(pArg[0]) = SQLITE_NULL then Exit;
  len := sqlite3_value_bytes(pArg[0]);
  zVal := PAnsiChar(testContextMalloc(context, len + 3));
  if zVal = nil then Exit;
  zVal[len + 1] := #0;
  zVal[len + 2] := #0;
  Inc(zVal);
  Move(sqlite3_value_text(pArg[0])^, zVal^, len);
  sqlite3_result_text(context, zVal, -1, @testDestructor);
end;

procedure test_destructor_count(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
begin
  sqlite3_result_int(context, test_destructor_count_var);
end;

{ test_func.c:154 test_agg_errmsg16 — no-op step + final returning the
  connection's error message.  The UTF-16 path is OMIT'd in this port,
  so the final returns the UTF-8 errmsg. }
procedure test_agg_errmsg16_step(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
begin
end;

procedure test_agg_errmsg16_final(context: Psqlite3_context); cdecl;
var
  db: PTsqlite3;
begin
  db := sqlite3_context_db_handle(context);
  sqlite3_aggregate_context(context, 2048);
  sqlite3_result_text(context, sqlite3_errmsg(PTsqlite3(db)), -1,
    SQLITE_TRANSIENT);
end;

{ test_func.c:212 test_error — return arg[0] as the error message; if a
  second argument exists it becomes the error code. }
procedure test_error(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  sqlite3_result_error(context, sqlite3_value_text(pArg[0]), -1);
  if argc = 2 then
    sqlite3_result_error_code(context, sqlite3_value_int(pArg[1]));
end;

{ test_func.c:233 counterFunc — first call returns X, then X+1, ... }
procedure counterFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pCounter: ^cint;
  pArg:     PPsqlite3_value;
begin
  pArg := argv;
  pCounter := sqlite3_get_auxdata(context, 0);
  if pCounter = nil then
  begin
    pCounter := sqlite3_malloc(SizeOf(cint));
    if pCounter = nil then
    begin
      sqlite3_result_error_nomem(context);
      Exit;
    end;
    pCounter^ := sqlite3_value_int(pArg[0]);
    sqlite3_set_auxdata(context, 0, pCounter, @testFreeXDel);
  end
  else
    Inc(pCounter^);
  sqlite3_result_int(context, pCounter^);
end;

{ test_func.c:268 test_isolation — UTF conversions on arg[0] then return
  a copy of arg[1].  UTF-16 conversions are OMIT'd; the value_text touch
  preserves the encoding-flip intent for the UTF-8 build. }
procedure test_isolation(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  sqlite3_value_text(pArg[0]);
  sqlite3_result_value(context, pArg[1]);
end;

{ test_func.c:289 test_eval — recursively run an SQL statement and
  return the first column of the first row. }
procedure test_eval(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pStmt: Pointer;
  rc:    cint;
  db:    PTsqlite3;
  zSql:  PAnsiChar;
  zErr:  PAnsiChar;
  pArg:  PPsqlite3_value;
  s:     AnsiString;
begin
  pArg  := argv;
  pStmt := nil;
  db    := sqlite3_context_db_handle(context);
  zSql  := sqlite3_value_text(pArg[0]);
  rc := sqlite3_prepare_v2(PTsqlite3(db), zSql, -1, @pStmt, nil);
  if rc = SQLITE_OK then
  begin
    rc := sqlite3_step(PVdbe(pStmt));
    if rc = SQLITE_ROW then
      sqlite3_result_value(context,
        sqlite3_column_value(PVdbe(pStmt), 0));
    rc := sqlite3_finalize(PVdbe(pStmt));
  end;
  if rc <> 0 then
  begin
    s := 'sqlite3_prepare_v2() error: ' +
         AnsiString(sqlite3_errmsg(PTsqlite3(db)));
    zErr := sqlite3_malloc(Length(s) + 1);
    if zErr <> nil then
    begin
      Move(s[1], zErr^, Length(s));
      zErr[Length(s)] := #0;
      sqlite3_result_text(context, zErr, -1, @testFreeXDel);
    end;
    sqlite3_result_error_code(context, rc);
  end;
end;

{ test_func.c:322 testHexChar — convert one character from hex to binary. }
function testHexChar(c: AnsiChar): cint;
begin
  if (c >= '0') and (c <= '9') then
    Result := Ord(c) - Ord('0')
  else if (c >= 'a') and (c <= 'f') then
    Result := Ord(c) - Ord('a') + 10
  else if (c >= 'A') and (c <= 'F') then
    Result := Ord(c) - Ord('A') + 10
  else
    Result := 0;
end;

{ test_func.c:336 testHexToBin — convert hex to binary in place. }
procedure testHexToBin(zIn: PAnsiChar; zOut: PAnsiChar);
begin
  while (zIn[0] <> #0) and (zIn[1] <> #0) do
  begin
    zOut^ := AnsiChar((testHexChar(zIn[0]) shl 4) + testHexChar(zIn[1]));
    Inc(zOut);
    Inc(zIn, 2);
  end;
end;

{ test_func.c:350 hex_to_utf16be — decode HEX into binary, return as UTF-16BE. }
procedure testHexToUtf16be(pCtx: Psqlite3_context; nArg: cint;
  argv: PPsqlite3_value); cdecl;
var
  n:    cint;
  zIn:  PAnsiChar;
  zOut: PAnsiChar;
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  n   := sqlite3_value_bytes(pArg[0]);
  zIn := sqlite3_value_text(pArg[0]);
  zOut := sqlite3_malloc(n div 2);
  if zOut = nil then
    sqlite3_result_error_nomem(pCtx)
  else
  begin
    testHexToBin(zIn, zOut);
    sqlite3_result_text16be(pCtx, zOut, n div 2, @testFreeXDel);
  end;
end;

{ test_func.c:404 hex_to_utf16le — decode HEX into binary, return as UTF-16LE. }
procedure testHexToUtf16le(pCtx: Psqlite3_context; nArg: cint;
  argv: PPsqlite3_value); cdecl;
var
  n:    cint;
  zIn:  PAnsiChar;
  zOut: PAnsiChar;
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  n   := sqlite3_value_bytes(pArg[0]);
  zIn := sqlite3_value_text(pArg[0]);
  zOut := sqlite3_malloc(n div 2);
  if zOut = nil then
    sqlite3_result_error_nomem(pCtx)
  else
  begin
    testHexToBin(zIn, zOut);
    sqlite3_result_text16le(pCtx, zOut, n div 2, @testFreeXDel);
  end;
end;

{ test_func.c:399 real2hex — big-endian hex of the ieee754 encoding. }
procedure real2hex(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
const
  zHex: array[0..15] of AnsiChar = '0123456789abcdef';
var
  vi:        QWord;
  vr:        Double;
  vx:        array[0..7] of Byte absolute vi;
  zOut:      array[0..19] of AnsiChar;
  i:         cint;
  bigEndian: Boolean;
  pArg:      PPsqlite3_value;
begin
  pArg := argv;
  vi := 1;
  bigEndian := vx[0] = 0;
  vr := sqlite3_value_double(pArg[0]);
  Move(vr, vi, SizeOf(vi));
  for i := 0 to 7 do
  begin
    if bigEndian then
    begin
      zOut[i * 2]     := zHex[(vx[i] shr 4) and $f];
      zOut[i * 2 + 1] := zHex[vx[i] and $f];
    end
    else
    begin
      zOut[14 - i * 2]     := zHex[(vx[i] shr 4) and $f];
      zOut[14 - i * 2 + 1] := zHex[vx[i] and $f];
    end;
  end;
  zOut[16] := #0;
  sqlite3_result_text(context, @zOut[0], -1, SQLITE_TRANSIENT);
end;

{ test_func.c:441 test_extract — extract field `field` from a formatted
  database record blob. }
procedure test_extract(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  db:       PTsqlite3;
  pRec:     Pu8;
  pEndHdr:  Pu8;
  pHdr:     Pu8;
  pBody:    Pu8;
  nHdr:     u64;
  iIdx:     cint;
  iCurrent: cint;
  iSerial:  u64;
  mem:      TMem;
  pArg:     PPsqlite3_value;
begin
  pArg := argv;
  db   := sqlite3_context_db_handle(context);
  pRec := Pu8(sqlite3_value_blob(pArg[0]));
  iIdx := sqlite3_value_int(pArg[1]);

  pHdr := pRec + sqlite3GetVarint(pRec, nHdr);
  pBody := pRec + nHdr;
  pEndHdr := pBody;

  iCurrent := 0;
  while (pHdr < pEndHdr) and (iCurrent <= iIdx) do
  begin
    FillChar(mem, SizeOf(mem), 0);
    mem.db  := db;
    mem.enc := PTsqlite3(db)^.enc;
    pHdr := pHdr + sqlite3GetVarint(pHdr, iSerial);
    sqlite3VdbeSerialGet(pBody, u32(iSerial), @mem);
    pBody := pBody + sqlite3VdbeSerialTypeLen(u32(iSerial));

    if iCurrent = iIdx then
      sqlite3_result_value(context, Psqlite3_value(@mem));

    if mem.szMalloc <> 0 then
      sqlite3DbFree(db, mem.zMalloc);
    Inc(iCurrent);
  end;
end;

{ test_func.c:489 test_decode — decode a formatted database record blob
  into a Tcl list of values (returned as SQLITE_TEXT). }
procedure test_decode(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
const
  hexdigit: array[0..15] of AnsiChar = '0123456789abcdef';
var
  db:       PTsqlite3;
  pRec:     Pu8;
  pEndHdr:  Pu8;
  pHdr:     Pu8;
  pBody:    Pu8;
  nHdr:     u64;
  iSerial:  u64;
  mem:      TMem;
  pRet:     PTclObj;
  pVal:     PTclObj;
  n, i:     cint;
  z:        Pu8;
  sHex:     AnsiString;
  pArg:     PPsqlite3_value;
begin
  pArg := argv;
  db   := sqlite3_context_db_handle(context);

  pRet := Tcl_NewObj;
  Tcl_IncrRefCount(pRet);

  pRec := Pu8(sqlite3_value_blob(pArg[0]));
  pHdr := pRec + sqlite3GetVarint(pRec, nHdr);
  pBody := pRec + nHdr;
  pEndHdr := pBody;

  while pHdr < pEndHdr do
  begin
    pVal := nil;
    FillChar(mem, SizeOf(mem), 0);
    mem.db  := db;
    mem.enc := PTsqlite3(db)^.enc;
    pHdr := pHdr + sqlite3GetVarint(pHdr, iSerial);
    sqlite3VdbeSerialGet(pBody, u32(iSerial), @mem);
    pBody := pBody + sqlite3VdbeSerialTypeLen(u32(iSerial));

    case sqlite3_value_type(Psqlite3_value(@mem)) of
      SQLITE_TEXT:
        pVal := Tcl_NewStringObj(
          sqlite3_value_text(Psqlite3_value(@mem)), -1);
      SQLITE_BLOB:
        begin
          n := sqlite3_value_bytes(Psqlite3_value(@mem));
          z := Pu8(sqlite3_value_blob(Psqlite3_value(@mem)));
          sHex := 'x''';
          for i := 0 to n - 1 do
          begin
            sHex := sHex + hexdigit[(z[i] shr 4) and $0F];
            sHex := sHex + hexdigit[z[i] and $0F];
          end;
          sHex := sHex + '''';
          pVal := Tcl_NewStringObj(PChar(sHex), -1);
        end;
      SQLITE_FLOAT:
        pVal := Tcl_NewDoubleObj(
          sqlite3_value_double(Psqlite3_value(@mem)));
      SQLITE_INTEGER:
        pVal := Tcl_NewWideIntObj(
          sqlite3_value_int64(Psqlite3_value(@mem)));
      SQLITE_NULL:
        pVal := Tcl_NewStringObj(PChar('NULL'), -1);
    end;

    Tcl_ListObjAppendElement(nil, pRet, pVal);

    if mem.szMalloc <> 0 then
      sqlite3DbFree(db, mem.zMalloc);
  end;

  sqlite3_result_text(context, Tcl_GetString(pRet), -1, SQLITE_TRANSIENT);
  Tcl_DecrRefCount(pRet);
end;

{ test_func.c:566 test_zeroblob — like zeroblob() without range checks. }
procedure test_zeroblob(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  sqlite3_result_zeroblob(context, sqlite3_value_int(pArg[0]));
end;

{ test_func.c:619 test_getsubtype — return the subtype for value V. }
procedure test_getsubtype(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  sqlite3_result_int(context, cint(sqlite3_value_subtype(pArg[0])));
end;

{ test_func.c:649 test_setsubtype — return the value V with its subtype
  changed to T. }
procedure test_setsubtype(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  sqlite3_result_value(context, pArg[0]);
  sqlite3_result_subtype(context, cuint(sqlite3_value_int(pArg[1])));
end;

{ ----------------------------------------------------------------------
  test_func.c:572 registerTestFunctions — the auto-extension entry that
  registers the test scalar UDFs into a connection.  Signature matches
  Tsqlite3_loadext_entry (db, **pzErrMsg, *pThunk).
  ---------------------------------------------------------------------- }
type
  TTestFuncDef = record
    zName:    PAnsiChar;
    nArg:     cint;
    eTextRep: cint;
    xFunc:    Pointer;
  end;

function registerTestFunctions(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pThunk: Pointer): cint; cdecl;
const
  aFuncs: array[0..14] of TTestFuncDef = (
    (zName: 'randstr';               nArg: 2;
       eTextRep: SQLITE_UTF8; xFunc: @randStr),
    (zName: 'hex_to_utf16be';         nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @testHexToUtf16be),
    (zName: 'hex_to_utf16le';         nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @testHexToUtf16le),
    (zName: 'test_destructor';        nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @test_destructor),
    (zName: 'test_destructor_count';  nArg: 0;
       eTextRep: SQLITE_UTF8; xFunc: @test_destructor_count),
    (zName: 'test_error';             nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @test_error),
    (zName: 'test_error';             nArg: 2;
       eTextRep: SQLITE_UTF8; xFunc: @test_error),
    (zName: 'test_eval';              nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @test_eval),
    (zName: 'test_isolation';         nArg: 2;
       eTextRep: SQLITE_UTF8; xFunc: @test_isolation),
    (zName: 'test_counter';           nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @counterFunc),
    (zName: 'real2hex';               nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @real2hex),
    (zName: 'test_decode';            nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @test_decode),
    (zName: 'test_extract';           nArg: 2;
       eTextRep: SQLITE_UTF8; xFunc: @test_extract),
    (zName: 'test_getsubtype';         nArg: 1;
       eTextRep: SQLITE_UTF8; xFunc: @test_getsubtype),
    (zName: 'test_setsubtype';         nArg: 2;
       eTextRep: SQLITE_UTF8 or SQLITE_RESULT_SUBTYPE;
       xFunc: @test_setsubtype)
  );
var
  i: cint;
begin
  for i := 0 to High(aFuncs) do
    sqlite3_create_function(db, aFuncs[i].zName, aFuncs[i].nArg,
      aFuncs[i].eTextRep, nil, aFuncs[i].xFunc, nil, nil);

  sqlite3_create_function(db, PAnsiChar('test_zeroblob'), 1,
    SQLITE_UTF8 or SQLITE_DETERMINISTIC, nil, @test_zeroblob, nil, nil);

  sqlite3_create_function(db, PAnsiChar('test_agg_errmsg16'), 0,
    SQLITE_ANY, nil, nil, @test_agg_errmsg16_step,
    @test_agg_errmsg16_final);

  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  test_func.c:617 autoinstall_test_funcs.
  tclcmd: autoinstall_test_functions
  Register registerTestFunctions as an auto-extension so the test scalar
  UDFs are loaded into every new connection.  (Md5_Register is registered
  separately in C; not wired here.)
  ---------------------------------------------------------------------- }
function autoinstall_test_funcs(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
begin
  rc := sqlite3_auto_extension(Tsqlite3_loadext_fn(@registerTestFunctions));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test_func.c:780 Sqlitetest_func_Init — register the Tcl commands.  This
  port surfaces only autoinstall_test_functions (abuse_create_function /
  install_fts3_rank_function are not ported).
  9.4.divbug.66.a — also pre-register registerTestFunctions as an
  auto-extension (mirrors test_func.c:949 — Sqlitetest_func_Init calls
  sqlite3_auto_extension((void(*)(void))registerTestFunctions) at init
  time so randstr / test_destructor / test_auxdata / etc. are surfaced
  on every new connection without each .test file having to invoke
  `autoinstall_test_functions` explicitly).  Resolves
  "no such function: randstr" (tkt3918). }
function Sqlitetestfunc_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('autoinstall_test_functions'),
    @autoinstall_test_funcs, nil, nil);
  sqlite3_initialize;
  sqlite3_auto_extension(Tsqlite3_loadext_fn(@registerTestFunctions));
  Result := TCL_OK;
end;

end.
