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
  SysUtils,
  Strings,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser;  { Phase 6.bis.1e: sqlite3GetToken + TK_* + sqlite3RunParser }

type
  { ----- sqlite.h:7663..7666 — opaque-by-name types ----- }
  PSqlite3Vtab        = ^Tsqlite3_vtab;
  PPSqlite3Vtab       = ^PSqlite3Vtab;
  PSqlite3VtabCursor  = ^Tsqlite3_vtab_cursor;
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;
  PSqlite3Module      = ^Tsqlite3_module;
  PSqlite3IndexInfo   = ^Tsqlite3_index_info;

  { ----- sqlite.h:7833 — sqlite3_index_constraint (input) ----- }
  PSqlite3IndexConstraint = ^Tsqlite3_index_constraint;
  Tsqlite3_index_constraint = record
    iColumn      : i32;     { Column constrained.  -1 for ROWID }
    op           : u8;      { Constraint operator }
    usable       : u8;      { True if this constraint is usable }
    _pad         : u16;
    iTermOffset  : i32;     { Used internally - xBestIndex should ignore }
  end;

  { ----- sqlite.h:7840 — sqlite3_index_orderby (input) ----- }
  PSqlite3IndexOrderBy = ^Tsqlite3_index_orderby;
  Tsqlite3_index_orderby = record
    iColumn : i32;
    desc    : u8;     { True for DESC.  False for ASC. }
    _pad0   : u8;
    _pad1   : u16;
  end;

  { ----- sqlite.h:7845 — sqlite3_index_constraint_usage (output) ----- }
  PSqlite3IndexConstraintUsage = ^Tsqlite3_index_constraint_usage;
  Tsqlite3_index_constraint_usage = record
    argvIndex : i32;     { if >0, constraint is part of argv to xFilter }
    omit      : u8;      { Do not code a test for this constraint }
    _pad0     : u8;
    _pad1     : u16;
  end;

  { ----- sqlite.h:7830 — sqlite3_index_info ----- }
  Tsqlite3_index_info = record
    { Inputs }
    nConstraint     : i32;
    aConstraint     : PSqlite3IndexConstraint;
    nOrderBy        : i32;
    aOrderBy        : PSqlite3IndexOrderBy;
    { Outputs }
    aConstraintUsage: PSqlite3IndexConstraintUsage;
    idxNum          : i32;
    idxStr          : PAnsiChar;
    needToFreeIdxStr: i32;
    orderByConsumed : i32;
    estimatedCost   : Double;
    { 3.8.2+ }
    estimatedRows   : i64;
    { 3.9.0+ }
    idxFlags        : i32;
    { 3.10.0+ }
    colUsed         : u64;
  end;

  { ----- typedef for xBestIndex callbacks (vtab modules cast their slot) ----- }
  TxBestIndex = function(pVtab: PSqlite3Vtab; pIdxInfo: PSqlite3IndexInfo): i32; cdecl;

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
    pVTbl   : PVTable;
    pTab      : Pointer;       { Table* — opaque here }
    pPrior    : PVtabCtx;
    bDeclared : i32;
  end;

const
  { sqliteInt.h:2417 — VTable.eVtabRisk values }
  SQLITE_VTABRISK_Low    = 0;
  SQLITE_VTABRISK_Normal = 1;
  SQLITE_VTABRISK_High   = 2;

  { sqlite.h:10273 — sqlite3_vtab_config op codes }
  SQLITE_VTAB_CONSTRAINT_SUPPORT = 1;
  SQLITE_VTAB_INNOCUOUS          = 2;
  SQLITE_VTAB_DIRECTONLY         = 3;
  SQLITE_VTAB_USES_ALL_SCHEMAS   = 4;

  { sqlite.h:7869 — sqlite3_index_info.idxFlags bits }
  SQLITE_INDEX_SCAN_UNIQUE = $00000001;
  SQLITE_INDEX_SCAN_HEX    = $00000002;

  { sqlite.h:7911..7927 — aConstraint[].op codes }
  SQLITE_INDEX_CONSTRAINT_EQ         = 2;
  SQLITE_INDEX_CONSTRAINT_GT         = 4;
  SQLITE_INDEX_CONSTRAINT_LE         = 8;
  SQLITE_INDEX_CONSTRAINT_LT         = 16;
  SQLITE_INDEX_CONSTRAINT_GE         = 32;
  SQLITE_INDEX_CONSTRAINT_MATCH      = 64;
  SQLITE_INDEX_CONSTRAINT_LIKE       = 65;
  SQLITE_INDEX_CONSTRAINT_GLOB       = 66;
  SQLITE_INDEX_CONSTRAINT_REGEXP     = 67;
  SQLITE_INDEX_CONSTRAINT_NE         = 68;
  SQLITE_INDEX_CONSTRAINT_ISNOT      = 69;
  SQLITE_INDEX_CONSTRAINT_ISNOTNULL  = 70;
  SQLITE_INDEX_CONSTRAINT_ISNULL     = 71;
  SQLITE_INDEX_CONSTRAINT_IS         = 72;
  SQLITE_INDEX_CONSTRAINT_LIMIT      = 73;
  SQLITE_INDEX_CONSTRAINT_OFFSET     = 74;
  SQLITE_INDEX_CONSTRAINT_FUNCTION   = 150;

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

{ Eponymous-table cleanup (vtab.c:1298).  Marks pMod^.pEpoTab as Ephemeral
  (so sqlite3DeleteTable knows it is not in the schema) and frees it. }
procedure sqlite3VtabEponymousTableClear(db: PTsqlite3; pMod: PVtabModule);

{ ============================================================
  Constructor lifecycle (Phase 6.bis.1c — vtab.c:557..968)
  ============================================================ }

{ Invoked by the parser to call the xConnect() method of pTab. (vtab.c:697) }
function sqlite3VtabCallConnect(pParse: PParse; pTab: passqlite3codegen.PTable2): i32;

{ Invoked by the VDBE to call xCreate of zTab in db. *pzErr returns an
  English-language description on error.  Caller must sqlite3DbFree pzErr.
  (vtab.c:770) }
function sqlite3VtabCallCreate(db: PTsqlite3; iDb: i32; zTab: PAnsiChar;
  pzErr: PPAnsiChar): i32;

{ Invoked by the VDBE to call xDestroy on a DROP TABLE.  No-op if zTab is
  not a virtual table.  (vtab.c:926) }
