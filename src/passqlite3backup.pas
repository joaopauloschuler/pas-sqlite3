{$I passqlite3.inc}
unit passqlite3backup;

{
  Phase 8.7 — backup.c port (the online-backup API).

  Public entry points (sqlite3.h):
    sqlite3_backup_init       — create a backup handle.
    sqlite3_backup_step       — copy nPage source pages to destination.
    sqlite3_backup_finish     — release a backup handle (and report status).
    sqlite3_backup_remaining  — pages still to be backed up.
    sqlite3_backup_pagecount  — total pages as of the last step.

  Internal entry points (called by pager / btree.c):
    sqlite3BackupUpdate       — invoked when a copied source page is dirtied.
    sqlite3BackupRestart      — invoked when the source schema is invalidated.
    sqlite3BtreeCopyFile      — used by VACUUM (btree.c-side public name).

  Faithful port of ../sqlite3/src/backup.c (~770 lines).  Field order in
  Tsqlite3_backup matches the C struct exactly so that pPager^.pBackup,
  threaded through the linked list rooted at Pager.pBackup, can be cast
  freely between Pascal and (eventual) C consumers.

  Phase 8.7 scope and known gaps:
    * The pager does not yet invoke sqlite3BackupUpdate / sqlite3BackupRestart
      from its write path — those hooks land with Phase 9 (acceptance).  A
      backup of a quiescent source therefore works end-to-end; concurrent
      writes during a step will not yet replicate dirty pages.
    * sqlite3LeaveMutexAndCloseZombie is not invoked on backup_finish — the
      "destination database closed during backup" zombie path is not wired
      in this initial port.  finish() falls back to a plain rollback +
      sqlite3Error for the destination handle.
    * sqlite3OpenTempDatabase is referenced by findBtree() for the magic
      "temp" name.  The Phase 8.1 openDatabase already eagerly populates
      aDb[1], so the temp branch of findBtree is effectively dead code in
      this port; it is included for future compatibility.
}

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen;

type
  PSqlite3Backup = ^TSqlite3Backup;
  TSqlite3Backup = record
    pDestDb     : PTsqlite3;       { Destination database handle }
    pDest       : PBtree;          { Destination b-tree file }
    iDestSchema : u32;             { Original schema cookie in destination }
    bDestLocked : i32;             { True once a write-txn open on pDest }

    iNext       : Pgno;            { Page number of next source page to copy }
    pSrcDb      : PTsqlite3;       { Source database handle }
    pSrc        : PBtree;          { Source b-tree file }

    rc          : i32;             { Backup process error code }

    nRemaining  : Pgno;            { Number of pages left to copy }
    nPagecount  : Pgno;            { Total number of pages to copy }

    isAttached  : i32;             { Registered with pager }
    pNext       : PSqlite3Backup;  { Next backup on source pager's list }
  end;

{ Public API. }
function  sqlite3_backup_init(pDestDb: PTsqlite3; zDestDb: PAnsiChar;
                              pSrcDb:  PTsqlite3; zSrcDb:  PAnsiChar): PSqlite3Backup;
function  sqlite3_backup_step(p: PSqlite3Backup; nPage: i32): i32;
function  sqlite3_backup_finish(p: PSqlite3Backup): i32;
function  sqlite3_backup_remaining(p: PSqlite3Backup): i32;
function  sqlite3_backup_pagecount(p: PSqlite3Backup): i32;

{ Internal entry points (pager/btree-side). }
procedure sqlite3BackupUpdate(pBackup: PSqlite3Backup; iPage: Pgno; aData: Pu8);
procedure sqlite3BackupRestart(pBackup: PSqlite3Backup);

{ btree.c — used by VACUUM.  Kept here because it is a thin wrapper over
  the backup machinery; the C source places it in the same translation unit. }
function  sqlite3BtreeCopyFile(pTo, pFrom: PBtree): i32;

implementation

{ Page mappings — backup.c calls PENDING_BYTE_PAGE(pBt) extensively.
  We compute it from the public BtShared fields exposed via the Btree pointer. }
function PendingBytePageOfBtree(p: PBtree): Pgno; inline;
begin
  Result := Pgno(PENDING_BYTE div p^.pBt^.pageSize) + 1;
end;

function MinI64(a, b: i64): i64; inline;
begin
  if a < b then Result := a else Result := b;
end;

function MinI32(a, b: i32): i32; inline;
begin
  if a < b then Result := a else Result := b;
end;

{ ---------------------------------------------------------------------------
  findBtree — backup.c:82
  --------------------------------------------------------------------------- }
function findBtree(pErrorDb, pDb: PTsqlite3; zDb: PAnsiChar): PBtree;
var
  i : i32;
begin
  i := sqlite3FindDbName(pDb, zDb);
  { The "temp" branch (i=1) of the C source needs OpenTempDatabase; our
    openDatabase already does this eagerly so we can simply trust aDb[1]. }
  if i < 0 then begin
    sqlite3ErrorWithMsg(pErrorDb, SQLITE_ERROR, 'unknown database');
    Result := nil;
    Exit;
  end;
  Result := PBtree(pDb^.aDb[i].pBt);
end;

{ ---------------------------------------------------------------------------
  setDestPgsz — backup.c:112
  --------------------------------------------------------------------------- }
function setDestPgsz(p: PSqlite3Backup): i32;
begin
  Result := sqlite3BtreeSetPageSize(p^.pDest,
                                    sqlite3BtreeGetPageSize(p^.pSrc), 0, 0);
end;

{ ---------------------------------------------------------------------------
  checkReadTransaction — backup.c:124
  --------------------------------------------------------------------------- }
function checkReadTransaction(db: PTsqlite3; p: PBtree): i32;
begin
  if sqlite3BtreeTxnState(p) <> SQLITE_TXN_NONE then begin
    sqlite3ErrorWithMsg(db, SQLITE_ERROR, 'destination database is in use');
    Result := SQLITE_ERROR;
    Exit;
  end;
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  isFatalError — backup.c:217
  --------------------------------------------------------------------------- }
