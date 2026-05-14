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

uses SysUtils, passqlite3types, passqlite3util, passqlite3main, passqlite3vdbe;

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
function DbEvalArm(clientData: TClientData; interp: PTclInterp;
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
  { Free zNull buffer if any — owned by us, see DbNullValueArm.  Pairs
    with the GetMem in the nullvalue setter (9.4.2.e). }
  if pDb^.zNull <> nil then
  begin
    FreeMem(pDb^.zNull);
    pDb^.zNull := nil;
  end;
  Dispose(pDb);
end;

{ DbEvalArm — minimum port of the "eval" arm of DbObjCmd
  (tclsqlite.c ~2700..2820) plus the row-stepper loop body from
  dbEvalStep (tclsqlite.c:1766..1823).

  Contract: objc>=3, objv[2]=SQL text.  All rows in all statements
  contained in the SQL text are appended (column by column) onto a
  freshly built Tcl list, which becomes the interp's obj-result on
  success.  On any SQLITE error we set the interp result to
  sqlite3_errmsg() and return TCL_ERROR.

  NULL column policy mirrors dbEvalColumnValue (tclsqlite.c:1871):
  Tcl_NewStringObj(zNull, -1).  We pass an empty C string when
  pDb^.zNull is nil (i.e. before any `db nullvalue ...` call); the
  nullvalue subcommand lands in 9.4.2.e. }
function DbEvalArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:        PSqliteDb;
  zSql:       PAnsiChar;
  zTail:      PAnsiChar;
  pStmt:      Pointer;
  rc:         i32;
  rcStep:     i32;
  i, nCol:    cint;
  pList:      PTclObj;
  pCol:       PTclObj;
  zVal:       PAnsiChar;
  zNullStr:   PAnsiChar;
  emptyNull:  array[0..0] of AnsiChar;
begin
  if objc < 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('SQL ?ARRAY-NAME? ?SCRIPT?'));
    Result := TCL_ERROR;
    Exit;
  end;

  pDb  := PSqliteDb(clientData);
  zSql := Tcl_GetStringFromObj(ObjvAt(objv, 2), nil);
  if zSql = nil then
  begin
    Result := TCL_OK;
    Exit;
  end;

  emptyNull[0] := #0;
  if pDb^.zNull <> nil then
    zNullStr := pDb^.zNull
  else
    zNullStr := @emptyNull[0];

  pList := Tcl_NewListObj(0, nil);
  Tcl_IncrRefCount(pList);

  { Outer loop: walk through zSql, one prepared statement per
    sqlite3_prepare_v2 call, advancing via pzTail.  Mirrors the
    `while (p->zSql[0] || p->pPreStmt)` loop of dbEvalStep:1769. }
  while (zSql <> nil) and (zSql^ <> #0) do
  begin
    pStmt := nil;
    zTail := nil;
    rc := sqlite3_prepare_v2(pDb^.db, zSql, -1, @pStmt, @zTail);
    if rc <> SQLITE_OK then
    begin
      Tcl_DecrRefCount(pList);
      Tcl_AppendResult(interp, sqlite3_errmsg(pDb^.db), Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;

    if pStmt = nil then
    begin
      { Trailing whitespace / comment — no statement compiled. }
      zSql := zTail;
      continue;
    end;

    nCol := sqlite3_column_count(pStmt);

    repeat
      rcStep := sqlite3_step(pStmt);
      if rcStep = SQLITE_ROW then
      begin
        for i := 0 to nCol - 1 do
        begin
          zVal := sqlite3_column_text(pStmt, i);
          if zVal = nil then
            pCol := Tcl_NewStringObj(zNullStr, -1)
          else
            pCol := Tcl_NewStringObj(zVal, -1);
          Tcl_ListObjAppendElement(interp, pList, pCol);
        end;
      end;
    until rcStep <> SQLITE_ROW;

    sqlite3_finalize(pStmt);

    if (rcStep <> SQLITE_DONE) and (rcStep <> SQLITE_OK) then
    begin
      Tcl_DecrRefCount(pList);
      Tcl_AppendResult(interp, sqlite3_errmsg(pDb^.db), Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;

    zSql := zTail;
  end;

  Tcl_SetObjResult(interp, pList);
  Tcl_DecrRefCount(pList);
  Result := TCL_OK;
end;

{ DbNullValueArm — port of the "nullvalue" arm of DbObjCmd
  (tclsqlite.c:3524..3545).  2-arg form is a getter (returns current
  pDb^.zNull as a string, "" if nil).  3-arg form is a setter: free
  old buffer if any, copy objv[2] verbatim into a freshly GetMem'd
  PAnsiChar.  Tcl owns the objv string so we must copy.

  Memory rule: GetMem here matches FreeMem in DbDeleteCmd above. }
function DbNullValueArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:  PSqliteDb;
  zArg: PAnsiChar;
  nArg: cint;
begin
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('NULLVALUE'));
    Result := TCL_ERROR;
    Exit;
  end;
  pDb := PSqliteDb(clientData);
  if objc = 3 then
  begin
    nArg := 0;
    zArg := Tcl_GetStringFromObj(ObjvAt(objv, 2), @nArg);
    if pDb^.zNull <> nil then
    begin
      FreeMem(pDb^.zNull);
      pDb^.zNull := nil;
    end;
    if (zArg <> nil) and (nArg > 0) then
    begin
      GetMem(pDb^.zNull, nArg + 1);
      Move(zArg^, pDb^.zNull^, nArg);
      pDb^.zNull[nArg] := #0;
    end;
  end;
  Tcl_SetObjResult(interp, Tcl_NewStringObj(pDb^.zNull, -1));
  Result := TCL_OK;
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

  { eval — tclsqlite.c "eval" arm of DbObjCmd (~2700..2820, dispatch
    table at :2445).  This is a straight-line minimum port of
    dbEvalStep (tclsqlite.c:1766..1823): we drive
    sqlite3_prepare_v2 / sqlite3_step / sqlite3_finalize in-line and
    accumulate a flat Tcl list of column values.

    KNOWN DIVERGENCE from upstream's dbEvalColumnValue
    (tclsqlite.c:1850..1876): every column is stringified through
    sqlite3_column_text (UTF-8) and wrapped with Tcl_NewStringObj.
    Upstream returns typed Tcl_Obj (Int / WideInt / Double /
    ByteArray) per sqlite3_column_type.  Cite the Pascal feedback
    feedback_result_text_change_encoding.md re: text encoding —
    sqlite3_column_text always renders UTF-8, so Tcl_NewStringObj is
    safe here.  Typed-Obj marshalling lands as a follow-up (9.4.2.d.1
    if/when a .test file demands it; `puts [db eval ...]` stringifies
    anyway so the divergence is invisible to ~99% of tester.tcl
    call sites).

    Also deferred vs upstream:
      * 4-arg form `db eval sql arrayName script` — would require a
        sub-interpreter eval per row;
      * `$var` substitution in SQL (dbPrepareAndBind);
      * the prepared-statement cache (SqlPreparedStmt);
      * DbEvalContext / NRE machinery;
      * busy-handler retries on SQLITE_SCHEMA. }
  if (zSub <> nil) and (StrComp(zSub, 'eval') = 0) then
  begin
    Result := DbEvalArm(clientData, interp, objc, objv);
    Exit;
  end;

  { version — tclsqlite.c:4161. }
  if (zSub <> nil) and (StrComp(zSub, 'version') = 0) then
  begin
    Tcl_AppendResult(interp, sqlite3_libversion(), Pointer(nil));
    Result := TCL_OK;
    Exit;
  end;

  { changes — tclsqlite.c:2728.  We use sqlite3_changes64 (i64). }
  if (zSub <> nil) and (StrComp(zSub, 'changes') = 0) then
  begin
    Tcl_SetObjResult(interp,
      Tcl_NewWideIntObj(sqlite3_changes64(PSqliteDb(clientData)^.db)));
    Result := TCL_OK;
    Exit;
  end;

  { last_insert_rowid — tclsqlite.c:3552. }
  if (zSub <> nil) and (StrComp(zSub, 'last_insert_rowid') = 0) then
  begin
    Tcl_SetObjResult(interp,
      Tcl_NewWideIntObj(sqlite3_last_insert_rowid(PSqliteDb(clientData)^.db)));
    Result := TCL_OK;
    Exit;
  end;

  { errorcode — tclsqlite.c:3236. }
  if (zSub <> nil) and (StrComp(zSub, 'errorcode') = 0) then
  begin
    Tcl_SetObjResult(interp,
      Tcl_NewIntObj(sqlite3_errcode(PSqliteDb(clientData)^.db)));
    Result := TCL_OK;
    Exit;
  end;

  { nullvalue — tclsqlite.c:3524.  Mutates pDb^.zNull. }
  if (zSub <> nil) and (StrComp(zSub, 'nullvalue') = 0) then
  begin
    Result := DbNullValueArm(clientData, interp, objc, objv);
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
