{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/fuzzer.c (1192 lines in C).

  Provides the `fuzzer` virtual table — a demonstration vtab that
  generates variations on an input word at increasing edit distances
  from the original.  Created via:

      CREATE VIRTUAL TABLE f USING fuzzer(<rule-table>);

  where <rule-table> is a four-column table of (ruleset, cFrom, cTo,
  Cost) describing the per-character transformations and their costs.
  Queried as:

      SELECT word, distance FROM f WHERE word MATCH 'abc' AND distance<200;

  Read-only.  Output is sorted by increasing distance; duplicate words
  are suppressed via an internal hash table.

  Public entry: sqlite3FuzzerInit(db) — equivalent to
  sqlite3_fuzzer_init() in the C extension.

  Same caveat as the prior eponymous-vtab series (10.1.69, 10.1.71,
  10.1.72, 10.1.77, 10.1.80, 10.1.83, 10.1.86): the Pascal port does
  not yet wire vtab xBestIndex pushdown, so a bare
  `SELECT … FROM f WHERE word MATCH 'abc'` may not flow the constraint
  through; the module itself is faithful end-to-end.
}
{$I passqlite3.inc}
unit passqlite3fuzzer;

interface

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3FuzzerInit(db: PTsqlite3): i32;

implementation

const
  FUZZER_MX_LENGTH         = 50;          { fuzzer.c:184 — max rule string length }
  FUZZER_MX_RULEID         = $7FFFFFFF;   { fuzzer.c:185 — max rule ID }
  FUZZER_MX_COST           = 1000;        { fuzzer.c:186 — max single-rule cost }
  FUZZER_MX_OUTPUT_LENGTH  = 100;         { fuzzer.c:187 — max output string length }

  FUZZER_HASH              = 4001;        { fuzzer.c:235 — hash table size }
  FUZZER_NQUEUE            = 20;          { fuzzer.c:236 — stem queue slots }

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  PFuzzerRule = ^TFuzzerRule;
  PFuzzerStem = ^TFuzzerStem;
  PFuzzerVtab = ^TFuzzerVtab;
  PFuzzerCursor = ^TFuzzerCursor;

  { fuzzer.c:194..201 — fuzzer_rule.  Variable-length: the actual
    allocation is SizeOf(TFuzzerRule) + nFrom + nTo bytes.  zTo is the
    start of the trailing "to-string" buffer; zFrom is set to
    @zTo[nTo+1]. }
  TFuzzerRule = record
    pNext    : PFuzzerRule;
    zFrom    : PAnsiChar;
    rCost    : i32;
    nFrom    : ShortInt;     { signed char }
    nTo      : ShortInt;
    iRuleset : i32;
    zTo      : array[0..3] of AnsiChar;
  end;

  { fuzzer.c:214..223 — fuzzer_stem. }
  TFuzzerStem = record
    zBasis    : PAnsiChar;
    pRule     : PFuzzerRule;
    pNext     : PFuzzerStem;
    pHash     : PFuzzerStem;
    rBaseCost : i32;
    rCostX    : i32;
    nBasis    : ShortInt;
    n         : ShortInt;
  end;

  { fuzzer.c:228..233 — fuzzer_vtab. }
  TFuzzerVtab = record
    base       : Tsqlite3_vtab;
    zClassName : PAnsiChar;
    pRule      : PFuzzerRule;
    nCursor    : i32;
  end;

  TFuzzerStemArr = array[0..FUZZER_NQUEUE - 1] of PFuzzerStem;
  TFuzzerHashArr = array[0..FUZZER_HASH - 1]  of PFuzzerStem;
  PFuzzerHashArr = ^TFuzzerHashArr;

  { fuzzer.c:239..254 — fuzzer_cursor. }
  TFuzzerCursor = record
    base      : Tsqlite3_vtab_cursor;
    iRowid    : i64;
    pVtab     : PFuzzerVtab;
    rLimit    : i32;
    pStem     : PFuzzerStem;
    pDone     : PFuzzerStem;
    aQueue    : TFuzzerStemArr;
    mxQueue   : i32;
    zBuf      : PAnsiChar;
    nBuf      : i32;
    nStem     : i32;
    iRuleset  : i32;
    nullRule  : TFuzzerRule;
    apHash    : TFuzzerHashArr;
  end;

var
  fuzzerModule: Tsqlite3_module;

{ ----- libc strlen / memcmp / strcmp / memcpy bindings -------------- }

function strlenC(s: PAnsiChar): NativeUInt; cdecl; external 'c' name 'strlen';
function memcmpC(a, b: Pointer; n: NativeUInt): i32; cdecl; external 'c' name 'memcmp';
function strcmpC(a, b: PAnsiChar): i32; cdecl; external 'c' name 'strcmp';