function isFatalError(rc: i32): Boolean; inline;
begin
  Result := (rc <> SQLITE_OK) and (rc <> SQLITE_BUSY) and (rc <> SQLITE_LOCKED);
end;

{ ---------------------------------------------------------------------------
  attachBackupObject — backup.c:302
  --------------------------------------------------------------------------- }
procedure attachBackupObject(p: PSqlite3Backup);
var
  pp : PPointer;
begin
  pp := sqlite3PagerBackupPtr(sqlite3BtreePager(p^.pSrc));
  p^.pNext := PSqlite3Backup(pp^);
  pp^ := p;
  p^.isAttached := 1;
end;

{ ---------------------------------------------------------------------------
  backupOnePage — backup.c:226
  --------------------------------------------------------------------------- }
function backupOnePage(p: PSqlite3Backup; iSrcPg: Pgno; zSrcData: Pu8;
                       bUpdate: i32): i32;
var
  pDestPager : PPager;
  nSrcPgsz   : i32;
  nDestPgsz  : i32;
  nCopy      : i32;
  iEnd       : i64;
  rc         : i32;
  iOff       : i64;
  pDestPg    : PDbPage;
  iDest      : Pgno;
  zIn        : Pu8;
  zDestData  : Pu8;
  zOut       : Pu8;
begin
  pDestPager := sqlite3BtreePager(p^.pDest);
  nSrcPgsz   := sqlite3BtreeGetPageSize(p^.pSrc);
  nDestPgsz  := sqlite3BtreeGetPageSize(p^.pDest);
  nCopy      := MinI32(nSrcPgsz, nDestPgsz);
  iEnd       := i64(iSrcPg) * i64(nSrcPgsz);
  rc         := SQLITE_OK;

  iOff := iEnd - i64(nSrcPgsz);
  while (rc = SQLITE_OK) and (iOff < iEnd) do begin
    pDestPg := nil;
    iDest   := Pgno(iOff div i64(nDestPgsz)) + 1;
    if iDest = PendingBytePageOfBtree(p^.pDest) then begin
      iOff := iOff + i64(nDestPgsz);
      Continue;
    end;
    rc := sqlite3PagerGet(pDestPager, iDest, @pDestPg, 0);
    if rc = SQLITE_OK then begin
      rc := sqlite3PagerWrite(pDestPg);
      if rc = SQLITE_OK then begin
        zIn       := Pu8(zSrcData) + (iOff mod i64(nSrcPgsz));
        zDestData := Pu8(sqlite3PagerGetData(pDestPg));
        zOut      := zDestData + (iOff mod i64(nDestPgsz));
        Move(zIn^, zOut^, nCopy);
        Pu8(sqlite3PagerGetExtra(pDestPg))[0] := 0;
        if (iOff = 0) and (bUpdate = 0) then
          sqlite3Put4byte(zOut + 28, u32(sqlite3BtreeLastPage(p^.pSrc)));
      end;
    end;
    sqlite3PagerUnref(pDestPg);
    iOff := iOff + i64(nDestPgsz);
  end;
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  backupTruncateFile — backup.c:289
  --------------------------------------------------------------------------- }
