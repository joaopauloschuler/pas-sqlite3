{$I ../passqlite3.inc}
{
  TestInitCallback.pas — Phase 6.9-bis step 11g.1.c gate.

  Audits the init.busy=1 publication arms in sqlite3EndTable
  (codegen.pas:6892..6904) and sqlite3CreateIndex (codegen.pas:7562..7572)
  by driving them through the live sqlite3InitCallback dispatcher rather
  than the openDatabase-time sqlite3InstallSchemaTable bootstrap.

  Until step 11g.1.c, these arms had only ever been exercised via
  sqlite3InstallSchemaTable, which heap-allocates a fully-formed PTable2
  and inserts it directly into pSchema^.tblHash.  Driving the same arms
  via the parser (sqlite3InitCallback -> sqlite3Prepare under
  init.busy=1) is a different codepath that exercises:
    * pTable^.zName lifetime — must survive the prepare's transient
      Parse object, since it ends up as the hash-table key;
    * pSchema selection — pTable^.pSchema must point at the
      iDb-indexed db^.aDb[iDb].pSchema (otherwise sqlite3FindTable
      with the wrong zDb returns nil);
    * lookaside placement — sqlite3DbStrDup uses lookaside when
      enabled, but the live hash-key pointer must remain valid past
      sqlite3_finalize of the inner statement.

  Coverage:
    T1  CREATE TABLE via callback — pTab in main.tblHash, tnum=2
    T2  CREATE INDEX via callback — pIdx in main.idxHash, tnum=3
    T3  Auto-index branch (empty SQL) — patches pre-existing index tnum
    T4  Corrupt schema — argv[3] = nil triggers SQLITE_CORRUPT
}

program TestInitCallback;

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin
    Inc(gPass);
    WriteLn('  PASS ', msg);
  end else begin
    Inc(gFail);
    WriteLn('  FAIL ', msg);
  end;
end;