function sqlite3VtabCallDestroy(db: PTsqlite3; iDb: i32; zTab: PAnsiChar): i32;

{ ============================================================
  Per-statement transaction hooks (Phase 6.bis.1d — vtab.c:970..1138)
  ============================================================ }

{ vtab.c:998 — invoke xSync on every entry in db^.aVTrans.  pV is the Vdbe
  whose zErrMsg is updated with any error message returned by xSync via
  sqlite3VtabImportErrmsg. }
function sqlite3VtabSync(db: PTsqlite3; pV: PVdbe): i32;

{ vtab.c:1020 — invoke xRollback on every entry, then clear aVTrans. }
function sqlite3VtabRollback(db: PTsqlite3): i32;

{ vtab.c:1029 — invoke xCommit on every entry, then clear aVTrans. }
function sqlite3VtabCommit(db: PTsqlite3): i32;

{ vtab.c:1042 — open a transaction on pVTab if its module supports it and
  one is not already open.  On success appends pVTab to db^.aVTrans. }
function sqlite3VtabBegin(db: PTsqlite3; pVTab: PVTable): i32;

{ vtab.c:1102 — invoke xSavepoint / xRollbackTo / xRelease on every entry
  whose module is iVersion>=2.  op is one of SAVEPOINT_BEGIN /
  SAVEPOINT_ROLLBACK / SAVEPOINT_RELEASE. }
function sqlite3VtabSavepoint(db: PTsqlite3; op, iSavepoint: i32): i32;

{ vtab.c:5673 (vdbeaux.c) — copy pVtab^.zErrMsg into pV^.zErrMsg, freeing
  the previous contents on both sides.  Exposed so 6.bis.2 in-tree vtabs
  can use the same wiring. }
procedure sqlite3VtabImportErrmsg(pV: PVdbe; pVtab: PSqlite3Vtab);

{ ============================================================
  Phase 6.bis.1e — public API entry points (vtab.c:811..1374)
  ============================================================ }

