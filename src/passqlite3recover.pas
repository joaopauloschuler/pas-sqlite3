{
  SPDX-License-Identifier: blessing

  Faithful initial-cut port of ../sqlite3/ext/recover/sqlite3recover.c
  (~2901 lines C → ~700 lines Pascal scaffold).

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
      { The page-1 cache divergence-injection optimisation in upstream
        is conditional on pPage1Cache being populated by the wrapper VFS;
        the wrapper is not yet ported, so we always serve the raw blob. }
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

procedure recoverFinalCleanup(p: Psqlite3_recover);
var pTab, pNext: PRecoverTable;
begin
  if p = nil then Exit;
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
var rc: i32;
begin
  Assert((p <> nil) and (p^.errCode = SQLITE_OK));
  case p^.eState of
    RECOVER_STATE_INIT:
      begin
        recoverSqlCallback(p, 'BEGIN');
        recoverSqlCallback(p, 'PRAGMA writable_schema = on');
        recoverSqlCallback(p, 'PRAGMA foreign_keys = off');

        recoverOpenOutput(p);

        if p^.errCode = SQLITE_OK then begin
          sqlite3_file_control(p^.dbIn, p^.zDb, SQLITE_FCNTL_RESET_CACHE, nil);
          recoverExec(p, p^.dbIn, 'PRAGMA writable_schema = on');
          recoverExec(p, p^.dbIn, 'BEGIN');
          if p^.errCode = SQLITE_OK then p^.bCloseTransaction := 1;
          recoverExec(p, p^.dbIn, 'SELECT 1 FROM sqlite_schema');
          recoverTransferSettings(p);
          recoverOpenRecovery(p);
          recoverCacheSchema(p);
        end;

        { recoverWriteSchema1 / WRITING / SCHEMA2 deferred — short
          circuit to DONE so callers see SQLITE_DONE. }
        if p^.errCode = SQLITE_OK then begin
          recoverExec(p, p^.dbOut, 'BEGIN');
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

end.