procedure ExpectEq(a, b: i64; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

{ Drive sqlite3InitCallback with a synthesised 5-element argv tuple.
  Returns the rc reported by the callback as well as initData.rc so the
  caller can check both. }
function DriveCallback(db: PTsqlite3; iDb: i32;
                       const argv: array of PAnsiChar;
                       out initData: TInitData): i32;
var
  argvArr  : array[0..4] of PAnsiChar;
  i        : i32;
  savedBusy: u8;
begin
  Assert(Length(argv) = 5);
  for i := 0 to 4 do argvArr[i] := argv[i];

  initData.db         := db;
  initData.iDb        := iDb;
  initData.pzErrMsg   := nil;
  initData.rc         := SQLITE_OK;
  initData.mInitFlags := 0;
  initData.nInitRow   := 0;
  initData.mxPage     := 1024 * 1024;

  savedBusy        := db^.init.busy;
  db^.init.busy    := 1;
  Result := sqlite3InitCallback(@initData, 5, @argvArr[0], nil);
  db^.init.busy    := savedBusy;
end;

{ ============================================================ }

procedure T1_CreateTableViaCallback;
var
  db      : PTsqlite3;
  rc      : i32;
  pTab    : PTable2;
  initD   : TInitData;
begin
  WriteLn('T1 CREATE TABLE via callback:');
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Expect(rc = SQLITE_OK, 'open(:memory:)');
  if (rc <> SQLITE_OK) or (db = nil) then Exit;

  rc := DriveCallback(db, 0,
          ['table', 'foo', 'foo', '2', 'CREATE TABLE foo(a,b,c)'],
          initD);
  ExpectEq(rc, 0, 'callback rc=0');
  ExpectEq(initD.rc, SQLITE_OK, 'initData.rc=SQLITE_OK');

  pTab := sqlite3FindTable(db, 'foo', 'main');
  Expect(pTab <> nil, 'sqlite3FindTable("foo","main") non-nil');
  if pTab <> nil then begin
    ExpectEq(pTab^.tnum, 2, 'pTab^.tnum=2');
    Expect(pTab^.pSchema = db^.aDb[0].pSchema,
           'pTab^.pSchema = aDb[0].pSchema');
    Expect(pTab^.zName <> nil, 'pTab^.zName non-nil');
    if pTab^.zName <> nil then
      Expect(StrComp(PAnsiChar(pTab^.zName), 'foo') = 0,
             'pTab^.zName = "foo"');
  end;

  { Schema must NOT be visible under any other db. }
  pTab := sqlite3FindTable(db, 'foo', 'temp');
  Expect(pTab = nil, 'sqlite3FindTable("foo","temp") = nil');

  sqlite3_close(db);
end;

procedure T2_CreateIndexViaCallback;
var
  db    : PTsqlite3;
  rc    : i32;
  pIdx  : PIndex2;
  pTab  : PTable2;
  initD : TInitData;
begin
  WriteLn('T2 CREATE INDEX via callback:');
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Expect(rc = SQLITE_OK, 'open(:memory:)');
  if (rc <> SQLITE_OK) or (db = nil) then Exit;

  { Pre-create the parent table via the callback path. }
  rc := DriveCallback(db, 0,
          ['table', 't', 't', '2', 'CREATE TABLE t(a,b)'],
          initD);
  ExpectEq(rc, 0, 'parent callback rc=0');
  pTab := sqlite3FindTable(db, 't', 'main');
  Expect(pTab <> nil, 'parent table "t" published');

  { Now publish a CREATE INDEX. }
  rc := DriveCallback(db, 0,
          ['index', 'i1', 't', '3', 'CREATE INDEX i1 ON t(a)'],
          initD);
  ExpectEq(rc, 0, 'index callback rc=0');
  ExpectEq(initD.rc, SQLITE_OK, 'index initData.rc=SQLITE_OK');

  pIdx := sqlite3FindIndex(db, 'i1', 'main');
  Expect(pIdx <> nil, 'sqlite3FindIndex("i1","main") non-nil');
  if pIdx <> nil then begin
    ExpectEq(pIdx^.tnum, 3, 'pIdx^.tnum=3');
    Expect(pIdx^.pSchema = db^.aDb[0].pSchema,
           'pIdx^.pSchema = aDb[0].pSchema');
  end;

  sqlite3_close(db);
end;

procedure T3_AutoIndexBranch;
var
  db    : PTsqlite3;
  rc    : i32;
  pIdx  : PIndex2;
  pTab  : PTable2;
  initD : TInitData;
begin
  WriteLn('T3 auto-index tnum patch (empty SQL):');
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Expect(rc = SQLITE_OK, 'open(:memory:)');
  if (rc <> SQLITE_OK) or (db = nil) then Exit;

  { Pre-create a table with an auto-index already attached.  We stage
    the index via a CREATE TABLE...PRIMARY KEY, but today's parser
    stub does not yet promote PRIMARY KEY to an Index, so synthesise
    one directly: allocate a 1-column Index, link it onto pTab, and
    publish it in idxHash with tnum=0 (the unpatched state).  This
    mirrors the structural shape sqlite3FindIndex needs. }
  rc := DriveCallback(db, 0,
          ['table', 't', 't', '2', 'CREATE TABLE t(a,b)'],
          initD);
  ExpectEq(rc, 0, 'parent callback rc=0');
  pTab := sqlite3FindTable(db, 't', 'main');
  Expect(pTab <> nil, 'parent table "t" published');
  if pTab = nil then begin sqlite3_close(db); Exit; end;

  pIdx := sqlite3AllocateIndexObject(db, 1, 0, nil);
  Expect(pIdx <> nil, 'AllocateIndexObject');
  if pIdx = nil then begin sqlite3_close(db); Exit; end;
  pIdx^.zName   := sqlite3DbStrDup(db, PAnsiChar('sqlite_autoindex_t_1'));
  pIdx^.pTable  := pTab;
  pIdx^.pSchema := db^.aDb[0].pSchema;
  pIdx^.tnum    := 0;
  pIdx^.pNext   := pTab^.pIndex;
  pTab^.pIndex  := pIdx;
  sqlite3HashInsert(@passqlite3util.PSchema(pIdx^.pSchema)^.idxHash,
                    PChar(pIdx^.zName), pIdx);

  { Now drive the branch (d) of sqlite3InitCallback: empty SQL, valid
    name, valid rootpage. }
  rc := DriveCallback(db, 0,
          ['index', 'sqlite_autoindex_t_1', 't', '5', ''],
          initD);
  ExpectEq(rc, 0, 'auto-index callback rc=0');
  ExpectEq(initD.rc, SQLITE_OK, 'auto-index initData.rc=SQLITE_OK');
  ExpectEq(pIdx^.tnum, 5, 'pIdx^.tnum patched to 5');

  sqlite3_close(db);
end;

procedure T4_CorruptSchemaPath;
var
  db    : PTsqlite3;
  rc    : i32;
  initD : TInitData;
  emptyArgv : array[0..4] of PAnsiChar;
begin
  WriteLn('T4 corrupt-schema branches:');
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  Expect(rc = SQLITE_OK, 'open(:memory:)');
  if (rc <> SQLITE_OK) or (db = nil) then Exit;

  { Branch (a) — argv[3] = nil. }
  emptyArgv[0] := 'table'; emptyArgv[1] := 'foo';
  emptyArgv[2] := 'foo';   emptyArgv[3] := nil;
  emptyArgv[4] := 'CREATE TABLE foo(a)';
  rc := DriveCallback(db, 0,
          [emptyArgv[0], emptyArgv[1], emptyArgv[2],
           emptyArgv[3], emptyArgv[4]],
          initD);
  ExpectEq(rc, 0, 'callback rc=0 (errors via initData.rc)');
  ExpectEq(initD.rc, SQLITE_CORRUPT,
           'argv[3]=nil → initData.rc=SQLITE_CORRUPT');

  { Branch (c) — argv[1] = nil with non-c-r argv[4]. }
  rc := DriveCallback(db, 0,
          ['table', nil, 'foo', '2', 'BOGUS NON-CR SQL'],
          initD);
  ExpectEq(rc, 0, 'non-CR garbage rc=0');
  ExpectEq(initD.rc, SQLITE_CORRUPT,
           'non-CR garbage → initData.rc=SQLITE_CORRUPT');

  sqlite3_close(db);
end;

{ ============================================================ }

begin
  gPass := 0; gFail := 0;
  WriteLn('TestInitCallback — Phase 6.9-bis step 11g.1.c');
  WriteLn;

  T1_CreateTableViaCallback;
  WriteLn;
  T2_CreateIndexViaCallback;
  WriteLn;
  T3_AutoIndexBranch;
  WriteLn;
  T4_CorruptSchemaPath;

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed');
  if gFail > 0 then Halt(1);
end.
