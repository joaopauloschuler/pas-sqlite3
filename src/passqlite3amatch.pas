{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/amatch.c (1502 lines in C).

  Provides the `approximate_match` virtual table — a demonstration vtab
  that finds strings from a finite vocabulary that are nearly the same
  as a single user-supplied input string, ranked by edit-distance under
  a costed character-rewrite ruleset.  Created via:

      CREATE VIRTUAL TABLE f USING approximate_match(
        vocabulary_table=<tablename>,      -- V
        vocabulary_word=<columnname>,      -- W
        vocabulary_language=<columnname>,  -- L (optional)
        edit_distances=<edit-cost-table>
      );

  Queried as:

      SELECT word, distance FROM f
       WHERE word MATCH 'abcdefg'
         AND distance<200;

  Read-only.  Output is sorted by increasing distance.

  Public entry: sqlite3AmatchInit(db) — equivalent to
  sqlite3_amatch_init() in the C extension.

  Same caveat as the prior eponymous-vtab series (10.1.69, 10.1.71,
  10.1.72, 10.1.77, 10.1.80, 10.1.83, 10.1.86, 10.1.92): the Pascal
  port does not yet wire vtab xBestIndex MATCH-constraint pushdown,
  so a bare `… WHERE word MATCH 'abc'` may not flow the constraint
  through; the module itself is faithful end-to-end.
}
{$I passqlite3.inc}
unit passqlite3amatch;

interface

uses
  SysUtils,
  Strings,
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3AmatchInit(db: PTsqlite3): i32;

implementation

const
  AMATCH_MX_LENGTH = 50;          { amatch.c:459 }
  AMATCH_MX_LANGID = $7FFFFFFF;   { amatch.c:460 }
  AMATCH_MX_COST   = 1000;        { amatch.c:461 }

  AMATCH_COL_WORD     = 0;
  AMATCH_COL_DISTANCE = 1;
  AMATCH_COL_LANGUAGE = 2;
  AMATCH_COL_COMMAND  = 3;
  AMATCH_COL_NWORD    = 4;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  PAmatchAvl  = ^TAmatchAvl;
  PAmatchWord = ^TAmatchWord;
  PAmatchRule = ^TAmatchRule;
  PAmatchVtab = ^TAmatchVtab;
  PAmatchCursor = ^TAmatchCursor;
  PPAmatchAvl = ^PAmatchAvl;

  { amatch.c:186..194 — string-keyed AVL node. }
  TAmatchAvl = record
    pWord     : PAmatchWord;
    zKey      : PAnsiChar;
    pBefore   : PAmatchAvl;
    pAfter    : PAmatchAvl;
    pUp       : PAmatchAvl;
    height    : SmallInt;
    imbalance : SmallInt;
  end;

  { amatch.c:466..475 — a match or partial match.  Variable-length zWord
    appended past the end of the record. }
  TAmatchWord = record
    pNext   : PAmatchWord;
    sCost   : TAmatchAvl;
    sWord   : TAmatchAvl;
    rCost   : i32;
    iSeq    : i32;
    zCost   : array[0..9] of AnsiChar;
    nMatch  : SmallInt;
    zWord   : array[0..3] of AnsiChar;
  end;

  { amatch.c:481..488 — costed character transformation rule.
    Variable-length: SizeOf(TAmatchRule) + nFrom + nTo bytes allocated;
    zFrom is set to @zTo[nTo+1]. }
  TAmatchRule = record
    pNext    : PAmatchRule;
    zFrom    : PAnsiChar;
    rCost    : i32;
    iLang    : i32;
    nFrom    : ShortInt;
    nTo      : ShortInt;
    zTo      : array[0..3] of AnsiChar;
  end;

  TAmatchVtab = record
    base       : Tsqlite3_vtab;
    zClassName : PAnsiChar;
    zDb        : PAnsiChar;
    zSelf      : PAnsiChar;
    zCostTab   : PAnsiChar;
    zVocabTab  : PAnsiChar;
    zVocabWord : PAnsiChar;
    zVocabLang : PAnsiChar;
    pRule      : PAmatchRule;
    rIns       : i32;
    rDel       : i32;
    rSub       : i32;
    db         : PTsqlite3;
    pVCheck    : Pointer;
    nCursor    : i32;
  end;

  TAmatchCursor = record
    base      : Tsqlite3_vtab_cursor;
    iRowid    : i64;
    iLang     : i32;
    rLimit    : i32;
    nBuf      : i64;
    oomErr    : i32;
    nWord     : i32;
    zBuf      : PAnsiChar;
    zInput    : PAnsiChar;
    pVtab     : PAmatchVtab;
    pAllWords : PAmatchWord;
    pCurrent  : PAmatchWord;
    pCost     : PAmatchAvl;
    pWord     : PAmatchAvl;
  end;

var
  amatchModule: Tsqlite3_module;

{ 6.40.1.p.2.3 — strlen/strcmp/strncmp/memcmp externals replaced with FPC RTL:
  StrLen / StrComp / StrLComp / CompareByte. }

procedure memmoveP(dst, src: Pointer; n: NativeUInt);
begin
  if n > 0 then Move(src^, dst^, n);
end;

{ ---------------------------------------------------------------------------
  AVL tree keyed by C string (amatch.c:198..437)
  --------------------------------------------------------------------------- }

procedure amatchAvlRecomputeHeight(p: PAmatchAvl);
var hBefore, hAfter: SmallInt;
begin
  if p^.pBefore <> nil then hBefore := p^.pBefore^.height else hBefore := 0;
  if p^.pAfter  <> nil then hAfter  := p^.pAfter^.height  else hAfter  := 0;
  p^.imbalance := hBefore - hAfter;
  if hBefore > hAfter then p^.height := hBefore + 1
                      else p^.height := hAfter + 1;