procedure memmoveP(dst, src: Pointer; n: NativeUInt);
begin
  if n > 0 then Move(src^, dst^, n);
end;

{ fuzzer.c:261..283 — merge two cost-sorted rule lists. }
function fuzzerMergeRules(pA, pB: PFuzzerRule): PFuzzerRule;
var
  head : TFuzzerRule;
  pTail: PFuzzerRule;
begin
  pTail := @head;
  while (pA <> nil) and (pB <> nil) do begin
    if pA^.rCost <= pB^.rCost then begin
      pTail^.pNext := pA;
      pTail := pA;
      pA := pA^.pNext;
    end else begin
      pTail^.pNext := pB;
      pTail := pB;
      pB := pB^.pNext;
    end;
  end;
  if pA = nil then
    pTail^.pNext := pB
  else
    pTail^.pNext := pA;
  Result := head.pNext;
end;

{ fuzzer.c:294..358 — load one row of the rule table into a fuzzer_rule. }
function fuzzerLoadOneRule(p: PFuzzerVtab; pStmt: Pointer;
  out ppRule: PFuzzerRule; out pzErr: PAnsiChar): i32;
var
  iRuleset    : i64;
  zFrom, zTo  : PAnsiChar;
  nCost       : i32;
  rc          : i32;
  nFrom, nTo  : i32;
  pRule       : PFuzzerRule;
  pToBase     : PAnsiChar;
  fmtBuf      : array[0..255] of AnsiChar;
begin
  iRuleset := sqlite3_column_int64(PVdbe(pStmt), 0);
  zFrom    := PAnsiChar(sqlite3_column_text(PVdbe(pStmt), 1));
  zTo      := PAnsiChar(sqlite3_column_text(PVdbe(pStmt), 2));
  nCost    := sqlite3_column_int(PVdbe(pStmt), 3);

  rc    := SQLITE_OK;
  pRule := nil;

  if zFrom = nil then zFrom := PAnsiChar('');
  if zTo   = nil then zTo   := PAnsiChar('');
  nFrom := i32(strlenC(zFrom));
  nTo   := i32(strlenC(zTo));

  { Silently ignore null transformations }
  if strcmpC(zFrom, zTo) = 0 then begin
    ppRule := nil;
    Result := SQLITE_OK;
    Exit;
  end;

  if (nCost <= 0) or (nCost > FUZZER_MX_COST) then begin
    StrPCopy(fmtBuf, Format('%s: cost must be between 1 and %d',
      [StrPas(p^.zClassName), FUZZER_MX_COST]));
    pzErr := PAnsiChar(sqlite3StrDup(PChar(fmtBuf)));
    rc := SQLITE_ERROR;
  end else
  if (nFrom > FUZZER_MX_LENGTH) or (nTo > FUZZER_MX_LENGTH) then begin
    StrPCopy(fmtBuf, Format('%s: maximum string length is %d',
      [StrPas(p^.zClassName), FUZZER_MX_LENGTH]));
    pzErr := PAnsiChar(sqlite3StrDup(PChar(fmtBuf)));
    rc := SQLITE_ERROR;
  end else
  if (iRuleset < 0) or (iRuleset > FUZZER_MX_RULEID) then begin
    StrPCopy(fmtBuf, Format('%s: ruleset must be between 0 and %d',
      [StrPas(p^.zClassName), FUZZER_MX_RULEID]));
    pzErr := PAnsiChar(sqlite3StrDup(PChar(fmtBuf)));
    rc := SQLITE_ERROR;
  end else begin
    pRule := PFuzzerRule(sqlite3_malloc64(u64(SizeOf(TFuzzerRule)) + u64(nFrom) + u64(nTo)));
    if pRule = nil then
      rc := SQLITE_NOMEM
    else begin
      FillChar(pRule^, SizeOf(TFuzzerRule), 0);
      pToBase := @pRule^.zTo[0];
      pRule^.zFrom := pToBase + nTo + 1;
      pRule^.nFrom := ShortInt(nFrom);
      memmoveP(pRule^.zFrom, zFrom, NativeUInt(nFrom + 1));
      memmoveP(pToBase,      zTo,   NativeUInt(nTo + 1));
      pRule^.nTo := ShortInt(nTo);
      pRule^.rCost := nCost;
      pRule^.iRuleset := i32(iRuleset);
    end;
  end;

  ppRule := pRule;
  Result := rc;
end;

{ fuzzer.c:363..434 — load the rule table into pNew^.pRule. }
function fuzzerLoadRules(db: PTsqlite3; p: PFuzzerVtab;
  zDb, zData: PAnsiChar; out pzErr: PAnsiChar): i32;