function backupTruncateFile(pFile: Psqlite3_file; iSize: i64): i32;
var
  iCurrent : i64;
  rc       : i32;
begin
  rc := sqlite3OsFileSize(pFile, @iCurrent);
  if (rc = SQLITE_OK) and (iCurrent > iSize) then
    rc := sqlite3OsTruncate(pFile, iSize);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  sqlite3_backup_init — backup.c:140
  --------------------------------------------------------------------------- }
function sqlite3_backup_init(pDestDb: PTsqlite3; zDestDb: PAnsiChar;
                             pSrcDb:  PTsqlite3; zSrcDb:  PAnsiChar): PSqlite3Backup;
var
  p : PSqlite3Backup;
begin
  if (sqlite3SafetyCheckOk(pSrcDb) = 0) or
     (sqlite3SafetyCheckOk(pDestDb) = 0) then
  begin
    Result := nil;
    Exit;
  end;

  sqlite3_mutex_enter(pSrcDb^.mutex);
  sqlite3_mutex_enter(pDestDb^.mutex);

  if pSrcDb = pDestDb then begin
    sqlite3ErrorWithMsg(pDestDb, SQLITE_ERROR,
                        'source and destination must be distinct');
    p := nil;
  end else begin
    p := PSqlite3Backup(sqlite3MallocZero(SizeOf(TSqlite3Backup)));
    if p = nil then sqlite3Error(pDestDb, SQLITE_NOMEM);
  end;

  if p <> nil then begin
    p^.pSrc      := findBtree(pDestDb, pSrcDb,  zSrcDb);
    p^.pDest     := findBtree(pDestDb, pDestDb, zDestDb);
    p^.pDestDb   := pDestDb;
    p^.pSrcDb    := pSrcDb;
    p^.iNext     := 1;
    p^.isAttached := 0;

    if (p^.pSrc = nil) or (p^.pDest = nil) or
       (checkReadTransaction(pDestDb, p^.pDest) <> SQLITE_OK) then
    begin
      sqlite3_free(p);
      p := nil;
    end;
  end;

  if p <> nil then
    Inc(p^.pSrc^.nBackup);

  sqlite3_mutex_leave(pDestDb^.mutex);
  sqlite3_mutex_leave(pSrcDb^.mutex);
  Result := p;
end;

{ ---------------------------------------------------------------------------
  sqlite3_backup_step — backup.c:314
  --------------------------------------------------------------------------- }
function sqlite3_backup_step(p: PSqlite3Backup; nPage: i32): i32;
var
  rc          : i32;
  destMode    : i32;
  pgszSrc     : i32;
  pgszDest    : i32;
  pSrcPager   : PPager;
  pDestPager  : PPager;
  ii          : i32;
  nSrcPage    : i32;
  bCloseTrans : i32;
  iSrcPg      : Pgno;
  pSrcPg      : PDbPage;
  nDestTruncate : i32;
  ratio       : i32;
  iSize       : i64;
  pFile       : Psqlite3_file;
  iPg, iEnd   : i64;
  iOff        : i64;
  nDstPage    : i32;
  pPg         : PDbPage;
  zData       : Pu8;
  iSrcPgInner : Pgno;
  pSrcPgInner : PDbPage;
