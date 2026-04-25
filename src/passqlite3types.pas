{$I passqlite3.inc}
unit passqlite3types;

{
  Primitive type aliases and compile-time constants for the Pascal port of
  SQLite 3.53.0.

  Covers:
    - C-style integer aliases (u8, u16, u32, u64, i8, i16, i32, i64)
    - sqlite3_int64 / sqlite3_uint64 public aliases
    - All primary result codes (from sqlite3.h / sqlite.h.in)
    - All extended result codes
    - SQLITE_OPEN_* flag constants
    - sqliteLimit.h compile-time limits
    - SQLITE_VERSION constants

  Rule: name every type exactly as the C source does so diffs read 1:1.
}

interface

// ---------------------------------------------------------------------------
// Primitive type aliases
// ---------------------------------------------------------------------------

type
  u8   = Byte;
  u16  = UInt16;
  u32  = UInt32;
  u64  = UInt64;
  i8   = Int8;
  i16  = Int16;
  i32  = Int32;
  i64  = Int64;

  Pu8  = ^u8;
  Pu16 = ^u16;
  Pu32 = ^u32;
  Pi32 = ^i32;
  Pi64 = ^i64;

  { SQLite page number — always an unsigned 32-bit value. }
  Pgno  = u32;
  PPgno = ^Pgno;

  { Public API integer types (sqlite3.h names). }
  sqlite3_int64  = i64;
  sqlite3_uint64 = u64;

// ---------------------------------------------------------------------------
// Version constants  (pinned to upstream 3.53.0)
// ---------------------------------------------------------------------------

const
  SQLITE_VERSION        = '3.53.0';
  SQLITE_VERSION_NUMBER = 3053000;
  SQLITE_SOURCE_ID      = '3.53.0 — see ../sqlite3/manifest.uuid';

// ---------------------------------------------------------------------------
// Primary result codes  (sqlite3.h §1)
// ---------------------------------------------------------------------------

const
  SQLITE_OK           = 0;   { Successful result }
  SQLITE_ERROR        = 1;   { Generic error }
  SQLITE_INTERNAL     = 2;   { Internal logic error in SQLite }
  SQLITE_PERM         = 3;   { Access permission denied }
  SQLITE_ABORT        = 4;   { Callback routine requested an abort }
  SQLITE_BUSY         = 5;   { The database file is locked }
  SQLITE_LOCKED       = 6;   { A table in the database is locked }
  SQLITE_NOMEM        = 7;   { A malloc() failed }
  SQLITE_READONLY     = 8;   { Attempt to write a readonly database }
  SQLITE_INTERRUPT    = 9;   { Operation terminated by sqlite3_interrupt() }
  SQLITE_IOERR        = 10;  { Some kind of disk I/O error occurred }
  SQLITE_CORRUPT      = 11;  { The database disk image is malformed }
  SQLITE_NOTFOUND     = 12;  { Unknown opcode in sqlite3_file_control() }
  SQLITE_FULL         = 13;  { Insertion failed because database is full }
  SQLITE_CANTOPEN     = 14;  { Unable to open the database file }
  SQLITE_PROTOCOL     = 15;  { Database lock protocol error }
  SQLITE_EMPTY        = 16;  { Internal use only }
  SQLITE_SCHEMA       = 17;  { The database schema changed }
  SQLITE_TOOBIG       = 18;  { String or BLOB exceeds size limit }
  SQLITE_CONSTRAINT   = 19;  { Abort due to constraint violation }
  SQLITE_MISMATCH     = 20;  { Data type mismatch }
  SQLITE_MISUSE       = 21;  { Library used incorrectly }
  SQLITE_NOLFS        = 22;  { Uses OS features not supported on host }
  SQLITE_AUTH         = 23;  { Authorization denied }
  SQLITE_FORMAT       = 24;  { Not used }
  SQLITE_RANGE        = 25;  { 2nd parameter to sqlite3_bind out of range }
  SQLITE_NOTADB       = 26;  { File opened that is not a database file }
  SQLITE_NOTICE       = 27;  { Notifications from sqlite3_log() }
  SQLITE_WARNING      = 28;  { Warnings from sqlite3_log() }
  SQLITE_ROW          = 100; { sqlite3_step() has another row ready }
  SQLITE_DONE         = 101; { sqlite3_step() has finished executing }

  { Authorizer return codes (sqlite3.h §3.7) }
  SQLITE_DENY         = 1;   { Abort the SQL statement with an error }
  SQLITE_IGNORE       = 2;   { Don't allow access, but don't generate error }

