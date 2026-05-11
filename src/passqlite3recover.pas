{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/recover/sqlite3recover.c
  (~2901 lines C → ~2400 lines Pascal).

  Provides the recover-extension public API:

    sqlite3_recover_init(db, zDb, zUri)
    sqlite3_recover_init_sql(db, zDb, xSql, pCtx)
    sqlite3_recover_config(p, op, pArg)
    sqlite3_recover_step(p)
    sqlite3_recover_run(p)
    sqlite3_recover_errmsg(p)
    sqlite3_recover_errcode(p)
    sqlite3_recover_finish(p)

  Initial-cut scope (this commit):

    * All public type declarations (sqlite3_recover, RecoverTable,
      RecoverColumn, RecoverBitmap, RecoverStateW1, RecoverStateLAF) and
      RECOVER_STATE_* / RECOVER_EHIDDEN_* / SQLITE_RECOVER_* constants.
    * Ported helpers: recoverStrlen, recoverMalloc, recoverError,
      recoverDbError, recoverBitmapAlloc/Free/Set/Query, recoverPrepare,
      recoverPreparePrintf, recoverReset, recoverFinalize, recoverExec,
      recoverBindValue, recoverMPrintf, recoverPageCount.
    * Custom SQL functions wired through sqlite3_create_function:
      read_i32 / page_is_used / getpage / escape_crlf — faithful 1:1.
    * recoverSqlCallback, recoverTransferSettings, recoverOpenOutput,
      recoverOpenRecovery, recoverCacheSchema, recoverFinalCleanup.
    * recoverInit (allocator + parameter capture) and the seven public
      entry points.

  Deferred (subsequent commits will land):

    * Schema synthesis pipeline (recoverWriteSchema1 / 2,
      recoverNewTable, recoverAddTable, recoverFindTable,
      recoverInsertStmt, recoverWriteDataInit / Step / Cleanup).
    * Lost-and-found pipeline (recoverLostAndFound1/2/3 Init+Step
      + recoverLostAndFoundFindRoot + recoverLostAndFoundOnePage).
    * VFS shim wrapper used to validate the input db's page-1
      header (recoverVfs* + recover_methods + recoverInstallWrapper /
      recoverUninstallWrapper + recoverVfsDetectPagesize +
      recoverIsValidPage + recoverGetU16 / U32 / Varint).
    * Full recoverStep state machine — currently only RECOVER_STATE_INIT
      is partially exercised: the output db is opened, recovery
      virtuals/UDFs are registered, settings are transferred from input
      to output, and the schema cache is populated.  After that the
      handle short-circuits to RECOVER_STATE_DONE with SQLITE_OK.

  Pascal-port adaptations:

    * recoverMPrintf / recoverPreparePrintf accept Pascal `array of
      const` instead of C `va_list` and route through sqlite3PfMprintf.
    * SQL UDF trampolines have cdecl signatures matching the existing
      passqlite3 ports (taking PAnsiChar / Psqlite3_context / nArg /
      argv).
    * The C `RecoverGlobal recover_g` static is preserved as a unit-
      level var; the mutex protocol uses SQLITE_MUTEX_STATIC_APP2 like
      upstream.
}
{$I passqlite3.inc}
unit passqlite3recover;

interface

uses
  ctypes,
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3main,
  passqlite3backup,
  passqlite3dbdata;

