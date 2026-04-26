{$I ../passqlite3.inc}
program TestRegistration;

{
  Phase 8.3 gate — exercise sqlite3_create_function / _create_collation /
  _create_module wiring against an open db.

  These tests verify that registration succeeds, MISUSE is returned for
  bad inputs, and that re-registering replaces the previous entry without
  leaking destructor calls.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

var
  gPass, gFail: i32;
  gDestroyCallCount: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

{ Dummy callbacks for registration. }
procedure DummySFunc(ctx: Pointer; n: i32; argv: Pointer); cdecl;
begin
end;

function DummyCollate(p: Pointer; n1: i32; z1: Pointer; n2: i32; z2: Pointer): i32; cdecl;
begin Result := 0; end;

procedure DummyDestroy(p: Pointer); cdecl;
begin Inc(gDestroyCallCount); end;

var
  db:  PTsqlite3;
  rc:  i32;
  dummyModule: array[0..31] of Byte;  { fake sqlite3_module — content irrelevant }

begin
  gPass := 0; gFail := 0; gDestroyCallCount := 0;
  WriteLn('TestRegistration — Phase 8.3 gate');

  rc := sqlite3_open_v2(':memory:', @db,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK, 'T1 open :memory:');
  Expect(db <> nil, 'T1b db non-nil');

  { ---------------- create_function ---------------- }
  rc := sqlite3_create_function(db, 'myfunc', 1, SQLITE_UTF8, nil,
          @DummySFunc, nil, nil);
  ExpectEq(rc, SQLITE_OK, 'T2 create_function ok');

  { Bad nArg → MISUSE }
  rc := sqlite3_create_function(db, 'myfunc', -2, SQLITE_UTF8, nil,
          @DummySFunc, nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T3 create_function bad nArg');

  { Re-registering with v2 + xDestroy: prior call had no destructor. }
  rc := sqlite3_create_function_v2(db, 'myfunc', 1, SQLITE_UTF8, nil,
          @DummySFunc, nil, nil, @DummyDestroy);
  ExpectEq(rc, SQLITE_OK, 'T4 create_function_v2 with destructor');

  { Re-registering same name+nArg+enc: previous destructor must fire. }
  gDestroyCallCount := 0;
  rc := sqlite3_create_function(db, 'myfunc', 1, SQLITE_UTF8, nil,
          @DummySFunc, nil, nil);
  ExpectEq(rc, SQLITE_OK, 'T5 create_function replace');
  ExpectEq(gDestroyCallCount, 1, 'T5b prior destructor fired exactly once');

  { create_function on null db → MISUSE }
  rc := sqlite3_create_function(nil, 'x', 0, SQLITE_UTF8, nil,
          @DummySFunc, nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T6 create_function nil db');

  { ---------------- create_collation ---------------- }
  rc := sqlite3_create_collation(db, 'mycoll', SQLITE_UTF8, nil, @DummyCollate);
  ExpectEq(rc, SQLITE_OK, 'T7 create_collation ok');

  { Re-registering same name → also OK (no active vms). }
  rc := sqlite3_create_collation_v2(db, 'mycoll', SQLITE_UTF8, nil,
          @DummyCollate, nil);
  ExpectEq(rc, SQLITE_OK, 'T8 create_collation_v2 replace');

  { Bogus encoding → MISUSE. }
  rc := sqlite3_create_collation(db, 'badenc', 99, nil, @DummyCollate);
  ExpectEq(rc, SQLITE_MISUSE, 'T9 create_collation bad encoding');

  { zName nil → MISUSE. }
  rc := sqlite3_create_collation(db, nil, SQLITE_UTF8, nil, @DummyCollate);
  ExpectEq(rc, SQLITE_MISUSE, 'T10 create_collation nil name');

  { collation_needed sets db hooks; no observable side effects in this
    Phase 8.3 cut, just verify it returns OK. }
  rc := sqlite3_collation_needed(db, nil, nil);
  ExpectEq(rc, SQLITE_OK, 'T11 collation_needed clears hook');

  { ---------------- create_module ---------------- }
  FillChar(dummyModule, SizeOf(dummyModule), 0);
  rc := sqlite3_create_module(db, 'mymod', @dummyModule, nil);
  ExpectEq(rc, SQLITE_OK, 'T12 create_module ok');

  { Re-register same name with destructor: should replace and leave
    previous one disposed.  No destructor on the first registration, so
    gDestroyCallCount stays the same. }
  gDestroyCallCount := 0;
  rc := sqlite3_create_module_v2(db, 'mymod', @dummyModule, nil, @DummyDestroy);
  ExpectEq(rc, SQLITE_OK, 'T13 create_module_v2 replace');

  { Re-register same name a third time: the previous module's xDestroy
    is invoked exactly once with pAux (=nil here).  Phase 6.bis.1a swaps
    the inline pAux-guarded stub for the faithful sqlite3VtabModuleUnref
    path, which always calls xDestroy regardless of pAux.  DummyDestroy
    increments gDestroyCallCount unconditionally. }
  rc := sqlite3_create_module(db, 'mymod', @dummyModule, nil);
  ExpectEq(rc, SQLITE_OK, 'T14 create_module replace v2 entry');
  ExpectEq(gDestroyCallCount, 1,
    'T14b destructor called once (faithful vtab.c behaviour)');

  { create_module nil name → MISUSE. }
  rc := sqlite3_create_module(db, nil, @dummyModule, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T15 create_module nil name');

  rc := sqlite3_close_v2(db);
  ExpectEq(rc, SQLITE_OK, 'T16 close_v2');

  WriteLn;
  WriteLn('TestRegistration: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail <> 0 then Halt(1);
end.