// ---------------------------------------------------------------------------
// Extended result codes  (sqlite3.h §2)
// ---------------------------------------------------------------------------

const
  { SQLITE_ERROR extensions }
  SQLITE_ERROR_MISSING_COLLSEQ  = SQLITE_ERROR or (1 shl 8);
  SQLITE_ERROR_RETRY            = SQLITE_ERROR or (2 shl 8);
  SQLITE_ERROR_SNAPSHOT         = SQLITE_ERROR or (3 shl 8);
  SQLITE_ERROR_RESERVESIZE      = SQLITE_ERROR or (4 shl 8);
  SQLITE_ERROR_KEY              = SQLITE_ERROR or (5 shl 8);
  SQLITE_ERROR_UNABLE           = SQLITE_ERROR or (6 shl 8);

  { SQLITE_IOERR extensions }
  SQLITE_IOERR_READ              = SQLITE_IOERR or (1 shl 8);
  SQLITE_IOERR_SHORT_READ        = SQLITE_IOERR or (2 shl 8);
  SQLITE_IOERR_WRITE             = SQLITE_IOERR or (3 shl 8);
  SQLITE_IOERR_FSYNC             = SQLITE_IOERR or (4 shl 8);
  SQLITE_IOERR_DIR_FSYNC         = SQLITE_IOERR or (5 shl 8);
  SQLITE_IOERR_TRUNCATE          = SQLITE_IOERR or (6 shl 8);
  SQLITE_IOERR_FSTAT             = SQLITE_IOERR or (7 shl 8);
  SQLITE_IOERR_UNLOCK            = SQLITE_IOERR or (8 shl 8);
  SQLITE_IOERR_RDLOCK            = SQLITE_IOERR or (9 shl 8);
  SQLITE_IOERR_DELETE            = SQLITE_IOERR or (10 shl 8);
  SQLITE_IOERR_BLOCKED           = SQLITE_IOERR or (11 shl 8);
  SQLITE_IOERR_NOMEM             = SQLITE_IOERR or (12 shl 8);
  SQLITE_IOERR_ACCESS            = SQLITE_IOERR or (13 shl 8);
  SQLITE_IOERR_CHECKRESERVEDLOCK = SQLITE_IOERR or (14 shl 8);
  SQLITE_IOERR_LOCK              = SQLITE_IOERR or (15 shl 8);
  SQLITE_IOERR_CLOSE             = SQLITE_IOERR or (16 shl 8);
  SQLITE_IOERR_DIR_CLOSE         = SQLITE_IOERR or (17 shl 8);
  SQLITE_IOERR_SHMOPEN           = SQLITE_IOERR or (18 shl 8);
  SQLITE_IOERR_SHMSIZE           = SQLITE_IOERR or (19 shl 8);
  SQLITE_IOERR_SHMLOCK           = SQLITE_IOERR or (20 shl 8);
  SQLITE_IOERR_SHMMAP            = SQLITE_IOERR or (21 shl 8);
  SQLITE_IOERR_SEEK              = SQLITE_IOERR or (22 shl 8);
  SQLITE_IOERR_DELETE_NOENT      = SQLITE_IOERR or (23 shl 8);
  SQLITE_IOERR_MMAP              = SQLITE_IOERR or (24 shl 8);
  SQLITE_IOERR_GETTEMPPATH       = SQLITE_IOERR or (25 shl 8);
  SQLITE_IOERR_CONVPATH          = SQLITE_IOERR or (26 shl 8);
  SQLITE_IOERR_VNODE             = SQLITE_IOERR or (27 shl 8);
  SQLITE_IOERR_AUTH              = SQLITE_IOERR or (28 shl 8);
  SQLITE_IOERR_BEGIN_ATOMIC      = SQLITE_IOERR or (29 shl 8);
  SQLITE_IOERR_COMMIT_ATOMIC     = SQLITE_IOERR or (30 shl 8);
  SQLITE_IOERR_ROLLBACK_ATOMIC   = SQLITE_IOERR or (31 shl 8);
  SQLITE_IOERR_DATA              = SQLITE_IOERR or (32 shl 8);
  SQLITE_IOERR_CORRUPTFS         = SQLITE_IOERR or (33 shl 8);
  SQLITE_IOERR_IN_PAGE           = SQLITE_IOERR or (34 shl 8);
  SQLITE_IOERR_BADKEY            = SQLITE_IOERR or (35 shl 8);
  SQLITE_IOERR_CODEC             = SQLITE_IOERR or (36 shl 8);

  { SQLITE_LOCKED extensions }
  SQLITE_LOCKED_SHAREDCACHE = SQLITE_LOCKED or (1 shl 8);
  SQLITE_LOCKED_VTAB        = SQLITE_LOCKED or (2 shl 8);

  { SQLITE_BUSY extensions }
  SQLITE_BUSY_RECOVERY = SQLITE_BUSY or (1 shl 8);
  SQLITE_BUSY_SNAPSHOT = SQLITE_BUSY or (2 shl 8);
  SQLITE_BUSY_TIMEOUT  = SQLITE_BUSY or (3 shl 8);

  { _BKPT aliases — same value; used by internal C code for debugging breakpoints }
  SQLITE_NOMEM_BKPT    = SQLITE_NOMEM;
  SQLITE_CANTOPEN_BKPT = SQLITE_CANTOPEN;
  SQLITE_CORRUPT_BKPT  = SQLITE_CORRUPT;

  { SQLITE_CANTOPEN extensions }
  SQLITE_CANTOPEN_NOTEMPDIR  = SQLITE_CANTOPEN or (1 shl 8);
  SQLITE_CANTOPEN_ISDIR      = SQLITE_CANTOPEN or (2 shl 8);
  SQLITE_CANTOPEN_FULLPATH   = SQLITE_CANTOPEN or (3 shl 8);
  SQLITE_CANTOPEN_CONVPATH   = SQLITE_CANTOPEN or (4 shl 8);
  SQLITE_CANTOPEN_DIRTYWAL   = SQLITE_CANTOPEN or (5 shl 8); { Not Used }
  SQLITE_CANTOPEN_SYMLINK    = SQLITE_CANTOPEN or (6 shl 8);

  { SQLITE_CORRUPT extensions }
  SQLITE_CORRUPT_VTAB     = SQLITE_CORRUPT or (1 shl 8);
  SQLITE_CORRUPT_SEQUENCE = SQLITE_CORRUPT or (2 shl 8);
  SQLITE_CORRUPT_INDEX    = SQLITE_CORRUPT or (3 shl 8);

  { SQLITE_READONLY extensions }
  SQLITE_READONLY_RECOVERY  = SQLITE_READONLY or (1 shl 8);
  SQLITE_READONLY_CANTLOCK  = SQLITE_READONLY or (2 shl 8);
  SQLITE_READONLY_ROLLBACK  = SQLITE_READONLY or (3 shl 8);
  SQLITE_READONLY_DBMOVED   = SQLITE_READONLY or (4 shl 8);
  SQLITE_READONLY_CANTINIT  = SQLITE_READONLY or (5 shl 8);
  SQLITE_READONLY_DIRECTORY = SQLITE_READONLY or (6 shl 8);

  { SQLITE_ABORT extensions }
  SQLITE_ABORT_ROLLBACK = SQLITE_ABORT or (2 shl 8);

  { SQLITE_CONSTRAINT extensions }
  SQLITE_CONSTRAINT_CHECK       = SQLITE_CONSTRAINT or (1 shl 8);
  SQLITE_CONSTRAINT_COMMITHOOK  = SQLITE_CONSTRAINT or (2 shl 8);
  SQLITE_CONSTRAINT_FOREIGNKEY  = SQLITE_CONSTRAINT or (3 shl 8);
  SQLITE_CONSTRAINT_FUNCTION    = SQLITE_CONSTRAINT or (4 shl 8);
  SQLITE_CONSTRAINT_NOTNULL     = SQLITE_CONSTRAINT or (5 shl 8);
  SQLITE_CONSTRAINT_PRIMARYKEY  = SQLITE_CONSTRAINT or (6 shl 8);
  SQLITE_CONSTRAINT_TRIGGER     = SQLITE_CONSTRAINT or (7 shl 8);
  SQLITE_CONSTRAINT_UNIQUE      = SQLITE_CONSTRAINT or (8 shl 8);
  SQLITE_CONSTRAINT_VTAB        = SQLITE_CONSTRAINT or (9 shl 8);
  SQLITE_CONSTRAINT_ROWID       = SQLITE_CONSTRAINT or (10 shl 8);
  SQLITE_CONSTRAINT_PINNED      = SQLITE_CONSTRAINT or (11 shl 8);
  SQLITE_CONSTRAINT_DATATYPE    = SQLITE_CONSTRAINT or (12 shl 8);

  { SQLITE_NOTICE extensions }
  SQLITE_NOTICE_RECOVER_WAL      = SQLITE_NOTICE or (1 shl 8);
  SQLITE_NOTICE_RECOVER_ROLLBACK = SQLITE_NOTICE or (2 shl 8);
  SQLITE_NOTICE_RBU              = SQLITE_NOTICE or (3 shl 8);

  { SQLITE_WARNING extensions }
  SQLITE_WARNING_AUTOINDEX = SQLITE_WARNING or (1 shl 8);

  { SQLITE_AUTH extensions }
  SQLITE_AUTH_USER = SQLITE_AUTH or (1 shl 8);