var
  rc, rc2 : i32;
  zSql    : PAnsiChar;
  pStmt   : Pointer;
  pHead   : PFuzzerRule;
  pRule   : PFuzzerRule;
  pX      : PFuzzerRule;
  i       : i32;
  a       : array[0..14] of PFuzzerRule;
  fmtBuf  : array[0..511] of AnsiChar;
begin
  rc    := SQLITE_OK;
  pHead := nil;
  pStmt := nil;

  zSql := sqlite3PfMprintf('SELECT * FROM %Q.%Q', [zDb, zData]);
  if zSql = nil then begin
    Result := SQLITE_NOMEM;
    Exit;
  end;

  rc := sqlite3_prepare_v2(db, zSql, -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin
    StrPCopy(fmtBuf, Format('%s: %s',
      [StrPas(p^.zClassName), StrPas(sqlite3_errmsg(db))]));
    pzErr := PAnsiChar(sqlite3StrDup(PChar(fmtBuf)));
  end else if sqlite3_column_count(PVdbe(pStmt)) <> 4 then begin
    StrPCopy(fmtBuf, Format('%s: %s has %d columns, expected 4',
      [StrPas(p^.zClassName), StrPas(zData),
       sqlite3_column_count(PVdbe(pStmt))]));
    pzErr := PAnsiChar(sqlite3StrDup(PChar(fmtBuf)));
    rc := SQLITE_ERROR;
  end else begin
    while (rc = SQLITE_OK) and (sqlite3_step(PVdbe(pStmt)) = SQLITE_ROW) do begin
      pRule := nil;
      rc := fuzzerLoadOneRule(p, pStmt, pRule, pzErr);
      if pRule <> nil then begin
        pRule^.pNext := pHead;
        pHead := pRule;
      end;
    end;
  end;

  rc2 := sqlite3_finalize(PVdbe(pStmt));
  if rc = SQLITE_OK then rc := rc2;
  sqlite3_free(zSql);

  { Sort the loaded list by cost using a 15-bin merge ladder
    (fuzzer.c:407..424). }
  if rc = SQLITE_OK then begin
    for i := 0 to High(a) do a[i] := nil;
    while pHead <> nil do begin
      pX := pHead;
      pHead := pX^.pNext;
      pX^.pNext := nil;
      i := 0;
      while (a[i] <> nil) and (i < High(a)) do begin
        pX := fuzzerMergeRules(a[i], pX);
        a[i] := nil;
        Inc(i);
      end;
      a[i] := fuzzerMergeRules(a[i], pX);
    end;
    pX := a[0];
    for i := 1 to High(a) do
      pX := fuzzerMergeRules(a[i], pX);
    p^.pRule := fuzzerMergeRules(p^.pRule, pX);
  end else begin
    { On error, anchor the partial list so disconnect frees it. }
    Assert(p^.pRule = nil);
    p^.pRule := pHead;
  end;

  Result := rc;
end;

{ fuzzer.c:449..473 — dequote a SQL-quoted identifier. }
function fuzzerDequote(zIn: PAnsiChar): PAnsiChar;
var
  nIn        : i64;
  zOut       : PAnsiChar;
  q          : AnsiChar;
  iIn, iOut  : i32;
begin
  nIn := i64(strlenC(zIn));
  zOut := PAnsiChar(sqlite3_malloc64(u64(nIn + 1)));
  if zOut <> nil then begin
    q := zIn[0];
    if (q <> '[') and (q <> '''') and (q <> '"') and (q <> '`') then begin
      memmoveP(zOut, zIn, NativeUInt(nIn + 1));
    end else begin
      iOut := 0;
      if q = '[' then q := ']';
      iIn := 1;
      while iIn < nIn do begin
        if zIn[iIn] = q then Inc(iIn);
        zOut[iOut] := zIn[iIn];
        Inc(iOut);
        Inc(iIn);
      end;
      { Trailing terminator: implicit because malloc returns at least
        one extra slot — match the C source by writing it explicitly. }
      zOut[iOut] := #0;
    end;
  end;
  Result := zOut;
end;

{ fuzzer.c:478..488 — xDisconnect / xDestroy. }
function fuzzerDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
var
  p     : PFuzzerVtab;
  pRule : PFuzzerRule;
begin
  p := PFuzzerVtab(pVtab);
  Assert(p^.nCursor = 0);
  while p^.pRule <> nil do begin
    pRule := p^.pRule;
    p^.pRule := pRule^.pNext;
    sqlite3_free(pRule);
  end;
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ fuzzer.c:498..551 — xConnect / xCreate. }
function fuzzerConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  rc      : i32;
  pNew    : PFuzzerVtab;
  zModule : PAnsiChar;
  zDb     : PAnsiChar;
  zTab    : PAnsiChar;
  nModule : i64;
  pTab    : PPAnsiChar;
  fmtBuf  : array[0..255] of AnsiChar;
  errOut  : PAnsiChar;
begin
  rc      := SQLITE_OK;
  pNew    := nil;
  zModule := argv^;
  pTab    := argv;
  Inc(pTab);
  zDb := pTab^;

  if argc <> 4 then begin
    StrPCopy(fmtBuf, Format('%s: wrong number of CREATE VIRTUAL TABLE arguments',
      [StrPas(zModule)]));
    pzErr^ := PAnsiChar(sqlite3StrDup(PChar(fmtBuf)));
    Result := SQLITE_ERROR;
    Exit;
  end;

  nModule := i64(strlenC(zModule));
  pNew := PFuzzerVtab(sqlite3_malloc64(u64(SizeOf(TFuzzerVtab)) + u64(nModule + 1)));
  if pNew = nil then begin
    rc := SQLITE_NOMEM;
  end else begin
    FillChar(pNew^, SizeOf(TFuzzerVtab), 0);
    { Stash the class name in the trailing slot. }
    pNew^.zClassName := PAnsiChar(pNew) + SizeOf(TFuzzerVtab);
    memmoveP(pNew^.zClassName, zModule, NativeUInt(nModule + 1));

    Inc(pTab, 2);  { argv[3] }
    zTab := fuzzerDequote(pTab^);
    if zTab = nil then
      rc := SQLITE_NOMEM
    else begin
      errOut := nil;
      rc := fuzzerLoadRules(db, pNew, zDb, zTab, errOut);
      if errOut <> nil then pzErr^ := errOut;
      sqlite3_free(zTab);
    end;

    if rc = SQLITE_OK then
      rc := sqlite3_declare_vtab(db, 'CREATE TABLE x(word,distance,ruleset)');
    if rc <> SQLITE_OK then begin
      fuzzerDisconnect(PSqlite3Vtab(pNew));
      pNew := nil;
    end else
      sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS, 0);
  end;

  ppVtab^ := PSqlite3Vtab(pNew);
  Result := rc;
end;

{ fuzzer.c:556..566 — xOpen. }
function fuzzerOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  p    : PFuzzerVtab;
  pCur : PFuzzerCursor;
begin
  p := PFuzzerVtab(pVTab);
  pCur := PFuzzerCursor(sqlite3_malloc64(u64(SizeOf(TFuzzerCursor))));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TFuzzerCursor), 0);
  pCur^.pVtab := p;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Inc(p^.nCursor);
  Result := SQLITE_OK;
end;

{ fuzzer.c:571..577 — free a stem list. }
procedure fuzzerClearStemList(pStem: PFuzzerStem);
var pNext: PFuzzerStem;
begin
  while pStem <> nil do begin
    pNext := pStem^.pNext;
    sqlite3_free(pStem);
    pStem := pNext;
  end;
end;

{ fuzzer.c:583..597 — drop all stems and reset. }
procedure fuzzerClearCursor(pCur: PFuzzerCursor; clearHash: i32);
var i: i32;
begin
  fuzzerClearStemList(pCur^.pStem);
  fuzzerClearStemList(pCur^.pDone);
  for i := 0 to FUZZER_NQUEUE - 1 do
    fuzzerClearStemList(pCur^.aQueue[i]);
  pCur^.rLimit := 0;
  if (clearHash <> 0) and (pCur^.nStem <> 0) then begin
    pCur^.mxQueue := 0;
    pCur^.pStem := nil;
    pCur^.pDone := nil;
    FillChar(pCur^.aQueue, SizeOf(pCur^.aQueue), 0);
    FillChar(pCur^.apHash, SizeOf(pCur^.apHash), 0);
  end;
  pCur^.nStem := 0;
end;

{ fuzzer.c:602..609 — xClose. }
function fuzzerClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PFuzzerCursor;
begin
  pCur := PFuzzerCursor(cur);
  fuzzerClearCursor(pCur, 0);
  sqlite3_free(pCur^.zBuf);
  Dec(pCur^.pVtab^.nCursor);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ fuzzer.c:614..642 — render the current output term for a stem. }
function fuzzerRender(pStem: PFuzzerStem;
  pzBuf: PPAnsiChar; pnBuf: Pi32): i32;
var
  pRule : PFuzzerRule;
  n     : i64;
  z     : PAnsiChar;
  pNew  : PAnsiChar;
begin
  pRule := pStem^.pRule;
  n := i64(pStem^.nBasis) + i64(pRule^.nTo) - i64(pRule^.nFrom);
  if pnBuf^ < (n + 1) then begin
    pNew := PAnsiChar(sqlite3_realloc64(pzBuf^, u64(n + 100)));
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    pzBuf^ := pNew;
    pnBuf^ := i32(n + 100);
  end;
  n := pStem^.n;
  z := pzBuf^;
  if n < 0 then begin
    memmoveP(z, pStem^.zBasis, NativeUInt(pStem^.nBasis + 1));
  end else begin
    memmoveP(z, pStem^.zBasis, NativeUInt(n));
    memmoveP(z + n, @pRule^.zTo[0], NativeUInt(pRule^.nTo));
    memmoveP(z + n + pRule^.nTo, pStem^.zBasis + n + pRule^.nFrom,
      NativeUInt(pStem^.nBasis - n - pRule^.nFrom + 1));
  end;
  Result := SQLITE_OK;
end;

{ fuzzer.c:647..651 — hash a basis string. }
function fuzzerHash(z: PAnsiChar): u32;
var h: u32;
begin
  h := 0;
  while z^ <> #0 do begin
    h := (h shl 3) xor (h shr 29) xor u32(Byte(z^));
    Inc(z);
  end;
  Result := h mod FUZZER_HASH;
end;

{ fuzzer.c:656..658 — recompute and cache the running cost. }
function fuzzerCost(pStem: PFuzzerStem): i32;
begin
  pStem^.rCostX := pStem^.rBaseCost + pStem^.pRule^.rCost;
  Result := pStem^.rCostX;
end;

{ fuzzer.c:694..707 — has the current rendering already been emitted? }
function fuzzerSeen(pCur: PFuzzerCursor; pStem: PFuzzerStem): i32;
var
  h       : u32;
  pLookup : PFuzzerStem;
begin
  if fuzzerRender(pStem, @pCur^.zBuf, @pCur^.nBuf) = SQLITE_NOMEM then begin
    Result := -1;
    Exit;
  end;
  h := fuzzerHash(pCur^.zBuf);
  pLookup := pCur^.apHash[h];
  while (pLookup <> nil) and (strcmpC(pLookup^.zBasis, pCur^.zBuf) <> 0) do
    pLookup := pLookup^.pHash;
  if pLookup <> nil then Result := 1 else Result := 0;
end;

{ fuzzer.c:717..726 — should this rule be skipped? }
function fuzzerSkipRule(pRule: PFuzzerRule;
  pStem: PFuzzerStem; iRuleset: i32): Boolean;
begin
  Result := (pRule <> nil) and
    ((pRule^.iRuleset <> iRuleset) or
     ((pStem^.nBasis + pRule^.nTo - pRule^.nFrom) > FUZZER_MX_OUTPUT_LENGTH));
end;

{ fuzzer.c:733..759 — advance a stem to its next rewrite. }
function fuzzerAdvance(pCur: PFuzzerCursor; pStem: PFuzzerStem): i32;
var
  pRule : PFuzzerRule;
  rc    : i32;
begin
  pRule := pStem^.pRule;
  while pRule <> nil do begin
    Assert((pRule = @pCur^.nullRule) or (pRule^.iRuleset = pCur^.iRuleset));
    while pStem^.n < (pStem^.nBasis - pRule^.nFrom) do begin
      pStem^.n := pStem^.n + 1;
      if (pRule^.nFrom = 0) or
         (memcmpC(pStem^.zBasis + pStem^.n, pRule^.zFrom, NativeUInt(pRule^.nFrom)) = 0) then
      begin
        rc := fuzzerSeen(pCur, pStem);
        if rc < 0 then begin Result := -1; Exit; end;
        if rc = 0 then begin
          fuzzerCost(pStem);
          Result := 1;
          Exit;
        end;
      end;
    end;
    pStem^.n := -1;
    repeat
      pRule := pRule^.pNext;
    until not fuzzerSkipRule(pRule, pStem, pCur^.iRuleset);
    pStem^.pRule := pRule;
    if (pRule <> nil) and (fuzzerCost(pStem) > pCur^.rLimit) then
      pStem^.pRule := nil;
    pRule := pStem^.pRule;
  end;
  Result := 0;
end;

{ fuzzer.c:766..788 — merge two cost-sorted stem lists. }
function fuzzerMergeStems(pA, pB: PFuzzerStem): PFuzzerStem;
var
  head : TFuzzerStem;
  pTail: PFuzzerStem;
begin
  pTail := @head;
  while (pA <> nil) and (pB <> nil) do begin
    if pA^.rCostX <= pB^.rCostX then begin
      pTail^.pNext := pA;
      pTail := pA;
      pA := pA^.pNext;
    end else begin
      pTail^.pNext := pB;
      pTail := pB;
      pB := pB^.pNext;
    end;
  end;
  if pA = nil then
    pTail^.pNext := pB
  else
    pTail^.pNext := pA;
  Result := head.pNext;
end;

{ fuzzer.c:794..817 — pull the lowest-cost stem out of the queue. }
function fuzzerLowestCostStem(pCur: PFuzzerCursor): PFuzzerStem;
var
  pBest, pX : PFuzzerStem;
  iBest, i  : i32;
begin
  if pCur^.pStem = nil then begin
    iBest := -1;
    pBest := nil;
    for i := 0 to pCur^.mxQueue do begin
      pX := pCur^.aQueue[i];
      if pX = nil then continue;
      if (pBest = nil) or (pBest^.rCostX > pX^.rCostX) then begin
        pBest := pX;
        iBest := i;
      end;
    end;
    if pBest <> nil then begin
      pCur^.aQueue[iBest] := pBest^.pNext;
      pBest^.pNext := nil;
      pCur^.pStem := pBest;
    end;
  end;
  Result := pCur^.pStem;
end;

{ fuzzer.c:825..862 — insert pNew into the priority queue. }
function fuzzerInsert(pCur: PFuzzerCursor; pNew: PFuzzerStem): PFuzzerStem;
var
  pX : PFuzzerStem;
  i  : i32;
begin
  pX := pCur^.pStem;
  if (pX <> nil) and (pX^.rCostX > pNew^.rCostX) then begin
    pNew^.pNext := nil;
    pCur^.pStem := pNew;
    pNew := pX;
  end;

  pNew^.pNext := nil;
  pX := pNew;
  i := 0;
  while i <= pCur^.mxQueue do begin
    if pCur^.aQueue[i] <> nil then begin
      pX := fuzzerMergeStems(pX, pCur^.aQueue[i]);
      pCur^.aQueue[i] := nil;
    end else begin
      pCur^.aQueue[i] := pX;
      Break;
    end;
    Inc(i);
  end;
  if i > pCur^.mxQueue then begin
    if i < FUZZER_NQUEUE then begin
      pCur^.mxQueue := i;
      pCur^.aQueue[i] := pX;
    end else begin
      Assert(pCur^.mxQueue = FUZZER_NQUEUE - 1);
      pX := fuzzerMergeStems(pX, pCur^.aQueue[FUZZER_NQUEUE - 1]);
      pCur^.aQueue[FUZZER_NQUEUE - 1] := pX;
    end;
  end;

  Result := fuzzerLowestCostStem(pCur);
end;

{ fuzzer.c:868..895 — allocate a new stem. }
function fuzzerNewStem(pCur: PFuzzerCursor;
  zWord: PAnsiChar; rBaseCost: i32): PFuzzerStem;
var
  pNew  : PFuzzerStem;
  pRule : PFuzzerRule;
  h     : u32;
  nWord : NativeUInt;
begin
  nWord := strlenC(zWord);
  pNew := PFuzzerStem(sqlite3_malloc64(u64(SizeOf(TFuzzerStem)) + u64(nWord) + 1));
  if pNew = nil then begin Result := nil; Exit; end;
  FillChar(pNew^, SizeOf(TFuzzerStem), 0);
  pNew^.zBasis := PAnsiChar(pNew) + SizeOf(TFuzzerStem);
  pNew^.nBasis := ShortInt(nWord);
  memmoveP(pNew^.zBasis, zWord, nWord + 1);
  pRule := pCur^.pVtab^.pRule;
  while fuzzerSkipRule(pRule, pNew, pCur^.iRuleset) do
    pRule := pRule^.pNext;
  pNew^.pRule := pRule;
  pNew^.n := -1;
  pNew^.rBaseCost := rBaseCost;
  pNew^.rCostX    := rBaseCost;
  h := fuzzerHash(pNew^.zBasis);
  pNew^.pHash := pCur^.apHash[h];
  pCur^.apHash[h] := pNew;
  Inc(pCur^.nStem);
  Result := pNew;
end;

{ fuzzer.c:901..962 — xNext. }
function fuzzerNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur  : PFuzzerCursor;
  pStem : PFuzzerStem;
  pNew  : PFuzzerStem;
  rc    : i32;
  res   : i32;
begin
  pCur := PFuzzerCursor(cur);
  Inc(pCur^.iRowid);

  pStem := pCur^.pStem;
  if pStem^.rCostX > 0 then begin
    rc := fuzzerRender(pStem, @pCur^.zBuf, @pCur^.nBuf);
    if rc = SQLITE_NOMEM then begin Result := SQLITE_NOMEM; Exit; end;
    pNew := fuzzerNewStem(pCur, pCur^.zBuf, pStem^.rCostX);
    if pNew <> nil then begin
      if fuzzerAdvance(pCur, pNew) = 0 then begin
        pNew^.pNext := pCur^.pDone;
        pCur^.pDone := pNew;
      end else begin
        if fuzzerInsert(pCur, pNew) = pNew then begin
          Result := SQLITE_OK;
          Exit;
        end;
      end;
    end else begin
      Result := SQLITE_NOMEM;
      Exit;
    end;
  end;

  pStem := pCur^.pStem;
  while pStem <> nil do begin
    res := fuzzerAdvance(pCur, pStem);
    if res < 0 then begin
      Result := SQLITE_NOMEM;
      Exit;
    end else if res > 0 then begin
      pCur^.pStem := nil;
      pStem := fuzzerInsert(pCur, pStem);
      rc := fuzzerSeen(pCur, pStem);
      if rc <> 0 then begin
        if rc < 0 then begin Result := SQLITE_NOMEM; Exit; end;
        pStem := pCur^.pStem;
        continue;
      end;
      Result := SQLITE_OK;
      Exit;
    end;
    pCur^.pStem := nil;
    pStem^.pNext := pCur^.pDone;
    pCur^.pDone := pStem;
    if fuzzerLowestCostStem(pCur) <> nil then begin
      rc := fuzzerSeen(pCur, pCur^.pStem);
      if rc < 0 then begin Result := SQLITE_NOMEM; Exit; end;
      if rc = 0 then begin
        Result := SQLITE_OK;
        Exit;
      end;
    end;
    pStem := pCur^.pStem;
  end;

  pCur^.rLimit := 0;
  Result := SQLITE_OK;
end;

{ fuzzer.c:969..1014 — xFilter. }
function fuzzerFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur  : PFuzzerCursor;
  zWord : PAnsiChar;
  pStem : PFuzzerStem;
  idx   : i32;
  pArg  : PPsqlite3_value;
begin
  pCur := PFuzzerCursor(pVtabCursor);
  zWord := PAnsiChar('');
  fuzzerClearCursor(pCur, 1);
  pCur^.rLimit := $7FFFFFFF;
  idx := 0;
  pArg := argv;
  if (idxNum and 1) <> 0 then begin
    zWord := PAnsiChar(sqlite3_value_text(pArg^));
    if zWord = nil then zWord := PAnsiChar('');
    Inc(pArg);
    Inc(idx);
  end;
  if (idxNum and 2) <> 0 then begin
    pCur^.rLimit := sqlite3_value_int(pArg^);
    Inc(pArg);
    Inc(idx);
  end;
  if (idxNum and 4) <> 0 then begin
    pCur^.iRuleset := sqlite3_value_int(pArg^);
    Inc(pArg);
    Inc(idx);
  end;
  pCur^.nullRule.pNext    := pCur^.pVtab^.pRule;
  pCur^.nullRule.rCost    := 0;
  pCur^.nullRule.nFrom    := 0;
  pCur^.nullRule.nTo      := 0;
  pCur^.nullRule.zFrom    := PAnsiChar('');
  pCur^.iRowid := 1;
  Assert(pCur^.pStem = nil);

  if i32(strlenC(zWord)) < FUZZER_MX_OUTPUT_LENGTH then begin
    pStem := fuzzerNewStem(pCur, zWord, 0);
    pCur^.pStem := pStem;
    if pStem = nil then begin Result := SQLITE_NOMEM; Exit; end;
    pStem^.pRule := @pCur^.nullRule;
    pStem^.n := pStem^.nBasis;
  end else begin
    pCur^.rLimit := 0;
  end;

  Result := SQLITE_OK;
end;

{ fuzzer.c:1020..1036 — xColumn. }
function fuzzerColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var pCur: PFuzzerCursor;
begin
  pCur := PFuzzerCursor(cur);
  if i = 0 then begin
    if fuzzerRender(pCur^.pStem, @pCur^.zBuf, @pCur^.nBuf) = SQLITE_NOMEM then begin
      Result := SQLITE_NOMEM;
      Exit;
    end;
    sqlite3_result_text(ctx, pCur^.zBuf, -1, SQLITE_TRANSIENT);
  end else if i = 1 then begin
    sqlite3_result_int(ctx, pCur^.pStem^.rCostX);
  end else
    sqlite3_result_null(ctx);
  Result := SQLITE_OK;
end;

{ fuzzer.c:1041..1045 — xRowid. }
function fuzzerRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PFuzzerCursor;
begin
  pCur := PFuzzerCursor(cur);
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

{ fuzzer.c:1051..1054 — xEof. }
function fuzzerEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PFuzzerCursor;
begin
  pCur := PFuzzerCursor(cur);
  if pCur^.rLimit <= 0 then Result := 1 else Result := 0;
end;

{ fuzzer.c:1078..1142 — xBestIndex. }
function fuzzerBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  iPlan        : i32;
  iDistTerm    : i32;
  iRulesetTerm : i32;
  i, idx       : i32;
  seenMatch    : i32;
  pC           : PSqlite3IndexConstraint;
  pUse         : PSqlite3IndexConstraintUsage;
  pOrder       : PSqlite3IndexOrderBy;
  rCost        : Double;
begin
  iPlan        := 0;
  iDistTerm    := -1;
  iRulesetTerm := -1;
  seenMatch    := 0;
  rCost        := 1e12;

  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if (pC^.iColumn = 0) and (pC^.op = SQLITE_INDEX_CONSTRAINT_MATCH) then
      seenMatch := 1;
    if pC^.usable <> 0 then begin
      if ((iPlan and 1) = 0)
         and (pC^.iColumn = 0)
         and (pC^.op = SQLITE_INDEX_CONSTRAINT_MATCH) then
      begin
        iPlan := iPlan or 1;
        pUse := pIdxInfo^.aConstraintUsage; Inc(pUse, i);
        pUse^.argvIndex := 1;
        pUse^.omit := 1;
        rCost := rCost / 1e6;
      end;
      if ((iPlan and 2) = 0)
         and (pC^.iColumn = 1)
         and ((pC^.op = SQLITE_INDEX_CONSTRAINT_LT)
              or (pC^.op = SQLITE_INDEX_CONSTRAINT_LE)) then
      begin
        iPlan := iPlan or 2;
        iDistTerm := i;
        rCost := rCost / 10.0;
      end;
      if ((iPlan and 4) = 0)
         and (pC^.iColumn = 2)
         and (pC^.op = SQLITE_INDEX_CONSTRAINT_EQ) then
      begin
        iPlan := iPlan or 4;
        pUse := pIdxInfo^.aConstraintUsage; Inc(pUse, i);
        pUse^.omit := 1;
        iRulesetTerm := i;
        rCost := rCost / 10.0;
      end;
    end;
    Inc(pC);
  end;

  if (iPlan and 2) <> 0 then begin
    pUse := pIdxInfo^.aConstraintUsage; Inc(pUse, iDistTerm);
    if (iPlan and 1) <> 0 then pUse^.argvIndex := 2 else pUse^.argvIndex := 1;
  end;
  if (iPlan and 4) <> 0 then begin
    idx := 1;
    if (iPlan and 1) <> 0 then Inc(idx);
    if (iPlan and 2) <> 0 then Inc(idx);
    pUse := pIdxInfo^.aConstraintUsage; Inc(pUse, iRulesetTerm);
    pUse^.argvIndex := idx;
  end;
  pIdxInfo^.idxNum := iPlan;
  if (pIdxInfo^.nOrderBy = 1) then begin
    pOrder := pIdxInfo^.aOrderBy;
    if (pOrder^.iColumn = 1) and (pOrder^.desc = 0) then
      pIdxInfo^.orderByConsumed := 1;
  end;
  if (seenMatch <> 0) and ((iPlan and 1) = 0) then rCost := 1e99;
  pIdxInfo^.estimatedCost := rCost;

  Result := SQLITE_OK;
end;

function sqlite3FuzzerInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'fuzzer', @fuzzerModule, nil);
end;

initialization
  FillChar(fuzzerModule, SizeOf(fuzzerModule), 0);
  fuzzerModule.iVersion    := 0;
  fuzzerModule.xCreate     := @fuzzerConnect;
  fuzzerModule.xConnect    := @fuzzerConnect;
  fuzzerModule.xBestIndex  := @fuzzerBestIndex;
  fuzzerModule.xDisconnect := @fuzzerDisconnect;
  fuzzerModule.xDestroy    := @fuzzerDisconnect;
  fuzzerModule.xOpen       := @fuzzerOpen;
  fuzzerModule.xClose      := @fuzzerClose;
  fuzzerModule.xFilter     := @fuzzerFilter;
  fuzzerModule.xNext       := @fuzzerNext;
  fuzzerModule.xEof        := @fuzzerEof;
  fuzzerModule.xColumn     := @fuzzerColumn;
  fuzzerModule.xRowid      := @fuzzerRowid;
end.
