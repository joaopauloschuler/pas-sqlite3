{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/scrub.c (~610 lines in C).

  Implements sqlite3_scrub_backup(zSrcFile, zDestFile, pzErr): copy a
  whole SQLite database while zeroing out content in regions that the
  database considers free / unused (freelist pages, gap between cell
  index and cell content, free-blocks inside b-tree pages, and the
  unused tail of the last overflow page in each chain).  Faster than
  VACUUM on large databases when the goal is to scrub deleted content
  that secure_delete=OFF left behind.

  Public entry: sqlite3_scrub_backup — exact signature mirror.
}
{$I passqlite3.inc}
unit passqlite3scrub;

interface

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3wal,
  passqlite3vdbe,
  passqlite3main;

function sqlite3_scrub_backup(zSrcFile, zDestFile: PAnsiChar;
                              pzErr: PPAnsiChar): i32; cdecl;

implementation

type
  PScrubState = ^TScrubState;
  TScrubState = record
    zSrcFile : PAnsiChar;        { Name of the source file }
    zDestFile: PAnsiChar;        { Name of the destination file }
    rcErr    : i32;              { Error code }
    zErr     : PAnsiChar;        { Error message text }
    dbSrc    : PTsqlite3;        { Source database connection }
    pSrc     : Psqlite3_file;    { Source file handle }
    dbDest   : PTsqlite3;        { Destination database connection }
    pDest    : Psqlite3_file;    { Destination file handle }
    szPage   : u32;              { Page size }
    szUsable : u32;              { Usable bytes on each page }
    nPage    : u32;              { Number of pages }
    iLastPage: u32;              { Page number of last page written so far }
    page1    : Pu8;              { Content of page 1 }
  end;

{ scrub.c:82 — store a textual error.  C source uses sqlite3_vmprintf;
  we route through SysUtils.Format then sqlite3StrDup so the error
  buffer lives in sqlite3_malloc memory (caller frees via
  sqlite3_free if pzErr is non-NULL — see sqlite3_scrub_backup tail). }
procedure scrubBackupErr(p: PScrubState; const zMsg: AnsiString);
var
  z: PAnsiChar;
  n: PtrUInt;
begin
  if p^.zErr <> nil then sqlite3_free(p^.zErr);
  n := Length(zMsg);
  z := PAnsiChar(sqlite3_malloc64(u64(n + 1)));
  if z <> nil then begin
    if n > 0 then Move(zMsg[1], z^, n);
    z[n] := #0;
  end;
  p^.zErr := z;
  if p^.rcErr = 0 then p^.rcErr := SQLITE_ERROR;
end;

{ scrub.c:92 — allocate a single page buffer. }
function scrubBackupAllocPage(p: PScrubState): Pu8;
begin
  if p^.rcErr <> 0 then begin Result := nil; Exit; end;
  Result := Pu8(sqlite3_malloc64(u64(p^.szPage)));
  if Result = nil then p^.rcErr := SQLITE_NOMEM;
end;

{ scrub.c:103 — read a page from source.  pBuf reused if non-nil,
  otherwise we allocate. }
function scrubBackupRead(p: PScrubState; pgno: i32; pBuf: Pu8): Pu8;
var
  rc:  i32;
  iOff: i64;
  pOut: Pu8;
begin
  pOut := pBuf;
  if p^.rcErr <> 0 then begin Result := nil; Exit; end;
  if pOut = nil then begin
    pOut := scrubBackupAllocPage(p);
    if pOut = nil then begin Result := nil; Exit; end;
  end;
  iOff := i64(pgno - 1) * i64(p^.szPage);
  rc := p^.pSrc^.pMethods^.xRead(p^.pSrc, pOut, i32(p^.szPage), iOff);
  if rc <> SQLITE_OK then begin
    if pBuf = nil then sqlite3_free(pOut);
    pOut := nil;
    scrubBackupErr(p, Format('read failed for page %d', [pgno]));
    p^.rcErr := SQLITE_IOERR;
  end;
  Result := pOut;
end;

{ scrub.c:124 — write a page to destination. }
procedure scrubBackupWrite(p: PScrubState; pgno: i32; pData: Pu8);
var
  rc:  i32;
  iOff: i64;
begin
  if p^.rcErr <> 0 then Exit;
  iOff := i64(pgno - 1) * i64(p^.szPage);
  rc := p^.pDest^.pMethods^.xWrite(p^.pDest, pData, i32(p^.szPage), iOff);
  if rc <> SQLITE_OK then begin
    scrubBackupErr(p, Format('write failed for page %d', [pgno]));
    p^.rcErr := SQLITE_IOERR;
  end;
  if u32(pgno) > p^.iLastPage then p^.iLastPage := u32(pgno);
