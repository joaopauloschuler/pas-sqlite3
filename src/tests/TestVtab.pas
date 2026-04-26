{$I ../passqlite3.inc}
program TestVtab;

{
  Phase 6.bis.1a gate — vtab.c types and module-registry leaf helpers.

  Exercises:
    * sqlite3VtabCreateModule (direct call) and the public
      sqlite3_create_module / _v2 wrappers in main.pas
    * Replacement path now invokes sqlite3VtabModuleUnref → xDestroy
      regardless of pAux nullity (faithful vtab.c behaviour, replacing
      the Phase 8.3 stub guard).
    * sqlite3_drop_modules with and without an azNames whitelist.
    * Empty module registry: drop_modules → SQLITE_OK no-op.
    * Lock/Unlock pairs on a manually constructed VTable (no Table or
      constructor lifecycle yet — those land with 6.bis.1c).
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3codegen,
  passqlite3parser,
  passqlite3vdbe,
  passqlite3main,
  passqlite3vtab;

var
  gPass, gFail: i32;
  gDestroyCount: i32;
  gDisconnectCount: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

procedure DummyDestroy(p: Pointer); cdecl;
begin Inc(gDestroyCount); end;

function DummyDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  Inc(gDisconnectCount);
  Result := SQLITE_OK;
end;

{ Manually construct a TParse + TTable to drive the Phase 6.bis.1b parser
  hooks without the still-stubbed sqlite3StartTable.  Pins the azArg
  accumulation contract: ArgExtend builds up sArg, ArgInit flushes one
  argument, FinishParse flushes the trailing one and (on init.busy=1)
  installs the table into the schema. }
type
  TUtilPSchema = passqlite3util.PSchema;
  TCgPTable    = passqlite3codegen.PTable2;
  TCgPParse    = passqlite3codegen.PParse;
  TCgTParse    = passqlite3codegen.TParse;

procedure TestVtabParser_Run(db: PTsqlite3);
var
  pParse:    TCgPParse;
  pTab:      TCgPTable;
  pSchemaT:  TUtilPSchema;
  tName:     TToken;
  tArg1:     TToken;
  tArg2a:    TToken;
  tArg2b:    TToken;
  azArg:     PPAnsiChar;
  pHashed:   TCgPTable;
  zN, zArg1, zArg2: AnsiString;
const
  cName  = 'mvtab';
  cArg1  = 'foo';
  cArg2a = 'bar';
  cArg2b = 'baz';
begin
  zN    := cName;  { keep the strings live for sArg.z borrowing }
  zArg1 := cArg1;
  zArg2 := cArg2a + ' ' + cArg2b;

  pParse := TCgPParse(sqlite3MallocZero64(SizeOf(TCgTParse)));
  Expect(pParse <> nil, 'T17 alloc Parse');
  pParse^.db := db;

  pTab := TCgPTable(
    sqlite3MallocZero64(SizeOf(passqlite3codegen.TTable)));
  Expect(pTab <> nil, 'T17b alloc Table');
  pTab^.zName    := PAnsiChar(zN);
  pTab^.eTabType := passqlite3codegen.TABTYP_VTAB;
  { aDb[0].pSchema is allocated by openDatabase; reuse it. }
  pSchemaT := TUtilPSchema(db^.aDb[0].pSchema);
  pTab^.pSchema  := passqlite3codegen.PSchema(pSchemaT);
  pParse^.pNewTable := pTab;

  { Extend a single token's worth of sArg state, then ArgInit flushes it.   }
  tArg1.z := PAnsiChar(zArg1);
  tArg1.n := Length(zArg1);
  sqlite3VtabArgExtend(pParse, @tArg1);
  ExpectEq(pParse^.sArg.n, Length(zArg1), 'T18 ArgExtend sets sArg.n');
  Expect(pParse^.sArg.z = PAnsiChar(zArg1), 'T18b ArgExtend sets sArg.z');

  sqlite3VtabArgInit(pParse);
  ExpectEq(pTab^.u.vtab.nArg, 1, 'T19 ArgInit appends argument');
  Expect(pParse^.sArg.z = nil, 'T19b ArgInit clears sArg.z');
  ExpectEq(pParse^.sArg.n, 0,   'T19c ArgInit clears sArg.n');

  azArg := PPAnsiChar(pTab^.u.vtab.azArg);
  Expect(StrComp(azArg[0], PAnsiChar(zArg1)) = 0,
    'T19d argument 0 == "foo"');

  { Two ArgExtend calls in sequence span both tokens via address arithmetic. }
  tArg2a.z := PAnsiChar(zArg2);
  tArg2a.n := Length(cArg2a);
  tArg2b.z := PAnsiChar(zArg2) + Length(cArg2a) + 1;  { skip space }
  tArg2b.n := Length(cArg2b);
  sqlite3VtabArgExtend(pParse, @tArg2a);
  sqlite3VtabArgExtend(pParse, @tArg2b);
  ExpectEq(pParse^.sArg.n,
    Length(cArg2a) + 1 + Length(cArg2b),
    'T20 ArgExtend spans two tokens');

  { FinishParse with init.busy=1: flushes pending sArg and installs pTab in
    the schema.  We can't easily exercise the init.busy=0 branch yet —
    sqlite3MPrintf and sqlite3NestedParse are still Phase-7 stubs. }
  tName.z := PAnsiChar(zN);
  tName.n := Length(zN);
  pParse^.sNameToken := tName;
  db^.init.busy := 1;
  try
    sqlite3VtabFinishParse(pParse, nil);
  finally
    db^.init.busy := 0;
  end;
  ExpectEq(pTab^.u.vtab.nArg, 2,
    'T21 FinishParse flushes trailing argument');
  Expect(pParse^.pNewTable = nil,
    'T21b init.busy=1 path nulls pNewTable on success');

  pHashed := TCgPTable(
    sqlite3HashFind(@pSchemaT^.tblHash, PChar(zN)));
  Expect(pHashed = pTab,
    'T22 table installed in schema tblHash under zName');

  { Cleanup: yank from hash so sqlite3_close_v2 on db doesn't double-free.   }
  sqlite3HashInsert(@pSchemaT^.tblHash, PChar(zN), nil);
  azArg := PPAnsiChar(pTab^.u.vtab.azArg);
  if azArg <> nil then begin
    sqlite3DbFree(db, azArg[0]);
    sqlite3DbFree(db, azArg[2]);
    { slot 1 is the borrowed schema name (nil here) }
    sqlite3DbFree(db, azArg);
  end;
  sqlite3DbFree(db, pTab);
  sqlite3DbFree(db, pParse);

  { Note: T18..T22 leave T1..T17 numbering intact for the gate counter so
    the "27/27 PASS" headline grows naturally to the new count. }
end;

{ ============================================================
  Phase 6.bis.1c — constructor lifecycle (vtabCallConstructor +
  sqlite3VtabCallConnect / _Create / _Destroy + growVTrans/addToVTrans).
  ============================================================ }

var
  gConnectCount: i32;
  gCreateCount:  i32;
  gXDestroyCount: i32;     { distinct from Module's xDestroy = gDestroyCount }
  gAllocVtabs:   array[0..15] of PSqlite3Vtab;
  gAllocVtabN:   i32;
  gFailNextConnect: i32;   { if 1, the next xConnect returns ERROR }
  gSkipDeclare:  i32;      { if 1, the next xConnect skips bDeclared:=1 }

procedure CtorTrackVtab(p: PSqlite3Vtab);
begin
  gAllocVtabs[gAllocVtabN] := p;
  Inc(gAllocVtabN);
end;

function CtorXConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  v:    PSqlite3Vtab;
  pCtx: PVtabCtx;
begin
  Inc(gConnectCount);
  if gFailNextConnect = 1 then begin
    gFailNextConnect := 0;
    pzErr^ := nil;     { let the constructor synthesise a default message }
    Result := SQLITE_ERROR;
    Exit;
  end;
  GetMem(v, SizeOf(Tsqlite3_vtab));
  FillChar(v^, SizeOf(Tsqlite3_vtab), 0);
  CtorTrackVtab(v);
  ppVtab^ := v;

  if gSkipDeclare = 0 then begin
    { Mirror sqlite3_declare_vtab's only side effect that Phase 6.bis.1c
      actually depends on: flip the active VtabCtx's bDeclared bit so the
      constructor doesn't reject us with "did not declare schema". }
    pCtx := PVtabCtx(db^.pVtabCtx);
    if pCtx <> nil then pCtx^.bDeclared := 1;
  end else begin
    gSkipDeclare := 0;
  end;
  Result := SQLITE_OK;
end;

function CtorXCreate(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
begin
  Inc(gCreateCount);
  Result := CtorXConnect(db, pAux, argc, argv, ppVtab, pzErr);
end;

function CtorXDestroy(p: PSqlite3Vtab): i32; cdecl;
begin
  Inc(gXDestroyCount);
  FreeMem(p);
  Result := SQLITE_OK;
end;

function CtorXDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  Inc(gDisconnectCount);
  FreeMem(p);
  Result := SQLITE_OK;
end;

{ Build a heap-allocated TTable in TABTYP_VTAB shape, install it into the
  default schema's tblHash, and return it.  Caller is responsible for
  removing it from the hash before close (vtabDisconnectAll deals with the
  VTable chain; the Table itself is freed via sqlite3DeleteTable). }
function CtorMakeTable(db: PTsqlite3;
  const zName, zMod: AnsiString): TCgPTable;
var
  pTab:    TCgPTable;
  azArg:   PPAnsiChar;
  pSchemaT: TUtilPSchema;
begin
  pTab := TCgPTable(sqlite3MallocZero64(
            SizeOf(passqlite3codegen.TTable)));
  pTab^.zName    := sqlite3DbStrDup(db, PChar(zName));
  pTab^.eTabType := passqlite3codegen.TABTYP_VTAB;
  pTab^.nTabRef  := 1;
  pSchemaT := TUtilPSchema(db^.aDb[0].pSchema);
  pTab^.pSchema  := passqlite3codegen.PSchema(pSchemaT);

  { azArg layout: [0]=module name, [1]=schema name (filled by ctor),
                  [2]=table name. nArg=3. }
  azArg := PPAnsiChar(sqlite3MallocZero64(SizeOf(Pointer) * 3));
  azArg[0] := sqlite3DbStrDup(db, PChar(zMod));
  azArg[1] := nil;
  azArg[2] := sqlite3DbStrDup(db, PChar(zName));
  pTab^.u.vtab.azArg := Pointer(azArg);
  pTab^.u.vtab.nArg  := 3;

  sqlite3HashInsert(@pSchemaT^.tblHash, PChar(pTab^.zName), pTab);
  Result := pTab;
end;

procedure TestVtabCtor_Run(db: PTsqlite3);
var
  m:        Tsqlite3_module;
  pMod:     PVtabModule;
  pParse:   TCgPParse;
  pTabA:    TCgPTable;
  pTabB:    TCgPTable;
  pVT:      PVTable;
  rc:       i32;
  zErr:     PAnsiChar;
  pSchemaT: TUtilPSchema;
  i:        i32;
begin
  WriteLn('TestVtab — Phase 6.bis.1c gate');
  pSchemaT := TUtilPSchema(db^.aDb[0].pSchema);

  { Module with all four constructor/destructor slots populated. }
  FillChar(m, SizeOf(m), 0);
  m.iVersion    := 1;
  m.xCreate     := @CtorXCreate;
  m.xConnect    := @CtorXConnect;
  m.xDestroy    := @CtorXDestroy;
  m.xDisconnect := @CtorXDisconnect;
  pMod := sqlite3VtabCreateModule(db, 'ctormod', @m, nil, nil);
  Expect(pMod <> nil, 'T23 register ctormod');

  pParse := TCgPParse(sqlite3MallocZero64(SizeOf(TCgTParse)));
  pParse^.db := db;

  { ---- T24: sqlite3VtabCallConnect happy path ---- }
  pTabA := CtorMakeTable(db, 'ct_a', 'ctormod');
  gConnectCount := 0;
  rc := sqlite3VtabCallConnect(pParse, pTabA);
  ExpectEq(rc, SQLITE_OK, 'T24 VtabCallConnect ok');
  ExpectEq(gConnectCount, 1, 'T24b xConnect fired once');
  pVT := sqlite3GetVTable(db, pTabA);
  Expect(pVT <> nil, 'T24c VTable linked into pTab');
  if pVT <> nil then begin
    ExpectEq(pVT^.nRef, 1, 'T24d nRef=1 after connect');
    Expect(pVT^.pVtab <> nil, 'T24e pVtab non-nil');
  end;
  ExpectEq(db^.nVTrans, 0,
    'T24f Connect path does NOT touch aVTrans (only Create does)');

  { Calling Connect a second time on the same pTab is a no-op (returns OK
    immediately because sqlite3GetVTable already finds it). }
  gConnectCount := 0;
  rc := sqlite3VtabCallConnect(pParse, pTabA);
  ExpectEq(rc, SQLITE_OK, 'T25 second Connect = OK');
  ExpectEq(gConnectCount, 0, 'T25b xConnect NOT re-fired');

  { ---- T26: missing module → SQLITE_ERROR ---- }
  pTabB := CtorMakeTable(db, 'ct_missing', 'no_such_module');
  rc := sqlite3VtabCallConnect(pParse, pTabB);
  ExpectEq(rc, SQLITE_ERROR, 'T26 missing module → ERROR');
  Expect(sqlite3GetVTable(db, pTabB) = nil, 'T26b no VTable attached');
  { Cleanup pTabB manually: yank from hash and free Table }
  sqlite3HashInsert(@pSchemaT^.tblHash, PChar(pTabB^.zName), nil);
  sqlite3VtabClear(db, pTabB);
  sqlite3DbFree(db, pTabB^.zName);
  sqlite3DbFree(db, pTabB);

  { ---- T27: xConnect returns ERROR ---- }
  pTabB := CtorMakeTable(db, 'ct_fail', 'ctormod');
  zErr := nil;
  gFailNextConnect := 1;
  rc := sqlite3VtabCallConnect(pParse, pTabB);
  ExpectEq(rc, SQLITE_ERROR, 'T27 xConnect ERROR propagates');
  Expect(sqlite3GetVTable(db, pTabB) = nil,
    'T27b error path leaves pTab^.u.vtab.p nil');
  sqlite3HashInsert(@pSchemaT^.tblHash, PChar(pTabB^.zName), nil);
  sqlite3VtabClear(db, pTabB);
  sqlite3DbFree(db, pTabB^.zName);
  sqlite3DbFree(db, pTabB);

  { ---- T28: xConnect succeeds but does not declare schema ---- }
  pTabB := CtorMakeTable(db, 'ct_nodecl', 'ctormod');
  gSkipDeclare := 1;
  rc := sqlite3VtabCallConnect(pParse, pTabB);
  ExpectEq(rc, SQLITE_ERROR, 'T28 missing declare → ERROR');
  Expect(sqlite3GetVTable(db, pTabB) = nil,
    'T28b VTable unlocked when bDeclared stays 0');
  sqlite3HashInsert(@pSchemaT^.tblHash, PChar(pTabB^.zName), nil);
  sqlite3VtabClear(db, pTabB);
  sqlite3DbFree(db, pTabB^.zName);
  sqlite3DbFree(db, pTabB);

  { ---- T29: sqlite3VtabCallCreate adds to aVTrans ---- }
  CtorMakeTable(db, 'ct_cr1', 'ctormod');
  zErr := nil;
  rc := sqlite3VtabCallCreate(db, 0, 'ct_cr1', @zErr);
  ExpectEq(rc, SQLITE_OK, 'T29 CallCreate ok');
  ExpectEq(db^.nVTrans, 1, 'T29b aVTrans grown to 1');
  Expect(db^.aVTrans <> nil, 'T29c aVTrans allocated');

  { Add 6 more so we cross the ARRAY_INCR=5 boundary. }
  for i := 2 to 7 do begin
    CtorMakeTable(db, 'ct_cr' + AnsiString(IntToStr(i)), 'ctormod');
    zErr := nil;
    rc := sqlite3VtabCallCreate(db, 0,
            PAnsiChar('ct_cr' + AnsiString(IntToStr(i))), @zErr);
    ExpectEq(rc, SQLITE_OK,
      'T30 CallCreate batch (' + AnsiString(IntToStr(i)) + ')');
  end;
  ExpectEq(db^.nVTrans, 7, 'T30b nVTrans = 7 after batch');

  { ---- T31: sqlite3VtabCallDestroy on first-created table ---- }
  gXDestroyCount := 0;
  rc := sqlite3VtabCallDestroy(db, 0, 'ct_cr1');
  ExpectEq(rc, SQLITE_OK, 'T31 CallDestroy ok');
  ExpectEq(gXDestroyCount, 1, 'T31b xDestroy fired once');

  { sqlite3VtabCallDestroy disconnects but leaves the Table in the schema
    hash; DROP TABLE codegen is responsible for removing it (Phase 7).  We
    only assert pTab^.u.vtab.p is now nil (the VTable was unlocked). }
  pTabB := passqlite3codegen.sqlite3FindTable(db, 'ct_cr1', 'main');
  Expect(pTabB <> nil, 'T31c Table still in schema (codegen removes it)');
  if pTabB <> nil then
    Expect(pTabB^.u.vtab.p = nil,
      'T31d pTab^.u.vtab.p cleared after destroy');

  { ---- Cleanup remaining tables and module before close ---- }
  for i := 2 to 7 do begin
    rc := sqlite3VtabCallDestroy(db, 0,
            PAnsiChar('ct_cr' + AnsiString(IntToStr(i))));
    ExpectEq(rc, SQLITE_OK,
      'T32 cleanup destroy ' + AnsiString(IntToStr(i)));
  end;
  rc := sqlite3VtabCallDestroy(db, 0, 'ct_a');
  { ct_a was Connect-only (not in aVTrans), but vtabDisconnectAll handles
    that fine: it pops the lone VTable off pTab^.u.vtab.p, fires xDestroy. }
  ExpectEq(rc, SQLITE_OK, 'T33 cleanup destroy ct_a');

  { aVTrans bookkeeping is not auto-pruned by VtabCallDestroy — it just
    drops the VTable from pTab; the slot in aVTrans still contains a
    pointer to the freed VTable.  Per upstream this is cleaned up by
    sqlite3VtabCommit/Rollback (Phase 6.bis.1d) which iterates aVTrans
    after a transaction.  For this gate we accept the leaked slots and
    zero db^.nVTrans manually so close() doesn't trip. }
  db^.nVTrans := 0;
  if db^.aVTrans <> nil then begin
    sqlite3DbFree(db, db^.aVTrans);
    db^.aVTrans := nil;
  end;

  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T34 drop modules');

  sqlite3DbFree(db, pParse);
end;

{ ============================================================
  Phase 6.bis.1d — per-statement transaction hooks.
  ============================================================ }

var
  gBeginCount, gSyncCount, gCommitCount, gRollbackCount: i32;
  gSavepointCount, gReleaseCount, gRollbackToCount:      i32;
  gLastSavepointArg: i32;
  gXSyncFails:       i32;   { if 1, next xSync returns ERROR + zErrMsg }

function HookXBegin(p: PSqlite3Vtab): i32; cdecl;
begin Inc(gBeginCount); Result := SQLITE_OK; end;

function HookXSync(p: PSqlite3Vtab): i32; cdecl;
var z: PAnsiChar;
begin
  Inc(gSyncCount);
  if gXSyncFails = 1 then begin
    gXSyncFails := 0;
    { Allocate via sqlite3Malloc (= libc malloc) so sqlite3VtabImportErrmsg's
      sqlite3_free (= libc free) balances the allocator. }
    z := PAnsiChar(sqlite3Malloc(32));
    StrPCopy(z, 'forced xSync error');
    p^.zErrMsg := z;
    Result := SQLITE_ERROR;
    Exit;
  end;
  Result := SQLITE_OK;
end;

function HookXCommit(p: PSqlite3Vtab): i32; cdecl;
begin Inc(gCommitCount); Result := SQLITE_OK; end;

function HookXRollback(p: PSqlite3Vtab): i32; cdecl;
begin Inc(gRollbackCount); Result := SQLITE_OK; end;

function HookXSavepoint(p: PSqlite3Vtab; iSav: i32): i32; cdecl;
begin
  Inc(gSavepointCount); gLastSavepointArg := iSav;
  Result := SQLITE_OK;
end;

function HookXRelease(p: PSqlite3Vtab; iSav: i32): i32; cdecl;
begin Inc(gReleaseCount); gLastSavepointArg := iSav; Result := SQLITE_OK; end;

function HookXRollbackTo(p: PSqlite3Vtab; iSav: i32): i32; cdecl;
begin Inc(gRollbackToCount); gLastSavepointArg := iSav; Result := SQLITE_OK; end;

procedure ResetHookCounters;
begin
  gBeginCount := 0; gSyncCount := 0; gCommitCount := 0; gRollbackCount := 0;
  gSavepointCount := 0; gReleaseCount := 0; gRollbackToCount := 0;
  gLastSavepointArg := -999; gXSyncFails := 0;
end;

procedure TestVtabHooks_Run(db: PTsqlite3);
var
  m:        Tsqlite3_module;
  pMod:     PVtabModule;
  pTabHk:   TCgPTable;
  pParse:   TCgPParse;
  pVT:      PVTable;
  rc:       i32;
  pSchemaT: TUtilPSchema;
  pVm:      PVdbe;
  origNStmt: i32;
begin
  WriteLn('TestVtab — Phase 6.bis.1d gate (per-statement hooks)');
  pSchemaT := TUtilPSchema(db^.aDb[0].pSchema);

  { iVersion=2 module: must be >=2 for sqlite3VtabSavepoint to dispatch. }
  FillChar(m, SizeOf(m), 0);
  m.iVersion    := 2;
  m.xCreate     := @CtorXCreate;
  m.xConnect    := @CtorXConnect;
  m.xDestroy    := @CtorXDestroy;
  m.xDisconnect := @CtorXDisconnect;
  m.xBegin      := @HookXBegin;
  m.xSync       := @HookXSync;
  m.xCommit     := @HookXCommit;
  m.xRollback   := @HookXRollback;
  m.xSavepoint  := @HookXSavepoint;
  m.xRelease    := @HookXRelease;
  m.xRollbackTo := @HookXRollbackTo;
  pMod := sqlite3VtabCreateModule(db, 'hookmod', @m, nil, nil);
  Expect(pMod <> nil, 'T35 register hookmod');

  { Attach via CallConnect — does NOT add to aVTrans, leaving sqlite3VtabBegin
    a clean slate to exercise its grow-and-add path. }
  pParse := TCgPParse(sqlite3MallocZero64(SizeOf(TCgTParse)));
  pParse^.db := db;

  pTabHk := CtorMakeTable(db, 'hk_a', 'hookmod');
  rc := sqlite3VtabCallConnect(pParse, pTabHk);
  ExpectEq(rc, SQLITE_OK, 'T36 CallConnect hk_a');
  pVT := sqlite3GetVTable(db, pTabHk);
  Expect(pVT <> nil, 'T36b VTable attached');
  ExpectEq(db^.nVTrans, 0,
    'T36c CallConnect path leaves aVTrans empty');

  { ---- T37: sqlite3VtabBegin grows aVTrans and calls xBegin. ---- }
  ResetHookCounters;
  origNStmt := db^.nStatement;
  db^.nStatement := 0;
  rc := sqlite3VtabBegin(db, pVT);
  db^.nStatement := origNStmt;
  ExpectEq(rc, SQLITE_OK, 'T37 sqlite3VtabBegin ok');
  ExpectEq(gBeginCount, 1, 'T37b xBegin fired once');
  ExpectEq(gSavepointCount, 0,
    'T37c xSavepoint NOT fired when iSvpt=0');
  ExpectEq(db^.nVTrans, 1, 'T37d nVTrans=1 after first Begin');

  { Idempotent: second Begin on same pVT short-circuits. }
  ResetHookCounters;
  rc := sqlite3VtabBegin(db, pVT);
  ExpectEq(rc, SQLITE_OK, 'T38 second Begin ok');
  ExpectEq(gBeginCount, 0, 'T38b second Begin = no-op (already in aVTrans)');

  { Begin with nil pVTab is a no-op success (vtab.c:1054). }
  rc := sqlite3VtabBegin(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T39 Begin(nil) = OK');

  { ---- T40: sqlite3VtabSync dispatches xSync per VTable ---- }
  ResetHookCounters;
  pVm := PVdbe(sqlite3MallocZero64(SizeOf(TVdbe)));
  pVm^.db := Pointer(db);
  rc := sqlite3VtabSync(db, pVm);
  ExpectEq(rc, SQLITE_OK, 'T40 sqlite3VtabSync ok');
  ExpectEq(gSyncCount, db^.nVTrans, 'T40b xSync called for each VTable');
  Expect(db^.aVTrans <> nil, 'T40c aVTrans restored after Sync');

  { xSync error → propagates with zErrMsg imported into Vdbe. }
  ResetHookCounters;
  gXSyncFails := 1;
  rc := sqlite3VtabSync(db, pVm);
  ExpectEq(rc, SQLITE_ERROR, 'T41 xSync error propagates');
  Expect(pVm^.zErrMsg <> nil, 'T41b zErrMsg imported into Vdbe');
  if pVm^.zErrMsg <> nil then
    Expect(StrComp(pVm^.zErrMsg, 'forced xSync error') = 0,
      'T41c zErrMsg text matches');
  sqlite3DbFree(db, pVm^.zErrMsg);
  pVm^.zErrMsg := nil;

  { ---- T42: sqlite3VtabSavepoint(BEGIN) dispatches xSavepoint ---- }
  ResetHookCounters;
  rc := sqlite3VtabSavepoint(db, SAVEPOINT_BEGIN, 3);
  ExpectEq(rc, SQLITE_OK, 'T42 Savepoint(BEGIN, 3) ok');
  ExpectEq(gSavepointCount, db^.nVTrans,
    'T42b xSavepoint fired for each iVersion>=2 VTable');
  ExpectEq(gLastSavepointArg, 3,
    'T42c xSavepoint received iSavepoint as-is (3)');
  Expect(pVT^.iSavepoint = 4, 'T42d pVT.iSavepoint set to iSavepoint+1');

  { ROLLBACK_TO: only fires when pVTab^.iSavepoint > iSavepoint. }
  ResetHookCounters;
  rc := sqlite3VtabSavepoint(db, SAVEPOINT_ROLLBACK, 2);
  ExpectEq(rc, SQLITE_OK, 'T43 Savepoint(ROLLBACK, 2) ok');
  ExpectEq(gRollbackToCount, db^.nVTrans,
    'T43b xRollbackTo fired (iSavepoint=4 > 2)');

  { RELEASE with iSavepoint that is NOT exceeded → xRelease NOT fired. }
  ResetHookCounters;
  rc := sqlite3VtabSavepoint(db, SAVEPOINT_RELEASE, 99);
  ExpectEq(rc, SQLITE_OK, 'T44 Savepoint(RELEASE, 99) ok');
  ExpectEq(gReleaseCount, 0,
    'T44b xRelease NOT fired (iSavepoint=4 <= 99)');

  { ---- T45: sqlite3VtabCommit drains aVTrans + fires xCommit per slot ---- }
  ResetHookCounters;
  rc := sqlite3VtabCommit(db);
  ExpectEq(rc, SQLITE_OK, 'T45 Commit ok');
  ExpectEq(gCommitCount, 1, 'T45b xCommit fired once');
  ExpectEq(db^.nVTrans, 0, 'T45c nVTrans=0 after Commit');
  Expect(db^.aVTrans = nil, 'T45d aVTrans=nil after Commit');

  { Commit unlocks each VTable in aVTrans, dropping nRef from 2→1; the
    surviving reference (held by pTab^.u.vtab.p) keeps the VTable alive
    until CallDestroy fires xDisconnect. }
  rc := sqlite3VtabCallDestroy(db, 0, 'hk_a');
  ExpectEq(rc, SQLITE_OK, 'T46 CallDestroy hk_a after Commit');

  { ---- T47: sqlite3VtabRollback parallel path ---- }
  pTabHk := CtorMakeTable(db, 'hk_b', 'hookmod');
  rc := sqlite3VtabCallConnect(pParse, pTabHk);
  ExpectEq(rc, SQLITE_OK, 'T47 CallConnect hk_b');
  pVT := sqlite3GetVTable(db, pTabHk);
  origNStmt := db^.nStatement;
  db^.nStatement := 0;
  rc := sqlite3VtabBegin(db, pVT);
  db^.nStatement := origNStmt;
  ExpectEq(rc, SQLITE_OK, 'T47b Begin hk_b');

  ResetHookCounters;
  rc := sqlite3VtabRollback(db);
  ExpectEq(rc, SQLITE_OK, 'T48 Rollback ok');
  ExpectEq(gRollbackCount, 1, 'T48b xRollback fired once');
  ExpectEq(db^.nVTrans, 0, 'T48c nVTrans=0 after Rollback');

  rc := sqlite3VtabCallDestroy(db, 0, 'hk_b');
  ExpectEq(rc, SQLITE_OK, 'T49 CallDestroy hk_b');

  { Cleanup: drop the module. }
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T50 drop hookmod');

  sqlite3DbFree(db, pVm);
  sqlite3DbFree(db, pParse);
end;

{ ============================================================
  Phase 6.bis.1e — public API entry points: sqlite3_declare_vtab,
  sqlite3_vtab_on_conflict, sqlite3_vtab_config.
  ============================================================ }

var
  gApiCtxBDeclared: i32;        { observed pCtx^.bDeclared inside xConnect }
  gApiConfigRc:     i32;        { observed sqlite3_vtab_config return inside xConnect }
  gApiConfigOp:     i32;        { which op to call sqlite3_vtab_config with }

function ApiXConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  v:    PSqlite3Vtab;
  pCtx: PVtabCtx;
begin
  GetMem(v, SizeOf(Tsqlite3_vtab));
  FillChar(v^, SizeOf(Tsqlite3_vtab), 0);
  ppVtab^ := v;

  { sqlite3_declare_vtab is the canonical way to flip bDeclared.  Use a
    minimal but real CREATE TABLE statement to drive the keyword check. }
  Inc(gConnectCount);
  Result := sqlite3_declare_vtab(db, 'CREATE TABLE x(a)');
  if Result <> SQLITE_OK then begin
    FreeMem(v);
    ppVtab^ := nil;
    Exit;
  end;

  pCtx := PVtabCtx(db^.pVtabCtx);
  if pCtx <> nil then gApiCtxBDeclared := pCtx^.bDeclared;

  { Probe sqlite3_vtab_config from inside the constructor. }
  if gApiConfigOp <> 0 then
    gApiConfigRc := sqlite3_vtab_config(db, gApiConfigOp, 1)
  else
    gApiConfigRc := -1;

  Result := SQLITE_OK;
end;

procedure TestVtabApi_Run(db: PTsqlite3);
var
  m:        Tsqlite3_module;
  pMod:     PVtabModule;
  pTab:     TCgPTable;
  rc:       i32;
  pParse:   TCgPParse;
  pVT:      PVTable;
  pSchemaT: TUtilPSchema;
  sCtx:     TVtabCtx;
begin
  WriteLn('TestVtab — Phase 6.bis.1e gate (declare_vtab / on_conflict / vtab_config)');
  pSchemaT := TUtilPSchema(db^.aDb[0].pSchema);

  { ---- T51..T56: sqlite3_declare_vtab misuse / keyword checks ---- }

  { T51: nil db → MISUSE.  No pCtx involvement. }
  rc := sqlite3_declare_vtab(nil, 'CREATE TABLE x(a)');
  ExpectEq(rc, SQLITE_MISUSE, 'T51 declare_vtab(nil db) → MISUSE');

  { T52: nil zCreateTable → MISUSE. }
  rc := sqlite3_declare_vtab(db, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T52 declare_vtab(nil sql) → MISUSE');

  { T53: bad first keyword → ERROR. }
  rc := sqlite3_declare_vtab(db, 'DROP TABLE x');
  ExpectEq(rc, SQLITE_ERROR, 'T53 non-CREATE leading keyword → ERROR');

  { T54: bad second keyword → ERROR. }
  rc := sqlite3_declare_vtab(db, 'CREATE INDEX x');
  ExpectEq(rc, SQLITE_ERROR, 'T54 CREATE without TABLE → ERROR');

  { T55: leading whitespace + comments still passes the keyword scan; with
    no active VtabCtx, it then falls through to MISUSE. }
  rc := sqlite3_declare_vtab(db,
    '  /* hi */  CREATE  -- line comment'#10'TABLE x(a)');
  ExpectEq(rc, SQLITE_MISUSE,
    'T55 spaces/comments OK, then no pVtabCtx → MISUSE');

  { ---- T56..T57: drive declare_vtab through a real xConnect callback. ---- }
  FillChar(m, SizeOf(m), 0);
  m.iVersion    := 1;
  m.xCreate     := @ApiXConnect;     { reuse to satisfy CallCreate }
  m.xConnect    := @ApiXConnect;
  m.xDestroy    := @CtorXDestroy;
  m.xDisconnect := @CtorXDisconnect;
  pMod := sqlite3VtabCreateModule(db, 'apimod', @m, nil, nil);
  Expect(pMod <> nil, 'T56a register apimod');

  pParse := TCgPParse(sqlite3MallocZero64(SizeOf(TCgTParse)));
  pParse^.db := db;

  pTab := CtorMakeTable(db, 'api_a', 'apimod');
  gConnectCount    := 0;
  gApiCtxBDeclared := -1;
  gApiConfigOp     := 0;
  rc := sqlite3VtabCallConnect(pParse, pTab);
  ExpectEq(rc, SQLITE_OK, 'T56 declare_vtab inside xConnect → OK');
  ExpectEq(gApiCtxBDeclared, 1,
    'T57 pCtx^.bDeclared=1 after sqlite3_declare_vtab');
  pVT := sqlite3GetVTable(db, pTab);
  Expect(pVT <> nil, 'T57b VTable attached after declare_vtab');

  { ---- T58: bDeclared already set → second declare_vtab → MISUSE. ---- }
  { Re-fabricate a manual VtabCtx with bDeclared=1 to exercise the path. }
  FillChar(sCtx, SizeOf(sCtx), 0);
  sCtx.pTab      := pTab;
  sCtx.pVTbl     := pVT;
  sCtx.bDeclared := 1;
  db^.pVtabCtx := @sCtx;
  rc := sqlite3_declare_vtab(db, 'CREATE TABLE x(a)');
  db^.pVtabCtx := nil;
  ExpectEq(rc, SQLITE_MISUSE,
    'T58 declare_vtab when bDeclared already set → MISUSE');

  { ---- Cleanup the connected vtab so close_v2 doesn't trip. ---- }
  rc := sqlite3VtabCallDestroy(db, 0, 'api_a');
  ExpectEq(rc, SQLITE_OK, 'T58b cleanup api_a');

  { ---- T59..T63: sqlite3_vtab_on_conflict ---- }
  db^.vtabOnConflict := 1;  { OE_Rollback }
  ExpectEq(sqlite3_vtab_on_conflict(db), 1,
    'T59 on_conflict OE_Rollback → SQLITE_ROLLBACK(1)');
  db^.vtabOnConflict := 2;  { OE_Abort }
  ExpectEq(sqlite3_vtab_on_conflict(db), 4,
    'T60 on_conflict OE_Abort → SQLITE_ABORT(4)');
  db^.vtabOnConflict := 3;  { OE_Fail }
  ExpectEq(sqlite3_vtab_on_conflict(db), 3,
    'T61 on_conflict OE_Fail → SQLITE_FAIL(3)');
  db^.vtabOnConflict := 4;  { OE_Ignore }
  ExpectEq(sqlite3_vtab_on_conflict(db), 2,
    'T62 on_conflict OE_Ignore → SQLITE_IGNORE(2)');
  db^.vtabOnConflict := 5;  { OE_Replace }
  ExpectEq(sqlite3_vtab_on_conflict(db), 5,
    'T63 on_conflict OE_Replace → SQLITE_REPLACE(5)');

  { ---- T64: sqlite3_vtab_config without an active VtabCtx → MISUSE. ---- }
  rc := sqlite3_vtab_config(db, SQLITE_VTAB_CONSTRAINT_SUPPORT, 1);
  ExpectEq(rc, SQLITE_MISUSE,
    'T64 vtab_config without pVtabCtx → MISUSE');

  { ---- T65..T68: drive vtab_config through ApiXConnect's gApiConfigOp ---- }
  pTab := CtorMakeTable(db, 'api_b', 'apimod');
  gApiConfigOp := SQLITE_VTAB_CONSTRAINT_SUPPORT;
  rc := sqlite3VtabCallConnect(pParse, pTab);
  ExpectEq(rc, SQLITE_OK, 'T65 vtab_config(CONSTRAINT_SUPPORT) ok');
  ExpectEq(gApiConfigRc, SQLITE_OK, 'T65b returned OK');
  pVT := sqlite3GetVTable(db, pTab);
  Expect((pVT <> nil) and (pVT^.bConstraint = 1),
    'T65c bConstraint=1');
  rc := sqlite3VtabCallDestroy(db, 0, 'api_b');

  pTab := CtorMakeTable(db, 'api_c', 'apimod');
  gApiConfigOp := SQLITE_VTAB_INNOCUOUS;
  rc := sqlite3VtabCallConnect(pParse, pTab);
  ExpectEq(rc, SQLITE_OK, 'T66 vtab_config(INNOCUOUS) ok');
  pVT := sqlite3GetVTable(db, pTab);
  Expect((pVT <> nil) and (pVT^.eVtabRisk = SQLITE_VTABRISK_Low),
    'T66b eVtabRisk=Low');
  rc := sqlite3VtabCallDestroy(db, 0, 'api_c');

  pTab := CtorMakeTable(db, 'api_d', 'apimod');
  gApiConfigOp := SQLITE_VTAB_DIRECTONLY;
  rc := sqlite3VtabCallConnect(pParse, pTab);
  ExpectEq(rc, SQLITE_OK, 'T67 vtab_config(DIRECTONLY) ok');
  pVT := sqlite3GetVTable(db, pTab);
  Expect((pVT <> nil) and (pVT^.eVtabRisk = SQLITE_VTABRISK_High),
    'T67b eVtabRisk=High');
  rc := sqlite3VtabCallDestroy(db, 0, 'api_d');

  pTab := CtorMakeTable(db, 'api_e', 'apimod');
  gApiConfigOp := SQLITE_VTAB_USES_ALL_SCHEMAS;
  rc := sqlite3VtabCallConnect(pParse, pTab);
  ExpectEq(rc, SQLITE_OK, 'T68 vtab_config(USES_ALL_SCHEMAS) ok');
  pVT := sqlite3GetVTable(db, pTab);
  Expect((pVT <> nil) and (pVT^.bAllSchemas = 1),
    'T68b bAllSchemas=1');
  rc := sqlite3VtabCallDestroy(db, 0, 'api_e');

  pTab := CtorMakeTable(db, 'api_f', 'apimod');
  gApiConfigOp := 9999;  { invalid op }
  rc := sqlite3VtabCallConnect(pParse, pTab);
  { Connect itself succeeds; the bad-op probe stashed MISUSE in gApiConfigRc. }
  ExpectEq(gApiConfigRc, SQLITE_MISUSE,
    'T69 vtab_config(invalid op) → MISUSE');
  rc := sqlite3VtabCallDestroy(db, 0, 'api_f');

  { Drop the API module before close. }
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T70 drop apimod');

  sqlite3DbFree(db, pParse);
end;

{ ===== Phase 6.bis.1f — overload + makewritable + eponymous ============== }

var
  gOverloadCount:    i32;
  gOverloadReturn:   i32;       { what xFindFunction returns: 0=no, 1=yes }
  gOverloadXSFunc:   Pointer;
  gOverloadPArg:     Pointer;
  gOverloadSeenName: AnsiString;

procedure FakeOverloadFn(pCtx: Pointer; argc: i32; argv: Pointer); cdecl;
begin
  { Sentinel — never actually invoked by the gate; we only check pointer
    identity inside the carved-out FuncDef. }
end;

function FindFunctionXxx(pVtab: PSqlite3Vtab; nArg: i32; zName: PAnsiChar;
  pxFunc: Pointer; ppArg: PPointer): i32; cdecl;
type PProc = ^Pointer;
begin
  Inc(gOverloadCount);
  gOverloadSeenName := AnsiString(zName);
  if gOverloadReturn <> 0 then begin
    PProc(pxFunc)^ := gOverloadXSFunc;
    ppArg^         := gOverloadPArg;
  end;
  Result := gOverloadReturn;
end;

procedure TestVtabOverload_Run(db: PTsqlite3);
var
  m:        Tsqlite3_module;
  pMod:     PVtabModule;
  pParse:   TCgPParse;
  pTab:     TCgPTable;
  pVT:      PVTable;
  pDef:     passqlite3vdbe.PTFuncDef;
  pNew:     passqlite3vdbe.PTFuncDef;
  pE:       passqlite3codegen.PExpr;
  rc:       i32;
  zFn:      AnsiString;
const
  cName = 'ovl_a';
  cMod  = 'ovlmod';
begin
  WriteLn('TestVtab — Phase 6.bis.1f gate (Overload)');

  FillChar(m, SizeOf(m), 0);
  m.iVersion      := 1;
  m.xCreate       := @CtorXConnect;     { reuse }
  m.xConnect      := @CtorXConnect;
  m.xDestroy      := @CtorXDestroy;
  m.xDisconnect   := @CtorXDisconnect;
  m.xFindFunction := @FindFunctionXxx;
  pMod := sqlite3VtabCreateModule(db, PChar(AnsiString(cMod)), @m, nil, nil);
  Expect(pMod <> nil, 'T71 register ovlmod');

  pParse := TCgPParse(sqlite3MallocZero64(SizeOf(TCgTParse)));
  pParse^.db := db;
  pTab := CtorMakeTable(db, cName, cMod);
  rc := sqlite3VtabCallConnect(pParse, pTab);
  ExpectEq(rc, SQLITE_OK, 'T71b connect ovl_a');
  pVT := sqlite3GetVTable(db, pTab);
  Expect(pVT <> nil, 'T71c VTable attached');

  zFn := 'match';
  pDef := passqlite3vdbe.PTFuncDef(
    sqlite3DbMallocZero(db, u64(SizeOf(passqlite3vdbe.TFuncDef))));
  pDef^.zName     := PAnsiChar(zFn);
  pDef^.nArg      := 2;
  pDef^.funcFlags := 0;

  { Build a fabricated TExpr of op=TK_COLUMN whose y.pTab == pTab. }
  pE := passqlite3codegen.PExpr(
    sqlite3MallocZero64(SizeOf(passqlite3codegen.TExpr)));
  pE^.op    := u8(passqlite3codegen.TK_COLUMN);
  pE^.y.pTab := pTab;

  { Case A: xFindFunction returns 0 → pDef returned unchanged. }
  gOverloadCount  := 0;
  gOverloadReturn := 0;
  pNew := sqlite3VtabOverloadFunction(db, pDef, 2, pE);
  ExpectEq(gOverloadCount, 1, 'T72 xFindFunction invoked');
  Expect(pNew = pDef, 'T72b returns pDef when xFindFunction = 0');

  { Case B: xFindFunction returns 1 with overrides → carved-out ephemeral. }
  gOverloadCount  := 0;
  gOverloadReturn := 1;
  gOverloadXSFunc := @FakeOverloadFn;
  gOverloadPArg   := Pointer(PtrUInt($DEADBEEF));
  pNew := sqlite3VtabOverloadFunction(db, pDef, 2, pE);
  ExpectEq(gOverloadCount, 1, 'T73 xFindFunction invoked second time');
  Expect(pNew <> pDef, 'T73b returns NEW FuncDef when xFindFunction = 1');
  Expect((pNew^.funcFlags and passqlite3vdbe.SQLITE_FUNC_EPHEM) <> 0,
    'T73c new FuncDef carries SQLITE_FUNC_EPHEM');
  Expect(Pointer(pNew^.xSFunc) = Pointer(@FakeOverloadFn),
    'T73d xSFunc replaced');
  Expect(pNew^.pUserData = Pointer(PtrUInt($DEADBEEF)),
    'T73e pUserData replaced');
  Expect(StrComp(pNew^.zName, PChar(zFn)) = 0, 'T73f zName preserved');
  sqlite3DbFree(db, pNew);

  { Case C: pExpr=nil → pDef returned untouched. }
  gOverloadCount := 0;
  pNew := sqlite3VtabOverloadFunction(db, pDef, 2, nil);
  Expect(pNew = pDef, 'T74 pExpr=nil → pDef');
  ExpectEq(gOverloadCount, 0, 'T74b xFindFunction NOT invoked');

  { Case D: pExpr.op != TK_COLUMN → pDef returned untouched. }
  pE^.op := u8(passqlite3codegen.TK_COLUMN) + 1;
  gOverloadCount := 0;
  pNew := sqlite3VtabOverloadFunction(db, pDef, 2, pE);
  Expect(pNew = pDef, 'T75 op != TK_COLUMN → pDef');
  ExpectEq(gOverloadCount, 0, 'T75b xFindFunction NOT invoked');
  pE^.op := u8(passqlite3codegen.TK_COLUMN);

  { Case E: a module without xFindFunction → pDef returned untouched. }
  m.xFindFunction := nil;
  gOverloadCount := 0;
  pNew := sqlite3VtabOverloadFunction(db, pDef, 2, pE);
  Expect(pNew = pDef, 'T76 module xFindFunction=nil → pDef');

  passqlite3os.sqlite3_free(pE);
  sqlite3DbFree(db, pDef);

  rc := sqlite3VtabCallDestroy(db, 0, cName);
  ExpectEq(rc, SQLITE_OK, 'T77 destroy ovl_a');
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T77b drop ovlmod');

  sqlite3DbFree(db, pParse);
end;

procedure TestVtabMakeWritable_Run(db: PTsqlite3);
var
  pParse, pTopP: TCgPParse;
  pTab1, pTab2:  TCgPTable;
  pSchemaT:      TUtilPSchema;
  apv:           PPointer;
begin
  WriteLn('TestVtab — Phase 6.bis.1f gate (MakeWritable)');
  pSchemaT := TUtilPSchema(db^.aDb[0].pSchema);

  pParse := TCgPParse(sqlite3MallocZero64(SizeOf(TCgTParse)));
  pParse^.db := db;

  pTab1 := TCgPTable(sqlite3MallocZero64(SizeOf(passqlite3codegen.TTable)));
  pTab1^.eTabType := passqlite3codegen.TABTYP_VTAB;
  pTab1^.pSchema  := passqlite3codegen.PSchema(pSchemaT);
  pTab2 := TCgPTable(sqlite3MallocZero64(SizeOf(passqlite3codegen.TTable)));
  pTab2^.eTabType := passqlite3codegen.TABTYP_VTAB;
  pTab2^.pSchema  := passqlite3codegen.PSchema(pSchemaT);

  { No pToplevel → MakeWritable should manipulate pParse itself. }
  ExpectEq(pParse^.nVtabLock, 0, 'T78 initial nVtabLock=0');
  sqlite3VtabMakeWritable(pParse, pTab1);
  ExpectEq(pParse^.nVtabLock, 1, 'T78b after first add → 1');

  { Re-adding the same pTab → no-op. }
  sqlite3VtabMakeWritable(pParse, pTab1);
  ExpectEq(pParse^.nVtabLock, 1, 'T79 duplicate add is no-op');

  { Add a second distinct pTab → grows array. }
  sqlite3VtabMakeWritable(pParse, pTab2);
  ExpectEq(pParse^.nVtabLock, 2, 'T80 distinct add → 2');
  apv := PPointer(pParse^.apVtabLock);
  Expect((apv[0] = Pointer(pTab1)) and (apv[1] = Pointer(pTab2)),
    'T80b array contents in insertion order');

  { With pToplevel set, additions go to the top-level Parse. }
  pTopP := TCgPParse(sqlite3MallocZero64(SizeOf(TCgTParse)));
  pTopP^.db := db;
  pParse^.pToplevel := pTopP;
  sqlite3VtabMakeWritable(pParse, pTab1);
  ExpectEq(pTopP^.nVtabLock, 1, 'T81 add via inner Parse lands in toplevel');
  ExpectEq(pParse^.nVtabLock, 2, 'T81b inner Parse untouched');

  { Cleanup: realloc'd via libc realloc → free with libc free. }
  passqlite3os.sqlite3_free(pParse^.apVtabLock);
  passqlite3os.sqlite3_free(pTopP^.apVtabLock);
  passqlite3os.sqlite3_free(pTab1);
  passqlite3os.sqlite3_free(pTab2);
  sqlite3DbFree(db, pParse);
  sqlite3DbFree(db, pTopP);
end;

procedure TestVtabEponymous_Run(db: PTsqlite3);
var
  m:        Tsqlite3_module;
  pMod:     PVtabModule;
  pParse:   TCgPParse;
  rc:       i32;
  pTab:     TCgPTable;
const
  cMod = 'epomod';
begin
  WriteLn('TestVtab — Phase 6.bis.1f gate (Eponymous)');

  { Module with xCreate==xConnect → eponymous-eligible. }
  FillChar(m, SizeOf(m), 0);
  m.iVersion    := 1;
  m.xCreate     := @CtorXConnect;
  m.xConnect    := @CtorXConnect;
  m.xDestroy    := @CtorXDestroy;
  m.xDisconnect := @CtorXDisconnect;
  pMod := sqlite3VtabCreateModule(db, PChar(AnsiString(cMod)), @m, nil, nil);
  Expect(pMod <> nil, 'T82 register epomod');

  pParse := TCgPParse(sqlite3MallocZero64(SizeOf(TCgTParse)));
  pParse^.db := db;
  db^.pVtabCtx := nil;

  { Make sure declare_vtab passes during the constructor. }
  gFailNextConnect := 0;
  rc := sqlite3VtabEponymousTableInit(pParse, pMod);
  ExpectEq(rc, 1, 'T82b EponymousTableInit returns 1 (success)');
  Expect(pMod^.pEpoTab <> nil, 'T82c pEpoTab populated');
  pTab := TCgPTable(pMod^.pEpoTab);
  Expect((pTab^.tabFlags and passqlite3codegen.TF_Eponymous) <> 0,
    'T83 TF_Eponymous flag set on pEpoTab');
  ExpectEq(pTab^.iPKey, -1, 'T83b iPKey = -1');
  ExpectEq(pTab^.u.vtab.nArg, 3,
    'T83c azArg has [name, schema, name] = 3 entries');

  { Second call is a no-op (returns 1, pEpoTab unchanged). }
  rc := sqlite3VtabEponymousTableInit(pParse, pMod);
  ExpectEq(rc, 1, 'T84 second EponymousTableInit returns 1');
  Expect(TCgPTable(pMod^.pEpoTab) = pTab,
    'T84b pEpoTab pointer unchanged on second call');

  { ---- T85: Clear marks Ephemeral, calls sqlite3DeleteTable, resets
    pEpoTab.  Note: passqlite3codegen.sqlite3DeleteTable today does NOT
    cascade through sqlite3VtabClear (it just frees aCol+zName+the table),
    so xDisconnect is NOT invoked at this layer.  When build.c's
    DeleteTable port lands and chains into sqlite3VtabClear, T85b should
    flip to expect gDisconnectCount=1.  Tracked in tasklist.md. ---- }
  gDisconnectCount := 0;
  sqlite3VtabEponymousTableClear(db, pMod);
  Expect(pMod^.pEpoTab = nil, 'T85 pEpoTab cleared');
  ExpectEq(gDisconnectCount, 0,
    'T85b xDisconnect NOT yet fired (DeleteTable->VtabClear unported)');

  { ---- T86: a module whose xCreate != xConnect (and xCreate != nil) is
    NOT eponymous-eligible; Init returns 0 without touching pEpoTab. ---- }
  m.xCreate  := @CtorXCreate;        { distinct from xConnect }
  m.xConnect := @CtorXConnect;
  rc := sqlite3VtabEponymousTableInit(pParse, pMod);
  ExpectEq(rc, 0, 'T86 non-eponymous module → 0');
  Expect(pMod^.pEpoTab = nil, 'T86b pEpoTab still nil');

  { ---- T87: a module with xCreate=nil (connect-only) IS eponymous. ---- }
  m.xCreate  := nil;
  m.xConnect := @CtorXConnect;
  rc := sqlite3VtabEponymousTableInit(pParse, pMod);
  ExpectEq(rc, 1, 'T87 xCreate=nil eponymous module → 1');
  Expect(pMod^.pEpoTab <> nil, 'T87b pEpoTab populated');

  { Cleanup: drop modules will run sqlite3VtabModuleUnref which asserts
    pEpoTab=nil — clear it first. }
  sqlite3VtabEponymousTableClear(db, pMod);
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T88 drop epomod');

  sqlite3DbFree(db, pParse);
end;

var
  db: PTsqlite3;
  rc: i32;
  m1, m2: Tsqlite3_module;
  pMod, pMod2: PVtabModule;
  vt: TVTable;
  vtPtr: PVTable;
  whitelist: array[0..2] of PAnsiChar;
  fakeVtab: Tsqlite3_vtab;

begin
  gPass := 0; gFail := 0; gDestroyCount := 0; gDisconnectCount := 0;
  WriteLn('TestVtab — Phase 6.bis.1a gate');

  rc := sqlite3_open_v2(':memory:', @db,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK, 'T1 open :memory:');
  Expect(db <> nil, 'T1b db non-nil');

  { ---- sqlite3VtabCreateModule directly ---- }
  FillChar(m1, SizeOf(m1), 0);
  m1.iVersion := 1;
  pMod := sqlite3VtabCreateModule(db, 'mymod1', @m1, nil, nil);
  Expect(pMod <> nil, 'T2 sqlite3VtabCreateModule returns Module');
  ExpectEq(pMod^.nRefModule, 1, 'T2b nRefModule=1');
  Expect(pMod^.pModule = @m1, 'T2c pModule set');

  { ---- replacement: should fire previous destructor exactly once ---- }
  gDestroyCount := 0;
  pMod2 := sqlite3VtabCreateModule(db, 'mymod1', @m1, nil, @DummyDestroy);
  Expect(pMod2 <> nil, 'T3 replace returns new Module');
  Expect(pMod2 <> pMod, 'T3b new pointer differs from old');
  ExpectEq(gDestroyCount, 0,
    'T3c old module had no destructor → no destructor fired');

  { Replace again — this time the previous registration HAD a destructor
    with pAux=nil.  Faithful behaviour: xDestroy(nil) is invoked. }
  gDestroyCount := 0;
  sqlite3VtabCreateModule(db, 'mymod1', @m1, nil, nil);
  ExpectEq(gDestroyCount, 1,
    'T4 replace fires xDestroy regardless of pAux (faithful)');

  { ---- public sqlite3_create_module / _v2 ---- }
  rc := sqlite3_create_module(db, 'mymod2', @m1, nil);
  ExpectEq(rc, SQLITE_OK, 'T5 sqlite3_create_module ok');

  rc := sqlite3_create_module_v2(db, 'mymod2', @m1, nil, @DummyDestroy);
  ExpectEq(rc, SQLITE_OK, 'T6 sqlite3_create_module_v2 replace');

  { ---- MISUSE paths ---- }
  rc := sqlite3_create_module(nil, 'foo', @m1, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T7 nil db → MISUSE');

  rc := sqlite3_create_module(db, nil, @m1, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T8 nil zName → MISUSE');

  { ---- sqlite3_drop_modules: whitelist preserves listed names ---- }
  { State: db has 'mymod1' (no destructor) and 'mymod2' (DummyDestroy). }
  whitelist[0] := 'mymod1';
  whitelist[1] := nil;
  gDestroyCount := 0;
  rc := sqlite3_drop_modules(db, @whitelist[0]);
  ExpectEq(rc, SQLITE_OK, 'T9 drop_modules whitelist returns OK');
  ExpectEq(gDestroyCount, 1,
    'T9b mymod2 dropped → DummyDestroy fired exactly once');

  { drop_modules with nil whitelist drops everything. }
  gDestroyCount := 0;
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T10 drop_modules(nil) returns OK');
  ExpectEq(gDestroyCount, 0,
    'T10b only mymod1 remained, no destructor');

  { Empty registry is fine. }
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T11 drop_modules on empty registry');

  rc := sqlite3_drop_modules(nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T12 drop_modules nil db → MISUSE');

  { ---- Lock / Unlock semantics on a fabricated VTable ---- }
  { Build a VTable with nRef=1 by hand.  Skip the real sqlite3_vtab pointer
    so xDisconnect is not invoked unless we wire it. }
  FillChar(vt, SizeOf(vt), 0);
  vt.db   := db;
  vt.nRef := 1;
  { Lock takes us to nRef=2; one Unlock returns to 1; we never let it hit
    zero (that path requires a real Module + sqlite3DbFree of the heap-
    allocated VTable, which only the constructor lifecycle produces). }
  sqlite3VtabLock(@vt);
  ExpectEq(vt.nRef, 2, 'T13 sqlite3VtabLock increments nRef');
  sqlite3VtabLock(@vt);
  ExpectEq(vt.nRef, 3, 'T13b nested lock');

  { Manual decrement to mirror Unlock without freeing — keep nRef >= 1. }
  Dec(vt.nRef); Dec(vt.nRef);
  ExpectEq(vt.nRef, 1, 'T13c manual back to 1');

  { ---- Hook xDisconnect through a heap-allocated VTable so Unlock can
    actually drop nRef to 0 and walk the disconnect path.  We register a
    module so VTable.pMod is real and sqlite3VtabModuleUnref can free it. ---- }
  FillChar(m2, SizeOf(m2), 0);
  m2.iVersion    := 1;
  m2.xDisconnect := @DummyDisconnect;
  pMod := sqlite3VtabCreateModule(db, 'mymod3', @m2, nil, nil);
  Expect(pMod <> nil, 'T14 register module with xDisconnect');

  { Allocate a sqlite3_vtab + VTable on the heap.  The sqlite3_vtab must
    point at our module so sqlite3VtabUnlock can dispatch xDisconnect. }
  FillChar(fakeVtab, SizeOf(fakeVtab), 0);
  fakeVtab.pModule := @m2;
  vtPtr := PVTable(sqlite3MallocZero64(SizeOf(TVTable)));
  Expect(vtPtr <> nil, 'T14b alloc VTable');
  vtPtr^.db    := db;
  vtPtr^.nRef  := 1;
  vtPtr^.pMod  := pMod;
  vtPtr^.pVtab := @fakeVtab;
  Inc(pMod^.nRefModule);  { mirror constructor's nRefModule++ on attach }

  gDisconnectCount := 0;
  sqlite3VtabUnlock(vtPtr);  { nRef→0 → xDisconnect → ModuleUnref → DbFree }
  ExpectEq(gDisconnectCount, 1,
    'T14c xDisconnect fired exactly once on nRef→0');

  { Drop the now-orphan module to clear the registry before close. }
  gDestroyCount := 0;
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'T15 drop registry before close');

  { ---- Phase 6.bis.1b — parser-hook leaf helpers ---- }
  TestVtabParser_Run(db);

  { ---- Phase 6.bis.1c — constructor lifecycle ---- }
  TestVtabCtor_Run(db);

  { ---- Phase 6.bis.1d — per-statement transaction hooks ---- }
  TestVtabHooks_Run(db);

  { ---- Phase 6.bis.1e — public API entry points ---- }
  TestVtabApi_Run(db);

  { ---- Phase 6.bis.1f — overload + writable + eponymous tables ---- }
  TestVtabOverload_Run(db);
  TestVtabMakeWritable_Run(db);
  TestVtabEponymous_Run(db);

  rc := sqlite3_close_v2(db);
  ExpectEq(rc, SQLITE_OK, 'T16 close_v2');

  WriteLn;
  WriteLn('TestVtab: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail <> 0 then Halt(1);
end.
