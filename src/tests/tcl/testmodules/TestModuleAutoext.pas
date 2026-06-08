{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/src/test_autoext.c (221 lines) — the test
  module for sqlite3_auto_extension() / sqlite3_cancel_auto_extension() /
  sqlite3_reset_auto_extension() (loadext2.test).

  Defines three loadable extensions:
    * sqr_init    — registers the sqr()  SQL function (square of arg)
    * cube_init   — registers the cube() SQL function (cube of arg)
    * broken_init — a deliberately-failing entry point

  and the Tcl commands wrapping them:
    sqlite3_auto_extension_sqr / _cube / _broken
    sqlite3_cancel_auto_extension_sqr / _cube / _broken
    sqlite3_reset_auto_extension

  Public entry: Sqlitetest_autoext_Init(interp).

  NOTE: TestModuleTest1 carries a *partial* copy of this module (only the
  sqlite3_auto_extension_sqr + sqlite3_reset_auto_extension commands, used by
  mutex2-2.5) backed by its own private sqr_init.  Because loadext2.test pairs
  register/cancel by pointer identity (loadext.c), this complete module's Init
  must run AFTER Sqlitetest1_Init so that *both* the register and the cancel
  commands resolve to this module's sqr_init — see PasTclSqlite.pas.

  C ref: test_autoext.c.
}
{$I passqlite3.inc}
unit TestModuleAutoext;

interface

uses
  ctypes,
  PasTclBridge,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function Sqlitetest_autoext_Init(interp: PTclInterp): cint; cdecl;

implementation

{ Stable function-pointer thunks for the three extension entry points, cast
  once (in the initialization section) to the bare Tsqlite3_loadext_fn shape
  that sqlite3_auto_extension / _cancel_auto_extension expect.  Taking @x at a
  single site guarantees both the register and cancel calls compare the *same*
  address (loadext.c identifies extensions by pointer identity). }
var
  pSqrInit    : Tsqlite3_loadext_fn;
  pCubeInit   : Tsqlite3_loadext_fn;
  pBrokenInit : Tsqlite3_loadext_fn;

{ test_autoext.c:23..30 — the sqr() SQL function returns the square. }
procedure sqrFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pArg: PPsqlite3_value;
  r:    Double;
begin
  pArg := argv;
  r := sqlite3_value_double(pArg[0]);
  sqlite3_result_double(context, r * r);
end;

{ test_autoext.c:35..43 — entry point registering sqr(). }
function sqr_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  sqlite3_create_function(db, 'sqr', 1, SQLITE_ANY, nil,
    @sqrFunc, nil, nil);
  Result := 0;
end;

{ test_autoext.c:48..55 — the cube() SQL function returns the cube. }
procedure cubeFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pArg: PPsqlite3_value;
  r:    Double;
begin
  pArg := argv;
  r := sqlite3_value_double(pArg[0]);
  sqlite3_result_double(context, r * r * r);
end;

{ test_autoext.c:60..68 — entry point registering cube(). }
function cube_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  sqlite3_create_function(db, 'cube', 1, SQLITE_ANY, nil,
    @cubeFunc, nil, nil);
  Result := 0;
end;

{ test_autoext.c:73..83 — a broken extension entry point. }
function broken_init(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pApi: Pointer): cint; cdecl;
begin
  pzErrMsg^ := sqlite3_mprintf('broken autoext!');
  Result := 1;
end;

{ test_autoext.c:90..99 — sqlite3_auto_extension_sqr. }
function autoExtSqrObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
begin
  rc := sqlite3_auto_extension(pSqrInit);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test_autoext.c:106..115 — sqlite3_cancel_auto_extension_sqr. }
function cancelAutoExtSqrObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
begin
  rc := sqlite3_cancel_auto_extension(pSqrInit);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test_autoext.c:122..131 — sqlite3_auto_extension_cube. }
function autoExtCubeObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
begin
  rc := sqlite3_auto_extension(pCubeInit);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test_autoext.c:138..147 — sqlite3_cancel_auto_extension_cube. }
function cancelAutoExtCubeObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
begin
  rc := sqlite3_cancel_auto_extension(pCubeInit);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test_autoext.c:154..163 — sqlite3_auto_extension_broken. }
function autoExtBrokenObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
begin
  rc := sqlite3_auto_extension(pBrokenInit);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test_autoext.c:170..179 — sqlite3_cancel_auto_extension_broken. }
function cancelAutoExtBrokenObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  rc: cint;
begin
  rc := sqlite3_cancel_auto_extension(pBrokenInit);
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  Result := TCL_OK;
end;

{ test_autoext.c:189..197 — sqlite3_reset_auto_extension. }
function resetAutoExtObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  sqlite3_reset_auto_extension();
  Result := TCL_OK;
end;

{ test_autoext.c:203..221 — Sqlitetest_autoext_Init. }
function Sqlitetest_autoext_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('sqlite3_auto_extension_sqr'),
    @autoExtSqrObjCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_auto_extension_cube'),
    @autoExtCubeObjCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_auto_extension_broken'),
    @autoExtBrokenObjCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_cancel_auto_extension_sqr'),
    @cancelAutoExtSqrObjCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_cancel_auto_extension_cube'),
    @cancelAutoExtCubeObjCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_cancel_auto_extension_broken'),
    @cancelAutoExtBrokenObjCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_reset_auto_extension'),
    @resetAutoExtObjCmd, nil, nil);
  Result := TCL_OK;
end;

initialization
  pSqrInit    := Tsqlite3_loadext_fn(@sqr_init);
  pCubeInit   := Tsqlite3_loadext_fn(@cube_init);
  pBrokenInit := Tsqlite3_loadext_fn(@broken_init);

end.
