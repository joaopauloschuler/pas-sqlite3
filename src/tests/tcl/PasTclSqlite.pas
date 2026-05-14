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

uses SysUtils, passqlite3types, passqlite3util, passqlite3main, passqlite3vdbe,
     passqlite3codegen;

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
    zTrace:   PAnsiChar;   { tclsqlite.c:201 — `trace` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
    zTraceV2: PAnsiChar;   { tclsqlite.c:202 — `trace_v2` callback script. }
    zProfile: PAnsiChar;   { tclsqlite.c:203 — `profile` callback script. }
    zAuth:    PAnsiChar;   { tclsqlite.c:206 — `authorizer` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
    zBusy:    PAnsiChar;   { tclsqlite.c:199 — `busy` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
    zProgress: PAnsiChar;  { tclsqlite.c:204 — `progress` callback script,
                             Tcl_Alloc'd; freed in DbDeleteCmd. }
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
  { Free trace/profile callback scripts — tclsqlite.c:631..639. }
  if pDb^.zTrace <> nil then
  begin
    Tcl_Free(pDb^.zTrace);
    pDb^.zTrace := nil;
  end;
  if pDb^.zTraceV2 <> nil then
  begin
    Tcl_Free(pDb^.zTraceV2);
    pDb^.zTraceV2 := nil;
  end;
  if pDb^.zProfile <> nil then
  begin
    Tcl_Free(pDb^.zProfile);
    pDb^.zProfile := nil;
  end;
  { Free authorizer callback script — tclsqlite.c:643..645. }
  if pDb^.zAuth <> nil then
  begin
    Tcl_Free(pDb^.zAuth);
    pDb^.zAuth := nil;
  end;
  { Free busy callback script — tclsqlite.c:628..630. }
  if pDb^.zBusy <> nil then
  begin
    Tcl_Free(pDb^.zBusy);
    pDb^.zBusy := nil;
  end;
  { Free progress callback script — tclsqlite.c:631..633. }
  if pDb^.zProgress <> nil then
  begin
    Tcl_Free(pDb^.zProgress);
    pDb^.zProgress := nil;
  end;
  Dispose(pDb);
end;

{ DbEvalColumnValue — Pas port of dbEvalColumnValue (tclsqlite.c:1850..1876).
  Returns a fresh (refcount-0) typed Tcl_Obj for column iCol of the row the
  statement currently points at:
    SQLITE_INTEGER -> Tcl_NewWideIntObj  (via sqlite3_column_int64)
    SQLITE_FLOAT   -> Tcl_NewDoubleObj
    SQLITE_BLOB    -> Tcl_NewByteArrayObj
    SQLITE_NULL    -> Tcl_NewStringObj(zNull, -1)
    else (text)    -> Tcl_NewStringObj(sqlite3_column_text, -1)
  Divergence vs upstream: upstream narrows small int64 to Tcl_NewIntObj; we
  always use Tcl_NewWideIntObj — Tcl stringifies both identically and the
  numeric value is exact, so no observable difference. }
function DbEvalColumnValue(pStmt: Pointer; iCol: cint;
  zNullStr: PAnsiChar): PTclObj;
var
  zBlob: Pointer;
  nByte: cint;
  zTxt:  PAnsiChar;
begin
  case sqlite3_column_type(pStmt, iCol) of
    SQLITE_INTEGER:
      Result := Tcl_NewWideIntObj(sqlite3_column_int64(pStmt, iCol));
    SQLITE_FLOAT:
      Result := Tcl_NewDoubleObj(sqlite3_column_double(pStmt, iCol));
    SQLITE_BLOB:
      begin
        nByte := sqlite3_column_bytes(pStmt, iCol);
        zBlob := sqlite3_column_blob(pStmt, iCol);
        if zBlob = nil then nByte := 0;
        Result := Tcl_NewByteArrayObj(zBlob, nByte);
      end;
    SQLITE_NULL:
      Result := Tcl_NewStringObj(zNullStr, -1);
    else
      begin
        zTxt := sqlite3_column_text(pStmt, iCol);
        Result := Tcl_NewStringObj(zTxt, -1);
      end;
  end;
end;

{ DbEvalArm — port of the "eval" arm of DbObjCmd (tclsqlite.c:3299..3360)
  plus the row-stepper loop body from dbEvalStep (tclsqlite.c:1766..1823)
  and DbEvalNextCmd (tclsqlite.c:1915..2005).

  Contract:
    objc==3:  `db eval SQL` — accumulate a flat list of typed column
              Tcl_Objs and return it as the interp result.
    objc==5 (or objc==4 with empty array name):
              `db eval SQL ARRAY-NAME SCRIPT` — for each row, bind every
              column value into the named Tcl array (column-name -> value)
              via Tcl_ObjSetVar2, then evaluate the script body.
              TCL_BREAK / TCL_CONTINUE / TCL_RETURN / TCL_ERROR from the
              body are handled exactly as upstream DbEvalNextCmd.
    objc==4 with a non-empty 3rd arg:
              `db eval SQL SCRIPT` — pVarName is 0, so each column NAME is
              itself used as the scalar variable (upstream: pVarName==0
              -> Tcl_ObjSetVar2(interp, apColName[i], 0, value)).

  On any SQLITE error we SET the interp result to sqlite3_errmsg() and
  return TCL_ERROR (9.4.divbug.6 — SET, not Append, so a UDF error already
  on the interp result is not duplicated).

  Not ported (vs upstream): NRE machinery, -withoutnulls / -asdict flags,
  the prepared-statement cache, busy-handler SCHEMA retries. }
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
  zNullStr:   PAnsiChar;
  emptyNull:  array[0..0] of AnsiChar;
  nVar:       i32;
  iParam:     i32;
  zParamName: PAnsiChar;
  pVarStr:    PChar;
  pVarName:   PTclObj;       { array name obj, or nil for the scalar form }
  pScript:    PTclObj;       { per-row script body, or nil for objc==3   }
  pColName:   PTclObj;
  pColVal:    PTclObj;
  rcBody:     cint;
  zArrName:   PAnsiChar;
  bDone:      Boolean;
begin
  if (objc < 3) or (objc > 5) then
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

  { Decide the row-callback shape — mirrors tclsqlite.c:3320..3349. }
  pVarName := nil;
  pScript  := nil;
  if objc >= 4 then
  begin
    pScript := ObjvAt(objv, objc - 1);
    if objc >= 5 then
    begin
      { objv[3] is the array name; an empty string means "scalar form". }
      zArrName := Tcl_GetStringFromObj(ObjvAt(objv, 3), nil);
      if (zArrName <> nil) and (zArrName^ <> #0) then
        pVarName := ObjvAt(objv, 3);
    end;
    Tcl_IncrRefCount(pScript);
  end;

  emptyNull[0] := #0;
  if pDb^.zNull <> nil then
    zNullStr := pDb^.zNull
  else
    zNullStr := @emptyNull[0];

  if pScript = nil then
  begin
    pList := Tcl_NewListObj(0, nil);
    Tcl_IncrRefCount(pList);
  end
  else
    pList := nil;

  rcBody := TCL_OK;
  bDone  := False;

  { Outer loop: walk through zSql, one prepared statement per
    sqlite3_prepare_v2 call, advancing via pzTail.  Mirrors the
    `while (p->zSql[0] || p->pPreStmt)` loop of dbEvalStep:1769. }
  while (not bDone) and (zSql <> nil) and (zSql^ <> #0) do
  begin
    pStmt := nil;
    zTail := nil;
    rc := sqlite3_prepare_v2(pDb^.db, zSql, -1, @pStmt, @zTail);
    if rc <> SQLITE_OK then
    begin
      if pList <> nil then Tcl_DecrRefCount(pList);
      if pScript <> nil then Tcl_DecrRefCount(pScript);
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

    { 9.4.divbug.5 — minimal port of tclsqlite.c:dbPrepareAndBind
      (tclsqlite.c:1490..1556).  Walk the prepared statement's parameter
      list and substitute `$NAME` / `:NAME` / `@NAME` from the calling
      Tcl scope. }
    nVar := sqlite3_bind_parameter_count(pStmt);
    for iParam := 1 to nVar do begin
      zParamName := sqlite3_bind_parameter_name(pStmt, iParam);
      if (zParamName <> nil) and
         ((zParamName[0] = '$') or (zParamName[0] = ':') or (zParamName[0] = '@')) then begin
        pVarStr := Tcl_GetVar(interp, zParamName + 1, 0);
        if pVarStr <> nil then
          sqlite3_bind_text(pStmt, iParam, pVarStr, -1, SQLITE_TRANSIENT)
        else
          sqlite3_bind_null(pStmt, iParam);
      end;
    end;

    nCol := sqlite3_column_count(pStmt);

    repeat
      rcStep := sqlite3_step(pStmt);
      if rcStep = SQLITE_ROW then
      begin
        if pScript = nil then
        begin
          { objc==3: accumulate typed column values onto the flat list. }
          for i := 0 to nCol - 1 do
            Tcl_ListObjAppendElement(interp, pList,
              DbEvalColumnValue(pStmt, i, zNullStr));
        end
        else
        begin
          { 3-arg form: populate the target then run the script body.
            Mirrors the per-row block of DbEvalNextCmd (tclsqlite.c:1930..). }
          for i := 0 to nCol - 1 do
          begin
            pColName := Tcl_NewStringObj(sqlite3_column_name(pStmt, i), -1);
            Tcl_IncrRefCount(pColName);
            pColVal  := DbEvalColumnValue(pStmt, i, zNullStr);
            if pVarName = nil then
              { pVarName==0: the column NAME itself is the scalar var. }
              Tcl_ObjSetVar2(interp, pColName, nil, pColVal, 0)
            else
              { array form: ARRAY(colName) = colValue. }
              Tcl_ObjSetVar2(interp, pVarName, pColName, pColVal, 0);
            Tcl_DecrRefCount(pColName);
          end;

          rcBody := Tcl_EvalObjEx(interp, pScript, 0);
          if (rcBody <> TCL_OK) and (rcBody <> TCL_CONTINUE) then
          begin
            { TCL_BREAK / TCL_RETURN / TCL_ERROR — stop stepping. }
            bDone := True;
            break;  { out of the repeat..until row loop }
          end;
        end;
      end;
    until rcStep <> SQLITE_ROW;

    sqlite3_finalize(pStmt);

    if bDone then
    begin
      { Body asked us to stop; finalize already done above. }
      break;
    end;

    if (rcStep <> SQLITE_DONE) and (rcStep <> SQLITE_OK) then
    begin
      if pList <> nil then Tcl_DecrRefCount(pList);
      if pScript <> nil then Tcl_DecrRefCount(pScript);
      Tcl_SetObjResult(interp,
        Tcl_NewStringObj(sqlite3_errmsg(pDb^.db), -1));
      Result := TCL_ERROR;
      Exit;
    end;

    zSql := zTail;
  end;

  if pScript = nil then
  begin
    { objc==3: the flat list is the result. }
    Tcl_SetObjResult(interp, pList);
    Tcl_DecrRefCount(pList);
    Result := TCL_OK;
    Exit;
  end;

  { 3-arg form cleanup — mirrors DbEvalNextCmd tail (tclsqlite.c:1999..2005). }
  Tcl_DecrRefCount(pScript);
  if (rcBody = TCL_OK) or (rcBody = TCL_BREAK) or (rcBody = TCL_CONTINUE) then
  begin
    Tcl_ResetResult(interp);
    Result := TCL_OK;
  end
  else
    { TCL_RETURN / TCL_ERROR propagate to the caller verbatim. }
    Result := rcBody;
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

{ ----------------------------------------------------------------------
  Trace / profile callback trampolines — tclsqlite.c:715..826.

  Each fires on prepared-statement events and evaluates the stored Tcl
  script with the per-event arguments appended as list elements. }

{ DbTraceHandler — legacy sqlite3_trace callback.  tclsqlite.c:710..727.
  Signature: void (*)(void *cd, const char *zSql). }
procedure DbTraceHandler(cd: Pointer; zSql: PAnsiChar); cdecl;
var
  pDb: PSqliteDb;
  str: TTclDString;
begin
  pDb := PSqliteDb(cd);
  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pDb^.zTrace, -1);
  Tcl_DStringAppendElement(@str, zSql);
  Tcl_Eval(pDb^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);
  Tcl_ResetResult(pDb^.interp);
end;

{ DbTraceV2Handler — sqlite3_trace_v2 callback.  tclsqlite.c:737..803.
  Signature: int (*)(unsigned type, void *cd, void *pd, void *xd). }
function DbTraceV2Handler(traceType: cuint;
  cd, pd, xd: Pointer): cint; cdecl;
var
  pDb:  PSqliteDb;
  pCmd: PTclObj;
  zSql: PAnsiChar;
  ns:   Int64;
begin
  pDb := PSqliteDb(cd);
  case traceType of
    SQLITE_TRACE_STMT:
      begin
        zSql := PAnsiChar(xd);
        pCmd := Tcl_NewStringObj(pDb^.zTraceV2, -1);
        Tcl_IncrRefCount(pCmd);
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(Int64(PtrUInt(pd))));
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewStringObj(zSql, -1));
        Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
        Tcl_DecrRefCount(pCmd);
        Tcl_ResetResult(pDb^.interp);
      end;
    SQLITE_TRACE_PROFILE:
      begin
        ns   := PInt64(xd)^;
        pCmd := Tcl_NewStringObj(pDb^.zTraceV2, -1);
        Tcl_IncrRefCount(pCmd);
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(Int64(PtrUInt(pd))));
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(ns));
        Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
        Tcl_DecrRefCount(pCmd);
        Tcl_ResetResult(pDb^.interp);
      end;
    SQLITE_TRACE_ROW:
      begin
        pCmd := Tcl_NewStringObj(pDb^.zTraceV2, -1);
        Tcl_IncrRefCount(pCmd);
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(Int64(PtrUInt(pd))));
        Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
        Tcl_DecrRefCount(pCmd);
        Tcl_ResetResult(pDb^.interp);
      end;
    SQLITE_TRACE_CLOSE:
      begin
        pCmd := Tcl_NewStringObj(pDb^.zTraceV2, -1);
        Tcl_IncrRefCount(pCmd);
        Tcl_ListObjAppendElement(pDb^.interp, pCmd,
          Tcl_NewWideIntObj(Int64(PtrUInt(pd))));
        Tcl_EvalObjEx(pDb^.interp, pCmd, TCL_EVAL_DIRECT);
        Tcl_DecrRefCount(pCmd);
        Tcl_ResetResult(pDb^.interp);
      end;
  end;
  Result := SQLITE_OK;