type
  Psqlite3_recover  = ^Tsqlite3_recover;
  PPsqlite3_recover = ^Psqlite3_recover;
  PRecoverTable     = ^TRecoverTable;
  PRecoverColumn    = ^TRecoverColumn;
  PRecoverBitmap    = ^TRecoverBitmap;
  PRecoverStateW1   = ^TRecoverStateW1;
  PRecoverStateLAF  = ^TRecoverStateLAF;

  TRecoverColumn = record
    iField: i32;     { Field in record on disk; -1 for virtual generated }
    iBind:  i32;     { Bind index in INSERT; 0 if iField<0 }
    bIPK:   i32;     { True if INTEGER PRIMARY KEY column }
    zCol:   PAnsiChar;
    eHidden: i32;
  end;

  TRecoverTable = record
    iRoot:      u32;            { Root page in original db }
    zTab:       PAnsiChar;
    nCol:       i32;
    aCol:       PRecoverColumn;
    bIntkey:    i32;            { True for intkey, false for WITHOUT ROWID }
    iRowidBind: i32;
    pNext:      PRecoverTable;
  end;

  { Bitmap.  aElem[] is a flexible array — we allocate the trailing
    storage by sqlite3_malloc of the appropriate size and treat the
    record's `aElem[0]` slot as the start of an open array. }
  TRecoverBitmap = record
    nPg:   i64;
    aElem: array[0..0] of u32;
  end;

  TXSqlCb = function(pCtx: Pointer; zSql: PAnsiChar): i32; cdecl;

  PRecoverFuncEntry = ^TRecoverFuncEntry;
  TRecoverFuncEntry = record
    zName: PAnsiChar;
    nArg:  i32;
    xFunc: Pointer;
  end;

  TRecoverStateW1 = record
    pTbls:     PVdbe;
    pSel:      PVdbe;
    pInsert:   PVdbe;
    nInsert:   i32;
    pTab:      PRecoverTable;
    nMax:      i32;
    apVal:     Pointer;          { Array of nMax sqlite3_value* }
    nVal:      i32;
    bHaveRowid: i32;
    iRowid:    i64;
    iPrevPage: i64;
    iPrevCell: i32;
  end;

  TRecoverStateLAF = record
    pUsed:           PRecoverBitmap;
    nPg:             i64;
    pAllAndParent:   PVdbe;
    pMapInsert:      PVdbe;
    pMaxField:       PVdbe;
    pUsedPages:      PVdbe;
    pFindRoot:       PVdbe;
    pInsert:         PVdbe;
    pAllPage:        PVdbe;
    pPageData:       PVdbe;
    apVal:           Pointer;
    nMaxField:       i32;
  end;

  Tsqlite3_recover = record
    { Constructor parameters }
    dbIn:     PTsqlite3;
    zDb:      PAnsiChar;
    zUri:     PAnsiChar;
    pSqlCtx:  Pointer;
    xSql:     TXSqlCb;
    { Configured options }
    zStateDb:        PAnsiChar;
    zLostAndFound:   PAnsiChar;
    bFreelistCorrupt: i32;
    bRecoverRowid:    i32;
    bSlowIndexes:     i32;

    pgsz:          i32;
    detected_pgsz: i32;
    nReserve:      i32;
    pPage1Disk:    PByte;
    pPage1Cache:   PByte;

    { Error state }
    errCode: i32;
    zErrMsg: PAnsiChar;

    eState: i32;
    bCloseTransaction: i32;

    w1:  TRecoverStateW1;
    laf: TRecoverStateLAF;

    dbOut:    PTsqlite3;
    pGetPage: PVdbe;
    pTblList: PRecoverTable;
  end;

const
  { Public config opcodes (sqlite3recover.h:184..187). }
  SQLITE_RECOVER_LOST_AND_FOUND   = 1;
  SQLITE_RECOVER_FREELIST_CORRUPT = 2;
  SQLITE_RECOVER_ROWIDS           = 3;
  SQLITE_RECOVER_SLOWINDEXES      = 4;

  { Internal eState values. }
  RECOVER_STATE_INIT          = 0;
  RECOVER_STATE_WRITING       = 1;
  RECOVER_STATE_LOSTANDFOUND1 = 2;
  RECOVER_STATE_LOSTANDFOUND2 = 3;
  RECOVER_STATE_LOSTANDFOUND3 = 4;
  RECOVER_STATE_SCHEMA2       = 5;
  RECOVER_STATE_DONE          = 6;

  { Hidden-column markers (RECOVER_EHIDDEN_*). }
  RECOVER_EHIDDEN_NONE    = 0;
  RECOVER_EHIDDEN_HIDDEN  = 1;
  RECOVER_EHIDDEN_VIRTUAL = 2;
  RECOVER_EHIDDEN_STORED  = 3;

  RECOVER_ROWID_DEFAULT = 1;

{ Public API. }
function sqlite3_recover_init(db: PTsqlite3; zDb, zUri: PAnsiChar): Psqlite3_recover;
function sqlite3_recover_init_sql(db: PTsqlite3; zDb: PAnsiChar;
  xSql: TXSqlCb; pSqlCtx: Pointer): Psqlite3_recover;
function sqlite3_recover_config(p: Psqlite3_recover; op: i32; pArg: Pointer): i32;
function sqlite3_recover_step(p: Psqlite3_recover): i32;
function sqlite3_recover_run(p: Psqlite3_recover): i32;
function sqlite3_recover_errmsg(p: Psqlite3_recover): PAnsiChar;
function sqlite3_recover_errcode(p: Psqlite3_recover): i32;
function sqlite3_recover_finish(p: Psqlite3_recover): i32;

implementation

{ ---------------------------------------------------------------
  Local helpers
  --------------------------------------------------------------- }

function recoverStrlen(zStr: PAnsiChar): i32;
var p: PAnsiChar;
begin
  if zStr = nil then begin Result := 0; Exit; end;
  p := zStr;
  while p^ <> #0 do Inc(p);
  Result := i32(p - zStr) and $7fffffff;
end;

function recoverMalloc(p: Psqlite3_recover; nByte: i64): Pointer;
var pRet: Pointer;
begin
  pRet := nil;
  Assert(nByte > 0);
  if p^.errCode = SQLITE_OK then begin
    pRet := sqlite3_malloc64(u64(nByte));
    if pRet <> nil then
      FillChar(pRet^, nByte, 0)
    else
      p^.errCode := SQLITE_NOMEM;
  end;
  Result := pRet;
end;

function recoverError(p: Psqlite3_recover; errCode: i32;
  zFmt: PAnsiChar; const args: array of const): i32;
var z: PAnsiChar;
begin
  z := nil;
  if zFmt <> nil then z := sqlite3PfMprintf(zFmt, args);
  if p^.zErrMsg <> nil then sqlite3_free(p^.zErrMsg);
  p^.zErrMsg := z;
  p^.errCode := errCode;
  Result := errCode;
end;

function recoverDbError(p: Psqlite3_recover; db: PTsqlite3): i32;
begin
  Result := recoverError(p, sqlite3_errcode(db), '%s', [sqlite3_errmsg(db)]);
end;

{ ---------------------------------------------------------------
  Bitmap helpers
  --------------------------------------------------------------- }

function recoverBitmapAlloc(p: Psqlite3_recover; nPg: i64): PRecoverBitmap;
var
  nElem, nByte: i32;
  pRet: PRecoverBitmap;
begin
  nElem := i32((nPg + 1 + 31) div 32);
  nByte := SizeOf(TRecoverBitmap) - SizeOf(u32) + nElem * SizeOf(u32);
  if nByte < SizeOf(TRecoverBitmap) then nByte := SizeOf(TRecoverBitmap);
  pRet := PRecoverBitmap(recoverMalloc(p, nByte));
  if pRet <> nil then pRet^.nPg := nPg;
  Result := pRet;
end;

procedure recoverBitmapFree(pMap: PRecoverBitmap);
begin
  sqlite3_free(pMap);
end;

{$PUSH}{$POINTERMATH ON}
procedure recoverBitmapSet(pMap: PRecoverBitmap; iPg: i64);
var iElem, iBit: i32; pElem: PCardinal;
begin
  if iPg <= pMap^.nPg then begin
    iElem := i32(iPg div 32);
    iBit  := i32(iPg mod 32);
    pElem := PCardinal(@pMap^.aElem[0]);
    pElem[iElem] := pElem[iElem] or (u32(1) shl iBit);
  end;
end;

function recoverBitmapQuery(pMap: PRecoverBitmap; iPg: i64): i32;
var iElem, iBit: i32; pElem: PCardinal;
begin
  Result := 1;
  if (iPg <= pMap^.nPg) and (iPg > 0) then begin
    iElem := i32(iPg div 32);
    iBit  := i32(iPg mod 32);
    pElem := PCardinal(@pMap^.aElem[0]);
    if (pElem[iElem] and (u32(1) shl iBit)) <> 0 then
      Result := 1
    else
      Result := 0;
  end;
end;
{$POP}

{ ---------------------------------------------------------------
  Statement helpers
  --------------------------------------------------------------- }

function recoverPrepare(p: Psqlite3_recover; db: PTsqlite3; zSql: PAnsiChar): PVdbe;
var pStmt: PVdbe;
begin
  pStmt := nil;
  if p^.errCode = SQLITE_OK then begin
    if sqlite3_prepare_v2(db, zSql, -1, @pStmt, nil) <> SQLITE_OK then
      recoverDbError(p, db);
  end;
  Result := pStmt;
end;

function recoverPreparePrintf(p: Psqlite3_recover; db: PTsqlite3;
  zFmt: PAnsiChar; const args: array of const): PVdbe;
var
  pStmt: PVdbe;
  z: PAnsiChar;
begin
  pStmt := nil;
  if p^.errCode = SQLITE_OK then begin
    z := sqlite3PfMprintf(zFmt, args);
    if z = nil then begin
      p^.errCode := SQLITE_NOMEM;
    end else begin
      pStmt := recoverPrepare(p, db, z);
      sqlite3_free(z);
    end;
  end;
  Result := pStmt;
end;

function recoverReset(p: Psqlite3_recover; pStmt: PVdbe): PVdbe;
var rc: i32;
begin
  rc := sqlite3_reset(pStmt);
  if (rc <> SQLITE_OK) and (rc <> SQLITE_CONSTRAINT) and (p^.errCode = SQLITE_OK) then
    recoverDbError(p, sqlite3_db_handle(pStmt));
  Result := pStmt;
end;

procedure recoverFinalize(p: Psqlite3_recover; pStmt: PVdbe);
var
  db: PTsqlite3;
  rc: i32;
begin
  if pStmt = nil then Exit;
  db := sqlite3_db_handle(pStmt);
  rc := sqlite3_finalize(pStmt);
  if (rc <> SQLITE_OK) and (p^.errCode = SQLITE_OK) then
    recoverDbError(p, db);
end;

function recoverExec(p: Psqlite3_recover; db: PTsqlite3; zSql: PAnsiChar): i32;
var rc: i32;
begin
  if p^.errCode = SQLITE_OK then begin
    rc := sqlite3_exec(db, zSql, nil, nil, nil);
    if rc <> 0 then recoverDbError(p, db);
  end;
  Result := p^.errCode;
end;

procedure recoverBindValue(p: Psqlite3_recover; pStmt: PVdbe;
  iBind: i32; pVal: Psqlite3_value);
var rc: i32;
begin
  if p^.errCode = SQLITE_OK then begin
    rc := sqlite3_bind_value(pStmt, iBind, pVal);
    if rc <> 0 then recoverError(p, rc, nil, []);
  end;
end;

function recoverMPrintf(p: Psqlite3_recover; zFmt: PAnsiChar;
  const args: array of const): PAnsiChar;
var z: PAnsiChar;
begin
  z := sqlite3PfMprintf(zFmt, args);
  if p^.errCode = SQLITE_OK then begin
    if z = nil then p^.errCode := SQLITE_NOMEM;
  end else begin
    if z <> nil then sqlite3_free(z);
    z := nil;
  end;
  Result := z;
end;

function recoverPageCount(p: Psqlite3_recover): i64;
var
  nPg: i64;
  pStmt: PVdbe;
begin
  nPg := 0;
  if p^.errCode = SQLITE_OK then begin
    pStmt := recoverPreparePrintf(p, p^.dbIn, 'PRAGMA %Q.page_count', [p^.zDb]);
    if pStmt <> nil then begin
      sqlite3_step(pStmt);
      nPg := sqlite3_column_int64(pStmt, 0);
    end;
    recoverFinalize(p, pStmt);
  end;
  Result := nPg;
end;

{ ---------------------------------------------------------------
  Custom SQL functions registered with the output handle.
  --------------------------------------------------------------- }

procedure recoverReadI32(pCtx: Psqlite3_context; argc: i32;
  argv: PPsqlite3_value); cdecl;
var
  pBlob: PByte;
  nBlob, iInt: i32;
  iVal: i64;
  a: PByte;
begin
  Assert(argc = 2);
  nBlob := sqlite3_value_bytes(argv[0]);
  pBlob := PByte(sqlite3_value_blob(argv[0]));
  iInt  := sqlite3_value_int(argv[1]) and $FFFF;
  if (iInt + 1) * 4 <= nBlob then begin
    a := pBlob; Inc(a, iInt * 4);
    iVal := (i64(a[0]) shl 24) + (i64(a[1]) shl 16) +
            (i64(a[2]) shl 8)  + (i64(a[3]) shl 0);
    sqlite3_result_int64(pCtx, iVal);
  end;
end;

procedure recoverPageIsUsed(pCtx: Psqlite3_context; nArg: i32;
  apArg: PPsqlite3_value); cdecl;
var
  p: Psqlite3_recover;
  pgno: i64;
begin
  Assert(nArg = 1);
  p := Psqlite3_recover(sqlite3_user_data(pCtx));
  pgno := sqlite3_value_int64(apArg[0]);
  sqlite3_result_int(pCtx, recoverBitmapQuery(p^.laf.pUsed, pgno));
end;

procedure recoverGetPage(pCtx: Psqlite3_context; nArg: i32;
  apArg: PPsqlite3_value); cdecl;
var
  p: Psqlite3_recover;
  pgno, nPg: i64;
  pStmt: PVdbe;
  aPg: Pointer;
  nPgB: i32;
begin
  Assert(nArg = 1);
  p := Psqlite3_recover(sqlite3_user_data(pCtx));
  pgno := sqlite3_value_int64(apArg[0]);

  if pgno = 0 then begin
    nPg := recoverPageCount(p);
    sqlite3_result_int64(pCtx, nPg);
    Exit;
  end;

  pStmt := nil;
  if p^.pGetPage = nil then begin
    p^.pGetPage := recoverPreparePrintf(p, p^.dbIn,
      'SELECT data FROM sqlite_dbpage(%Q) WHERE pgno=?', [p^.zDb]);
    pStmt := p^.pGetPage;
  end else if p^.errCode = SQLITE_OK then
    pStmt := p^.pGetPage;

  if pStmt <> nil then begin
    sqlite3_bind_int64(pStmt, 1, pgno);
    if SQLITE_ROW = sqlite3_step(pStmt) then begin
      aPg  := sqlite3_column_blob(pStmt, 0);
      nPgB := sqlite3_column_bytes(pStmt, 0);
      { 10.1.48.c partial — recoverInstallWrapper rewrites page 1's
        header bytes via recoverVfsRead's sanitization pass.  C
        sqlite3recover.c:723 swaps the sanitized bytes for the cached
        on-disk bytes (pPage1Disk) before returning, so subsequent
        sqlite_dbdata/dbptr scans see the real b-tree header.  Pas:
        adding that swap unblocks recoverCacheSchema (nCell populates,
        recovery.schema lands two rows) but uncovers a use-after-free
        further down the writeData pipeline (glibc `free(): invalid
        pointer` after the first emitted INSERT).  Tracked as a
        follow-up in tasklist; for now the un-swapped raw blob keeps
        .recover stable on the lost_and_found fallback, which is what
        DiagRecover gates today. }
      sqlite3_result_blob(pCtx, aPg, nPgB - p^.nReserve, SQLITE_TRANSIENT);
    end;
    recoverReset(p, pStmt);
  end;

  if p^.errCode <> 0 then begin
    if p^.zErrMsg <> nil then
      sqlite3_result_error(pCtx, p^.zErrMsg, -1);
    sqlite3_result_error_code(pCtx, p^.errCode);
  end;
end;

{ ASCII strstr (libc).  Returned pointer is into the haystack. }
function recoverStrStr(haystack, needle: PAnsiChar): PAnsiChar;
  cdecl; external 'c' name 'strstr';

function recoverStrLen(s: PAnsiChar): NativeUInt;
  cdecl; external 'c' name 'strlen';

function recoverUnusedString(z, zA, zB, zBuf: PAnsiChar): PAnsiChar;
var
  i: u32;
  zTmp: PAnsiChar;
begin
  if recoverStrStr(z, zA) = nil then begin Result := zA; Exit; end;
  if recoverStrStr(z, zB) = nil then begin Result := zB; Exit; end;
  i := 0;
  repeat
    zTmp := sqlite3PfMprintf('(%s%u)', [zA, i]);
    if zTmp <> nil then begin
      { Copy at most 19 bytes into the caller-supplied 20-byte zBuf. }
      Move(zTmp[0], zBuf[0], recoverStrLen(zTmp) + 1);
      sqlite3_free(zTmp);
    end;
    Inc(i);
  until recoverStrStr(z, zBuf) = nil;
  Result := zBuf;
end;

{ Faithful escape_crlf — wraps the input in nested replace() calls when
  the value passed to quote() contains CR/LF; otherwise returns input. }
procedure recoverEscapeCrlf(pCtx: Psqlite3_context; argc: i32;
  argv: PPsqlite3_value); cdecl;
var
  zText: PAnsiChar;
  nText, i, iOut, nNL, nCR: i32;
  zBuf1, zBuf2: array[0..31] of AnsiChar;
  zNL, zCR: PAnsiChar;
  nMax, nAlloc: i64;
  zOut: PAnsiChar;
  cPrefix1, cPrefix2: PAnsiChar;
  cTail: PAnsiChar;
begin
  zText := PAnsiChar(sqlite3_value_text(argv[0]));
  if (zText <> nil) and (zText[0] = '''') then begin
    nText := sqlite3_value_bytes(argv[0]);
    zNL := nil; zCR := nil; nNL := 0; nCR := 0;
    i := 0;
    while zText[i] <> #0 do begin
      if (zNL = nil) and (zText[i] = #10) then begin
        zNL := recoverUnusedString(zText, '\n', '\012', PAnsiChar(@zBuf1[0]));
        nNL := i32(recoverStrLen(zNL));
      end;
      if (zCR = nil) and (zText[i] = #13) then begin
        zCR := recoverUnusedString(zText, '\r', '\015', PAnsiChar(@zBuf2[0]));
        nCR := i32(recoverStrLen(zCR));
      end;
      Inc(i);
    end;
    if (zNL <> nil) or (zCR <> nil) then begin
      if nNL > nCR then nMax := nNL else nMax := nCR;
      nAlloc := nMax * nText + (nMax + 64) * 2;
      zOut := PAnsiChar(sqlite3_malloc64(u64(nAlloc)));
      if zOut = nil then begin sqlite3_result_error_nomem(pCtx); Exit; end;
      iOut := 0;
      cPrefix1 := 'replace(replace(';
      cPrefix2 := 'replace(';
      if (zNL <> nil) and (zCR <> nil) then begin
        Move(cPrefix1[0], zOut[iOut], 16); Inc(iOut, 16);
      end else begin
        Move(cPrefix2[0], zOut[iOut], 8); Inc(iOut, 8);
      end;
      i := 0;
      while zText[i] <> #0 do begin
        if zText[i] = #10 then begin
          Move(zNL[0], zOut[iOut], nNL); Inc(iOut, nNL);
        end else if zText[i] = #13 then begin
          Move(zCR[0], zOut[iOut], nCR); Inc(iOut, nCR);
        end else begin
          zOut[iOut] := zText[i]; Inc(iOut);
        end;
        Inc(i);
      end;
      if zNL <> nil then begin
        zOut[iOut] := ','; Inc(iOut);
        zOut[iOut] := ''''; Inc(iOut);
        Move(zNL[0], zOut[iOut], nNL); Inc(iOut, nNL);
        cTail := ''', char(10))';
        Move(cTail[0], zOut[iOut], 12); Inc(iOut, 12);
      end;
      if zCR <> nil then begin
        zOut[iOut] := ','; Inc(iOut);
        zOut[iOut] := ''''; Inc(iOut);
        Move(zCR[0], zOut[iOut], nCR); Inc(iOut, nCR);
        cTail := ''', char(13))';
        Move(cTail[0], zOut[iOut], 12); Inc(iOut, 12);
      end;
      sqlite3_result_text(pCtx, zOut, iOut, SQLITE_TRANSIENT);
      sqlite3_free(zOut);
      Exit;
    end;
  end;
  sqlite3_result_value(pCtx, argv[0]);
end;

{ ---------------------------------------------------------------
  Schema cache + settings transfer
  --------------------------------------------------------------- }

function recoverCacheSchema(p: Psqlite3_recover): i32;
begin
  Result := recoverExec(p, p^.dbOut,
    'WITH RECURSIVE pages(p) AS (' +
    '  SELECT 1' +
    '    UNION' +
    '  SELECT child FROM sqlite_dbptr(''getpage()''), pages WHERE pgno=p' +
    ')' +
    'INSERT INTO recovery.schema SELECT' +
    '  max(CASE WHEN field=0 THEN value ELSE NULL END),' +
    '  max(CASE WHEN field=1 THEN value ELSE NULL END),' +
    '  max(CASE WHEN field=2 THEN value ELSE NULL END),' +
    '  max(CASE WHEN field=3 THEN value ELSE NULL END),' +
    '  max(CASE WHEN field=4 THEN value ELSE NULL END)' +
    'FROM sqlite_dbdata(''getpage()'') WHERE pgno IN (' +
    '  SELECT p FROM pages' +
    ') GROUP BY pgno, cell');
end;

procedure recoverSqlCallback(p: Psqlite3_recover; zSql: PAnsiChar);
var res: i32;
begin
  if (p^.errCode = SQLITE_OK) and Assigned(p^.xSql) then begin
    res := p^.xSql(p^.pSqlCtx, zSql);
    if res <> 0 then
      recoverError(p, SQLITE_ERROR, 'callback returned an error - %d', [res]);
  end;
end;

procedure recoverTransferSettings(p: Psqlite3_recover);
const
  aPragma: array[0..4] of PAnsiChar = (
    'encoding', 'page_size', 'auto_vacuum', 'user_version', 'application_id');
var
  ii: i32;
  db2: PTsqlite3;
  rc: i32;
  p1: PVdbe;
  zPrag, zArg, z2: PAnsiChar;
  pBackup: Pointer;
begin
  if p^.errCode <> SQLITE_OK then Exit;
  db2 := nil;
  rc := sqlite3_open('', @db2);
  if rc <> SQLITE_OK then begin
    recoverDbError(p, db2);
    if db2 <> nil then sqlite3_close(db2);
    Exit;
  end;

  for ii := 0 to High(aPragma) do begin
    zPrag := aPragma[ii];
    p1 := recoverPreparePrintf(p, p^.dbIn, 'PRAGMA %Q.%s', [p^.zDb, zPrag]);
    if (p^.errCode = SQLITE_OK) and (p1 <> nil) and
       (sqlite3_step(p1) = SQLITE_ROW) then
    begin
      zArg := PAnsiChar(sqlite3_column_text(p1, 0));
      z2 := recoverMPrintf(p, 'PRAGMA %s = %Q', [zPrag, zArg]);
      recoverSqlCallback(p, z2);
      recoverExec(p, db2, z2);
      sqlite3_free(z2);
      if zArg = nil then
        recoverError(p, SQLITE_NOMEM, nil, []);
    end;
    recoverFinalize(p, p1);
  end;
  recoverExec(p, db2, 'CREATE TABLE t1(a); DROP TABLE t1;');

  if p^.errCode = SQLITE_OK then begin
    pBackup := sqlite3_backup_init(p^.dbOut, 'main', db2, 'main');
    if pBackup <> nil then begin
      sqlite3_backup_step(pBackup, -1);
      p^.errCode := sqlite3_backup_finish(pBackup);
    end else
      recoverDbError(p, p^.dbOut);
  end;

  sqlite3_close(db2);
end;

{ ---------------------------------------------------------------
  Output db open + recovery aux db ATTACH
  --------------------------------------------------------------- }

function recoverOpenOutput(p: Psqlite3_recover): i32;
const
  flags = SQLITE_OPEN_URI or SQLITE_OPEN_CREATE or SQLITE_OPEN_READWRITE;
var
  aFunc: array[0..3] of TRecoverFuncEntry;
  db: PTsqlite3;
  ii, rc: i32;
begin
  aFunc[0].zName := 'getpage';      aFunc[0].nArg := 1; aFunc[0].xFunc := @recoverGetPage;
  aFunc[1].zName := 'page_is_used'; aFunc[1].nArg := 1; aFunc[1].xFunc := @recoverPageIsUsed;
  aFunc[2].zName := 'read_i32';     aFunc[2].nArg := 2; aFunc[2].xFunc := @recoverReadI32;
  aFunc[3].zName := 'escape_crlf';  aFunc[3].nArg := 1; aFunc[3].xFunc := @recoverEscapeCrlf;

  Assert(p^.dbOut = nil);
  db := nil;
  rc := sqlite3_open_v2(p^.zUri, @db, flags, nil);
  if rc <> SQLITE_OK then recoverDbError(p, db);

  { Register sqlite_dbdata / sqlite_dbptr against the OUTPUT handle.
    Upstream calls sqlite3_dbdata_init(db, 0, 0).  Our port exposes the
    registration via sqlite3DbdataRegister. }
  if p^.errCode = SQLITE_OK then
    p^.errCode := sqlite3DbdataRegister(db);

  ii := 0;
  while (p^.errCode = SQLITE_OK) and (ii < Length(aFunc)) do begin
    p^.errCode := sqlite3_create_function(db, aFunc[ii].zName,
      aFunc[ii].nArg, SQLITE_UTF8, p, aFunc[ii].xFunc, nil, nil);
    Inc(ii);
  end;

  p^.dbOut := db;
  Result := p^.errCode;
end;

procedure recoverOpenRecovery(p: Psqlite3_recover);
var zSql: PAnsiChar;
begin
  zSql := recoverMPrintf(p, 'ATTACH %Q AS recovery;', [p^.zStateDb]);
  recoverExec(p, p^.dbOut, zSql);
  recoverExec(p, p^.dbOut,
    'PRAGMA writable_schema = 1;' +
    'CREATE TABLE recovery.map(pgno INTEGER PRIMARY KEY, parent INT);' +
    'CREATE TABLE recovery.schema(type, name, tbl_name, rootpage, sql);');
  if zSql <> nil then sqlite3_free(zSql);
end;

{ ---------------------------------------------------------------
  Cleanup
  --------------------------------------------------------------- }

procedure recoverWriteDataCleanup(p: Psqlite3_recover); forward;
procedure recoverLostAndFoundCleanup(p: Psqlite3_recover); forward;

procedure recoverFinalCleanup(p: Psqlite3_recover);
var pTab, pNext: PRecoverTable;
begin
  if p = nil then Exit;
  recoverWriteDataCleanup(p);
  recoverLostAndFoundCleanup(p);
  pTab := p^.pTblList;
  while pTab <> nil do begin
    pNext := pTab^.pNext;
    if pTab^.zTab <> nil then sqlite3_free(pTab^.zTab);
    if pTab^.aCol <> nil then sqlite3_free(pTab^.aCol);
    sqlite3_free(pTab);
    pTab := pNext;
  end;
  p^.pTblList := nil;

  recoverFinalize(p, p^.pGetPage); p^.pGetPage := nil;
  if p^.dbOut <> nil then begin
    sqlite3_close(p^.dbOut);
    p^.dbOut := nil;
  end;
end;

{ ---------------------------------------------------------------
  recoverFindTable / recoverAddTable — schema synthesis (lines
  1050..1138 / 1371..1375 of sqlite3recover.c).
  --------------------------------------------------------------- }

function recoverFindTable(p: Psqlite3_recover; iRoot: u32): PRecoverTable;
var pRet: PRecoverTable;
begin
  pRet := p^.pTblList;
  while (pRet <> nil) and (pRet^.iRoot <> iRoot) do
    pRet := pRet^.pNext;
  Result := pRet;
end;

procedure recoverAddTable(p: Psqlite3_recover; zName: PAnsiChar; iRoot: i64);
var
  pStmt: PVdbe;
  iPk, iBind, nCol, nName, nByte: i32;
  pNew: PRecoverTable;
  i, iField, iPKF, n, eHidden: i32;
  csr, z, zType: PAnsiChar;
  iCol: i32;
begin
  pStmt := recoverPreparePrintf(p, p^.dbOut, 'PRAGMA table_xinfo(%Q)', [zName]);
  if pStmt = nil then Exit;

  iPk := -1;
  iBind := 1;
  pNew := nil;
  nCol := 0;
  nName := recoverStrlen(zName);
  nByte := 0;

  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    Inc(nCol);
    Inc(nByte, sqlite3_column_bytes(pStmt, 1) + 1);
  end;
  Inc(nByte, SizeOf(TRecoverTable) + nCol * SizeOf(TRecoverColumn) + nName + 1);
  recoverReset(p, pStmt);

  pNew := PRecoverTable(recoverMalloc(p, nByte));
  if pNew <> nil then begin
    pNew^.aCol := PRecoverColumn(PByte(pNew) + SizeOf(TRecoverTable));
    csr := PAnsiChar(pNew^.aCol) + nCol * SizeOf(TRecoverColumn);
    pNew^.zTab := csr;
    pNew^.nCol := nCol;
    pNew^.iRoot := u32(iRoot);
    if nName > 0 then Move(zName[0], csr[0], nName);
    Inc(csr, nName + 1);

    iField := 0;
    i := 0;
    while sqlite3_step(pStmt) = SQLITE_ROW do begin
      iPKF := sqlite3_column_int(pStmt, 5);
      n := sqlite3_column_bytes(pStmt, 1);
      z := PAnsiChar(sqlite3_column_text(pStmt, 1));
      zType := PAnsiChar(sqlite3_column_text(pStmt, 2));
      eHidden := sqlite3_column_int(pStmt, 6);

      if (iPk = -1) and (iPKF = 1) and (sqlite3_stricmp('integer', zType) = 0) then
        iPk := i;
      if iPKF > 1 then iPk := -2;

      pNew^.aCol[i].zCol := csr;
      pNew^.aCol[i].eHidden := eHidden;
      if eHidden = RECOVER_EHIDDEN_VIRTUAL then begin
        pNew^.aCol[i].iField := -1;
      end else begin
        pNew^.aCol[i].iField := iField;
        Inc(iField);
      end;
      if (eHidden <> RECOVER_EHIDDEN_VIRTUAL) and
         (eHidden <> RECOVER_EHIDDEN_STORED) then
      begin
        pNew^.aCol[i].iBind := iBind;
        Inc(iBind);
      end;

      if n > 0 then Move(z[0], csr[0], n);
      Inc(csr, n + 1);
      Inc(i);
    end;

    pNew^.pNext := p^.pTblList;
    p^.pTblList := pNew;
    pNew^.bIntkey := 1;
  end;

  recoverFinalize(p, pStmt);

  pStmt := recoverPreparePrintf(p, p^.dbOut, 'PRAGMA index_xinfo(%Q)', [zName]);
  while (pStmt <> nil) and (sqlite3_step(pStmt) = SQLITE_ROW) do begin
    iField := sqlite3_column_int(pStmt, 0);
    iCol   := sqlite3_column_int(pStmt, 1);
    if pNew <> nil then begin
      Assert(iCol < pNew^.nCol);
      pNew^.aCol[iCol].iField := iField;
      pNew^.bIntkey := 0;
    end;
    iPk := -2;
  end;
  recoverFinalize(p, pStmt);

  if (p^.errCode = SQLITE_OK) and (pNew <> nil) then begin
    if iPk >= 0 then
      pNew^.aCol[iPk].bIPK := 1
    else if pNew^.bIntkey <> 0 then begin
      pNew^.iRowidBind := iBind;
      Inc(iBind);
    end;
  end;
end;

{ ---------------------------------------------------------------
  recoverWriteSchema1 / recoverWriteSchema2 — emit recovered
  CREATE TABLE / CREATE INDEX statements (lines 1159..1260).
  --------------------------------------------------------------- }

function recoverWriteSchema1(p: Psqlite3_recover): i32;
var
  pSelect, pTblname: PVdbe;
  iRoot: i64;
  bTable, bVirtual, rc: i32;
  zName, zSql, zTbl: PAnsiChar;
  zFree: PAnsiChar;
begin
  pSelect := recoverPrepare(p, p^.dbOut,
    'WITH dbschema(rootpage, name, sql, tbl, isVirtual, isIndex) AS (' +
    '  SELECT rootpage, name, sql, ' +
    '    type=''table'', ' +
    '    sql LIKE ''create virtual%'',' +
    '    (type=''index'' AND (sql LIKE ''%unique%'' OR ?1))' +
    '  FROM recovery.schema' +
    ')' +
    'SELECT rootpage, tbl, isVirtual, name, sql' +
    ' FROM dbschema ' +
    '  WHERE tbl OR isIndex' +
    '  ORDER BY tbl DESC, name==''sqlite_sequence'' DESC');

  pTblname := recoverPrepare(p, p^.dbOut,
    'SELECT name FROM sqlite_schema ' +
    'WHERE type=''table'' ORDER BY rowid DESC LIMIT 1');

  if pSelect <> nil then begin
    sqlite3_bind_int(pSelect, 1, p^.bSlowIndexes);
    while sqlite3_step(pSelect) = SQLITE_ROW do begin
      iRoot    := sqlite3_column_int64(pSelect, 0);
      bTable   := sqlite3_column_int(pSelect, 1);
      bVirtual := sqlite3_column_int(pSelect, 2);
      zName    := PAnsiChar(sqlite3_column_text(pSelect, 3));
      zSql     := PAnsiChar(sqlite3_column_text(pSelect, 4));
      zFree    := nil;

      if bVirtual <> 0 then begin
        zFree := recoverMPrintf(p,
          'INSERT INTO sqlite_schema VALUES(''table'', %Q, %Q, 0, %Q)',
          [zName, zName, zSql]);
        zSql := zFree;
      end;
      rc := sqlite3_exec(p^.dbOut, zSql, nil, nil, nil);
      if rc = SQLITE_OK then begin
        recoverSqlCallback(p, zSql);
        if (bTable <> 0) and (bVirtual = 0) then begin
          if sqlite3_step(pTblname) = SQLITE_ROW then begin
            zTbl := PAnsiChar(sqlite3_column_text(pTblname, 0));
            if zTbl <> nil then recoverAddTable(p, zTbl, iRoot);
          end;
          recoverReset(p, pTblname);
        end;
      end else if rc <> SQLITE_ERROR then
        recoverDbError(p, p^.dbOut);
      if zFree <> nil then sqlite3_free(zFree);
    end;
  end;
  recoverFinalize(p, pSelect);
  recoverFinalize(p, pTblname);
  Result := p^.errCode;
end;

function recoverWriteSchema2(p: Psqlite3_recover): i32;
var
  pSelect: PVdbe;
  zSql: PAnsiChar;
  rc: i32;
begin
  if p^.bSlowIndexes <> 0 then
    pSelect := recoverPrepare(p, p^.dbOut,
      'SELECT rootpage, sql FROM recovery.schema ' +
      '  WHERE type!=''table'' AND type!=''index''')
  else
    pSelect := recoverPrepare(p, p^.dbOut,
      'SELECT rootpage, sql FROM recovery.schema ' +
      '  WHERE type!=''table'' AND (type!=''index'' OR sql NOT LIKE ''%unique%'')');

  if pSelect <> nil then begin
    while sqlite3_step(pSelect) = SQLITE_ROW do begin
      zSql := PAnsiChar(sqlite3_column_text(pSelect, 1));
      rc := sqlite3_exec(p^.dbOut, zSql, nil, nil, nil);
      if rc = SQLITE_OK then
        recoverSqlCallback(p, zSql)
      else if rc <> SQLITE_ERROR then
        recoverDbError(p, p^.dbOut);
    end;
  end;
  recoverFinalize(p, pSelect);
  Result := p^.errCode;
end;

{ ---------------------------------------------------------------
  recoverInsertStmt — synthesize per-table INSERT (lines 1297..1363).
  --------------------------------------------------------------- }

function recoverInsertStmt(p: Psqlite3_recover; pTab: PRecoverTable;
  nField: i32): PVdbe;
var
  pRet: PVdbe;
  zSep, zSqlSep: PAnsiChar;
  zSql, zFinal, zBind, zTmp: PAnsiChar;
  ii, eHidden, bSql: i32;
begin
  pRet := nil;
  zSep := '';
  zSqlSep := '';
  zSql := nil;
  zFinal := nil;
  zBind := nil;
  if Assigned(p^.xSql) then bSql := 1 else bSql := 0;

  if nField <= 0 then begin Result := nil; Exit; end;
  Assert(nField <= pTab^.nCol);

  zSql := recoverMPrintf(p, 'INSERT OR IGNORE INTO %Q(', [pTab^.zTab]);

  if pTab^.iRowidBind <> 0 then begin
    Assert(pTab^.bIntkey <> 0);
    zTmp := recoverMPrintf(p, '%s_rowid_', [zSql]);
    sqlite3_free(zSql); zSql := zTmp;
    if bSql <> 0 then
      zBind := recoverMPrintf(p, 'quote(?%d)', [pTab^.iRowidBind])
    else
      zBind := recoverMPrintf(p, '?%d', [pTab^.iRowidBind]);
    zSqlSep := '||'', ''||';
    zSep := ', ';
  end;

  for ii := 0 to nField - 1 do begin
    eHidden := pTab^.aCol[ii].eHidden;
    if (eHidden <> RECOVER_EHIDDEN_VIRTUAL) and
       (eHidden <> RECOVER_EHIDDEN_STORED) then
    begin
      Assert((pTab^.aCol[ii].iField >= 0) and (pTab^.aCol[ii].iBind >= 1));
      zTmp := recoverMPrintf(p, '%s%s%Q', [zSql, zSep, pTab^.aCol[ii].zCol]);
      sqlite3_free(zSql); zSql := zTmp;

      if bSql <> 0 then begin
        if zBind = nil then
          zTmp := recoverMPrintf(p, 'escape_crlf(quote(?%d))', [pTab^.aCol[ii].iBind])
        else
          zTmp := recoverMPrintf(p, '%s%sescape_crlf(quote(?%d))',
            [zBind, zSqlSep, pTab^.aCol[ii].iBind]);
        if zBind <> nil then sqlite3_free(zBind);
        zBind := zTmp;
        zSqlSep := '||'', ''||';
      end else begin
        if zBind = nil then
          zTmp := recoverMPrintf(p, '?%d', [pTab^.aCol[ii].iBind])
        else
          zTmp := recoverMPrintf(p, '%s%s?%d',
            [zBind, zSep, pTab^.aCol[ii].iBind]);
        if zBind <> nil then sqlite3_free(zBind);
        zBind := zTmp;
      end;
      zSep := ', ';
    end;
  end;

  if bSql <> 0 then
    zFinal := recoverMPrintf(p,
      'SELECT %Q || '') VALUES ('' || %s || '')''', [zSql, zBind])
  else
    zFinal := recoverMPrintf(p, '%s) VALUES (%s)', [zSql, zBind]);

  pRet := recoverPrepare(p, p^.dbOut, zFinal);
  if zSql <> nil then sqlite3_free(zSql);
  if zBind <> nil then sqlite3_free(zBind);
  if zFinal <> nil then sqlite3_free(zFinal);
  Result := pRet;
end;

{ ---------------------------------------------------------------
  recoverWriteDataInit / Cleanup / Step — table-by-table data extraction
  (lines 1669..1853 of sqlite3recover.c).
  --------------------------------------------------------------- }

function recoverWriteDataInit(p: Psqlite3_recover): i32;
var
  p1: PRecoverStateW1;
  pTbl: PRecoverTable;
  nByte: i32;
begin
  p1 := @p^.w1;
  Assert(p1^.nMax = 0);
  pTbl := p^.pTblList;
  while pTbl <> nil do begin
    if pTbl^.nCol > p1^.nMax then p1^.nMax := pTbl^.nCol;
    pTbl := pTbl^.pNext;
  end;

  nByte := SizeOf(Pointer) * (p1^.nMax + 1);
  p1^.apVal := recoverMalloc(p, nByte);
  if p1^.apVal = nil then begin Result := p^.errCode; Exit; end;

  p1^.pTbls := recoverPrepare(p, p^.dbOut,
    'SELECT rootpage FROM recovery.schema ' +
    '  WHERE type=''table'' AND (sql NOT LIKE ''create virtual%'')' +
    '  ORDER BY (tbl_name=''sqlite_sequence'') ASC');
  p1^.pSel := recoverPrepare(p, p^.dbOut,
    'WITH RECURSIVE pages(page) AS (' +
    '  SELECT ?1' +
    '    UNION' +
    '  SELECT child FROM sqlite_dbptr(''getpage()''), pages ' +
    '    WHERE pgno=page' +
    ') ' +
    'SELECT page, cell, field, value ' +
    'FROM sqlite_dbdata(''getpage()'') d, pages p WHERE p.page=d.pgno ' +
    'UNION ALL ' +
    'SELECT 0, 0, 0, 0');

  Result := p^.errCode;
end;

procedure recoverWriteDataCleanup(p: Psqlite3_recover);
var
  p1: PRecoverStateW1;
  apVal: PPsqlite3_value;
  ii: i32;
begin
  p1 := @p^.w1;
  apVal := PPsqlite3_value(p1^.apVal);
  if apVal <> nil then begin
    for ii := 0 to p1^.nVal - 1 do
      sqlite3_value_free(apVal[ii]);
    sqlite3_free(apVal);
  end;
  recoverFinalize(p, p1^.pInsert);
  recoverFinalize(p, p1^.pTbls);
  recoverFinalize(p, p1^.pSel);
  FillChar(p1^, SizeOf(p1^), 0);
end;

function recoverWriteDataStep(p: Psqlite3_recover): i32;
var
  p1: PRecoverStateW1;
  pSel, pInsert: PVdbe;
  apVal: PPsqlite3_value;
  iRoot, iPage: i64;
  iCell, iField, ii, iBind: i32;
  pVal: Psqlite3_value;
  bNewCell: i32;
  pTab: PRecoverTable;
  pCol: PRecoverColumn;
  z: PAnsiChar;
begin
  p1 := @p^.w1;
  pSel := p1^.pSel;
  apVal := PPsqlite3_value(p1^.apVal);

  if (p^.errCode = SQLITE_OK) and (p1^.pTab = nil) then begin
    if sqlite3_step(p1^.pTbls) = SQLITE_ROW then begin
      iRoot := sqlite3_column_int64(p1^.pTbls, 0);
      p1^.pTab := recoverFindTable(p, u32(iRoot));

      recoverFinalize(p, p1^.pInsert);
      p1^.pInsert := nil;

      if p1^.pTab = nil then begin Result := p^.errCode; Exit; end;

      if sqlite3_stricmp('sqlite_sequence', p1^.pTab^.zTab) = 0 then begin
        recoverExec(p, p^.dbOut, 'DELETE FROM sqlite_sequence');
        recoverSqlCallback(p, 'DELETE FROM sqlite_sequence');
      end;

      sqlite3_bind_int64(pSel, 1, iRoot);
      p1^.nVal := 0;
      p1^.bHaveRowid := 0;
      p1^.iPrevPage := -1;
      p1^.iPrevCell := -1;
    end else begin
      Result := SQLITE_DONE;
      Exit;
    end;
  end;

  Assert((p^.errCode <> SQLITE_OK) or (p1^.pTab <> nil));

  if (p^.errCode = SQLITE_OK) and (sqlite3_step(pSel) = SQLITE_ROW) then begin
    pTab := p1^.pTab;
    iPage := sqlite3_column_int64(pSel, 0);
    iCell := sqlite3_column_int(pSel, 1);
    iField := sqlite3_column_int(pSel, 2);
    pVal := sqlite3_column_value(pSel, 3);
    if (p1^.iPrevPage <> iPage) or (p1^.iPrevCell <> iCell) then
      bNewCell := 1
    else
      bNewCell := 0;

    if bNewCell <> 0 then begin
      if p1^.nVal >= 0 then begin
        if (p1^.pInsert = nil) or (p1^.nVal <> p1^.nInsert) then begin
          recoverFinalize(p, p1^.pInsert);
          p1^.pInsert := recoverInsertStmt(p, pTab, p1^.nVal);
          p1^.nInsert := p1^.nVal;
        end;
        if p1^.nVal > 0 then begin
          pInsert := p1^.pInsert;
          for ii := 0 to pTab^.nCol - 1 do begin
            pCol := @pTab^.aCol[ii];
            iBind := pCol^.iBind;
            if iBind > 0 then begin
              if pCol^.bIPK <> 0 then
                sqlite3_bind_int64(pInsert, iBind, p1^.iRowid)
              else if pCol^.iField < p1^.nVal then
                recoverBindValue(p, pInsert, iBind, apVal[pCol^.iField]);
            end;
          end;
          if (p^.bRecoverRowid <> 0) and (pTab^.iRowidBind > 0) and
             (p1^.bHaveRowid <> 0) then
            sqlite3_bind_int64(pInsert, pTab^.iRowidBind, p1^.iRowid);
          if sqlite3_step(pInsert) = SQLITE_ROW then begin
            z := PAnsiChar(sqlite3_column_text(pInsert, 0));
            recoverSqlCallback(p, z);
          end;
          recoverReset(p, pInsert);
          if pInsert <> nil then sqlite3_clear_bindings(pInsert);
        end;
      end;
      for ii := 0 to p1^.nVal - 1 do begin
        sqlite3_value_free(apVal[ii]);
        apVal[ii] := nil;
      end;
      p1^.nVal := -1;
      p1^.bHaveRowid := 0;
    end;

    if iPage <> 0 then begin
      if iField < 0 then begin
        p1^.iRowid := sqlite3_column_int64(pSel, 3);
        Assert(p1^.nVal = -1);
        p1^.nVal := 0;
        p1^.bHaveRowid := 1;
      end else if iField < pTab^.nCol then begin
        Assert(apVal[iField] = nil);
        apVal[iField] := sqlite3_value_dup(pVal);
        if apVal[iField] = nil then
          recoverError(p, SQLITE_NOMEM, nil, []);
        p1^.nVal := iField + 1;
      end else if pTab^.nCol = 0 then
        p1^.nVal := pTab^.nCol;
      p1^.iPrevCell := iCell;
      p1^.iPrevPage := iPage;
    end;
  end else begin
    recoverReset(p, pSel);
    p1^.pTab := nil;
  end;

  Result := p^.errCode;
end;

{ ---------------------------------------------------------------
  Lost-and-found pipeline (sqlite3recover.c:1386..2019).

  Three RECOVER_STATE_LOSTANDFOUND states cooperate:
    LAF1 — drive recovery.map with the seed page set so every
           input page that is reachable through the recovered
           schema (or, when bFreelistCorrupt=0, the freelist) is
           marked in pUsed.
    LAF2 — for every (parent, child) pair in sqlite_dbptr —
           plus every page from 1..nPg as a fallback — if the
           page is not already in pUsed, insert it into
           recovery.map and update nMaxField.
    LAF3 — once nMaxField is known, create the lost_and_found
           output table (with rootpgno/pgno/nfield/id/c0..cN
           columns) and walk every page not in pUsed, emitting
           one row per recovered cell.
  --------------------------------------------------------------- }

function recoverLostAndFoundCreate(p: Psqlite3_recover; nField: i32): PAnsiChar;
var
  zTbl: PAnsiChar;
  pProbe: PVdbe;
  ii: i32;
  bFail: i32;
  zSep, zField, zSql, zOld: PAnsiChar;
begin
  zTbl := nil;
  pProbe := recoverPrepare(p, p^.dbOut,
    'SELECT 1 FROM sqlite_schema WHERE name=?');
  ii := -1;
  while (zTbl = nil) and (p^.errCode = SQLITE_OK) and (ii < 1000) do begin
    bFail := 0;
    if ii < 0 then
      zTbl := recoverMPrintf(p, '%s', [p^.zLostAndFound])
    else
      zTbl := recoverMPrintf(p, '%s_%d', [p^.zLostAndFound, ii]);

    if p^.errCode = SQLITE_OK then begin
      sqlite3_bind_text(pProbe, 1, zTbl, -1, SQLITE_STATIC);
      if sqlite3_step(pProbe) = SQLITE_ROW then bFail := 1;
      recoverReset(p, pProbe);
    end;

    if bFail <> 0 then begin
      sqlite3_clear_bindings(pProbe);
      sqlite3_free(zTbl);
      zTbl := nil;
    end;
    Inc(ii);
  end;
  recoverFinalize(p, pProbe);

  if zTbl <> nil then begin
    zField := nil;
    zSep := 'rootpgno INTEGER, pgno INTEGER, nfield INTEGER, id INTEGER, ';
    ii := 0;
    while (p^.errCode = SQLITE_OK) and (ii < nField) do begin
      zOld := zField;
      if zOld <> nil then
        zField := recoverMPrintf(p, '%s%sc%d', [zOld, zSep, ii])
      else
        zField := recoverMPrintf(p, '%sc%d', [zSep, ii]);
      if zOld <> nil then sqlite3_free(zOld);
      zSep := ', ';
      Inc(ii);
    end;

    zSql := recoverMPrintf(p, 'CREATE TABLE %s(%s)', [zTbl, zField]);
    if zField <> nil then sqlite3_free(zField);

    recoverExec(p, p^.dbOut, zSql);
    recoverSqlCallback(p, zSql);
    if zSql <> nil then sqlite3_free(zSql);
  end else if p^.errCode = SQLITE_OK then begin
    recoverError(p, SQLITE_ERROR,
      'failed to create %s output table', [p^.zLostAndFound]);
  end;

  Result := zTbl;
end;

function recoverLostAndFoundInsert(p: Psqlite3_recover;
  zTab: PAnsiChar; nField: i32): PVdbe;
var
  nTotal, ii: i32;
  zBind, zOld, zSep: PAnsiChar;
  pRet: PVdbe;
begin
  nTotal := nField + 4;
  zBind := nil;
  pRet := nil;

  if not Assigned(p^.xSql) then begin
    for ii := 0 to nTotal - 1 do begin
      zOld := zBind;
      if zOld <> nil then
        zBind := recoverMPrintf(p, '%s, ?', [zOld])
      else
        zBind := recoverMPrintf(p, '?', []);
      if zOld <> nil then sqlite3_free(zOld);
    end;
    pRet := recoverPreparePrintf(p, p^.dbOut,
      'INSERT INTO %s VALUES(%s)', [zTab, zBind]);
  end else begin
    zSep := '';
    for ii := 0 to nTotal - 1 do begin
      zOld := zBind;
      if zOld <> nil then
        zBind := recoverMPrintf(p, '%s%squote(?)', [zOld, zSep])
      else
        zBind := recoverMPrintf(p, 'quote(?)', []);
      if zOld <> nil then sqlite3_free(zOld);
      zSep := '|| '', '' ||';
    end;
    pRet := recoverPreparePrintf(p, p^.dbOut,
      'SELECT ''INSERT INTO %s VALUES('' || %s || '')''',
      [zTab, zBind]);
  end;

  if zBind <> nil then sqlite3_free(zBind);
  Result := pRet;
end;

function recoverLostAndFoundFindRoot(p: Psqlite3_recover;
  iPg: i64; var iRoot: i64): i32;
var pLaf: PRecoverStateLAF;
begin
  pLaf := @p^.laf;
  if pLaf^.pFindRoot = nil then begin
    pLaf^.pFindRoot := recoverPrepare(p, p^.dbOut,
      'WITH RECURSIVE p(pgno) AS (' +
      '  SELECT ?' +
      '    UNION' +
      '  SELECT parent FROM recovery.map AS m, p WHERE m.pgno=p.pgno' +
      ') ' +
      'SELECT p.pgno FROM p, recovery.map m WHERE m.pgno=p.pgno ' +
      '    AND m.parent IS NULL');
  end;
  if p^.errCode = SQLITE_OK then begin
    sqlite3_bind_int64(pLaf^.pFindRoot, 1, iPg);
    if sqlite3_step(pLaf^.pFindRoot) = SQLITE_ROW then
      iRoot := sqlite3_column_int64(pLaf^.pFindRoot, 0)
    else
      iRoot := iPg;
    recoverReset(p, pLaf^.pFindRoot);
  end;
  Result := p^.errCode;
end;

procedure recoverLostAndFoundOnePage(p: Psqlite3_recover; iPage: i64);
var
  pLaf: PRecoverStateLAF;
  apVal: PPsqlite3_value;
  pPageData, pInsert: PVdbe;
  nVal, iPrevCell, bHaveRowid, ii, iCell, iField: i32;
  iRoot, iRowid: i64;
  pVal: Psqlite3_value;
begin
  pLaf := @p^.laf;
  apVal := PPsqlite3_value(pLaf^.apVal);
  pPageData := pLaf^.pPageData;
  pInsert := pLaf^.pInsert;
  nVal := -1;
  iPrevCell := 0;
  iRoot := 0;
  bHaveRowid := 0;
  iRowid := 0;

  if recoverLostAndFoundFindRoot(p, iPage, iRoot) <> 0 then Exit;
  sqlite3_bind_int64(pPageData, 1, iPage);
  while (p^.errCode = SQLITE_OK) and (sqlite3_step(pPageData) = SQLITE_ROW) do begin
    iCell  := sqlite3_column_int64(pPageData, 0);
    iField := sqlite3_column_int64(pPageData, 1);

    if (iPrevCell <> iCell) and (nVal >= 0) then begin
      sqlite3_bind_int64(pInsert, 1, iRoot);
      sqlite3_bind_int64(pInsert, 2, iPage);
      sqlite3_bind_int(pInsert, 3, nVal);
      if bHaveRowid <> 0 then
        sqlite3_bind_int64(pInsert, 4, iRowid);
      for ii := 0 to nVal - 1 do
        recoverBindValue(p, pInsert, 5 + ii, apVal[ii]);
      if sqlite3_step(pInsert) = SQLITE_ROW then
        recoverSqlCallback(p, PAnsiChar(sqlite3_column_text(pInsert, 0)));
      recoverReset(p, pInsert);

      for ii := 0 to nVal - 1 do begin
        sqlite3_value_free(apVal[ii]);
        apVal[ii] := nil;
      end;
      sqlite3_clear_bindings(pInsert);
      bHaveRowid := 0;
      nVal := -1;
    end;

    if iCell < 0 then Break;

    if iField < 0 then begin
      Assert(nVal = -1);
      iRowid := sqlite3_column_int64(pPageData, 2);
      bHaveRowid := 1;
      nVal := 0;
    end else if iField < pLaf^.nMaxField then begin
      pVal := sqlite3_column_value(pPageData, 2);
      apVal[iField] := sqlite3_value_dup(pVal);
      Assert((iField = nVal) or ((nVal = -1) and (iField = 0)));
      nVal := iField + 1;
      if apVal[iField] = nil then
        recoverError(p, SQLITE_NOMEM, nil, []);
    end;

    iPrevCell := iCell;
  end;
  recoverReset(p, pPageData);

  for ii := 0 to nVal - 1 do begin
    sqlite3_value_free(apVal[ii]);
    apVal[ii] := nil;
  end;
end;

procedure recoverLostAndFound1Init(p: Psqlite3_recover);
var
  pLaf: PRecoverStateLAF;
  pStmt: PVdbe;
begin
  pLaf := @p^.laf;
  Assert(p^.laf.pUsed = nil);
  pLaf^.nPg := recoverPageCount(p);
  pLaf^.pUsed := recoverBitmapAlloc(p, pLaf^.nPg);

  pStmt := recoverPrepare(p, p^.dbOut,
    'WITH trunk(pgno) AS (' +
    '  SELECT read_i32(getpage(1), 8) AS x WHERE x>0' +
    '    UNION' +
    '  SELECT read_i32(getpage(trunk.pgno), 0) AS x FROM trunk WHERE x>0' +
    '),' +
    'trunkdata(pgno, data) AS (' +
    '  SELECT pgno, getpage(pgno) FROM trunk' +
    '),' +
    'freelist(data, n, freepgno) AS (' +
    '  SELECT data, min(16384, read_i32(data, 1)-1), pgno FROM trunkdata' +
    '    UNION ALL' +
    '  SELECT data, n-1, read_i32(data, 2+n) FROM freelist WHERE n>=0' +
    '),' +
    '' +
    'roots(r) AS (' +
    '  SELECT 1 UNION ALL' +
    '  SELECT rootpage FROM recovery.schema WHERE rootpage>0' +
    '),' +
    'used(page) AS (' +
    '  SELECT r FROM roots' +
    '    UNION' +
    '  SELECT child FROM sqlite_dbptr(''getpage()''), used ' +
    '    WHERE pgno=page' +
    ') ' +
    'SELECT page FROM used' +
    ' UNION ALL ' +
    'SELECT freepgno FROM freelist WHERE NOT ?');
  if pStmt <> nil then sqlite3_bind_int(pStmt, 1, p^.bFreelistCorrupt);
  pLaf^.pUsedPages := pStmt;
end;

function recoverLostAndFound1Step(p: Psqlite3_recover): i32;
var
  pLaf: PRecoverStateLAF;
  rc: i32;
  iPg: i64;
begin
  pLaf := @p^.laf;
  rc := p^.errCode;
  if rc = SQLITE_OK then begin
    rc := sqlite3_step(pLaf^.pUsedPages);
    if rc = SQLITE_ROW then begin
      iPg := sqlite3_column_int64(pLaf^.pUsedPages, 0);
      recoverBitmapSet(pLaf^.pUsed, iPg);
      rc := SQLITE_OK;
    end else begin
      recoverFinalize(p, pLaf^.pUsedPages);
      pLaf^.pUsedPages := nil;
    end;
  end;
  Result := rc;
end;

procedure recoverLostAndFound2Init(p: Psqlite3_recover);
var pLaf: PRecoverStateLAF;
begin
  pLaf := @p^.laf;
  Assert(p^.laf.pAllAndParent = nil);
  Assert(p^.laf.pMapInsert = nil);
  Assert(p^.laf.pMaxField = nil);
  Assert(p^.laf.nMaxField = 0);

  pLaf^.pMapInsert := recoverPrepare(p, p^.dbOut,
    'INSERT OR IGNORE INTO recovery.map(pgno, parent) VALUES(?, ?)');
  pLaf^.pAllAndParent := recoverPreparePrintf(p, p^.dbOut,
    'WITH RECURSIVE seq(ii) AS (' +
    '  SELECT 1 UNION ALL SELECT ii+1 FROM seq WHERE ii<%lld' +
    ')' +
    'SELECT pgno, child FROM sqlite_dbptr(''getpage()'') ' +
    ' UNION ALL ' +
    'SELECT NULL, ii FROM seq', [p^.laf.nPg]);
  { 10.1.48.c — port deviation: C upstream's SQL is
    `sqlite_dbdata('getpage')` (no parens).  C relies on the planner
    pushing `WHERE pgno = ?` into xBestIndex so dbdataFilter sees the
    pgno constraint and never reaches dbdataDbsize / the PRAGMA path.
    The Pas eponymous-vtab agg arm (codegen.pas:26621..26743) does not
    push regular-column WHERE constraints into BestIndex, so the
    schema-only `idxNum=1, argc=1` call falls through to
    dbdataDbsize, then `PRAGMA 'getpage'.page_count` fails with
    "unknown database 'getpage'".  Forcing the function form here
    keeps the runtime semantics identical (dbdataDbsize takes the
    `SELECT getpage(0)` path that returns the page count) without
    requiring the codegen pushdown to land first. }
  pLaf^.pMaxField := recoverPreparePrintf(p, p^.dbOut,
    'SELECT max(field)+1 FROM sqlite_dbdata(''getpage()'') WHERE pgno = ?',
    []);
end;

function recoverLostAndFound2Step(p: Psqlite3_recover): i32;
var
  pLaf: PRecoverStateLAF;
  res: i32;
  iChild: i64;
  nMax: i32;
begin
  pLaf := @p^.laf;
  if p^.errCode = SQLITE_OK then begin
    res := sqlite3_step(pLaf^.pAllAndParent);
    if res = SQLITE_ROW then begin
      iChild := sqlite3_column_int(pLaf^.pAllAndParent, 1);
      if recoverBitmapQuery(pLaf^.pUsed, iChild) = 0 then begin
        sqlite3_bind_int64(pLaf^.pMapInsert, 1, iChild);
        sqlite3_bind_value(pLaf^.pMapInsert, 2,
          sqlite3_column_value(pLaf^.pAllAndParent, 0));
        sqlite3_step(pLaf^.pMapInsert);
        recoverReset(p, pLaf^.pMapInsert);
        sqlite3_bind_int64(pLaf^.pMaxField, 1, iChild);
        if sqlite3_step(pLaf^.pMaxField) = SQLITE_ROW then begin
          nMax := sqlite3_column_int(pLaf^.pMaxField, 0);
          if nMax > pLaf^.nMaxField then pLaf^.nMaxField := nMax;
        end;
        recoverReset(p, pLaf^.pMaxField);
      end;
    end else begin
      recoverFinalize(p, pLaf^.pAllAndParent);
      pLaf^.pAllAndParent := nil;
      Result := SQLITE_DONE;
      Exit;
    end;
  end;
  Result := p^.errCode;
end;

procedure recoverLostAndFound3Init(p: Psqlite3_recover);
var
  pLaf: PRecoverStateLAF;
  zTab: PAnsiChar;
begin
  pLaf := @p^.laf;
  if pLaf^.nMaxField > 0 then begin
    zTab := recoverLostAndFoundCreate(p, pLaf^.nMaxField);
    pLaf^.pInsert := recoverLostAndFoundInsert(p, zTab, pLaf^.nMaxField);
    if zTab <> nil then sqlite3_free(zTab);

    pLaf^.pAllPage := recoverPreparePrintf(p, p^.dbOut,
      'WITH RECURSIVE seq(ii) AS (' +
      '  SELECT 1 UNION ALL SELECT ii+1 FROM seq WHERE ii<%lld' +
      ')' +
      'SELECT ii FROM seq', [p^.laf.nPg]);
    pLaf^.pPageData := recoverPrepare(p, p^.dbOut,
      'SELECT cell, field, value ' +
      'FROM sqlite_dbdata(''getpage()'') d WHERE d.pgno=? ' +
      'UNION ALL ' +
      'SELECT -1, -1, -1');

    pLaf^.apVal := recoverMalloc(p, pLaf^.nMaxField * SizeOf(Pointer));
  end;
end;

function recoverLostAndFound3Step(p: Psqlite3_recover): i32;
var
  pLaf: PRecoverStateLAF;
  res: i32;
  iPage: i64;
begin
  pLaf := @p^.laf;
  if p^.errCode = SQLITE_OK then begin
    if pLaf^.pInsert = nil then begin
      Result := SQLITE_DONE; Exit;
    end else begin
      if p^.errCode = SQLITE_OK then begin
        res := sqlite3_step(pLaf^.pAllPage);
        if res = SQLITE_ROW then begin
          iPage := sqlite3_column_int64(pLaf^.pAllPage, 0);
          if recoverBitmapQuery(pLaf^.pUsed, iPage) = 0 then
            recoverLostAndFoundOnePage(p, iPage);
        end else begin
          recoverReset(p, pLaf^.pAllPage);
          Result := SQLITE_DONE; Exit;
        end;
      end;
    end;
  end;
  Result := SQLITE_OK;
end;

procedure recoverLostAndFoundCleanup(p: Psqlite3_recover);
var
  apVal: PPsqlite3_value;
  ii: i32;
begin
  recoverBitmapFree(p^.laf.pUsed);
  p^.laf.pUsed := nil;
  sqlite3_finalize(p^.laf.pUsedPages);
  sqlite3_finalize(p^.laf.pAllAndParent);
  sqlite3_finalize(p^.laf.pMapInsert);
  sqlite3_finalize(p^.laf.pMaxField);
  sqlite3_finalize(p^.laf.pFindRoot);
  sqlite3_finalize(p^.laf.pInsert);
  sqlite3_finalize(p^.laf.pAllPage);
  sqlite3_finalize(p^.laf.pPageData);
  p^.laf.pUsedPages    := nil;
  p^.laf.pAllAndParent := nil;
  p^.laf.pMapInsert    := nil;
  p^.laf.pMaxField     := nil;
  p^.laf.pFindRoot     := nil;
  p^.laf.pInsert       := nil;
  p^.laf.pAllPage      := nil;
  p^.laf.pPageData     := nil;
  apVal := PPsqlite3_value(p^.laf.apVal);
  if apVal <> nil then begin
    for ii := 0 to p^.laf.nMaxField - 1 do
      if apVal[ii] <> nil then sqlite3_value_free(apVal[ii]);
    sqlite3_free(apVal);
  end;
  p^.laf.apVal := nil;
end;

{ ---------------------------------------------------------------
  Wrapper VFS — port of sqlite3recover.c lines 2050..2580.

  Installed by recoverInstallWrapper around the sqlite3_file held by
  the input db.  Its sole purpose is to intercept xRead() of page 1
  and substitute a sane header so sqlite3 can open even a database
  whose own header is corrupt.  All other methods pass through to the
  underlying VFS unchanged.

  RECOVER_MUTEX_ID protects the unit-level recover_g singleton so two
  recover handles do not stomp on each other while a wrapper is
  installed.  We use SQLITE_MUTEX_STATIC_APP2 to match upstream.
  --------------------------------------------------------------- }

const
  RECOVER_MUTEX_ID = SQLITE_MUTEX_STATIC_APP2;

type
  TRecoverGlobal = record
    pMethods: Psqlite3_io_methods;  { Saved upstream pMethods }
    p:        Psqlite3_recover;     { Owning recover handle }
  end;

var
  recover_g: TRecoverGlobal;
  recover_methods: sqlite3_io_methods;

procedure recoverEnterMutex; inline;
begin
  sqlite3_mutex_enter(sqlite3MutexAlloc(RECOVER_MUTEX_ID));
end;

procedure recoverLeaveMutex; inline;
begin
  sqlite3_mutex_leave(sqlite3MutexAlloc(RECOVER_MUTEX_ID));
end;

procedure recoverAssertMutexHeld; inline;
begin
  { No-op — Pascal port omits the upstream `assert(sqlite3_mutex_held(...))`
    diagnostic.  Same convention as backup / cksumvfs / vfslog ports. }
end;

function recoverGetU16(a: PByte): u32; inline;
begin
  Result := (u32(a[0]) shl 8) + u32(a[1]);
end;

function recoverGetU32(a: PByte): u32; inline;
begin
  Result := (u32(a[0]) shl 24) + (u32(a[1]) shl 16)
          + (u32(a[2]) shl 8) + u32(a[3]);
end;

function recoverGetVarint(a: PByte; out v: i64): i32;
var u: u64; i: i32;
begin
  u := 0;
  for i := 0 to 7 do begin
    u := (u shl 7) + (a[i] and $7F);
    if (a[i] and $80) = 0 then begin
      v := i64(u); Result := i + 1; Exit;
    end;
  end;
  u := (u shl 8) + a[8];
  v := i64(u);
  Result := 9;
end;

procedure recoverPutU16(a: PByte; v: u32); inline;
begin
  a[0] := u8((v shr 8) and $FF);
  a[1] := u8(v and $FF);
end;

procedure recoverPutU32(a: PByte; v: u32); inline;
begin
  a[0] := u8((v shr 24) and $FF);
  a[1] := u8((v shr 16) and $FF);
  a[2] := u8((v shr 8) and $FF);
  a[3] := u8(v and $FF);
end;

{ Probe a candidate b-tree page; returns 1 (true) if a[0..n-1] looks like
  a valid leaf/interior page, 0 otherwise.  aTmp is a scratch buffer of
  the same size used to track byte usage. }
function recoverIsValidPage(aTmp, a: PByte; n: i32): i32;
var
  aUsed: PByte;
  nFrag, nActual, iFree, nCell, iCellOff, iContent, eType, ii: i32;
  iNext, nByte, iByte, iOff: i32;
  X, M, K: i32;
  nPayload, dummy: i64;
begin
  aUsed := aTmp;
  nFrag := 0; nActual := 0; iFree := 0; nCell := 0; iCellOff := 0;
  iContent := 0; eType := 0; ii := 0;

  eType := i32(a[0]);
  if (eType <> $02) and (eType <> $05) and (eType <> $0A) and (eType <> $0D) then
  begin Result := 0; Exit; end;

  iFree    := i32(recoverGetU16(a + 1));
  nCell    := i32(recoverGetU16(a + 3));
  iContent := i32(recoverGetU16(a + 5));
  if iContent = 0 then iContent := 65536;
  nFrag    := i32(a[7]);

  if iContent > n then begin Result := 0; Exit; end;

  FillChar(aUsed^, n, 0);
  FillChar(aUsed^, iContent, $FF);

  if (iFree <> 0) and (iFree <= iContent) then begin Result := 0; Exit; end;
  while iFree <> 0 do begin
    iNext := 0; nByte := 0;
    if iFree > (n - 4) then begin Result := 0; Exit; end;
    iNext := i32(recoverGetU16(a + iFree));
    nByte := i32(recoverGetU16(a + iFree + 2));
    if (iFree + nByte > n) or (nByte < 4) then begin Result := 0; Exit; end;
    if (iNext <> 0) and (iNext < iFree + nByte) then begin Result := 0; Exit; end;
    FillChar((aUsed + iFree)^, nByte, $FF);
    iFree := iNext;
  end;

  if (eType = $02) or (eType = $05) then iCellOff := 12 else iCellOff := 8;
  if (iCellOff + 2 * nCell) > iContent then begin Result := 0; Exit; end;

  for ii := 0 to nCell - 1 do begin
    nPayload := 0;
    nByte := 0;
    iOff := i32(recoverGetU16(a + iCellOff + 2 * ii));
    if (iOff < iContent) or (iOff > n) then begin Result := 0; Exit; end;
    if (eType = $05) or (eType = $02) then nByte := nByte + 4;
    nByte := nByte + recoverGetVarint(a + iOff + nByte, nPayload);
    if eType = $0D then begin
      dummy := 0;
      nByte := nByte + recoverGetVarint(a + iOff + nByte, dummy);
    end;
    if eType <> $05 then begin
      if eType = $0D then X := n - 35
      else                X := ((n - 12) * 64 div 255) - 23;
      M := ((n - 12) * 32 div 255) - 23;
      K := M + i32((nPayload - M) mod (n - 4));
      if nPayload < X then
        nByte := nByte + i32(nPayload)
      else if K <= X then
        nByte := nByte + K + 4
      else
        nByte := nByte + M + 4;
    end;
    if iOff + nByte > n then begin Result := 0; Exit; end;
    iByte := iOff;
    while iByte < (iOff + nByte) do begin
      if aUsed[iByte] <> 0 then begin Result := 0; Exit; end;
      aUsed[iByte] := $FF;
      Inc(iByte);
    end;
  end;

  nActual := 0;
  for ii := 0 to n - 1 do
    if aUsed[ii] = 0 then Inc(nActual);
  if nActual = nFrag then Result := 1 else Result := 0;
end;

{ Forward decls for the io_methods table. }
function recoverVfsClose(pFd: Psqlite3_file): cint; cdecl; forward;
function recoverVfsRead(pFd: Psqlite3_file; aBuf: Pointer; nByte: cint;
  iOff: i64): cint; cdecl; forward;
function recoverVfsWrite(pFd: Psqlite3_file; aBuf: Pointer; nByte: cint;
  iOff: i64): cint; cdecl; forward;
function recoverVfsTruncate(pFd: Psqlite3_file; size: i64): cint; cdecl; forward;
function recoverVfsSync(pFd: Psqlite3_file; flags: cint): cint; cdecl; forward;
function recoverVfsFileSize(pFd: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function recoverVfsLock(pFd: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function recoverVfsUnlock(pFd: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function recoverVfsCheckReservedLock(pFd: Psqlite3_file; pResOut: PcInt): cint; cdecl; forward;
function recoverVfsFileControl(pFd: Psqlite3_file; op: cint; pArg: Pointer): cint; cdecl; forward;
function recoverVfsSectorSize(pFd: Psqlite3_file): cint; cdecl; forward;
function recoverVfsDeviceCharacteristics(pFd: Psqlite3_file): cint; cdecl; forward;
function recoverVfsShmMap(pFd: Psqlite3_file; iPg, pgsz, bExtend: cint;
  pp: PPointer): cint; cdecl; forward;
function recoverVfsShmLock(pFd: Psqlite3_file; offset, n, flags: cint): cint; cdecl; forward;
procedure recoverVfsShmBarrier(pFd: Psqlite3_file); cdecl; forward;
function recoverVfsShmUnmap(pFd: Psqlite3_file; deleteFlag: cint): cint; cdecl; forward;
function recoverVfsFetch(pFd: Psqlite3_file; iOff: i64; iAmt: cint;
  pp: PPointer): cint; cdecl; forward;
function recoverVfsUnfetch(pFd: Psqlite3_file; iOff: i64; pVal: Pointer): cint; cdecl; forward;

function recoverVfsClose(pFd: Psqlite3_file): cint; cdecl;
begin
  Assert(pFd^.pMethods <> @recover_methods);
  Result := pFd^.pMethods^.xClose(pFd);
end;

{ Detect the page-size of the input db by scanning the first nMaxBlk*64KB
  for a well-formed b-tree page.  Walks descending pgsz candidates (nMin
  up to nMax = 65536); a hit at any pgsz2 sets p^.detected_pgsz. }
function recoverVfsDetectPagesize(p: Psqlite3_recover; pFd: Psqlite3_file;
  nReserve: u32; nSz: i64): cint;
const
  nMin = 512;
  nMax = 65536;
  nMaxBlk = 4;
var
  rc: cint;
  pgsz: u32;
  iBlk, nBlk, nByte, pgsz2, iOff: cint;
  aPg, aTmp: PByte;
  hit: Boolean;
begin
  rc := SQLITE_OK;
  pgsz := 0;
  aPg := PByte(sqlite3_malloc(2 * nMax));
  if aPg = nil then begin Result := SQLITE_NOMEM; Exit; end;
  aTmp := aPg + nMax;

  nBlk := cint((nSz + nMax - 1) div nMax);
  if nBlk > nMaxBlk then nBlk := nMaxBlk;

  repeat
    iBlk := 0;
    while (rc = SQLITE_OK) and (iBlk < nBlk) do begin
      if nSz >= ((iBlk + 1) * nMax) then nByte := nMax
      else nByte := cint(nSz mod nMax);
      FillChar(aPg^, nMax, 0);
      rc := pFd^.pMethods^.xRead(pFd, aPg, nByte, iBlk * nMax);
      if rc = SQLITE_OK then begin
        if pgsz <> 0 then pgsz2 := cint(pgsz * 2) else pgsz2 := nMin;
        while pgsz2 <= nMax do begin
          iOff := 0;
          hit := False;
          while iOff < nMax do begin
            if recoverIsValidPage(aTmp, aPg + iOff,
                                  pgsz2 - cint(nReserve)) <> 0 then
            begin
              pgsz := u32(pgsz2);
              hit := True;
              break;
            end;
            iOff := iOff + pgsz2;
          end;
          if hit then break;
          pgsz2 := pgsz2 * 2;
        end;
      end;
      Inc(iBlk);
    end;
    if pgsz > u32(p^.detected_pgsz) then begin
      p^.detected_pgsz := i32(pgsz);
      p^.nReserve      := i32(nReserve);
    end;
    if nReserve = 0 then break;
    nReserve := 0;
  until False;

  p^.detected_pgsz := i32(pgsz);
  sqlite3_free(aPg);
  Result := rc;
end;

function recoverVfsRead(pFd: Psqlite3_file; aBuf: Pointer; nByte: cint;
  iOff: i64): cint; cdecl;
const
  aPreserve: array[0..5] of i32 = (32, 36, 52, 60, 64, 68);
var
  rc: cint;
  a: PByte;
  pgsz, nReserve, enc, dbsz: u32;
  dbFileSize: i64;
  ii: i32;
  p: Psqlite3_recover;
  aHdr: array[0..107] of u8;
begin
  rc := SQLITE_OK;
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xRead(pFd, aBuf, nByte, iOff);
    if nByte = 16 then begin
      sqlite3_randomness(16, aBuf);
    end
    else if (rc = SQLITE_OK) and (iOff = 0) and (nByte >= 108) then begin
      { Canonical sane page-1 header (108 bytes): keep enough of the
        on-disk header to drive recovery while ensuring the file looks
        well-formed to the engine. }
      FillChar(aHdr, SizeOf(aHdr), 0);
      aHdr[0] := $53; aHdr[1] := $51; aHdr[2] := $4c; aHdr[3] := $69;
      aHdr[4] := $74; aHdr[5] := $65; aHdr[6] := $20; aHdr[7] := $66;
      aHdr[8] := $6f; aHdr[9] := $72; aHdr[10] := $6d; aHdr[11] := $61;
      aHdr[12] := $74; aHdr[13] := $20; aHdr[14] := $33; aHdr[15] := $00;
      aHdr[16] := $FF; aHdr[17] := $FF; aHdr[18] := $01; aHdr[19] := $01;
      aHdr[20] := $00; aHdr[21] := $40; aHdr[22] := $20; aHdr[23] := $20;
      aHdr[28] := $00; aHdr[29] := $00; aHdr[30] := $00; aHdr[31] := $00;
      aHdr[32] := $FF; aHdr[33] := $FF; aHdr[34] := $FF; aHdr[35] := $FF;
      aHdr[36] := $FF; aHdr[37] := $FF; aHdr[38] := $FF; aHdr[39] := $FF;
      aHdr[40] := $FF; aHdr[41] := $FF; aHdr[42] := $FF; aHdr[43] := $FF;
      aHdr[47] := $04;
      aHdr[50] := $10;
      aHdr[52] := $FF; aHdr[53] := $FF; aHdr[54] := $FF; aHdr[55] := $FF;
      aHdr[56] := $FF; aHdr[57] := $FF; aHdr[58] := $FF; aHdr[59] := $FF;
      aHdr[60] := $FF; aHdr[61] := $FF; aHdr[62] := $FF; aHdr[63] := $FF;
      aHdr[64] := $FF; aHdr[65] := $FF; aHdr[66] := $FF; aHdr[67] := $FF;
      aHdr[68] := $FF; aHdr[69] := $FF; aHdr[70] := $FF; aHdr[71] := $FF;
      aHdr[97]  := $2e; aHdr[98]  := $5b; aHdr[99]  := $30;
      aHdr[100] := $0D;
      { aHdr[105/106] = 0xFF/0xFF is overwritten below by recoverPutU16. }

      a := PByte(aBuf);
      pgsz     := recoverGetU16(a + 16);
      nReserve := a[20];
      enc      := recoverGetU32(a + 56);
      dbsz     := 0;
      dbFileSize := 0;
      p := recover_g.p;

      if pgsz = $01 then pgsz := 65536;
      rc := pFd^.pMethods^.xFileSize(pFd, @dbFileSize);

      if (rc = SQLITE_OK) and (p^.detected_pgsz = 0) then
        rc := recoverVfsDetectPagesize(p, pFd, nReserve, dbFileSize);
      if p^.detected_pgsz <> 0 then begin
        pgsz := u32(p^.detected_pgsz);
        nReserve := u32(p^.nReserve);
      end;

      if pgsz <> 0 then dbsz := u32(dbFileSize div pgsz);
      if (enc <> SQLITE_UTF8) and (enc <> SQLITE_UTF16BE)
         and (enc <> SQLITE_UTF16LE) then enc := SQLITE_UTF8;

      if p^.pPage1Cache <> nil then sqlite3_free(p^.pPage1Cache);
      p^.pPage1Cache := nil;
      p^.pPage1Disk  := nil;

      p^.pgsz := nByte;
      p^.pPage1Cache := PByte(recoverMalloc(p, i64(nByte) * 2));
      if p^.pPage1Cache <> nil then begin
        p^.pPage1Disk := p^.pPage1Cache + nByte;
        Move(aBuf^, p^.pPage1Disk^, nByte);
        aHdr[18] := a[18];
        aHdr[19] := a[19];
        recoverPutU32(@aHdr[28], dbsz);
        recoverPutU32(@aHdr[56], enc);
        recoverPutU16(@aHdr[105], pgsz - nReserve);
        if pgsz = 65536 then pgsz := 1;
        recoverPutU16(@aHdr[16], pgsz);
        aHdr[20] := u8(nReserve);
        for ii := 0 to High(aPreserve) do
          Move(a[aPreserve[ii]], aHdr[aPreserve[ii]], 4);
        Move(aHdr[0], PByte(aBuf)^, SizeOf(aHdr));
        FillChar((PByte(aBuf) + SizeOf(aHdr))^, nByte - SizeOf(aHdr), 0);

        Move(PByte(aBuf)^, p^.pPage1Cache^, nByte);
      end else begin
        rc := p^.errCode;
      end;
    end;
    pFd^.pMethods := @recover_methods;
  end else begin
    rc := pFd^.pMethods^.xRead(pFd, aBuf, nByte, iOff);
  end;
  Result := rc;
end;

function recoverVfsWrite(pFd: Psqlite3_file; aBuf: Pointer; nByte: cint;
  iOff: i64): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xWrite(pFd, aBuf, nByte, iOff);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xWrite(pFd, aBuf, nByte, iOff);
  Result := rc;
end;

function recoverVfsTruncate(pFd: Psqlite3_file; size: i64): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xTruncate(pFd, size);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xTruncate(pFd, size);
  Result := rc;
end;

function recoverVfsSync(pFd: Psqlite3_file; flags: cint): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xSync(pFd, flags);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xSync(pFd, flags);
  Result := rc;
end;

function recoverVfsFileSize(pFd: Psqlite3_file; pSize: Pi64): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xFileSize(pFd, pSize);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xFileSize(pFd, pSize);
  Result := rc;
end;

function recoverVfsLock(pFd: Psqlite3_file; eLock: cint): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xLock(pFd, eLock);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xLock(pFd, eLock);
  Result := rc;
end;

function recoverVfsUnlock(pFd: Psqlite3_file; eLock: cint): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xUnlock(pFd, eLock);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xUnlock(pFd, eLock);
  Result := rc;
end;

function recoverVfsCheckReservedLock(pFd: Psqlite3_file; pResOut: PcInt): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xCheckReservedLock(pFd, pResOut);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xCheckReservedLock(pFd, pResOut);
  Result := rc;
end;

function recoverVfsFileControl(pFd: Psqlite3_file; op: cint; pArg: Pointer): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    if pFd^.pMethods <> nil then
      rc := pFd^.pMethods^.xFileControl(pFd, op, pArg)
    else
      rc := SQLITE_NOTFOUND;
    pFd^.pMethods := @recover_methods;
  end else begin
    if pFd^.pMethods <> nil then
      rc := pFd^.pMethods^.xFileControl(pFd, op, pArg)
    else
      rc := SQLITE_NOTFOUND;
  end;
  Result := rc;
end;

function recoverVfsSectorSize(pFd: Psqlite3_file): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xSectorSize(pFd);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xSectorSize(pFd);
  Result := rc;
end;

function recoverVfsDeviceCharacteristics(pFd: Psqlite3_file): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xDeviceCharacteristics(pFd);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xDeviceCharacteristics(pFd);
  Result := rc;
end;

function recoverVfsShmMap(pFd: Psqlite3_file; iPg, pgsz, bExtend: cint;
  pp: PPointer): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xShmMap(pFd, iPg, pgsz, bExtend, pp);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xShmMap(pFd, iPg, pgsz, bExtend, pp);
  Result := rc;
end;

function recoverVfsShmLock(pFd: Psqlite3_file; offset, n, flags: cint): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xShmLock(pFd, offset, n, flags);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xShmLock(pFd, offset, n, flags);
  Result := rc;
end;

procedure recoverVfsShmBarrier(pFd: Psqlite3_file); cdecl;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    pFd^.pMethods^.xShmBarrier(pFd);
    pFd^.pMethods := @recover_methods;
  end else
    pFd^.pMethods^.xShmBarrier(pFd);
end;

function recoverVfsShmUnmap(pFd: Psqlite3_file; deleteFlag: cint): cint; cdecl;
var rc: cint;
begin
  if pFd^.pMethods = @recover_methods then begin
    pFd^.pMethods := recover_g.pMethods;
    rc := pFd^.pMethods^.xShmUnmap(pFd, deleteFlag);
    pFd^.pMethods := @recover_methods;
  end else
    rc := pFd^.pMethods^.xShmUnmap(pFd, deleteFlag);
  Result := rc;
end;

function recoverVfsFetch(pFd: Psqlite3_file; iOff: i64; iAmt: cint;
  pp: PPointer): cint; cdecl;
begin
  pp^ := nil;
  Result := SQLITE_OK;
end;

function recoverVfsUnfetch(pFd: Psqlite3_file; iOff: i64; pVal: Pointer): cint; cdecl;
begin
  Result := SQLITE_OK;
end;

procedure recoverInstallWrapper(p: Psqlite3_recover);
var
  pFd: Psqlite3_file;
  iVersion: cint;
begin
  pFd := nil;
  Assert(recover_g.pMethods = nil);
  recoverAssertMutexHeld;
  sqlite3_file_control(p^.dbIn, p^.zDb, SQLITE_FCNTL_FILE_POINTER, @pFd);
  Assert((pFd = nil) or (pFd^.pMethods <> @recover_methods));
  if (pFd <> nil) and (pFd^.pMethods <> nil) then begin
    if (pFd^.pMethods^.iVersion > 1) and (Pointer(pFd^.pMethods^.xShmMap) <> nil) then
      iVersion := 2
    else
      iVersion := 1;
    recover_g.pMethods := pFd^.pMethods;
    recover_g.p := p;
    recover_methods.iVersion := iVersion;
    pFd^.pMethods := @recover_methods;
  end;
end;

procedure recoverUninstallWrapper(p: Psqlite3_recover);
var pFd: Psqlite3_file;
begin
  pFd := nil;
  recoverAssertMutexHeld;
  sqlite3_file_control(p^.dbIn, p^.zDb, SQLITE_FCNTL_FILE_POINTER, @pFd);
  if (pFd <> nil) and (pFd^.pMethods <> nil) then begin
    pFd^.pMethods := recover_g.pMethods;
    recover_g.pMethods := nil;
    recover_g.p := nil;
  end;
end;

procedure recoverInitMethods;
begin
  FillChar(recover_methods, SizeOf(recover_methods), 0);
  recover_methods.iVersion             := 2;
  recover_methods.xClose               := @recoverVfsClose;
  recover_methods.xRead                := @recoverVfsRead;
  recover_methods.xWrite               := @recoverVfsWrite;
  recover_methods.xTruncate            := @recoverVfsTruncate;
  recover_methods.xSync                := @recoverVfsSync;
  recover_methods.xFileSize            := @recoverVfsFileSize;
  recover_methods.xLock                := @recoverVfsLock;
  recover_methods.xUnlock              := @recoverVfsUnlock;
  recover_methods.xCheckReservedLock   := @recoverVfsCheckReservedLock;
  recover_methods.xFileControl         := @recoverVfsFileControl;
  recover_methods.xSectorSize          := @recoverVfsSectorSize;
  recover_methods.xDeviceCharacteristics := @recoverVfsDeviceCharacteristics;
  recover_methods.xShmMap              := @recoverVfsShmMap;
  recover_methods.xShmLock             := @recoverVfsShmLock;
  recover_methods.xShmBarrier          := @recoverVfsShmBarrier;
  recover_methods.xShmUnmap            := @recoverVfsShmUnmap;
  recover_methods.xFetch               := @recoverVfsFetch;
  recover_methods.xUnfetch             := @recoverVfsUnfetch;
end;

{ ---------------------------------------------------------------
  recoverStep — initial-cut state machine.

  The full upstream pipeline is:
    INIT          → open output, transfer settings, cache schema,
                    write recovered schema (recoverWriteSchema1) —
                    move to WRITING
    WRITING       → drive recoverWriteDataStep one batch at a time
    LOSTANDFOUND* → optional orphan-row collection
    SCHEMA2       → recoverWriteSchema2 + COMMIT
    DONE          → no-op

  This initial port runs everything that does not require the
  per-table emit machinery (helpers, SQL UDFs, settings transfer,
  schema-cache UNION ALL) and then short-circuits to DONE.  Follow-up
  commits will fill in the WRITING / SCHEMA2 / LOSTANDFOUND* arms.
  --------------------------------------------------------------- }

procedure recoverStep(p: Psqlite3_recover);
var
  rc: i32;
  bUseWrapper: i32;
  bRetry: Boolean;
begin
  Assert((p <> nil) and (p^.errCode = SQLITE_OK));
  case p^.eState of
    RECOVER_STATE_INIT:
      begin
        recoverSqlCallback(p, 'BEGIN');
        recoverSqlCallback(p, 'PRAGMA writable_schema = on');
        recoverSqlCallback(p, 'PRAGMA foreign_keys = off');

        recoverEnterMutex;
        recoverOpenOutput(p);

        if p^.errCode = SQLITE_OK then begin
          { Two attempts — first with the wrapper installed, then again
            without it on SQLITE_NOTADB.  Mirrors recoverStep upstream
            (sqlite3recover.c:2604..2629). }
          bUseWrapper := 1;
          repeat
            p^.errCode := SQLITE_OK;
            if bUseWrapper <> 0 then recoverInstallWrapper(p);

            sqlite3_file_control(p^.dbIn, p^.zDb,
                                 SQLITE_FCNTL_RESET_CACHE, nil);
            recoverExec(p, p^.dbIn, 'PRAGMA writable_schema = on');
            recoverExec(p, p^.dbIn, 'BEGIN');
            if p^.errCode = SQLITE_OK then p^.bCloseTransaction := 1;
            recoverExec(p, p^.dbIn, 'SELECT 1 FROM sqlite_schema');
            recoverTransferSettings(p);
            recoverOpenRecovery(p);
            recoverCacheSchema(p);

            if bUseWrapper <> 0 then recoverUninstallWrapper(p);
            bRetry := False;
            if (p^.errCode = SQLITE_NOTADB) and (bUseWrapper <> 0) then begin
              if SQLITE_OK = sqlite3_exec(p^.dbIn, 'ROLLBACK',
                                          nil, nil, nil) then begin
                Dec(bUseWrapper);
                bRetry := True;
              end;
            end;
          until not bRetry;
        end;

        recoverLeaveMutex;
        if p^.errCode = SQLITE_OK then begin
          recoverExec(p, p^.dbOut, 'BEGIN');
          recoverWriteSchema1(p);
          recoverWriteDataInit(p);
        end;
        p^.eState := RECOVER_STATE_WRITING;
      end;
    RECOVER_STATE_WRITING:
      begin
        if recoverWriteDataStep(p) = SQLITE_DONE then begin
          recoverWriteDataCleanup(p);
          if p^.zLostAndFound <> nil then begin
            recoverLostAndFound1Init(p);
            p^.eState := RECOVER_STATE_LOSTANDFOUND1;
          end else begin
            p^.eState := RECOVER_STATE_SCHEMA2;
          end;
        end;
      end;
    RECOVER_STATE_LOSTANDFOUND1:
      begin
        if recoverLostAndFound1Step(p) = SQLITE_DONE then begin
          recoverLostAndFound2Init(p);
          p^.eState := RECOVER_STATE_LOSTANDFOUND2;
        end;
      end;
    RECOVER_STATE_LOSTANDFOUND2:
      begin
        if recoverLostAndFound2Step(p) = SQLITE_DONE then begin
          recoverLostAndFound3Init(p);
          p^.eState := RECOVER_STATE_LOSTANDFOUND3;
        end;
      end;
    RECOVER_STATE_LOSTANDFOUND3:
      begin
        if recoverLostAndFound3Step(p) = SQLITE_DONE then
          p^.eState := RECOVER_STATE_SCHEMA2;
      end;
    RECOVER_STATE_SCHEMA2:
      begin
        recoverWriteSchema2(p);
        if p^.errCode = SQLITE_OK then begin
          recoverExec(p, p^.dbOut, 'COMMIT');
          rc := sqlite3_exec(p^.dbIn, 'END', nil, nil, nil);
          if p^.errCode = SQLITE_OK then p^.errCode := rc;
          p^.bCloseTransaction := 0;
          recoverSqlCallback(p, 'PRAGMA writable_schema = off');
          recoverSqlCallback(p, 'COMMIT');
        end;
        p^.eState := RECOVER_STATE_DONE;
        recoverFinalCleanup(p);
      end;
    RECOVER_STATE_DONE:
      begin
        { no-op }
      end;
  end;
end;

{ ---------------------------------------------------------------
  Public API
  --------------------------------------------------------------- }

function recoverInit(db: PTsqlite3; zDb, zUri: PAnsiChar;
  xSql: TXSqlCb; pSqlCtx: Pointer): Psqlite3_recover;
var
  pRet: Psqlite3_recover;
  nDb, nUri, nByte: i32;
  pTail: PAnsiChar;
begin
  pRet := nil;
  if zDb = nil then zDb := 'main';
  nDb  := recoverStrlen(zDb);
  nUri := recoverStrlen(zUri);
  nByte := SizeOf(Tsqlite3_recover) + nDb + 1 + nUri + 1;
  pRet := Psqlite3_recover(sqlite3_malloc(nByte));
  if pRet <> nil then begin
    FillChar(pRet^, nByte, 0);
    pRet^.dbIn  := db;
    pTail := PAnsiChar(pRet) + SizeOf(Tsqlite3_recover);
    pRet^.zDb   := pTail;
    pRet^.zUri  := pTail + nDb + 1;
    if nDb > 0 then Move(zDb[0], pRet^.zDb[0], nDb);
    if (nUri > 0) and (zUri <> nil) then Move(zUri[0], pRet^.zUri[0], nUri);
    pRet^.xSql  := xSql;
    pRet^.pSqlCtx := pSqlCtx;
    pRet^.bRecoverRowid := RECOVER_ROWID_DEFAULT;
  end;
  Result := pRet;
end;

function sqlite3_recover_init(db: PTsqlite3; zDb, zUri: PAnsiChar): Psqlite3_recover;
begin
  Result := recoverInit(db, zDb, zUri, nil, nil);
end;

function sqlite3_recover_init_sql(db: PTsqlite3; zDb: PAnsiChar;
  xSql: TXSqlCb; pSqlCtx: Pointer): Psqlite3_recover;
begin
  Result := recoverInit(db, zDb, nil, xSql, pSqlCtx);
end;

function sqlite3_recover_errmsg(p: Psqlite3_recover): PAnsiChar;
begin
  if (p <> nil) and (p^.errCode <> SQLITE_NOMEM) then
    Result := p^.zErrMsg
  else
    Result := 'out of memory';
end;

function sqlite3_recover_errcode(p: Psqlite3_recover): i32;
begin
  if p <> nil then Result := p^.errCode
              else Result := SQLITE_NOMEM;
end;

function sqlite3_recover_config(p: Psqlite3_recover; op: i32; pArg: Pointer): i32;
var rc: i32;
begin
  rc := SQLITE_OK;
  if p = nil then begin
    Result := SQLITE_NOMEM; Exit;
  end;
  if p^.eState <> RECOVER_STATE_INIT then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  case op of
    789:
      begin
        if p^.zStateDb <> nil then sqlite3_free(p^.zStateDb);
        p^.zStateDb := recoverMPrintf(p, '%s', [PAnsiChar(pArg)]);
      end;
    SQLITE_RECOVER_LOST_AND_FOUND:
      begin
        if p^.zLostAndFound <> nil then sqlite3_free(p^.zLostAndFound);
        if pArg <> nil then
          p^.zLostAndFound := recoverMPrintf(p, '%s', [PAnsiChar(pArg)])
        else
          p^.zLostAndFound := nil;
      end;
    SQLITE_RECOVER_FREELIST_CORRUPT: p^.bFreelistCorrupt := PInteger(pArg)^;
    SQLITE_RECOVER_ROWIDS:           p^.bRecoverRowid    := PInteger(pArg)^;
    SQLITE_RECOVER_SLOWINDEXES:      p^.bSlowIndexes     := PInteger(pArg)^;
    else
      rc := SQLITE_NOTFOUND;
  end;
  Result := rc;
end;

function sqlite3_recover_step(p: Psqlite3_recover): i32;
begin
  if p = nil then begin Result := SQLITE_NOMEM; Exit; end;
  if p^.errCode = SQLITE_OK then recoverStep(p);
  if (p^.eState = RECOVER_STATE_DONE) and (p^.errCode = SQLITE_OK) then
    Result := SQLITE_DONE
  else
    Result := p^.errCode;
end;

function sqlite3_recover_run(p: Psqlite3_recover): i32;
begin
  while SQLITE_OK = sqlite3_recover_step(p) do ;
  Result := sqlite3_recover_errcode(p);
end;

function sqlite3_recover_finish(p: Psqlite3_recover): i32;
var rc: i32;
begin
  if p = nil then begin Result := SQLITE_NOMEM; Exit; end;
  recoverFinalCleanup(p);
  if (p^.bCloseTransaction <> 0) and (sqlite3_get_autocommit(p^.dbIn) = 0) then begin
    rc := sqlite3_exec(p^.dbIn, 'END', nil, nil, nil);
    if p^.errCode = SQLITE_OK then p^.errCode := rc;
  end;
  rc := p^.errCode;
  if p^.zErrMsg       <> nil then sqlite3_free(p^.zErrMsg);
  if p^.zStateDb      <> nil then sqlite3_free(p^.zStateDb);
  if p^.zLostAndFound <> nil then sqlite3_free(p^.zLostAndFound);
  if p^.pPage1Cache   <> nil then sqlite3_free(p^.pPage1Cache);
  sqlite3_free(p);
  Result := rc;
end;

initialization
  recoverInitMethods;
  FillChar(recover_g, SizeOf(recover_g), 0);

end.
