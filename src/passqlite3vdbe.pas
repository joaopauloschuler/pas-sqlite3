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
  PExpr     = Pointer;  { Expr     — Phase 6 (expr.c) }
  PParse    = Pointer;  { Parse    — Phase 7 (tokenize.c / parse.y) }
  PVList    = Pointer;  { VList (int array) — Phase 6 }
  PVTable   = Pointer;  { VTable   — Phase 6.bis (vtab.c) }
  Psqlite3_vtab_cursor = Pointer;  { vtab cursor — Phase 6.bis }
  PVdbeSorter = ^TVdbeSorter;      { VdbeSorter  — Phase 5.7 (vdbesort.c) }

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
    pFree:           Pointer;        { free this when deleting the Vdbe }
    pFrame:          PVdbeFrame;     { currently executing sub-frame (nil=main) }
    pDelFrame:       PVdbeFrame;     { sub-frames to free on VM reset }
    nFrame:          i32;            { count of frames in pFrame chain }
    expmask:         u32;            { binding changes that invalidate VM }
    pProgram:        PSubProgram;    { all sub-programs used by this VM }
    pAuxData:        PAuxData;       { linked list of auxdata allocations }
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
    Phase 5.7 — vdbesort.c external sorter types.
    Full implementations of PmaReader, MergeEngine, SortSubtask, and
    SorterRecord are deferred to Phase 7 (SQL compiler available).
    We define TVdbeSorter with the fields needed by the stub public API.
    ----------------------------------------------------------------------- }

  TSorterFile = record
    pFd:  Pointer;         { sqlite3_file* }
    iEof: i64;             { bytes of data stored in pFd }
  end;

  TSorterList = record
    pList:   Pointer;      { SorterRecord* linked list }
    aMemory: Pu8;          { bulk memory for pList (nil if individual allocs) }
    szPMA:   i64;          { size of pList as PMA in bytes }
  end;

  TVdbeSorter = record
    mnPmaSize:   i32;      { minimum PMA size, in bytes }
    mxPmaSize:   i32;      { maximum PMA size, in bytes; 0=no limit }
    mxKeysize:   i32;      { largest serialised key seen so far }
    pgsz:        i32;      { main database page size }
    pReader:     Pointer;  { PmaReader* — read data after Rewind() }
    pMerger:     Pointer;  { MergeEngine* — used when bUseThreads=0 }
    db:          PTsqlite3; { database connection }
    pKeyInfo:    PKeyInfo; { how to compare records }
    pUnpacked:   Pointer;  { UnpackedRecord* — used by VdbeSorterCompare }
    list:        TSorterList; { in-memory record list }
    iMemory:     i32;      { offset of free space in list.aMemory }
    nMemory:     i32;      { size of list.aMemory allocation }
    bUsePMA:     u8;       { true if one or more PMAs created }
    bUseThreads: u8;       { true to use background threads }
    iPrev:       u8;       { previous thread used to flush PMA }
    nTask:       u8;       { size of aTask array }
    typeMask:    u8;       { SORTER_TYPE_INTEGER|TEXT mask }
  end;

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
procedure sqlite3VdbeMultiLoad(p: PVdbe; iDest: i32; zTypes: PAnsiChar);
function  sqlite3VdbeAddFunctionCall(pParse: PParse; p1: i32; p2, p3: i32;
                                    nArg: i32; pFunc: PFuncDef; p5: i32): i32;
function  sqlite3VdbeExplainParent(pParse: PParse): i32;
procedure sqlite3ExplainBreakpoint(z1, z2: PAnsiChar);
function  sqlite3VdbeExplain(pParse: PParse; bPush: u8; zFmt: PAnsiChar): i32;
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
procedure sqlite3VdbeScanStatusRange(p: PVdbe; iScan, addrA, addrB: i32);
procedure sqlite3VdbeScanStatusCounters(p: PVdbe; iScan, iScan2: i32; iLip: i32);
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
function  sqlite3VdbeNextOpcode(p: PVdbe; pSub: PSubProgram; eType: i32;
                                piSub: Pi32; piAddr: Pi32): PVdbeOp;
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
function  sqlite3_get_auxdata(pCtx: Psqlite3_context; iArg: i32): Pointer;
procedure sqlite3_set_auxdata(pCtx: Psqlite3_context; iArg: i32;
                              pAux: Pointer; xDelete: TxDelProc);

{ --- vdbeapi.c — additional context API (Phase 6.8.h.1) --- }
function  sqlite3_user_data(pCtx: Psqlite3_context): Pointer;
procedure sqlite3_result_subtype(pCtx: Psqlite3_context; eSubtype: u32);
procedure sqlite3_result_text64(pCtx: Psqlite3_context; z: PAnsiChar;
                                n: u64; xDel: TxDelProc; enc: u8);
function  sqlite3VdbeFinishMoveto(p: PVdbeCursor): i32;
function  sqlite3VdbeHandleMovedCursor(p: PVdbeCursor): i32;
function  sqlite3VdbeCursorRestore(p: PVdbeCursor): i32;

{ --- Serial type helpers (vdbeaux.c) --- }
function  sqlite3VdbeSerialType(pMem: PMem; file_format: i32; pLen: Pu32): u32;
function  sqlite3VdbeSerialTypeLen(serialType: u32): u32;
function  sqlite3VdbeOneByteSerialTypeLen(serialType: u8): u8;
function  sqlite3VdbeSerialPut(buf: Pu8; pMem: PMem; serial_type: u32): u32;
procedure sqlite3VdbeSerialGet(buf: Pu8; serialType: u32; pMem: PMem);
function  sqlite3VdbeRecordUnpack(pKeyInfo: PKeyInfo; nKey: i32; pKey: Pointer;
                                  p: Pointer): Pointer; { returns UnpackedRecord* }
function  sqlite3VdbeAllocUnpackedRecord(pKeyInfo: PKeyInfo): Pointer;
function  sqlite3VdbeRecordCompareWithSkip(nKey1: i32; pKey1: Pointer;
                                           pPKey2: Pointer; bSkip: i32): i32;
function  sqlite3VdbeRecordCompare(nKey1: i32; pKey1: Pointer;
                                   pPKey2: Pointer): i32;
function  sqlite3VdbeFindCompare(pKey: Pointer): Pointer; { returns RecordCompare fn }

{ Opcode name lookup (vdbeaux.c, used for EXPLAIN) }
function  sqlite3OpcodeName(n: i32): PAnsiChar;

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
var
  gUnlinkAndDeleteTable:   TUnlinkAndDeleteFn;
  gUnlinkAndDeleteIndex:   TUnlinkAndDeleteFn;
  gUnlinkAndDeleteTrigger: TUnlinkAndDeleteFn;
  gRootPageMoved:          TRootPageMovedFn;
procedure sqlite3ResetAllSchemasOfConnection(db: PTsqlite3);
function  sqlite3SchemaMutexHeld(db: PTsqlite3; iDb: i32; pSchema: Pointer): i32;
procedure sqlite3CloseSavepoints(pDb: PTsqlite3);
procedure sqlite3RollbackAll(pDb: PTsqlite3; tripCode: i32);
function  sqlite3LogEst(n: u64): i16;
function  sqlite3LogEstAdd(a: i16; b: i16): i16;

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
function sqlite3_value_blob(pVal: Psqlite3_value): Pointer;
function sqlite3_value_bytes(pVal: Psqlite3_value): i32;
function sqlite3_value_subtype(pVal: Psqlite3_value): u32;
function sqlite3_value_dup(pOrig: Psqlite3_value): Psqlite3_value;
procedure sqlite3_value_free(pOld: Psqlite3_value);
function sqlite3_value_nochange(pVal: Psqlite3_value): i32;
function sqlite3_value_frombind(pVal: Psqlite3_value): i32;

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
function sqlite3_column_value(pStmt: PVdbe; i: i32): Psqlite3_value;
function sqlite3_column_name(pStmt: PVdbe; N: i32): PAnsiChar;