begin
  if p = nil then begin Result := SQLITE_MISUSE; Exit; end;

  sqlite3_mutex_enter(p^.pSrcDb^.mutex);
  sqlite3BtreeEnter(p^.pSrc);
  if p^.pDestDb <> nil then sqlite3_mutex_enter(p^.pDestDb^.mutex);

  rc       := p^.rc;
  destMode := 0;
  pgszSrc  := 0;
  pgszDest := 0;
  if not isFatalError(rc) then begin
    pSrcPager  := sqlite3BtreePager(p^.pSrc);
    pDestPager := sqlite3BtreePager(p^.pDest);
    nSrcPage   := -1;
    bCloseTrans := 0;

    if (p^.pDestDb <> nil) and
       (p^.pSrc^.pBt^.inTransaction = TRANS_WRITE) then
      rc := SQLITE_BUSY
    else
      rc := SQLITE_OK;

    if (rc = SQLITE_OK) and
       (sqlite3BtreeTxnState(p^.pSrc) = SQLITE_TXN_NONE) then
    begin
      rc := sqlite3BtreeBeginTrans(p^.pSrc, 0, nil);
      bCloseTrans := 1;
    end;

    if (p^.bDestLocked = 0) and (rc = SQLITE_OK) and
       (setDestPgsz(p) = SQLITE_NOMEM) then
      rc := SQLITE_NOMEM;

    if (rc = SQLITE_OK) and (p^.bDestLocked = 0) then begin
      rc := sqlite3BtreeBeginTrans(p^.pDest, 2, Pi32(@p^.iDestSchema));
      if rc = SQLITE_OK then p^.bDestLocked := 1;
    end;

    pgszSrc  := sqlite3BtreeGetPageSize(p^.pSrc);
    pgszDest := sqlite3BtreeGetPageSize(p^.pDest);
    destMode := sqlite3PagerGetJournalMode(sqlite3BtreePager(p^.pDest));
    if (rc = SQLITE_OK) and
       ((destMode = PAGER_JOURNALMODE_WAL) or
        (sqlite3PagerIsMemdb(pDestPager) <> 0)) and
       (pgszSrc <> pgszDest) then
      rc := SQLITE_READONLY;

    nSrcPage := i32(sqlite3BtreeLastPage(p^.pSrc));
    ii := 0;
    while ((nPage < 0) or (ii < nPage)) and
          (p^.iNext <= Pgno(nSrcPage)) and (rc = SQLITE_OK) do
    begin
      iSrcPg := p^.iNext;
      if iSrcPg <> PendingBytePageOfBtree(p^.pSrc) then begin
        pSrcPg := nil;
        rc := sqlite3PagerGet(pSrcPager, iSrcPg, @pSrcPg, PAGER_GET_READONLY);
        if rc = SQLITE_OK then begin
          rc := backupOnePage(p, iSrcPg, sqlite3PagerGetData(pSrcPg), 0);
          sqlite3PagerUnref(pSrcPg);
        end;
      end;
      Inc(p^.iNext);
      Inc(ii);
    end;
    if rc = SQLITE_OK then begin
      p^.nPagecount := Pgno(nSrcPage);
      p^.nRemaining := Pgno(nSrcPage + 1) - p^.iNext;
      if p^.iNext > Pgno(nSrcPage) then
        rc := SQLITE_DONE
      else if p^.isAttached = 0 then
        attachBackupObject(p);
    end;

    if rc = SQLITE_DONE then begin
      if nSrcPage = 0 then begin
        rc := sqlite3BtreeNewDb(p^.pDest);
        nSrcPage := 1;
      end;
      if (rc = SQLITE_OK) or (rc = SQLITE_DONE) then
        rc := sqlite3BtreeUpdateMeta(p^.pDest, 1, p^.iDestSchema + 1);
      if rc = SQLITE_OK then begin
        if p^.pDestDb <> nil then
          sqlite3ResetAllSchemasOfConnection(p^.pDestDb);
        if destMode = PAGER_JOURNALMODE_WAL then
          rc := sqlite3BtreeSetVersion(p^.pDest, 2);
      end;
      if rc = SQLITE_OK then begin
        if pgszSrc < pgszDest then begin
          ratio := pgszDest div pgszSrc;
          nDestTruncate := (nSrcPage + ratio - 1) div ratio;
          if nDestTruncate = i32(PendingBytePageOfBtree(p^.pDest)) then
            Dec(nDestTruncate);
        end else
          nDestTruncate := nSrcPage * (pgszSrc div pgszDest);

        if pgszSrc < pgszDest then begin
          iSize := i64(pgszSrc) * i64(nSrcPage);
          pFile := sqlite3PagerFile(pDestPager);
          sqlite3PagerPagecount(pDestPager, @nDstPage);
          iPg := nDestTruncate;
          while (rc = SQLITE_OK) and (iPg <= i64(nDstPage)) do begin
            if Pgno(iPg) <> PendingBytePageOfBtree(p^.pDest) then begin
              pPg := nil;
              rc := sqlite3PagerGet(pDestPager, Pgno(iPg), @pPg, 0);
              if rc = SQLITE_OK then begin
                rc := sqlite3PagerWrite(pPg);
                sqlite3PagerUnref(pPg);
              end;
            end;
            Inc(iPg);
          end;
          if rc = SQLITE_OK then
            rc := sqlite3PagerCommitPhaseOne(pDestPager, nil, 1);

          iEnd := MinI64(PENDING_BYTE + i64(pgszDest), iSize);
          iOff := PENDING_BYTE + i64(pgszSrc);
          while (rc = SQLITE_OK) and (iOff < iEnd) do begin
            pSrcPgInner := nil;
            iSrcPgInner := Pgno((iOff div i64(pgszSrc)) + 1);
            rc := sqlite3PagerGet(pSrcPager, iSrcPgInner, @pSrcPgInner, 0);
            if rc = SQLITE_OK then begin
              zData := Pu8(sqlite3PagerGetData(pSrcPgInner));
              rc := sqlite3OsWrite(pFile, zData, pgszSrc, iOff);
            end;
            sqlite3PagerUnref(pSrcPgInner);
            iOff := iOff + i64(pgszSrc);
          end;
          if rc = SQLITE_OK then
            rc := backupTruncateFile(pFile, iSize);
          if rc = SQLITE_OK then
            rc := sqlite3PagerSync(pDestPager, nil);
        end else begin
          sqlite3PagerTruncateImage(pDestPager, Pgno(nDestTruncate));
          rc := sqlite3PagerCommitPhaseOne(pDestPager, nil, 0);
        end;

        if (rc = SQLITE_OK) and
           ((sqlite3BtreeCommitPhaseTwo(p^.pDest, 0)) = SQLITE_OK) then
          rc := SQLITE_DONE;
      end;
    end;

    if bCloseTrans <> 0 then begin
      sqlite3BtreeCommitPhaseOne(p^.pSrc, nil);
      sqlite3BtreeCommitPhaseTwo(p^.pSrc, 0);
    end;

    if rc = SQLITE_IOERR_NOMEM then rc := SQLITE_NOMEM;
    p^.rc := rc;
  end;

  if p^.pDestDb <> nil then sqlite3_mutex_leave(p^.pDestDb^.mutex);
  sqlite3BtreeLeave(p^.pSrc);
  sqlite3_mutex_leave(p^.pSrcDb^.mutex);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  sqlite3_backup_finish — backup.c:571
  --------------------------------------------------------------------------- }
