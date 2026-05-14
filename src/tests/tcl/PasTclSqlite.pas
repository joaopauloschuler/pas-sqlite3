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
  PSqlFunc = ^TSqlFunc;
  PSqliteDb = ^TSqliteDb;

  { Per-UDF state.  Pas analogue of struct SqlFunc in tclsqlite.c:148..
    Only pointer-typed fields, so New/Dispose is safe (no managed
    AnsiString — see memory feedback_new_record_ansistring). }
  TSqlFunc = record
    pDb:      PSqliteDb;   { back-pointer for zNull/interp access (tclsqlite.c:154) }
    interp:   PTclInterp;  { tclsqlite.c:150 — the Tcl interp to eval into }
    pScript:  PTclObj;     { tclsqlite.c:151 — the user-supplied Tcl script,
                             refcount-incremented for our duration }
    pNext:    PSqlFunc;    { tclsqlite.c:156 — next on the per-db chain }
  end;

  { Per-connection state.  Pas analogue of struct SqliteDb in
    tclsqlite.c:215..  Only the fields needed by 9.4.2.c..f are present;
    later sub-tasks will extend (stmt cache, hooks). }
  TSqliteDb = record
    db:     PTsqlite3;     { tclsqlite.c:216  — the sqlite3* handle }
    interp: PTclInterp;    { tclsqlite.c:217  — owning Tcl interp   }
    zNull:  PAnsiChar;     { tclsqlite.c:230  — placeholder for NULL,
                             populated by the `nullvalue` subcmd in
                             9.4.2.e; held as raw PChar so this record
                             has no managed fields (no AnsiString,
                             see memory feedback_new_record_ansistring) }
    pFunc:  PSqlFunc;      { tclsqlite.c:209  — head of TSqlFunc chain,
                             populated by the `function` subcmd in
                             9.4.2.f.  Freed in DbDeleteCmd. }
  end;

