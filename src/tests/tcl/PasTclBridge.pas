unit PasTclBridge;

{
  PasTclBridge — minimal FPC <-> Tcl 8.6 C ABI shim.

  All cdecl externs below are first used in
  /home/bpsa/app/sqlite3/src/tclsqlite.c at the cited line.  The libtcl8.6
  C entry points are stable across 8.6.x and live in
  /usr/lib/x86_64-linux-gnu/libtcl8.6.so.0 (Debian/Ubuntu so-name
  `libtcl8.6.so`, resolved via /etc/ld.so.conf.d).  FPC's `external 'tcl8.6'`
  emits a DT_NEEDED of `libtcl8.6.so` so ld.so finds the .0 SONAME at run
  time.

  Notes
  -----
  * `Tcl_IncrRefCount` / `Tcl_DecrRefCount` are *macros* in tcl.h (they poke
    the Tcl_Obj.refCount field directly), so the symbols are not exported
    from libtcl8.6.so.  We instead bind the always-present debug variants
    `Tcl_DbIncrRefCount` / `Tcl_DbDecrRefCount` and pass dummy file/line —
    this is the same fall-back trick the Tcl FFI bindings of TclKit and
    Python's `tkinter` use, and avoids depending on the Tcl_Obj struct
    layout from Pascal land.  Cites: tclsqlite.c:752, 620.
  * Tcl_Obj is opaque to us.  We never read its fields; we round-trip
    pointers and call accessor functions like `Tcl_GetStringFromObj`.
  * Calling convention is `cdecl` everywhere (libtcl is plain C).
  * `Tcl_FindExecutable(NULL)` must be called once before any interp work
    (Tcl >= 8.5 init contract).  See tclsqlite.c:4581.
}

{$mode objfpc}{$H+}

interface

uses ctypes;

const
  { Tcl result codes — tcl.h:475..483, used throughout tclsqlite.c. }
  TCL_OK         = 0;
  TCL_ERROR      = 1;
  TCL_RETURN     = 2;
  TCL_BREAK      = 3;
  TCL_CONTINUE   = 4;

  { Tcl string-lifetime markers — passed as the `freeProc` arg of
    Tcl_SetResult/Tcl_AppendElement etc.  tcl.h:1011..1014. }
  TCL_STATIC   : Pointer = Pointer(0);
  TCL_VOLATILE : Pointer = Pointer(1);
  TCL_DYNAMIC  : Pointer = Pointer(3);

  { Tcl variable / eval flag bits.  tcl.h:885 (TCL_GLOBAL_ONLY),
    tcl.h:931 (TCL_EVAL_DIRECT). }
  TCL_GLOBAL_ONLY = 1;       // tclsqlite.c:887
  TCL_EVAL_DIRECT = $40000;  // tclsqlite.c:757