{ sqlite3_bind_* }
function sqlite3_bind_int(pStmt: PVdbe; i: i32; iVal: i32): i32;
function sqlite3_bind_int64(pStmt: PVdbe; i: i32; iVal: i64): i32;
function sqlite3_bind_double(pStmt: PVdbe; i: i32; rVal: Double): i32;
function sqlite3_bind_null(pStmt: PVdbe; i: i32): i32;
function sqlite3_bind_text(pStmt: PVdbe; i: i32; zData: PAnsiChar;
                           nData: i32; xDel: TxDelProc): i32;
function sqlite3_bind_blob(pStmt: PVdbe; i: i32; zData: Pointer;
                           nData: i32; xDel: TxDelProc): i32;
function sqlite3_bind_value(pStmt: PVdbe; i: i32;
                            pValue: Psqlite3_value): i32;
function sqlite3_bind_parameter_count(pStmt: PVdbe): i32;

{ --- vdbeapi.c — sqlite3_result_* context-result setters (Phase 6.6) --- }
procedure sqlite3_result_null(pCtx: Psqlite3_context);
procedure sqlite3_result_int(pCtx: Psqlite3_context; iVal: i32);
procedure sqlite3_result_int64(pCtx: Psqlite3_context; iVal: i64);
procedure sqlite3_result_double(pCtx: Psqlite3_context; rVal: Double);
procedure sqlite3_result_text(pCtx: Psqlite3_context; z: PAnsiChar;
  n: i32; xDel: TxDelProc);
procedure sqlite3_result_blob(pCtx: Psqlite3_context; z: Pointer;
  n: i32; xDel: TxDelProc);
procedure sqlite3_result_value(pCtx: Psqlite3_context; pVal: Psqlite3_value);
procedure sqlite3_result_error(pCtx: Psqlite3_context; z: PAnsiChar; n: i32);
procedure sqlite3_result_error_nomem(pCtx: Psqlite3_context);
procedure sqlite3_result_error_toobig(pCtx: Psqlite3_context);
function  sqlite3_result_zeroblob64(pCtx: Psqlite3_context; n: u64): i32;
function  sqlite3_aggregate_context(pCtx: Psqlite3_context;
  nByte: i32): Pointer;

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
                                  zWhere: PAnsiChar; p5: u16): i32;
var
  vdbeParseSchemaExec: TVdbeParseSchemaExec = nil;

{ --- vdbe.c Phase 5.4b helpers (exported for testing) --- }
function  sqlite3IntFloatCompare(i: i64; r: Double): i32;

implementation

uses
  passqlite3vtab;  { Phase 6.bis.3a: VTable + sqlite3VtabBegin/CallCreate/CallDestroy/ImportErrmsg
                     — implementation-only to break the interface-side cycle (vtab uses vdbe). }

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

procedure sqlite3VdbeSerialGet(buf: Pu8; serialType: u32; pMem: PMem);
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

function sqlite3VdbeAllocUnpackedRecord(pKeyInfo: PKeyInfo): Pointer;
begin
  Result := nil;
end;

function sqlite3VdbeRecordUnpack(pKeyInfo: PKeyInfo; nKey: i32; pKey: Pointer;
                                 p: Pointer): Pointer;
begin
  Result := nil;
end;

function sqlite3VdbeRecordCompareWithSkip(nKey1: i32; pKey1: Pointer;
                                          pPKey2: Pointer; bSkip: i32): i32;
begin
  Result := 0;
end;

function sqlite3VdbeRecordCompare(nKey1: i32; pKey1: Pointer;
                                  pPKey2: Pointer): i32;
begin
  Result := 0;
end;

function sqlite3VdbeFindCompare(pKey: Pointer): Pointer;
begin
  Result := nil;
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

procedure sqlite3VdbeMultiLoad(p: PVdbe; iDest: i32; zTypes: PAnsiChar);
begin
  { Stub — full implementation requires va_list support (Phase 6) }
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
  { Note: ChangeP5(nArg) elided — current libsqlite3 (matches the EXPLAIN
    oracle) does not write P5 for OP_Function/OP_PureFunc; argc is read
    from pCtx^.argc at runtime, not pOp^.p5.  Setting P5 introduces a
    spurious bytecode-diff against the oracle. }
  Result := addr;
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
    Inc(pOut);
    Inc(pSrc);
  end;
  p^.nOp := p^.nOp + nOp;
  Result := pFirst;
end;

{ --- Scan status (stubs — SQLITE_ENABLE_STMT_SCANSTATUS not enabled) --- }

procedure sqlite3VdbeScanStatus(p: PVdbe; addrExplain, addrLoop, addrVisit: i32;
                                nEst: LogEst; zName: PAnsiChar);
begin
end;

procedure sqlite3VdbeScanStatusRange(p: PVdbe; iScan, addrA, addrB: i32);
begin
end;

procedure sqlite3VdbeScanStatusCounters(p: PVdbe; iScan, iScan2: i32; iLip: i32);
begin
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
      { SubrtnSig has zAff heap string — defer to Phase 6 }
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
    if pOp^.p4type <= P4_FREE_IF_LE then
      freeP4(db, pOp^.p4type, pOp^.p4.p);
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
  { Stub — requires Phase 6 (KeyInfo / Index) }
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
begin
  Result := 0;
end;

procedure sqlite3ExplainBreakpoint(z1, z2: PAnsiChar);
begin
end;

function sqlite3VdbeExplain(pParse: PParse; bPush: u8; zFmt: PAnsiChar): i32;
begin
  Result := 0;
end;

procedure sqlite3VdbeExplainPop(pParse: PParse);
begin
end;

{ --- ParseSchema and EndCoroutine --- }

procedure sqlite3VdbeAddParseSchemaOp(p: PVdbe; iDb: i32; zWhere: PAnsiChar; p5: u16);
begin
  sqlite3VdbeAddOp4(p, OP_ParseSchema, iDb, 0, 0, zWhere, P4_DYNAMIC);
  sqlite3VdbeChangeP5(p, p5);
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

{ --- Display helpers (stubs — full implementation Phase 5.8 vdbetrace.c) --- }

function sqlite3VdbeDisplayComment(db: Psqlite3; pOp: PVdbeOp; zP4: PAnsiChar): PAnsiChar;
begin
  Result := nil;
end;

function sqlite3VdbeDisplayP4(db: Psqlite3; pOp: PVdbeOp): PAnsiChar;
begin
  Result := nil;
end;

procedure sqlite3VdbeUsesBtree(p: PVdbe; i: i32);
begin
  p^.btreeMask := p^.btreeMask or (yDbMask(1) shl i);
end;

procedure sqlite3VdbeEnter(p: PVdbe);
begin
  { mutex acquisition — stub for Phase 5.2; full in Phase 8 }
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
begin
  { Stub — Phase 5.4 }
end;

function sqlite3VdbeNextOpcode(p: PVdbe; pSub: PSubProgram; eType: i32;
                               piSub: Pi32; piAddr: Pi32): PVdbeOp;
begin
  { Stub — Phase 5.8 vdbetrace.c }
  Result := nil;
end;

procedure sqlite3VdbeFrameDelete(p: PVdbeFrame);
begin
  sqlite3DbFree(p^.v^.db, p);
end;

function sqlite3VdbeFrameRestore(pFrame: PVdbeFrame): i32;
begin
  { Stub — Phase 5.4 }
  Result := 0;
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
    nTab @56 (i32), nMem @60 (i32), nVar @296 (i16). }
  nCursor := PInt32(PByte(pParse) + 56)^;
  nMem    := PInt32(PByte(pParse) + 60)^;
  nVar    := i32(PWord(PByte(pParse) + 296)^);
  nArg    := 0;

  n := vdbeParseSzOpAllocPtr(pParse)^;
  resolveP2Values(p, @nArg);

  p^.vdbeFlags := p^.vdbeFlags and not (VDBF_UsesStmtJournal or VDBF_EXPIRED_MASK);

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
  if (not vdbeDbMallocFailed(db)) and (nMem > 0) then begin
    p^.aMem := PMem(sqlite3DbMallocZero(db,
                                       u64(nMem + 1) * SizeOf(TMem)));
    p^.nMem := nMem;
  end;
  if (not vdbeDbMallocFailed(db)) and (nCursor > 0) then begin
    p^.apCsr := PPVdbeCursor(sqlite3DbMallocZero(db,
                             u64(nCursor) * SizeOf(PVdbeCursor)));
    p^.nCursor := nCursor;
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

