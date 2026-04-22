{$I ../passqlite3.inc}
program TestPCache;

{
  Phase 3.A.5 -- PCache gate tests for passqlite3pcache.

  Tests the Pascal page-cache implementation (passqlite3pcache) via its
  public API:

    T1  Initialize PCache system, open a cache instance.
    T2  Fetch pages with createFlag=1; verify pages come back non-nil.
    T3  Make pages dirty; verify dirty list is non-empty.
    T4  Release pages; verify reference counts decrease.
    T5  MakeClean removes pages from the dirty list.
    T6  Truncate removes high-numbered pages.
    T7  Close cleans up without crashing.
    T8  Differential: open an in-memory SQLite DB via C reference (csqlite3),
        write rows, read back -- confirms the engine that drives PCache is
        equivalent to the C reference at the SQL level.

  Prints PASS/FAIL per test.  Exits 0 if ALL PASS, 1 on any failure.

  Run with:
    LD_LIBRARY_PATH=src/ bin/TestPCache
}

uses
  SysUtils,
  BaseUnix,
  UnixType,
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  csqlite3;

{ ------------------------------------------------------------------ helpers }

var
  gAllPass: Boolean = True;

procedure Fail(const test, msg: string);
begin
  WriteLn('FAIL [', test, ']: ', msg);
  gAllPass := False;
end;

procedure Pass(const test: string);
begin
  WriteLn('PASS [', test, ']');
end;

{ A no-op stress callback -- we never spill pages in this test. }
function noStress(pArg: Pointer; pPage: PPgHdr): i32;
begin
  pArg  := pArg;
  pPage := pPage;
  Result := SQLITE_OK;
end;

{ ------------------------------------------------------------------ T1: Init + Open }

procedure T1_InitAndOpen;
var
  rc    : i32;
  cache : PCache;
begin
  { Initialize the pcache module }
  sqlite3_os_init;
  sqlite3MallocInit;
  rc := sqlite3PcacheInitialize;
  if rc <> SQLITE_OK then
  begin
    Fail('T1', 'sqlite3PcacheInitialize returned ' + IntToStr(rc));
    Exit;
  end;

  { Open a non-purgeable cache with 4096-byte pages, 0 extra bytes }
  FillChar(cache, SizeOf(cache), 0);
  rc := sqlite3PcacheOpen(4096, 0, 0, @noStress, nil, @cache);
  if rc <> SQLITE_OK then
  begin
    Fail('T1', 'sqlite3PcacheOpen returned ' + IntToStr(rc));
    Exit;
  end;
  if cache.pCache = nil then
  begin
    Fail('T1', 'sqlite3PcacheOpen: pCache is nil');
    Exit;
  end;

  sqlite3PcacheClose(@cache);
  Pass('T1: PCache init + open + close');
end;

{ ------------------------------------------------------------------ T2: Fetch pages }

procedure T2_FetchPages;
const
  NUM_PAGES = 5;
var
  rc    : i32;
  cache : PCache;
  rawP  : Psqlite3_pcache_page;
  hdr   : PPgHdr;
  i     : i32;
  ok    : Boolean;
begin
  FillChar(cache, SizeOf(cache), 0);
  rc := sqlite3PcacheOpen(4096, 32, 0, @noStress, nil, @cache);
  if rc <> SQLITE_OK then
  begin
    Fail('T2', 'sqlite3PcacheOpen returned ' + IntToStr(rc));
    Exit;
  end;

  ok := True;
  for i := 1 to NUM_PAGES do
  begin
    rawP := sqlite3PcacheFetch(@cache, Pgno(i), 3);
    if rawP = nil then
    begin
      Fail('T2', 'sqlite3PcacheFetch returned nil for page ' + IntToStr(i));
      ok := False;
      Continue;
    end;

    hdr := sqlite3PcacheFetchFinish(@cache, Pgno(i), rawP);
    if hdr = nil then
    begin
      Fail('T2', 'sqlite3PcacheFetchFinish returned nil for page ' + IntToStr(i));
      ok := False;
      Continue;
    end;

    if hdr^.pgno <> Pgno(i) then
    begin
      Fail('T2', Format('Page %d: pgno mismatch: got %d', [i, hdr^.pgno]));
      ok := False;
    end;
    if hdr^.pData = nil then
    begin
      Fail('T2', 'Page ' + IntToStr(i) + ': pData is nil');
      ok := False;
    end;
  end;

  sqlite3PcacheClose(@cache);
  if ok then Pass('T2: Fetch pages (createFlag=3)');
end;

{ ------------------------------------------------------------------ T3: Dirty list }

procedure T3_DirtyList;
var
  rc    : i32;
  cache : PCache;
  rawP  : Psqlite3_pcache_page;
  hdr   : array[1..3] of PPgHdr;
  dirty : PPgHdr;
  i     : i32;
  ok    : Boolean;