end;

{ DbProfileHandler — legacy sqlite3_profile callback.  tclsqlite.c:812..825.
  Signature: void (*)(void *cd, const char *zSql, sqlite_uint64 tm). }
procedure DbProfileHandler(cd: Pointer; zSql: PAnsiChar; tm: UInt64); cdecl;
var
  pDb: PSqliteDb;
  str: TTclDString;
  zTm: array[0..63] of AnsiChar;
begin
  pDb := PSqliteDb(cd);
  StrPCopy(zTm, IntToStr(tm));
  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pDb^.zProfile, -1);
  Tcl_DStringAppendElement(@str, zSql);
  Tcl_DStringAppendElement(@str, zTm);
  Tcl_Eval(pDb^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);
  Tcl_ResetResult(pDb^.interp);
end;

{ DbTraceArm — `db trace ?CALLBACK?`  tclsqlite.c:3831..3863. }
function DbTraceArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:    PSqliteDb;
  zTrace: PAnsiChar;
  len:    cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zTrace <> nil then
      Tcl_AppendResult(interp, pDb^.zTrace, Pointer(nil));
  end
  else
  begin
    if pDb^.zTrace <> nil then
      Tcl_Free(pDb^.zTrace);
    zTrace := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zTrace <> nil) and (len > 0) then
    begin
      pDb^.zTrace := Tcl_Alloc(len + 1);
      Move(zTrace^, pDb^.zTrace^, len + 1);
    end
    else
      pDb^.zTrace := nil;
    if pDb^.zTrace <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_trace(pDb^.db, @DbTraceHandler, pDb);
    end
    else
      sqlite3_trace(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbTraceV2Arm — `db trace_v2 ?CALLBACK? ?MASK?`  tclsqlite.c:3871..3945. }