// ---------------------------------------------------------------------------
// SQLITE_OPEN_* flags  (sqlite3.h §3)
// ---------------------------------------------------------------------------

const
  SQLITE_OPEN_READONLY      = $00000001; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_READWRITE     = $00000002; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_CREATE        = $00000004; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_DELETEONCLOSE = $00000008; { VFS only }
  SQLITE_OPEN_EXCLUSIVE     = $00000010; { VFS only }
  SQLITE_OPEN_AUTOPROXY     = $00000020; { VFS only }
  SQLITE_OPEN_URI           = $00000040; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_MEMORY        = $00000080; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_MAIN_DB       = $00000100; { VFS only }
  SQLITE_OPEN_TEMP_DB       = $00000200; { VFS only }
  SQLITE_OPEN_TRANSIENT_DB  = $00000400; { VFS only }
  SQLITE_OPEN_MAIN_JOURNAL  = $00000800; { VFS only }
  SQLITE_OPEN_TEMP_JOURNAL  = $00001000; { VFS only }
  SQLITE_OPEN_SUBJOURNAL    = $00002000; { VFS only }
  SQLITE_OPEN_SUPER_JOURNAL = $00004000; { VFS only }
  SQLITE_OPEN_NOMUTEX       = $00008000; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_FULLMUTEX     = $00010000; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_SHAREDCACHE   = $00020000; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_PRIVATECACHE  = $00040000; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_WAL           = $00080000; { VFS only }
  SQLITE_OPEN_NOFOLLOW      = $01000000; { Ok for sqlite3_open_v2() }
  SQLITE_OPEN_EXRESCODE     = $02000000; { Extended result codes }
  { Legacy alias }
  SQLITE_OPEN_MASTER_JOURNAL = $00004000; { VFS only }