type
  PTclInterp = Pointer;
  PTclObj    = Pointer;
  PPTclObj   = ^PTclObj;
  TClientData = Pointer;

  { Tcl_ObjCmdProc — typedef'd in tcl.h:769.  Used by Tcl_CreateObjCommand.
    Signature: int (*)(ClientData, Tcl_Interp*, int objc, Tcl_Obj* const* objv). }
  TTclObjCmdProc = function(clientData: TClientData; interp: PTclInterp;
    objc: cint; objv: PPTclObj): cint; cdecl;

  { Tcl_CmdDeleteProc — typedef'd in tcl.h:760. }
  TTclCmdDeleteProc = procedure(clientData: TClientData); cdecl;

{ ----------------------------------------------------------------------
  Interpreter lifecycle.  tclsqlite.c:4583 (CreateInterp), paired Delete. }
function  Tcl_CreateInterp: PTclInterp; cdecl; external 'tcl8.6';
procedure Tcl_DeleteInterp(interp: PTclInterp); cdecl; external 'tcl8.6';
procedure Tcl_FindExecutable(argv0: PChar); cdecl; external 'tcl8.6';  // tclsqlite.c:4581

{ ----------------------------------------------------------------------
  Script evaluation.  tclsqlite.c:703 (Tcl_Eval), :757 (EvalObjEx). }
function Tcl_Eval(interp: PTclInterp; script: PChar): cint; cdecl; external 'tcl8.6';
function Tcl_EvalFile(interp: PTclInterp; fileName: PChar): cint; cdecl; external 'tcl8.6';
function Tcl_EvalObjEx(interp: PTclInterp; objPtr: PTclObj; flags: cint): cint; cdecl; external 'tcl8.6';
function Tcl_EvalObjv(interp: PTclInterp; objc: cint; objv: PPTclObj; flags: cint): cint; cdecl; external 'tcl8.6';
function Tcl_DuplicateObj(objPtr: PTclObj): PTclObj; cdecl; external 'tcl8.6';

{ Command registration.  tclsqlite.c:4407. }
function Tcl_CreateObjCommand(interp: PTclInterp; cmdName: PChar;
  proc: TTclObjCmdProc; clientData: TClientData;
  deleteProc: TTclCmdDeleteProc): Pointer; cdecl; external 'tcl8.6';

{ Command teardown.  tclsqlite.c:2744 (Tcl_DeleteCommand by name in
  the DB_CLOSE arm of DbObjCmd); token form is the modern API.  Both
  end up firing the registered TTclCmdDeleteProc (i.e. DbDeleteCmd). }
function Tcl_DeleteCommand(interp: PTclInterp; cmdName: PChar): cint; cdecl; external 'tcl8.6';
function Tcl_DeleteCommandFromToken(interp: PTclInterp; cmd: Pointer): cint; cdecl; external 'tcl8.6';

{ Result accessors.  tclsqlite.c:874 (GetObjResult), :1451 (SetObjResult),
  :688 (GetStringResult), :1339 (AppendResult). }
function  Tcl_GetObjResult(interp: PTclInterp): PTclObj; cdecl; external 'tcl8.6';
procedure Tcl_SetObjResult(interp: PTclInterp; objPtr: PTclObj); cdecl; external 'tcl8.6';
function  Tcl_GetStringResult(interp: PTclInterp): PChar; cdecl; external 'tcl8.6';
procedure Tcl_AppendResult(interp: PTclInterp); cdecl; varargs; external 'tcl8.6';

{ Tcl_Obj <-> string.  tclsqlite.c:1094 (GetString), :535 (GetStringFromObj),
  :751 (NewStringObj). }
function Tcl_GetString(objPtr: PTclObj): PChar; cdecl; external 'tcl8.6';
function Tcl_GetStringFromObj(objPtr: PTclObj; lengthPtr: pcint): PChar; cdecl; external 'tcl8.6';
function Tcl_NewStringObj(bytes: PChar; length: cint): PTclObj; cdecl; external 'tcl8.6';

{ Numeric / blob Tcl_Obj factories.  tclsqlite.c:872 (NewIntObj),
  :754 (NewWideIntObj), :1070 (NewDoubleObj), :1056 (NewByteArrayObj). }
function Tcl_NewIntObj(intValue: cint): PTclObj; cdecl; external 'tcl8.6';
function Tcl_NewWideIntObj(wideValue: Int64): PTclObj; cdecl; external 'tcl8.6';
function Tcl_NewDoubleObj(doubleValue: Double): PTclObj; cdecl; external 'tcl8.6';
function Tcl_NewByteArrayObj(bytes: Pointer; length: cint): PTclObj; cdecl; external 'tcl8.6';

{ Lists.  tclsqlite.c:1046 (NewListObj), :753 (ListObjAppendElement),
  :1042 (ListObjGetElements). }
function Tcl_NewListObj(objc: cint; objv: PPTclObj): PTclObj; cdecl; external 'tcl8.6';
function Tcl_ListObjAppendElement(interp: PTclInterp; listPtr, objPtr: PTclObj): cint; cdecl; external 'tcl8.6';
function Tcl_ListObjGetElements(interp: PTclInterp; listPtr: PTclObj;
  objcPtr: pcint; objvPtr: PPointer): cint; cdecl; external 'tcl8.6';

{ Tcl_Obj refcount.  See header note above: macros in tcl.h, so we bind the
  Db* debug variants and pass dummies.  tclsqlite.c:752, 620 use the macros. }
function  Tcl_DbIncrRefCount(objPtr: PTclObj; fileName: PChar; line: cint): cint; cdecl; external 'tcl8.6';
function  Tcl_DbDecrRefCount(objPtr: PTclObj; fileName: PChar; line: cint): cint; cdecl; external 'tcl8.6';
procedure Tcl_IncrRefCount(objPtr: PTclObj); inline;
procedure Tcl_DecrRefCount(objPtr: PTclObj); inline;

{ Package + variable plumbing.  tclsqlite.c:4452 (PkgProvide),
  :887 (SetVar with TCL_GLOBAL_ONLY). }
function Tcl_PkgProvide(interp: PTclInterp; name, version: PChar): cint; cdecl; external 'tcl8.6';
function Tcl_GetVar(interp: PTclInterp; varName: PChar; flags: cint): PChar; cdecl; external 'tcl8.6';
function Tcl_SetVar(interp: PTclInterp; varName, newValue: PChar; flags: cint): PChar; cdecl; external 'tcl8.6';

{ Two-part (array) variable plumbing.  tclsqlite.c uses Tcl_ObjSetVar2 /
  Tcl_UnsetVar2 for the `db eval sql arr script` 3-arg form (DbEvalNextCmd
  at tclsqlite.c:1935..1944).  Tcl_SetVar2 is the string-keyed variant. }
function Tcl_SetVar2(interp: PTclInterp; part1, part2, newValue: PChar; flags: cint): PChar; cdecl; external 'tcl8.6';
function Tcl_ObjSetVar2(interp: PTclInterp; part1Ptr, part2Ptr, newValuePtr: PTclObj; flags: cint): PTclObj; cdecl; external 'tcl8.6';
function Tcl_UnsetVar2(interp: PTclInterp; part1, part2: PChar; flags: cint): cint; cdecl; external 'tcl8.6';

{ Reset the interpreter result.  tclsqlite.c:2003 (DbEvalNextCmd cleanup). }
procedure Tcl_ResetResult(interp: PTclInterp); cdecl; external 'tcl8.6';

{ Tcl_Obj -> primitive accessors.  tclsqlite.c:874, :1138, :1146. }
function Tcl_GetIntFromObj(interp: PTclInterp; objPtr: PTclObj; intPtr: pcint): cint; cdecl; external 'tcl8.6';
function Tcl_GetWideIntFromObj(interp: PTclInterp; objPtr: PTclObj; widePtr: PInt64): cint; cdecl; external 'tcl8.6';
function Tcl_GetDoubleFromObj(interp: PTclInterp; objPtr: PTclObj; doublePtr: PDouble): cint; cdecl; external 'tcl8.6';

{ Misc command-arg helpers.  tclsqlite.c:2476. }
procedure Tcl_WrongNumArgs(interp: PTclInterp; objc: cint; objv: PPTclObj; message: PChar); cdecl; external 'tcl8.6';

{ ----------------------------------------------------------------------
  Pascal-side helpers. }
procedure InitTclLibrary;
function  TclEvalGetString(interp: PTclInterp; const cmd: AnsiString): AnsiString;

implementation

{ Tcl_FindExecutable(NULL) is required by Tcl >= 8.5 before *any* interp
  operation; it initialises the static encoding tables.  Without it the
  first Tcl_CreateInterp returns nil.  See tclsqlite.c:4581. }
procedure InitTclLibrary;
begin
  Tcl_FindExecutable(nil);
end;

procedure Tcl_IncrRefCount(objPtr: PTclObj); inline;
begin
  Tcl_DbIncrRefCount(objPtr, 'PasTclBridge', 0);
end;

procedure Tcl_DecrRefCount(objPtr: PTclObj); inline;
begin
  Tcl_DbDecrRefCount(objPtr, 'PasTclBridge', 0);
end;

{ Eval `cmd` and read back the current obj-result as a Pascal AnsiString.
  Returns the result regardless of rc — caller checks rc separately if it
  matters; for the smoke gate, success is sufficient. }
function TclEvalGetString(interp: PTclInterp; const cmd: AnsiString): AnsiString;
var
  rc: cint;
  zRes: PChar;
begin
  rc := Tcl_Eval(interp, PChar(cmd));
  zRes := Tcl_GetStringFromObj(Tcl_GetObjResult(interp), nil);
  if zRes = nil then
    Result := ''
  else
    Result := zRes;
  if rc <> TCL_OK then
    { Leave Result populated with the error message Tcl produced. } ;
end;

end.
