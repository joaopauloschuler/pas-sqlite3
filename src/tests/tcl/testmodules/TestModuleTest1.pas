{
  SPDX-License-Identifier: blessing

  Partial port of ../sqlite3/src/test1.c — the subset of test-harness Tcl
  commands surfaced by the 9.4.4.c 50-test sweep (task 9.4.6.q):

    * sqlite3_connection_pointer DB     — test1.c:85   get_sqlite_pointer
    * sqlite3_db_config DB SETTING ?V?  — test1.c:8617 test_sqlite3_db_config
    * atomic_batch_write PATH           — test1.c:2878 test_atomic_batch_write
    * load_static_extension DB NAME ... — test1.c:8369 tclLoadStaticExtensionCmd

  The `load_static_extension` command knows two extensions: `ieee754`
  (the already-ported passqlite3ieee754 unit — the only static extension
  referenced by the affected tests, atof2.test) and `real2hex` (a thin
  wrapper exposing the test_func.c:432 real2hex scalar, which the
  atof1.test error-display paths invoke).  Additional extensions can be
  added as they are ported.

  real2hex itself is registered through load_static_extension rather than
  via the full autoinstall_test_functions machinery (task 9.4.6.l.4);
  the test1.c subset above is self-contained.

  Public entry:
    Sqlitetest1_Init(interp) — register the four Tcl commands.

  C ref: test1.c, test_func.c, ext/misc/ieee754.c.
}
{$I passqlite3.inc}
unit TestModuleTest1;

interface

uses
  ctypes,
  SysUtils,
  PasTclBridge,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3ieee754,
  passqlite3main;

function Sqlitetest1_Init(interp: PTclInterp): cint; cdecl;

implementation

{ test1.c:39..41 — the first part of the SqliteDb struct from tclsqlite.c.
  The Tcl `db` command's objClientData points at a SqliteDb whose first
  field is the sqlite3* handle. }
type
  PTestSqliteDb = ^TTestSqliteDb;
  TTestSqliteDb = record
    db: PTsqlite3;
  end;

{ test1.c:57..76 — sqlite3TestTextToPtr.  Convert "%p" text back to a
  pointer.  Used by getDbPointer when the argument is not a Tcl command. }
function testHexToInt(h: cint): cint;
begin
  if (h >= Ord('0')) and (h <= Ord('9')) then
    Result := h - Ord('0')
  else if (h >= Ord('a')) and (h <= Ord('f')) then
    Result := h - Ord('a') + 10
  else
    Result := h - Ord('A') + 10;
end;

function sqlite3TestTextToPtr(z: PAnsiChar): Pointer;
var
  v: QWord;
begin
  if (z[0] = '0') and (z[1] = 'x') then
    Inc(z, 2);
  v := 0;
  while z^ <> #0 do
  begin
    v := (v shl 4) + QWord(testHexToInt(Ord(z^)));
    Inc(z);
  end;
  Result := Pointer(PtrUInt(v));
end;

{ test1.c:112..123 — getDbPointer.  Decode a pointer to an sqlite3 object,
  either from a Tcl `db` command name or from a "%p" hex string. }
function getDbPointer(interp: PTclInterp; zA: PAnsiChar;
  ppDb: PPTsqlite3): cint;
var
  cmdInfo: TTclCmdInfo;
  p:       PTestSqliteDb;
begin
  if Tcl_GetCommandInfo(interp, zA, @cmdInfo) <> 0 then
  begin
    p := PTestSqliteDb(cmdInfo.objClientData);
    ppDb^ := p^.db;
  end
  else
    ppDb^ := PTsqlite3(sqlite3TestTextToPtr(zA));
  Result := TCL_OK;
end;

{ test1.c:85..107 — get_sqlite_pointer.  Returns the address of the
  sqlite3* pointer for an sqlite connection instance, as a "%p" hex
  string.  The Pascal port's sqlite3_snprintf has no varargs, so the
  "%p" rendering is done by hand (0x-prefixed lowercase hex). }