end;

function amatchAvlRotateBefore(pP: PAmatchAvl): PAmatchAvl;
var pB, pY: PAmatchAvl;
begin
  pB := pP^.pBefore;
  pY := pB^.pAfter;
  pB^.pUp     := pP^.pUp;
  pB^.pAfter  := pP;
  pP^.pUp     := pB;
  pP^.pBefore := pY;
  if pY <> nil then pY^.pUp := pP;
  amatchAvlRecomputeHeight(pP);
  amatchAvlRecomputeHeight(pB);
  Result := pB;
end;

function amatchAvlRotateAfter(pP: PAmatchAvl): PAmatchAvl;
var pA, pY: PAmatchAvl;
begin
  pA := pP^.pAfter;
  pY := pA^.pBefore;
  pA^.pUp     := pP^.pUp;
  pA^.pBefore := pP;
  pP^.pUp     := pA;
  pP^.pAfter  := pY;
  if pY <> nil then pY^.pUp := pP;
  amatchAvlRecomputeHeight(pP);
  amatchAvlRecomputeHeight(pA);
  Result := pA;
end;

function amatchAvlFromPtr(p: PAmatchAvl; pp: PPAmatchAvl): PPAmatchAvl;
var pUp: PAmatchAvl;
begin
  pUp := p^.pUp;
  if pUp = nil then begin Result := pp; Exit; end;
  if pUp^.pAfter = p then Result := @pUp^.pAfter
                     else Result := @pUp^.pBefore;
end;

function amatchAvlBalance(p: PAmatchAvl): PAmatchAvl;
var
  pTop: PAmatchAvl;
  pp: PPAmatchAvl;
  pB, pA: PAmatchAvl;
begin
  pTop := p;
  while p <> nil do begin
    amatchAvlRecomputeHeight(p);
    if p^.imbalance >= 2 then begin
      pB := p^.pBefore;
      if pB^.imbalance < 0 then p^.pBefore := amatchAvlRotateAfter(pB);
      pp := amatchAvlFromPtr(p, @p);
      p  := amatchAvlRotateBefore(p);
      pp^ := p;
    end else if p^.imbalance <= (-2) then begin
      pA := p^.pAfter;
      if pA^.imbalance > 0 then p^.pAfter := amatchAvlRotateBefore(pA);
      pp := amatchAvlFromPtr(p, @p);
      p  := amatchAvlRotateAfter(p);
      pp^ := p;
    end;
    pTop := p;
    p := p^.pUp;
  end;
  Result := pTop;
end;

function amatchAvlSearch(p: PAmatchAvl; zKey: PAnsiChar): PAmatchAvl;
var c: i32;
begin
  while p <> nil do begin
    c := StrComp(zKey, p^.zKey);
    if c = 0 then Break;
    if c < 0 then p := p^.pBefore
             else p := p^.pAfter;
  end;
  Result := p;
end;

function amatchAvlFirst(p: PAmatchAvl): PAmatchAvl;
begin
  if p <> nil then
    while p^.pBefore <> nil do p := p^.pBefore;
  Result := p;
end;

function amatchAvlInsert(ppHead: PPAmatchAvl; pNew: PAmatchAvl): PAmatchAvl;
var
  p: PAmatchAvl;
  c: i32;
begin
  p := ppHead^;
  if p = nil then begin
    p := pNew;
    pNew^.pUp := nil;
  end else begin
    while p <> nil do begin
      c := StrComp(pNew^.zKey, p^.zKey);
      if c < 0 then begin
        if p^.pBefore <> nil then
          p := p^.pBefore
        else begin
          p^.pBefore := pNew;
          pNew^.pUp  := p;
          break;
        end;
      end else if c > 0 then begin
        if p^.pAfter <> nil then
          p := p^.pAfter
        else begin
          p^.pAfter := pNew;
          pNew^.pUp := p;
          break;
        end;
      end else begin
        Result := p;
        Exit;
      end;
    end;
  end;
  pNew^.pBefore   := nil;
  pNew^.pAfter    := nil;
  pNew^.height    := 1;
  pNew^.imbalance := 0;
  ppHead^ := amatchAvlBalance(p);
  Result := nil;
end;

procedure amatchAvlRemove(ppHead: PPAmatchAvl; pOld: PAmatchAvl);
var
  ppParent: PPAmatchAvl;
  pBalance: PAmatchAvl;
  pX, pY: PAmatchAvl;
begin
  pBalance := nil;
  ppParent := amatchAvlFromPtr(pOld, ppHead);
  if (pOld^.pBefore = nil) and (pOld^.pAfter = nil) then begin
    ppParent^ := nil;
    pBalance := pOld^.pUp;
  end else if (pOld^.pBefore <> nil) and (pOld^.pAfter <> nil) then begin
    pX := amatchAvlFirst(pOld^.pAfter);
    amatchAvlFromPtr(pX, nil)^ := pX^.pAfter;
    if pX^.pAfter <> nil then pX^.pAfter^.pUp := pX^.pUp;
    pBalance := pX^.pUp;
    pX^.pAfter := pOld^.pAfter;
    if pX^.pAfter <> nil then
      pX^.pAfter^.pUp := pX
    else begin
      Assert(pBalance = pOld);
      pBalance := pX;
    end;
    pY := pOld^.pBefore;
    pX^.pBefore := pY;
    if pY <> nil then pY^.pUp := pX;
    pX^.pUp := pOld^.pUp;
    ppParent^ := pX;
  end else if pOld^.pBefore = nil then begin
    pBalance := pOld^.pAfter;
    ppParent^ := pBalance;
    pBalance^.pUp := pOld^.pUp;
  end else if pOld^.pAfter = nil then begin
    pBalance := pOld^.pBefore;
    ppParent^ := pBalance;
    pBalance^.pUp := pOld^.pUp;
  end;
  ppHead^ := amatchAvlBalance(pBalance);
  pOld^.pUp := nil;
  pOld^.pBefore := nil;
  pOld^.pAfter := nil;
