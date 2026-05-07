{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/recover/dbdata.c (1023 lines in C).

  Provides two eponymous virtual tables that read raw b-tree page bytes
  via the sqlite_dbpage virtual table:

    sqlite_dbdata(pgno INTEGER, cell INTEGER, field INTEGER,
                  value ANY, schema TEXT HIDDEN)
        — one row per record-field on every b-tree page in the database.
          For intkey b-trees the rowid value is reported in field=-1.

    sqlite_dbptr(pgno INTEGER, child INTEGER, schema TEXT HIDDEN)
        — one row per parent->child pointer between b-tree pages.

  Both modules tolerate corruption: a bad page yields no rows for that
  page rather than an error.  This is the storage layer that backs the
  ext/recover sqlite3recover.c corruption-recovery API (Phase 10.1.48
  ".recover" dot-command depends on it).

  Public entry: sqlite3DbdataRegister(db) — equivalent to
  sqlite3_dbdata_init() in C.
}
{$I passqlite3.inc}
unit passqlite3dbdata;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3DbdataRegister(db: PTsqlite3): i32;

implementation

const
  { dbdata.c:87 } DBDATA_PADDING_BYTES = 100;
  { dbdata.c:546 — DBDATA_MX_CELL(pgsz) := (pgsz-8)/6 ; computed inline. }
  { dbdata.c:550 } DBDATA_MX_FIELD = 32676;

  { dbdata.c:136..148 — sqlite_dbdata column ordinals. }
  DBDATA_COLUMN_PGNO   = 0;
  DBDATA_COLUMN_CELL   = 1;
  DBDATA_COLUMN_FIELD  = 2;
  DBDATA_COLUMN_VALUE  = 3;
  DBDATA_COLUMN_SCHEMA = 4;
  DBDATA_SCHEMA =
    'CREATE TABLE x(' +
    '  pgno INTEGER,' +
    '  cell INTEGER,' +
    '  field INTEGER,' +
    '  value ANY,' +
    '  schema TEXT HIDDEN' +
    ')';

  { dbdata.c:151..159 — sqlite_dbptr column ordinals. }
  DBPTR_COLUMN_PGNO   = 0;
  DBPTR_COLUMN_CHILD  = 1;
  DBPTR_COLUMN_SCHEMA = 2;
  DBPTR_SCHEMA =
    'CREATE TABLE x(' +
    '  pgno INTEGER,' +
    '  child INTEGER,' +
    '  schema TEXT HIDDEN' +
    ')';

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { dbdata.c:96..99 — DbdataBuffer. }
  PDbdataBuffer = ^TDbdataBuffer;
  TDbdataBuffer = record
    aBuf : Pu8;
    nBuf : i64;
  end;

  { dbdata.c:102..125 — DbdataCursor. }
  PDbdataCursor = ^TDbdataCursor;
  TDbdataCursor = record
    base     : Tsqlite3_vtab_cursor;     { MUST be first }
    pStmt    : Pointer;                  { sqlite3_stmt* — page fetcher }

    iPgno    : i32;
    aPage    : Pu8;
    nPage    : i32;
    nCell    : i32;
    iCell    : i32;
    bOnePage : i32;
    szDb     : i32;
    iRowid   : i64;

    { Only for sqlite_dbdata }
    rec      : TDbdataBuffer;
    nRec     : i64;
    nHdr     : i64;
    iField   : i32;
    pHdrPtr  : Pu8;
    pPtr     : Pu8;
    enc      : u32;
    iIntkey  : i64;
  end;

  { dbdata.c:128..133 — DbdataTable. }
  PDbdataTable = ^TDbdataTable;
  TDbdataTable = record
    base  : Tsqlite3_vtab;        { MUST be first }
    db    : PTsqlite3;
    pStmt : Pointer;              { cached fetcher (lent to next cursor) }
    bPtr  : i32;                  { True for sqlite_dbptr }
  end;

var
  dbdataModule: Tsqlite3_module;

{ ----- helpers ----- }

{$POINTERMATH ON}

{ dbdata.c:166..176 — dbdataBufferSize.  Grow buffer to >= nMin bytes. }
function dbdataBufferSize(pBuf: PDbdataBuffer; nMin: i64): i32;
var
  nNew : i64;
  aNew : Pu8;
begin
  if nMin > pBuf^.nBuf then begin
    nNew := nMin + 16384;
    aNew := Pu8(sqlite3_realloc64(pBuf^.aBuf, u64(nNew)));
    if aNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    pBuf^.aBuf := aNew;
    pBuf^.nBuf := nNew;
  end;
  Result := SQLITE_OK;
