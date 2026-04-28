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
unit csqlite3;

{
  External cdecl declarations of the C reference SQLite library (libsqlite3.so).
  All Pascal-side names carry the csq_ prefix to avoid collision with the Pascal
  port symbols defined in passqlite3.pas.

  Convention mirrors cbz_ in pas-bzip2 and ccm_ in pas-core-math.

  Used by test programs only.  The Pascal port itself MUST NEVER link against
  libsqlite3.so — that would make differential testing compare a thing with itself.
}

interface

uses passqlite3types;

const
  LIBSQLITE3 = 'sqlite3';

// ---------------------------------------------------------------------------
// Opaque pointer types (matching the C opaque typedefs)
// ---------------------------------------------------------------------------

type
  { Opaque database connection handle — sqlite3* }
  Pcsq_db   = Pointer;
  PPcsq_db  = ^Pcsq_db;

  { Opaque prepared statement handle — sqlite3_stmt* }
  Pcsq_stmt  = Pointer;
  PPcsq_stmt = ^Pcsq_stmt;

  { Opaque value handle — sqlite3_value* }
  Pcsq_value = Pointer;

  { Opaque context handle — sqlite3_context* }
  Pcsq_ctx   = Pointer;

  { Callback type for sqlite3_exec }
  Tcsq_exec_callback = function(pArg: Pointer; argc: Int32;
      argv: PPChar; colNames: PPChar): Int32; cdecl;

// ---------------------------------------------------------------------------
// Library metadata
// ---------------------------------------------------------------------------

function csq_libversion: PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_libversion';

function csq_libversion_number: Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_libversion_number';

function csq_sourceid: PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_sourceid';

// ---------------------------------------------------------------------------
// Initialisation / shutdown
// ---------------------------------------------------------------------------

function csq_initialize: Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_initialize';

function csq_shutdown: Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_shutdown';

// ---------------------------------------------------------------------------
// Database connection open / close
// ---------------------------------------------------------------------------

function csq_open(zFilename: PChar; out ppDb: Pcsq_db): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_open';

function csq_open_v2(zFilename: PChar; out ppDb: Pcsq_db;
    flags: Int32; zVfs: PChar): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_open_v2';

function csq_close(db: Pcsq_db): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_close';

function csq_close_v2(db: Pcsq_db): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_close_v2';

// ---------------------------------------------------------------------------
// One-shot SQL execution
// ---------------------------------------------------------------------------

function csq_exec(db: Pcsq_db; zSql: PChar;
    callback: Tcsq_exec_callback; pArg: Pointer;
    out pzErrMsg: PChar): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_exec';

// ---------------------------------------------------------------------------
// Prepared statement lifecycle
// ---------------------------------------------------------------------------

function csq_prepare_v2(db: Pcsq_db; zSql: PChar; nByte: Int32;
    out ppStmt: Pcsq_stmt; out pzTail: PChar): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_prepare_v2';

function csq_prepare_v3(db: Pcsq_db; zSql: PChar; nByte: Int32;
    prepFlags: u32; out ppStmt: Pcsq_stmt; out pzTail: PChar): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_prepare_v3';

function csq_step(pStmt: Pcsq_stmt): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_step';

function csq_reset(pStmt: Pcsq_stmt): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_reset';

function csq_finalize(pStmt: Pcsq_stmt): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_finalize';

// ---------------------------------------------------------------------------
// Bind parameters
// ---------------------------------------------------------------------------

function csq_bind_blob(pStmt: Pcsq_stmt; i: Int32;
    zData: Pointer; nData: Int32; xDel: Pointer): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_blob';

function csq_bind_blob64(pStmt: Pcsq_stmt; i: Int32;
    zData: Pointer; nData: u64; xDel: Pointer): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_blob64';

function csq_bind_double(pStmt: Pcsq_stmt; i: Int32; rValue: Double): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_double';

function csq_bind_int(pStmt: Pcsq_stmt; i: Int32; iValue: Int32): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_int';

function csq_bind_int64(pStmt: Pcsq_stmt; i: Int32; iValue: i64): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_int64';

function csq_bind_null(pStmt: Pcsq_stmt; i: Int32): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_null';

function csq_bind_text(pStmt: Pcsq_stmt; i: Int32;
    zData: PChar; nData: Int32; xDel: Pointer): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_text';

function csq_bind_text64(pStmt: Pcsq_stmt; i: Int32;
    zData: PChar; nData: u64; xDel: Pointer; enc: u8): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_text64';

function csq_bind_zeroblob(pStmt: Pcsq_stmt; i: Int32; n: Int32): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_zeroblob';

