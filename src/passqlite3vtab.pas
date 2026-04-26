{$I passqlite3.inc}
unit passqlite3vtab;

{
  Phase 6.bis.1a — vtab.c: types + module registry + VTable lifecycle.

  Faithful port of ../sqlite3/src/vtab.c, leaf-helper subset:

    sqlite3VtabCreateModule       (vtab.c:39)   — install a Module
    sqlite3VtabModuleUnref        (vtab.c:162)
    sqlite3VtabLock               (vtab.c:182)
    sqlite3GetVTable              (vtab.c:192)
    sqlite3VtabUnlock             (vtab.c:203)
    vtabDisconnectAll             (vtab.c:229)  — internal
    sqlite3VtabDisconnect         (vtab.c:272)
    sqlite3VtabUnlockList         (vtab.c:310)
    sqlite3VtabClear              (vtab.c:340)
    sqlite3_drop_modules          (vtab.c:140)
    sqlite3VtabEponymousTableClear (stub — full version in 6.bis.1f)

  Public types defined here (mirroring sqlite.h / sqliteInt.h byte layout):
    Tsqlite3_module     (sqlite.h:7684) — 22 function-pointer slots + iVersion
    Tsqlite3_vtab       (sqlite.h:8010)
    Tsqlite3_vtab_cursor (sqlite.h:8034)
    TVTable             (sqliteInt.h:2403) — per-connection vtab instance
    TVtabModule             (sqliteInt.h:2211) — module registry entry
    TVtabCtx            (vtab.c:24)        — declare_vtab/vtab_config context

  Scope of this initial sub-phase (6.bis.1a):
    * The constructor/destructor lifecycle (vtabCallConstructor,
      sqlite3VtabCallCreate, sqlite3VtabCallConnect, sqlite3VtabCallDestroy,
      growVTrans, addToVTrans) is NOT yet ported — wait for 6.bis.1c.
    * The parser-side hooks (sqlite3VtabBeginParse, sqlite3VtabFinishParse,
      sqlite3VtabArgInit, sqlite3VtabArgExtend) remain stubs in
      passqlite3parser; their full bodies land with 6.bis.1b.
    * Per-statement hooks (Sync/Rollback/Commit/Begin/Savepoint/Finaliser)
      land with 6.bis.1d.
    * sqlite3_declare_vtab, sqlite3_vtab_on_conflict, sqlite3_vtab_config
      land with 6.bis.1e.
    * sqlite3VtabOverloadFunction, sqlite3VtabMakeWritable,
      sqlite3VtabEponymousTableInit/Clear (full body) land with 6.bis.1f.

  After this sub-phase, sqlite3_create_module / _v2 in passqlite3main delegate
  to the new sqlite3VtabCreateModule (replacing the inline minimal version
  from Phase 8.3).  Replacement of an existing module now correctly invokes
  sqlite3VtabEponymousTableClear (still a no-op for now) and
  sqlite3VtabModuleUnref, matching the C control flow — only the module's
  destructor and free wait on a future sub-phase to also chase eponymous
  tables.
}

interface

uses
  Strings,
  passqlite3types,
  passqlite3util;

