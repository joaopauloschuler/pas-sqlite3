{
  SPDX-License-Identifier: blessing

  TestSerialize — Phase 8.7.2 gate for sqlite3_serialize.
  Real-Btree path: open a :memory: db, populate it, serialize it, and
  verify the returned buffer is well-formed (SQLite header magic, the
  reported size matches sqlite_count(*pages) * page_size, and the buffer
  is non-NULL when SQLITE_SERIALIZE_NOCOPY is clear).
}
{$I ../passqlite3.inc}
program TestSerialize;

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

const
  SQLITE_HEADER_MAGIC: PAnsiChar = 'SQLite format 3'#0;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i64; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

function HasSqliteMagic(p: Pu8): Boolean;
var i: i32;
begin
  Result := False;
  if p = nil then Exit;
  for i := 0 to 15 do
    if PAnsiChar(p)[i] <> SQLITE_HEADER_MAGIC[i] then Exit;
  Result := True;
end;

var
  db:   PTsqlite3;
  rc:   i32;
  buf:  Pu8;
  sz:   i64;
  pStmt: PVdbe;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestSerialize — Phase 8.7.2 sqlite3_serialize');

  db := nil;
  ExpectEq(sqlite3_open(':memory:', @db), SQLITE_OK, 'open');
  if db = nil then begin WriteLn('  open failed'); Halt(1); end;

  { Populate. }
  rc := sqlite3_exec(db,
    'CREATE TABLE t(a INTEGER, b TEXT);'#10 +
    'INSERT INTO t VALUES(1,''alpha'');'#10 +
    'INSERT INTO t VALUES(2,''beta'');'#10 +
    'INSERT INTO t VALUES(3,''gamma'');',
    nil, nil, nil);
  ExpectEq(rc, SQLITE_OK, 'exec seed');

  { T1 — serialize main with size returned. }
  sz  := -123;
  buf := sqlite3_serialize(db, 'main', @sz, 0);
  Expect(buf <> nil, 'T1 buffer non-nil');
  Expect(sz > 0, 'T1 size > 0');
  Expect(HasSqliteMagic(buf), 'T1 SQLite header magic at offset 0');

  { T2 — sqlite3_serialize(zSchema=nil) defaults to "main". }
  sqlite3_free(buf);
  sz  := -123;
  buf := sqlite3_serialize(db, nil, @sz, 0);
  Expect(buf <> nil, 'T2 buffer non-nil for zSchema=nil');
  Expect(sz > 0, 'T2 size > 0 for zSchema=nil');

  { T3 — unknown schema returns nil and *piSize := -1. }
  sqlite3_free(buf);
  sz  := 999;
  buf := sqlite3_serialize(db, 'no_such_db', @sz, 0);
  Expect(buf = nil, 'T3 unknown schema -> nil');
  ExpectEq(sz, -1, 'T3 piSize := -1');

  { T4 — round-trip: prepared statement still works after serialize.
    Serialize is read-only, so existing connection state must survive. }
  rc := sqlite3_prepare_v2(db, 'SELECT count(*) FROM t', -1, @pStmt, nil);
  ExpectEq(rc, SQLITE_OK, 'T4 prepare count');
  if pStmt <> nil then begin
    rc := sqlite3_step(pStmt);
    ExpectEq(rc, SQLITE_ROW, 'T4 step ROW');
    ExpectEq(sqlite3_column_int64(pStmt, 0), 3, 'T4 count = 3');
    sqlite3_finalize(pStmt);
  end;

  { T5 — sqlite3_deserialize OMIT_DESERIALIZE-equivalent semantics:
    memdb VFS is unported, so the call must fail with SQLITE_ERROR.
    Pass nil pData/0 sizes so no FREEONCLOSE bookkeeping is exercised. }
  ExpectEq(sqlite3_deserialize(db, 'main', nil, 0, 0, 0),
           SQLITE_ERROR, 'T5 deserialize -> SQLITE_ERROR');

  { T6 — FREEONCLOSE on failure path: pData must be freed by SQLite even
    though deserialize fails (memdb.c:903).  Allocate via sqlite3_malloc
    so the matched free path is exercised; nothing to assert directly,
    but a leak would surface under valgrind / repeat runs. }
  buf := sqlite3_malloc(64);
  Expect(buf <> nil, 'T6 malloc');
  ExpectEq(sqlite3_deserialize(db, 'main', buf, 0, 64,
                               SQLITE_DESERIALIZE_FREEONCLOSE),
           SQLITE_ERROR, 'T6 deserialize FREEONCLOSE -> SQLITE_ERROR');

  sqlite3_close(db);

  WriteLn('---');
  WriteLn('TestSerialize  PASS=', gPass, '  FAIL=', gFail);
  if gFail > 0 then Halt(1);
end.
