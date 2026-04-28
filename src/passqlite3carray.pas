{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  This is a faithful port of SQLite 3.53 (https://sqlite.org/) from C to
  Free Pascal, authored by Dr. Joao Paulo Schwarz Schuler and contributors
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
{$I passqlite3.inc}
unit passqlite3carray;

{
  Phase 6.bis.2b — port of ../sqlite3/src/carray.c (the carray() table-
  valued virtual table; 558 lines in C).

  Faithful port: the in-tree carray vtab exposes a 4-column table

      CREATE TABLE x(value, pointer HIDDEN, count HIDDEN, ctype HIDDEN);

  with five static module callbacks (xConnect/xDisconnect/xOpen/xClose/
  xNext/xEof/xColumn/xRowid/xFilter/xBestIndex) and a static
  Tsqlite3_module record `carrayModule`.  `sqlite3CarrayRegister(db)` is
  the public entry point and returns a PVtabModule, mirroring the C
  signature in carray.c:554.

  Dependencies that are NOT yet ported (carry-over from 6.bis.2a):
    * sqlite3_value_pointer / sqlite3_bind_pointer — the type-tagged
      pointer machinery used by carray's xFilter (case 1 = bind path)
      and by sqlite3_carray_bind_v2.  Until that lands, xFilter's
      idxNum=1 branch yields an empty result set (sqlite3_value_pointer
      stub returns nil); the 2/3 branches still work end-to-end.
    * sqlite3_mprintf — used once on the unknown-datatype error path
      in xFilter (idxNum=3).  Bridged here through the same vtabFmtMsg
      shim pattern used by passqlite3vtab in 6.bis.1c.

  Gate: src/tests/TestCarray.pas exercises module registration,
  xBestIndex constraint dispatch (idxNum 0/1/2/3), xOpen/xClose +
  manual cursor walk via xColumn/xNext/xEof/xRowid for INT32, INT64,
  DOUBLE and TEXT element types.
}

interface

uses
  SysUtils,
  Strings,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab;

const
  { sqlite.h:11329..11343 — public element-type tags (legacy + SQLITE_-
    prefixed forms; values are identical). }
  CARRAY_INT32  = 0;
  CARRAY_INT64  = 1;
  CARRAY_DOUBLE = 2;
  CARRAY_TEXT   = 3;
  CARRAY_BLOB   = 4;

  SQLITE_CARRAY_INT32  = CARRAY_INT32;
  SQLITE_CARRAY_INT64  = CARRAY_INT64;
  SQLITE_CARRAY_DOUBLE = CARRAY_DOUBLE;
  SQLITE_CARRAY_TEXT   = CARRAY_TEXT;
  SQLITE_CARRAY_BLOB   = CARRAY_BLOB;

  { carray column ordinals — carray.c:123..126 }
  CARRAY_COLUMN_VALUE   = 0;
  CARRAY_COLUMN_POINTER = 1;
  CARRAY_COLUMN_COUNT   = 2;
  CARRAY_COLUMN_CTYPE   = 3;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { struct iovec (sys/uio.h) — carray.c:58..61 fallback definition.
    Used when the array element type is CARRAY_BLOB. }
  PIoVec = ^TIoVec;
  TIoVec = record
    iov_base : Pointer;
    iov_len  : SizeUInt;
  end;

  { carray.c:77 — `sqlite3_carray_bind()` per-bind state. }
  PCarrayBind = ^TCarrayBind;
  TCarrayBind = record
    aData  : Pointer;
    nData  : i32;
    mFlags : i32;
    xDel   : TxDelProc;
    pDel   : Pointer;
  end;

  { carray.c:91 — cursor that scans the array.  First field MUST be
    the public sqlite3_vtab_cursor base for pointer-cast compat. }
  PCarrayCursor = ^TCarrayCursor;
  TCarrayCursor = record
    base   : Tsqlite3_vtab_cursor;
    iRowid : i64;
    pPtr   : Pointer;
    iCnt   : i64;
    eType  : u8;
    _pad   : array[0..6] of u8;
  end;

{ Module entry point — vtab.c:554.  Installs the module on db under the
  name "carray" and returns the registry slot. }
function sqlite3CarrayRegister(db: PTsqlite3): PVtabModule;

{ Public Tsqlite3_module record (carrayModule, carray.c:381).  Exposed
  so gate tests can read its slot pointers without going through the
  registry. }
var
  carrayModule: Tsqlite3_module;

implementation

{ ============================================================
  Datatype-name table — carray.c:69
  ============================================================ }
const
  azCarrayType: array[0..4] of PAnsiChar = (
    'int32', 'int64', 'double', 'char*', 'struct iovec'
  );

{ ============================================================
  Static module callbacks
  ============================================================ }

{ carray.c:112 — xConnect: declare the 4-column schema and allocate the
  vtab object. }
function carrayConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PSqlite3Vtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE x(value,pointer hidden,count hidden,ctype hidden)');
  if rc = SQLITE_OK then begin
    pNew := PSqlite3Vtab(sqlite3Malloc(SizeOf(Tsqlite3_vtab)));
    ppVtab^ := pNew;
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(Tsqlite3_vtab), 0);
  end;
  Result := rc;
end;

{ carray.c:141 — xDisconnect. }
function carrayDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ carray.c:149 — xOpen. }
function carrayOpen(p: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pCur: PCarrayCursor;
begin
  pCur := PCarrayCursor(sqlite3Malloc(SizeOf(TCarrayCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TCarrayCursor), 0);
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ carray.c:161 — xClose. }
function carrayClose(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ carray.c:170 — xNext. }
function carrayNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PCarrayCursor;
begin
  pCur := PCarrayCursor(cur);
  Inc(pCur^.iRowid);
  Result := SQLITE_OK;
end;

{ carray.c:180 — xColumn. }
function carrayColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: i32): i32; cdecl;
var
  pCur:  PCarrayCursor;
  x:     i64;
  pI32:  ^i32;
  pI64:  ^i64;
  pDbl:  ^Double;
  pTxt:  ^PAnsiChar;
  pBlob: PIoVec;
  idx:   i64;