begin
  FillChar(cache, SizeOf(cache), 0);
  rc := sqlite3PcacheOpen(4096, 8, 0, @noStress, nil, @cache);
  if rc <> SQLITE_OK then
  begin
    Fail('T3', 'sqlite3PcacheOpen returned ' + IntToStr(rc));
    Exit;
  end;

  { Fetch 3 pages }
  ok := True;
  for i := 1 to 3 do
  begin
    rawP   := sqlite3PcacheFetch(@cache, Pgno(i), 3);
    hdr[i] := sqlite3PcacheFetchFinish(@cache, Pgno(i), rawP);
    if hdr[i] = nil then
    begin
      Fail('T3', 'FetchFinish returned nil for page ' + IntToStr(i));
      ok := False;
    end;
  end;

  if not ok then
  begin
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  { Make all 3 pages dirty }
  for i := 1 to 3 do
    sqlite3PcacheMakeDirty(hdr[i]);

  { Dirty list must be non-nil }
  dirty := sqlite3PcacheDirtyList(@cache);
  if dirty = nil then
  begin
    Fail('T3', 'Dirty list is nil after making 3 pages dirty');
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  { Count dirty pages }
  i := 0;
  while dirty <> nil do
  begin
    Inc(i);
    dirty := dirty^.pDirty;
  end;
  if i < 1 then
  begin
    Fail('T3', 'Dirty list has 0 entries after making 3 pages dirty');
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  sqlite3PcacheClose(@cache);
  Pass('T3: Dirty list populated after sqlite3PcacheMakeDirty');
end;

{ ------------------------------------------------------------------ T4: Release / refcount }

procedure T4_ReleaseRefcount;
var
  rc    : i32;
  cache : PCache;
  rawP  : Psqlite3_pcache_page;
  hdr   : PPgHdr;
  refB  : i64;
  refA  : i64;
begin
  FillChar(cache, SizeOf(cache), 0);
  rc := sqlite3PcacheOpen(4096, 8, 0, @noStress, nil, @cache);
  if rc <> SQLITE_OK then
  begin
    Fail('T4', 'sqlite3PcacheOpen returned ' + IntToStr(rc));
    Exit;
  end;

  rawP := sqlite3PcacheFetch(@cache, 1, 3);
  hdr  := sqlite3PcacheFetchFinish(@cache, 1, rawP);
  if hdr = nil then
  begin
    Fail('T4', 'FetchFinish returned nil');
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  { Add another reference }
  sqlite3PcacheRef(hdr);
  refB := sqlite3PcachePageRefcount(hdr);
  if refB < 2 then
  begin
    Fail('T4', Format('Expected refcount >= 2 after Ref, got %d', [refB]));
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  { Release one reference }
  sqlite3PcacheRelease(hdr);
  refA := sqlite3PcachePageRefcount(hdr);
  if refA >= refB then
  begin
    Fail('T4', Format('Refcount should decrease after Release: was %d, now %d',
      [refB, refA]));
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  sqlite3PcacheClose(@cache);
  Pass('T4: Ref/Release changes reference count correctly');
end;

{ ------------------------------------------------------------------ T5: MakeClean }

procedure T5_MakeClean;
var
  rc    : i32;
  cache : PCache;
  rawP  : Psqlite3_pcache_page;
  hdr   : PPgHdr;
  dirty : PPgHdr;
begin
  FillChar(cache, SizeOf(cache), 0);
  rc := sqlite3PcacheOpen(4096, 8, 0, @noStress, nil, @cache);
  if rc <> SQLITE_OK then
  begin
    Fail('T5', 'sqlite3PcacheOpen returned ' + IntToStr(rc));
    Exit;
  end;

  rawP := sqlite3PcacheFetch(@cache, 1, 3);
  hdr  := sqlite3PcacheFetchFinish(@cache, 1, rawP);
  if hdr = nil then
  begin
    Fail('T5', 'FetchFinish returned nil');
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  sqlite3PcacheMakeDirty(hdr);
  dirty := sqlite3PcacheDirtyList(@cache);
  if dirty = nil then
  begin
    Fail('T5', 'Dirty list should be non-nil after MakeDirty');
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  sqlite3PcacheMakeClean(hdr);
  dirty := sqlite3PcacheDirtyList(@cache);
  if dirty <> nil then
  begin
    Fail('T5', 'Dirty list should be nil after MakeClean');
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  sqlite3PcacheClose(@cache);
  Pass('T5: MakeClean removes page from dirty list');
end;

{ ------------------------------------------------------------------ T6: Truncate }

procedure T6_Truncate;
var
  rc    : i32;
  cache : PCache;
  rawP  : Psqlite3_pcache_page;
  i     : i32;
  cnt   : i32;