type
  { ----- sqlite.h:7663..7666 — opaque-by-name types ----- }
  PSqlite3Vtab        = ^Tsqlite3_vtab;
  PSqlite3VtabCursor  = ^Tsqlite3_vtab_cursor;
  PSqlite3Module      = ^Tsqlite3_module;
  PSqlite3IndexInfo   = Pointer;       { full type lands with 6.bis.1c }

  { ----- sqlite.h:7684 — sqlite3_module ----- }
  Tsqlite3_module = record
    iVersion       : i32;
    xCreate        : Pointer;  { int (*)(sqlite3*, void*, int, const char*const*, sqlite3_vtab**, char**) }
    xConnect       : Pointer;
    xBestIndex     : Pointer;  { int (*)(sqlite3_vtab*, sqlite3_index_info*) }
    xDisconnect    : function(p: PSqlite3Vtab): i32; cdecl;
    xDestroy       : function(p: PSqlite3Vtab): i32; cdecl;
    xOpen          : Pointer;
    xClose         : Pointer;
    xFilter        : Pointer;
    xNext          : Pointer;
    xEof           : Pointer;
    xColumn        : Pointer;
    xRowid         : Pointer;
    xUpdate        : Pointer;
    xBegin         : Pointer;
    xSync          : Pointer;
    xCommit        : Pointer;
    xRollback      : Pointer;
    xFindFunction  : Pointer;
    xRename        : Pointer;
    { v2 }
    xSavepoint     : Pointer;
    xRelease       : Pointer;
    xRollbackTo    : Pointer;
    { v3 }
    xShadowName    : Pointer;
    { v4 }
    xIntegrity     : Pointer;
  end;

  { ----- sqlite.h:8010 — sqlite3_vtab ----- }
  Tsqlite3_vtab = record
    pModule : PSqlite3Module;
    nRef    : i32;
    _pad    : i32;
    zErrMsg : PAnsiChar;
  end;

  { ----- sqlite.h:8034 — sqlite3_vtab_cursor ----- }
  Tsqlite3_vtab_cursor = record
    pVtab : PSqlite3Vtab;
  end;

  { ----- sqliteInt.h:2403 — VTable ----- }
  PVTable = ^TVTable;
  TVTable = record
    db          : PTsqlite3;
    pMod        : Pointer;       { PVtabModule — forward (declared just below) }
    pVtab       : PSqlite3Vtab;
    nRef        : i32;
    bConstraint : u8;
    bAllSchemas : u8;
    eVtabRisk   : u8;
    _pad        : u8;
    iSavepoint  : i32;
    pNext       : PVTable;
  end;

  { ----- sqliteInt.h:2211 — Module ----- }
  PVtabModule = ^TVtabModule;
  TxModuleDestroy = procedure(p: Pointer); cdecl;
  TVtabModule = record
    pModule    : PSqlite3Module;
    zName      : PAnsiChar;
    nRefModule : i32;
    _pad       : i32;
    pAux       : Pointer;
    xDestroy   : TxModuleDestroy;
    pEpoTab    : Pointer;        { Table* — eponymous table; nil for now }
  end;

  { ----- vtab.c:24 — VtabCtx ----- }
  PVtabCtx = ^TVtabCtx;
  TVtabCtx = record
    pVTable   : PVTable;
    pTab      : Pointer;       { Table* — opaque here }
    pPrior    : PVtabCtx;
    bDeclared : i32;
  end;

const
  { sqliteInt.h:2417 — VTable.eVtabRisk values }
  SQLITE_VTABRISK_Low    = 0;
  SQLITE_VTABRISK_Normal = 1;
  SQLITE_VTABRISK_High   = 2;

{ ============================================================
  Module registry
  ============================================================ }

{ Install a Module object in db^.aModule.  vtab.c:39.  If pModule is nil,
  removes the entry named zName.  Returns the new PVtabModule or nil. }
function sqlite3VtabCreateModule(db: PTsqlite3; zName: PAnsiChar;
  pModule: PSqlite3Module; pAux: Pointer; xDestroy: TxModuleDestroy): PVtabModule;

{ Decrement Module.nRefModule; destroy when it hits zero.  vtab.c:162. }
procedure sqlite3VtabModuleUnref(db: PTsqlite3; pMod: PVtabModule);

{ vtab.c:140 — drop all modules except those on azNames. }
function sqlite3_drop_modules(db: PTsqlite3; azNames: PPAnsiChar): i32; cdecl;

{ ============================================================
  VTable lifecycle (per-connection)
  ============================================================ }

procedure sqlite3VtabLock(pVTab: PVTable);
procedure sqlite3VtabUnlock(pVTab: PVTable);