end;

{ scrub.c:138 — prepare a statement on db. }
function scrubBackupPrepare(p: PScrubState; db: PTsqlite3;
                            zSql: PAnsiChar): Pointer;
var
  pStmt: Pointer;
begin
  if p^.rcErr <> 0 then begin Result := nil; Exit; end;
  pStmt := nil;
  p^.rcErr := sqlite3_prepare_v2(db, zSql, -1, @pStmt, nil);
  if p^.rcErr <> 0 then begin
    scrubBackupErr(p, Format('SQL error "%s" on "%s"',
                             [AnsiString(sqlite3_errmsg(db)),
                              AnsiString(zSql)]));
    sqlite3_finalize(pStmt);
    Result := nil;
    Exit;
  end;
  Result := pStmt;
end;

{ scrub.c:157 — open the source and read PRAGMA page_size / page_count. }
procedure scrubBackupOpenSrc(p: PScrubState);
var
  pStmt: Pointer;
  rc:    i32;
begin
  p^.rcErr := sqlite3_open_v2(p^.zSrcFile, @p^.dbSrc,
                 SQLITE_OPEN_READWRITE or SQLITE_OPEN_URI or
                 SQLITE_OPEN_PRIVATECACHE, nil);
  if p^.rcErr <> 0 then begin
    scrubBackupErr(p, Format('cannot open source database: %s',
                             [AnsiString(sqlite3_errmsg(p^.dbSrc))]));
    Exit;
  end;
  p^.rcErr := sqlite3_exec(p^.dbSrc,
                 'SELECT 1 FROM sqlite_schema; BEGIN;', nil, nil, nil);
  if p^.rcErr <> 0 then begin
    scrubBackupErr(p,
       Format('cannot start a read transaction on the source database: %s',
              [AnsiString(sqlite3_errmsg(p^.dbSrc))]));
    Exit;
  end;
  rc := sqlite3_wal_checkpoint_v2(p^.dbSrc, 'main',
                                  SQLITE_CHECKPOINT_FULL, nil, nil);
  if rc <> 0 then begin
    scrubBackupErr(p, 'cannot checkpoint the source database');
    Exit;
  end;
  pStmt := scrubBackupPrepare(p, p^.dbSrc, 'PRAGMA page_size');
  if pStmt = nil then Exit;
  rc := sqlite3_step(pStmt);
  if rc = SQLITE_ROW then
    p^.szPage := u32(sqlite3_column_int(pStmt, 0))
  else
    scrubBackupErr(p, 'unable to determine the page size');
  sqlite3_finalize(pStmt);
  if p^.rcErr <> 0 then Exit;
  pStmt := scrubBackupPrepare(p, p^.dbSrc, 'PRAGMA page_count');
  if pStmt = nil then Exit;
  rc := sqlite3_step(pStmt);
  if rc = SQLITE_ROW then
    p^.nPage := u32(sqlite3_column_int(pStmt, 0))
  else
    scrubBackupErr(p, 'unable to determine the size of the source database');
  sqlite3_finalize(pStmt);
  sqlite3_file_control(p^.dbSrc, 'main',
                       SQLITE_FCNTL_FILE_POINTER, @p^.pSrc);
  if (p^.pSrc = nil) or (p^.pSrc^.pMethods = nil) then begin
    scrubBackupErr(p, 'cannot get the source file handle');
    p^.rcErr := SQLITE_ERROR;
  end;
end;

{ scrub.c:210 — create / open the destination. }
procedure scrubBackupOpenDest(p: PScrubState);
var
  pStmt: Pointer;
  rc:    i32;
  zSql:  PAnsiChar;
