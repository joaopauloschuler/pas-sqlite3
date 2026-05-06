{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/wholenumber.c (280 lines in C).

  Eponymous virtual table that yields the whole numbers 1..4294967295:

      CREATE VIRTUAL TABLE nums USING wholenumber;
      SELECT value FROM nums WHERE value<10;  -- 1..9

  xBestIndex understands GT/GE/LT/LE constraints on the single column
  "value" and encodes them in idxNum.  xFilter applies them to the
  cursor's [iValue..mxValue] window.  An ascending ORDER BY value is
  consumed.  No xUpdate / xBegin / xSync — read-only and stateless.

  Runtime caveat: the Pascal port does not yet wire vtab xBestIndex
  pushdown for arbitrary WHERE clauses (codegen TODO at
  passqlite3codegen.pas:13938 and 28163).  Without pushdown a bare
  SELECT walks all 2^32-1 rows.  Once that path lands, this module
  becomes practically usable; the C implementation here is faithful
  end-to-end.

  Public entry: sqlite3WholenumberInit(db) — equivalent to
  sqlite3_wholenumber_init() in C.
}
{$I passqlite3.inc}
unit passqlite3wholenumber;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3WholenumberInit(db: PTsqlite3): i32;

implementation

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { wholenumber.c:34..39 — wholenumber_cursor.  First field MUST be
    Tsqlite3_vtab_cursor. }
  PWholenumberCursor = ^TWholenumberCursor;
  TWholenumberCursor = record
    base    : Tsqlite3_vtab_cursor;
    iValue  : i64;
    mxValue : i64;
  end;

var
  wholenumberModule: Tsqlite3_module;

{ wholenumber.c:42..56 — xConnect (also xCreate). }
function wholenumberConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PSqlite3Vtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db, 'CREATE TABLE x(value)');
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  pNew := PSqlite3Vtab(sqlite3Malloc(SizeOf(Tsqlite3_vtab)));
  ppVtab^ := pNew;
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pNew^, SizeOf(Tsqlite3_vtab), 0);
  sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS, 0);
  Result := SQLITE_OK;
end;

