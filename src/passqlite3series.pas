{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/series.c (937 lines in C).

  Eponymous virtual table generate_series(start[, stop[, step]]):

      SELECT * FROM generate_series(0, 100, 5);   -- 0,5,10,...,100
      SELECT * FROM generate_series(20) LIMIT 10; -- 20..29
      SELECT * FROM generate_series(0, -1);       -- empty

  xBestIndex understands EQ on the hidden start/stop/step columns,
  EQ/GE/GT/LE/LT on the value column (rowid is an alias of value), and
  LIMIT/OFFSET pushdown. ORDER BY value ASC/DESC is consumed when both
  start and stop are bound. The query plan is encoded as a bitmask in
  idxNum, mirroring series.c:411..425.

  The step is an unsigned 64-bit integer so a query like

      SELECT * FROM generate_series(9223372036854775807,
                                    -9223372036854775808,
                                    -9223372036854775808);

  produces a single row at iBase=-1 (the C source's example at
  series.c:155..164).  add64 / sub64 / span64 are therefore implemented
  with explicit unchecked u64 arithmetic; FPC's range checks would
  otherwise reject the wrap-around.

  Public entry: sqlite3SeriesInit(db) — equivalent to
  sqlite3_series_init() in C.
}
{$I passqlite3.inc}
unit passqlite3series;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3SeriesInit(db: PTsqlite3): i32;

implementation

const
  { series.c:319..322 }
  LARGEST_INT64  : i64 = i64($7FFFFFFFFFFFFFFF);
  SMALLEST_INT64 : i64 = i64($8000000000000000);
  LARGEST_UINT64 : u64 = u64($FFFFFFFFFFFFFFFF);

  { Column numbers — series.c:229..233 }
  SERIES_COLUMN_ROWID = -1;
  SERIES_COLUMN_VALUE = 0;
  SERIES_COLUMN_START = 1;
  SERIES_COLUMN_STOP  = 2;
  SERIES_COLUMN_STEP  = 3;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { series.c:166..178 — series_cursor.  base must be first. }
  PSeriesCursor = ^TSeriesCursor;
  TSeriesCursor = record
    base   : Tsqlite3_vtab_cursor;
    iOBase : i64;     { Original "start" }
    iOTerm : i64;     { Original "stop" }
    iOStep : i64;     { Original "step" }
    iBase  : i64;     { Effective start used to drive the scan }
    iTerm  : i64;     { Effective stop }
    iStep  : u64;     { Effective step (always positive) }
    iValue : i64;     { Current value }
    bDesc  : u8;      { Non-zero if iStep is logically negative }
    bDone  : u8;      { Non-zero after stepping past the last element }
  end;

var
  seriesModule: Tsqlite3_module;

{ ---------------------------------------------------------------------
  series.c:185..203 — span64 / add64 / sub64.

  The C source type-puns through u64 to defeat the C signed-overflow
  rule.  In Pascal we can do the same with QWord arithmetic; the
  {$Q-}{$R-} block disables overflow / range checking for these
  helpers exclusively.
  --------------------------------------------------------------------- }
{$Q-}{$R-}
function span64(a, b: i64): u64; inline;
begin
  Result := u64(a) - u64(b);
end;

function add64(a: i64; b: u64): i64; inline;
begin
  Result := i64(u64(a) + b);
end;

function sub64(a: i64; b: u64): i64; inline;
begin
  Result := i64(u64(a) - b);
end;
{$Q+}{$R+}

{ series.c:218..248 — xConnect (also xCreate=NULL upstream; here we
  leave xCreate NULL which makes the table eponymous-only). }
function seriesConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PSqlite3Vtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE x(value,start hidden,stop hidden,step hidden)');
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  pNew := PSqlite3Vtab(sqlite3Malloc(SizeOf(Tsqlite3_vtab)));
  ppVtab^ := pNew;
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pNew^, SizeOf(Tsqlite3_vtab), 0);
  sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS, 0);
  Result := SQLITE_OK;
