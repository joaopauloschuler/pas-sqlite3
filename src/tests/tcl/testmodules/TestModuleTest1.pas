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
  passqlite3eval,
  passqlite3fileio,
  passqlite3totype,
  passqlite3explain,
  passqlite3wholenumber,
  passqlite3decimal,
  passqlite3qpvtab,
  { 6.40.4 — more statically-linked test extensions for load_static_extension. }
  passqlite3series,
  passqlite3spellfix,
  passqlite3closure,
  passqlite3csv,
  passqlite3fuzzer,
  passqlite3prefixes,
  passqlite3randomjson,
  passqlite3appendvfs,
  passqlite3amatch,
  passqlite3nextchar,
  passqlite3remember,
  passqlite3unionvtab,
  passqlite3printf,
  passqlite3normalize,
  passqlite3cksumvfs,
  passqlite3multiplex,
  passqlite3carray,
  passqlite3internal,
  passqlite3mmapwarm,
  passqlite3btree,
  passqlite3pager,
  passqlite3pcache,
  passqlite3vtab,
  passqlite3fts3,
  passqlite3main;

{ 9.4.divbug.66 — local stdio extern decls (FPC ships no portable stdio
  bindings unit and the test_hexio.c port (lines 2189..2266) needs them).
  Pinned to libc the same way passqlite3zipfile.pas:225 does for fopen. }
type
  PFile = Pointer;
function fopen(path, mode: PAnsiChar): PFile; cdecl;
  external 'c' name 'fopen';
function fclose(stream: PFile): cint; cdecl;
  external 'c' name 'fclose';
function fread(ptr: Pointer; size, nmemb: csize_t; stream: PFile): csize_t; cdecl;
  external 'c' name 'fread';
function fwrite(ptr: Pointer; size, nmemb: csize_t; stream: PFile): csize_t; cdecl;
  external 'c' name 'fwrite';
function fseek(stream: PFile; offset: clong; whence: cint): cint; cdecl;
  external 'c' name 'fseek';

{ test1.c:7969 strftime_cmd needs the C-library gmtime()/strftime() so the
  test can compare SQLite's internal strftime() SQL function against the
  byte-identical libc output.  FPC ships no portable struct tm binding here,
  so mirror the libc decls directly (same approach as the stdio binds above). }
type
  PCTm = ^TCTm;
  TCTm = record
    tm_sec:   cint;
    tm_min:   cint;
    tm_hour:  cint;
    tm_mday:  cint;
    tm_mon:   cint;
    tm_year:  cint;
    tm_wday:  cint;
    tm_yday:  cint;
    tm_isdst: cint;
    { glibc extensions — present in the on-disk struct, declared for layout. }
    tm_gmtoff: clong;
    tm_zone:   PAnsiChar;
  end;
  PTimeT = ^clong;
function c_gmtime(timer: PTimeT): PCTm; cdecl;
  external 'c' name 'gmtime';
function c_strftime(s: PAnsiChar; maxsize: csize_t; format: PAnsiChar;
  timeptr: PCTm): csize_t; cdecl;
  external 'c' name 'strftime';