begin
  pCur := PCarrayCursor(cur);
  x    := 0;
  case i of
    CARRAY_COLUMN_POINTER: begin Result := SQLITE_OK; Exit; end;
    CARRAY_COLUMN_COUNT:   x := pCur^.iCnt;
    CARRAY_COLUMN_CTYPE: begin
      sqlite3_result_text(ctx, azCarrayType[pCur^.eType], -1, SQLITE_STATIC);
      Result := SQLITE_OK; Exit;
    end;
  else
    idx := pCur^.iRowid - 1;
    case pCur^.eType of
      CARRAY_INT32: begin
        pI32 := pCur^.pPtr;
        sqlite3_result_int(ctx, (pI32 + idx)^);
        Result := SQLITE_OK; Exit;
      end;
      CARRAY_INT64: begin
        pI64 := pCur^.pPtr;
        sqlite3_result_int64(ctx, (pI64 + idx)^);
        Result := SQLITE_OK; Exit;
      end;
      CARRAY_DOUBLE: begin
        pDbl := pCur^.pPtr;
        sqlite3_result_double(ctx, (pDbl + idx)^);
        Result := SQLITE_OK; Exit;
      end;
      CARRAY_TEXT: begin
        pTxt := pCur^.pPtr;
        sqlite3_result_text(ctx, (pTxt + idx)^, -1, SQLITE_TRANSIENT);
        Result := SQLITE_OK; Exit;
      end;
    else
      Assert(pCur^.eType = CARRAY_BLOB,
        'carrayColumn: unexpected eType');
      pBlob := PIoVec(pCur^.pPtr);
      sqlite3_result_blob(ctx, pBlob[idx].iov_base,
        i32(pBlob[idx].iov_len), SQLITE_TRANSIENT);
      Result := SQLITE_OK; Exit;
    end;
  end;
  sqlite3_result_int64(ctx, x);
  Result := SQLITE_OK;
end;

{ carray.c:234 — xRowid. }
function carrayRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var
  pCur: PCarrayCursor;
begin
  pCur := PCarrayCursor(cur);
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

