{$I ../passqlite3.inc}
program TestInitShutdown;

{
  Phase 8.5 gate — exercise sqlite3_initialize / sqlite3_shutdown.

  Verified properties:
    * Idempotent initialize: second call after first succeeds is a no-op.
    * Initialize sets isInit / isMutexInit / isMallocInit / isPCacheInit.
    * Shutdown clears all the same flags and is safe to call twice.
    * Shutdown when never initialized is a harmless no-op.
    * Builtin-functions hash is populated after initialize.
    * Init → open db → step (smoke) → close → shutdown round-trips.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

function BuiltinHashHasEntry: Boolean;
var
  i: i32;
begin
  Result := False;
  for i := 0 to High(sqlite3BuiltinFunctions.a) do
    if sqlite3BuiltinFunctions.a[i] <> nil then begin
      Result := True;
      Exit;
    end;
end;

var
  rc: i32;
  db: PTsqlite3;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestInitShutdown — Phase 8.5 gate');

  { Force a clean slate.  The test suite running before us may have left
    isInit non-zero via openDatabase's lazy init path. }
  rc := sqlite3_shutdown;
  ExpectEq(rc, SQLITE_OK, 'T1 shutdown (clean slate, harmless)');
  ExpectEq(sqlite3GlobalConfig.isInit,        0, 'T1b isInit=0');
  ExpectEq(sqlite3GlobalConfig.isMutexInit,   0, 'T1c isMutexInit=0');
  ExpectEq(sqlite3GlobalConfig.isMallocInit,  0, 'T1d isMallocInit=0');
  ExpectEq(sqlite3GlobalConfig.isPCacheInit,  0, 'T1e isPCacheInit=0');

  { First initialize. }
  rc := sqlite3_initialize;
  ExpectEq(rc, SQLITE_OK, 'T2 initialize ok');
  ExpectEq(sqlite3GlobalConfig.isInit,        1, 'T2b isInit=1');
  ExpectEq(sqlite3GlobalConfig.isMutexInit,   1, 'T2c isMutexInit=1');
  ExpectEq(sqlite3GlobalConfig.isMallocInit,  1, 'T2d isMallocInit=1');
  ExpectEq(sqlite3GlobalConfig.isPCacheInit,  1, 'T2e isPCacheInit=1');
  Expect(BuiltinHashHasEntry, 'T2f sqlite3BuiltinFunctions populated');
  Expect(sqlite3GlobalConfig.pInitMutex = nil,
         'T2g pInitMutex released after init returns (nRefInitMutex=0)');
  ExpectEq(sqlite3GlobalConfig.inProgress,    0, 'T2h inProgress=0 after init');

  { Idempotent second call. }
  rc := sqlite3_initialize;
  ExpectEq(rc, SQLITE_OK, 'T3 initialize idempotent');
  ExpectEq(sqlite3GlobalConfig.isInit,        1, 'T3b still isInit=1');

  { Open / close round-trip after explicit initialize. }
  db := nil;
  rc := sqlite3_open_v2(':memory:', @db,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK, 'T4 open :memory: post-init');
  Expect(db <> nil, 'T4b db non-nil');
  rc := sqlite3_close(db);
  ExpectEq(rc, SQLITE_OK, 'T4c close');

  { Shutdown clears all subsystems. }
  rc := sqlite3_shutdown;
  ExpectEq(rc, SQLITE_OK, 'T5 shutdown ok');
  ExpectEq(sqlite3GlobalConfig.isInit,        0, 'T5b isInit=0');
  ExpectEq(sqlite3GlobalConfig.isMutexInit,   0, 'T5c isMutexInit=0');
  ExpectEq(sqlite3GlobalConfig.isMallocInit,  0, 'T5d isMallocInit=0');
  ExpectEq(sqlite3GlobalConfig.isPCacheInit,  0, 'T5e isPCacheInit=0');

  { Shutdown twice is harmless. }
  rc := sqlite3_shutdown;
  ExpectEq(rc, SQLITE_OK, 'T6 shutdown idempotent');

  { Re-initialize after shutdown — full lifecycle round-trip. }
  rc := sqlite3_initialize;
  ExpectEq(rc, SQLITE_OK, 'T7 re-initialize');
  ExpectEq(sqlite3GlobalConfig.isInit,        1, 'T7b isInit=1');

  rc := sqlite3_shutdown;
  ExpectEq(rc, SQLITE_OK, 'T8 final shutdown');

  WriteLn;
  WriteLn('Summary: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail <> 0 then Halt(1);
end.