{ wholenumber.c:60..63 — xDisconnect (also xDestroy). }
function wholenumberDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ wholenumber.c:70..77 — xOpen. }
function wholenumberOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PWholenumberCursor;
begin
  pCur := PWholenumberCursor(sqlite3Malloc(SizeOf(TWholenumberCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TWholenumberCursor), 0);
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ wholenumber.c:82..85 — xClose. }
function wholenumberClose(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ wholenumber.c:91..95 — xNext. }
function wholenumberNext(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PWholenumberCursor;
begin
  pCur := PWholenumberCursor(cur);
  Inc(pCur^.iValue);
  Result := SQLITE_OK;
end;

{ wholenumber.c:100..108 — xColumn. }
function wholenumberColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var pCur: PWholenumberCursor;
begin
  pCur := PWholenumberCursor(cur);
  sqlite3_result_int64(ctx, pCur^.iValue);
  Result := SQLITE_OK;
end;

{ wholenumber.c:113..117 — xRowid. }
function wholenumberRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PWholenumberCursor;
begin
  pCur := PWholenumberCursor(cur);
  pRowid^ := pCur^.iValue;
  Result := SQLITE_OK;
end;

{ wholenumber.c:123..126 — xEof. }
function wholenumberEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PWholenumberCursor;
begin
  pCur := PWholenumberCursor(cur);
  if (pCur^.iValue > pCur^.mxValue) or (pCur^.iValue = 0) then
    Result := 1
  else
    Result := 0;
end;

{ wholenumber.c:146..166 — xFilter.

  idxNum bits:
       1   value > argv0
       2   value >= argv0
       4   value < argv0 (or argv1 if low end is also constrained)
       8   value <= argv0 (or argv1 if low end is also constrained)
}
function wholenumberFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PWholenumberCursor;
  v:    i64;
  i:    i32;
begin
  pCur := PWholenumberCursor(cur);
  i := 0;
  pCur^.iValue  := 1;
  pCur^.mxValue := i64($FFFFFFFF);   { 4294967295 }
  if (idxNum and 3) <> 0 then begin
    v := sqlite3_value_int64(argv[0]) + (idxNum and 1);
    if (v > pCur^.iValue) and (v <= pCur^.mxValue) then pCur^.iValue := v;
    Inc(i);
  end;
  if (idxNum and 12) <> 0 then begin
    v := sqlite3_value_int64(argv[i]) - ((idxNum shr 2) and 1);
    if (v >= pCur^.iValue) and (v < pCur^.mxValue) then pCur^.mxValue := v;
  end;
  Result := SQLITE_OK;
end;

{ wholenumber.c:178..230 — xBestIndex. }
function wholenumberBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i:        i32;
  idxNum:   i32;
  argvIdx:  i32;
  ltIdx:    i32;
  gtIdx:    i32;
  pC:       PSqlite3IndexConstraint;
  pUse:     PSqlite3IndexConstraintUsage;
  pOrder:   PSqlite3IndexOrderBy;
begin
  idxNum  := 0;
  argvIdx := 1;
  ltIdx   := -1;
  gtIdx   := -1;

  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if pC^.usable <> 0 then begin
      if ((idxNum and 3) = 0) and (pC^.op = SQLITE_INDEX_CONSTRAINT_GT) then begin
        idxNum := idxNum or 1;
        ltIdx  := i;
      end;
      if ((idxNum and 3) = 0) and (pC^.op = SQLITE_INDEX_CONSTRAINT_GE) then begin
        idxNum := idxNum or 2;
        ltIdx  := i;
      end;
      if ((idxNum and 12) = 0) and (pC^.op = SQLITE_INDEX_CONSTRAINT_LT) then begin
        idxNum := idxNum or 4;
        gtIdx  := i;
      end;
      if ((idxNum and 12) = 0) and (pC^.op = SQLITE_INDEX_CONSTRAINT_LE) then begin
        idxNum := idxNum or 8;
        gtIdx  := i;
      end;
    end;
    Inc(pC);
  end;

  pIdxInfo^.idxNum := idxNum;

  if ltIdx >= 0 then begin
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, ltIdx);
    pUse^.argvIndex := argvIdx;
    Inc(argvIdx);
    pUse^.omit      := 1;
  end;
  if gtIdx >= 0 then begin
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, gtIdx);
    pUse^.argvIndex := argvIdx;
    pUse^.omit      := 1;
  end;
  if (pIdxInfo^.nOrderBy = 1) then begin
    pOrder := pIdxInfo^.aOrderBy;
    if pOrder^.desc = 0 then
      pIdxInfo^.orderByConsumed := 1;
  end;

  if (idxNum and 12) = 0 then
    pIdxInfo^.estimatedCost := 1.0e99
  else if (idxNum and 3) = 0 then
    pIdxInfo^.estimatedCost := 5.0
  else
    pIdxInfo^.estimatedCost := 1.0;
  Result := SQLITE_OK;
end;

function sqlite3WholenumberInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'wholenumber',
    @wholenumberModule, nil);
end;

initialization
  FillChar(wholenumberModule, SizeOf(wholenumberModule), 0);
  wholenumberModule.iVersion    := 0;
  wholenumberModule.xCreate     := @wholenumberConnect;
  wholenumberModule.xConnect    := @wholenumberConnect;
  wholenumberModule.xBestIndex  := @wholenumberBestIndex;
  wholenumberModule.xDisconnect := @wholenumberDisconnect;
  wholenumberModule.xDestroy    := @wholenumberDisconnect;
  wholenumberModule.xOpen       := @wholenumberOpen;
  wholenumberModule.xClose      := @wholenumberClose;
  wholenumberModule.xFilter     := @wholenumberFilter;
  wholenumberModule.xNext       := @wholenumberNext;
  wholenumberModule.xEof        := @wholenumberEof;
  wholenumberModule.xColumn     := @wholenumberColumn;
  wholenumberModule.xRowid      := @wholenumberRowid;
end.