function DbTraceV2Arm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  TTYPE_strs: array[0..4] of PChar =
    ('statement', 'profile', 'row', 'close', nil);
var
  pDb:      PSqliteDb;
  zTraceV2: PAnsiChar;
  len:      cint;
  wMask:    Int64;
  i:        cint;
  pObj:     PTclObj;
  ttype:    cint;
  wType:    Int64;
  pError:   PTclObj;
begin
  pDb := PSqliteDb(clientData);
  if objc > 4 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK? ?MASK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zTraceV2 <> nil then
      Tcl_AppendResult(interp, pDb^.zTraceV2, Pointer(nil));
  end
  else
  begin
    wMask := 0;
    if objc = 4 then
    begin
      if Tcl_ListObjLength(interp, ObjvAt(objv, 3), @len) <> TCL_OK then
      begin
        Result := TCL_ERROR;
        Exit;
      end;
      for i := 0 to len - 1 do
      begin
        if Tcl_ListObjIndex(interp, ObjvAt(objv, 3), i, @pObj) <> TCL_OK then
        begin
          Result := TCL_ERROR;
          Exit;
        end;
        if Tcl_GetIndexFromObj(interp, pObj, @TTYPE_strs[0],
             PChar('trace type'), 0, @ttype) <> TCL_OK then
        begin
          pError := Tcl_DuplicateObj(Tcl_GetObjResult(interp));
          Tcl_IncrRefCount(pError);
          if Tcl_GetWideIntFromObj(interp, pObj, @wType) = TCL_OK then
          begin
            Tcl_DecrRefCount(pError);
            wMask := wMask or wType;
          end
          else
          begin
            Tcl_SetObjResult(interp, pError);
            Tcl_DecrRefCount(pError);
            Result := TCL_ERROR;
            Exit;
          end;
        end
        else
        begin
          case ttype of
            0: wMask := wMask or SQLITE_TRACE_STMT;
            1: wMask := wMask or SQLITE_TRACE_PROFILE;
            2: wMask := wMask or SQLITE_TRACE_ROW;
            3: wMask := wMask or SQLITE_TRACE_CLOSE;
          end;
        end;
      end;
    end
    else
      wMask := SQLITE_TRACE_STMT;  { the "legacy" default }
    if pDb^.zTraceV2 <> nil then
      Tcl_Free(pDb^.zTraceV2);
    zTraceV2 := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zTraceV2 <> nil) and (len > 0) then
    begin
      pDb^.zTraceV2 := Tcl_Alloc(len + 1);
      Move(zTraceV2^, pDb^.zTraceV2^, len + 1);
    end
    else
      pDb^.zTraceV2 := nil;
    if pDb^.zTraceV2 <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_trace_v2(pDb^.db, cuint(wMask), @DbTraceV2Handler, pDb);
    end
    else
      sqlite3_trace_v2(pDb^.db, 0, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbProfileArm — `db profile ?CALLBACK?`  tclsqlite.c:3620..3651. }
function DbProfileArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:      PSqliteDb;
  zProfile: PAnsiChar;
  len:      cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zProfile <> nil then
      Tcl_AppendResult(interp, pDb^.zProfile, Pointer(nil));
  end
  else
  begin
    if pDb^.zProfile <> nil then
      Tcl_Free(pDb^.zProfile);
    zProfile := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zProfile <> nil) and (len > 0) then
    begin
      pDb^.zProfile := Tcl_Alloc(len + 1);
      Move(zProfile^, pDb^.zProfile^, len + 1);
    end
    else
      pDb^.zProfile := nil;
    if pDb^.zProfile <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_profile(pDb^.db, @DbProfileHandler, pDb);
    end
    else
      sqlite3_profile(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbAuthHandler — the sqlite3_set_authorizer callback trampoline.
  Port of auth_callback (tclsqlite.c:1170..1248).  Maps the integer
  action code to its symbolic string, appends the symbolic code plus
  the four string args as Tcl list elements to the stored callback
  script, GlobalEval's it, then maps the result string back to an
  integer rc.  Signature:
    int (*)(void*, int, const char*, const char*,
            const char*, const char*). }
function DbAuthHandler(pArg: Pointer; code: cint;
  zArg1, zArg2, zArg3, zArg4: PAnsiChar): cint; cdecl;