procedure sqlite3VdbeSetNumCols(p: PVdbe; nResColumn: i32);
begin
  p^.nResColumn := u16(nResColumn);
end;

function sqlite3VdbeSetColName(p: PVdbe; idx, var2: i32; zName: PAnsiChar;
                               xDel: TxDelProc): i32;
begin
  { Stub — Phase 5.5 (vdbeapi.c sqlite3_column_name) }
  Result := SQLITE_OK;
end;

{ --- Statement close --- }

function sqlite3VdbeCloseStatement(p: PVdbe; eOp: i32): i32;
begin
  { Stub — Phase 5.4 (complex transaction savepoint logic) }
  Result := SQLITE_OK;
end;

function sqlite3VdbeCheckFkImmediate(p: PVdbe): i32;
begin
  Result := 0;
end;

function sqlite3VdbeCheckFkDeferred(p: PVdbe): i32;
begin
  Result := 0;
end;

{ --- VdbeList — EXPLAIN output (stub; Phase 5.8 vdbetrace.c) --- }

function sqlite3VdbeList(v: PVdbe): i32;
begin
  Result := SQLITE_DONE;
end;

procedure sqlite3VdbePrintSql(p: PVdbe);
begin
end;

procedure sqlite3VdbeIOTraceSql(p: PVdbe);
begin
end;

{ --- VdbeHalt, VdbeReset, VdbeFinalize (Phase 5.4 stubs) --- }

function sqlite3VdbeHalt(v: PVdbe): i32;
var
  i:  i32;
  pC: PVdbeCursor;
begin
  { Full implementation (transaction commit/rollback bookkeeping) is in
    vdbeaux.c Phase 5.4.  closeAllCursors-equivalent loop wired here so
    cursors (in particular CURTYPE_VTAB cursors) do not leak across
    sqlite3_step → sqlite3_finalize.  Mirrors closeCursorsInFrame
    (vdbeaux.c:2796) inlined the same way it is in sqlite3VdbeFrameRestoreFull. }
  if (v <> nil) and (v^.apCsr <> nil) then begin
    for i := 0 to v^.nCursor - 1 do begin
      pC := v^.apCsr[i];
      if pC <> nil then begin
        sqlite3VdbeFreeCursorNN(v, pC);
        v^.apCsr[i] := nil;
      end;
    end;
  end;
  v^.eVdbeState := VDBE_HALT_STATE;
  Result := SQLITE_OK;
end;

procedure sqlite3VdbeResetStepResult(p: PVdbe);
begin
  p^.rc := SQLITE_OK;
end;

function sqlite3VdbeTransferError(p: PVdbe): i32;
begin
  Result := p^.rc;
end;

function sqlite3VdbeReset(p: PVdbe): i32;
begin
  if p = nil then begin Result := SQLITE_OK; Exit; end;
  if p^.eVdbeState = VDBE_RUN_STATE then
    sqlite3VdbeHalt(p);
  p^.eVdbeState := VDBE_READY_STATE;
  Result := p^.rc;
end;

function sqlite3VdbeFinalize(p: PVdbe): i32;
var
  rc: i32;
begin
  if p = nil then begin Result := SQLITE_OK; Exit; end;
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
      if Assigned(xDelete) then xDelete(pAux);
      if pCtx^.isError = 0 then pCtx^.isError := SQLITE_NOMEM;
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
  sqlite3VdbeMemSetStr(pCtx^.pOut, z, i64(n), enc, xDel);
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
  pSub:  PSubProgram;
  pNext: PSubProgram;
  i:     i32;
begin
  { Free sub-programs }
  pSub := p^.pProgram;
  while pSub <> nil do begin
    pNext := pSub^.pNext;
    vdbeFreeOpArray(db, pSub^.aOp, pSub^.nOp);
    sqlite3DbFree(db, pSub^.aOnce);
    sqlite3DbFree(db, pSub);
    pSub := pNext;
  end;
  { Free op array }
  vdbeFreeOpArray(db, p^.aOp, p^.nOp);
  { Free col names }
  if p^.aColName <> nil then
    sqlite3DbFree(db, p^.aColName);
  { Free aMem registers }
  if p^.aMem <> nil then begin
    for i := 0 to p^.nMem - 1 do begin
      if (p^.aMem[i].flags and (MEM_Dyn or MEM_Agg)) <> 0 then
        sqlite3VdbeMemRelease(@p^.aMem[i]);
    end;
  end;
  if p^.pFree <> nil then
    sqlite3DbFree(db, p^.pFree);
  sqlite3DbFree(db, p^.zErrMsg);
  sqlite3DbFree(db, p^.zSql);
  sqlite3VdbeDeleteAuxData(db, @p^.pAuxData, -1, 0);
end;

procedure sqlite3VdbeDelete(p: PVdbe);
var
  db: Psqlite3db;
begin
  if p = nil then Exit;
  db := p^.db;
  sqlite3VdbeClearObject(db, p);
  { Unlink from db->pVdbe list }
  if p^.ppVPrev <> nil then
    p^.ppVPrev^ := p^.pVNext;
  if p^.pVNext <> nil then
    p^.pVNext^.ppVPrev := p^.ppVPrev;
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

function sqlite3_value_blob(pVal: Psqlite3_value): Pointer;
begin
  if pVal = nil then begin Result := nil; Exit; end;
  if (pVal^.flags and (MEM_Blob or MEM_Str)) <> 0 then begin
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

function sqlite3_value_subtype(pVal: Psqlite3_value): u32;
begin
  if (pVal^.flags and MEM_Subtype) <> 0 then Result := pVal^.eSubtype
  else Result := 0;
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

function sqlite3_column_name(pStmt: PVdbe; N: i32): PAnsiChar;
begin
  if (pStmt = nil) or (N < 0) or (N >= pStmt^.nResColumn) then begin
    Result := nil; Exit;
  end;
  if pStmt^.aColName = nil then begin Result := nil; Exit; end;
  Result := PAnsiChar(sqlite3ValueText(
    pStmt^.aColName + N, SQLITE_UTF8));
end;

{ --- vdbeUnbind helper (vdbeapi.c:1654) --- }

function vdbeUnbind55(p: PVdbe; i: u32): i32;
var
  pVar: PMem;
begin
  if p = nil then begin Result := SQLITE_MISUSE; Exit; end;
  if p^.eVdbeState <> VDBE_READY_STATE then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  if i >= u32(p^.nVar) then begin
    Result := SQLITE_RANGE; Exit;
  end;
  pVar := p^.aVar + i;
  sqlite3VdbeMemRelease(pVar);
  pVar^.flags := MEM_Null;
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

function sqlite3_bind_value(pStmt: PVdbe; i: i32;
                            pValue: Psqlite3_value): i32;
begin
  case sqlite3_value_type(pValue) of
    SQLITE_INTEGER: Result := sqlite3_bind_int64(pStmt, i, pValue^.u.i);
    SQLITE_FLOAT:   Result := sqlite3_bind_double(pStmt, i, pValue^.u.r);
    SQLITE_TEXT:    Result := sqlite3_bind_text(pStmt, i,
                                pValue^.z, pValue^.n, SQLITE_TRANSIENT);
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

{ --- sqlite3_step / sqlite3_reset / sqlite3_finalize (vdbeapi.c:771) --- }

function sqlite3_step(pStmt: PVdbe): i32;
var
  rc: i32;
  db: PTsqlite3;
begin
  if pStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  db := pStmt^.db;

  { Auto-reset if in HALT state (vdbeapi.c:846) }
  if pStmt^.eVdbeState = VDBE_HALT_STATE then begin
    sqlite3VdbeReset(pStmt);
  end;

  { Transition READY → RUN }
  if pStmt^.eVdbeState = VDBE_READY_STATE then begin
    if db <> nil then Inc(db^.nVdbeActive);
    pStmt^.pc := 0;
    pStmt^.eVdbeState := VDBE_RUN_STATE;
  end;

  rc := sqlite3VdbeExec(pStmt);

  if rc = SQLITE_ROW then begin
    if db <> nil then db^.errCode := SQLITE_ROW;
    Result := SQLITE_ROW; Exit;
  end;

  pStmt^.pResultRow := nil;
  if db <> nil then begin
    db^.errCode := rc;
    Dec(db^.nVdbeActive);
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