end;

{ dbdata.c:181..184 — dbdataBufferFree. }
procedure dbdataBufferFree(pBuf: PDbdataBuffer);
begin
  sqlite3_free(pBuf^.aBuf);
  FillChar(pBuf^, SizeOf(TDbdataBuffer), 0);
end;

{ dbdata.c:344..346 — get_uint16. }
function getUint16(a: Pu8): u32; inline;
begin
  Result := (u32(a[0]) shl 8) or u32(a[1]);
end;

{ dbdata.c:347..352 — get_uint32. }
function getUint32(a: Pu8): u32; inline;
begin
  Result := (u32(a[0]) shl 24)
         or (u32(a[1]) shl 16)
         or (u32(a[2]) shl 8)
         or  u32(a[3]);
end;

{ dbdata.c:404..414 — dbdataGetVarint. }
function dbdataGetVarint(z: Pu8; pVal: Pi64): i32;
var
  u : u64;
  i : i32;
begin
  u := 0;
  for i := 0 to 7 do begin
    u := (u shl 7) + u64(z[i] and $7f);
    if (z[i] and $80) = 0 then begin
      pVal^ := i64(u);
      Result := i + 1;
      Exit;
    end;
  end;
  u := (u shl 8) + u64(z[8] and $ff);
  pVal^ := i64(u);
  Result := 9;
end;

{ dbdata.c:421..427 — dbdataGetVarintU32.  Clamp out-of-range to 0. }
function dbdataGetVarintU32(z: Pu8; pVal: Pi64): i32;
var
  v : i64;
  n : i32;
begin
  n := dbdataGetVarint(z, @v);
  if (v < 0) or (v > $FFFFFFFF) then v := 0;
  pVal^ := v;
  Result := n;
end;

{ dbdata.c:433..457 — dbdataValueBytes.  Bytes of payload for serial type. }
function dbdataValueBytes(eType: i32): i32;
begin
  case eType of
    0, 8, 9, 10, 11: Result := 0;
    1: Result := 1;
    2: Result := 2;
    3: Result := 3;
    4: Result := 4;
    5: Result := 6;
    6, 7: Result := 8;
  else
    if eType > 0 then
      Result := (eType - 12) div 2
    else
      Result := 0;
  end;
end;

{ dbdata.c:463..541 — dbdataValue.  Decode a serial value into ctx. }
procedure dbdataValue(pCtx: Psqlite3_context; enc: u32; eType: i32;
  pData: Pu8; nData: i64);
var
  v   : u64;
  n   : i32;
  r   : Double;
  pD  : Pu8;
begin
  if eType < 0 then Exit;

  if dbdataValueBytes(eType) <= nData then begin
    case eType of
      0, 10, 11: sqlite3_result_null(pCtx);
      8: sqlite3_result_int(pCtx, 0);
      9: sqlite3_result_int(pCtx, 1);
      1, 2, 3, 4, 5, 6, 7:
        begin
          { Sign-extend from the first byte. }
          v := u64(i64(ShortInt(pData[0])));
          pD := pData + 1;
          { Fall-through chain (C uses `case 7: case 6: …` without break). }
          case eType of
            7, 6:
              begin
                v := (v shl 16) + (u64(pD[0]) shl 8) + u64(pD[1]); Inc(pD, 2);
                v := (v shl 16) + (u64(pD[0]) shl 8) + u64(pD[1]); Inc(pD, 2);
                v := (v shl 8)  + u64(pD[0]);                       Inc(pD);
                v := (v shl 8)  + u64(pD[0]);                       Inc(pD);
                v := (v shl 8)  + u64(pD[0]);                       Inc(pD);
              end;
            5:
              begin
                v := (v shl 16) + (u64(pD[0]) shl 8) + u64(pD[1]); Inc(pD, 2);
                v := (v shl 8)  + u64(pD[0]);                       Inc(pD);
                v := (v shl 8)  + u64(pD[0]);                       Inc(pD);
                v := (v shl 8)  + u64(pD[0]);                       Inc(pD);
              end;
            4:
              begin
                v := (v shl 8) + u64(pD[0]); Inc(pD);
                v := (v shl 8) + u64(pD[0]); Inc(pD);
                v := (v shl 8) + u64(pD[0]); Inc(pD);
              end;
            3:
              begin
                v := (v shl 8) + u64(pD[0]); Inc(pD);
                v := (v shl 8) + u64(pD[0]); Inc(pD);
              end;
            2:
              begin
                v := (v shl 8) + u64(pD[0]); Inc(pD);
              end;
          end;

          if eType = 7 then begin
            Move(v, r, SizeOf(r));
            sqlite3_result_double(pCtx, r);
          end else
            sqlite3_result_int64(pCtx, i64(v));
        end;
    else
      n := (eType - 12) div 2;
      if (eType mod 2) = 1 then begin
        { Text. }
        case enc of
          SQLITE_UTF16BE:
            sqlite3_result_text16be(pCtx, Pointer(pData), n, SQLITE_TRANSIENT);
          SQLITE_UTF16LE:
            sqlite3_result_text16le(pCtx, Pointer(pData), n, SQLITE_TRANSIENT);
        else
          sqlite3_result_text(pCtx, PAnsiChar(pData), n, SQLITE_TRANSIENT);
        end;
      end else begin
        { Blob. }
        sqlite3_result_blob(pCtx, Pointer(pData), n, SQLITE_TRANSIENT);
      end;
    end;
  end else begin
    { Truncated payload (corruption tolerance). }
    if eType = 7 then
      sqlite3_result_double(pCtx, 0.0)
    else if eType < 7 then
      sqlite3_result_int(pCtx, 0)
    else if (eType mod 2) = 1 then
      sqlite3_result_text(pCtx, PAnsiChar(''), 0, SQLITE_STATIC)
    else
      sqlite3_result_blob(pCtx, Pointer(PAnsiChar('')), 0, SQLITE_STATIC);
  end;