{ carray.c:244 — xEof. }
function carrayEof(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PCarrayCursor;
begin
  pCur := PCarrayCursor(cur);
  if pCur^.iRowid > pCur^.iCnt then Result := 1 else Result := 0;
end;

{ Forward stub for sqlite3_value_pointer — not yet ported (recurring
  blocker tracked in 6.bis.2a notes).  Returns nil so xFilter's bind
  branch and 2/3-arg pointer extraction degrade to "empty table"
  rather than crash. }
function sqlite3_value_pointer_stub(pVal: Psqlite3_value;
  zType: PAnsiChar): Pointer;
begin
  Result := nil;
end;

{ Phase 6.bis follow-up (2026-04-26): unknown-datatype error path now
  delegates to the shared sqlite3VtabFmtMsg1Libc helper in passqlite3vtab. }

{ carray.c:253 — xFilter. }
function carrayFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur:    PCarrayCursor;
  pBind:   PCarrayBind;
  i:       u8;
  zType:   PAnsiChar;
  found:   Boolean;
begin
  pCur := PCarrayCursor(cur);
  pCur^.pPtr := nil;
  pCur^.iCnt := 0;
  case idxNum of
    1: begin
      pBind := PCarrayBind(sqlite3_value_pointer_stub(argv[0], 'carray-bind'));
      if pBind <> nil then begin
        pCur^.pPtr  := pBind^.aData;
        pCur^.iCnt  := pBind^.nData;
        pCur^.eType := pBind^.mFlags and $07;
      end;
    end;
    2, 3: begin
      pCur^.pPtr := sqlite3_value_pointer_stub(argv[0], 'carray');
      if pCur^.pPtr <> nil then
        pCur^.iCnt := sqlite3_value_int64(argv[1])
      else
        pCur^.iCnt := 0;
      if idxNum < 3 then
        pCur^.eType := CARRAY_INT32
      else begin
        zType := PAnsiChar(sqlite3_value_text(argv[2]));
        found := False;
        i := 0;
        while i < Length(azCarrayType) do begin
          if sqlite3StrICmp(zType, azCarrayType[i]) = 0 then begin
            found := True; Break;
          end;
          Inc(i);
        end;
        if not found then begin
          { vtab.c:283 — pVtab^.zErrMsg uses sqlite3_mprintf; we mirror
            with a libc-allocated buffer so sqlite3_free clears it. }
          cur^.pVtab^.zErrMsg := sqlite3VtabFmtMsg1Libc('unknown datatype: %s',
            AnsiString(zType));
          Result := SQLITE_ERROR; Exit;
        end;
        pCur^.eType := i;
      end;
    end;
  end;
  pCur^.iRowid := 1;
  Result := SQLITE_OK;
end;

{ carray.c:317 — xBestIndex.

  idxNum encoding:
    1  pointer= bound only          (use sqlite3_carray_bind path)
    2  pointer= and count= bound
    3  pointer=, count= and ctype= bound
    0  no usable constraints        (empty table) }
function carrayBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i:        i32;
  ptrIdx, cntIdx, ctypeIdx: i32;
  seen:     u32;
  pC:       PSqlite3IndexConstraint;
  pUse:     PSqlite3IndexConstraintUsage;
begin
  ptrIdx   := -1;
  cntIdx   := -1;
  ctypeIdx := -1;
  seen     := 0;

  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if pC^.op = SQLITE_INDEX_CONSTRAINT_EQ then begin
      if pC^.iColumn >= 0 then
        seen := seen or (u32(1) shl pC^.iColumn);
      if pC^.usable <> 0 then begin
        case pC^.iColumn of
          CARRAY_COLUMN_POINTER: ptrIdx   := i;
          CARRAY_COLUMN_COUNT:   cntIdx   := i;
          CARRAY_COLUMN_CTYPE:   ctypeIdx := i;
        end;
      end;
    end;
    Inc(pC);
  end;

  if ptrIdx >= 0 then begin
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, ptrIdx);
    pUse^.argvIndex := 1;
    pUse^.omit      := 1;
    pIdxInfo^.estimatedCost := 1.0;
    pIdxInfo^.estimatedRows := 100;
    pIdxInfo^.idxNum        := 1;
    if cntIdx >= 0 then begin
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, cntIdx);
      pUse^.argvIndex := 2;
      pUse^.omit      := 1;
      pIdxInfo^.idxNum := 2;
      if ctypeIdx >= 0 then begin
        pUse := pIdxInfo^.aConstraintUsage;
        Inc(pUse, ctypeIdx);
        pUse^.argvIndex := 3;
        pUse^.omit      := 1;
        pIdxInfo^.idxNum := 3;
      end else if (seen and (u32(1) shl CARRAY_COLUMN_CTYPE)) <> 0 then begin
        Result := SQLITE_CONSTRAINT; Exit;
      end;
    end else if (seen and (u32(1) shl CARRAY_COLUMN_COUNT)) <> 0 then begin
      Result := SQLITE_CONSTRAINT; Exit;
    end;
  end else begin
    pIdxInfo^.estimatedCost := 2147483647.0;
    pIdxInfo^.estimatedRows := 2147483647;
    pIdxInfo^.idxNum        := 0;
  end;
  Result := SQLITE_OK;
end;

{ ============================================================
  Module registration
  ============================================================ }

function sqlite3CarrayRegister(db: PTsqlite3): PVtabModule;
begin
  Result := sqlite3VtabCreateModule(db, 'carray', @carrayModule, nil, nil);
end;

initialization
  FillChar(carrayModule, SizeOf(carrayModule), 0);
  carrayModule.iVersion    := 0;
  carrayModule.xCreate     := nil;
  carrayModule.xConnect    := @carrayConnect;
  carrayModule.xBestIndex  := @carrayBestIndex;
  carrayModule.xDisconnect := @carrayDisconnect;
  carrayModule.xDestroy    := nil;
  carrayModule.xOpen       := @carrayOpen;
  carrayModule.xClose      := @carrayClose;
  carrayModule.xFilter     := @carrayFilter;
  carrayModule.xNext       := @carrayNext;
  carrayModule.xEof        := @carrayEof;
  carrayModule.xColumn     := @carrayColumn;
  carrayModule.xRowid      := @carrayRowid;
end.