function csq_bind_parameter_count(pStmt: Pcsq_stmt): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_parameter_count';

function csq_bind_parameter_index(pStmt: Pcsq_stmt; zName: PChar): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_parameter_index';

function csq_bind_parameter_name(pStmt: Pcsq_stmt; i: Int32): PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_bind_parameter_name';

// ---------------------------------------------------------------------------
// Column results
// ---------------------------------------------------------------------------

function csq_column_count(pStmt: Pcsq_stmt): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_count';

function csq_column_name(pStmt: Pcsq_stmt; N: Int32): PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_name';

function csq_column_decltype(pStmt: Pcsq_stmt; N: Int32): PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_decltype';

function csq_column_type(pStmt: Pcsq_stmt; i: Int32): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_type';

function csq_column_int(pStmt: Pcsq_stmt; i: Int32): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_int';

function csq_column_int64(pStmt: Pcsq_stmt; i: Int32): i64;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_int64';

function csq_column_double(pStmt: Pcsq_stmt; i: Int32): Double;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_double';

function csq_column_text(pStmt: Pcsq_stmt; i: Int32): PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_text';

function csq_column_blob(pStmt: Pcsq_stmt; i: Int32): Pointer;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_blob';

function csq_column_bytes(pStmt: Pcsq_stmt; i: Int32): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_bytes';

function csq_column_value(pStmt: Pcsq_stmt; i: Int32): Pcsq_value;
    cdecl; external LIBSQLITE3 name 'sqlite3_column_value';

// ---------------------------------------------------------------------------
// Error reporting
// ---------------------------------------------------------------------------

function csq_errmsg(db: Pcsq_db): PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_errmsg';

function csq_errcode(db: Pcsq_db): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_errcode';

function csq_extended_errcode(db: Pcsq_db): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_extended_errcode';

function csq_errstr(rc: Int32): PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_errstr';

// ---------------------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------------------

function csq_malloc(n: Int32): Pointer;
    cdecl; external LIBSQLITE3 name 'sqlite3_malloc';

function csq_malloc64(n: u64): Pointer;
    cdecl; external LIBSQLITE3 name 'sqlite3_malloc64';

function csq_realloc(p: Pointer; n: Int32): Pointer;
    cdecl; external LIBSQLITE3 name 'sqlite3_realloc';

function csq_realloc64(p: Pointer; n: u64): Pointer;
    cdecl; external LIBSQLITE3 name 'sqlite3_realloc64';

procedure csq_free(p: Pointer);
    cdecl; external LIBSQLITE3 name 'sqlite3_free';

function csq_memory_used: i64;
    cdecl; external LIBSQLITE3 name 'sqlite3_memory_used';

function csq_memory_highwater(resetFlag: Int32): i64;
    cdecl; external LIBSQLITE3 name 'sqlite3_memory_highwater';

// ---------------------------------------------------------------------------
// printf helpers
// ---------------------------------------------------------------------------

function csq_mprintf(fmt: PChar): PChar; varargs;
    cdecl; external LIBSQLITE3 name 'sqlite3_mprintf';

function csq_snprintf(n: Int32; zBuf: PChar; fmt: PChar): PChar; varargs;
    cdecl; external LIBSQLITE3 name 'sqlite3_snprintf';

// ---------------------------------------------------------------------------
// Connection status / metadata
// ---------------------------------------------------------------------------

function csq_changes(db: Pcsq_db): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_changes';

function csq_total_changes(db: Pcsq_db): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_total_changes';

function csq_last_insert_rowid(db: Pcsq_db): i64;
    cdecl; external LIBSQLITE3 name 'sqlite3_last_insert_rowid';

function csq_db_filename(db: Pcsq_db; zDbName: PChar): PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_db_filename';

function csq_db_readonly(db: Pcsq_db; zDbName: PChar): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_db_readonly';

// ---------------------------------------------------------------------------
// sqlite3_complete
// ---------------------------------------------------------------------------

function csq_complete(zSql: PChar): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_complete';

// ---------------------------------------------------------------------------
// Tracing
// ---------------------------------------------------------------------------

function csq_trace_v2(db: Pcsq_db; uMask: u32;
    xCallback: Pointer; pCtx: Pointer): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_trace_v2';

// ---------------------------------------------------------------------------
// Randomness
// ---------------------------------------------------------------------------

procedure csq_randomness(N: Int32; P: Pointer);
    cdecl; external LIBSQLITE3 name 'sqlite3_randomness';

// ---------------------------------------------------------------------------
// Extended result code control
// ---------------------------------------------------------------------------

function csq_extended_result_codes(db: Pcsq_db; onoff: Int32): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_extended_result_codes';

implementation

end.