end;

{ dbdata.c:364..399 — dbdataLoadPage.  Fetch one page via sqlite_dbpage. }
function dbdataLoadPage(pCsr: PDbdataCursor; pgno: u32;
  ppPage: PPointer; pnPage: Pi32): i32;
var
  rc, rc2 : i32;
  pStmt   : Pointer;
  nCopy   : i32;
  pPage   : Pu8;
  pCopy   : Pointer;
begin
  rc := SQLITE_OK;
  pStmt := pCsr^.pStmt;
  ppPage^ := nil;
  pnPage^ := 0;
  if pgno > 0 then begin
    sqlite3_bind_int64(pStmt, 2, i64(pgno));
    if sqlite3_step(pStmt) = SQLITE_ROW then begin
      nCopy := sqlite3_column_bytes(pStmt, 0);
      if nCopy > 0 then begin
        pPage := Pu8(sqlite3_malloc64(u64(nCopy + DBDATA_PADDING_BYTES)));
        if pPage = nil then
          rc := SQLITE_NOMEM
        else begin
          pCopy := sqlite3_column_blob(pStmt, 0);
          Move(pCopy^, pPage^, nCopy);
          FillChar((pPage + nCopy)^, DBDATA_PADDING_BYTES, 0);
        end;
        ppPage^ := pPage;
        pnPage^ := nCopy;
      end;
    end;
    rc2 := sqlite3_reset(pStmt);
    if rc = SQLITE_OK then rc := rc2;
  end;
  Result := rc;
end;

{ dbdata.c:779..785 — dbdataIsFunction.  Returns trimmed length when
  zSchema ends in "()", else 0. }
function dbdataIsFunction(zSchema: PAnsiChar): i32;
var n: PtrUInt;
begin
  n := StrLen(zSchema);
  if (n > 2) and (zSchema[n - 2] = '(') and (zSchema[n - 1] = ')') then
    Result := i32(n) - 2
  else
    Result := 0;
end;

{ ----- module callbacks ----- }

{ dbdata.c:190..217 — dbdataConnect. }
function dbdataConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pTab : PDbdataTable;
  rc   : i32;
begin
  pTab := nil;
  if pAux <> nil then
    rc := sqlite3_declare_vtab(db, DBPTR_SCHEMA)
  else
    rc := sqlite3_declare_vtab(db, DBDATA_SCHEMA);
  sqlite3_vtab_config(db, SQLITE_VTAB_USES_ALL_SCHEMAS, 0);
  if rc = SQLITE_OK then begin
    pTab := PDbdataTable(sqlite3_malloc64(SizeOf(TDbdataTable)));
    if pTab = nil then
      rc := SQLITE_NOMEM
    else begin
      FillChar(pTab^, SizeOf(TDbdataTable), 0);
      pTab^.db := db;
      if pAux <> nil then pTab^.bPtr := 1 else pTab^.bPtr := 0;
    end;
  end;
  ppVtab^ := PSqlite3Vtab(pTab);
  Result := rc;
end;

