unit PasTclSqlite;

{
  PasTclSqlite — Pascal port of the Sqlite3_Init exporter and the
  minimal DbMain/DbObjCmd surface from
  /home/bpsa/app/sqlite3/src/tclsqlite.c.

  Phase 9.4.2.c deliverable: `sqlite3 db1 :memory:` actually opens an
  in-memory connection (sqlite3_open_v2), registers a per-connection
  Tcl obj-cmd, and `db1 close` tears it down via DbDeleteCmd.

  Subcommands other than "close" return TCL_ERROR with
  "unknown subcommand" — `eval`/`version`/`function`/etc. land in
  9.4.2.d..f.

  Memory rule for SqliteDb: the record only carries pointer fields
  (db, zNull is PAnsiChar — pointer, not managed AnsiString) so
  New/Dispose is safe; see memory feedback_new_record_ansistring for
  the AnsiString trap we are deliberately avoiding.
}

{$mode objfpc}{$H+}

interface

uses ctypes, PasTclBridge;

function Sqlite3_Init(interp: PTclInterp): cint; cdecl;
function Sqlite3_SafeInit(interp: PTclInterp): cint; cdecl;

implementation

uses SysUtils, passqlite3types, passqlite3util, passqlite3main;

type
  { Per-connection state.  Pas analogue of struct SqliteDb in
    tclsqlite.c:215..  Only the fields needed by 9.4.2.c are present;
    9.4.2.d..f will extend (interp back-pointer, stmt cache, hooks). }
  PSqliteDb = ^TSqliteDb;
  TSqliteDb = record
    db:     PTsqlite3;     { tclsqlite.c:216  — the sqlite3* handle }
    interp: PTclInterp;    { tclsqlite.c:217  — owning Tcl interp   }
    zNull:  PAnsiChar;     { tclsqlite.c:230  — placeholder for NULL,
                             populated by the `nullvalue` subcmd in
                             9.4.2.e; held as raw PChar so this record
                             has no managed fields (no AnsiString,
                             see memory feedback_new_record_ansistring) }
  end;

{ Forward decl: DbMain hands DbObjCmdAdaptor to Tcl_CreateObjCommand. }
function DbObjCmdAdaptor(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl; forward;
procedure DbDeleteCmd(clientData: TClientData); cdecl; forward;

{ Pointer-arithmetic helper: objv is a flat `Tcl_Obj* const* `; treat
  it as a base pointer + index*sizeof(pointer).  Equivalent to objv[i]
  in C. }
function ObjvAt(objv: PPTclObj; i: cint): PTclObj; inline;
begin
  Result := (PPTclObj(PtrUInt(objv) + PtrUInt(i) * SizeOf(Pointer)))^;
end;

{ DbDeleteCmd — Tcl_CmdDeleteProc invoked when the per-connection
  command is destroyed (either via `db1 close` -> Tcl_DeleteCommand,
  or via `rename db1 ""`).  Tears the SqliteDb down.

  Mirrors tclsqlite.c:670 (DbDeleteCmd) → delDatabaseRef → sqlite3_close
  path, collapsed because we have no refcount or hook state yet. }
procedure DbDeleteCmd(clientData: TClientData); cdecl;
var
  pDb: PSqliteDb;
begin
  pDb := PSqliteDb(clientData);
  if pDb = nil then Exit;
  if pDb^.db <> nil then
    sqlite3_close_v2(pDb^.db);
  Dispose(pDb);
end;

{ DbObjCmdAdaptor — the per-connection dispatcher.  In 9.4.2.c only
  the "close" arm is wired; everything else returns TCL_ERROR with
  a stable "unknown subcommand" string so callers can grep it. }
function DbObjCmdAdaptor(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  zSub:  PAnsiChar;
  zSelf: PAnsiChar;
begin
  if objc < 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SUBCOMMAND ...'));
    Result := TCL_ERROR;
    Exit;
  end;

  zSub := Tcl_GetStringFromObj(ObjvAt(objv, 1), nil);

  { close — tclsqlite.c:2743. }
  if (zSub <> nil) and (StrComp(zSub, 'close') = 0) then
  begin
    zSelf := Tcl_GetStringFromObj(ObjvAt(objv, 0), nil);
    Tcl_DeleteCommand(interp, zSelf);
    Result := TCL_OK;
    Exit;
  end;

  Tcl_AppendResult(interp,
    PChar('unknown subcommand "'),
    zSub,
    PChar('" - implemented in 9.4.2.d..f'),
    Pointer(nil));
  Result := TCL_ERROR;
end;

{ DbMain — constructor for the `sqlite3 db1 FILE` Tcl command.
  Minimal port of tclsqlite.c:4253..4570: skips flag parsing, key
  options, busy/encoding setup; just defaults RW+CREATE which is the
  documented behaviour for `:memory:`.

  objv[0]="sqlite3", objv[1]=dbname (e.g. "db1"), objv[2]=zFile. }
function DbMain(clientData: TClientData; interp: PTclInterp;
                objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:     PSqliteDb;
  zDbName: PAnsiChar;
  zFile:   PAnsiChar;
  rc:      cint;
  pHandle: PTsqlite3;
begin
  if objc < 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('HANDLE FILENAME ?OPTIONS?'));
    Result := TCL_ERROR;
    Exit;
  end;

  zDbName := Tcl_GetStringFromObj(ObjvAt(objv, 1), nil);
  zFile   := Tcl_GetStringFromObj(ObjvAt(objv, 2), nil);

  pHandle := nil;
  rc := sqlite3_open_v2(zFile, @pHandle,
                        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE,
                        nil);
  if rc <> SQLITE_OK then
  begin
    if pHandle <> nil then
      sqlite3_close_v2(pHandle);
    Tcl_AppendResult(interp,
      PChar('sqlite3_open_v2 failed'),
      Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;

  { New() is safe here because TSqliteDb has no managed-type fields
    (zNull is a raw PAnsiChar, not an AnsiString).  See memory
    feedback_new_record_ansistring for the trap to avoid. }
  New(pDb);
  pDb^.db     := pHandle;
  pDb^.interp := interp;
  pDb^.zNull  := nil;

  Tcl_CreateObjCommand(interp, zDbName,
    @DbObjCmdAdaptor, TClientData(pDb), @DbDeleteCmd);

  Result := TCL_OK;
end;

function Sqlite3_Init(interp: PTclInterp): cint; cdecl;
var
  rc: cint;
begin
  Tcl_CreateObjCommand(interp, PChar('sqlite3'),
    @DbMain, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite'),
    @DbMain, nil, nil);
  rc := Tcl_PkgProvide(interp, PChar('sqlite3'), PChar(SQLITE_VERSION));
  Result := rc;
end;

function Sqlite3_SafeInit(interp: PTclInterp): cint; cdecl;
begin
  Result := TCL_ERROR;
end;

end.