procedure sqlite3_result_text(pCtx: Psqlite3_context; z: PAnsiChar;
  n: i32; xDel: TxDelProc);
begin
  if pCtx = nil then Exit;
  sqlite3VdbeMemSetStr(pCtx^.pOut, z, n, SQLITE_UTF8, xDel);
end;

procedure sqlite3_result_blob(pCtx: Psqlite3_context; z: Pointer;
  n: i32; xDel: TxDelProc);
begin
  if pCtx = nil then Exit;
  sqlite3VdbeMemSetStr(pCtx^.pOut, z, n, 0, xDel);
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

function sqlite3_aggregate_context(pCtx: Psqlite3_context;
  nByte: i32): Pointer;
var
  pAggMem: PMem;
begin
  if pCtx = nil then begin Result := nil; Exit; end;
  pAggMem := pCtx^.pMem;
  if (pAggMem^.flags and MEM_Agg) = 0 then begin
    if nByte = 0 then begin Result := nil; Exit; end;
    sqlite3VdbeMemClearAndResize(pAggMem, nByte);
    if pAggMem^.szMalloc > 0 then begin
      FillChar(pAggMem^.z^, nByte, 0);
      pAggMem^.flags := MEM_Agg or MEM_Dyn;
    end else begin
      sqlite3OomFault(pAggMem^.db);
      Result := nil; Exit;
    end;
  end;
  Result := pAggMem^.z;
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
  { Stub: SQL compiler not yet available (Phase 7+). }
  ppBlob := nil;
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

function sqlite3_blob_read(pBlob: Psqlite3_blob; z: Pointer;
                           n: i32; iOffset: i32): i32;
begin
  if pBlob = nil then begin Result := SQLITE_MISUSE; Exit; end;
  if pBlob^.pStmt = nil then begin Result := SQLITE_ABORT; Exit; end;
  if (n < 0) or (iOffset < 0) or
     (i64(iOffset) + i64(n) > pBlob^.nByte) then begin
    Result := SQLITE_ERROR; Exit;
  end;
  { sqlite3BtreePayloadChecked not yet ported (Phase 5.7 / btree) }
  Result := SQLITE_ERROR;
end;

function sqlite3_blob_write(pBlob: Psqlite3_blob; z: Pointer;
                            n: i32; iOffset: i32): i32;
begin
  if pBlob = nil then begin Result := SQLITE_MISUSE; Exit; end;
  if pBlob^.pStmt = nil then begin Result := SQLITE_ABORT; Exit; end;
  if (n < 0) or (iOffset < 0) or
     (i64(iOffset) + i64(n) > pBlob^.nByte) then begin
    Result := SQLITE_ERROR; Exit;
  end;
  { sqlite3BtreePutData not yet ported (Phase 5.7 / btree) }
  Result := SQLITE_ERROR;
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
  { blobSeekToRow requires SQL compiler (Phase 7+) }
  Result := SQLITE_ERROR;
end;

{ ============================================================================
  Phase 5.8 — vdbetrace.c EXPLAIN SQL expander

  sqlite3VdbeExpandSql expands bound parameters in zRawSql for tracing.
  Full implementation requires sqlite3GetToken (Phase 7 tokenizer).
  This stub returns a heap-allocated copy of the raw SQL, which is correct
  when there are no bound parameters (nVar=0) and is a safe degraded result
  otherwise (the trace shows unexpanded SQL instead of crashing).
  ============================================================================ }

function sqlite3VdbeExpandSql(p: PVdbe; zRawSql: PAnsiChar): PAnsiChar;
var
  n:   i32;
  db:  PTsqlite3;
  z:   PAnsiChar;
begin
  if (p = nil) or (zRawSql = nil) then begin Result := nil; Exit; end;
  db := PTsqlite3(p^.db);
  n := sqlite3Strlen30(zRawSql);
  z := PAnsiChar(sqlite3DbMallocZero(db, n + 1));
  if z <> nil then
    Move(zRawSql^, z^, n);
  Result := z;
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
  Phase 5.7 — vdbesort.c external sorter stubs

  Full implementation requires KeyInfo/UnpackedRecord (Phase 6+) and the
  PmaReader / MergeEngine / SortSubtask subsystems. The public functions
  handle nil-guard and state-check behavior correctly; the actual sort logic
  is deferred until ORDER BY opcodes are active (Phase 6.bis onward).
  ============================================================================ }

function sqlite3VdbeSorterInit(db: PTsqlite3; nField: i32;
                               pCsr: PVdbeCursor): i32;
var
  pSorter: PVdbeSorter;
begin
  if pCsr = nil then begin Result := SQLITE_MISUSE; Exit; end;
  { Cannot sort without KeyInfo — Phase 6+ }
  if pCsr^.pKeyInfo = nil then begin Result := SQLITE_ERROR; Exit; end;
  pSorter := PVdbeSorter(sqlite3DbMallocZero(db, SizeOf(TVdbeSorter)));
  if pSorter = nil then begin Result := SQLITE_NOMEM; Exit; end;
  pSorter^.db       := db;
  pSorter^.pKeyInfo := pCsr^.pKeyInfo;
  pSorter^.nTask    := 1;
  pSorter^.pgsz     := 4096;
  pCsr^.uc.pSorter  := pSorter;
  Result := SQLITE_OK;
end;

procedure sqlite3VdbeSorterReset(db: PTsqlite3; pSorter: PVdbeSorter);
var
  pRec, pNext: Pointer;
begin
  if pSorter = nil then Exit;
  { Free in-memory record list if individually allocated (aMemory=nil) }
  if pSorter^.list.aMemory = nil then begin
    pRec := pSorter^.list.pList;
    while pRec <> nil do begin
      pNext := PPointer(pRec)^;  { SorterRecord.u.pNext at offset 0 }
      sqlite3DbFree(db, pRec);
      pRec := pNext;
    end;
  end else begin
    sqlite3DbFree(db, pSorter^.list.aMemory);
    pSorter^.list.aMemory := nil;
  end;
  pSorter^.list.pList := nil;
  pSorter^.list.szPMA := 0;
  pSorter^.bUsePMA    := 0;
end;

procedure sqlite3VdbeSorterClose(db: PTsqlite3; pCsr: PVdbeCursor);
var
  pSorter: PVdbeSorter;
begin
  if pCsr = nil then Exit;
  pSorter := pCsr^.uc.pSorter;
  if pSorter <> nil then begin
    sqlite3VdbeSorterReset(db, pSorter);
    sqlite3DbFree(db, pSorter);
    pCsr^.uc.pSorter := nil;
  end;
end;

function sqlite3VdbeSorterWrite(pCsr: PVdbeCursor; pVal: PMem): i32;
begin
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  { Full in-memory insertion requires UnpackedRecord (Phase 6+) }
  Result := SQLITE_ERROR;
end;

function sqlite3VdbeSorterRewind(pCsr: PVdbeCursor; out pbEof: i32): i32;
begin
  pbEof := 1;
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  { Rewind requires sort + PMA merge (Phase 6+) }
  Result := SQLITE_ERROR;
end;

function sqlite3VdbeSorterNext(db: PTsqlite3; pCsr: PVdbeCursor): i32;
begin
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  Result := SQLITE_DONE;
end;

function sqlite3VdbeSorterRowkey(pCsr: PVdbeCursor; pOut: PMem): i32;
begin
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  sqlite3VdbeMemSetNull(pOut);
  Result := SQLITE_ERROR;
end;

function sqlite3VdbeSorterCompare(pCsr: PVdbeCursor; bOmitRowid: i32;
                                  pKey: Pointer; nKey: i32;
                                  out pRes: i32): i32;
