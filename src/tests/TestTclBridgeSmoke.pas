program TestTclBridgeSmoke;

{
  Phase 9.4.2.a smoke gate.

  Spins up a Tcl 8.6 interp via the PasTclBridge unit, evaluates
  `expr 2+2`, and asserts the obj-result reads back as "4".  Exits
  rc=0 on success, rc=1 on any failure (interp == nil, Tcl_Eval rc,
  unexpected result).

  C reference: /home/bpsa/app/sqlite3/src/tclsqlite.c
    * Tcl_CreateInterp           — line 4583
    * Tcl_Eval                   — line 703
    * Tcl_GetObjResult           — line 874
    * Tcl_GetStringFromObj       — line 535
    * Tcl_DeleteInterp           — std cleanup
}

{$mode objfpc}{$H+}

uses
  SysUtils,
  ctypes,
  PasTclBridge;

var
  interp: PTclInterp;
  rc: cint;
  zRes: PChar;
  sRes: AnsiString;

begin
  InitTclLibrary;

  interp := Tcl_CreateInterp;
  if interp = nil then
  begin
    Writeln('FAIL: Tcl_CreateInterp returned nil');
    Halt(1);
  end;

  rc := Tcl_Eval(interp, PChar('expr 2+2'));
  if rc <> TCL_OK then
  begin
    Writeln('FAIL: Tcl_Eval rc=', rc,
            ' err=', Tcl_GetStringResult(interp));
    Tcl_DeleteInterp(interp);
    Halt(1);
  end;

  zRes := Tcl_GetStringFromObj(Tcl_GetObjResult(interp), nil);
  if zRes = nil then sRes := '' else sRes := zRes;

  if sRes <> '4' then
  begin
    Writeln('FAIL: expected "4", got "', sRes, '"');
    Tcl_DeleteInterp(interp);
    Halt(1);
  end;

  Writeln('PASS: expr 2+2 -> ', sRes);
  Tcl_DeleteInterp(interp);
  Halt(0);
end.