function get_sqlite_pointer(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  cmdInfo: TTclCmdInfo;
  p:       PTestSqliteDb;
  zBuf:    array[0..99] of AnsiChar;
  s:       AnsiString;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SQLITE-CONNECTION'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetCommandInfo(interp, Tcl_GetString(objv[1]),
       @cmdInfo) = 0 then
  begin
    Tcl_AppendResult(interp, PChar('command not found: '),
      Tcl_GetString(objv[1]), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  p := PTestSqliteDb(cmdInfo.objClientData);
  s := '0x' + LowerCase(IntToHex(PtrUInt(p^.db), 1));
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(s[1], zBuf[0], Length(s));
  Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
  Result := TCL_OK;
end;

{ test1.c:8617..8680 — test_sqlite3_db_config.
  tclcmd:  sqlite3_db_config DB SETTING ?VALUE?
  Every setting in the table is a boolean/int config slot, so the port
  routes through the engine's sqlite3_db_config_int typed entry point. }
type
  TDbConfigSetting = record
    zName: PAnsiChar;
    eVal:  cint;
  end;

const
  aSetting: array[0..20] of TDbConfigSetting = (
    (zName: 'FKEY';               eVal: SQLITE_DBCONFIG_ENABLE_FKEY),
    (zName: 'TRIGGER';            eVal: SQLITE_DBCONFIG_ENABLE_TRIGGER),
    (zName: 'FTS3_TOKENIZER';     eVal: SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER),
    (zName: 'LOAD_EXTENSION';     eVal: SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION),
    (zName: 'NO_CKPT_ON_CLOSE';   eVal: SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE),
    (zName: 'QPSG';               eVal: SQLITE_DBCONFIG_ENABLE_QPSG),
    (zName: 'TRIGGER_EQP';        eVal: SQLITE_DBCONFIG_TRIGGER_EQP),
    (zName: 'RESET_DB';           eVal: SQLITE_DBCONFIG_RESET_DATABASE),
    (zName: 'DEFENSIVE';          eVal: SQLITE_DBCONFIG_DEFENSIVE),
    (zName: 'WRITABLE_SCHEMA';    eVal: SQLITE_DBCONFIG_WRITABLE_SCHEMA),
    (zName: 'LEGACY_ALTER_TABLE'; eVal: SQLITE_DBCONFIG_LEGACY_ALTER_TABLE),
    (zName: 'DQS_DML';            eVal: SQLITE_DBCONFIG_DQS_DML),
    (zName: 'DQS_DDL';            eVal: SQLITE_DBCONFIG_DQS_DDL),
    (zName: 'LEGACY_FILE_FORMAT'; eVal: SQLITE_DBCONFIG_LEGACY_FILE_FORMAT),
    (zName: 'TRUSTED_SCHEMA';     eVal: SQLITE_DBCONFIG_TRUSTED_SCHEMA),
    (zName: 'STMT_SCANSTATUS';    eVal: SQLITE_DBCONFIG_STMT_SCANSTATUS),
    (zName: 'REVERSE_SCANORDER';  eVal: SQLITE_DBCONFIG_REVERSE_SCANORDER),
    (zName: 'ATTACH_CREATE';      eVal: SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE),
    (zName: 'ATTACH_WRITE';       eVal: SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE),
    (zName: 'COMMENTS';           eVal: SQLITE_DBCONFIG_ENABLE_COMMENTS),
    (zName: 'FP_DIGITS';          eVal: SQLITE_DBCONFIG_FP_DIGITS)
  );

function test_sqlite3_db_config(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i, v:     cint;
  zSetting: PAnsiChar;
  db:       PTsqlite3;
begin
  if (objc <> 4) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB SETTING [VALUE]'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  zSetting := Tcl_GetString(objv[2]);
  if sqlite3_strglob(PAnsiChar('SQLITE_*'), zSetting) = 0 then
    Inc(zSetting, 7);
  if sqlite3_strglob(PAnsiChar('DBCONFIG_*'), zSetting) = 0 then
    Inc(zSetting, 9);
  if sqlite3_strglob(PAnsiChar('ENABLE_*'), zSetting) = 0 then
    Inc(zSetting, 7);
  i := 0;
  while i <= High(aSetting) do
  begin
    if StrComp(zSetting, aSetting[i].zName) = 0 then
      Break;
    Inc(i);
  end;
  if i > High(aSetting) then
  begin
    Tcl_SetObjResult(interp,
      Tcl_NewStringObj(PChar('unknown sqlite3_db_config setting'), -1));
    Result := TCL_ERROR;
    Exit;
  end;
  if objc = 4 then
  begin
    if Tcl_GetIntFromObj(interp, objv[3], @v) <> 0 then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
  end
  else
    v := -1;
  sqlite3_db_config_int(db, aSetting[i].eVal, v, @v);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(v));
  Result := TCL_OK;
end;

{ test1.c:2876..2911 — test_atomic_batch_write.
  Usage: atomic_batch_write PATH
  Returns 1 if the VFS reports SQLITE_IOCAP_BATCH_ATOMIC for PATH. }
function test_atomic_batch_write(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zFile: PAnsiChar;
  db:    PTsqlite3;
  pFd:   Psqlite3_file;
  bRes:  cint;
  dc:    cint;
  rc:    cint;
begin
  db   := nil;
  pFd  := nil;
  bRes := 0;
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('PATH'));
    Result := TCL_ERROR;
    Exit;
  end;
  zFile := Tcl_GetString(objv[1]);

  rc := sqlite3_open(zFile, @db);
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, sqlite3_errmsg(db), Pointer(nil));
    sqlite3_close(db);
    Result := TCL_ERROR;
    Exit;
  end;

  rc := sqlite3_file_control(db, PAnsiChar('main'),
    SQLITE_FCNTL_FILE_POINTER, @pFd);
  dc := pFd^.pMethods^.xDeviceCharacteristics(pFd);
  if (dc and SQLITE_IOCAP_BATCH_ATOMIC) <> 0 then
    bRes := 1;

  Tcl_SetObjResult(interp, Tcl_NewIntObj(bRes));
  sqlite3_close(db);
  Result := TCL_OK;
end;

{ test_func.c:432..459 — real2hex(X).  Big-endian hex of the ieee754
  encoding of X, or NULL if X is not a real number. }
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

{ ----------------------------------------------------------------------
  test1.c:8369..8467 — tclLoadStaticExtensionCmd.
  Usage: load_static_extension DB NAME ...
  ---------------------------------------------------------------------- }
type
  TStaticExtInit = function(db: PTsqlite3; pzErrMsg: PPAnsiChar;
    pApi: Pointer): cint; cdecl;
  TStaticExt = record
    zExtName: PAnsiChar;
    pInit:    TStaticExtInit;
  end;

{ ieee754 — the already-ported passqlite3ieee754 unit.  Wrapped to the
  C extension-init ABI (db, **pzErrMsg, *pApi). }
function ieee754_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3IeeeInit(db);
end;

{ real2hex — a thin "extension" exposing the test_func.c real2hex scalar.
  Not a standalone C extension; bundled here so that tests which rely on
  real2hex but do not call autoinstall_test_functions still work.
  atof1.test only needs `real2hex` to exist. }
function realhex_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3_create_function(db, PAnsiChar('real2hex'), 1,
    SQLITE_UTF8, nil, @real2hex, nil, nil);
end;

function tclLoadStaticExtensionCmd(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
const
  SQLITE_OK_LOAD_PERMANENTLY = 256;  { sqlite3.h — SQLITE_OK | (8<<8) }
var
  aExtension: array[0..1] of TStaticExt;
  db:         PTsqlite3;
  zName:      PAnsiChar;
  i, j, rc:   cint;
  zErrMsg:    PAnsiChar;
begin
  aExtension[0].zExtName := 'ieee754';  aExtension[0].pInit := @ieee754_ext_init;
  aExtension[1].zExtName := 'real2hex'; aExtension[1].pInit := @realhex_ext_init;
  zErrMsg := nil;
  if objc < 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB NAME ...'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  for j := 2 to objc - 1 do
  begin
    zName := Tcl_GetString(objv[j]);
    i := 0;
    while i <= High(aExtension) do
    begin
      if StrComp(zName, aExtension[i].zExtName) = 0 then
        Break;
      Inc(i);
    end;
    if i > High(aExtension) then
    begin
      Tcl_AppendResult(interp, PChar('no such extension: '), zName,
        Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
    if Assigned(aExtension[i].pInit) then
      rc := aExtension[i].pInit(db, @zErrMsg, nil)
    else
      rc := SQLITE_OK;
    if ((rc <> SQLITE_OK) and (rc <> SQLITE_OK_LOAD_PERMANENTLY))
       or (zErrMsg <> nil) then
    begin
      Tcl_AppendResult(interp, PChar('initialization of '), zName,
        PChar(' failed: '), zErrMsg, Pointer(nil));
      sqlite3_free(zErrMsg);
      Result := TCL_ERROR;
      Exit;
    end;
  end;
  Result := TCL_OK;
end;

{ test1.c:9106..9322 — register the subset of Sqlitetest1_Init commands
  needed by the 9.4.4.c sweep. }
function Sqlitetest1_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('sqlite3_connection_pointer'),
    @get_sqlite_pointer, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_db_config'),
    @test_sqlite3_db_config, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('atomic_batch_write'),
    @test_atomic_batch_write, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('load_static_extension'),
    @tclLoadStaticExtensionCmd, nil, nil);
  Result := TCL_OK;
end;

end.