var
  pDb:    PSqliteDb;
  zCode:  PAnsiChar;
  str:    TTclDString;
  rc:     cint;
  zReply: PAnsiChar;
begin
  pDb := PSqliteDb(pArg);

  { EVIDENCE-OF: R-56518-44310 — the second parameter to the callback
    is an integer action code that specifies the action to authorize. }
  case code of
    0                          : zCode := 'SQLITE_COPY';
    SQLITE_CREATE_INDEX        : zCode := 'SQLITE_CREATE_INDEX';
    SQLITE_CREATE_TABLE        : zCode := 'SQLITE_CREATE_TABLE';
    SQLITE_CREATE_TEMP_INDEX   : zCode := 'SQLITE_CREATE_TEMP_INDEX';
    SQLITE_CREATE_TEMP_TABLE   : zCode := 'SQLITE_CREATE_TEMP_TABLE';
    SQLITE_CREATE_TEMP_TRIGGER : zCode := 'SQLITE_CREATE_TEMP_TRIGGER';
    SQLITE_CREATE_TEMP_VIEW    : zCode := 'SQLITE_CREATE_TEMP_VIEW';
    SQLITE_CREATE_TRIGGER      : zCode := 'SQLITE_CREATE_TRIGGER';
    SQLITE_CREATE_VIEW         : zCode := 'SQLITE_CREATE_VIEW';
    SQLITE_DELETE_AUTH         : zCode := 'SQLITE_DELETE';
    SQLITE_DROP_INDEX          : zCode := 'SQLITE_DROP_INDEX';
    SQLITE_DROP_TABLE          : zCode := 'SQLITE_DROP_TABLE';
    SQLITE_DROP_TEMP_INDEX     : zCode := 'SQLITE_DROP_TEMP_INDEX';
    SQLITE_DROP_TEMP_TABLE     : zCode := 'SQLITE_DROP_TEMP_TABLE';
    SQLITE_DROP_TEMP_TRIGGER   : zCode := 'SQLITE_DROP_TEMP_TRIGGER';
    SQLITE_DROP_TEMP_VIEW      : zCode := 'SQLITE_DROP_TEMP_VIEW';
    SQLITE_DROP_TRIGGER        : zCode := 'SQLITE_DROP_TRIGGER';
    SQLITE_DROP_VIEW           : zCode := 'SQLITE_DROP_VIEW';
    SQLITE_INSERT_AUTH         : zCode := 'SQLITE_INSERT';
    SQLITE_PRAGMA_AUTH         : zCode := 'SQLITE_PRAGMA';
    SQLITE_READ_AUTH           : zCode := 'SQLITE_READ';
    SQLITE_SELECT_AUTH         : zCode := 'SQLITE_SELECT';
    SQLITE_TRANSACTION_AUTH    : zCode := 'SQLITE_TRANSACTION';
    SQLITE_UPDATE_AUTH         : zCode := 'SQLITE_UPDATE';
    SQLITE_ATTACH_AUTH         : zCode := 'SQLITE_ATTACH';
    SQLITE_DETACH_AUTH         : zCode := 'SQLITE_DETACH';
    SQLITE_ALTER_TABLE_AUTH    : zCode := 'SQLITE_ALTER_TABLE';
    SQLITE_REINDEX_AUTH        : zCode := 'SQLITE_REINDEX';
    SQLITE_ANALYZE_AUTH        : zCode := 'SQLITE_ANALYZE';
    SQLITE_CREATE_VTABLE       : zCode := 'SQLITE_CREATE_VTABLE';
    SQLITE_DROP_VTABLE         : zCode := 'SQLITE_DROP_VTABLE';
    SQLITE_FUNCTION_AUTH       : zCode := 'SQLITE_FUNCTION';
    SQLITE_SAVEPOINT_AUTH      : zCode := 'SQLITE_SAVEPOINT';
    SQLITE_RECURSIVE_AUTH      : zCode := 'SQLITE_RECURSIVE';
  else
    zCode := '????';
  end;

  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pDb^.zAuth, -1);
  Tcl_DStringAppendElement(@str, zCode);
  if zArg1 <> nil then Tcl_DStringAppendElement(@str, zArg1)
                  else Tcl_DStringAppendElement(@str, '');
  if zArg2 <> nil then Tcl_DStringAppendElement(@str, zArg2)
                  else Tcl_DStringAppendElement(@str, '');
  if zArg3 <> nil then Tcl_DStringAppendElement(@str, zArg3)
                  else Tcl_DStringAppendElement(@str, '');
  if zArg4 <> nil then Tcl_DStringAppendElement(@str, zArg4)
                  else Tcl_DStringAppendElement(@str, '');
  rc := Tcl_GlobalEval(pDb^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);

  if rc = TCL_OK then
    zReply := Tcl_GetStringResult(pDb^.interp)
  else
    zReply := 'SQLITE_DENY';

  if StrComp(zReply, 'SQLITE_OK') = 0 then
    rc := SQLITE_OK
  else if StrComp(zReply, 'SQLITE_DENY') = 0 then
    rc := SQLITE_DENY
  else if StrComp(zReply, 'SQLITE_IGNORE') = 0 then
    rc := SQLITE_IGNORE
  else
    rc := 999;
  Result := rc;