end;

{ ---------------------------------------------------------------------------
  Rule list helpers (amatch.c:534..725)
  --------------------------------------------------------------------------- }

function amatchMergeRules(pA, pB: PAmatchRule): PAmatchRule;
var
  head : TAmatchRule;
  pTail: PAmatchRule;
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
  if pA = nil then pTail^.pNext := pB
              else pTail^.pNext := pA;
  Result := head.pNext;
end;

function amatchLoadOneRule(p: PAmatchVtab; pStmt: Pointer;
  out ppRule: PAmatchRule; out pzErr: PAnsiChar): i32;
var
  iLang : i64;
  zFrom, zTo : PAnsiChar;
  rCost : i32;
  rc, nFrom, nTo : i32;
  pRule : PAmatchRule;
  pToBase : PAnsiChar;
begin
  iLang := sqlite3_column_int64(PVdbe(pStmt), 0);
  zFrom := PAnsiChar(sqlite3_column_text(PVdbe(pStmt), 1));
  zTo   := PAnsiChar(sqlite3_column_text(PVdbe(pStmt), 2));
  rCost := sqlite3_column_int(PVdbe(pStmt), 3);

  rc := SQLITE_OK;
  pRule := nil;

  if zFrom = nil then zFrom := PAnsiChar('');
  if zTo   = nil then zTo   := PAnsiChar('');
  nFrom := i32(StrLen(zFrom));
  nTo   := i32(StrLen(zTo));

  { Silently ignore null transformations, but capture rSub for "?"="?". }
  if StrComp(zFrom, zTo) = 0 then begin
    if (zFrom[0] = '?') and (zFrom[1] = #0) then begin
      if (p^.rSub = 0) or (p^.rSub > rCost) then p^.rSub := rCost;
    end;
    ppRule := nil;
    Result := SQLITE_OK;
    Exit;
  end;

  if (rCost <= 0) or (rCost > AMATCH_MX_COST) then begin
    pzErr := PAnsiChar(sqlite3StrDup(PChar(Format(
      '%s: cost must be between 1 and %d',
      [StrPas(p^.zClassName), AMATCH_MX_COST]))));
    rc := SQLITE_ERROR;
  end else
  if (nFrom > AMATCH_MX_LENGTH) or (nTo > AMATCH_MX_LENGTH) then begin
    pzErr := PAnsiChar(sqlite3StrDup(PChar(Format(
      '%s: maximum string length is %d',
      [StrPas(p^.zClassName), AMATCH_MX_LENGTH]))));
    rc := SQLITE_ERROR;
  end else
  if (iLang < 0) or (iLang > AMATCH_MX_LANGID) then begin
    pzErr := PAnsiChar(sqlite3StrDup(PChar(Format(
      '%s: iLang must be between 0 and %d',
      [StrPas(p^.zClassName), AMATCH_MX_LANGID]))));
    rc := SQLITE_ERROR;
  end else
  if (StrComp(zFrom, '') = 0) and (StrComp(zTo, '?') = 0) then begin
    if (p^.rIns = 0) or (p^.rIns > rCost) then p^.rIns := rCost;
  end else
  if (StrComp(zFrom, '?') = 0) and (StrComp(zTo, '') = 0) then begin
    if (p^.rDel = 0) or (p^.rDel > rCost) then p^.rDel := rCost;
  end else begin
    pRule := PAmatchRule(sqlite3_malloc64(u64(SizeOf(TAmatchRule)) +
                                          u64(nFrom) + u64(nTo)));
    if pRule = nil then
      rc := SQLITE_NOMEM
    else begin
      FillChar(pRule^, SizeOf(TAmatchRule), 0);
      pToBase := @pRule^.zTo[0];
      pRule^.zFrom := pToBase + nTo + 1;
      pRule^.nFrom := ShortInt(nFrom);
      memmoveP(pRule^.zFrom, zFrom, NativeUInt(nFrom + 1));
      memmoveP(pToBase,      zTo,   NativeUInt(nTo + 1));
      pRule^.nTo := ShortInt(nTo);
      pRule^.rCost := rCost;
      pRule^.iLang := i32(iLang);
    end;
  end;

  ppRule := pRule;
  Result := rc;
end;

procedure amatchFreeRules(p: PAmatchVtab);
var pRule: PAmatchRule;
begin
  while p^.pRule <> nil do begin
    pRule := p^.pRule;
    p^.pRule := pRule^.pNext;
    sqlite3_free(pRule);
  end;
  p^.pRule := nil;
end;

function amatchLoadRules(db: PTsqlite3; p: PAmatchVtab;
  out pzErr: PAnsiChar): i32;
var
  rc, rc2: i32;
  zSql: PAnsiChar;
  pStmt: Pointer;
  pHead, pX, pRule: PAmatchRule;
  i: i32;
  a: array[0..14] of PAmatchRule;
begin
  rc := SQLITE_OK;
  pHead := nil;
  pStmt := nil;

  zSql := sqlite3PfMprintf('SELECT * FROM %Q.%Q', [p^.zDb, p^.zCostTab]);
  if zSql = nil then begin Result := SQLITE_NOMEM; Exit; end;

  rc := sqlite3_prepare_v2(db, zSql, -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin
    pzErr := PAnsiChar(sqlite3StrDup(PChar(Format('%s: %s',
      [StrPas(p^.zClassName), StrPas(sqlite3_errmsg(db))]))));
  end else if sqlite3_column_count(PVdbe(pStmt)) <> 4 then begin
    pzErr := PAnsiChar(sqlite3StrDup(PChar(Format('%s: %s has %d columns, expected 4',
      [StrPas(p^.zClassName), StrPas(p^.zCostTab),
       sqlite3_column_count(PVdbe(pStmt))]))));
    rc := SQLITE_ERROR;
  end else begin
    while (rc = SQLITE_OK) and (sqlite3_step(PVdbe(pStmt)) = SQLITE_ROW) do begin
      pRule := nil;
      rc := amatchLoadOneRule(p, pStmt, pRule, pzErr);
      if pRule <> nil then begin
        pRule^.pNext := pHead;
        pHead := pRule;
      end;
    end;
  end;

  rc2 := sqlite3_finalize(PVdbe(pStmt));
  if rc = SQLITE_OK then rc := rc2;
  sqlite3_free(zSql);

  if rc = SQLITE_OK then begin
    for i := 0 to High(a) do a[i] := nil;
    while pHead <> nil do begin
      pX := pHead;
      pHead := pX^.pNext;
      pX^.pNext := nil;
      i := 0;
      while (a[i] <> nil) and (i < High(a)) do begin
        pX := amatchMergeRules(a[i], pX);
        a[i] := nil;
        Inc(i);
      end;
      a[i] := amatchMergeRules(a[i], pX);
    end;
    pX := a[0];
    for i := 1 to High(a) do
      pX := amatchMergeRules(a[i], pX);
    p^.pRule := amatchMergeRules(p^.pRule, pX);
  end else begin
    Assert(p^.pRule = nil);
    p^.pRule := pHead;
  end;

  Result := rc;
end;

{ amatch.c:740..764 — dequote a SQL-quoted string. }
function amatchDequote(zIn: PAnsiChar): PAnsiChar;
var
  nIn: i64;
  zOut: PAnsiChar;
  q: AnsiChar;
  iIn, iOut: i32;
begin
  nIn := i64(StrLen(zIn));
  zOut := PAnsiChar(sqlite3_malloc64(u64(nIn + 1)));
  if zOut <> nil then begin
    q := zIn[0];
    if (q <> '[') and (q <> '''') and (q <> '"') and (q <> '`') then begin
      memmoveP(zOut, zIn, NativeUInt(nIn + 1));
    end else begin
      if q = '[' then q := ']';
      iOut := 0;
      iIn := 1;
      while iIn < nIn do begin
        if zIn[iIn] = q then Inc(iIn);
        zOut[iOut] := zIn[iIn];
        Inc(iOut);
        Inc(iIn);
      end;
      zOut[iOut] := #0;
    end;
  end;
  Result := zOut;
end;

procedure amatchVCheckClear(p: PAmatchVtab);
begin
  if p^.pVCheck <> nil then begin
    sqlite3_finalize(PVdbe(p^.pVCheck));
    p^.pVCheck := nil;
  end;
end;

procedure amatchFree(p: PAmatchVtab);
begin
  if p <> nil then begin
    amatchFreeRules(p);
    amatchVCheckClear(p);
    sqlite3_free(p^.zClassName);
    sqlite3_free(p^.zDb);
    sqlite3_free(p^.zCostTab);
    sqlite3_free(p^.zVocabTab);
    sqlite3_free(p^.zVocabWord);
    sqlite3_free(p^.zVocabLang);
    sqlite3_free(p^.zSelf);
    FillChar(p^, SizeOf(TAmatchVtab), 0);
    sqlite3_free(p);
  end;
end;

function amatchDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
var p: PAmatchVtab;
begin
  p := PAmatchVtab(pVtab);
  Assert(p^.nCursor = 0);
  amatchFree(p);
  Result := SQLITE_OK;
end;

{ amatch.c:813..824 — KEY = VALUE parser. }
function amatchValueOfKey(zKey, zStr: PAnsiChar): PAnsiChar;
var
  nKey, nStr, i: i32;
begin
  nKey := i32(StrLen(zKey));
  nStr := i32(StrLen(zStr));
  if nStr < nKey + 1 then begin Result := nil; Exit; end;
  if CompareByte(zStr^, zKey^, nKey) <> 0 then begin Result := nil; Exit; end;
  i := nKey;
  while (i < nStr) and (zStr[i] in [' ', #9, #10, #11, #12, #13]) do Inc(i);
  if (i >= nStr) or (zStr[i] <> '=') then begin Result := nil; Exit; end;
  Inc(i);
  while (i < nStr) and (zStr[i] in [' ', #9, #10, #11, #12, #13]) do Inc(i);
  Result := zStr + i;
end;

{ amatch.c:834..923 — xConnect / xCreate. }
function amatchConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
label
  ErrorExit;
var
  rc: i32;
  pNew: PAmatchVtab;
  zModule, zDb, zVal: PAnsiChar;
  pArgs: ^PAnsiChar;
  i: i32;
  errOut: PAnsiChar;
begin
  ppVtab^ := nil;
  pNew := PAmatchVtab(sqlite3_malloc64(u64(SizeOf(TAmatchVtab))));
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  rc := SQLITE_NOMEM;
  FillChar(pNew^, SizeOf(TAmatchVtab), 0);
  pNew^.db := db;

  pArgs := argv;
  zModule := pArgs[0];
  zDb     := pArgs[1];
  pNew^.zClassName := sqlite3PfMprintf('%s', [zModule]);
  if pNew^.zClassName = nil then goto ErrorExit;
  pNew^.zDb := sqlite3PfMprintf('%s', [zDb]);
  if pNew^.zDb = nil then goto ErrorExit;
  pNew^.zSelf := sqlite3PfMprintf('%s', [pArgs[2]]);
  if pNew^.zSelf = nil then goto ErrorExit;

  for i := 3 to argc - 1 do begin
    zVal := amatchValueOfKey('vocabulary_table', pArgs[i]);
    if zVal <> nil then begin
      sqlite3_free(pNew^.zVocabTab);
      pNew^.zVocabTab := amatchDequote(zVal);
      if pNew^.zVocabTab = nil then goto ErrorExit;
      Continue;
    end;
    zVal := amatchValueOfKey('vocabulary_word', pArgs[i]);
    if zVal <> nil then begin
      sqlite3_free(pNew^.zVocabWord);
      pNew^.zVocabWord := amatchDequote(zVal);
      if pNew^.zVocabWord = nil then goto ErrorExit;
      Continue;
    end;
    zVal := amatchValueOfKey('vocabulary_language', pArgs[i]);
    if zVal <> nil then begin
      sqlite3_free(pNew^.zVocabLang);
      pNew^.zVocabLang := amatchDequote(zVal);
      if pNew^.zVocabLang = nil then goto ErrorExit;
      Continue;
    end;
    zVal := amatchValueOfKey('edit_distances', pArgs[i]);
    if zVal <> nil then begin
      sqlite3_free(pNew^.zCostTab);
      pNew^.zCostTab := amatchDequote(zVal);
      if pNew^.zCostTab = nil then goto ErrorExit;
      Continue;
    end;
    pzErr^ := sqlite3PfMprintf('unrecognized argument: [%s]'#10, [pArgs[i]]);
    amatchFree(pNew);
    ppVtab^ := nil;
    Result := SQLITE_ERROR;
    Exit;
  end;

  rc := SQLITE_OK;
  if pNew^.zCostTab = nil then begin
    pzErr^ := sqlite3PfMprintf('no edit_distances table specified', []);
    rc := SQLITE_ERROR;
  end else begin
    errOut := nil;
    rc := amatchLoadRules(db, pNew, errOut);
    if errOut <> nil then pzErr^ := errOut;
  end;
  if rc = SQLITE_OK then begin
    sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS, 0);
    rc := sqlite3_declare_vtab(db,
      'CREATE TABLE x(word,distance,language,' +
      'command HIDDEN,nword HIDDEN)');
  end;
  if rc <> SQLITE_OK then begin
    amatchFree(pNew);
    pNew := nil;
  end;
  ppVtab^ := PSqlite3Vtab(pNew);
  Result := rc;
  Exit;

ErrorExit:
  amatchFree(pNew);
  Result := rc;
end;

function amatchOpen(pVTab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  p: PAmatchVtab;
  pCur: PAmatchCursor;
begin
  p := PAmatchVtab(pVTab);
  pCur := PAmatchCursor(sqlite3_malloc64(u64(SizeOf(TAmatchCursor))));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TAmatchCursor), 0);
  pCur^.pVtab := p;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Inc(p^.nCursor);
  Result := SQLITE_OK;
end;

procedure amatchClearCursor(pCur: PAmatchCursor);
var pWord, pNextWord: PAmatchWord;
begin
  pWord := pCur^.pAllWords;
  while pWord <> nil do begin
    pNextWord := pWord^.pNext;
    sqlite3_free(pWord);
    pWord := pNextWord;
  end;
  pCur^.pAllWords := nil;
  sqlite3_free(pCur^.zInput);
  pCur^.zInput := nil;
  sqlite3_free(pCur^.zBuf);
  pCur^.zBuf := nil;
  pCur^.nBuf := 0;
  pCur^.pCost := nil;
  pCur^.pWord := nil;
  pCur^.pCurrent := nil;
  pCur^.rLimit := 1000000;
  pCur^.iLang := 0;
  pCur^.nWord := 0;
end;

function amatchClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PAmatchCursor;
begin
  pCur := PAmatchCursor(cur);
  amatchClearCursor(pCur);
  Dec(pCur^.pVtab^.nCursor);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ amatch.c:976..1000 — base-64 cost-key encoding. }
const
  amatchEncodeAlphabet: array[0..63] of AnsiChar = (
    '0','1','2','3','4','5','6','7','8','9',
    'A','B','C','D','E','F','G','H','I','J',
    'K','L','M','N','O','P','Q','R','S','T',
    'U','V','W','X','Y','Z','^','a','b','c',
    'd','e','f','g','h','i','j','k','l','m',
    'n','o','p','q','r','s','t','u','v','w',
    'x','y','z','~');

procedure amatchEncodeInt(x: i32; z: PAnsiChar);
begin
  z[0] := amatchEncodeAlphabet[(x shr 18) and $3f];
  z[1] := amatchEncodeAlphabet[(x shr 12) and $3f];
  z[2] := amatchEncodeAlphabet[(x shr  6) and $3f];
  z[3] := amatchEncodeAlphabet[ x         and $3f];
end;

procedure amatchWriteCost(pWord: PAmatchWord);
begin
  amatchEncodeInt(pWord^.rCost, @pWord^.zCost[0]);
  amatchEncodeInt(pWord^.iSeq,  @pWord^.zCost[4]);
  pWord^.zCost[8] := #0;
end;

procedure amatchStrcpy(dst, src: PAnsiChar);
begin
  while src^ <> #0 do begin
    dst^ := src^;
    Inc(dst); Inc(src);
  end;
  dst^ := #0;
end;

procedure amatchStrcat(dst, src: PAnsiChar);
begin
  while dst^ <> #0 do Inc(dst);
  amatchStrcpy(dst, src);
end;

{ amatch.c:1022..1096 — add or update an amatch_word. }
procedure amatchAddWord(pCur: PAmatchCursor; rCost, nMatch: i32;
  zWordBase, zWordTail: PAnsiChar);
var
  pWord: PAmatchWord;
  pNode, pOther: PAmatchAvl;
  nBase, nTail: i32;
  zBuf: array[0..3] of AnsiChar;
  pNew: PAnsiChar;
begin
  if rCost > pCur^.rLimit then Exit;
  nBase := i32(StrLen(zWordBase));
  nTail := i32(StrLen(zWordTail));
  if nBase + nTail + 3 > pCur^.nBuf then begin
    pCur^.nBuf := nBase + nTail + 100;
    pNew := PAnsiChar(sqlite3_realloc64(pCur^.zBuf, u64(pCur^.nBuf)));
    if pNew = nil then begin
      pCur^.nBuf := 0;
      Exit;
    end;
    pCur^.zBuf := pNew;
  end;
  amatchEncodeInt(nMatch, @zBuf[0]);
  Move(zBuf[2], pCur^.zBuf^, 2);
  Move(zWordBase^, (pCur^.zBuf + 2)^, nBase);
  Move(zWordTail^, (pCur^.zBuf + 2 + nBase)^, nTail + 1);
  pNode := amatchAvlSearch(pCur^.pWord, pCur^.zBuf);
  if pNode <> nil then begin
    pWord := pNode^.pWord;
    if pWord^.rCost > rCost then begin
      amatchAvlRemove(@pCur^.pCost, @pWord^.sCost);
      pWord^.rCost := rCost;
      amatchWriteCost(pWord);
      pOther := amatchAvlInsert(@pCur^.pCost, @pWord^.sCost);
      Assert(pOther = nil);
    end;
    Exit;
  end;
  pWord := PAmatchWord(sqlite3_malloc64(
    u64(SizeOf(TAmatchWord)) + u64(nBase + nTail) - 1));
  if pWord = nil then Exit;
  FillChar(pWord^, SizeOf(TAmatchWord), 0);
  pWord^.rCost := rCost;
  pWord^.iSeq := pCur^.nWord;
  Inc(pCur^.nWord);
  amatchWriteCost(pWord);
  pWord^.nMatch := SmallInt(nMatch);
  pWord^.pNext := pCur^.pAllWords;
  pCur^.pAllWords := pWord;
  pWord^.sCost.zKey := @pWord^.zCost[0];
  pWord^.sCost.pWord := pWord;
  pOther := amatchAvlInsert(@pCur^.pCost, @pWord^.sCost);
  Assert(pOther = nil);
  pWord^.sWord.zKey := @pWord^.zWord[0];
  pWord^.sWord.pWord := pWord;
  amatchStrcpy(@pWord^.zWord[0], pCur^.zBuf);
  pOther := amatchAvlInsert(@pCur^.pWord, @pWord^.sWord);
  Assert(pOther = nil);
end;

{ amatch.c:1102..1244 — advance the cursor.  This is the heart of the
  approximate-match search. }
function amatchNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PAmatchCursor;
  pWord: PAmatchWord;
  pNode: PAmatchAvl;
  isMatch: i32;
  p: PAmatchVtab;
  nWord: i64;
  rc, i, nNextIn: i32;
  zW: PAnsiChar;
  pRule: PAmatchRule;
  zBuf: PAnsiChar;
  nBuf: i64;
  zNext, zNextIn: array[0..7] of AnsiChar;
  zSql: PAnsiChar;
  pStmt: Pointer;
begin
  pCur := PAmatchCursor(cur);
  pWord := nil;
  isMatch := 0;
  p := pCur^.pVtab;
  zBuf := nil;
  nBuf := 0;

  if p^.pVCheck = nil then begin
    if (p^.zVocabLang <> nil) and (p^.zVocabLang[0] <> #0) then begin
      zSql := sqlite3PfMprintf(
        'SELECT "%w" FROM "%w" WHERE "%w">=?1 AND "%w"=?2 ORDER BY 1',
        [p^.zVocabWord, p^.zVocabTab, p^.zVocabWord, p^.zVocabLang]);
    end else begin
      zSql := sqlite3PfMprintf(
        'SELECT "%w" FROM "%w" WHERE "%w">=?1 ORDER BY 1',
        [p^.zVocabWord, p^.zVocabTab, p^.zVocabWord]);
    end;
    pStmt := nil;
    rc := sqlite3_prepare_v2(p^.db, zSql, -1, @pStmt, nil);
    p^.pVCheck := pStmt;
    sqlite3_free(zSql);
    if rc <> 0 then begin Result := rc; Exit; end;
  end;
  sqlite3_bind_int(PVdbe(p^.pVCheck), 2, pCur^.iLang);

  repeat
    pNode := amatchAvlFirst(pCur^.pCost);
    if pNode = nil then begin
      pWord := nil;
      Break;
    end;
    pWord := pNode^.pWord;
    amatchAvlRemove(@pCur^.pCost, @pWord^.sCost);

    nWord := i64(StrLen(@pWord^.zWord[2]));
    if nWord + 20 > nBuf then begin
      nBuf := nWord + 100;
      zBuf := PAnsiChar(sqlite3_realloc64(zBuf, u64(nBuf)));
      if zBuf = nil then begin Result := SQLITE_NOMEM; Exit; end;
    end;
    amatchStrcpy(zBuf, @pWord^.zWord[2]);
    zNext[0] := #0;
    zNextIn[0] := pCur^.zInput[pWord^.nMatch];
    if zNextIn[0] <> #0 then begin
      i := 1;
      while (i <= 4) and ((Byte(pCur^.zInput[pWord^.nMatch + i]) and $C0) = $80) do begin
        zNextIn[i] := pCur^.zInput[pWord^.nMatch + i];
        Inc(i);
      end;
      zNextIn[i] := #0;
      nNextIn := i;
    end else begin
      nNextIn := 0;
    end;

    if (zNextIn[0] <> #0) and (zNextIn[0] <> '*') then begin
      sqlite3_reset(PVdbe(p^.pVCheck));
      amatchStrcat(zBuf, @zNextIn[0]);
      sqlite3_bind_text(PVdbe(p^.pVCheck), 1, zBuf,
        i32(nWord) + nNextIn, SQLITE_STATIC);
      rc := sqlite3_step(PVdbe(p^.pVCheck));
      if rc = SQLITE_ROW then begin
        zW := PAnsiChar(sqlite3_column_text(PVdbe(p^.pVCheck), 0));
        if (zW <> nil)
           and (StrLComp(zBuf, zW, NativeUInt(nWord + nNextIn)) = 0) then
          amatchAddWord(pCur, pWord^.rCost, pWord^.nMatch + nNextIn, zBuf, '');
      end;
      zBuf[nWord] := #0;
    end;

    while True do begin
      amatchStrcpy(zBuf + nWord, @zNext[0]);
      sqlite3_reset(PVdbe(p^.pVCheck));
      sqlite3_bind_text(PVdbe(p^.pVCheck), 1, zBuf, -1, SQLITE_TRANSIENT);
      rc := sqlite3_step(PVdbe(p^.pVCheck));
      if rc <> SQLITE_ROW then Break;
      zW := PAnsiChar(sqlite3_column_text(PVdbe(p^.pVCheck), 0));
      if zW = nil then Break;
      amatchStrcpy(zBuf + nWord, @zNext[0]);
      if StrLComp(zW, zBuf, NativeUInt(nWord)) <> 0 then Break;
      if ((zNextIn[0] = '*') and (zNextIn[1] = #0))
         or ((zNextIn[0] = #0) and (zW[nWord] = #0)) then begin
        isMatch := 1;
        zNextIn[0] := #0;
        nNextIn := 0;
        Break;
      end;
      zNext[0] := zW[nWord];
      i := 1;
      while (i <= 4) and ((Byte(zW[nWord + i]) and $C0) = $80) do begin
        zNext[i] := zW[nWord + i];
        Inc(i);
      end;
      zNext[i] := #0;
      zBuf[nWord] := #0;
      if p^.rIns > 0 then
        amatchAddWord(pCur, pWord^.rCost + p^.rIns, pWord^.nMatch,
                      zBuf, @zNext[0]);
      if p^.rSub > 0 then
        amatchAddWord(pCur, pWord^.rCost + p^.rSub, pWord^.nMatch + nNextIn,
                      zBuf, @zNext[0]);
      if (p^.rIns < 0) and (p^.rSub < 0) then Break;
      Inc(zNext[i - 1]);  { FIX ME — verbatim from amatch.c:1223 }
    end;
    sqlite3_reset(PVdbe(p^.pVCheck));

    if p^.rDel > 0 then begin
      zBuf[nWord] := #0;
      amatchAddWord(pCur, pWord^.rCost + p^.rDel, pWord^.nMatch + nNextIn,
                    zBuf, '');
    end;

    pRule := p^.pRule;
    while pRule <> nil do begin
      if pRule^.iLang = pCur^.iLang then begin
        if StrLComp(pRule^.zFrom, pCur^.zInput + pWord^.nMatch,
                    NativeUInt(pRule^.nFrom)) = 0 then
          amatchAddWord(pCur, pWord^.rCost + pRule^.rCost,
                        pWord^.nMatch + pRule^.nFrom,
                        @pWord^.zWord[2], @pRule^.zTo[0]);
      end;
      pRule := pRule^.pNext;
    end;
  until isMatch <> 0;
  pCur^.pCurrent := pWord;
  sqlite3_free(zBuf);
  Result := SQLITE_OK;
end;

function amatchFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PAmatchCursor;
  zWord: PAnsiChar;
  idx: i32;
  pArgs: PPsqlite3_value;
begin
  pCur := PAmatchCursor(pVtabCursor);
  zWord := PAnsiChar('*');
  amatchClearCursor(pCur);
  pArgs := argv;
  idx := 0;
  if (idxNum and 1) <> 0 then begin
    zWord := PAnsiChar(sqlite3_value_text(pArgs[0]));
    Inc(idx);
  end;
  if (idxNum and 2) <> 0 then begin
    pCur^.rLimit := sqlite3_value_int(pArgs[idx]);
    Inc(idx);
  end;
  if (idxNum and 4) <> 0 then begin
    pCur^.iLang := sqlite3_value_int(pArgs[idx]);
    Inc(idx);
  end;
  pCur^.zInput := sqlite3PfMprintf('%s', [zWord]);
  if pCur^.zInput = nil then begin Result := SQLITE_NOMEM; Exit; end;
  amatchAddWord(pCur, 0, 0, '', '');
  amatchNext(pVtabCursor);
  Result := SQLITE_OK;
end;

function amatchColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var pCur: PAmatchCursor;
begin
  pCur := PAmatchCursor(cur);
  case i of
    AMATCH_COL_WORD:
      sqlite3_result_text(ctx, @pCur^.pCurrent^.zWord[2], -1, SQLITE_STATIC);
    AMATCH_COL_DISTANCE:
      sqlite3_result_int(ctx, pCur^.pCurrent^.rCost);
    AMATCH_COL_LANGUAGE:
      sqlite3_result_int(ctx, pCur^.iLang);
    AMATCH_COL_NWORD:
      sqlite3_result_int(ctx, pCur^.nWord);
  else
    sqlite3_result_null(ctx);
  end;
  Result := SQLITE_OK;
end;

function amatchRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PAmatchCursor;
begin
  pCur := PAmatchCursor(cur);
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

function amatchEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PAmatchCursor;
begin
  pCur := PAmatchCursor(cur);
  if pCur^.pCurrent = nil then Result := 1 else Result := 0;
end;

{ amatch.c:1352..1410 — bit-vector index plan.
    bit 1: word MATCH $str
    bit 2: distance < $value or distance <= $value
    bit 3: language == $language }
function amatchBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  iPlan, iDistTerm, iLangTerm, i, idx: i32;
  pConstraint: PSqlite3IndexConstraint;
begin
  iPlan := 0;
  iDistTerm := -1;
  iLangTerm := -1;
  pConstraint := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if pConstraint^.usable <> 0 then begin
      if ((iPlan and 1) = 0)
         and (pConstraint^.iColumn = 0)
         and (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_MATCH) then
      begin
        iPlan := iPlan or 1;
        pIdxInfo^.aConstraintUsage[i].argvIndex := 1;
        pIdxInfo^.aConstraintUsage[i].omit := 1;
      end;
      if ((iPlan and 2) = 0)
         and (pConstraint^.iColumn = 1)
         and ((pConstraint^.op = SQLITE_INDEX_CONSTRAINT_LT)
           or (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_LE)) then
      begin
        iPlan := iPlan or 2;
        iDistTerm := i;
      end;
      if ((iPlan and 4) = 0)
         and (pConstraint^.iColumn = 2)
         and (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_EQ) then
      begin
        iPlan := iPlan or 4;
        pIdxInfo^.aConstraintUsage[i].omit := 1;
        iLangTerm := i;
      end;
    end;
    Inc(pConstraint);
  end;
  if (iPlan and 2) <> 0 then begin
    if (iPlan and 1) <> 0 then idx := 2 else idx := 1;
    pIdxInfo^.aConstraintUsage[iDistTerm].argvIndex := idx;
  end;
  if (iPlan and 4) <> 0 then begin
    idx := 1;
    if (iPlan and 1) <> 0 then Inc(idx);
    if (iPlan and 2) <> 0 then Inc(idx);
    pIdxInfo^.aConstraintUsage[iLangTerm].argvIndex := idx;
  end;
  pIdxInfo^.idxNum := iPlan;
  if (pIdxInfo^.nOrderBy = 1)
   and (pIdxInfo^.aOrderBy[0].iColumn = 1)
   and (pIdxInfo^.aOrderBy[0].desc = 0) then
    pIdxInfo^.orderByConsumed := 1;
  pIdxInfo^.estimatedCost := 10000.0;
  Result := SQLITE_OK;
end;

{ amatch.c:1418..1449 — xUpdate.  DELETE / UPDATE rejected; INSERT
  accepted only into the hidden command column (and currently a no-op
  in the C source since command parsing was never wired). }
function amatchUpdate(pVTab: PSqlite3Vtab;
  argc: i32; argv: PPsqlite3_value; pRowid: Pi64): i32; cdecl;
var
  p: PAmatchVtab;
  pArgs: PPsqlite3_value;
begin
  p := PAmatchVtab(pVTab);
  pArgs := argv;
  if argc = 1 then begin
    pVTab^.zErrMsg := sqlite3PfMprintf('DELETE from %s is not allowed',
      [p^.zSelf]);
    Result := SQLITE_ERROR;
    Exit;
  end;
  if sqlite3_value_type(pArgs[0]) <> SQLITE_NULL then begin
    pVTab^.zErrMsg := sqlite3PfMprintf('UPDATE of %s is not allowed',
      [p^.zSelf]);
    Result := SQLITE_ERROR;
    Exit;
  end;
  if (sqlite3_value_type(pArgs[2 + AMATCH_COL_WORD]) <> SQLITE_NULL)
   or (sqlite3_value_type(pArgs[2 + AMATCH_COL_DISTANCE]) <> SQLITE_NULL)
   or (sqlite3_value_type(pArgs[2 + AMATCH_COL_LANGUAGE]) <> SQLITE_NULL) then
  begin
    pVTab^.zErrMsg := sqlite3PfMprintf(
      'INSERT INTO %s allowed for column [command] only', [p^.zSelf]);
    Result := SQLITE_ERROR;
    Exit;
  end;
  Result := SQLITE_OK;
end;

function sqlite3AmatchInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'approximate_match',
    @amatchModule, nil);
end;

initialization
  FillChar(amatchModule, SizeOf(amatchModule), 0);
  amatchModule.iVersion    := 0;
  amatchModule.xCreate     := @amatchConnect;
  amatchModule.xConnect    := @amatchConnect;
  amatchModule.xBestIndex  := @amatchBestIndex;
  amatchModule.xDisconnect := @amatchDisconnect;
  amatchModule.xDestroy    := @amatchDisconnect;
  amatchModule.xOpen       := @amatchOpen;
  amatchModule.xClose      := @amatchClose;
  amatchModule.xFilter     := @amatchFilter;
  amatchModule.xNext       := @amatchNext;
  amatchModule.xEof        := @amatchEof;
  amatchModule.xColumn     := @amatchColumn;
  amatchModule.xRowid      := @amatchRowid;
  amatchModule.xUpdate     := @amatchUpdate;
end.