// ---------------------------------------------------------------------------
// Compile-time limits  (sqliteLimit.h — ported once, whole)
// ---------------------------------------------------------------------------

const
  SQLITE_MAX_LENGTH              = 1000000000;
  SQLITE_MIN_LENGTH              = 30;
  SQLITE_MAX_ALLOCATION_SIZE     = 2147483391;
  SQLITE_MAX_COLUMN              = 2000;
  SQLITE_MAX_SQL_LENGTH          = 1000000000;
  SQLITE_MAX_EXPR_DEPTH          = 1000;
  SQLITE_MAX_PARSER_DEPTH        = 2500;
  SQLITE_MAX_COMPOUND_SELECT     = 500;
  SQLITE_MAX_VDBE_OP             = 250000000;
  SQLITE_MAX_FUNCTION_ARG        = 1000;
  SQLITE_DEFAULT_CACHE_SIZE      = -2000;
  SQLITE_DEFAULT_WAL_AUTOCHECKPOINT = 1000;
  SQLITE_MAX_ATTACHED            = 10;
  SQLITE_MAX_VARIABLE_NUMBER     = 32766;
  SQLITE_MAX_PAGE_SIZE           = 65536;
  SQLITE_DEFAULT_PAGE_SIZE       = 4096;
  SQLITE_MAX_DEFAULT_PAGE_SIZE   = 8192;
  SQLITE_MAX_PAGE_COUNT          = $fffffffe; { 4294967294 }
  SQLITE_MAX_LIKE_PATTERN_LENGTH = 50000;
  SQLITE_MAX_TRIGGER_DEPTH       = 1000;

