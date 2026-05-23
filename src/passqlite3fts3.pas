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
unit passqlite3fts3;

{
  Phase 6.40.1.a / 6.40.1.b — foundation of the FTS3/FTS4 full-text-search
  port.  This unit is the new home for the entire ext/fts3/ cluster
  (tasklist 6.40.1); subsequent sub-tasks (.c .. .o) extend it.

  6.40.1.a — ABI type/record declarations:
    * fts3.h                (../sqlite3/ext/fts3/fts3.h, 26L) — declares only
      sqlite3Fts3Init(); ported as a forward (not yet implemented, 6.40.1.o).
    * fts3_tokenizer.h      (../sqlite3/ext/fts3/fts3_tokenizer.h) — the
      public tokenizer interface: sqlite3_tokenizer, sqlite3_tokenizer_module
      (a C-ABI vtable of cdecl function pointers) and
      sqlite3_tokenizer_cursor.
    * fts3_hash.h           (../sqlite3/ext/fts3/fts3_hash.h) — Fts3Hash,
      Fts3HashElem, the FTS3_HASH_* constants and the macro-style accessors.

  6.40.1.b — fts3_hash.c (../sqlite3/ext/fts3/fts3_hash.c, 383L): the
    standalone string/binary hash table used throughout FTS3
    (sqlite3Fts3HashInit / Insert / Find / Clear / FindElem plus the static
    helpers).  Allocates only through sqlite3_malloc64 / sqlite3_free.

  Gate: src/tests/TestFts3Hash.pas exercises init / insert / find /
  overwrite / delete-via-NULL / rehash / clear of a FTS3_HASH_STRING table.

  NOTE on FPC porting: the FTS3 hash stores raw void* keys/data; the records
  below keep all key/data fields as plain Pointer so no managed-string
  ref-counting ever runs over the GetMem'd blocks (the New()-on-managed-record
  hazard documented in MEMORY.md does not apply).
}

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,    { sqlite3_mprintf / sqlite3_free wrappers }
  passqlite3printf,  { sqlite3PfMprintf — Pascal-side varargs formatter }
  passqlite3vdbe,    { sqlite3_value_* / sqlite3_result_* / sqlite3_user_data /
                       sqlite3_context_db_handle and the statement APIs }
  passqlite3vtab,    { Tsqlite3_module + vtab/cursor base records + index_info,
                       sqlite3_declare_vtab (6.40.1.h fts3tokenize module) }
  passqlite3main;    { sqlite3_create_function(_v2) / sqlite3_create_module_v2 /
                       sqlite3_db_config_int / sqlite3_prepare_v2 /
                       sqlite3_errmsg }

const
  { fts3_hash.h:68..69 — key-class modes. }
  FTS3_HASH_STRING = 1;
  FTS3_HASH_BINARY = 2;

  { fts3_tokenizer.h — tokenizer-module structure version sentinel; the
    xLanguageid slot is only present/used for iVersion>=1. }
  FTS3_TOKENIZER_IVERSION0 = 0;
  FTS3_TOKENIZER_IVERSION1 = 1;

  { fts3Int.h:517..521 — Fts3Expr.eType node-type codes.  The first four
    are in order of parse precedence (NEAR tightest, OR loosest). }
  FTSQUERY_NEAR   = 1;
  FTSQUERY_NOT    = 2;
  FTSQUERY_AND    = 3;
  FTSQUERY_OR     = 4;
  FTSQUERY_PHRASE = 5;

  { fts3Int.h:65..67 — maximum depth of an FTS expression tree. }
  SQLITE_FTS3_MAX_EXPR_DEPTH = 12;

  { fts3_expr.c:79 — default span for NEAR operators. }
  SQLITE_FTS3_DEFAULT_NEAR_PARAM = 10;

type
  { ===================================================================== }
  { fts3_tokenizer.h — public tokenizer interface (C ABI).                }
  { ===================================================================== }

  Psqlite3_tokenizer        = ^Tsqlite3_tokenizer;
  Psqlite3_tokenizer_module = ^Tsqlite3_tokenizer_module;
  Psqlite3_tokenizer_cursor = ^Tsqlite3_tokenizer_cursor;

  PPsqlite3_tokenizer        = ^Psqlite3_tokenizer;
  PPsqlite3_tokenizer_cursor = ^Psqlite3_tokenizer_cursor;
  PPsqlite3_tokenizer_module = ^Psqlite3_tokenizer_module;

  { fts3_tokenizer.h:76..80 — xCreate.
    int (*xCreate)(int argc, const char *const*argv,
                   sqlite3_tokenizer **ppTokenizer) }
  TFts3TokXCreate = function(argc: cint; const argv: PPChar;
    ppTokenizer: PPsqlite3_tokenizer): cint; cdecl;

  { fts3_tokenizer.h:86 — int (*xDestroy)(sqlite3_tokenizer *pTokenizer) }
  TFts3TokXDestroy = function(pTokenizer: Psqlite3_tokenizer): cint; cdecl;

  { fts3_tokenizer.h:93..97 — xOpen.
    int (*xOpen)(sqlite3_tokenizer *pTokenizer, const char *pInput,
                 int nBytes, sqlite3_tokenizer_cursor **ppCursor) }
  TFts3TokXOpen = function(pTokenizer: Psqlite3_tokenizer; const pInput: PChar;
    nBytes: cint; ppCursor: PPsqlite3_tokenizer_cursor): cint; cdecl;

  { fts3_tokenizer.h:103 — int (*xClose)(sqlite3_tokenizer_cursor *pCursor) }
  TFts3TokXClose = function(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;

  { fts3_tokenizer.h:129..135 — xNext.
    int (*xNext)(sqlite3_tokenizer_cursor *pCursor,
                 const char **ppToken, int *pnBytes,
                 int *piStartOffset, int *piEndOffset, int *piPosition) }
  TFts3TokXNext = function(pCursor: Psqlite3_tokenizer_cursor;
    ppToken: PPChar; pnBytes: Pcint;
    piStartOffset: Pcint; piEndOffset: Pcint; piPosition: Pcint): cint; cdecl;

  { fts3_tokenizer.h:144 — only available when iVersion>=1.
    int (*xLanguageid)(sqlite3_tokenizer_cursor *pCsr, int iLangid) }
  TFts3TokXLanguageid = function(pCsr: Psqlite3_tokenizer_cursor;
    iLangid: cint): cint; cdecl;

  { fts3_tokenizer.h:52..145 — struct sqlite3_tokenizer_module.
    The class structure (vtable) for tokenizers. }
  Tsqlite3_tokenizer_module = record
    iVersion    : cint;            { Should always be set to 0 or 1. }
    xCreate     : TFts3TokXCreate;
    xDestroy    : TFts3TokXDestroy;
    xOpen       : TFts3TokXOpen;
    xClose      : TFts3TokXClose;
    xNext       : TFts3TokXNext;
    { Methods below this point are only available if iVersion>=1. }
    xLanguageid : TFts3TokXLanguageid;
  end;

  { fts3_tokenizer.h:147..150 — struct sqlite3_tokenizer.
    Tokenizer implementations typically append additional fields. }
  Tsqlite3_tokenizer = record
    pModule : Psqlite3_tokenizer_module;  { The module for this tokenizer }
  end;

  { fts3_tokenizer.h:152..155 — struct sqlite3_tokenizer_cursor.
    Tokenizer implementations typically append additional fields. }
  Tsqlite3_tokenizer_cursor = record
    pTokenizer : Psqlite3_tokenizer;      { Tokenizer for this cursor. }
  end;

  { ===================================================================== }
  { fts3_hash.h — standalone hash table.                                  }
  { ===================================================================== }

  PFts3Hash     = ^TFts3Hash;
  PFts3HashElem = ^TFts3HashElem;
  PPFts3HashElem = ^PFts3HashElem;

  { fts3_hash.h:38..41 — struct _fts3ht (one hash bucket). }
  PFts3Ht = ^TFts3Ht;
  TFts3Ht = record
    count : cint;            { Number of entries with this hash }
    chain : PFts3HashElem;   { Pointer to first entry with this hash }
  end;

  { fts3_hash.h:50..54 — struct Fts3HashElem.
    All elements are stored on a single doubly-linked list.  Keys/data are
    raw void* (kept as Pointer; never managed). }
  TFts3HashElem = record
    next : PFts3HashElem;    { Next element in the table }
    prev : PFts3HashElem;    { Previous element in the table }
    data : Pointer;          { Data associated with this element }
    pKey : Pointer;          { Key associated with this element }
    nKey : cint;
  end;

  { fts3_hash.h:32..42 — struct Fts3Hash. }
  TFts3Hash = record
    keyClass : cchar;        { HASH_INT, _POINTER, _STRING, _BINARY }
    copyKey  : cchar;        { True if copy of key made on insert }
    count    : cint;         { Number of entries in this table }
    first    : PFts3HashElem; { The first element of the array }
    htsize   : cint;         { Number of buckets in the hash table }
    ht       : PFts3Ht;      { the hash table }
  end;

  { ===================================================================== }
  { 6.40.1.i — fts3Int.h:430..521 — the MATCH query-expression tree.      }
  { These types are shared by the parser (fts3_expr.c) and the evaluator  }
  { (fts3_write.c / fts3.c, tasks 6.40.1.j/.k); declared here so .j/.k can }
  { reuse them.  Fields below the parser line are populated/used only by   }
  { the evaluation phase and stay zero on a freshly-parsed tree.           }
  { ===================================================================== }

  PFts3Expr            = ^TFts3Expr;
  PPFts3Expr           = ^PFts3Expr;
  PFts3Phrase          = ^TFts3Phrase;
  PFts3PhraseToken     = ^TFts3PhraseToken;

  { Forward-only opaque types referenced by the tree but defined by the
    not-yet-ported evaluator (fts3_write.c, 6.40.1.j).  Kept as Pointer
    here; the real records land with their owning subtask. }
  PFts3DeferredToken   = Pointer;   { fts3Int.h:247 (fts3_write.c) }
  PFts3MultiSegReader2 = Pointer;   { fts3Int.h:249 (fts3_write.c) }

  { fts3Int.h:413..422 — struct Fts3Doclist (embedded in Fts3Phrase).
    Populated by the evaluator only; on a parsed tree it is all zero. }
  TFts3Doclist = record
    aAll       : PChar;          { Array containing doclist (or NULL) }
    nAll       : cint;           { Size of a[] in bytes }
    pNextDocid : PChar;          { Pointer to next docid }
    iDocid     : sqlite3_int64;  { Current docid (if pList!=0) }
    bFreeList  : cint;           { True if pList should be sqlite3_free()d }
    pList      : PChar;          { Pointer to position list following iDocid }
    nList      : cint;           { Length of position list }
  end;

  { fts3Int.h:430..441 — struct Fts3PhraseToken. }
  TFts3PhraseToken = record
    z        : PChar;            { Text of the token }
    n        : cint;             { Number of bytes in buffer z }
    isPrefix : cint;             { True if token ends with a "*" character }
    bFirst   : cint;             { True if token must appear at position 0 }
    { Variables below populated/used by the evaluation phase only. }
    pDeferred : PFts3DeferredToken;
    pSegcsr   : PFts3MultiSegReader2;
  end;

  { fts3Int.h:443..460 — struct Fts3Phrase.  aToken[] is a flexible array;
    in Pascal the trailing array is sized at allocation time (the whole
    Fts3Expr+Fts3Phrase+aToken[]+token-text block is one sqlite3_malloc).
    Declared with a single trailing element so @aToken[0] is the base. }
  TFts3Phrase = record
    { Cache of doclist for this phrase (evaluation phase). }
    doclist       : TFts3Doclist;
    bIncr         : cint;        { True if doclist is loaded incrementally }
    iDoclistToken : cint;
    pOrPoslist    : PChar;
    iOrDocid      : sqlite3_int64;
    { Variables below populated by the parser (fts3_expr.c). }
    nToken        : cint;        { Number of tokens in the phrase }
    iColumn       : cint;        { Index of column this phrase must match }
    aToken        : array[0..0] of TFts3PhraseToken;  { FLEXARRAY }
  end;

  { fts3Int.h:487..504 — struct Fts3Expr. }
  TFts3Expr = record
    eType   : cint;              { One of the FTSQUERY_XXX values }
    nNear   : cint;              { Valid if eType==FTSQUERY_NEAR }
    pParent : PFts3Expr;         { pParent->pLeft==this or pParent->pRight==this }
    pLeft   : PFts3Expr;         { Left operand }
    pRight  : PFts3Expr;         { Right operand }
    pPhrase : PFts3Phrase;       { Valid if eType==FTSQUERY_PHRASE }
    { The following are used by the fts3_eval.c module. }
    iDocid    : sqlite3_int64;   { Current docid }
    bEof      : cuchar;          { True this expression is at EOF already }
    bStart    : cuchar;          { True if iDocid is valid }
    bDeferred : cuchar;          { True if this expression is entirely deferred }
    { The following are used by the fts3_snippet.c module. }
    iPhrase : cint;              { Index of this phrase in matchinfo() results }
    aMI     : Pcuint;            { See fts3Int.h }
  end;

  { ===================================================================== }
  { 6.40.1.j — shared structs from fts3Int.h.  These are populated/used by }
  { the segment engine (fts3_write.c) and are also referenced by the       }
  { fts3/fts4 vtab module (.k), fts3_snippet.c (.l), fts3_aux.c (.m) and    }
  { fts3_term.c (.n).  Declared here so all those tasks can reuse them.     }
  { ===================================================================== }

  Psqlite3_int64      = Pi64;          { fts3_write.c sqlite3_int64* params }

  PFts3Table          = ^TFts3Table;
  PFts3Cursor         = ^TFts3Cursor;
  PFts3SegReader      = ^TFts3SegReader;
  PPFts3SegReader     = ^PFts3SegReader;
  PFts3MultiSegReader = ^TFts3MultiSegReader;
  PFts3SegFilter      = ^TFts3SegFilter;
  PFts3DeferredTokenR = ^TFts3DeferredToken;
  PMatchinfoBuffer    = Pointer;       { fts3_snippet.c (6.40.1.l) — opaque here }

  { fts3Int.h:313..316 — struct Fts3Index (one per term/prefix index). }
  PFts3Index = ^TFts3Index;
  TFts3Index = record
    nPrefix  : cint;             { Prefix length (0 for main terms index) }
    hPending : TFts3Hash;        { Pending terms table for this index }
  end;

  { fts3Int.h:260..341 — struct Fts3Table.  Populated by fts3.c xConnect (.k);
    here we port the struct + the functions that read/write through it.
    Debug-only fields (inTransaction/mxSavepoint, bNoIncrDoclist/nMergeCount)
    are kept unconditionally for a stable ABI layout shared with .k. }
  TFts3Table = record
    base          : Tsqlite3_vtab;     { Base class used by SQLite core }
    db            : PTsqlite3;          { The database connection }
    zDb           : PChar;             { logical database name }
    zName         : PChar;             { virtual table name }
    nColumn       : cint;              { number of named columns in vtab }
    azColumn      : PPChar;            { column names.  malloced }
    abNotindexed  : PByte;             { True for 'notindexed' columns }
    pTokenizer    : Psqlite3_tokenizer;{ tokenizer for inserts and queries }
    zContentTbl   : PChar;             { content=xxx option, or NULL }
    zLanguageid   : PChar;             { languageid=xxx option, or NULL }
    nAutoincrmerge: cint;              { Value configured by 'automerge' }
    nLeafAdd      : cuint;             { Number of leaf blocks added this trans }
    bLock         : cint;              { prevent recursive content= tbls }

    aStmt         : array[0..39] of PVdbe;  { Precompiled statements }
    pSeekStmt     : PVdbe;             { Cache for fts3CursorSeekStmt() }

    zReadExprlist : PChar;
    zWriteExprlist: PChar;

    nNodeSize     : cint;              { Soft limit for node size }
    bFts4         : cuchar;            { True for FTS4, false for FTS3 }
    bHasStat      : cuchar;            { True if %_stat exists (2==unknown) }
    bHasDocsize   : cuchar;            { True if %_docsize table exists }
    bDescIdx      : cuchar;            { True if doclists are in reverse order }
    bIgnoreSavepoint: cuchar;          { True to ignore xSavepoint invocations }
    nPgsz         : cint;              { Page size for host database }
    zSegmentsTbl  : PChar;             { Name of %_segments table }
    pSegments     : Psqlite3_blob;     { Blob handle open on %_segments table }
    iSavepoint    : cint;

    nIndex        : cint;              { Size of aIndex[] }
    aIndex        : PFts3Index;        { Array of term/prefix indexes }
    nMaxPendingData: cint;             { Max pending data before flush to disk }
    nPendingData  : cint;              { Current bytes of pending data }
    iPrevDocid    : sqlite3_int64;     { Docid of most recently inserted doc }
    iPrevLangid   : cint;              { Langid of recently inserted document }
    bPrevDelete   : cint;              { True if last operation was a delete }

    { SQLITE_DEBUG || SQLITE_COVERAGE_TEST }
    inTransaction : cint;              { True after xBegin before xCommit }
    mxSavepoint   : cint;              { Largest valid xSavepoint integer }

    { SQLITE_DEBUG || SQLITE_TEST }
    bNoIncrDoclist: cint;              { test-no-incr-doclist special insert }
    nMergeCount   : cint;              { Number of segments in a level }
  end;

  { fts3Int.h:355..378 — struct Fts3Cursor.  Owned by fts3.c (.k); declared
    here because the deferred-token machinery in fts3_write.c reads/writes
    pCsr->pDeferred, pStmt, iLangid and base.pVtab. }
  TFts3Cursor = record
    base          : Tsqlite3_vtab_cursor; { Base class used by SQLite core }
    eSearch       : cshort;            { Search strategy }
    isEof         : cuchar;            { True if at End Of Results }
    isRequireSeek : cuchar;            { True if must seek pStmt to %_content }
    bSeekStmt     : cuchar;            { True if pStmt is a seek }
    pStmt         : PVdbe;             { Prepared statement in use by cursor }
    pExpr         : PFts3Expr;         { Parsed MATCH query string }
    iLangid       : cint;              { Language being queried for }
    nPhrase       : cint;              { Number of matchable phrases in query }
    pDeferred     : PFts3DeferredTokenR;{ Deferred search tokens, if any }
    iPrevId       : sqlite3_int64;     { Previous id read from aDoclist }
    pNextId       : PChar;             { Pointer into the body of aDoclist }
    aDoclist      : PChar;             { List of docids for full-text queries }
    nDoclist      : cint;              { Size of buffer at aDoclist }
    bDesc         : cuchar;            { True to sort in descending order }
    eEvalmode     : cint;              { An FTS3_EVAL_XX constant }
    nRowAvg       : cint;              { Average size of database rows, in pages }
    nDoc          : sqlite3_int64;     { Documents in table }
    iMinDocid     : sqlite3_int64;     { Minimum docid to return }
    iMaxDocid     : sqlite3_int64;     { Maximum docid to return }
    isMatchinfoNeeded: cint;           { True when aMatchinfo[] needs filling }
    pMIBuffer     : PMatchinfoBuffer;  { Buffer for matchinfo data }
  end;

  { fts3Int.h:137..171 — struct Fts3SegReader.  Internal to fts3_write.c, but
    handled opaquely by fts3.c. }
  TFts3SegReader = record
    iIdx          : cint;              { Index within level, or 0x7FFFFFFF for PT }
    bLookup       : cuchar;            { True for a lookup only }
    rootOnly      : cuchar;            { True for a root-only reader }

    iStartBlock   : sqlite3_int64;     { Rowid of first leaf block to traverse }
    iLeafEndBlock : sqlite3_int64;     { Rowid of final leaf block to traverse }
    iEndBlock     : sqlite3_int64;     { Rowid of final block in segment (or 0) }
    iCurrentBlock : sqlite3_int64;     { Current leaf block (or 0) }

    aNode         : PChar;             { Pointer to node data (or NULL) }
    nNode         : cint;              { Size of buffer at aNode (or 0) }
    nPopulate     : cint;              { If >0, bytes of buffer aNode[] loaded }
    pBlob         : Psqlite3_blob;     { If not NULL, blob handle to read node }

    ppNextElem    : PPFts3HashElem;

    { Variables set by fts3SegReaderNext(). }
    nTerm         : cint;              { Number of bytes in current term }
    zTerm         : PChar;             { Pointer to current term }
    nTermAlloc    : cint;              { Allocated size of zTerm buffer }
    aDoclist      : PChar;             { Pointer to doclist of current entry }
    nDoclist      : cint;              { Size of doclist in current entry }

    { Used by fts3SegReaderNextDocid() }
    pOffsetList   : PChar;
    nOffsetList   : cint;              { For descending pending seg-readers only }
    iDocid        : sqlite3_int64;
  end;

  { fts3Int.h:577..582 — struct Fts3SegFilter. }
  TFts3SegFilter = record
    zTerm : PChar;
    nTerm : cint;
    iCol  : cint;
    flags : cint;
  end;

  { fts3Int.h:584..605 — struct Fts3MultiSegReader. }
  TFts3MultiSegReader = record
    apSegment : PPFts3SegReader;       { Array of Fts3SegReader objects }
    nSegment  : cint;                  { Size of apSegment array }
    nAdvance  : cint;                  { How many seg-readers to advance }
    pFilter   : PFts3SegFilter;        { Pointer to filter object }
    aBuffer   : PChar;                 { Buffer to merge doclists in }
    nBuffer   : sqlite3_int64;         { Allocated size of aBuffer[] in bytes }

    iColFilter: cint;                  { If >=0, filter for this column }
    bRestart  : cint;

    { Used by fts3.c only. }
    nCost     : cint;                  { Cost of running iterator }
    bLookup   : cint;                  { True if a lookup of a single entry. }

    { Output values. Valid only after Step() returns SQLITE_ROW. }
    zTerm     : PChar;                 { Pointer to term buffer }
    nTerm     : cint;                  { Size of zTerm in bytes }
    aDoclist  : PChar;                 { Pointer to doclist buffer }
    nDoclist  : cint;                  { Size of aDoclist[] in bytes }
  end;

  { fts3_write.c:100..107 — struct PendingList. }
  PPendingList = ^TPendingList;
  PPPendingList = ^PPendingList;
  TPendingList = record
    nData     : sqlite3_int64;
    aData     : PChar;
    nSpace    : sqlite3_int64;
    iLastDocid: sqlite3_int64;
    iLastCol  : sqlite3_int64;
    iLastPos  : sqlite3_int64;
  end;

  { fts3_write.c:113..118 — struct Fts3DeferredToken. }
  TFts3DeferredToken = record
    pToken : PFts3PhraseToken;         { Pointer to corresponding expr token }
    iCol   : cint;                     { Column token must occur in }
    pNext  : PFts3DeferredTokenR;      { Next in list of deferred tokens }
    pList  : PPendingList;             { Doclist is assembled here }
  end;

const
  { fts3Int.h:75 — segments-per-level merge threshold. }
  FTS3_MERGE_COUNT = 16;
  { fts3Int.h:85 — max pending-data bytes before mid-transaction flush. }
  FTS3_MAX_PENDING_DATA = (1*1024*1024);
  { fts3Int.h:106 — FTS3 varint max length (10, not 9 as in the core). }
  FTS3_VARINT_MAX = 10;
  { fts3Int.h:108 }
  FTS3_BUFFER_PADDING = 8;
  { fts3Int.h:125..126 }
  FTS3_SEGDIR_MAXLEVEL = 1024;
  { fts3Int.h:139..140 — position/column-list terminators. }
  POS_COLUMN = 1;
  POS_END    = 0;

  { fts3Int.h:380..382 — Fts3Cursor.eEvalmode values. }
  FTS3_EVAL_FILTER    = 0;
  FTS3_EVAL_NEXT      = 1;
  FTS3_EVAL_MATCHINFO = 2;

  { fts3Int.h:399..401 — Fts3Cursor.eSearch base values. }
  FTS3_FULLSCAN_SEARCH = 0;
  FTS3_DOCID_SEARCH    = 1;
  FTS3_FULLTEXT_SEARCH = 2;

  { fts3Int.h:409..411 — idxNum high-bit constraint flags. }
  FTS3_HAVE_LANGID   = $00010000;
  FTS3_HAVE_DOCID_GE = $00020000;
  FTS3_HAVE_DOCID_LE = $00040000;

  { fts3Int.h:558..559 — special iLevel values for sqlite3Fts3SegReaderCursor. }
  FTS3_SEGCURSOR_PENDING = -1;
  FTS3_SEGCURSOR_ALL     = -2;

  { fts3Int.h:569..574 — SegmentReaderIterate() 4th-argument flags. }
  FTS3_SEGMENT_REQUIRE_POS   = $00000001;
  FTS3_SEGMENT_IGNORE_EMPTY  = $00000002;
  FTS3_SEGMENT_COLUMN_FILTER = $00000004;
  FTS3_SEGMENT_PREFIX        = $00000008;
  FTS3_SEGMENT_SCAN          = $00000010;
  FTS3_SEGMENT_FIRST         = $00000020;

  { fts3_write.c:233..274 — fts3SqlStmt() statement-id constants. }
  SQL_DELETE_CONTENT            = 0;
  SQL_IS_EMPTY                  = 1;
  SQL_DELETE_ALL_CONTENT        = 2;
  SQL_DELETE_ALL_SEGMENTS       = 3;
  SQL_DELETE_ALL_SEGDIR         = 4;
  SQL_DELETE_ALL_DOCSIZE        = 5;
  SQL_DELETE_ALL_STAT           = 6;
  SQL_SELECT_CONTENT_BY_ROWID   = 7;
  SQL_NEXT_SEGMENT_INDEX        = 8;
  SQL_INSERT_SEGMENTS           = 9;
  SQL_NEXT_SEGMENTS_ID          = 10;
  SQL_INSERT_SEGDIR             = 11;
  SQL_SELECT_LEVEL              = 12;
  SQL_SELECT_LEVEL_RANGE        = 13;
  SQL_SELECT_LEVEL_COUNT        = 14;
  SQL_SELECT_SEGDIR_MAX_LEVEL   = 15;
  SQL_DELETE_SEGDIR_LEVEL       = 16;
  SQL_DELETE_SEGMENTS_RANGE     = 17;
  SQL_CONTENT_INSERT            = 18;
  SQL_DELETE_DOCSIZE            = 19;
  SQL_REPLACE_DOCSIZE           = 20;
  SQL_SELECT_DOCSIZE            = 21;
  SQL_SELECT_STAT               = 22;
  SQL_REPLACE_STAT              = 23;
  SQL_SELECT_ALL_PREFIX_LEVEL   = 24;
  SQL_DELETE_ALL_TERMS_SEGDIR   = 25;
  SQL_DELETE_SEGDIR_RANGE       = 26;
  SQL_SELECT_ALL_LANGID         = 27;
  SQL_FIND_MERGE_LEVEL          = 28;
  SQL_MAX_LEAF_NODE_ESTIMATE    = 29;
  SQL_DELETE_SEGDIR_ENTRY       = 30;
  SQL_SHIFT_SEGDIR_ENTRY        = 31;
  SQL_SELECT_SEGDIR             = 32;
  SQL_CHOMP_SEGDIR              = 33;
  SQL_SEGMENT_IS_APPENDABLE     = 34;
  SQL_SELECT_INDEXES            = 35;
  SQL_SELECT_MXLEVEL            = 36;
  SQL_SELECT_LEVEL_RANGE2       = 37;
  SQL_UPDATE_LEVEL_IDX          = 38;
  SQL_UPDATE_LEVEL              = 39;

  { fts3_write.c:73..75 — %_stat row-ids bound to :1 of REPLACE/SELECT_STAT. }
  FTS_STAT_DOCTOTAL      = 0;
  FTS_STAT_INCRMERGEHINT = 1;
  FTS_STAT_AUTOINCRMERGE = 2;

{ --------------------------------------------------------------------- }
{ fts3.h:22 — declares the FTS3 library entry point.  Implemented in    }
{ task 6.40.1.o; here only as the public signature the cluster targets. }
{ --------------------------------------------------------------------- }
{ function sqlite3Fts3Init(db: Psqlite3): cint;  -- forward, see 6.40.1.o }

{ --------------------------------------------------------------------- }
{ fts3_hash.h:74..78 — access routines.  To delete, insert a NULL ptr.  }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3HashInit(pNew: PFts3Hash; keyClass: cchar; copyKey: cchar);
function  sqlite3Fts3HashInsert(pH: PFts3Hash; const pKey: Pointer; nKey: cint;
  data: Pointer): Pointer;
function  sqlite3Fts3HashFind(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint): Pointer;
procedure sqlite3Fts3HashClear(pH: PFts3Hash);
function  sqlite3Fts3HashFindElem(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint): PFts3HashElem;

{ fts3_hash.h:101..110 — macro-style accessors, ported as inline helpers. }
function fts3HashFirst(const H: PFts3Hash): PFts3HashElem; inline;
function fts3HashNext(const E: PFts3HashElem): PFts3HashElem; inline;
function fts3HashData(const E: PFts3HashElem): Pointer; inline;
function fts3HashKey(const E: PFts3HashElem): Pointer; inline;
function fts3HashKeysize(const E: PFts3HashElem): cint; inline;
function fts3HashCount(const H: PFts3Hash): cint; inline;

{ --------------------------------------------------------------------- }
{ 6.40.1.c — fts3_tokenizer1.c:228..232 — the built-in "simple"         }
{ tokenizer module entry point.                                          }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3SimpleTokenizerModule(ppModule: PPsqlite3_tokenizer_module);

{ --------------------------------------------------------------------- }
{ 6.40.1.d — fts3_porter.c:656..660 — the "porter" stemmer tokenizer    }
{ module entry point.                                                    }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3PorterTokenizerModule(ppModule: PPsqlite3_tokenizer_module);

{ --------------------------------------------------------------------- }
{ 6.40.1.e — fts3_unicode2.c — Unicode codepoint classification.         }
{ --------------------------------------------------------------------- }
function sqlite3FtsUnicodeIsalnum(c: cint): cint;
function sqlite3FtsUnicodeIsdiacritic(c: cint): cint;
function sqlite3FtsUnicodeFold(c: cint; eRemoveDiacritic: cint): cint;

{ --------------------------------------------------------------------- }
{ 6.40.1.f — fts3_unicode.c:383..394 — the "unicode61" tokenizer module  }
{ entry point.                                                           }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3UnicodeTokenizer(ppModule: PPsqlite3_tokenizer_module);

{ --------------------------------------------------------------------- }
{ 6.40.1.g — fts3_tokenizer.c — the generic tokenizer registry.          }
{ --------------------------------------------------------------------- }

{ fts3_tokenizer.c:114..126 — true if c is a tokenizer-name identifier char. }
function sqlite3Fts3IsIdChar(c: cchar): cint;

{ fts3_tokenizer.c:128..163 — return the start of the next token in zStr,
  setting pn^ to its length; nil when no more tokens. }
function sqlite3Fts3NextToken(const zStr: PChar; pn: Pcint): PChar;

{ fts3_tokenizer.c:165..224 — resolve a tokenizer by name from pHash and
  build it from the parsed argument list. }
function sqlite3Fts3InitTokenizer(pHash: PFts3Hash; const zArg: PChar;
  ppTok: PPsqlite3_tokenizer; pzErr: PPChar): cint;

{ fts3_tokenizer.c:473..end — install the fts3_tokenizer SQL function (and,
  under SQLITE_TEST, fts3_tokenizer_test / _internal_test) with pHash as
  user-data. }
function sqlite3Fts3InitHashTable(db: PTsqlite3; pHash: PFts3Hash;
  const zName: PChar): cint;

{ --------------------------------------------------------------------- }
{ 6.40.1.h — fts3_tokenize_vtab.c:423 — register the "fts3tokenize"        }
{ virtual-table module on db.  pHash is the tokenizer hash (passed as the  }
{ module's pAux); xDestroy is the nRef-guarded hashDestroy.                }
{ --------------------------------------------------------------------- }
function sqlite3Fts3InitTok(db: PTsqlite3; pHash: PFts3Hash;
  xDestroy: TxModuleDestroy): cint;

{ --------------------------------------------------------------------- }
{ 6.40.1.g (down-payment on 6.40.1.o) — minimal sqlite3Fts3Init: alloc    }
{ the tokenizer-hash wrapper, load simple/porter/unicode61, and install   }
{ the fts3_tokenizer SQL function(s) via sqlite3Fts3InitHashTable AND, as   }
{ of 6.40.1.h, the fts3tokenize VTAB module via sqlite3Fts3InitTok.  Does   }
{ NOT register the fts3/fts4 VTAB modules — those land in 6.40.1.k/.o.      }
{ fts3.c:4102 (partial port).                                             }
{ --------------------------------------------------------------------- }
function sqlite3Fts3Init(db: PTsqlite3): cint;

{ --------------------------------------------------------------------- }
{ 6.40.1.i — fts3_expr.c — the MATCH query-expression parser.            }
{ --------------------------------------------------------------------- }

{ fts3_expr.c:125..129 — allocate nByte bytes, zero them, return ptr (or nil). }
function sqlite3Fts3MallocZero(nByte: sqlite3_int64): Pointer;

{ fts3_expr.c:131..156 — open a tokenizer cursor over z[0..n).  This is the
  REAL opener (replacing the .g local stub sqlite3Fts3OpenTokenizerLocal). }
function sqlite3Fts3OpenTokenizer(pTokenizer: Psqlite3_tokenizer;
  iLangid: cint; const z: PChar; n: cint;
  ppCsr: PPsqlite3_tokenizer_cursor): cint;

{ fts3_expr.c:1048..1087 — parse a MATCH query expression into an Fts3Expr
  tree.  azCol[] holds nCol column names; iDefaultCol is the default column
  (or -1 for "any").  Rebalances and depth-checks the result. }
function sqlite3Fts3ExprParse(pTokenizer: Psqlite3_tokenizer; iLangid: cint;
  azCol: PPChar; bFts4: cint; nCol: cint; iDefaultCol: cint;
  const z: PChar; n: cint; ppExpr: PPFts3Expr; pzErr: PPChar): cint;

{ fts3_expr.c:1106..1125 — free a parsed Fts3Expr tree (iterative, so a deep
  tree cannot overflow the stack). }
procedure sqlite3Fts3ExprFree(pDel: PFts3Expr);

{ --------------------------------------------------------------------- }
{ 6.40.1.j — fts3_write.c — segment writer/reader/merge core + xUpdate.   }
{ Public surface (fts3Int.h:524..695).  Functions whose primary caller is  }
{ fts3.c (.k) / fts3_snippet.c (.l) / fts3_aux.c (.m) are declared here so   }
{ those tasks can call them once landed.                                   }
{ --------------------------------------------------------------------- }

{ fts3.c:331..442 — FTS3 varint codecs (defined in fts3.c in C; ported here
  since fts3_write.c depends on them — owner of these is fts3.c/6.40.1.k,
  but they live here and .k must NOT duplicate them). }
function sqlite3Fts3PutVarint(p: PChar; v: sqlite3_int64): cint;
function sqlite3Fts3GetVarintU(const pBuf: PChar; v: Pu64): cint;
function sqlite3Fts3GetVarint(const pBuf: PChar; v: Psqlite3_int64): cint;
function sqlite3Fts3GetVarintBounded(const pBuf, pEnd: PChar;
  v: Psqlite3_int64): cint;
function sqlite3Fts3GetVarint32(const p: PChar; pi: Pcint): cint;
function sqlite3Fts3VarintLen(v: u64): cint;

{ fts3_write.c:280..292 — sqlite3Fts3PrepareStmt. }
function sqlite3Fts3PrepareStmt(p: PFts3Table; const zSql: PChar;
  bPersist: cint; bAllowVtab: cint; pp: PPVdbe): cint;

{ fts3_write.c — pending-terms + flush write path. }
function sqlite3Fts3PendingTermsFlush(p: PFts3Table): cint;
procedure sqlite3Fts3PendingTermsClear(p: PFts3Table);

{ fts3_write.c — %_segments / %_segdir helpers used by fts3.c / fts3_aux.c. }
function sqlite3Fts3ReadBlock(p: PFts3Table; iBlockid: sqlite3_int64;
  paBlob: PPChar; pnBlob: Pcint; pnLoad: Pcint): cint;
procedure sqlite3Fts3SegmentsClose(p: PFts3Table);
function sqlite3Fts3AllSegdirs(p: PFts3Table; iLangid, iIndex, iLevel: cint;
  ppStmt: PPVdbe): cint;
function sqlite3Fts3MaxLevel(p: PFts3Table; pnMax: Pcint): cint;
function sqlite3Fts3SelectDoctotal(pTab: PFts3Table; ppStmt: PPVdbe): cint;
function sqlite3Fts3SelectDocsize(pTab: PFts3Table; iDocid: sqlite3_int64;
  ppStmt: PPVdbe): cint;

{ fts3_write.c — segment-reader (multi-way merge) public API. }
function sqlite3Fts3SegReaderNew(iAge, bLookup: cint; iStartLeaf, iEndLeaf,
  iEndBlock: sqlite3_int64; const zRoot: PChar; nRoot: cint;
  ppReader: PPFts3SegReader): cint;
function sqlite3Fts3SegReaderPending(p: PFts3Table; iIndex: cint;
  const zTerm: PChar; nTerm: cint; bPrefix: cint;
  ppReader: PPFts3SegReader): cint;
procedure sqlite3Fts3SegReaderFree(pReader: PFts3SegReader);
function sqlite3Fts3SegReaderStart(p: PFts3Table; pCsr: PFts3MultiSegReader;
  pFilter: PFts3SegFilter): cint;
function sqlite3Fts3SegReaderStep(p: PFts3Table; pCsr: PFts3MultiSegReader): cint;
procedure sqlite3Fts3SegReaderFinish(pCsr: PFts3MultiSegReader);

function sqlite3Fts3MsrIncrStart(p: PFts3Table; pCsr: PFts3MultiSegReader;
  iCol: cint; const zTerm: PChar; nTerm: cint): cint;
function sqlite3Fts3MsrIncrNext(p: PFts3Table; pMsr: PFts3MultiSegReader;
  piDocid: Psqlite3_int64; paPoslist: PPChar; pnPoslist: Pcint): cint;
function sqlite3Fts3MsrIncrRestart(pCsr: PFts3MultiSegReader): cint;
function sqlite3Fts3MsrOvfl(pCsr: PFts3Cursor; pMsr: PFts3MultiSegReader;
  pnOvfl: Pcint): cint;

{ fts3_write.c — xUpdate + maintenance. }
function sqlite3Fts3UpdateMethod(pVtab: PSqlite3Vtab; nArg: cint;
  apVal: PPsqlite3_value; pRowid: Psqlite3_int64): cint;
function sqlite3Fts3Optimize(p: PFts3Table): cint;
function sqlite3Fts3Incrmerge(p: PFts3Table; nMerge, nMin: cint): cint;
function sqlite3Fts3IntegrityCheck(p: PFts3Table; pbOk: Pcint): cint;

{ fts3_write.c — deferred-token machinery (SQLITE_DISABLE_FTS4_DEFERRED off). }
procedure sqlite3Fts3FreeDeferredDoclists(pCsr: PFts3Cursor);
procedure sqlite3Fts3FreeDeferredTokens(pCsr: PFts3Cursor);
function sqlite3Fts3CacheDeferredDoclists(pCsr: PFts3Cursor): cint;
function sqlite3Fts3DeferredTokenList(p: PFts3DeferredTokenR;
  ppData: PPChar; pnData: Pcint): cint;
function sqlite3Fts3DeferToken(pCsr: PFts3Cursor; pToken: PFts3PhraseToken;
  iCol: cint): cint;

{ fts3_write.c:609..611 — fts3GetVarint32 macro: if high bit set use the slow
  path, else inline single-byte read. }
function fts3GetVarint32(const p: PChar; piVal: Pcint): cint; inline;

implementation

{ libc bindings (match the amatch/fuzzer pattern; avoids depending on a
  csize_t alias from elsewhere). }
function libc_strlen(s: PChar): NativeUInt; cdecl; external 'c' name 'strlen';
function libc_memcpy(dst, src: Pointer; n: NativeUInt): Pointer; cdecl;
  external 'c' name 'memcpy';
procedure libc_memset(dst: Pointer; c: cint; n: NativeUInt); cdecl;
  external 'c' name 'memset';
function libc_strncmp(a, b: PChar; n: NativeUInt): cint; cdecl;
  external 'c' name 'strncmp';
function libc_strcmp(a, b: PChar): cint; cdecl; external 'c' name 'strcmp';
function libc_memcmp(a, b: Pointer; n: NativeUInt): cint; cdecl;
  external 'c' name 'memcmp';
function libc_atoi(s: PChar): cint; cdecl; external 'c' name 'atoi';

{ Function-pointer types for the key-class-selected hash/compare fns. }
type
  TFts3HashFn    = function(const pKey: Pointer; nKey: cint): cint;
  TFts3CompareFn = function(const pKey1: Pointer; n1: cint;
    const pKey2: Pointer; n2: cint): cint;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:38..47 — Malloc and Free functions.                       }
{ --------------------------------------------------------------------- }
function fts3HashMalloc(n: sqlite3_int64): Pointer;
begin
  Result := sqlite3_malloc64(u64(n));
  if Result <> nil then
    libc_memset(Result, 0, NativeUInt(n));
end;

procedure fts3HashFree(p: Pointer);
begin
  sqlite3_free(p);
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:59..68 — sqlite3Fts3HashInit.                             }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3HashInit(pNew: PFts3Hash; keyClass: cchar; copyKey: cchar);
begin
  Assert(pNew <> nil);
  Assert((keyClass >= FTS3_HASH_STRING) and (keyClass <= FTS3_HASH_BINARY));
  pNew^.keyClass := keyClass;
  pNew^.copyKey := copyKey;
  pNew^.first := nil;
  pNew^.count := 0;
  pNew^.htsize := 0;
  pNew^.ht := nil;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:74..92 — sqlite3Fts3HashClear.  Remove all entries and    }
{ reclaim all memory.                                                   }
{ --------------------------------------------------------------------- }
procedure sqlite3Fts3HashClear(pH: PFts3Hash);
var
  elem, next_elem: PFts3HashElem;
begin
  Assert(pH <> nil);
  elem := pH^.first;
  pH^.first := nil;
  fts3HashFree(pH^.ht);
  pH^.ht := nil;
  pH^.htsize := 0;
  while elem <> nil do begin
    next_elem := elem^.next;
    if (pH^.copyKey <> 0) and (elem^.pKey <> nil) then
      fts3HashFree(elem^.pKey);
    fts3HashFree(elem);
    elem := next_elem;
  end;
  pH^.count := 0;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:97..106 — fts3StrHash (FTS3_HASH_STRING).                  }
{ --------------------------------------------------------------------- }
function fts3StrHash(const pKey: Pointer; nKey: cint): cint;
var
  z: PByte;
  h: cuint;
begin
  z := PByte(pKey);
  h := 0;
  if nKey <= 0 then nKey := cint(libc_strlen(PChar(pKey)));
  while nKey > 0 do begin
    h := (h shl 3) xor h xor cuint(z^);
    Inc(z);
    Dec(nKey);
  end;
  Result := cint(h and $7fffffff);
end;

{ fts3_hash.c:107..110 — fts3StrCompare. }
function fts3StrCompare(const pKey1: Pointer; n1: cint;
  const pKey2: Pointer; n2: cint): cint;
begin
  if n1 <> n2 then Exit(1);
  Result := libc_strncmp(PChar(pKey1), PChar(pKey2), NativeUInt(n1));
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:115..122 — fts3BinHash (FTS3_HASH_BINARY).                 }
{ --------------------------------------------------------------------- }
function fts3BinHash(const pKey: Pointer; nKey: cint): cint;
var
  h: cint;
  z: PByte;
begin
  h := 0;
  z := PByte(pKey);
  while nKey > 0 do begin
    Dec(nKey);                 { C: while( nKey-- > 0 ) — test then decrement }
    h := (h shl 3) xor h xor cint(z^);
    Inc(z);
  end;
  Result := h and $7fffffff;
end;

{ fts3_hash.c:123..126 — fts3BinCompare. }
function fts3BinCompare(const pKey1: Pointer; n1: cint;
  const pKey2: Pointer; n2: cint): cint;
begin
  if n1 <> n2 then Exit(1);
  Result := libc_memcmp(pKey1, pKey2, NativeUInt(n1));
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:140..147 — ftsHashFunction: pick hash fn by key class.    }
{ --------------------------------------------------------------------- }
function ftsHashFunction(keyClass: cint): TFts3HashFn;
begin
  if keyClass = FTS3_HASH_STRING then
    Result := @fts3StrHash
  else begin
    Assert(keyClass = FTS3_HASH_BINARY);
    Result := @fts3BinHash;
  end;
end;

{ fts3_hash.c:155..162 — ftsCompareFunction: pick compare fn by key class. }
function ftsCompareFunction(keyClass: cint): TFts3CompareFn;
begin
  if keyClass = FTS3_HASH_STRING then
    Result := @fts3StrCompare
  else begin
    Assert(keyClass = FTS3_HASH_BINARY);
    Result := @fts3BinCompare;
  end;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:166..187 — fts3HashInsertElement: link an element in.     }
{ --------------------------------------------------------------------- }
procedure fts3HashInsertElement(pH: PFts3Hash; pEntry: PFts3Ht;
  pNew: PFts3HashElem);
var
  pHead: PFts3HashElem;
begin
  pHead := pEntry^.chain;
  if pHead <> nil then begin
    pNew^.next := pHead;
    pNew^.prev := pHead^.prev;
    if pHead^.prev <> nil then
      pHead^.prev^.next := pNew
    else
      pH^.first := pNew;
    pHead^.prev := pNew;
  end else begin
    pNew^.next := pH^.first;
    if pH^.first <> nil then
      pH^.first^.prev := pNew;
    pNew^.prev := nil;
    pH^.first := pNew;
  end;
  Inc(pEntry^.count);
  pEntry^.chain := pNew;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:196..214 — fts3Rehash: resize the table to new_size       }
{ buckets (a power of 2).  Returns non-zero on malloc failure.          }
{ --------------------------------------------------------------------- }
function fts3Rehash(pH: PFts3Hash; new_size: cint): cint;
var
  new_ht: PFts3Ht;
  elem, next_elem: PFts3HashElem;
  xHash: TFts3HashFn;
  h: cint;
begin
  Assert((new_size and (new_size - 1)) = 0);
  new_ht := PFts3Ht(fts3HashMalloc(sqlite3_int64(new_size) * SizeOf(TFts3Ht)));
  if new_ht = nil then Exit(1);
  fts3HashFree(pH^.ht);
  pH^.ht := new_ht;
  pH^.htsize := new_size;
  xHash := ftsHashFunction(pH^.keyClass);
  elem := pH^.first;
  pH^.first := nil;
  while elem <> nil do begin
    h := xHash(elem^.pKey, elem^.nKey) and (new_size - 1);
    next_elem := elem^.next;
    fts3HashInsertElement(pH, @new_ht[h], elem);
    elem := next_elem;
  end;
  Result := 0;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:220..243 — fts3FindElementByHash.                         }
{ --------------------------------------------------------------------- }
function fts3FindElementByHash(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint; h: cint): PFts3HashElem;
var
  elem: PFts3HashElem;
  count: cint;
  xCompare: TFts3CompareFn;
  pEntry: PFts3Ht;
begin
  if pH^.ht <> nil then begin
    pEntry := @pH^.ht[h];
    elem := pEntry^.chain;
    count := pEntry^.count;
    xCompare := ftsCompareFunction(pH^.keyClass);
    { C: while( count-- && elem ) — post-decrement, short-circuit }
    while (count > 0) and (elem <> nil) do begin
      Dec(count);
      if xCompare(elem^.pKey, elem^.nKey, pKey, nKey) = 0 then
        Exit(elem);
      elem := elem^.next;
    end;
  end;
  Result := nil;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:248..280 — fts3RemoveElementByHash.                       }
{ --------------------------------------------------------------------- }
procedure fts3RemoveElementByHash(pH: PFts3Hash; elem: PFts3HashElem; h: cint);
var
  pEntry: PFts3Ht;
begin
  if elem^.prev <> nil then
    elem^.prev^.next := elem^.next
  else
    pH^.first := elem^.next;
  if elem^.next <> nil then
    elem^.next^.prev := elem^.prev;
  pEntry := @pH^.ht[h];
  if pEntry^.chain = elem then
    pEntry^.chain := elem^.next;
  Dec(pEntry^.count);
  if pEntry^.count <= 0 then
    pEntry^.chain := nil;
  if (pH^.copyKey <> 0) and (elem^.pKey <> nil) then
    fts3HashFree(elem^.pKey);
  fts3HashFree(elem);
  Dec(pH^.count);
  if pH^.count <= 0 then begin
    Assert(pH^.first = nil);
    Assert(pH^.count = 0);
    sqlite3Fts3HashClear(pH);
  end;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:282..296 — sqlite3Fts3HashFindElem.                       }
{ --------------------------------------------------------------------- }
function sqlite3Fts3HashFindElem(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint): PFts3HashElem;
var
  h: cint;
  xHash: TFts3HashFn;
begin
  if (pH = nil) or (pH^.ht = nil) then Exit(nil);
  xHash := ftsHashFunction(pH^.keyClass);
  Assert(xHash <> nil);
  h := xHash(pKey, nKey);
  Assert((pH^.htsize and (pH^.htsize - 1)) = 0);
  Result := fts3FindElementByHash(pH, pKey, nKey, h and (pH^.htsize - 1));
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:303..308 — sqlite3Fts3HashFind.                           }
{ --------------------------------------------------------------------- }
function sqlite3Fts3HashFind(const pH: PFts3Hash; const pKey: Pointer;
  nKey: cint): Pointer;
var
  pElem: PFts3HashElem;
begin
  pElem := sqlite3Fts3HashFindElem(pH, pKey, nKey);
  if pElem <> nil then
    Result := pElem^.data
  else
    Result := nil;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.c:325..381 — sqlite3Fts3HashInsert.                         }
{ --------------------------------------------------------------------- }
function sqlite3Fts3HashInsert(pH: PFts3Hash; const pKey: Pointer; nKey: cint;
  data: Pointer): Pointer;
var
  hraw: cint;             { Raw hash value of the key }
  h: cint;                { the hash of the key modulo hash table size }
  elem: PFts3HashElem;
  new_elem: PFts3HashElem;
  xHash: TFts3HashFn;
  old_data: Pointer;
begin
  Assert(pH <> nil);
  xHash := ftsHashFunction(pH^.keyClass);
  Assert(xHash <> nil);
  hraw := xHash(pKey, nKey);
  Assert((pH^.htsize and (pH^.htsize - 1)) = 0);
  h := hraw and (pH^.htsize - 1);
  elem := fts3FindElementByHash(pH, pKey, nKey, h);
  if elem <> nil then begin
    old_data := elem^.data;
    if data = nil then
      fts3RemoveElementByHash(pH, elem, h)
    else
      elem^.data := data;
    Exit(old_data);
  end;
  if data = nil then Exit(nil);
  if ((pH^.htsize = 0) and (fts3Rehash(pH, 8) <> 0))
  or ((pH^.count >= pH^.htsize) and (fts3Rehash(pH, pH^.htsize * 2) <> 0)) then
  begin
    pH^.count := 0;
    Exit(data);
  end;
  Assert(pH^.htsize > 0);
  new_elem := PFts3HashElem(fts3HashMalloc(SizeOf(TFts3HashElem)));
  if new_elem = nil then Exit(data);
  if (pH^.copyKey <> 0) and (pKey <> nil) then begin
    new_elem^.pKey := fts3HashMalloc(nKey);
    if new_elem^.pKey = nil then begin
      fts3HashFree(new_elem);
      Exit(data);
    end;
    libc_memcpy(new_elem^.pKey, pKey, NativeUInt(nKey));
  end else
    new_elem^.pKey := pKey;
  new_elem^.nKey := nKey;
  Inc(pH^.count);
  Assert(pH^.htsize > 0);
  Assert((pH^.htsize and (pH^.htsize - 1)) = 0);
  h := hraw and (pH^.htsize - 1);
  fts3HashInsertElement(pH, @pH^.ht[h], new_elem);
  new_elem^.data := data;
  Result := nil;
end;

{ --------------------------------------------------------------------- }
{ fts3_hash.h:101..110 — macro-style accessors.                         }
{ --------------------------------------------------------------------- }
function fts3HashFirst(const H: PFts3Hash): PFts3HashElem;
begin
  Result := H^.first;
end;

function fts3HashNext(const E: PFts3HashElem): PFts3HashElem;
begin
  Result := E^.next;
end;

function fts3HashData(const E: PFts3HashElem): Pointer;
begin
  Result := E^.data;
end;

function fts3HashKey(const E: PFts3HashElem): Pointer;
begin
  Result := E^.pKey;
end;

function fts3HashKeysize(const E: PFts3HashElem): cint;
begin
  Result := E^.nKey;
end;

function fts3HashCount(const H: PFts3Hash): cint;
begin
  Result := H^.count;
end;

{ ===================================================================== }
{ 6.40.1.c — fts3_tokenizer1.c — the built-in "simple" tokenizer.        }
{ ===================================================================== }

type
  { fts3_tokenizer1.c:35..38 — struct simple_tokenizer.
    Derives from sqlite3_tokenizer; appends a 128-byte ASCII delimiter
    flag array.  delim[c] is non-zero when c is a delimiter. }
  Psimple_tokenizer = ^Tsimple_tokenizer;
  Tsimple_tokenizer = record
    base  : Tsqlite3_tokenizer;
    delim : array[0..127] of cchar;   { flag ASCII delimiters }
  end;

  { fts3_tokenizer1.c:40..48 — struct simple_tokenizer_cursor. }
  Psimple_tokenizer_cursor = ^Tsimple_tokenizer_cursor;
  Tsimple_tokenizer_cursor = record
    base            : Tsqlite3_tokenizer_cursor;
    pInput          : PChar;  { input we are tokenizing }
    nBytes          : cint;   { size of the input }
    iOffset         : cint;   { current position in pInput }
    iToken          : cint;   { index of next token to be returned }
    pToken          : PChar;  { storage for current token }
    nTokenAllocated : cint;   { space allocated to zToken buffer }
  end;

{ fts3_tokenizer1.c:51..53 — simpleDelim. }
function simpleDelim(t: Psimple_tokenizer; c: Byte): cint;
begin
  if (c < $80) and (t^.delim[c] <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_tokenizer1.c:54..56 — fts3_isalnum. }
function fts3_isalnum(x: cint): cint;
begin
  if ((x >= Ord('0')) and (x <= Ord('9')))
  or ((x >= Ord('A')) and (x <= Ord('Z')))
  or ((x >= Ord('a')) and (x <= Ord('z'))) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_tokenizer1.c:61..97 — simpleCreate. }
function simpleCreate(argc: cint; const argv: PPChar;
  ppTokenizer: PPsqlite3_tokenizer): cint; cdecl;
var
  t  : Psimple_tokenizer;
  i, n : cint;
  ch : Byte;
  pArg : PChar;
begin
  t := Psimple_tokenizer(sqlite3_malloc(i32(SizeOf(Tsimple_tokenizer))));
  if t = nil then Exit(SQLITE_NOMEM);
  libc_memset(t, 0, NativeUInt(SizeOf(Tsimple_tokenizer)));

  { TODO(shess) Delimiters need to remain the same from run to run, else
    we need to reindex. }
  if argc > 1 then begin
    pArg := PPChar(argv)[1];
    n := cint(libc_strlen(pArg));
    i := 0;
    while i < n do begin
      ch := Byte(pArg[i]);
      { We explicitly don't support UTF-8 delimiters for now. }
      if ch >= $80 then begin
        sqlite3_free(t);
        Exit(SQLITE_ERROR);
      end;
      t^.delim[ch] := 1;
      Inc(i);
    end;
  end else begin
    { Mark non-alphanumeric ASCII characters as delimiters }
    i := 1;
    while i < $80 do begin
      if fts3_isalnum(i) = 0 then
        t^.delim[i] := cchar(-1)
      else
        t^.delim[i] := 0;
      Inc(i);
    end;
  end;

  ppTokenizer^ := @t^.base;
  Result := SQLITE_OK;
end;

{ fts3_tokenizer1.c:102..105 — simpleDestroy. }
function simpleDestroy(pTokenizer: Psqlite3_tokenizer): cint; cdecl;
begin
  sqlite3_free(pTokenizer);
  Result := SQLITE_OK;
end;

{ fts3_tokenizer1.c:113..140 — simpleOpen. }
function simpleOpen(pTokenizer: Psqlite3_tokenizer; const pInput: PChar;
  nBytes: cint; ppCursor: PPsqlite3_tokenizer_cursor): cint; cdecl;
var
  c: Psimple_tokenizer_cursor;
begin
  { UNUSED_PARAMETER(pTokenizer) }
  c := Psimple_tokenizer_cursor(sqlite3_malloc(i32(SizeOf(Tsimple_tokenizer_cursor))));
  if c = nil then Exit(SQLITE_NOMEM);

  c^.pInput := pInput;
  if pInput = nil then
    c^.nBytes := 0
  else if nBytes < 0 then
    c^.nBytes := cint(libc_strlen(pInput))
  else
    c^.nBytes := nBytes;
  c^.iOffset := 0;                 { start tokenizing at the beginning }
  c^.iToken := 0;
  c^.pToken := nil;                { no space allocated, yet. }
  c^.nTokenAllocated := 0;

  ppCursor^ := @c^.base;
  Result := SQLITE_OK;
end;

{ fts3_tokenizer1.c:146..151 — simpleClose. }
function simpleClose(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;
var
  c: Psimple_tokenizer_cursor;
begin
  c := Psimple_tokenizer_cursor(pCursor);
  sqlite3_free(c^.pToken);
  sqlite3_free(c);
  Result := SQLITE_OK;
end;

{ fts3_tokenizer1.c:157..209 — simpleNext. }
function simpleNext(pCursor: Psqlite3_tokenizer_cursor;
  ppToken: PPChar; pnBytes: Pcint;
  piStartOffset: Pcint; piEndOffset: Pcint; piPosition: Pcint): cint; cdecl;
var
  c: Psimple_tokenizer_cursor;
  t: Psimple_tokenizer;
  p: PByte;
  iStartOffset, i, n: cint;
  pNew: PChar;
  ch: Byte;
begin
  c := Psimple_tokenizer_cursor(pCursor);
  t := Psimple_tokenizer(pCursor^.pTokenizer);
  p := PByte(c^.pInput);

  while c^.iOffset < c^.nBytes do begin
    { Scan past delimiter characters }
    while (c^.iOffset < c^.nBytes) and (simpleDelim(t, p[c^.iOffset]) <> 0) do
      Inc(c^.iOffset);

    { Count non-delimiter characters. }
    iStartOffset := c^.iOffset;
    while (c^.iOffset < c^.nBytes) and (simpleDelim(t, p[c^.iOffset]) = 0) do
      Inc(c^.iOffset);

    if c^.iOffset > iStartOffset then begin
      n := c^.iOffset - iStartOffset;
      if n > c^.nTokenAllocated then begin
        c^.nTokenAllocated := n + 20;
        pNew := PChar(sqlite3_realloc64(c^.pToken, u64(c^.nTokenAllocated)));
        if pNew = nil then Exit(SQLITE_NOMEM);
        c^.pToken := pNew;
      end;
      for i := 0 to n - 1 do begin
        { TODO(shess) UTF-8 case-insensitivity. }
        ch := p[iStartOffset + i];
        if (ch >= Ord('A')) and (ch <= Ord('Z')) then
          c^.pToken[i] := Chr(ch - Ord('A') + Ord('a'))
        else
          c^.pToken[i] := Chr(ch);
      end;
      ppToken^ := c^.pToken;
      pnBytes^ := n;
      piStartOffset^ := iStartOffset;
      piEndOffset^ := c^.iOffset;
      piPosition^ := c^.iToken;
      Inc(c^.iToken);
      Exit(SQLITE_OK);
    end;
  end;
  Result := SQLITE_DONE;
end;

{ fts3_tokenizer1.c:214..222 — the static simpleTokenizerModule record. }
const
  simpleTokenizerModule: Tsqlite3_tokenizer_module = (
    iVersion    : 0;
    xCreate     : @simpleCreate;
    xDestroy    : @simpleDestroy;
    xOpen       : @simpleOpen;
    xClose      : @simpleClose;
    xNext       : @simpleNext;
    xLanguageid : nil;
  );

{ fts3_tokenizer1.c:228..232 — sqlite3Fts3SimpleTokenizerModule. }
procedure sqlite3Fts3SimpleTokenizerModule(ppModule: PPsqlite3_tokenizer_module);
begin
  ppModule^ := @simpleTokenizerModule;
end;

{ ===================================================================== }
{ 6.40.1.d — fts3_porter.c — the "porter" stemmer tokenizer.            }
{ ===================================================================== }

type
  { fts3_porter.c:38..40 — struct porter_tokenizer. }
  Pporter_tokenizer = ^Tporter_tokenizer;
  Tporter_tokenizer = record
    base : Tsqlite3_tokenizer;   { Base class }
  end;

  { fts3_porter.c:45..53 — struct porter_tokenizer_cursor. }
  Pporter_tokenizer_cursor = ^Tporter_tokenizer_cursor;
  Tporter_tokenizer_cursor = record
    base       : Tsqlite3_tokenizer_cursor;
    zInput     : PChar;   { input we are tokenizing }
    nInput     : cint;    { size of the input }
    iOffset    : cint;    { current position in zInput }
    iToken     : cint;    { index of next token to be returned }
    zToken     : PChar;   { storage for current token }
    nAllocated : cint;    { space allocated to zToken buffer }
  end;

{ fts3_porter.c:59..73 — porterCreate. }
function porterCreate(argc: cint; const argv: PPChar;
  ppTokenizer: PPsqlite3_tokenizer): cint; cdecl;
var
  t: Pporter_tokenizer;
begin
  { UNUSED_PARAMETER(argc); UNUSED_PARAMETER(argv) }
  t := Pporter_tokenizer(sqlite3_malloc(i32(SizeOf(Tporter_tokenizer))));
  if t = nil then Exit(SQLITE_NOMEM);
  libc_memset(t, 0, NativeUInt(SizeOf(Tporter_tokenizer)));
  ppTokenizer^ := @t^.base;
  Result := SQLITE_OK;
end;

{ fts3_porter.c:78..81 — porterDestroy. }
function porterDestroy(pTokenizer: Psqlite3_tokenizer): cint; cdecl;
begin
  sqlite3_free(pTokenizer);
  Result := SQLITE_OK;
end;

{ fts3_porter.c:89..116 — porterOpen. }
function porterOpen(pTokenizer: Psqlite3_tokenizer; const zInput: PChar;
  nInput: cint; ppCursor: PPsqlite3_tokenizer_cursor): cint; cdecl;
var
  c: Pporter_tokenizer_cursor;
begin
  { UNUSED_PARAMETER(pTokenizer) }
  c := Pporter_tokenizer_cursor(sqlite3_malloc(i32(SizeOf(Tporter_tokenizer_cursor))));
  if c = nil then Exit(SQLITE_NOMEM);

  c^.zInput := zInput;
  if zInput = nil then
    c^.nInput := 0
  else if nInput < 0 then
    c^.nInput := cint(libc_strlen(zInput))
  else
    c^.nInput := nInput;
  c^.iOffset := 0;                 { start tokenizing at the beginning }
  c^.iToken := 0;
  c^.zToken := nil;                { no space allocated, yet. }
  c^.nAllocated := 0;

  ppCursor^ := @c^.base;
  Result := SQLITE_OK;
end;

{ fts3_porter.c:122..127 — porterClose. }
function porterClose(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;
var
  c: Pporter_tokenizer_cursor;
begin
  c := Pporter_tokenizer_cursor(pCursor);
  sqlite3_free(c^.zToken);
  sqlite3_free(c);
  Result := SQLITE_OK;
end;

{ fts3_porter.c:131..134 — Vowel or consonant table.
  Indexed by letter-'a' (0..25); value 0=vowel,1=consonant,2='y'. }
const
  cType: array[0..25] of cint = (
     0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0,
     1, 1, 1, 2, 1
  );

{ Forward declaration (fts3_porter.c:149: static int isVowel(const char*)). }
function isVowel(const z: PChar): cint; forward;

{ fts3_porter.c:150..158 — isConsonant.  z[] is in reverse order. }
function isConsonant(const z: PChar): cint;
var
  j: cint;
  x: Char;
begin
  x := z^;
  if x = #0 then Exit(0);
  Assert((x >= 'a') and (x <= 'z'));
  j := cType[Ord(x) - Ord('a')];
  if j < 2 then Exit(j);
  if (z[1] = #0) or (isVowel(z + 1) <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_porter.c:159..167 — isVowel. }
function isVowel(const z: PChar): cint;
var
  j: cint;
  x: Char;
begin
  x := z^;
  if x = #0 then Exit(0);
  Assert((x >= 'a') and (x <= 'z'));
  j := cType[Ord(x) - Ord('a')];
  if j < 2 then Exit(1 - j);
  Result := isConsonant(z + 1);
end;

{ fts3_porter.c:188..193 — m_gt_0: true if m-value is 1 or more. }
function m_gt_0(const z: PChar): cint;
var
  p: PChar;
begin
  p := z;
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ <> #0 then Result := 1 else Result := 0;
end;

{ fts3_porter.c:198..207 — m_eq_1: true if m-value is exactly 1. }
function m_eq_1(const z: PChar): cint;
var
  p: PChar;
begin
  p := z;
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(1);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ = #0 then Result := 1 else Result := 0;
end;

{ fts3_porter.c:212..221 — m_gt_1: true if m-value is greater than 1. }
function m_gt_1(const z: PChar): cint;
var
  p: PChar;
begin
  p := z;
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isVowel(p) <> 0 do Inc(p);
  if p^ = #0 then Exit(0);
  while isConsonant(p) <> 0 do Inc(p);
  if p^ <> #0 then Result := 1 else Result := 0;
end;

{ fts3_porter.c:226..229 — hasVowel. }
function hasVowel(const z: PChar): cint;
var
  p: PChar;
begin
  p := z;
  while isConsonant(p) <> 0 do Inc(p);
  if p^ <> #0 then Result := 1 else Result := 0;
end;

{ fts3_porter.c:237..239 — doubleConsonant.  Text is reversed. }
function doubleConsonant(const z: PChar): cint;
begin
  if (isConsonant(z) <> 0) and (z[0] = z[1]) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_porter.c:249..255 — star_oh.  Word is reversed. }
function star_oh(const z: PChar): cint;
begin
  if (isConsonant(z) <> 0)
  and (z[0] <> 'w') and (z[0] <> 'x') and (z[0] <> 'y')
  and (isVowel(z + 1) <> 0)
  and (isConsonant(z + 2) <> 0) then
    Result := 1
  else
    Result := 0;
end;

type
  { fts3_porter.c:273 — int (*xCond)(const char*). }
  TPorterCond = function(const z: PChar): cint;

{ fts3_porter.c:269..284 — stem.  *pz and zFrom are reversed; zTo is normal.
  Returns TRUE if zFrom matches (even when xCond fails and no substitution
  occurs). }
function stem(pz: PPChar; const zFrom: PChar; const zTo: PChar;
  xCond: TPorterCond): cint;
var
  z, pF, pT: PChar;
begin
  z := pz^;
  pF := zFrom;
  while (pF^ <> #0) and (pF^ = z^) do begin
    Inc(z);
    Inc(pF);
  end;
  if pF^ <> #0 then Exit(0);
  if (xCond <> nil) and (xCond(z) = 0) then Exit(1);
  pT := zTo;
  while pT^ <> #0 do begin
    Dec(z);
    z^ := pT^;
    Inc(pT);
  end;
  pz^ := z;
  Result := 1;
end;

{ fts3_porter.c:294..315 — copy_stemmer.  Fallback US-ASCII case-fold copy
  with long-word truncation. }
procedure copy_stemmer(const zIn: PChar; nIn: cint; zOut: PChar; pnOut: Pcint);
var
  i, mx, j: cint;
  hasDigit: cint;
  c: Char;
begin
  hasDigit := 0;
  for i := 0 to nIn - 1 do begin
    c := zIn[i];
    if (c >= 'A') and (c <= 'Z') then
      zOut[i] := Chr(Ord(c) - Ord('A') + Ord('a'))
    else begin
      if (c >= '0') and (c <= '9') then hasDigit := 1;
      zOut[i] := c;
    end;
  end;
  if hasDigit <> 0 then mx := 3 else mx := 10;
  i := nIn;
  if nIn > mx * 2 then begin
    j := mx;
    i := nIn - mx;
    while i < nIn do begin
      zOut[j] := zOut[i];
      Inc(i);
      Inc(j);
    end;
    i := j;
  end;
  zOut[i] := #0;
  pnOut^ := i;
end;

{ fts3_porter.c:341..572 — porter_stemmer. }
procedure porter_stemmer(const zIn: PChar; nIn: cint; zOut: PChar; pnOut: Pcint);
var
  i, j: cint;
  zReverse: array[0..27] of Char;
  z, z2: PChar;
  c: Char;
begin
  if (nIn < 3) or (nIn >= cint(SizeOf(zReverse)) - 7) then begin
    { Too big or too small for the porter stemmer; fall back to copy. }
    copy_stemmer(zIn, nIn, zOut, pnOut);
    Exit;
  end;
  i := 0;
  j := cint(SizeOf(zReverse)) - 6;
  while i < nIn do begin
    c := zIn[i];
    if (c >= 'A') and (c <= 'Z') then
      zReverse[j] := Chr(Ord(c) + Ord('a') - Ord('A'))
    else if (c >= 'a') and (c <= 'z') then
      zReverse[j] := c
    else begin
      { A character not in [a-zA-Z] → fall back to the copy stemmer. }
      copy_stemmer(zIn, nIn, zOut, pnOut);
      Exit;
    end;
    Inc(i);
    Dec(j);
  end;
  libc_memset(@zReverse[SizeOf(zReverse) - 5], 0, 5);
  z := @zReverse[j + 1];

  { Step 1a }
  if z[0] = 's' then begin
    if (stem(@z, 'sess', 'ss', nil) = 0)
    and (stem(@z, 'sei', 'i', nil) = 0)
    and (stem(@z, 'ss', 'ss', nil) = 0) then
      Inc(z);
  end;

  { Step 1b }
  z2 := z;
  if stem(@z, 'dee', 'ee', @m_gt_0) <> 0 then begin
    { Do nothing.  The work was all in the test }
  end else if ((stem(@z, 'gni', '', @hasVowel) <> 0)
            or (stem(@z, 'de', '', @hasVowel) <> 0))
           and (z <> z2) then begin
    if (stem(@z, 'ta', 'ate', nil) <> 0)
    or (stem(@z, 'lb', 'ble', nil) <> 0)
    or (stem(@z, 'zi', 'ize', nil) <> 0) then begin
      { Do nothing.  The work was all in the test }
    end else if (doubleConsonant(z) <> 0)
            and ((z^ <> 'l') and (z^ <> 's') and (z^ <> 'z')) then
      Inc(z)
    else if (m_eq_1(z) <> 0) and (star_oh(z) <> 0) then begin
      Dec(z);
      z^ := 'e';
    end;
  end;

  { Step 1c }
  if (z[0] = 'y') and (hasVowel(z + 1) <> 0) then
    z[0] := 'i';

  { Step 2 }
  case z[1] of
   'a':
     if stem(@z, 'lanoita', 'ate', @m_gt_0) = 0 then
       stem(@z, 'lanoit', 'tion', @m_gt_0);
   'c':
     if stem(@z, 'icne', 'ence', @m_gt_0) = 0 then
       stem(@z, 'icna', 'ance', @m_gt_0);
   'e':
     stem(@z, 'rezi', 'ize', @m_gt_0);
   'g':
     stem(@z, 'igol', 'log', @m_gt_0);
   'l':
     if (stem(@z, 'ilb', 'ble', @m_gt_0) = 0)
     and (stem(@z, 'illa', 'al', @m_gt_0) = 0)
     and (stem(@z, 'iltne', 'ent', @m_gt_0) = 0)
     and (stem(@z, 'ile', 'e', @m_gt_0) = 0) then
       stem(@z, 'ilsuo', 'ous', @m_gt_0);
   'o':
     if (stem(@z, 'noitazi', 'ize', @m_gt_0) = 0)
     and (stem(@z, 'noita', 'ate', @m_gt_0) = 0) then
       stem(@z, 'rota', 'ate', @m_gt_0);
   's':
     if (stem(@z, 'msila', 'al', @m_gt_0) = 0)
     and (stem(@z, 'ssenevi', 'ive', @m_gt_0) = 0)
     and (stem(@z, 'ssenluf', 'ful', @m_gt_0) = 0) then
       stem(@z, 'ssensuo', 'ous', @m_gt_0);
   't':
     if (stem(@z, 'itila', 'al', @m_gt_0) = 0)
     and (stem(@z, 'itivi', 'ive', @m_gt_0) = 0) then
       stem(@z, 'itilib', 'ble', @m_gt_0);
  end;

  { Step 3 }
  case z[0] of
   'e':
     if (stem(@z, 'etaci', 'ic', @m_gt_0) = 0)
     and (stem(@z, 'evita', '', @m_gt_0) = 0) then
       stem(@z, 'ezila', 'al', @m_gt_0);
   'i':
     stem(@z, 'itici', 'ic', @m_gt_0);
   'l':
     if stem(@z, 'laci', 'ic', @m_gt_0) = 0 then
       stem(@z, 'luf', '', @m_gt_0);
   's':
     stem(@z, 'ssen', '', @m_gt_0);
  end;

  { Step 4 }
  case z[1] of
   'a':
     if (z[0] = 'l') and (m_gt_1(z + 2) <> 0) then
       Inc(z, 2);
   'c':
     if (z[0] = 'e') and (z[2] = 'n')
     and ((z[3] = 'a') or (z[3] = 'e')) and (m_gt_1(z + 4) <> 0) then
       Inc(z, 4);
   'e':
     if (z[0] = 'r') and (m_gt_1(z + 2) <> 0) then
       Inc(z, 2);
   'i':
     if (z[0] = 'c') and (m_gt_1(z + 2) <> 0) then
       Inc(z, 2);
   'l':
     if (z[0] = 'e') and (z[2] = 'b')
     and ((z[3] = 'a') or (z[3] = 'i')) and (m_gt_1(z + 4) <> 0) then
       Inc(z, 4);
   'n':
     if z[0] = 't' then begin
       if z[2] = 'a' then begin
         if m_gt_1(z + 3) <> 0 then
           Inc(z, 3);
       end else if z[2] = 'e' then begin
         if (stem(@z, 'tneme', '', @m_gt_1) = 0)
         and (stem(@z, 'tnem', '', @m_gt_1) = 0) then
           stem(@z, 'tne', '', @m_gt_1);
       end;
     end;
   'o':
     if z[0] = 'u' then begin
       if m_gt_1(z + 2) <> 0 then
         Inc(z, 2);
     end else if (z[3] = 's') or (z[3] = 't') then
       stem(@z, 'noi', '', @m_gt_1);
   's':
     if (z[0] = 'm') and (z[2] = 'i') and (m_gt_1(z + 3) <> 0) then
       Inc(z, 3);
   't':
     if stem(@z, 'eta', '', @m_gt_1) = 0 then
       stem(@z, 'iti', '', @m_gt_1);
   'u':
     if (z[0] = 's') and (z[2] = 'o') and (m_gt_1(z + 3) <> 0) then
       Inc(z, 3);
   'v', 'z':
     if (z[0] = 'e') and (z[2] = 'i') and (m_gt_1(z + 3) <> 0) then
       Inc(z, 3);
  end;

  { Step 5a }
  if z[0] = 'e' then begin
    if m_gt_1(z + 1) <> 0 then
      Inc(z)
    else if (m_eq_1(z + 1) <> 0) and (star_oh(z + 1) = 0) then
      Inc(z);
  end;

  { Step 5b }
  if (m_gt_1(z) <> 0) and (z[0] = 'l') and (z[1] = 'l') then
    Inc(z);

  { z[] is now the stemmed word in reverse order.  Flip it back. }
  i := cint(libc_strlen(z));
  pnOut^ := i;
  zOut[i] := #0;
  while z^ <> #0 do begin
    Dec(i);
    zOut[i] := z^;
    Inc(z);
  end;
end;

{ fts3_porter.c:580..587 — porterIdChar table (indexed by ch-0x30). }
const
  porterIdChar: array[0..79] of cchar = (
{ x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 xA xB xC xD xE xF }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0,  { 3x }
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  { 4x }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1,  { 5x }
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  { 6x }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0   { 7x }
  );

{ fts3_porter.c:588 — #define isDelim(C).  Ported as a helper taking the
  raw byte; C: ((ch=C)&0x80)==0 && (ch<0x30 || !porterIdChar[ch-0x30]). }
function porterIsDelim(ch: Byte): Boolean; inline;
begin
  Result := ((ch and $80) = 0)
        and ((ch < $30) or (porterIdChar[ch - $30] = 0));
end;

{ fts3_porter.c:594..637 — porterNext. }
function porterNext(pCursor: Psqlite3_tokenizer_cursor;
  pzToken: PPChar; pnBytes: Pcint;
  piStartOffset: Pcint; piEndOffset: Pcint; piPosition: Pcint): cint; cdecl;
var
  c: Pporter_tokenizer_cursor;
  z: PChar;
  iStartOffset, n: cint;
  pNew: PChar;
begin
  c := Pporter_tokenizer_cursor(pCursor);
  z := c^.zInput;

  while c^.iOffset < c^.nInput do begin
    { Scan past delimiter characters }
    while (c^.iOffset < c^.nInput) and porterIsDelim(Byte(z[c^.iOffset])) do
      Inc(c^.iOffset);

    { Count non-delimiter characters. }
    iStartOffset := c^.iOffset;
    while (c^.iOffset < c^.nInput) and (not porterIsDelim(Byte(z[c^.iOffset]))) do
      Inc(c^.iOffset);

    if c^.iOffset > iStartOffset then begin
      n := c^.iOffset - iStartOffset;
      if n > c^.nAllocated then begin
        c^.nAllocated := n + 20;
        pNew := PChar(sqlite3_realloc64(c^.zToken, u64(c^.nAllocated)));
        if pNew = nil then Exit(SQLITE_NOMEM);
        c^.zToken := pNew;
      end;
      porter_stemmer(@z[iStartOffset], n, c^.zToken, pnBytes);
      pzToken^ := c^.zToken;
      piStartOffset^ := iStartOffset;
      piEndOffset^ := c^.iOffset;
      piPosition^ := c^.iToken;
      Inc(c^.iToken);
      Exit(SQLITE_OK);
    end;
  end;
  Result := SQLITE_DONE;
end;

{ fts3_porter.c:642..650 — the static porterTokenizerModule record. }
const
  porterTokenizerModule: Tsqlite3_tokenizer_module = (
    iVersion    : 0;
    xCreate     : @porterCreate;
    xDestroy    : @porterDestroy;
    xOpen       : @porterOpen;
    xClose      : @porterClose;
    xNext       : @porterNext;
    xLanguageid : nil;
  );

{ fts3_porter.c:656..660 — sqlite3Fts3PorterTokenizerModule. }
procedure sqlite3Fts3PorterTokenizerModule(ppModule: PPsqlite3_tokenizer_module);
begin
  ppModule^ := @porterTokenizerModule;
end;

{ ===================================================================== }
{ 6.40.1.e — fts3_unicode2.c — auto-generated Unicode category data.     }
{ DO NOT EDIT the tables: ported verbatim from the machine-generated C.  }
{ ===================================================================== }

{ fts3_unicode2.c:30..151 — sqlite3FtsUnicodeIsalnum.
  Return true if the argument corresponds to a unicode codepoint
  classified as either a letter or a number; otherwise false. }
function sqlite3FtsUnicodeIsalnum(c: cint): cint;
const
  { fts3_unicode2.c:42..125 — aEntry[].  Each value ((C<<22)+N) represents a
    range of N codepoints (that are NOT letters/numbers) starting at C. }
  aEntry: array[0..405] of cuint = (
    $00000030, $0000E807, $00016C06, $0001EC2F, $0002AC07,
    $0002D001, $0002D803, $0002EC01, $0002FC01, $00035C01,
    $0003DC01, $000B0804, $000B480E, $000B9407, $000BB401,
    $000BBC81, $000DD401, $000DF801, $000E1002, $000E1C01,
    $000FD801, $00120808, $00156806, $00162402, $00163C01,
    $00164437, $0017CC02, $00180005, $00181816, $00187802,
    $00192C15, $0019A804, $0019C001, $001B5001, $001B580F,
    $001B9C07, $001BF402, $001C000E, $001C3C01, $001C4401,
    $001CC01B, $001E980B, $001FAC09, $001FD804, $00205804,
    $00206C09, $00209403, $0020A405, $0020C00F, $00216403,
    $00217801, $0023901B, $00240004, $0024E803, $0024F812,
    $00254407, $00258804, $0025C001, $00260403, $0026F001,
    $0026F807, $00271C02, $00272C03, $00275C01, $00278802,
    $0027C802, $0027E802, $00280403, $0028F001, $0028F805,
    $00291C02, $00292C03, $00294401, $0029C002, $0029D401,
    $002A0403, $002AF001, $002AF808, $002B1C03, $002B2C03,
    $002B8802, $002BC002, $002C0403, $002CF001, $002CF807,
    $002D1C02, $002D2C03, $002D5802, $002D8802, $002DC001,
    $002E0801, $002EF805, $002F1803, $002F2804, $002F5C01,
    $002FCC08, $00300403, $0030F807, $00311803, $00312804,
    $00315402, $00318802, $0031FC01, $00320802, $0032F001,
    $0032F807, $00331803, $00332804, $00335402, $00338802,
    $00340802, $0034F807, $00351803, $00352804, $00355C01,
    $00358802, $0035E401, $00360802, $00372801, $00373C06,
    $00375801, $00376008, $0037C803, $0038C401, $0038D007,
    $0038FC01, $00391C09, $00396802, $003AC401, $003AD006,
    $003AEC02, $003B2006, $003C041F, $003CD00C, $003DC417,
    $003E340B, $003E6424, $003EF80F, $003F380D, $0040AC14,
    $00412806, $00415804, $00417803, $00418803, $00419C07,
    $0041C404, $0042080C, $00423C01, $00426806, $0043EC01,
    $004D740C, $004E400A, $00500001, $0059B402, $005A0001,
    $005A6C02, $005BAC03, $005C4803, $005CC805, $005D4802,
    $005DC802, $005ED023, $005F6004, $005F7401, $0060000F,
    $0062A401, $0064800C, $0064C00C, $00650001, $00651002,
    $0066C011, $00672002, $00677822, $00685C05, $00687802,
    $0069540A, $0069801D, $0069FC01, $006A8007, $006AA006,
    $006C0005, $006CD011, $006D6823, $006E0003, $006E840D,
    $006F980E, $006FF004, $00709014, $0070EC05, $0071F802,
    $00730008, $00734019, $0073B401, $0073C803, $00770027,
    $0077F004, $007EF401, $007EFC03, $007F3403, $007F7403,
    $007FB403, $007FF402, $00800065, $0081A806, $0081E805,
    $00822805, $0082801A, $00834021, $00840002, $00840C04,
    $00842002, $00845001, $00845803, $00847806, $00849401,
    $00849C01, $0084A401, $0084B801, $0084E802, $00850005,
    $00852804, $00853C01, $00864264, $00900027, $0091000B,
    $0092704E, $00940200, $009C0475, $009E53B9, $00AD400A,
    $00B39406, $00B3BC03, $00B3E404, $00B3F802, $00B5C001,
    $00B5FC01, $00B7804F, $00B8C00C, $00BA001A, $00BA6C59,
    $00BC00D6, $00BFC00C, $00C00005, $00C02019, $00C0A807,
    $00C0D802, $00C0F403, $00C26404, $00C28001, $00C3EC01,
    $00C64002, $00C6580A, $00C70024, $00C8001F, $00C8A81E,
    $00C94001, $00C98020, $00CA2827, $00CB003F, $00CC0100,
    $01370040, $02924037, $0293F802, $02983403, $0299BC10,
    $029A7C01, $029BC008, $029C0017, $029C8002, $029E2402,
    $02A00801, $02A01801, $02A02C01, $02A08C09, $02A0D804,
    $02A1D004, $02A20002, $02A2D011, $02A33802, $02A38012,
    $02A3E003, $02A4980A, $02A51C0D, $02A57C01, $02A60004,
    $02A6CC1B, $02A77802, $02A8A40E, $02A90C01, $02A93002,
    $02A97004, $02A9DC03, $02A9EC01, $02AAC001, $02AAC803,
    $02AADC02, $02AAF802, $02AB0401, $02AB7802, $02ABAC07,
    $02ABD402, $02AF8C0B, $03600001, $036DFC02, $036FFC02,
    $037FFC01, $03EC7801, $03ECA401, $03EEC810, $03F4F802,
    $03F7F002, $03F8001A, $03F88007, $03F8C023, $03F95013,
    $03F9A004, $03FBFC01, $03FC040F, $03FC6807, $03FCEC06,
    $03FD6C0B, $03FF8007, $03FFA007, $03FFE405, $04040003,
    $0404DC09, $0405E411, $0406400C, $0407402E, $040E7C01,
    $040F4001, $04215C01, $04247C01, $0424FC01, $04280403,
    $04281402, $04283004, $0428E003, $0428FC01, $04294009,
    $0429FC01, $042CE407, $04400003, $0440E016, $04420003,
    $0442C012, $04440003, $04449C0E, $04450004, $04460003,
    $0446CC0E, $04471404, $045AAC0D, $0491C004, $05BD442E,
    $05BE3C04, $074000F6, $07440027, $0744A4B5, $07480046,
    $074C0057, $075B0401, $075B6C01, $075BEC01, $075C5401,
    $075CD401, $075D3C01, $075DBC01, $075E2401, $075EA401,
    $075F0C01, $07BBC002, $07C0002C, $07C0C064, $07C2800F,
    $07C2C40E, $07C3040F, $07C3440F, $07C4401F, $07C4C03C,
    $07C5C02B, $07C7981D, $07C8402B, $07C90009, $07C94002,
    $07CC0021, $07CCC006, $07CCDC46, $07CE0014, $07CE8025,
    $07CF1805, $07CF8011, $07D0003F, $07D10001, $07D108B6,
    $07D3E404, $07D4003E, $07D50004, $07D54018, $07D7EC46,
    $07D9140B, $07DA0046, $07DC0074, $38000401, $38008060,
    $380400F0
  );
  { fts3_unicode2.c:126..128 — aAscii[4]. }
  aAscii: array[0..3] of cuint = (
    $FFFFFFFF, $FC00FFFF, $F8000001, $F8000001
  );
var
  key: cuint;
  iRes, iHi, iLo, iTest: cint;
begin
  if cuint(c) < 128 then begin
    if (aAscii[c shr 5] and (cuint(1) shl (c and $001F))) = 0 then
      Result := 1
    else
      Result := 0;
    Exit;
  end else if cuint(c) < (1 shl 22) then begin
    key := (cuint(c) shl 10) or $000003FF;
    iRes := 0;
    iHi := (SizeOf(aEntry) div SizeOf(aEntry[0])) - 1;
    iLo := 0;
    while iHi >= iLo do begin
      iTest := (iHi + iLo) div 2;
      if key >= aEntry[iTest] then begin
        iRes := iTest;
        iLo := iTest + 1;
      end else
        iHi := iTest - 1;
    end;
    Assert(aEntry[0] < key);
    Assert(key >= aEntry[iRes]);
    if cuint(c) >= ((aEntry[iRes] shr 10) + (aEntry[iRes] and $3FF)) then
      Result := 1
    else
      Result := 0;
    Exit;
  end;
  Result := 1;
end;

{ fts3_unicode2.c:162..222 — remove_diacritic. }
function remove_diacritic(c: cint; bComplex: cint): cint;
const
  { fts3_unicode2.c:163..180 — aDia[].  Unsigned 16-bit. }
  aDia: array[0..125] of cushort = (
        0,  1797,  1848,  1859,  1891,  1928,  1940,  1995,
     2024,  2040,  2060,  2110,  2168,  2206,  2264,  2286,
     2344,  2383,  2472,  2488,  2516,  2596,  2668,  2732,
     2782,  2842,  2894,  2954,  2984,  3000,  3028,  3336,
     3456,  3696,  3712,  3728,  3744,  3766,  3832,  3896,
     3912,  3928,  3944,  3968,  4008,  4040,  4056,  4106,
     4138,  4170,  4202,  4234,  4266,  4296,  4312,  4344,
     4408,  4424,  4442,  4472,  4488,  4504,  6148,  6198,
     6264,  6280,  6360,  6429,  6505,  6529, 61448, 61468,
    61512, 61534, 61592, 61610, 61642, 61672, 61688, 61704,
    61726, 61784, 61800, 61816, 61836, 61880, 61896, 61914,
    61948, 61998, 62062, 62122, 62154, 62184, 62200, 62218,
    62252, 62302, 62364, 62410, 62442, 62478, 62536, 62554,
    62584, 62604, 62640, 62648, 62656, 62664, 62730, 62766,
    62830, 62890, 62924, 62974, 63032, 63050, 63082, 63118,
    63182, 63242, 63274, 63310, 63368, 63390
  );
  { fts3_unicode2.c:181 — #define HIBIT ((unsigned char)0x80) }
  HIBIT = $80;
  { fts3_unicode2.c:182..204 — aChar[].  ASCII letter (low 7 bits) plus the
    HIBIT "complex" flag for codepoints only folded when bComplex!=0. }
  aChar: array[0..125] of cuchar = (
    Ord(#0),         Ord('a'),        Ord('c'),        Ord('e'),
    Ord('i'),        Ord('n'),
    Ord('o'),        Ord('u'),        Ord('y'),        Ord('y'),
    Ord('a'),        Ord('c'),
    Ord('d'),        Ord('e'),        Ord('e'),        Ord('g'),
    Ord('h'),        Ord('i'),
    Ord('j'),        Ord('k'),        Ord('l'),        Ord('n'),
    Ord('o'),        Ord('r'),
    Ord('s'),        Ord('t'),        Ord('u'),        Ord('u'),
    Ord('w'),        Ord('y'),
    Ord('z'),        Ord('o'),        Ord('u'),        Ord('a'),
    Ord('i'),        Ord('o'),
    Ord('u'),        Ord('u') or HIBIT, Ord('a') or HIBIT, Ord('g'),
    Ord('k'),        Ord('o'),
    Ord('o') or HIBIT, Ord('j'),      Ord('g'),        Ord('n'),
    Ord('a') or HIBIT, Ord('a'),
    Ord('e'),        Ord('i'),        Ord('o'),        Ord('r'),
    Ord('u'),        Ord('s'),
    Ord('t'),        Ord('h'),        Ord('a'),        Ord('e'),
    Ord('o') or HIBIT, Ord('o'),
    Ord('o') or HIBIT, Ord('y'),      Ord(#0),         Ord(#0),
    Ord(#0),         Ord(#0),
    Ord(#0),         Ord(#0),         Ord(#0),         Ord(#0),
    Ord('a'),        Ord('b'),
    Ord('c') or HIBIT, Ord('d'),      Ord('d'),        Ord('e') or HIBIT,
    Ord('e'),        Ord('e') or HIBIT,
    Ord('f'),        Ord('g'),        Ord('h'),        Ord('h'),
    Ord('i'),        Ord('i') or HIBIT,
    Ord('k'),        Ord('l'),        Ord('l') or HIBIT, Ord('l'),
    Ord('m'),        Ord('n'),
    Ord('o') or HIBIT, Ord('p'),      Ord('r'),        Ord('r') or HIBIT,
    Ord('r'),        Ord('s'),
    Ord('s') or HIBIT, Ord('t'),      Ord('u'),        Ord('u') or HIBIT,
    Ord('v'),        Ord('w'),
    Ord('w'),        Ord('x'),        Ord('y'),        Ord('z'),
    Ord('h'),        Ord('t'),
    Ord('w'),        Ord('y'),        Ord('a'),        Ord('a') or HIBIT,
    Ord('a') or HIBIT, Ord('a') or HIBIT,
    Ord('e'),        Ord('e') or HIBIT, Ord('e') or HIBIT, Ord('i'),
    Ord('o'),        Ord('o') or HIBIT,
    Ord('o') or HIBIT, Ord('o') or HIBIT, Ord('u'),     Ord('u') or HIBIT,
    Ord('u') or HIBIT, Ord('y')
  );
var
  key: cuint;
  iRes, iHi, iLo, iTest: cint;
begin
  key := (cuint(c) shl 3) or $00000007;
  iRes := 0;
  iHi := (SizeOf(aDia) div SizeOf(aDia[0])) - 1;
  iLo := 0;
  while iHi >= iLo do begin
    iTest := (iHi + iLo) div 2;
    if key >= aDia[iTest] then begin
      iRes := iTest;
      iLo := iTest + 1;
    end else
      iHi := iTest - 1;
  end;
  Assert(key >= aDia[iRes]);
  if (bComplex = 0) and ((aChar[iRes] and $80) <> 0) then Exit(c);
  if cuint(c) > ((aDia[iRes] shr 3) + (aDia[iRes] and $07)) then
    Result := c
  else
    Result := cint(aChar[iRes]) and $7F;
end;

{ fts3_unicode2.c:229..236 — sqlite3FtsUnicodeIsdiacritic. }
function sqlite3FtsUnicodeIsdiacritic(c: cint): cint;
var
  mask0, mask1: cuint;
begin
  mask0 := $08029FDF;
  mask1 := $000361F8;
  if (c < 768) or (c > 817) then Exit(0);
  if c < 768 + 32 then
    Result := cint(mask0 and (cuint(1) shl (c - 768)))
  else
    Result := cint(mask1 and (cuint(1) shl (c - 768 - 32)));
end;

type
  { fts3_unicode2.c:266..270 — struct TableEntry. }
  TFtsUFoldEntry = record
    iCode  : cushort;
    flags  : cuchar;
    nRange : cuchar;
  end;

{ fts3_unicode2.c:248..381 — sqlite3FtsUnicodeFold. }
function sqlite3FtsUnicodeFold(c: cint; eRemoveDiacritic: cint): cint;
const
  { fts3_unicode2.c:271..326 — aEntry[] (TableEntry).  Verbatim. }
  aEntry: array[0..162] of TFtsUFoldEntry = (
    (iCode:65;    flags:14;  nRange:26),  (iCode:181;   flags:64;  nRange:1),  (iCode:192;   flags:14;  nRange:23),
    (iCode:216;   flags:14;  nRange:7),   (iCode:256;   flags:1;   nRange:48), (iCode:306;   flags:1;   nRange:6),
    (iCode:313;   flags:1;   nRange:16),  (iCode:330;   flags:1;   nRange:46), (iCode:376;   flags:116; nRange:1),
    (iCode:377;   flags:1;   nRange:6),   (iCode:383;   flags:104; nRange:1),  (iCode:385;   flags:50;  nRange:1),
    (iCode:386;   flags:1;   nRange:4),   (iCode:390;   flags:44;  nRange:1),  (iCode:391;   flags:0;   nRange:1),
    (iCode:393;   flags:42;  nRange:2),   (iCode:395;   flags:0;   nRange:1),  (iCode:398;   flags:32;  nRange:1),
    (iCode:399;   flags:38;  nRange:1),   (iCode:400;   flags:40;  nRange:1),  (iCode:401;   flags:0;   nRange:1),
    (iCode:403;   flags:42;  nRange:1),   (iCode:404;   flags:46;  nRange:1),  (iCode:406;   flags:52;  nRange:1),
    (iCode:407;   flags:48;  nRange:1),   (iCode:408;   flags:0;   nRange:1),  (iCode:412;   flags:52;  nRange:1),
    (iCode:413;   flags:54;  nRange:1),   (iCode:415;   flags:56;  nRange:1),  (iCode:416;   flags:1;   nRange:6),
    (iCode:422;   flags:60;  nRange:1),   (iCode:423;   flags:0;   nRange:1),  (iCode:425;   flags:60;  nRange:1),
    (iCode:428;   flags:0;   nRange:1),   (iCode:430;   flags:60;  nRange:1),  (iCode:431;   flags:0;   nRange:1),
    (iCode:433;   flags:58;  nRange:2),   (iCode:435;   flags:1;   nRange:4),  (iCode:439;   flags:62;  nRange:1),
    (iCode:440;   flags:0;   nRange:1),   (iCode:444;   flags:0;   nRange:1),  (iCode:452;   flags:2;   nRange:1),
    (iCode:453;   flags:0;   nRange:1),   (iCode:455;   flags:2;   nRange:1),  (iCode:456;   flags:0;   nRange:1),
    (iCode:458;   flags:2;   nRange:1),   (iCode:459;   flags:1;   nRange:18), (iCode:478;   flags:1;   nRange:18),
    (iCode:497;   flags:2;   nRange:1),   (iCode:498;   flags:1;   nRange:4),  (iCode:502;   flags:122; nRange:1),
    (iCode:503;   flags:134; nRange:1),   (iCode:504;   flags:1;   nRange:40), (iCode:544;   flags:110; nRange:1),
    (iCode:546;   flags:1;   nRange:18),  (iCode:570;   flags:70;  nRange:1),  (iCode:571;   flags:0;   nRange:1),
    (iCode:573;   flags:108; nRange:1),   (iCode:574;   flags:68;  nRange:1),  (iCode:577;   flags:0;   nRange:1),
    (iCode:579;   flags:106; nRange:1),   (iCode:580;   flags:28;  nRange:1),  (iCode:581;   flags:30;  nRange:1),
    (iCode:582;   flags:1;   nRange:10),  (iCode:837;   flags:36;  nRange:1),  (iCode:880;   flags:1;   nRange:4),
    (iCode:886;   flags:0;   nRange:1),   (iCode:902;   flags:18;  nRange:1),  (iCode:904;   flags:16;  nRange:3),
    (iCode:908;   flags:26;  nRange:1),   (iCode:910;   flags:24;  nRange:2),  (iCode:913;   flags:14;  nRange:17),
    (iCode:931;   flags:14;  nRange:9),   (iCode:962;   flags:0;   nRange:1),  (iCode:975;   flags:4;   nRange:1),
    (iCode:976;   flags:140; nRange:1),   (iCode:977;   flags:142; nRange:1),  (iCode:981;   flags:146; nRange:1),
    (iCode:982;   flags:144; nRange:1),   (iCode:984;   flags:1;   nRange:24), (iCode:1008;  flags:136; nRange:1),
    (iCode:1009;  flags:138; nRange:1),   (iCode:1012;  flags:130; nRange:1),  (iCode:1013;  flags:128; nRange:1),
    (iCode:1015;  flags:0;   nRange:1),   (iCode:1017;  flags:152; nRange:1),  (iCode:1018;  flags:0;   nRange:1),
    (iCode:1021;  flags:110; nRange:3),   (iCode:1024;  flags:34;  nRange:16), (iCode:1040;  flags:14;  nRange:32),
    (iCode:1120;  flags:1;   nRange:34),  (iCode:1162;  flags:1;   nRange:54), (iCode:1216;  flags:6;   nRange:1),
    (iCode:1217;  flags:1;   nRange:14),  (iCode:1232;  flags:1;   nRange:88), (iCode:1329;  flags:22;  nRange:38),
    (iCode:4256;  flags:66;  nRange:38),  (iCode:4295;  flags:66;  nRange:1),  (iCode:4301;  flags:66;  nRange:1),
    (iCode:7680;  flags:1;   nRange:150), (iCode:7835;  flags:132; nRange:1),  (iCode:7838;  flags:96;  nRange:1),
    (iCode:7840;  flags:1;   nRange:96),  (iCode:7944;  flags:150; nRange:8),  (iCode:7960;  flags:150; nRange:6),
    (iCode:7976;  flags:150; nRange:8),   (iCode:7992;  flags:150; nRange:8),  (iCode:8008;  flags:150; nRange:6),
    (iCode:8025;  flags:151; nRange:8),   (iCode:8040;  flags:150; nRange:8),  (iCode:8072;  flags:150; nRange:8),
    (iCode:8088;  flags:150; nRange:8),   (iCode:8104;  flags:150; nRange:8),  (iCode:8120;  flags:150; nRange:2),
    (iCode:8122;  flags:126; nRange:2),   (iCode:8124;  flags:148; nRange:1),  (iCode:8126;  flags:100; nRange:1),
    (iCode:8136;  flags:124; nRange:4),   (iCode:8140;  flags:148; nRange:1),  (iCode:8152;  flags:150; nRange:2),
    (iCode:8154;  flags:120; nRange:2),   (iCode:8168;  flags:150; nRange:2),  (iCode:8170;  flags:118; nRange:2),
    (iCode:8172;  flags:152; nRange:1),   (iCode:8184;  flags:112; nRange:2),  (iCode:8186;  flags:114; nRange:2),
    (iCode:8188;  flags:148; nRange:1),   (iCode:8486;  flags:98;  nRange:1),  (iCode:8490;  flags:92;  nRange:1),
    (iCode:8491;  flags:94;  nRange:1),   (iCode:8498;  flags:12;  nRange:1),  (iCode:8544;  flags:8;   nRange:16),
    (iCode:8579;  flags:0;   nRange:1),   (iCode:9398;  flags:10;  nRange:26), (iCode:11264; flags:22;  nRange:47),
    (iCode:11360; flags:0;   nRange:1),   (iCode:11362; flags:88;  nRange:1),  (iCode:11363; flags:102; nRange:1),
    (iCode:11364; flags:90;  nRange:1),   (iCode:11367; flags:1;   nRange:6),  (iCode:11373; flags:84;  nRange:1),
    (iCode:11374; flags:86;  nRange:1),   (iCode:11375; flags:80;  nRange:1),  (iCode:11376; flags:82;  nRange:1),
    (iCode:11378; flags:0;   nRange:1),   (iCode:11381; flags:0;   nRange:1),  (iCode:11390; flags:78;  nRange:2),
    (iCode:11392; flags:1;   nRange:100), (iCode:11499; flags:1;   nRange:4),  (iCode:11506; flags:0;   nRange:1),
    (iCode:42560; flags:1;   nRange:46),  (iCode:42624; flags:1;   nRange:24), (iCode:42786; flags:1;   nRange:14),
    (iCode:42802; flags:1;   nRange:62),  (iCode:42873; flags:1;   nRange:4),  (iCode:42877; flags:76;  nRange:1),
    (iCode:42878; flags:1;   nRange:10),  (iCode:42891; flags:0;   nRange:1),  (iCode:42893; flags:74;  nRange:1),
    (iCode:42896; flags:1;   nRange:4),   (iCode:42912; flags:1;   nRange:10), (iCode:42922; flags:72;  nRange:1),
    (iCode:65313; flags:14;  nRange:26)
  );
  { fts3_unicode2.c:327..338 — aiOff[].  Unsigned 16-bit. }
  aiOff: array[0..76] of cushort = (
    1,     2,     8,     15,    16,    26,    28,    32,
    37,    38,    40,    48,    63,    64,    69,    71,
    79,    80,    116,   202,   203,   205,   206,   207,
    209,   210,   211,   213,   214,   217,   218,   219,
    775,   7264,  10792, 10795, 23228, 23256, 30204, 54721,
    54753, 54754, 54756, 54787, 54793, 54809, 57153, 57274,
    57921, 58019, 58363, 61722, 65268, 65341, 65373, 65406,
    65408, 65410, 65415, 65424, 65436, 65439, 65450, 65462,
    65472, 65476, 65478, 65480, 65482, 65488, 65506, 65511,
    65514, 65521, 65527, 65528, 65529
  );
var
  ret: cint;
  p: ^TFtsUFoldEntry;
  iHi, iLo, iRes, iTest, cmp: cint;
begin
  ret := c;
  if c < 128 then begin
    if (c >= Ord('A')) and (c <= Ord('Z')) then
      ret := c + (Ord('a') - Ord('A'));
  end else if c < 65536 then begin
    iHi := (SizeOf(aEntry) div SizeOf(aEntry[0])) - 1;
    iLo := 0;
    iRes := -1;
    Assert(c > aEntry[0].iCode);
    while iHi >= iLo do begin
      iTest := (iHi + iLo) div 2;
      cmp := c - aEntry[iTest].iCode;
      if cmp >= 0 then begin
        iRes := iTest;
        iLo := iTest + 1;
      end else
        iHi := iTest - 1;
    end;
    Assert((iRes >= 0) and (c >= aEntry[iRes].iCode));
    p := @aEntry[iRes];
    if (c < (p^.iCode + p^.nRange))
    and ((($01 and p^.flags) and (cint(p^.iCode) xor c)) = 0) then begin
      ret := (c + cint(aiOff[p^.flags shr 1])) and $0000FFFF;
      Assert(ret > 0);
    end;
    if eRemoveDiacritic <> 0 then begin
      if eRemoveDiacritic = 2 then
        ret := remove_diacritic(ret, 1)
      else
        ret := remove_diacritic(ret, 0);
    end;
  end
  else if (c >= 66560) and (c < 66600) then
    ret := c + 40;
  Result := ret;
end;

{ ===================================================================== }
{ 6.40.1.f — fts3_unicode.c — the "unicode61" tokenizer.                 }
{ ===================================================================== }

type
  { fts3_unicode.c:83..88 — struct unicode_tokenizer. }
  Punicode_tokenizer = ^Tunicode_tokenizer;
  Tunicode_tokenizer = record
    base            : Tsqlite3_tokenizer;
    eRemoveDiacritic : cint;
    nException       : cint;
    aiException       : Pcint;
  end;

  { fts3_unicode.c:90..98 — struct unicode_cursor. }
  Punicode_cursor = ^Tunicode_cursor;
  Tunicode_cursor = record
    base   : Tsqlite3_tokenizer_cursor;
    aInput : PByte;        { Input text being tokenized }
    nInput : cint;         { Size of aInput[] in bytes }
    iOff   : cint;         { Current offset within aInput[] }
    iToken : cint;         { Index of next token to be returned }
    zToken : PChar;        { storage for current token }
    nAlloc : cint;         { space allocated at zToken }
  end;

const
  { fts3_unicode.c:35..44 — sqlite3Utf8Trans1[] (lead-byte offset table). }
  sqlite3Utf8Trans1: array[0..63] of cuchar = (
    $00, $01, $02, $03, $04, $05, $06, $07,
    $08, $09, $0a, $0b, $0c, $0d, $0e, $0f,
    $10, $11, $12, $13, $14, $15, $16, $17,
    $18, $19, $1a, $1b, $1c, $1d, $1e, $1f,
    $00, $01, $02, $03, $04, $05, $06, $07,
    $08, $09, $0a, $0b, $0c, $0d, $0e, $0f,
    $00, $01, $02, $03, $04, $05, $06, $07,
    $00, $01, $02, $03, $00, $01, $00, $00
  );

{ fts3_unicode.c:46..56 — READ_UTF8 macro, ported as a procedure.
  Reads one codepoint at z (PByte), advancing z, stopping before zTerm. }
procedure fts3ReadUtf8(var z: PByte; const zTerm: PByte; var c: cuint); inline;
begin
  c := z^;            { c = *(zIn++) }
  Inc(z);
  if c >= $c0 then begin
    c := sqlite3Utf8Trans1[c - $c0];
    while (z <> zTerm) and ((z^ and $c0) = $80) do begin
      c := (c shl 6) + (cuint($3f) and z^);   { c = (c<<6) + (0x3f & *(zIn++)) }
      Inc(z);
    end;
    if (c < $80)
    or ((c and $FFFFF800) = $D800)
    or ((c and $FFFFFFFE) = $FFFE) then
      c := $FFFD;
  end;
end;

{ fts3_unicode.c:58..76 — WRITE_UTF8 macro, ported as a procedure.
  Writes codepoint c at zOut (PByte), advancing zOut. }
procedure fts3WriteUtf8(var zOut: PByte; c: cuint); inline;
begin
  if c < $00080 then begin
    zOut^ := cuchar(c and $FF);            Inc(zOut);
  end else if c < $00800 then begin
    zOut^ := cuchar($C0 + ((c shr 6) and $1F));  Inc(zOut);
    zOut^ := cuchar($80 + (c and $3F));          Inc(zOut);
  end else if c < $10000 then begin
    zOut^ := cuchar($E0 + ((c shr 12) and $0F)); Inc(zOut);
    zOut^ := cuchar($80 + ((c shr 6) and $3F));  Inc(zOut);
    zOut^ := cuchar($80 + (c and $3F));          Inc(zOut);
  end else begin
    zOut^ := cuchar($F0 + ((c shr 18) and $07)); Inc(zOut);
    zOut^ := cuchar($80 + ((c shr 12) and $3F)); Inc(zOut);
    zOut^ := cuchar($80 + ((c shr 6) and $3F));  Inc(zOut);
    zOut^ := cuchar($80 + (c and $3F));          Inc(zOut);
  end;
end;

{ fts3_unicode.c:104..111 — unicodeDestroy. }
function unicodeDestroy(pTokenizer: Psqlite3_tokenizer): cint; cdecl;
var
  p: Punicode_tokenizer;
begin
  if pTokenizer <> nil then begin
    p := Punicode_tokenizer(pTokenizer);
    sqlite3_free(p^.aiException);
    sqlite3_free(p);
  end;
  Result := SQLITE_OK;
end;

{ fts3_unicode.c:131..180 — unicodeAddExceptions. }
function unicodeAddExceptions(p: Punicode_tokenizer; bAlnum: cint;
  const zIn: PChar; nIn: cint): cint;
var
  z, zTerm: PByte;
  iCode: cuint;
  nEntry: cint;
  aNew: Pcint;
  nNew, i, j: cint;
begin
  z := PByte(zIn);
  zTerm := @z[nIn];
  nEntry := 0;
  Assert((bAlnum = 0) or (bAlnum = 1));

  while PtrUInt(z) < PtrUInt(zTerm) do begin
    fts3ReadUtf8(z, zTerm, iCode);
    Assert((sqlite3FtsUnicodeIsalnum(cint(iCode)) and $FFFFFFFE) = 0);
    if (sqlite3FtsUnicodeIsalnum(cint(iCode)) <> bAlnum)
    and (sqlite3FtsUnicodeIsdiacritic(cint(iCode)) = 0) then
      Inc(nEntry);
  end;

  if nEntry <> 0 then begin
    aNew := Pcint(sqlite3_realloc64(p^.aiException,
      u64((p^.nException + nEntry) * cint(SizeOf(cint)))));
    if aNew = nil then Exit(SQLITE_NOMEM);
    nNew := p^.nException;

    z := PByte(zIn);
    while PtrUInt(z) < PtrUInt(zTerm) do begin
      fts3ReadUtf8(z, zTerm, iCode);
      if (sqlite3FtsUnicodeIsalnum(cint(iCode)) <> bAlnum)
      and (sqlite3FtsUnicodeIsdiacritic(cint(iCode)) = 0) then begin
        i := 0;
        while (i < nNew) and (aNew[i] < cint(iCode)) do Inc(i);
        j := nNew;
        while j > i do begin
          aNew[j] := aNew[j - 1];
          Dec(j);
        end;
        aNew[i] := cint(iCode);
        Inc(nNew);
      end;
    end;
    p^.aiException := aNew;
    p^.nException := nNew;
  end;

  Result := SQLITE_OK;
end;

{ fts3_unicode.c:185..204 — unicodeIsException. }
function unicodeIsException(p: Punicode_tokenizer; iCode: cint): cint;
var
  a: Pcint;
  iLo, iHi, iTest: cint;
begin
  if p^.nException > 0 then begin
    a := p^.aiException;
    iLo := 0;
    iHi := p^.nException - 1;
    while iHi >= iLo do begin
      iTest := (iHi + iLo) div 2;
      if iCode = a[iTest] then
        Exit(1)
      else if iCode > a[iTest] then
        iLo := iTest + 1
      else
        iHi := iTest - 1;
    end;
  end;
  Result := 0;
end;

{ fts3_unicode.c:210..213 — unicodeIsAlnum. }
function unicodeIsAlnum(p: Punicode_tokenizer; iCode: cint): cint;
begin
  Assert((sqlite3FtsUnicodeIsalnum(iCode) and $FFFFFFFE) = 0);
  Result := sqlite3FtsUnicodeIsalnum(iCode) xor unicodeIsException(p, iCode);
end;

{ fts3_unicode.c:218..263 — unicodeCreate. }
function unicodeCreate(nArg: cint; const azArg: PPChar;
  pp: PPsqlite3_tokenizer): cint; cdecl;
var
  pNew: Punicode_tokenizer;
  i, n, rc: cint;
  z: PChar;
begin
  rc := SQLITE_OK;
  pNew := Punicode_tokenizer(sqlite3_malloc(i32(SizeOf(Tunicode_tokenizer))));
  if pNew = nil then Exit(SQLITE_NOMEM);
  libc_memset(pNew, 0, NativeUInt(SizeOf(Tunicode_tokenizer)));
  pNew^.eRemoveDiacritic := 1;

  i := 0;
  while (rc = SQLITE_OK) and (i < nArg) do begin
    z := PPChar(azArg)[i];
    n := cint(libc_strlen(z));

    if (n = 19) and (libc_memcmp(PChar('remove_diacritics=1'), z, 19) = 0) then
      pNew^.eRemoveDiacritic := 1
    else if (n = 19) and (libc_memcmp(PChar('remove_diacritics=0'), z, 19) = 0) then
      pNew^.eRemoveDiacritic := 0
    else if (n = 19) and (libc_memcmp(PChar('remove_diacritics=2'), z, 19) = 0) then
      pNew^.eRemoveDiacritic := 2
    else if (n >= 11) and (libc_memcmp(PChar('tokenchars='), z, 11) = 0) then
      rc := unicodeAddExceptions(pNew, 1, @z[11], n - 11)
    else if (n >= 11) and (libc_memcmp(PChar('separators='), z, 11) = 0) then
      rc := unicodeAddExceptions(pNew, 0, @z[11], n - 11)
    else
      rc := SQLITE_ERROR;   { Unrecognized argument }
    Inc(i);
  end;

  if rc <> SQLITE_OK then begin
    unicodeDestroy(Psqlite3_tokenizer(pNew));
    pNew := nil;
  end;
  pp^ := Psqlite3_tokenizer(pNew);
  Result := rc;
end;

{ fts3_unicode.c:271..298 — unicodeOpen. }
const
  unicodeEmptyInput: cuchar = 0;   { stands in for C's (const u8*)"" }

function unicodeOpen(p: Psqlite3_tokenizer; const aInput: PChar;
  nInput: cint; pp: PPsqlite3_tokenizer_cursor): cint; cdecl;
var
  pCsr: Punicode_cursor;
begin
  pCsr := Punicode_cursor(sqlite3_malloc(i32(SizeOf(Tunicode_cursor))));
  if pCsr = nil then Exit(SQLITE_NOMEM);
  libc_memset(pCsr, 0, NativeUInt(SizeOf(Tunicode_cursor)));

  pCsr^.aInput := PByte(aInput);
  if aInput = nil then begin
    pCsr^.nInput := 0;
    pCsr^.aInput := @unicodeEmptyInput;
  end else if nInput < 0 then
    pCsr^.nInput := cint(libc_strlen(aInput))
  else
    pCsr^.nInput := nInput;

  pp^ := @pCsr^.base;
  { UNUSED_PARAMETER(p) }
  if p = nil then ;
  Result := SQLITE_OK;
end;

{ fts3_unicode.c:304..309 — unicodeClose. }
function unicodeClose(pCursor: Psqlite3_tokenizer_cursor): cint; cdecl;
var
  pCsr: Punicode_cursor;
begin
  pCsr := Punicode_cursor(pCursor);
  sqlite3_free(pCsr^.zToken);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ fts3_unicode.c:315..377 — unicodeNext. }
function unicodeNext(pC: Psqlite3_tokenizer_cursor;
  paToken: PPChar; pnToken: Pcint;
  piStart: Pcint; piEnd: Pcint; piPos: Pcint): cint; cdecl;
var
  pCsr: Punicode_cursor;
  p: Punicode_tokenizer;
  iCode: cuint;
  zOut: PByte;
  z, zStart, zEnd, zTerm: PByte;
  iOut: cint;
  zNew: PChar;
begin
  pCsr := Punicode_cursor(pC);
  p := Punicode_tokenizer(pCsr^.base.pTokenizer);
  iCode := 0;
  z := @pCsr^.aInput[pCsr^.iOff];
  zStart := z;
  zEnd := z;
  zTerm := @pCsr^.aInput[pCsr^.nInput];

  { Scan past any delimiter characters before the start of the next token. }
  while PtrUInt(z) < PtrUInt(zTerm) do begin
    fts3ReadUtf8(z, zTerm, iCode);
    if unicodeIsAlnum(p, cint(iCode)) <> 0 then Break;
    zStart := z;
  end;
  if PtrUInt(zStart) >= PtrUInt(zTerm) then Exit(SQLITE_DONE);

  zOut := PByte(pCsr^.zToken);
  repeat
    { Grow the output buffer if required. }
    if (PtrInt(zOut) - PtrInt(pCsr^.zToken)) >= (pCsr^.nAlloc - 4) then begin
      zNew := PChar(sqlite3_realloc64(pCsr^.zToken, u64(pCsr^.nAlloc + 64)));
      if zNew = nil then Exit(SQLITE_NOMEM);
      zOut := @PByte(zNew)[PtrInt(zOut) - PtrInt(pCsr^.zToken)];
      pCsr^.zToken := zNew;
      Inc(pCsr^.nAlloc, 64);
    end;

    { Write the folded case of the last character read to the output }
    zEnd := z;
    iOut := sqlite3FtsUnicodeFold(cint(iCode), p^.eRemoveDiacritic);
    if iOut <> 0 then
      fts3WriteUtf8(zOut, cuint(iOut));

    { If the cursor is not at EOF, read the next character }
    if PtrUInt(z) >= PtrUInt(zTerm) then Break;
    fts3ReadUtf8(z, zTerm, iCode);
  until not ((unicodeIsAlnum(p, cint(iCode)) <> 0)
          or (sqlite3FtsUnicodeIsdiacritic(cint(iCode)) <> 0));

  { Set the output variables and return. }
  pCsr^.iOff := cint(PtrInt(z) - PtrInt(pCsr^.aInput));
  paToken^ := pCsr^.zToken;
  pnToken^ := cint(PtrInt(zOut) - PtrInt(pCsr^.zToken));
  piStart^ := cint(PtrInt(zStart) - PtrInt(pCsr^.aInput));
  piEnd^ := cint(PtrInt(zEnd) - PtrInt(pCsr^.aInput));
  piPos^ := pCsr^.iToken;
  Inc(pCsr^.iToken);
  Result := SQLITE_OK;
end;

{ fts3_unicode.c:384..392 — the static unicode tokenizer module record. }
const
  unicodeTokenizerModule: Tsqlite3_tokenizer_module = (
    iVersion    : 0;
    xCreate     : @unicodeCreate;
    xDestroy    : @unicodeDestroy;
    xOpen       : @unicodeOpen;
    xClose      : @unicodeClose;
    xNext       : @unicodeNext;
    xLanguageid : nil;
  );

{ fts3_unicode.c:383..394 — sqlite3Fts3UnicodeTokenizer. }
procedure sqlite3Fts3UnicodeTokenizer(ppModule: PPsqlite3_tokenizer_module);
begin
  ppModule^ := @unicodeTokenizerModule;
end;

{ ===================================================================== }
{ 6.40.1.g — fts3_tokenizer.c — the generic tokenizer registry.          }
{ ===================================================================== }

{ ---------------------------------------------------------------------
  fts3.c:458..480 — sqlite3Fts3Dequote.  Ported here as a local static
  helper because fts3.c (the fts3/fts4 vtab module) is task 6.40.1.k and
  not yet ported; sqlite3Fts3InitTokenizer needs it now.  TODO(6.40.1.k):
  promote to the shared fts3.c port and drop this copy.
  --------------------------------------------------------------------- }
procedure fts3Dequote(z: PChar);
var
  quote: Char;
  iIn, iOut: cint;
begin
  quote := z[0];
  if (quote = '[') or (quote = '''') or (quote = '"') or (quote = '`') then
  begin
    iIn := 1;
    iOut := 0;
    { If the first byte was a '[', then the close-quote character is a ']' }
    if quote = '[' then quote := ']';
    while z[iIn] <> #0 do begin
      if z[iIn] = quote then begin
        if z[iIn + 1] <> quote then break;
        z[iOut] := quote; Inc(iOut);
        Inc(iIn, 2);
      end else begin
        z[iOut] := z[iIn]; Inc(iOut); Inc(iIn);
      end;
    end;
    z[iOut] := #0;
  end;
end;

{ ---------------------------------------------------------------------
  fts3.c:552..558 — sqlite3Fts3ErrMsg.  Ported here as a local static
  helper for the same reason as fts3Dequote (fts3.c is 6.40.1.k).  The
  format string only ever carries plain `%s`/literal text, so the
  Pascal-side varargs sqlite3PfMprintf renders it faithfully and the
  result is freed via sqlite3_free (libc-backed), matching C.
  TODO(6.40.1.k): promote to the shared fts3.c port and drop this copy.
  --------------------------------------------------------------------- }
procedure fts3ErrMsg(pzErr: PPChar; const zFormat: PChar;
  const args: array of const);
begin
  sqlite3_free(pzErr^);
  pzErr^ := PChar(sqlite3PfMprintf(PAnsiChar(zFormat), args));
end;

{ fts3_tokenizer.c:114..126 — sqlite3Fts3IsIdChar. }
const
  { fts3_tokenizer.c:115..124 — the 128-entry isFtsIdChar table. }
  isFtsIdChar: array[0..127] of cchar = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  { 0x }
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  { 1x }
    0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  { 2x }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0,  { 3x }
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  { 4x }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1,  { 5x }
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  { 6x }
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0   { 7x }
  );

function sqlite3Fts3IsIdChar(c: cchar): cint;
begin
  { C: return (c&0x80 || isFtsIdChar[(int)(c)]);  c is a *signed* char so a
    high-bit byte is negative; the (c&0x80) test catches it before the table
    index is taken. }
  if ((Byte(c) and $80) <> 0) or (isFtsIdChar[Byte(c) and $7f] <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ fts3_tokenizer.c:128..163 — sqlite3Fts3NextToken. }
function sqlite3Fts3NextToken(const zStr: PChar; pn: Pcint): PChar;
var
  z1, z2: PChar;
  c: Char;
begin
  z2 := nil;
  { Find the start of the next token. }
  z1 := zStr;
  while z2 = nil do begin
    c := z1^;
    case c of
      #0: begin Result := nil; Exit; end;   { No more tokens here }
      '''', '"', '`': begin
        z2 := z1;
        { C: while( *++z2 && (*z2!=c || *++z2==c) );
          Each iteration: pre-increment z2 then test *z2.  If NUL, stop.
          Else if *z2 is the close quote, pre-increment again: a doubled
          (escaped) quote continues the loop; a lone close quote ends it
          with z2 pointing just past the close quote. }
        repeat
          Inc(z2);
          if z2^ = #0 then break;
          if z2^ <> c then continue;
          Inc(z2);
          if z2^ <> c then break;
        until False;
      end;
      '[': begin
        z2 := @z1[1];
        while (z2^ <> #0) and (z2[0] <> ']') do Inc(z2);
        if z2^ <> #0 then Inc(z2);
      end;
    else
      if sqlite3Fts3IsIdChar(cchar(z1^)) <> 0 then begin
        z2 := @z1[1];
        while sqlite3Fts3IsIdChar(cchar(z2^)) <> 0 do Inc(z2);
      end else
        Inc(z1);
    end;
  end;

  pn^ := cint(PtrInt(z2) - PtrInt(z1));
  Result := z1;
end;

{ fts3_tokenizer.c:165..224 — sqlite3Fts3InitTokenizer. }
function sqlite3Fts3InitTokenizer(pHash: PFts3Hash; const zArg: PChar;
  ppTok: PPsqlite3_tokenizer; pzErr: PPChar): cint;
var
  rc: cint;
  z: PChar;
  n: cint;
  zCopy, zEnd: PChar;
  m: Psqlite3_tokenizer_module;
  aArg, aNew: PPChar;
  iArg: cint;
  nNew: sqlite3_int64;
begin
  n := 0;
  { C: zCopy = sqlite3_mprintf("%s", zArg);  the Pas one-arg sqlite3_mprintf
    cannot interpolate, so render with the varargs formatter (libc-backed,
    freed by sqlite3_free — the same allocator as C's sqlite3_mprintf). }
  zCopy := PChar(sqlite3PfMprintf(PAnsiChar('%s'), [zArg]));
  if zCopy = nil then begin Result := SQLITE_NOMEM; Exit; end;
  zEnd := @zCopy[libc_strlen(zCopy)];

  z := sqlite3Fts3NextToken(zCopy, @n);
  if z = nil then begin
    Assert(n = 0);
    z := zCopy;
  end;
  z[n] := #0;
  fts3Dequote(z);

  m := Psqlite3_tokenizer_module(
         sqlite3Fts3HashFind(pHash, z, cint(libc_strlen(z)) + 1));
  if m = nil then begin
    fts3ErrMsg(pzErr, 'unknown tokenizer: %s', [z]);
    rc := SQLITE_ERROR;
  end else begin
    aArg := nil;
    iArg := 0;
    z := @z[n + 1];
    while z < zEnd do begin
      z := sqlite3Fts3NextToken(z, @n);
      if z = nil then break;
      nNew := sqlite3_int64(SizeOf(PChar)) * (iArg + 1);
      aNew := PPChar(sqlite3_realloc64(aArg, u64(nNew)));
      if aNew = nil then begin
        sqlite3_free(zCopy);
        sqlite3_free(aArg);
        Result := SQLITE_NOMEM;
        Exit;
      end;
      aArg := aNew;
      PPChar(aArg)[iArg] := z; Inc(iArg);
      z[n] := #0;
      fts3Dequote(z);
      z := @z[n + 1];
    end;
    rc := m^.xCreate(iArg, aArg, ppTok);
    Assert((rc <> SQLITE_OK) or (ppTok^ <> nil));
    if rc <> SQLITE_OK then
      fts3ErrMsg(pzErr, 'unknown tokenizer', [])
    else
      ppTok^^.pModule := m;
    sqlite3_free(aArg);
  end;

  sqlite3_free(zCopy);
  Result := rc;
end;

{ fts3_tokenizer.c:37..42 — fts3TokenizerEnabled: true when the two-arg
  fts3_tokenizer() has been enabled via SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER. }
function fts3TokenizerEnabled(context: Psqlite3_context): cint;
var
  db: Pointer;
  isEnabled: cint;
begin
  db := sqlite3_context_db_handle(context);
  isEnabled := 0;
  { C: sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER, -1,
       &isEnabled);  the Pas db_config is split by value-shape; the int
       variant with onoff=-1 is the query (no-change) path. }
  sqlite3_db_config_int(PTsqlite3(db), SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER,
    -1, @isEnabled);
  Result := isEnabled;
end;

{ fts3_tokenizer.c:64..112 — fts3TokenizerFunc (the fts3_tokenizer() SQL fn). }
procedure fts3TokenizerFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pHash: PFts3Hash;
  pPtr: Pointer;
  zName: PChar;
  nName: cint;
  pOld: Pointer;
  n: cint;
  zErr: PChar;
  pArgv: PPsqlite3_value;
begin
  pPtr := nil;
  pArgv := argv;
  Assert((argc = 1) or (argc = 2));

  pHash := PFts3Hash(sqlite3_user_data(context));

  zName := PChar(sqlite3_value_text(PPsqlite3_value(pArgv)[0]));
  nName := sqlite3_value_bytes(PPsqlite3_value(pArgv)[0]) + 1;

  if argc = 2 then begin
    if (fts3TokenizerEnabled(context) <> 0)
    or (sqlite3_value_frombind(PPsqlite3_value(pArgv)[1]) <> 0) then begin
      n := sqlite3_value_bytes(PPsqlite3_value(pArgv)[1]);
      if (zName = nil) or (n <> cint(SizeOf(pPtr))) then begin
        sqlite3_result_error(context, 'argument type mismatch', -1);
        Exit;
      end;
      pPtr := PPointer(sqlite3_value_blob(PPsqlite3_value(pArgv)[1]))^;
      pOld := sqlite3Fts3HashInsert(pHash, zName, nName, pPtr);
      if pOld = pPtr then
        sqlite3_result_error(context, 'out of memory', -1);
    end else begin
      sqlite3_result_error(context, 'fts3tokenize disabled', -1);
      Exit;
    end;
  end else begin
    if zName <> nil then
      pPtr := sqlite3Fts3HashFind(pHash, zName, nName);
    if pPtr = nil then begin
      zErr := PChar(sqlite3PfMprintf(PAnsiChar('unknown tokenizer: %s'), [zName]));
      sqlite3_result_error(context, PAnsiChar(zErr), -1);
      sqlite3_free(zErr);
      Exit;
    end;
  end;
  if (fts3TokenizerEnabled(context) <> 0)
  or (sqlite3_value_frombind(PPsqlite3_value(pArgv)[0]) <> 0) then
    sqlite3_result_blob(context, @pPtr, cint(SizeOf(pPtr)), SQLITE_TRANSIENT);
end;

{ ---------------------------------------------------------------------
  fts3_expr.c:131..156 — sqlite3Fts3OpenTokenizer.  6.40.1.i promoted the
  .g local stub (sqlite3Fts3OpenTokenizerLocal) to this REAL opener; the
  forward declaration in the interface is its public face and all callers
  now use this name.
  --------------------------------------------------------------------- }
function sqlite3Fts3OpenTokenizer(pTokenizer: Psqlite3_tokenizer;
  iLangid: cint; const z: PChar; n: cint;
  ppCsr: PPsqlite3_tokenizer_cursor): cint;
var
  pModule: Psqlite3_tokenizer_module;
  pCsr: Psqlite3_tokenizer_cursor;
  rc: cint;
begin
  pModule := pTokenizer^.pModule;
  pCsr := nil;
  rc := pModule^.xOpen(pTokenizer, z, n, @pCsr);
  Assert((rc = SQLITE_OK) or (pCsr = nil));
  if rc = SQLITE_OK then begin
    pCsr^.pTokenizer := pTokenizer;
    if pModule^.iVersion >= 1 then begin
      rc := pModule^.xLanguageid(pCsr, iLangid);
      if rc <> SQLITE_OK then begin
        pModule^.xClose(pCsr);
        pCsr := nil;
      end;
    end;
  end;
  ppCsr^ := pCsr;
  Result := rc;
end;

{$IFDEF SQLITE_TEST}
{ ---------------------------------------------------------------------
  fts3_tokenizer.c:227..454 — the SQLITE_TEST-only helpers.  These are
  compiled only into the Tcl bridge library (build_tcl_lib.sh passes
  -dSQLITE_TEST), which links libtcl8.6; the engine build (build.sh)
  leaves SQLITE_TEST undefined so none of this code (nor the Tcl import)
  is emitted.  The Tcl bindings mirror src/tests/tcl/PasTclBridge.pas.
  --------------------------------------------------------------------- }
type
  PTclObj = Pointer;
function Tcl_NewObj: PTclObj; cdecl; external 'tcl8.6';
function Tcl_NewIntObj(intValue: cint): PTclObj; cdecl; external 'tcl8.6';
function Tcl_NewStringObj(bytes: PChar; length: cint): PTclObj; cdecl;
  external 'tcl8.6';
function Tcl_GetString(objPtr: PTclObj): PChar; cdecl; external 'tcl8.6';
function Tcl_ListObjAppendElement(interp: Pointer; listPtr, objPtr: PTclObj):
  cint; cdecl; external 'tcl8.6';
{ Tcl_IncrRefCount/DecrRefCount are macros in tcl.h; bind the always-present
  debug variants exactly as PasTclBridge.pas does. }
function Tcl_DbIncrRefCount(objPtr: PTclObj; fileName: PChar; line: cint): cint;
  cdecl; external 'tcl8.6';
function Tcl_DbDecrRefCount(objPtr: PTclObj; fileName: PChar; line: cint): cint;
  cdecl; external 'tcl8.6';

{ fts3_tokenizer.c:257..346 — testFunc (registered as fts3_tokenizer_test). }
procedure testFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  pHash: PFts3Hash;
  p: Psqlite3_tokenizer_module;
  pTokenizer: Psqlite3_tokenizer;
  pCsr: Psqlite3_tokenizer_cursor;
  zErr: PChar;
  zName, zInput: PChar;
  nName, nInput: cint;
  azArg: array[0..63] of PChar;
  zToken: PChar;
  nToken, iStart, iEnd, iPos, i: cint;
  zErr2: PChar;
  pRet: PTclObj;
  pArgv: PPsqlite3_value;
  label finish;
begin
  pTokenizer := nil;
  pCsr := nil;
  zErr := nil;
  nToken := 0; iStart := 0; iEnd := 0; iPos := 0;
  pArgv := argv;

  if argc < 2 then begin
    sqlite3_result_error(context, 'insufficient arguments', -1);
    Exit;
  end;

  nName := sqlite3_value_bytes(PPsqlite3_value(pArgv)[0]);
  zName := PChar(sqlite3_value_text(PPsqlite3_value(pArgv)[0]));
  nInput := sqlite3_value_bytes(PPsqlite3_value(pArgv)[argc - 1]);
  zInput := PChar(sqlite3_value_text(PPsqlite3_value(pArgv)[argc - 1]));

  pHash := PFts3Hash(sqlite3_user_data(context));
  p := Psqlite3_tokenizer_module(sqlite3Fts3HashFind(pHash, zName, nName + 1));

  if p = nil then begin
    zErr2 := PChar(sqlite3PfMprintf(PAnsiChar('unknown tokenizer: %s'), [zName]));
    sqlite3_result_error(context, PAnsiChar(zErr2), -1);
    sqlite3_free(zErr2);
    Exit;
  end;

  pRet := Tcl_NewObj;
  Tcl_DbIncrRefCount(pRet, 'passqlite3fts3', 0);

  for i := 1 to argc - 2 do
    azArg[i - 1] := PChar(sqlite3_value_text(PPsqlite3_value(pArgv)[i]));

  if SQLITE_OK <> p^.xCreate(argc - 2, @azArg[0], @pTokenizer) then begin
    zErr := 'error in xCreate()';
    goto finish;
  end;
  pTokenizer^.pModule := p;
  if sqlite3Fts3OpenTokenizer(pTokenizer, 0, zInput, nInput, @pCsr) <> 0 then
  begin
    zErr := 'error in xOpen()';
    goto finish;
  end;

  while SQLITE_OK = p^.xNext(pCsr, @zToken, @nToken, @iStart, @iEnd, @iPos) do
  begin
    Tcl_ListObjAppendElement(nil, pRet, Tcl_NewIntObj(iPos));
    Tcl_ListObjAppendElement(nil, pRet, Tcl_NewStringObj(zToken, nToken));
    zToken := @zInput[iStart];
    nToken := iEnd - iStart;
    Tcl_ListObjAppendElement(nil, pRet, Tcl_NewStringObj(zToken, nToken));
  end;

  if SQLITE_OK <> p^.xClose(pCsr) then begin
    zErr := 'error in xClose()';
    goto finish;
  end;
  if SQLITE_OK <> p^.xDestroy(pTokenizer) then begin
    zErr := 'error in xDestroy()';
    goto finish;
  end;

finish:
  if zErr <> nil then
    sqlite3_result_error(context, PAnsiChar(zErr), -1)
  else
    sqlite3_result_text(context, Tcl_GetString(pRet), -1, SQLITE_TRANSIENT);
  Tcl_DbDecrRefCount(pRet, 'passqlite3fts3', 0);
end;

{ fts3_tokenizer.c:348..368 — registerTokenizer (README.tokenizer example). }
function registerTokenizer(db: PTsqlite3; zName: PChar;
  const p: Psqlite3_tokenizer_module): cint;
var
  rc: cint;
  pStmt: Pointer;
  pLocal: Psqlite3_tokenizer_module;
const
  zSql = 'SELECT fts3_tokenizer(?, ?)';
begin
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  pLocal := p;   { C binds &p (a pointer to the module pointer) }
  sqlite3_bind_text(pStmt, 1, PAnsiChar(zName), -1, SQLITE_STATIC);
  sqlite3_bind_blob(pStmt, 2, @pLocal, cint(SizeOf(pLocal)), SQLITE_STATIC);
  sqlite3_step(pStmt);

  Result := sqlite3_finalize(pStmt);
end;

{ fts3_tokenizer.c:371..397 — queryTokenizer (README.tokenizer example). }
function queryTokenizer(db: PTsqlite3; zName: PChar;
  pp: PPsqlite3_tokenizer_module): cint;
var
  rc: cint;
  pStmt: Pointer;
const
  zSql = 'SELECT fts3_tokenizer(?)';
begin
  pp^ := nil;
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  sqlite3_bind_text(pStmt, 1, PAnsiChar(zName), -1, SQLITE_STATIC);
  if SQLITE_ROW = sqlite3_step(pStmt) then begin
    if (sqlite3_column_type(pStmt, 0) = SQLITE_BLOB)
    and (sqlite3_column_bytes(pStmt, 0) = cint(SizeOf(pp^))) then
      libc_memcpy(pp, sqlite3_column_blob(pStmt, 0), NativeUInt(SizeOf(pp^)));
  end;

  Result := sqlite3_finalize(pStmt);
end;

{ fts3_tokenizer.c:419..452 — intTestFunc (fts3_tokenizer_internal_test()). }
procedure intTestFunc(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  rc: cint;
  p1, p2: Psqlite3_tokenizer_module;
  db: PTsqlite3;
begin
  { UNUSED_PARAMETER(argc); UNUSED_PARAMETER(argv) }
  if (argc = 0) and (argv = nil) then ;   { silence unused-param hints }
  db := PTsqlite3(sqlite3_user_data(context));

  { Test the query function. }
  sqlite3Fts3SimpleTokenizerModule(@p1);
  rc := queryTokenizer(db, 'simple', @p2);
  Assert(rc = SQLITE_OK);
  Assert(p1 = p2);
  rc := queryTokenizer(db, 'nosuchtokenizer', @p2);
  Assert(rc = SQLITE_ERROR);
  Assert(p2 = nil);
  Assert(libc_strcmp(sqlite3_errmsg(db),
    'unknown tokenizer: nosuchtokenizer') = 0);

  { Test the storage function. }
  if fts3TokenizerEnabled(context) <> 0 then begin
    rc := registerTokenizer(db, 'nosuchtokenizer', p1);
    Assert(rc = SQLITE_OK);
    rc := queryTokenizer(db, 'nosuchtokenizer', @p2);
    Assert(rc = SQLITE_OK);
    Assert(p2 = p1);
  end;

  sqlite3_result_text(context, 'ok', -1, SQLITE_STATIC);
end;
{$ENDIF}

{ fts3_tokenizer.c:473..514 — sqlite3Fts3InitHashTable. }
function sqlite3Fts3InitHashTable(db: PTsqlite3; pHash: PFts3Hash;
  const zName: PChar): cint;
var
  rc: cint;
  p: Pointer;
  any: cint;
{$IFDEF SQLITE_TEST}
  zTest, zTest2: PChar;
  pdb: Pointer;
{$ENDIF}
begin
  rc := SQLITE_OK;
  p := Pointer(pHash);
  any := SQLITE_UTF8 or SQLITE_DIRECTONLY;

{$IFDEF SQLITE_TEST}
  zTest := nil;
  zTest2 := nil;
  pdb := Pointer(db);
  zTest := PChar(sqlite3PfMprintf(PAnsiChar('%s_test'), [zName]));
  zTest2 := PChar(sqlite3PfMprintf(PAnsiChar('%s_internal_test'), [zName]));
  if (zTest = nil) or (zTest2 = nil) then
    rc := SQLITE_NOMEM;
{$ENDIF}

  if SQLITE_OK = rc then
    rc := sqlite3_create_function(db, PAnsiChar(zName), 1, any, p,
            @fts3TokenizerFunc, nil, nil);
  if SQLITE_OK = rc then
    rc := sqlite3_create_function(db, PAnsiChar(zName), 2, any, p,
            @fts3TokenizerFunc, nil, nil);
{$IFDEF SQLITE_TEST}
  if SQLITE_OK = rc then
    rc := sqlite3_create_function(db, PAnsiChar(zTest), -1, any, p,
            @testFunc, nil, nil);
  if SQLITE_OK = rc then
    rc := sqlite3_create_function(db, PAnsiChar(zTest2), 0, any, pdb,
            @intTestFunc, nil, nil);
{$ENDIF}

{$IFDEF SQLITE_TEST}
  sqlite3_free(zTest);
  sqlite3_free(zTest2);
{$ENDIF}

  Result := rc;
end;

{ ===================================================================== }
{ 6.40.1.h — fts3_tokenize_vtab.c — the "fts3tokenize" virtual table.    }
{ ===================================================================== }

type
  { fts3_tokenize_vtab.c:53..57 — struct Fts3tokTable.  base MUST be the
    first field for the sqlite3_vtab* <-> Fts3tokTable* pointer-casts. }
  PFts3tokTable = ^TFts3tokTable;
  TFts3tokTable = record
    base : Tsqlite3_vtab;                    { Base class used by SQLite core }
    pMod : Psqlite3_tokenizer_module;
    pTok : Psqlite3_tokenizer;
  end;

  { fts3_tokenize_vtab.c:62..72 — struct Fts3tokCursor.  base MUST be the
    first field for the sqlite3_vtab_cursor* <-> Fts3tokCursor* casts. }
  PFts3tokCursor = ^TFts3tokCursor;
  TFts3tokCursor = record
    base   : Tsqlite3_vtab_cursor;           { Base class used by SQLite core }
    zInput : PChar;                          { Input string }
    pCsr   : Psqlite3_tokenizer_cursor;      { Cursor to iterate through zInput }
    iRowid : cint;                           { Current 'rowid' value }
    zToken : PChar;                          { Current 'token' value }
    nToken : cint;                           { Size of zToken in bytes }
    iStart : cint;                           { Current 'start' value }
    iEnd   : cint;                           { Current 'end' value }
    iPos   : cint;                           { Current 'pos' value }
  end;

{ fts3_tokenize_vtab.c:77..94 — fts3tokQueryTokenizer.  Query FTS for the
  tokenizer implementation named zName. }
function fts3tokQueryTokenizer(pHash: PFts3Hash; const zName: PChar;
  pp: PPsqlite3_tokenizer_module; pzErr: PPChar): cint;
var
  p: Psqlite3_tokenizer_module;
  nName: cint;
begin
  nName := cint(libc_strlen(zName));

  p := Psqlite3_tokenizer_module(
         sqlite3Fts3HashFind(pHash, zName, nName + 1));
  if p = nil then begin
    fts3ErrMsg(pzErr, 'unknown tokenizer: %s', [zName]);
    Result := SQLITE_ERROR;
    Exit;
  end;

  pp^ := p;
  Result := SQLITE_OK;
end;

{ fts3_tokenize_vtab.c:108..141 — fts3tokDequoteArray.  Copy argv[] into a
  single block, then dequote each string.  *pazDequote is sqlite3_free'd by
  the caller.  Keys/strings stay raw PChar (no managed-string ref-count). }
function fts3tokDequoteArray(argc: cint; const argv: PPChar;
  pazDequote: PPPAnsiChar): cint;
var
  rc: cint;
  i: cint;
  nByte: cint;
  azDequote: PPChar;
  pSpace: PChar;
  n: cint;
begin
  rc := SQLITE_OK;
  if argc = 0 then
    pazDequote^ := nil
  else begin
    nByte := 0;
    for i := 0 to argc - 1 do
      nByte := nByte + cint(libc_strlen(argv[i]) + 1);

    azDequote := PPChar(sqlite3_malloc64(
                   u64(SizeOf(PChar) * argc + nByte)));
    pazDequote^ := azDequote;
    if azDequote = nil then
      rc := SQLITE_NOMEM
    else begin
      { C: pSpace = (char *)&azDequote[argc]; }
      pSpace := PChar(@azDequote[argc]);
      for i := 0 to argc - 1 do begin
        n := cint(libc_strlen(argv[i]));
        azDequote[i] := pSpace;
        libc_memcpy(pSpace, argv[i], NativeUInt(n + 1));
        fts3Dequote(pSpace);
        Inc(pSpace, n + 1);
      end;
    end;
  end;

  Result := rc;
end;

{ fts3_tokenize_vtab.c:146 — schema of the tokenizer table. }
const
  FTS3_TOK_SCHEMA = 'CREATE TABLE x(input, token, start, end, position)';

{ fts3_tokenize_vtab.c:158..216 — fts3tokConnectMethod.  Does all the work
  for both xConnect and xCreate (identical: these tables have no persistent
  representation).  pHash is the module pAux (the tokenizer hash). }
function fts3tokConnectMethod(db: PTsqlite3; pHash: Pointer;
  argc: cint; const argv: PPChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPChar): cint; cdecl;
var
  pTab: PFts3tokTable;
  pMod: Psqlite3_tokenizer_module;
  pTok: Psqlite3_tokenizer;
  rc: cint;
  azDequote: PPChar;
  nDequote: cint;
  zModule: PChar;
  azArg: PPChar;
  nArg: cint;
begin
  pTab := nil;
  pMod := nil;
  pTok := nil;
  azDequote := nil;

  rc := sqlite3_declare_vtab(db, PAnsiChar(FTS3_TOK_SCHEMA));
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  nDequote := argc - 3;
  rc := fts3tokDequoteArray(nDequote, PPChar(@argv[3]), @azDequote);

  if rc = SQLITE_OK then begin
    if nDequote < 1 then
      zModule := 'simple'
    else
      zModule := azDequote[0];
    rc := fts3tokQueryTokenizer(PFts3Hash(pHash), zModule, @pMod, pzErr);
  end;

  Assert((rc = SQLITE_OK) = (pMod <> nil));
  if rc = SQLITE_OK then begin
    azArg := nil;
    if nDequote > 1 then azArg := PPChar(@azDequote[1]);
    if nDequote > 1 then nArg := nDequote - 1 else nArg := 0;
    rc := pMod^.xCreate(nArg, azArg, @pTok);
  end;

  if rc = SQLITE_OK then begin
    pTab := PFts3tokTable(sqlite3_malloc(i32(SizeOf(TFts3tokTable))));
    if pTab = nil then
      rc := SQLITE_NOMEM;
  end;

  if rc = SQLITE_OK then begin
    libc_memset(pTab, 0, SizeOf(TFts3tokTable));
    pTab^.pMod := pMod;
    pTab^.pTok := pTok;
    ppVtab^ := @pTab^.base;
  end else begin
    if pTok <> nil then
      pMod^.xDestroy(pTok);
  end;

  sqlite3_free(azDequote);
  Result := rc;
end;

{ fts3_tokenize_vtab.c:223..229 — fts3tokDisconnectMethod.  Does the work
  for both xDisconnect and xDestroy (identical). }
function fts3tokDisconnectMethod(pVtab: PSqlite3Vtab): cint; cdecl;
var
  pTab: PFts3tokTable;
begin
  pTab := PFts3tokTable(pVtab);
  pTab^.pMod^.xDestroy(pTab^.pTok);
  sqlite3_free(pTab);
  Result := SQLITE_OK;
end;

{ fts3_tokenize_vtab.c:234..258 — fts3tokBestIndexMethod. }
function fts3tokBestIndexMethod(pVTab: PSqlite3Vtab;
  pInfo: PSqlite3IndexInfo): cint; cdecl;
var
  i: cint;
  pC: PSqlite3IndexConstraint;
  pUse: PSqlite3IndexConstraintUsage;
begin
  for i := 0 to pInfo^.nConstraint - 1 do begin
    pC := pInfo^.aConstraint;
    Inc(pC, i);
    if (pC^.usable <> 0)
    and (pC^.iColumn = 0)
    and (pC^.op = SQLITE_INDEX_CONSTRAINT_EQ) then begin
      pInfo^.idxNum := 1;
      pUse := pInfo^.aConstraintUsage;
      Inc(pUse, i);
      pUse^.argvIndex := 1;
      pUse^.omit := 1;
      pInfo^.estimatedCost := 1;
      Result := SQLITE_OK;
      Exit;
    end;
  end;

  pInfo^.idxNum := 0;
  Assert(pInfo^.estimatedCost > 1000000.0);

  Result := SQLITE_OK;
end;

{ fts3_tokenize_vtab.c:263..275 — fts3tokOpenMethod. }
function fts3tokOpenMethod(pVTab: PSqlite3Vtab;
  ppCsr: PPSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFts3tokCursor;
begin
  pCsr := PFts3tokCursor(sqlite3_malloc(i32(SizeOf(TFts3tokCursor))));
  if pCsr = nil then begin
    Result := SQLITE_NOMEM;
    Exit;
  end;
  libc_memset(pCsr, 0, SizeOf(TFts3tokCursor));

  ppCsr^ := PSqlite3VtabCursor(@pCsr^.base);
  Result := SQLITE_OK;
end;

{ fts3_tokenize_vtab.c:281..295 — fts3tokResetCursor.  Reset the cursor as
  if just returned by fts3tokOpenMethod(). }
procedure fts3tokResetCursor(pCsr: PFts3tokCursor);
var
  pTab: PFts3tokTable;
begin
  if pCsr^.pCsr <> nil then begin
    pTab := PFts3tokTable(pCsr^.base.pVtab);
    pTab^.pMod^.xClose(pCsr^.pCsr);
    pCsr^.pCsr := nil;
  end;
  sqlite3_free(pCsr^.zInput);
  pCsr^.zInput := nil;
  pCsr^.zToken := nil;
  pCsr^.nToken := 0;
  pCsr^.iStart := 0;
  pCsr^.iEnd := 0;
  pCsr^.iPos := 0;
  pCsr^.iRowid := 0;
end;

{ fts3_tokenize_vtab.c:300..306 — fts3tokCloseMethod. }
function fts3tokCloseMethod(pCursor: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFts3tokCursor;
begin
  pCsr := PFts3tokCursor(pCursor);
  fts3tokResetCursor(pCsr);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ fts3_tokenize_vtab.c:311..328 — fts3tokNextMethod. }
function fts3tokNextMethod(pCursor: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFts3tokCursor;
  pTab: PFts3tokTable;
  rc: cint;
begin
  pCsr := PFts3tokCursor(pCursor);
  pTab := PFts3tokTable(pCursor^.pVtab);

  Inc(pCsr^.iRowid);
  rc := pTab^.pMod^.xNext(pCsr^.pCsr,
      @pCsr^.zToken, @pCsr^.nToken,
      @pCsr^.iStart, @pCsr^.iEnd, @pCsr^.iPos);

  if rc <> SQLITE_OK then begin
    fts3tokResetCursor(pCsr);
    if rc = SQLITE_DONE then rc := SQLITE_OK;
  end;

  Result := rc;
end;

{ fts3_tokenize_vtab.c:333..365 — fts3tokFilterMethod. }
function fts3tokFilterMethod(pCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PChar;
  nVal: cint; apVal: PPsqlite3_value): cint; cdecl;
var
  rc: cint;
  pCsr: PFts3tokCursor;
  pTab: PFts3tokTable;
  zByte: PChar;
  nByte: sqlite3_int64;
begin
  rc := SQLITE_ERROR;
  pCsr := PFts3tokCursor(pCursor);
  pTab := PFts3tokTable(pCursor^.pVtab);

  fts3tokResetCursor(pCsr);
  if idxNum = 1 then begin
    zByte := PChar(sqlite3_value_text(apVal[0]));
    nByte := sqlite3_value_bytes(apVal[0]);
    pCsr^.zInput := PChar(sqlite3_malloc64(u64(nByte + 1)));
    if pCsr^.zInput = nil then
      rc := SQLITE_NOMEM
    else begin
      if nByte > 0 then libc_memcpy(pCsr^.zInput, zByte, NativeUInt(nByte));
      pCsr^.zInput[nByte] := #0;
      rc := pTab^.pMod^.xOpen(pTab^.pTok, pCsr^.zInput, cint(nByte),
              @pCsr^.pCsr);
      if rc = SQLITE_OK then
        pCsr^.pCsr^.pTokenizer := pTab^.pTok;
    end;
  end;

  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  Result := fts3tokNextMethod(pCursor);
end;

{ fts3_tokenize_vtab.c:370..373 — fts3tokEofMethod. }
function fts3tokEofMethod(pCursor: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFts3tokCursor;
begin
  pCsr := PFts3tokCursor(pCursor);
  if pCsr^.zToken = nil then Result := 1 else Result := 0;
end;

{ fts3_tokenize_vtab.c:378..405 — fts3tokColumnMethod.
  CREATE TABLE x(input, token, start, end, position) }
function fts3tokColumnMethod(pCursor: PSqlite3VtabCursor;
  pCtx: Psqlite3_context; iCol: cint): cint; cdecl;
var
  pCsr: PFts3tokCursor;
begin
  pCsr := PFts3tokCursor(pCursor);
  case iCol of
    0: sqlite3_result_text(pCtx, PAnsiChar(pCsr^.zInput), -1, SQLITE_TRANSIENT);
    1: sqlite3_result_text(pCtx, PAnsiChar(pCsr^.zToken), pCsr^.nToken,
         SQLITE_TRANSIENT);
    2: sqlite3_result_int(pCtx, pCsr^.iStart);
    3: sqlite3_result_int(pCtx, pCsr^.iEnd);
  else
    Assert(iCol = 4);
    sqlite3_result_int(pCtx, pCsr^.iPos);
  end;
  Result := SQLITE_OK;
end;

{ fts3_tokenize_vtab.c:410..417 — fts3tokRowidMethod. }
function fts3tokRowidMethod(pCursor: PSqlite3VtabCursor;
  pRowid: Pi64): cint; cdecl;
var
  pCsr: PFts3tokCursor;
begin
  pCsr := PFts3tokCursor(pCursor);
  pRowid^ := sqlite3_int64(pCsr^.iRowid);
  Result := SQLITE_OK;
end;

{ fts3_tokenize_vtab.c:424..450 — the static fts3tok_module record. }
var
  fts3tok_module: Tsqlite3_module;

procedure initFts3TokModule;
begin
  FillChar(fts3tok_module, SizeOf(fts3tok_module), 0);
  fts3tok_module.iVersion    := 0;
  fts3tok_module.xCreate     := @fts3tokConnectMethod;
  fts3tok_module.xConnect    := @fts3tokConnectMethod;
  fts3tok_module.xBestIndex  := @fts3tokBestIndexMethod;
  fts3tok_module.xDisconnect := @fts3tokDisconnectMethod;
  fts3tok_module.xDestroy    := @fts3tokDisconnectMethod;
  fts3tok_module.xOpen       := @fts3tokOpenMethod;
  fts3tok_module.xClose      := @fts3tokCloseMethod;
  fts3tok_module.xFilter     := @fts3tokFilterMethod;
  fts3tok_module.xNext       := @fts3tokNextMethod;
  fts3tok_module.xEof        := @fts3tokEofMethod;
  fts3tok_module.xColumn     := @fts3tokColumnMethod;
  fts3tok_module.xRowid      := @fts3tokRowidMethod;
end;

{ fts3_tokenize_vtab.c:423..457 — sqlite3Fts3InitTok. }
function sqlite3Fts3InitTok(db: PTsqlite3; pHash: PFts3Hash;
  xDestroy: TxModuleDestroy): cint;
begin
  initFts3TokModule;
  Result := sqlite3_create_module_v2(
      db, PAnsiChar('fts3tokenize'), @fts3tok_module, Pointer(pHash),
      Pointer(xDestroy));
end;

{ ===================================================================== }
{ 6.40.1.i — fts3_expr.c — the MATCH query-expression parser.            }
{                                                                        }
{ SYNTAX MODE: the oracle libsqlite3.so is built WITH                    }
{ SQLITE_ENABLE_FTS3_PARENTHESIS (verified: pragma_compile_options lists  }
{ ENABLE_FTS3_PARENTHESIS), i.e. the NEW/parenthesis syntax.  fts3_expr.c }
{ selects this at compile time via the macro sqlite3_fts3_enable_         }
{ parentheses (fts3_expr.c:66..74):                                       }
{   * #ifdef SQLITE_TEST  -> it is a RUNTIME int (default 0), set by the   }
{     Tcl testfixture's `sqlite_fts3_enable_parentheses` linked var.      }
{   * else #ifdef SQLITE_ENABLE_FTS3_PARENTHESIS -> compile-constant 1.    }
{   * else -> compile-constant 0.                                         }
{ This port mirrors that exactly: under {$IFDEF SQLITE_TEST} (the Tcl      }
{ bridge build) it is a writable global defaulting to 0 (so testfixture    }
{ semantics match — the legacy path is active until a test flips it); in   }
{ the engine build (no SQLITE_TEST) it is a constant 1, matching the       }
{ oracle .so.  TODO(6.40.1.n/.o test wiring): port fts3_test.c's           }
{ Sqlitetestfts3_Init Tcl_LinkVar of `sqlite_fts3_enable_parentheses` so   }
{ the gated fts3*.test files that set it (fts3auto/fts3corrupt4/...) drive  }
{ the new-syntax path under the Tcl bridge.                               }
{ ===================================================================== }

{$IFDEF SQLITE_TEST}
{ fts3_expr.c:67 — exported, runtime-settable so both syntaxes test from
  one build.  Default 0 (legacy), matching tester.tcl:2614. }
var
  sqlite3_fts3_enable_parentheses: cint = 0;
{$ELSE}
{ fts3_expr.c:69..70 — the oracle build defines SQLITE_ENABLE_FTS3_PARENTHESIS. }
const
  sqlite3_fts3_enable_parentheses = 1;
{$ENDIF}

{ fts3_expr.c:116..118 — fts3isspace.  Accepts a char and returns 0 for any
  value outside the unsigned-char range (negative chars). }
function fts3isspace(c: Char): cint;
begin
  if (c = ' ') or (c = #9) or (c = #10) or (c = #13) or (c = #11) or (c = #12)
  then Result := 1
  else Result := 0;
end;

{ fts3_expr.c:125..129 — sqlite3Fts3MallocZero. }
function sqlite3Fts3MallocZero(nByte: sqlite3_int64): Pointer;
begin
  Result := sqlite3_malloc64(u64(nByte));
  if Result <> nil then libc_memset(Result, 0, NativeUInt(nByte));
end;

{ ---------------------------------------------------------------------
  fts3.c:966..975 — sqlite3Fts3ReadInt.  Ported here as a local static
  helper because fts3.c (the fts3/fts4 vtab module) is task 6.40.1.k and
  not yet ported; getNextNode needs it now for the "NEAR/n" span.
  TODO(6.40.1.k): promote to the shared fts3.c port and drop this copy.
  --------------------------------------------------------------------- }
function fts3ReadInt(const z: PChar; pnOut: Pcint): cint;
var
  iVal: u64;
  i: cint;
begin
  iVal := 0;
  i := 0;
  while (z[i] >= '0') and (z[i] <= '9') do begin
    iVal := iVal * 10 + u64(Ord(z[i]) - Ord('0'));
    if iVal > $7FFFFFFF then Exit(-1);
    Inc(i);
  end;
  pnOut^ := cint(iVal);
  Result := i;
end;

{ ---------------------------------------------------------------------
  fts3.c:6163..6175 — sqlite3Fts3EvalPhraseCleanup.  Ported here as a local
  static helper because fts3.c is task 6.40.1.k and not yet ported;
  fts3FreeExprNode needs it now.  On a freshly-PARSED tree every field this
  touches (doclist.aAll, pOrPoslist, aToken[].pSegcsr) is nil/zero — the
  parser never sets them — so for parser-built trees this is a safe no-op.
  The full body frees doclist.aAll, invalidates the OR poslist, and frees
  each aToken[].pSegcsr via fts3SegReaderCursorFree(); those two helpers
  belong to fts3.c/fts3_write.c.  TODO(6.40.1.j/.k): replace this minimal
  copy with the real one once the evaluator (which populates those fields)
  lands, and route the pSegcsr free through fts3SegReaderCursorFree().
  --------------------------------------------------------------------- }
procedure fts3EvalPhraseCleanupLocal(pPhrase: PFts3Phrase);
var
  i: cint;
begin
  if pPhrase <> nil then begin
    sqlite3_free(pPhrase^.doclist.aAll);
    { fts3EvalInvalidatePoslist: free pOrPoslist when it owns its buffer. }
    if pPhrase^.doclist.bFreeList <> 0 then
      sqlite3_free(pPhrase^.pOrPoslist);
    pPhrase^.pOrPoslist := nil;
    libc_memset(@pPhrase^.doclist, 0, NativeUInt(SizeOf(TFts3Doclist)));
    for i := 0 to pPhrase^.nToken - 1 do begin
      { TODO(6.40.1.j): fts3SegReaderCursorFree(aToken[i].pSegcsr). }
      Assert(pPhrase^.aToken[i].pSegcsr = nil);
      pPhrase^.aToken[i].pSegcsr := nil;
    end;
  end;
end;

{ fts3_expr.c:92..103 — struct ParseContext. }
type
  PParseContext = ^TParseContext;
  TParseContext = record
    pTokenizer  : Psqlite3_tokenizer;  { Tokenizer module }
    iLangid     : cint;                { Language id used with tokenizer }
    azCol       : PPChar;              { Array of column names for fts3 table }
    bFts4       : cint;                { True to allow FTS4-only syntax }
    nCol        : cint;                { Number of entries in azCol[] }
    iDefaultCol : cint;                { Default column to query }
    isNot       : cint;                { True if getNextNode() sees a unary - }
    pCtx        : Psqlite3_context;    { Write error message here }
    nNest       : cint;                { Number of nested brackets }
  end;

{ Forward declarations (fts3_expr.c:162 — getNextNode calls fts3ExprParse). }
function fts3ExprParse(pParse: PParseContext; const z: PChar; n: cint;
  ppExpr: PPFts3Expr; pnConsumed: Pcint): cint; forward;
function getNextNode(pParse: PParseContext; const z: PChar; n: cint;
  ppExpr: PPFts3Expr; pnConsumed: Pcint): cint; forward;

{ Helper to access aToken[i] of a phrase by index (FLEXARRAY in C). }
function fts3PhraseTokenAt(pPhrase: PFts3Phrase; i: cint): PFts3PhraseToken;
  inline;
begin
  Result := @PFts3PhraseToken(@pPhrase^.aToken[0])[i];
end;

{ fts3_expr.c:169..179 — findBarredChar.  Search z[0..n) for a '"' (and, in
  parenthesis mode, '(' or ')').  Return the index of the first such char,
  or -1. }
function findBarredChar(const z: PChar; n: cint): cint;
var
  ii: cint;
begin
  for ii := 0 to n - 1 do begin
    if (z[ii] = '"')
    or ((sqlite3_fts3_enable_parentheses <> 0) and
        ((z[ii] = '(') or (z[ii] = ')'))) then
      Exit(ii);
  end;
  Result := -1;
end;

{ fts3_expr.c:193..273 — getNextToken.  Extract the next token from z[0..n)
  and build a single-token FTSQUERY_PHRASE Fts3Expr. }
function getNextToken(pParse: PParseContext; iCol: cint;
  const z: PChar; n: cint; ppExpr: PPFts3Expr; pnConsumed: Pcint): cint;
var
  pTokenizer: Psqlite3_tokenizer;
  pModule: Psqlite3_tokenizer_module;
  rc: cint;
  pCursor: Psqlite3_tokenizer_cursor;
  pRet: PFts3Expr;
  zToken: PChar;
  nToken, iStart, iEnd, iPosition: cint;
  nByte: sqlite3_int64;
  iBarred: cint;
  pTok0: PFts3PhraseToken;
begin
  pTokenizer := pParse^.pTokenizer;
  pModule := pTokenizer^.pModule;
  pRet := nil;

  pnConsumed^ := n;
  rc := sqlite3Fts3OpenTokenizer(pTokenizer, pParse^.iLangid, z, n, @pCursor);
  if rc = SQLITE_OK then begin
    nToken := 0; iStart := 0; iEnd := 0; iPosition := 0;
    rc := pModule^.xNext(pCursor, @zToken, @nToken, @iStart, @iEnd, @iPosition);
    if rc = SQLITE_OK then begin
      { Check this tokenization did not gobble up any barred characters; if
        it did, retry over only the part of the buffer up to the first one. }
      iBarred := findBarredChar(z, iEnd);
      if iBarred >= 0 then begin
        pModule^.xClose(pCursor);
        Result := getNextToken(pParse, iCol, z, iBarred, ppExpr, pnConsumed);
        Exit;
      end;

      nByte := sqlite3_int64(SizeOf(TFts3Expr))
             + (PtrUInt(@PFts3Phrase(nil)^.aToken[0]) + 1 * SizeOf(TFts3PhraseToken))
             + nToken;
      pRet := PFts3Expr(sqlite3Fts3MallocZero(nByte));
      if pRet = nil then
        rc := SQLITE_NOMEM
      else begin
        pRet^.eType := FTSQUERY_PHRASE;
        pRet^.pPhrase := PFts3Phrase(@PFts3Expr(pRet)[1]);
        pRet^.pPhrase^.nToken := 1;
        pRet^.pPhrase^.iColumn := iCol;
        pTok0 := fts3PhraseTokenAt(pRet^.pPhrase, 0);
        pTok0^.n := nToken;
        { aToken[0].z = (char*)&aToken[1] — token text follows the 1-elem
          flexible array. }
        pTok0^.z := PChar(@PFts3PhraseToken(@pRet^.pPhrase^.aToken[0])[1]);
        libc_memcpy(pTok0^.z, zToken, NativeUInt(nToken));

        if (iEnd < n) and (z[iEnd] = '*') then begin
          pTok0^.isPrefix := 1;
          Inc(iEnd);
        end;

        while True do begin
          if (sqlite3_fts3_enable_parentheses = 0)
          and (iStart > 0) and (z[iStart - 1] = '-') then begin
            pParse^.isNot := 1;
            Dec(iStart);
          end else if (pParse^.bFts4 <> 0) and (iStart > 0)
                  and (z[iStart - 1] = '^') then begin
            pTok0^.bFirst := 1;
            Dec(iStart);
          end else
            break;
        end;
      end;
      pnConsumed^ := iEnd;
    end else if (n <> 0) and (rc = SQLITE_DONE) then begin
      iBarred := findBarredChar(z, n);
      if iBarred >= 0 then pnConsumed^ := iBarred;
      rc := SQLITE_OK;
    end;

    pModule^.xClose(pCursor);
  end;

  ppExpr^ := pRet;
  Result := rc;
end;

{ fts3_expr.c:280..286 — fts3ReallocOrFree.  Enlarge an allocation; on OOM
  free the old block. }
function fts3ReallocOrFree(pOrig: Pointer; nNew: sqlite3_int64): Pointer;
begin
  Result := sqlite3_realloc64(pOrig, u64(nNew));
  if Result = nil then sqlite3_free(pOrig);
end;

{ fts3_expr.c:300..407 — getNextString.  Tokenize an entire quoted phrase
  buffer into one multi-token FTSQUERY_PHRASE Fts3Expr (single allocation). }
function getNextString(pParse: PParseContext;
  const zInput: PChar; nInput: cint; ppExpr: PPFts3Expr): cint;
var
  pTokenizer: Psqlite3_tokenizer;
  pModule: Psqlite3_tokenizer_module;
  rc: cint;
  p: PFts3Expr;
  pCursor: Psqlite3_tokenizer_cursor;
  zTemp: PChar;
  nTemp: i64;
  nSpace: cint;
  nToken: cint;
  ii: cint;
  zByte: PChar;
  nByte, iBegin, iEnd, iPos: cint;
  pToken: PFts3PhraseToken;
  jj: cint;
  zBuf: PChar;
  pPhrase: PFts3Phrase;
  label getnextstring_out;
begin
  pTokenizer := pParse^.pTokenizer;
  pModule := pTokenizer^.pModule;
  p := nil;
  pCursor := nil;
  zTemp := nil;
  nTemp := 0;

  { const int nSpace = sizeof(Fts3Expr) + SZ_FTS3PHRASE(1); }
  nSpace := cint(SizeOf(TFts3Expr))
          + cint(PtrUInt(@PFts3Phrase(nil)^.aToken[0])
                 + 1 * SizeOf(TFts3PhraseToken));
  nToken := 0;

  rc := sqlite3Fts3OpenTokenizer(pTokenizer, pParse^.iLangid, zInput, nInput,
          @pCursor);
  if rc = SQLITE_OK then begin
    ii := 0;
    while rc = SQLITE_OK do begin
      nByte := 0; iBegin := 0; iEnd := 0; iPos := 0;
      rc := pModule^.xNext(pCursor, @zByte, @nByte, @iBegin, @iEnd, @iPos);
      if rc = SQLITE_OK then begin
        p := PFts3Expr(fts3ReallocOrFree(p,
               nSpace + ii * SizeOf(TFts3PhraseToken)));
        zTemp := PChar(fts3ReallocOrFree(zTemp, nTemp + nByte));
        if (zTemp = nil) or (p = nil) then begin
          rc := SQLITE_NOMEM;
          goto getnextstring_out;
        end;

        Assert(nToken = ii);
        { pToken = &((Fts3Phrase *)(&p[1]))->aToken[ii]; }
        pPhrase := PFts3Phrase(@PFts3Expr(p)[1]);
        pToken := fts3PhraseTokenAt(pPhrase, ii);
        libc_memset(pToken, 0, NativeUInt(SizeOf(TFts3PhraseToken)));

        libc_memcpy(@zTemp[nTemp], zByte, NativeUInt(nByte));
        nTemp := nTemp + nByte;

        pToken^.n := nByte;
        if (iEnd < nInput) and (zInput[iEnd] = '*') then
          pToken^.isPrefix := 1 else pToken^.isPrefix := 0;
        if (iBegin > 0) and (zInput[iBegin - 1] = '^') then
          pToken^.bFirst := 1 else pToken^.bFirst := 0;
        nToken := ii + 1;
      end;
      Inc(ii);
    end;
  end;

  if rc = SQLITE_DONE then begin
    zBuf := nil;
    p := PFts3Expr(fts3ReallocOrFree(p,
           nSpace + nToken * SizeOf(TFts3PhraseToken) + nTemp));
    if p = nil then begin
      rc := SQLITE_NOMEM;
      goto getnextstring_out;
    end;
    pPhrase := PFts3Phrase(@PFts3Expr(p)[1]);
    { memset(p, 0, (char *)&(((Fts3Phrase *)&p[1])->aToken[0]) - (char *)p); }
    libc_memset(p, 0,
      NativeUInt(PtrUInt(@pPhrase^.aToken[0]) - PtrUInt(p)));
    p^.eType := FTSQUERY_PHRASE;
    p^.pPhrase := pPhrase;
    p^.pPhrase^.iColumn := pParse^.iDefaultCol;
    p^.pPhrase^.nToken := nToken;

    { zBuf = (char *)&p->pPhrase->aToken[nToken]; }
    zBuf := PChar(@PFts3PhraseToken(@p^.pPhrase^.aToken[0])[nToken]);
    Assert((nTemp = 0) or (zTemp <> nil));
    if zTemp <> nil then
      libc_memcpy(zBuf, zTemp, NativeUInt(nTemp));

    for jj := 0 to p^.pPhrase^.nToken - 1 do begin
      pToken := fts3PhraseTokenAt(p^.pPhrase, jj);
      pToken^.z := zBuf;
      Inc(zBuf, pToken^.n);
    end;
    rc := SQLITE_OK;
  end;

getnextstring_out:
  if pCursor <> nil then
    pModule^.xClose(pCursor);
  sqlite3_free(zTemp);
  if rc <> SQLITE_OK then begin
    sqlite3_free(p);
    p := nil;
  end;
  ppExpr^ := p;
  Result := rc;
end;

{ fts3_expr.c:423..433 — the static aKeyword table. }
type
  PFts3Keyword = ^TFts3Keyword;
  TFts3Keyword = record
    z        : PChar;     { Keyword text }
    n        : cuchar;    { Length of the keyword }
    parenOnly: cuchar;    { Only valid in paren mode }
    eType    : cuchar;    { Keyword code }
  end;

const
  aKeyword: array[0..3] of TFts3Keyword = (
    (z: 'OR';   n: 2; parenOnly: 0; eType: FTSQUERY_OR),
    (z: 'AND';  n: 3; parenOnly: 1; eType: FTSQUERY_AND),
    (z: 'NOT';  n: 3; parenOnly: 1; eType: FTSQUERY_NOT),
    (z: 'NEAR'; n: 4; parenOnly: 0; eType: FTSQUERY_NEAR)
  );

{ fts3_expr.c:417..563 — getNextNode. }
function getNextNode(pParse: PParseContext; const z: PChar; n: cint;
  ppExpr: PPFts3Expr; pnConsumed: Pcint): cint;
var
  ii: cint;
  iCol: cint;
  iColLen: cint;
  rc: cint;
  pRet: PFts3Expr;
  zInput: PChar;
  nInput: cint;
  pKey: PFts3Keyword;
  nNear: cint;
  nKey: cint;
  cNext: Char;
  zStr: PChar;
  nStr: cint;
  nConsumed: cint;
begin
  pRet := nil;
  zInput := z;
  nInput := n;

  pParse^.isNot := 0;

  { Skip leading whitespace. }
  while (nInput > 0) and (fts3isspace(zInput^) <> 0) do begin
    Dec(nInput);
    Inc(zInput);
  end;
  if nInput = 0 then Exit(SQLITE_DONE);

  { See if we are dealing with a keyword. }
  for ii := 0 to (SizeOf(aKeyword) div SizeOf(TFts3Keyword)) - 1 do begin
    pKey := @aKeyword[ii];

    { C: if( (pKey->parenOnly & ~sqlite3_fts3_enable_parentheses)!=0 ) continue;
      ~enable is bitwise-not of 0 or 1.  Both operands are 0/1 here. }
    if (pKey^.parenOnly and (not cuchar(sqlite3_fts3_enable_parentheses))) <> 0
    then
      continue;

    if (nInput >= cint(pKey^.n))
    and (libc_memcmp(zInput, pKey^.z, NativeUInt(pKey^.n)) = 0) then begin
      nNear := SQLITE_FTS3_DEFAULT_NEAR_PARAM;
      nKey := pKey^.n;

      { If this is a "NEAR" keyword, check for an explicit nearness. }
      if pKey^.eType = FTSQUERY_NEAR then begin
        Assert(nKey = 4);
        if (zInput[4] = '/') and (zInput[5] >= '0') and (zInput[5] <= '9') then
          nKey := nKey + 1 + fts3ReadInt(@zInput[nKey + 1], @nNear);
      end;

      { For this to really be a keyword, the next byte must be whitespace,
        an open/close paren, a quote, or EOF. }
      cNext := zInput[nKey];
      if (fts3isspace(cNext) <> 0)
      or (cNext = '"') or (cNext = '(') or (cNext = ')') or (cNext = #0) then
      begin
        pRet := PFts3Expr(sqlite3Fts3MallocZero(SizeOf(TFts3Expr)));
        if pRet = nil then Exit(SQLITE_NOMEM);
        pRet^.eType := pKey^.eType;
        pRet^.nNear := nNear;
        ppExpr^ := pRet;
        pnConsumed^ := cint(PtrUInt(zInput) - PtrUInt(z)) + nKey;
        Exit(SQLITE_OK);
      end;
      { Wasn't a keyword after all (e.g. "ORacle").  Continue. }
    end;
  end;

  { See if we are dealing with a quoted phrase. }
  if zInput^ = '"' then begin
    ii := 1;
    while (ii < nInput) and (zInput[ii] <> '"') do Inc(ii);
    pnConsumed^ := cint(PtrUInt(zInput) - PtrUInt(z)) + ii + 1;
    if ii = nInput then Exit(SQLITE_ERROR);
    Result := getNextString(pParse, @zInput[1], ii - 1, ppExpr);
    Exit;
  end;

  if sqlite3_fts3_enable_parentheses <> 0 then begin
    if zInput^ = '(' then begin
      nConsumed := 0;
      Inc(pParse^.nNest);
      { !defined(SQLITE_MAX_EXPR_DEPTH) branch (the Pas port does not define
        it for FTS3): cap nest depth at 1000. }
      if pParse^.nNest > 1000 then Exit(SQLITE_ERROR);
      rc := fts3ExprParse(pParse, zInput + 1, nInput - 1, ppExpr, @nConsumed);
      pnConsumed^ := cint(PtrUInt(zInput) - PtrUInt(z)) + 1 + nConsumed;
      Exit(rc);
    end else if zInput^ = ')' then begin
      Dec(pParse^.nNest);
      pnConsumed^ := cint(PtrUInt(zInput) - PtrUInt(z)) + 1;
      ppExpr^ := nil;
      Exit(SQLITE_DONE);
    end;
  end;

  { Regular token (or EOF).  First detect an explicit column specifier. }
  iCol := pParse^.iDefaultCol;
  iColLen := 0;
  for ii := 0 to pParse^.nCol - 1 do begin
    zStr := PPChar(pParse^.azCol)[ii];
    nStr := cint(libc_strlen(zStr));
    if (nInput > nStr) and (zInput[nStr] = ':')
    and (sqlite3_strnicmp(zStr, zInput, nStr) = 0) then begin
      iCol := ii;
      iColLen := cint(PtrUInt(zInput) - PtrUInt(z)) + nStr + 1;
      break;
    end;
  end;
  rc := getNextToken(pParse, iCol, @z[iColLen], n - iColLen, ppExpr, pnConsumed);
  pnConsumed^ := pnConsumed^ + iColLen;
  Result := rc;
end;

{ fts3_expr.c:584..595 — opPrecedence. }
function opPrecedence(p: PFts3Expr): cint;
begin
  Assert(p^.eType <> FTSQUERY_PHRASE);
  if sqlite3_fts3_enable_parentheses <> 0 then
    Result := p^.eType
  else if p^.eType = FTSQUERY_NEAR then
    Result := 1
  else if p^.eType = FTSQUERY_OR then
    Result := 2
  else begin
    Assert(p^.eType = FTSQUERY_AND);
    Result := 3;
  end;
end;

{ fts3_expr.c:605..624 — insertBinaryOperator. }
procedure insertBinaryOperator(ppHead: PPFts3Expr; pPrev: PFts3Expr;
  pNew: PFts3Expr);
var
  pSplit: PFts3Expr;
begin
  pSplit := pPrev;
  while (pSplit^.pParent <> nil)
    and (opPrecedence(pSplit^.pParent) <= opPrecedence(pNew)) do
    pSplit := pSplit^.pParent;

  if pSplit^.pParent <> nil then begin
    Assert(pSplit^.pParent^.pRight = pSplit);
    pSplit^.pParent^.pRight := pNew;
    pNew^.pParent := pSplit^.pParent;
  end else
    ppHead^ := pNew;
  pNew^.pLeft := pSplit;
  pSplit^.pParent := pNew;
end;

{ fts3_expr.c:636..779 — fts3ExprParse. }
function fts3ExprParse(pParse: PParseContext; const z: PChar; n: cint;
  ppExpr: PPFts3Expr; pnConsumed: Pcint): cint;
var
  pRet: PFts3Expr;
  pPrev: PFts3Expr;
  pNotBranch: PFts3Expr;       { Only used in legacy parse mode }
  nIn: cint;
  zIn: PChar;
  rc: cint;
  isRequirePhrase: cint;
  p: PFts3Expr;
  nByte: cint;
  isPhrase: cint;
  pNot: PFts3Expr;
  eType: cint;
  pAnd: PFts3Expr;
  pIter: PFts3Expr;
  label exprparse_out;
begin
  pRet := nil;
  pPrev := nil;
  pNotBranch := nil;
  nIn := n;
  zIn := z;
  rc := SQLITE_OK;
  isRequirePhrase := 1;

  while rc = SQLITE_OK do begin
    p := nil;
    nByte := 0;

    rc := getNextNode(pParse, zIn, nIn, @p, @nByte);
    Assert((nByte > 0) or ((rc <> SQLITE_OK) and (p = nil)));
    if rc = SQLITE_OK then begin
      if p <> nil then begin
        if (sqlite3_fts3_enable_parentheses = 0)
        and (p^.eType = FTSQUERY_PHRASE) and (pParse^.isNot <> 0) then begin
          { Create an implicit NOT operator. }
          pNot := PFts3Expr(sqlite3Fts3MallocZero(SizeOf(TFts3Expr)));
          if pNot = nil then begin
            sqlite3Fts3ExprFree(p);
            rc := SQLITE_NOMEM;
            goto exprparse_out;
          end;
          pNot^.eType := FTSQUERY_NOT;
          pNot^.pRight := p;
          p^.pParent := pNot;
          if pNotBranch <> nil then begin
            pNot^.pLeft := pNotBranch;
            pNotBranch^.pParent := pNot;
          end;
          pNotBranch := pNot;
          p := pPrev;
        end else begin
          eType := p^.eType;
          if (eType = FTSQUERY_PHRASE) or (p^.pLeft <> nil) then
            isPhrase := 1 else isPhrase := 0;

          { A phrase (or bracketed expr) is required where isRequirePhrase
            is set; a binary operator there is a syntax error. }
          if (isPhrase = 0) and (isRequirePhrase <> 0) then begin
            sqlite3Fts3ExprFree(p);
            rc := SQLITE_ERROR;
            goto exprparse_out;
          end;

          if (isPhrase <> 0) and (isRequirePhrase = 0) then begin
            { Insert an implicit AND operator. }
            Assert((pRet <> nil) and (pPrev <> nil));
            pAnd := PFts3Expr(sqlite3Fts3MallocZero(SizeOf(TFts3Expr)));
            if pAnd = nil then begin
              sqlite3Fts3ExprFree(p);
              rc := SQLITE_NOMEM;
              goto exprparse_out;
            end;
            pAnd^.eType := FTSQUERY_AND;
            insertBinaryOperator(@pRet, pPrev, pAnd);
            pPrev := pAnd;
          end;

          { Catch a NEAR operand that is not a phrase. }
          if (pPrev <> nil) and (
            ((eType = FTSQUERY_NEAR) and (isPhrase = 0)
              and (pPrev^.eType <> FTSQUERY_PHRASE))
         or ((eType <> FTSQUERY_PHRASE) and (isPhrase <> 0)
              and (pPrev^.eType = FTSQUERY_NEAR))
          ) then begin
            sqlite3Fts3ExprFree(p);
            rc := SQLITE_ERROR;
            goto exprparse_out;
          end;

          if isPhrase <> 0 then begin
            if pRet <> nil then begin
              Assert((pPrev <> nil) and (pPrev^.pLeft <> nil)
                     and (pPrev^.pRight = nil));
              pPrev^.pRight := p;
              p^.pParent := pPrev;
            end else
              pRet := p;
          end else
            insertBinaryOperator(@pRet, pPrev, p);
          if isPhrase <> 0 then isRequirePhrase := 0 else isRequirePhrase := 1;
        end;
        pPrev := p;
      end;
      Assert(nByte > 0);
    end;
    Assert((rc <> SQLITE_OK) or ((nByte > 0) and (nByte <= nIn)));
    nIn := nIn - nByte;
    zIn := zIn + nByte;
  end;

  if (rc = SQLITE_DONE) and (pRet <> nil) and (isRequirePhrase <> 0) then
    rc := SQLITE_ERROR;

  if rc = SQLITE_DONE then begin
    rc := SQLITE_OK;
    if (sqlite3_fts3_enable_parentheses = 0) and (pNotBranch <> nil) then begin
      if pRet = nil then
        rc := SQLITE_ERROR
      else begin
        pIter := pNotBranch;
        while pIter^.pLeft <> nil do
          pIter := pIter^.pLeft;
        pIter^.pLeft := pRet;
        pRet^.pParent := pIter;
        pRet := pNotBranch;
      end;
    end;
  end;
  pnConsumed^ := n - nIn;

exprparse_out:
  if rc <> SQLITE_OK then begin
    sqlite3Fts3ExprFree(pRet);
    sqlite3Fts3ExprFree(pNotBranch);
    pRet := nil;
  end;
  ppExpr^ := pRet;
  Result := rc;
end;

{ fts3_expr.c:785..798 — fts3ExprCheckDepth. }
function fts3ExprCheckDepth(p: PFts3Expr; nMaxDepth: cint): cint;
var
  rc: cint;
begin
  rc := SQLITE_OK;
  if p <> nil then begin
    if nMaxDepth < 0 then
      rc := SQLITE_TOOBIG
    else begin
      rc := fts3ExprCheckDepth(p^.pLeft, nMaxDepth - 1);
      if rc = SQLITE_OK then
        rc := fts3ExprCheckDepth(p^.pRight, nMaxDepth - 1);
    end;
  end;
  Result := rc;
end;

{ fts3_expr.c:811..972 — fts3ExprBalance. }
function fts3ExprBalance(pp: PPFts3Expr; nMaxDepth: cint): cint;
var
  rc: cint;
  pRoot: PFts3Expr;
  pFree: PFts3Expr;        { List of free nodes. Linked by pParent. }
  eType: cint;
  apLeaf: PPFts3Expr;
  i: cint;
  p: PFts3Expr;
  iLvl: cint;
  pParent: PFts3Expr;
  pDel: PFts3Expr;
  pLeft, pRight: PFts3Expr;
begin
  rc := SQLITE_OK;
  pRoot := pp^;
  pFree := nil;
  eType := pRoot^.eType;

  if nMaxDepth = 0 then rc := SQLITE_ERROR;

  if rc = SQLITE_OK then begin
    if (eType = FTSQUERY_AND) or (eType = FTSQUERY_OR) then begin
      apLeaf := PPFts3Expr(sqlite3_malloc64(
                  u64(SizeOf(PFts3Expr)) * u64(nMaxDepth)));
      if apLeaf = nil then
        rc := SQLITE_NOMEM
      else
        libc_memset(apLeaf, 0, NativeUInt(SizeOf(PFts3Expr) * nMaxDepth));

      if rc = SQLITE_OK then begin
        { Set p to the left-most leaf in the tree of eType nodes. }
        p := pRoot;
        while p^.eType = eType do begin
          Assert((p^.pParent = nil) or (p^.pParent^.pLeft = p));
          Assert((p^.pLeft <> nil) and (p^.pRight <> nil));
          p := p^.pLeft;
        end;

        { Runs once per leaf in the tree of eType nodes. }
        while True do begin
          pParent := p^.pParent;     { Current parent of p }

          Assert((pParent = nil) or (pParent^.pLeft = p));
          p^.pParent := nil;
          if pParent <> nil then
            pParent^.pLeft := nil
          else
            pRoot := nil;
          rc := fts3ExprBalance(@p, nMaxDepth - 1);
          if rc <> SQLITE_OK then break;

          iLvl := 0;
          while (p <> nil) and (iLvl < nMaxDepth) do begin
            if apLeaf[iLvl] = nil then begin
              apLeaf[iLvl] := p;
              p := nil;
            end else begin
              Assert(pFree <> nil);
              pFree^.pLeft := apLeaf[iLvl];
              pFree^.pRight := p;
              pFree^.pLeft^.pParent := pFree;
              pFree^.pRight^.pParent := pFree;

              p := pFree;
              pFree := pFree^.pParent;
              p^.pParent := nil;
              apLeaf[iLvl] := nil;
            end;
            Inc(iLvl);
          end;
          if p <> nil then begin
            sqlite3Fts3ExprFree(p);
            rc := SQLITE_TOOBIG;
            break;
          end;

          { If that was the last leaf node, break out of the loop. }
          if pParent = nil then break;

          { Set p to the next leaf in the tree of eType nodes. }
          p := pParent^.pRight;
          while p^.eType = eType do p := p^.pLeft;

          { Remove pParent from the original tree. }
          Assert((pParent^.pParent = nil)
                 or (pParent^.pParent^.pLeft = pParent));
          pParent^.pRight^.pParent := pParent^.pParent;
          if pParent^.pParent <> nil then
            pParent^.pParent^.pLeft := pParent^.pRight
          else begin
            Assert(pParent = pRoot);
            pRoot := pParent^.pRight;
          end;

          { Link pParent into the free node list. }
          pParent^.pParent := pFree;
          pFree := pParent;
        end;

        if rc = SQLITE_OK then begin
          p := nil;
          for i := 0 to nMaxDepth - 1 do begin
            if apLeaf[i] <> nil then begin
              if p = nil then begin
                p := apLeaf[i];
                p^.pParent := nil;
              end else begin
                Assert(pFree <> nil);
                pFree^.pRight := p;
                pFree^.pLeft := apLeaf[i];
                pFree^.pLeft^.pParent := pFree;
                pFree^.pRight^.pParent := pFree;

                p := pFree;
                pFree := pFree^.pParent;
                p^.pParent := nil;
              end;
            end;
          end;
          pRoot := p;
        end else begin
          { An error occurred.  Delete apLeaf[] contents and the pFree list;
            sqlite3Fts3ExprFree(pRoot) below cleans up the rest. }
          for i := 0 to nMaxDepth - 1 do
            sqlite3Fts3ExprFree(apLeaf[i]);
          pDel := pFree;
          while pDel <> nil do begin
            pFree := pDel^.pParent;
            sqlite3_free(pDel);
            pDel := pFree;
          end;
        end;

        Assert(pFree = nil);
        sqlite3_free(apLeaf);
      end;
    end else if eType = FTSQUERY_NOT then begin
      pLeft := pRoot^.pLeft;
      pRight := pRoot^.pRight;

      pRoot^.pLeft := nil;
      pRoot^.pRight := nil;
      pLeft^.pParent := nil;
      pRight^.pParent := nil;

      rc := fts3ExprBalance(@pLeft, nMaxDepth - 1);
      if rc = SQLITE_OK then
        rc := fts3ExprBalance(@pRight, nMaxDepth - 1);

      if rc <> SQLITE_OK then begin
        sqlite3Fts3ExprFree(pRight);
        sqlite3Fts3ExprFree(pLeft);
      end else begin
        Assert((pLeft <> nil) and (pRight <> nil));
        pRoot^.pLeft := pLeft;
        pLeft^.pParent := pRoot;
        pRoot^.pRight := pRight;
        pRight^.pParent := pRoot;
      end;
    end;
  end;

  if rc <> SQLITE_OK then begin
    sqlite3Fts3ExprFree(pRoot);
    pRoot := nil;
  end;
  pp^ := pRoot;
  Result := rc;
end;

{ fts3_expr.c:985..1022 — fts3ExprParseUnbalanced. }
function fts3ExprParseUnbalanced(pTokenizer: Psqlite3_tokenizer; iLangid: cint;
  azCol: PPChar; bFts4: cint; nCol: cint; iDefaultCol: cint;
  const z: PChar; n: cint; ppExpr: PPFts3Expr): cint;
var
  nParsed: cint;
  rc: cint;
  sParse: TParseContext;
  nn: cint;
begin
  libc_memset(@sParse, 0, NativeUInt(SizeOf(TParseContext)));
  sParse.pTokenizer := pTokenizer;
  sParse.iLangid := iLangid;
  sParse.azCol := azCol;
  sParse.nCol := nCol;
  sParse.iDefaultCol := iDefaultCol;
  sParse.bFts4 := bFts4;
  if z = nil then begin
    ppExpr^ := nil;
    Exit(SQLITE_OK);
  end;
  nn := n;
  if nn < 0 then nn := cint(libc_strlen(z));
  rc := fts3ExprParse(@sParse, z, nn, ppExpr, @nParsed);
  Assert((rc = SQLITE_OK) or (ppExpr^ = nil));

  { Check for mismatched parenthesis. }
  if (rc = SQLITE_OK) and (sParse.nNest <> 0) then
    rc := SQLITE_ERROR;

  Result := rc;
end;

{ fts3_expr.c:1048..1087 — sqlite3Fts3ExprParse. }
function sqlite3Fts3ExprParse(pTokenizer: Psqlite3_tokenizer; iLangid: cint;
  azCol: PPChar; bFts4: cint; nCol: cint; iDefaultCol: cint;
  const z: PChar; n: cint; ppExpr: PPFts3Expr; pzErr: PPChar): cint;
var
  rc: cint;
begin
  rc := fts3ExprParseUnbalanced(pTokenizer, iLangid, azCol, bFts4, nCol,
          iDefaultCol, z, n, ppExpr);

  { Rebalance and check the depth does not exceed SQLITE_FTS3_MAX_EXPR_DEPTH. }
  if (rc = SQLITE_OK) and (ppExpr^ <> nil) then begin
    rc := fts3ExprBalance(ppExpr, SQLITE_FTS3_MAX_EXPR_DEPTH);
    if rc = SQLITE_OK then
      rc := fts3ExprCheckDepth(ppExpr^, SQLITE_FTS3_MAX_EXPR_DEPTH);
  end;

  if rc <> SQLITE_OK then begin
    sqlite3Fts3ExprFree(ppExpr^);
    ppExpr^ := nil;
    if rc = SQLITE_TOOBIG then begin
      fts3ErrMsg(pzErr,
        'FTS expression tree is too large (maximum depth %d)',
        [SQLITE_FTS3_MAX_EXPR_DEPTH]);
      rc := SQLITE_ERROR;
    end else if rc = SQLITE_ERROR then
      fts3ErrMsg(pzErr, 'malformed MATCH expression: [%s]', [z]);
  end;

  Result := rc;
end;

{ fts3_expr.c:1092..1097 — fts3FreeExprNode. }
procedure fts3FreeExprNode(p: PFts3Expr);
begin
  Assert((p^.eType = FTSQUERY_PHRASE) or (p^.pPhrase = nil));
  fts3EvalPhraseCleanupLocal(p^.pPhrase);
  sqlite3_free(p^.aMI);
  sqlite3_free(p);
end;

{ fts3_expr.c:1106..1125 — sqlite3Fts3ExprFree.  Iterative so a deep tree
  cannot overflow the stack. }
procedure sqlite3Fts3ExprFree(pDel: PFts3Expr);
var
  p: PFts3Expr;
  pParent: PFts3Expr;
begin
  Assert((pDel = nil) or (pDel^.pParent = nil));
  p := pDel;
  while (p <> nil) and ((p^.pLeft <> nil) or (p^.pRight <> nil)) do begin
    Assert((p^.pParent = nil) or (p = p^.pParent^.pRight)
           or (p = p^.pParent^.pLeft));
    if p^.pLeft <> nil then p := p^.pLeft else p := p^.pRight;
  end;
  while p <> nil do begin
    pParent := p^.pParent;
    fts3FreeExprNode(p);
    if (pParent <> nil) and (p = pParent^.pLeft) and (pParent^.pRight <> nil)
    then begin
      p := pParent^.pRight;
      while (p <> nil) and ((p^.pLeft <> nil) or (p^.pRight <> nil)) do begin
        Assert((p = p^.pParent^.pRight) or (p = p^.pParent^.pLeft));
        if p^.pLeft <> nil then p := p^.pLeft else p := p^.pRight;
      end;
    end else
      p := pParent;
  end;
end;

{$IFDEF SQLITE_TEST}
{ ---------------------------------------------------------------------
  fts3_expr.c:1146..1313 — the SQLITE_TEST-only expression-parser test
  interface (fts3_exprtest / fts3_exprtest_rebalance).  Compiled only into
  the Tcl bridge (build_tcl_lib.sh passes -dSQLITE_TEST).  exprToString
  serialises a parsed tree to text; the format is the contract the gated
  fts3expr*.test files assert against.
  --------------------------------------------------------------------- }

{ fts3_expr.c:1146..1187 — exprToString.  Recursively render pExpr to a
  sqlite3_mprintf-allocated string; zBuf (if non-nil) is prepended and freed.
  C uses the %z conversion (take ownership of/free the string argument); the
  Pas printf lacks %z, so we render the new segment and concat-then-free by
  hand to preserve identical semantics and byte output. }
function exprToString(pExpr: PFts3Expr; zBuf: PChar): PChar;
var
  pPhrase: PFts3Phrase;
  i: cint;
  zNew: PChar;
  pTok: PFts3PhraseToken;
  pfx: PChar;

  { Append the rendering of zAdd onto zBuf, freeing both inputs as %z would;
    returns the freshly-mprintf'd combined string (or nil on OOM). }
  function ZCat(zHead: PChar; const zTail: PChar): PChar;
  begin
    if zHead = nil then Exit(nil);
    Result := PChar(sqlite3PfMprintf(PAnsiChar('%s%s'), [zHead, zTail]));
    sqlite3_free(zHead);
  end;

begin
  if pExpr = nil then
    Exit(PChar(sqlite3PfMprintf(PAnsiChar(''), [])));

  case pExpr^.eType of
    FTSQUERY_PHRASE: begin
      pPhrase := pExpr^.pPhrase;
      { "%zPHRASE %d 0" }
      zNew := PChar(sqlite3PfMprintf(PAnsiChar('PHRASE %d 0'),
                [pPhrase^.iColumn]));
      if zBuf <> nil then begin
        zBuf := ZCat(zBuf, zNew);
        sqlite3_free(zNew);
      end else
        zBuf := zNew;
      i := 0;
      while (zBuf <> nil) and (i < pPhrase^.nToken) do begin
        pTok := fts3PhraseTokenAt(pPhrase, i);
        if pTok^.isPrefix <> 0 then pfx := '+' else pfx := '';
        { "%z %.*s%s" }
        zNew := PChar(sqlite3PfMprintf(PAnsiChar(' %.*s%s'),
                  [pTok^.n, pTok^.z, pfx]));
        zBuf := ZCat(zBuf, zNew);
        sqlite3_free(zNew);
        Inc(i);
      end;
      Exit(zBuf);
    end;

    FTSQUERY_NEAR: begin
      zNew := PChar(sqlite3PfMprintf(PAnsiChar('NEAR/%d '), [pExpr^.nNear]));
      if zBuf <> nil then begin zBuf := ZCat(zBuf, zNew); sqlite3_free(zNew); end
      else zBuf := zNew;
    end;
    FTSQUERY_NOT: begin
      zNew := PChar(sqlite3PfMprintf(PAnsiChar('NOT '), []));
      if zBuf <> nil then begin zBuf := ZCat(zBuf, zNew); sqlite3_free(zNew); end
      else zBuf := zNew;
    end;
    FTSQUERY_AND: begin
      zNew := PChar(sqlite3PfMprintf(PAnsiChar('AND '), []));
      if zBuf <> nil then begin zBuf := ZCat(zBuf, zNew); sqlite3_free(zNew); end
      else zBuf := zNew;
    end;
    FTSQUERY_OR: begin
      zNew := PChar(sqlite3PfMprintf(PAnsiChar('OR '), []));
      if zBuf <> nil then begin zBuf := ZCat(zBuf, zNew); sqlite3_free(zNew); end
      else zBuf := zNew;
    end;
  end;

  if zBuf <> nil then begin
    zNew := PChar(sqlite3PfMprintf(PAnsiChar('{'), []));
    zBuf := ZCat(zBuf, zNew); sqlite3_free(zNew);
  end;
  if zBuf <> nil then zBuf := exprToString(pExpr^.pLeft, zBuf);
  if zBuf <> nil then begin
    zNew := PChar(sqlite3PfMprintf(PAnsiChar('} {'), []));
    zBuf := ZCat(zBuf, zNew); sqlite3_free(zNew);
  end;
  if zBuf <> nil then zBuf := exprToString(pExpr^.pRight, zBuf);
  if zBuf <> nil then begin
    zNew := PChar(sqlite3PfMprintf(PAnsiChar('}'), []));
    zBuf := ZCat(zBuf, zNew); sqlite3_free(zNew);
  end;

  Result := zBuf;
end;

{ fts3_expr.c:1203..1282 — fts3ExprTestCommon. }
procedure fts3ExprTestCommon(bRebalance: cint; context: Psqlite3_context;
  argc: cint; argv: PPsqlite3_value);
var
  pTokenizer: Psqlite3_tokenizer;
  rc: cint;
  azCol: PPChar;
  zExpr: PChar;
  nExpr: cint;
  nCol: cint;
  ii: cint;
  pExpr: PFts3Expr;
  zBuf: PChar;
  pHash: PFts3Hash;
  zTokenizer: PChar;
  zErr: PChar;
  zDummy: PChar;
  pArgv: PPsqlite3_value;
  label exprtest_out;
begin
  pTokenizer := nil;
  azCol := nil;
  zBuf := nil;
  zErr := nil;
  pExpr := nil;
  pArgv := argv;
  pHash := PFts3Hash(sqlite3_user_data(context));

  if argc < 3 then begin
    sqlite3_result_error(context,
      'Usage: fts3_exprtest(tokenizer, expr, col1, ...', -1);
    Exit;
  end;

  zTokenizer := PChar(sqlite3_value_text(PPsqlite3_value(pArgv)[0]));
  rc := sqlite3Fts3InitTokenizer(pHash, zTokenizer, @pTokenizer, @zErr);
  if rc <> SQLITE_OK then begin
    if rc = SQLITE_NOMEM then
      sqlite3_result_error_nomem(context)
    else
      sqlite3_result_error(context, PAnsiChar(zErr), -1);
    sqlite3_free(zErr);
    Exit;
  end;

  zExpr := PChar(sqlite3_value_text(PPsqlite3_value(pArgv)[1]));
  nExpr := sqlite3_value_bytes(PPsqlite3_value(pArgv)[1]);
  nCol := argc - 2;
  azCol := PPChar(sqlite3_malloc64(u64(nCol) * u64(SizeOf(PChar))));
  if azCol = nil then begin
    sqlite3_result_error_nomem(context);
    goto exprtest_out;
  end;
  for ii := 0 to nCol - 1 do
    PPChar(azCol)[ii] := PChar(sqlite3_value_text(PPsqlite3_value(pArgv)[ii + 2]));

  if bRebalance <> 0 then begin
    zDummy := nil;
    rc := sqlite3Fts3ExprParse(pTokenizer, 0, azCol, 0, nCol, nCol,
            zExpr, nExpr, @pExpr, @zDummy);
    Assert((rc = SQLITE_OK) or (pExpr = nil));
    sqlite3_free(zDummy);
  end else
    rc := fts3ExprParseUnbalanced(pTokenizer, 0, azCol, 0, nCol, nCol,
            zExpr, nExpr, @pExpr);

  if (rc <> SQLITE_OK) and (rc <> SQLITE_NOMEM) then
    sqlite3_result_error(context, 'Error parsing expression', -1)
  else begin
    if rc = SQLITE_NOMEM then
      zBuf := nil
    else
      zBuf := exprToString(pExpr, nil);
    if (rc = SQLITE_NOMEM) or (zBuf = nil) then
      sqlite3_result_error_nomem(context)
    else begin
      sqlite3_result_text(context, PAnsiChar(zBuf), -1, SQLITE_TRANSIENT);
      sqlite3_free(zBuf);
    end;
  end;

  sqlite3Fts3ExprFree(pExpr);

exprtest_out:
  if pTokenizer <> nil then
    rc := pTokenizer^.pModule^.xDestroy(pTokenizer);
  sqlite3_free(azCol);
end;

{ fts3_expr.c:1284..1290 — fts3ExprTest (= fts3_exprtest). }
procedure fts3ExprTest(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
begin
  fts3ExprTestCommon(0, context, argc, argv);
end;

{ fts3_expr.c:1291..1297 — fts3ExprTestRebalance (= fts3_exprtest_rebalance). }
procedure fts3ExprTestRebalance(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
begin
  fts3ExprTestCommon(1, context, argc, argv);
end;

{ fts3_expr.c:1303..1313 — sqlite3Fts3ExprInitTestInterface. }
function sqlite3Fts3ExprInitTestInterface(db: PTsqlite3; pHash: PFts3Hash): cint;
var
  rc: cint;
begin
  rc := sqlite3_create_function(db, PAnsiChar('fts3_exprtest'), -1,
          SQLITE_UTF8, Pointer(pHash), @fts3ExprTest, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, PAnsiChar('fts3_exprtest_rebalance'), -1,
            SQLITE_UTF8, Pointer(pHash), @fts3ExprTestRebalance, nil, nil);
  Result := rc;
end;
{$ENDIF}

{ ===================================================================== }
{ 6.40.1.j — fts3_write.c — segment writer/reader/merge core + xUpdate.   }
{                                                                        }
{ Sub-sections (in dependency order, matching the C file):               }
{   1. FTS3 varint codecs (fts3.c:331..442 — depended on here)           }
{   2. SQL statement registry (fts3SqlStmt + aStmt + fts3SqlExec)        }
{   3. pending-terms hash + accumulation                                 }
{   4. segment WRITER (node building, prefix compression, write)         }
{   5. segment READER (multi-way merge, doclist merge, column filter)    }
{   6. xUpdate path (delete/insert, %_docsize/%_stat FTS4 maintenance)    }
{   7. maintenance (optimize, incr-merge, integrity-check, deferred)     }
{                                                                        }
{ CROSS-BOUNDARY STUBS for 6.40.1.k (fts3.c — the fts3/fts4 vtab module): }
{   sqlite3Fts3SegReaderCursor  (fts3.c:3038)                            }
{   sqlite3Fts3DoclistPrev      (fts3.c)                                 }
{   sqlite3Fts3FirstFilter      (fts3.c:2760)                            }
{   sqlite3Fts3CreateStatTable  (fts3.c:665)                             }
{ These four are CALLED by this file but DEFINED in fts3.c.  Local        }
{ forward-declared stubs are provided below (clearly marked) so .j        }
{ compiles standalone; .k must replace them with the real ports and       }
{ delete the stubs.                                                       }
{ ===================================================================== }

{ FTS_MAX_APPENDABLE_HEIGHT (fts3_write.c:28). }
const
  { sqlite3.h public SQLITE_PREPARE_* flag bits (not exported by main). }
  FTS3_SQLITE_PREPARE_PERSISTENT = $01;
  FTS3_SQLITE_PREPARE_NO_VTAB    = $04;
  FTS3_SQLITE_PREPARE_FROM_DDL   = $20;  { sqlite3.h:4486 public value }
  { sqlite3.h conflict-resolution code returned by sqlite3_vtab_on_conflict. }
  FTS3_SQLITE_REPLACE = 5;

  FTS_MAX_APPENDABLE_HEIGHT = 16;
  { fts3_write.c:40 — node padding so two varints can always be read safely. }
  FTS3_NODE_PADDING = FTS3_VARINT_MAX*2;
  { fts3_write.c:65..66 — incremental-load chunk size/threshold (non-TEST). }
  FTS3_NODE_CHUNKSIZE = (4*1024);
  FTS3_NODE_CHUNK_THRESHOLD = FTS3_NODE_CHUNKSIZE*4;
  { fts3Int.h:203..204 }
  LARGEST_INT64  = sqlite3_int64($7fffffffffffffff);

{ qsort from libc, used by sqlite3Fts3SegReaderPending (fts3_write.c:1771). }
type
  TFts3QSortCmp = function(const a, b: Pointer): cint; cdecl;
procedure libc_qsort(base: Pointer; nmemb, size: NativeUInt;
  compar: TFts3QSortCmp); cdecl; external 'c' name 'qsort';

type
  { fts3_write.c:217..228 — struct SegmentNode (interior tree node). }
  PSegmentNode  = ^TSegmentNode;
  PPSegmentNode = ^PSegmentNode;
  TSegmentNode = record
    pParent  : PSegmentNode;     { Parent node (or NULL for root node) }
    pRight   : PSegmentNode;     { Pointer to right-sibling }
    pLeftmost: PSegmentNode;     { Pointer to left-most node of this depth }
    nEntry   : cint;             { Number of terms written to node so far }
    zTerm    : PChar;            { Pointer to previous term buffer }
    nTerm    : cint;             { Number of bytes in zTerm }
    nMalloc  : cint;             { Size of malloc'd buffer at zMalloc }
    zMalloc  : PChar;            { Malloc'd space (possibly) used for zTerm }
    nData    : cint;             { Bytes of valid data so far }
    aData    : PChar;            { Node data }
  end;

  { fts3_write.c:185..197 — struct SegmentWriter. }
  PSegmentWriter  = ^TSegmentWriter;
  PPSegmentWriter = ^PSegmentWriter;
  TSegmentWriter = record
    pTree    : PSegmentNode;     { Pointer to interior tree structure }
    iFirst   : sqlite3_int64;    { First slot in %_segments written }
    iFree    : sqlite3_int64;    { Next free slot in %_segments }
    zTerm    : PChar;            { Pointer to previous term buffer }
    nTerm    : cint;             { Number of bytes in zTerm }
    nMalloc  : cint;             { Size of malloc'd buffer at zMalloc }
    zMalloc  : PChar;            { Malloc'd space (possibly) used for zTerm }
    nSize    : cint;             { Size of allocation at aData }
    nData    : cint;             { Bytes of data in aData }
    aData    : PChar;            { Pointer to block from malloc() }
    nLeafData: sqlite3_int64;    { Number of bytes of leaf data written }
  end;

  { fts3_write.c:3718..3722 — struct Blob (dynamic buffer). }
  PFtsBlob = ^TFtsBlob;
  TFtsBlob = record
    a     : PChar;               { Pointer to allocation }
    n     : cint;                { Number of valid bytes of data in a[] }
    nAlloc: cint;                { Allocated size of a[] (nAlloc>=n) }
  end;

  { fts3_write.c:3728..3732 — struct NodeWriter. }
  PNodeWriter = ^TNodeWriter;
  TNodeWriter = record
    iBlock: sqlite3_int64;       { Current block id }
    key   : TFtsBlob;            { Last key written to the current block }
    block : TFtsBlob;            { Current block image }
  end;

  { fts3_write.c:3738..3748 — struct IncrmergeWriter. }
  PIncrmergeWriter = ^TIncrmergeWriter;
  TIncrmergeWriter = record
    nLeafEst   : sqlite3_int64;  { Space allocated for leaf blocks }
    nWork      : sqlite3_int64;  { Number of leaf pages flushed }
    iAbsLevel  : sqlite3_int64;  { Absolute level of input segments }
    iIdx       : cint;           { Index of *output* segment in iAbsLevel+1 }
    iStart     : sqlite3_int64;  { Block number of first allocated block }
    iEnd       : sqlite3_int64;  { Block number of last allocated block }
    nLeafData  : sqlite3_int64;  { Bytes of leaf page data so far }
    bNoLeafData: cuchar;         { If true, store 0 for segment size }
    aNodeWriter: array[0..FTS_MAX_APPENDABLE_HEIGHT-1] of TNodeWriter;
  end;

  { fts3_write.c:3758..3768 — struct NodeReader. }
  PNodeReader = ^TNodeReader;
  TNodeReader = record
    aNode   : PChar;
    nNode   : cint;
    iOff    : cint;              { Current offset within aNode[] }
    { Output variables. Containing the current node entry. }
    iChild  : sqlite3_int64;     { Pointer to child node }
    term    : TFtsBlob;          { Current term }
    aDoclist: PChar;             { Pointer to doclist }
    nDoclist: cint;              { Size of doclist in bytes }
  end;

{ MergeCount(P): in the engine build this is the constant FTS3_MERGE_COUNT;
  under SQLITE_TEST it is p->nMergeCount (fts3Int.h:344..348).  We keep the
  field unconditionally but read it only when non-zero to match TEST. }
function MergeCount(p: PFts3Table): cint; inline;
begin
{$IFDEF SQLITE_TEST}
  Result := p^.nMergeCount;
{$ELSE}
  if p = nil then ;  { unused-param silence }
  Result := FTS3_MERGE_COUNT;
{$ENDIF}
end;

{ FTS_CORRUPT_VTAB (fts3Int.h:236 non-DEBUG). }
function FTS_CORRUPT_VTAB: cint; inline;
begin
  Result := SQLITE_CORRUPT_VTAB;
end;

function Fts3_MIN(x, y: sqlite3_int64): sqlite3_int64; inline;
begin if x < y then Result := x else Result := y; end;
function Fts3_MAX(x, y: sqlite3_int64): sqlite3_int64; inline;
begin if x > y then Result := x else Result := y; end;

{ ===================================================================== }
{ Section 1 — FTS3 varint codecs (fts3.c:331..442).                      }
{ NB: the FTS3 varint differs from the engine's core varint (max 10 not  }
{ 9 bytes); ported faithfully here.  Owner = fts3.c (6.40.1.k); .k reuses }
{ these and must NOT re-port them.                                       }
{ ===================================================================== }

{ fts3.c:331..341 — sqlite3Fts3PutVarint. }
function sqlite3Fts3PutVarint(p: PChar; v: sqlite3_int64): cint;
var
  q: PByte;
  vu: u64;
  pStart: PByte;
begin
  q := PByte(p);
  pStart := q;
  vu := u64(v);
  repeat
    q^ := Byte((vu and $7f) or $80);
    Inc(q);
    vu := vu shr 7;
  until vu = 0;
  PByte(PtrUInt(q) - 1)^ := PByte(PtrUInt(q) - 1)^ and $7f; { turn off high bit }
  Result := cint(PtrUInt(q) - PtrUInt(pStart));
end;

{ fts3.c:350..370 — sqlite3Fts3GetVarintU.  Hand-unrolled GETVARINT macros. }
function sqlite3Fts3GetVarintU(const pBuf: PChar; v: Pu64): cint;
var
  p, pStart: PByte;
  a: u32;
  b, c: u64;
  shift: cint;
begin
  p := PByte(pBuf);
  pStart := p;

  { GETVARINT_INIT(a,p,0, 0x00, 0x80, *v, 1) }
  a := p^; Inc(p);
  if (a and $80) = 0 then begin v^ := a; Exit(1); end;
  { GETVARINT_STEP(a,p,7, 0x7F, 0x4000, *v, 2) }
  a := (a and $7F) or (u32(p^) shl 7); Inc(p);
  if (a and $4000) = 0 then begin v^ := a; Exit(2); end;
  { GETVARINT_STEP(a,p,14, 0x3FFF, 0x200000, *v, 3) }
  a := (a and $3FFF) or (u32(p^) shl 14); Inc(p);
  if (a and $200000) = 0 then begin v^ := a; Exit(3); end;
  { GETVARINT_STEP(a,p,21, 0x1FFFFF, 0x10000000, *v, 4) }
  a := (a and $1FFFFF) or (u32(p^) shl 21); Inc(p);
  if (a and $10000000) = 0 then begin v^ := a; Exit(4); end;

  b := (a and $0FFFFFFF);
  shift := 28;
  while shift <= 63 do begin
    c := p^; Inc(p);
    b := b + ((c and $7F) shl shift);
    if (c and $80) = 0 then break;
    Inc(shift, 7);
  end;
  v^ := b;
  Result := cint(PtrUInt(p) - PtrUInt(pStart));
end;

{ fts3.c:377..379 — sqlite3Fts3GetVarint. }
function sqlite3Fts3GetVarint(const pBuf: PChar; v: Psqlite3_int64): cint;
begin
  Result := sqlite3Fts3GetVarintU(pBuf, Pu64(v));
end;

{ fts3.c:387..405 — sqlite3Fts3GetVarintBounded. }
function sqlite3Fts3GetVarintBounded(const pBuf, pEnd: PChar;
  v: Psqlite3_int64): cint;
var
  p, pStart, pX: PByte;
  b, c: u64;
  shift: cint;
begin
  p := PByte(pBuf);
  pStart := p;
  pX := PByte(pEnd);
  b := 0;
  shift := 0;
  while shift <= 63 do begin
    if PtrUInt(p) < PtrUInt(pX) then c := p^ else c := 0;
    Inc(p);
    b := b + ((c and $7F) shl shift);
    if (c and $80) = 0 then break;
    Inc(shift, 7);
  end;
  v^ := sqlite3_int64(b);
  Result := cint(PtrUInt(p) - PtrUInt(pStart));
end;

{ fts3.c:411..430 — sqlite3Fts3GetVarint32 (truncate to non-negative i32). }
function sqlite3Fts3GetVarint32(const p: PChar; pi: Pcint): cint;
var
  ptr: PByte;
  a: u32;
begin
  ptr := PByte(p);
  { GETVARINT_INIT(a,ptr,0, 0x00, 0x80, *pi, 1) }
  a := ptr^; Inc(ptr);
  if (a and $80) = 0 then begin pi^ := cint(a); Exit(1); end;
  { GETVARINT_STEP(a,ptr,7, 0x7F, 0x4000, *pi, 2) }
  a := (a and $7F) or (u32(ptr^) shl 7); Inc(ptr);
  if (a and $4000) = 0 then begin pi^ := cint(a); Exit(2); end;
  { GETVARINT_STEP(a,ptr,14, 0x3FFF, 0x200000, *pi, 3) }
  a := (a and $3FFF) or (u32(ptr^) shl 14); Inc(ptr);
  if (a and $200000) = 0 then begin pi^ := cint(a); Exit(3); end;
  { GETVARINT_STEP(a,ptr,21, 0x1FFFFF, 0x10000000, *pi, 4) }
  a := (a and $1FFFFF) or (u32(ptr^) shl 21); Inc(ptr);
  if (a and $10000000) = 0 then begin pi^ := cint(a); Exit(4); end;
  a := (a and $0FFFFFFF);
  pi^ := cint(a or ((u32(ptr^ and $07)) shl 28));
  Result := 5;
end;

{ fts3.c:435..442 — sqlite3Fts3VarintLen. }
function sqlite3Fts3VarintLen(v: u64): cint;
var
  i: cint;
begin
  i := 0;
  repeat
    Inc(i);
    v := v shr 7;
  until v = 0;
  Result := i;
end;

{ fts3Int.h:609..611 — fts3GetVarint32 macro. }
function fts3GetVarint32(const p: PChar; piVal: Pcint): cint;
begin
  if (Byte(p[0]) and $80) <> 0 then
    Result := sqlite3Fts3GetVarint32(p, piVal)
  else begin
    piVal^ := cint(Byte(p[0]));
    Result := 1;
  end;
end;

{ ===================================================================== }
{ CROSS-BOUNDARY STUBS for 6.40.1.k (fts3.c).  See header note above.    }
{ Each is forward-declared and given a minimal local body that returns    }
{ an error / no-op so that .j compiles + links standalone.  TODO(.k):     }
{ port the real fts3.c bodies and delete these.                          }
{ ===================================================================== }

{ fts3.c:3038 — sqlite3Fts3SegReaderCursor.  TODO(6.40.1.k). }
function sqlite3Fts3SegReaderCursor(p: PFts3Table; iLangid, iIndex,
  iLevel: cint; const zTerm: PChar; nTerm, isPrefix, isScan: cint;
  pCsr: PFts3MultiSegReader): cint; forward;

{ fts3.c — sqlite3Fts3DoclistPrev.  TODO(6.40.1.k). }
procedure sqlite3Fts3DoclistPrev(bDescIdx: cint; aDoclist: PChar;
  nDoclist: cint; ppIter: PPChar; piDocid: Psqlite3_int64;
  pnList: Pcint; pbEof: PByte); forward;

{ fts3.c:2760 — sqlite3Fts3FirstFilter.  TODO(6.40.1.k). }
function sqlite3Fts3FirstFilter(iDelta: sqlite3_int64; pList: PChar;
  nList: cint; pOut: PChar): cint; forward;

{ fts3.c:665 — sqlite3Fts3CreateStatTable.  TODO(6.40.1.k). }
procedure sqlite3Fts3CreateStatTable(pRc: Pcint; p: PFts3Table); forward;

{ Forward declarations for the internal mutual recursion. }
function fts3SegmentMerge(p: PFts3Table; iLangid, iIndex, iLevel: cint): cint;
  forward;
function fts3NodeAddTerm(p: PFts3Table; ppTree: PPSegmentNode;
  isCopyTerm: cint; const zTerm: PChar; nTerm: cint): cint; forward;

{ ===================================================================== }
{ Section 2 — SQL statement registry (fts3_write.c:305..527).            }
{ ===================================================================== }

{ fts3_write.c:280..292 — sqlite3Fts3PrepareStmt. }
function sqlite3Fts3PrepareStmt(p: PFts3Table; const zSql: PChar;
  bPersist: cint; bAllowVtab: cint; pp: PPVdbe): cint;
var
  f: u32;
begin
  f := FTS3_SQLITE_PREPARE_FROM_DDL;
  if bAllowVtab = 0 then f := f or FTS3_SQLITE_PREPARE_NO_VTAB;
  if bPersist <> 0 then f := f or FTS3_SQLITE_PREPARE_PERSISTENT;
  Result := sqlite3_prepare_v3(p^.db, PAnsiChar(zSql), -1, f, PPointer(pp), nil);
end;

const
  { fts3_write.c:311..409 — the aStmt[] SQL templates. }
  fts3AzSql: array[0..39] of PChar = (
{ 0  } 'DELETE FROM %Q.''%q_content'' WHERE rowid = ?',
{ 1  } 'SELECT NOT EXISTS(SELECT docid FROM %Q.''%q_content'' WHERE rowid!=?)',
{ 2  } 'DELETE FROM %Q.''%q_content''',
{ 3  } 'DELETE FROM %Q.''%q_segments''',
{ 4  } 'DELETE FROM %Q.''%q_segdir''',
{ 5  } 'DELETE FROM %Q.''%q_docsize''',
{ 6  } 'DELETE FROM %Q.''%q_stat''',
{ 7  } 'SELECT %s WHERE rowid=?',
{ 8  } 'SELECT (SELECT max(idx) FROM %Q.''%q_segdir'' WHERE level = ?) + 1',
{ 9  } 'REPLACE INTO %Q.''%q_segments''(blockid, block) VALUES(?, ?)',
{ 10 } 'SELECT coalesce((SELECT max(blockid) FROM %Q.''%q_segments'') + 1, 1)',
{ 11 } 'REPLACE INTO %Q.''%q_segdir'' VALUES(?,?,?,?,?,?)',
{ 12 } 'SELECT idx, start_block, leaves_end_block, end_block, root '
         + 'FROM %Q.''%q_segdir'' WHERE level = ? ORDER BY idx ASC',
{ 13 } 'SELECT idx, start_block, leaves_end_block, end_block, root '
         + 'FROM %Q.''%q_segdir'' WHERE level BETWEEN ? AND ?'
         + 'ORDER BY level DESC, idx ASC',
{ 14 } 'SELECT count(*) FROM %Q.''%q_segdir'' WHERE level = ?',
{ 15 } 'SELECT max(level) FROM %Q.''%q_segdir'' WHERE level BETWEEN ? AND ?',
{ 16 } 'DELETE FROM %Q.''%q_segdir'' WHERE level = ?',
{ 17 } 'DELETE FROM %Q.''%q_segments'' WHERE blockid BETWEEN ? AND ?',
{ 18 } 'INSERT INTO %Q.''%q_content'' VALUES(%s)',
{ 19 } 'DELETE FROM %Q.''%q_docsize'' WHERE docid = ?',
{ 20 } 'REPLACE INTO %Q.''%q_docsize'' VALUES(?,?)',
{ 21 } 'SELECT size FROM %Q.''%q_docsize'' WHERE docid=?',
{ 22 } 'SELECT value FROM %Q.''%q_stat'' WHERE id=?',
{ 23 } 'REPLACE INTO %Q.''%q_stat'' VALUES(?,?)',
{ 24 } '',
{ 25 } '',
{ 26 } 'DELETE FROM %Q.''%q_segdir'' WHERE level BETWEEN ? AND ?',
{ 27 } 'SELECT ? UNION SELECT level / (1024 * ?) FROM %Q.''%q_segdir''',
{ 28 } 'SELECT level, count(*) AS cnt FROM %Q.''%q_segdir'' '
         + '  GROUP BY level HAVING cnt>=?'
         + '  ORDER BY (level %% 1024) ASC, 2 DESC LIMIT 1',
{ 29 } 'SELECT 2 * total(1 + leaves_end_block - start_block) '
         + '  FROM (SELECT * FROM %Q.''%q_segdir'' '
         + '        WHERE level = ? ORDER BY idx ASC LIMIT ?'
         + '  )',
{ 30 } 'DELETE FROM %Q.''%q_segdir'' WHERE level = ? AND idx = ?',
{ 31 } 'UPDATE %Q.''%q_segdir'' SET idx = ? WHERE level=? AND idx=?',
{ 32 } 'SELECT idx, start_block, leaves_end_block, end_block, root '
         + 'FROM %Q.''%q_segdir'' WHERE level = ? AND idx = ?',
{ 33 } 'UPDATE %Q.''%q_segdir'' SET start_block = ?, root = ?'
         + 'WHERE level = ? AND idx = ?',
{ 34 } 'SELECT 1 FROM %Q.''%q_segments'' WHERE blockid=? AND block IS NULL',
{ 35 } 'SELECT idx FROM %Q.''%q_segdir'' WHERE level=? ORDER BY 1 ASC',
{ 36 } 'SELECT max( level %% 1024 ) FROM %Q.''%q_segdir''',
{ 37 } 'SELECT level, idx, end_block '
         + 'FROM %Q.''%q_segdir'' WHERE level BETWEEN ? AND ? '
         + 'ORDER BY level DESC, idx ASC',
{ 38 } 'UPDATE OR FAIL %Q.''%q_segdir'' SET level=-1,idx=? '
         + 'WHERE level=? AND idx=?',
{ 39 } 'UPDATE OR FAIL %Q.''%q_segdir'' SET level=? WHERE level=-1'
  );

{ fts3_write.c:305..447 — fts3SqlStmt. }
function fts3SqlStmt(p: PFts3Table; eStmt: cint; pp: PPVdbe;
  apVal: PPsqlite3_value): cint;
var
  rc: cint;
  pStmt: PVdbe;
  bAllowVtab: cint;
  zSql: PChar;
  i, nParam: cint;
begin
  rc := SQLITE_OK;
  Assert((eStmt < Length(fts3AzSql)) and (eStmt >= 0));

  pStmt := p^.aStmt[eStmt];
  if pStmt = nil then begin
    bAllowVtab := 0;
    if eStmt = SQL_CONTENT_INSERT then
      zSql := PChar(sqlite3PfMprintf(PAnsiChar(fts3AzSql[eStmt]),
                [p^.zDb, p^.zName, p^.zWriteExprlist]))
    else if eStmt = SQL_SELECT_CONTENT_BY_ROWID then begin
      bAllowVtab := 1;
      zSql := PChar(sqlite3PfMprintf(PAnsiChar(fts3AzSql[eStmt]),
                [p^.zReadExprlist]));
    end else
      zSql := PChar(sqlite3PfMprintf(PAnsiChar(fts3AzSql[eStmt]),
                [p^.zDb, p^.zName]));
    if zSql = nil then
      rc := SQLITE_NOMEM
    else begin
      rc := sqlite3Fts3PrepareStmt(p, zSql, 1, bAllowVtab, @pStmt);
      sqlite3_free(zSql);
      Assert((rc = SQLITE_OK) or (pStmt = nil));
      p^.aStmt[eStmt] := pStmt;
    end;
  end;
  if apVal <> nil then begin
    nParam := sqlite3_bind_parameter_count(pStmt);
    i := 0;
    while (rc = SQLITE_OK) and (i < nParam) do begin
      rc := sqlite3_bind_value(pStmt, i+1, PPsqlite3_value(apVal)[i]);
      Inc(i);
    end;
  end;
  pp^ := pStmt;
  Result := rc;
end;

{ fts3_write.c:450..473 — fts3SelectDocsize. }
function fts3SelectDocsize(pTab: PFts3Table; iDocid: sqlite3_int64;
  ppStmt: PPVdbe): cint;
var
  pStmt: PVdbe;
  rc: cint;
begin
  pStmt := nil;
  rc := fts3SqlStmt(pTab, SQL_SELECT_DOCSIZE, @pStmt, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pStmt, 1, iDocid);
    rc := sqlite3_step(pStmt);
    if (rc <> SQLITE_ROW) or (sqlite3_column_type(pStmt, 0) <> SQLITE_BLOB) then
    begin
      rc := sqlite3_reset(pStmt);
      if rc = SQLITE_OK then rc := FTS_CORRUPT_VTAB;
      pStmt := nil;
    end else
      rc := SQLITE_OK;
  end;
  ppStmt^ := pStmt;
  Result := rc;
end;

{ fts3_write.c:475..494 — sqlite3Fts3SelectDoctotal. }
function sqlite3Fts3SelectDoctotal(pTab: PFts3Table; ppStmt: PPVdbe): cint;
var
  pStmt: PVdbe;
  rc: cint;
begin
  pStmt := nil;
  rc := fts3SqlStmt(pTab, SQL_SELECT_STAT, @pStmt, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int(pStmt, 1, FTS_STAT_DOCTOTAL);
    if (sqlite3_step(pStmt) <> SQLITE_ROW)
    or (sqlite3_column_type(pStmt, 0) <> SQLITE_BLOB) then begin
      rc := sqlite3_reset(pStmt);
      if rc = SQLITE_OK then rc := FTS_CORRUPT_VTAB;
      pStmt := nil;
    end;
  end;
  ppStmt^ := pStmt;
  Result := rc;
end;

{ fts3_write.c:496..502 — sqlite3Fts3SelectDocsize. }
function sqlite3Fts3SelectDocsize(pTab: PFts3Table; iDocid: sqlite3_int64;
  ppStmt: PPVdbe): cint;
begin
  Result := fts3SelectDocsize(pTab, iDocid, ppStmt);
end;

{ fts3_write.c:512..527 — fts3SqlExec. }
procedure fts3SqlExec(pRC: Pcint; p: PFts3Table; eStmt: cint;
  apVal: PPsqlite3_value);
var
  pStmt: PVdbe;
  rc: cint;
begin
  if pRC^ <> 0 then Exit;
  rc := fts3SqlStmt(p, eStmt, @pStmt, apVal);
  if rc = SQLITE_OK then begin
    sqlite3_step(pStmt);
    rc := sqlite3_reset(pStmt);
  end;
  pRC^ := rc;
end;

{ fts3_write.c:544..558 — fts3Writelock. }
function fts3Writelock(p: PFts3Table): cint;
var
  rc: cint;
  pStmt: PVdbe;
begin
  rc := SQLITE_OK;
  if p^.nPendingData = 0 then begin
    rc := fts3SqlStmt(p, SQL_DELETE_SEGDIR_LEVEL, @pStmt, nil);
    if rc = SQLITE_OK then begin
      sqlite3_bind_null(pStmt, 1);
      sqlite3_step(pStmt);
      rc := sqlite3_reset(pStmt);
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:583..596 — getAbsoluteLevel. }
function getAbsoluteLevel(p: PFts3Table; iLangid, iIndex, iLevel: cint):
  sqlite3_int64;
var
  iBase: sqlite3_int64;
begin
  Assert(p^.nIndex > 0);
  Assert((iIndex >= 0) and (iIndex < p^.nIndex));
  iBase := (sqlite3_int64(iLangid) * p^.nIndex + iIndex) * FTS3_SEGDIR_MAXLEVEL;
  Result := iBase + iLevel;
end;

{ fts3_write.c:615..647 — sqlite3Fts3AllSegdirs. }
function sqlite3Fts3AllSegdirs(p: PFts3Table; iLangid, iIndex, iLevel: cint;
  ppStmt: PPVdbe): cint;
var
  rc: cint;
  pStmt: PVdbe;
begin
  pStmt := nil;
  Assert((iLevel = FTS3_SEGCURSOR_ALL) or (iLevel >= 0));
  Assert(iLevel < FTS3_SEGDIR_MAXLEVEL);
  Assert((iIndex >= 0) and (iIndex < p^.nIndex));

  if iLevel < 0 then begin
    rc := fts3SqlStmt(p, SQL_SELECT_LEVEL_RANGE, @pStmt, nil);
    if rc = SQLITE_OK then begin
      sqlite3_bind_int64(pStmt, 1, getAbsoluteLevel(p, iLangid, iIndex, 0));
      sqlite3_bind_int64(pStmt, 2,
          getAbsoluteLevel(p, iLangid, iIndex, FTS3_SEGDIR_MAXLEVEL-1));
    end;
  end else begin
    rc := fts3SqlStmt(p, SQL_SELECT_LEVEL, @pStmt, nil);
    if rc = SQLITE_OK then
      sqlite3_bind_int64(pStmt, 1, getAbsoluteLevel(p, iLangid, iIndex, iLevel));
  end;
  ppStmt^ := pStmt;
  Result := rc;
end;

{ ===================================================================== }
{ Section 3 — pending-terms hash + doclist accumulation                  }
{ (fts3_write.c:662..932).                                               }
{ ===================================================================== }

{ fts3_write.c:662..695 — fts3PendingListAppendVarint. }
function fts3PendingListAppendVarint(pp: PPPendingList; i: sqlite3_int64): cint;
var
  p: PPendingList;
  nNew: sqlite3_int64;
begin
  p := pp^;
  if p = nil then begin
    p := PPendingList(sqlite3_malloc64(u64(SizeOf(TPendingList)) + 100));
    if p = nil then Exit(SQLITE_NOMEM);
    p^.nSpace := 100;
    p^.aData := PChar(PtrUInt(p) + SizeOf(TPendingList));
    p^.nData := 0;
  end else if p^.nData + FTS3_VARINT_MAX + 1 > p^.nSpace then begin
    nNew := p^.nSpace * 2;
    p := PPendingList(sqlite3_realloc64(p, u64(SizeOf(TPendingList)) + u64(nNew)));
    if p = nil then begin
      sqlite3_free(pp^);
      pp^ := nil;
      Exit(SQLITE_NOMEM);
    end;
    p^.nSpace := cint(nNew);
    p^.aData := PChar(PtrUInt(p) + SizeOf(TPendingList));
  end;
  p^.nData := p^.nData + sqlite3Fts3PutVarint(@p^.aData[p^.nData], i);
  p^.aData[p^.nData] := #0;
  pp^ := p;
  Result := SQLITE_OK;
end;

{ fts3_write.c:706..756 — fts3PendingListAppend. }
function fts3PendingListAppend(pp: PPPendingList; iDocid, iCol, iPos:
  sqlite3_int64; pRc: Pcint): cint;
var
  p: PPendingList;
  rc: cint;
  iDelta: u64;
label pendinglistappend_out;
begin
  p := pp^;
  rc := SQLITE_OK;
  Assert((p = nil) or (p^.iLastDocid <= iDocid));

  if (p = nil) or (p^.iLastDocid <> iDocid) then begin
    if p <> nil then iDelta := u64(iDocid) - u64(p^.iLastDocid)
                else iDelta := u64(iDocid);
    if p <> nil then begin
      Assert(p^.nData < p^.nSpace);
      Assert(p^.aData[p^.nData] = #0);
      Inc(p^.nData);
    end;
    rc := fts3PendingListAppendVarint(@p, sqlite3_int64(iDelta));
    if rc <> SQLITE_OK then goto pendinglistappend_out;
    p^.iLastCol := -1;
    p^.iLastPos := 0;
    p^.iLastDocid := iDocid;
  end;
  if (iCol > 0) and (p^.iLastCol <> iCol) then begin
    rc := fts3PendingListAppendVarint(@p, 1);
    if rc = SQLITE_OK then rc := fts3PendingListAppendVarint(@p, iCol);
    if rc <> SQLITE_OK then goto pendinglistappend_out;
    p^.iLastCol := iCol;
    p^.iLastPos := 0;
  end;
  if iCol >= 0 then begin
    Assert((iPos > p^.iLastPos) or ((iPos = 0) and (p^.iLastPos = 0)));
    rc := fts3PendingListAppendVarint(@p, 2 + iPos - p^.iLastPos);
    if rc = SQLITE_OK then p^.iLastPos := iPos;
  end;

pendinglistappend_out:
  pRc^ := rc;
  if p <> pp^ then begin
    pp^ := p;
    Exit(1);
  end;
  Result := 0;
end;

{ fts3_write.c:761..763 — fts3PendingListDelete. }
procedure fts3PendingListDelete(pList: PPendingList);
begin
  sqlite3_free(pList);
end;

{ fts3_write.c:768..801 — fts3PendingTermsAddOne. }
function fts3PendingTermsAddOne(p: PFts3Table; iCol, iPos: cint;
  pHash: PFts3Hash; const zToken: PChar; nToken: cint): cint;
var
  pList: PPendingList;
  rc: cint;
begin
  rc := SQLITE_OK;
  pList := PPendingList(sqlite3Fts3HashFind(pHash, zToken, nToken));
  if pList <> nil then
    p^.nPendingData := p^.nPendingData -
        cint(pList^.nData + nToken + sqlite3_int64(SizeOf(TFts3HashElem)));
  if fts3PendingListAppend(@pList, p^.iPrevDocid, iCol, iPos, @rc) <> 0 then begin
    if pList = PPendingList(sqlite3Fts3HashInsert(pHash, zToken, nToken, pList))
    then begin
      Assert(sqlite3Fts3HashFind(pHash, zToken, nToken) = nil);
      sqlite3_free(pList);
      rc := SQLITE_NOMEM;
    end;
  end;
  if rc = SQLITE_OK then
    p^.nPendingData := p^.nPendingData +
        cint(pList^.nData + nToken + sqlite3_int64(SizeOf(TFts3HashElem)));
  Result := rc;
end;

{ fts3_write.c:810..881 — fts3PendingTermsAdd. }
function fts3PendingTermsAdd(p: PFts3Table; iLangid: cint; const zText: PChar;
  iCol: cint; pnWord: Pcuint): cint;
var
  rc: cint;
  iStart, iEnd, iPos, nWord: cint;
  zToken: PChar;
  nToken: cint;
  pTokenizer: Psqlite3_tokenizer;
  pModule: Psqlite3_tokenizer_module;
  pCsr: Psqlite3_tokenizer_cursor;
  xNext: TFts3TokXNext;
  i: cint;
  pIndex: PFts3Index;
begin
  iStart := 0; iEnd := 0; iPos := 0; nWord := 0;
  nToken := 0;
  pTokenizer := p^.pTokenizer;
  pModule := pTokenizer^.pModule;
  Assert((pTokenizer <> nil) and (pModule <> nil));

  if zText = nil then begin
    pnWord^ := 0;
    Exit(SQLITE_OK);
  end;

  rc := sqlite3Fts3OpenTokenizer(pTokenizer, iLangid, zText, -1, @pCsr);
  if rc <> SQLITE_OK then Exit(rc);

  xNext := pModule^.xNext;
  while (rc = SQLITE_OK)
    and (rc = xNext(pCsr, @zToken, @nToken, @iStart, @iEnd, @iPos)) do
  begin
    if iPos >= nWord then nWord := iPos + 1;
    if (iPos < 0) or (zToken = nil) or (nToken <= 0) then begin
      rc := SQLITE_ERROR;
      break;
    end;
    rc := fts3PendingTermsAddOne(p, iCol, iPos, @p^.aIndex[0].hPending,
            zToken, nToken);
    i := 1;
    while (rc = SQLITE_OK) and (i < p^.nIndex) do begin
      pIndex := @PFts3Index(p^.aIndex)[i];
      if nToken >= pIndex^.nPrefix then
        rc := fts3PendingTermsAddOne(p, iCol, iPos, @pIndex^.hPending,
                zToken, pIndex^.nPrefix);
      Inc(i);
    end;
  end;

  pModule^.xClose(pCsr);
  pnWord^ := pnWord^ + cuint(nWord);
  if rc = SQLITE_DONE then Result := SQLITE_OK else Result := rc;
end;

{ fts3_write.c:888..915 — fts3PendingTermsDocid. }
function fts3PendingTermsDocid(p: PFts3Table; bDelete, iLangid: cint;
  iDocid: sqlite3_int64): cint;
var
  rc: cint;
begin
  Assert(iLangid >= 0);
  Assert((bDelete = 1) or (bDelete = 0));
  if (iDocid < p^.iPrevDocid)
   or ((iDocid = p^.iPrevDocid) and (p^.bPrevDelete = 0))
   or (p^.iPrevLangid <> iLangid)
   or (p^.nPendingData > p^.nMaxPendingData) then begin
    rc := sqlite3Fts3PendingTermsFlush(p);
    if rc <> SQLITE_OK then Exit(rc);
  end;
  p^.iPrevDocid := iDocid;
  p^.iPrevLangid := iLangid;
  p^.bPrevDelete := bDelete;
  Result := SQLITE_OK;
end;

{ fts3_write.c:920..932 — sqlite3Fts3PendingTermsClear. }
procedure sqlite3Fts3PendingTermsClear(p: PFts3Table);
var
  i: cint;
  pElem: PFts3HashElem;
  pHash: PFts3Hash;
  pList: PPendingList;
begin
  for i := 0 to p^.nIndex - 1 do begin
    pHash := @PFts3Index(p^.aIndex)[i].hPending;
    pElem := fts3HashFirst(pHash);
    while pElem <> nil do begin
      pList := PPendingList(fts3HashData(pElem));
      fts3PendingListDelete(pList);
      pElem := fts3HashNext(pElem);
    end;
    sqlite3Fts3HashClear(pHash);
  end;
  p^.nPendingData := 0;
end;

{ fts3_write.c:942..961 — fts3InsertTerms. }
function fts3InsertTerms(p: PFts3Table; iLangid: cint; apVal: PPsqlite3_value;
  aSz: Pcuint): cint;
var
  i, iCol, rc: cint;
  zText: PChar;
begin
  for i := 2 to p^.nColumn + 1 do begin
    iCol := i - 2;
    if PByte(p^.abNotindexed)[iCol] = 0 then begin
      zText := PChar(sqlite3_value_text(PPsqlite3_value(apVal)[i]));
      rc := fts3PendingTermsAdd(p, iLangid, zText, iCol, @Pcuint(aSz)[iCol]);
      if rc <> SQLITE_OK then Exit(rc);
      Pcuint(aSz)[p^.nColumn] := Pcuint(aSz)[p^.nColumn] +
          cuint(sqlite3_value_bytes(PPsqlite3_value(apVal)[i]));
    end;
  end;
  Result := SQLITE_OK;
end;

{ fts3_write.c:977..1043 — fts3InsertData. }
function fts3InsertData(p: PFts3Table; apVal: PPsqlite3_value;
  piDocid: Psqlite3_int64): cint;
var
  rc: cint;
  pContentInsert: PVdbe;
  pRowid: Psqlite3_value;
begin
  if p^.zContentTbl <> nil then begin
    pRowid := PPsqlite3_value(apVal)[p^.nColumn+3];
    if sqlite3_value_type(pRowid) = SQLITE_NULL then
      pRowid := PPsqlite3_value(apVal)[1];
    if sqlite3_value_type(pRowid) <> SQLITE_INTEGER then
      Exit(SQLITE_CONSTRAINT);
    piDocid^ := sqlite3_value_int64(pRowid);
    Exit(SQLITE_OK);
  end;

  rc := fts3SqlStmt(p, SQL_CONTENT_INSERT, @pContentInsert,
          @PPsqlite3_value(apVal)[1]);
  if (rc = SQLITE_OK) and (p^.zLanguageid <> nil) then
    rc := sqlite3_bind_int(pContentInsert, p^.nColumn+2,
            sqlite3_value_int(PPsqlite3_value(apVal)[p^.nColumn+4]));
  if rc <> SQLITE_OK then Exit(rc);

  if SQLITE_NULL <> sqlite3_value_type(PPsqlite3_value(apVal)[3+p^.nColumn]) then
  begin
    if (SQLITE_NULL = sqlite3_value_type(PPsqlite3_value(apVal)[0]))
     and (SQLITE_NULL <> sqlite3_value_type(PPsqlite3_value(apVal)[1])) then
      Exit(SQLITE_ERROR);
    rc := sqlite3_bind_value(pContentInsert, 1,
            PPsqlite3_value(apVal)[3+p^.nColumn]);
    if rc <> SQLITE_OK then Exit(rc);
  end;

  sqlite3_step(pContentInsert);
  rc := sqlite3_reset(pContentInsert);
  piDocid^ := sqlite3_last_insert_rowid(p^.db);
  Result := rc;
end;

{ fts3_write.c:1051..1070 — fts3DeleteAll. }
function fts3DeleteAll(p: PFts3Table; bContent: cint): cint;
var
  rc: cint;
begin
  rc := SQLITE_OK;
  sqlite3Fts3PendingTermsClear(p);
  Assert((p^.zContentTbl = nil) or (bContent = 0));
  if bContent <> 0 then fts3SqlExec(@rc, p, SQL_DELETE_ALL_CONTENT, nil);
  fts3SqlExec(@rc, p, SQL_DELETE_ALL_SEGMENTS, nil);
  fts3SqlExec(@rc, p, SQL_DELETE_ALL_SEGDIR, nil);
  if p^.bHasDocsize <> 0 then fts3SqlExec(@rc, p, SQL_DELETE_ALL_DOCSIZE, nil);
  if p^.bHasStat <> 0 then fts3SqlExec(@rc, p, SQL_DELETE_ALL_STAT, nil);
  Result := rc;
end;

{ fts3_write.c:1075..1079 — langidFromSelect. }
function langidFromSelect(p: PFts3Table; pSelect: PVdbe): cint;
begin
  if p^.zLanguageid <> nil then
    Result := sqlite3_column_int(pSelect, p^.nColumn+1)
  else
    Result := 0;
end;

{ fts3_write.c:1086..1125 — fts3DeleteTerms. }
procedure fts3DeleteTerms(pRC: Pcint; p: PFts3Table; pRowid: Psqlite3_value;
  aSz: Pcuint; pbFound: Pcint);
var
  rc, i, iLangid, iCol: cint;
  pSelect: PVdbe;
  iDocid: sqlite3_int64;
  zText: PChar;
begin
  Assert(pbFound^ = 0);
  if pRC^ <> 0 then Exit;
  rc := fts3SqlStmt(p, SQL_SELECT_CONTENT_BY_ROWID, @pSelect, @pRowid);
  if rc = SQLITE_OK then begin
    if SQLITE_ROW = sqlite3_step(pSelect) then begin
      iLangid := langidFromSelect(p, pSelect);
      iDocid := sqlite3_column_int64(pSelect, 0);
      rc := fts3PendingTermsDocid(p, 1, iLangid, iDocid);
      i := 1;
      while (rc = SQLITE_OK) and (i <= p^.nColumn) do begin
        iCol := i - 1;
        if PByte(p^.abNotindexed)[iCol] = 0 then begin
          zText := PChar(sqlite3_column_text(pSelect, i));
          rc := fts3PendingTermsAdd(p, iLangid, zText, -1, @Pcuint(aSz)[iCol]);
          Pcuint(aSz)[p^.nColumn] := Pcuint(aSz)[p^.nColumn] +
              cuint(sqlite3_column_bytes(pSelect, i));
        end;
        Inc(i);
      end;
      if rc <> SQLITE_OK then begin
        sqlite3_reset(pSelect);
        pRC^ := rc;
        Exit;
      end;
      pbFound^ := 1;
    end;
    rc := sqlite3_reset(pSelect);
  end else
    sqlite3_reset(pSelect);
  pRC^ := rc;
end;

{ fts3_write.c:1148..1190 — fts3AllocateSegdirIdx. }
function fts3AllocateSegdirIdx(p: PFts3Table; iLangid, iIndex, iLevel: cint;
  piIdx: Pcint): cint;
var
  rc: cint;
  pNextIdx: PVdbe;
  iNext: cint;
begin
  iNext := 0;
  Assert(iLangid >= 0);
  Assert(p^.nIndex >= 1);
  rc := fts3SqlStmt(p, SQL_NEXT_SEGMENT_INDEX, @pNextIdx, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pNextIdx, 1, getAbsoluteLevel(p, iLangid, iIndex, iLevel));
    if SQLITE_ROW = sqlite3_step(pNextIdx) then
      iNext := sqlite3_column_int(pNextIdx, 0);
    rc := sqlite3_reset(pNextIdx);
  end;
  if rc = SQLITE_OK then begin
    if iNext >= MergeCount(p) then begin
      rc := fts3SegmentMerge(p, iLangid, iIndex, iLevel);
      piIdx^ := 0;
    end else
      piIdx^ := iNext;
  end;
  Result := rc;
end;

{ ===================================================================== }
{ Section 5 (read path) — %_segments block reads + Fts3SegReader.         }
{ (fts3_write.c:1219..1581).                                             }
{ ===================================================================== }

{ fts3_write.c:1219..1269 — sqlite3Fts3ReadBlock. }
function sqlite3Fts3ReadBlock(p: PFts3Table; iBlockid: sqlite3_int64;
  paBlob: PPChar; pnBlob: Pcint; pnLoad: Pcint): cint;
var
  rc, nByte: cint;
  aByte: PChar;
begin
  Assert(pnBlob <> nil);
  if p^.pSegments <> nil then
    rc := sqlite3_blob_reopen(p^.pSegments, iBlockid)
  else begin
    if p^.zSegmentsTbl = nil then begin
      p^.zSegmentsTbl := PChar(sqlite3PfMprintf(PAnsiChar('%s_segments'),
                            [p^.zName]));
      if p^.zSegmentsTbl = nil then Exit(SQLITE_NOMEM);
    end;
    rc := sqlite3_blob_open(p^.db, PAnsiChar(p^.zDb),
            PAnsiChar(p^.zSegmentsTbl), PAnsiChar('block'), iBlockid, 0,
            p^.pSegments);
  end;

  if rc = SQLITE_OK then begin
    nByte := sqlite3_blob_bytes(p^.pSegments);
    pnBlob^ := nByte;
    if paBlob <> nil then begin
      aByte := PChar(sqlite3_malloc64(u64(sqlite3_int64(nByte) +
                                          FTS3_NODE_PADDING)));
      if aByte = nil then
        rc := SQLITE_NOMEM
      else begin
        if (pnLoad <> nil) and (nByte > FTS3_NODE_CHUNK_THRESHOLD) then begin
          nByte := FTS3_NODE_CHUNKSIZE;
          pnLoad^ := nByte;
        end;
        rc := sqlite3_blob_read(p^.pSegments, aByte, nByte, 0);
        libc_memset(@aByte[nByte], 0, FTS3_NODE_PADDING);
        if rc <> SQLITE_OK then begin
          sqlite3_free(aByte);
          aByte := nil;
        end;
      end;
      paBlob^ := aByte;
    end;
  end else if rc = SQLITE_ERROR then
    rc := FTS_CORRUPT_VTAB;

  Result := rc;
end;

{ fts3_write.c:1275..1278 — sqlite3Fts3SegmentsClose. }
procedure sqlite3Fts3SegmentsClose(p: PFts3Table);
begin
  sqlite3_blob_close(p^.pSegments);
  p^.pSegments := nil;
end;

{ fts3_write.c:173..174 — pending/root-only seg-reader predicates. }
function fts3SegReaderIsPending(p: PFts3SegReader): Boolean; inline;
begin Result := p^.ppNextElem <> nil; end;
function fts3SegReaderIsRootOnly(p: PFts3SegReader): Boolean; inline;
begin Result := p^.rootOnly <> 0; end;

{ fts3_write.c:1280..1302 — fts3SegReaderIncrRead. }
function fts3SegReaderIncrRead(pReader: PFts3SegReader): cint;
var
  nRead, rc: cint;
begin
  nRead := cint(Fts3_MIN(pReader^.nNode - pReader^.nPopulate, FTS3_NODE_CHUNKSIZE));
  rc := sqlite3_blob_read(pReader^.pBlob, @pReader^.aNode[pReader^.nPopulate],
          nRead, pReader^.nPopulate);
  if rc = SQLITE_OK then begin
    pReader^.nPopulate := pReader^.nPopulate + nRead;
    libc_memset(@pReader^.aNode[pReader^.nPopulate], 0, FTS3_NODE_PADDING);
    if pReader^.nPopulate = pReader^.nNode then begin
      sqlite3_blob_close(pReader^.pBlob);
      pReader^.pBlob := nil;
      pReader^.nPopulate := 0;
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:1304..1315 — fts3SegReaderRequire. }
function fts3SegReaderRequire(pReader: PFts3SegReader; pFrom: PChar;
  nByte: cint): cint;
var
  rc: cint;
begin
  rc := SQLITE_OK;
  while (pReader^.pBlob <> nil) and (rc = SQLITE_OK)
    and ((PtrUInt(pFrom) - PtrUInt(pReader^.aNode) + nByte) > PtrUInt(pReader^.nPopulate)) do
    rc := fts3SegReaderIncrRead(pReader);
  Result := rc;
end;

{ fts3_write.c:1320..1327 — fts3SegReaderSetEof. }
procedure fts3SegReaderSetEof(pSeg: PFts3SegReader);
begin
  if not fts3SegReaderIsRootOnly(pSeg) then begin
    sqlite3_free(pSeg^.aNode);
    sqlite3_blob_close(pSeg^.pBlob);
    pSeg^.pBlob := nil;
  end;
  pSeg^.aNode := nil;
end;

{ fts3_write.c:1334..1457 — fts3SegReaderNext. }
function fts3SegReaderNext(p: PFts3Table; pReader: PFts3SegReader;
  bIncr: cint): cint;
var
  rc: cint;
  pNext: PChar;
  nPrefix, nSuffix: cint;
  pElem: PFts3HashElem;
  aCopy: PChar;
  pList: PPendingList;
  nCopy, nTerm: cint;
  nNew: sqlite3_int64;
  zNew: PChar;
  pnPop: Pcint;
begin
  if pReader^.aDoclist = nil then
    pNext := pReader^.aNode
  else
    pNext := @pReader^.aDoclist[pReader^.nDoclist];

  if (pNext = nil) or (PtrUInt(pNext) >= PtrUInt(@pReader^.aNode[pReader^.nNode])) then
  begin
    if fts3SegReaderIsPending(pReader) then begin
      pElem := pReader^.ppNextElem^;
      sqlite3_free(pReader^.aNode);
      pReader^.aNode := nil;
      if pElem <> nil then begin
        pList := PPendingList(fts3HashData(pElem));
        nCopy := cint(pList^.nData) + 1;
        nTerm := fts3HashKeysize(pElem);
        if (nTerm+1) > pReader^.nTermAlloc then begin
          sqlite3_free(pReader^.zTerm);
          pReader^.zTerm := PChar(sqlite3_malloc64(u64((sqlite3_int64(nTerm)+1)*2)));
          if pReader^.zTerm = nil then Exit(SQLITE_NOMEM);
          pReader^.nTermAlloc := (nTerm+1)*2;
        end;
        libc_memcpy(pReader^.zTerm, fts3HashKey(pElem), NativeUInt(nTerm));
        pReader^.zTerm[nTerm] := #0;
        pReader^.nTerm := nTerm;

        aCopy := PChar(sqlite3_malloc64(u64(nCopy)));
        if aCopy = nil then Exit(SQLITE_NOMEM);
        libc_memcpy(aCopy, pList^.aData, NativeUInt(nCopy));
        pReader^.nNode := nCopy; pReader^.nDoclist := nCopy;
        pReader^.aNode := aCopy; pReader^.aDoclist := aCopy;
        Inc(pReader^.ppNextElem);
        Assert(pReader^.aNode <> nil);
      end;
      Exit(SQLITE_OK);
    end;

    fts3SegReaderSetEof(pReader);
    if pReader^.iCurrentBlock >= pReader^.iLeafEndBlock then Exit(SQLITE_OK);

    Inc(pReader^.iCurrentBlock);
    if bIncr <> 0 then pnPop := @pReader^.nPopulate else pnPop := nil;
    rc := sqlite3Fts3ReadBlock(p, pReader^.iCurrentBlock, @pReader^.aNode,
            @pReader^.nNode, pnPop);
    if rc <> SQLITE_OK then Exit(rc);
    Assert(pReader^.pBlob = nil);
    if (bIncr <> 0) and (pReader^.nPopulate < pReader^.nNode) then begin
      pReader^.pBlob := p^.pSegments;
      p^.pSegments := nil;
    end;
    pNext := pReader^.aNode;
  end;

  Assert(not fts3SegReaderIsPending(pReader));

  rc := fts3SegReaderRequire(pReader, pNext, FTS3_VARINT_MAX*2);
  if rc <> SQLITE_OK then Exit(rc);

  pNext := pNext + fts3GetVarint32(pNext, @nPrefix);
  pNext := pNext + fts3GetVarint32(pNext, @nSuffix);
  if (nSuffix <= 0)
   or ((PtrInt(@pReader^.aNode[pReader^.nNode]) - PtrInt(pNext)) < nSuffix)
   or (nPrefix > pReader^.nTerm) then
    Exit(FTS_CORRUPT_VTAB);

  if sqlite3_int64(nPrefix)+nSuffix > sqlite3_int64(pReader^.nTermAlloc) then begin
    nNew := (sqlite3_int64(nPrefix)+nSuffix)*2;
    zNew := PChar(sqlite3_realloc64(pReader^.zTerm, u64(nNew)));
    if zNew = nil then Exit(SQLITE_NOMEM);
    pReader^.zTerm := zNew;
    pReader^.nTermAlloc := cint(nNew);
  end;

  rc := fts3SegReaderRequire(pReader, pNext, nSuffix+FTS3_VARINT_MAX);
  if rc <> SQLITE_OK then Exit(rc);

  libc_memcpy(@pReader^.zTerm[nPrefix], pNext, NativeUInt(nSuffix));
  pReader^.nTerm := nPrefix+nSuffix;
  pNext := pNext + nSuffix;
  pNext := pNext + fts3GetVarint32(pNext, @pReader^.nDoclist);
  pReader^.aDoclist := pNext;
  pReader^.pOffsetList := nil;

  if (pReader^.nDoclist > pReader^.nNode-(PtrInt(pReader^.aDoclist)-PtrInt(pReader^.aNode)))
   or ((pReader^.nPopulate = 0) and (pReader^.aDoclist[pReader^.nDoclist-1] <> #0))
   or (pReader^.nDoclist = 0) then
    Exit(FTS_CORRUPT_VTAB);
  Result := SQLITE_OK;
end;

{ fts3_write.c:1463..1483 — fts3SegReaderFirstDocid. }
function fts3SegReaderFirstDocid(pTab: PFts3Table; pReader: PFts3SegReader): cint;
var
  rc, n: cint;
  bEof: Byte;
begin
  rc := SQLITE_OK;
  Assert(pReader^.aDoclist <> nil);
  Assert(pReader^.pOffsetList = nil);
  if (pTab^.bDescIdx <> 0) and fts3SegReaderIsPending(pReader) then begin
    bEof := 0;
    pReader^.iDocid := 0;
    pReader^.nOffsetList := 0;
    sqlite3Fts3DoclistPrev(0, pReader^.aDoclist, pReader^.nDoclist,
        @pReader^.pOffsetList, @pReader^.iDocid, @pReader^.nOffsetList, @bEof);
  end else begin
    rc := fts3SegReaderRequire(pReader, pReader^.aDoclist, FTS3_VARINT_MAX);
    if rc = SQLITE_OK then begin
      n := sqlite3Fts3GetVarint(pReader^.aDoclist, @pReader^.iDocid);
      pReader^.pOffsetList := @pReader^.aDoclist[n];
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:1495..1581 — fts3SegReaderNextDocid. }
function fts3SegReaderNextDocid(pTab: PFts3Table; pReader: PFts3SegReader;
  ppOffsetList: PPChar; pnOffsetList: Pcint): cint;
var
  rc: cint;
  p, pEnd: PChar;
  c: Byte;
  bEof: Byte;
  iDelta: u64;
begin
  rc := SQLITE_OK;
  p := pReader^.pOffsetList;
  c := 0;
  Assert(p <> nil);

  if (pTab^.bDescIdx <> 0) and fts3SegReaderIsPending(pReader) then begin
    bEof := 0;
    if ppOffsetList <> nil then begin
      ppOffsetList^ := pReader^.pOffsetList;
      pnOffsetList^ := pReader^.nOffsetList - 1;
    end;
    sqlite3Fts3DoclistPrev(0, pReader^.aDoclist, pReader^.nDoclist, @p,
        @pReader^.iDocid, @pReader^.nOffsetList, @bEof);
    if bEof <> 0 then pReader^.pOffsetList := nil
                 else pReader^.pOffsetList := p;
  end else begin
    pEnd := @pReader^.aDoclist[pReader^.nDoclist];
    while True do begin
      { C: while( *p | c ) c = *p++ & 0x80; — read THEN advance. }
      while (Byte(p^) or c) <> 0 do begin c := Byte(p^) and $80; Inc(p); end;
      Assert(p^ = #0);
      if (pReader^.pBlob = nil)
       or (PtrUInt(p) < PtrUInt(@pReader^.aNode[pReader^.nPopulate])) then break;
      rc := fts3SegReaderIncrRead(pReader);
      if rc <> SQLITE_OK then Exit(rc);
    end;
    Inc(p);

    if ppOffsetList <> nil then begin
      ppOffsetList^ := pReader^.pOffsetList;
      pnOffsetList^ := cint(PtrInt(p) - PtrInt(pReader^.pOffsetList) - 1);
    end;

    { List may have been edited in place by fts3EvalNearTrim() }
    while (PtrUInt(p) < PtrUInt(pEnd)) and (p^ = #0) do Inc(p);

    if PtrUInt(p) >= PtrUInt(pEnd) then
      pReader^.pOffsetList := nil
    else begin
      rc := fts3SegReaderRequire(pReader, p, FTS3_VARINT_MAX);
      if rc = SQLITE_OK then begin
        pReader^.pOffsetList := p + sqlite3Fts3GetVarintU(p, @iDelta);
        if pTab^.bDescIdx <> 0 then
          pReader^.iDocid := sqlite3_int64(u64(pReader^.iDocid) - iDelta)
        else
          pReader^.iDocid := sqlite3_int64(u64(pReader^.iDocid) + iDelta);
      end;
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:1584..1616 — sqlite3Fts3MsrOvfl. }
function sqlite3Fts3MsrOvfl(pCsr: PFts3Cursor; pMsr: PFts3MultiSegReader;
  pnOvfl: Pcint): cint;
var
  p: PFts3Table;
  nOvfl, ii, rc, pgsz, nBlob: cint;
  pReader: PFts3SegReader;
  jj: sqlite3_int64;
begin
  p := PFts3Table(pCsr^.base.pVtab);
  nOvfl := 0;
  rc := SQLITE_OK;
  pgsz := p^.nPgsz;
  Assert(p^.bFts4 <> 0);
  Assert(pgsz > 0);

  ii := 0;
  while (rc = SQLITE_OK) and (ii < pMsr^.nSegment) do begin
    pReader := PPFts3SegReader(pMsr^.apSegment)[ii];
    if (not fts3SegReaderIsPending(pReader))
     and (not fts3SegReaderIsRootOnly(pReader)) then begin
      jj := pReader^.iStartBlock;
      while jj <= pReader^.iLeafEndBlock do begin
        rc := sqlite3Fts3ReadBlock(p, jj, nil, @nBlob, nil);
        if rc <> SQLITE_OK then break;
        if (nBlob+35) > pgsz then nOvfl := nOvfl + (nBlob + 34) div pgsz;
        Inc(jj);
      end;
    end;
    Inc(ii);
  end;
  pnOvfl^ := nOvfl;
  Result := rc;
end;

{ fts3_write.c:1622..1631 — sqlite3Fts3SegReaderFree. }
procedure sqlite3Fts3SegReaderFree(pReader: PFts3SegReader);
begin
  if pReader <> nil then begin
    sqlite3_free(pReader^.zTerm);
    if not fts3SegReaderIsRootOnly(pReader) then
      sqlite3_free(pReader^.aNode);
    sqlite3_blob_close(pReader^.pBlob);
  end;
  sqlite3_free(pReader);
end;

{ fts3_write.c:1636..1682 — sqlite3Fts3SegReaderNew. }
function sqlite3Fts3SegReaderNew(iAge, bLookup: cint; iStartLeaf, iEndLeaf,
  iEndBlock: sqlite3_int64; const zRoot: PChar; nRoot: cint;
  ppReader: PPFts3SegReader): cint;
var
  pReader: PFts3SegReader;
  nExtra: cint;
begin
  nExtra := 0;
  Assert((zRoot <> nil) or (nRoot = 0));
  if iStartLeaf = 0 then begin
    if iEndLeaf <> 0 then Exit(FTS_CORRUPT_VTAB);
    nExtra := nRoot + FTS3_NODE_PADDING;
  end;
  pReader := PFts3SegReader(sqlite3_malloc64(u64(SizeOf(TFts3SegReader)) + u64(nExtra)));
  if pReader = nil then Exit(SQLITE_NOMEM);
  libc_memset(pReader, 0, SizeOf(TFts3SegReader));
  pReader^.iIdx := iAge;
  if bLookup <> 0 then pReader^.bLookup := 1 else pReader^.bLookup := 0;
  pReader^.iStartBlock := iStartLeaf;
  pReader^.iLeafEndBlock := iEndLeaf;
  pReader^.iEndBlock := iEndBlock;
  if nExtra <> 0 then begin
    pReader^.aNode := PChar(PtrUInt(pReader) + SizeOf(TFts3SegReader));
    pReader^.rootOnly := 1;
    pReader^.nNode := nRoot;
    if nRoot <> 0 then libc_memcpy(pReader^.aNode, zRoot, NativeUInt(nRoot));
    libc_memset(@pReader^.aNode[nRoot], 0, FTS3_NODE_PADDING);
  end else
    pReader^.iCurrentBlock := iStartLeaf-1;
  ppReader^ := pReader;
  Result := SQLITE_OK;
end;

{ fts3_write.c:1689..1704 — fts3CompareElemByTerm (qsort callback). }
function fts3CompareElemByTerm(const lhs, rhs: Pointer): cint; cdecl;
var
  e1, e2: PFts3HashElem;
  z1, z2: PChar;
  n1, n2, n, c: cint;
begin
  e1 := PPFts3HashElem(lhs)^;
  e2 := PPFts3HashElem(rhs)^;
  z1 := PChar(fts3HashKey(e1));
  z2 := PChar(fts3HashKey(e2));
  n1 := fts3HashKeysize(e1);
  n2 := fts3HashKeysize(e2);
  if n1 < n2 then n := n1 else n := n2;
  c := libc_memcmp(z1, z2, NativeUInt(n));
  if c = 0 then c := n1 - n2;
  Result := c;
end;

{ fts3_write.c:1725..1808 — sqlite3Fts3SegReaderPending. }
function sqlite3Fts3SegReaderPending(p: PFts3Table; iIndex: cint;
  const zTerm: PChar; nTerm: cint; bPrefix: cint;
  ppReader: PPFts3SegReader): cint;
var
  pReader: PFts3SegReader;
  pE: PFts3HashElem;
  aElem: PPFts3HashElem;
  nElem, rc, nAlloc: cint;
  pHash: PFts3Hash;
  zKey: PChar;
  nKey: cint;
  aElem2: PPFts3HashElem;
  nByte: sqlite3_int64;
begin
  pReader := nil;
  aElem := nil;
  nElem := 0;
  rc := SQLITE_OK;
  pHash := @PFts3Index(p^.aIndex)[iIndex].hPending;

  if bPrefix <> 0 then begin
    nAlloc := 0;
    pE := fts3HashFirst(pHash);
    while pE <> nil do begin
      zKey := PChar(fts3HashKey(pE));
      nKey := fts3HashKeysize(pE);
      if (nTerm = 0)
       or ((nKey >= nTerm) and (libc_memcmp(zKey, zTerm, NativeUInt(nTerm)) = 0)) then
      begin
        if nElem = nAlloc then begin
          nAlloc := nAlloc + 16;
          aElem2 := PPFts3HashElem(sqlite3_realloc64(aElem,
                      u64(nAlloc*SizeOf(PFts3HashElem))));
          if aElem2 = nil then begin
            rc := SQLITE_NOMEM;
            nElem := 0;
            break;
          end;
          aElem := aElem2;
        end;
        PPFts3HashElem(aElem)[nElem] := pE;
        Inc(nElem);
      end;
      pE := fts3HashNext(pE);
    end;
    if nElem > 1 then
      libc_qsort(aElem, NativeUInt(nElem), SizeOf(PFts3HashElem),
        @fts3CompareElemByTerm);
  end else begin
    pE := sqlite3Fts3HashFindElem(pHash, zTerm, nTerm);
    if pE <> nil then begin
      aElem := @pE;
      nElem := 1;
    end;
  end;

  if nElem > 0 then begin
    nByte := SizeOf(TFts3SegReader) + (sqlite3_int64(nElem)+1)*SizeOf(PFts3HashElem);
    pReader := PFts3SegReader(sqlite3_malloc64(u64(nByte)));
    if pReader = nil then
      rc := SQLITE_NOMEM
    else begin
      libc_memset(pReader, 0, NativeUInt(nByte));
      pReader^.iIdx := $7FFFFFFF;
      pReader^.ppNextElem := PPFts3HashElem(PtrUInt(pReader) + SizeOf(TFts3SegReader));
      libc_memcpy(pReader^.ppNextElem, aElem, NativeUInt(nElem*SizeOf(PFts3HashElem)));
    end;
  end;

  if bPrefix <> 0 then sqlite3_free(aElem);
  ppReader^ := pReader;
  Result := rc;
end;

{ fts3_write.c:1822..1842 — fts3SegReaderCmp. }
function fts3SegReaderCmp(pLhs, pRhs: PFts3SegReader): cint;
var
  rc, rc2: cint;
begin
  if (pLhs^.aNode <> nil) and (pRhs^.aNode <> nil) then begin
    rc2 := pLhs^.nTerm - pRhs^.nTerm;
    if rc2 < 0 then
      rc := libc_memcmp(pLhs^.zTerm, pRhs^.zTerm, NativeUInt(pLhs^.nTerm))
    else
      rc := libc_memcmp(pLhs^.zTerm, pRhs^.zTerm, NativeUInt(pRhs^.nTerm));
    if rc = 0 then rc := rc2;
  end else
    rc := cint(Ord(pLhs^.aNode = nil)) - cint(Ord(pRhs^.aNode = nil));
  if rc = 0 then rc := pRhs^.iIdx - pLhs^.iIdx;
  Result := rc;
end;

{ fts3_write.c:1855..1866 — fts3SegReaderDoclistCmp. }
function fts3SegReaderDoclistCmp(pLhs, pRhs: PFts3SegReader): cint;
var
  rc: cint;
begin
  rc := cint(Ord(pLhs^.pOffsetList = nil)) - cint(Ord(pRhs^.pOffsetList = nil));
  if rc = 0 then begin
    if pLhs^.iDocid = pRhs^.iDocid then rc := pRhs^.iIdx - pLhs^.iIdx
    else if pLhs^.iDocid > pRhs^.iDocid then rc := 1 else rc := -1;
  end;
  Result := rc;
end;

{ fts3_write.c:1867..1878 — fts3SegReaderDoclistCmpRev. }
function fts3SegReaderDoclistCmpRev(pLhs, pRhs: PFts3SegReader): cint;
var
  rc: cint;
begin
  rc := cint(Ord(pLhs^.pOffsetList = nil)) - cint(Ord(pRhs^.pOffsetList = nil));
  if rc = 0 then begin
    if pLhs^.iDocid = pRhs^.iDocid then rc := pRhs^.iIdx - pLhs^.iIdx
    else if pLhs^.iDocid < pRhs^.iDocid then rc := 1 else rc := -1;
  end;
  Result := rc;
end;

{ fts3_write.c:1888..1905 — fts3SegReaderTermCmp. }
function fts3SegReaderTermCmp(pSeg: PFts3SegReader; const zTerm: PChar;
  nTerm: cint): cint;
var
  res: cint;
begin
  res := 0;
  if pSeg^.aNode <> nil then begin
    if pSeg^.nTerm > nTerm then
      res := libc_memcmp(pSeg^.zTerm, zTerm, NativeUInt(nTerm))
    else
      res := libc_memcmp(pSeg^.zTerm, zTerm, NativeUInt(pSeg^.nTerm));
    if res = 0 then res := pSeg^.nTerm-nTerm;
  end;
  Result := res;
end;

type
  TSegReaderCmpFn = function(pLhs, pRhs: PFts3SegReader): cint;

{ fts3_write.c:1913..1941 — fts3SegReaderSort. }
procedure fts3SegReaderSort(apSegment: PPFts3SegReader; nSegment, nSuspect: cint;
  xCmp: TSegReaderCmpFn);
var
  i, j: cint;
  pTmp: PFts3SegReader;
  a: PPFts3SegReader;
begin
  a := apSegment;
  Assert(nSuspect <= nSegment);
  if nSuspect = nSegment then Dec(nSuspect);
  for i := nSuspect-1 downto 0 do begin
    j := i;
    while j < (nSegment-1) do begin
      if xCmp(a[j], a[j+1]) < 0 then break;
      pTmp := a[j+1];
      a[j+1] := a[j];
      a[j] := pTmp;
      Inc(j);
    end;
  end;
end;

{ ===================================================================== }
{ Section 4 — segment WRITER: node building, prefix compression, writes.  }
{ (fts3_write.c:1946..2450).                                             }
{ ===================================================================== }

{ fts3_write.c:1946..1962 — fts3WriteSegment. }
function fts3WriteSegment(p: PFts3Table; iBlock: sqlite3_int64; z: PChar;
  n: cint): cint;
var
  pStmt: PVdbe;
  rc: cint;
begin
  rc := fts3SqlStmt(p, SQL_INSERT_SEGMENTS, @pStmt, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pStmt, 1, iBlock);
    sqlite3_bind_blob(pStmt, 2, z, n, SQLITE_STATIC);
    sqlite3_step(pStmt);
    rc := sqlite3_reset(pStmt);
    sqlite3_bind_null(pStmt, 2);
  end;
  Result := rc;
end;

{ fts3_write.c:1969..1983 — sqlite3Fts3MaxLevel. }
function sqlite3Fts3MaxLevel(p: PFts3Table; pnMax: Pcint): cint;
var
  rc, mxLevel: cint;
  pStmt: PVdbe;
begin
  mxLevel := 0;
  pStmt := nil;
  rc := fts3SqlStmt(p, SQL_SELECT_MXLEVEL, @pStmt, nil);
  if rc = SQLITE_OK then begin
    if SQLITE_ROW = sqlite3_step(pStmt) then
      mxLevel := sqlite3_column_int(pStmt, 0);
    rc := sqlite3_reset(pStmt);
  end;
  pnMax^ := mxLevel;
  Result := rc;
end;

{ fts3_write.c:1988..2019 — fts3WriteSegdir. }
function fts3WriteSegdir(p: PFts3Table; iLevel: sqlite3_int64; iIdx: cint;
  iStartBlock, iLeafEndBlock, iEndBlock, nLeafData: sqlite3_int64;
  zRoot: PChar; nRoot: cint): cint;
var
  pStmt: PVdbe;
  rc: cint;
  zEnd: PChar;
begin
  rc := fts3SqlStmt(p, SQL_INSERT_SEGDIR, @pStmt, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pStmt, 1, iLevel);
    sqlite3_bind_int(pStmt, 2, iIdx);
    sqlite3_bind_int64(pStmt, 3, iStartBlock);
    sqlite3_bind_int64(pStmt, 4, iLeafEndBlock);
    if nLeafData = 0 then
      sqlite3_bind_int64(pStmt, 5, iEndBlock)
    else begin
      zEnd := PChar(sqlite3PfMprintf(PAnsiChar('%lld %lld'),
                [iEndBlock, nLeafData]));
      if zEnd = nil then Exit(SQLITE_NOMEM);
      sqlite3_bind_text(pStmt, 5, zEnd, -1, TxDelProc(@sqlite3_free));
    end;
    sqlite3_bind_blob(pStmt, 6, zRoot, nRoot, SQLITE_STATIC);
    sqlite3_step(pStmt);
    rc := sqlite3_reset(pStmt);
    sqlite3_bind_null(pStmt, 6);
  end;
  Result := rc;
end;

{ fts3_write.c:2029..2039 — fts3PrefixCompress. }
function fts3PrefixCompress(const zPrev: PChar; nPrev: cint; const zNext: PChar;
  nNext: cint): cint;
var
  n: cint;
begin
  n := 0;
  while (n < nPrev) and (n < nNext) and (zPrev[n] = zNext[n]) do Inc(n);
  Result := n;
end;

{ fts3_write.c:2045..2156 — fts3NodeAddTerm (mutually recursive). }
function fts3NodeAddTerm(p: PFts3Table; ppTree: PPSegmentNode;
  isCopyTerm: cint; const zTerm: PChar; nTerm: cint): cint;
var
  pTree, pNew, pParent: PSegmentNode;
  rc: cint;
  nData, nReq, nPrefix, nSuffix: cint;
  zNew: PChar;
begin
  pTree := ppTree^;

  if pTree <> nil then begin
    nData := pTree^.nData;
    nReq := nData;
    nPrefix := fts3PrefixCompress(pTree^.zTerm, pTree^.nTerm, zTerm, nTerm);
    nSuffix := nTerm-nPrefix;
    if nSuffix <= 0 then Exit(FTS_CORRUPT_VTAB);
    nReq := nReq + sqlite3Fts3VarintLen(nPrefix) + sqlite3Fts3VarintLen(nSuffix)
              + nSuffix;
    if (nReq <= p^.nNodeSize) or (pTree^.zTerm = nil) then begin
      if nReq > p^.nNodeSize then begin
        Assert(pTree^.aData = PChar(PtrUInt(pTree) + SizeOf(TSegmentNode)));
        pTree^.aData := PChar(sqlite3_malloc64(u64(nReq)));
        if pTree^.aData = nil then Exit(SQLITE_NOMEM);
      end;
      if pTree^.zTerm <> nil then
        nData := nData + sqlite3Fts3PutVarint(@pTree^.aData[nData], nPrefix);
      nData := nData + sqlite3Fts3PutVarint(@pTree^.aData[nData], nSuffix);
      libc_memcpy(@pTree^.aData[nData], @zTerm[nPrefix], NativeUInt(nSuffix));
      pTree^.nData := nData + nSuffix;
      Inc(pTree^.nEntry);
      if isCopyTerm <> 0 then begin
        if pTree^.nMalloc < nTerm then begin
          zNew := PChar(sqlite3_realloc64(pTree^.zMalloc, u64(sqlite3_int64(nTerm)*2)));
          if zNew = nil then Exit(SQLITE_NOMEM);
          pTree^.nMalloc := nTerm*2;
          pTree^.zMalloc := zNew;
        end;
        pTree^.zTerm := pTree^.zMalloc;
        libc_memcpy(pTree^.zTerm, zTerm, NativeUInt(nTerm));
        pTree^.nTerm := nTerm;
      end else begin
        pTree^.zTerm := PChar(zTerm);
        pTree^.nTerm := nTerm;
      end;
      Exit(SQLITE_OK);
    end;
  end;

  pNew := PSegmentNode(sqlite3_malloc64(u64(SizeOf(TSegmentNode)) + u64(p^.nNodeSize)));
  if pNew = nil then Exit(SQLITE_NOMEM);
  libc_memset(pNew, 0, SizeOf(TSegmentNode));
  pNew^.nData := 1 + FTS3_VARINT_MAX;
  pNew^.aData := PChar(PtrUInt(pNew) + SizeOf(TSegmentNode));

  if pTree <> nil then begin
    pParent := pTree^.pParent;
    rc := fts3NodeAddTerm(p, @pParent, isCopyTerm, zTerm, nTerm);
    if pTree^.pParent = nil then pTree^.pParent := pParent;
    pTree^.pRight := pNew;
    pNew^.pLeftmost := pTree^.pLeftmost;
    pNew^.pParent := pParent;
    pNew^.zMalloc := pTree^.zMalloc;
    pNew^.nMalloc := pTree^.nMalloc;
    pTree^.zMalloc := nil;
  end else begin
    pNew^.pLeftmost := pNew;
    rc := fts3NodeAddTerm(p, @pNew, isCopyTerm, zTerm, nTerm);
  end;

  ppTree^ := pNew;
  Result := rc;
end;

{ fts3_write.c:2161..2172 — fts3TreeFinishNode. }
function fts3TreeFinishNode(pTree: PSegmentNode; iHeight: cint;
  iLeftChild: sqlite3_int64): cint;
var
  nStart: cint;
begin
  Assert((iHeight >= 1) and (iHeight < 128));
  nStart := FTS3_VARINT_MAX - sqlite3Fts3VarintLen(iLeftChild);
  pTree^.aData[nStart] := Chr(iHeight);
  sqlite3Fts3PutVarint(@pTree^.aData[nStart+1], iLeftChild);
  Result := nStart;
end;

{ fts3_write.c:2187..2226 — fts3NodeWrite. }
function fts3NodeWrite(p: PFts3Table; pTree: PSegmentNode; iHeight: cint;
  iLeaf, iFree: sqlite3_int64; piLast: Psqlite3_int64; paRoot: PPChar;
  pnRoot: Pcint): cint;
var
  rc: cint;
  pIter: PSegmentNode;
  iNextFree, iNextLeaf: sqlite3_int64;
  nStart, nWrite: cint;
begin
  rc := SQLITE_OK;
  if pTree^.pParent = nil then begin
    nStart := fts3TreeFinishNode(pTree, iHeight, iLeaf);
    piLast^ := iFree-1;
    pnRoot^ := pTree^.nData - nStart;
    paRoot^ := @pTree^.aData[nStart];
  end else begin
    iNextFree := iFree;
    iNextLeaf := iLeaf;
    pIter := pTree^.pLeftmost;
    while (pIter <> nil) and (rc = SQLITE_OK) do begin
      nStart := fts3TreeFinishNode(pIter, iHeight, iNextLeaf);
      nWrite := pIter^.nData - nStart;
      rc := fts3WriteSegment(p, iNextFree, @pIter^.aData[nStart], nWrite);
      Inc(iNextFree);
      iNextLeaf := iNextLeaf + (pIter^.nEntry+1);
      pIter := pIter^.pRight;
    end;
    if rc = SQLITE_OK then begin
      Assert(iNextLeaf = iFree);
      rc := fts3NodeWrite(p, pTree^.pParent, iHeight+1, iFree, iNextFree,
              piLast, paRoot, pnRoot);
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:2231..2246 — fts3NodeFree. }
procedure fts3NodeFree(pTree: PSegmentNode);
var
  p, pRight: PSegmentNode;
begin
  if pTree <> nil then begin
    p := pTree^.pLeftmost;
    fts3NodeFree(p^.pParent);
    while p <> nil do begin
      pRight := p^.pRight;
      if p^.aData <> PChar(PtrUInt(p) + SizeOf(TSegmentNode)) then
        sqlite3_free(p^.aData);
      sqlite3_free(p^.zMalloc);
      sqlite3_free(p);
      p := pRight;
    end;
  end;
end;

{ fts3_write.c:2256..2399 — fts3SegWriterAdd. }
function fts3SegWriterAdd(p: PFts3Table; ppWriter: PPSegmentWriter;
  isCopyTerm: cint; const zTerm: PChar; nTerm: cint; const aDoclist: PChar;
  nDoclist: cint): cint;
var
  nPrefix, nSuffix, nData, rc: cint;
  nReq: sqlite3_int64;
  pWriter: PSegmentWriter;
  pStmt: PVdbe;
  aNew, zNew: PChar;
begin
  pWriter := ppWriter^;
  if pWriter = nil then begin
    pWriter := PSegmentWriter(sqlite3_malloc64(u64(SizeOf(TSegmentWriter))));
    if pWriter = nil then Exit(SQLITE_NOMEM);
    libc_memset(pWriter, 0, SizeOf(TSegmentWriter));
    ppWriter^ := pWriter;
    pWriter^.aData := PChar(sqlite3_malloc64(u64(p^.nNodeSize)));
    if pWriter^.aData = nil then Exit(SQLITE_NOMEM);
    pWriter^.nSize := p^.nNodeSize;
    rc := fts3SqlStmt(p, SQL_NEXT_SEGMENTS_ID, @pStmt, nil);
    if rc <> SQLITE_OK then Exit(rc);
    if SQLITE_ROW = sqlite3_step(pStmt) then begin
      pWriter^.iFree := sqlite3_column_int64(pStmt, 0);
      pWriter^.iFirst := pWriter^.iFree;
    end;
    rc := sqlite3_reset(pStmt);
    if rc <> SQLITE_OK then Exit(rc);
  end;
  nData := pWriter^.nData;

  nPrefix := fts3PrefixCompress(pWriter^.zTerm, pWriter^.nTerm, zTerm, nTerm);
  nSuffix := nTerm-nPrefix;
  if nSuffix <= 0 then Exit(FTS_CORRUPT_VTAB);

  nReq := sqlite3Fts3VarintLen(nPrefix) + sqlite3Fts3VarintLen(nSuffix)
            + nSuffix + sqlite3Fts3VarintLen(nDoclist) + nDoclist;

  if (nData > 0) and (nData+nReq > p^.nNodeSize) then begin
    if pWriter^.iFree = LARGEST_INT64 then Exit(FTS_CORRUPT_VTAB);
    rc := fts3WriteSegment(p, pWriter^.iFree, pWriter^.aData, nData);
    Inc(pWriter^.iFree);
    if rc <> SQLITE_OK then Exit(rc);
    Inc(p^.nLeafAdd);
    Assert(nPrefix < nTerm);
    rc := fts3NodeAddTerm(p, @pWriter^.pTree, isCopyTerm, zTerm, nPrefix+1);
    if rc <> SQLITE_OK then Exit(rc);
    nData := 0;
    pWriter^.nTerm := 0;
    nPrefix := 0;
    nSuffix := nTerm;
    nReq := 1 + sqlite3Fts3VarintLen(nTerm) + nTerm
              + sqlite3Fts3VarintLen(nDoclist) + nDoclist;
  end;

  pWriter^.nLeafData := pWriter^.nLeafData + nReq;

  if nReq > pWriter^.nSize then begin
    aNew := PChar(sqlite3_realloc64(pWriter^.aData, u64(nReq)));
    if aNew = nil then Exit(SQLITE_NOMEM);
    pWriter^.aData := aNew;
    pWriter^.nSize := cint(nReq);
  end;
  Assert(nData+nReq <= pWriter^.nSize);

  nData := nData + sqlite3Fts3PutVarint(@pWriter^.aData[nData], nPrefix);
  nData := nData + sqlite3Fts3PutVarint(@pWriter^.aData[nData], nSuffix);
  libc_memcpy(@pWriter^.aData[nData], @zTerm[nPrefix], NativeUInt(nSuffix));
  nData := nData + nSuffix;
  nData := nData + sqlite3Fts3PutVarint(@pWriter^.aData[nData], nDoclist);
  libc_memcpy(@pWriter^.aData[nData], aDoclist, NativeUInt(nDoclist));
  pWriter^.nData := nData + nDoclist;

  if isCopyTerm <> 0 then begin
    if nTerm > pWriter^.nMalloc then begin
      zNew := PChar(sqlite3_realloc64(pWriter^.zMalloc, u64(sqlite3_int64(nTerm)*2)));
      if zNew = nil then Exit(SQLITE_NOMEM);
      pWriter^.nMalloc := nTerm*2;
      pWriter^.zMalloc := zNew;
      pWriter^.zTerm := zNew;
    end;
    Assert(pWriter^.zTerm = pWriter^.zMalloc);
    libc_memcpy(pWriter^.zTerm, zTerm, NativeUInt(nTerm));
  end else
    pWriter^.zTerm := PChar(zTerm);
  pWriter^.nTerm := nTerm;
  Result := SQLITE_OK;
end;

{ fts3_write.c:2407..2437 — fts3SegWriterFlush. }
function fts3SegWriterFlush(p: PFts3Table; pWriter: PSegmentWriter;
  iLevel: sqlite3_int64; iIdx: cint): cint;
var
  rc: cint;
  iLast, iLastLeaf: sqlite3_int64;
  zRoot: PChar;
  nRoot: cint;
begin
  if pWriter^.pTree <> nil then begin
    iLast := 0;
    zRoot := nil;
    nRoot := 0;
    iLastLeaf := pWriter^.iFree;
    rc := fts3WriteSegment(p, pWriter^.iFree, pWriter^.aData, pWriter^.nData);
    Inc(pWriter^.iFree);
    if rc = SQLITE_OK then
      rc := fts3NodeWrite(p, pWriter^.pTree, 1, pWriter^.iFirst, pWriter^.iFree,
              @iLast, @zRoot, @nRoot);
    if rc = SQLITE_OK then
      rc := fts3WriteSegdir(p, iLevel, iIdx, pWriter^.iFirst, iLastLeaf, iLast,
              pWriter^.nLeafData, zRoot, nRoot);
  end else
    rc := fts3WriteSegdir(p, iLevel, iIdx, 0, 0, 0, pWriter^.nLeafData,
            pWriter^.aData, pWriter^.nData);
  Inc(p^.nLeafAdd);
  Result := rc;
end;

{ fts3_write.c:2443..2450 — fts3SegWriterFree. }
procedure fts3SegWriterFree(pWriter: PSegmentWriter);
begin
  if pWriter <> nil then begin
    sqlite3_free(pWriter^.aData);
    sqlite3_free(pWriter^.zMalloc);
    fts3NodeFree(pWriter^.pTree);
    sqlite3_free(pWriter);
  end;
end;

{ ===================================================================== }
{ Section 5b — merge driver + multi-way reader step.                     }
{ (fts3_write.c:2462..3096, 3108..3376).                                 }
{ ===================================================================== }

{ fts3_write.c:2462..2479 — fts3IsEmpty. }
function fts3IsEmpty(p: PFts3Table; pRowid: Psqlite3_value; pisEmpty: Pcint): cint;
var
  pStmt: PVdbe;
  rc: cint;
begin
  if p^.zContentTbl <> nil then begin
    pisEmpty^ := 0;
    rc := SQLITE_OK;
  end else begin
    rc := fts3SqlStmt(p, SQL_IS_EMPTY, @pStmt, @pRowid);
    if rc = SQLITE_OK then begin
      if SQLITE_ROW = sqlite3_step(pStmt) then
        pisEmpty^ := sqlite3_column_int(pStmt, 0);
      rc := sqlite3_reset(pStmt);
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:2489..2515 — fts3SegmentMaxLevel. }
function fts3SegmentMaxLevel(p: PFts3Table; iLangid, iIndex: cint;
  pnMax: Psqlite3_int64): cint;
var
  pStmt: PVdbe;
  rc: cint;
begin
  Assert((iIndex >= 0) and (iIndex < p^.nIndex));
  rc := fts3SqlStmt(p, SQL_SELECT_SEGDIR_MAX_LEVEL, @pStmt, nil);
  if rc <> SQLITE_OK then Exit(rc);
  sqlite3_bind_int64(pStmt, 1, getAbsoluteLevel(p, iLangid, iIndex, 0));
  sqlite3_bind_int64(pStmt, 2,
      getAbsoluteLevel(p, iLangid, iIndex, FTS3_SEGDIR_MAXLEVEL-1));
  if SQLITE_ROW = sqlite3_step(pStmt) then
    pnMax^ := sqlite3_column_int64(pStmt, 0);
  Result := sqlite3_reset(pStmt);
end;

{ fts3_write.c:2525..2546 — fts3SegmentIsMaxLevel. }
function fts3SegmentIsMaxLevel(p: PFts3Table; iAbsLevel: sqlite3_int64;
  pbMax: Pcint): cint;
var
  pStmt: PVdbe;
  rc: cint;
begin
  rc := fts3SqlStmt(p, SQL_SELECT_SEGDIR_MAX_LEVEL, @pStmt, nil);
  if rc <> SQLITE_OK then Exit(rc);
  sqlite3_bind_int64(pStmt, 1, iAbsLevel+1);
  sqlite3_bind_int64(pStmt, 2,
      sqlite3_int64(((u64(iAbsLevel) div FTS3_SEGDIR_MAXLEVEL)+1) * FTS3_SEGDIR_MAXLEVEL));
  pbMax^ := 0;
  if SQLITE_ROW = sqlite3_step(pStmt) then
    pbMax^ := cint(Ord(sqlite3_column_type(pStmt, 0) = SQLITE_NULL));
  Result := sqlite3_reset(pStmt);
end;

{ fts3_write.c:2553..2569 — fts3DeleteSegment. }
function fts3DeleteSegment(p: PFts3Table; pSeg: PFts3SegReader): cint;
var
  rc: cint;
  pDelete: PVdbe;
begin
  rc := SQLITE_OK;
  if pSeg^.iStartBlock <> 0 then begin
    rc := fts3SqlStmt(p, SQL_DELETE_SEGMENTS_RANGE, @pDelete, nil);
    if rc = SQLITE_OK then begin
      sqlite3_bind_int64(pDelete, 1, pSeg^.iStartBlock);
      sqlite3_bind_int64(pDelete, 2, pSeg^.iEndBlock);
      sqlite3_step(pDelete);
      rc := sqlite3_reset(pDelete);
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:2585..2628 — fts3DeleteSegdir. }
function fts3DeleteSegdir(p: PFts3Table; iLangid, iIndex, iLevel: cint;
  apSegment: PPFts3SegReader; nReader: cint): cint;
var
  rc, i: cint;
  pDelete: PVdbe;
begin
  rc := SQLITE_OK;
  pDelete := nil;
  i := 0;
  while (rc = SQLITE_OK) and (i < nReader) do begin
    rc := fts3DeleteSegment(p, PPFts3SegReader(apSegment)[i]);
    Inc(i);
  end;
  if rc <> SQLITE_OK then Exit(rc);

  Assert((iLevel >= 0) or (iLevel = FTS3_SEGCURSOR_ALL));
  if iLevel = FTS3_SEGCURSOR_ALL then begin
    rc := fts3SqlStmt(p, SQL_DELETE_SEGDIR_RANGE, @pDelete, nil);
    if rc = SQLITE_OK then begin
      sqlite3_bind_int64(pDelete, 1, getAbsoluteLevel(p, iLangid, iIndex, 0));
      sqlite3_bind_int64(pDelete, 2,
          getAbsoluteLevel(p, iLangid, iIndex, FTS3_SEGDIR_MAXLEVEL-1));
    end;
  end else begin
    rc := fts3SqlStmt(p, SQL_DELETE_SEGDIR_LEVEL, @pDelete, nil);
    if rc = SQLITE_OK then
      sqlite3_bind_int64(pDelete, 1,
          getAbsoluteLevel(p, iLangid, iIndex, iLevel));
  end;
  if rc = SQLITE_OK then begin
    sqlite3_step(pDelete);
    rc := sqlite3_reset(pDelete);
  end;
  Result := rc;
end;

{ fts3_write.c:2642..2678 — fts3ColumnFilter. }
procedure fts3ColumnFilter(iCol, bZero: cint; ppList: PPChar; pnList: Pcint);
var
  pList, pEnd, p: PChar;
  nList, iCurrent: cint;
  c: Byte;
begin
  pList := ppList^;
  nList := pnList^;
  pEnd := @pList[nList];
  iCurrent := 0;
  p := pList;
  Assert(iCol >= 0);
  while True do begin
    c := 0;
    { C: while( p<pEnd && (c | *p)&0xFE ) c = *p++ & 0x80; }
    while (PtrUInt(p) < PtrUInt(pEnd)) and (((c or Byte(p^)) and $FE) <> 0) do
      begin c := Byte(p^) and $80; Inc(p); end;
    if iCol = iCurrent then begin
      nList := cint(PtrInt(p) - PtrInt(pList));
      break;
    end;
    nList := nList - cint(PtrInt(p) - PtrInt(pList));
    pList := p;
    if nList <= 0 then break;
    p := @pList[1];
    p := p + fts3GetVarint32(p, @iCurrent);
  end;
  if (bZero <> 0) and ((PtrInt(pEnd) - PtrInt(@pList[nList])) > 0) then
    libc_memset(@pList[nList], 0, NativeUInt(PtrInt(pEnd) - PtrInt(@pList[nList])));
  ppList^ := pList;
  pnList^ := nList;
end;

{ fts3_write.c:2687..2705 — fts3MsrBufferData. }
function fts3MsrBufferData(pMsr: PFts3MultiSegReader; pList: PChar;
  nList: sqlite3_int64): cint;
var
  pNew: PChar;
  nNew: cint;
begin
  if (nList+FTS3_NODE_PADDING) > pMsr^.nBuffer then begin
    nNew := cint(nList*2 + FTS3_NODE_PADDING);
    pNew := PChar(sqlite3_realloc64(pMsr^.aBuffer, u64(nNew)));
    if pNew = nil then Exit(SQLITE_NOMEM);
    pMsr^.aBuffer := pNew;
    pMsr^.nBuffer := nNew;
  end;
  libc_memcpy(pMsr^.aBuffer, pList, NativeUInt(nList));
  libc_memset(@pMsr^.aBuffer[nList], 0, FTS3_NODE_PADDING);
  Result := SQLITE_OK;
end;

{ fts3_write.c:2707..2773 — sqlite3Fts3MsrIncrNext. }
function sqlite3Fts3MsrIncrNext(p: PFts3Table; pMsr: PFts3MultiSegReader;
  piDocid: Psqlite3_int64; paPoslist: PPChar; pnPoslist: Pcint): cint;
var
  nMerge: cint;
  apSegment: PPFts3SegReader;
  xCmp: TSegReaderCmpFn;
  pSeg: PFts3SegReader;
  rc, nList, j: cint;
  pList: PChar;
  iDocid: sqlite3_int64;
begin
  nMerge := pMsr^.nAdvance;
  apSegment := pMsr^.apSegment;
  if p^.bDescIdx <> 0 then xCmp := @fts3SegReaderDoclistCmpRev
                       else xCmp := @fts3SegReaderDoclistCmp;
  if nMerge = 0 then begin
    paPoslist^ := nil;
    Exit(SQLITE_OK);
  end;

  while True do begin
    pSeg := PPFts3SegReader(pMsr^.apSegment)[0];
    if pSeg^.pOffsetList = nil then begin
      paPoslist^ := nil;
      break;
    end else begin
      iDocid := PPFts3SegReader(apSegment)[0]^.iDocid;
      rc := fts3SegReaderNextDocid(p, PPFts3SegReader(apSegment)[0], @pList, @nList);
      j := 1;
      while (rc = SQLITE_OK) and (j < nMerge)
        and (PPFts3SegReader(apSegment)[j]^.pOffsetList <> nil)
        and (PPFts3SegReader(apSegment)[j]^.iDocid = iDocid) do begin
        rc := fts3SegReaderNextDocid(p, PPFts3SegReader(apSegment)[j], nil, nil);
        Inc(j);
      end;
      if rc <> SQLITE_OK then Exit(rc);
      fts3SegReaderSort(pMsr^.apSegment, nMerge, j, xCmp);

      if (nList > 0) and fts3SegReaderIsPending(PPFts3SegReader(apSegment)[0]) then
      begin
        rc := fts3MsrBufferData(pMsr, pList, sqlite3_int64(nList)+1);
        if rc <> SQLITE_OK then Exit(rc);
        pList := pMsr^.aBuffer;
      end;
      if pMsr^.iColFilter >= 0 then
        fts3ColumnFilter(pMsr^.iColFilter, 1, @pList, @nList);
      if nList > 0 then begin
        paPoslist^ := pList;
        piDocid^ := iDocid;
        pnPoslist^ := nList;
        break;
      end;
    end;
  end;
  Result := SQLITE_OK;
end;

{ fts3_write.c:2775..2805 — fts3SegReaderStart. }
function fts3SegReaderStart(p: PFts3Table; pCsr: PFts3MultiSegReader;
  const zTerm: PChar; nTerm: cint): cint;
var
  i, nSeg, res, rc: cint;
  pSeg: PFts3SegReader;
begin
  nSeg := pCsr^.nSegment;
  i := 0;
  while (pCsr^.bRestart = 0) and (i < pCsr^.nSegment) do begin
    res := 0;
    pSeg := PPFts3SegReader(pCsr^.apSegment)[i];
    repeat
      rc := fts3SegReaderNext(p, pSeg, 0);
      if rc <> SQLITE_OK then Exit(rc);
      if zTerm = nil then break;
      res := fts3SegReaderTermCmp(pSeg, zTerm, nTerm);
    until res >= 0;
    if (pSeg^.bLookup <> 0) and (res <> 0) then
      fts3SegReaderSetEof(pSeg);
    Inc(i);
  end;
  fts3SegReaderSort(pCsr^.apSegment, nSeg, nSeg, @fts3SegReaderCmp);
  Result := SQLITE_OK;
end;

{ fts3_write.c:2807..2814 — sqlite3Fts3SegReaderStart. }
function sqlite3Fts3SegReaderStart(p: PFts3Table; pCsr: PFts3MultiSegReader;
  pFilter: PFts3SegFilter): cint;
begin
  pCsr^.pFilter := pFilter;
  Result := fts3SegReaderStart(p, pCsr, pFilter^.zTerm, pFilter^.nTerm);
end;

{ fts3_write.c:2816..2857 — sqlite3Fts3MsrIncrStart. }
function sqlite3Fts3MsrIncrStart(p: PFts3Table; pCsr: PFts3MultiSegReader;
  iCol: cint; const zTerm: PChar; nTerm: cint): cint;
var
  i, rc, nSegment: cint;
  xCmp: TSegReaderCmpFn;
  pSeg: PFts3SegReader;
begin
  nSegment := pCsr^.nSegment;
  if p^.bDescIdx <> 0 then xCmp := @fts3SegReaderDoclistCmpRev
                       else xCmp := @fts3SegReaderDoclistCmp;
  Assert(pCsr^.pFilter = nil);
  Assert((zTerm <> nil) and (nTerm > 0));

  rc := fts3SegReaderStart(p, pCsr, zTerm, nTerm);
  if rc <> SQLITE_OK then Exit(rc);

  i := 0;
  while i < nSegment do begin
    pSeg := PPFts3SegReader(pCsr^.apSegment)[i];
    if (pSeg^.aNode = nil) or (fts3SegReaderTermCmp(pSeg, zTerm, nTerm) <> 0) then
      break;
    Inc(i);
  end;
  pCsr^.nAdvance := i;

  i := 0;
  while i < pCsr^.nAdvance do begin
    rc := fts3SegReaderFirstDocid(p, PPFts3SegReader(pCsr^.apSegment)[i]);
    if rc <> SQLITE_OK then Exit(rc);
    Inc(i);
  end;
  fts3SegReaderSort(pCsr^.apSegment, i, i, xCmp);
  Assert((iCol < 0) or (iCol < p^.nColumn));
  pCsr^.iColFilter := iCol;
  Result := SQLITE_OK;
end;

{ fts3_write.c:2871..2888 — sqlite3Fts3MsrIncrRestart. }
function sqlite3Fts3MsrIncrRestart(pCsr: PFts3MultiSegReader): cint;
var
  i: cint;
begin
  Assert(pCsr^.zTerm = nil);
  Assert(pCsr^.nTerm = 0);
  Assert(pCsr^.aDoclist = nil);
  Assert(pCsr^.nDoclist = 0);
  pCsr^.nAdvance := 0;
  pCsr^.bRestart := 1;
  for i := 0 to pCsr^.nSegment - 1 do begin
    PPFts3SegReader(pCsr^.apSegment)[i]^.pOffsetList := nil;
    PPFts3SegReader(pCsr^.apSegment)[i]^.nOffsetList := 0;
    PPFts3SegReader(pCsr^.apSegment)[i]^.iDocid := 0;
  end;
  Result := SQLITE_OK;
end;

{ fts3_write.c:2890..2901 — fts3GrowSegReaderBuffer. }
function fts3GrowSegReaderBuffer(pCsr: PFts3MultiSegReader;
  nReq: sqlite3_int64): cint;
var
  aNew: PChar;
begin
  if nReq > pCsr^.nBuffer then begin
    pCsr^.nBuffer := nReq*2;
    aNew := PChar(sqlite3_realloc64(pCsr^.aBuffer, u64(pCsr^.nBuffer)));
    if aNew = nil then Exit(SQLITE_NOMEM);
    pCsr^.aBuffer := aNew;
  end;
  Result := SQLITE_OK;
end;

{ fts3_write.c:2904..3078 — sqlite3Fts3SegReaderStep. }
function sqlite3Fts3SegReaderStep(p: PFts3Table; pCsr: PFts3MultiSegReader): cint;
var
  rc: cint;
  isIgnoreEmpty, isRequirePos, isColFilter, isPrefix, isScan, isFirst: cint;
  apSegment: PPFts3SegReader;
  nSegment: cint;
  pFilter: PFts3SegFilter;
  xCmp: TSegReaderCmpFn;
  nMerge, i, j, nByte: cint;
  pSeg: PFts3SegReader;
  nDoclist: cint;
  iPrev, iDocid, iDelta: sqlite3_int64;
  pList: PChar;
  nList, nWrite: cint;
  a: PChar;
begin
  rc := SQLITE_OK;
  isIgnoreEmpty := pCsr^.pFilter^.flags and FTS3_SEGMENT_IGNORE_EMPTY;
  isRequirePos  := pCsr^.pFilter^.flags and FTS3_SEGMENT_REQUIRE_POS;
  isColFilter   := pCsr^.pFilter^.flags and FTS3_SEGMENT_COLUMN_FILTER;
  isPrefix      := pCsr^.pFilter^.flags and FTS3_SEGMENT_PREFIX;
  isScan        := pCsr^.pFilter^.flags and FTS3_SEGMENT_SCAN;
  isFirst       := pCsr^.pFilter^.flags and FTS3_SEGMENT_FIRST;

  apSegment := pCsr^.apSegment;
  nSegment := pCsr^.nSegment;
  pFilter := pCsr^.pFilter;
  if p^.bDescIdx <> 0 then xCmp := @fts3SegReaderDoclistCmpRev
                       else xCmp := @fts3SegReaderDoclistCmp;

  if pCsr^.nSegment = 0 then Exit(SQLITE_OK);

  repeat
    for i := 0 to pCsr^.nAdvance - 1 do begin
      pSeg := PPFts3SegReader(apSegment)[i];
      if pSeg^.bLookup <> 0 then
        fts3SegReaderSetEof(pSeg)
      else
        rc := fts3SegReaderNext(p, pSeg, 0);
      if rc <> SQLITE_OK then Exit(rc);
    end;
    fts3SegReaderSort(apSegment, nSegment, pCsr^.nAdvance, @fts3SegReaderCmp);
    pCsr^.nAdvance := 0;

    if PPFts3SegReader(apSegment)[0]^.aNode = nil then break;

    pCsr^.nTerm := PPFts3SegReader(apSegment)[0]^.nTerm;
    pCsr^.zTerm := PPFts3SegReader(apSegment)[0]^.zTerm;

    if (pFilter^.zTerm <> nil) and (isScan = 0) then begin
      if (pCsr^.nTerm < pFilter^.nTerm)
       or ((isPrefix = 0) and (pCsr^.nTerm > pFilter^.nTerm))
       or (libc_memcmp(pCsr^.zTerm, pFilter^.zTerm, NativeUInt(pFilter^.nTerm)) <> 0)
      then break;
    end;

    nMerge := 1;
    while (nMerge < nSegment)
      and (PPFts3SegReader(apSegment)[nMerge]^.aNode <> nil)
      and (PPFts3SegReader(apSegment)[nMerge]^.nTerm = pCsr^.nTerm)
      and (libc_memcmp(pCsr^.zTerm, PPFts3SegReader(apSegment)[nMerge]^.zTerm,
             NativeUInt(pCsr^.nTerm)) = 0) do
      Inc(nMerge);

    if (nMerge = 1) and (isIgnoreEmpty = 0) and (isFirst = 0)
     and ((p^.bDescIdx = 0)
          or (not fts3SegReaderIsPending(PPFts3SegReader(apSegment)[0]))) then
    begin
      pCsr^.nDoclist := PPFts3SegReader(apSegment)[0]^.nDoclist;
      if fts3SegReaderIsPending(PPFts3SegReader(apSegment)[0]) then begin
        rc := fts3MsrBufferData(pCsr, PPFts3SegReader(apSegment)[0]^.aDoclist,
                sqlite3_int64(pCsr^.nDoclist));
        pCsr^.aDoclist := pCsr^.aBuffer;
      end else
        pCsr^.aDoclist := PPFts3SegReader(apSegment)[0]^.aDoclist;
      if rc = SQLITE_OK then rc := SQLITE_ROW;
    end else begin
      nDoclist := 0;
      iPrev := 0;
      for i := 0 to nMerge - 1 do
        fts3SegReaderFirstDocid(p, PPFts3SegReader(apSegment)[i]);
      fts3SegReaderSort(apSegment, nMerge, nMerge, xCmp);
      while PPFts3SegReader(apSegment)[0]^.pOffsetList <> nil do begin
        pList := nil;
        nList := 0;
        iDocid := PPFts3SegReader(apSegment)[0]^.iDocid;
        fts3SegReaderNextDocid(p, PPFts3SegReader(apSegment)[0], @pList, @nList);
        j := 1;
        while (j < nMerge)
          and (PPFts3SegReader(apSegment)[j]^.pOffsetList <> nil)
          and (PPFts3SegReader(apSegment)[j]^.iDocid = iDocid) do begin
          fts3SegReaderNextDocid(p, PPFts3SegReader(apSegment)[j], nil, nil);
          Inc(j);
        end;
        if isColFilter <> 0 then
          fts3ColumnFilter(pFilter^.iCol, 0, @pList, @nList);
        if (isIgnoreEmpty = 0) or (nList > 0) then begin
          if (p^.bDescIdx <> 0) and (nDoclist > 0) then begin
            if iPrev <= iDocid then Exit(FTS_CORRUPT_VTAB);
            iDelta := sqlite3_int64(u64(iPrev) - u64(iDocid));
          end else begin
            if (nDoclist > 0) and (iPrev >= iDocid) then Exit(FTS_CORRUPT_VTAB);
            iDelta := sqlite3_int64(u64(iDocid) - u64(iPrev));
          end;
          if isRequirePos <> 0 then nByte := sqlite3Fts3VarintLen(u64(iDelta)) + nList + 1
                               else nByte := sqlite3Fts3VarintLen(u64(iDelta));
          rc := fts3GrowSegReaderBuffer(pCsr,
                  sqlite3_int64(nByte)+nDoclist+FTS3_NODE_PADDING);
          if rc <> 0 then Exit(rc);
          if isFirst <> 0 then begin
            a := @pCsr^.aBuffer[nDoclist];
            nWrite := sqlite3Fts3FirstFilter(iDelta, pList, nList, a);
            if nWrite <> 0 then begin
              iPrev := iDocid;
              nDoclist := nDoclist + nWrite;
            end;
          end else begin
            nDoclist := nDoclist +
                sqlite3Fts3PutVarint(@pCsr^.aBuffer[nDoclist], iDelta);
            iPrev := iDocid;
            if isRequirePos <> 0 then begin
              libc_memcpy(@pCsr^.aBuffer[nDoclist], pList, NativeUInt(nList));
              nDoclist := nDoclist + nList;
              pCsr^.aBuffer[nDoclist] := #0;
              Inc(nDoclist);
            end;
          end;
        end;
        fts3SegReaderSort(apSegment, nMerge, j, xCmp);
      end;
      if nDoclist > 0 then begin
        rc := fts3GrowSegReaderBuffer(pCsr, sqlite3_int64(nDoclist)+FTS3_NODE_PADDING);
        if rc <> 0 then Exit(rc);
        libc_memset(@pCsr^.aBuffer[nDoclist], 0, FTS3_NODE_PADDING);
        pCsr^.aDoclist := pCsr^.aBuffer;
        pCsr^.nDoclist := nDoclist;
        rc := SQLITE_ROW;
      end;
    end;
    pCsr^.nAdvance := nMerge;
  until rc <> SQLITE_OK;
  Result := rc;
end;

{ fts3_write.c:3081..3096 — sqlite3Fts3SegReaderFinish. }
procedure sqlite3Fts3SegReaderFinish(pCsr: PFts3MultiSegReader);
var
  i: cint;
begin
  if pCsr <> nil then begin
    for i := 0 to pCsr^.nSegment - 1 do
      sqlite3Fts3SegReaderFree(PPFts3SegReader(pCsr^.apSegment)[i]);
    sqlite3_free(pCsr^.apSegment);
    sqlite3_free(pCsr^.aBuffer);
    pCsr^.nSegment := 0;
    pCsr^.apSegment := nil;
    pCsr^.aBuffer := nil;
  end;
end;

{ fts3_write.c:3108..3134 — fts3ReadEndBlockField. }
procedure fts3ReadEndBlockField(pStmt: PVdbe; iCol: cint;
  piEndBlock, pnByte: Psqlite3_int64);
var
  zText: PByte;
  i, iMul: cint;
  iVal: u64;
begin
  zText := PByte(sqlite3_column_text(pStmt, iCol));
  if zText <> nil then begin
    iMul := 1;
    iVal := 0;
    i := 0;
    while (zText[i] >= Ord('0')) and (zText[i] <= Ord('9')) do begin
      iVal := iVal*10 + (zText[i] - Ord('0'));
      Inc(i);
    end;
    piEndBlock^ := sqlite3_int64(iVal);
    while zText[i] = Ord(' ') do Inc(i);
    iVal := 0;
    if zText[i] = Ord('-') then begin Inc(i); iMul := -1; end;
    while (zText[i] >= Ord('0')) and (zText[i] <= Ord('9')) do begin
      iVal := iVal*10 + (zText[i] - Ord('0'));
      Inc(i);
    end;
    pnByte^ := sqlite3_int64(iVal) * sqlite3_int64(iMul);
  end;
end;

{ fts3_write.c:3141..3230 — fts3PromoteSegments. }
function fts3PromoteSegments(p: PFts3Table; iAbsLevel, nByte: sqlite3_int64): cint;
var
  rc: cint;
  pRange: PVdbe;
  bOk, iIdx: cint;
  iLast, nLimit, nSize, dummy: sqlite3_int64;
  pUpdate1, pUpdate2: PVdbe;
begin
  rc := fts3SqlStmt(p, SQL_SELECT_LEVEL_RANGE2, @pRange, nil);
  if rc = SQLITE_OK then begin
    bOk := 0;
    iLast := (iAbsLevel div FTS3_SEGDIR_MAXLEVEL + 1) * FTS3_SEGDIR_MAXLEVEL - 1;
    nLimit := (nByte*3) div 2;
    sqlite3_bind_int64(pRange, 1, iAbsLevel+1);
    sqlite3_bind_int64(pRange, 2, iLast);
    while SQLITE_ROW = sqlite3_step(pRange) do begin
      nSize := 0; dummy := 0;
      fts3ReadEndBlockField(pRange, 2, @dummy, @nSize);
      if (nSize <= 0) or (nSize > nLimit) then begin
        bOk := 0;
        break;
      end;
      bOk := 1;
    end;
    rc := sqlite3_reset(pRange);

    if bOk <> 0 then begin
      iIdx := 0;
      pUpdate1 := nil;
      pUpdate2 := nil;
      if rc = SQLITE_OK then rc := fts3SqlStmt(p, SQL_UPDATE_LEVEL_IDX, @pUpdate1, nil);
      if rc = SQLITE_OK then rc := fts3SqlStmt(p, SQL_UPDATE_LEVEL, @pUpdate2, nil);
      if rc = SQLITE_OK then begin
        sqlite3_bind_int64(pRange, 1, iAbsLevel);
        while SQLITE_ROW = sqlite3_step(pRange) do begin
          sqlite3_bind_int(pUpdate1, 1, iIdx); Inc(iIdx);
          sqlite3_bind_int(pUpdate1, 2, sqlite3_column_int(pRange, 0));
          sqlite3_bind_int(pUpdate1, 3, sqlite3_column_int(pRange, 1));
          sqlite3_step(pUpdate1);
          rc := sqlite3_reset(pUpdate1);
          if rc <> SQLITE_OK then begin
            sqlite3_reset(pRange);
            break;
          end;
        end;
      end;
      if rc = SQLITE_OK then rc := sqlite3_reset(pRange);
      if rc = SQLITE_OK then begin
        sqlite3_bind_int64(pUpdate2, 1, iAbsLevel);
        sqlite3_step(pUpdate2);
        rc := sqlite3_reset(pUpdate2);
      end;
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:3243..3336 — fts3SegmentMerge. }
function fts3SegmentMerge(p: PFts3Table; iLangid, iIndex, iLevel: cint): cint;
var
  rc, iIdx: cint;
  iNewLevel: sqlite3_int64;
  pWriter: PSegmentWriter;
  filter: TFts3SegFilter;
  csr: TFts3MultiSegReader;
  bIgnoreEmpty: cint;
  iMaxLevel: sqlite3_int64;
label finished;
begin
  iIdx := 0;
  iNewLevel := 0;
  pWriter := nil;
  bIgnoreEmpty := 0;
  iMaxLevel := 0;
  Assert((iLevel = FTS3_SEGCURSOR_ALL) or (iLevel = FTS3_SEGCURSOR_PENDING)
         or (iLevel >= 0));
  Assert(iLevel < FTS3_SEGDIR_MAXLEVEL);
  Assert((iIndex >= 0) and (iIndex < p^.nIndex));

  rc := sqlite3Fts3SegReaderCursor(p, iLangid, iIndex, iLevel, nil, 0, 1, 0, @csr);
  if (rc <> SQLITE_OK) or (csr.nSegment = 0) then goto finished;

  if iLevel <> FTS3_SEGCURSOR_PENDING then begin
    rc := fts3SegmentMaxLevel(p, iLangid, iIndex, @iMaxLevel);
    if rc <> SQLITE_OK then goto finished;
  end;

  if iLevel = FTS3_SEGCURSOR_ALL then begin
    if (csr.nSegment = 1)
     and (not fts3SegReaderIsPending(PPFts3SegReader(csr.apSegment)[0])) then begin
      rc := SQLITE_DONE;
      goto finished;
    end;
    iNewLevel := iMaxLevel;
    bIgnoreEmpty := 1;
  end else begin
    Assert(FTS3_SEGCURSOR_PENDING = -1);
    iNewLevel := getAbsoluteLevel(p, iLangid, iIndex, iLevel+1);
    rc := fts3AllocateSegdirIdx(p, iLangid, iIndex, iLevel+1, @iIdx);
    bIgnoreEmpty := cint(Ord((iLevel <> FTS3_SEGCURSOR_PENDING)
                              and (iNewLevel > iMaxLevel)));
  end;
  if rc <> SQLITE_OK then goto finished;

  Assert(csr.nSegment > 0);
  libc_memset(@filter, 0, SizeOf(TFts3SegFilter));
  filter.flags := FTS3_SEGMENT_REQUIRE_POS;
  if bIgnoreEmpty <> 0 then filter.flags := filter.flags or FTS3_SEGMENT_IGNORE_EMPTY;

  rc := sqlite3Fts3SegReaderStart(p, @csr, @filter);
  while SQLITE_OK = rc do begin
    rc := sqlite3Fts3SegReaderStep(p, @csr);
    if rc <> SQLITE_ROW then break;
    rc := fts3SegWriterAdd(p, @pWriter, 1, csr.zTerm, csr.nTerm,
            csr.aDoclist, csr.nDoclist);
  end;
  if rc <> SQLITE_OK then goto finished;

  if iLevel <> FTS3_SEGCURSOR_PENDING then begin
    rc := fts3DeleteSegdir(p, iLangid, iIndex, iLevel, csr.apSegment, csr.nSegment);
    if rc <> SQLITE_OK then goto finished;
  end;
  if pWriter <> nil then begin
    rc := fts3SegWriterFlush(p, pWriter, iNewLevel, iIdx);
    if rc = SQLITE_OK then begin
      if (iLevel = FTS3_SEGCURSOR_PENDING) or (iNewLevel < iMaxLevel) then
        rc := fts3PromoteSegments(p, iNewLevel, pWriter^.nLeafData);
    end;
  end;

finished:
  fts3SegWriterFree(pWriter);
  sqlite3Fts3SegReaderFinish(@csr);
  Result := rc;
end;

{ fts3_write.c:3342..3376 — sqlite3Fts3PendingTermsFlush. }
function sqlite3Fts3PendingTermsFlush(p: PFts3Table): cint;
var
  rc, i: cint;
  pStmt: PVdbe;
begin
  rc := SQLITE_OK;
  i := 0;
  while (rc = SQLITE_OK) and (i < p^.nIndex) do begin
    rc := fts3SegmentMerge(p, p^.iPrevLangid, i, FTS3_SEGCURSOR_PENDING);
    if rc = SQLITE_DONE then rc := SQLITE_OK;
    Inc(i);
  end;

  if (rc = SQLITE_OK) and (p^.bHasStat <> 0)
   and (p^.nAutoincrmerge = $ff) and (p^.nLeafAdd > 0) then begin
    pStmt := nil;
    rc := fts3SqlStmt(p, SQL_SELECT_STAT, @pStmt, nil);
    if rc = SQLITE_OK then begin
      sqlite3_bind_int(pStmt, 1, FTS_STAT_AUTOINCRMERGE);
      rc := sqlite3_step(pStmt);
      if rc = SQLITE_ROW then begin
        p^.nAutoincrmerge := sqlite3_column_int(pStmt, 0);
        if p^.nAutoincrmerge = 1 then p^.nAutoincrmerge := 8;
      end else if rc = SQLITE_DONE then
        p^.nAutoincrmerge := 0;
      rc := sqlite3_reset(pStmt);
    end;
  end;

  if rc = SQLITE_OK then sqlite3Fts3PendingTermsClear(p);
  Result := rc;
end;

{ ===================================================================== }
{ Section 6 — %_docsize / %_stat FTS4 maintenance + optimize/rebuild.     }
{ (fts3_write.c:3381..3654).                                             }
{ ===================================================================== }

{ fts3_write.c:3381..3392 — fts3EncodeIntArray. }
procedure fts3EncodeIntArray(N: cint; a: Pcuint; zBuf: PChar; pNBuf: Pcint);
var
  i, j: cint;
begin
  j := 0;
  for i := 0 to N - 1 do
    j := j + sqlite3Fts3PutVarint(@zBuf[j], sqlite3_int64(Pcuint(a)[i]));
  pNBuf^ := j;
end;

{ fts3_write.c:3397..3413 — fts3DecodeIntArray. }
procedure fts3DecodeIntArray(N: cint; a: Pcuint; const zBuf: PChar; nBuf: cint);
var
  i, j: cint;
  x: sqlite3_int64;
begin
  i := 0;
  if (nBuf <> 0) and ((Byte(zBuf[nBuf-1]) and $80) = 0) then begin
    j := 0;
    while (i < N) and (j < nBuf) do begin
      j := j + sqlite3Fts3GetVarint(@zBuf[j], @x);
      Pcuint(a)[i] := cuint(x and $ffffffff);
      Inc(i);
    end;
  end;
  while i < N do begin Pcuint(a)[i] := 0; Inc(i); end;
end;

{ fts3_write.c:3420..3447 — fts3InsertDocsize. }
procedure fts3InsertDocsize(pRC: Pcint; p: PFts3Table; aSz: Pcuint);
var
  pBlob: PChar;
  nBlob, rc: cint;
  pStmt: PVdbe;
begin
  if pRC^ <> 0 then Exit;
  pBlob := PChar(sqlite3_malloc64(u64(10*sqlite3_int64(p^.nColumn))));
  if pBlob = nil then begin pRC^ := SQLITE_NOMEM; Exit; end;
  fts3EncodeIntArray(p^.nColumn, aSz, pBlob, @nBlob);
  rc := fts3SqlStmt(p, SQL_REPLACE_DOCSIZE, @pStmt, nil);
  if rc <> 0 then begin sqlite3_free(pBlob); pRC^ := rc; Exit; end;
  sqlite3_bind_int64(pStmt, 1, p^.iPrevDocid);
  sqlite3_bind_blob(pStmt, 2, pBlob, nBlob, TxDelProc(@sqlite3_free));
  sqlite3_step(pStmt);
  pRC^ := sqlite3_reset(pStmt);
end;

{ fts3_write.c:3464..3534 — fts3UpdateDocTotals. }
procedure fts3UpdateDocTotals(pRC: Pcint; p: PFts3Table;
  aSzIns, aSzDel: Pcuint; nChng: cint);
var
  pBlob: PChar;
  nBlob, i, rc: cint;
  a: Pcuint;
  pStmt: PVdbe;
  nStat: cint;
  x: cuint;
begin
  nStat := p^.nColumn+2;
  if pRC^ <> 0 then Exit;
  a := Pcuint(sqlite3_malloc64(u64((SizeOf(cuint)+10)*sqlite3_int64(nStat))));
  if a = nil then begin pRC^ := SQLITE_NOMEM; Exit; end;
  pBlob := PChar(@Pcuint(a)[nStat]);
  rc := fts3SqlStmt(p, SQL_SELECT_STAT, @pStmt, nil);
  if rc <> 0 then begin sqlite3_free(a); pRC^ := rc; Exit; end;
  sqlite3_bind_int(pStmt, 1, FTS_STAT_DOCTOTAL);
  if sqlite3_step(pStmt) = SQLITE_ROW then
    fts3DecodeIntArray(nStat, a, sqlite3_column_blob(pStmt, 0),
                       sqlite3_column_bytes(pStmt, 0))
  else
    libc_memset(a, 0, NativeUInt(SizeOf(cuint)*nStat));
  rc := sqlite3_reset(pStmt);
  if rc <> SQLITE_OK then begin sqlite3_free(a); pRC^ := rc; Exit; end;
  if (nChng < 0) and (Pcuint(a)[0] < cuint(-nChng)) then
    Pcuint(a)[0] := 0
  else
    Pcuint(a)[0] := Pcuint(a)[0] + cuint(nChng);
  for i := 0 to p^.nColumn do begin
    x := Pcuint(a)[i+1];
    if (x + Pcuint(aSzIns)[i]) < Pcuint(aSzDel)[i] then
      x := 0
    else
      x := x + Pcuint(aSzIns)[i] - Pcuint(aSzDel)[i];
    Pcuint(a)[i+1] := x;
  end;
  fts3EncodeIntArray(nStat, a, pBlob, @nBlob);
  rc := fts3SqlStmt(p, SQL_REPLACE_STAT, @pStmt, nil);
  if rc <> 0 then begin sqlite3_free(a); pRC^ := rc; Exit; end;
  sqlite3_bind_int(pStmt, 1, FTS_STAT_DOCTOTAL);
  sqlite3_bind_blob(pStmt, 2, pBlob, nBlob, SQLITE_STATIC);
  sqlite3_step(pStmt);
  pRC^ := sqlite3_reset(pStmt);
  sqlite3_bind_null(pStmt, 2);
  sqlite3_free(a);
end;

{ fts3_write.c:3540..3571 — fts3DoOptimize. }
function fts3DoOptimize(p: PFts3Table; bReturnDone: cint): cint;
var
  bSeenDone, rc, rc2, i, iLangid: cint;
  pAllLangid: PVdbe;
begin
  bSeenDone := 0;
  pAllLangid := nil;
  rc := sqlite3Fts3PendingTermsFlush(p);
  if rc = SQLITE_OK then rc := fts3SqlStmt(p, SQL_SELECT_ALL_LANGID, @pAllLangid, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int(pAllLangid, 1, p^.iPrevLangid);
    sqlite3_bind_int(pAllLangid, 2, p^.nIndex);
    while sqlite3_step(pAllLangid) = SQLITE_ROW do begin
      iLangid := sqlite3_column_int(pAllLangid, 0);
      i := 0;
      while (rc = SQLITE_OK) and (i < p^.nIndex) do begin
        rc := fts3SegmentMerge(p, iLangid, i, FTS3_SEGCURSOR_ALL);
        if rc = SQLITE_DONE then begin
          bSeenDone := 1;
          rc := SQLITE_OK;
        end;
        Inc(i);
      end;
    end;
    rc2 := sqlite3_reset(pAllLangid);
    if rc = SQLITE_OK then rc := rc2;
  end;
  sqlite3Fts3SegmentsClose(p);
  if (rc = SQLITE_OK) and (bReturnDone <> 0) and (bSeenDone <> 0) then
    Result := SQLITE_DONE
  else
    Result := rc;
end;

{ fts3_write.c:3583..3654 — fts3DoRebuild. }
function fts3DoRebuild(p: PFts3Table): cint;
var
  rc, rc2, nEntry, iCol, iLangid: cint;
  aSz, aSzIns, aSzDel: Pcuint;
  pStmt: PVdbe;
  zSql, z: PChar;
  nByte: sqlite3_int64;
begin
  aSz := nil; aSzIns := nil; aSzDel := nil; pStmt := nil; nEntry := 0;
  rc := fts3DeleteAll(p, 0);
  if rc = SQLITE_OK then begin
    zSql := PChar(sqlite3PfMprintf(PAnsiChar('SELECT %s'), [p^.zReadExprlist]));
    if zSql = nil then
      rc := SQLITE_NOMEM
    else begin
      rc := sqlite3Fts3PrepareStmt(p, zSql, 0, 1, @pStmt);
      sqlite3_free(zSql);
    end;

    if rc = SQLITE_OK then begin
      nByte := SizeOf(cuint) * (sqlite3_int64(p^.nColumn)+1)*3;
      aSz := Pcuint(sqlite3_malloc64(u64(nByte)));
      if aSz = nil then
        rc := SQLITE_NOMEM
      else begin
        libc_memset(aSz, 0, NativeUInt(nByte));
        aSzIns := @Pcuint(aSz)[p^.nColumn+1];
        aSzDel := @Pcuint(aSzIns)[p^.nColumn+1];
      end;
    end;

    while (rc = SQLITE_OK) and (SQLITE_ROW = sqlite3_step(pStmt)) do begin
      iLangid := langidFromSelect(p, pStmt);
      rc := fts3PendingTermsDocid(p, 0, iLangid, sqlite3_column_int64(pStmt, 0));
      libc_memset(aSz, 0, NativeUInt(SizeOf(cuint) * (p^.nColumn+1)));
      iCol := 0;
      while (rc = SQLITE_OK) and (iCol < p^.nColumn) do begin
        if PByte(p^.abNotindexed)[iCol] = 0 then begin
          z := PChar(sqlite3_column_text(pStmt, iCol+1));
          rc := fts3PendingTermsAdd(p, iLangid, z, iCol, @Pcuint(aSz)[iCol]);
          Pcuint(aSz)[p^.nColumn] := Pcuint(aSz)[p^.nColumn] +
              cuint(sqlite3_column_bytes(pStmt, iCol+1));
        end;
        Inc(iCol);
      end;
      if p^.bHasDocsize <> 0 then fts3InsertDocsize(@rc, p, aSz);
      if rc <> SQLITE_OK then begin
        sqlite3_finalize(pStmt);
        pStmt := nil;
      end else begin
        Inc(nEntry);
        for iCol := 0 to p^.nColumn do
          Pcuint(aSzIns)[iCol] := Pcuint(aSzIns)[iCol] + Pcuint(aSz)[iCol];
      end;
    end;
    if p^.bFts4 <> 0 then fts3UpdateDocTotals(@rc, p, aSzIns, aSzDel, nEntry);
    sqlite3_free(aSz);

    if pStmt <> nil then begin
      rc2 := sqlite3_finalize(pStmt);
      if rc = SQLITE_OK then rc := rc2;
    end;
  end;
  Result := rc;
end;

{ ===================================================================== }
{ Section 7 — incremental merge machinery (fts3_write.c:3663..5113).      }
{ ===================================================================== }

{ fts3_write.c:3663..3705 — fts3IncrmergeCsr. }
function fts3IncrmergeCsr(p: PFts3Table; iAbsLevel: sqlite3_int64; nSeg: cint;
  pCsr: PFts3MultiSegReader): cint;
var
  rc, i, rc2: cint;
  pStmt: PVdbe;
  nByte: sqlite3_int64;
begin
  pStmt := nil;
  libc_memset(pCsr, 0, SizeOf(TFts3MultiSegReader));
  nByte := SizeOf(PFts3SegReader) * nSeg;
  pCsr^.apSegment := PPFts3SegReader(sqlite3_malloc64(u64(nByte)));
  if pCsr^.apSegment = nil then
    rc := SQLITE_NOMEM
  else begin
    libc_memset(pCsr^.apSegment, 0, NativeUInt(nByte));
    rc := fts3SqlStmt(p, SQL_SELECT_LEVEL, @pStmt, nil);
  end;
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pStmt, 1, iAbsLevel);
    Assert(pCsr^.nSegment = 0);
    i := 0;
    while (rc = SQLITE_OK) and (sqlite3_step(pStmt) = SQLITE_ROW) and (i < nSeg) do
    begin
      rc := sqlite3Fts3SegReaderNew(i, 0,
              sqlite3_column_int64(pStmt, 1),
              sqlite3_column_int64(pStmt, 2),
              sqlite3_column_int64(pStmt, 3),
              sqlite3_column_blob(pStmt, 4),
              sqlite3_column_bytes(pStmt, 4),
              @PPFts3SegReader(pCsr^.apSegment)[i]);
      Inc(pCsr^.nSegment);
      Inc(i);
    end;
    rc2 := sqlite3_reset(pStmt);
    if rc = SQLITE_OK then rc := rc2;
  end;
  Result := rc;
end;

{ fts3_write.c:3779..3790 — blobGrowBuffer. }
procedure blobGrowBuffer(pBlob: PFtsBlob; nMin: cint; pRc: Pcint);
var
  nAlloc: cint;
  a: PChar;
begin
  if (pRc^ = SQLITE_OK) and (nMin > pBlob^.nAlloc) then begin
    nAlloc := nMin;
    a := PChar(sqlite3_realloc64(pBlob^.a, u64(nAlloc)));
    if a <> nil then begin
      pBlob^.nAlloc := nAlloc;
      pBlob^.a := a;
    end else
      pRc^ := SQLITE_NOMEM;
  end;
end;

{ fts3_write.c:3802..3840 — nodeReaderNext. }
function nodeReaderNext(p: PNodeReader): cint;
var
  bFirst, nPrefix, nSuffix, rc: cint;
begin
  bFirst := cint(Ord(p^.term.n = 0));
  nPrefix := 0;
  nSuffix := 0;
  rc := SQLITE_OK;
  Assert(p^.aNode <> nil);
  if (p^.iChild <> 0) and (bFirst = 0) then Inc(p^.iChild);
  if p^.iOff >= p^.nNode then
    p^.aNode := nil
  else begin
    if bFirst = 0 then
      p^.iOff := p^.iOff + fts3GetVarint32(@p^.aNode[p^.iOff], @nPrefix);
    p^.iOff := p^.iOff + fts3GetVarint32(@p^.aNode[p^.iOff], @nSuffix);
    if (nPrefix > p^.term.n) or (nSuffix > p^.nNode-p^.iOff) or (nSuffix = 0) then
      Exit(FTS_CORRUPT_VTAB);
    blobGrowBuffer(@p^.term, nPrefix+nSuffix, @rc);
    if (rc = SQLITE_OK) and (p^.term.a <> nil) then begin
      libc_memcpy(@p^.term.a[nPrefix], @p^.aNode[p^.iOff], NativeUInt(nSuffix));
      p^.term.n := nPrefix+nSuffix;
      p^.iOff := p^.iOff + nSuffix;
      if p^.iChild = 0 then begin
        p^.iOff := p^.iOff + fts3GetVarint32(@p^.aNode[p^.iOff], @p^.nDoclist);
        if (p^.nNode-p^.iOff) < p^.nDoclist then Exit(FTS_CORRUPT_VTAB);
        p^.aDoclist := @p^.aNode[p^.iOff];
        p^.iOff := p^.iOff + p^.nDoclist;
      end;
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:3845..3847 — nodeReaderRelease. }
procedure nodeReaderRelease(p: PNodeReader);
begin
  sqlite3_free(p^.term.a);
end;

{ fts3_write.c:3856..3870 — nodeReaderInit. }
function nodeReaderInit(p: PNodeReader; const aNode: PChar; nNode: cint): cint;
begin
  libc_memset(p, 0, SizeOf(TNodeReader));
  p^.aNode := aNode;
  p^.nNode := nNode;
  if (aNode <> nil) and (aNode[0] <> #0) then
    p^.iOff := 1 + sqlite3Fts3GetVarint(@p^.aNode[1], @p^.iChild)
  else
    p^.iOff := 1;
  if aNode <> nil then Result := nodeReaderNext(p) else Result := SQLITE_OK;
end;

{ fts3_write.c:3882..3960 — fts3IncrmergePush. }
function fts3IncrmergePush(p: PFts3Table; pWriter: PIncrmergeWriter;
  const zTerm: PChar; nTerm: cint): cint;
var
  iPtr: sqlite3_int64;
  iLayer: cint;
  iNextPtr: sqlite3_int64;
  pNode: PNodeWriter;
  rc, nPrefix, nSuffix, nSpace: cint;
  pBlk: PFtsBlob;
begin
  iPtr := pWriter^.aNodeWriter[0].iBlock;
  Assert(nTerm > 0);
  iLayer := 1;
  while iLayer < FTS_MAX_APPENDABLE_HEIGHT do begin
    iNextPtr := 0;
    pNode := @pWriter^.aNodeWriter[iLayer];
    rc := SQLITE_OK;
    nPrefix := fts3PrefixCompress(pNode^.key.a, pNode^.key.n, zTerm, nTerm);
    nSuffix := nTerm - nPrefix;
    if nSuffix <= 0 then Exit(FTS_CORRUPT_VTAB);
    nSpace := sqlite3Fts3VarintLen(nPrefix);
    nSpace := nSpace + sqlite3Fts3VarintLen(nSuffix) + nSuffix;

    if (pNode^.key.n = 0) or ((pNode^.block.n + nSpace) <= p^.nNodeSize) then begin
      pBlk := @pNode^.block;
      if pBlk^.n = 0 then begin
        blobGrowBuffer(pBlk, p^.nNodeSize, @rc);
        if rc = SQLITE_OK then begin
          pBlk^.a[0] := Chr(iLayer);
          pBlk^.n := 1 + sqlite3Fts3PutVarint(@pBlk^.a[1], iPtr);
        end;
      end;
      blobGrowBuffer(pBlk, pBlk^.n + nSpace, @rc);
      blobGrowBuffer(@pNode^.key, nTerm, @rc);
      if rc = SQLITE_OK then begin
        if pNode^.key.n <> 0 then
          pBlk^.n := pBlk^.n + sqlite3Fts3PutVarint(@pBlk^.a[pBlk^.n], nPrefix);
        pBlk^.n := pBlk^.n + sqlite3Fts3PutVarint(@pBlk^.a[pBlk^.n], nSuffix);
        libc_memcpy(@pBlk^.a[pBlk^.n], @zTerm[nPrefix], NativeUInt(nSuffix));
        pBlk^.n := pBlk^.n + nSuffix;
        libc_memcpy(pNode^.key.a, zTerm, NativeUInt(nTerm));
        pNode^.key.n := nTerm;
      end;
    end else begin
      rc := fts3WriteSegment(p, pNode^.iBlock, pNode^.block.a, pNode^.block.n);
      pNode^.block.a[0] := Chr(iLayer);
      pNode^.block.n := 1 + sqlite3Fts3PutVarint(@pNode^.block.a[1], iPtr+1);
      iNextPtr := pNode^.iBlock;
      Inc(pNode^.iBlock);
      pNode^.key.n := 0;
    end;
    if (rc <> SQLITE_OK) or (iNextPtr = 0) then Exit(rc);
    iPtr := iNextPtr;
    Inc(iLayer);
  end;
  Assert(False);
  Result := 0;
end;

{ fts3_write.c:3986..4031 — fts3AppendToNode. }
function fts3AppendToNode(pNode, pPrev: PFtsBlob; const zTerm: PChar;
  nTerm: cint; const aDoclist: PChar; nDoclist: cint): cint;
var
  rc, bFirst, nPrefix, nSuffix: cint;
begin
  rc := SQLITE_OK;
  bFirst := cint(Ord(pPrev^.n = 0));
  Assert(pNode^.n > 0);
  blobGrowBuffer(pPrev, nTerm, @rc);
  if rc <> SQLITE_OK then Exit(rc);
  Assert(pPrev^.a <> nil);
  nPrefix := fts3PrefixCompress(pPrev^.a, pPrev^.n, zTerm, nTerm);
  nSuffix := nTerm - nPrefix;
  if nSuffix <= 0 then Exit(FTS_CORRUPT_VTAB);
  libc_memcpy(pPrev^.a, zTerm, NativeUInt(nTerm));
  pPrev^.n := nTerm;
  if bFirst = 0 then
    pNode^.n := pNode^.n + sqlite3Fts3PutVarint(@pNode^.a[pNode^.n], nPrefix);
  pNode^.n := pNode^.n + sqlite3Fts3PutVarint(@pNode^.a[pNode^.n], nSuffix);
  libc_memcpy(@pNode^.a[pNode^.n], @zTerm[nPrefix], NativeUInt(nSuffix));
  pNode^.n := pNode^.n + nSuffix;
  if aDoclist <> nil then begin
    pNode^.n := pNode^.n + sqlite3Fts3PutVarint(@pNode^.a[pNode^.n], nDoclist);
    libc_memcpy(@pNode^.a[pNode^.n], aDoclist, NativeUInt(nDoclist));
    pNode^.n := pNode^.n + nDoclist;
  end;
  Assert(pNode^.n <= pNode^.nAlloc);
  Result := SQLITE_OK;
end;

{ fts3_write.c:4039..4114 — fts3IncrmergeAppend. }
function fts3IncrmergeAppend(p: PFts3Table; pWriter: PIncrmergeWriter;
  pCsr: PFts3MultiSegReader): cint;
var
  zTerm, aDoclist: PChar;
  nTerm, nDoclist, rc, nSpace, nPrefix, nSuffix: cint;
  pLeaf: PNodeWriter;
begin
  zTerm := pCsr^.zTerm;
  nTerm := pCsr^.nTerm;
  aDoclist := pCsr^.aDoclist;
  nDoclist := pCsr^.nDoclist;
  rc := SQLITE_OK;
  pLeaf := @pWriter^.aNodeWriter[0];
  nPrefix := fts3PrefixCompress(pLeaf^.key.a, pLeaf^.key.n, zTerm, nTerm);
  nSuffix := nTerm - nPrefix;
  if nSuffix <= 0 then Exit(FTS_CORRUPT_VTAB);

  nSpace := sqlite3Fts3VarintLen(nPrefix);
  nSpace := nSpace + sqlite3Fts3VarintLen(nSuffix) + nSuffix;
  nSpace := nSpace + sqlite3Fts3VarintLen(nDoclist) + nDoclist;

  if (pLeaf^.block.n > 0)
   and ((pLeaf^.block.n + nSpace) > p^.nNodeSize)
   and (pLeaf^.iBlock < (pWriter^.iStart + pWriter^.nLeafEst)) then begin
    rc := fts3WriteSegment(p, pLeaf^.iBlock, pLeaf^.block.a, pLeaf^.block.n);
    Inc(pWriter^.nWork);
    if rc = SQLITE_OK then rc := fts3IncrmergePush(p, pWriter, zTerm, nPrefix+1);
    Inc(pLeaf^.iBlock);
    pLeaf^.key.n := 0;
    pLeaf^.block.n := 0;
    nSuffix := nTerm;
    nSpace := 1;
    nSpace := nSpace + sqlite3Fts3VarintLen(nSuffix) + nSuffix;
    nSpace := nSpace + sqlite3Fts3VarintLen(nDoclist) + nDoclist;
  end;

  pWriter^.nLeafData := pWriter^.nLeafData + nSpace;
  blobGrowBuffer(@pLeaf^.block, pLeaf^.block.n + nSpace, @rc);
  if rc = SQLITE_OK then begin
    if pLeaf^.block.n = 0 then begin
      pLeaf^.block.n := 1;
      pLeaf^.block.a[0] := #0;
    end;
    rc := fts3AppendToNode(@pLeaf^.block, @pLeaf^.key, zTerm, nTerm,
            aDoclist, nDoclist);
  end;
  Result := rc;
end;

{ fts3_write.c:4129..4209 — fts3IncrmergeRelease. }
procedure fts3IncrmergeRelease(p: PFts3Table; pWriter: PIncrmergeWriter;
  pRc: Pcint);
var
  i, iRoot, rc: cint;
  pNode, pRoot: PNodeWriter;
  pBlock: PFtsBlob;
begin
  rc := pRc^;
  iRoot := FTS_MAX_APPENDABLE_HEIGHT-1;
  while iRoot >= 0 do begin
    pNode := @pWriter^.aNodeWriter[iRoot];
    if pNode^.block.n > 0 then break;
    sqlite3_free(pNode^.block.a);
    sqlite3_free(pNode^.key.a);
    Dec(iRoot);
  end;
  if iRoot < 0 then Exit;

  if iRoot = 0 then begin
    pBlock := @pWriter^.aNodeWriter[1].block;
    blobGrowBuffer(pBlock, 1 + FTS3_VARINT_MAX, @rc);
    if rc = SQLITE_OK then begin
      pBlock^.a[0] := Chr($01);
      pBlock^.n := 1 + sqlite3Fts3PutVarint(@pBlock^.a[1],
          pWriter^.aNodeWriter[0].iBlock);
    end;
    iRoot := 1;
  end;
  pRoot := @pWriter^.aNodeWriter[iRoot];

  for i := 0 to iRoot - 1 do begin
    pNode := @pWriter^.aNodeWriter[i];
    if (pNode^.block.n > 0) and (rc = SQLITE_OK) then
      rc := fts3WriteSegment(p, pNode^.iBlock, pNode^.block.a, pNode^.block.n);
    sqlite3_free(pNode^.block.a);
    sqlite3_free(pNode^.key.a);
  end;

  if rc = SQLITE_OK then begin
    if pWriter^.bNoLeafData = 0 then
      rc := fts3WriteSegdir(p, pWriter^.iAbsLevel+1, pWriter^.iIdx,
              pWriter^.iStart, pWriter^.aNodeWriter[0].iBlock, pWriter^.iEnd,
              pWriter^.nLeafData, pRoot^.block.a, pRoot^.block.n)
    else
      rc := fts3WriteSegdir(p, pWriter^.iAbsLevel+1, pWriter^.iIdx,
              pWriter^.iStart, pWriter^.aNodeWriter[0].iBlock, pWriter^.iEnd,
              0, pRoot^.block.a, pRoot^.block.n);
  end;
  sqlite3_free(pRoot^.block.a);
  sqlite3_free(pRoot^.key.a);
  pRc^ := rc;
end;

{ fts3_write.c:4219..4234 — fts3TermCmp. }
function fts3TermCmp(const zLhs: PChar; nLhs: cint; const zRhs: PChar;
  nRhs: cint): cint;
var
  nCmp, res: cint;
begin
  if nLhs < nRhs then nCmp := nLhs else nCmp := nRhs;
  if (nCmp <> 0) and (zLhs <> nil) and (zRhs <> nil) then
    res := libc_memcmp(zLhs, zRhs, NativeUInt(nCmp))
  else
    res := 0;
  if res = 0 then res := nLhs - nRhs;
  Result := res;
end;

{ fts3_write.c:4249..4263 — fts3IsAppendable. }
function fts3IsAppendable(p: PFts3Table; iEnd: sqlite3_int64; pbRes: Pcint): cint;
var
  bRes, rc: cint;
  pCheck: PVdbe;
begin
  bRes := 0;
  rc := fts3SqlStmt(p, SQL_SEGMENT_IS_APPENDABLE, @pCheck, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pCheck, 1, iEnd);
    if SQLITE_ROW = sqlite3_step(pCheck) then bRes := 1;
    rc := sqlite3_reset(pCheck);
  end;
  pbRes^ := bRes;
  Result := rc;
end;

{ fts3_write.c:4280..4421 — fts3IncrmergeLoad. }
function fts3IncrmergeLoad(p: PFts3Table; iAbsLevel: sqlite3_int64; iIdx: cint;
  const zKey: PChar; nKey: cint; pWriter: PIncrmergeWriter): cint;
var
  rc, rc2, bAppendable, nRoot, nLeaf, i, nHeight: cint;
  pSelect: PVdbe;
  iStart, iLeafEnd, iEnd: sqlite3_int64;
  aRoot, aLeaf, aBlock: PChar;
  nBlock: cint;
  reader: TNodeReader;
  pNode: PNodeWriter;
begin
  rc := fts3SqlStmt(p, SQL_SELECT_SEGDIR, @pSelect, nil);
  if rc = SQLITE_OK then begin
    iStart := 0; iLeafEnd := 0; iEnd := 0;
    aRoot := nil; nRoot := 0; bAppendable := 0;
    sqlite3_bind_int64(pSelect, 1, iAbsLevel+1);
    sqlite3_bind_int(pSelect, 2, iIdx);
    if sqlite3_step(pSelect) = SQLITE_ROW then begin
      iStart := sqlite3_column_int64(pSelect, 1);
      iLeafEnd := sqlite3_column_int64(pSelect, 2);
      fts3ReadEndBlockField(pSelect, 3, @iEnd, @pWriter^.nLeafData);
      if pWriter^.nLeafData < 0 then pWriter^.nLeafData := pWriter^.nLeafData * -1;
      pWriter^.bNoLeafData := cuchar(Ord(pWriter^.nLeafData = 0));
      nRoot := sqlite3_column_bytes(pSelect, 4);
      aRoot := sqlite3_column_blob(pSelect, 4);
      if aRoot = nil then begin
        sqlite3_reset(pSelect);
        if nRoot <> 0 then Exit(SQLITE_NOMEM) else Exit(FTS_CORRUPT_VTAB);
      end;
    end else
      Exit(sqlite3_reset(pSelect));

    rc := fts3IsAppendable(p, iEnd, @bAppendable);

    if (rc = SQLITE_OK) and (bAppendable <> 0) then begin
      aLeaf := nil; nLeaf := 0;
      rc := sqlite3Fts3ReadBlock(p, iLeafEnd, @aLeaf, @nLeaf, nil);
      if rc = SQLITE_OK then begin
        rc := nodeReaderInit(@reader, aLeaf, nLeaf);
        while (rc = SQLITE_OK) and (reader.aNode <> nil) do
          rc := nodeReaderNext(@reader);
        if fts3TermCmp(zKey, nKey, reader.term.a, reader.term.n) <= 0 then
          bAppendable := 0;
        nodeReaderRelease(@reader);
      end;
      sqlite3_free(aLeaf);
    end;

    if (rc = SQLITE_OK) and (bAppendable <> 0) then begin
      nHeight := cint(Byte(aRoot[0]));
      if (nHeight < 1) or (nHeight >= FTS_MAX_APPENDABLE_HEIGHT) then begin
        sqlite3_reset(pSelect);
        Exit(FTS_CORRUPT_VTAB);
      end;
      pWriter^.nLeafEst := ((iEnd - iStart) + 1) div FTS_MAX_APPENDABLE_HEIGHT;
      pWriter^.iStart := iStart;
      pWriter^.iEnd := iEnd;
      pWriter^.iAbsLevel := iAbsLevel;
      pWriter^.iIdx := iIdx;

      for i := nHeight+1 to FTS_MAX_APPENDABLE_HEIGHT-1 do
        pWriter^.aNodeWriter[i].iBlock := pWriter^.iStart + i*pWriter^.nLeafEst;

      pNode := @pWriter^.aNodeWriter[nHeight];
      pNode^.iBlock := pWriter^.iStart + pWriter^.nLeafEst*nHeight;
      blobGrowBuffer(@pNode^.block,
          cint(Fts3_MAX(nRoot, p^.nNodeSize))+FTS3_NODE_PADDING, @rc);
      if rc = SQLITE_OK then begin
        libc_memcpy(pNode^.block.a, aRoot, NativeUInt(nRoot));
        pNode^.block.n := nRoot;
        libc_memset(@pNode^.block.a[nRoot], 0, FTS3_NODE_PADDING);
      end;

      i := nHeight;
      while (i >= 0) and (rc = SQLITE_OK) do begin
        libc_memset(@reader, 0, SizeOf(reader));
        pNode := @pWriter^.aNodeWriter[i];
        if pNode^.block.a <> nil then begin
          rc := nodeReaderInit(@reader, pNode^.block.a, pNode^.block.n);
          while (reader.aNode <> nil) and (rc = SQLITE_OK) do
            rc := nodeReaderNext(@reader);
          blobGrowBuffer(@pNode^.key, reader.term.n, @rc);
          if rc = SQLITE_OK then begin
            if reader.term.n > 0 then
              libc_memcpy(pNode^.key.a, reader.term.a, NativeUInt(reader.term.n));
            pNode^.key.n := reader.term.n;
            if i > 0 then begin
              aBlock := nil; nBlock := 0;
              pNode := @pWriter^.aNodeWriter[i-1];
              pNode^.iBlock := reader.iChild;
              rc := sqlite3Fts3ReadBlock(p, reader.iChild, @aBlock, @nBlock, nil);
              blobGrowBuffer(@pNode^.block,
                  cint(Fts3_MAX(nBlock, p^.nNodeSize))+FTS3_NODE_PADDING, @rc);
              if rc = SQLITE_OK then begin
                libc_memcpy(pNode^.block.a, aBlock, NativeUInt(nBlock));
                pNode^.block.n := nBlock;
                libc_memset(@pNode^.block.a[nBlock], 0, FTS3_NODE_PADDING);
              end;
              sqlite3_free(aBlock);
            end;
          end;
        end;
        nodeReaderRelease(@reader);
        Dec(i);
      end;
    end;

    rc2 := sqlite3_reset(pSelect);
    if rc = SQLITE_OK then rc := rc2;
  end;
  Result := rc;
end;

{ fts3_write.c:4432..4449 — fts3IncrmergeOutputIdx. }
function fts3IncrmergeOutputIdx(p: PFts3Table; iAbsLevel: sqlite3_int64;
  piIdx: Pcint): cint;
var
  rc: cint;
  pOutputIdx: PVdbe;
begin
  rc := fts3SqlStmt(p, SQL_NEXT_SEGMENT_INDEX, @pOutputIdx, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pOutputIdx, 1, iAbsLevel+1);
    sqlite3_step(pOutputIdx);
    piIdx^ := sqlite3_column_int(pOutputIdx, 0);
    rc := sqlite3_reset(pOutputIdx);
  end;
  Result := rc;
end;

{ fts3_write.c:4477..4529 — fts3IncrmergeWriter. }
function fts3IncrmergeWriter(p: PFts3Table; iAbsLevel: sqlite3_int64; iIdx: cint;
  pCsr: PFts3MultiSegReader; pWriter: PIncrmergeWriter): cint;
var
  rc, i: cint;
  nLeafEst: sqlite3_int64;
  pLeafEst, pFirstBlock: PVdbe;
begin
  nLeafEst := 0;
  rc := fts3SqlStmt(p, SQL_MAX_LEAF_NODE_ESTIMATE, @pLeafEst, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pLeafEst, 1, iAbsLevel);
    sqlite3_bind_int64(pLeafEst, 2, pCsr^.nSegment);
    if SQLITE_ROW = sqlite3_step(pLeafEst) then
      nLeafEst := sqlite3_column_int64(pLeafEst, 0);
    rc := sqlite3_reset(pLeafEst);
  end;
  if rc <> SQLITE_OK then Exit(rc);

  rc := fts3SqlStmt(p, SQL_NEXT_SEGMENTS_ID, @pFirstBlock, nil);
  if rc = SQLITE_OK then begin
    if SQLITE_ROW = sqlite3_step(pFirstBlock) then begin
      pWriter^.iStart := sqlite3_column_int64(pFirstBlock, 0);
      pWriter^.iEnd := pWriter^.iStart - 1;
      pWriter^.iEnd := pWriter^.iEnd + nLeafEst * FTS_MAX_APPENDABLE_HEIGHT;
    end;
    rc := sqlite3_reset(pFirstBlock);
  end;
  if rc <> SQLITE_OK then Exit(rc);

  rc := fts3WriteSegment(p, pWriter^.iEnd, nil, 0);
  if rc <> SQLITE_OK then Exit(rc);

  pWriter^.iAbsLevel := iAbsLevel;
  pWriter^.nLeafEst := nLeafEst;
  pWriter^.iIdx := iIdx;
  for i := 0 to FTS_MAX_APPENDABLE_HEIGHT-1 do
    pWriter^.aNodeWriter[i].iBlock := pWriter^.iStart + i*pWriter^.nLeafEst;
  Result := SQLITE_OK;
end;

{ fts3_write.c:4542..4559 — fts3RemoveSegdirEntry. }
function fts3RemoveSegdirEntry(p: PFts3Table; iAbsLevel: sqlite3_int64;
  iIdx: cint): cint;
var
  rc: cint;
  pDelete: PVdbe;
begin
  rc := fts3SqlStmt(p, SQL_DELETE_SEGDIR_ENTRY, @pDelete, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pDelete, 1, iAbsLevel);
    sqlite3_bind_int(pDelete, 2, iIdx);
    sqlite3_step(pDelete);
    rc := sqlite3_reset(pDelete);
  end;
  Result := rc;
end;

{ fts3_write.c:4566..4620 — fts3RepackSegdirLevel. }
function fts3RepackSegdirLevel(p: PFts3Table; iAbsLevel: sqlite3_int64): cint;
var
  rc, rc2, nIdx, nAlloc, i: cint;
  aIdx, aNew: Pcint;
  pSelect, pUpdate: PVdbe;
begin
  aIdx := nil; nIdx := 0; nAlloc := 0;
  rc := fts3SqlStmt(p, SQL_SELECT_INDEXES, @pSelect, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pSelect, 1, iAbsLevel);
    while SQLITE_ROW = sqlite3_step(pSelect) do begin
      if nIdx >= nAlloc then begin
        nAlloc := nAlloc + 16;
        aNew := Pcint(sqlite3_realloc64(aIdx, u64(nAlloc*SizeOf(cint))));
        if aNew = nil then begin rc := SQLITE_NOMEM; break; end;
        aIdx := aNew;
      end;
      Pcint(aIdx)[nIdx] := sqlite3_column_int(pSelect, 0);
      Inc(nIdx);
    end;
    rc2 := sqlite3_reset(pSelect);
    if rc = SQLITE_OK then rc := rc2;
  end;

  if rc = SQLITE_OK then rc := fts3SqlStmt(p, SQL_SHIFT_SEGDIR_ENTRY, @pUpdate, nil);
  if rc = SQLITE_OK then sqlite3_bind_int64(pUpdate, 2, iAbsLevel);

  Assert(p^.bIgnoreSavepoint = 0);
  p^.bIgnoreSavepoint := 1;
  i := 0;
  while (rc = SQLITE_OK) and (i < nIdx) do begin
    if Pcint(aIdx)[i] <> i then begin
      sqlite3_bind_int(pUpdate, 3, Pcint(aIdx)[i]);
      sqlite3_bind_int(pUpdate, 1, i);
      sqlite3_step(pUpdate);
      rc := sqlite3_reset(pUpdate);
    end;
    Inc(i);
  end;
  p^.bIgnoreSavepoint := 0;
  sqlite3_free(aIdx);
  Result := rc;
end;

{ fts3_write.c:4622..4631 — fts3StartNode. }
procedure fts3StartNode(pNode: PFtsBlob; iHeight: cint; iChild: sqlite3_int64);
begin
  pNode^.a[0] := Chr(iHeight);
  if iChild <> 0 then
    pNode^.n := 1 + sqlite3Fts3PutVarint(@pNode^.a[1], iChild)
  else
    pNode^.n := 1;
end;

{ fts3_write.c:4641..4688 — fts3TruncateNode. }
function fts3TruncateNode(const aNode: PChar; nNode: cint; pNew: PFtsBlob;
  const zTerm: PChar; nTerm: cint; piBlock: Psqlite3_int64): cint;
var
  reader: TNodeReader;
  prev: TFtsBlob;
  rc, bLeaf, res: cint;
begin
  prev.a := nil; prev.n := 0; prev.nAlloc := 0;
  rc := SQLITE_OK;
  if nNode < 1 then Exit(FTS_CORRUPT_VTAB);
  bLeaf := cint(Ord(aNode[0] = #0));
  blobGrowBuffer(pNew, nNode, @rc);
  if rc <> SQLITE_OK then Exit(rc);
  pNew^.n := 0;

  rc := nodeReaderInit(@reader, aNode, nNode);
  while (rc = SQLITE_OK) and (reader.aNode <> nil) do begin
    if pNew^.n = 0 then begin
      res := fts3TermCmp(reader.term.a, reader.term.n, zTerm, nTerm);
      if (res < 0) or ((bLeaf = 0) and (res = 0)) then begin
        rc := nodeReaderNext(@reader);
        continue;
      end;
      fts3StartNode(pNew, cint(Byte(aNode[0])), reader.iChild);
      piBlock^ := reader.iChild;
    end;
    rc := fts3AppendToNode(pNew, @prev, reader.term.a, reader.term.n,
            reader.aDoclist, reader.nDoclist);
    if rc <> SQLITE_OK then break;
    rc := nodeReaderNext(@reader);
  end;
  if pNew^.n = 0 then begin
    fts3StartNode(pNew, cint(Byte(aNode[0])), reader.iChild);
    piBlock^ := reader.iChild;
  end;
  nodeReaderRelease(@reader);
  sqlite3_free(prev.a);
  Result := rc;
end;

{ fts3_write.c:4699..4773 — fts3TruncateSegment. }
function fts3TruncateSegment(p: PFts3Table; iAbsLevel: sqlite3_int64; iIdx: cint;
  const zTerm: PChar; nTerm: cint): cint;
var
  rc, rc2, nRoot, nBlock: cint;
  root, block: TFtsBlob;
  iBlock, iNewStart, iOldStart: sqlite3_int64;
  pFetch, pDel, pChomp: PVdbe;
  aRoot, aBlock: PChar;
begin
  rc := SQLITE_OK;
  root.a := nil; root.n := 0; root.nAlloc := 0;
  block.a := nil; block.n := 0; block.nAlloc := 0;
  iBlock := 0; iNewStart := 0; iOldStart := 0;

  rc := fts3SqlStmt(p, SQL_SELECT_SEGDIR, @pFetch, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int64(pFetch, 1, iAbsLevel);
    sqlite3_bind_int(pFetch, 2, iIdx);
    if SQLITE_ROW = sqlite3_step(pFetch) then begin
      aRoot := sqlite3_column_blob(pFetch, 4);
      nRoot := sqlite3_column_bytes(pFetch, 4);
      iOldStart := sqlite3_column_int64(pFetch, 1);
      rc := fts3TruncateNode(aRoot, nRoot, @root, zTerm, nTerm, @iBlock);
    end;
    rc2 := sqlite3_reset(pFetch);
    if rc = SQLITE_OK then rc := rc2;
  end;

  while (rc = SQLITE_OK) and (iBlock <> 0) do begin
    aBlock := nil; nBlock := 0;
    iNewStart := iBlock;
    rc := sqlite3Fts3ReadBlock(p, iBlock, @aBlock, @nBlock, nil);
    if rc = SQLITE_OK then
      rc := fts3TruncateNode(aBlock, nBlock, @block, zTerm, nTerm, @iBlock);
    if rc = SQLITE_OK then rc := fts3WriteSegment(p, iNewStart, block.a, block.n);
    sqlite3_free(aBlock);
  end;

  if (rc = SQLITE_OK) and (iNewStart <> 0) then begin
    rc := fts3SqlStmt(p, SQL_DELETE_SEGMENTS_RANGE, @pDel, nil);
    if rc = SQLITE_OK then begin
      sqlite3_bind_int64(pDel, 1, iOldStart);
      sqlite3_bind_int64(pDel, 2, iNewStart-1);
      sqlite3_step(pDel);
      rc := sqlite3_reset(pDel);
    end;
  end;

  if rc = SQLITE_OK then begin
    rc := fts3SqlStmt(p, SQL_CHOMP_SEGDIR, @pChomp, nil);
    if rc = SQLITE_OK then begin
      sqlite3_bind_int64(pChomp, 1, iNewStart);
      sqlite3_bind_blob(pChomp, 2, root.a, root.n, SQLITE_STATIC);
      sqlite3_bind_int64(pChomp, 3, iAbsLevel);
      sqlite3_bind_int(pChomp, 4, iIdx);
      sqlite3_step(pChomp);
      rc := sqlite3_reset(pChomp);
      sqlite3_bind_null(pChomp, 2);
    end;
  end;
  sqlite3_free(root.a);
  sqlite3_free(block.a);
  Result := rc;
end;

{ fts3_write.c:4785..4831 — fts3IncrmergeChomp. }
function fts3IncrmergeChomp(p: PFts3Table; iAbsLevel: sqlite3_int64;
  pCsr: PFts3MultiSegReader; pnRem: Pcint): cint;
var
  i, j, nRem, rc: cint;
  pSeg: PFts3SegReader;
  zTerm: PChar;
  nTerm: cint;
begin
  nRem := 0;
  rc := SQLITE_OK;
  i := pCsr^.nSegment-1;
  while (i >= 0) and (rc = SQLITE_OK) do begin
    pSeg := nil;
    j := 0;
    while j < pCsr^.nSegment do begin
      pSeg := PPFts3SegReader(pCsr^.apSegment)[j];
      if pSeg^.iIdx = i then break;
      Inc(j);
    end;
    Assert((j < pCsr^.nSegment) and (pSeg^.iIdx = i));
    if pSeg^.aNode = nil then begin
      rc := fts3DeleteSegment(p, pSeg);
      if rc = SQLITE_OK then rc := fts3RemoveSegdirEntry(p, iAbsLevel, pSeg^.iIdx);
      pnRem^ := 0;
    end else begin
      zTerm := pSeg^.zTerm;
      nTerm := pSeg^.nTerm;
      rc := fts3TruncateSegment(p, iAbsLevel, pSeg^.iIdx, zTerm, nTerm);
      Inc(nRem);
    end;
    Dec(i);
  end;
  if (rc = SQLITE_OK) and (nRem <> pCsr^.nSegment) then
    rc := fts3RepackSegdirLevel(p, iAbsLevel);
  pnRem^ := nRem;
  Result := rc;
end;

{ fts3_write.c:4836..4850 — fts3IncrmergeHintStore. }
function fts3IncrmergeHintStore(p: PFts3Table; pHint: PFtsBlob): cint;
var
  pReplace: PVdbe;
  rc: cint;
begin
  rc := fts3SqlStmt(p, SQL_REPLACE_STAT, @pReplace, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int(pReplace, 1, FTS_STAT_INCRMERGEHINT);
    sqlite3_bind_blob(pReplace, 2, pHint^.a, pHint^.n, SQLITE_STATIC);
    sqlite3_step(pReplace);
    rc := sqlite3_reset(pReplace);
    sqlite3_bind_null(pReplace, 2);
  end;
  Result := rc;
end;

{ fts3_write.c:4860..4885 — fts3IncrmergeHintLoad. }
function fts3IncrmergeHintLoad(p: PFts3Table; pHint: PFtsBlob): cint;
var
  pSelect: PVdbe;
  rc, rc2, nHint: cint;
  aHint: PChar;
begin
  pHint^.n := 0;
  rc := fts3SqlStmt(p, SQL_SELECT_STAT, @pSelect, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int(pSelect, 1, FTS_STAT_INCRMERGEHINT);
    if SQLITE_ROW = sqlite3_step(pSelect) then begin
      aHint := sqlite3_column_blob(pSelect, 0);
      nHint := sqlite3_column_bytes(pSelect, 0);
      if aHint <> nil then begin
        blobGrowBuffer(pHint, nHint, @rc);
        if rc = SQLITE_OK then begin
          if pHint^.a <> nil then libc_memcpy(pHint^.a, aHint, NativeUInt(nHint));
          pHint^.n := nHint;
        end;
      end;
    end;
    rc2 := sqlite3_reset(pSelect);
    if rc = SQLITE_OK then rc := rc2;
  end;
  Result := rc;
end;

{ fts3_write.c:4896..4907 — fts3IncrmergeHintPush. }
procedure fts3IncrmergeHintPush(pHint: PFtsBlob; iAbsLevel: sqlite3_int64;
  nInput: cint; pRc: Pcint);
begin
  blobGrowBuffer(pHint, pHint^.n + 2*FTS3_VARINT_MAX, pRc);
  if pRc^ = SQLITE_OK then begin
    pHint^.n := pHint^.n + sqlite3Fts3PutVarint(@pHint^.a[pHint^.n], iAbsLevel);
    pHint^.n := pHint^.n + sqlite3Fts3PutVarint(@pHint^.a[pHint^.n], sqlite3_int64(nInput));
  end;
end;

{ fts3_write.c:4917..4935 — fts3IncrmergeHintPop. }
function fts3IncrmergeHintPop(pHint: PFtsBlob; piAbsLevel: Psqlite3_int64;
  pnInput: Pcint): cint;
var
  nHint, i: cint;
begin
  nHint := pHint^.n;
  i := pHint^.n-1;
  if (Byte(pHint^.a[i]) and $80) <> 0 then Exit(FTS_CORRUPT_VTAB);
  while (i > 0) and ((Byte(pHint^.a[i-1]) and $80) <> 0) do Dec(i);
  if i = 0 then Exit(FTS_CORRUPT_VTAB);
  Dec(i);
  while (i > 0) and ((Byte(pHint^.a[i-1]) and $80) <> 0) do Dec(i);
  pHint^.n := i;
  i := i + sqlite3Fts3GetVarint(@pHint^.a[i], piAbsLevel);
  i := i + fts3GetVarint32(@pHint^.a[i], pnInput);
  if i <> nHint then Exit(FTS_CORRUPT_VTAB);
  Result := SQLITE_OK;
end;

{ fts3_write.c:4947..5113 — sqlite3Fts3Incrmerge. }
function sqlite3Fts3Incrmerge(p: PFts3Table; nMerge, nMin: cint): cint;
var
  rc, nRem, nSeg, bUseHint, iIdx, bDirtyHint, bEmpty, bIgnore: cint;
  pCsr: PFts3MultiSegReader;
  pFilter: PFts3SegFilter;
  pWriter: PIncrmergeWriter;
  iAbsLevel: sqlite3_int64;
  hint: TFtsBlob;
  nAlloc: cint;
  nMod: sqlite3_int64;
  pFindLevel: PVdbe;
  nHint, nHintSeg: cint;
  iHintAbsLevel: sqlite3_int64;
  zKey: PChar;
  nKey: cint;
begin
  nRem := nMerge;
  nSeg := 0;
  iAbsLevel := 0;
  bDirtyHint := 0;
  hint.a := nil; hint.n := 0; hint.nAlloc := 0;

  nAlloc := SizeOf(TFts3MultiSegReader) + SizeOf(TFts3SegFilter)
              + SizeOf(TIncrmergeWriter);
  pWriter := PIncrmergeWriter(sqlite3_malloc64(u64(nAlloc)));
  if pWriter = nil then Exit(SQLITE_NOMEM);
  pFilter := PFts3SegFilter(PtrUInt(pWriter) + SizeOf(TIncrmergeWriter));
  pCsr := PFts3MultiSegReader(PtrUInt(pFilter) + SizeOf(TFts3SegFilter));

  rc := fts3IncrmergeHintLoad(p, @hint);
  while (rc = SQLITE_OK) and (nRem > 0) do begin
    nMod := FTS3_SEGDIR_MAXLEVEL * sqlite3_int64(p^.nIndex);
    bUseHint := 0;
    iIdx := 0;

    rc := fts3SqlStmt(p, SQL_FIND_MERGE_LEVEL, @pFindLevel, nil);
    sqlite3_bind_int(pFindLevel, 1, cint(Fts3_MAX(2, nMin)));
    if sqlite3_step(pFindLevel) = SQLITE_ROW then begin
      iAbsLevel := sqlite3_column_int64(pFindLevel, 0);
      nSeg := sqlite3_column_int(pFindLevel, 1);
      Assert(nSeg >= 2);
    end else
      nSeg := -1;
    rc := sqlite3_reset(pFindLevel);

    if (rc = SQLITE_OK) and (hint.n <> 0) then begin
      nHint := hint.n;
      iHintAbsLevel := 0;
      nHintSeg := 0;
      rc := fts3IncrmergeHintPop(@hint, @iHintAbsLevel, @nHintSeg);
      if (nSeg < 0) or ((iAbsLevel mod nMod) >= (iHintAbsLevel mod nMod)) then begin
        iAbsLevel := iHintAbsLevel;
        nSeg := cint(Fts3_MIN(Fts3_MAX(nMin, nSeg), nHintSeg));
        bUseHint := 1;
        bDirtyHint := 1;
      end else
        hint.n := nHint;
    end;

    if nSeg <= 0 then break;
    Assert(nMod <= $7FFFFFFF);
    if (iAbsLevel < 0) or (iAbsLevel > (nMod shl 32)) then begin
      rc := FTS_CORRUPT_VTAB;
      break;
    end;

    libc_memset(pWriter, 0, NativeUInt(nAlloc));
    pFilter^.flags := FTS3_SEGMENT_REQUIRE_POS;

    if rc = SQLITE_OK then begin
      rc := fts3IncrmergeOutputIdx(p, iAbsLevel, @iIdx);
      if (iIdx = 0) or ((bUseHint <> 0) and (iIdx = 1)) then begin
        bIgnore := 0;
        rc := fts3SegmentIsMaxLevel(p, iAbsLevel+1, @bIgnore);
        if bIgnore <> 0 then
          pFilter^.flags := pFilter^.flags or FTS3_SEGMENT_IGNORE_EMPTY;
      end;
    end;

    if rc = SQLITE_OK then rc := fts3IncrmergeCsr(p, iAbsLevel, nSeg, pCsr);
    if (rc = SQLITE_OK) and (pCsr^.nSegment = nSeg) then begin
      rc := sqlite3Fts3SegReaderStart(p, pCsr, pFilter);
      if rc = SQLITE_OK then begin
        bEmpty := 0;
        rc := sqlite3Fts3SegReaderStep(p, pCsr);
        if rc = SQLITE_OK then bEmpty := 1
        else if rc <> SQLITE_ROW then begin
          sqlite3Fts3SegReaderFinish(pCsr);
          break;
        end;
        if (bUseHint <> 0) and (iIdx > 0) then begin
          zKey := pCsr^.zTerm;
          nKey := pCsr^.nTerm;
          rc := fts3IncrmergeLoad(p, iAbsLevel, iIdx-1, zKey, nKey, pWriter);
        end else
          rc := fts3IncrmergeWriter(p, iAbsLevel, iIdx, pCsr, pWriter);

        if (rc = SQLITE_OK) and (pWriter^.nLeafEst <> 0) then begin
          if bEmpty = 0 then begin
            repeat
              rc := fts3IncrmergeAppend(p, pWriter, pCsr);
              if rc = SQLITE_OK then rc := sqlite3Fts3SegReaderStep(p, pCsr);
              if (pWriter^.nWork >= nRem) and (rc = SQLITE_ROW) then rc := SQLITE_OK;
            until rc <> SQLITE_ROW;
          end;
          if rc = SQLITE_OK then begin
            nRem := nRem - cint(1 + pWriter^.nWork);
            rc := fts3IncrmergeChomp(p, iAbsLevel, pCsr, @nSeg);
            if nSeg <> 0 then begin
              bDirtyHint := 1;
              fts3IncrmergeHintPush(@hint, iAbsLevel, nSeg, @rc);
            end;
          end;
        end;

        if nSeg <> 0 then pWriter^.nLeafData := pWriter^.nLeafData * -1;
        fts3IncrmergeRelease(p, pWriter, @rc);
        if (nSeg = 0) and (pWriter^.bNoLeafData = 0) then
          fts3PromoteSegments(p, iAbsLevel+1, pWriter^.nLeafData);
      end;
    end;
    sqlite3Fts3SegReaderFinish(pCsr);
  end;

  if (bDirtyHint <> 0) and (rc = SQLITE_OK) then
    rc := fts3IncrmergeHintStore(p, @hint);

  sqlite3_free(pWriter);
  sqlite3_free(hint.a);
  Result := rc;
end;

{ fts3_write.c:5123..5129 — fts3Getint. }
function fts3Getint(pz: PPChar): cint;
var
  z: PChar;
  i: cint;
begin
  z := pz^;
  i := 0;
  while (z^ >= '0') and (z^ <= '9') and (i < 214748363) do begin
    i := 10*i + (Ord(z^) - Ord('0'));
    Inc(z);
  end;
  pz^ := z;
  Result := i;
end;

{ fts3_write.c:5140..5173 — fts3DoIncrmerge. }
function fts3DoIncrmerge(p: PFts3Table; const zParam: PChar): cint;
var
  rc, nMin, nMerge: cint;
  z: PChar;
begin
  nMin := MergeCount(p) div 2;
  nMerge := 0;
  z := zParam;
  nMerge := fts3Getint(@z);
  if (z[0] = ',') and (z[1] <> #0) then begin
    Inc(z);
    nMin := fts3Getint(@z);
  end;
  if (z[0] <> #0) or (nMin < 2) then
    rc := SQLITE_ERROR
  else begin
    rc := SQLITE_OK;
    if p^.bHasStat = 0 then begin
      Assert(p^.bFts4 = 0);
      sqlite3Fts3CreateStatTable(@rc, p);
    end;
    if rc = SQLITE_OK then rc := sqlite3Fts3Incrmerge(p, nMerge, nMin);
    sqlite3Fts3SegmentsClose(p);
  end;
  Result := rc;
end;

{ fts3_write.c:5183..5205 — fts3DoAutoincrmerge. }
function fts3DoAutoincrmerge(p: PFts3Table; zParam: PChar): cint;
var
  rc: cint;
  pStmt: PVdbe;
  zP: PChar;
begin
  rc := SQLITE_OK;
  zP := zParam;
  p^.nAutoincrmerge := fts3Getint(@zP);
  if (p^.nAutoincrmerge = 1) or (p^.nAutoincrmerge > MergeCount(p)) then
    p^.nAutoincrmerge := 8;
  if p^.bHasStat = 0 then begin
    Assert(p^.bFts4 = 0);
    sqlite3Fts3CreateStatTable(@rc, p);
    if rc <> 0 then Exit(rc);
  end;
  rc := fts3SqlStmt(p, SQL_REPLACE_STAT, @pStmt, nil);
  if rc <> 0 then Exit(rc);
  sqlite3_bind_int(pStmt, 1, FTS_STAT_AUTOINCRMERGE);
  sqlite3_bind_int(pStmt, 2, p^.nAutoincrmerge);
  sqlite3_step(pStmt);
  rc := sqlite3_reset(pStmt);
  Result := rc;
end;

{ fts3_write.c:5211..5230 — fts3ChecksumEntry. }
function fts3ChecksumEntry(const zTerm: PChar; nTerm, iLangid, iIndex: cint;
  iDocid: sqlite3_int64; iCol, iPos: cint): u64;
var
  i: cint;
  ret: u64;
begin
  ret := u64(iDocid);
  ret := ret + (ret shl 3) + u64(iLangid);
  ret := ret + (ret shl 3) + u64(iIndex);
  ret := ret + (ret shl 3) + u64(iCol);
  ret := ret + (ret shl 3) + u64(iPos);
  for i := 0 to nTerm - 1 do
    ret := ret + (ret shl 3) + u64(ShortInt(zTerm[i]));
  Result := ret;
end;

{ fts3_write.c:5241..5308 — fts3ChecksumIndex. }
function fts3ChecksumIndex(p: PFts3Table; iLangid, iIndex: cint; pRc: Pcint): u64;
var
  filter: TFts3SegFilter;
  csr: TFts3MultiSegReader;
  rc: cint;
  cksum: u64;
  pCsr, pEnd: PChar;
  iDocid, iCol: sqlite3_int64;
  iPos, iVal: u64;
begin
  cksum := 0;
  if pRc^ <> 0 then Exit(0);
  libc_memset(@filter, 0, SizeOf(filter));
  libc_memset(@csr, 0, SizeOf(csr));
  filter.flags := FTS3_SEGMENT_REQUIRE_POS or FTS3_SEGMENT_IGNORE_EMPTY;
  filter.flags := filter.flags or FTS3_SEGMENT_SCAN;

  rc := sqlite3Fts3SegReaderCursor(p, iLangid, iIndex, FTS3_SEGCURSOR_ALL,
          nil, 0, 0, 1, @csr);
  if rc = SQLITE_OK then rc := sqlite3Fts3SegReaderStart(p, @csr, @filter);

  if rc = SQLITE_OK then begin
    rc := sqlite3Fts3SegReaderStep(p, @csr);
    while rc = SQLITE_ROW do begin
      pCsr := csr.aDoclist;
      pEnd := @pCsr[csr.nDoclist];
      iDocid := 0; iCol := 0; iPos := 0;
      pCsr := pCsr + sqlite3Fts3GetVarint(pCsr, @iDocid);
      while PtrUInt(pCsr) < PtrUInt(pEnd) do begin
        iVal := 0;
        pCsr := pCsr + sqlite3Fts3GetVarintU(pCsr, @iVal);
        if PtrUInt(pCsr) < PtrUInt(pEnd) then begin
          if (iVal = 0) or (iVal = 1) then begin
            iCol := 0; iPos := 0;
            if iVal <> 0 then
              pCsr := pCsr + sqlite3Fts3GetVarint(pCsr, @iCol)
            else begin
              pCsr := pCsr + sqlite3Fts3GetVarintU(pCsr, @iVal);
              if p^.bDescIdx <> 0 then
                iDocid := sqlite3_int64(u64(iDocid) - iVal)
              else
                iDocid := sqlite3_int64(u64(iDocid) + iVal);
            end;
          end else begin
            iPos := iPos + (iVal - 2);
            cksum := cksum xor fts3ChecksumEntry(csr.zTerm, csr.nTerm, iLangid,
                iIndex, iDocid, cint(iCol), cint(iPos));
          end;
        end;
      end;
      rc := sqlite3Fts3SegReaderStep(p, @csr);
    end;
  end;
  sqlite3Fts3SegReaderFinish(@csr);
  pRc^ := rc;
  Result := cksum;
end;

{ fts3_write.c:5319..5404 — sqlite3Fts3IntegrityCheck. }
function sqlite3Fts3IntegrityCheck(p: PFts3Table; pbOk: Pcint): cint;
var
  rc, rc2, i, iLangid, iCol, iLang, nToken, iDum1, iDum2, iPos: cint;
  cksum1, cksum2: u64;
  pAllLangid, pStmt: PVdbe;
  pModule: Psqlite3_tokenizer_module;
  zSql, zText, zToken: PChar;
  iDocid: sqlite3_int64;
  pT: Psqlite3_tokenizer_cursor;
begin
  rc := SQLITE_OK;
  cksum1 := 0; cksum2 := 0;
  pAllLangid := nil;

  rc := fts3SqlStmt(p, SQL_SELECT_ALL_LANGID, @pAllLangid, nil);
  if rc = SQLITE_OK then begin
    sqlite3_bind_int(pAllLangid, 1, p^.iPrevLangid);
    sqlite3_bind_int(pAllLangid, 2, p^.nIndex);
    while (rc = SQLITE_OK) and (sqlite3_step(pAllLangid) = SQLITE_ROW) do begin
      iLangid := sqlite3_column_int(pAllLangid, 0);
      for i := 0 to p^.nIndex - 1 do
        cksum1 := cksum1 xor fts3ChecksumIndex(p, iLangid, i, @rc);
    end;
    rc2 := sqlite3_reset(pAllLangid);
    if rc = SQLITE_OK then rc := rc2;
  end;

  if rc = SQLITE_OK then begin
    pModule := p^.pTokenizer^.pModule;
    pStmt := nil;
    zSql := PChar(sqlite3PfMprintf(PAnsiChar('SELECT %s'), [p^.zReadExprlist]));
    if zSql = nil then
      rc := SQLITE_NOMEM
    else begin
      rc := sqlite3Fts3PrepareStmt(p, zSql, 0, 1, @pStmt);
      sqlite3_free(zSql);
    end;

    while (rc = SQLITE_OK) and (SQLITE_ROW = sqlite3_step(pStmt)) do begin
      iDocid := sqlite3_column_int64(pStmt, 0);
      iLang := langidFromSelect(p, pStmt);
      iCol := 0;
      while (rc = SQLITE_OK) and (iCol < p^.nColumn) do begin
        if PByte(p^.abNotindexed)[iCol] = 0 then begin
          zText := PChar(sqlite3_column_text(pStmt, iCol+1));
          pT := nil;
          rc := sqlite3Fts3OpenTokenizer(p^.pTokenizer, iLang, zText, -1, @pT);
          while rc = SQLITE_OK do begin
            nToken := 0; iDum1 := 0; iDum2 := 0; iPos := 0;
            rc := pModule^.xNext(pT, @zToken, @nToken, @iDum1, @iDum2, @iPos);
            if rc = SQLITE_OK then begin
              cksum2 := cksum2 xor fts3ChecksumEntry(zToken, nToken, iLang, 0,
                  iDocid, iCol, iPos);
              for i := 1 to p^.nIndex - 1 do begin
                if PFts3Index(p^.aIndex)[i].nPrefix <= nToken then
                  cksum2 := cksum2 xor fts3ChecksumEntry(zToken,
                      PFts3Index(p^.aIndex)[i].nPrefix, iLang, i, iDocid, iCol, iPos);
              end;
            end;
          end;
          if pT <> nil then pModule^.xClose(pT);
          if rc = SQLITE_DONE then rc := SQLITE_OK;
        end;
        Inc(iCol);
      end;
    end;
    sqlite3_finalize(pStmt);
  end;

  if rc = SQLITE_CORRUPT_VTAB then begin
    rc := SQLITE_OK;
    pbOk^ := 0;
  end else
    pbOk^ := cint(Ord((rc = SQLITE_OK) and (cksum1 = cksum2)));
  Result := rc;
end;

{ fts3_write.c:5437..5445 — fts3DoIntegrityCheck. }
function fts3DoIntegrityCheck(p: PFts3Table): cint;
var
  rc, bOk: cint;
begin
  bOk := 0;
  rc := sqlite3Fts3IntegrityCheck(p, @bOk);
  if (rc = SQLITE_OK) and (bOk = 0) then rc := FTS_CORRUPT_VTAB;
  Result := rc;
end;

{ fts3_write.c:5455..5497 — fts3SpecialInsert. }
function fts3SpecialInsert(p: PFts3Table; pVal: Psqlite3_value): cint;
var
  rc, nVal, v: cint;
  zVal: PChar;
begin
  rc := SQLITE_ERROR;
  zVal := PChar(sqlite3_value_text(pVal));
  nVal := sqlite3_value_bytes(pVal);
  if zVal = nil then
    Exit(SQLITE_NOMEM)
  else if (nVal = 8) and (sqlite3_strnicmp(zVal, 'optimize', 8) = 0) then
    rc := fts3DoOptimize(p, 0)
  else if (nVal = 7) and (sqlite3_strnicmp(zVal, 'rebuild', 7) = 0) then
    rc := fts3DoRebuild(p)
  else if (nVal = 15) and (sqlite3_strnicmp(zVal, 'integrity-check', 15) = 0) then
    rc := fts3DoIntegrityCheck(p)
  else if (nVal > 6) and (sqlite3_strnicmp(zVal, 'merge=', 6) = 0) then
    rc := fts3DoIncrmerge(p, @zVal[6])
  else if (nVal > 10) and (sqlite3_strnicmp(zVal, 'automerge=', 10) = 0) then
    rc := fts3DoAutoincrmerge(p, @zVal[10])
  else if (nVal = 5) and (sqlite3_strnicmp(zVal, 'flush', 5) = 0) then
    rc := sqlite3Fts3PendingTermsFlush(p)
{$IFDEF SQLITE_TEST}
  else begin
    if (nVal > 9) and (sqlite3_strnicmp(zVal, 'nodesize=', 9) = 0) then begin
      v := libc_atoi(@zVal[9]);
      if (v >= 24) and (v <= p^.nPgsz-35) then p^.nNodeSize := v;
      rc := SQLITE_OK;
    end else if (nVal > 11) and (sqlite3_strnicmp(zVal, 'maxpending=', 11) = 0) then
    begin
      v := libc_atoi(@zVal[11]);
      if (v >= 64) and (v <= FTS3_MAX_PENDING_DATA) then p^.nMaxPendingData := v;
      rc := SQLITE_OK;
    end else if (nVal > 21)
      and (sqlite3_strnicmp(zVal, 'test-no-incr-doclist=', 21) = 0) then begin
      p^.bNoIncrDoclist := libc_atoi(@zVal[21]);
      rc := SQLITE_OK;
    end else if (nVal > 11) and (sqlite3_strnicmp(zVal, 'mergecount=', 11) = 0) then
    begin
      v := libc_atoi(@zVal[11]);
      if (v >= 4) and (v <= FTS3_MERGE_COUNT) and ((v and 1) = 0) then
        p^.nMergeCount := v;
      rc := SQLITE_OK;
    end;
  end
{$ENDIF}
  ;
  Result := rc;
end;

{ ===================================================================== }
{ Deferred-token machinery (fts3_write.c:5504..5638).                    }
{ SQLITE_DISABLE_FTS4_DEFERRED is NOT defined in the oracle build.        }
{ ===================================================================== }

{ fts3_write.c:5504..5510 — sqlite3Fts3FreeDeferredDoclists. }
procedure sqlite3Fts3FreeDeferredDoclists(pCsr: PFts3Cursor);
var
  pDef: PFts3DeferredTokenR;
begin
  pDef := pCsr^.pDeferred;
  while pDef <> nil do begin
    fts3PendingListDelete(pDef^.pList);
    pDef^.pList := nil;
    pDef := pDef^.pNext;
  end;
end;

{ fts3_write.c:5516..5525 — sqlite3Fts3FreeDeferredTokens. }
procedure sqlite3Fts3FreeDeferredTokens(pCsr: PFts3Cursor);
var
  pDef, pNext: PFts3DeferredTokenR;
begin
  pDef := pCsr^.pDeferred;
  while pDef <> nil do begin
    pNext := pDef^.pNext;
    fts3PendingListDelete(pDef^.pList);
    sqlite3_free(pDef);
    pDef := pNext;
  end;
  pCsr^.pDeferred := nil;
end;

{ fts3_write.c:5535..5586 — sqlite3Fts3CacheDeferredDoclists. }
function sqlite3Fts3CacheDeferredDoclists(pCsr: PFts3Cursor): cint;
var
  rc, i, nToken, iDum1, iDum2, iPos: cint;
  iDocid: sqlite3_int64;
  pDef: PFts3DeferredTokenR;
  p: PFts3Table;
  pT: Psqlite3_tokenizer;
  pModule: Psqlite3_tokenizer_module;
  zText, zToken: PChar;
  pTC: Psqlite3_tokenizer_cursor;
  pPT: PFts3PhraseToken;
begin
  rc := SQLITE_OK;
  if pCsr^.pDeferred <> nil then begin
    p := PFts3Table(pCsr^.base.pVtab);
    pT := p^.pTokenizer;
    pModule := pT^.pModule;
    Assert(pCsr^.isRequireSeek = 0);
    iDocid := sqlite3_column_int64(pCsr^.pStmt, 0);

    i := 0;
    while (i < p^.nColumn) and (rc = SQLITE_OK) do begin
      if PByte(p^.abNotindexed)[i] = 0 then begin
        zText := PChar(sqlite3_column_text(pCsr^.pStmt, i+1));
        pTC := nil;
        rc := sqlite3Fts3OpenTokenizer(pT, pCsr^.iLangid, zText, -1, @pTC);
        while rc = SQLITE_OK do begin
          nToken := 0; iDum1 := 0; iDum2 := 0; iPos := 0;
          rc := pModule^.xNext(pTC, @zToken, @nToken, @iDum1, @iDum2, @iPos);
          pDef := pCsr^.pDeferred;
          while (pDef <> nil) and (rc = SQLITE_OK) do begin
            pPT := pDef^.pToken;
            if ((pDef^.iCol >= p^.nColumn) or (pDef^.iCol = i))
              and ((pPT^.bFirst = 0) or (iPos = 0))
              and ((pPT^.n = nToken) or ((pPT^.isPrefix <> 0) and (pPT^.n < nToken)))
              and (libc_memcmp(zToken, pPT^.z, NativeUInt(pPT^.n)) = 0) then
              fts3PendingListAppend(@pDef^.pList, iDocid, i, iPos, @rc);
            pDef := pDef^.pNext;
          end;
        end;
        if pTC <> nil then pModule^.xClose(pTC);
        if rc = SQLITE_DONE then rc := SQLITE_OK;
      end;
      Inc(i);
    end;

    pDef := pCsr^.pDeferred;
    while (pDef <> nil) and (rc = SQLITE_OK) do begin
      if pDef^.pList <> nil then
        rc := fts3PendingListAppendVarint(@pDef^.pList, 0);
      pDef := pDef^.pNext;
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:5588..5613 — sqlite3Fts3DeferredTokenList. }
function sqlite3Fts3DeferredTokenList(p: PFts3DeferredTokenR;
  ppData: PPChar; pnData: Pcint): cint;
var
  pRet: PChar;
  nSkip: cint;
  dummy: sqlite3_int64;
begin
  ppData^ := nil;
  pnData^ := 0;
  if p^.pList = nil then Exit(SQLITE_OK);
  pRet := PChar(sqlite3_malloc64(u64(p^.pList^.nData)));
  if pRet = nil then Exit(SQLITE_NOMEM);
  nSkip := sqlite3Fts3GetVarint(p^.pList^.aData, @dummy);
  pnData^ := cint(p^.pList^.nData) - nSkip;
  ppData^ := pRet;
  libc_memcpy(pRet, @p^.pList^.aData[nSkip], NativeUInt(pnData^));
  Result := SQLITE_OK;
end;

{ fts3_write.c:5618..5638 — sqlite3Fts3DeferToken. }
function sqlite3Fts3DeferToken(pCsr: PFts3Cursor; pToken: PFts3PhraseToken;
  iCol: cint): cint;
var
  pDeferred: PFts3DeferredTokenR;
begin
  pDeferred := PFts3DeferredTokenR(sqlite3_malloc64(u64(SizeOf(TFts3DeferredToken))));
  if pDeferred = nil then Exit(SQLITE_NOMEM);
  libc_memset(pDeferred, 0, SizeOf(TFts3DeferredToken));
  pDeferred^.pToken := pToken;
  pDeferred^.pNext := pCsr^.pDeferred;
  pDeferred^.iCol := iCol;
  pCsr^.pDeferred := pDeferred;
  Assert(pToken^.pDeferred = nil);
  pToken^.pDeferred := pDeferred;
  Result := SQLITE_OK;
end;

{ fts3_write.c:5646..5680 — fts3DeleteByRowid. }
function fts3DeleteByRowid(p: PFts3Table; pRowid: Psqlite3_value;
  pnChng: Pcint; aSzDel: Pcuint): cint;
var
  rc, bFound, isEmpty: cint;
begin
  rc := SQLITE_OK;
  bFound := 0;
  fts3DeleteTerms(@rc, p, pRowid, aSzDel, @bFound);
  if (bFound <> 0) and (rc = SQLITE_OK) then begin
    isEmpty := 0;
    rc := fts3IsEmpty(p, pRowid, @isEmpty);
    if rc = SQLITE_OK then begin
      if isEmpty <> 0 then begin
        rc := fts3DeleteAll(p, 1);
        pnChng^ := 0;
        libc_memset(aSzDel, 0, NativeUInt(SizeOf(cuint) * (p^.nColumn+1) * 2));
      end else begin
        pnChng^ := pnChng^ - 1;
        if p^.zContentTbl = nil then fts3SqlExec(@rc, p, SQL_DELETE_CONTENT, @pRowid);
        if p^.bHasDocsize <> 0 then fts3SqlExec(@rc, p, SQL_DELETE_DOCSIZE, @pRowid);
      end;
    end;
  end;
  Result := rc;
end;

{ fts3_write.c:5695..5832 — sqlite3Fts3UpdateMethod. }
function sqlite3Fts3UpdateMethod(pVtab: PSqlite3Vtab; nArg: cint;
  apVal: PPsqlite3_value; pRowid: Psqlite3_int64): cint;
var
  p: PFts3Table;
  rc, nChng, bInsertDone, iLangid: cint;
  aSzIns, aSzDel: Pcuint;
  pNewRowid: Psqlite3_value;
label update_out;
begin
  p := PFts3Table(pVtab);
  rc := SQLITE_OK;
  aSzIns := nil; aSzDel := nil; nChng := 0; bInsertDone := 0;
  Assert((p^.bHasStat = 0) or (p^.bHasStat = 1));
  Assert(p^.pSegments = nil);

  if (nArg > 1)
   and (sqlite3_value_type(PPsqlite3_value(apVal)[0]) = SQLITE_NULL)
   and (sqlite3_value_type(PPsqlite3_value(apVal)[p^.nColumn+2]) <> SQLITE_NULL) then
  begin
    rc := fts3SpecialInsert(p, PPsqlite3_value(apVal)[p^.nColumn+2]);
    goto update_out;
  end;

  if (nArg > 1)
   and (sqlite3_value_int(PPsqlite3_value(apVal)[2 + p^.nColumn + 2]) < 0) then begin
    rc := SQLITE_CONSTRAINT;
    goto update_out;
  end;

  aSzDel := Pcuint(sqlite3_malloc64(u64(SizeOf(cuint)*(sqlite3_int64(p^.nColumn)+1)*2)));
  if aSzDel = nil then begin
    rc := SQLITE_NOMEM;
    goto update_out;
  end;
  aSzIns := @Pcuint(aSzDel)[p^.nColumn+1];
  libc_memset(aSzDel, 0, NativeUInt(SizeOf(cuint)*(p^.nColumn+1)*2));

  rc := fts3Writelock(p);
  if rc <> SQLITE_OK then goto update_out;

  if (nArg > 1) and (p^.zContentTbl = nil) then begin
    pNewRowid := PPsqlite3_value(apVal)[3+p^.nColumn];
    if sqlite3_value_type(pNewRowid) = SQLITE_NULL then
      pNewRowid := PPsqlite3_value(apVal)[1];
    if (sqlite3_value_type(pNewRowid) <> SQLITE_NULL)
     and ((sqlite3_value_type(PPsqlite3_value(apVal)[0]) = SQLITE_NULL)
          or (sqlite3_value_int64(PPsqlite3_value(apVal)[0])
               <> sqlite3_value_int64(pNewRowid))) then begin
      if sqlite3_vtab_on_conflict(p^.db) = FTS3_SQLITE_REPLACE then
        rc := fts3DeleteByRowid(p, pNewRowid, @nChng, aSzDel)
      else begin
        rc := fts3InsertData(p, apVal, pRowid);
        bInsertDone := 1;
      end;
    end;
  end;
  if rc <> SQLITE_OK then goto update_out;

  if sqlite3_value_type(PPsqlite3_value(apVal)[0]) <> SQLITE_NULL then begin
    Assert(sqlite3_value_type(PPsqlite3_value(apVal)[0]) = SQLITE_INTEGER);
    rc := fts3DeleteByRowid(p, PPsqlite3_value(apVal)[0], @nChng, aSzDel);
  end;

  if (nArg > 1) and (rc = SQLITE_OK) then begin
    iLangid := sqlite3_value_int(PPsqlite3_value(apVal)[2 + p^.nColumn + 2]);
    if bInsertDone = 0 then begin
      rc := fts3InsertData(p, apVal, pRowid);
      if (rc = SQLITE_CONSTRAINT) and (p^.zContentTbl = nil) then
        rc := FTS_CORRUPT_VTAB;
    end;
    if rc = SQLITE_OK then rc := fts3PendingTermsDocid(p, 0, iLangid, pRowid^);
    if rc = SQLITE_OK then begin
      Assert(p^.iPrevDocid = pRowid^);
      rc := fts3InsertTerms(p, iLangid, apVal, aSzIns);
    end;
    if p^.bHasDocsize <> 0 then fts3InsertDocsize(@rc, p, aSzIns);
    Inc(nChng);
  end;

  if p^.bFts4 <> 0 then fts3UpdateDocTotals(@rc, p, aSzIns, aSzDel, nChng);

update_out:
  sqlite3_free(aSzDel);
  sqlite3Fts3SegmentsClose(p);
  Result := rc;
end;

{ fts3_write.c:5839..5854 — sqlite3Fts3Optimize. }
function sqlite3Fts3Optimize(p: PFts3Table): cint;
var
  rc, rc2: cint;
begin
  rc := sqlite3_exec(p^.db, PAnsiChar('SAVEPOINT fts3'), nil, nil, nil);
  if rc = SQLITE_OK then begin
    rc := fts3DoOptimize(p, 1);
    if (rc = SQLITE_OK) or (rc = SQLITE_DONE) then begin
      rc2 := sqlite3_exec(p^.db, PAnsiChar('RELEASE fts3'), nil, nil, nil);
      if rc2 <> SQLITE_OK then rc := rc2;
    end else begin
      sqlite3_exec(p^.db, PAnsiChar('ROLLBACK TO fts3'), nil, nil, nil);
      sqlite3_exec(p^.db, PAnsiChar('RELEASE fts3'), nil, nil, nil);
    end;
  end;
  sqlite3Fts3SegmentsClose(p);
  Result := rc;
end;

{ ===================================================================== }
{ CROSS-BOUNDARY STUB BODIES for 6.40.1.k (fts3.c).  These satisfy the    }
{ forward declarations above so .j links standalone.  TODO(6.40.1.k):     }
{ replace each with the faithful fts3.c port and delete the stub.         }
{ ===================================================================== }

function sqlite3Fts3SegReaderCursor(p: PFts3Table; iLangid, iIndex,
  iLevel: cint; const zTerm: PChar; nTerm, isPrefix, isScan: cint;
  pCsr: PFts3MultiSegReader): cint;
begin
  { TODO(6.40.1.k): fts3.c:3038 fts3SegReaderCursor — opens seg-readers over
    pending + on-disk segdir rows.  Returns ERROR until .k lands. }
  if (p = nil) or (iLangid = 0) or (iIndex = 0) or (iLevel = 0)
   or (zTerm = nil) or (nTerm = 0) or (isPrefix = 0) or (isScan = 0)
   or (pCsr = nil) then ;  { unused-param silence }
  Result := SQLITE_ERROR;
end;

procedure sqlite3Fts3DoclistPrev(bDescIdx: cint; aDoclist: PChar;
  nDoclist: cint; ppIter: PPChar; piDocid: Psqlite3_int64;
  pnList: Pcint; pbEof: PByte);
begin
  { TODO(6.40.1.k): fts3.c sqlite3Fts3DoclistPrev — reverse-iterate a doclist. }
  if (bDescIdx = 0) or (aDoclist = nil) or (nDoclist = 0) or (ppIter = nil)
   or (piDocid = nil) or (pnList = nil) then ;
  pbEof^ := 1;
end;

function sqlite3Fts3FirstFilter(iDelta: sqlite3_int64; pList: PChar;
  nList: cint; pOut: PChar): cint;
begin
  { TODO(6.40.1.k): fts3.c:2760 sqlite3Fts3FirstFilter — keep only position-0
    entries of a doclist (FTS3_SEGMENT_FIRST). }
  if (iDelta = 0) or (pList = nil) or (nList = 0) or (pOut = nil) then ;
  Result := 0;
end;

procedure sqlite3Fts3CreateStatTable(pRc: Pcint; p: PFts3Table);
begin
  { TODO(6.40.1.k): fts3.c:665 sqlite3Fts3CreateStatTable — CREATE the %_stat
    shadow table on demand and set p->bHasStat. }
  if p = nil then ;
  if pRc^ = SQLITE_OK then pRc^ := SQLITE_ERROR;
end;

{ ===================================================================== }
{ 6.40.1.g down-payment on 6.40.1.o — minimal sqlite3Fts3Init.           }
{ ===================================================================== }

type
  { fts3.c:305..309 — struct Fts3HashWrapper.  The inner `hash` is the FIRST
    field, so &wrapper == &wrapper.hash; the fts3_tokenizer SQL function is
    given &hash as user-data (C passes the same), while hashDestroy receives
    the identical pointer and reclaims the wrapper. }
  PFts3HashWrapper = ^TFts3HashWrapper;
  TFts3HashWrapper = record
    hash : TFts3Hash;   { Hash table }
    nRef : cint;        { Number of pointers to this object }
  end;

{ fts3.c:4068..4075 — hashDestroy.  nRef-guarded so it is safe to attach to
  more than one FuncDef sharing the same user-data (each FuncDef teardown
  calls it once; only the last frees).  TODO(6.40.1.o): when the fts3/fts4/
  fts3tokenize modules are registered, their sqlite3_create_module_v2
  destructors become the owners and this function-destructor wiring is
  removed in favour of the C nRef accounting at fts3.c:4174..4187. }
procedure hashDestroy(p: Pointer); cdecl;
var
  pHash: PFts3HashWrapper;
begin
  pHash := PFts3HashWrapper(p);
  Dec(pHash^.nRef);
  if pHash^.nRef <= 0 then begin
    sqlite3Fts3HashClear(@pHash^.hash);
    sqlite3_free(pHash);
  end;
end;

function sqlite3Fts3Init(db: PTsqlite3): cint;
var
  rc: cint;
  pHash: PFts3HashWrapper;
  pSimple, pPorter, pUnicode: Psqlite3_tokenizer_module;
begin
  rc := SQLITE_OK;
  pHash := nil;
  pSimple := nil; pPorter := nil; pUnicode := nil;

  sqlite3Fts3UnicodeTokenizer(@pUnicode);
  sqlite3Fts3SimpleTokenizerModule(@pSimple);
  sqlite3Fts3PorterTokenizerModule(@pPorter);

  { Allocate and initialise the hash-table used to store tokenizers. }
  pHash := PFts3HashWrapper(sqlite3_malloc(i32(SizeOf(TFts3HashWrapper))));
  if pHash = nil then
    rc := SQLITE_NOMEM
  else begin
    sqlite3Fts3HashInit(@pHash^.hash, FTS3_HASH_STRING, 1);
    pHash^.nRef := 0;
  end;

  { Load the built-in tokenizers into the hash table. }
  if rc = SQLITE_OK then begin
    if (sqlite3Fts3HashInsert(@pHash^.hash, PChar('simple'), 7, pSimple) <> nil)
    or (sqlite3Fts3HashInsert(@pHash^.hash, PChar('porter'), 7, pPorter) <> nil)
    or (sqlite3Fts3HashInsert(@pHash^.hash, PChar('unicode61'), 10, pUnicode) <> nil)
    then
      rc := SQLITE_NOMEM;
  end;

  { Install the fts3_tokenizer SQL function(s) and the fts3tokenize VTAB
    module (6.40.1.h).  Unlike C (fts3.c:4167) we DO NOT register the
    fts3/fts4 modules here (6.40.1.k/.o), so two of C's three module
    destructors (which would own the wrapper) do not yet exist.  To keep
    the wrapper's lifetime correct and per-connection while fts3/fts4 are
    absent, attach the nRef-guarded hashDestroy to the two fts3_tokenizer
    FuncDefs as stand-in owners (each FuncDef gets &hash == the wrapper
    pointer and calls hashDestroy once on db close), then add the
    fts3tokenize module via sqlite3Fts3InitTok as a real owner (matching
    fts3.c:4185..4187).  nRef = 2 (funcs) + 1 (fts3tokenize) = 3; only the
    last hashDestroy call frees.  TODO(6.40.1.o): drop the FuncDef-
    destructor stand-in once the fts3/fts4 module owners land. }
  if rc = SQLITE_OK then begin
    pHash^.nRef := 2;
    rc := sqlite3_create_function_v2(db, PAnsiChar('fts3_tokenizer'), 1,
            SQLITE_UTF8 or SQLITE_DIRECTONLY, @pHash^.hash,
            @fts3TokenizerFunc, nil, nil, @hashDestroy);
    if rc = SQLITE_OK then
      rc := sqlite3_create_function_v2(db, PAnsiChar('fts3_tokenizer'), 2,
              SQLITE_UTF8 or SQLITE_DIRECTONLY, @pHash^.hash,
              @fts3TokenizerFunc, nil, nil, @hashDestroy);
{$IFDEF SQLITE_TEST}
    { Under SQLITE_TEST also install fts3_tokenizer_test / _internal_test.
      These share the wrapper but carry no destructor (matching C, where the
      _test funcs are plain create_function), so nRef stays balanced. }
    if rc = SQLITE_OK then
      rc := sqlite3_create_function(db, PAnsiChar('fts3_tokenizer_test'), -1,
              SQLITE_UTF8 or SQLITE_DIRECTONLY, @pHash^.hash,
              @testFunc, nil, nil);
    if rc = SQLITE_OK then
      rc := sqlite3_create_function(db, PAnsiChar('fts3_tokenizer_internal_test'),
              0, SQLITE_UTF8 or SQLITE_DIRECTONLY, Pointer(db),
              @intTestFunc, nil, nil);
    { fts3.c:4156..4160 — under SQLITE_TEST also install the expression
      parser test interface (fts3_exprtest / fts3_exprtest_rebalance),
      sharing the same tokenizer hash as user-data (6.40.1.i). }
    if rc = SQLITE_OK then
      rc := sqlite3Fts3ExprInitTestInterface(db, @pHash^.hash);
{$ENDIF}
    { fts3.c:4185..4187 — register the fts3tokenize module as an nRef owner. }
    if rc = SQLITE_OK then begin
      Inc(pHash^.nRef);
      rc := sqlite3Fts3InitTok(db, @pHash^.hash, @hashDestroy);
    end;
  end else if pHash <> nil then begin
    { Allocation/insert failed before any FuncDef adopted the wrapper. }
    sqlite3Fts3HashClear(@pHash^.hash);
    sqlite3_free(pHash);
  end;

  Result := rc;
end;

end.
