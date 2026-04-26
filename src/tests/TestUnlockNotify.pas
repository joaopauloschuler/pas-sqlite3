{$I ../passqlite3.inc}
program TestUnlockNotify;

{
  Phase 8.8 gate — exercise sqlite3_unlock_notify (notify.c shim).

  Build configuration leaves SQLITE_ENABLE_UNLOCK_NOTIFY off, so the
  port provides a tiny shim that:
    * MISUSE on db=nil
    * No-op (OK) when xNotify=nil
    * Fires xNotify(&pArg, 1) immediately when xNotify<>nil — there
      is never a blocking peer in a no-shared-cache build.

    T1 unlock_notify(db=nil, xNotify=nil)         -> SQLITE_MISUSE
    T2 unlock_notify(db=nil, xNotify<>nil)        -> SQLITE_MISUSE
    T3 unlock_notify(db, xNotify=nil)             -> SQLITE_OK, no fire
    T4 unlock_notify(db, xNotify<>nil, pArg=A)    -> SQLITE_OK, fired once
                                                     with apArg^=A, nArg=1
    T5 unlock_notify(db, xNotify, pArg=B) twice   -> fires twice (each call
                                                     is independent in this
                                                     shim — there is no
                                                     deferred queue)
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
  gFireCount  : i32;
  gLastArg    : Pointer;
  gLastNArg   : i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

procedure NotifyCB(apArg: PPointer; nArg: i32); cdecl;
begin
  Inc(gFireCount);
  gLastNArg := nArg;
  if (apArg <> nil) and (nArg >= 1) then
    gLastArg := apArg^
  else
    gLastArg := nil;
end;

var
  db: PTsqlite3;
  rc: i32;
  tagA, tagB: i32;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestUnlockNotify — Phase 8.8 sqlite3_unlock_notify');

  db := nil;
  rc := sqlite3_open(':memory:', @db);
  ExpectEq(rc, SQLITE_OK, 'open(:memory:)');
  if (rc <> SQLITE_OK) or (db = nil) then begin
    WriteLn('  open failed — aborting'); Halt(1);
  end;

  { T1 — db=nil, xNotify=nil. }
  rc := sqlite3_unlock_notify(nil, nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T1 db=nil,xNotify=nil');

  { T2 — db=nil, xNotify<>nil (must NOT be invoked). }
  gFireCount := 0;
  rc := sqlite3_unlock_notify(nil, @NotifyCB, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T2 db=nil,xNotify<>nil rc');
  ExpectEq(gFireCount, 0,     'T2 xNotify must not fire on MISUSE');

  { T3 — xNotify=nil clears (no-op). }
  gFireCount := 0;
  rc := sqlite3_unlock_notify(db, nil, Pointer(PtrUInt($DEAD)));
  ExpectEq(rc, SQLITE_OK, 'T3 xNotify=nil clears');
  ExpectEq(gFireCount, 0, 'T3 no fire when clearing');

  { T4 — fires immediately with a one-element apArg. }
  gFireCount := 0; gLastArg := nil; gLastNArg := -1;
  tagA := $A1A1A1A1;
  rc := sqlite3_unlock_notify(db, @NotifyCB, @tagA);
  ExpectEq(rc, SQLITE_OK,         'T4 rc');
  ExpectEq(gFireCount, 1,         'T4 fired once');
  ExpectEq(gLastNArg, 1,          'T4 nArg=1');
  Expect(gLastArg = @tagA,        'T4 apArg^=&tagA');

  { T5 — second call fires again (no deferred queue in this shim). }
  tagB := $B2B2B2B2;
  rc := sqlite3_unlock_notify(db, @NotifyCB, @tagB);
  ExpectEq(rc, SQLITE_OK,    'T5 rc');
  ExpectEq(gFireCount, 2,    'T5 fired again');
  Expect(gLastArg = @tagB,   'T5 apArg^=&tagB');

  ExpectEq(sqlite3_close(db), SQLITE_OK, 'close');

  WriteLn;
  WriteLn('TestUnlockNotify summary: ', gPass, ' pass, ', gFail, ' fail');
  if gFail = 0 then Halt(0) else Halt(1);
end.
