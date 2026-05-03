{$I ../passqlite3.inc}
program DiagDbFileObject;
{ Differential probe for sqlite3_database_file_object (pager.c:5090).
  Open a temporary on-disk database, fetch its filename via
  sqlite3_db_filename, walk back to the Pager via sqlite3_database_file_object,
  and verify that the returned sqlite3_file* matches the one the pager
  reports via sqlite3PagerFile(sqlite3BtreePager(...)). }
uses
  SysUtils,
  passqlite3types, passqlite3os, passqlite3util,
  passqlite3pager, passqlite3btree, passqlite3internal,
  passqlite3vdbe, passqlite3codegen, passqlite3main;

var
  db   : PTsqlite3;
  zFn  : PAnsiChar;
  pf   : Psqlite3_file;
  pBt  : PBtree;
  pPgr : PPager;
  pfRef: Psqlite3_file;
  tmp  : string;
begin
  tmp := SysUtils.GetTempDir(False) + 'pas_dbfile_' +
         IntToStr(GetProcessID) + '.db';
  SysUtils.DeleteFile(tmp);

  db := nil;
  if sqlite3_open(PAnsiChar(tmp), @db) <> 0 then begin
    WriteLn('FAIL open'); Halt(1);
  end;

  { Force the pager to fully open by running a trivial pragma. }
  sqlite3_exec(db, 'PRAGMA user_version=1', nil, nil, nil);

  zFn := sqlite3_db_filename(db, PAnsiChar('main'));
  if zFn = nil then begin WriteLn('FAIL db_filename'); Halt(1); end;

  pf := sqlite3_database_file_object(zFn);

  pBt := db^.aDb[0].pBt;
  pPgr := sqlite3BtreePager(pBt);
  pfRef := sqlite3PagerFile(pPgr);

  if pf = pfRef then
    WriteLn('PASS    sqlite3_database_file_object(zMain) = pager fd')
  else
    WriteLn('DIVERGE pf=', PtrUInt(pf), ' pfRef=', PtrUInt(pfRef));

  sqlite3_close(db);
  SysUtils.DeleteFile(tmp);
end.