begin
  if p^.rcErr <> 0 then Exit;
  p^.rcErr := sqlite3_open_v2(p^.zDestFile, @p^.dbDest,
                 SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or
                 SQLITE_OPEN_URI or SQLITE_OPEN_PRIVATECACHE, nil);
  if p^.rcErr <> 0 then begin
    scrubBackupErr(p, Format('cannot open destination database: %s',
                             [AnsiString(sqlite3_errmsg(p^.dbDest))]));
    Exit;
  end;
  zSql := PAnsiChar(sqlite3_mprintf(
    PAnsiChar(AnsiString(Format('PRAGMA page_size(%u);', [p^.szPage])))));
  if zSql = nil then begin p^.rcErr := SQLITE_NOMEM; Exit; end;
  p^.rcErr := sqlite3_exec(p^.dbDest, zSql, nil, nil, nil);
  sqlite3_free(zSql);
  if p^.rcErr <> 0 then begin
    scrubBackupErr(p,
       Format('cannot set the page size on the destination database: %s',
              [AnsiString(sqlite3_errmsg(p^.dbDest))]));
    Exit;
  end;
  sqlite3_exec(p^.dbDest, 'PRAGMA journal_mode=OFF;', nil, nil, nil);
  p^.rcErr := sqlite3_exec(p^.dbDest, 'BEGIN EXCLUSIVE;',
                           nil, nil, nil);
  if p^.rcErr <> 0 then begin
    scrubBackupErr(p,
       Format('cannot start a write transaction on the destination database: %s',
              [AnsiString(sqlite3_errmsg(p^.dbDest))]));
    Exit;
  end;
  pStmt := scrubBackupPrepare(p, p^.dbDest, 'PRAGMA page_count;');
  if pStmt = nil then Exit;
  rc := sqlite3_step(pStmt);
  if rc <> SQLITE_ROW then
    scrubBackupErr(p, 'cannot measure the size of the destination')
  else if sqlite3_column_int(pStmt, 0) > 1 then
    scrubBackupErr(p,
       Format('destination database is not empty - holds %d pages',
              [sqlite3_column_int(pStmt, 0)]));
  sqlite3_finalize(pStmt);
  sqlite3_file_control(p^.dbDest, 'main',
                       SQLITE_FCNTL_FILE_POINTER, @p^.pDest);
  if (p^.pDest = nil) or (p^.pDest^.pMethods = nil) then begin
    scrubBackupErr(p, 'cannot get the destination file handle');
    p^.rcErr := SQLITE_ERROR;
  end;
end;

{ scrub.c:262 — read a 32-bit big-endian integer. }
function scrubBackupInt32(a: Pu8): u32; inline;
begin
  Result := u32(a[3]) or (u32(a[2]) shl 8) or
            (u32(a[1]) shl 16) or (u32(a[0]) shl 24);
end;

{ scrub.c:271 — read a 16-bit big-endian integer. }
function scrubBackupInt16(a: Pu8): u32; inline;
begin
  Result := (u32(a[0]) shl 8) or u32(a[1]);
end;

{ scrub.c:278 — varint reader.  Returns byte count, value via pVal. }
function scrubBackupVarint(z: Pu8; pVal: Pi64): i32;
var
  v: i64;
  i: i32;
begin
  v := 0;
  for i := 0 to 7 do begin
    v := (v shl 7) or i64(z[i] and $7f);
    if (z[i] and $80) = 0 then begin
      pVal^ := v; Result := i + 1; Exit;
    end;
  end;
  v := (v shl 8) or i64(z[8] and $ff);
  pVal^ := v;
  Result := 9;
end;

{ scrub.c:293 — return number of bytes spanned by varint at z. }
function scrubBackupVarintSize(z: Pu8): i32;
var
  i: i32;
begin
  for i := 0 to 7 do begin
    if (z[i] and $80) = 0 then begin Result := i + 1; Exit; end;
  end;
  Result := 9;
end;

{ scrub.c:305 — copy freelist trunk + zero descendants. }
procedure scrubBackupFreelist(p: PScrubState; pgno: i32; nFree: u32);
var
  a, aBuf: Pu8;
  n, mx: u32;
begin
  if p^.rcErr <> 0 then Exit;
  aBuf := scrubBackupAllocPage(p);
  if aBuf = nil then Exit;
  while (pgno <> 0) and (nFree <> 0) do begin
    a := scrubBackupRead(p, pgno, aBuf);
    if a = nil then Break;
    n := scrubBackupInt32(@a[4]);
    mx := (p^.szUsable div 4) - 2;
    if n < mx then
      FillChar(a[n*4 + 8], 4 * (mx - n), 0);
    scrubBackupWrite(p, pgno, a);
    pgno := i32(scrubBackupInt32(a));
    { Freelist leaves are intentionally NOT copied — see scrub.c:323..338. }
  end;
  sqlite3_free(aBuf);
end;

{ scrub.c:347 — copy an overflow chain, zeroing the unused tail. }
procedure scrubBackupOverflow(p: PScrubState; pgno: i32; nByte: u32);
var
  a, aBuf: Pu8;
  x, i:    u32;