{ vtab.c:811 — sqlite3_declare_vtab.  Called by an xCreate/xConnect
  callback to specify the column layout of a virtual table.  The
  zCreateTable string is parsed as a CREATE TABLE statement and the
  resulting column list is grafted onto the active VtabCtx's pTab.

  IMPORTANT: full column-list grafting requires sqlite3StartTable /
  sqlite3AddColumn / sqlite3EndTable in passqlite3codegen, which are
  still Phase-7 stubs.  Until those land, the parser produces a nil
  sParse.pNewTable for "CREATE TABLE x(...)" and this function falls
  back to flipping pCtx^.bDeclared (so vtabCallConstructor's "did not
  declare schema" check passes) without populating pTab^.aCol.  The
  hidden-column type-string scan (vtab.c:653..682) referenced from
  6.bis.1c remains gated on pTab^.aCol being non-nil.  Tracked under
  6.bis.1e in tasklist.md. }
function sqlite3_declare_vtab(db: PTsqlite3; zCreateTable: PAnsiChar): i32; cdecl;

{ vtab.c:1317 — return the ON CONFLICT resolution mode in effect for
  an in-progress xUpdate.  Maps db^.vtabOnConflict (1..5) to one of
  SQLITE_ROLLBACK / _ABORT / _FAIL / _IGNORE / _REPLACE. }
function sqlite3_vtab_on_conflict(db: PTsqlite3): i32; cdecl;

{ vtab.c:1335 — sqlite3_vtab_config.  C uses varargs; we follow the
  Phase 8.4 db_config approach and expose a single function carrying
  the int payload (only CONSTRAINT_SUPPORT actually consumes it; the
  three valueless ops ignore intArg).  Must be called from inside an
  xCreate / xConnect callback (i.e. while db^.pVtabCtx is non-nil). }
function sqlite3_vtab_config(db: PTsqlite3; op: i32; intArg: i32): i32; cdecl;

{ ============================================================
  Phase 6.bis.1f — function overload + writable + eponymous tables
  (vtab.c:1153..1308)
  ============================================================ }

{ vtab.c:1153 — give the virtual-table implementation a chance to overload
  pDef when its first argument is a column belonging to that vtab.  Returns
  pDef unchanged if no overload happens, otherwise an SQLITE_FUNC_EPHEM
  FuncDef carved out of db. }
function sqlite3VtabOverloadFunction(db: PTsqlite3;
  pDef: passqlite3vdbe.PTFuncDef; nArg: i32;
  pExpr: passqlite3codegen.PExpr): passqlite3vdbe.PTFuncDef;

{ vtab.c:1223 — ensure pTab appears in pParse->pToplevel->apVtabLock so
  an OP_VBegin gets emitted for it.  No-op if already present. }
procedure sqlite3VtabMakeWritable(pParse: passqlite3codegen.PParse;
  pTab: passqlite3codegen.PTable2);

{ vtab.c:1257 — instantiate an eponymous virtual-table for module pMod
  (i.e. one whose name == module name; no CREATE VIRTUAL TABLE needed).
  Returns 1 on success or on attempted-but-failed; 0 if the module does
  not support eponymity (xCreate != xConnect when xCreate is non-nil). }
function sqlite3VtabEponymousTableInit(pParse: passqlite3codegen.PParse;
  pMd: PVtabModule): i32;

{ ============================================================
  Phase 6.bis.3d — Table-layout introspection helpers (interface)
  Exposed for vdbe to drive OP_VCheck without taking a circular
  dependency on passqlite3codegen's full TTable record.
  ============================================================ }

type
  PPVTable = ^PVTable;

{ Pointer to pTab^.u.vtab.p (the head of the per-connection VTable list). }
function tabVtabPP(pTab: Pointer): PPVTable;

{ pTab^.zName — table or view name. }
function tabZName(pTab: Pointer): PAnsiChar; inline;

{ ============================================================
  Shared printf-shim helpers (Phase 6.bis follow-up: collapse the
  four duplicate *FmtMsg copies in passqlite3vtab/carray/dbpage/
  dbstat into a single pair).  Both implement the one-%s
  substitution pattern that the four call sites need today;
  full sqlite3MPrintf-format support waits on the printf sub-phase.
  ============================================================ }

{ One-%s formatter.  Allocated via sqlite3DbMalloc(db, ...) — caller
  releases with sqlite3DbFree.  fmt without '%' is returned verbatim. }
function sqlite3VtabFmtMsg1Db(db: PTsqlite3;
  const fmt, arg: AnsiString): PAnsiChar;

{ One-%s formatter.  Allocated via sqlite3Malloc (libc malloc) so the
  caller can release it with sqlite3_free — matches the allocator
  contract for sqlite3_vtab.zErrMsg.  fmt without '%' is returned
  verbatim. }
function sqlite3VtabFmtMsg1Libc(const fmt, arg: AnsiString): PAnsiChar;

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
  PPPAnsiCharL  = ^PPAnsiChar;

function tabIsVirtual(pTab: Pointer): Boolean; inline;
begin
  Result := (pTab <> nil) and ((PByte(pTab) + TAB_OFF_eTabType)^ = TABTYP_VTAB);
end;

function tabVtabPP(pTab: Pointer): PPVTable;
begin
  Result := PPVTable(PByte(pTab) + TAB_OFF_uVtab + VTAB_OFF_p);
end;

function tabZName(pTab: Pointer): PAnsiChar; inline;
begin
  Result := PPAnsiChar(pTab)^;
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

{ ============================================================
  Phase 6.bis.1c — Constructor lifecycle (vtab.c:557..968)
  ============================================================ }

type
  { Faithful Pascal type for vtab.c:557 xConstruct callback. }
  Tsqlite3_vtab_construct = function(db: PTsqlite3; pAux: Pointer;
    argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
    pzErr: PPAnsiChar): i32; cdecl;

{ Build an error message via SysUtils.Format and return as a sqlite3DbMalloc
  string.  Replacement for sqlite3MPrintf in the Phase 6.bis.1c code paths
  (the printf-machinery sub-phase will replace these calls when it lands). }
function sqlite3VtabFmtMsg1Db(db: PTsqlite3;
  const fmt, arg: AnsiString): PAnsiChar;
var
  s: AnsiString;
  n: i32;
  z: PAnsiChar;
begin
  if Pos('%', fmt) > 0 then
    s := SysUtils.Format(string(fmt), [string(arg)])
  else
    s := fmt;
  n := Length(s);
  z := PAnsiChar(sqlite3DbMalloc(Psqlite3db(db), n + 1));
  if z = nil then begin Result := nil; Exit; end;
  if n > 0 then Move(PAnsiChar(s)^, z^, n);
  z[n] := #0;
  Result := z;
end;

function sqlite3VtabFmtMsg1Libc(const fmt, arg: AnsiString): PAnsiChar;
var
  s: AnsiString;
  n: i32;
  z: PAnsiChar;
begin
  if Pos('%', fmt) > 0 then
    s := SysUtils.Format(string(fmt), [string(arg)])
  else
    s := fmt;
  n := Length(s);
  z := PAnsiChar(sqlite3Malloc(n + 1));
  if z = nil then begin Result := nil; Exit; end;
  if n > 0 then Move(PAnsiChar(s)^, z^, n);
  z[n] := #0;
  Result := z;
end;

{ Back-compat alias for in-unit callers that used the older private name. }
function vtabFmtMsg(db: PTsqlite3; const fmt, arg: AnsiString): PAnsiChar; inline;
begin
  Result := sqlite3VtabFmtMsg1Db(db, fmt, arg);
end;

{ vtab.c:557 — invoke xCreate or xConnect on pTab.  *pzErr is heap-allocated
  on error and the caller must sqlite3DbFree it. }
function vtabCallConstructor(db: PTsqlite3; pTab: passqlite3codegen.PTable2;
  pMod: PVtabModule;
  xConstruct: Tsqlite3_vtab_construct;
  pzErr: PPAnsiChar): i32;
var
  sCtx:        TVtabCtx;
  pCtx:        PVtabCtx;
  pVTbl:     PVTable;
  rc, iDb:     i32;
  azArg:       PPAnsiChar;
  nArg:        i32;
  zErr:        PAnsiChar;
  zModuleName: PAnsiChar;
begin
  Assert(pTab <> nil, 'vtabCallConstructor pTab nil');
  Assert(pTab^.eTabType = passqlite3codegen.TABTYP_VTAB,
    'vtabCallConstructor: not a vtab');
  azArg := PPAnsiChar(pTab^.u.vtab.azArg);
  nArg  := pTab^.u.vtab.nArg;
  zErr  := nil;

  { Recursion guard (vtab.c:578) }
  pCtx := PVtabCtx(db^.pVtabCtx);
  while pCtx <> nil do begin
    if PtrUInt(pCtx^.pTab) = PtrUInt(pTab) then begin
      pzErr^ := vtabFmtMsg(db, 'vtable constructor called recursively: %s',
                           AnsiString(pTab^.zName));
      Result := SQLITE_LOCKED;
      Exit;
    end;
    pCtx := pCtx^.pPrior;
  end;

  zModuleName := sqlite3DbStrDup(Psqlite3db(db), PChar(pTab^.zName));
  if zModuleName = nil then begin
    Result := SQLITE_NOMEM;
    Exit;
  end;

  pVTbl := PVTable(sqlite3MallocZero64(SizeOf(TVTable)));
  if pVTbl = nil then begin
    sqlite3OomFault(Psqlite3db(db));
    sqlite3DbFree(Psqlite3db(db), zModuleName);
    Result := SQLITE_NOMEM;
    Exit;
  end;
  pVTbl^.db        := db;
  pVTbl^.pMod      := pMod;
  pVTbl^.eVtabRisk := SQLITE_VTABRISK_Normal;

  iDb := passqlite3codegen.sqlite3SchemaToIndex(db, pTab^.pSchema);
  azArg[1] := db^.aDb[iDb].zDbSName;

  { Push a new VtabCtx on db^.pVtabCtx and call the constructor. }
  Assert(@xConstruct <> nil, 'vtabCallConstructor xConstruct nil');
  sCtx.pTab      := pTab;
  sCtx.pVTbl   := pVTbl;
  sCtx.pPrior    := PVtabCtx(db^.pVtabCtx);
  sCtx.bDeclared := 0;
  db^.pVtabCtx   := @sCtx;
  Inc(pTab^.nTabRef);
  rc := xConstruct(db, pMod^.pAux, nArg, azArg, @pVTbl^.pVtab, @zErr);
  Assert(pTab <> nil, 'vtab pTab vanished');
  Assert((pTab^.nTabRef > 1) or (rc <> SQLITE_OK),
         'vtabCallConstructor nTabRef invariant');
  passqlite3codegen.sqlite3DeleteTable(db, pTab);
  db^.pVtabCtx := sCtx.pPrior;
  if rc = SQLITE_NOMEM then sqlite3OomFault(Psqlite3db(db));
  Assert(sCtx.pTab = pTab, 'sCtx.pTab corrupt');

  if rc <> SQLITE_OK then begin
    if zErr = nil then
      pzErr^ := vtabFmtMsg(db, 'vtable constructor failed: %s',
                           AnsiString(zModuleName))
    else begin
      pzErr^ := vtabFmtMsg(db, '%s', AnsiString(zErr));
      sqlite3DbFree(Psqlite3db(db), zErr);
    end;
    sqlite3DbFree(Psqlite3db(db), pVTbl);
  end else if pVTbl^.pVtab <> nil then begin
    { Successful construct: zero the sqlite3_vtab[0], link onto the chain,
      bump module nRefModule and pVTbl nRef. }
    FillChar(pVTbl^.pVtab^, SizeOf(Tsqlite3_vtab), 0);
    pVTbl^.pVtab^.pModule := pMod^.pModule;
    Inc(pMod^.nRefModule);
    pVTbl^.nRef := 1;
    if sCtx.bDeclared = 0 then begin
      pzErr^ := vtabFmtMsg(db,
        'vtable constructor did not declare schema: %s',
        AnsiString(zModuleName));
      sqlite3VtabUnlock(pVTbl);
      rc := SQLITE_ERROR;
    end else begin
      { Link the new VTable into pTab^.u.vtab.p (head insertion). }
      pVTbl^.pNext   := pTab^.u.vtab.p;
      pTab^.u.vtab.p   := pVTbl;
      { vtab.c:653..682 hidden-column scan: skipped here.  pTab^.aCol is
        normally populated only after sqlite3_declare_vtab() has run; the
        declare-vtab path lands with 6.bis.1e and re-introduces the scan
        when the printf machinery is wired.  For non-declared schemas
        (nCol=0) the upstream loop is a no-op anyway. }
    end;
  end;

  sqlite3DbFree(Psqlite3db(db), zModuleName);
  Result := rc;
end;

function sqlite3VtabCallConnect(pParse: PParse;
  pTab: passqlite3codegen.PTable2): i32;
var
  db:    PTsqlite3;
  zMod:  PAnsiChar;
  pMod:  PVtabModule;
  rc:    i32;
  zErr:  PAnsiChar;
  azArg: PPAnsiChar;
begin
  db := pParse^.db;
  Assert(pTab <> nil, 'sqlite3VtabCallConnect pTab nil');
  Assert(pTab^.eTabType = passqlite3codegen.TABTYP_VTAB,
    'sqlite3VtabCallConnect: not a vtab');
  if sqlite3GetVTable(db, pTab) <> nil then begin
    Result := SQLITE_OK; Exit;
  end;

  azArg := PPAnsiChar(pTab^.u.vtab.azArg);
  zMod  := azArg[0];
  pMod  := PVtabModule(sqlite3HashFind(@db^.aModule, PChar(zMod)));

  if pMod = nil then begin
    sqlite3ErrorMsg(pParse, PAnsiChar(AnsiString('no such module')));
    rc := SQLITE_ERROR;
  end else begin
    zErr := nil;
    rc := vtabCallConstructor(db, pTab, pMod,
            Tsqlite3_vtab_construct(pMod^.pModule^.xConnect), @zErr);
    if rc <> SQLITE_OK then begin
      sqlite3ErrorMsg(pParse, PAnsiChar(AnsiString('vtable connect failed')));
      pParse^.rc := rc;
    end;
    sqlite3DbFree(Psqlite3db(db), zErr);
  end;
  Result := rc;
end;

{ vtab.c:733 — grow db^.aVTrans by ARRAY_INCR slots when full. }
function growVTrans(db: PTsqlite3): i32;
const
  ARRAY_INCR = 5;
var
  nBytes:  i64;
  aVTrans: ^Pointer;
begin
  if (db^.nVTrans mod ARRAY_INCR) = 0 then begin
    nBytes := i64(SizeOf(Pointer)) * (i64(db^.nVTrans) + ARRAY_INCR);
    aVTrans := sqlite3DbRealloc(Psqlite3db(db), db^.aVTrans, u64(nBytes));
    if aVTrans = nil then begin
      Result := SQLITE_NOMEM; Exit;
    end;
    FillChar((PByte(aVTrans) + i64(SizeOf(Pointer)) * db^.nVTrans)^,
             SizeOf(Pointer) * ARRAY_INCR, 0);
    db^.aVTrans := aVTrans;
  end;
  Result := SQLITE_OK;
end;

{ vtab.c:756 — append pVTab to db^.aVTrans (caller has growVTrans'd). }
procedure addToVTrans(db: PTsqlite3; pVTab: PVTable);
var
  slot: PPointer;
begin
  slot := PPointer(PByte(db^.aVTrans) + i64(SizeOf(Pointer)) * db^.nVTrans);
  slot^ := pVTab;
  Inc(db^.nVTrans);
  sqlite3VtabLock(pVTab);
end;

function sqlite3VtabCallCreate(db: PTsqlite3; iDb: i32; zTab: PAnsiChar;
  pzErr: PPAnsiChar): i32;
var
  rc:   i32;
  pTab: passqlite3codegen.PTable2;
  pMod: PVtabModule;
  zMod: PAnsiChar;
  pVT:  PVTable;
begin
  rc   := SQLITE_OK;
  pTab := passqlite3codegen.sqlite3FindTable(db, zTab,
            db^.aDb[iDb].zDbSName);
  Assert((pTab <> nil) and (pTab^.eTabType = passqlite3codegen.TABTYP_VTAB)
    and (pTab^.u.vtab.p = nil),
    'sqlite3VtabCallCreate preconditions violated');

  zMod := PPAnsiChar(pTab^.u.vtab.azArg)[0];
  pMod := PVtabModule(sqlite3HashFind(@db^.aModule, PChar(zMod)));

  if (pMod = nil) or (pMod^.pModule^.xCreate = nil)
     or (not Assigned(pMod^.pModule^.xDestroy)) then begin
    pzErr^ := vtabFmtMsg(db, 'no such module: %s', AnsiString(zMod));
    rc := SQLITE_ERROR;
  end else begin
    rc := vtabCallConstructor(db, pTab, pMod,
            Tsqlite3_vtab_construct(pMod^.pModule^.xCreate), pzErr);
  end;

  if rc = SQLITE_OK then begin
    pVT := sqlite3GetVTable(db, pTab);
    if pVT <> nil then begin
      rc := growVTrans(db);
      if rc = SQLITE_OK then addToVTrans(db, pVT);
    end;
  end;
  Result := rc;
end;

function sqlite3VtabCallDestroy(db: PTsqlite3; iDb: i32; zTab: PAnsiChar): i32;
var
  rc:       i32;
  pTab:     passqlite3codegen.PTable2;
  p:        PVTable;
  xDestroy: function(p: PSqlite3Vtab): i32; cdecl;
begin
  rc   := SQLITE_OK;
  pTab := passqlite3codegen.sqlite3FindTable(db, zTab,
            db^.aDb[iDb].zDbSName);
  if (pTab <> nil)
     and (pTab^.eTabType = passqlite3codegen.TABTYP_VTAB)
     and (pTab^.u.vtab.p <> nil)
  then begin
    { No outstanding cursors? }
    p := pTab^.u.vtab.p;
    while p <> nil do begin
      Assert(p^.pVtab <> nil, 'VTable.pVtab nil');
      if p^.pVtab^.nRef > 0 then begin
        Result := SQLITE_LOCKED; Exit;
      end;
      p := p^.pNext;
    end;

    p        := vtabDisconnectAll(db, pTab);
    xDestroy := PVtabModule(p^.pMod)^.pModule^.xDestroy;
    if not Assigned(xDestroy) then
      xDestroy := PVtabModule(p^.pMod)^.pModule^.xDisconnect;
    Assert(Assigned(xDestroy), 'sqlite3VtabCallDestroy xDestroy nil');
    Inc(pTab^.nTabRef);
    rc := xDestroy(p^.pVtab);
    if rc = SQLITE_OK then begin
      Assert((pTab^.u.vtab.p = p) and (p^.pNext = nil),
        'sqlite3VtabCallDestroy chain invariant');
      p^.pVtab     := nil;
      pTab^.u.vtab.p := nil;
      sqlite3VtabUnlock(p);
    end;
    passqlite3codegen.sqlite3DeleteTable(db, pTab);
  end;
  Result := rc;
end;

{ ============================================================
  Phase 6.bis.1d — Per-statement transaction hooks (vtab.c:970..1138)
  ============================================================ }

const
  SQLITE_Defensive = u64($10000000);  { sqliteInt.h:1859 — db.flags bit }

type
  Tsqlite3_vtab_meth1 = function(p: PSqlite3Vtab): i32; cdecl;
  Tsqlite3_vtab_meth2 = function(p: PSqlite3Vtab; iSav: i32): i32; cdecl;

procedure sqlite3VtabImportErrmsg(pV: PVdbe; pVtab: PSqlite3Vtab);
var
  db: PTsqlite3;
begin
  if pVtab^.zErrMsg <> nil then begin
    db := PTsqlite3(pV^.db);
    sqlite3DbFree(Psqlite3db(db), pV^.zErrMsg);
    pV^.zErrMsg := sqlite3DbStrDup(Psqlite3db(db), PChar(pVtab^.zErrMsg));
    sqlite3_free(pVtab^.zErrMsg);
    pVtab^.zErrMsg := nil;
  end;
end;

{ Method-kind enum for callFinaliser — mirrors the C offsetof() trick by
  selecting the correct slot in the module dispatch table at call site. }
type
  TFinKind = (fkCommit, fkRollback);

procedure callFinaliser(db: PTsqlite3; kind: TFinKind);
var
  i:       i32;
  aVTrans: ^Pointer;
  pVTab:   PVTable;
  p:       PSqlite3Vtab;
  x:       Tsqlite3_vtab_meth1;
  pf:      Pointer;
begin
  if db^.aVTrans <> nil then begin
    aVTrans     := db^.aVTrans;
    db^.aVTrans := nil;
    for i := 0 to db^.nVTrans - 1 do begin
      pVTab := PVTable(aVTrans[i]);
      p     := pVTab^.pVtab;
      if p <> nil then begin
        case kind of
          fkCommit:   pf := p^.pModule^.xCommit;
          fkRollback: pf := p^.pModule^.xRollback;
        else
          pf := nil;
        end;
        if pf <> nil then begin
          x := Tsqlite3_vtab_meth1(pf);
          x(p);
        end;
      end;
      pVTab^.iSavepoint := 0;
      sqlite3VtabUnlock(pVTab);
    end;
    sqlite3DbFree(Psqlite3db(db), aVTrans);
    db^.nVTrans := 0;
  end;
end;

function sqlite3VtabSync(db: PTsqlite3; pV: PVdbe): i32;
var
  i:       i32;
  rc:      i32;
  aVTrans: ^Pointer;
  pVtab:   PSqlite3Vtab;
  pf:      Pointer;
  x:       Tsqlite3_vtab_meth1;
begin
  rc      := SQLITE_OK;
  aVTrans := db^.aVTrans;
  db^.aVTrans := nil;
  i := 0;
  while (rc = SQLITE_OK) and (i < db^.nVTrans) do begin
    pVtab := PVTable(aVTrans[i])^.pVtab;
    if pVtab <> nil then begin
      pf := pVtab^.pModule^.xSync;
      if pf <> nil then begin
        x  := Tsqlite3_vtab_meth1(pf);
        rc := x(pVtab);
        sqlite3VtabImportErrmsg(pV, pVtab);
      end;
    end;
    Inc(i);
  end;
  db^.aVTrans := aVTrans;
  Result := rc;
end;

function sqlite3VtabRollback(db: PTsqlite3): i32;
begin
  callFinaliser(db, fkRollback);
  Result := SQLITE_OK;
end;

function sqlite3VtabCommit(db: PTsqlite3): i32;
begin
  callFinaliser(db, fkCommit);
  Result := SQLITE_OK;
end;

{ vtab.c:1051 macro — true iff a vtab module is currently inside an xSync
  callback (callFinaliser/Sync nulled aVTrans while keeping nVTrans>0). }
function vtabInSync(db: PTsqlite3): Boolean; inline;
begin
  Result := (db^.nVTrans > 0) and (db^.aVTrans = nil);
end;

function sqlite3VtabBegin(db: PTsqlite3; pVTab: PVTable): i32;
var
  rc:      i32;
  pModule: PSqlite3Module;
  i, iSvpt: i32;
  pfBegin, pfSv: Pointer;
  xBegin: Tsqlite3_vtab_meth1;
  xSavepoint: Tsqlite3_vtab_meth2;
begin
  rc := SQLITE_OK;
  if vtabInSync(db) then begin
    Result := SQLITE_LOCKED; Exit;
  end;
  if pVTab = nil then begin
    Result := SQLITE_OK; Exit;
  end;
  pModule := pVTab^.pVtab^.pModule;

  pfBegin := pModule^.xBegin;
  if pfBegin <> nil then begin
    { Already in aVTrans?  No-op. }
    for i := 0 to db^.nVTrans - 1 do begin
      if PVTable(PPointer(db^.aVTrans)[i]) = pVTab then begin
        Result := SQLITE_OK; Exit;
      end;
    end;

    rc := growVTrans(db);
    if rc = SQLITE_OK then begin
      xBegin := Tsqlite3_vtab_meth1(pfBegin);
      rc := xBegin(pVTab^.pVtab);
      if rc = SQLITE_OK then begin
        iSvpt := db^.nStatement + db^.nSavepoint;
        addToVTrans(db, pVTab);
        pfSv := pModule^.xSavepoint;
        if (iSvpt <> 0) and (pfSv <> nil) then begin
          pVTab^.iSavepoint := iSvpt;
          xSavepoint := Tsqlite3_vtab_meth2(pfSv);
          rc := xSavepoint(pVTab^.pVtab, iSvpt - 1);
        end;
      end;
    end;
  end;
  Result := rc;
end;

function sqlite3VtabSavepoint(db: PTsqlite3; op, iSavepoint: i32): i32;
var
  rc:         i32;
  i:          i32;
  pVTab:      PVTable;
  pMod:       PSqlite3Module;
  pf:         Pointer;
  xMethod:    Tsqlite3_vtab_meth2;
  savedFlags: u64;
begin
  rc := SQLITE_OK;
  Assert((op = SAVEPOINT_RELEASE) or (op = SAVEPOINT_ROLLBACK)
         or (op = SAVEPOINT_BEGIN), 'sqlite3VtabSavepoint bad op');
  Assert(iSavepoint >= -1, 'sqlite3VtabSavepoint bad iSavepoint');
  if db^.aVTrans <> nil then begin
    i := 0;
    while (rc = SQLITE_OK) and (i < db^.nVTrans) do begin
      pVTab := PVTable(PPointer(db^.aVTrans)[i]);
      pMod  := PVtabModule(pVTab^.pMod)^.pModule;
      if (pVTab^.pVtab <> nil) and (pMod^.iVersion >= 2) then begin
        sqlite3VtabLock(pVTab);
        pf := nil;
        case op of
          SAVEPOINT_BEGIN:
            begin
              pf := pMod^.xSavepoint;
              pVTab^.iSavepoint := iSavepoint + 1;
            end;
          SAVEPOINT_ROLLBACK:
            pf := pMod^.xRollbackTo;
        else
          pf := pMod^.xRelease;
        end;
        if (pf <> nil) and (pVTab^.iSavepoint > iSavepoint) then begin
          savedFlags := db^.flags and SQLITE_Defensive;
          db^.flags  := db^.flags and (not SQLITE_Defensive);
          xMethod := Tsqlite3_vtab_meth2(pf);
          rc := xMethod(pVTab^.pVtab, iSavepoint);
          db^.flags := db^.flags or savedFlags;
        end;
        sqlite3VtabUnlock(pVTab);
      end;
      Inc(i);
    end;
  end;
  Result := rc;
end;

{ vtab.c:1298 — full body for Phase 6.bis.1f. }
procedure sqlite3VtabEponymousTableClear(db: PTsqlite3; pMod: PVtabModule);
var
  pTab: passqlite3codegen.PTable2;
begin
  pTab := passqlite3codegen.PTable2(pMod^.pEpoTab);
  if pTab <> nil then begin
    { Mark Ephemeral so sqlite3DeleteTable does not look for it in the
      schema (which it never lived in). }
    pTab^.tabFlags := pTab^.tabFlags or passqlite3codegen.TF_Ephemeral;
    passqlite3codegen.sqlite3DeleteTable(db, pTab);
    pMod^.pEpoTab := nil;
  end;
end;

{ ============================================================
  Phase 6.bis.1f — function overload + writable + eponymous tables
  (vtab.c:1153..1308)
  ============================================================ }

type
  { xFindFunction(pVtab, nArg, zName, &xSFunc, &pArg) — returns 0 if no
    overload, non-zero otherwise.  Mirrors sqlite.h:7986. }
  TVtabFindFn = function(pVtab: PSqlite3Vtab; nArg: i32; zName: PAnsiChar;
                         pxFunc: Pointer; ppArg: PPointer): i32; cdecl;

function sqlite3VtabOverloadFunction(db: PTsqlite3;
  pDef: passqlite3vdbe.PTFuncDef; nArg: i32;
  pExpr: passqlite3codegen.PExpr): passqlite3vdbe.PTFuncDef;
var
  pTab:    passqlite3codegen.PTable2;
  pVtab:   PSqlite3Vtab;
  pMd:     PSqlite3Module;
  xSFunc:  Pointer;
  pArg:    Pointer;
  pNew:    passqlite3vdbe.PTFuncDef;
  rc:      i32;
  nName:   i32;
  xFind:   TVtabFindFn;
  pVT:     PVTable;
begin
  xSFunc := nil;
  pArg   := nil;
  rc     := 0;

  { Check that pExpr->op==TK_COLUMN and the column belongs to a vtab. }
  if pExpr = nil then begin Result := pDef; Exit; end;
  if pExpr^.op <> u8(passqlite3codegen.TK_COLUMN) then begin
    Result := pDef; Exit;
  end;
  pTab := passqlite3codegen.PTable2(pExpr^.y.pTab);
  if pTab = nil then begin Result := pDef; Exit; end;
  if pTab^.eTabType <> passqlite3codegen.TABTYP_VTAB then begin
    Result := pDef; Exit;
  end;
  pVT := sqlite3GetVTable(db, pTab);
  Assert(pVT <> nil, 'sqlite3VtabOverloadFunction: VTable nil');
  pVtab := pVT^.pVtab;
  Assert(pVtab <> nil, 'sqlite3VtabOverloadFunction: pVtab nil');
  Assert(pVtab^.pModule <> nil, 'sqlite3VtabOverloadFunction: pModule nil');
  pMd := pVtab^.pModule;
  if pMd^.xFindFunction = nil then begin
    Result := pDef; Exit;
  end;

  { Invoke xFindFunction. }
  xFind := TVtabFindFn(pMd^.xFindFunction);
  rc := xFind(pVtab, nArg, pDef^.zName, @xSFunc, @pArg);
  if rc = 0 then begin
    Result := pDef; Exit;
  end;

  { Carve out a fresh ephemeral FuncDef.  The name is appended after the
    record (vtab.c:1209..1210). }
  nName := sqlite3Strlen30(PChar(pDef^.zName));
  pNew  := passqlite3vdbe.PTFuncDef(
             sqlite3DbMallocZero(Psqlite3db(db),
               u64(SizeOf(passqlite3vdbe.TFuncDef) + nName + 1)));
  if pNew = nil then begin
    Result := pDef; Exit;
  end;
  pNew^ := pDef^;
  pNew^.zName := PAnsiChar(PByte(pNew) + SizeOf(passqlite3vdbe.TFuncDef));
  Move(pDef^.zName^, (PByte(pNew) + SizeOf(passqlite3vdbe.TFuncDef))^,
       nName + 1);
  pNew^.xSFunc    := passqlite3vdbe.TxSFuncProc(xSFunc);
  pNew^.pUserData := pArg;
  pNew^.funcFlags := pNew^.funcFlags or passqlite3vdbe.SQLITE_FUNC_EPHEM;
  Result := pNew;
end;

procedure sqlite3VtabMakeWritable(pParse: passqlite3codegen.PParse;
  pTab: passqlite3codegen.PTable2);
var
  pTop:        passqlite3codegen.PParse;
  i, n:        i32;
  apOld, apNew: PPointer;
begin
  Assert(pTab^.eTabType = passqlite3codegen.TABTYP_VTAB,
    'sqlite3VtabMakeWritable: not a vtab');
  if pParse^.pToplevel <> nil then
    pTop := pParse^.pToplevel
  else
    pTop := pParse;

  apOld := PPointer(pTop^.apVtabLock);
  for i := 0 to pTop^.nVtabLock - 1 do begin
    if Pointer(pTab) = apOld[i] then Exit;
  end;
  n := (pTop^.nVtabLock + 1) * SizeOf(Pointer);
  apNew := PPointer(sqlite3_realloc64(apOld, u64(n)));
  if apNew <> nil then begin
    pTop^.apVtabLock := Pointer(apNew);
    apNew[pTop^.nVtabLock] := Pointer(pTab);
    Inc(pTop^.nVtabLock);
  end else
    sqlite3OomFault(Psqlite3db(pTop^.db));
end;

function sqlite3VtabEponymousTableInit(pParse: passqlite3codegen.PParse;
  pMd: PVtabModule): i32;
var
  pModule: PSqlite3Module;
  pTab:    passqlite3codegen.PTable2;
  zErr:    PAnsiChar;
  rc:      i32;
  db:      PTsqlite3;
begin
  pModule := pMd^.pModule;
  zErr    := nil;
  db      := pParse^.db;

  if pMd^.pEpoTab <> nil then begin Result := 1; Exit; end;
  { An eponymous module is one where xCreate is nil OR equals xConnect. }
  if (pModule^.xCreate <> nil)
     and (pModule^.xCreate <> pModule^.xConnect) then begin
    Result := 0; Exit;
  end;

  pTab := passqlite3codegen.PTable2(
            sqlite3DbMallocZero(Psqlite3db(db),
              SizeOf(passqlite3codegen.TTable)));
  if pTab = nil then begin Result := 0; Exit; end;
  pTab^.zName := sqlite3DbStrDup(Psqlite3db(db), PChar(pMd^.zName));
  if pTab^.zName = nil then begin
    sqlite3DbFree(Psqlite3db(db), pTab);
    Result := 0; Exit;
  end;
  pMd^.pEpoTab     := pTab;
  pTab^.nTabRef    := 1;
  pTab^.eTabType   := passqlite3codegen.TABTYP_VTAB;
  pTab^.pSchema    := passqlite3codegen.PSchema(db^.aDb[0].pSchema);
  Assert(pTab^.u.vtab.nArg = 0,
    'sqlite3VtabEponymousTableInit: nArg non-zero');
  pTab^.iPKey      := -1;
  pTab^.tabFlags   := pTab^.tabFlags or passqlite3codegen.TF_Eponymous;
  passqlite3parser.addModuleArgument(pParse, pTab,
    sqlite3DbStrDup(Psqlite3db(db), PChar(pTab^.zName)));
  passqlite3parser.addModuleArgument(pParse, pTab, nil);
  passqlite3parser.addModuleArgument(pParse, pTab,
    sqlite3DbStrDup(Psqlite3db(db), PChar(pTab^.zName)));
  Inc(db^.nSchemaLock);
  rc := vtabCallConstructor(db, pTab, pMd,
                            Tsqlite3_vtab_construct(pModule^.xConnect),
                            @zErr);
  Dec(db^.nSchemaLock);
  if rc <> SQLITE_OK then begin
    { Upstream uses sqlite3ErrorMsg(p, "%s", zErr) — our port's
      sqlite3ErrorMsg has no varargs, so pass zErr directly.  Until a
      printf sub-phase lands sqlite3MPrintf, this drops % escapes if any
      slipped into a constructor's error message.  Tracked alongside the
      6.bis.1c vtabFmtMsg shim. }
    passqlite3codegen.sqlite3ErrorMsg(pParse, zErr);
    pParse^.rc := rc;
    sqlite3DbFree(Psqlite3db(db), zErr);
    sqlite3VtabEponymousTableClear(db, pMd);
  end;
  Result := 1;
end;

{ ============================================================
  Phase 6.bis.1e — public API entry points (vtab.c:811..1374)
  ============================================================ }

function sqlite3_declare_vtab(db: PTsqlite3; zCreateTable: PAnsiChar): i32; cdecl;
const
  { vtab.c:819 — first two non-trivia tokens must be CREATE then TABLE. }
  aKeyword: array[0..1] of u8 = (TK_CREATE, TK_TABLE);
var
  pCtx:    PVtabCtx;
  rc:      i32;
  pTab:    passqlite3codegen.PTable2;
  sParse:  passqlite3codegen.TParse;
  initBusy: i32;
  i:       i32;
  z:       PByte;
  tokenType: i32;
  pNew:    passqlite3codegen.PTable2;
begin
  rc := SQLITE_OK;
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if (sqlite3SafetyCheckOk(db) = 0) or (zCreateTable = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ELSE}
  if (db = nil) or (zCreateTable = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}

  { Verify CREATE TABLE prefix (vtab.c:827..841). }
  z := PByte(zCreateTable);
  for i := 0 to High(aKeyword) do begin
    repeat
      tokenType := 0;
      Inc(z, sqlite3GetToken(z, @tokenType));
    until (tokenType <> TK_SPACE) and (tokenType <> TK_COMMENT);
    if tokenType <> aKeyword[i] then begin
      sqlite3ErrorWithMsg(db, SQLITE_ERROR, 'syntax error');
      Result := SQLITE_ERROR; Exit;
    end;
  end;

  sqlite3_mutex_enter(db^.mutex);
  pCtx := PVtabCtx(db^.pVtabCtx);
  if (pCtx = nil) or (pCtx^.bDeclared <> 0) then begin
    sqlite3Error(db, SQLITE_MISUSE);
    sqlite3_mutex_leave(db^.mutex);
    Result := SQLITE_MISUSE; Exit;
  end;

  pTab := passqlite3codegen.PTable2(pCtx^.pTab);
  Assert((pTab <> nil)
    and (pTab^.eTabType = passqlite3codegen.TABTYP_VTAB),
    'sqlite3_declare_vtab: pCtx^.pTab is not a vtab');

  { Initialise a Parse object and run the parser in DECLARE_VTAB mode. }
  FillChar(sParse, SizeOf(sParse), 0);
  sParse.db          := db;
  sParse.pOuterParse := db^.pParse;
  db^.pParse         := @sParse;
  sParse.eParseMode  := passqlite3codegen.PARSE_MODE_DECLARE_VTAB;
  sParse.parseFlags  := sParse.parseFlags
                       or passqlite3codegen.PARSEFLAG_DisableTriggers;
  Assert(db^.init.busy = 0,
    'sqlite3_declare_vtab: re-entered while loading the schema');
  initBusy := db^.init.busy;
  db^.init.busy := 0;
  sParse.nQueryLoop := 1;

  if passqlite3parser.sqlite3RunParser(@sParse, zCreateTable) = SQLITE_OK then begin
    pNew := sParse.pNewTable;
    if pNew = nil then begin
      { CREATE TABLE parsing produces no Table object until the build.c
        ports (sqlite3StartTable / AddColumn / EndTable) land in Phase 7.
        Treat this as a successful bDeclared flip so vtabCallConstructor
        accepts the constructor; column metadata grafting waits on Phase 7.
        Tracked in tasklist.md under 6.bis.1e. }
      pCtx^.bDeclared := 1;
    end else begin
      { Faithful column-graft branch (vtab.c:869..896).  Once
        sqlite3StartTable populates pNewTable this branch becomes hot. }
      if pTab^.aCol = nil then begin
        pTab^.aCol     := pNew^.aCol;
        pTab^.nCol     := pNew^.nCol;
        pTab^.nNVCol   := pNew^.nCol;
        pTab^.tabFlags := pTab^.tabFlags
                         or (pNew^.tabFlags
                             and (passqlite3codegen.TF_WithoutRowid
                                  or passqlite3codegen.TF_NoVisibleRowid));
        pNew^.nCol := 0;
        pNew^.aCol := nil;
        if pNew^.pIndex <> nil then begin
          pTab^.pIndex := pNew^.pIndex;
          pNew^.pIndex := nil;
          pTab^.pIndex^.pTable := pTab;
        end;
      end;
      pCtx^.bDeclared := 1;
    end;
  end else begin
    sqlite3ErrorWithMsg(db, SQLITE_ERROR, sParse.zErrMsg);
    sqlite3DbFree(db, sParse.zErrMsg);
    sParse.zErrMsg := nil;
    rc := SQLITE_ERROR;
  end;
  sParse.eParseMode := passqlite3codegen.PARSE_MODE_NORMAL;

  if sParse.pVdbe <> nil then
    passqlite3vdbe.sqlite3VdbeFinalize(sParse.pVdbe);
  passqlite3codegen.sqlite3DeleteTable(db, sParse.pNewTable);
  passqlite3codegen.sqlite3ParseObjectReset(@sParse);
  db^.init.busy := initBusy;

  Assert((rc and $FF) = rc, 'sqlite3_declare_vtab: rc has high bits set');
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_vtab_on_conflict(db: PTsqlite3): i32; cdecl;
const
  { vtab.c:1318 — OE_Rollback..OE_Replace map to the public SQLITE_*
    constants from sqlite.h:1133.  Inlined as bytes here because the
    SQLITE_FAIL/_REPLACE/_ROLLBACK constants are not (yet) re-exported
    from passqlite3types — these are the conflict-resolution codes,
    distinct from the result codes of the same name.  Values match
    sqlite.h: ROLLBACK=1, IGNORE=2, FAIL=3, ABORT=4, REPLACE=5. }
  aMap: array[0..4] of u8 = (1, 4, 3, 2, 5);
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}
  Assert((db^.vtabOnConflict >= 1) and (db^.vtabOnConflict <= 5),
    'sqlite3_vtab_on_conflict: vtabOnConflict out of range');
  Result := i32(aMap[db^.vtabOnConflict - 1]);
end;

function sqlite3_vtab_config(db: PTsqlite3; op: i32; intArg: i32): i32; cdecl;
var
  rc: i32;
  p:  PVtabCtx;
begin
  rc := SQLITE_OK;
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}
  sqlite3_mutex_enter(db^.mutex);
  p := PVtabCtx(db^.pVtabCtx);
  if p = nil then begin
    rc := SQLITE_MISUSE;
  end else begin
    Assert((p^.pTab = nil)
      or (passqlite3codegen.PTable2(p^.pTab)^.eTabType
          = passqlite3codegen.TABTYP_VTAB),
      'sqlite3_vtab_config: p^.pTab is not a vtab');
    case op of
      SQLITE_VTAB_CONSTRAINT_SUPPORT:
        p^.pVTbl^.bConstraint := u8(intArg);
      SQLITE_VTAB_INNOCUOUS:
        p^.pVTbl^.eVtabRisk := SQLITE_VTABRISK_Low;
      SQLITE_VTAB_DIRECTONLY:
        p^.pVTbl^.eVtabRisk := SQLITE_VTABRISK_High;
      SQLITE_VTAB_USES_ALL_SCHEMAS:
        p^.pVTbl^.bAllSchemas := 1;
    else
      rc := SQLITE_MISUSE;
    end;
  end;

  if rc <> SQLITE_OK then sqlite3Error(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

end.