// ---------------------------------------------------------------------------
// Column type codes  (sqlite3.h §5 — SQLITE_INTEGER etc.)
// ---------------------------------------------------------------------------

const
  SQLITE_INTEGER = 1;
  SQLITE_FLOAT   = 2;
  SQLITE_REAL    = 2; { alias for SQLITE_FLOAT }
  SQLITE_BLOB    = 4;
  SQLITE_NULL    = 5;
  SQLITE_TEXT    = 3;
  SQLITE3_TEXT   = 3; { legacy alias }

// ---------------------------------------------------------------------------
// Text encoding constants
// ---------------------------------------------------------------------------

const
  SQLITE_UTF8     = 1; { IMP: R-37514-35566 }
  SQLITE_UTF16LE  = 2; { IMP: R-03371-37637 }
  SQLITE_UTF16BE  = 3; { IMP: R-51971-34154 }
  SQLITE_UTF16    = 4; { Use native byte order — SQLITE_UTF16NATIVE below }
  SQLITE_ANY      = 5; { Deprecated }
  SQLITE_UTF16_ALIGNED = 8; { sqlite3_create_collation only }

// ---------------------------------------------------------------------------
// sqlite3_create_function flags (sqlite3.h §4.8)
// ---------------------------------------------------------------------------

const
  SQLITE_DETERMINISTIC = $00000800; { function always returns same result for same inputs }
  SQLITE_DIRECTONLY    = $00080000; { may only be called from top-level SQL, not triggers/views }
  SQLITE_SUBTYPE       = $00100000; { function may call sqlite3_value_subtype() }
  SQLITE_INNOCUOUS     = $00200000; { function is unlikely to cause problems }

// ---------------------------------------------------------------------------
// Destructor callback type — used by Mem.xDel and sqlite3_create_function
// ---------------------------------------------------------------------------

type
  TxDelProc = procedure(p: Pointer); cdecl;

// ---------------------------------------------------------------------------
// Fundamental destructor constants
// ---------------------------------------------------------------------------

const
  SQLITE_STATIC    : TxDelProc = nil;   { sentinel: no destructor }
  { SQLITE_TRANSIENT and SQLITE_DYNAMIC are vars in passqlite3vdbe.pas because
    they hold non-nil sentinel pointer values that FPC typed const cannot encode. }

// ---------------------------------------------------------------------------
// Integer range constants (used by VDBE and util code)
// ---------------------------------------------------------------------------

const
  SMALLEST_INT64 = Int64(-9223372036854775807) - 1;  { Low(Int64) }
  LARGEST_INT64  = Int64(9223372036854775807);         { High(Int64) }

// ---------------------------------------------------------------------------
// Mem cell size constant (offsetof(TMem, db) = 24)
// ---------------------------------------------------------------------------

const
  MEMCELLSIZE = 24;

implementation

end.