begin
  pRes := 0;
  if (pCsr = nil) or (pCsr^.uc.pSorter = nil) then begin
    Result := SQLITE_MISUSE; Exit;
  end;
  Result := SQLITE_ERROR;
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
begin
  case rc of
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
    SQLITE_ROW:      Result := 'another row available';
    SQLITE_DONE:     Result := 'no more rows available';
  else                Result := 'unknown error';
  end;
end;

procedure sqlite3VdbeLogAbort(p: PVdbe; rc: i32; pOp, aOp: Pointer);
begin
  { Stub — Phase 5.5 }
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
  { Stub — Phase 6 }
end;

{ Implement sqlite3VdbeFrameRestore properly (vdbeaux.c:2812) }
function sqlite3VdbeFrameRestoreFull(pFrame: PVdbeFrame): i32;
var
  v: PVdbe;
  i: i32;
  pC: PVdbeCursor;
begin
  v := pFrame^.v;
  { Close cursors in current frame }
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
  { db->lastRowid and db->nChange would need PTsqlite3 cast }
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
  sqlite3GetVarint32(Pu8(pMem.z), szHdr);
  if (szHdr < 3) or (szHdr > u32(pMem.n)) then begin
    sqlite3VdbeMemReleaseMalloc(@pMem);
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;
  typeRowid := 0;
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
  Port of vdbe.c:498 (computeNumericType + numericType). }
function numericType(pMem: PMem): u16;
var r: Double; iVal: i64;
begin
  if (pMem^.flags and (MEM_Int or MEM_Real or MEM_IntReal or MEM_Null)) <> 0 then begin
    Result := pMem^.flags and (MEM_Int or MEM_Real or MEM_IntReal or MEM_Null);
    Exit;
  end;
  { Str or Blob: try numeric parse (conservative — return MEM_Real on failure) }
  if sqlite3MemRealValueRC(pMem, r) <= 0 then begin
    if (sqlite3Atoi64(pMem^.z, iVal, pMem^.n, pMem^.enc) <= 1) then begin
      pMem^.u.i := iVal;
      Result := MEM_Int;
    end else begin
      pMem^.u.r := r;
      Result := MEM_Real;
    end;
  end else if (sqlite3Atoi64(pMem^.z, iVal, pMem^.n, pMem^.enc) = 0) then begin
    pMem^.u.i := iVal;
    Result := MEM_Int;
  end else begin
    pMem^.u.r := r;
    Result := MEM_Real;
  end;
end;

{ sqlite3BlobCompare — compare two blob/binary Mem values.
  Port of vdbeaux.c:4508. }
function sqlite3BlobCompare(pB1, pB2: PMem): i32;
var n1, n2, c, nMin: i32;
begin
  n1 := pB1^.n;
  n2 := pB2^.n;
  if ((pB1^.flags or pB2^.flags) and MEM_Zero) <> 0 then begin
    if (pB1^.flags and pB2^.flags and MEM_Zero) <> 0 then begin
      Result := pB1^.u.nZero - pB2^.u.nZero; Exit;
    end else if (pB1^.flags and MEM_Zero) <> 0 then begin
      Result := -1; Exit;  { simplified: treat MEM_Zero as less }
    end else begin
      Result := +1; Exit;
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
    { no collation support in this port — fall through to blob compare }
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
  sqlite3RollbackAll — roll back all btrees in db->aDb (vdbeaux.c)
  ============================================================================ }
procedure sqlite3RollbackAll(pDb: PTsqlite3; tripCode: i32);
var
  ii:  i32;
  pBt: PBtree;