{ dbdata.c:222..229 — dbdataDisconnect. }
function dbdataDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
var pTab: PDbdataTable;
begin
  pTab := PDbdataTable(pVtab);
  if pTab <> nil then begin
    sqlite3_finalize(pTab^.pStmt);
    sqlite3_free(pVtab);
  end;
  Result := SQLITE_OK;
end;

{ dbdata.c:244..289 — dbdataBestIndex.  Recognises schema=? and pgno=?. }
function dbdataBestIndex(tab: PSqlite3Vtab;
  pIdx: PSqlite3IndexInfo): i32; cdecl;
var
  pTab     : PDbdataTable;
  i        : i32;
  iSchema  : i32;
  iPgno    : i32;
  colSchema: i32;
  p        : PSqlite3IndexConstraint;
  iCol     : i32;
begin
  pTab := PDbdataTable(tab);
  iSchema := -1;
  iPgno   := -1;
  if pTab^.bPtr <> 0 then
    colSchema := DBPTR_COLUMN_SCHEMA
  else
    colSchema := DBDATA_COLUMN_SCHEMA;

  for i := 0 to pIdx^.nConstraint - 1 do begin
    p := pIdx^.aConstraint + i;
    if p^.op = SQLITE_INDEX_CONSTRAINT_EQ then begin
      if i32(p^.iColumn) = colSchema then begin
        if p^.usable = 0 then begin
          Result := SQLITE_CONSTRAINT;
          Exit;
        end;
        iSchema := i;
      end;
      if (p^.iColumn = DBDATA_COLUMN_PGNO) and (p^.usable <> 0) then
        iPgno := i;
    end;
  end;

  if iSchema >= 0 then begin
    pIdx^.aConstraintUsage[iSchema].argvIndex := 1;
    pIdx^.aConstraintUsage[iSchema].omit := 1;
  end;
  if iPgno >= 0 then begin
    if iSchema >= 0 then
      pIdx^.aConstraintUsage[iPgno].argvIndex := 2
    else
      pIdx^.aConstraintUsage[iPgno].argvIndex := 1;
    pIdx^.aConstraintUsage[iPgno].omit := 1;
    pIdx^.estimatedCost := 100;
    pIdx^.estimatedRows := 50;

    if (pTab^.bPtr = 0) and (pIdx^.nOrderBy <> 0)
       and (pIdx^.aOrderBy[0].desc = 0) then
    begin
      iCol := pIdx^.aOrderBy[0].iColumn;
      if pIdx^.nOrderBy = 1 then begin
        if (iCol = 0) or (iCol = 1) then
          pIdx^.orderByConsumed := 1
        else
          pIdx^.orderByConsumed := 0;
      end else if (pIdx^.nOrderBy = 2)
              and (pIdx^.aOrderBy[1].desc = 0) and (iCol = 0) then
      begin
        if pIdx^.aOrderBy[1].iColumn = 1 then
          pIdx^.orderByConsumed := 1
        else
          pIdx^.orderByConsumed := 0;
      end;
    end;
  end else begin
    pIdx^.estimatedCost := 100000000;
    pIdx^.estimatedRows := 1000000000;
  end;
  pIdx^.idxNum := 0;
  if iSchema >= 0 then pIdx^.idxNum := pIdx^.idxNum or $01;
  if iPgno   >= 0 then pIdx^.idxNum := pIdx^.idxNum or $02;
  Result := SQLITE_OK;
end;

{ dbdata.c:294..307 — dbdataOpen. }
function dbdataOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCsr: PDbdataCursor;
begin
  pCsr := PDbdataCursor(sqlite3_malloc64(SizeOf(TDbdataCursor)));
  if pCsr = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCsr^, SizeOf(TDbdataCursor), 0);
  pCsr^.base.pVtab := pVTab;
  ppCursor^ := PSqlite3VtabCursor(@pCsr^.base);
  Result := SQLITE_OK;
end;

{ dbdata.c:313..329 — dbdataResetCursor. }
procedure dbdataResetCursor(pCsr: PDbdataCursor);
var pTab: PDbdataTable;
begin
  pTab := PDbdataTable(pCsr^.base.pVtab);
  if pTab^.pStmt = nil then
    pTab^.pStmt := pCsr^.pStmt
  else
    sqlite3_finalize(pCsr^.pStmt);
  pCsr^.pStmt := nil;
  pCsr^.iPgno := 1;
  pCsr^.iCell := 0;
  pCsr^.iField := 0;
  pCsr^.bOnePage := 0;
  sqlite3_free(pCsr^.aPage);
  dbdataBufferFree(@pCsr^.rec);
  pCsr^.aPage := nil;
  pCsr^.nRec := 0;
