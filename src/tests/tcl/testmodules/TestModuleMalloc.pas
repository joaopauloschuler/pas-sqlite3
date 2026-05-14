{
  SPDX-License-Identifier: blessing

  Partial port of ../sqlite3/src/test_malloc.c — the malloc fault-injection
  layer and its Tcl test commands (tasks 9.4.6.n / 9.4.7.b).

  The core piece is the `MemFault` fault-injection allocator: a
  sqlite3_mem_methods wrapper installed via SQLITE_CONFIG_GETMALLOC /
  SQLITE_CONFIG_MALLOC that, after a configurable countdown, makes the
  next N allocations fail.  This is what `do_malloc_test` (test/tester.tcl,
  task 9.4.2.g.9) drives to exercise SQLite's OOM-recovery paths.

  Tcl commands registered by Sqlitetest_malloc_Init:
    * sqlite3_malloc NBYTES               — raw sqlite3_malloc()
    * sqlite3_realloc PRIOR NBYTES         — raw sqlite3_realloc()
    * sqlite3_free PRIOR                   — raw sqlite3_free()
    * sqlite3_memory_used                  — sqlite3_memory_used()
    * sqlite3_memory_highwater ?RESET?     — sqlite3_memory_highwater()
    * install_malloc_faultsim BOOLEAN      — install/remove the fault layer
    * sqlite3_memdebug_fail CTR ?OPTIONS?  — schedule a fault after CTR oks
    * sqlite3_memdebug_pending              — oks remaining before next fault
    * sqlite3_memdebug_settitle TITLE      — per-allocation title (MEMDEBUG)
    * sqlite3_memdebug_backtrace DEPTH     — backtrace depth (MEMDEBUG)
    * sqlite3_memdebug_malloc_count        — total malloc() calls (MEMDEBUG)

  The `sqlite3_memdebug_settitle` / `_backtrace` / `_malloc_count` command
  bodies are gated on {$ifdef SQLITE_MEMDEBUG}; in a non-memdebug build
  they are harmless no-ops (settitle/backtrace) or return -1
  (malloc_count) — matching the C source where those bodies sit behind
  #ifdef SQLITE_MEMDEBUG.  The fault-injection layer itself is always
  compiled in (it is in C too).

  C ref: ../sqlite3/src/test_malloc.c.
}
{$I passqlite3.inc}
unit TestModuleMalloc;

interface

uses
  ctypes,
  SysUtils,
  PasTclBridge,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3main;

function Sqlitetest_malloc_Init(interp: PTclInterp): cint; cdecl;

implementation

{ test_malloc.c:26..37 — the global fault-injection state. }
type
  TMemFault = record
    iCountdown:   cint;   { pending successes before a failure }
    nRepeat:      cint;   { number of times to repeat the failure }
    nBenign:      cint;   { benign failures since last config }
    nFail:        cint;   { failures since last config }
    nOkBefore:    cint;   { successful allocations prior to first fault }
    nOkAfter:     cint;   { successful allocations after a fault }
    enable:       Byte;   { true if enabled }
    isInstalled:  cint;   { true if the fault layer is installed }
    isBenignMode: cint;   { true if malloc failures are considered benign }
    m:            Tsqlite3_mem_methods;  { 'real' malloc implementation }
  end;

var
  memfault: TMemFault;

{ test_malloc.c:65..86 — faultsimStep.  Returns true to simulate a fault. }
function faultsimStep: cint;
begin
  if memfault.enable = 0 then
  begin
    Inc(memfault.nOkAfter);
    Result := 0;
    Exit;
  end;
  if memfault.iCountdown > 0 then
  begin
    Dec(memfault.iCountdown);
    Inc(memfault.nOkBefore);
    Result := 0;
    Exit;
  end;
  Inc(memfault.nFail);
  if memfault.isBenignMode > 0 then
    Inc(memfault.nBenign);
  Dec(memfault.nRepeat);
  if memfault.nRepeat <= 0 then
    memfault.enable := 0;
  Result := 1;
end;

{ test_malloc.c:92..98 — faultsimMalloc. }
function faultsimMalloc(n: cint): Pointer; cdecl;
begin
  Result := nil;
  if faultsimStep = 0 then
    Result := memfault.m.xMalloc(n);
end;

{ test_malloc.c:105..111 — faultsimRealloc. }
function faultsimRealloc(pOld: Pointer; n: cint): Pointer; cdecl;
begin
  Result := nil;
  if faultsimStep = 0 then
    Result := memfault.m.xRealloc(pOld, n);
