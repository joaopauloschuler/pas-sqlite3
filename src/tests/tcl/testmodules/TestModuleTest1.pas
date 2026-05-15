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
  passqlite3backup,
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

{ ----------------------------------------------------------------------
  9.4.6.q.1 — test1.c prepared-statement Tcl wrappers.

  Test1.c references (line ranges):
    * sqlite3_exec                test1.c:417..460   (test_exec)
    * sqlite3_errmsg              test1.c:4904..4929 (test_errmsg)
    * sqlite3_prepare             test1.c:5027..5082 (test_prepare)
    * sqlite3_prepare_v2          test1.c:5084..5156 (test_prepare_v2)
    * sqlite3_transfer_bindings   test1.c:3140..3164 (test_transfer_bind)
    * sqlite3_backup family       test_backup.c:26..150 (backupTest*)
  ---------------------------------------------------------------------- }

{ main.c — sqlite3ErrName: enum-name table for the rc codes the backup
  Tcl commands surface.  Minimal subset, mirrors echoErrName but covers
  every code sqlite3_backup_step / _finish can return. }
function t1ErrName(rc: cint): PAnsiChar;
begin
  case rc of
    SQLITE_OK:         Result := PChar('SQLITE_OK');
    SQLITE_ERROR:      Result := PChar('SQLITE_ERROR');
    SQLITE_INTERNAL:   Result := PChar('SQLITE_INTERNAL');
    SQLITE_PERM:       Result := PChar('SQLITE_PERM');
    SQLITE_ABORT:      Result := PChar('SQLITE_ABORT');
    SQLITE_BUSY:       Result := PChar('SQLITE_BUSY');
    SQLITE_LOCKED:     Result := PChar('SQLITE_LOCKED');
    SQLITE_NOMEM:      Result := PChar('SQLITE_NOMEM');
    SQLITE_READONLY:   Result := PChar('SQLITE_READONLY');
    SQLITE_INTERRUPT:  Result := PChar('SQLITE_INTERRUPT');
    SQLITE_IOERR:      Result := PChar('SQLITE_IOERR');
    SQLITE_CORRUPT:    Result := PChar('SQLITE_CORRUPT');
    SQLITE_NOTFOUND:   Result := PChar('SQLITE_NOTFOUND');
    SQLITE_FULL:       Result := PChar('SQLITE_FULL');
    SQLITE_CANTOPEN:   Result := PChar('SQLITE_CANTOPEN');
    SQLITE_PROTOCOL:   Result := PChar('SQLITE_PROTOCOL');
    SQLITE_EMPTY:      Result := PChar('SQLITE_EMPTY');
    SQLITE_SCHEMA:     Result := PChar('SQLITE_SCHEMA');
    SQLITE_TOOBIG:     Result := PChar('SQLITE_TOOBIG');
    SQLITE_CONSTRAINT: Result := PChar('SQLITE_CONSTRAINT');
    SQLITE_MISMATCH:   Result := PChar('SQLITE_MISMATCH');
    SQLITE_MISUSE:     Result := PChar('SQLITE_MISUSE');
    SQLITE_NOLFS:      Result := PChar('SQLITE_NOLFS');
    SQLITE_AUTH:       Result := PChar('SQLITE_AUTH');
    SQLITE_FORMAT:     Result := PChar('SQLITE_FORMAT');
    SQLITE_RANGE:      Result := PChar('SQLITE_RANGE');
    SQLITE_NOTADB:     Result := PChar('SQLITE_NOTADB');
    SQLITE_ROW:        Result := PChar('SQLITE_ROW');
    SQLITE_DONE:       Result := PChar('SQLITE_DONE');
  else
    Result := PChar('SQLITE_Unknown');
  end;
end;

{ Format a pointer as the "%p"-flavoured hex test1.c hands to Tcl. }
procedure ptrToHex(p: Pointer; out zBuf: AnsiString);
begin
  zBuf := '0x' + LowerCase(IntToHex(PtrUInt(p), 1));
end;