begin
  for ii := 0 to pDb^.nDb - 1 do begin
    pBt := PBtree(pDb^.aDb[ii].pBt);
    if pBt <> nil then
      sqlite3BtreeRollback(pBt, tripCode, 0);
  end;
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
  { 5.4c locals — record I/O }
  pCol:    PVdbeCursor;   { OP_Column: cursor being read }
  p2col:   u32;           { OP_Column: column index }
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
  nSvptName5g: i32;           { OP_Savepoint: name length }
  iSvpt5g:     i32;           { OP_Savepoint: depth counter }
  isTxnSvpt5g: i32;           { OP_Savepoint: is this a transaction savepoint? }
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
  repeat
    Inc(nVmStep);

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
      pIn1 := @aMem[pOp^.p1];
      if (pIn1^.flags and MEM_Int) <> 0 then begin
        pOp := @aOp[pIn1^.u.i];
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
            { TODO Phase 5.5: append pOp^.p4.z suffix via sqlite3MPrintf }
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
    end;

    { ────── OP_String8 / OP_String ────── (vdbe.c:1414/1458)
      P4.z = string literal, P1 = byte length, P2 = output register, enc = P4 enc.
      OP_String8 converts itself to OP_String on first execution. }
    OP_String8: begin
      pOp^.p1 := sqlite3Strlen30(PChar(pOp^.p4.z));
      if pOp^.p1 > db^.aLimit[0] { SQLITE_LIMIT_LENGTH } then goto too_big;
      pOp^.opcode := OP_String;
      { fall through to OP_String }
      pOut := out2Prerelease(v, pOp);
      pOut^.flags := MEM_Str or MEM_Static or MEM_Term;
      pOut^.z     := pOp^.p4.z;
      pOut^.n     := pOp^.p1;
      pOut^.enc   := enc;
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
        pOut^.flags := (pOut^.flags and not u16(MEM_TypeMask or MEM_Zero)) or (pOut^.flags and MEM_TypeMask);
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
      v^.pResultRow := @aMem[pOp^.p1];
      v^.nResColumn := u16(pOp^.p2);
      if db^.mallocFailed <> 0 then goto no_mem;
      v^.pc := i32(pOp - aOp) + 1;  { save resume point for next call }
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
        rc := SQLITE_ABORT or (1 shl 8);  { SQLITE_ABORT_ROLLBACK }
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

    { ────── OP_Init ────── (vdbe.c:9046) }
    OP_Init: begin
      i := 1;
      if pOp^.p1 >= sqlite3GlobalConfig.iOnceResetThreshold then begin
        if pOp^.opcode = OP_Trace then begin { break equivalent — handled below }
        end else begin
          while i < v^.nOp do begin
            if aOp[i].opcode = OP_Once then aOp[i].p1 := 0;
            Inc(i);
          end;
          pOp^.p1 := 0;
        end;
      end;
      Inc(pOp^.p1);
      Inc(v^.aCounter[SQLITE_STMTSTATUS_RUN]);
      goto jump_to_p2;
    end;

    { ────── OP_Column ────── (vdbe.c:2975) }
    OP_Column: begin
      pCol   := v^.apCsr[pOp^.p1];
      p2col  := u32(pOp^.p2);
      aOffset := Pu32(Pu8(pCol) + 120 + u32(pCol^.nField) * SizeOf(u32));
      { aOffset = pCol->aType + pCol->nField }

      op_column_restart:
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
      { UPDATE_MAX_BLOBSIZE — update db->szMalloc watermark (skip for now) }
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
    end;

    { ────── OP_Delete ────── (vdbe.c:5903) }
    OP_Delete: begin
      opflags := pOp^.p2;
      pCur := v^.apCsr[pOp^.p1];
      sqlite3VdbeIncrWriteCounter(v, pCur);
      rc := sqlite3BtreeDelete(pCur^.uc.pCursor, u8(pOp^.p5));
      pCur^.cacheStatus := CACHE_STALE;
      Inc(colCacheCtr);
      pCur^.seekResult := 0;
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if (opflags and OPFLAG_NCHANGE) <> 0 then
        Inc(v^.nChange);
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
      rc := sqlite3BtreeIndexMoveto(pCrsr, @rSeek, @res);
      if rc <> SQLITE_OK then goto abort_due_to_error;
      if res = 0 then begin
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
        rc := pCtxAgg^.isError;
        pCtxAgg^.isError := 0;
        sqlite3VdbeMemRelease(pCtxAgg^.pOut);
        pCtxAgg^.pOut^.flags := MEM_Null;
        if rc <> 0 then goto abort_due_to_error;
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
          sqlite3VdbeError(v, 'aggregate finalize error');
          goto abort_due_to_error;
        end;
      end;
      rc := sqlite3VdbeChangeEncoding(@aMem[pOp^.p1], enc);
      if rc <> SQLITE_OK then goto abort_due_to_error;
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
        { NULL — execute halt logic }
        if pOp^.p1 <> 0 then begin
          { error halt }
          v^.pc := i32(pOp - aOp);
          v^.rc := pOp^.p1;
          if pOp^.p4.z <> nil then
            sqlite3VdbeError(v, pOp^.p4.z);
          if v^.eVdbeState = VDBE_RUN_STATE then sqlite3VdbeHalt(v);
          rc := pOp^.p1;
          goto vdbe_return;
        end else begin
          v^.pc := i32(pOp - aOp);
          if v^.eVdbeState = VDBE_RUN_STATE then sqlite3VdbeHalt(v);
          rc := SQLITE_DONE;
          goto vdbe_return;
        end;
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
        rc := pCtxAgg^.isError;
        pCtxAgg^.isError := 0;
        if rc <> 0 then goto abort_due_to_error;
      end;
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
          { Schema cookie check — only when p5≠0 and schema is fully ported }
          { Skipped for now: pDb->pSchema->iGeneration not yet accessible }
        end;
      end;
    end;

    { ────── OP_Savepoint ────── (vdbe.c:3823)
      P1=SAVEPOINT_BEGIN(0)/RELEASE(1)/ROLLBACK(2), P4.z=name }
    OP_Savepoint: begin
      zSvptName5g := pOp^.p4.z;
      if pOp^.p1 = SAVEPOINT_BEGIN then begin
        nSvptName5g := sqlite3Strlen30(PChar(zSvptName5g));
        pNewSvpt5g := PSavepoint(
          sqlite3DbMallocRawNN(db, SizeOf(TSavepoint) + nSvptName5g + 1));
        if pNewSvpt5g = nil then goto no_mem;
        pNewSvpt5g^.zName := PAnsiChar(PByte(pNewSvpt5g) + SizeOf(TSavepoint));
        Move(zSvptName5g^, pNewSvpt5g^.zName^, nSvptName5g + 1);
        if db^.autoCommit <> 0 then begin
          db^.autoCommit              := 0;
          db^.isTransactionSavepoint  := 1;
        end else
          Inc(db^.nSavepoint);
        pNewSvpt5g^.pNext           := db^.pSavepoint;
        db^.pSavepoint              := pNewSvpt5g;
        pNewSvpt5g^.nDeferredCons   := db^.nDeferredCons;
        pNewSvpt5g^.nDeferredImmCons := db^.nDeferredImmCons;
      end else begin
        { RELEASE or ROLLBACK: find named savepoint }
        iSvpt5g := 0;
        pSvpt5g := db^.pSavepoint;
        while (pSvpt5g <> nil) and
              (sqlite3StrICmp(PChar(pSvpt5g^.zName), PChar(zSvptName5g)) <> 0) do begin
          Inc(iSvpt5g);
          pSvpt5g := pSvpt5g^.pNext;
        end;
        if pSvpt5g = nil then begin
          sqlite3VdbeError(v, 'no such savepoint');
          rc := SQLITE_ERROR;
          goto abort_due_to_error;
        end;
        isTxnSvpt5g := ord((pSvpt5g^.pNext = nil) and (db^.isTransactionSavepoint <> 0));
        if (isTxnSvpt5g <> 0) and (pOp^.p1 = SAVEPOINT_RELEASE) then begin
          { Release of transaction savepoint: commit }
          db^.autoCommit := 1;
          if sqlite3VdbeHalt(v) = SQLITE_BUSY then begin
            v^.pc := i32(pOp - aOp);
            db^.autoCommit := 0;
            v^.rc := SQLITE_BUSY;
            goto vdbe_return;
          end;
          sqlite3CloseSavepoints(db);
          rc := SQLITE_DONE;
          goto vdbe_return;
        end else begin
          { Pop savepoints down to and including pSvpt5g }
          while db^.pSavepoint <> pSvpt5g do begin
            pNewSvpt5g := db^.pSavepoint;
            db^.pSavepoint := pNewSvpt5g^.pNext;
            sqlite3DbFree(db, pNewSvpt5g);
            Dec(db^.nSavepoint);
          end;
          if pOp^.p1 = SAVEPOINT_RELEASE then begin
            { pop the named savepoint too }
            db^.pSavepoint := pSvpt5g^.pNext;
            sqlite3DbFree(db, pSvpt5g);
            Dec(db^.nSavepoint);
          end else begin
            { ROLLBACK: restore deferred cons, rollback btrees to this savepoint }
            db^.nDeferredCons    := pSvpt5g^.nDeferredCons;
            db^.nDeferredImmCons := pSvpt5g^.nDeferredImmCons;
          end;
        end;
      end;
    end;

    { ────── OP_AutoCommit ────── (vdbe.c:4013)
      P1=desiredAutoCommit(1=commit,0=begin), P2=rollback flag }
    OP_AutoCommit: begin
      desiredAC5g := pOp^.p1;
      iRollback5g := pOp^.p2;
      if desiredAC5g <> i32(db^.autoCommit) then begin
        if iRollback5g <> 0 then begin
          sqlite3RollbackAll(db, SQLITE_ABORT_ROLLBACK);
          db^.autoCommit := 1;
        end else begin
          db^.autoCommit := u8(desiredAC5g);
        end;
        sqlite3VdbeHalt(v);
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
          { Rowid table: use the auto-created table at SCHEMA_ROOT+1 }
          rc := sqlite3BtreeCursor(pCur^.ub.pBtx, SCHEMA_ROOT + 1,
                                   BTREE_WRCSR, nil, pCur^.uc.pCursor);
          pCur^.isTable := 1;
        end;
      end;
      if rc <> SQLITE_OK then goto abort_due_to_error;
      pCur^.pgnoRoot := pCur^.uc.pCursor^.pgnoRoot;
    end;

    { ────── OP_OpenPseudo ────── (vdbe.c:4590) }
    { Open a new cursor P1 backed by the register P3 (which holds a serialised
      row).  P2 is the number of fields.  When P3 is non-zero the cursor is an
      index-format pseudo-cursor (isTable=0); when P3 is zero it is a rowid
      pseudo-cursor (isTable=1).
      Pascal note: seekResult stores P3 (the register index) so that
      OP_Column can read the row with  pRegCol := @aMem[pCx^.seekResult]. }
    OP_OpenPseudo: begin
      pCur := allocateCursor(v, pOp^.p1, pOp^.p2, CURTYPE_PSEUDO);
      if pCur = nil then goto no_mem;
      pCur^.nullRow    := 1;
      pCur^.seekResult := pOp^.p3;           { register holding the row }
      pCur^.isTable    := u8(ord(pOp^.p3 = 0));
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
      if pOp^.p3 = 0 then
        pDest^.flags := pDest^.flags and not MEM_Zero;
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
      { SeekScan is followed by SeekGE — use pOp[1] for the SeekGE info }
      pCur := v^.apCsr[pOp^.p1];
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
      pOut^.u.i := i64(idx);
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
        { OP_Destroy auto-vacuum: sqlite3RootPageMoved deferred to Phase 6 }
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
      end else if pOp^.p4.z = nil then begin
        { ALTER-branch (p4.z = NULL) — full sqlite3InitOne port lands in
          Phase 7.  For now treat as success so callers that emit this
          opcode shape (none, currently) don't trip an error. }
        rc := SQLITE_OK;
      end else begin
        rc := vdbeParseSchemaExec(db, pOp^.p1, pOp^.p4.z, pOp^.p5);
        if rc <> SQLITE_OK then begin
          sqlite3ResetAllSchemasOfConnection(db);
          if rc = SQLITE_NOMEM then goto no_mem;
          goto abort_due_to_error;
        end;
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

    { ────── OP_OffsetLimit ────── (vdbe.c:7740) }
    OP_OffsetLimit: begin
      pIn1  := @aMem[pOp^.p1];
      pIn3  := @aMem[pOp^.p3];
      pOut  := out2Prerelease(v, pOp);
      xLim  := pIn1^.u.i;
      if (xLim <= 0) or (sqlite3AddInt64(@xLim, pIn3^.u.i) <> 0) then
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

    { ────── OP_FkCheck ────── — stub (vdbe.c:~8120) }
    OP_FkCheck: begin
      { FK check requires Phase 6 schema/codegen }
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
          nProgMem := pProgSub^.nMem + pProgSub^.nCsr;
          if nProgMem = 0 then nProgMem := 1;
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
          { aOnce flags are stored just after the TVdbeFrame header in the alloc }
          pMemEnd := PMem(Pu8(pFrame) + ROUND8(SizeOf(TVdbeFrame)));
          pFrame^.aOnce := Pu8(pMemEnd) + nProgMem * SizeOf(TMem)
                         + u64(pProgSub^.nCsr) * SizeOf(PVdbeCursor);
          FillChar(pFrame^.aOnce^, (pProgSub^.nOp + 7) div 8, 0);
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

    { ────── OP_Checkpoint ────── }
    OP_Checkpoint, OP_Vacuum, OP_JournalMode: begin
      { Stub: WAL checkpoint / vacuum / journal mode change require Phase 6 infra }
      { For now return OK to avoid crashes during basic SQL testing }
      pOut := out2Prerelease(v, pOp);
      pOut^.u.i := 0;
    end;

    { ────── OP_SqlExec ────── (vdbe.c:7064) — stub }
    OP_SqlExec: begin
      { Stub: requires sqlite3_exec which needs Phase 6 }
    end;

    { ────── OP_IntegrityCk ────── — stub }
    OP_IntegrityCk: begin
      { Full integrity check deferred to Phase 6 }
      sqlite3VdbeMemSetNull(@aMem[pOp^.p1 + 1]);
    end;

    { ────── OP_IFindKey ────── — index find with key }
    OP_IFindKey: begin
      { Stub: deferred to Phase 6 (requires full index/key infrastructure) }
    end;

    { ────── OP_IncrVacuum ────── — stub }
    OP_IncrVacuum: begin
      goto jump_to_p2;
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
      { Stub: Bloom filter not yet ported (Phase 6) }
    end;
    OP_Filter: begin
      { Stub: no filter → never skip any row }
    end;

    { ────── OP_ColumnsUsed ────── — hint only, no-op }
    OP_ColumnsUsed: begin end;

    { ────── OP_Offset ────── (vdbe.c:2931) }
    OP_Offset: begin
      pCur := v^.apCsr[pOp^.p1];
      if (pCur = nil) or (pCur^.eCurType <> CURTYPE_BTREE) then
        sqlite3VdbeMemSetNull(@aMem[pOp^.p3])
      else begin
        sqlite3VdbeMemSetInt64(@aMem[pOp^.p3], 0);
        { Full B-tree offset computation deferred to Phase 6 }
      end;
    end;

    { ────── OP_TypeCheck ────── (vdbe.c:3305) — deferred }
    OP_TypeCheck: begin
      { Type checking requires table schema (Phase 6) }
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
    { use libc snprintf with %g formatting; SQLite uses its own %!.*g }
    libc_snprintf(zBuf, sz, '%.*g', nFp, p^.u.r);
    p^.n := sqlite3Strlen30(zBuf);
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

{ -----------------------------------------------------------------------
  sqlite3VdbeMemTranslate — UTF encoding conversion stub (Phase 2 note)
  Full port deferred to Phase 6 (needs Mem encoding fully wired).
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemTranslate(pMem: PMem; desiredEnc: u8): i32;
begin
  { Stub: if already the right encoding (or UTF8), no-op }
  if (pMem^.flags and MEM_Str) = 0 then begin
    Result := SQLITE_OK; Exit;
  end;
  if pMem^.enc = desiredEnc then begin
    Result := SQLITE_OK; Exit;
  end;
  { For now, we only support UTF-8; other conversions fail gracefully }
  Result := SQLITE_ERROR;
end;

function sqlite3VdbeMemHandleBom(pMem: PMem): i32;
begin
  { BOM handling stub — UTF-16 BOM stripping deferred to Phase 6 }
  Result := SQLITE_OK;
  if pMem = nil then Exit;
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
  sqlite3VdbeMemFinalize — call aggregate finalizer (stub: FuncDef not ported)
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
    pFd^.xFinalize(@ctx);
    if ctx.isError <> 0 then begin
      pMem^.flags := MEM_Null;
      Result := ctx.isError;
    end else begin
      sqlite3VdbeMemRelease(pMem);
      pMem^ := t;
      Result := SQLITE_OK;
    end;
  end else begin
    pMem^.flags := MEM_Null;
    Result := SQLITE_OK;
  end;
end;

{ -----------------------------------------------------------------------
  sqlite3VdbeMemAggValue — stub (window functions, Phase 6)
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
  sqlite3VdbeMemCast — cast value to affinity (stub for complex cases)
  ----------------------------------------------------------------------- }
function sqlite3VdbeMemCast(pMem: PMem; aff: u8; encoding: u8): i32;
begin
  if (pMem^.flags and MEM_Null) <> 0 then begin Result := SQLITE_OK; Exit; end;
  case aff of
    SQLITE_AFF_BLOB: begin
      if (pMem^.flags and MEM_Blob) = 0 then begin
        { attempt text conversion then mark as blob }
        sqlite3VdbeMemStringify(pMem, encoding, 0);
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
      pMem^.flags := pMem^.flags or ((pMem^.flags and MEM_Blob) shr 3);
      sqlite3VdbeMemStringify(pMem, encoding, 0);
      pMem^.flags := pMem^.flags and not u16(MEM_Int or MEM_Real or MEM_IntReal or MEM_Blob or MEM_Zero);
      if encoding <> SQLITE_UTF8 then pMem^.n := pMem^.n and not 1;
      sqlite3VdbeChangeEncoding(pMem, encoding);
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
    Result^.rsFlags := 0;
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
  pSet^.rsFlags := 0;
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

{ rowset.c internal: merge two sorted lists by v }
function rowSetEntryMerge(pA: PRowSetEntry; pB: PRowSetEntry): PRowSetEntry;
var
  head: TRowSetEntry;
  pTail: PRowSetEntry;
begin
  pTail := @head;
  while (pA <> nil) and (pB <> nil) do begin
    if pA^.v < pB^.v then begin
      pTail^.pRight := pA;
      pTail := pA;
      pA := pA^.pRight;
    end else begin
      pTail^.pRight := pB;
      pTail := pB;
      pB := pB^.pRight;
    end;
  end;
  if pA <> nil then pTail^.pRight := pA
  else             pTail^.pRight := pB;
  Result := head.pRight;
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

{ rowset.c internal: sort the pEntry list and add as BST to pForest }
procedure rowSetToList(pSet: PRowSet);
var
  pNext: PRowSetEntry;
  pHead: PRowSetEntry;
  pTail: PRowSetEntry;
  pNew:  PRowSetEntry;
  p:     PRowSetEntry;
begin
  { Step 1: reverse the pEntry list so it is sorted by rowid (insertion order) }
  { Actually they were appended; sort them with merge sort }
  { Simple insertion sort for small sets; use merge sort in production }
  { Here we sort pEntry list by v ascending using a merge sort }
  if pSet^.pEntry = nil then Exit;

  { Use bottom-up merge sort on pEntry list }
  pHead := pSet^.pEntry;
  pSet^.pEntry := nil;
  pSet^.pLast  := nil;
  while pHead <> nil do begin
    pNext := pHead^.pRight;
    pHead^.pRight := nil;
    pHead^.pLeft  := nil;
    { Add as BST to pForest (simplified: just prepend as tree of depth 1) }
    p := pSet^.pForest;
    pNew := rowSetListToTree(pHead);
    if p = nil then pSet^.pForest := pNew
    else begin
      { merge: find a tree with same depth or just put at front }
      pNew^.pRight := pSet^.pForest;
      pSet^.pForest := pNew;
    end;
    pHead := pNext;
  end;
end;

{ rowset.c internal: in-order traverse tree to sorted list }
procedure rowSetTreeToList(pIn: PRowSetEntry; ppFirst: PPRowSetEntry;
                           ppLast: PPRowSetEntry);
begin
  if pIn = nil then Exit;
  if pIn^.pLeft <> nil then begin
    rowSetTreeToList(pIn^.pLeft, ppFirst, ppLast);
    ppLast^^.pRight := pIn;
  end else
    ppFirst^ := pIn;
  pIn^.pLeft := nil;
  ppLast^ := pIn;
  if pIn^.pRight <> nil then
    rowSetTreeToList(pIn^.pRight, ppLast, ppLast)
  else
    pIn^.pRight := nil;
end;

{ rowset.c internal: merge all forest trees into one sorted list }
procedure rowSetSort(pSet: PRowSet);
var
  p:      PRowSetEntry;
  pList:  PRowSetEntry;
  pLast:  PRowSetEntry;
  pFst:   PRowSetEntry;
  pLst:   PRowSetEntry;
begin
  pList := nil;
  pLast := nil;
  p := pSet^.pForest;
  while p <> nil do begin
    pFst  := nil;
    pLst  := @pFst;
    rowSetTreeToList(p, @pFst, @pLst);
    pList := rowSetEntryMerge(pList, pFst);
    p := p^.pRight;
  end;
  pSet^.pForest := nil;
  pSet^.pEntry  := pList;
  pSet^.pLast   := nil;
  pSet^.rsFlags := pSet^.rsFlags or ROWSET_NEXT;
end;

{ rowset.c:sqlite3RowSetInsert }
procedure sqlite3RowSetInsert(pSet: PRowSet; rowid: i64);
var
  pEntry: PRowSetEntry;
begin
  pEntry := rowSetEntryAlloc(pSet);
  if pEntry = nil then Exit;
  pEntry^.v      := rowid;
  pEntry^.pRight := nil;
  pEntry^.pLeft  := nil;
  if pSet^.pLast = nil then
    pSet^.pEntry := pEntry
  else
    pSet^.pLast^.pRight := pEntry;
  pSet^.pLast := pEntry;
end;

{ rowset.c:sqlite3RowSetTest — return 1 if rowid exists in batch iBatch }
function sqlite3RowSetTest(pSet: PRowSet; iBatch: i32; rowid: i64): i32;
var
  pTree: PRowSetEntry;
  p:     PRowSetEntry;
begin
  { If batch changed, move pEntry list into the forest as a new tree }
  if iBatch <> pSet^.iBatch then begin
    if pSet^.pEntry <> nil then begin
      { Sort pEntry and add as BST to pForest }
      p := pSet^.pEntry;
      { For simplicity, add all entries as individual nodes to forest }
      while p <> nil do begin
        pTree := p^.pRight;
        p^.pLeft  := nil;
        p^.pRight := pSet^.pForest;
        pSet^.pForest := p;
        p := pTree;
      end;
      pSet^.pEntry := nil;
      pSet^.pLast  := nil;
    end;
    pSet^.iBatch := iBatch;
  end;
  { Search all trees in pForest }
  pTree := pSet^.pForest;
  while pTree <> nil do begin
    p := pTree;
    while p <> nil do begin
      if rowid < p^.v then p := p^.pLeft
      else if rowid > p^.v then p := p^.pRight
      else begin Result := 1; Exit; end;
    end;
    pTree := pTree^.pRight;
  end;
  { Also search unsorted pEntry list }
  p := pSet^.pEntry;
  while p <> nil do begin
    if p^.v = rowid then begin Result := 1; Exit; end;
    p := p^.pRight;
  end;
  Result := 0;
end;

{ rowset.c:sqlite3RowSetNext — extract smallest value, return 0 when empty }
function sqlite3RowSetNext(pSet: PRowSet; pRowid: Pi64): i32;
var
  p: PRowSetEntry;
begin
  { If NEXT mode not started, merge everything into a sorted list }
  if (pSet^.rsFlags and ROWSET_NEXT) = 0 then begin
    { Add pEntry unsorted list to forest }
    if pSet^.pEntry <> nil then begin
      p := pSet^.pEntry;
      while p <> nil do begin
        pSet^.pEntry := p^.pRight;
        p^.pLeft  := nil;
        p^.pRight := pSet^.pForest;
        pSet^.pForest := p;
        p := pSet^.pEntry;
      end;
      pSet^.pLast := nil;
    end;
    rowSetSort(pSet);
  end;
  if pSet^.pEntry = nil then begin
    Result := 0; Exit;
  end;
  pRowid^ := pSet^.pEntry^.v;
  pSet^.pEntry := pSet^.pEntry^.pRight;
  Result := 1;
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

procedure sqlite3ExpirePreparedStatements(db: PTsqlite3; iCode: i32);
begin
  { Stub — full implementation requires Phase 6 parser types }
end;

function sqlite3AnalysisLoad(db: PTsqlite3; iDb: i32): i32;
begin
  { Stub — full stat1 loading requires codegen (Phase 6) }
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
begin { Stub: FK trigger cache requires Phase 6 } end;

procedure sqlite3ResetAllSchemasOfConnection(db: PTsqlite3);
begin { Stub: schema reset requires Phase 6 } end;

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

{ -----------------------------------------------------------------------
  sqlite3ValueApplyAffinity — stub (affinity logic in codegen, Phase 6)
  ----------------------------------------------------------------------- }
procedure sqlite3ValueApplyAffinity(pVal: Psqlite3_value; aff: u8; enc: u8);
var
  p: PMem;
begin
  p := PMem(pVal);
  if p = nil then Exit;
  case aff of
    SQLITE_AFF_INTEGER:
      sqlite3VdbeMemIntegerify(p);
    SQLITE_AFF_REAL:
      sqlite3VdbeMemRealify(p);
    SQLITE_AFF_NUMERIC:
      sqlite3VdbeMemNumerify(p);
    SQLITE_AFF_TEXT:
      if (p^.flags and MEM_Null) = 0 then begin
        if (p^.flags and (MEM_Str or MEM_Blob)) = 0 then
          sqlite3VdbeMemStringify(p, enc, 0);
        p^.flags := p^.flags and not u16(MEM_Int or MEM_Real or MEM_IntReal);
      end;
    else { SQLITE_AFF_BLOB: no coercion }
      if (p^.flags and (MEM_Str or MEM_Int or MEM_Real or MEM_IntReal or MEM_Blob or MEM_Null)) = 0 then
        sqlite3VdbeMemStringify(p, enc, 0);
  end;
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
    if nAlloc < 32 then nAlloc := 32;
    if sqlite3VdbeMemClearAndResize(pMem, i32(nAlloc)) <> 0 then begin
      Result := SQLITE_NOMEM_BKPT; Exit;
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
  sqlite3ValueFromExpr — stub (Expr not yet ported, Phase 6)
  ----------------------------------------------------------------------- }
function sqlite3ValueFromExpr(db: Psqlite3; pExpr: Pointer;
                              enc: u8; affinity: u8;
                              out ppVal: Psqlite3_value): i32;
begin
  ppVal := nil;
  Result := SQLITE_OK;
end;

{ -----------------------------------------------------------------------
  sqlite3Stat4Column / sqlite3Stat4ProbeFree — STAT4 stubs (Phase 6)
  ----------------------------------------------------------------------- }
function sqlite3Stat4Column(db: Psqlite3; pRec: Pointer; nRec: i32;
                            iCol: i32; var ppVal: Psqlite3_value): i32;
var
  t:     u32;
  nHdr:  u32;
  iHdr:  u32;
  iFstield: i64;
  szField: u32;
  i:     i32;
  a:     Pu8;
  pM:    PMem;
begin
  t := 0; nHdr := 0; iHdr := 0; szField := 0;
  a := Pu8(pRec);
  pM := PMem(ppVal);
  iHdr := sqlite3GetVarint32(a, nHdr);
  if (nHdr > u32(nRec)) or (iHdr >= nHdr) then begin
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;
  iFstield := nHdr;
  for i := 0 to iCol do begin
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
end;

procedure sqlite3Stat4ProbeFree(pRec: Pointer);
begin
  { Stub: full implementation deferred to Phase 6 }
end;

initialization
  FillChar(gVdbeOpDummy, SizeOf(TVdbeOp), 0);
  SQLITE_DYNAMIC   := @sqlite3FreeXDel;
  SQLITE_TRANSIENT := TxDelProc(Pointer(-1));

end.
