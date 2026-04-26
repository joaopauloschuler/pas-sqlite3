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

  rc := sqlite3_close_v2(db);
  ExpectEq(rc, SQLITE_OK, 'T16 close_v2');

  WriteLn;
  WriteLn('TestVtab: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail <> 0 then Halt(1);
end.