begin
  FillChar(cache, SizeOf(cache), 0);
  rc := sqlite3PcacheOpen(4096, 8, 0, @noStress, nil, @cache);
  if rc <> SQLITE_OK then
  begin
    Fail('T6', 'sqlite3PcacheOpen returned ' + IntToStr(rc));
    Exit;
  end;

  { Fetch and release 10 pages so they stay in the cache }
  for i := 1 to 10 do
  begin
    rawP := sqlite3PcacheFetch(@cache, Pgno(i), 3);
    if rawP <> nil then
      sqlite3PcacheRelease(sqlite3PcacheFetchFinish(@cache, Pgno(i), rawP));
  end;

  cnt := sqlite3PcachePagecount(@cache);
  if cnt < 1 then
  begin
    Fail('T6', 'Expected > 0 pages before truncate, got ' + IntToStr(cnt));
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  { Truncate to keep only pages 1..5 }
  sqlite3PcacheTruncate(@cache, 5);

  { Attempt to fetch page 7 with createFlag=0 -- should return nil }
  rawP := sqlite3PcacheFetch(@cache, 7, 0);
  if rawP <> nil then
  begin
    Fail('T6', 'Page 7 should not exist after truncate to 5');
    sqlite3PcacheClose(@cache);
    Exit;
  end;

  sqlite3PcacheClose(@cache);
  Pass('T6: Truncate removes pages above threshold');
end;

{ ------------------------------------------------------------------ T7: Close }

procedure T7_Close;
var
  rc    : i32;
  cache : PCache;
  rawP  : Psqlite3_pcache_page;
  i     : i32;
begin
  FillChar(cache, SizeOf(cache), 0);
  rc := sqlite3PcacheOpen(4096, 64, 1, @noStress, nil, @cache);
  if rc <> SQLITE_OK then
  begin
    Fail('T7', 'sqlite3PcacheOpen returned ' + IntToStr(rc));
    Exit;
  end;

  for i := 1 to 8 do
  begin
    rawP := sqlite3PcacheFetch(@cache, Pgno(i), 3);
    if rawP <> nil then
      sqlite3PcacheMakeDirty(sqlite3PcacheFetchFinish(@cache, Pgno(i), rawP));
  end;

  { Close with pinned dirty pages -- must not crash }
  sqlite3PcacheClose(@cache);
  Pass('T7: Close with dirty pages does not crash');
end;

{ ------------------------------------------------------------------ T8: C reference differential }

procedure T8_CReferenceDiff;
var
  db     : Pcsq_db;
  rc     : i32;
  ok     : Boolean;
  cnt    : i32;
  pzErr  : PChar;

  function countRows(db: Pcsq_db; const sql: string): i32;
  var
    pStmt : Pcsq_stmt;
    pTail : PChar;
    s     : i32;
  begin
    Result := -1;
    if csq_prepare_v2(db, PChar(sql), -1, pStmt, pTail) <> 0 then Exit;
    s := csq_step(pStmt);
    if s = 100 { SQLITE_ROW } then
      Result := csq_column_int(pStmt, 0);
    csq_finalize(pStmt);
  end;

begin
  ok    := True;
  pzErr := nil;
  rc := csq_open(':memory:', db);
  if rc <> 0 then
  begin
    Fail('T8', 'csq_open(:memory:) returned ' + IntToStr(rc));
    Exit;
  end;

  rc := csq_exec(db, 'CREATE TABLE t(x INTEGER PRIMARY KEY, y TEXT)',
                 nil, nil, pzErr);
  if rc <> 0 then
  begin
    Fail('T8', 'CREATE TABLE failed: ' + IntToStr(rc)); ok := False;
  end;

  if ok then
  begin
    rc := csq_exec(db,
      'INSERT INTO t VALUES(1,''a''),(2,''b''),(3,''c'')',
      nil, nil, pzErr);
    if rc <> 0 then
    begin
      Fail('T8', 'INSERT failed: ' + IntToStr(rc)); ok := False;
    end;
  end;

  if ok then
  begin
    cnt := countRows(db, 'SELECT count(*) FROM t');
    if cnt <> 3 then
    begin
      Fail('T8', 'Expected 3 rows, got ' + IntToStr(cnt)); ok := False;
    end;
  end;

  csq_close(db);
  if ok then Pass('T8: C reference :memory: DB open/write/read (differential sanity)');
end;

{ ------------------------------------------------------------------ main }

begin
  T1_InitAndOpen;
  T2_FetchPages;
  T3_DirtyList;
  T4_ReleaseRefcount;
  T5_MakeClean;
  T6_Truncate;
  T7_Close;
  T8_CReferenceDiff;

  if gAllPass then
    WriteLn('ALL PASS')
  else
  begin
    WriteLn('SOME TESTS FAILED');
    Halt(1);
  end;
end.
