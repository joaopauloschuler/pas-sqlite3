{ Smoke probe for passqlite3vfstrace.

  Registers the "vfstrace" shim VFS atop the default unix VFS, opens a
  fresh on-disk database through it, runs CREATE/INSERT/SELECT, then
  verifies the captured trace contains the expected method labels.
}
{$I passqlite3.inc}
program DiagVfstrace;

uses
  ctypes, SysUtils,
  passqlite3types, passqlite3os, passqlite3util, passqlite3pcache,
  passqlite3pager, passqlite3wal, passqlite3btree, passqlite3vdbe,
  passqlite3codegen, passqlite3parser, passqlite3vtab, passqlite3main,
  passqlite3vfstrace;

var
  buf : AnsiString;

function CapOut(zMsg: PAnsiChar; pAppData: Pointer): cint; cdecl;
begin
  if zMsg <> nil then buf := buf + StrPas(zMsg);
  Result := 0;
end;

function HasNeedle(const haystack, needle: AnsiString): Boolean;
begin
  Result := Pos(needle, haystack) > 0;
end;

var
  rc       : cint;
  db       : Psqlite3db;
  pErr     : PAnsiChar;
  zPath    : AnsiString;
  ok       : Boolean;
begin
  buf := '';
  sqlite3_initialize;
  rc := vfstrace_register('vfstrace', nil, @CapOut, nil, 0);
  if rc <> SQLITE_OK then begin
    WriteLn('vfstrace_register failed rc=', rc);
    Halt(1);
  end;
  WriteLn('vfstrace registered.');

  zPath := '/tmp/diagvfstrace_' + IntToStr(GetProcessId) + '.db';
  if FileExists(zPath) then DeleteFile(zPath);

  rc := sqlite3_open_v2(PAnsiChar(zPath), @db,
    SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, 'vfstrace');
  if rc <> SQLITE_OK then begin
    WriteLn('sqlite3_open_v2 failed rc=', rc);
    Halt(1);
  end;
  WriteLn('opened ', zPath, ' through vfstrace');

  pErr := nil;
  sqlite3_exec(db,
    'CREATE TABLE t(a INTEGER, b TEXT);'#10 +
    'INSERT INTO t VALUES (1, ''one''), (2, ''two'');'#10 +
    'SELECT count(*) FROM t;',
    nil, nil, @pErr);
  if pErr <> nil then begin
    WriteLn('exec error: ', StrPas(pErr));
    sqlite3_free(pErr);
  end;

  sqlite3_close(db);

  WriteLn('--- captured trace (first 800 bytes) ---');
  if Length(buf) > 800 then
    WriteLn(Copy(buf, 1, 800), '...')
  else
    WriteLn(buf);
  WriteLn('--- end ---');

  ok := True;
  if not HasNeedle(buf, 'vfstrace.xOpen') then begin
    WriteLn('FAIL: missing xOpen line'); ok := False;
  end;
  if not HasNeedle(buf, '.xWrite(') then begin
    WriteLn('FAIL: missing xWrite line'); ok := False;
  end;
  if not HasNeedle(buf, '.xClose(') then begin
    WriteLn('FAIL: missing xClose line'); ok := False;
  end;
  if not HasNeedle(buf, 'enabled_for') then begin
    WriteLn('FAIL: missing enabled_for line'); ok := False;
  end;

  vfstrace_unregister('vfstrace');
  if FileExists(zPath) then DeleteFile(zPath);

  if ok then begin
    WriteLn('DiagVfstrace PASSED.');
    Halt(0);
  end else begin
    WriteLn('DiagVfstrace FAILED.');
    Halt(2);
  end;
end.
