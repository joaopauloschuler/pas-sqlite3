{
  DiagAppendvfs — smoke test for the appendvfs VFS shim
  (passqlite3appendvfs.pas, port of ../sqlite3/ext/misc/appendvfs.c).

  Steps:
    (1) Create a prefix file with non-DB content.
    (2) Open via "apndvfs" with SQLITE_OPEN_CREATE and create a small
        table.
    (3) Close and re-open; verify the rows survive and the prefix is
        intact at the head of the file.
    (4) Verify the trailing append-mark "Start-Of-SQLite3-NNNNNNNN" is
        present.
}
{$I passqlite3.inc}
program DiagAppendvfs;

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser,
  passqlite3vtab,
  passqlite3main,
  passqlite3appendvfs;

const
  PrefixText = 'THIS-IS-A-PREFIX-NOT-A-DATABASE-PADDING'#10;
  TestPath   = '/tmp/diag_apnd_test.bin';

var
  fail: Integer = 0;

procedure Check(cond: Boolean; const msg: AnsiString);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(fail);
  end else WriteLn('ok  : ', msg);
end;

procedure WritePrefix;
var f: file;
begin
  AssignFile(f, TestPath);
  Rewrite(f, 1);
  BlockWrite(f, PrefixText[1], Length(PrefixText));
  CloseFile(f);
end;

function FileSize64(const path: AnsiString): Int64;
var f: file;
begin
  AssignFile(f, path);
  Reset(f, 1);
  Result := FileSize(f);
  CloseFile(f);
end;

function HasAppendMark: Boolean;
var
  f    : file;
  buf  : array[0..24] of Byte;
  prefx: AnsiString;
  i    : Integer;
begin
  AssignFile(f, TestPath);
  Reset(f, 1);
  Seek(f, FileSize(f) - 25);
  BlockRead(f, buf[0], 25);
  CloseFile(f);
  prefx := 'Start-Of-SQLite3-';
  Result := True;
  for i := 1 to Length(prefx) do
    if buf[i-1] <> Byte(prefx[i]) then Exit(False);
end;

var
  db   : PTsqlite3;
  rc   : i32;
  pErr : PAnsiChar;
  pStmt: Pointer;
  cnt  : Integer;
  txt  : PAnsiChar;
  f    : file;
  head : array[0..Length(PrefixText)-1] of Byte;
  cmpRc: Integer;
begin
  WriteLn('DiagAppendvfs');
  WriteLn('-------------');

  { Step 0 — bootstrap, then register the appendvfs shim. }
  rc := sqlite3_initialize;
  Check(rc = SQLITE_OK, 'sqlite3_initialize returns SQLITE_OK');
  rc := sqlite3AppendvfsInit(nil);
  Check(rc = SQLITE_OK, 'sqlite3AppendvfsInit returns SQLITE_OK');

  { Step 1 — fresh prefix file. }
  if FileExists(TestPath) then DeleteFile(TestPath);
  WritePrefix;

  { Step 2 — open via apndvfs with CREATE flag and write rows. }
  rc := sqlite3_open_v2(TestPath, @db,
                        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE,
                        'apndvfs');
  Check(rc = SQLITE_OK, 'sqlite3_open_v2(apndvfs, CREATE) ok');

  pErr := nil;
  rc := sqlite3_exec(db,
    'CREATE TABLE t(x INTEGER PRIMARY KEY, s TEXT);'#10 +
    'INSERT INTO t VALUES(1, ''alpha''),(2, ''beta''),(3, ''gamma'');',
    nil, nil, @pErr);
  if pErr <> nil then begin
    WriteLn('exec error: ', pErr);
    sqlite3_free(pErr);
  end;
  Check(rc = SQLITE_OK, 'CREATE/INSERT via apndvfs');

  rc := sqlite3_close(db);
  Check(rc = SQLITE_OK, 'close after writes');

  { Step 3 — verify file size grew past prefix and append mark exists. }
  Check(FileSize64(TestPath) > Length(PrefixText) + 4096,
        'file extended beyond prefix');
  Check(HasAppendMark, 'trailing Start-Of-SQLite3- marker present');

  { Step 4 — re-open read-only via apndvfs and read back. }
  rc := sqlite3_open_v2(TestPath, @db, SQLITE_OPEN_READWRITE, 'apndvfs');
  Check(rc = SQLITE_OK, 're-open via apndvfs ok');
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT count(*), max(s) FROM t', -1,
                           @pStmt, nil);
  if rc <> SQLITE_OK then
    WriteLn('  prepare error: ', sqlite3_errmsg(db));
  Check(rc = SQLITE_OK, 'prepare SELECT');
  if rc = SQLITE_OK then begin
    rc := sqlite3_step(pStmt);
    Check(rc = SQLITE_ROW, 'step yields row');
    cnt := sqlite3_column_int(pStmt, 0);
    txt := sqlite3_column_text(pStmt, 1);
    Check(cnt = 3, 'row count = 3');
    Check((txt <> nil) and (StrComp(txt, 'gamma') = 0), 'max(s) = gamma');
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);

  { Step 5 — prefix must still match. }
  AssignFile(f, TestPath);
  Reset(f, 1);
  BlockRead(f, head[0], Length(PrefixText));
  CloseFile(f);
  cmpRc := CompareByte(head[0], PrefixText[1], Length(PrefixText));
  Check(cmpRc = 0, 'prefix bytes preserved at file head');

  if fail = 0 then begin
    WriteLn;
    WriteLn('DiagAppendvfs PASSED.');
    Halt(0);
  end else begin
    WriteLn;
    WriteLn('DiagAppendvfs FAILED (', fail, ' check(s)).');
    Halt(1);
  end;
end.
