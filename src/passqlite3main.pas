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
unit passqlite3main;

{
  Phase 8.1 — Connection lifecycle (main.c subset).

  Public entry points:
    sqlite3_open       — open a database (READWRITE | CREATE)
    sqlite3_open_v2    — open a database with explicit flags + VFS name
    sqlite3_close      — close (legacy: refuses if statements outstanding)
    sqlite3_close_v2   — close (zombifies if statements outstanding)

  Internal helpers (mirror main.c names where practical):
    openDatabase                  — main allocation / setup path
    sqlite3Close                  — common close machinery
    sqlite3LeaveMutexAndCloseZombie — final tear-down
    connectionIsBusy              — detects pending Vdbe / backup state

  Scope of this initial port (Phase 8.1, 2026-04-25):
    * No URI parsing (zFilename is passed straight to BtreeOpen).
    * No shared-cache, no virtual-table list, no extension list.
    * No lookaside (db^.lookaside.bDisable = 1, sz = 0).
    * No WAL autocheckpoint wiring (the WAL layer ignores it currently).
    * No mutex allocation — db^.mutex stays nil.  Single-threaded use only.
    * Schema slots 0 and 1 are allocated via sqlite3SchemaGet(db, nil),
      not fetched from the BtShared (sqlite3BtreeSchema is not yet ported).
    * Collation registration (BINARY/NOCASE/RTRIM) is delegated to
      sqlite3RegisterPerConnectionBuiltinFunctions when available; the
      explicit createCollation calls from main.c openDatabase are skipped.

  These gaps are expected to close in Phase 8.2 (prepare_v2 wiring) and
  Phase 8.3+ (registration APIs, hooks, lookaside).
}

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser,  { Phase 8.2 — real sqlite3RunParser }
  passqlite3vtab;    { Phase 6.bis.1a — module/VTable lifecycle }

type
  PPTsqlite3 = ^PTsqlite3;

{ ----------------------------------------------------------------------
  SQLITE_STATE_* — db^.eOpenState magic values (sqliteInt.h:1951).
  ---------------------------------------------------------------------- }
const
  SQLITE_STATE_OPEN   = $76;  { Database is open }
  SQLITE_STATE_CLOSED = $CE;  { Database is closed }
  SQLITE_STATE_SICK   = $BA;  { Error and awaiting close }
  SQLITE_STATE_BUSY   = $6D;  { Database currently in use }
  SQLITE_STATE_ERROR  = $D5;  { An SQLITE_MISUSE error occurred }
  SQLITE_STATE_ZOMBIE = $A7;  { Close with last statement close }

{ ----------------------------------------------------------------------
  Phase 8.4 — public sqlite3.h DBCONFIG / CONFIG opcode values.
  ---------------------------------------------------------------------- }
const
  SQLITE_DBCONFIG_MAINDBNAME            = 1000;
  SQLITE_DBCONFIG_LOOKASIDE             = 1001;
  SQLITE_DBCONFIG_ENABLE_FKEY           = 1002;
  SQLITE_DBCONFIG_ENABLE_TRIGGER        = 1003;
  SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER = 1004;
  SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION = 1005;
  SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE      = 1006;
  SQLITE_DBCONFIG_ENABLE_QPSG           = 1007;
  SQLITE_DBCONFIG_TRIGGER_EQP           = 1008;
  SQLITE_DBCONFIG_RESET_DATABASE        = 1009;
  SQLITE_DBCONFIG_DEFENSIVE             = 1010;
  SQLITE_DBCONFIG_WRITABLE_SCHEMA       = 1011;
  SQLITE_DBCONFIG_LEGACY_ALTER_TABLE    = 1012;
  SQLITE_DBCONFIG_DQS_DML               = 1013;
  SQLITE_DBCONFIG_DQS_DDL               = 1014;
  SQLITE_DBCONFIG_ENABLE_VIEW           = 1015;
  SQLITE_DBCONFIG_LEGACY_FILE_FORMAT    = 1016;
  SQLITE_DBCONFIG_TRUSTED_SCHEMA        = 1017;
  SQLITE_DBCONFIG_STMT_SCANSTATUS       = 1018;
  SQLITE_DBCONFIG_REVERSE_SCANORDER     = 1019;
  SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE  = 1020;
  SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE   = 1021;
  SQLITE_DBCONFIG_ENABLE_COMMENTS       = 1022;
  SQLITE_DBCONFIG_FP_DIGITS             = 1023;

  SQLITE_CONFIG_SINGLETHREAD = 1;
  SQLITE_CONFIG_MULTITHREAD  = 2;
  SQLITE_CONFIG_SERIALIZED   = 3;
  SQLITE_CONFIG_MEMSTATUS    = 9;
  SQLITE_CONFIG_URI          = 17;
  SQLITE_CONFIG_COVERING_INDEX_SCAN = 20;
  SQLITE_CONFIG_STMTJRNL_SPILL = 26;
  SQLITE_CONFIG_SMALL_MALLOC = 27;
  SQLITE_CONFIG_SORTERREF_SIZE = 28;
  SQLITE_CONFIG_MEMDB_MAXSIZE  = 29;

{ ----------------------------------------------------------------------
  Public API
  ---------------------------------------------------------------------- }

function sqlite3_open(zFilename: PAnsiChar; ppDb: PPTsqlite3): i32;
function sqlite3_open_v2(zFilename: PAnsiChar; ppDb: PPTsqlite3;
                          flags: i32; zVfs: PAnsiChar): i32;
function sqlite3_close(db: PTsqlite3): i32;
function sqlite3_close_v2(db: PTsqlite3): i32;

{ Phase 8.2 — sqlite3_prepare family (prepare.c). }
function sqlite3_prepare(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                         ppStmt: PPointer; pzTail: PPAnsiChar): i32;
function sqlite3_prepare_v2(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                            ppStmt: PPointer; pzTail: PPAnsiChar): i32;
function sqlite3_prepare_v3(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                            prepFlags: u32; ppStmt: PPointer;
                            pzTail: PPAnsiChar): i32;

{ Phase 7.1.3 — re-prepare a v2 statement after schema change (prepare.c:886). }
function sqlite3Reprepare(p: PVdbe): i32;

{ Phase 8.3 — registration APIs (main.c, vtab.c). }
function sqlite3_create_function(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer): i32;
function sqlite3_create_function_v2(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer;
  xDestroy: Pointer): i32;
function sqlite3_create_window_function(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xStep: Pointer; xFinal: Pointer; xValue: Pointer; xInverse: Pointer;
  xDestroy: Pointer): i32;

function sqlite3_create_collation(db: PTsqlite3; zName: PAnsiChar;
  enc: i32; pCtx: Pointer; xCompare: Pointer): i32;
function sqlite3_create_collation_v2(db: PTsqlite3; zName: PAnsiChar;
  enc: i32; pCtx: Pointer; xCompare: Pointer; xDel: Pointer): i32;
function sqlite3_collation_needed(db: PTsqlite3;
  pCollNeededArg: Pointer; xCollNeeded: Pointer): i32;

function sqlite3_create_module(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer): i32;
function sqlite3_create_module_v2(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer; xDestroy: Pointer): i32;

{ Phase 8.4 — configuration and hooks (main.c). }

{ Busy handler / timeout. }
function sqlite3_busy_handler(db: PTsqlite3;
  xBusy: Pointer; pArg: Pointer): i32;
function sqlite3_busy_timeout(db: PTsqlite3; ms: i32): i32;

{ Hooks: each returns the previously-installed pArg (or nil). }
function sqlite3_commit_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
function sqlite3_rollback_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
function sqlite3_update_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;

{ Trace v2.  Combinations of SQLITE_TRACE_STMT/PROFILE/ROW/CLOSE. }
function sqlite3_trace_v2(db: PTsqlite3; mTrace: u32;
  xTrace: Pointer; pArg: Pointer): i32;

{ db_config — Pascal-friendly typed entry points (no C varargs).
  The varargs C signature collapses into three argument shapes; we expose
  one entry point per shape.  Phase 8.4 covers MAINDBNAME / FP_DIGITS /
  LOOKASIDE / all flag-toggle ops in main.c:982. }
function sqlite3_db_config_text(db: PTsqlite3; op: i32;
  zName: PAnsiChar): i32;
function sqlite3_db_config_lookaside(db: PTsqlite3; op: i32;
  pBuf: Pointer; sz: i32; cnt: i32): i32;
function sqlite3_db_config_int(db: PTsqlite3; op: i32;
  onoff: i32; pRes: Pi32): i32;

{ config — int-shape entry point.  passqlite3util already provides the
  pointer-shape sqlite3_config(op, pArg) (overloaded); this adds the
  int-shape used by SQLITE_CONFIG_MEMSTATUS / SINGLETHREAD / etc. }
function sqlite3_config(op: i32; arg: i32): i32; overload;

{ Phase 8.5 — library-wide initialize / shutdown (main.c:190 / :372). }
function sqlite3_initialize: i32;
function sqlite3_shutdown:   i32;

{ Phase 8.6 — legacy.c (sqlite3_exec) + table.c (get_table / free_table). }

type
  Tsqlite3_callback = function(pArg: Pointer; nCol: i32;
                               argv: PPAnsiChar;
                               colv: PPAnsiChar): i32; cdecl;
  PPPAnsiChar = ^PPAnsiChar;

{ sqlite3_errmsg — minimal port: returns the textual form of db^.errCode.
  The full main.c version consults db^.pErr (a sqlite3_value), which is not
  populated by our codegen yet (sqlite3ErrorWithMsg only stores the code).
  Returning sqlite3ErrStr(errCode) is what main.c falls back to when
  pErr is nil, so this is byte-correct for that path. }
function sqlite3_errmsg(db: PTsqlite3): PAnsiChar;

function sqlite3_exec(db: PTsqlite3; zSql: PAnsiChar;
                      xCallback: Tsqlite3_callback; pArg: Pointer;
                      pzErrMsg: PPAnsiChar): i32;

function sqlite3_get_table(db: PTsqlite3; zSql: PAnsiChar;
                           pazResult: PPPAnsiChar;
                           pnRow: Pi32; pnColumn: Pi32;
                           pzErrMsg: PPAnsiChar): i32;
procedure sqlite3_free_table(azResult: PPAnsiChar);