begin
  aBuf := scrubBackupAllocPage(p);
  if aBuf = nil then Exit;
  while (nByte > 0) and (pgno <> 0) do begin
    a := scrubBackupRead(p, pgno, aBuf);
    if a = nil then Break;
    if nByte >= (p^.szUsable - 4) then begin
      Dec(nByte, p^.szUsable - 4);
    end else begin
      x := (p^.szUsable - 4) - nByte;
      i := p^.szUsable - x;
      FillChar(a[i], x, 0);
      nByte := 0;
    end;
    scrubBackupWrite(p, pgno, a);
    pgno := i32(scrubBackupInt32(a));
  end;
  sqlite3_free(aBuf);
end;

{ scrub.c:374 — recurse over a b-tree page, zero gaps + free blocks,
  recurse into children, and copy overflow chains. }
procedure scrubBackupBtree(p: PScrubState; pgno: i32; iDepth: i32);
label
  btree_corrupt;
var
  a:        Pu8;
  i, n, pc: u32;
  nCell:    u32;
  nPrefix:  u32;
  szHdr:    u32;
  iChild:   u32;
  aTop:     Pu8;
  aCell:    Pu8;
  x, y:     u32;
  ln:       i32;
  X_, M, K, nLocal: u32;
  P_:       i64;
begin
  ln := 0;
  if p^.rcErr <> 0 then Exit;
  if iDepth > 50 then begin
    scrubBackupErr(p, Format('corrupt: b-tree too deep at page %d',
                             [pgno]));
    Exit;
  end;
  if pgno = 1 then
    a := p^.page1
  else begin
    a := scrubBackupRead(p, pgno, nil);
    if a = nil then Exit;
  end;
  if pgno = 1 then nPrefix := 100 else nPrefix := 0;
  aTop := @a[nPrefix];
  if (aTop[0] = $02) or (aTop[0] = $05) then
    szHdr := 12
  else
    szHdr := 8;
  aCell := aTop + szHdr;
  nCell := scrubBackupInt16(@aTop[3]);

  { Zero the gap between cell index and the cell content area. }
  x := scrubBackupInt16(@aTop[5]);
  if x > p^.szUsable then begin ln := 407; goto btree_corrupt; end;
  y := szHdr + nPrefix + nCell * 2;
  if y > x then begin ln := 409; goto btree_corrupt; end;
  if y < x then FillChar(a[y], x - y, 0);

  { Zero out free blocks. }
  pc := scrubBackupInt16(@aTop[1]);
  if (pc > 0) and (pc < x) then begin ln := 414; goto btree_corrupt; end;
  while pc <> 0 do begin
    if pc > p^.szUsable - 4 then begin ln := 416; goto btree_corrupt; end;
    n := scrubBackupInt16(@a[pc + 2]);
    if pc + n > p^.szUsable then begin ln := 418; goto btree_corrupt; end;
    if n > 4 then FillChar(a[pc + 4], n - 4, 0);
    x := scrubBackupInt16(@a[pc]);
    if (x < pc + 4) and (x > 0) then begin ln := 421; goto btree_corrupt; end;
    pc := x;
  end;

  scrubBackupWrite(p, pgno, a);

  { Walk children pointed at by each cell. }
  i := 0;
  while i < nCell do begin
    pc := scrubBackupInt16(@aCell[i * 2]);
    if pc <= szHdr then begin ln := 433; goto btree_corrupt; end;
    if pc > p^.szUsable - 3 then begin ln := 434; goto btree_corrupt; end;
    if (aTop[0] = $05) or (aTop[0] = $02) then begin
      if pc + 4 > p^.szUsable then begin ln := 436; goto btree_corrupt; end;
      iChild := scrubBackupInt32(@a[pc]);
      Inc(pc, 4);
      scrubBackupBtree(p, i32(iChild), iDepth + 1);
      if aTop[0] = $05 then begin Inc(i); Continue; end;
    end;
    Inc(pc, u32(scrubBackupVarint(@a[pc], @P_)));
    if pc >= p^.szUsable then begin ln := 443; goto btree_corrupt; end;
    if aTop[0] = $0d then
      X_ := p^.szUsable - 35
    else
      X_ := ((p^.szUsable - 12) * 64 div 255) - 23;
    if P_ <= i64(X_) then begin
      Inc(i); Continue;
    end;
    M := ((p^.szUsable - 12) * 32 div 255) - 23;
    K := M + u32((P_ - i64(M)) mod i64(p^.szUsable - 4));
    if aTop[0] = $0d then begin
      Inc(pc, u32(scrubBackupVarintSize(@a[pc])));
      if pc > p^.szUsable - 4 then begin ln := 457; goto btree_corrupt; end;
    end;
    if K <= X_ then nLocal := K else nLocal := M;
    if pc + nLocal > p^.szUsable - 4 then begin ln := 460; goto btree_corrupt; end;
    iChild := scrubBackupInt32(@a[pc + nLocal]);
    scrubBackupOverflow(p, i32(iChild), u32(P_ - i64(nLocal)));
    Inc(i);
  end;

  { Right-most child for interior pages. }
  if (aTop[0] = $05) or (aTop[0] = $02) then begin
    iChild := scrubBackupInt32(@aTop[8]);
    scrubBackupBtree(p, i32(iChild), iDepth + 1);
  end;

  if pgno > 1 then sqlite3_free(a);
  Exit;

