{$I passqlite3.inc}
unit passqlite3parser;
{
  Phase 7.1 — SQL tokenizer + statement-complete helper.

  Sources ported:
    sqlite3/src/tokenize.c  (899 lines)  — sqlite3GetToken, sqlite3RunParser
    sqlite3/src/complete.c  (290 lines)  — sqlite3_complete
  Generated data inlined:
    sqlite3/parse.h          (TK_* token constants, SQLite 3.53.0)
    sqlite3/keywordhash.h    (keyword perfect-hash tables)

  sqlite3RunParser is a stub — the LALR(1) Lemon parser (Phase 7.2) is
  not yet available.  Every other function in this unit is complete.
}

interface

uses
  passqlite3types,
  passqlite3util;

{ =========================================================================== }
{ TK_* token constants  (from sqlite3/parse.h, SQLite 3.53.0)                }
{ =========================================================================== }

const
  TK_SEMI          = 1;
  TK_EXPLAIN       = 2;
  TK_QUERY         = 3;
  TK_PLAN          = 4;
  TK_BEGIN         = 5;
  TK_TRANSACTION   = 6;
  TK_DEFERRED      = 7;
  TK_IMMEDIATE     = 8;
  TK_EXCLUSIVE     = 9;
  TK_COMMIT        = 10;
  TK_END           = 11;
  TK_ROLLBACK      = 12;
  TK_SAVEPOINT     = 13;
  TK_RELEASE       = 14;
  TK_TO            = 15;
  TK_TABLE         = 16;
  TK_CREATE        = 17;
  TK_IF            = 18;
  TK_NOT           = 19;
  TK_EXISTS        = 20;
  TK_TEMP          = 21;
  TK_LP            = 22;
  TK_RP            = 23;
  TK_AS            = 24;
  TK_COMMA         = 25;
  TK_WITHOUT       = 26;
  TK_ABORT         = 27;
  TK_ACTION        = 28;
  TK_AFTER         = 29;
  TK_ANALYZE       = 30;
  TK_ASC           = 31;
  TK_ATTACH        = 32;
  TK_BEFORE        = 33;
  TK_BY            = 34;
  TK_CASCADE       = 35;
  TK_CAST          = 36;
  TK_CONFLICT      = 37;
  TK_DATABASE      = 38;
  TK_DESC          = 39;
  TK_DETACH        = 40;
  TK_EACH          = 41;
  TK_FAIL          = 42;
  TK_OR            = 43;
  TK_AND           = 44;
  TK_IS            = 45;
  TK_ISNOT         = 46;
  TK_MATCH         = 47;
  TK_LIKE_KW       = 48;
  TK_BETWEEN       = 49;
  TK_IN            = 50;
  TK_ISNULL        = 51;
  TK_NOTNULL       = 52;
  TK_NE            = 53;
  TK_EQ            = 54;
  TK_GT            = 55;
  TK_LE            = 56;
  TK_LT            = 57;
  TK_GE            = 58;
  TK_ESCAPE        = 59;
  TK_ID            = 60;
  TK_COLUMNKW      = 61;
  TK_DO            = 62;
  TK_FOR           = 63;
  TK_IGNORE        = 64;
  TK_INITIALLY     = 65;
  TK_INSTEAD       = 66;
  TK_NO            = 67;
  TK_KEY           = 68;
  TK_OF            = 69;
  TK_OFFSET        = 70;
  TK_PRAGMA        = 71;
  TK_RAISE         = 72;
  TK_RECURSIVE     = 73;
  TK_REPLACE       = 74;
  TK_RESTRICT      = 75;
  TK_ROW           = 76;
  TK_ROWS          = 77;
  TK_TRIGGER       = 78;
  TK_VACUUM        = 79;
  TK_VIEW          = 80;
  TK_VIRTUAL       = 81;
  TK_WITH          = 82;
  TK_NULLS         = 83;
  TK_FIRST         = 84;
  TK_LAST          = 85;
  TK_CURRENT       = 86;
  TK_FOLLOWING     = 87;
  TK_PARTITION     = 88;
  TK_PRECEDING     = 89;
  TK_RANGE         = 90;
  TK_UNBOUNDED     = 91;
  TK_EXCLUDE       = 92;
  TK_GROUPS        = 93;
  TK_OTHERS        = 94;
  TK_TIES          = 95;
  TK_GENERATED     = 96;
  TK_ALWAYS        = 97;
  TK_MATERIALIZED  = 98;
  TK_REINDEX       = 99;
  TK_RENAME        = 100;
  TK_CTIME_KW      = 101;
  TK_ANY           = 102;
  TK_BITAND        = 103;
  TK_BITOR         = 104;
  TK_LSHIFT        = 105;
  TK_RSHIFT        = 106;
  TK_PLUS          = 107;
  TK_MINUS         = 108;
  TK_STAR          = 109;
  TK_SLASH         = 110;
  TK_REM           = 111;
  TK_CONCAT        = 112;
  TK_PTR           = 113;
  TK_COLLATE       = 114;
  TK_BITNOT        = 115;
  TK_ON            = 116;
  TK_INDEXED       = 117;
  TK_STRING        = 118;
  TK_JOIN_KW       = 119;
  TK_CONSTRAINT    = 120;
  TK_DEFAULT       = 121;
  TK_NULL          = 122;
  TK_PRIMARY       = 123;
  TK_UNIQUE        = 124;
  TK_CHECK         = 125;
  TK_REFERENCES    = 126;
  TK_AUTOINCR      = 127;
  TK_INSERT        = 128;
  TK_DELETE        = 129;
  TK_UPDATE        = 130;
  TK_SET           = 131;
  TK_DEFERRABLE    = 132;
  TK_FOREIGN       = 133;
  TK_DROP          = 134;
  TK_UNION         = 135;
  TK_ALL           = 136;
  TK_EXCEPT        = 137;
  TK_INTERSECT     = 138;
  TK_SELECT        = 139;
  TK_VALUES        = 140;
  TK_DISTINCT      = 141;
  TK_DOT           = 142;
  TK_FROM          = 143;
  TK_JOIN          = 144;
  TK_USING         = 145;
  TK_ORDER         = 146;
  TK_GROUP         = 147;
  TK_HAVING        = 148;
  TK_LIMIT         = 149;
  TK_WHERE         = 150;
  TK_RETURNING     = 151;
  TK_INTO          = 152;
  TK_NOTHING       = 153;
  TK_FLOAT         = 154;
  TK_BLOB          = 155;
  TK_INTEGER       = 156;
  TK_VARIABLE      = 157;
  TK_CASE          = 158;
  TK_WHEN          = 159;
  TK_THEN          = 160;
  TK_ELSE          = 161;
  TK_INDEX         = 162;
  TK_ALTER         = 163;
  TK_ADD           = 164;
  TK_WINDOW        = 165;
  TK_OVER          = 166;
  TK_FILTER        = 167;
  TK_COLUMN        = 168;
  TK_AGG_FUNCTION  = 169;
  TK_AGG_COLUMN    = 170;
  TK_TRUEFALSE     = 171;
  TK_FUNCTION      = 172;
  TK_UPLUS         = 173;
  TK_UMINUS        = 174;
  TK_TRUTH         = 175;
  TK_REGISTER      = 176;
  TK_VECTOR        = 177;
  TK_SELECT_COLUMN = 178;
  TK_IF_NULL_ROW   = 179;
  TK_ASTERISK      = 180;
  TK_SPAN          = 181;
  TK_ERROR         = 182;
  TK_QNUMBER       = 183;
  TK_SPACE         = 184;
  TK_COMMENT       = 185;
  TK_ILLEGAL       = 186;

  SQLITE_N_KEYWORD = 147;