end;

{ test_malloc.c:119..136 — faultsimConfig. }
procedure faultsimConfig(nDelay, nRepeat: cint);
begin
  memfault.iCountdown := nDelay;
  memfault.nRepeat    := nRepeat;
  memfault.nBenign    := 0;
  memfault.nFail      := 0;
  memfault.nOkBefore  := 0;
  memfault.nOkAfter   := 0;
  if nDelay >= 0 then
    memfault.enable := 1
  else
    memfault.enable := 0;
  memfault.isBenignMode := 0;
end;

{ test_malloc.c:142..144 — faultsimFailures. }
function faultsimFailures: cint;
begin
  Result := memfault.nFail;
end;

{ test_malloc.c:150..152 — faultsimBenignFailures. }
function faultsimBenignFailures: cint;
begin
  Result := memfault.nBenign;
end;

{ test_malloc.c:158..164 — faultsimPending. }
function faultsimPending: cint;
begin
  if memfault.enable <> 0 then
    Result := memfault.iCountdown
  else
    Result := -1;
end;

{ test_malloc.c:167..172 — benign-mode hooks.

  Pascal-port note: the Pascal engine's sqlite3_test_control does not yet
  implement SQLITE_TESTCTRL_BENIGN_MALLOC_HOOKS (op 10), so faultsimInstall
  cannot register these the way the C source does.  They are kept here for
  parity and so the engine's sqlite3BeginBenignMalloc machinery can be
  pointed at them once that op is ported; for now nBenign simply stays 0,
  which only affects the optional `-benigncnt` reporting of
  sqlite3_memdebug_fail, not fault injection itself. }
procedure faultsimBeginBenign;
begin
  Inc(memfault.isBenignMode);
end;

procedure faultsimEndBenign;
begin
  Dec(memfault.isBenignMode);
end;

{ test_malloc.c:178..220 — faultsimInstall.  Add/remove the fault layer
  via sqlite3_config(). }
function faultsimInstall(install: cint): cint;
var
  rc: cint;
  m:  Tsqlite3_mem_methods;
  m2: Tsqlite3_mem_methods;
begin
  if install <> 0 then
    install := 1;

  if install = memfault.isInstalled then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  if install <> 0 then
  begin
    rc := sqlite3_config(SQLITE_CONFIG_GETMALLOC, @memfault.m);
    if rc = SQLITE_OK then
    begin
      m := memfault.m;
      m.xMalloc  := @faultsimMalloc;
      m.xRealloc := @faultsimRealloc;
      rc := sqlite3_config(SQLITE_CONFIG_MALLOC, @m);
    end;
    { C also calls sqlite3_test_control(SQLITE_TESTCTRL_BENIGN_MALLOC_HOOKS,
      ...) here — see faultsimBeginBenign/faultsimEndBenign above; that
      test-control op is not yet ported on the Pascal side. }
  end
  else
  begin
    { Reset to the default allocator by storing a zeroed allocator then
      calling GETMALLOC, then re-storing the saved real allocator. }
    FillChar(m2, SizeOf(m2), 0);
    sqlite3_config(SQLITE_CONFIG_MALLOC, @m2);
    sqlite3_config(SQLITE_CONFIG_GETMALLOC, @m2);
    rc := sqlite3_config(SQLITE_CONFIG_MALLOC, @memfault.m);
  end;

  if rc = SQLITE_OK then
    memfault.isInstalled := install;
  Result := rc;
end;

{ ----------------------------------------------------------------------
  test_malloc.c:237..289 — pointer <-> text helpers.
  ---------------------------------------------------------------------- }
procedure pointerToText(p: Pointer; z: PAnsiChar);
const
  zHex: array[0..15] of AnsiChar = '0123456789abcdef';
var
  i, k: cint;
  n:    QWord;
begin
  if p = nil then
  begin
    z[0] := '0';
    z[1] := #0;
    Exit;
  end;
  n := QWord(PtrUInt(p));
  k := SizeOf(Pointer) * 2 - 1;
  for i := 0 to SizeOf(Pointer) * 2 - 1 do
  begin
    z[k] := zHex[n and $f];
    n := n shr 4;
    Dec(k);
  end;
  z[SizeOf(Pointer) * 2] := #0;
end;

function hexToInt(h: cint): cint;
begin
  if (h >= Ord('0')) and (h <= Ord('9')) then
    Result := h - Ord('0')
  else if (h >= Ord('a')) and (h <= Ord('f')) then
    Result := h - Ord('a') + 10
  else
    Result := -1;
end;