btree_corrupt:
  scrubBackupErr(p,
    Format('corruption on page %d of source database (errid=%d)',
           [pgno, ln]));
  if pgno > 1 then sqlite3_free(a);
end;

{ scrub.c:486 — copy ptrmap pages.  Only called when the source file
  is in (incremental) auto-vacuum mode. }
procedure scrubBackupPtrmap(p: PScrubState);
var
  pgno, J, iLock: u32;
  a, pBuf:        Pu8;
begin
  pgno  := 2;
  J     := p^.szUsable div 5;
  iLock := (1073742335 div p^.szPage) + 1;
  if p^.rcErr <> 0 then Exit;
  pBuf := scrubBackupAllocPage(p);
  if pBuf = nil then Exit;
  while pgno <= p^.nPage do begin
    a := scrubBackupRead(p, i32(pgno), pBuf);
    if a = nil then Break;
    scrubBackupWrite(p, i32(pgno), a);
    Inc(pgno, J + 1);
    if pgno = iLock then Inc(pgno);
  end;
  sqlite3_free(pBuf);
end;

{ scrub.c:504 — public entry. }
function sqlite3_scrub_backup(zSrcFile, zDestFile: PAnsiChar;
                              pzErr: PPAnsiChar): i32; cdecl;
label
  scrub_abort;
var
  s:     TScrubState;
  n, i:  u32;
  pStmt: Pointer;
  aZero: Pu8;
begin
  FillChar(s, SizeOf(s), 0);
  s.zSrcFile  := zSrcFile;
  s.zDestFile := zDestFile;

  scrubBackupOpenSrc(@s);
  scrubBackupOpenDest(@s);

  s.page1 := scrubBackupRead(@s, 1, nil);
  if s.page1 = nil then goto scrub_abort;
  s.szUsable := s.szPage - u32(s.page1[20]);

  { Copy the freelist. }
  n := scrubBackupInt32(@s.page1[36]);
  i := scrubBackupInt32(@s.page1[32]);
  if n <> 0 then scrubBackupFreelist(@s, i32(i), n);

  { Copy ptrmap pages if the file is in autovacuum mode. }
  n := scrubBackupInt32(@s.page1[52]);
  if n <> 0 then scrubBackupPtrmap(@s);

  { Walk all the btrees rooted in sqlite_schema (plus root=1). }
  scrubBackupBtree(@s, 1, 0);
  pStmt := scrubBackupPrepare(@s, s.dbSrc,
       'SELECT rootpage FROM sqlite_schema WHERE coalesce(rootpage,0)>0');
  if pStmt = nil then goto scrub_abort;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    i := u32(sqlite3_column_int(pStmt, 0));
    scrubBackupBtree(@s, i32(i), 0);
  end;
  sqlite3_finalize(pStmt);

  { Write a trailing page of zeroes if the on-disk size still trails
    the header-declared page count (last input page may be a freelist
    leaf which we deliberately skipped). }
  if s.iLastPage < s.nPage then begin
    aZero := scrubBackupAllocPage(@s);
    if aZero <> nil then begin
      FillChar(aZero^, s.szPage, 0);
      scrubBackupWrite(@s, i32(s.nPage), aZero);
      sqlite3_free(aZero);
    end;
  end;

scrub_abort:
  { Close destination WITHOUT committing — committing would overwrite
    page 1 with the (possibly different) destination's header. }
  sqlite3_close(s.dbDest);
  sqlite3_exec(s.dbSrc, 'COMMIT;', nil, nil, nil);
  sqlite3_close(s.dbSrc);
  if s.page1 <> nil then sqlite3_free(s.page1);
  if pzErr <> nil then
    pzErr^ := s.zErr
  else if s.zErr <> nil then
    sqlite3_free(s.zErr);
  Result := s.rcErr;
end;

end.
