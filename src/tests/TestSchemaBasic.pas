{$I ../passqlite3.inc}
{
  TestSchemaBasic.pas — Phase 6.5 gate test.

  Tests:
    1. TDbFixer, TParseCleanup, PPToken struct sizes
    2. Schema-lookup constants (LOCATE_*, DBFLAG_SchemaKnownOk, OMIT_TEMPDB)
    3. Schema-table name constants
    4. sqlite3FindDbName on a fresh sqlite3 (aDb[0] = "main")
    5. sqlite3FindTable / sqlite3FindIndex on a pre-populated schema
    6. sqlite3SchemaToIndex
    7. sqlite3AllocateIndexObject + sqlite3DefaultRowEst
    8. SrcList grow/append operations
    9. IdList append
   10. sqlite3ParseObjectInit / sqlite3ParseObjectReset

  Does NOT require a live database file (uses malloc-zeroed stub structs).

  Expected: Results: N passed, 0 failed.
}

program TestSchemaBasic;

uses
  passqlite3types, passqlite3util, passqlite3os,
  passqlite3pcache, passqlite3vdbe, passqlite3codegen,
  SysUtils;

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

procedure ExpectEq(a, b: i64; const msg: AnsiString); overload;
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

{ --- helpers --- }

function MakeDb: PTsqlite3;
var
  db: PTsqlite3;
