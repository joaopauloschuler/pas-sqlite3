{
  DiagVfslog — smoke test for the vfslog VFS shim
  (passqlite3vfslog.pas, port of ../sqlite3/ext/misc/vfslog.c).

  Steps:
    (1) Register the vfslog VFS — it becomes the new default.
    (2) Open a fresh database and run a CREATE/INSERT/SELECT mix.
    (3) Close the connection, find the generated -debuglog-NNN file,
        and confirm it contains a non-zero number of CSV records.
    (4) Confirm the IDENT, OPEN, READ, WRITE, CLOSE, FILESIZE opcodes
        all show up in the trace (best-effort substring scan — the
        upstream format is "tStart,tElapsed,opcode,...").
}
{$I passqlite3.inc}
program DiagVfslog;

uses
  SysUtils,
  Classes,
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
  passqlite3vfslog;

const
  TestPath = '/tmp/diag_vfslog_test.db';

var
  fail: Integer = 0;

procedure Check(cond: Boolean; const msg: AnsiString);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(fail);
  end else WriteLn('ok  : ', msg);
end;

function FindLatestDebugLog(const dbPath: AnsiString): AnsiString;
var
  res    : TStringList;
  baseN  : AnsiString;
  i      : Integer;
  candidate : AnsiString;
  best, bestStat : Int64;
  bestPath : AnsiString;
  st     : TFileStream;
  dir    : AnsiString;
  fname  : AnsiString;
  sr     : TSearchRec;
begin
  Result := '';
  bestStat := -1;
  bestPath := '';
  dir   := ExtractFilePath(dbPath);
  baseN := ExtractFileName(dbPath) + '-debuglog-';
  if FindFirst(dir + baseN + '*', faAnyFile, sr) = 0 then begin
    repeat
      candidate := dir + sr.Name;
      try
        st := TFileStream.Create(candidate, fmOpenRead or fmShareDenyNone);
        try
          best := st.Size;
        finally st.Free; end;
        if best > bestStat then begin
          bestStat := best;
          bestPath := candidate;
        end;
      except end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  Result := bestPath;
end;

function FileContains(const path, needle: AnsiString): Boolean;
var
  st  : TFileStream;
  buf : AnsiString;
begin
  Result := False;
  if not FileExists(path) then Exit;
  st := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(buf, st.Size);
    if st.Size > 0 then st.ReadBuffer(buf[1], st.Size);
  finally st.Free; end;
  Result := Pos(needle, buf) > 0;
end;

procedure DeleteOldLogs(const dbPath: AnsiString);
var
  dir, baseN, candidate : AnsiString;
  sr : TSearchRec;
begin
  dir   := ExtractFilePath(dbPath);
  baseN := ExtractFileName(dbPath) + '-debuglog-';
  if FindFirst(dir + baseN + '*', faAnyFile, sr) = 0 then begin
    repeat
      candidate := dir + sr.Name;
      DeleteFile(candidate);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

var
  db    : PTsqlite3;
  rc    : i32;
  pErr  : PAnsiChar;
  pStmt : Pointer;
  logPath : AnsiString;

begin
  WriteLn('DiagVfslog');
  WriteLn('----------');

  rc := sqlite3_initialize;
  Check(rc = SQLITE_OK, 'sqlite3_initialize OK');

  if FileExists(TestPath) then DeleteFile(TestPath);
  DeleteOldLogs(TestPath);

  { Register vfslog as new default VFS. }
  rc := sqlite3_register_vfslog(nil);
  Check(rc = SQLITE_OK, 'sqlite3_register_vfslog returns SQLITE_OK');

  rc := sqlite3_open_v2(TestPath, @db,
                        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE,
                        'vfslog');
  Check(rc = SQLITE_OK, 'sqlite3_open_v2(...,"vfslog") OK');

  pErr := nil;
  rc := sqlite3_exec(db,
    'CREATE TABLE t(x INTEGER PRIMARY KEY, s TEXT);'#10 +
    'INSERT INTO t VALUES(1,''alpha''),(2,''beta''),(3,''gamma'');',
    nil, nil, @pErr);
  if pErr <> nil then begin
    WriteLn('  exec error: ', pErr);
    sqlite3_free(pErr); pErr := nil;
  end;
  Check(rc = SQLITE_OK, 'CREATE/INSERT under vfslog');

  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT count(*) FROM t', -1, @pStmt, nil);
  Check(rc = SQLITE_OK, 'prepare SELECT count(*)');
  if rc = SQLITE_OK then begin
    rc := sqlite3_step(pStmt);
    Check(rc = SQLITE_ROW, 'step yields row');
    Check(sqlite3_column_int(pStmt, 0) = 3, 'count(*) = 3');
    sqlite3_finalize(pStmt);
  end;

  sqlite3_close(db);

  { Locate the generated debuglog file and verify content. }
  logPath := FindLatestDebugLog(TestPath);
  Check(logPath <> '', 'debuglog file produced');
  if logPath = '' then begin
    WriteLn;
    WriteLn('DiagVfslog FAILED (', fail, ' check(s)).');
    Halt(1);
  end;
  WriteLn('  log file: ', logPath);

  Check(FileContains(logPath, ',IDENT,'),    'IDENT line present');
  Check(FileContains(logPath, ',OPEN,'),     'OPEN line present');
  Check(FileContains(logPath, ',READ,'),     'READ line present');
  Check(FileContains(logPath, ',WRITE,'),    'WRITE line present');
  Check(FileContains(logPath, ',CLOSE,'),    'CLOSE line present');
  Check(FileContains(logPath, ',FILESIZE,'), 'FILESIZE line present');

  { Cleanup. }
  DeleteFile(TestPath);
  DeleteOldLogs(TestPath);

  if fail = 0 then begin
    WriteLn;
    WriteLn('DiagVfslog PASSED.');
    Halt(0);
  end else begin
    WriteLn;
    WriteLn('DiagVfslog FAILED (', fail, ' check(s)).');
    Halt(1);
  end;
end.
