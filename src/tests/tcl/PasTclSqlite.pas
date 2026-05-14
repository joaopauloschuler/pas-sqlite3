unit PasTclSqlite;

{
  PasTclSqlite — Pascal port of the Sqlite3_Init exporter from
  /home/bpsa/app/sqlite3/src/tclsqlite.c:4442..4486.

  Phase 9.4.2.b deliverable.  This unit is the *constructor* half of the
  Tcl `load` contract: when `tclsh` evaluates
      load /path/to/libpassqlite3tcl.so Sqlite3
  Tcl resolves the symbol `Sqlite3_Init` via dlsym() and calls it.  We
  register a stub `DbMain` ObjCmd under the names "sqlite3" and "sqlite",
  then advertise the package via Tcl_PkgProvide.

  The real DbMain (constructor that opens a database and installs the
  per-connection ObjCmd dispatcher) lands in 9.4.2.c..f.  For now DbMain
  emits "sqlite3 cmd not implemented yet" via Tcl_AppendResult and
  returns TCL_ERROR — exactly the surface needed to gate `package
  require sqlite3`, which only checks that Sqlite3_Init returned TCL_OK.

  We deliberately skip Tcl_InitStubs (tclsqlite.c:4443): the upstream
  code uses Tcl's stubs table so a single binary works against any
  8.5+ libtcl ABI.  We link directly against libtcl8.6 at FPC time, so
  the stubs detour is pointless and would also drag in libtclstub8.6.a.
}

{$mode objfpc}{$H+}

interface

uses ctypes, PasTclBridge;

function Sqlite3_Init(interp: PTclInterp): cint; cdecl;
function Sqlite3_SafeInit(interp: PTclInterp): cint; cdecl;

implementation

uses passqlite3types;

{ Stub DbMain — placeholder for the real constructor that lands in
  9.4.2.c..f.  Mirrors the no-op surface of upstream just enough to
  prove Sqlite3_Init wired the command correctly: invoking `sqlite3 db
  :memory:` from Tcl returns a clean error rather than crashing.

  Pas memory rule applied: no `pInterp` var-shadow of the param. }
function DbMain(clientData: TClientData; interp: PTclInterp;
                objc: cint; objv: PPTclObj): cint; cdecl;
begin
  Tcl_AppendResult(interp,
    PChar('sqlite3 cmd not implemented yet'),
    Pointer(nil));
  Result := TCL_ERROR;
end;

function Sqlite3_Init(interp: PTclInterp): cint; cdecl;
var
  rc: cint;
begin
  { tclsqlite.c:4445 — register the primary "sqlite3" command. }
  Tcl_CreateObjCommand(interp, PChar('sqlite3'),
    @DbMain, nil, nil);
  { tclsqlite.c:4450 — undocumented legacy "sqlite" alias. }
  Tcl_CreateObjCommand(interp, PChar('sqlite'),
    @DbMain, nil, nil);
  { tclsqlite.c:4452 — advertise the package version so
    `package require sqlite3` succeeds. }
  rc := Tcl_PkgProvide(interp, PChar('sqlite3'), PChar(SQLITE_VERSION));
  Result := rc;
end;

{ tclsqlite.c:4464 — SafeInit is intentionally rejected for SQLite. }
function Sqlite3_SafeInit(interp: PTclInterp): cint; cdecl;
begin
  Result := TCL_ERROR;
end;

end.