end;

{ DbAuthorizerArm — `db authorizer ?CALLBACK?`  tclsqlite.c:2503..2541.
  2-arg form reports the current callback; 3-arg form replaces it and
  (re)registers via sqlite3_set_authorizer (or clears it). }
function DbAuthorizerArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:   PSqliteDb;
  zAuth: PAnsiChar;
  len:   cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('?CALLBACK?'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zAuth <> nil then
      Tcl_AppendResult(interp, pDb^.zAuth, Pointer(nil));
  end
  else
  begin
    if pDb^.zAuth <> nil then
      Tcl_Free(pDb^.zAuth);
    zAuth := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zAuth <> nil) and (len > 0) then
    begin
      pDb^.zAuth := Tcl_Alloc(len + 1);
      Move(zAuth^, pDb^.zAuth^, len + 1);
    end
    else
      pDb^.zAuth := nil;
    if pDb^.zAuth <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_set_authorizer(pDb^.db, @DbAuthHandler, pDb);
    end
    else
      sqlite3_set_authorizer(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbBusyHandler — the sqlite3_busy_handler callback trampoline.
  Port of DbBusyHandler (tclsqlite.c:681..692).  Builds "<zBusy> <n>"
  and evals it; a TCL error or a zero/non-integer result means
  "give up" (return 0), a non-zero integer result means "retry"
  (return 1).  Signature: int (*)(void*, int). }