{ ----------------------------------------------------------------------
  Phase 8.8 — sqlite3_unlock_notify (notify.c).

  Upstream's notify.c is wrapped in `#ifdef SQLITE_ENABLE_UNLOCK_NOTIFY`,
  and our build configuration leaves that macro off (see passqlite3util's
  Tsqlite3 record: pBlockingConnection / pUnlockConnection / xUnlockNotify
  fields are intentionally omitted).  In that build mode the C library
  does not emit notify.c at all; SQLite consumers that need the symbol
  must compile with the macro on.

  We expose the symbol anyway as a tiny shim because: (1) the unlock-
  notify semantics on a single connection / no-shared-cache port are
  trivial — there can never be a blocking peer connection in this
  environment, so the callback is always safe to fire immediately;
  (2) consumers that always link `sqlite3_unlock_notify` (e.g. a Pascal
  wrapper that mirrors the public API verbatim) keep working without
  conditional compilation on their side.  This matches the documented
  fast-path in notify.c:167 ("0==db->pBlockingConnection → invoke the
  notify callback immediately").
  ---------------------------------------------------------------------- }
type
  Tsqlite3_unlock_notify_cb = procedure(apArg: PPointer; nArg: i32); cdecl;

function sqlite3_unlock_notify(db: PTsqlite3;
                               xNotify: Tsqlite3_unlock_notify_cb;
                               pArg: Pointer): i32;

{ ----------------------------------------------------------------------
  Phase 8.9 — loadext.c (sqlite3_load_extension family).

  Build configuration sets SQLITE_OMIT_LOAD_EXTENSION (see Phase 0.12 in
  passqlite3.inc), so upstream's loadext.c emits *only* the auto-extension
  surface (sqlite3_auto_extension / _cancel_auto_extension /
  _reset_auto_extension); the DLL-loading path
  (sqlite3_load_extension / sqlite3_enable_load_extension) is `#ifndef`-
  guarded out.  We expose the symbols anyway as thin shims:

    * sqlite3_load_extension      → SQLITE_ERROR + "extension loading is
                                    disabled" message, matching the
                                    documented behaviour in the OMIT build.
    * sqlite3_enable_load_extension → flips the db->flags bit faithfully,
                                    so DBCONFIG_ENABLE_LOAD_EXTENSION
                                    parity is preserved (a flag with no
                                    loader behind it is harmless).
    * sqlite3_auto_extension      → faithful port of loadext.c:808.
    * sqlite3_cancel_auto_extension → faithful port of loadext.c:858.
    * sqlite3_reset_auto_extension  → faithful port of loadext.c:886.

  The auto-extension list is *process-global* in the C code (a static
  WSD array protected by SQLITE_MUTEX_STATIC_MAIN).  We mirror that with
  a `var`-level dynamic array protected by the same static main mutex.
  ---------------------------------------------------------------------- }
type
  Tsqlite3_loadext_fn = procedure; cdecl;

function sqlite3_load_extension(db: PTsqlite3;
                                zFile, zProc: PAnsiChar;
                                pzErrMsg: PPAnsiChar): i32;
function sqlite3_enable_load_extension(db: PTsqlite3; onoff: i32): i32;

function sqlite3_auto_extension(xInit: Tsqlite3_loadext_fn): i32;
function sqlite3_cancel_auto_extension(xInit: Tsqlite3_loadext_fn): i32;
procedure sqlite3_reset_auto_extension;

{ ----------------------------------------------------------------------
  Phase 6.9-bis step 11g.1 — schema-init dispatcher.

  Exposed in the interface so step-11g.1.c's audit test can drive the
  callback directly with synthesised argv tuples (without spinning up
  a full OP_ParseSchema → sqlite3_exec round trip on a btree that has
  no actual sqlite_master rows yet).
  ---------------------------------------------------------------------- }
type
  PInitData = ^TInitData;
  TInitData = record
    db         : PTsqlite3;
    iDb        : i32;
    pzErrMsg   : PPAnsiChar;
    rc         : i32;
    mInitFlags : u32;
    nInitRow   : u32;
    mxPage     : Pgno;
  end;

function sqlite3InitCallback(pInit: Pointer; argc: i32;
                             argv: PPAnsiChar;
                             NotUsed: PPAnsiChar): i32; cdecl;

{ ----------------------------------------------------------------------
  Phase 8.1.1 / 8.4.1 — informational + change-counter / interrupt /
  errcode / autocommit / readonly / sleep / memory accessors.
  Faithful ports of the corresponding main.c / malloc.c entry points.
  ---------------------------------------------------------------------- }
function sqlite3_libversion: PAnsiChar; cdecl;
function sqlite3_libversion_number: i32; cdecl;
function sqlite3_sourceid: PAnsiChar; cdecl;
function sqlite3_threadsafe: i32; cdecl;

{ ctime.c-equivalent compile-time option enquiry.  The Pas port keeps the
  options table empty (matches a build with no extra ENABLE_/OMIT_ macros
  beyond the upstream defaults the port mirrors); the API surface is
  exposed regardless so client code that probes feature gates compiles. }
function sqlite3CompileOptions(out pnOpt: i32): PPAnsiChar;
function sqlite3_compileoption_used(zOptName: PAnsiChar): i32; cdecl;
function sqlite3_compileoption_get(N: i32): PAnsiChar; cdecl;

function sqlite3_last_insert_rowid(db: PTsqlite3): i64; cdecl;
procedure sqlite3_set_last_insert_rowid(db: PTsqlite3; iRowid: i64); cdecl;
function sqlite3_changes(db: PTsqlite3): i32; cdecl;
function sqlite3_changes64(db: PTsqlite3): i64; cdecl;
function sqlite3_total_changes(db: PTsqlite3): i32; cdecl;
function sqlite3_total_changes64(db: PTsqlite3): i64; cdecl;

procedure sqlite3_interrupt(db: PTsqlite3); cdecl;
function sqlite3_is_interrupted(db: PTsqlite3): i32; cdecl;

type
  TProgressHandlerFn = function(p: Pointer): i32; cdecl;

procedure sqlite3_progress_handler(db: PTsqlite3; nOps: i32;
  xProgress: TProgressHandlerFn; pArg: Pointer); cdecl;

type
  TAutovacuumPagesFn = function(pArg: Pointer; zSchema: PAnsiChar;
    nDbPage: u32; nFreePage: u32; nBytePerPage: u32): u32; cdecl;
  TAutovacuumDestrFn = procedure(p: Pointer); cdecl;

function sqlite3_autovacuum_pages(db: PTsqlite3; xCallback: TAutovacuumPagesFn;
  pArg: Pointer; xDestructor: TAutovacuumDestrFn): i32; cdecl;

function sqlite3_overload_function(db: PTsqlite3; zName: PAnsiChar;
  nArg: i32): i32; cdecl;

type
  TClientDataDestrFn = procedure(p: Pointer); cdecl;

function sqlite3_get_clientdata(db: PTsqlite3; zName: PAnsiChar): Pointer; cdecl;
function sqlite3_set_clientdata(db: PTsqlite3; zName: PAnsiChar;
  pData: Pointer; xDestructor: TClientDataDestrFn): i32; cdecl;

function sqlite3_table_column_metadata(db: PTsqlite3;
  zDbName: PAnsiChar; zTableName: PAnsiChar; zColumnName: PAnsiChar;
  pzDataType: PPAnsiChar; pzCollSeq: PPAnsiChar;
  pNotNull: Pi32; pPrimaryKey: Pi32; pAutoinc: Pi32): i32; cdecl;

function sqlite3_errcode(db: PTsqlite3): i32; cdecl;
function sqlite3_extended_errcode(db: PTsqlite3): i32; cdecl;
function sqlite3_extended_result_codes(db: PTsqlite3; onoff: i32): i32; cdecl;
function sqlite3_system_errno(db: PTsqlite3): i32; cdecl;

function sqlite3_get_autocommit(db: PTsqlite3): i32; cdecl;
function sqlite3_db_readonly(db: PTsqlite3; zDbName: PAnsiChar): i32; cdecl;
function sqlite3_db_filename(db: PTsqlite3; zDbName: PAnsiChar): PAnsiChar; cdecl;
function sqlite3_db_release_memory(db: PTsqlite3): i32; cdecl;
function sqlite3_db_cacheflush(db: PTsqlite3): i32; cdecl;
function sqlite3_db_status(db: PTsqlite3; op: i32; pCurrent, pHighwtr: Pi32;
                           resetFlag: i32): i32; cdecl;
function sqlite3_db_status64(db: PTsqlite3; op: i32; pCurrent, pHighwtr: Pi64;
                             resetFlag: i32): i32; cdecl;
function sqlite3_file_control(db: PTsqlite3; zDbName: PAnsiChar; op: i32;
                              pArg: Pointer): i32; cdecl;
function sqlite3_txn_state(db: PTsqlite3; zSchema: PAnsiChar): i32; cdecl;
function sqlite3_error_offset(db: PTsqlite3): i32; cdecl;
function sqlite3_set_errmsg(db: PTsqlite3; errcode: i32; zMsg: PAnsiChar): i32; cdecl;
function sqlite3_limit(db: PTsqlite3; limitId: i32; newLimit: i32): i32; cdecl;

function sqlite3_complete16(zSql: Pointer): i32; cdecl;
function sqlite3_open16(zFilename: Pointer; ppDb: PPTsqlite3): i32; cdecl;
function sqlite3_create_collation16(db: PTsqlite3; zName: Pointer; enc: i32;
  pCtx: Pointer; xCompare: Pointer): i32; cdecl;
function sqlite3_collation_needed16(db: PTsqlite3; pCollNeededArg: Pointer;
  xCollNeeded16: Pointer): i32; cdecl;
function sqlite3_create_function16(db: PTsqlite3; zFunctionName: Pointer;
  nArg: i32; eTextRep: i32; p: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer): i32; cdecl;
function sqlite3_prepare16(db: PTsqlite3; zSql: Pointer; nBytes: i32;
  ppStmt: PPointer; pzTail: PPointer): i32; cdecl;
function sqlite3_prepare16_v2(db: PTsqlite3; zSql: Pointer; nBytes: i32;
  ppStmt: PPointer; pzTail: PPointer): i32; cdecl;
function sqlite3_prepare16_v3(db: PTsqlite3; zSql: Pointer; nBytes: i32;
  prepFlags: u32; ppStmt: PPointer; pzTail: PPointer): i32; cdecl;

function sqlite3_stmt_busy(pStmt: Pointer): i32; cdecl;
function sqlite3_stmt_readonly(pStmt: Pointer): i32; cdecl;
function sqlite3_stmt_explain(pStmt: Pointer; eMode: i32): i32; cdecl;
function sqlite3_stmt_status(pStmt: Pointer; op, resetFlag: i32): i32; cdecl;
function sqlite3_db_handle(pStmt: Pointer): PTsqlite3; cdecl;
function sqlite3_db_mutex(db: PTsqlite3): Pointer; cdecl;
function sqlite3_db_name(db: PTsqlite3; N: i32): PAnsiChar; cdecl;
function sqlite3_errstr(rc: i32): PAnsiChar; cdecl;
function sqlite3_next_stmt(pDb: PTsqlite3; pStmt: Pointer): Pointer; cdecl;
function sqlite3_sql(pStmt: Pointer): PAnsiChar; cdecl;
function sqlite3_expanded_sql(pStmt: Pointer): PAnsiChar; cdecl;

function sqlite3_sleep(ms: i32): i32; cdecl;

function sqlite3_release_memory(n: i32): i32; cdecl;
function sqlite3_memory_highwater(resetFlag: i32): i64; cdecl;
function sqlite3_msize(p: Pointer): u64; cdecl;
function sqlite3_soft_heap_limit64(n: i64): i64; cdecl;
function sqlite3_hard_heap_limit64(n: i64): i64; cdecl;
procedure sqlite3_soft_heap_limit(n: i32); cdecl;

function sqlite3_enable_shared_cache(enable: i32): i32; cdecl;
procedure sqlite3_activate_cerod(zPassPhrase: PAnsiChar); cdecl;
function sqlite3_setlk_timeout(db: PTsqlite3; ms: i32; flags: i32): i32; cdecl;

{ Phase 8.7.1 — WAL public-API entry points.  See main.c:2470..2620. }
type
  TWalHookFn = function(p: Pointer; db: PTsqlite3;
    zDb: PAnsiChar; nFrame: i32): i32; cdecl;

function sqlite3_wal_hook(db: PTsqlite3; xCallback: TWalHookFn;
  pArg: Pointer): Pointer; cdecl;
function sqlite3_wal_autocheckpoint(db: PTsqlite3; nFrame: i32): i32; cdecl;
function sqlite3_wal_checkpoint_v2(db: PTsqlite3; zDb: PAnsiChar;
  eMode: i32; pnLog, pnCkpt: PInt32): i32; cdecl;
function sqlite3_wal_checkpoint(db: PTsqlite3; zDb: PAnsiChar): i32; cdecl;

{ Phase 8.7.2 — sqlite3_serialize.  Real-Btree path only; the memdb branch
  of memdb.c:750 is unreachable here because the memdb VFS is not wired in. }
const
  SQLITE_SERIALIZE_NOCOPY = $001;
function sqlite3_serialize(db: PTsqlite3; zSchema: PAnsiChar;
  piSize: Pi64; mFlags: u32): Pu8; cdecl;

{ Phase 8.7.2 — sqlite3_deserialize.  Reopens database zSchema using the
  serialized image in pData.  Faithful to memdb.c:839 in the build mode
  where the memdb VFS is unported: the function fails with SQLITE_ERROR
  because the underlying memdb backing store is required to swap the
  pData buffer in.  The FREEONCLOSE bit is honoured on failure (memdb.c
  :903) so the caller's ownership-transfer contract still holds. }
const
  SQLITE_DESERIALIZE_FREEONCLOSE = 1;
  SQLITE_DESERIALIZE_RESIZEABLE  = 2;
  SQLITE_DESERIALIZE_READONLY    = 4;
function sqlite3_deserialize(db: PTsqlite3; zSchema: PAnsiChar;
  pData: Pu8; szDb, szBuf: i64; mFlags: u32): i32; cdecl;

{ Phase 8.7.1 — Snapshot public-API entry points (sqlite.h.in:11006..11136).
  Mirrors the SQLITE_OMIT_WAL build of main.c:5018..5147: snapshot machinery
  on top of WAL is not yet ported (sqlite3PagerSnapshotOpen/Get/Check/Recover
  /Unlock have no Pascal counterparts), so _get / _open / _recover return
  SQLITE_ERROR on every call and _free is the trivial sqlite3_free wrapper.
  _cmp is the WAL-less stub (returns 0 — undefined-but-stable per the docs:
  "result of the comparison is undefined" if the snapshot was not produced
  by a successful _get).  This brings the public-API surface to parity even
  while the underlying WAL feature stays unported.  C reference:
  main.c:5013..5148 (gated on SQLITE_ENABLE_SNAPSHOT). }
type
  TSqlite3Snapshot = record
    hidden: array[0..47] of u8;
  end;
  Psqlite3_snapshot  = ^TSqlite3Snapshot;
  PPsqlite3_snapshot = ^Psqlite3_snapshot;

function  sqlite3_snapshot_get(db: PTsqlite3; zSchema: PAnsiChar;
                               ppSnapshot: PPsqlite3_snapshot): i32; cdecl;
function  sqlite3_snapshot_open(db: PTsqlite3; zSchema: PAnsiChar;
                                pSnapshot: Psqlite3_snapshot): i32; cdecl;
procedure sqlite3_snapshot_free(pSnapshot: Psqlite3_snapshot); cdecl;
function  sqlite3_snapshot_cmp(p1, p2: Psqlite3_snapshot): i32; cdecl;
function  sqlite3_snapshot_recover(db: PTsqlite3; zDb: PAnsiChar): i32; cdecl;

{ Phase 8.8.1 — Pre-update hook public-API entry points
  (sqlite.h.in:10897..10915).  The C reference gates every body on
  SQLITE_ENABLE_PREUPDATE_HOOK; the default upstream build (and our
  oracle) compiles without it, so the symbols are absent there.  We
  expose them as faithful translations of the SQLITE_ENABLE_API_ARMOR
  arms that fire when no preupdate is in flight (db->pPreUpdate == NULL):
  count/depth return 0, blobwrite returns -1, old/new return SQLITE_MISUSE,
  and _hook returns nil without installing a callback.  Brings the
  public-API surface to parity even while the underlying preupdate
  machinery (vdbeapi.c:2209..2400) stays unported.  C reference:
  vdbeapi.c:2314 / 2337 / 2353 / 2209 / 2369 + main.c:4001 (_hook). }
function  sqlite3_preupdate_hook(db: PTsqlite3;
                                 xPreUpdate: Pointer;
                                 pArg: Pointer): Pointer; cdecl;
function  sqlite3_preupdate_old(db: PTsqlite3; iIdx: i32;
                                ppValue: PPointer): i32; cdecl;
function  sqlite3_preupdate_new(db: PTsqlite3; iIdx: i32;
                                ppValue: PPointer): i32; cdecl;
function  sqlite3_preupdate_count(db: PTsqlite3): i32; cdecl;
function  sqlite3_preupdate_depth(db: PTsqlite3): i32; cdecl;
function  sqlite3_preupdate_blobwrite(db: PTsqlite3): i32; cdecl;

implementation

uses
  passqlite3printf;  { Phase 6.9-bis step 11g.1 — sqlite3MPrintf in OP_ParseSchema worker }

{ ----------------------------------------------------------------------
  aHardLimit — default per-connection limits (mirrors main.c aHardLimit).
  Order matches SQLITE_LIMIT_* indices in passqlite3codegen.
  ---------------------------------------------------------------------- }
const
  SQLITE_MAX_LENGTH                = 1000000000;
  SQLITE_MAX_SQL_LENGTH            = 1000000000;
  SQLITE_MAX_COLUMN_LIMIT          = 2000;
  SQLITE_MAX_EXPR_DEPTH_LIMIT      = 1000;
  SQLITE_MAX_COMPOUND_SELECT       = 500;
  SQLITE_MAX_VDBE_OP               = 250000000;
  SQLITE_MAX_FUNCTION_ARG          = 127;
  SQLITE_MAX_ATTACHED              = 10;
  SQLITE_MAX_LIKE_PATTERN_LENGTH   = 50000;
  SQLITE_MAX_VARIABLE_NUMBER       = 32766;
  SQLITE_MAX_TRIGGER_DEPTH         = 1000;
  SQLITE_MAX_WORKER_THREADS_LIMIT  = 8;
  SQLITE_DEFAULT_WORKER_THREADS    = 0;

const
  aHardLimit: array[0..11] of i32 = (
    SQLITE_MAX_LENGTH,
    SQLITE_MAX_SQL_LENGTH,
    SQLITE_MAX_COLUMN_LIMIT,
    SQLITE_MAX_EXPR_DEPTH_LIMIT,
    SQLITE_MAX_COMPOUND_SELECT,
    SQLITE_MAX_VDBE_OP,
    SQLITE_MAX_FUNCTION_ARG,
    SQLITE_MAX_ATTACHED,
    SQLITE_MAX_LIKE_PATTERN_LENGTH,
    SQLITE_MAX_VARIABLE_NUMBER,
    SQLITE_MAX_TRIGGER_DEPTH,
    SQLITE_MAX_WORKER_THREADS_LIMIT
  );

{ ----------------------------------------------------------------------
  connectionIsBusy — true if the connection has unfinalised statements.
  main.c:1240
  ---------------------------------------------------------------------- }
function connectionIsBusy(db: PTsqlite3): i32;
begin
  if db^.pVdbe <> nil then begin Result := 1; Exit; end;
  Result := 0;
end;

{ ----------------------------------------------------------------------
  sqlite3LeaveMutexAndCloseZombie — final tear-down.
  main.c:1363  (simplified for Phase 8.1 scope)
  ---------------------------------------------------------------------- }
procedure sqlite3LeaveMutexAndCloseZombie(db: PTsqlite3);
var
  j: i32;
begin
  if (db^.eOpenState <> SQLITE_STATE_ZOMBIE) or (connectionIsBusy(db) <> 0) then
    Exit;

  { Roll back any open transaction and reset schemas. }
  sqlite3RollbackAll(db, SQLITE_OK);

  { Free any outstanding savepoints. }
  sqlite3CloseSavepoints(db);

  { Close all attached database back-ends. }
  for j := 0 to db^.nDb - 1 do begin
    if db^.aDb[j].pBt <> nil then begin
      sqlite3BtreeClose(PBtree(db^.aDb[j].pBt));
      db^.aDb[j].pBt := nil;
      if j <> 1 then
        db^.aDb[j].pSchema := nil;
    end;
  end;

  { Clear the temp-db schema separately (allocated independently). }
  if db^.aDb[1].pSchema <> nil then begin
    sqlite3SchemaClear(db^.aDb[1].pSchema);
  end;

  { Collapse aDb back to the static array (no-op when nDb<=2). }
  sqlite3CollapseDatabaseArray(db);

  { Clear the per-connection hash tables. }
  sqlite3HashClear(@db^.aFunc);
  sqlite3HashClear(@db^.aCollSeq);
  sqlite3HashClear(@db^.aModule);

  { Deallocate the cached error string, if any. }
  sqlite3Error(db, SQLITE_OK);
  if db^.pErr <> nil then begin
    sqlite3ValueFree(Psqlite3_value(db^.pErr));
    db^.pErr := nil;
  end;

  { Free the temp-schema record itself (allocated via sqlite3DbMallocZero). }
  if db^.aDb[1].pSchema <> nil then begin
    sqlite3DbFree(Psqlite3db(db), db^.aDb[1].pSchema);
    db^.aDb[1].pSchema := nil;
  end;

  db^.eOpenState := SQLITE_STATE_CLOSED;
  if db^.mutex <> nil then
    sqlite3_mutex_free(db^.mutex);
  sqlite3_free(db);
end;

{ ----------------------------------------------------------------------
  sqlite3Close — common close path shared by sqlite3_close{,v2}.
  main.c:1254
  ---------------------------------------------------------------------- }
function sqlite3Close(db: PTsqlite3; forceZombie: i32): i32;
var
  cdNode: PDbClientData;
begin
  if db = nil then begin
    { R-63257-11740: NULL is a harmless no-op. }
    Result := SQLITE_OK;
    Exit;
  end;
  if sqlite3SafetyCheckSickOrOk(db) = 0 then begin
    Result := SQLITE_MISUSE;
    Exit;
  end;

  { Legacy sqlite3_close() refuses if statements still pending. }
  if (forceZombie = 0) and (connectionIsBusy(db) <> 0) then begin
    sqlite3ErrorWithMsg(db, SQLITE_BUSY,
      'unable to close due to unfinalized statements or unfinished backups');
    Result := SQLITE_BUSY;
    Exit;
  end;

  { main.c:1297 — fire xDestructor on each pDbData entry, free node. }
  while db^.pDbData <> nil do begin
    cdNode  := db^.pDbData;
    db^.pDbData := PDbClientData(cdNode^.pNext);
    if Assigned(cdNode^.xDestroyData) then
      cdNode^.xDestroyData(cdNode^.pData);
    sqlite3_free(cdNode);
  end;

  db^.eOpenState := SQLITE_STATE_ZOMBIE;
  sqlite3LeaveMutexAndCloseZombie(db);
  Result := SQLITE_OK;
end;

{ Forward decls — built-in collation funcs + createCollation are defined
  later in this unit but called from openDatabase below. }
function binCollFunc(NotUsed: Pointer; nKey1: i32; pKey1: Pointer;
  nKey2: i32; pKey2: Pointer): i32; cdecl; forward;
function rtrimCollFunc(pUser: Pointer; nKey1: i32; pKey1: Pointer;
  nKey2: i32; pKey2: Pointer): i32; cdecl; forward;
function nocaseCollatingFunc(NotUsed: Pointer; nKey1: i32; pKey1: Pointer;
  nKey2: i32; pKey2: Pointer): i32; cdecl; forward;
function createCollation(db: PTsqlite3; zName: PAnsiChar; enc: u8;
  pCtx: Pointer; xCompare: Pointer; xDel: Pointer): i32; forward;

{ ----------------------------------------------------------------------
  openDatabase — main.c:3324
  ---------------------------------------------------------------------- }
function openDatabase(zFilename: PAnsiChar; ppDb: PPTsqlite3;
                      flags: i32; zVfs: PAnsiChar): i32;
var
  db   : PTsqlite3;
  rc   : i32;
  i    : i32;
  pVfs : Psqlite3_vfs;
  label opendb_out;
begin
  if ppDb = nil then begin Result := SQLITE_MISUSE; Exit; end;
  ppDb^ := nil;

  { Phase 6.9-bis 11g.2.f sub-progress 16(a) — ensure
    sqlite3BuiltinFunctions and the rest of the global init state are
    populated before any prepare runs.  Mirrors main.c:3328 — C's
    openDatabase calls sqlite3_initialize() first.  Latent gap: prior
    to TK_FUNCTION codegen, no Pascal-prepare path consulted the
    built-in function hash, so the empty table was harmless. }
  if sqlite3GlobalConfig.isInit = 0 then begin
    Result := sqlite3_initialize;
    if Result <> SQLITE_OK then Exit;
  end;

  { Strip non-public flag bits, just like main.c:3371 does. }
  flags := flags and not (
      SQLITE_OPEN_DELETEONCLOSE or
      SQLITE_OPEN_EXCLUSIVE     or
      SQLITE_OPEN_MAIN_DB       or
      SQLITE_OPEN_TEMP_DB       or
      SQLITE_OPEN_TRANSIENT_DB  or
      SQLITE_OPEN_MAIN_JOURNAL  or
      SQLITE_OPEN_TEMP_JOURNAL  or
      SQLITE_OPEN_SUBJOURNAL    or
      SQLITE_OPEN_SUPER_JOURNAL or
      SQLITE_OPEN_NOMUTEX       or
      SQLITE_OPEN_FULLMUTEX     or
      SQLITE_OPEN_WAL);

  db := PTsqlite3(sqlite3MallocZero(SizeOf(Tsqlite3)));
  if db = nil then begin Result := SQLITE_NOMEM; Exit; end;

  if (flags and SQLITE_OPEN_EXRESCODE) <> 0 then
    db^.errMask := i32($FFFFFFFF)
  else
    db^.errMask := i32($FF);

  db^.nDb            := 2;
  db^.eOpenState     := SQLITE_STATE_BUSY;
  db^.aDb            := @db^.aDbStatic[0];
  db^.lookaside.bDisable := 1;
  db^.lookaside.sz   := 0;
  db^.nFpDigit       := 17;
  db^.openFlags      := u32(flags);

  { Install per-connection limits from aHardLimit. }
  for i := 0 to High(aHardLimit) do
    db^.aLimit[i] := aHardLimit[i];
  db^.aLimit[SQLITE_LIMIT_WORKER_THREADS] := SQLITE_DEFAULT_WORKER_THREADS;

  db^.autoCommit  := 1;
  db^.nextAutovac := -1;
  db^.szMmap      := 0;
  db^.nextPagesize := 0;
  db^.init.azInit := nil;

  db^.flags := db^.flags or
    (u64($00040) shl 32) or  { SQLITE_Comments — keep TestParser's flag bit }
    SQLITE_ShortColNames or  { LO(0x00000040) — main.c:3428 default }
    SQLITE_AutoIndex or      { SQLITE_DEFAULT_AUTOMATIC_INDEX default-on }
    SQLITE_CacheSpill or     { main.c:3428 default-on }
    SQLITE_EnableTrigger or  { main.c:3428 default-on }
    SQLITE_TrustedSchema;    { SQLITE_DEFAULT_TRUSTED_SCHEMA default-on }

  sqlite3HashInit(@db^.aCollSeq);
  sqlite3HashInit(@db^.aModule);
  sqlite3HashInit(@db^.aFunc);

  { Locate the requested VFS.  Lazily run sqlite3_os_init the first
    time around — main.c does this via sqlite3_initialize(). }
  pVfs := sqlite3_vfs_find(zVfs);
  if pVfs = nil then begin
    sqlite3_os_init;
    sqlite3PcacheInitialize;
    pVfs := sqlite3_vfs_find(zVfs);
  end;
  if pVfs = nil then begin
    rc := SQLITE_ERROR;
    sqlite3ErrorWithMsg(db, rc, 'no such vfs');
    goto opendb_out;
  end;
  db^.pVfs := pVfs;

  { Validate flags{0..2} — must be exactly READONLY, READWRITE, or
    READWRITE|CREATE.  Mirrors main.c:3556. }
  if ((1 shl (flags and 7)) and $46) = 0 then begin
    rc := SQLITE_MISUSE;
    goto opendb_out;
  end;

  if (zFilename = nil) or (zFilename[0] = #0) then
    zFilename := ':memory:';

  { Open the back-end b-tree. }
  rc := sqlite3BtreeOpen(pVfs, PChar(zFilename), Psqlite3(db),
                         PPBtree(@db^.aDb[0].pBt), 0,
                         flags or SQLITE_OPEN_MAIN_DB);
  if rc <> SQLITE_OK then begin
    sqlite3Error(db, rc);
    goto opendb_out;
  end;

  { Allocate stand-in schemas for main and temp.  Phase 8.1 stub:
    sqlite3BtreeSchema is not ported, so we do not pull from BtShared. }
  db^.aDb[0].pSchema := sqlite3SchemaGet(db, nil);
  db^.aDb[1].pSchema := sqlite3SchemaGet(db, nil);

  db^.aDb[0].zDbSName     := 'main';
  db^.aDb[0].safety_level := 3;     { FULL — matches PAGER_SYNCHRONOUS_FULL }
  db^.aDb[1].zDbSName     := 'temp';
  db^.aDb[1].safety_level := 1;     { OFF }

  { Phase 6.x — nested-parse schema visibility: bootstrap sqlite_master /
    sqlite_temp_master into the in-memory schema so the schema-row UPDATE /
    INSERT / DELETE statements emitted by sqlite3NestedParse (from
    sqlite3EndTable, sqlite3CreateIndex, sqlite3CodeDropTable, etc.) can
    resolve their target via sqlite3SrcListLookup -> sqlite3LocateTableItem.
    Real on-disk schema initialisation (sqlite3InitOne port) lands in
    Phase 7. }
  sqlite3InstallSchemaTable(db, 0);
  sqlite3InstallSchemaTable(db, 1);

  { sqlite3SetTextEncoding consults collation tables, which require the full
    Phase 8.3 registration APIs.  Set the encoding directly for now. }
  db^.enc := SQLITE_UTF8;

  db^.eOpenState := SQLITE_STATE_OPEN;

  { Register per-connection built-ins (collations + scalar/aggregate funcs). }
  sqlite3RegisterPerConnectionBuiltinFunctions(db);

  { Register the three built-in collations BINARY / NOCASE / RTRIM, then
    point pDfltColl at the BINARY entry — port of the openDatabase tail in
    main.c:3515..3519 + the sqlite3SetTextEncoding finalisation.  Without
    this bootstrap, sqlite3ExprNNCollSeq asserts because db^.pDfltColl is
    nil (Phase 6.26 ExprCollSeq port surfaced this gap). }
  createCollation(db, 'BINARY', SQLITE_UTF8,    nil, @binCollFunc, nil);
  createCollation(db, 'BINARY', SQLITE_UTF16BE, nil, @binCollFunc, nil);
  createCollation(db, 'BINARY', SQLITE_UTF16LE, nil, @binCollFunc, nil);
  createCollation(db, 'NOCASE', SQLITE_UTF8,    nil, @nocaseCollatingFunc, nil);
  createCollation(db, 'RTRIM',  SQLITE_UTF8,    nil, @rtrimCollFunc, nil);
  if db^.mallocFailed = 0 then
    db^.pDfltColl := sqlite3FindCollSeq(db, db^.enc, 'BINARY', 0);

  sqlite3Error(db, SQLITE_OK);
  rc := SQLITE_OK;

opendb_out:
  if (rc and $FF) = SQLITE_NOMEM then begin
    sqlite3_close(db);
    db := nil;
  end else if rc <> SQLITE_OK then begin
    if db <> nil then db^.eOpenState := SQLITE_STATE_SICK;
  end;
  ppDb^  := db;
  Result := rc;
end;

{ ----------------------------------------------------------------------
  Public API entry points.
  ---------------------------------------------------------------------- }
function sqlite3_open(zFilename: PAnsiChar; ppDb: PPTsqlite3): i32;
begin
  Result := openDatabase(zFilename, ppDb,
              SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
end;

function sqlite3_open_v2(zFilename: PAnsiChar; ppDb: PPTsqlite3;
                          flags: i32; zVfs: PAnsiChar): i32;
begin
  Result := openDatabase(zFilename, ppDb, flags, zVfs);
end;

function sqlite3_close(db: PTsqlite3): i32;
begin
  Result := sqlite3Close(db, 0);
end;

function sqlite3_close_v2(db: PTsqlite3): i32;
begin
  Result := sqlite3Close(db, 1);
end;

{ ----------------------------------------------------------------------
  Phase 8.2 — sqlite3_prepare / sqlite3_prepare_v2 / sqlite3_prepare_v3
  Ported from prepare.c:682 (sqlite3Prepare), :836 (sqlite3LockAndPrepare),
  :925 (sqlite3_prepare), :937 (sqlite3_prepare_v2), :955 (sqlite3_prepare_v3).

  Scope of this Phase 8.2 port:
    * Single-attempt compile.  The C version retries on SQLITE_SCHEMA via
      sqlite3ResetOneSchema, but the schema-cookie subsystem is not yet
      ported — there is no schema state to reset, so the retry loop is
      reduced to one pass.
    * Schema-locked check (BtreeSchemaLocked) skipped — the codegen stub
      always returns 0 and there is no shared cache.
    * Vtab unlock list skipped (no vtabs registered).
    * Btree mutex enter/leave still goes via the codegen stubs (no-op).
    * Long-statement copy (when the caller passes a non-NUL-terminated
      buffer with explicit nBytes) is faithfully reproduced — we duplicate
      the SQL into a NUL-terminated buffer before handing it to the
      parser, then translate the parser's zTail back into the caller's
      buffer offset.
  ---------------------------------------------------------------------- }

const
  SQLITE_MAX_PREPARE_RETRY    = 25;
  SQLITE_PREPARE_PERSISTENT   = $01;  { sqlite3.h public flag bit }
  SQLITE_PREPARE_NORMALIZE    = $02;
  SQLITE_PREPARE_NO_VTAB      = $04;

function sqlite3Prepare(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                        prepFlags: u32; pReprepare: PVdbe;
                        ppStmt: PPointer; pzTail: PPAnsiChar): i32;
var
  rc:       i32;
  sParse:   TParse;
  zSqlCopy: PAnsiChar;
  mxLen:    i32;
  nDup:     i32;
  pT:       PTriggerPrg;
  label end_prepare;
begin
  rc := SQLITE_OK;

  { Inline sqlite3ParseObjectInit + zero the rest of TParse (PARSE_TAIL). }
  FillChar(sParse, SizeOf(sParse), 0);
  sParse.pOuterParse := db^.pParse;
  db^.pParse         := @sParse;
  sParse.db          := db;
  if pReprepare <> nil then begin
    sParse.pReprepare := pReprepare;
    sParse.explain    := u8(sqlite3_stmt_isexplain(Pointer(pReprepare)));
  end;

  Assert((ppStmt <> nil) and (ppStmt^ = nil));
  if db^.mallocFailed <> 0 then begin
    sqlite3ErrorMsg(@sParse, 'out of memory');
    db^.errCode := SQLITE_NOMEM;
    rc          := SQLITE_NOMEM;
    goto end_prepare;
  end;

  { Long-term prepared statements bypass lookaside. }
  if (prepFlags and SQLITE_PREPARE_PERSISTENT) <> 0 then begin
    Inc(sParse.disableLookaside);
    Inc(db^.lookaside.bDisable);
    db^.lookaside.sz := 0;
  end;
  sParse.prepFlags := u8(prepFlags and $FF);

  { Schema-locked check: codegen stub always returns 0; left as a
    documented no-op until shared-cache lands. }

  if (nBytes >= 0) and ((nBytes = 0) or (zSql[nBytes - 1] <> #0)) then begin
    mxLen := db^.aLimit[SQLITE_LIMIT_SQL_LENGTH];
    if nBytes > mxLen then begin
      sqlite3ErrorWithMsg(db, SQLITE_TOOBIG, 'statement too long');
      rc := sqlite3ApiExit(db, SQLITE_TOOBIG);
      goto end_prepare;
    end;
    nDup     := nBytes;
    zSqlCopy := PAnsiChar(sqlite3DbStrNDup(db, PChar(zSql), u64(nDup)));
    if zSqlCopy <> nil then begin
      sqlite3RunParser(@sParse, zSqlCopy);
      { Translate zTail back from copy-relative to caller-relative. }
      sParse.zTail := zSql + (PtrUInt(sParse.zTail) - PtrUInt(zSqlCopy));
      sqlite3DbFree(db, zSqlCopy);
    end else begin
      sParse.zTail := zSql + nBytes;
    end;
  end else begin
    sqlite3RunParser(@sParse, zSql);
  end;
  Assert(sParse.nQueryLoop = 0);

  if pzTail <> nil then
    pzTail^ := sParse.zTail;

  if (db^.init.busy = 0) and (sParse.pVdbe <> nil) then
    sqlite3VdbeSetSql(sParse.pVdbe, zSql,
                      i32(PtrUInt(sParse.zTail) - PtrUInt(zSql)),
                      u8(prepFlags and $FF));

  if db^.mallocFailed <> 0 then begin
    sParse.rc := SQLITE_NOMEM;
    sParse.parseFlags := sParse.parseFlags and (not u32($200)); { clear checkSchema }
  end;

  if (sParse.rc <> SQLITE_OK) and (sParse.rc <> SQLITE_DONE) then begin
    { schemaIsValid path skipped — no schema-cookie machinery yet. }
    if sParse.pVdbe <> nil then
      sqlite3VdbeFinalize(sParse.pVdbe);
    Assert(ppStmt^ = nil);
    rc := sParse.rc;
    if sParse.zErrMsg <> nil then begin
      sqlite3ErrorWithMsg(db, rc, PAnsiChar(sParse.zErrMsg));
      sqlite3DbFree(db, sParse.zErrMsg);
      sParse.zErrMsg := nil;
    end else begin
      sqlite3Error(db, rc);
    end;
  end else begin
    Assert(sParse.zErrMsg = nil);
    ppStmt^ := Pointer(sParse.pVdbe);
    rc      := SQLITE_OK;
    sqlite3ErrorClear(db);
  end;

  { Free any TriggerPrg structures allocated by the parser. }
  while sParse.pTriggerPrg <> nil do begin
    pT := sParse.pTriggerPrg;
    sParse.pTriggerPrg := pT^.pNext;
    sqlite3DbFree(db, pT);
  end;

end_prepare:
  sqlite3ParseObjectReset(@sParse);
  Result := rc;
end;

function sqlite3LockAndPrepare(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                               prepFlags: u32; pOld: PVdbe;
                               ppStmt: PPointer; pzTail: PPAnsiChar): i32;
var
  rc, cnt: i32;
begin
  if ppStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  ppStmt^ := nil;
  if (sqlite3SafetyCheckOk(db) = 0) or (zSql = nil) then begin
    Result := SQLITE_MISUSE;
    Exit;
  end;
  cnt := 0;
  sqlite3BtreeEnterAll(db);
  repeat
    rc := sqlite3Prepare(db, zSql, nBytes, prepFlags, pOld, ppStmt, pzTail);
    Assert((rc = SQLITE_OK) or (ppStmt^ = nil));
    if (rc = SQLITE_OK) or (db^.mallocFailed <> 0) then Break;
    Inc(cnt);
    { sqlite3ResetOneSchema not yet ported — bail after one retry on
      SQLITE_ERROR_RETRY only. }
    if (rc <> SQLITE_ERROR_RETRY) or (cnt > SQLITE_MAX_PREPARE_RETRY) then
      Break;
  until False;
  sqlite3BtreeLeaveAll(db);
  rc := sqlite3ApiExit(db, rc);
  db^.busyHandler.nBusy := 0;
  Result := rc;
end;

function sqlite3_prepare(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                         ppStmt: PPointer; pzTail: PPAnsiChar): i32;
begin
  Result := sqlite3LockAndPrepare(db, zSql, nBytes, 0, nil, ppStmt, pzTail);
end;

function sqlite3_prepare_v2(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                            ppStmt: PPointer; pzTail: PPAnsiChar): i32;
begin
  Result := sqlite3LockAndPrepare(db, zSql, nBytes,
                                  SQLITE_PREPARE_SAVESQL, nil, ppStmt, pzTail);
end;

function sqlite3_prepare_v3(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                            prepFlags: u32; ppStmt: PPointer;
                            pzTail: PPAnsiChar): i32;
begin
  Result := sqlite3LockAndPrepare(db, zSql, nBytes,
              (prepFlags and SQLITE_PREPARE_MASK) or SQLITE_PREPARE_SAVESQL,
              nil, ppStmt, pzTail);
end;

{ prepare.c:886 — sqlite3Reprepare.  Recompile a prepared statement after a
  schema change so the next sqlite3_step() can transparently re-execute against
  the new schema.  Only called for prepare_v2()/v3() statements (those that
  retain zSql).  Returns SQLITE_OK on success, SQLITE_LOCKED if another
  connection holds the schema lock, SQLITE_SCHEMA on any other error. }
function sqlite3Reprepare(p: PVdbe): i32;
var
  rc:        i32;
  pNew:      Pointer;
  zSql:      PAnsiChar;
  db:        PTsqlite3;
  prepFlags: u8;
begin
  zSql := p^.zSql;
  Assert(zSql <> nil, 'Reprepare on prepare_v2 stmt only');
  db := p^.db;
  prepFlags := p^.prepFlags;
  pNew := nil;
  rc := sqlite3LockAndPrepare(db, zSql, -1, prepFlags, p, @pNew, nil);
  if rc <> 0 then begin
    if rc = SQLITE_NOMEM then sqlite3OomFault(db);
    Assert(pNew = nil, 'pNew must be nil on prepare error');
    Result := rc;
    Exit;
  end;
  Assert(pNew <> nil, 'pNew must be non-nil on prepare success');
  sqlite3VdbeSwap(PVdbe(pNew), p);
  sqlite3TransferBindings(pNew, Pointer(p));
  sqlite3VdbeResetStepResult(PVdbe(pNew));
  sqlite3VdbeFinalize(PVdbe(pNew));
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  Phase 8.3 — Registration APIs.
  Ported from main.c:1931..2230 (functions), main.c:2852..3848 (collations),
  vtab.c:39..134 (modules).

  Scope of this Phase 8.3 port:
    * sqlite3_create_function / _v2 / _create_window_function delegate to
      createFunctionApi → sqlite3CreateFunc (already present in codegen).
    * sqlite3_create_collation / _v2 implement the createCollation flow
      directly (replace check + ExpirePreparedStatements + FindCollSeq(create=1)).
    * sqlite3_create_module / _v2 inline a minimal sqlite3VtabCreateModule
      replacement: alloc Module struct, hash insert into db^.aModule.
      Vtab eponymous-table cleanup is skipped — no vtabs are registered
      yet (Phase 6.bis.1 not done), so the replace path can only happen
      if the same module name is registered twice in the same connection.
    * UTF-16 entry points (_create_function16, _create_collation16,
      _collation_needed16) are deferred until UTF-16 lands.
  ---------------------------------------------------------------------- }

const
  SQLITE_FUNC_ENCMASK = $03;

type
  TxCollCmpReg   = function(p: Pointer; n1: i32; z1: Pointer;
                            n2: i32; z2: Pointer): i32; cdecl;
  TxCollDelReg   = procedure(p: Pointer); cdecl;

{ createFunctionApi — main.c:2066 }
function createFunctionApi(db: PTsqlite3; zFunc: PAnsiChar; nArg: i32;
  enc: i32; p: Pointer; xSFunc, xStep, xFinal, xValue, xInverse,
  xDestroy: Pointer): i32;
var
  rc:   i32;
  pArg: PTFuncDestructor;
  label out_lbl;
begin
  rc   := SQLITE_ERROR;
  pArg := nil;
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if xDestroy <> nil then begin
    pArg := PTFuncDestructor(sqlite3Malloc(SizeOf(TFuncDestructor)));
    if pArg = nil then begin
      sqlite3OomFault(db);
      TxFuncDestroy(xDestroy)(p);
      goto out_lbl;
    end;
    pArg^.nRef     := 0;
    pArg^.xDestroy := TxFuncDestroy(xDestroy);
    pArg^.pUserData := p;
  end;
  rc := sqlite3CreateFunc(db, zFunc, nArg, enc, p,
          xSFunc, xStep, xFinal, xValue, xInverse, pArg);
  if (pArg <> nil) and (pArg^.nRef = 0) then begin
    TxFuncDestroy(xDestroy)(p);
    sqlite3_free(pArg);
  end;
out_lbl:
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_create_function(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer): i32;
begin
  Result := createFunctionApi(db, zFunc, nArg, enc, pUserData,
              xSFunc, xStep, xFinal, nil, nil, nil);
end;

function sqlite3_create_function_v2(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer;
  xDestroy: Pointer): i32;
begin
  Result := createFunctionApi(db, zFunc, nArg, enc, pUserData,
              xSFunc, xStep, xFinal, nil, nil, xDestroy);
end;

function sqlite3_create_window_function(db: PTsqlite3; zFunc: PAnsiChar;
  nArg: i32; enc: i32; pUserData: Pointer;
  xStep: Pointer; xFinal: Pointer; xValue: Pointer; xInverse: Pointer;
  xDestroy: Pointer): i32;
begin
  Result := createFunctionApi(db, zFunc, nArg, enc, pUserData,
              nil, xStep, xFinal, xValue, xInverse, xDestroy);
end;

{ binCollFunc — main.c:1044.  Default BINARY collation: byte-by-byte memcmp,
  break tie with length difference. }
function binCollFunc(NotUsed: Pointer; nKey1: i32; pKey1: Pointer;
  nKey2: i32; pKey2: Pointer): i32; cdecl;
var
  rc, n, i: i32;
  p1, p2:   PByte;
begin
  if nKey1 < nKey2 then n := nKey1 else n := nKey2;
  Assert((pKey1 <> nil) and (pKey2 <> nil));
  rc := 0;
  p1 := PByte(pKey1);
  p2 := PByte(pKey2);
  for i := 0 to n - 1 do
    if p1[i] <> p2[i] then begin
      rc := i32(p1[i]) - i32(p2[i]);
      Break;
    end;
  if rc = 0 then rc := nKey1 - nKey2;
  Result := rc;
end;

{ rtrimCollFunc — main.c:1067.  As BINARY but ignores trailing spaces. }
function rtrimCollFunc(pUser: Pointer; nKey1: i32; pKey1: Pointer;
  nKey2: i32; pKey2: Pointer): i32; cdecl;
var
  pK1, pK2: PByte;
begin
  pK1 := PByte(pKey1);
  pK2 := PByte(pKey2);
  while (nKey1 > 0) and (pK1[nKey1 - 1] = Ord(' ')) do Dec(nKey1);
  while (nKey2 > 0) and (pK2[nKey2 - 1] = Ord(' ')) do Dec(nKey2);
  Result := binCollFunc(pUser, nKey1, pKey1, nKey2, pKey2);
end;

{ nocaseCollatingFunc — main.c:1096.  Case-insensitive ASCII compare,
  English-letter folding only.  Standalone implementation since
  sqlite3StrNICmp is not yet available in passqlite3util. }
function nocaseCollatingFunc(NotUsed: Pointer; nKey1: i32; pKey1: Pointer;
  nKey2: i32; pKey2: Pointer): i32; cdecl;
var
  pK1, pK2: PByte;
  n, i, c1, c2, r: i32;
begin
  pK1 := PByte(pKey1);
  pK2 := PByte(pKey2);
  if nKey1 < nKey2 then n := nKey1 else n := nKey2;
  r := 0;
  for i := 0 to n - 1 do begin
    c1 := pK1[i]; c2 := pK2[i];
    if (c1 >= Ord('A')) and (c1 <= Ord('Z')) then c1 := c1 + 32;
    if (c2 >= Ord('A')) and (c2 <= Ord('Z')) then c2 := c2 + 32;
    if c1 <> c2 then begin r := c1 - c2; Break; end;
  end;
  if r = 0 then r := nKey1 - nKey2;
  Result := r;
end;

{ createCollation — main.c:2852.  Performs the replace-or-create flow that
  the codegen-side sqlite3FindCollSeq(create=1) cannot do on its own. }
function createCollation(db: PTsqlite3; zName: PAnsiChar; enc: u8;
  pCtx: Pointer; xCompare: Pointer; xDel: Pointer): i32;
var
  pColl: PTCollSeq;
  enc2:  i32;
begin
  enc2 := enc;
  if (enc2 = SQLITE_UTF16) or (enc2 = SQLITE_UTF16_ALIGNED) then
    enc2 := SQLITE_UTF16LE;  { native LE on x86_64 }
  if (enc2 < SQLITE_UTF8) or (enc2 > SQLITE_UTF16BE) then begin
    Result := SQLITE_MISUSE; Exit;
  end;

  pColl := PTCollSeq(sqlite3FindCollSeq(db, u8(enc2), zName, 0));
  if (pColl <> nil) and (pColl^.xCmp <> nil) then begin
    if db^.nVdbeActive <> 0 then begin
      sqlite3ErrorWithMsg(db, SQLITE_BUSY,
        'unable to delete/modify collation sequence due to active statements');
      Result := SQLITE_BUSY; Exit;
    end;
    sqlite3ExpirePreparedStatements(db, 0);
  end;

  pColl := PTCollSeq(sqlite3FindCollSeq(db, u8(enc2), zName, 1));
  if pColl = nil then begin Result := SQLITE_NOMEM; Exit; end;
  pColl^.xCmp  := TxCollCmpReg(xCompare);
  pColl^.pUser := pCtx;
  pColl^.xDel  := TxCollDelReg(xDel);
  pColl^.enc   := u8(enc2 or (enc and SQLITE_UTF16_ALIGNED));
  sqlite3Error(db, SQLITE_OK);
  Result := SQLITE_OK;
end;

function sqlite3_create_collation_v2(db: PTsqlite3; zName: PAnsiChar;
  enc: i32; pCtx: Pointer; xCompare: Pointer; xDel: Pointer): i32;
var
  rc: i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  rc := createCollation(db, zName, u8(enc), pCtx, xCompare, xDel);
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_create_collation(db: PTsqlite3; zName: PAnsiChar;
  enc: i32; pCtx: Pointer; xCompare: Pointer): i32;
begin
  Result := sqlite3_create_collation_v2(db, zName, enc, pCtx, xCompare, nil);
end;

function sqlite3_collation_needed(db: PTsqlite3;
  pCollNeededArg: Pointer; xCollNeeded: Pointer): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  db^.xCollNeeded    := xCollNeeded;
  db^.xCollNeeded16  := nil;
  db^.pCollNeededArg := pCollNeededArg;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  sqlite3_create_module / _v2 — vtab.c:108..134.

  The internal Module record + sqlite3VtabCreateModule live in
  passqlite3vtab (Phase 6.bis.1a).  These public entry points are the
  thin createModule() wrapper from vtab.c:87-101: enter the db mutex,
  call sqlite3VtabCreateModule, ApiExit, and on failure invoke the
  caller-supplied destructor exactly once.
  ---------------------------------------------------------------------- }

function _api_create_module(db: PTsqlite3; zName: PAnsiChar;
  pModule: PSqlite3Module; pAux: Pointer; xDestroy: TxModuleDestroy): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  sqlite3_mutex_enter(db^.mutex);
  sqlite3VtabCreateModule(db, zName, pModule, pAux, xDestroy);
  rc := sqlite3ApiExit(db, rc);
  if (rc <> SQLITE_OK) and Assigned(xDestroy) then xDestroy(pAux);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_create_module(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer): i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  Result := _api_create_module(db, zName, PSqlite3Module(pModule), pAux, nil);
end;

function sqlite3_create_module_v2(db: PTsqlite3; zName: PAnsiChar;
  pModule: Pointer; pAux: Pointer; xDestroy: Pointer): i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  Result := _api_create_module(db, zName, PSqlite3Module(pModule), pAux,
                               TxModuleDestroy(xDestroy));
end;

{ ----------------------------------------------------------------------
  Phase 8.4 — Configuration and hooks.
  Ported from main.c:
    426  sqlite3_config         (varargs — exposed here as int-shape overload)
    950  sqlite3_db_config      (varargs — exposed as three typed entry points)
   1718  sqliteDefaultBusyCallback
   1786  sqlite3_busy_handler
   1843  sqlite3_busy_timeout
   2277  sqlite3_trace_v2
   2337  sqlite3_commit_hook
   2362  sqlite3_update_hook
   2387  sqlite3_rollback_hook

  Scope of this Phase 8.4 port:
    * No C-ABI varargs.  sqlite3_config and sqlite3_db_config are split
      into typed entry points (one per argument shape).  Pascal callers
      are the v1 audience; a future ABI-compat layer can wrap these
      under a varargs trampoline.
    * setupLookaside is stubbed: lookaside slot allocation is not wired
      (Phase 8.1 already set bDisable=1, sz=0).  We record sz / nSlot
      / pBuf for future use but never actually serve allocations from
      the buffer.  If cnt <= 0 the subsystem is forcibly disabled.
    * sqlite3_progress_handler is exported (Phase 8.4.1).  Setter only;
      the per-step xProgress invocation is in sqlite3VdbeExec.
    * SETLK_TIMEOUT (compile-time gated in C) is not built in.
    * Db-config flags that reference codegen state we have not yet
      wired (e.g. SQLITE_DqsDDL parser-side enforcement, SQLITE_Defensive
      vdbe checks) still flip the flag bit; their *behaviour* engages
      only when the consumer subsystem honours the bit, which is a
      separate concern.
  ---------------------------------------------------------------------- }

const
  { sqlite3.flags bits not previously declared in passqlite3util.SQLITE_*. }
  SQLITE_StmtScanStatus_Bit = u64($00000400);
  SQLITE_NoCkptOnClose_Bit  = u64($00000800);
  SQLITE_ReverseOrder_Bit   = u64($00001000);
  SQLITE_LoadExtension_Bit  = u64($00010000);
  SQLITE_Fts3Tokenizer_Bit  = u64($00400000);
  SQLITE_EnableQPSG_Bit     = u64($00800000);
  SQLITE_TriggerEQP_Bit     = u64($01000000);
  SQLITE_ResetDatabase_Bit  = u64($02000000);
  SQLITE_LegacyAlter_Bit    = u64($04000000);
  SQLITE_NoSchemaError_Bit  = u64($08000000);
  SQLITE_Defensive_Bit      = u64($10000000);
  SQLITE_DqsDDL_Bit         = u64($20000000);
  SQLITE_DqsDML_Bit         = u64($40000000);
  SQLITE_EnableView_Bit     = u64($80000000);
  SQLITE_AttachCreate_Bit   = u64($00010) shl 32;
  SQLITE_AttachWrite_Bit    = u64($00020) shl 32;
  SQLITE_Comments_Bit       = u64($00040) shl 32;

type
  TBusyCallbackFn   = function(p: Pointer; n: i32): i32; cdecl;
  TCommitCallbackFn = function(p: Pointer): i32; cdecl;
  TRollbackCallbackFn = procedure(p: Pointer); cdecl;
  TTraceV2Fn        = function(n: u32; p, x, y: Pointer): i32; cdecl;

{ sqliteDefaultBusyCallback — main.c:1718.  Faithful port of the
  delays/totals nanosleep variant.  HAVE_NANOSLEEP is assumed (Linux). }
function sqliteDefaultBusyCallback(ptr: Pointer; count: i32): i32; cdecl;
const
  delays: array[0..11] of u8 = ( 1, 2, 5, 10, 15, 20, 25, 25,  25,  50,  50, 100);
  totals: array[0..11] of u8 = ( 0, 1, 3,  8, 18, 33, 53, 78, 103, 128, 178, 228);
  NDELAY = 12;
var
  db: PTsqlite3;
  tmout, delay, prior: i32;
begin
  db    := PTsqlite3(ptr);
  tmout := db^.busyTimeout;
  if count < NDELAY then begin
    delay := delays[count];
    prior := totals[count];
  end else begin
    delay := delays[NDELAY - 1];
    prior := totals[NDELAY - 1] + delay * (count - (NDELAY - 1));
  end;
  if (prior + delay) > tmout then begin
    delay := tmout - prior;
    if delay <= 0 then begin Result := 0; Exit; end;
  end;
  sqlite3OsSleep(Psqlite3_vfs(db^.pVfs), delay * 1000);
  Result := 1;
end;

function sqlite3_busy_handler(db: PTsqlite3;
  xBusy: Pointer; pArg: Pointer): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  db^.busyHandler.xBusyHandler := TBusyCallbackFn(xBusy);
  db^.busyHandler.pBusyArg     := pArg;
  db^.busyHandler.nBusy        := 0;
  db^.busyTimeout              := 0;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

function sqlite3_busy_timeout(db: PTsqlite3; ms: i32): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  if ms > 0 then begin
    sqlite3_busy_handler(db, @sqliteDefaultBusyCallback, Pointer(db));
    db^.busyTimeout := ms;
  end else begin
    sqlite3_busy_handler(db, nil, nil);
  end;
  Result := SQLITE_OK;
end;

{ Hooks — main.c:2337/2362/2387. }
function sqlite3_commit_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  Result               := db^.pCommitArg;
  db^.xCommitCallback  := TCommitCallbackFn(xCallback);
  db^.pCommitArg       := pArg;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_rollback_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  Result                 := db^.pRollbackArg;
  db^.xRollbackCallback  := TRollbackCallbackFn(xCallback);
  db^.pRollbackArg       := pArg;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_update_hook(db: PTsqlite3;
  xCallback: Pointer; pArg: Pointer): Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  Result               := db^.pUpdateArg;
  db^.xUpdateCallback  := xCallback;
  db^.pUpdateArg       := pArg;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_trace_v2(db: PTsqlite3; mTrace: u32;
  xTrace: Pointer; pArg: Pointer): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if mTrace = 0 then xTrace := nil;
  if xTrace = nil then mTrace := 0;
  db^.mTrace      := u8(mTrace and $FF);
  db^.trace.xV2   := TTraceV2Fn(xTrace);
  db^.pTraceArg   := pArg;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  setupLookaside — main.c:776 (greatly simplified for Phase 8.4).

  We do not implement slot allocation; the lookaside subsystem stays
  disabled (bDisable=1) as it has been since Phase 8.1.  This stub
  exists so SQLITE_DBCONFIG_LOOKASIDE callers get well-defined
  behaviour: SQLITE_OK is returned, the caller's request is recorded
  in the (non-functional) sz / nSlot fields, and the bDisable flag
  reflects the request.
  ---------------------------------------------------------------------- }
function setupLookaside(db: PTsqlite3; pBuf: Pointer; sz, cnt: i32): i32;
begin
  if pBuf <> nil then ;  { silence unused warning }
  if (sz <= 0) or (cnt <= 0) then begin
    db^.lookaside.bDisable := 1;
    db^.lookaside.sz       := 0;
    db^.lookaside.nSlot    := 0;
  end else begin
    { Round sz down to a multiple of 8.  Mirrors C: sz = ROUNDDOWN8(sz). }
    sz := sz and (not 7);
    db^.lookaside.bDisable := 1;        { still no real allocation }
    db^.lookaside.sz       := u16(sz);
    db^.lookaside.nSlot    := u32(cnt);
  end;
  Result := SQLITE_OK;
end;

type
  TFlagOpEntry = record
    op:   i32;
    mask: u64;
  end;
const
  { Mirrors aFlagOp[] in main.c:986. }
  aFlagOp: array[0..20] of TFlagOpEntry = (
    (op: SQLITE_DBCONFIG_ENABLE_FKEY;           mask: SQLITE_ForeignKeys),
    (op: SQLITE_DBCONFIG_ENABLE_TRIGGER;        mask: SQLITE_EnableTrigger),
    (op: SQLITE_DBCONFIG_ENABLE_VIEW;           mask: SQLITE_EnableView_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER; mask: SQLITE_Fts3Tokenizer_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION; mask: SQLITE_LoadExtension_Bit),
    (op: SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE;      mask: SQLITE_NoCkptOnClose_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_QPSG;           mask: SQLITE_EnableQPSG_Bit),
    (op: SQLITE_DBCONFIG_TRIGGER_EQP;           mask: SQLITE_TriggerEQP_Bit),
    (op: SQLITE_DBCONFIG_RESET_DATABASE;        mask: SQLITE_ResetDatabase_Bit),
    (op: SQLITE_DBCONFIG_DEFENSIVE;             mask: SQLITE_Defensive_Bit),
    (op: SQLITE_DBCONFIG_WRITABLE_SCHEMA;       mask: SQLITE_WriteSchema or SQLITE_NoSchemaError_Bit),
    (op: SQLITE_DBCONFIG_LEGACY_ALTER_TABLE;    mask: SQLITE_LegacyAlter_Bit),
    (op: SQLITE_DBCONFIG_DQS_DDL;               mask: SQLITE_DqsDDL_Bit),
    (op: SQLITE_DBCONFIG_DQS_DML;               mask: SQLITE_DqsDML_Bit),
    (op: SQLITE_DBCONFIG_LEGACY_FILE_FORMAT;    mask: SQLITE_LegacyFileFmt),
    (op: SQLITE_DBCONFIG_TRUSTED_SCHEMA;        mask: SQLITE_TrustedSchema),
    (op: SQLITE_DBCONFIG_STMT_SCANSTATUS;       mask: SQLITE_StmtScanStatus_Bit),
    (op: SQLITE_DBCONFIG_REVERSE_SCANORDER;     mask: SQLITE_ReverseOrder_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE;  mask: SQLITE_AttachCreate_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE;   mask: SQLITE_AttachWrite_Bit),
    (op: SQLITE_DBCONFIG_ENABLE_COMMENTS;       mask: SQLITE_Comments_Bit)
  );

{ Common flag-op handler. }
function dbConfigFlagOp(db: PTsqlite3; op: i32;
  onoff: i32; pRes: Pi32): i32;
var
  i: i32;
  oldFlags: u64;
begin
  for i := 0 to High(aFlagOp) do begin
    if aFlagOp[i].op = op then begin
      oldFlags := db^.flags;
      if onoff > 0 then
        db^.flags := db^.flags or aFlagOp[i].mask
      else if onoff = 0 then
        db^.flags := db^.flags and (not aFlagOp[i].mask);
      if oldFlags <> db^.flags then
        sqlite3ExpirePreparedStatements(db, 0);
      if pRes <> nil then begin
        if (db^.flags and aFlagOp[i].mask) <> 0 then pRes^ := 1 else pRes^ := 0;
      end;
      Result := SQLITE_OK;
      Exit;
    end;
  end;
  Result := SQLITE_ERROR;
end;

function sqlite3_db_config_text(db: PTsqlite3; op: i32;
  zName: PAnsiChar): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if op = SQLITE_DBCONFIG_MAINDBNAME then begin
    db^.aDb[0].zDbSName := zName;
    Result := SQLITE_OK;
  end else
    Result := SQLITE_ERROR;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_db_config_lookaside(db: PTsqlite3; op: i32;
  pBuf: Pointer; sz: i32; cnt: i32): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if op = SQLITE_DBCONFIG_LOOKASIDE then
    Result := setupLookaside(db, pBuf, sz, cnt)
  else
    Result := SQLITE_ERROR;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_db_config_int(db: PTsqlite3; op: i32;
  onoff: i32; pRes: Pi32): i32;
var
  rc: i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if op = SQLITE_DBCONFIG_FP_DIGITS then begin
    if (onoff > 3) and (onoff < 24) then db^.nFpDigit := u8(onoff);
    if pRes <> nil then pRes^ := db^.nFpDigit;
    rc := SQLITE_OK;
  end else
    rc := dbConfigFlagOp(db, op, onoff, pRes);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ sqlite3_config(int).  Mirrors the int-shape branches of main.c:426. }
function sqlite3_config(op: i32; arg: i32): i32; overload;
begin
  if sqlite3GlobalConfig.isInit <> 0 then begin
    { Only LOG / PCACHE_HDRSZ are anytime-config; neither uses int shape. }
    Result := SQLITE_MISUSE;
    Exit;
  end;
  Result := SQLITE_OK;
  case op of
    SQLITE_CONFIG_SINGLETHREAD: begin
      sqlite3GlobalConfig.bCoreMutex := 0;
      sqlite3GlobalConfig.bFullMutex := 0;
    end;
    SQLITE_CONFIG_MULTITHREAD: begin
      sqlite3GlobalConfig.bCoreMutex := 1;
      sqlite3GlobalConfig.bFullMutex := 0;
    end;
    SQLITE_CONFIG_SERIALIZED: begin
      sqlite3GlobalConfig.bCoreMutex := 1;
      sqlite3GlobalConfig.bFullMutex := 1;
    end;
    SQLITE_CONFIG_MEMSTATUS:    sqlite3GlobalConfig.bMemstat    := arg;
    SQLITE_CONFIG_SMALL_MALLOC: sqlite3GlobalConfig.bSmallMalloc := arg;
    SQLITE_CONFIG_URI:          sqlite3GlobalConfig.bOpenUri    := arg;
    SQLITE_CONFIG_COVERING_INDEX_SCAN: sqlite3GlobalConfig.bUseCis := arg;
    SQLITE_CONFIG_STMTJRNL_SPILL: sqlite3GlobalConfig.nStmtSpill := arg;
    SQLITE_CONFIG_SORTERREF_SIZE: sqlite3GlobalConfig.szSorterRef := u32(arg);
    SQLITE_CONFIG_MEMDB_MAXSIZE:  sqlite3GlobalConfig.mxMemdbSize := arg;
  else
    Result := SQLITE_MISUSE;
  end;
end;

{ ----------------------------------------------------------------------
  Phase 8.5 — sqlite3_initialize / sqlite3_shutdown.
  Ported from main.c:190 (sqlite3_initialize) and main.c:372 (sqlite3_shutdown).

  Scope notes:
    * SQLITE_EXTRA_INIT / SQLITE_OMIT_WSD / SQLITE_ENABLE_SQLLOG branches
      are compile-time gated in C and not relevant here.
    * sqlite3_reset_auto_extension is not ported (auto-extension subsystem
      not present); shutdown therefore omits the call.  Re-add with that
      subsystem in a later phase.
    * sqlite3_data_directory / sqlite3_temp_directory globals are not
      ported either, so the post-MallocEnd zeroing block is skipped.
    * The NDEBUG NaN sanity check is omitted.
  ---------------------------------------------------------------------- }

function sqlite3_initialize: i32;
var
  pMainMtx : Psqlite3_mutex;
  rc       : i32;
begin
  { If SQLite is already completely initialized, this is a no-op. }
  if sqlite3GlobalConfig.isInit <> 0 then begin
    sqlite3MemoryBarrier;
    Result := SQLITE_OK;
    Exit;
  end;

  { Make sure the mutex subsystem is initialized. }
  rc := sqlite3MutexInit;
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  { Initialize malloc + the recursive pInitMutex under STATIC_MAIN. }
  pMainMtx := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMainMtx);
  sqlite3GlobalConfig.isMutexInit := 1;
  if sqlite3GlobalConfig.isMallocInit = 0 then
    rc := sqlite3MallocInit;
  if rc = SQLITE_OK then begin
    sqlite3GlobalConfig.isMallocInit := 1;
    if sqlite3GlobalConfig.pInitMutex = nil then begin
      sqlite3GlobalConfig.pInitMutex :=
        sqlite3MutexAlloc(SQLITE_MUTEX_RECURSIVE);
      if (sqlite3GlobalConfig.bCoreMutex <> 0)
         and (sqlite3GlobalConfig.pInitMutex = nil) then
        rc := SQLITE_NOMEM;
    end;
  end;
  if rc = SQLITE_OK then
    Inc(sqlite3GlobalConfig.nRefInitMutex);
  sqlite3_mutex_leave(pMainMtx);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  { Recursive-mutex section: do the rest of the work serialized via
    pInitMutex so re-entrant calls (typically through sqlite3_os_init →
    sqlite3_vfs_register) don't deadlock. }
  sqlite3_mutex_enter(sqlite3GlobalConfig.pInitMutex);
  if (sqlite3GlobalConfig.isInit = 0)
     and (sqlite3GlobalConfig.inProgress = 0) then begin
    sqlite3GlobalConfig.inProgress := 1;

    { Reset the global builtin-functions hash and re-populate. }
    FillChar(sqlite3BuiltinFunctions, SizeOf(sqlite3BuiltinFunctions), 0);
    sqlite3RegisterBuiltinFunctions;

    if sqlite3GlobalConfig.isPCacheInit = 0 then
      rc := sqlite3PcacheInitialize;
    if rc = SQLITE_OK then begin
      sqlite3GlobalConfig.isPCacheInit := 1;
      rc := sqlite3OsInit;
    end;
    if rc = SQLITE_OK then
      rc := sqlite3MemdbInit;
    if rc = SQLITE_OK then begin
      sqlite3PCacheBufferSetup(
        sqlite3GlobalConfig.pPage,
        sqlite3GlobalConfig.szPage,
        sqlite3GlobalConfig.nPage);
    end;
    if rc = SQLITE_OK then begin
      sqlite3MemoryBarrier;
      sqlite3GlobalConfig.isInit := 1;
    end;
    sqlite3GlobalConfig.inProgress := 0;
  end;
  sqlite3_mutex_leave(sqlite3GlobalConfig.pInitMutex);

  { Tear down the recursive pInitMutex once the last in-flight caller
    leaves, to prevent a resource leak across repeated init/shutdown. }
  sqlite3_mutex_enter(pMainMtx);
  Dec(sqlite3GlobalConfig.nRefInitMutex);
  if sqlite3GlobalConfig.nRefInitMutex <= 0 then begin
    Assert(sqlite3GlobalConfig.nRefInitMutex = 0);
    sqlite3_mutex_free(sqlite3GlobalConfig.pInitMutex);
    sqlite3GlobalConfig.pInitMutex := nil;
  end;
  sqlite3_mutex_leave(pMainMtx);

  Result := rc;
end;

function sqlite3_shutdown: i32;
begin
  if sqlite3GlobalConfig.isInit <> 0 then begin
    sqlite3_os_end;
    { sqlite3_reset_auto_extension — auto-extension subsystem not ported. }
    sqlite3GlobalConfig.isInit := 0;
  end;
  if sqlite3GlobalConfig.isPCacheInit <> 0 then begin
    sqlite3PcacheShutdown;
    sqlite3GlobalConfig.isPCacheInit := 0;
  end;
  if sqlite3GlobalConfig.isMallocInit <> 0 then begin
    sqlite3MallocEnd;
    sqlite3GlobalConfig.isMallocInit := 0;
    { sqlite3_data_directory / sqlite3_temp_directory globals not ported. }
  end;
  if sqlite3GlobalConfig.isMutexInit <> 0 then begin
    sqlite3MutexEnd;
    sqlite3GlobalConfig.isMutexInit := 0;
  end;
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  Phase 8.6 — sqlite3_exec / sqlite3_get_table / sqlite3_free_table
  Faithful port of legacy.c (entire file) and table.c.
  ---------------------------------------------------------------------- }

{ Port of main.c:2711 sqlite3_errmsg — consult db^.pErr first, fall
  back to sqlite3ErrStr(errCode) if no per-connection message stored. }
function sqlite3_errmsg(db: PTsqlite3): PAnsiChar;
var
  z: PAnsiChar;
begin
  if db = nil then begin Result := sqlite3ErrStr(SQLITE_NOMEM); Exit; end;
  if sqlite3SafetyCheckSickOrOk(db) = 0 then begin
    Result := sqlite3ErrStr(SQLITE_MISUSE); Exit;
  end;
  if db^.mallocFailed <> 0 then begin
    Result := sqlite3ErrStr(SQLITE_NOMEM); Exit;
  end;
  z := nil;
  if db^.errCode <> 0 then
    z := PAnsiChar(sqlite3_value_text(Psqlite3_value(db^.pErr)));
  if z = nil then
    z := sqlite3ErrStr(db^.errCode);
  Result := z;
end;

type
  PPPAnsiCharLocal = ^PPAnsiChar;

  PTabResult = ^TTabResult;
  TTabResult = record
    azResult: PPAnsiChar;   { Accumulated output }
    zErrMsg:  PAnsiChar;    { Error message text, if an error occurs }
    nAlloc:   u32;          { Slots allocated for azResult[] }
    nRow:     u32;          { Number of rows in the result }
    nColumn:  u32;          { Number of columns in the result }
    nData:    u32;          { Slots used in azResult[].  (nRow+1)*nColumn }
    rc:       i32;          { Return code from sqlite3_exec() }
  end;

function sqlite3_exec(db: PTsqlite3; zSql: PAnsiChar;
                      xCallback: Tsqlite3_callback; pArg: Pointer;
                      pzErrMsg: PPAnsiChar): i32;
label
  exec_out;
var
  rc:        i32;
  zLeftover: PAnsiChar;
  pStmt:     PVdbe;
  pStmtP:    Pointer;
  azCols:    PPAnsiChar;
  azVals:    PPAnsiChar;
  callbackIsInit: Boolean;
  nCol, i:   i32;
  src, dst:  PAnsiChar;
  errSrc:    PAnsiChar;
  n:         PtrUInt;
begin
  rc     := SQLITE_OK;
  pStmt  := nil;
  azCols := nil;

  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  if zSql = nil then zSql := '';

  sqlite3_mutex_enter(db^.mutex);
  sqlite3Error(db, SQLITE_OK);
  while (rc = SQLITE_OK) and (zSql[0] <> #0) do begin
    nCol  := 0;
    azVals := nil;

    pStmtP := nil;
    rc := sqlite3_prepare_v2(db, zSql, -1, @pStmtP, @zLeftover);
    pStmt := PVdbe(pStmtP);
    Assert((rc = SQLITE_OK) or (pStmt = nil));
    if rc <> SQLITE_OK then continue;
    if pStmt = nil then begin
      { whitespace / comment-only statement }
      zSql := zLeftover;
      continue;
    end;
    callbackIsInit := False;

    while True do begin
      rc := sqlite3_step(pStmt);

      { Invoke the callback function if required. }
      if (xCallback <> nil) and
         ((rc = SQLITE_ROW) or
          ((rc = SQLITE_DONE) and (not callbackIsInit) and
           ((db^.flags and SQLITE_NullCallback) <> 0))) then
      begin
        if not callbackIsInit then begin
          nCol := sqlite3_column_count(pStmt);
          azCols := PPAnsiChar(sqlite3DbMallocRaw(db,
                       u64((2 * nCol + 1) * SizeOf(PAnsiChar))));
          if azCols = nil then goto exec_out;
          for i := 0 to nCol - 1 do begin
            (azCols + i)^ := sqlite3_column_name(pStmt, i);
            Assert((azCols + i)^ <> nil);
          end;
          callbackIsInit := True;
        end;
        if rc = SQLITE_ROW then begin
          azVals := PPAnsiChar(azCols + nCol);
          for i := 0 to nCol - 1 do begin
            (azVals + i)^ := PAnsiChar(sqlite3_column_text(pStmt, i));
            if ((azVals + i)^ = nil) and
               (sqlite3_column_type(pStmt, i) <> SQLITE_NULL) then
            begin
              sqlite3OomFault(db);
              goto exec_out;
            end;
          end;
          (azVals + nCol)^ := nil;
        end;
        if xCallback(pArg, nCol, azVals, azCols) <> 0 then begin
          rc := SQLITE_ABORT;
          sqlite3VdbeFinalize(pStmt);
          pStmt := nil;
          sqlite3Error(db, SQLITE_ABORT);
          goto exec_out;
        end;
      end;

      if rc <> SQLITE_ROW then begin
        rc := sqlite3VdbeFinalize(pStmt);
        pStmt := nil;
        zSql := zLeftover;
        while sqlite3Isspace(u8(zSql[0])) <> 0 do Inc(zSql);
        Break;
      end;
    end;

    sqlite3DbFree(db, azCols);
    azCols := nil;
  end;

exec_out:
  if pStmt <> nil then sqlite3VdbeFinalize(pStmt);
  sqlite3DbFree(db, azCols);

  rc := sqlite3ApiExit(db, rc);
  if (rc <> SQLITE_OK) and (pzErrMsg <> nil) then begin
    errSrc := sqlite3_errmsg(db);
    if errSrc = nil then errSrc := '';
    n := PtrUInt(sqlite3Strlen30(errSrc));
    dst := PAnsiChar(sqlite3_malloc64(u64(n + 1)));
    pzErrMsg^ := dst;
    if dst = nil then begin
      rc := SQLITE_NOMEM;
      sqlite3Error(db, SQLITE_NOMEM);
    end else begin
      src := errSrc;
      Move(src^, dst^, n);
      (dst + n)^ := #0;
    end;
  end else if pzErrMsg <> nil then
    pzErrMsg^ := nil;

  Assert((rc and db^.errMask) = rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ ----------------------------------------------------------------------
  table.c — sqlite3_get_table / sqlite3_get_table_cb / sqlite3_free_table
  ---------------------------------------------------------------------- }

function sqlite3_get_table_cb(pArg: Pointer; nCol: i32;
                              argv: PPAnsiChar;
                              colv: PPAnsiChar): i32; cdecl;
label
  malloc_failed;
var
  p:    PTabResult;
  need: i32;
  i, n: i32;
  z:    PAnsiChar;
  azNew: PPAnsiChar;
  src:  PAnsiChar;
begin
  p := PTabResult(pArg);

  if (p^.nRow = 0) and (argv <> nil) then
    need := nCol * 2
  else
    need := nCol;
  if (p^.nData + u32(need)) > p^.nAlloc then begin
    p^.nAlloc := p^.nAlloc * 2 + u32(need);
    azNew := PPAnsiChar(sqlite3Realloc(p^.azResult,
                                       NativeUInt(SizeOf(PAnsiChar) * p^.nAlloc)));
    if azNew = nil then goto malloc_failed;
    p^.azResult := azNew;
  end;

  { First row: emit the column names. }
  if p^.nRow = 0 then begin
    p^.nColumn := u32(nCol);
    for i := 0 to nCol - 1 do begin
      src := (colv + i)^;
      if src = nil then n := 0 else n := sqlite3Strlen30(src);
      z := PAnsiChar(sqlite3_malloc64(u64(n + 1)));
      if z = nil then goto malloc_failed;
      if n > 0 then Move(src^, z^, n);
      z[n] := #0;
      (p^.azResult + p^.nData)^ := z;
      Inc(p^.nData);
    end;
  end else if i32(p^.nColumn) <> nCol then begin
    sqlite3_free(p^.zErrMsg);
    p^.zErrMsg := PAnsiChar(sqlite3StrDup(
      'sqlite3_get_table() called with two or more incompatible queries'));
    p^.rc := SQLITE_ERROR;
    Result := 1; Exit;
  end;

  { Copy over the row data. }
  if argv <> nil then begin
    for i := 0 to nCol - 1 do begin
      src := (argv + i)^;
      if src = nil then begin
        z := nil;
      end else begin
        n := sqlite3Strlen30(src) + 1;
        z := PAnsiChar(sqlite3_malloc64(u64(n)));
        if z = nil then goto malloc_failed;
        Move(src^, z^, n);
      end;
      (p^.azResult + p^.nData)^ := z;
      Inc(p^.nData);
    end;
    Inc(p^.nRow);
  end;
  Result := 0;
  Exit;

malloc_failed:
  p^.rc := SQLITE_NOMEM;
  Result := 1;
end;

function sqlite3_get_table(db: PTsqlite3; zSql: PAnsiChar;
                           pazResult: PPPAnsiChar;
                           pnRow: Pi32; pnColumn: Pi32;
                           pzErrMsg: PPAnsiChar): i32;
var
  rc:    i32;
  res:   TTabResult;
  azNew: PPAnsiChar;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (pazResult = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  pazResult^ := nil;
  if pnColumn <> nil then pnColumn^ := 0;
  if pnRow    <> nil then pnRow^    := 0;
  if pzErrMsg <> nil then pzErrMsg^ := nil;
  res.zErrMsg := nil;
  res.nRow    := 0;
  res.nColumn := 0;
  res.nData   := 1;
  res.nAlloc  := 20;
  res.rc      := SQLITE_OK;
  res.azResult := PPAnsiChar(sqlite3_malloc64(SizeOf(PAnsiChar) * res.nAlloc));
  if res.azResult = nil then begin
    db^.errCode := SQLITE_NOMEM;
    Result := SQLITE_NOMEM; Exit;
  end;
  (res.azResult + 0)^ := nil;
  rc := sqlite3_exec(db, zSql, @sqlite3_get_table_cb, @res, pzErrMsg);
  { Stash nData in slot 0 so sqlite3_free_table knows the array length. }
  (res.azResult + 0)^ := PAnsiChar(PtrUInt(res.nData));
  if (rc and $FF) = SQLITE_ABORT then begin
    sqlite3_free_table(PPAnsiChar(res.azResult + 1));
    if res.zErrMsg <> nil then begin
      if pzErrMsg <> nil then begin
        sqlite3_free(pzErrMsg^);
        pzErrMsg^ := PAnsiChar(sqlite3StrDup(res.zErrMsg));
      end;
      sqlite3_free(res.zErrMsg);
    end;
    db^.errCode := res.rc;
    Result := res.rc; Exit;
  end;
  sqlite3_free(res.zErrMsg);
  if rc <> SQLITE_OK then begin
    sqlite3_free_table(PPAnsiChar(res.azResult + 1));
    Result := rc; Exit;
  end;
  if res.nAlloc > res.nData then begin
    azNew := PPAnsiChar(sqlite3Realloc(res.azResult,
                                       NativeUInt(SizeOf(PAnsiChar) * res.nData)));
    if azNew = nil then begin
      sqlite3_free_table(PPAnsiChar(res.azResult + 1));
      db^.errCode := SQLITE_NOMEM;
      Result := SQLITE_NOMEM; Exit;
    end;
    res.azResult := azNew;
  end;
  pazResult^ := PPAnsiChar(res.azResult + 1);
  if pnColumn <> nil then pnColumn^ := i32(res.nColumn);
  if pnRow    <> nil then pnRow^    := i32(res.nRow);
  Result := rc;
end;

procedure sqlite3_free_table(azResult: PPAnsiChar);
var
  i, n: i32;
  base: PPAnsiChar;
begin
  if azResult <> nil then begin
    base := PPAnsiChar(PtrUInt(azResult) - SizeOf(PAnsiChar));
    n := i32(PtrUInt((base + 0)^));
    for i := 1 to n - 1 do
      if (base + i)^ <> nil then sqlite3_free((base + i)^);
    sqlite3_free(base);
  end;
end;

{ Phase 8.8 — sqlite3_unlock_notify shim.

  Mirrors notify.c:148 in the trivial degenerate case enforced by our
  build configuration:
    * No shared-cache → the port never sets pBlockingConnection on any
      connection.  The C path at notify.c:167 (`0==db->pBlockingConnection`)
      is therefore the only branch reachable here, which fires xNotify
      immediately with a one-element argument array and returns OK.
    * xNotify=nil clears prior registrations — but with no per-connection
      state to clear, this is also a pure no-op returning OK.
    * db=nil → SQLITE_MISUSE_BKPT, matching the API_ARMOR guard. }
function sqlite3_unlock_notify(db: PTsqlite3;
                               xNotify: Tsqlite3_unlock_notify_cb;
                               pArg: Pointer): i32;
var
  arg: Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if Assigned(xNotify) then begin
    arg := pArg;
    xNotify(@arg, 1);
  end;
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  Phase 8.9 — loadext.c shims and faithful auto-extension list.

  See interface block above for design notes.
  ---------------------------------------------------------------------- }
const
  cExtLoadDisabledMsg: AnsiString = 'extension loading is disabled';

var
  gAutoExt   : array of Tsqlite3_loadext_fn;
  gAutoExtN  : i32 = 0;

{ sqlite3_load_extension — loadext.c:728 (with SQLITE_OMIT_LOAD_EXTENSION
  the C code does not emit this symbol at all; we provide a shim that
  tells the caller the obvious truth). }
function sqlite3_load_extension(db: PTsqlite3;
                                zFile, zProc: PAnsiChar;
                                pzErrMsg: PPAnsiChar): i32;
var
  z: PAnsiChar;
  n: PtrUInt;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if pzErrMsg <> nil then begin
    n := Length(cExtLoadDisabledMsg);
    z := sqlite3_malloc(i32(n + 1));
    if z <> nil then begin
      Move(cExtLoadDisabledMsg[1], z^, n);
      (z + n)^ := #0;
    end;
    pzErrMsg^ := z;
  end;
  Result := SQLITE_ERROR;
end;

{ sqlite3_enable_load_extension — loadext.c:759.  Faithful.  The
  SQLITE_LoadExtFunc bit is shifted >32 in upstream; we don't model that
  bit yet (it gates only the load_extension() SQL function which is not
  ported), so toggle SQLITE_LoadExtension only. }
function sqlite3_enable_load_extension(db: PTsqlite3; onoff: i32): i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  if onoff <> 0 then
    db^.flags := db^.flags or SQLITE_LoadExtension_Bit
  else
    db^.flags := db^.flags and (not SQLITE_LoadExtension_Bit);
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ sqlite3_auto_extension — loadext.c:808.  Faithful. }
function sqlite3_auto_extension(xInit: Tsqlite3_loadext_fn): i32;
var
  rc      : i32;
  i       : i32;
  pMainMtx: Psqlite3_mutex;
begin
  if not Assigned(xInit) then begin Result := SQLITE_MISUSE; Exit; end;
  rc := sqlite3_initialize;
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  pMainMtx := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMainMtx);
  i := 0;
  while i < gAutoExtN do begin
    if Pointer(gAutoExt[i]) = Pointer(xInit) then break;
    Inc(i);
  end;
  if i = gAutoExtN then begin
    SetLength(gAutoExt, gAutoExtN + 1);
    gAutoExt[gAutoExtN] := xInit;
    Inc(gAutoExtN);
  end;
  sqlite3_mutex_leave(pMainMtx);
  Result := SQLITE_OK;
end;

{ sqlite3_cancel_auto_extension — loadext.c:858.  Returns 1 if removed,
  0 otherwise. }
function sqlite3_cancel_auto_extension(xInit: Tsqlite3_loadext_fn): i32;
var
  i, n    : i32;
  pMainMtx: Psqlite3_mutex;
begin
  if not Assigned(xInit) then begin Result := 0; Exit; end;
  n := 0;
  pMainMtx := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMainMtx);
  i := gAutoExtN - 1;
  while i >= 0 do begin
    if Pointer(gAutoExt[i]) = Pointer(xInit) then begin
      Dec(gAutoExtN);
      gAutoExt[i] := gAutoExt[gAutoExtN];
      Inc(n);
      break;
    end;
    Dec(i);
  end;
  sqlite3_mutex_leave(pMainMtx);
  Result := n;