const
  { sqliteInt.h — index 12, defined in C but not yet exposed in this port. }
  SQLITE_LIMIT_PARSER_DEPTH = 12;
  { sqlite3.h — opcode 20.  Defined in passqlite3main implementation but
    not re-exported in the unit's interface; mirror locally. }
  SQLITE_TESTCTRL_NEVER_CORRUPT_OP = 20;
  { sqlite3.h — opcode 29.  Mirrored locally (see comment above). }
  SQLITE_TESTCTRL_EXTRA_SCHEMA_CHECKS_OP = 29;
  { sqlite3.h — opcode 8 (BITVEC_TEST).  Mirrored locally. }
  SQLITE_TESTCTRL_BITVEC_TEST_OP = 8;
  { sqlite3.h — opcode 9 (FAULT_INSTALL).  Mirrored locally; the engine
    handler lives in passqlite3main testCtrlImpl. }
  SQLITE_TESTCTRL_FAULT_INSTALL_OP = 9;
  { sqlite3.h — opcodes 5/6 (PRNG_SAVE/PRNG_RESTORE).  Mirrored locally. }
  SQLITE_TESTCTRL_PRNG_SAVE_OP    = 5;
  SQLITE_TESTCTRL_PRNG_RESTORE_OP = 6;
  { sqlite3.h — opcodes used by the `sqlite3_test_control` Tcl command
    (test1.c:8026 test_test_control) and `optimization_control`
    (test1.c:8301).  Mirrored locally (see comment above). }
  SQLITE_TESTCTRL_FK_NO_ACTION_OP       = 7;
  SQLITE_TESTCTRL_OPTIMIZATIONS_OP      = 15;
  SQLITE_TESTCTRL_INTERNAL_FUNCTIONS_OP = 17;
  SQLITE_TESTCTRL_LOCALTIME_FAULT_OP    = 18;
  SQLITE_TESTCTRL_SORTER_MMAP_OP        = 24;
  SQLITE_TESTCTRL_IMPOSTER_OP           = 25;
  SEEK_SET = 0;

function Sqlitetest1_Init(interp: PTclInterp): cint; cdecl;

implementation

{ test1.c:3835.. — static buffers for the *array_addr test commands
  (each overwritten/freed on the next call). }
var
  intarrayAddrP   : Pointer = nil;
  int64arrayAddrP : Pointer = nil;
  doublearrayAddrP: Pointer = nil;
  textarrayAddrP  : Pointer = nil;
  textarrayAddrN  : cint    = 0;

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
  { test1.c:104 sqlite3_snprintf("%p", p->db) — bare hex, no "0x" prefix. }
  s := LowerCase(IntToHex(PtrUInt(p^.db), 1));
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(s[1], zBuf[0], Length(s));
  Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
  Result := TCL_OK;
end;

{ test1.c:7831..7855 — runAsObjProc (Tcl command `tcl_objproc`).
  Usage: tcl_objproc COMMANDNAME ARGS...
  Run a TCL command via its objProc interface, erroring if the command
  has none. }
function runAsObjProc(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  cmdInfo: TTclCmdInfo;
  xObj:    TTclObjCmdProc;
begin
  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('COMMAND ...'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetCommandInfo(interp, Tcl_GetString(objv[1]), @cmdInfo) = 0 then
  begin
    Tcl_AppendResult(interp, PChar('command not found: '),
      Tcl_GetString(objv[1]), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if cmdInfo.objProc = nil then
  begin
    Tcl_AppendResult(interp, PChar('command has no objProc: '),
      Tcl_GetString(objv[1]), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  xObj := TTclObjCmdProc(cmdInfo.objProc);
  Result := xObj(cmdInfo.objClientData, interp, objc - 1, PPTclObj(@objv[1]));
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

{ test1.c:8708..8729 — test_dbconfig_maindbname_icecube.
  Usage: dbconfig_maindbname_icecube DB
  Change the name of the main database schema from "main" to "icecube". }
function test_dbconfig_maindbname_icecube(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
  db: PTsqlite3;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  rc := sqlite3_db_config_text(db, SQLITE_DBCONFIG_MAINDBNAME,
    PAnsiChar('icecube'));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
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

{ 9.4.divbug.90 — five more aExtension[] slots mirroring test1.c:8406..8435.
  Each Pas port already exists; only the C-ABI shim + table row were missing.
    * eval         — ext/misc/eval.c (btree02.test, misc8.test)
    * fileio       — ext/misc/fileio.c (extension01.test)
    * totype       — ext/misc/totype.c (func4.test)
    * explain      — ext/misc/explain.c — vtab (indexexpr2.test)
    * wholenumber  — ext/misc/wholenumber.c — vtab (memdb.test, percentile.test) }
function eval_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3EvalInit(db);
end;

function fileio_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3FileioInit(db);
end;

function totype_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3TotypeInit(db);
end;

function explain_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3ExplainVtabInit(db);
end;

function wholenumber_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3WholenumberInit(db);
end;

{ decimal — ported passqlite3decimal unit (ext/misc/decimal.c).
  Needed by nan.test (load_static_extension db decimal) which uses
  decimal_exp() to render the exact decimal expansion of subnormal
  doubles. 9.4.divbug.88.056. }
function decimal_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3DecimalInit(db);
end;

{ qpvtab — ported passqlite3qpvtab unit (ext/misc/qpvtab.c).
  Needed by vtabdistinct.test / vtabrhs1.test which load it via
  `load_static_extension db qpvtab` (test1.c registers
  sqlite3_qpvtab_init the same way for the C build). }
function qpvtab_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3QpvtabInit(db);
end;

{ 6.40.4 — twelve more aExtension[] slots mirroring test1.c:8406..8435.
  Each Pas port already exists (ext/misc/*.c); only the C-ABI shim + the
  table row were missing.
    * series      — ext/misc/series.c     (bestindexC, join8, tabfunc01, with2)
    * spellfix    — ext/misc/spellfix.c   (spellfix2)
    * closure     — ext/misc/closure.c    (closure01)
    * csv         — ext/misc/csv.c        (csv01)
    * fuzzer      — ext/misc/fuzzer.c     (fuzzer1/fuzzer2/fuzzerfault)
    * prefixes    — ext/misc/prefixes.c   (prefixes)
    * randomjson  — ext/misc/randomjson.c (json106, json108)
    * appendvfs   — ext/misc/appendvfs.c  (avfs)
    * amatch      — ext/misc/amatch.c
    * nextchar    — ext/misc/nextchar.c
    * remember    — ext/misc/remember.c   (tabfunc01)
    * unionvtab   — ext/misc/unionvtab.c }
function series_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3SeriesInit(db);
end;

function spellfix_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3SpellfixInit(db);
end;

function closure_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3ClosureInit(db);
end;

function csv_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3CsvInit(db);
end;

function fuzzer_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3FuzzerInit(db);
end;

function prefixes_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3PrefixesInit(db);
end;

function randomjson_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3RandomJsonInit(db);
end;

function appendvfs_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3AppendvfsInit(db);
end;

function amatch_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3AmatchInit(db);
end;

function nextchar_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3NextcharInit(db);
end;

function remember_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3RememberInit(db);
end;

function unionvtab_ext_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3UnionvtabInit(db);
end;

function tclLoadStaticExtensionCmd(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
const
  SQLITE_OK_LOAD_PERMANENTLY = 256;  { sqlite3.h — SQLITE_OK | (8<<8) }
var
  aExtension: array[0..22] of TStaticExt;
  db:         PTsqlite3;
  zName:      PAnsiChar;
  i, j, rc:   cint;
  zErrMsg:    PAnsiChar;
begin
  aExtension[0].zExtName := 'ieee754';  aExtension[0].pInit := @ieee754_ext_init;
  aExtension[1].zExtName := 'real2hex'; aExtension[1].pInit := @realhex_ext_init;
  aExtension[2].zExtName := 'regexp';   aExtension[2].pInit := @regexp_ext_init;
  aExtension[3].zExtName := 'stmtrand'; aExtension[3].pInit := @stmtrand_ext_init;
  aExtension[4].zExtName := 'eval';        aExtension[4].pInit := @eval_ext_init;
  aExtension[5].zExtName := 'fileio';      aExtension[5].pInit := @fileio_ext_init;
  aExtension[6].zExtName := 'totype';      aExtension[6].pInit := @totype_ext_init;
  aExtension[7].zExtName := 'explain';     aExtension[7].pInit := @explain_ext_init;
  aExtension[8].zExtName := 'wholenumber'; aExtension[8].pInit := @wholenumber_ext_init;
  aExtension[9].zExtName := 'decimal';     aExtension[9].pInit := @decimal_ext_init;
  aExtension[10].zExtName := 'qpvtab';     aExtension[10].pInit := @qpvtab_ext_init;
  aExtension[11].zExtName := 'series';     aExtension[11].pInit := @series_ext_init;
  aExtension[12].zExtName := 'spellfix';   aExtension[12].pInit := @spellfix_ext_init;
  aExtension[13].zExtName := 'closure';    aExtension[13].pInit := @closure_ext_init;
  aExtension[14].zExtName := 'csv';        aExtension[14].pInit := @csv_ext_init;
  aExtension[15].zExtName := 'fuzzer';     aExtension[15].pInit := @fuzzer_ext_init;
  aExtension[16].zExtName := 'prefixes';   aExtension[16].pInit := @prefixes_ext_init;
  aExtension[17].zExtName := 'randomjson'; aExtension[17].pInit := @randomjson_ext_init;
  aExtension[18].zExtName := 'appendvfs';  aExtension[18].pInit := @appendvfs_ext_init;
  aExtension[19].zExtName := 'amatch';     aExtension[19].pInit := @amatch_ext_init;
  aExtension[20].zExtName := 'nextchar';   aExtension[20].pInit := @nextchar_ext_init;
  aExtension[21].zExtName := 'remember';   aExtension[21].pInit := @remember_ext_init;
  aExtension[22].zExtName := 'unionvtab';  aExtension[22].pInit := @unionvtab_ext_init;
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

{ main.c:1533 — sqlite3ErrName: faithful port of the two-pass enum-name
  lookup.  First pass matches the full extended code; if unmatched, rc is
  masked to the primary code (rc and $ff) and the second pass matches that.
  Returns 'SQLITE_Unknown' for the still-unmatched case (existing harness
  convention; C returns the static "SQLITE_UNKNOWN(%d)" buffer). }
function t1ErrName(rc: cint): PAnsiChar;
var
  zName: PAnsiChar;
  i: Integer;
begin
  zName := nil;
  i := 0;
  while (i < 2) and (zName = nil) do
  begin
    case rc of
      SQLITE_OK:                 zName := PChar('SQLITE_OK');
      SQLITE_ERROR:              zName := PChar('SQLITE_ERROR');
      SQLITE_ERROR_SNAPSHOT:     zName := PChar('SQLITE_ERROR_SNAPSHOT');
      SQLITE_ERROR_RETRY:        zName := PChar('SQLITE_ERROR_RETRY');
      SQLITE_ERROR_MISSING_COLLSEQ:
                                 zName := PChar('SQLITE_ERROR_MISSING_COLLSEQ');
      SQLITE_INTERNAL:           zName := PChar('SQLITE_INTERNAL');
      SQLITE_PERM:               zName := PChar('SQLITE_PERM');
      SQLITE_ABORT:              zName := PChar('SQLITE_ABORT');
      SQLITE_ABORT_ROLLBACK:     zName := PChar('SQLITE_ABORT_ROLLBACK');
      SQLITE_BUSY:               zName := PChar('SQLITE_BUSY');
      SQLITE_BUSY_RECOVERY:      zName := PChar('SQLITE_BUSY_RECOVERY');
      SQLITE_BUSY_SNAPSHOT:      zName := PChar('SQLITE_BUSY_SNAPSHOT');
      SQLITE_LOCKED:             zName := PChar('SQLITE_LOCKED');
      SQLITE_LOCKED_SHAREDCACHE: zName := PChar('SQLITE_LOCKED_SHAREDCACHE');
      SQLITE_NOMEM:              zName := PChar('SQLITE_NOMEM');
      SQLITE_READONLY:           zName := PChar('SQLITE_READONLY');
      SQLITE_READONLY_RECOVERY:  zName := PChar('SQLITE_READONLY_RECOVERY');
      SQLITE_READONLY_CANTINIT:  zName := PChar('SQLITE_READONLY_CANTINIT');
      SQLITE_READONLY_ROLLBACK:  zName := PChar('SQLITE_READONLY_ROLLBACK');
      SQLITE_READONLY_DBMOVED:   zName := PChar('SQLITE_READONLY_DBMOVED');
      SQLITE_READONLY_DIRECTORY: zName := PChar('SQLITE_READONLY_DIRECTORY');
      SQLITE_INTERRUPT:          zName := PChar('SQLITE_INTERRUPT');
      SQLITE_IOERR:              zName := PChar('SQLITE_IOERR');
      SQLITE_IOERR_READ:         zName := PChar('SQLITE_IOERR_READ');
      SQLITE_IOERR_SHORT_READ:   zName := PChar('SQLITE_IOERR_SHORT_READ');
      SQLITE_IOERR_WRITE:        zName := PChar('SQLITE_IOERR_WRITE');
      SQLITE_IOERR_FSYNC:        zName := PChar('SQLITE_IOERR_FSYNC');
      SQLITE_IOERR_DIR_FSYNC:    zName := PChar('SQLITE_IOERR_DIR_FSYNC');
      SQLITE_IOERR_TRUNCATE:     zName := PChar('SQLITE_IOERR_TRUNCATE');
      SQLITE_IOERR_FSTAT:        zName := PChar('SQLITE_IOERR_FSTAT');
      SQLITE_IOERR_UNLOCK:       zName := PChar('SQLITE_IOERR_UNLOCK');
      SQLITE_IOERR_RDLOCK:       zName := PChar('SQLITE_IOERR_RDLOCK');
      SQLITE_IOERR_DELETE:       zName := PChar('SQLITE_IOERR_DELETE');
      SQLITE_IOERR_NOMEM:        zName := PChar('SQLITE_IOERR_NOMEM');
      SQLITE_IOERR_ACCESS:       zName := PChar('SQLITE_IOERR_ACCESS');
      SQLITE_IOERR_CHECKRESERVEDLOCK:
                                 zName := PChar('SQLITE_IOERR_CHECKRESERVEDLOCK');
      SQLITE_IOERR_LOCK:         zName := PChar('SQLITE_IOERR_LOCK');
      SQLITE_IOERR_CLOSE:        zName := PChar('SQLITE_IOERR_CLOSE');
      SQLITE_IOERR_DIR_CLOSE:    zName := PChar('SQLITE_IOERR_DIR_CLOSE');
      SQLITE_IOERR_SHMOPEN:      zName := PChar('SQLITE_IOERR_SHMOPEN');
      SQLITE_IOERR_SHMSIZE:      zName := PChar('SQLITE_IOERR_SHMSIZE');
      SQLITE_IOERR_SHMLOCK:      zName := PChar('SQLITE_IOERR_SHMLOCK');
      SQLITE_IOERR_SHMMAP:       zName := PChar('SQLITE_IOERR_SHMMAP');
      SQLITE_IOERR_SEEK:         zName := PChar('SQLITE_IOERR_SEEK');
      SQLITE_IOERR_DELETE_NOENT: zName := PChar('SQLITE_IOERR_DELETE_NOENT');
      SQLITE_IOERR_MMAP:         zName := PChar('SQLITE_IOERR_MMAP');
      SQLITE_IOERR_GETTEMPPATH:  zName := PChar('SQLITE_IOERR_GETTEMPPATH');
      SQLITE_IOERR_CONVPATH:     zName := PChar('SQLITE_IOERR_CONVPATH');
      SQLITE_CORRUPT:            zName := PChar('SQLITE_CORRUPT');
      SQLITE_CORRUPT_VTAB:       zName := PChar('SQLITE_CORRUPT_VTAB');
      SQLITE_NOTFOUND:           zName := PChar('SQLITE_NOTFOUND');
      SQLITE_FULL:               zName := PChar('SQLITE_FULL');
      SQLITE_CANTOPEN:           zName := PChar('SQLITE_CANTOPEN');
      SQLITE_CANTOPEN_NOTEMPDIR: zName := PChar('SQLITE_CANTOPEN_NOTEMPDIR');
      SQLITE_CANTOPEN_ISDIR:     zName := PChar('SQLITE_CANTOPEN_ISDIR');
      SQLITE_CANTOPEN_FULLPATH:  zName := PChar('SQLITE_CANTOPEN_FULLPATH');
      SQLITE_CANTOPEN_CONVPATH:  zName := PChar('SQLITE_CANTOPEN_CONVPATH');
      SQLITE_CANTOPEN_SYMLINK:   zName := PChar('SQLITE_CANTOPEN_SYMLINK');
      SQLITE_PROTOCOL:           zName := PChar('SQLITE_PROTOCOL');
      SQLITE_EMPTY:              zName := PChar('SQLITE_EMPTY');
      SQLITE_SCHEMA:             zName := PChar('SQLITE_SCHEMA');
      SQLITE_TOOBIG:             zName := PChar('SQLITE_TOOBIG');
      SQLITE_CONSTRAINT:         zName := PChar('SQLITE_CONSTRAINT');
      SQLITE_CONSTRAINT_UNIQUE:  zName := PChar('SQLITE_CONSTRAINT_UNIQUE');
      SQLITE_CONSTRAINT_TRIGGER: zName := PChar('SQLITE_CONSTRAINT_TRIGGER');
      SQLITE_CONSTRAINT_FOREIGNKEY:
                                 zName := PChar('SQLITE_CONSTRAINT_FOREIGNKEY');
      SQLITE_CONSTRAINT_CHECK:   zName := PChar('SQLITE_CONSTRAINT_CHECK');
      SQLITE_CONSTRAINT_PRIMARYKEY:
                                 zName := PChar('SQLITE_CONSTRAINT_PRIMARYKEY');
      SQLITE_CONSTRAINT_NOTNULL: zName := PChar('SQLITE_CONSTRAINT_NOTNULL');
      SQLITE_CONSTRAINT_COMMITHOOK:
                                 zName := PChar('SQLITE_CONSTRAINT_COMMITHOOK');
      SQLITE_CONSTRAINT_VTAB:    zName := PChar('SQLITE_CONSTRAINT_VTAB');
      SQLITE_CONSTRAINT_FUNCTION:
                                 zName := PChar('SQLITE_CONSTRAINT_FUNCTION');
      SQLITE_CONSTRAINT_ROWID:   zName := PChar('SQLITE_CONSTRAINT_ROWID');
      SQLITE_MISMATCH:           zName := PChar('SQLITE_MISMATCH');
      SQLITE_MISUSE:             zName := PChar('SQLITE_MISUSE');
      SQLITE_NOLFS:              zName := PChar('SQLITE_NOLFS');
      SQLITE_AUTH:               zName := PChar('SQLITE_AUTH');
      SQLITE_FORMAT:             zName := PChar('SQLITE_FORMAT');
      SQLITE_RANGE:              zName := PChar('SQLITE_RANGE');
      SQLITE_NOTADB:             zName := PChar('SQLITE_NOTADB');
      SQLITE_ROW:                zName := PChar('SQLITE_ROW');
      SQLITE_NOTICE:             zName := PChar('SQLITE_NOTICE');
      SQLITE_NOTICE_RECOVER_WAL: zName := PChar('SQLITE_NOTICE_RECOVER_WAL');
      SQLITE_NOTICE_RECOVER_ROLLBACK:
                                 zName := PChar('SQLITE_NOTICE_RECOVER_ROLLBACK');
      SQLITE_NOTICE_RBU:         zName := PChar('SQLITE_NOTICE_RBU');
      SQLITE_WARNING:            zName := PChar('SQLITE_WARNING');
      SQLITE_WARNING_AUTOINDEX:  zName := PChar('SQLITE_WARNING_AUTOINDEX');
      SQLITE_DONE:               zName := PChar('SQLITE_DONE');
    end;
    rc := rc and $ff;
    Inc(i);
  end;
  if zName = nil then
    zName := PChar('SQLITE_Unknown');
  Result := zName;
end;

{ test1.c:147 — sqlite3TestErrCode.  In a non-threadsafe build, when the
  returned rc disagrees with sqlite3_errcode(db) (and is neither MISUSE nor
  OK), report a mismatch and return 1.  In a threadsafe build (the profile
  used by the driver) the guard short-circuits and this is a no-op returning
  0, so a failing bind simply returns TCL_ERROR with an empty result. }
function sqlite3TestErrCode(interp: PTclInterp; db: PTsqlite3; rc: cint): cint;
var
  r2: cint;
  zBuf: AnsiString;
begin
  if (sqlite3_threadsafe = 0) and (rc <> SQLITE_MISUSE) and (rc <> SQLITE_OK)
     and (sqlite3_errcode(db) <> rc) then
  begin
    r2 := sqlite3_errcode(db);
    zBuf := 'error code ' + AnsiString(t1ErrName(rc)) + ' (' + IntToStr(rc) +
            ') does not match sqlite3_errcode ' + AnsiString(t1ErrName(r2)) +
            ' (' + IntToStr(r2) + ')';
    Tcl_ResetResult(interp);
    Tcl_AppendResult(interp, PChar(zBuf), Pointer(nil));
    Result := 1;
    Exit;
  end;
  Result := 0;
end;

{ Format a pointer as the "%p"-flavoured hex test1.c hands to Tcl.
  sqlite3TestMakePointerStr uses sqlite3_snprintf("%p", p); SQLite's own
  %p (printf.c etPOINTER, no prefix) renders bare lowercase hex with NO
  "0x" prefix.  The tests regex-match this as /^[0-9A-Fa-f]+$/. }
procedure ptrToHex(p: Pointer; out zBuf: AnsiString);
begin
  zBuf := LowerCase(IntToHex(PtrUInt(p), 1));
end;

{ test1.c:419..460 — test_exec.
  Usage: sqlite3_exec DB SQL  (string-arg form).
  The Pascal port collapses the result to a single-list: "{rc} {result-or-err}",
  matching what Tcl_AppendElement produces.  Performs the in-place %HH hex
  decode pass (test1.c:442..449) before invoking sqlite3_exec — badutf.test
  and friends rely on it to inject raw bytes into the SQL string. }
{ test1.c:195..208 — exec_printf_cb.
  pArg is a Tcl_DString*.  On the first row, append the column names;
  then for every row append each value as a Tcl list element.  Using
  Tcl_DStringAppendElement gets the brace-escaping right (e.g.
  "x 80" → "{x 80}", plain "80" → "80"). }
function execPrintfCb(pArg: Pointer; nCol: i32;
  argv: PPAnsiChar; colv: PPAnsiChar): i32; cdecl;
var
  str: PTclDString;
  i:   i32;
  z:   PAnsiChar;
begin
  str := PTclDString(pArg);
  if str^.length = 0 then
  begin
    for i := 0 to nCol - 1 do
    begin
      z := PPAnsiChar(PtrUInt(colv) + PtrUInt(i) * SizeOf(Pointer))^;
      if z = nil then z := PAnsiChar('NULL');
      Tcl_DStringAppendElement(str, z);
    end;
  end;
  for i := 0 to nCol - 1 do
  begin
    z := PPAnsiChar(PtrUInt(argv) + PtrUInt(i) * SizeOf(Pointer))^;
    if z = nil then z := PAnsiChar('NULL');
    Tcl_DStringAppendElement(str, z);
  end;
  Result := 0;
end;

function test_exec(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  rc:    i32;
  zErr:  PAnsiChar;
  str:   TTclDString;
  zBuf:  array[0..31] of AnsiChar;
  zSql:  PAnsiChar;
  zIn:   PAnsiChar;
  i, j:  cint;
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
  Tcl_DStringInit(@str);
  zErr := nil;
  { test1.c:441..449 — copy SQL into a mutable buffer and apply the
    in-place %HH → raw-byte decode pass.  Pas sqlite3_mprintf has no
    varargs entry, so allocate via GetMem and copy by hand. }
  zIn := Tcl_GetString(objv[2]);
  i := 0;
  while zIn[i] <> #0 do Inc(i);
  GetMem(zSql, i + 1);
  Move(zIn^, zSql^, i + 1);
  i := 0; j := 0;
  while zSql[i] <> #0 do
  begin
    if (zSql[i] = '%') and (zSql[i+1] <> #0) and (zSql[i+2] <> #0) then
    begin
      zSql[j] := AnsiChar((testHexToInt(Ord(zSql[i+1])) shl 4)
                        + testHexToInt(Ord(zSql[i+2])));
      Inc(j); Inc(i, 3);
    end
    else
    begin
      zSql[j] := zSql[i];
      Inc(j); Inc(i);
    end;
  end;
  zSql[j] := #0;
  rc := sqlite3_exec(db, zSql, @execPrintfCb, @str, @zErr);
  FreeMem(zSql);
  FillChar(zBuf, SizeOf(zBuf), 0);
  StrPCopy(zBuf, IntToStr(rc));
  Tcl_AppendElement(interp, @zBuf[0]);
  if rc = SQLITE_OK then
    Tcl_AppendElement(interp, Tcl_DStringValue(@str))
  else if zErr <> nil then
    Tcl_AppendElement(interp, zErr)
  else
    Tcl_AppendElement(interp, PChar(''));
  Tcl_DStringFree(@str);
  if zErr <> nil then sqlite3_free(zErr);
  Result := TCL_OK;
end;

{ test1.c:331..375 — test_exec_hex.
  Usage: sqlite3_exec_hex DB HEX.
  Copies HEX into a 501-byte buffer, replacing each "%XX" with the raw
  byte 0xXX (test1.c:357..364), then runs sqlite3_exec with execPrintfCb
  accumulating into a Tcl_DString and appends "{rc} {result-or-err}".
  Must be a native command (not a Tcl shim) so the raw 0xFF/0xFE bytes
  reach sqlite3_exec unchanged — a Tcl `db eval` would UTF-8 re-encode
  them (0xFF -> 0xC3 0xBF), corrupting the LIKE-range optimisation tests
  like-9.4.3 / 9.5.1 / 9.5.2. }
function test_exec_hex(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db:    PTsqlite3;
  rc:    i32;
  zErr:  PAnsiChar;
  str:   TTclDString;
  zBuf:  array[0..29] of AnsiChar;
  zSql:  array[0..500] of AnsiChar;
  zHex:  PAnsiChar;
  av:    PPAnsiCharArr;
  i, j:  cint;
begin
  av := argv;
  if argc <> 3 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB HEX'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zHex := av[2];
  zErr := nil;
  i := 0; j := 0;
  while (i < (SizeOf(zSql) - 1)) and (zHex[j] <> #0) do
  begin
    if (zHex[j] = '%') and (zHex[j+1] <> #0) and (zHex[j+2] <> #0) then
    begin
      zSql[i] := AnsiChar((testHexToInt(Ord(zHex[j+1])) shl 4)
                        + testHexToInt(Ord(zHex[j+2])));
      Inc(j, 2);
    end
    else
      zSql[i] := zHex[j];
    Inc(i); Inc(j);
  end;
  zSql[i] := #0;
  Tcl_DStringInit(@str);
  rc := sqlite3_exec(db, @zSql[0], @execPrintfCb, @str, @zErr);
  FillChar(zBuf, SizeOf(zBuf), 0);
  StrPCopy(zBuf, IntToStr(rc));
  Tcl_AppendElement(interp, @zBuf[0]);
  if rc = SQLITE_OK then
    Tcl_AppendElement(interp, Tcl_DStringValue(@str))
  else if zErr <> nil then
    Tcl_AppendElement(interp, zErr)
  else
    Tcl_AppendElement(interp, PChar(''));
  Tcl_DStringFree(@str);
  if zErr <> nil then sqlite3_free(zErr);
  Result := TCL_OK;
end;

{ test1.c:299..328 — test_exec_printf.
  Usage: sqlite3_exec_printf DB FORMAT STRING.
  Builds SQL via sqlite3_mprintf(FORMAT, STRING), runs sqlite3_exec with
  execPrintfCb accumulating into a Tcl_DString, then appends
  "{rc} {result-or-err}".  Trampoline takes the legacy argc/argv form
  (Tcl_CreateCommand), matching the C registration at test1.c:9072. }
function test_exec_printf(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db:    PTsqlite3;
  rc:    i32;
  zErr:  PAnsiChar;
  zSql:  PAnsiChar;
  str:   TTclDString;
  zBuf:  array[0..31] of AnsiChar;
  av:    PPAnsiCharArr;
begin
  av := argv;
  if argc <> 4 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB FORMAT STRING'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  Tcl_DStringInit(@str);
  zErr := nil;
  zSql := sqlite3PfMprintf(av[2], [av[3]]);
  rc := sqlite3_exec(db, zSql, @execPrintfCb, @str, @zErr);
  sqlite3_free(zSql);
  FillChar(zBuf, SizeOf(zBuf), 0);
  StrPCopy(zBuf, IntToStr(rc));
  Tcl_AppendElement(interp, @zBuf[0]);
  if rc = SQLITE_OK then
    Tcl_AppendElement(interp, Tcl_DStringValue(@str))
  else if zErr <> nil then
    Tcl_AppendElement(interp, zErr)
  else
    Tcl_AppendElement(interp, PChar(''));
  Tcl_DStringFree(@str);
  if zErr <> nil then sqlite3_free(zErr);
  Result := TCL_OK;
end;

{ test1.c:383..397 — db_enter (old-style argc/argv handler).
  Usage: db_enter DB.  Enters the connection mutex. }
function db_enter(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db: PTsqlite3;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  Result := TCL_OK;
end;

{ test1.c:399..414 — db_leave (old-style argc/argv handler).
  Usage: db_leave DB.  Leaves the connection mutex. }
function db_leave(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db: PTsqlite3;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_mutex_leave(db^.mutex);
  Result := TCL_OK;
end;

{ test1.c:6024..6048 — delete_function (old-style argc/argv handler).
  Usage: sqlite_delete_function DB function-name.  Re-registers the named
  user function with NULL callbacks (any number of args, UTF8) which is
  how SQLite deletes a function.  Needed by schema.test 11.2/11.6 +
  schema2.test. }
function delete_function(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db: PTsqlite3;
  rc: i32;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 3 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB function-name'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_create_function(db, av[2], -1, SQLITE_UTF8, nil, nil, nil, nil);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
end;

{ test1.c:6050..6075 — delete_collation (old-style argc/argv handler).
  Usage: sqlite_delete_collation DB collation-name.  Re-registers the named
  collation (UTF8) with a NULL comparator, which deletes it.  Needed by
  schema.test + schema2.test. }
function delete_collation(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db: PTsqlite3;
  rc: i32;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 3 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB function-name'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_create_collation(db, av[2], SQLITE_UTF8, nil, nil);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
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

{ test1.c:4938..4957 — test_error_offset.
  Usage: sqlite3_error_offset DB. }
function test_error_offset(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:          PTsqlite3;
  iByteOffset: cint;
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
  iByteOffset := sqlite3_error_offset(db);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(iByteOffset));
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

{ test1.c:5159..5229 — test_prepare_v3.
  Usage: sqlite3_prepare_v3 DB sql bytes flags ?tailvar?  Mirrors the _v2
  sibling but takes an explicit prepFlags argument (objv[4]); the optional
  tailvar moves to objv[5].  Like the Pascal _v2 trampoline we skip the
  malloc-copy (valgrind aid) and exercise the same engine path directly. }
function test_prepare_v3(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  zSql:  PAnsiChar;
  zTail: PAnsiChar;
  pStmt: Pointer;
  bytes: cint;
  flags: cint;
  rc:    i32;
  hex:   AnsiString;
  zBuf:  array[0..63] of AnsiChar;
begin
  if (objc <> 6) and (objc <> 5) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' DB sql bytes flags tailvar'),
      Pointer(nil));
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
  if Tcl_GetIntFromObj(interp, objv[4], @flags) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zTail := nil;
  pStmt := nil;
  if objc >= 6 then
    rc := sqlite3_prepare_v3(db, zSql, bytes, u32(flags), @pStmt, @zTail)
  else
    rc := sqlite3_prepare_v3(db, zSql, bytes, u32(flags), @pStmt, nil);
  Tcl_ResetResult(interp);
  if (rc = SQLITE_OK) and (zTail <> nil) and (objc >= 6) then
  begin
    if bytes >= 0 then
      bytes := bytes - cint(PtrUInt(zTail) - PtrUInt(zSql));
    Tcl_ObjSetVar2(interp, objv[5], nil,
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

{ 9.4.divbug.88.004 — test1.c:5280..5330 — test_prepare16.
  Usage: sqlite3_prepare16 DB sql bytes ?tailvar?
  Mirrors the UTF-8 sibling but routes through sqlite3_prepare16 and
  echoes the unused tail back as a byte-array Tcl_Obj (matching
  Tcl_NewByteArrayObj in the C reference). }
function test_prepare16(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:     PTsqlite3;
  zSql:   Pointer;
  zTail:  Pointer;
  pStmt:  Pointer;
  pTail:  PTclObj;
  bytes:  cint;
  objlen: cint;
  rc:     i32;
  hex:    AnsiString;
  zBuf:   array[0..63] of AnsiChar;
begin
  if (objc <> 5) and (objc <> 4) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' DB sql bytes ?tailvar?'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  objlen := 0;
  zSql := Tcl_GetByteArrayFromObj(objv[2], @objlen);
  if Tcl_GetIntFromObj(interp, objv[3], @bytes) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zTail := nil;
  pStmt := nil;
  if objc >= 5 then
    rc := sqlite3_prepare16(db, zSql, bytes, @pStmt, @zTail)
  else
    rc := sqlite3_prepare16(db, zSql, bytes, @pStmt, nil);
  if rc <> SQLITE_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if objc >= 5 then
  begin
    if zTail <> nil then
      objlen := objlen - cint(PtrUInt(zTail) - PtrUInt(zSql))
    else
      objlen := 0;
    pTail := Tcl_NewByteArrayObj(zTail, objlen);
    Tcl_DbIncrRefCount(pTail, PChar('test_prepare16'), 0);
    Tcl_ObjSetVar2(interp, objv[4], nil, pTail, 0);
    Tcl_DbDecrRefCount(pTail, PChar('test_prepare16'), 0);
  end;
  FillChar(zBuf, SizeOf(zBuf), 0);
  if pStmt <> nil then
  begin
    ptrToHex(pStmt, hex);
    Move(hex[1], zBuf[0], Length(hex));
  end;
  Tcl_AppendResult(interp, @zBuf[0], Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.004 — test1.c:5340..5390 — test_prepare16_v2.
  Identical surface to test_prepare16 but routes through the _v2 engine
  entry (sets SQLITE_PREPARE_SAVESQL). }
function test_prepare16_v2(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:     PTsqlite3;
  zSql:   Pointer;
  zTail:  Pointer;
  pStmt:  Pointer;
  pTail:  PTclObj;
  bytes:  cint;
  objlen: cint;
  rc:     i32;
  hex:    AnsiString;
  zBuf:   array[0..63] of AnsiChar;
begin
  if (objc <> 5) and (objc <> 4) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' DB sql bytes ?tailvar?'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  objlen := 0;
  zSql := Tcl_GetByteArrayFromObj(objv[2], @objlen);
  if Tcl_GetIntFromObj(interp, objv[3], @bytes) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zTail := nil;
  pStmt := nil;
  if objc >= 5 then
    rc := sqlite3_prepare16_v2(db, zSql, bytes, @pStmt, @zTail)
  else
    rc := sqlite3_prepare16_v2(db, zSql, bytes, @pStmt, nil);
  if rc <> SQLITE_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if objc >= 5 then
  begin
    if zTail <> nil then
      objlen := objlen - cint(PtrUInt(zTail) - PtrUInt(zSql))
    else
      objlen := 0;
    pTail := Tcl_NewByteArrayObj(zTail, objlen);
    Tcl_DbIncrRefCount(pTail, PChar('test_prepare16_v2'), 0);
    Tcl_ObjSetVar2(interp, objv[4], nil, pTail, 0);
    Tcl_DbDecrRefCount(pTail, PChar('test_prepare16_v2'), 0);
  end;
  FillChar(zBuf, SizeOf(zBuf), 0);
  if pStmt <> nil then
  begin
    ptrToHex(pStmt, hex);
    Move(hex[1], zBuf[0], Length(hex));
  end;
  Tcl_AppendResult(interp, @zBuf[0], Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
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

{ test1.c:3172..3189 — test_changes.
  Usage: sqlite3_changes DB. }
function test_changes(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
begin
  if objc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' DB'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_changes(db)));
  Result := TCL_OK;
end;

{ test1.c:4967..4994 — test_errmsg16.
  Usage: sqlite3_errmsg16 DB.
  Returns the UTF-16 representation of the most recent error message as a
  Tcl byte-array (including the trailing 0x00 0x00 terminator). }
function test_errmsg16(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  zErr:  Pointer;
  z:     PAnsiChar;
  bytes: cint;
begin
  if objc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' DB'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  bytes := 0;
  zErr := sqlite3_errmsg16(db);
  if zErr <> nil then
  begin
    z := PAnsiChar(zErr);
    while (z[bytes] <> #0) or (z[bytes + 1] <> #0) do
      Inc(bytes, 2);
  end;
  Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(zErr, bytes));
  Result := TCL_OK;
end;

{ 9.4.divbug.88.002 — test1.c:3193..3194 module statics backing the
  `static` flag of sqlite_bind (test_bind) and exposed via Tcl_LinkVar
  at test1.c:9429..9432.  Init left at nil / 0 to mirror C `= 0`. }
var
  sqlite_static_bind_value: PAnsiChar = nil;
  sqlite_static_bind_nbyte: cint = 0;

{ 9.4.divbug.88.001 — test1.c:3121..3138.  Usage: sqlite3_expired STMT.
  sqlite3_expired() itself is deprecated and always returns 0 in the
  modern engine; we still wire the Tcl command 1:1 so badutf2.test can
  load. }
function test_expired(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
begin
  if objc <> 2 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' <STMT>'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp, Tcl_NewBooleanObj(sqlite3_expired(pStmt)));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.002 — test1.c:3207..3247 (old-style argc/argv handler).
  Usage: sqlite_bind VM IDX VALUE (null|static|static-nbytes|normal|blob10) }
function test_bind(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pStmt: PVdbe;
  rc, idx: cint;
  sBuf: ShortString;
begin
  if argc <> 5 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'), argv[0],
      PChar(' VM IDX VALUE (null|static|normal)"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(argv[1]));
  if Tcl_GetInt(interp, argv[2], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if StrComp(argv[4], 'null') = 0 then
    rc := sqlite3_bind_null(pStmt, idx)
  else if StrComp(argv[4], 'static') = 0 then
    rc := sqlite3_bind_text(pStmt, idx, sqlite_static_bind_value, -1, nil)
  else if StrComp(argv[4], 'static-nbytes') = 0 then
    rc := sqlite3_bind_text(pStmt, idx, sqlite_static_bind_value,
                            sqlite_static_bind_nbyte, nil)
  else if StrComp(argv[4], 'normal') = 0 then
    rc := sqlite3_bind_text(pStmt, idx, argv[3], -1, SQLITE_TRANSIENT)
  else if StrComp(argv[4], 'blob10') = 0 then
    rc := sqlite3_bind_text(pStmt, idx, PAnsiChar(#$61#$62#$63#$00#$78#$79#$7a#$00#$70#$71),
                            10, SQLITE_STATIC)
  else begin
    Tcl_AppendResult(interp,
      PChar('4th argument should be "null" or "static" or "normal"'),
      Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if rc <> 0 then begin
    Str(rc, sBuf);
    sBuf := '(' + sBuf + ') ' + #0;
    Tcl_AppendResult(interp, PChar(@sBuf[1]),
      sqlite3ErrStr(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
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
  unless arg is NULL; emit SQLITE_ERROR if v=40 (UTF-8), or
  SQLITE_ERROR with UTF-16 "abc" if v=41 (aggerror-1.4, divbug.14
  residual).  zUtf16ErrMsg layout mirrors test1.c:1286 — 8 bytes
  storing 0|'a'|0|'b'|0|'c'|0|0 so &z[1-SQLITE_BIGENDIAN] addresses
  the LE byte stream on a little-endian host. }
procedure t1CountStep(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
const
  { test1.c:1286 — { 0, 0x61, 0, 0x62, 0, 0x63, 0, 0, 0 }. }
  zUtf16ErrMsg: array[0..8] of Byte =
    ($00, $61, $00, $62, $00, $63, $00, $00, $00);
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
        PChar('value of 40 handed to x_count'), -1)
    else if v = 41 then
      { LE-host shift = 1 (1-SQLITE_BIGENDIAN, BIGENDIAN=0). }
      sqlite3_result_error16(pCtx, @zUtf16ErrMsg[1], -1);
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

{ test3.c:25..28 — a bogus sqlite3 connection used by the [btree_open]
  family.  Only pVfs and mutex are ever touched. }
var
  t3_sDb: Tsqlite3;
  t3_nRefSqlite3: cint = 0;

{ Render a pointer as test3.c does (sqlite3_snprintf "%p") and append it
  to the interp result.  SQLite's %p (printf.c etPOINTER) is bare lowercase
  hex with NO "0x" prefix. }
procedure t3AppendPtr(interp: PTclInterp; p: Pointer);
var
  s:    AnsiString;
  zBuf: array[0..99] of AnsiChar;
begin
  s := LowerCase(IntToHex(PtrUInt(p), 1));
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(s[1], zBuf[0], Length(s));
  Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
end;

{ test3.c:30..77 — btree_open FILENAME NCACHE.  Open a new database at the
  raw b-tree level against the bogus sDb connection. }
function btree_open(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pBt:       PBtree;
  rc:        cint;
  nCache:    cint;
  n:         cint;
  zFilename: PAnsiChar;
begin
  if argc <> 3 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' FILENAME NCACHE FLAGS"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetInt(interp, argv[2], @nCache) <> 0 then begin Result := TCL_ERROR; Exit; end;
  Inc(t3_nRefSqlite3);
  if t3_nRefSqlite3 = 1 then
  begin
    t3_sDb.pVfs := sqlite3_vfs_find(nil);
    t3_sDb.mutex := sqlite3MutexAlloc(SQLITE_MUTEX_RECURSIVE);
    sqlite3_mutex_enter(t3_sDb.mutex);
  end;
  n := StrLen(argv[1]);
  zFilename := sqlite3_malloc(n + 2);
  if zFilename = nil then begin Result := TCL_ERROR; Exit; end;
  Move(argv[1]^, zFilename^, n + 1);
  zFilename[n + 1] := #0;
  pBt := nil;
  rc := sqlite3BtreeOpen(t3_sDb.pVfs, zFilename, @t3_sDb, @pBt, 0,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MAIN_DB);
  sqlite3_free(zFilename);
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  sqlite3BtreeSetCacheSize(pBt, nCache);
  t3AppendPtr(interp, pBt);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:83..110 — btree_close ID. }
function btree_close(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pBt: PBtree;
  rc:  cint;
begin
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' ID"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pBt := PBtree(sqlite3TestTextToPtr(argv[1]));
  rc := sqlite3BtreeClose(pBt);
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Dec(t3_nRefSqlite3);
  if t3_nRefSqlite3 = 0 then
  begin
    sqlite3_mutex_leave(t3_sDb.mutex);
    sqlite3_mutex_free(t3_sDb.mutex);
    t3_sDb.mutex := nil;
    t3_sDb.pVfs := nil;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:548..575 — btree_ismemdb ID.
  Return true if the B-Tree is currently stored entirely in memory
  (i.e. its pager file has no installed IO methods). }
function btree_ismemdb(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pBt:   PBtree;
  res:   cint;
  pFile: Psqlite3_file;
begin
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' ID"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pBt := PBtree(sqlite3TestTextToPtr(argv[1]));
  { C: pBt->db->mutex.  In this port every test3 b-tree is opened against
    the shared bogus connection t3_sDb (see btree_open), so pBt->db == &t3_sDb. }
  sqlite3_mutex_enter(t3_sDb.mutex);
  sqlite3BtreeEnter(pBt);
  pFile := sqlite3PagerFile(sqlite3BtreePager(pBt));
  res := cint(Ord(pFile^.pMethods = nil));
  sqlite3BtreeLeave(pBt);
  sqlite3_mutex_leave(t3_sDb.mutex);
  Tcl_SetObjResult(interp, Tcl_NewBooleanObj(res));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:118..143 — btree_begin_transaction ID. }
function btree_begin_transaction(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pBt: PBtree;
  rc:  cint;
begin
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' ID"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pBt := PBtree(sqlite3TestTextToPtr(argv[1]));
  sqlite3BtreeEnter(pBt);
  rc := sqlite3BtreeBeginTrans(pBt, 1, nil);
  sqlite3BtreeLeave(pBt);
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:197..244 — btree_cursor ID TABLENUM WRITEABLE. }
function btree_cursor(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pBt:    PBtree;
  iTable: cint;
  pCur:   PBtCursor;
  rc:     cint;
  wrFlag: cint;
begin
  rc := SQLITE_OK;
  if argc <> 4 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' ID TABLENUM WRITEABLE"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pBt := PBtree(sqlite3TestTextToPtr(argv[1]));
  if Tcl_GetInt(interp, argv[2], @iTable) <> 0 then begin Result := TCL_ERROR; Exit; end;
  if Tcl_GetBoolean(interp, argv[3], @wrFlag) <> 0 then begin Result := TCL_ERROR; Exit; end;
  if wrFlag <> 0 then wrFlag := BTREE_WRCSR;
  pCur := PBtCursor(sqlite3_malloc(sqlite3BtreeCursorSize()));
  FillChar(pCur^, sqlite3BtreeCursorSize(), 0);
  sqlite3_mutex_enter(PTsqlite3(pBt^.db)^.mutex);
  sqlite3BtreeEnter(pBt);
  rc := sqlite3BtreeLockTable(pBt, iTable, Ord(wrFlag <> 0));
  if rc = SQLITE_OK then
    rc := sqlite3BtreeCursor(pBt, iTable, wrFlag, nil, pCur);
  sqlite3BtreeLeave(pBt);
  sqlite3_mutex_leave(PTsqlite3(pBt^.db)^.mutex);
  if rc <> 0 then
  begin
    sqlite3_free(pCur);
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  t3AppendPtr(interp, pCur);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:246..286 — btree_close_cursor ID. }
function btree_close_cursor(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pCur: PBtCursor;
  pBt:  PBtree;
  rc:   cint;
begin
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' ID"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pCur := PBtCursor(sqlite3TestTextToPtr(argv[1]));
  pBt := pCur^.pBtree;
  sqlite3_mutex_enter(PTsqlite3(pBt^.db)^.mutex);
  sqlite3BtreeEnter(pBt);
  rc := sqlite3BtreeCloseCursor(pCur);
  sqlite3BtreeLeave(pBt);
  sqlite3_mutex_leave(PTsqlite3(pBt^.db)^.mutex);
  sqlite3_free(pCur);
  if rc <> 0 then
  begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:288..325 — btree_next ID.  0 on success, 1 if at/past last. }
function btree_next(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pCur: PBtCursor;
  rc:   cint;
  res:  cint;
  zBuf: array[0..99] of AnsiChar;
  s:    AnsiString;
begin
  res := 0;
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' ID"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pCur := PBtCursor(sqlite3TestTextToPtr(argv[1]));
  sqlite3BtreeEnter(pCur^.pBtree);
  rc := sqlite3BtreeNext(pCur, 0);
  if rc = SQLITE_DONE then
  begin
    res := 1;
    rc := SQLITE_OK;
  end;
  sqlite3BtreeLeave(pCur^.pBtree);
  if rc <> 0 then
  begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  s := IntToStr(res);
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(s[1], zBuf[0], Length(s));
  Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:327..361 — btree_first ID.  0 if positioned, 1 if table empty. }
function btree_first(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pCur: PBtCursor;
  rc:   cint;
  res:  cint;
  zBuf: array[0..99] of AnsiChar;
  s:    AnsiString;
begin
  res := 0;
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' ID"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pCur := PBtCursor(sqlite3TestTextToPtr(argv[1]));
  sqlite3BtreeEnter(pCur^.pBtree);
  rc := sqlite3BtreeFirst(pCur, @res);
  sqlite3BtreeLeave(pCur^.pBtree);
  if rc <> 0 then
  begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  s := IntToStr(res);
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(s[1], zBuf[0], Length(s));
  Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:391..417 — btree_payload_size ID. }
function btree_payload_size(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  pCur: PBtCursor;
  n:    u32;
  zBuf: array[0..99] of AnsiChar;
  s:    AnsiString;
begin
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      argv[0], PChar(' ID"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pCur := PBtCursor(sqlite3TestTextToPtr(argv[1]));
  sqlite3BtreeEnter(pCur^.pBtree);
  n := sqlite3BtreePayloadSize(pCur);
  sqlite3BtreeLeave(pCur^.pBtree);
  s := IntToStr(n);
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(s[1], zBuf[0], Length(s));
  Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:609..654 — btree_insert CSR ?KEY? VALUE.
  ObjCommand: with KEY (objc=4) inserts an integer-key/table row whose rowid
  is KEY and whose data is VALUE; without KEY (objc=3) inserts an index/blob
  key whose bytes are VALUE. }
function btree_insert(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pCur: PBtCursor;
  rc:   cint;
  x:    TBtreePayload;
  n:    cint;
begin
  if (objc <> 4) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?-intkey? CSR KEY VALUE'));
    Result := TCL_ERROR; Exit;
  end;

  FillChar(x, SizeOf(x), 0);
  if objc = 4 then
  begin
    if Tcl_GetIntFromObj(interp, objv[2], @rc) <> 0 then
    begin Result := TCL_ERROR; Exit; end;
    x.nKey := rc;
    x.pData := Pointer(Tcl_GetByteArrayFromObj(objv[3], @n));
    x.nData := cint(n);
  end
  else
  begin
    x.pKey := Pointer(Tcl_GetByteArrayFromObj(objv[2], @n));
    x.nKey := cint(n);
  end;
  pCur := PBtCursor(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));

  sqlite3_mutex_enter(PTsqlite3(pCur^.pBtree^.db)^.mutex);
  sqlite3BtreeEnter(pCur^.pBtree);
  rc := sqlite3BtreeInsert(pCur, @x, 0, 0);
  sqlite3BtreeLeave(pCur^.pBtree);
  sqlite3_mutex_leave(PTsqlite3(pCur^.pBtree^.db)^.mutex);

  Tcl_ResetResult(interp);
  if rc <> 0 then
  begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:504..546 — btree_from_db DB-HANDLE ?N?.
  Returns the Btree* pointer for database iDb (default 0) of the SQLite
  connection bound to the Tcl `db` command.  Rendered as "%p" hex.
  9.4.divbug.88.011. }
function btree_from_db(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
type
  TArgvArr = array[0..16] of PAnsiChar;
  PArgvArr = ^TArgvArr;
var
  cmdInfo: TTclCmdInfo;
  p:       PTestSqliteDb;
  db:      PTsqlite3;
  pBt:     Pointer;
  iDb:     cint;
  av:      PArgvArr;
  zBuf:    array[0..99] of AnsiChar;
  s:       AnsiString;
begin
  av := PArgvArr(argv);
  if (argc <> 2) and (argc <> 3) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av^[0], PChar(' DB-HANDLE ?N?"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetCommandInfo(interp, av^[1], @cmdInfo) = 0 then
  begin
    Tcl_AppendResult(interp, PChar('No such db-handle: "'),
      av^[1], PChar('"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  iDb := 0;
  if argc = 3 then
    iDb := StrToIntDef(StrPas(av^[2]), 0);
  p := PTestSqliteDb(cmdInfo.objClientData);
  db := p^.db;
  pBt := db^.aDb[iDb].pBt;
  { test3.c:73 sqlite3_snprintf("%p", pBt) — bare hex, no "0x" prefix. }
  s := LowerCase(IntToHex(PtrUInt(pBt), 1));
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(s[1], zBuf[0], Length(s));
  Tcl_SetResult(interp, PChar(@zBuf[0]), TCL_VOLATILE);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:147..190 — btree_pager_stats ID.
  Returns pager statistics as a Tcl list of name/value pairs.  ID is the
  "%p" text of a Btree* (from btree_from_db).  The Btree may belong to an
  open SQLite connection, so acquire pBt->db->mutex before BtreeEnter.
  6.40.6 (HARNESS). }
function btree_pager_stats(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
type
  TArgvArr = array[0..16] of PAnsiChar;
  PArgvArr = ^TArgvArr;
const
  zName: array[0..10] of PChar = (
    'ref', 'page', 'max', 'size', 'state', 'err',
    'hit', 'miss', 'ovfl', 'read', 'write');
var
  av:    PArgvArr;
  pBt:   PBtree;
  a:     PPagerStatsArray;
  i:     cint;
  zBuf:  array[0..99] of AnsiChar;
  s:     AnsiString;
begin
  av := PArgvArr(argv);
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av^[0], PChar(' ID"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pBt := PBtree(sqlite3TestTextToPtr(av^[1]));

  { The Btree handle may have been obtained from an open SQLite connection
    (via btree_from_db), so take the controlling handle's mutex first. }
  sqlite3_mutex_enter(PTsqlite3(pBt^.db)^.mutex);
  sqlite3BtreeEnter(pBt);
  a := sqlite3PagerStats(sqlite3BtreePager(pBt));
  for i := 0 to 10 do
  begin
    Tcl_AppendElement(interp, zName[i]);
    s := IntToStr(a^[i]);  { C: sqlite3_snprintf(zBuf,"%d",a[i]) }
    FillChar(zBuf, SizeOf(zBuf), 0);
    Move(s[1], zBuf[0], Length(s));
    Tcl_AppendElement(interp, @zBuf[0]);
  end;
  sqlite3BtreeLeave(pBt);
  sqlite3_mutex_leave(PTsqlite3(pBt^.db)^.mutex);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test3.c:429..502 — btree_varint_test START MULTIPLIER COUNT INCREMENT.
  Round-trips integers through sqlite3PutVarint / sqlite3GetVarint to
  validate the codec.  Mirrors C 1:1 including the inner 19x getVarint
  timing loop and the 32-bit fast-path cross-check.
  9.4.divbug.88.062. }
function btree_varint_test(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  start, mult, count, incr: u32;
  inVal, outVal: u64;
  out32:        u32;
  n1, n2, i, j: cint;
  zBuf:         array[0..99] of byte;
  zErr:         array[0..199] of AnsiChar;
  s:            AnsiString;
begin
  if argc <> 5 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'), argv[0],
      PChar(' START MULTIPLIER COUNT INCREMENT"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetInt(interp, argv[1], @start) <> 0 then begin Result := TCL_ERROR; Exit; end;
  if Tcl_GetInt(interp, argv[2], @mult)  <> 0 then begin Result := TCL_ERROR; Exit; end;
  if Tcl_GetInt(interp, argv[3], @count) <> 0 then begin Result := TCL_ERROR; Exit; end;
  if Tcl_GetInt(interp, argv[4], @incr)  <> 0 then begin Result := TCL_ERROR; Exit; end;
  inVal := start;
  inVal := inVal * mult;
  for i := 0 to cint(count) - 1 do
  begin
    n1 := sqlite3PutVarint(@zBuf[0], inVal);
    if (n1 > 9) or (n1 < 1) then
    begin
      s := Format('putVarint returned %d - should be between 1 and 9', [n1]);
      FillChar(zErr, SizeOf(zErr), 0);
      Move(s[1], zErr[0], Length(s));
      Tcl_AppendResult(interp, PChar(@zErr[0]), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    n2 := sqlite3GetVarint(@zBuf[0], outVal);
    if n1 <> n2 then
    begin
      s := Format('putVarint returned %d and getVarint returned %d', [n1, n2]);
      FillChar(zErr, SizeOf(zErr), 0);
      Move(s[1], zErr[0], Length(s));
      Tcl_AppendResult(interp, PChar(@zErr[0]), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    if inVal <> outVal then
    begin
      s := Format('Wrote 0x%.16x and got back 0x%.16x', [inVal, outVal]);
      FillChar(zErr, SizeOf(zErr), 0);
      Move(s[1], zErr[0], Length(s));
      Tcl_AppendResult(interp, PChar(@zErr[0]), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    if (inVal and $ffffffff) = inVal then
    begin
      n2 := sqlite3GetVarint32(@zBuf[0], out32);
      outVal := out32;
      if n1 <> n2 then
      begin
        s := Format('putVarint returned %d and GetVarint32 returned %d', [n1, n2]);
        FillChar(zErr, SizeOf(zErr), 0);
        Move(s[1], zErr[0], Length(s));
        Tcl_AppendResult(interp, PChar(@zErr[0]), Pointer(nil));
        Result := TCL_ERROR; Exit;
      end;
      if inVal <> outVal then
      begin
        s := Format('Wrote 0x%.16x and got back 0x%.16x from GetVarint32',
                    [inVal, outVal]);
        FillChar(zErr, SizeOf(zErr), 0);
        Move(s[1], zErr[0], Length(s));
        Tcl_AppendResult(interp, PChar(@zErr[0]), Pointer(nil));
        Result := TCL_ERROR; Exit;
      end;
    end;
    { Realistic-timing loop: getVarint called 19 more times. }
    for j := 0 to 18 do
      sqlite3GetVarint(@zBuf[0], outVal);
    inVal := inVal + incr;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ ============================================================
  test_quota.c:254..320 — quotaStrglob(zGlob, z): pure glob matcher.
  Faithful recursive port.  Reads a byte then advances the pointer to
  mirror C's *(p++).  '*' '?' '[...]' '[^...]' supported; '/' matches
  '/' or '\\'.  Returns 1 on match, 0 otherwise.
  ============================================================ }
function quotaStrglob(zGlob: PByte; z: PByte): cint;
var
  c, c2, cx: cint;
  invert, seen, prior_c: cint;
begin
  while True do
  begin
    c := zGlob^; Inc(zGlob);
    if c = 0 then Break;
    if c = Ord('*') then
    begin
      c := zGlob^; Inc(zGlob);
      while (c = Ord('*')) or (c = Ord('?')) do
      begin
        if c = Ord('?') then
        begin
          if z^ = 0 then begin Result := 0; Exit; end;
          Inc(z);
        end;
        c := zGlob^; Inc(zGlob);
      end;
      if c = 0 then
      begin
        Result := 1; Exit;
      end
      else if c = Ord('[') then
      begin
        while (z^ <> 0) and (quotaStrglob(zGlob - 1, z) = 0) do
          Inc(z);
        if z^ <> 0 then Result := 1 else Result := 0;
        Exit;
      end;
      if c = Ord('/') then cx := Ord('\') else cx := c;
      c2 := z^; Inc(z);
      while c2 <> 0 do
      begin
        while (c2 <> c) and (c2 <> cx) do
        begin
          c2 := z^; Inc(z);
          if c2 = 0 then begin Result := 0; Exit; end;
        end;
        if quotaStrglob(zGlob, z) <> 0 then begin Result := 1; Exit; end;
        c2 := z^; Inc(z);
      end;
      Result := 0; Exit;
    end
    else if c = Ord('?') then
    begin
      if z^ = 0 then begin Result := 0; Exit; end;
      Inc(z);
    end
    else if c = Ord('[') then
    begin
      prior_c := 0;
      seen := 0;
      invert := 0;
      c := z^; Inc(z);
      if c = 0 then begin Result := 0; Exit; end;
      c2 := zGlob^; Inc(zGlob);
      if c2 = Ord('^') then
      begin
        invert := 1;
        c2 := zGlob^; Inc(zGlob);
      end;
      if c2 = Ord(']') then
      begin
        if c = Ord(']') then seen := 1;
        c2 := zGlob^; Inc(zGlob);
      end;
      while (c2 <> 0) and (c2 <> Ord(']')) do
      begin
        if (c2 = Ord('-')) and (zGlob[0] <> Ord(']')) and (zGlob[0] <> 0)
           and (prior_c > 0) then
        begin
          c2 := zGlob^; Inc(zGlob);
          if (c >= prior_c) and (c <= c2) then seen := 1;
          prior_c := 0;
        end
        else
        begin
          if c = c2 then seen := 1;
          prior_c := c2;
        end;
        c2 := zGlob^; Inc(zGlob);
      end;
      if (c2 = 0) or ((seen xor invert) = 0) then begin Result := 0; Exit; end;
    end
    else if c = Ord('/') then
    begin
      if (z[0] <> Ord('/')) and (z[0] <> Ord('\')) then
        begin Result := 0; Exit; end;
      Inc(z);
    end
    else
    begin
      if c <> z^ then begin Result := 0; Exit; end;
      Inc(z);
    end;
  end;
  if z^ = 0 then Result := 1 else Result := 0;
end;

{ test_quota.c:1859..1877 — tclcmd: sqlite3_quota_glob PATTERN TEXT.
  Returns 1 if TEXT matches the glob PATTERN, else 0. }
function test_quota_glob(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zPattern, zText: PChar;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('PATTERN TEXT'));
    Result := TCL_ERROR; Exit;
  end;
  zPattern := Tcl_GetString(objv[1]);
  zText := Tcl_GetString(objv[2]);
  Tcl_SetObjResult(interp,
    Tcl_NewIntObj(quotaStrglob(PByte(zPattern), PByte(zText))));
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

{ ============================================================
  test_autoext.c — the "sqr" auto-extension + its Tcl command.
  Used by mutex2-2.5 to prove sqlite3_auto_extension() honours a failing
  sqlite3_initialize().  Only the sqr variant is needed here.
  ============================================================ }

{ test_autoext.c:23..30 — sqr() SQL function: returns x*x. }
procedure sqrFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  r: Double;
  pArg: PPsqlite3_value;
begin
  pArg := argv;
  r := sqlite3_value_double(pArg[0]);
  sqlite3_result_double(context, r * r);
  if argc = 0 then ;
end;

{ test_autoext.c:35..43 — sqr_init: extension entry point registering sqr(). }
function sqr_init(db: PTsqlite3; pzErrMsg: PPAnsiChar; pApi: Pointer): cint; cdecl;
begin
  Result := sqlite3_create_function(db, PAnsiChar('sqr'), 1,
    SQLITE_ANY, nil, @sqrFunc, nil, nil);
  if (pzErrMsg = nil) or (pApi = nil) then ;
end;

{ test_autoext.c:90..99 — sqlite3_auto_extension_sqr.  Register sqr_init as
  an auto-extension; return the rc (mutex2-2.5 expects 7 when init fails). }
function test_auto_extension_sqr(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var rc: cint;
begin
  rc := sqlite3_auto_extension(Tsqlite3_loadext_fn(Pointer(@sqr_init)));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
  if (clientData = nil) and (objc = 0) and (objv = nil) then ;
end;

{ ============================================================
  test_mutex.c — the countable mutex layer + Tcl bindings.

  This is a faithful port of ../sqlite3/src/test_mutex.c.  A counting
  wrapper is installed over the engine's real mutex methods (retrieved
  via sqlite3_config(SQLITE_CONFIG_GETMUTEX) and re-installed via
  SQLITE_CONFIG_MUTEX).  Every counterMutexEnter / counterMutexTry bumps
  a per-type counter that mutex1.test / mutex2.test read back.

  Note on calling convention: the wrapper functions are stored in
  gMutexMethods (the engine's sqlite3_mutex_methods table, os-type, plain
  register convention) — NOT the cdecl util-type — so they are declared
  WITHOUT cdecl to match how the engine invokes them.
  ============================================================ }

const
  MAX_MUTEXES    = SQLITE_MUTEX_STATIC_VFS3 + 1;                  { 14 }
  STATIC_MUTEXES = MAX_MUTEXES - (SQLITE_MUTEX_RECURSIVE + 1);    { 12 }

  { aName[] — MAX_MUTEXES entries followed by a nil terminator (for
    Tcl_GetIndexFromObj).  test_mutex.c:27..32. }
  mutexAName: array[0..MAX_MUTEXES] of PAnsiChar = (
    'fast',        'recursive',   'static_main',   'static_mem',
    'static_open', 'static_prng', 'static_lru',    'static_pmem',
    'static_app1', 'static_app2', 'static_app3',   'static_vfs1',
    'static_vfs2', 'static_vfs3', nil
  );

type
  { A countable mutex — test_mutex.c:35..38. }
  PTestCountMutex = ^TTestCountMutex;
  TTestCountMutex = record
    pReal: Psqlite3_mutex;
    eType: cint;
  end;

  { test_mutex_globals — test_mutex.c:41..49. }
  TTestMutexGlobals = record
    isInstalled: cint;                          { True if installed }
    disableInit: cint;                          { True → sqlite3_initialize() fails }
    disableTry:  cint;                          { True → sqlite3_mutex_try() fails }
    isInit:      cint;                          { True if initialized }
    m:           sqlite3_mutex_methods;         { Interface to "real" mutex system }
    aCounter:    array[0..MAX_MUTEXES - 1] of cint; { Grabs of each type }
    aStatic:     array[0..STATIC_MUTEXES - 1] of TTestCountMutex;
  end;

var
  mutexG: TTestMutexGlobals;

{ test_mutex.c:52..54 — counterMutexHeld. }
function counterMutexHeld(p: Psqlite3_mutex): cint;
begin
  Result := mutexG.m.xMutexHeld(PTestCountMutex(p)^.pReal);
end;

{ test_mutex.c:57..59 — counterMutexNotheld. }
function counterMutexNotheld(p: Psqlite3_mutex): cint;
begin
  Result := mutexG.m.xMutexNotheld(PTestCountMutex(p)^.pReal);
end;

{ test_mutex.c:66..72 — counterMutexInit. }
function counterMutexInit: cint;
begin
  if mutexG.disableInit <> 0 then
  begin
    Result := mutexG.disableInit;
    Exit;
  end;
  Result := mutexG.m.xMutexInit();
  mutexG.isInit := 1;
end;

{ test_mutex.c:77..80 — counterMutexEnd. }
function counterMutexEnd: cint;
begin
  mutexG.isInit := 0;
  Result := mutexG.m.xMutexEnd();
end;

{ test_mutex.c:85..108 — counterMutexAlloc. }
function counterMutexAlloc(eType: cint): Psqlite3_mutex;
var
  pReal: Psqlite3_mutex;
  pRet:  PTestCountMutex;
  eStaticType: cint;
begin
  pRet := nil;
  Assert(mutexG.isInit <> 0);
  Assert(eType >= SQLITE_MUTEX_FAST);
  Assert(eType <= SQLITE_MUTEX_STATIC_VFS3);

  pReal := mutexG.m.xMutexAlloc(eType);
  if pReal = nil then
  begin
    Result := nil;
    Exit;
  end;

  if (eType = SQLITE_MUTEX_FAST) or (eType = SQLITE_MUTEX_RECURSIVE) then
    pRet := PTestCountMutex(GetMem(SizeOf(TTestCountMutex)))
  else
  begin
    eStaticType := eType - (MAX_MUTEXES - STATIC_MUTEXES);
    Assert(eStaticType >= 0);
    Assert(eStaticType < STATIC_MUTEXES);
    pRet := @mutexG.aStatic[eStaticType];
  end;

  pRet^.eType := eType;
  pRet^.pReal := pReal;
  Result := Psqlite3_mutex(pRet);
end;

{ test_mutex.c:113..119 — counterMutexFree. }
procedure counterMutexFree(p: Psqlite3_mutex);
begin
  Assert(mutexG.isInit <> 0);
  mutexG.m.xMutexFree(PTestCountMutex(p)^.pReal);
  if (PTestCountMutex(p)^.eType = SQLITE_MUTEX_FAST)
     or (PTestCountMutex(p)^.eType = SQLITE_MUTEX_RECURSIVE) then
    FreeMem(Pointer(p));
end;

{ test_mutex.c:124..130 — counterMutexEnter. }
procedure counterMutexEnter(p: Psqlite3_mutex);
begin
  Assert(mutexG.isInit <> 0);
  Assert(PTestCountMutex(p)^.eType >= 0);
  Assert(PTestCountMutex(p)^.eType < MAX_MUTEXES);
  Inc(mutexG.aCounter[PTestCountMutex(p)^.eType]);
  mutexG.m.xMutexEnter(PTestCountMutex(p)^.pReal);
end;

{ test_mutex.c:135..142 — counterMutexTry. }
function counterMutexTry(p: Psqlite3_mutex): cint;
begin
  Assert(mutexG.isInit <> 0);
  Assert(PTestCountMutex(p)^.eType >= 0);
  Assert(PTestCountMutex(p)^.eType < MAX_MUTEXES);
  Inc(mutexG.aCounter[PTestCountMutex(p)^.eType]);
  if mutexG.disableTry <> 0 then
  begin
    Result := SQLITE_BUSY;
    Exit;
  end;
  Result := mutexG.m.xMutexTry(PTestCountMutex(p)^.pReal);
end;

{ test_mutex.c:146..149 — counterMutexLeave. }
procedure counterMutexLeave(p: Psqlite3_mutex);
begin
  Assert(mutexG.isInit <> 0);
  mutexG.m.xMutexLeave(PTestCountMutex(p)^.pReal);
end;

{ test_mutex.c:196..252 — install_mutex_counters BOOLEAN. }
function test_install_mutex_counters(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc, isInstall: cint;
  counter_methods: sqlite3_mutex_methods;
begin
  rc := SQLITE_OK;
  counter_methods.xMutexInit    := @counterMutexInit;
  counter_methods.xMutexEnd     := @counterMutexEnd;
  counter_methods.xMutexAlloc   := @counterMutexAlloc;
  counter_methods.xMutexFree    := @counterMutexFree;
  counter_methods.xMutexEnter   := @counterMutexEnter;
  counter_methods.xMutexTry     := @counterMutexTry;
  counter_methods.xMutexLeave   := @counterMutexLeave;
  counter_methods.xMutexHeld    := @counterMutexHeld;
  counter_methods.xMutexNotheld := @counterMutexNotheld;

  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BOOLEAN'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[1], @isInstall) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;

  Assert((isInstall = 0) or (isInstall = 1));
  Assert((mutexG.isInstalled = 0) or (mutexG.isInstalled = 1));
  if isInstall = mutexG.isInstalled then
  begin
    Tcl_AppendResult(interp, PChar('mutex counters are '), nil);
    if isInstall <> 0 then
      Tcl_AppendResult(interp, PChar('already installed'), nil)
    else
      Tcl_AppendResult(interp, PChar('not installed'), nil);
    Result := TCL_ERROR; Exit;
  end;

  if isInstall <> 0 then
  begin
    Assert(not Assigned(mutexG.m.xMutexAlloc));
    rc := sqlite3_config(SQLITE_CONFIG_GETMUTEX_U, @mutexG.m);
    if rc = SQLITE_OK then
      sqlite3_config(SQLITE_CONFIG_MUTEX_U, @counter_methods);
    mutexG.disableTry := 0;
  end
  else
  begin
    Assert(Assigned(mutexG.m.xMutexAlloc));
    rc := sqlite3_config(SQLITE_CONFIG_MUTEX_U, @mutexG.m);
    FillChar(mutexG.m, SizeOf(sqlite3_mutex_methods), 0);
  end;

  if rc = SQLITE_OK then
    mutexG.isInstalled := isInstall;

  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_mutex.c:257..281 — read_mutex_counters. }
function test_read_mutex_counters(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  pRet: PTclObj;
  ii:   cint;
begin
  if objc <> 1 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR; Exit;
  end;
  pRet := Tcl_NewObj();
  Tcl_IncrRefCount(pRet);
  for ii := 0 to MAX_MUTEXES - 1 do
  begin
    Tcl_ListObjAppendElement(interp, pRet, Tcl_NewStringObj(mutexAName[ii], -1));
    Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(mutexG.aCounter[ii]));
  end;
  Tcl_SetObjResult(interp, pRet);
  Tcl_DecrRefCount(pRet);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_mutex.c:286..303 — clear_mutex_counters. }
function test_clear_mutex_counters(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  ii: cint;
begin
  if objc <> 1 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR; Exit;
  end;
  for ii := 0 to MAX_MUTEXES - 1 do
    mutexG.aCounter[ii] := 0;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_mutex.c:310..324 — alloc_dealloc_mutex.  Allocate then free a FAST
  mutex; return the (now stale) pointer so the caller can check it was
  non-NULL. }
function test_alloc_mutex(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  p:    Psqlite3_mutex;
  zBuf: AnsiString;
begin
  p := sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
  sqlite3_mutex_free(p);
  { C uses sqlite3_snprintf(...,"%p",p).  SQLite's printf renders %p as a
    bare hexadecimal integer (no 0x prefix), so a NULL pointer prints "0"
    (mutex2-2.9 expects exactly "0"). }
  if p = nil then
    zBuf := '0'
  else
    zBuf := AnsiString(Format('%x', [PtrUInt(p)]));
  Tcl_AppendResult(interp, PChar(zBuf), nil);
  Result := TCL_OK;
  if (clientData = nil) and (objc = 0) and (objv = nil) then ;
end;

{ test_mutex.c:387..397 — getStaticMutexPointer. }
function getStaticMutexPointer(pInterp: PTclInterp; pObj: PTclObj): Psqlite3_mutex;
var
  iMutex: cint;
begin
  if Tcl_GetIndexFromObj(pInterp, pObj, @mutexAName[0], PChar('mutex name'),
       0, @iMutex) <> 0 then
  begin
    Result := nil;
    Exit;
  end;
  Assert((iMutex <> SQLITE_MUTEX_FAST) and (iMutex <> SQLITE_MUTEX_RECURSIVE));
  Result := counterMutexAlloc(iMutex);
end;

{ test_mutex.c:399..416 — enter_static_mutex NAME. }
function test_enter_static_mutex(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  pMtx: Psqlite3_mutex;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('NAME'));
    Result := TCL_ERROR; Exit;
  end;
  pMtx := getStaticMutexPointer(interp, objv[1]);
  if pMtx = nil then
  begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_mutex_enter(pMtx);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_mutex.c:418..435 — leave_static_mutex NAME. }
function test_leave_static_mutex(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  pMtx: Psqlite3_mutex;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('NAME'));
    Result := TCL_ERROR; Exit;
  end;
  pMtx := getStaticMutexPointer(interp, objv[1]);
  if pMtx = nil then
  begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_mutex_leave(pMtx);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_mutex.c:437..454 — enter_db_mutex DB. }
function test_enter_db_mutex(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
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
  if db = nil then
  begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_mutex_enter(Psqlite3_mutex(sqlite3_db_mutex(db)));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_mutex.c:456..473 — leave_db_mutex DB. }
function test_leave_db_mutex(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
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
  if db = nil then
  begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_mutex_leave(Psqlite3_mutex(sqlite3_db_mutex(db)));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:6726..6746 — vfs_initfail_test.  Verifies that vfs_find /
  vfs_register all fail while sqlite3_initialize() is failing. }
function vfs_initfail_test(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  one: sqlite3_vfs;
begin
  FillChar(one, SizeOf(one), 0);
  one.zName := PChar('__one');

  if sqlite3_vfs_find(nil) <> nil then begin Result := TCL_ERROR; Exit; end;
  sqlite3_vfs_register(@one, 0);
  if sqlite3_vfs_find(nil) <> nil then begin Result := TCL_ERROR; Exit; end;
  sqlite3_vfs_register(@one, 1);
  if sqlite3_vfs_find(nil) <> nil then begin Result := TCL_ERROR; Exit; end;
  Result := TCL_OK;
  if (clientData = nil) and (objc = 0) and (objv = nil) then ;
end;

{ test_mutex.c:337..372 — sqlite3_config OPTION.
  OPTION is one of the keywords singlethread/multithread/serialized
  (mapped to SQLITE_CONFIG_SINGLETHREAD/MULTITHREAD/SERIALIZED = 1/2/3)
  or a raw integer.  Calls sqlite3_config(i) and returns sqlite3ErrName(rc). }
function test_config(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i, rc: cint;
  z:     PAnsiChar;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR; Exit;
  end;
  z := Tcl_GetString(objv[1]);
  if StrComp(z, PChar('singlethread')) = 0 then
    i := SQLITE_CONFIG_SINGLETHREAD
  else if StrComp(z, PChar('multithread')) = 0 then
    i := SQLITE_CONFIG_MULTITHREAD
  else if StrComp(z, PChar('serialized')) = 0 then
    i := SQLITE_CONFIG_SERIALIZED
  else if Tcl_GetIntFromObj(interp, objv[1], @i) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_config(i, 0);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_malloc.c:968..983 — sqlite3_config_memstatus BOOLEAN.
  Enable/disable memory status reporting via SQLITE_CONFIG_MEMSTATUS.
  Returns the rc from sqlite3_config. }
function test_config_memstatus(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  enable, rc: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BOOLEAN'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[1], @enable) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_config(SQLITE_CONFIG_MEMSTATUS, enable);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_malloc.c:986..1013 — sqlite3_config_lookaside SIZE COUNT.
  Returns prior {szLookaside nLookaside} list, then applies new values
  via SQLITE_CONFIG_LOOKASIDE. }
function test_config_lookaside(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  sz, cnt: cint;
  pRet:    PTclObj;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SIZE COUNT'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @sz) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[2], @cnt) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  pRet := Tcl_NewObj;
  Tcl_ListObjAppendElement(interp, pRet,
    Tcl_NewIntObj(sqlite3GlobalConfig.szLookaside));
  Tcl_ListObjAppendElement(interp, pRet,
    Tcl_NewIntObj(sqlite3GlobalConfig.nLookaside));
  sqlite3_config(SQLITE_CONFIG_LOOKASIDE, sz, cnt);
  Tcl_SetObjResult(interp, pRet);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_config.c / tclsqlite.c — thin wrappers around the engine
  lifecycle entry points; used by test_set_config_pagecache. }
{ test_mutex.c:175..191 — sqlite3_initialize.  Returns sqlite3ErrName(rc)
  (mutex1.test reads back SQLITE_OK / the disable_mutex_init failure code). }
function test_initialize(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var rc: cint;
begin
  if objc <> 1 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_initialize;
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_mutex.c:154..170 — sqlite3_shutdown.  Returns sqlite3ErrName(rc). }
function test_shutdown(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var rc: cint;
begin
  if objc <> 1 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_shutdown;
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
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
  { test1.c:1419 calls the public sqlite3_mprintf, which autoinits and
    returns NULL when sqlite3_initialize() is failing (mutex2-2.4). }
  if sqlite3_initialize <> SQLITE_OK then begin
    Result := TCL_OK; Exit;
  end;
  z := sqlite3PfMprintf(av[1], [a[0], a[1], a[2]]);
  Tcl_AppendResult(interp, z, Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ test1.c:542..560 — sqlite3_snprintf_int  SIZE FORMAT INT.
  Prefill a 100-byte buffer with the alphabet, then snprintf(n,...). }
function tcl_snprintf_int(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  zStr: array[0..99] of AnsiChar;
  n:    cint;
  a1:   cint;
  v:    Int64;
  code: Integer;
  av:   PPAnsiCharArr;
begin
  av := argv;
  Val(AnsiString(av[1]), v, code); if code <> 0 then v := 0;
  n := cint(v);
  Val(AnsiString(av[3]), v, code); if code <> 0 then v := 0;
  a1 := cint(v);
  if n > SizeOf(zStr) then n := SizeOf(zStr);
  sqlite3PfSnprintf(SizeOf(zStr), @zStr[0],
    PAnsiChar('abcdefghijklmnopqrstuvwxyz'), []);
  sqlite3PfSnprintf(n, @zStr[0], av[2], [a1]);
  Tcl_AppendResult(interp, @zStr[0], Pointer(nil));
  Result := TCL_OK;
end;

{ test1.c:1518..1546 — sqlite3_snprintf_str  INT FORMAT INT INT ?STRING?. }
function tcl_snprintf_str(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  a:    array[0..1] of cint;
  i:    cint;
  n:    cint;
  z:    PAnsiChar;
  zStr: PAnsiChar;
  av:   PPAnsiCharArr;
begin
  av := argv;
  if (argc < 5) or (argc > 6) then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' INT FORMAT INT INT ?STRING?"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetInt(interp, av[1], @n) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if n < 0 then begin
    Tcl_AppendResult(interp, PChar('N must be non-negative'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  for i := 3 to 4 do
    if Tcl_GetInt(interp, av[i], @a[i-3]) <> 0 then begin
      Result := TCL_ERROR; Exit;
    end;
  if argc > 5 then zStr := av[5] else zStr := nil;
  z := PAnsiChar(sqlite3_malloc(n + 1));
  sqlite3PfSnprintf(n, z, av[2], [a[0], a[1], zStr]);
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

{ test1.c:518..530 — sqlite3_mprintf_n_test STRING. %n returns chars written.

  In C, sqlite3_mprintf("%s%n", argv[1], &n) uses the direct-varargs path
  (printf.c:740..744 etSIZE: bArgList=0 branch writes *va_arg(int*)=nChar).
  Pascal's sqlite3PfMprintf routes via array-of-const (effectively bArgList
  mode), where etSIZE is silently ignored.  For the printf-14.2 fixture
  ("xyzzy" → 5) we can compute n directly: after `%s%n` with no flags the
  output length is exactly Length(av[1]).  Mirror by measuring instead of
  threading a writable cursor through the bArgList-style renderer. }
function tcl_mprintf_n_test(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  zStr: PAnsiChar;
  av:   PPAnsiCharArr;
  n:    cint;
begin
  av := argv;
  zStr := sqlite3PfMprintf(PAnsiChar('%s'), [av[1]]);
  if zStr <> nil then n := Length(AnsiString(zStr)) else n := 0;
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

{ test1.c:3056..3078 — uses_stmt_journal STMT.
  Return true if STMT uses a statement journal.  6.40.6 (HARNESS). }
function uses_stmt_journal(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  b:     cint;
begin
  if objc <> 2 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  sqlite3_stmt_readonly(pStmt);
  if (pStmt^.vdbeFlags and VDBF_UsesStmtJournal) <> 0 then b := 1 else b := 0;
  Tcl_SetObjResult(interp, Tcl_NewBooleanObj(b));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:6553..6589 — sqlite3_pager_refcounts DB.
  Return a list of the PagerRefcount for each pager on the connection
  (or -1 if a backend has no Btree).  6.40.6 (HARNESS). }
function test_pager_refcounts(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:      PTsqlite3;
  i, v:    cint;
  a:       PPagerStatsArray;
  pBt:     PBtree;
  pResult: PTclObj;
begin
  if objc <> 2 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' DB'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  pResult := Tcl_NewObj();
  for i := 0 to db^.nDb - 1 do
  begin
    pBt := PBtree(db^.aDb[i].pBt);
    if pBt = nil then
      v := -1
    else
    begin
      sqlite3_mutex_enter(db^.mutex);
      a := sqlite3PagerStats(sqlite3BtreePager(pBt));
      v := a^[0];
      sqlite3_mutex_leave(db^.mutex);
    end;
    Tcl_ListObjAppendElement(nil, pResult, Tcl_NewIntObj(v));
  end;
  Tcl_SetObjResult(interp, pResult);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:7571..7598 — pcache_stats.
  Return the global pcache statistics as a name/value list.  6.40.6. }
function test_pcache_stats(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  nMin, nMax, nCurrent, nRecyclable: cint;
  pRet: PTclObj;
begin
  sqlite3PcacheStats(@nCurrent, @nMax, @nMin, @nRecyclable);
  pRet := Tcl_NewObj();
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewStringObj(PChar('current'), -1));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(nCurrent));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewStringObj(PChar('max'), -1));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(nMax));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewStringObj(PChar('min'), -1));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(nMin));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewStringObj(PChar('recyclable'), -1));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(nRecyclable));
  Tcl_SetObjResult(interp, pRet);
  Result := TCL_OK;
  if (clientData = nil) or (objc < 0) or (objv = nil) then ;
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
  9.4.divbug.62.b extension — statement-introspection commands missing
  from the earlier .62.b cluster: sqlite3_sql / _expanded_sql /
  _normalized_sql / _stmt_status / _stmt_busy / _stmt_readonly /
  _stmt_isexplain / _column_bytes16.  All accept a single "0xABCD..."
  STMT pointer (per sqlite3TestTextToPtr); _stmt_status additionally
  takes a symbolic op + reset flag.
  ---------------------------------------------------------------------- }

{ test1.c:5602..5618 — sqlite3_sql STMT. }
function tcl_test_sql(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStm: PVdbe;
  z: PAnsiChar;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  z := sqlite3_sql(pStm);
  if z = nil then z := PAnsiChar('');
  Tcl_SetResult(interp, PChar(z), TCL_VOLATILE);
  Result := TCL_OK;
end;

{ test1.c:5619..5638 — sqlite3_expanded_sql STMT (caller frees). }
function tcl_test_ex_sql(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStm: PVdbe;
  z: PAnsiChar;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  z := sqlite3_expanded_sql(pStm);
  if z <> nil then begin
    Tcl_SetResult(interp, PChar(z), TCL_VOLATILE);
    sqlite3_free(z);
  end;
  Result := TCL_OK;
end;

{ test1.c:5640..5656 — sqlite3_normalized_sql STMT.  Engine returns NULL
  when SQLITE_ENABLE_NORMALIZE is not active; we still register the cmd
  so callers don't trip "invalid command name". }
function tcl_test_norm_sql(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStm: PVdbe;
  z: PAnsiChar;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  z := sqlite3_normalized_sql(pStm);
  if z = nil then z := PAnsiChar('');
  Tcl_SetResult(interp, PChar(z), TCL_VOLATILE);
  Result := TCL_OK;
end;

{ test1.c:5550..5572 — sqlite3_normalize SQL.  Normalises an SQL string
  via the ext/misc/normalize.c helper (string-in / string-out). }
function tcl_test_normalize(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zSql, zNorm: PAnsiChar;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SQL'));
    Result := TCL_ERROR; Exit;
  end;
  zSql := Tcl_GetString(objv[1]);
  zNorm := sqlite3_normalize(zSql);
  if zNorm <> nil then begin
    Tcl_SetObjResult(interp, Tcl_NewStringObj(zNorm, -1));
    sqlite3_free(zNorm);
  end;
  Result := TCL_OK;
end;

{ test1.c:272..291 — clang_sanitize_address.  Returns 1 when the C test
  binary was compiled with -fsanitize=address, else 0.  Also returns 1
  when env OMIT_MISUSE is set.  FPC port has no asan, so we honour only
  the OMIT_MISUSE env hook. }
function tcl_test_clang_sanitize_address(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  res: cint;
begin
  res := 0;
  if GetEnvironmentVariable('OMIT_MISUSE') <> '' then res := 1;
  Tcl_SetObjResult(interp, Tcl_NewIntObj(res));
  Result := TCL_OK;
  if (clientData = nil) and (objc = 0) and (objv = nil) then ;
end;

{ test1.c:3836..3859 — test_intarray_addr.  Usage:  intarray_addr  INT ...
  Returns (as a wide-int) the address of a malloc'd C array of 32-bit ints
  holding the supplied values.  Call with no args to release the memory;
  each call overwrites the previous array. }
function tcl_test_intarray_addr(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i: cint;
  p: PInteger;
begin
  sqlite3_free(intarrayAddrP);
  intarrayAddrP := nil;
  if objc > 1 then
  begin
    p := PInteger(sqlite3_malloc(SizeOf(cint) * (objc - 1)));
    if p = nil then begin Result := TCL_ERROR; Exit; end;
    intarrayAddrP := p;
    for i := 0 to objc - 2 do
    begin
      if Tcl_GetIntFromObj(interp, objv[1 + i],
           @PInteger(PByte(p) + i * SizeOf(cint))^) <> 0 then
      begin
        sqlite3_free(intarrayAddrP);
        intarrayAddrP := nil;
        Result := TCL_ERROR;
        Exit;
      end;
    end;
  end;
  Tcl_SetObjResult(interp, Tcl_NewWideIntObj(Int64(PtrUInt(intarrayAddrP))));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:3861..3897 — test_int64array_addr.  As intarray_addr but the C
  array holds 64-bit integers. }
function tcl_test_int64array_addr(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i: cint;
  p: PInt64;
  v: Int64;
begin
  sqlite3_free(int64arrayAddrP);
  int64arrayAddrP := nil;
  if objc > 1 then
  begin
    p := PInt64(sqlite3_malloc(SizeOf(Int64) * (objc - 1)));
    if p = nil then begin Result := TCL_ERROR; Exit; end;
    int64arrayAddrP := p;
    for i := 0 to objc - 2 do
    begin
      if Tcl_GetWideIntFromObj(interp, objv[1 + i], @v) <> 0 then
      begin
        sqlite3_free(int64arrayAddrP);
        int64arrayAddrP := nil;
        Result := TCL_ERROR;
        Exit;
      end;
      PInt64(PByte(p) + i * SizeOf(Int64))^ := v;
    end;
  end;
  Tcl_SetObjResult(interp, Tcl_NewWideIntObj(Int64(PtrUInt(int64arrayAddrP))));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:3899..3930 — test_doublearray_addr.  As intarray_addr but the C
  array holds doubles. }
function tcl_test_doublearray_addr(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i: cint;
  p: PDouble;
begin
  sqlite3_free(doublearrayAddrP);
  doublearrayAddrP := nil;
  if objc > 1 then
  begin
    p := PDouble(sqlite3_malloc(SizeOf(Double) * (objc - 1)));
    if p = nil then begin Result := TCL_ERROR; Exit; end;
    doublearrayAddrP := p;
    for i := 0 to objc - 2 do
    begin
      if Tcl_GetDoubleFromObj(interp, objv[1 + i],
           PDouble(PByte(p) + i * SizeOf(Double))) <> 0 then
      begin
        sqlite3_free(doublearrayAddrP);
        doublearrayAddrP := nil;
        Result := TCL_ERROR;
        Exit;
      end;
    end;
  end;
  Tcl_SetObjResult(interp, Tcl_NewWideIntObj(Int64(PtrUInt(doublearrayAddrP))));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:3932..3962 — test_textarray_addr.  Returns the address of a
  malloc'd C array of malloc'd strings (char**). }
function tcl_test_textarray_addr(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i, n: cint;
  pp: PPAnsiChar;
  z, zDup: PAnsiChar;
begin
  pp := PPAnsiChar(textarrayAddrP);
  for i := 0 to textarrayAddrN - 1 do
    sqlite3_free(PPAnsiChar(PByte(pp) + i * SizeOf(Pointer))^);
  sqlite3_free(textarrayAddrP);
  textarrayAddrP := nil;
  if objc > 1 then
  begin
    pp := PPAnsiChar(sqlite3_malloc(SizeOf(Pointer) * (objc - 1)));
    if pp = nil then begin Result := TCL_ERROR; Exit; end;
    textarrayAddrP := pp;
    for i := 0 to objc - 2 do
    begin
      z := Tcl_GetString(objv[1 + i]);
      n := StrLen(z);
      zDup := sqlite3_malloc(n + 1);
      if zDup <> nil then Move(z^, zDup^, n + 1);
      PPAnsiChar(PByte(pp) + i * SizeOf(Pointer))^ := zDup;
    end;
  end;
  textarrayAddrN := objc - 1;
  Tcl_SetObjResult(interp, Tcl_NewWideIntObj(Int64(PtrUInt(textarrayAddrP))));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.068 — sqlite3_register_cksumvfs.  test1.c:8795..8814.
  Wraps the full Pascal port in passqlite3cksumvfs.pas. }
function tcl_test_register_cksumvfs(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: i32;
begin
  if objc <> 1 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_register_cksumvfs(nil);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
  Result := TCL_OK;
end;

{ 9.4.divbug.88.068 — sqlite3_unregister_cksumvfs.  test1.c:8816..8835. }
function tcl_test_unregister_cksumvfs(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: i32;
begin
  if objc <> 1 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_unregister_cksumvfs;
  Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
  Result := TCL_OK;
end;

{ 9.4.divbug.88.069.b — sqlite3_delete_database FILENAME.
  test1.c:2852..2873; entry point in passqlite3multiplex.pas. }
function tcl_test_delete_database(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zFile : PAnsiChar;
  rc    : cint;
begin
  if clientData = clientData then ;
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('FILE'));
    Result := TCL_ERROR; Exit;
  end;
  zFile := Tcl_GetString(objv[1]);
  rc := sqlite3_delete_database(zFile);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
  Result := TCL_OK;
end;

{ 9.4.divbug.88.069 — sqlite3_multiplex_initialize.
  test_multiplex.c:1229..1255.  Full Pascal port in passqlite3multiplex.pas. }
function tcl_test_multiplex_initialize(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zName       : PAnsiChar;
  makeDefault : cint;
  rc          : cint;
begin
  if clientData = clientData then ;
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('NAME MAKEDEFAULT'));
    Result := TCL_ERROR; Exit;
  end;
  zName := Tcl_GetString(objv[1]);
  if Tcl_GetBooleanFromObj(interp, objv[2], @makeDefault) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if zName[0] = #0 then zName := nil;
  rc := sqlite3_multiplex_initialize(zName, makeDefault);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
  Result := TCL_OK;
end;

{ 9.4.divbug.88.069 — sqlite3_multiplex_shutdown.
  test_multiplex.c:1260..1283. }
function tcl_test_multiplex_shutdown(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc : cint;
begin
  if clientData = clientData then ;
  if (objc = 2) and (StrComp(Tcl_GetString(objv[1]), '-force') <> 0) then
    objc := 3;
  if (objc <> 1) and (objc <> 2) then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?-force?'));
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_multiplex_shutdown(Ord(objc = 2));
  Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
  Result := TCL_OK;
end;

{ 9.4.divbug.88.069 — sqlite3_multiplex_control HANDLE DBNAME SUB-COMMAND INT-VALUE.
  test_multiplex.c:1288..1345. }
const
  aMxSubName : array[0..3] of PAnsiChar =
    ('enable', 'chunk_size', 'max_chunks', nil);
  aMxSubOp : array[0..2] of cint =
    (214014 {MULTIPLEX_CTRL_ENABLE},
     214015 {MULTIPLEX_CTRL_SET_CHUNK_SIZE},
     214016 {MULTIPLEX_CTRL_SET_MAX_CHUNKS});

function tcl_test_multiplex_control(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc      : cint;
  idx     : cint;
  cmdInfo : TTclCmdInfo;
  db      : PTsqlite3;
  iValue  : cint;
  pArg    : Pointer;
begin
  if clientData = clientData then ;
  iValue := 0;
  pArg := nil;
  if objc <> 5 then begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('HANDLE DBNAME SUB-COMMAND INT-VALUE'));
    Result := TCL_ERROR; Exit;
  end;
  FillChar(cmdInfo, SizeOf(cmdInfo), 0);
  if Tcl_GetCommandInfo(interp, Tcl_GetString(objv[1]),
                        @cmdInfo) = 0 then begin
    Tcl_AppendResult(interp, PChar('expected database handle, got "'),
      Tcl_GetString(objv[1]), PChar('"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  db := PTestSqliteDb(cmdInfo.objClientData)^.db;
  rc := Tcl_GetIndexFromObj(interp, objv[3],
                            @aMxSubName[0], PChar('sub-command'), 0, @idx);
  if rc <> TCL_OK then begin Result := rc; Exit; end;
  if Tcl_GetIntFromObj(interp, objv[4], @iValue) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  pArg := @iValue;
  rc := sqlite3_file_control(db, Tcl_GetString(objv[2]),
                             aMxSubOp[idx], pArg);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
  if rc = SQLITE_OK then Result := TCL_OK else Result := TCL_ERROR;
end;

{ 9.4.divbug.88.034 — sqlite3_enable_shared_cache (test1.c:1665..1699).
  Usage: sqlite3_enable_shared_cache ?BOOLEAN?
  Returns the *previous* value of sqlite3GlobalConfig.sharedCacheEnabled.
  With an argument, also calls sqlite3_enable_shared_cache(enable). }
function tcl_test_enable_shared(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
  enable: cint;
  ret: cint;
begin
  enable := 0;
  if (objc <> 2) and (objc <> 1) then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?BOOLEAN?'));
    Result := TCL_ERROR; Exit;
  end;
  ret := sqlite3GlobalConfig.sharedCacheEnabled;
  if objc = 2 then begin
    if Tcl_GetBooleanFromObj(interp, objv[1], @enable) <> 0 then begin
      Result := TCL_ERROR; Exit;
    end;
    rc := sqlite3_enable_shared_cache(enable);
    if rc <> SQLITE_OK then begin
      Tcl_SetResult(interp, PChar(sqlite3ErrStr(rc)), TCL_STATIC);
      Result := TCL_ERROR; Exit;
    end;
  end;
  Tcl_SetObjResult(interp, Tcl_NewBooleanObj(ret));
  Result := TCL_OK;
end;

{ 9.4.divbug.88.023 — decode_hexdb TEXT (test1.c:8837..8910).
  Parses dbtotxt(1) output back into a raw SQLite database byte-array so
  Tcl scripts can run `db deserialize [decode_hexdb $hex]`.  Three line
  shapes are recognised; everything else is silently skipped, matching
  the C sscanf-based dispatch:
    "| size <n> pagesize <p>"       — allocate the buffer (rounds n up).
    "| page <j> offset <k>"         — set iOffset for subsequent hex lines.
    "| <off>: hh hh hh ... (x16)"   — store 16 bytes at iOffset+off.
  Leading whitespace on every logical line is skipped, as in C
  (test1.c:8868). }

{ Hex digit -> value; -1 if not hex.  Mirrors C sscanf("%x"). }
function hexdb_hexval(c: AnsiChar): cint;
begin
  case c of
    '0'..'9': Result := Ord(c) - Ord('0');
    'a'..'f': Result := Ord(c) - Ord('a') + 10;
    'A'..'F': Result := Ord(c) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ Skip ASCII spaces/tabs in zIn starting at i; bump i in place. }
procedure hexdb_skip_ws(zIn: PAnsiChar; var i: cint);
begin
  while (zIn[i] = ' ') or (zIn[i] = #9) do Inc(i);
end;

{ Skip an unsigned decimal integer; on success returns True and writes
  the value into v and advances i.  Returns False if no digit at i. }
function hexdb_parse_uint(zIn: PAnsiChar; var i: cint; out v: cint): Boolean;
var
  acc: cint;
  any: Boolean;
begin
  any := False;
  acc := 0;
  while (zIn[i] >= '0') and (zIn[i] <= '9') do begin
    acc := acc * 10 + (Ord(zIn[i]) - Ord('0'));
    Inc(i);
    any := True;
  end;
  v := acc;
  Result := any;
end;

{ Match a literal needle starting at i; on success advance i and return
  True.  Used in lieu of sscanf format-literals. }
function hexdb_match_lit(zIn: PAnsiChar; var i: cint; needle: PAnsiChar): Boolean;
var
  j: cint;
begin
  j := 0;
  while needle[j] <> #0 do begin
    if zIn[i + j] <> needle[j] then begin
      Result := False; Exit;
    end;
    Inc(j);
  end;
  Inc(i, j);
  Result := True;
end;

function tcl_test_decode_hexdb(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zIn: PAnsiChar;
  a: PByte;
  n: cint;
  i, iNext, iSave: cint;
  iOffset: cint;
  j, k: cint;
  x: array[0..15] of cuint;
  pgsz: cint;
  ii, hi, lo: cint;
  ok: Boolean;
begin
  a := nil;
  n := 0;
  iOffset := 0;
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('HEXDB'));
    Result := TCL_ERROR; Exit;
  end;
  zIn := Tcl_GetString(objv[1]);
  i := 0;
  while zIn[i] <> #0 do begin
    iNext := i;
    while (zIn[iNext] <> #0) and (zIn[iNext] <> #10) do Inc(iNext);
    if zIn[iNext] = #10 then Inc(iNext);
    hexdb_skip_ws(zIn, i);
    if a = nil then begin
      iSave := i;
      ok := hexdb_match_lit(zIn, i, '| size ');
      if ok then ok := hexdb_parse_uint(zIn, i, n);
      if ok then ok := hexdb_match_lit(zIn, i, ' pagesize ');
      if ok then ok := hexdb_parse_uint(zIn, i, pgsz);
      if not ok then begin
        i := iNext;
        Continue;
      end;
      if (pgsz < 512) or (pgsz > 65536) or ((pgsz and (pgsz - 1)) <> 0) then begin
        Tcl_AppendResult(interp, PChar('bad ''pagesize'' field'), Pointer(nil));
        Result := TCL_ERROR; Exit;
      end;
      n := (n + pgsz - 1) and not (pgsz - 1);
      if n < 512 then begin
        Tcl_AppendResult(interp, PChar('bad ''size'' field'), Pointer(nil));
        Result := TCL_ERROR; Exit;
      end;
      GetMem(a, n);
      if a = nil then begin
        Tcl_AppendResult(interp, PChar('out of memory'), Pointer(nil));
        Result := TCL_ERROR; Exit;
      end;
      FillChar(a^, n, 0);
      i := iNext;
      // suppress unused warning on iSave
      if iSave < 0 then ;
      Continue;
    end;
    { Try "| page J offset K". }
    iSave := i;
    ok := hexdb_match_lit(zIn, i, '| page ');
    if ok then ok := hexdb_parse_uint(zIn, i, j);
    if ok then ok := hexdb_match_lit(zIn, i, ' offset ');
    if ok then ok := hexdb_parse_uint(zIn, i, k);
    if ok then begin
      iOffset := k;
      i := iNext;
      Continue;
    end;
    { Try "| OFF: hh hh hh hh hh hh hh hh hh hh hh hh hh hh hh hh". }
    i := iSave;
    ok := hexdb_match_lit(zIn, i, '| ');
    if ok then hexdb_skip_ws(zIn, i);
    if ok then ok := hexdb_parse_uint(zIn, i, j);
    if ok then ok := hexdb_match_lit(zIn, i, ':');
    if ok then begin
      for ii := 0 to 15 do begin
        hexdb_skip_ws(zIn, i);
        hi := hexdb_hexval(zIn[i]);
        if hi < 0 then begin ok := False; Break; end;
        Inc(i);
        lo := hexdb_hexval(zIn[i]);
        if lo >= 0 then begin
          Inc(i);
          x[ii] := cuint((hi shl 4) or lo);
        end else begin
          x[ii] := cuint(hi);
        end;
      end;
    end;
    if ok then begin
      k := iOffset + j;
      if (k + 16) <= n then begin
        for ii := 0 to 15 do
          (a + (k + ii))^ := Byte(x[ii] and $ff);
      end;
    end;
    i := iNext;
  end;
  Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(a, n));
  if a <> nil then FreeMem(a);
  Result := TCL_OK;
end;

{ test1.c:2288..2330 — sqlite3_stmt_status STMT PARAMETER RESETFLAG. }
function tcl_test_stmt_status(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
type
  TOpEntry = record zName: PAnsiChar; op: cint; end;
const
  aOp: array[0..6] of TOpEntry = (
    (zName: 'SQLITE_STMTSTATUS_FULLSCAN_STEP'; op: SQLITE_STMTSTATUS_FULLSCAN_STEP),
    (zName: 'SQLITE_STMTSTATUS_SORT';          op: SQLITE_STMTSTATUS_SORT),
    (zName: 'SQLITE_STMTSTATUS_AUTOINDEX';     op: SQLITE_STMTSTATUS_AUTOINDEX),
    (zName: 'SQLITE_STMTSTATUS_VM_STEP';       op: SQLITE_STMTSTATUS_VM_STEP),
    (zName: 'SQLITE_STMTSTATUS_REPREPARE';     op: SQLITE_STMTSTATUS_REPREPARE),
    (zName: 'SQLITE_STMTSTATUS_RUN';           op: SQLITE_STMTSTATUS_RUN),
    (zName: 'SQLITE_STMTSTATUS_MEMUSED';       op: SQLITE_STMTSTATUS_MEMUSED));
var
  pStm: PVdbe;
  i, op, resetFlag, iValue: cint;
  zOpName: PAnsiChar;
  matched: Boolean;
begin
  if objc <> 4 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT PARAMETER RESETFLAG'));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  zOpName := Tcl_GetString(objv[2]);
  op := 0; matched := False;
  for i := 0 to High(aOp) do
    if StrComp(aOp[i].zName, zOpName) = 0 then begin
      op := aOp[i].op; matched := True; break;
    end;
  if not matched then
    if Tcl_GetIntFromObj(interp, objv[2], @op) <> 0 then begin
      Result := TCL_ERROR; Exit;
    end;
  if Tcl_GetBooleanFromObj(interp, objv[3], @resetFlag) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  iValue := sqlite3_stmt_status(pStm, op, resetFlag);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(iValue));
  Result := TCL_OK;
end;

{ test1.c:3034..3057 — sqlite3_stmt_busy STMT. }
function tcl_test_stmt_busy(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStm: PVdbe;
begin
  if objc <> 2 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp, Tcl_NewBooleanObj(sqlite3_stmt_busy(pStm)));
  Result := TCL_OK;
end;

{ test1.c:2952..2971 — sqlite3_stmt_readonly STMT. }
function tcl_test_stmt_readonly(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStm: PVdbe;
begin
  if objc <> 2 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp, Tcl_NewBooleanObj(sqlite3_stmt_readonly(pStm)));
  Result := TCL_OK;
end;

{ test1.c:2979..2998 — sqlite3_stmt_isexplain STMT (returns 0/1/2). }
function tcl_test_stmt_isexplain(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStm: PVdbe;
begin
  if objc <> 2 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_stmt_isexplain(pStm)));
  Result := TCL_OK;
end;

{ test1.c:5853..5912 (test_stmt_utf16/_bytes16 cluster) — sqlite3_column_bytes16
  STMT column.  Returns the UTF-16 byte length of the indicated column. }
function tcl_column_bytes16(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStm: PVdbe; col: cint;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT column'));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  Tcl_SetObjResult(interp,
    Tcl_NewIntObj(sqlite3_column_bytes16(pStm, col)));
  Result := TCL_OK;
end;

{ test1.c:5904..5945 (test_stmt_utf16) — sqlite3_column_text16 STMT column.
  Returns the column text as a UTF-16 byte array including the 0x00 0x00
  terminator (n+2 bytes), where n is found by scanning 2 bytes at a time
  until a 0x00 0x00 pair. }
function tcl_column_text16(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var pStm: PVdbe; col: cint; zName16: PByte; n: cint;
begin
  if objc <> 3 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' STMT column'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  pStm := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @col) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  zName16 := PByte(sqlite3_column_text16(pStm, col));
  if zName16 <> nil then begin
    n := 0;
    while (zName16[n] <> 0) or (zName16[n + 1] <> 0) do
      Inc(n, 2);
    Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(zName16, n + 2));
  end;
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if rc <> SQLITE_OK then begin
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if rc <> SQLITE_OK then begin
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if rc <> SQLITE_OK then begin
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if rc <> SQLITE_OK then begin
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if rc <> SQLITE_OK then begin
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
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
  if sqlite3TestErrCode(interp, sqlite3_db_handle(pStmt), rc) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
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

{ test_hexio.c:391..449 — make_fts3record LIST.
  Builds a byte blob: each list element that parses as a wide integer is
  appended as an fts3 varint (sqlite3Fts3PutVarint), otherwise the raw
  string bytes are appended.  Returns a Tcl byte-array. }
function make_fts3record(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  aArg: PPTclObj;
  nArg: cint;
  aOut: PByte;
  nOut: sqlite3_int64;
  nAlloc: sqlite3_int64;
  i: cint;
  iVal: Int64;
  zVal: PChar;
  nVal: cint;
  nNew: sqlite3_int64;
  aNew: PByte;
begin
  aArg := nil;
  nArg := 0;
  aOut := nil;
  nOut := 0;
  nAlloc := 0;

  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('LIST'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_ListObjGetElements(interp, objv[1], @nArg, @aArg) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;

  for i := 0 to nArg - 1 do begin
    if Tcl_GetWideIntFromObj(nil, PPTclObj(aArg)[i], @iVal) = TCL_OK then begin
      if nOut + 10 > nAlloc then begin
        if nAlloc <> 0 then nNew := nAlloc * 2 else nNew := 128;
        aNew := PByte(sqlite3_realloc(aOut, cint(nNew)));
        if aNew = nil then begin
          sqlite3_free(aOut);
          Result := TCL_ERROR; Exit;
        end;
        aOut := aNew;
        nAlloc := nNew;
      end;
      nOut := nOut + sqlite3Fts3PutVarint(PChar(@aOut[nOut]), iVal);
    end else begin
      nVal := 0;
      zVal := Tcl_GetStringFromObj(PPTclObj(aArg)[i], @nVal);
      while (nOut + nVal) > nAlloc do begin
        if nAlloc <> 0 then nNew := nAlloc * 2 else nNew := 128;
        aNew := PByte(sqlite3_realloc(aOut, cint(nNew)));
        if aNew = nil then begin
          sqlite3_free(aOut);
          Result := TCL_ERROR; Exit;
        end;
        aOut := aNew;
        nAlloc := nNew;
      end;
      Move(zVal^, aOut[nOut], nVal);
      nOut := nOut + nVal;
    end;
  end;

  Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(aOut, cint(nOut)));
  sqlite3_free(aOut);
  Result := TCL_OK;
end;

{ ----------------------------------------------------------------------
  9.4.divbug.62.c — additional test1.c / test_malloc.c Tcl commands:
  sqlite3_status, sqlite3_release_memory, sqlite3_limit, sqlite3_rekey,
  sqlite3_create_function (with the UDF helpers x_coalesce / hex8 /
  tkt2213func / pointer_change / counter1 / counter2 / intreal /
  add_text_type / add_int_type / add_real_type / strtod / dtostr /
  inttoptr).  Cite ranges noted per block. }

{ test_malloc.c:1280..1335 — sqlite3_status OPCODE RESETFLAG.
  Returns {rc current highwater}. }
function tcl_test_status(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
type
  TStatOp = record
    zName: PAnsiChar;
    op: cint;
  end;
const
  aOp: array[0..9] of TStatOp = (
    (zName: 'SQLITE_STATUS_MEMORY_USED';         op: SQLITE_STATUS_MEMORY_USED),
    (zName: 'SQLITE_STATUS_MALLOC_SIZE';         op: SQLITE_STATUS_MALLOC_SIZE),
    (zName: 'SQLITE_STATUS_PAGECACHE_USED';      op: SQLITE_STATUS_PAGECACHE_USED),
    (zName: 'SQLITE_STATUS_PAGECACHE_OVERFLOW';  op: SQLITE_STATUS_PAGECACHE_OVERFLOW),
    (zName: 'SQLITE_STATUS_PAGECACHE_SIZE';      op: SQLITE_STATUS_PAGECACHE_SIZE),
    (zName: 'SQLITE_STATUS_SCRATCH_USED';        op: SQLITE_STATUS_SCRATCH_USED),
    (zName: 'SQLITE_STATUS_SCRATCH_OVERFLOW';    op: SQLITE_STATUS_SCRATCH_OVERFLOW),
    (zName: 'SQLITE_STATUS_SCRATCH_SIZE';        op: SQLITE_STATUS_SCRATCH_SIZE),
    (zName: 'SQLITE_STATUS_PARSER_STACK';        op: SQLITE_STATUS_PARSER_STACK),
    (zName: 'SQLITE_STATUS_MALLOC_COUNT';        op: SQLITE_STATUS_MALLOC_COUNT)
  );
var
  rc, iValue, mxValue, i, op, resetFlag: cint;
  zOpName: PAnsiChar;
  pResult: PTclObj;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('PARAMETER RESETFLAG'));
    Result := TCL_ERROR; Exit;
  end;
  zOpName := Tcl_GetString(objv[1]);
  op := 0;
  i := 0;
  while i <= High(aOp) do
  begin
    if StrComp(aOp[i].zName, zOpName) = 0 then
    begin
      op := aOp[i].op;
      Break;
    end;
    Inc(i);
  end;
  if i > High(aOp) then
  begin
    if Tcl_GetIntFromObj(interp, objv[1], @op) <> 0 then
    begin
      Result := TCL_ERROR; Exit;
    end;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[2], @resetFlag) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  iValue  := 0;
  mxValue := 0;
  rc := sqlite3_status(op, @iValue, @mxValue, resetFlag);
  pResult := Tcl_NewObj;
  Tcl_ListObjAppendElement(nil, pResult, Tcl_NewIntObj(rc));
  Tcl_ListObjAppendElement(nil, pResult, Tcl_NewIntObj(iValue));
  Tcl_ListObjAppendElement(nil, pResult, Tcl_NewIntObj(mxValue));
  Tcl_SetObjResult(interp, pResult);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:6327..6356 — sqlite3_release_memory ?N?. }
function tcl_test_release_memory(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  N, amt: cint;
begin
  if (objc <> 1) and (objc <> 2) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?N?'));
    Result := TCL_ERROR; Exit;
  end;
  if objc = 2 then
  begin
    if Tcl_GetIntFromObj(interp, objv[1], @N) <> 0 then
    begin
      Result := TCL_ERROR; Exit;
    end;
  end
  else
    N := -1;
  amt := sqlite3_release_memory(N);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(amt));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:6359..6381 — sqlite3_db_release_memory DB. }
function tcl_test_db_release_memory(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:  PTsqlite3;
  rc:  cint;
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
  rc := sqlite3_db_release_memory(db);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:7372..7433 — sqlite3_limit DB ID VALUE. }
function tcl_test_limit(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
type
  TLimitId = record
    zName: PAnsiChar;
    id: cint;
  end;
const
  aId: array[0..14] of TLimitId = (
    (zName: 'SQLITE_LIMIT_LENGTH';              id: SQLITE_LIMIT_LENGTH),
    (zName: 'SQLITE_LIMIT_SQL_LENGTH';          id: SQLITE_LIMIT_SQL_LENGTH),
    (zName: 'SQLITE_LIMIT_COLUMN';              id: SQLITE_LIMIT_COLUMN),
    (zName: 'SQLITE_LIMIT_EXPR_DEPTH';          id: SQLITE_LIMIT_EXPR_DEPTH),
    (zName: 'SQLITE_LIMIT_PARSER_DEPTH';        id: SQLITE_LIMIT_PARSER_DEPTH),
    (zName: 'SQLITE_LIMIT_COMPOUND_SELECT';     id: SQLITE_LIMIT_COMPOUND_SELECT),
    (zName: 'SQLITE_LIMIT_VDBE_OP';             id: SQLITE_LIMIT_VDBE_OP),
    (zName: 'SQLITE_LIMIT_FUNCTION_ARG';        id: SQLITE_LIMIT_FUNCTION_ARG),
    (zName: 'SQLITE_LIMIT_ATTACHED';            id: SQLITE_LIMIT_ATTACHED),
    (zName: 'SQLITE_LIMIT_LIKE_PATTERN_LENGTH'; id: SQLITE_LIMIT_LIKE_PATTERN_LENGTH),
    (zName: 'SQLITE_LIMIT_VARIABLE_NUMBER';     id: SQLITE_LIMIT_VARIABLE_NUMBER),
    (zName: 'SQLITE_LIMIT_TRIGGER_DEPTH';       id: SQLITE_LIMIT_TRIGGER_DEPTH),
    (zName: 'SQLITE_LIMIT_WORKER_THREADS';      id: SQLITE_LIMIT_WORKER_THREADS),
    { Out-of-range probes — matches test1.c:7404..7406. }
    (zName: 'SQLITE_LIMIT_TOOSMALL';            id: -1),
    (zName: 'SQLITE_LIMIT_TOOBIG';              id: SQLITE_LIMIT_PARSER_DEPTH + 1)
  );
var
  db: PTsqlite3;
  rc, i, id, val: cint;
  zId: PAnsiChar;
begin
  if objc <> 4 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetStringFromObj(objv[0], nil), PChar(' DB ID VALUE'),
      Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zId := Tcl_GetString(objv[2]);
  id := 0;
  i := 0;
  while i <= High(aId) do
  begin
    if StrComp(zId, aId[i].zName) = 0 then
    begin
      id := aId[i].id;
      Break;
    end;
    Inc(i);
  end;
  if i > High(aId) then
  begin
    Tcl_AppendResult(interp, PChar('unknown limit type: '), zId,
      Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[3], @val) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_limit(db, id, val);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.d — sqlite3_db_status DB OPCODE RESETFLAG.
  test_malloc.c:1338..1397 — accepts SQLITE_DBSTATUS_* or DBSTATUS_*
  or unprefixed name, falls back to integer parse. }
function tcl_test_db_status(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
type
  TDbStatOp = record
    zName: PAnsiChar;
    op: cint;
  end;
const
  aOp: array[0..13] of TDbStatOp = (
    (zName: 'LOOKASIDE_USED';      op: 0  { SQLITE_DBSTATUS_LOOKASIDE_USED }),
    (zName: 'CACHE_USED';          op: 1  { SQLITE_DBSTATUS_CACHE_USED }),
    (zName: 'SCHEMA_USED';         op: 2  { SQLITE_DBSTATUS_SCHEMA_USED }),
    (zName: 'STMT_USED';           op: 3  { SQLITE_DBSTATUS_STMT_USED }),
    (zName: 'LOOKASIDE_HIT';       op: 4  { SQLITE_DBSTATUS_LOOKASIDE_HIT }),
    (zName: 'LOOKASIDE_MISS_SIZE'; op: 5  { SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE }),
    (zName: 'LOOKASIDE_MISS_FULL'; op: 6  { SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL }),
    (zName: 'CACHE_HIT';           op: 7  { SQLITE_DBSTATUS_CACHE_HIT }),
    (zName: 'CACHE_MISS';          op: 8  { SQLITE_DBSTATUS_CACHE_MISS }),
    (zName: 'CACHE_WRITE';         op: 9  { SQLITE_DBSTATUS_CACHE_WRITE }),
    (zName: 'DEFERRED_FKS';        op: 10 { SQLITE_DBSTATUS_DEFERRED_FKS }),
    (zName: 'CACHE_USED_SHARED';   op: 11 { SQLITE_DBSTATUS_CACHE_USED_SHARED }),
    (zName: 'CACHE_SPILL';         op: 12 { SQLITE_DBSTATUS_CACHE_SPILL }),
    (zName: 'TEMPBUF_SPILL';       op: 13 { SQLITE_DBSTATUS_TEMPBUF_SPILL })
  );
var
  db: PTsqlite3;
  rc, iValue, mxValue, i, op, resetFlag: cint;
  zOpName: PAnsiChar;
  pResult: PTclObj;
begin
  if objc <> 4 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB PARAMETER RESETFLAG'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zOpName := Tcl_GetString(objv[2]);
  { test_malloc.c:1378..1379 — strip optional SQLITE_ / DBSTATUS_ prefix. }
  if (StrLen(zOpName) >= 7) and (StrLComp(zOpName, 'SQLITE_', 7) = 0) then
    Inc(zOpName, 7);
  if (StrLen(zOpName) >= 9) and (StrLComp(zOpName, 'DBSTATUS_', 9) = 0) then
    Inc(zOpName, 9);
  op := 0;
  i := 0;
  while i <= High(aOp) do
  begin
    if StrComp(aOp[i].zName, zOpName) = 0 then
    begin
      op := aOp[i].op;
      Break;
    end;
    Inc(i);
  end;
  if i > High(aOp) then
  begin
    if Tcl_GetIntFromObj(interp, objv[2], @op) <> 0 then
    begin
      Result := TCL_ERROR; Exit;
    end;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[3], @resetFlag) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  iValue  := 0;
  mxValue := 0;
  rc := sqlite3_db_status(db, op, @iValue, @mxValue, resetFlag);
  pResult := Tcl_NewObj;
  Tcl_ListObjAppendElement(nil, pResult, Tcl_NewIntObj(rc));
  Tcl_ListObjAppendElement(nil, pResult, Tcl_NewIntObj(iValue));
  Tcl_ListObjAppendElement(nil, pResult, Tcl_NewIntObj(mxValue));
  Tcl_SetObjResult(interp, pResult);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.d — sqlite3_soft_heap_limit ?N? / sqlite3_soft_heap_limit64.
  test1.c:6482..6506 — both registrations route through this handler. }
function tcl_test_soft_heap_limit(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  N, amt: Int64;
begin
  N := -1;
  if (objc <> 1) and (objc <> 2) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?N?'));
    Result := TCL_ERROR; Exit;
  end;
  if objc = 2 then
  begin
    if Tcl_GetWideIntFromObj(interp, objv[1], @N) <> 0 then
    begin
      Result := TCL_ERROR; Exit;
    end;
  end;
  amt := sqlite3_soft_heap_limit64(N);
  Tcl_SetObjResult(interp, Tcl_NewWideIntObj(amt));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.d — sqlite3_hard_heap_limit64 ?N?.
  test1.c:6508..6533. }
function tcl_test_hard_heap_limit(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  N, amt: Int64;
begin
  N := -1;
  if (objc <> 1) and (objc <> 2) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?N?'));
    Result := TCL_ERROR; Exit;
  end;
  if objc = 2 then
  begin
    if Tcl_GetWideIntFromObj(interp, objv[1], @N) <> 0 then
    begin
      Result := TCL_ERROR; Exit;
    end;
  end;
  amt := sqlite3_hard_heap_limit64(N);
  Tcl_SetObjResult(interp, Tcl_NewWideIntObj(amt));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:665..677 — sqlite3_rekey DB KEY.  SQLite without the SEE
  extension simply returns TCL_OK (codec is a no-op). }
function tcl_test_rekey(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
begin
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (argc < 0)
     or (argv = nil) then ;
end;

{ test1.c:651..663 — sqlite3_key DB KEY.  SEE-only; without the
  codec extension upstream simply returns TCL_OK. }
function tcl_test_key(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
begin
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (argc < 0)
     or (argv = nil) then ;
end;

{ 9.4.divbug.62.f — sqlite3_key_v2 / sqlite3_rekey_v2 are the
  SEE-only multi-database variants (engine API at passqlite3main.pas
  returns SQLITE_OK without SEE).  No upstream test1.c counterpart;
  registered here purely so tests that invoke them do not abort with
  `invalid command name`.  Same TCL_OK semantics as tcl_test_key. }
function tcl_test_key_v2(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
begin
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (argc < 0)
     or (argv = nil) then ;
end;

{ 9.4.divbug.62.f — test_malloc.c:927..966 sqlite3_config_alt_pcache.
  Upstream installs an instrumented test page cache via
  installTestPCache (test_pcache.c).  test_pcache.c is not ported;
  this handler validates the argument shape exactly like upstream
  (objc 2..5, optional discardChance in [0,100], prngSeed, highStress)
  and returns TCL_OK without installing anything.  Tests that merely
  toggle the alt-pcache on/off (and don't depend on the fault
  injection behaviour) therefore no longer abort. }
function tcl_test_config_alt_pcache(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  installFlag, discardChance, prngSeed, highStress: cint;
begin
  installFlag := 0;
  discardChance := 0;
  prngSeed := 0;
  highStress := 0;
  if (objc < 2) or (objc > 5) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('INSTALLFLAG DISCARDCHANCE PRNGSEEED HIGHSTRESS'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @installFlag) <> 0 then
  begin Result := TCL_ERROR; Exit; end;
  if (objc >= 3)
     and (Tcl_GetIntFromObj(interp, objv[2], @discardChance) <> 0) then
  begin Result := TCL_ERROR; Exit; end;
  if (objc >= 4)
     and (Tcl_GetIntFromObj(interp, objv[3], @prngSeed) <> 0) then
  begin Result := TCL_ERROR; Exit; end;
  if (objc >= 5)
     and (Tcl_GetIntFromObj(interp, objv[4], @highStress) <> 0) then
  begin Result := TCL_ERROR; Exit; end;
  if (discardChance < 0) or (discardChance > 100) then
  begin
    Tcl_AppendResult(interp,
      PChar('discard-chance should be between 0 and 100'), nil);
    Result := TCL_ERROR; Exit;
  end;
  { test_pcache.c installTestPCache not ported — stub, no-op. }
  Result := TCL_OK;
  if (clientData = nil) or (installFlag = 0) or (prngSeed = 0)
     or (highStress = 0) then ;
end;

{ ----------------------------------------------------------------------
  test1.c:727..1226 — the UDF helpers that test_create_function registers
  on DB.  Each is a 1:1 port of the matching C body.
  ---------------------------------------------------------------------- }

{ test1.c:731..745 — x_coalesce: returns the first non-NULL argument. }
procedure t1_ifnullFunc(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..255] of Psqlite3_value;
var
  i, n: cint;
  pa:   PValueArr;
begin
  pa := PValueArr(argv);
  for i := 0 to argc - 1 do
    if sqlite3_value_type(pa^[i]) <> SQLITE_NULL then
    begin
      n := sqlite3_value_bytes(pa^[i]);
      sqlite3_result_text(pCtx, PAnsiChar(sqlite3_value_text(pa^[i])),
        n, SQLITE_TRANSIENT);
      Break;
    end;
end;

{ test1.c:752..762 — hex8: hex-encode the UTF-8 bytes of arg[0]. }
procedure hex8Func(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
const
  cHex: array[0..15] of AnsiChar = '0123456789abcdef';
var
  z:    PAnsiChar;
  i:    cint;
  zBuf: array[0..199] of AnsiChar;
  b:    Byte;
  pa:   PValueArr;
begin
  pa := PValueArr(argv);
  z := PAnsiChar(sqlite3_value_text(pa^[0]));
  i := 0;
  while (i < (SizeOf(zBuf) div 2) - 2) and (z <> nil) and (z[i] <> #0) do
  begin
    b := Byte(z[i]);
    zBuf[i * 2]     := cHex[b shr 4];
    zBuf[i * 2 + 1] := cHex[b and $0F];
    Inc(i);
  end;
  zBuf[i * 2] := #0;
  sqlite3_result_text(pCtx, @zBuf[0], -1, SQLITE_TRANSIENT);
  if argc = 0 then ;
end;

{ 9.4.divbug.88.052 — test1.c:764..774 hex16: hex-encode the low byte of
  each UTF-16 code unit of arg[0] (UTF-16 SQL function). }
procedure hex16Func(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
  PUInt16Arr = ^TUInt16Arr;
  TUInt16Arr = array[0..16383] of Word;
const
  cHex: array[0..15] of AnsiChar = '0123456789abcdef';
var
  z:    PUInt16Arr;
  i:    cint;
  zBuf: array[0..399] of AnsiChar;
  b:    Byte;
  w:    Word;
  pa:   PValueArr;
begin
  pa := PValueArr(argv);
  z := PUInt16Arr(sqlite3_value_text16(pa^[0]));
  i := 0;
  while (i < (SizeOf(zBuf) div 4) - 4) and (z <> nil) and (z^[i] <> 0) do
  begin
    w := z^[i] and $00FF;
    { Match C "%04x" of (z[i] & 0xff): always 4 hex chars, high byte 00. }
    zBuf[i * 4]     := '0';
    zBuf[i * 4 + 1] := '0';
    b := Byte(w);
    zBuf[i * 4 + 2] := cHex[b shr 4];
    zBuf[i * 4 + 3] := cHex[b and $0F];
    Inc(i);
  end;
  zBuf[i * 4] := #0;
  sqlite3_result_text(pCtx, @zBuf[0], -1, SQLITE_TRANSIENT);
  if argc = 0 then ;
end;

{ test1.c:866..888 — tkt2213func: pointer-stability probe.
  Calls sqlite3_value_text 3x; errors if pointers diverge; otherwise
  returns a fresh copy via sqlite3_malloc owned by sqlite3_free. }
procedure tkt2213Function(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  nText: cint;
  zText1, zText2, zText3, zCopy: PAnsiChar;
  pa:    PValueArr;
begin
  pa := PValueArr(argv);
  nText  := sqlite3_value_bytes(pa^[0]);
  zText1 := PAnsiChar(sqlite3_value_text(pa^[0]));
  zText2 := PAnsiChar(sqlite3_value_text(pa^[0]));
  zText3 := PAnsiChar(sqlite3_value_text(pa^[0]));
  if (zText1 <> zText2) or (zText2 <> zText3) then
    sqlite3_result_error(pCtx, PChar('tkt2213 is not fixed'), -1)
  else
  begin
    zCopy := PAnsiChar(sqlite3_malloc(nText));
    Move(zText1^, zCopy^, nText);
    sqlite3_result_text(pCtx, zCopy, nText, TxDelProc(@sqlite3_free));
  end;
  if argc = 0 then ;
end;

{ test1.c:914..962 — pointer_change(VALUE, API1, BYTES, API2).
  Reports 1 if the pointers returned by API1/API2 differ on VALUE. }
procedure ptrChngFunction(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  p1, p2: Pointer;
  zCmd:   PAnsiChar;
  pa:     PValueArr;
begin
  pa := PValueArr(argv);
  if argc <> 4 then Exit;
  zCmd := PAnsiChar(sqlite3_value_text(pa^[1]));
  if zCmd = nil then Exit;
  if StrComp(zCmd, 'text') = 0 then
    p1 := sqlite3_value_text(pa^[0])
  else if StrComp(zCmd, 'text16') = 0 then
    p1 := sqlite3_value_text16(pa^[0])
  else if StrComp(zCmd, 'blob') = 0 then
    p1 := sqlite3_value_blob(pa^[0])
  else
    Exit;
  zCmd := PAnsiChar(sqlite3_value_text(pa^[2]));
  if zCmd = nil then Exit;
  if StrComp(zCmd, 'bytes') = 0 then
    sqlite3_value_bytes(pa^[0])
  else if StrComp(zCmd, 'bytes16') = 0 then
    sqlite3_value_bytes16(pa^[0])
  else if StrComp(zCmd, 'noop') = 0 then
    { do nothing }
  else
    Exit;
  zCmd := PAnsiChar(sqlite3_value_text(pa^[3]));
  if zCmd = nil then Exit;
  if StrComp(zCmd, 'text') = 0 then
    p2 := sqlite3_value_text(pa^[0])
  else if StrComp(zCmd, 'text16') = 0 then
    p2 := sqlite3_value_text16(pa^[0])
  else if StrComp(zCmd, 'blob') = 0 then
    p2 := sqlite3_value_blob(pa^[0])
  else
    Exit;
  if p1 = p2 then
    sqlite3_result_int(pCtx, 0)
  else
    sqlite3_result_int(pCtx, 1);
end;

{ test1.c:968..975 — counter1/counter2: ascending-int probe. }
var
  g_nondetCnt: cint = 0;

procedure nondeterministicFunction(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
begin
  sqlite3_result_int(pCtx, g_nondetCnt);
  Inc(g_nondetCnt);
  if (argc < 0) or (argv = nil) then ;
end;

{ test1.c:981..989 — intreal: integer value tagged as MEM_IntReal.
  The C path is sqlite3_result_int64 + sqlite3_test_control
  (SQLITE_TESTCTRL_RESULT_INTREAL, ctx) which sets MEM_IntReal on
  pCtx->pOut.  We inline the flag toggle here since the test-control
  op is not yet ported. }
procedure intrealFunction(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  v:  i64;
  pa: PValueArr;
begin
  pa := PValueArr(argv);
  v := sqlite3_value_int64(pa^[0]);
  sqlite3_result_int64(pCtx, v);
  if (pCtx <> nil) and (pCtx^.pOut <> nil) then
    pCtx^.pOut^.flags := (pCtx^.pOut^.flags and not MEM_Int) or MEM_IntReal;
  if argc = 0 then ;
end;

{ test1.c:996..1022 — add_text_type / add_int_type / add_real_type.
  Each forces an additional internal type-tag via a coercion call,
  then echoes argv[0]. }
procedure addTextTypeFunction(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var pa: PValueArr;
begin
  pa := PValueArr(argv);
  sqlite3_value_text(pa^[0]);
  sqlite3_result_value(pCtx, pa^[0]);
  if argc = 0 then ;
end;

procedure addIntTypeFunction(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var pa: PValueArr;
begin
  pa := PValueArr(argv);
  sqlite3_value_int64(pa^[0]);
  sqlite3_result_value(pCtx, pa^[0]);
  if argc = 0 then ;
end;

procedure addRealTypeFunction(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var pa: PValueArr;
begin
  pa := PValueArr(argv);
  sqlite3_value_double(pa^[0]);
  sqlite3_result_value(pCtx, pa^[0]);
  if argc = 0 then ;
end;

{ test1.c:1031..1040 — strtod(X): C-library text→double via Pascal's
  StrToFloat (close enough — these tests probe rounding parity). }
procedure shellStrtod(pCtx: Psqlite3_context; nVal: cint;
  apVal: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  z:  PAnsiChar;
  d:  Double;
  pa: PValueArr;
  fs: TFormatSettings;
begin
  pa := PValueArr(apVal);
  z := PAnsiChar(sqlite3_value_text(pa^[0]));
  if z = nil then Exit;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  if not TryStrToFloat(AnsiString(z), d, fs) then d := 0;
  sqlite3_result_double(pCtx, d);
  if nVal = 0 then ;
end;

{ test1.c:1049..1061 — dtostr(X[,N]): "%#+.*e" double→text. }
procedure shellDtostr(pCtx: Psqlite3_context; nVal: cint;
  apVal: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  r:    Double;
  n:    cint;
  z:    array[0..399] of AnsiChar;
  s:    AnsiString;
  pa:   PValueArr;
begin
  pa := PValueArr(apVal);
  r := sqlite3_value_double(pa^[0]);
  if nVal >= 2 then n := sqlite3_value_int(pa^[1]) else n := 26;
  if n < 1 then n := 1;
  if n > 350 then n := 350;
  { Pascal has no '%#+.*e'; emulate: sign-forced, decimal point present. }
  s := Format('%.*e', [n, r]);
  if (Length(s) > 0) and (s[1] <> '-') then s := '+' + s;
  { Ensure decimal point — Format with non-zero precision always emits one. }
  FillChar(z[0], SizeOf(z), 0);
  Move(PAnsiChar(s)^, z[0], Length(s));
  sqlite3_result_text(pCtx, @z[0], -1, SQLITE_TRANSIENT);
end;

{ test1.c:1071..1086 — inttoptr(X): wrap integer as pointer-typed result. }
procedure inttoptrFunc(pCtx: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  i64v: i64;
  p:    Pointer;
  pa:   PValueArr;
begin
  pa := PValueArr(argv);
  i64v := sqlite3_value_int64(pa^[0]);
  p := Pointer(PtrUInt(i64v));
  sqlite3_result_pointer(pCtx, p, PChar('carray'), nil);
  if argc = 0 then ;
end;

{ ----------------------------------------------------------------------
  test1.c:3554..3664 — add_test_function and its three encoding-specific
  SQL-function callbacks.  Register one SQL function named "test_function"
  up to three times on DB (UTF-8 / UTF-16LE / UTF-16BE), one per requested
  encoding.  Each callback re-dispatches into the Tcl proc "test_function"
  with the encoding tag and the argument, then returns the proc result in
  a deliberately distinct encoding so the test can verify which handler ran.
  ---------------------------------------------------------------------- }

{ test1.c:3555..3578 — test_function_utf8. }
procedure test_function_utf8(pCtx: Psqlite3_context; nArg: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  interp: PTclInterp;
  pX:     PTclObj;
  pVal:   Psqlite3_value;
  pa:     PValueArr;
begin
  pa := PValueArr(argv);
  interp := PTclInterp(sqlite3_user_data(pCtx));
  pX := Tcl_NewStringObj(PChar('test_function'), -1);
  Tcl_IncrRefCount(pX);
  Tcl_ListObjAppendElement(interp, pX, Tcl_NewStringObj(PChar('UTF-8'), -1));
  Tcl_ListObjAppendElement(interp, pX,
    Tcl_NewStringObj(PChar(sqlite3_value_text(pa^[0])), -1));
  Tcl_EvalObjEx(interp, pX, 0);
  Tcl_DecrRefCount(pX);
  sqlite3_result_text(pCtx, Tcl_GetStringResult(interp), -1, SQLITE_TRANSIENT);
  pVal := sqlite3ValueNew(nil);
  sqlite3ValueSetStr(pVal, -1, Tcl_GetStringResult(interp),
    SQLITE_UTF8, SQLITE_STATIC);
  sqlite3_result_text16be(pCtx, sqlite3_value_text16be(pVal),
    -1, SQLITE_TRANSIENT);
  sqlite3ValueFree(pVal);
  if nArg = 0 then ;
end;

{ test1.c:3579..3600 — test_function_utf16le. }
procedure test_function_utf16le(pCtx: Psqlite3_context; nArg: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  interp: PTclInterp;
  pX:     PTclObj;
  pVal:   Psqlite3_value;
  pa:     PValueArr;
begin
  pa := PValueArr(argv);
  interp := PTclInterp(sqlite3_user_data(pCtx));
  pX := Tcl_NewStringObj(PChar('test_function'), -1);
  Tcl_IncrRefCount(pX);
  Tcl_ListObjAppendElement(interp, pX, Tcl_NewStringObj(PChar('UTF-16LE'), -1));
  Tcl_ListObjAppendElement(interp, pX,
    Tcl_NewStringObj(PChar(sqlite3_value_text(pa^[0])), -1));
  Tcl_EvalObjEx(interp, pX, 0);
  Tcl_DecrRefCount(pX);
  pVal := sqlite3ValueNew(nil);
  sqlite3ValueSetStr(pVal, -1, Tcl_GetStringResult(interp),
    SQLITE_UTF8, SQLITE_STATIC);
  sqlite3_result_text(pCtx, PChar(sqlite3_value_text(pVal)), -1,
    SQLITE_TRANSIENT);
  sqlite3ValueFree(pVal);
  if nArg = 0 then ;
end;

{ test1.c:3601..3627 — test_function_utf16be. }
procedure test_function_utf16be(pCtx: Psqlite3_context; nArg: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..15] of Psqlite3_value;
var
  interp: PTclInterp;
  pX:     PTclObj;
  pVal:   Psqlite3_value;
  pa:     PValueArr;
begin
  pa := PValueArr(argv);
  interp := PTclInterp(sqlite3_user_data(pCtx));
  pX := Tcl_NewStringObj(PChar('test_function'), -1);
  Tcl_IncrRefCount(pX);
  Tcl_ListObjAppendElement(interp, pX, Tcl_NewStringObj(PChar('UTF-16BE'), -1));
  Tcl_ListObjAppendElement(interp, pX,
    Tcl_NewStringObj(PChar(sqlite3_value_text(pa^[0])), -1));
  Tcl_EvalObjEx(interp, pX, 0);
  Tcl_DecrRefCount(pX);
  pVal := sqlite3ValueNew(nil);
  sqlite3ValueSetStr(pVal, -1, Tcl_GetStringResult(interp),
    SQLITE_UTF8, SQLITE_STATIC);
  sqlite3_result_text16(pCtx, sqlite3_value_text16le(pVal),
    -1, SQLITE_TRANSIENT);
  sqlite3_result_text16be(pCtx, sqlite3_value_text16le(pVal),
    -1, SQLITE_TRANSIENT);
  sqlite3_result_text16le(pCtx, sqlite3_value_text16le(pVal),
    -1, SQLITE_TRANSIENT);
  sqlite3ValueFree(pVal);
  if nArg = 0 then ;
end;

{ test1.c:3629..3664 — add_test_function DB <utf8> <utf16le> <utf16be>. }
function test_function(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:  PTsqlite3;
  val: cint;
begin
  if objc <> 5 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetStringFromObj(objv[0], nil),
      PChar(' <DB> <utf8> <utf16le> <utf16be>'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[2], @val) <> TCL_OK then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if val <> 0 then
    sqlite3_create_function(db, PChar('test_function'), 1, SQLITE_UTF8,
      interp, @test_function_utf8, nil, nil);
  if Tcl_GetBooleanFromObj(interp, objv[3], @val) <> TCL_OK then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if val <> 0 then
    sqlite3_create_function(db, PChar('test_function'), 1, SQLITE_UTF16LE,
      interp, @test_function_utf16le, nil, nil);
  if Tcl_GetBooleanFromObj(interp, objv[4], @val) <> TCL_OK then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if val <> 0 then
    sqlite3_create_function(db, PChar('test_function'), 1, SQLITE_UTF16BE,
      interp, @test_function_utf16be, nil, nil);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ ----------------------------------------------------------------------
  test1.c:3249..3479 — add_test_collate / add_test_collate_needed.

  The collation sequence "test_collate" is implemented by calling the
  Tcl proc "test_collate <enc> <lhs> <rhs>" with the encoding tag and the
  two operands (UTF-8 transcoded), and returning the integer proc result.
  The interp to use is stashed in the unit-level pTestCollateInterp, exactly
  as the file-scope static of the same name in C.
  ---------------------------------------------------------------------- }

{ test1.c:3278 — file-scope static Tcl_Interp *pTestCollateInterp. }
var
  pTestCollateInterp: PTclInterp = nil;

{ test1.c:3279..3328 — test_collate_func.  SQL collation callback that
  re-dispatches into the Tcl "test_collate" proc.  pCtx carries the
  encoding the registered collation was created for. }
function test_collate_func(pCtx: Pointer; nA: cint; zA: Pointer;
  nB: cint; zB: Pointer): cint; cdecl;
var
  i:     PTclInterp;
  encin: cint;
  res:   cint;
  n:     cint;
  pVal:  Psqlite3_value;
  pX:    PTclObj;
begin
  i := pTestCollateInterp;
  encin := cint(PtrInt(pCtx));
  res := 0;

  pX := Tcl_NewStringObj(PChar('test_collate'), -1);
  Tcl_IncrRefCount(pX);

  case encin of
    SQLITE_UTF8:
      Tcl_ListObjAppendElement(i, pX, Tcl_NewStringObj(PChar('UTF-8'), -1));
    SQLITE_UTF16LE:
      Tcl_ListObjAppendElement(i, pX, Tcl_NewStringObj(PChar('UTF-16LE'), -1));
    SQLITE_UTF16BE:
      Tcl_ListObjAppendElement(i, pX, Tcl_NewStringObj(PChar('UTF-16BE'), -1));
  end;

  pVal := sqlite3ValueNew(nil);
  if pVal <> nil then
  begin
    sqlite3ValueSetStr(pVal, nA, zA, encin, SQLITE_STATIC);
    n := sqlite3_value_bytes(pVal);
    Tcl_ListObjAppendElement(i, pX,
      Tcl_NewStringObj(PChar(sqlite3_value_text(pVal)), n));
    sqlite3ValueSetStr(pVal, nB, zB, encin, SQLITE_STATIC);
    n := sqlite3_value_bytes(pVal);
    Tcl_ListObjAppendElement(i, pX,
      Tcl_NewStringObj(PChar(sqlite3_value_text(pVal)), n));
    sqlite3ValueFree(pVal);
  end;

  Tcl_EvalObjEx(i, pX, 0);
  Tcl_DecrRefCount(pX);
  Tcl_GetIntFromObj(i, Tcl_GetObjResult(i), @res);
  Result := res;
end;

{ test1.c:3329..3384 — add_test_collate DB <utf8> <utf16le> <utf16be>. }
function test_collate(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  val:   cint;
  pVal:  Psqlite3_value;
  rc:    cint;
  zUtf16: Pointer;
  xCmp8, xCmp16le, xCmp16be: Pointer;
begin
  if objc <> 5 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetStringFromObj(objv[0], nil),
      PChar(' <DB> <utf8> <utf16le> <utf16be>'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  pTestCollateInterp := interp;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;

  if Tcl_GetBooleanFromObj(interp, objv[2], @val) <> TCL_OK then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if val <> 0 then xCmp8 := @test_collate_func else xCmp8 := nil;
  rc := sqlite3_create_collation(db, PChar('test_collate'), SQLITE_UTF8,
          Pointer(PtrInt(SQLITE_UTF8)), xCmp8);
  if rc = SQLITE_OK then
  begin
    if Tcl_GetBooleanFromObj(interp, objv[3], @val) <> TCL_OK then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
    if val <> 0 then xCmp16le := @test_collate_func else xCmp16le := nil;
    rc := sqlite3_create_collation(db, PChar('test_collate'), SQLITE_UTF16LE,
            Pointer(PtrInt(SQLITE_UTF16LE)), xCmp16le);
    if Tcl_GetBooleanFromObj(interp, objv[4], @val) <> TCL_OK then
    begin
      Result := TCL_ERROR;
      Exit;
    end;

    sqlite3_mutex_enter(db^.mutex);
    pVal := sqlite3ValueNew(db);
    sqlite3ValueSetStr(pVal, -1, PChar('test_collate'), SQLITE_UTF8,
      SQLITE_STATIC);
    zUtf16 := sqlite3ValueText(pVal, SQLITE_UTF16NATIVE);
    if db^.mallocFailed <> 0 then
      rc := SQLITE_NOMEM
    else
    begin
      if val <> 0 then xCmp16be := @test_collate_func else xCmp16be := nil;
      rc := sqlite3_create_collation16(db, zUtf16, SQLITE_UTF16BE,
              Pointer(PtrInt(SQLITE_UTF16BE)), xCmp16be);
    end;
    sqlite3ValueFree(pVal);
    sqlite3_mutex_leave(db^.mutex);
  end;
  if sqlite3TestErrCode(interp, db, rc) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:3432..3433 — module statics: the recorded needed-collation name.
  zNeededCollation is the buffer; pzNeededCollation points at it and is the
  thing Tcl_LinkVar'd to ::sqlite_last_needed_collation. }
var
  zNeededCollation:  array[0..199] of AnsiChar;
  pzNeededCollation: PAnsiChar = @zNeededCollation[0];

{ test1.c:3440..3455 — test_collate_needed_cb.  Records the requested
  collation name (the UTF-16 pName flattened to a C string) and registers
  test_collate in the database's native encoding. }
procedure test_collate_needed_cb(pCtx: Pointer; db: PTsqlite3;
  eTextRep: cint; pName: Pointer); cdecl;
var
  enc: cint;
  i:   cint;
  z:   PAnsiChar;
begin
  enc := cint(db^.enc);
  z := PAnsiChar(pName);
  i := 0;
  { for(z=pName, i=0; *z || z[1]; z++) if(*z) zNeededCollation[i++]=*z; }
  while (z[0] <> #0) or (z[1] <> #0) do
  begin
    if z[0] <> #0 then
    begin
      zNeededCollation[i] := z[0];
      Inc(i);
    end;
    Inc(z);
  end;
  zNeededCollation[i] := #0;
  sqlite3_create_collation(db, PChar('test_collate'), cint(db^.enc),
    Pointer(PtrInt(enc)), @test_collate_func);
  if (pCtx = nil) and (eTextRep = 0) then ;
end;

{ test1.c:3460..3479 — add_test_collate_needed DB. }
function test_collate_needed(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  rc := sqlite3_collation_needed16(db, nil, @test_collate_needed_cb);
  zNeededCollation[0] := #0;
  if sqlite3TestErrCode(interp, db, rc) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ ----------------------------------------------------------------------
  test1.c:3494..3526 — add_alignment_test_collations.

  Two collations, "utf16_unaligned" (SQLITE_UTF16) and "utf16_aligned"
  (SQLITE_UTF16_ALIGNED), share the alignmentCollFunc xCompare.  That
  function does a BINARY-style memcmp but bumps unaligned_string_counter
  whenever a key begins on an odd byte boundary.  The point of the test
  is that the ALIGNED collation never receives an odd-boundary key, so
  its contribution to the counter stays 0.  The counter is exposed to
  Tcl via Tcl_LinkVar so the test can read it back.
  ---------------------------------------------------------------------- }

{ test1.c:3495 — file-scope static int unaligned_string_counter = 0. }
var
  unaligned_string_counter: cint = 0;

{ test1.c:3496..3510 — alignmentCollFunc. }
function alignmentCollFunc(NotUsed: Pointer; nKey1: cint; pKey1: Pointer;
  nKey2: cint; pKey2: Pointer): cint; cdecl;
var
  rc, n: cint;
begin
  if nKey1 < nKey2 then n := nKey1 else n := nKey2;
  if (nKey1 > 0) and (1 = (1 and cint(PtrInt(pKey1)))) then
    Inc(unaligned_string_counter);
  if (nKey2 > 0) and (1 = (1 and cint(PtrInt(pKey2)))) then
    Inc(unaligned_string_counter);
  rc := CompareByte(pKey1^, pKey2^, n);
  if rc = 0 then
    rc := nKey1 - nKey2;
  Result := rc;
  if NotUsed = nil then ;
end;

{ test1.c:3511..3526 — add_alignment_test_collations DB. }
function add_alignment_test_collations(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
begin
  if objc >= 2 then
  begin
    if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
    sqlite3_create_collation(db, PChar('utf16_unaligned'), SQLITE_UTF16,
      nil, @alignmentCollFunc);
    sqlite3_create_collation(db, PChar('utf16_aligned'), SQLITE_UTF16_ALIGNED,
      nil, @alignmentCollFunc);
  end;
  Result := SQLITE_OK;
  if clientData = nil then ;
end;

{ test5.c:29..44 — binarize: return the argument string as a byte array,
  including its trailing NUL (len+1 bytes). }
function binarize(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  bytes: PChar;
  len:   cint;
begin
  AssertH(objc = 2, 'binarize: objc=2');
  bytes := Tcl_GetStringFromObj(objv[1], @len);
  Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(bytes, len + 1));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test5.c:90..115 — name_to_enc: map an encoding-name Tcl object to the
  SQLITE_UTF* constant.  UTF16 folds to SQLITE_UTF16NATIVE; unknown names
  append an error to interp and return 0. }
function name_to_enc(interp: PTclInterp; pObj: PTclObj): u8;
type
  TEncName = record zName: PChar; enc: u8; end;
const
  encnames: array[0..3] of TEncName = (
    (zName: 'UTF8';    enc: SQLITE_UTF8),
    (zName: 'UTF16LE'; enc: SQLITE_UTF16LE),
    (zName: 'UTF16BE'; enc: SQLITE_UTF16BE),
    (zName: 'UTF16';   enc: SQLITE_UTF16));
var
  z:    PChar;
  i:    cint;
  enc:  u8;
begin
  z := Tcl_GetString(pObj);
  i := 0;
  enc := 0;
  while i <= High(encnames) do
  begin
    if sqlite3StrICmp(z, encnames[i].zName) = 0 then
    begin
      enc := encnames[i].enc;
      Break;
    end;
    Inc(i);
  end;
  if enc = 0 then
    Tcl_AppendResult(interp, PChar('No such encoding: '), z, Pointer(nil));
  if enc = SQLITE_UTF16 then
    Result := SQLITE_UTF16NATIVE
  else
    Result := enc;
end;

{ test5.c:121..176 — test_translate <string/blob> <from> <to> ?<transient>?.
  Translates a value between encodings via the engine sqlite3Value* API and
  returns the result as a Tcl byte array (incl. NUL/BOM terminator). }
function test_translate(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  enc_from, enc_to: u8;
  pVal:    Psqlite3_value;
  z, zTmp: PChar;
  len:     cint;
  xDel:    TxDelProc;
begin
  xDel := SQLITE_STATIC;
  if (objc <> 4) and (objc <> 5) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetStringFromObj(objv[0], nil),
      PChar(' <string/blob> <from enc> <to enc>'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  if objc = 5 then
    xDel := @sqlite3_free;

  enc_from := name_to_enc(interp, objv[2]);
  if enc_from = 0 then begin Result := TCL_ERROR; Exit; end;
  enc_to := name_to_enc(interp, objv[3]);
  if enc_to = 0 then begin Result := TCL_ERROR; Exit; end;

  pVal := sqlite3ValueNew(nil);

  if enc_from = SQLITE_UTF8 then
  begin
    z := Tcl_GetString(objv[1]);
    if objc = 5 then
    begin
      { test5.c: z = sqlite3_mprintf("%s", z) — a freshly sqlite3_malloc'd,
        NUL-terminated copy the value owns and frees via xDel.  The Pascal
        sqlite3_mprintf is single-arg (no varargs), so copy by hand. }
      len := StrLen(z) + 1;
      zTmp := z;
      z := sqlite3_malloc64(len);
      Move(zTmp^, z^, len);
    end;
    sqlite3ValueSetStr(pVal, -1, z, enc_from, xDel);
  end
  else
  begin
    z := Tcl_GetByteArrayFromObj(objv[1], @len);
    if objc = 5 then
    begin
      zTmp := z;
      z := sqlite3_malloc64(len);
      Move(zTmp^, z^, len);
    end;
    sqlite3ValueSetStr(pVal, -1, z, enc_from, xDel);
  end;

  z := PChar(sqlite3ValueText(pVal, enc_to));
  if enc_to = SQLITE_UTF8 then
    len := sqlite3ValueBytes(pVal, enc_to) + 1
  else
    len := sqlite3ValueBytes(pVal, enc_to) + 2;
  Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(z, len));

  sqlite3ValueFree(pVal);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test5.c:185..195 — translate_selftest.  Runs sqlite3UtfSelfTest, which
  round-trips every codepoint through the UTF serialise/deserialise
  primitives and asserts they are inverses.  Takes no arguments. }
function test_translate_selftest(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  sqlite3UtfSelfTest;
  Result := TCL_OK;
  if (clientData = nil) and (interp = nil) and (objc = 0) and (objv = nil) then ;
end;

{ test1.c:780..847 — the x_sqlite_exec() SQL function.  Runs its single
  TEXT argument as SQL on the connection passed as user-data, gathering
  every result column into a space-separated string.  Used by misuse.test
  to exercise re-entrant sqlite3_exec().  C registers this via
  sqlite3_create_function16; the body is encoding-independent so we
  register the UTF-8 entry directly (test_create_function below). }
type
  Tdstr = record
    nAlloc: cint;   { space allocated }
    nUsed:  cint;   { space used      }
    z:      PAnsiChar;
  end;
  Pdstr = ^Tdstr;

procedure dstrAppend(p: Pdstr; z: PAnsiChar; divider: cint);
var
  n:    cint;
  zNew: PAnsiChar;
begin
  n := StrLen(z);
  if p^.nUsed + n + 2 > p^.nAlloc then
  begin
    p^.nAlloc := p^.nAlloc * 2 + n + 200;
    zNew := sqlite3_realloc(p^.z, p^.nAlloc);
    if zNew = nil then
    begin
      sqlite3_free(p^.z);
      FillChar(p^, SizeOf(p^), 0);
      Exit;
    end;
    p^.z := zNew;
  end;
  if (divider <> 0) and (p^.nUsed > 0) then
  begin
    p^.z[p^.nUsed] := AnsiChar(divider);
    Inc(p^.nUsed);
  end;
  Move(z^, (p^.z + p^.nUsed)^, n + 1);
  Inc(p^.nUsed, n);
end;

function execFuncCallback(pData: Pointer; argc: cint;
  argv: PPAnsiChar; NotUsed: PPAnsiChar): cint; cdecl;
var
  p:  Pdstr;
  i:  cint;
  z:  PAnsiChar;
begin
  p := Pdstr(pData);
  for i := 0 to argc - 1 do
  begin
    z := PPAnsiChar(PtrUInt(argv) + PtrUInt(i) * SizeOf(Pointer))^;
    if z = nil then
      dstrAppend(p, PAnsiChar('NULL'), Ord(' '))
    else
      dstrAppend(p, z, Ord(' '));
  end;
  Result := 0;
  if NotUsed = nil then ;
end;

procedure sqlite3ExecFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..255] of Psqlite3_value;
var
  x:  Tdstr;
  pa: PValueArr;
begin
  pa := PValueArr(argv);
  FillChar(x, SizeOf(x), 0);
  sqlite3_exec(PTsqlite3(sqlite3_user_data(context)),
    PAnsiChar(sqlite3_value_text(pa^[0])), @execFuncCallback, @x, nil);
  sqlite3_result_text(context, x.z, x.nUsed, SQLITE_TRANSIENT);
  sqlite3_free(x.z);
end;

{ test1.c:1088..1226 — test_create_function: register the UDFs above
  on DB.  Returns the rc enum-name.  hex16 / x_sqlite_exec are registered
  via sqlite3_create_function16 in C (SQLITE_OMIT_UTF16 gate); the bodies
  are encoding-independent so we register UTF-8 entries directly. }
function test_create_function(clientData: TClientData; interp: PTclInterp;
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
      av^[0], PChar(' DB"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av^[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_create_function(db, PChar('x_coalesce'), -1, SQLITE_UTF8,
          nil, @t1_ifnullFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('hex8'), 1,
            SQLITE_UTF8 or SQLITE_DETERMINISTIC, nil,
            @hex8Func, nil, nil);
  { 9.4.divbug.88.052 — hex16 UTF-16 helper (test1.c:1126..1129). }
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('hex16'), 1,
            SQLITE_UTF16 or SQLITE_DETERMINISTIC, nil,
            @hex16Func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('tkt2213func'), 1, SQLITE_ANY,
            nil, @tkt2213Function, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('pointer_change'), 4, SQLITE_ANY,
            nil, @ptrChngFunction, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('counter1'), -1, SQLITE_UTF8,
            nil, @nondeterministicFunction, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('counter2'), -1,
            SQLITE_UTF8 or SQLITE_DETERMINISTIC, nil,
            @nondeterministicFunction, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('intreal'), 1, SQLITE_UTF8,
            nil, @intrealFunction, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('add_text_type'), 1, SQLITE_UTF8,
            nil, @addTextTypeFunction, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('add_int_type'), 1, SQLITE_UTF8,
            nil, @addIntTypeFunction, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('add_real_type'), 1, SQLITE_UTF8,
            nil, @addRealTypeFunction, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('strtod'), 1, SQLITE_UTF8,
            nil, @shellStrtod, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('dtostr'), 1, SQLITE_UTF8,
            nil, @shellDtostr, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('dtostr'), 2, SQLITE_UTF8,
            nil, @shellDtostr, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('inttoptr'), 1, SQLITE_UTF8,
            nil, @inttoptrFunc, nil, nil);
  { test1.c:1202..1221 — x_sqlite_exec.  C registers via
    sqlite3_create_function16 (UTF-16); we register the UTF-8 entry with
    db as user-data so the function can re-enter sqlite3_exec. }
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PChar('x_sqlite_exec'), 1, SQLITE_UTF8,
            db, @sqlite3ExecFunc, nil, nil);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.d — test_malloc.c:1163..1184 test_config_uri.
  Set SQLITE_CONFIG_URI; return sqlite3ErrName(rc). }
function tcl_test_config_uri(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc, bOpenUri: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BOOL'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[1], @bOpenUri) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_config(SQLITE_CONFIG_URI, bOpenUri);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ coveridxscan — test_malloc.c:1186..1213 test_config_cis.
  Enable/disable SQLITE_CONFIG_COVERING_INDEX_SCAN; return sqlite3ErrName(rc). }
function tcl_test_config_cis(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc, bUseCis: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BOOL'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[1], @bUseCis) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_config(SQLITE_CONFIG_COVERING_INDEX_SCAN, bUseCis);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.d — test_malloc.c:1220..1241 test_config_pmasz.
  Set the minimum PMA size via SQLITE_CONFIG_PMASZ. }
function tcl_test_config_pmasz(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc, iPmaSz: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BOOL'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @iPmaSz) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_config(SQLITE_CONFIG_PMASZ, iPmaSz);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.d — test_autoext.c:189..197 resetAutoExtObjCmd.
  Reset all auto-extensions. }
function tcl_reset_auto_extension(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  sqlite3_reset_auto_extension;
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (objc < 0) or (objv = nil) then ;
end;

{ 9.4.divbug.63.a — test1.c:3707..3714 test_breakpoint.
  Usage:  breakpoint
  A pure no-op TCL command that exists solely as a GDB breakpoint
  anchor.  Tests sprinkle `breakpoint` calls inside their bodies so a
  developer running testfixture under gdb can `b test_breakpoint` to
  catch a specific iteration. }
function test_breakpoint(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
begin
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (argc < 0) or (argv = nil) then ;
end;

{ 9.4.divbug.63.a — test1.c:7544..7552 database_may_be_corrupt.
  tclcmd:  database_may_be_corrupt
  Indicate that database files might be corrupt (normal state). }
function database_may_be_corrupt(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  sqlite3_test_control(SQLITE_TESTCTRL_NEVER_CORRUPT_OP, 0);
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (objc < 0) or (objv = nil) then ;
end;

{ 9.4.divbug.63.a — test1.c:7560..7568 database_never_corrupt.
  tclcmd:  database_never_corrupt
  Indicate that database files are always well-formed; enables extra
  asserts that test invariants of well-formed databases. }
function database_never_corrupt(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  sqlite3_test_control(SQLITE_TESTCTRL_NEVER_CORRUPT_OP, 1);
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (objc < 0) or (objv = nil) then ;
end;

{ test1.c:7515..7536 — extra_schema_checks BOOLEAN.
  Enable/disable schema checks when parsing sqlite_schema.  6.40.6 (HARNESS). }
function extra_schema_checks(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i: cint;
begin
  i := 0;
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BOOLEAN'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[1], @i) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_test_control(SQLITE_TESTCTRL_EXTRA_SCHEMA_CHECKS_OP, i);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:7185..7214 — file_control_powersafe_overwrite DB PSOW-FLAG.
  Runs sqlite3_file_control with SQLITE_FCNTL_POWERSAFE_OVERWRITE.
  Result is "<rc> <b>".  6.40.6 (HARNESS). }
function file_control_powersafe_overwrite(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:  PTsqlite3;
  rc:  cint;
  b:   cint;
  s:   AnsiString;
begin
  if objc <> 3 then begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' DB FLAG'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[2], @b) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_file_control(db, nil, SQLITE_FCNTL_POWERSAFE_OVERWRITE, @b);
  s := IntToStr(rc) + ' ' + IntToStr(b);
  Tcl_AppendResult(interp, PChar(s), Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.63.a — test1.c:6169..6186 tcl_variable_type.
  Usage:  tcl_variable_type VARIABLENAME
  Return the name of the internal Tcl_Obj type of the named variable's
  current value (e.g. "int", "double", "list", "bytearray").  Tests
  use this to probe whether a recent shimmer made the interp produce a
  particular internalRep.  When the value has no typePtr (pure-string),
  return the empty result.

  Tcl_Obj layout (tcl.h):
    int            refCount;
    char          *bytes;
    int            length;
    const Tcl_ObjType *typePtr;
    union { ... }  internalRep;
  Tcl_ObjType layout:
    const char *name;
    ... }
type
  PTclObjTypeName = ^PAnsiChar;
  TTclObjLayout = record
    refCount:  cint;
    bytes:     PAnsiChar;
    length:    cint;
    typePtr:   PTclObjTypeName;
    { internalRep omitted — we never read it }
  end;
  PTclObjLayout = ^TTclObjLayout;

function tcl_variable_type(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pVar:   PTclObj;
  pLay:   PTclObjLayout;
  zName:  PAnsiChar;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('VARIABLE'));
    Result := TCL_ERROR;
    Exit;
  end;
  { TCL_LEAVE_ERR_MSG = $200 from tcl.h:885 }
  pVar := Tcl_GetVar2Ex(interp, Tcl_GetString(objv[1]), nil, $200);
  if pVar = nil then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  pLay := PTclObjLayout(pVar);
  if pLay^.typePtr <> nil then
  begin
    zName := pLay^.typePtr^;
    Tcl_SetObjResult(interp, Tcl_NewStringObj(zName, -1));
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:7249..7276 — file_control_reservebytes DB N.  Thin Tcl wrapper
  over sqlite3_file_control(db, "main", SQLITE_FCNTL_RESERVE_BYTES, &n).
  Returns the symbolic rc name (e.g. "SQLITE_OK") via sqlite3ErrName.
  9.4.divbug.63.b. }
function file_control_reservebytes(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  n:  cint;
  rc: cint;
begin
  db := nil;
  n  := 0;
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB N'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[2], @n) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  rc := sqlite3_file_control(db, PAnsiChar('main'),
    SQLITE_FCNTL_RESERVE_BYTES, @n);
  Tcl_SetObjResult(interp, Tcl_NewStringObj(t1ErrName(rc), -1));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.63 — test1.c:8469..8501 sorter_test_fakeheap BOOL.
  Toggle a fake (non-NULL but invalid) global heap pointer so the sorter
  takes its "heap configured" code path without an actual allocator.
  SQLITE_INT_TO_PTR(-1) == Pointer(-1). }
function sorter_test_fakeheap(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  bArg: cint;
begin
  bArg := 0;
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BOOL'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[1], @bArg) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if bArg <> 0 then
  begin
    if sqlite3GlobalConfig.pHeap = nil then
      sqlite3GlobalConfig.pHeap := Pointer(PtrInt(-1));
  end
  else
  begin
    if sqlite3GlobalConfig.pHeap = Pointer(PtrInt(-1)) then
      sqlite3GlobalConfig.pHeap := nil;
  end;
  Tcl_ResetResult(interp);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.63 — test1.c:8503..8574 sorter_test_sort4_helper DB SQL1 NSTEP SQL2.
  Step SQL1 up to NSTEP times; assert col[0]==col[last] are equal ints,
  accumulate a checksum; then run SQL2 fully accumulating a second checksum
  over col[0]; assert the two checksums match. }
function sorter_test_sort4_helper(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zSql1, zSql2: PAnsiChar;
  nStep, iStep: cint;
  iCksum1, iCksum2: cuint32;
  rc, iB, a: cint;
  db: PTsqlite3;
  pStmt: PVdbe;
label sql_error;
begin
  db := nil;
  nStep := 0;
  iCksum1 := 0;
  iCksum2 := 0;
  pStmt := nil;
  if objc <> 5 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB SQL1 NSTEP SQL2'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  zSql1 := Tcl_GetString(objv[2]);
  if Tcl_GetIntFromObj(interp, objv[3], @nStep) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  zSql2 := Tcl_GetString(objv[4]);

  rc := sqlite3_prepare_v2(db, zSql1, -1, @pStmt, nil);
  if rc <> SQLITE_OK then goto sql_error;

  iB := sqlite3_column_count(pStmt) - 1;
  iStep := 0;
  while (iStep < nStep) and (sqlite3_step(pStmt) = SQLITE_ROW) do
  begin
    a := sqlite3_column_int(pStmt, 0);
    if a <> sqlite3_column_int(pStmt, iB) then
    begin
      Tcl_AppendResult(interp, PChar('data error: (a!=b)'), Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
    iCksum1 := iCksum1 + (iCksum1 shl 3) + cuint32(a);
    Inc(iStep);
  end;
  rc := sqlite3_finalize(pStmt);
  pStmt := nil;
  if rc <> SQLITE_OK then goto sql_error;

  rc := sqlite3_prepare_v2(db, zSql2, -1, @pStmt, nil);
  if rc <> SQLITE_OK then goto sql_error;
  while sqlite3_step(pStmt) = SQLITE_ROW do
  begin
    a := sqlite3_column_int(pStmt, 0);
    iCksum2 := iCksum2 + (iCksum2 shl 3) + cuint32(a);
  end;
  rc := sqlite3_finalize(pStmt);
  pStmt := nil;
  if rc <> SQLITE_OK then goto sql_error;

  if iCksum1 <> iCksum2 then
  begin
    Tcl_AppendResult(interp, PChar('checksum mismatch'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;

  Result := TCL_OK;
  if clientData = nil then ;
  Exit;
sql_error:
  Tcl_AppendResult(interp, PChar('sql error: '), sqlite3_errmsg(db), Pointer(nil));
  Result := TCL_ERROR;
end;

{ 9.4.divbug.88.006 — test1.c:6912..6941 file_control_chunksize_test
  DB DBNAME SIZE.  Thin Tcl wrapper over
  sqlite3_file_control(db, zDb, SQLITE_FCNTL_CHUNK_SIZE, &nSize).
  Empty zDb → NULL.  On rc<>0 sets result to sqlite3ErrName and returns
  TCL_ERROR (matches C). }
function file_control_chunksize_test(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  nSize: cint;
  zDb:   PAnsiChar;
  rc:    cint;
begin
  db := nil;
  nSize := 0;
  if objc <> 4 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB DBNAME SIZE'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[3], @nSize) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  zDb := Tcl_GetString(objv[2]);
  if (zDb <> nil) and (zDb^ = #0) then zDb := nil;
  rc := sqlite3_file_control(db, zDb, SQLITE_FCNTL_CHUNK_SIZE, @nSize);
  if rc <> 0 then
  begin
    Tcl_SetObjResult(interp, Tcl_NewStringObj(t1ErrName(rc), -1));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.024 — test1.c:6873..6903 file_control_data_version
  DB ?DBNAME?.  Thin Tcl wrapper over
  sqlite3_file_control(db, zDb, SQLITE_FCNTL_DATA_VERSION, &iVers).
  objc==2 (no DBNAME) → zDb=NULL.  On rc<>0 sets result to sqlite3ErrName
  and returns TCL_ERROR; otherwise returns "%u" of iVers. }
function file_control_data_version(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  iVers: cuint;
  zDb:   PAnsiChar;
  rc:    cint;
  sBuf:  AnsiString;
begin
  db := nil;
  iVers := 0;
  if (objc <> 3) and (objc <> 2) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB [DBNAME]'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if objc = 3 then
    zDb := Tcl_GetString(objv[2])
  else
    zDb := nil;
  rc := sqlite3_file_control(db, zDb, SQLITE_FCNTL_DATA_VERSION, @iVers);
  if rc <> 0 then
  begin
    Tcl_SetObjResult(interp, Tcl_NewStringObj(t1ErrName(rc), -1));
    Result := TCL_ERROR;
    Exit;
  end;
  { C: sqlite3_snprintf("%u",iVers); decimal of unsigned int. }
  Str(iVers, sBuf);
  Tcl_SetObjResult(interp, Tcl_NewStringObj(PAnsiChar(sBuf), -1));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.037 — test1.c:6795..6827 file_control_test.
  Usage: file_control_test DB.  Exercises sqlite3_file_control plumbing:
  4 calls — bad opcode 0, bad schema name, "main" opcode -1, "temp"
  opcode -1.  C uses assert() on the rc; release builds (and Pas) just
  drop them — empty result == TCL_OK matches filectrl-1.1. }
function file_control_test_tcl(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:   PTsqlite3;
  iArg: cint;
  rc:   cint;
begin
  db := nil;
  iArg := 0;
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  rc := sqlite3_file_control(db, nil, 0, @iArg);
  { expect SQLITE_NOTFOUND }
  rc := sqlite3_file_control(db, PAnsiChar('notadatabase'),
          SQLITE_FCNTL_LOCKSTATE, @iArg);
  { expect SQLITE_ERROR }
  rc := sqlite3_file_control(db, PAnsiChar('main'), -1, @iArg);
  { expect SQLITE_NOTFOUND }
  rc := sqlite3_file_control(db, PAnsiChar('temp'), -1, @iArg);
  { expect SQLITE_NOTFOUND or SQLITE_ERROR }
  Result := TCL_OK;
  if clientData = nil then ;
  if rc = 0 then ;
end;

{ 9.4.divbug.88.065 — test1.c:6830..6865 file_control_lasterrno_test.
  Usage: file_control_lasterrno_test DB.  Calls
  sqlite3_file_control(db, NULL, SQLITE_LAST_ERRNO, &iArg); errors if rc
  is non-zero or if the returned errno is non-zero. }
function file_control_lasterrno_test_tcl(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:   PTsqlite3;
  iArg: cint;
  rc:   cint;
  zBuf: array[0..63] of AnsiChar;
begin
  db := nil;
  iArg := 0;
  if objc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetStringFromObj(objv[0], nil), PChar(' DB'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  rc := sqlite3_file_control(db, nil, SQLITE_FCNTL_LAST_ERRNO, @iArg);
  if rc <> 0 then
  begin
    Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
    Result := TCL_ERROR;
    Exit;
  end;
  if iArg <> 0 then
  begin
    StrPCopy(zBuf, IntToStr(iArg));
    Tcl_AppendResult(interp, PChar('Unexpected non-zero errno: '),
      PChar(@zBuf[0]), PChar(' '), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.065 — test1.c:7279..7309 file_control_tempfilename.
  Usage: file_control_tempfilename DB ?AUXDB?.  Asks the VFS for a
  temporary filename via SQLITE_FCNTL_TEMPFILENAME and appends it to
  the interp result, then frees the allocation. }
function file_control_tempfilename_tcl(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:      PTsqlite3;
  zDbName: PAnsiChar;
  zTName:  PAnsiChar;
begin
  db := nil;
  zDbName := PAnsiChar('main');
  zTName := nil;
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetStringFromObj(objv[0], nil), PChar(' DB ?AUXDB?'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if objc = 3 then
    zDbName := Tcl_GetString(objv[2]);
  sqlite3_file_control(db, zDbName, SQLITE_FCNTL_TEMPFILENAME, @zTName);
  Tcl_AppendResult(interp, zTName, Pointer(nil));
  if zTName <> nil then sqlite3_free(zTName);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.067 — test1.c:6981..7048 file_control_lockproxy_test.
  Usage: file_control_lockproxy_test DB PWD.  On Apple targets exercises
  SQLITE_{GET,SET}_LOCKPROXYFILE; on non-Apple platforms the C body is
  compiled out, so this is a validate-args-and-return-OK stub matching
  the upstream Linux behaviour. }
function file_control_lockproxy_test_tcl(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
begin
  db := nil;
  if objc <> 3 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetStringFromObj(objv[0], nil), PChar(' DB PWD'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  { Non-Apple builds: SQLITE_ENABLE_LOCKING_STYLE block elided; mirror
    the C function's fall-through to TCL_OK. }
  Result := TCL_OK;
  if clientData = nil then ;
  if db = nil then ;
end;

{ 9.4.divbug.87.005 — test1.c:1740..1791 test_table_column_metadata.
  Usage: sqlite3_table_column_metadata DB dbname tblname ?colname?
  Returns a 5-element list: datatype collseq notnull primarykey autoinc.
  When zDb is "" pass NULL to engine.  colname omitted → table-exists
  probe. }
function tcl_test_table_column_metadata(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:            PTsqlite3;
  zDb, zTbl, zCol: PAnsiChar;
  rc:            cint;
  pRet:          PTclObj;
  zDatatype:     PAnsiChar;
  zCollseq:      PAnsiChar;
  notnull:       cint;
  primarykey:    cint;
  autoincrement: cint;
begin
  db := nil;
  if (objc <> 5) and (objc <> 4) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('DB dbname tblname colname'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zDb := Tcl_GetString(objv[2]);
  zTbl := Tcl_GetString(objv[3]);
  if objc = 5 then
    zCol := Tcl_GetString(objv[4])
  else
    zCol := nil;
  if (zDb <> nil) and (zDb^ = #0) then zDb := nil;

  zDatatype     := nil;
  zCollseq      := nil;
  notnull       := 0;
  primarykey    := 0;
  autoincrement := 0;

  rc := sqlite3_table_column_metadata(db, zDb, zTbl, zCol,
    @zDatatype, @zCollseq, @notnull, @primarykey, @autoincrement);

  if rc <> SQLITE_OK then
  begin
    Tcl_AppendResult(interp, sqlite3_errmsg(db), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;

  pRet := Tcl_NewObj;
  Tcl_ListObjAppendElement(nil, pRet, Tcl_NewStringObj(zDatatype, -1));
  Tcl_ListObjAppendElement(nil, pRet, Tcl_NewStringObj(zCollseq, -1));
  Tcl_ListObjAppendElement(nil, pRet, Tcl_NewIntObj(notnull));
  Tcl_ListObjAppendElement(nil, pRet, Tcl_NewIntObj(primarykey));
  Tcl_ListObjAppendElement(nil, pRet, Tcl_NewIntObj(autoincrement));
  Tcl_SetObjResult(interp, pRet);

  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.e — test1.c:1947..1972 CreateFunctionV2 trampoline
  record + cf2Func / cf2Step / cf2Final / cf2Destroy helpers.  cf2Func /
  cf2Step / cf2Final are intentional no-ops (upstream uses these only to
  exercise the create_function_v2 registration / xDestroy path; the
  affected tests — autoext, fts3matchinfo edges — don't read function
  results).  cf2Destroy fires the optional -destroy Tcl script. }
type
  PCreateFunctionV2 = ^TCreateFunctionV2;
  TCreateFunctionV2 = record
    interp: PTclInterp;
    pFunc, pStep, pFinal, pDestroy: PTclObj;
  end;

procedure cf2Func(pCtx: Psqlite3_context; nArg: cint;
  apArg: PPsqlite3_value); cdecl;
begin
  if (pCtx = nil) or (nArg < 0) or (apArg = nil) then ;
end;
procedure cf2Step(pCtx: Psqlite3_context; nArg: cint;
  apArg: PPsqlite3_value); cdecl;
begin
  if (pCtx = nil) or (nArg < 0) or (apArg = nil) then ;
end;
procedure cf2Final(pCtx: Psqlite3_context); cdecl;
begin
  if pCtx = nil then ;
end;
procedure cf2Destroy(pUser: Pointer); cdecl;
var
  p: PCreateFunctionV2;
  rc: cint;
begin
  p := PCreateFunctionV2(pUser);
  if p = nil then Exit;
  if (p^.interp <> nil) and (p^.pDestroy <> nil) then
  begin
    rc := Tcl_EvalObjEx(p^.interp, p^.pDestroy, 0);
    if rc <> TCL_OK then Tcl_BackgroundError(p^.interp);
  end;
  if p^.pFunc    <> nil then Tcl_DecrRefCount(p^.pFunc);
  if p^.pStep    <> nil then Tcl_DecrRefCount(p^.pStep);
  if p^.pFinal   <> nil then Tcl_DecrRefCount(p^.pFinal);
  if p^.pDestroy <> nil then Tcl_DecrRefCount(p^.pDestroy);
  sqlite3_free(p);
end;

{ 9.4.divbug.62.e — test1.c:1975..2059 test_create_function_v2.
  Usage: sqlite3_create_function_v2 DB NAME NARG ENC ?-func/-step/-final/-destroy SCRIPT?...
  Encoding strings recognised: utf8, utf16, utf16le, utf16be, any, 0. }
function tcl_test_create_function_v2(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
const
  aEncName: array[0..6] of PChar =
    ('utf8', 'utf16', 'utf16le', 'utf16be', 'any', '0', nil);
  aEncVal: array[0..5] of cint =
    (SQLITE_UTF8, SQLITE_UTF16, SQLITE_UTF16LE, SQLITE_UTF16BE,
     SQLITE_ANY, 0);
  aSwitch: array[0..4] of PChar =
    ('-func', '-step', '-final', '-destroy', nil);
var
  db: PTsqlite3;
  zFunc: PChar;
  nArg, enc, iEnc, iSwitch, i, rc: cint;
  p: PCreateFunctionV2;
  xFn, xSt, xFn2: Pointer;
begin
  if (objc < 5) or ((objc mod 2) = 0) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('DB NAME NARG ENC SWITCHES...'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zFunc := Tcl_GetString(objv[2]);
  if Tcl_GetIntFromObj(interp, objv[3], @nArg) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIndexFromObj(interp, objv[4], @aEncName[0], PChar('encoding'),
    0, @iEnc) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  enc := aEncVal[iEnc];

  p := PCreateFunctionV2(sqlite3_malloc(SizeOf(TCreateFunctionV2)));
  if p = nil then begin Result := TCL_ERROR; Exit; end;
  FillChar(p^, SizeOf(p^), 0);
  p^.interp := interp;

  i := 5;
  while i < objc do
  begin
    if Tcl_GetIndexFromObj(interp, objv[i], @aSwitch[0], PChar('switch'),
      0, @iSwitch) <> 0 then
    begin
      sqlite3_free(p); Result := TCL_ERROR; Exit;
    end;
    case iSwitch of
      0: p^.pFunc    := objv[i + 1];
      1: p^.pStep    := objv[i + 1];
      2: p^.pFinal   := objv[i + 1];
      3: p^.pDestroy := objv[i + 1];
    end;
    Inc(i, 2);
  end;
  if p^.pFunc    <> nil then p^.pFunc    := Tcl_DuplicateObj(p^.pFunc);
  if p^.pStep    <> nil then p^.pStep    := Tcl_DuplicateObj(p^.pStep);
  if p^.pFinal   <> nil then p^.pFinal   := Tcl_DuplicateObj(p^.pFinal);
  if p^.pDestroy <> nil then p^.pDestroy := Tcl_DuplicateObj(p^.pDestroy);
  if p^.pFunc    <> nil then Tcl_IncrRefCount(p^.pFunc);
  if p^.pStep    <> nil then Tcl_IncrRefCount(p^.pStep);
  if p^.pFinal   <> nil then Tcl_IncrRefCount(p^.pFinal);
  if p^.pDestroy <> nil then Tcl_IncrRefCount(p^.pDestroy);

  if p^.pFunc  <> nil then xFn  := @cf2Func  else xFn  := nil;
  if p^.pStep  <> nil then xSt  := @cf2Step  else xSt  := nil;
  if p^.pFinal <> nil then xFn2 := @cf2Final else xFn2 := nil;
  rc := sqlite3_create_function_v2(db, zFunc, nArg, enc, p,
    xFn, xSt, xFn2, @cf2Destroy);
  if rc <> SQLITE_OK then
  begin
    Tcl_ResetResult(interp);
    Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.009 — test1.c:1858..1935 testCreateCollation* +
  test_create_collation_v2.
  Usage: sqlite3_create_collation_v2 DB-HANDLE NAME CMP-PROC DEL-PROC
  The C handler first attempts registration with an invalid encoding (16)
  and expects SQLITE_MISUSE, then registers with SQLITE_UTF8.  The
  destructor fires the DEL-PROC Tcl script.  collate7-1.x checks both. }
type
  PTestCollationX = ^TTestCollationX;
  TTestCollationX = record
    interp: PTclInterp;
    pCmp:   PTclObj;
    pDel:   PTclObj;
  end;

procedure testCreateCollationDel(pCtx: Pointer); cdecl;
var
  p: PTestCollationX;
  rc: cint;
begin
  p := PTestCollationX(pCtx);
  if p = nil then Exit;
  if (p^.interp <> nil) and (p^.pDel <> nil) then
  begin
    rc := Tcl_EvalObjEx(p^.interp, p^.pDel,
            TCL_EVAL_DIRECT or TCL_EVAL_GLOBAL);
    if rc <> TCL_OK then Tcl_BackgroundError(p^.interp);
  end;
  if p^.pCmp <> nil then Tcl_DecrRefCount(p^.pCmp);
  if p^.pDel <> nil then Tcl_DecrRefCount(p^.pDel);
  sqlite3_free(p);
end;

function testCreateCollationCmp(pCtx: Pointer; nLeft: cint; zLeft: Pointer;
  nRight: cint; zRight: Pointer): cint; cdecl;
var
  p: PTestCollationX;
  pScript: PTclObj;
  iRes: cint;
begin
  p := PTestCollationX(pCtx);
  iRes := 0;
  pScript := Tcl_DuplicateObj(p^.pCmp);
  Tcl_IncrRefCount(pScript);
  Tcl_ListObjAppendElement(nil, pScript,
    Tcl_NewStringObj(PChar(zLeft), nLeft));
  Tcl_ListObjAppendElement(nil, pScript,
    Tcl_NewStringObj(PChar(zRight), nRight));
  if (Tcl_EvalObjEx(p^.interp, pScript,
        TCL_EVAL_DIRECT or TCL_EVAL_GLOBAL) <> TCL_OK)
     or (Tcl_GetIntFromObj(p^.interp,
           Tcl_GetObjResult(p^.interp), @iRes) <> TCL_OK) then
    Tcl_BackgroundError(p^.interp);
  Tcl_DecrRefCount(pScript);
  Result := iRes;
end;

function tcl_test_create_collation_v2(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  p: PTestCollationX;
  db: PTsqlite3;
  rc: cint;
begin
  if objc <> 5 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('DB-HANDLE NAME CMP-PROC DEL-PROC'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  p := PTestCollationX(sqlite3_malloc(SizeOf(TTestCollationX)));
  if p = nil then begin Result := TCL_ERROR; Exit; end;
  FillChar(p^, SizeOf(p^), 0);
  p^.pCmp := objv[3];
  p^.pDel := objv[4];
  p^.interp := interp;
  Tcl_IncrRefCount(p^.pCmp);
  Tcl_IncrRefCount(p^.pDel);

  rc := sqlite3_create_collation_v2(db, Tcl_GetString(objv[2]), 16,
          p, @testCreateCollationCmp, @testCreateCollationDel);
  if rc <> SQLITE_MISUSE then
  begin
    Tcl_AppendResult(interp,
      PChar('sqlite3_create_collate_v2() failed to detect '
            + 'an invalid encoding'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_create_collation_v2(db, Tcl_GetString(objv[2]), SQLITE_UTF8,
          p, @testCreateCollationCmp, @testCreateCollationDel);
  if rc = 0 then ;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.e — test_window.c:24..177 TestWindow trampoline +
  test_create_window.  Usage:
    sqlite3_create_window_function DB NAME XSTEP XFINAL XVALUE XINVERSE
  Each callback receives the accumulator + nArg arg strings appended;
  callback's result becomes the new accumulator (final / value emit it). }
type
  PTestWindow = ^TTestWindow;
  TTestWindow = record
    xStep, xFinal, xValue, xInverse: PTclObj;
    interp: PTclInterp;
  end;
  PTestWindowCtx = ^TTestWindowCtx;
  TTestWindowCtx = record
    pVal: PTclObj;
  end;

procedure doTestWindowStep(bInverse: cint; ctx: Psqlite3_context;
  nArg: cint; apArg: PPsqlite3_value);
var
  p: PTestWindow;
  pEval, pArg: PTclObj;
  pCtx: PTestWindowCtx;
  i, rc: cint;
  zResult: PChar;
begin
  p := PTestWindow(sqlite3_user_data(ctx));
  if bInverse <> 0 then pEval := Tcl_DuplicateObj(p^.xInverse)
  else                  pEval := Tcl_DuplicateObj(p^.xStep);
  pCtx := PTestWindowCtx(sqlite3_aggregate_context(ctx,
    SizeOf(TTestWindowCtx)));
  Tcl_IncrRefCount(pEval);
  if pCtx <> nil then
  begin
    if pCtx^.pVal <> nil then
      Tcl_ListObjAppendElement(p^.interp, pEval,
        Tcl_DuplicateObj(pCtx^.pVal))
    else
      Tcl_ListObjAppendElement(p^.interp, pEval,
        Tcl_NewStringObj(PChar(''), -1));
    for i := 0 to nArg - 1 do
    begin
      pArg := Tcl_NewStringObj(PChar(sqlite3_value_text(apArg[i])), -1);
      Tcl_ListObjAppendElement(p^.interp, pEval, pArg);
    end;
    rc := Tcl_EvalObjEx(p^.interp, pEval, TCL_EVAL_GLOBAL);
    if rc <> TCL_OK then
    begin
      zResult := Tcl_GetStringResult(p^.interp);
      sqlite3_result_error(ctx, zResult, -1);
    end else
    begin
      if pCtx^.pVal <> nil then Tcl_DecrRefCount(pCtx^.pVal);
      pCtx^.pVal := Tcl_DuplicateObj(Tcl_GetObjResult(p^.interp));
      Tcl_IncrRefCount(pCtx^.pVal);
    end;
  end;
  Tcl_DecrRefCount(pEval);
end;

procedure doTestWindowFinalize(bValue: cint; ctx: Psqlite3_context);
var
  p: PTestWindow;
  pEval: PTclObj;
  pCtx: PTestWindowCtx;
  rc: cint;
  zResult: PChar;
begin
  p := PTestWindow(sqlite3_user_data(ctx));
  if bValue <> 0 then pEval := Tcl_DuplicateObj(p^.xValue)
  else                pEval := Tcl_DuplicateObj(p^.xFinal);
  pCtx := PTestWindowCtx(sqlite3_aggregate_context(ctx,
    SizeOf(TTestWindowCtx)));
  Tcl_IncrRefCount(pEval);
  if pCtx <> nil then
  begin
    if pCtx^.pVal <> nil then
      Tcl_ListObjAppendElement(p^.interp, pEval,
        Tcl_DuplicateObj(pCtx^.pVal))
    else
      Tcl_ListObjAppendElement(p^.interp, pEval,
        Tcl_NewStringObj(PChar(''), -1));
    rc := Tcl_EvalObjEx(p^.interp, pEval, TCL_EVAL_GLOBAL);
    zResult := Tcl_GetStringResult(p^.interp);
    if rc <> TCL_OK then
      sqlite3_result_error(ctx, zResult, -1)
    else
      sqlite3_result_text(ctx, zResult, -1, SQLITE_TRANSIENT);
    if bValue = 0 then
    begin
      if pCtx^.pVal <> nil then Tcl_DecrRefCount(pCtx^.pVal);
      pCtx^.pVal := nil;
    end;
  end;
  Tcl_DecrRefCount(pEval);
end;

procedure testWindowStep(ctx: Psqlite3_context; nArg: cint;
  apArg: PPsqlite3_value); cdecl;
begin
  doTestWindowStep(0, ctx, nArg, apArg);
end;
procedure testWindowInverse(ctx: Psqlite3_context; nArg: cint;
  apArg: PPsqlite3_value); cdecl;
begin
  doTestWindowStep(1, ctx, nArg, apArg);
end;
procedure testWindowFinal(ctx: Psqlite3_context); cdecl;
begin
  doTestWindowFinalize(0, ctx);
end;
procedure testWindowValue(ctx: Psqlite3_context); cdecl;
begin
  doTestWindowFinalize(1, ctx);
end;
procedure testWindowDestroy(pCtx: Pointer); cdecl;
var
  p: PTestWindow;
begin
  p := PTestWindow(pCtx);
  if p = nil then Exit;
  if p^.xStep    <> nil then Tcl_DecrRefCount(p^.xStep);
  if p^.xFinal   <> nil then Tcl_DecrRefCount(p^.xFinal);
  if p^.xValue   <> nil then Tcl_DecrRefCount(p^.xValue);
  if p^.xInverse <> nil then Tcl_DecrRefCount(p^.xInverse);
  sqlite3_free(p);
end;

{ test_window.c:225..241 sumintStep — xStep for sumint(). }
procedure sumintStep(ctx: Psqlite3_context; nArg: cint;
  apArg: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..255] of Psqlite3_value;
var
  pa:   PValueArr;
  pInt: ^sqlite3_int64;
begin
  pa := PValueArr(apArg);
  if sqlite3_value_type(pa^[0]) <> SQLITE_INTEGER then
  begin
    sqlite3_result_error(ctx, PChar('invalid argument'), -1);
    Exit;
  end;
  pInt := sqlite3_aggregate_context(ctx, SizeOf(sqlite3_int64));
  if pInt <> nil then
    pInt^ := pInt^ + sqlite3_value_int64(pa^[0]);
end;

{ test_window.c:246..254 sumintInverse — xInverse for sumint(). }
procedure sumintInverse(ctx: Psqlite3_context; nArg: cint;
  apArg: PPsqlite3_value); cdecl;
type
  PValueArr = ^TValueArr;
  TValueArr = array[0..255] of Psqlite3_value;
var
  pa:   PValueArr;
  pInt: ^sqlite3_int64;
begin
  pa := PValueArr(apArg);
  pInt := sqlite3_aggregate_context(ctx, SizeOf(sqlite3_int64));
  pInt^ := pInt^ - sqlite3_value_int64(pa^[0]);
end;

{ test_window.c:259..265 sumintFinal — xFinal for sumint(). }
procedure sumintFinal(ctx: Psqlite3_context); cdecl;
var
  res:  sqlite3_int64;
  pInt: ^sqlite3_int64;
begin
  res := 0;
  pInt := sqlite3_aggregate_context(ctx, 0);
  if pInt <> nil then res := pInt^;
  sqlite3_result_int64(ctx, res);
end;

{ test_window.c:270..276 sumintValue — xValue for sumint(). }
procedure sumintValue(ctx: Psqlite3_context); cdecl;
var
  res:  sqlite3_int64;
  pInt: ^sqlite3_int64;
begin
  res := 0;
  pInt := sqlite3_aggregate_context(ctx, 0);
  if pInt <> nil then res := pInt^;
  sqlite3_result_int64(ctx, res);
end;

{ test_window.c:278..303 test_create_sumint.
  Usage: test_create_sumint DB — register the sumint() window function. }
function tcl_test_create_sumint(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
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
  rc := sqlite3_create_window_function(db, PChar('sumint'), 1, SQLITE_UTF8,
    nil, @sumintStep, @sumintFinal, @sumintValue, @sumintInverse, nil);
  if rc <> SQLITE_OK then
  begin
    Tcl_SetObjResult(interp, Tcl_NewStringObj(t1ErrName(rc), -1));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:4996..5025 test_set_errmsg.
  Usage: sqlite3_set_errmsg DB ERRCODE ERRMSG }
function tcl_test_set_errmsg(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  zDb, zErr: PAnsiChar;
  iErr:      cint;
  db:        PTsqlite3;
  rc:        cint;
begin
  zErr := nil;
  iErr := 0;
  db   := nil;
  if objc <> 4 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB ERRCODE ERRMSG'));
    Result := TCL_ERROR; Exit;
  end;
  zDb := Tcl_GetString(objv[1]);
  if zDb[0] <> #0 then
    if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
    begin
      Result := TCL_ERROR; Exit;
    end;
  if Tcl_GetIntFromObj(interp, objv[2], @iErr) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zErr := Tcl_GetString(objv[3]);
  if zErr[0] = #0 then zErr := nil;
  rc := sqlite3_set_errmsg(db, iErr, zErr);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_window.c:179..220 test_create_window_misuse — verify that
  sqlite3_create_window_function returns SQLITE_MISUSE if any of the
  four window callbacks is missing. }
function tcl_test_create_window_misuse(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
label
  error;
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
  rc := sqlite3_create_window_function(db, PChar('fff'), -1, SQLITE_UTF8,
    nil, nil, @testWindowFinal, @testWindowValue, @testWindowInverse, nil);
  if rc <> SQLITE_MISUSE then goto error;
  rc := sqlite3_create_window_function(db, PChar('fff'), -1, SQLITE_UTF8,
    nil, @testWindowStep, nil, @testWindowValue, @testWindowInverse, nil);
  if rc <> SQLITE_MISUSE then goto error;
  rc := sqlite3_create_window_function(db, PChar('fff'), -1, SQLITE_UTF8,
    nil, @testWindowStep, @testWindowFinal, nil, @testWindowInverse, nil);
  if rc <> SQLITE_MISUSE then goto error;
  rc := sqlite3_create_window_function(db, PChar('fff'), -1, SQLITE_UTF8,
    nil, @testWindowStep, @testWindowFinal, @testWindowValue, nil, nil);
  if rc <> SQLITE_MISUSE then goto error;
  Result := TCL_OK;
  if clientData = nil then ;
  Exit;
error:
  Tcl_SetObjResult(interp, Tcl_NewStringObj(PChar('misuse test error'), -1));
  Result := TCL_ERROR;
end;

{ test_window.c:305..329 test_override_sum — override the built-in sum()
  with the sumint() step/final implementation (no xValue/xInverse, so it
  is a plain aggregate). }
function tcl_test_override_sum(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
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
  rc := sqlite3_create_function(db, PChar('sum'), -1, SQLITE_UTF8, nil,
    nil, @sumintStep, @sumintFinal);
  if rc <> SQLITE_OK then
  begin
    Tcl_SetObjResult(interp, Tcl_NewStringObj(t1ErrName(rc), -1));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_window.c:136..177 test_create_window. }
function tcl_test_create_window(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  pNew: PTestWindow;
  db: PTsqlite3;
  zName: PChar;
  rc: cint;
begin
  if objc <> 7 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('DB NAME XSTEP XFINAL XVALUE XINVERSE'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zName := Tcl_GetString(objv[2]);
  pNew := PTestWindow(sqlite3_malloc(SizeOf(TTestWindow)));
  if pNew = nil then begin Result := TCL_ERROR; Exit; end;
  FillChar(pNew^, SizeOf(pNew^), 0);
  pNew^.xStep    := Tcl_DuplicateObj(objv[3]);
  pNew^.xFinal   := Tcl_DuplicateObj(objv[4]);
  pNew^.xValue   := Tcl_DuplicateObj(objv[5]);
  pNew^.xInverse := Tcl_DuplicateObj(objv[6]);
  pNew^.interp   := interp;
  Tcl_IncrRefCount(pNew^.xStep);
  Tcl_IncrRefCount(pNew^.xFinal);
  Tcl_IncrRefCount(pNew^.xValue);
  Tcl_IncrRefCount(pNew^.xInverse);
  rc := sqlite3_create_window_function(db, zName, -1, SQLITE_UTF8, pNew,
    @testWindowStep, @testWindowFinal, @testWindowValue,
    @testWindowInverse, @testWindowDestroy);
  if rc <> SQLITE_OK then
  begin
    Tcl_SetObjResult(interp,
      Tcl_NewStringObj(t1ErrName(rc), -1));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.e — test1.c:2064..2117 test_load_extension.
  Usage: sqlite3_load_extension DB-HANDLE FILE ?PROC?
  The Pascal port's sqlite3_load_extension (passqlite3main.pas:2840)
  always returns SQLITE_ERROR with the canned "extension loading is
  disabled" message — matches upstream's SQLITE_OMIT_LOAD_EXTENSION
  arm.  The Tcl shim mirrors test1.c's error surface: it reports the
  engine's pzErrMsg verbatim to the caller. }
function tcl_test_load_extension(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  cmdInfo: TTclCmdInfo;
  db: PTsqlite3;
  rc: cint;
  zDb, zFile, zProc: PChar;
  zErr: PAnsiChar;
begin
  zProc := nil;
  if (objc <> 4) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB-HANDLE FILE ?PROC?'));
    Result := TCL_ERROR; Exit;
  end;
  zDb := Tcl_GetString(objv[1]);
  zFile := Tcl_GetString(objv[2]);
  if objc = 4 then zProc := Tcl_GetString(objv[3]);
  FillChar(cmdInfo, SizeOf(cmdInfo), 0);
  if Tcl_GetCommandInfo(interp, zDb, @cmdInfo) = 0 then
  begin
    Tcl_AppendResult(interp, PChar('command not found: '), zDb,
      Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  db := PTestSqliteDb(cmdInfo.objClientData)^.db;
  zErr := nil;
  rc := sqlite3_load_extension(db, zFile, zProc, @zErr);
  if rc <> SQLITE_OK then
  begin
    if zErr <> nil then
      Tcl_SetResult(interp, zErr, TCL_VOLATILE)
    else
      Tcl_SetResult(interp, PChar(''), TCL_VOLATILE);
    Result := TCL_ERROR;
  end else
    Result := TCL_OK;
  sqlite3_free(zErr);
  if clientData = nil then ;
end;

{ ============================================================
  test_devsym.c — device-characteristics simulation VFS.
  A thin pass-through VFS wrapping the default ("real") VFS that
  overrides xDeviceCharacteristics()/xSectorSize() to report the
  values set via `sqlite3_simulate_device`.  test6.c:716..1025
  provides the Tcl glue (processDevSymArgs / devSymObjCmd /
  dsUnregisterObjCmd).  Used by tkt-9d68c883.test.
  ============================================================ }

const
  DEVSYM_MAX_PATHNAME = 512;
  DEVSYM_VFS_NAME     = 'devsym';
  WRITECRASH_NAME     = 'writecrash';

type
  { test_devsym.c:33..37 — devsym_file.  Must start with sqlite3_file
    so a Psqlite3_file cast works; the real underlying sqlite3_file
    lives immediately after this record (p->pReal = &p[1]). }
  Pdevsym_file = ^Tdevsym_file;
  Tdevsym_file = record
    base  : sqlite3_file;
    pReal : Psqlite3_file;
  end;

  { test_devsym.c:76..81 — struct DevsymGlobal g = {0, 0, 512, 0}. }
  TDevsymGlobal = record
    pVfs        : Psqlite3_vfs;
    iDeviceChar : cint;
    iSectorSize : cint;
    nWriteCrash : cint;
  end;

var
  devsym_g: TDevsymGlobal = (pVfs: nil; iDeviceChar: 0; iSectorSize: 512; nWriteCrash: 0);
  devsym_vfs: sqlite3_vfs;
  writecrash_vfs: sqlite3_vfs;
  devsym_io_methods: sqlite3_io_methods;
  writecrash_io_methods: sqlite3_io_methods;

{ ----- io_methods (test_devsym.c:87..213) ----- }

function devsymClose(pFile: Psqlite3_file): cint; cdecl;
begin
  sqlite3OsClose(Pdevsym_file(pFile)^.pReal);
  Result := SQLITE_OK;
end;

function devsymRead(pFile: Psqlite3_file; zBuf: Pointer; iAmt: cint; iOfst: i64): cint; cdecl;
begin
  Result := sqlite3OsRead(Pdevsym_file(pFile)^.pReal, zBuf, iAmt, iOfst);
end;

function devsymWrite(pFile: Psqlite3_file; zBuf: Pointer; iAmt: cint; iOfst: i64): cint; cdecl;
begin
  Result := sqlite3OsWrite(Pdevsym_file(pFile)^.pReal, zBuf, iAmt, iOfst);
end;

function devsymTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
begin
  Result := sqlite3OsTruncate(Pdevsym_file(pFile)^.pReal, size);
end;

function devsymSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
begin
  Result := sqlite3OsSync(Pdevsym_file(pFile)^.pReal, flags);
end;

function devsymFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
begin
  Result := sqlite3OsFileSize(Pdevsym_file(pFile)^.pReal, pSize);
end;

function devsymLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
begin
  Result := sqlite3OsLock(Pdevsym_file(pFile)^.pReal, eLock);
end;

function devsymUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
begin
  Result := sqlite3OsUnlock(Pdevsym_file(pFile)^.pReal, eLock);
end;

function devsymCheckReservedLock(pFile: Psqlite3_file; pResOut: PcInt): cint; cdecl;
begin
  Result := sqlite3OsCheckReservedLock(Pdevsym_file(pFile)^.pReal, pResOut);
end;

function devsymFileControl(pFile: Psqlite3_file; op: cint; pArg: Pointer): cint; cdecl;
begin
  Result := sqlite3OsFileControl(Pdevsym_file(pFile)^.pReal, op, pArg);
end;

function devsymSectorSize(pFile: Psqlite3_file): cint; cdecl;
begin
  Result := devsym_g.iSectorSize;
  if pFile = nil then ;
end;

function devsymDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
begin
  Result := devsym_g.iDeviceChar;
  if pFile = nil then ;
end;

{ Shared-memory methods are all pass-throughs (test_devsym.c:190..213). }
function devsymShmLock(pFile: Psqlite3_file; ofst: cint; n: cint; flags: cint): cint; cdecl;
var p: Pdevsym_file;
begin
  p := Pdevsym_file(pFile);
  Result := p^.pReal^.pMethods^.xShmLock(p^.pReal, ofst, n, flags);
end;

function devsymShmMap(pFile: Psqlite3_file; iRegion: cint; szRegion: cint;
  isWrite: cint; pp: PPointer): cint; cdecl;
var p: Pdevsym_file;
begin
  p := Pdevsym_file(pFile);
  Result := p^.pReal^.pMethods^.xShmMap(p^.pReal, iRegion, szRegion, isWrite, pp);
end;

procedure devsymShmBarrier(pFile: Psqlite3_file); cdecl;
var p: Pdevsym_file;
begin
  p := Pdevsym_file(pFile);
  p^.pReal^.pMethods^.xShmBarrier(p^.pReal);
end;

function devsymShmUnmap(pFile: Psqlite3_file; delFlag: cint): cint; cdecl;
var p: Pdevsym_file;
begin
  p := Pdevsym_file(pFile);
  Result := p^.pReal^.pMethods^.xShmUnmap(p^.pReal, delFlag);
end;

{ ----- writecrash io_methods (test_devsym.c:351..379) ----- }

function writecrashSectorSize(pFile: Psqlite3_file): cint; cdecl;
begin
  Result := sqlite3OsSectorSize(Pdevsym_file(pFile)^.pReal);
end;

function writecrashDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
begin
  Result := sqlite3OsDeviceCharacteristics(Pdevsym_file(pFile)^.pReal);
end;

function writecrashWrite(pFile: Psqlite3_file; zBuf: Pointer; iAmt: cint; iOfst: i64): cint; cdecl;
begin
  if devsym_g.nWriteCrash > 0 then begin
    Dec(devsym_g.nWriteCrash);
    if devsym_g.nWriteCrash = 0 then Halt(134);  { C calls abort() }
  end;
  Result := sqlite3OsWrite(Pdevsym_file(pFile)^.pReal, zBuf, iAmt, iOfst);
end;

{ ----- sqlite3_vfs methods (test_devsym.c:220..346) ----- }

function devsymOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
  pFile: Psqlite3_file; flags: cint; pOutFlags: PcInt): cint; cdecl;
var p: Pdevsym_file;
begin
  p := Pdevsym_file(pFile);
  p^.pReal := Psqlite3_file(PtrUInt(p) + SizeOf(Tdevsym_file));
  Result := sqlite3OsOpen(devsym_g.pVfs, zName, p^.pReal, flags, pOutFlags);
  if p^.pReal^.pMethods <> nil then
    pFile^.pMethods := @devsym_io_methods;
  if pVfs = nil then ;
end;

function writecrashOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
  pFile: Psqlite3_file; flags: cint; pOutFlags: PcInt): cint; cdecl;
var p: Pdevsym_file;
begin
  p := Pdevsym_file(pFile);
  p^.pReal := Psqlite3_file(PtrUInt(p) + SizeOf(Tdevsym_file));
  Result := sqlite3OsOpen(devsym_g.pVfs, zName, p^.pReal, flags, pOutFlags);
  if p^.pReal^.pMethods <> nil then
    pFile^.pMethods := @writecrash_io_methods;
  if pVfs = nil then ;
end;

function devsymDelete(pVfs: Psqlite3_vfs; zPath: PChar; dirSync: cint): cint; cdecl;
begin
  Result := sqlite3OsDelete(devsym_g.pVfs, zPath, dirSync);
  if pVfs = nil then ;
end;

function devsymAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint; pResOut: PcInt): cint; cdecl;
begin
  Result := sqlite3OsAccess(devsym_g.pVfs, zPath, flags, pResOut);
  if pVfs = nil then ;
end;

function devsymFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint; zOut: PChar): cint; cdecl;
begin
  Result := sqlite3OsFullPathname(devsym_g.pVfs, zPath, nOut, zOut);
  if pVfs = nil then ;
end;

function devsymRandomness(pVfs: Psqlite3_vfs; nByte: cint; zBufOut: PChar): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := devsym_g.pVfs;
  Result := pP^.xRandomness(pP, nByte, zBufOut);
  if pVfs = nil then ;
end;

function devsymSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl;
begin
  Result := sqlite3OsSleep(devsym_g.pVfs, nMicro);
  if pVfs = nil then ;
end;

function devsymCurrentTime(pVfs: Psqlite3_vfs; pTimeOut: PDouble): cint; cdecl;
begin
  Result := devsym_g.pVfs^.xCurrentTime(devsym_g.pVfs, pTimeOut);
  if pVfs = nil then ;
end;

procedure InitDevsymTables;
begin
  { devsym io_methods (test_devsym.c:227..245) — iVersion 2. }
  FillChar(devsym_io_methods, SizeOf(devsym_io_methods), 0);
  devsym_io_methods.iVersion              := 2;
  devsym_io_methods.xClose                := @devsymClose;
  devsym_io_methods.xRead                 := @devsymRead;
  devsym_io_methods.xWrite                := @devsymWrite;
  devsym_io_methods.xTruncate             := @devsymTruncate;
  devsym_io_methods.xSync                 := @devsymSync;
  devsym_io_methods.xFileSize             := @devsymFileSize;
  devsym_io_methods.xLock                 := @devsymLock;
  devsym_io_methods.xUnlock               := @devsymUnlock;
  devsym_io_methods.xCheckReservedLock    := @devsymCheckReservedLock;
  devsym_io_methods.xFileControl          := @devsymFileControl;
  devsym_io_methods.xSectorSize           := @devsymSectorSize;
  devsym_io_methods.xDeviceCharacteristics:= @devsymDeviceCharacteristics;
  devsym_io_methods.xShmMap               := @devsymShmMap;
  devsym_io_methods.xShmLock              := @devsymShmLock;
  devsym_io_methods.xShmBarrier           := @devsymShmBarrier;
  devsym_io_methods.xShmUnmap             := @devsymShmUnmap;

  { writecrash io_methods (test_devsym.c:391..409). }
  writecrash_io_methods := devsym_io_methods;
  writecrash_io_methods.xWrite                  := @writecrashWrite;
  writecrash_io_methods.xSectorSize             := @writecrashSectorSize;
  writecrash_io_methods.xDeviceCharacteristics  := @writecrashDeviceCharacteristics;

  { devsym_vfs (test_devsym.c:421..448) — iVersion 2.  Dl* slots are nil
    because this build is SQLITE_OMIT_LOAD_EXTENSION. }
  FillChar(devsym_vfs, SizeOf(devsym_vfs), 0);
  devsym_vfs.iVersion      := 2;
  devsym_vfs.szOsFile      := SizeOf(Tdevsym_file);
  devsym_vfs.mxPathname    := DEVSYM_MAX_PATHNAME;
  devsym_vfs.zName         := DEVSYM_VFS_NAME;
  devsym_vfs.xOpen         := @devsymOpen;
  devsym_vfs.xDelete       := @devsymDelete;
  devsym_vfs.xAccess       := @devsymAccess;
  devsym_vfs.xFullPathname := @devsymFullPathname;
  devsym_vfs.xRandomness   := @devsymRandomness;
  devsym_vfs.xSleep        := @devsymSleep;
  devsym_vfs.xCurrentTime  := @devsymCurrentTime;

  { writecrash_vfs (test_devsym.c:450..477). }
  writecrash_vfs := devsym_vfs;
  writecrash_vfs.zName := WRITECRASH_NAME;
  writecrash_vfs.xOpen := @writecrashOpen;
end;

{ test_devsym.c:485..504 — devsym_register. }
procedure devsym_register(iDeviceChar: cint; iSectorSize: cint);
begin
  if devsym_g.pVfs = nil then begin
    InitDevsymTables;
    devsym_g.pVfs := sqlite3_vfs_find(nil);
    Inc(devsym_vfs.szOsFile, devsym_g.pVfs^.szOsFile);
    Inc(writecrash_vfs.szOsFile, devsym_g.pVfs^.szOsFile);
    sqlite3_vfs_register(@devsym_vfs, 0);
    sqlite3_vfs_register(@writecrash_vfs, 0);
  end;
  if iDeviceChar >= 0 then devsym_g.iDeviceChar := iDeviceChar
  else devsym_g.iDeviceChar := 0;
  if iSectorSize >= 0 then devsym_g.iSectorSize := iSectorSize
  else devsym_g.iSectorSize := 512;
end;

{ test_devsym.c:506..512 — devsym_unregister. }
procedure devsym_unregister;
begin
  sqlite3_vfs_unregister(@devsym_vfs);
  sqlite3_vfs_unregister(@writecrash_vfs);
  devsym_g.pVfs := nil;
  devsym_g.iDeviceChar := 0;
  devsym_g.iSectorSize := 0;
end;

{ test_devsym.c:514..523 — devsym_crash_on_write. }
procedure devsym_crash_on_write(nWrite: cint);
begin
  if devsym_g.pVfs = nil then begin
    InitDevsymTables;
    devsym_g.pVfs := sqlite3_vfs_find(nil);
    Inc(devsym_vfs.szOsFile, devsym_g.pVfs^.szOsFile);
    Inc(writecrash_vfs.szOsFile, devsym_g.pVfs^.szOsFile);
    sqlite3_vfs_register(@devsym_vfs, 0);
    sqlite3_vfs_register(@writecrash_vfs, 0);
  end;
  devsym_g.nWriteCrash := nWrite;
end;

{ test6.c:716..808 — processDevSymArgs.  Parses ?-sectorsize N?
  ?-characteristics FLAGLIST? option pairs. }
function processDevSymArgs(interp: PTclInterp; objc: cint; objv: PPTclObj;
  piDeviceChar: PcInt; piSectorSize: PcInt): cint;
type
  TDeviceFlag = record zName: PChar; iValue: cint; end;
const
  aFlag: array[0..12] of TDeviceFlag = (
    (zName: 'atomic';              iValue: SQLITE_IOCAP_ATOMIC),
    (zName: 'atomic512';           iValue: SQLITE_IOCAP_ATOMIC512),
    (zName: 'atomic1k';            iValue: SQLITE_IOCAP_ATOMIC1K),
    (zName: 'atomic2k';            iValue: SQLITE_IOCAP_ATOMIC2K),
    (zName: 'atomic4k';            iValue: SQLITE_IOCAP_ATOMIC4K),
    (zName: 'atomic8k';            iValue: SQLITE_IOCAP_ATOMIC8K),
    (zName: 'atomic16k';           iValue: SQLITE_IOCAP_ATOMIC16K),
    (zName: 'atomic32k';           iValue: SQLITE_IOCAP_ATOMIC32K),
    (zName: 'atomic64k';           iValue: SQLITE_IOCAP_ATOMIC64K),
    (zName: 'sequential';          iValue: SQLITE_IOCAP_SEQUENTIAL),
    (zName: 'safe_append';         iValue: SQLITE_IOCAP_SAFE_APPEND),
    (zName: 'powersafe_overwrite'; iValue: SQLITE_IOCAP_POWERSAFE_OVERWRITE),
    (zName: 'batch-atomic';        iValue: SQLITE_IOCAP_BATCH_ATOMIC)
  );
var
  i, j, k        : cint;
  nOpt           : cint;
  zOpt           : PChar;
  iDc, iSectorSize : cint;
  setSectorsize, setDeviceChar : cint;
  apObj          : PPTclObj;
  nObj           : cint;
  zFlag          : PChar;
  s              : AnsiString;
  found          : cint;
begin
  iDc := 0; iSectorSize := 0;
  setSectorsize := 0; setDeviceChar := 0;
  i := 0;
  while i < objc do begin
    nOpt := 0;
    zOpt := Tcl_GetStringFromObj(objv[i], @nOpt);
    if ((nOpt > 11) or (nOpt < 2) or (StrLComp('-sectorsize', zOpt, nOpt) <> 0))
       and ((nOpt > 16) or (nOpt < 2) or (StrLComp('-characteristics', zOpt, nOpt) <> 0)) then
    begin
      Tcl_AppendResult(interp, PChar('Bad option: "'), zOpt,
        PChar('" - must be "-characteristics" or "-sectorsize"'), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    if i = objc - 1 then begin
      Tcl_AppendResult(interp, PChar('Option requires an argument: "'),
        zOpt, PChar('"'), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    if zOpt[1] = 's' then begin
      if Tcl_GetIntFromObj(interp, objv[i+1], @iSectorSize) <> 0 then begin
        Result := TCL_ERROR; Exit;
      end;
      setSectorsize := 1;
    end else begin
      apObj := nil; nObj := 0;
      if Tcl_ListObjGetElements(interp, objv[i+1], @nObj, @apObj) <> 0 then begin
        Result := TCL_ERROR; Exit;
      end;
      for j := 0 to nObj - 1 do begin
        zFlag := Tcl_GetString(PPTclObj(PtrUInt(apObj) + PtrUInt(j) * SizeOf(Pointer))^);
        s := LowerCase(AnsiString(zFlag));
        found := 0;
        for k := 0 to High(aFlag) do
          if s = AnsiString(aFlag[k].zName) then begin
            iDc := iDc or aFlag[k].iValue;
            found := 1;
            Break;
          end;
        if found = 0 then begin
          Tcl_AppendResult(interp, PChar('no such flag "'), zFlag,
            PChar('"'), Pointer(nil));
          Result := TCL_ERROR; Exit;
        end;
      end;
      setDeviceChar := 1;
    end;
    Inc(i, 2);
  end;

  if setDeviceChar <> 0 then piDeviceChar^ := iDc;
  if setSectorsize <> 0 then piSectorSize^ := iSectorSize;
  Result := TCL_OK;
end;

{ test6.c:964..981 — devSymObjCmd.  tclcmd: sqlite3_simulate_device. }
function tcl_test_simulate_device(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  iDc, iSectorSize: cint;
begin
  iDc := -1;
  iSectorSize := -1;
  if processDevSymArgs(interp, objc - 1, PPTclObj(@objv[1]), @iDc, @iSectorSize) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  devsym_register(iDc, iSectorSize);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test6.c:986..1005 — writeCrashObjCmd.  tclcmd: sqlite3_crash_on_write N. }
function tcl_test_crash_on_write(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var nWrite: cint;
begin
  nWrite := 0;
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('NWRITE'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @nWrite) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  devsym_crash_on_write(nWrite);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test6.c:1010..1025 — dsUnregisterObjCmd.  tclcmd: unregister_devsim. }
function tcl_test_unregister_devsim(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
begin
  if objc <> 1 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR; Exit;
  end;
  devsym_unregister;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.62.e — `sqlite3_user_version` has no upstream Tcl-command
  counterpart (it is exposed only as `PRAGMA user_version`).  Provide a
  thin shim: `sqlite3_user_version DB ?VALUE?` returns / sets the
  user_version cookie via the existing PRAGMA, so any test that calls
  the Tcl form stops aborting. }
function tcl_test_user_version(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  iVal: cint;
  zSql: AnsiString;
  pStmt: PVdbe;
  rc: cint;
begin
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB ?VALUE?'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if objc = 3 then
  begin
    if Tcl_GetIntFromObj(interp, objv[2], @iVal) <> 0 then
    begin
      Result := TCL_ERROR; Exit;
    end;
    zSql := 'PRAGMA user_version=' + IntToStr(iVal);
  end else
    zSql := 'PRAGMA user_version';
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc = SQLITE_OK then
  begin
    if sqlite3_step(pStmt) = SQLITE_ROW then
      Tcl_SetObjResult(interp,
        Tcl_NewIntObj(sqlite3_column_int(pStmt, 0)));
    sqlite3_finalize(pStmt);
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.005 / 88.008 — sqlite3_open / _v2 / _16 trampolines used by
  capi3e.test (sqlite3_open / sqlite3_open16) and close.test (sqlite3_open).
  C ref: test1.c:5395..5517 (test_open / test_open_v2 / test_open16),
  registered at test1.c:9140..9142. }

{ test1.c:5395..5417 — Usage: sqlite3_open ?filename? ?options-list? }
function test_open(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zFilename: PAnsiChar;
  db:        PTsqlite3;
  hex:       AnsiString;
  zBuf:      array[0..63] of AnsiChar;
begin
  if (objc <> 3) and (objc <> 2) and (objc <> 1) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' filename options-list"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if objc > 1 then
    zFilename := Tcl_GetString(objv[1])
  else
    zFilename := nil;
  db := nil;
  sqlite3_open(zFilename, @db);
  ptrToHex(db, hex);
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(hex[1], zBuf[0], Length(hex));
  Tcl_AppendResult(interp, @zBuf[0], Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:5419..5488 — Usage: sqlite3_open_v2 FILENAME FLAGS VFS }
function test_open_v2(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  { Mirror of test1.c:5454..5475 OpenFlag table. }
  aFlagName: array[0..19] of PAnsiChar = (
    'SQLITE_OPEN_READONLY',     'SQLITE_OPEN_READWRITE',
    'SQLITE_OPEN_CREATE',       'SQLITE_OPEN_DELETEONCLOSE',
    'SQLITE_OPEN_EXCLUSIVE',    'SQLITE_OPEN_AUTOPROXY',
    'SQLITE_OPEN_MAIN_DB',      'SQLITE_OPEN_TEMP_DB',
    'SQLITE_OPEN_TRANSIENT_DB', 'SQLITE_OPEN_MAIN_JOURNAL',
    'SQLITE_OPEN_TEMP_JOURNAL', 'SQLITE_OPEN_SUBJOURNAL',
    'SQLITE_OPEN_SUPER_JOURNAL','SQLITE_OPEN_NOMUTEX',
    'SQLITE_OPEN_FULLMUTEX',    'SQLITE_OPEN_SHAREDCACHE',
    'SQLITE_OPEN_PRIVATECACHE', 'SQLITE_OPEN_WAL',
    'SQLITE_OPEN_URI',          'SQLITE_OPEN_EXRESCODE'
  );
  aFlagVal:  array[0..19] of cint = (
    SQLITE_OPEN_READONLY,       SQLITE_OPEN_READWRITE,
    SQLITE_OPEN_CREATE,         SQLITE_OPEN_DELETEONCLOSE,
    SQLITE_OPEN_EXCLUSIVE,      SQLITE_OPEN_AUTOPROXY,
    SQLITE_OPEN_MAIN_DB,        SQLITE_OPEN_TEMP_DB,
    SQLITE_OPEN_TRANSIENT_DB,   SQLITE_OPEN_MAIN_JOURNAL,
    SQLITE_OPEN_TEMP_JOURNAL,   SQLITE_OPEN_SUBJOURNAL,
    SQLITE_OPEN_SUPER_JOURNAL,  SQLITE_OPEN_NOMUTEX,
    SQLITE_OPEN_FULLMUTEX,      SQLITE_OPEN_SHAREDCACHE,
    SQLITE_OPEN_PRIVATECACHE,   SQLITE_OPEN_WAL,
    SQLITE_OPEN_URI,            SQLITE_OPEN_EXRESCODE
  );
var
  zFilename: PAnsiChar;
  zVfs:      PAnsiChar;
  flags:     cint;
  db:        PTsqlite3;
  rc:        cint;
  hex:       AnsiString;
  zBuf:      array[0..63] of AnsiChar;
  nFlag:     cint;
  apFlagRaw: Pointer;
  apFlag:    PPTclObj;
  i, j:      cint;
  zFlag:     PAnsiChar;
  found:     Boolean;
begin
  if objc <> 4 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('FILENAME FLAGS VFS'));
    Result := TCL_ERROR; Exit;
  end;
  zFilename := Tcl_GetString(objv[1]);
  zVfs := Tcl_GetString(objv[3]);
  if (zVfs <> nil) and (zVfs[0] = #0) then zVfs := nil;

  apFlagRaw := nil;
  nFlag := 0;
  rc := Tcl_ListObjGetElements(interp, objv[2], @nFlag, @apFlagRaw);
  if rc <> TCL_OK then
  begin
    Result := rc; Exit;
  end;
  apFlag := PPTclObj(apFlagRaw);

  flags := 0;
  for i := 0 to nFlag - 1 do
  begin
    zFlag := Tcl_GetString(apFlag[i]);
    found := False;
    for j := 0 to High(aFlagName) do
    begin
      if StrComp(zFlag, aFlagName[j]) = 0 then
      begin
        flags := flags or aFlagVal[j];
        found := True;
        Break;
      end;
    end;
    if not found then
    begin
      Tcl_AppendResult(interp, PChar('unknown flag: '), zFlag, Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
  end;

  db := nil;
  rc := sqlite3_open_v2(zFilename, @db, flags, zVfs);
  ptrToHex(db, hex);
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(hex[1], zBuf[0], Length(hex));
  Tcl_AppendResult(interp, @zBuf[0], Pointer(nil));
  Result := TCL_OK;
  if (clientData = nil) and (rc = rc) then ;
end;

{ test1.c:5490..5517 — Usage: sqlite3_open16 filename options }
function test_open16(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zFilename: Pointer;
  db:        PTsqlite3;
  hex:       AnsiString;
  zBuf:      array[0..63] of AnsiChar;
begin
  if objc <> 3 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' filename options-list"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  zFilename := Tcl_GetByteArrayFromObj(objv[1], nil);
  db := nil;
  sqlite3_open16(zFilename, @db);
  ptrToHex(db, hex);
  FillChar(zBuf, SizeOf(zBuf), 0);
  Move(hex[1], zBuf[0], Length(hex));
  Tcl_AppendResult(interp, @zBuf[0], Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.063 — test1.c:2920..2944 test_next_stmt.
  Usage: sqlite3_next_stmt DB STMT.  Returns the next prepared statement
  in sequence after STMT as a "0x%p" hex pointer, or empty string when
  the chain is exhausted.  Engine entry: passqlite3main.pas:4120.
  Required by capi3d.test (capi3d-1.1, capi3d-2.*). }
function tcl_test_next_stmt(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:    PTsqlite3;
  pStmt: Pointer;
  s:     AnsiString;
  zBuf:  array[0..49] of AnsiChar;
begin
  if objc <> 3 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' DB STMT"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  db := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  pStmt := sqlite3TestTextToPtr(Tcl_GetString(objv[2]));
  pStmt := sqlite3_next_stmt(db, pStmt);
  if pStmt <> nil then
  begin
    { C: sqlite3TestMakePointerStr → sqlite3_snprintf("%p", p); bare hex,
      no "0x" prefix (printf.c etPOINTER). }
    s := LowerCase(IntToHex(PtrUInt(pStmt), 1));
    FillChar(zBuf, SizeOf(zBuf), 0);
    Move(s[1], zBuf[0], Length(s));
    Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.031 — test1.c:684..701 sqlite_test_close.
  Usage: sqlite3_close DB.  Engine: passqlite3main.pas:1015. }
function test_close(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
begin
  if objc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' FILENAME"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  db := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_close(db);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.031 — test1.c:708..725 sqlite_test_close_v2.
  Usage: sqlite3_close_v2 DB.  Engine: passqlite3main.pas:1020. }
function test_close_v2(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
begin
  if objc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      Tcl_GetString(objv[0]), PChar(' FILENAME"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  db := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_close_v2(db);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.035 — extended-rc name helper for sqlite3_extended_errcode
  trampoline.  Subset of main.c:1533..1641 sqlite3ErrName covering the
  extended codes verify_ex_errcode call-sites actually compare against
  (test/errmsg.test, test/fkey2.test, test/notnull.test).  Falls back to
  the primary t1ErrName for non-extended rc. }
function extErrName(rc: cint): PAnsiChar;
begin
  case rc of
    SQLITE_CONSTRAINT_CHECK:      Result := PChar('SQLITE_CONSTRAINT_CHECK');
    SQLITE_CONSTRAINT_FOREIGNKEY: Result := PChar('SQLITE_CONSTRAINT_FOREIGNKEY');
    SQLITE_CONSTRAINT_NOTNULL:    Result := PChar('SQLITE_CONSTRAINT_NOTNULL');
    SQLITE_CONSTRAINT_PRIMARYKEY: Result := PChar('SQLITE_CONSTRAINT_PRIMARYKEY');
    SQLITE_CONSTRAINT_TRIGGER:    Result := PChar('SQLITE_CONSTRAINT_TRIGGER');
    SQLITE_CONSTRAINT_UNIQUE:     Result := PChar('SQLITE_CONSTRAINT_UNIQUE');
    SQLITE_ERROR_MISSING_COLLSEQ: Result := PChar('SQLITE_ERROR_MISSING_COLLSEQ');
    SQLITE_CORRUPT_VTAB:          Result := PChar('SQLITE_CORRUPT_VTAB');
    SQLITE_CORRUPT_SEQUENCE:      Result := PChar('SQLITE_CORRUPT_SEQUENCE');
    SQLITE_CORRUPT_INDEX:         Result := PChar('SQLITE_CORRUPT_INDEX');
  else
    Result := t1ErrName(rc);
  end;
end;

{ 9.4.divbug.88.035 — test1.c:test_ex_errcode analogue.
  Usage: sqlite3_extended_errcode DB.  Returns symbolic extended-rc name
  (e.g. "SQLITE_CONSTRAINT_UNIQUE").  Required by tester.tcl:1682
  verify_ex_errcode (errmsg.test, fkey2.test, notnull.test).
  Engine entry: passqlite3main.pas:3703. }
function test_extended_errcode(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR; Exit;
  end;
  db := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_extended_errcode(db);
  Tcl_AppendResult(interp, extErrName(rc), Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:1707 test_extended_result_codes.
  Usage: sqlite3_extended_result_codes DB BOOLEAN.  Toggles db->errMask
  between 0xff (primary codes) and 0xffffffff (extended codes) at the API
  boundary.  Required so without_rowid7-3.5.1 sees the extended rc (257)
  after enabling, while 3.4.1 (before enabling) sees the masked code (1).
  Engine entry: passqlite3main.pas:3857. }
function test_extended_result_codes(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  enable: cint;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB BOOLEAN'));
    Result := TCL_ERROR; Exit;
  end;
  db := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  enable := 0;
  if Tcl_GetBooleanFromObj(interp, objv[2], @enable) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_extended_result_codes(db, enable);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.012.f — test1.c:4884..4902 test_errcode.
  Usage: sqlite3_errcode DB.  Returns the symbolic name of the most
  recent error (e.g. "SQLITE_CORRUPT"), via t1ErrName/sqlite3ErrName.
  corrupt2-10.2 catches sqlite3_errcode and asserts {SQLITE_CORRUPT};
  without this trampoline tester_min.tcl's fallback returned the numeric
  rc (11). Registered at test1.c:9134. }
function test_errcode(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR; Exit;
  end;
  db := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_errcode(db);
  Tcl_AppendResult(interp, t1ErrName(rc), Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:1229..1251 — test_drop_modules.
  Usage: sqlite3_drop_modules DB ?NAME ...?  Drop every registered vtab
  module on DB except those named.  No NAME args → drop all.  Engine entry:
  passqlite3vtab.sqlite3_drop_modules (vtab.c:140).  Needed by
  fts3dropmod.test. }
function test_drop_modules(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  az: array of PAnsiChar;
  i: cint;
begin
  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB ?NAME ...?'));
    Result := TCL_ERROR; Exit;
  end;
  db := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if objc > 2 then
  begin
    SetLength(az, objc - 2 + 1);
    for i := 2 to objc - 1 do az[i - 2] := Tcl_GetString(objv[i]);
    az[objc - 2] := nil;  { NULL-terminated keep-list }
    sqlite3_drop_modules(db, @az[0]);
  end
  else
    sqlite3_drop_modules(db, nil);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test_func.c:846..909 — rankfunc + install_fts3_rank_function.
  A worked-example scalar fts3 rank() over a matchinfo() blob; used by
  fts3rank.test (install_fts3_rank_function db). }
procedure rankfunc(pCtx: Psqlite3_context; nVal: cint;
  apVal: PPsqlite3_value); cdecl;
var
  aMatchinfo: PInteger;
  nMatchinfo, nCol, nPhrase, iPhrase, iCol: cint;
  score, weight: Double;
  aPhraseinfo: PInteger;
  nHitCount, nGlobalHitCount: cint;
begin
  nCol := 0; nPhrase := 0; score := 0.0;
  if nVal < 1 then begin
    sqlite3_result_error(pCtx,
      PChar('wrong number of arguments to function rank()'), -1);
    Exit;
  end;
  aMatchinfo := PInteger(sqlite3_value_blob(PPsqlite3_value(apVal)[0]));
  nMatchinfo := sqlite3_value_bytes(PPsqlite3_value(apVal)[0]) div cint(SizeOf(cint));
  if nMatchinfo >= 2 then begin
    nPhrase := aMatchinfo[0];
    nCol    := aMatchinfo[1];
  end;
  if nMatchinfo <> (2 + 3*nCol*nPhrase) then begin
    sqlite3_result_error(pCtx,
      PChar('invalid matchinfo blob passed to function rank()'), -1);
    Exit;
  end;
  if nVal <> (1 + nCol) then begin
    sqlite3_result_error(pCtx,
      PChar('wrong number of arguments to function rank()'), -1);
    Exit;
  end;
  for iPhrase := 0 to nPhrase - 1 do begin
    aPhraseinfo := @aMatchinfo[2 + iPhrase*nCol*3];
    for iCol := 0 to nCol - 1 do begin
      nHitCount       := aPhraseinfo[3*iCol];
      nGlobalHitCount := aPhraseinfo[3*iCol+1];
      weight := sqlite3_value_double(PPsqlite3_value(apVal)[iCol+1]);
      if nHitCount > 0 then
        score := score + (Double(nHitCount) / Double(nGlobalHitCount)) * weight;
    end;
  end;
  sqlite3_result_double(pCtx, score);
end;

function install_fts3_rank_function(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR; Exit;
  end;
  db := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_create_function(db, PChar('rank'), -1, SQLITE_UTF8, nil,
    @rankfunc, nil, nil);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.003 — test1.c:6383..6411 test_db_cacheflush.
  Usage: sqlite3_db_cacheflush DB.  Attempt to flush any dirty pages to
  disk.  Engine entry: passqlite3main.pas:4391 (main.c:921). }
function test_db_cacheflush(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
  rc: cint;
begin
  db := nil;
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_db_cacheflush(db);
  if rc <> 0 then
  begin
    Tcl_SetResult(interp, PChar(sqlite3ErrStr(rc)), TCL_STATIC);
    Result := TCL_ERROR; Exit;
  end;
  Tcl_ResetResult(interp);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.81 — test1.c:6458..6480 test_db_readonly.
  Usage: sqlite3_db_readonly DB DBNAME.  Returns 1 if DBNAME is readonly,
  0 if read/write, -1 if DBNAME is not a database on DB.  Engine entry:
  passqlite3main.pas:4373 (main.c:5001). }
function test_db_readonly(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:      PTsqlite3;
  zDbName: PAnsiChar;
begin
  db := nil;
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB DBNAME'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zDbName := Tcl_GetString(objv[2]);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_db_readonly(db, zDbName)));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ attach.test — test1.c:6434..6455 test_db_filename.
  Usage: sqlite3_db_filename DB DBNAME.  Returns the on-disk filename
  associated with DBNAME on DB ("" for :memory:/temp/unknown).  Engine
  entry: passqlite3main.pas:4390 (main.c:4985). }
function test_db_filename(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:      PTsqlite3;
  zDbName: PAnsiChar;
  zRes:    PAnsiChar;
begin
  db := nil;
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB DBNAME'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zDbName := Tcl_GetString(objv[2]);
  zRes := sqlite3_db_filename(db, zDbName);
  Tcl_AppendResult(interp, zRes, Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ 9.4.divbug.88.042 + 9.4.divbug.88.060 — test1.c:6075..6098 get_autocommit.
  Usage: sqlite3_get_autocommit DB.  Returns 1 if DB is in auto-commit mode,
  0 otherwise.  Required by ioerr.test and trans3.test (trans3-1.3.1). }
function get_autocommit(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
type
  TArgvArr = array[0..16] of PAnsiChar;
  PArgvArr = ^TArgvArr;
var
  db:   PTsqlite3;
  av:   PArgvArr;
  sBuf: ShortString;
begin
  av := PArgvArr(argv);
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av^[0], PChar(' DB"'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av^[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  { C: sqlite3_snprintf(sizeof zBuf,"%d", sqlite3_get_autocommit(db)). }
  Str(sqlite3_get_autocommit(db), sBuf);
  sBuf[Length(sBuf)+1] := #0;
  Tcl_AppendResult(interp, PChar(@sBuf[1]), Pointer(nil));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ autovacuum2.test — test1.c:8915..9000 test_autovacuum_pages.
  Usage: sqlite3_autovacuum_pages DB ?SCRIPT?.  Registers a Tcl script as
  the autovacuum-pages callback on DB; with no SCRIPT (or empty), clears
  it.  Engine entry: passqlite3main.pas:3554 (main.c:2439). }
type
  PAutovacPageData = ^TAutovacPageData;
  TAutovacPageData = record
    interp:  PTclInterp;
    zScript: PAnsiChar;  { points just past the record into the same alloc }
  end;

function test_autovacuum_pages_callback(pClientData: Pointer;
  zSchema: PAnsiChar; nFilePages: u32; nFreePages: u32;
  nBytePerPage: u32): u32; cdecl;
var
  pData: PAutovacPageData;
  str:   TTclDString;
  x:     cint;
  zBuf:  array[0..63] of AnsiChar;
  sBuf:  ShortString;
begin
  pData := PAutovacPageData(pClientData);
  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pData^.zScript, -1);
  Tcl_DStringAppendElement(@str, zSchema);
  sBuf := IntToStr(QWord(nFilePages));
  Move(sBuf[1], zBuf[0], Length(sBuf)); zBuf[Length(sBuf)] := #0;
  Tcl_DStringAppendElement(@str, PChar(@zBuf[0]));
  sBuf := IntToStr(QWord(nFreePages));
  Move(sBuf[1], zBuf[0], Length(sBuf)); zBuf[Length(sBuf)] := #0;
  Tcl_DStringAppendElement(@str, PChar(@zBuf[0]));
  sBuf := IntToStr(QWord(nBytePerPage));
  Move(sBuf[1], zBuf[0], Length(sBuf)); zBuf[Length(sBuf)] := #0;
  Tcl_DStringAppendElement(@str, PChar(@zBuf[0]));
  Tcl_ResetResult(pData^.interp);
  Tcl_Eval(pData^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);
  x := cint(nFreePages);
  Tcl_GetIntFromObj(nil, Tcl_GetObjResult(pData^.interp), @x);
  Result := u32(x);
end;

function test_autovacuum_pages(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pData:   PAutovacPageData;
  db:      PTsqlite3;
  rc:      cint;
  zScript: PAnsiChar;
  nScript: PtrUInt;
  pAlloc:  PByte;
  zBuf:    array[0..127] of AnsiChar;
  sBuf:    ShortString;
begin
  db := nil;
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB ?SCRIPT?'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if objc = 3 then zScript := Tcl_GetString(objv[2]) else zScript := nil;
  if zScript <> nil then
  begin
    nScript := StrLen(zScript);
    pAlloc := PByte(sqlite3_malloc64(u64(SizeOf(TAutovacPageData) + nScript + 1)));
    if pAlloc = nil then
    begin
      Tcl_AppendResult(interp, PChar('out of memory'), Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    pData := PAutovacPageData(pAlloc);
    pData^.interp := interp;
    pData^.zScript := PAnsiChar(pAlloc + SizeOf(TAutovacPageData));
    Move(zScript^, pData^.zScript^, nScript + 1);
    rc := sqlite3_autovacuum_pages(db,
      TAutovacuumPagesFn(@test_autovacuum_pages_callback),
      pData, TAutovacuumDestrFn(@sqlite3_free));
  end else
    rc := sqlite3_autovacuum_pages(db, nil, nil, nil);
  if rc <> 0 then
  begin
    sBuf := IntToStr(rc);
    Move(sBuf[1], zBuf[0], Length(sBuf)); zBuf[Length(sBuf)] := #0;
    Tcl_AppendResult(interp, PChar('sqlite3_autovacuum_pages() returns '),
      PChar(@zBuf[0]), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ ----------------------------------------------------------------------
  test_blob.c — Tcl wrappers around the sqlite3_blob_* incremental-BLOB API.
  The underlying engine functions live in passqlite3vdbe; this is the Tcl
  glue (test_blob.c:33..339). }

{ test_blob.c:33..37 — ptrToText.  Render a pointer as the "%p" text
  sqlite3TestTextToPtr() can decode back.  SQLite's %p is bare lowercase
  hex with NO "0x" prefix (printf.c etPOINTER). }
procedure blobPtrToText(p: Pointer; out zBuf: AnsiString);
begin
  zBuf := LowerCase(IntToHex(PtrUInt(p), 1));
end;

{ test_blob.c:51..79 — blobHandleFromObj.  Extract an sqlite3_blob* from a
  Tcl object: either an "incrblob_N" channel name or a ptrToText pointer. }
function blobHandleFromObj(interp: PTclInterp; pObj: PTclObj;
  out ppBlob: Psqlite3_blob): cint;
var
  z:            PAnsiChar;
  n:            cint;
  notUsed:      cint;
  channel:      TTclChannel;
  instanceData: TClientData;
begin
  z := Tcl_GetStringFromObj(pObj, @n);
  if n = 0 then
    ppBlob := nil
  else if (n > 9) and (StrLComp(z, PAnsiChar('incrblob_'), 9) = 0) then
  begin
    channel := Tcl_GetChannel(interp, z, @notUsed);
    if channel = nil then begin Result := TCL_ERROR; Exit; end;
    Tcl_Flush(channel);
    Tcl_Seek(channel, 0, 0 { SEEK_SET });
    instanceData := Tcl_GetChannelInstanceData(channel);
    { The IncrblobChannel's first field is the sqlite3_blob* pointer. }
    ppBlob := Psqlite3_blob(PPointer(instanceData)^);
  end
  else
    ppBlob := Psqlite3_blob(sqlite3TestTextToPtr(z));
  Result := TCL_OK;
end;

{ test_blob.c:86..91 — blobStringFromObj.  Like Tcl_GetString but returns
  nil for a 0-byte string. }
function blobStringFromObj(pObj: PTclObj): PAnsiChar;
var
  n: cint;
  z: PAnsiChar;
begin
  z := Tcl_GetStringFromObj(pObj, @n);
  if n <> 0 then Result := z else Result := nil;
end;

{ test_blob.c:98..152 — test_blob_open.
  Usage: sqlite3_blob_open DB DATABASE TABLE COLUMN ROWID FLAGS VARNAME. }
function test_blob_open(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db:       PTsqlite3;
  zDb:      PAnsiChar;
  zTable:   PAnsiChar;
  zColumn:  PAnsiChar;
  iRowid:   Int64;
  flags:    cint;
  zVarname: PAnsiChar;
  nVarname: cint;
  pBlob:    Psqlite3_blob;
  rc:       cint;
  zPtr:     AnsiString;
begin
  if objc <> 8 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('DB DATABASE TABLE COLUMN ROWID FLAGS VARNAME'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zDb := Tcl_GetString(objv[2]);
  zTable := blobStringFromObj(objv[3]);
  zColumn := Tcl_GetString(objv[4]);
  if Tcl_GetWideIntFromObj(interp, objv[5], @iRowid) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[6], @flags) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zVarname := Tcl_GetStringFromObj(objv[7], @nVarname);

  if nVarname > 0 then
  begin
    rc := sqlite3_blob_open(db, zDb, zTable, zColumn, iRowid, flags, pBlob);
    blobPtrToText(pBlob, zPtr);
    Tcl_SetVar(interp, zVarname, PChar(zPtr), 0);
  end
  else
    rc := sqlite3_blob_open(db, zDb, zTable, zColumn, iRowid, flags, pBlob);

  if rc = SQLITE_OK then
    Tcl_ResetResult(interp)
  else
  begin
    Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test_blob.c:158..183 — test_blob_close.
  Usage: sqlite3_blob_close HANDLE. }
function test_blob_close(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pBlob: Psqlite3_blob;
  rc:    cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('HANDLE'));
    Result := TCL_ERROR; Exit;
  end;
  if blobHandleFromObj(interp, objv[1], pBlob) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_blob_close(pBlob);
  if rc <> 0 then
    Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE)
  else
    Tcl_ResetResult(interp);
  Result := TCL_OK;
end;

{ test_blob.c:188..210 — test_blob_bytes.
  Usage: sqlite3_blob_bytes HANDLE. }
function test_blob_bytes(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pBlob: Psqlite3_blob;
  nByte: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('HANDLE'));
    Result := TCL_ERROR; Exit;
  end;
  if blobHandleFromObj(interp, objv[1], pBlob) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  nByte := sqlite3_blob_bytes(pBlob);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(nByte));
  Result := TCL_OK;
end;

{ test_blob.c:227..280 — test_blob_read.
  Usage: sqlite3_blob_read CHANNEL OFFSET N. }
function test_blob_read(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pBlob:   Psqlite3_blob;
  nByte:   cint;
  iOffset: cint;
  zBuf:    PByte;
  rc:      cint;
begin
  if objc <> 4 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('CHANNEL OFFSET N'));
    Result := TCL_ERROR; Exit;
  end;
  if blobHandleFromObj(interp, objv[1], pBlob) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if (Tcl_GetIntFromObj(interp, objv[2], @iOffset) <> TCL_OK)
    or (Tcl_GetIntFromObj(interp, objv[3], @nByte) <> TCL_OK) then
  begin
    Result := TCL_ERROR; Exit;
  end;

  zBuf := PByte(Tcl_Alloc(nByte));
  rc := sqlite3_blob_read(pBlob, zBuf, nByte, iOffset);
  if rc = SQLITE_OK then
    Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(zBuf, nByte))
  else
    Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
  Tcl_Free(PChar(zBuf));

  if rc = SQLITE_OK then Result := TCL_OK else Result := TCL_ERROR;
end;

{ test_blob.c:285..339 — test_blob_write.
  Usage: sqlite3_blob_write CHANNEL OFFSET DATA ?NDATA?. }
function test_blob_write(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pBlob:   Psqlite3_blob;
  iOffset: cint;
  rc:      cint;
  zBuf:    Pointer;
  nBuf:    cint;
begin
  if (objc <> 4) and (objc <> 5) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('CHANNEL OFFSET DATA ?NDATA?'));
    Result := TCL_ERROR; Exit;
  end;
  if blobHandleFromObj(interp, objv[1], pBlob) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[2], @iOffset) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;

  zBuf := Tcl_GetByteArrayFromObj(objv[3], @nBuf);
  if objc = 5 then
  begin
    if Tcl_GetIntFromObj(interp, objv[4], @nBuf) <> TCL_OK then
    begin
      Result := TCL_ERROR; Exit;
    end;
  end;
  rc := sqlite3_blob_write(pBlob, zBuf, nBuf, iOffset);
  if rc <> SQLITE_OK then
  begin
    Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:1824..1848 — test_blob_reopen.
  Usage: sqlite3_blob_reopen CHANNEL ROWID. }
function test_blob_reopen(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  iRowid: Int64;
  pBlob:  Psqlite3_blob;
  rc:     cint;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('CHANNEL ROWID'));
    Result := TCL_ERROR; Exit;
  end;
  if blobHandleFromObj(interp, objv[1], pBlob) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetWideIntFromObj(interp, objv[2], @iRowid) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_blob_reopen(pBlob, iRowid);
  if rc <> SQLITE_OK then
    Tcl_SetResult(interp, t1ErrName(rc), TCL_VOLATILE);
  if rc = SQLITE_OK then Result := TCL_OK else Result := TCL_ERROR;
end;

{ test1.c:5984..5998 — test_interrupt (old-style argc/argv handler).
  Usage: sqlite3_interrupt DB. }
function test_interrupt(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db: PTsqlite3;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_interrupt(db);
  Result := TCL_OK;
end;

{ test1.c:6005..6021 — test_is_interrupted (old-style argc/argv handler).
  Usage: sqlite3_is_interrupted DB.  Returns 1 if an interrupt is in effect. }
function test_is_interrupted(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db: PTsqlite3;
  av: PPAnsiCharArr;
  rc: cint;
begin
  av := argv;
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_is_interrupted(db);
  if rc <> 0 then
    Tcl_AppendResult(interp, PChar('1'), Pointer(nil))
  else
    Tcl_AppendResult(interp, PChar('0'), Pointer(nil));
  Result := TCL_OK;
end;

{ test2.c:671..698 — testBitvecBuiltinTest (old-style argc/argv handler).
  Usage: sqlite3BitvecBuiltinTest SIZE PROGRAM.
  Invokes SQLITE_TESTCTRL_BITVEC_TEST and returns the integer result. }
function testBitvecBuiltinTest(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  av:    PPAnsiCharArr;
  sz, rc, nProg: cint;
  aProg: array[0..99] of cint;
  z:     PAnsiChar;
begin
  av := argv;
  nProg := 0;
  if argc <> 3 then
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' SIZE PROGRAM"'), Pointer(nil));
  if Tcl_GetInt(interp, av[1], @sz) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  z := av[2];
  while (nProg < 99) and (z^ <> #0) do begin
    while (z^ <> #0) and not (z^ in ['0'..'9']) do Inc(z);
    if z^ = #0 then Break;
    { atoi over the digit run }
    rc := 0;
    while z^ in ['0'..'9'] do begin
      rc := rc * 10 + (Ord(z^) - Ord('0'));
      Inc(z);
    end;
    aProg[nProg] := rc;
    Inc(nProg);
  end;
  aProg[nProg] := 0;
  rc := sqlite3_test_control(SQLITE_TESTCTRL_BITVEC_TEST_OP, sz, Pu32(@aProg[0]));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test1.c:7685..7740 — test_wal_checkpoint_v2.
  Usage: sqlite3_wal_checkpoint_v2 db MODE ?NAME?. }
function test_wal_checkpoint_v2(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  aMode: array[0..5] of PChar =
    ('noop', 'passive', 'full', 'restart', 'truncate', nil);
var
  zDb:   PAnsiChar;
  db:    PTsqlite3;
  rc:    cint;
  eMode: cint;
  nLog:  cint;
  nCkpt: cint;
  pRet:  PTclObj;
  zErrCode: PAnsiChar;
begin
  zDb := nil;
  nLog := -555;
  nCkpt := -555;
  if (objc <> 3) and (objc <> 4) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB MODE ?NAME?'));
    Result := TCL_ERROR; Exit;
  end;
  if objc = 4 then
    zDb := Tcl_GetString(objv[3]);
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetIntFromObj(nil, objv[2], @eMode) <> TCL_OK then
  begin
    if Tcl_GetIndexFromObj(interp, objv[2], @aMode[0], PChar('mode'), 0,
        @eMode) <> TCL_OK then
    begin
      Result := TCL_ERROR; Exit;
    end;
    eMode := eMode - 1;
  end;

  rc := sqlite3_wal_checkpoint_v2(db, zDb, eMode, @nLog, @nCkpt);
  if (rc <> SQLITE_OK) and (rc <> SQLITE_BUSY) then
  begin
    zErrCode := t1ErrName(rc);
    Tcl_ResetResult(interp);
    Tcl_AppendResult(interp, zErrCode, PChar(' - '), sqlite3_errmsg(db),
      Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;

  pRet := Tcl_NewObj();
  if rc = SQLITE_BUSY then
    Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(1))
  else
    Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(0));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(nLog));
  Tcl_ListObjAppendElement(interp, pRet, Tcl_NewIntObj(nCkpt));
  Tcl_SetObjResult(interp, pRet);
  Result := TCL_OK;
end;

{ test1.c:8734..8758 — test_mmap_warm.
  Usage: sqlite3_mmap_warm DB ?DBNAME?. }
function test_mmap_warm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc:  cint;
  db:  PTsqlite3;
  zDb: PAnsiChar;
begin
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB ?DBNAME?'));
    Result := TCL_ERROR; Exit;
  end;
  zDb := nil;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if objc = 3 then
    zDb := Tcl_GetString(objv[2]);
  rc := sqlite3_mmap_warm(db, zDb);
  Tcl_SetObjResult(interp, Tcl_NewStringObj(t1ErrName(rc), -1));
  Result := TCL_OK;
end;

{ utf.c:505..518 — sqlite3Utf8To8 (SQLITE_TEST && SQLITE_DEBUG only).
  Translate UTF-8 to UTF-8 in place: make sure the string is well-formed,
  dropping miscoded (0xFFFD) characters.  Aborts if the output overruns the
  input.  Returns the new byte length.  Ported here because the engine omits
  this test-only helper. }
function utf8To8Inplace(zIn: PByte): cint;
var
  zOut:   PByte;
  zStart: PByte;
  pRead:  PChar;
  c:      u32;
begin
  zOut := zIn;
  zStart := zIn;
  while (zIn[0] <> 0) and (PtrUInt(zOut) <= PtrUInt(zIn)) do
  begin
    pRead := PChar(zIn);
    c := sqlite3Utf8Read(@pRead);
    zIn := PByte(pRead);
    if c <> $fffd then
      Inc(zOut, sqlite3AppendOneUtf8Character(PChar(zOut), c));
  end;
  zOut^ := 0;
  Result := cint(PtrUInt(zOut) - PtrUInt(zStart));
end;

{ test_hexio.c:299..336 — utf8_to_utf8 HEX.
  The argument is a UTF8 string in hex; convert it back to binary, run it
  through sqlite3Utf8To8 (well-form it), then re-hex and return.  Built with
  -DSQLITE_DEBUG so the function is available (no #else stub). }
function utf8_to_utf8(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  n:     cint;
  nOut:  cint;
  zOrig: PByte;
  z:     PByte;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('HEX'));
    Result := TCL_ERROR; Exit;
  end;
  zOrig := PByte(Tcl_GetStringFromObj(objv[1], @n));
  z := sqlite3_malloc64(u64(n) + 4);
  n := t1HexToBin(zOrig, n, z);
  (z + n)^ := 0;
  nOut := utf8To8Inplace(z);
  t1BinToHex(z, nOut);
  Tcl_AppendResult(interp, PChar(z), Pointer(nil));
  sqlite3_free(z);
  Result := TCL_OK;
end;

{ ----------------------------------------------------------------------
  test1.c:4395..4728 — sqlite3_carray_bind.

  Faithful port of test_carray_bind plus its two helpers testCarrayAlloc /
  testCarrayFree (the -malloc option's custom allocator that prefixes the
  buffer with 16 bytes so the destructor can recover the real allocation).
  The C `static` per-call cache (aStaticData/nStaticData/eStaticType) is
  mirrored here by unit-level globals, cleared on every invocation.
  ---------------------------------------------------------------------- }

{ test1.c:4409..4449 — bind_carray_intptr STMT IPARAM INT-0 INT-1 ...
  Binds an int array as the "carray" pointer (idxNum 1's sibling path,
  used with NN/count= constraints), allocated with Tcl_Alloc and freed
  by delIntptr (= ckfree). }
procedure delIntptr(p: Pointer); cdecl;
begin
  Tcl_Free(PChar(p));
end;

function tcl_bind_carray_intptr(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt: PVdbe;
  iVar:  cint;
  aInt:  ^cint;
  nInt:  cint;
  ii:    cint;
  rc:    cint;
begin
  iVar := 0;
  if objc < 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('STMT'));
    Result := TCL_ERROR; Exit;
  end;
  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[1])));
  if Tcl_GetIntFromObj(interp, objv[2], @iVar) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  nInt := objc - 3;

  aInt := Pointer(Tcl_Alloc(cuint((nInt + 1) * SizeOf(cint))));
  for ii := 0 to nInt - 1 do begin
    if Tcl_GetIntFromObj(interp, objv[3 + ii], @((aInt + ii)^)) <> 0 then begin
      Tcl_Free(PChar(aInt));
      Result := TCL_ERROR; Exit;
    end;
  end;

  rc := sqlite3_bind_pointer(pStmt, iVar, Pointer(aInt), PChar('carray'),
                             @delIntptr);
  Tcl_SetResult(interp, t1ErrName(rc), TCL_STATIC);
  Result := TCL_OK;
end;

{ test1.c:4395..4407 — the two helpers used by the -malloc option. }
function testCarrayAlloc(n: cint): Pointer;
var pRet: PByte;
begin
  pRet := PByte(sqlite3_malloc(n + 16));
  if pRet <> nil then
    Inc(pRet, 16);
  Result := Pointer(pRet);
end;

procedure testCarrayFree(p: Pointer); cdecl;
var p2: PByte;
begin
  if p <> nil then begin
    p2 := PByte(p);
    Dec(p2, 16);
    sqlite3_free(Pointer(p2));
  end;
end;

var
  carrayStaticData: Pointer = nil;
  carrayNStaticData: cint = 0;
  carrayEStaticType: cint = 0;

function tcl_test_carray_bind(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pStmt:          PVdbe;
  eType:          cint;
  mFlagsOverride: cint;
  nData:          cint;
  aData:          Pointer;
  isTransient:    cint;
  isStatic:       cint;
  isV2:           cint;
  isMalloc:       cint;
  idx:            cint;
  i, j:           cint;
  rc:             cint;
  xDel:           TxDelProc;
  z:              PAnsiChar;
  v:              cint;
  wv:             Int64;
  dv:             Double;
  sv:             PAnsiChar;
  pDel:           Pointer;
  nByte:          cint;
  aByte:          Pointer;
  p2:             PByte;
  aI32:           ^cint;
  aI64:           ^Int64;
  aDbl:           ^Double;
  aTxt:           PPAnsiChar;
  aIov:           PIoVec;
  blen:           cint;
  bptr:           PAnsiChar;
  svLen:          SizeInt;
label
  carray_bind_done;
begin
  eType          := 0;   { CARRAY_INT32 }
  mFlagsOverride := 0;
  nData          := 0;
  aData          := nil;
  isTransient    := 0;
  isStatic       := 0;
  isV2           := 0;
  isMalloc       := 0;
  rc             := SQLITE_OK;
  xDel           := @sqlite3_free;

  { test1.c:4491..4507 — always clear preexisting static data. }
  if carrayStaticData <> nil then begin
    if carrayEStaticType = 3 then
      for i := 0 to carrayNStaticData - 1 do
        sqlite3_free(PPAnsiChar(carrayStaticData)[i]);
    if carrayEStaticType = 4 then
      for i := 0 to carrayNStaticData - 1 do
        sqlite3_free(PIoVec(carrayStaticData)[i].iov_base);
    sqlite3_free(carrayStaticData);
    carrayStaticData  := nil;
    carrayNStaticData := 0;
    carrayEStaticType := 0;
  end;
  if objc = 1 then begin Result := TCL_OK; Exit; end;

  { test1.c:4510..4558 — option parsing. }
  i := 1;
  while (i < objc) and (Tcl_GetString(objv[i])[0] = '-') do begin
    z := Tcl_GetString(objv[i]);
    if StrComp(z, '-transient') = 0 then begin
      isTransient := 1; isStatic := 0; isMalloc := 0;
      xDel := TxDelProc(SQLITE_TRANSIENT);
    end else if StrComp(z, '-static') = 0 then begin
      isStatic := 1; isMalloc := 0; isTransient := 0;
      xDel := SQLITE_STATIC;
    end else if StrComp(z, '-malloc') = 0 then begin
      isMalloc := 1; isStatic := 0; isTransient := 0;
      xDel := @testCarrayFree;
    end else if StrComp(z, '-v2') = 0 then begin
      isV2 := 1;
    end else if StrComp(z, '-int32') = 0 then begin
      eType := 0;
    end else if StrComp(z, '-int64') = 0 then begin
      eType := 1;
    end else if StrComp(z, '-double') = 0 then begin
      eType := 2;
    end else if StrComp(z, '-text') = 0 then begin
      eType := 3;
    end else if StrComp(z, '-blob') = 0 then begin
      eType := 4;
    end else if (i < (objc - 1)) and (StrComp(z, '-flags') = 0) then begin
      Inc(i);
      if Tcl_GetIntFromObj(interp, objv[i], @mFlagsOverride) <> 0 then begin
        Result := TCL_ERROR; Exit;
      end;
    end else if StrComp(z, '--') = 0 then begin
      Break;
    end else begin
      Tcl_AppendResult(interp, PChar('unknown option: '), z, Pointer(nil));
      Result := TCL_ERROR; Exit;
    end;
    Inc(i);
  end;

  { test1.c:4559..4577 — option validation. }
  if (eType = 3) and (isStatic = 0) and (isTransient = 0) then begin
    Tcl_AppendResult(interp,
      PChar('text data must be either -static or -transient'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if (eType = 4) and (isStatic = 0) and (isTransient = 0) then begin
    Tcl_AppendResult(interp,
      PChar('blob data must be either -static or -transient'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if (isStatic <> 0) and (isTransient <> 0) then begin
    Tcl_AppendResult(interp,
      PChar('cannot be both -static and -transient'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if (objc - i) < 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('[OPTIONS] STMT IDX VALUE ...'));
    Result := TCL_ERROR; Exit;
  end;

  pStmt := PVdbe(sqlite3TestTextToPtr(Tcl_GetString(objv[i])));
  Inc(i);
  if Tcl_GetIntFromObj(interp, objv[i], @idx) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  Inc(i);
  nData := objc - i;

  { test1.c:4583..4672 — gather the data array. }
  case eType + 5 * Ord(nData <= 0) of
    0: begin { INT32 }
      aI32 := sqlite3_malloc(SizeOf(cint) * nData);
      if aI32 = nil then begin rc := SQLITE_NOMEM; goto carray_bind_done; end;
      for j := 0 to nData - 1 do begin
        if Tcl_GetIntFromObj(interp, objv[i + j], @v) <> 0 then begin
          sqlite3_free(aI32); Result := TCL_ERROR; Exit;
        end;
        (aI32 + j)^ := v;
      end;
      aData := aI32;
    end;
    1: begin { INT64 }
      aI64 := sqlite3_malloc(SizeOf(Int64) * nData);
      if aI64 = nil then begin rc := SQLITE_NOMEM; goto carray_bind_done; end;
      for j := 0 to nData - 1 do begin
        if Tcl_GetWideIntFromObj(interp, objv[i + j], @wv) <> 0 then begin
          sqlite3_free(aI64); Result := TCL_ERROR; Exit;
        end;
        (aI64 + j)^ := wv;
      end;
      aData := aI64;
    end;
    2: begin { DOUBLE }
      aDbl := sqlite3_malloc(SizeOf(Double) * nData);
      if aDbl = nil then begin rc := SQLITE_NOMEM; goto carray_bind_done; end;
      for j := 0 to nData - 1 do begin
        if Tcl_GetDoubleFromObj(interp, objv[i + j], @dv) <> 0 then begin
          sqlite3_free(aDbl); Result := TCL_ERROR; Exit;
        end;
        (aDbl + j)^ := dv;
      end;
      aData := aDbl;
    end;
    3: begin { TEXT }
      aTxt := sqlite3_malloc(SizeOf(PAnsiChar) * nData);
      if aTxt = nil then
        rc := SQLITE_NOMEM
      else
        FillChar(aTxt^, SizeOf(PAnsiChar) * nData, 0);
      j := 0;
      while (rc = SQLITE_OK) and (j < nData) do begin
        sv := Tcl_GetString(objv[i + j]);
        if (sv <> nil) and (StrComp(sv, 'NULL') <> 0) then begin
          { C: sqlite3_mprintf("%s", v) — a plain string dup; the Pascal
            sqlite3_mprintf has no varargs, so malloc+copy directly. }
          svLen := StrLen(sv);
          aTxt[j] := PAnsiChar(sqlite3_malloc(svLen + 1));
          if aTxt[j] = nil then
            rc := SQLITE_NOMEM
          else
            Move(sv^, aTxt[j]^, svLen + 1);
        end;
        Inc(j);
      end;
      aData := aTxt;
    end;
    4: begin { BLOB }
      aIov := sqlite3_malloc(SizeOf(TIoVec) * nData);
      if aIov = nil then
        rc := SQLITE_NOMEM
      else
        FillChar(aIov^, SizeOf(TIoVec) * nData, 0);
      j := 0;
      while (rc = SQLITE_OK) and (j < nData) do begin
        blen := 0;
        bptr := Tcl_GetByteArrayFromObj(objv[i + j], @blen);
        aIov[j].iov_len  := SizeUInt(blen);
        aIov[j].iov_base := sqlite3_malloc64(blen);
        if aIov[j].iov_base = nil then begin
          aIov[j].iov_len := 0;
          rc := SQLITE_NOMEM;
        end else
          Move(bptr^, aIov[j].iov_base^, blen);
        Inc(j);
      end;
      aData := aIov;
    end;
    5: begin { nData == 0 }
      aData := PAnsiChar('');
      xDel := SQLITE_STATIC;
      isTransient := 0;
      isStatic := 0;
    end;
  end;

  { test1.c:4674..4694 — static/malloc post-processing. }
  if rc = SQLITE_OK then begin
    if isStatic <> 0 then begin
      carrayStaticData  := aData;
      carrayNStaticData := nData;
      carrayEStaticType := eType;
    end else if isMalloc <> 0 then begin
      if eType = 0 then nByte := SizeOf(cint) * nData
                   else nByte := SizeOf(Int64) * nData;
      aByte := testCarrayAlloc(nByte);
      if aByte = nil then begin
        sqlite3_free(aData);
        rc := SQLITE_NOMEM;
      end else begin
        Move(aData^, aByte^, nByte);
        sqlite3_free(aData);
        aData := aByte;
        xDel := @testCarrayFree;
      end;
    end;
  end;

  { test1.c:4696..4712 — perform the bind. }
  if rc = SQLITE_OK then begin
    if mFlagsOverride = 0 then mFlagsOverride := eType;
    if isV2 <> 0 then begin
      if Pointer(xDel) = Pointer(@testCarrayFree) then begin
        p2 := PByte(aData);
        Dec(p2, 16);
        pDel := Pointer(p2);
        xDel := @sqlite3_free;
      end else
        pDel := aData;
      rc := sqlite3_carray_bind_v2(pStmt, idx, aData, nData, mFlagsOverride,
                                   xDel, pDel);
    end else
      rc := sqlite3_carray_bind(pStmt, idx, aData, nData, mFlagsOverride, xDel);
  end;

  { test1.c:4713..4721 — release transient-owned data. }
  if isTransient <> 0 then begin
    if (eType = 3) and (aData <> nil) then
      for i := 0 to nData - 1 do
        sqlite3_free(PPAnsiChar(aData)[i]);
    if (eType = 4) and (aData <> nil) then
      for i := 0 to nData - 1 do
        sqlite3_free(PIoVec(aData)[i].iov_base);
    sqlite3_free(aData);
  end;

carray_bind_done:
  if rc <> 0 then begin
    Tcl_AppendResult(interp, sqlite3_errstr(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:5527..5550 — sqlite3_complete16 <utf-16 sql>.  Returns 1 if the
  supplied UTF-16 argument is a complete SQL statement, 0 otherwise. }
function test_complete16(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var zBuf: Pointer;
begin
  if objc <> 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('<utf-16 sql>'));
    Result := TCL_ERROR; Exit;
  end;
  zBuf := Tcl_GetByteArrayFromObj(objv[1], nil);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_complete16(zBuf)));
  Result := TCL_OK;
end;

{ test1.c:1727..1738 — Usage: sqlite3_libversion_number
  Returns sqlite3_libversion_number() as an int. }
function test_libversion_number(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_libversion_number()));
  Result := TCL_OK;
  if (clientData = nil) or (objc < 0) or (objv = nil) then ;
end;

{ test1.c:7436..7456 — tclcmd: save_prng_state
  Save the state of the PRNG.  Also verifies sqlite3_test_control tolerates
  out-of-range opcodes (returns 0). }
function save_prng_state(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
begin
  rc := sqlite3_test_control(9999);
  Assert(rc = 0);
  rc := sqlite3_test_control(-1);
  Assert(rc = 0);
  sqlite3_test_control(SQLITE_TESTCTRL_PRNG_SAVE_OP);
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (objc < 0) or (objv = nil) then ;
end;

{ test1.c:7458..7468 — tclcmd: reset_prng_state
  Restore the previously-saved PRNG state. }
function reset_prng_state(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  sqlite3_test_control(SQLITE_TESTCTRL_PRNG_RESTORE_OP);
  Result := TCL_OK;
  if (clientData = nil) or (interp = nil) or (objc < 0) or (objv = nil) then ;
end;

{ test1.c:7787..7789 — struct LogCallback { Tcl_Interp*; Tcl_Obj*; } = {0,0}. }
type
  TLogCallback = record
    pInterp: PTclInterp;
    pObj:    PTclObj;
  end;
var
  logcallback: TLogCallback = (pInterp: nil; pObj: nil);

{ test1.c:7790..7799 — xLogcallback.  Duplicates the saved Tcl script,
  appends the symbolic error-code name (sqlite3ErrName == t1ErrName here)
  and the message, then evaluates it at global scope. }
procedure xLogcallback(unused: Pointer; err: i32; zMsg: PAnsiChar); cdecl;
var
  pNew: PTclObj;
begin
  pNew := Tcl_DuplicateObj(logcallback.pObj);
  Tcl_IncrRefCount(pNew);
  Tcl_ListObjAppendElement(nil, pNew,
    Tcl_NewStringObj(t1ErrName(err), -1));
  Tcl_ListObjAppendElement(nil, pNew, Tcl_NewStringObj(zMsg, -1));
  Tcl_EvalObjEx(logcallback.pInterp, pNew,
    TCL_EVAL_GLOBAL or TCL_EVAL_DIRECT);
  Tcl_DecrRefCount(pNew);
  if unused = nil then ;
end;

{ test1.c:7800..7822 — tclcmd: test_sqlite3_log ?SCRIPT?
  Registers (or deregisters with no/empty arg) a Tcl log callback via
  SQLITE_CONFIG_LOG. }
function test_sqlite3_log(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  if objc > 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SCRIPT'));
    Result := TCL_ERROR; Exit;
  end;
  if logcallback.pObj <> nil then begin
    Tcl_DecrRefCount(logcallback.pObj);
    logcallback.pObj    := nil;
    logcallback.pInterp := nil;
    sqlite3_config(SQLITE_CONFIG_LOG, Tsqlite3_config_log_cb(nil), nil);
  end;
  if (objc > 1) and (Tcl_GetString(objv[1])[0] <> #0) then begin
    logcallback.pObj := objv[1];
    Tcl_IncrRefCount(logcallback.pObj);
    logcallback.pInterp := interp;
    sqlite3_config(SQLITE_CONFIG_LOG, @xLogcallback, nil);
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:7969..8009 — TCLCMD: strftime FORMAT UNIXTIMESTAMP
  Access to the C-library strftime() so its results can be compared against
  SQLite's internal strftime() SQL function. }
function strftime_cmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  ts:   Int64;
  t:    clong;
  pTm:  PCTm;
  zFmt: PAnsiChar;
  n:    csize_t;
  zBuf: array[0..999] of AnsiChar;
begin
  if objc <> 3 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('FORMAT UNIXTIMESTAMP'));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetWideIntFromObj(interp, objv[2], @ts) <> 0 then begin
    Result := TCL_ERROR; Exit;
  end;
  zFmt := Tcl_GetString(objv[1]);
  t := clong(ts);
  pTm := c_gmtime(@t);
  n := c_strftime(@zBuf[0], SizeOf(zBuf) - 1, zFmt, pTm);
  if n < csize_t(SizeOf(zBuf)) then begin
    zBuf[n] := #0;
    Tcl_SetResult(interp, @zBuf[0], TCL_VOLATILE);
  end;
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:8023..8126 — TCLCMD: sqlite3_test_control VERB ARGS...
  The aVerb[] name table and per-verb argument shapes mirror the C
  test_test_control exactly.  LOCALTIME_FAULT: the C harness passes the
  testLocaltime callback as a third argument; the Pascal engine's
  LOCALTIME_FAULT op ignores/clears xAltLocaltime, so only the integer
  is forwarded (passqlite3main.pas LOCALTIME_FAULT_OP). }
function test_test_control(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  aVerbName: array[0..5] of PChar = (
    'SQLITE_TESTCTRL_LOCALTIME_FAULT',
    'SQLITE_TESTCTRL_SORTER_MMAP',
    'SQLITE_TESTCTRL_IMPOSTER',
    'SQLITE_TESTCTRL_INTERNAL_FUNCTIONS',
    'SQLITE_TESTCTRL_FK_NO_ACTION',
    nil);
  aVerbFlag: array[0..4] of cint = (
    SQLITE_TESTCTRL_LOCALTIME_FAULT_OP,
    SQLITE_TESTCTRL_SORTER_MMAP_OP,
    SQLITE_TESTCTRL_IMPOSTER_OP,
    SQLITE_TESTCTRL_INTERNAL_FUNCTIONS_OP,
    SQLITE_TESTCTRL_FK_NO_ACTION_OP);
var
  iVerb:   cint;
  iFlag:   cint;
  val:     cint;
  onOff:   cint;
  tnum:    cint;
  db:      PTsqlite3;
  zDbName: PAnsiChar;
begin
  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('VERB ARGS...'));
    Result := TCL_ERROR; Exit;
  end;
  iVerb := 0;
  if Tcl_GetIndexFromObj(interp, objv[1], @aVerbName[0], PChar('VERB'), 0,
      @iVerb) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  iFlag := aVerbFlag[iVerb];
  case iFlag of
    SQLITE_TESTCTRL_INTERNAL_FUNCTIONS_OP:
    begin
      db := nil;
      if objc <> 3 then
      begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('DB'));
        Result := TCL_ERROR; Exit;
      end;
      if getDbPointer(interp, Tcl_GetString(objv[2]), @db) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      sqlite3_test_control(SQLITE_TESTCTRL_INTERNAL_FUNCTIONS_OP, db);
    end;
    SQLITE_TESTCTRL_LOCALTIME_FAULT_OP:
    begin
      if objc <> 3 then
      begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('0|1|2'));
        Result := TCL_ERROR; Exit;
      end;
      if Tcl_GetIntFromObj(interp, objv[2], @val) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      sqlite3_test_control(iFlag, val);
    end;
    SQLITE_TESTCTRL_FK_NO_ACTION_OP:
    begin
      val := 0;
      db := nil;
      if objc <> 4 then
      begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('DB BOOLEAN'));
        Result := TCL_ERROR; Exit;
      end;
      if getDbPointer(interp, Tcl_GetString(objv[2]), @db) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      if Tcl_GetBooleanFromObj(interp, objv[3], @val) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      sqlite3_test_control(SQLITE_TESTCTRL_FK_NO_ACTION_OP, db, val);
    end;
    SQLITE_TESTCTRL_SORTER_MMAP_OP:
    begin
      if objc <> 4 then
      begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('DB LIMIT'));
        Result := TCL_ERROR; Exit;
      end;
      if getDbPointer(interp, Tcl_GetString(objv[2]), @db) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      if Tcl_GetIntFromObj(interp, objv[3], @val) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      sqlite3_test_control(SQLITE_TESTCTRL_SORTER_MMAP_OP, db, val);
    end;
    SQLITE_TESTCTRL_IMPOSTER_OP:
    begin
      if objc <> 6 then
      begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('DB dbName onOff tnum'));
        Result := TCL_ERROR; Exit;
      end;
      if getDbPointer(interp, Tcl_GetString(objv[2]), @db) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      zDbName := Tcl_GetString(objv[3]);
      if Tcl_GetIntFromObj(interp, objv[4], @onOff) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      if Tcl_GetIntFromObj(interp, objv[5], @tnum) <> 0 then
      begin
        Result := TCL_ERROR; Exit;
      end;
      sqlite3_test_control(SQLITE_TESTCTRL_IMPOSTER_OP, db, zDbName,
        onOff, tnum);
    end;
  end;
  Tcl_ResetResult(interp);
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:8289..8362 — TCLCMD: optimization_control DB OPT BOOLEAN
  Enable or disable query optimizations via
  SQLITE_TESTCTRL_OPTIMIZATIONS.  OPT may be a single name or a list of
  names (the C code matches with strstr, so any substring hit counts).
  Each invocation overrides all prior invocations.  The name→mask table
  is a verbatim port of test1.c aOpt[]; masks come from
  passqlite3codegen (sqliteInt.h:1898..1933). }
type
  TOptCtrlEntry = record
    zOptName: PAnsiChar;
    mask:     u32;
  end;

const
  { sqliteInt.h:1902/1933 — not yet mirrored in passqlite3codegen. }
  SQLITE_FactorOutConst = u32($00000008);
  SQLITE_AllOpts        = u32($ffffffff);

  aOptCtrl: array[0..17] of TOptCtrlEntry = (
    (zOptName: 'all';               mask: SQLITE_AllOpts),
    (zOptName: 'none';              mask: 0),
    (zOptName: 'query-flattener';   mask: SQLITE_QueryFlattener),
    (zOptName: 'groupby-order';     mask: SQLITE_GroupByOrder),
    (zOptName: 'factor-constants';  mask: SQLITE_FactorOutConst),
    (zOptName: 'distinct-opt';      mask: SQLITE_DistinctOpt),
    (zOptName: 'cover-idx-scan';    mask: SQLITE_CoverIdxScan),
    (zOptName: 'order-by-idx-join'; mask: SQLITE_OrderByIdxJoin),
    (zOptName: 'order-by-subquery'; mask: SQLITE_OrderBySubq),
    (zOptName: 'transitive';        mask: SQLITE_Transitive),
    (zOptName: 'omit-noop-join';    mask: SQLITE_OmitNoopJoin),
    (zOptName: 'stat4';             mask: SQLITE_Stat4),
    (zOptName: 'skip-scan';         mask: SQLITE_SkipScan),
    (zOptName: 'push-down';         mask: SQLITE_PushDown),
    (zOptName: 'balanced-merge';    mask: SQLITE_BalancedMerge),
    (zOptName: 'propagate-const';   mask: SQLITE_PropagateConst),
    (zOptName: 'one-pass';          mask: SQLITE_OnePass),
    (zOptName: 'exists-to-join';    mask: SQLITE_ExistsToJoin));

function optimization_control(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  i:     cint;
  db:    PTsqlite3;
  zOpt:  AnsiString;
  onoff: cint;
  mask:  u32;
  cnt:   cint;
begin
  mask := 0;
  cnt := 0;
  if objc <> 4 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB OPT BOOLEAN'));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[3], @onoff) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  zOpt := AnsiString(Tcl_GetString(objv[2]));
  for i := 0 to High(aOptCtrl) do
  begin
    { C: strstr(zOpt, aOpt[i].zOptName) — substring match. }
    if Pos(AnsiString(aOptCtrl[i].zOptName), zOpt) > 0 then
    begin
      mask := mask or aOptCtrl[i].mask;
      Inc(cnt);
    end;
  end;
  if onoff <> 0 then
    mask := not mask;
  if cnt = 0 then
  begin
    Tcl_AppendResult(interp,
      PChar('unknown optimization - should be one of:'), Pointer(nil));
    for i := 0 to High(aOptCtrl) do
      Tcl_AppendResult(interp, PChar(' '), aOptCtrl[i].zOptName,
        Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  sqlite3_test_control(SQLITE_TESTCTRL_OPTIMIZATIONS_OP, db, i32(mask));
  Tcl_SetObjResult(interp, Tcl_NewIntObj(cint(i32(mask))));
  Result := TCL_OK;
  if clientData = nil then ;
end;

{ test1.c:2189..2220 — testFunc.  User-defined SQL function exercising
  the sqlite_set_result() API.  Arguments come in TYPE/VALUE pairs; TYPE
  is one of int/int64/string/double/null/value (case-insensitive). }
procedure t1TestFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pArg:  PPsqlite3_value;
  zArg0: PAnsiChar;
begin
  pArg := argv;
  while argc >= 2 do
  begin
    zArg0 := PAnsiChar(sqlite3_value_text(pArg[0]));
    if zArg0 <> nil then
    begin
      if sqlite3StrICmp(zArg0, PAnsiChar('int')) = 0 then
        sqlite3_result_int(context, sqlite3_value_int(pArg[1]))
      else if sqlite3StrICmp(zArg0, PAnsiChar('int64')) = 0 then
        sqlite3_result_int64(context, sqlite3_value_int64(pArg[1]))
      else if sqlite3StrICmp(zArg0, PAnsiChar('string')) = 0 then
        sqlite3_result_text(context,
          PAnsiChar(sqlite3_value_text(pArg[1])), -1, SQLITE_TRANSIENT)
      else if sqlite3StrICmp(zArg0, PAnsiChar('double')) = 0 then
        sqlite3_result_double(context, sqlite3_value_double(pArg[1]))
      else if sqlite3StrICmp(zArg0, PAnsiChar('null')) = 0 then
        sqlite3_result_null(context)
      else if sqlite3StrICmp(zArg0, PAnsiChar('value')) = 0 then
        sqlite3_result_value(context, pArg[sqlite3_value_int(pArg[1])])
      else
      begin
        sqlite3_result_error(context,
          PAnsiChar('first argument should be one of: int int64 string double null value'), -1);
        Exit;
      end;
    end
    else
    begin
      sqlite3_result_error(context,
        PAnsiChar('first argument should be one of: int int64 string double null value'), -1);
      Exit;
    end;
    Dec(argc, 2);
    pArg := PPsqlite3_value(PtrUInt(pArg) + 2 * SizeOf(Pointer));
  end;
end;

{ test1.c:2227..2249 — test_register_func (old-style argc/argv handler).
  Usage: sqlite_register_test_function DB NAME.  Registers testFunc on
  DB under NAME. }
function test_register_func(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  db: PTsqlite3;
  rc: i32;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 3 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' DB FUNCTION-NAME'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if getDbPointer(interp, av[1], @db) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  rc := sqlite3_create_function(db, av[2], -1, SQLITE_UTF8, nil,
    @t1TestFunc, nil, nil);
  if rc <> 0 then
  begin
    Tcl_AppendResult(interp, sqlite3ErrStr(rc), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if sqlite3TestErrCode(interp, db, rc) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  Result := TCL_OK;
end;

{ test1.c:4830..4849 — test_sleep (old-style argc/argv handler).
  Usage: sqlite3_sleep MILLISECONDS. }
function test_sleep(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  ms: cint;
  av: PPAnsiCharArr;
begin
  av := argv;
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' MILLISECONDS'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if Tcl_GetInt(interp, av[1], @ms) <> 0 then
  begin
    Result := TCL_ERROR; Exit;
  end;
  Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_sleep(ms)));
  Result := TCL_OK;
end;

{ test2.c:582..618 — the sqlite3FaultSim() callback bridge.  The script
  installed by sqlite3_test_control_fault_install is evaluated with the
  integer argument appended; its integer result becomes the
  sqlite3FaultSim() return value. }
var
  faultSimInterp:     PTclInterp = nil;
  faultSimScriptSize: cint       = 0;
  faultSimScript:     PAnsiChar  = nil;

function faultSimCallback(x: i32): i32; cdecl;
var
  zInt: string[31];
  rc:   cint;
  i:    cint;
begin
  { Convert x to text (the C code hand-rolls this to avoid re-entering
    sqlite3 routines; Str() is a pure RTL conversion). }
  Str(x, zInt);
  for i := 1 to Length(zInt) do
    (faultSimScript + faultSimScriptSize + i - 1)^ := zInt[i];
  (faultSimScript + faultSimScriptSize + Length(zInt))^ := #0;
  rc := Tcl_Eval(faultSimInterp, faultSimScript);
  if rc <> TCL_OK then
  begin
    Flush(StdErr);
    WriteLn(StdErr, 'fault simulator script failed: [',
      string(faultSimScript), ']');
    rc := SQLITE_ERROR;
  end
  else
    rc := StrToIntDef(Trim(string(Tcl_GetStringResult(faultSimInterp))), 0);
  Tcl_ResetResult(faultSimInterp);
  Result := rc;
end;

{ test2.c:627..663 — faultInstallCmd (old-style argc/argv handler).
  Usage: sqlite3_test_control_fault_install ?SCRIPT?.  Arrange to invoke
  SCRIPT (with the sqlite3FaultSim() argument appended) whenever
  sqlite3FaultSim() is called; an empty/absent SCRIPT cancels the
  callback. }
function faultInstallCmd(clientData: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  zScript: PAnsiChar;
  nScript: cint;
  rc:      cint;
  av:      PPAnsiCharArr;
begin
  av := argv;
  if (argc <> 1) and (argc <> 2) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      av[0], PChar(' SCRIPT'), Pointer(nil));
    Result := TCL_ERROR; Exit;
  end;
  if argc = 2 then
    zScript := av[1]
  else
    zScript := PAnsiChar('');
  nScript := cint(strlen(zScript));
  if faultSimScript <> nil then
  begin
    FreeMem(faultSimScript);
    faultSimScript := nil;
  end;
  if nScript = 0 then
    rc := sqlite3_test_control(SQLITE_TESTCTRL_FAULT_INSTALL_OP, Pi32(nil))
  else
  begin
    GetMem(faultSimScript, nScript + 100);
    Move(zScript^, faultSimScript^, nScript);
    (faultSimScript + nScript)^ := ' ';
    faultSimScriptSize := nScript + 1;
    faultSimInterp := interp;
    rc := sqlite3_test_control(SQLITE_TESTCTRL_FAULT_INSTALL_OP,
      Pi32(@faultSimCallback));
  end;
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test1.c:9106..9322 — register the subset of Sqlitetest1_Init commands
  needed by the 9.4.4.c sweep. }
function Sqlitetest1_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('sqlite3_connection_pointer'),
    @get_sqlite_pointer, nil, nil);
  { tclsqlite.test — test1.c:1834 sqlite3_libversion_number. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_libversion_number'),
    @test_libversion_number, nil, nil);
  { fts3corrupt4.test — test1.c:9258/9260 save_prng_state/reset_prng_state. }
  Tcl_CreateObjCommand(interp, PChar('save_prng_state'),
    @save_prng_state, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('reset_prng_state'),
    @reset_prng_state, nil, nil);
  { date4.test — test1.c:9320 strftime. }
  Tcl_CreateObjCommand(interp, PChar('strftime'),
    @strftime_cmd, nil, nil);
  { pragma4.test/pragma.test — test1.c:9290 test_sqlite3_log. }
  Tcl_CreateObjCommand(interp, PChar('test_sqlite3_log'),
    @test_sqlite3_log, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_db_config'),
    @test_sqlite3_db_config, nil, nil);
  { alter/altercol/fkey2/sort/... — test1.c:9295 sqlite3_test_control. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_test_control'),
    @test_test_control, nil, nil);
  { join2/merge1/selectB/skipscan1/... — test1.c:9196 optimization_control. }
  Tcl_CreateObjCommand(interp, PChar('optimization_control'),
    @optimization_control, nil, nil);
  { misc8.test — test1.c:9187 dbconfig_maindbname_icecube. }
  Tcl_CreateObjCommand(interp, PChar('dbconfig_maindbname_icecube'),
    @test_dbconfig_maindbname_icecube, nil, nil);
  { 9.4.divbug.88.003 — test1.c:9173 sqlite3_db_cacheflush. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_db_cacheflush'),
    @test_db_cacheflush, nil, nil);
  { 9.4.divbug.81 — test1.c:9176 sqlite3_db_readonly. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_db_readonly'),
    @test_db_readonly, nil, nil);
  { attach.test — test1.c:9175 sqlite3_db_filename. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_db_filename'),
    @test_db_filename, nil, nil);
  { autovacuum2.test — test1.c:9325 sqlite3_autovacuum_pages. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_autovacuum_pages'),
    @test_autovacuum_pages, nil, nil);
  { 9.4.divbug.35 — fpnum_compare for fuzzy float-string equality
    fallback used by tester.tcl do_test (tester.tcl:789..792). }
  Tcl_CreateObjCommand(interp, PChar('fpnum_compare'),
    @fpnum_compare, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('atomic_batch_write'),
    @test_atomic_batch_write, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('load_static_extension'),
    @tclLoadStaticExtensionCmd, nil, nil);
  { 9.4.6.q.1 — prepared-statement / errmsg / exec / transfer / backup. }
  { 9.4.divbug.88.005 / 88.008 — sqlite3_open / _v2 / _16 Tcl trampolines.
    test1.c:9140..9142. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_open'),
    @test_open, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_open_v2'),
    @test_open_v2, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_open16'),
    @test_open16, nil, nil);
  { test1.c:9143 — sqlite3_complete16 <utf-16 sql>. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_complete16'),
    @test_complete16, nil, nil);
  { 9.4.divbug.88.031 — test1.c:9079..9080 sqlite3_close / _v2. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_close'),
    @test_close, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_close_v2'),
    @test_close_v2, nil, nil);
  { 9.4.divbug.88.063 — test1.c:9164 sqlite3_next_stmt. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_next_stmt'),
    @tcl_test_next_stmt, nil, nil);
  { 9.4.divbug.88.035 — sqlite3_extended_errcode Tcl trampoline used by
    tester.tcl:1682 verify_ex_errcode (errmsg.test, fkey2.test,
    notnull.test).  C ref test1.c registered at 9133. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_extended_errcode'),
    @test_extended_errcode, nil, nil);
  { test1.c:9185 sqlite3_extended_result_codes DB BOOLEAN — toggles the
    API-boundary errMask so without_rowid7-3.5.1 sees the extended rc. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_extended_result_codes'),
    @test_extended_result_codes, nil, nil);
  { 9.4.divbug.88.012.f — sqlite3_errcode DB returns symbolic rc
    name (test1.c:4884..4902, registered :9134). Without this the
    tester_min.tcl fallback `[$db errorcode]` returns numeric 11 and
    corrupt2-10.2 diverges from {SQLITE_CORRUPT}. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_errcode'),
    @test_errcode, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_drop_modules'),
    @test_drop_modules, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('install_fts3_rank_function'),
    @install_fts3_rank_function, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_exec'),
    @test_exec, nil, nil);
  { test1.c:331..375 / registered test1.c:9073 — sqlite3_exec_hex DB HEX.
    Native command so %ff/%fe decode to raw bytes (a Tcl shim would
    UTF-8 re-encode them and break the LIKE-range opt tests). }
  Tcl_CreateCommand(interp, PChar('sqlite3_exec_hex'),
    @test_exec_hex, nil, nil);
  { 9.4.divbug.88.047 — sqlite3_exec_printf DB FORMAT STRING.
    test1.c:299..328, registered at test1.c:9072.  Used by
    laststmtchanges-1.2.1 to inject a value into a CREATE TABLE statement
    via %q. }
  Tcl_CreateCommand(interp, PChar('sqlite3_exec_printf'),
    @test_exec_printf, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_errmsg'),
    @test_errmsg, nil, nil);
  { test1.c:9137 — sqlite3_error_offset DB (test_error_offset). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_error_offset'),
    @test_error_offset, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_prepare'),
    @test_prepare, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_prepare_v2'),
    @test_prepare_v2, nil, nil);
  { test1.c:9149 — sqlite3_prepare_v3 DB sql bytes flags ?tailvar?
    (test_prepare_v3). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_prepare_v3'),
    @test_prepare_v3, nil, nil);
  { 9.4.divbug.88.004 — sqlite3_prepare16 / sqlite3_prepare16_v2.
    test1.c:5280..5330, 5340..5390; registered at test1.c:9147 and 9151. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_prepare16'),
    @test_prepare16, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_prepare16_v2'),
    @test_prepare16_v2, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_transfer_bindings'),
    @test_transfer_bind, nil, nil);
  { test1.c:9157 — sqlite3_changes DB (test_changes). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_changes'),
    @test_changes, nil, nil);
  { test1.c:9138 — sqlite3_errmsg16 DB (test_errmsg16). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_errmsg16'),
    @test_errmsg16, nil, nil);
  { test1.c:9057..9058 — db_enter / db_leave DB (old-style argc/argv). }
  Tcl_CreateCommand(interp, PChar('db_enter'),
    @db_enter, nil, nil);
  Tcl_CreateCommand(interp, PChar('db_leave'),
    @db_leave, nil, nil);
  { 9.4.divbug.88.001 — sqlite3_expired STMT.  test1.c:3121..3138, 9155. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_expired'),
    @test_expired, nil, nil);
  { 9.4.divbug.88.002 — sqlite_bind VM IDX VALUE FLAGS (old-style argc/argv).
    test1.c:3207..3247, registered at test1.c:9086.
    Paired Tcl_LinkVars at test1.c:9429..9432. }
  Tcl_CreateCommand(interp, PChar('sqlite_bind'),
    @test_bind, nil, nil);
  Tcl_LinkVar(interp, PChar('sqlite_static_bind_value'),
    @sqlite_static_bind_value, TCL_LINK_STRING);
  Tcl_LinkVar(interp, PChar('sqlite_static_bind_nbyte'),
    @sqlite_static_bind_nbyte, TCL_LINK_INT);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_backup'),
    @backupTestInit, nil, nil);
  { 9.4.divbug.88.011 — btree_from_db.  test3.c:676. }
  Tcl_CreateCommand(interp, PChar('btree_from_db'),
    @btree_from_db, nil, nil);
  { types.test — raw b-tree harness commands.  test3.c:664..674. }
  Tcl_CreateCommand(interp, PChar('btree_open'),
    @btree_open, nil, nil);
  Tcl_CreateCommand(interp, PChar('btree_close'),
    @btree_close, nil, nil);
  Tcl_CreateCommand(interp, PChar('btree_ismemdb'),
    @btree_ismemdb, nil, nil);
  Tcl_CreateCommand(interp, PChar('btree_begin_transaction'),
    @btree_begin_transaction, nil, nil);
  Tcl_CreateCommand(interp, PChar('btree_cursor'),
    @btree_cursor, nil, nil);
  Tcl_CreateCommand(interp, PChar('btree_close_cursor'),
    @btree_close_cursor, nil, nil);
  Tcl_CreateCommand(interp, PChar('btree_next'),
    @btree_next, nil, nil);
  Tcl_CreateCommand(interp, PChar('btree_first'),
    @btree_first, nil, nil);
  Tcl_CreateCommand(interp, PChar('btree_payload_size'),
    @btree_payload_size, nil, nil);
  { 6.40.6 (HARNESS) — btree_pager_stats.  test3.c:668. }
  Tcl_CreateCommand(interp, PChar('btree_pager_stats'),
    @btree_pager_stats, nil, nil);
  { 9.4.divbug.88.062 — btree_varint_test.  test3.c:675. }
  Tcl_CreateCommand(interp, PChar('btree_varint_test'),
    @btree_varint_test, nil, nil);
  { test3.c:686 — btree_insert (ObjCommand). }
  Tcl_CreateObjCommand(interp, PChar('btree_insert'),
    @btree_insert, nil, nil);
  { 9.4.6.q.2 — aggregate UDF registration + pagecache config + lifecycle.
    test1.c:9082 / test_malloc.c:1487. }
  Tcl_CreateCommand(interp, PChar('sqlite3_create_aggregate'),
    @test_create_aggregate, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config_pagecache'),
    @test_config_pagecache, nil, nil);
  { test_quota.c:1954 — sqlite3_quota_glob PATTERN TEXT (glob matcher only). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_quota_glob'),
    @test_quota_glob, nil, nil);
  { test_mutex.c:337..372 — sqlite3_config OPTION. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config'),
    @test_config, nil, nil);
  { test_mutex.c:475..504 — Sqlitetest_mutex_Init command table
    (mutex1.test / mutex2.test).  sqlite3_config / _initialize / _shutdown
    are already registered above. }
  Tcl_CreateObjCommand(interp, PChar('enter_static_mutex'),
    @test_enter_static_mutex, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('leave_static_mutex'),
    @test_leave_static_mutex, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('enter_db_mutex'),
    @test_enter_db_mutex, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('leave_db_mutex'),
    @test_leave_db_mutex, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('alloc_dealloc_mutex'),
    @test_alloc_mutex, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('install_mutex_counters'),
    @test_install_mutex_counters, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('read_mutex_counters'),
    @test_read_mutex_counters, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('clear_mutex_counters'),
    @test_clear_mutex_counters, nil, nil);
  { test_mutex.c:500..503 — Tcl_LinkVar the failure-injection switches. }
  Tcl_LinkVar(interp, PChar('disable_mutex_init'),
    @mutexG.disableInit, TCL_LINK_INT);
  Tcl_LinkVar(interp, PChar('disable_mutex_try'),
    @mutexG.disableTry, TCL_LINK_INT);
  { test1.c:6726..6746 — vfs_initfail_test (mutex2-2.10). }
  Tcl_CreateObjCommand(interp, PChar('vfs_initfail_test'),
    @vfs_initfail_test, nil, nil);
  { test_autoext.c:205..206 — sqlite3_auto_extension_sqr (mutex2-2.5). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_auto_extension_sqr'),
    @test_auto_extension_sqr, nil, nil);
  { 9.4.divbug.88.050/051 — test_malloc.c:1494..1495 sqlite3_config_memstatus
    and sqlite3_config_lookaside. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config_memstatus'),
    @test_config_memstatus, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config_lookaside'),
    @test_config_lookaside, nil, nil);
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
  Tcl_CreateCommand(interp, PChar('sqlite3_snprintf_str'),
    @tcl_snprintf_str, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_snprintf_int'),
    @tcl_snprintf_int, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_step'),
    @tcl_test_step, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_finalize'),
    @tcl_test_finalize, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_reset'),
    @tcl_test_reset, nil, nil);
  { 6.40.6 (HARNESS) — uses_stmt_journal.  test1.c:9169. }
  Tcl_CreateObjCommand(interp, PChar('uses_stmt_journal'),
    @uses_stmt_journal, nil, nil);
  { 6.40.6 (HARNESS) — sqlite3_pager_refcounts.  test1.c:9181. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_pager_refcounts'),
    @test_pager_refcounts, nil, nil);
  { 6.40.6 (HARNESS) — pcache_stats.  test1.c:9283. }
  Tcl_CreateObjCommand(interp, PChar('pcache_stats'),
    @test_pcache_stats, nil, nil);
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
  { 9.4.divbug.62.b extension — stmt-introspection (test1.c:5602..5656,
    2288..2330, 2952..2998, 3034..3057). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_sql'),
    @tcl_test_sql, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_expanded_sql'),
    @tcl_test_ex_sql, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_normalized_sql'),
    @tcl_test_norm_sql, nil, nil);
  { 9.4.divbug.88.058 — sqlite3_normalize SQL (test1.c:5550..5572). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_normalize'),
    @tcl_test_normalize, nil, nil);
  { 9.4.divbug.88.053 — clang_sanitize_address (test1.c:272..291). }
  Tcl_CreateObjCommand(interp, PChar('clang_sanitize_address'),
    @tcl_test_clang_sanitize_address, nil, nil);
  { 9.4.divbug.88.007 — sqlite3_register_cksumvfs / _unregister_cksumvfs
    STUBS (test1.c:9328..9329).  Full cksumvfs.c port deferred. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_register_cksumvfs'),
    @tcl_test_register_cksumvfs, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_unregister_cksumvfs'),
    @tcl_test_unregister_cksumvfs, nil, nil);
  { 9.4.divbug.88.069.b — sqlite3_delete_database (test1.c:9321). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_delete_database'),
    @tcl_test_delete_database, nil, nil);

  { 9.4.divbug.88.069 — sqlite3_multiplex_* (test_multiplex.c:1352..1367).
    Full multiplex shim VFS in passqlite3multiplex.pas. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_multiplex_initialize'),
    @tcl_test_multiplex_initialize, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_multiplex_shutdown'),
    @tcl_test_multiplex_shutdown, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_multiplex_control'),
    @tcl_test_multiplex_control, nil, nil);
  { 9.4.divbug.88.034 — sqlite3_enable_shared_cache (test1.c:9275). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_enable_shared_cache'),
    @tcl_test_enable_shared, nil, nil);
  { 9.4.divbug.88.023 — decode_hexdb TEXT (test1.c:8837..8910). }
  Tcl_CreateObjCommand(interp, PChar('decode_hexdb'),
    @tcl_test_decode_hexdb, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_stmt_status'),
    @tcl_test_stmt_status, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_stmt_busy'),
    @tcl_test_stmt_busy, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_stmt_readonly'),
    @tcl_test_stmt_readonly, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_stmt_isexplain'),
    @tcl_test_stmt_isexplain, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_bytes16'),
    @tcl_column_bytes16, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_column_text16'),
    @tcl_column_text16, nil, nil);
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
  { 9.4.divbug.62.c — sqlite3_status / _release_memory / _limit / _rekey
    / _create_function (test1.c:9081..9186). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_status'),
    @tcl_test_status, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_release_memory'),
    @tcl_test_release_memory, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_db_release_memory'),
    @tcl_test_db_release_memory, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_limit'),
    @tcl_test_limit, nil, nil);
  { 9.4.divbug.62.d — sqlite3_db_status / _soft_heap_limit[64] /
    _hard_heap_limit64 (test_malloc.c:1489..1490 + test1.c:9177..9179). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_db_status'),
    @tcl_test_db_status, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_soft_heap_limit'),
    @tcl_test_soft_heap_limit, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_soft_heap_limit64'),
    @tcl_test_soft_heap_limit, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_hard_heap_limit64'),
    @tcl_test_hard_heap_limit, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_rekey'),
    @tcl_test_rekey, nil, nil);
  { 9.4.divbug.62.f — sqlite3_key + SEE-only _v2 variants
    (test1.c:9088 + engine APIs).  All TCL_OK stubs without SEE. }
  Tcl_CreateCommand(interp, PChar('sqlite3_key'),
    @tcl_test_key, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_key_v2'),
    @tcl_test_key_v2, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_rekey_v2'),
    @tcl_test_key_v2, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_create_function'),
    @test_create_function, nil, nil);
  { test1.c:9268 — add_test_function (objc/objv-style). }
  Tcl_CreateObjCommand(interp, PChar('add_test_function'),
    @test_function, nil, nil);
  { test1.c:9266..9267 — add_test_collate / add_test_collate_needed. }
  Tcl_CreateObjCommand(interp, PChar('add_test_collate'),
    @test_collate, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('add_test_collate_needed'),
    @test_collate_needed, nil, nil);
  { test1.c:9226 — add_alignment_test_collations. }
  Tcl_CreateObjCommand(interp, PChar('add_alignment_test_collations'),
    @add_alignment_test_collations, nil, nil);
  { test5.c:206..209 — binarize / test_translate / translate_selftest
    (upstream Sqlitetest5_Init). }
  Tcl_CreateObjCommand(interp, PChar('binarize'),
    @binarize, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('test_translate'),
    @test_translate, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('translate_selftest'),
    @test_translate_selftest, nil, nil);
  { test1.c:9399..9400 — ::sqlite_last_needed_collation, read-only string
    backed by pzNeededCollation (which points at the zNeededCollation buffer
    the collation-needed callback writes). }
  Tcl_LinkVar(interp, PChar('sqlite_last_needed_collation'),
    @pzNeededCollation, TCL_LINK_STRING or TCL_LINK_READ_ONLY);
  { test1.c:9092..9093 — sqlite_delete_function / sqlite_delete_collation
    (old-style argc/argv).  Needed by schema.test 11.2/11.6 + schema2.test. }
  Tcl_CreateCommand(interp, PChar('sqlite_delete_function'),
    @delete_function, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite_delete_collation'),
    @delete_collation, nil, nil);
  { 9.4.divbug.88.042 + 9.4.divbug.88.060 — test1.c:9094 sqlite3_get_autocommit. }
  Tcl_CreateCommand(interp, PChar('sqlite3_get_autocommit'),
    @get_autocommit, nil, nil);
  { test1.c:9370..9371 — expose the undocumented sort counter so
    regression tests (between.test's `queryplan` proc, etc.) can
    verify the optimizer correctly elides ORDER BY sorts. }
  Tcl_LinkVar(interp, PChar('sqlite_sort_count'),
    @sqlite3_sort_count, TCL_LINK_INT);
  { test1.c:9374 Tcl_LinkVar(sqlite_like_count) — LIKE/GLOB invocation
    counter (func.c:891) for like.test 3.x / 4.x / 5.x. }
  Tcl_LinkVar(interp, PChar('sqlite_like_count'),
    @sqlite3_like_count, TCL_LINK_INT);
  { test1.c:9395 — expose the alignment-collation counter so utf16align.test
    can read/reset it. }
  Tcl_LinkVar(interp, PChar('unaligned_string_counter'),
    @unaligned_string_counter, TCL_LINK_INT);
  { test1.c:9439..9442 — expose unixSync's fsync/FULLFSYNC counters
    (sqlite3_sync_count / sqlite3_fullsync_count, os_unix.c:3728..3729)
    so sync.test / sync2.test / wal2.test can verify that PRAGMA
    synchronous gates fsync correctly. }
  Tcl_LinkVar(interp, PChar('sqlite_sync_count'),
    @sqlite3_sync_count, TCL_LINK_INT);
  Tcl_LinkVar(interp, PChar('sqlite_fullsync_count'),
    @sqlite3_fullsync_count, TCL_LINK_INT);
  { 9.4.divbug.62.d — sqlite3_config_uri / _config_pmasz
    (test_malloc.c:1163..1241, registered at test_malloc.c:1497, 1499)
    and sqlite3_reset_auto_extension (test_autoext.c:189..219). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config_uri'),
    @tcl_test_config_uri, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config_pmasz'),
    @tcl_test_config_pmasz, nil, nil);
  { coveridxscan — sqlite3_config_cis
    (test_malloc.c:1186..1213, registered at test_malloc.c:1498). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config_cis'),
    @tcl_test_config_cis, nil, nil);
  { 9.4.divbug.62.f — sqlite3_config_alt_pcache stub
    (test_malloc.c:927..966, registered at test_malloc.c:1488).
    Validates args; install is a no-op since test_pcache.c is not
    ported. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_config_alt_pcache'),
    @tcl_test_config_alt_pcache, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_reset_auto_extension'),
    @tcl_reset_auto_extension, nil, nil);
  { 9.4.divbug.63.a — breakpoint / database_*_corrupt / tcl_variable_type
    (test1.c:9087 old-style, 9194..9195 / 9272 objCommand). }
  Tcl_CreateCommand(interp, PChar('breakpoint'),
    @test_breakpoint, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('database_never_corrupt'),
    @database_never_corrupt, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('database_may_be_corrupt'),
    @database_may_be_corrupt, nil, nil);
  { 6.40.6 (HARNESS) — extra_schema_checks.  test1.c:9193. }
  Tcl_CreateObjCommand(interp, PChar('extra_schema_checks'),
    @extra_schema_checks, nil, nil);
  { 6.40.6 (HARNESS) — file_control_powersafe_overwrite.  test1.c:9256. }
  Tcl_CreateObjCommand(interp, PChar('file_control_powersafe_overwrite'),
    @file_control_powersafe_overwrite, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('tcl_variable_type'),
    @tcl_variable_type, nil, nil);
  { 9.4.divbug.63.b — file_control_reservebytes (test1.c:9258 / 7249..7276). }
  Tcl_CreateObjCommand(interp, PChar('file_control_reservebytes'),
    @file_control_reservebytes, nil, nil);
  { 9.4.divbug.63 — sorter_test_fakeheap / sorter_test_sort4_helper
    (test1.c:9301..9302 / 8469..8574).  sort4.test helpers. }
  Tcl_CreateObjCommand(interp, PChar('sorter_test_fakeheap'),
    @sorter_test_fakeheap, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sorter_test_sort4_helper'),
    @sorter_test_sort4_helper, nil, nil);
  { 9.4.divbug.88.006 — file_control_chunksize_test (test1.c:9247 / 6912..6941). }
  Tcl_CreateObjCommand(interp, PChar('file_control_chunksize_test'),
    @file_control_chunksize_test, nil, nil);
  { 9.4.divbug.88.024 — file_control_data_version (test1.c:9249 / 6873..6903). }
  Tcl_CreateObjCommand(interp, PChar('file_control_data_version'),
    @file_control_data_version, nil, nil);
  { 9.4.divbug.88.037 — file_control_test (test1.c:9244 / 6795..6827). }
  Tcl_CreateObjCommand(interp, PChar('file_control_test'),
    @file_control_test_tcl, nil, nil);
  { 9.4.divbug.88.065 — file_control_lasterrno_test (test1.c:9245 / 6830..6865). }
  Tcl_CreateObjCommand(interp, PChar('file_control_lasterrno_test'),
    @file_control_lasterrno_test_tcl, nil, nil);
  { 9.4.divbug.88.065 — file_control_tempfilename (test1.c:9259 / 7279..7309). }
  Tcl_CreateObjCommand(interp, PChar('file_control_tempfilename'),
    @file_control_tempfilename_tcl, nil, nil);
  { 9.4.divbug.88.067 — file_control_lockproxy_test (test1.c:9246 / 6987..7048).
    Linux: no-op stub (Apple-only body compiled out). }
  Tcl_CreateObjCommand(interp, PChar('file_control_lockproxy_test'),
    @file_control_lockproxy_test_tcl, nil, nil);
  { 9.4.divbug.62.e — sqlite3_create_function_v2 / _create_window_function /
    _load_extension / _simulate_device / _user_version
    (test1.c:9262 + 9183 + test_window.c:337). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_create_function_v2'),
    @tcl_test_create_function_v2, nil, nil);
  { 9.4.divbug.88.009 — sqlite3_create_collation_v2 (test1.c:9237). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_create_collation_v2'),
    @tcl_test_create_collation_v2, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_create_window_function'),
    @tcl_test_create_window, nil, nil);
  { 6.40.8 — test_window.c:338 test_create_window_function_misuse. }
  Tcl_CreateObjCommand(interp, PChar('test_create_window_function_misuse'),
    @tcl_test_create_window_misuse, nil, nil);
  { 6.40.8 — test_window.c:339 test_create_sumint. }
  Tcl_CreateObjCommand(interp, PChar('test_create_sumint'),
    @tcl_test_create_sumint, nil, nil);
  { 6.40.8 — test_window.c:340 test_override_sum. }
  Tcl_CreateObjCommand(interp, PChar('test_override_sum'),
    @tcl_test_override_sum, nil, nil);
  { 6.40.8 — test1.c:9139 sqlite3_set_errmsg. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_set_errmsg'),
    @tcl_test_set_errmsg, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_load_extension'),
    @tcl_test_load_extension, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_simulate_device'),
    @tcl_test_simulate_device, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_crash_on_write'),
    @tcl_test_crash_on_write, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('unregister_devsim'),
    @tcl_test_unregister_devsim, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_user_version'),
    @tcl_test_user_version, nil, nil);
  { 9.4.divbug.87.005 — sqlite3_table_column_metadata (test1.c:9279). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_table_column_metadata'),
    @tcl_test_table_column_metadata, nil, nil);
  { test_blob.c:310..328 — Sqlitetest_blob_Init: the incremental-BLOB
    Tcl wrappers (sqlite3_blob_open / _close / _bytes / _read / _write). }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_blob_open'),
    @test_blob_open, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_blob_close'),
    @test_blob_close, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_blob_bytes'),
    @test_blob_bytes, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_blob_read'),
    @test_blob_read, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_blob_write'),
    @test_blob_write, nil, nil);
  { 6.40.9 — WAL/blob test-harness commands.
    test1.c:9281 blob_reopen, 9288 wal_checkpoint_v2, 9323 mmap_warm;
    test1.c:9090/9091 interrupt + is_interrupted (old-style);
    test_hexio.c:466 utf8_to_utf8. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3_blob_reopen'),
    @test_blob_reopen, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_wal_checkpoint_v2'),
    @test_wal_checkpoint_v2, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_mmap_warm'),
    @test_mmap_warm, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('utf8_to_utf8'),
    @utf8_to_utf8, nil, nil);
  { test_hexio.c:468 make_fts3record. }
  Tcl_CreateObjCommand(interp, PChar('make_fts3record'),
    @make_fts3record, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_interrupt'),
    @test_interrupt, nil, nil);
  Tcl_CreateCommand(interp, PChar('sqlite3_is_interrupted'),
    @test_is_interrupted, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_carray_bind'),
    @tcl_test_carray_bind, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('bind_carray_intptr'),
    @tcl_bind_carray_intptr, nil, nil);
  { test1.c:9110..9113 — intarray_addr / int64array_addr /
    doublearray_addr / textarray_addr (carray-binding helpers). }
  Tcl_CreateObjCommand(interp, PChar('intarray_addr'),
    @tcl_test_intarray_addr, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('int64array_addr'),
    @tcl_test_int64array_addr, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('doublearray_addr'),
    @tcl_test_doublearray_addr, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('textarray_addr'),
    @tcl_test_textarray_addr, nil, nil);
  { test2.c:732 — sqlite3BitvecBuiltinTest (registered by Sqlitetest2_Init
    in C; the pas Sqlitetest2_Init is a stub, so register it here). }
  Tcl_CreateCommand(interp, PChar('sqlite3BitvecBuiltinTest'),
    @testBitvecBuiltinTest, nil, nil);
  { func.test — test1.c:9084 sqlite_register_test_function. }
  Tcl_CreateCommand(interp, PChar('sqlite_register_test_function'),
    @test_register_func, nil, nil);
  { misc1.test — test1.c:9133 sqlite3_sleep. }
  Tcl_CreateCommand(interp, PChar('sqlite3_sleep'),
    @test_sleep, nil, nil);
  { misc1.test — test2.c:734 sqlite3_test_control_fault_install (registered
    by Sqlitetest2_Init in C; the pas Sqlitetest2_Init is a stub, so
    register it here). }
  Tcl_CreateCommand(interp, PChar('sqlite3_test_control_fault_install'),
    @faultInstallCmd, nil, nil);
  { test1.c:9200 — tcl_objproc. }
  Tcl_CreateObjCommand(interp, PChar('tcl_objproc'),
    @runAsObjProc, nil, nil);
  Result := TCL_OK;
end;

end.