function DbBusyHandler(cd: Pointer; nTries: cint): cint; cdecl;
var
  pDb:  PSqliteDb;
  str:  TTclDString;
  zVal: AnsiString;
  rc:   cint;
begin
  pDb  := PSqliteDb(cd);
  zVal := IntToStr(nTries);   { "%d" of nTries — tclsqlite.c:686 }
  Tcl_DStringInit(@str);
  Tcl_DStringAppend(@str, pDb^.zBusy, -1);
  Tcl_DStringAppend(@str, PChar(' '), 1);
  Tcl_DStringAppend(@str, PChar(zVal), -1);
  rc := Tcl_Eval(pDb^.interp, Tcl_DStringValue(@str));
  Tcl_DStringFree(@str);
  if (rc <> TCL_OK) or
     (StrToIntDef(string(Tcl_GetStringResult(pDb^.interp)), 0) <> 0) then
    Result := 0
  else
    Result := 1;
end;

{ DbBusyArm — `db busy ?CALLBACK?`  tclsqlite.c:2641..2670.
  2-arg form reports the current callback; 3-arg form replaces it and
  (re)registers via sqlite3_busy_handler (or clears it). }
function DbBusyArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:   PSqliteDb;
  zBusy: PAnsiChar;
  len:   cint;
begin
  pDb := PSqliteDb(clientData);
  if objc > 3 then
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('CALLBACK'));
    Result := TCL_ERROR;
    Exit;
  end
  else if objc = 2 then
  begin
    if pDb^.zBusy <> nil then
      Tcl_AppendResult(interp, pDb^.zBusy, Pointer(nil));
  end
  else
  begin
    if pDb^.zBusy <> nil then
      Tcl_Free(pDb^.zBusy);
    zBusy := Tcl_GetStringFromObj(ObjvAt(objv, 2), @len);
    if (zBusy <> nil) and (len > 0) then
    begin
      pDb^.zBusy := Tcl_Alloc(len + 1);
      Move(zBusy^, pDb^.zBusy^, len + 1);
    end
    else
      pDb^.zBusy := nil;
    if pDb^.zBusy <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_busy_handler(pDb^.db, @DbBusyHandler, pDb);
    end
    else
      sqlite3_busy_handler(pDb^.db, nil, nil);
  end;
  Result := TCL_OK;
end;

{ DbProgressHandler — the sqlite3_progress_handler callback trampoline.
  Port of DbProgressHandler (tclsqlite.c:698..708).  Evals the stored
  script; a TCL error or a non-zero/non-integer result interrupts the
  query (return 1), otherwise continue (return 0).
  Signature: int (*)(void*). }
function DbProgressHandler(cd: Pointer): cint; cdecl;
var
  pDb: PSqliteDb;
  rc:  cint;