{ Forward decl: DbMain hands DbObjCmdAdaptor to Tcl_CreateObjCommand. }
function DbObjCmdAdaptor(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl; forward;
function DbEvalArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl; forward;
procedure DbDeleteCmd(clientData: TClientData); cdecl; forward;
procedure DbSqlFunc(pCtx: Psqlite3_context; argc: cint;
  argv: PPointer); cdecl; forward;
procedure DbSqlFuncDelete(pUser: Pointer); cdecl; forward;

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
  { sqlite3_close_v2 fires our DbSqlFuncDelete xDestroy hook for every
    TSqlFunc previously registered via sqlite3_create_function_v2, which
    decrefs pScript and Disposes each chain entry.  After this call the
    pFunc list is fully dangling, so we just nil the head.  Compare
    tclsqlite.c:617..630 where the equivalent C path walks p->pFunc
    explicitly because the C build uses _create_function (no _v2) and
    therefore needs manual teardown; we have _v2 and lean on it. }
  if pDb^.db <> nil then
    sqlite3_close_v2(pDb^.db);
  pDb^.pFunc := nil;
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
      { 9.4.divbug.6: mirror upstream tclsqlite.c:1812 — SET the interp result
        from sqlite3_errmsg, do not Append.  The UDF trampoline may have
        already pushed an error string (sqlite3_result_error), and AppendResult
        on top of that doubled the text ("boomboom"). }
      Tcl_SetObjResult(interp,
        Tcl_NewStringObj(sqlite3_errmsg(pDb^.db), -1));
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
      { 9.4.divbug.6: see comment above — must SET, not Append, so a UDF
        error already on the interp result is not duplicated. }
      Tcl_SetObjResult(interp,
        Tcl_NewStringObj(sqlite3_errmsg(pDb^.db), -1));
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

{ DbSqlFunc — sqlite3 xFunc trampoline.  Pas port of tclSqlFunc
  (tclsqlite.c:1015..1166), collapsed to the minimum the smoke gate
  needs.  Strategy:
    * argc==0 path: Tcl_EvalObjEx on pScript directly (matches
      C:1021..1029; this is the bytecode-cache fast path).
    * argc>0  path: build a fresh PPTclObj buffer of length argc+1,
      where slot 0 is pScript and slots 1..argc are per-arg Tcl_Obj
      built per sqlite3_value_type (mirrors C:1053..1082, condensed
      to int64/double/text branches; blob/null fall through to
      stringify-via-text for the minimum port).  Then Tcl_EvalObjv.
    * On TCL_OK the obj-result is routed to sqlite3_result_text via
      SQLITE_TRANSIENT (sqlite takes a copy).
    * On TCL_ERROR the obj-result string is routed to
      sqlite3_result_error.
    * TCL_BREAK -> sqlite3_result_null (matches C:1100..1101).
  Divergence from upstream: we do NOT do type-detection of the result
  (eType heuristic at tclsqlite.c:1108..1140); everything comes back
  as text and SQLite's normal affinity rules apply.  The smoke gate
  exercises both numeric and text round-trips and Tcl's autocoercion
  on the input side makes that sufficient. }
procedure DbSqlFunc(pCtx: Psqlite3_context; argc: cint;
  argv: PPointer); cdecl;
var
  pFn:    PSqlFunc;
  rc:     cint;
  i:      cint;
  pVal:   Psqlite3_value;
  pArg:   PTclObj;
  pRes:   PTclObj;
  zRes:   PAnsiChar;
  nRes:   cint;
  zErr:   PAnsiChar;
  pIn:    PPointer;
  vType:  i32;
  zText:  PAnsiChar;
  nText:  cint;
  objv:   PPTclObj;
  objc:   cint;
begin
  pFn := PSqlFunc(sqlite3_user_data(pCtx));
  if pFn = nil then
  begin
    sqlite3_result_error(pCtx, PAnsiChar('DbSqlFunc: nil user_data'), -1);
    Exit;
  end;

  if argc = 0 then
  begin
    { Fast path — no shallow-list-copy work needed. }
    Tcl_IncrRefCount(pFn^.pScript);
    rc := Tcl_EvalObjEx(pFn^.interp, pFn^.pScript, 0);
    Tcl_DecrRefCount(pFn^.pScript);
  end
  else
  begin
    { Build objv = [pScript, arg0, arg1, ...].  Use heap so we don't
      blow a Pascal stack-array bound; free unconditionally below. }
    objc := argc + 1;
    GetMem(objv, objc * SizeOf(PTclObj));
    objv[0] := pFn^.pScript;
    Tcl_IncrRefCount(pFn^.pScript);

    pIn := argv;
    for i := 0 to argc - 1 do
    begin
      pVal := Psqlite3_value(pIn^);
      vType := sqlite3_value_type(pVal);
      case vType of
        SQLITE_INTEGER:
          pArg := Tcl_NewWideIntObj(sqlite3_value_int64(pVal));
        SQLITE_FLOAT:
          pArg := Tcl_NewDoubleObj(sqlite3_value_double(pVal));
        SQLITE_NULL:
          begin
            if pFn^.pDb^.zNull <> nil then
              pArg := Tcl_NewStringObj(pFn^.pDb^.zNull, -1)
            else
              pArg := Tcl_NewStringObj(PAnsiChar(''), 0);
          end;
        else
          begin
            zText := PAnsiChar(sqlite3_value_text(pVal));
            nText := sqlite3_value_bytes(pVal);
            if zText = nil then
              pArg := Tcl_NewStringObj(PAnsiChar(''), 0)
            else
              pArg := Tcl_NewStringObj(zText, nText);
          end;
      end;
      Tcl_IncrRefCount(pArg);
      objv[i + 1] := pArg;
      pIn := PPointer(PtrUInt(pIn) + SizeOf(Pointer));
    end;

    rc := Tcl_EvalObjv(pFn^.interp, objc, objv, 0);

    { Decref the arg Tcl_Objs we created (slot 0 = pScript). }
    Tcl_DecrRefCount(pFn^.pScript);
    for i := 1 to objc - 1 do
      Tcl_DecrRefCount(objv[i]);
    FreeMem(objv);
  end;

  { Result routing — see C:1100..1147 minus the type-detection arm. }
  if rc = TCL_BREAK then
  begin
    sqlite3_result_null(pCtx);
  end
  else if (rc <> TCL_OK) and (rc <> TCL_RETURN) then
  begin
    zErr := Tcl_GetStringResult(pFn^.interp);
    if zErr = nil then zErr := PAnsiChar('Tcl error');
    sqlite3_result_error(pCtx, zErr, -1);
  end
  else
  begin
    pRes := Tcl_GetObjResult(pFn^.interp);
    nRes := 0;
    zRes := Tcl_GetStringFromObj(pRes, @nRes);
    if zRes = nil then
      sqlite3_result_null(pCtx)
    else
      sqlite3_result_text(pCtx, zRes, nRes, SQLITE_TRANSIENT);
  end;
end;

{ DbSqlFuncDelete — sqlite3_create_function_v2 xDestroy hook.  Fired
  on db close, on _create_function_v2 re-registration with the same
  name, and on explicit sqlite3_close_v2.  Mirrors the per-entry
  teardown in C's pDb->pFunc walker at tclsqlite.c:617..630. }
procedure DbSqlFuncDelete(pUser: Pointer); cdecl;
var
  pFn: PSqlFunc;
begin
  pFn := PSqlFunc(pUser);
  if pFn = nil then Exit;
  if pFn^.pScript <> nil then
  begin
    Tcl_DecrRefCount(pFn^.pScript);
    pFn^.pScript := nil;
  end;
  Dispose(pFn);
end;

{ DbFunctionArm — port of the `function` arm of DbObjCmd
  (tclsqlite.c:3386..3469).  Minimum surface: parse `NAME ?-argcount N?
  ?-deterministic? SCRIPT`.  Other flags (-directonly / -innocuous /
  -returntype) are unimplemented and rejected with "bad option".

  Reuse policy: unlike upstream's findSqlFunc (tclsqlite.c:548) which
  reuses an existing TSqlFunc on re-register, we always allocate a
  fresh one.  sqlite3_create_function_v2 will fire xDestroy on the
  *previously* registered TSqlFunc for the same name+nArg, which
  decrefs its pScript and Disposes it — net effect identical for
  the smoke gate. }
function DbFunctionArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:     PSqliteDb;
  pFn:     PSqlFunc;
  zName:   PAnsiChar;
  z:       PAnsiChar;
  nA:      cint;
  nArg:    cint;
  flags:   cint;
  i:       cint;
  rc:      i32;
  pScript: PTclObj;
begin
  if objc < 4 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('NAME ?SWITCHES? SCRIPT'));
    Result := TCL_ERROR;
    Exit;
  end;
  pDb   := PSqliteDb(clientData);
  nArg  := -1;
  flags := SQLITE_UTF8;

  { Flag loop runs over objv[3 .. objc-2]; objv[objc-1] is the script. }
  i := 3;
  while i < (objc - 1) do
  begin
    z := Tcl_GetStringFromObj(ObjvAt(objv, i), nil);
    if (z <> nil) and (StrComp(z, PAnsiChar('-argcount')) = 0) then
    begin
      if i = (objc - 2) then
      begin
        Tcl_AppendResult(interp,
          PChar('option requires an argument: '), z, Pointer(nil));
        Result := TCL_ERROR;
        Exit;
      end;
      nA := 0;
      if Tcl_GetIntFromObj(interp, ObjvAt(objv, i + 1), @nA) <> TCL_OK then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
      if nA < 0 then
      begin
        Tcl_AppendResult(interp,
          PChar('number of arguments must be non-negative'),
          Pointer(nil));
        Result := TCL_ERROR;
        Exit;
      end;
      nArg := nA;
      Inc(i, 2);
    end
    else if (z <> nil) and (StrComp(z, PAnsiChar('-deterministic')) = 0) then
    begin
      flags := flags or SQLITE_DETERMINISTIC;
      Inc(i);
    end
    else
    begin
      Tcl_AppendResult(interp,
        PChar('bad option "'), z,
        PChar('": must be -argcount or -deterministic'),
        Pointer(nil));
      Result := TCL_ERROR;
      Exit;
    end;
  end;

  zName   := Tcl_GetStringFromObj(ObjvAt(objv, 2), nil);
  pScript := ObjvAt(objv, objc - 1);

  { Allocate fresh TSqlFunc, chain it onto pDb^.pFunc.  Note: New()
    is safe — TSqlFunc has no managed fields (see
    feedback_new_record_ansistring). }
  New(pFn);
  pFn^.pDb     := pDb;
  pFn^.interp  := interp;
  pFn^.pScript := pScript;
  Tcl_IncrRefCount(pScript);
  pFn^.pNext   := pDb^.pFunc;
  pDb^.pFunc   := pFn;

  rc := sqlite3_create_function_v2(pDb^.db, zName, nArg, flags,
                                   Pointer(pFn), @DbSqlFunc, nil, nil,
                                   @DbSqlFuncDelete);
  if rc <> SQLITE_OK then
  begin
    { create_function_v2 invokes xDestroy itself on failure, per
      sqlite3.h:5572 — so pFn is already gone.  Unlink the head we
      just set; the previous head is still valid. }
    pDb^.pFunc := pFn^.pNext;
    Tcl_AppendResult(interp,
      PAnsiChar(sqlite3_errmsg(pDb^.db)), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
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

  { function — tclsqlite.c:3386 (DB_FUNCTION).  Scalar UDF registration
    via sqlite3_create_function_v2; Tcl trampoline is DbSqlFunc. }
  if (zSub <> nil) and (StrComp(zSub, 'function') = 0) then
  begin
    Result := DbFunctionArm(clientData, interp, objc, objv);
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
  pDb^.pFunc  := nil;

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