{ Return the VTable for connection db on Table pTab, or nil.  vtab.c:192. }
function  sqlite3GetVTable(db: PTsqlite3; pTab: Pointer): PVTable;

{ Move every VTable on pTab^.u.vtab.p (other than db's) onto its connection's
  pDisconnect list.  Returns db's VTable (or nil if db is nil).  vtab.c:229. }
function  vtabDisconnectAll(db: PTsqlite3; pTab: Pointer): PVTable;

{ Remove db's VTable from pTab and unlock it.  vtab.c:272. }
procedure sqlite3VtabDisconnect(db: PTsqlite3; pTab: Pointer);

{ Disconnect every VTable on db^.pDisconnect.  vtab.c:310. }
procedure sqlite3VtabUnlockList(db: PTsqlite3);

{ Tear down all vtab state on a Table about to be deleted.  vtab.c:340. }
procedure sqlite3VtabClear(db: PTsqlite3; pTab: Pointer);

{ Eponymous-table cleanup.  Stub for 6.bis.1a — full body in 6.bis.1f.
  Until then, no eponymous tables are ever created, so this is correct. }
procedure sqlite3VtabEponymousTableClear(db: PTsqlite3; pMod: PVtabModule);

implementation

{ ----------------------------------------------------------------------
  Mirror of the codegen TTable layout (passqlite3codegen:979) for the few
  fields vtab.c touches.  We stay independent of passqlite3codegen here to
  avoid a circular unit dependency: codegen already publishes
  PVTable = Pointer, and now this unit owns the real PVTable type.

  The only fields we reach are eTabType (offset 63), u.vtab.p (offset 80),
  u.vtab.azArg (offset 72), u.vtab.nArg (offset 64), nTabRef (offset 44).
  ---------------------------------------------------------------------- }

const
  TAB_OFF_eTabType = 63;
  TAB_OFF_nTabRef  = 44;
  { union u sits at offset 64; vtab variant: nArg @0, azArg @8, p @16 }
  TAB_OFF_uVtab    = 64;
  VTAB_OFF_nArg    = 0;
  VTAB_OFF_azArg   = 8;
  VTAB_OFF_p       = 16;

  TABTYP_NORMAL = 0;
  TABTYP_VTAB   = 1;
  TABTYP_VIEW   = 2;

type
  PPVTable      = ^PVTable;
  PPPAnsiCharL  = ^PPAnsiChar;

function tabIsVirtual(pTab: Pointer): Boolean; inline;
begin
  Result := (pTab <> nil) and ((PByte(pTab) + TAB_OFF_eTabType)^ = TABTYP_VTAB);
end;

function tabVtabPP(pTab: Pointer): PPVTable; inline;
begin
  Result := PPVTable(PByte(pTab) + TAB_OFF_uVtab + VTAB_OFF_p);
end;

function tabVtabAzArgPP(pTab: Pointer): PPPAnsiCharL; inline;
begin
  Result := PPPAnsiCharL(PByte(pTab) + TAB_OFF_uVtab + VTAB_OFF_azArg);
end;

function tabVtabNArg(pTab: Pointer): Pi32; inline;
begin
  Result := Pi32(PByte(pTab) + TAB_OFF_uVtab + VTAB_OFF_nArg);
end;

{ ============================================================
  Module registry
  ============================================================ }

function sqlite3VtabCreateModule(db: PTsqlite3; zName: PAnsiChar;
  pModule: PSqlite3Module; pAux: Pointer; xDestroy: TxModuleDestroy): PVtabModule;
var
  pMod, pDel: PVtabModule;
  zCopy:      PAnsiChar;
  nName:      i32;
begin
  if pModule = nil then begin
    zCopy := zName;
    pMod  := nil;
  end else begin
    nName := sqlite3Strlen30(PChar(zName));
    pMod  := PVtabModule(sqlite3Malloc(SizeOf(TVtabModule) + nName + 1));
    if pMod = nil then begin
      sqlite3OomFault(Psqlite3db(db));
      Result := nil; Exit;
    end;
    zCopy := PAnsiChar(PByte(pMod) + SizeOf(TVtabModule));
    Move(zName^, zCopy^, nName + 1);
    pMod^.zName      := zCopy;
    pMod^.pModule    := pModule;
    pMod^.pAux       := pAux;
    pMod^.xDestroy   := xDestroy;
    pMod^.pEpoTab    := nil;
    pMod^.nRefModule := 1;
  end;
  pDel := PVtabModule(sqlite3HashInsert(@db^.aModule, PChar(zCopy), pMod));
  if pDel <> nil then begin
    if pDel = pMod then begin
      { Hash insert failed (OOM): pMod was returned to us.  Free it. }
      sqlite3OomFault(Psqlite3db(db));
      sqlite3DbFree(Psqlite3db(db), pDel);
      pMod := nil;
    end else begin
      { Replaced an existing module.  vtab.c:75 calls
        sqlite3VtabEponymousTableClear + sqlite3VtabModuleUnref. }
      sqlite3VtabEponymousTableClear(db, pDel);
      sqlite3VtabModuleUnref(db, pDel);
    end;
  end;
  Result := pMod;
end;

procedure sqlite3VtabModuleUnref(db: PTsqlite3; pMod: PVtabModule);
begin
  Assert(pMod^.nRefModule > 0, 'Module nRefModule underflow');
  Dec(pMod^.nRefModule);
  if pMod^.nRefModule = 0 then begin
    if Assigned(pMod^.xDestroy) then pMod^.xDestroy(pMod^.pAux);
    Assert(pMod^.pEpoTab = nil, 'Module pEpoTab leaked');
    sqlite3DbFree(Psqlite3db(db), pMod);
  end;
end;

function sqlite3_drop_modules(db: PTsqlite3; azNames: PPAnsiChar): i32; cdecl;
var
  pThis, pNext: PHashElem;
  pMod:         PVtabModule;
  ii:           i32;
  azp:          PPAnsiChar;
  match:        Boolean;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ELSE}
  if db = nil then begin Result := SQLITE_MISUSE; Exit; end;
{$ENDIF}
  pThis := db^.aModule.first;
  while pThis <> nil do begin
    pNext := PHashElem(pThis^.next);
    pMod  := PVtabModule(pThis^.data);
    if azNames <> nil then begin
      azp   := azNames;
      match := False;
      ii    := 0;
      while azp[ii] <> nil do begin
        if StrComp(azp[ii], pMod^.zName) = 0 then begin
          match := True; Break;
        end;
        Inc(ii);
      end;
      if match then begin
        pThis := pNext; Continue;
      end;
    end;
    sqlite3VtabCreateModule(db, pMod^.zName, nil, nil, nil);
    pThis := pNext;
  end;
  Result := SQLITE_OK;
end;

{ ============================================================
  VTable lifecycle
  ============================================================ }

procedure sqlite3VtabLock(pVTab: PVTable);
begin
  Inc(pVTab^.nRef);
end;

function sqlite3GetVTable(db: PTsqlite3; pTab: Pointer): PVTable;
var
  pVtab: PVTable;
begin
  Assert(tabIsVirtual(pTab), 'sqlite3GetVTable on non-vtab');
  pVtab := tabVtabPP(pTab)^;
  while (pVtab <> nil) and (pVtab^.db <> db) do
    pVtab := pVtab^.pNext;
  Result := pVtab;
end;

procedure sqlite3VtabUnlock(pVTab: PVTable);
var
  db: PTsqlite3;
  p:  PSqlite3Vtab;
begin
  db := pVTab^.db;
  Assert(db <> nil, 'VTable.db nil');
  Assert(pVTab^.nRef > 0, 'VTable nRef underflow');

  Dec(pVTab^.nRef);
  if pVTab^.nRef = 0 then begin
    p := pVTab^.pVtab;
    if p <> nil then begin
      if Assigned(p^.pModule^.xDisconnect) then
        p^.pModule^.xDisconnect(p);
    end;
    sqlite3VtabModuleUnref(pVTab^.db, PVtabModule(pVTab^.pMod));
    sqlite3DbFree(Psqlite3db(db), pVTab);
  end;
end;

function vtabDisconnectAll(db: PTsqlite3; pTab: Pointer): PVTable;
var
  pRet, pVT, pNext: PVTable;
  db2: PTsqlite3;
  ppHead: PPVTable;
begin
  pRet    := nil;
  Assert(tabIsVirtual(pTab), 'vtabDisconnectAll non-vtab');
  ppHead  := tabVtabPP(pTab);
  pVT     := ppHead^;
  ppHead^ := nil;

  while pVT <> nil do begin
    db2   := pVT^.db;
    pNext := pVT^.pNext;
    Assert(db2 <> nil, 'VTable.db nil');
    if db2 = db then begin
      pRet         := pVT;
      ppHead^      := pRet;
      pRet^.pNext  := nil;
    end else begin
      pVT^.pNext      := PVTable(db2^.pDisconnect);
      db2^.pDisconnect := pVT;
    end;
    pVT := pNext;
  end;
  Assert((db = nil) or (pRet <> nil), 'vtabDisconnectAll: db not found');
  Result := pRet;
end;

procedure sqlite3VtabDisconnect(db: PTsqlite3; pTab: Pointer);
var
  ppVTab: PPVTable;
  pVTab:  PVTable;
begin
  Assert(tabIsVirtual(pTab), 'sqlite3VtabDisconnect non-vtab');
  ppVTab := tabVtabPP(pTab);
  while ppVTab^ <> nil do begin
    if ppVTab^^.db = db then begin
      pVTab   := ppVTab^;
      ppVTab^ := pVTab^.pNext;
      sqlite3VtabUnlock(pVTab);
      Break;
    end;
    ppVTab := PPVTable(@(ppVTab^^.pNext));
  end;
end;

procedure sqlite3VtabUnlockList(db: PTsqlite3);
var
  p, pNext: PVTable;
begin
  p := PVTable(db^.pDisconnect);
  if p <> nil then begin
    db^.pDisconnect := nil;
    repeat
      pNext := p^.pNext;
      sqlite3VtabUnlock(p);
      p := pNext;
    until p = nil;
  end;
end;

procedure sqlite3VtabClear(db: PTsqlite3; pTab: Pointer);
var
  azArg: PPAnsiChar;
  i, n:  i32;
begin
  Assert(tabIsVirtual(pTab), 'sqlite3VtabClear non-vtab');
  Assert(db <> nil, 'sqlite3VtabClear db nil');
  if db^.pnBytesFreed = nil then vtabDisconnectAll(nil, pTab);
  azArg := tabVtabAzArgPP(pTab)^;
  if azArg <> nil then begin
    n := tabVtabNArg(pTab)^;
    for i := 0 to n - 1 do begin
      { vtab.c:347: skip i==1 (that slot is the schema name borrowed from
        db^.aDb[iDb].zDbSName, not owned by us). }
      if i <> 1 then sqlite3DbFree(Psqlite3db(db), azArg[i]);
    end;
    sqlite3DbFree(Psqlite3db(db), azArg);
  end;
end;

procedure sqlite3VtabEponymousTableClear(db: PTsqlite3; pMod: PVtabModule);
begin
  { Stub for Phase 6.bis.1a.  Full version in 6.bis.1f will:
      * Look at pMod^.pEpoTab (Table*); if non-nil, delete its columns,
        free the Table struct, and clear pMod^.pEpoTab.
    Until 6.bis.1c lands the constructor lifecycle, no eponymous table
    is ever attached, so pEpoTab is always nil and there is nothing to do. }
  Assert(pMod^.pEpoTab = nil,
    'sqlite3VtabEponymousTableClear: pEpoTab unexpectedly non-nil before 6.bis.1f');
end;

end.