{ test1.c:419..460 — test_exec.
  Usage: sqlite3_exec DB SQL  (string-arg form).
  The Pascal port collapses the result to a single-list: "{rc} {result-or-err}",
  matching what Tcl_AppendElement produces.  We skip the % hex-decode pass
  (it's only used by a handful of obscure tests) — straight passthrough. }
type
  TExecCtx = record
    rows: AnsiString;
  end;
  PExecCtx = ^TExecCtx;

function execPrintfCb(pArg: Pointer; nCol: i32;
  argv: PPAnsiChar; colv: PPAnsiChar): i32; cdecl;
var
  ctx: PExecCtx;
  i:   i32;
  z:   PAnsiChar;
begin
  ctx := PExecCtx(pArg);
  for i := 0 to nCol - 1 do
  begin
    if Length(ctx^.rows) > 0 then ctx^.rows := ctx^.rows + ' ';
    z := PPAnsiChar(PtrUInt(argv) + PtrUInt(i) * SizeOf(Pointer))^;
    if z = nil then
      ctx^.rows := ctx^.rows + '{}'
    else
      ctx^.rows := ctx^.rows + '{' + AnsiString(z) + '}';
  end;
  Result := 0;
end;

function test_exec(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  rc:    i32;
  zErr:  PAnsiChar;
  ctx:   TExecCtx;
  zBuf:  array[0..31] of AnsiChar;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB SQL'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  ctx.rows := '';
  zErr := nil;
  rc := sqlite3_exec(db, Tcl_GetString(objv[2]), @execPrintfCb, @ctx, @zErr);
  FillChar(zBuf, SizeOf(zBuf), 0);
  StrPCopy(zBuf, IntToStr(rc));
  Tcl_AppendElement(interp, @zBuf[0]);
  if rc = SQLITE_OK then
    Tcl_AppendElement(interp, PChar(ctx.rows))
  else if zErr <> nil then
    Tcl_AppendElement(interp, zErr)
  else
    Tcl_AppendElement(interp, PChar(''));
  if zErr <> nil then sqlite3_free(zErr);
  Result := TCL_OK;
end;

{ test1.c:4910..4929 — test_errmsg.
  Usage: sqlite3_errmsg DB. }
function test_errmsg(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:   PTsqlite3;
  zErr: PAnsiChar;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zErr := sqlite3_errmsg(db);
  Tcl_SetObjResult(interp, Tcl_NewStringObj(zErr, -1));
  Result := TCL_OK;
end;

{ test1.c:5035..5082 — test_prepare.
  Usage: sqlite3_prepare DB sql bytes ?tailvar? }
function test_prepare(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  zSql:  PAnsiChar;
  zTail: PAnsiChar;
  pStmt: Pointer;
  bytes, nTail: cint;
  rc:    i32;
  hex:   AnsiString;
  zBuf:  array[0..63] of AnsiChar;
begin
  if (objc <> 5) and (objc <> 4) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB sql bytes ?tailvar?'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zSql := Tcl_GetString(objv[2]);
  if Tcl_GetIntFromObj(interp, objv[3], @bytes) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zTail := nil;
  pStmt := nil;
  if objc >= 5 then
    rc := sqlite3_prepare(db, zSql, bytes, @pStmt, @zTail)
  else
    rc := sqlite3_prepare(db, zSql, bytes, @pStmt, nil);
  Tcl_ResetResult(interp);
  if (zTail <> nil) and (objc >= 5) then
  begin
    if bytes >= 0 then
      bytes := bytes - cint(PtrUInt(zTail) - PtrUInt(zSql));
    nTail := StrLen(zTail);
    if nTail < bytes then bytes := nTail;
    Tcl_ObjSetVar2(interp, objv[4], nil,
      Tcl_NewStringObj(zTail, bytes), 0);
  end;
  if rc <> SQLITE_OK then
  begin
    FillChar(zBuf, SizeOf(zBuf), 0);
    StrPCopy(zBuf, '(' + IntToStr(rc) + ') ');
    Tcl_AppendResult(interp, @zBuf[0], sqlite3_errmsg(db), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if pStmt <> nil then
  begin
    ptrToHex(pStmt, hex);
    FillChar(zBuf, SizeOf(zBuf), 0);
    Move(hex[1], zBuf[0], Length(hex));
    Tcl_AppendResult(interp, @zBuf[0], Pointer(nil));
  end;
  Result := TCL_OK;
end;

{ test1.c:5092..5156 — test_prepare_v2.
  Usage: sqlite3_prepare_v2 DB sql bytes ?tailvar?  The test1.c version
  malloc-copies the SQL to make valgrind happier; we skip the copy (still
  exercises the same engine path). }
function test_prepare_v2(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  zSql:  PAnsiChar;
  zTail: PAnsiChar;
  pStmt: Pointer;
  bytes: cint;
  rc:    i32;
  hex:   AnsiString;
  zBuf:  array[0..63] of AnsiChar;
begin
  if (objc <> 5) and (objc <> 4) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB sql bytes ?tailvar?'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zSql := Tcl_GetString(objv[2]);
  if Tcl_GetIntFromObj(interp, objv[3], @bytes) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zTail := nil;
  pStmt := nil;
  if objc >= 5 then
    rc := sqlite3_prepare_v2(db, zSql, bytes, @pStmt, @zTail)
  else
    rc := sqlite3_prepare_v2(db, zSql, bytes, @pStmt, nil);
  Tcl_ResetResult(interp);
  if (rc = SQLITE_OK) and (objc >= 5) and (zTail <> nil) then
  begin
    if bytes >= 0 then
      bytes := bytes - cint(PtrUInt(zTail) - PtrUInt(zSql));
    Tcl_ObjSetVar2(interp, objv[4], nil,
      Tcl_NewStringObj(zTail, bytes), 0);
  end;
  if rc <> SQLITE_OK then
  begin
    FillChar(zBuf, SizeOf(zBuf), 0);
    StrPCopy(zBuf, '(' + IntToStr(rc) + ') ');
    Tcl_AppendResult(interp, @zBuf[0], sqlite3_errmsg(db), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if pStmt <> nil then
  begin
    ptrToHex(pStmt, hex);
    FillChar(zBuf, SizeOf(zBuf), 0);
    Move(hex[1], zBuf[0], Length(hex));
    Tcl_AppendResult(interp, @zBuf[0], Pointer(nil));
  end;
  Result := TCL_OK;
end;

{ test1.c:3145..3164 — test_transfer_bind.
  Usage: sqlite3_transfer_bindings FROM-STMT TO-STMT }
function test_transfer_bind(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt1, pStmt2: Pointer;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('FROM-STMT TO-STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt1 := sqlite3TestTextToPtr(Tcl_GetString(objv[1]));
  pStmt2 := sqlite3TestTextToPtr(Tcl_GetString(objv[2]));
  Tcl_SetObjResult(interp,
    Tcl_NewIntObj(sqlite3_transfer_bindings(PVdbe(pStmt1), PVdbe(pStmt2))));
  Result := TCL_OK;
end;

{ ----------------------------------------------------------------------
  test_backup.c — backupTestInit + backupTestCmd.
  Usage: sqlite3_backup CMDNAME DESTHANDLE DESTNAME SRCHANDLE SRCNAME
         CMDNAME step npage | finish | remaining | pagecount
  ---------------------------------------------------------------------- }
procedure backupTestFinish(clientData: TClientData); cdecl;
begin
  sqlite3_backup_finish(PSqlite3Backup(clientData));
end;

function backupTestCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  p:       PSqlite3Backup;
  zSub:    PAnsiChar;
  nPage:   cint;
  rc:      i32;
  info:    TTclCmdInfo;
  zCmdName:PAnsiChar;
begin
  p := PSqlite3Backup(clientData);
  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('option ?arg?'));
    Result := TCL_ERROR; Exit;
  end;
  zSub := Tcl_GetString(objv[1]);
  if StrComp(zSub, 'step') = 0 then
  begin
    if objc <> 3 then
    begin
      Tcl_WrongNumArgs(interp, 2, objv, PChar('npage'));
      Result := TCL_ERROR; Exit;
    end;
    if Tcl_GetIntFromObj(interp, objv[2], @nPage) <> 0 then
    begin
      Result := TCL_ERROR; Exit;
    end;
    rc := sqlite3_backup_step(p, nPage);
    Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  end
  else if StrComp(zSub, 'finish') = 0 then
  begin
    zCmdName := Tcl_GetString(objv[0]);
    if Tcl_GetCommandInfo(interp, zCmdName, @info) <> 0 then
    begin
      info.deleteProc := nil;
      Tcl_SetCommandInfo(interp, zCmdName, @info);
    end;
    Tcl_DeleteCommand(interp, zCmdName);
    rc := sqlite3_backup_finish(p);
    Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  end
  else if StrComp(zSub, 'remaining') = 0 then
    Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_backup_remaining(p)))
  else if StrComp(zSub, 'pagecount') = 0 then
    Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_backup_pagecount(p)))
  else
  begin
    Tcl_AppendResult(interp, PChar('bad option "'), zSub,
      PChar('": must be step, finish, remaining or pagecount'),
      Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

function backupTestInit(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pBackup:   PSqlite3Backup;
  pDestDb:   PTsqlite3;
  pSrcDb:    PTsqlite3;
  zDestName: PAnsiChar;
  zSrcName:  PAnsiChar;
  zCmd:      PAnsiChar;
begin
  if objc <> 6 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('CMDNAME DESTHANDLE DESTNAME SRCHANDLE SRCNAME'));
    Result := TCL_ERROR; Exit;
  end;
  zCmd := Tcl_GetString(objv[1]);
  getDbPointer(interp, Tcl_GetString(objv[2]), @pDestDb);
  zDestName := Tcl_GetString(objv[3]);
  getDbPointer(interp, Tcl_GetString(objv[4]), @pSrcDb);
  zSrcName := Tcl_GetString(objv[5]);
  pBackup := sqlite3_backup_init(pDestDb, zDestName, pSrcDb, zSrcName);
  if pBackup = nil then
  begin
    Tcl_AppendResult(interp, PChar('sqlite3_backup_init() failed'),
      Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Tcl_CreateObjCommand(interp, zCmd, @backupTestCmd, pBackup,
    @backupTestFinish);
  Tcl_SetObjResult(interp, objv[1]);
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
  { 9.4.6.q.1 — prepared-statement / errmsg / exec / transfer / backup. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_exec'),
    @test_exec, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_errmsg'),
    @test_errmsg, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_prepare'),
    @test_prepare, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_prepare_v2'),
    @test_prepare_v2, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_transfer_bindings'),
    @test_transfer_bind, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_backup'),
    @backupTestInit, nil, nil);
  { test1.c:9370..9371 — expose the undocumented sort counter so
    regression tests (between.test's `queryplan` proc, etc.) can
    verify the optimizer correctly elides ORDER BY sorts. }
  Tcl_LinkVar(interp, PChar('sqlite_sort_count'),
    @sqlite3_sort_count, TCL_LINK_INT);
  Result := TCL_OK;
end;

end.
