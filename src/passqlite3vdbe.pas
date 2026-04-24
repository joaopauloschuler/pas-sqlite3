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
  Psqlite3_value = PMem;           { Mem and sqlite3_value are the same type }
  PPsqlite3_value = ^Psqlite3_value;
  PVdbeCursor    = ^TVdbeCursor;
  PPVdbeCursor   = ^PVdbeCursor;
  PVdbeFrame     = ^TVdbeFrame;
  PAuxData       = ^TAuxData;
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
  Function stubs — will be implemented in Phases 5.2 – 5.9.
  Declared here so that other units (btree, pager) can forward-reference them.
  ============================================================================ }

{ vdbeaux.c — program assembly }
function  sqlite3VdbeCreate(pParse: PParse): PVdbe;
procedure sqlite3VdbeDelete(p: PVdbe);
function  sqlite3VdbeAddOp0(v: PVdbe; op: i32): i32;
function  sqlite3VdbeAddOp1(v: PVdbe; op, p1: i32): i32;
function  sqlite3VdbeAddOp2(v: PVdbe; op, p1, p2: i32): i32;
function  sqlite3VdbeAddOp3(v: PVdbe; op, p1, p2, p3: i32): i32;
function  sqlite3VdbeAddOp4(v: PVdbe; op, p1, p2, p3: i32;
                            zP4: PAnsiChar; p4type: i32): i32;
function  sqlite3VdbeGoto(v: PVdbe; iDest: i32): i32;
procedure sqlite3VdbeResolveLabel(v: PVdbe; x: i32);
function  sqlite3VdbeMakeLabel(pParse: PParse): i32;

{ vdbemem.c — Mem value operations }
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

{ vdbeapi.c — public API (sqlite3_step, _column_*, _bind_*) }
function  sqlite3_step(pStmt: PVdbe): i32;
procedure sqlite3_reset(pStmt: PVdbe);
function  sqlite3_finalize(pStmt: PVdbe): i32;

{ vdbe.c — execution engine }
function  sqlite3VdbeExec(v: PVdbe): i32;
function  sqlite3VdbeHalt(v: PVdbe): i32;

{ vdbetrace.c — EXPLAIN rendering }
function  sqlite3VdbeList(v: PVdbe): i32;

{ Opcode name lookup (vdbeaux.c, used for EXPLAIN) }
function  sqlite3OpcodeName(n: i32): PAnsiChar;

{ Serial type helpers (vdbeaux.c) }
function  sqlite3VdbeSerialTypeLen(serialType: u32): u32;
function  sqlite3VdbeOneByteSerialTypeLen(serialType: u8): u8;
procedure sqlite3VdbeSerialGet(buf: Pu8; serialType: u32; pMem: PMem);

implementation

{ ============================================================================
  sqlite3SmallTypeSizes — serial type → stored size lookup table.
  Source: vdbeaux.c const u8 sqlite3SmallTypeSizes[].
  Types 0-12 have fixed sizes in bytes (type 0=NULL, 1=1B, 2=2B, …, 7=8B,
  8=8B, 9=0B, 10=0B); types ≥ 13 use varint length and are NOT in this table
  (lookup returns 0 to indicate "use varint").  Values ≥ 128 also return 0.
  ============================================================================ }

const
  SMALL_TYPE_SIZES: array[0..12] of u8 = (
    { type  0 (NULL)       } 0,
    { type  1 (int 1B)     } 1,
    { type  2 (int 2B)     } 2,
    { type  3 (int 3B)     } 3,
    { type  4 (int 4B)     } 4,
    { type  5 (int 6B)     } 6,
    { type  6 (int 8B)     } 8,
    { type  7 (float 8B)   } 8,
    { type  8 (int 0=zero) } 0,
    { type  9 (int 1=one)  } 0,
    { type 10 (reserved)   } 0,
    { type 11 (reserved)   } 0,
    { type 12 (blob/str 0B)} 0
  );

{ ============================================================================
  Stub implementations for Phase 5.1.
  Full implementations land in Phases 5.2 – 5.9.
  All stubs compile cleanly and return safe zero/nil values.
  ============================================================================ }

function  sqlite3VdbeCreate(pParse: PParse): PVdbe;
begin
  Result := nil;
end;

procedure sqlite3VdbeDelete(p: PVdbe);
begin
end;