begin
  pDb := PSqliteDb(cd);
  rc  := Tcl_Eval(pDb^.interp, pDb^.zProgress);
  if (rc <> TCL_OK) or
     (StrToIntDef(string(Tcl_GetStringResult(pDb^.interp)), 0) <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ DbProgressArm — `db progress ?N CALLBACK?`  tclsqlite.c:3574..3606.
  2-arg form reports the current callback and clears it; 4-arg form
  (re)registers a callback fired every N opcodes via
  sqlite3_progress_handler. }
function DbProgressArm(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  pDb:       PSqliteDb;
  zProgress: PAnsiChar;
  len:       cint;
  N:         cint;
begin
  pDb := PSqliteDb(clientData);
  if objc = 2 then
  begin
    if pDb^.zProgress <> nil then
      Tcl_AppendResult(interp, pDb^.zProgress, Pointer(nil));
    sqlite3_progress_handler(pDb^.db, 0, nil, nil);
  end
  else if objc = 4 then
  begin
    if Tcl_GetIntFromObj(interp, ObjvAt(objv, 2), @N) <> TCL_OK then
    begin
      Result := TCL_ERROR;
      Exit;
    end;
    if pDb^.zProgress <> nil then
      Tcl_Free(pDb^.zProgress);
    zProgress := Tcl_GetStringFromObj(ObjvAt(objv, 3), @len);
    if (zProgress <> nil) and (len > 0) then
    begin
      pDb^.zProgress := Tcl_Alloc(len + 1);
      Move(zProgress^, pDb^.zProgress^, len + 1);
    end
    else
      pDb^.zProgress := nil;
    if pDb^.zProgress <> nil then
    begin
      pDb^.interp := interp;
      sqlite3_progress_handler(pDb^.db, N, @DbProgressHandler, pDb);
    end
    else
      sqlite3_progress_handler(pDb^.db, 0, nil, nil);
  end
  else
  begin
    Tcl_WrongNumArgs(interp, 2, objv, PChar('N CALLBACK'));
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

  { trace — tclsqlite.c:3831 (DB_TRACE).  Legacy sqlite3_trace shim. }
  if (zSub <> nil) and (StrComp(zSub, 'trace') = 0) then
  begin
    Result := DbTraceArm(clientData, interp, objc, objv);
    Exit;
  end;

  { trace_v2 — tclsqlite.c:3871 (DB_TRACE_V2).  sqlite3_trace_v2 shim. }
  if (zSub <> nil) and (StrComp(zSub, 'trace_v2') = 0) then
  begin
    Result := DbTraceV2Arm(clientData, interp, objc, objv);
    Exit;
  end;

  { profile — tclsqlite.c:3620 (DB_PROFILE).  Legacy sqlite3_profile shim. }
  if (zSub <> nil) and (StrComp(zSub, 'profile') = 0) then
  begin
    Result := DbProfileArm(clientData, interp, objc, objv);
    Exit;
  end;

  { authorizer — tclsqlite.c:2503 (DB_AUTHORIZER).  sqlite3_set_authorizer
    shim. }
  if (zSub <> nil) and (StrComp(zSub, 'authorizer') = 0) then
  begin
    Result := DbAuthorizerArm(clientData, interp, objc, objv);
    Exit;
  end;

  { busy — tclsqlite.c:2641 (DB_BUSY).  sqlite3_busy_handler shim. }
  if (zSub <> nil) and (StrComp(zSub, 'busy') = 0) then
  begin
    Result := DbBusyArm(clientData, interp, objc, objv);
    Exit;
  end;

  { progress — tclsqlite.c:3574 (DB_PROGRESS).  sqlite3_progress_handler
    shim. }
  if (zSub <> nil) and (StrComp(zSub, 'progress') = 0) then
  begin
    Result := DbProgressArm(clientData, interp, objc, objv);
    Exit;
  end;

  { interrupt — tclsqlite.c:3511 (DB_INTERRUPT).  Direct passthrough. }
  if (zSub <> nil) and (StrComp(zSub, 'interrupt') = 0) then
  begin
    sqlite3_interrupt(PSqliteDb(clientData)^.db);
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
  pDb^.db       := pHandle;
  pDb^.interp   := interp;
  pDb^.zNull    := nil;
  pDb^.pFunc    := nil;
  pDb^.zTrace   := nil;
  pDb^.zTraceV2 := nil;
  pDb^.zProfile := nil;
  pDb^.zAuth    := nil;

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
