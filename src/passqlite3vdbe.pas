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
unit passqlite3vdbe;

{
  Pascal port of SQLite's VDBE (Virtual Database Engine).
  Source files: vdbe.c (~9.4 k lines, 192 opcodes), vdbeaux.c, vdbeapi.c,
                vdbemem.c, vdbeblob.c, vdbesort.c, vdbetrace.c, vdbevtab.c.
  Headers:      vdbe.h, vdbeInt.h.

  Phase 5.1: Type definitions — Vdbe, VdbeOp, Mem (sqlite3_value), VdbeCursor,
             plus all constants from opcodes.h, vdbe.h, vdbeInt.h.

  Porting strategy (Phase 0.9 — progressive):
    Types from sqliteInt.h that are not yet ported (FuncDef, CollSeq, KeyInfo,
    Table, Index, Expr, Parse, VList, etc.) are declared as opaque Pointer
    aliases; they will be filled in as Phases 6-8 land.
    Module-local headers: vdbeInt.h fields travel in this unit.

  Field order MUST match C bit-for-bit.
  FPC alignment in {$MODE OBJFPC} mirrors GCC on x86-64 for non-packed records,
  so natural ordering (same types in same order) reproduces C struct offsets
  exactly.  Do NOT add explicit padding fields — FPC inserts it automatically.
  Do NOT reorder for readability.

  Bitfield translation: C `bft x:N` groups are represented as a plain u32 field
  with named bit-mask constants (VDBC_*, VDBF_*).  Adjacent bitfields of the
  same type occupy one storage unit in GCC/Clang; the u32 replacement has the
  same size and alignment.
}

interface

uses
  ctypes,
  Math,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3printf,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree;

{ ============================================================================
  Constants from opcodes.h (generated from vdbe.c by tool/mkopcodeh.tcl)
  SQLite 3.53.0 — 192 opcodes.
  IMPORTANT: These numeric values are part of the stable on-disk serialisation
  for triggers; they must match upstream exactly.
  ============================================================================ }

const
  OP_Savepoint      =   0;
  OP_AutoCommit     =   1;
  OP_Transaction    =   2;
  OP_Checkpoint     =   3;
  OP_JournalMode    =   4;
  OP_Vacuum         =   5;
  OP_VFilter        =   6;
  OP_VUpdate        =   7;
  OP_Init           =   8;
  OP_Goto           =   9;
  OP_Gosub          =  10;
  OP_InitCoroutine  =  11;
  OP_Yield          =  12;
  OP_MustBeInt      =  13;
  OP_Jump           =  14;
  OP_Once           =  15;
  OP_If             =  16;
  OP_IfNot          =  17;
  OP_IsType         =  18;
  OP_Not            =  19;
  OP_IfNullRow      =  20;
  OP_SeekLT         =  21;
  OP_SeekLE         =  22;
  OP_SeekGE         =  23;
  OP_SeekGT         =  24;
  OP_IfNotOpen      =  25;
  OP_IfNoHope       =  26;
  OP_NoConflict     =  27;
  OP_NotFound       =  28;
  OP_Found          =  29;
  OP_SeekRowid      =  30;
  OP_NotExists      =  31;
  OP_Last           =  32;
  OP_IfSizeBetween  =  33;
  OP_SorterSort     =  34;
  OP_Sort           =  35;
  OP_Rewind         =  36;
  OP_IfEmpty        =  37;
  OP_SorterNext     =  38;
  OP_Prev           =  39;
  OP_Next           =  40;
  OP_IdxLE          =  41;
  OP_IdxGT          =  42;
  OP_Or             =  43;
  OP_And            =  44;
  OP_IdxLT          =  45;
  OP_IdxGE          =  46;
  OP_IFindKey       =  47;
  OP_RowSetRead     =  48;
  OP_RowSetTest     =  49;
  OP_Program        =  50;
  OP_IsNull         =  51;
  OP_NotNull        =  52;
  OP_Ne             =  53;
  OP_Eq             =  54;
  OP_Gt             =  55;
  OP_Le             =  56;
  OP_Lt             =  57;
  OP_Ge             =  58;
  OP_ElseEq         =  59;
  OP_FkIfZero       =  60;
  OP_IfPos          =  61;
  OP_IfNotZero      =  62;
  OP_DecrJumpZero   =  63;
  OP_IncrVacuum     =  64;
  OP_VNext          =  65;
  OP_Filter         =  66;
  OP_PureFunc       =  67;
  OP_Function       =  68;
  OP_Return         =  69;
  OP_EndCoroutine   =  70;
  OP_HaltIfNull     =  71;
  OP_Halt           =  72;
  OP_Integer        =  73;
  OP_Int64          =  74;
  OP_String         =  75;
  OP_BeginSubrtn    =  76;
  OP_Null           =  77;
  OP_SoftNull       =  78;
  OP_Blob           =  79;
  OP_Variable       =  80;
  OP_Move           =  81;
  OP_Copy           =  82;
  OP_SCopy          =  83;
  OP_IntCopy        =  84;
  OP_FkCheck        =  85;
  OP_ResultRow      =  86;
  OP_CollSeq        =  87;
  OP_AddImm         =  88;
  OP_RealAffinity   =  89;
  OP_Cast           =  90;
  OP_Permutation    =  91;
  OP_Compare        =  92;
  OP_IsTrue         =  93;
  OP_ZeroOrNull     =  94;
  OP_Offset         =  95;
  OP_Column         =  96;
  OP_TypeCheck      =  97;
  OP_Affinity       =  98;
  OP_MakeRecord     =  99;
  OP_Count          = 100;
  OP_ReadCookie     = 101;
  OP_SetCookie      = 102;
  OP_BitAnd         = 103;
  OP_BitOr          = 104;
  OP_ShiftLeft      = 105;
  OP_ShiftRight     = 106;
  OP_Add            = 107;
  OP_Subtract       = 108;
  OP_Multiply       = 109;
  OP_Divide         = 110;
  OP_Remainder      = 111;
  OP_Concat         = 112;
  OP_ReopenIdx      = 113;
  OP_OpenRead       = 114;
  OP_BitNot         = 115;
  OP_OpenWrite      = 116;
  OP_OpenDup        = 117;
  OP_String8        = 118;
  OP_OpenAutoindex  = 119;
  OP_OpenEphemeral  = 120;
  OP_SorterOpen     = 121;
  OP_SequenceTest   = 122;
  OP_OpenPseudo     = 123;
  OP_Close          = 124;
  OP_ColumnsUsed    = 125;
  OP_SeekScan       = 126;
  OP_SeekHit        = 127;
  OP_Sequence       = 128;
  OP_NewRowid       = 129;
  OP_Insert         = 130;
  OP_RowCell        = 131;
  OP_Delete         = 132;
  OP_ResetCount     = 133;
  OP_SorterCompare  = 134;
  OP_SorterData     = 135;
  OP_RowData        = 136;
  OP_Rowid          = 137;
  OP_NullRow        = 138;
  OP_SeekEnd        = 139;
  OP_IdxInsert      = 140;
  OP_SorterInsert   = 141;
  OP_IdxDelete      = 142;
  OP_DeferredSeek   = 143;
  OP_IdxRowid       = 144;
  OP_FinishSeek     = 145;
  OP_Destroy        = 146;
  OP_Clear          = 147;
  OP_ResetSorter    = 148;
  OP_CreateBtree    = 149;
  OP_SqlExec        = 150;
  OP_ParseSchema    = 151;
  OP_LoadAnalysis   = 152;
  OP_DropTable      = 153;
  OP_Real           = 154;
  OP_DropIndex      = 155;
  OP_DropTrigger    = 156;
  OP_IntegrityCk    = 157;
  OP_RowSetAdd      = 158;
  OP_Param          = 159;
  OP_FkCounter      = 160;
  OP_MemMax         = 161;
  OP_OffsetLimit    = 162;
  OP_AggInverse     = 163;
  OP_AggStep        = 164;
  OP_AggStep1       = 165;
  OP_AggValue       = 166;
  OP_AggFinal       = 167;
  OP_Expire         = 168;
  OP_CursorLock     = 169;
  OP_CursorUnlock   = 170;
  OP_TableLock      = 171;
  OP_VBegin         = 172;
  OP_VCreate        = 173;
  OP_VDestroy       = 174;
  OP_VOpen          = 175;
  OP_VCheck         = 176;
  OP_VInitIn        = 177;
  OP_VColumn        = 178;
  OP_VRename        = 179;
  OP_Pagecount      = 180;
  OP_MaxPgcnt       = 181;
  OP_ClrSubtype     = 182;
  OP_GetSubtype     = 183;
  OP_SetSubtype     = 184;
  OP_FilterAdd      = 185;
  OP_Trace          = 186;
  OP_CursorHint     = 187;
  OP_ReleaseReg     = 188;
  OP_Noop           = 189;
  OP_Explain        = 190;
  OP_Abortable      = 191;

  { Maximum JUMP opcode value (opcodes.h) }
  SQLITE_MX_JUMP_OPCODE = 66;

{ ============================================================================
  Opcode property flags (opcodes.h OPFLG_*)
  ============================================================================ }

const
  OPFLG_JUMP   = $01;  { P2 holds jump target }
  OPFLG_IN1    = $02;  { P1 is an input }
  OPFLG_IN2    = $04;  { P2 is an input }
  OPFLG_IN3    = $08;  { P3 is an input }
  OPFLG_OUT2   = $10;  { P2 is an output }
  OPFLG_OUT3   = $20;  { P3 is an output }
  OPFLG_NCYCLE = $40;  { cycles count against P1 }
  OPFLG_JUMP0  = $80;  { P2 might be zero }

{ ============================================================================
  P4 operand type tags (vdbe.h)
  Negative values indicate the P4 union field owns a heap allocation
  and must be freed when the instruction is freed.
  ============================================================================ }

const
  P4_NOTUSED    =   0;  { P4 not used }
  P4_TRANSIENT  =   0;  { P4 is transient string — same slot as NOTUSED }
  P4_STATIC     =  -1;  { Pointer to static string }
  P4_COLLSEQ    =  -2;  { P4 is CollSeq* }
  P4_INT32      =  -3;  { P4 is 32-bit signed integer }
  P4_SUBPROGRAM =  -4;  { P4 is SubProgram* }
  P4_TABLE      =  -5;  { P4 is Table* }
  P4_INDEX      =  -6;  { P4 is Index* }
  P4_FREE_IF_LE =  -7;  { threshold: types ≤ this free their payload }
  P4_DYNAMIC    =  -7;  { P4 is malloc'd pointer — same threshold }
  P4_FUNCDEF    =  -8;  { P4 is FuncDef* }
  P4_KEYINFO    =  -9;  { P4 is KeyInfo* }
  P4_EXPR       = -10;  { P4 is Expr* }
  P4_MEM        = -11;  { P4 is Mem* }
  P4_VTAB       = -12;  { P4 is sqlite3_vtab* }
  P4_REAL       = -13;  { P4 is 64-bit floating point }
  P4_INT64      = -14;  { P4 is 64-bit signed integer }
  P4_INTARRAY   = -15;  { P4 is u32 array }
  P4_FUNCCTX    = -16;  { P4 is sqlite3_context* }
  P4_TABLEREF   = -17;  { P4 is reference-counted Table* }
  P4_SUBRTNSIG  = -18;  { P4 is SubrtnSig* }

{ P5 values for OP_Halt constraint violations (vdbe.h) }
const
  P5_ConstraintNotNull = 1;
  P5_ConstraintUnique  = 2;
  P5_ConstraintCheck   = 3;
  P5_ConstraintFK      = 4;

{ Column name slot indices for Vdbe.aColName (vdbe.h) }
const
  COLNAME_NAME     = 0;
  COLNAME_DECLTYPE = 1;
  COLNAME_DATABASE = 2;
  COLNAME_TABLE    = 3;
  COLNAME_COLUMN   = 4;
  { Without SQLITE_ENABLE_COLUMN_METADATA: }
  COLNAME_N        = 2;

{ SQLITE_PREPARE_* internal flags (vdbe.h) }
const
  SQLITE_PREPARE_SAVESQL = $80;  { preserve SQL text in Vdbe.zSql }
  SQLITE_PREPARE_MASK    = $3F;  { mask of public flags }

{ ADDR(x) macro from vdbe.h: label index <-> negative encoding }
{ A label L is stored as ~L (bitwise NOT); ADDR(x) = ~x = -(x+1). }
{ In Pascal: vdbeADDR(x) = not x  (which equals -(x+1) for signed int). }

{ On-error action codes (sqliteInt.h OE_*) }
const
  OE_None     = 0;
  OE_Rollback = 1;  { ROLLBACK the transaction }
  OE_Abort    = 2;  { back out changes but don't rollback }
  OE_Fail     = 3;  { stop without rolling back }
  OE_Ignore   = 4;  { ignore the constraint error }
  OE_Replace  = 5;  { delete old, then do INSERT/UPDATE }
  OE_Update   = 6;  { update existing record }
  OE_Restrict = 7;  { restrict referential action }
  OE_SetNull  = 8;
  OE_SetDflt  = 9;
  OE_Cascade  = 10;
  OE_Default  = 11;

{ SQLITE_N_LIMIT: number of distinct run-time limits (sqliteInt.h) }
const
  SQLITE_N_LIMIT = 13;

{ SQLITE_LIMIT_VDBE_OP index }
const
  SQLITE_LIMIT_VDBE_OP        = 5;   { max number of instructions in a VDBE program }
  SQLITE_LIMIT_TRIGGER_DEPTH  = 10;  { max nested trigger depth }

{ SQLITE_STMTSTATUS_REPREPARE counter index (vdbe.h) }
const
  SQLITE_STMTSTATUS_FULLSCAN_STEP = 1;
  SQLITE_STMTSTATUS_SORT          = 2;
  SQLITE_STMTSTATUS_AUTOINDEX     = 3;
  SQLITE_STMTSTATUS_VM_STEP       = 4;
  SQLITE_STMTSTATUS_REPREPARE     = 5;
  SQLITE_STMTSTATUS_RUN           = 6;
  SQLITE_STMTSTATUS_FILTER_MISS   = 7;
  SQLITE_STMTSTATUS_FILTER_HIT    = 8;
  SQLITE_STMTSTATUS_MEMUSED       = 99;

{ Default VDBE OP limit — from sqliteInt.h SQLITE_DEFAULT_VDBE_OP }
const
  SQLITE_DEFAULT_VDBE_OP = 250000000;

{ BTREE_INTKEY from btree.h — used in sqlite3VdbeAssertMayAbort }
{ (already in passqlite3btree.pas but we need it here too) }
const
  BTREE_INTKEY = 1;

{ sqlite3 statement close operations (sqliteInt.h) }
const
  SAVEPOINT_BEGIN   = 0;
  SAVEPOINT_RELEASE = 1;
  SAVEPOINT_ROLLBACK = 2;

{ ============================================================================
  MEM_* flag bits for Mem.flags (vdbeInt.h)
  ============================================================================ }

const
  MEM_Undefined = $0000;  { value is undefined / uninitialised }
  MEM_Null      = $0001;  { SQL NULL (or pointer type) }
  MEM_Str       = $0002;  { string stored in Mem.z / Mem.n }
  MEM_Int       = $0004;  { integer stored in Mem.u.i }
  MEM_Real      = $0008;  { real stored in Mem.u.r }
  MEM_Blob      = $0010;  { blob stored in Mem.z / Mem.n }
  MEM_IntReal   = $0020;  { real stored as integer in Mem.u.i }
  MEM_AffMask   = $003F;  { mask of affinity bits }
  MEM_FromBind  = $0040;  { value from sqlite3_bind() }
  { $0080 available }
  MEM_Cleared   = $0100;  { NULL set by OP_Null, not from data }
  MEM_Term      = $0200;  { Mem.z is NUL-terminated }
  MEM_Zero      = $0400;  { Mem.u.nZero extra 0-bytes appended to blob }
  MEM_Subtype   = $0800;  { Mem.eSubtype is valid }
  MEM_TypeMask  = $0DBF;  { mask of all type bits }
  MEM_Dyn       = $1000;  { must call Mem.xDel() on Mem.z }
  MEM_Static    = $2000;  { Mem.z points to static string }
  MEM_Ephem     = $4000;  { Mem.z points to ephemeral string }
  MEM_Agg       = $8000;  { Mem.z points to agg function context }

{ ============================================================================
  VdbeCursor type codes (vdbeInt.h CURTYPE_*)
  ============================================================================ }

const
  CURTYPE_BTREE  = 0;  { b-tree cursor (main or ephemeral) }
  CURTYPE_SORTER = 1;  { external sorter }
  CURTYPE_VTAB   = 2;  { virtual table }
  CURTYPE_PSEUDO = 3;  { single-row "pseudotable" in a register }

  { Cache-invalid sentinel for VdbeCursor.cacheStatus }
  CACHE_STALE    = 0;

{ ============================================================================
  VdbeCursor bitfield constants — packed into cursorFlags: u32
  C source: Bool isEphemeral:1; useRandomRowid:1; isOrdered:1; noReuse:1;
            colCache:1;  (5 bits in one unsigned int storage unit)
  ============================================================================ }

const
  VDBC_Ephemeral   = $01;  { isEphemeral: ephemeral table cursor }
  VDBC_RandomRowid = $02;  { useRandomRowid: generate random rowids }
  VDBC_Ordered     = $04;  { isOrdered: btree is not BTREE_UNORDERED }
  VDBC_NoReuse     = $08;  { noReuse: OpenEphemeral may not reuse this }
  VDBC_ColCache    = $10;  { colCache: pCache is initialised and valid }

{ ============================================================================
  Vdbe bitfield constants — packed into vdbeFlags: u32
  C source: bft expired:2; explain:2; changeCntOn:1; usesStmtJournal:1;
            readOnly:1; bIsReader:1; haveEqpOps:1;  (9 bits total)
  ============================================================================ }

const
  VDBF_EXPIRED_SHIFT      = 0;
  VDBF_EXPIRED_MASK       = $03;  { expired: 0=live, 1=recompile now, 2=when convenient }
  VDBF_EXPLAIN_SHIFT      = 2;
  VDBF_EXPLAIN_MASK       = $0C;  { explain: 0=normal, 1=EXPLAIN, 2=EXPLAIN QUERY PLAN }
  VDBF_ChangeCntOn        = $10;  { changeCntOn: update change-counter }
  VDBF_UsesStmtJournal    = $20;  { usesStmtJournal: uses statement journal }
  VDBF_ReadOnly           = $40;  { readOnly: no writes }
  VDBF_IsReader           = $80;  { bIsReader: reads data }
  VDBF_HaveEqpOps         = $100; { haveEqpOps: bytecode has EQP ops }

{ ============================================================================
  Vdbe execution state values (vdbeInt.h VDBE_*_STATE)
  ============================================================================ }

const
  VDBE_INIT_STATE  = 0;  { prepared statement under construction }
  VDBE_READY_STATE = 1;  { ready to run, not yet started }
  VDBE_RUN_STATE   = 2;  { execution in progress }
  VDBE_HALT_STATE  = 3;  { finished; needs reset() or finalize() }

{ VdbeFrame validity sentinel (vdbeInt.h) }
const
  SQLITE_FRAME_MAGIC   = $879fb71e;
  SQLITE_MAX_SCHEMA_RETRY = 50;  { max SQLITE_SCHEMA retries before error }

{ VDBE_DISPLAY_P4: 1 because we include explain/debug support by default }
const
  VDBE_DISPLAY_P4 = 1;

{ ============================================================================
  Text / column affinity constants (from sqliteInt.h; also needed by VDBE)
  ============================================================================ }

const
  SQLITE_AFF_NONE    = $40;  { '@' }
  SQLITE_AFF_BLOB    = $41;  { 'A' }
  SQLITE_AFF_TEXT    = $42;  { 'B' }
  SQLITE_AFF_NUMERIC = $43;  { 'C' }
  SQLITE_AFF_INTEGER = $44;  { 'D' }
  SQLITE_AFF_REAL    = $45;  { 'E' }
  SQLITE_AFF_FLEXNUM = $46;  { 'F' }
  SQLITE_AFF_DEFER   = $58;  { 'X' — defer until later }
  SQLITE_AFF_MASK    = $47;

  { Comparison flags (OR'd with affinity in VdbeOp.p5 for comparisons) }
  SQLITE_JUMPIFNULL  = $10;
  SQLITE_NULLEQ      = $80;
  SQLITE_NOTNULL     = $90;

{ ============================================================================
  SQLITE_FUNC_* flags (sqliteInt.h — FuncDef.funcFlags)
  ============================================================================ }

const
  SQLITE_FUNC_ENCMASK  = $0003;
  SQLITE_FUNC_LIKE     = $0004;
  SQLITE_FUNC_CASE     = $0008;
  SQLITE_FUNC_EPHEM    = $0010;
  SQLITE_FUNC_NEEDCOLL = $0020;
  SQLITE_FUNC_LENGTH   = $0040;
  SQLITE_FUNC_TYPEOF   = $0080;
  SQLITE_FUNC_BYTELEN  = $00C0;
  SQLITE_FUNC_COUNT    = $0100;
  SQLITE_FUNC_UNLIKELY = $0400;
  SQLITE_FUNC_CONSTANT = $0800;
  SQLITE_FUNC_MINMAX   = $1000;
  SQLITE_FUNC_SLOCHNG  = $2000;
  SQLITE_FUNC_TEST     = $4000;
  SQLITE_FUNC_RUNONLY  = $8000;
  SQLITE_FUNC_WINDOW   = $00010000;
  SQLITE_FUNC_INTERNAL = $00040000;
  SQLITE_FUNC_DIRECT   = $00080000;
  SQLITE_FUNC_UNSAFE   = $00200000;
  SQLITE_FUNC_INLINE   = $00400000;
  SQLITE_FUNC_BUILTIN  = $00800000;
  SQLITE_FUNC_ANYORDER = $08000000;

  SQLITE_FUNC_HASH_SZ  = 23;

{ INLINEFUNC_* — pUserData tags for SQLITE_FUNC_INLINE built-ins.
  Mirrors sqliteInt.h:2055..2062.  The expression-parity layer reads
  these to decide whether a TK_FUNCTION node has implication / non-NULL-
  row inferences attached. }
  INLINEFUNC_coalesce            = 0;
  INLINEFUNC_implies_nonnull_row = 1;
  INLINEFUNC_expr_implies_expr   = 2;
  INLINEFUNC_expr_compare        = 3;
  INLINEFUNC_affinity            = 4;
  INLINEFUNC_iif                 = 5;
  INLINEFUNC_sqlite_offset       = 6;
  INLINEFUNC_unlikely            = 99;

{ ============================================================================
  Auth action codes (sqlite3.h — for sqlite3_set_authorizer)
  ============================================================================ }

  SQLITE_CREATE_INDEX      = 1;
  SQLITE_CREATE_TABLE      = 2;
  SQLITE_CREATE_TEMP_INDEX = 3;
  SQLITE_CREATE_TEMP_TABLE = 4;
  SQLITE_CREATE_TEMP_TRIGGER = 5;
  SQLITE_CREATE_TEMP_VIEW  = 6;
  SQLITE_CREATE_TRIGGER    = 7;
  SQLITE_CREATE_VIEW       = 8;
  SQLITE_DELETE_AUTH       = 9;   { = SQLITE_DELETE but avoid clash with SQLITE_DELETE result code }
  SQLITE_DROP_INDEX        = 10;
  SQLITE_DROP_TABLE        = 11;
  SQLITE_DROP_TEMP_INDEX   = 12;
  SQLITE_DROP_TEMP_TABLE   = 13;
  SQLITE_DROP_TEMP_TRIGGER = 14;
  SQLITE_DROP_TEMP_VIEW    = 15;
  SQLITE_DROP_TRIGGER      = 16;
  SQLITE_DROP_VIEW         = 17;
  SQLITE_INSERT_AUTH       = 18;  { = SQLITE_INSERT }
  SQLITE_PRAGMA_AUTH       = 19;
  SQLITE_READ_AUTH         = 20;
  SQLITE_SELECT_AUTH       = 21;
  SQLITE_TRANSACTION_AUTH  = 22;
  SQLITE_UPDATE_AUTH       = 23;
  SQLITE_ATTACH_AUTH       = 24;
  SQLITE_DETACH_AUTH       = 25;
  SQLITE_ALTER_TABLE_AUTH  = 26;
  SQLITE_REINDEX_AUTH      = 27;
  SQLITE_ANALYZE_AUTH      = 28;
  SQLITE_CREATE_VTABLE     = 29;
  SQLITE_DROP_VTABLE       = 30;
  SQLITE_FUNCTION_AUTH     = 31;
  SQLITE_SAVEPOINT_AUTH    = 32;
  SQLITE_RECURSIVE_AUTH    = 33;

{ ============================================================================
  KEY INFO sort flags (sqliteInt.h KEYINFO_ORDER_*)
  ============================================================================ }

const
  KEYINFO_ORDER_DESC    = $01;
  KEYINFO_ORDER_BIGNULL = $02;

{ ============================================================================
  OPFLG_INITIALIZER (192-byte property table, from opcodes.h)
  Maps OP_xxx → bitset of OPFLG_* flags; used by vdbeaux.c resolve logic.
  ============================================================================ }

const
  sqlite3OpcodeProperty: array[0..191] of u8 = (
    { 000-007 } $00, $00, $00, $00, $10, $00, $41, $00,
    { 008-015 } $81, $01, $01, $81, $83, $83, $01, $01,
    { 016-023 } $03, $03, $01, $12, $01, $c9, $c9, $c9,
    { 024-031 } $c9, $01, $49, $49, $49, $49, $c9, $49,
    { 032-039 } $c1, $01, $41, $41, $c1, $01, $01, $41,
    { 040-047 } $41, $41, $41, $26, $26, $41, $41, $09,
    { 048-055 } $23, $0b, $81, $03, $03, $0b, $0b, $0b,
    { 056-063 } $0b, $0b, $0b, $01, $01, $03, $03, $03,
    { 064-071 } $01, $41, $01, $00, $00, $02, $02, $08,
    { 072-079 } $00, $10, $10, $10, $00, $10, $00, $10,
    { 080-087 } $10, $00, $00, $10, $10, $00, $00, $00,
    { 088-095 } $02, $02, $02, $00, $00, $12, $1e, $20,
    { 096-103 } $40, $00, $00, $00, $10, $10, $00, $26,
    { 104-111 } $26, $26, $26, $26, $26, $26, $26, $26,
    { 112-119 } $26, $40, $40, $12, $00, $40, $10, $40,
    { 120-127 } $40, $00, $00, $00, $40, $00, $40, $40,
    { 128-135 } $10, $10, $00, $00, $00, $40, $00, $40,
    { 136-143 } $00, $50, $00, $40, $04, $04, $00, $40,
    { 144-151 } $50, $40, $10, $00, $00, $10, $00, $00,
    { 152-159 } $00, $00, $10, $00, $00, $00, $06, $10,
    { 160-167 } $00, $04, $1a, $00, $00, $00, $00, $00,
    { 168-175 } $00, $00, $00, $00, $00, $00, $00, $40,
    { 176-183 } $10, $50, $40, $00, $10, $10, $02, $12,
    { 184-191 } $12, $00, $00, $00, $00, $00, $00, $00
  );

{ ============================================================================
  TYPE DEFINITIONS
  All types in one block so FPC can resolve mutual forward references.
  ============================================================================ }

type

  { -----------------------------------------------------------------------
    Scalar type aliases (from sqliteInt.h).
    These must match the platform defaults for SQLITE_MAX_VARIABLE_NUMBER
    (default 32766 ≤ 32767 → i16) and SQLITE_MAX_ATTACHED (default 10 ≤ 30
    → u32).
    ----------------------------------------------------------------------- }

  ynVar  = i16;   { number of variables; fits i16 for default config }
  LogEst = i16;   { INT16_TYPE: base-2 log estimate }
  yDbMask = u32;  { bitmask of attached databases; u32 for ≤30 attached }

  { -----------------------------------------------------------------------
    Opaque pointer aliases for sqliteInt.h types not yet ported.
    These will be replaced with proper pointer-to-record types as the
    corresponding phases land (Phase 6 for most, Phase 7 for Parse).
    ----------------------------------------------------------------------- }

  PFuncDef  = Pointer;  { FuncDef  — kept as opaque for OP_ param compat }
  PCollSeq  = Pointer;  { CollSeq  — opaque alias for OP_CollSeq param compat }
  PTable    = Pointer;  { Table    — Phase 6 (build.c) }
  PIndex    = Pointer;  { Index    — Phase 6 }

  { Minimal field overlay for struct Table — only the members the
    update-hook arms of OP_Insert / OP_Delete need (zName@0, aCol@8,
    tabFlags@48).  Full layout lives in passqlite3codegen.TTable, which
    this unit deliberately does not see; the offsets below mirror it. }
  PTableHookFields = ^TTableHookFields;
  TTableHookFields = record
    zName:    PAnsiChar;            { @0  }
    aCol:     Pointer;              { @8  }
    pad0:     array[0..31] of Byte; { @16 — pIndex..nTabRef }
    tabFlags: u32;                  { @48 }
  end;

  { Post-update hook callback — sqlite3.xUpdateCallback.
    void(*)(void*,int,const char*,const char*,sqlite3_int64). }
  TUpdateCallbackFn = procedure(pArg: Pointer; op: i32;
    zDb, zTbl: PAnsiChar; rowid: i64); cdecl;
  PExpr     = Pointer;  { Expr     — Phase 6 (expr.c) }
  PParse    = Pointer;  { Parse    — Phase 7 (tokenize.c / parse.y) }
  PVList    = Pointer;  { VList (int array) — Phase 6 }
  PVTable   = Pointer;  { VTable   — Phase 6.bis (vtab.c) }
  Psqlite3_vtab_cursor = Pointer;  { vtab cursor — Phase 6.bis }
  PVdbeSorter = ^TVdbeSorter;      { VdbeSorter  — Phase 5.7 (vdbesort.c) }
  { vdbesort.c private objects (Phase 5.7.b.1) — forward pointer typedefs;
    full record layouts declared in the Phase 5.7 sorter type block below. }
  PSorterRecord = ^TSorterRecord;  { SorterRecord — vdbesort.c:447 }
  PMergeEngine  = ^TMergeEngine;   { MergeEngine  — vdbesort.c:256 }
  PPMergeEngine = ^PMergeEngine;   { MergeEngine** — out-param for Level0 }
  PPmaReader    = ^TPmaReader;     { PmaReader    — vdbesort.c:354 }
  PPmaWriter    = ^TPmaWriter;     { PmaWriter    — vdbesort.c:418 }
  PIncrMerger   = ^TIncrMerger;    { IncrMerger   — vdbesort.c:400 }
  PPIncrMerger  = ^PIncrMerger;    { IncrMerger** — out-param for IncrMergerNew }
  PSortSubtask  = ^TSortSubtask;   { SortSubtask  — vdbesort.c:295 }

  { -----------------------------------------------------------------------
    Pointer forward declarations for VDBE types — mutual references require
    all to be in a single type block in FPC.
    ----------------------------------------------------------------------- }

  PVdbe          = ^TVdbe;
  PPVdbe         = ^PVdbe;
  PMem           = ^TMem;
  PPMem          = ^PMem;
  PPi32          = ^Pi32;           { pointer to Pi32, used for Parse.aLabel }
  Psqlite3_value = PMem;           { Mem and sqlite3_value are the same type }
  PPsqlite3_value = ^Psqlite3_value;
  PVdbeCursor    = ^TVdbeCursor;
  PPVdbeCursor   = ^PVdbeCursor;
  PVdbeFrame     = ^TVdbeFrame;
  PAuxData       = ^TAuxData;
  PPAuxData      = ^PAuxData;
  PSubProgram    = ^TSubProgram;
  PPSubProgram   = ^PSubProgram;

  { Phase 5.6 — vdbeblob.c Incrblob handle }
  PIncrblob      = ^TIncrblob;
  Psqlite3_blob  = PIncrblob;       { sqlite3_blob* opaque handle }
  PScanStatus    = ^TScanStatus;
  PDblquoteStr   = ^TDblquoteStr;
  PVdbeOp        = ^TVdbeOp;
  PPVdbeOp       = ^PVdbeOp;
  PVdbeOpList    = ^TVdbeOpList;
  PSubrtnSig     = ^TSubrtnSig;
  PVdbeTxtBlbCache = ^TVdbeTxtBlbCache;
  PValueList     = ^TValueList;
  Psqlite3_context = ^Tsqlite3_context;
  PPsqlite3_context = ^Psqlite3_context;

  { -----------------------------------------------------------------------
    Destructor callback type: see passqlite3types.TxDelProc.
    ----------------------------------------------------------------------- }

  { TxDelProc is defined in passqlite3types. }

  { -----------------------------------------------------------------------
    TMemValue — variant union inside TMem (vdbeInt.h struct sqlite3_value.u).
    C layout: union { double r; i64 i; int nZero; const char *zPType;
                      FuncDef *pDef; }
    Size: 8 bytes on 64-bit (largest member is double/i64/pointer = 8 B).
    ----------------------------------------------------------------------- }

  TMemValue = record
    case integer of
      0: (r:      Double);     { MEM_Real: floating-point value }
      1: (i:      i64);        { MEM_Int: integer value }
      2: (nZero:  i32);        { MEM_Zero: extra 0-bytes for blob }
      3: (zPType: PAnsiChar);  { MEM_Term|MEM_Subtype|MEM_Null: pointer type }
      4: (pDef:   PFuncDef);   { MEM_Agg: aggregate function context }
  end;

  { -----------------------------------------------------------------------
    TMem = sqlite3_value — the universal VDBE value type.
    vdbeInt.h struct sqlite3_value.

    Field ordering matches C exactly.  MEMCELLSIZE = offsetof(Mem,db);
    ShallowCopy only copies fields above that boundary.

    NOTE: debug-only fields (pScopyFrom, mScopyFlags, bScopy) are omitted
    because the port targets the non-debug configuration for on-disk parity.
    ----------------------------------------------------------------------- }

  TMem = record
    u:        TMemValue;   { value union (8 bytes) }
    z:        PAnsiChar;   { string or BLOB data }
    n:        i32;         { length of z (excluding NUL for strings) }
    flags:    u16;         { MEM_* flag bits }
    enc:      u8;          { SQLITE_UTF8/UTF16LE/UTF16BE }
    eSubtype: u8;          { subtype byte (valid when MEM_Subtype set) }
    { ShallowCopy copies only the fields above — MEMCELLSIZE boundary here }
    db:       Psqlite3;    { associated database connection }
    szMalloc: i32;         { size of the zMalloc buffer }
    uTemp:    u32;         { transient: serial_type during OP_MakeRecord }
    zMalloc:  PAnsiChar;   { heap buffer backing z when szMalloc > 0 }
    xDel:     TxDelProc;   { z destructor, valid when MEM_Dyn is set }
  end;

  { -----------------------------------------------------------------------
    TVdbeTxtBlbCache — large TEXT/BLOB column value cache attached to a cursor.
    vdbeInt.h struct VdbeTxtBlbCache.
    ----------------------------------------------------------------------- }

  TVdbeTxtBlbCache = record
    pCValue:    PAnsiChar;  { RCStr buffer holding the cached value }
    iOffset:    i64;        { file offset of the row being cached }
    iCol:       i32;        { column for which the cache is valid }
    cacheStatus:u32;        { value of Vdbe.cacheCtr when this was cached }
    colCacheCtr:u32;        { column cache counter }
  end;

  { -----------------------------------------------------------------------
    TAuxData — per-invocation auxiliary data for SQL functions.
    vdbeInt.h struct AuxData.
    Linked list headed at Vdbe.pAuxData; freed when VM is reset.
    ----------------------------------------------------------------------- }

  TAuxData = record
    iAuxOp:     i32;        { instruction number of the OP_Function opcode }
    iAuxArg:    i32;        { index of the function argument }
    pAux:       Pointer;    { the auxiliary data pointer }
    xDeleteAux: TxDelProc;  { destructor for pAux }
    pNextAux:   PAuxData;   { next element in Vdbe.pAuxData list }
  end;

  { -----------------------------------------------------------------------
    TScanStatus — one entry in Vdbe.aScan[] for sqlite3_stmt_scanstatus().
    vdbeInt.h struct ScanStatus.
    ----------------------------------------------------------------------- }

  TScanStatus = record
    addrExplain: i32;              { OP_Explain address for the loop }
    aAddrRange:  array[0..5] of i32; { up to 3 [start,end] ranges for nCycle }
    addrLoop:    i32;              { address of "loops visited" counter }
    addrVisit:   i32;              { address of "rows visited" counter }
    iSelectID:   i32;              { SELECT-id for this loop }
    nEst:        LogEst;           { estimated output rows per loop }
    zName:       PAnsiChar;        { name of table or index }
  end;

  { -----------------------------------------------------------------------
    TDblquoteStr — double-quoted string literal entry.
    vdbeInt.h struct DblquoteStr.
    Used to distinguish identifiers from string literals in normalised SQL.
    ----------------------------------------------------------------------- }

  TDblquoteStr = record
    pNextStr: PDblquoteStr;      { next string literal in list }
    z:        array[0..7] of AnsiChar;  { dequoted value (first 8 bytes) }
  end;

  { -----------------------------------------------------------------------
    TSubrtnSig — signature for a reusable IN-operator subroutine.
    vdbe.h struct SubrtnSig.
    ----------------------------------------------------------------------- }

  TSubrtnSig = record
    selId:     i32;        { SELECT-id of the RHS SELECT statement }
    bComplete: u8;         { True if fully coded and reusable }
    zAff:      PAnsiChar;  { affinity of the overall IN expression }
    iTable:    i32;        { ephemeral table generated by the subroutine }
    iAddr:     i32;        { subroutine entry address }
    regReturn: i32;        { register used for return address }
  end;

  { -----------------------------------------------------------------------
    Tp4union — fourth-operand union for TVdbeOp.
    vdbe.h union p4union.
    All members are pointer-sized (or smaller); size = 8 bytes on 64-bit.
    The tag (p4type in TVdbeOp) is NOT stored inside this union.
    ----------------------------------------------------------------------- }

  Tp4union = record
    case integer of
       0: (i:          i32);           { P4_INT32 }
       1: (p:          Pointer);       { generic pointer / P4_DYNAMIC }
       2: (z:          PAnsiChar);     { P4_STATIC / P4_TRANSIENT }
       3: (pI64:       Pi64);          { P4_INT64 }
       4: (pReal:      PDouble);       { P4_REAL }
       5: (pFunc:      PFuncDef);      { P4_FUNCDEF }
       6: (pCtx:       Psqlite3_context); { P4_FUNCCTX }
       7: (pColl:      PCollSeq);      { P4_COLLSEQ }
       8: (pMem:       PMem);          { P4_MEM }
       9: (pVtab:      PVTable);       { P4_VTAB }
      10: (pKeyInfo:   PKeyInfo);      { P4_KEYINFO }
      11: (ai:         Pu32);          { P4_INTARRAY }
      12: (pProgram:   PSubProgram);   { P4_SUBPROGRAM }
      13: (pTab:       PTable);        { P4_TABLE / P4_TABLEREF }
      14: (pSubrtnSig: PSubrtnSig);    { P4_SUBRTNSIG }
      15: (pIdx:       PIndex);        { P4_INDEX }
  end;

  { -----------------------------------------------------------------------
    TVdbeOp — one VDBE instruction.
    vdbe.h struct VdbeOp.

    On-disk note: opcode+p4type+p5+p1+p2+p3+p4 are serialised into the
    trigger program stored in sqlite_schema.  Field order MUST match C.
    ----------------------------------------------------------------------- }

  TVdbeOp = record
    opcode:  u8;      { which operation to perform }
    p4type:  i8;      { one of the P4_xxx constants (signed) }
    p5:      u16;     { fifth parameter }
    p1:      i32;     { first operand }
    p2:      i32;     { second operand (often jump destination) }
    p3:      i32;     { third operand }
    p4:      Tp4union;{ fourth operand }
    { Phase 8.2.1 — sqlite3_stmt_scanstatus() per-op execution counter.
      Mirrors u64 nExec in vdbe.h struct VdbeOp (gated on
      SQLITE_ENABLE_STMT_SCANSTATUS in C; unconditional here so
      .scanstats works without a rebuild flag). }
    nExec:   u64;     { times this opcode has been executed }
    { Phase 10.1.39.d.1 — sqlite3_stmt_scanstatus(SCANSTAT_NCYCLE)
      per-op hardware-time counter.  Mirrors u64 nCycle in vdbe.h
      struct VdbeOp (gated on SQLITE_ENABLE_STMT_SCANSTATUS in C).
      The bracket that increments this is conditional on
      {$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS} around the dispatch
      loop in vdbe.pas (vdbe.c:940..950 + vdbe.c:9246..9251).
      Field is always present so the record layout/size stays stable
      across debug/non-debug builds; in non-default builds it just
      stays 0 and the SCANSTAT_NCYCLE reader returns sum-of-zeros. }
    nCycle:  u64;     { hwtime cycles attributed to this opcode }
  end;

  { -----------------------------------------------------------------------
    TVdbeOpList — compact instruction descriptor for VdbeAddOpList().
    vdbe.h struct VdbeOpList.
    Smaller than TVdbeOp (4 bytes vs ≥24); only opcode+p1+p2+p3.
    ----------------------------------------------------------------------- }

  TVdbeOpList = record
    opcode: u8;
    p1:     shortint;  { = signed char }
    p2:     shortint;
    p3:     shortint;
  end;

  { -----------------------------------------------------------------------
    TSubProgram — a trigger sub-program referenced by OP_Program.
    vdbe.h struct SubProgram.
    ----------------------------------------------------------------------- }

  TSubProgram = record
    aOp:   PVdbeOp;      { opcodes for the sub-program }
    nOp:   i32;          { element count in aOp[] }
    nMem:  i32;          { memory cells required }
    nCsr:  i32;          { cursors required }
    aOnce: Pu8;          { OP_Once flags array }
    token: Pointer;      { identity token for recursive trigger detection }
    pNext: PSubProgram;  { next sub-program already visited }
  end;

  { -----------------------------------------------------------------------
    TVdbeFrame — saved VM state during sub-program (trigger) execution.
    vdbeInt.h struct VdbeFrame.

    Allocated as a memory cell; linked via VdbeFrame.pParent.  When the
    sub-program returns, these values are copied back to Vdbe.
    ----------------------------------------------------------------------- }

  TVdbeFrame = record
    v:         PVdbe;           { VM that owns this frame }
    pParent:   PVdbeFrame;      { parent frame, or nil if this is main }
    aOp:       PVdbeOp;         { program instructions for parent frame }
    aMem:      PMem;            { memory cells for parent frame }
    apCsr:     PPVdbeCursor;    { cursors for parent frame }
    aOnce:     Pu8;             { OP_Once bitmask for parent frame }
    token:     Pointer;         { copy of SubProgram.token }
    lastRowid: i64;             { sqlite3.lastRowid at entry }
    pAuxData:  PAuxData;        { linked list of auxdata allocations }
    nCursor:   i32;             { number of entries in apCsr }
    pc:        i32;             { program counter in parent frame }
    nOp:       i32;             { size of aOp[] }
    nMem:      i32;             { number of entries in aMem }
    nChildMem: i32;             { memory cells for child frame }
    nChildCsr: i32;             { cursors for child frame }
    nChange:   i64;             { Vdbe.nChange at entry }
    nDbChange: i64;             { db->nChange at entry }
  end;

  { -----------------------------------------------------------------------
    TVdbeCursorUb — union ub inside TVdbeCursor.
    C: union { Btree *pBtx; u32 *aAltMap; }
    Used for isEphemeral cursors (pBtx) vs index-alias cursors (aAltMap).
    ----------------------------------------------------------------------- }

  TVdbeCursorUb = record
    case integer of
      0: (pBtx:    PBtree);  { ephemeral table's separate Btree handle }
      1: (aAltMap: Pu32);    { mapping from table column to index column }
  end;

  { -----------------------------------------------------------------------
    TVdbeCursorUc — union uc inside TVdbeCursor.
    C: union { BtCursor *pCursor; sqlite3_vtab_cursor *pVCur;
               VdbeSorter *pSorter; }
    ----------------------------------------------------------------------- }

  TVdbeCursorUc = record
    case integer of
      0: (pCursor: PBtCursor);              { CURTYPE_BTREE or CURTYPE_PSEUDO }
      1: (pVCur:   Psqlite3_vtab_cursor);   { CURTYPE_VTAB }
      2: (pSorter: PVdbeSorter);            { CURTYPE_SORTER }
  end;

  { -----------------------------------------------------------------------
    TVdbeCursor — superclass for b-tree, sorter, vtab, and pseudotable cursors.
    vdbeInt.h struct VdbeCursor.

    IMPORTANT: The flexible array aType[FLEXARRAY] at the END of the C struct
    is NOT declared here.  Callers must allocate the cursor with extra space:
      SZ_VDBECURSOR(n) = ROUND8(offsetof(VdbeCursor,aType)) + (n+1)*sizeof(u64)
    The Pascal equivalent is:
      SizeOf(TVdbeCursor) + (nField+1)*SizeOf(u64)
    rounded up to 8.

    C bitfield block (Bool isEphemeral:1..colCache:1) follows isTable (u8 at
    offset 4); GCC inserts 3 bytes padding to align the unsigned storage unit
    to 4 bytes.  FPC will also pad cursorFlags (u32) to 4-byte alignment after
    the 5-byte u8 run, producing identical offsets.

    Layout sanity (x86-64, sizeof(pointer)=8):
      Offset  0  u8  eCurType
      Offset  1  i8  iDb
      Offset  2  u8  nullRow
      Offset  3  u8  deferredMoveto
      Offset  4  u8  isTable
      [3 bytes FPC padding]
      Offset  8  u32 cursorFlags  (= C's Bool bitfields in one unsigned)
      Offset 12  u16 seekHit
      [2 bytes FPC padding to 8-align ub pointer]
      Offset 16  TVdbeCursorUb (8 bytes, pointer)
      Offset 24  i64 seqCount
      Offset 32  u32 cacheStatus
      Offset 36  i32 seekResult
      [no padding; pAltCursor is pointer at 8-aligned offset 40]
      Offset 40  PVdbeCursor pAltCursor
      Offset 48  TVdbeCursorUc (8 bytes, pointer)
      Offset 56  PKeyInfo
      Offset 64  u32 iHdrOffset
      Offset 68  Pgno pgnoRoot
      Offset 72  i16 nField
      Offset 74  u16 nHdrParsed
      [4 bytes FPC padding to 8-align movetoTarget]
      Offset 80  i64 movetoTarget
      Offset 88  Pu32 aOffset
      Offset 96  Pu8  aRow
      Offset 104 u32 payloadSize
      Offset 108 u32 szRow
      [no padding; pCache is pointer at offset 112, which is 8-aligned]
      Offset 112 PVdbeTxtBlbCache pCache
      Total fixed: 120 bytes; aType[] follows in extra allocation.
    ----------------------------------------------------------------------- }

  TVdbeCursor = record
    eCurType:       u8;            { CURTYPE_* value }
    iDb:            i8;            { index of db in db->aDb[] (signed) }
    nullRow:        u8;            { 1 if pointing at a row with no data }
    deferredMoveto: u8;            { 1 if sqlite3BtreeMoveto() is pending }
    isTable:        u8;            { 1 for rowid tables, 0 for indexes }
    { 3 bytes FPC alignment padding here before cursorFlags (u32) }
    cursorFlags:    u32;           { packed Bool bitfields — use VDBC_* }
    seekHit:        u16;           { OP_SeekHit / OP_IfNoHope result }
    { 2 bytes FPC alignment padding here before ub (pointer union) }
    ub:             TVdbeCursorUb; { ephemeral Btree or column-alias map }
    seqCount:       i64;           { sequence counter (OP_Sequence) }
    cacheStatus:    u32;           { cache valid iff == Vdbe.cacheCtr }
    seekResult:     i32;           { result of last sqlite3BtreeMoveto, or 0 }
    { Fields below are uninitialized at allocation; set before first use }
    pAltCursor:     PVdbeCursor;   { associated index cursor (read from) }
    uc:             TVdbeCursorUc; { the underlying cursor object }
    pKeyInfo:       PKeyInfo;      { key info for index cursors }
    iHdrOffset:     u32;           { next unparsed byte offset in header }
    pgnoRoot:       Pgno;          { root page of the open btree cursor }
    nField:         i16;           { number of fields in the header }
    nHdrParsed:     u16;           { number of header fields parsed }
    { 4 bytes FPC alignment padding here before movetoTarget (i64) }
    movetoTarget:   i64;           { arg to deferred sqlite3BtreeMoveto() }
    aOffset:        Pu32;          { pointer to aType[nField] area }
    aRow:           Pu8;           { row data if all on one page, else nil }
    payloadSize:    u32;           { total payload bytes in record }
    szRow:          u32;           { bytes available in aRow }
    pCache:         PVdbeTxtBlbCache; { large TEXT/BLOB value cache }
    { aType[FLEXARRAY] follows in extra-allocated space — NOT in this record }
  end;

  { -----------------------------------------------------------------------
    Tsqlite3_context — execution context for a user-defined SQL function.
    vdbeInt.h struct sqlite3_context.

    NOTE: The flexible array argv[FLEXARRAY] at the end is not declared here.
    Allocate with SZ_CONTEXT(N) = offsetof(sqlite3_context,argv) + N*sizeof(ptr).
    ----------------------------------------------------------------------- }

  Tsqlite3_context = record
    pOut:     PMem;            { return value stored here }
    pFunc:    PFuncDef;        { pointer to function definition }
    pMem:     PMem;            { memory cell for aggregate context }
    pVdbe:    PVdbe;           { VM that owns this context }
    iOp:      i32;             { instruction number of OP_Function }
    isError:  i32;             { error code returned by the function }
    enc:      u8;              { encoding to use for results }
    skipFlag: u8;              { skip accumulator loading if true }
    argc:     u16;             { number of arguments }
    { argv[FLEXARRAY] follows in extra-allocated space }
  end;

  { -----------------------------------------------------------------------
    TFuncDef — SQL function / aggregate descriptor (sqliteInt.h FuncDef).
    PFuncDef stays as Pointer for compatibility; cast to PTFuncDef to call
    through the function pointers in aggregate/scalar opcodes.
    Layout verified for x86_64 Linux (little-endian, 8-byte pointers).
    ----------------------------------------------------------------------- }
  TxSFuncProc  = procedure(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
  TxFinalProc  = procedure(pCtx: Psqlite3_context); cdecl;
  TxValueProc  = procedure(pCtx: Psqlite3_context); cdecl;
  TxInverseProc= procedure(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;

  TFuncDef = record
    nArg:      i16;              { offset  0: arg count (-1=unlimited); C uses i16 }
    _pad0:     u16;              { offset  2: pad to align funcFlags }
    funcFlags: u32;              { offset  4: SQLITE_FUNC_* flags }
    pUserData: Pointer;          { offset  8: user data for app-defined funcs }
    pNext:     Pointer;          { offset 16: next FuncDef with same name }
    xSFunc:    TxSFuncProc;      { offset 24: step (agg) or scalar function }
    xFinalize: TxFinalProc;      { offset 32: aggregate finalizer }
    xValue:    TxValueProc;      { offset 40: current window value }
    xInverse:  TxInverseProc;    { offset 48: inverse step (window) }
    zName:     PAnsiChar;        { offset 56: SQL name of the function }
    u:         Pointer;          { offset 64: pHash or pDestructor }
  end;                           { SizeOf = 72 bytes (GCC x86-64 verified) }
  PTFuncDef = ^TFuncDef;

  { TCollSeq — collating-sequence descriptor (sqliteInt.h CollSeq).
    GCC x86-64 layout: zName(8) + enc(1) + pad(7) + pUser(8) + xCmp(8) + xDel(8) = 40 bytes. }
  TxCollCmp  = function(pUser: Pointer; nA: i32; pA: Pointer;
                        nB: i32; pB: Pointer): i32; cdecl;
  TxCollDel  = procedure(pUser: Pointer); cdecl;
  TCollSeq = record
    zName:   PAnsiChar;    { offset  0: UTF-8 name }
    enc:     u8;           { offset  8: SQLITE_UTF8/UTF16LE/UTF16BE }
    _pad:    array[0..6] of Byte;  { offset 9..15: alignment }
    pUser:   Pointer;      { offset 16: first arg to xCmp }
    xCmp:    TxCollCmp;    { offset 24: comparison function }
    xDel:    TxCollDel;    { offset 32: destructor for pUser }
  end;                     { SizeOf = 40 bytes }
  PTCollSeq = ^TCollSeq;

  { TFuncDestructor — reference-counted destructor for user-defined functions.
    GCC x86-64: nRef(4) + pad(4) + xDestroy(8) + pUserData(8) = 24 bytes. }
  TxFuncDestroy = procedure(p: Pointer); cdecl;
  TFuncDestructor = record
    nRef:      i32;        { offset 0: reference count }
    _pad1:     u32;        { offset 4: alignment }
    xDestroy:  TxFuncDestroy; { offset 8 }
    pUserData: Pointer;    { offset 16 }
  end;                     { SizeOf = 24 bytes }
  PTFuncDestructor = ^TFuncDestructor;

  { TFuncDefHash — built-in function hash table (SQLITE_FUNC_HASH_SZ=23 slots). }
  SQLITE_FUNC_HASH_SZ_t = array[0..22] of PTFuncDef;
  TFuncDefHash = record
    a: SQLITE_FUNC_HASH_SZ_t;  { 23 * 8 = 184 bytes }
  end;
  PTFuncDefHash = ^TFuncDefHash;

  { SZ_CONTEXT(n) = ROUND8P(SizeOf(Tsqlite3_context)) + n * SizeOf(PMem)
    = ROUND8P(44) = 48 base, plus n*8 for argv pointers. }

  { -----------------------------------------------------------------------
    TVdbe — the virtual machine instance.
    vdbeInt.h struct Vdbe.

    Bitfield block at offset ~200:
      bft expired:2; explain:2; changeCntOn:1; usesStmtJournal:1;
      readOnly:1; bIsReader:1; haveEqpOps:1   (9 bits in one u32).
    Represented as vdbeFlags:u32 with VDBF_* constants.

    startTime (i64) is present when !SQLITE_OMIT_TRACE (default build).
    ----------------------------------------------------------------------- }

  TVdbe = record
    db:              Psqlite3;       { database connection that owns this stmt }
    ppVPrev:         PPVdbe;         { previous in db->pVdbe doubly-linked list }
    pVNext:          PVdbe;          { next in db->pVdbe list }
    pParse:          PParse;         { parse context used to create this Vdbe }
    nVar:            ynVar;          { number of OP_Variable slots }
    { 2 bytes FPC padding to align nMem (i32) }
    nMem:            i32;            { number of memory locations allocated }
    nCursor:         i32;            { number of slots in apCsr[] }
    cacheCtr:        u32;            { VdbeCursor row cache generation counter }
    pc:              i32;            { program counter }
    rc:              i32;            { current return value }
    nChange:         i64;            { db changes since last reset }
    iStatement:      i32;            { statement number (0 = no open stmt) }
    { 4 bytes FPC padding to align iCurrentTime (i64) }
    iCurrentTime:    i64;            { julianday('now') for this statement }
    nFkConstraint:   i64;            { immediate FK constraints this VM }
    nStmtDefCons:    i64;            { deferred constraints when stmt started }
    nStmtDefImmCons: i64;            { deferred imm constraints at start }
    aMem:            PMem;           { memory cells (nMem entries) }
    apArg:           PPMem;          { args to xUpdate/xFilter vtab methods }
    apCsr:           PPVdbeCursor;   { open cursors (nCursor slots) }
    aVar:            PMem;           { values for OP_Variable (nVar entries) }
    { Zero-initialised boundary — fields above zeroed at alloc; below not }
    aOp:             PVdbeOp;        { instruction array }
    nOp:             i32;            { instruction count }
    nOpAlloc:        i32;            { allocated slots in aOp[] }
    aColName:        PMem;           { column names to return }
    pResultRow:      PMem;           { current output row }
    zErrMsg:         PAnsiChar;      { error message }
    pVList:          PVList;         { variable names (VList int array) }
    startTime:       i64;            { query start time for profiling }
    nResColumn:      u16;            { columns in one row of result set }
    nResAlloc:       u16;            { column slots allocated in aColName[] }
    errorAction:     u8;             { OE_Abort/OE_Fail/… recovery action }
    minWriteFileFormat: u8;          { minimum file format for writes }
    prepFlags:       u8;             { SQLITE_PREPARE_* flags }
    eVdbeState:      u8;             { VDBE_*_STATE }
    vdbeFlags:       u32;            { packed bft bitfields — use VDBF_* }
    btreeMask:       yDbMask;        { bitmask of db->aDb[] entries referenced }
    lockMask:        yDbMask;        { subset of btreeMask requiring a lock }
    aCounter:        array[0..8] of u32; { sqlite3_stmt_status() counters }
    zSql:            PAnsiChar;      { SQL text that generated this stmt }
    zNormSql:        PAnsiChar;      { Normalization of the associated SQL (lazy) }
    pFree:           Pointer;        { free this when deleting the Vdbe }
    pFrame:          PVdbeFrame;     { currently executing sub-frame (nil=main) }
    pDelFrame:       PVdbeFrame;     { sub-frames to free on VM reset }
    nFrame:          i32;            { count of frames in pFrame chain }
    expmask:         u32;            { binding changes that invalidate VM }
    pProgram:        PSubProgram;    { all sub-programs used by this VM }
    pAuxData:        PAuxData;       { linked list of auxdata allocations }
    { Phase 8.2.1 — sqlite3_stmt_scanstatus() data.  Mirrors C
      vdbeInt.h:526..527 gated on SQLITE_ENABLE_STMT_SCANSTATUS;
      unconditional here so .scanstats works without a rebuild flag. }
    nScan:           i32;            { entries in aScan[] }
    aScan:           PScanStatus;    { per-loop scan definitions }
    { SQLITE_ENABLE_NORMALIZE (vdbeInt.h) — list of double-quoted strings
      that were resolved as string literals, so sqlite3Normalize can tell
      them apart from real identifiers. }
    pDblStr:         PDblquoteStr;   { all DQS literals seen during resolve }
  end;

  { -----------------------------------------------------------------------
    TValueList — vector of values for OP_VFilter IN constraint.
    vdbeInt.h struct ValueList.
    Passed to xFilter as an sqlite3_value with MEM_Term|MEM_Subtype|MEM_Null
    and subtype 'p'; read by sqlite3_vtab_in_first() / _next().
    ----------------------------------------------------------------------- }

  TValueList = record
    pCsr: PBtCursor;       { ephemeral table holding all IN values }
    pOut: PMem;            { register to hold each decoded output value }
  end;

  { -----------------------------------------------------------------------
    TIncrblob — incremental blob I/O handle (vdbeblob.c Phase 5.6).
    sqlite3_blob* opaque pointer maps to Psqlite3_blob = PIncrblob.
    ----------------------------------------------------------------------- }
  TIncrblob = record
    nByte:   i32;          { size of open blob, in bytes }
    iOffset: i32;          { byte offset of blob in cursor payload }
    iCol:    u16;          { table column this handle is open on }
    pCsr:    PBtCursor;    { cursor pointing at blob row }
    pStmt:   PVdbe;        { statement holding cursor open }
    db:      PTsqlite3;    { the associated database }
    zDb:     PAnsiChar;    { database name }
    pTab:    Pointer;      { Table* (Phase 6) }
  end;

  { -----------------------------------------------------------------------
    Phase 5.7 — vdbesort.c external sorter types (C-faithful layout).
    Ported 1:1 from ../sqlite3/src/vdbesort.c:173..461.  Single-threaded
    subset (SQLITE_MAX_WORKER_THREADS==0): thread fields are declared for
    layout fidelity but unused.  Function bodies for the PMA disk-spill
    subsystem land in Phase 5.7.b.2..b.9.
    ----------------------------------------------------------------------- }

  { typedef int (*SorterCompare)(SortSubtask*,int*,const void*,int,
                                 const void*,int);  vdbesort.c:294 }
  TSorterCompare = function(pTask: PSortSubtask; pbKey2Cached: Pi32;
    pKey1: Pointer; nKey1: i32; pKey2: Pointer; nKey2: i32): i32; cdecl;

  { struct SorterFile — vdbesort.c:173 }
  PSorterFile = ^TSorterFile;
  TSorterFile = record
    pFd:  Psqlite3_file;   { file handle }
    iEof: i64;             { bytes of data stored in pFd }
  end;
  PPsqlite3_file = ^Psqlite3_file;  { sqlite3_file** out-param helper }
  PPByte         = ^PByte;          { u8** out-param helper }

  { struct SorterList — vdbesort.c:186 }
  PSorterList = ^TSorterList;
  TSorterList = record
    pList:   PSorterRecord; { linked list of records }
    aMemory: Pu8;          { bulk memory for pList (nil if individual allocs) }
    szPMA:   i64;          { size of pList as PMA in bytes }
  end;

  { struct MergeEngine — vdbesort.c:256 }
  TMergeEngine = record
    nTree:  i32;           { used size of aTree/aReadr (power of 2) }
    pTask:  PSortSubtask;  { used by this thread only }
    aTree:  Pi32;          { current state of incremental merge }
    aReadr: PPmaReader;    { array of PmaReaders to merge data from }
  end;

  { struct PmaReader — vdbesort.c:354 }
  TPmaReader = record
    iReadOff: i64;         { current read offset }
    iEof:     i64;         { 1 byte past EOF for this PmaReader }
    nAlloc:   i32;         { bytes of space at aAlloc }
    nKey:     i32;         { number of bytes in key }
    pFd:      Psqlite3_file; { file handle we are reading from }
    aAlloc:   Pu8;         { space for aKey if aBuffer/pMap wont work }
    aKey:     Pu8;         { pointer to current key }
    aBuffer:  Pu8;         { current read buffer }
    nBuffer:  i32;         { size of read buffer in bytes }
    aMap:     Pu8;         { pointer to mapping of entire file }
    pIncr:    PIncrMerger; { incremental merger }
  end;

  { struct IncrMerger — vdbesort.c:400 (single-threaded: aFile[1] unused) }
  TIncrMerger = record
    pTask:      PSortSubtask;        { task that owns this merger }
    pMerger:    PMergeEngine;        { merge engine thread reads data from }
    iStartOff:  i64;                 { offset to start writing file at }
    mxSz:       i32;                 { maximum bytes of data to store }
    bEof:       i32;                 { set true when merge is finished }
    bUseThread: i32;                 { true to use a bg thread (unused here) }
    aFile:      array[0..1] of TSorterFile; { [0]=reading, [1]=writing }
  end;

  { struct PmaWriter — vdbesort.c:418 }
  TPmaWriter = record
    eFWErr:    i32;        { non-zero if in an error state }
    aBuffer:   Pu8;        { pointer to write buffer }
    nBuffer:   i32;        { size of write buffer in bytes }
    iBufStart: i32;        { first byte of buffer to write }
    iBufEnd:   i32;        { last byte of buffer to write }
    iWriteOff: i64;        { offset of start of buffer in file }
    pFd:       Psqlite3_file; { file handle to write to }
    nPmaSpill: u64;        { total number of bytes written }
  end;

  { struct SortSubtask — vdbesort.c:295 }
  TSortSubtask = record
    pThread:   Pointer;        { SQLiteThread* — threads unused }
    bDone:     i32;            { set if thread is finished but not joined }
    nPMA:      i32;            { number of PMAs currently in file }
    pSorter:   PVdbeSorter;    { sorter that owns this sub-task }
    pUnpacked: PUnpackedRecord; { space to unpack a record }
    list:      TSorterList;    { list for thread to write to a PMA }
    xCompare:  TSorterCompare; { compare function to use }
    file_:     TSorterFile;    { temp file for level-0 PMAs (C: file) }
    file2:     TSorterFile;    { space for other PMAs }
    nSpill:    u64;            { total bytes written by this task }
  end;

  { struct VdbeSorter — vdbesort.c:318.  C has SortSubtask aTask[FLEXARRAY]
    as the trailing field; this port is single-threaded (nTask always 1)
    so a single inline aTask suffices. }
  TVdbeSorter = record
    mnPmaSize:   i32;      { minimum PMA size, in bytes }
    mxPmaSize:   i32;      { maximum PMA size, in bytes; 0=no limit }
    mxKeysize:   i32;      { largest serialised key seen so far }
    pgsz:        i32;      { main database page size }
    pReader:     PPmaReader;  { read data from here after Rewind() }
    pMerger:     PMergeEngine; { or here, if bUseThreads=0 }
    db:          PTsqlite3; { database connection }
    pKeyInfo:    PKeyInfo; { how to compare records }
    pUnpacked:   PUnpackedRecord; { used by VdbeSorterCompare }
    list:        TSorterList; { in-memory record list }
    iMemory:     i32;      { offset of free space in list.aMemory }
    nMemory:     i32;      { size of list.aMemory allocation }
    bUsePMA:     u8;       { true if one or more PMAs created }
    bUseThreads: u8;       { true to use background threads }
    iPrev:       u8;       { previous thread used to flush PMA }
    nTask:       u8;       { size of aTask array }
    typeMask:    u8;       { SORTER_TYPE_INTEGER|TEXT mask }
    aTask:       TSortSubtask; { one or more subtasks (single-threaded: 1) }
  end;

  { struct SorterRecord — vdbesort.c:447.  C-faithful layout:
      nVal:i32 @0; union{pNext:PSorterRecord|iNext:i32} @8 (8-byte ptr
      alignment forces 4 pad bytes @4); record data follows the header so
      SRVAL(p)=PByte(p)+SizeOf(TSorterRecord)=p+16. }
  TSorterRecord = record
    nVal: i32;             { size of the record in bytes (@0) }
    u: record             { union u — vdbesort.c:449..452 (@8) }
      case Integer of
        0: (pNext: PSorterRecord);  { pointer to next record in list }
        1: (iNext: i32);            { offset within aMemory of next record }
    end;
    { the data for the record immediately follows this header (SRVAL) }
  end;

const
  { vdbesort.c constants (Phase 5.7.b.1) }
  SQLITE_MAX_PMASZ       = (1 shl 29); { 512MiB — vdbesort.c:155 }
  SORTER_TYPE_INTEGER    = $01;        { vdbesort.c:342 }
  SORTER_TYPE_TEXT       = $02;        { vdbesort.c:343 }
  SORTER_MAX_MERGE_COUNT = 16;         { vdbesort.c:465 }
  INCRINIT_NORMAL        = 0;          { vdbesort.c:2115 }
  INCRINIT_TASK          = 1;          { vdbesort.c:2116 }
  INCRINIT_ROOT          = 2;          { vdbesort.c:2117 }
  { sizeof(SorterRecord)=16; record data starts here — SRVAL(p)=p+16 }
  SZ_SORTER_RECORD       = 16;

{ SRVAL(p) — vdbesort.c:461 — pointer to record data after the header. }
function SRVAL(p: PSorterRecord): Pointer; inline;

  { -----------------------------------------------------------------------
    Phase 5.4j — RowSet types (rowset.c).
    A RowSet is a set of rowids; supports INSERT, TEST (by batch), and
    SMALLEST (sequential extraction in sorted order).
    ----------------------------------------------------------------------- }

const
  ROWSET_ALLOCATION_SIZE = 1024;
  ROWSET_ENTRY_PER_CHUNK = (ROWSET_ALLOCATION_SIZE - 8) div 24;
  ROWSET_SORTED = $01;
  ROWSET_NEXT   = $02;

type
  PRowSetEntry  = ^TRowSetEntry;
  PPRowSetEntry = ^PRowSetEntry;
  TRowSetEntry = record
    v:      i64;
    pRight: PRowSetEntry;
    pLeft:  PRowSetEntry;
  end;

  PRowSetChunk = ^TRowSetChunk;
  TRowSetChunk = record
    pNextChunk: PRowSetChunk;
    aEntry:     array[0..ROWSET_ENTRY_PER_CHUNK-1] of TRowSetEntry;
  end;

  PRowSet = ^TRowSet;
  TRowSet = record
    pChunk:  PRowSetChunk;
    db:      PTsqlite3;
    pEntry:  PRowSetEntry;
    pLast:   PRowSetEntry;
    pFresh:  PRowSetEntry;
    pForest: PRowSetEntry;
    iFstresh:  u16;
    rsFlags: u16;
    iBatch:  i32;
  end;

{ ============================================================================
  vdbeaux.c — program assembly, lifecycle, serial types (Phase 5.2)
  vdbemem.c  — Mem value type (Phase 5.3)
  vdbeapi.c  — public API (Phase 5.5)
  vdbe.c     — execution engine (Phase 5.4)
  vdbetrace.c — EXPLAIN renderer (Phase 5.8)
  ============================================================================ }

{ --- Program assembly (vdbeaux.c) --- }
function  sqlite3VdbeCreate(pParse: PParse): PVdbe;
function  sqlite3VdbeParser(p: PVdbe): PParse;
procedure sqlite3VdbeError(p: PVdbe; zFormat: PAnsiChar);
procedure sqlite3VdbeSetSql(p: PVdbe; z: PAnsiChar; n: i32; prepFlags: u8);
procedure sqlite3VdbeSwap(pA, pB: PVdbe);
function  sqlite3VdbeAddOp0(v: PVdbe; op: i32): i32;
function  sqlite3VdbeAddOp1(v: PVdbe; op, p1: i32): i32;
function  sqlite3VdbeAddOp2(v: PVdbe; op, p1, p2: i32): i32;
function  sqlite3VdbeAddOp3(v: PVdbe; op, p1, p2, p3: i32): i32;
function  sqlite3VdbeAddOp4Int(v: PVdbe; op, p1, p2, p3, p4: i32): i32;
function  sqlite3VdbeAddOp4(v: PVdbe; op, p1, p2, p3: i32;
                            zP4: PAnsiChar; p4type: i32): i32;
function  sqlite3VdbeAddOp4Dup8(v: PVdbe; op, p1, p2, p3: i32;
                                pP4: Pu8; p4type: i32): i32;
function  sqlite3VdbeGoto(v: PVdbe; iDest: i32): i32;
function  sqlite3VdbeLoadString(p: PVdbe; iDest: i32; zStr: PAnsiChar): i32;
procedure sqlite3VdbeMultiLoad(p: PVdbe; iDest: i32; zTypes: PAnsiChar;
                               const args: array of const);
function  sqlite3VdbeAddFunctionCall(pParse: PParse; p1: i32; p2, p3: i32;
                                    nArg: i32; pFunc: PFuncDef; p5: i32): i32;
function  sqlite3NotPureFunc(pCtx: Psqlite3_context): i32;
function  sqlite3VdbeExplainParent(pParse: PParse): i32;
procedure sqlite3ExplainBreakpoint(z1, z2: PAnsiChar);
function  sqlite3VdbeExplain(pParse: PParse; bPush: u8; zFmt: PAnsiChar;
                             const args: array of const): i32;
procedure sqlite3VdbeExplainPop(pParse: PParse);
procedure sqlite3VdbeAddParseSchemaOp(p: PVdbe; iDb: i32; zWhere: PAnsiChar; p5: u16);
procedure sqlite3VdbeEndCoroutine(v: PVdbe; regYield: i32);
function  sqlite3VdbeMakeLabel(pParse: PParse): i32;
procedure sqlite3VdbeResolveLabel(v: PVdbe; x: i32);
procedure sqlite3VdbeRunOnlyOnce(p: PVdbe);
procedure sqlite3VdbeReusable(p: PVdbe);
function  sqlite3VdbeAssertMayAbort(v: PVdbe; mayAbort: i32): i32;
procedure sqlite3VdbeIncrWriteCounter(p: PVdbe; pC: PVdbeCursor);
procedure sqlite3VdbeCountChanges(v: PVdbe);
procedure sqlite3VdbeAssertAbortable(p: PVdbe);
procedure sqlite3VdbeNoJumpsOutsideSubrtn(v: PVdbe; iFstirst, iLast: i32;
                                          regReturn: i32);
function  sqlite3VdbeCurrentAddr(p: PVdbe): i32;
procedure sqlite3VdbeVerifyNoMallocRequired(p: PVdbe; N: i32);
procedure sqlite3VdbeVerifyNoResultRow(p: PVdbe);
procedure sqlite3VdbeVerifyAbortable(p: PVdbe; onError: i32);
function  sqlite3VdbeTakeOpArray(p: PVdbe; pnOp: Pi32; pnMaxArg: Pi32): PVdbeOp;
function  sqlite3VdbeAddOpList(p: PVdbe; nOp: i32; aOp: PVdbeOpList;
                               iLineno: i32): PVdbeOp;
procedure sqlite3VdbeScanStatus(p: PVdbe; addrExplain, addrLoop, addrVisit: i32;
                                nEst: LogEst; zName: PAnsiChar);
procedure sqlite3VdbeScanStatusRange(p: PVdbe; addrExplain, addrStart, addrEnd: i32);
procedure sqlite3VdbeScanStatusCounters(p: PVdbe; addrExplain, addrLoop, addrVisit: i32);
procedure sqlite3VdbeChangeOpcode(p: PVdbe; addr: i32; iNewOpcode: u8);
procedure sqlite3VdbeChangeP1(p: PVdbe; addr, val: i32);
procedure sqlite3VdbeChangeP2(p: PVdbe; addr, val: i32);
procedure sqlite3VdbeChangeP3(p: PVdbe; addr, val: i32);
procedure sqlite3VdbeChangeP5(p: PVdbe; p5: u16);
procedure sqlite3VdbeSetVarmask(v: PVdbe; iVar: i32);
function  sqlite3VdbeGetBoundValue(v: PVdbe; iVar: i32; aff: u8): Psqlite3_value;
procedure sqlite3VdbeTypeofColumn(p: PVdbe; iDest: i32);
procedure sqlite3VdbeJumpHere(p: PVdbe; addr: i32);
procedure sqlite3VdbeJumpHereOrPopInst(p: PVdbe; addr: i32);
procedure sqlite3VdbeLinkSubProgram(pVdbe: PVdbe; pSub: PSubProgram);
function  sqlite3VdbeHasSubProgram(pVdbe: PVdbe): i32;
function  sqlite3VdbeChangeToNoop(p: PVdbe; addr: i32): i32;
function  sqlite3VdbeDeletePriorOpcode(p: PVdbe; op: u8): i32;
procedure sqlite3VdbeReleaseRegisters(pParse: PParse; iFstirst, nReg, mask: i32;
                                      bUndefine: i32);
procedure sqlite3VdbeChangeP4(p: PVdbe; addr: i32; zP4: PAnsiChar; n: i32);
procedure sqlite3VdbeAppendP4(p: PVdbe; pP4: Pointer; n: i32);
procedure sqlite3VdbeSetP4KeyInfo(pParse: PParse; pIdx: PIndex);
procedure sqlite3VdbeComment(p: PVdbe; zFormat: PAnsiChar);
procedure sqlite3VdbeNoopComment(p: PVdbe; zFormat: PAnsiChar);
procedure sqlite3VdbeSetLineNumber(v: PVdbe; iLine: i32);
function  sqlite3VdbeGetOp(p: PVdbe; addr: i32): PVdbeOp;
function  sqlite3VdbeGetLastOp(p: PVdbe): PVdbeOp;
function  sqlite3VdbeDisplayComment(db: Psqlite3; pOp: PVdbeOp; zP4: PAnsiChar): PAnsiChar;
function  sqlite3VdbeDisplayP4(db: Psqlite3; pOp: PVdbeOp): PAnsiChar;
procedure sqlite3VdbeUsesBtree(p: PVdbe; i: i32);
procedure sqlite3VdbeEnter(p: PVdbe);
procedure sqlite3VdbeLeave(p: PVdbe);
procedure sqlite3VdbePrintOp(pOut: Pointer; pc: i32; pOp: PVdbeOp);
function  sqlite3VdbeFrameIsValid(pFrame: PVdbeFrame): i32;
procedure sqlite3VdbeFrameMemDel(pArg: Pointer); cdecl;
function  sqlite3VdbeNextOpcode(p: PVdbe; pSub: PMem; eMode: i32;
                                piPc: Pi32; piAddr: Pi32; paOp: PPVdbeOp): i32;
procedure sqlite3VdbeFrameDelete(p: PVdbeFrame);
function  sqlite3VdbeList(v: PVdbe): i32;
procedure sqlite3VdbePrintSql(p: PVdbe);
procedure sqlite3VdbeIOTraceSql(p: PVdbe);
procedure sqlite3VdbeRewind(p: PVdbe);
procedure sqlite3VdbeMakeReady(p: PVdbe; pParse: PParse);
procedure sqlite3VdbeFreeCursor(p: PVdbe; pCx: PVdbeCursor);
procedure sqlite3VdbeFreeCursorNN(p: PVdbe; pCx: PVdbeCursor);
function  sqlite3VdbeFrameRestore(pFrame: PVdbeFrame): i32;
procedure sqlite3VdbeSetNumCols(p: PVdbe; nResColumn: i32);
function  sqlite3VdbeSetColName(p: PVdbe; idx, var2: i32; zName: PAnsiChar;
                                xDel: TxDelProc): i32;
function  sqlite3VdbeCloseStatement(p: PVdbe; eOp: i32): i32;
function  sqlite3VdbeCheckFkImmediate(p: PVdbe): i32;
function  sqlite3VdbeCheckFkDeferred(p: PVdbe): i32;
function  sqlite3VdbeHalt(v: PVdbe): i32;
procedure sqlite3VdbeResetStepResult(p: PVdbe);
function  sqlite3VdbeTransferError(p: PVdbe): i32;
function  sqlite3VdbeReset(p: PVdbe): i32;
function  sqlite3VdbeFinalize(p: PVdbe): i32;
procedure sqlite3VdbeDeleteAuxData(db: Psqlite3; pp: PPAuxData; iOp, mask: i32);
procedure sqlite3VdbeDelete(p: PVdbe);

{ --- vdbeapi.c — sqlite3_context introspection + auxdata (Phase 6.8.g) --- }
function  sqlite3_context_db_handle(p: Psqlite3_context): Psqlite3;
function  sqlite3_vtab_nochange(p: Psqlite3_context): i32;
function  sqlite3_vtab_in_first(pVal: PMem; ppOut: PPMem): i32;
function  sqlite3_vtab_in_next(pVal: PMem; ppOut: PPMem): i32;
function  sqlite3_get_auxdata(pCtx: Psqlite3_context; iArg: i32): Pointer;
procedure sqlite3_set_auxdata(pCtx: Psqlite3_context; iArg: i32;
                              pAux: Pointer; xDelete: TxDelProc);

{ --- vdbeapi.c — additional context API (Phase 6.8.h.1) --- }
function  sqlite3_user_data(pCtx: Psqlite3_context): Pointer;
procedure sqlite3_result_subtype(pCtx: Psqlite3_context; eSubtype: u32);
procedure sqlite3_result_text64(pCtx: Psqlite3_context; z: PAnsiChar;
                                n: u64; xDel: TxDelProc; enc: u8);
procedure sqlite3_result_text16(pCtx: Psqlite3_context; z: Pointer;
                                n: i32; xDel: TxDelProc);
procedure sqlite3_result_text16be(pCtx: Psqlite3_context; z: Pointer;
                                  n: i32; xDel: TxDelProc);
procedure sqlite3_result_text16le(pCtx: Psqlite3_context; z: Pointer;
                                  n: i32; xDel: TxDelProc);
procedure sqlite3_result_error16(pCtx: Psqlite3_context; z: Pointer; n: i32);
function  sqlite3VdbeFinishMoveto(p: PVdbeCursor): i32;
function  sqlite3VdbeHandleMovedCursor(p: PVdbeCursor): i32;
function  sqlite3VdbeCursorRestore(p: PVdbeCursor): i32;

{ --- Serial type helpers (vdbeaux.c) --- }
function  sqlite3VdbeSerialType(pMem: PMem; file_format: i32; pLen: Pu32): u32;
function  sqlite3VdbeSerialTypeLen(serialType: u32): u32;
function  sqlite3VdbeOneByteSerialTypeLen(serialType: u8): u8;
function  sqlite3VdbeSerialPut(buf: Pu8; pMem: PMem; serial_type: u32): u32;
procedure sqlite3VdbeSerialGet(buf: Pu8; serialType: u32; pMem: PMem); inline;
function  sqlite3VdbeRecordUnpack(pKeyInfo: PKeyInfo; nKey: i32; pKey: Pointer;
                                  p: Pointer): Pointer; inline; { returns UnpackedRecord* }
function  sqlite3VdbeAllocUnpackedRecord(pKeyInfo: PKeyInfo): Pointer;
function  sqlite3VdbeRecordCompareWithSkip(nKey1: i32; pKey1: Pointer;
                                           pPKey2: Pointer; bSkip: i32): i32;
function  sqlite3VdbeRecordCompare(nKey1: i32; pKey1: Pointer;
                                   pPKey2: Pointer): i32;
function  sqlite3VdbeFindCompare(pKey: Pointer): Pointer; { returns RecordCompare fn }

{ Opcode name lookup (vdbeaux.c, used for EXPLAIN) }
function  sqlite3OpcodeName(n: i32): PAnsiChar;

{ Phase 7.4c — opcode-trace capture buffer.  When db^.flags has
  SQLITE_VdbeTrace set, sqlite3VdbeExec appends one line per executed
  opcode to gVdbeTraceBuf in the form '<pc> <opname> <p1> <p2> <p3> <p5>'#10.
  The C reference (with SQLITE_DEBUG) writes the full trace to stdout via
  sqlite3VdbePrintOp; TestVdbeTrace.pas captures the C stdout and parses
  the same five fields per line for differential comparison. }
var
  gVdbeTraceBuf: AnsiString;

{ Phase 9.1.6 — opcode coverage counters.  When gVdbeOpCoverageEnabled
  is non-zero the dispatch loop bumps gVdbeOpCoverage[opcode] once per
  step.  Default-off (zero) so non-coverage builds pay one branch per
  step.  Consumers (bin/TestSQLCorpus --coverage) flip the flag, run
  the corpus, then walk the array and assert every opcode reachable
  from passqlite3codegen is non-zero.  See tasklist 9.1.6. }
const
  SQLITE_NUM_OPCODES = 192;  { 0..191 inclusive (vdbe.pas:67). }
var
  gVdbeOpCoverage: array[0..SQLITE_NUM_OPCODES - 1] of u64;
  gVdbeOpCoverageEnabled: i32;

{ sqlite3BuiltinFunctions — global table of built-in SQL functions (callback.c).
  Initialized by sqlite3RegisterBuiltinFunctions. }
var
  sqlite3BuiltinFunctions: TFuncDefHash;

{ --- vdbemem.c — Mem value operations (Phase 5.3) --- }
{ SQLITE_DYNAMIC / SQLITE_TRANSIENT: sentinel destructor values.
  Declared as vars because FPC typed constants cannot hold arbitrary
  pointer-sized integer values in procedure pointer fields. }
var
  SQLITE_DYNAMIC:   TxDelProc;   { = sqlite3_free (function pointer) }
  SQLITE_TRANSIENT: TxDelProc;   { = TxDelProc(Pointer(-1)) sentinel }

procedure sqlite3VdbeMemInit(pMem: PMem; db: Psqlite3; flags: u16);
procedure sqlite3VdbeMemSetNull(pMem: PMem);
procedure sqlite3ValueSetNull(v: Psqlite3_value);
procedure sqlite3VdbeMemSetInt64(pMem: PMem; val: i64);
procedure sqlite3MemSetArrayInt64(aMem: Psqlite3_value; iIdx: i32; val: i64);
procedure sqlite3VdbeMemSetDouble(pMem: PMem; val: Double);
procedure sqlite3VdbeMemSetZeroBlob(pMem: PMem; n: i32);
procedure sqlite3VdbeMemSetPointer(pMem: PMem; pPtr: Pointer;
                                   zPType: PAnsiChar;
                                   xDestructor: TxDelProc);
procedure sqlite3NoopDestructor(p: Pointer); cdecl;
procedure sqlite3VdbeValueListFree(p: Pointer); cdecl;
function  sqlite3VdbeMemSetStr(pMem: PMem; z: PAnsiChar; n: i64;
                               enc: u8; xDel: TxDelProc): i32;
function  sqlite3VdbeMemSetText(pMem: PMem; z: PAnsiChar; n: i64;
                                xDel: TxDelProc): i32;
function  sqlite3VdbeMemGrow(pMem: PMem; n: i32; bPreserve: i32): i32;
function  sqlite3VdbeMemClearAndResize(pMem: PMem; szNew: i32): i32;
function  sqlite3VdbeMemZeroTerminateIfAble(pMem: PMem): i32;
function  sqlite3VdbeMemMakeWriteable(pMem: PMem): i32;
function  sqlite3VdbeMemExpandBlob(pMem: PMem): i32;
function  sqlite3VdbeMemNulTerminate(pMem: PMem): i32;
function  sqlite3VdbeMemStringify(pMem: PMem; enc: u8; bForce: u8): i32;
procedure sqlite3VdbeMemRelease(pMem: PMem);
procedure sqlite3VdbeMemReleaseMalloc(pMem: PMem);
function  sqlite3VdbeMemCopy(pTo: PMem; const pFrom: PMem): i32;
procedure sqlite3VdbeMemShallowCopy(pTo: PMem; const pFrom: PMem; srcType: i32);
procedure sqlite3VdbeMemMove(pTo: PMem; pFrom: PMem);
function  sqlite3VdbeMemNumerify(pMem: PMem): i32;
function  sqlite3VdbeIntValue(const pMem: PMem): i64;
function  sqlite3MemRealValueRC(pMem: PMem; out pValue: Double): i32;
function  sqlite3VdbeRealValue(pMem: PMem): Double;
function  sqlite3VdbeBooleanValue(pMem: PMem; ifNull: i32): i32;
procedure sqlite3VdbeIntegerAffinity(pMem: PMem);
function  sqlite3VdbeMemIntegerify(pMem: PMem): i32;
function  sqlite3VdbeMemRealify(pMem: PMem): i32;
function  sqlite3VdbeMemCast(pMem: PMem; aff: u8; encoding: u8): i32;
function  sqlite3RealSameAsInt(r1: Double; i: sqlite3_int64): i32;
function  sqlite3RealToI64(r: Double): i64;
function  sqlite3VdbeMemTooBig(p: PMem): i32;
function  sqlite3VdbeMemFromBtree(pCur: PBtCursor; offset: u32;
                                  amt: u32; pMem: PMem): i32;
function  sqlite3VdbeMemFromBtreeZeroOffset(pCur: PBtCursor;
                                            amt: u32; pMem: PMem): i32;
function  sqlite3VdbeMemFinalize(pMem: PMem; pFunc: PFuncDef): i32;
function  sqlite3VdbeMemAggValue(pAccum: PMem; pOut: PMem; pFunc: PFuncDef): i32;
function  sqlite3MemCompare(pMem1, pMem2: PMem; pColl: Pointer): i32;
function  sqlite3VdbeCompareMemStringEncChg(pMem1, pMem2: PMem;
                                            pColl: PTCollSeq;
                                            prcErr: Pu8): i32;
function  sqlite3AddInt64(pA: Pi64; iB: i64): i32;
function  sqlite3VdbeMemSetRowSet(pMem: PMem): i32;
function  sqlite3VdbeMemIsRowSet(pMem: PMem): i32;

{ --- RowSet functions (rowset.c Phase 5.4j) --- }
function  sqlite3RowSetAlloc(db: PTsqlite3): PRowSet;
procedure sqlite3RowSetClear(pSet: PRowSet);
procedure sqlite3RowSetDelete(pSet: PRowSet);
procedure sqlite3RowSetInsert(pSet: PRowSet; rowid: i64);
function  sqlite3RowSetTest(pSet: PRowSet; iBatch: i32; rowid: i64): i32;
function  sqlite3RowSetNext(pSet: PRowSet; pRowid: Pi64): i32;

{ --- Phase 5.4 — high-level stubs needed by opcodes --- }
procedure sqlite3ExpirePreparedStatements(db: PTsqlite3; iCode: i32);
function  sqlite3AnalysisLoad(db: PTsqlite3; iDb: i32): i32;
procedure sqlite3UnlinkAndDeleteTable(db: PTsqlite3; iDb: i32; zTabName: PAnsiChar);
procedure sqlite3UnlinkAndDeleteIndex(db: PTsqlite3; iDb: i32; zIdxName: PAnsiChar);
procedure sqlite3UnlinkAndDeleteTrigger(db: PTsqlite3; iDb: i32; zTrigName: PAnsiChar);
procedure sqlite3RootPageMoved(db: PTsqlite3; iDb: i32; iFstrom: i32; iTo: i32);
procedure sqlite3FkClearTriggerCache(db: PTsqlite3; iDb: i32);

{ Hook variables registered by passqlite3codegen at unit-init time so that
  the OP_Destroy / OP_DropTable / OP_DropIndex / OP_DropTrigger opcode
  handlers reach the real schema-cleanup ports (which live in codegen.pas
  and depend on PTable2/PIndex2/PTrigger types not visible to this unit).
  Default nil → opcode handlers degrade to no-ops, matching prior stub
  behaviour for codegen-less test programs. }
type
  TUnlinkAndDeleteFn = procedure(db: PTsqlite3; iDb: i32; zName: PAnsiChar);
  TRootPageMovedFn   = procedure(db: PTsqlite3; iDb: i32; iFrom, iTo: i32);
  TFkClearTriggerCacheFn = procedure(db: PTsqlite3; iDb: i32);
  TSetP4KeyInfoFn    = procedure(pParse: PParse; pIdx: PIndex);
  TResetOneSchemaFn  = procedure(db: PTsqlite3; iDb: i32);
  TResetAllSchemasFn = procedure(db: PTsqlite3);
  TDisplayP4Fn       = function(db: Psqlite3; pOp: PVdbeOp): PAnsiChar;
  TAnalysisLoadFn    = function(db: PTsqlite3; iDb: i32): i32;
  TBlobOpenFn        = function(db: PTsqlite3; zDb, zTable, zColumn: PAnsiChar;
                                iRow: i64; flags: i32;
                                out ppBlob: Psqlite3_blob): i32;
  TBlobReopenFn      = function(pBlob: Psqlite3_blob; iRow: i64): i32;
  TGetTokenFn        = function(z: PByte; tokenType: Pi32): i64;
  { pCtx is PValueNewStat4Ctx (declared later in this unit).  Typed as
    raw Pointer here because TValueFromExprFn precedes that declaration. }
  TValueFromExprFn   = function(db: Psqlite3; pExpr: Pointer;
                                enc: u8; affinity: u8;
                                out ppVal: Psqlite3_value;
                                pCtx: Pointer): i32;
  TKeyInfoUnrefFn    = procedure(p: Pointer);
{$IFDEF SQLITE_ENABLE_STAT4}
  { Trampoline for the codegen-private pair (pIdx^.nColumn + sqlite3KeyInfoOfIndex)
    used by valueNew()'s STAT4 arm.  Returns the index's nColumn (rowid included);
    writes the *unreffed* KeyInfo pointer (or nil on OOM) into ppKeyInfo.  vdbe.pas
    cannot reach PIndex2/PKeyInfo2 layouts directly. }
  TKeyInfoOfIndexFn  = function(pParse: PParse; pIdx: PIndex;
                                out ppKeyInfo: Pointer): i32;
{$ENDIF}
  TPrepareV2Fn       = function(db: PTsqlite3; zSql: PAnsiChar; nBytes: i32;
                                ppStmt: PPointer;
                                pzTail: PPointer): i32; cdecl;
  TRepreparFn        = function(p: PVdbe): i32;
var
  gUnlinkAndDeleteTable:   TUnlinkAndDeleteFn;
  gUnlinkAndDeleteIndex:   TUnlinkAndDeleteFn;
  gUnlinkAndDeleteTrigger: TUnlinkAndDeleteFn;
  gRootPageMoved:          TRootPageMovedFn;
  gFkClearTriggerCache:    TFkClearTriggerCacheFn;
  gSetP4KeyInfo:           TSetP4KeyInfoFn;
  gResetOneSchema:         TResetOneSchemaFn;
  gResetAllSchemas:        TResetAllSchemasFn;
  gDisplayP4:              TDisplayP4Fn;
  gAnalysisLoad:           TAnalysisLoadFn;
  gBlobOpenImpl:           TBlobOpenFn;
  gBlobReopenImpl:         TBlobReopenFn;
  gGetTokenImpl:           TGetTokenFn;  { wired by passqlite3parser at init;
                                            used by sqlite3VdbeExpandSql to scan
                                            host-parameter tokens. }
  gValueFromExprImpl:      TValueFromExprFn;  { wired by passqlite3codegen —
                                                 needs PExpr layout. }
  gKeyInfoUnref:           TKeyInfoUnrefFn;  { wired by passqlite3codegen —
                                                releases per-BtShared KeyInfo cache. }
{$IFDEF SQLITE_ENABLE_STAT4}
  gKeyInfoOfIndex:         TKeyInfoOfIndexFn;  { wired by passqlite3codegen —
                                                  STAT4 valueNew dependency.
                                                  Returns pIdx^.nColumn; out
                                                  ppKeyInfo := KeyInfo (unref'd). }
{$ENDIF}
  gPrepareV2:              TPrepareV2Fn;     { wired by passqlite3main — used
                                                by pragmaVtab xFilter to prepare
                                                the synthesised "PRAGMA name(arg)"
                                                statement.  Codegen cannot import
                                                main directly (circular). }
  gReprepare:              TRepreparFn;      { wired by passqlite3main — invoked
                                                by sqlite3_step on SQLITE_SCHEMA
                                                to recompile the statement
                                                against the new schema.  See
                                                vdbeapi.c:911 wrapper. }
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
type
  TVdbePreUpdateHookFn = procedure(v: Pointer; pCsr: PVdbeCursor; op: i32;
    zDb: PAnsiChar; pTab: Pointer; iKey1: i64; iReg: i32; iBlobWrite: i32);
var
  { wired by passqlite3codegen at init — invokes the pre-update callback.
    Codegen owns the body (needs Table/Index/KeyInfo layouts). }
  gVdbePreUpdateHook:      TVdbePreUpdateHookFn;
{$ENDIF}
procedure sqlite3ResetAllSchemasOfConnection(db: PTsqlite3);
function  sqlite3SchemaMutexHeld(db: PTsqlite3; iDb: i32; pSchema: Pointer): i32;
procedure sqlite3CloseSavepoints(pDb: PTsqlite3);
procedure sqlite3RollbackAll(pDb: PTsqlite3; tripCode: i32);
function  sqlite3LogEst(n: u64): i16;
function  sqlite3LogEstAdd(a: i16; b: i16): i16;
function  sqlite3LogEstFromDouble(x: Double): i16;
function  sqlite3LogEstToInt(x: i16): u64;

procedure sqlite3ValueApplyAffinity(pVal: Psqlite3_value; aff: u8; enc: u8);
function  sqlite3ValueText(pVal: Psqlite3_value; enc: u8): Pointer;
function  sqlite3ValueIsOfClass(pVal: Psqlite3_value; xFree: TxDelProc): i32;
function  sqlite3ValueNew(db: Psqlite3): Psqlite3_value;
procedure sqlite3ValueSetStr(v: Psqlite3_value; n: i32; z: Pointer;
                             enc: u8; xDel: TxDelProc);
procedure sqlite3ValueFree(v: Psqlite3_value);
function  sqlite3ValueBytes(pVal: Psqlite3_value; enc: u8): i32;
function  sqlite3ValueFromExpr(db: Psqlite3; pExpr: Pointer;
                               enc: u8; affinity: u8;
                               out ppVal: Psqlite3_value): i32;
function  sqlite3Stat4Column(db: Psqlite3; pRec: Pointer; nRec: i32;
                             iCol: i32; var ppVal: Psqlite3_value): i32;
procedure sqlite3Stat4ProbeFree(pRec: Pointer);

type
  { ValueNewStat4Ctx — vdbemem.c:1614..1619.  Context object passed by
    sqlite3Stat4ProbeSetValue() through to valueNew().  ppRec points to the
    caller's UnpackedRecord* slot so valueNew can allocate-on-first-use.
    iVal is the column index within that record being populated.
    Type declared unconditionally so valueNew()'s signature compiles in both
    builds; the body's STAT4 arm is the only consumer (non-STAT4 path passes
    nil and falls through to sqlite3ValueNew). }
  PValueNewStat4Ctx = ^TValueNewStat4Ctx;
  TValueNewStat4Ctx = record
    pParse: PParse;
    pIdx:   PIndex;
    ppRec:  ^PUnpackedRecord;
    iVal:   i32;
  end;
{$IFDEF SQLITE_ENABLE_STAT4}
  { Trampoline for valueFromFunction (vdbemem.c:1701..1799).  The C body
    reads PExpr internals (flags / x.pList / u.zToken) and calls
    sqlite3FindFunction + sqlite3Stat4ValueFromExpr + sqlite3ErrorMsg —
    all of which live in passqlite3codegen.  Real body wired at init. }
type
  TValueFromFunctionFn = function(db: Psqlite3; pExpr: Pointer;
                                  enc: u8; aff: u8;
                                  out ppVal: Psqlite3_value;
                                  pCtx: PValueNewStat4Ctx): i32;
var
  gValueFromFunctionImpl: TValueFromFunctionFn;
{ valueNew exposed for codegen's valueFromFunctionImpl (STAT4 only). }
function valueNew(db: Psqlite3; p: PValueNewStat4Ctx): Psqlite3_value;
{ valueFromFunction exposed for codegen's valueFromExprTrampoline TK_FUNCTION
  arm (STAT4 only).  See implementation at line ~13646. }
function valueFromFunction(db: Psqlite3; pExpr: Pointer;
                           enc: u8; aff: u8;
                           out ppVal: Psqlite3_value;
                           pCtx: PValueNewStat4Ctx): i32;
{$ENDIF}
function  sqlite3VdbeChangeEncoding(pMem: PMem; desiredEnc: i32): i32;
function  sqlite3VdbeMemTranslate(pMem: PMem; desiredEnc: u8): i32;
function  sqlite3VdbeMemHandleBom(pMem: PMem): i32;

{ --- vdbeapi.c — public API (Phase 5.5) --- }
function  sqlite3_step(pStmt: PVdbe): i32;
function  sqlite3_reset(pStmt: PVdbe): i32;
function  sqlite3_finalize(pStmt: PVdbe): i32;
function  sqlite3_clear_bindings(pStmt: PVdbe): i32;
function  sqlite3ErrStr(rc: i32): PAnsiChar;

{ sqlite3_value_* accessors }
function sqlite3_value_type(pVal: Psqlite3_value): i32;
function sqlite3_value_int(pVal: Psqlite3_value): i32;
function sqlite3_value_int64(pVal: Psqlite3_value): i64;
function sqlite3_value_double(pVal: Psqlite3_value): Double;
function sqlite3_value_text(pVal: Psqlite3_value): PAnsiChar;
function sqlite3_value_text16(pVal: Psqlite3_value): Pointer;
function sqlite3_value_text16be(pVal: Psqlite3_value): Pointer;
function sqlite3_value_text16le(pVal: Psqlite3_value): Pointer;
function sqlite3_value_blob(pVal: Psqlite3_value): Pointer;
function sqlite3_value_bytes(pVal: Psqlite3_value): i32;
function sqlite3_value_bytes16(pVal: Psqlite3_value): i32;
function sqlite3_value_subtype(pVal: Psqlite3_value): u32;
function sqlite3_value_pointer(pVal: Psqlite3_value; zPType: PAnsiChar): Pointer;
function sqlite3_value_dup(pOrig: Psqlite3_value): Psqlite3_value;
procedure sqlite3_value_free(pOld: Psqlite3_value);
function sqlite3_value_nochange(pVal: Psqlite3_value): i32;
function sqlite3_value_frombind(pVal: Psqlite3_value): i32;
function sqlite3_value_numeric_type(pVal: Psqlite3_value): i32;
function sqlite3_value_encoding(pVal: Psqlite3_value): i32;

{ sqlite3_column_* accessors }
function sqlite3_column_count(pStmt: PVdbe): i32;
function sqlite3_data_count(pStmt: PVdbe): i32;
function sqlite3_column_type(pStmt: PVdbe; i: i32): i32;
function sqlite3_column_int(pStmt: PVdbe; i: i32): i32;
function sqlite3_column_int64(pStmt: PVdbe; i: i32): i64;
function sqlite3_column_double(pStmt: PVdbe; i: i32): Double;
function sqlite3_column_text(pStmt: PVdbe; i: i32): PAnsiChar;
function sqlite3_column_blob(pStmt: PVdbe; i: i32): Pointer;
function sqlite3_column_bytes(pStmt: PVdbe; i: i32): i32;
function sqlite3_column_bytes16(pStmt: PVdbe; i: i32): i32;
function sqlite3_column_value(pStmt: PVdbe; i: i32): Psqlite3_value;
function sqlite3_column_name(pStmt: PVdbe; N: i32): PAnsiChar;
function sqlite3_column_name16(pStmt: PVdbe; N: i32): Pointer;
function sqlite3_column_decltype(pStmt: PVdbe; N: i32): PAnsiChar;
function sqlite3_column_decltype16(pStmt: PVdbe; N: i32): Pointer;
function sqlite3_column_database_name(pStmt: PVdbe; N: i32): PAnsiChar;
function sqlite3_column_database_name16(pStmt: PVdbe; N: i32): Pointer;
function sqlite3_column_table_name(pStmt: PVdbe; N: i32): PAnsiChar;
function sqlite3_column_table_name16(pStmt: PVdbe; N: i32): Pointer;
function sqlite3_column_origin_name(pStmt: PVdbe; N: i32): PAnsiChar;
function sqlite3_column_origin_name16(pStmt: PVdbe; N: i32): Pointer;
function sqlite3_expired(pStmt: PVdbe): i32;
function sqlite3_aggregate_count(pCtx: Psqlite3_context): i32;
function sqlite3_transfer_bindings(pFromStmt: PVdbe; pToStmt: PVdbe): i32;
function sqlite3_column_text16(pStmt: PVdbe; i: i32): Pointer;

{ sqlite3_bind_* }
function sqlite3_bind_int(pStmt: PVdbe; i: i32; iVal: i32): i32;
function sqlite3_bind_int64(pStmt: PVdbe; i: i32; iVal: i64): i32;
function sqlite3_bind_double(pStmt: PVdbe; i: i32; rVal: Double): i32;
function sqlite3_bind_null(pStmt: PVdbe; i: i32): i32;
function sqlite3_bind_text(pStmt: PVdbe; i: i32; zData: PAnsiChar;
                           nData: i32; xDel: TxDelProc): i32;
function sqlite3_bind_blob(pStmt: PVdbe; i: i32; zData: Pointer;
                           nData: i32; xDel: TxDelProc): i32;
function sqlite3_bind_blob64(pStmt: PVdbe; i: i32; zData: Pointer;
                             nData: u64; xDel: TxDelProc): i32;
function sqlite3_bind_text64(pStmt: PVdbe; i: i32; zData: PAnsiChar;
                             nData: u64; xDel: TxDelProc; enc: u8): i32;
function sqlite3_bind_text16(pStmt: PVdbe; i: i32; zData: Pointer;
                             n: i32; xDel: TxDelProc): i32;
function sqlite3_bind_zeroblob(pStmt: PVdbe; i: i32; n: i32): i32;
function sqlite3_bind_zeroblob64(pStmt: PVdbe; i: i32; n: u64): i32;
function sqlite3_bind_pointer(pStmt: PVdbe; i: i32; pPtr: Pointer;
                              zPType: PAnsiChar; xDestructor: TxDelProc): i32;
function sqlite3_bind_value(pStmt: PVdbe; i: i32;
                            pValue: Psqlite3_value): i32;
function sqlite3_bind_parameter_count(pStmt: PVdbe): i32;
function sqlite3_bind_parameter_name(pStmt: PVdbe; i: i32): PAnsiChar;
function sqlite3_bind_parameter_index(pStmt: PVdbe; zName: PAnsiChar): i32;
function sqlite3VdbeParameterIndex(p: PVdbe; zName: PAnsiChar; nName: i32): i32;

{ --- vdbeapi.c — sqlite3_result_* context-result setters (Phase 6.6) --- }
procedure setResultStrOrError(pCtx: Psqlite3_context; z: PAnsiChar;
                              n: i32; enc: u8; xDel: TxDelProc);
procedure sqlite3_result_null(pCtx: Psqlite3_context);
procedure sqlite3_result_int(pCtx: Psqlite3_context; iVal: i32);
procedure sqlite3_result_int64(pCtx: Psqlite3_context; iVal: i64);
procedure sqlite3_result_double(pCtx: Psqlite3_context; rVal: Double);
procedure sqlite3_result_text(pCtx: Psqlite3_context; z: PAnsiChar;
  n: i32; xDel: TxDelProc);
procedure sqlite3_result_blob(pCtx: Psqlite3_context; z: Pointer;
  n: i32; xDel: TxDelProc);
procedure sqlite3_result_blob64(pCtx: Psqlite3_context; z: Pointer;
  n: u64; xDel: TxDelProc);
procedure sqlite3_result_value(pCtx: Psqlite3_context; pVal: Psqlite3_value);
procedure sqlite3_result_error(pCtx: Psqlite3_context; z: PAnsiChar; n: i32);
procedure sqlite3_result_error_nomem(pCtx: Psqlite3_context);
procedure sqlite3_result_error_toobig(pCtx: Psqlite3_context);
procedure sqlite3_result_error_code(pCtx: Psqlite3_context; errCode: i32);
procedure sqlite3_result_pointer(pCtx: Psqlite3_context; pPtr: Pointer;
                                 zPType: PAnsiChar; xDestructor: TxDelProc);
procedure sqlite3_result_zeroblob(pCtx: Psqlite3_context; n: i32);
function  sqlite3_result_zeroblob64(pCtx: Psqlite3_context; n: u64): i32;
function  sqlite3_aggregate_context(pCtx: Psqlite3_context;
  nByte: i32): Pointer;
function  sqlite3StmtCurrentTime(pCtx: Psqlite3_context): i64;

{ --- vdbeblob.c — incremental blob I/O (Phase 5.6) --- }
function  sqlite3_blob_open(db: PTsqlite3; zDb, zTable, zColumn: PAnsiChar;
                            iRow: i64; flags: i32;
                            out ppBlob: Psqlite3_blob): i32;
function  sqlite3_blob_close(pBlob: Psqlite3_blob): i32;
function  sqlite3_blob_read(pBlob: Psqlite3_blob; z: Pointer;
                            n: i32; iOffset: i32): i32;
function  sqlite3_blob_write(pBlob: Psqlite3_blob; z: Pointer;
                             n: i32; iOffset: i32): i32;
function  sqlite3_blob_bytes(pBlob: Psqlite3_blob): i32;
function  sqlite3_blob_reopen(pBlob: Psqlite3_blob; iRow: i64): i32;

{ --- vdbetrace.c — EXPLAIN SQL expander (Phase 5.8) --- }
function sqlite3VdbeExpandSql(p: PVdbe; zRawSql: PAnsiChar): PAnsiChar;

{ --- vdbevtab.c — bytecode virtual-table initialiser (Phase 5.9) --- }
function sqlite3VdbeBytecodeVtabInit(db: PTsqlite3): i32;

{ --- vdbesort.c — external sorter (Phase 5.7) --- }
function  sqlite3VdbeSorterInit(db: PTsqlite3; nField: i32;
                                pCsr: PVdbeCursor): i32;
procedure sqlite3VdbeSorterReset(db: PTsqlite3; pSorter: PVdbeSorter);
procedure sqlite3VdbeSorterClose(db: PTsqlite3; pCsr: PVdbeCursor);
function  sqlite3VdbeSorterWrite(pCsr: PVdbeCursor; pVal: PMem): i32;
function  sqlite3VdbeSorterRewind(pCsr: PVdbeCursor; out pbEof: i32): i32;
function  sqlite3VdbeSorterNext(db: PTsqlite3; pCsr: PVdbeCursor): i32;
function  sqlite3VdbeSorterRowkey(pCsr: PVdbeCursor; pOut: PMem): i32;
function  sqlite3VdbeSorterCompare(pCsr: PVdbeCursor; bOmitRowid: i32;
                                   pKey: Pointer; nKey: i32;
                                   out pRes: i32): i32;

{ --- vdbe.c — execution engine (Phase 5.4) --- }
function  sqlite3VdbeExec(v: PVdbe): i32;

{ ----------------------------------------------------------------------
  Phase 6.9-bis step 11g.1 (structural skeleton) — OP_ParseSchema hook.

  vdbe.c:7114..7183 OP_ParseSchema invokes sqlite3_exec() which lives in
  passqlite3main.pas and would create a `uses` cycle if called directly
  from this unit (main already uses vdbe).  We expose a function pointer
  that main.pas assigns at unit-init time; the OP_ParseSchema body in
  sqlite3VdbeExec dispatches through it.  When the pointer is nil (e.g.
  during early bring-up or unit tests that link vdbe without main) the
  opcode falls back to the legacy no-op stub.

  Signature mirrors the productive part of vdbe.c:7146..7173:
    iDb       — pOp^.p1
    zWhere    — pOp^.p4.z (must be non-nil; ALTER-branch p4.z=0 is
                deferred to the future sqlite3InitOne port)
    p5        — pOp^.p5 (currently unused by callers; reserved for
                ALTER-branch flags)
  Returns SQLITE_OK / SQLITE_CORRUPT_BKPT / SQLITE_NOMEM_BKPT exactly
  as the C body sets `rc` before the `if(rc) goto abort_due_to_error`
  tail.  Caller is responsible for setting db^.errCode / triggering the
  schema-reset on non-OK return.
  ---------------------------------------------------------------------- }
type
  TVdbeParseSchemaExec = function(db: PTsqlite3; iDb: i32;
                                  zWhere: PAnsiChar; p5: u16;
                                  pzErrMsg: PPAnsiChar): i32;
var
  vdbeParseSchemaExec: TVdbeParseSchemaExec = nil;

{ OP_SqlExec hook (vdbe.c:7064 → main.c sqlite3_exec).  Same uses-cycle
  rationale as vdbeParseSchemaExec above; main.pas installs the pointer at
  unit init.  Signature mirrors the productive subset of sqlite3_exec used
  by OP_SqlExec — no callback, no callback context, just a plain SQL
  string and an output zErrMsg slot. }
type
  TVdbeSqlExec = function(db: PTsqlite3; zSql: PAnsiChar;
                          pzErrMsg: PPAnsiChar): i32;
var
  vdbeSqlExec: TVdbeSqlExec = nil;

{ OP_Vacuum hook (vdbe.c → vacuum.c sqlite3RunVacuum).  Same uses-cycle
  rationale as vdbeParseSchemaExec / vdbeSqlExec.  Signature mirrors the
  C function: write any error message via *pzErrMsg, vacuum aDb[iDb], and
  if pOut is non-nil treat the call as VACUUM INTO 'pOut->z'. }
type
  TVdbeRunVacuum = function(pzErrMsg: PPAnsiChar; db: PTsqlite3;
                            iDb: i32; pOut: Psqlite3_value): i32;
var
  vdbeRunVacuum: TVdbeRunVacuum = nil;

{ OP_IFindKey / OP_IdxDelete hook — vdbeaux.c sqlite3VdbeFindIndexKey
  (vdbeaux.c:5542).  Sub-search around the current index cursor for a
  matching record where indexed-expression / virtual columns may differ
  by tiny amounts (EIIB bug).  TIndex layout lives in passqlite3codegen
  (PIndex is opaque here), so the body is installed via this hook. }
type
  TVdbeFindIndexKey = function(pCur: Pointer; pIdx: PIndex;
                               p: Pointer; pRes: Pi32;
                               bIntegrity: i32): i32;
var
  vdbeFindIndexKey: TVdbeFindIndexKey = nil;

{ --- vdbe.c Phase 5.4b helpers (exported for testing) --- }
function  sqlite3IntFloatCompare(i: i64; r: Double): i32;

{ Undocumented test-only global incremented by OP_Sort / OP_SorterSort
  (vdbe.c:79, vdbe.c:6350, guarded by SQLITE_TEST).  Regression tests
  (e.g. between.test's `queryplan` proc) read it via the Tcl-linked
  `sqlite_sort_count` variable to verify the optimizer correctly
  elides sorts.  Always present here; harmless when unused. }
var
  sqlite3_sort_count: i32 = 0;

{ Test-only global incremented by likeFunc on each LIKE/GLOB invocation
  (func.c:891, 924, 966 — guarded by SQLITE_TEST).  Regression tests
  (like.test, e_expr-* etc.) read it via the Tcl-linked
  `sqlite_like_count` variable (test1.c:9374) to verify the optimizer
  has, or has not, elided LIKE/GLOB function calls.  Always present
  here; harmless when unused. }
var
  sqlite3_like_count: i32 = 0;

{ 9.4.divbug.73 — Test-only global incremented by OP_SeekGE/GT/LT/LE on
  success (vdbe.c:4975), by OP_Next/Prev/SorterNext on success (vdbe.c:6532),
  and decremented by OP_Sort/OP_SorterSort (vdbe.c:6351).  Read by regression
  tests via the Tcl-linked `sqlite_search_count` variable (test1.c:9366) to
  count B-tree-driven row visits.  rowid-4.5 / rowid-4.5.1 expect 3 here. }
var
  sqlite3_search_count: i32 = 0;

{ vdbe.c:68 — test-only countdown: when >0, decremented once per VDBE opcode
  step (vdbe.c:961..971, #ifdef SQLITE_TEST) and, when it reaches 0, fires
  sqlite3_interrupt(db).  Tcl-linked as `sqlite_interrupt_count` (test1.c:9376)
  so interrupt.test section 3 can simulate an interrupt after N steps. }
var
  sqlite3_interrupt_count: Int32 = 0;

{ vdbe.c:90 — largest blob (MEM_Str|MEM_Blob, by Mem.n, excluding zero-padding)
  ever materialised on the VDBE register stack.  Test-only watermark read by the
  regression suite via the Tcl-linked `sqlite3_max_blobsize` variable
  (test1.c:9372).  Bumped by UPDATE_MAX_BLOBSIZE / updateMaxBlobsize. }
var
  sqlite3_max_blobsize: i32 = 0;

implementation

uses
  SysUtils,        { Format — used by the Phase 7.4c trace capture }
  passqlite3vtab;  { Phase 6.bis.3a: VTable + sqlite3VtabBegin/CallCreate/CallDestroy/ImportErrmsg
                     — implementation-only to break the interface-side cycle (vtab uses vdbe). }

{ vdbe.c:91 updateMaxBlobsize — record the largest string/blob ever placed in a
  VDBE register.  Uses p^.n only (the materialised byte count); MEM_Zero blobs
  carry their padding in u.nZero and are NOT counted, which is exactly how the
  zeroblob.test watermark proves zeroblobs are never instantiated on the stack. }
procedure UpdateMaxBlobsize(p: PMem); inline;
begin
  if ((p^.flags and (MEM_Str or MEM_Blob)) <> 0) and (p^.n > sqlite3_max_blobsize) then
    sqlite3_max_blobsize := p^.n;
end;

{ ============================================================================
  Phase 5.2 — vdbeaux.c port
  Byte-offset helpers for Parse and sqlite3 fields (opaque pointers).
  Offsets verified against SQLite 3.53.0 GCC x86-64 non-debug build.

  Parse offsets:
    db          = 0   (8B pointer)
    pVdbe       = 16  (8B pointer)
    nTempReg    = 31  (1B u8)
    nRangeReg   = 44  (4B i32)
    szOpAlloc   = 64  (4B i32)
    nLabel      = 72  (4B i32, stored as negative of count)
    nLabelAlloc = 76  (4B i32)
    aLabel      = 80  (8B pointer, Pi32)

  sqlite3 offsets:
    mallocFailed = 103 (1B u8)
    aLimit[5]    = 156 (4B i32, SQLITE_LIMIT_VDBE_OP=5)

  ADDR(x) macro from vdbe.h: label index ↔ negative encoding.
    C: #define ADDR(X) (~(X))
    Pascal: vdbeADDR(x) = not x
  ============================================================================ }

function vdbeParseDbPtr(p: PParse): Psqlite3db; inline;
begin
  Result := PPsqlite3db(p)^;  { Parse.db at offset 0 }
end;

function vdbeParsePVdbe(p: PParse): PVdbe; inline;
begin
  Result := PPVdbe(PByte(p) + 16)^;  { Parse.pVdbe at offset 16 }
end;

function vdbeParseSzOpAllocPtr(p: PParse): Pi32; inline;
begin
  Result := Pi32(PByte(p) + 64);
end;

function vdbeParseNLabelPtr(p: PParse): Pi32; inline;
begin
  Result := Pi32(PByte(p) + 72);
end;

function vdbeParseNLabelAllocPtr(p: PParse): Pi32; inline;
begin
  Result := Pi32(PByte(p) + 76);
end;

function vdbeParseALabelPtr(p: PParse): PPi32; inline;
begin
  Result := PPi32(PByte(p) + 80);
end;

function vdbeDbMallocFailed(db: Psqlite3db): Boolean; inline;
begin
  if db = nil then begin Result := False; Exit; end;
  Result := PByte(db)[103] <> 0;
end;

function vdbeDbVdbeOpLimit(db: Psqlite3db): i32; inline;
begin
  { sqlite3.aLimit[SQLITE_LIMIT_VDBE_OP] = aLimit[5]; aLimit at offset 136;
    each entry is i32 (4 bytes); offset = 136 + 5*4 = 156 }
  if db = nil then begin Result := SQLITE_DEFAULT_VDBE_OP; Exit; end;
  Result := Pi32(PByte(db) + 156)^;
end;

function vdbeADDR(x: i32): i32; inline;
begin
  Result := not x;  { ADDR(x) = ~x from vdbe.h }
end;

{ dummy op returned by sqlite3VdbeGetOp on OOM — never written, always read }
var
  gVdbeOpDummy: TVdbeOp;

{ sqlite3FreeXDel — cdecl wrapper for sqlite3_free, used as SQLITE_DYNAMIC }
procedure sqlite3FreeXDel(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

{ ============================================================================
  sqlite3SmallTypeSizes — serial type → stored byte size.
  Source: vdbeaux.c const u8 sqlite3SmallTypeSizes[128].
  For types 0-12 the sizes are special (not formula-derivable).
  For types 13-127: size = (serial_type - 12) shr 1 (integer / 2).
  For types >=128:  size = (serial_type - 12) shr 1 (same formula, no table).
  ============================================================================ }

const
  { Serial type 0-12 stored byte sizes (special values; types >=13 use formula) }
  SMALL_SERIAL_SIZES: array[0..12] of u8 = (0,1,2,3,4,6,8,8,0,0,0,0,0);

{ ============================================================================
  sqlite3VdbeSerialTypeLen — length of data for given serial type.
  Source: vdbeaux.c sqlite3VdbeSerialTypeLen().
  For types 0-12: use table. For types >= 13: (type-12) div 2.
  ============================================================================ }

function sqlite3VdbeSerialTypeLen(serialType: u32): u32;
begin
  if serialType <= 12 then
    Result := SMALL_SERIAL_SIZES[serialType]
  else
    Result := (serialType - 12) shr 1;
end;

function sqlite3VdbeOneByteSerialTypeLen(serialType: u8): u8;
begin
  if serialType <= 12 then
    Result := SMALL_SERIAL_SIZES[serialType]
  else
    Result := u8((serialType - 12) shr 1);
end;

{ ============================================================================
  sqlite3VdbeSerialGet — deserialize one value from a record.
  Source: vdbeaux.c sqlite3VdbeSerialGet().
  ============================================================================ }

procedure sqlite3VdbeSerialGet(buf: Pu8; serialType: u32; pMem: PMem); inline;
var
  x: u64;
  y: u32;
begin
  case serialType of
    10: begin  { NULL with virtual-table UPDATE no-change flag }
      pMem^.flags := MEM_Null or MEM_Zero;
      pMem^.n := 0;
      pMem^.u.nZero := 0;
    end;
    11, 0: begin  { NULL or reserved }
      pMem^.flags := MEM_Null;
    end;
    1: begin  { 8-bit signed int }
      pMem^.u.i := i64(i8(buf[0]));
      pMem^.flags := MEM_Int;
    end;
    2: begin  { 16-bit big-endian signed int }
      pMem^.u.i := i64(i16((i16(buf[0]) shl 8) or i16(buf[1])));
      pMem^.flags := MEM_Int;
    end;
    3: begin  { 24-bit big-endian signed int }
      x := (u32(buf[0]) shl 16) or (u32(buf[1]) shl 8) or u32(buf[2]);
      if (x and $800000) <> 0 then x := x or u64($FFFFFFFFFF000000);
      pMem^.u.i := i64(x);
      pMem^.flags := MEM_Int;
    end;
    4: begin  { 32-bit big-endian signed int }
      pMem^.u.i := i64(i32((u32(buf[0]) shl 24) or (u32(buf[1]) shl 16)
                           or (u32(buf[2]) shl 8) or u32(buf[3])));
      pMem^.flags := MEM_Int;
    end;
    5: begin  { 48-bit big-endian signed int }
      x := (u32(buf[2]) shl 24) or (u32(buf[3]) shl 16)
         or (u32(buf[4]) shl 8) or u32(buf[5]);
      x := x + u64(i64(i16((i16(buf[0]) shl 8) or i16(buf[1]))) shl 32);
      pMem^.u.i := i64(x);
      pMem^.flags := MEM_Int;
    end;
    6: begin  { 64-bit big-endian signed int }
      x := (u64(buf[0]) shl 56) or (u64(buf[1]) shl 48)
         or (u64(buf[2]) shl 40) or (u64(buf[3]) shl 32)
         or (u64(buf[4]) shl 24) or (u64(buf[5]) shl 16)
         or (u64(buf[6]) shl 8)  or  u64(buf[7]);
      pMem^.u.i := i64(x);
      pMem^.flags := MEM_Int;
    end;
    7: begin  { IEEE 754 big-endian 64-bit float }
      x := (u64(buf[0]) shl 56) or (u64(buf[1]) shl 48)
         or (u64(buf[2]) shl 40) or (u64(buf[3]) shl 32);
      y := (u32(buf[4]) shl 24) or (u32(buf[5]) shl 16)
         or (u32(buf[6]) shl 8)  or  u32(buf[7]);
      x := x or u64(y);
      Move(x, pMem^.u.r, 8);
      { NaN → NULL }
      if (x and $7FF0000000000000) = $7FF0000000000000 then
        if (x and $000FFFFFFFFFFFFF) <> 0 then begin
          pMem^.flags := MEM_Null;
          Exit;
        end;
      pMem^.flags := MEM_Real;
    end;
    8: begin  { integer constant 0 }
      pMem^.u.i := 0;
      pMem^.flags := MEM_Int;
    end;
    9: begin  { integer constant 1 }
      pMem^.u.i := 1;
      pMem^.flags := MEM_Int;
    end;
    else begin  { blob or string }
      pMem^.z := PAnsiChar(buf);
      pMem^.n := i32((serialType - 12) shr 1);
      if (serialType and 1) <> 0 then
        pMem^.flags := MEM_Str or MEM_Ephem
      else
        pMem^.flags := MEM_Blob or MEM_Ephem;
    end;
  end;
end;

{ ============================================================================
  sqlite3VdbeSerialType — determine serial type for a Mem value.
  Source: vdbeaux.c sqlite3VdbeSerialType().
  ============================================================================ }

function sqlite3VdbeSerialType(pMem: PMem; file_format: i32; pLen: Pu32): u32;
const
  MAX_6BYTE = u64(($00008000 shl 32) - 1);  { = $7FFFFFFFFFFF }
var
  flags: i32;
  i:     i64;
  u:     u64;
  n:     u32;
begin
  flags := pMem^.flags;
  if (flags and MEM_Null) <> 0 then begin
    pLen^ := 0;
    Result := 0;
    Exit;
  end;
  if (flags and (MEM_Int or MEM_IntReal)) <> 0 then begin
    i := pMem^.u.i;
    if i < 0 then u := u64(not i)  { ~i for twos-complement abs }
    else u := u64(i);
    if u <= 127 then begin
      if ((i and 1) = i) and (file_format >= 4) then begin
        pLen^ := 0; Result := 8 + u32(u); Exit;
      end else begin
        pLen^ := 1; Result := 1; Exit;
      end;
    end;
    if u <= 32767       then begin pLen^ := 2; Result := 2; Exit; end;
    if u <= 8388607     then begin pLen^ := 3; Result := 3; Exit; end;
    if u <= 2147483647  then begin pLen^ := 4; Result := 4; Exit; end;
    if u <= MAX_6BYTE   then begin pLen^ := 6; Result := 5; Exit; end;
    pLen^ := 8;
    if (flags and MEM_IntReal) <> 0 then begin
      pMem^.u.r := Double(pMem^.u.i);
      pMem^.flags := (pMem^.flags and not MEM_IntReal) or MEM_Real;
      Result := 7; Exit;
    end;
    Result := 6; Exit;
  end;
  if (flags and MEM_Real) <> 0 then begin
    pLen^ := 8; Result := 7; Exit;
  end;
  n := u32(pMem^.n);
  if (flags and MEM_Zero) <> 0 then
    n := n + u32(pMem^.u.nZero);
  pLen^ := n;
  Result := (n * 2) + 12 + u32(ord((flags and MEM_Str) <> 0));
end;

{ ============================================================================
  sqlite3VdbeSerialPut — serialize one value into a record buffer.
  Source: vdbeaux.c sqlite3VdbeSerialPut().
  ============================================================================ }

function sqlite3VdbeSerialPut(buf: Pu8; pMem: PMem; serial_type: u32): u32;
var
  v: u64;
  len: u32;
  k: i32;
begin
  len := sqlite3VdbeSerialTypeLen(serial_type);
  if serial_type >= 10 then begin
    if serial_type >= 12 then begin
      if (pMem^.flags and MEM_Zero) <> 0 then begin
        FillChar(buf^, len, 0);
        if len > u32(pMem^.n) then
          FillChar(PByte(buf)[pMem^.n], len - u32(pMem^.n), 0)
        else
          len := u32(pMem^.n);
      end else begin
        Move(pMem^.z^, buf^, len);
      end;
    end;
    { types 10, 11: zero bytes }
    Result := len;
    Exit;
  end;
  if len = 0 then begin Result := 0; Exit; end;
  if serial_type = 7 then
    Move(pMem^.u.r, v, 8)
  else
    v := u64(pMem^.u.i);
  { Big-endian write: C uses fall-through switch; Pascal uses a loop.
    Write bytes from index len-1 down to 1, shifting v right each time. }
  for k := i32(len) - 1 downto 1 do begin
    buf[k] := u8(v);
    v := v shr 8;
  end;
  buf[0] := u8(v);
  Result := len;
end;

{ ============================================================================
  Record comparison — stubs for Phase 5.2 (full port in Phase 5.4).
  ============================================================================ }

{ sqlite3VdbeAllocUnpackedRecord — vdbeaux.c:4222 port.
  Allocates an UnpackedRecord plus an array of (nKeyField+1) Mem cells in a
  single contiguous block, with the Mem array placed at the 8-byte-aligned
  offset past the UnpackedRecord header.  KeyInfo fields are accessed by
  the offsets documented in passqlite3codegen.pas TKeyInfo (nKeyField @6,
  db @16); vdbe.pas does not import codegen so manual offsets are used,
  matching the convention already employed at vdbe.pas:5728/7891. }
function sqlite3VdbeAllocUnpackedRecord(pKeyInfo: PKeyInfo): Pointer;
var
  p:      PUnpackedRecord;
  nByte:  u64;
  nField: i32;
  pDb:    Psqlite3;
  hdr8:   PtrUInt;
begin
  hdr8   := (PtrUInt(SizeOf(TUnpackedRecord)) + 7) and (not PtrUInt(7));
  nField := i32(Pu16(Pu8(pKeyInfo) + 6)^) + 1;
  pDb    := PPointer(Pu8(pKeyInfo) + 16)^;
  nByte  := u64(hdr8) + u64(SizeOf(TMem)) * u64(nField);
  p      := PUnpackedRecord(sqlite3DbMallocRaw(pDb, nByte));
  if p = nil then begin Result := nil; Exit; end;
  p^.pKeyInfo := pKeyInfo;
  p^.aMem     := Pointer(PtrUInt(p) + hdr8);
  p^.nField   := nField;
  Result := p;
end;

{ sqlite3VdbeRecordUnpack — vdbeaux.c:4242 port.
  Decodes the binary record at pKey/nKey into the Mem cells embedded in p,
  using sqlite3VdbeSerialGet / sqlite3VdbeSerialTypeLen.  Returns p (the
  C reference is void; the Pascal signature returns Pointer historically). }
function sqlite3VdbeRecordUnpack(pKeyInfo: PKeyInfo; nKey: i32; pKey: Pointer;
                                 p: Pointer): Pointer; inline;
var
  pUR:        PUnpackedRecord;
  aKey:       Pu8;
  d, idx:     u32;
  szHdr:      u32;
  serialType: u32;
  consumed:   u8;
  u:          u16;
  pMm:        PMem;
  enc:        u8;
  pDb:        Psqlite3;
  nAllField:  i32;  { hoisted from pUR^.nField to avoid repeated deref in loop;
                      task 12.2.candidate.7 (nAllField is the C-side KeyInfo
                      header field; in this routine the loop bound is the
                      unpacked-record's own nField, which mirrors the same
                      caller-supplied count). }
begin
  pUR  := PUnpackedRecord(p);
  aKey := Pu8(pKey);
  pMm  := PMem(pUR^.aMem);
  enc  := Pu8(pKeyInfo)[4];
  pDb  := PPointer(Pu8(pKeyInfo) + 16)^;
  nAllField := pUR^.nField;
  pUR^.default_rc := 0;
  { getVarint32 macro fast path: high-bit clear means single-byte varint. }
  if (aKey[0] and $80) = 0 then begin
    szHdr := u32(aKey[0]);
    consumed := 1;
  end else
    consumed := sqlite3GetVarint32(aKey, szHdr);
  idx := consumed;
  d   := szHdr;
  u   := 0;
  while (idx < szHdr) and (d <= u32(nKey)) do begin
    if (aKey[idx] and $80) = 0 then begin
      serialType := u32(aKey[idx]);
      consumed := 1;
    end else
      consumed := sqlite3GetVarint32(@aKey[idx], serialType);
    Inc(idx, consumed);
    pMm^.enc      := enc;
    pMm^.db       := pDb;
    pMm^.szMalloc := 0;
    pMm^.z        := nil;
    sqlite3VdbeSerialGet(@aKey[d], serialType, pMm);
    Inc(d, sqlite3VdbeSerialTypeLen(serialType));
    Inc(u);
    if u >= u16(nAllField) then break;
    Inc(pMm);
  end;
  if (d > u32(nKey)) and (u <> 0) then begin
    if u < u16(nAllField) then
      sqlite3VdbeMemSetNull(pMm);
  end;
  pUR^.nField := i32(u);
  Result := p;
end;

function sqlite3VdbeRecordCompareWithSkip(nKey1: i32; pKey1: Pointer;
                                          pPKey2: Pointer; bSkip: i32): i32;
begin
  { Phase 6.10 step 9 d-INNER fix: previously a stub returning 0, which
    caused INNER JOIN aggregate count() to wrongly return 0 because
    OP_IdxGT computed res = 0 + 1 = 1 → jumped past OP_AggStep.
    The full key-compare engine is implemented in btree.pas as
    sqlite3VdbeRecordCompare; bSkip=0 is the only value passed by the
    callsites in vdbe.pas (OP_IdxGT/IdxGE/IdxLT/IdxLE and OP_SeekScan),
    so we delegate.  Real bSkip support (skip first N pre-matched
    fields) is a fast-path optimisation; defer until profiling shows
    it matters. }
  if bSkip = 0 then
    Result := passqlite3btree.sqlite3VdbeRecordCompare(nKey1, pKey1,
                passqlite3btree.PUnpackedRecord(pPKey2))
  else
    Result := passqlite3btree.sqlite3VdbeRecordCompare(nKey1, pKey1,
                passqlite3btree.PUnpackedRecord(pPKey2));
end;

function sqlite3VdbeRecordCompare(nKey1: i32; pKey1: Pointer;
                                  pPKey2: Pointer): i32;
begin
  Result := passqlite3btree.sqlite3VdbeRecordCompare(nKey1, pKey1,
              passqlite3btree.PUnpackedRecord(pPKey2));
end;

function sqlite3VdbeFindCompare(pKey: Pointer): Pointer;
begin
  Result := passqlite3btree.sqlite3VdbeFindCompare(
              passqlite3btree.PUnpackedRecord(pKey));
end;

{ ============================================================================
  vdbeaux.c — VDBE program assembly (Phase 5.2)
  ============================================================================ }

{ --- growOpArray: resize v->aOp[] to hold at least one more op --- }

function growOpArray(v: PVdbe; nOp: i32): i32; forward;

function growOp3(p: PVdbe; op, p1, p2, p3: i32): i32;
begin
  if growOpArray(p, 1) <> 0 then begin Result := 1; Exit; end;
  Result := sqlite3VdbeAddOp3(p, op, p1, p2, p3);
end;

function addOp4IntSlow(p: PVdbe; op, p1, p2, p3, p4: i32): i32;
var
  addr: i32;
  pOp:  PVdbeOp;
begin
  addr := sqlite3VdbeAddOp3(p, op, p1, p2, p3);
  if not vdbeDbMallocFailed(p^.db) then begin
    pOp := @p^.aOp[addr];
    pOp^.p4type := P4_INT32;
    pOp^.p4.i   := p4;
  end;
  Result := addr;
end;

function growOpArray(v: PVdbe; nOp: i32): i32;
var
  pNew:  PVdbeOp;
  pPrs:  PParse;
  nNew:  i64;
  db:    Psqlite3db;
begin
  pPrs := v^.pParse;
  db   := vdbeParseDbPtr(pPrs);
  if v^.nOpAlloc <> 0 then
    nNew := i64(v^.nOpAlloc) * 2
  else
    nNew := i64(1024 div SizeOf(TVdbeOp));  { initial size }
  { enforce SQLITE_LIMIT_VDBE_OP }
  if nNew > vdbeDbVdbeOpLimit(db) then begin
    sqlite3OomFault(db);
    Result := SQLITE_NOMEM;
    Exit;
  end;
  pNew := PVdbeOp(sqlite3DbRealloc(db, v^.aOp, u64(nNew) * SizeOf(TVdbeOp)));
  if pNew <> nil then begin
    vdbeParseSzOpAllocPtr(pPrs)^ := sqlite3DbMallocSize(db, pNew);
    v^.nOpAlloc := vdbeParseSzOpAllocPtr(pPrs)^ div SizeOf(TVdbeOp);
    v^.aOp := pNew;
    Result := SQLITE_OK;
  end else
    Result := SQLITE_NOMEM;
end;

{ --- sqlite3VdbeAddOp3 — add one instruction (core of all AddOp variants) --- }

function sqlite3VdbeAddOp3(v: PVdbe; op, p1, p2, p3: i32): i32;
var
  i:   i32;
  pOp: PVdbeOp;
begin
  i := v^.nOp;
  if v^.nOpAlloc <= i then begin
    Result := growOp3(v, op, p1, p2, p3);
    Exit;
  end;
  v^.nOp := i + 1;
  pOp := @v^.aOp[i];
  pOp^.opcode  := u8(op);
  pOp^.p5      := 0;
  pOp^.p1      := p1;
  pOp^.p2      := p2;
  pOp^.p3      := p3;
  pOp^.p4.p   := nil;
  pOp^.p4type := P4_NOTUSED;
  pOp^.nExec  := 0;        { Phase 8.2.1 — scanstatus counter }
  pOp^.nCycle := 0;        { Phase 10.1.39.d.1 — scanstatus NCYCLE }
  Result := i;
end;

function sqlite3VdbeAddOp4Int(v: PVdbe; op, p1, p2, p3, p4: i32): i32;
var
  i:   i32;
  pOp: PVdbeOp;
begin
  i := v^.nOp;
  if v^.nOpAlloc <= i then begin
    Result := addOp4IntSlow(v, op, p1, p2, p3, p4);
    Exit;
  end;
  v^.nOp := i + 1;
  pOp := @v^.aOp[i];
  pOp^.opcode  := u8(op);
  pOp^.p5      := 0;
  pOp^.p1      := p1;
  pOp^.p2      := p2;
  pOp^.p3      := p3;
  pOp^.p4.i   := p4;
  pOp^.p4type := P4_INT32;
  pOp^.nExec  := 0;        { Phase 8.2.1 — scanstatus counter }
  pOp^.nCycle := 0;        { Phase 10.1.39.d.1 — scanstatus NCYCLE }
  Result := i;
end;

function sqlite3VdbeAddOp0(v: PVdbe; op: i32): i32;
begin
  Result := sqlite3VdbeAddOp3(v, op, 0, 0, 0);
end;

function sqlite3VdbeAddOp1(v: PVdbe; op, p1: i32): i32;
begin
  Result := sqlite3VdbeAddOp3(v, op, p1, 0, 0);
end;

function sqlite3VdbeAddOp2(v: PVdbe; op, p1, p2: i32): i32;
begin
  Result := sqlite3VdbeAddOp3(v, op, p1, p2, 0);
end;

function sqlite3VdbeAddOp4(v: PVdbe; op, p1, p2, p3: i32;
                           zP4: PAnsiChar; p4type: i32): i32;
var
  addr: i32;
begin
  addr := sqlite3VdbeAddOp3(v, op, p1, p2, p3);
  sqlite3VdbeChangeP4(v, addr, zP4, p4type);
  Result := addr;
end;

function sqlite3VdbeAddOp4Dup8(v: PVdbe; op, p1, p2, p3: i32;
                                pP4: Pu8; p4type: i32): i32;
var
  p4copy: PAnsiChar;
begin
  p4copy := PAnsiChar(sqlite3DbMallocRawNN(v^.db, 8));
  if p4copy <> nil then
    Move(pP4^, p4copy^, 8);
  Result := sqlite3VdbeAddOp4(v, op, p1, p2, p3, p4copy, p4type);
end;

function sqlite3VdbeGoto(v: PVdbe; iDest: i32): i32;
begin
  Result := sqlite3VdbeAddOp3(v, OP_Goto, 0, iDest, 0);
end;

function sqlite3VdbeLoadString(p: PVdbe; iDest: i32; zStr: PAnsiChar): i32;
begin
  Result := sqlite3VdbeAddOp4(p, OP_String8, 0, iDest, 0, zStr, 0);
end;

procedure sqlite3VdbeMultiLoad(p: PVdbe; iDest: i32; zTypes: PAnsiChar;
                               const args: array of const);
{ Port of vdbeaux.c:391 sqlite3VdbeMultiLoad.  Walk zTypes left-to-right,
  emitting OP_Integer / OP_String8 / OP_Null per character, then close with
  OP_ResultRow over the contiguous registers iDest..iDest+i-1.  An 'X' or
  unknown character ends the loop early and skips the OP_ResultRow.  C
  varargs are exposed in Pas via `array of const` (TVarRec); 'i' consumes
  one integer slot, 's' consumes one string/pointer slot. }
var
  i, k: i32;
  c:    AnsiChar;
  vr:   TVarRec;
  pStr: PAnsiChar;
  iVal: i32;
begin
  i := 0;
  k := 0;
  while True do begin
    c := zTypes[i];
    if c = #0 then break;
    if c = 's' then begin
      pStr := nil;
      if k <= High(args) then begin
        vr := args[k];
        case vr.VType of
          vtString:     pStr := PAnsiChar(@vr.VString^[1]);
          vtAnsiString: pStr := PAnsiChar(AnsiString(vr.VAnsiString));
          vtPChar:      pStr := vr.VPChar;
          vtPointer:    pStr := PAnsiChar(vr.VPointer);
          vtChar:       pStr := nil;
        end;
        Inc(k);
      end;
      if pStr = nil then
        sqlite3VdbeAddOp4(p, OP_Null, 0, iDest + i, 0, nil, 0)
      else
        sqlite3VdbeAddOp4(p, OP_String8, 0, iDest + i, 0, pStr, 0);
    end else if c = 'i' then begin
      iVal := 0;
      if k <= High(args) then begin
        vr := args[k];
        case vr.VType of
          vtInteger:  iVal := vr.VInteger;
          vtInt64:    iVal := i32(vr.VInt64^);
          vtBoolean:  if vr.VBoolean then iVal := 1 else iVal := 0;
        end;
        Inc(k);
      end;
      sqlite3VdbeAddOp2(p, OP_Integer, iVal, iDest + i);
    end else begin
      { 'X' or unknown: skip OP_ResultRow }
      Exit;
    end;
    Inc(i);
  end;
  sqlite3VdbeAddOp2(p, OP_ResultRow, iDest, i);
end;

function sqlite3VdbeAddFunctionCall(pParse: PParse; p1: i32; p2, p3: i32;
                                    nArg: i32; pFunc: PFuncDef; p5: i32): i32;
{ Faithful port of vdbeaux.c sqlite3VdbeAddFunctionCall.
  p5 here is the C `eCallCtx` argument (0 = OP_Function, 1 = OP_PureFunc),
  not the VDBE P5 byte.  Allocates a sqlite3_context with room for nArg
  argv slots, wires pFunc/argc/iOp into it, emits the OP_Function /
  OP_PureFunc opcode with P4_FUNCCTX, and ChangeP5(nArg). }
var
  v:      PVdbe;
  pCtx:   Psqlite3_context;
  pDb:    Psqlite3db;
  nByte:  u64;
  baseSz: u64;
  addr:   i32;
  op:     i32;
  pTop:   PParse;
begin
  v := vdbeParsePVdbe(pParse);
  Assert(v <> nil);
  pDb := vdbeParseDbPtr(pParse);
  baseSz := (u64(SizeOf(Tsqlite3_context)) + 7) and not u64(7);
  nByte  := baseSz + u64(nArg) * u64(SizeOf(PMem));
  pCtx   := Psqlite3_context(sqlite3DbMallocRawNN(pDb, nByte));
  if pCtx = nil then
  begin
    Assert(vdbeDbMallocFailed(pDb));
    Result := 0;
    Exit;
  end;
  FillChar(pCtx^, nByte, 0);
  pCtx^.pOut    := nil;
  pCtx^.pFunc   := pFunc;
  pCtx^.pVdbe   := nil;
  pCtx^.isError := 0;
  pCtx^.argc    := u16(nArg);
  pCtx^.iOp     := sqlite3VdbeCurrentAddr(v);
  if p5 <> 0 then
    op := OP_PureFunc
  else
    op := OP_Function;
  addr := sqlite3VdbeAddOp4(v, op, p1, p2, p3, PAnsiChar(pCtx), P4_FUNCCTX);
  { vdbeaux.c:465 — sqlite3VdbeChangeP5(v, eCallCtx & NC_SelfRef).  NC_SelfRef
    = 0x2E (NC_PartIdx|NC_IsCheck|NC_GenCol|NC_IdxExpr, sqliteInt.h:3532); the
    masked context bits become the OP_PureFunc P5 byte that sqlite3NotPureFunc
    reads to choose "a CHECK constraint" / "a generated column" / "an index".
    For an ordinary (non-DDL) function call eCallCtx is 0, so P5 stays 0 and
    no ChangeP5 fires — preserving byte-identical bytecode vs the EXPLAIN
    oracle (which never writes P5 for OP_Function).  argc is read from
    pCtx^.argc at runtime, not pOp^.p5. }
  if (p5 and $2E) <> 0 then
    sqlite3VdbeChangeP5(v, u16(p5 and $2E));
  { vdbeaux.c:466 — any OP_Function/OP_PureFunc may set sqlite3_result_error
    at run-time, so the surrounding statement may need to abort.  Marking
    mayAbort here is what lets a multi-row INSERT (e.g. VALUES(0),(json(...))
    inside a BEGIN) open a statement-journal savepoint at OP_Transaction and
    roll back the partial row on a json() "malformed JSON" failure.  Without
    this call usesStmtJournal stays 0, OP_Transaction skips BeginStmt, and
    json101-19.3's COMMIT keeps row 0.  Inlined to avoid a uses-cycle on
    passqlite3codegen.pas — equivalent to sqlite3MayAbort: set bit 1 of the
    toplevel Parse.parseFlags (PARSEFLAG_MayAbort).  Parse offsets:
    pToplevel @152 (PParse), parseFlags @40 (u32). }
  pTop := PPointer(PByte(pParse) + 152)^;
  if pTop = nil then pTop := pParse;
  PUInt32(PByte(pTop) + 40)^ := PUInt32(PByte(pTop) + 40)^ or u32(1 shl 1);
  Result := addr;
end;

{ sqlite3NotPureFunc — port of vdbeaux.c:5627..5650.  Invoked by date/time
  functions that use non-deterministic features (e.g. 'now', 'localtime',
  'utc', 'subsec').  Returns 1 normally; but when the function was coded as
  OP_PureFunc (i.e. it appears in a CHECK constraint / generated column /
  index expression — context recorded in the opcode's P5 byte by
  sqlite3VdbeAddFunctionCall), it sets a "non-deterministic use of X() in ..."
  error on pCtx and returns 0.  The date function then aborts the parse,
  leaving the error in place (and must NOT subsequently call result_null). }
function sqlite3NotPureFunc(pCtx: Psqlite3_context): i32;
var
  pOp:      PVdbeOp;
  zContext: PAnsiChar;
  zMsg:     PAnsiChar;
  pFn:      PTFuncDef;
begin
  { SQLITE_ENABLE_STAT4 guard (vdbeaux.c:5630): pVdbe may be nil when a
    function is evaluated outside the VM (STAT4 sample analysis).  Harmless
    to keep unconditionally. }
  if (pCtx = nil) or (pCtx^.pVdbe = nil) then begin Result := 1; Exit; end;
  pOp := PVdbeOp(PByte(pCtx^.pVdbe^.aOp) + u32(pCtx^.iOp) * SizeOf(TVdbeOp));
  if pOp^.opcode = OP_PureFunc then
  begin
    { NC_IsCheck=0x04, NC_GenCol=0x08 (sqliteInt.h:3528..3529).  P5 holds the
      DDL context bits (eCallCtx & NC_SelfRef). }
    if (pOp^.p5 and $04) <> 0 then
      zContext := 'a CHECK constraint'
    else if (pOp^.p5 and $08) <> 0 then
      zContext := 'a generated column'
    else
      zContext := 'an index';
    pFn := PTFuncDef(pCtx^.pFunc);
    zMsg := sqlite3MPrintf(pCtx^.pVdbe^.db,
      'non-deterministic use of %s() in %s', [pFn^.zName, zContext]);
    sqlite3_result_error(pCtx, zMsg, -1);
    sqlite3DbFree(pCtx^.pVdbe^.db, zMsg);
    Result := 0;
    Exit;
  end;
  Result := 1;
end;

{ --- Label management --- }

function resizeResolveLabel(p: PParse; v: PVdbe; j: i32): i32;
var
  nNewSize: i32;
  aLbl:     Pi32;
begin
  nNewSize := 10 - vdbeParseNLabelPtr(p)^;
  aLbl := Pi32(sqlite3DbReallocOrFree(vdbeParseDbPtr(p),
               vdbeParseALabelPtr(p)^,
               u64(nNewSize) * SizeOf(i32)));
  if aLbl = nil then begin
    vdbeParseNLabelAllocPtr(p)^ := 0;
    Result := SQLITE_NOMEM;
    Exit;
  end;
  vdbeParseALabelPtr(p)^ := aLbl;
  vdbeParseNLabelAllocPtr(p)^ := nNewSize;
  aLbl[j] := v^.nOp;
  Result := SQLITE_OK;
end;

function sqlite3VdbeMakeLabel(pParse: PParse): i32;
begin
  vdbeParseNLabelPtr(pParse)^ := vdbeParseNLabelPtr(pParse)^ - 1;
  Result := vdbeParseNLabelPtr(pParse)^;
end;

procedure sqlite3VdbeResolveLabel(v: PVdbe; x: i32);
var
  p: PParse;
  j: i32;
begin
  p := v^.pParse;
  j := vdbeADDR(x);  { = ~x, converts label to array index }
  if vdbeParseNLabelAllocPtr(p)^ + vdbeParseNLabelPtr(p)^ < 0 then begin
    { Need to resize the label array }
    resizeResolveLabel(p, v, j);
  end else begin
    vdbeParseALabelPtr(p)^[j] := v^.nOp;
  end;
end;

{ --- resolveP2Values: patch forward-reference labels, called by VdbeMakeReady --- }

procedure resolveP2Values(p: PVdbe; pMaxVtabArgs: Pi32);
var
  nMaxVtabArgs: i32;
  pPrs:         PParse;
  aLabel:       Pi32;
  pOp:          PVdbeOp;
label resolve_exit;
begin
  nMaxVtabArgs := pMaxVtabArgs^;
  pPrs   := p^.pParse;
  aLabel := vdbeParseALabelPtr(pPrs)^;
  p^.vdbeFlags := (p^.vdbeFlags or VDBF_ReadOnly) and not VDBF_IsReader;
  if p^.nOp = 0 then goto resolve_exit;
  pOp := @p^.aOp[p^.nOp - 1];
  while True do begin
    if pOp^.opcode <= SQLITE_MX_JUMP_OPCODE then begin
      case pOp^.opcode of
        OP_Transaction: begin
          if pOp^.p2 <> 0 then p^.vdbeFlags := p^.vdbeFlags and not VDBF_ReadOnly;
          p^.vdbeFlags := p^.vdbeFlags or VDBF_IsReader;
        end;
        OP_AutoCommit, OP_Savepoint: begin
          p^.vdbeFlags := p^.vdbeFlags or VDBF_IsReader;
        end;
        OP_Checkpoint, OP_Vacuum, OP_JournalMode: begin
          p^.vdbeFlags := (p^.vdbeFlags and not VDBF_ReadOnly) or VDBF_IsReader;
        end;
        OP_VUpdate: begin
          if pOp^.p2 > nMaxVtabArgs then nMaxVtabArgs := pOp^.p2;
        end;
        OP_VFilter: begin
          { nArg is in pOp[-1].p1 (OP_Integer before VFilter) }
          if (pOp^.p2 < 0) and (aLabel <> nil) then
            pOp^.p2 := aLabel[vdbeADDR(pOp^.p2)];
        end;
        OP_Init: begin
          goto resolve_exit;
        end;
        else begin
          if pOp^.p2 < 0 then begin
            if (aLabel <> nil) then
              pOp^.p2 := aLabel[vdbeADDR(pOp^.p2)];
          end;
        end;
      end;
    end;
    if pOp = p^.aOp then Break;
    Dec(pOp);
  end;
resolve_exit:
  if aLabel <> nil then begin
    sqlite3DbFree(p^.db, aLabel);
    vdbeParseALabelPtr(pPrs)^ := nil;
  end;
  vdbeParseNLabelPtr(pPrs)^ := 0;
  pMaxVtabArgs^ := nMaxVtabArgs;
end;

{ --- Query current address / get op --- }

function sqlite3VdbeCurrentAddr(p: PVdbe): i32;
begin
  Result := p^.nOp;
end;

function sqlite3VdbeGetOp(p: PVdbe; addr: i32): PVdbeOp;
begin
  if vdbeDbMallocFailed(p^.db) then begin
    FillChar(gVdbeOpDummy, SizeOf(TVdbeOp), 0);
    Result := @gVdbeOpDummy;
  end else
    Result := @p^.aOp[addr];
end;

function sqlite3VdbeGetLastOp(p: PVdbe): PVdbeOp;
begin
  Result := sqlite3VdbeGetOp(p, p^.nOp - 1);
end;

{ --- Change individual fields of existing ops --- }

procedure sqlite3VdbeChangeOpcode(p: PVdbe; addr: i32; iNewOpcode: u8);
begin
  sqlite3VdbeGetOp(p, addr)^.opcode := iNewOpcode;
end;

procedure sqlite3VdbeChangeP1(p: PVdbe; addr, val: i32);
begin
  sqlite3VdbeGetOp(p, addr)^.p1 := val;
end;

procedure sqlite3VdbeChangeP2(p: PVdbe; addr, val: i32);
begin
  sqlite3VdbeGetOp(p, addr)^.p2 := val;
end;

procedure sqlite3VdbeChangeP3(p: PVdbe; addr, val: i32);
begin
  sqlite3VdbeGetOp(p, addr)^.p3 := val;
end;

procedure sqlite3VdbeChangeP5(p: PVdbe; p5: u16);
begin
  if p^.nOp > 0 then p^.aOp[p^.nOp - 1].p5 := p5;
end;

{ Faithful port of sqlite3VdbeSetVarmask (vdbeaux.c:5389..5398).  Configure
  SQL variable iVar so that binding a new value to it signals to
  sqlite3_reoptimize() that re-preparing the statement may yield a better
  query plan. }
procedure sqlite3VdbeSetVarmask(v: PVdbe; iVar: i32);
begin
  Assert(iVar > 0);
  if iVar >= 32 then
    v^.expmask := v^.expmask or u32($80000000)
  else
    v^.expmask := v^.expmask or (u32(1) shl (iVar - 1));
end;

{ Faithful port of sqlite3VdbeGetBoundValue (vdbeaux.c:5366..5382).  Return
  a fresh sqlite3_value carrying the value bound to parameter iVar of VM v,
  with affinity aff applied.  Returns nil if v is nil or the bound value is
  SQL NULL.  The returned value must be freed by the caller via
  sqlite3ValueFree(). }
function sqlite3VdbeGetBoundValue(v: PVdbe; iVar: i32; aff: u8): Psqlite3_value;
var
  pBound: PMem;
  pRet:   Psqlite3_value;
begin
  Assert(iVar > 0);
  Result := nil;
  if v = nil then Exit;
  pBound := v^.aVar + (iVar - 1);
  if (pBound^.flags and MEM_Null) = 0 then
  begin
    pRet := sqlite3ValueNew(v^.db);
    if pRet <> nil then
    begin
      sqlite3VdbeMemCopy(PMem(pRet), pBound);
      sqlite3ValueApplyAffinity(pRet, aff, SQLITE_UTF8);
    end;
    Result := pRet;
  end;
end;

procedure sqlite3VdbeTypeofColumn(p: PVdbe; iDest: i32);
const
  OPFLAG_TYPEOFARG = $80;  { sqliteInt.h:4066 — was $20 prior to
    sub-progress 13's IS NULL pathfix.  The two-bit slip silently
    inverted OPFLAG_TYPEOFARG with an unrelated mask, causing
    OP_Column p5 emitted by IS NULL / IS NOT NULL residuals to
    diverge from the C oracle on this single bit.  All other
    OPFLAG_TYPEOFARG sites in the codebase (codegen.pas:312,
    util.pas:300) already use $80; this was the lone outlier. }
var
  pOp: PVdbeOp;
begin
  pOp := sqlite3VdbeGetLastOp(p);
  if (pOp^.p3 = iDest) and (pOp^.opcode = OP_Column) then
    pOp^.p5 := pOp^.p5 or OPFLAG_TYPEOFARG;
end;

procedure sqlite3VdbeJumpHere(p: PVdbe; addr: i32);
begin
  sqlite3VdbeChangeP2(p, addr, p^.nOp);
end;

procedure sqlite3VdbeJumpHereOrPopInst(p: PVdbe; addr: i32);
begin
  if addr = p^.nOp - 1 then
    p^.nOp := p^.nOp - 1
  else
    sqlite3VdbeChangeP2(p, addr, p^.nOp);
end;

{ --- AddOpList --- }

function sqlite3VdbeAddOpList(p: PVdbe; nOp: i32; aOp: PVdbeOpList;
                              iLineno: i32): PVdbeOp;
var
  i:      i32;
  pOut:   PVdbeOp;
  pFirst: PVdbeOp;
  pSrc:   PVdbeOpList;
begin
  if p^.nOp + nOp > p^.nOpAlloc then begin
    if growOpArray(p, nOp) <> SQLITE_OK then begin
      Result := nil;
      Exit;
    end;
  end;
  pFirst := @p^.aOp[p^.nOp];
  pOut := pFirst;
  pSrc := aOp;
  for i := 0 to nOp - 1 do begin
    pOut^.opcode  := pSrc^.opcode;
    pOut^.p1      := pSrc^.p1;
    pOut^.p2      := pSrc^.p2;
    if (sqlite3OpcodeProperty[pSrc^.opcode] and OPFLG_JUMP) <> 0 then
      if pSrc^.p2 > 0 then
        pOut^.p2 := pOut^.p2 + p^.nOp;
    pOut^.p3      := pSrc^.p3;
    pOut^.p4type  := P4_NOTUSED;
    pOut^.p4.p   := nil;
    pOut^.p5      := 0;
    pOut^.nExec   := 0;        { Phase 8.2.1 — scanstatus counter }
    pOut^.nCycle  := 0;        { Phase 10.1.39.d.1 — scanstatus NCYCLE }
    Inc(pOut);
    Inc(pSrc);
  end;
  p^.nOp := p^.nOp + nOp;
  Result := pFirst;
end;

{ --- Scan status --- }
{ Phase 8.2.1 — sqlite3VdbeScanStatus*.  Ports vdbeaux.c:1186..1274.
  In C these are gated by SQLITE_ENABLE_STMT_SCANSTATUS; this port
  enables the data path unconditionally so `.scanstats` works without
  a rebuild flag (callers in codegen.pas always emit the calls).
  The IS_STMT_SCANSTATUS(db) gate is still honoured so a connection
  that has not enabled SQLITE_DBCONFIG_STMT_SCANSTATUS pays no cost. }

procedure sqlite3VdbeScanStatus(p: PVdbe; addrExplain, addrLoop, addrVisit: i32;
                                nEst: LogEst; zName: PAnsiChar);
var
  nByte:  i64;
  aNew:   PScanStatus;
  pSc:    PScanStatus;
begin
  if (PTsqlite3(p^.db)^.flags and SQLITE_StmtScanStatus) = 0 then Exit;
  nByte := (i64(1) + i64(p^.nScan)) * i64(SizeOf(TScanStatus));
  aNew := PScanStatus(sqlite3DbRealloc(p^.db, p^.aScan, u64(nByte)));
  if aNew <> nil then begin
    pSc := @aNew[p^.nScan];
    Inc(p^.nScan);
    FillChar(pSc^, SizeOf(TScanStatus), 0);
    pSc^.addrExplain := addrExplain;
    pSc^.addrLoop    := addrLoop;
    pSc^.addrVisit   := addrVisit;
    pSc^.nEst        := nEst;
    pSc^.zName       := sqlite3DbStrDup(p^.db, zName);
    p^.aScan := aNew;
  end;
end;

procedure sqlite3VdbeScanStatusRange(p: PVdbe; addrExplain, addrStart, addrEnd: i32);
var
  pSc: PScanStatus;
  ii:  i32;
begin
  if (PTsqlite3(p^.db)^.flags and SQLITE_StmtScanStatus) = 0 then Exit;
  pSc := nil;
  for ii := p^.nScan - 1 downto 0 do begin
    pSc := @p^.aScan[ii];
    if pSc^.addrExplain = addrExplain then break;
    pSc := nil;
  end;
  if pSc <> nil then begin
    if addrEnd < 0 then addrEnd := sqlite3VdbeCurrentAddr(p) - 1;
    ii := 0;
    while ii < Length(pSc^.aAddrRange) do begin
      if pSc^.aAddrRange[ii] = 0 then begin
        pSc^.aAddrRange[ii]     := addrStart;
        pSc^.aAddrRange[ii + 1] := addrEnd;
        break;
      end;
      Inc(ii, 2);
    end;
  end;
end;

procedure sqlite3VdbeScanStatusCounters(p: PVdbe; addrExplain, addrLoop, addrVisit: i32);
var
  pSc: PScanStatus;
  ii:  i32;
begin
  if (PTsqlite3(p^.db)^.flags and SQLITE_StmtScanStatus) = 0 then Exit;
  pSc := nil;
  for ii := p^.nScan - 1 downto 0 do begin
    pSc := @p^.aScan[ii];
    if pSc^.addrExplain = addrExplain then break;
    pSc := nil;
  end;
  if pSc <> nil then begin
    if addrLoop  > 0 then pSc^.addrLoop  := addrLoop;
    if addrVisit > 0 then pSc^.addrVisit := addrVisit;
  end;
end;

{ --- P4 management --- }

procedure freeP4(db: Psqlite3db; p4type: i8; p4: Pointer); forward;

procedure freeP4(db: Psqlite3db; p4type: i8; p4: Pointer);
begin
  { For types that own memory, free it.  Others are static / not owned. }
  case p4type of
    P4_REAL,
    P4_INT64,
    P4_DYNAMIC,
    P4_INTARRAY: begin
      if p4 <> nil then sqlite3DbFree(db, p4);
    end;
    P4_KEYINFO: begin
      { sqlite3KeyInfoUnref — defer to Phase 6 }
    end;
    P4_MEM: begin
      { sqlite3ValueFree — defer to Phase 5.3 }
    end;
    P4_FUNCCTX,
    P4_FUNCDEF: begin
      { freeEphemeralFunction — defer to Phase 6 }
    end;
    P4_SUBRTNSIG: begin
      { vdbeaux.c:1421 — free the affinity string then the struct. }
      if p4 <> nil then
      begin
        sqlite3DbFree(db, PSubrtnSig(p4)^.zAff);
        sqlite3DbFree(db, p4);
      end;
    end;
  end;
end;

procedure vdbeFreeOpArray(db: Psqlite3db; aOp: PVdbeOp; nOp: i32);
var
  pOp: PVdbeOp;
begin
  if aOp = nil then Exit;
  if nOp = 0 then begin sqlite3DbFree(db, aOp); Exit; end;
  pOp := @aOp[nOp - 1];
  while True do begin
    if pOp^.p4type <= P4_FREE_IF_LE then begin
      freeP4(db, pOp^.p4type, pOp^.p4.p);
      { Defensive: clear after free so a second visit (e.g. an aliased
        SubProgram.aOp == parent.aOp) cannot double-free the same P4. }
      pOp^.p4type := P4_NOTUSED;
      pOp^.p4.p := nil;
    end;
    if pOp = aOp then Break;
    Dec(pOp);
  end;
  sqlite3DbFree(db, aOp);
end;

procedure vdbeChangeP4Full(p: PVdbe; pOp: PVdbeOp; zP4: PAnsiChar; n: i32);
var
  len: i32;
begin
  if pOp^.p4type <> 0 then begin
    pOp^.p4type := 0;
    pOp^.p4.p  := nil;
  end;
  if n < 0 then begin
    sqlite3VdbeChangeP4(p, i32(PByte(pOp) - PByte(p^.aOp)) div SizeOf(TVdbeOp),
                        zP4, n);
  end else begin
    if n = 0 then len := sqlite3Strlen30(PChar(zP4))
    else len := n;
    pOp^.p4.z  := PAnsiChar(sqlite3DbStrNDup(p^.db, PChar(zP4), u64(len)));
    pOp^.p4type := P4_DYNAMIC;
  end;
end;

procedure sqlite3VdbeChangeP4(p: PVdbe; addr: i32; zP4: PAnsiChar; n: i32);
var
  pOp: PVdbeOp;
  db:  Psqlite3db;
begin
  db := p^.db;
  if vdbeDbMallocFailed(db) then begin
    if n <> P4_VTAB then freeP4(db, i8(n), Pointer(zP4));
    Exit;
  end;
  if addr < 0 then addr := p^.nOp - 1;
  pOp := @p^.aOp[addr];
  if (n >= 0) or (pOp^.p4type <> 0) then begin
    vdbeChangeP4Full(p, pOp, zP4, n);
    Exit;
  end;
  if n = P4_INT32 then begin
    pOp^.p4.i   := i32(PtrInt(zP4));
    pOp^.p4type := P4_INT32;
  end else if zP4 <> nil then begin
    pOp^.p4.p   := Pointer(zP4);
    pOp^.p4type := i8(n);
  end;
end;

procedure sqlite3VdbeAppendP4(p: PVdbe; pP4: Pointer; n: i32);
var
  pOp: PVdbeOp;
begin
  if vdbeDbMallocFailed(p^.db) then begin
    freeP4(p^.db, i8(n), pP4);
    Exit;
  end;
  pOp := @p^.aOp[p^.nOp - 1];
  pOp^.p4type := i8(n);
  pOp^.p4.p  := pP4;
end;

procedure sqlite3VdbeSetP4KeyInfo(pParse: PParse; pIdx: PIndex);
begin
  { Real body lives in passqlite3codegen (vdbeaux.c:1629) — needs PIndex2
    layout + sqlite3KeyInfoOfIndex which are codegen-private.  Hook is
    registered at codegen unit-init; nil hook = degraded no-op for
    codegen-less test programs. }
  if Assigned(gSetP4KeyInfo) then
    gSetP4KeyInfo(pParse, pIdx);
end;

{ --- Comment helpers (no-ops unless SQLITE_ENABLE_EXPLAIN_COMMENTS) --- }

procedure sqlite3VdbeComment(p: PVdbe; zFormat: PAnsiChar);
begin
end;

procedure sqlite3VdbeNoopComment(p: PVdbe; zFormat: PAnsiChar);
begin
  if p <> nil then sqlite3VdbeAddOp0(p, OP_Noop);
end;

procedure sqlite3VdbeSetLineNumber(v: PVdbe; iLine: i32);
begin
end;

{ --- Link / query sub-programs --- }

procedure sqlite3VdbeLinkSubProgram(pVdbe: PVdbe; pSub: PSubProgram);
begin
  pSub^.pNext   := pVdbe^.pProgram;
  pVdbe^.pProgram := pSub;
end;

function sqlite3VdbeHasSubProgram(pVdbe: PVdbe): i32;
begin
  if pVdbe^.pProgram <> nil then Result := 1 else Result := 0;
end;

{ --- Change / delete ops --- }

function sqlite3VdbeChangeToNoop(p: PVdbe; addr: i32): i32;
var
  pOp: PVdbeOp;
begin
  if vdbeDbMallocFailed(p^.db) then begin Result := 0; Exit; end;
  pOp := @p^.aOp[addr];
  freeP4(p^.db, pOp^.p4type, pOp^.p4.p);
  pOp^.p4type := P4_NOTUSED;
  pOp^.p4.z  := nil;
  pOp^.opcode := OP_Noop;
  Result := 1;
end;

function sqlite3VdbeDeletePriorOpcode(p: PVdbe; op: u8): i32;
begin
  if (p^.nOp > 0) and (p^.aOp[p^.nOp - 1].opcode = op) then
    Result := sqlite3VdbeChangeToNoop(p, p^.nOp - 1)
  else
    Result := 0;
end;

procedure sqlite3VdbeReleaseRegisters(pParse: PParse; iFstirst, nReg, mask: i32;
                                      bUndefine: i32);
{ Port of vdbeaux.c:1501..1527 (under SQLITE_DEBUG).  Emits OP_ReleaseReg to
  flag a contiguous register range as no longer in use.  Trims leading and
  trailing bits set in `mask` (registers that must NOT be released) before
  emission; if the trimmed range is empty, emits nothing. }
var
  v:    PVdbe;
  uMask: u32;
  N:    i32;
  iFst:   i32;
begin
  if nReg = 0 then Exit;
  v := vdbeParsePVdbe(pParse);
  if v = nil then Exit;
  uMask := u32(mask);
  N := nReg;
  iFst := iFstirst;
  if (N <= 31) and (uMask <> 0) then
  begin
    while (N > 0) and ((uMask and 1) <> 0) do
    begin
      uMask := uMask shr 1;
      Inc(iFst);
      Dec(N);
    end;
    while (N > 0) and (N <= 32) and ((uMask and (u32(1) shl (N - 1))) <> 0) do
    begin
      uMask := uMask and (not (u32(1) shl (N - 1)));
      Dec(N);
    end;
  end;
  if N > 0 then
  begin
    sqlite3VdbeAddOp3(v, OP_ReleaseReg, iFst, N, i32(uMask));
    if bUndefine <> 0 then sqlite3VdbeChangeP5(v, 1);
  end;
end;

{ --- TakeOpArray (returns the op array and zeroes v->aOp) --- }

function sqlite3VdbeTakeOpArray(p: PVdbe; pnOp: Pi32; pnMaxArg: Pi32): PVdbeOp;
begin
  resolveP2Values(p, pnMaxArg);
  pnOp^ := p^.nOp;
  Result := p^.aOp;
  p^.aOp := nil;
end;

{ --- Explain helpers (stubs) --- }

function sqlite3VdbeExplainParent(pParse: PParse): i32;
{ Port of vdbeaux.c:493.  Returns the address of the current EXPLAIN
  QUERY PLAN baseline (0 if none).  pParse->addrExplain lives at offset
  312 (verified against passqlite3codegen.TParse layout). }
var
  addrExplain: i32;
  pOp:         PVdbeOp;
begin
  addrExplain := PInt32(PByte(pParse) + 312)^;
  if addrExplain = 0 then begin Result := 0; Exit; end;
  pOp := sqlite3VdbeGetOp(vdbeParsePVdbe(pParse), addrExplain);
  Result := pOp^.p2;
end;

procedure sqlite3ExplainBreakpoint(z1, z2: PAnsiChar);
begin
  { vdbeaux.c:505 — SQLITE_DEBUG-only debugger hook; no-op matches
    default-build (NDEBUG) behaviour exactly. }
end;

function sqlite3VdbeExplain(pParse: PParse; bPush: u8; zFmt: PAnsiChar;
                            const args: array of const): i32;
{ Port of vdbeaux.c:517.  Emit an OP_Explain opcode when EXPLAIN QUERY PLAN
  mode is active (Parse.explain == 2).  In production builds (NDEBUG, no
  ENABLE_STMT_SCANSTATUS — which matches our build) the body is gated on
  the explain == 2 check; otherwise it is a no-op returning 0.

  Pas signature exposes the variadic message via `array of const` so the
  format string passes through sqlite3VMPrintf identically to the C body. }
var
  zMsg:  PAnsiChar;
  v:     PVdbe;
  iThis: i32;
begin
  Result := 0;
  if PByte(pParse)[299] <> 2 then Exit;     { Parse.explain }
  zMsg := sqlite3VMPrintf(Psqlite3db(PPointer(pParse)^), zFmt, args);
  v := vdbeParsePVdbe(pParse);
  iThis := v^.nOp;
  Result := sqlite3VdbeAddOp4(v, OP_Explain, iThis,
                              PInt32(PByte(pParse) + 312)^, 0,
                              zMsg, P4_DYNAMIC);
  if bPush <> 0 then
    PInt32(PByte(pParse) + 312)^ := iThis;
  sqlite3VdbeScanStatus(v, iThis, -1, -1, 0, nil);
end;

procedure sqlite3VdbeExplainPop(pParse: PParse);
{ Port of vdbeaux.c:548.  Pop the EXPLAIN QUERY PLAN stack one level by
  resetting pParse^.addrExplain to the parent's address.  The C body is
  a one-liner: pParse->addrExplain = sqlite3VdbeExplainParent(pParse);
  Parse.addrExplain lives at offset 312 (same offset used by
  sqlite3VdbeExplainParent above). }
begin
  PInt32(PByte(pParse) + 312)^ := sqlite3VdbeExplainParent(pParse);
end;

{ --- ParseSchema and EndCoroutine --- }

procedure sqlite3VdbeAddParseSchemaOp(p: PVdbe; iDb: i32; zWhere: PAnsiChar; p5: u16);
var
  j: i32;
begin
  sqlite3VdbeAddOp4(p, OP_ParseSchema, iDb, 0, 0, zWhere, P4_DYNAMIC);
  sqlite3VdbeChangeP5(p, p5);
  { vdbeaux.c:562 — mark every attached btree as used so the prepared
    statement claims their schema mutexes during sqlite3_step.  Caller is
    responsible for the matching sqlite3MayAbort(pParse) since the Parse
    structure lives in codegen.pas. }
  for j := 0 to PTsqlite3(p^.db)^.nDb - 1 do sqlite3VdbeUsesBtree(p, j);
end;

procedure sqlite3VdbeEndCoroutine(v: PVdbe; regYield: i32);
begin
  sqlite3VdbeAddOp1(v, OP_EndCoroutine, regYield);
  { Clear temp register cache to give each co-routine its own register set }
  PByte(v^.pParse)[31] := 0;  { Parse.nTempReg = 0 (offset 31) }
  Pi32(PByte(v^.pParse) + 44)^ := 0;  { Parse.nRangeReg = 0 (offset 44) }
end;

{ --- RunOnlyOnce / Reusable --- }

procedure sqlite3VdbeRunOnlyOnce(p: PVdbe);
begin
  sqlite3VdbeAddOp2(p, OP_Expire, 1, 1);
end;

procedure sqlite3VdbeReusable(p: PVdbe);
var
  i: i32;
begin
  for i := 1 to p^.nOp - 1 do begin
    if p^.aOp[i].opcode = OP_Expire then begin
      p^.aOp[1].opcode := OP_Noop;
      Break;
    end;
  end;
end;

{ --- Debug assertion stubs --- }

function sqlite3VdbeAssertMayAbort(v: PVdbe; mayAbort: i32): i32;
begin
  Result := 1;  { always return true in non-debug build }
end;

procedure sqlite3VdbeIncrWriteCounter(p: PVdbe; pC: PVdbeCursor);
begin
  { vdbeaux.c:829 is SQLITE_DEBUG-only; nWrite not present in release struct }
end;

{ sqlite3VdbeCountChanges — port of vdbeaux.c:5315.
  Set the changeCntOn flag so that the VDBE updates the change counter. }
procedure sqlite3VdbeCountChanges(v: PVdbe);
begin
  if v <> nil then
    v^.vdbeFlags := v^.vdbeFlags or VDBF_ChangeCntOn;
end;

procedure sqlite3VdbeAssertAbortable(p: PVdbe);
begin
end;

procedure sqlite3VdbeNoJumpsOutsideSubrtn(v: PVdbe; iFstirst, iLast: i32;
                                          regReturn: i32);
begin
end;

procedure sqlite3VdbeVerifyNoMallocRequired(p: PVdbe; N: i32);
begin
end;

procedure sqlite3VdbeVerifyNoResultRow(p: PVdbe);
begin
end;

procedure sqlite3VdbeVerifyAbortable(p: PVdbe; onError: i32);
begin
  { Faithful port of vdbeaux.c:1106 (SQLITE_DEBUG-gated in C; emitted
    unconditionally here so explain-parity vs the reference debug build
    matches). }
  if onError = OE_Abort then sqlite3VdbeAddOp0(p, OP_Abortable);
end;

{ --- Display helpers --- }

{ Phase 6.21 port — vdbeaux.c:1740 sqlite3VdbeDisplayComment.

  Renders the EXPLAIN "comment" column for a single VDBE opcode.  The C
  reference is gated on SQLITE_ENABLE_EXPLAIN_COMMENTS (which the oracle
  build at src/tests/build.sh:53 enables); this port produces the same
  synopsis-driven text so EXPLAIN output can be diffed against the C
  reference once TestExplainParity expands its scope to include the
  comment column (currently restricted to (op,p1,p2,p3,p5)).

  The synopsis text is stored in a separate per-opcode table
  (vdbeOpcodeSynopsis below) instead of being embedded in the opcode
  name like in the C `opcodes.c` generated file — Pascal string-literal
  arrays have no clean syntax for embedded NULs, and lookup tables of
  192 entries are tractable enough on their own.

  pOp^.zComment (the comment field carried by each opcode at codegen
  time) is not present on the Pas TVdbeOp record (no SQLITE_DEBUG-style
  per-instruction comments wired yet), so the zComment branches are
  short-circuited.  When such a field is added, the corresponding
  branches can simply be re-enabled. }
function vdbeOpcodeSynopsis(op: i32): PAnsiChar;
const Syn: array[0..191] of PAnsiChar = (
  '', '', '', '', '', '',
  'iplan=r[P3] zplan=''P4''',
  'data=r[P3@P2]',
  'Start at P2',
  '', '', '', '', '', '', '', '', '',
  'if typeof(P1.P3) in P5 goto P2',
  'r[P2]= !r[P1]',
  'if P1.nullRow then r[P3]=NULL, goto P2',
  'key=r[P3@P4]', 'key=r[P3@P4]', 'key=r[P3@P4]', 'key=r[P3@P4]',
  'if( !csr[P1] ) goto P2',
  'key=r[P3@P4]', 'key=r[P3@P4]', 'key=r[P3@P4]', 'key=r[P3@P4]',
  'intkey=r[P3]', 'intkey=r[P3]',
  '', '', '', '', '',
  'if( empty(P1) ) goto P2',
  '', '', '',
  'key=r[P3@P4]', 'key=r[P3@P4]',
  'r[P3]=(r[P1] || r[P2])',
  'r[P3]=(r[P1] && r[P2])',
  'key=r[P3@P4]', 'key=r[P3@P4]',
  '',
  'r[P3]=rowset(P1)',
  'if r[P3] in rowset(P1) goto P2',
  '',
  'if r[P1]==NULL goto P2',
  'if r[P1]!=NULL goto P2',
  'IF r[P3]!=r[P1]', 'IF r[P3]==r[P1]', 'IF r[P3]>r[P1]',
  'IF r[P3]<=r[P1]', 'IF r[P3]<r[P1]', 'IF r[P3]>=r[P1]',
  '',
  'if fkctr[P1]==0 goto P2',
  'if r[P1]>0 then r[P1]-=P3, goto P2',
  'if r[P1]!=0 then r[P1]--, goto P2',
  'if (--r[P1])==0 goto P2',
  '', '',
  'if key(P3@P4) not in filter(P1) goto P2',
  'r[P3]=func(r[P2@NP])', 'r[P3]=func(r[P2@NP])',
  '', '',
  'if r[P3]=null halt',
  '',
  'r[P2]=P1', 'r[P2]=P4',
  'r[P2]=''P4'' (len=P1)',
  'r[P2]=NULL', 'r[P2..P3]=NULL', 'r[P1]=NULL',
  'r[P2]=P4 (len=P1)',
  'r[P2]=parameter(P1)',
  'r[P2@P3]=r[P1@P3]', 'r[P2@P3+1]=r[P1@P3+1]',
  'r[P2]=r[P1]', 'r[P2]=r[P1]',
  '',
  'output=r[P1@P2]',
  '',
  'r[P1]=r[P1]+P2',
  '',
  'affinity(r[P1])',
  '',
  'r[P1@P3] <-> r[P2@P3]',
  'r[P2] = coalesce(r[P1]==TRUE,P3) ^ P4',
  'r[P2] = 0 OR NULL',
  'r[P3] = sqlite_offset(P1)',
  'r[P3]=PX cursor P1 column P2',
  'typecheck(r[P1@P2])',
  'affinity(r[P1@P2])',
  'r[P3]=mkrec(r[P1@P2])',
  'r[P2]=count()',
  '', '',
  'r[P3]=r[P1]&r[P2]', 'r[P3]=r[P1]|r[P2]',
  'r[P3]=r[P2]<<r[P1]', 'r[P3]=r[P2]>>r[P1]',
  'r[P3]=r[P1]+r[P2]', 'r[P3]=r[P2]-r[P1]',
  'r[P3]=r[P1]*r[P2]', 'r[P3]=r[P2]/r[P1]',
  'r[P3]=r[P2]%r[P1]', 'r[P3]=r[P2]+r[P1]',
  'root=P2 iDb=P3', 'root=P2 iDb=P3',
  'r[P2]= ~r[P1]',
  'root=P2 iDb=P3',
  '',
  'r[P2]=''P4''',
  'nColumn=P2', 'nColumn=P2',
  '',
  'if( cursor[P1].ctr++ ) pc = P2',
  'P3 columns in r[P2]',
  '', '',
  'Scan-ahead up to P1 rows',
  'set P2<=seekHit<=P3',
  'r[P2]=cursor[P1].ctr++',
  'r[P2]=rowid',
  'intkey=r[P3] data=r[P2]',
  '', '', '',
  'if key(P1)!=trim(r[P3],P4) goto P2',
  'r[P2]=data', 'r[P2]=data',
  'r[P2]=PX rowid of P1',
  '', '',
  'key=r[P2]', 'key=r[P2]',
  'key=r[P2@P3]',
  'Move P3 to P1.rowid if needed',
  'r[P2]=rowid',
  '', '', '', '',
  'r[P2]=root iDb=P1 flags=P3',
  '', '', '',
  '',
  'r[P2]=P4',
  '', '', '',
  'rowset(P1)=r[P2]',
  '',
  'fkctr[P1]+=P2',
  'r[P1]=max(r[P1],r[P2])',
  'if r[P1]>0 then r[P2]=r[P1]+max(0,r[P3]) else r[P2]=(-1)',
  'accum=r[P3] inverse(r[P2@P5])',
  'accum=r[P3] step(r[P2@P5])',
  'accum=r[P3] step(r[P2@P5])',
  'r[P3]=value N=P2',
  'accum=r[P1] N=P2',
  '', '', '',
  'iDb=P1 root=P2 write=P3',
  '', '', '', '', '',
  'r[P2]=ValueList(P1,P3)',
  'r[P3]=vcolumn(P2)',
  '',
  '', '',
  'r[P1].subtype = 0',
  'r[P2] = r[P1].subtype',
  'r[P2].subtype = r[P1]',
  'filter(P1) += key(P3@P4)',
  '', '',
  'release r[P1@P2] mask P3',
  '', '', ''
);
begin
  if (op >= 0) and (op <= 191) then
    Result := Syn[op]
  else
    Result := '';
end;

function translateP(c: AnsiChar; pOp: PVdbeOp): i32; inline;
begin
  case c of
    '1': Result := pOp^.p1;
    '2': Result := pOp^.p2;
    '3': Result := pOp^.p3;
    '4': Result := pOp^.p4.i;
  else   Result := i32(pOp^.p5);
  end;
end;

function sqlite3VdbeDisplayComment(db: Psqlite3; pOp: PVdbeOp; zP4: PAnsiChar): PAnsiChar;
var
  zSynopsis: PAnsiChar;
  zAlt:      array[0..49] of AnsiChar;
  ii:        i32;
  c:         AnsiChar;
  v1, v2:    i32;
  pStr:      PSqlite3Str;
  pCtx:      Psqlite3_context;
begin
  Result := nil;
  zSynopsis := vdbeOpcodeSynopsis(pOp^.opcode);
  if (zSynopsis = nil) or (zSynopsis[0] = #0) then Exit;

  pStr := sqlite3_str_new(Psqlite3db(db));
  if pStr = nil then Exit;

  if (zSynopsis[0] = 'I') and (zSynopsis[1] = 'F') and (zSynopsis[2] = ' ') then begin
    { Hand-rolled `snprintf("if %s goto P2", zSynopsis+3)` — sqlite3_snprintf
      in this port handles only no-arg fmt strings. }
    ii := 0;
    zAlt[0] := 'i'; zAlt[1] := 'f'; zAlt[2] := ' ';
    ii := 3;
    while (zSynopsis[ii] <> #0) and (ii < SizeOf(zAlt) - 12) do begin
      zAlt[ii] := zSynopsis[ii]; Inc(ii);
    end;
    zAlt[ii] := ' '; zAlt[ii+1] := 'g'; zAlt[ii+2] := 'o'; zAlt[ii+3] := 't';
    zAlt[ii+4] := 'o'; zAlt[ii+5] := ' '; zAlt[ii+6] := 'P'; zAlt[ii+7] := '2';
    zAlt[ii+8] := #0;
    zSynopsis := @zAlt[0];
  end;

  ii := 0;
  c := zSynopsis[ii];
  while c <> #0 do begin
    if c = 'P' then begin
      Inc(ii);
      c := zSynopsis[ii];
      if c = '4' then begin
        if zP4 <> nil then sqlite3_str_appendall(pStr, zP4);
      end else if c = 'X' then begin
        { pOp->zComment branch — not present in Pas TVdbeOp; skip }
      end else begin
        v1 := translateP(c, pOp);
        if (zSynopsis[ii+1] = '@') and (zSynopsis[ii+2] = 'P') then begin
          Inc(ii, 3);
          v2 := translateP(zSynopsis[ii], pOp);
          if (zSynopsis[ii+1] = '+') and (zSynopsis[ii+2] = '1') then begin
            Inc(ii, 2);
            Inc(v2);
          end;
          if v2 < 2 then
            sqlite3_str_appendf(pStr, '%d', [v1])
          else
            sqlite3_str_appendf(pStr, '%d..%d', [v1, v1+v2-1]);
        end else if (zSynopsis[ii+1] = '@') and (zSynopsis[ii+2] = 'N')
                and (zSynopsis[ii+3] = 'P') then begin
          pCtx := pOp^.p4.pCtx;
          if (pOp^.p4type <> P4_FUNCCTX) or (pCtx^.argc = 1) then
            sqlite3_str_appendf(pStr, '%d', [v1])
          else if pCtx^.argc > 1 then
            sqlite3_str_appendf(pStr, '%d..%d', [v1, v1 + i32(pCtx^.argc) - 1])
          else if pStr^.accError = 0 then begin
            Assert(pStr^.nChar > 2, 'DisplayComment: nChar>2 required for @NP rewind');
            pStr^.nChar := pStr^.nChar - 2;
            Inc(ii);
          end;
          Inc(ii, 3);
        end else begin
          sqlite3_str_appendf(pStr, '%d', [v1]);
          if (zSynopsis[ii+1] = '.') and (zSynopsis[ii+2] = '.')
             and (zSynopsis[ii+3] = 'P') and (zSynopsis[ii+4] = '3')
             and (pOp^.p3 = 0) then
            Inc(ii, 4);
        end;
      end;
    end else begin
      sqlite3_str_appendchar(pStr, 1, c);
    end;
    Inc(ii);
    c := zSynopsis[ii];
  end;

  if (pStr^.accError and SQLITE_NOMEM) <> 0 then begin
    if db <> nil then sqlite3OomFault(db);
  end;
  Result := sqlite3_str_finish(pStr);
end;

{ sqlite3VdbeDisplayP4 — vdbeaux.c:1905.  Renders the P4 operand of an
  opcode as a heap-allocated string (caller must sqlite3_free).  Real body
  lives in passqlite3codegen via the gDisplayP4 hook (needs PTable/PIndex
  field access not visible to this unit); the standalone arms (P4_INT32,
  P4_INT64, P4_REAL, P4_FUNCDEF, P4_FUNCCTX, P4_INTARRAY, P4_SUBPROGRAM,
  P4_MEM, P4_VTAB, default) are handled inline so the helper still works
  for opcode display in vdbe-only test programs. }
function sqlite3VdbeDisplayP4(db: Psqlite3; pOp: PVdbeOp): PAnsiChar;
var
  pFD:  PTFuncDef;
  pCx:  Psqlite3_context;
  pM:   PMem;
  ai:   Pu32;
  i, n: u32;
  zRes: PAnsiChar;
begin
  if Assigned(gDisplayP4) then
  begin
    zRes := gDisplayP4(db, pOp);
    if zRes <> nil then begin Result := zRes; Exit; end;
  end;
  case pOp^.p4type of
    P4_FUNCDEF:
      begin
        pFD := PTFuncDef(pOp^.p4.pFunc);
        Result := sqlite3MPrintf(PTsqlite3(db), '%s(%d)',
                                 [pFD^.zName, i32(pFD^.nArg)]);
      end;
    P4_FUNCCTX:
      begin
        pCx := pOp^.p4.pCtx;
        pFD := PTFuncDef(pCx^.pFunc);
        Result := sqlite3MPrintf(PTsqlite3(db), '%s(%d)',
                                 [pFD^.zName, i32(pFD^.nArg)]);
      end;
    P4_INT64:
      Result := sqlite3MPrintf(PTsqlite3(db), '%lld', [pOp^.p4.pI64^]);
    P4_INT32:
      Result := sqlite3MPrintf(PTsqlite3(db), '%d', [pOp^.p4.i]);
    P4_REAL:
      Result := sqlite3MPrintf(PTsqlite3(db), '%.16g', [pOp^.p4.pReal^]);
    P4_MEM:
      begin
        pM := pOp^.p4.pMem;
        if (pM^.flags and MEM_Str) <> 0 then
          Result := sqlite3MPrintf(PTsqlite3(db), '%s', [pM^.z])
        else if (pM^.flags and (MEM_Int or MEM_IntReal)) <> 0 then
          Result := sqlite3MPrintf(PTsqlite3(db), '%lld', [pM^.u.i])
        else if (pM^.flags and MEM_Real) <> 0 then
          Result := sqlite3MPrintf(PTsqlite3(db), '%.16g', [pM^.u.r])
        else if (pM^.flags and MEM_Null) <> 0 then
          Result := sqlite3MPrintf(PTsqlite3(db), 'NULL', [])
        else
          Result := sqlite3MPrintf(PTsqlite3(db), '(blob)', []);
      end;
    P4_VTAB:
      Result := sqlite3MPrintf(PTsqlite3(db), 'vtab:%p',
                               [Pointer(pOp^.p4.pVtab)]);
    P4_INTARRAY:
      begin
        ai := pOp^.p4.ai;
        if ai = nil then begin Result := nil; Exit; end;
        n := ai[0];
        if n = 0 then
          Result := sqlite3MPrintf(PTsqlite3(db), '[]', [])
        else
        begin
          Result := sqlite3MPrintf(PTsqlite3(db), '[%u', [ai[1]]);
          for i := 2 to n do
            Result := sqlite3MPrintf(PTsqlite3(db), '%z,%u', [Result, ai[i]]);
          Result := sqlite3MPrintf(PTsqlite3(db), '%z]', [Result]);
        end;
      end;
    P4_SUBPROGRAM:
      Result := sqlite3MPrintf(PTsqlite3(db), 'program', []);
    P4_SUBRTNSIG:
      Result := sqlite3MPrintf(PTsqlite3(db), 'subrtnsig:%d,%s',
                               [pOp^.p4.pSubrtnSig^.selId,
                                pOp^.p4.pSubrtnSig^.zAff]);
    P4_COLLSEQ:
      begin
        { encnames mirror vdbeaux.c:1935 }
        case PTCollSeq(pOp^.p4.pColl)^.enc of
          1: Result := sqlite3MPrintf(PTsqlite3(db), '%.18s-8',
                                       [PTCollSeq(pOp^.p4.pColl)^.zName]);
          2: Result := sqlite3MPrintf(PTsqlite3(db), '%.18s-16LE',
                                       [PTCollSeq(pOp^.p4.pColl)^.zName]);
          3: Result := sqlite3MPrintf(PTsqlite3(db), '%.18s-16BE',
                                       [PTCollSeq(pOp^.p4.pColl)^.zName]);
        else
          Result := sqlite3MPrintf(PTsqlite3(db), '%.18s-?',
                                    [PTCollSeq(pOp^.p4.pColl)^.zName]);
        end;
      end;
    P4_KEYINFO, P4_TABLE, P4_TABLEREF, P4_INDEX:
      Result := nil;  { handled by gDisplayP4 hook above when wired }
  else
    if pOp^.p4.z <> nil then
      Result := sqlite3MPrintf(PTsqlite3(db), '%s', [pOp^.p4.z])
    else
      Result := nil;
  end;
end;

procedure sqlite3VdbeUsesBtree(p: PVdbe; i: i32);
begin
  p^.btreeMask := p^.btreeMask or (yDbMask(1) shl i);
end;

{ sqlite3VdbeEnter / sqlite3VdbeLeave — OMIT_SHARED_CACHE no-ops.
  C reference: vdbeaux.c:2066/2101 are bodied only when
  !defined(SQLITE_OMIT_SHARED_CACHE) && SQLITE_THREADSAFE>0; otherwise
  vdbeInt.h:714/720 expand them to empty macros.  The Pas port has no
  shared-cache, so the empty body is the faithful port. }
procedure sqlite3VdbeEnter(p: PVdbe);
begin
end;

procedure sqlite3VdbeLeave(p: PVdbe);
begin
end;

procedure sqlite3VdbePrintOp(pOut: Pointer; pc: i32; pOp: PVdbeOp);
begin
  { Full implementation is in vdbetrace.c (Phase 5.8) }
end;

{ --- Frame helpers --- }

function sqlite3VdbeFrameIsValid(pFrame: PVdbeFrame): i32;
begin
  if pFrame = nil then Result := 0 else Result := 1;
end;

procedure sqlite3VdbeFrameMemDel(pArg: Pointer); cdecl;
{ Port of vdbeaux.c:2247.  Mem destructor that defers the actual frame
  free until the owning Vdbe halts (so OP_Program callers can still walk
  the frame chain after the sub-program returns). }
var
  pFrame: PVdbeFrame;
begin
  pFrame := PVdbeFrame(pArg);
  pFrame^.pParent := pFrame^.v^.pDelFrame;
  pFrame^.v^.pDelFrame := pFrame;
end;

{ sqlite3VdbeNextOpcode — port of vdbeaux.c:2262.
  Locate the next opcode to be displayed in EXPLAIN or EXPLAIN QUERY PLAN
  output.  Returns SQLITE_ROW on success, SQLITE_DONE when no more opcodes
  remain.  pSub stores subprogram-nesting state across calls (initially a
  zero-flagged Mem; promoted to MEM_Blob holding a SubProgram*[] array
  the first time an OP_Program with a P4_SUBPROGRAM argument is seen).
  eMode: 0=normal, 1=EQP (stop at OP_Explain), 2=TablesUsed (gated on
  SQLITE_ENABLE_BYTECODE_VTAB, off in default upstream build). }
function sqlite3VdbeNextOpcode(p: PVdbe; pSub: PMem; eMode: i32;
                               piPc: Pi32; piAddr: Pi32; paOp: PPVdbeOp): i32;
var
  nRow:  i32;
  nSub:  i32;
  apSub: PPSubProgram;
  i:     i32;
  j:     i32;
  rc:    i32;
  aOp:   PVdbeOp;
  iPc:   i32;
  pOp:   PVdbeOp;
  nByte: i32;
begin
  nSub  := 0;
  apSub := nil;
  rc    := SQLITE_OK;
  aOp   := nil;
  i     := 0;

  { When the number of output rows reaches nRow, that means the listing
    has finished and sqlite3_step() should return SQLITE_DONE.  nRow is
    the sum of the number of rows in the main program plus the number of
    rows in all trigger subprograms encountered so far. }
  nRow := p^.nOp;
  if pSub <> nil then
  begin
    if (pSub^.flags and MEM_Blob) <> 0 then
    begin
      nSub  := pSub^.n div SizeOf(PSubProgram);
      apSub := PPSubProgram(pSub^.z);
    end;
    j := 0;
    while j < nSub do
    begin
      nRow := nRow + apSub[j]^.nOp;
      Inc(j);
    end;
  end;
  iPc := piPc^;
  while True do
  begin
    i := iPc;
    Inc(iPc);
    if i >= nRow then
    begin
      p^.rc := SQLITE_OK;
      rc := SQLITE_DONE;
      Break;
    end;
    if i < p^.nOp then
    begin
      aOp := p^.aOp;
    end
    else
    begin
      i := i - p^.nOp;
      Assert(apSub <> nil);
      Assert(nSub > 0);
      j := 0;
      while i >= apSub[j]^.nOp do
      begin
        i := i - apSub[j]^.nOp;
        Assert((i < apSub[j]^.nOp) or (j + 1 < nSub));
        Inc(j);
      end;
      aOp := apSub[j]^.aOp;
    end;

    { When an OP_Program opcode is encountered (the only opcode that has
      a P4_SUBPROGRAM argument), expand the size of the array of
      subprograms kept in pSub->z to hold the new program — assuming the
      subprogram has not already been seen. }
    if (pSub <> nil) and (aOp[i].p4type = P4_SUBPROGRAM) then
    begin
      nByte := (nSub + 1) * i32(SizeOf(PSubProgram));
      j := 0;
      while j < nSub do
      begin
        if apSub[j] = aOp[i].p4.pProgram then Break;
        Inc(j);
      end;
      if j = nSub then
      begin
        if nSub <> 0 then p^.rc := sqlite3VdbeMemGrow(pSub, nByte, 1)
        else                p^.rc := sqlite3VdbeMemGrow(pSub, nByte, 0);
        if p^.rc <> SQLITE_OK then
        begin
          rc := SQLITE_ERROR;
          Break;
        end;
        apSub := PPSubProgram(pSub^.z);
        apSub[nSub] := aOp[i].p4.pProgram;
        Inc(nSub);
        { MemSetTypeFlag(pSub, MEM_Blob) — clear all type bits then set MEM_Blob. }
        pSub^.flags := (pSub^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Blob;
        pSub^.n     := nSub * i32(SizeOf(PSubProgram));
        nRow        := nRow + apSub[nSub - 1]^.nOp;
      end;
    end;
    if eMode = 0 then Break;
    { SQLITE_ENABLE_BYTECODE_VTAB (eMode=2) — off in default upstream build. }
    Assert(eMode = 1);
    pOp := @aOp[i];
    if pOp^.opcode = OP_Explain then Break;
    if (pOp^.opcode = OP_Init) and (iPc > 1) then Break;
  end;
  piPc^   := iPc;
  piAddr^ := i;
  paOp^   := aOp;
  Result := rc;
end;

procedure sqlite3VdbeFrameDelete(p: PVdbeFrame);
begin
  sqlite3DbFree(p^.v^.db, p);
end;

{ sqlite3VdbeFrameRestore — port of vdbeaux.c:2812.
  Forwards to sqlite3VdbeFrameRestoreFull (see further down in this unit) which
  already mirrors the C body line-for-line; consolidating the two declarations
  here so the real implementation is reachable through both names. }
function sqlite3VdbeFrameRestoreFull(pFrame: PVdbeFrame): i32; forward;
function sqlite3VdbeFrameRestore(pFrame: PVdbeFrame): i32;
begin
  Result := sqlite3VdbeFrameRestoreFull(pFrame);
  Exit;
end;

{ --- VdbeMakeReady / VdbeRewind --- }

procedure sqlite3VdbeRewind(p: PVdbe);
begin
  p^.eVdbeState := VDBE_READY_STATE;
  p^.pc         := -1;
  p^.rc         := SQLITE_OK;
  p^.errorAction := OE_Abort;
  p^.nChange    := 0;
  p^.cacheCtr   := 1;
  p^.minWriteFileFormat := 255;
  p^.iStatement := 0;
  p^.nFkConstraint := 0;
end;

procedure sqlite3VdbeMakeReady(p: PVdbe; pParse: PParse);
var
  db:      Psqlite3db;
  nVar:    i32;
  nMem:    i32;
  nCursor: i32;
  nArg:    i32;
  n:       i32;
begin
  db      := p^.db;
  { Parse field offsets (verified against passqlite3codegen.TParse layout):
    nTab @56 (i32), nMem @60 (i32), nVar @296 (i16), pVList @320 (Pointer). }
  nCursor := PInt32(PByte(pParse) + 56)^;
  nMem    := PInt32(PByte(pParse) + 60)^;
  nVar    := i32(PWord(PByte(pParse) + 296)^);
  nArg    := 0;
  { vdbeaux.c:2665 — transfer the variable-name VList from Parse to Vdbe.
    Required by sqlite3_bind_parameter_name / _index. }
  p^.pVList := PPointer(PByte(pParse) + 320)^;
  PPointer(PByte(pParse) + 320)^ := nil;

  n := vdbeParseSzOpAllocPtr(pParse)^;
  resolveP2Values(p, @nArg);

  p^.vdbeFlags := p^.vdbeFlags and not (VDBF_UsesStmtJournal or VDBF_EXPIRED_MASK);
  { vdbeaux.c:2694 — p->usesStmtJournal = pParse->isMultiWrite && pParse->mayAbort.
    Without this assignment the statement-journal arm in OP_Transaction is never
    taken, so a constraint-aborted CREATE INDEX (or any failing multi-write DDL)
    leaves the sqlite_master insert + freshly allocated btree root page
    committed when the enclosing transaction commits — yielding integrity_check
    "Page N: never used" (9.4.divbug.87.026, index3-1.4). }
  { Parse offsets: isMultiWrite is u8 @32; parseFlags is u32 @40, mayAbort=bit 1. }
  if (PByte(PByte(pParse) + 32)^ <> 0) and
     ((PUInt32(PByte(pParse) + 40)^ and u32(1 shl 1)) <> 0) then
    p^.vdbeFlags := p^.vdbeFlags or VDBF_UsesStmtJournal;

  { Port of vdbeaux.c:2695..2699 — propagate Parse.explain into the Vdbe and
    set the EXPLAIN result-column count.  EXPLAIN emits 8 columns
    (addr, opcode, p1, p2, p3, p4, p5, comment); EXPLAIN QUERY PLAN emits 4
    (id, parent, notused, detail).  The makeReady-ready aMem array must
    have nMem>=10 so cell [9] is available as the SubProgram array slot
    used by sqlite3VdbeNextOpcode when listing trigger subprograms. }
  if PByte(PByte(pParse) + 299)^ <> 0 then begin
    if nMem < 10 then nMem := 10;
    p^.vdbeFlags := (p^.vdbeFlags and not u32(VDBF_EXPLAIN_MASK))
                    or (u32(PByte(PByte(pParse) + 299)^) shl VDBF_EXPLAIN_SHIFT);
    p^.nResColumn := u16(12 - 4 * i32(PByte(PByte(pParse) + 299)^));
  end;

  { Reserve nCursor extra Mem cells at the top of aMem[] for VdbeCursor
    storage — allocateCursor() places cursor i at aMem[nMem-i] for i>0,
    so without this bump the cursor slot collides with a regular register
    and any OP_MakeRecord / OP_String write into that register clobbers
    the cursor (causing eCurType corruption at sqlite3_finalize).
    Port of vdbeaux.c:2679 (`nMem += nCursor`). }
  nMem := nMem + nCursor;
  if (nCursor = 0) and (nMem > 0) then Inc(nMem);

  { allocate Mem registers (aMem[1..nMem] are user registers; aMem[0] is
    the unused slot held by all VDBE programs).  Phase 6.9-bis. }
  { Bug 6.16: nMem/aMem must be set unconditionally to avoid stale values
    from the raw-malloc'd Vdbe surviving when nMem=0. }
  if vdbeDbMallocFailed(db) or (nMem <= 0) then begin
    p^.nMem := 0;
    p^.aMem := nil;
  end;
  if (not vdbeDbMallocFailed(db)) and (nMem > 0) then begin
    p^.aMem := PMem(sqlite3DbMallocZero(db,
                                       u64(nMem + 1) * SizeOf(TMem)));
    p^.nMem := nMem;
    { initMemArray (vdbeaux.c:2740): every Mem slot must carry db so that
      callbacks like sqlite3_context_db_handle (which reads pCtx^.pOut^.db)
      do not deref a NULL.  Default flags are MEM_Undefined for aMem
      registers; flag bits left zero are corrected on first write. }
    if p^.aMem <> nil then begin
      n := 0;
      while n <= nMem do begin
        (p^.aMem + n)^.db := db;
        Inc(n);
      end;
    end;
  end;
  { vdbeaux.c:2731-2742 — apCsr/nCursor must be set unconditionally so
    closeAllCursors sees a coherent (apCsr=nil, nCursor=0) on the
    zero-cursor path; otherwise the raw-malloc'd Vdbe retains stale
    apCsr/nCursor from a previously freed Vdbe at the same address and
    sqlite3VdbeHalt dereferences a bogus pointer (bug 6.16). }
  if vdbeDbMallocFailed(db) then begin
    p^.nCursor := 0;
    p^.apCsr   := nil;
  end else if nCursor > 0 then begin
    p^.apCsr := PPVdbeCursor(sqlite3DbMallocZero(db,
                             u64(nCursor) * SizeOf(PVdbeCursor)));
    p^.nCursor := nCursor;
  end else begin
    p^.nCursor := 0;
    p^.apCsr   := nil;
  end;

  { Port of vdbeaux.c:2714/2737-2738 — allocate aVar[] and set nVar so
    OP_Variable / sqlite3_bind_* can resolve `?N`/`:name`/`@name`/`$name`
    parameters.  Each slot is initialised to MEM_Null with a back-pointer
    to db (initMemArray contract). }
  if vdbeDbMallocFailed(db) then
    p^.nVar := 0
  else
    p^.nVar := ynVar(nVar);
  if (not vdbeDbMallocFailed(db)) and (nVar > 0) then begin
    p^.aVar := PMem(sqlite3DbMallocZero(db, u64(nVar) * SizeOf(TMem)));
    if p^.aVar <> nil then begin
      n := 0;
      while n < nVar do begin
        (p^.aVar + n)^.db    := db;
        (p^.aVar + n)^.flags := MEM_Null;
        Inc(n);
      end;
    end else
      p^.nVar := 0;
  end;

  sqlite3VdbeRewind(p);
end;

{ --- Cursor management --- }

procedure sqlite3VdbeFreeCursorNN(p: PVdbe; pCx: PVdbeCursor);
type
  TxCloseFn = function(pCur: passqlite3vtab.PSqlite3VtabCursor): i32; cdecl;
var
  pVCur:   passqlite3vtab.PSqlite3VtabCursor;
  pVtab:   passqlite3vtab.PSqlite3Vtab;
  pModule: passqlite3vtab.PSqlite3Module;
  xClose:  TxCloseFn;
  pCache:  PVdbeTxtBlbCache;
begin
  { Port of vdbeaux.c freeCursorWithCache: drop the RCStr-cached overflow
    buffer (if any) before tearing down the underlying cursor. }
  if (pCx^.cursorFlags and VDBC_ColCache) <> 0 then begin
    pCache := pCx^.pCache;
    pCx^.cursorFlags := pCx^.cursorFlags and not u32(VDBC_ColCache);
    pCx^.pCache := nil;
    if (pCache <> nil) and (pCache^.pCValue <> nil) then begin
      sqlite3RCStrUnref(pCache^.pCValue);
      pCache^.pCValue := nil;
    end;
    sqlite3DbFree(Psqlite3db(p^.db), pCache);
  end;
  case pCx^.eCurType of
    CURTYPE_BTREE: begin
      if (pCx^.cursorFlags and VDBC_Ephemeral) <> 0 then begin
        { Ephemeral table: owner cursor (noReuse=0) closes the whole Btree;
          shared/dup cursor (noReuse=1) only closes its own BtCursor. }
        if (pCx^.cursorFlags and VDBC_NoReuse) = 0 then begin
          if pCx^.ub.pBtx <> nil then
            sqlite3BtreeClose(pCx^.ub.pBtx);
          { BtCursor closed automatically by BtreeClose }
        end else begin
          if pCx^.uc.pCursor <> nil then
            sqlite3BtreeCloseCursor(pCx^.uc.pCursor);
        end;
      end else begin
        if pCx^.uc.pCursor <> nil then
          sqlite3BtreeCloseCursor(pCx^.uc.pCursor);
      end;
    end;
    { CURTYPE_VTAB — Phase 6.bis.3b — vdbeaux.c:closeCursor }
    CURTYPE_VTAB: begin
      pVCur := passqlite3vtab.PSqlite3VtabCursor(pCx^.uc.pVCur);
      if pVCur <> nil then begin
        pVtab := pVCur^.pVtab;
        if pVtab <> nil then begin
          pModule := pVtab^.pModule;
          if (pModule <> nil) and (pModule^.xClose <> nil) then begin
            xClose := TxCloseFn(pModule^.xClose);
            xClose(pVCur);
          end;
          if pVtab^.nRef > 0 then Dec(pVtab^.nRef);
        end;
      end;
    end;
    { CURTYPE_SORTER: defer to Phase 5.7 }
  end;
  { The cursor itself is part of aMem space; no free needed }
end;

procedure sqlite3VdbeFreeCursor(p: PVdbe; pCx: PVdbeCursor);
begin
  if pCx <> nil then sqlite3VdbeFreeCursorNN(p, pCx);
end;

{ --- Column name management --- }

{ Internal helper — release any allocated Mem auxiliary memory in the
  aColName array before the array itself is freed.  Mirrors the relevant
  arms of releaseMemArray (vdbeaux.c:2179) for the limited subset of
  flags column-name Mem cells can carry: MEM_Dyn / MEM_Agg via xDel,
  or szMalloc/zMalloc via the small-buffer path. }
procedure vdbeReleaseColNames(p: PMem; N: i32);
var
  i: i32;
  pCell: PMem;
begin
  if (p = nil) or (N <= 0) then Exit;
  for i := 0 to N - 1 do begin
    pCell := PMem(PtrUInt(p) + PtrUInt(i) * SizeOf(TMem));
    if (pCell^.flags and (MEM_Agg or MEM_Dyn)) <> 0 then begin
      sqlite3VdbeMemRelease(pCell);
      pCell^.flags := MEM_Undefined;
    end else if pCell^.szMalloc > 0 then begin
      sqlite3DbFree(pCell^.db, pCell^.zMalloc);
      pCell^.zMalloc := nil;
      pCell^.szMalloc := 0;
      pCell^.flags := MEM_Undefined;
    end;
  end;
end;

{ vdbeaux.c:2866 — set the number of result columns this VDBE will emit.
  Allocates aColName as nResColumn*COLNAME_N Mem cells, each initialised
  to MEM_Null with db backref, ready for sqlite3VdbeSetColName to fill in
  the various COLNAME_* slots. }
procedure sqlite3VdbeSetNumCols(p: PVdbe; nResColumn: i32);
var
  db: Psqlite3;
  n, i: i32;
  pCell: PMem;
begin
  db := p^.db;
  if p^.nResAlloc > 0 then begin
    vdbeReleaseColNames(p^.aColName, i32(p^.nResAlloc) * COLNAME_N);
    sqlite3DbFree(db, p^.aColName);
  end;
  n := nResColumn * COLNAME_N;
  p^.nResColumn := u16(nResColumn);
  p^.nResAlloc  := u16(nResColumn);
  p^.aColName := PMem(sqlite3DbMallocRawNN(db, SizeOf(TMem) * n));
  if p^.aColName = nil then Exit;
  for i := 0 to n - 1 do begin
    pCell := PMem(PtrUInt(p^.aColName) + PtrUInt(i) * SizeOf(TMem));
    FillChar(pCell^, SizeOf(TMem), 0);
    pCell^.flags := MEM_Null;
    pCell^.db    := db;
  end;
end;

{ vdbeaux.c:2891 — store zName at aColName[idx + slot*nResAlloc].
  slot is one of the COLNAME_* constants; xDel is SQLITE_DYNAMIC,
  SQLITE_STATIC or SQLITE_TRANSIENT. }
function sqlite3VdbeSetColName(p: PVdbe; idx, var2: i32; zName: PAnsiChar;
                               xDel: TxDelProc): i32;
var
  pColName: PMem;
begin
  Assert(idx < i32(p^.nResAlloc));
  Assert(var2 < COLNAME_N);
  if PTsqlite3(p^.db)^.mallocFailed <> 0 then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;
  Assert(p^.aColName <> nil);
  pColName := PMem(PtrUInt(p^.aColName) +
              PtrUInt(idx + var2 * i32(p^.nResAlloc)) * SizeOf(TMem));
  Result := sqlite3VdbeMemSetText(pColName, zName, -1, xDel);
end;

{ --- Statement close --- }

{ vdbeaux.c:3215 — vdbeCloseStatement (release/rollback the per-stmt savepoint
  on every attached btree, then on every vtab, then unwind nDeferredCons). }
function vdbeCloseStatement(p: PVdbe; eOp: i32): i32;
var
  db          : PTsqlite3;
  rc, rc2     : i32;
  i           : i32;
  iSavepoint  : i32;
  pBt         : PBtree;
  pAdb        : PtrUInt;
begin
  db         := PTsqlite3(p^.db);
  rc         := SQLITE_OK;
  iSavepoint := p^.iStatement - 1;
  for i := 0 to db^.nDb - 1 do begin
    pAdb := PtrUInt(db^.aDb) + PtrUInt(i) * SizeOf(TDb);
    pBt  := PBtree(PDb(pAdb)^.pBt);
    if pBt <> nil then begin
      rc2 := SQLITE_OK;
      if eOp = SAVEPOINT_ROLLBACK then
        rc2 := sqlite3BtreeSavepoint(pBt, SAVEPOINT_ROLLBACK, iSavepoint);
      if rc2 = SQLITE_OK then
        rc2 := sqlite3BtreeSavepoint(pBt, SAVEPOINT_RELEASE, iSavepoint);
      if rc = SQLITE_OK then rc := rc2;
    end;
  end;
  Dec(db^.nStatement);
  p^.iStatement := 0;
  if rc = SQLITE_OK then begin
    if eOp = SAVEPOINT_ROLLBACK then
      rc := sqlite3VtabSavepoint(db, SAVEPOINT_ROLLBACK, iSavepoint);
    if rc = SQLITE_OK then
      rc := sqlite3VtabSavepoint(db, SAVEPOINT_RELEASE, iSavepoint);
  end;
  if eOp = SAVEPOINT_ROLLBACK then begin
    db^.nDeferredCons    := p^.nStmtDefCons;
    db^.nDeferredImmCons := p^.nStmtDefImmCons;
  end;
  Result := rc;
end;

{ vdbeaux.c:3265 — sqlite3VdbeCloseStatement.  Outer guard: only walk the
  btrees when an outer transaction has actually opened a per-statement
  savepoint (db^.nStatement>0 and p^.iStatement set). }
function sqlite3VdbeCloseStatement(p: PVdbe; eOp: i32): i32;
begin
  if (PTsqlite3(p^.db)^.nStatement <> 0) and (p^.iStatement <> 0) then
    Result := vdbeCloseStatement(p, eOp)
  else
    Result := SQLITE_OK;
end;

{ vdbeaux.c:3284 — vdbeFkError.  Set the VM's rc/errorAction/zErrMsg
  to SQLITE_CONSTRAINT_FOREIGNKEY; return SQLITE_ERROR for a one-shot
  prepare (legacy sqlite3_prepare path) or SQLITE_CONSTRAINT_FOREIGNKEY
  when SQLITE_PREPARE_SAVESQL is set (sqlite3_prepare_v2). }
function vdbeFkError(p: PVdbe): i32;
begin
  p^.rc := SQLITE_CONSTRAINT_FOREIGNKEY;
  p^.errorAction := OE_Abort;
  sqlite3VdbeError(p, 'FOREIGN KEY constraint failed');
  if (p^.prepFlags and SQLITE_PREPARE_SAVESQL) = 0 then
    Result := SQLITE_ERROR
  else
    Result := SQLITE_CONSTRAINT_FOREIGNKEY;
end;

function sqlite3VdbeCheckFkImmediate(p: PVdbe): i32;
begin
  if p^.nFkConstraint = 0 then Exit(SQLITE_OK);
  Result := vdbeFkError(p);
end;

function sqlite3VdbeCheckFkDeferred(p: PVdbe): i32;
var
  db: PTsqlite3;
begin
  db := p^.db;
  if (db^.nDeferredCons + db^.nDeferredImmCons) = 0 then Exit(SQLITE_OK);
  Result := vdbeFkError(p);
end;

{ --- VdbeList — EXPLAIN output (vdbeaux.c:2406).
  Drives one row of EXPLAIN / EXPLAIN QUERY PLAN output per call.  Returns
  SQLITE_ROW with p^.pResultRow filled in, SQLITE_DONE when the listing is
  exhausted, SQLITE_ERROR on interrupt / OOM. }

function sqlite3VdbeList(v: PVdbe): i32;
var
  pSub:          PMem;
  db:            PTsqlite3;
  i:             i32;
  rc:            i32;
  pMm:           PMem;
  bListSubprogs: Boolean;
  aOp:           PVdbeOp;
  pOp:           PVdbeOp;
  zP4:           PAnsiChar;
  explainBits:   u32;
  k:             i32;
  pClk:          PMem;
begin
  pSub := nil;
  db   := v^.db;
  pMm  := @v^.aMem[1];
  explainBits := (v^.vdbeFlags and VDBF_EXPLAIN_MASK) shr VDBF_EXPLAIN_SHIFT;
  { SQLITE_TriggerEQP_Bit = $01000000 — inlined to avoid uses-cycle on main.pas. }
  bListSubprogs := (explainBits = 1)
                or ((db^.flags and u64($01000000)) <> 0);

  Assert(explainBits <> 0);
  Assert(v^.eVdbeState = VDBE_RUN_STATE);
  Assert((v^.rc = SQLITE_OK) or (v^.rc = SQLITE_BUSY) or (v^.rc = SQLITE_NOMEM));

  { Inlined releaseMemArray(pMm, 8) — see vdbeaux.c:2179.
    The first 8 result-set Mem cells get the prior row's payload freed
    so we can rewrite them below. }
  for k := 0 to 7 do begin
    pClk := PMem(PtrUInt(pMm) + PtrUInt(k) * SizeOf(TMem));
    if (pClk^.flags and (MEM_Agg or MEM_Dyn)) <> 0 then begin
      sqlite3VdbeMemRelease(pClk);
      pClk^.flags := MEM_Undefined;
    end else if pClk^.szMalloc > 0 then begin
      sqlite3DbFree(db, pClk^.zMalloc);
      pClk^.zMalloc := nil;
      pClk^.szMalloc := 0;
      pClk^.flags := MEM_Undefined;
    end else begin
      pClk^.flags := MEM_Undefined;
    end;
  end;

  if v^.rc = SQLITE_NOMEM then begin
    sqlite3OomFault(db);
    Exit(SQLITE_ERROR);
  end;

  if bListSubprogs then begin
    Assert(v^.nMem > 9);
    pSub := @v^.aMem[9];
  end;

  rc := sqlite3VdbeNextOpcode(v, pSub, Ord(explainBits = 2),
                              @v^.pc, @i, @aOp);

  if rc = SQLITE_OK then begin
    pOp := @aOp[i];
    if db^.u1.isInterrupted <> 0 then begin
      v^.rc := SQLITE_INTERRUPT;
      rc := SQLITE_ERROR;
      sqlite3VdbeError(v, sqlite3ErrStr(v^.rc));
    end else begin
      zP4 := sqlite3VdbeDisplayP4(db, pOp);
      if explainBits = 2 then begin
        sqlite3VdbeMemSetInt64(pMm, pOp^.p1);
        sqlite3VdbeMemSetInt64(@PMem(PtrUInt(pMm) + 1*SizeOf(TMem))^, pOp^.p2);
        sqlite3VdbeMemSetInt64(@PMem(PtrUInt(pMm) + 2*SizeOf(TMem))^, pOp^.p3);
        sqlite3VdbeMemSetStr(@PMem(PtrUInt(pMm) + 3*SizeOf(TMem))^,
                             zP4, -1, SQLITE_UTF8, SQLITE_DYNAMIC);
        Assert(v^.nResColumn = 4);
      end else begin
        sqlite3VdbeMemSetInt64(@PMem(PtrUInt(pMm) + 0*SizeOf(TMem))^, i);
        sqlite3VdbeMemSetStr(@PMem(PtrUInt(pMm) + 1*SizeOf(TMem))^,
                             sqlite3OpcodeName(pOp^.opcode), -1,
                             SQLITE_UTF8, SQLITE_STATIC);
        sqlite3VdbeMemSetInt64(@PMem(PtrUInt(pMm) + 2*SizeOf(TMem))^, pOp^.p1);
        sqlite3VdbeMemSetInt64(@PMem(PtrUInt(pMm) + 3*SizeOf(TMem))^, pOp^.p2);
        sqlite3VdbeMemSetInt64(@PMem(PtrUInt(pMm) + 4*SizeOf(TMem))^, pOp^.p3);
        { vdbeaux.c:2471 — column 6 is p5 as int64.  Was set to NULL here,
          which made Pascal-side EXPLAIN report p5=0 always (TestExplainParity
          worked around it by walking aOp[] directly on the Pascal side). }
        sqlite3VdbeMemSetInt64(@PMem(PtrUInt(pMm) + 6*SizeOf(TMem))^, pOp^.p5);
        sqlite3VdbeMemSetNull (@PMem(PtrUInt(pMm) + 7*SizeOf(TMem))^);
        sqlite3VdbeMemSetStr(@PMem(PtrUInt(pMm) + 5*SizeOf(TMem))^,
                             zP4, -1, SQLITE_UTF8, SQLITE_DYNAMIC);
        Assert(v^.nResColumn = 8);
      end;
      v^.pResultRow := pMm;
      if db^.mallocFailed <> 0 then begin
        v^.rc := SQLITE_NOMEM;
        rc := SQLITE_ERROR;
      end else begin
        v^.rc := SQLITE_OK;
        rc := SQLITE_ROW;
      end;
    end;
  end;

  Result := rc;
end;

{ Faithful port of vdbeaux.c:2501..2513 (SQLITE_DEBUG only).  Prints the
  SQL that produced this VDBE.  Sources zSql first; if absent, peeks the
  P4 string of the OP_Init opcode at slot 0. }
procedure sqlite3VdbePrintSql(p: PVdbe);
var
  z:   PAnsiChar;
  pOp: PVdbeOp;
begin
  if p = nil then Exit;
  z := nil;
  if p^.zSql <> nil then
    z := p^.zSql
  else if p^.nOp >= 1 then begin
    pOp := @p^.aOp[0];
    if (pOp^.opcode = OP_Init) and (pOp^.p4.z <> nil) then begin
      z := pOp^.p4.z;
      while (z <> nil) and (z^ <> #0) and (Byte(z^) <= Byte(' '))
            and ((z^ = ' ') or (z^ = #9) or (z^ = #10)
                 or (z^ = #11) or (z^ = #12) or (z^ = #13)) do
        Inc(z);
    end;
  end;
  if z <> nil then
    Write('SQL: [', z, ']'#10);
end;

{ vdbeaux.c:2519 — sqlite3VdbeIOTraceSql.  Upstream is SQLITE_ENABLE_IOTRACE-
  gated; this port does not compile that macro, but the sqlite3IoTrace hook
  variable now exists unconditionally, so dispatch faithfully whenever a sink
  has been installed.  When sqlite3IoTrace is nil (the default) this is the
  same no-op as the !ENABLE_IOTRACE branch.  Whitespace is collapsed into
  single spaces exactly as the C loop does. }
procedure sqlite3VdbeIOTraceSql(p: PVdbe);
var
  pOp: PVdbeOp;
  z:   array[0..999] of AnsiChar;
  i, j, nCopy: i32;
begin
  if not Assigned(sqlite3IoTrace) then Exit;
  if (p = nil) or (p^.nOp < 1) then Exit;
  pOp := @p^.aOp[0];
  if (pOp^.opcode = OP_Init) and (pOp^.p4.z <> nil) then begin
    { C: sqlite3_snprintf(sizeof(z), z, "%s", pOp->p4.z) — a bounded copy. }
    nCopy := strlen(pOp^.p4.z);
    if nCopy > SizeOf(z) - 1 then nCopy := SizeOf(z) - 1;
    if nCopy > 0 then Move(pOp^.p4.z^, z[0], nCopy);
    z[nCopy] := #0;
    i := 0;
    while (z[i] <> #0) and (sqlite3Isspace(u8(z[i])) <> 0) do Inc(i);
    j := 0;
    while z[i] <> #0 do begin
      if sqlite3Isspace(u8(z[i])) <> 0 then begin
        if z[i - 1] <> ' ' then begin z[j] := ' '; Inc(j); end;
      end else begin
        z[j] := z[i]; Inc(j);
      end;
      Inc(i);
    end;
    z[j] := #0;
    sqlite3IoTrace(@z[0]);
  end;
end;

{ --- VdbeHalt, VdbeReset, VdbeFinalize --- }

procedure sqlite3VdbeSetChanges(db: Pointer; nChange: i64); forward;
procedure sqlite3SystemError(db: Pointer; rc: i32); forward;

{ vdbeaux.c:3029..3171 — multi-file commit via super-journal.
  Called by vdbeCommit when nTrans>1 and zMain is a real file.  Atomically
  commits write-transactions across every attached database by writing a
  super-journal file naming each per-db journal, fsyncing it, fsyncing each
  db's own commit-phase-one (which embeds the super-journal pathname), then
  deleting the super-journal — the deletion is the commit point.  Phase-two
  cleanup runs under benign-malloc; failure there is non-fatal. }
function vdbeSuperJournalCommit(db: PTsqlite3; zMainFile: PAnsiChar): i32;
const
  SQLITE_IOCAP_SEQUENTIAL = $00000400;
  SQLITE_SYNC_NORMAL      = $00002;
  SQLITE_ACCESS_EXISTS    = 0;
var
  pVfs:        Psqlite3_vfs;
  pSuperJrnl:  Psqlite3_file;
  zBuf:        PAnsiChar;       { raw allocation: 4 leading nulls + main + 16 nulls }
  zSuper:      PAnsiChar;       { = zBuf + 4, the writable super-journal pathname }
  nMainFile:   i32;
  offset:      i64;
  res:         cint;
  retryCount:  i32;
  iRandom:     u32;
  rc:          i32;
  i:           i32;
  pBt:         PBtree;
  zFile:       PAnsiChar;
  nFile:       i32;
begin
  pVfs       := Psqlite3_vfs(db^.pVfs);
  pSuperJrnl := nil;
  offset     := 0;
  retryCount := 0;
  zBuf       := nil;
  zSuper     := nil;

  nMainFile := sqlite3Strlen30(zMainFile);
  { 4 leading + nMainFile + 16 trailing nulls (= room for "-mj%06X9%02X" + NUL). }
  zBuf := PAnsiChar(sqlite3DbMallocZero(db, u64(nMainFile) + 4 + 16));
  if zBuf = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
  zSuper := zBuf + 4;
  Move(zMainFile^, zSuper^, nMainFile);

  repeat
    if retryCount > 0 then begin
      if retryCount > 100 then begin
        { sqlite3_log(SQLITE_FULL, zSuper) — diagnostic only, omit }
        sqlite3OsDelete(pVfs, zSuper, 0);
        Break;
      end else if retryCount = 1 then
        { sqlite3_log(SQLITE_FULL, zSuper) — diagnostic only, omit }
    end;
    Inc(retryCount);
    sqlite3_randomness(SizeOf(iRandom), @iRandom);
    zFile := sqlite3MPrintf(db, '-mj%06x9%02x',
                            [(iRandom shr 8) and $ffffff, iRandom and $ff]);
    if zFile = nil then begin
      sqlite3DbFree(db, zBuf);
      Result := SQLITE_NOMEM_BKPT; Exit;
    end;
    Move(zFile^, zSuper[nMainFile], 13);
    sqlite3DbFree(db, zFile);
    sqlite3FileSuffix3(zMainFile, zSuper);
    rc := sqlite3OsAccess(pVfs, zSuper, SQLITE_ACCESS_EXISTS, @res);
  until not ((rc = SQLITE_OK) and (res <> 0));

  if rc = SQLITE_OK then begin
    pSuperJrnl := Psqlite3_file(sqlite3MallocZero(csize_t(pVfs^.szOsFile)));
    if pSuperJrnl = nil then rc := SQLITE_NOMEM_BKPT
    else
      rc := sqlite3OsOpen(pVfs, zSuper, pSuperJrnl,
              SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or
              SQLITE_OPEN_EXCLUSIVE or SQLITE_OPEN_SUPER_JOURNAL, nil);
    if rc <> SQLITE_OK then begin
      if pSuperJrnl <> nil then sqlite3_free(pSuperJrnl);
      pSuperJrnl := nil;
    end;
  end;
  if rc <> SQLITE_OK then begin
    sqlite3DbFree(db, zBuf);
    Result := rc; Exit;
  end;

  { Write each per-db journal name into the super-journal. }
  for i := 0 to db^.nDb - 1 do begin
    pBt := PBtree(db^.aDb[i].pBt);
    if (pBt <> nil) and (sqlite3BtreeTxnState(pBt) = SQLITE_TXN_WRITE) then begin
      zFile := sqlite3BtreeGetJournalname(pBt);
      if (zFile = nil) or (zFile^ = #0) then Continue;
      nFile := sqlite3Strlen30(zFile) + 1;
      rc := sqlite3OsWrite(pSuperJrnl, zFile, nFile, offset);
      offset := offset + nFile;
      if rc <> SQLITE_OK then begin
        sqlite3OsClose(pSuperJrnl);
        sqlite3_free(pSuperJrnl);
        sqlite3OsDelete(pVfs, zSuper, 0);
        sqlite3DbFree(db, zBuf);
        Result := rc; Exit;
      end;
    end;
  end;

  { Sync the super-journal unless the device says IOCAP_SEQUENTIAL. }
  if (sqlite3OsDeviceCharacteristics(pSuperJrnl) and SQLITE_IOCAP_SEQUENTIAL) = 0 then begin
    rc := sqlite3OsSync(pSuperJrnl, SQLITE_SYNC_NORMAL);
    if rc <> SQLITE_OK then begin
      sqlite3OsClose(pSuperJrnl);
      sqlite3_free(pSuperJrnl);
      sqlite3OsDelete(pVfs, zSuper, 0);
      sqlite3DbFree(db, zBuf);
      Result := rc; Exit;
    end;
  end;

  { Phase-one each db: sync its journal embedding the super-journal name. }
  i := 0;
  while (rc = SQLITE_OK) and (i < db^.nDb) do begin
    pBt := PBtree(db^.aDb[i].pBt);
    if pBt <> nil then
      rc := sqlite3BtreeCommitPhaseOne(pBt, zSuper);
    Inc(i);
  end;
  sqlite3OsClose(pSuperJrnl);
  sqlite3_free(pSuperJrnl);
  if rc <> SQLITE_OK then begin
    sqlite3DbFree(db, zBuf);
    Result := rc; Exit;
  end;

  { Delete the super-journal: this is the atomic commit point. }
  rc := sqlite3OsDelete(pVfs, zSuper, 1);
  sqlite3DbFree(db, zBuf);
  zBuf := nil;
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  { Phase-two: cleanup per-db journals.  Failures here cannot un-commit. }
  for i := 0 to db^.nDb - 1 do begin
    pBt := PBtree(db^.aDb[i].pBt);
    if pBt <> nil then
      sqlite3BtreeCommitPhaseTwo(pBt, 1);
  end;
  sqlite3VtabCommit(db);
  Result := SQLITE_OK;
end;

{ vdbeaux.c:2919 — vdbeCommit.  Single-database simple-case is ported in
  full (covers the entire default test corpus, which does not ATTACH writable
  files).  The multi-file super-journal arm forwards to
  vdbeSuperJournalCommit above. }
function vdbeCommit(db: PTsqlite3; p: PVdbe): i32;
var
  i:           i32;
  nTrans:      i32;
  rc:          i32;
  needXcommit: i32;
  pBt:         PBtree;
  pPg:         PPager;
  txn:         i32;
  jm:          i32;
  aMJNeeded:   array[0..5] of u8;
  zMain:       PAnsiChar;
const
  PAGER_JM_DELETE   = 0; PAGER_JM_PERSIST = 1; PAGER_JM_OFF = 2;
  PAGER_JM_TRUNCATE = 3; PAGER_JM_MEMORY  = 4; PAGER_JM_WAL = 5;
begin
  nTrans := 0;
  needXcommit := 0;
  aMJNeeded[PAGER_JM_DELETE]   := 1;
  aMJNeeded[PAGER_JM_PERSIST]  := 1;
  aMJNeeded[PAGER_JM_OFF]      := 0;
  aMJNeeded[PAGER_JM_TRUNCATE] := 1;
  aMJNeeded[PAGER_JM_MEMORY]   := 0;
  aMJNeeded[PAGER_JM_WAL]      := 0;

  { Sync vtabs first — may add attached databases to the transaction. }
  rc := sqlite3VtabSync(db, p);

  { Count write-transactions and acquire exclusive locks. }
  i := 0;
  while (rc = SQLITE_OK) and (i < db^.nDb) do begin
    pBt := PBtree(db^.aDb[i].pBt);
    if (pBt <> nil) and (sqlite3BtreeTxnState(pBt) = SQLITE_TXN_WRITE) then begin
      needXcommit := 1;
      pPg := sqlite3BtreePager(pBt);
      jm := sqlite3PagerGetJournalMode(pPg);
      if (db^.aDb[i].safety_level <> PAGER_SYNCHRONOUS_OFF)
         and (jm >= 0) and (jm <= 5)
         and (aMJNeeded[jm] <> 0)
         and (sqlite3PagerIsMemdb(pPg) = 0) then
        Inc(nTrans);
      rc := sqlite3PagerExclusiveLock(pPg);
    end;
    Inc(i);
  end;
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  { Invoke commit hook if any write-transaction is active. }
  if (needXcommit <> 0) and Assigned(db^.xCommitCallback) then begin
    if db^.xCommitCallback(db^.pCommitArg) <> 0 then begin
      Result := SQLITE_CONSTRAINT_COMMITHOOK; Exit;
    end;
  end;

  { Simple case: zero or one writable database (or main is :memory:/temp). }
  zMain := nil;
  if (db^.nDb > 0) and (db^.aDb[0].pBt <> nil) then
    zMain := sqlite3BtreeGetFilename(PBtree(db^.aDb[0].pBt));
  if (zMain = nil) or (zMain^ = #0) or (nTrans <= 1) then begin
    if needXcommit <> 0 then begin
      i := 0;
      while (rc = SQLITE_OK) and (i < db^.nDb) do begin
        pBt := PBtree(db^.aDb[i].pBt);
        if (pBt <> nil) and (sqlite3BtreeTxnState(pBt) >= SQLITE_TXN_WRITE) then
          rc := sqlite3BtreeCommitPhaseOne(pBt, nil);
        Inc(i);
      end;
    end;
    i := 0;
    while (rc = SQLITE_OK) and (i < db^.nDb) do begin
      pBt := PBtree(db^.aDb[i].pBt);
      if pBt <> nil then begin
        txn := sqlite3BtreeTxnState(pBt);
        if txn <> SQLITE_TXN_NONE then
          rc := sqlite3BtreeCommitPhaseTwo(pBt, 0);
      end;
      Inc(i);
    end;
    if rc = SQLITE_OK then sqlite3VtabCommit(db);
  end else begin
    { Multi-file commit: open a super-journal so the transaction commits
      atomically across all attached databases.  Faithful port of
      vdbeaux.c:3029..3171. }
    Result := vdbeSuperJournalCommit(db, zMain);
    Exit;
  end;
  Result := rc;
end;

{ vdbeaux.c:3315 — sqlite3VdbeHalt.  Determines whether this VM's work is
  committed or rolled back, runs the commit hook, and unwinds statement-
  transactions on per-statement errors.  Faithful 1:1 port; only the
  nVdbe{Active,Read,Write} decrements at the tail are skipped here because
  the equivalent counters are decremented one-shot by sqlite3_step (Pas
  divergence retained from the prior stub — moving the decrements would
  require touching every caller site at once). }
function sqlite3VdbeHalt(v: PVdbe): i32;
var
  i:               i32;
  pC:              PVdbeCursor;
  db:              PTsqlite3;
  rc, mrc:         i32;
  eStatementOp:    i32;
  isSpecialError:  i32;
begin
  if v = nil then begin Result := SQLITE_OK; Exit; end;
  db := v^.db;
  if db = nil then begin v^.eVdbeState := VDBE_HALT_STATE; Result := SQLITE_OK; Exit; end;

  if db^.mallocFailed <> 0 then v^.rc := SQLITE_NOMEM;

  { closeAllCursors — free every per-cursor blob, including CURTYPE_VTAB. }
  if v^.apCsr <> nil then begin
    for i := 0 to v^.nCursor - 1 do begin
      pC := v^.apCsr[i];
      if pC <> nil then begin
        sqlite3VdbeFreeCursorNN(v, pC);
        v^.apCsr[i] := nil;
      end;
    end;
  end;

  if (v^.vdbeFlags and VDBF_IsReader) <> 0 then begin
    eStatementOp   := 0;
    sqlite3VdbeEnter(v);

    { Detect special errors that may have left the cache inconsistent. }
    if v^.rc <> SQLITE_OK then begin
      mrc := v^.rc and $ff;
      if (mrc = SQLITE_NOMEM) or (mrc = SQLITE_IOERR)
         or (mrc = SQLITE_INTERRUPT) or (mrc = SQLITE_FULL) then
        isSpecialError := 1
      else
        isSpecialError := 0;
    end else begin
      mrc            := 0;
      isSpecialError := 0;
    end;
    if isSpecialError <> 0 then begin
      if ((v^.vdbeFlags and VDBF_ReadOnly) = 0) or (mrc <> SQLITE_INTERRUPT) then
      begin
        if ((mrc = SQLITE_NOMEM) or (mrc = SQLITE_FULL))
           and ((v^.vdbeFlags and VDBF_UsesStmtJournal) <> 0) then begin
          eStatementOp := SAVEPOINT_ROLLBACK;
        end else begin
          sqlite3RollbackAll(db, SQLITE_ABORT_ROLLBACK);
          sqlite3CloseSavepoints(db);
          db^.autoCommit := 1;
          v^.nChange := 0;
        end;
      end;
    end;

    { Immediate FK violation check. }
    if (v^.rc = SQLITE_OK) or
       ((v^.errorAction = OE_Fail) and (isSpecialError = 0)) then
      sqlite3VdbeCheckFkImmediate(v);

    { Auto-commit arm: if this is the only writer VM and autoCommit is on,
      do the commit (or rollback on error). }
    if (sqlite3VtabInSync(db) = 0)
       and (db^.autoCommit <> 0)
       and (((v^.vdbeFlags and VDBF_ReadOnly) = 0) and (db^.nVdbeWrite = 1)
            or ((v^.vdbeFlags and VDBF_ReadOnly) <> 0) and (db^.nVdbeWrite = 0)) then
    begin
      if (v^.rc = SQLITE_OK)
         or ((v^.errorAction = OE_Fail) and (isSpecialError = 0)) then begin
        rc := sqlite3VdbeCheckFkDeferred(v);
        if rc <> SQLITE_OK then begin
          if (v^.vdbeFlags and VDBF_ReadOnly) <> 0 then begin
            sqlite3VdbeLeave(v);
            Result := SQLITE_ERROR; Exit;
          end;
          rc := SQLITE_CONSTRAINT_FOREIGNKEY;
        end else if (db^.flags and SQLITE_CorruptRdOnly) <> 0 then begin
          rc := SQLITE_CORRUPT;
          db^.flags := db^.flags and not SQLITE_CorruptRdOnly;
        end else begin
          rc := vdbeCommit(db, v);
        end;
        if (rc = SQLITE_BUSY) and ((v^.vdbeFlags and VDBF_ReadOnly) <> 0) then
        begin
          sqlite3VdbeLeave(v);
          Result := SQLITE_BUSY; Exit;
        end else if rc <> SQLITE_OK then begin
          sqlite3SystemError(db, rc);
          v^.rc := rc;
          sqlite3RollbackAll(db, SQLITE_OK);
          v^.nChange := 0;
        end else begin
          db^.nDeferredCons    := 0;
          db^.nDeferredImmCons := 0;
          db^.flags            := db^.flags and not SQLITE_DeferFKs;
          { sqlite3CommitInternalChanges — inlined: clear schema-change. }
          db^.mDbFlags := db^.mDbFlags and not u32(DBFLAG_SchemaChange);
        end;
      end else if (v^.rc = SQLITE_SCHEMA) and (db^.nVdbeActive > 1) then begin
        v^.nChange := 0;
      end else begin
        sqlite3RollbackAll(db, SQLITE_OK);
        v^.nChange := 0;
      end;
      db^.nStatement := 0;
    end else if eStatementOp = 0 then begin
      if (v^.rc = SQLITE_OK) or (v^.errorAction = OE_Fail) then
        eStatementOp := SAVEPOINT_RELEASE
      else if v^.errorAction = OE_Abort then
        eStatementOp := SAVEPOINT_ROLLBACK
      else begin
        sqlite3RollbackAll(db, SQLITE_ABORT_ROLLBACK);
        sqlite3CloseSavepoints(db);
        db^.autoCommit := 1;
        v^.nChange := 0;
      end;
    end;

    { Statement-transaction commit/rollback. }
    if eStatementOp <> 0 then begin
      rc := sqlite3VdbeCloseStatement(v, eStatementOp);
      if rc <> 0 then begin
        if (v^.rc = SQLITE_OK) or ((v^.rc and $ff) = SQLITE_CONSTRAINT) then
        begin
          v^.rc := rc;
          sqlite3DbFree(db, v^.zErrMsg);
          v^.zErrMsg := nil;
        end;
        sqlite3RollbackAll(db, SQLITE_ABORT_ROLLBACK);
        sqlite3CloseSavepoints(db);
        db^.autoCommit := 1;
        v^.nChange := 0;
      end;
    end;

    { Update connection change counter. }
    if (v^.vdbeFlags and VDBF_ChangeCntOn) <> 0 then begin
      if eStatementOp <> SAVEPOINT_ROLLBACK then
        sqlite3VdbeSetChanges(db, v^.nChange)
      else
        sqlite3VdbeSetChanges(db, 0);
      v^.nChange := 0;
    end;

    sqlite3VdbeLeave(v);
  end;

  { vdbeaux.c:3496..3500 — decrement the connection's nVdbeWrite/nVdbeRead
    counters that were bumped by sqlite3_step at READY→RUN.  nVdbeActive's
    Dec stays in sqlite3_step (Pascal-port deviation: many tests construct
    a Vdbe directly and set eVdbeState:=RUN without going through step,
    so the Inc never fired and an unconditional Dec here would underflow).
    Guard the others with a `>0` check for the same reason. }
  if v^.eVdbeState = VDBE_RUN_STATE then begin
    if ((v^.vdbeFlags and VDBF_ReadOnly) = 0) and (db^.nVdbeWrite > 0) then
      Dec(db^.nVdbeWrite);
    if ((v^.vdbeFlags and VDBF_IsReader) <> 0) and (db^.nVdbeRead > 0) then
      Dec(db^.nVdbeRead);
  end;

  v^.eVdbeState := VDBE_HALT_STATE;

  if db^.mallocFailed <> 0 then v^.rc := SQLITE_NOMEM;

  if v^.rc = SQLITE_BUSY then Result := SQLITE_BUSY else Result := SQLITE_OK;
end;

procedure sqlite3VdbeResetStepResult(p: PVdbe);
begin
  p^.rc := SQLITE_OK;
end;

{ Port of vdbeaux.c:3536 sqlite3VdbeTransferError.  Copies p^.zErrMsg
  (set by sqlite3VdbeError) into db^.pErr so sqlite3_errmsg returns the
  real cause; clears db^.pErr if no VDBE-side message. }
function sqlite3VdbeTransferError(p: PVdbe): i32;
var
  db: PTsqlite3;
  rc: i32;
begin
  db := p^.db;
  rc := p^.rc;
  if p^.zErrMsg <> nil then begin
    Inc(db^.bBenignMalloc);
    if db^.pErr = nil then
      db^.pErr := sqlite3ValueNew(Psqlite3(db));
    if db^.pErr <> nil then
      sqlite3ValueSetStr(Psqlite3_value(db^.pErr), -1, p^.zErrMsg,
                         SQLITE_UTF8, SQLITE_TRANSIENT);
    Dec(db^.bBenignMalloc);
  end else if db^.pErr <> nil then begin
    sqlite3ValueSetNull(Psqlite3_value(db^.pErr));
  end;
  db^.errCode := rc;
  db^.errByteOffset := -1;
  Result := rc;
end;

function sqlite3VdbeReset(p: PVdbe): i32;
var
  db: PTsqlite3;
  wasRun: Boolean;
begin
  if p = nil then begin Result := SQLITE_OK; Exit; end;
  db := p^.db;
  wasRun := (p^.eVdbeState = VDBE_RUN_STATE);
  if wasRun then
    sqlite3VdbeHalt(p);
  { Reset/Finalize on a stmt paused at SQLITE_ROW must release the
    nVdbeActive counter that step bumped on READY→RUN — otherwise
    subsequent VACUUM/DDL falsely reports "SQL statements in progress".
    Guarded with `>0` to match the nVdbeWrite/nVdbeRead pattern in
    sqlite3VdbeHalt (some tests build a Vdbe directly without ever
    routing through sqlite3_step, so the Inc never fired). }
  if wasRun and (db <> nil) and (db^.nVdbeActive > 0) then
    Dec(db^.nVdbeActive);
  { vdbeaux.c:3605 — if the VDBE has executed any instruction, transfer
    the error code/message from the VDBE into the connection.  Otherwise
    leave db^.errCode unchanged.  Without this arm, a clean SQLITE_DONE
    leaks rc=SQLITE_DONE into db^.errCode, and a subsequent sqlite3_errmsg
    falls through to sqlite3ErrStr(SQLITE_DONE)="no more rows available"
    instead of "not an error". }
  if (db <> nil) and (p^.pc >= 0) then begin
    if (db^.pErr <> nil) or (p^.zErrMsg <> nil) then
      sqlite3VdbeTransferError(p)
    else
      db^.errCode := p^.rc;
  end;
  { vdbeaux.c:3628 — clear the current-result-row pointer so that
    sqlite3_data_count()/sqlite3_column_*() report no live row after a
    reset (capi2-1.9/1.10). }
  p^.pResultRow := nil;
  { vdbeaux.c:3586..3671 — sqlite3VdbeReset NEVER writes eVdbeState; the only
    state transition it can cause is the RUN->HALT one performed by
    sqlite3VdbeHalt above.  An unconditional ':= VDBE_READY_STATE' here flipped
    a failed-prepare (never-MakeReady) Vdbe from INIT to READY, defeating the
    INIT-gate in sqlite3VdbeClearObject and crashing on garbage aMem. }
  if db <> nil then
    Result := p^.rc and db^.errMask
  else
    Result := p^.rc;
end;

function sqlite3VdbeFinalize(p: PVdbe): i32;
var
  rc: i32;
begin
  if p = nil then begin Result := SQLITE_OK; Exit; end;
  rc := SQLITE_OK;
  { vdbeaux.c:3682 — only reset a Vdbe that actually reached READY (or beyond).
    A failed-prepare Vdbe is still in VDBE_INIT_STATE and must not be reset. }
  if p^.eVdbeState >= VDBE_READY_STATE then
    rc := sqlite3VdbeReset(p);
  sqlite3VdbeDelete(p);
  Result := rc;
end;

{ --- AuxData cleanup --- }

procedure sqlite3VdbeDeleteAuxData(db: Psqlite3; pp: PPAuxData; iOp, mask: i32);
var
  pAux: PAuxData;
begin
  pAux := pp^;
  while pAux <> nil do begin
    pp^   := pAux^.pNextAux;
    if pAux^.xDeleteAux <> nil then
      pAux^.xDeleteAux(pAux^.pAux);
    sqlite3DbFree(db, pAux);
    pAux := pp^;
  end;
end;

{ --- vdbeapi.c — sqlite3_context_db_handle / sqlite3_get_auxdata /
      sqlite3_set_auxdata (Phase 6.8.g) --- }

function sqlite3_context_db_handle(p: Psqlite3_context): Psqlite3;
begin
  if p = nil then begin Result := nil; Exit; end;
  Result := p^.pOut^.db;
end;

{ sqlite3_vtab_nochange — vdbeapi.c:1008.  True when the column being
  written by the current vtab xUpdate is unchanged from before the
  update.  Forwards to sqlite3_value_nochange on pCtx^.pOut. }
function sqlite3_vtab_nochange(p: Psqlite3_context): i32;
begin
  if p = nil then begin Result := 0; Exit; end;
  Result := sqlite3_value_nochange(p^.pOut);
end;

{ valueFromValueList — vdbeapi.c:1032.  Implementation of
  sqlite3_vtab_in_first() (bNext=0) and sqlite3_vtab_in_next() (bNext=1).
  Reads the next row of the ephemeral b-tree backing the IN-list value
  and decodes the single-column record into pRhs^.pOut. }
function valueFromValueList(pVal: PMem; ppOut: PPMem; bNext: i32): i32;
var
  pRhs:     PValueList;
  rc:       i32;
  dummy:    i32;
  sz:       u32;
  sMem:     TMem;
  zBuf:     Pu8;
  iSerial:  u32;
  iOff:     i32;
  consumed: u8;
  pOut:     PMem;
begin
  ppOut^ := nil;
  if pVal = nil then begin Result := SQLITE_MISUSE; Exit; end;
  if ((pVal^.flags and MEM_Dyn) = 0)
     or (Pointer(pVal^.xDel) <> Pointer(@sqlite3VdbeValueListFree)) then
  begin
    Result := SQLITE_ERROR; Exit;
  end;
  pRhs := PValueList(pVal^.z);
  if bNext <> 0 then
    rc := sqlite3BtreeNext(pRhs^.pCsr, 0)
  else begin
    dummy := 0;
    rc := sqlite3BtreeFirst(pRhs^.pCsr, @dummy);
    if sqlite3BtreeEof(pRhs^.pCsr) <> 0 then rc := SQLITE_DONE;
  end;
  if rc = SQLITE_OK then begin
    FillChar(sMem, SizeOf(sMem), 0);
    sz := sqlite3BtreePayloadSize(pRhs^.pCsr);
    rc := sqlite3VdbeMemFromBtreeZeroOffset(pRhs^.pCsr, sz, @sMem);
    if rc = SQLITE_OK then begin
      zBuf := Pu8(sMem.z);
      iSerial := 0;
      { getVarint32(&zBuf[1], iSerial) }
      if (Pu8(zBuf + 1)^ and $80) = 0 then begin
        iSerial  := u32(Pu8(zBuf + 1)^);
        consumed := 1;
      end else
        consumed := sqlite3GetVarint32(Pu8(zBuf + 1), iSerial);
      iOff := 1 + i32(consumed);
      pOut := pRhs^.pOut;
      sqlite3VdbeSerialGet(Pu8(zBuf + iOff), iSerial, pOut);
      pOut^.enc := PTsqlite3(pOut^.db)^.enc;
      if ((pOut^.flags and MEM_Ephem) <> 0)
         and (sqlite3VdbeMemMakeWriteable(pOut) <> 0) then
        rc := SQLITE_NOMEM
      else
        ppOut^ := pOut;
    end;
    sqlite3VdbeMemRelease(@sMem);
  end;
  Result := rc;
end;

function sqlite3_vtab_in_first(pVal: PMem; ppOut: PPMem): i32;
begin
  Result := valueFromValueList(pVal, ppOut, 0);
end;

function sqlite3_vtab_in_next(pVal: PMem; ppOut: PPMem): i32;
begin
  Result := valueFromValueList(pVal, ppOut, 1);
end;

function sqlite3_get_auxdata(pCtx: Psqlite3_context; iArg: i32): Pointer;
var
  pAux: PAuxData;
begin
  if (pCtx = nil) or (pCtx^.pVdbe = nil) then
  begin
    Result := nil;
    Exit;
  end;
  pAux := pCtx^.pVdbe^.pAuxData;
  while pAux <> nil do
  begin
    if (pAux^.iAuxArg = iArg)
       and ((pAux^.iAuxOp = pCtx^.iOp) or (iArg < 0)) then
    begin
      Result := pAux^.pAux;
      Exit;
    end;
    pAux := pAux^.pNextAux;
  end;
  Result := nil;
end;

procedure sqlite3_set_auxdata(pCtx: Psqlite3_context; iArg: i32;
                              pAux: Pointer; xDelete: TxDelProc);
var
  pAd:   PAuxData;
  pVm:   PVdbe;
begin
  if pCtx = nil then Exit;
  pVm := pCtx^.pVdbe;
  if pVm = nil then
  begin
    if Assigned(xDelete) then xDelete(pAux);
    Exit;
  end;
  pAd := pVm^.pAuxData;
  while pAd <> nil do
  begin
    if (pAd^.iAuxArg = iArg)
       and ((pAd^.iAuxOp = pCtx^.iOp) or (iArg < 0)) then
      Break;
    pAd := pAd^.pNextAux;
  end;
  if pAd = nil then
  begin
    pAd := PAuxData(sqlite3DbMallocZero(pVm^.db, SizeOf(TAuxData)));
    if pAd = nil then
    begin
      { failed: — vdbeapi.c sqlite3_set_auxdata }
      if Assigned(xDelete) then xDelete(pAux);
      Exit;
    end;
    pAd^.iAuxOp   := pCtx^.iOp;
    pAd^.iAuxArg  := iArg;
    pAd^.pNextAux := pVm^.pAuxData;
    pVm^.pAuxData := pAd;
    if pCtx^.isError = 0 then pCtx^.isError := -1;
  end
  else if Assigned(pAd^.xDeleteAux) then
    pAd^.xDeleteAux(pAd^.pAux);
  pAd^.pAux       := pAux;
  pAd^.xDeleteAux := xDelete;
end;

{ --- vdbeapi.c — sqlite3_user_data, result_subtype, result_text64
      (Phase 6.8.h.1) --- }

{ vdbeapi.c:837 — return the pUserData slot of the function definition. }
function sqlite3_user_data(pCtx: Psqlite3_context): Pointer;
begin
  if (pCtx = nil) or (pCtx^.pFunc = nil) then begin Result := nil; Exit; end;
  Result := PTFuncDef(pCtx^.pFunc)^.pUserData;
end;

{ vdbeapi.c:1014 — set the result subtype byte on pCtx^.pOut. }
procedure sqlite3_result_subtype(pCtx: Psqlite3_context; eSubtype: u32);
var
  pOut: PMem;
begin
  if pCtx = nil then Exit;
  pOut := pCtx^.pOut;
  pOut^.eSubtype := u8(eSubtype and $FF);
  pOut^.flags := pOut^.flags or MEM_Subtype;
end;

{ vdbeapi.c:889 — wide-length text result.  Behaviour matches
  sqlite3_result_text but accepts a u64 length so JSON outputs > 2GB
  are at least representable.  enc selects UTF-8/16. }
procedure sqlite3_result_text64(pCtx: Psqlite3_context; z: PAnsiChar;
                                n: u64; xDel: TxDelProc; enc: u8);
begin
  if pCtx = nil then Exit;
  if n > $7FFFFFFF then
  begin
    sqlite3_result_error_toobig(pCtx);
    Exit;
  end;
  setResultStrOrError(pCtx, z, i32(n), enc, xDel);
end;

{ --- sqlite3VdbeCreate / sqlite3VdbeDelete --- }

function sqlite3VdbeCreate(pParse: PParse): PVdbe;
var
  db: Psqlite3db;
  p:  PVdbe;
  pPrevVdbe: PPVdbe;
begin
  db := vdbeParseDbPtr(pParse);
  p  := PVdbe(sqlite3DbMallocRawNN(db, SizeOf(TVdbe)));
  if p = nil then begin Result := nil; Exit; end;
  { Zero everything from aOp onwards (offsetof(Vdbe,aOp) = 136) }
  FillChar(PByte(p)[136], SizeOf(TVdbe) - 136, 0);
  { vdbeaux.c:25 leaves p->pc uninitialized (it sits before aOp, outside the
    memset) and relies on it being negative until sqlite3VdbeRewind sets it
    to -1 at exec time.  sqlite3VdbeReset (vdbeaux.c:3605) uses `p->pc>=0` to
    decide whether to transfer the VM's (clean) error code into db^.errCode.
    sqlite3DbMallocRawNN here can hand back zeroed memory, so an unexecuted
    parse-only Vdbe (e.g. the one sqlite3_declare_vtab builds for a rejected
    CREATE TABLE ... AS SELECT) would have pc=0, wrongly clobber db^.errCode
    back to SQLITE_OK, and sqlite3_errmsg would report "not an error"
    (vtabL-1.9/1.10).  Initialise pc<0 explicitly to honour the C invariant. }
  p^.pc := -1;
  p^.db := db;
  { Insert into db->pVdbe linked list (db->pVdbe at offset 8) }
  pPrevVdbe := PPVdbe(PByte(db) + 8);
  if pPrevVdbe^ <> nil then
    pPrevVdbe^^.ppVPrev := @p^.pVNext;
  p^.pVNext := pPrevVdbe^;
  p^.ppVPrev := pPrevVdbe;
  pPrevVdbe^ := p;
  p^.eVdbeState := VDBE_INIT_STATE;
  p^.pParse := pParse;
  { pParse->pVdbe at offset 16 }
  PPVdbe(PByte(pParse) + 16)^ := p;
  sqlite3VdbeAddOp2(p, OP_Init, 0, 1);
  Result := p;
end;

procedure sqlite3VdbeClearObject(db: Psqlite3db; p: PVdbe);
var
  pSub:    PSubProgram;
  pNext:   PSubProgram;
  i:       i32;
  aliased: i32;
  pThisDS: PDblquoteStr;
  pNxtDS:  PDblquoteStr;
begin
  { Free sub-programs.  Track whether any sub-program's aOp aliases the
    parent's aOp (a known-bug scenario in the trigger codegen path —
    DiagTrig 6.8.6 KNOWN BUG); if so, skip the parent free below to avoid
    a double-free of the same allocation. }
  aliased := 0;
  pSub := p^.pProgram;
  while pSub <> nil do begin
    pNext := pSub^.pNext;
    if (pSub^.aOp <> nil) and (pSub^.aOp = p^.aOp) then aliased := 1;
    vdbeFreeOpArray(db, pSub^.aOp, pSub^.nOp);
    sqlite3DbFree(db, pSub^.aOnce);
    sqlite3DbFree(db, pSub);
    pSub := pNext;
  end;
  { Free op array (skip if aliased to a sub-program already freed). }
  if aliased = 0 then
    vdbeFreeOpArray(db, p^.aOp, p^.nOp)
  else
    p^.aOp := nil;
  { Free col names }
  if p^.aColName <> nil then begin
    vdbeReleaseColNames(p^.aColName, i32(p^.nResAlloc) * COLNAME_N);
    sqlite3DbFree(db, p^.aColName);
  end;
  { Gate aMem / aVar / pVList / pFree release on eVdbeState != INIT.
    Trigger sub-vdbes (codeRowTrigger) are created via VdbeCreate, never
    transit VdbeMakeReady, and are deleted while still in VDBE_INIT_STATE.
    Their nVar/aVar/aMem/pVList/pFree fields are raw-malloc garbage in
    that case (VdbeCreate only zeroes from aOp onwards — see vdbeaux.c:30
    and the comment in TVdbe at the "Zero-initialised boundary" line).
    C mirrors this gate at vdbeaux.c:3747..3751 (9.2.divbug.J). }
  if p^.eVdbeState <> VDBE_INIT_STATE then begin
    { Free aMem registers }
    if p^.aMem <> nil then begin
      for i := 0 to p^.nMem - 1 do begin
        if (p^.aMem[i].flags and (MEM_Dyn or MEM_Agg)) <> 0 then
          sqlite3VdbeMemRelease(@p^.aMem[i]);
      end;
    end;
    if p^.pVList <> nil then begin
      sqlite3DbNNFreeNN(db, p^.pVList);
      p^.pVList := nil;
    end;
    { Release any bound parameter Mem cells.  Mirrors vdbeaux.c:3748 —
      releaseMemArray(p->aVar, p->nVar).  Required so bind-pointer /
      bind-text/blob destructors fire on finalize. }
    if (p^.aVar <> nil) and (p^.nVar > 0) then begin
      for i := 0 to p^.nVar - 1 do
        sqlite3VdbeMemRelease(p^.aVar + i);
    end;
    if p^.pFree <> nil then
      sqlite3DbFree(db, p^.pFree);
  end;
  sqlite3DbFree(db, p^.zErrMsg);
  sqlite3DbFree(db, p^.zSql);
  sqlite3DbFree(db, p^.zNormSql);   { vdbeaux.c:3755 }
  { vdbeaux.c:3756..3762 — free the pDblStr list. }
  begin
    pThisDS := p^.pDblStr;
    while pThisDS <> nil do
    begin
      pNxtDS := pThisDS^.pNextStr;
      sqlite3DbFree(db, pThisDS);
      pThisDS := pNxtDS;
    end;
    p^.pDblStr := nil;
  end;
  sqlite3VdbeDeleteAuxData(db, @p^.pAuxData, -1, 0);
  { Phase 8.2.1 — free scanstatus aScan[] array and its duped zName strings
    (vdbeaux.c:3765..3771). }
  if p^.aScan <> nil then begin
    for i := 0 to p^.nScan - 1 do
      sqlite3DbFree(db, p^.aScan[i].zName);
    sqlite3DbFree(db, p^.aScan);
    p^.aScan := nil;
    p^.nScan := 0;
  end;
end;

procedure sqlite3VdbeDelete(p: PVdbe);
var
  db: Psqlite3db;
begin
  if p = nil then Exit;
  db := p^.db;
  sqlite3VdbeClearObject(db, p);
  { vdbeaux.c:1156 — skip unlink under the pnBytesFreed dry-run so the
    sqlite3_stmt_status(.., MEMUSED, 0) accounting pass does not
    actually destroy the live vdbe. }
  if (db = nil) or (PTsqlite3(db)^.pnBytesFreed = nil) then
  begin
    if p^.ppVPrev <> nil then
      p^.ppVPrev^ := p^.pVNext;
    if p^.pVNext <> nil then
      p^.pVNext^.ppVPrev := p^.ppVPrev;
  end;
  sqlite3DbFree(db, p);
end;

{ --- Cursor move helpers --- }

function sqlite3VdbeFinishMoveto(p: PVdbeCursor): i32;
{ Port of vdbeaux.c:3801 }
var
  resMoveto: i32;
  rc: i32;
begin
  rc := sqlite3BtreeTableMoveto(p^.uc.pCursor, u64(p^.movetoTarget), 0, @resMoveto);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  if resMoveto <> 0 then begin Result := SQLITE_CORRUPT_BKPT; Exit; end;
  { 9.4.divbug.73 — vdbeaux.c:3812..3814 SQLITE_TEST counter (lazy seek lands) }
  Inc(sqlite3_search_count);
  p^.deferredMoveto := 0;
  p^.cacheStatus := CACHE_STALE;
  Result := SQLITE_OK;
end;

function sqlite3VdbeHandleMovedCursor(p: PVdbeCursor): i32;
{ Port of vdbeaux.c:3827 }
var
  isDifferentRow: i32;
  rc: i32;
begin
  rc := sqlite3BtreeCursorRestore(p^.uc.pCursor, @isDifferentRow);
  p^.cacheStatus := CACHE_STALE;
  if isDifferentRow <> 0 then p^.nullRow := 1;
  Result := rc;
end;

function sqlite3VdbeCursorRestore(p: PVdbeCursor): i32;
{ Port of vdbeaux.c:3842 }
begin
  if sqlite3BtreeCursorHasMoved(p^.uc.pCursor) <> 0 then
    Result := sqlite3VdbeHandleMovedCursor(p)
  else
    Result := SQLITE_OK;
end;

{ --- Misc lifecycle functions --- }

function sqlite3VdbeParser(p: PVdbe): PParse;
begin
  Result := p^.pParse;
end;

procedure sqlite3VdbeError(p: PVdbe; zFormat: PAnsiChar);
{ Port of vdbeaux.c:59.  C uses sqlite3VMPrintf to format zFormat with a
  va_list and stores the result in p->zErrMsg.  Every Pas caller passes
  an already-formatted plain string (no %-substitution required at this
  layer — see callers in passqlite3vdbe.pas), so we duplicate the string
  directly into db-tracked memory after freeing any prior message. }
begin
  if p = nil then Exit;
  sqlite3DbFree(p^.db, p^.zErrMsg);
  if zFormat = nil then
    p^.zErrMsg := nil
  else
    p^.zErrMsg := PAnsiChar(sqlite3DbStrDup(p^.db, PChar(zFormat)));
end;

procedure sqlite3VdbeSetSql(p: PVdbe; z: PAnsiChar; n: i32; prepFlags: u8);
begin
  if p = nil then Exit;
  p^.prepFlags := prepFlags;
  if (prepFlags and SQLITE_PREPARE_SAVESQL) = 0 then
    p^.expmask := 0;
  if z <> nil then
    p^.zSql := PAnsiChar(sqlite3DbStrNDup(p^.db, PChar(z), u64(n)));
end;

procedure sqlite3VdbeSwap(pA, pB: PVdbe);
var
  tmp:  TVdbe;
  pTmp: PVdbe;
  ppTmp: PPVdbe;
  zTmp: PAnsiChar;
begin
  tmp := pA^;
  pA^ := pB^;
  pB^ := tmp;
  pTmp        := pA^.pVNext;
  pA^.pVNext  := pB^.pVNext;
  pB^.pVNext  := pTmp;
  ppTmp       := pA^.ppVPrev;
  pA^.ppVPrev := pB^.ppVPrev;
  pB^.ppVPrev := ppTmp;
  zTmp        := pA^.zSql;
  pA^.zSql    := pB^.zSql;
  pB^.zSql    := zTmp;
  zTmp          := pA^.zNormSql;   { vdbeaux.c:144..146 }
  pA^.zNormSql  := pB^.zNormSql;
  pB^.zNormSql  := zTmp;
  pB^.expmask  := pA^.expmask;
  pB^.prepFlags := pA^.prepFlags;
  Move(pA^.aCounter, pB^.aCounter, SizeOf(pB^.aCounter));
  pB^.aCounter[SQLITE_STMTSTATUS_REPREPARE] :=
    pB^.aCounter[SQLITE_STMTSTATUS_REPREPARE] + 1;
end;

{ ============================================================================
  Phase 5.5 — vdbeapi.c public API port
  ============================================================================ }

{ --- sqlite3_value_type aType lookup (vdbeapi.c:245) --- }
const
  aValueType: array[0..63] of u8 = (
    SQLITE_BLOB,    { 0x00 }  SQLITE_NULL,    { 0x01 NULL }
    SQLITE_TEXT,    { 0x02 }  SQLITE_NULL,    { 0x03 }
    SQLITE_INTEGER, { 0x04 }  SQLITE_NULL,    { 0x05 }
    SQLITE_INTEGER, { 0x06 }  SQLITE_NULL,    { 0x07 }
    SQLITE_FLOAT,   { 0x08 }  SQLITE_NULL,    { 0x09 }
    SQLITE_FLOAT,   { 0x0a }  SQLITE_NULL,    { 0x0b }
    SQLITE_INTEGER, { 0x0c }  SQLITE_NULL,    { 0x0d }
    SQLITE_INTEGER, { 0x0e }  SQLITE_NULL,    { 0x0f }
    SQLITE_BLOB,    { 0x10 }  SQLITE_NULL,    { 0x11 }
    SQLITE_TEXT,    { 0x12 }  SQLITE_NULL,    { 0x13 }
    SQLITE_INTEGER, { 0x14 }  SQLITE_NULL,    { 0x15 }
    SQLITE_INTEGER, { 0x16 }  SQLITE_NULL,    { 0x17 }
    SQLITE_FLOAT,   { 0x18 }  SQLITE_NULL,    { 0x19 }
    SQLITE_FLOAT,   { 0x1a }  SQLITE_NULL,    { 0x1b }
    SQLITE_INTEGER, { 0x1c }  SQLITE_NULL,    { 0x1d }
    SQLITE_INTEGER, { 0x1e }  SQLITE_NULL,    { 0x1f }
    SQLITE_FLOAT,   { 0x20 }  SQLITE_NULL,    { 0x21 }
    SQLITE_FLOAT,   { 0x22 }  SQLITE_NULL,    { 0x23 }
    SQLITE_FLOAT,   { 0x24 }  SQLITE_NULL,    { 0x25 }
    SQLITE_FLOAT,   { 0x26 }  SQLITE_NULL,    { 0x27 }
    SQLITE_FLOAT,   { 0x28 }  SQLITE_NULL,    { 0x29 }
    SQLITE_FLOAT,   { 0x2a }  SQLITE_NULL,    { 0x2b }
    SQLITE_FLOAT,   { 0x2c }  SQLITE_NULL,    { 0x2d }
    SQLITE_FLOAT,   { 0x2e }  SQLITE_NULL,    { 0x2f }
    SQLITE_BLOB,    { 0x30 }  SQLITE_NULL,    { 0x31 }
    SQLITE_TEXT,    { 0x32 }  SQLITE_NULL,    { 0x33 }
    SQLITE_FLOAT,   { 0x34 }  SQLITE_NULL,    { 0x35 }
    SQLITE_FLOAT,   { 0x36 }  SQLITE_NULL,    { 0x37 }
    SQLITE_FLOAT,   { 0x38 }  SQLITE_NULL,    { 0x39 }
    SQLITE_FLOAT,   { 0x3a }  SQLITE_NULL,    { 0x3b }
    SQLITE_FLOAT,   { 0x3c }  SQLITE_NULL,    { 0x3d }
    SQLITE_FLOAT,   { 0x3e }  SQLITE_NULL     { 0x3f }
  );

{ --- sqlite3_value_* accessors (vdbeapi.c:182) --- }

function sqlite3_value_type(pVal: Psqlite3_value): i32;
begin
  if pVal = nil then begin Result := SQLITE_NULL; Exit; end;
  Result := aValueType[pVal^.flags and MEM_AffMask];
end;

function sqlite3_value_int(pVal: Psqlite3_value): i32;
begin
  Result := i32(sqlite3VdbeIntValue(pVal));
end;

function sqlite3_value_int64(pVal: Psqlite3_value): i64;
begin
  Result := sqlite3VdbeIntValue(pVal);
end;

function sqlite3_value_double(pVal: Psqlite3_value): Double;
begin
  Result := sqlite3VdbeRealValue(pVal);
end;

function sqlite3_value_text(pVal: Psqlite3_value): PAnsiChar;
begin
  Result := PAnsiChar(sqlite3ValueText(pVal, SQLITE_UTF8));
end;

{ vdbeapi.c:231..239 — sqlite3_value_text16 / _text16be / _text16le.
  Trivial wrappers around sqlite3ValueText with the requested encoding. }
function sqlite3_value_text16(pVal: Psqlite3_value): Pointer;
begin
  Result := sqlite3ValueText(pVal, SQLITE_UTF16NATIVE);
end;

function sqlite3_value_text16be(pVal: Psqlite3_value): Pointer;
begin
  Result := sqlite3ValueText(pVal, SQLITE_UTF16BE);
end;

function sqlite3_value_text16le(pVal: Psqlite3_value): Pointer;
begin
  Result := sqlite3ValueText(pVal, SQLITE_UTF16LE);
end;

function sqlite3_value_blob(pVal: Psqlite3_value): Pointer;
begin
  if pVal = nil then begin Result := nil; Exit; end;
  if (pVal^.flags and (MEM_Blob or MEM_Str)) <> 0 then begin
    if (pVal^.flags and MEM_Zero) <> 0 then begin
      if sqlite3VdbeMemExpandBlob(pVal) <> SQLITE_OK then begin
        Result := nil; Exit;
      end;
    end;
    pVal^.flags := pVal^.flags or MEM_Blob;
    if pVal^.n <> 0 then Result := pVal^.z
    else Result := nil;
  end else
    Result := sqlite3_value_text(pVal);
end;

function sqlite3_value_bytes(pVal: Psqlite3_value): i32;
begin
  Result := sqlite3ValueBytes(pVal, SQLITE_UTF8);
end;

{ vdbeapi.c:198 — sqlite3_value_bytes16.  Reports the byte count of the
  value's UTF-16 (native byte order) representation, performing the
  encoding conversion lazily inside sqlite3ValueBytes / valueToText
  when the source Mem is UTF-8 text. }
function sqlite3_value_bytes16(pVal: Psqlite3_value): i32;
begin
  Result := sqlite3ValueBytes(pVal, SQLITE_UTF16NATIVE);
end;

function sqlite3_value_subtype(pVal: Psqlite3_value): u32;
begin
  if (pVal^.flags and MEM_Subtype) <> 0 then Result := pVal^.eSubtype
  else Result := 0;
end;

{ vdbeapi.c:214 — sqlite3_value_pointer.
  A typed-pointer Mem is encoded as MEM_Null|MEM_Term|MEM_Subtype with
  eSubtype='p'.  zPType must match the tag stored in u.zPType (strict
  strcmp, not stricmp) — used to enforce type-correctness of typed-
  pointer bindings (vtab IN-helpers, carray, etc.). }
function sqlite3_value_pointer(pVal: Psqlite3_value; zPType: PAnsiChar): Pointer;
const
  MASK = MEM_TypeMask or MEM_Term or MEM_Subtype;
  WANT = MEM_Null or MEM_Term or MEM_Subtype;
var
  pa, pb: PAnsiChar;
begin
  Result := nil;
  if (pVal = nil) or (zPType = nil) then Exit;
  if (pVal^.flags and MASK) <> WANT then Exit;
  if pVal^.eSubtype <> Ord('p') then Exit;
  pa := pVal^.u.zPType;
  if pa = nil then Exit;
  pb := zPType;
  while (pa^ <> #0) and (pa^ = pb^) do begin Inc(pa); Inc(pb); end;
  if pa^ = pb^ then Result := pVal^.z;
end;

function sqlite3_value_dup(pOrig: Psqlite3_value): Psqlite3_value;
var
  pNew: Psqlite3_value;
begin
  if pOrig = nil then begin Result := nil; Exit; end;
  pNew := Psqlite3_value(sqlite3_malloc(SizeOf(TMem)));
  if pNew = nil then begin Result := nil; Exit; end;
  FillChar(pNew^, SizeOf(TMem), 0);
  Move(pOrig^, pNew^, MEMCELLSIZE);
  pNew^.flags := pNew^.flags and not u16(MEM_Dyn);
  pNew^.db := nil;
  if (pNew^.flags and (MEM_Str or MEM_Blob)) <> 0 then begin
    pNew^.flags := (pNew^.flags and not u16(MEM_Static or MEM_Dyn)) or MEM_Ephem;
    if sqlite3VdbeMemMakeWriteable(pNew) <> SQLITE_OK then begin
      sqlite3ValueFree(pNew);
      pNew := nil;
    end;
  end;
  Result := pNew;
end;

procedure sqlite3_value_free(pOld: Psqlite3_value);
begin
  sqlite3ValueFree(pOld);
end;

function sqlite3_value_nochange(pVal: Psqlite3_value): i32;
begin
  if (pVal^.flags and (MEM_Null or MEM_Zero)) = (MEM_Null or MEM_Zero) then
    Result := 1
  else
    Result := 0;
end;

function sqlite3_value_frombind(pVal: Psqlite3_value): i32;
begin
  if (pVal^.flags and MEM_FromBind) <> 0 then Result := 1
  else Result := 0;
end;

procedure applyNumericAffinity(pRec: PMem; bTryForInt: i32); forward;

{ vdbe.c:436 — apply numeric affinity if value is TEXT, then return type. }
function sqlite3_value_numeric_type(pVal: Psqlite3_value): i32;
begin
  Result := sqlite3_value_type(pVal);
  if Result = SQLITE_TEXT then begin
    applyNumericAffinity(PMem(pVal), 0);
    Result := sqlite3_value_type(pVal);
  end;
end;

{ vdbeapi.c:329 }
function sqlite3_value_encoding(pVal: Psqlite3_value): i32;
begin
  if pVal = nil then begin Result := SQLITE_UTF8; Exit; end;
  Result := i32(pVal^.enc);
end;

{ --- static columnNullValue / columnMem helpers (vdbeapi.c:1285) --- }

var
  gNullMem: TMem;  { global static null Mem for out-of-range column access }

function columnNullValue: PMem;
begin
  Result := @gNullMem;
end;

function columnMem(pStmt: PVdbe; i: i32): PMem;
begin
  if pStmt = nil then begin Result := columnNullValue; Exit; end;
  if (pStmt^.pResultRow <> nil) and (i >= 0) and (i < pStmt^.nResColumn) then
    Result := pStmt^.pResultRow + i
  else
    Result := columnNullValue;
end;

{ --- sqlite3_column_* accessors (vdbeapi.c:1266) --- }

function sqlite3_column_count(pStmt: PVdbe): i32;
begin
  if pStmt = nil then begin Result := 0; Exit; end;
  Result := pStmt^.nResColumn;
end;

function sqlite3_data_count(pStmt: PVdbe): i32;
begin
  if (pStmt = nil) or (pStmt^.pResultRow = nil) then begin Result := 0; Exit; end;
  Result := pStmt^.nResColumn;
end;

function sqlite3_column_type(pStmt: PVdbe; i: i32): i32;
begin
  Result := sqlite3_value_type(columnMem(pStmt, i));
end;

function sqlite3_column_int(pStmt: PVdbe; i: i32): i32;
begin
  Result := sqlite3_value_int(columnMem(pStmt, i));
end;

function sqlite3_column_int64(pStmt: PVdbe; i: i32): i64;
begin
  Result := sqlite3_value_int64(columnMem(pStmt, i));
end;

function sqlite3_column_double(pStmt: PVdbe; i: i32): Double;
begin
  Result := sqlite3_value_double(columnMem(pStmt, i));
end;

function sqlite3_column_text(pStmt: PVdbe; i: i32): PAnsiChar;
begin
  Result := sqlite3_value_text(columnMem(pStmt, i));
end;

function sqlite3_column_blob(pStmt: PVdbe; i: i32): Pointer;
begin
  Result := sqlite3_value_blob(columnMem(pStmt, i));
end;

function sqlite3_column_bytes(pStmt: PVdbe; i: i32): i32;
begin
  Result := sqlite3_value_bytes(columnMem(pStmt, i));
end;

{ vdbeapi.c:1396 — sqlite3_column_bytes16. }
function sqlite3_column_bytes16(pStmt: PVdbe; i: i32): i32;
begin
  Result := sqlite3_value_bytes16(columnMem(pStmt, i));
end;

function sqlite3_column_value(pStmt: PVdbe; i: i32): Psqlite3_value;
var
  pOut: PMem;
begin
  pOut := columnMem(pStmt, i);
  if (pOut^.flags and MEM_Static) <> 0 then begin
    pOut^.flags := (pOut^.flags and not u16(MEM_Static)) or MEM_Ephem;
  end;
  Result := pOut;
end;

{ vdbeapi.c:1492 — columnName(pStmt, N, useUtf16, useType).
  Slot stored at aColName[N + useType*nResColumn]; encoding selected by
  useUtf16. }
const
  azExplainColNames8: array[0..11] of PAnsiChar = (
    'addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment',
    'id', 'parent', 'notused', 'detail'
  );

function columnName(pStmt: PVdbe; N: i32; useUtf16, useType: i32): Pointer;
var
  pCell:       PMem;
  off:         PtrUInt;
  explainBits: u32;
  nExp:        i32;
begin
  Result := nil;
  if pStmt = nil then Exit;
  if N < 0 then Exit;
  { vdbeapi.c:1505..1518 — EXPLAIN / EXPLAIN QUERY PLAN return canonical
    static column names regardless of any aColName setup performed by
    the inner SELECT codegen. }
  explainBits := (pStmt^.vdbeFlags and VDBF_EXPLAIN_MASK) shr VDBF_EXPLAIN_SHIFT;
  if explainBits <> 0 then begin
    if useType > 0 then Exit;
    if explainBits = 1 then nExp := 8 else nExp := 4;
    if N >= nExp then Exit;
    if useUtf16 = 0 then
      Result := Pointer(azExplainColNames8[N + 8 * i32(explainBits) - 8]);
    Exit;
  end;
  if N >= pStmt^.nResColumn then Exit;
  if pStmt^.aColName = nil then Exit;
  if (useType < 0) or (useType >= COLNAME_N) then Exit;
  off := PtrUInt(N + useType * i32(pStmt^.nResColumn)) * SizeOf(TMem);
  pCell := PMem(PtrUInt(pStmt^.aColName) + off);
  if useUtf16 <> 0 then
    Result := sqlite3ValueText(pCell, SQLITE_UTF16NATIVE)
  else
    Result := sqlite3ValueText(pCell, SQLITE_UTF8);
end;

function sqlite3_column_name(pStmt: PVdbe; N: i32): PAnsiChar;
begin
  Result := PAnsiChar(columnName(pStmt, N, 0, COLNAME_NAME));
end;

function sqlite3_column_name16(pStmt: PVdbe; N: i32): Pointer;
begin
  Result := columnName(pStmt, N, 1, COLNAME_NAME);
end;

function sqlite3_column_decltype(pStmt: PVdbe; N: i32): PAnsiChar;
begin
  Result := PAnsiChar(columnName(pStmt, N, 0, COLNAME_DECLTYPE));
end;

function sqlite3_column_decltype16(pStmt: PVdbe; N: i32): Pointer;
begin
  Result := columnName(pStmt, N, 1, COLNAME_DECLTYPE);
end;

{ vdbeapi.c:1589 — sqlite3_column_database_name (SQLITE_ENABLE_COLUMN_METADATA).
  Returns the name of the database from which a result column derives, or nil
  if the column is an expression / constant.  The aColName slot is populated
  by sqlite3VdbeSetColName(COLNAME_DATABASE) at codegen time. }
function sqlite3_column_database_name(pStmt: PVdbe; N: i32): PAnsiChar;
begin
  Result := PAnsiChar(columnName(pStmt, N, 0, COLNAME_DATABASE));
end;

function sqlite3_column_database_name16(pStmt: PVdbe; N: i32): Pointer;
begin
  Result := columnName(pStmt, N, 1, COLNAME_DATABASE);
end;

{ vdbeapi.c:1603 — sqlite3_column_table_name. }
function sqlite3_column_table_name(pStmt: PVdbe; N: i32): PAnsiChar;
begin
  Result := PAnsiChar(columnName(pStmt, N, 0, COLNAME_TABLE));
end;

function sqlite3_column_table_name16(pStmt: PVdbe; N: i32): Pointer;
begin
  Result := columnName(pStmt, N, 1, COLNAME_TABLE);
end;

{ vdbeapi.c:1617 — sqlite3_column_origin_name. }
function sqlite3_column_origin_name(pStmt: PVdbe; N: i32): PAnsiChar;
begin
  Result := PAnsiChar(columnName(pStmt, N, 0, COLNAME_COLUMN));
end;

function sqlite3_column_origin_name16(pStmt: PVdbe; N: i32): Pointer;
begin
  Result := columnName(pStmt, N, 1, COLNAME_COLUMN);
end;

{ vdbeapi.c:29 — sqlite3_expired (SQLITE_OMIT_DEPRECATED-gated upstream).
  Returns true if the prepared statement has been invalidated by a schema
  change since it was prepared.  Vdbe^.expired is the same flag set by
  sqlite3ExpirePreparedStatements; we expose it for legacy callers. }
function sqlite3_expired(pStmt: PVdbe): i32;
begin
  if pStmt = nil then
    Result := 1
  else if (pStmt^.vdbeFlags and VDBF_EXPIRED_MASK) <> 0 then
    Result := 1
  else
    Result := 0;
end;

{ vdbeapi.c:1257 — sqlite3_aggregate_count (deprecated).  Returns the
  number of times the step function of an aggregate has been called for
  the current row, taken from the n field of the aggregate's pMem cell. }
function sqlite3_aggregate_count(pCtx: Psqlite3_context): i32;
begin
  Result := pCtx^.pMem^.n;
end;

{ vdbeapi.c:1991 — sqlite3_transfer_bindings (deprecated).  Move bindings
  from one prepared statement to another that has the same number of
  parameters.  Both statements are flagged expired if they have any
  expmask bits set. }
function sqlite3_transfer_bindings(pFromStmt: PVdbe; pToStmt: PVdbe): i32;
var
  i: i32;
begin
  if pFromStmt^.nVar <> pToStmt^.nVar then begin
    Result := SQLITE_ERROR;
    Exit;
  end;
  if pToStmt^.expmask <> 0 then
    pToStmt^.vdbeFlags := (pToStmt^.vdbeFlags and not u32(VDBF_EXPIRED_MASK)) or 1;
  if pFromStmt^.expmask <> 0 then
    pFromStmt^.vdbeFlags := (pFromStmt^.vdbeFlags and not u32(VDBF_EXPIRED_MASK)) or 1;
  for i := 0 to pFromStmt^.nVar - 1 do
    sqlite3VdbeMemMove(pToStmt^.aVar + i, pFromStmt^.aVar + i);
  Result := SQLITE_OK;
end;

{ vdbeapi.c:1431 — sqlite3_column_text16. }
function sqlite3_column_text16(pStmt: PVdbe; i: i32): Pointer;
begin
  Result := sqlite3_value_text16(columnMem(pStmt, i));
end;

{ --- vdbeUnbind helper (vdbeapi.c:1654) --- }

function vdbeUnbind55(p: PVdbe; i: u32): i32;
var
  pVar: PMem;
  db:   PTsqlite3;
begin
  if p = nil then begin Result := SQLITE_MISUSE; Exit; end;
  db := p^.db;
  if p^.eVdbeState <> VDBE_READY_STATE then begin
    { vdbeapi.c:1660-1666 — set the connection error to SQLITE_MISUSE so
      sqlite3_errmsg reports the standard text. }
    db^.errCode := SQLITE_MISUSE;
    if db^.pErr <> nil then sqlite3ValueSetNull(Psqlite3_value(db^.pErr));
    sqlite3SystemError(db, SQLITE_MISUSE);
    Result := SQLITE_MISUSE; Exit;
  end;
  if i >= u32(p^.nVar) then begin
    { vdbeapi.c:1667-1671 — sqlite3Error(p->db, SQLITE_RANGE) so the
      connection error message becomes "column index out of range". }
    db^.errCode := SQLITE_RANGE;
    if db^.pErr <> nil then sqlite3ValueSetNull(Psqlite3_value(db^.pErr));
    sqlite3SystemError(db, SQLITE_RANGE);
    Result := SQLITE_RANGE; Exit;
  end;
  pVar := p^.aVar + i;
  sqlite3VdbeMemRelease(pVar);
  pVar^.flags := MEM_Null;
  { vdbeapi.c:1675 — successful unbind clears any prior error. }
  db^.errCode := SQLITE_OK;

  { vdbeapi.c:1685..1687 — if the bit for this variable is set in expmask,
    binding a new value invalidates the current query plan, so flag the VM
    expired (expired=1) to force a reprepare on the next sqlite3_step().  The
    expired field is the low 2 bits of vdbeFlags (VDBF_EXPIRED_MASK).
    C: if( p->expmask!=0 && (p->expmask & (i>=31?0x80000000:(u32)1<<i))!=0 ) }
  if (p^.expmask <> 0) then
  begin
    if i >= 31 then
    begin
      if (p^.expmask and u32($80000000)) <> 0 then
        p^.vdbeFlags := (p^.vdbeFlags and not u32(VDBF_EXPIRED_MASK)) or 1;
    end
    else if (p^.expmask and (u32(1) shl i)) <> 0 then
      p^.vdbeFlags := (p^.vdbeFlags and not u32(VDBF_EXPIRED_MASK)) or 1;
  end;
  Result := SQLITE_OK;
end;

{ --- sqlite3_bind_* (vdbeapi.c:1749) --- }

function sqlite3_bind_int(pStmt: PVdbe; i: i32; iVal: i32): i32;
begin
  Result := sqlite3_bind_int64(pStmt, i, i64(iVal));
end;

function sqlite3_bind_int64(pStmt: PVdbe; i: i32; iVal: i64): i32;
var rc: i32;
begin
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc = SQLITE_OK then
    sqlite3VdbeMemSetInt64(pStmt^.aVar + (i - 1), iVal);
  Result := rc;
end;

function sqlite3_bind_double(pStmt: PVdbe; i: i32; rVal: Double): i32;
var rc: i32;
begin
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc = SQLITE_OK then
    sqlite3VdbeMemSetDouble(pStmt^.aVar + (i - 1), rVal);
  Result := rc;
end;

function sqlite3_bind_null(pStmt: PVdbe; i: i32): i32;
begin
  Result := vdbeUnbind55(pStmt, u32(i - 1));
end;

function sqlite3_bind_text(pStmt: PVdbe; i: i32; zData: PAnsiChar;
                           nData: i32; xDel: TxDelProc): i32;
var
  rc: i32;
  pVar: PMem;
begin
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc <> SQLITE_OK then begin
    if (xDel <> SQLITE_STATIC) and (xDel <> SQLITE_TRANSIENT) and
       (xDel <> nil) and (zData <> nil) then
      xDel(zData);
    Result := rc; Exit;
  end;
  if zData <> nil then begin
    pVar := pStmt^.aVar + (i - 1);
    rc := sqlite3VdbeMemSetText(pVar, zData, nData, xDel);
    if rc = SQLITE_OK then
      rc := sqlite3VdbeChangeEncoding(pVar, PTsqlite3(pStmt^.db)^.enc);
  end;
  Result := rc;
end;

function sqlite3_bind_blob(pStmt: PVdbe; i: i32; zData: Pointer;
                           nData: i32; xDel: TxDelProc): i32;
var
  rc: i32;
  pVar: PMem;
begin
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc <> SQLITE_OK then begin
    if (xDel <> SQLITE_STATIC) and (xDel <> SQLITE_TRANSIENT) and
       (xDel <> nil) and (zData <> nil) then
      xDel(zData);
    Result := rc; Exit;
  end;
  if zData <> nil then begin
    pVar := pStmt^.aVar + (i - 1);
    rc := sqlite3VdbeMemSetStr(pVar, zData, nData, 0, xDel);
  end;
  Result := rc;
end;

{ vdbeapi.c:1761 — sqlite3_bind_blob64.
  i64-length blob bind.  C body asserts xDel<>SQLITE_DYNAMIC then
  delegates to bindText with encoding=0 (BLOB).  Pascal port inlines
  the bindText body since no shared helper exists; sqlite3VdbeMemSetStr
  already accepts i64 nData and enforces SQLITE_LIMIT_LENGTH. }
function sqlite3_bind_blob64(pStmt: PVdbe; i: i32; zData: Pointer;
                             nData: u64; xDel: TxDelProc): i32;
var
  rc: i32;
  pVar: PMem;
begin
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc <> SQLITE_OK then begin
    if (xDel <> SQLITE_STATIC) and (xDel <> SQLITE_TRANSIENT) and
       (xDel <> nil) and (zData <> nil) then
      xDel(zData);
    Result := rc; Exit;
  end;
  if zData <> nil then begin
    pVar := pStmt^.aVar + (i - 1);
    rc := sqlite3VdbeMemSetStr(pVar, zData, i64(nData), 0, xDel);
  end;
  Result := rc;
end;

{ vdbeapi.c:1834 — sqlite3_bind_text64.
  i64-length text bind with explicit encoding.  Mirrors the C body:
  for non-UTF8 encodings, SQLITE_UTF16 is mapped to SQLITE_UTF16NATIVE
  and nData is masked to even (drops trailing half-codeunit). }
function sqlite3_bind_text64(pStmt: PVdbe; i: i32; zData: PAnsiChar;
                             nData: u64; xDel: TxDelProc; enc: u8): i32;
var
  rc: i32;
  pVar: PMem;
  effEnc: u8;
  effLen: i64;
begin
  effEnc := enc;
  effLen := i64(nData);
  if effEnc <> SQLITE_UTF8 then begin
    if effEnc = SQLITE_UTF16 then effEnc := SQLITE_UTF16NATIVE;
    effLen := effLen and (not i64(1));
  end;
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc <> SQLITE_OK then begin
    if (xDel <> SQLITE_STATIC) and (xDel <> SQLITE_TRANSIENT) and
       (xDel <> nil) and (zData <> nil) then
      xDel(zData);
    Result := rc; Exit;
  end;
  if zData <> nil then begin
    pVar := pStmt^.aVar + (i - 1);
    if effEnc = SQLITE_UTF8 then begin
      rc := sqlite3VdbeMemSetText(pVar, zData, effLen, xDel);
      if rc = SQLITE_OK then
        rc := sqlite3VdbeChangeEncoding(pVar, PTsqlite3(pStmt^.db)^.enc);
    end else begin
      rc := sqlite3VdbeMemSetStr(pVar, zData, effLen, effEnc, xDel);
      if rc = SQLITE_OK then
        rc := sqlite3VdbeChangeEncoding(pVar, PTsqlite3(pStmt^.db)^.enc);
    end;
  end;
  Result := rc;
end;

{ vdbeapi.c:1850 — sqlite3_bind_text16.
  UTF-16 text bind.  C body delegates to bindText with
  SQLITE_UTF16NATIVE encoding and length masked to even. }
function sqlite3_bind_text16(pStmt: PVdbe; i: i32; zData: Pointer;
                             n: i32; xDel: TxDelProc): i32;
var
  rc: i32;
  pVar: PMem;
  effLen: i64;
begin
  effLen := i64(n) and (not i64(1));
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc <> SQLITE_OK then begin
    if (xDel <> SQLITE_STATIC) and (xDel <> SQLITE_TRANSIENT) and
       (xDel <> nil) and (zData <> nil) then
      xDel(zData);
    Result := rc; Exit;
  end;
  if zData <> nil then begin
    pVar := pStmt^.aVar + (i - 1);
    rc := sqlite3VdbeMemSetStr(pVar, PAnsiChar(zData), effLen,
                               SQLITE_UTF16NATIVE, xDel);
    if rc = SQLITE_OK then
      rc := sqlite3VdbeChangeEncoding(pVar, PTsqlite3(pStmt^.db)^.enc);
  end;
  Result := rc;
end;

{ vdbeapi.c:1894 — sqlite3_bind_zeroblob.
  Binds an n-byte zero-blob placeholder to the i'th host parameter.
  vdbeUnbind55 already validates the (pStmt, i) pair and returns
  SQLITE_MISUSE for out-of-range indices, matching the C body's
  behaviour without the sqlite3_mutex_leave call (this port has no
  per-connection mutex).  The OMIT_INCRBLOB arm of the C body applies
  here because passqlite3vdbe builds without incrblob; the return
  value of MemSetZeroBlob is preserved. }
function sqlite3_bind_zeroblob(pStmt: PVdbe; i: i32; n: i32): i32;
var
  rc: i32;
begin
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc = SQLITE_OK then
    sqlite3VdbeMemSetZeroBlob(pStmt^.aVar + (i - 1), n);
  Result := rc;
end;

{ vdbeapi.c:1909 — sqlite3_bind_zeroblob64.
  Same as sqlite3_bind_zeroblob but takes a u64 size; rejects n above
  SQLITE_LIMIT_LENGTH with SQLITE_TOOBIG before delegating. }
function sqlite3_bind_zeroblob64(pStmt: PVdbe; i: i32; n: u64): i32;
var
  db: PTsqlite3;
begin
  if pStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  db := PTsqlite3(pStmt^.db);
  if (db <> nil) and (n > u64(db^.aLimit[0])) then
    Result := SQLITE_TOOBIG
  else
    Result := sqlite3_bind_zeroblob(pStmt, i, i32(n));
end;

{ vdbeapi.c:1806 — sqlite3_bind_pointer.
  Bind a typed pointer to the i'th host parameter.  vdbeUnbind55
  validates pStmt and i; on validation failure the destructor (if any)
  is invoked with pPtr to release ownership, mirroring the C body. }
function sqlite3_bind_pointer(pStmt: PVdbe; i: i32; pPtr: Pointer;
                              zPType: PAnsiChar; xDestructor: TxDelProc): i32;
var
  rc: i32;
begin
  rc := vdbeUnbind55(pStmt, u32(i - 1));
  if rc = SQLITE_OK then
    sqlite3VdbeMemSetPointer(pStmt^.aVar + (i - 1), pPtr, zPType, xDestructor)
  else if Assigned(xDestructor) then
    xDestructor(pPtr);
  Result := rc;
end;

function sqlite3_bind_value(pStmt: PVdbe; i: i32;
                            pValue: Psqlite3_value): i32;
begin
  { vdbeapi.c:1383 — bind by value MUST honour the value's own text encoding
    (pValue->enc), not assume UTF-8.  The C TEXT arm calls
    bindText(...,pValue->enc); our sqlite3_bind_text64 is that bindText.  The
    previous port routed through sqlite3_bind_text (UTF-8 only), so a UTF-16
    sqlite3_value bound into e.g. an FTS3 content-insert statement in a
    PRAGMA encoding=utf-16 db was treated as UTF-8 and truncated at the first
    embedded NUL byte (fts3snippet utf16 / fts4umlaut). }
  case sqlite3_value_type(pValue) of
    SQLITE_INTEGER: Result := sqlite3_bind_int64(pStmt, i, pValue^.u.i);
    SQLITE_FLOAT:   Result := sqlite3_bind_double(pStmt, i, pValue^.u.r);
    SQLITE_TEXT:    Result := sqlite3_bind_text64(pStmt, i,
                                pValue^.z, u64(pValue^.n), SQLITE_TRANSIENT,
                                pValue^.enc);
    SQLITE_BLOB:    Result := sqlite3_bind_blob(pStmt, i,
                                pValue^.z, pValue^.n, SQLITE_TRANSIENT);
    else            Result := sqlite3_bind_null(pStmt, i);
  end;
end;

function sqlite3_bind_parameter_count(pStmt: PVdbe): i32;
begin
  if pStmt = nil then begin Result := 0; Exit; end;
  Result := pStmt^.nVar;
end;

{ vdbeapi.c:1942 — name of an indexed wildcard, NULL if unnamed/out-of-range. }
function sqlite3_bind_parameter_name(pStmt: PVdbe; i: i32): PAnsiChar;
begin
  if pStmt = nil then begin Result := nil; Exit; end;
  Result := sqlite3VListNumToName(pStmt^.pVList, i);
end;

{ vdbeapi.c:1953/1957 — name → 1-based wildcard index, 0 if absent. }
function sqlite3VdbeParameterIndex(p: PVdbe; zName: PAnsiChar; nName: i32): i32;
begin
  if (p = nil) or (zName = nil) then begin Result := 0; Exit; end;
  Result := sqlite3VListNameToNum(p^.pVList, zName, nName);
end;

function sqlite3_bind_parameter_index(pStmt: PVdbe; zName: PAnsiChar): i32;
begin
  Result := sqlite3VdbeParameterIndex(pStmt, zName, sqlite3Strlen30(zName));
end;

{ --- sqlite3_clear_bindings (vdbeapi.c:149) --- }

function sqlite3_clear_bindings(pStmt: PVdbe): i32;
var
  i: i32;
begin
  if pStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  for i := 0 to pStmt^.nVar - 1 do begin
    sqlite3VdbeMemRelease(pStmt^.aVar + i);
    (pStmt^.aVar + i)^.flags := MEM_Null;
  end;
  Result := SQLITE_OK;
end;

{ vdbeapi.c:739 — doWalCallbacks.  Invoked from sqlite3Step after a
  statement commits (rc=DONE && db->autoCommit).  Walks every attached
  Btree, drains its pager's pending wal-frame count via
  sqlite3PagerWalCallback, and fires the registered xWalCallback for
  any database that wrote frames.  Without this, db.wal_hook never
  observes the frames a COMMIT just flushed (9.4.divbug.37). }
function doWalCallbacks(db: PTsqlite3): i32;
type
  TWalCb = function(p: Pointer; db: PTsqlite3; zDb: PAnsiChar;
                    nFrame: i32): i32; cdecl;
var
  i      : i32;
  pBt    : PBtree;
  nEntry : i32;
begin
  Result := SQLITE_OK;
  if db = nil then Exit;
  for i := 0 to db^.nDb - 1 do begin
    pBt := PBtree(db^.aDb[i].pBt);
    if pBt <> nil then begin
      sqlite3BtreeEnter(pBt);
      nEntry := sqlite3PagerWalCallback(sqlite3BtreePager(pBt));
      sqlite3BtreeLeave(pBt);
      if (nEntry > 0) and (db^.xWalCallback <> nil) and (Result = SQLITE_OK) then
        Result := TWalCb(db^.xWalCallback)(db^.pWalArg, db,
                    db^.aDb[i].zDbSName, nEntry);
    end;
  end;
end;

{ --- sqlite3_step / sqlite3_reset / sqlite3_finalize (vdbeapi.c:771) --- }

{ Inner step (vdbeapi.c:771 sqlite3Step) — public sqlite3_step (vdbeapi.c:911)
  is the wrapper below that catches SQLITE_SCHEMA and reprepares. }
function sqlite3StepInternal(pStmt: PVdbe): i32;
type
  { vdbeapi.c:72 — legacy sqlite3_profile callback shape. }
  TVdbeLegacyProfileFn = procedure(p: Pointer; zSql: PAnsiChar; tm: u64); cdecl;
var
  rc: i32;
  db: PTsqlite3;
  iElapse, iNowProf: i64;
begin
  if pStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  db := pStmt^.db;

  { Auto-reset if in HALT state (vdbeapi.c:846) — C calls the public
    sqlite3_reset(), i.e. sqlite3VdbeReset + sqlite3VdbeRewind; the Rewind is
    what restores VDBE_READY_STATE so the restart_step re-check below succeeds.
    (sqlite3VdbeReset no longer sets eVdbeState — see vdbeaux.c:3586.) }
  if pStmt^.eVdbeState = VDBE_HALT_STATE then begin
    sqlite3VdbeReset(pStmt);
    sqlite3VdbeRewind(pStmt);
  end;

  { vdbeapi.c:779..792 — expired-stmt short-circuit.  Must precede the
    READY→RUN transition so we don't bump counters or run any opcodes.
    Sets p^.rc=SCHEMA so sqlite3_finalize returns SCHEMA, while step
    itself returns SQLITE_ERROR (folded to 0xff later).  When prepared
    with SAVESQL the real db error is surfaced via TransferError. }
  if (pStmt^.eVdbeState = VDBE_READY_STATE)
     and ((pStmt^.vdbeFlags and VDBF_EXPIRED_MASK) <> 0) then begin
    pStmt^.rc := SQLITE_SCHEMA;
    rc := SQLITE_ERROR;
    if (pStmt^.prepFlags and SQLITE_PREPARE_SAVESQL) <> 0 then
      rc := sqlite3VdbeTransferError(pStmt);
    if db <> nil then begin
      db^.errCode := rc;
      Result := rc and db^.errMask;
    end else
      Result := rc;
    Exit;
  end;

  { vdbeapi.c:794..800 — if no other statements are running, reset the
    interrupt flag so a stale sqlite3_interrupt from a previous statement
    doesn't immediately abort this one. }
  if (pStmt^.eVdbeState = VDBE_READY_STATE)
     and (db <> nil) and (db^.nVdbeActive = 0) then begin
    db^.u1.isInterrupted := 0;
  end;

  { Transition READY → RUN — vdbeapi.c:815..819 }
  if pStmt^.eVdbeState = VDBE_READY_STATE then begin
    if db <> nil then begin
      Inc(db^.nVdbeActive);
      if (pStmt^.vdbeFlags and VDBF_ReadOnly) = 0 then Inc(db^.nVdbeWrite);
      if (pStmt^.vdbeFlags and VDBF_IsReader) <> 0 then Inc(db^.nVdbeRead);
    end;
    { vdbeapi.c:806..813 — capture startTime for SQLITE_TRACE_PROFILE. }
    if (db <> nil) and (pStmt^.zSql <> nil)
       and ((db^.mTrace and (SQLITE_TRACE_PROFILE or SQLITE_TRACE_XPROFILE)) <> 0)
       and (db^.init.busy = 0) then begin
      sqlite3OsCurrentTimeInt64(Psqlite3_vfs(db^.pVfs), @pStmt^.startTime);
    end else begin
      pStmt^.startTime := 0;
    end;
    pStmt^.pc := 0;
    pStmt^.eVdbeState := VDBE_RUN_STATE;
  end;

  if db <> nil then Inc(db^.nVdbeExec);
  if (pStmt^.vdbeFlags and VDBF_EXPLAIN_MASK) <> 0 then
    rc := sqlite3VdbeList(pStmt)
  else
    rc := sqlite3VdbeExec(pStmt);
  if db <> nil then Dec(db^.nVdbeExec);

  if rc = SQLITE_ROW then begin
    if db <> nil then db^.errCode := SQLITE_ROW;
    Result := SQLITE_ROW; Exit;
  end;

  { vdbeapi.c:62..79 — invoke SQLITE_TRACE_PROFILE callback at end of step. }
  if (db <> nil) and (pStmt^.startTime > 0) then begin
    iNowProf := 0;
    sqlite3OsCurrentTimeInt64(Psqlite3_vfs(db^.pVfs), @iNowProf);
    iElapse := (iNowProf - pStmt^.startTime) * 1000000;
    { vdbeapi.c:70..73 — NOT SQLITE_OMIT_DEPRECATED: legacy xProfile. }
    if Assigned(db^.xProfile) then
      TVdbeLegacyProfileFn(db^.xProfile)(db^.pProfileArg, pStmt^.zSql, iElapse);
    if ((db^.mTrace and SQLITE_TRACE_PROFILE) <> 0)
       and Assigned(db^.trace.xV2) then
      db^.trace.xV2(SQLITE_TRACE_PROFILE, db^.pTraceArg, pStmt, @iElapse);
    pStmt^.startTime := 0;
  end;

  pStmt^.pResultRow := nil;
  { vdbeapi.c:878..883 — on clean commit, invoke wal_hook callbacks
    (9.4.divbug.37).  Must precede the error-transfer arm so a hook
    failure can override rc. }
  if (rc = SQLITE_DONE) and (db <> nil) and (db^.autoCommit <> 0) then begin
    pStmt^.rc := doWalCallbacks(db);
    if pStmt^.rc <> SQLITE_OK then rc := SQLITE_ERROR;
  end;
  if db <> nil then begin
    { vdbeapi.c:884..890 — only transfer p^.zErrMsg into db^.pErr when the
      stmt was prepared with SAVESQL (i.e. sqlite3_prepare_v2/v3).  For
      legacy sqlite3_prepare the real error stays attached to the stmt
      (surfaced via sqlite3_finalize/_reset) and sqlite3_errmsg(db) must
      return the generic "SQL logic error" string from db^.errCode alone
      (errmsg-1.1 / 2.2 / 3.1.2). }
    if (rc <> SQLITE_DONE)
       and ((pStmt^.prepFlags and SQLITE_PREPARE_SAVESQL) <> 0) then
      rc := sqlite3VdbeTransferError(pStmt);
    db^.errCode := rc;
    Dec(db^.nVdbeActive);
    { vdbeapi.c sqlite3Step tail — fold extended → primary unless the
      app opted in via sqlite3_extended_result_codes(...,1). }
    rc := rc and db^.errMask;
  end;
  Result := rc;
end;

{ vdbeapi.c:911 — public sqlite3_step wrapper.  Catches SQLITE_SCHEMA from
  the inner step, invokes sqlite3Reprepare (via gReprepare trampoline; main
  owns the body) and retries up to SQLITE_MAX_SCHEMA_RETRY times.  Without
  this loop a prepared statement that survives a concurrent schema change
  (e.g. backup overwrite — backup5-1.6) keeps returning SQLITE_SCHEMA or,
  worse, decodes stale b-tree pages and surfaces bogus SQLITE_CORRUPT. }
function sqlite3_step(pStmt: PVdbe): i32;
var
  rc:      i32;
  cnt:     i32;
  savedPc: i32;
  db:      PTsqlite3;
  zErr:    PAnsiChar;
begin
  if pStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  db  := pStmt^.db;
  cnt := 0;
  rc  := sqlite3StepInternal(pStmt);
  while (rc = SQLITE_SCHEMA) and (cnt < SQLITE_MAX_SCHEMA_RETRY)
        and Assigned(gReprepare) do begin
    Inc(cnt);
    savedPc := pStmt^.pc;
    rc := gReprepare(pStmt);
    if rc <> SQLITE_OK then begin
      { Reprepare failed — copy the parser error from db^.pErr into the
        stmt so sqlite3_errmsg() returns it after sqlite3_finalize.
        Matches vdbeapi.c:929..945. }
      if (db <> nil) and (db^.pErr <> nil) then
        zErr := PAnsiChar(sqlite3_value_text(db^.pErr))
      else
        zErr := nil;
      sqlite3DbFree(db, pStmt^.zErrMsg);
      if (db = nil) or (db^.mallocFailed = 0) then begin
        if zErr <> nil then
          pStmt^.zErrMsg := PAnsiChar(sqlite3DbStrDup(db, zErr))
        else
          pStmt^.zErrMsg := nil;
        pStmt^.rc := rc;
        if db <> nil then db^.errCode := rc;
      end else begin
        pStmt^.zErrMsg := nil;
        pStmt^.rc      := SQLITE_NOMEM;
        rc             := SQLITE_NOMEM;
        if db <> nil then db^.errCode := SQLITE_NOMEM;
      end;
      Break;
    end;
    sqlite3_reset(pStmt);
    if savedPc >= 0 then
      pStmt^.minWriteFileFormat := 254;
    rc := sqlite3StepInternal(pStmt);
  end;
  Result := rc;
end;

function sqlite3_reset(pStmt: PVdbe): i32;
begin
  if pStmt = nil then begin Result := SQLITE_OK; Exit; end;
  Result := sqlite3VdbeReset(pStmt);
  sqlite3VdbeRewind(pStmt);
end;

function sqlite3_finalize(pStmt: PVdbe): i32;
begin
  if pStmt = nil then begin Result := SQLITE_OK; Exit; end;
  if pStmt^.db = nil then begin Result := SQLITE_MISUSE; Exit; end;
  Result := sqlite3VdbeReset(pStmt);
  sqlite3VdbeDelete(pStmt);
end;

{ ============================================================================
  Phase 6.6 — vdbeapi.c sqlite3_result_* context setters
  ============================================================================ }

procedure sqlite3_result_null(pCtx: Psqlite3_context);
begin
  if pCtx = nil then Exit;
  sqlite3VdbeMemSetNull(pCtx^.pOut);
end;

procedure sqlite3_result_int(pCtx: Psqlite3_context; iVal: i32);
begin
  if pCtx = nil then Exit;
  sqlite3VdbeMemSetInt64(pCtx^.pOut, i64(iVal));
end;

procedure sqlite3_result_int64(pCtx: Psqlite3_context; iVal: i64);
begin
  if pCtx = nil then Exit;
  sqlite3VdbeMemSetInt64(pCtx^.pOut, iVal);
end;

procedure sqlite3_result_double(pCtx: Psqlite3_context; rVal: Double);
begin
  if pCtx = nil then Exit;
  sqlite3VdbeMemSetDouble(pCtx^.pOut, rVal);
end;

{ vdbeapi.c:387 — setResultStrOrError.  After setting the result text on
  the function's pOut Mem, convert it to pCtx->enc so downstream column
  output sees bytes in the requested encoding.  Fixes bucket-K: hex()
  over a UTF-16 text value previously left the hex digits tagged
  SQLITE_UTF8 inside a UTF-16 database, and column_text returned the
  raw ASCII bytes wearing a UTF-16 label. }
procedure setResultStrOrError(pCtx: Psqlite3_context; z: PAnsiChar;
                              n: i32; enc: u8; xDel: TxDelProc);
var
  pOut: PMem;
  rc:   i32;
begin
  pOut := pCtx^.pOut;
  rc := sqlite3VdbeMemSetStr(pOut, z, n, enc, xDel);
  if rc <> 0 then
  begin
    if rc = SQLITE_TOOBIG then sqlite3_result_error_toobig(pCtx)
    else sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  sqlite3VdbeChangeEncoding(pOut, pCtx^.enc);
  if sqlite3VdbeMemTooBig(pOut) <> 0 then
    sqlite3_result_error_toobig(pCtx);
end;

procedure sqlite3_result_text(pCtx: Psqlite3_context; z: PAnsiChar;
  n: i32; xDel: TxDelProc);
begin
  if pCtx = nil then Exit;
  setResultStrOrError(pCtx, z, n, SQLITE_UTF8, xDel);
end;

procedure sqlite3_result_blob(pCtx: Psqlite3_context; z: Pointer;
  n: i32; xDel: TxDelProc);
begin
  if pCtx = nil then Exit;
  setResultStrOrError(pCtx, PAnsiChar(z), n, 0, xDel);
end;

{ vdbeapi.c:880 — wide-length blob result.  Mirrors sqlite3_result_blob
  but accepts a u64 length so callers producing >2GB payloads can at
  least signal SQLITE_TOOBIG instead of overflowing into a negative i32. }
procedure sqlite3_result_blob64(pCtx: Psqlite3_context; z: Pointer;
  n: u64; xDel: TxDelProc);
begin
  if pCtx = nil then Exit;
  if n > $7FFFFFFF then
  begin
    sqlite3_result_error_toobig(pCtx);
    Exit;
  end;
  setResultStrOrError(pCtx, PAnsiChar(z), i32(n), 0, xDel);
end;

procedure sqlite3_result_value(pCtx: Psqlite3_context; pVal: Psqlite3_value);
var
  pOut: PMem;
begin
  if (pCtx = nil) or (pVal = nil) then Exit;
  pOut := pCtx^.pOut;
  sqlite3VdbeMemCopy(pOut, PMem(pVal));
  sqlite3VdbeChangeEncoding(pOut, SQLITE_UTF8);
  if sqlite3VdbeMemTooBig(pOut) <> 0 then
    sqlite3_result_error_toobig(pCtx);
end;

procedure sqlite3_result_error(pCtx: Psqlite3_context; z: PAnsiChar; n: i32);
begin
  if pCtx = nil then Exit;
  pCtx^.isError := SQLITE_ERROR;
  sqlite3VdbeMemSetStr(pCtx^.pOut, z, n, SQLITE_UTF8, SQLITE_TRANSIENT);
end;

{ vdbeapi.c:616 — sqlite3_result_text16.  UTF-16 result with native byte
  order.  C masks n with ~(u64)1 to drop a stray low bit before delegating
  to setResultStrOrError; we fold that mask in directly and call
  sqlite3VdbeMemSetStr like the existing _text64 path. }
procedure sqlite3_result_text16(pCtx: Psqlite3_context; z: Pointer;
                                n: i32; xDel: TxDelProc);
begin
  if pCtx = nil then Exit;
  setResultStrOrError(pCtx, PAnsiChar(z), n and (not 1),
                      SQLITE_UTF16NATIVE, xDel);
end;

{ vdbeapi.c:625 — sqlite3_result_text16be. }
procedure sqlite3_result_text16be(pCtx: Psqlite3_context; z: Pointer;
                                  n: i32; xDel: TxDelProc);
begin
  if pCtx = nil then Exit;
  setResultStrOrError(pCtx, PAnsiChar(z), n and (not 1),
                      SQLITE_UTF16BE, xDel);
end;

{ vdbeapi.c:634 — sqlite3_result_text16le. }
procedure sqlite3_result_text16le(pCtx: Psqlite3_context; z: Pointer;
                                  n: i32; xDel: TxDelProc);
begin
  if pCtx = nil then Exit;
  setResultStrOrError(pCtx, PAnsiChar(z), n and (not 1),
                      SQLITE_UTF16LE, xDel);
end;

{ vdbeapi.c:503 — sqlite3_result_error16.  UTF-16 error string. }
procedure sqlite3_result_error16(pCtx: Psqlite3_context; z: Pointer; n: i32);
begin
  if pCtx = nil then Exit;
  pCtx^.isError := SQLITE_ERROR;
  sqlite3VdbeMemSetStr(pCtx^.pOut, PAnsiChar(z), n, SQLITE_UTF16NATIVE,
                       SQLITE_TRANSIENT);
end;

procedure sqlite3_result_error_nomem(pCtx: Psqlite3_context);
begin
  if pCtx = nil then Exit;
  sqlite3VdbeMemSetNull(pCtx^.pOut);
  pCtx^.isError := SQLITE_NOMEM_BKPT;
  if pCtx^.pOut^.db <> nil then
    sqlite3OomFault(pCtx^.pOut^.db);
end;

procedure sqlite3_result_error_toobig(pCtx: Psqlite3_context);
begin
  if pCtx = nil then Exit;
  pCtx^.isError := SQLITE_TOOBIG;
  sqlite3VdbeMemSetStr(pCtx^.pOut, 'string or blob too big', -1,
    SQLITE_UTF8, SQLITE_STATIC);
end;

function sqlite3_result_zeroblob64(pCtx: Psqlite3_context; n: u64): i32;
begin
  if pCtx = nil then begin Result := SQLITE_MISUSE; Exit; end;
  if n > u64(SQLITE_MAX_LENGTH) then begin
    sqlite3_result_error_toobig(pCtx);
    Result := SQLITE_TOOBIG; Exit;
  end;
  sqlite3VdbeMemSetZeroBlob(pCtx^.pOut, i32(n));
  Result := SQLITE_OK;
end;

{ vdbeapi.c:662 — sqlite3_result_zeroblob.  Negative n maps to 0 per C. }
procedure sqlite3_result_zeroblob(pCtx: Psqlite3_context; n: i32);
begin
  if n > 0 then
    sqlite3_result_zeroblob64(pCtx, u64(n))
  else
    sqlite3_result_zeroblob64(pCtx, 0);
end;

{ vdbeapi.c:684 — sqlite3_result_error_code.  Sets isError without
  changing the result Mem; errCode=0 maps to -1 to keep isError truthy. }
procedure sqlite3_result_error_code(pCtx: Psqlite3_context; errCode: i32);
begin
  if pCtx = nil then Exit;
  if errCode <> 0 then pCtx^.isError := errCode
  else pCtx^.isError := -1;
  if (pCtx^.pOut^.flags and MEM_Null) <> 0 then
    sqlite3VdbeMemSetStr(pCtx^.pOut, sqlite3ErrStr(errCode), -1,
                         SQLITE_UTF8, SQLITE_STATIC);
end;

{ vdbeapi.c:533 — sqlite3_result_pointer.  Encode a typed pointer in
  pCtx^.pOut as MEM_Null|MEM_Term|MEM_Subtype with eSubtype='p'. }
procedure sqlite3_result_pointer(pCtx: Psqlite3_context; pPtr: Pointer;
                                 zPType: PAnsiChar; xDestructor: TxDelProc);
var
  pOut: PMem;
begin
  if pCtx = nil then begin
    if Assigned(xDestructor) then xDestructor(pPtr);
    Exit;
  end;
  pOut := pCtx^.pOut;
  sqlite3VdbeMemRelease(pOut);
  pOut^.flags := MEM_Null;
  sqlite3VdbeMemSetPointer(pOut, pPtr, zPType, xDestructor);
end;

function sqlite3_aggregate_context(pCtx: Psqlite3_context;
  nByte: i32): Pointer;
var
  pAggMem: PMem;
begin
  if pCtx = nil then begin Result := nil; Exit; end;
  pAggMem := pCtx^.pMem;
  if (pAggMem^.flags and MEM_Agg) = 0 then begin
    { createAggContext — vdbeapi.c }
    if nByte <= 0 then begin
      sqlite3VdbeMemSetNull(pAggMem);
      pAggMem^.z := nil;
    end else begin
      sqlite3VdbeMemClearAndResize(pAggMem, nByte);
      pAggMem^.flags  := MEM_Agg;
      pAggMem^.u.pDef := pCtx^.pFunc;
      if pAggMem^.z <> nil then
        FillChar(pAggMem^.z^, nByte, 0);
    end;
  end;
  Result := pAggMem^.z;
end;

{ vdbeapi.c:1106 — sqlite3StmtCurrentTime.  Latch the current time for the
  duration of one statement run so repeated calls within the same statement
  observe the same value (e.g. multiple julianday('now') invocations in the
  same SELECT row).  Returns 0 on VFS-side error. }
function sqlite3StmtCurrentTime(pCtx: Psqlite3_context): i64;
var
  piTime: Pi64;
  rc:     i32;
  pVfs:   Psqlite3_vfs;
begin
  Assert(pCtx^.pVdbe <> nil);
  piTime := @pCtx^.pVdbe^.iCurrentTime;
  if piTime^ = 0 then begin
    pVfs := Psqlite3_vfs(PTsqlite3(pCtx^.pOut^.db)^.pVfs);
    rc := sqlite3OsCurrentTimeInt64(pVfs, piTime);
    if rc <> 0 then piTime^ := 0;
  end;
  Result := piTime^;
end;

{ ============================================================================
  Phase 5.6 — vdbeblob.c incremental blob I/O

  sqlite3_blob_open requires the SQL compiler (Phase 7+) and returns
  SQLITE_ERROR as a stub until then.  The remaining 5 functions are fully
  implemented at the type/protocol level.
  ============================================================================ }

function sqlite3_blob_open(db: PTsqlite3; zDb, zTable, zColumn: PAnsiChar;
                           iRow: i64; flags: i32;
                           out ppBlob: Psqlite3_blob): i32;
begin
  ppBlob := nil;
  { vdbeblob.c:139..148 — the SQLITE_ENABLE_API_ARMOR misuse guard
    (sqlite3SafetyCheckOk(db) || zTable==0 || zColumn==0) is applied inside
    gBlobOpenImpl (codegen), where sqlite3SafetyCheckOk is reachable. }
  if (db = nil) or (zTable = nil) or (zColumn = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if Assigned(gBlobOpenImpl) then
    Result := gBlobOpenImpl(db, zDb, zTable, zColumn, iRow, flags, ppBlob)
  else
    Result := SQLITE_ERROR;
end;

function sqlite3_blob_close(pBlob: Psqlite3_blob): i32;
var
  pStmt: PVdbe;
  db:    PTsqlite3;
begin
  if pBlob = nil then begin Result := SQLITE_OK; Exit; end;
  pStmt := pBlob^.pStmt;
  db    := pBlob^.db;
  sqlite3DbFree(db, pBlob);
  Result := sqlite3_finalize(pStmt);
end;

{ vdbeblob.c:381..466 — blobReadWrite.  Shared helper for blob_read and
  blob_write.  xCall is either sqlite3BtreePayloadChecked (read) or
  sqlite3BtreePutData (write).  Faithful port: takes the db mutex, brackets
  the b-tree cursor access, and on SQLITE_ABORT finalises the held
  statement so the handle is permanently invalidated.  The
  SQLITE_ENABLE_PREUPDATE_HOOK arm is omitted (not compiled in this build;
  preupdate engine is a separate task). }
type
  TBlobRWCall = function(pCur: PBtCursor; offset: u32; amt: u32;
                         pBuf: Pointer): i32;

function blobReadWrite(pBlob: Psqlite3_blob; z: Pointer; n: i32;
                       iOffset: i32; xCall: TBlobRWCall): i32;
var
  p:  PIncrblob;
  v:  PVdbe;
  db: PTsqlite3;
  rc: i32;
begin
  p := pBlob;
  if p = nil then begin Result := SQLITE_MISUSE; Exit; end;
  db := p^.db;
  sqlite3_mutex_enter(db^.mutex);
  v := p^.pStmt;

  if (n < 0) or (iOffset < 0) or
     (i64(iOffset) + i64(n) > p^.nByte) then
    { Request is out of range.  Return a transient error. }
    rc := SQLITE_ERROR
  else if v = nil then
    { No statement handle — the blob handle has been invalidated. }
    rc := SQLITE_ABORT
  else begin
    sqlite3BtreeEnterCursor(p^.pCsr);
    rc := xCall(p^.pCsr, u32(iOffset + p^.iOffset), u32(n), z);
    sqlite3BtreeLeaveCursor(p^.pCsr);
    if rc = SQLITE_ABORT then begin
      sqlite3VdbeFinalize(v);
      p^.pStmt := nil;
    end else
      v^.rc := rc;
  end;

  db^.errCode := rc;
  rc := sqlite3ApiExit(db, rc);
  sqlite3_mutex_leave(db^.mutex);
  Result := rc;
end;

function sqlite3_blob_read(pBlob: Psqlite3_blob; z: Pointer;
                           n: i32; iOffset: i32): i32;
begin
  Result := blobReadWrite(pBlob, z, n, iOffset, @sqlite3BtreePayloadChecked);
end;

function sqlite3_blob_write(pBlob: Psqlite3_blob; z: Pointer;
                            n: i32; iOffset: i32): i32;
begin
  Result := blobReadWrite(pBlob, z, n, iOffset, @sqlite3BtreePutData);
end;

function sqlite3_blob_bytes(pBlob: Psqlite3_blob): i32;
begin
  if (pBlob = nil) or (pBlob^.pStmt = nil) then begin Result := 0; Exit; end;
  Result := pBlob^.nByte;
end;

function sqlite3_blob_reopen(pBlob: Psqlite3_blob; iRow: i64): i32;
begin
  if pBlob = nil then begin Result := SQLITE_MISUSE; Exit; end;
  if pBlob^.pStmt = nil then begin Result := SQLITE_ABORT; Exit; end;
  if Assigned(gBlobReopenImpl) then
    Result := gBlobReopenImpl(pBlob, iRow)
  else
    Result := SQLITE_ERROR;
end;

{ ============================================================================
  Phase 5.8 — vdbetrace.c EXPLAIN SQL expander

  Faithful port of sqlite3VdbeExpandSql (vdbetrace.c:72..190).  Expands bound
  ?, ?N, :name, $name, @name parameters into their current bindings as SQL
  literals, suitable for tracing.  Requires sqlite3GetToken (parser); wired
  via gGetTokenImpl to avoid a uses-cycle.

  Notes vs. C:
   * UTF-16 → UTF-8 conversion of bound text values is omitted; the trace
     shows the raw bytes (we already call vdbeMemRenderNum-aware codecs
     elsewhere, and tracing is debug-only).
   * SQLITE_TRACE_SIZE_LIMIT is not defined in our build, so no truncation.
  ============================================================================ }

const
  TK_VARIABLE_TRACE = 157;  { matches passqlite3parser.TK_VARIABLE }

function findNextHostParameter(zSql: PAnsiChar; pnToken: Pi64): i64;
var
  ttype: i32;
  nTotal, n: i64;
begin
  pnToken^ := 0;
  nTotal := 0;
  if not Assigned(gGetTokenImpl) then
  begin
    { Tokenizer not yet wired (e.g. test programs that don't pull parser in):
      no host parameters — caller copies the rest verbatim. }
    while zSql[nTotal] <> #0 do Inc(nTotal);
    Result := nTotal;
    Exit;
  end;
  while zSql^ <> #0 do begin
    n := gGetTokenImpl(PByte(zSql), @ttype);
    if n <= 0 then Break;
    if ttype = TK_VARIABLE_TRACE then begin
      pnToken^ := n;
      Break;
    end;
    Inc(nTotal, n);
    Inc(zSql, n);
  end;
  Result := nTotal;
end;

function sqlite3VdbeExpandSql(p: PVdbe; zRawSql: PAnsiChar): PAnsiChar;
var
  out_:       PSqlite3Str;
  db:         PTsqlite3;
  idx:        i32;
  nextIndex:  i32;
  n, nToken:  i64;
  i:          i32;
  pVar:       PMem;
  zStart:     PAnsiChar;
  enc:        u8;
  utf8:       TMem;
begin
  Result := nil;
  if (p = nil) or (zRawSql = nil) then Exit;
  db   := PTsqlite3(p^.db);
  out_ := sqlite3_str_new(Psqlite3db(db));
  if out_ = nil then Exit;

  idx       := 0;
  nextIndex := 1;

  if db^.nVdbeExec > 1 then begin
    { Re-entrant call (e.g. trigger fire): prefix every line with "-- ". }
    while zRawSql^ <> #0 do begin
      zStart := zRawSql;
      while (zRawSql^ <> #0) and (zRawSql^ <> #10) do Inc(zRawSql);
      if zRawSql^ = #10 then Inc(zRawSql);
      sqlite3_str_append(out_, '-- ', 3);
      sqlite3_str_append(out_, zStart, i32(zRawSql - zStart));
    end;
  end else if p^.nVar = 0 then begin
    sqlite3_str_append(out_, zRawSql, sqlite3Strlen30(zRawSql));
  end else begin
    while zRawSql[0] <> #0 do begin
      n := findNextHostParameter(zRawSql, @nToken);
      sqlite3_str_append(out_, zRawSql, i32(n));
      Inc(zRawSql, n);
      if nToken = 0 then Break;
      if zRawSql[0] = '?' then begin
        if nToken > 1 then sqlite3GetInt32(zRawSql + 1, @idx)
        else                 idx := nextIndex;
      end else begin
        idx := sqlite3VdbeParameterIndex(p, zRawSql, i32(nToken));
      end;
      Inc(zRawSql, nToken);
      if idx + 1 > nextIndex then nextIndex := idx + 1;
      if (idx <= 0) or (idx > p^.nVar) then Continue;
      pVar := p^.aVar + (idx - 1);
      if (pVar^.flags and MEM_Null) <> 0 then
        sqlite3_str_append(out_, 'NULL', 4)
      else if (pVar^.flags and (MEM_Int or MEM_IntReal)) <> 0 then
        sqlite3_str_appendf(out_, '%lld', [pVar^.u.i])
      else if (pVar^.flags and MEM_Real) <> 0 then
        sqlite3_str_appendf(out_, '%!.15g', [pVar^.u.r])
      else if (pVar^.flags and MEM_Str) <> 0 then begin
        { vdbetrace.c:137..148 — convert UTF-16 bound text to UTF-8 for
          display before formatting it as a quoted literal. }
        enc := db^.enc;
        if enc <> SQLITE_UTF8 then begin
          FillChar(utf8, SizeOf(utf8), 0);
          utf8.db := Psqlite3(db);
          sqlite3VdbeMemSetStr(@utf8, pVar^.z, pVar^.n, enc, SQLITE_STATIC);
          if sqlite3VdbeChangeEncoding(@utf8, SQLITE_UTF8) = SQLITE_NOMEM then begin
            out_^.accError := SQLITE_NOMEM;
            out_^.nAlloc   := 0;
          end;
          pVar := @utf8;
        end;
        sqlite3_str_appendf(out_, '''%.*q''', [pVar^.n, pVar^.z]);
        if enc <> SQLITE_UTF8 then sqlite3VdbeMemRelease(@utf8);
      end else if (pVar^.flags and MEM_Zero) <> 0 then
        sqlite3_str_appendf(out_, 'zeroblob(%d)', [pVar^.u.nZero])
      else begin
        { BLOB }
        sqlite3_str_append(out_, 'x''', 2);
        for i := 0 to pVar^.n - 1 do
          sqlite3_str_appendf(out_, '%02x', [Byte(pVar^.z[i])]);
        sqlite3_str_append(out_, '''', 1);
      end;
    end;
  end;
  if out_^.accError <> 0 then sqlite3_str_reset(out_);
  Result := sqlite3_str_finish(out_);
  { sqlite3_str_finish returns nil when nothing was appended; the C
    sqlite3StrAccumFinish always returns a non-nil heap buffer (possibly
    "" for empty input).  Mirror that. }
  if Result = nil then begin
    Result := PAnsiChar(sqlite3DbMallocZero(db, 1));
  end;
end;

{ ============================================================================
  Phase 5.9 — vdbevtab.c bytecode virtual-table initialiser

  In a build without SQLITE_ENABLE_BYTECODE_VTAB (which is the default and
  our target configuration), sqlite3VdbeBytecodeVtabInit is a no-op that
  returns SQLITE_OK.  The full bytecode()/tables_used() vtab modules require
  the vtab framework (Phase 6.bis).
  ============================================================================ }

function sqlite3VdbeBytecodeVtabInit(db: PTsqlite3): i32;
begin
  {$WARN 5024 OFF}
  Result := SQLITE_OK;
  {$WARN 5024 ON}
end;

{ ============================================================================
  Phase 5.7 — vdbesort.c external sorter (in-memory engine C-faithful;
  PMA disk-spill compiled but not yet triggered — see SORTER_PMA_ENABLED).

  Phase 5.7.b.5 replaced the bespoke array-mergesort with C's real
  bottom-up linked-list merge engine (vdbeSorterMerge / vdbeSorterSort /
  vdbeSorterGetCompare / the vdbeSorterCompare* family operating on
  SRVAL/nVal with typeMask Int/Text fast paths) and the C-exact
  sqlite3VdbeSorterInit / Write / Rewind / Next / Rowkey / Compare.  The
  write-side PMA path (vdbeSorterListToPMA / vdbeSorterFlushPMA) is fully
  ported and compiled, but the spill TRIGGER in sqlite3VdbeSorterWrite is
  GATED OFF behind the module const SORTER_PMA_ENABLED=False (see below).
  With the gate off, every sort stays in RAM exactly as before — the
  read-back merge machinery (MergeEngine / IncrMerger / Rewind-merge)
  lands in 5.7.b.6..b.9, and 5.7.b.9 flips SORTER_PMA_ENABLED to True.
  ============================================================================ }

const
  { ----------------------------------------------------------------------
    SORTER_PMA_ENABLED — 5.7.b.5 spill-trigger gate.

    C's sqlite3VdbeSorterWrite flushes the in-memory list to an on-disk
    PMA (vdbesort.c:1849..1854) whenever memory fills.  The PMA write side
    (vdbeSorterListToPMA / vdbeSorterFlushPMA / PmaWriter) is ported and
    compiled, BUT the read-back side (MergeEngine / IncrMerger and the
    PMA arms of Rewind/Next/Rowkey/Compare) does NOT exist until
    5.7.b.6..b.9.  If we let the flush fire now, a sort that spills would
    discard everything but the final PMA at Rewind — silent data loss.

    Therefore the spill block is kept fully faithful (bFlush computation,
    szPMA/iMemory reset) but the actual vdbeSorterFlushPMA() call is
    guarded by this const.  With it False the behaviour is identical to
    the pre-5.7.b in-memory sorter (no spill, no data loss, gate green).

    *** 5.7.b.9 MUST flip this to True AND verify the merge read-back. ***
    ---------------------------------------------------------------------- }
  SORTER_PMA_ENABLED = True;   { 5.7.b.9: spill + merge read-back enabled }

{ SRVAL(p) — vdbesort.c:461 — record data immediately follows the header. }
function SRVAL(p: PSorterRecord): Pointer; inline;
begin
  Result := PByte(p) + SZ_SORTER_RECORD;
end;

{ ============================================================================
  Temp-file plumbing — vdbesort.c:619..634, 1308..1352  (tasklist 5.7.b.2)

  MMAP PATH: this port treats SQLITE_MAX_MMAP_SIZE as 0 (see passqlite3os.pas
  ~line 47 — no mmap paths are ported in the OS layer).  That is exactly the
  SQLITE_MAX_MMAP_SIZE==0 configuration of these same C functions, NOT a
  deviation:
    * vdbeSorterMapFile sets pp:=nil (no mapping → callers fall back to
      buffered reads, byte-identical results).  Faithfully it still calls
      sqlite3OsFetch, which in this port returns pp:=nil + SQLITE_OK whenever
      the VFS exposes no xFetch (passqlite3os.pas:1250), so the mapped vs
      unmapped behaviour is identical here.
    * vdbeSorterExtendFile still issues the CHUNK_SIZE / SIZE_HINT hints to
      truncate/extend the file, but skips the OsFetch pre-fault (the prefault
      only matters when a real mmap is active).
    * vdbeSorterOpenTempFile skips the SQLITE_FCNTL_MMAP_SIZE control (it has
      no effect with mmap disabled).
  ============================================================================ }

{ vdbesort.c:1308..1326 — extend/truncate temp file pFd to nByte.  Gated
  #if SQLITE_MAX_MMAP_SIZE>0 in C; here SQLITE_MAX_MMAP_SIZE==0, so we keep
  the truncate/extend hints (db->nMaxSorterMmap is 0 by default, so this is a
  no-op unless PRAGMA/limit raised it) and omit the OsFetch/OsUnfetch
  pre-fault. }
procedure vdbeSorterExtendFile(db: PTsqlite3; pFd: Psqlite3_file; nByte: i64);
var
  chunksize: i32;
begin
  if (nByte <= i64(db^.nMaxSorterMmap)) and (pFd^.pMethods^.iVersion >= 3) then
  begin
    chunksize := 4 * 1024;
    sqlite3OsFileControlHint(pFd, SQLITE_FCNTL_CHUNK_SIZE, @chunksize);
    sqlite3OsFileControlHint(pFd, SQLITE_FCNTL_SIZE_HINT, @nByte);
    { mmap disabled (SQLITE_MAX_MMAP_SIZE==0): skip the OsFetch/OsUnfetch
      pre-fault that the SQLITE_MAX_MMAP_SIZE>0 body performs here. }
  end;
end;

{ vdbesort.c:1327..1352 — allocate a file-handle and open a temp file.  On
  success set ppFd^ and return SQLITE_OK; otherwise set ppFd^:=nil and return
  an error code.  This port lacks sqlite3OsOpenMalloc, so its faithful body
  (os.c:308 — MallocZero(szOsFile) + OsOpen + free-on-error) is inlined. }
function vdbeSorterOpenTempFile(db: PTsqlite3; nExtend: i64;
                               ppFd: PPsqlite3_file): i32;
var
  rc: i32;
  pFile: Psqlite3_file;
  pVfs: Psqlite3_vfs;
begin
  if sqlite3FaultSim(202) <> 0 then begin Result := SQLITE_IOERR_ACCESS; Exit; end;

  pVfs := Psqlite3_vfs(db^.pVfs);
  { inlined sqlite3OsOpenMalloc (os.c:308) }
  pFile := Psqlite3_file(sqlite3MallocZero(csize_t(pVfs^.szOsFile)));
  if pFile = nil then begin
    ppFd^ := nil;
    Result := SQLITE_NOMEM_BKPT;
    Exit;
  end;
  rc := sqlite3OsOpen(pVfs, nil, pFile,
      SQLITE_OPEN_TEMP_JOURNAL or
      SQLITE_OPEN_READWRITE    or SQLITE_OPEN_CREATE or
      SQLITE_OPEN_EXCLUSIVE    or SQLITE_OPEN_DELETEONCLOSE, nil);
  if rc <> SQLITE_OK then begin
    sqlite3_free(pFile);
    ppFd^ := nil;
  end else
    ppFd^ := pFile;

  if rc = SQLITE_OK then begin
    { mmap disabled (SQLITE_MAX_MMAP_SIZE==0): skip the SQLITE_FCNTL_MMAP_SIZE
      control the C body issues here. }
    if nExtend > 0 then
      vdbeSorterExtendFile(db, ppFd^, nExtend);
  end;
  Result := rc;
end;

{ vdbesort.c:619..634 — attempt to memory-map SorterFile pFile.  If not
  attempted (file too large, or VFS not configured for mmap) return SQLITE_OK
  with pp^:=nil.  Here mmap is disabled, so sqlite3OsFetch returns pp^:=nil. }
function vdbeSorterMapFile(pTask: PSortSubtask; pFile: PSorterFile;
                          pp: PPByte): i32;
var
  rc: i32;
  pFd: Psqlite3_file;
begin
  rc := SQLITE_OK;
  if pFile^.iEof <= i64(pTask^.pSorter^.db^.nMaxSorterMmap) then begin
    pFd := pFile^.pFd;
    if pFd^.pMethods^.iVersion >= 3 then
      rc := sqlite3OsFetch(pFd, 0, i32(pFile^.iEof), PPointer(pp));
  end;
  Result := rc;
end;

{ ============================================================================
  PmaWriter — incremental, buffered, page-aligned PMA writer.
  vdbesort.c:1479..1576  (tasklist 5.7.b.3)

  Single-threaded only.  Reuses sqlite3Malloc/sqlite3_free for aBuffer (as C),
  sqlite3OsWrite(id,pBuf,amt,offset) for flushes, sqlite3PutVarint for varints.
  Not yet wired into production paths (that lands in 5.7.b.5).
  ============================================================================ }

{ vdbePmaWriterInit — vdbesort.c:1479..1500 }
procedure vdbePmaWriterInit(pFd: Psqlite3_file; p: PPmaWriter;
                            nBuf: i32; iStart: i64);
begin
  FillChar(p^, SizeOf(TPmaWriter), 0);
  p^.aBuffer := Pu8(sqlite3Malloc(nBuf));
  if p^.aBuffer = nil then begin
    p^.eFWErr := SQLITE_NOMEM_BKPT;
  end else begin
    p^.iBufStart := i32(iStart mod nBuf);
    p^.iBufEnd   := p^.iBufStart;
    p^.iWriteOff := iStart - p^.iBufStart;
    p^.nBuffer   := nBuf;
    p^.pFd       := pFd;
  end;
end;

{ vdbePmaWriteBlob — vdbesort.c:1501..1535 }
procedure vdbePmaWriteBlob(p: PPmaWriter; pData: Pu8; nData: i32);
var
  nRem, nCopy: i32;
begin
  nRem := nData;
  while (nRem > 0) and (p^.eFWErr = 0) do begin
    nCopy := nRem;
    if nCopy > (p^.nBuffer - p^.iBufEnd) then
      nCopy := p^.nBuffer - p^.iBufEnd;

    Move((pData + (nData - nRem))^, (p^.aBuffer + p^.iBufEnd)^, nCopy);
    Inc(p^.iBufEnd, nCopy);
    if p^.iBufEnd = p^.nBuffer then begin
      p^.eFWErr := sqlite3OsWrite(p^.pFd,
          p^.aBuffer + p^.iBufStart, p^.iBufEnd - p^.iBufStart,
          p^.iWriteOff + p^.iBufStart);
      Inc(p^.nPmaSpill, u64(p^.iBufEnd - p^.iBufStart));
      p^.iBufStart := 0;
      p^.iBufEnd   := 0;
      Inc(p^.iWriteOff, p^.nBuffer);
    end;
    Assert(p^.iBufEnd < p^.nBuffer);

    Dec(nRem, nCopy);
  end;
end;

{ vdbePmaWriterFinish — vdbesort.c:1536..1556 }
function vdbePmaWriterFinish(p: PPmaWriter; piEof: Pi64; pnSpill: Pu64): i32;
var
  rc: i32;
begin
  if (p^.eFWErr = 0) and (p^.aBuffer <> nil) and (p^.iBufEnd > p^.iBufStart) then
  begin
    p^.eFWErr := sqlite3OsWrite(p^.pFd,
        p^.aBuffer + p^.iBufStart, p^.iBufEnd - p^.iBufStart,
        p^.iWriteOff + p^.iBufStart);
    Inc(p^.nPmaSpill, u64(p^.iBufEnd - p^.iBufStart));
  end;
  piEof^ := p^.iWriteOff + p^.iBufEnd;
  Inc(pnSpill^, p^.nPmaSpill);
  sqlite3_free(p^.aBuffer);
  rc := p^.eFWErr;
  FillChar(p^, SizeOf(TPmaWriter), 0);
  Result := rc;
end;

{ vdbePmaWriteVarint — vdbesort.c:1557..1576 }
procedure vdbePmaWriteVarint(p: PPmaWriter; iVal: u64);
var
  nByte: i32;
  aByte: array[0..9] of u8;
begin
  nByte := sqlite3PutVarint(@aByte[0], iVal);
  vdbePmaWriteBlob(p, @aByte[0], nByte);
end;

{ ============================================================================
  PmaReader — incrementally read one PMA in sorted order.
  vdbesort.c:474..761  (tasklist 5.7.b.4)

  Single-threaded only.  Reuses sqlite3OsRead(id,pBuf,amt,offset),
  sqlite3Realloc(p,n), sqlite3Malloc/sqlite3_free, sqlite3GetVarint and the
  already-ported vdbeSorterMapFile.  Not yet wired into production
  (5.7.b.6/.8/.9 do that).

  IncrMerger: vdbeIncrFree/vdbeIncrSwap referenced below are forward-declared
  here; their real single-threaded bodies (5.7.b.7) appear after the
  PmaReader/MergeEngine helpers they depend on.
  ============================================================================ }

{ Forward declarations — real single-threaded IncrMerger bodies in 5.7.b.7. }
procedure vdbeIncrFree(pIncr: PIncrMerger); forward;
function  vdbeIncrSwap(pIncr: PIncrMerger): i32; forward;
function  vdbeIncrPopulate(pIncr: PIncrMerger): i32; forward;
procedure vdbeMergeEngineFree(pMerger: PMergeEngine); forward;

{ vdbePmaReaderClear — vdbesort.c:474..480 }
procedure vdbePmaReaderClear(pReadr: PPmaReader);
begin
  sqlite3_free(pReadr^.aAlloc);
  sqlite3_free(pReadr^.aBuffer);
  if pReadr^.aMap <> nil then sqlite3OsUnfetch(pReadr^.pFd, 0, pReadr^.aMap);
  vdbeIncrFree(pReadr^.pIncr);
  FillChar(pReadr^, SizeOf(TPmaReader), 0);
end;

{ vdbePmaReadBlob — vdbesort.c:491..585.  Read nByte from the PMA, set ppOut^
  to a buffer holding the data (a pointer into aMap/aBuffer, or a copy in the
  grown aAlloc).  The buffer is valid only until the next call. }
function vdbePmaReadBlob(p: PPmaReader; nByte: i32; ppOut: PPByte): i32;
var
  iBuf:   i32;   { offset within buffer to read from }
  nAvail: i32;   { bytes of data available in buffer }
  nRead:  i32;   { bytes to read from disk }
  rc:     i32;   { sqlite3OsRead() return code }
  nRem:   i32;   { bytes remaining to copy }
  nCopy:  i32;   { number of bytes to copy }
  aNext:  Pu8;   { pointer to buffer to copy data from }
  aNew:   Pu8;
  nNew:   i64;
begin
  if p^.aMap <> nil then begin
    ppOut^ := @p^.aMap[p^.iReadOff];
    Inc(p^.iReadOff, nByte);
    Result := SQLITE_OK;
    Exit;
  end;

  Assert(p^.aBuffer <> nil);

  { If there is no more data to be read from the buffer, read the next
    p->nBuffer bytes of data from the file into it. Or, if there are less
    than p->nBuffer bytes remaining in the PMA, read all remaining data.  }
  iBuf := i32(p^.iReadOff mod p^.nBuffer);
  if iBuf = 0 then begin
    { Determine how many bytes of data to read. }
    if (p^.iEof - p^.iReadOff) > i64(p^.nBuffer) then
      nRead := p^.nBuffer
    else
      nRead := i32(p^.iEof - p^.iReadOff);
    Assert(nRead > 0);

    { Read data from the file. Return early if an error occurs. }
    rc := sqlite3OsRead(p^.pFd, p^.aBuffer, nRead, p^.iReadOff);
    Assert(rc <> SQLITE_IOERR_SHORT_READ);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;
  nAvail := p^.nBuffer - iBuf;

  if nByte <= nAvail then begin
    { The requested data is available in the in-memory buffer.  Return a
      pointer into the buffer rather than copying. }
    ppOut^ := @p^.aBuffer[iBuf];
    Inc(p^.iReadOff, nByte);
  end else begin
    { The requested data is not all available in the in-memory buffer.
      Allocate space at p->aAlloc[] to copy the requested range into, then
      return a copy of pointer p->aAlloc to the caller. }

    { Extend the p->aAlloc[] allocation if required. }
    if p^.nAlloc < nByte then begin
      nNew := 2 * i64(p^.nAlloc);          { MAX(128, 2*nAlloc) — vdbesort.c:556 }
      if nNew < 128 then nNew := 128;
      while nByte > nNew do nNew := nNew * 2;
      aNew := Pu8(sqlite3Realloc(p^.aAlloc, u64(nNew)));
      if aNew = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
      p^.nAlloc := i32(nNew);
      p^.aAlloc := aNew;
    end;

    { Copy as much data as is available in the buffer into the start of
      p->aAlloc[]. }
    Move(p^.aBuffer[iBuf], p^.aAlloc^, nAvail);
    Inc(p^.iReadOff, nAvail);
    nRem := nByte - nAvail;

    { The following loop copies up to p->nBuffer bytes per iteration into
      the p->aAlloc[] buffer. }
    while nRem > 0 do begin
      aNext := nil;
      nCopy := nRem;
      if nRem > p^.nBuffer then nCopy := p^.nBuffer;
      rc := vdbePmaReadBlob(p, nCopy, @aNext);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      Assert(aNext <> p^.aAlloc);
      Assert(aNext <> nil);
      Move(aNext^, p^.aAlloc[nByte - nRem], nCopy);
      Dec(nRem, nCopy);
    end;

    ppOut^ := p^.aAlloc;
  end;

  Result := SQLITE_OK;
end;

{ vdbePmaReadVarint — vdbesort.c:586..618.  Read a varint from the stream,
  set pnOut^ to the value. }
function vdbePmaReadVarint(p: PPmaReader; pnOut: Pu64): i32;
var
  iBuf:    i32;
  aVarint: array[0..15] of u8;
  a:       Pu8;
  i, rc:   i32;
  v:       u64;
begin
  if p^.aMap <> nil then begin
    Inc(p^.iReadOff, sqlite3GetVarint(@p^.aMap[p^.iReadOff], pnOut^));
  end else begin
    iBuf := i32(p^.iReadOff mod p^.nBuffer);
    if (iBuf <> 0) and ((p^.nBuffer - iBuf) >= 9) then begin
      Inc(p^.iReadOff, sqlite3GetVarint(@p^.aBuffer[iBuf], pnOut^));
    end else begin
      i := 0;
      a := nil;
      repeat
        rc := vdbePmaReadBlob(p, 1, @a);
        if rc <> 0 then begin Result := rc; Exit; end;
        aVarint[(i) and $f] := a[0];
        Inc(i);
      until (a[0] and $80) = 0;
      sqlite3GetVarint(@aVarint[0], v);
      pnOut^ := v;
    end;
  end;

  Result := SQLITE_OK;
end;

{ vdbePmaReaderSeek — vdbesort.c:636..682.  Attach pReadr to pFile and seek it
  to offset iOff. }
function vdbePmaReaderSeek(pTask: PSortSubtask; pReadr: PPmaReader;
                          pFile: PSorterFile; iOff: i64): i32;
var
  rc:    i32;
  pgsz:  i32;
  iBuf:  i32;
  nRead: i32;
begin
  rc := SQLITE_OK;

  Assert((pReadr^.pIncr = nil) or (pReadr^.pIncr^.bEof = 0));

  if sqlite3FaultSim(201) <> 0 then begin Result := SQLITE_IOERR_READ; Exit; end;
  if pReadr^.aMap <> nil then begin
    sqlite3OsUnfetch(pReadr^.pFd, 0, pReadr^.aMap);
    pReadr^.aMap := nil;
  end;
  pReadr^.iReadOff := iOff;
  pReadr^.iEof     := pFile^.iEof;
  pReadr^.pFd      := pFile^.pFd;

  rc := vdbeSorterMapFile(pTask, pFile, @pReadr^.aMap);
  if (rc = SQLITE_OK) and (pReadr^.aMap = nil) then begin
    pgsz := pTask^.pSorter^.pgsz;
    iBuf := i32(pReadr^.iReadOff mod pgsz);
    if pReadr^.aBuffer = nil then begin
      pReadr^.aBuffer := Pu8(sqlite3Malloc(pgsz));
      if pReadr^.aBuffer = nil then rc := SQLITE_NOMEM_BKPT;
      pReadr^.nBuffer := pgsz;
    end;
    if (rc = SQLITE_OK) and (iBuf <> 0) then begin
      nRead := pgsz - iBuf;
      if (pReadr^.iReadOff + nRead) > pReadr^.iEof then
        nRead := i32(pReadr^.iEof - pReadr^.iReadOff);
      rc := sqlite3OsRead(pReadr^.pFd, @pReadr^.aBuffer[iBuf], nRead,
                          pReadr^.iReadOff);
    end;
  end;

  Result := rc;
end;

{ vdbePmaReaderNext — vdbesort.c:683..729.  Advance pReadr to the next key. }
function vdbePmaReaderNext(pReadr: PPmaReader): i32;
var
  rc:    i32;
  nRec:  u64;
  bEof:  i32;
  pIncr: PIncrMerger;
begin
  rc   := SQLITE_OK;
  nRec := 0;

  if pReadr^.iReadOff >= pReadr^.iEof then begin
    pIncr := pReadr^.pIncr;
    bEof := 1;
    if pIncr <> nil then begin
      rc := vdbeIncrSwap(pIncr);
      if (rc = SQLITE_OK) and (pIncr^.bEof = 0) then begin
        rc := vdbePmaReaderSeek(pIncr^.pTask, pReadr, @pIncr^.aFile[0],
                                pIncr^.iStartOff);
        bEof := 0;
      end;
    end;

    if bEof <> 0 then begin
      { This is an EOF condition }
      vdbePmaReaderClear(pReadr);
      Result := rc;
      Exit;
    end;
  end;

  if rc = SQLITE_OK then
    rc := vdbePmaReadVarint(pReadr, @nRec);
  if rc = SQLITE_OK then begin
    pReadr^.nKey := i32(nRec);
    rc := vdbePmaReadBlob(pReadr, i32(nRec), @pReadr^.aKey);
  end;

  Result := rc;
end;

{ vdbePmaReaderInit — vdbesort.c:730..761.  Initialise pReadr to scan the PMA
  in pFile starting at iStart.  If pnByte is nil the PMA omits its initial
  length varint. }
function vdbePmaReaderInit(pTask: PSortSubtask; pFile: PSorterFile;
                          iStart: i64; pReadr: PPmaReader; pnByte: Pi64): i32;
var
  rc:    i32;
  nByte: u64;
begin
  Assert(pFile^.iEof > iStart);
  Assert((pReadr^.aAlloc = nil) and (pReadr^.nAlloc = 0));
  Assert(pReadr^.aBuffer = nil);
  Assert(pReadr^.aMap = nil);

  rc := vdbePmaReaderSeek(pTask, pReadr, pFile, iStart);
  if rc = SQLITE_OK then begin
    nByte := 0;
    rc := vdbePmaReadVarint(pReadr, @nByte);
    pReadr^.iEof := pReadr^.iReadOff + i64(nByte);
    Inc(pnByte^, i64(nByte));
  end;

  if rc = SQLITE_OK then
    rc := vdbePmaReaderNext(pReadr);
  Result := rc;
end;

{ vdbeIncrFree — vdbesort.c:1229..1241.  Free the IncrMerger's MergeEngine and
  the struct itself.  The threaded aFile[0]/aFile[1] teardown is gated
  #if SQLITE_MAX_WORKER_THREADS>0 in C and omitted here: a single-threaded
  IncrMerger does not own its temp files (it borrows a region of
  pTask->file2), so there is nothing to close. }
procedure vdbeIncrFree(pIncr: PIncrMerger);
begin
  if pIncr <> nil then begin
    vdbeMergeEngineFree(pIncr^.pMerger);
    sqlite3_free(pIncr);
  end;
end;

{ vdbeIncrSwap — vdbesort.c:1985..2023, single-threaded (#else) arm only.
  Called when the PmaReader has finished reading aFile[0]; "refills" the
  region by literally reading keys from pIncr->pMerger via vdbeIncrPopulate,
  copies aFile[1] (the just-written region) onto aFile[0], and flags EOF when
  the population produced no new bytes (iEof back at iStartOff).  The
  SQLITE_MAX_WORKER_THREADS>0 thread-join/file-swap arm is omitted. }
function vdbeIncrSwap(pIncr: PIncrMerger): i32;
var
  rc: i32;
begin
  rc := vdbeIncrPopulate(pIncr);
  pIncr^.aFile[0] := pIncr^.aFile[1];
  if pIncr^.aFile[0].iEof = pIncr^.iStartOff then
    pIncr^.bEof := 1;
  Result := rc;
end;

{ ----------------------------------------------------------------------------
  Phase 5.7.b.6 — MergeEngine (the aTree[] loser/winner tournament that
  combines up to SORTER_MAX_MERGE_COUNT PmaReaders).  Ports vdbeMergeEngineNew/
  Free/Compare/Step/Init/Level0 from vdbesort.c.  Single-threaded only:
  the SQLITE_MAX_WORKER_THREADS>0 and INCRINIT_TASK/ROOT arms are omitted.
  Not yet wired into production (5.7.b.8/.9 do that).
  ---------------------------------------------------------------------------- }

{ Forward declaration — real single-threaded body is in the 5.7.b.7 block
  (vdbesort.c:2220..2280); vdbeMergeEngineInit calls it for each reader. }
function vdbePmaReaderIncrMergeInit(pReadr: PPmaReader; eMode: i32): i32; forward;
function vdbePmaReaderIncrInit(pReadr: PPmaReader; eMode: i32): i32; forward;

{ vdbeMergeEngineNew — vdbesort.c:1193..1215.  Allocate a MergeEngine able to
  merge up to nReader inputs.  nReader is rounded up to the next power of two
  (N), and a single allocation holds the MergeEngine header followed by the
  aReadr[N] PmaReader array and the aTree[N] int array. }
function vdbeMergeEngineNew(nReader: i32): PMergeEngine;
var
  N:     i32;     { smallest power of two >= nReader }
  nByte: i64;     { total bytes of space to allocate }
  pNew:  PMergeEngine;
begin
  N := 2;
  Assert(nReader <= SORTER_MAX_MERGE_COUNT);

  while N < nReader do N := N + N;
  nByte := SizeOf(TMergeEngine) + i64(N) * (SizeOf(i32) + SizeOf(TPmaReader));

  if sqlite3FaultSim(100) <> 0 then
    pNew := nil
  else
    pNew := PMergeEngine(sqlite3MallocZero(csize_t(nByte)));
  if pNew <> nil then begin
    pNew^.nTree  := N;
    pNew^.pTask  := nil;
    { aReadr = &pNew[1] (the PmaReader array immediately follows the header);
      aTree = &aReadr[N] (the int array immediately follows that). }
    pNew^.aReadr := PPmaReader(PByte(pNew) + SizeOf(TMergeEngine));
    pNew^.aTree  := Pi32(PByte(pNew^.aReadr) + i64(N) * SizeOf(TPmaReader));
  end;
  Result := pNew;
end;

{ vdbeMergeEngineFree — vdbesort.c:1216..1229.  Clear each PmaReader, then
  free the single MergeEngine allocation. }
procedure vdbeMergeEngineFree(pMerger: PMergeEngine);
var
  i: i32;
begin
  if pMerger <> nil then begin
    for i := 0 to pMerger^.nTree - 1 do
      vdbePmaReaderClear(@pMerger^.aReadr[i]);
  end;
  sqlite3_free(pMerger);
end;

{ vdbeMergeEngineCompare — vdbesort.c:2062..2114.  Recompute aTree[iOut] by
  comparing the next keys on the two PmaReaders feeding that entry.  Neither
  reader is advanced.  EOF reader is "greatest"; on a tie the lower-index
  (older) reader wins (res<=0 -> i1). }
procedure vdbeMergeEngineCompare(pMerger: PMergeEngine; iOut: i32);
var
  i1, i2, iRes: i32;
  p1, p2:       PPmaReader;
  pTask:        PSortSubtask;
  bCached:      i32;
  res:          i32;
begin
  Assert((iOut < pMerger^.nTree) and (iOut > 0));

  if iOut >= (pMerger^.nTree div 2) then begin
    i1 := (iOut - pMerger^.nTree div 2) * 2;
    i2 := i1 + 1;
  end else begin
    i1 := pMerger^.aTree[iOut * 2];
    i2 := pMerger^.aTree[iOut * 2 + 1];
  end;

  p1 := @pMerger^.aReadr[i1];
  p2 := @pMerger^.aReadr[i2];

  if p1^.pFd = nil then
    iRes := i2
  else if p2^.pFd = nil then
    iRes := i1
  else begin
    pTask := pMerger^.pTask;
    bCached := 0;
    Assert(pTask^.pUnpacked <> nil);  { from vdbeSortSubtaskMain() }
    res := pTask^.xCompare(pTask, @bCached,
        p1^.aKey, p1^.nKey, p2^.aKey, p2^.nKey);
    if res <= 0 then iRes := i1
    else             iRes := i2;
  end;

  pMerger^.aTree[iOut] := iRes;
end;

{ vdbeMergeEngineStep — vdbesort.c:1642..1712.  Advance the current winner
  (aTree[1]) one key, then walk UP the tree recomputing comparisons.  The C
  pReadr1/pReadr2 pointers and the `pReadr1 - aReadr` index math / `pReadr1 <
  pReadr2` tie rule are reproduced here via integer element indices into
  aReadr[] (iReadr1/iReadr2), which preserves C's exact semantics. }
function vdbeMergeEngineStep(pMerger: PMergeEngine; pbEof: Pi32): i32;
var
  rc:       i32;
  iPrev:    i32;          { index of PmaReader to advance }
  pTask:    PSortSubtask;
  i:        i32;          { index of aTree[] to recalculate }
  iReadr1:  i32;          { index of first PmaReader to compare }
  iReadr2:  i32;          { index of second PmaReader to compare }
  bCached:  i32;
  iRes:     i32;
  p1, p2:   PPmaReader;
begin
  iPrev := pMerger^.aTree[1];
  pTask := pMerger^.pTask;

  { Advance the current PmaReader }
  rc := vdbePmaReaderNext(@pMerger^.aReadr[iPrev]);

  { Update contents of aTree[] }
  if rc = SQLITE_OK then begin
    bCached := 0;

    { Find the first two PmaReaders to compare. The one that was just
      advanced (iPrev) and the one next to it in the array. }
    iReadr1 := iPrev and $FFFE;
    iReadr2 := iPrev or  $0001;

    i := (pMerger^.nTree + iPrev) div 2;
    while i > 0 do begin
      { Compare the two readers. Store the result in iRes. }
      p1 := @pMerger^.aReadr[iReadr1];
      p2 := @pMerger^.aReadr[iReadr2];
      if p1^.pFd = nil then
        iRes := +1
      else if p2^.pFd = nil then
        iRes := -1
      else
        iRes := pTask^.xCompare(pTask, @bCached,
            p1^.aKey, p1^.nKey, p2^.aKey, p2^.nKey);

      { If pReadr1 contained the smaller value, set aTree[i] to its index.
        Then set pReadr2 to the next PmaReader to compare to pReadr1.

        Alternatively, if pReadr2 contains the smaller of the two values,
        set aTree[i] to its index and update pReadr1.  If the comparison
        was actually called above, then pTask->pUnpacked now contains a
        value equivalent to pReadr2, so leave bCached set to prevent it
        being decoded again.

        If the two values were equal, the value from the oldest PMA (lower
        aReadr[] index, i.e. iReadr1 < iReadr2) is considered smaller. }
      if (iRes < 0) or ((iRes = 0) and (iReadr1 < iReadr2)) then begin
        pMerger^.aTree[i] := iReadr1;
        iReadr2 := pMerger^.aTree[i xor $0001];
        bCached := 0;
      end else begin
        if p1^.pFd <> nil then bCached := 0;
        pMerger^.aTree[i] := iReadr2;
        iReadr1 := pMerger^.aTree[i xor $0001];
      end;

      i := i div 2;
    end;
    pbEof^ := Ord(pMerger^.aReadr[pMerger^.aTree[1]].pFd = nil);
  end;

  if rc = SQLITE_OK then
    Result := pTask^.pUnpacked^.errCode
  else
    Result := rc;
end;

{ vdbeMergeEngineInit — vdbesort.c:2144..2218.  Initialise every PmaReader,
  then build the initial aTree[] bottom-up.  Single-threaded: eMode is always
  INCRINIT_NORMAL, so each reader is initialised via vdbePmaReaderIncrMergeInit
  (5.7.b.7); the INCRINIT_ROOT / bg-thread arms are omitted. }
function vdbeMergeEngineInit(pTask: PSortSubtask; pMerger: PMergeEngine;
                            eMode: i32): i32;
var
  rc:    i32;
  i:     i32;
  nTree: i32;
begin
  rc := SQLITE_OK;

  { Failure to allocate the merge would have been detected before now. }
  Assert(pMerger <> nil);

  { eMode is always INCRINIT_NORMAL in single-threaded mode. }
  Assert(eMode = INCRINIT_NORMAL);

  { Verify that the MergeEngine is assigned to a single thread. }
  Assert(pMerger^.pTask = nil);
  pMerger^.pTask := pTask;

  nTree := pMerger^.nTree;
  for i := 0 to nTree - 1 do begin
    { vdbesort.c:2176 — the INCRINIT_NORMAL (else) arm calls IncrInit, which
      no-ops on a level-0 reader (pIncr=nil) and only recurses through the
      tree on incremental readers.  Calling IncrMergeInit directly would
      deref a nil pIncr on the leaf readers. }
    rc := vdbePmaReaderIncrInit(@pMerger^.aReadr[i], INCRINIT_NORMAL);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  for i := pMerger^.nTree - 1 downto 1 do
    vdbeMergeEngineCompare(pMerger, i);
  Result := pTask^.pUnpacked^.errCode;
end;

{ vdbeMergeEngineLevel0 — vdbesort.c:2338..2375.  Build a level-0 MergeEngine
  reading nPMA PMAs directly from pTask->file starting at *piOffset; advance
  *piOffset past the last PMA read. }
function vdbeMergeEngineLevel0(pTask: PSortSubtask; nPMA: i32;
                              piOffset: Pi64; ppOut: PPMergeEngine): i32;
var
  pNew:   PMergeEngine;
  iOff:   i64;
  i:      i32;
  rc:     i32;
  nDummy: i64;
  pReadr: PPmaReader;
begin
  iOff := piOffset^;
  rc := SQLITE_OK;

  pNew := vdbeMergeEngineNew(nPMA);
  ppOut^ := pNew;
  if pNew = nil then rc := SQLITE_NOMEM_BKPT;

  i := 0;
  while (i < nPMA) and (rc = SQLITE_OK) do begin
    nDummy := 0;
    pReadr := @pNew^.aReadr[i];
    rc := vdbePmaReaderInit(pTask, @pTask^.file_, iOff, pReadr, @nDummy);
    iOff := pReadr^.iEof;
    Inc(i);
  end;

  if rc <> SQLITE_OK then begin
    vdbeMergeEngineFree(pNew);
    ppOut^ := nil;
  end;
  piOffset^ := iOff;
  Result := rc;
end;

{ ----------------------------------------------------------------------------
  Phase 5.7.b.7 — single-threaded IncrMerger.  Reads keys from a wrapped
  MergeEngine and incrementally merges them into a refillable region of
  pTask->file2.  Ports vdbeIncrPopulate / vdbeIncrSwap / vdbeIncrFree /
  vdbeIncrMergerNew / vdbeIncrMergerSetThreads / vdbePmaReaderIncrMergeInit /
  vdbePmaReaderIncrInit (vdbeIncrFree/Swap bodies appear earlier, after the
  PmaReader helpers).  Single-threaded only: all SQLITE_MAX_WORKER_THREADS>0
  / INCRINIT_TASK / INCRINIT_ROOT / bg-thread arms are omitted.  In this mode
  an IncrMerger borrows a region of pTask->file2 rather than owning temp files.
  ---------------------------------------------------------------------------- }

{ vdbeIncrPopulate — vdbesort.c:1908..1942.  Read keys from pIncr->pMerger and
  populate pIncr->aFile[1].  The on-disk format matches a regular PMA except
  the leading number-of-bytes varint is omitted (vdbesort.c:1903..1906).
  Steps the merge engine, writing each winner key, until the output region is
  full (iEof+nKey+VarintLen(nKey) would exceed iStartOff+mxSz) or the input is
  exhausted (winning reader's pFd became nil). }
function vdbeIncrPopulate(pIncr: PIncrMerger): i32;
var
  rc, rc2:  i32;
  iStart:   i64;
  pOut:     PSorterFile;
  pTask:    PSortSubtask;
  pMerger:  PMergeEngine;
  writer:   TPmaWriter;
  dummy:    i32;
  pReader:  PPmaReader;
  nKey:     i32;
  iEof:     i64;
begin
  rc := SQLITE_OK;
  iStart  := pIncr^.iStartOff;
  pOut    := @pIncr^.aFile[1];
  pTask   := pIncr^.pTask;
  pMerger := pIncr^.pMerger;
  Assert(pIncr^.bEof = 0);

  vdbePmaWriterInit(pOut^.pFd, @writer, pTask^.pSorter^.pgsz, iStart);
  while rc = SQLITE_OK do begin
    pReader := @pMerger^.aReadr[pMerger^.aTree[1]];
    nKey := pReader^.nKey;
    iEof := writer.iWriteOff + writer.iBufEnd;

    { Check if the output file is full or if the input has been exhausted.
      In either case exit the loop. }
    if pReader^.pFd = nil then Break;
    if (iEof + nKey + i64(sqlite3VarintLen(u64(nKey)))) > (iStart + pIncr^.mxSz) then
      Break;

    { Write the next key to the output. }
    vdbePmaWriteVarint(@writer, u64(nKey));
    vdbePmaWriteBlob(@writer, pReader^.aKey, nKey);
    Assert(pIncr^.pMerger^.pTask = pTask);
    rc := vdbeMergeEngineStep(pIncr^.pMerger, @dummy);
  end;

  rc2 := vdbePmaWriterFinish(@writer, @pOut^.iEof, @pTask^.nSpill);
  if rc = SQLITE_OK then rc := rc2;
  Result := rc;
end;

{ vdbeIncrMergerNew — vdbesort.c:2024..2047.  Allocate an IncrMerger wrapping
  pMerger and assign it to pTask.  mxSz = MAX(mxKeysize+9, mxPmaSize/2); the
  task's file2 reservation grows by mxSz.  On OOM, free pMerger and return
  SQLITE_NOMEM_BKPT (the contract: *ppOut<>nil iff rc=SQLITE_OK). }
function vdbeIncrMergerNew(pTask: PSortSubtask; pMerger: PMergeEngine;
                          ppOut: PPIncrMerger): i32;
var
  rc:    i32;
  pIncr: PIncrMerger;
  a, b:  i32;
begin
  rc := SQLITE_OK;
  if sqlite3FaultSim(100) <> 0 then
    pIncr := nil
  else
    pIncr := PIncrMerger(sqlite3MallocZero(SizeOf(TIncrMerger)));
  ppOut^ := pIncr;
  if pIncr <> nil then begin
    pIncr^.pMerger := pMerger;
    pIncr^.pTask   := pTask;
    a := pTask^.pSorter^.mxKeysize + 9;
    b := pTask^.pSorter^.mxPmaSize div 2;
    if a > b then pIncr^.mxSz := a else pIncr^.mxSz := b;
    Inc(pTask^.file2.iEof, pIncr^.mxSz);
  end else begin
    vdbeMergeEngineFree(pMerger);
    rc := SQLITE_NOMEM_BKPT;
  end;
  Assert((ppOut^ <> nil) or (rc <> SQLITE_OK));
  Result := rc;
end;

{ vdbeIncrMergerSetThreads — vdbesort.c:2049..2061.  Gated
  #if SQLITE_MAX_WORKER_THREADS>0 in C; a no-op in single-threaded builds
  (there are no bg threads to enable).  Provided for callers (5.7.b.8/.9). }
procedure vdbeIncrMergerSetThreads(pIncr: PIncrMerger);
begin
  { single-threaded: no bg thread to enable; the threaded body that sets
    bUseThread and reclaims file2.iEof is omitted. }
end;

{ vdbePmaReaderIncrMergeInit — vdbesort.c:2220..2280, single-threaded arm.
  Initialise the wrapped MergeEngine, then reserve a region of pTask->file2
  for this IncrMerger (opening file2 on first use, sized to its accumulated
  iEof reservation).  Finally advance the reader to its first key, which
  triggers the initial vdbeIncrSwap/Populate fill.  eMode is always
  INCRINIT_NORMAL here; the threaded / INCRINIT_TASK / INCRINIT_ROOT arms and
  the bg-thread populate are omitted. }
function vdbePmaReaderIncrMergeInit(pReadr: PPmaReader; eMode: i32): i32;
var
  rc:    i32;
  pIncr: PIncrMerger;
  pTask: PSortSubtask;
  db:    PTsqlite3;
  mxSz:  i32;
begin
  rc    := SQLITE_OK;
  pIncr := pReadr^.pIncr;
  pTask := pIncr^.pTask;
  db    := pTask^.pSorter^.db;

  { eMode is always INCRINIT_NORMAL in single-threaded mode. }
  Assert(eMode = INCRINIT_NORMAL);

  rc := vdbeMergeEngineInit(pTask, pIncr^.pMerger, eMode);

  { Set up the required files for pIncr.  A single-threaded object only
    requires a region of pTask->file2 (the multi-threaded two-temp-file arm
    is omitted). }
  if rc = SQLITE_OK then begin
    mxSz := pIncr^.mxSz;
    if pTask^.file2.pFd = nil then begin
      Assert(pTask^.file2.iEof > 0);
      rc := vdbeSorterOpenTempFile(db, pTask^.file2.iEof, @pTask^.file2.pFd);
      pTask^.file2.iEof := 0;
    end;
    if rc = SQLITE_OK then begin
      pIncr^.aFile[1].pFd := pTask^.file2.pFd;
      pIncr^.iStartOff    := pTask^.file2.iEof;
      Inc(pTask^.file2.iEof, mxSz);
    end;
  end;

  { SQLITE_MAX_WORKER_THREADS==0: eMode!=INCRINIT_TASK always holds. }
  if rc = SQLITE_OK then
    rc := vdbePmaReaderNext(pReadr);

  Result := rc;
end;

{ vdbePmaReaderIncrInit — vdbesort.c:2308..2336, single-threaded arm.  If
  pReadr->pIncr is set, drive vdbePmaReaderIncrMergeInit on the current thread
  (the threaded bg-thread launch is omitted).  No-op otherwise. }
function vdbePmaReaderIncrInit(pReadr: PPmaReader; eMode: i32): i32;
var
  pIncr: PIncrMerger;
begin
  pIncr  := pReadr^.pIncr;
  Result := SQLITE_OK;
  if pIncr <> nil then
    Result := vdbePmaReaderIncrMergeInit(pReadr, eMode);
end;

{ ----------------------------------------------------------------------------
  Phase 5.7.b.8 — merge-tree builder + final reader/merger setup.
  Ports vdbeSorterTreeDepth / vdbeSorterAddToTree / vdbeSorterMergeTreeBuild /
  vdbeSorterSetupMerge (vdbesort.c:2377..2611).  Single-threaded only
  (SQLITE_MAX_WORKER_THREADS==0): nTask==1, bUseThreads==0; the >0 per-task
  fan-out, INCRINIT_TASK/ROOT and bg-init branches are omitted.  Not yet wired
  into Rewind (5.7.b.9 does that).
  ---------------------------------------------------------------------------- }

{ vdbeSorterTreeDepth — vdbesort.c:2377..2394.  Compute the depth of the
  incremental-merge tree needed for nPMA PMAs: the number of times nDiv must be
  multiplied by SORTER_MAX_MERGE_COUNT (starting at SORTER_MAX_MERGE_COUNT)
  before it equals or exceeds nPMA. }
function vdbeSorterTreeDepth(nPMA: i32): i32;
var
  nDepth: i32;
  nDiv:   i64;
begin
  nDepth := 0;
  nDiv   := SORTER_MAX_MERGE_COUNT;
  while nDiv < i64(nPMA) do begin
    nDiv := nDiv * SORTER_MAX_MERGE_COUNT;
    Inc(nDepth);
  end;
  Result := nDepth;
end;

{ vdbeSorterAddToTree — vdbesort.c:2395..2450.  pRoot is the root of an
  incremental merge-tree of depth nDepth (per vdbeSorterTreeDepth).  pLeaf is
  the iSeq'th leaf (counting from zero); add it to the tree, creating the
  intermediate MergeEngine+IncrMerger nodes on the descent path as needed.
  On error pLeaf is freed (via vdbeIncrFree of the IncrMerger that wraps it). }
function vdbeSorterAddToTree(pTask: PSortSubtask; nDepth: i32; iSeq: i32;
                            pRoot: PMergeEngine; pLeaf: PMergeEngine): i32;
var
  rc:     i32;
  nDiv:   i32;
  i:      i32;
  p:      PMergeEngine;
  pIncr:  PIncrMerger;
  iIter:  i32;
  pReadr: PPmaReader;
  pNew:   PMergeEngine;
begin
  rc   := SQLITE_OK;
  nDiv := 1;
  p    := pRoot;

  rc := vdbeIncrMergerNew(pTask, pLeaf, @pIncr);

  i := 1;
  while i < nDepth do begin
    nDiv := nDiv * SORTER_MAX_MERGE_COUNT;
    Inc(i);
  end;

  i := 1;
  while (i < nDepth) and (rc = SQLITE_OK) do begin
    iIter  := (iSeq div nDiv) mod SORTER_MAX_MERGE_COUNT;
    pReadr := @p^.aReadr[iIter];

    if pReadr^.pIncr = nil then begin
      pNew := vdbeMergeEngineNew(SORTER_MAX_MERGE_COUNT);
      if pNew = nil then
        rc := SQLITE_NOMEM_BKPT
      else
        rc := vdbeIncrMergerNew(pTask, pNew, @pReadr^.pIncr);
    end;
    if rc = SQLITE_OK then begin
      p    := pReadr^.pIncr^.pMerger;
      nDiv := nDiv div SORTER_MAX_MERGE_COUNT;
    end;
    Inc(i);
  end;

  if rc = SQLITE_OK then
    p^.aReadr[iSeq mod SORTER_MAX_MERGE_COUNT].pIncr := pIncr
  else
    vdbeIncrFree(pIncr);
  Result := rc;
end;

{ vdbeSorterMergeTreeBuild — vdbesort.c:2451..2529.  Build a tree of
  MergeEngine/IncrMerger/PmaReader objects spanning all PMAs on disk; set
  *ppOut to the root MergeEngine.  Single-threaded subset: the
  SQLITE_MAX_WORKER_THREADS>0 multi-task top-level MergeEngine and per-task
  IncrMerger wiring collapse to one task (aTask[0]) whose root becomes pMain. }
function vdbeSorterMergeTreeBuild(pSorter: PVdbeSorter;
                                 ppOut: PPMergeEngine): i32;
var
  pMain:    PMergeEngine;
  rc:       i32;
  iTask:    i32;
  pTask:    PSortSubtask;
  pRoot:    PMergeEngine;
  nDepth:   i32;
  iReadOff: i64;
  i:        i32;
  iSeq:     i32;
  pMerger:  PMergeEngine;
  nReader:  i32;
begin
  pMain := nil;
  rc    := SQLITE_OK;

  { SQLITE_MAX_WORKER_THREADS>0 top-level MergeEngine block omitted. }

  iTask := 0;
  while (rc = SQLITE_OK) and (iTask < pSorter^.nTask) do begin
    pTask := @pSorter^.aTask;   { single-threaded: aTask[0] }
    { C: assert(pTask->nPMA>0 || SQLITE_MAX_WORKER_THREADS>0).  With
      SQLITE_MAX_WORKER_THREADS==0 the second disjunct is false, so the
      assertion reduces to nPMA>0. }
    Assert(pTask^.nPMA > 0);
    { SQLITE_MAX_WORKER_THREADS==0: the guard is always taken. }
    begin
      pRoot    := nil;          { Root node of tree for this task }
      nDepth   := vdbeSorterTreeDepth(pTask^.nPMA);
      iReadOff := 0;

      if pTask^.nPMA <= SORTER_MAX_MERGE_COUNT then begin
        rc := vdbeMergeEngineLevel0(pTask, pTask^.nPMA, @iReadOff, @pRoot);
      end else begin
        iSeq  := 0;
        pRoot := vdbeMergeEngineNew(SORTER_MAX_MERGE_COUNT);
        if pRoot = nil then rc := SQLITE_NOMEM_BKPT;
        i := 0;
        while (i < pTask^.nPMA) and (rc = SQLITE_OK) do begin
          pMerger := nil;       { New level-0 PMA merger }
          { Number of level-0 PMAs to merge }
          if (pTask^.nPMA - i) < SORTER_MAX_MERGE_COUNT then
            nReader := pTask^.nPMA - i
          else
            nReader := SORTER_MAX_MERGE_COUNT;
          rc := vdbeMergeEngineLevel0(pTask, nReader, @iReadOff, @pMerger);
          if rc = SQLITE_OK then begin
            rc := vdbeSorterAddToTree(pTask, nDepth, iSeq, pRoot, pMerger);
            Inc(iSeq);
          end;
          Inc(i, SORTER_MAX_MERGE_COUNT);
        end;
      end;

      if rc = SQLITE_OK then begin
        { SQLITE_MAX_WORKER_THREADS>0 pMain<>nil arm omitted. }
        Assert(pMain = nil);
        pMain := pRoot;
      end else
        vdbeMergeEngineFree(pRoot);
    end;
    Inc(iTask);
  end;

  if rc <> SQLITE_OK then begin
    vdbeMergeEngineFree(pMain);
    pMain := nil;
  end;
  ppOut^ := pMain;
  Result := rc;
end;

{ vdbeSorterSetupMerge — vdbesort.c:2530..2611.  Build the merge tree and set
  up the final iterator.  Single-threaded only: SQLITE_MAX_WORKER_THREADS==0 so
  bUseThreads==0; the result always goes through pSorter->pMerger (the bg-init
  pReader branch is omitted).  After this returns OK, pSorter->pMerger points
  at a ready-to-step engine. }
function vdbeSorterSetupMerge(pSorter: PVdbeSorter): i32;
var
  rc:     i32;
  pTask0: PSortSubtask;
  pMain:  PMergeEngine;
begin
  pTask0 := @pSorter^.aTask;   { &pSorter->aTask[0] }
  pMain  := nil;

  { SQLITE_MAX_WORKER_THREADS xCompare-per-task setup omitted. }

  rc := vdbeSorterMergeTreeBuild(pSorter, @pMain);
  if rc = SQLITE_OK then begin
    { bUseThreads==0: the threaded pReader/bg-init arm is omitted. }
    rc := vdbeMergeEngineInit(pTask0, pMain, INCRINIT_NORMAL);
    pSorter^.pMerger := pMain;
    pMain := nil;
  end;

  if rc <> SQLITE_OK then
    vdbeMergeEngineFree(pMain);
  Result := rc;
end;

{ ============================================================================
  In-memory sort engine + write-side PMA — vdbesort.c  (tasklist 5.7.b.5)

  C-faithful 1:1 port of the in-memory linked-list merge engine and the
  PMA write path.  KeyInfo header fields are read by byte offset because
  PKeyInfo is opaque in this unit (nKeyField:u16@6, nAllField:u16@8,
  aSortFlags:Pu8@24, aColl[0]:PCollSeq@32; see codegen.pas TKeyInfo).
  Record layout: nVal:i32@0, union u@8, SRVAL(p)=p+16 (5.7.b.1).
  ============================================================================ }

{ Small KeyInfo header accessors (opaque PKeyInfo). }
function kiNKeyField(pKI: PKeyInfo): i32; inline;
begin Result := i32(Pu16(PByte(pKI) + 6)^); end;

function kiAColl0(pKI: PKeyInfo): Pointer; inline;
begin Result := PPointer(PByte(pKI) + 32)^; end;

function kiASortFlags(pKI: PKeyInfo): Pu8; inline;
begin Result := PPointer(PByte(pKI) + 24)^; end;

{ vdbeSorterRecordFree — vdbesort.c:1050..1057.  Free a list of separately
  allocated SorterRecords (u.pNext at offset 8). }
procedure vdbeSorterRecordFree(db: PTsqlite3; pRecord: PSorterRecord);
var
  p, pNext: PSorterRecord;
begin
  p := pRecord;
  while p <> nil do begin
    pNext := p^.u.pNext;
    sqlite3DbFree(db, p);
    p := pNext;
  end;
end;

{ vdbeSortSubtaskCleanup — vdbesort.c:1063..1083 (single-threaded subset).
  list.aMemory is always 0 in single-threaded mode, so the record list is
  freed via vdbeSorterRecordFree.  file/file2 teardown lands with the
  merger (5.7.b.9); here they are nil until the spill gate flips. }
procedure vdbeSortSubtaskCleanup(db: PTsqlite3; pTask: PSortSubtask);
begin
  sqlite3DbFree(db, pTask^.pUnpacked);
  Assert(pTask^.list.aMemory = nil);
  vdbeSorterRecordFree(nil, pTask^.list.pList);
  if pTask^.file_.pFd <> nil then begin
    sqlite3OsClose(pTask^.file_.pFd);
    sqlite3_free(pTask^.file_.pFd);
  end;
  if pTask^.file2.pFd <> nil then begin
    sqlite3OsClose(pTask^.file2.pFd);
    sqlite3_free(pTask^.file2.pFd);
  end;
  FillChar(pTask^, SizeOf(TSortSubtask), 0);
end;

{ sqlite3VdbeSorterInit — vdbesort.c:936..1044 (single-threaded; nWorker==0).
  Computes mnPmaSize/mxPmaSize from szPma + page-size + schema cache_size,
  pgsz from the main btree, sets up aTask[0], and the bulk aMemory buffer.
  KeyInfo is referenced (not copied) — pCsr->pKeyInfo outlives pSorter and
  this port shares the same allocation, so the nField override below does
  NOT clobber pCsr->pKeyInfo->nKeyField (we never write through it). }
function sqlite3VdbeSorterInit(db: PTsqlite3; nField: i32;
                               pCsr: PVdbeCursor): i32;
var
  pgsz:    i32;
  pSorter: PVdbeSorter;
  pKInfo:  PKeyInfo;   { local: pKeyInfo would shadow type PKeyInfo (FPC) }
  rc:      i32;
  pBt:     PBtree;
  mxCache: i64;
  szPma:   u32;
begin
  if pCsr = nil then begin Result := SQLITE_MISUSE; Exit; end;
  { Cannot sort without KeyInfo. }
  if pCsr^.pKeyInfo = nil then begin Result := SQLITE_ERROR; Exit; end;
  rc := SQLITE_OK;

  pSorter := PVdbeSorter(sqlite3DbMallocZero(db, SizeOf(TVdbeSorter)));
  pCsr^.uc.pSorter := pSorter;
  if pSorter = nil then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;

  pKInfo := pCsr^.pKeyInfo;
  pSorter^.pKeyInfo := pKInfo;
  if (nField <> 0) {and nWorker==0} then begin
    { Override key-field count for a stable CREATE INDEX sort (9.4.divbug.30
      keeps RecordCompare from walking the PK tail).  This port reuses the
      caller's KeyInfo allocation rather than copying it (C copies), so we
      record the override on the sorter and apply it to pUnpacked->nField in
      vdbeSortAllocUnpacked — we must NOT write pKInfo->nKeyField here. }
  end;

  pBt := PBtree(db^.aDb[0].pBt);
  sqlite3BtreeEnter(pBt);
  pgsz := sqlite3BtreeGetPageSize(pBt);
  pSorter^.pgsz := pgsz;
  sqlite3BtreeLeave(pBt);
  pSorter^.nTask := 1;
  pSorter^.iPrev := 0;
  pSorter^.bUseThreads := 0;
  pSorter^.db := db;
  pSorter^.aTask.pSorter := pSorter;

  if sqlite3TempInMemory(db) = 0 then begin
    szPma := sqlite3GlobalConfig.szPma;
    pSorter^.mnPmaSize := i32(szPma) * pgsz;

    mxCache := i64(db^.aDb[0].pSchema^.cache_size);
    if mxCache < 0 then
      mxCache := mxCache * (-1024)        { abs(C) KiB }
    else
      mxCache := mxCache * pgsz;
    if mxCache > SQLITE_MAX_PMASZ then mxCache := SQLITE_MAX_PMASZ;
    pSorter^.mxPmaSize := pSorter^.mnPmaSize;
    if i32(mxCache) > pSorter^.mxPmaSize then pSorter^.mxPmaSize := i32(mxCache);

    { Avoid large allocations under SQLITE_CONFIG_SMALL_MALLOC. }
    if sqlite3GlobalConfig.bSmallMalloc = 0 then begin
      Assert(pSorter^.iMemory = 0);
      pSorter^.nMemory := pgsz;
      pSorter^.list.aMemory := Pu8(sqlite3Malloc(pgsz));
      if pSorter^.list.aMemory = nil then rc := SQLITE_NOMEM_BKPT;
    end;
  end;

  if (i32(Pu16(PByte(pKInfo) + 8)^) < 13)   { nAllField@8 }
   and ((kiAColl0(pKInfo) = nil) or (kiAColl0(pKInfo) = db^.pDfltColl))
   and ((kiASortFlags(pKInfo)[0] and KEYINFO_ORDER_BIGNULL) = 0) then
    pSorter^.typeMask := SORTER_TYPE_INTEGER or SORTER_TYPE_TEXT;

  Result := rc;
end;

procedure sqlite3VdbeSorterReset(db: PTsqlite3; pSorter: PVdbeSorter);
begin
  { vdbesort.c:1247..1275 (single-threaded subset).  No thread joins
    (bUseThreads==0); the SQLITE_MAX_WORKER_THREADS pReader-free arm is
    omitted (pReader stays nil single-threaded), but the merge engine and
    pUnpacked still need releasing.  vdbeMergeEngineFree walks aReadr[] and
    frees each PmaReader's buffers + the engine block; subtask cleanup
    closes the temp files (vdbesort.c:1063..1083). }
  if pSorter = nil then Exit;
  Assert((pSorter^.bUseThreads <> 0) or (pSorter^.pReader = nil));
  vdbeMergeEngineFree(pSorter^.pMerger);
  pSorter^.pMerger := nil;
  vdbeSortSubtaskCleanup(db, @pSorter^.aTask);
  pSorter^.aTask.pSorter := pSorter;
  if pSorter^.list.aMemory = nil then
    vdbeSorterRecordFree(nil, pSorter^.list.pList);
  pSorter^.list.pList := nil;
  pSorter^.list.szPMA := 0;
  pSorter^.bUsePMA    := 0;
  pSorter^.iMemory    := 0;
  pSorter^.mxKeysize  := 0;
  sqlite3DbFree(db, pSorter^.pUnpacked);
  pSorter^.pUnpacked := nil;
end;

procedure sqlite3VdbeSorterClose(db: PTsqlite3; pCsr: PVdbeCursor);
var
  pSorter: PVdbeSorter;
begin
  { vdbesort.c:1280..1296 }
  if pCsr = nil then Exit;
  pSorter := pCsr^.uc.pSorter;
  if pSorter <> nil then begin
    Inc(db^.nSpill, pSorter^.aTask.nSpill);
    sqlite3VdbeSorterReset(db, pSorter);
    sqlite3_free(pSorter^.list.aMemory);
    sqlite3DbFree(db, pSorter);
    pCsr^.uc.pSorter := nil;
  end;
end;

{ -------- comparison family — vdbesort.c:763..915 -------- }

{ vdbeSorterCompareTail — vdbesort.c:763..775 }
function vdbeSorterCompareTail(pTask: PSortSubtask; pbKey2Cached: Pi32;
  pKey1: Pointer; nKey1: i32; pKey2: Pointer; nKey2: i32): i32; cdecl;
var
  r2: PUnpackedRecord;
begin
  r2 := pTask^.pUnpacked;
  if pbKey2Cached^ = 0 then begin
    sqlite3VdbeRecordUnpack(pTask^.pSorter^.pKeyInfo, nKey2, pKey2, r2);
    pbKey2Cached^ := 1;
  end;
  Result := sqlite3VdbeRecordCompareWithSkip(nKey1, pKey1, r2, 1);
end;

{ vdbeSorterCompare — vdbesort.c:790..802 (generic) }
function vdbeSorterCompare(pTask: PSortSubtask; pbKey2Cached: Pi32;
  pKey1: Pointer; nKey1: i32; pKey2: Pointer; nKey2: i32): i32; cdecl;
var
  r2: PUnpackedRecord;
begin
  r2 := pTask^.pUnpacked;
  if pbKey2Cached^ = 0 then begin
    sqlite3VdbeRecordUnpack(pTask^.pSorter^.pKeyInfo, nKey2, pKey2, r2);
    pbKey2Cached^ := 1;
  end;
  Result := sqlite3VdbeRecordCompare(nKey1, pKey1, r2);
end;

{ vdbeSorterCompareText — vdbesort.c:809..846.  First field assumed TEXT,
  collation BINARY. }
function vdbeSorterCompareText(pTask: PSortSubtask; pbKey2Cached: Pi32;
  pKey1: Pointer; nKey1: i32; pKey2: Pointer; nKey2: i32): i32; cdecl;
var
  p1, p2, v1, v2: Pu8;
  n1, n2, res, mn: i32;
  un1, un2: u32;
begin
  p1 := Pu8(pKey1);
  p2 := Pu8(pKey2);
  v1 := @p1[p1[0]];
  v2 := @p2[p2[0]];
  { getVarint32NR(&p1[1], n1) }
  sqlite3GetVarint32(@p1[1], un1); n1 := i32(un1);
  sqlite3GetVarint32(@p2[1], un2); n2 := i32(un2);
  if n1 < n2 then mn := n1 else mn := n2;
  { memcmp — CompareByte returns the signed first-differing-byte delta. }
  res := i32(CompareByte(v1^, v2^, (mn - 13) div 2));
  if res = 0 then
    res := n1 - n2;

  if res = 0 then begin
    if kiNKeyField(pTask^.pSorter^.pKeyInfo) > 1 then
      res := vdbeSorterCompareTail(pTask, pbKey2Cached,
                                   pKey1, nKey1, pKey2, nKey2);
  end else begin
    if kiASortFlags(pTask^.pSorter^.pKeyInfo)[0] <> 0 then
      res := res * -1;
  end;
  Result := res;
end;

{ vdbeSorterCompareInt — vdbesort.c:852..914.  First field assumed INTEGER. }
function vdbeSorterCompareInt(pTask: PSortSubtask; pbKey2Cached: Pi32;
  pKey1: Pointer; nKey1: i32; pKey2: Pointer; nKey2: i32): i32; cdecl;
const
  aLen: array[0..9] of u8 = (0, 1, 2, 3, 4, 6, 8, 0, 0, 0);
var
  p1, p2, v1, v2: Pu8;
  s1, s2, res, i: i32;
  n: u8;
begin
  p1 := Pu8(pKey1);
  p2 := Pu8(pKey2);
  s1 := p1[1];
  s2 := p2[1];
  v1 := @p1[p1[0]];
  v2 := @p2[p2[0]];

  if s1 = s2 then begin
    { Same serial type — compare value bytes via memcmp with sign fix-up. }
    n := aLen[s1];
    res := 0;
    for i := 0 to i32(n) - 1 do begin
      res := i32(v1[i]) - i32(v2[i]);
      if res <> 0 then begin
        if ((v1[0] xor v2[0]) and $80) <> 0 then begin
          if (v1[0] and $80) <> 0 then res := -1 else res := +1;
        end;
        break;
      end;
    end;
  end else if (s1 > 7) and (s2 > 7) then begin
    res := s1 - s2;
  end else begin
    if s2 > 7 then res := +1
    else if s1 > 7 then res := -1
    else res := s1 - s2;
    Assert(res <> 0);
    if res > 0 then begin
      if (v1[0] and $80) <> 0 then res := -1;
    end else begin
      if (v2[0] and $80) <> 0 then res := +1;
    end;
  end;

  if res = 0 then begin
    if kiNKeyField(pTask^.pSorter^.pKeyInfo) > 1 then
      res := vdbeSorterCompareTail(pTask, pbKey2Cached,
                                   pKey1, nKey1, pKey2, nKey2);
  end else if kiASortFlags(pTask^.pSorter^.pKeyInfo)[0] <> 0 then
    res := res * -1;

  Result := res;
end;

{ vdbeSortAllocUnpacked — vdbesort.c:1354..1362.  default_rc:=0 (bug 6.13);
  nField capped at nKeyField (9.4.divbug.30). }
function vdbeSortAllocUnpacked(pTask: PSortSubtask): i32;
begin
  if pTask^.pUnpacked = nil then begin
    pTask^.pUnpacked :=
      PUnpackedRecord(sqlite3VdbeAllocUnpackedRecord(pTask^.pSorter^.pKeyInfo));
    if pTask^.pUnpacked = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
    pTask^.pUnpacked^.nField := u16(kiNKeyField(pTask^.pSorter^.pKeyInfo));
    pTask^.pUnpacked^.errCode := 0;
    pTask^.pUnpacked^.default_rc := 0;
  end;
  Result := SQLITE_OK;
end;

{ vdbeSorterMerge — vdbesort.c:1368..1404.  Stable two-list merge (res<=0
  keeps p1), linking via u.pNext. }
function vdbeSorterMerge(pTask: PSortSubtask;
  p1, p2: PSorterRecord): PSorterRecord;
var
  pFinal: PSorterRecord;
  pp:     ^PSorterRecord;
  bCached, res: i32;
begin
  pFinal := nil;
  pp := @pFinal;
  bCached := 0;
  Assert((p1 <> nil) and (p2 <> nil));
  while True do begin
    res := pTask^.xCompare(pTask, @bCached,
                           SRVAL(p1), p1^.nVal, SRVAL(p2), p2^.nVal);
    if res <= 0 then begin
      pp^ := p1;
      pp  := @p1^.u.pNext;
      p1  := p1^.u.pNext;
      if p1 = nil then begin pp^ := p2; break; end;
    end else begin
      pp^ := p2;
      pp  := @p2^.u.pNext;
      p2  := p2^.u.pNext;
      bCached := 0;
      if p2 = nil then begin pp^ := p1; break; end;
    end;
  end;
  Result := pFinal;
end;

{ vdbeSorterGetCompare — vdbesort.c:1410..1417. }
function vdbeSorterGetCompare(p: PVdbeSorter): TSorterCompare;
begin
  if p^.typeMask = SORTER_TYPE_INTEGER then
    Result := @vdbeSorterCompareInt
  else if p^.typeMask = SORTER_TYPE_TEXT then
    Result := @vdbeSorterCompareText
  else
    Result := @vdbeSorterCompare;
end;

{ vdbeSorterSort — vdbesort.c:1424..1474.  Bottom-up merge with aSlot[64],
  converting aMemory iNext->pNext as the list is traversed. }
function vdbeSorterSort(pTask: PSortSubtask; pList: PSorterList): i32;
var
  i, rc:  i32;
  p, pNext: PSorterRecord;
  aSlot:  array[0..63] of PSorterRecord;
begin
  rc := vdbeSortAllocUnpacked(pTask);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  p := pList^.pList;
  pTask^.xCompare := vdbeSorterGetCompare(pTask^.pSorter);
  FillChar(aSlot, SizeOf(aSlot), 0);

  while p <> nil do begin
    if pList^.aMemory <> nil then begin
      if Pu8(p) = pList^.aMemory then
        pNext := nil
      else
        pNext := PSorterRecord(@pList^.aMemory[p^.u.iNext]);
    end else
      pNext := p^.u.pNext;

    p^.u.pNext := nil;
    i := 0;
    while aSlot[i] <> nil do begin
      p := vdbeSorterMerge(pTask, p, aSlot[i]);
      Assert(i < Length(aSlot));
      aSlot[i] := nil;
      Inc(i);
    end;
    aSlot[i] := p;
    p := pNext;
  end;

  p := nil;
  for i := 0 to Length(aSlot) - 1 do begin
    if aSlot[i] = nil then Continue;
    if p <> nil then p := vdbeSorterMerge(pTask, p, aSlot[i])
    else             p := aSlot[i];
  end;
  pList^.pList := p;

  Result := pTask^.pUnpacked^.errCode;
end;

{ vdbeSorterListToPMA — vdbesort.c:1578..1633 (single-threaded).  Sort the
  list then write it as one PMA via the (already ported) PmaWriter. }
function vdbeSorterListToPMA(pTask: PSortSubtask; pList: PSorterList): i32;
var
  db:     PTsqlite3;
  rc:     i32;
  writer: TPmaWriter;
  p, pNext: PSorterRecord;
begin
  db := pTask^.pSorter^.db;
  rc := SQLITE_OK;
  FillChar(writer, SizeOf(writer), 0);
  Assert(pList^.szPMA > 0);

  { Open the first temporary PMA file if not yet open. }
  if pTask^.file_.pFd = nil then begin
    rc := vdbeSorterOpenTempFile(db, 0, @pTask^.file_.pFd);
    Assert((rc <> SQLITE_OK) or (pTask^.file_.pFd <> nil));
  end;

  if rc = SQLITE_OK then
    vdbeSorterExtendFile(db, pTask^.file_.pFd,
                         pTask^.file_.iEof + pList^.szPMA + 9);

  if rc = SQLITE_OK then
    rc := vdbeSorterSort(pTask, pList);

  if rc = SQLITE_OK then begin
    pNext := nil;
    vdbePmaWriterInit(pTask^.file_.pFd, @writer, pTask^.pSorter^.pgsz,
                      pTask^.file_.iEof);
    Inc(pTask^.nPMA);
    vdbePmaWriteVarint(@writer, u64(pList^.szPMA));
    p := pList^.pList;
    while p <> nil do begin
      pNext := p^.u.pNext;
      vdbePmaWriteVarint(@writer, u64(p^.nVal));
      vdbePmaWriteBlob(@writer, SRVAL(p), p^.nVal);
      if pList^.aMemory = nil then sqlite3_free(p);
      p := pNext;
    end;
    pList^.pList := p;
    rc := vdbePmaWriterFinish(@writer, @pTask^.file_.iEof, @pTask^.nSpill);
  end;

  Assert((rc <> SQLITE_OK) or (pList^.pList = nil));
  Result := rc;
end;

{ vdbeSorterFlushPMA — vdbesort.c:1727..1730 (SQLITE_MAX_WORKER_THREADS==0
  branch only).  Sets bUsePMA and flushes aTask[0]'s list to a new PMA. }
function vdbeSorterFlushPMA(pSorter: PVdbeSorter): i32;
begin
  pSorter^.bUsePMA := 1;
  Result := vdbeSorterListToPMA(@pSorter^.aTask, @pSorter^.list);
end;

{ sqlite3VdbeSorterWrite — vdbesort.c:1797..1902.  Add a record to the
  sorter.  typeMask update + bFlush computation are fully live; the actual
  spill (vdbeSorterFlushPMA) is GATED behind SORTER_PMA_ENABLED (5.7.b.5)
  — see the const block at the top of this section.  With the gate False,
  everything stays in RAM (no spill, no data loss); 5.7.b.9 flips it. }
function sqlite3VdbeSorterWrite(pCsr: PVdbeCursor; pVal: PMem): i32;
var
  pSorter: PVdbeSorter;
  rc:      i32;
  pNew:    PSorterRecord;
  bFlush:  Boolean;
  nReq:    i64;
  nPMA:    i64;
  t:       u32;
  nMin:    i32;
  nNew:    i64;
  iListOff: PtrInt;
  aNew:    Pu8;
begin
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  pSorter := pCsr^.uc.pSorter;
  rc := SQLITE_OK;

  { getVarint32NR(&pVal->z[1], t) — serial type of first record field. }
  sqlite3GetVarint32(@Pu8(pVal^.z)[1], t);
  if (t > 0) and (t < 10) and (t <> 7) then
    pSorter^.typeMask := pSorter^.typeMask and SORTER_TYPE_INTEGER
  else if (t > 10) and ((t and $01) <> 0) then
    pSorter^.typeMask := pSorter^.typeMask and SORTER_TYPE_TEXT
  else
    pSorter^.typeMask := 0;

  nReq := i64(pVal^.n) + SZ_SORTER_RECORD;
  nPMA := i64(pVal^.n) + sqlite3VarintLen(u64(pVal^.n));
  if pSorter^.mxPmaSize <> 0 then begin
    if pSorter^.list.aMemory <> nil then
      bFlush := (pSorter^.iMemory <> 0)
            and ((i64(pSorter^.iMemory) + nReq) > pSorter^.mxPmaSize)
    else
      bFlush := (pSorter^.list.szPMA > pSorter^.mxPmaSize)
             or ((pSorter^.list.szPMA > pSorter^.mnPmaSize)
                 and (sqlite3HeapNearlyFull <> 0));
    if bFlush then begin
      { *** 5.7.b.5 SPILL GATE — see SORTER_PMA_ENABLED comment block. ***
        Faithful flush call deferred until the merge read-back (5.7.b.6..b.9)
        exists; 5.7.b.9 flips SORTER_PMA_ENABLED to True. }
      if SORTER_PMA_ENABLED then begin
        rc := vdbeSorterFlushPMA(pSorter);
        pSorter^.list.szPMA := 0;
        pSorter^.iMemory := 0;
        Assert((rc <> SQLITE_OK) or (pSorter^.list.pList = nil));
      end;
    end;
  end;

  pSorter^.list.szPMA := pSorter^.list.szPMA + nPMA;
  if nPMA > pSorter^.mxKeysize then
    pSorter^.mxKeysize := i32(nPMA);

  if pSorter^.list.aMemory <> nil then begin
    nMin := pSorter^.iMemory + i32(nReq);
    if nMin > pSorter^.nMemory then begin
      nNew := 2 * i64(pSorter^.nMemory);
      iListOff := -1;
      if pSorter^.list.pList <> nil then
        iListOff := PtrInt(Pu8(pSorter^.list.pList) - pSorter^.list.aMemory);
      while nNew < nMin do nNew := nNew * 2;
      if nNew > pSorter^.mxPmaSize then nNew := pSorter^.mxPmaSize;
      if nNew < nMin then nNew := nMin;
      aNew := Pu8(sqlite3Realloc(pSorter^.list.aMemory, u64(nNew)));
      if aNew = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
      if iListOff >= 0 then
        pSorter^.list.pList := PSorterRecord(@aNew[iListOff]);
      pSorter^.list.aMemory := aNew;
      pSorter^.nMemory := i32(nNew);
    end;

    pNew := PSorterRecord(@pSorter^.list.aMemory[pSorter^.iMemory]);
    Inc(pSorter^.iMemory, i32(ROUND8(SizeInt(nReq))));
    if pSorter^.list.pList <> nil then
      pNew^.u.iNext :=
        i32(Pu8(pSorter^.list.pList) - pSorter^.list.aMemory);
  end else begin
    pNew := PSorterRecord(sqlite3Malloc(i32(nReq)));
    if pNew = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
    pNew^.u.pNext := pSorter^.list.pList;
  end;

  Move(pVal^.z^, SRVAL(pNew)^, pVal^.n);
  pNew^.nVal := pVal^.n;
  pSorter^.list.pList := pNew;

  Result := rc;
end;

{ sqlite3VdbeSorterRewind — vdbesort.c:2612..2655.  In-memory (bUsePMA==0)
  path only — sort the list; the VDBE then reads it directly.  The PMA
  flush+merge-setup arm lands in 5.7.b.9 (gated by SORTER_PMA_ENABLED). }
function sqlite3VdbeSorterRewind(pCsr: PVdbeCursor; out pbEof: i32): i32;
var
  pSorter: PVdbeSorter;
  rc:      i32;
begin
  pbEof := 1;
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  pSorter := pCsr^.uc.pSorter;
  rc := SQLITE_OK;

  if pSorter^.bUsePMA = 0 then begin
    if pSorter^.list.pList <> nil then begin
      pbEof := 0;
      rc := vdbeSorterSort(@pSorter^.aTask, @pSorter^.list);
    end else
      pbEof := 1;
    pSorter^.pReader := nil;
    Result := rc;
    Exit;
  end;

  { Write the residual in-memory list to a final PMA, then build the merge
    tree.  After a spill VdbeSorterWrite always re-seeds list.pList with one
    key, so the list is never empty here (vdbesort.c:2632..2654). }
  Assert(pSorter^.list.pList <> nil);
  rc := vdbeSorterFlushPMA(pSorter);
  { vdbeSorterJoinAll is a no-op single-threaded; skipped. }
  Assert(pSorter^.pReader = nil);
  if rc = SQLITE_OK then begin
    rc := vdbeSorterSetupMerge(pSorter);
    pbEof := 0;
  end;
  Result := rc;
end;

{ sqlite3VdbeSorterNext — vdbesort.c:2664..2696.  In-memory path: advance the
  list head and free the consumed record (separate-alloc only). }
function sqlite3VdbeSorterNext(db: PTsqlite3; pCsr: PVdbeCursor): i32;
var
  pSorter: PVdbeSorter;
  pFree:   PSorterRecord;
  rc:      i32;
  res:     i32;
begin
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  pSorter := pCsr^.uc.pSorter;
  if pSorter^.bUsePMA <> 0 then begin
    { Single-threaded: drive the merge from pSorter->pMerger (vdbesort.c:
      2681..2687).  res<>0 means the merge tree is exhausted. }
    Assert(pSorter^.pMerger <> nil);
    res := 0;
    rc  := vdbeMergeEngineStep(pSorter^.pMerger, @res);
    if (rc = SQLITE_OK) and (res <> 0) then rc := SQLITE_DONE;
    Result := rc;
    Exit;
  end;
  pFree := pSorter^.list.pList;
  if pFree = nil then begin Result := SQLITE_DONE; Exit; end;
  pSorter^.list.pList := pFree^.u.pNext;
  pFree^.u.pNext := nil;
  if pSorter^.list.aMemory = nil then vdbeSorterRecordFree(db, pFree);
  if pSorter^.list.pList <> nil then Result := SQLITE_OK
  else                              Result := SQLITE_DONE;
end;

{ vdbeSorterRowkey — vdbesort.c:2702..2724.  Returns the current key buffer
  (in-memory path: SRVAL of the list head). }
function vdbeSorterRowkey(pSorter: PVdbeSorter; out pnKey: i32): Pointer;
var
  pReadr: PPmaReader;
begin
  if pSorter^.bUsePMA <> 0 then begin
    { Single-threaded: the winning reader is aReadr[aTree[1]] (vdbesort.c:
      2714..2719). }
    pReadr := @pSorter^.pMerger^.aReadr[pSorter^.pMerger^.aTree[1]];
    pnKey  := pReadr^.nKey;
    Result := pReadr^.aKey;
  end else begin
    pnKey := pSorter^.list.pList^.nVal;
    Result := SRVAL(pSorter^.list.pList);
  end;
end;

{ sqlite3VdbeSorterRowkey — vdbesort.c:2729..2744. }
function sqlite3VdbeSorterRowkey(pCsr: PVdbeCursor; pOut: PMem): i32;
var
  pSorter: PVdbeSorter;
  pKey:    Pointer;
  nKey:    i32;
begin
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  pSorter := pCsr^.uc.pSorter;
  pKey := vdbeSorterRowkey(pSorter, nKey);
  if sqlite3VdbeMemClearAndResize(pOut, nKey) <> 0 then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;
  pOut^.n := nKey;
  pOut^.flags := MEM_Blob;
  if nKey > 0 then Move(pKey^, pOut^.z^, nKey);
  Result := SQLITE_OK;
end;

{ sqlite3VdbeSorterCompare — vdbesort.c:2762..2796. }
function sqlite3VdbeSorterCompare(pCsr: PVdbeCursor; bOmitRowid: i32;
                                  pKey: Pointer; nKey: i32;
                                  out pRes: i32): i32;
var
  pSorter: PVdbeSorter;
  r2:      PUnpackedRecord;
  pKInfo:  PKeyInfo;   { local: pKeyInfo would shadow type PKeyInfo (FPC) }
  i:       i32;
  pK:      Pointer;
  nK:      i32;
  nKeyCol: i32;
  pVal:    PMem;
begin
  pRes := 0;
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  pSorter := pCsr^.uc.pSorter;
  pVal := PMem(pKey);
  nKeyCol := nKey;
  if bOmitRowid <> 0 then Dec(nKeyCol);
  r2 := pSorter^.pUnpacked;
  pKInfo := pCsr^.pKeyInfo;
  if r2 = nil then begin
    r2 := PUnpackedRecord(sqlite3VdbeAllocUnpackedRecord(pKInfo));
    pSorter^.pUnpacked := r2;
    if r2 = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
    r2^.nField := u16(nKeyCol);
  end;
  Assert(r2^.nField = u16(nKeyCol));

  pK := vdbeSorterRowkey(pSorter, nK);
  sqlite3VdbeRecordUnpack(pSorter^.pKeyInfo, nK, pK, r2);
  for i := 0 to nKeyCol - 1 do begin
    if (PMem(r2^.aMem)[i].flags and MEM_Null) <> 0 then begin
      pRes := -1;
      Result := SQLITE_OK;
      Exit;
    end;
  end;

  pRes := sqlite3VdbeRecordCompare(pVal^.n, pVal^.z, r2);
  Result := SQLITE_OK;
end;

{ ============================================================================
  Phase 5.4a — vdbe.c execution engine helpers + main interpreter loop
  Opcodes ported: OP_Goto, OP_Gosub, OP_Return, OP_InitCoroutine,
  OP_EndCoroutine, OP_Yield, OP_Halt, OP_Init, OP_Integer, OP_Int64,
  OP_Null, OP_SoftNull, OP_Blob, OP_Move, OP_SCopy, OP_IntCopy, OP_Copy,
  OP_ResultRow, OP_Jump, OP_If, OP_IfNot, OP_OpenRead, OP_OpenWrite,
  OP_Close.
  All other opcodes fall to the default case (SQLITE_ERROR).
  ============================================================================ }

{ --- out2Prerelease helpers (vdbe.c:667) --- }

function out2PrereleaseWithClear(pOut: PMem): PMem;
begin
  sqlite3VdbeMemSetNull(pOut);
  pOut^.flags := MEM_Int;
  Result := pOut;
end;

function out2Prerelease(p: PVdbe; pOp: PVdbeOp): PMem; inline;
var
  pOut: PMem;
begin
  pOut := @p^.aMem[pOp^.p2];
  if (pOut^.flags and (MEM_Agg or MEM_Dyn)) <> 0 then
    Result := out2PrereleaseWithClear(pOut)
  else begin
    pOut^.flags := MEM_Int;
    Result := pOut;
  end;
end;

{ SZ_VDBECURSOR(N) = ROUND8(offsetof(VdbeCursor,aType)) + (N+1)*8 }
const
  VDBECURSOR_FIXED_SZ         = 112;
  offsetof_VdbeCursor_pAltCursor = 112;

function SZ_VDBECURSOR(nField: i32): i64; inline;
begin
  Result := 120 + i64(nField + 1) * 8;
end;

{ --- allocateCursor (vdbe.c:253) --- }

function allocateCursor(p: PVdbe; iCur, nField: i32; eCurType: u8): PVdbeCursor;
var
  pMSlot: PMem;   { renamed from pMem to avoid FPC case-insensitive conflict with PMem type }
  nByte:  i64;
  pCx:    PVdbeCursor;
begin
  if iCur > 0 then pMSlot := @p^.aMem[p^.nMem - iCur]
  else pMSlot := p^.aMem;

  nByte := SZ_VDBECURSOR(nField);
  if eCurType = CURTYPE_BTREE then
    nByte := nByte + sqlite3BtreeCursorSize();

  if p^.apCsr[iCur] <> nil then begin
    sqlite3VdbeFreeCursorNN(p, p^.apCsr[iCur]);
    p^.apCsr[iCur] := nil;
  end;

  if pMSlot^.szMalloc < nByte then begin
    if pMSlot^.szMalloc > 0 then
      sqlite3DbFreeNN(pMSlot^.db, pMSlot^.zMalloc);
    pMSlot^.z       := sqlite3DbMallocRaw(pMSlot^.db, u64(nByte));
    pMSlot^.zMalloc := pMSlot^.z;
    if pMSlot^.zMalloc = nil then begin
      pMSlot^.szMalloc := 0;
      Result := nil;
      Exit;
    end;
    pMSlot^.szMalloc := i32(nByte);
  end;

  pCx := PVdbeCursor(pMSlot^.zMalloc);
  p^.apCsr[iCur] := pCx;
  FillChar(pCx^, offsetof_VdbeCursor_pAltCursor, 0);
  pCx^.eCurType := eCurType;
  pCx^.nField   := nField;
  pCx^.aOffset  := Pu32(Pu8(pCx) + 120 + u32(nField) * SizeOf(u32));
  if eCurType = CURTYPE_BTREE then begin
    pCx^.uc.pCursor := PBtCursor(Pu8(pMSlot^.z) + SZ_VDBECURSOR(nField));
    sqlite3BtreeCursorZero(pCx^.uc.pCursor);
  end;
  Result := pCx;
end;

{ --- stub helpers needed by OP_Halt and abort path --- }

function sqlite3ErrStr(rc: i32): PAnsiChar;
{ Port of main.c:1648.  Match the C two-phase lookup: handle the
  extended ABORT_ROLLBACK / ROW / DONE codes first, otherwise mask
  off the high bits before consulting the primary-code table.
  9.4.divbug.71: previously this routine returned "unknown error" for
  SQLITE_ABORT_ROLLBACK because the bare `case` matched neither the
  extended value nor any of the primary codes. }
begin
  case rc of
    SQLITE_ABORT_ROLLBACK: begin Result := 'abort due to ROLLBACK'; Exit; end;
    SQLITE_ROW:            begin Result := 'another row available'; Exit; end;
    SQLITE_DONE:           begin Result := 'no more rows available'; Exit; end;
  end;
  case (rc and $FF) of
    SQLITE_OK:       Result := 'not an error';
    SQLITE_ERROR:    Result := 'SQL logic error';
    SQLITE_INTERNAL: Result := 'internal SQLite error';
    SQLITE_PERM:     Result := 'access permission denied';
    SQLITE_ABORT:    Result := 'query aborted';
    SQLITE_BUSY:     Result := 'database is locked';
    SQLITE_LOCKED:   Result := 'database table is locked';
    SQLITE_NOMEM:    Result := 'out of memory';
    SQLITE_READONLY: Result := 'attempt to write a readonly database';
    SQLITE_INTERRUPT:Result := 'interrupted';
    SQLITE_IOERR:    Result := 'disk I/O error';
    SQLITE_CORRUPT:  Result := 'database disk image is malformed';
    SQLITE_FULL:     Result := 'database or disk is full';
    SQLITE_CANTOPEN: Result := 'unable to open database file';
    SQLITE_PROTOCOL: Result := 'locking protocol';
    SQLITE_SCHEMA:   Result := 'database schema has changed';
    SQLITE_TOOBIG:   Result := 'string or blob too big';
    SQLITE_CONSTRAINT:Result:= 'constraint failed';
    SQLITE_MISMATCH: Result := 'datatype mismatch';
    SQLITE_MISUSE:   Result := 'bad parameter or other API misuse';
    SQLITE_NOLFS:    Result := 'large file support is disabled';
    SQLITE_AUTH:     Result := 'authorization denied';
    SQLITE_RANGE:    Result := 'column index out of range';
    SQLITE_NOTADB:   Result := 'file is not a database';
    SQLITE_NOTICE:   Result := 'notification message';
    SQLITE_WARNING:  Result := 'warning message';
  else               Result := 'unknown error';
  end;
end;

{ Port of vdbe.c:800 sqlite3VdbeLogAbort.
  Sends a "statement aborts at <pc>: <errMsg>; [<prefix><sql>]" message
  through sqlite3_log so the configured xLog callback can record the
  aborting opcode.  The trigger-frame prefix is mirrored faithfully:
  when running inside a sub-program (p^.pFrame <> nil) and the OP_Init
  carries a "-- ..." trigger label in its P4 string, the label is
  rendered as a "/* ... */ " prefix to disambiguate which trigger fired. }
procedure sqlite3VdbeLogAbort(p: PVdbe; rc: i32; pOp, aOp: Pointer);
var
  pOp1:    PVdbeOp;
  aOp1:    PVdbeOp;
  zSqlT:   PAnsiChar;
  zPrefix: PAnsiChar;
  zXtra:   array[0..99] of AnsiChar;
  pcAddr:  PtrInt;
  zP4:     PAnsiChar;
  zMsg:    array[0..511] of AnsiChar;
  zErr:    PAnsiChar;
  xLog:    procedure(pArg: Pointer; iErrCode: i32; zMsg: PAnsiChar); cdecl;
begin
  if p = nil then Exit;
  zSqlT   := p^.zSql;
  zPrefix := PAnsiChar('');
  pOp1 := PVdbeOp(pOp);
  aOp1 := PVdbeOp(aOp);
  if (p^.pFrame <> nil) and (aOp1 <> nil) then begin
    Assert(aOp1^.opcode = OP_Init,
           'sqlite3VdbeLogAbort expects aOp[0]=OP_Init');
    if (aOp1^.p4type = P4_DYNAMIC) or (aOp1^.p4type = P4_STATIC) then
      zP4 := aOp1^.p4.z
    else
      zP4 := nil;
    if zP4 <> nil then begin
      Assert((zP4[0] = '-') and (zP4[1] = '-') and (zP4[2] = ' '),
             'trigger zSql label expected to start with "-- "');
      sqlite3PfSnprintf(SizeOf(zXtra), @zXtra[0],
                        PAnsiChar(AnsiString('/* %s */ ')), [zP4 + 3]);
      zPrefix := @zXtra[0];
    end else
      zPrefix := PAnsiChar('/* unknown trigger */ ');
  end;
  if (pOp1 <> nil) and (aOp1 <> nil) then
    pcAddr := (PtrUInt(pOp1) - PtrUInt(aOp1)) div SizeOf(TVdbeOp)
  else
    pcAddr := 0;
  zErr := p^.zErrMsg;
  if zErr  = nil then zErr  := PAnsiChar('');
  if zSqlT = nil then zSqlT := PAnsiChar('');
  sqlite3PfSnprintf(SizeOf(zMsg), @zMsg[0],
                    PAnsiChar(AnsiString(
                      'statement aborts at %d: %s; [%s%s]')),
                    [i32(pcAddr), zErr, zPrefix, zSqlT]);
  if sqlite3GlobalConfig.xLog <> nil then begin
    Pointer(xLog) := sqlite3GlobalConfig.xLog;
    xLog(sqlite3GlobalConfig.pLogArg, rc, @zMsg[0]);
  end;
end;

procedure sqlite3VdbeSetChanges(db: Pointer; nChange: i64);
{ Port of vdbeaux.c:5305.  Sets the per-connection change counter and
  bumps the cumulative total — the value subsequently returned by
  sqlite3_changes() / sqlite3_total_changes(). }
var
  pDb: PTsqlite3;
begin
  pDb := PTsqlite3(db);
  if pDb = nil then Exit;
  pDb^.nChange := nChange;
  pDb^.nTotalChange := pDb^.nTotalChange + nChange;
end;

procedure sqlite3SystemError(db: Pointer; rc: i32);
{ Port of util.c:155.  Records the host OS errno on the connection so
  sqlite3_system_errno() can surface it.  SQLITE_USE_SEH path is gated
  off in the default upstream build (and sqlite3PagerWalSystemErrno is
  not a Pas symbol yet); we mirror the default-build body. }
var
  pDb:  PTsqlite3;
  pVfs: Psqlite3_vfs;
begin
  if rc = SQLITE_IOERR_NOMEM then Exit;
  rc := rc and $FF;
  if (rc = SQLITE_CANTOPEN) or (rc = SQLITE_IOERR) then
  begin
    pDb := PTsqlite3(db);
    if pDb = nil then Exit;
    pVfs := Psqlite3_vfs(pDb^.pVfs);
    if (pVfs <> nil) and Assigned(pVfs^.xGetLastError) then
      pDb^.iSysErrno := pVfs^.xGetLastError(pVfs, 0, nil);
  end;
end;

procedure sqlite3ResetOneSchema(db: Pointer; iDb: i32);
begin
  if Assigned(gResetOneSchema) then
    gResetOneSchema(PTsqlite3(db), iDb);
end;

{ Implement sqlite3VdbeFrameRestore properly (vdbeaux.c:2812) }
function sqlite3VdbeFrameRestoreFull(pFrame: PVdbeFrame): i32;
var
  v:  PVdbe;
  db: PTsqlite3;
  i:  i32;
  pC: PVdbeCursor;
begin
  v := pFrame^.v;
  { closeCursorsInFrame — vdbeaux.c:2796 }
  for i := 0 to v^.nCursor - 1 do begin
    pC := v^.apCsr[i];
    if pC <> nil then begin
      sqlite3VdbeFreeCursorNN(v, pC);
      v^.apCsr[i] := nil;
    end;
  end;
  v^.aOp    := pFrame^.aOp;
  v^.nOp    := pFrame^.nOp;
  v^.aMem   := pFrame^.aMem;
  v^.nMem   := pFrame^.nMem;
  v^.apCsr  := pFrame^.apCsr;
  v^.nCursor := pFrame^.nCursor;
  db := v^.db;
  if db <> nil then begin
    db^.lastRowid := pFrame^.lastRowid;
    db^.nChange   := pFrame^.nDbChange;
  end;
  v^.nChange := pFrame^.nChange;
  sqlite3VdbeDeleteAuxData(v^.db, @v^.pAuxData, -1, 0);
  v^.pAuxData := pFrame^.pAuxData;
  pFrame^.pAuxData := nil;
  Result := pFrame^.pc;
end;

{ ============================================================================
  Phase 5.4b helpers — ported from vdbe.c (SQLite 3.53.0)
  ============================================================================ }

{ sqlite3IsNaN — true if double is Not-a-Number.
  SQLite is built with SQLITE_NO_ISNAN off on most platforms; use the standard
  IEEE754 test (NaN is the only value not equal to itself). }
function sqlite3IsNaN(x: Double): Boolean; inline;
begin
  Result := x <> x;
end;

{ alsoAnInt — helper for applyNumericAffinity.
  Returns 1 if rValue can be losslessly represented as an i64 (either via
  sqlite3RealSameAsInt or via the decimal string in pRec). }
function alsoAnInt(pRec: PMem; rValue: Double; out piValue: i64): i32;
var
  iValue: i64;
begin
  iValue := sqlite3RealToI64(rValue);
  if sqlite3RealSameAsInt(rValue, iValue) <> 0 then begin
    piValue := iValue;
    Result := 1;
    Exit;
  end;
  if sqlite3Atoi64(pRec^.z, iValue, pRec^.n, pRec^.enc) = 0 then begin
    piValue := iValue;
    Result := 1;
    Exit;
  end;
  piValue := 0;
  Result := 0;
end;

{ applyNumericAffinity — convert a MEM_Str to numeric (Int or Real).
  Port of vdbe.c:354. }
procedure applyNumericAffinity(pRec: PMem; bTryForInt: i32);
var
  rValue: Double;
  rcM:    i32;
  iVal:   i64;
begin
  { assert: pRec^.flags has MEM_Str set (and no numeric bits) }
  rcM := sqlite3MemRealValueRC(pRec, rValue);
  if rcM <= 0 then Exit;
  iVal := 0;
  if ((rcM and 2) = 0) and (alsoAnInt(pRec, rValue, iVal) <> 0) then begin
    pRec^.u.i := iVal;
    pRec^.flags := pRec^.flags or u16(MEM_Int);
  end else begin
    pRec^.u.r := rValue;
    pRec^.flags := pRec^.flags or u16(MEM_Real);
    if bTryForInt <> 0 then sqlite3VdbeIntegerAffinity(pRec);
  end;
  pRec^.flags := pRec^.flags and not u16(MEM_Str);
end;

{ applyAffinity — apply type affinity to a Mem value.
  Port of vdbe.c:397. }
procedure applyAffinity(pRec: PMem; affinity: AnsiChar; enc: u8);
begin
  if Byte(affinity) >= SQLITE_AFF_NUMERIC then begin
    if (pRec^.flags and MEM_Int) = 0 then begin
      if (pRec^.flags and (MEM_Real or MEM_IntReal)) = 0 then begin
        if (pRec^.flags and MEM_Str) <> 0 then
          applyNumericAffinity(pRec, 1);
      end else if Byte(affinity) <= SQLITE_AFF_REAL then
        sqlite3VdbeIntegerAffinity(pRec);
    end;
  end else if Byte(affinity) = SQLITE_AFF_TEXT then begin
    if (pRec^.flags and MEM_Str) = 0 then begin
      if (pRec^.flags and (MEM_Real or MEM_Int or MEM_IntReal)) <> 0 then
        sqlite3VdbeMemStringify(pRec, enc, 1);
    end;
    pRec^.flags := pRec^.flags and not u16(MEM_Real or MEM_Int or MEM_IntReal);
  end;
end;

{ sqlite3IntFloatCompare — compare i64 vs double.
  Port of vdbeaux.c:4551. Returns -1/0/+1 like memcmp. }
function sqlite3IntFloatCompare(i: i64; r: Double): i32;
var
  y: i64;
begin
  if sqlite3IsNaN(r) then begin
    Result := 1; { NaN treated as NULL; integers are greater than NULL }
    Exit;
  end;
  if r < -9223372036854775808.0 then begin Result := 1; Exit; end;
  if r >= 9223372036854775808.0 then begin Result := -1; Exit; end;
  y := Trunc(r);
  if i < y then begin Result := -1; Exit; end;
  if i > y then begin Result := 1; Exit; end;
  if Double(i) < r then Result := -1
  else if Double(i) > r then Result := 1
  else Result := 0;
end;

{ vdbeMemDynamic — needs to be visible to sqlite3VdbeExec }
function vdbeMemDynamic(p: PMem): Boolean; inline;
begin
  Result := (p^.flags and (MEM_Agg or MEM_Dyn)) <> 0;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeIdxRowid — extract rowid from index cursor (vdbeaux.c:5191)
  ----------------------------------------------------------------------- }
function sqlite3VdbeIdxRowid(db: PTsqlite3; pCur: PBtCursor; out rowid: i64): i32;
var
  nCellKey: i64;
  rc:       i32;
  szHdr:    u32;
  typeRowid: u32;
  lenRowid:  u32;
  pMem:      TMem;
  pV:        TMem;
begin
  nCellKey := i64(sqlite3BtreePayloadSize(pCur));
  sqlite3VdbeMemInit(@pMem, Psqlite3(db), 0);
  rc := sqlite3VdbeMemFromBtreeZeroOffset(pCur, u32(nCellKey), @pMem);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  szHdr := 0;
  { getVarint32 macro fast path: high-bit clear means single-byte varint. }
  if (Pu8(pMem.z)[0] and $80) = 0 then
    szHdr := u32(Pu8(pMem.z)[0])
  else
    sqlite3GetVarint32(Pu8(pMem.z), szHdr);
  if (szHdr < 3) or (szHdr > u32(pMem.n)) then begin
    sqlite3VdbeMemReleaseMalloc(@pMem);
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;
  typeRowid := 0;
  if (Pu8(pMem.z + szHdr - 1)[0] and $80) = 0 then
    typeRowid := u32(Pu8(pMem.z + szHdr - 1)[0])
  else
    sqlite3GetVarint32(Pu8(pMem.z + szHdr - 1), typeRowid);
  if (typeRowid < 1) or (typeRowid > 9) or (typeRowid = 7) then begin
    sqlite3VdbeMemReleaseMalloc(@pMem);
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;
  lenRowid := sqlite3VdbeSerialTypeLen(typeRowid);
  if u32(pMem.n) < szHdr + lenRowid then begin
    sqlite3VdbeMemReleaseMalloc(@pMem);
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;
  FillChar(pV, SizeOf(TMem), 0);
  sqlite3VdbeSerialGet(Pu8(pMem.z + pMem.n - i32(lenRowid)), typeRowid, @pV);
  rowid := pV.u.i;
  sqlite3VdbeMemReleaseMalloc(@pMem);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  vdbeColumnFromOverflow — read a column value from overflow pages
  Port of vdbe.c:719 (with RCStr-cached buffer for large TEXT/BLOB).
  ----------------------------------------------------------------------- }
function vdbeColumnFromOverflow(pC: PVdbeCursor; iCol: i32; t: u32;
    iOffset: i64; cacheStatus: u32; colCacheCtr: u32;
    pDest: PMem): i32;
var
  db:       PTsqlite3;
  encoding: u8;
  len:      i32;
  rc:       i32;
  pCache:   PVdbeTxtBlbCache;
  pBuf:     PAnsiChar;
begin
  db       := PTsqlite3(pDest^.db);
  encoding := pDest^.enc;
  len      := i32(sqlite3VdbeSerialTypeLen(t));
  if len > i32(Pu32(Pu8(db) + 136)^) then begin
    { SQLITE_LIMIT_LENGTH exceeded }
    Result := SQLITE_TOOBIG; Exit;
  end;
  if (len > 4000) and (pC^.pKeyInfo = nil) then begin
    { Large TEXT/BLOB on a table-btree: cache via RCStr so a re-read of
      the same column on the same row reuses the buffer (vdbe.c:735..). }
    if (pC^.cursorFlags and VDBC_ColCache) = 0 then begin
      pC^.pCache := PVdbeTxtBlbCache(sqlite3DbMallocZero(Psqlite3db(db),
                                          SizeOf(TVdbeTxtBlbCache)));
      if pC^.pCache = nil then begin Result := SQLITE_NOMEM; Exit; end;
      pC^.cursorFlags := pC^.cursorFlags or VDBC_ColCache;
    end;
    pCache := pC^.pCache;
    if (pCache^.pCValue = nil)
       or (pCache^.iCol <> iCol)
       or (pCache^.cacheStatus <> cacheStatus)
       or (pCache^.colCacheCtr <> colCacheCtr)
       or (pCache^.iOffset <> sqlite3BtreeOffset(pC^.uc.pCursor)) then begin
      if pCache^.pCValue <> nil then sqlite3RCStrUnref(pCache^.pCValue);
      pBuf := sqlite3RCStrNew(u64(len) + 3);
      pCache^.pCValue := pBuf;
      if pBuf = nil then begin Result := SQLITE_NOMEM; Exit; end;
      rc := sqlite3BtreePayload(pC^.uc.pCursor, u32(iOffset), u32(len), pBuf);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      pBuf[len]     := #0;
      pBuf[len + 1] := #0;
      pBuf[len + 2] := #0;
      pCache^.iCol        := iCol;
      pCache^.cacheStatus := cacheStatus;
      pCache^.colCacheCtr := colCacheCtr;
      pCache^.iOffset     := sqlite3BtreeOffset(pC^.uc.pCursor);
    end else
      pBuf := pCache^.pCValue;
    Assert(t >= 12);
    sqlite3RCStrRef(pBuf);
    if (t and 1) <> 0 then begin
      rc := sqlite3VdbeMemSetStr(pDest, pBuf, len, encoding,
                                 TxDelProc(@sqlite3RCStrUnref));
      pDest^.flags := pDest^.flags or MEM_Term;
    end else
      rc := sqlite3VdbeMemSetStr(pDest, pBuf, len, 0,
                                 TxDelProc(@sqlite3RCStrUnref));
  end else begin
    rc := sqlite3VdbeMemFromBtree(pC^.uc.pCursor, u32(iOffset), u32(len), pDest);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    sqlite3VdbeSerialGet(Pu8(pDest^.z), t, pDest);
    if ((t and 1) <> 0) and (pDest^.enc = SQLITE_UTF8) then begin
      if pDest^.szMalloc > pDest^.n then
        pDest^.z[pDest^.n] := #0;
      pDest^.flags := pDest^.flags or MEM_Term;
    end;
  end;
  pDest^.flags := pDest^.flags and not u16(MEM_Ephem);
  Result := rc;
end;

{ ============================================================================
  Phase 5.4d helpers — arithmetic, bitwise, comparison (vdbeaux.c / util.c)
  ============================================================================ }

{ sqlite3AddInt64 — add iB to *pA; return 1 on overflow, 0 on success. }
function sqlite3AddInt64(pA: Pi64; iB: i64): i32;
var iA: i64;
begin
  iA := pA^;
  if iB >= 0 then begin
    if (iA > 0) and (High(i64) - iA < iB) then begin Result := 1; Exit; end;
  end else begin
    if (iA < 0) and (-(iA + High(i64)) > iB + 1) then begin Result := 1; Exit; end;
  end;
  pA^ := iA + iB;
  Result := 0;
end;

{ sqlite3SubInt64 — subtract iB from *pA; return 1 on overflow. }
function sqlite3SubInt64(pA: Pi64; iB: i64): i32;
begin
  if iB = Low(i64) then begin
    if pA^ >= 0 then begin Result := 1; Exit; end;
    pA^ := pA^ - iB;
    Result := 0;
  end else
    Result := sqlite3AddInt64(pA, -iB);
end;

{ sqlite3MulInt64 — multiply *pA by iB; return 1 on overflow. }
function sqlite3MulInt64(pA: Pi64; iB: i64): i32;
var iA: i64;
begin
  iA := pA^;
  if iB > 0 then begin
    if (iA > High(i64) div iB) then begin Result := 1; Exit; end;
    if (iA < Low(i64) div iB) then begin Result := 1; Exit; end;
  end else if iB < 0 then begin
    if iA > 0 then begin
      if iB < Low(i64) div iA then begin Result := 1; Exit; end;
    end else if iA < 0 then begin
      if iB = Low(i64) then begin Result := 1; Exit; end;
      if iA = Low(i64) then begin Result := 1; Exit; end;
      if -iA > High(i64) div (-iB) then begin Result := 1; Exit; end;
    end;
  end;
  pA^ := iA * iB;
  Result := 0;
end;

{ numericType — return numeric flags of pMem without modifying it.
  Port of vdbe.c:467..490 (computeNumericType + numericType).
  The (rc and 2) = 0 guard rejects "has decimal point/exponent" parses
  from the integer arm — without it a string like '3.14abc' would
  truncate to integer 3 (C falls through to MEM_Real with rValue=3.14). }
function numericType(pMem: PMem): u16;
var iVal: i64; rcM: i32;
begin
  if (pMem^.flags and (MEM_Int or MEM_Real or MEM_IntReal or MEM_Null)) <> 0 then begin
    Result := pMem^.flags and (MEM_Int or MEM_Real or MEM_IntReal or MEM_Null);
    Exit;
  end;
  { computeNumericType (vdbe.c:467): the value is a Str/Blob.  Materialise any
    MEM_Zero padding FIRST so the subsequent writes into the pMem.u union do
    not clobber u.nZero (which shares the union slot) while MEM_Zero is still
    set — otherwise a zeroblob operand of an arithmetic op silently loses its
    trailing zero bytes (ticket bb4bdb9f7f654b0bb9). }
  if sqlite3VdbeMemExpandBlob(pMem) <> SQLITE_OK then begin
    pMem^.u.i := 0;
    Result := MEM_Int;
    Exit;
  end;
  rcM := sqlite3MemRealValueRC(pMem, pMem^.u.r);
  if rcM <= 0 then begin
    if ((rcM and 2) = 0) and
       (sqlite3Atoi64(pMem^.z, iVal, pMem^.n, pMem^.enc) <= 1) then begin
      pMem^.u.i := iVal;
      Result := MEM_Int;
    end else
      Result := MEM_Real;
  end else if ((rcM and 2) = 0) and
              (sqlite3Atoi64(pMem^.z, iVal, pMem^.n, pMem^.enc) = 0) then begin
    pMem^.u.i := iVal;
    Result := MEM_Int;
  end else
    Result := MEM_Real;
end;

{ sqlite3BlobCompare — compare two blob/binary Mem values.
  Port of vdbeaux.c:4508. }
function memIsAllZero(z: Pu8; n: i32): Boolean;
var i: i32;
begin
  for i := 0 to n - 1 do
    if z[i] <> 0 then begin Result := False; Exit; end;
  Result := True;
end;

function sqlite3BlobCompare(pB1, pB2: PMem): i32;
var n1, n2, c, nMin: i32;
begin
  n1 := pB1^.n;
  n2 := pB2^.n;
  if ((pB1^.flags or pB2^.flags) and MEM_Zero) <> 0 then begin
    if (pB1^.flags and pB2^.flags and MEM_Zero) <> 0 then begin
      Result := pB1^.u.nZero - pB2^.u.nZero; Exit;
    end else if (pB1^.flags and MEM_Zero) <> 0 then begin
      if not memIsAllZero(Pu8(pB2^.z), pB2^.n) then begin Result := -1; Exit; end;
      Result := pB1^.u.nZero - n2; Exit;
    end else begin
      if not memIsAllZero(Pu8(pB1^.z), pB1^.n) then begin Result := +1; Exit; end;
      Result := n1 - pB2^.u.nZero; Exit;
    end;
  end;
  if n1 < n2 then nMin := n1 else nMin := n2;
  if nMin > 0 then
    c := CompareByte(pB1^.z^, pB2^.z^, nMin)  { memcmp equivalent }
  else
    c := 0;
  if c <> 0 then begin Result := c; Exit; end;
  Result := n1 - n2;
end;

{ sqlite3VdbeCompareMemStringEncChg — port of vdbeaux.c:4450
  vdbeCompareMemStringWithEncodingChange.  Both input Mems carry
  string data in encodings that differ from pColl->enc; shallow-copy
  each into a local Mem, transcode via sqlite3ValueText(v,pColl->enc),
  call pColl->xCmp, then release.  On OOM (ValueText returns NULL)
  sets prcErr (if non-NULL) to SQLITE_NOMEM and returns 0. }
function sqlite3VdbeCompareMemStringEncChg(pMem1, pMem2: PMem;
                                           pColl: PTCollSeq;
                                           prcErr: Pu8): i32;
var
  c1, c2: TMem;
  v1, v2: Pointer;
begin
  sqlite3VdbeMemInit(@c1, pMem1^.db, MEM_Null);
  sqlite3VdbeMemInit(@c2, pMem1^.db, MEM_Null);
  sqlite3VdbeMemShallowCopy(@c1, pMem1, MEM_Ephem);
  sqlite3VdbeMemShallowCopy(@c2, pMem2, MEM_Ephem);
  v1 := sqlite3ValueText(Psqlite3_value(@c1), pColl^.enc);
  v2 := sqlite3ValueText(Psqlite3_value(@c2), pColl^.enc);
  if (v1 = nil) or (v2 = nil) then begin
    if prcErr <> nil then prcErr^ := SQLITE_NOMEM;
    Result := 0;
  end else begin
    Result := pColl^.xCmp(pColl^.pUser, c1.n, v1, c2.n, v2);
  end;
  sqlite3VdbeMemReleaseMalloc(@c1);
  sqlite3VdbeMemReleaseMalloc(@c2);
end;

{ sqlite3MemCompare — full typed comparison of two Mem values.
  Port of vdbeaux.c:4579. pColl=nil → memcmp for strings. }
function sqlite3MemCompare(pMem1, pMem2: PMem; pColl: Pointer): i32;
var f1, f2, cf: i32;
begin
  f1 := pMem1^.flags;
  f2 := pMem2^.flags;
  cf := f1 or f2;
  { NULL: less than anything; two NULLs equal }
  if (cf and MEM_Null) <> 0 then begin
    Result := (f2 and MEM_Null) - (f1 and MEM_Null);
    Exit;
  end;
  { At least one numeric }
  if (cf and (MEM_Int or MEM_Real or MEM_IntReal)) <> 0 then begin
    { Both int-like }
    if (f1 and f2 and (MEM_Int or MEM_IntReal)) <> 0 then begin
      if pMem1^.u.i < pMem2^.u.i then begin Result := -1; Exit; end;
      if pMem1^.u.i > pMem2^.u.i then begin Result := +1; Exit; end;
      Result := 0; Exit;
    end;
    { Both real }
    if (f1 and f2 and MEM_Real) <> 0 then begin
      if pMem1^.u.r < pMem2^.u.r then begin Result := -1; Exit; end;
      if pMem1^.u.r > pMem2^.u.r then begin Result := +1; Exit; end;
      Result := 0; Exit;
    end;
    { pMem1 is int, pMem2 is real }
    if (f1 and (MEM_Int or MEM_IntReal)) <> 0 then begin
      if (f2 and MEM_Real) <> 0 then begin
        Result := sqlite3IntFloatCompare(pMem1^.u.i, pMem2^.u.r); Exit;
      end else if (f2 and (MEM_Int or MEM_IntReal)) <> 0 then begin
        if pMem1^.u.i < pMem2^.u.i then begin Result := -1; Exit; end;
        if pMem1^.u.i > pMem2^.u.i then begin Result := +1; Exit; end;
        Result := 0; Exit;
      end else begin
        Result := -1; Exit;  { number < string }
      end;
    end;
    { pMem1 is real }
    if (f1 and MEM_Real) <> 0 then begin
      if (f2 and (MEM_Int or MEM_IntReal)) <> 0 then begin
        Result := -sqlite3IntFloatCompare(pMem2^.u.i, pMem1^.u.r); Exit;
      end else begin
        Result := -1; Exit;  { number < string }
      end;
    end;
    Result := +1; Exit;
  end;
  { String comparison }
  if (cf and MEM_Str) <> 0 then begin
    if (f1 and MEM_Str) = 0 then begin Result := 1; Exit; end;
    if (f2 and MEM_Str) = 0 then begin Result := -1; Exit; end;
    { Collation-aware compare (vdbeaux.c:4659..4661, vdbeCompareMemString
      same-encoding arm).  pColl=nil falls through to blob compare. }
    if pColl <> nil then begin
      Assert(Assigned(PTCollSeq(pColl)^.xCmp));
      if pMem1^.enc = PTCollSeq(pColl)^.enc then begin
        Result := PTCollSeq(pColl)^.xCmp(PTCollSeq(pColl)^.pUser,
                                          pMem1^.n, pMem1^.z,
                                          pMem2^.n, pMem2^.z);
        Exit;
      end;
      { Encoding-change arm — port of vdbeaux.c:4450
        vdbeCompareMemStringWithEncodingChange.  Shallow-copy both Mems,
        transcode via sqlite3ValueText(v, pColl->enc), then xCmp + release. }
      Result := sqlite3VdbeCompareMemStringEncChg(pMem1, pMem2,
                                                   PTCollSeq(pColl), nil);
      Exit;
    end;
    { no collation: fall through to blob compare (memcmp) }
  end;
  Result := sqlite3BlobCompare(pMem1, pMem2);
end;

{ ============================================================================
  sqlite3CloseSavepoints — free the db->pSavepoint linked list (sqliteInt.h)
  ============================================================================ }
procedure sqlite3CloseSavepoints(pDb: PTsqlite3);
var
  pSvpt: PSavepoint;
  pNext: PSavepoint;
begin
  pSvpt := pDb^.pSavepoint;
  while pSvpt <> nil do begin
    pNext := pSvpt^.pNext;
    sqlite3DbFree(pDb, pSvpt);
    pSvpt := pNext;
  end;
  pDb^.pSavepoint              := nil;
  pDb^.nSavepoint              := 0;
  pDb^.isTransactionSavepoint  := 0;
end;

{ ============================================================================
  sqlite3RollbackAll — port of main.c:1483.

  Roll back every attached btree, then handle schema-change rollback,
  reset deferred-FK counters, clear DeferFKs / CorruptRdOnly flags,
  and invoke the optional xRollbackCallback.

  Deviations from the C reference (documented at the port site):
    * sqlite3BtreeEnterAll / sqlite3BtreeLeaveAll are no-ops in this
      OMIT_SHARED_CACHE port — same surface as C macros under the same
      gate.
    * Pas legacy-port behaviour: this procedure historically also set
      pDb^.autoCommit := 1.  Upstream sets autoCommit elsewhere
      (sqlite3VdbeHalt's special-error arm and OP_AutoCommit).  The
      autoCommit assignment is retained here to preserve OP_AutoCommit's
      observable behaviour while the full sqlite3VdbeHalt port is still
      pending — without it, an immediate `BEGIN; ROLLBACK` cycle would
      leave autoCommit unchanged and break the DiagTxn corpus.
  ============================================================================ }
procedure sqlite3RollbackAll(pDb: PTsqlite3; tripCode: i32);
var
  ii:           i32;
  pBt:          PBtree;
  inTrans:      i32;
  schemaChange: i32;
  unwind:       i32;
begin
  inTrans := 0;
  sqlite3BeginBenignMalloc;
  schemaChange := 0;
  if ((pDb^.mDbFlags and DBFLAG_SchemaChange) <> 0)
     and (pDb^.init.busy = 0) then
    schemaChange := 1;
  if schemaChange <> 0 then unwind := 0 else unwind := 1;
  for ii := 0 to pDb^.nDb - 1 do begin
    pBt := PBtree(pDb^.aDb[ii].pBt);
    if pBt <> nil then begin
      if sqlite3BtreeTxnState(pBt) = SQLITE_TXN_WRITE then
        inTrans := 1;
      sqlite3BtreeRollback(pBt, tripCode, unwind);
    end;
  end;
  sqlite3VtabRollback(pDb);
  sqlite3EndBenignMalloc;
  if schemaChange <> 0 then begin
    sqlite3ExpirePreparedStatements(pDb, 0);
    sqlite3ResetAllSchemasOfConnection(pDb);
  end;
  pDb^.nDeferredCons    := 0;
  pDb^.nDeferredImmCons := 0;
  pDb^.flags := pDb^.flags and not (SQLITE_DeferFKs or SQLITE_CorruptRdOnly);
  if Assigned(pDb^.xRollbackCallback)
     and ((inTrans <> 0) or (pDb^.autoCommit = 0)) then
    pDb^.xRollbackCallback(pDb^.pRollbackArg);
  pDb^.autoCommit := 1;
end;

{ ============================================================================
  sqlite3VdbeExec — Phase 5.4a+5.4b+5.4c+5.4d implementation
  Source: vdbe.c sqlite3VdbeExec (SQLite 3.53.0)

  Ported opcodes (5.4a):
    OP_Init, OP_Goto, OP_Gosub, OP_Return, OP_InitCoroutine,
    OP_EndCoroutine, OP_Yield, OP_Halt, OP_Integer, OP_Int64, OP_Null,
    OP_SoftNull, OP_Blob, OP_Move, OP_SCopy, OP_IntCopy, OP_Copy,
    OP_ResultRow, OP_Jump, OP_If, OP_IfNot, OP_OpenRead, OP_OpenWrite,
    OP_Close.
  Ported opcodes (5.4b — cursor motion):
    OP_Rewind, OP_Next, OP_Prev, OP_SorterNext,
    OP_SeekLT, OP_SeekLE, OP_SeekGE, OP_SeekGT,
    OP_Found, OP_NotFound, OP_NoConflict, OP_IfNoHope,
    OP_SeekRowid, OP_NotExists,
    OP_IdxLE, OP_IdxGT, OP_IdxLT, OP_IdxGE.
  Ported opcodes (5.4c — record I/O):
    OP_Column, OP_MakeRecord, OP_Count, OP_Rowid, OP_NullRow, OP_SeekEnd,
    OP_NewRowid, OP_Insert, OP_Delete, OP_ResetCount,
    OP_IdxInsert, OP_IdxDelete, OP_IdxRowid, OP_DeferredSeek, OP_FinishSeek.
  Ported opcodes (5.4d — arithmetic / comparison):
    OP_Add, OP_Subtract, OP_Multiply, OP_Divide, OP_Remainder,
    OP_BitAnd, OP_BitOr, OP_ShiftLeft, OP_ShiftRight, OP_AddImm,
    OP_Eq, OP_Ne, OP_Lt, OP_Le, OP_Gt, OP_Ge.
  Ported opcodes (5.4e — string/blob):
    OP_String8, OP_String, OP_Concat.
  All other opcodes: fall to default → SQLITE_ERROR abort.
  ============================================================================ }

function sqlite3VdbeExec(v: PVdbe): i32;
label
  jump_to_p2_and_check_for_interrupt,
  jump_to_p2,
  check_for_interrupt,
  abort_due_to_error,
  vdbe_return,
  too_big,
  no_mem,
  abort_due_to_interrupt,
  open_cursor_set_hints,
  next_tail,
  seek_not_found,
  notExistsWithKey,
  op_column_restart,
  op_column_read_header,
  op_column_out,
  op_column_corrupt,
  arith_fp,
  arith_null,
  arith_done,
  cmp_jump,
  cmp_done,
  agg_step1_body,
  op_program_run,
  op_function_body;
type
  { 6.bis.3b — typed function-pointer aliases for vtab module callbacks.
    The Tsqlite3_module record stores most slots as Pointer; we cast at
    the call site to obtain the proper cdecl signature. }
  TxOpenFnV     = function(pVtab: passqlite3vtab.PSqlite3Vtab;
                           ppCursor: passqlite3vtab.PPSqlite3VtabCursor): i32; cdecl;
  TxCloseFnV    = function(pCur: passqlite3vtab.PSqlite3VtabCursor): i32; cdecl;
  TxFilterFnV   = function(pCur: passqlite3vtab.PSqlite3VtabCursor;
                           idxNum: i32; idxStr: PAnsiChar;
                           argc: i32; argv: PPMem): i32; cdecl;
  TxNextFnV     = function(pCur: passqlite3vtab.PSqlite3VtabCursor): i32; cdecl;
  TxEofFnV      = function(pCur: passqlite3vtab.PSqlite3VtabCursor): i32; cdecl;
  TxColumnFnV   = function(pCur: passqlite3vtab.PSqlite3VtabCursor;
                           pCtx: Psqlite3_context; iCol: i32): i32; cdecl;
  TxRowidFnV    = function(pCur: passqlite3vtab.PSqlite3VtabCursor;
                           pRowid: Pi64): i32; cdecl;
  TxRenameFnV   = function(pVtab: passqlite3vtab.PSqlite3Vtab;
                           zNew: PAnsiChar): i32; cdecl;
  TxUpdateFnV   = function(pVtab: passqlite3vtab.PSqlite3Vtab;
                           argc: i32; argv: PPMem; pRowid: Pi64): i32; cdecl;
  TxIntegrityFnV= function(pVtab: passqlite3vtab.PSqlite3Vtab;
                           zSchema, zTabName: PAnsiChar; mFlags: i32;
                           pzErr: PPAnsiChar): i32; cdecl;
var
  aOp:   PVdbeOp;
  pOp:   PVdbeOp;
  rc:    i32;
  db:    PTsqlite3;
  enc:   u8;
  iCompare: i32;
  nVmStep: u64;
  aMem:  PMem;
  pIn1:  PMem;
  pIn2:  PMem;
  pIn3:  PMem;
  pOut:  PMem;
  colCacheCtr: u32;
  resetSchemaOnFault: u8;
  nProgressLimit: u64;
  { locals for individual opcodes }
  pcx:     i32;
  pFrame:  PVdbeFrame;
  p2:      u32;
  iDb:     i32;
  nField:  i32;
  wrFlag:  i32;
  pCur:    PVdbeCursor;
  pSrcCur: PVdbeCursor;  { OP_RowCell source cursor }
  pDbb:    PDb;      { renamed: pDb conflicts with PDb type (FPC case-insensitive) }
  pX:      PBtree;
  pKInfo:  PKeyInfo; { renamed: pKeyInfo conflicts with PKeyInfo type }
  zErr:    PAnsiChar;
  zTrcStmt: PAnsiChar;  { OP_Init/OP_Trace stmt-trace string }
  zTrcDup:  PAnsiChar;  { "-- %s" wrap for nested-exec trace }
  nByte:   i32;
  n:       i32;
  i:       i32;
  pDest:   PMem;
  pSrc:    PMem;
  { 5.4b locals }
  pCrsr:   PBtCursor;
  res:     i32;
  oc:      i32;
  eqOnly:  i32;
  nFld:    i32;
  iKey:    u64;
  flags3:  u16;
  newType: u16;
  c:       i32;
  rSeek:   TUnpackedRecord;
  pIdxKey: ^TUnpackedRecord;
  alreadyExists: i32;
  ii:      i32;
  nCellKey: i64;
  pMem5b:  TMem;
  { OP_Filter / OP_FilterAdd locals }
  hFilter: u64;
  mxFilter: i32;
  pMemFilter: PMem;
  { 5.4c locals — record I/O }
  pCol:    PVdbeCursor;   { OP_Column: cursor being read }
  p2col:   u32;           { OP_Column: column index }
  iAltMap: u32;           { OP_Column: index-alias map entry (vdbe.c:3025) }
  aOffset: Pu32;          { OP_Column: aOffset array pointer }
  lenCol:  i32;           { OP_Column: data length }
  zData:   Pu8;           { OP_Column: pointer into page data }
  zHdrC:   Pu8;           { OP_Column: next unparsed header byte }
  zEndHdr: Pu8;           { OP_Column: end of header }
  offset64: u64;          { OP_Column: 64-bit offset accumulator }
  tCol:    u32;           { OP_Column: serial type code }
  pRegCol: PMem;          { OP_Column: pseudo-table register }
  sMemCol: TMem;          { OP_Column: scratch Mem for header read }
  pRec:    PMem;          { OP_MakeRecord: current record Mem }
  nData:   u64;           { OP_MakeRecord: data byte count }
  nHdr:    i32;           { OP_MakeRecord: header byte count }
  nByteMR: i64;           { OP_MakeRecord: total byte count }
  nZeroMR: i64;           { OP_MakeRecord: trailing zero bytes }
  nVarint: i32;           { OP_MakeRecord: varint size }
  serial_type: u32;       { OP_MakeRecord: current serial type }
  pData0:  PMem;          { OP_MakeRecord: first field }
  pLastMR: PMem;          { OP_MakeRecord: last field }
  nFieldMR: i32;          { OP_MakeRecord: field count }
  zAffMR:  PAnsiChar;     { OP_MakeRecord: affinity string }
  lenMR:   u32;           { OP_MakeRecord: field length }
  zHdrMR:  Pu8;           { OP_MakeRecord: header write pointer }
  zPayMR:  Pu8;           { OP_MakeRecord: payload write pointer }
  vMR:     u64;           { OP_MakeRecord: integer value bits }
  uuMR:    u64;           { OP_MakeRecord: unsigned int for size computation }
  ivMR:    i64;           { OP_MakeRecord: signed int for size computation }
  seekRes: i32;           { OP_Insert: prior seek result }
  xPay:    TBtreePayload; { OP_Insert/IdxInsert: payload descriptor }
  opflags: i32;           { OP_Delete: opcode flags from P2 }
  zHookDb:  PAnsiChar;        { OP_Insert/Delete: db name for update hook }
  pHookTab: PTableHookFields; { OP_Insert/Delete: table for update hook }
  vRow:    i64;           { OP_NewRowid/OP_Rowid: rowid value }
  cntNR:   i32;           { OP_NewRowid: retry counter }
  nEntry:  i64;           { OP_Count: entry count }
  rowid54: i64;           { OP_IdxRowid/DeferredSeek: rowid }
  pTabCur: PVdbeCursor;   { OP_DeferredSeek: table cursor }
  { 5.4h locals — misc opcodes }
  v1h:  i32;                  { OP_And/Or: left boolean value }
  v2h:  i32;                  { OP_And/Or: right boolean value }
  typeMaskH: u16;             { OP_IsType: type bitmask }
  serialTypeH: u32;           { OP_IsType: serial type from cursor header }
  pVarH: PMem;                { OP_Variable: variable Mem pointer }
  { 5.4g locals — transaction control }
  iMeta5g:     i32;           { OP_Transaction: btree cookie }
  pSvpt5g:     PSavepoint;    { OP_Savepoint: iterator / found savepoint }
  pNewSvpt5g:  PSavepoint;    { OP_Savepoint: newly-allocated savepoint }
  zSvptName5g: PAnsiChar;     { OP_Savepoint: savepoint name }
  zSvptFmtMsg5g: PAnsiChar;   { OP_Savepoint: formatted "no such savepoint: <name>" }
  nSvptName5g: i32;           { OP_Savepoint: name length }
  iSvpt5g:     i32;           { OP_Savepoint: depth counter }
  isTxnSvpt5g: i32;           { OP_Savepoint: is this a transaction savepoint? }
  iSvptii5g:   i32;           { OP_Savepoint: per-db loop index }
  isSchemaChange5g: i32;      { OP_Savepoint: schema-change flag }
  pTmpSvpt5g:  PSavepoint;    { OP_Savepoint: temporary for nested-savepoint pop }
  desiredAC5g: i32;           { OP_AutoCommit: desired autocommit state }
  iRollback5g: i32;           { OP_AutoCommit: rollback flag }
  { 5.4f locals — aggregate }
  pCtxAgg: Psqlite3_context;  { OP_AggStep: context being set up }
  pFdAgg:  PTFuncDef;         { OP_AggStep1: typed FuncDef pointer }
  { 5.4d locals — arithmetic / comparison }
  type1d:  u16;           { OP_Add/Sub/Mul/Div/Rem: numeric type of p1 }
  type2d:  u16;           { OP_Add/Sub/Mul/Div/Rem: numeric type of p2 }
  iAd:     i64;           { OP_Add/Sub/Mul/Div/Rem: left operand int }
  iBd:     i64;           { OP_Add/Sub/Mul/Div/Rem: right operand int }
  rAd:     Double;        { OP_Add/Sub/Mul/Div/Rem: left operand real }
  rBd:     Double;        { OP_Add/Sub/Mul/Div/Rem: right operand real }
  opBd:    u8;            { OP_ShiftLeft/Right: opcode byte }
  uAd:     u64;           { OP_ShiftLeft/Right: unsigned intermediate }
  flags1d: u16;           { OP_Eq/.../Ge: saved pIn1 flags }
  flags3d: u16;           { OP_Eq/.../Ge: saved pIn3 flags }
  resd:    i32;           { OP_Eq/.../Ge: compare result }
  res2d:   i32;           { OP_Eq/.../Ge: jump decision }
  affd:    u8;            { OP_Eq/.../Ge: affinity byte }
  { 5.4i locals — ephemeral / pseudo cursor open }
  pgnoEph: Pgno;          { OP_OpenEphemeral: CreateTable result page number }
  pOrig:   PVdbeCursor;   { OP_OpenDup: original (source) cursor }
  { 5.4j/k/l/m/n/o/q locals — new opcode groups }
  r:        TUnpackedRecord;  { OP_SeekScan: key to compare }
  nStep:    i32;              { OP_SeekScan: steps remaining }
  iSz:      i64;              { OP_IfSizeBetween: log estimate }
  p1reg:    i32;              { OP_Compare: P1 base register }
  p2reg:    i32;              { OP_Compare: P2 base register }
  idx:      u32;              { OP_Compare: permuted index }
  aPermute: Pu32;             { OP_Compare: permutation array }
  iCompareIsInit: i32;        { OP_Compare/ElseEq: init flag }
  bRevCol:  Boolean;          { OP_Compare: DESC flag }
  bBigNull: Boolean;          { OP_Compare: BIGNULL flag }
  pCS:      PCollSeq;         { OP_Compare: collating sequence }
  nKeyCol:  i32;              { OP_SorterCompare: # key cols }
  nChange:  i64;              { OP_Clear: change count }
  iMoved:   i32;              { OP_Destroy: moved-to page }
  newPgno:  Pgno;             { OP_CreateBtree: new page number }
  pDbRec:   PDb;              { OP_SetCookie/CreateBtree: db slot }
  pProgSub: PSubProgram;      { OP_Program: sub-program }
  pRtMem:   PMem;             { OP_Program: runtime memory }
  nProgMem: i32;              { OP_Program: # child mem cells }
  nByteProg: i64;             { OP_Program: alloc size }
  pFrameTok: Pointer;         { OP_Program: recursive trigger token }
  pMemEnd:   PMem;            { OP_Program: mem init loop }
  i64Val:   i64;              { OP_RowSetRead: extracted value }
  iSet:     i32;              { OP_RowSetTest: batch number }
  exists:   i32;              { OP_RowSetTest: membership result }
  xLim:     i64;              { OP_OffsetLimit: combined limit }
  xOfs:     i64;              { OP_OffsetLimit: clamped offset (max(0,r[P3])) }
  newMax:   Pgno;             { OP_MaxPgcnt: new max page count }
  pBtArg:   PBtree;           { OP_MaxPgcnt/Pagecount: btree }
  { 6.bis.3a locals — vtab opcode wiring }
  pVTabRef:    passqlite3vtab.PVTable;  { OP_VBegin/VCreate/VDestroy: VTable* from p4 }
  sMemVCreate: TMem;                    { OP_VCreate: scratch Mem for table-name copy }
  zVTabName:   PAnsiChar;               { OP_VCreate: text of table name }
  { 6.bis.3b locals — cursor-bearing vtab opcodes }
  pVCurC:      passqlite3vtab.PSqlite3VtabCursor;  { vtab cursor (uc.pVCur cast) }
  pVtabC:      passqlite3vtab.PSqlite3Vtab;        { sqlite3_vtab* (pVCur^.pVtab) }
  pModC:       passqlite3vtab.PSqlite3Module;      { module pointer-table }
  sCtxV:       Tsqlite3_context;        { OP_VColumn: stack-allocated context }
  nullFnV:     TFuncDef;                { OP_VColumn: synthetic FuncDef }
  apArgV:      array of PMem;           { OP_VFilter/VUpdate: argv buffer }
  iVRow:       i64;                     { OP_VUpdate: out rowid }
  iLegacyV:    i32;                     { OP_VRename: SQLITE_LegacyAlter saved bit }
  zErrIntV:    PAnsiChar;               { OP_VCheck: integrity error msg }
  pTabIntV:    Pointer;                 { OP_VCheck: Table* from p4 }
  pVTblIntV:   passqlite3vtab.PVTable;  { OP_VCheck: per-conn VTable }
  iQueryV:     i32;                     { OP_VFilter: idx number }
  nArgV:       i32;                     { OP_VFilter/VUpdate: arg count }
  resV:        i32;                     { OP_VFilter/VNext: xEof result }
  iV:          i32;                     { vtab opcode loop var }
  pRhsV:       PValueList;              { OP_VInitIn: ValueList object }
  pNameMem:    PMem;                    { OP_VRename: name register }
  pVCurNew:    passqlite3vtab.PSqlite3VtabCursor;  { OP_VOpen: xOpen out param }
  { OP_SqlExec locals (vdbe.c:7064) }
  sqlExecErr:                 PAnsiChar;
  sqlExecXAuth:               Pointer;
  sqlExecMTrace:              u8;
  sqlExecSavedAnalysisLimit:  i32;
  { OP_Checkpoint locals (vdbe.c:8015) — inlined sqlite3Checkpoint loop. }
  aResCk:    array[0..2] of i32;
  pnLogCk:   Pi32;
  pnCkptCk:  Pi32;
  bBusyCk:   i32;
  rcCk:      i32;
  iCk:       i32;
  { OP_JournalMode locals (vdbe.c:8054) }
  jmEnew:      i32;
  jmEold:      i32;
  jmBt:        PBtree;
  jmPager:     PPager;
  jmZFilename: PChar;
  { OP_IntegrityCk locals (vdbe.c:7263) }
  icRoot:    PPgno;
  icRowCnt:  Pi64;
  icpnErr:   PMem;
  icpzOut:   PAnsiChar;
  icnRoot:   i32;
  icnErr:    i32;
  icIdx:     i32;
  {$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}
  { Phase 10.1.39.d.3 — hwtime cycle bracket around the dispatch loop.
    pCycleOp pins the opcode being measured (in case the body mutates pOp
    via jump arms); t0Cycle is the start TSC sample. }
  pCycleOp: PVdbeOp;
  t0Cycle:  u64;
  {$ENDIF}
  { OP_TypeCheck locals (vdbe.c:3305) — 9.4.divbug.71.
    PTable is an opaque Pointer in vdbe.pas; we reach into TTable/TColumn
    via the byte-offset pattern used elsewhere in this file (sizeof TColumn
    = 16, TTable fields zName@0, aCol@8, nCol@54). }
  pTabBaseTC: Pu8;            { TTable base pointer }
  aColBaseTC: Pu8;            { aCol base pointer (=pTabBaseTC + 8 deref) }
  pColTC:     Pu8;            { current TColumn entry }
  zTabNameTC: PAnsiChar;
  zColNameTC: PAnsiChar;
  iTC, nColTC, eCTypeTC: i32;
  affTC:      u8;
  colFlagsTC: u16;
  typeFlagsTC: u8;
  zMemTypeTC: PAnsiChar;
  zStdTypeTC: PAnsiChar;
  zErrMsgTC:  PAnsiChar;
begin
  aOp    := v^.aOp;
  pOp    := @aOp[v^.pc];
  rc     := SQLITE_OK;
  db     := PTsqlite3(v^.db);
  enc    := db^.enc;
  iCompare := 0;
  nVmStep  := 0;
  aMem     := v^.aMem;
  pIn1  := nil;
  pIn2  := nil;
  pIn3  := nil;
  pOut  := nil;
  colCacheCtr := 0;
  resetSchemaOnFault := 0;
  nProgressLimit := u64($FFFFFFFFFFFFFFFF);

  { Check initial state }
  if v^.lockMask <> 0 then  { DbMaskNonZero }
    sqlite3VdbeEnter(v);

  if db^.xProgress <> nil then begin
    nProgressLimit := db^.nProgressOps - (v^.aCounter[SQLITE_STMTSTATUS_VM_STEP] mod db^.nProgressOps);
  end;

  if v^.rc = SQLITE_NOMEM then goto no_mem;
  v^.rc := SQLITE_OK;
  v^.iCurrentTime := 0;
  db^.busyHandler.nBusy := 0;
  if db^.u1.isInterrupted <> 0 then goto abort_due_to_interrupt;

  { ── Main interpreter loop ── }
  {$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}
  pCycleOp := nil;
  t0Cycle  := 0;
  {$ENDIF}
  repeat
    {$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}
    { Phase 10.1.39.d.3 — close out the previous op's cycle window.
      Mirrors vdbe.c:9249..9252 (the `if(pnCycle){ *pnCycle += sqlite3Hwtime(); }`
      epilogue) — but since we accumulate at loop-top rather than loop-bottom
      we can credit any continue/goto exit without per-continue stamping. }
    if pCycleOp <> nil then begin
      pCycleOp^.nCycle := pCycleOp^.nCycle + (sqlite3Hwtime - t0Cycle);
      pCycleOp := nil;
    end;
    {$ENDIF}
    Inc(nVmStep);

    { Phase 8.2.1 — bump per-op execution counter for
      sqlite3_stmt_scanstatus() (vdbe.c:940 `pOp->nExec++`).  nCycle
      hwtime sampling is bracketed below under SQLITE_ENABLE_STMT_SCANSTATUS. }
    Inc(pOp^.nExec);

    { Phase 9.1.6 — opcode coverage hook.  Single predictable branch
      that compiles to a near-zero-cost no-op when the flag is off
      (default).  Tests that need coverage flip gVdbeOpCoverageEnabled
      to 1 before driving the workload. }
    if gVdbeOpCoverageEnabled <> 0 then begin
      if (pOp^.opcode >= 0) and (pOp^.opcode < SQLITE_NUM_OPCODES) then
        Inc(gVdbeOpCoverage[pOp^.opcode]);
    end;
    {$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}
    { Phase 10.1.39.d.3 — start cycle window.  Mirrors vdbe.c:944..948
      (`pnCycle = &pOp->nCycle; *pnCycle -= sqlite3Hwtime();`).  We stash
      pOp itself rather than &pOp->nCycle because Pascal opcodes that
      mutate pOp (jump arms) still need the *original* op to be debited. }
    pCycleOp := pOp;
    t0Cycle  := sqlite3Hwtime;
    {$ENDIF}

    { Phase 7.4c — opcode-trace capture (mirrors C sqlite3VdbePrintOp call
      gated by db->flags & SQLITE_VdbeTrace at vdbe.c:954). }
    if (db^.flags and SQLITE_VdbeTrace) <> 0 then
      gVdbeTraceBuf := gVdbeTraceBuf
        + Format('%d %s %d %d %d %.2x'#10,
                 [i32(pOp - aOp), sqlite3OpcodeName(pOp^.opcode),
                  pOp^.p1, pOp^.p2, pOp^.p3, pOp^.p5]);

    {$IFDEF SQLITE_TEST}
    { Check to see if we need to simulate an interrupt.  This only happens
      if we have a special test build (vdbe.c:961..971). }
    if sqlite3_interrupt_count > 0 then begin
      Dec(sqlite3_interrupt_count);
      if sqlite3_interrupt_count = 0 then
        db^.u1.isInterrupted := 1;   { = sqlite3_interrupt(db); inlined to avoid uses cycle }
    end;
    {$ENDIF}

    { Dispatch }
    case pOp^.opcode of

    { ────── OP_Goto ────── (vdbe.c:1063) }
    OP_Goto: begin
      goto jump_to_p2_and_check_for_interrupt;
    end;

    { ────── OP_Gosub ────── (vdbe.c:1119) }
    OP_Gosub: begin
      pIn1 := @aMem[pOp^.p1];
      pIn1^.flags := MEM_Int;
      pIn1^.u.i   := i64(pOp - aOp);
      goto jump_to_p2_and_check_for_interrupt;
    end;

    { ────── OP_Return ────── (vdbe.c:1152) }
    OP_Return: begin
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and MEM_Int) <> 0 then
        pOp := @aOp[pIn1^.u.i]
      { else: p3≠0 case — fall through (no jump), just break }
    end;

    { ────── OP_InitCoroutine ────── (vdbe.c:1174) }
    OP_InitCoroutine: begin
      pOut := @aMem[pOp^.p1];
      pOut^.u.i   := i64(pOp^.p3 - 1);
      pOut^.flags := MEM_Int;
      if pOp^.p2 <> 0 then goto jump_to_p2;
    end;

    { ────── OP_EndCoroutine ────── (vdbe.c:1203) }
    OP_EndCoroutine: begin
      { Faithful port of vdbe.c:1203..1213.  pIn1^.u.i holds the
        address of the most-recent OP_Yield that resumed this
        coroutine; jump to that Yield's p2 (addrEnd) so the outer
        scan exits its loop.  Save this EndCoroutine - 1 in pIn1
        so any later Yield against this regReturn lands back here
        and re-jumps to the same addrEnd. }
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and MEM_Int) <> 0 then begin
        pcx := i32(pOp - aOp);  { addr of this EndCoroutine }
        pOp := @aOp[aOp[pIn1^.u.i].p2 - 1];
        pIn1^.u.i := i64(pcx) - 1;
      end;
    end;

    { ────── OP_Yield ────── (vdbe.c:1229) }
    OP_Yield: begin
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and MEM_Int) <> 0 then begin
        pcx := i32(pOp - aOp);
        pOp := @aOp[pIn1^.u.i];
        pIn1^.u.i := i64(pcx);
      end;
    end;

    { ────── OP_Halt ────── (vdbe.c:1293) }
    OP_Halt: begin
      if (v^.pFrame <> nil) and (pOp^.p1 = SQLITE_OK) then begin
        pFrame := v^.pFrame;
        v^.pFrame  := pFrame^.pParent;
        v^.nFrame  := v^.nFrame - 1;
        sqlite3VdbeSetChanges(db, v^.nChange);
        pcx := sqlite3VdbeFrameRestoreFull(pFrame);
        if pOp^.p2 = OE_Ignore then
          pcx := v^.aOp[pcx].p2 - 1;
        aOp := v^.aOp;
        aMem := v^.aMem;
        pOp := @aOp[pcx];
      end else begin
        v^.rc := pOp^.p1;
        v^.errorAction := u8(pOp^.p2);
        if v^.rc <> 0 then begin
          if (pOp^.p3 > 0) and (pOp^.p4type = P4_NOTUSED) then begin
            zErr := sqlite3ValueText(@aMem[pOp^.p3], SQLITE_UTF8);
            sqlite3VdbeError(v, zErr);
          end else if pOp^.p5 <> 0 then begin
            case pOp^.p5 of
              1: sqlite3VdbeError(v, 'NOT NULL constraint failed');
              2: sqlite3VdbeError(v, 'UNIQUE constraint failed');
              3: sqlite3VdbeError(v, 'CHECK constraint failed');
              4: sqlite3VdbeError(v, 'FOREIGN KEY constraint failed');
            else sqlite3VdbeError(v, 'constraint failed');
            end;
            if pOp^.p4.z <> nil then
              v^.zErrMsg := sqlite3MPrintf(db, '%z: %s',
                              [v^.zErrMsg, pOp^.p4.z]);
          end else begin
            sqlite3VdbeError(v, pOp^.p4.z);
          end;
          sqlite3VdbeLogAbort(v, pOp^.p1, pOp, aOp);
        end;
        rc := sqlite3VdbeHalt(v);
        if rc = SQLITE_BUSY then begin
          v^.rc := SQLITE_BUSY;
        end else begin
          if v^.rc <> 0 then rc := SQLITE_ERROR
          else rc := SQLITE_DONE;
        end;
        goto vdbe_return;
      end;
    end;

    { ────── OP_Integer ────── (vdbe.c:1371) }
    OP_Integer: begin
      pOut := out2Prerelease(v, pOp);
      pOut^.u.i := i64(pOp^.p1);
    end;

    { ────── OP_Int64 ────── (vdbe.c:1383) }
    OP_Int64: begin
      pOut := out2Prerelease(v, pOp);
      pOut^.u.i := pOp^.p4.pI64^;
    end;

    { ────── OP_Null / OP_BeginSubrtn ────── (vdbe.c:1511) }
    OP_BeginSubrtn,
    OP_Null: begin
      n := pOp^.p3 - pOp^.p2;
      pOut := @aMem[pOp^.p2];
      pOut^.flags := MEM_Null;
      if n > 0 then begin
        i := 0;
        while i < n do begin
          Inc(i);
          pDest := @aMem[pOp^.p2 + i];
          pDest^.flags := MEM_Null;
        end;
      end;
    end;

    { ────── OP_SoftNull ────── (vdbe.c:1542) }
    OP_SoftNull: begin
      pOut := @aMem[pOp^.p1];
      pOut^.flags := MEM_Null or MEM_Cleared;
    end;

    { ────── OP_Blob ────── (vdbe.c:1556) }
    OP_Blob: begin
      pOut := out2Prerelease(v, pOp);
      nByte := pOp^.p1;
      if nByte > SQLITE_MAX_LENGTH then goto too_big;
      sqlite3VdbeMemSetStr(pOut, pOp^.p4.z, nByte, 0, SQLITE_TRANSIENT);
      pOut^.enc := enc;
      rc := sqlite3VdbeMemTooBig(pOut);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      UpdateMaxBlobsize(pOut);   { vdbe.c:1566 }
    end;

    { ────── OP_String8 / OP_String ────── (vdbe.c:1414/1458)
      P4.z = string literal, P1 = byte length, P2 = output register, enc = P4 enc.
      OP_String8 converts itself to OP_String on first execution. }
    OP_String8: begin
      Assert(pOp^.p4.z <> nil);
      pOut := out2Prerelease(v, pOp);
      pOp^.p1 := sqlite3Strlen30(PChar(pOp^.p4.z));
      { vdbe.c:1419..1436 — when db's enc is UTF-16 we must convert the
        literal UTF-8 bytes to native encoding once, then rewrite p4.z to
        point at the converted buffer so subsequent OP_String fires reuse
        it as MEM_Static.  Required so column_text sees the bytes in
        db^.enc (otherwise UTF-8 bytes carry an enc=UTF-16 tag and
        column_text returns garbled output).  9.2.divbug.G. }
      if enc <> SQLITE_UTF8 then begin
        rc := sqlite3VdbeMemSetStr(pOut, pOp^.p4.z, -1, SQLITE_UTF8, SQLITE_STATIC);
        if rc <> SQLITE_OK then goto too_big;
        if sqlite3VdbeChangeEncoding(pOut, enc) <> SQLITE_OK then goto no_mem;
        Assert(pOut^.szMalloc > 0);
        pOut^.szMalloc := 0;
        pOut^.flags := pOut^.flags or MEM_Static;
        if pOp^.p4type = P4_DYNAMIC then
          sqlite3DbFree(db, pOp^.p4.z);
        pOp^.p4type := P4_DYNAMIC;
        pOp^.p4.z := pOut^.z;
        pOp^.p1 := pOut^.n;
      end;
      if pOp^.p1 > db^.aLimit[0] { SQLITE_LIMIT_LENGTH } then goto too_big;
      pOp^.opcode := OP_String;
      { fall through to OP_String }
      pOut^.flags := MEM_Str or MEM_Static or MEM_Term;
      pOut^.z     := pOp^.p4.z;
      pOut^.n     := pOp^.p1;
      pOut^.enc   := enc;
      { vdbe.c:1466..1472 — LIKE-optimization blob pass: when P3 names a
        counter register whose value equals P5, reinterpret the bound string
        as a BLOB so the second range scan covers the index's blob region. }
      if (pOp^.p3 > 0) and (aMem[pOp^.p3].flags and MEM_Int <> 0) and
         (aMem[pOp^.p3].u.i = pOp^.p5) then
        pOut^.flags := MEM_Blob or MEM_Static or MEM_Term;
      UpdateMaxBlobsize(pOut);   { vdbe.c:1465 }
    end;

    OP_String: begin
      pOut := out2Prerelease(v, pOp);
      pOut^.flags := MEM_Str or MEM_Static or MEM_Term;
      pOut^.z     := pOp^.p4.z;
      pOut^.n     := pOp^.p1;
      pOut^.enc   := enc;
      if (pOp^.p3 > 0) and (aMem[pOp^.p3].flags and MEM_Int <> 0) and
         (aMem[pOp^.p3].u.i = pOp^.p5) then
        pOut^.flags := MEM_Blob or MEM_Static or MEM_Term;
      UpdateMaxBlobsize(pOut);   { vdbe.c:1465 }
    end;

    { ────── OP_Concat ────── (vdbe.c:1791)
      P1=in1 (right), P2=in2 (left), P3=out3.  Result = r[P2] || r[P1]. }
    OP_Concat: begin
      pIn1 := @aMem[pOp^.p1];
      pIn2 := @aMem[pOp^.p2];
      pOut := @aMem[pOp^.p3];
      if ((pIn1^.flags or pIn2^.flags) and MEM_Null) <> 0 then begin
        sqlite3VdbeMemSetNull(pOut);
      end else begin
        { stringify/expand inputs if needed }
        if (pIn1^.flags and (MEM_Str or MEM_Blob)) = 0 then begin
          if sqlite3VdbeMemStringify(pIn1, enc, 0) <> SQLITE_OK then goto no_mem;
        end else if (pIn1^.flags and MEM_Zero) <> 0 then begin
          if sqlite3VdbeMemExpandBlob(pIn1) <> SQLITE_OK then goto no_mem;
        end;
        if (pIn2^.flags and (MEM_Str or MEM_Blob)) = 0 then begin
          if sqlite3VdbeMemStringify(pIn2, enc, 0) <> SQLITE_OK then goto no_mem;
        end else if (pIn2^.flags and MEM_Zero) <> 0 then begin
          if sqlite3VdbeMemExpandBlob(pIn2) <> SQLITE_OK then goto no_mem;
        end;
        nByte := pIn1^.n + pIn2^.n;
        if nByte > db^.aLimit[0] { SQLITE_LIMIT_LENGTH } then goto too_big;
        if sqlite3VdbeMemGrow(pOut, nByte + 2, ord(pOut = pIn2)) <> SQLITE_OK then goto no_mem;
        pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Str;
        if pOut <> pIn2 then
          Move(pIn2^.z^, pOut^.z^, pIn2^.n);
        Move(pIn1^.z^, PByte(pOut^.z)[pIn2^.n], pIn1^.n);
        PByte(pOut^.z)[nByte]   := 0;
        PByte(pOut^.z)[nByte+1] := 0;
        pOut^.flags := pOut^.flags or MEM_Term;
        pOut^.n   := nByte;
        pOut^.enc := enc;
      end;
      UpdateMaxBlobsize(pOut);   { vdbe.c:1849 }
    end;

    { ────── OP_Move ────── (vdbe.c:1601) }
    OP_Move: begin
      n  := pOp^.p3;
      pIn1 := @aMem[pOp^.p1];
      pOut := @aMem[pOp^.p2];
      i := 0;
      while i < n do begin
        sqlite3VdbeMemMove(pOut, pIn1);
        pIn1^.flags := MEM_Undefined;
        Inc(pIn1);
        Inc(pOut);
        Inc(i);
      end;
    end;

    { ────── OP_Copy ────── (vdbe.c:1652) }
    OP_Copy: begin
      n := pOp^.p3;
      pIn1 := @aMem[pOp^.p1];
      pOut := @aMem[pOp^.p2];
      i := 0;
      while i <= n do begin
        rc := sqlite3VdbeMemCopy(pOut, pIn1);
        if rc <> SQLITE_OK then goto abort_due_to_error;
        { vdbe.c:1663 — when the 0x0002 bit of P5 is set, clear MEM_Subtype
          on the destination (value crosses a coroutine/subquery boundary). }
        if ((pOut^.flags and MEM_Subtype) <> 0) and ((pOp^.p5 and $0002) <> 0) then
          pOut^.flags := pOut^.flags and not u16(MEM_Subtype);
        Inc(pIn1);
        Inc(pOut);
        Inc(i);
      end;
    end;

    { ────── OP_SCopy ────── (vdbe.c:1690) }
    OP_SCopy: begin
      pIn1 := @aMem[pOp^.p1];
      pOut := @aMem[pOp^.p2];
      sqlite3VdbeMemShallowCopy(pOut, pIn1, MEM_Ephem);
    end;

    { ────── OP_IntCopy ────── (vdbe.c:1711) }
    OP_IntCopy: begin
      pIn1 := @aMem[pOp^.p1];
      pOut := @aMem[pOp^.p2];
      pOut^.u.i   := pIn1^.u.i;
      pOut^.flags := MEM_Int;
    end;

    { ────── OP_ResultRow ────── (vdbe.c:1746) }
    OP_ResultRow: begin
      { Check string/blob size }
      pOut := @aMem[pOp^.p1];
      n    := pOp^.p2;
      i := 0;
      while i < n do begin
        if (pOut^.flags and MEM_Str) <> 0 then begin
          if pOut^.n > SQLITE_MAX_LENGTH then goto too_big;
        end;
        Inc(pOut);
        Inc(i);
      end;
      { vdbe.c:1751 — bump column cache generation so Column reads refresh
        from the underlying row.  Without this, eph-cursor reads under
        windowing (windowFullScan / OpenDup chain) keep returning the first
        row's data because cacheStatus stays equal to a never-bumped
        cacheCtr. }
      v^.cacheCtr := (v^.cacheCtr + 2) or 1;
      v^.pResultRow := @aMem[pOp^.p1];
      v^.nResColumn := u16(pOp^.p2);
      if db^.mallocFailed <> 0 then goto no_mem;
      v^.pc := i32(pOp - aOp) + 1;  { save resume point for next call }
      { vdbe.c:1770 — SQLITE_TRACE_ROW fanout. }
      if (db^.mTrace and SQLITE_TRACE_ROW) <> 0 then begin
        if Assigned(db^.trace.xV2) then
          db^.trace.xV2(SQLITE_TRACE_ROW, db^.pTraceArg, v, nil);
      end;
      rc := SQLITE_ROW;
      goto vdbe_return;
    end;

    { ────── OP_Jump ────── (vdbe.c:2561) }
    OP_Jump: begin
      if iCompare < 0 then
        pOp := @aOp[pOp^.p1 - 1]
      else if iCompare = 0 then
        pOp := @aOp[pOp^.p2 - 1]
      else
        pOp := @aOp[pOp^.p3 - 1];
    end;

    { ────── OP_If ────── (vdbe.c:2733) }
    OP_If: begin
      if sqlite3VdbeBooleanValue(@aMem[pOp^.p1], pOp^.p3) <> 0 then
        goto jump_to_p2;
    end;

    { ────── OP_IfNot ────── (vdbe.c:2747) }
    OP_IfNot: begin
      if sqlite3VdbeBooleanValue(@aMem[pOp^.p1], ord(pOp^.p3 = 0)) = 0 then
        goto jump_to_p2;
    end;

    { ────── OP_OpenRead / OP_OpenWrite ────── (vdbe.c:4386) }
    OP_OpenRead,
    OP_OpenWrite: begin
      if (v^.vdbeFlags and VDBF_EXPIRED_MASK) = 1 then begin
        rc := SQLITE_ABORT_ROLLBACK;  { vdbe.c:4395 — was wrongly (1 shl 8); C sqlite.h.in:562 defines it as SQLITE_ABORT|(2<<8) }
        goto abort_due_to_error;
      end;
      nField   := 0;
      pKInfo   := nil;
      p2       := u32(pOp^.p2);
      iDb      := pOp^.p3;
      pDbb     := @db^.aDb[iDb];
      pX       := PBtree(pDbb^.pBt);
      if pOp^.opcode = OP_OpenWrite then begin
        wrFlag := BTREE_WRCSR or (pOp^.p5 and OPFLAG_FORDELETE);
        if pDbb^.pSchema <> nil then begin
          if pDbb^.pSchema^.file_format < v^.minWriteFileFormat then
            v^.minWriteFileFormat := pDbb^.pSchema^.file_format;
        end;
        if (pOp^.p5 and OPFLAG_P2ISREG) <> 0 then begin
          pIn2 := @aMem[p2];
          sqlite3VdbeMemIntegerify(pIn2);
          p2 := u32(pIn2^.u.i);
        end;
      end else begin
        wrFlag := 0;
      end;
      if pOp^.p4type = P4_KEYINFO then begin
        pKInfo := pOp^.p4.pKeyInfo;
        { nAllField is at offset 8 in KeyInfo (u32 nRef + u8 enc + pad + u16 nKeyField + u16 nAllField) }
        nField := i32(Pu16(Pu8(pKInfo) + 8)^);
      end else if pOp^.p4type = P4_INT32 then begin
        nField := pOp^.p4.i;
      end;
      pCur := allocateCursor(v, pOp^.p1, nField, CURTYPE_BTREE);
      if pCur = nil then goto no_mem;
      pCur^.iDb         := iDb;
      pCur^.nullRow     := 1;
      pCur^.cursorFlags := pCur^.cursorFlags or VDBC_Ordered;
      pCur^.pgnoRoot    := p2;
      rc := sqlite3BtreeCursor(pX, p2, wrFlag, pKInfo, pCur^.uc.pCursor);
      pCur^.pKeyInfo := pKInfo;
      pCur^.isTable  := u8(ord(pOp^.p4type <> P4_KEYINFO));
      goto open_cursor_set_hints;
    end;

    { ────── OP_Close ────── (vdbe.c:4707) }
    OP_Close: begin
      sqlite3VdbeFreeCursor(v, v^.apCsr[pOp^.p1]);
      v^.apCsr[pOp^.p1] := nil;
    end;

    { ────── OP_Rewind ────── (vdbe.c:6372) }
    OP_Rewind: begin
      pCur := v^.apCsr[pOp^.p1];
      res := 1;
      pCrsr := pCur^.uc.pCursor;
      rc := sqlite3BtreeFirst(pCrsr, @res);
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus   := CACHE_STALE;
      if rc <> SQLITE_OK then goto abort_due_to_error;
      pCur^.nullRow := u8(res);
      if pOp^.p2 > 0 then begin
        if res <> 0 then goto jump_to_p2;
      end;
    end;

    { ────── OP_Prev / OP_Next ────── (vdbe.c:6495-6524) }
    OP_Prev: begin
      pCur := v^.apCsr[pOp^.p1];
      rc := sqlite3BtreePrevious(pCur^.uc.pCursor, pOp^.p3);
      goto next_tail;
    end;

    OP_Next: begin
      pCur := v^.apCsr[pOp^.p1];
      rc := sqlite3BtreeNext(pCur^.uc.pCursor, pOp^.p3);
      goto next_tail;
    end;

    { ────── OP_SorterNext ────── (vdbe.c:6533) }
    OP_SorterNext: begin
      pCur := v^.apCsr[pOp^.p1];
      rc := sqlite3VdbeSorterNext(db, pCur);
      goto next_tail;
    end;

    { ────── OP_SeekLT / OP_SeekLE / OP_SeekGE / OP_SeekGT ────── (vdbe.c:4824) }
    OP_SeekLT,
    OP_SeekLE,
    OP_SeekGE,
    OP_SeekGT: begin
      pCur  := v^.apCsr[pOp^.p1];
      oc    := pOp^.opcode;
      eqOnly := 0;
      pCur^.nullRow      := 0;
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus  := CACHE_STALE;
      if pCur^.isTable <> 0 then begin
        { Table cursor: seek by integer rowid }
        pIn3   := @aMem[pOp^.p3];
        flags3 := pIn3^.flags;
        if (flags3 and (MEM_Int or MEM_Real or MEM_IntReal or MEM_Str)) = MEM_Str then
          applyNumericAffinity(pIn3, 0);
        iKey := u64(sqlite3VdbeIntValue(pIn3));
        newType := pIn3^.flags;
        pIn3^.flags := flags3; { restore original type }
        if (newType and (MEM_Int or MEM_IntReal)) = 0 then begin
          { could not convert to integer }
          c := 0;
          if (newType and MEM_Real) = 0 then begin
            if (newType and MEM_Null) <> 0 then begin
              goto jump_to_p2;
            end else if oc >= OP_SeekGE then begin
              goto jump_to_p2;
            end else begin
              rc := sqlite3BtreeLast(pCur^.uc.pCursor, @res);
              if rc <> SQLITE_OK then goto abort_due_to_error;
              goto seek_not_found;
            end;
          end;
          c := sqlite3IntFloatCompare(i64(iKey), pIn3^.u.r);
          if c > 0 then begin
            if (oc and 1) = (OP_SeekGT and 1) then Dec(oc);
          end else if c < 0 then begin
            if (oc and 1) = (OP_SeekLT and 1) then Inc(oc);
          end;
        end;
        rc := sqlite3BtreeTableMoveto(pCur^.uc.pCursor, iKey, 0, @res);
        pCur^.movetoTarget := i64(iKey);
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end else begin
        { Index cursor: seek by key record }
        if sqlite3BtreeCursorHasHint(pCur^.uc.pCursor, BTREE_SEEK_EQ) <> 0 then begin
          eqOnly := 1;
        end;
        nFld := pOp^.p4.i;
        rSeek.pKeyInfo := pCur^.pKeyInfo;
        rSeek.nField   := nFld;
        { default_rc: +1 for SeekGE/SeekLT, -1 for SeekGT/SeekLE }
        if (1 and (oc - OP_SeekLT)) <> 0 then rSeek.default_rc := -1
        else rSeek.default_rc := 1;
        rSeek.aMem   := @aMem[pOp^.p3];
        rSeek.eqSeen := 0;
        rc := sqlite3BtreeIndexMoveto(pCur^.uc.pCursor, @rSeek, @res);
        if rc <> SQLITE_OK then goto abort_due_to_error;
        if (eqOnly <> 0) and (rSeek.eqSeen = 0) then goto seek_not_found;
      end;
      { 9.4.divbug.73 — vdbe.c:4974..4976 SQLITE_TEST counter (table+index arms) }
      Inc(sqlite3_search_count);
      if oc >= OP_SeekGE then begin
        if (res < 0) or ((res = 0) and (oc = OP_SeekGT)) then begin
          res := 0;
          rc := sqlite3BtreeNext(pCur^.uc.pCursor, 0);
          if rc <> SQLITE_OK then begin
            if rc = SQLITE_DONE then begin rc := SQLITE_OK; res := 1; end
            else goto abort_due_to_error;
          end;
        end else
          res := 0;
      end else begin
        if (res > 0) or ((res = 0) and (oc = OP_SeekLT)) then begin
          res := 0;
          rc := sqlite3BtreePrevious(pCur^.uc.pCursor, 0);
          if rc <> SQLITE_OK then begin
            if rc = SQLITE_DONE then begin rc := SQLITE_OK; res := 1; end
            else goto abort_due_to_error;
          end;
        end else
          res := sqlite3BtreeEof(pCur^.uc.pCursor);
      end;
      { fall to seek_not_found }
      goto seek_not_found;
    end;

    { ────── OP_Found / OP_NotFound / OP_NoConflict / OP_IfNoHope ────── (vdbe.c:5363) }
    OP_NoConflict,
    OP_NotFound,
    OP_IfNoHope,
    OP_Found: begin
      pCur := v^.apCsr[pOp^.p1];
      rSeek.aMem   := @aMem[pOp^.p3];
      rSeek.nField := pOp^.p4.i;
      if rSeek.nField > 0 then begin
        rSeek.pKeyInfo  := pCur^.pKeyInfo;
        rSeek.default_rc := 0;
        rc := sqlite3BtreeIndexMoveto(pCur^.uc.pCursor, @rSeek, @pCur^.seekResult);
      end else begin
        { Composite key from OP_MakeRecord }
        if (PMem(rSeek.aMem)^.flags and MEM_Blob) = 0 then begin rc := SQLITE_ERROR; goto abort_due_to_error; end;
        if ((PMem(rSeek.aMem)^.flags and MEM_Zero) <> 0) and (sqlite3VdbeMemExpandBlob(PMem(rSeek.aMem)) <> SQLITE_OK) then goto no_mem;
        pIdxKey := sqlite3VdbeAllocUnpackedRecord(pCur^.pKeyInfo);
        if pIdxKey = nil then goto no_mem;
        sqlite3VdbeRecordUnpack(pCur^.pKeyInfo, PMem(rSeek.aMem)^.n, PMem(rSeek.aMem)^.z, pIdxKey);
        pIdxKey^.default_rc := 0;
        rc := sqlite3BtreeIndexMoveto(pCur^.uc.pCursor, pIdxKey, @pCur^.seekResult);
        sqlite3DbFreeNN(db, pIdxKey);
      end;
      if rc <> SQLITE_OK then goto abort_due_to_error;
      alreadyExists := ord(pCur^.seekResult = 0);
      pCur^.nullRow      := u8(1 - alreadyExists);
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus  := CACHE_STALE;
      if pOp^.opcode = OP_Found then begin
        if alreadyExists <> 0 then goto jump_to_p2;
      end else begin
        if alreadyExists = 0 then begin
          goto jump_to_p2;
        end;
        if pOp^.opcode = OP_NoConflict then begin
          for ii := 0 to rSeek.nField - 1 do begin
            if (PMem(rSeek.aMem)[ii].flags and MEM_Null) <> 0 then goto jump_to_p2;
          end;
        end;
        if pOp^.opcode = OP_IfNoHope then
          pCur^.seekHit := u16(pOp^.p4.i);
      end;
    end;

    { ────── OP_SeekRowid / OP_NotExists ────── (vdbe.c:5495) }
    OP_SeekRowid: begin
      pIn3 := @aMem[pOp^.p3];
      if (pIn3^.flags and (MEM_Int or MEM_IntReal)) = 0 then begin
        { not an integer — convert with NUMERIC affinity }
        pMem5b := pIn3^;
        applyAffinity(@pMem5b, AnsiChar(SQLITE_AFF_NUMERIC), enc);
        if (pMem5b.flags and MEM_Int) = 0 then goto jump_to_p2;
        iKey := u64(pMem5b.u.i);
        goto notExistsWithKey;
      end;
      { fall through into NotExists }
      iKey := u64(pIn3^.u.i);
      goto notExistsWithKey;
    end;

    OP_NotExists: begin
      pIn3 := @aMem[pOp^.p3];
      iKey := u64(pIn3^.u.i);
      goto notExistsWithKey;
    end;

    { ────── OP_IdxLE / OP_IdxGT / OP_IdxLT / OP_IdxGE ────── (vdbe.c:6827) }
    OP_IdxLE,
    OP_IdxGT,
    OP_IdxLT,
    OP_IdxGE: begin
      pCur := v^.apCsr[pOp^.p1];
      rSeek.pKeyInfo  := pCur^.pKeyInfo;
      rSeek.nField    := pOp^.p4.i;
      if pOp^.opcode < OP_IdxLT then
        rSeek.default_rc := -1  { OP_IdxLE or OP_IdxGT }
      else
        rSeek.default_rc := 0;  { OP_IdxGE or OP_IdxLT }
      rSeek.aMem := @aMem[pOp^.p3];
      { Inlined sqlite3VdbeIdxKeyCompare }
      nCellKey := 0;
      pCrsr := pCur^.uc.pCursor;
      nCellKey := sqlite3BtreePayloadSize(pCrsr);
      if (nCellKey <= 0) or (nCellKey > $7FFFFFFF) then begin
        rc := SQLITE_CORRUPT_BKPT;
        goto abort_due_to_error;
      end;
      sqlite3VdbeMemInit(@pMem5b, db, 0);
      rc := sqlite3VdbeMemFromBtreeZeroOffset(pCrsr, u32(nCellKey), @pMem5b);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      res := sqlite3VdbeRecordCompareWithSkip(pMem5b.n, pMem5b.z, @rSeek, 0);
      sqlite3VdbeMemReleaseMalloc(@pMem5b);
      { End inlined IdxKeyCompare }
      { OP_IdxLE/OP_IdxLT: negate; OP_IdxGE/OP_IdxGT: increment }
      if (pOp^.opcode and 1) = (OP_IdxLT and 1) then
        res := -res
      else
        Inc(res);
      if res > 0 then goto jump_to_p2;
    end;

    { ────── OP_Trace / OP_Init ────── (vdbe.c:9020/9046) }
    OP_Trace, OP_Init: begin
      i := 1;
      { vdbe.c:9067..9085 — SQLITE_TRACE_STMT / LEGACY fanout. }
      if (db^.mTrace and (SQLITE_TRACE_STMT or SQLITE_TRACE_LEGACY)) <> 0 then begin
        if v^.minWriteFileFormat <> 254 then begin
          if pOp^.p4.z <> nil then
            zTrcStmt := pOp^.p4.z
          else
            zTrcStmt := v^.zSql;
          if zTrcStmt <> nil then begin
            if (db^.mTrace and SQLITE_TRACE_LEGACY) <> 0 then begin
              { Legacy xTrace receives expanded SQL (vdbe.c:9072..9075). }
              zTrcDup := sqlite3VdbeExpandSql(v, zTrcStmt);
              if Assigned(db^.trace.xLegacy) then
                db^.trace.xLegacy(db^.pTraceArg, zTrcDup);
              sqlite3_free(zTrcDup);
            end else if db^.nVdbeExec > 1 then begin
              zTrcDup := sqlite3MPrintf(db, '-- %s', [zTrcStmt]);
              if Assigned(db^.trace.xV2) then
                db^.trace.xV2(SQLITE_TRACE_STMT, db^.pTraceArg, v, zTrcDup);
              sqlite3DbFree(db, zTrcDup);
            end else begin
              if Assigned(db^.trace.xV2) then
                db^.trace.xV2(SQLITE_TRACE_STMT, db^.pTraceArg, v, zTrcStmt);
            end;
          end;
        end;
      end;
      if pOp^.p1 >= sqlite3GlobalConfig.iOnceResetThreshold then begin
        if pOp^.opcode = OP_Trace then begin
          { C `break;` — exit the case without jumping; advance to next op. }
        end else begin
          while i < v^.nOp do begin
            if aOp[i].opcode = OP_Once then aOp[i].p1 := 0;
            Inc(i);
          end;
          pOp^.p1 := 0;
          Inc(pOp^.p1);
          Inc(v^.aCounter[SQLITE_STMTSTATUS_RUN]);
          goto jump_to_p2;
        end;
      end else begin
        Inc(pOp^.p1);
        Inc(v^.aCounter[SQLITE_STMTSTATUS_RUN]);
        goto jump_to_p2;
      end;
    end;

    { ────── OP_Column ────── (vdbe.c:2975) }
    OP_Column: begin
      pCol   := v^.apCsr[pOp^.p1];
      p2col  := u32(pOp^.p2);

      op_column_restart:
      { vdbe.c:3000 — aOffset recomputed from current pCol so an aAltMap
        redirect (below) lands on the alias cursor's aType/aOffset. }
      aOffset := Pu32(Pu8(pCol) + 120 + u32(pCol^.nField) * SizeOf(u32));
      if pCol^.cacheStatus <> v^.cacheCtr then begin
        if pCol^.nullRow <> 0 then begin
          if (pCol^.eCurType = CURTYPE_PSEUDO) and (pCol^.seekResult > 0) then begin
            pRegCol := @aMem[pCol^.seekResult];
            pCol^.payloadSize := u32(pRegCol^.n);
            pCol^.szRow       := u32(pRegCol^.n);
            pCol^.aRow        := Pu8(pRegCol^.z);
          end else begin
            pDest := @aMem[pOp^.p3];
            sqlite3VdbeMemSetNull(pDest);
            goto op_column_out;
          end;
        end else begin
          pCrsr := pCol^.uc.pCursor;
          if pCol^.deferredMoveto <> 0 then begin
            { vdbe.c:3025..3031 — covering-index alias redirect: if the
              table cursor was set up by OP_DeferredSeek with an aAltMap
              (P4_INTARRAY), and the requested column maps to an index
              column, read directly from the index cursor and skip the
              deferred table seek entirely (saves a sqlite3_search_count
              tick for covering-index OR plans — see whereD-3.5.1). }
            if (pCol^.ub.aAltMap <> nil)
               and (Pu32(pCol^.ub.aAltMap)[1 + p2col] > 0) then begin
              iAltMap := Pu32(pCol^.ub.aAltMap)[1 + p2col];
              pCol    := pCol^.pAltCursor;
              p2col   := iAltMap - 1;
              goto op_column_restart;
            end;
            rc := sqlite3VdbeFinishMoveto(pCol);
            if rc <> SQLITE_OK then goto abort_due_to_error;
          end else if sqlite3BtreeCursorHasMoved(pCrsr) <> 0 then begin
            rc := sqlite3VdbeHandleMovedCursor(pCol);
            if rc <> SQLITE_OK then goto abort_due_to_error;
            goto op_column_restart;
          end;
          pCol^.payloadSize := sqlite3BtreePayloadSize(pCrsr);
          pCol^.aRow := Pu8(sqlite3BtreePayloadFetch(pCrsr, pCol^.szRow));
        end;
        pCol^.cacheStatus := v^.cacheCtr;
        if pCol^.aRow[0] < $80 then begin
          aOffset[0] := pCol^.aRow[0];
          pCol^.iHdrOffset := 1;
        end else begin
          pCol^.iHdrOffset := u32(sqlite3GetVarint32(pCol^.aRow, aOffset[0]));
        end;
        pCol^.nHdrParsed := 0;
        if pCol^.szRow < aOffset[0] then begin
          pCol^.aRow := nil;
          pCol^.szRow := 0;
          if (aOffset[0] > 98307) or (aOffset[0] > pCol^.payloadSize) then
            goto op_column_corrupt;
        end else begin
          zData := pCol^.aRow;
          goto op_column_read_header;
        end;
      end else if (pCol^.eCurType = CURTYPE_BTREE) and
                  (sqlite3BtreeCursorHasMoved(pCol^.uc.pCursor) <> 0) then begin
        rc := sqlite3VdbeHandleMovedCursor(pCol);
        if rc <> SQLITE_OK then goto abort_due_to_error;
        goto op_column_restart;
      end;

      if pCol^.nHdrParsed <= i32(p2col) then begin
        if pCol^.iHdrOffset < aOffset[0] then begin
          if pCol^.aRow = nil then begin
            FillChar(sMemCol, SizeOf(TMem), 0);
            rc := sqlite3VdbeMemFromBtreeZeroOffset(pCol^.uc.pCursor, aOffset[0], @sMemCol);
            if rc <> SQLITE_OK then goto abort_due_to_error;
            zData := Pu8(sMemCol.z);
          end else
            zData := pCol^.aRow;

          op_column_read_header:
          i := pCol^.nHdrParsed;
          offset64 := aOffset[i];
          zHdrC   := zData + pCol^.iHdrOffset;
          zEndHdr := zData + aOffset[0];
          repeat
            tCol := zHdrC[0];
            if tCol < $80 then begin
              Inc(zHdrC);
              offset64 := offset64 + sqlite3VdbeOneByteSerialTypeLen(u8(tCol));
            end else begin
              zHdrC := zHdrC + sqlite3GetVarint32(zHdrC, tCol);
              offset64 := offset64 + sqlite3VdbeSerialTypeLen(tCol);
            end;
            { pCol->aType[i] = tCol; aOffset[i+1] = offset64 }
            Pu32(Pu8(pCol) + 120)[i] := tCol;
            Inc(i);
            aOffset[i] := u32(offset64 and $FFFFFFFF);
          until not ((u32(i) <= p2col) and (zHdrC < zEndHdr));

          { corruption check }
          if ((zHdrC >= zEndHdr) and
              ((zHdrC > zEndHdr) or (offset64 <> pCol^.payloadSize))) or
             (offset64 > pCol^.payloadSize) then begin
            if aOffset[0] = 0 then begin
              i := 0;
              zHdrC := zEndHdr;
            end else begin
              if pCol^.aRow = nil then sqlite3VdbeMemRelease(@sMemCol);
              goto op_column_corrupt;
            end;
          end;

          pCol^.nHdrParsed    := i;
          pCol^.iHdrOffset    := u32(zHdrC - zData);
          if pCol^.aRow = nil then sqlite3VdbeMemRelease(@sMemCol);
        end else
          tCol := 0;

        if pCol^.nHdrParsed <= i32(p2col) then begin
          pDest := @aMem[pOp^.p3];
          if pOp^.p4type = P4_MEM then
            sqlite3VdbeMemShallowCopy(pDest, PMem(pOp^.p4.pMem), MEM_Static)
          else
            sqlite3VdbeMemSetNull(pDest);
          goto op_column_out;
        end;
      end else
        tCol := Pu32(Pu8(pCol) + 120)[p2col];  { pCol->aType[p2col] }

      { Extract column value }
      pDest := @aMem[pOp^.p3];
      if vdbeMemDynamic(pDest) then sqlite3VdbeMemSetNull(pDest);
      if pCol^.szRow >= aOffset[p2col + 1] then begin
        zData := pCol^.aRow + aOffset[p2col];
        if tCol < 12 then
          sqlite3VdbeSerialGet(zData, tCol, pDest)
        else begin
          lenCol := i32((tCol - 12) div 2);
          pDest^.n   := lenCol;
          pDest^.enc := enc;
          if pDest^.szMalloc < lenCol + 2 then begin
            if lenCol > i32(Pu32(Pu8(db) + 136)^) then goto too_big;
            pDest^.flags := MEM_Null;
            if sqlite3VdbeMemGrow(pDest, lenCol + 2, 0) <> SQLITE_OK then goto no_mem;
          end else
            pDest^.z := pDest^.zMalloc;
          Move(zData^, pDest^.z^, lenCol);
          pDest^.z[lenCol]     := #0;
          pDest^.z[lenCol + 1] := #0;
          if (tCol and 1) <> 0 then pDest^.flags := MEM_Str
          else pDest^.flags := MEM_Blob;
        end;
      end else begin
        pDest^.enc := enc;
        if ((pOp^.p5 and OPFLAG_BYTELENARG) <> 0) and
           ((pOp^.p5 = OPFLAG_TYPEOFARG) or
            ((tCol >= 12) and (((tCol and 1) = 0) or (pOp^.p5 = OPFLAG_BYTELENARG)))) or
           (sqlite3VdbeSerialTypeLen(tCol) = 0) then
          sqlite3VdbeSerialGet(Pu8(@sqlite3CtypeMap[0]), tCol, pDest)
        else begin
          rc := vdbeColumnFromOverflow(pCol, i32(p2col), tCol, aOffset[p2col],
                    v^.cacheCtr, colCacheCtr, pDest);
          if rc <> SQLITE_OK then begin
            if rc = SQLITE_NOMEM then goto no_mem;
            if rc = SQLITE_TOOBIG then goto too_big;
            goto abort_due_to_error;
          end;
        end;
      end;

      op_column_out:
      UpdateMaxBlobsize(pDest);   { vdbe.c:3256 UPDATE_MAX_BLOBSIZE(pDest) }
    end;

    { ────── OP_MakeRecord ────── (vdbe.c:3469) }
    OP_MakeRecord: begin
      nData    := 0;
      nHdr     := 0;
      nZeroMR  := 0;
      nFieldMR := pOp^.p1;
      zAffMR   := pOp^.p4.z;
      pData0   := @aMem[nFieldMR];
      nFieldMR := pOp^.p2;
      pLastMR  := pData0 + (nFieldMR - 1);
      pOut     := @aMem[pOp^.p3];

      { Apply affinity to inputs }
      if zAffMR <> nil then begin
        pRec := pData0;
        while zAffMR[0] <> #0 do begin
          applyAffinity(pRec, zAffMR[0], enc);
          if (zAffMR[0] = AnsiChar(SQLITE_AFF_REAL)) and
             ((pRec^.flags and MEM_Int) <> 0) then begin
            pRec^.flags := (pRec^.flags or MEM_IntReal) and not u16(MEM_Int);
          end;
          Inc(zAffMR);
          Inc(pRec);
        end;
      end;

      { Compute sizes — iterating pData0..pLastMR }
      pRec := pLastMR;
      repeat
        if (pRec^.flags and MEM_Null) <> 0 then begin
          if (pRec^.flags and MEM_Zero) <> 0 then
            pRec^.uTemp := 10
          else
            pRec^.uTemp := 0;
          Inc(nHdr);
        end else if (pRec^.flags and (MEM_Int or MEM_IntReal)) <> 0 then begin
          { uu,iv declared in outer var section as uuMR, ivMR }
          ivMR := pRec^.u.i;
          if ivMR < 0 then uuMR := u64(not ivMR) else uuMR := u64(ivMR);
          Inc(nHdr);
          if uuMR <= 127 then begin
            if ((ivMR and 1) = ivMR) and (v^.minWriteFileFormat >= 4) then
              pRec^.uTemp := 8 + u32(uuMR)
            else begin
              nData := nData + 1;
              pRec^.uTemp := 1;
            end;
          end else if uuMR <= 32767 then begin
            nData := nData + 2; pRec^.uTemp := 2;
          end else if uuMR <= 8388607 then begin
            nData := nData + 3; pRec^.uTemp := 3;
          end else if uuMR <= 2147483647 then begin
            nData := nData + 4; pRec^.uTemp := 4;
          end else if uuMR <= 140737488355327 then begin
            nData := nData + 6; pRec^.uTemp := 5;
          end else begin
            nData := nData + 8;
            if (pRec^.flags and MEM_IntReal) <> 0 then begin
              pRec^.u.r := Double(pRec^.u.i);
              pRec^.flags := (pRec^.flags and not u16(MEM_IntReal)) or MEM_Real;
              pRec^.uTemp := 7;
            end else
              pRec^.uTemp := 6;
          end;
        end else if (pRec^.flags and MEM_Real) <> 0 then begin
          Inc(nHdr);
          nData := nData + 8;
          pRec^.uTemp := 7;
        end else begin
          lenMR := u32(pRec^.n);
          serial_type := (lenMR * 2) + 12 + u32(ord((pRec^.flags and MEM_Str) <> 0));
          if (pRec^.flags and MEM_Zero) <> 0 then begin
            serial_type := serial_type + u32(pRec^.u.nZero) * 2;
            if nData <> 0 then begin
              if sqlite3VdbeMemExpandBlob(pRec) <> SQLITE_OK then goto no_mem;
              lenMR := lenMR + u32(pRec^.u.nZero);
            end else
              nZeroMR := nZeroMR + pRec^.u.nZero;
          end;
          nData := nData + lenMR;
          nHdr  := nHdr + i32(sqlite3VarintLen(serial_type));
          pRec^.uTemp := serial_type;
        end;
        if pRec = pData0 then break;
        Dec(pRec);
      until False;

      { Compute header size (varint of nHdr itself) }
      if nHdr <= 126 then
        Inc(nHdr)
      else begin
        nVarint := i32(sqlite3VarintLen(u64(nHdr)));
        nHdr := nHdr + nVarint;
        if nVarint < i32(sqlite3VarintLen(u64(nHdr))) then Inc(nHdr);
      end;
      nByteMR := i64(nHdr) + i64(nData);

      { Resize output register }
      if nByteMR + nZeroMR <= i64(pOut^.szMalloc) then
        pOut^.z := pOut^.zMalloc
      else begin
        if nByteMR + nZeroMR > i64(Pu32(Pu8(db) + 136)^) then goto too_big;
        if sqlite3VdbeMemClearAndResize(pOut, i32(nByteMR)) <> SQLITE_OK then goto no_mem;
      end;
      pOut^.n := i32(nByteMR);
      pOut^.flags := MEM_Blob;
      if nZeroMR <> 0 then begin
        pOut^.u.nZero := nZeroMR;
        pOut^.flags := pOut^.flags or MEM_Zero;
      end;
      UpdateMaxBlobsize(pOut);   { vdbe.c:3710 }
      zHdrMR := Pu8(pOut^.z);
      zPayMR := zHdrMR + nHdr;

      { Write header size varint }
      if nHdr < $80 then begin
        zHdrMR[0] := u8(nHdr);
        Inc(zHdrMR);
      end else
        zHdrMR := zHdrMR + sqlite3PutVarint(zHdrMR, u64(nHdr));

      { Write records }
      pRec := pData0;
      while True do begin
        serial_type := pRec^.uTemp;
        if serial_type <= 7 then begin
          zHdrMR[0] := u8(serial_type);
          Inc(zHdrMR);
          if serial_type = 0 then begin
            { NULL — no payload }
          end else begin
            if serial_type = 7 then
              Move(pRec^.u.r, vMR, 8)
            else
              vMR := u64(pRec^.u.i);
            lenMR := sqlite3VdbeSerialTypeLen(serial_type);
            case lenMR of
              8: begin zPayMR[7] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[6] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[5] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[4] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[3] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[2] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[1] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[0] := u8(vMR and $FF); end;
              6: begin zPayMR[5] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[4] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[3] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[2] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[1] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[0] := u8(vMR and $FF); end;
              4: begin zPayMR[3] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[2] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[1] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[0] := u8(vMR and $FF); end;
              3: begin zPayMR[2] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[1] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[0] := u8(vMR and $FF); end;
              2: begin zPayMR[1] := u8(vMR and $FF); vMR := vMR shr 8;
                       zPayMR[0] := u8(vMR and $FF); end;
              1: zPayMR[0] := u8(vMR and $FF);
            end;
            zPayMR := zPayMR + lenMR;
          end;
        end else if serial_type < $80 then begin
          zHdrMR[0] := u8(serial_type);
          Inc(zHdrMR);
          if (serial_type >= 14) and (pRec^.n > 0) then begin
            Move(pRec^.z^, zPayMR^, pRec^.n);
            zPayMR := zPayMR + pRec^.n;
          end;
        end else begin
          zHdrMR := zHdrMR + sqlite3PutVarint(zHdrMR, serial_type);
          if pRec^.n > 0 then begin
            Move(pRec^.z^, zPayMR^, pRec^.n);
            zPayMR := zPayMR + pRec^.n;
          end;
        end;
        if pRec = pLastMR then break;
        Inc(pRec);
      end;
    end;

    { ────── OP_Count ────── (vdbe.c:3797) }
    OP_Count: begin
      pCrsr := v^.apCsr[pOp^.p1]^.uc.pCursor;
      if pOp^.p3 <> 0 then
        nEntry := sqlite3BtreeRowCountEst(pCrsr)
      else begin
        nEntry := 0;
        rc := sqlite3BtreeCount(Psqlite3(db), pCrsr, @nEntry);
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end;
      pOut := out2Prerelease(v, pOp);
      pOut^.u.i := nEntry;
      goto check_for_interrupt;
    end;

    { ────── OP_Rowid ────── (vdbe.c:6154) }
    OP_Rowid: begin
      pOut := out2Prerelease(v, pOp);
      pCur := v^.apCsr[pOp^.p1];
      if pCur^.nullRow <> 0 then begin
        pOut^.flags := MEM_Null;
      end else if pCur^.deferredMoveto <> 0 then begin
        pOut^.u.i := pCur^.movetoTarget;
      end else if pCur^.eCurType = CURTYPE_VTAB then begin
        { Phase 6.bis.3b — vdbe.c:6171 }
        pVCurC := passqlite3vtab.PSqlite3VtabCursor(pCur^.uc.pVCur);
        Assert(pVCurC <> nil, 'OP_Rowid VTAB pVCur');
        pVtabC := pVCurC^.pVtab;
        pModC  := pVtabC^.pModule;
        Assert(pModC^.xRowid <> nil, 'OP_Rowid xRowid');
        rc := TxRowidFnV(pModC^.xRowid)(pVCurC, @pOut^.u.i);
        passqlite3vtab.sqlite3VtabImportErrmsg(v, pVtabC);
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end else begin
        rc := sqlite3VdbeCursorRestore(pCur);
        if rc <> SQLITE_OK then goto abort_due_to_error;
        if pCur^.nullRow <> 0 then begin
          pOut^.flags := MEM_Null;
        end else begin
          pOut^.u.i := sqlite3BtreeIntegerKey(pCur^.uc.pCursor);
        end;
      end;
    end;

    { ────── OP_NullRow ────── (vdbe.c:6204) }
    OP_NullRow: begin
      pCur := v^.apCsr[pOp^.p1];
      if pCur = nil then begin
        pCur := allocateCursor(v, pOp^.p1, 1, CURTYPE_PSEUDO);
        if pCur = nil then goto no_mem;
        pCur^.seekResult := 0;
        pCur^.isTable := 1;
        pCur^.cursorFlags := pCur^.cursorFlags or VDBC_NoReuse;
        pCur^.uc.pCursor := sqlite3BtreeFakeValidCursor();
      end;
      pCur^.nullRow := 1;
      pCur^.cacheStatus := CACHE_STALE;
      if pCur^.eCurType = CURTYPE_BTREE then
        sqlite3BtreeClearCursor(pCur^.uc.pCursor);
    end;

    { ────── OP_SeekEnd ────── (vdbe.c:6231) }
    OP_SeekEnd: begin
      pCur := v^.apCsr[pOp^.p1];
      pCrsr := pCur^.uc.pCursor;
      pCur^.cacheStatus := CACHE_STALE;
      pCur^.seekResult := -1;
      rc := sqlite3BtreeLast(pCrsr, @res);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_NewRowid ────── (vdbe.c:5589) }
    OP_NewRowid: begin
      vRow := 0;
      res  := 0;
      pOut := out2Prerelease(v, pOp);
      pCur := v^.apCsr[pOp^.p1];
      pCrsr := pCur^.uc.pCursor;
      if (pCur^.cursorFlags and VDBC_RandomRowid) = 0 then begin
        rc := sqlite3BtreeLast(pCrsr, @res);
        if rc <> SQLITE_OK then goto abort_due_to_error;
        if res <> 0 then
          vRow := 1
        else begin
          vRow := sqlite3BtreeIntegerKey(pCrsr);
          if vRow >= i64($7FFFFFFFFFFFFFFF) then
            pCur^.cursorFlags := pCur^.cursorFlags or VDBC_RandomRowid
          else
            Inc(vRow);
        end;
      end;
      { AUTOINCREMENT — port of vdbe.c:5652..5681.  When P3 is non-zero, it
        names the register holding the running max ROWID (the regCtr emitted
        by sqlite3AutoincrementBegin from sqlite_sequence).  Bump the new
        rowid to at least mem[P3]+1, then store it back into mem[P3] so the
        autoincrement epilogue writes the updated counter. }
      if pOp^.p3 <> 0 then begin
        if v^.pFrame <> nil then begin
          pFrame := v^.pFrame;
          while pFrame^.pParent <> nil do pFrame := pFrame^.pParent;
          pIn3 := @pFrame^.aMem[pOp^.p3];
        end else
          pIn3 := @aMem[pOp^.p3];
        sqlite3VdbeMemIntegerify(pIn3);
        if (pIn3^.u.i = i64($7FFFFFFFFFFFFFFF))
           or ((pCur^.cursorFlags and VDBC_RandomRowid) <> 0) then begin
          rc := SQLITE_FULL;
          goto abort_due_to_error;
        end;
        if vRow < pIn3^.u.i + 1 then vRow := pIn3^.u.i + 1;
        pIn3^.u.i := vRow;
      end;
      if (pCur^.cursorFlags and VDBC_RandomRowid) <> 0 then begin
        cntNR := 0;
        repeat
          sqlite3_randomness(SizeOf(vRow), @vRow);
          vRow := (vRow and (i64($7FFFFFFFFFFFFFFF) shr 1)) + 1;
          res := 0;
          rc := sqlite3BtreeTableMoveto(pCrsr, u64(vRow), 0, @res);
          Inc(cntNR);
        until not ((rc = SQLITE_OK) and (res = 0) and (cntNR < 100));
        if rc <> SQLITE_OK then goto abort_due_to_error;
        if res = 0 then begin
          rc := SQLITE_FULL;
          goto abort_due_to_error;
        end;
      end;
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus    := CACHE_STALE;
      pOut^.u.i := vRow;
    end;

    { ────── OP_Insert ────── (vdbe.c:5748) }
    OP_Insert: begin
      pIn2 := @aMem[pOp^.p2];
      pCur := v^.apCsr[pOp^.p1];
      sqlite3VdbeIncrWriteCounter(v, pCur);
      pIn3 := @aMem[pOp^.p3];  { key register }
      xPay.nKey := pIn3^.u.i;

      { vdbe.c:5778..5784 — derive zDb/pTab for the update hook when P4
        is a Table* and an update hook is installed.  With the pre-update
        hook compiled in, HAS_UPDATE_HOOK(db) also covers xPreUpdateCallback. }
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
      if (pOp^.p4type = P4_TABLE)
         and ((db^.xUpdateCallback <> nil)
              or (db^.xPreUpdateCallback <> nil)) then begin
{$ELSE}
      if (pOp^.p4type = P4_TABLE) and (db^.xUpdateCallback <> nil) then begin
{$ENDIF}
        zHookDb  := PDb(PtrUInt(db^.aDb) +
                        PtrUInt(pCur^.iDb) * SizeOf(TDb))^.zDbSName;
        pHookTab := PTableHookFields(pOp^.p4.pTab);
      end else begin
        zHookDb  := nil;
        pHookTab := nil;
      end;

{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
      { vdbe.c:5786..5799 — invoke the pre-update hook (INSERT) before the
        row is written.  ISNOOP rows fall through without inserting. }
      if pHookTab <> nil then begin
        if (db^.xPreUpdateCallback <> nil)
           and ((pOp^.p5 and OPFLAG_ISUPDATE) = 0)
           and Assigned(gVdbePreUpdateHook) then
          gVdbePreUpdateHook(v, pCur, SQLITE_INSERT_AUTH, zHookDb,
            pOp^.p4.pTab, xPay.nKey, pOp^.p2, -1);
        if (db^.xUpdateCallback = nil)
           or (PTableHookFields(pOp^.p4.pTab)^.aCol = nil) then begin
          { Prevent the post-update hook from running when it should not. }
          pHookTab := nil;
        end;
      end;
      { ISNOOP rows (vdbe.c:5798) skip the insert entirely — the pre-update
        hook above is the only side-effect. }
      if (pOp^.p5 and OPFLAG_ISNOOP) = 0 then begin
{$ENDIF}

      if (pOp^.p5 and OPFLAG_NCHANGE) <> 0 then begin
        Inc(v^.nChange);
        if (pOp^.p5 and OPFLAG_LASTROWID) <> 0 then
          db^.lastRowid := xPay.nKey;
      end;
      xPay.pData := pIn2^.z;
      xPay.nData := pIn2^.n;
      if (pIn2^.flags and MEM_Zero) <> 0 then
        xPay.nZero := pIn2^.u.nZero
      else
        xPay.nZero := 0;
      xPay.pKey  := nil;
      seekRes    := 0;
      if (pOp^.p5 and OPFLAG_USESEEKRESULT) <> 0 then
        seekRes := pCur^.seekResult;
      rc := sqlite3BtreeInsert(pCur^.uc.pCursor, @xPay,
              pOp^.p5 and (OPFLAG_APPEND or OPFLAG_SAVEPOSITION or OPFLAG_PREFORMAT),
              seekRes);
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus    := CACHE_STALE;
      Inc(colCacheCtr);
      if rc <> SQLITE_OK then goto abort_due_to_error;

      { vdbe.c:5824..5831 — invoke the update hook after a successful
        insert.  ISUPDATE distinguishes UPDATE from INSERT. }
      if (pHookTab <> nil) and (pHookTab^.aCol <> nil) then begin
        if (pOp^.p5 and OPFLAG_ISUPDATE) <> 0 then
          TUpdateCallbackFn(db^.xUpdateCallback)(db^.pUpdateArg,
            SQLITE_UPDATE_AUTH, zHookDb, pHookTab^.zName, xPay.nKey)
        else
          TUpdateCallbackFn(db^.xUpdateCallback)(db^.pUpdateArg,
            SQLITE_INSERT_AUTH, zHookDb, pHookTab^.zName, xPay.nKey);
      end;
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
      end;  { OPFLAG_ISNOOP guard }
{$ENDIF}
    end;

    { ────── OP_Delete ────── (vdbe.c:5903) }
    OP_Delete: begin
      opflags := pOp^.p2;
      pCur := v^.apCsr[pOp^.p1];
      sqlite3VdbeIncrWriteCounter(v, pCur);

      { vdbe.c:5937..5950 — derive zDb/pTab for the update hook; if the
        cursor was last moved with Next/Prev (SAVEPOSITION) capture the
        current rowid into movetoTarget so it can be passed to the hook. }
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
      if (pOp^.p4type = P4_TABLE)
         and ((db^.xUpdateCallback <> nil)
              or (db^.xPreUpdateCallback <> nil)) then begin
{$ELSE}
      if (pOp^.p4type = P4_TABLE) and (db^.xUpdateCallback <> nil) then begin
{$ENDIF}
        zHookDb  := PDb(PtrUInt(db^.aDb) +
                        PtrUInt(pCur^.iDb) * SizeOf(TDb))^.zDbSName;
        pHookTab := PTableHookFields(pOp^.p4.pTab);
        if ((pOp^.p5 and OPFLAG_SAVEPOSITION) <> 0) and (pCur^.isTable <> 0) then
          pCur^.movetoTarget := sqlite3BtreeIntegerKey(pCur^.uc.pCursor);
      end else begin
        zHookDb  := nil;
        pHookTab := nil;
      end;

{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
      { vdbe.c:5952..5969 — invoke the pre-update hook (DELETE or, for an
        UPDATE that deletes the old row first, UPDATE) before the row is
        removed.  ISNOOP rows skip the actual delete. }
      if (db^.xPreUpdateCallback <> nil) and (pHookTab <> nil)
         and Assigned(gVdbePreUpdateHook) then begin
        if (opflags and OPFLAG_ISUPDATE) <> 0 then
          gVdbePreUpdateHook(v, pCur, SQLITE_UPDATE_AUTH, zHookDb,
            pOp^.p4.pTab, pCur^.movetoTarget, pOp^.p3, -1)
        else
          gVdbePreUpdateHook(v, pCur, SQLITE_DELETE_AUTH, zHookDb,
            pOp^.p4.pTab, pCur^.movetoTarget, pOp^.p3, -1);
      end;
      if (opflags and OPFLAG_ISNOOP) = 0 then begin
{$ENDIF}

      rc := sqlite3BtreeDelete(pCur^.uc.pCursor, u8(pOp^.p5));
      pCur^.cacheStatus := CACHE_STALE;
      Inc(colCacheCtr);
      pCur^.seekResult := 0;
      if rc <> SQLITE_OK then goto abort_due_to_error;

      { vdbe.c:5993..6000 — invoke the update hook after a successful
        delete (rowid tables only). }
      if (opflags and OPFLAG_NCHANGE) <> 0 then begin
        Inc(v^.nChange);
        { TF_WithoutRowid = $00000080 (sqliteInt.h); HasRowid == not set. }
        if (pHookTab <> nil) and (db^.xUpdateCallback <> nil) and
           ((pHookTab^.tabFlags and u32($00000080)) = 0) then
          TUpdateCallbackFn(db^.xUpdateCallback)(db^.pUpdateArg,
            SQLITE_DELETE_AUTH, zHookDb, pHookTab^.zName, pCur^.movetoTarget);
      end;
{$IFDEF SQLITE_ENABLE_PREUPDATE_HOOK}
      end;  { OPFLAG_ISNOOP guard }
{$ENDIF}
    end;

    { ────── OP_ResetCount ────── (vdbe.c:6011) }
    OP_ResetCount: begin
      sqlite3VdbeSetChanges(Psqlite3(db), v^.nChange);
      v^.nChange := 0;
    end;

    { ────── OP_IdxInsert ────── (vdbe.c:6570) }
    OP_IdxInsert: begin
      pCur := v^.apCsr[pOp^.p1];
      sqlite3VdbeIncrWriteCounter(v, pCur);
      pIn2 := @aMem[pOp^.p2];
      if (pOp^.p5 and OPFLAG_NCHANGE) <> 0 then Inc(v^.nChange);
      if sqlite3VdbeMemExpandBlob(pIn2) <> SQLITE_OK then goto no_mem;
      xPay.nKey  := pIn2^.n;
      xPay.pKey  := pIn2^.z;
      xPay.aMem  := @aMem[pOp^.p3];
      xPay.nMem  := u16(pOp^.p4.i);
      seekRes    := 0;
      if (pOp^.p5 and OPFLAG_USESEEKRESULT) <> 0 then
        seekRes := pCur^.seekResult;
      rc := sqlite3BtreeInsert(pCur^.uc.pCursor, @xPay,
              pOp^.p5 and (OPFLAG_APPEND or OPFLAG_SAVEPOSITION or OPFLAG_PREFORMAT),
              seekRes);
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus    := CACHE_STALE;
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_IdxDelete ────── (vdbe.c:6637) }
    OP_IdxDelete: begin
      pCur := v^.apCsr[pOp^.p1];
      sqlite3VdbeIncrWriteCounter(v, pCur);
      pCrsr := pCur^.uc.pCursor;
      rSeek.pKeyInfo  := pCur^.pKeyInfo;
      rSeek.nField    := u16(pOp^.p3);
      rSeek.default_rc := 0;
      rSeek.aMem      := @aMem[pOp^.p2];
      rSeek.eqSeen    := 0;
      rc := sqlite3BtreeIndexMoveto(pCrsr, @rSeek, @res);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if res <> 0 then begin
        { vdbe.c:6658..6670 — sub-search around the current cursor for an
          EIIB-affected match (real-value index expression / virtual
          column).  If still not found and not in writable_schema mode,
          report SQLITE_CORRUPT_INDEX. }
        if (vdbeFindIndexKey <> nil) and (pOp^.p4type = P4_INDEX) then begin
          rc := vdbeFindIndexKey(pCrsr, pOp^.p4.pIdx, @rSeek, @res, 0);
          if rc <> SQLITE_OK then goto abort_due_to_error;
        end;
        if res <> 0 then begin
          if (db^.flags and u64($00000001)) = 0 then begin  { SQLITE_WriteSchema }
            rc := SQLITE_CORRUPT_INDEX;
            goto abort_due_to_error;
          end;
          pCur^.cacheStatus := CACHE_STALE;
          pCur^.seekResult  := 0;
        end else begin
          rc := sqlite3BtreeDelete(pCrsr, BTREE_AUXDELETE);
          if rc <> SQLITE_OK then goto abort_due_to_error;
        end;
      end else begin
        rc := sqlite3BtreeDelete(pCrsr, BTREE_AUXDELETE);
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end;
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus    := CACHE_STALE;
      pCur^.seekResult     := 0;
    end;

    { ────── OP_DeferredSeek / OP_IdxRowid ────── (vdbe.c:6708) }
    OP_DeferredSeek,
    OP_IdxRowid: begin
      pCur := v^.apCsr[pOp^.p1];
      rc := sqlite3VdbeCursorRestore(pCur);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if pCur^.nullRow = 0 then begin
        rowid54 := 0;
        rc := sqlite3VdbeIdxRowid(db, pCur^.uc.pCursor, rowid54);
        if rc <> SQLITE_OK then goto abort_due_to_error;
        if pOp^.opcode = OP_DeferredSeek then begin
          pTabCur := v^.apCsr[pOp^.p3];
          pTabCur^.nullRow        := 0;
          pTabCur^.movetoTarget   := rowid54;
          pTabCur^.deferredMoveto := 1;
          pTabCur^.cacheStatus    := CACHE_STALE;
          pTabCur^.ub.aAltMap     := Pointer(pOp^.p4.ai);
          pTabCur^.pAltCursor     := pCur;
        end else begin
          pOut := out2Prerelease(v, pOp);
          pOut^.u.i := rowid54;
        end;
      end else begin
        sqlite3VdbeMemSetNull(@aMem[pOp^.p2]);
      end;
    end;

    { ────── OP_FinishSeek ────── (vdbe.c:6771) }
    OP_FinishSeek: begin
      pCur := v^.apCsr[pOp^.p1];
      if pCur^.deferredMoveto <> 0 then begin
        rc := sqlite3VdbeFinishMoveto(pCur);
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end;
    end;

    { ────── OP_Add / OP_Subtract / OP_Multiply / OP_Divide / OP_Remainder ──
      (vdbe.c:1891) P1=in1, P2=in2, P3=out3  (result = r[P2] op r[P1]) }
    OP_Add,
    OP_Subtract,
    OP_Multiply,
    OP_Divide,
    OP_Remainder: begin
      pIn1  := @aMem[pOp^.p1];
      type1d := pIn1^.flags;
      pIn2  := @aMem[pOp^.p2];
      type2d := pIn2^.flags;
      pOut  := @aMem[pOp^.p3];
      if (type1d and type2d and MEM_Int) <> 0 then begin
        { fast int path }
        iAd := pIn1^.u.i;
        iBd := pIn2^.u.i;
        case pOp^.opcode of
          OP_Add:       if sqlite3AddInt64(@iBd, iAd) <> 0 then goto arith_fp;
          OP_Subtract:  if sqlite3SubInt64(@iBd, iAd) <> 0 then goto arith_fp;
          OP_Multiply:  if sqlite3MulInt64(@iBd, iAd) <> 0 then goto arith_fp;
          OP_Divide: begin
            if iAd = 0 then goto arith_null;
            if (iAd = -1) and (iBd = Low(i64)) then goto arith_fp;
            iBd := iBd div iAd;
          end;
          else begin  { OP_Remainder }
            if iAd = 0 then goto arith_null;
            if iAd = -1 then iAd := 1;
            iBd := iBd mod iAd;
          end;
        end;
        pOut^.u.i := iBd;
        pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Int;
      end else if ((type1d or type2d) and MEM_Null) <> 0 then
        goto arith_null
      else begin
        type1d := numericType(pIn1);
        type2d := numericType(pIn2);
        if (type1d and type2d and MEM_Int) <> 0 then begin
          iAd := pIn1^.u.i;
          iBd := pIn2^.u.i;
          case pOp^.opcode of
            OP_Add:      if sqlite3AddInt64(@iBd, iAd) <> 0 then goto arith_fp;
            OP_Subtract: if sqlite3SubInt64(@iBd, iAd) <> 0 then goto arith_fp;
            OP_Multiply: if sqlite3MulInt64(@iBd, iAd) <> 0 then goto arith_fp;
            OP_Divide: begin
              if iAd = 0 then goto arith_null;
              if (iAd = -1) and (iBd = Low(i64)) then goto arith_fp;
              iBd := iBd div iAd;
            end;
            else begin
              if iAd = 0 then goto arith_null;
              if iAd = -1 then iAd := 1;
              iBd := iBd mod iAd;
            end;
          end;
          pOut^.u.i := iBd;
          pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Int;
          goto arith_done;
        end;
        goto arith_fp;
      end;
      goto arith_done;

      arith_fp:
      rAd := sqlite3VdbeRealValue(pIn1);
      rBd := sqlite3VdbeRealValue(pIn2);
      case pOp^.opcode of
        OP_Add:      rBd := rBd + rAd;
        OP_Subtract: rBd := rBd - rAd;
        OP_Multiply: rBd := rBd * rAd;
        OP_Divide: begin
          if rAd = 0.0 then goto arith_null;
          rBd := rBd / rAd;
        end;
        else begin  { OP_Remainder — integer mod via real }
          iAd := sqlite3VdbeIntValue(pIn1);
          iBd := sqlite3VdbeIntValue(pIn2);
          if iAd = 0 then goto arith_null;
          if iAd = -1 then iAd := 1;
          rBd := Double(iBd mod iAd);
        end;
      end;
      if sqlite3IsNaN(rBd) then goto arith_null;
      pOut^.u.r := rBd;
      pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Real;
      goto arith_done;

      arith_null:
      sqlite3VdbeMemSetNull(pOut);

      arith_done: ;
    end;

    { ────── OP_BitAnd / OP_BitOr / OP_ShiftLeft / OP_ShiftRight ──
      (vdbe.c:2030) P1=in1, P2=in2, P3=out3 }
    OP_BitAnd,
    OP_BitOr,
    OP_ShiftLeft,
    OP_ShiftRight: begin
      pIn1 := @aMem[pOp^.p1];
      pIn2 := @aMem[pOp^.p2];
      pOut := @aMem[pOp^.p3];
      if ((pIn1^.flags or pIn2^.flags) and MEM_Null) <> 0 then begin
        sqlite3VdbeMemSetNull(pOut);
      end else begin
        iAd := sqlite3VdbeIntValue(pIn2);  { note: pIn2 is the shifted value }
        iBd := sqlite3VdbeIntValue(pIn1);  { pIn1 is the shift amount }
        opBd := pOp^.opcode;
        if opBd = OP_BitAnd then
          iAd := iAd and iBd
        else if opBd = OP_BitOr then
          iAd := iAd or iBd
        else begin
          { ShiftLeft or ShiftRight }
          if iBd <> 0 then begin
            if iBd < 0 then begin
              { negative shift: flip direction }
              if opBd = OP_ShiftLeft then opBd := OP_ShiftRight
              else opBd := OP_ShiftLeft;
              if iBd > -64 then iBd := -iBd else iBd := 64;
            end;
            if iBd >= 64 then begin
              if (iAd >= 0) or (opBd = OP_ShiftLeft) then iAd := 0
              else iAd := -1;
            end else begin
              Move(iAd, uAd, SizeOf(uAd));
              if opBd = OP_ShiftLeft then
                uAd := uAd shl iBd
              else begin
                uAd := uAd shr iBd;
                if iAd < 0 then
                  uAd := uAd or (u64($FFFFFFFFFFFFFFFF) shl (64 - iBd));
              end;
              Move(uAd, iAd, SizeOf(iAd));
            end;
          end;
        end;
        pOut^.u.i := iAd;
        pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Int;
      end;
    end;

    { ────── OP_AddImm ────── (vdbe.c:2090) P1=in/out reg, P2=immediate }
    OP_AddImm: begin
      pIn1 := @aMem[pOp^.p1];
      sqlite3VdbeMemIntegerify(pIn1);
      u64(pIn1^.u.i) := u64(pIn1^.u.i) + u64(pOp^.p2);
    end;

    { ────── OP_Eq / OP_Ne / OP_Lt / OP_Le / OP_Gt / OP_Ge ──
      (vdbe.c:2273) P1=in1, P2=jump target, P3=in3, P5=flags|affinity
      Comparison: r[P3] <op> r[P1] → jump to P2 if true.

      Jump decision tables (indexed by opcode, OP_Ne=53..OP_Ge=58):
        aLTb = [1,0,0,1,1,0]  NE,EQ,GT,LE,LT,GE — jump when compare < 0
        aEQb = [0,1,0,1,0,1]  jump when compare = 0
        aGTb = [1,0,1,0,0,1]  jump when compare > 0  }
    OP_Eq,
    OP_Ne,
    OP_Lt,
    OP_Le,
    OP_Gt,
    OP_Ge: begin
      pIn1  := @aMem[pOp^.p1];
      pIn3  := @aMem[pOp^.p3];
      flags1d := pIn1^.flags;
      flags3d := pIn3^.flags;

      if (flags1d and flags3d and MEM_Int) <> 0 then begin
        { Fast integer-vs-integer comparison }
        if pIn3^.u.i > pIn1^.u.i then begin
          { GT case }
          case pOp^.opcode of
            OP_Ne, OP_Gt, OP_Ge: goto cmp_jump;
          else iCompare := +1;
          end;
        end else if pIn3^.u.i < pIn1^.u.i then begin
          { LT case }
          case pOp^.opcode of
            OP_Ne, OP_Le, OP_Lt: goto cmp_jump;
          else iCompare := -1;
          end;
        end else begin
          { EQ case }
          case pOp^.opcode of
            OP_Eq, OP_Le, OP_Ge: goto cmp_jump;
          else iCompare := 0;
          end;
        end;
      end else if ((flags1d or flags3d) and MEM_Null) <> 0 then begin
        { At least one NULL }
        if (pOp^.p5 and SQLITE_NULLEQ) <> 0 then begin
          { NULLEQ: compare NULLs as equal }
          if (flags1d and flags3d and MEM_Null) <> 0 then
            resd := 0  { both NULL → equal }
          else if (flags3d and MEM_Null) <> 0 then
            resd := -1
          else
            resd := +1;
          iCompare := resd;
          if resd = 0 then begin
            case pOp^.opcode of
              OP_Eq, OP_Le, OP_Ge: goto cmp_jump;
            end;
          end else if resd < 0 then begin
            case pOp^.opcode of
              OP_Ne, OP_Le, OP_Lt: goto cmp_jump;
            end;
          end else begin
            case pOp^.opcode of
              OP_Ne, OP_Gt, OP_Ge: goto cmp_jump;
            end;
          end;
        end else begin
          { NULL operand, no NULLEQ: result is NULL → jump only if JUMPIFNULL }
          iCompare := 1;
          if (pOp^.p5 and SQLITE_JUMPIFNULL) <> 0 then
            goto cmp_jump;
        end;
      end else begin
        { General comparison }
        affd := pOp^.p5 and SQLITE_AFF_MASK;
        if affd >= SQLITE_AFF_NUMERIC then begin
          if ((flags1d or flags3d) and MEM_Str) <> 0 then begin
            if (flags1d and (MEM_Int or MEM_IntReal or MEM_Real or MEM_Str)) = MEM_Str then begin
              applyNumericAffinity(pIn1, 0);
              flags3d := pIn3^.flags;
            end;
            if (flags3d and (MEM_Int or MEM_IntReal or MEM_Real or MEM_Str)) = MEM_Str then
              applyNumericAffinity(pIn3, 0);
          end;
        end else if (affd = SQLITE_AFF_TEXT) and (((flags1d or flags3d) and MEM_Str) <> 0) then begin
          if (flags1d and MEM_Str) <> 0 then
            pIn1^.flags := pIn1^.flags and not u16(MEM_Int or MEM_Real or MEM_IntReal)
          else if (flags1d and (MEM_Int or MEM_Real or MEM_IntReal)) <> 0 then begin
            sqlite3VdbeMemStringify(pIn1, enc, 1);
            flags1d := (pIn1^.flags and not u16(MEM_TypeMask)) or (flags1d and MEM_TypeMask);
          end;
          if (flags3d and MEM_Str) <> 0 then
            pIn3^.flags := pIn3^.flags and not u16(MEM_Int or MEM_Real or MEM_IntReal)
          else if (flags3d and (MEM_Int or MEM_Real or MEM_IntReal)) <> 0 then begin
            sqlite3VdbeMemStringify(pIn3, enc, 1);
            flags3d := (pIn3^.flags and not u16(MEM_TypeMask)) or (flags3d and MEM_TypeMask);
          end;
        end;
        resd := sqlite3MemCompare(pIn3, pIn1, pOp^.p4.pColl);
        iCompare := resd;
        { Undo affinity changes }
        pIn3^.flags := flags3d;
        pIn1^.flags := flags1d;

        if resd < 0 then begin
          case pOp^.opcode of
            OP_Ne, OP_Le, OP_Lt: goto cmp_jump;
          end;
        end else if resd = 0 then begin
          case pOp^.opcode of
            OP_Eq, OP_Le, OP_Ge: goto cmp_jump;
          end;
        end else begin
          case pOp^.opcode of
            OP_Ne, OP_Gt, OP_Ge: goto cmp_jump;
          end;
        end;
      end;
      goto cmp_done;

      cmp_jump:
      goto jump_to_p2;

      cmp_done: ;
    end;

    { ────── OP_AggInverse / OP_AggStep ────── (vdbe.c:7837)
      First execution: allocate sqlite3_context + pOut Mem, convert to OP_AggStep1. }
    OP_AggInverse,
    OP_AggStep: begin
      { Allocate context: SZ_CONTEXT(p5) = 48 + p5*8, plus SizeOf(TMem) for pOut }
      n     := pOp^.p5;
      nByte := ((SizeOf(Tsqlite3_context) + 7) and not 7) + n * SizeOf(PMem);
      pCtxAgg := Psqlite3_context(sqlite3DbMallocRawNN(db, nByte + SizeOf(TMem)));
      if pCtxAgg = nil then goto no_mem;
      pCtxAgg^.pOut := PMem(PByte(pCtxAgg) + nByte);
      sqlite3VdbeMemInit(pCtxAgg^.pOut, Psqlite3(db), MEM_Null);
      pCtxAgg^.pMem     := nil;
      pCtxAgg^.pFunc    := pOp^.p4.pFunc;
      pCtxAgg^.iOp      := i32(pOp - aOp);
      pCtxAgg^.pVdbe    := v;
      pCtxAgg^.skipFlag  := 0;
      pCtxAgg^.isError   := 0;
      pCtxAgg^.enc       := enc;
      pCtxAgg^.argc      := u16(n);
      pOp^.p4type        := P4_FUNCCTX;
      pOp^.p4.pCtx       := pCtxAgg;
      if pOp^.opcode = OP_AggInverse then
        pOp^.p1 := 1
      else
        pOp^.p1 := 0;
      pOp^.opcode := OP_AggStep1;
      { fall through to OP_AggStep1 — re-dispatch }
      goto agg_step1_body;
    end;

    { ────── OP_AggStep1 ────── (vdbe.c:7881) }
    OP_AggStep1: begin
      agg_step1_body:
      pCtxAgg := pOp^.p4.pCtx;
      if pCtxAgg^.pMem <> @aMem[pOp^.p3] then begin
        pCtxAgg^.pMem := @aMem[pOp^.p3];
        { set up argv: n pointers after the context struct }
        for ii := pCtxAgg^.argc - 1 downto 0 do
          PPMem(PByte(pCtxAgg) + ((SizeOf(Tsqlite3_context)+7) and not 7))[ii]
            := @aMem[pOp^.p2 + ii];
      end;
      Inc(aMem[pOp^.p3].n);
      { call step or inverse }
      pFdAgg := PTFuncDef(pCtxAgg^.pFunc);
      if pFdAgg <> nil then begin
        if (pOp^.p1 <> 0) and Assigned(pFdAgg^.xInverse) then
          pFdAgg^.xInverse(pCtxAgg, pCtxAgg^.argc,
            PPMem(PByte(pCtxAgg) + ((SizeOf(Tsqlite3_context)+7) and not 7)))
        else if Assigned(pFdAgg^.xSFunc) then
          pFdAgg^.xSFunc(pCtxAgg, pCtxAgg^.argc,
            PPMem(PByte(pCtxAgg) + ((SizeOf(Tsqlite3_context)+7) and not 7)));
      end;
      if pCtxAgg^.isError <> 0 then begin
        { Mirror vdbe.c:7928..7942 — when xSFunc reported an error via
          sqlite3_result_error, the message sits as TEXT in pCtx^.pOut.
          Lift it into the vdbe's zErrMsg BEFORE we release pOut, else
          OP_AggFinal / sqlite3_step report a generic "SQL logic error".
          Ported for 9.4.divbug.51 (json_group_array(BLOB) sub-case). }
        rc := pCtxAgg^.isError;
        if rc > 0 then
          sqlite3VdbeError(v, PAnsiChar(sqlite3_value_text(
            Psqlite3_value(pCtxAgg^.pOut))));
        { Magnet wiring (vdbe.c:7933..7938).  min/max's skipFlag uses
          isError=-1 as a non-rc carrier — set the magnet register so
          updateAccumulator's OP_If gate skips bare-column reload on
          this non-bumping row.  Required for `SELECT bare, max(x)`
          sticky-row semantics (divbug.14 residual aggorderby-4.1). }
        if pCtxAgg^.skipFlag <> 0 then begin
          { Preceding op must be OP_CollSeq; its p1 is the magnet reg. }
          if (PtrUInt(pOp) >= PtrUInt(aOp) + SizeOf(TVdbeOp))
             and ((pOp - 1)^.opcode = OP_CollSeq) then
          begin
            ii := (pOp - 1)^.p1;
            if ii > 0 then sqlite3VdbeMemSetInt64(@aMem[ii], 1);
          end;
          pCtxAgg^.skipFlag := 0;
        end;
        sqlite3VdbeMemRelease(pCtxAgg^.pOut);
        pCtxAgg^.pOut^.flags := MEM_Null;
        pCtxAgg^.isError := 0;
        if rc > 0 then goto abort_due_to_error;
      end;
    end;

    { ────── OP_AggFinal / OP_AggValue ────── (vdbe.c:7975) }
    OP_AggValue,
    OP_AggFinal: begin
      if (pOp^.opcode = OP_AggValue) and (pOp^.p3 > 0) then begin
        rc := sqlite3VdbeMemAggValue(@aMem[pOp^.p1], @aMem[pOp^.p3], pOp^.p4.pFunc);
        if rc <> SQLITE_OK then begin
          sqlite3VdbeError(v, 'aggregate value error');
          goto abort_due_to_error;
        end;
      end else begin
        rc := sqlite3VdbeMemFinalize(@aMem[pOp^.p1], pOp^.p4.pFunc);
        if rc <> SQLITE_OK then begin
          { Mirror vdbe.c:7993 — finalizer reported an error; the message
            sits in pMem as TEXT (set by sqlite3_result_error in the
            xFinalize callback). }
          sqlite3VdbeError(v,
            PAnsiChar(sqlite3_value_text(Psqlite3_value(@aMem[pOp^.p1]))));
          goto abort_due_to_error;
        end;
      end;
      rc := sqlite3VdbeChangeEncoding(@aMem[pOp^.p1], enc);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      UpdateMaxBlobsize(@aMem[pOp^.p1]);   { vdbe.c:7998 }
    end;

    { ────── OP_Real ────── (vdbe.c:1397)
      out2: r[P2] = *P4.pReal }
    OP_Real: begin
      pOut := out2Prerelease(v, pOp);
      pOut^.flags := MEM_Real;
      pOut^.u.r   := pOp^.p4.pReal^;
    end;

    { ────── OP_HaltIfNull ────── (vdbe.c:1249)
      in3: if r[P3] is NULL, fall through to OP_Halt }
    OP_HaltIfNull: begin
      pIn3 := @aMem[pOp^.p3];
      if (pIn3^.flags and MEM_Null) = 0 then begin
        { not NULL — do nothing }
      end else begin
        { NULL — execute halt logic, mirroring OP_Halt fall-through (vdbe.c:1257) }
        v^.rc := pOp^.p1;
        v^.errorAction := u8(pOp^.p2);
        if v^.rc <> 0 then begin
          if pOp^.p5 <> 0 then begin
            case pOp^.p5 of
              1: sqlite3VdbeError(v, 'NOT NULL constraint failed');
              2: sqlite3VdbeError(v, 'UNIQUE constraint failed');
              3: sqlite3VdbeError(v, 'CHECK constraint failed');
              4: sqlite3VdbeError(v, 'FOREIGN KEY constraint failed');
            else sqlite3VdbeError(v, 'constraint failed');
            end;
            if pOp^.p4.z <> nil then
              v^.zErrMsg := sqlite3MPrintf(db, '%z: %s',
                              [v^.zErrMsg, pOp^.p4.z]);
          end else if pOp^.p4.z <> nil then
            sqlite3VdbeError(v, pOp^.p4.z);
          sqlite3VdbeLogAbort(v, pOp^.p1, pOp, aOp);
        end;
        rc := sqlite3VdbeHalt(v);
        if rc = SQLITE_BUSY then v^.rc := SQLITE_BUSY
        else if v^.rc <> 0 then rc := SQLITE_ERROR
        else rc := SQLITE_DONE;
        goto vdbe_return;
      end;
    end;

    { ────── OP_Variable ────── (vdbe.c:1575)
      out2: r[P2] = parameter P1 }
    OP_Variable: begin
      pVarH := @v^.aVar[pOp^.p1 - 1];
      if sqlite3VdbeMemTooBig(pVarH) <> 0 then goto too_big;
      pOut := @aMem[pOp^.p2];
      if vdbeMemDynamic(pOut) then sqlite3VdbeMemSetNull(pOut);
      Move(pVarH^, pOut^, MEMCELLSIZE);
      pOut^.flags := pOut^.flags and not u16(MEM_Dyn or MEM_Ephem);
      pOut^.flags := pOut^.flags or u16(MEM_Static or MEM_FromBind);
      UpdateMaxBlobsize(pOut);   { vdbe.c:1588 }
    end;

    { ────── OP_CollSeq ────── (vdbe.c:1992)
      P1: if nonzero, set r[P1] = 0 (integer) }
    OP_CollSeq: begin
      if pOp^.p1 <> 0 then
        sqlite3VdbeMemSetInt64(@aMem[pOp^.p1], 0);
    end;

    { ────── OP_MustBeInt ────── (vdbe.c:2105)
      jump0, in1: ensure r[P1] is integer; jump or error if not }
    OP_MustBeInt: begin
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and MEM_Int) = 0 then begin
        applyAffinity(pIn1, AnsiChar(SQLITE_AFF_NUMERIC), enc);
        if (pIn1^.flags and MEM_Int) = 0 then begin
          if pOp^.p2 = 0 then begin
            rc := SQLITE_MISMATCH;
            goto abort_due_to_error;
          end else
            goto jump_to_p2;
        end;
      end;
      pIn1^.flags := (pIn1^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Int;
    end;

    { ────── OP_RealAffinity ────── (vdbe.c:2134)
      in1: if r[P1] is int, convert to real }
    OP_RealAffinity: begin
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and (MEM_Int or MEM_IntReal)) <> 0 then
        sqlite3VdbeMemRealify(pIn1);
    end;

    { ────── OP_Cast ────── (vdbe.c:2162)
      in1: CAST r[P1] to affinity P2 }
    OP_Cast: begin
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and MEM_Zero) <> 0 then begin
        rc := sqlite3VdbeMemExpandBlob(pIn1);
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end;
      rc := sqlite3VdbeMemCast(pIn1, u8(pOp^.p2), enc);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      UpdateMaxBlobsize(pIn1);   { vdbe.c:2175 }
    end;

    { ────── OP_And / OP_Or ────── (vdbe.c:2594)
      in1, in2, out3: boolean AND / OR with NULL propagation }
    OP_And,
    OP_Or: begin
      v1h := sqlite3VdbeBooleanValue(@aMem[pOp^.p1], 2);
      v2h := sqlite3VdbeBooleanValue(@aMem[pOp^.p2], 2);
      if pOp^.opcode = OP_And then begin
        case v1h * 3 + v2h of
          0: v1h := 0;   { F,F→0 }
          1: v1h := 0;   { F,T→0 }
          2: v1h := 0;   { F,N→0 }
          3: v1h := 0;   { T,F→0 }
          4: v1h := 1;   { T,T→1 }
          5: v1h := 2;   { T,N→N }
          6: v1h := 0;   { N,F→0 }
          7: v1h := 2;   { N,T→N }
          else v1h := 2; { N,N→N }
        end;
      end else begin
        case v1h * 3 + v2h of
          0: v1h := 0;   { F,F→0 }
          1: v1h := 1;   { F,T→1 }
          2: v1h := 2;   { F,N→N }
          3: v1h := 1;   { T,F→1 }
          4: v1h := 1;   { T,T→1 }
          5: v1h := 1;   { T,N→1 }
          6: v1h := 2;   { N,F→N }
          7: v1h := 1;   { N,T→1 }
          else v1h := 2; { N,N→N }
        end;
      end;
      pOut := @aMem[pOp^.p3];
      if v1h = 2 then
        pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Null
      else begin
        pOut^.u.i := v1h;
        pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Int;
      end;
    end;

    { ────── OP_IsTrue ────── (vdbe.c:2638)
      in1, out2: r[P2] = (r[P1]==TRUE, else P3) XOR P4 }
    OP_IsTrue: begin
      sqlite3VdbeMemSetInt64(@aMem[pOp^.p2],
        sqlite3VdbeBooleanValue(@aMem[pOp^.p1], pOp^.p3) xor pOp^.p4.i);
    end;

    { ────── OP_Not ────── (vdbe.c:2654)
      in1, out2: r[P2] = !r[P1] (NULL if in1 is NULL) }
    OP_Not: begin
      pIn1 := @aMem[pOp^.p1];
      pOut := @aMem[pOp^.p2];
      if (pIn1^.flags and MEM_Null) = 0 then
        sqlite3VdbeMemSetInt64(pOut, i64(sqlite3VdbeBooleanValue(pIn1, 0) = 0))
      else
        sqlite3VdbeMemSetNull(pOut);
    end;

    { ────── OP_BitNot ────── (vdbe.c:2672)
      in1, out2: r[P2] = ~r[P1] (NULL if in1 is NULL) }
    OP_BitNot: begin
      pIn1 := @aMem[pOp^.p1];
      pOut := @aMem[pOp^.p2];
      sqlite3VdbeMemSetNull(pOut);
      if (pIn1^.flags and MEM_Null) = 0 then begin
        pOut^.flags := MEM_Int;
        pOut^.u.i   := not sqlite3VdbeIntValue(pIn1);
      end;
    end;

    { ────── OP_IsNull ────── (vdbe.c:2760)
      jump, in1: if r[P1] IS NULL goto P2 }
    OP_IsNull: begin
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and MEM_Null) <> 0 then goto jump_to_p2;
    end;

    { ────── OP_NotNull ────── (vdbe.c:2885)
      jump, in1: if r[P1] IS NOT NULL goto P2 }
    OP_NotNull: begin
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and MEM_Null) = 0 then goto jump_to_p2;
    end;

    { ────── OP_ZeroOrNull ────── (vdbe.c:2869)
      in1, in2, out2, in3: r[P2]=0 if r[P1] and r[P3] not NULL, else NULL }
    OP_ZeroOrNull: begin
      if ((aMem[pOp^.p1].flags or aMem[pOp^.p3].flags) and MEM_Null) <> 0 then
        sqlite3VdbeMemSetNull(@aMem[pOp^.p2])
      else
        sqlite3VdbeMemSetInt64(@aMem[pOp^.p2], 0);
    end;

    { ────── OP_IfNullRow ────── (vdbe.c:2904)
      jump: if cursor P1 has nullRow, set r[P3]=NULL and goto P2 }
    OP_IfNullRow: begin
      if (pOp^.p1 >= 0) and (pOp^.p1 < v^.nCursor) then begin
        pCur := v^.apCsr[pOp^.p1];
        if (pCur <> nil) and (pCur^.nullRow <> 0) then begin
          sqlite3VdbeMemSetNull(@aMem[pOp^.p3]);
          goto jump_to_p2;
        end;
      end;
    end;

    { ────── OP_IsType ────── (vdbe.c:2800)
      jump: if typeof(cursor P1, col P3) matches bitmask P5, goto P2 }
    OP_IsType: begin
      if pOp^.p1 >= 0 then begin
        pCur := v^.apCsr[pOp^.p1];
        if (pCur <> nil) and (pOp^.p3 < i32(pCur^.nHdrParsed)) then begin
          serialTypeH := Pu32(Pu8(pCur) + 120)[pOp^.p3];
          if serialTypeH >= 12 then begin
            if (serialTypeH and 1) <> 0 then typeMaskH := $04  { text }
            else                              typeMaskH := $08; { blob }
          end else
            case serialTypeH of
              0:  typeMaskH := $10;  { null }
              7:  typeMaskH := $02;  { float }
              10, 11: typeMaskH := $10;  { null (special) }
              else    typeMaskH := $01;  { integer }
            end;
        end else
          typeMaskH := u16(1 shl (pOp^.p4.i - 1));
      end else begin
        { P1<0: register mode — derive type from Mem flags }
        if (aMem[pOp^.p3].flags and MEM_Null)    <> 0 then typeMaskH := $10
        else if (aMem[pOp^.p3].flags and MEM_Int)    <> 0 then typeMaskH := $01
        else if (aMem[pOp^.p3].flags and MEM_Real)   <> 0 then typeMaskH := $02
        else if (aMem[pOp^.p3].flags and MEM_Str)    <> 0 then typeMaskH := $04
        else if (aMem[pOp^.p3].flags and MEM_Blob)   <> 0 then typeMaskH := $08
        else typeMaskH := $10;
      end;
      if (typeMaskH and u16(pOp^.p5)) <> 0 then goto jump_to_p2;
    end;

    { ────── OP_Affinity ────── (vdbe.c:3404)
      Apply affinity string P4 to registers P1..P1+P2-1 }
    OP_Affinity: begin
      pIn1 := @aMem[pOp^.p1];
      n    := pOp^.p2;
      i    := 0;
      while i < n do begin
        applyAffinity(pIn1, pOp^.p4.z[i], enc);
        if (pOp^.p4.z[i] = AnsiChar(SQLITE_AFF_REAL)) and
           ((pIn1^.flags and MEM_Int) <> 0) then begin
          if (pIn1^.u.i <= 140737488355327) and (pIn1^.u.i >= -140737488355328) then begin
            pIn1^.flags := pIn1^.flags or MEM_IntReal;
            pIn1^.flags := pIn1^.flags and not u16(MEM_Int);
          end else begin
            pIn1^.u.r   := Double(pIn1^.u.i);
            pIn1^.flags := pIn1^.flags or MEM_Real;
            pIn1^.flags := pIn1^.flags and not u16(MEM_Int or MEM_Str);
          end;
        end;
        Inc(pIn1);
        Inc(i);
      end;
    end;

    { ────── OP_Function ────── (vdbe.c:8850)
      group: call scalar function via P4.pCtx (set up by OP_Function's first run) }
    OP_Function: begin
      op_function_body:
      pCtxAgg := pOp^.p4.pCtx;
      pOut := @aMem[pOp^.p3];
      if pCtxAgg^.pOut <> pOut then begin
        pCtxAgg^.pVdbe := v;
        pCtxAgg^.pOut  := pOut;
        pCtxAgg^.enc   := enc;
        for ii := pCtxAgg^.argc - 1 downto 0 do
          PPMem(PByte(pCtxAgg) + ((SizeOf(Tsqlite3_context)+7) and not 7))[ii]
            := @aMem[pOp^.p2 + ii];
      end;
      pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Null;
      pFdAgg := PTFuncDef(pCtxAgg^.pFunc);
      if (pFdAgg <> nil) and Assigned(pFdAgg^.xSFunc) then
        pFdAgg^.xSFunc(pCtxAgg, pCtxAgg^.argc,
          PPMem(PByte(pCtxAgg) + ((SizeOf(Tsqlite3_context)+7) and not 7)));
      if pCtxAgg^.isError <> 0 then begin
        if pCtxAgg^.isError > 0 then begin
          sqlite3VdbeError(v, sqlite3_value_text(Psqlite3_value(pOut)));
          rc := pCtxAgg^.isError;
        end;
        pCtxAgg^.isError := 0;
        if rc <> 0 then goto abort_due_to_error;
      end;
      UpdateMaxBlobsize(pOut);   { vdbe.c:8898 }
    end;

    { ────── OP_Noop / OP_Explain ────── }
    OP_Noop,
    OP_Explain: begin
      { no-op }
    end;

    { ────── OP_ClrSubtype ────── (vdbe.c:8902) }
    OP_ClrSubtype: begin
      pIn1 := @aMem[pOp^.p1];
      pIn1^.flags := pIn1^.flags and not u16(MEM_Subtype);
    end;

    { ────── OP_GetSubtype ────── (vdbe.c:8913) }
    OP_GetSubtype: begin
      pIn1 := @aMem[pOp^.p1];
      pOut := @aMem[pOp^.p2];
      if (pIn1^.flags and MEM_Subtype) <> 0 then
        sqlite3VdbeMemSetInt64(pOut, pIn1^.eSubtype)
      else
        sqlite3VdbeMemSetNull(pOut);
    end;

    { ────── OP_SetSubtype ────── (vdbe.c:8930) }
    OP_SetSubtype: begin
      pIn1 := @aMem[pOp^.p1];
      pOut := @aMem[pOp^.p2];
      if (pIn1^.flags and MEM_Null) <> 0 then
        pOut^.flags := pOut^.flags and not u16(MEM_Subtype)
      else begin
        pOut^.flags := pOut^.flags or MEM_Subtype;
        pOut^.eSubtype := u8(pIn1^.u.i and $FF);
      end;
    end;

    { ────── OP_Transaction ────── (vdbe.c:4102)
      P1=db-index, P2=wrflag(0=read,1=write,2=exclusive), P3=cookie, P4=gen, P5=scheckflag }
    OP_Transaction: begin
      iMeta5g := 0;
      { vdbe.c:4113..4123 — PRAGMA query_only / prior CORRUPT in txn
        prohibit a write-transaction open. }
      if (pOp^.p2 <> 0) and
         ((db^.flags and (SQLITE_QueryOnly or SQLITE_CorruptRdOnly)) <> 0) then
      begin
        if (db^.flags and SQLITE_QueryOnly) <> 0 then
          rc := SQLITE_READONLY
        else
          rc := SQLITE_CORRUPT;
        goto abort_due_to_error;
      end;
      if pOp^.p1 >= 0 then begin
        pDbb := @db^.aDb[pOp^.p1];
        pX   := PBtree(pDbb^.pBt);
        if pX <> nil then begin
          rc := sqlite3BtreeBeginTrans(pX, pOp^.p2, @iMeta5g);
          if rc <> SQLITE_OK then begin
            if (rc and $FF) = SQLITE_BUSY then begin
              v^.pc := i32(pOp - aOp);
              v^.rc := rc;
              goto vdbe_return;
            end;
            goto abort_due_to_error;
          end;

          { vdbe.c:4140..4161 — open a statement-journal savepoint if this VM
            uses one (usesStmtJournal = isMultiWrite && mayAbort) and we are
            opening a write transaction nested inside an outer BEGIN…COMMIT
            (autoCommit=0) or with concurrent readers (nVdbeRead>1).  Without
            this arm an aborted CREATE INDEX inside a user transaction cannot
            be rolled back at the btree level — the sqlite_master row + freshly
            allocated root page survive the COMMIT and integrity_check reports
            "Page N: never used" (9.4.divbug.87.026, index3-1.4). }
          if ((v^.vdbeFlags and VDBF_UsesStmtJournal) <> 0)
             and (pOp^.p2 <> 0)
             and ((db^.autoCommit = 0) or (db^.nVdbeRead > 1)) then begin
            if v^.iStatement = 0 then begin
              Inc(db^.nStatement);
              v^.iStatement := db^.nSavepoint + db^.nStatement;
            end;
            rc := sqlite3VtabSavepoint(db, SAVEPOINT_BEGIN, v^.iStatement - 1);
            if rc = SQLITE_OK then
              rc := sqlite3BtreeBeginStmt(pX, v^.iStatement);
            { Snapshot deferred-FK counters for matching statement-rollback. }
            v^.nStmtDefCons    := db^.nDeferredCons;
            v^.nStmtDefImmCons := db^.nDeferredImmCons;
          end;
        end;
        { Schema cookie check — vdbe.c:4163..4198.
          When P5≠0, compare iMeta (BeginTrans-returned file cookie) against
          P3 (cookie at prepare time) and pSchema->iGeneration against P4.i
          (generation at prepare time).  Mismatch → SQLITE_SCHEMA so the
          sqlite3_step() wrapper can reprepare via sqlite3Reprepare().
          Without this gate, statements like SELECT against a table dropped
          by a concurrent backup keep using stale schema and the cursor
          decodes raw pages as the gone table — surfaces as bogus
          SQLITE_CORRUPT (backup5-1.6).  C cite: vdbe.c:4163..4197.
          NOTE: in C this check lives OUTSIDE the `if(pBt)` block (vdbe.c:4163
          follows the closing brace at 4161), so it still fires when the btree
          is null — e.g. the TEMP db (iDb=1) after `PRAGMA temp_store=…` ran
          invalidateTempStorage (sqlite3BtreeClose + aDb[1].pBt:=nil +
          sqlite3ResetAllSchemasOfConnection bumped the temp schema's
          iGeneration).  iMeta stays 0 there, so the iGeneration mismatch
          alone raises SQLITE_SCHEMA and the cached stmt reprepares instead of
          falling through to OP_OpenRead and dereferencing the nil temp btree
          (segfault). }
        if (rc = SQLITE_OK) and (pOp^.p5 <> 0) then begin
          if pDbb^.pSchema <> nil then begin
            if (iMeta5g <> pOp^.p3) or
               (PSchema(pDbb^.pSchema)^.iGeneration <> pOp^.p4.i) then
            begin
              sqlite3DbFree(db, v^.zErrMsg);
              v^.zErrMsg := PAnsiChar(sqlite3DbStrDup(db,
                'database schema has changed'));
              { Only reset the schema if the on-disk cookie has changed; a
                pure iGeneration mismatch (e.g. v-table reload) keeps the
                cached schema alive — vdbe.c:4187..4190. }
              if PSchema(pDbb^.pSchema)^.schema_cookie <> iMeta5g then begin
                if Assigned(gResetOneSchema) then
                  gResetOneSchema(db, pOp^.p1);
              end;
              v^.vdbeFlags :=
                (v^.vdbeFlags and not u32(VDBF_EXPIRED_MASK)) or 1;
              rc := SQLITE_SCHEMA;
              v^.vdbeFlags := v^.vdbeFlags and not u32(VDBF_ChangeCntOn);
            end;
          end;
        end;
      end;
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_Savepoint ────── (vdbe.c:3823)
      P1=SAVEPOINT_BEGIN(0)/RELEASE(1)/ROLLBACK(2), P4.z=name }
    OP_Savepoint: begin
      { Faithful port of vdbe.c:3823.  Replaces the prior structural-only
        port that omitted the actual sqlite3BtreeSavepoint /
        sqlite3BtreeTripAllCursors calls (the per-db rollback/release work)
        as well as the nVdbeWrite BUSY guards and the vtab-savepoint hook.
        Closes 6.10 step 15(c). }
      zSvptName5g := pOp^.p4.z;
      if pOp^.p1 = SAVEPOINT_BEGIN then begin
        if db^.nVdbeWrite > 0 then begin
          sqlite3VdbeError(v, 'cannot open savepoint - SQL statements in progress');
          rc := SQLITE_BUSY;
        end else begin
          nSvptName5g := sqlite3Strlen30(PChar(zSvptName5g));
          rc := sqlite3VtabSavepoint(db, SAVEPOINT_BEGIN,
                  db^.nStatement + db^.nSavepoint);
          if rc <> SQLITE_OK then goto abort_due_to_error;
          pNewSvpt5g := PSavepoint(
            sqlite3DbMallocRawNN(db, SizeOf(TSavepoint) + nSvptName5g + 1));
          if pNewSvpt5g <> nil then begin
            pNewSvpt5g^.zName := PAnsiChar(PByte(pNewSvpt5g) + SizeOf(TSavepoint));
            Move(zSvptName5g^, pNewSvpt5g^.zName^, nSvptName5g + 1);
            if db^.autoCommit <> 0 then begin
              db^.autoCommit              := 0;
              db^.isTransactionSavepoint  := 1;
            end else
              Inc(db^.nSavepoint);
            pNewSvpt5g^.pNext            := db^.pSavepoint;
            db^.pSavepoint               := pNewSvpt5g;
            pNewSvpt5g^.nDeferredCons    := db^.nDeferredCons;
            pNewSvpt5g^.nDeferredImmCons := db^.nDeferredImmCons;
          end;
        end;
      end else begin
        Assert((pOp^.p1 = SAVEPOINT_RELEASE) or (pOp^.p1 = SAVEPOINT_ROLLBACK));
        iSvpt5g := 0;
        pSvpt5g := db^.pSavepoint;
        while (pSvpt5g <> nil) and
              (sqlite3StrICmp(PChar(pSvpt5g^.zName), PChar(zSvptName5g)) <> 0) do begin
          Inc(iSvpt5g);
          pSvpt5g := pSvpt5g^.pNext;
        end;
        if pSvpt5g = nil then begin
          { C: sqlite3VdbeError(p, "no such savepoint: %s", zName) — vdbe.c:3902.
            Pascal sqlite3VdbeError takes a pre-formatted string and DbStrDup's
            it; format via sqlite3MPrintf into a temp buffer, then free. }
          zSvptFmtMsg5g := PAnsiChar(sqlite3MPrintf(PTsqlite3(db),
            'no such savepoint: %s', [zSvptName5g]));
          sqlite3VdbeError(v, zSvptFmtMsg5g);
          sqlite3DbFree(db, zSvptFmtMsg5g);
          rc := SQLITE_ERROR;
        end else if (db^.nVdbeWrite > 0) and (pOp^.p1 = SAVEPOINT_RELEASE) then begin
          sqlite3VdbeError(v,
            'cannot release savepoint - SQL statements in progress');
          rc := SQLITE_BUSY;
        end else begin
          isTxnSvpt5g := ord((pSvpt5g^.pNext = nil)
                          and (db^.isTransactionSavepoint <> 0));
          if (isTxnSvpt5g <> 0) and (pOp^.p1 = SAVEPOINT_RELEASE) then begin
            rc := sqlite3VdbeCheckFkDeferred(v);
            if rc <> SQLITE_OK then goto vdbe_return;
            db^.autoCommit := 1;
            if sqlite3VdbeHalt(v) = SQLITE_BUSY then begin
              v^.pc := i32(pOp - aOp);
              db^.autoCommit := 0;
              v^.rc := SQLITE_BUSY;
              rc    := SQLITE_BUSY;
              goto vdbe_return;
            end;
            rc := v^.rc;
            if rc <> 0 then
              db^.autoCommit := 0
            else
              db^.isTransactionSavepoint := 0;
          end else begin
            iSvpt5g := db^.nSavepoint - iSvpt5g - 1;
            if pOp^.p1 = SAVEPOINT_ROLLBACK then begin
              if (db^.mDbFlags and DBFLAG_SchemaChange) <> 0 then
                isSchemaChange5g := 1
              else
                isSchemaChange5g := 0;
              for iSvptii5g := 0 to db^.nDb - 1 do begin
                rc := sqlite3BtreeTripAllCursors(PBtree(db^.aDb[iSvptii5g].pBt),
                        SQLITE_ABORT_ROLLBACK,
                        ord(isSchemaChange5g = 0));
                if rc <> SQLITE_OK then goto abort_due_to_error;
              end;
            end else begin
              isSchemaChange5g := 0;
            end;
            for iSvptii5g := 0 to db^.nDb - 1 do begin
              rc := sqlite3BtreeSavepoint(PBtree(db^.aDb[iSvptii5g].pBt),
                      pOp^.p1, iSvpt5g);
              if rc <> SQLITE_OK then goto abort_due_to_error;
            end;
            if isSchemaChange5g <> 0 then begin
              sqlite3ExpirePreparedStatements(db, 0);
              sqlite3ResetAllSchemasOfConnection(db);
              db^.mDbFlags := db^.mDbFlags or u32(DBFLAG_SchemaChange);
            end;
          end;
          if rc <> 0 then goto abort_due_to_error;

          { Destroy any savepoints nested inside the one being operated on. }
          while db^.pSavepoint <> pSvpt5g do begin
            pTmpSvpt5g       := db^.pSavepoint;
            db^.pSavepoint   := pTmpSvpt5g^.pNext;
            sqlite3DbFree(db, pTmpSvpt5g);
            Dec(db^.nSavepoint);
          end;
          if pOp^.p1 = SAVEPOINT_RELEASE then begin
            Assert(pSvpt5g = db^.pSavepoint);
            db^.pSavepoint := pSvpt5g^.pNext;
            sqlite3DbFree(db, pSvpt5g);
            if isTxnSvpt5g = 0 then Dec(db^.nSavepoint);
          end else begin
            { ROLLBACK TO: restore deferred-FK counters from the snapshot. }
            db^.nDeferredCons    := pSvpt5g^.nDeferredCons;
            db^.nDeferredImmCons := pSvpt5g^.nDeferredImmCons;
          end;
          if isTxnSvpt5g = 0 then begin
            { Notify vtabs of the savepoint change. }
            rc := sqlite3VtabSavepoint(db, pOp^.p1, iSvpt5g);
            if rc <> SQLITE_OK then goto abort_due_to_error;
          end;
        end;
      end;
      if rc <> 0 then goto abort_due_to_error;
    end;

    { ────── OP_AutoCommit ────── (vdbe.c:4013)
      P1=desiredAutoCommit(1=commit,0=begin), P2=rollback flag }
    OP_AutoCommit: begin
      desiredAC5g := pOp^.p1;
      iRollback5g := pOp^.p2;
      if desiredAC5g <> i32(db^.autoCommit) then begin
        if iRollback5g <> 0 then begin
          { assert( desiredAutoCommit==1 ) }
          sqlite3RollbackAll(db, SQLITE_ABORT_ROLLBACK);
          db^.autoCommit := 1;
        end else if (desiredAC5g <> 0) and (db^.nVdbeWrite > 0) then begin
          { vdbe.c:4032 — this instruction implements a COMMIT but other VMs
            are still writing; tell the caller they must complete first. }
          sqlite3VdbeError(v,
            'cannot commit transaction - SQL statements in progress');
          rc := SQLITE_BUSY;
          goto abort_due_to_error;
        end else begin
          rc := sqlite3VdbeCheckFkDeferred(v);
          if rc <> SQLITE_OK then
            goto vdbe_return;
          db^.autoCommit := u8(desiredAC5g);
        end;
        { vdbe.c:4044 — if sqlite3VdbeHalt could not obtain the required
          locks (another connection holds a conflicting lock), the commit
          must be retried.  Rewind pc, restore autoCommit, and surface
          SQLITE_BUSY.  The previous Pascal port ignored VdbeHalt's return
          value, so a cross-connection lock conflict on COMMIT was silently
          reported as success (9.4.divbug.21). }
        if sqlite3VdbeHalt(v) = SQLITE_BUSY then begin
          v^.pc := i32(pOp - aOp);
          db^.autoCommit := u8(1 - desiredAC5g);
          v^.rc := SQLITE_BUSY;
          rc    := SQLITE_BUSY;
          goto vdbe_return;
        end;
        sqlite3CloseSavepoints(db);
        if v^.rc = SQLITE_OK then
          rc := SQLITE_DONE
        else
          rc := SQLITE_ERROR;
        goto vdbe_return;
      end else begin
        if desiredAC5g = 0 then
          sqlite3VdbeError(v, 'cannot start a transaction within a transaction')
        else if iRollback5g <> 0 then
          sqlite3VdbeError(v, 'cannot rollback - no transaction is active')
        else
          sqlite3VdbeError(v, 'cannot commit - no transaction is active');
        rc := SQLITE_ERROR;
        goto abort_due_to_error;
      end;
    end;

    { ────── OP_Once ────── (vdbe.c:2706) }
    { Run the body only once per VM invocation.  On second and subsequent
      calls, jump to P2.  Uses bit in aOp[0].p1 (main frame) or aOnce[]
      bitmask (sub-frame) to remember whether the body has been run. }
    OP_Once: begin
      if v^.pFrame <> nil then begin
        pcx := i32((PByte(pOp) - PByte(aOp)) div SizeOf(TVdbeOp));
        if (v^.pFrame^.aOnce[pcx shr 3] and u8(1 shl (pcx and 7))) <> 0 then
          goto jump_to_p2;
        v^.pFrame^.aOnce[pcx shr 3] :=
          v^.pFrame^.aOnce[pcx shr 3] or u8(1 shl (pcx and 7));
      end else begin
        if aOp[0].p1 = pOp^.p1 then
          goto jump_to_p2;
      end;
      pOp^.p1 := aOp[0].p1;
    end;

    { ────── OP_IfEmpty ────── (vdbe.c:6413) }
    { Jump to P2 if the b-tree table pointed to by cursor P1 is empty
      (contains zero rows).  Reports an error on I/O failure. }
    OP_IfEmpty: begin
      pCur  := v^.apCsr[pOp^.p1];
      pCrsr := pCur^.uc.pCursor;
      rc := sqlite3BtreeIsEmpty(pCrsr, @res);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if res <> 0 then goto jump_to_p2;
    end;

    { ────── OP_ReopenIdx ────── (vdbe.c:4386) }
    { Reopen cursor P1 on index root P2 in database P3.  If the cursor is
      already open on the correct root page, clear it and reuse it; otherwise
      open a fresh read-only b-tree cursor (equivalent to OP_OpenRead). }
    OP_ReopenIdx: begin
      pCur := v^.apCsr[pOp^.p1];
      if (pCur <> nil) and (pCur^.pgnoRoot = u32(pOp^.p2)) then begin
        sqlite3BtreeClearCursor(pCur^.uc.pCursor);
        pCur^.nullRow     := 1;
        pCur^.cacheStatus := CACHE_STALE;
        goto open_cursor_set_hints;
      end;
      { Root-page mismatch — open a new read cursor, mirroring OP_OpenRead }
      nField   := 0;
      pKInfo   := nil;
      p2       := u32(pOp^.p2);
      iDb      := pOp^.p3;
      pDbb     := @db^.aDb[iDb];
      pX       := PBtree(pDbb^.pBt);
      if pOp^.p4type = P4_KEYINFO then begin
        pKInfo := pOp^.p4.pKeyInfo;
        nField := i32(Pu16(Pu8(pKInfo) + 8)^);
      end else if pOp^.p4type = P4_INT32 then begin
        nField := pOp^.p4.i;
      end;
      pCur := allocateCursor(v, pOp^.p1, nField, CURTYPE_BTREE);
      if pCur = nil then goto no_mem;
      pCur^.iDb         := iDb;
      pCur^.nullRow     := 1;
      pCur^.cursorFlags := pCur^.cursorFlags or VDBC_Ordered;
      pCur^.pgnoRoot    := p2;
      rc := sqlite3BtreeCursor(pX, p2, 0 { read-only }, pKInfo,
                               pCur^.uc.pCursor);
      pCur^.pKeyInfo := pKInfo;
      pCur^.isTable  := u8(ord(pOp^.p4type <> P4_KEYINFO));
      goto open_cursor_set_hints;
    end;

    { ────── OP_OpenEphemeral / OP_OpenAutoindex ────── (vdbe.c:4500) }
    { Open a new cursor P1 pointing to a transient table (OP_OpenEphemeral)
      or a transient auto-index (OP_OpenAutoindex).  P2 is the number of
      fields.  P4, if present and of type P4_KEYINFO, gives the key
      comparator for an index table; when P4 is absent the cursor is a
      regular integer-key (rowid) table.  P5 may be 0 or BTREE_PREFORMAT. }
    OP_OpenEphemeral,
    OP_OpenAutoindex: begin
      pgnoEph := 0;
      pCur := allocateCursor(v, pOp^.p1, pOp^.p2, CURTYPE_BTREE);
      if pCur = nil then goto no_mem;
      pCur^.nullRow     := 1;
      pCur^.cursorFlags := pCur^.cursorFlags or VDBC_Ephemeral;
      pCur^.pKeyInfo    := pOp^.p4.pKeyInfo;
      rc := sqlite3BtreeOpen(
        Psqlite3_vfs(db^.pVfs), nil, db, @pCur^.ub.pBtx,
        BTREE_OMIT_JOURNAL or BTREE_SINGLE or pOp^.p5,
        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or
        SQLITE_OPEN_EXCLUSIVE or SQLITE_OPEN_DELETEONCLOSE or
        SQLITE_OPEN_TEMP_DB);
      if rc = SQLITE_OK then
        rc := sqlite3BtreeBeginTrans(pCur^.ub.pBtx, 1, nil);
      if rc = SQLITE_OK then begin
        if pCur^.pKeyInfo <> nil then begin
          { Index table: create a BLOB-key table and open a cursor on it }
          rc := sqlite3BtreeCreateTable(pCur^.ub.pBtx, @pgnoEph,
                                        BTREE_BLOBKEY);
          if rc = SQLITE_OK then begin
            rc := sqlite3BtreeCursor(pCur^.ub.pBtx, pgnoEph, BTREE_WRCSR,
                                     pCur^.pKeyInfo, pCur^.uc.pCursor);
            pCur^.isTable := 0;
          end;
        end else begin
          { Rowid table: allocate a fresh INTKEY root page and open a cursor
            on it.  In upstream C the comment "use the auto-created table at
            SCHEMA_ROOT+1" applies because newDatabase pre-allocates that
            page; this port's newDatabase only initialises page 1, so we
            must call sqlite3BtreeCreateTable explicitly and capture the
            assigned pgno (typically SCHEMA_ROOT+1 = 2 for a fresh eph). }
          rc := sqlite3BtreeCreateTable(pCur^.ub.pBtx, @pgnoEph, BTREE_INTKEY);
          if rc = SQLITE_OK then begin
            rc := sqlite3BtreeCursor(pCur^.ub.pBtx, pgnoEph, BTREE_WRCSR,
                                     nil, pCur^.uc.pCursor);
            pCur^.isTable := 1;
          end;
        end;
      end;
      if rc <> SQLITE_OK then goto abort_due_to_error;
      pCur^.pgnoRoot := pCur^.uc.pCursor^.pgnoRoot;
    end;

    { ────── OP_OpenPseudo ────── (vdbe.c:4683) }
    { Open a new cursor P1 backed by register P2 (which holds the row).
      P3 is the number of fields.  Mirrors C semantics exactly. }
    OP_OpenPseudo: begin
      pCur := allocateCursor(v, pOp^.p1, pOp^.p3, CURTYPE_PSEUDO);
      if pCur = nil then goto no_mem;
      pCur^.nullRow    := 1;
      pCur^.seekResult := pOp^.p2;           { register holding the row }
      pCur^.isTable    := 1;
    end;

    { ────── OP_OpenDup ────── (vdbe.c:4600) }
    { Open a new cursor P1 that is a duplicate of the ephemeral cursor P2.
      Both cursors share the same underlying Btree; neither cursor "owns" the
      Btree in the sense that neither is responsible for closing it (both have
      VDBC_NoReuse set).  A fresh BtCursor is opened on the shared Btree so
      that the two cursors can move independently. }
    OP_OpenDup: begin
      pOrig := v^.apCsr[pOp^.p2];
      pCur  := allocateCursor(v, pOp^.p1, pOrig^.nField, CURTYPE_BTREE);
      if pCur = nil then goto no_mem;
      pCur^.nullRow     := 1;
      pCur^.cursorFlags := pCur^.cursorFlags or VDBC_Ephemeral;
      if (pOrig^.cursorFlags and VDBC_Ordered) <> 0 then
        pCur^.cursorFlags := pCur^.cursorFlags or VDBC_Ordered;
      pCur^.pKeyInfo    := pOrig^.pKeyInfo;
      pCur^.isTable     := pOrig^.isTable;
      pCur^.pgnoRoot    := pOrig^.pgnoRoot;
      pCur^.ub.pBtx     := pOrig^.ub.pBtx;
      { Mark both as shared so FreeCursor does not close the Btree }
      pCur^.cursorFlags  := pCur^.cursorFlags  or VDBC_NoReuse;
      pOrig^.cursorFlags := pOrig^.cursorFlags or VDBC_NoReuse;
      rc := sqlite3BtreeCursor(pCur^.ub.pBtx, pCur^.pgnoRoot, BTREE_WRCSR,
                               pCur^.pKeyInfo, pCur^.uc.pCursor);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_RowData ────── (vdbe.c:6104) }
    { Write into register P2 the complete row data for the row at which
      cursor P1 is currently pointing.  There is no interpretation of the
      data; it is copied verbatim.  If P3 is zero the MEM_Zero flag is
      cleared so the value is not expanded lazily. }
    OP_RowData: begin
      pDest := @aMem[pOp^.p2];
      pCur  := v^.apCsr[pOp^.p1];
      pCrsr := pCur^.uc.pCursor;
      p2    := sqlite3BtreePayloadSize(pCrsr);
      if p2 >= u32(db^.aLimit[0]) { SQLITE_LIMIT_LENGTH } then goto too_big;
      if sqlite3VdbeMemFromBtreeZeroOffset(pCrsr, p2, pDest) <> 0 then goto no_mem;
      { vdbe.c:6138 — when p3=0, Deephemeralize the result so the row data
        survives subsequent cursor mutations (e.g. OP_Delete on the same
        cursor immediately after, as the recursive-CTE FIFO consumer does). }
      if pOp^.p3 = 0 then begin
        if (pDest^.flags and MEM_Ephem) <> 0 then begin
          if sqlite3VdbeMemMakeWriteable(pDest) <> SQLITE_OK then goto no_mem;
        end;
      end;
      UpdateMaxBlobsize(pDest);   { vdbe.c:6139 }
    end;

    { ────── OP_RowCell ────── (vdbe.c:5847) }
    { Transfer a row from cursor P2 to cursor P1. If the cursors are opened on
      intkey tables, register P3 contains the rowid to use with the new record
      in P1. If they are opened on index tables, P3 is not used.
      This opcode must be followed by either an Insert or IdxInsert opcode
      with the OPFLAG_PREFORMAT flag set to complete the insert operation. }
    OP_RowCell: begin
      pCur := v^.apCsr[pOp^.p1];  { destination cursor }
      pSrcCur := v^.apCsr[pOp^.p2];  { source cursor }
      if pOp^.p3 <> 0 then
        iKey := aMem[pOp^.p3].u.i
      else
        iKey := 0;
      rc := sqlite3BtreeTransferRow(pCur^.uc.pCursor, pSrcCur^.uc.pCursor, i64(iKey));
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_SeekScan ────── (vdbe.c:5093)
      Advance the cursor up to P1 steps; if key >= SeekGE key then handle
      the found/not-found branches without running SeekGE again. }
    OP_SeekScan: begin
      { SeekScan is followed by SeekGE — use pOp[1] for the SeekGE info.
        vdbe.c:5122 — the cursor index comes from the following SeekGE
        (pOp[1].p1); pOp->p1 here is the nStep count, NOT a cursor index. }
      pCur := v^.apCsr[pOp[1].p1];
      if pCur = nil then begin
        { cursor not valid: fall through to SeekGE }
        Inc(pOp); continue;
      end;
      if not Boolean(sqlite3BtreeCursorIsValidNN(pCur^.uc.pCursor)) then begin
        Inc(pOp); continue;
      end;
      { Build the unpacked record from the SeekGE operands }
      r.pKeyInfo := pCur^.pKeyInfo;
      r.nField   := u16(pOp[1].p4.i);
      r.default_rc := 0;
      r.aMem     := @aMem[pOp[1].p3];
      nStep      := pOp^.p1;
      res        := 0;
      while True do begin
        { Inlined sqlite3VdbeIdxKeyCompare }
        nCellKey := i64(sqlite3BtreePayloadSize(pCur^.uc.pCursor));
        if (nCellKey <= 0) or (nCellKey > $7FFFFFFF) then begin
          rc := SQLITE_CORRUPT_BKPT;
          goto abort_due_to_error;
        end;
        sqlite3VdbeMemInit(@pMem5b, db, 0);
        rc := sqlite3VdbeMemFromBtreeZeroOffset(pCur^.uc.pCursor, u32(nCellKey), @pMem5b);
        if rc <> SQLITE_OK then begin sqlite3VdbeMemReleaseMalloc(@pMem5b); goto abort_due_to_error; end;
        res := sqlite3VdbeRecordCompareWithSkip(pMem5b.n, pMem5b.z, @r, 0);
        sqlite3VdbeMemReleaseMalloc(@pMem5b);
        { End inlined IdxKeyCompare }
        if rc <> SQLITE_OK then goto abort_due_to_error;
        if (res > 0) and (pOp^.p5 = 0) then begin
          { key exceeded — jump to SeekGE.P2 }
          Inc(pOp);
          goto jump_to_p2;
        end;
        if res >= 0 then begin
          { found or equal — jump to SeekScan.P2, bypassing SeekGE }
          goto jump_to_p2;
        end;
        if nStep <= 0 then begin
          { exhausted steps — fall through to SeekGE }
          break;
        end;
        Dec(nStep);
        pCur^.cacheStatus := CACHE_STALE;
        rc := sqlite3BtreeNext(pCur^.uc.pCursor, 0);
        if rc = SQLITE_DONE then begin rc := SQLITE_OK; Inc(pOp); goto jump_to_p2; end;
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end;
    end;

    { ────── OP_SeekHit ────── (vdbe.c:5216)
      Clamp seekHit of cursor P1 to [P2, P3]. }
    OP_SeekHit: begin
      pCur := v^.apCsr[pOp^.p1];
      if pCur^.seekHit < u16(pOp^.p2) then pCur^.seekHit := u16(pOp^.p2)
      else if pCur^.seekHit > u16(pOp^.p3) then pCur^.seekHit := u16(pOp^.p3);
    end;

    { ────── OP_IfNotOpen ────── (vdbe.c:5246)
      If cursor P1 is not open or is NullRow, jump to P2. }
    OP_IfNotOpen: begin
      pCur := v^.apCsr[pOp^.p1];
      if (pCur = nil) or (pCur^.nullRow <> 0) then
        goto jump_to_p2_and_check_for_interrupt;
    end;

    { ────── OP_IfSizeBetween ────── (vdbe.c:6296)
      Jump to P2 if 10*log2(rowcount) is in [P3,P4]. }
    OP_IfSizeBetween: begin
      pCur  := v^.apCsr[pOp^.p1];
      pCrsr := pCur^.uc.pCursor;
      rc    := sqlite3BtreeFirst(pCrsr, @res);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if res <> 0 then
        iSz := -1
      else begin
        iSz := sqlite3BtreeRowCountEst(pCrsr);
        if iSz > 0 then iSz := sqlite3LogEst(u64(iSz))
        else iSz := 0;
      end;
      if (iSz >= pOp^.p3) and (iSz <= pOp^.p4.i) then
        goto jump_to_p2;
    end;

    { ────── OP_SorterSort / OP_Sort ────── (vdbe.c:6330)
      Rewind the sorter/index and jump to P2 if empty. }
    OP_SorterSort,
    OP_Sort: begin
      { vdbe.c:6349..6351 — SQLITE_TEST-guarded sort counter, read by
        regression tests to confirm sorts are elided when possible. }
      Inc(sqlite3_sort_count);
      { 9.4.divbug.73 — vdbe.c:6351 dec search_count (Sort masquerades as Rewind) }
      Dec(sqlite3_search_count);
      Inc(v^.aCounter[SQLITE_STMTSTATUS_SORT]);
      { Fall through to OP_Rewind logic }
      pCur  := v^.apCsr[pOp^.p1];
      pCrsr := pCur^.uc.pCursor;
      pCur^.nullRow      := 0;
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus  := CACHE_STALE;
      if pCur^.eCurType = CURTYPE_SORTER then begin
        rc := sqlite3VdbeSorterRewind(pCur, res);
      end else begin
        rc := sqlite3BtreeFirst(pCrsr, @res);
      end;
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if res <> 0 then goto jump_to_p2;
    end;

    { ────── OP_SorterOpen ────── (vdbe.c:4633) }
    OP_SorterOpen: begin
      pCur := allocateCursor(v, pOp^.p1, pOp^.p2, CURTYPE_SORTER);
      if pCur = nil then goto no_mem;
      pCur^.pKeyInfo := pOp^.p4.pKeyInfo;
      rc := sqlite3VdbeSorterInit(db, pOp^.p3, pCur);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_SorterInsert ────── (vdbe.c:6607) }
    OP_SorterInsert: begin
      pCur  := v^.apCsr[pOp^.p1];
      sqlite3VdbeIncrWriteCounter(v, pCur);
      pIn2  := @aMem[pOp^.p2];
      rc := sqlite3VdbeSorterWrite(pCur, pIn2);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_SorterData ────── (vdbe.c:6062) }
    OP_SorterData: begin
      pOut  := @aMem[pOp^.p2];
      pCur  := v^.apCsr[pOp^.p1];
      rc    := sqlite3VdbeSorterRowkey(pCur, pOut);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      v^.apCsr[pOp^.p3]^.cacheStatus := CACHE_STALE;
    end;

    { ────── OP_SorterCompare ────── (vdbe.c:6032) }
    OP_SorterCompare: begin
      pCur    := v^.apCsr[pOp^.p1];
      pIn3    := @aMem[pOp^.p3];
      nKeyCol := pOp^.p4.i;
      res     := 0;
      rc      := sqlite3VdbeSorterCompare(pCur, 0, pIn3, nKeyCol, res);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if res <> 0 then goto jump_to_p2;
    end;

    { ────── OP_ResetSorter ────── (vdbe.c:7006) }
    OP_ResetSorter: begin
      pCur := v^.apCsr[pOp^.p1];
      if pCur^.eCurType = CURTYPE_SORTER then
        sqlite3VdbeSorterReset(db, pCur^.uc.pSorter)
      else begin
        rc := sqlite3BtreeClearTableOfCursor(pCur^.uc.pCursor);
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end;
    end;

    { ────── OP_SequenceTest ────── (vdbe.c:4655) }
    OP_SequenceTest: begin
      pCur := v^.apCsr[pOp^.p1];
      if pCur^.seqCount = 0 then begin
        Inc(pCur^.seqCount);
        goto jump_to_p2;
      end;
      Inc(pCur^.seqCount);
    end;

    { ────── OP_Sequence ────── (vdbe.c:5564) }
    OP_Sequence: begin
      pOut    := out2Prerelease(v, pOp);
      pCur    := v^.apCsr[pOp^.p1];
      pOut^.u.i := pCur^.seqCount;
      Inc(pCur^.seqCount);
    end;

    { ────── OP_Last ────── (vdbe.c:6254) }
    OP_Last: begin
      pCur  := v^.apCsr[pOp^.p1];
      pCrsr := pCur^.uc.pCursor;
      res   := 0;
      rc    := sqlite3BtreeLast(pCrsr, @res);
      pCur^.nullRow      := u8(res);
      pCur^.deferredMoveto := 0;
      pCur^.cacheStatus  := CACHE_STALE;
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if pOp^.p2 > 0 then begin
        if res <> 0 then goto jump_to_p2;
      end;
    end;

    { ────── OP_ReadCookie ────── (vdbe.c:4215) }
    OP_ReadCookie: begin
      pOut := out2Prerelease(v, pOp);
      idx := 0;
      sqlite3BtreeGetMeta(PBtree(db^.aDb[pOp^.p1].pBt), pOp^.p3, @idx);
      { C: int iMeta; sqlite3BtreeGetMeta(...,(u32*)&iMeta); pOut->u.i=iMeta;
        — assigning a signed 32-bit int to i64 SIGN-EXTENDS. Cast u32 bits
        through i32 so the high bit propagates (vdbe.c:4216/4228/4230). }
      pOut^.u.i := i64(i32(idx));
    end;

    { ────── OP_SetCookie ────── (vdbe.c:4249) }
    OP_SetCookie: begin
      sqlite3VdbeIncrWriteCounter(v, nil);
      pDbRec := @db^.aDb[pOp^.p1];
      rc := sqlite3BtreeUpdateMeta(PBtree(pDbRec^.pBt), pOp^.p2, u32(pOp^.p3));
      if pOp^.p2 = BTREE_SCHEMA_VERSION then begin
        u32(pDbRec^.pSchema^.schema_cookie) := u32(pOp^.p3) - u32(pOp^.p5);
        db^.mDbFlags := db^.mDbFlags or DBFLAG_SchemaChange;
        sqlite3FkClearTriggerCache(db, pOp^.p1);
      end else if pOp^.p2 = BTREE_FILE_FORMAT then
        pDbRec^.pSchema^.file_format := u8(pOp^.p3);
      if pOp^.p1 = 1 then begin
        sqlite3ExpirePreparedStatements(db, 0);
        v^.vdbeFlags := v^.vdbeFlags and not u32(VDBF_EXPIRED_MASK);
      end;
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_CreateBtree ────── (vdbe.c:7032) }
    OP_CreateBtree: begin
      sqlite3VdbeIncrWriteCounter(v, nil);
      pOut := out2Prerelease(v, pOp);
      newPgno := 0;
      pDbRec := @db^.aDb[pOp^.p1];
      rc := sqlite3BtreeCreateTable(PBtree(pDbRec^.pBt), @newPgno, pOp^.p3);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      pOut^.u.i := newPgno;
    end;

    { ────── OP_Destroy ────── (vdbe.c:6928) }
    OP_Destroy: begin
      sqlite3VdbeIncrWriteCounter(v, nil);
      pOut := out2Prerelease(v, pOp);
      pOut^.flags := MEM_Null;
      if db^.nVdbeRead > db^.nVDestroy + 1 then begin
        rc := SQLITE_LOCKED;
        v^.errorAction := OE_Abort;
        goto abort_due_to_error;
      end else begin
        iMoved := 0;
        rc := sqlite3BtreeDropTable(PBtree(db^.aDb[pOp^.p3].pBt), pOp^.p1, @iMoved);
        pOut^.flags := MEM_Int;
        pOut^.u.i := iMoved;
        if rc <> SQLITE_OK then goto abort_due_to_error;
        if iMoved <> 0 then
          sqlite3RootPageMoved(db, pOp^.p3, iMoved, pOp^.p1);
      end;
    end;

    { ────── OP_Clear ────── (vdbe.c:6978) }
    OP_Clear: begin
      sqlite3VdbeIncrWriteCounter(v, nil);
      nChange := 0;
      rc := sqlite3BtreeClearTable(PBtree(db^.aDb[pOp^.p2].pBt), u32(pOp^.p1), @nChange);
      if pOp^.p3 <> 0 then begin
        Inc(v^.nChange, nChange);
        if pOp^.p3 > 0 then
          Inc(aMem[pOp^.p3].u.i, nChange);
      end;
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_ParseSchema ────── (vdbe.c:7114) }
    { Phase 6.9-bis step 11g.1 (structural skeleton): dispatch to the
      sqlite3_exec-driven body in passqlite3main via a settable hook.
      When the hook is unbound (early bring-up / unit tests linking vdbe
      without main) we retain the legacy no-op stub so all existing
      tests remain green. }
    OP_ParseSchema: begin
      if vdbeParseSchemaExec = nil then begin
        { Fallback stub — schema already loaded by codegen's
          sqlite3InstallSchemaTable bootstrap (Phase 6.x). }
      end else begin
        { Both p4.z=nil (ALTER) and p4.z<>nil (general) paths route
          through the hook.  vdbe.c:7136..7144 clears the schema and
          re-runs sqlite3InitOne when p4 is nil; the hook implementation
          in main.pas mirrors that distinction by detecting nil zWhere. }
        rc := vdbeParseSchemaExec(db, pOp^.p1, pOp^.p4.z, pOp^.p5, @v^.zErrMsg);
        if rc <> SQLITE_OK then begin
          sqlite3ResetAllSchemasOfConnection(db);
          if rc = SQLITE_NOMEM then goto no_mem;
          goto abort_due_to_error;
        end;
        if pOp^.p4.z = nil then
          db^.mDbFlags := db^.mDbFlags or u32(DBFLAG_SchemaChange);
      end;
    end;

    { ────── OP_LoadAnalysis ────── (vdbe.c:7192) }
    OP_LoadAnalysis: begin
      rc := sqlite3AnalysisLoad(db, pOp^.p1);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_DropTable ────── (vdbe.c:7208) }
    OP_DropTable: begin
      sqlite3VdbeIncrWriteCounter(v, nil);
      sqlite3UnlinkAndDeleteTable(db, pOp^.p1, pOp^.p4.z);
    end;

    { ────── OP_DropIndex ────── (vdbe.c:7222) }
    OP_DropIndex: begin
      sqlite3VdbeIncrWriteCounter(v, nil);
      sqlite3UnlinkAndDeleteIndex(db, pOp^.p1, pOp^.p4.z);
    end;

    { ────── OP_DropTrigger ────── (vdbe.c:7236) }
    OP_DropTrigger: begin
      sqlite3VdbeIncrWriteCounter(v, nil);
      sqlite3UnlinkAndDeleteTrigger(db, pOp^.p1, pOp^.p4.z);
    end;

    { ────── OP_TableLock ────── (vdbe.c:8264) }
    OP_TableLock: begin
      { No shared-cache: sqlite3BtreeLockTable is a stub returning SQLITE_OK }
      rc := sqlite3BtreeLockTable(PBtree(db^.aDb[pOp^.p1].pBt), pOp^.p2, u8(pOp^.p3));
      if rc <> SQLITE_OK then begin
        if (rc and $FF) = SQLITE_LOCKED then
          sqlite3VdbeError(v, 'database table is locked');
        goto abort_due_to_error;
      end;
    end;

    { ────── OP_ElseEq ────── (vdbe.c:2430) }
    OP_ElseEq: begin
      if iCompare = 0 then goto jump_to_p2;
    end;

    { ────── OP_Permutation ────── (vdbe.c:2460) — just a marker, no action }
    OP_Permutation: begin
      { No action; the permutation data is read by OP_Compare }
    end;

    { ────── OP_Compare ────── (vdbe.c:2490) }
    OP_Compare: begin
      pKInfo  := pOp^.p4.pKeyInfo;
      nField  := pOp^.p3;
      p1reg   := pOp^.p1;
      p2reg   := pOp^.p2;
      if (pOp^.p5 and OPFLAG_PERMUTE) <> 0 then
        aPermute := pOp[-1].p4.ai + 1  { skip the count at [0] }
      else
        aPermute := nil;
      iCompare := 0;
      iCompareIsInit := 1;
      i := 0;
      while i < nField do begin
        if aPermute <> nil then idx := aPermute[i]
        else idx := u32(i);
        pCS := nil;
        bRevCol  := False;
        bBigNull := False;
        if pKInfo <> nil then begin
          { KeyInfo layout (64-bit): nRef(4)+enc(1)+pad(1)+nKeyField(2)+nAllField(2)+pad(6)+db*(8)+aSortFlags*(8)+aColl[...] }
          { aSortFlags pointer at offset 24; aColl pointer array at offset 32 }
          pCS := PCollSeq(PPointer(Pu8(pKInfo) + 32 + SizeOf(Pointer) * i)^);
          bRevCol  := (Pu8(PPointer(Pu8(pKInfo) + 24)^)[i] and KEYINFO_ORDER_DESC) <> 0;
          bBigNull := (Pu8(PPointer(Pu8(pKInfo) + 24)^)[i] and KEYINFO_ORDER_BIGNULL) <> 0;
        end;
        iCompare := sqlite3MemCompare(@aMem[p1reg + idx], @aMem[p2reg + idx], pCS);
        if iCompare <> 0 then begin
          if bBigNull and
               (((aMem[p1reg+idx].flags and MEM_Null) <> 0) or
                ((aMem[p2reg+idx].flags and MEM_Null) <> 0)) then
              iCompare := -iCompare;
            if bRevCol then iCompare := -iCompare;
          break;
        end;
        Inc(i);
      end;
    end;

    { ────── OP_IfPos ────── (vdbe.c:7711) }
    OP_IfPos: begin
      pIn1 := @aMem[pOp^.p1];
      if pIn1^.u.i > 0 then begin
        Dec(pIn1^.u.i, pOp^.p3);
        goto jump_to_p2;
      end;
    end;

    { ────── OP_IfNotZero ────── (vdbe.c:7771) }
    OP_IfNotZero: begin
      pIn1 := @aMem[pOp^.p1];
      if pIn1^.u.i <> 0 then begin
        if pIn1^.u.i > 0 then Dec(pIn1^.u.i);
        goto jump_to_p2;
      end;
    end;

    { ────── OP_DecrJumpZero ────── (vdbe.c:7788) }
    OP_DecrJumpZero: begin
      pIn1 := @aMem[pOp^.p1];
      if pIn1^.u.i > i64(-$7FFFFFFFFFFFFFFF - 1) then Dec(pIn1^.u.i);
      if pIn1^.u.i = 0 then goto jump_to_p2;
    end;

    { ────── OP_OffsetLimit ────── (vdbe.c:7740)
      Synopsis: if r[P1]>0 then r[P2]=r[P1]+max(0,r[P3]) else r[P2]=(-1)
      9.4.divbug.46: must clamp r[P3] (OFFSET) to 0 before adding —
      C does `pIn3->u.i>0?pIn3->u.i:0`.  A negative OFFSET (e.g.
      `LIMIT 5 OFFSET -2`) otherwise shrinks the Top-N B-tree cap
      from LIMIT to LIMIT+OFFSET, returning fewer rows than expected. }
    OP_OffsetLimit: begin
      pIn1  := @aMem[pOp^.p1];
      pIn3  := @aMem[pOp^.p3];
      pOut  := out2Prerelease(v, pOp);
      xLim  := pIn1^.u.i;
      if pIn3^.u.i > 0 then xOfs := pIn3^.u.i else xOfs := 0;
      if (xLim <= 0) or (sqlite3AddInt64(@xLim, xOfs) <> 0) then
        pOut^.u.i := -1
      else
        pOut^.u.i := xLim;
    end;

    { ────── OP_MemMax ────── (vdbe.c:7682) }
    OP_MemMax: begin
      if v^.pFrame <> nil then begin
        pFrame := v^.pFrame;
        while pFrame^.pParent <> nil do pFrame := pFrame^.pParent;
        pIn1 := @pFrame^.aMem[pOp^.p1];
      end else
        pIn1 := @aMem[pOp^.p1];
      sqlite3VdbeMemIntegerify(pIn1);
      pIn2 := @aMem[pOp^.p2];
      sqlite3VdbeMemIntegerify(pIn2);
      if pIn1^.u.i < pIn2^.u.i then pIn1^.u.i := pIn2^.u.i;
    end;

    { ────── OP_FkCounter ────── (vdbe.c:7638) }
    OP_FkCounter: begin
      if pOp^.p1 <> 0 then
        Inc(db^.nDeferredCons, pOp^.p2)
      else begin
        if (db^.flags and SQLITE_DeferFKs) <> 0 then
          Inc(db^.nDeferredImmCons, pOp^.p2)
        else
          Inc(v^.nFkConstraint, pOp^.p2);
      end;
    end;

    { ────── OP_FkIfZero ────── (vdbe.c:7658) }
    OP_FkIfZero: begin
      if pOp^.p1 <> 0 then begin
        if (db^.nDeferredCons = 0) and (db^.nDeferredImmCons = 0) then
          goto jump_to_p2;
      end else begin
        if (v^.nFkConstraint = 0) and (db^.nDeferredImmCons = 0) then
          goto jump_to_p2;
      end;
    end;

    { ────── OP_FkCheck ────── (vdbe.c:1730) }
    OP_FkCheck: begin
      rc := sqlite3VdbeCheckFkImmediate(v);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_RowSetAdd ────── (vdbe.c:7362) }
    OP_RowSetAdd: begin
      pIn1 := @aMem[pOp^.p1];
      pIn2 := @aMem[pOp^.p2];
      if (pIn1^.flags and MEM_Blob) = 0 then begin
        if sqlite3VdbeMemSetRowSet(pIn1) <> 0 then goto no_mem;
      end;
      sqlite3RowSetInsert(PRowSet(pIn1^.z), pIn2^.u.i);
    end;

    { ────── OP_RowSetRead ────── (vdbe.c:7382) }
    OP_RowSetRead: begin
      pIn1 := @aMem[pOp^.p1];
      if ((pIn1^.flags and MEM_Blob) = 0) or
         (sqlite3RowSetNext(PRowSet(pIn1^.z), @i64Val) = 0) then begin
        sqlite3VdbeMemSetNull(pIn1);
        goto jump_to_p2_and_check_for_interrupt;
      end else begin
        sqlite3VdbeMemSetInt64(@aMem[pOp^.p3], i64Val);
      end;
      goto check_for_interrupt;
    end;

    { ────── OP_RowSetTest ────── (vdbe.c:7425) }
    OP_RowSetTest: begin
      pIn1  := @aMem[pOp^.p1];
      pIn3  := @aMem[pOp^.p3];
      iSet  := pOp^.p4.i;
      if (pIn1^.flags and MEM_Blob) = 0 then begin
        if sqlite3VdbeMemSetRowSet(pIn1) <> 0 then goto no_mem;
      end;
      if iSet <> 0 then begin
        exists := sqlite3RowSetTest(PRowSet(pIn1^.z), iSet, pIn3^.u.i);
        if exists <> 0 then goto jump_to_p2;
      end;
      if iSet >= 0 then
        sqlite3RowSetInsert(PRowSet(pIn1^.z), pIn3^.u.i);
    end;

    { ────── OP_Program ────── (vdbe.c:7474) — trigger sub-program }
    OP_Program: begin
      pProgSub := pOp^.p4.pProgram;
      pRtMem   := @aMem[pOp^.p3];
      if v^.nFrame >= db^.aLimit[SQLITE_LIMIT_TRIGGER_DEPTH] then begin
        rc := SQLITE_ERROR;
        sqlite3VdbeError(v, 'too many levels of trigger recursion');
        goto abort_due_to_error;
      end;
      { Check recursive trigger (p5 flag).
        If already executing this trigger, skip (fall through). }
      pFrame := nil;
      if pOp^.p5 <> 0 then begin
        pFrameTok := pProgSub^.token;
        pFrame    := v^.pFrame;
        while (pFrame <> nil) and (pFrame^.token <> pFrameTok) do
          pFrame := pFrame^.pParent;
      end;
      if pFrame = nil then begin
        op_program_run:
        pFrame := nil; { suppress unused label warning }
        if (pRtMem^.flags and MEM_Blob) = 0 then begin
          { Port of vdbe.c:7521..7523 — bump nMem by 1 whenever the trigger
            sub-program uses no cursors so apCsr (placed at &aMem[nMem]) does
            not overlap the last register slot.  Previously gated only on
            nProgMem=0, which silently corrupted apCsr for any trigger body
            that allocated registers but no cursors (e.g. SELECT 1, RAISE())
            — bug 9.4.divbug.87.052. }
          nProgMem := pProgSub^.nMem + pProgSub^.nCsr;
          if pProgSub^.nCsr = 0 then Inc(nProgMem);
          nByteProg := i64(ROUND8(SizeOf(TVdbeFrame)))
                     + i64(nProgMem) * i64(SizeOf(TMem))
                     + i64(pProgSub^.nCsr) * i64(SizeOf(PVdbeCursor))
                     + i64((7 + pProgSub^.nOp) div 8);
          pFrame := sqlite3DbMallocZero(db, nByteProg);
          if pFrame = nil then goto no_mem;
          sqlite3VdbeMemRelease(pRtMem);
          pRtMem^.flags := MEM_Blob or MEM_Dyn;
          pRtMem^.z     := PAnsiChar(pFrame);
          pRtMem^.n     := i32(nByteProg);
          pRtMem^.xDel  := @sqlite3VdbeFrameMemDel;
          pFrame^.v           := v;
          pFrame^.nChildMem   := nProgMem;
          pFrame^.nChildCsr   := pProgSub^.nCsr;
          { pc = index of the OP_Program instruction in aOp[] }
          pFrame^.pc          := (PByte(pOp) - PByte(aOp)) div SizeOf(TVdbeOp);
          pFrame^.aMem        := v^.aMem;
          pFrame^.nMem        := v^.nMem;
          pFrame^.apCsr       := v^.apCsr;
          pFrame^.nCursor     := v^.nCursor;
          pFrame^.aOp         := v^.aOp;
          pFrame^.nOp         := v^.nOp;
          pFrame^.token       := pProgSub^.token;
          pMemEnd := PMem(Pu8(pFrame) + ROUND8(SizeOf(TVdbeFrame)));
          i := 0;
          while i < nProgMem do begin
            pMemEnd^.flags := MEM_Undefined;
            pMemEnd^.db    := db;
            Inc(pMemEnd);
            Inc(i);
          end;
        end else begin
          pFrame := PVdbeFrame(pRtMem^.z);
        end;
        Inc(v^.nFrame);
        pFrame^.pParent    := v^.pFrame;
        pFrame^.lastRowid  := db^.lastRowid;
        pFrame^.nChange    := v^.nChange;
        pFrame^.nDbChange  := db^.nChange;
        pFrame^.pAuxData   := v^.pAuxData;
        v^.pAuxData        := nil;
        v^.nChange         := 0;
        v^.pFrame          := pFrame;
        v^.aMem            := PMem(Pu8(pFrame) + ROUND8(SizeOf(TVdbeFrame)));
        aMem               := v^.aMem;
        v^.nMem            := pFrame^.nChildMem;
        v^.nCursor         := u16(pFrame^.nChildCsr);
        v^.apCsr           := @v^.aMem[v^.nMem];
        { OP_Once flags live just past apCsr[nCsr]; per vdbe.c:7581..7582 they
          must be (re)computed and zeroed on EVERY OP_Program invocation — not
          only on the first (allocating) pass — else a cached frame reused for a
          later row of a multi-row DML keeps the prior row's OP_Once bits set,
          so cacheable scalar subqueries in the trigger body skip re-execution
          and return stale results (trigger2 1.x.x). }
        pFrame^.aOnce      := Pu8(@v^.apCsr[pProgSub^.nCsr]);
        FillChar(pFrame^.aOnce^, (pProgSub^.nOp + 7) div 8, 0);
        aOp                := pProgSub^.aOp;
        v^.aOp             := aOp;
        v^.nOp             := pProgSub^.nOp;
        pOp                := @aOp[-1];
        goto check_for_interrupt;
      end;
      { else: recursive trigger already running — fall through }
    end;

    { ────── OP_Param ────── (vdbe.c:7612) }
    OP_Param: begin
      pOut   := out2Prerelease(v, pOp);
      pFrame := v^.pFrame;
      pIn1   := @pFrame^.aMem[pOp^.p1 + pFrame^.aOp[pFrame^.pc].p1];
      sqlite3VdbeMemShallowCopy(pOut, pIn1, MEM_Ephem);
    end;

    { ────── OP_Expire ────── (vdbe.c:8208) }
    OP_Expire: begin
      if pOp^.p1 = 0 then
        sqlite3ExpirePreparedStatements(db, pOp^.p2)
      else
        v^.vdbeFlags := v^.vdbeFlags or u32(pOp^.p2 + 1);
    end;

    { ────── OP_CursorLock ────── (vdbe.c:8223) }
    OP_CursorLock: begin
      pCur := v^.apCsr[pOp^.p1];
      sqlite3BtreeCursorPin(pCur^.uc.pCursor);
    end;

    { ────── OP_CursorUnlock ────── (vdbe.c:8238) }
    OP_CursorUnlock: begin
      pCur := v^.apCsr[pOp^.p1];
      sqlite3BtreeCursorUnpin(pCur^.uc.pCursor);
    end;

    { ────── OP_Pagecount ────── (vdbe.c:8770) }
    OP_Pagecount: begin
      pOut  := out2Prerelease(v, pOp);
      pOut^.u.i := sqlite3BtreeLastPage(PBtree(db^.aDb[pOp^.p1].pBt));
    end;

    { ────── OP_MaxPgcnt ────── (vdbe.c:8787) }
    OP_MaxPgcnt: begin
      pOut   := out2Prerelease(v, pOp);
      pBtArg := PBtree(db^.aDb[pOp^.p1].pBt);
      newMax := 0;
      if pOp^.p3 <> 0 then begin
        newMax := sqlite3BtreeLastPage(pBtArg);
        if newMax < Pgno(pOp^.p3) then newMax := Pgno(pOp^.p3);
      end;
      pOut^.u.i := sqlite3BtreeMaxPageCount(pBtArg, newMax);
    end;

    { ────── OP_Checkpoint ────── (vdbe.c:8015) }
    OP_Checkpoint: begin
      { Inline of sqlite3Checkpoint (main.c) — match vdbe.c:8015..8038.
        aResCk[0] = busy flag, aResCk[1] = nLog, aResCk[2] = nCkpt. }
      aResCk[0] := 0;
      aResCk[1] := -1;
      aResCk[2] := -1;
      rcCk     := SQLITE_OK;
      bBusyCk  := 0;
      pnLogCk  := @aResCk[1];
      pnCkptCk := @aResCk[2];
      iCk      := 0;
      { SQLITE_MAX_DB_INTERNAL = SQLITE_MAX_ATTACHED + 2 (main.c) — sentinel
        meaning "checkpoint every database".  Inlined here to avoid a uses
        cycle through passqlite3main. }
      while (iCk < db^.nDb) and (rcCk = SQLITE_OK) do begin
        if (iCk = pOp^.p1) or (pOp^.p1 = SQLITE_MAX_ATTACHED + 2) then begin
          rcCk := sqlite3BtreeCheckpoint(PBtree(db^.aDb[iCk].pBt), pOp^.p2,
                                         Pointer(pnLogCk), Pointer(pnCkptCk));
          pnLogCk  := nil;
          pnCkptCk := nil;
          if rcCk = SQLITE_BUSY then begin bBusyCk := 1; rcCk := SQLITE_OK; end;
        end;
        Inc(iCk);
      end;
      if (rcCk = SQLITE_OK) and (bBusyCk <> 0) then rcCk := SQLITE_BUSY;
      if rcCk <> SQLITE_OK then begin
        if rcCk <> SQLITE_BUSY then begin rc := rcCk; goto abort_due_to_error; end;
        rcCk := SQLITE_OK;
        aResCk[0] := 1;
      end;
      sqlite3VdbeMemSetInt64(@aMem[pOp^.p3],     i64(aResCk[0]));
      sqlite3VdbeMemSetInt64(@aMem[pOp^.p3 + 1], i64(aResCk[1]));
      sqlite3VdbeMemSetInt64(@aMem[pOp^.p3 + 2], i64(aResCk[2]));
    end;

    { ────── OP_Vacuum ────── (vdbe.c:7188).  p1 selects the database to
      VACUUM (0 = main; 1 cannot be VACUUMed and is rejected by the codegen
      gate, so any non-zero p1 here is an attached DB).  When p2 is non-
      zero, register p2 holds the VACUUM INTO target filename.  Delegates
      to the vdbeRunVacuum hook installed by main.pas (sqlite3RunVacuum
      port of vacuum.c:143).  When the hook is unbound (early bring-up /
      tests linking vdbe without main) we degrade to the legacy no-op so
      DiagOps and friends keep working. }
    OP_Vacuum: begin
      Assert(pOp^.p1 <> 1);
      sqlite3VdbeIncrWriteCounter(v, nil);
      if vdbeRunVacuum <> nil then begin
        if pOp^.p2 <> 0 then
          rc := vdbeRunVacuum(@v^.zErrMsg, db, pOp^.p1, @aMem[pOp^.p2])
        else
          rc := vdbeRunVacuum(@v^.zErrMsg, db, pOp^.p1, nil);
        if rc <> 0 then goto abort_due_to_error;
      end;
    end;

    { ────── OP_JournalMode ────── (vdbe.c:8054) — full 1:1 port. }
    OP_JournalMode: begin
      pOut := out2Prerelease(v, pOp);
      jmEnew := pOp^.p3;
      jmBt := PBtree(db^.aDb[pOp^.p1].pBt);
      jmPager := sqlite3BtreePager(jmBt);
      jmEold := sqlite3PagerGetJournalMode(jmPager);
      if jmEnew = PAGER_JOURNALMODE_QUERY then jmEnew := jmEold;
      if sqlite3PagerOkToChangeJournalMode(jmPager) = 0 then jmEnew := jmEold;

      { Do not allow a transition to journal_mode=WAL for a database
        in temporary storage or if the VFS does not support shared memory. }
      jmZFilename := sqlite3PagerFilename(jmPager, 1);
      if (jmEnew = PAGER_JOURNALMODE_WAL)
         and ((jmZFilename = nil) or (jmZFilename^ = #0)
              or (sqlite3PagerWalSupported(jmPager) = 0))
      then jmEnew := jmEold;

      if (jmEnew <> jmEold)
         and ((jmEold = PAGER_JOURNALMODE_WAL) or (jmEnew = PAGER_JOURNALMODE_WAL))
      then begin
        if (db^.autoCommit = 0) or (db^.nVdbeRead > 1) then begin
          rc := SQLITE_ERROR;
          if jmEnew = PAGER_JOURNALMODE_WAL then
            sqlite3VdbeError(v, 'cannot change into wal mode from within a transaction')
          else
            sqlite3VdbeError(v, 'cannot change out of wal mode from within a transaction');
          goto abort_due_to_error;
        end else begin
          if jmEold = PAGER_JOURNALMODE_WAL then begin
            { Leaving WAL mode — checkpoint and close the log. }
            rc := sqlite3PagerCloseWal(jmPager, db);
            if rc = SQLITE_OK then
              sqlite3PagerSetJournalMode(jmPager, jmEnew);
          end else if jmEold = PAGER_JOURNALMODE_MEMORY then begin
            { Cannot transition directly from MEMORY to WAL.  Use mode OFF
              as an intermediate. }
            sqlite3PagerSetJournalMode(jmPager, PAGER_JOURNALMODE_OFF);
          end;

          { Open a transaction on the database file.  Regardless of the
            journal mode, this transaction always uses a rollback journal. }
          if rc = SQLITE_OK then begin
            if jmEnew = PAGER_JOURNALMODE_WAL then
              rc := sqlite3BtreeSetVersion(jmBt, 2)
            else
              rc := sqlite3BtreeSetVersion(jmBt, 1);
          end;
        end;
      end;

      if rc <> SQLITE_OK then jmEnew := jmEold;
      jmEnew := sqlite3PagerSetJournalMode(jmPager, jmEnew);
      pOut^.flags := MEM_Str or MEM_Static or MEM_Term;
      pOut^.z     := PAnsiChar(sqlite3JournalModename(jmEnew));
      pOut^.n     := sqlite3Strlen30(PChar(pOut^.z));
      pOut^.enc   := SQLITE_UTF8;
      sqlite3VdbeChangeEncoding(pOut, enc);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_SqlExec ────── (vdbe.c:7064) }
    OP_SqlExec: begin
      sqlite3VdbeIncrWriteCounter(v, nil);
      Inc(db^.nSqlExec);
      sqlExecErr := nil;
      sqlExecXAuth := db^.xAuth;
      sqlExecMTrace := db^.mTrace;
      sqlExecSavedAnalysisLimit := db^.nAnalysisLimit;
      if (pOp^.p1 and $0001) <> 0 then begin
        db^.xAuth := nil;
        db^.mTrace := 0;
      end;
      if (pOp^.p1 and $0002) <> 0 then
        db^.nAnalysisLimit := pOp^.p2;
      if vdbeSqlExec <> nil then
        rc := vdbeSqlExec(db, pOp^.p4.z, @sqlExecErr)
      else
        rc := SQLITE_OK;
      Dec(db^.nSqlExec);
      db^.xAuth := sqlExecXAuth;
      db^.mTrace := sqlExecMTrace;
      db^.nAnalysisLimit := sqlExecSavedAnalysisLimit;
      if (sqlExecErr <> nil) or (rc <> SQLITE_OK) then begin
        sqlite3VdbeError(v, sqlExecErr);
        sqlite3_free(sqlExecErr);
        if rc = SQLITE_NOMEM then goto no_mem;
        goto abort_due_to_error;
      end;
    end;

    { ────── OP_IntegrityCk ────── (vdbe.c:7263) — full integrity-check
      driver.  Faithful 1:1 with the upstream arm: nRoot = pOp^.p2;
      aRoot = pOp^.p4.ai (P4_INTARRAY); aRoot[0] is encoded as nRoot
      for full checks, 0 for partial.  Per-tree row counts go into
      aMem[pOp^.p3 .. pOp^.p3+nRoot-1]; the error message lands in
      aMem[pOp^.p1+1]; the remaining-error counter is decremented in
      aMem[pOp^.p1] by (nErr-1). }
    OP_IntegrityCk: begin
      icnRoot := pOp^.p2;
      { aRoot[0] holds the count; the roots are aRoot[1..nRoot].  Pass
        &aRoot[1] to sqlite3BtreeIntegrityCheck (vdbe.c:7284). }
      icRoot := @PPgno(pOp^.p4.ai)[1];
      Assert(icnRoot > 0);
      Assert(PPgno(pOp^.p4.ai) <> nil);
      Assert(PPgno(pOp^.p4.ai)[0] = Pgno(icnRoot));
      icpnErr := @aMem[pOp^.p1];
      icpzOut := nil;
      icnErr  := 0;
      { Allocate a small i64[] for per-tree row counts.  The opcode
        contract guarantees nRoot fits in i32. }
      GetMem(icRowCnt, icnRoot * SizeOf(i64));
      FillChar(icRowCnt^, PtrUInt(icnRoot) * SizeOf(i64), 0);
      rc := sqlite3BtreeIntegrityCheck(db, db^.aDb[pOp^.p5].pBt,
                                       icRoot, icRowCnt, icnRoot,
                                       i32(icpnErr^.u.i) + 1,
                                       @icnErr, @icpzOut);
      { Marshal per-tree row counts into aMem[p3..]. }
      for icIdx := 0 to icnRoot - 1 do
        sqlite3MemSetArrayInt64(@aMem[pOp^.p3], icIdx, icRowCnt[icIdx]);
      FreeMem(icRowCnt);
      sqlite3VdbeMemSetNull(@aMem[pOp^.p1 + 1]);
      if icnErr = 0 then begin
        Assert(icpzOut = nil);
      end else if rc <> SQLITE_OK then begin
        if icpzOut <> nil then sqlite3_free(icpzOut);
        goto abort_due_to_error;
      end else begin
        icpnErr^.u.i := icpnErr^.u.i - (icnErr - 1);
        sqlite3VdbeMemSetStr(@aMem[pOp^.p1 + 1], icpzOut, -1,
                             SQLITE_UTF8, SQLITE_DYNAMIC);
      end;
      sqlite3VdbeChangeEncoding(@aMem[pOp^.p1 + 1], enc);
      UpdateMaxBlobsize(@aMem[pOp^.p1]);   { vdbe.c:7296 }
      goto check_for_interrupt;
    end;

    { ────── OP_IFindKey ────── (vdbe.c:7301) — sub-search around the
      current index cursor for an entry whose non-EIIB-affected columns
      match.  Used by OP_IdxDelete / integrity-check.  See vdbeaux.c
      sqlite3VdbeFindIndexKey (5542).  Body lives in passqlite3codegen
      via the vdbeFindIndexKey hook (TIndex layout not visible here). }
    OP_IFindKey: begin
      pCur  := v^.apCsr[pOp^.p1];
      pCrsr := pCur^.uc.pCursor;
      rSeek.pKeyInfo  := pCur^.pKeyInfo;
      rSeek.nField    := 0;            { hook fills from pIdx^.nColumn }
      rSeek.default_rc := 0;
      rSeek.aMem      := @aMem[pOp^.p3];
      rSeek.eqSeen    := 0;
      res := 0;
      if vdbeFindIndexKey <> nil then
        rc := vdbeFindIndexKey(pCrsr, pOp^.p4.pIdx, @rSeek, @res, 1)
      else begin
        rc  := SQLITE_OK;
        res := 1;  { no hook → no match → take the jump (matches C's "not found" arm) }
      end;
      if rc <> SQLITE_OK then begin
        rc := SQLITE_OK;
        goto jump_to_p2;
      end;
      if res <> 0 then goto jump_to_p2;
      pCur^.nullRow := 0;
    end;

    { ────── OP_IncrVacuum ────── (vdbe.c:8174) — single step of an
      incremental vacuum on db P1.  Jumps to P2 when the vacuum is
      complete (SQLITE_DONE).  Faithful 1:1 with the upstream arm. }
    OP_IncrVacuum: begin
      Assert((pOp^.p1 >= 0) and (pOp^.p1 < db^.nDb));
      Assert((v^.vdbeFlags and VDBF_ReadOnly) = 0);
      pX := db^.aDb[pOp^.p1].pBt;
      rc := sqlite3BtreeIncrVacuum(pX);
      if rc <> SQLITE_OK then
      begin
        if rc <> SQLITE_DONE then goto abort_due_to_error;
        rc := SQLITE_OK;
        goto jump_to_p2;
      end;
    end;

    { ────── OP_Abortable ────── (vdbe.c:9150) — debug-only, no-op in release }
    OP_Abortable: begin
      sqlite3VdbeAssertAbortable(v);
    end;

    { ────── OP_ReleaseReg ────── (vdbe.c:9187) — debug-only, no-op in release }
    OP_ReleaseReg: begin
      { no-op in release builds }
    end;

    { ────── OP_CursorHint ────── — no-op in this port }
    OP_CursorHint: begin
      { Hint ignored — no query planner optimization in Phase 5 }
    end;

    { ────── OP_Filter / OP_FilterAdd ────── — Bloom filter (vdbe.c:8955/8991) }
    OP_FilterAdd: begin
      pIn1 := @aMem[pOp^.p1];
      if ((pIn1^.flags and MEM_Blob) = 0) or (pIn1^.n <= 0) then
        { Filter blob not initialized — fall through (no-op) }
        else begin
      { filterHash (vdbe.c:690): sum hashes of pOp.p4.i registers from p3 }
      hFilter := 0;
      ii := pOp^.p3;
      mxFilter := ii + pOp^.p4.i;
      while ii < mxFilter do begin
        pMemFilter := @aMem[ii];
        if (pMemFilter^.flags and (MEM_Int or MEM_IntReal)) <> 0 then
          hFilter := hFilter + u64(pMemFilter^.u.i)
        else if (pMemFilter^.flags and MEM_Real) <> 0 then
          hFilter := hFilter + u64(sqlite3VdbeIntValue(pMemFilter))
        else if (pMemFilter^.flags and (MEM_Str or MEM_Blob)) <> 0 then
          hFilter := hFilter + 4093 + u64(pMemFilter^.flags and (MEM_Str or MEM_Blob));
        Inc(ii);
      end;
      hFilter := hFilter mod u64(pIn1^.n * 8);
      PByte(pIn1^.z)[hFilter shr 3] := PByte(pIn1^.z)[hFilter shr 3] or (Byte(1) shl (hFilter and 7));
      end;
    end;
    OP_Filter: begin
      pIn1 := @aMem[pOp^.p1];
      if ((pIn1^.flags and MEM_Blob) = 0) or (pIn1^.n <= 0) then begin
        { Filter blob not initialized — fall through (don't skip) }
      end else begin
      hFilter := 0;
      ii := pOp^.p3;
      mxFilter := ii + pOp^.p4.i;
      while ii < mxFilter do begin
        pMemFilter := @aMem[ii];
        if (pMemFilter^.flags and (MEM_Int or MEM_IntReal)) <> 0 then
          hFilter := hFilter + u64(pMemFilter^.u.i)
        else if (pMemFilter^.flags and MEM_Real) <> 0 then
          hFilter := hFilter + u64(sqlite3VdbeIntValue(pMemFilter))
        else if (pMemFilter^.flags and (MEM_Str or MEM_Blob)) <> 0 then
          hFilter := hFilter + 4093 + u64(pMemFilter^.flags and (MEM_Str or MEM_Blob));
        Inc(ii);
      end;
      hFilter := hFilter mod u64(pIn1^.n * 8);
      if (PByte(pIn1^.z)[hFilter shr 3] and (Byte(1) shl (hFilter and 7))) = 0 then begin
        Inc(v^.aCounter[SQLITE_STMTSTATUS_FILTER_HIT]);
        goto jump_to_p2;
      end else begin
        Inc(v^.aCounter[SQLITE_STMTSTATUS_FILTER_MISS]);
      end;
      end;
    end;

    { ────── OP_ColumnsUsed ────── — hint only, no-op }
    OP_ColumnsUsed: begin end;

    { ────── OP_Offset ────── (vdbe.c:2931) — port of vdbe.c case OP_Offset }
    OP_Offset: begin
      pCur := v^.apCsr[pOp^.p1];
      if (pCur = nil) or (pCur^.eCurType <> CURTYPE_BTREE) then
        sqlite3VdbeMemSetNull(@aMem[pOp^.p3])
      else begin
        if pCur^.deferredMoveto <> 0 then begin
          rc := sqlite3VdbeFinishMoveto(pCur);
          if rc <> 0 then goto abort_due_to_error;
        end;
        if sqlite3BtreeEof(pCur^.uc.pCursor) <> 0 then
          sqlite3VdbeMemSetNull(@aMem[pOp^.p3])
        else
          sqlite3VdbeMemSetInt64(@aMem[pOp^.p3],
            sqlite3BtreeOffset(pCur^.uc.pCursor));
      end;
    end;

    { ────── OP_TypeCheck ────── (vdbe.c:3305) — 9.4.divbug.71
      Verify the values in registers P1..P1+P2-1 conform to the column
      types of the STRICT table P4.  On mismatch emit
      "cannot store <type> value in <COLTYPE> column <tbl>.<col>" and
      return SQLITE_CONSTRAINT_DATATYPE.

      Field offsets (verified against passqlite3codegen.TTable / TColumn):
        TTable:   zName@0(ptr) aCol@8(ptr) nCol@54(i16)
        TColumn:  zCnName@0(ptr) typeFlags@8(u8) affinity@9(u8)
                  colFlags@14(u16);  sizeof TColumn = 16
        eCType  = (typeFlags >> 4) & 0xF   (1=ANY 2=BLOB 3=INT 4=INTEGER
                                            5=REAL 6=TEXT)
        COLFLAG_GENERATED = $0060 (STORED|VIRTUAL); COLFLAG_VIRTUAL = $0020 }
    OP_TypeCheck: begin
      pTabBaseTC := Pu8(pOp^.p4.pTab);
      aColBaseTC := Pu8(PPointer(pTabBaseTC + 8)^);
      pIn1       := @aMem[pOp^.p1];
      if pOp^.p3 < 2 then begin
        iTC    := 0;
        nColTC := PSmallInt(pTabBaseTC + 54)^;
      end else begin
        iTC    := pOp^.p3 - 2;
        nColTC := iTC + 1;
      end;
      zErrMsgTC := nil;
      eCTypeTC  := -1;
      while iTC < nColTC do begin
        pColTC      := aColBaseTC + (iTC * 16);
        colFlagsTC  := Pu16(pColTC + 14)^;
        if ((colFlagsTC and $0060) <> 0) and (pOp^.p3 < 2) then begin
          if (colFlagsTC and $0020) <> 0 then begin
            Inc(iTC);
            Continue;
          end;
          if pOp^.p3 <> 0 then begin
            Inc(pIn1);
            Inc(iTC);
            Continue;
          end;
        end;
        affTC := Pu8(pColTC + 9)^;
        applyAffinity(pIn1, AnsiChar(affTC), enc);
        eCTypeTC := -1;
        if (pIn1^.flags and MEM_Null) = 0 then begin
          typeFlagsTC := Pu8(pColTC + 8)^;
          eCTypeTC := (typeFlagsTC shr 4) and $0F;
          case eCTypeTC of
            2: { COLTYPE_BLOB }
              if (pIn1^.flags and MEM_Blob) <> 0 then eCTypeTC := -1;
            3, 4: { COLTYPE_INT / INTEGER }
              if (pIn1^.flags and MEM_Int) <> 0 then eCTypeTC := -1;
            6: { COLTYPE_TEXT }
              if (pIn1^.flags and MEM_Str) <> 0 then eCTypeTC := -1;
            5: begin { COLTYPE_REAL }
              if (pIn1^.flags and MEM_Int) <> 0 then begin
                if (pIn1^.u.i <= 140737488355327) and
                   (pIn1^.u.i >= -140737488355328) then begin
                  pIn1^.flags := pIn1^.flags or MEM_IntReal;
                  pIn1^.flags := pIn1^.flags and not u16(MEM_Int);
                end else begin
                  pIn1^.u.r   := Double(pIn1^.u.i);
                  pIn1^.flags := pIn1^.flags or MEM_Real;
                  pIn1^.flags := pIn1^.flags and not u16(MEM_Int);
                end;
                eCTypeTC := -1;
              end else if (pIn1^.flags and (MEM_Real or MEM_IntReal)) <> 0 then
                eCTypeTC := -1;
            end;
          else
            eCTypeTC := -1;  { COLTYPE_ANY and any other: accept anything }
          end;
        end;
        if eCTypeTC >= 0 then Break;  { mismatch — pIn1, iTC pin error site }
        Inc(pIn1);
        Inc(iTC);
      end;
      if eCTypeTC >= 0 then begin
        { vdbeMemTypeName: SQLITE_INTEGER=1..SQLITE_NULL=5 }
        case sqlite3_value_type(pIn1) of
          1: zMemTypeTC := 'INT';
          2: zMemTypeTC := 'REAL';
          3: zMemTypeTC := 'TEXT';
          4: zMemTypeTC := 'BLOB';
        else
          zMemTypeTC := 'NULL';
        end;
        case eCTypeTC of
          1: zStdTypeTC := 'ANY';
          2: zStdTypeTC := 'BLOB';
          3: zStdTypeTC := 'INT';
          4: zStdTypeTC := 'INTEGER';
          5: zStdTypeTC := 'REAL';
          6: zStdTypeTC := 'TEXT';
        else
          zStdTypeTC := '';
        end;
        zTabNameTC := PPAnsiChar(pTabBaseTC + 0)^;
        zColNameTC := PPAnsiChar(pColTC + 0)^;
        zErrMsgTC := sqlite3MPrintf(Psqlite3db(db),
          'cannot store %s value in %s column %s.%s',
          [zMemTypeTC, zStdTypeTC, zTabNameTC, zColNameTC]);
        sqlite3VdbeError(v, zErrMsgTC);
        sqlite3DbFree(db, zErrMsgTC);
        rc := SQLITE_CONSTRAINT_DATATYPE;
        goto abort_due_to_error;
      end;
    end;

    { ────── OP_PureFunc ────── — same as OP_Function (already handled) }
    OP_PureFunc: begin
      { Identical to OP_Function — reuse that code path }
      goto op_function_body;
    end;

    { ────── OP_VBegin (vdbe.c:8294) ────── Phase 6.bis.3a }
    OP_VBegin: begin
      pVTabRef := passqlite3vtab.PVTable(pOp^.p4.pVtab);
      rc := passqlite3vtab.sqlite3VtabBegin(db, pVTabRef);
      if pVTabRef <> nil then
        passqlite3vtab.sqlite3VtabImportErrmsg(v, pVTabRef^.pVtab);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_VCreate (vdbe.c:8310) ────── Phase 6.bis.3a }
    OP_VCreate: begin
      FillChar(sMemVCreate, SizeOf(sMemVCreate), 0);
      sMemVCreate.db := db;
      { aMem[p2] is always a static string per the opcode contract — copy is
        guaranteed not to fail, but we still funnel rc through to be faithful. }
      rc := sqlite3VdbeMemCopy(@sMemVCreate, @aMem[pOp^.p2]);
      zVTabName := sqlite3_value_text(@sMemVCreate);
      if zVTabName <> nil then
        rc := passqlite3vtab.sqlite3VtabCallCreate(db, pOp^.p1, zVTabName,
                                                   @v^.zErrMsg);
      sqlite3VdbeMemRelease(@sMemVCreate);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_VDestroy (vdbe.c:8339) ────── Phase 6.bis.3a }
    OP_VDestroy: begin
      Inc(db^.nVDestroy);
      rc := passqlite3vtab.sqlite3VtabCallDestroy(db, pOp^.p1, pOp^.p4.z);
      Dec(db^.nVDestroy);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_VOpen (vdbe.c:8356) ────── Phase 6.bis.3b }
    OP_VOpen: begin
      pVTabRef := passqlite3vtab.PVTable(pOp^.p4.pVtab);
      pCur     := v^.apCsr[pOp^.p1];
      pVtabC   := nil;
      if pVTabRef <> nil then pVtabC := pVTabRef^.pVtab;
      { No-op if cursor is already open on the same vtab }
      if (pCur <> nil) and (pCur^.eCurType = CURTYPE_VTAB)
         and (pCur^.uc.pVCur <> nil)
         and (passqlite3vtab.PSqlite3VtabCursor(pCur^.uc.pVCur)^.pVtab = pVtabC) then
      begin
        { already open — fall through }
      end else begin
        if (pVtabC = nil) or (pVtabC^.pModule = nil) then begin
          rc := SQLITE_LOCKED;
          goto abort_due_to_error;
        end;
        pModC    := pVtabC^.pModule;
        pVCurNew := nil;
        if pModC^.xOpen <> nil then
          rc := TxOpenFnV(pModC^.xOpen)(pVtabC, @pVCurNew)
        else
          rc := SQLITE_ERROR;
        passqlite3vtab.sqlite3VtabImportErrmsg(v, pVtabC);
        if rc <> SQLITE_OK then goto abort_due_to_error;
        pVCurNew^.pVtab := pVtabC;
        pCur := allocateCursor(v, pOp^.p1, 0, CURTYPE_VTAB);
        if pCur = nil then begin
          if pModC^.xClose <> nil then
            TxCloseFnV(pModC^.xClose)(pVCurNew);
          goto no_mem;
        end;
        pCur^.uc.pVCur := Psqlite3_vtab_cursor(pVCurNew);
        Inc(pVtabC^.nRef);
      end;
    end;

    { ────── OP_VFilter (vdbe.c:8493) ────── Phase 6.bis.3b }
    OP_VFilter: begin
      pIn1 := @aMem[pOp^.p3];           { pQuery }
      pIn2 := @aMem[pOp^.p3 + 1];       { pArgc }
      pCur := v^.apCsr[pOp^.p1];
      Assert(pCur <> nil, 'OP_VFilter cursor');
      Assert(pCur^.eCurType = CURTYPE_VTAB, 'OP_VFilter eCurType');
      pVCurC := passqlite3vtab.PSqlite3VtabCursor(pCur^.uc.pVCur);
      pVtabC := pVCurC^.pVtab;
      pModC  := pVtabC^.pModule;
      nArgV  := i32(pIn2^.u.i);
      iQueryV := i32(pIn1^.u.i);
      SetLength(apArgV, nArgV);
      for iV := 0 to nArgV - 1 do
        apArgV[iV] := @aMem[pOp^.p3 + 2 + iV];
      if pModC^.xFilter <> nil then begin
        if nArgV > 0 then
          rc := TxFilterFnV(pModC^.xFilter)(pVCurC, iQueryV, pOp^.p4.z,
                                            nArgV, @apArgV[0])
        else
          rc := TxFilterFnV(pModC^.xFilter)(pVCurC, iQueryV, pOp^.p4.z,
                                            nArgV, nil);
      end else
        rc := SQLITE_ERROR;
      passqlite3vtab.sqlite3VtabImportErrmsg(v, pVtabC);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      resV := 1;
      if pModC^.xEof <> nil then
        resV := TxEofFnV(pModC^.xEof)(pVCurC);
      pCur^.nullRow := 0;
      if resV <> 0 then goto jump_to_p2;
    end;

    { ────── OP_VColumn (vdbe.c:8554) ────── Phase 6.bis.3b }
    OP_VColumn: begin
      pCur := v^.apCsr[pOp^.p1];
      Assert(pCur <> nil, 'OP_VColumn cursor');
      pOut := @aMem[pOp^.p3];
      if pCur^.nullRow <> 0 then begin
        sqlite3VdbeMemSetNull(pOut);
      end else begin
        Assert(pCur^.eCurType = CURTYPE_VTAB, 'OP_VColumn eCurType');
        pVCurC := passqlite3vtab.PSqlite3VtabCursor(pCur^.uc.pVCur);
        pVtabC := pVCurC^.pVtab;
        pModC  := pVtabC^.pModule;
        FillChar(sCtxV,    SizeOf(sCtxV),    0);
        FillChar(nullFnV,  SizeOf(nullFnV),  0);
        sCtxV.pOut := pOut;
        sCtxV.enc  := enc;
        nullFnV.funcFlags := u32($01000000);  { SQLITE_RESULT_SUBTYPE }
        sCtxV.pFunc := PFuncDef(@nullFnV);
        Assert((pOp^.p5 = OPFLAG_NOCHNG) or (pOp^.p5 = 0), 'OP_VColumn p5');
        if (pOp^.p5 and OPFLAG_NOCHNG) <> 0 then begin
          sqlite3VdbeMemSetNull(pOut);
          pOut^.flags := MEM_Null or MEM_Zero;
          pOut^.u.nZero := 0;
        end else begin
          pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or MEM_Null;
        end;
        if pModC^.xColumn <> nil then
          rc := TxColumnFnV(pModC^.xColumn)(pVCurC, @sCtxV, pOp^.p2)
        else
          rc := SQLITE_ERROR;
        passqlite3vtab.sqlite3VtabImportErrmsg(v, pVtabC);
        if sCtxV.isError > 0 then begin
          sqlite3VdbeError(v, PAnsiChar(sqlite3_value_text(pOut)));
          rc := sCtxV.isError;
        end;
        sqlite3VdbeChangeEncoding(pOut, enc);
        UpdateMaxBlobsize(pOut);   { vdbe.c:8596 }
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end;
    end;

    { ────── OP_VNext (vdbe.c:8610) ────── Phase 6.bis.3b }
    OP_VNext: begin
      pCur := v^.apCsr[pOp^.p1];
      Assert(pCur <> nil, 'OP_VNext cursor');
      Assert(pCur^.eCurType = CURTYPE_VTAB, 'OP_VNext eCurType');
      if pCur^.nullRow <> 0 then begin
        { fall through }
      end else begin
        pVCurC := passqlite3vtab.PSqlite3VtabCursor(pCur^.uc.pVCur);
        pVtabC := pVCurC^.pVtab;
        pModC  := pVtabC^.pModule;
        if pModC^.xNext <> nil then
          rc := TxNextFnV(pModC^.xNext)(pVCurC)
        else
          rc := SQLITE_ERROR;
        passqlite3vtab.sqlite3VtabImportErrmsg(v, pVtabC);
        if rc <> SQLITE_OK then goto abort_due_to_error;
        resV := 1;
        if pModC^.xEof <> nil then
          resV := TxEofFnV(pModC^.xEof)(pVCurC);
        if resV = 0 then goto jump_to_p2_and_check_for_interrupt;
        goto check_for_interrupt;
      end;
    end;

    { ────── OP_VRename (vdbe.c:8652) ────── Phase 6.bis.3b }
    OP_VRename: begin
      iLegacyV := i32(db^.flags and u64($04000000));  { SQLITE_LegacyAlter }
      db^.flags := db^.flags or u64($04000000);
      pVTabRef := passqlite3vtab.PVTable(pOp^.p4.pVtab);
      pVtabC   := pVTabRef^.pVtab;
      pNameMem := @aMem[pOp^.p1];
      Assert(pVtabC^.pModule^.xRename <> nil, 'OP_VRename xRename');
      Assert((pNameMem^.flags and MEM_Str) <> 0, 'OP_VRename MEM_Str');
      rc := sqlite3VdbeChangeEncoding(pNameMem, SQLITE_UTF8);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      rc := TxRenameFnV(pVtabC^.pModule^.xRename)(pVtabC, pNameMem^.z);
      if iLegacyV = 0 then
        db^.flags := db^.flags and not u64($04000000);
      passqlite3vtab.sqlite3VtabImportErrmsg(v, pVtabC);
      v^.vdbeFlags := v^.vdbeFlags and not u32(VDBF_EXPIRED_MASK);
      if rc <> SQLITE_OK then goto abort_due_to_error;
    end;

    { ────── OP_VUpdate (vdbe.c:8708) ────── Phase 6.bis.3b }
    OP_VUpdate: begin
      Assert((pOp^.p2 = 1) or (pOp^.p5 = OE_Fail) or (pOp^.p5 = OE_Rollback)
          or (pOp^.p5 = OE_Abort) or (pOp^.p5 = OE_Ignore)
          or (pOp^.p5 = OE_Replace), 'OP_VUpdate p5');
      Assert((v^.vdbeFlags and VDBF_ReadOnly) = 0, 'OP_VUpdate readOnly');
      if vdbeDbMallocFailed(db) then goto no_mem;
      sqlite3VdbeIncrWriteCounter(v, nil);
      pVTabRef := passqlite3vtab.PVTable(pOp^.p4.pVtab);
      pVtabC   := pVTabRef^.pVtab;
      if (pVtabC = nil) or (pVtabC^.pModule = nil) then begin
        rc := SQLITE_LOCKED;
        goto abort_due_to_error;
      end;
      pModC := pVtabC^.pModule;
      nArgV := pOp^.p2;
      Assert(pOp^.p4type = P4_VTAB, 'OP_VUpdate p4type');
      if pModC^.xUpdate <> nil then begin
        SetLength(apArgV, nArgV);
        for iV := 0 to nArgV - 1 do
          apArgV[iV] := @aMem[pOp^.p3 + iV];
        db^.vtabOnConflict := u8(pOp^.p5);
        iVRow := 0;
        if nArgV > 0 then
          rc := TxUpdateFnV(pModC^.xUpdate)(pVtabC, nArgV, @apArgV[0], @iVRow)
        else
          rc := TxUpdateFnV(pModC^.xUpdate)(pVtabC, nArgV, nil, @iVRow);
        passqlite3vtab.sqlite3VtabImportErrmsg(v, pVtabC);
        if (rc = SQLITE_OK) and (pOp^.p1 <> 0) then
          db^.lastRowid := iVRow;
        if ((rc and $FF) = SQLITE_CONSTRAINT) and (pVTabRef^.bConstraint <> 0) then begin
          if pOp^.p5 = OE_Ignore then
            rc := SQLITE_OK
          else begin
            if pOp^.p5 = OE_Replace then
              v^.errorAction := OE_Abort
            else
              v^.errorAction := u8(pOp^.p5);
          end;
        end else
          Inc(v^.nChange);
        if rc <> SQLITE_OK then goto abort_due_to_error;
      end;
    end;

    { ────── OP_VCheck (vdbe.c:8409) ────── Phase 6.bis.3d
      Run xIntegrity on the vtab in p4. If it returns an error string,
      store it as a UTF-8 result in register p2; otherwise leave the
      register NULL. p3 is the integer flags argument forwarded to
      xIntegrity. }
    OP_VCheck: begin
      pOut := @aMem[pOp^.p2];
      sqlite3VdbeMemSetNull(pOut);  { innocent until proven guilty }
      pTabIntV := pOp^.p4.pTab;
      if (pTabIntV = nil) or (passqlite3vtab.tabVtabPP(pTabIntV)^ = nil) then
        { no VTable attached — nothing to check }
      else begin
        pVTblIntV := passqlite3vtab.tabVtabPP(pTabIntV)^;
        pVtabC    := pVTblIntV^.pVtab;
        pModC     := pVtabC^.pModule;
        Assert(pModC^.iVersion >= 4, 'OP_VCheck requires module iVersion>=4');
        Assert(pModC^.xIntegrity <> nil, 'OP_VCheck requires xIntegrity');
        passqlite3vtab.sqlite3VtabLock(pVTblIntV);
        zErrIntV := nil;
        rc := TxIntegrityFnV(pModC^.xIntegrity)(pVtabC,
                db^.aDb[pOp^.p1].zDbSName,
                passqlite3vtab.tabZName(pTabIntV),
                pOp^.p3, @zErrIntV);
        passqlite3vtab.sqlite3VtabUnlock(pVTblIntV);
        if rc <> SQLITE_OK then begin
          sqlite3_free(zErrIntV);
          goto abort_due_to_error;
        end;
        if zErrIntV <> nil then
          sqlite3VdbeMemSetStr(pOut, zErrIntV, -1, SQLITE_UTF8, SQLITE_DYNAMIC);
      end;
    end;

    { ────── OP_VInitIn (vdbe.c:8456) ────── Phase 6.bis.3b }
    OP_VInitIn: begin
      pCur := v^.apCsr[pOp^.p1];
      pRhsV := PValueList(sqlite3_malloc64(SizeOf(TValueList)));
      if pRhsV = nil then goto no_mem;
      pRhsV^.pCsr := pCur^.uc.pCursor;
      pRhsV^.pOut := @aMem[pOp^.p3];
      pOut := out2Prerelease(v, pOp);
      pOut^.flags := MEM_Null;
      sqlite3VdbeMemSetPointer(pOut, pRhsV, 'ValueList',
                               @sqlite3VdbeValueListFree);
    end;

    else begin
      { Unimplemented opcode }
      rc := SQLITE_ERROR;
      sqlite3VdbeError(v, 'unimplemented opcode');
      goto abort_due_to_error;
    end;
    end; { case }

    { advance to next instruction }
    Inc(pOp);
    continue;

    { ── open_cursor_set_hints continuation ── (vdbe.c:4461) }
    open_cursor_set_hints:
    sqlite3BtreeCursorHintFlags(pCur^.uc.pCursor,
                                pOp^.p5 and (OPFLAG_BULKCSR or OPFLAG_SEEKEQ));
    if rc <> SQLITE_OK then goto abort_due_to_error;
    Inc(pOp);
    continue;

    { ── next_tail ── (vdbe.c:6525) shared tail for OP_Next/OP_Prev/OP_SorterNext }
    next_tail:
    pCur^.cacheStatus := CACHE_STALE;
    if rc = SQLITE_OK then begin
      pCur^.nullRow := 0;
      Inc(v^.aCounter[pOp^.p5]);
      { 9.4.divbug.73 — vdbe.c:6531..6533 SQLITE_TEST counter on Next/Prev/SorterNext }
      Inc(sqlite3_search_count);
      goto jump_to_p2_and_check_for_interrupt;
    end;
    if rc <> SQLITE_DONE then goto abort_due_to_error;
    rc := SQLITE_OK;
    pCur^.nullRow := 1;
    goto check_for_interrupt;

    { ── seek_not_found ── (vdbe.c:5012) shared tail for SeekGT/GE/LT/LE }
    seek_not_found:
    if res <> 0 then goto jump_to_p2;
    if eqOnly <> 0 then Inc(pOp);  { eqOnly: skip OP_IdxLT/OP_IdxGT that follows }
    Inc(pOp);
    continue;

    { ── notExistsWithKey ── (vdbe.c:5525) shared body for SeekRowid/NotExists }
    notExistsWithKey:
    pCur := v^.apCsr[pOp^.p1];
    pCrsr := pCur^.uc.pCursor;
    res := 0;
    rc := sqlite3BtreeTableMoveto(pCrsr, iKey, 0, @res);
    pCur^.movetoTarget := i64(iKey);
    pCur^.nullRow        := 0;
    pCur^.cacheStatus    := CACHE_STALE;
    pCur^.deferredMoveto := 0;
    pCur^.seekResult := res;
    if res <> 0 then begin
      if pOp^.p2 = 0 then begin
        rc := SQLITE_CORRUPT_BKPT;
        goto abort_due_to_error;
      end else
        goto jump_to_p2;
    end;
    if rc <> SQLITE_OK then goto abort_due_to_error;
    Inc(pOp);
    continue;

    { ── jump_to_p2_and_check_for_interrupt ── (vdbe.c:1078) }
    jump_to_p2_and_check_for_interrupt:
    pOp := @aOp[pOp^.p2 - 1];

    check_for_interrupt:
    if db^.u1.isInterrupted <> 0 then goto abort_due_to_interrupt;
    if (db^.xProgress <> nil) and (nVmStep >= nProgressLimit) then begin
      while (nVmStep >= nProgressLimit) and (db^.xProgress <> nil) do begin
        nProgressLimit := nProgressLimit + db^.nProgressOps;
        if db^.xProgress(db^.pProgressArg) <> 0 then begin
          nProgressLimit := u64($FFFFFFFFFFFFFFFF);
          rc := SQLITE_INTERRUPT;
          goto abort_due_to_error;
        end;
      end;
    end;
    Inc(pOp);
    continue;

    { ── jump_to_p2 ── (vdbe.c:1186) }
    jump_to_p2:
    pOp := @aOp[pOp^.p2 - 1];
    Inc(pOp);
    continue;

    { ── op_column_corrupt ── shared corrupt-record handler for OP_Column }
    op_column_corrupt:
    if aOp[0].p3 > 0 then begin
      pOp := @aOp[aOp[0].p3 - 1];
      Inc(pOp);
      continue;
    end else begin
      rc := SQLITE_CORRUPT_BKPT;
      goto abort_due_to_error;
    end;

  until False;

  { ───────────────────────────────────────────────────────────── }

  abort_due_to_error:
  if db^.mallocFailed <> 0 then
    rc := SQLITE_NOMEM_BKPT
  else if rc = (SQLITE_IOERR or ($0B shl 8)) then  { SQLITE_IOERR_CORRUPTFS }
    rc := SQLITE_CORRUPT_BKPT;
  if v^.zErrMsg = nil then
    sqlite3VdbeError(v, sqlite3ErrStr(rc));
  v^.rc := rc;
  sqlite3SystemError(db, rc);
  sqlite3VdbeLogAbort(v, rc, pOp, aOp);
  if v^.eVdbeState = VDBE_RUN_STATE then sqlite3VdbeHalt(v);
  if rc = SQLITE_NOMEM_BKPT then sqlite3OomFault(db);
  if (rc = SQLITE_CORRUPT) and (db^.autoCommit = 0) then
    db^.flags := db^.flags or SQLITE_CorruptRdOnly;
  rc := SQLITE_ERROR;
  if resetSchemaOnFault > 0 then
    sqlite3ResetOneSchema(db, i32(resetSchemaOnFault) - 1);

  vdbe_return:
  {$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}
  { Phase 10.1.39.d.3 — credit the last op on abnormal exit (mirrors
    vdbe.c:9328..9332 the vdbe_return `if(pnCycle){ *pnCycle += sqlite3Hwtime(); }`). }
  if pCycleOp <> nil then begin
    pCycleOp^.nCycle := pCycleOp^.nCycle + (sqlite3Hwtime - t0Cycle);
    pCycleOp := nil;
  end;
  {$ENDIF}

  { vdbe.c:9339..9348 — final progress-callback check at the normal exit.
    A statement that halts (or finishes) without crossing a
    check_for_interrupt boundary after nVmStep last advanced past
    nProgressLimit must still invoke xProgress here.  Without this arm a
    short query (one whose VM-step count exceeds db^.nProgressOps but
    never re-reaches a check_for_interrupt opcode at the right step) never
    fires the handler at all (progress-1.7: `db progress 5 ...` with N>1
    never aborted, so the inner SELECT ran to completion). }
  while (nVmStep >= nProgressLimit) and (db^.xProgress <> nil) do begin
    nProgressLimit := nProgressLimit + db^.nProgressOps;
    if db^.xProgress(db^.pProgressArg) <> 0 then begin
      nProgressLimit := u64($FFFFFFFFFFFFFFFF);
      rc := SQLITE_INTERRUPT;
      goto abort_due_to_error;
    end;
  end;

  Inc(v^.aCounter[SQLITE_STMTSTATUS_VM_STEP], i32(nVmStep));
  if v^.lockMask <> 0 then
    sqlite3VdbeLeave(v);
  Result := rc;
  Exit;

  too_big:
  sqlite3VdbeError(v, 'string or blob too big');
  rc := SQLITE_TOOBIG;
  goto abort_due_to_error;

  no_mem:
  sqlite3OomFault(db);
  sqlite3VdbeError(v, 'out of memory');
  rc := SQLITE_NOMEM_BKPT;
  goto abort_due_to_error;

  abort_due_to_interrupt:
  rc := SQLITE_INTERRUPT;
  goto abort_due_to_error;

  { Unreachable — Pascal requires function to return }
  Result := rc;
end;

{ ============================================================================
  Opcode name table (vdbeaux.c sqlite3OpcodeName).
  Order matches OP_* numeric values 0..191.
  ============================================================================ }

function sqlite3OpcodeName(n: i32): PAnsiChar;
const
  OpcodeNames: array[0..191] of PAnsiChar = (
    'Savepoint',      'AutoCommit',     'Transaction',    'Checkpoint',
    'JournalMode',    'Vacuum',         'VFilter',        'VUpdate',
    'Init',           'Goto',           'Gosub',          'InitCoroutine',
    'Yield',          'MustBeInt',      'Jump',           'Once',
    'If',             'IfNot',          'IsType',         'Not',
    'IfNullRow',      'SeekLT',         'SeekLE',         'SeekGE',
    'SeekGT',         'IfNotOpen',      'IfNoHope',       'NoConflict',
    'NotFound',       'Found',          'SeekRowid',      'NotExists',
    'Last',           'IfSizeBetween',  'SorterSort',     'Sort',
    'Rewind',         'IfEmpty',        'SorterNext',     'Prev',
    'Next',           'IdxLE',          'IdxGT',          'Or',
    'And',            'IdxLT',          'IdxGE',          'IFindKey',
    'RowSetRead',     'RowSetTest',     'Program',        'IsNull',
    'NotNull',        'Ne',             'Eq',             'Gt',
    'Le',             'Lt',             'Ge',             'ElseEq',
    'FkIfZero',       'IfPos',          'IfNotZero',      'DecrJumpZero',
    'IncrVacuum',     'VNext',          'Filter',         'PureFunc',
    'Function',       'Return',         'EndCoroutine',   'HaltIfNull',
    'Halt',           'Integer',        'Int64',          'String',
    'BeginSubrtn',    'Null',           'SoftNull',       'Blob',
    'Variable',       'Move',           'Copy',           'SCopy',
    'IntCopy',        'FkCheck',        'ResultRow',      'CollSeq',
    'AddImm',         'RealAffinity',   'Cast',           'Permutation',
    'Compare',        'IsTrue',         'ZeroOrNull',     'Offset',
    'Column',         'TypeCheck',      'Affinity',       'MakeRecord',
    'Count',          'ReadCookie',     'SetCookie',      'BitAnd',
    'BitOr',          'ShiftLeft',      'ShiftRight',     'Add',
    'Subtract',       'Multiply',       'Divide',         'Remainder',
    'Concat',         'ReopenIdx',      'OpenRead',       'BitNot',
    'OpenWrite',      'OpenDup',        'String8',        'OpenAutoindex',
    'OpenEphemeral',  'SorterOpen',     'SequenceTest',   'OpenPseudo',
    'Close',          'ColumnsUsed',    'SeekScan',       'SeekHit',
    'Sequence',       'NewRowid',       'Insert',         'RowCell',
    'Delete',         'ResetCount',     'SorterCompare',  'SorterData',
    'RowData',        'Rowid',          'NullRow',        'SeekEnd',
    'IdxInsert',      'SorterInsert',   'IdxDelete',      'DeferredSeek',
    'IdxRowid',       'FinishSeek',     'Destroy',        'Clear',
    'ResetSorter',    'CreateBtree',    'SqlExec',        'ParseSchema',
    'LoadAnalysis',   'DropTable',      'Real',           'DropIndex',
    'DropTrigger',    'IntegrityCk',    'RowSetAdd',      'Param',
    'FkCounter',      'MemMax',         'OffsetLimit',    'AggInverse',
    'AggStep',        'AggStep1',       'AggValue',       'AggFinal',
    'Expire',         'CursorLock',     'CursorUnlock',   'TableLock',
    'VBegin',         'VCreate',        'VDestroy',       'VOpen',
    'VCheck',         'VInitIn',        'VColumn',        'VRename',
    'Pagecount',      'MaxPgcnt',       'ClrSubtype',     'GetSubtype',
    'SetSubtype',     'FilterAdd',      'Trace',          'CursorHint',
    'ReleaseReg',     'Noop',           'Explain',        'Abortable'
  );
begin
  if (n >= 0) and (n <= 191) then
    Result := OpcodeNames[n]
  else
    Result := '???';
end;

{ ============================================================================
  vdbemem.c — Mem value type operations (Phase 5.3 full port)
  Source: SQLite 3.53.0 src/vdbemem.c

  sqlite3 struct field offsets used below (verified vs GCC x86-64):
    enc          = 100  (u8)
    mallocFailed = 103  (u8)
    nFpDigit     = 114  (u8)
    aLimit[0]    = 136  (i32, SQLITE_LIMIT_LENGTH=0)

  MEMCELLSIZE = 24 = offsetof(TMem, db)

  VdbeMemDynamic(p): (p^.flags and (MEM_Agg or MEM_Dyn)) <> 0
  MemSetTypeFlag(p,f): p^.flags := (p^.flags and not (MEM_TypeMask or MEM_Zero)) or f
  ExpandBlob(p): if (p^.flags and MEM_Zero)<>0 then sqlite3VdbeMemExpandBlob(p) else 0
  ============================================================================ }

{ libc snprintf for numeric formatting }
function libc_snprintf(str: PAnsiChar; size: csize_t; fmt: PAnsiChar): i32;
  cdecl; varargs; external 'c' name 'snprintf';

{ Access enc field from opaque sqlite3* at offset 100 }
function vdbeDbEnc(db: Psqlite3): u8; inline;
begin
  if db = nil then Result := SQLITE_UTF8
  else Result := PByte(db)[100];
end;

{ Access nFpDigit from opaque sqlite3* at offset 114 }
function vdbeDbNFpDigit(db: Psqlite3): u8; inline;
begin
  if db = nil then Result := 17
  else Result := PByte(db)[114];
end;

{ Access aLimit[SQLITE_LIMIT_LENGTH] from opaque sqlite3* (aLimit starts at 136) }
function vdbeDbLimitLength(db: Psqlite3): i32; inline;
begin
  if db = nil then Result := SQLITE_MAX_LENGTH
  else Result := Pi32(PByte(db) + 136)^;
end;

{ MemSetTypeFlag — set a type flag, clearing all other type bits }
procedure memSetTypeFlag(p: PMem; f: u16); inline;
begin
  p^.flags := (p^.flags and not u16(MEM_TypeMask or MEM_Zero)) or f;
end;

{ Render a numeric Mem (MEM_Int, MEM_Real, or MEM_IntReal) into zBuf.
  sz must be > 22. Sets p^.n to the string length. }
procedure vdbeMemRenderNum(sz: i32; zBuf: PAnsiChar; p: PMem);
var
  tmpBuf: array[0..31] of AnsiChar;
  nFp:    i32;
begin
  if (p^.flags and (MEM_Int or MEM_IntReal)) <> 0 then begin
    p^.n := sqlite3Int64ToText(p^.u.i, zBuf);
    if (p^.flags and MEM_IntReal) <> 0 then begin
      { append ".0" for IntReal }
      zBuf[p^.n]   := '.';
      zBuf[p^.n+1] := '0';
      zBuf[p^.n+2] := #0;
      Inc(p^.n, 2);
    end;
  end else begin
    nFp := vdbeDbNFpDigit(p^.db);
    if nFp <= 0 then nFp := 17;
    { Mirror C: sqlite3_str_appendf(&acc, "%!.*g", nFp, r) — altform2,
      via sqlite3RenderNumF (printf.c:528..738 + util.c:1380). }
    p^.n := sqlite3RenderNumF(p^.u.r, nFp, True, zBuf, sz);
  end;
  { suppress compiler hint — sz unused in int branch }
  if sz < 0 then FillChar(tmpBuf, 0, 1);
end;

{ vdbeMemClearExternAndSetNull — call xDel (or finalize agg) then set MEM_Null }
procedure vdbeMemClearExternAndSetNull(p: PMem);
begin
  if (p^.flags and MEM_Agg) <> 0 then
    sqlite3VdbeMemFinalize(p, p^.u.pDef);
  if (p^.flags and MEM_Dyn) <> 0 then begin
    if Assigned(p^.xDel) then
      p^.xDel(p^.z);
  end;
  p^.flags := MEM_Null;
end;

{ vdbeMemClear — full release of both external and malloc'd memory }
procedure vdbeMemClear(p: PMem);
begin
  if vdbeMemDynamic(p) then
    vdbeMemClearExternAndSetNull(p);
  if p^.szMalloc <> 0 then begin
    sqlite3DbFreeNN(p^.db, p^.zMalloc);
    p^.szMalloc := 0;
  end;
  p^.z := nil;
  p^.flags := MEM_Null;
end;

{ sqlite3VdbeMemTranslate — convert pMem->z between SQLITE_UTF8 / UTF16LE /
  UTF16BE.  Faithful port of utf.c:242..423.  The UTF-16 ↔ UTF-16 byte-swap
  arm (utf.c:266..288) is in-place; UTF-8 ↔ UTF-16 arms allocate a new
  output buffer and READ_UTF8 / WRITE_UTF8 / WRITE_UTF16{LE,BE} are expanded
  inline.  SQLITE_REPLACE_INVALID_UTF arm is omitted (off in default build). }
function sqlite3VdbeMemTranslate(pMem: PMem; desiredEnc: u8): i32;
const
  utfTrans1: array[0..63] of u8 = (
    $00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$0a,$0b,$0c,$0d,$0e,$0f,
    $10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$1a,$1b,$1c,$1d,$1e,$1f,
    $00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$0a,$0b,$0c,$0d,$0e,$0f,
    $00,$01,$02,$03,$04,$05,$06,$07,$00,$01,$02,$03,$00,$01,$00,$00
  );
var
  rc:    i32;
  zIn:   Pu8;
  zTerm: Pu8;
  zOut:  Pu8;
  z:     Pu8;
  temp:  u8;
  c, c2: u32;
  len:   i64;
  newFlags: u32;
begin
  if (pMem^.flags and MEM_Str) = 0 then begin
    Result := SQLITE_OK; Exit;
  end;
  if pMem^.enc = desiredEnc then begin
    Result := SQLITE_OK; Exit;
  end;
  Assert(pMem^.enc <> 0);
  Assert(pMem^.n >= 0);
  if (pMem^.enc <> SQLITE_UTF8) and (desiredEnc <> SQLITE_UTF8) then
  begin
    rc := sqlite3VdbeMemMakeWriteable(pMem);
    if rc <> SQLITE_OK then begin
      Assert(rc = SQLITE_NOMEM);
      Result := SQLITE_NOMEM_BKPT; Exit;
    end;
    zIn   := Pu8(pMem^.z);
    zTerm := zIn + (pMem^.n and (not 1));
    while PtrUInt(zIn) < PtrUInt(zTerm) do
    begin
      temp     := zIn^;
      zIn^     := (zIn + 1)^;
      Inc(zIn);
      zIn^     := temp;
      Inc(zIn);
    end;
    pMem^.enc := desiredEnc;
    Result := SQLITE_OK; Exit;
  end;

  if desiredEnc = SQLITE_UTF8 then begin
    pMem^.n := pMem^.n and (not 1);
    len := 2 * i64(pMem^.n) + 1;
  end else begin
    len := 2 * i64(pMem^.n) + 2;
  end;

  zIn   := Pu8(pMem^.z);
  zTerm := zIn + pMem^.n;
  zOut  := Pu8(sqlite3DbMallocRaw(pMem^.db, u64(len)));
  if zOut = nil then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;
  z := zOut;

  if pMem^.enc = SQLITE_UTF8 then begin
    if desiredEnc = SQLITE_UTF16LE then begin
      while PtrUInt(zIn) < PtrUInt(zTerm) do begin
        c := zIn^; Inc(zIn);
        if c >= $c0 then begin
          c := utfTrans1[c - $c0];
          while (PtrUInt(zIn) < PtrUInt(zTerm)) and ((zIn^ and $c0) = $80) do begin
            c := (c shl 6) + u32($3f and zIn^);
            Inc(zIn);
          end;
          if (c < $80)
             or ((c and $FFFFF800) = $D800)
             or ((c and $FFFFFFFE) = $FFFE) then c := $FFFD;
        end;
        if c <= $FFFF then begin
          z^ := u8(c and $FF); Inc(z);
          z^ := u8((c shr 8) and $FF); Inc(z);
        end else begin
          z^ := u8(((c shr 10) and $3F) + (((c - $10000) shr 10) and $C0)); Inc(z);
          z^ := u8($D8 + (((c - $10000) shr 18) and $03)); Inc(z);
          z^ := u8(c and $FF); Inc(z);
          z^ := u8($DC + ((c shr 8) and $03)); Inc(z);
        end;
      end;
    end else begin
      Assert(desiredEnc = SQLITE_UTF16BE);
      while PtrUInt(zIn) < PtrUInt(zTerm) do begin
        c := zIn^; Inc(zIn);
        if c >= $c0 then begin
          c := utfTrans1[c - $c0];
          while (PtrUInt(zIn) < PtrUInt(zTerm)) and ((zIn^ and $c0) = $80) do begin
            c := (c shl 6) + u32($3f and zIn^);
            Inc(zIn);
          end;
          if (c < $80)
             or ((c and $FFFFF800) = $D800)
             or ((c and $FFFFFFFE) = $FFFE) then c := $FFFD;
        end;
        if c <= $FFFF then begin
          z^ := u8((c shr 8) and $FF); Inc(z);
          z^ := u8(c and $FF); Inc(z);
        end else begin
          z^ := u8($D8 + (((c - $10000) shr 18) and $03)); Inc(z);
          z^ := u8(((c shr 10) and $3F) + (((c - $10000) shr 10) and $C0)); Inc(z);
          z^ := u8($DC + ((c shr 8) and $03)); Inc(z);
          z^ := u8(c and $FF); Inc(z);
        end;
      end;
    end;
    pMem^.n := i32(PtrUInt(z) - PtrUInt(zOut));
    z^ := 0; Inc(z);
  end else begin
    Assert(desiredEnc = SQLITE_UTF8);
    if pMem^.enc = SQLITE_UTF16LE then begin
      while PtrUInt(zIn) < PtrUInt(zTerm) do begin
        c := zIn^; Inc(zIn);
        c := c + (u32(zIn^) shl 8); Inc(zIn);
        if (c >= $d800) and (c < $e000) then begin
          if PtrUInt(zIn) < PtrUInt(zTerm) then begin
            c2 := zIn^; Inc(zIn);
            c2 := c2 + (u32(zIn^) shl 8); Inc(zIn);
            c := (c2 and $03FF) + ((c and $003F) shl 10) + (((c and $03C0) + $0040) shl 10);
          end;
        end;
        if c < $00080 then begin
          z^ := u8(c and $FF); Inc(z);
        end else if c < $00800 then begin
          z^ := u8($C0 + ((c shr 6) and $1F)); Inc(z);
          z^ := u8($80 + (c and $3F)); Inc(z);
        end else if c < $10000 then begin
          z^ := u8($E0 + ((c shr 12) and $0F)); Inc(z);
          z^ := u8($80 + ((c shr 6) and $3F)); Inc(z);
          z^ := u8($80 + (c and $3F)); Inc(z);
        end else begin
          z^ := u8($F0 + ((c shr 18) and $07)); Inc(z);
          z^ := u8($80 + ((c shr 12) and $3F)); Inc(z);
          z^ := u8($80 + ((c shr 6) and $3F)); Inc(z);
          z^ := u8($80 + (c and $3F)); Inc(z);
        end;
      end;
    end else begin
      while PtrUInt(zIn) < PtrUInt(zTerm) do begin
        c := u32(zIn^) shl 8; Inc(zIn);
        c := c + zIn^; Inc(zIn);
        if (c >= $d800) and (c < $e000) then begin
          if PtrUInt(zIn) < PtrUInt(zTerm) then begin
            c2 := u32(zIn^) shl 8; Inc(zIn);
            c2 := c2 + zIn^; Inc(zIn);
            c := (c2 and $03FF) + ((c and $003F) shl 10) + (((c and $03C0) + $0040) shl 10);
          end;
        end;
        if c < $00080 then begin
          z^ := u8(c and $FF); Inc(z);
        end else if c < $00800 then begin
          z^ := u8($C0 + ((c shr 6) and $1F)); Inc(z);
          z^ := u8($80 + (c and $3F)); Inc(z);
        end else if c < $10000 then begin
          z^ := u8($E0 + ((c shr 12) and $0F)); Inc(z);
          z^ := u8($80 + ((c shr 6) and $3F)); Inc(z);
          z^ := u8($80 + (c and $3F)); Inc(z);
        end else begin
          z^ := u8($F0 + ((c shr 18) and $07)); Inc(z);
          z^ := u8($80 + ((c shr 12) and $3F)); Inc(z);
          z^ := u8($80 + ((c shr 6) and $3F)); Inc(z);
          z^ := u8($80 + (c and $3F)); Inc(z);
        end;
      end;
    end;
    pMem^.n := i32(PtrUInt(z) - PtrUInt(zOut));
  end;
  z^ := 0;
  Assert((pMem^.n + i32(Ord(desiredEnc = SQLITE_UTF8) * 1 + Ord(desiredEnc <> SQLITE_UTF8) * 2)) <= len);

  newFlags := MEM_Str or MEM_Term or (pMem^.flags and (MEM_AffMask or MEM_Subtype));
  sqlite3VdbeMemRelease(pMem);
  pMem^.flags := newFlags;
  pMem^.enc   := desiredEnc;
  pMem^.z     := PAnsiChar(zOut);
  pMem^.zMalloc  := pMem^.z;
  pMem^.szMalloc := sqlite3DbMallocSize(pMem^.db, pMem^.z);
  Result := SQLITE_OK;
end;

{ sqlite3VdbeMemHandleBom — strip a UTF-16 byte-order mark, if present, from
  the start of pMem->z and adjust pMem->enc to the BOM-derived encoding.
  Faithful port of utf.c:437..465.  No byte-swapping; only sets pMem->enc.
  Caller must ensure pMem->n >= 0. }
function sqlite3VdbeMemHandleBom(pMem: PMem): i32;
var
  rc:  i32;
  bom: u8;
  b1:  u8;
  b2:  u8;
  pZ:  Pu8;
begin
  rc  := SQLITE_OK;
  bom := 0;
  Assert(pMem^.n >= 0);
  if pMem^.n > 1 then
  begin
    pZ := Pu8(pMem^.z);
    b1 := pZ^;
    b2 := (pZ + 1)^;
    if (b1 = $FE) and (b2 = $FF) then
      bom := SQLITE_UTF16BE;
    if (b1 = $FF) and (b2 = $FE) then
      bom := SQLITE_UTF16LE;
  end;
  if bom <> 0 then
  begin
    rc := sqlite3VdbeMemMakeWriteable(pMem);
    if rc = SQLITE_OK then
    begin
      Dec(pMem^.n, 2);
      pZ := Pu8(pMem^.z);
      Move((pZ + 2)^, pZ^, pMem^.n);
      (pZ + pMem^.n)^     := 0;
      (pZ + pMem^.n + 1)^ := 0;
      pMem^.flags := pMem^.flags or MEM_Term;
      pMem^.enc   := bom;
    end;
  end;
  Result := rc;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeChangeEncoding — change string encoding of a Mem
  ----------------------------------------------------------------------- }
function sqlite3VdbeChangeEncoding(pMem: PMem; desiredEnc: i32): i32;
var
  rc: i32;
begin
  if (pMem^.flags and MEM_Str) = 0 then begin
    pMem^.enc := u8(desiredEnc);
    Result := SQLITE_OK; Exit;
  end;
  if pMem^.enc = u8(desiredEnc) then begin
    Result := SQLITE_OK; Exit;
  end;
  rc := sqlite3VdbeMemTranslate(pMem, u8(desiredEnc));
  Result := rc;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemGrow — grow or allocate pMem->zMalloc to at least n bytes
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemGrow(pMem: PMem; n: i32; bPreserve: i32): i32;
begin
  if (pMem^.szMalloc > 0) and (bPreserve <> 0) and (pMem^.z = pMem^.zMalloc) then begin
    if pMem^.db <> nil then begin
      pMem^.z := sqlite3DbReallocOrFree(pMem^.db, pMem^.z, u64(n));
      pMem^.zMalloc := pMem^.z;
    end else begin
      pMem^.zMalloc := sqlite3_realloc(pMem^.z, n);
      if pMem^.zMalloc = nil then sqlite3_free(pMem^.z);
      pMem^.z := pMem^.zMalloc;
    end;
    bPreserve := 0;
  end else begin
    if pMem^.szMalloc > 0 then sqlite3DbFreeNN(pMem^.db, pMem^.zMalloc);
    pMem^.zMalloc := sqlite3DbMallocRaw(pMem^.db, u64(n));
  end;
  if pMem^.zMalloc = nil then begin
    sqlite3VdbeMemSetNull(pMem);
    pMem^.z := nil;
    pMem^.szMalloc := 0;
    Result := SQLITE_NOMEM_BKPT; Exit;
  end else
    pMem^.szMalloc := sqlite3DbMallocSize(pMem^.db, pMem^.zMalloc);
  if (bPreserve <> 0) and (pMem^.z <> nil) then begin
    Move(pMem^.z^, pMem^.zMalloc^, pMem^.n);
  end;
  if (pMem^.flags and MEM_Dyn) <> 0 then begin
    if Assigned(pMem^.xDel) then
      pMem^.xDel(pMem^.z);
  end;
  pMem^.z := pMem^.zMalloc;
  pMem^.flags := pMem^.flags and not u16(MEM_Dyn or MEM_Ephem or MEM_Static);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemClearAndResize
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemClearAndResize(pMem: PMem; szNew: i32): i32;
begin
  if pMem^.szMalloc < szNew then begin
    Result := sqlite3VdbeMemGrow(pMem, szNew, 0); Exit;
  end;
  pMem^.z := pMem^.zMalloc;
  pMem^.flags := pMem^.flags and u16(MEM_Null or MEM_Int or MEM_Real or MEM_IntReal);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  vdbeMemAddTerminator — add NUL terminator (3 bytes) to pMem->z
  ----------------------------------------------------------------------- }
function vdbeMemAddTerminator(pMem: PMem): i32;
begin
  if sqlite3VdbeMemGrow(pMem, pMem^.n + 3, 1) <> 0 then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;
  pMem^.z[pMem^.n]   := #0;
  pMem^.z[pMem^.n+1] := #0;
  pMem^.z[pMem^.n+2] := #0;
  pMem^.flags := pMem^.flags or MEM_Term;
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemZeroTerminateIfAble
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemZeroTerminateIfAble(pMem: PMem): i32;
begin
  Result := 0;
  if (pMem^.flags and (MEM_Str or MEM_Term or MEM_Ephem or MEM_Static)) <> MEM_Str then
    Exit;
  if pMem^.enc <> SQLITE_UTF8 then Exit;
  if pMem^.z = nil then Exit;
  if (pMem^.flags and MEM_Dyn) <> 0 then begin
    { check if we can add terminator within existing allocation }
    if pMem^.szMalloc >= pMem^.n + 1 then begin
      pMem^.z[pMem^.n] := #0;
      pMem^.flags := pMem^.flags or MEM_Term;
      Result := 1;
    end;
  end else if pMem^.szMalloc >= pMem^.n + 1 then begin
    pMem^.z[pMem^.n] := #0;
    pMem^.flags := pMem^.flags or MEM_Term;
    Result := 1;
  end;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemMakeWriteable
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemMakeWriteable(pMem: PMem): i32;
begin
  if (pMem^.flags and (MEM_Str or MEM_Blob)) <> 0 then begin
    if ((pMem^.flags and MEM_Zero) <> 0) and (sqlite3VdbeMemExpandBlob(pMem) <> 0) then begin
      Result := SQLITE_NOMEM; Exit;
    end;
    if (pMem^.szMalloc = 0) or (pMem^.z <> pMem^.zMalloc) then begin
      Result := vdbeMemAddTerminator(pMem); Exit;
    end;
  end;
  pMem^.flags := pMem^.flags and not u16(MEM_Ephem);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemExpandBlob — expand zero-filled blob tail
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemExpandBlob(pMem: PMem): i32;
var
  nByte: i32;
begin
  { Mirror the upstream `ExpandBlob` macro guard (vdbeInt.h):
    only act when MEM_Zero is set.  Without this, calls from
    OP_IdxInsert / OP_MakeRecord / OP_String8 etc. that pass a plain
    blob would expand by `pMem^.u.nZero` bytes of garbage from the
    Mem union, growing `.n` past the actual blob length and
    triggering "database disk image is malformed" downstream. }
  if (pMem^.flags and MEM_Zero) = 0 then begin
    Result := SQLITE_OK; Exit;
  end;
  nByte := pMem^.n + pMem^.u.nZero;
  if nByte <= 0 then begin
    if (pMem^.flags and MEM_Blob) = 0 then begin Result := SQLITE_OK; Exit; end;
    nByte := 1;
  end;
  if sqlite3VdbeMemGrow(pMem, nByte, 1) <> 0 then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;
  FillChar(pMem^.z[pMem^.n], pMem^.u.nZero, 0);
  Inc(pMem^.n, pMem^.u.nZero);
  pMem^.flags := pMem^.flags and not u16(MEM_Zero or MEM_Term);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemNulTerminate
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemNulTerminate(pMem: PMem): i32;
begin
  if (pMem^.flags and (MEM_Term or MEM_Str)) <> MEM_Str then begin
    Result := SQLITE_OK; Exit;
  end;
  Result := vdbeMemAddTerminator(pMem);
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemStringify — add MEM_Str representation to a numeric Mem
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemStringify(pMem: PMem; enc: u8; bForce: u8): i32;
const
  nByte = 32;
begin
  if sqlite3VdbeMemClearAndResize(pMem, nByte) <> 0 then begin
    pMem^.enc := 0;
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;
  vdbeMemRenderNum(nByte, pMem^.z, pMem);
  pMem^.enc := SQLITE_UTF8;
  pMem^.flags := pMem^.flags or u16(MEM_Str or MEM_Term);
  if bForce <> 0 then
    pMem^.flags := pMem^.flags and not u16(MEM_Int or MEM_Real or MEM_IntReal);
  sqlite3VdbeChangeEncoding(pMem, enc);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemFinalize (vdbemem.c:506) — call aggregate finalizer.
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemFinalize(pMem: PMem; pFunc: PFuncDef): i32;
var
  pFd:  PTFuncDef;
  ctx:  Tsqlite3_context;
  t:    TMem;
begin
  if (pMem^.flags and MEM_Agg) <> 0 then
    pFd := PTFuncDef(pMem^.u.pDef)
  else
    pFd := PTFuncDef(pFunc);
  if (pFd <> nil) and Assigned(pFd^.xFinalize) then begin
    FillChar(ctx, SizeOf(ctx), 0);
    FillChar(t,   SizeOf(t),   0);
    t.flags  := MEM_Null;
    t.db     := pMem^.db;
    ctx.pOut  := @t;       { separate output — accumulator stays intact }
    ctx.pMem  := pMem;
    ctx.pFunc := pFd;
    if t.db <> nil then ctx.enc := PTsqlite3(t.db)^.enc;
    pFd^.xFinalize(@ctx);
    { Mirror vdbemem.c:524 — release the accumulator's zMalloc and copy
      the result Mem (`t`) over `pMem^` unconditionally, even on error.
      On error, `t` carries the error string set by sqlite3_result_error
      via sqlite3VdbeMemSetStr, so OP_AggFinal can recover it via
      sqlite3_value_text(pMem). }
    if pMem^.szMalloc > 0 then begin
      sqlite3DbFreeNN(pMem^.db, pMem^.zMalloc);
      pMem^.szMalloc := 0;
    end;
    pMem^ := t;
    Result := ctx.isError;
  end else begin
    pMem^.flags := MEM_Null;
    Result := SQLITE_OK;
  end;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemAggValue (vdbemem.c:539) — call window xValue method.
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemAggValue(pAccum: PMem; pOut: PMem; pFunc: PFuncDef): i32;
var
  pFd:  PTFuncDef;
  ctx:  Tsqlite3_context;
begin
  pFd := PTFuncDef(pFunc);
  sqlite3VdbeMemSetNull(pOut);
  if (pFd <> nil) and Assigned(pFd^.xValue) then begin
    FillChar(ctx, SizeOf(ctx), 0);
    ctx.pOut  := pOut;
    ctx.pMem  := pAccum;
    ctx.pFunc := pFd;
    if pAccum^.db <> nil then ctx.enc := PTsqlite3(pAccum^.db)^.enc;
    pFd^.xValue(@ctx);
    Result := ctx.isError;
  end else
    Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemRelease
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeMemRelease(pMem: PMem);
begin
  if vdbeMemDynamic(pMem) or (pMem^.szMalloc <> 0) then
    vdbeMemClear(pMem);
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemReleaseMalloc — faster release when no MEM_Dyn/MEM_Agg
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeMemReleaseMalloc(pMem: PMem);
begin
  if pMem^.szMalloc <> 0 then vdbeMemClear(pMem);
end;

{ -----------------------------------------------------------------------
  memIntValue — convert string Mem to integer (internal)
  ----------------------------------------------------------------------- }
function memIntValue(const pMem: PMem): i64;
var
  value: i64;
begin
  value := 0;
  sqlite3Atoi64(pMem^.z, value, pMem^.n, pMem^.enc);
  Result := value;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeIntValue
  ----------------------------------------------------------------------- }
function sqlite3VdbeIntValue(const pMem: PMem): i64;
var
  flags: u16;
begin
  flags := pMem^.flags;
  if (flags and (MEM_Int or MEM_IntReal)) <> 0 then begin
    Result := pMem^.u.i; Exit;
  end else if (flags and MEM_Real) <> 0 then begin
    Result := sqlite3RealToI64(pMem^.u.r); Exit;
  end else if ((flags and (MEM_Str or MEM_Blob)) <> 0) and (pMem^.z <> nil) then begin
    Result := memIntValue(pMem); Exit;
  end else
    Result := 0;
end;

{ -----------------------------------------------------------------------
  sqlite3RealToI64 — convert double to closest i64 (safe from UBSAN)
  ----------------------------------------------------------------------- }
function sqlite3RealToI64(r: Double): i64;
begin
  if r < -9223372036854774784.0 then Result := SMALLEST_INT64
  else if r > +9223372036854774784.0 then Result := LARGEST_INT64
  else Result := Trunc(r);  { Trunc truncates toward zero; i64() reinterprets bits in FPC }
end;

{ -----------------------------------------------------------------------
  sqlite3RealSameAsInt — true if double and int64 represent the same value
  ----------------------------------------------------------------------- }
function sqlite3RealSameAsInt(r1: Double; i: sqlite3_int64): i32;
var
  r2: Double;
begin
  r2 := Double(i);
  if (r1 = 0.0) or
     (CompareByte(r1, r2, SizeOf(r1)) = 0) and
     (i >= -2251799813685248) and (i < 2251799813685248) then
    Result := 1
  else
    Result := 0;
end;

{ -----------------------------------------------------------------------
  sqlite3MemRealValueRCSlowPath — slow text→double for non-UTF8 or non-terminated
  ----------------------------------------------------------------------- }
function sqlite3MemRealValueRCSlowPath(pMem: PMem; out pValue: Double): i32;
var
  rc:   i32;
  n, iIter, jIter: i32;
  zCopy: PAnsiChar;
  z:     PAnsiChar;
begin
  rc := SQLITE_OK;
  pValue := 0.0;
  if pMem^.enc = SQLITE_UTF8 then begin
    zCopy := sqlite3DbStrNDup(pMem^.db, pMem^.z, u64(pMem^.n));
    if zCopy <> nil then begin
      rc := sqlite3AtoF(zCopy, pValue);
      sqlite3DbFree(pMem^.db, zCopy);
    end;
    Result := rc; Exit;
  end else begin
    n := pMem^.n and not 1;
    zCopy := sqlite3DbMallocRaw(pMem^.db, u64(n div 2 + 2));
    if zCopy <> nil then begin
      z := pMem^.z;
      iIter := 0; jIter := 0;
      if pMem^.enc = SQLITE_UTF16LE then begin
        while iIter < n - 1 do begin
          zCopy[jIter] := z[iIter];
          if z[iIter+1] <> #0 then break;
          Inc(iIter, 2); Inc(jIter);
        end;
      end else begin
        while iIter < n - 1 do begin
          if z[iIter] <> #0 then break;
          zCopy[jIter] := z[iIter+1];
          Inc(iIter, 2); Inc(jIter);
        end;
      end;
      zCopy[jIter] := #0;
      rc := sqlite3AtoF(zCopy, pValue);
      if iIter < n then rc := -100;
      sqlite3DbFree(pMem^.db, zCopy);
    end;
    Result := rc;
  end;
end;

{ -----------------------------------------------------------------------
  sqlite3MemRealValueRC
  ----------------------------------------------------------------------- }
function sqlite3MemRealValueRC(pMem: PMem; out pValue: Double): i32;
begin
  if pMem^.z = nil then begin
    pValue := 0.0; Result := 0; Exit;
  end else if (pMem^.enc = SQLITE_UTF8) and
    (((pMem^.flags and MEM_Term) <> 0) or
     (sqlite3VdbeMemZeroTerminateIfAble(pMem) <> 0)) then begin
    Result := sqlite3AtoF(pMem^.z, pValue); Exit;
  end else if pMem^.n = 0 then begin
    pValue := 0.0; Result := 0; Exit;
  end else
    Result := sqlite3MemRealValueRCSlowPath(pMem, pValue);
end;

{ sqlite3MemRealValueNoRC — wrapper that discards rc }
function sqlite3MemRealValueNoRC(pMem: PMem): Double;
begin
  sqlite3MemRealValueRC(pMem, Result);
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeRealValue
  ----------------------------------------------------------------------- }
function sqlite3VdbeRealValue(pMem: PMem): Double;
begin
  if (pMem^.flags and MEM_Real) <> 0 then
    Result := pMem^.u.r
  else if (pMem^.flags and (MEM_Int or MEM_IntReal)) <> 0 then
    Result := Double(pMem^.u.i)
  else if (pMem^.flags and (MEM_Str or MEM_Blob)) <> 0 then
    Result := sqlite3MemRealValueNoRC(pMem)
  else
    Result := 0.0;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeBooleanValue
  ----------------------------------------------------------------------- }
function sqlite3VdbeBooleanValue(pMem: PMem; ifNull: i32): i32;
begin
  if (pMem^.flags and (MEM_Int or MEM_IntReal)) <> 0 then begin
    Result := ord(pMem^.u.i <> 0); Exit;
  end;
  if (pMem^.flags and MEM_Null) <> 0 then begin
    Result := ifNull; Exit;
  end;
  Result := ord(sqlite3VdbeRealValue(pMem) <> 0.0);
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeIntegerAffinity — demote Real→Int if lossless
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeIntegerAffinity(pMem: PMem);
var
  ix: i64;
begin
  if (pMem^.flags and MEM_IntReal) <> 0 then begin
    memSetTypeFlag(pMem, MEM_Int); Exit;
  end;
  ix := sqlite3RealToI64(pMem^.u.r);
  if (pMem^.u.r = Double(ix)) and (ix > SMALLEST_INT64) and (ix < LARGEST_INT64) then begin
    pMem^.u.i := ix;
    memSetTypeFlag(pMem, MEM_Int);
  end;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemIntegerify — convert to integer
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemIntegerify(pMem: PMem): i32;
begin
  pMem^.u.i := sqlite3VdbeIntValue(pMem);
  memSetTypeFlag(pMem, MEM_Int);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemRealify — convert to real
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemRealify(pMem: PMem): i32;
begin
  pMem^.u.r := sqlite3VdbeRealValue(pMem);
  memSetTypeFlag(pMem, MEM_Real);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemNumerify — convert to numeric (Int or Real)
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemNumerify(pMem: PMem): i32;
var
  rc: i32;
  ix: sqlite3_int64;
begin
  if (pMem^.flags and (MEM_Int or MEM_Real or MEM_IntReal or MEM_Null)) = 0 then begin
    rc := sqlite3MemRealValueRC(pMem, pMem^.u.r);
    ix := 0;
    if ((rc and 2) = 0) and (sqlite3Atoi64(pMem^.z, ix, pMem^.n, pMem^.enc) < 2) then begin
      pMem^.u.i := ix;
      memSetTypeFlag(pMem, MEM_Int);
    end else if sqlite3RealSameAsInt(pMem^.u.r, sqlite3RealToI64(pMem^.u.r)) <> 0 then begin
      pMem^.u.i := sqlite3RealToI64(pMem^.u.r);
      memSetTypeFlag(pMem, MEM_Int);
    end else
      memSetTypeFlag(pMem, MEM_Real);
  end;
  pMem^.flags := pMem^.flags and not u16(MEM_Str or MEM_Blob or MEM_Zero);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemCast — cast value to affinity (vdbemem.c:926).
  Casting is different from applying affinity in that a cast is forced.
  Used to implement the SQL "cast()" operator.
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemCast(pMem: PMem; aff: u8; encoding: u8): i32;
var
  rc: i32;
begin
  if (pMem^.flags and MEM_Null) <> 0 then begin Result := SQLITE_OK; Exit; end;
  case aff of
    SQLITE_AFF_BLOB: begin
      if (pMem^.flags and MEM_Blob) = 0 then begin
        sqlite3ValueApplyAffinity(pMem, SQLITE_AFF_TEXT, encoding);
        if (pMem^.flags and MEM_Str) <> 0 then
          memSetTypeFlag(pMem, MEM_Blob);
      end else
        pMem^.flags := pMem^.flags and not u16(MEM_TypeMask and not MEM_Blob);
    end;
    SQLITE_AFF_NUMERIC:
      sqlite3VdbeMemNumerify(pMem);
    SQLITE_AFF_INTEGER:
      sqlite3VdbeMemIntegerify(pMem);
    SQLITE_AFF_REAL:
      sqlite3VdbeMemRealify(pMem);
    else begin { SQLITE_AFF_TEXT }
      { vdbemem.c:951..962 — assert( MEM_Str==(MEM_Blob>>3) ); reinterpret
        a BLOB payload as TEXT via the bit-shift trick, then ApplyAffinity
        only stringifies non-string/non-blob payloads. }
      pMem^.flags := pMem^.flags or ((pMem^.flags and MEM_Blob) shr 3);
      sqlite3ValueApplyAffinity(pMem, SQLITE_AFF_TEXT, encoding);
      pMem^.flags := pMem^.flags and not u16(MEM_Int or MEM_Real or MEM_IntReal or MEM_Blob or MEM_Zero);
      if encoding <> SQLITE_UTF8 then pMem^.n := pMem^.n and not 1;
      rc := sqlite3VdbeChangeEncoding(pMem, encoding);
      if rc <> 0 then begin Result := rc; Exit; end;
      sqlite3VdbeMemZeroTerminateIfAble(pMem);
    end;
  end;
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemInit
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeMemInit(pMem: PMem; db: Psqlite3; flags: u16);
begin
  pMem^.flags    := flags;
  pMem^.db       := db;
  pMem^.szMalloc := 0;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemSetNull / sqlite3ValueSetNull
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeMemSetNull(pMem: PMem);
begin
  if vdbeMemDynamic(pMem) then
    vdbeMemClearExternAndSetNull(pMem)
  else
    pMem^.flags := MEM_Null;
end;

procedure sqlite3ValueSetNull(v: Psqlite3_value);
begin
  sqlite3VdbeMemSetNull(PMem(v));
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemSetZeroBlob
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeMemSetZeroBlob(pMem: PMem; n: i32);
begin
  sqlite3VdbeMemRelease(pMem);
  pMem^.flags    := MEM_Blob or MEM_Zero;
  pMem^.n        := 0;
  if n < 0 then n := 0;
  pMem^.u.nZero  := n;
  pMem^.enc      := SQLITE_UTF8;
  pMem^.z        := nil;
end;

{ -----------------------------------------------------------------------
  vdbeReleaseAndSetInt64
  ----------------------------------------------------------------------- }
procedure vdbeReleaseAndSetInt64(pMem: PMem; val: i64);
begin
  sqlite3VdbeMemSetNull(pMem);
  pMem^.u.i   := val;
  pMem^.flags := MEM_Int;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemSetInt64 / sqlite3MemSetArrayInt64
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeMemSetInt64(pMem: PMem; val: i64);
begin
  if vdbeMemDynamic(pMem) then
    vdbeReleaseAndSetInt64(pMem, val)
  else begin
    pMem^.u.i   := val;
    pMem^.flags := MEM_Int;
  end;
end;

procedure sqlite3MemSetArrayInt64(aMem: Psqlite3_value; iIdx: i32; val: i64);
begin
  sqlite3VdbeMemSetInt64(PMem(aMem) + iIdx, val);
end;

{ -----------------------------------------------------------------------
  sqlite3NoopDestructor / sqlite3VdbeMemSetPointer
  ----------------------------------------------------------------------- }
procedure sqlite3NoopDestructor(p: Pointer); cdecl;
begin
  { intentionally empty }
end;

procedure sqlite3VdbeMemSetPointer(pMem: PMem; pPtr: Pointer;
                                   zPType: PAnsiChar;
                                   xDestructor: TxDelProc);
begin
  vdbeMemClear(pMem);
  if zPType <> nil then pMem^.u.zPType := zPType else pMem^.u.zPType := '';
  pMem^.z        := pPtr;
  pMem^.flags    := MEM_Null or MEM_Dyn or MEM_Subtype or MEM_Term;
  pMem^.eSubtype := Ord('p');
  if Assigned(xDestructor) then pMem^.xDel := xDestructor
  else pMem^.xDel := @sqlite3NoopDestructor;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeValueListFree (vdbeapi.c:1024) — Phase 6.bis.3b
  Destructor callback for ValueList objects attached to a Mem via
  sqlite3VdbeMemSetPointer (used by OP_VInitIn / sqlite3_vtab_in_*).
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeValueListFree(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemSetDouble
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeMemSetDouble(pMem: PMem; val: Double);
begin
  sqlite3VdbeMemSetNull(pMem);
  if not IsNaN(val) then begin
    pMem^.u.r   := val;
    pMem^.flags := MEM_Real;
  end;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemTooBig
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemTooBig(p: PMem): i32;
var
  n: i32;
begin
  if (p^.flags and (MEM_Str or MEM_Blob)) <> 0 then begin
    n := p^.n;
    if (p^.flags and MEM_Zero) <> 0 then n := n + p^.u.nZero;
    if n > vdbeDbLimitLength(p^.db) then begin
      Result := 1; Exit;
    end;
  end;
  Result := 0;
end;

{ ==========================================================================
  Phase 5.4j — RowSet implementation (rowset.c, SQLite 3.53.0)
  ========================================================================== }

{ Allocate a new RowSet }
function sqlite3RowSetAlloc(db: PTsqlite3): PRowSet;
begin
  Result := sqlite3DbMallocRawNN(db, SizeOf(TRowSet));
  if Result <> nil then begin
    Result^.pChunk  := nil;
    Result^.db      := db;
    Result^.pEntry  := nil;
    Result^.pLast   := nil;
    Result^.pFresh  := nil;
    Result^.pForest := nil;
    Result^.iFstresh  := 0;
    Result^.rsFlags := ROWSET_SORTED;
    Result^.iBatch  := 0;
  end;
end;

{ rowset.c:sqlite3RowSetClear — free all chunks, reset state }
procedure sqlite3RowSetClear(pSet: PRowSet);
var
  pChunk: PRowSetChunk;
  pNextChunk: PRowSetChunk;
begin
  pChunk := pSet^.pChunk;
  while pChunk <> nil do begin
    pNextChunk := pChunk^.pNextChunk;
    sqlite3_free(pChunk);
    pChunk := pNextChunk;
  end;
  pSet^.pChunk  := nil;
  pSet^.pEntry  := nil;
  pSet^.pLast   := nil;
  pSet^.pFresh  := nil;
  pSet^.pForest := nil;
  pSet^.iFstresh  := 0;
  pSet^.rsFlags := ROWSET_SORTED;
end;

{ rowset.c:sqlite3RowSetDelete }
procedure sqlite3RowSetDelete(pSet: PRowSet);
begin
  sqlite3RowSetClear(pSet);
  sqlite3_free(pSet);
end;

{ rowset.c internal: allocate a fresh entry from the chunk pool }
function rowSetEntryAlloc(pSet: PRowSet): PRowSetEntry;
var
  pChunk: PRowSetChunk;
begin
  if pSet^.iFstresh = 0 then begin
    pChunk := sqlite3DbMallocRawNN(pSet^.db, SizeOf(TRowSetChunk));
    if pChunk = nil then begin Result := nil; Exit; end;
    pChunk^.pNextChunk := pSet^.pChunk;
    pSet^.pChunk := pChunk;
    pSet^.pFresh := @pChunk^.aEntry[0];
    pSet^.iFstresh := ROWSET_ENTRY_PER_CHUNK;
  end;
  Result := pSet^.pFresh;
  Inc(pSet^.pFresh);
  Dec(pSet^.iFstresh);
end;

{ rowset.c:rowSetEntryMerge — merge two sorted lists, drop duplicates. }
function rowSetEntryMerge(pA: PRowSetEntry; pB: PRowSetEntry): PRowSetEntry;
var
  head: TRowSetEntry;
  pTail: PRowSetEntry;
begin
  head.pRight := nil;
  pTail := @head;
  while True do begin
    if pA^.v <= pB^.v then begin
      if pA^.v < pB^.v then begin
        pTail^.pRight := pA;
        pTail := pA;
      end;
      pA := pA^.pRight;
      if pA = nil then begin pTail^.pRight := pB; Break; end;
    end else begin
      pTail^.pRight := pB;
      pTail := pB;
      pB := pB^.pRight;
      if pB = nil then begin pTail^.pRight := pA; Break; end;
    end;
  end;
  Result := head.pRight;
end;

{ rowset.c:rowSetEntrySort — bucket merge sort over the pRight linked list. }
function rowSetEntrySort(pIn: PRowSetEntry): PRowSetEntry;
var
  i:        u32;
  pNext:    PRowSetEntry;
  aBucket:  array[0..39] of PRowSetEntry;
begin
  FillChar(aBucket, SizeOf(aBucket), 0);
  while pIn <> nil do begin
    pNext := pIn^.pRight;
    pIn^.pRight := nil;
    i := 0;
    while (i < 40) and (aBucket[i] <> nil) do begin
      pIn := rowSetEntryMerge(aBucket[i], pIn);
      aBucket[i] := nil;
      Inc(i);
    end;
    if i >= 40 then i := 39;
    aBucket[i] := pIn;
    pIn := pNext;
  end;
  pIn := aBucket[0];
  for i := 1 to 39 do begin
    if aBucket[i] = nil then continue;
    if pIn <> nil then
      pIn := rowSetEntryMerge(pIn, aBucket[i])
    else
      pIn := aBucket[i];
  end;
  Result := pIn;
end;

{ rowset.c internal: convert sorted list to a balanced BST }
function rowSetNDeepTree(ppList: PPRowSetEntry; iDepth: i32): PRowSetEntry;
var
  pLeft: PRowSetEntry;
  pThis: PRowSetEntry;
begin
  if ppList^ = nil then begin Result := nil; Exit; end;
  if iDepth = 1 then begin
    Result := ppList^;
    ppList^ := Result^.pRight;
    Result^.pLeft  := nil;
    Result^.pRight := nil;
    Exit;
  end;
  pLeft := rowSetNDeepTree(ppList, iDepth - 1);
  pThis := ppList^;
  if pThis = nil then begin Result := pLeft; Exit; end;
  ppList^ := pThis^.pRight;
  pThis^.pLeft  := pLeft;
  pThis^.pRight := rowSetNDeepTree(ppList, iDepth - 1);
  Result := pThis;
end;

{ rowset.c internal: build a balanced BST from a sorted list }
function rowSetListToTree(pList: PRowSetEntry): PRowSetEntry;
var
  iDepth: i32;
  n:      i32;
  pTmp:   PRowSetEntry;
begin
  n := 0;
  pTmp := pList;
  while pTmp <> nil do begin Inc(n); pTmp := pTmp^.pRight; end;
  iDepth := 1;
  while (1 shl iDepth) <= n do Inc(iDepth);
  Result := rowSetNDeepTree(@pList, iDepth);
end;

{ rowset.c:rowSetTreeToList — in-order linearise a tree via pRight chain. }
procedure rowSetTreeToList(pIn: PRowSetEntry; ppFirst: PPRowSetEntry;
                           ppLast: PPRowSetEntry);
var
  pInner: PRowSetEntry;
begin
  Assert(pIn <> nil);
  if pIn^.pLeft <> nil then begin
    pInner := nil;
    rowSetTreeToList(pIn^.pLeft, ppFirst, @pInner);
    pInner^.pRight := pIn;
  end else
    ppFirst^ := pIn;
  if pIn^.pRight <> nil then
    rowSetTreeToList(pIn^.pRight, @pIn^.pRight, ppLast)
  else
    ppLast^ := pIn;
end;

{ rowset.c:sqlite3RowSetInsert }
procedure sqlite3RowSetInsert(pSet: PRowSet; rowid: i64);
var
  pEntry, pLast: PRowSetEntry;
begin
  Assert((pSet^.rsFlags and ROWSET_NEXT) = 0);
  pEntry := rowSetEntryAlloc(pSet);
  if pEntry = nil then Exit;
  pEntry^.v      := rowid;
  pEntry^.pRight := nil;
  pLast := pSet^.pLast;
  if pLast <> nil then begin
    if rowid <= pLast^.v then
      pSet^.rsFlags := pSet^.rsFlags and (not ROWSET_SORTED);
    pLast^.pRight := pEntry;
  end else
    pSet^.pEntry := pEntry;
  pSet^.pLast := pEntry;
end;

{ rowset.c:sqlite3RowSetTest — sort entries into the forest on each new
  batch, then search all forest trees for `rowid`. }
function sqlite3RowSetTest(pSet: PRowSet; iBatch: i32; rowid: i64): i32;
var
  pTree:        PRowSetEntry;
  p:            PRowSetEntry;
  pAux, pTail:  PRowSetEntry;
  ppPrevTree:   PPRowSetEntry;
begin
  Assert(pSet <> nil);
  Assert((pSet^.rsFlags and ROWSET_NEXT) = 0);

  if iBatch <> pSet^.iBatch then begin
    p := pSet^.pEntry;
    if p <> nil then begin
      ppPrevTree := @pSet^.pForest;
      if (pSet^.rsFlags and ROWSET_SORTED) = 0 then
        p := rowSetEntrySort(p);
      pTree := pSet^.pForest;
      while pTree <> nil do begin
        ppPrevTree := @pTree^.pRight;
        if pTree^.pLeft = nil then begin
          pTree^.pLeft := rowSetListToTree(p);
          break;
        end else begin
          pAux := nil; pTail := nil;
          rowSetTreeToList(pTree^.pLeft, @pAux, @pTail);
          pTree^.pLeft := nil;
          p := rowSetEntryMerge(pAux, p);
        end;
        pTree := pTree^.pRight;
      end;
      if pTree = nil then begin
        pTree := rowSetEntryAlloc(pSet);
        ppPrevTree^ := pTree;
        if pTree <> nil then begin
          pTree^.v := 0;
          pTree^.pRight := nil;
          pTree^.pLeft := rowSetListToTree(p);
        end;
      end;
      pSet^.pEntry := nil;
      pSet^.pLast  := nil;
      pSet^.rsFlags := pSet^.rsFlags or ROWSET_SORTED;
    end;
    pSet^.iBatch := iBatch;
  end;

  pTree := pSet^.pForest;
  while pTree <> nil do begin
    p := pTree^.pLeft;
    while p <> nil do begin
      if p^.v < rowid then p := p^.pRight
      else if p^.v > rowid then p := p^.pLeft
      else begin Result := 1; Exit; end;
    end;
    pTree := pTree^.pRight;
  end;
  Result := 0;
end;

{ rowset.c:sqlite3RowSetNext — extract smallest value, return 0 when empty }
function sqlite3RowSetNext(pSet: PRowSet; pRowid: Pi64): i32;
begin
  { If NEXT mode not started, merge everything into a sorted list }
  Assert(pSet <> nil);
  Assert(pSet^.pForest = nil);
  if (pSet^.rsFlags and ROWSET_NEXT) = 0 then begin
    if (pSet^.rsFlags and ROWSET_SORTED) = 0 then
      pSet^.pEntry := rowSetEntrySort(pSet^.pEntry);
    pSet^.rsFlags := pSet^.rsFlags or ROWSET_SORTED or ROWSET_NEXT;
  end;
  if pSet^.pEntry <> nil then begin
    pRowid^ := pSet^.pEntry^.v;
    pSet^.pEntry := pSet^.pEntry^.pRight;
    if pSet^.pEntry = nil then
      sqlite3RowSetClear(pSet);
    Result := 1;
  end else
    Result := 0;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemSetRowSet — real implementation (Phase 5.4j)
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemSetRowSet(pMem: PMem): i32;
var
  db:  PTsqlite3;
  pRs: PRowSet;
begin
  db := pMem^.db;
  sqlite3VdbeMemRelease(pMem);
  pRs := sqlite3RowSetAlloc(db);
  if pRs = nil then begin
    pMem^.flags := MEM_Null;
    Result := 1; { SQLITE_NOMEM indication }
    Exit;
  end;
  pMem^.z    := PAnsiChar(pRs);
  pMem^.n    := 0;
  pMem^.xDel := nil;
  pMem^.flags := MEM_Blob or MEM_Dyn;
  Result := 0;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemIsRowSet
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemIsRowSet(pMem: PMem): i32;
begin
  if (pMem^.flags and MEM_Blob) <> 0 then Result := 1 else Result := 0;
end;

{ -----------------------------------------------------------------------
  Phase 5.4 — high-level stubs needed by new opcodes
  ----------------------------------------------------------------------- }

{ sqlite3ExpirePreparedStatements — vdbeaux.c:5337.
  Walks every Vdbe attached to the connection and writes (iCode+1) into
  the 2-bit `expired` field (low bits of vdbeFlags via VDBF_EXPIRED_MASK).
  iCode=0 → expired=1 (recompile now); iCode=1 → expired=2 (recompile
  when convenient).  C: `for(p=db->pVdbe; p; p=p->pVNext) p->expired = iCode+1;` }
procedure sqlite3ExpirePreparedStatements(db: PTsqlite3; iCode: i32);
var
  v: PVdbe;
  newExp: u32;
begin
  if db = nil then Exit;
  newExp := u32(iCode + 1) and VDBF_EXPIRED_MASK;
  v := PVdbe(db^.pVdbe);
  while v <> nil do begin
    v^.vdbeFlags := (v^.vdbeFlags and not u32(VDBF_EXPIRED_MASK)) or newExp;
    v := v^.pVNext;
  end;
end;

function sqlite3AnalysisLoad(db: PTsqlite3; iDb: i32): i32;
begin
  if Assigned(gAnalysisLoad) then
    Result := gAnalysisLoad(db, iDb)
  else
    Result := SQLITE_OK;
end;

procedure sqlite3UnlinkAndDeleteTable(db: PTsqlite3; iDb: i32; zTabName: PAnsiChar);
begin
  if Assigned(gUnlinkAndDeleteTable) then
    gUnlinkAndDeleteTable(db, iDb, zTabName);
end;

procedure sqlite3UnlinkAndDeleteIndex(db: PTsqlite3; iDb: i32; zIdxName: PAnsiChar);
begin
  if Assigned(gUnlinkAndDeleteIndex) then
    gUnlinkAndDeleteIndex(db, iDb, zIdxName);
end;

procedure sqlite3UnlinkAndDeleteTrigger(db: PTsqlite3; iDb: i32; zTrigName: PAnsiChar);
begin
  if Assigned(gUnlinkAndDeleteTrigger) then
    gUnlinkAndDeleteTrigger(db, iDb, zTrigName);
end;

procedure sqlite3RootPageMoved(db: PTsqlite3; iDb: i32; iFstrom: i32; iTo: i32);
begin
  if Assigned(gRootPageMoved) then
    gRootPageMoved(db, iDb, iFstrom, iTo);
end;

procedure sqlite3FkClearTriggerCache(db: PTsqlite3; iDb: i32);
begin
  if Assigned(gFkClearTriggerCache) then
    gFkClearTriggerCache(db, iDb);
end;

procedure sqlite3ResetAllSchemasOfConnection(db: PTsqlite3);
begin
  if Assigned(gResetAllSchemas) then
    gResetAllSchemas(db);
end;

function sqlite3SchemaMutexHeld(db: PTsqlite3; iDb: i32; pSchema: Pointer): i32;
begin Result := 1; end;  { Always held in single-connection mode }

{ util.c:sqlite3LogEst — compute approx 10*log2(x) as LogEst (i16) }
function sqlite3LogEst(n: u64): i16;
const
  a: array[0..7] of i16 = (0, 2, 3, 5, 6, 7, 8, 9);
var
  y: i16;
  x: u64;
begin
  x := n;
  y := 40;
  if x < 8 then
  begin
    if x < 2 then begin Result := 0; Exit; end;
    while x < 8 do begin Dec(y, 10); x := x shl 1; end;
  end else begin
    while x > 255 do begin Inc(y, 40); x := x shr 4; end;
    while x > 15  do begin Inc(y, 10); x := x shr 1; end;
  end;
  Result := a[x and 7] + y - 10;
end;

{ util.c:sqlite3LogEstAdd — approximate sum of two LogEst values
  (where.c uses this when combining the cost of a key search with the
  cost of stepping forward through matching rows).  Direct port of
  util.c:2069..2098. }
function sqlite3LogEstAdd(a: i16; b: i16): i16;
const
  x: array[0..31] of u8 = (
    10, 10,
     9,  9,
     8,  8,
     7,  7,  7,
     6,  6,  6,
     5,  5,  5,
     4,  4,  4,  4,
     3,  3,  3,  3,  3,  3,
     2,  2,  2,  2,  2,  2,  2);
begin
  if a >= b then
  begin
    if a > b + 49 then Exit(a);
    if a > b + 31 then Exit(i16(a + 1));
    Result := i16(a + x[a - b]);
  end else
  begin
    if b > a + 49 then Exit(b);
    if b > a + 31 then Exit(i16(b + 1));
    Result := i16(b + x[b - a]);
  end;
end;

{ util.c:2125 — Convert a double into a LogEst, i.e. compute an
  approximation for 10*log2(x).  Uses the integer LogEst path for
  values up to 2e9; above that, decode the IEEE-754 binary64 exponent
  directly from the bit pattern. }
function sqlite3LogEstFromDouble(x: Double): i16;
var
  a: u64;
  e: i16;
begin
  if x <= 1 then begin Result := 0; Exit; end;
  if x <= 2000000000 then begin Result := sqlite3LogEst(u64(Trunc(x))); Exit; end;
  Move(x, a, 8);
  e := i16((a shr 52) - 1022);
  Result := i16(e * 10);
end;

{ util.c:2139 — Convert a LogEst into an integer.  Inverse of
  sqlite3LogEst (within the rounding precision of LogEst). }
function sqlite3LogEstToInt(x: i16): u64;
var
  n: u64;
  xi: i32;
begin
  xi := x;
  n  := u64(xi mod 10);
  xi := xi div 10;
  if n >= 5 then n := n - 2
  else if n >= 1 then n := n - 1;
  if xi > 60 then begin Result := u64(LARGEST_INT64); Exit; end;
  if xi >= 3 then
    Result := (n + 8) shl (xi - 3)
  else
    Result := (n + 8) shr (3 - xi);
end;

{ -----------------------------------------------------------------------
  sqlite3ValueApplyAffinity — stub (affinity logic in codegen, Phase 6)
  ----------------------------------------------------------------------- }
procedure sqlite3ValueApplyAffinity(pVal: Psqlite3_value; aff: u8; enc: u8);
var
  p: PMem;
begin
  { Port of vdbe.c:453 — simply delegate to the runtime applyAffinity,
    which only demotes Real->Int when LOSSLESS. }
  p := PMem(pVal);
  if p = nil then Exit;
  applyAffinity(p, AnsiChar(aff), enc);
end;

{ -----------------------------------------------------------------------
  vdbeClrCopy + sqlite3VdbeMemShallowCopy
  ----------------------------------------------------------------------- }
procedure vdbeClrCopy(pTo: PMem; const pFrom: PMem; eType: i32);
begin
  vdbeMemClearExternAndSetNull(pTo);
  sqlite3VdbeMemShallowCopy(pTo, pFrom, eType);
end;

procedure sqlite3VdbeMemShallowCopy(pTo: PMem; const pFrom: PMem; srcType: i32);
begin
  if vdbeMemDynamic(pTo) then begin vdbeClrCopy(pTo, pFrom, srcType); Exit; end;
  Move(pFrom^, pTo^, MEMCELLSIZE);
  if (pFrom^.flags and MEM_Static) = 0 then begin
    pTo^.flags := pTo^.flags and not u16(MEM_Dyn or MEM_Static or MEM_Ephem);
    pTo^.flags := pTo^.flags or u16(srcType);
  end;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemCopy — full deep copy
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemCopy(pTo: PMem; const pFrom: PMem): i32;
begin
  Result := SQLITE_OK;
  if vdbeMemDynamic(pTo) then vdbeMemClearExternAndSetNull(pTo);
  Move(pFrom^, pTo^, MEMCELLSIZE);
  pTo^.flags := pTo^.flags and not u16(MEM_Dyn);
  if (pTo^.flags and (MEM_Str or MEM_Blob)) <> 0 then begin
    if (pFrom^.flags and MEM_Static) = 0 then begin
      pTo^.flags := pTo^.flags or MEM_Ephem;
      Result := sqlite3VdbeMemMakeWriteable(pTo);
    end;
  end;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemMove
  ----------------------------------------------------------------------- }
procedure sqlite3VdbeMemMove(pTo: PMem; pFrom: PMem);
begin
  sqlite3VdbeMemRelease(pTo);
  Move(pFrom^, pTo^, SizeOf(TMem));
  pFrom^.flags    := MEM_Null;
  pFrom^.szMalloc := 0;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemSetStr
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemSetStr(pMem: PMem; z: PAnsiChar; n: i64;
                              enc: u8; xDel: TxDelProc): i32;
var
  nByte:  i64;
  iLimit: i32;
  flags:  u16;
  nAlloc: i64;
begin
  nByte := n;
  if z = nil then begin
    sqlite3VdbeMemSetNull(pMem);
    Result := SQLITE_OK; Exit;
  end;
  if pMem^.db <> nil then iLimit := vdbeDbLimitLength(pMem^.db)
  else iLimit := SQLITE_MAX_LENGTH;
  if nByte < 0 then begin
    if enc = SQLITE_UTF8 then
      nByte := sqlite3Strlen30(z)
    else begin
      nByte := 0;
      while (nByte <= iLimit) and ((Ord(z[nByte]) or Ord(z[nByte+1])) <> 0) do
        Inc(nByte, 2);
    end;
    flags := MEM_Str or MEM_Term;
  end else if enc = 0 then begin
    flags := MEM_Blob;
    enc := SQLITE_UTF8;
  end else
    flags := MEM_Str;
  if nByte > iLimit then begin
    if Assigned(xDel) and (TxDelProc(xDel) <> TxDelProc(SQLITE_TRANSIENT)) then begin
      if TxDelProc(xDel) = SQLITE_DYNAMIC then
        sqlite3DbFree(pMem^.db, Pointer(z))
      else
        xDel(Pointer(z));
    end;
    sqlite3VdbeMemSetNull(pMem);
    Result := SQLITE_TOOBIG; Exit;
  end;
  if TxDelProc(xDel) = TxDelProc(SQLITE_TRANSIENT) then begin
    nAlloc := nByte;
    if (flags and MEM_Term) <> 0 then begin
      if enc = SQLITE_UTF8 then Inc(nAlloc) else Inc(nAlloc, 2);
    end;
    { Mirror vdbemem.c:1338 — MAX(nAlloc,32) is the resize floor; the
      memcpy still copies just nAlloc bytes (z is only that large). }
    if nAlloc < 32 then begin
      if sqlite3VdbeMemClearAndResize(pMem, 32) <> 0 then begin
        Result := SQLITE_NOMEM_BKPT; Exit;
      end;
    end else begin
      if sqlite3VdbeMemClearAndResize(pMem, i32(nAlloc)) <> 0 then begin
        Result := SQLITE_NOMEM_BKPT; Exit;
      end;
    end;
    Move(z^, pMem^.z^, nAlloc);
  end else begin
    sqlite3VdbeMemRelease(pMem);
    pMem^.z := z;
    if TxDelProc(xDel) = SQLITE_DYNAMIC then begin
      pMem^.zMalloc  := pMem^.z;
      pMem^.szMalloc := sqlite3DbMallocSize(pMem^.db, pMem^.zMalloc);
    end else begin
      pMem^.xDel := xDel;
      if TxDelProc(xDel) = TxDelProc(SQLITE_STATIC) then
        flags := flags or MEM_Static
      else
        flags := flags or MEM_Dyn;
    end;
  end;
  pMem^.n    := i32(nByte and $7fffffff);
  pMem^.flags := flags;
  pMem^.enc  := enc;
  if enc > SQLITE_UTF8 then sqlite3VdbeMemHandleBom(pMem);
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemSetText — simplified SetStr for always-UTF8 with db != nil
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemSetText(pMem: PMem; z: PAnsiChar; n: i64;
                               xDel: TxDelProc): i32;
var
  nByte: i64;
  flags: u16;
  nAlloc: i64;
begin
  nByte := n;
  if z = nil then begin
    sqlite3VdbeMemSetNull(pMem);
    Result := SQLITE_OK; Exit;
  end;
  if nByte < 0 then begin
    nByte := sqlite3Strlen30(z);
    flags := MEM_Str or MEM_Term;
  end else
    flags := MEM_Str;
  if nByte > vdbeDbLimitLength(pMem^.db) then begin
    if Assigned(xDel) and (TxDelProc(xDel) <> TxDelProc(SQLITE_TRANSIENT)) then begin
      if TxDelProc(xDel) = SQLITE_DYNAMIC then
        sqlite3DbFree(pMem^.db, Pointer(z))
      else
        xDel(Pointer(z));
    end;
    sqlite3VdbeMemSetNull(pMem);
    Result := SQLITE_TOOBIG; Exit;
  end;
  if TxDelProc(xDel) = TxDelProc(SQLITE_TRANSIENT) then begin
    nAlloc := nByte + 1;
    if nAlloc < 32 then nAlloc := 32;
    if sqlite3VdbeMemClearAndResize(pMem, i32(nAlloc)) <> 0 then begin
      Result := SQLITE_NOMEM_BKPT; Exit;
    end;
    Move(z^, pMem^.z^, nByte);
    pMem^.z[nByte] := #0;
  end else begin
    sqlite3VdbeMemRelease(pMem);
    pMem^.z := z;
    if TxDelProc(xDel) = SQLITE_DYNAMIC then begin
      pMem^.zMalloc  := pMem^.z;
      pMem^.szMalloc := sqlite3DbMallocSize(pMem^.db, pMem^.zMalloc);
      pMem^.xDel     := nil;
    end else if TxDelProc(xDel) = TxDelProc(SQLITE_STATIC) then begin
      pMem^.xDel := xDel;
      flags := flags or MEM_Static;
    end else begin
      pMem^.xDel := xDel;
      flags := flags or MEM_Dyn;
    end;
  end;
  pMem^.flags := flags;
  pMem^.n    := i32(nByte and $7fffffff);
  pMem^.enc  := SQLITE_UTF8;
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemFromBtree / sqlite3VdbeMemFromBtreeZeroOffset
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemFromBtree(pCur: PBtCursor; offset: u32;
                                 amt: u32; pMem: PMem): i32;
var
  rc: i32;
begin
  pMem^.flags := MEM_Null;
  if amt >= SQLITE_MAX_ALLOCATION_SIZE then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;
  rc := sqlite3VdbeMemClearAndResize(pMem, i32(amt) + 1);
  if rc = SQLITE_OK then begin
    rc := sqlite3BtreePayload(pCur, offset, amt, pMem^.z);
    if rc = SQLITE_OK then begin
      pMem^.z[amt] := #0;
      pMem^.flags  := MEM_Blob;
      pMem^.n      := i32(amt);
    end else
      sqlite3VdbeMemRelease(pMem);
  end;
  Result := rc;
end;

function sqlite3VdbeMemFromBtreeZeroOffset(pCur: PBtCursor;
                                           amt: u32; pMem: PMem): i32;
var
  available: u32;
  rc:        i32;
begin
  available := 0;
  rc := SQLITE_OK;
  pMem^.z := sqlite3BtreePayloadFetch(pCur, available);
  if amt <= available then begin
    pMem^.flags := MEM_Blob or MEM_Ephem;
    pMem^.n     := i32(amt);
  end else
    rc := sqlite3VdbeMemFromBtree(pCur, 0, amt, pMem);
  Result := rc;
end;

{ -----------------------------------------------------------------------
  sqlite3ValueText / valueToText helper
  ----------------------------------------------------------------------- }
function valueToText(pVal: Psqlite3_value; enc: u8): Pointer;
var
  p: PMem;
begin
  p := PMem(pVal);
  Result := nil;
  if (p^.flags and (MEM_Blob or MEM_Str)) <> 0 then begin
    if ((p^.flags and MEM_Zero) <> 0) and (sqlite3VdbeMemExpandBlob(p) <> 0) then Exit;
    p^.flags := p^.flags or MEM_Str;
    if p^.enc <> (enc and not SQLITE_UTF16_ALIGNED) then
      sqlite3VdbeChangeEncoding(p, enc and not SQLITE_UTF16_ALIGNED);
    sqlite3VdbeMemNulTerminate(p);
  end else begin
    sqlite3VdbeMemStringify(p, enc, 0);
  end;
  if p^.enc = (enc and not SQLITE_UTF16_ALIGNED) then
    Result := p^.z;
end;

function sqlite3ValueText(pVal: Psqlite3_value; enc: u8): Pointer;
var
  p: PMem;
begin
  if pVal = nil then begin Result := nil; Exit; end;
  p := PMem(pVal);
  if ((p^.flags and (MEM_Str or MEM_Term)) = (MEM_Str or MEM_Term)) and
     (p^.enc = enc) then begin
    Result := p^.z; Exit;
  end;
  if (p^.flags and MEM_Null) <> 0 then begin
    Result := nil; Exit;
  end;
  Result := valueToText(pVal, enc);
end;

{ -----------------------------------------------------------------------
  sqlite3ValueIsOfClass
  ----------------------------------------------------------------------- }
function sqlite3ValueIsOfClass(pVal: Psqlite3_value; xFree: TxDelProc): i32;
var
  p: PMem;
begin
  p := PMem(pVal);
  if (pVal <> nil) and ((p^.flags and (MEM_Str or MEM_Blob)) <> 0) and
     ((p^.flags and MEM_Dyn) <> 0) and (p^.xDel = xFree) then
    Result := 1
  else
    Result := 0;
end;

{ -----------------------------------------------------------------------
  sqlite3ValueNew / sqlite3ValueSetStr / sqlite3ValueFree / sqlite3ValueBytes
  ----------------------------------------------------------------------- }
function sqlite3ValueNew(db: Psqlite3): Psqlite3_value;
var
  p: PMem;
begin
  p := sqlite3DbMallocZero(db, SizeOf(TMem));
  if p <> nil then begin
    p^.flags := MEM_Null;
    p^.db    := db;
  end;
  Result := Psqlite3_value(p);
end;

{ valueNew — port of vdbemem.c:1632..1672.  STAT4-aware factory: if pCtx is
  nil, falls through to sqlite3ValueNew(db); otherwise allocates (on first
  call) the UnpackedRecord that will be returned to the caller of
  sqlite3Stat4ProbeSetValue, and returns a pointer to its iVal'th aMem cell.
  Static in C — kept file-private here too.  STAT4 body gated behind the
  ifdef; default build collapses to the plain sqlite3ValueNew path. }
function valueNew(db: Psqlite3; p: PValueNewStat4Ctx): Psqlite3_value;
{$IFDEF SQLITE_ENABLE_STAT4}
var
  pRec:     PUnpackedRecord;
  pIdx:     PIndex;
  nByte:    i64;
  i:        i32;
  nCol:     i32;
  pKeyInfo: Pointer;
  aMm:      PMem;
{$ENDIF}
begin
{$IFDEF SQLITE_ENABLE_STAT4}
  if p <> nil then begin
    pRec := p^.ppRec^;
    if pRec = nil then begin
      pIdx := p^.pIdx;
      if Assigned(gKeyInfoOfIndex) then
        nCol := gKeyInfoOfIndex(p^.pParse, pIdx, pKeyInfo)
      else begin
        pKeyInfo := nil;
        nCol := 0;
      end;
      nByte := i64(SizeOf(TMem)) * nCol + ROUND8(SizeOf(TUnpackedRecord));
      pRec := PUnpackedRecord(sqlite3DbMallocZero(db, u64(nByte)));
      if pRec <> nil then begin
        pRec^.pKeyInfo := pKeyInfo;
        if pRec^.pKeyInfo <> nil then begin
          { C asserts pKeyInfo->nAllField==nCol and pKeyInfo->enc==ENC(db);
            elided here (codegen owns those fields). }
          aMm := PMem(PByte(pRec) + ROUND8(SizeOf(TUnpackedRecord)));
          pRec^.aMem := aMm;
          for i := 0 to nCol - 1 do begin
            aMm[i].flags := MEM_Null;
            aMm[i].db    := db;
          end;
        end else begin
          sqlite3DbFreeNN(db, pRec);
          pRec := nil;
        end;
      end;
      if pRec = nil then begin
        Result := nil;
        Exit;
      end;
      p^.ppRec^ := pRec;
    end;
    pRec^.nField := u16(p^.iVal + 1);
    aMm := PMem(pRec^.aMem);
    sqlite3VdbeMemSetNull(@aMm[p^.iVal]);
    Result := Psqlite3_value(@aMm[p^.iVal]);
    Exit;
  end;
{$ENDIF}
  { Non-STAT4 path mirrors `return sqlite3ValueNew(db)` (vdbemem.c:1671).
    p is unreferenced in this build; FPC tolerates unused param. }
  Result := sqlite3ValueNew(db);
end;

{ valueFromFunction — port of vdbemem.c:1701..1799.  Pre-evaluates a
  deterministic scalar function call at planner time so its constant result
  becomes a probe value into pIdx^.aSample[].  Body lives in
  passqlite3codegen.valueFromFunctionImpl (needs PExpr layout and
  sqlite3FindFunction / sqlite3Stat4ValueFromExpr / sqlite3ErrorMsg, all
  codegen-owned).  Default build collapses to SQLITE_OK with *ppVal=nil,
  matching the C `#define valueFromFunction(...) SQLITE_OK` non-STAT4 arm
  at vdbemem.c:1782. }
function valueFromFunction(db: Psqlite3; pExpr: Pointer;
                           enc: u8; aff: u8;
                           out ppVal: Psqlite3_value;
                           pCtx: PValueNewStat4Ctx): i32;
begin
{$IFDEF SQLITE_ENABLE_STAT4}
  if Assigned(gValueFromFunctionImpl) then
  begin
    Result := gValueFromFunctionImpl(db, pExpr, enc, aff, ppVal, pCtx);
    Exit;
  end;
{$ENDIF}
  ppVal  := nil;
  Result := SQLITE_OK;
end;

procedure sqlite3ValueSetStr(v: Psqlite3_value; n: i32; z: Pointer;
                             enc: u8; xDel: TxDelProc);
begin
  if v <> nil then
    sqlite3VdbeMemSetStr(PMem(v), z, n, enc, xDel);
end;

procedure sqlite3ValueFree(v: Psqlite3_value);
begin
  if v = nil then Exit;
  sqlite3VdbeMemRelease(PMem(v));
  sqlite3DbFreeNN(PMem(v)^.db, v);
end;

function valueBytes(pVal: Psqlite3_value; enc: u8): i32;
begin
  if valueToText(pVal, enc) <> nil then Result := PMem(pVal)^.n
  else Result := 0;
end;

function sqlite3ValueBytes(pVal: Psqlite3_value; enc: u8): i32;
var
  p: PMem;
begin
  p := PMem(pVal);
  if ((p^.flags and MEM_Str) <> 0) and (pVal^.enc = enc) then begin
    Result := p^.n; Exit;
  end;
  if ((p^.flags and MEM_Str) <> 0) and (enc <> SQLITE_UTF8) and (pVal^.enc <> SQLITE_UTF8) then begin
    Result := p^.n; Exit;
  end;
  if (p^.flags and MEM_Blob) <> 0 then begin
    if (p^.flags and MEM_Zero) <> 0 then Result := p^.n + p^.u.nZero
    else Result := p^.n;
    Exit;
  end;
  if (p^.flags and MEM_Null) <> 0 then begin Result := 0; Exit; end;
  Result := valueBytes(pVal, enc);
end;

{ -----------------------------------------------------------------------
  sqlite3ValueFromExpr — vdbemem.c:1978.  Dispatches to the codegen
  trampoline that has visibility into the PExpr layout.  When the hook
  is unwired (codegen-less test harnesses) returns NULL — the documented
  fallback for "expression cannot be converted to a value".  Body lives
  at passqlite3codegen.valueFromExprTrampoline.
  ----------------------------------------------------------------------- }
function sqlite3ValueFromExpr(db: Psqlite3; pExpr: Pointer;
                              enc: u8; affinity: u8;
                              out ppVal: Psqlite3_value): i32;
begin
  ppVal := nil;
  if pExpr = nil then begin Result := 0; Exit; end;
  if Assigned(gValueFromExprImpl) then
    Result := gValueFromExprImpl(db, pExpr, enc, affinity, ppVal, nil)
  else
    Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3Stat4Column / sqlite3Stat4ProbeFree — real bodies (vdbemem.c:2149..2210)
  STAT4-gated in C; non-STAT4 build keeps a stub form so the unit-interface
  forward decls (vdbe.pas:1655..1657) and the codegen call site link cleanly.
  ----------------------------------------------------------------------- }
function sqlite3Stat4Column(db: Psqlite3; pRec: Pointer; nRec: i32;
                            iCol: i32; var ppVal: Psqlite3_value): i32;
{$IFDEF SQLITE_ENABLE_STAT4}
var
  t:     u32;
  nHdr:  u32;
  iHdr:  u32;
  iFstield: i64;
  szField: u32;
  i:     i32;
  a:     Pu8;
  pM:    PMem;
{$ENDIF}
begin
{$IFDEF SQLITE_ENABLE_STAT4}
  t := 0; nHdr := 0; iHdr := 0; szField := 0;
  a := Pu8(pRec);
  pM := PMem(ppVal);
  { getVarint32 macro fast path: high-bit clear means single-byte varint. }
  if (a[0] and $80) = 0 then begin
    nHdr := u32(a[0]);
    iHdr := 1;
  end else
    iHdr := sqlite3GetVarint32(a, nHdr);
  if (nHdr > u32(nRec)) or (iHdr >= nHdr) then begin
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;
  iFstield := nHdr;
  for i := 0 to iCol do begin
    if (a[iHdr] and $80) = 0 then begin
      t := u32(a[iHdr]);
      iHdr := iHdr + 1;
    end else
      iHdr := iHdr + u32(sqlite3GetVarint32(@a[iHdr], t));
    if iHdr > nHdr then begin Result := SQLITE_CORRUPT_BKPT; Exit; end;
    szField := sqlite3VdbeSerialTypeLen(t);
    iFstield := iFstield + szField;
  end;
  if iFstield > nRec then begin Result := SQLITE_CORRUPT_BKPT; Exit; end;
  if pM = nil then begin
    pM := PMem(sqlite3ValueNew(db));
    ppVal := Psqlite3_value(pM);
    if pM = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
  end;
  sqlite3VdbeSerialGet(@a[iFstield - szField], t, pM);
  pM^.enc := vdbeDbEnc(db);
  Result := SQLITE_OK;
{$ELSE}
  { Non-STAT4 build: stat4 sample blobs are never produced, so this is
    unreachable in practice.  Return OK with *ppVal untouched. }
  ppVal := ppVal; { silence FPC unused-out hint }
  if (db = nil) or (pRec = nil) or (nRec = 0) or (iCol = 0) then ;
  Result := SQLITE_OK;
{$ENDIF}
end;

{ sqlite3Stat4ProbeFree — port of vdbemem.c:2194.
  Releases an UnpackedRecord built by sqlite3Stat4ProbeSetValue: walks the
  per-column Mem array (length = pKeyInfo^.nAllField at byte offset 8 in
  TKeyInfo), invokes sqlite3VdbeMemRelease on each cell, drops the KeyInfo
  reference via the codegen-installed gKeyInfoUnref hook, and frees the
  record itself.  Dead-code in the default build (gated on SQLITE_ENABLE_STAT4
  in the C reference) but matches C 1:1 once where.c stat4 paths are wired. }
procedure sqlite3Stat4ProbeFree(pRec: Pointer);
{$IFDEF SQLITE_ENABLE_STAT4}
var
  p:        PUnpackedRecord;
  nCol:     i32;
  aMem:     PMem;
  pCell:    PMem;
  i:        i32;
  db:       Psqlite3;
  pKeyInfo: Pointer;
{$ENDIF}
begin
{$IFDEF SQLITE_ENABLE_STAT4}
  if pRec = nil then Exit;
  p := PUnpackedRecord(pRec);
  pKeyInfo := p^.pKeyInfo;
  { TKeyInfo.nAllField is at byte offset 8 (u16). }
  nCol := i32(Pu16(PByte(pKeyInfo) + 8)^);
  aMem := PMem(p^.aMem);
  if (aMem <> nil) and (nCol > 0) then
  begin
    db := aMem^.db;
    pCell := aMem;
    for i := 0 to nCol - 1 do
    begin
      sqlite3VdbeMemRelease(pCell);
      Inc(pCell);
    end;
  end
  else
    db := nil;
  if Assigned(gKeyInfoUnref) then
    gKeyInfoUnref(pKeyInfo);
  if db <> nil then
    sqlite3DbFreeNN(db, pRec)
  else
    sqlite3DbFree(nil, pRec);
{$ELSE}
  { Non-STAT4 build: STAT4 probe records are never built so the only callers
    (where.c:4303 path, gated in C) never reach this in practice.  Keep a
    NULL-tolerant stub so the where.c port can call it unconditionally. }
  if pRec = nil then ;
{$ENDIF}
end;

{ btreeMovetoIndexImpl — registered into btree.pas as the index-cursor arm
  of btreeMoveto.  Faithful port of btree.c:858..889 (the pKey<>nil branch). }
function btreeMovetoIndexImpl(pCur: PBtCursor; pKey: Pointer; nKey: i64;
                              pRes: Pi32): i32;
var
  pIdxKey: PUnpackedRecord;
  pKI:     PKeyInfo;
  rc:      i32;
  nAll:    u16;
begin
  pKI := pCur^.pKeyInfo;
  pIdxKey := PUnpackedRecord(sqlite3VdbeAllocUnpackedRecord(pKI));
  if pIdxKey = nil then begin
    Result := SQLITE_NOMEM_BKPT;
    Exit;
  end;
  sqlite3VdbeRecordUnpack(pKI, i32(nKey), pKey, pIdxKey);
  nAll := Pu16(Pu8(pKI) + 8)^;
  if (pIdxKey^.nField = 0) or (pIdxKey^.nField > i32(nAll)) then
    rc := SQLITE_CORRUPT_BKPT
  else
    rc := sqlite3BtreeIndexMoveto(pCur, pIdxKey, pRes);
  sqlite3DbFree(pCur^.pBtree^.db, pIdxKey);
  Result := rc;
end;

{ btreeRecordCmpEncChgImpl — wired into btree.pas's
  btreeRecordCmpEncChgHook at init.  The btree comparator calls this
  when pColl^.enc differs from the LHS kiEnc or RHS pRhs^.enc — see
  passqlite3btree.pas:3303 region.  We synthesise a Mem(kiEnc) over the
  LHS raw bytes and delegate to sqlite3VdbeCompareMemStringEncChg
  (vdbeaux.c:4450 port). }
function btreeRecordCmpEncChgImpl(pLhsBytes: Pointer; nLhs: i32;
                                  kiEnc: u8; db: Pointer;
                                  pRhs: Pointer;
                                  pColl: Pointer;
                                  prcErr: Pu8): i32;
var
  mLhs: TMem;
begin
  sqlite3VdbeMemInit(@mLhs, Psqlite3(db), 0);
  mLhs.flags := MEM_Str or MEM_Ephem;
  mLhs.enc   := kiEnc;
  mLhs.z     := PAnsiChar(pLhsBytes);
  mLhs.n     := nLhs;
  Result := sqlite3VdbeCompareMemStringEncChg(@mLhs, PMem(pRhs),
                                              PTCollSeq(pColl), prcErr);
  sqlite3VdbeMemReleaseMalloc(@mLhs);
end;

initialization
  FillChar(gVdbeOpDummy, SizeOf(TVdbeOp), 0);
  { vdbeapi.c:1295 — the static nullMem returned by columnNullValue() is a
    const Mem with flags=MEM_Null.  Without MEM_Null set here, a column read
    of an out-of-range / post-reset statement returns @gNullMem with flags=0,
    which sqlite3ValueText() then treats as a real value and mutates/caches
    (leaking a stale "0.0" etc. into every later null-column access). }
  FillChar(gNullMem, SizeOf(gNullMem), 0);
  gNullMem.flags := MEM_Null;
  SQLITE_DYNAMIC   := @sqlite3FreeXDel;
  SQLITE_TRANSIENT := TxDelProc(Pointer(-1));
  btreeMovetoIndexHook   := @btreeMovetoIndexImpl;
  btreeRecordCmpEncChgHook := @btreeRecordCmpEncChgImpl;

end.
