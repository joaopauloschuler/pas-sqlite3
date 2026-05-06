{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/mmapwarm.c (108 lines in C).

  Implements sqlite3_mmap_warm(db, zDb): touch every page of a memory-
  mapped database so the OS pre-faults the entire file into RAM, making
  subsequent reads cheaper.  Honours the upstream contract:

    * Caller must hold no open transaction (returns SQLITE_MISUSE
      otherwise — checked via sqlite3_get_autocommit).
    * Opens a read-only transaction internally (BEGIN ... END) and
      walks pages 1..N via xFetch / xUnfetch on the file's io_methods.
    * If the underlying VFS is below iVersion 3 (no mmap), the page
      walk silently degrades to a no-op — only the BEGIN / END pair
      runs.  The Pascal Unix VFS is currently iVersion=2, so this is
      the active path on Linux for now.
    * sqlite3_log() is omitted (not yet ported); the C source emits
      one informational record per call.

  Public entry: sqlite3_mmap_warm(db, zDb) — exact signature mirror.
}
{$I passqlite3.inc}
unit passqlite3mmapwarm;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3main;

function sqlite3_mmap_warm(db: PTsqlite3; zDb: PAnsiChar): i32; cdecl;

implementation

{ Build a SQL string of the form
     BEGIN; SELECT * FROM 'name'.sqlite_schema
  when zDb is non-NULL, or
     BEGIN; SELECT * FROM sqlite_schema
  when zDb is NULL.  Mirrors the inline sqlite3_mprintf("%s%q%s", ...)
  pattern in mmapwarm.c:46 / mmapwarm.c:55 — implemented here with
  the printf-aware sqlite3_mprintf so quoting of zDb stays correct. }
function buildSchemaSql(zDb: PAnsiChar): PAnsiChar;
begin
  if zDb = nil then
    Result := sqlite3_mprintf('BEGIN; SELECT * FROM sqlite_schema')
  else
    Result := sqlite3_mprintf(
      PAnsiChar(AnsiString('BEGIN; SELECT * FROM ''') + AnsiString(zDb) +
               AnsiString('''.sqlite_schema')));
end;

function buildPgszSql(zDb: PAnsiChar): PAnsiChar;
begin
  if zDb = nil then
    Result := sqlite3_mprintf('PRAGMA page_size')
  else
    Result := sqlite3_mprintf(
      PAnsiChar(AnsiString('PRAGMA ''') + AnsiString(zDb) +
               AnsiString('''.page_size')));
end;

{ mmapwarm.c:37..108 — sqlite3_mmap_warm. }
function sqlite3_mmap_warm(db: PTsqlite3; zDb: PAnsiChar): i32; cdecl;
var
  rc, rc2:  i32;
  zSql:     PAnsiChar;
  pgsz:     i32;
  nTotal:   u32;
  pPgsz:    Pointer;
  pFd:      Psqlite3_file;
  pIoM:     Psqlite3_io_methods;
  iPg:      i64;
  pMap:     PByte;
  pVoid:    Pointer;
begin
  rc     := SQLITE_OK;
  pgsz   := 0;
  nTotal := 0;
  pPgsz  := nil;
  pFd    := nil;

  if sqlite3_get_autocommit(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;

  { Open a read-only transaction on the file in question. }
  zSql := buildSchemaSql(zDb);
  if zSql = nil then begin Result := SQLITE_NOMEM; Exit; end;
  rc := sqlite3_exec(db, zSql, nil, nil, nil);
  sqlite3_free(zSql);

  { Find the SQLite page size of the file. }
  if rc = SQLITE_OK then begin
    zSql := buildPgszSql(zDb);
    if zSql = nil then begin
      rc := SQLITE_NOMEM;
    end else begin
      rc := sqlite3_prepare_v2(db, zSql, -1, @pPgsz, nil);
      sqlite3_free(zSql);
      if rc = SQLITE_OK then begin
        if sqlite3_step(pPgsz) = SQLITE_ROW then
          pgsz := sqlite3_column_int(pPgsz, 0);
        rc := sqlite3_finalize(pPgsz);
      end;
      if (rc = SQLITE_OK) and (pgsz = 0) then
        rc := SQLITE_ERROR;
    end;
  end;

  { Touch each mmap'd page of the file.

    The Pascal Unix VFS is iVersion=2 (no xFetch/xUnfetch), so this
    block is a no-op on the current build — preserved structurally
    for the day a higher-iVersion VFS comes online. }
  if rc = SQLITE_OK then begin
    rc := sqlite3_file_control(db, zDb, SQLITE_FCNTL_FILE_POINTER, @pFd);
    if (rc = SQLITE_OK) and (pFd <> nil) and (pFd^.pMethods <> nil)
       and (pFd^.pMethods^.iVersion >= 3) then begin
      iPg  := 1;
      pIoM := pFd^.pMethods;
      while True do begin
        pVoid := nil;
        if not Assigned(pIoM^.xFetch) then Break;
        rc := pIoM^.xFetch(pFd, pgsz * iPg, pgsz, @pVoid);
        if (rc <> SQLITE_OK) or (pVoid = nil) then Break;
        pMap := PByte(pVoid);
        Inc(nTotal, pMap[0]);
        Inc(nTotal, pMap[pgsz - 1]);
        if not Assigned(pIoM^.xUnfetch) then Break;
        rc := pIoM^.xUnfetch(pFd, pgsz * iPg, pVoid);
        if rc <> SQLITE_OK then Break;
        Inc(iPg);
      end;
    end;

    rc2 := sqlite3_exec(db, 'END', nil, nil, nil);
    if rc = SQLITE_OK then rc := rc2;
  end;

  { (void)nTotal — ignored, mirrors mmapwarm.c:106. }
  if nTotal = 0 then ; { suppress unused-var warnings cleanly }
  Result := rc;
end;

end.