function  sqlite3VdbeAddOp0(v: PVdbe; op: i32): i32;
begin
  Result := 0;
end;

function  sqlite3VdbeAddOp1(v: PVdbe; op, p1: i32): i32;
begin
  Result := 0;
end;

function  sqlite3VdbeAddOp2(v: PVdbe; op, p1, p2: i32): i32;
begin
  Result := 0;
end;

function  sqlite3VdbeAddOp3(v: PVdbe; op, p1, p2, p3: i32): i32;
begin
  Result := 0;
end;

function  sqlite3VdbeAddOp4(v: PVdbe; op, p1, p2, p3: i32;
                            zP4: PAnsiChar; p4type: i32): i32;
begin
  Result := 0;
end;

function  sqlite3VdbeGoto(v: PVdbe; iDest: i32): i32;
begin
  Result := 0;
end;

procedure sqlite3VdbeResolveLabel(v: PVdbe; x: i32);
begin
end;

function  sqlite3VdbeMakeLabel(pParse: PParse): i32;
begin
  Result := 0;
end;

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

function  sqlite3VdbeMemSetStr(pMem: PMem; z: PAnsiChar; n: i64;
                               enc: u8; xDel: TxDelProc): i32;
begin
  Result := SQLITE_OK;
end;

procedure sqlite3VdbeMemRelease(pMem: PMem);
begin
end;

function  sqlite3VdbeMemCopy(pTo: PMem; const pFrom: PMem): i32;
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

function  sqlite3VdbeMemNumerify(pMem: PMem): i32;
begin
  Result := SQLITE_OK;
end;

function  sqlite3VdbeIntValue(const pMem: PMem): i64;
begin
  if pMem = nil then begin Result := 0; Exit; end;
  if (pMem^.flags and MEM_Int) <> 0 then
    Result := pMem^.u.i
  else if (pMem^.flags and MEM_Real) <> 0 then
    Result := i64(Trunc(pMem^.u.r))
  else
    Result := 0;
end;

function  sqlite3VdbeRealValue(pMem: PMem): Double;
begin
  if pMem = nil then begin Result := 0.0; Exit; end;
  if (pMem^.flags and MEM_Real) <> 0 then
    Result := pMem^.u.r
  else if (pMem^.flags and MEM_Int) <> 0 then
    Result := Double(pMem^.u.i)
  else
    Result := 0.0;
end;

function  sqlite3VdbeBooleanValue(pMem: PMem; ifNull: i32): i32;
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

function  sqlite3_step(pStmt: PVdbe): i32;
begin
  Result := SQLITE_MISUSE;
end;

procedure sqlite3_reset(pStmt: PVdbe);
begin
end;

function  sqlite3_finalize(pStmt: PVdbe): i32;
begin
  Result := SQLITE_OK;
end;

function  sqlite3VdbeExec(v: PVdbe): i32;
begin
  Result := SQLITE_MISUSE;
end;

function  sqlite3VdbeHalt(v: PVdbe): i32;
begin
  Result := SQLITE_OK;
end;

function  sqlite3VdbeList(v: PVdbe): i32;
begin
  Result := SQLITE_OK;
end;

function  sqlite3OpcodeName(n: i32): PAnsiChar;
const
  { opcode name strings from vdbeaux.c sqlite3OpcodeName().
    Order matches the OP_* numeric values 0..191. }
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

function  sqlite3VdbeSerialTypeLen(serialType: u32): u32;
begin
  if serialType >= 12 then begin
    if (serialType and 1) = 0 then
      Result := (serialType - 12) div 2
    else
      Result := (serialType - 13) div 2;
    Exit;
  end;
  if serialType < 13 then
    Result := SMALL_TYPE_SIZES[serialType]
  else
    Result := 0;
end;

function  sqlite3VdbeOneByteSerialTypeLen(serialType: u8): u8;
begin
  if serialType < 13 then
    Result := SMALL_TYPE_SIZES[serialType]
  else
    Result := 0;
end;

procedure sqlite3VdbeSerialGet(buf: Pu8; serialType: u32; pMem: PMem);
begin
  { Stub: full implementation in Phase 5.4 (vdbe.c OP_Column path) }
  if pMem <> nil then
    FillChar(pMem^, SizeOf(TMem), 0);
end;

end.