{ =========================================================================== }
{ Public API                                                                  }
{ =========================================================================== }

{ Return the byte length of the next SQL token starting at z[0].
  Store the token-type code in tokenType^.  Returns 0 for NUL. }
function  sqlite3GetToken(z: PByte; tokenType: Pi32): i64;

{ Return 1 if c is a valid identifier character, 0 otherwise. }
function  sqlite3IsIdChar(c: u8): i32;

{ Look up identifier z[0..n-1] in the keyword table.
  Returns TK_ID if not a keyword, otherwise the TK_* code. }
function  sqlite3KeywordCode(z: PByte; n: i32): i32;

{ Keyword enumeration API (sqlite3.h public API). }
function  sqlite3_keyword_name(idx: i32; out pzName: PAnsiChar; out pnName: i32): i32;
function  sqlite3_keyword_count: i32;
function  sqlite3_keyword_check(zName: PAnsiChar; nName: i32): i32;

{ Run the LALR(1) parser on zSql.  Phase 7.1 stub — returns SQLITE_ERROR.
  Full implementation requires the Lemon-generated parse.c (Phase 7.2). }
function  sqlite3RunParser(pParse: Pointer; zSql: PAnsiChar): i32;

{ Return 1 if zSql ends with a complete SQL statement (ends at a semicolon
  that is not inside a string or comment), 0 otherwise. }
function  sqlite3_complete(zSql: PAnsiChar): i32;

{ =========================================================================== }

implementation

{ =========================================================================== }
{ Character-class table for the tokenizer switch  (tokenize.c lines 29–100)  }
{ =========================================================================== }

