{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/percentile.c (503 lines in C).

  Provides the percentile family of aggregate / window functions:
    - median(Y)              == percentile(Y, 50)
    - percentile(Y, P)        P in [0..100]
    - percentile_cont(Y, P)   P in [0..1]
    - percentile_disc(Y, P)   P in [0..1], returns one of the inputs

  All four are also valid window functions; xInverse / xValue are wired.

  Public entry: sqlite3PercentileInit(db) — equivalent to
  sqlite3_percentile_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3percentile;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

function sqlite3PercentileInit(db: PTsqlite3): i32;

{ Register the percentile family (median/percentile/percentile_cont/
  percentile_disc) into the GLOBAL builtin-function hash, mirroring the
  way C's func.c registers them via WAGGREGATE+sqlite3InsertBuiltinFuncs
  when compiled with SQLITE_ENABLE_PERCENTILE.  This MUST be a builtin
  (not a per-connection sqlite3_create_function entry in db^.aFunc) so a
  user-defined function of the same name — e.g. the window5.test
  `sqlite3_create_window_function db median ...` — correctly overrides it
  (sqlite3FindFunction prefers db^.aFunc matches over builtins). }
procedure sqlite3PercentileFunctions;

implementation

uses
  passqlite3printf;

const
  SQLITE_SELFORDER1 = $002000000;

type
  { Mirrors `struct Percentile` (percentile.c:132..141). }
  TPercentile = record
    nAlloc:      u32;     { slots allocated for a[] }
    nUsed:       u32;     { slots used in a[] }
    bSorted:     Byte;    { a[] is sorted }
    bKeepSorted: Byte;    { advantageous to keep a[] sorted }
    bPctValid:   Byte;    { rPct is valid }
    rPct:        Double;  { fraction 0.0..1.0 }
    a:           PDouble; { array of Y values }
  end;
  PPercentile = ^TPercentile;

  { Mirrors `struct PercentileFunc` (percentile.c:144..150). }
  TPercentileFunc = record
    zName:     PAnsiChar;
    nArg:      Byte;
    mxFrac:    Byte;
    bDiscrete: Byte;
  end;
  PPercentileFunc = ^TPercentileFunc;

const
  { aPercentFunc[] (percentile.c:151..156).  Pascal `const` arrays of
    record literals support PAnsiChar pointers to string literals. }
  aPercentFunc: array[0..3] of TPercentileFunc = (
    (zName: 'median';           nArg: 1; mxFrac:   1; bDiscrete: 0),
    (zName: 'percentile';       nArg: 2; mxFrac: 100; bDiscrete: 0),
    (zName: 'percentile_cont';  nArg: 2; mxFrac:   1; bDiscrete: 0),
    (zName: 'percentile_disc';  nArg: 2; mxFrac:   1; bDiscrete: 1)
  );

{ TBits64 — used to type-pun Double → u64 for the IEEE-754 exponent
  test in percentIsInfinity (percentile.c:161..166).  FPC on x86_64 is
  little-endian so the union layout matches `union { u64; double; }`. }
type
  TBits64 = record
    case Byte of
      0: (d: Double);
      1: (u: u64);
  end;

function percentIsInfinity(r: Double): Boolean; inline;
var
  b: TBits64;
begin
  b.d := r;
  Result := ((b.u shr 52) and $7ff) = $7ff;
end;

{ Two doubles differ by 0.001 or less.  Mirrors percentile.c:171..174. }
function percentSameValue(a, b: Double): Boolean; inline;
begin
  a := a - b;
  Result := (a >= -0.001) and (a <= 0.001);
end;

{ Binary search (percentile.c:187..203).  Returns the index of an entry
  with value y, or — when bExact=0 — the position at which a new entry
  with value y should be inserted to keep the array sorted. }
function percentBinarySearch(p: PPercentile; y: Double; bExact: i32): i32;
var
  iFirst, iLast, iMid: i32;
  x: Double;
  pa: PDouble;
begin
  iFirst := 0;
  iLast := i32(p^.nUsed) - 1;
  pa := p^.a;
  while iLast >= iFirst do
  begin
    iMid := (iFirst + iLast) div 2;
    x := pa[iMid];
    if x < y then
      iFirst := iMid + 1
    else if x > y then
      iLast := iMid - 1
    else begin
      Result := iMid; Exit;
    end;
  end;
  if bExact <> 0 then begin Result := -1; Exit; end;
  Result := iFirst;
end;

{ percentError (percentile.c:212..225).  C's two-pass vmprintf+mprintf
  exists only because the variadic %.1f arg has to be substituted before
  the function-name %s can be filled in.  Pascal port collapses the two
  passes into one sqlite3MPrintf call by interleaving the arguments. }
procedure percentError1(pCtx: Psqlite3_context; const zMsg: AnsiString);
var
  pFunc: PPercentileFunc;
  zOut: PAnsiChar;
begin
  pFunc := PPercentileFunc(sqlite3_user_data(pCtx));
  zOut := sqlite3MPrintf(nil, PAnsiChar(zMsg), [pFunc^.zName]);
  sqlite3_result_error(pCtx, zOut, -1);
  sqlite3_free(zOut);
end;

procedure percentErrorRange(pCtx: Psqlite3_context);
var
  pFunc: PPercentileFunc;
  zOut: PAnsiChar;
begin
  pFunc := PPercentileFunc(sqlite3_user_data(pCtx));
  zOut := sqlite3MPrintf(nil,
    'the fraction argument to %s() is not between 0.0 and %.1f',
    [pFunc^.zName, Double(pFunc^.mxFrac)]);
  sqlite3_result_error(pCtx, zOut, -1);
  sqlite3_free(zOut);
end;

{ Quicksort port of percentSort (percentile.c:338..382).  Pascal lacks
  a no-bounds-check variadic macro for SWAP, so we expand inline. }
procedure percentSort(a: PDouble; n: u32);
var
  iLt, iGt, i: i32;
  rPivot, ttt: Double;
begin
  if n < 2 then Exit;
  if a[0] > a[n - 1] then
  begin
    ttt := a[0]; a[0] := a[n - 1]; a[n - 1] := ttt;
  end;
  if n = 2 then Exit;
  iGt := i32(n) - 1;
  i := i32(n) div 2;
  if a[0] > a[i] then
  begin
    ttt := a[0]; a[0] := a[i]; a[i] := ttt;
  end
  else if a[i] > a[iGt] then
  begin
    ttt := a[i]; a[i] := a[iGt]; a[iGt] := ttt;
  end;
  if n = 3 then Exit;
  rPivot := a[i];
  iLt := 1;
  i := 1;
  repeat
    if a[i] < rPivot then
    begin
      if i > iLt then
      begin
        ttt := a[i]; a[i] := a[iLt]; a[iLt] := ttt;
      end;
      Inc(iLt);
      Inc(i);
    end
    else if a[i] > rPivot then
    begin
      repeat
        Dec(iGt);
      until (iGt <= i) or (a[iGt] <= rPivot);
      ttt := a[i]; a[i] := a[iGt]; a[iGt] := ttt;
    end
    else
      Inc(i);
  until i >= iGt;
  if iLt >= 2 then percentSort(a, u32(iLt));
  if i32(n) - iGt >= 2 then percentSort(a + iGt, n - u32(iGt));
end;

{ percentStep (percentile.c:231..319). }
procedure percentStep(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  p: PPercentile;
  pFunc: PPercentileFunc;
  rPct, y: Double;
  eType: i32;
  n: u32;
  pa: PDouble;
  i: i32;
begin
  if argc = 1 then
    rPct := 0.5
  else
  begin
    pFunc := PPercentileFunc(sqlite3_user_data(pCtx));
    eType := sqlite3_value_numeric_type(argv[0 + 1]);
    rPct  := sqlite3_value_double(argv[0 + 1]) / Double(pFunc^.mxFrac);
    if ((eType <> SQLITE_INTEGER) and (eType <> SQLITE_FLOAT))
       or (rPct < 0.0) or (rPct > 1.0) then
    begin
      percentErrorRange(pCtx);
      Exit;
    end;
  end;

  p := PPercentile(sqlite3_aggregate_context(pCtx, SizeOf(TPercentile)));
  if p = nil then Exit;

  if p^.bPctValid = 0 then
  begin
    p^.rPct := rPct;
    p^.bPctValid := 1;
  end
  else if not percentSameValue(p^.rPct, rPct) then
  begin
    percentError1(pCtx,
      'the fraction argument to %s() is not the same for all input rows');
    Exit;
  end;

  eType := sqlite3_value_type(argv[0]);
  if eType = SQLITE_NULL then Exit;
  if (eType <> SQLITE_INTEGER) and (eType <> SQLITE_FLOAT) then
  begin
    percentError1(pCtx, 'input to %s() is not numeric');
    Exit;
  end;
  y := sqlite3_value_double(argv[0]);
  if percentIsInfinity(y) then
  begin
    percentError1(pCtx, 'Inf input to %s()');
    Exit;
  end;

  if p^.nUsed >= p^.nAlloc then
  begin
    n := p^.nAlloc * 2 + 250;
    pa := PDouble(sqlite3_realloc64(p^.a, u64(SizeOf(Double)) * n));
    if pa = nil then
    begin
      sqlite3_free(p^.a);
      FillChar(p^, SizeOf(p^), 0);
      sqlite3_result_error_nomem(pCtx);
      Exit;
    end;
    p^.nAlloc := n;
    p^.a := pa;
  end;

  if p^.nUsed = 0 then
  begin
    p^.a[p^.nUsed] := y;
    Inc(p^.nUsed);
    p^.bSorted := 1;
  end
  else if (p^.bSorted = 0) or (y >= p^.a[p^.nUsed - 1]) then
  begin
    p^.a[p^.nUsed] := y;
    Inc(p^.nUsed);
  end
  else if p^.bKeepSorted <> 0 then
  begin
    i := percentBinarySearch(p, y, 0);
    if u32(i) < p^.nUsed then
      Move(p^.a[i], p^.a[i + 1], (p^.nUsed - u32(i)) * SizeOf(Double));
    p^.a[i] := y;
    Inc(p^.nUsed);
  end
  else
  begin
    p^.a[p^.nUsed] := y;
    Inc(p^.nUsed);
    p^.bSorted := 0;
  end;
end;

{ percentInverse (percentile.c:389..430).  xInverse is invoked when a
  row leaves the window frame.  We must keep the array sorted so that
  binary search finds the value to remove. }
procedure percentInverse(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  p: PPercentile;
  eType, i: i32;
  y: Double;
begin
  p := PPercentile(sqlite3_aggregate_context(pCtx, SizeOf(TPercentile)));
  if p = nil then Exit;
  eType := sqlite3_value_type(argv[0]);
  if eType = SQLITE_NULL then Exit;
  if (eType <> SQLITE_INTEGER) and (eType <> SQLITE_FLOAT) then Exit;
  y := sqlite3_value_double(argv[0]);
  if percentIsInfinity(y) then Exit;
  if p^.bSorted = 0 then
  begin
    percentSort(p^.a, p^.nUsed);
    p^.bSorted := 1;
  end;
  p^.bKeepSorted := 1;
  i := percentBinarySearch(p, y, 1);
  if i >= 0 then
  begin
    Dec(p^.nUsed);
    if u32(i) < p^.nUsed then
      Move(p^.a[i + 1], p^.a[i], (p^.nUsed - u32(i)) * SizeOf(Double));
  end;
end;

{ percentCompute (percentile.c:436..469). }
procedure percentCompute(pCtx: Psqlite3_context; bIsFinal: i32);
var
  p: PPercentile;
  pFunc: PPercentileFunc;
  i1, i2: u32;
  v1, v2, ix, vx: Double;
begin
  pFunc := PPercentileFunc(sqlite3_user_data(pCtx));
  p := PPercentile(sqlite3_aggregate_context(pCtx, 0));
  if p = nil then Exit;
  if p^.a = nil then Exit;
  if p^.nUsed > 0 then
  begin
    if p^.bSorted = 0 then
    begin
      percentSort(p^.a, p^.nUsed);
      p^.bSorted := 1;
    end;
    ix := p^.rPct * Double(p^.nUsed - 1);
    i1 := u32(Trunc(ix));
    if pFunc^.bDiscrete <> 0 then
      vx := p^.a[i1]
    else
    begin
      if (ix = Double(i1)) or (i1 = p^.nUsed - 1) then
        i2 := i1
      else
        i2 := i1 + 1;
      v1 := p^.a[i1];
      v2 := p^.a[i2];
      vx := v1 + (v2 - v1) * (ix - Double(i1));
    end;
    sqlite3_result_double(pCtx, vx);
  end;
  if bIsFinal <> 0 then
  begin
    sqlite3_free(p^.a);
    FillChar(p^, SizeOf(p^), 0);
  end
  else
    p^.bKeepSorted := 1;
end;

procedure percentFinal(pCtx: Psqlite3_context); cdecl;
begin
  percentCompute(pCtx, 1);
end;

procedure percentValue(pCtx: Psqlite3_context); cdecl;
begin
  percentCompute(pCtx, 0);
end;

var
  { Module-static FuncDef storage for the four percentile builtins.  Like
    aStatFuncs / aBuiltinFuncs (codegen.pas) the bucket-chain links live in
    these records, so re-running sqlite3PercentileFunctions is idempotent
    (sqlite3InsertBuiltinFuncs skips already-linked entries). }
  aPercentileFuncs:      array[0..3] of TFuncDef;
  percentileFuncsInited: Boolean = False;

procedure sqlite3PercentileFunctions;
const
  { WAGGREGATE flags for the percentile family (func.c:3366..3377):
    SQLITE_FUNC_BUILTIN|SQLITE_UTF8|SQLITE_INNOCUOUS|SQLITE_SELFORDER1.
    Aggregate-ness comes from a non-nil xFinalize; usable as a window
    function via xValue/xInverse. }
  GFlags = SQLITE_FUNC_BUILTIN or SQLITE_UTF8
        or SQLITE_INNOCUOUS or SQLITE_SELFORDER1;
var
  i: i32;
begin
  if percentileFuncsInited then Exit;
  percentileFuncsInited := True;
  FillChar(aPercentileFuncs[0], SizeOf(aPercentileFuncs), 0);
  for i := 0 to High(aPercentFunc) do
  begin
    aPercentileFuncs[i].nArg      := aPercentFunc[i].nArg;
    aPercentileFuncs[i].funcFlags := GFlags;
    { C passes SQLITE_INT_TO_PTR(arg) as pUserData (a mxFrac/discrete
      bitmask), but this port reuses the ext/misc/percentile.c struct-based
      callbacks which read pUserData as a PercentileFunc*.  Point it at the
      matching aPercentFunc[] descriptor so percentStep can read mxFrac. }
    aPercentileFuncs[i].pUserData := @aPercentFunc[i];
    aPercentileFuncs[i].xSFunc    := TxSFuncProc(@percentStep);
    aPercentileFuncs[i].xFinalize := TxFinalProc(@percentFinal);
    aPercentileFuncs[i].xValue    := TxValueProc(@percentValue);
    aPercentileFuncs[i].xInverse  := TxInverseProc(@percentInverse);
    aPercentileFuncs[i].zName     := aPercentFunc[i].zName;
  end;
  sqlite3InsertBuiltinFuncs(@aPercentileFuncs, Length(aPercentileFuncs));
end;

{ sqlite3PercentileInit — retained for callers that wire ext/misc
  extensions per-connection (shell.c-style _init hooks).  Now that the
  percentile family is a global builtin, this just ensures the builtin
  registration has run; it no longer adds per-connection db^.aFunc entries
  (which would shadow user-defined functions of the same name). }
function sqlite3PercentileInit(db: PTsqlite3): i32;
begin
  sqlite3PercentileFunctions;
  Result := SQLITE_OK;
  if db = nil then ;
end;

end.
