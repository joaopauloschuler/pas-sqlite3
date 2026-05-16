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
  passqlite3regexp,
  passqlite3stmtrand,
  passqlite3printf,
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

{ test1.c:6191..6325 — fpnum_compare STRING1 STRING2.
  Fuzzy float-string equality used by tester.tcl do_test as a fallback
  when [string compare] fails (tester.tcl:789..792).  Compares two
  whitespace-separated token streams; for floating-point tokens the
  match tolerates up to ~15 significant digits of drift (rounding-up
  on either side, exponent zero-padding "e+9" vs "e+09").  This is the
  mechanism by which fpconv1.test default-3.3 etc. accept either
  17-digit (Grisu / FP_DIGITS=17) or 15-digit (FP_DIGITS=15) renderings
  of the same underlying double — without it our exact-string compare
  diverges from upstream even though the SQLite engine renders
  byte-identically.  Surfaced 9.4.divbug.35. }
function fpnum_compare(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zA, zB: PAnsiChar;
  i, j:   cint;
  nDigit: cint;
  function IsSp(c: AnsiChar): Boolean; inline;
  begin Result := (c = ' ') or (c = #9) or (c = #10) or (c = #11)
                              or (c = #12) or (c = #13);
  end;
  function IsDig(c: AnsiChar): Boolean; inline;
  begin Result := (c >= '0') and (c <= '9'); end;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STRING1 STRING2'));
    Result := TCL_ERROR; Exit;
  end;
  zA := Tcl_GetString(objv[1]);
  zB := Tcl_GetString(objv[2]);
  i := 0; j := 0;
  while True do begin
    while IsSp(zA[i]) do Inc(i);
    while IsSp(zB[j]) do Inc(j);
    if zA[i] <> zB[j] then Break;
    if (zA[i] = '-') and IsDig(zA[i+1]) then begin Inc(i); Inc(j); end;
    if not IsDig(zA[i]) then begin
      while (not IsSp(zA[i])) and (zA[i] <> #0) and (zA[i] = zB[j]) do
      begin Inc(i); Inc(j); end;
      if zA[i] <> zB[j] then Break;
      if IsSp(zA[i]) then Continue;
      Break;
    end;
    nDigit := 0;
    while (zA[i] = zB[j]) and IsDig(zA[i]) do
    begin Inc(i); Inc(j); Inc(nDigit); end;
    if zA[i] <> zB[j] then Break;
    if zA[i] = #0 then Break;
    if (zA[i] = '.') and (zB[j] = '.') then begin
      Inc(i); Inc(j);
      while (zA[i] = zB[j]) and IsDig(zA[i]) do
      begin Inc(i); Inc(j); Inc(nDigit); end;
      if zA[i] = #0 then begin
        while (zB[j] = '0') or (IsDig(zB[j]) and (nDigit >= 15)) do
        begin Inc(j); Inc(nDigit); end;
        Break;
      end;
      if zB[j] = #0 then begin
        while (zA[i] = '0') or (IsDig(zA[i]) and (nDigit >= 15)) do
        begin Inc(i); Inc(nDigit); end;
        Break;
      end;
      if IsSp(zA[i]) and IsSp(zB[j]) then Continue;
      if IsDig(zA[i]) and IsDig(zB[j]) then begin
        if (zA[i] = AnsiChar(Ord(zB[j])+1))
           and (not IsDig(zA[i+1])) and IsDig(zB[j+1]) then begin
          Inc(j);
          while zB[j] = '9' do begin Inc(j); Inc(nDigit); end;
          if (nDigit < 14) and ((not IsDig(zB[j])) or (zB[j] < '5'))
            then Break;
          while IsDig(zB[j]) do Inc(j);
          Inc(i);
        end else if (zB[j] = AnsiChar(Ord(zA[i])+1))
                 and (not IsDig(zB[j+1])) and IsDig(zA[i+1]) then begin
          Inc(i);
          while zA[i] = '9' do begin Inc(i); Inc(nDigit); end;
          if (nDigit < 14) and ((not IsDig(zA[i])) or (zA[i] < '5'))
            then Break;
          while IsDig(zA[i]) do Inc(i);
          Inc(j);
        end else
          Break;
      end else if (not IsDig(zA[i])) and IsDig(zB[j]) then begin
        while zB[j] = '0' do begin Inc(j); Inc(nDigit); end;
        if nDigit < 15 then Break;
        while IsDig(zB[j]) do Inc(j);
      end else if (not IsDig(zB[j])) and IsDig(zA[i]) then begin
        while zA[i] = '0' do begin Inc(i); Inc(nDigit); end;
        if nDigit < 15 then Break;
        while IsDig(zA[i]) do Inc(i);
      end else
        Break;
    end;
    if (zA[i] = 'e') and (zB[j] = 'e') then begin
      Inc(i); Inc(j);
      if ((zA[i] = '+') or (zA[i] = '-')) and (zB[j] = zA[i]) then
      begin Inc(i); Inc(j); end;
      if zA[i] <> zB[j] then begin
        if (zA[i] = '0') and (zA[i+1] = zB[j]) then Inc(i);
        if (zB[j] = '0') and (zB[j+1] = zA[i]) then Inc(j);
      end;
      while (zA[i] = zB[j]) and IsDig(zA[i]) do
      begin Inc(i); Inc(j); end;
      if zA[i] <> zB[j] then Break;
      if zA[i] = #0 then Break;
      Continue;
    end;
    { Fall through: C loops back to the top of `while(1)` to handle the
      next token (e.g. after a plain integer like "-21" the next char is
      whitespace, which the loop head skips before matching the next
      token).  Earlier draft `Break`d here which mishandled multi-token
      inputs whose first token was a non-floating integer. }
    Continue;
  end;
  while IsSp(zA[i]) do Inc(i);
  while IsSp(zB[j]) do Inc(j);
  if (zA[i] = #0) and (zB[j] = #0) then
    Tcl_SetObjResult(interp, Tcl_NewIntObj(1))
  else
    Tcl_SetObjResult(interp, Tcl_NewIntObj(0));
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

{ regexp — already-ported passqlite3regexp unit (ext/misc/regexp.c).
  Wrapped to the C extension-init ABI for load_static_extension.
  Needed by regexp1.test/regexp2.test which load it explicitly.
  9.4.divbug.66. }
function regexp_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3RegexpInit(db);
end;

{ stmtrand — already-ported passqlite3stmtrand unit (ext/misc/stmtrand.c).
  Wrapped to the C extension-init ABI for load_static_extension.
  Needed by stmtrand.test, stmt.test, sqllimits1.test, starschema1.test
  which load it via `load_static_extension db stmtrand` (test_stmt.c:82..97
  registers sqlite3_stmtrand_init the same way for the C build).
  9.4.divbug.67. }
function stmtrand_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3StmtrandInit(db);
end;

function tclLoadStaticExtensionCmd(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
const
  SQLITE_OK_LOAD_PERMANENTLY = 256;  { sqlite3.h — SQLITE_OK | (8<<8) }
var
  aExtension: array[0..3] of TStaticExt;
  db:         PTsqlite3;
  zName:      PAnsiChar;
  i, j, rc:   cint;
  zErrMsg:    PAnsiChar;
begin
  aExtension[0].zExtName := 'ieee754';  aExtension[0].pInit := @ieee754_ext_init;
  aExtension[1].zExtName := 'real2hex'; aExtension[1].pInit := @realhex_ext_init;
  aExtension[2].zExtName := 'regexp';   aExtension[2].pInit := @regexp_ext_init;
  aExtension[3].zExtName := 'stmtrand'; aExtension[3].pInit := @stmtrand_ext_init;
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

{ --------------------------------------------------------------------------
  9.4.6.q.2 — additional test1.c / test_malloc.c Tcl commands.

    * sqlite3_create_aggregate DB     test1.c:1318..1367  (test_create_aggregate)
        Registers `x_count` (0/1-arg) and `legacy_count` aggregate UDFs.
        Step/finalize bodies port test1.c:1270..1315 verbatim — including
        the "value of 40 handed to x_count" UTF-8 step-error and the
        "x_count totals to 42" finalize-error used by aggerror.test.
    * sqlite3_config_pagecache SIZE N test_malloc.c:874..915 (test_config_pagecache)
        Calls sqlite3_config(SQLITE_CONFIG_PAGECACHE, …); returns the
        prior {szPage nPage} pair.  Engine support already in place
        (passqlite3main.pas:2033..2036).
    * sqlite3_initialize              test_config.c — thin wrapper.
    * sqlite3_shutdown                test_config.c — thin wrapper.
  -------------------------------------------------------------------------- }

{ test1.c:1266..1268 — aggregate context for x_count. }
type
  Pt1CountCtx = ^Tt1CountCtx;
  Tt1CountCtx = record
    n: cint;
  end;

{ test1.c:1270..1291 — t1CountStep.  Argless: bump n.  1-arg: bump n
  unless arg is NULL; emit SQLITE_ERROR if v=40 (UTF-8). }
procedure t1CountStep(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  p: Pt1CountCtx;
  v: cint;
begin
  p := Pt1CountCtx(sqlite3_aggregate_context(pCtx, SizeOf(Tt1CountCtx)));
  if ((argc = 0) or (sqlite3_value_type(argv^) <> SQLITE_NULL))
     and (p <> nil) then
    Inc(p^.n);
  if argc > 0 then
  begin
    v := sqlite3_value_int(argv^);
    if v = 40 then
      sqlite3_result_error(pCtx,
        PChar('value of 40 handed to x_count'), -1);
    { v=41 UTF-16 arm omitted — SQLITE_OMIT_UTF16 not exercised here. }
  end;
end;

{ test1.c:1292..1302 — t1CountFinalize.  Emit error on total=42. }
procedure t1CountFinalize(pCtx: Psqlite3_context); cdecl;
var
  p: Pt1CountCtx;
begin
  p := Pt1CountCtx(sqlite3_aggregate_context(pCtx, SizeOf(Tt1CountCtx)));
  if p <> nil then
  begin
    if p^.n = 42 then
      sqlite3_result_error(pCtx, PChar('x_count totals to 42'), -1)
    else
      sqlite3_result_int(pCtx, p^.n);
  end;
end;

{ test1.c:1305..1315 — legacy_count step (no-op) + finalize using
  the deprecated sqlite3_aggregate_count() API. }
procedure legacyCountStep(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
begin
  { no-op — matches test1.c:1310. }
  if (pCtx = nil) or (argc < 0) or (argv = nil) then ;
end;

procedure legacyCountFinalize(pCtx: Psqlite3_context); cdecl;
begin
  sqlite3_result_int(pCtx, sqlite3_aggregate_count(pCtx));
end;

{ test1.c:1337..1367 — test_create_aggregate: register x_count (0/1 arg)
  and legacy_count(0 arg) on DB.  Surfaces the rc symbolic name. }
function test_create_aggregate(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
type
  TArgvArr = array[0..16] of PAnsiChar;
  PArgvArr = ^TArgvArr;
var
  db: PTsqlite3;
  rc: cint;
  av: PArgvArr;
begin
  av := PArgvArr(argv);
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av^[0], PChar(' FILENAME"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av^[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_create_function(db, PChar('x_count'), 0, SQLITE_UTF8, nil,
          nil, @t1CountStep, @t1CountFinalize);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('x_count'), 1, SQLITE_UTF8, nil,
            nil, @t1CountStep, @t1CountFinalize);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('legacy_count'), 0, SQLITE_ANY,
            nil, nil, @legacyCountStep, @legacyCountFinalize);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
end;

{ test_malloc.c:884..915 — sqlite3_config_pagecache SIZE N.
  Sets the page-cache memory buffer.  The "static buf" trick from C is
  preserved via a unit-level var so successive calls do not leak.
  Negative SIZE → buffer=NULL (sets sz=0, cnt=0).  Returns the prior
  {szPage nPage} pair as a list. }
var
  g_PagecacheBuf: Pointer = nil;

function test_config_pagecache(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  sz, N: cint;
  pRes:  PTclObj;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SIZE N'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @sz) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[2], @N) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if g_PagecacheBuf <> nil then
  begin
    FreeMem(g_PagecacheBuf);
    g_PagecacheBuf := nil;
  end;
  { Return prior values BEFORE applying new ones (matches C order). }
  pRes := Tcl_NewObj;
  Tcl_ListObjAppendElement(nil, pRes,
    Tcl_NewIntObj(sqlite3GlobalConfig.szPage));
  Tcl_ListObjAppendElement(nil, pRes,
    Tcl_NewIntObj(sqlite3GlobalConfig.nPage));
  Tcl_SetObjResult(interp, pRes);
  if sz < 0 then
    sqlite3_config(SQLITE_CONFIG_PAGECACHE, Pointer(nil), 0, 0)
  else
  begin
    if (sz > 0) and (N > 0) then
    begin
      GetMem(g_PagecacheBuf, PtrUInt(sz) * PtrUInt(N));
      sqlite3_config(SQLITE_CONFIG_PAGECACHE, g_PagecacheBuf, sz, N);
    end
    else
      sqlite3_config(SQLITE_CONFIG_PAGECACHE, Pointer(nil), sz, N);
  end;
  Result := TCL_OK;
end;

{ test_config.c / tclsqlite.c — thin wrappers around the engine
  lifecycle entry points; used by test_set_config_pagecache. }
function test_initialize(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  sqlite3_initialize;
  Result := TCL_OK;
  if (interp = nil) or (objc < 0) or (objv = nil) then ;
end;

function test_shutdown(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  sqlite3_shutdown;
  Result := TCL_OK;
  if (interp = nil) or (objc < 0) or (objv = nil) then ;
end;

{ ----------------------------------------------------------------------
  9.4.divbug.62.a — test1.c sqlite3_mprintf_* / step / finalize / reset
  and the sqlite3_column_* family.

  Test1.c references (line ranges):
    * sqlite3_mprintf_int           test1.c:1400..1420
    * sqlite3_mprintf_int64         test1.c:1427..1451
    * sqlite3_mprintf_long          test1.c:1460..1484
    * sqlite3_mprintf_str           test1.c:1491..1511
    * sqlite3_mprintf_double        test1.c:1552..1574
    * sqlite3_mprintf_scaled        test1.c:1583..1604
    * sqlite3_mprintf_stronly       test1.c:1613..1629
    * sqlite3_mprintf_hexdouble     test1.c:1637..1663
    * sqlite3_mprintf_z_test        test1.c:495..510   (test_mprintf_z)
    * sqlite3_mprintf_n_test        test1.c:518..530   (test_mprintf_n)
    * sqlite3_step                  test1.c:5579..5600 (test_step)
    * sqlite3_finalize              test1.c:2256..2281 (test_finalize)
    * sqlite3_reset                 test1.c:3086..3117 (test_reset)
    * sqlite3_column_count          test1.c:5664..5682
    * sqlite3_data_count            test1.c:5826..5844
    * sqlite3_column_type           test1.c:5689..5730
    * sqlite3_column_int64          test1.c:5738..5760
    * sqlite3_column_blob           test1.c:5765..5790
    * sqlite3_column_double         test1.c:5797..5819
    * sqlite3_column_text / _name / _decltype /
      _database_name / _table_name / _origin_name
                                    test1.c:5853..5884 (test_stmt_utf8)
    * sqlite3_column_int / _bytes   test1.c:5955..5977 (test_stmt_int)

  Pascal's sqlite3_mprintf entry (passqlite3util.pas:2931) ignores
  varargs; we route the mprintf-Tcl-command bodies through
  sqlite3PfMprintf (passqlite3printf.pas:1499), the Pascal-array-of-
  const flavoured renderer.  Same engine the SQL `printf()` builtin
  uses — handles %d/%x/%o/%X/%s/%g/%e/%f/%p with width/precision flags.
  ---------------------------------------------------------------------- }

{ argv: PPAnsiCharArr  (defined in PasTclBridge as ^PAnsiChar) — index
  via argv[i] for old-style argc/argv handlers. }

{ test1.c:1400..1420 — sqlite3_mprintf_int FORMAT INT INT INT.
  Old-style (string argc/argv) handler. }
function tcl_mprintf_int(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  a: array[0..2] of cint;
  i: cint;
  z: PAnsiChar;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 5 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' FORMAT INT INT INT"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  for i := 2 to 4 do
    if Tcl_GetInt(interp, av[i], @a[i-2]) <> 0 then begin
      Result := TCL_ERROR; Exit;
    end;
  z := sqlite3PfMprintf(av[1], [a[0], a[1], a[2]]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:1427..1451 — sqlite3_mprintf_int64. }
function tcl_mprintf_int64(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  a: array[0..2] of i64;
  i: cint;
  z: PAnsiChar;
  av: PPAnsiCharArr;
  v: Int64;
  code: Integer;
begin
  av := argv;
  if argc <> 5 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' FORMAT INT INT INT"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  for i := 2 to 4 do begin
    Val(AnsiString(av[i]), v, code);
    if code <> 0 then begin
      Tcl_AppendResult(interp,
        PChar('argument is not a valid 64-bit integer'), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    a[i-2] := v;
  end;
  z := sqlite3PfMprintf(av[1], [a[0], a[1], a[2]]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:1460..1484 — sqlite3_mprintf_long.  On LP64 long==int64; the C
  body also masks to int-width.  Port literally. }
function tcl_mprintf_long(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  b: array[0..2] of cint;
  a: array[0..2] of i64;
  i: cint;
  z: PAnsiChar;
  av: PPAnsiCharArr;
  mask: i64;
begin
  av := argv;
  if argc <> 5 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' FORMAT INT INT INT"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  for i := 2 to 4 do
    if Tcl_GetInt(interp, av[i], @b[i-2]) <> 0 then begin
      Result := TCL_ERROR; Exit;
    end;
  mask := (i64(1) shl (SizeOf(cint) * 8)) - 1;
  for i := 0 to 2 do a[i] := i64(b[i]) and mask;
  z := sqlite3PfMprintf(av[1], [a[0], a[1], a[2]]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:1491..1511 — sqlite3_mprintf_str FORMAT INT INT ?STRING?. }
function tcl_mprintf_str(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  a: array[0..1] of cint;
  i: cint;
  z: PAnsiChar;
  zStr: PAnsiChar;
  av: PPAnsiCharArr;
begin
  av := argv;
  if (argc < 4) or (argc > 5) then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' FORMAT INT INT ?STRING?"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  for i := 2 to 3 do
    if Tcl_GetInt(interp, av[i], @a[i-2]) <> 0 then begin
      Result := TCL_ERROR; Exit;
    end;
  if argc > 4 then zStr := av[4] else zStr := nil;
  z := sqlite3PfMprintf(av[1], [a[0], a[1], zStr]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:1552..1574 — sqlite3_mprintf_double FORMAT INT INT DOUBLE. }
function tcl_mprintf_double(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  a: array[0..1] of cint;
  r: Double;
  i: cint;
  z: PAnsiChar;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 5 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' FORMAT INT INT DOUBLE"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  for i := 2 to 3 do
    if Tcl_GetInt(interp, av[i], @a[i-2]) <> 0 then begin
      Result := TCL_ERROR; Exit;
    end;
  if Tcl_GetDouble(interp, av[4], @r) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  z := sqlite3PfMprintf(av[1], [a[0], a[1], r]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:1583..1604 — sqlite3_mprintf_scaled FORMAT DOUBLE DOUBLE. }
function tcl_mprintf_scaled(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  r: array[0..1] of Double;
  i: cint;
  z: PAnsiChar;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 4 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' FORMAT DOUBLE DOUBLE"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  for i := 2 to 3 do
    if Tcl_GetDouble(interp, av[i], @r[i-2]) <> 0 then begin
      Result := TCL_ERROR; Exit;
    end;
  z := sqlite3PfMprintf(av[1], [r[0] * r[1]]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:1613..1629 — sqlite3_mprintf_stronly FORMAT STRING. }
function tcl_mprintf_stronly(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  z: PAnsiChar;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 3 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' FORMAT STRING"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  z := sqlite3PfMprintf(av[1], [av[2]]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:1637..1663 — sqlite3_mprintf_hexdouble FORMAT HEX(16). }
function tcl_mprintf_hexdouble(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  z:   PAnsiChar;
  r:   Double;
  d:   QWord;
  hex: AnsiString;
  i:   cint;
  c:   AnsiChar;
  v:   cint;
  av:  PPAnsiCharArr;
begin
  av := argv;
  if argc <> 3 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' FORMAT STRING"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  hex := AnsiString(av[2]);
  if Length(hex) <> 16 then begin
    Tcl_AppendResult(interp,
      PChar('2nd argument should be 16-characters of hex'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  d := 0;
  for i := 1 to 16 do begin
    c := hex[i];
    case c of
      '0'..'9': v := Ord(c) - Ord('0');
      'a'..'f': v := Ord(c) - Ord('a') + 10;
      'A'..'F': v := Ord(c) - Ord('A') + 10;
    else
      Tcl_AppendResult(interp,
        PChar('2nd argument should be 16-characters of hex'), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    d := (d shl 4) or QWord(v);
  end;
  Move(d, r, SizeOf(r));
  z := sqlite3PfMprintf(av[1], [r]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:495..510 — sqlite3_mprintf_z_test SEPARATOR ARG0 ARG1 ...
  Tests %z by repeated concatenation. }
function tcl_mprintf_z_test(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  zResult: PAnsiChar;
  i:       cint;
  av:      PPAnsiCharArr;
begin
  av := argv;
  zResult := nil;
  i := 2;
  while (i < argc) and ((i = 2) or (zResult <> nil)) do begin
    zResult := sqlite3PfMprintf(PAnsiChar('%z%s%s'),
      [zResult, av[1], av[i]]);
    Inc(i);
  end;
  Tcl_AppendResult(interp, zResult, Pointer(nil));
  sqlite3_free(zResult);
  Result := TCL_OK;
end;

{ test1.c:518..530 — sqlite3_mprintf_n_test STRING. %n returns chars written. }
function tcl_mprintf_n_test(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  zStr: PAnsiChar;
  av:   PPAnsiCharArr;
  n:    cint;
begin
  av := argv;
  n := 0;
  zStr := sqlite3PfMprintf(PAnsiChar('%s%n'), [av[1], @n]);
  sqlite3_free(zStr);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(n));
  Result := TCL_OK;
end;

{ ----------------------------------------------------------------------
  test1.c:5579..5600 / 2256..2281 / 3086..3117 — sqlite3_step / _finalize /
  _reset.  All take a single STMT pointer formatted by test_prepare /
  test_prepare_v2 (a "0xABCD..." hex string).  Decoded via
  sqlite3TestTextToPtr (already in this unit).
  ---------------------------------------------------------------------- }
function tcl_test_step(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  rc:    cint;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  rc := sqlite3_step(pStmt);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
end;

function tcl_test_finalize(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  rc:    cint;
begin
  if objc <> 2 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' <STMT>'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  rc := sqlite3_finalize(pStmt);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
end;

function tcl_test_reset(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  rc:    cint;
begin
  if objc <> 2 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' <STMT>'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  rc := sqlite3_reset(pStmt);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
end;

{ ----------------------------------------------------------------------
  test1.c:5664..5844 + 5853..5977 — sqlite3_column_* family.
  ---------------------------------------------------------------------- }
function tcl_column_count(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_column_count(pStmt)));
  Result := TCL_OK;
end;

function tcl_data_count(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_data_count(pStmt)));
  Result := TCL_OK;
end;

function tcl_column_type(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  col, tp: cint;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT column'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  tp := sqlite3_column_type(pStmt, col);
  case tp of
    SQLITE_INTEGER: Tcl_SetResult(interp, PChar('INTEGER'), TCL_STATIC);
    SQLITE_NULL:    Tcl_SetResult(interp, PChar('NULL'),    TCL_STATIC);
    SQLITE_FLOAT:   Tcl_SetResult(interp, PChar('FLOAT'),   TCL_STATIC);
    SQLITE_TEXT:    Tcl_SetResult(interp, PChar('TEXT'),    TCL_STATIC);
    SQLITE_BLOB:    Tcl_SetResult(interp, PChar('BLOB'),    TCL_STATIC);
  end;
  Result := TCL_OK;
end;

function tcl_column_int(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe; col: cint;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT column'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_column_int(pStmt, col)));
  Result := TCL_OK;
end;

function tcl_column_int64(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe; col: cint;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT column'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  Tcl_SetObjResult(interp,
    Tcl_NewWideIntObj(sqlite3_column_int64(pStmt, col)));
  Result := TCL_OK;
end;

function tcl_column_double(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe; col: cint;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT column'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  Tcl_SetObjResult(interp,
    Tcl_NewDoubleObj(sqlite3_column_double(pStmt, col)));
  Result := TCL_OK;
end;

function tcl_column_bytes(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe; col: cint;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT column'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  Tcl_SetObjResult(interp,
    Tcl_NewIntObj(sqlite3_column_bytes(pStmt, col)));
  Result := TCL_OK;
end;

function tcl_column_blob(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  col, len: cint;
  pBlob: Pointer;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT column'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  len := sqlite3_column_bytes(pStmt, col);
  pBlob := sqlite3_column_blob(pStmt, col);
  Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(pBlob, len));
  Result := TCL_OK;
end;

{ Shared dispatcher for the six "STMT column → PAnsiChar" entrypoints —
  test_stmt_utf8 in test1.c.  clientData is the function pointer. }
type
  Tt1ColTextFn = function(pStmt: PVdbe; i: i32): PAnsiChar; cdecl;

function tcl_stmt_utf8(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  col:   cint;
  zRet:  PAnsiChar;
  fn:    Tt1ColTextFn;
begin
  fn := Tt1ColTextFn(clientData);
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT column'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  zRet := fn(pStmt, col);
  if zRet <> nil then Tcl_SetResult(interp, zRet, Pointer(nil));
  Result := TCL_OK;
end;

{ ----------------------------------------------------------------------
  9.4.divbug.62.b — sqlite3_bind_* family + hexio_* helpers.

  Ported handlers (verbatim from upstream test1.c / test_hexio.c):
    * sqlite3_bind_int             test1.c:3796..3824 (test_bind_int)
    * sqlite3_bind_int64           test1.c:3972..4000 (test_bind_int64)
    * sqlite3_bind_double          test1.c:4010..4077 (test_bind_double)
    * sqlite3_bind_null            test1.c:4086..4112 (test_bind_null)
    * sqlite3_bind_text            test1.c:4122..4165 (test_bind_text)
    * sqlite3_bind_text16          test1.c:4175..4226 (test_bind_text16)
    * sqlite3_bind_blob            test1.c:4235..4281 (test_bind_blob)
    * sqlite3_bind_zeroblob        test1.c:3723..3750 (test_bind_zeroblob)
    * sqlite3_bind_zeroblob64      test1.c:3759..3787 (test_bind_zeroblob64)
    * sqlite3_bind_value_from_select
                                   test1.c:4338..4379
    * sqlite3_bind_parameter_count test1.c:4736..4751
    * sqlite3_bind_parameter_name  test1.c:4760..4779
    * sqlite3_bind_parameter_index test1.c:4787..4806
    * sqlite3_clear_bindings       test1.c:4812..4827
    * hexio_read                   test_hexio.c:97..138
    * hexio_write                  test_hexio.c:147..187
    * hexio_get_int                test_hexio.c:196..241
    * hexio_render_int16           test_hexio.c:249..268
    * hexio_render_int32           test_hexio.c:276..297

  Stmt pointers arrive as "0xABCD..." strings (sqlite3TestTextToPtr)
  matching the convention already used by the column_* / step / finalize
  cluster. test1.c's getStmtPointer additionally accepts a Tcl-command
  name, but no affected test (tkt2213, vacuum*, upsert5, values,
  rowvalue7) relies on that path.
  ---------------------------------------------------------------------- }

{ test_hexio.c:32..44 — sqlite3TestBinToHex. }
procedure t1BinToHex(zBuf: PByte; N: cint);
const
  zHex: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  i, j: cint;
  c: Byte;
begin
  i := N * 2;
  (zBuf + i)^ := 0;
  Dec(i);
  for j := N - 1 downto 0 do
  begin
    c := (zBuf + j)^;
    (zBuf + i)^ := Byte(zHex[c and $f]); Dec(i);
    (zBuf + i)^ := Byte(zHex[c shr 4]);  Dec(i);
  end;
end;

{ test_hexio.c:52..87 — sqlite3TestHexToBin. }
function t1HexToBin(zIn: PByte; N: cint; aOut: PByte): cint;
const
  aMap: array[0..255] of Byte = (
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     1, 2, 3, 4, 5, 6, 7, 8,  9,10, 0, 0, 0, 0, 0, 0,
     0,11,12,13,14,15,16, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0,11,12,13,14,15,16, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0);
var
  i, j: cint;
  hi: cint;
  c: Byte;
begin
  hi := 1; j := 0;
  for i := 0 to N - 1 do
  begin
    c := aMap[(zIn + i)^];
    if c = 0 then continue;
    if hi <> 0 then
    begin
      (aOut + j)^ := (c - 1) shl 4;
      hi := 0;
    end else begin
      (aOut + j)^ := (aOut + j)^ or (c - 1);
      Inc(j);
      hi := 1;
    end;
  end;
  Result := j;
end;

{ test1.c:3796..3824 — sqlite3_bind_int. }
function tcl_bind_int(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  idx, value, rc: cint;
begin
  if objc <> 4 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT N VALUE'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[3], @value) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_bind_int(pStmt, idx, value);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:3972..4000 — sqlite3_bind_int64. }
function tcl_bind_int64(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  idx, rc: cint;
  value: Int64;
begin
  if objc <> 4 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT N VALUE'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetWideIntFromObj(interp, objv[3], @value) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_bind_int64(pStmt, idx, value);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:4010..4077 — sqlite3_bind_double, with "NaN"/"+Inf" sentinels. }
function tcl_bind_double(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
type
  TSpecialFp = record
    zName: PAnsiChar;
    iUpper, iLower: cuint;
  end;
const
  aSpecialFp: array[0..9] of TSpecialFp = (
    (zName: 'NaN';      iUpper: $7fffffff; iLower: $ffffffff),
    (zName: 'SNaN';     iUpper: $7ff7ffff; iLower: $ffffffff),
    (zName: '-NaN';     iUpper: $ffffffff; iLower: $ffffffff),
    (zName: '-SNaN';    iUpper: $fff7ffff; iLower: $ffffffff),
    (zName: '+Inf';     iUpper: $7ff00000; iLower: $00000000),
    (zName: '-Inf';     iUpper: $fff00000; iLower: $00000000),
    (zName: 'Epsilon';  iUpper: $00000000; iLower: $00000001),
    (zName: '-Epsilon'; iUpper: $80000000; iLower: $00000001),
    (zName: 'NaN0';     iUpper: $7ff80000; iLower: $00000000),
    (zName: '-NaN0';    iUpper: $fff80000; iLower: $00000000));
var
  pStmt: PVdbe;
  idx, rc, i: cint;
  value: Double;
  zVal: PAnsiChar;
  x: QWord;
  matched: Boolean;
begin
  if objc <> 4 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT N VALUE'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  zVal := Tcl_GetString(objv[3]);
  value := 0; matched := False;
  for i := 0 to High(aSpecialFp) do
  begin
    if StrComp(aSpecialFp[i].zName, zVal) = 0 then
    begin
      x := QWord(aSpecialFp[i].iUpper);
      x := x shl 32;
      x := x or QWord(aSpecialFp[i].iLower);
      Move(x, value, 8);
      matched := True;
      break;
    end;
  end;
  if (not matched) and (Tcl_GetDoubleFromObj(interp, objv[3], @value) <> 0) then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_bind_double(pStmt, idx, value);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:4086..4112 — sqlite3_bind_null. }
function tcl_bind_null(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  idx, rc: cint;
begin
  if objc <> 3 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT N'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_bind_null(pStmt, idx);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:4122..4165 — sqlite3_bind_text. }
function tcl_bind_text(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  idx, bytes, rc: cint;
  trueLength: cint;
  value, toFree: PAnsiChar;
begin
  if objc <> 5 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT N VALUE BYTES'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  trueLength := 0;
  value := Tcl_GetByteArrayFromObj(objv[3], @trueLength);
  if Tcl_GetIntFromObj(interp, objv[4], @bytes) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  toFree := nil;
  if bytes < 0 then
  begin
    GetMem(toFree, trueLength + 1);
    if toFree = nil then begin
      Tcl_AppendResult(interp, PChar('out of memory'), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    Move(value^, toFree^, trueLength);
    (toFree + trueLength)^ := #0;
    value := toFree;
  end;
  rc := sqlite3_bind_text(pStmt, idx, value, bytes, SQLITE_TRANSIENT);
  if toFree <> nil then FreeMem(toFree);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:4175..4226 — sqlite3_bind_text16 ?-static? STMT N STRING BYTES. }
function tcl_bind_text16(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  idx, bytes, rc: cint;
  trueLength: cint;
  value, toFree: PAnsiChar;
  xDel: TxDelProc;
  oStmt, oN, oString, oBytes: PTclObj;
begin
  if (objc <> 5) and (objc <> 6) then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT N VALUE BYTES'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if objc = 6 then xDel := SQLITE_STATIC else xDel := SQLITE_TRANSIENT;
  oStmt   := objv[objc - 4];
  oN      := objv[objc - 3];
  oString := objv[objc - 2];
  oBytes  := objv[objc - 1];
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(oStmt)));
  if Tcl_GetIntFromObj(interp, oN, @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  trueLength := 0;
  value := Tcl_GetByteArrayFromObj(oString, @trueLength);
  if Tcl_GetIntFromObj(interp, oBytes, @bytes) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  toFree := nil;
  if (bytes < 0) and (xDel = SQLITE_TRANSIENT) then
  begin
    GetMem(toFree, trueLength + 3);
    if toFree = nil then begin
      Tcl_AppendResult(interp, PChar('out of memory'), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    Move(value^, toFree^, trueLength);
    FillChar((toFree + trueLength)^, 3, 0);
    value := toFree;
  end;
  rc := sqlite3_bind_text16(pStmt, idx, Pointer(value), bytes, xDel);
  if toFree <> nil then FreeMem(toFree);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:4235..4281 — sqlite3_bind_blob ?-static? STMT N DATA BYTES. }
function tcl_bind_blob(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  idx, bytes, rc: cint;
  len: cint;
  value: PAnsiChar;
  xDel: TxDelProc;
  ofs: cint;
  zBuf: array[0..199] of AnsiChar;
begin
  if (objc <> 5) and (objc <> 6) then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT N DATA BYTES'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  xDel := SQLITE_TRANSIENT; ofs := 0;
  if objc = 6 then begin
    xDel := SQLITE_STATIC;
    ofs := 1;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1 + ofs])));
  if Tcl_GetIntFromObj(interp, objv[2 + ofs], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  len := 0;
  value := Tcl_GetByteArrayFromObj(objv[3 + ofs], @len);
  if Tcl_GetIntFromObj(interp, objv[4 + ofs], @bytes) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if bytes > len then begin
    FillChar(zBuf, SizeOf(zBuf), 0);
    StrPCopy(zBuf, 'cannot use ' + IntToStr(bytes) + ' blob bytes, have '
             + IntToStr(len));
    Tcl_AppendResult(interp, @zBuf[0], Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_bind_blob(pStmt, idx, value, bytes, xDel);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:3723..3750 — sqlite3_bind_zeroblob STMT IDX N. }
function tcl_bind_zeroblob(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  idx, n, rc: cint;
begin
  if objc <> 4 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT IDX N'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[3], @n) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_bind_zeroblob(pStmt, idx, n);
  if rc <> SQLITE_OK then begin
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:3759..3787 — sqlite3_bind_zeroblob64 STMT IDX N. }
function tcl_bind_zeroblob64(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  idx, rc: cint;
  n: Int64;
begin
  if objc <> 4 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT IDX N'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetWideIntFromObj(interp, objv[3], @n) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_bind_zeroblob64(pStmt, idx, u64(n));
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:4338..4379 — sqlite3_bind_value_from_select STMT N SELECT. }
function tcl_bind_value_from_select(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt, pStmt2: PVdbe;
  idx, rc: cint;
  zSql: PAnsiChar;
  db: PTsqlite3;
  pVal: Psqlite3_value;
begin
  if objc <> 4 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT N SELECT'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  zSql := Tcl_GetString(objv[3]);
  db := sqlite3_db_handle(pStmt);
  rc := sqlite3_prepare_v2(db, zSql, -1, @pStmt2, nil);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, PChar('error in SQL: '),
      sqlite3_errmsg(db), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if sqlite3_step(pStmt2) = SQLITE_ROW then
  begin
    pVal := sqlite3_column_value(pStmt2, 0);
    sqlite3_bind_value(pStmt, idx, pVal);
  end;
  rc := sqlite3_finalize(pStmt2);
  if rc <> SQLITE_OK then begin
    Tcl_AppendResult(interp, PChar('error runnning SQL: '),
      sqlite3_errmsg(db), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:4736..4751 — sqlite3_bind_parameter_count STMT. }
function tcl_bind_parameter_count(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp,
    Tcl_NewIntObj(sqlite3_bind_parameter_count(pStmt)));
  Result := TCL_OK;
end;

{ test1.c:4760..4779 — sqlite3_bind_parameter_name STMT N. }
function tcl_bind_parameter_name(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  i: cint;
  z: PAnsiChar;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT N'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @i) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  z := sqlite3_bind_parameter_name(pStmt, i);
  Tcl_SetObjResult(interp, Tcl_NewStringObj(z, -1));
  Result := TCL_OK;
end;

{ test1.c:4787..4806 — sqlite3_bind_parameter_index STMT NAME. }
function tcl_bind_parameter_index(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT NAME'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp,
    Tcl_NewIntObj(sqlite3_bind_parameter_index(pStmt,
      Tcl_GetString(objv[2]))));
  Result := TCL_OK;
end;

{ test1.c:4812..4827 — sqlite3_clear_bindings STMT. }
function tcl_clear_bindings(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStmt: PVdbe;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp,
    Tcl_NewIntObj(sqlite3_clear_bindings(pStmt)));
  Result := TCL_OK;
end;

{ test_hexio.c:97..138 — hexio_read FILENAME OFFSET AMT. }
function tcl_hexio_read(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  offset, amt, got: cint;
  zFile: PAnsiChar;
  zBuf: PByte;
  inF: PFile;
begin
  if objc <> 4 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('FILENAME OFFSET AMT'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[2], @offset) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[3], @amt) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  zFile := Tcl_GetString(objv[1]);
  zBuf := PByte(sqlite3_malloc(amt * 2 + 1));
  if zBuf = nil then begin Result := TCL_ERROR; Exit; end;
  inF := fopen(zFile, PChar('rb'));
  if inF = nil then inF := fopen(zFile, PChar('r'));
  if inF = nil then begin
    Tcl_AppendResult(interp, PChar('cannot open input file '),
      zFile, Pointer(nil));
    sqlite3_free(zBuf);
    Result := TCL_ERROR; Exit;
  end;
  fseek(inF, offset, SEEK_SET);
  got := fread(zBuf, 1, amt, inF);
  fclose(inF);
  if got < 0 then got := 0;
  t1BinToHex(zBuf, got);
  Tcl_AppendResult(interp, PAnsiChar(zBuf), Pointer(nil));
  sqlite3_free(zBuf);
  Result := TCL_OK;
end;

{ test_hexio.c:147..187 — hexio_write FILENAME OFFSET HEXDATA. }
function tcl_hexio_write(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  offset, nIn, nOut, written: cint;
  zFile: PAnsiChar;
  zIn: PAnsiChar;
  aOut: PByte;
  outF: PFile;
begin
  if objc <> 4 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('FILENAME OFFSET HEXDATA'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[2], @offset) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  zFile := Tcl_GetString(objv[1]);
  nIn := 0;
  zIn := Tcl_GetStringFromObj(objv[3], @nIn);
  aOut := PByte(sqlite3_malloc(1 + nIn div 2));
  if aOut = nil then begin Result := TCL_ERROR; Exit; end;
  nOut := t1HexToBin(PByte(zIn), nIn, aOut);
  outF := fopen(zFile, PChar('r+b'));
  if outF = nil then outF := fopen(zFile, PChar('r+'));
  if outF = nil then begin
    Tcl_AppendResult(interp, PChar('cannot open output file '),
      zFile, Pointer(nil));
    sqlite3_free(aOut);
    Result := TCL_ERROR; Exit;
  end;
  fseek(outF, offset, SEEK_SET);
  written := fwrite(aOut, 1, nOut, outF);
  sqlite3_free(aOut);
  fclose(outF);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(written));
  Result := TCL_OK;
end;

{ test_hexio.c:196..241 — hexio_get_int [-littleendian] HEXDATA. }
function tcl_hexio_get_int(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  val, nIn, nOut: cint;
  zIn, z: PAnsiChar;
  aOut: PByte;
  aNum: array[0..3] of Byte;
  bLittle: cint;
  n: cint;
begin
  bLittle := 0;
  if objc = 3 then
  begin
    n := 0;
    z := Tcl_GetStringFromObj(objv[1], @n);
    if (n >= 2) and (n <= 13) and (CompareByte(z^, PAnsiChar('-littleendian')^, n) = 0) then
      bLittle := 1;
  end;
  if (objc - bLittle) <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('[-littleendian] HEXDATA'));
    Result := TCL_ERROR; Exit;
  end;
  nIn := 0;
  zIn := Tcl_GetStringFromObj(objv[1 + bLittle], @nIn);
  aOut := PByte(sqlite3_malloc(1 + nIn div 2));
  if aOut = nil then begin Result := TCL_ERROR; Exit; end;
  nOut := t1HexToBin(PByte(zIn), nIn, aOut);
  if nOut >= 4 then
    Move(aOut^, aNum[0], 4)
  else begin
    FillChar(aNum, SizeOf(aNum), 0);
    Move(aOut^, aNum[4 - nOut], nOut);
  end;
  sqlite3_free(aOut);
  if bLittle <> 0 then
    val := cint((cuint(aNum[3]) shl 24) or (cuint(aNum[2]) shl 16)
                or (cuint(aNum[1]) shl 8) or cuint(aNum[0]))
  else
    val := cint((cuint(aNum[0]) shl 24) or (cuint(aNum[1]) shl 16)
                or (cuint(aNum[2]) shl 8) or cuint(aNum[3]));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(val));
  Result := TCL_OK;
end;

{ test_hexio.c:249..268 — hexio_render_int16 INTEGER. }
function tcl_hexio_render_int16(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  val: cint;
  aNum: array[0..9] of Byte;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('INTEGER'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @val) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  aNum[0] := Byte(val shr 8);
  aNum[1] := Byte(val);
  t1BinToHex(@aNum[0], 2);
  Tcl_SetObjResult(interp, Tcl_NewStringObj(PAnsiChar(@aNum[0]), 4));
  Result := TCL_OK;
end;

{ test_hexio.c:276..297 — hexio_render_int32 INTEGER. }
function tcl_hexio_render_int32(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  val: cint;
  aNum: array[0..9] of Byte;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('INTEGER'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @val) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  aNum[0] := Byte(val shr 24);
  aNum[1] := Byte(val shr 16);
  aNum[2] := Byte(val shr 8);
  aNum[3] := Byte(val);
  t1BinToHex(@aNum[0], 4);
  Tcl_SetObjResult(interp, Tcl_NewStringObj(PAnsiChar(@aNum[0]), 8));
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
  { 9.4.divbug.35 — fpnum_compare for fuzzy float-string equality
    fallback used by tester.tcl do_test (tester.tcl:789..792). }
  Tcl_CreateObjCommand(interp, PChar('fpnum_compare'),
    @fpnum_compare, nil, nil);
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
  { 9.4.6.q.2 — aggregate UDF registration + pagecache config + lifecycle.
    test1.c:9082 / test_malloc.c:1487. }
  Tcl_CreateCommand(interp, PChar('sqlite3_create_aggregate'),
    @test_create_aggregate, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config_pagecache'),
    @test_config_pagecache, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_initialize'),
    @test_initialize, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_shutdown'),
    @test_shutdown, nil, nil);
  { 9.4.divbug.62.a — sqlite3_mprintf_* / step / finalize / reset /
    column_*.  Old-style argc/argv handlers for the mprintf cluster
    (test1.c:9059..9069) — Tcl_CreateCommand for those, objCommand
    for the rest. }
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_int'),
    @tcl_mprintf_int, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_int64'),
    @tcl_mprintf_int64, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_long'),
    @tcl_mprintf_long, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_str'),
    @tcl_mprintf_str, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_double'),
    @tcl_mprintf_double, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_scaled'),
    @tcl_mprintf_scaled, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_stronly'),
    @tcl_mprintf_stronly, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_hexdouble'),
    @tcl_mprintf_hexdouble, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_z_test'),
    @tcl_mprintf_z_test, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_mprintf_n_test'),
    @tcl_mprintf_n_test, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_step'),
    @tcl_test_step, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_finalize'),
    @tcl_test_finalize, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_reset'),
    @tcl_test_reset, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_count'),
    @tcl_column_count, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_data_count'),
    @tcl_data_count, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_type'),
    @tcl_column_type, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_int'),
    @tcl_column_int, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_int64'),
    @tcl_column_int64, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_double'),
    @tcl_column_double, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_bytes'),
    @tcl_column_bytes, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_blob'),
    @tcl_column_blob, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_text'),
    @tcl_stmt_utf8, Pointer(@sqlite3_column_text), nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_name'),
    @tcl_stmt_utf8, Pointer(@sqlite3_column_name), nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_decltype'),
    @tcl_stmt_utf8, Pointer(@sqlite3_column_decltype), nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_database_name'),
    @tcl_stmt_utf8, Pointer(@sqlite3_column_database_name), nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_table_name'),
    @tcl_stmt_utf8, Pointer(@sqlite3_column_table_name), nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_origin_name'),
    @tcl_stmt_utf8, Pointer(@sqlite3_column_origin_name), nil);
  { 9.4.divbug.62.b — sqlite3_bind_* family + hexio_* helpers
    (test1.c:9114..9132, test_hexio.c:461..465). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_int'),
    @tcl_bind_int, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_int64'),
    @tcl_bind_int64, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_double'),
    @tcl_bind_double, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_null'),
    @tcl_bind_null, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_text'),
    @tcl_bind_text, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_text16'),
    @tcl_bind_text16, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_blob'),
    @tcl_bind_blob, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_zeroblob'),
    @tcl_bind_zeroblob, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_zeroblob64'),
    @tcl_bind_zeroblob64, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_value_from_select'),
    @tcl_bind_value_from_select, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_parameter_count'),
    @tcl_bind_parameter_count, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_parameter_name'),
    @tcl_bind_parameter_name, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_bind_parameter_index'),
    @tcl_bind_parameter_index, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_clear_bindings'),
    @tcl_clear_bindings, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('hexio_read'),
    @tcl_hexio_read, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('hexio_write'),
    @tcl_hexio_write, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('hexio_get_int'),
    @tcl_hexio_get_int, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('hexio_render_int16'),
    @tcl_hexio_render_int16, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('hexio_render_int32'),
    @tcl_hexio_render_int32, nil, nil);
  { test1.c:9370..9371 — expose the undocumented sort counter so
    regression tests (between.test's `queryplan` proc, etc.) can
    verify the optimizer correctly elides ORDER BY sorts. }
  Tcl_LinkVar(interp, PChar('sqlite_sort_count'),
    @sqlite3_sort_count, TCL_LINK_INT);
  Result := TCL_OK;
end;

end.