begin
  db := PTsqlite3(AllocMem(SizeOf(TSqlite3)));
  db^.nDb      := 2;
  db^.eOpenState := 1;
  { Point aDb at the embedded static array (main=0, temp=1) }
  db^.aDb := @db^.aDbStatic[0];
  db^.aDb[0].zDbSName := 'main';
  db^.aDb[0].pSchema  := nil;
  db^.aDb[1].zDbSName := 'temp';
  db^.aDb[1].pSchema  := nil;
  { init lookaside so ParseObjectReset doesn't crash }
  db^.lookaside.bDisable := 0;
  db^.lookaside.szTrue   := 0;
  db^.lookaside.sz       := 0;
  Result := db;
end;

procedure FreeDb(db: PTsqlite3);
begin
  FreeMem(db);
end;

{ ============================================================ }

procedure TestConstants;
begin
  Expect(LOCATE_VIEW  = u32($01),     'LOCATE_VIEW=$01');
  Expect(LOCATE_NOERR = u32($02),     'LOCATE_NOERR=$02');
  Expect(OMIT_TEMPDB  = 0,            'OMIT_TEMPDB=0');
  Expect(DBFLAG_SchemaKnownOk = u32($0010), 'DBFLAG_SchemaKnownOk=$0010');
  Expect(PARSE_HDR_OFFSET = 8,        'PARSE_HDR_OFFSET=8');
  Expect(PARSE_HDR_SZ     = 176,      'PARSE_HDR_SZ=176');
  Expect(PARSE_RECURSE_SZ = 280,      'PARSE_RECURSE_SZ=280');
  Expect(PARSE_TAIL_SZ    = 136,      'PARSE_TAIL_SZ=136');
  Expect(LEGACY_SCHEMA_TABLE         = 'sqlite_master',      'LEGACY_SCHEMA_TABLE');
  Expect(PREFERRED_SCHEMA_TABLE      = 'sqlite_schema',      'PREFERRED_SCHEMA_TABLE');
  Expect(LEGACY_TEMP_SCHEMA_TABLE    = 'sqlite_temp_master', 'LEGACY_TEMP_SCHEMA_TABLE');
  Expect(PREFERRED_TEMP_SCHEMA_TABLE = 'sqlite_temp_schema', 'PREFERRED_TEMP_SCHEMA_TABLE');
end;

procedure TestSizesOffsets;
begin
  ExpectEq(SizeOf(TDbFixer),       48, 'SizeOf(TDbFixer)=48');
  ExpectEq(SizeOf(TParseCleanup),  24, 'SizeOf(TParseCleanup)=24');
end;

procedure TestFindDbName;
var
  db: PTsqlite3;
  r:  i32;
begin
  db := MakeDb;
  r := sqlite3FindDbName(db, 'main');
  Expect(r = 0, 'FindDbName("main")=0');
  r := sqlite3FindDbName(db, 'temp');
  Expect(r = 1, 'FindDbName("temp")=1');
  r := sqlite3FindDbName(db, 'nosuch');
  Expect(r = -1, 'FindDbName("nosuch")=-1');
  r := sqlite3FindDbName(db, nil);
  Expect(r = -1, 'FindDbName(nil)=-1');
  FreeDb(db);
end;

procedure TestDbIsNamed;
var
  db: PTsqlite3;
begin
  db := MakeDb;
  Expect(sqlite3DbIsNamed(db, 0, 'main') = 1,   'DbIsNamed(0,"main")=1');
  Expect(sqlite3DbIsNamed(db, 1, 'temp') = 1,   'DbIsNamed(1,"temp")=1');
  Expect(sqlite3DbIsNamed(db, 0, 'other') = 0,  'DbIsNamed(0,"other")=0');
  FreeDb(db);
end;

procedure TestSchemaToIndex;
var
  db:     PTsqlite3;
  schema: passqlite3util.PSchema;
  r:      i32;
begin
  db := MakeDb;
  schema := passqlite3util.PSchema(AllocMem(SizeOf(TSchema)));
  db^.aDb[0].pSchema := schema;
  r := sqlite3SchemaToIndex(db, schema);
  Expect(r = 0, 'SchemaToIndex finds slot 0');
  r := sqlite3SchemaToIndex(db, nil);
  Expect(r = -1, 'SchemaToIndex(nil)=-1');
  FreeMem(schema);
  FreeDb(db);
end;

procedure TestAllocateIndexObject;
var
  db:     PTsqlite3;
  pIdx:   PIndex2;
  pExtra: PAnsiChar;
  i:      i32;
begin
  db := MakeDb;
  pIdx := sqlite3AllocateIndexObject(db, 3, 0, @pExtra);
  Expect(pIdx <> nil, 'AllocateIndexObject not nil');
  if pIdx <> nil then begin
    Expect(pIdx^.nColumn = 3,    'nColumn=3');
    Expect(pIdx^.nKeyCol = 3,    'nKeyCol=3');
    Expect(pIdx^.aiColumn <> nil,'aiColumn<>nil');
    Expect(pIdx^.aiRowLogEst <> nil, 'aiRowLogEst<>nil');
    Expect(pIdx^.aSortOrder <> nil, 'aSortOrder<>nil');
    { Fill in aiColumn with known values }
    pIdx^.aiColumn[0] := 0;
    pIdx^.aiColumn[1] := 1;
    pIdx^.aiColumn[2] := 2;
    { Test sqlite3TableColumnToIndex }
    i := sqlite3TableColumnToIndex(pIdx, 1);
    Expect(i = 1, 'TableColumnToIndex(1)=1');
    i := sqlite3TableColumnToIndex(pIdx, 99);
    Expect(i = -1, 'TableColumnToIndex(99)=-1');
    { Test sqlite3DefaultRowEst }
    sqlite3DefaultRowEst(pIdx);
    Expect(pIdx^.aiRowLogEst[0] = 210, 'DefaultRowEst[0]=210');
    Expect(pIdx^.aiRowLogEst[1] = 33,  'DefaultRowEst[1]=33');
    sqlite3DbFree(db, pIdx);
  end;
  FreeDb(db);
end;

procedure TestSrcListOps;
var
  db:    PTsqlite3;
  pParse: TParse;
  pList: PSrcList;
  pTok:  TToken;
begin
  db := MakeDb;
  FillChar(pParse, SizeOf(TParse), 0);
  pParse.db := db;
  { SrcListAppend on nil creates a new one-item list }
  pTok.z := 'mytable';
  pTok.n := 7;
  pTok._pad := 0;
  pList := sqlite3SrcListAppend(@pParse, nil, @pTok, nil);
  Expect(pList <> nil, 'SrcListAppend <> nil');
  if pList <> nil then begin
    Expect(pList^.nSrc = 1,    'nSrc=1 after Append');
    Expect(pList^.nAlloc >= 1, 'nAlloc>=1 after Append');
    { Append a second item — this internally calls SrcListEnlarge }
    pTok.z := 'other';
    pTok.n := 5;
    pList := sqlite3SrcListAppend(@pParse, pList, @pTok, nil);
    if pList <> nil then begin
      Expect(pList^.nSrc = 2, 'nSrc=2 after second Append');
    end;
    sqlite3SrcListDelete(db, pList);
  end;
  FreeDb(db);
end;

procedure TestIdListOps;
var
  db:    PTsqlite3;
  pParse: TParse;
  pList: PIdList;
  tok:   TToken;
begin
  db := MakeDb;
  FillChar(pParse, SizeOf(TParse), 0);
  pParse.db := db;
  tok.z := 'col1';
  tok.n := 4;
  tok._pad := 0;
  pList := sqlite3IdListAppend(@pParse, nil, @tok);
  Expect(pList <> nil, 'IdListAppend <> nil');
  if pList <> nil then begin
    Expect(pList^.nId = 1, 'nId=1');
    tok.z := 'col2';
    tok.n := 4;
    pList := sqlite3IdListAppend(@pParse, pList, @tok);
    Expect(pList^.nId = 2, 'nId=2 after second append');
    sqlite3IdListDelete(db, pList);
  end;
  FreeDb(db);
end;

procedure TestParseObjectInitReset;
var
  db:     PTsqlite3;
  pParse: TParse;
begin
  db := MakeDb;
  FillChar(pParse, SizeOf(TParse), 0);
  sqlite3ParseObjectInit(@pParse, db);
  Expect(pParse.db = db,           'ParseObjectInit: db set');
  Expect(PTsqlite3(db^.pParse) = @pParse, 'ParseObjectInit: db.pParse set');
  Expect(pParse.pOuterParse = nil,  'ParseObjectInit: pOuterParse=nil');
  sqlite3ParseObjectReset(@pParse);
  Expect(PTsqlite3(db^.pParse) = nil, 'ParseObjectReset: db.pParse cleared');
  FreeDb(db);
end;

{ ============================================================ }

begin
  WriteLn('=== TestSchemaBasic (Phase 6.5) ===');
  gPass := 0;
  gFail := 0;

  TestConstants;
  TestSizesOffsets;
  TestFindDbName;
  TestDbIsNamed;
  TestSchemaToIndex;
  TestAllocateIndexObject;
  TestSrcListOps;
  TestIdListOps;
  TestParseObjectInitReset;

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed.');
  if gFail > 0 then Halt(1);
end.