const
  CC_X        = 0;   { 'x' / 'X' — start of BLOB literal }
  CC_KYWD0    = 1;   { first letter of a keyword }
  CC_KYWD     = 2;   { alphabetic or '_', usable in a keyword }
  CC_DIGIT    = 3;   { digit }
  CC_DOLLAR   = 4;   { '$' }
  CC_VARALPHA = 5;   { '@', '#', ':' — alphabetic SQL variables }
  CC_VARNUM   = 6;   { '?' — numeric SQL variables }
  CC_SPACE    = 7;   { whitespace }
  CC_QUOTE    = 8;   { '"', '''', '`' }
  CC_QUOTE2   = 9;   { '[' }
  CC_PIPE     = 10;  { '|' }
  CC_MINUS    = 11;  { '-' }
  CC_LT       = 12;  { '<' }
  CC_GT       = 13;  { '>' }
  CC_EQ       = 14;  { '=' }
  CC_BANG     = 15;  { '!' }
  CC_SLASH    = 16;  { '/' }
  CC_LP       = 17;  { '(' }
  CC_RP       = 18;  { ')' }
  CC_SEMI     = 19;  { ';' }
  CC_PLUS     = 20;  { '+' }
  CC_STAR     = 21;  { '*' }
  CC_PERCENT  = 22;  { '%' }
  CC_COMMA    = 23;  { ',' }
  CC_AND      = 24;  { '&' }
  CC_TILDA    = 25;  { '~' }
  CC_DOT      = 26;  { '.' }
  CC_ID       = 27;  { unicode bytes usable in identifiers }
  CC_ILLEGAL  = 28;  { illegal character }
  CC_NUL      = 29;  { 0x00 }
  CC_BOM      = 30;  { 0xEF — first byte of UTF-8 BOM }

{ Per-byte character class (ASCII, 256 entries). }
const aiClass: array[0..255] of u8 = (
{ 0x } 29,28,28,28,28,28,28,28,28, 7, 7,28, 7, 7,28,28,
{ 1x } 28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,
{ 2x }  7,15, 8, 5, 4,22,24, 8,17,18,21,20,23,11,26,16,
{ 3x }  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 5,19,12,14,13, 6,
{ 4x }  5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
{ 5x }  1, 1, 1, 1, 1, 1, 1, 1, 0, 2, 2, 9,28,28,28, 2,
{ 6x }  8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
{ 7x }  1, 1, 1, 1, 1, 1, 1, 1, 0, 2, 2,28,10,28,25,28,
{ 8x } 27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,
{ 9x } 27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,
{ Ax } 27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,
{ Bx } 27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,
{ Cx } 27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,
{ Dx } 27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,
{ Ex } 27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,30,
{ Fx } 27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27
);

{ =========================================================================== }
{ Keyword hash tables  (from sqlite3/keywordhash.h, auto-generated)           }
{ =========================================================================== }

const
  zKWText: array[0..665] of AnsiChar = (
    'R','E','I','N','D','E','X','E','D','E','S','C','A','P','E','A','C','H',
    'E','C','K','E','Y','B','E','F','O','R','E','I','G','N','O','R','E','G',
    'E','X','P','L','A','I','N','S','T','E','A','D','D','A','T','A','B','A',
    'S','E','L','E','C','T','A','B','L','E','F','T','H','E','N','D','E','F',
    'E','R','R','A','B','L','E','L','S','E','X','C','L','U','D','E','L','E',
    'T','E','M','P','O','R','A','R','Y','I','S','N','U','L','L','S','A','V',
    'E','P','O','I','N','T','E','R','S','E','C','T','I','E','S','N','O','T',
    'N','U','L','L','I','K','E','X','C','E','P','T','R','A','N','S','A','C',
    'T','I','O','N','A','T','U','R','A','L','T','E','R','A','I','S','E','X',
    'C','L','U','S','I','V','E','X','I','S','T','S','C','O','N','S','T','R',
    'A','I','N','T','O','F','F','S','E','T','R','I','G','G','E','R','A','N',
    'G','E','N','E','R','A','T','E','D','E','T','A','C','H','A','V','I','N',
    'G','L','O','B','E','G','I','N','N','E','R','E','F','E','R','E','N','C',
    'E','S','U','N','I','Q','U','E','R','Y','W','I','T','H','O','U','T','E',
    'R','E','L','E','A','S','E','A','T','T','A','C','H','B','E','T','W','E',
    'E','N','O','T','H','I','N','G','R','O','U','P','S','C','A','S','C','A',
    'D','E','F','A','U','L','T','C','A','S','E','C','O','L','L','A','T','E',
    'C','R','E','A','T','E','C','U','R','R','E','N','T','_','D','A','T','E',
    'I','M','M','E','D','I','A','T','E','J','O','I','N','S','E','R','T','M',
    'A','T','C','H','P','L','A','N','A','L','Y','Z','E','P','R','A','G','M',
    'A','T','E','R','I','A','L','I','Z','E','D','E','F','E','R','R','E','D',
    'I','S','T','I','N','C','T','U','P','D','A','T','E','V','A','L','U','E',
    'S','V','I','R','T','U','A','L','W','A','Y','S','W','H','E','N','W','H',
    'E','R','E','C','U','R','S','I','V','E','A','B','O','R','T','A','F','T',
    'E','R','E','N','A','M','E','A','N','D','R','O','P','A','R','T','I','T',
    'I','O','N','A','U','T','O','I','N','C','R','E','M','E','N','T','C','A',
    'S','T','C','O','L','U','M','N','C','O','M','M','I','T','C','O','N','F',
    'L','I','C','T','C','R','O','S','S','C','U','R','R','E','N','T','_','T',
    'I','M','E','S','T','A','M','P','R','E','C','E','D','I','N','G','F','A',
    'I','L','A','S','T','F','I','L','T','E','R','E','P','L','A','C','E','F',
    'I','R','S','T','F','O','L','L','O','W','I','N','G','F','R','O','M','F',
    'U','L','L','I','M','I','T','I','F','O','R','D','E','R','E','S','T','R',
    'I','C','T','O','T','H','E','R','S','O','V','E','R','E','T','U','R','N',
    'I','N','G','R','I','G','H','T','R','O','L','L','B','A','C','K','R','O',
    'W','S','U','N','B','O','U','N','D','E','D','U','N','I','O','N','U','S',
    'I','N','G','V','A','C','U','U','M','V','I','E','W','I','N','D','O','W',
    'B','Y','I','N','I','T','I','A','L','L','Y','P','R','I','M','A','R','Y'
  );

  aKWHash: array[0..126] of u8 = (
     84, 92,134, 82,105, 29,  0,  0, 94,  0, 85, 72,  0,
     53, 35, 86, 15,  0, 42, 97, 54, 89,135, 19,  0,  0,
    140,  0, 40,129,  0, 22,107,  0,  9,  0,  0,123, 80,
      0, 78,  6,  0, 65,103,147,  0,136,115,  0,  0, 48,
      0, 90, 24,  0, 17,  0, 27, 70, 23, 26,  5, 60,142,
    110,122,  0, 73, 91, 71,145, 61,120, 74,  0, 49,  0,
     11, 41,  0,113,  0,  0,  0,109, 10,111,116,125, 14,
     50,124,  0,100,  0, 18,121,144, 56,130,139, 88, 83,
     37, 30,126,  0,  0,108, 51,131,128,  0, 34,  0,  0,
    132,  0, 98, 38, 39,  0, 20, 45,117, 93
  );

  aKWNext: array[0..147] of u8 = (0,
      0,  0,  0,  0,  4,  0, 43,  0,  0,106,114,  0,  0,
      0,  2,  0,  0,143,  0,  0,  0, 13,  0,  0,  0,  0,
    141,  0,  0,119, 52,  0,  0,137, 12,  0,  0, 62,  0,
    138,  0,133,  0,  0, 36,  0,  0, 28, 77,  0,  0,  0,
      0, 59,  0, 47,  0,  0,  0,  0,  0,  0,  0,  0,  0,
      0, 69,  0,  0,  0,  0,  0,146,  3,  0, 58,  0,  1,
     75,  0,  0,  0, 31,  0,  0,  0,  0,  0,127,  0,104,
      0, 64, 66, 63,  0,  0,  0,  0,  0, 46,  0, 16,  8,
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0, 81,101,  0,
    112, 21,  7, 67,  0, 79, 96,118,  0,  0, 68,  0,  0,
     99, 44,  0, 55,  0, 76,  0, 95, 32, 33, 57, 25,  0,
    102,  0,  0, 87
  );

  aKWLen: array[0..147] of u8 = (0,
      7,  7,  5,  4,  6,  4,  5,  3,  6,  7,  3,  6,  6,
      7,  7,  3,  8,  2,  6,  5,  4,  4,  3, 10,  4,  7,
      6,  9,  4,  2,  6,  5,  9,  9,  4,  7,  3,  2,  4,
      4,  6, 11,  6,  2,  7,  5,  5,  9,  6, 10,  4,  6,
      2,  3,  7,  5,  9,  6,  6,  4,  5,  5, 10,  6,  5,
      7,  4,  5,  7,  6,  7,  7,  6,  5,  7,  3,  7,  4,
      7,  6, 12,  9,  4,  6,  5,  4,  7,  6, 12,  8,  8,
      2,  6,  6,  7,  6,  4,  5,  9,  5,  5,  6,  3,  4,
      9, 13,  2,  2,  4,  6,  6,  8,  5, 17, 12,  7,  9,
      4,  4,  6,  7,  5,  9,  4,  4,  5,  2,  5,  8,  6,
      4,  9,  5,  8,  4,  3,  9,  5,  5,  6,  4,  6,  2,
      2,  9,  3,  7
  );

  aKWOffset: array[0..147] of u16 = (0,
      0,  2,  2,  8,  9, 14, 16, 20, 23, 25, 25, 29, 33,
     36, 41, 46, 48, 53, 54, 59, 62, 65, 67, 69, 78, 81,
     86, 90, 90, 94, 99,101,105,111,119,123,123,123,126,
    129,132,137,142,146,147,152,156,160,168,174,181,184,
    184,187,189,195,198,206,211,216,219,222,226,236,239,
    244,244,248,252,259,265,271,277,277,283,284,288,295,
    299,306,312,324,333,335,341,346,348,355,359,370,377,
    378,385,391,397,402,408,412,415,424,429,433,439,441,
    444,453,455,457,466,470,476,482,490,495,495,495,511,
    520,523,527,532,539,544,553,557,560,565,567,571,579,
    585,588,597,602,610,610,614,623,628,633,639,642,645,
    648,650,655,659
  );

  aKWCode: array[0..147] of u8 = (0,
    TK_REINDEX,   TK_INDEXED,    TK_INDEX,      TK_DESC,       TK_ESCAPE,
    TK_EACH,      TK_CHECK,      TK_KEY,        TK_BEFORE,     TK_FOREIGN,
    TK_FOR,       TK_IGNORE,     TK_LIKE_KW,    TK_EXPLAIN,    TK_INSTEAD,
    TK_ADD,       TK_DATABASE,   TK_AS,         TK_SELECT,     TK_TABLE,
    TK_JOIN_KW,   TK_THEN,       TK_END,        TK_DEFERRABLE, TK_ELSE,
    TK_EXCLUDE,   TK_DELETE,     TK_TEMP,       TK_TEMP,       TK_OR,
    TK_ISNULL,    TK_NULLS,      TK_SAVEPOINT,  TK_INTERSECT,  TK_TIES,
    TK_NOTNULL,   TK_NOT,        TK_NO,         TK_NULL,       TK_LIKE_KW,
    TK_EXCEPT,    TK_TRANSACTION,TK_ACTION,     TK_ON,         TK_JOIN_KW,
    TK_ALTER,     TK_RAISE,      TK_EXCLUSIVE,  TK_EXISTS,     TK_CONSTRAINT,
    TK_INTO,      TK_OFFSET,     TK_OF,         TK_SET,        TK_TRIGGER,
    TK_RANGE,     TK_GENERATED,  TK_DETACH,     TK_HAVING,     TK_LIKE_KW,
    TK_BEGIN,     TK_JOIN_KW,    TK_REFERENCES, TK_UNIQUE,     TK_QUERY,
    TK_WITHOUT,   TK_WITH,       TK_JOIN_KW,    TK_RELEASE,    TK_ATTACH,
    TK_BETWEEN,   TK_NOTHING,    TK_GROUPS,     TK_GROUP,      TK_CASCADE,
    TK_ASC,       TK_DEFAULT,    TK_CASE,       TK_COLLATE,    TK_CREATE,
    TK_CTIME_KW,  TK_IMMEDIATE,  TK_JOIN,       TK_INSERT,     TK_MATCH,
    TK_PLAN,      TK_ANALYZE,    TK_PRAGMA,     TK_MATERIALIZED,TK_DEFERRED,
    TK_DISTINCT,  TK_IS,         TK_UPDATE,     TK_VALUES,     TK_VIRTUAL,
    TK_ALWAYS,    TK_WHEN,       TK_WHERE,      TK_RECURSIVE,  TK_ABORT,
    TK_AFTER,     TK_RENAME,     TK_AND,        TK_DROP,       TK_PARTITION,
    TK_AUTOINCR,  TK_TO,         TK_IN,         TK_CAST,       TK_COLUMNKW,
    TK_COMMIT,    TK_CONFLICT,   TK_JOIN_KW,    TK_CTIME_KW,   TK_CTIME_KW,
    TK_CURRENT,   TK_PRECEDING,  TK_FAIL,       TK_LAST,       TK_FILTER,
    TK_REPLACE,   TK_FIRST,      TK_FOLLOWING,  TK_FROM,       TK_JOIN_KW,
    TK_LIMIT,     TK_IF,         TK_ORDER,      TK_RESTRICT,   TK_OTHERS,
    TK_OVER,      TK_RETURNING,  TK_JOIN_KW,    TK_ROLLBACK,   TK_ROWS,
    TK_ROW,       TK_UNBOUNDED,  TK_UNION,      TK_USING,      TK_VACUUM,
    TK_VIEW,      TK_WINDOW,     TK_DO,         TK_BY,         TK_INITIALLY,
    TK_ALL,       TK_PRIMARY
  );

{ =========================================================================== }
{ IdChar — true if c can appear inside an identifier                          }
{ Equivalent to C macro: ((sqlite3CtypeMap[(unsigned char)C]&0x46)!=0)       }
{ =========================================================================== }

function sqlite3IsIdChar(c: u8): i32;
begin
  if (sqlite3CtypeMap[c] and $46) <> 0 then Result := 1 else Result := 0;
end;

{ =========================================================================== }
{ keywordCode — private perfect-hash keyword lookup                           }
{ (tokenize.c:293 — static i64 keywordCode)                                  }
{ =========================================================================== }

function keywordCode(z: PByte; n: i64; pType: Pi32): i64;
var
  idx, j: i64;
  zKW: PAnsiChar;
begin
  { Hash formula from mkkeywordhash.c }
  idx := ((i64(sqlite3UpperToLower[z[0]])*4)
          xor (i64(sqlite3UpperToLower[z[n-1]])*3)
          xor n) mod 127;
  idx := aKWHash[idx];
  while idx > 0 do begin
    if aKWLen[idx] <> n then begin idx := aKWNext[idx]; continue; end;
    zKW := @zKWText[aKWOffset[idx]];
    { Case-insensitive compare via uppercase mask $DF }
    if (z[0] and $DF) <> u8(Ord(zKW[0])) then begin idx := aKWNext[idx]; continue; end;
    if (z[1] and $DF) <> u8(Ord(zKW[1])) then begin idx := aKWNext[idx]; continue; end;
    j := 2;
    while (j < n) and ((z[j] and $DF) = u8(Ord(zKW[j]))) do Inc(j);
    if j < n then begin idx := aKWNext[idx]; continue; end;
    pType^ := aKWCode[idx];
    Break;
  end;
  Result := n;
end;

{ =========================================================================== }
{ sqlite3KeywordCode                                                           }
{ =========================================================================== }

function sqlite3KeywordCode(z: PByte; n: i32): i32;
var
  id: i32;
begin
  id := TK_ID;
  if n >= 2 then keywordCode(z, n, @id);
  Result := id;
end;

{ =========================================================================== }
{ Keyword API (sqlite3.h public surface)                                      }
{ =========================================================================== }

function sqlite3_keyword_name(idx: i32; out pzName: PAnsiChar; out pnName: i32): i32;
begin
  if (idx < 0) or (idx >= SQLITE_N_KEYWORD) then begin
    Result := SQLITE_ERROR; Exit;
  end;
  Inc(idx);   { aKW* arrays are 1-based }
  pzName := @zKWText[aKWOffset[idx]];
  pnName := aKWLen[idx];
  Result := SQLITE_OK;
end;

function sqlite3_keyword_count: i32;
begin
  Result := SQLITE_N_KEYWORD;
end;

function sqlite3_keyword_check(zName: PAnsiChar; nName: i32): i32;
begin
  if TK_ID <> sqlite3KeywordCode(PByte(zName), nName) then
    Result := 1
  else
    Result := 0;
end;

{ =========================================================================== }
{ sqlite3GetToken  (tokenize.c:273 — i64 sqlite3GetToken)                    }
{ =========================================================================== }

function sqlite3GetToken(z: PByte; tokenType: Pi32): i64;
var
  i:   i64;
  c:   i32;
  nId: i64;
begin
  case aiClass[z[0]] of

    CC_SPACE: begin
      i := 1;
      while sqlite3Isspace(z[i]) <> 0 do Inc(i);
      tokenType^ := TK_SPACE;
      Result := i; Exit;
    end;

    CC_MINUS: begin
      if z[1] = Ord('-') then begin
        i := 2;
        c := i32(z[i]);
        while (c <> 0) and (c <> i32(Ord(#10))) do begin
          Inc(i); c := i32(z[i]);
        end;
        tokenType^ := TK_COMMENT;
        Result := i; Exit;
      end else if z[1] = Ord('>') then begin
        tokenType^ := TK_PTR;
        if z[2] = Ord('>') then Result := 3 else Result := 2;
        Exit;
      end;
      tokenType^ := TK_MINUS;
      Result := 1; Exit;
    end;

    CC_LP: begin
      tokenType^ := TK_LP;
      Result := 1; Exit;
    end;

    CC_RP: begin
      tokenType^ := TK_RP;
      Result := 1; Exit;
    end;

    CC_SEMI: begin
      tokenType^ := TK_SEMI;
      Result := 1; Exit;
    end;

    CC_PLUS: begin
      tokenType^ := TK_PLUS;
      Result := 1; Exit;
    end;

    CC_STAR: begin
      tokenType^ := TK_STAR;
      Result := 1; Exit;
    end;

    CC_SLASH: begin
      if (z[1] <> Ord('*')) or (z[2] = 0) then begin
        tokenType^ := TK_SLASH;
        Result := 1; Exit;
      end;
      i := 3;
      c := i32(z[2]);
      while ((c <> i32(Ord('*'))) or (z[i] <> Ord('/'))) and (c <> 0) do begin
        c := i32(z[i]);
        Inc(i);
      end;
      if c <> 0 then Inc(i);
      tokenType^ := TK_COMMENT;
      Result := i; Exit;
    end;

    CC_PERCENT: begin
      tokenType^ := TK_REM;
      Result := 1; Exit;
    end;

    CC_EQ: begin
      tokenType^ := TK_EQ;
      if z[1] = Ord('=') then Result := 2 else Result := 1;
      Exit;
    end;

    CC_LT: begin
      c := i32(z[1]);
      if c = i32(Ord('=')) then begin tokenType^ := TK_LE; Result := 2; Exit; end;
      if c = i32(Ord('>')) then begin tokenType^ := TK_NE; Result := 2; Exit; end;
      if c = i32(Ord('<')) then begin tokenType^ := TK_LSHIFT; Result := 2; Exit; end;
      tokenType^ := TK_LT;
      Result := 1; Exit;
    end;

    CC_GT: begin
      c := i32(z[1]);
      if c = i32(Ord('=')) then begin tokenType^ := TK_GE; Result := 2; Exit; end;
      if c = i32(Ord('>')) then begin tokenType^ := TK_RSHIFT; Result := 2; Exit; end;
      tokenType^ := TK_GT;
      Result := 1; Exit;
    end;

    CC_BANG: begin
      if z[1] <> Ord('=') then begin
        tokenType^ := TK_ILLEGAL;
        Result := 1;
      end else begin
        tokenType^ := TK_NE;
        Result := 2;
      end;
      Exit;
    end;

    CC_PIPE: begin
      if z[1] <> Ord('|') then begin
        tokenType^ := TK_BITOR;
        Result := 1;
      end else begin
        tokenType^ := TK_CONCAT;
        Result := 2;
      end;
      Exit;
    end;

    CC_COMMA: begin
      tokenType^ := TK_COMMA;
      Result := 1; Exit;
    end;

    CC_AND: begin
      tokenType^ := TK_BITAND;
      Result := 1; Exit;
    end;

    CC_TILDA: begin
      tokenType^ := TK_BITNOT;
      Result := 1; Exit;
    end;

    CC_QUOTE: begin
      { Single-quoted string, double-quoted id, or backtick id }
      c := i32(z[0]);   { the delimiter }
      i := 1;
      while z[i] <> 0 do begin
        if i32(z[i]) = c then begin
          if i32(z[i+1]) = c then
            Inc(i)   { doubled delimiter = escaped }
          else
            Break;
        end;
        Inc(i);
      end;
      if i32(z[i]) = i32(Ord('''')) then begin
        tokenType^ := TK_STRING;
        Result := i + 1;
      end else if z[i] <> 0 then begin
        tokenType^ := TK_ID;
        Result := i + 1;
      end else begin
        tokenType^ := TK_ILLEGAL;
        Result := i;
      end;
      Exit;
    end;

    CC_DOT: begin
      { If next char is NOT a digit, this is just a dot. }
      if sqlite3Isdigit(z[1]) = 0 then begin
        tokenType^ := TK_DOT;
        Result := 1; Exit;
      end;
      { z[0]='.' followed by digits — a float like .5 }
      tokenType^ := TK_FLOAT;
      i := 1;
      while sqlite3Isdigit(z[i]) <> 0 do Inc(i);
      { optional exponent }
      if (z[i] = Ord('e')) or (z[i] = Ord('E')) then begin
        if sqlite3Isdigit(z[i+1]) <> 0 then begin
          Inc(i, 2);
          while sqlite3Isdigit(z[i]) <> 0 do Inc(i);
        end else if ((z[i+1] = Ord('+')) or (z[i+1] = Ord('-'))) and
                    (sqlite3Isdigit(z[i+2]) <> 0) then begin
          Inc(i, 3);
          while sqlite3Isdigit(z[i]) <> 0 do Inc(i);
        end;
      end;
      while sqlite3IsIdChar(z[i]) <> 0 do begin
        tokenType^ := TK_ILLEGAL;
        Inc(i);
      end;
      Result := i; Exit;
    end;

    CC_DIGIT: begin
      tokenType^ := TK_INTEGER;
      { Hex literal? }
      if (z[0] = Ord('0')) and
         ((z[1] = Ord('x')) or (z[1] = Ord('X'))) and
         (sqlite3Isxdigit(z[2]) <> 0) then begin
        i := 3;
        while sqlite3Isxdigit(z[i]) <> 0 do Inc(i);
      end else begin
        i := 0;
        while sqlite3Isdigit(z[i]) <> 0 do Inc(i);
        { Decimal point? }
        if z[i] = Ord('.') then begin
          tokenType^ := TK_FLOAT;
          Inc(i);
          while sqlite3Isdigit(z[i]) <> 0 do Inc(i);
        end;
        { Exponent? }
        if ((z[i] = Ord('e')) or (z[i] = Ord('E'))) then begin
          if sqlite3Isdigit(z[i+1]) <> 0 then begin
            if tokenType^ = TK_INTEGER then tokenType^ := TK_FLOAT;
            Inc(i, 2);
            while sqlite3Isdigit(z[i]) <> 0 do Inc(i);
          end else if ((z[i+1] = Ord('+')) or (z[i+1] = Ord('-'))) and
                      (sqlite3Isdigit(z[i+2]) <> 0) then begin
            if tokenType^ = TK_INTEGER then tokenType^ := TK_FLOAT;
            Inc(i, 3);
            while sqlite3Isdigit(z[i]) <> 0 do Inc(i);
          end;
        end;
      end;
      { Identifier character immediately after number → illegal }
      while sqlite3IsIdChar(z[i]) <> 0 do begin
        tokenType^ := TK_ILLEGAL;
        Inc(i);
      end;
      Result := i; Exit;
    end;

    CC_QUOTE2: begin
      { Microsoft-style [...] identifier }
      i := 1;
      c := i32(z[0]);   { '[' }
      while (c <> i32(Ord(']'))) and (z[i] <> 0) do begin
        c := i32(z[i]);
        Inc(i);
      end;
      if c = i32(Ord(']')) then
        tokenType^ := TK_ID
      else
        tokenType^ := TK_ILLEGAL;
      Result := i; Exit;
    end;

    CC_VARNUM: begin
      { ?NNN numeric variable }
      tokenType^ := TK_VARIABLE;
      i := 1;
      while sqlite3Isdigit(z[i]) <> 0 do Inc(i);
      Result := i; Exit;
    end;

    CC_DOLLAR,
    CC_VARALPHA: begin
      { $var, @var, :var, #var }
      nId := 0;
      tokenType^ := TK_VARIABLE;
      i := 1;
      while z[i] <> 0 do begin
        if sqlite3IsIdChar(z[i]) <> 0 then
          Inc(nId)
        else
          Break;
        Inc(i);
      end;
      if nId = 0 then tokenType^ := TK_ILLEGAL;
      Result := i; Exit;
    end;

    CC_KYWD0: begin
      { Keyword starting with a letter that starts keywords (not CC_KYWD) }
      if aiClass[z[1]] > CC_KYWD then begin
        { Only one keyword-class char — fall into identifier handling }
        i := 1;
        while sqlite3IsIdChar(z[i]) <> 0 do Inc(i);
        tokenType^ := TK_ID;
        Result := i; Exit;
      end;
      i := 2;
      while aiClass[z[i]] <= CC_KYWD do Inc(i);
      if sqlite3IsIdChar(z[i]) <> 0 then begin
        { More chars follow that are not keyword-class, so it's an identifier }
        Inc(i);
        while sqlite3IsIdChar(z[i]) <> 0 do Inc(i);
        tokenType^ := TK_ID;
        Result := i; Exit;
      end;
      tokenType^ := TK_ID;
      Result := keywordCode(z, i, tokenType);
      Exit;
    end;

    CC_X: begin
      { BLOB literal x'...' or identifier starting with x/X }
      if z[1] = Ord('''') then begin
        tokenType^ := TK_BLOB;
        i := 2;
        while sqlite3Isxdigit(z[i]) <> 0 do Inc(i);
        if (z[i] <> Ord('''')) or ((i and 1) <> 0) then begin
          tokenType^ := TK_ILLEGAL;
          while (z[i] <> 0) and (z[i] <> Ord('''')) do Inc(i);
        end;
        if z[i] <> 0 then Inc(i);
        Result := i; Exit;
      end;
      { Fall through: treat as identifier }
      i := 1;
      while sqlite3IsIdChar(z[i]) <> 0 do Inc(i);
      tokenType^ := TK_ID;
      Result := i; Exit;
    end;

    CC_KYWD,
    CC_ID: begin
      i := 1;
      while sqlite3IsIdChar(z[i]) <> 0 do Inc(i);
      tokenType^ := TK_ID;
      Result := i; Exit;
    end;

    CC_BOM: begin
      if (z[1] = $BB) and (z[2] = $BF) then begin
        tokenType^ := TK_SPACE;
        Result := 3; Exit;
      end;
      i := 1;
      while sqlite3IsIdChar(z[i]) <> 0 do Inc(i);
      tokenType^ := TK_ID;
      Result := i; Exit;
    end;

    CC_NUL: begin
      tokenType^ := TK_ILLEGAL;
      Result := 0; Exit;
    end;

    else begin
      tokenType^ := TK_ILLEGAL;
      Result := 1; Exit;
    end;

  end; { case }
end;

{ =========================================================================== }
{ WINDOW / OVER / FILTER lookahead helpers  (tokenize.c:197–266)              }
{ =========================================================================== }

{ Return the type of the next non-whitespace, non-comment token at *pz,
  advancing *pz past it.  Returns TK_ID for any identifier-like token
  (including keywords that fall back to TK_ID in the Lemon grammar).
  sqlite3ParserFallback is stubbed as 0 until Phase 7.2. }
function getNextToken(var pz: PByte): i32;
var
  tt: i32;
  n:  i64;
begin
  repeat
    n  := sqlite3GetToken(pz, @tt);
    pz := pz + n;
  until (tt <> TK_SPACE) and (tt <> TK_COMMENT);
  { Tokens that behave as identifiers in the grammar }
  if (tt = TK_ID) or (tt = TK_STRING) or (tt = TK_JOIN_KW) or
     (tt = TK_WINDOW) or (tt = TK_OVER) then
    Result := TK_ID
  else
    Result := tt;
end;

function analyzeWindowKeyword(z: PByte): i32;
var pz: PByte;
begin
  pz := z;
  if getNextToken(pz) <> TK_ID  then begin Result := TK_ID; Exit; end;
  if getNextToken(pz) <> TK_AS  then begin Result := TK_ID; Exit; end;
  Result := TK_WINDOW;
end;

function analyzeOverKeyword(z: PByte; lastToken: i32): i32;
var
  pz: PByte;
  t:  i32;
begin
  if lastToken = TK_RP then begin
    pz := z;
    t  := getNextToken(pz);
    if (t = TK_LP) or (t = TK_ID) then begin Result := TK_OVER; Exit; end;
  end;
  Result := TK_ID;
end;

function analyzeFilterKeyword(z: PByte; lastToken: i32): i32;
var pz: PByte;
begin
  pz := z;
  if (lastToken = TK_RP) and (getNextToken(pz) = TK_LP) then
    Result := TK_FILTER
  else
    Result := TK_ID;
end;

{ =========================================================================== }
{ sqlite3RunParser — Phase 7.1 stub                                           }
{ Full implementation requires the Lemon LALR(1) parser (Phase 7.2).         }
{ =========================================================================== }

function sqlite3RunParser(pParse: Pointer; zSql: PAnsiChar): i32;
begin
  Result := SQLITE_ERROR;
end;

{ =========================================================================== }
{ sqlite3_complete  (complete.c:104)                                           }
{ =========================================================================== }

function sqlite3_complete(zSql: PAnsiChar): i32;
const
  { State-machine token classes for sqlite3_complete }
  tkSEMI    = 0;
  tkWS      = 1;
  tkOTHER   = 2;
  tkEXPLAIN = 3;
  tkCREATE  = 4;
  tkTEMP    = 5;
  tkTRIGGER = 6;
  tkEND_tok = 7;

  { Transition table:  trans[state][token] → next state }
  trans: array[0..7, 0..7] of u8 = (
    { SEMI WS OTHER EXPLAIN CREATE TEMP TRIGGER END }
    ( 1,  0,  2,  3,  4,  2,  2,  2 ),  { 0: INVALID }
    ( 1,  1,  2,  3,  4,  2,  2,  2 ),  { 1: START   }
    ( 1,  2,  2,  2,  2,  2,  2,  2 ),  { 2: NORMAL  }
    ( 1,  3,  3,  2,  4,  2,  2,  2 ),  { 3: EXPLAIN }
    ( 1,  4,  2,  2,  2,  4,  5,  2 ),  { 4: CREATE  }
    ( 6,  5,  5,  5,  5,  5,  5,  5 ),  { 5: TRIGGER }
    ( 6,  6,  5,  5,  5,  5,  5,  7 ),  { 6: SEMI    }
    ( 1,  7,  5,  5,  5,  5,  5,  5 )   { 7: END     }
  );
var
  state: u8;
  tok:   u8;
  nId:   i32;
  ch:    AnsiChar;
begin
  if zSql = nil then begin Result := 0; Exit; end;
  state := 0;
  while zSql^ <> #0 do begin
    ch := zSql^;
    case ch of
      ';': tok := tkSEMI;
      ' ', #9, #10, #13, #12: tok := tkWS;
      '/': begin
        if zSql[1] <> '*' then begin
          tok := tkOTHER;
        end else begin
          Inc(zSql, 2);
          while (zSql^ <> #0) and
                ((zSql^ <> '*') or (zSql[1] <> '/')) do
            Inc(zSql);
          if zSql^ = #0 then begin Result := 0; Exit; end;
          Inc(zSql);
          tok := tkWS;
        end;
      end;
      '-': begin
        if zSql[1] <> '-' then begin
          tok := tkOTHER;
        end else begin
          while (zSql^ <> #0) and (zSql^ <> #10) do Inc(zSql);
          if zSql^ = #0 then begin Result := ord(state = 1); Exit; end;
          tok := tkWS;
        end;
      end;
      '[': begin
        Inc(zSql);
        while (zSql^ <> #0) and (zSql^ <> ']') do Inc(zSql);
        if zSql^ = #0 then begin Result := 0; Exit; end;
        tok := tkOTHER;
      end;
      '`', '"', '''': begin
        Inc(zSql);
        while (zSql^ <> #0) and (zSql^ <> ch) do Inc(zSql);
        if zSql^ = #0 then begin Result := 0; Exit; end;
        tok := tkOTHER;
      end;
      else begin
        if sqlite3IsIdChar(u8(Ord(ch))) <> 0 then begin
          nId := 1;
          while sqlite3IsIdChar(u8(Ord(zSql[nId]))) <> 0 do Inc(nId);
          case ch of
            'c', 'C':
              if (nId = 6) and
                 (sqlite3_strnicmp(zSql, 'create', 6) = 0) then
                tok := tkCREATE
              else
                tok := tkOTHER;
            't', 'T': begin
              if (nId = 7) and
                 (sqlite3_strnicmp(zSql, 'trigger', 7) = 0) then
                tok := tkTRIGGER
              else if (nId = 4) and
                      (sqlite3_strnicmp(zSql, 'temp', 4) = 0) then
                tok := tkTEMP
              else if (nId = 9) and
                      (sqlite3_strnicmp(zSql, 'temporary', 9) = 0) then
                tok := tkTEMP
              else
                tok := tkOTHER;
            end;
            'e', 'E': begin
              if (nId = 3) and
                 (sqlite3_strnicmp(zSql, 'end', 3) = 0) then
                tok := tkEND_tok
              else if (nId = 7) and
                      (sqlite3_strnicmp(zSql, 'explain', 7) = 0) then
                tok := tkEXPLAIN
              else
                tok := tkOTHER;
            end;
            else tok := tkOTHER;
          end;
          Inc(zSql, nId - 1);
        end else
          tok := tkOTHER;
      end;
    end;
    state := trans[state][tok];
    Inc(zSql);
  end;
  if state = 1 then Result := 1 else Result := 0;
end;

end.