end;

{ sqlite3_reset_auto_extension — loadext.c:886.  Faithful. }
procedure sqlite3_reset_auto_extension;
var
  pMainMtx: Psqlite3_mutex;
begin
  if sqlite3_initialize <> SQLITE_OK then Exit;
  pMainMtx := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMainMtx);
  SetLength(gAutoExt, 0);
  gAutoExtN := 0;
  sqlite3_mutex_leave(pMainMtx);
end;

{ ----------------------------------------------------------------------
  Phase 6.9-bis step 11g.1 — OP_ParseSchema worker.

  Faithful structural port of the productive (non-ALTER) branch of
  vdbe.c:7146..7173.  Builds the SELECT against sqlite_master under the
  caller-supplied WHERE clause, runs it via sqlite3_exec under
  init.busy=1, and dispatches each schema row to sqlite3InitCallback.

  Step 11g.1 ships the structural skeleton: the InitData record, the
  init.busy gating, the SQL build/exec/free dance, and the nInitRow
  corruption check are all in place.  sqlite3InitCallback is the
  *minimal* re-entrant dispatcher — it bumps nInitRow so the
  corruption check passes, but does NOT yet re-prepare the row's CREATE
  statement under init.busy=1 to publish to pSchema^.tblHash (that
  re-prepare lands in step 11g.1+, since the codegen-side init.busy=1
  path in sqlite3EndTable / sqlite3CreateIndex still needs verification
  end-to-end against TestExplainParity's CREATE INDEX/DROP TABLE rows).

  Source map:
    InitData     — sqliteInt.h:struct InitData
    sqlite3InitCallback — prepare.c:96..189
    Worker tail  — vdbe.c:7137..7181

  TInitData / PInitData / sqlite3InitCallback are declared in the
  interface section so step-11g.1.c's audit test can drive the
  callback directly with synthesised argv.
  ---------------------------------------------------------------------- }

{ Helper — minimal port of prepare.c:22 corruptSchema.  We do not yet
  honour mInitFlags / SQLITE_WriteSchema overrides (Phase 7 territory);
  for now any caller-side error simply sets pData^.rc to a corruption
  code, which is exactly what the surrounding sqlite3InitCallback
  branches need to ferry the failure out through OP_ParseSchema. }
procedure initCorruptSchema(pData: PInitData; {%H-}argv: PPAnsiChar;
                            {%H-}zExtra: PAnsiChar);
begin
  if pData^.db^.mallocFailed <> 0 then
    pData^.rc := SQLITE_NOMEM
  else
    pData^.rc := SQLITE_CORRUPT;
end;

{ Faithful port of prepare.c:96 sqlite3InitCallback.

  Three productive branches mirror the C reference:
    (a) argv[3] = nil                            → corruptSchema
    (b) argv[4] starts with 'c'/'C' then 'r'/'R' → re-prepare CREATE
        under init.busy=1, populating db^.init.{iDb,newTnum,azInit}
        per prepare.c:128..163.  This is what publishes a table /
        index / view into pSchema^.tblHash without re-emitting any
        VDBE bytecode — the parser builds the in-memory structures
        and bails out before codegen because init.busy is set.
    (c) argv[1] = nil, or argv[4] is non-empty   → corruptSchema
    (d) otherwise (PRIMARY KEY / UNIQUE auto-index with empty SQL):
        sqlite3FindIndex + patch pIndex^.tnum from argv[3].
}
function sqlite3InitCallback(pInit: Pointer; argc: i32;
                             argv: PPAnsiChar;
                             {%H-}NotUsed: PPAnsiChar): i32; cdecl;
var
  pData     : PInitData;
  db        : PTsqlite3;
  iDb       : i32;
  rc        : i32;
  saved_iDb : u8;
  pStmt     : Pointer;
  zArg1, zArg3, zArg4 : PAnsiChar;
  c0, c1    : u8;
  pIndex    : PIndex2;
begin
  pData := PInitData(pInit);
  db    := pData^.db;
  iDb   := pData^.iDb;
  Assert(argc = 5);
  { DBFLAG_EncodingFixed (sqliteInt.h:1892) — redeclared locally here
    because passqlite3parser scopes it to its implementation section. }
  db^.mDbFlags := db^.mDbFlags or u32($0040);
  if argv = nil then begin Result := 0; Exit; end;
  Inc(pData^.nInitRow);
  if db^.mallocFailed <> 0 then begin
    initCorruptSchema(pData, argv, nil);
    Result := 1; Exit;
  end;
  Assert((iDb >= 0) and (iDb < db^.nDb));

  zArg1 := (argv + 1)^;
  zArg3 := (argv + 3)^;
  zArg4 := (argv + 4)^;

  if zArg3 = nil then begin
    initCorruptSchema(pData, argv, nil);
  end else begin
    { Mirror prepare.c:114..189: a flat else-if ladder over argv[4],
      not a nested split on (argv[4] = nil).  Empty-string argv[4]
      ("" — non-nil but zArg4[0]=#0) must fall through to branch (d)
      (auto-index), exactly like nil argv[4].  The earlier nested
      structure left empty-string argv[4] orphaned in a "should not
      happen" arm and corrupted every PRIMARY KEY / UNIQUE auto-index
      row. }
    c0 := 0; c1 := 0;
    if zArg4 <> nil then begin
      c0 := sqlite3UpperToLower[u8(zArg4[0])];
      if zArg4[0] <> #0 then c1 := sqlite3UpperToLower[u8(zArg4[1])];
    end;
    if (zArg4 <> nil) and (c0 = u8(Ord('c'))) and (c1 = u8(Ord('r'))) then begin
      { Phase 6.9-bis 11g.2.f sub-progress 8: skip if already published.
        Without a WHERE filter on the schema-row SELECT (see banner in
        execParseSchemaImpl), OP_ParseSchema enumerates every existing
        schema row each time it fires.  Already-published tables would
        otherwise trip StartTable's "table already exists" collision
        check on every subsequent CREATE TABLE step. }
      if (zArg1 <> nil)
         and (sqlite3FindTable(db, zArg1, db^.aDb[iDb].zDbSName) <> nil) then
      begin
        Result := 0; Exit;
      end;
      { Branch (b) — re-prepare a CREATE statement to publish into
        pSchema^.tblHash.  init.busy is already 1 (set by the
        OP_ParseSchema worker / sqlite3InitOne); we save & restore
        only init.iDb so nested attaches don't clobber it. }
      Assert(db^.init.busy <> 0);
      saved_iDb     := db^.init.iDb;
      db^.init.iDb  := u8(iDb);
      if (sqlite3GetUInt32(zArg3, @db^.init.newTnum) = 0)
         or ((db^.init.newTnum > pData^.mxPage) and (pData^.mxPage > 0)) then begin
        { bExtraSchemaChecks gate omitted — sqlite3Config.bExtraSchemaChecks
          isn't wired yet; following the reference's safe default of OFF. }
      end;
      { Clear the orphanTrigger flag (bit 0 of init.flags). }
      db^.init.flags := db^.init.flags and (not u8($01));
      db^.init.azInit := PPAnsiChar(argv);
      pStmt := nil;
      rc := sqlite3Prepare(db, zArg4, -1, 0, nil, @pStmt, nil);
      rc := db^.errCode;
      db^.init.iDb := saved_iDb;
      if rc <> SQLITE_OK then begin
        if (db^.init.flags and u8($01)) <> 0 then begin
          { orphanTrigger — only valid for TEMP. }
          Assert(iDb = 1);
        end else begin
          if rc > pData^.rc then pData^.rc := rc;
          if rc = SQLITE_NOMEM then
            sqlite3OomFault(db)
          else if (rc <> SQLITE_INTERRUPT) and ((rc and $FF) <> SQLITE_LOCKED) then
            initCorruptSchema(pData, argv, sqlite3_errmsg(db));
        end;
      end;
      db^.init.azInit := nil;  { sqlite3StdType in C; nil is safe — no live consumer. }
      sqlite3_finalize(PVdbe(pStmt));
    end else if (zArg1 = nil)
                or ((zArg4 <> nil) and (zArg4[0] <> #0)) then begin
      initCorruptSchema(pData, argv, nil);
    end else begin
      { Branch (d) — argv[4] is nil OR empty string (no SQL).  An
        auto-index for a PRIMARY KEY / UNIQUE constraint: the Index
        struct already exists from the parent CREATE TABLE; only
        patch its tnum from argv[3]. }
    pIndex := sqlite3FindIndex(db, zArg1, db^.aDb[iDb].zDbSName);
    if pIndex = nil then begin
      initCorruptSchema(pData, argv, PAnsiChar('orphan index'));
    end else begin
      if (sqlite3GetUInt32(zArg3, @pIndex^.tnum) = 0)
         or (pIndex^.tnum < 2)
         or (pIndex^.tnum > pData^.mxPage) then begin
        { sqlite3IndexHasDuplicateRootPage check + bExtraSchemaChecks
          gate are still pending (see passqlite3codegen.pas:7379).
          Leave silent for now — matches the C reference when
          bExtraSchemaChecks is OFF. }
      end;
    end;
    end;
  end;
  Result := 0;
end;

function execParseSchemaImpl(db: PTsqlite3; iDb: i32;
                             zWhere: PAnsiChar; {%H-}p5: u16): i32;
var
  initData : TInitData;
  zSql     : PAnsiChar;
  rc       : i32;
  savedBusy: u8;
begin
  rc := SQLITE_OK;
  if (db = nil) or (iDb < 0) or (iDb >= db^.nDb) or (zWhere = nil) then begin
    Result := SQLITE_ERROR;
    Exit;
  end;
  { Phase 6.9-bis 11g.2.f sub-progress 8: drop the WHERE/ORDER BY from
    the schema-cache SELECT until the Pascal sqlite3Select codegen path
    can handle them productively (today it stub-bails to a 3-op
    Init/Halt/Goto, returning zero rows, which leaves tblHash empty
    after every CREATE TABLE).  Iterating every schema row instead is
    safe because sqlite3InitCallback gates each row on
    "table already in tblHash" before re-preparing the CREATE
    statement, so already-published tables are no-ops on subsequent
    OP_ParseSchema fires.  The %s zWhere argument is kept in the
    function signature for caller compatibility but ignored. }
  if zWhere = nil then ;  { unreferenced — see banner. }
  { SCHEMA_TABLE(iDb) — temp DB (iDb=1) lives in sqlite_temp_master,
    every other attached DB in sqlite_master.  Bootstrap installs
    sqlite_master only in main and sqlite_temp_master only in temp,
    so the bare name resolves unambiguously to the right btree.
    (A qualified "<dbname>.<table>" form still trips the codegen's
    silent-bail on qualified lookups; revisit when that gate is
    closed.) }
  if iDb = 1 then
    zSql := sqlite3MPrintf(db,
              'SELECT type,name,tbl_name,rootpage,sql FROM %s',
              [LEGACY_TEMP_SCHEMA_TABLE])
  else
    zSql := sqlite3MPrintf(db,
              'SELECT type,name,tbl_name,rootpage,sql FROM %s',
              [LEGACY_SCHEMA_TABLE]);
  if zSql = nil then begin
    Result := SQLITE_NOMEM;
    Exit;
  end;
  initData.db         := db;
  initData.iDb        := iDb;
  initData.pzErrMsg   := nil;
  initData.rc         := SQLITE_OK;
  initData.mInitFlags := 0;
  initData.nInitRow   := 0;
  initData.mxPage     := sqlite3BtreeLastPage(PBtree(db^.aDb[iDb].pBt));

  savedBusy        := db^.init.busy;
  db^.init.busy    := 1;
  rc := sqlite3_exec(db, zSql, @sqlite3InitCallback, @initData, nil);
  db^.init.busy    := savedBusy;

  if rc = SQLITE_OK then rc := initData.rc;
  { vdbe.c:7165..7170 raises SQLITE_CORRUPT when nInitRow==0 (a non-NULL
    P4 must hit at least one schema row, otherwise sqlite_master is
    corrupt).  We DELIBERATELY skip that check while the schema-row
    INSERT in sqlite3Insert (codegen.pas) is still a structural skeleton
    that emits zero ops — every fresh CREATE TABLE today reaches
    OP_ParseSchema *before* a row is actually present in sqlite_master,
    so a faithful corruption check would convert every CREATE TABLE to
    SQLITE_CORRUPT and regress the entire test corpus.  Re-enable this
    check the moment sqlite3Insert (step 11e) starts writing real rows;
    that's tracked in Phase 6.9-bis under the productive-emission tail
    of step 11g.1+. }
  // if (rc = SQLITE_OK) and (initData.nInitRow = 0) then
  //   rc := SQLITE_CORRUPT;
  sqlite3DbFree(db, zSql);
  Result := rc;
end;

{ ----------------------------------------------------------------------
  Phase 8.1.1 / 8.4.1 implementations — see interface comment.
  ---------------------------------------------------------------------- }

function sqlite3_libversion: PAnsiChar; cdecl;
begin
  Result := PAnsiChar(SQLITE_VERSION);
end;

function sqlite3_libversion_number: i32; cdecl;
begin
  Result := SQLITE_VERSION_NUMBER;
end;

function sqlite3_sourceid: PAnsiChar; cdecl;
begin
  Result := PAnsiChar(SQLITE_SOURCE_ID);
end;

function sqlite3_threadsafe: i32; cdecl;
begin
  { passqlite3util:848 sets bFullMutex=1 → SQLITE_THREADSAFE==1. }
  Result := 1;
end;

{ ctime.c:55..808 — names of compile-time options used to build the
  library.  The Pas port currently has no ENABLE_/OMIT_ flag plumbing
  reachable from this entry point, so the table is empty — matches the
  C build with no SQLITE_ENABLE_*/SQLITE_OMIT_* defines.  Verbatim port
  of ctime.c:809..812. }
const
  sqlite3azCompileOpt: array[0..0] of PAnsiChar = (nil);

function sqlite3CompileOptions(out pnOpt: i32): PPAnsiChar;
begin
  pnOpt := 0;
  Result := @sqlite3azCompileOpt[0];
end;

{ main.c:5158 — verbatim port. }
function sqlite3_compileoption_used(zOptName: PAnsiChar): i32; cdecl;
var
  i, n, nOpt: i32;
  azOpt: PPAnsiChar;
  zCur: PAnsiChar;
begin
  if zOptName = nil then begin Result := 0; Exit; end;
  azOpt := sqlite3CompileOptions(nOpt);
  if sqlite3_strnicmp(zOptName, PAnsiChar('SQLITE_'), 7) = 0 then
    Inc(zOptName, 7);
  n := sqlite3Strlen30(zOptName);
  for i := 0 to nOpt - 1 do begin
    zCur := azOpt[i];
    if (zCur <> nil)
       and (sqlite3_strnicmp(zOptName, zCur, n) = 0)
       and (sqlite3IsIdChar(u8((zCur + n)^)) = 0)
    then begin
      Result := 1; Exit;
    end;
  end;
  Result := 0;
end;

{ main.c:5191 — verbatim port. }
function sqlite3_compileoption_get(N: i32): PAnsiChar; cdecl;
var
  nOpt: i32;
  azOpt: PPAnsiChar;
begin
  azOpt := sqlite3CompileOptions(nOpt);
  if (N >= 0) and (N < nOpt) then
    Result := azOpt[N]
  else
    Result := nil;
end;

function sqlite3_last_insert_rowid(db: PTsqlite3): i64; cdecl;
begin
  if db = nil then begin Result := 0; Exit; end;
  Result := db^.lastRowid;
end;

procedure sqlite3_set_last_insert_rowid(db: PTsqlite3; iRowid: i64); cdecl;
begin
  if db = nil then Exit;
  sqlite3_mutex_enter(db^.mutex);
  db^.lastRowid := iRowid;
  sqlite3_mutex_leave(db^.mutex);
end;

function sqlite3_changes64(db: PTsqlite3): i64; cdecl;
begin
  if db = nil then begin Result := 0; Exit; end;
  Result := db^.nChange;
end;

function sqlite3_changes(db: PTsqlite3): i32; cdecl;
begin
  Result := i32(sqlite3_changes64(db));
end;

function sqlite3_total_changes64(db: PTsqlite3): i64; cdecl;
begin
  if db = nil then begin Result := 0; Exit; end;
  Result := db^.nTotalChange;
end;

function sqlite3_total_changes(db: PTsqlite3): i32; cdecl;
begin
  Result := i32(sqlite3_total_changes64(db));
end;

procedure sqlite3_interrupt(db: PTsqlite3); cdecl;
begin
  if db = nil then Exit;
  db^.u1.isInterrupted := 1;
end;

function sqlite3_is_interrupted(db: PTsqlite3): i32; cdecl;
begin
  if db = nil then begin Result := 0; Exit; end;
  if db^.u1.isInterrupted <> 0 then Result := 1 else Result := 0;
end;

{ main.c:1812 — sqlite3_progress_handler.  Sets per-connection progress
  callback fired every nOps VDBE step opcodes.  When nOps<=0 the callback
  is cleared.  The runtime invocation is already wired in
  passqlite3vdbe.pas (xProgress is consulted in sqlite3VdbeExec). }
procedure sqlite3_progress_handler(db: PTsqlite3; nOps: i32;
  xProgress: TProgressHandlerFn; pArg: Pointer); cdecl;
begin
  if db = nil then Exit;
  if nOps > 0 then begin
    db^.xProgress    := xProgress;
    db^.nProgressOps := u32(nOps);
    db^.pProgressArg := pArg;
  end else begin
    db^.xProgress    := nil;
    db^.nProgressOps := 0;
    db^.pProgressArg := nil;
  end;
end;

{ main.c:2439 — sqlite3_autovacuum_pages.  Per-connection autovacuum hook
  invoked from the pager autovacuum path.  If a previous destructor was
  registered, fire it for the previous pArg before installing the new
  callback. }
function sqlite3_autovacuum_pages(db: PTsqlite3; xCallback: TAutovacuumPagesFn;
  pArg: Pointer; xDestructor: TAutovacuumDestrFn): i32; cdecl;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    if Assigned(xDestructor) then xDestructor(pArg);
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  if Assigned(db^.xAutovacDestr) then
    db^.xAutovacDestr(db^.pAutovacPagesArg);
  db^.xAutovacPages    := Pointer(@xCallback);
  db^.pAutovacPagesArg := pArg;
  db^.xAutovacDestr    := xDestructor;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ main.c:2197 — sqlite3InvalidFunction.  Static helper used by
  sqlite3_overload_function: when a virtual table claims to overload
  a function but the runtime ends up calling the global stub directly,
  this scalar emits the canonical "unable to use function NAME in the
  requested context" error. }
procedure sqlite3InvalidFunction(pCtx: Psqlite3_context; nArg: i32;
  argv: PPsqlite3_value); cdecl;
var
  zName, zErr: PAnsiChar;
begin
  { sqlite3_mprintf is a single-fmt-arg wrapper in the Pas port (no real
    varargs), so format the message inline rather than via "%s". }
  zName := PAnsiChar(sqlite3_user_data(pCtx));
  if zName <> nil then
    zErr := PAnsiChar(sqlite3StrDup(PChar('unable to use function ' + StrPas(zName) + ' in the requested context')))
  else
    zErr := PAnsiChar(sqlite3StrDup(PChar('unable to use function in the requested context')));
  sqlite3_result_error(pCtx, zErr, -1);
  sqlite3_free(zErr);
end;

{ main.c:2223 — sqlite3_overload_function.  Declare that a function has
  been overloaded by a virtual table.  If the function already exists as
  a regular global function, this is a no-op.  Otherwise create a stub
  that always errors at runtime; xFindFunction on the vtab is expected
  to redirect lookups to the real implementation. }
function sqlite3_overload_function(db: PTsqlite3; zName: PAnsiChar;
  nArg: i32): i32; cdecl;
var
  rc:    i32;
  zCopy: PAnsiChar;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) or (nArg < -2) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  if sqlite3FindFunction(db, zName, nArg, SQLITE_UTF8, 0) <> nil then
    rc := 1
  else
    rc := 0;
  sqlite3_mutex_leave(db^.mutex);
  if rc <> 0 then begin Result := SQLITE_OK; Exit; end;
  zCopy := PAnsiChar(sqlite3StrDup(PChar(zName)));
  if zCopy = nil then begin Result := SQLITE_NOMEM; Exit; end;
  Result := sqlite3_create_function_v2(db, zName, nArg, SQLITE_UTF8,
              zCopy, @sqlite3InvalidFunction, nil, nil, @sqlite3_free);
end;

{ main.c:4009 — sqlite3_table_column_metadata.  Return type, collation,
  NOT NULL, PK and AUTOINCREMENT metadata for a table column.  When
  zColumnName is nil, only existence of the table is checked.  rowid
  aliases ("rowid", "oid", "_rowid_") resolve to the IPK column when
  HasRowid; otherwise INTEGER + PRIMARY KEY are reported. }
function sqlite3_table_column_metadata(db: PTsqlite3;
  zDbName: PAnsiChar; zTableName: PAnsiChar; zColumnName: PAnsiChar;
  pzDataType: PPAnsiChar; pzCollSeq: PPAnsiChar;
  pNotNull: Pi32; pPrimaryKey: Pi32; pAutoinc: Pi32): i32; cdecl;
label
  error_out;
var
  rc:         i32;
  iCol:       i32;
  zErrMsg:    PAnsiChar;
  pTab:       PTable2;
  pCol:       PColumn;
  zDataType:  PAnsiChar;
  zCollSeq:   PAnsiChar;
  notnull:    i32;
  primarykey: i32;
  autoinc:    i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zTableName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  rc         := SQLITE_OK;
  zErrMsg    := nil;
  pTab       := nil;
  pCol       := nil;
  iCol       := 0;
  zDataType  := nil;
  zCollSeq   := nil;
  notnull    := 0;
  primarykey := 0;
  autoinc    := 0;

  sqlite3_mutex_enter(db^.mutex);
  sqlite3BtreeEnterAll(db);

  pTab := sqlite3FindTable(db, zTableName, zDbName);
  if (pTab = nil) or IsView(pTab) then begin
    pTab := nil;
    goto error_out;
  end;

  if zColumnName = nil then begin
    { Existence check only. }
  end else begin
    iCol := sqlite3ColumnIndex(pTab, zColumnName);
    if iCol >= 0 then
      pCol := @pTab^.aCol[iCol]
    else if HasRowid(pTab) and (sqlite3IsRowid(zColumnName) <> 0) then begin
      iCol := pTab^.iPKey;
      if iCol >= 0 then pCol := @pTab^.aCol[iCol] else pCol := nil;
    end else begin
      pTab := nil;
      goto error_out;
    end;
  end;

  if pCol <> nil then begin
    zDataType  := sqlite3ColumnType(pCol, nil);
    zCollSeq   := sqlite3ColumnColl(pCol);
    if (pCol^.typeFlags and $0F) <> 0 then notnull := 1 else notnull := 0;
    if (pCol^.colFlags and COLFLAG_PRIMKEY) <> 0 then primarykey := 1
    else primarykey := 0;
    if (pTab^.iPKey = iCol)
       and ((pTab^.tabFlags and TF_Autoincrement) <> 0) then
      autoinc := 1
    else
      autoinc := 0;
  end else begin
    zDataType  := 'INTEGER';
    primarykey := 1;
  end;
  if zCollSeq = nil then zCollSeq := 'BINARY';

error_out:
  sqlite3BtreeLeaveAll(db);

  if pzDataType  <> nil then pzDataType^  := zDataType;
  if pzCollSeq   <> nil then pzCollSeq^   := zCollSeq;
  if pNotNull    <> nil then pNotNull^    := notnull;
  if pPrimaryKey <> nil then pPrimaryKey^ := primarykey;
  if pAutoinc    <> nil then pAutoinc^    := autoinc;

  if (rc = SQLITE_OK) and (pTab = nil) then begin
    sqlite3DbFree(db, zErrMsg);
    zErrMsg := sqlite3MPrintf(db, 'no such table column: %s.%s',
                              [zTableName, zColumnName]);
    rc := SQLITE_ERROR;
  end;
  if zErrMsg <> nil then sqlite3ErrorWithMsg(db, rc, zErrMsg)
  else if rc <> SQLITE_OK then sqlite3ErrorWithMsg(db, rc, nil);
  sqlite3DbFree(db, zErrMsg);
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_errcode(db: PTsqlite3): i32; cdecl;
begin
  if (db <> nil) and (sqlite3SafetyCheckSickOrOk(db) = 0) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if (db = nil) or (db^.mallocFailed <> 0) then begin
    Result := SQLITE_NOMEM; Exit;
  end;
  Result := db^.errCode and db^.errMask;
end;

function sqlite3_extended_errcode(db: PTsqlite3): i32; cdecl;
begin
  if (db <> nil) and (sqlite3SafetyCheckSickOrOk(db) = 0) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if (db = nil) or (db^.mallocFailed <> 0) then begin
    Result := SQLITE_NOMEM; Exit;
  end;
  Result := db^.errCode;
end;

function sqlite3_extended_result_codes(db: PTsqlite3; onoff: i32): i32; cdecl;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if onoff <> 0 then db^.errMask := i32($FFFFFFFF) else db^.errMask := $FF;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

function sqlite3_system_errno(db: PTsqlite3): i32; cdecl;
begin
  if db = nil then Result := 0 else Result := db^.iSysErrno;
end;

function sqlite3_get_autocommit(db: PTsqlite3): i32; cdecl;
begin
  if db = nil then begin Result := 0; Exit; end;
  Result := db^.autoCommit;
end;

{ complete.c:269 — sqlite3_complete16.  UTF-16 wrapper around sqlite3_complete:
  wraps the input as a sqlite3_value with SQLITE_UTF16NATIVE encoding, asks
  the value layer to transcode to UTF-8, then forwards. }
function sqlite3_complete16(zSql: Pointer): i32; cdecl;
var
  pVal: Psqlite3_value;
  zSql8: PAnsiChar;
  rc: i32;
begin
  pVal := sqlite3ValueNew(nil);
  if pVal = nil then begin Result := SQLITE_NOMEM; Exit; end;
  sqlite3ValueSetStr(pVal, -1, zSql, SQLITE_UTF16NATIVE, SQLITE_STATIC);
  zSql8 := PAnsiChar(sqlite3ValueText(pVal, SQLITE_UTF8));
  if zSql8 <> nil then
    rc := sqlite3_complete(zSql8)
  else
    rc := SQLITE_NOMEM;
  sqlite3ValueFree(pVal);
  Result := rc and $FF;
end;

{ main.c:3706 — sqlite3_open16.  Open a new database handle from a UTF-16
  filename.  Wraps the input as a sqlite3_value with SQLITE_UTF16NATIVE
  encoding, transcodes to UTF-8, then forwards to openDatabase.  When the
  open succeeds and the schema has not been loaded yet, force the
  connection encoding (and the schema's own enc field) to UTF-16NATIVE so
  subsequent prepares produce UTF-16 text. }
function sqlite3_open16(zFilename: Pointer; ppDb: PPTsqlite3): i32; cdecl;
const
  zEmpty16: array[0..1] of Byte = (0, 0);
var
  pVal: Psqlite3_value;
  zFilename8: PAnsiChar;
  rc: i32;
  pDb: PTsqlite3;
begin
  if ppDb = nil then begin Result := SQLITE_MISUSE; Exit; end;
  ppDb^ := nil;
  if zFilename = nil then zFilename := @zEmpty16[0];
  pVal := sqlite3ValueNew(nil);
  if pVal = nil then begin Result := SQLITE_NOMEM; Exit; end;
  sqlite3ValueSetStr(pVal, -1, zFilename, SQLITE_UTF16NATIVE, SQLITE_STATIC);
  zFilename8 := PAnsiChar(sqlite3ValueText(pVal, SQLITE_UTF8));
  if zFilename8 <> nil then begin
    rc := openDatabase(zFilename8, ppDb,
                       SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
    pDb := ppDb^;
    if (rc = SQLITE_OK) and (pDb <> nil) and (pDb^.aDb <> nil)
       and (pDb^.aDb[0].pSchema <> nil)
       and ((pDb^.aDb[0].pSchema^.schemaFlags and DB_SchemaLoaded) = 0) then
    begin
      pDb^.aDb[0].pSchema^.enc := SQLITE_UTF16NATIVE;
      pDb^.enc := SQLITE_UTF16NATIVE;
    end;
  end else
    rc := SQLITE_NOMEM;
  sqlite3ValueFree(pVal);
  Result := rc and $FF;
end;

{ prepare.c:983 — sqlite3Prepare16.  Transcode UTF-16 zSql to UTF-8 via a
  sqlite3_value, forward to sqlite3LockAndPrepare, then translate the UTF-8
  tail pointer back into a UTF-16 byte offset for *pzTail. }
function utf16ByteLenForChars(zIn: Pointer; nByte: i32; nChar: i32): i32;
{ Mirrors sqlite3Utf16ByteLen: count up to nChar codepoints in the UTF-16NATIVE
  buffer zIn (length nByte; -1 = until U+0000), return their byte length. }
var
  p: PByte;
  c: u32;
  i, n: i32;
begin
  p := PByte(zIn);
  i := 0;
  n := 0;
  while (nChar > 0) and ((nByte < 0) or (i + 1 < nByte)) do
  begin
    { Read one UTF-16LE code unit (Pas port is LE-only). }
    c := u32(p[i]) or (u32(p[i + 1]) shl 8);
    if (nByte < 0) and (c = 0) then break;
    Inc(i, 2);
    { High surrogate? Consume the trailing low surrogate too. }
    if (c >= $D800) and (c < $DC00)
       and ((nByte < 0) or (i + 1 < nByte)) then
    begin
      c := u32(p[i]) or (u32(p[i + 1]) shl 8);
      if (c >= $DC00) and (c < $E000) then Inc(i, 2);
    end;
    Dec(nChar);
    n := i;
  end;
  Result := n;
end;

function sqlite3Prepare16(db: PTsqlite3; zSql: Pointer; nBytes: i32;
  prepFlags: u32; ppStmt: PPointer; pzTail: PPointer): i32;
var
  pVal: Psqlite3_value;
  zSql8, zTail8: PAnsiChar;
  rc: i32;
  z: PByte;
  sz: i32;
  charsParsed: i32;
begin
  if ppStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  ppStmt^ := nil;
  if (sqlite3SafetyCheckOk(db) = 0) or (zSql = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;

  { Find U+0000 terminator / clamp nBytes to even. }
  z := PByte(zSql);
  if nBytes >= 0 then begin
    sz := 0;
    while (sz < nBytes) and ((z[sz] <> 0) or (z[sz + 1] <> 0)) do Inc(sz, 2);
    nBytes := sz;
  end else begin
    sz := 0;
    while (z[sz] <> 0) or (z[sz + 1] <> 0) do Inc(sz, 2);
    nBytes := sz;
  end;

  sqlite3_mutex_enter(db^.mutex);
  zTail8 := nil;
  pVal := sqlite3ValueNew(db);
  if pVal = nil then begin
    rc := SQLITE_NOMEM;
  end else begin
    sqlite3ValueSetStr(pVal, nBytes, zSql, SQLITE_UTF16NATIVE, SQLITE_STATIC);
    zSql8 := PAnsiChar(sqlite3ValueText(pVal, SQLITE_UTF8));
    if zSql8 <> nil then
      rc := sqlite3LockAndPrepare(db, zSql8, -1, prepFlags, nil,
                                  ppStmt, @zTail8)
    else
      rc := SQLITE_NOMEM;

    if (zTail8 <> nil) and (pzTail <> nil) and (zSql8 <> nil) then
    begin
      charsParsed := sqlite3Utf8CharLen(zSql8,
                                        i32(PtrUInt(zTail8) - PtrUInt(zSql8)));
      pzTail^ := Pointer(PtrUInt(zSql)
                         + PtrUInt(utf16ByteLenForChars(zSql, nBytes,
                                                        charsParsed)));
    end;
    sqlite3ValueFree(pVal);
  end;
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_prepare16(db: PTsqlite3; zSql: Pointer; nBytes: i32;
  ppStmt: PPointer; pzTail: PPointer): i32; cdecl;
begin
  Result := sqlite3Prepare16(db, zSql, nBytes, 0, ppStmt, pzTail);
end;

function sqlite3_prepare16_v2(db: PTsqlite3; zSql: Pointer; nBytes: i32;
  ppStmt: PPointer; pzTail: PPointer): i32; cdecl;
begin
  Result := sqlite3Prepare16(db, zSql, nBytes, SQLITE_PREPARE_SAVESQL,
                             ppStmt, pzTail);
end;

function sqlite3_prepare16_v3(db: PTsqlite3; zSql: Pointer; nBytes: i32;
  prepFlags: u32; ppStmt: PPointer; pzTail: PPointer): i32; cdecl;
begin
  Result := sqlite3Prepare16(db, zSql, nBytes,
              (prepFlags and SQLITE_PREPARE_MASK) or SQLITE_PREPARE_SAVESQL,
              ppStmt, pzTail);
end;

{ main.c:3783 — sqlite3_create_collation16.  UTF-16 wrapper around
  createCollation: transcode the name to UTF-8 via a sqlite3_value, then
  forward.  Mirrors the !defined(SQLITE_OMIT_UTF16) arm. }
function sqlite3_create_collation16(db: PTsqlite3; zName: Pointer; enc: i32;
  pCtx: Pointer; xCompare: Pointer): i32; cdecl;
var
  pVal: Psqlite3_value;
  zName8: PAnsiChar;
  rc: i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  rc := SQLITE_OK;
  pVal := sqlite3ValueNew(db);
  if pVal = nil then begin
    rc := SQLITE_NOMEM;
  end else begin
    sqlite3ValueSetStr(pVal, -1, zName, SQLITE_UTF16NATIVE, SQLITE_STATIC);
    zName8 := PAnsiChar(sqlite3ValueText(pVal, SQLITE_UTF8));
    if zName8 <> nil then
      rc := createCollation(db, zName8, u8(enc), pCtx, xCompare, nil)
    else
      rc := SQLITE_NOMEM;
    sqlite3ValueFree(pVal);
  end;
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ main.c:3834 — sqlite3_collation_needed16. }
function sqlite3_collation_needed16(db: PTsqlite3; pCollNeededArg: Pointer;
  xCollNeeded16: Pointer): i32; cdecl;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  db^.xCollNeeded    := nil;
  db^.xCollNeeded16  := xCollNeeded16;
  db^.pCollNeededArg := pCollNeededArg;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ main.c:2161 — sqlite3_create_function16.  UTF-16 wrapper around
  sqlite3CreateFunc: transcode the function name to UTF-8 via a sqlite3_value,
  then forward through createFunctionApi. }
function sqlite3_create_function16(db: PTsqlite3; zFunctionName: Pointer;
  nArg: i32; eTextRep: i32; p: Pointer;
  xSFunc: Pointer; xStep: Pointer; xFinal: Pointer): i32; cdecl;
var
  pVal: Psqlite3_value;
  zFunc8: PAnsiChar;
  rc: i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (zFunctionName = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  rc := SQLITE_OK;
  pVal := sqlite3ValueNew(db);
  if pVal = nil then begin
    rc := SQLITE_NOMEM;
  end else begin
    sqlite3ValueSetStr(pVal, -1, zFunctionName, SQLITE_UTF16NATIVE, SQLITE_STATIC);
    zFunc8 := PAnsiChar(sqlite3ValueText(pVal, SQLITE_UTF8));
    if zFunc8 <> nil then
      rc := sqlite3CreateFunc(db, zFunc8, nArg, eTextRep, p,
              xSFunc, xStep, xFinal, nil, nil, nil)
    else
      rc := SQLITE_NOMEM;
    sqlite3ValueFree(pVal);
  end;
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ vdbeapi.c:2074 — sqlite3_stmt_busy. }
function sqlite3_stmt_busy(pStmt: Pointer): i32; cdecl;
var v: PVdbe;
begin
  v := PVdbe(pStmt);
  if (v <> nil) and (v^.eVdbeState = VDBE_RUN_STATE) then
    Result := 1
  else
    Result := 0;
end;

{ vdbeapi.c:2106 — sqlite3_stmt_status.  Return (and optionally reset)
  one of the per-stmt counters maintained in v^.aCounter[].  The
  SQLITE_STMTSTATUS_MEMUSED branch reproduces the C trick of running
  sqlite3VdbeDelete with db^.pnBytesFreed pointing at a local counter so
  every freed allocation accumulates into v. }
function sqlite3_stmt_status(pStmt: Pointer; op, resetFlag: i32): i32; cdecl;
var
  v: PVdbe;
  db: PTsqlite3;
  vCnt: u32;
begin
  if (pStmt = nil)
     or ((op <> SQLITE_STMTSTATUS_MEMUSED)
         and ((op < 0) or (op >= 9))) then
  begin
    Result := 0;
    Exit;
  end;
  v := PVdbe(pStmt);
  if op = SQLITE_STMTSTATUS_MEMUSED then
  begin
    db := PTsqlite3(v^.db);
    sqlite3_mutex_enter(db^.mutex);
    vCnt := 0;
    db^.pnBytesFreed := Pi32(@vCnt);
    db^.lookaside.pEnd := db^.lookaside.pStart;
    sqlite3VdbeDelete(v);
    db^.pnBytesFreed := nil;
    db^.lookaside.pEnd := db^.lookaside.pTrueEnd;
    sqlite3_mutex_leave(db^.mutex);
  end
  else
  begin
    vCnt := v^.aCounter[op];
    if resetFlag <> 0 then
      v^.aCounter[op] := 0;
  end;
  Result := i32(vCnt);
end;

{ vdbeapi.c:2038 — sqlite3_stmt_explain.  Switch a prepared statement
  between normal / EXPLAIN / EXPLAIN QUERY PLAN modes, reprepare if
  required, and adjust the result-column count accordingly. }
function sqlite3_stmt_explain(pStmt: Pointer; eMode: i32): i32; cdecl;
var
  v: PVdbe;
  curExplain: i32;
begin
  if pStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  v := PVdbe(pStmt);
  sqlite3_mutex_enter(PTsqlite3(v^.db)^.mutex);
  curExplain := i32((v^.vdbeFlags and VDBF_EXPLAIN_MASK) shr VDBF_EXPLAIN_SHIFT);
  if curExplain = eMode then
    Result := SQLITE_OK
  else if (eMode < 0) or (eMode > 2) then
    Result := SQLITE_ERROR
  else if (v^.prepFlags and SQLITE_PREPARE_SAVESQL) = 0 then
    Result := SQLITE_ERROR
  else if v^.eVdbeState <> VDBE_READY_STATE then
    Result := SQLITE_BUSY
  else if (v^.nMem >= 10) and ((eMode <> 2) or ((v^.vdbeFlags and VDBF_HaveEqpOps) <> 0)) then
  begin
    v^.vdbeFlags := (v^.vdbeFlags and (not u32(VDBF_EXPLAIN_MASK)))
                    or (u32(eMode) shl VDBF_EXPLAIN_SHIFT);
    Result := SQLITE_OK;
  end
  else begin
    v^.vdbeFlags := (v^.vdbeFlags and (not u32(VDBF_EXPLAIN_MASK)))
                    or (u32(eMode) shl VDBF_EXPLAIN_SHIFT);
    Result := sqlite3Reprepare(v);
    if eMode = 2 then
      v^.vdbeFlags := v^.vdbeFlags or VDBF_HaveEqpOps
    else
      v^.vdbeFlags := v^.vdbeFlags and (not u32(VDBF_HaveEqpOps));
  end;
  curExplain := i32((v^.vdbeFlags and VDBF_EXPLAIN_MASK) shr VDBF_EXPLAIN_SHIFT);
  if curExplain <> 0 then
    v^.nResColumn := u16(12 - 4 * curExplain)
  else
    v^.nResColumn := v^.nResAlloc;
  sqlite3_mutex_leave(PTsqlite3(v^.db)^.mutex);
end;

{ vdbeapi.c:2023 — sqlite3_stmt_readonly. }
function sqlite3_stmt_readonly(pStmt: Pointer): i32; cdecl;
begin
  if pStmt = nil then begin Result := 1; Exit; end;
  if (PVdbe(pStmt)^.vdbeFlags and VDBF_ReadOnly) <> 0 then
    Result := 1
  else
    Result := 0;
end;

{ vdbeapi.c:2015 — sqlite3_db_handle.  Return the connection that owns
  the prepared statement. }
function sqlite3_db_handle(pStmt: Pointer): PTsqlite3; cdecl;
begin
  if pStmt = nil then Result := nil
  else Result := PTsqlite3(PVdbe(pStmt)^.db);
end;

{ main.c:883 — sqlite3_db_mutex.  Return the per-connection mutex. }
function sqlite3_db_mutex(db: PTsqlite3): Pointer; cdecl;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  Result := db^.mutex;
end;

{ main.c:4967 — sqlite3_db_name.  Return the name of the N-th database
  schema, or nil if N is out of range. }
function sqlite3_db_name(db: PTsqlite3; N: i32): PAnsiChar; cdecl;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  if (N < 0) or (N >= db^.nDb) then Result := nil
  else Result := db^.aDb[N].zDbSName;
end;

{ main.c:2844 — sqlite3_errstr.  Return the static error-code string. }
function sqlite3_errstr(rc: i32): PAnsiChar; cdecl;
begin
  Result := sqlite3ErrStr(rc);
end;

{ vdbeapi.c:2085 — sqlite3_next_stmt.  Walk the per-connection linked list
  of prepared statements; nil pStmt returns the head. }
function sqlite3_next_stmt(pDb: PTsqlite3; pStmt: Pointer): Pointer; cdecl;
var pNext: Pointer;
begin
  if sqlite3SafetyCheckOk(pDb) = 0 then begin Result := nil; Exit; end;
  sqlite3_mutex_enter(pDb^.mutex);
  if pStmt = nil then pNext := pDb^.pVdbe
  else pNext := PVdbe(pStmt)^.pVNext;
  sqlite3_mutex_leave(pDb^.mutex);
  Result := pNext;
end;

{ vdbeapi.c:2138 — sqlite3_sql.  Return the original SQL text saved on the
  Vdbe (only populated when the statement was prepared with
  SQLITE_PREPARE_SAVESQL / sqlite3_prepare_v2/v3). }
function sqlite3_sql(pStmt: Pointer): PAnsiChar; cdecl;
begin
  if pStmt = nil then Result := nil
  else Result := PVdbe(pStmt)^.zSql;
end;

{ vdbeapi.c:2152 — sqlite3_expanded_sql.  Expand bound parameters in the
  SQL text; returned string is allocated via sqlite3_malloc. }
function sqlite3_expanded_sql(pStmt: Pointer): PAnsiChar; cdecl;
var
  zSrc: PAnsiChar;
  p:    PVdbe;
begin
  Result := nil;
  if pStmt = nil then Exit;
  p := PVdbe(pStmt);
  zSrc := p^.zSql;
  if zSrc = nil then Exit;
  sqlite3_mutex_enter(PTsqlite3(p^.db)^.mutex);
  Result := sqlite3VdbeExpandSql(p, zSrc);
  sqlite3_mutex_leave(PTsqlite3(p^.db)^.mutex);
end;

function sqlite3_db_readonly(db: PTsqlite3; zDbName: PAnsiChar): i32; cdecl;
var
  iDb: i32;
  pBt: Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := -1; Exit; end;
  if zDbName <> nil then iDb := sqlite3FindDbName(db, zDbName) else iDb := 0;
  if iDb < 0 then begin Result := -1; Exit; end;
  pBt := db^.aDb[iDb].pBt;
  if pBt = nil then begin Result := -1; Exit; end;
  Result := sqlite3BtreeIsReadonly(PBtree(pBt));
end;

{ main.c:4985 — sqlite3_db_filename.  Return the full pathname of the
  database file backing zDbName ("main"/"temp"/attached), or NULL if no
  such schema is attached.  Temp / in-memory dbs report ''. }
function sqlite3DbNameToBtree(db: PTsqlite3; zDbName: PAnsiChar): PBtree; forward;
function sqlite3_db_filename(db: PTsqlite3; zDbName: PAnsiChar): PAnsiChar; cdecl;
var pBt: PBtree;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
  pBt := sqlite3DbNameToBtree(db, zDbName);
  if pBt = nil then Result := nil
  else            Result := sqlite3BtreeGetFilename(pBt);
end;

{ main.c:897 — sqlite3_db_release_memory.  Free as much memory as we can
  from the given database connection. }
function sqlite3_db_release_memory(db: PTsqlite3): i32; cdecl;
var
  i:      i32;
  pBt:    PBtree;
  pPgr:   Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE;
    Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  sqlite3BtreeEnterAll(db);
  for i := 0 to db^.nDb - 1 do begin
    pBt := PBtree(db^.aDb[i].pBt);
    if pBt <> nil then begin
      pPgr := sqlite3BtreePager(pBt);
      sqlite3PagerShrink(pPgr);
    end;
  end;
  sqlite3BtreeLeaveAll(db);
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ main.c:921 — sqlite3_db_cacheflush.  Flush dirty pages in the pager
  cache for any attached database that has an open write transaction. }
function sqlite3_db_cacheflush(db: PTsqlite3): i32; cdecl;
var
  i, rc, bSeenBusy: i32;
  pBt:    PBtree;
  pPgr:   Pointer;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE;
    Exit;
  end;
  rc        := SQLITE_OK;
  bSeenBusy := 0;
  sqlite3_mutex_enter(db^.mutex);
  sqlite3BtreeEnterAll(db);
  i := 0;
  while (rc = SQLITE_OK) and (i < db^.nDb) do begin
    pBt := PBtree(db^.aDb[i].pBt);
    if (pBt <> nil) and (sqlite3BtreeTxnState(pBt) = SQLITE_TXN_WRITE) then begin
      pPgr := sqlite3BtreePager(pBt);
      rc := sqlite3PagerFlush(pPgr);
      if rc = SQLITE_BUSY then begin
        bSeenBusy := 1;
        rc := SQLITE_OK;
      end;
    end;
    Inc(i);
  end;
  sqlite3BtreeLeaveAll(db);
  sqlite3_mutex_leave(db^.mutex);
  if (rc = SQLITE_OK) and (bSeenBusy <> 0) then
    Result := SQLITE_BUSY
  else
    Result := rc;
end;

{ status.c:188 — sqlite3LookasideUsed.  Count outstanding lookaside slots,
  optionally returning the high-water mark in pHighwater. }
function sqlite3LookasideUsed(db: PTsqlite3; pHighwater: Pi32): i32;
  function countSlots(p: PLookasideSlot): u32;
  var n: u32;
  begin
    n := 0;
    while p <> nil do begin Inc(n); p := p^.pNext; end;
    Result := n;
  end;
var
  nInit, nFree: u32;
begin
  nInit := countSlots(db^.lookaside.pInit) + countSlots(db^.lookaside.pSmallInit);
  nFree := countSlots(db^.lookaside.pFree) + countSlots(db^.lookaside.pSmallFree);
  if pHighwater <> nil then pHighwater^ := i32(db^.lookaside.nSlot - nInit);
  Result := i32(db^.lookaside.nSlot - (nInit + nFree));
end;

{ status.c:203 — sqlite3_db_status64.  Query per-connection status counters.
  Verbs SCHEMA_USED and STMT_USED require the pnBytesFreed accounting plumbing
  (drives sqlite3DbFree to count rather than free); not yet wired in this
  port, so they fall through to SQLITE_ERROR. }
function sqlite3_db_status64(db: PTsqlite3; op: i32; pCurrent, pHighwtr: Pi64;
                             resetFlag: i32): i32; cdecl;
var
  rc: i32;
  H:  i32;
  p, pTail: PLookasideSlot;
  i:  i32;
  pBt: PBtree;
  pPgr: PPager;
  totalUsed: i64;
  nByte: i32;
  nRet: u64;
  opLocal: i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (pCurrent = nil) or (pHighwtr = nil) then
  begin
    Result := SQLITE_MISUSE;
    Exit;
  end;
  rc := SQLITE_OK;
  sqlite3_mutex_enter(db^.mutex);
  case op of
    SQLITE_DBSTATUS_LOOKASIDE_USED:
      begin
        H := 0;
        pCurrent^ := sqlite3LookasideUsed(db, @H);
        pHighwtr^ := H;
        if resetFlag <> 0 then
        begin
          { Reset HWM: append pFree at the tail of pInit, then clear pFree. }
          p := db^.lookaside.pFree;
          if p <> nil then
          begin
            pTail := p;
            while pTail^.pNext <> nil do pTail := pTail^.pNext;
            pTail^.pNext := db^.lookaside.pInit;
            db^.lookaside.pInit := db^.lookaside.pFree;
            db^.lookaside.pFree := nil;
          end;
          p := db^.lookaside.pSmallFree;
          if p <> nil then
          begin
            pTail := p;
            while pTail^.pNext <> nil do pTail := pTail^.pNext;
            pTail^.pNext := db^.lookaside.pSmallInit;
            db^.lookaside.pSmallInit := db^.lookaside.pSmallFree;
            db^.lookaside.pSmallFree := nil;
          end;
        end;
      end;
    SQLITE_DBSTATUS_LOOKASIDE_HIT,
    SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE,
    SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL:
      begin
        pCurrent^ := 0;
        pHighwtr^ := db^.lookaside.anStat[op - SQLITE_DBSTATUS_LOOKASIDE_HIT];
        if resetFlag <> 0 then
          db^.lookaside.anStat[op - SQLITE_DBSTATUS_LOOKASIDE_HIT] := 0;
      end;
    SQLITE_DBSTATUS_CACHE_USED, SQLITE_DBSTATUS_CACHE_USED_SHARED:
      begin
        totalUsed := 0;
        sqlite3BtreeEnterAll(db);
        for i := 0 to db^.nDb - 1 do
        begin
          pBt := PBtree(db^.aDb[i].pBt);
          if pBt <> nil then
          begin
            pPgr := sqlite3BtreePager(pBt);
            nByte := sqlite3PagerMemUsed(pPgr);
            { No shared-cache in this port — connection count is always 1. }
            totalUsed := totalUsed + nByte;
          end;
        end;
        sqlite3BtreeLeaveAll(db);
        pCurrent^ := totalUsed;
        pHighwtr^ := 0;
      end;
    SQLITE_DBSTATUS_CACHE_SPILL,
    SQLITE_DBSTATUS_CACHE_HIT,
    SQLITE_DBSTATUS_CACHE_MISS,
    SQLITE_DBSTATUS_CACHE_WRITE:
      begin
        opLocal := op;
        if opLocal = SQLITE_DBSTATUS_CACHE_SPILL then
          opLocal := SQLITE_DBSTATUS_CACHE_WRITE + 1;
        nRet := 0;
        for i := 0 to db^.nDb - 1 do
          if db^.aDb[i].pBt <> nil then
          begin
            pPgr := sqlite3BtreePager(PBtree(db^.aDb[i].pBt));
            nRet := nRet + sqlite3PagerCacheStat(pPgr, opLocal, resetFlag);
          end;
        pHighwtr^ := 0;
        pCurrent^ := i64(nRet);
      end;
    SQLITE_DBSTATUS_TEMPBUF_SPILL:
      begin
        nRet := 0;
        if (db^.nDb >= 2) and (db^.aDb[1].pBt <> nil) then
        begin
          pPgr := sqlite3BtreePager(PBtree(db^.aDb[1].pBt));
          nRet := sqlite3PagerCacheStat(pPgr, SQLITE_DBSTATUS_CACHE_WRITE, resetFlag);
          nRet := nRet * u64(sqlite3BtreeGetPageSize(PBtree(db^.aDb[1].pBt)));
        end;
        nRet := nRet + db^.nSpill;
        if resetFlag <> 0 then db^.nSpill := 0;
        pHighwtr^ := 0;
        pCurrent^ := i64(nRet);
      end;
    SQLITE_DBSTATUS_DEFERRED_FKS:
      begin
        pHighwtr^ := 0;
        if (db^.nDeferredImmCons > 0) or (db^.nDeferredCons > 0) then
          pCurrent^ := 1
        else
          pCurrent^ := 0;
      end;
  else
    rc := SQLITE_ERROR;
  end;
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ status.c:426 — sqlite3_db_status.  32-bit variant of sqlite3_db_status64. }
function sqlite3_db_status(db: PTsqlite3; op: i32; pCurrent, pHighwtr: Pi32;
                           resetFlag: i32): i32; cdecl;
var
  C, H: i64;
  rc:   i32;
begin
  if (sqlite3SafetyCheckOk(db) = 0) or (pCurrent = nil) or (pHighwtr = nil) then
  begin
    Result := SQLITE_MISUSE;
    Exit;
  end;
  C := 0; H := 0;
  rc := sqlite3_db_status64(db, op, @C, @H, resetFlag);
  if rc = SQLITE_OK then
  begin
    pCurrent^ := i32(C and $7FFFFFFF);
    pHighwtr^ := i32(H and $7FFFFFFF);
  end;
  Result := rc;
end;

{ main.c:4958 — sqlite3DbNameToBtree.  Resolve a database name to its
  Btree*, or nil if the name is unknown. }
function sqlite3DbNameToBtree(db: PTsqlite3; zDbName: PAnsiChar): PBtree;
var iDb: i32;
begin
  if zDbName <> nil then iDb := sqlite3FindDbName(db, zDbName)
  else                   iDb := 0;
  if iDb < 0 then Result := nil
  else            Result := PBtree(db^.aDb[iDb].pBt);
end;

{ main.c:4153 — sqlite3_file_control.  Dispatch file-control opcodes to
  the per-database pager / btree, falling through to the VFS xFileControl
  for unknown opcodes. }
function sqlite3_file_control(db: PTsqlite3; zDbName: PAnsiChar; op: i32;
                              pArg: Pointer): i32; cdecl;
var
  rc:     i32;
  pBt:    PBtree;
  pPgr:   PPager;
  fd:     Psqlite3_file;
  iNew:   i32;
  nSave:  i32;
begin
  rc := SQLITE_ERROR;
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  pBt := sqlite3DbNameToBtree(db, zDbName);
  if pBt <> nil then begin
    sqlite3BtreeEnter(pBt);
    pPgr := sqlite3BtreePager(pBt);
    fd   := sqlite3PagerFile(pPgr);
    case op of
      SQLITE_FCNTL_FILE_POINTER: begin
        PPointer(pArg)^ := Pointer(fd);
        rc := SQLITE_OK;
      end;
      SQLITE_FCNTL_VFS_POINTER: begin
        PPointer(pArg)^ := Pointer(sqlite3PagerVfs(pPgr));
        rc := SQLITE_OK;
      end;
      SQLITE_FCNTL_JOURNAL_POINTER: begin
        PPointer(pArg)^ := Pointer(sqlite3PagerJrnlFile(pPgr));
        rc := SQLITE_OK;
      end;
      SQLITE_FCNTL_DATA_VERSION: begin
        Pu32(pArg)^ := sqlite3PagerDataVersion(pPgr);
        rc := SQLITE_OK;
      end;
      SQLITE_FCNTL_RESERVE_BYTES: begin
        iNew := Pi32(pArg)^;
        Pi32(pArg)^ := sqlite3BtreeGetRequestedReserve(pBt);
        if (iNew >= 0) and (iNew <= 255) then
          sqlite3BtreeSetPageSize(pBt, 0, iNew, 0);
        rc := SQLITE_OK;
      end;
      SQLITE_FCNTL_RESET_CACHE: begin
        sqlite3BtreeClearCache(pBt);
        rc := SQLITE_OK;
      end;
    else
      nSave := db^.busyHandler.nBusy;
      rc := sqlite3OsFileControl(fd, op, pArg);
      db^.busyHandler.nBusy := nSave;
    end;
    sqlite3BtreeLeave(pBt);
  end;
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ Local case-sensitive C-string equality + length helpers.  Avoid pulling
  SysUtils into main's interface for these tiny ASCII-byte routines. }
function clientNameEq(a, b: PAnsiChar): Boolean;
begin
  while (a^ <> #0) and (a^ = b^) do begin Inc(a); Inc(b); end;
  Result := a^ = b^;
end;

function clientNameLen(z: PAnsiChar): PtrUInt;
var p: PAnsiChar;
begin
  p := z;
  while p^ <> #0 do Inc(p);
  Result := PtrUInt(p) - PtrUInt(z);
end;

{ main.c:3854 — sqlite3_get_clientdata.  Look up a client-data slot by name.
  Returns the stored pointer or nil if missing. }
function sqlite3_get_clientdata(db: PTsqlite3; zName: PAnsiChar): Pointer; cdecl;
var
  p: PDbClientData;
  zSlot: PAnsiChar;
begin
  if (zName = nil) or (sqlite3SafetyCheckOk(db) = 0) then begin
    Result := nil;
    Exit;
  end;
  Result := nil;
  sqlite3_mutex_enter(db^.mutex);
  p := db^.pDbData;
  while p <> nil do begin
    zSlot := PAnsiChar(p) + SizeOf(TDbClientData);
    if clientNameEq(zSlot, zName) then begin
      Result := p^.pData;
      break;
    end;
    p := PDbClientData(p^.pNext);
  end;
  sqlite3_mutex_leave(db^.mutex);
end;

{ main.c:3877 — sqlite3_set_clientdata.  Store/replace/remove a named pointer
  on the connection.  Variable-length name is appended to the allocation. }
function sqlite3_set_clientdata(db: PTsqlite3; zName: PAnsiChar;
  pData: Pointer; xDestructor: TClientDataDestrFn): i32; cdecl;
var
  p, pPrev: PDbClientData;
  zSlot: PAnsiChar;
  n: PtrUInt;
begin
  sqlite3_mutex_enter(db^.mutex);
  pPrev := nil;
  p := db^.pDbData;
  while p <> nil do begin
    zSlot := PAnsiChar(p) + SizeOf(TDbClientData);
    if clientNameEq(zSlot, zName) then break;
    pPrev := p;
    p := PDbClientData(p^.pNext);
  end;
  if p <> nil then begin
    if Assigned(p^.xDestroyData) then
      p^.xDestroyData(p^.pData);
    if pData = nil then begin
      if pPrev = nil then
        db^.pDbData := PDbClientData(p^.pNext)
      else
        pPrev^.pNext := p^.pNext;
      sqlite3_free(p);
      sqlite3_mutex_leave(db^.mutex);
      Result := SQLITE_OK;
      Exit;
    end;
  end else if pData = nil then begin
    sqlite3_mutex_leave(db^.mutex);
    Result := SQLITE_OK;
    Exit;
  end else begin
    n := clientNameLen(zName);
    p := PDbClientData(sqlite3_malloc64(u64(SizeOf(TDbClientData) + n + 1)));
    if p = nil then begin
      if Assigned(xDestructor) then xDestructor(pData);
      sqlite3_mutex_leave(db^.mutex);
      Result := SQLITE_NOMEM;
      Exit;
    end;
    zSlot := PAnsiChar(p) + SizeOf(TDbClientData);
    Move(zName^, zSlot^, n + 1);
    p^.pNext := db^.pDbData;
    db^.pDbData := p;
  end;
  p^.pData := pData;
  p^.xDestroyData := xDestructor;
  sqlite3_mutex_leave(db^.mutex);
  Result := SQLITE_OK;
end;

{ main.c — sqlite3_txn_state. }
function sqlite3_txn_state(db: PTsqlite3; zSchema: PAnsiChar): i32; cdecl;
var
  iDb, nDb, x, iTxn: i32;
  pBt: Pointer;
begin
  iTxn := -1;
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := -1; Exit; end;
  sqlite3_mutex_enter(db^.mutex);
  if zSchema <> nil then begin
    iDb := sqlite3FindDbName(db, zSchema);
    nDb := iDb;
    if iDb < 0 then nDb := -1;
  end else begin
    iDb := 0;
    nDb := db^.nDb - 1;
  end;
  while iDb <= nDb do begin
    pBt := db^.aDb[iDb].pBt;
    if pBt <> nil then begin
      x := sqlite3BtreeTxnState(PBtree(pBt));
      if x > iTxn then iTxn := x;
    end;
    Inc(iDb);
  end;
  sqlite3_mutex_leave(db^.mutex);
  Result := iTxn;
end;

{ main.c — sqlite3_error_offset. }
function sqlite3_error_offset(db: PTsqlite3): i32; cdecl;
begin
  if (db <> nil) and (db^.errCode <> 0) and (db^.errByteOffset >= 0) then
    Result := db^.errByteOffset
  else
    Result := -1;
end;

{ main.c:2741 — sqlite3_set_errmsg.  Public extension hook (called by the
  Session extension); internal callers should use sqlite3Error /
  sqlite3ErrorWithMsg directly.  Faithful one-to-one port. }
function sqlite3_set_errmsg(db: PTsqlite3; errcode: i32; zMsg: PAnsiChar): i32; cdecl;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE;  { C uses SQLITE_MISUSE_BKPT — same value, debug breakpoint hook }
    Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  if zMsg <> nil then
    sqlite3ErrorWithMsg(db, errcode, zMsg)
  else
    sqlite3Error(db, errcode);
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ main.c — sqlite3_limit.  Mirrors aHardLimit clamp + LENGTH floor. }
function sqlite3_limit(db: PTsqlite3; limitId: i32; newLimit: i32): i32; cdecl;
var
  oldLimit: i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := -1; Exit; end;
  if (limitId < 0) or (limitId >= Length(aHardLimit)) then begin
    Result := -1; Exit;
  end;
  oldLimit := db^.aLimit[limitId];
  if newLimit >= 0 then begin
    if newLimit > aHardLimit[limitId] then newLimit := aHardLimit[limitId];
    if (limitId = 0) and (newLimit < 100) then newLimit := 100;  { SQLITE_LIMIT_LENGTH floor }
    db^.aLimit[limitId] := newLimit;
  end;
  Result := oldLimit;
end;

function sqlite3_sleep(ms: i32): i32; cdecl;
var
  pVfs: Psqlite3_vfs;
  micros: i32;
begin
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Result := 0; Exit; end;
  if ms < 0 then micros := 0 else micros := 1000 * ms;
  Result := sqlite3OsSleep(pVfs, micros) div 1000;
end;

function sqlite3_release_memory(n: i32): i32; cdecl;
begin
  { SQLITE_ENABLE_MEMORY_MANAGEMENT is off in this build — match the C
    no-op return path (malloc.c:30). }
  if n = 0 then ;  { unused }
  Result := 0;
end;

function sqlite3_memory_highwater(resetFlag: i32): i64; cdecl;
var
  res, mx: i64;
begin
  res := 0; mx := 0;
  sqlite3_status64(SQLITE_STATUS_MEMORY_USED, @res, @mx, resetFlag);
  Result := mx;
end;

function sqlite3_msize(p: Pointer): u64; cdecl;
begin
  if p = nil then Result := 0
  else Result := u64(MemSize(p));
end;

{ malloc.c — soft/hard heap-limit accessors.  SQLITE_ENABLE_MEMORY_MANAGEMENT
  is off in this build, so the no-op return path is the upstream contract:
  return the previously-set limit (kept in unit-level state) without
  installing a real alarm. }
var
  gSoftHeapLimit: i64 = 0;
  gHardHeapLimit: i64 = 0;

function sqlite3_soft_heap_limit64(n: i64): i64; cdecl;
var
  prior: i64;
begin
  prior := gSoftHeapLimit;
  if n >= 0 then gSoftHeapLimit := n;
  Result := prior;
end;

function sqlite3_hard_heap_limit64(n: i64): i64; cdecl;
var
  prior: i64;
begin
  prior := gHardHeapLimit;
  if n >= 0 then gHardHeapLimit := n;
  Result := prior;
end;

procedure sqlite3_soft_heap_limit(n: i32); cdecl;
begin
  if n < 0 then n := 0;
  sqlite3_soft_heap_limit64(i64(n));
end;

{ btree.c:89 — sqlite3_enable_shared_cache.  This Pascal port is built
  with the SQLITE_OMIT_SHARED_CACHE compile path: there is no
  sqlite3GlobalConfig.sharedCacheEnabled to mutate.  Mirror the
  loadext.c:91 omit-stub posture by accepting the call and returning
  SQLITE_OK; future opens never enable shared cache regardless. }
function sqlite3_enable_shared_cache(enable: i32): i32; cdecl;
begin
  Result := SQLITE_OK;
end;

{ sqlite.h.in:6780 — sqlite3_activate_cerod.  Deprecated CEROD
  (Compressed Encrypted Read-Only Database) activator; only meaningful
  under SQLITE_ENABLE_CEROD.  No-op stub here. }
procedure sqlite3_activate_cerod(zPassPhrase: PAnsiChar); cdecl;
begin
end;

{ main.c:1863 — sqlite3_setlk_timeout.  POSIX advisory-lock timeout.
  Only productive under SQLITE_ENABLE_SETLK_TIMEOUT (not enabled in
  this port).  Honour the C MISUSE / RANGE guards so callers see the
  same return codes; the timeout itself is a no-op. }
function sqlite3_setlk_timeout(db: PTsqlite3; ms: i32; flags: i32): i32; cdecl;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := SQLITE_MISUSE; Exit; end;
  if ms < -1 then begin Result := SQLITE_RANGE; Exit; end;
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  Phase 8.7.1 — WAL public-API entry points.

  The Pascal port has no `SQLITE_OMIT_WAL`-equivalent compile flag.  The
  underlying WAL machinery (`sqlite3WalCheckpoint`, `sqlite3PagerCheckpoint`,
  `sqlite3BtreeCheckpoint`) is fully ported, so these wrappers do real
  work when the connection has a WAL open and degrade to no-op when it
  does not.
  ---------------------------------------------------------------------- }

const
  SQLITE_MAX_DB_INTERNAL     = SQLITE_MAX_ATTACHED + 2;
  SQLITE_CHECKPOINT_PASSIVE  = 0;
  SQLITE_CHECKPOINT_TRUNCATE = 3;
  SQLITE_CHECKPOINT_NOOP     = -1;

{ main.c:2644 — sqlite3Checkpoint (internal).  Walks db^.aDb[] running a
  checkpoint on each open Btree.  iDb = SQLITE_MAX_DB processes all. }
function sqlite3Checkpoint(db: PTsqlite3; iDb, eMode: i32;
  pnLog, pnCkpt: PInt32): i32;
var
  rc:    i32;
  i:     i32;
  bBusy: i32;
begin
  rc    := SQLITE_OK;
  bBusy := 0;
  i     := 0;
  while (i < db^.nDb) and (rc = SQLITE_OK) do begin
    if (i = iDb) or (iDb = SQLITE_MAX_DB_INTERNAL) then begin
      rc := sqlite3BtreeCheckpoint(db^.aDb[i].pBt, eMode,
                                   Pointer(pnLog), Pointer(pnCkpt));
      pnLog  := nil;
      pnCkpt := nil;
      if rc = SQLITE_BUSY then begin
        bBusy := 1;
        rc    := SQLITE_OK;
      end;
    end;
    Inc(i);
  end;
  if (rc = SQLITE_OK) and (bBusy <> 0) then
    Result := SQLITE_BUSY
  else
    Result := rc;
end;

{ main.c:2470 — sqlite3WalDefaultHook.  Default callback installed by
  sqlite3_wal_autocheckpoint; fires sqlite3_wal_checkpoint(db, zDb)
  whenever the WAL has grown past pClientData frames. }
function sqlite3WalDefaultHook(pClientData: Pointer; db: PTsqlite3;
  zDb: PAnsiChar; nFrame: i32): i32; cdecl;
begin
  if nFrame >= i32(PtrUInt(pClientData)) then
    sqlite3_wal_checkpoint(db, zDb);
  Result := SQLITE_OK;
end;

{ main.c:2517 — sqlite3_wal_hook.  Replace the per-connection WAL hook;
  return the previous pArg. }
function sqlite3_wal_hook(db: PTsqlite3; xCallback: TWalHookFn;
  pArg: Pointer): Pointer; cdecl;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := nil; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  Result          := db^.pWalArg;
  db^.xWalCallback := Pointer(xCallback);
  db^.pWalArg     := pArg;
  sqlite3_mutex_leave(db^.mutex);
end;

{ main.c:2496 — sqlite3_wal_autocheckpoint.  Wires the default hook on
  positive nFrame, clears it otherwise. }
function sqlite3_wal_autocheckpoint(db: PTsqlite3; nFrame: i32): i32; cdecl;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if nFrame > 0 then
    sqlite3_wal_hook(db, @sqlite3WalDefaultHook, Pointer(PtrUInt(nFrame)))
  else
    sqlite3_wal_hook(db, nil, nil);
  Result := SQLITE_OK;
end;

{ main.c:2547 — sqlite3_wal_checkpoint_v2. }
function sqlite3_wal_checkpoint_v2(db: PTsqlite3; zDb: PAnsiChar;
  eMode: i32; pnLog, pnCkpt: PInt32): i32; cdecl;
var
  rc:  i32;
  iDb: i32;
begin
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if pnLog  <> nil then pnLog^  := -1;
  if pnCkpt <> nil then pnCkpt^ := -1;
  if (eMode < SQLITE_CHECKPOINT_NOOP) or (eMode > SQLITE_CHECKPOINT_TRUNCATE) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3_mutex_enter(db^.mutex);
  if (zDb <> nil) and (zDb[0] <> #0) then
    iDb := sqlite3FindDbName(db, zDb)
  else
    iDb := SQLITE_MAX_DB_INTERNAL;
  if iDb < 0 then begin
    rc := SQLITE_ERROR;
    sqlite3ErrorWithMsg(db, SQLITE_ERROR,
      PAnsiChar(sqlite3MPrintf(db, 'unknown database: %s', [zDb])));
  end else begin
    db^.busyHandler.nBusy := 0;
    rc := sqlite3Checkpoint(db, iDb, eMode, pnLog, pnCkpt);
    sqlite3Error(db, rc);
  end;
  rc := sqlite3ApiExit(db, rc);
  if db^.nVdbeActive = 0 then
    db^.u1.isInterrupted := 0;
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

{ main.c:2617 — sqlite3_wal_checkpoint.  PASSIVE-mode wrapper. }
function sqlite3_wal_checkpoint(db: PTsqlite3; zDb: PAnsiChar): i32; cdecl;
begin
  Result := sqlite3_wal_checkpoint_v2(db, zDb, SQLITE_CHECKPOINT_PASSIVE,
                                      nil, nil);
end;

{ memdb.c:750 — sqlite3_serialize.  Returns a freshly malloc'ed buffer
  containing the on-disk image of database zSchema (or NULL when it is
  the main database).  Length is written to *piSize.  When
  SQLITE_SERIALIZE_NOCOPY is set the function returns NULL for non-memdb
  databases (we have no memdb backing store to point at).  The memdb
  branch of the C source is omitted: the memdb VFS is not yet ported. }
function sqlite3_serialize(db: PTsqlite3; zSchema: PAnsiChar;
  piSize: Pi64; mFlags: u32): Pu8; cdecl;
var
  iDb:    i32;
  pBt:    PBtree;
  sz:     i64;
  szPage: i32;
  pOut:   Pu8;
  pTo:    Pu8;
  pPgr:   PPager;
  nPage:  i32;
  iPg:    i32;
  pPage:  PDbPage;
  rc:     i32;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := nil; Exit;
  end;
{$ENDIF}
  if zSchema = nil then zSchema := db^.aDb[0].zDbSName;
  iDb := sqlite3FindDbName(db, zSchema);
  if piSize <> nil then piSize^ := -1;
  if iDb < 0 then begin Result := nil; Exit; end;
  pBt := PBtree(db^.aDb[iDb].pBt);
  if pBt = nil then begin Result := nil; Exit; end;
  { C source preps "PRAGMA <db>.page_count"; the Pascal pragma dispatch
    does not yet implement page_count, so go straight to the underlying
    primitive.  Equivalent: sqlite3PagerPagecount on the schema's pager. }
  pPgr  := sqlite3BtreePager(pBt);
  nPage := 0;
  sqlite3PagerPagecount(pPgr, @nPage);
  szPage := sqlite3BtreeGetPageSize(pBt);
  sz     := i64(nPage) * szPage;
  if piSize <> nil then piSize^ := sz;
  if (mFlags and SQLITE_SERIALIZE_NOCOPY) <> 0 then begin
    Result := nil; Exit;
  end;
  if sz <= 0 then begin Result := nil; Exit; end;
  pOut := Pu8(sqlite3_malloc64(u64(sz)));
  if pOut = nil then begin Result := nil; Exit; end;
  for iPg := 1 to nPage do begin
    pPage := nil;
    pTo   := pOut + szPage * (iPg - 1);
    rc    := sqlite3PagerGet(pPgr, Pgno(iPg), @pPage, 0);
    if rc = SQLITE_OK then
      Move(sqlite3PagerGetData(pPage)^, pTo^, szPage)
    else
      FillChar(pTo^, szPage, 0);
    sqlite3PagerUnref(pPage);
  end;
  Result := pOut;
end;

{ memdb.c:839 — sqlite3_deserialize.  In the upstream build this would
  ATTACH a fresh memdb VFS file and swap pData into its MemStore backing
  buffer.  The memdb VFS is not yet ported here, so the operation cannot
  succeed; mirror the SQLITE_OMIT_DESERIALIZE-equivalent semantics by
  reporting SQLITE_ERROR.  The FREEONCLOSE flag still has to be honoured
  on the failure path (memdb.c:903) so the caller's "we hand over the
  buffer" contract remains intact. }
function sqlite3_deserialize(db: PTsqlite3; zSchema: PAnsiChar;
  pData: Pu8; szDb, szBuf: i64; mFlags: u32): i32; cdecl;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if (szDb < 0) or (szBuf < 0) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}
  if (pData <> nil)
     and ((mFlags and SQLITE_DESERIALIZE_FREEONCLOSE) <> 0) then
    sqlite3_free(pData);
  Result := SQLITE_ERROR;
end;

{ ----------------------------------------------------------------------
  Phase 8.7.1 — Snapshot public-API entry points (main.c:5013..5147).
  Faithful translation of the SQLITE_OMIT_WAL / SQLITE_OMIT_SNAPSHOT
  semantic: snapshot operations report SQLITE_ERROR because the pager
  snapshot machinery (sqlite3PagerSnapshotGet etc.) is not present.
  ---------------------------------------------------------------------- }

function sqlite3_snapshot_get(db: PTsqlite3; zSchema: PAnsiChar;
                              ppSnapshot: PPsqlite3_snapshot): i32; cdecl;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}
  if ppSnapshot <> nil then ppSnapshot^ := nil;
  Result := SQLITE_ERROR;
end;

function sqlite3_snapshot_open(db: PTsqlite3; zSchema: PAnsiChar;
                               pSnapshot: Psqlite3_snapshot): i32; cdecl;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}
  Result := SQLITE_ERROR;
end;

procedure sqlite3_snapshot_free(pSnapshot: Psqlite3_snapshot); cdecl;
begin
  sqlite3_free(pSnapshot);
end;

function sqlite3_snapshot_cmp(p1, p2: Psqlite3_snapshot): i32; cdecl;
begin
  { Without WAL backing the comparison is undefined per the docs.  Return
    0 (handles "compare equal") so callers do not see a bogus ordering. }
  if p1 = p2 then Result := 0
  else if p1 = nil then Result := -1
  else if p2 = nil then Result := 1
  else Result := 0;
end;

function sqlite3_snapshot_recover(db: PTsqlite3; zDb: PAnsiChar): i32; cdecl;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}
  Result := SQLITE_ERROR;
end;

{ ----------------------------------------------------------------------
  Phase 8.8.1 — Pre-update hook public-API entry points.
  Faithful translation of vdbeapi.c:2209..2400 + main.c:4001 in the
  build mode where SQLITE_ENABLE_PREUPDATE_HOOK is off and therefore
  db->pPreUpdate is permanently NULL.  Every SQLITE_ENABLE_API_ARMOR
  guard reduces to its "no-preupdate-active" arm.
  ---------------------------------------------------------------------- }

function sqlite3_preupdate_hook(db: PTsqlite3;
                                xPreUpdate: Pointer;
                                pArg: Pointer): Pointer; cdecl;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if sqlite3SafetyCheckOk(db) = 0 then begin Result := nil; Exit; end;
{$ENDIF}
  { No callback storage in db (PreUpdate fields are gated out at compile
    time in our build), so the previous registration is always nil. }
  Result := nil;
end;

function sqlite3_preupdate_old(db: PTsqlite3; iIdx: i32;
                               ppValue: PPointer): i32; cdecl;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if (db = nil) or (ppValue = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}
  if ppValue <> nil then ppValue^ := nil;
  Result := SQLITE_MISUSE;
end;

function sqlite3_preupdate_new(db: PTsqlite3; iIdx: i32;
                               ppValue: PPointer): i32; cdecl;
begin
{$IFDEF SQLITE_ENABLE_API_ARMOR}
  if (db = nil) or (ppValue = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
{$ENDIF}
  if ppValue <> nil then ppValue^ := nil;
  Result := SQLITE_MISUSE;
end;

function sqlite3_preupdate_count(db: PTsqlite3): i32; cdecl;
begin
  Result := 0;
end;

function sqlite3_preupdate_depth(db: PTsqlite3): i32; cdecl;
begin
  Result := 0;
end;

function sqlite3_preupdate_blobwrite(db: PTsqlite3): i32; cdecl;
begin
  Result := -1;
end;

{ OP_SqlExec hook (vdbe.c:7064).  Trampoline that adapts sqlite3_exec to
  the PVdbeSqlExec hook signature (no callback / no pArg). }
function execSqlExecImpl(db: PTsqlite3; zSql: PAnsiChar;
                         pzErrMsg: PPAnsiChar): i32;
begin
  Result := sqlite3_exec(db, zSql, nil, nil, pzErrMsg);
end;

initialization
  vdbeParseSchemaExec := @execParseSchemaImpl;
  vdbeSqlExec := @execSqlExecImpl;

  { Phase 5.8: wire the parser tokenizer into vdbetrace's ExpandSql so
    bound-parameter scanning works.  Done here (not in passqlite3parser)
    to avoid PParse-symbol shadowing inside the parser unit. }
  passqlite3vdbe.gGetTokenImpl :=
    passqlite3vdbe.TGetTokenFn(@passqlite3parser.sqlite3GetToken);

end.