function textToPointer(z: PAnsiChar; pp: PPointer): cint;
var
  n: QWord;
  i, v: cint;
begin
  n := 0;
  i := 0;
  while (i < SizeOf(Pointer) * 2) and (z^ <> #0) do
  begin
    v := hexToInt(Ord(z^));
    Inc(z);
    if v < 0 then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
    n := n * 16 + QWord(v);
    Inc(i);
  end;
  if z^ <> #0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  pp^ := Pointer(PtrUInt(n));
  Result := TCL_OK;
end;

{ test_malloc.c:296..314 — test_malloc:  sqlite3_malloc NBYTES }
function test_malloc(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  nByte: cint;
  p:     Pointer;
  zOut:  array[0..99] of AnsiChar;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('NBYTES'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @nByte) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  p := sqlite3_malloc(nByte);
  pointerToText(p, @zOut[0]);
  Tcl_AppendResult(interp, PChar(@zOut[0]), Pointer(nil));
  Result := TCL_OK;
end;

{ test_malloc.c:321..343 — test_realloc:  sqlite3_realloc PRIOR NBYTES }
function test_realloc(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  nByte:  cint;
  pPrior: Pointer;
  p:      Pointer;
  zOut:   array[0..99] of AnsiChar;
begin
  if objc <> 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('PRIOR NBYTES'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[2], @nByte) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  if textToPointer(Tcl_GetString(objv[1]), @pPrior) <> 0 then
  begin
    Tcl_AppendResult(interp, PChar('bad pointer: '),
      Tcl_GetString(objv[1]), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  p := sqlite3_realloc(pPrior, nByte);
  pointerToText(p, @zOut[0]);
  Tcl_AppendResult(interp, PChar(@zOut[0]), Pointer(nil));
  Result := TCL_OK;
end;

{ test_malloc.c:350..367 — test_free:  sqlite3_free PRIOR }
function test_free(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pPrior: Pointer;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('PRIOR'));
    Result := TCL_ERROR;
    Exit;
  end;
  if textToPointer(Tcl_GetString(objv[1]), @pPrior) <> 0 then
  begin
    Tcl_AppendResult(interp, PChar('bad pointer: '),
      Tcl_GetString(objv[1]), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  sqlite3_free(pPrior);
  Result := TCL_OK;
end;

{ test_malloc.c:475..483 — test_memory_used:  sqlite3_memory_used }
function test_memory_used(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  Tcl_SetObjResult(interp, Tcl_NewWideIntObj(sqlite3_memory_used));
  Result := TCL_OK;
end;

{ test_malloc.c:490..507 — test_memory_highwater:
  sqlite3_memory_highwater ?RESETFLAG? }
function test_memory_highwater(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  resetFlag: cint;
begin
  resetFlag := 0;
  if (objc <> 1) and (objc <> 2) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?RESET?'));
    Result := TCL_ERROR;
    Exit;
  end;
  if objc = 2 then
    if Tcl_GetBooleanFromObj(interp, objv[1], @resetFlag) <> 0 then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
  Tcl_SetObjResult(interp,
    Tcl_NewWideIntObj(sqlite3_memory_highwater(resetFlag)));
  Result := TCL_OK;
end;

{ test_malloc.c:515..534 — test_memdebug_backtrace:
  sqlite3_memdebug_backtrace DEPTH.  No-op unless SQLITE_MEMDEBUG. }
function test_memdebug_backtrace(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  depth: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DEPT'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @depth) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  {$ifdef SQLITE_MEMDEBUG}
  { sqlite3MemdebugBacktrace(depth) — the debug allocator is not yet
    ported; the command is a no-op even under the memdebug profile. }
  {$endif}
  Result := TCL_OK;
end;

{ test_malloc.c:566..585 — test_memdebug_malloc_count:
  sqlite3_memdebug_malloc_count.  Returns -1 unless SQLITE_MEMDEBUG. }
function test_memdebug_malloc_count(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  nMalloc: cint;
begin
  nMalloc := -1;
  if objc <> 1 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR;
    Exit;
  end;
  {$ifdef SQLITE_MEMDEBUG}
  { sqlite3MemdebugMallocCount() — the debug allocator is not yet ported;
    leave nMalloc as -1. }
  {$endif}
  Tcl_SetObjResult(interp, Tcl_NewIntObj(nMalloc));
  Result := TCL_OK;
end;

{ test_malloc.c:606..663 — test_memdebug_fail:
  sqlite3_memdebug_fail COUNTER ?OPTIONS?
  Options:  -repeat <count>   -benigncnt <varname>
  Returns the number of simulated failures since the previous call. }
function test_memdebug_fail(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  ii, iFail, nRepeat, nBenign, nFail: cint;
  nOption:    cint;
  pBenignCnt: PTclObj;
  zOption:    PAnsiChar;
  zErr:       PAnsiChar;
begin
  nRepeat    := 1;
  pBenignCnt := nil;
  nFail      := 0;

  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('COUNTER ?OPTIONS?'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetIntFromObj(interp, objv[1], @iFail) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;

  ii := 2;
  while ii < objc do
  begin
    zOption := Tcl_GetStringFromObj(objv[ii], @nOption);
    zErr := nil;

    if (nOption > 1) and (StrLComp(zOption, PAnsiChar('-repeat'), nOption) = 0) then
    begin
      if ii = (objc - 1) then
        zErr := 'option requires an argument: '
      else if Tcl_GetIntFromObj(interp, objv[ii + 1], @nRepeat) <> 0 then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
    end
    else if (nOption > 1) and (StrLComp(zOption, PAnsiChar('-benigncnt'), nOption) = 0) then
    begin
      if ii = (objc - 1) then
        zErr := 'option requires an argument: '
      else
        pBenignCnt := objv[ii + 1];
    end
    else
      zErr := 'unknown option: ';

    if zErr <> nil then
    begin
      Tcl_AppendResult(interp, zErr, zOption, Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
    Inc(ii, 2);
  end;

  nBenign := faultsimBenignFailures;
  nFail   := faultsimFailures;
  faultsimConfig(iFail, nRepeat);

  if pBenignCnt <> nil then
    Tcl_ObjSetVar2(interp, pBenignCnt, nil, Tcl_NewIntObj(nBenign), 0);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(nFail));
  Result := TCL_OK;
end;

{ test_malloc.c:672..686 — test_memdebug_pending:
  sqlite3_memdebug_pending.  Successes remaining before the next fault. }
function test_memdebug_pending(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  nPending: cint;
begin
  if objc <> 1 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR;
    Exit;
  end;
  nPending := faultsimPending;
  Tcl_SetObjResult(interp, Tcl_NewIntObj(nPending));
  Result := TCL_OK;
end;

{ test_malloc.c:693 — counter incremented on every settitle call. }
var
  sqlite3_memdebug_title_count: cint = 0;

{ test_malloc.c:705..725 — test_memdebug_settitle:
  sqlite3_memdebug_settitle TITLE.  No-op unless SQLITE_MEMDEBUG. }
function test_memdebug_settitle(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
{$ifdef SQLITE_MEMDEBUG}
var
  zTitle: PAnsiChar;
{$endif}
begin
  Inc(sqlite3_memdebug_title_count);
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('TITLE'));
    Result := TCL_ERROR;
    Exit;
  end;
  {$ifdef SQLITE_MEMDEBUG}
  zTitle := Tcl_GetString(objv[1]);
  { sqlite3MemdebugSettitle(zTitle) — the debug allocator is not yet
    ported; the title is accepted but not stored. }
  if zTitle = nil then ;
  {$endif}
  Result := TCL_OK;
end;

{ test_malloc.c:1406..1425 — test_install_malloc_faultsim:
  install_malloc_faultsim BOOLEAN }
function test_install_malloc_faultsim(clientData: TClientData;
  interp: PTclInterp; objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc, isInstall: cint;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('BOOLEAN'));
    Result := TCL_ERROR;
    Exit;
  end;
  if Tcl_GetBooleanFromObj(interp, objv[1], @isInstall) <> TCL_OK then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  rc := faultsimInstall(isInstall);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test_malloc.c:1467..1512 — register the Tcl commands. }
function Sqlitetest_malloc_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('sqlite3_malloc'),
    @test_malloc, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_realloc'),
    @test_realloc, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_free'),
    @test_free, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_memory_used'),
    @test_memory_used, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_memory_highwater'),
    @test_memory_highwater, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_memdebug_backtrace'),
    @test_memdebug_backtrace, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_memdebug_fail'),
    @test_memdebug_fail, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_memdebug_pending'),
    @test_memdebug_pending, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_memdebug_settitle'),
    @test_memdebug_settitle, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_memdebug_malloc_count'),
    @test_memdebug_malloc_count, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('install_malloc_faultsim'),
    @test_install_malloc_faultsim, nil, nil);
  Result := TCL_OK;
end;

initialization
  FillChar(memfault, SizeOf(memfault), 0);
end.
</content>
</invoke>