function sqlite3_backup_finish(p: PSqlite3Backup): i32;
var
  pp     : PPointer;
  pSrcDb : PTsqlite3;
  rc     : i32;
  cur    : PSqlite3Backup;
  prev   : PSqlite3Backup;
begin
  if p = nil then begin Result := SQLITE_OK; Exit; end;

  pSrcDb := p^.pSrcDb;
  sqlite3_mutex_enter(pSrcDb^.mutex);
  sqlite3BtreeEnter(p^.pSrc);
  if p^.pDestDb <> nil then sqlite3_mutex_enter(p^.pDestDb^.mutex);

  if p^.pDestDb <> nil then
    Dec(p^.pSrc^.nBackup);
  if p^.isAttached <> 0 then begin
    pp  := sqlite3PagerBackupPtr(sqlite3BtreePager(p^.pSrc));
    cur := PSqlite3Backup(pp^);
    prev := nil;
    while (cur <> nil) and (cur <> p) do begin
      prev := cur;
      cur  := cur^.pNext;
    end;
    if cur = p then begin
      if prev = nil then pp^ := p^.pNext
      else               prev^.pNext := p^.pNext;
    end;
  end;

  sqlite3BtreeRollback(p^.pDest, SQLITE_OK, 0);

  if p^.rc = SQLITE_DONE then rc := SQLITE_OK
  else                        rc := p^.rc;

  if p^.pDestDb <> nil then begin
    sqlite3Error(p^.pDestDb, rc);
    sqlite3_mutex_leave(p^.pDestDb^.mutex);
  end;
  sqlite3BtreeLeave(p^.pSrc);
  if p^.pDestDb <> nil then sqlite3_free(p);
  sqlite3_mutex_leave(pSrcDb^.mutex);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  sqlite3_backup_remaining / pagecount — backup.c:625 / :639
  --------------------------------------------------------------------------- }
