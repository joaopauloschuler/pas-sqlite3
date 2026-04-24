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
  SQLITE_LIMIT_VDBE_OP = 5;  { max number of instructions in a VDBE program }

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

  PFuncDef  = Pointer;  { FuncDef  — Phase 6 (callback.c / func.c) }
  PCollSeq  = Pointer;  { CollSeq  — Phase 6 }
  PTable    = Pointer;  { Table    — Phase 6 (build.c) }
  PIndex    = Pointer;  { Index    — Phase 6 }
  PExpr     = Pointer;  { Expr     — Phase 6 (expr.c) }
  PParse    = Pointer;  { Parse    — Phase 7 (tokenize.c / parse.y) }
  PVList    = Pointer;  { VList (int array) — Phase 6 }
  PVTable   = Pointer;  { VTable   — Phase 6.bis (vtab.c) }
  Psqlite3_vtab_cursor = Pointer;  { vtab cursor — Phase 6.bis }
  PVdbeSorter = Pointer;           { VdbeSorter  — Phase 5.7 (vdbesort.c) }

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
    Destructor callback type used by Mem.xDel and AuxData.xDeleteAux.
    ----------------------------------------------------------------------- }

  TxDelProc = procedure(p: Pointer); cdecl;

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
procedure sqlite3VdbeAssertAbortable(p: PVdbe);
procedure sqlite3VdbeNoJumpsOutsideSubrtn(v: PVdbe; iFirst, iLast: i32;
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
procedure sqlite3VdbeTypeofColumn(p: PVdbe; iDest: i32);
procedure sqlite3VdbeJumpHere(p: PVdbe; addr: i32);
procedure sqlite3VdbeJumpHereOrPopInst(p: PVdbe; addr: i32);
procedure sqlite3VdbeLinkSubProgram(pVdbe: PVdbe; pSub: PSubProgram);
function  sqlite3VdbeHasSubProgram(pVdbe: PVdbe): i32;
function  sqlite3VdbeChangeToNoop(p: PVdbe; addr: i32): i32;
function  sqlite3VdbeDeletePriorOpcode(p: PVdbe; op: u8): i32;
procedure sqlite3VdbeReleaseRegisters(pParse: PParse; iFirst, nReg, mask: i32;
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
procedure sqlite3VdbeFrameMemDel(pArg: Pointer);
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

{ --- vdbemem.c — Mem value operations (Phase 5.3) --- }
procedure sqlite3VdbeMemInit(pMem: PMem; db: Psqlite3; flags: u16);
procedure sqlite3VdbeMemSetNull(pMem: PMem);
procedure sqlite3VdbeMemSetInt64(pMem: PMem; val: i64);
procedure sqlite3VdbeMemSetDouble(pMem: PMem; val: Double);
function  sqlite3VdbeMemSetStr(pMem: PMem; z: PAnsiChar; n: i64;
                               enc: u8; xDel: TxDelProc): i32;
procedure sqlite3VdbeMemRelease(pMem: PMem);
function  sqlite3VdbeMemCopy(pTo: PMem; const pFrom: PMem): i32;
procedure sqlite3VdbeMemShallowCopy(pTo: PMem; const pFrom: PMem; srcType: i32);
function  sqlite3VdbeMemNumerify(pMem: PMem): i32;
function  sqlite3VdbeIntValue(const pMem: PMem): i64;
function  sqlite3VdbeRealValue(pMem: PMem): Double;
function  sqlite3VdbeBooleanValue(pMem: PMem; ifNull: i32): i32;

{ --- vdbeapi.c — public API (Phase 5.5) --- }
function  sqlite3_step(pStmt: PVdbe): i32;
procedure sqlite3_reset(pStmt: PVdbe);
function  sqlite3_finalize(pStmt: PVdbe): i32;

{ --- vdbe.c — execution engine (Phase 5.4) --- }
function  sqlite3VdbeExec(v: PVdbe): i32;

implementation

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
begin
  { Stub — requires Phase 6 (FuncDef, sqlite3_context allocation) }
  Result := 0;
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

procedure sqlite3VdbeTypeofColumn(p: PVdbe; iDest: i32);
const
  OPFLAG_TYPEOFARG = $20;  { from sqliteInt.h }
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

procedure sqlite3VdbeReleaseRegisters(pParse: PParse; iFirst, nReg, mask: i32;
                                      bUndefine: i32);
begin
  { Debug-only in C; no-op in release port }
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
end;

procedure sqlite3VdbeAssertAbortable(p: PVdbe);
begin
end;

procedure sqlite3VdbeNoJumpsOutsideSubrtn(v: PVdbe; iFirst, iLast: i32;
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

procedure sqlite3VdbeFrameMemDel(pArg: Pointer);
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
  { read key sizes from Parse (byte offsets) }
  nVar    := i32(PWord(PByte(pParse) + 120)^);   { Parse.nVar at offset 120? }
  { Use 0 safely if Parse layout is uncertain — will be replaced in Phase 6 }
  nVar    := 0;
  nMem    := 0;
  nCursor := 0;
  nArg    := 0;

  n := vdbeParseSzOpAllocPtr(pParse)^;
  resolveP2Values(p, @nArg);

  p^.vdbeFlags := p^.vdbeFlags and not (VDBF_UsesStmtJournal or VDBF_EXPIRED_MASK);

  { allocate Mem registers if nMem > 0 }
  if (not vdbeDbMallocFailed(db)) and (nMem > 0) then begin
    p^.aMem := PMem(sqlite3DbMallocZero(db, u64(nMem) * SizeOf(TMem)));
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
begin
  case pCx^.eCurType of
    CURTYPE_BTREE: begin
      if pCx^.uc.pCursor <> nil then
        sqlite3BtreeCloseCursor(pCx^.uc.pCursor);
    end;
    { CURTYPE_SORTER, CURTYPE_VTAB: defer to Phase 5.7 / 6.bis }
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
begin
  { Full implementation is in vdbeaux.c Phase 5.4 }
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
begin
  { Stub — Phase 5.4 }
  Result := SQLITE_OK;
end;

function sqlite3VdbeHandleMovedCursor(p: PVdbeCursor): i32;
begin
  { Stub — Phase 5.4 }
  Result := SQLITE_OK;
end;

function sqlite3VdbeCursorRestore(p: PVdbeCursor): i32;
begin
  { Stub — Phase 5.4 }
  Result := SQLITE_OK;
end;

{ --- Misc lifecycle functions --- }

function sqlite3VdbeParser(p: PVdbe): PParse;
begin
  Result := p^.pParse;
end;

procedure sqlite3VdbeError(p: PVdbe; zFormat: PAnsiChar);
begin
  { Stub — Phase 5.5 }
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

{ --- Public API stubs (Phase 5.5 vdbeapi.c) --- }

function sqlite3_step(pStmt: PVdbe): i32;
begin
  if pStmt = nil then begin Result := SQLITE_MISUSE; Exit; end;
  Result := sqlite3VdbeExec(pStmt);
end;

procedure sqlite3_reset(pStmt: PVdbe);
begin
  sqlite3VdbeReset(pStmt);
end;

function sqlite3_finalize(pStmt: PVdbe): i32;
begin
  Result := sqlite3VdbeFinalize(pStmt);
end;

{ --- Execution engine stub (Phase 5.4 vdbe.c) --- }

function sqlite3VdbeExec(v: PVdbe): i32;
begin
  { Full implementation is vdbe.c — Phase 5.4 }
  Result := SQLITE_MISUSE;
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
  vdbemem.c — Mem value type operations (Phase 5.3 stubs)
  ============================================================================ }

procedure sqlite3VdbeMemInit(pMem: PMem; db: Psqlite3; flags: u16);
begin
  if pMem <> nil then begin
    FillChar(pMem^, SizeOf(TMem), 0);
    pMem^.flags := flags;
    pMem^.db    := db;
  end;
end;

procedure sqlite3VdbeMemSetNull(pMem: PMem);
begin
  if pMem <> nil then begin
    pMem^.flags := MEM_Null;
    pMem^.z := nil;
  end;
end;

procedure sqlite3VdbeMemSetInt64(pMem: PMem; val: i64);
begin
  if pMem <> nil then begin
    pMem^.u.i   := val;
    pMem^.flags := MEM_Int;
  end;
end;

procedure sqlite3VdbeMemSetDouble(pMem: PMem; val: Double);
begin
  if pMem <> nil then begin
    pMem^.u.r   := val;
    pMem^.flags := MEM_Real;
  end;
end;

function sqlite3VdbeMemSetStr(pMem: PMem; z: PAnsiChar; n: i64;
                              enc: u8; xDel: TxDelProc): i32;
begin
  { Stub — Phase 5.3 }
  Result := SQLITE_OK;
end;

procedure sqlite3VdbeMemRelease(pMem: PMem);
begin
  if pMem = nil then Exit;
  if (pMem^.flags and MEM_Dyn) <> 0 then begin
    if pMem^.xDel <> nil then
      pMem^.xDel(pMem^.z)
    else if pMem^.szMalloc > 0 then
      sqlite3DbFree(pMem^.db, pMem^.zMalloc);
  end;
  pMem^.flags := MEM_Undefined;
  pMem^.z := nil;
  pMem^.zMalloc := nil;
  pMem^.szMalloc := 0;
end;

function sqlite3VdbeMemCopy(pTo: PMem; const pFrom: PMem): i32;
begin
  if (pTo <> nil) and (pFrom <> nil) then
    Move(pFrom^, pTo^, SizeOf(TMem));
  Result := SQLITE_OK;
end;

procedure sqlite3VdbeMemShallowCopy(pTo: PMem; const pFrom: PMem; srcType: i32);
begin
  if (pTo <> nil) and (pFrom <> nil) then
    Move(pFrom^, pTo^, SizeOf(TMem));
end;

function sqlite3VdbeMemNumerify(pMem: PMem): i32;
begin
  { Stub — Phase 5.3 }
  Result := SQLITE_OK;
end;

function sqlite3VdbeIntValue(const pMem: PMem): i64;
begin
  if pMem = nil then begin Result := 0; Exit; end;
  if (pMem^.flags and MEM_Int) <> 0 then
    Result := pMem^.u.i
  else if (pMem^.flags and MEM_Real) <> 0 then
    Result := i64(Trunc(pMem^.u.r))
  else
    Result := 0;
end;

function sqlite3VdbeRealValue(pMem: PMem): Double;
begin
  if pMem = nil then begin Result := 0.0; Exit; end;
  if (pMem^.flags and MEM_Real) <> 0 then
    Result := pMem^.u.r
  else if (pMem^.flags and MEM_Int) <> 0 then
    Result := Double(pMem^.u.i)
  else
    Result := 0.0;
end;

function sqlite3VdbeBooleanValue(pMem: PMem; ifNull: i32): i32;
begin
  if pMem = nil then begin Result := ifNull; Exit; end;
  if (pMem^.flags and MEM_Null) <> 0 then
    Result := ifNull
  else if (pMem^.flags and MEM_Int) <> 0 then
    Result := ord(pMem^.u.i <> 0)
  else if (pMem^.flags and MEM_Real) <> 0 then
    Result := ord(pMem^.u.r <> 0.0)
  else
    Result := 0;
end;

initialization
  FillChar(gVdbeOpDummy, SizeOf(TVdbeOp), 0);

end.