end;

{ series.c:253..256 — xDisconnect. }
function seriesDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ series.c:261..269 — xOpen. }
function seriesOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PSeriesCursor;
begin
  pCur := PSeriesCursor(sqlite3Malloc(SizeOf(TSeriesCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TSeriesCursor), 0);
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ series.c:274..277 — xClose. }
function seriesClose(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ series.c:283..295 — xNext. }
function seriesNext(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PSeriesCursor;
begin
  pCur := PSeriesCursor(cur);
  if pCur^.iValue = pCur^.iTerm then
    pCur^.bDone := 1
  else if pCur^.bDesc <> 0 then
    pCur^.iValue := sub64(pCur^.iValue, pCur^.iStep)
  else
    pCur^.iValue := add64(pCur^.iValue, pCur^.iStep);
  Result := SQLITE_OK;
end;

{ series.c:301..316 — xColumn. }
function seriesColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur: PSeriesCursor;
  x:    i64;
begin
  pCur := PSeriesCursor(cur);
  case i of
    SERIES_COLUMN_START: x := pCur^.iOBase;
    SERIES_COLUMN_STOP:  x := pCur^.iOTerm;
    SERIES_COLUMN_STEP:  x := pCur^.iOStep;
  else
    x := pCur^.iValue;
  end;
  sqlite3_result_int64(ctx, x);
  Result := SQLITE_OK;
end;

{ series.c:327..331 — xRowid (alias of value). }
function seriesRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PSeriesCursor;
begin
  pCur := PSeriesCursor(cur);
  pRowid^ := pCur^.iValue;
  Result := SQLITE_OK;
end;

{ series.c:337..340 — xEof. }
function seriesEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PSeriesCursor;
begin
  pCur := PSeriesCursor(cur);
  Result := pCur^.bDone;
end;

{ series.c:354..362 — seriesSteps. }
function seriesSteps(pCur: PSeriesCursor): u64;
begin
  if pCur^.bDesc <> 0 then
    Result := span64(pCur^.iBase, pCur^.iTerm) div pCur^.iStep
  else
    Result := span64(pCur^.iTerm, pCur^.iBase) div pCur^.iStep;
end;

{ series.c:381..400 — seriesCeil / seriesFloor (Case 3 home-grown
  variants — FPC doesn't define SQLITE_ENABLE_MATH_FUNCTIONS and the
  GCC builtins aren't available; the home-grown form works for our
  range and avoids pulling in libm via SysUtils-Math.). }
function seriesCeil(r: Double): Double;
var x: i64;
begin
  if r <> r then Exit(r);
  if r <= -4503599627370496.0 then Exit(r);
  if r >= +4503599627370496.0 then Exit(r);
  x := Trunc(r);
  if r = Double(x) then Exit(r);
  if r > Double(x) then Inc(x);
  Result := Double(x);
end;

function seriesFloor(r: Double): Double;
var x: i64;
begin
  if r <> r then Exit(r);
  if r <= -4503599627370496.0 then Exit(r);
  if r >= +4503599627370496.0 then Exit(r);
  x := Trunc(r);
  if r = Double(x) then Exit(r);
  if r < Double(x) then Dec(x);
  Result := Double(x);
end;

{ series.c:430..669 — xFilter.

  idxNum bits (also documented at series.c:411..424):
     0x0001  start=VALUE
     0x0002  stop=VALUE
     0x0004  step=VALUE
     0x0008  output is in descending order
     0x0010  output is in ascending order
     0x0020  LIMIT VALUE
     0x0040  OFFSET VALUE
     0x0080  value=VALUE
     0x0100  value>=VALUE
     0x0200  value>VALUE
     0x1000  value<=VALUE
     0x2000  value<VALUE
}
function seriesFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
label
  series_no_rows;
var
  pCur:    PSeriesCursor;
  iArg, i: i32;
  iMin, iMax, iLimit, iOffset, iTmp: i64;
  r:       Double;
  span:    u64;
begin
  pCur := PSeriesCursor(cur);
  iArg := 0;
  iMin := SMALLEST_INT64;
  iMax := LARGEST_INT64;
  iLimit  := 0;
  iOffset := 0;

  { NULL constraint anywhere → no rows.  series.c:447..452 }
  for i := 0 to argc - 1 do
    if sqlite3_value_type(argv[i]) = SQLITE_NULL then goto series_no_rows;

  { Capture the three hidden parameters with defaults — series.c:457..472 }
  if (idxNum and $01) <> 0 then begin
    pCur^.iOBase := sqlite3_value_int64(argv[iArg]); Inc(iArg);
  end else
    pCur^.iOBase := 0;
  if (idxNum and $02) <> 0 then begin
    pCur^.iOTerm := sqlite3_value_int64(argv[iArg]); Inc(iArg);
  end else
    pCur^.iOTerm := i64($FFFFFFFF);
  if (idxNum and $04) <> 0 then begin
    pCur^.iOStep := sqlite3_value_int64(argv[iArg]); Inc(iArg);
    if pCur^.iOStep = 0 then pCur^.iOStep := 1;
  end else
    pCur^.iOStep := 1;

  { When only value-column constraints exist, widen the default range
    to [SMALLEST_INT64..LARGEST_INT64] so they have something to
    contract.  series.c:480..485 }
  if ((idxNum and $05) = 0) and ((idxNum and $0380) <> 0) then
    pCur^.iOBase := SMALLEST_INT64;
  if ((idxNum and $06) = 0) and ((idxNum and $3080) <> 0) then
    pCur^.iOTerm := LARGEST_INT64;
  pCur^.iBase := pCur^.iOBase;
  pCur^.iTerm := pCur^.iOTerm;

  { Translate iOStep to the unsigned iStep, taking care of the
    SMALLEST_INT64 corner case.  series.c:488..495 }
  if pCur^.iOStep > 0 then
    pCur^.iStep := u64(pCur^.iOStep)
  else if pCur^.iOStep > SMALLEST_INT64 then
    pCur^.iStep := u64(-pCur^.iOStep)
  else begin
    { -SMALLEST_INT64 == LARGEST_INT64 + 1 == $8000000000000000 }
    pCur^.iStep := u64(LARGEST_INT64) + 1;
  end;
  if pCur^.iOStep < 0 then pCur^.bDesc := 1 else pCur^.bDesc := 0;

  if (pCur^.bDesc = 0) and (pCur^.iBase > pCur^.iTerm) then goto series_no_rows;
  if (pCur^.bDesc <> 0) and (pCur^.iBase < pCur^.iTerm) then goto series_no_rows;

  { Capture LIMIT / OFFSET (apply later).  series.c:507..512 }
  if (idxNum and $20) <> 0 then begin
    iLimit := sqlite3_value_int64(argv[iArg]); Inc(iArg);
    if (idxNum and $40) <> 0 then begin
      iOffset := sqlite3_value_int64(argv[iArg]); Inc(iArg);
    end;
  end;

  { Narrow [iMin..iMax] from value-column constraints, then contract
    [iBase..iTerm] to honour them.  series.c:517..612 }
  if (idxNum and $3380) <> 0 then begin
    if (idxNum and $0080) <> 0 then begin     { value=X }
      if sqlite3_value_numeric_type(argv[iArg]) = SQLITE_FLOAT then begin
        r := sqlite3_value_double(argv[iArg]); Inc(iArg);
        if (r = seriesCeil(r))
           and (r >= Double(SMALLEST_INT64))
           and (r <= Double(LARGEST_INT64)) then begin
          iMin := Trunc(r); iMax := iMin;
        end else
          goto series_no_rows;
      end else begin
        iMin := sqlite3_value_int64(argv[iArg]); Inc(iArg);
        iMax := iMin;
      end;
    end else begin
      if (idxNum and $0300) <> 0 then begin   { value>X or value>=X }
        if sqlite3_value_numeric_type(argv[iArg]) = SQLITE_FLOAT then begin
          r := sqlite3_value_double(argv[iArg]); Inc(iArg);
          if r < Double(SMALLEST_INT64) then
            iMin := SMALLEST_INT64
          else if ((idxNum and $0200) <> 0) and (r = seriesCeil(r)) then
            iMin := Trunc(seriesCeil(r + 1.0))
          else
            iMin := Trunc(seriesCeil(r));
        end else begin
          iMin := sqlite3_value_int64(argv[iArg]); Inc(iArg);
          if (idxNum and $0200) <> 0 then begin
            if iMin = LARGEST_INT64 then goto series_no_rows
            else Inc(iMin);
          end;
        end;
      end;
      if (idxNum and $3000) <> 0 then begin   { value<X or value<=X }
        if sqlite3_value_numeric_type(argv[iArg]) = SQLITE_FLOAT then begin
          r := sqlite3_value_double(argv[iArg]); Inc(iArg);
          if r > Double(LARGEST_INT64) then
            iMax := LARGEST_INT64
          else if ((idxNum and $2000) <> 0) and (r = seriesFloor(r)) then
            iMax := Trunc(r - 1.0)
          else
            iMax := Trunc(seriesFloor(r));
        end else begin
          iMax := sqlite3_value_int64(argv[iArg]); Inc(iArg);
          if (idxNum and $2000) <> 0 then begin
            if iMax = SMALLEST_INT64 then goto series_no_rows
            else Dec(iMax);
          end;
        end;
      end;
      if iMin > iMax then goto series_no_rows;
    end;

    { Contract [iBase..iTerm] to fit in [iMin..iMax].  series.c:583..611 }
    if pCur^.bDesc = 0 then begin
      if pCur^.iBase < iMin then begin
        span := span64(iMin, pCur^.iBase);
        pCur^.iBase := add64(pCur^.iBase, (span div pCur^.iStep) * pCur^.iStep);
        if pCur^.iBase < iMin then begin
          if pCur^.iBase > sub64(LARGEST_INT64, pCur^.iStep) then
            goto series_no_rows;
          pCur^.iBase := add64(pCur^.iBase, pCur^.iStep);
        end;
      end;
      if pCur^.iTerm > iMax then pCur^.iTerm := iMax;
    end else begin
      if pCur^.iBase > iMax then begin
        span := span64(pCur^.iBase, iMax);
        pCur^.iBase := sub64(pCur^.iBase, (span div pCur^.iStep) * pCur^.iStep);
        if pCur^.iBase > iMax then begin
          if pCur^.iBase < add64(SMALLEST_INT64, pCur^.iStep) then
            goto series_no_rows;
          pCur^.iBase := sub64(pCur^.iBase, pCur^.iStep);
        end;
      end;
      if pCur^.iTerm < iMin then pCur^.iTerm := iMin;
    end;
  end;

  { Round iTerm to the last reachable value.  series.c:616..628 }
  if pCur^.bDesc = 0 then begin
    if pCur^.iBase > pCur^.iTerm then goto series_no_rows;
    pCur^.iTerm := sub64(pCur^.iTerm,
      span64(pCur^.iTerm, pCur^.iBase) mod pCur^.iStep);
  end else begin
    if pCur^.iBase < pCur^.iTerm then goto series_no_rows;
    pCur^.iTerm := add64(pCur^.iTerm,
      span64(pCur^.iBase, pCur^.iTerm) mod pCur^.iStep);
  end;

  { Honour explicit ORDER BY by flipping iBase/iTerm.  series.c:633..640 }
  if (((idxNum and $0008) <> 0) and (pCur^.bDesc = 0))
  or (((idxNum and $0010) <> 0) and (pCur^.bDesc <> 0)) then begin
    iTmp := pCur^.iBase;
    pCur^.iBase := pCur^.iTerm;
    pCur^.iTerm := iTmp;
    pCur^.bDesc := pCur^.bDesc xor 1;
  end;

  { Apply LIMIT / OFFSET.  series.c:643..657 }
  if (idxNum and $20) <> 0 then begin
    if iOffset > 0 then begin
      if seriesSteps(pCur) < u64(iOffset) then
        goto series_no_rows
      else if pCur^.bDesc <> 0 then
        pCur^.iBase := sub64(pCur^.iBase, pCur^.iStep * u64(iOffset))
      else
        pCur^.iBase := add64(pCur^.iBase, pCur^.iStep * u64(iOffset));
    end;
    if (iLimit >= 0) and (seriesSteps(pCur) > u64(iLimit)) then
      pCur^.iTerm := add64(pCur^.iBase, (iLimit - 1) * i64(pCur^.iStep));
  end;

  pCur^.iValue := pCur^.iBase;
  pCur^.bDone  := 0;
  Result := SQLITE_OK;
  Exit;

series_no_rows:
  pCur^.iBase := 0;
  pCur^.iTerm := 0;
  pCur^.iStep := 1;
  pCur^.bDesc := 0;
  pCur^.bDone := 1;
  Result := SQLITE_OK;
end;

{ series.c:712..882 — xBestIndex. }
function seriesBestIndex(pVTab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i, j, idxNum: i32;
  bStartSeen:   i32;
  unusableMask: i32;
  nArg:         i32;
  aIdx:         array[0..6] of i32;
  pConstraint:  PSqlite3IndexConstraint;
  pUse:         PSqlite3IndexConstraintUsage;
  pOrder:       PSqlite3IndexOrderBy;
  iCol, iMask:  i32;
  op:           i32;
begin
  idxNum       := 0;
  bStartSeen   := 0;
  unusableMask := 0;
  nArg         := 0;
  for i := 0 to 6 do aIdx[i] := -1;

  pConstraint := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    op := pConstraint^.op;
    if (op >= SQLITE_INDEX_CONSTRAINT_LIMIT)
       and (op <= SQLITE_INDEX_CONSTRAINT_OFFSET) then begin
      if pConstraint^.usable <> 0 then begin
        if op = SQLITE_INDEX_CONSTRAINT_LIMIT then begin
          aIdx[3] := i;
          idxNum  := idxNum or $20;
        end else begin
          aIdx[4] := i;
          idxNum  := idxNum or $40;
        end;
      end;
      Inc(pConstraint);
      Continue;
    end;

    if pConstraint^.iColumn < SERIES_COLUMN_START then begin
      if ((pConstraint^.iColumn = SERIES_COLUMN_VALUE)
          or (pConstraint^.iColumn = SERIES_COLUMN_ROWID))
         and (pConstraint^.usable <> 0) then begin
        case op of
          SQLITE_INDEX_CONSTRAINT_EQ,
          SQLITE_INDEX_CONSTRAINT_IS:
            begin
              idxNum := (idxNum or $0080) and (not $3300);
              aIdx[5] := i;
              aIdx[6] := -1;
              bStartSeen := 1;
            end;
          SQLITE_INDEX_CONSTRAINT_GE:
            if (idxNum and $0080) = 0 then begin
              idxNum := (idxNum or $0100) and (not $0200);
              aIdx[5] := i;
              bStartSeen := 1;
            end;
          SQLITE_INDEX_CONSTRAINT_GT:
            if (idxNum and $0080) = 0 then begin
              idxNum := (idxNum or $0200) and (not $0100);
              aIdx[5] := i;
              bStartSeen := 1;
            end;
          SQLITE_INDEX_CONSTRAINT_LE:
            if (idxNum and $0080) = 0 then begin
              idxNum := (idxNum or $1000) and (not $2000);
              aIdx[6] := i;
            end;
          SQLITE_INDEX_CONSTRAINT_LT:
            if (idxNum and $0080) = 0 then begin
              idxNum := (idxNum or $2000) and (not $1000);
              aIdx[6] := i;
            end;
        end;
      end;
      Inc(pConstraint);
      Continue;
    end;

    iCol  := pConstraint^.iColumn - SERIES_COLUMN_START;  { 0..2 }
    iMask := 1 shl iCol;
    if (iCol = 0) and (op = SQLITE_INDEX_CONSTRAINT_EQ) then bStartSeen := 1;
    if pConstraint^.usable = 0 then
      unusableMask := unusableMask or iMask
    else if op = SQLITE_INDEX_CONSTRAINT_EQ then begin
      idxNum := idxNum or iMask;
      aIdx[iCol] := i;
    end;
    Inc(pConstraint);
  end;

  { OFFSET without LIMIT is meaningless in this implementation —
    series.c:825..829 }
  if aIdx[3] = 0 then begin
    idxNum  := idxNum and (not $60);
    aIdx[4] := 0;
  end;

  for i := 0 to 6 do begin
    j := aIdx[i];
    if j >= 0 then begin
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, j);
      Inc(nArg);
      pUse^.argvIndex := nArg;
      if i >= 3 then pUse^.omit := 1 else pUse^.omit := 1;
      { SQLITE_SERIES_CONSTRAINT_VERIFY=0 in upstream → omit always 1 }
    end;
  end;

  if bStartSeen = 0 then begin
    sqlite3_free(pVTab^.zErrMsg);
    pVTab^.zErrMsg := sqlite3_mprintf(
      'first argument to "generate_series()" missing or unusable');
    Result := SQLITE_ERROR;
    Exit;
  end;

  if (unusableMask and (not idxNum)) <> 0 then begin
    Result := SQLITE_CONSTRAINT;
    Exit;
  end;

  if (idxNum and $03) = $03 then begin
    { Both start and stop bound — preferred case.  series.c:856..867 }
    if (idxNum and 4) <> 0 then
      pIdxInfo^.estimatedCost := 1.0
    else
      pIdxInfo^.estimatedCost := 2.0;
    pIdxInfo^.estimatedRows := 1000;
    if (pIdxInfo^.nOrderBy >= 1)
       and (pIdxInfo^.aOrderBy^.iColumn = 0) then begin
      pOrder := pIdxInfo^.aOrderBy;
      if pOrder^.desc <> 0 then
        idxNum := idxNum or $08
      else
        idxNum := idxNum or $10;
      pIdxInfo^.orderByConsumed := 1;
    end;
  end else if (idxNum and $21) = $21 then begin
    pIdxInfo^.estimatedRows := 2500;
  end else begin
    pIdxInfo^.estimatedRows := 2147483647;
  end;
  pIdxInfo^.idxNum := idxNum;
  pIdxInfo^.idxFlags := pIdxInfo^.idxFlags or SQLITE_INDEX_SCAN_HEX;
  Result := SQLITE_OK;
end;

function sqlite3SeriesInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'generate_series',
    @seriesModule, nil);
end;

initialization
  FillChar(seriesModule, SizeOf(seriesModule), 0);
  seriesModule.iVersion    := 0;
  seriesModule.xCreate     := nil;          { eponymous-only }
  seriesModule.xConnect    := @seriesConnect;
  seriesModule.xBestIndex  := @seriesBestIndex;
  seriesModule.xDisconnect := @seriesDisconnect;
  seriesModule.xDestroy    := nil;
  seriesModule.xOpen       := @seriesOpen;
  seriesModule.xClose      := @seriesClose;
  seriesModule.xFilter     := @seriesFilter;
  seriesModule.xNext       := @seriesNext;
  seriesModule.xEof        := @seriesEof;
  seriesModule.xColumn     := @seriesColumn;
  seriesModule.xRowid      := @seriesRowid;
end.