function sqlite3_backup_remaining(p: PSqlite3Backup): i32;
begin
  if p = nil then begin Result := 0; Exit; end;
  Result := i32(p^.nRemaining);
end;

function sqlite3_backup_pagecount(p: PSqlite3Backup): i32;
begin
  if p = nil then begin Result := 0; Exit; end;
  Result := i32(p^.nPagecount);
end;

{ ---------------------------------------------------------------------------
  backupUpdate / sqlite3BackupUpdate — backup.c:661 / :686
  --------------------------------------------------------------------------- }
procedure backupUpdate(p: PSqlite3Backup; iPage: Pgno; aData: Pu8);
var
  rc : i32;
begin
  while p <> nil do begin
    if (not isFatalError(p^.rc)) and (iPage < p^.iNext) then begin
      sqlite3_mutex_enter(p^.pDestDb^.mutex);
      rc := backupOnePage(p, iPage, aData, 1);
      sqlite3_mutex_leave(p^.pDestDb^.mutex);
      if rc <> SQLITE_OK then p^.rc := rc;
    end;
    p := p^.pNext;
  end;
end;

procedure sqlite3BackupUpdate(pBackup: PSqlite3Backup; iPage: Pgno; aData: Pu8);
begin
  if pBackup <> nil then backupUpdate(pBackup, iPage, aData);
end;

{ ---------------------------------------------------------------------------
  sqlite3BackupRestart — backup.c:701
  --------------------------------------------------------------------------- }
procedure sqlite3BackupRestart(pBackup: PSqlite3Backup);
var
  p : PSqlite3Backup;
begin
  p := pBackup;
  while p <> nil do begin
    p^.iNext := 1;
    p := p^.pNext;
  end;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeCopyFile — backup.c:718 (used by VACUUM)
  --------------------------------------------------------------------------- }
function sqlite3BtreeCopyFile(pTo, pFrom: PBtree): i32;
var
  rc : i32;
  b  : TSqlite3Backup;
begin
  sqlite3BtreeEnter(pTo);
  sqlite3BtreeEnter(pFrom);

  FillChar(b, SizeOf(b), 0);
  b.pSrcDb := pFrom^.db;
  b.pSrc   := pFrom;
  b.pDest  := pTo;
  b.iNext  := 1;

  sqlite3_backup_step(@b, $7FFFFFFF);
  rc := sqlite3_backup_finish(@b);
  if rc = SQLITE_OK then
    pTo^.pBt^.btsFlags := pTo^.pBt^.btsFlags and not BTS_PAGESIZE_FIXED
  else
    sqlite3PagerClearCache(sqlite3BtreePager(b.pDest));

  sqlite3BtreeLeave(pFrom);
  sqlite3BtreeLeave(pTo);
  Result := rc;
end;

{ pager_reset (pager.c:1772) calls sqlite3BackupRestart, but passqlite3backup
  uses passqlite3pager.  Install ourselves via the hook variable so the call
  goes through without a circular unit dependency. }
procedure pagerBackupRestartHook(pHead: Pointer);
begin
  sqlite3BackupRestart(PSqlite3Backup(pHead));
end;

initialization
  sqlite3PagerBackupRestartFn := @pagerBackupRestartHook;

end.