end;

{ dbdata.c:334..339 — dbdataClose. }
function dbdataClose(pCursor: PSqlite3VtabCursor): i32; cdecl;
var pCsr: PDbdataCursor;
begin
  pCsr := PDbdataCursor(pCursor);
  dbdataResetCursor(pCsr);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ dbdata.c:555..765 — dbdataNext.  The heart of the module: walks pages,
  cells and fields. }
function dbdataNext(pCursor: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr     : PDbdataCursor;
  pTab     : PDbdataTable;
  rc       : i32;
  iOff     : i32;
  bNextPage: Boolean;
  bHasRowid: i32;
  nPointer : i32;
  nPayload : i64;
  nHdr     : i64;
  iHdr     : i32;
  U, X, M, K, nLocal : i32;
  iCellPtr : i32;
  nRem     : i64;
  pgnoOvfl : u32;
  aOvfl    : Pointer;
  nOvfl    : i32;
  nCopy    : i32;
  iType    : i64;
  szField  : i32;
  mxCell   : i32;
begin
  pCsr := PDbdataCursor(pCursor);
  pTab := PDbdataTable(pCursor^.pVtab);

  Inc(pCsr^.iRowid);
  while True do begin
    if pCsr^.iPgno = 1 then iOff := 100 else iOff := 0;
    bNextPage := False;

    if pCsr^.aPage = nil then begin
      while True do begin
        if (pCsr^.bOnePage = 0) and (pCsr^.iPgno > pCsr^.szDb) then begin
          Result := SQLITE_OK;
          Exit;
        end;
        rc := dbdataLoadPage(pCsr, u32(pCsr^.iPgno),
                             PPointer(@pCsr^.aPage), @pCsr^.nPage);
        if rc <> SQLITE_OK then begin Result := rc; Exit; end;
        if (pCsr^.aPage <> nil) and (pCsr^.nPage >= 256) then Break;
        sqlite3_free(pCsr^.aPage);
        pCsr^.aPage := nil;
        if pCsr^.bOnePage <> 0 then begin Result := SQLITE_OK; Exit; end;
        Inc(pCsr^.iPgno);
      end;

      if pTab^.bPtr <> 0 then pCsr^.iCell := -2 else pCsr^.iCell := 0;
      pCsr^.nCell := i32(getUint16(pCsr^.aPage + iOff + 3));
      mxCell := (pCsr^.nPage - 8) div 6;
      if pCsr^.nCell > mxCell then pCsr^.nCell := mxCell;
    end;

    if pTab^.bPtr <> 0 then begin
      if (pCsr^.aPage[iOff] <> $02) and (pCsr^.aPage[iOff] <> $05) then
        pCsr^.iCell := pCsr^.nCell;
      Inc(pCsr^.iCell);
      if pCsr^.iCell >= pCsr^.nCell then begin
        sqlite3_free(pCsr^.aPage);
        pCsr^.aPage := nil;
        if pCsr^.bOnePage <> 0 then begin Result := SQLITE_OK; Exit; end;
        Inc(pCsr^.iPgno);
      end else begin
        Result := SQLITE_OK;
        Exit;
      end;
    end else begin
      { sqlite_dbdata path. }
      if pCsr^.nRec = 0 then begin
        bHasRowid := 0;
        nPointer  := 0;
        nPayload  := 0;
        nHdr      := 0;

        case pCsr^.aPage[iOff] of
          $02: nPointer := 4;
          $0a: { interior index page — header only };
          $0d: bHasRowid := 1;
        else
          { Not a record-bearing b-tree page. }
          pCsr^.iCell := pCsr^.nCell;
        end;

        if pCsr^.iCell >= pCsr^.nCell then
          bNextPage := True
        else begin
          iCellPtr := iOff + 8 + nPointer + pCsr^.iCell * 2;

          if iCellPtr > pCsr^.nPage then
            bNextPage := True
          else
            iOff := i32(getUint16(pCsr^.aPage + iCellPtr));

          { Skip past child-page number on interior cells. }
          Inc(iOff, nPointer);

          { Load the "byte of payload including overflow" field. }
          if bNextPage or (iOff > pCsr^.nPage) or (iOff <= iCellPtr) then
            bNextPage := True
          else begin
            Inc(iOff, dbdataGetVarintU32(pCsr^.aPage + iOff, @nPayload));
            if nPayload > $7fffff00 then nPayload := nPayload and $3fff;
            if nPayload = 0 then nPayload := 1;
          end;

          { If this is a leaf intkey cell, load the rowid. }
          if (bHasRowid <> 0) and (not bNextPage) and (iOff < pCsr^.nPage) then
            Inc(iOff, dbdataGetVarint(pCsr^.aPage + iOff, @pCsr^.iIntkey));

          { Figure out how many bytes are stored locally vs. in overflow. }
          U := pCsr^.nPage;
          if bHasRowid <> 0 then
            X := U - 35
          else
            X := ((U - 12) * 64 div 255) - 23;

          if nPayload <= X then
            nLocal := i32(nPayload)
          else begin
            M := ((U - 12) * 32 div 255) - 23;
            K := M + i32((nPayload - M) mod (U - 4));
            if K <= X then nLocal := K else nLocal := M;
          end;

          if bNextPage or (nLocal + iOff > pCsr^.nPage) then
            bNextPage := True
          else begin
            { Allocate (with PADDING) and copy the local portion. }
            rc := dbdataBufferSize(@pCsr^.rec,
                                   nPayload + DBDATA_PADDING_BYTES);
            if rc <> SQLITE_OK then begin Result := rc; Exit; end;

            Move((pCsr^.aPage + iOff)^, pCsr^.rec.aBuf^, nLocal);
            Inc(iOff, nLocal);

            { Pull overflow page chain. }
            if nPayload > nLocal then begin
              nRem := nPayload - nLocal;
              pgnoOvfl := getUint32(pCsr^.aPage + iOff);
              while nRem > 0 do begin
                aOvfl := nil;
                nOvfl := 0;
                rc := dbdataLoadPage(pCsr, pgnoOvfl, @aOvfl, @nOvfl);
                if rc <> SQLITE_OK then begin Result := rc; Exit; end;
                if aOvfl = nil then Break;

                nCopy := U - 4;
                if nCopy > nRem then nCopy := i32(nRem);
                Move((Pu8(aOvfl) + 4)^,
                     (pCsr^.rec.aBuf + (nPayload - nRem))^, nCopy);
                Dec(nRem, nCopy);

                pgnoOvfl := getUint32(Pu8(aOvfl));
                sqlite3_free(aOvfl);
              end;
              Dec(nPayload, nRem);
            end;
            FillChar((pCsr^.rec.aBuf + nPayload)^,
                     DBDATA_PADDING_BYTES, 0);
            pCsr^.nRec := nPayload;

            iHdr := dbdataGetVarintU32(pCsr^.rec.aBuf, @nHdr);
            if nHdr > nPayload then nHdr := 0;
            pCsr^.nHdr := nHdr;
            pCsr^.pHdrPtr := pCsr^.rec.aBuf + iHdr;
            pCsr^.pPtr    := pCsr^.rec.aBuf + pCsr^.nHdr;
            if bHasRowid <> 0 then pCsr^.iField := -1 else pCsr^.iField := 0;
          end;
        end;
      end else begin
        Inc(pCsr^.iField);
        if pCsr^.iField > 0 then begin
          if (pCsr^.pHdrPtr >= pCsr^.rec.aBuf + pCsr^.nRec)
             or (pCsr^.iField >= DBDATA_MX_FIELD) then
            bNextPage := True
          else begin
            szField := 0;
            Inc(pCsr^.pHdrPtr,
                dbdataGetVarintU32(pCsr^.pHdrPtr, @iType));
            szField := dbdataValueBytes(i32(iType));
            if (pCsr^.nRec - (pCsr^.pPtr - pCsr^.rec.aBuf)) < szField then
              pCsr^.pPtr := pCsr^.rec.aBuf + pCsr^.nRec
            else
              Inc(pCsr^.pPtr, szField);
          end;
        end;
      end;

      if bNextPage then begin
        sqlite3_free(pCsr^.aPage);
        pCsr^.aPage := nil;
        pCsr^.nRec  := 0;
        if pCsr^.bOnePage <> 0 then begin Result := SQLITE_OK; Exit; end;
        Inc(pCsr^.iPgno);
      end else begin
        if (pCsr^.iField < 0)
           or (pCsr^.pHdrPtr < pCsr^.rec.aBuf + pCsr^.nHdr) then
        begin
          Result := SQLITE_OK;
          Exit;
        end;

        { Advance to next cell; loop will pull a fresh record. }
        pCsr^.nRec := 0;
        Inc(pCsr^.iCell);
      end;
    end;
  end;
end;

{ dbdata.c:770..773 — dbdataEof. }
function dbdataEof(pCursor: PSqlite3VtabCursor): i32; cdecl;
var pCsr: PDbdataCursor;
begin
  pCsr := PDbdataCursor(pCursor);
  if pCsr^.aPage = nil then Result := 1 else Result := 0;
end;

{ dbdata.c:793..815 — dbdataDbsize.  Resolve schema page count. }
function dbdataDbsize(pCsr: PDbdataCursor; zSchema: PAnsiChar): i32;
var
  pTab : PDbdataTable;
  zSql : PAnsiChar;
  rc, rc2: i32;
  nFunc: i32;
  pStmt: Pointer;
begin
  pTab := PDbdataTable(pCsr^.base.pVtab);
  pStmt := nil;
  nFunc := dbdataIsFunction(zSchema);

  if nFunc > 0 then
    zSql := sqlite3PfMprintf('SELECT %.*s(0)', [nFunc, zSchema])
  else
    { Upstream uses `PRAGMA %Q.page_count`.  In pas-sqlite3 that PRAGMA
      currently returns no rows — same gap noted in passqlite3shell.pas
      cmdDbtotxt.  Fall back to counting sqlite_dbpage rows for the
      target schema. }
    zSql := sqlite3PfMprintf(
      'SELECT count(*) FROM sqlite_dbpage(%Q)', [zSchema]);
  if zSql = nil then begin Result := SQLITE_NOMEM; Exit; end;

  rc := sqlite3_prepare_v2(pTab^.db, zSql, -1, @pStmt, nil);
  sqlite3_free(zSql);
  if (rc = SQLITE_OK) and (sqlite3_step(pStmt) = SQLITE_ROW) then
    pCsr^.szDb := sqlite3_column_int(pStmt, 0);
  rc2 := sqlite3_finalize(pStmt);
  if rc = SQLITE_OK then rc := rc2;
  Result := rc;
end;

{ dbdata.c:822..832 — dbdataGetEncoding. }
function dbdataGetEncoding(pCsr: PDbdataCursor): i32;
var
  rc   : i32;
  nPg1 : i32;
  aPg1 : Pu8;
begin
  aPg1 := nil;
  nPg1 := 0;
  rc := dbdataLoadPage(pCsr, 1, PPointer(@aPg1), @nPg1);
  if (rc = SQLITE_OK) and (nPg1 >= 56 + 4) then
    pCsr^.enc := getUint32(aPg1 + 56);
  sqlite3_free(aPg1);
  Result := rc;
end;

{ dbdata.c:838..901 — dbdataFilter. }
function dbdataFilter(pCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCsr   : PDbdataCursor;
  pTab   : PDbdataTable;
  rc     : i32;
  zSchema: PAnsiChar;
  nFunc  : i32;
  zSql   : PAnsiChar;
  pArgs  : PPsqlite3_value;
  pA0, pA1: Psqlite3_value;
begin
  pCsr := PDbdataCursor(pCursor);
  pTab := PDbdataTable(pCursor^.pVtab);
  rc := SQLITE_OK;
  zSchema := PAnsiChar('main');

  pArgs := argv;
  pA0 := nil; pA1 := nil;
  if argc >= 1 then pA0 := pArgs[0];
  if argc >= 2 then pA1 := pArgs[1];

  dbdataResetCursor(pCsr);
  if (idxNum and $01) <> 0 then begin
    zSchema := PAnsiChar(sqlite3_value_text(pA0));
    if zSchema = nil then zSchema := PAnsiChar('');
  end;
  if (idxNum and $02) <> 0 then begin
    if (idxNum and $01) <> 0 then
      pCsr^.iPgno := sqlite3_value_int(pA1)
    else
      pCsr^.iPgno := sqlite3_value_int(pA0);
    pCsr^.bOnePage := 1;
  end else begin
    rc := dbdataDbsize(pCsr, zSchema);
  end;

  if rc = SQLITE_OK then begin
    nFunc := 0;
    if pTab^.pStmt <> nil then begin
      pCsr^.pStmt := pTab^.pStmt;
      pTab^.pStmt := nil;
    end else begin
      nFunc := dbdataIsFunction(zSchema);
      if nFunc > 0 then begin
        zSql := sqlite3PfMprintf('SELECT %.*s(?2)', [nFunc, zSchema]);
        if zSql = nil then
          rc := SQLITE_NOMEM
        else begin
          rc := sqlite3_prepare_v2(pTab^.db, zSql, -1, @pCsr^.pStmt, nil);
          sqlite3_free(zSql);
        end;
      end else begin
        rc := sqlite3_prepare_v2(pTab^.db,
          'SELECT data FROM sqlite_dbpage(?) WHERE pgno=?', -1,
          @pCsr^.pStmt, nil);
      end;
    end;
  end;
  if rc = SQLITE_OK then
    rc := sqlite3_bind_text(pCsr^.pStmt, 1, zSchema, -1, SQLITE_TRANSIENT);

  if rc = SQLITE_OK then
    rc := dbdataGetEncoding(pCsr);

  if rc <> SQLITE_OK then
    pTab^.base.zErrMsg := sqlite3PfMprintf('%s',
      [sqlite3_errmsg(pTab^.db)]);

  if rc = SQLITE_OK then
    rc := dbdataNext(pCursor);
  Result := rc;
end;

{ dbdata.c:906..960 — dbdataColumn. }
function dbdataColumn(pCursor: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCsr  : PDbdataCursor;
  pTab  : PDbdataTable;
  iOff  : i32;
  iType : i64;
begin
  pCsr := PDbdataCursor(pCursor);
  pTab := PDbdataTable(pCursor^.pVtab);
  if pTab^.bPtr <> 0 then begin
    case i of
      DBPTR_COLUMN_PGNO: sqlite3_result_int64(ctx, pCsr^.iPgno);
      DBPTR_COLUMN_CHILD:
        begin
          if pCsr^.iPgno = 1 then iOff := 100 else iOff := 0;
          if pCsr^.iCell < 0 then
            Inc(iOff, 8)
          else begin
            Inc(iOff, 12 + pCsr^.iCell * 2);
            if iOff > pCsr^.nPage then begin Result := SQLITE_OK; Exit; end;
            iOff := i32(getUint16(pCsr^.aPage + iOff));
          end;
          if iOff <= pCsr^.nPage then
            sqlite3_result_int64(ctx, i64(getUint32(pCsr^.aPage + iOff)));
        end;
    end;
  end else begin
    case i of
      DBDATA_COLUMN_PGNO:  sqlite3_result_int64(ctx, pCsr^.iPgno);
      DBDATA_COLUMN_CELL:  sqlite3_result_int(ctx, pCsr^.iCell);
      DBDATA_COLUMN_FIELD: sqlite3_result_int(ctx, pCsr^.iField);
      DBDATA_COLUMN_VALUE:
        begin
          if pCsr^.iField < 0 then
            sqlite3_result_int64(ctx, pCsr^.iIntkey)
          else if (pCsr^.rec.aBuf + pCsr^.nRec) >= pCsr^.pPtr then begin
            dbdataGetVarintU32(pCsr^.pHdrPtr, @iType);
            dbdataValue(ctx, pCsr^.enc, i32(iType), pCsr^.pPtr,
              (pCsr^.rec.aBuf + pCsr^.nRec) - pCsr^.pPtr);
          end;
        end;
    end;
  end;
  Result := SQLITE_OK;
end;

{ dbdata.c:965..969 — dbdataRowid. }
function dbdataRowid(pCursor: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCsr: PDbdataCursor;
begin
  pCsr := PDbdataCursor(pCursor);
  pRowid^ := pCsr^.iRowid;
  Result := SQLITE_OK;
end;

{ dbdata.c:975..1009 — sqlite3DbdataRegister.  Registers the same module
  twice — once as sqlite_dbdata (pAux=nil) and once as sqlite_dbptr
  (pAux=Pointer(1)).  bPtr is derived from pAux at xConnect. }
function sqlite3DbdataRegister(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_module(db, 'sqlite_dbdata', @dbdataModule, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_module(db, 'sqlite_dbptr',
                                @dbdataModule, Pointer(1));
  Result := rc;
end;

initialization
  FillChar(dbdataModule, SizeOf(dbdataModule), 0);
  dbdataModule.iVersion    := 0;
  { xCreate intentionally nil — eponymous-only. }
  dbdataModule.xConnect    := @dbdataConnect;
  dbdataModule.xBestIndex  := @dbdataBestIndex;
  dbdataModule.xDisconnect := @dbdataDisconnect;
  dbdataModule.xOpen       := @dbdataOpen;
  dbdataModule.xClose      := @dbdataClose;
  dbdataModule.xFilter     := @dbdataFilter;
  dbdataModule.xNext       := @dbdataNext;
  dbdataModule.xEof        := @dbdataEof;
  dbdataModule.xColumn     := @dbdataColumn;
  dbdataModule.xRowid      := @dbdataRowid;
end.
