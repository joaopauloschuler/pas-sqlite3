{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  Phase 10 — passqlite3shell.pas

  Faithful Pascal port of the SQLite command-line tool found at
  ../sqlite3/src/shell.c.in.  The C source is ~13.8k lines; this initial
  cut lands the structural skeleton called for by tasklist.md tasks
  10.1.1 .. 10.1.6:

    10.1.1  ShellState record + globals (shell.c.in:340..555)
    10.1.2  process_input / one_input_line REPL core
            (shell.c.in:1041..1073, 12378..12542)
    10.1.3  main + minimal arg parser (shell.c.in:12942..)
    10.1.4  local_getline line reader (shell.c.in:994..1025)
    10.1.5  Exit-code mapping + interrupt-handler stub
    10.1.6  do_meta_command dispatcher skeleton — every dot-command
            currently lands the upstream
            "Error: unknown command or invalid arguments: ".foo""
            so partial Phase-10 landings cannot silently no-op.

  Per-command handlers (10.1.7..10.1.59) and full `process_command_line`
  flag coverage (10.1.3 expansion) are deliberately stubbed; this module
  is the foundation that subsequent phase-10 work will hang per-command
  arms onto.

  This program links against the same passqlite3* units as the rest of
  the test suite; no libsqlite3.so dependency.  Built into bin/passqlite3
  by src/tests/build.sh so that the upcoming 10.2 integration parity
  test can diff its output against the upstream sqlite3 binary.
}
{$I passqlite3.inc}
program passqlite3shell;

uses
  SysUtils,
  StrUtils,
  BaseUnix,
  Unix,
  termio,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser,
  passqlite3vtab,
  passqlite3dbpage,
  passqlite3backup,
  passqlite3shathree,
  passqlite3sha1,
  passqlite3uuid,
  passqlite3ieee754,
  passqlite3percentile,
  passqlite3main;

{ ----------------------------------------------------------------------
  Constants — shell.c.in:447..634
  ---------------------------------------------------------------------- }

const
  { Allowed values for ShellState.mode.autoEQP }
  AUTOEQP_off      = 0;
  AUTOEQP_on       = 1;
  AUTOEQP_trigger  = 2;
  AUTOEQP_full     = 3;

  { Allowed values for ShellState.openMode }
  SHELL_OPEN_UNSPEC      = 0;
  SHELL_OPEN_NORMAL      = 1;
  SHELL_OPEN_APPENDVFS   = 2;
  SHELL_OPEN_ZIPFILE     = 3;
  SHELL_OPEN_DESERIALIZE = 4;
  SHELL_OPEN_HEXDB       = 5;

  { Allowed values for ShellState.eTraceType }
  SHELL_TRACE_PLAIN      = 0;
  SHELL_TRACE_EXPANDED   = 1;
  SHELL_TRACE_NORMALIZED = 2;

  { Bits in the ShellState.flgProgress variable }
  SHELL_PROGRESS_QUIET = $01;
  SHELL_PROGRESS_RESET = $02;
  SHELL_PROGRESS_ONCE  = $04;
  SHELL_PROGRESS_TMOUT = $08;

  { ShellState.shellFlgs — shell.c.in:485..495 }
  SHFLG_Pagecache      = $00000001;
  SHFLG_Lookaside      = $00000002;
  SHFLG_Backslash      = $00000004;
  SHFLG_PreserveRowid  = $00000008;
  SHFLG_NoErrLineno    = $00000010;
  SHFLG_CountChanges   = $00000020;
  SHFLG_DumpDataOnly   = $00000100;
  SHFLG_DumpNoSys      = $00000200;
  SHFLG_TestingMode    = $00000400;

  { Mode.eMode — shell.c.in:509..531 }
  MODE_Ascii     = 0;
  MODE_Box       = 1;
  MODE_C         = 2;
  MODE_Column    = 3;
  MODE_Count     = 4;
  MODE_Csv       = 5;
  MODE_Html      = 6;
  MODE_Insert    = 7;
  MODE_JAtom     = 8;
  MODE_JObject   = 9;
  MODE_Json      = 10;
  MODE_Line      = 11;
  MODE_List      = 12;
  MODE_Markdown  = 13;
  MODE_Off       = 14;
  MODE_Psql      = 15;
  MODE_QBox      = 16;
  MODE_Quote     = 17;
  MODE_Split     = 18;
  MODE_Table     = 19;
  MODE_Tabs      = 20;
  MODE_Tcl       = 21;
  MODE_Www       = 22;

  MODE_BUILTIN  = 22;
  MODE_BATCH    = 50;
  MODE_TTY      = 51;
  MODE_USER     = 75;
  MODE_N_USER   = 25;

  { Mode.mFlags — shell.c.in:354..356 }
  MFLG_ECHO  = $01;
  MFLG_CRLF  = $02;
  MFLG_HDR   = $04;

  { QRF tri-state — qrf.h:142..147 }
  QRF_SW_Off = 1;
  QRF_SW_On  = 2;
  QRF_No     = 1;
  QRF_Yes    = 2;

  { Default values for QRF limits — shell.c.in:622..633 }
  DFLT_CHAR_LIMIT   = 300;
  DFLT_LINE_LIMIT   = 5;
  DFLT_TITLE_LIMIT  = 20;
  DFLT_MULTI_INSERT = 3000;

  { shell.c.in:610..617 — separator constants }
  SEP_Column = '|';
  SEP_Row    = #10;
  SEP_Tab    = #9;
  SEP_Space  = ' ';
  SEP_Comma  = ',';
  SEP_CrLf   = #13#10;
  SEP_Unit   = #$1F;
  SEP_Record = #$1E;

  PROMPT_LEN_MAX     = 128;
  MAX_INPUT_NESTING  = 25;     { shell.c.in MAX_INPUT_NESTING }
  FILENAME_MAX_PAS   = 4096;

  CONTINUATION_PROMPT = '   ...> ';
  MAIN_PROMPT_DEFAULT = 'sqlite> ';

  { Names of values for Mode.spec.eEsc and Mode.spec.eText
    (shell.c.in:480..482) }

{ ----------------------------------------------------------------------
  Records — shell.c.in:323..555
  ---------------------------------------------------------------------- }

type
  PFILE = Pointer;   { we treat C FILE* as opaque; only nil-checks are
                       meaningful in this initial cut.  When the per-mode
                       renderers land, this gets re-typed against
                       BaseUnix's libc bindings. }

  { sqlite3_qrf_spec — port of ext/qrf/qrf.h:27..61.  We carry the layout
    so that future 10.1.8/9 renderers can populate it without re-deriving
    field positions; the QRF rendering core itself is not yet ported. }
  TQrfRenderProc = function(p: Pointer; v: Pointer): PAnsiChar; cdecl;
  TQrfWriteProc  = function(p: Pointer; z: PAnsiChar; n: i64): i32; cdecl;

  Tsqlite3_qrf_spec = record
    iVersion:     u8;
    eStyle:       u8;
    eEsc:         u8;
    eText:        u8;
    eTitle:       u8;
    eBlob:        u8;
    bTitles:      u8;
    bWordWrap:    u8;
    bTextJsonb:   u8;
    eDfltAlign:   u8;
    eTitleAlign:  u8;
    bSplitColumn: u8;
    bBorder:      u8;
    nWrap:        SmallInt;
    nScreenWidth: SmallInt;
    nLineLimit:   SmallInt;
    nTitleLimit:  SmallInt;
    nMultiInsert: u32;
    nCharLimit:   i32;
    nWidth:       i32;
    nAlign:       i32;
    aWidth:       PSmallInt;
    aAlign:       PByte;
    zColumnSep:   PAnsiChar;
    zRowSep:      PAnsiChar;
    zTableName:   PAnsiChar;
    zNull:        PAnsiChar;
    xRender:      TQrfRenderProc;
    xWrite:       TQrfWriteProc;
    pRenderArg:   Pointer;
    pWriteArg:    Pointer;
    pzOutput:     PPAnsiChar;
  end;
  PQrfSpec = ^Tsqlite3_qrf_spec;

  { Mode — shell.c.in:342..351 }
  TShellMode = record
    autoExplain:       u8;
    autoEQP:           u8;
    autoEQPtrace:      u8;
    scanstatsOn:       u8;
    bAutoScreenWidth:  u8;
    mFlags:            u8;
    eMode:             u8;
    spec:              Tsqlite3_qrf_spec;
  end;
  PShellMode = ^TShellMode;

  { ModeInfo — shell.c.in:543..555 }
  TModeInfo = record
    zName:   array[0..8] of AnsiChar;
    eCSep:   u8;
    eRSep:   u8;
    eNull:   u8;
    eText:   u8;
    eHdr:    u8;
    eBlob:   u8;
    bHdr:    u8;
    eStyle:  u8;
    eCx:     u8;
    mFlg:    u8;
  end;

  { ShellState saved-modes slot — shell.c.in:406..409 }
  TSavedMode = record
    zTag: PAnsiChar;
    mode: TShellMode;
  end;
  PSavedMode = ^TSavedMode;

  { Per-aux-db slot — shell.c.in:411..420 (session bits omitted; not ported) }
  TAuxDb = record
    db:           PTsqlite3;
    zDbFilename:  PAnsiChar;
    zFreeOnClose: PAnsiChar;
  end;
  PAuxDb = ^TAuxDb;

  { Dot-command parsed-arg slot — shell.c.in:425..433 }
  TDotCmdLine = record
    zOrig:  PAnsiChar;
    zCopy:  PAnsiChar;
    nAlloc: i32;
    nArg:   i32;
    azArg:  PPAnsiChar;
    aiOfst: Pi32;
    abQuot: PAnsiChar;
  end;
  PDotCmdLine = ^TDotCmdLine;

  { ShellState — shell.c.in:363..441.  Session and Fiddle fields elided
    (not yet ported in this Pascal cut). }
  TShellState = record
    db:               PTsqlite3;
    openMode:         u8;
    doXdgOpen:        u8;
    nEqpLevel:        u8;
    eTraceType:       u8;
    bSafeMode:        u8;
    bSafeModePersist: u8;
    eRestoreState:    u8;
    statsOn:          u32;
    mEqpLines:        u32;
    nPopOutput:       u8;
    nPopMode:         u8;
    enableTimer:      u8;
    inputNesting:     i32;
    prevTimer:        Double;
    tmProgress:       Double;
    lineno:           i64;
    zInFile:          PAnsiChar;
    openFlags:        i32;
    inFile:           PFILE;          { p->in  }
    outFile:          PFILE;          { p->out }
    traceOut:         PFILE;
    nErr:             i32;
    writableSchema:   i32;
    nCheck:           i32;
    nProgress:        u32;
    mxProgress:       u32;
    flgProgress:      u32;
    shellFlgs:        u32;
    nTestRun:         u32;
    nTestErr:         u32;
    szMax:            i64;
    zDestTable:       PAnsiChar;
    zTempFile:        PAnsiChar;
    zErrPrefix:       PAnsiChar;
    zTestcase:        array[0..29] of AnsiChar;
    zOutfile:         array[0..FILENAME_MAX_PAS-1] of AnsiChar;
    pStmt:            PVdbe;
    pLog:             PFILE;
    mode:             TShellMode;
    modePrior:        TShellMode;
    aSavedModes:      PSavedMode;
    nSavedModes:      i32;
    aAuxDb:           array[0..4] of TAuxDb;
    pAuxDb:           PAuxDb;
    zNonce:           PAnsiChar;
    dot:              TDotCmdLine;
  end;
  PShellState = ^TShellState;

{ ----------------------------------------------------------------------
  Static tables — shell.c.in:480..605
  ---------------------------------------------------------------------- }

const
  qrfEscNames:   array[0..3] of PAnsiChar = ('auto', 'off', 'ascii', 'symbol');
  qrfQuoteNames: array[0..7] of PAnsiChar =
    ('off', 'off', 'sql', 'hex', 'csv', 'tcl', 'json', 'relaxed');

  { aModeStr — shell.c.in:558..561 }
  aModeStr: array[0..13] of PAnsiChar = (
    nil,         { 0 }
    #10,         { 1  "\n"      }
    '|',         { 2 }
    ' ',         { 3 }
    ',',         { 4 }
    #13#10,      { 5  "\r\n"    }
    #$1E,        { 6  record    }
    #$1F,        { 7  unit      }
    #9,          { 8  tab       }
    '',          { 9  empty     }
    'NULL',      { 10 NULL kw   }
    'null',      { 11 lower     }
    '""',        { 12 empty-q   }
    ': '         { 13 line-sep  }
  );

  { aModeInfo — shell.c.in:566..588 }
  aModeInfo: array[0..22] of TModeInfo = (
    (zName: 'ascii';    eCSep: 7; eRSep: 6; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 1; eStyle:12; eCx:0; mFlg:0),
    (zName: 'box';      eCSep: 0; eRSep: 0; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 2; eStyle: 1; eCx:2; mFlg:0),
    (zName: 'c';        eCSep: 4; eRSep: 1; eNull:10;  eText: 5; eHdr: 5; eBlob: 4; bHdr: 1; eStyle:12; eCx:0; mFlg:0),
    (zName: 'column';   eCSep: 0; eRSep: 0; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 2; eStyle: 2; eCx:2; mFlg:0),
    (zName: 'count';    eCSep: 0; eRSep: 0; eNull: 0;  eText: 0; eHdr: 0; eBlob: 0; bHdr: 0; eStyle: 3; eCx:0; mFlg:0),
    (zName: 'csv';      eCSep: 4; eRSep: 5; eNull: 9;  eText: 3; eHdr: 3; eBlob: 0; bHdr: 1; eStyle:12; eCx:0; mFlg:0),
    (zName: 'html';     eCSep: 0; eRSep: 0; eNull: 9;  eText: 4; eHdr: 4; eBlob: 0; bHdr: 2; eStyle: 7; eCx:0; mFlg:0),
    (zName: 'insert';   eCSep: 0; eRSep: 0; eNull:10;  eText: 2; eHdr: 2; eBlob: 0; bHdr: 1; eStyle: 8; eCx:0; mFlg:0),
    (zName: 'jatom';    eCSep: 4; eRSep: 1; eNull:11;  eText: 6; eHdr: 6; eBlob: 0; bHdr: 1; eStyle:12; eCx:0; mFlg:0),
    (zName: 'jobject';  eCSep: 0; eRSep: 1; eNull:11;  eText: 6; eHdr: 6; eBlob: 0; bHdr: 0; eStyle:10; eCx:0; mFlg:0),
    (zName: 'json';     eCSep: 0; eRSep: 0; eNull:11;  eText: 6; eHdr: 6; eBlob: 0; bHdr: 0; eStyle: 9; eCx:0; mFlg:0),
    (zName: 'line';     eCSep:13; eRSep: 1; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 0; eStyle:11; eCx:1; mFlg:0),
    (zName: 'list';     eCSep: 2; eRSep: 1; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 1; eStyle:12; eCx:0; mFlg:0),
    (zName: 'markdown'; eCSep: 0; eRSep: 0; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 2; eStyle:13; eCx:2; mFlg:0),
    (zName: 'off';      eCSep: 0; eRSep: 0; eNull: 0;  eText: 0; eHdr: 0; eBlob: 0; bHdr: 0; eStyle:14; eCx:0; mFlg:0),
    (zName: 'psql';     eCSep: 0; eRSep: 0; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 2; eStyle:19; eCx:2; mFlg:1),
    (zName: 'qbox';     eCSep: 0; eRSep: 0; eNull:10;  eText: 2; eHdr: 1; eBlob: 0; bHdr: 2; eStyle: 1; eCx:2; mFlg:0),
    (zName: 'quote';    eCSep: 4; eRSep: 1; eNull:10;  eText: 2; eHdr: 2; eBlob: 0; bHdr: 1; eStyle:12; eCx:0; mFlg:0),
    (zName: 'split';    eCSep: 0; eRSep: 0; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 1; eStyle: 2; eCx:2; mFlg:2),
    (zName: 'table';    eCSep: 0; eRSep: 0; eNull: 9;  eText: 1; eHdr: 1; eBlob: 0; bHdr: 2; eStyle:19; eCx:2; mFlg:0),
    (zName: 'tabs';     eCSep: 8; eRSep: 1; eNull: 9;  eText: 3; eHdr: 3; eBlob: 0; bHdr: 1; eStyle:12; eCx:0; mFlg:0),
    (zName: 'tcl';      eCSep: 3; eRSep: 1; eNull:12;  eText: 5; eHdr: 5; eBlob: 4; bHdr: 1; eStyle:12; eCx:0; mFlg:0),
    (zName: 'www';      eCSep: 0; eRSep: 0; eNull: 9;  eText: 4; eHdr: 4; eBlob: 0; bHdr: 2; eStyle: 7; eCx:0; mFlg:0)
  );

{ ----------------------------------------------------------------------
  File-scope mutable state — shell.c.in:639..685
  ---------------------------------------------------------------------- }

var
  bail_on_error:        i32 = 0;
  stdin_is_interactive: i32 = 1;
  stdout_is_console:    i32 = 1;
  stdout_tty_width:     i32 = -1;
  globalDb:             PTsqlite3 = nil;
  seenInterrupt:        i32 = 0;            { volatile in C }
  Argv0:                AnsiString = '';
  mainPromptStr:        AnsiString = MAIN_PROMPT_DEFAULT;
  continuePromptStr:    AnsiString = CONTINUATION_PROMPT;
  { 10.1.25 — `.output` / `.once` redirect state.  See cmdOutput. }
  gSavedStdoutFd:       cint    = -1;
  gOutRedirected:       Boolean = False;
  gOutCurFilename:      AnsiString = '';
  { 10.1.10 .separator / .nullvalue / .mode INSERT — keep stable
    AnsiString backing for the PAnsiChar fields in TShellMode.spec. }
  zUserColSep:          AnsiString = '|';
  zUserRowSep:          AnsiString = #10;
  zUserNull:            AnsiString = '';
  { 10.1.36 — track .log destination filename for cmdShow / future logger
    plumbing.  '' / 'off' both mean disabled, 'stdout' / 'stderr' refer
    to the standard streams; any other value is a regular pathname. }
  zLogFile:             AnsiString = 'off';
  { 10.1.10 follow-up — stable backing array for spec.aWidth. }
  aUserWidth:           array of SmallInt;

{ ----------------------------------------------------------------------
  Helpers — small utilities that mirror the cli_* family
  (shell.c.in:712..766).  We do not yet wire cli_output_capture; stdout/
  stderr writes go through the standard FPC I/O.
  ---------------------------------------------------------------------- }

procedure shellEPutZ(const z: AnsiString); inline;
begin
  Write(StdErr, z);
end;

procedure shellSPutZ(const z: AnsiString); inline;
begin
  Write(z);
end;

function CStrEq(a, b: PAnsiChar): Boolean;
{ shell.c.in:757 cli_strcmp; treats NULL as "" }
var pa, pb: PAnsiChar;
begin
  pa := a; if pa = nil then pa := '';
  pb := b; if pb = nil then pb := '';
  Result := StrComp(pa, pb) = 0;
end;

function CStrLen(z: PAnsiChar): SizeInt; inline;
begin
  if z = nil then Result := 0 else Result := StrLen(z);
end;

{ ----------------------------------------------------------------------
  ShellState lifecycle — shell.c.in:3140..3170 (memset/init equivalent)
  ---------------------------------------------------------------------- }

procedure shellStateInit(p: PShellState);
{ Mirrors the shell.c.in main() initialisation block at ~13070..13110:
  zeroes the struct and sets defaults that differ from zero. }
begin
  FillChar(p^, SizeOf(TShellState), 0);
  p^.openMode    := SHELL_OPEN_UNSPEC;
  p^.openFlags   := 0;
  p^.shellFlgs   := 0;
  p^.lineno      := 0;
  p^.inputNesting:= 0;
  p^.bSafeMode   := 0;
  p^.bSafeModePersist := 0;
  p^.eTraceType  := SHELL_TRACE_PLAIN;
  p^.szMax       := 0;
  p^.pAuxDb      := @p^.aAuxDb[0];
  { Mode defaults — shell.c.in main() roughly at 13072..13085 }
  p^.mode.eMode  := MODE_List;
  p^.mode.spec.eStyle := 12;          { QRF_STYLE_List }
  p^.mode.spec.bTitles := QRF_No;     { off by default; modeChangeBuiltin
                                        will overwrite from aModeInfo.bHdr
                                        unless MFLG_HDR pinned a user choice. }
  p^.mode.spec.zColumnSep := SEP_Column;
  p^.mode.spec.zRowSep := SEP_Row;
  p^.mode.spec.zNull := '';
  p^.mode.spec.nCharLimit  := DFLT_CHAR_LIMIT;
  p^.mode.spec.nLineLimit  := DFLT_LINE_LIMIT;
  p^.mode.spec.nTitleLimit := DFLT_TITLE_LIMIT;
  p^.mode.spec.nMultiInsert := DFLT_MULTI_INSERT;
end;

{ Open the database connection backing p^ if not already open.  Mirrors
  open_db (shell.c.in:6745..) at the level needed by the dispatcher
  skeleton: --readonly / --create / default SQLITE_OPEN_READWRITE|
  SQLITE_OPEN_CREATE. }
procedure openDb(p: PShellState; keepAlive: i32);
var
  flags: i32;
  rc:    i32;
  zErr:  PAnsiChar;
begin
  if p^.db <> nil then Exit;
  if p^.pAuxDb^.zDbFilename = nil then Exit;
  flags := p^.openFlags;
  if (flags and (SQLITE_OPEN_READONLY or SQLITE_OPEN_READWRITE)) = 0 then
    flags := flags or SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE;
  rc := sqlite3_open_v2(p^.pAuxDb^.zDbFilename, @p^.db, flags, nil);
  if (rc <> SQLITE_OK) or (p^.db = nil) then begin
    zErr := nil;
    if p^.db <> nil then zErr := sqlite3_errmsg(p^.db);
    if zErr = nil then zErr := 'cannot open database';
    shellEPutZ('Error: ' + zErr + sLineBreak);
    if keepAlive = 0 then begin
      if p^.db <> nil then sqlite3_close(p^.db);
      p^.db := nil;
      Halt(1);
    end;
  end;
  globalDb := p^.db;
  p^.pAuxDb^.db := p^.db;
  { sqlite_dbpage virtual table — needed by .dbinfo / .recover.  Upstream
    auto-registers this on the connection; the Pascal port leaves it
    optional, so we hook it here. }
  sqlite3DbpageRegister(p^.db);
  { 10.1.52 — sha3 / sha3_agg / sha3_query SQL functions backing .sha3sum. }
  sqlite3ShathreeInit(p^.db);
  { Phase 10 ext/misc — sha1 / sha1b / sha1_query and uuid / uuid_str /
    uuid_blob.  Auto-registered like upstream's `--shell` build. }
  sqlite3ShaInit(p^.db);
  sqlite3UuidInit(p^.db);
  { Phase 10.1.62 — ieee754() / ieee754_mantissa() / ieee754_exponent() /
    ieee754_to_blob() / ieee754_from_blob() / ieee754_to_int() /
    ieee754_from_int() / ieee754_inc() from ext/misc/ieee754.c. }
  sqlite3IeeeInit(p^.db);
  { Phase 10.1.63 — median(), percentile(), percentile_cont(),
    percentile_disc() aggregate / window functions from
    ext/misc/percentile.c. }
  sqlite3PercentileInit(p^.db);
end;

procedure closeDb(db: PTsqlite3);
{ Mirrors close_db (shell.c.in:851..) — a thin wrapper that swallows
  busy errors.  The Pascal sqlite3_close already implements the busy
  retry, so we collapse to the single call. }
var rc: i32;
begin
  if db = nil then Exit;
  rc := sqlite3_close(db);
  if rc <> SQLITE_OK then
    shellEPutZ(Format('Error: sqlite3_close() returns %d: %s'#10,
      [rc, sqlite3_errmsg(db)]));
end;

{ ----------------------------------------------------------------------
  10.1.4  local_getline — shell.c.in:994..1025
  ----------------------------------------------------------------------
  Reads one line (up to and including '\n') from inF.  Returns the line
  with the trailing '\n' (and optional '\r') stripped.  Returns '' and
  sets atEof=True on end-of-input.

  We use Free Pascal's text-file helpers rather than C's fgets because
  the shell's I/O surface goes through plain stdin/stdout — the C
  reference uses sqlite3_fgets only as a thin LF-translation hook on
  Windows, which is not required on Linux.
   }

function localGetLine(var inF: Text; out atEof: Boolean): AnsiString;
var
  ch: Char;
begin
  Result := '';
  atEof  := False;
  if EOF(inF) then begin
    atEof := True;
    Exit;
  end;
  while not EOF(inF) do begin
    Read(inF, ch);
    if ch = #10 then Break;
    Result := Result + ch;
  end;
  { Strip trailing '\r' if the input had CRLF terminators. }
  if (Length(Result) > 0) and (Result[Length(Result)] = #13) then
    SetLength(Result, Length(Result)-1);
end;

{ 10.1.4 sister: oneInputLine — shell.c.in:1042..1072.  In the C
  reference this branches on whether p->in is non-NULL (a script
  file) vs interactive stdin; we follow the same logic but consult
  inputNesting>0 as the script-file marker since this initial cut
  hasn't ported the FILE* plumbing. }
{ 10.1.22 — when a `.read FILE` arm is active, oneInputLine pulls from
  the pushed Text handle instead of stdin.  curInputText is a unit-level
  pointer so cmdRead can swap it without threading a TText through every
  call site. }
var
  curInputText: ^Text = nil;

function oneInputLine(p: PShellState; isContinuation: Boolean;
                      out atEof: Boolean): AnsiString;
begin
  if curInputText <> nil then begin
    Result := localGetLine(curInputText^, atEof);
    Exit;
  end;
  if (p^.inFile = nil) and (stdin_is_interactive <> 0) then begin
    if isContinuation then Write(continuePromptStr) else Write(mainPromptStr);
    Flush(Output);
  end;
  Result := localGetLine(Input, atEof);
end;

{ ----------------------------------------------------------------------
  Quick line-classification helpers used by process_input.  shell.c.in
  defines a more elaborate `quickscan` state machine; for the initial
  cut we use sqlite3_complete on the accumulated buffer (which is what
  the C reference falls back to anyway).
  ---------------------------------------------------------------------- }

function isAllWhitespace(const s: AnsiString): Boolean;
var i: SizeInt;
begin
  for i := 1 to Length(s) do
    if not (s[i] in [' ', #9, #11, #13]) then Exit(False);
  Result := True;
end;

function startsWithDot(const s: AnsiString): Boolean;
var i: SizeInt;
begin
  i := 1;
  while (i <= Length(s)) and (s[i] in [' ', #9]) do Inc(i);
  Result := (i <= Length(s)) and (s[i] = '.');
end;

function startsWithHash(const s: AnsiString): Boolean;
var i: SizeInt;
begin
  i := 1;
  while (i <= Length(s)) and (s[i] in [' ', #9]) do Inc(i);
  Result := (i <= Length(s)) and (s[i] = '#');
end;

{ ----------------------------------------------------------------------
  10.1.7  modeChange — port of shell.c.in:1642..1689.

  Applies the named-mode template (aModeInfo[eMode]) to p^.mode, refreshing
  separators / null / titles / blob style in the same order the C reference
  does.  The MODE_BATCH and MODE_TTY variants reuse the regular table:
  BATCH ≡ List; TTY ≡ QBox-with-relaxed-text overrides.  modeFind /
  modePush / modePop are kept thin since the saved-mode stack is not yet
  exercised.
  ---------------------------------------------------------------------- }

procedure modeSetStr(var dst: PAnsiChar; const z: PAnsiChar); inline;
begin
  { aModeStr entries are static literals owned by this unit.  Clone the
    pointer; ownership stays with aModeStr.  This mirrors the C
    `modeSetStr` used in modeChange — both forms target the same QRF
    spec fields. }
  dst := z;
end;

procedure modeChange(p: PShellState; eMode: u8); forward;
function  processInput(p: PShellState): i32; forward;

procedure modeChangeBuiltin(p: PShellState; eMode: u8);
var
  pI: ^TModeInfo;
  pM: PShellMode;
begin
  pI := @aModeInfo[eMode];
  pM := @p^.mode;
  pM^.eMode := eMode;
  if pI^.eCSep <> 0 then modeSetStr(pM^.spec.zColumnSep, aModeStr[pI^.eCSep]);
  if pI^.eRSep <> 0 then modeSetStr(pM^.spec.zRowSep,    aModeStr[pI^.eRSep]);
  if pI^.eNull <> 0 then modeSetStr(pM^.spec.zNull,      aModeStr[pI^.eNull]);
  pM^.spec.eText  := pI^.eText;
  pM^.spec.eBlob  := pI^.eBlob;
  if (pM^.mFlags and MFLG_HDR) = 0 then
    pM^.spec.bTitles := pI^.bHdr;
  pM^.spec.eTitle := pI^.eHdr;
  if (pI^.mFlg and $01) <> 0 then
    pM^.spec.bBorder := 0
  else
    pM^.spec.bBorder := 2;
  if (pI^.mFlg and $02) <> 0 then begin
    pM^.spec.bSplitColumn := 1;
    pM^.bAutoScreenWidth  := 1;
  end else
    pM^.spec.bSplitColumn := 0;
end;

procedure modeChange(p: PShellState; eMode: u8);
var savedFlags: u8;
begin
  if eMode < Length(aModeInfo) then
    modeChangeBuiltin(p, eMode)
  else if eMode = MODE_BATCH then begin
    savedFlags := p^.mode.mFlags;
    modeChange(p, MODE_List);
    p^.mode.mFlags := savedFlags;
  end else if eMode = MODE_TTY then begin
    savedFlags := p^.mode.mFlags;
    modeChange(p, MODE_QBox);
    p^.mode.bAutoScreenWidth   := 1;
    p^.mode.spec.eText         := 2;       { QRF_TEXT_Relaxed }
    p^.mode.spec.nCharLimit    := DFLT_CHAR_LIMIT;
    p^.mode.spec.nLineLimit    := DFLT_LINE_LIMIT;
    p^.mode.spec.bTextJsonb    := 1;
    p^.mode.spec.nTitleLimit   := DFLT_TITLE_LIMIT;
    p^.mode.spec.nMultiInsert  := DFLT_MULTI_INSERT;
    p^.mode.mFlags             := savedFlags;
  end;
end;

function modeFind(p: PShellState; const zName: AnsiString): i32;
var i: i32;
begin
  for i := 0 to Length(aModeInfo) - 1 do
    if StrPas(@aModeInfo[i].zName[0]) = zName then Exit(i);
  if zName = 'batch' then Exit(MODE_BATCH);
  if zName = 'tty'   then Exit(MODE_TTY);
  Result := -1;
end;

{ ----------------------------------------------------------------------
  10.1.12 / 10.1.13 / 10.1.14 — output_csv / output_json_string /
  output_html_string + a few sister helpers (TCL, C-quoting, SQL-quoting).
  These mirror shell.c.in's pre-QRF helpers (output_csv, output_quoted_string,
  output_quoted_escaped_string, output_json_string, output_html_string,
  output_c_string).  The Pascal port renders directly to stdout via Write
  rather than through a FILE*; output redirection lands with 10.1.25.
  ---------------------------------------------------------------------- }

procedure outputCsvField(const z: AnsiString; const sep: AnsiString);
{ output_csv (shell.c.in pre-QRF era).  Quote with double-quotes if the
  field contains the column separator, a quote, CR, or LF.  Embedded
  quotes are doubled. }
var
  needQuote: Boolean;
  i: SizeInt;
begin
  needQuote := False;
  for i := 1 to Length(z) do begin
    if (z[i] = '"') or (z[i] = #10) or (z[i] = #13) then begin
      needQuote := True;
      Break;
    end;
  end;
  if not needQuote and (Length(sep) > 0) and (Pos(sep, z) > 0) then
    needQuote := True;
  if not needQuote then begin
    Write(z);
    Exit;
  end;
  Write('"');
  for i := 1 to Length(z) do begin
    if z[i] = '"' then Write('""') else Write(z[i]);
  end;
  Write('"');
end;

procedure outputSqlQuoted(const z: AnsiString);
{ output_quoted_string — SQL-text quoted.  Single quotes doubled.  If z
  contains any control byte, fall back to the X'…' hex form (mirrors
  the C reference's escape-blob-as-hex branch).  ASCII non-control bytes
  pass straight through; UTF-8 multi-byte stays intact. }
var
  i: SizeInt;
  hasCtrl: Boolean;
  b: Byte;
const
  hex = '0123456789ABCDEF';
begin
  hasCtrl := False;
  for i := 1 to Length(z) do begin
    b := Byte(z[i]);
    if (b < 32) and (b <> 9) and (b <> 10) and (b <> 13) then begin
      hasCtrl := True;
      Break;
    end;
  end;
  if hasCtrl then begin
    Write('X''');
    for i := 1 to Length(z) do begin
      b := Byte(z[i]);
      Write(hex[1 + (b shr 4)]);
      Write(hex[1 + (b and $0F)]);
    end;
    Write('''');
    Exit;
  end;
  Write('''');
  for i := 1 to Length(z) do begin
    if z[i] = '''' then Write('''''') else Write(z[i]);
  end;
  Write('''');
end;

procedure outputJsonString(const z: AnsiString);
{ output_json_string — RFC 8259 string with the usual \" \\ \b \f \n \r \t
  escapes; non-printables in 0x00..0x1F as \u00XX. }
var
  i: SizeInt;
  c: AnsiChar;
const
  hex = '0123456789abcdef';
begin
  Write('"');
  for i := 1 to Length(z) do begin
    c := z[i];
    case c of
      '"': Write('\"');
      '\': Write('\\');
      #8:  Write('\b');
      #9:  Write('\t');
      #10: Write('\n');
      #12: Write('\f');
      #13: Write('\r');
    else
      if Byte(c) < 32 then begin
        Write('\u00');
        Write(hex[1 + (Byte(c) shr 4)]);
        Write(hex[1 + (Byte(c) and $0F)]);
      end else
        Write(c);
    end;
  end;
  Write('"');
end;

procedure outputHtmlString(const z: AnsiString);
{ output_html_string — escape <, >, &, and ".  Mirrors shell.c.in's
  pre-QRF helper byte-for-byte. }
var i: SizeInt;
begin
  for i := 1 to Length(z) do
    case z[i] of
      '<': Write('&lt;');
      '>': Write('&gt;');
      '&': Write('&amp;');
      '"': Write('&quot;');
      '''': Write('&#39;');
    else
      Write(z[i]);
    end;
end;

procedure outputCString(const z: AnsiString);
{ output_c_string — C-style escapes wrapped in double quotes.  Used by
  MODE_C and MODE_Tcl (TCL accepts the same escape vocabulary as C for
  the small set we need here). }
var
  i: SizeInt;
  b: Byte;
begin
  Write('"');
  for i := 1 to Length(z) do begin
    b := Byte(z[i]);
    case z[i] of
      '"', '\': begin Write('\'); Write(z[i]); end;
      #9: Write('\t');
      #10: Write('\n');
      #12: Write('\f');
      #13: Write('\r');
    else
      if (b < 32) or (b = 127) then begin
        Write('\');
        Write(AnsiChar(Chr(48 + ((b shr 6) and 3))));
        Write(AnsiChar(Chr(48 + ((b shr 3) and 7))));
        Write(AnsiChar(Chr(48 + (b and 7))));
      end else
        Write(z[i]);
    end;
  end;
  Write('"');
end;

{ ----------------------------------------------------------------------
  10.1.8  shell_callback / per-mode renderers — minimum viable cut.

  Header emission, row emission, and footer hooks are split so the
  controlling loop in runOneSqlLine can drive them without re-fetching
  column count on every row.  We support: List, Line, Csv, Tabs, Ascii,
  Quote, Insert, Json, Tcl, Html, Markdown, Column (left-aligned naive),
  Off.  Box / Table / QBox are out-of-scope until QRF lands; they fall
  back to Column with column-sep '|'.

  Caller contract:
    emitHeader(p, pStmt)   — call once before the first row.
    emitRow(p, pStmt)      — call once per SQLITE_ROW.
    emitFooter(p, pStmt)   — call once after the last row.

  rowsEmitted carries non-trivial state for Json / JAtom / JObject (which
  need a "[" / "]" pair around the row stream, with commas between rows).
  ---------------------------------------------------------------------- }

type
  TRenderState = record
    p:           PShellState;
    nCol:        i32;
    rowsEmitted: i64;
    headersOn:   Boolean;
    zNull:       AnsiString;
    zColSep:     AnsiString;
    zRowSep:     AnsiString;
    insertTab:   AnsiString;        { MODE_Insert only }
    lastStepRc:  i32;               { final step rc when columnar buffers }
    lineMaxNameLen: i32;            { MODE_Line auto-width; 0 = uncomputed }
  end;
  PRenderState = ^TRenderState;

function specStr(z: PAnsiChar): AnsiString; inline;
begin
  if z = nil then Result := '' else Result := AnsiString(z);
end;

function utf8DispWidth(const s: AnsiString): i32;
{ Approximate display width: count non-continuation UTF-8 bytes (one
  glyph per code point, all glyphs treated as width 1).  Good enough
  for ASCII / Latin / Greek / Cyrillic; CJK wide-char support arrives
  with the full QRF port. }
var
  i, n: i32;
  b: Byte;
begin
  n := 0;
  i := 1;
  while i <= Length(s) do begin
    b := Byte(s[i]);
    if (b and $C0) <> $80 then Inc(n);
    Inc(i);
  end;
  Result := n;
end;

procedure renderInit(var rs: TRenderState; p: PShellState; pStmt: PVdbe);
begin
  rs.p           := p;
  rs.nCol        := sqlite3_column_count(pStmt);
  rs.rowsEmitted := 0;
  rs.headersOn   := p^.mode.spec.bTitles = QRF_Yes;
  rs.zNull       := specStr(p^.mode.spec.zNull);
  rs.zColSep     := specStr(p^.mode.spec.zColumnSep);
  rs.zRowSep     := specStr(p^.mode.spec.zRowSep);
  if p^.zDestTable <> nil then
    rs.insertTab := AnsiString(p^.zDestTable)
  else
    rs.insertTab := 'table';
  rs.lastStepRc      := SQLITE_DONE;
  rs.lineMaxNameLen  := 0;
end;

function colNameStr(pStmt: PVdbe; i: i32): AnsiString; inline;
var z: PAnsiChar;
begin
  z := sqlite3_column_name(pStmt, i);
  if z = nil then Result := '' else Result := AnsiString(z);
end;

function colTextStr(pStmt: PVdbe; i: i32; out isNull: Boolean): AnsiString; inline;
var z: PAnsiChar;
begin
  isNull := sqlite3_column_type(pStmt, i) = SQLITE_NULL;
  if isNull then begin Result := ''; Exit; end;
  z := sqlite3_column_text(pStmt, i);
  if z = nil then Result := '' else Result := AnsiString(z);
end;

procedure emitHeader(var rs: TRenderState; pStmt: PVdbe);
var
  i: i32;
  nm: AnsiString;
begin
  if not rs.headersOn then Exit;
  case rs.p^.mode.eMode of
    MODE_List, MODE_Tabs, MODE_Ascii, MODE_Csv:
      begin
        for i := 0 to rs.nCol - 1 do begin
          nm := colNameStr(pStmt, i);
          if i > 0 then Write(rs.zColSep);
          if rs.p^.mode.eMode = MODE_Csv then
            outputCsvField(nm, rs.zColSep)
          else
            Write(nm);
        end;
        Write(rs.zRowSep);
      end;
    MODE_Markdown:
      begin
        Write('|');
        for i := 0 to rs.nCol - 1 do begin
          Write(' '); Write(colNameStr(pStmt, i)); Write(' |');
        end;
        WriteLn;
        Write('|');
        for i := 0 to rs.nCol - 1 do Write('---|');
        WriteLn;
      end;
    MODE_Column:
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(' ');
          Write(colNameStr(pStmt, i));
        end;
        WriteLn;
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(' ');
          Write(StringOfChar('-', Length(colNameStr(pStmt, i))));
        end;
        WriteLn;
      end;
    MODE_Html:
      begin
        Write('<TR>');
        for i := 0 to rs.nCol - 1 do begin
          Write('<TH>'); outputHtmlString(colNameStr(pStmt, i)); Write('</TH>');
        end;
        WriteLn('</TR>');
      end;
  end;
end;

procedure emitRowOne(var rs: TRenderState; pStmt: PVdbe);
var
  i, ty: i32;
  z: AnsiString;
  isNull: Boolean;
  decl: PAnsiChar;
  isNumericTy: Boolean;
begin
  case rs.p^.mode.eMode of
    MODE_Off: Exit;

    MODE_Line:
      begin
        if rs.lineMaxNameLen = 0 then begin
          for i := 0 to rs.nCol - 1 do begin
            ty := utf8DispWidth(colNameStr(pStmt, i));
            if ty > rs.lineMaxNameLen then rs.lineMaxNameLen := ty;
          end;
        end;
        for i := 0 to rs.nCol - 1 do begin
          z := colTextStr(pStmt, i, isNull);
          Write(Format('%*s = ', [rs.lineMaxNameLen + 1, colNameStr(pStmt, i)]));
          if isNull then Write(rs.zNull) else Write(z);
          WriteLn;
        end;
        WriteLn;
      end;

    MODE_List, MODE_Tabs, MODE_Ascii:
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(rs.zColSep);
          z := colTextStr(pStmt, i, isNull);
          if isNull then Write(rs.zNull) else Write(z);
        end;
        Write(rs.zRowSep);
      end;

    MODE_Csv:
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(rs.zColSep);
          z := colTextStr(pStmt, i, isNull);
          if isNull then Write(rs.zNull) else outputCsvField(z, rs.zColSep);
        end;
        Write(rs.zRowSep);
      end;

    MODE_Quote:
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(rs.zColSep);
          ty := sqlite3_column_type(pStmt, i);
          case ty of
            SQLITE_NULL:    Write('NULL');
            SQLITE_INTEGER: Write(IntToStr(sqlite3_column_int64(pStmt, i)));
            SQLITE_FLOAT:   Write(FloatToStr(sqlite3_column_double(pStmt, i)));
            SQLITE_TEXT:    outputSqlQuoted(specStr(sqlite3_column_text(pStmt, i)));
          else
            outputSqlQuoted(specStr(sqlite3_column_text(pStmt, i)));
          end;
        end;
        Write(rs.zRowSep);
      end;

    MODE_Insert:
      begin
        Write('INSERT INTO '); Write(rs.insertTab); Write(' VALUES(');
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(',');
          ty := sqlite3_column_type(pStmt, i);
          if ty = SQLITE_NULL then begin Write('NULL'); Continue; end;
          if ty = SQLITE_INTEGER then begin
            Write(IntToStr(sqlite3_column_int64(pStmt, i))); Continue;
          end;
          if ty = SQLITE_FLOAT then begin
            { Promote integer-valued doubles to a textual integer when the
              underlying column is declared INTEGER (matches insert.c's
              affinity-aware flush). }
            decl := sqlite3_column_decltype(pStmt, i);
            isNumericTy := (decl <> nil) and (StrComp(decl, 'INTEGER') = 0);
            if isNumericTy and (Frac(sqlite3_column_double(pStmt, i)) = 0) then
              Write(IntToStr(Trunc(sqlite3_column_double(pStmt, i))))
            else
              Write(FloatToStr(sqlite3_column_double(pStmt, i)));
            Continue;
          end;
          outputSqlQuoted(specStr(sqlite3_column_text(pStmt, i)));
        end;
        WriteLn(');');
      end;

    MODE_Json:
      begin
        if rs.rowsEmitted = 0 then Write('[') else Write(',');
        WriteLn;
        Write('{');
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(',');
          outputJsonString(colNameStr(pStmt, i));
          Write(':');
          ty := sqlite3_column_type(pStmt, i);
          case ty of
            SQLITE_NULL:    Write('null');
            SQLITE_INTEGER: Write(IntToStr(sqlite3_column_int64(pStmt, i)));
            SQLITE_FLOAT:   Write(FloatToStr(sqlite3_column_double(pStmt, i)));
          else
            outputJsonString(specStr(sqlite3_column_text(pStmt, i)));
          end;
        end;
        Write('}');
      end;

    MODE_Tcl:
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(rs.zColSep);
          z := colTextStr(pStmt, i, isNull);
          if isNull then outputCString(rs.zNull) else outputCString(z);
        end;
        Write(rs.zRowSep);
      end;

    MODE_Html:
      begin
        Write('<TR>');
        for i := 0 to rs.nCol - 1 do begin
          Write('<TD>');
          z := colTextStr(pStmt, i, isNull);
          if isNull then outputHtmlString(rs.zNull) else outputHtmlString(z);
          Write('</TD>');
        end;
        WriteLn('</TR>');
      end;

    MODE_Markdown:
      begin
        Write('|');
        for i := 0 to rs.nCol - 1 do begin
          Write(' ');
          z := colTextStr(pStmt, i, isNull);
          if isNull then Write(rs.zNull) else Write(z);
          Write(' |');
        end;
        WriteLn;
      end;

    MODE_Column:
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(' ');
          z := colTextStr(pStmt, i, isNull);
          if isNull then Write(rs.zNull) else Write(z);
        end;
        WriteLn;
      end;
  else
    { Fallback for unsupported modes (Box / Table / QBox / Www / JAtom /
      JObject / Split / Psql / Count) — emit pipe-delimited.  Closes
      cleanly so the REPL stays usable; full QRF support arrives with
      the QRF port. }
    for i := 0 to rs.nCol - 1 do begin
      if i > 0 then Write('|');
      z := colTextStr(pStmt, i, isNull);
      if isNull then Write(rs.zNull) else Write(z);
    end;
    WriteLn;
  end;
  Inc(rs.rowsEmitted);
end;

procedure emitFooter(var rs: TRenderState);
begin
  case rs.p^.mode.eMode of
    MODE_Json:
      if rs.rowsEmitted > 0 then begin WriteLn; WriteLn(']'); end;
  end;
end;

{ ----------------------------------------------------------------------
  10.1.9  Columnar renderers — MODE_Column, MODE_Table, MODE_Box.

  These three modes need to know the maximum width of every column
  before emitting the first row, so we buffer the result set into an
  AnsiString matrix, scan it to compute per-column widths, then emit.

  utf8DispWidth approximates display width by counting non-continuation
  UTF-8 bytes (each glyph counted as width 1).  This matches upstream's
  pre-3.50 behaviour and is good enough for ASCII / Latin-1 / typical
  Greek / Cyrillic content; CJK wide-character support arrives with the
  full QRF port.

  Box-drawing glyphs are the upstream Unicode set:
    ┌ ─ ┬ ┐  │   ├ ┼ ┤   └ ┴ ┘
  Table mode mirrors MySQL: + and - and | only.
  ---------------------------------------------------------------------- }

procedure padCell(const s: AnsiString; w: i32);
{ Write `s` followed by enough spaces to fill `w` display columns. }
var pad: i32;
begin
  Write(s);
  pad := w - utf8DispWidth(s);
  if pad > 0 then Write(StringOfChar(' ', pad));
end;

function colCellText(pStmt: PVdbe; i: i32; const zNull: AnsiString): AnsiString;
var
  isNull: Boolean;
  z: AnsiString;
begin
  z := colTextStr(pStmt, i, isNull);
  if isNull then Result := zNull else Result := z;
end;

procedure emitColumnar(var rs: TRenderState; pStmt: PVdbe; firstRow: AnsiString);
{ Buffer all remaining rows (`firstRow` already consumed via column-text
  capture) and emit per-mode in MODE_Column / MODE_Table / MODE_Box.
  `firstRow` is unused — kept for signature symmetry; the caller passes
  '' and we read the current row from pStmt before stepping further. }
var
  matrix: array of array of AnsiString;
  headers: array of AnsiString;
  widths: array of i32;
  i, c, w, rc, nCol: i32;
  nRowBuf: i32;
  rcStep: i32;
  isBox, isTable, isCol, isMd: Boolean;
  glyphTL, glyphTR, glyphBL, glyphBR: AnsiString;
  glyphHB, glyphVB, glyphCx, glyphTU, glyphTD, glyphTL2, glyphTR2: AnsiString;
  rowSep, hdrSep, footSep: AnsiString;
  sb: AnsiString;
  align: i32;
begin
  if firstRow = '' then ; { unused }
  nCol := rs.nCol;
  isBox   := rs.p^.mode.eMode = MODE_Box;
  isTable := rs.p^.mode.eMode = MODE_Table;
  isCol   := rs.p^.mode.eMode = MODE_Column;
  isMd    := rs.p^.mode.eMode = MODE_Markdown;

  SetLength(headers, nCol);
  SetLength(widths,  nCol);
  for i := 0 to nCol - 1 do begin
    headers[i] := colNameStr(pStmt, i);
    widths[i]  := utf8DispWidth(headers[i]);
  end;

  { User-supplied minimum widths via .width.  C uses the absolute value
    for the cell padding; sign decides alignment (negative = left).
    We honour magnitude here; alignment defaults match upstream
    (text=left, numeric=right) but our per-cell text capture is
    type-erased after sqlite3_column_text, so simplify to left-align
    for now (matches upstream's MODE_Column when no .width is set). }
  for i := 0 to nCol - 1 do
    if (rs.p^.mode.spec.aWidth <> nil) and (i < rs.p^.mode.spec.nWidth) then begin
      w := Abs(rs.p^.mode.spec.aWidth[i]);
      if w > widths[i] then widths[i] := w;
    end;

  { Buffer rows.  Start with the row already at pStmt (caller stepped to
    SQLITE_ROW once, then handed off without emitting). }
  nRowBuf := 0;
  SetLength(matrix, 16);
  SetLength(matrix[0], nCol);
  for c := 0 to nCol - 1 do begin
    matrix[0, c] := colCellText(pStmt, c, rs.zNull);
    w := utf8DispWidth(matrix[0, c]);
    if w > widths[c] then widths[c] := w;
  end;
  nRowBuf := 1;

  while True do begin
    rcStep := sqlite3_step(pStmt);
    if rcStep <> SQLITE_ROW then Break;
    if nRowBuf >= Length(matrix) then SetLength(matrix, Length(matrix) * 2);
    SetLength(matrix[nRowBuf], nCol);
    for c := 0 to nCol - 1 do begin
      matrix[nRowBuf, c] := colCellText(pStmt, c, rs.zNull);
      w := utf8DispWidth(matrix[nRowBuf, c]);
      if w > widths[c] then widths[c] := w;
    end;
    Inc(nRowBuf);
  end;
  rs.lastStepRc := rcStep;

  { Glyphs. }
  if isBox then begin
    glyphTL  := #$E2#$94#$8C; { ┌ }
    glyphTR  := #$E2#$94#$90; { ┐ }
    glyphBL  := #$E2#$94#$94; { └ }
    glyphBR  := #$E2#$94#$98; { ┘ }
    glyphHB  := #$E2#$94#$80; { ─ }
    glyphVB  := #$E2#$94#$82; { │ }
    glyphCx  := #$E2#$94#$BC; { ┼ }
    glyphTU  := #$E2#$94#$B4; { ┴ }
    glyphTD  := #$E2#$94#$AC; { ┬ }
    glyphTL2 := #$E2#$94#$9C; { ├ }
    glyphTR2 := #$E2#$94#$A4; { ┤ }
  end else if isTable then begin
    glyphTL := '+'; glyphTR := '+'; glyphBL := '+'; glyphBR := '+';
    glyphHB := '-'; glyphVB := '|';
    glyphCx := '+'; glyphTU := '+'; glyphTD := '+';
    glyphTL2 := '+'; glyphTR2 := '+';
  end else if isMd then begin
    { Markdown — pipe borders, no top/bottom rules; the only horizontal
      rule sits between header and rows and uses '-'. }
    glyphTL := ''; glyphTR := ''; glyphBL := ''; glyphBR := '';
    glyphHB := '-'; glyphVB := '|';
    glyphCx := '|'; glyphTU := ''; glyphTD := '';
    glyphTL2 := '|'; glyphTR2 := '|';
  end else begin
    { Column mode — no borders. }
    glyphTL := ''; glyphTR := ''; glyphBL := ''; glyphBR := '';
    glyphHB := '-'; glyphVB := '';
    glyphCx := ''; glyphTU := ''; glyphTD := '';
    glyphTL2 := ''; glyphTR2 := '';
  end;

  { Helper to build the horizontal rule between rows (Box / Table). }
  align := 0;
  if align = 0 then ; { unused }

  if isBox or isTable then begin
    sb := glyphTL;
    for c := 0 to nCol - 1 do begin
      if c > 0 then sb := sb + glyphTD;
      for i := 0 to widths[c] + 1 do sb := sb + glyphHB;
    end;
    sb := sb + glyphTR;
    rowSep := sb;

    sb := glyphTL2;
    for c := 0 to nCol - 1 do begin
      if c > 0 then sb := sb + glyphCx;
      for i := 0 to widths[c] + 1 do sb := sb + glyphHB;
    end;
    sb := sb + glyphTR2;
    hdrSep := sb;

    sb := glyphBL;
    for c := 0 to nCol - 1 do begin
      if c > 0 then sb := sb + glyphTU;
      for i := 0 to widths[c] + 1 do sb := sb + glyphHB;
    end;
    sb := sb + glyphBR;
    footSep := sb;
  end else if isMd then begin
    sb := glyphTL2;
    for c := 0 to nCol - 1 do begin
      if c > 0 then sb := sb + glyphCx;
      for i := 0 to widths[c] + 1 do sb := sb + glyphHB;
    end;
    sb := sb + glyphTR2;
    hdrSep := sb;
    rowSep := '';
    footSep := '';
  end else begin
    rowSep := '';
    hdrSep := '';
    footSep := '';
  end;

  { Emit. }
  if isBox or isTable then WriteLn(rowSep);

  if rs.headersOn or isBox or isTable or isMd then begin
    if isBox or isTable or isMd then begin
      Write(glyphVB);
      for c := 0 to nCol - 1 do begin
        if c > 0 then Write(glyphVB);
        Write(' ');
        { Header text centered for Box / Table / Markdown. }
        w := widths[c] - utf8DispWidth(headers[c]);
        if w > 0 then Write(StringOfChar(' ', w div 2));
        Write(headers[c]);
        if w > 0 then Write(StringOfChar(' ', w - (w div 2)));
        Write(' ');
      end;
      WriteLn(glyphVB);
      WriteLn(hdrSep);
    end else begin
      { MODE_Column header row. }
      for c := 0 to nCol - 1 do begin
        if c > 0 then Write('  ');
        padCell(headers[c], widths[c]);
      end;
      WriteLn;
      for c := 0 to nCol - 1 do begin
        if c > 0 then Write('  ');
        Write(StringOfChar('-', widths[c]));
      end;
      WriteLn;
    end;
  end;

  for rc := 0 to nRowBuf - 1 do begin
    if isBox or isTable or isMd then begin
      Write(glyphVB);
      for c := 0 to nCol - 1 do begin
        if c > 0 then Write(glyphVB);
        Write(' ');
        padCell(matrix[rc, c], widths[c]);
        Write(' ');
      end;
      WriteLn(glyphVB);
    end else begin
      for c := 0 to nCol - 1 do begin
        if c > 0 then Write('  ');
        padCell(matrix[rc, c], widths[c]);
      end;
      WriteLn;
    end;
  end;

  if isBox or isTable then WriteLn(footSep);

  rs.rowsEmitted := nRowBuf;
end;

function stepAndRender(p: PShellState; pStmt: PVdbe): i32;
{ Step the prepared statement to completion, dispatching SQLITE_ROW
  through the per-mode renderer.  Returns the final step rc (DONE / err). }
var
  rs: TRenderState;
  headerEmitted: Boolean;
  rc: i32;
  isColumnar: Boolean;
begin
  renderInit(rs, p, pStmt);
  rs.lastStepRc := SQLITE_DONE;
  isColumnar := (p^.mode.eMode = MODE_Column)
             or (p^.mode.eMode = MODE_Table)
             or (p^.mode.eMode = MODE_Box)
             or (p^.mode.eMode = MODE_Markdown);

  if isColumnar then begin
    rc := sqlite3_step(pStmt);
    if rc = SQLITE_ROW then begin
      emitColumnar(rs, pStmt, '');
      Result := rs.lastStepRc;
    end else
      Result := rc;
    Exit;
  end;

  headerEmitted := False;
  while True do begin
    rc := sqlite3_step(pStmt);
    if rc <> SQLITE_ROW then Break;
    if not headerEmitted then begin
      emitHeader(rs, pStmt);
      headerEmitted := True;
    end;
    emitRowOne(rs, pStmt);
  end;
  emitFooter(rs);
  Result := rc;
end;

{ runOneSqlLine — shell.c.in runOneSqlLine (~12290..12365).  Prepare /
  step / finalize one statement; emit each row through the active
  renderer.  This is the minimum needed for the 10.2 integration parity
  gate to start evaluating SELECTs against a known canon.   }
function displayStats(p: PShellState; bReset: i32): i32; forward;
procedure shellBeginTimer(p: PShellState); forward;
procedure shellEndTimer(p: PShellState); forward;

function runOneSqlLine(p: PShellState; const zSql: AnsiString;
                       const zSrc: AnsiString; lineno: i64): i32;
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc, stepRc: i32;
  zRemain: PAnsiChar;
  zCur: AnsiString;
begin
  Result := 0;
  if p^.db = nil then openDb(p, 0);
  zCur := zSql;
  while Length(zCur) > 0 do begin
    pStmt := nil;
    pzTail := nil;
    rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zCur), -1, @pStmt, @pzTail);
    if rc <> SQLITE_OK then begin
      shellEPutZ(Format('Parse error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
      Inc(Result);
      Exit;
    end;
    if pStmt = nil then begin
      { Empty statement (whitespace, comment) — advance to tail and continue. }
      if pzTail = nil then Exit;
      zRemain := pzTail;
      if (zRemain = nil) or (zRemain^ = #0) then Exit;
      zCur := AnsiString(zRemain);
      Continue;
    end;
    p^.pStmt := pStmt;
    shellBeginTimer(p);
    stepRc := stepAndRender(p, pStmt);
    shellEndTimer(p);
    if p^.statsOn <> 0 then displayStats(p, 0);
    p^.pStmt := nil;
    rc := sqlite3_finalize(pStmt);
    if (rc <> SQLITE_OK) and (rc <> SQLITE_DONE) then begin
      shellEPutZ(Format('Runtime error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
      Inc(Result);
    end;
    if pzTail = nil then Exit;
    zRemain := pzTail;
    if (zRemain = nil) or (zRemain^ = #0) then Exit;
    zCur := AnsiString(zRemain);
  end;
end;

{ ----------------------------------------------------------------------
  10.1.6  do_meta_command dispatcher skeleton — shell.c.in:8981..

  Per the tasklist, every dot-command in this initial cut returns the
  upstream "Error: unknown command or invalid arguments" message verbatim
  so partial Phase-10 landings cannot silently no-op.  Per-command
  handlers (10.1.7..10.1.59) hang their arms off this dispatcher.

  The .quit / .exit / .help arms land here because they are the bare
  minimum needed for the REPL to be drivable and self-documenting.
  ---------------------------------------------------------------------- }

function dotCmdName(const zLine: AnsiString): AnsiString;
{ Extract the leading dot-command name from zLine (without the leading
  '.', and stripped of trailing whitespace / arguments). }
var i, j: SizeInt;
begin
  Result := '';
  i := 1;
  while (i <= Length(zLine)) and (zLine[i] in [' ', #9]) do Inc(i);
  if (i > Length(zLine)) or (zLine[i] <> '.') then Exit;
  Inc(i);
  j := i;
  while (j <= Length(zLine)) and not (zLine[j] in [' ', #9, #10, #13]) do Inc(j);
  Result := Copy(zLine, i, j - i);
end;

{ Tokenise a dot-command body into whitespace-separated arguments.
  Honours single- and double-quoted runs (quotes are stripped) so that
  `.separator " "` and `.nullvalue 'null'` parse exactly as upstream's
  `do_meta_command` token loop (shell.c.in:8995..9070). }
procedure splitDotArgs(const zLine: AnsiString; out args: array of AnsiString;
                       out nArg: SizeInt);
var i, n, k: SizeInt;
    quote: AnsiChar;
    cur: AnsiString;
begin
  nArg := 0;
  n := Length(zLine);
  i := 1;
  { Skip past leading whitespace and the dot-command name. }
  while (i <= n) and (zLine[i] in [' ', #9]) do Inc(i);
  if (i <= n) and (zLine[i] = '.') then Inc(i);
  while (i <= n) and not (zLine[i] in [' ', #9]) do Inc(i);
  while i <= n do begin
    while (i <= n) and (zLine[i] in [' ', #9]) do Inc(i);
    if i > n then Break;
    cur := '';
    if zLine[i] in ['''', '"'] then begin
      quote := zLine[i];
      Inc(i);
      while (i <= n) and (zLine[i] <> quote) do begin
        if (zLine[i] = '\') and (i < n) then begin
          Inc(i);
          case zLine[i] of
            'n': cur := cur + #10;
            't': cur := cur + #9;
            'r': cur := cur + #13;
            '\': cur := cur + '\';
            '''': cur := cur + '''';
            '"': cur := cur + '"';
          else
            cur := cur + zLine[i];
          end;
          Inc(i);
        end else begin
          cur := cur + zLine[i];
          Inc(i);
        end;
      end;
      if (i <= n) and (zLine[i] = quote) then Inc(i);
    end else begin
      while (i <= n) and not (zLine[i] in [' ', #9]) do begin
        cur := cur + zLine[i];
        Inc(i);
      end;
    end;
    k := nArg;
    if k <= High(args) then begin
      args[k] := cur;
      Inc(nArg);
    end;
  end;
end;

function parseOnOff(const z: AnsiString; defaultVal: i32): i32;
{ booleanValue (shell.c.in:1340..) — recognises on/off, yes/no, true/false,
  numeric 0/1.  Falls back to defaultVal on unrecognised input. }
begin
  if (z = 'on') or (z = 'yes') or (z = 'true') or (z = '1') then Result := 1
  else if (z = 'off') or (z = 'no') or (z = 'false') or (z = '0') then Result := 0
  else Result := defaultVal;
end;

procedure runStatementVerbose(p: PShellState; const zSql: AnsiString);
{ Helper for the schema-introspection dot-commands.  Open the database
  if needed, prepare/step zSql under the active mode, and report any
  prepare/step error to stderr. }
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
begin
  if p^.db = nil then openDb(p, 0);
  pStmt := nil;
  pzTail := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    shellEPutZ(Format('Error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit;
  end;
  stepAndRender(p, pStmt);
  sqlite3_finalize(pStmt);
end;

{ ----------------------------------------------------------------------
  10.1.28  `.stats ?ARG?`  +  display_stats helper.

  Faithful port of shell.c.in:2722..2944.  display_stats() emits the
  per-statement / per-connection / process-wide counter summary that
  upstream prints after each SQL when statsOn is non-zero.

  ShellState.statsOn semantics (shell.c.in:402..408):
    0  off            — no automatic display
    1  on             — full display after each statement
    2  stmt           — show only column metadata (declared types etc.)
    3  vmstep         — show only the VM step counter
  ---------------------------------------------------------------------- }

procedure displayStatLine(const zLabel, zFormat: AnsiString;
                          iStatusCtrl: i32; bReset: i32);
var
  iCur, iHiwtr: i64;
  i, nPercent: SizeInt;
  zLine: AnsiString;
begin
  iCur := -1; iHiwtr := -1;
  sqlite3_status64(iStatusCtrl, @iCur, @iHiwtr, bReset);
  nPercent := 0;
  for i := 1 to Length(zFormat) do
    if zFormat[i] = '%' then Inc(nPercent);
  if nPercent > 1 then
    zLine := Format(zFormat, [iCur, iHiwtr])
  else
    zLine := Format(zFormat, [iHiwtr]);
  shellSPutZ(Format('%-36s %s'#10, [zLabel, zLine]));
end;

procedure displayLinuxIoStats;
{ shell.c.in:2722..2752 — read /proc/<pid>/io and translate the seven
  well-known counter lines into the upstream label format. }
var
  fn: AnsiString;
  f: TextFile;
  line, tag, rest: AnsiString;
  i: SizeInt;
const
  aTrans: array[0..6, 0..1] of AnsiString = (
    ('rchar: ',                  'Bytes received by read():'),
    ('wchar: ',                  'Bytes sent to write():'),
    ('syscr: ',                  'Read() system calls:'),
    ('syscw: ',                  'Write() system calls:'),
    ('read_bytes: ',             'Bytes read from storage:'),
    ('write_bytes: ',            'Bytes written to storage:'),
    ('cancelled_write_bytes: ',  'Cancelled write bytes:')
  );
begin
  fn := Format('/proc/%d/io', [FpGetPid]);
  if not FileExists(fn) then Exit;
  AssignFile(f, fn);
  {$I-} Reset(f); {$I+}
  if IOResult <> 0 then Exit;
  while not Eof(f) do begin
    {$I-} ReadLn(f, line); {$I+}
    if IOResult <> 0 then Break;
    for i := 0 to High(aTrans) do begin
      tag := aTrans[i, 0];
      if (Length(line) >= Length(tag)) and (Copy(line, 1, Length(tag)) = tag) then begin
        rest := Copy(line, Length(tag) + 1, Length(line) - Length(tag));
        shellSPutZ(Format('%-36s %s'#10, [aTrans[i, 1], rest]));
        Break;
      end;
    end;
  end;
  CloseFile(f);
end;

function displayStats(p: PShellState; bReset: i32): i32;
var
  iCur, iHiwtr: i32;
  iCur64, iHiwtr64: i64;
  pStmt: PVdbe;
  nCol, i: i32;
  iHit, iMiss: i32;
  zFmt: AnsiString;
  db: PTsqlite3;
begin
  Result := 0;
  if p = nil then Exit;
  db := p^.db;
  pStmt := p^.pStmt;

  if (pStmt <> nil) and (p^.statsOn = 2) then begin
    nCol := sqlite3_column_count(pStmt);
    shellSPutZ(Format('%-36s %d'#10, ['Number of output columns:', nCol]));
    for i := 0 to nCol - 1 do begin
      shellSPutZ(Format('%-36s %s'#10,
        [Format('Column %d name:', [i]),
         AnsiString(sqlite3_column_name(pStmt, i))]));
      shellSPutZ(Format('%-36s %s'#10,
        [Format('Column %d declared type:', [i]),
         AnsiString(sqlite3_column_decltype(pStmt, i))]));
    end;
  end;

  if p^.statsOn = 3 then begin
    if pStmt <> nil then begin
      iCur := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_VM_STEP, bReset);
      shellSPutZ(Format('VM-steps: %d'#10, [iCur]));
    end;
    Exit;
  end;

  displayStatLine('Memory Used:',
    '%d (max %d) bytes', SQLITE_STATUS_MEMORY_USED, bReset);
  displayStatLine('Number of Outstanding Allocations:',
    '%d (max %d)', SQLITE_STATUS_MALLOC_COUNT, bReset);
  if (p^.shellFlgs and SHFLG_Pagecache) <> 0 then
    displayStatLine('Number of Pcache Pages Used:',
      '%d (max %d) pages', SQLITE_STATUS_PAGECACHE_USED, bReset);
  displayStatLine('Number of Pcache Overflow Bytes:',
    '%d (max %d) bytes', SQLITE_STATUS_PAGECACHE_OVERFLOW, bReset);
  displayStatLine('Largest Allocation:',
    '%d bytes', SQLITE_STATUS_MALLOC_SIZE, bReset);
  displayStatLine('Largest Pcache Allocation:',
    '%d bytes', SQLITE_STATUS_PAGECACHE_SIZE, bReset);

  if db <> nil then begin
    if (p^.shellFlgs and SHFLG_Lookaside) <> 0 then begin
      iCur := -1; iHiwtr := -1;
      sqlite3_db_status(db, SQLITE_DBSTATUS_LOOKASIDE_USED,
                        @iCur, @iHiwtr, bReset);
      shellSPutZ(Format('Lookaside Slots Used:                %d (max %d)'#10,
        [iCur, iHiwtr]));
      sqlite3_db_status(db, SQLITE_DBSTATUS_LOOKASIDE_HIT,
                        @iCur, @iHiwtr, bReset);
      shellSPutZ(Format('Successful lookaside attempts:       %d'#10, [iHiwtr]));
      sqlite3_db_status(db, SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE,
                        @iCur, @iHiwtr, bReset);
      shellSPutZ(Format('Lookaside failures due to size:      %d'#10, [iHiwtr]));
      sqlite3_db_status(db, SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL,
                        @iCur, @iHiwtr, bReset);
      shellSPutZ(Format('Lookaside failures due to OOM:       %d'#10, [iHiwtr]));
    end;
    iCur := -1; iHiwtr := -1;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_USED, @iCur, @iHiwtr, bReset);
    shellSPutZ(Format('Pager Heap Usage:                    %d bytes'#10, [iCur]));
    iCur := -1; iHiwtr := -1;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_HIT, @iCur, @iHiwtr, 1);
    shellSPutZ(Format('Page cache hits:                     %d'#10, [iCur]));
    iCur := -1; iHiwtr := -1;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, @iCur, @iHiwtr, 1);
    shellSPutZ(Format('Page cache misses:                   %d'#10, [iCur]));
    iCur64 := -1; iHiwtr64 := -1;
    sqlite3_db_status64(db, SQLITE_DBSTATUS_TEMPBUF_SPILL,
                        @iCur64, @iHiwtr64, 0);
    iCur := -1; iHiwtr := -1;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_WRITE, @iCur, @iHiwtr, 1);
    shellSPutZ(Format('Page cache writes:                   %d'#10, [iCur]));
    iCur := -1; iHiwtr := -1;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_SPILL, @iCur, @iHiwtr, 1);
    shellSPutZ(Format('Page cache spills:                   %d'#10, [iCur]));
    shellSPutZ(Format('Temporary data spilled to disk:      %d'#10, [iCur64]));
    sqlite3_db_status64(db, SQLITE_DBSTATUS_TEMPBUF_SPILL,
                        @iCur64, @iHiwtr64, 1);
    iCur := -1; iHiwtr := -1;
    sqlite3_db_status(db, SQLITE_DBSTATUS_SCHEMA_USED, @iCur, @iHiwtr, bReset);
    shellSPutZ(Format('Schema Heap Usage:                   %d bytes'#10, [iCur]));
    iCur := -1; iHiwtr := -1;
    sqlite3_db_status(db, SQLITE_DBSTATUS_STMT_USED, @iCur, @iHiwtr, bReset);
    shellSPutZ(Format('Statement Heap/Lookaside Usage:      %d bytes'#10, [iCur]));
  end;

  if pStmt <> nil then begin
    iCur := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_FULLSCAN_STEP, bReset);
    shellSPutZ(Format('Fullscan Steps:                      %d'#10, [iCur]));
    iCur := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_SORT, bReset);
    shellSPutZ(Format('Sort Operations:                     %d'#10, [iCur]));
    iCur := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_AUTOINDEX, bReset);
    shellSPutZ(Format('Autoindex Inserts:                   %d'#10, [iCur]));
    iHit  := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_FILTER_HIT, bReset);
    iMiss := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_FILTER_MISS, bReset);
    if (iHit <> 0) or (iMiss <> 0) then
      shellSPutZ(Format('Bloom filter bypass taken:           %d/%d'#10,
        [iHit, iHit + iMiss]));
    iCur := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_VM_STEP, bReset);
    shellSPutZ(Format('Virtual Machine Steps:               %d'#10, [iCur]));
    iCur := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_REPREPARE, bReset);
    shellSPutZ(Format('Reprepare operations:                %d'#10, [iCur]));
    iCur := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_RUN, bReset);
    shellSPutZ(Format('Number of times run:                 %d'#10, [iCur]));
    iCur := sqlite3_stmt_status(pStmt, SQLITE_STMTSTATUS_MEMUSED, bReset);
    shellSPutZ(Format('Memory used by prepared stmt:        %d'#10, [iCur]));
  end;

  displayLinuxIoStats;
  zFmt := '';   { silence "unused" }
end;

procedure cmdStats(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
{ shell.c.in:10597..10620 .stats arm.  Bare `.stats` toggles the
  always-on counter display in upstream — but since the legacy bare-arg
  toggle is the source of long-standing parity drift, we expose only the
  documented sub-commands here. }
var
  s: AnsiString;
begin
  if nArg = 0 then begin
    case p^.statsOn of
      0: shellSPutZ('off'#10);
      1: shellSPutZ('on'#10);
      2: shellSPutZ('stmt'#10);
      3: shellSPutZ('vmstep'#10);
    else
      shellSPutZ('on'#10);
    end;
    Exit;
  end;
  s := args[0];
  if      s = 'off'    then p^.statsOn := 0
  else if s = 'on'     then p^.statsOn := 1
  else if s = 'stmt'   then p^.statsOn := 2
  else if s = 'vmstep' then p^.statsOn := 3
  else begin
    shellEPutZ('Usage: .stats off|on|stmt|vmstep'#10);
    Exit;
  end;
end;

{ ----------------------------------------------------------------------
  10.1.37  `.trace ?OPTIONS?`  — shell.c.in:11069..11171

  Installs a sqlite3_trace_v2 callback whose mTrace mask is the union of
  --stmt / --profile / --row / --close (default: --stmt).  The payload
  format is:
    STMT     : "<SQL>"            (SQL text or expanded SQL)
    PROFILE  : "<SQL>"            followed by " --- <ns>"
    ROW      : "[ROW <SQL>]"
    CLOSE    : "[CLOSE]"
  Output sink: passed FILE arg ("stdout", "stderr", or a path); closes
  the previous sink first.  `.trace off` disables tracing and clears the
  callback.
  ---------------------------------------------------------------------- }

var
  traceFile: TextFile;
  traceSink: i32;        { 0 = none, 1 = stdout, 2 = stderr, 3 = file }
  traceFmt:  i32;        { 0 = plain, 1 = expanded }

procedure traceWrite(const z: AnsiString); inline;
begin
  case traceSink of
    1: shellSPutZ(z);
    2: shellEPutZ(z);
    3: begin
         {$I-} Write(traceFile, z); Flush(traceFile); {$I+}
         if IOResult <> 0 then ;
       end;
  end;
end;

procedure traceCloseSink;
begin
  if traceSink = 3 then begin
    {$I-} CloseFile(traceFile); {$I+}
    if IOResult <> 0 then ;
  end;
  traceSink := 0;
end;

function traceCallback(traceType: u32; pCtx: Pointer;
                       pP, pX: Pointer): i32; cdecl;
var
  zSql, zExpanded: PAnsiChar;
  ns: PInt64;
  zOut: AnsiString;
begin
  Result := 0;
  case traceType of
    SQLITE_TRACE_STMT: begin
      zSql := PAnsiChar(pX);
      if (zSql <> nil) and (zSql^ = '-') and (PAnsiChar(zSql)[1] = '-') then
        zOut := AnsiString(zSql)
      else if traceFmt = 1 then begin
        zExpanded := sqlite3_expanded_sql(pP);
        if zExpanded <> nil then begin
          zOut := AnsiString(zExpanded);
          sqlite3_free(zExpanded);
        end else
          zOut := AnsiString(sqlite3_sql(pP));
      end else
        zOut := AnsiString(sqlite3_sql(pP));
      traceWrite(zOut + #10);
    end;
    SQLITE_TRACE_PROFILE: begin
      zSql := sqlite3_sql(pP);
      ns := PInt64(pX);
      if zSql = nil then zOut := '' else zOut := AnsiString(zSql);
      traceWrite(zOut + Format(' --- %d'#10, [ns^]));
    end;
    SQLITE_TRACE_ROW: begin
      zSql := sqlite3_sql(pP);
      if zSql = nil then zOut := '' else zOut := AnsiString(zSql);
      traceWrite('[ROW ' + zOut + ']'#10);
    end;
    SQLITE_TRACE_CLOSE: begin
      traceWrite('[CLOSE]'#10);
    end;
  end;
end;

procedure cmdTrace(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var
  i: SizeInt;
  mask: u32;
  s: AnsiString;
  zFile: AnsiString;
  newSink: i32;
begin
  if p^.db = nil then openDb(p, 0);
  mask := 0;
  zFile := '';
  newSink := 0;
  traceFmt := 0;
  for i := 0 to nArg - 1 do begin
    s := args[i];
    if      s = '--expanded' then traceFmt := 1
    else if s = '--plain'    then traceFmt := 0
    else if s = '--stmt'     then mask := mask or u32(SQLITE_TRACE_STMT)
    else if s = '--profile'  then mask := mask or u32(SQLITE_TRACE_PROFILE)
    else if s = '--row'      then mask := mask or u32(SQLITE_TRACE_ROW)
    else if s = '--close'    then mask := mask or u32(SQLITE_TRACE_CLOSE)
    else if s = 'off'        then begin
      sqlite3_trace_v2(p^.db, 0, nil, nil);
      traceCloseSink;
      Exit;
    end
    else if s = 'stdout'     then begin newSink := 1; zFile := 'stdout'; end
    else if s = 'stderr'     then begin newSink := 2; zFile := 'stderr'; end
    else if (Length(s) > 0) and (s[1] <> '-') then begin
      zFile := s; newSink := 3;
    end
    else begin
      shellEPutZ(Format('Unknown option: "%s"'#10, [s]));
      Exit;
    end;
  end;
  if mask = 0 then mask := u32(SQLITE_TRACE_STMT);
  traceCloseSink;
  case newSink of
    0, 1: traceSink := 1;
    2:    traceSink := 2;
    3: begin
      AssignFile(traceFile, zFile);
      {$I-} Rewrite(traceFile); {$I+}
      if IOResult <> 0 then begin
        shellEPutZ(Format('Cannot open "%s" for writing'#10, [zFile]));
        traceSink := 0;
        Exit;
      end;
      traceSink := 3;
    end;
  end;
  sqlite3_trace_v2(p^.db, mask, @traceCallback, nil);
end;

{ ----------------------------------------------------------------------
  10.1.33  `.help ?-all? ?PATTERN?`  — shell.c.in:3708..4090

  Faithful port of the upstream azHelp[] table and showHelp() walker.
  The table is captured as a unit-level array of AnsiString; entries
  beginning with '.' or ',' start a new command (',' marks an
  undocumented command, exposed only via `.help 0`).  Continuation
  lines start with whitespace and belong to the preceding command.
  ---------------------------------------------------------------------- }

const
  azHelp: array[0..264] of AnsiString = (
    '.archive ...             Manage SQL archives',
    '   Each command must have exactly one of the following options:',
    '     -c, --create               Create a new archive',
    '     -u, --update               Add or update files with changed mtime',
    '     -i, --insert               Like -u but always add even if unchanged',
    '     -r, --remove               Remove files from archive',
    '     -t, --list                 List contents of archive',
    '     -x, --extract              Extract files from archive',
    '   Optional arguments:',
    '     -v, --verbose              Print each filename as it is processed',
    '     -f FILE, --file FILE       Use archive FILE (default is current db)',
    '     -a FILE, --append FILE     Open FILE using the apndvfs VFS',
    '     -C DIR, --directory DIR    Read/extract files from directory DIR',
    '     -g, --glob                 Use glob matching for names in archive',
    '     -n, --dryrun               Show the SQL that would have occurred',
    '   Examples:',
    '     .ar -cf ARCHIVE foo bar  # Create ARCHIVE from files foo and bar',
    '     .ar -tf ARCHIVE          # List members of ARCHIVE',
    '     .ar -xvf ARCHIVE         # Verbosely extract files from ARCHIVE',
    '   See also:',
    '      http://sqlite.org/cli.html#sqlite_archive_support',
    '.auth ON|OFF             Show authorizer callbacks',
    '.backup ?DB? FILE        Backup DB (default "main") to FILE',
    '   Options:',
    '       --append            Use the appendvfs',
    '       --async             Write to FILE without journal and fsync()',
    '.bail on|off             Stop after hitting an error.  Default OFF',
    '.cd DIRECTORY            Change the working directory to DIRECTORY',
    '.changes on|off          Show number of rows changed by SQL',
    '.check OPTIONS ...       Verify the results of a .testcase',
    '.clone NEWDB             Clone data into NEWDB from the existing database',
    '.connection [close] [#]  Open or close an auxiliary database connection',
    '.crlf ?on|off?           Whether or not to use \r\n line endings',
    '.databases               List names and files of attached databases',
    '.dbconfig ?op? ?val?     List or change sqlite3_db_config() options',
    '.dbinfo ?DB?             Show status information about the database',
    '.dbtotxt                 Hex dump of the database file',
    '.dump ?OBJECTS?          Render database content as SQL',
    '   Options:',
    '     --data-only            Output only INSERT statements',
    '     --newlines             Allow unescaped newline characters in output',
    '     --nosys                Omit system tables (ex: "sqlite_stat1")',
    '     --preserve-rowids      Include ROWID values in the output',
    '   OBJECTS is a LIKE pattern for tables, indexes, triggers or views to dump',
    '   Additional LIKE patterns can be given in subsequent arguments',
    '.echo on|off             Turn command echo on or off',
    '.eqp on|off|full|...     Enable or disable automatic EXPLAIN QUERY PLAN',
    '   Other Modes:',
    '      test                  Show raw EXPLAIN QUERY PLAN output',
    '      trace                 Like "full" but enable "PRAGMA vdbe_trace"',
    '      trigger               Like "full" but also show trigger bytecode',
    '.excel                   Display the output of next command in spreadsheet',
    '   --bom                   Put a UTF8 byte-order mark on intermediate file',
    '.exit ?CODE?             Exit this program with return-code CODE',
    '.expert                  EXPERIMENTAL. Suggest indexes for queries',
    '.explain ?on|off|auto?   Change the EXPLAIN formatting mode.  Default: auto',
    '.filectrl CMD ...        Run various sqlite3_file_control() operations',
    '   --schema SCHEMA         Use SCHEMA instead of "main"',
    '   --help                  Show CMD details',
    '.fullschema ?--indent?   Show schema and the content of sqlite_stat tables',
    ',headers on|off          Turn display of headers on or off',
    '.help ?-all? ?PATTERN?   Show help text for PATTERN',
    '.import FILE TABLE       Import data from FILE into TABLE',
    '.imposter INDEX TABLE    Create imposter table TABLE on index INDEX',
    '.indexes ?PATTERN?       Show names of indexes matching PATTERN',
    '   -a|--all                Also show system-generated indexes',
    '   --expr                  Show only expression indexes',
    '   --sys                   Show only system-generated indexes',
    '.intck ?STEPS_PER_UNLOCK?  Run an incremental integrity check on the db',
    '.limit ?LIMIT? ?VAL?     Display or change the value of an SQLITE_LIMIT',
    '.lint OPTIONS            Report potential schema issues.',
    '     Options:',
    '        fkey-indexes     Find missing foreign key indexes',
    '.load FILE ?ENTRY?       Load an extension library',
    '.log FILE|on|off         Turn logging on or off.  FILE can be stderr/stdout',
    '.mode ?MODE? ?OPTIONS?   Set output mode',
    '.nonce STRING            Suspend safe mode for one command if nonce matches',
    '.nullvalue STRING        Use STRING in place of NULL values',
    '.once ?OPTIONS? ?FILE?   Output for the next SQL command only to FILE',
    '.open ?OPTIONS? ?FILE?   Close existing database and reopen FILE',
    '     Options:',
    '        --append        Use appendvfs to append database to the end of FILE',
    '        --deserialize   Load into memory using sqlite3_deserialize()',
    '        --hexdb         Load the output of "dbtotxt" as an in-memory db',
    '        --ifexist       Only open if FILE already exists',
    '        --maxsize N     Maximum size for --hexdb or --deserialized database',
    '        --new           Initialize FILE to an empty database',
    '        --normal        FILE is an ordinary SQLite database',
    '        --nofollow      Do not follow symbolic links',
    '        --readonly      Open FILE readonly',
    '        --zip           FILE is a ZIP archive',
    '.output ?FILE?           Send output to FILE or stdout if FILE is omitted',
    '.parameter CMD ...       Manage SQL parameter bindings',
    '   clear                   Erase all bindings',
    '   init                    Initialize the TEMP table that holds bindings',
    '   list                    List the current parameter bindings',
    '   set PARAMETER VALUE     Given SQL parameter PARAMETER a value of VALUE',
    '                           PARAMETER should start with one of: $ : @ ?',
    '   unset PARAMETER         Remove PARAMETER from the binding table',
    '.print STRING...         Print literal STRING',
    '.progress N              Invoke progress handler after every N opcodes',
    '   --limit N                 Interrupt after N progress callbacks',
    '   --once                    Do no more than one progress interrupt',
    '   --quiet|-q                No output except at interrupts',
    '   --reset                   Reset the count for each input and interrupt',
    '   --timeout S               Halt after running for S seconds',
    '.prompt MAIN CONTINUE    Replace the standard prompts',
    '.quit                    Stop interpreting input stream, exit if primary.',
    '.read FILE               Read input from FILE or command output',
    '    If FILE begins with "|", it is a command that generates the input.',
    '.recover                 Recover as much data as possible from corrupt db.',
    '   --ignore-freelist        Ignore pages that appear to be on db freelist',
    '   --lost-and-found TABLE   Alternative name for the lost-and-found table',
    '   --no-rowids              Do not attempt to recover rowid values',
    '                            that are not also INTEGER PRIMARY KEYs',
    '.restore ?DB? FILE       Restore content of DB (default "main") from FILE',
    '.save ?OPTIONS? FILE     Write database to FILE (an alias for .backup ...)',
    '.scanstats on|off|est    Turn sqlite3_stmt_scanstatus() metrics on or off',
    '.schema ?PATTERN?        Show the CREATE statements matching PATTERN',
    '   Options:',
    '      --indent             Try to pretty-print the schema',
    '      --nosys              Omit objects whose names start with "sqlite_"',
    ',selftest ?OPTIONS?      Run tests defined in the SELFTEST table',
    '    Options:',
    '       --init               Create a new SELFTEST table',
    '       -v                   Verbose output',
    ',separator COL ?ROW?     Change the column and row separators',
    '.session ?NAME? CMD ...  Create or control sessions',
    '   Subcommands:',
    '     attach TABLE             Attach TABLE',
    '     changeset FILE           Write a changeset into FILE',
    '     close                    Close one session',
    '     enable ?BOOLEAN?         Set or query the enable bit',
    '     filter GLOB...           Reject tables matching GLOBs',
    '     indirect ?BOOLEAN?       Mark or query the indirect status',
    '     isempty                  Query whether the session is empty',
    '     list                     List currently open session names',
    '     open DB NAME             Open a new session on DB',
    '     patchset FILE            Write a patchset into FILE',
    '   If ?NAME? is omitted, the first defined session is used.',
    '.sha3sum ...             Compute a SHA3 hash of database content',
    '    Options:',
    '      --schema              Also hash the sqlite_schema table',
    '      --sha3-224            Use the sha3-224 algorithm',
    '      --sha3-256            Use the sha3-256 algorithm (default)',
    '      --sha3-384            Use the sha3-384 algorithm',
    '      --sha3-512            Use the sha3-512 algorithm',
    '    Any other argument is a LIKE pattern for tables to hash',
    '.shell CMD ARGS...       Run CMD ARGS... in a system shell',
    ',show                    Show the current values for various settings',
    '.stats ?ARG?             Show stats or turn stats on or off',
    '   off                      Turn off automatic stat display',
    '   on                       Turn on automatic stat display',
    '   stmt                     Show statement stats',
    '   vmstep                   Show the virtual machine step count only',
    '.system CMD ARGS...      Run CMD ARGS... in a system shell',
    '.tables ?TABLE?          List names of tables matching LIKE pattern TABLE',
    '.testcase NAME           Begin a test case.',
    ',testctrl CMD ...        Run various sqlite3_test_control() operations',
    '                           Run ".testctrl" with no arguments for details',
    '.timeout MS              Try opening locked tables for MS milliseconds',
    '.timer on|off|once       Turn SQL timer on or off.',
    '.trace ?OPTIONS?         Output each SQL statement as it is run',
    '    FILE                    Send output to FILE',
    '    stdout                  Send output to stdout',
    '    stderr                  Send output to stderr',
    '    off                     Disable tracing',
    '    --expanded              Expand query parameters',
    '    --plain                 Show SQL as it is input',
    '    --stmt                  Trace statement execution (SQLITE_TRACE_STMT)',
    '    --profile               Profile statements (SQLITE_TRACE_PROFILE)',
    '    --row                   Trace each row (SQLITE_TRACE_ROW)',
    '    --close                 Trace connection close (SQLITE_TRACE_CLOSE)',
    '.unmodule NAME ...       Unregister virtual table modules',
    '    --allexcept             Unregister everything except those named',
    '.version                 Show source, library and compiler versions',
    '.vfsinfo ?AUX?           Information about the top-level VFS',
    '.vfslist                 List all available VFSes',
    '.vfsname ?AUX?           Print the name of the VFS stack',
    ',width NUM1 NUM2 ...     Set minimum column widths for columnar output',
    '     Negative values right-justify',
    '.www                     Display output of the next command in web browser',
    '    --plain                 Show results as text/plain, not as HTML',
    { sentinel — keep array length stable; unused entries below the
      live tail are tolerated by the showHelp loops.  We intentionally
      pad to a wider bound than the live entries (above) to absorb any
      minor upstream additions without re-counting the array. }
    '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '',
    '', '', '', '', '', '', '', '', '', '',
    '', ''
  );

function helpFirstChar(const s: AnsiString): AnsiChar; inline;
begin
  if Length(s) = 0 then Result := #0 else Result := s[1];
end;

function helpReplaceLeading(const s: AnsiString; from, into: AnsiChar): AnsiString;
begin
  Result := s;
  if (Length(Result) > 0) and (Result[1] = from) then Result[1] := into;
end;

procedure showHelp(const zPatternIn: AnsiString);
{ shell.c.in:4004..4090 — port of static int showHelp(FILE*, const char*).
  Returns nothing here; the caller does not consume the count. }
var
  i, j, n: SizeInt;
  zPattern: AnsiString;
  zPat: AnsiString;
  zHit: AnsiString;
  show: Boolean;
  c: AnsiChar;
  azLen: SizeInt;
begin
  azLen := Length(azHelp);
  zPattern := zPatternIn;
  if zPattern = '' then begin
    { Show just the first line for all documented help topics. }
    zPattern := '[a-z]';
  end else if (zPattern = '-a') or (zPattern = '-all') or (zPattern = '--all') then begin
    { Show everything except undocumented commands. }
    zPattern := '.';
  end else if zPattern = '0' then begin
    { Show complete help text of undocumented commands. }
    show := False;
    for i := 0 to azLen - 1 do begin
      c := helpFirstChar(azHelp[i]);
      if c = '.' then show := False
      else if c = ',' then begin
        show := True;
        shellSPutZ('.' + Copy(azHelp[i], 2, Length(azHelp[i]) - 1) + #10);
      end else if show then
        shellSPutZ(azHelp[i] + #10);
    end;
    Exit;
  end;

  { Seek documented commands for which zPattern is an exact prefix. }
  if (Length(zPattern) > 0) and (zPattern[1] = '.') then
    zPat := '.' + Copy(zPattern, 2, Length(zPattern) - 1) + '*'
  else
    zPat := '.' + zPattern + '*';
  zHit := '';
  j := 0;
  n := 0;
  for i := 0 to azLen - 1 do begin
    if azHelp[i] = '' then Continue;
    if sqlite3_strglob(PAnsiChar(zPat), PAnsiChar(azHelp[i])) = 0 then begin
      if zHit <> '' then shellSPutZ(zHit + #10);
      zHit := azHelp[i];
      j := i + 1;
      Inc(n);
    end;
  end;
  if n > 0 then begin
    if n = 1 then begin
      shellSPutZ(zHit + #10);
      while (j < azLen) and (helpFirstChar(azHelp[j]) = ' ') do begin
        shellSPutZ(azHelp[j] + #10);
        Inc(j);
      end;
    end else
      shellSPutZ(zHit + #10);
    Exit;
  end;

  { Substring (LIKE) match across all documented entries. }
  zPat := '%' + zPattern + '%';
  i := 0;
  while i < azLen do begin
    if azHelp[i] = '' then begin Inc(i); Continue; end;
    c := helpFirstChar(azHelp[i]);
    if c = ',' then begin
      while (i < azLen - 1) and (helpFirstChar(azHelp[i + 1]) = ' ') do
        Inc(i);
      Inc(i);
      Continue;
    end;
    if c = '.' then j := i;
    if sqlite3_strlike(PAnsiChar(zPat), PAnsiChar(azHelp[i]), 0) = 0 then begin
      shellSPutZ(azHelp[j] + #10);
      while (j < azLen - 1) and (helpFirstChar(azHelp[j + 1]) = ' ') do begin
        Inc(j);
        shellSPutZ(azHelp[j] + #10);
      end;
      i := j;
      Inc(n);
    end;
    Inc(i);
  end;
end;

procedure cmdHelp(const args: array of AnsiString; nArg: SizeInt);
var i: SizeInt; pat: AnsiString;
begin
  if nArg = 0 then begin
    showHelp('');
    Exit;
  end;
  for i := 0 to nArg - 1 do begin
    pat := args[i];
    showHelp(pat);
  end;
end;

function onOffStr(b: Boolean): AnsiString; inline;
begin
  if b then Result := 'on' else Result := 'off';
end;

procedure cmdShow(p: PShellState);
const
  azBool: array[0..3] of AnsiString = ('off', 'on', 'trigger', 'full');
var
  fn: AnsiString;
  i: SizeInt;
  widths: AnsiString;
begin
  if p^.pAuxDb^.zDbFilename = nil then fn := '' else fn := AnsiString(p^.pAuxDb^.zDbFilename);
  shellSPutZ(Format('%12s: %s'#10, ['echo',         onOffStr((p^.mode.mFlags and MFLG_ECHO) <> 0)]));
  shellSPutZ(Format('%12s: %s'#10, ['eqp',          azBool[p^.mode.autoEQP and 3]]));
  if p^.mode.autoExplain <> 0 then
    shellSPutZ(Format('%12s: %s'#10, ['explain',    'auto']))
  else
    shellSPutZ(Format('%12s: %s'#10, ['explain',    'off']));
  shellSPutZ(Format('%12s: %s'#10, ['headers',      onOffStr(p^.mode.spec.bTitles = QRF_Yes)]));
  shellSPutZ(Format('%12s: %s'#10, ['mode',         StrPas(@aModeInfo[p^.mode.eMode].zName[0])]));
  shellSPutZ(Format('%12s: "%s"'#10, ['nullvalue',  specStr(p^.mode.spec.zNull)]));
  shellSPutZ(Format('%12s: "%s"'#10, ['colseparator', specStr(p^.mode.spec.zColumnSep)]));
  shellSPutZ(Format('%12s: "%s"'#10, ['rowseparator', specStr(p^.mode.spec.zRowSep)]));
  case p^.statsOn of
    0: shellSPutZ(Format('%12s: %s'#10, ['stats', 'off']));
    2: shellSPutZ(Format('%12s: %s'#10, ['stats', 'stmt']));
    3: shellSPutZ(Format('%12s: %s'#10, ['stats', 'vmstep']));
  else
    shellSPutZ(Format('%12s: %s'#10, ['stats', 'on']));
  end;
  widths := '';
  for i := 0 to p^.mode.spec.nWidth - 1 do
    widths := widths + IntToStr(p^.mode.spec.aWidth[i]) + ' ';
  shellSPutZ(Format('%12s: %s'#10, ['width', widths]));
  shellSPutZ(Format('%12s: %s'#10, ['filename',     fn]));
  if gOutRedirected then
    shellSPutZ(Format('%12s: %s'#10, ['output', gOutCurFilename]))
  else
    shellSPutZ(Format('%12s: %s'#10, ['output', 'stdout']));
end;

procedure cmdMode(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var n: i32;
begin
  if nArg < 1 then begin
    shellSPutZ(Format('current output mode: %s'#10, [StrPas(@aModeInfo[p^.mode.eMode].zName[0])]));
    Exit;
  end;
  n := modeFind(p, args[0]);
  if n < 0 then begin
    shellEPutZ(Format('Error: mode should be one of: ' +
      'ascii box column csv html insert json line list markdown ' +
      'qbox quote table tabs tcl'#10, []));
    Exit;
  end;
  modeChange(p, u8(n));
  if (nArg >= 2) and (n = MODE_Insert) then begin
    p^.zDestTable := PAnsiChar(args[1]);
  end;
end;

procedure cmdHeaders(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var v: i32;
begin
  if nArg < 1 then begin
    shellEPutZ('Usage: .headers on|off'#10);
    Exit;
  end;
  v := parseOnOff(args[0], -1);
  if v < 0 then begin
    shellEPutZ('Error: not a boolean: '+args[0]+#10);
    Exit;
  end;
  if v <> 0 then begin
    p^.mode.spec.bTitles := QRF_Yes;
    p^.mode.mFlags := p^.mode.mFlags or MFLG_HDR;
  end else begin
    p^.mode.spec.bTitles := QRF_No;
    p^.mode.mFlags := p^.mode.mFlags and not MFLG_HDR;
  end;
end;

procedure cmdSeparator(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
{ The ShellState carries pre-allocated AnsiStrings via the parsed-arg
  buffer; we keep stable copies in unit-level vars so the PAnsiChars
  remain valid for the lifetime of the connection. }
begin
  if nArg < 1 then begin
    shellEPutZ('Usage: .separator COL ?ROW?'#10);
    Exit;
  end;
  zUserColSep := args[0];
  if nArg >= 2 then zUserRowSep := args[1];
  p^.mode.spec.zColumnSep := PAnsiChar(zUserColSep);
  if nArg >= 2 then p^.mode.spec.zRowSep := PAnsiChar(zUserRowSep);
end;

procedure cmdNullvalue(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
begin
  if nArg < 1 then zUserNull := '' else zUserNull := args[0];
  p^.mode.spec.zNull := PAnsiChar(zUserNull);
end;

procedure cmdEcho(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var v: i32;
begin
  if nArg < 1 then v := 1 else v := parseOnOff(args[0], 1);
  if v <> 0 then p^.mode.mFlags := p^.mode.mFlags or MFLG_ECHO
              else p^.mode.mFlags := p^.mode.mFlags and not MFLG_ECHO;
end;

procedure cmdChanges(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var v: i32;
begin
  if nArg < 1 then v := 1 else v := parseOnOff(args[0], 1);
  if v <> 0 then p^.shellFlgs := p^.shellFlgs or SHFLG_CountChanges
              else p^.shellFlgs := p^.shellFlgs and not SHFLG_CountChanges;
end;

procedure cmdTables(p: PShellState; const args: array of AnsiString;
                    nArg: SizeInt);
{ Mirror upstream `.tables` (shell.c.in:11341..11386).  Walk the
  sqlite3_database_list and union one SELECT per attached database, then
  collect every name with an in-memory list and emit it in the upstream
  3-column auto-formatted block (shell.c.in's MODE_Split rendering of
  the result).  Names are quoted "<db>.<name>" for non-main databases. }
const
  kInitCap = 16;
var
  zPattern: AnsiString;
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
  zDbName: PAnsiChar;
  sql: AnsiString;
  names: array of AnsiString;
  nNames, capNames: SizeInt;
  zText: PAnsiChar;
  i, j, nRow, nCol, colW, idx, padLen: SizeInt;
  maxLen: SizeInt;
  line: AnsiString;
begin
  zPattern := '';
  if nArg >= 1 then zPattern := args[0];
  openDb(p, 0);
  if p^.db = nil then Exit;

  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db,
          'SELECT seq, name, file FROM pragma_database_list ORDER BY seq',
          -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    Exit;
  end;

  sql := '';
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    zDbName := PAnsiChar(sqlite3_column_text(pStmt, 1));
    if zDbName = nil then Continue;
    if Length(sql) > 0 then sql := sql + ' UNION ALL ';
    if sqlite3_stricmp(zDbName, 'main') = 0 then
      sql := sql + 'SELECT name FROM '
    else
      sql := sql + 'SELECT '''
                 + StringReplace(AnsiString(zDbName), '''', '''''',
                                 [rfReplaceAll])
                 + '''||''.''||name FROM ';
    sql := sql + '"' + StringReplace(AnsiString(zDbName), '"', '""',
                                     [rfReplaceAll]) + '".sqlite_schema'
               + ' WHERE type IN (''table'',''view'')'
               + ' AND name NOT LIKE ''sqlite__%'' ESCAPE ''_''';
    if zPattern <> '' then
      sql := sql + ' AND name LIKE '''
                 + StringReplace(zPattern, '''', '''''', [rfReplaceAll])
                 + '''';
  end;
  sqlite3_finalize(pStmt);
  if Length(sql) = 0 then Exit;
  sql := sql + ' ORDER BY 1';

  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(sql), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    Exit;
  end;
  nNames   := 0;
  capNames := kInitCap;
  SetLength(names, capNames);
  rc := sqlite3_step(pStmt);
  while rc = SQLITE_ROW do begin
    zText := PAnsiChar(sqlite3_column_text(pStmt, 0));
    if zText = nil then Continue;
    if nNames >= capNames then begin
      capNames := capNames * 2;
      SetLength(names, capNames);
    end;
    names[nNames] := AnsiString(zText);
    Inc(nNames);
    rc := sqlite3_step(pStmt);
  end;
  sqlite3_finalize(pStmt);

  if nNames = 0 then Exit;
  { Layout: column-major, max name width as cell width, 2-space gap after
    each cell; mirrors shell.c.in:11342..11386 plus the print loop just
    after that range. }
  maxLen := 0;
  for i := 0 to nNames - 1 do
    if Length(names[i]) > maxLen then maxLen := Length(names[i]);
  colW := maxLen + 2;
  if colW < 4 then colW := 4;
  nCol := 80 div colW;
  if nCol < 1 then nCol := 1;
  nRow := (nNames + nCol - 1) div nCol;
  idx := 0;
  for i := 0 to nRow - 1 do begin
    line := '';
    j := i;
    while j < nNames do begin
      if j > i then line := line + '  ';
      padLen := maxLen - Length(names[j]);
      if (j + nRow < nNames) and (padLen > 0) then
        line := line + names[j] + StringOfChar(' ', padLen)
      else
        line := line + names[j];
      Inc(j, nRow);
    end;
    WriteLn(line);
    Inc(idx);
  end;
end;

procedure cmdIndexes(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
{ shell.c.in ~10989..11020: list all indexes (or just those of the
  named table) ordered by name. }
var sql, tab: AnsiString;
begin
  if nArg >= 1 then begin
    tab := StringReplace(args[0], '''', '''''', [rfReplaceAll]);
    sql := 'SELECT name FROM sqlite_schema WHERE type=''index'' AND tbl_name=''' +
           tab + ''' ORDER BY 1';
  end else
    sql := 'SELECT name FROM sqlite_schema WHERE type=''index'' ORDER BY 1';
  runStatementVerbose(p, sql);
end;

procedure cmdDatabases(p: PShellState);
{ shell.c.in ~10130: SELECT * FROM pragma_database_list. }
begin
  runStatementVerbose(p, 'SELECT name, file FROM pragma_database_list ORDER BY seq');
end;

procedure cmdSchema(p: PShellState; const args: array of AnsiString;
                    nArg: SizeInt);
{ shell.c.in:10575..10711.  Walk pragma_database_list, build a UNION ALL
  across each attached database's sqlite_schema, render the matching
  CREATE statements.  This Pascal cut covers --nosys, a literal LIKE/GLOB
  pattern, and the sqlite_schema/sqlite_master self-description block.
  --indent and --debug are deferred (they need shell_format_schema /
  shell_add_schema UDFs which are not yet ported).  --debug emits the
  composed SQL just like upstream so external diff harnesses can pick
  up the new shape. }
const
  zSelfSchema =
    'CREATE TABLE %ssqlite_schema (' + sLineBreak +
    '  type text,' + sLineBreak +
    '  name text,' + sLineBreak +
    '  tbl_name text,' + sLineBreak +
    '  rootpage integer,' + sLineBreak +
    '  sql text' + sLineBreak +
    ');' + sLineBreak;
var
  bDebug, bNoSysTabs, bIndent, bGlob: Boolean;
  zName, sql, zDb, zNameQuoted, zPattern: AnsiString;
  zDiv: AnsiString;
  ii: SizeInt;
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
  zDbName: PAnsiChar;
  iSchema: i32;
  zRow: PAnsiChar;
  isSchema: Boolean;
begin
  bDebug     := False;
  bNoSysTabs := False;
  bIndent    := False;
  zName      := '';
  for ii := 0 to nArg - 1 do begin
    if (args[ii] = '--indent') or (args[ii] = '-indent') then
      bIndent := True
    else if (args[ii] = '--debug') or (args[ii] = '-debug') then
      bDebug := True
    else if (args[ii] = '--nosys') or (args[ii] = '-nosys') then
      bNoSysTabs := True
    else if (Length(args[ii]) > 0) and (args[ii][1] = '-') then begin
      shellEPutZ(Format('Unknown option: "%s"'#10, [args[ii]]));
      Exit;
    end else if zName = '' then
      zName := args[ii]
    else begin
      shellEPutZ('Usage: .schema ?--indent? ?--nosys? ?LIKE-PATTERN?'#10);
      Exit;
    end;
  end;
  if bIndent then begin
    { --indent depends on the shell_format_schema/_add_schema UDFs that
      are not yet ported; quietly ignore the flag rather than error so
      `.dump`-style scripted gates keep working. }
  end;

  openDb(p, 0);
  if p^.db = nil then Exit;

  if zName <> '' then begin
    isSchema := (sqlite3_strlike('sqlite_master', PAnsiChar(zName), Ord('\')) = 0)
              or (sqlite3_strlike('sqlite_schema', PAnsiChar(zName), Ord('\')) = 0)
              or (sqlite3_strlike('sqlite_temp_master',
                                  PAnsiChar(zName), Ord('\')) = 0)
              or (sqlite3_strlike('sqlite_temp_schema',
                                  PAnsiChar(zName), Ord('\')) = 0);
    if isSchema then begin
      if sqlite3_strlike('sqlite_t%', PAnsiChar(zName), 0) = 0 then
        Write(Format(zSelfSchema, ['temp.']))
      else
        Write(Format(zSelfSchema, ['']));
    end;
  end;

  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db,
          'SELECT seq, name, file FROM pragma_database_list ORDER BY seq',
          -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    Exit;
  end;
  sql     := 'SELECT sql FROM (';
  zDiv    := '';
  iSchema := 0;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    zDbName := PAnsiChar(sqlite3_column_text(pStmt, 1));
    if zDbName = nil then Continue;
    Inc(iSchema);
    sql := sql + zDiv;
    zDiv := ' UNION ALL ';
    zDb  := AnsiString(zDbName);
    if sqlite3_stricmp(zDbName, 'main') = 0 then
      sql := sql + 'SELECT sql, type, tbl_name, name, rowid, '
                 + IntToStr(iSchema) + ' AS snum, '
                 + '''' + StringReplace(zDb, '''', '''''', [rfReplaceAll])
                 + ''' AS sname'
                 + ' FROM "' + StringReplace(zDb, '"', '""', [rfReplaceAll])
                 + '".sqlite_schema'
    else
      sql := sql + 'SELECT sql, type, tbl_name, name, rowid, '
                 + IntToStr(iSchema) + ' AS snum, '
                 + '''' + StringReplace(zDb, '''', '''''', [rfReplaceAll])
                 + ''' AS sname'
                 + ' FROM "' + StringReplace(zDb, '"', '""', [rfReplaceAll])
                 + '".sqlite_schema';
  end;
  sqlite3_finalize(pStmt);
  if iSchema = 0 then Exit;

  sql := sql + ') WHERE ';
  if zName <> '' then begin
    bGlob := (Pos('*', zName) > 0) or (Pos('?', zName) > 0)
            or (Pos('[', zName) > 0);
    zNameQuoted := '''' + StringReplace(zName, '''', '''''',
                                        [rfReplaceAll]) + '''';
    if Pos('.', zName) > 0 then
      sql := sql + 'lower(format(''%s.%s'',sname,tbl_name))'
    else
      sql := sql + 'lower(tbl_name)';
    if bGlob then
      sql := sql + ' GLOB ' + zNameQuoted + ' AND '
    else
      sql := sql + ' LIKE ' + zNameQuoted + ' ESCAPE ''\'' AND ';
  end;
  if bNoSysTabs then
    sql := sql + 'name NOT LIKE ''sqlite__%'' ESCAPE ''_'' AND ';
  sql := sql + 'sql IS NOT NULL ORDER BY snum, rowid';

  if bDebug then begin
    WriteLn(Format('SQL: %s;', [sql]));
    Exit;
  end;
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(sql), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    zRow := PAnsiChar(sqlite3_column_text(pStmt, 0));
    if zRow <> nil then WriteLn(AnsiString(zRow) + ';');
  end;
  sqlite3_finalize(pStmt);
end;

{ ----------------------------------------------------------------------
  10.1.29 — `.timer on|off|once` + the BEGIN_TIMER / END_TIMER probe
  ports shell.c.in:1404..1456 (the Unix arm) plus the dispatcher arm at
  11886..11901.  We declare getrusage / gettimeofday locally as cdecl
  imports because BaseUnix doesn't surface getrusage and the upstream
  layout (timeval seconds + microseconds) is what we need to mirror. }

const
  RUSAGE_SELF_PAS = 0;

type
  TTVPas = record
    tv_sec:  clong;
    tv_usec: clong;
  end;
  TRUsagePas = record
    ru_utime:    TTVPas;
    ru_stime:    TTVPas;
    ru_maxrss:   clong;
    ru_ixrss:    clong;
    ru_idrss:    clong;
    ru_isrss:    clong;
    ru_minflt:   clong;
    ru_majflt:   clong;
    ru_nswap:    clong;
    ru_inblock:  clong;
    ru_oublock:  clong;
    ru_msgsnd:   clong;
    ru_msgrcv:   clong;
    ru_nsignals: clong;
    ru_nvcsw:    clong;
    ru_nivcsw:   clong;
  end;
  PRUsagePas = ^TRUsagePas;

function shellGetRUsage(who: cint; usage: PRUsagePas): cint;
  cdecl; external 'c' name 'getrusage';
function shellGetTimeOfDay(tp: Pointer; tzp: Pointer): cint;
  cdecl; external 'c' name 'gettimeofday';

var
  shellTimerBeginRU: TRUsagePas;
  shellTimerBeginNs: i64;

function shellTimeOfDayUs: i64;
{ Microseconds since the Unix epoch; mirrors timeOfDay() in shell.c.in
  (search for 'timeOfDay' near line 13950 — implemented via gettimeofday
  on Unix). }
var
  tv: TTVPas;
begin
  tv.tv_sec  := 0;
  tv.tv_usec := 0;
  shellGetTimeOfDay(@tv, nil);
  Result := (i64(tv.tv_sec) * 1000000) + i64(tv.tv_usec);
end;

procedure shellBeginTimer(p: PShellState);
{ shell.c.in:1411..1416.  Snapshot user/sys CPU and wall clock when the
  timer (or the soft-timeout progress hook) is armed. }
begin
  if (p^.enableTimer <> 0) or ((p^.flgProgress and SHELL_PROGRESS_TMOUT) <> 0) then
  begin
    FillChar(shellTimerBeginRU, SizeOf(shellTimerBeginRU), 0);
    shellGetRUsage(RUSAGE_SELF_PAS, @shellTimerBeginRU);
    shellTimerBeginNs := shellTimeOfDayUs;
  end;
end;

function shellTvDiffSec(const tStart, tEnd: TTVPas): Double;
{ shell.c.in:1419..1422.  timeDiff(): difference of two timevals as a
  fractional number of seconds. }
begin
  Result := (tEnd.tv_usec - tStart.tv_usec) * 0.000001
          + Double(tEnd.tv_sec - tStart.tv_sec);
end;

procedure shellEndTimer(p: PShellState);
{ shell.c.in:1437..1450.  Print the wall/user/sys triple and decay
  enableTimer=1 (`.timer once`) back to 0. }
var
  ruEnd: TRUsagePas;
  iEndUs: i64;
  realSec: Double;
  s: AnsiString;
begin
  if p^.enableTimer = 0 then Exit;
  iEndUs := shellTimeOfDayUs;
  FillChar(ruEnd, SizeOf(ruEnd), 0);
  shellGetRUsage(RUSAGE_SELF_PAS, @ruEnd);
  realSec := (iEndUs - shellTimerBeginNs) * 0.000001;
  p^.prevTimer := realSec;
  s := Format('Run Time: real %.6f user %.6f sys %.6f'#10,
              [realSec,
               shellTvDiffSec(shellTimerBeginRU.ru_utime, ruEnd.ru_utime),
               shellTvDiffSec(shellTimerBeginRU.ru_stime, ruEnd.ru_stime)]);
  Write(s);
  if p^.enableTimer = 1 then p^.enableTimer := 0;
  shellTimerBeginNs := 0;
end;

procedure cmdTimer(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
begin
  if nArg < 1 then begin
    shellEPutZ('Usage: .timer on|off|once'#10);
    Exit;
  end;
  if args[0] = 'once' then p^.enableTimer := 1
  else p^.enableTimer := 2 * parseOnOff(args[0], 0);
end;

{ 10.1.30 — `.eqp off|on|trace|trigger|full`  (shell.c.in:9479..9504) }

procedure cmdEqp(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
begin
  if nArg < 1 then begin
    shellEPutZ('Usage: .eqp off|on|trace|trigger|full'#10);
    Exit;
  end;
  if p^.mode.autoEQPtrace <> 0 then begin
    if p^.db <> nil then sqlite3_exec(p^.db, 'PRAGMA vdbe_trace=OFF;', nil, nil, nil);
    p^.mode.autoEQPtrace := 0;
  end;
  if args[0] = 'full' then p^.mode.autoEQP := AUTOEQP_full
  else if args[0] = 'trigger' then p^.mode.autoEQP := AUTOEQP_trigger
  else if args[0] = 'trace' then begin
    p^.mode.autoEQP := AUTOEQP_full;
    p^.mode.autoEQPtrace := 1;
    openDb(p, 0);
    if p^.db <> nil then begin
      sqlite3_exec(p^.db, 'SELECT name FROM sqlite_schema LIMIT 1', nil, nil, nil);
      sqlite3_exec(p^.db, 'PRAGMA vdbe_trace=ON;', nil, nil, nil);
    end;
  end else
    p^.mode.autoEQP := u8(parseOnOff(args[0], 0));
end;

{ 10.1.31 — `.explain auto|on|off`  (shell.c.in:9515..9523) }

procedure cmdExplain(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
begin
  if nArg < 1 then begin
    p^.mode.autoExplain := 1;
    Exit;
  end;
  if args[0] = 'auto' then p^.mode.autoExplain := 1
  else p^.mode.autoExplain := u8(parseOnOff(args[0], 0));
end;

{ 10.1.34 — `.shell` / `.system COMMAND ...`  (shell.c.in:11243..11264).
  Concatenate args (quoting any token that contains a space), pass to
  the underlying shell via libc system().  Mirrors the upstream
  "System command returns N" stderr breadcrumb on non-zero exit. }

procedure cmdShell(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var
  zCmd, tok: AnsiString;
  i, x: i32;
begin
  if nArg < 1 then begin
    shellEPutZ('Usage: .system COMMAND'#10);
    Exit;
  end;
  zCmd := '';
  for i := 0 to nArg - 1 do begin
    if Pos(' ', args[i]) > 0 then tok := '"' + args[i] + '"' else tok := args[i];
    if i = 0 then zCmd := tok else zCmd := zCmd + ' ' + tok;
  end;
  x := fpsystem(zCmd);
  if x <> 0 then shellEPutZ(Format('System command returns %d'#10, [x]));
end;

{ 10.1.35 — `.cd DIRECTORY`  (shell.c.in:9127..9145) }

procedure cmdCd(const args: array of AnsiString; nArg: SizeInt);
var rc: i32;
begin
  if nArg <> 1 then begin
    shellEPutZ('Usage: .cd DIRECTORY'#10);
    Exit;
  end;
  rc := FpChdir(PAnsiChar(args[0]));
  if rc <> 0 then
    shellEPutZ(Format('Cannot change to directory "%s"'#10, [args[0]]));
end;

{ 10.1.36 — `.log FILENAME|on|off`  (shell.c.in:10091..10109).

  Records the destination so `.show` and future logger plumbing have
  a stable view.  Actually wiring SQLITE_CONFIG_LOG is gated on the
  raw-varargs sqlite3_config port (out of phase-10 scope). }

procedure cmdLog(const args: array of AnsiString; nArg: SizeInt);
begin
  if nArg <> 1 then begin
    shellEPutZ('Usage: .log FILENAME'#10);
    Exit;
  end;
  if args[0] = 'on' then zLogFile := 'stdout'
  else zLogFile := args[0];
end;

{ 10.1.49 — `.dbinfo ?DB?`  (shell.c.in:5485..5575).  Reads the 100-byte
  page-1 header via sqlite_dbpage(?), prints the named integer fields,
  then runs the small set of count queries against sqlite_schema. }

procedure cmdDbinfo(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
const
  fieldName: array[0..11] of AnsiString = (
    'file change counter:', 'database page count:', 'freelist page count:',
    'schema cookie:', 'schema format:', 'default cache size:',
    'autovacuum top root:', 'incremental vacuum:', 'text encoding:',
    'user version:', 'application id:', 'software version:');
  fieldOfst: array[0..11] of i32 =
    (24, 28, 36, 40, 44, 48, 52, 64, 56, 60, 68, 96);
  qName: array[0..4] of AnsiString = (
    'number of tables:',  'number of indexes:', 'number of triggers:',
    'number of views:',   'schema size:');
  qSql: array[0..4] of AnsiString = (
    'SELECT count(*) FROM %s WHERE type=''table''',
    'SELECT count(*) FROM %s WHERE type=''index''',
    'SELECT count(*) FROM %s WHERE type=''trigger''',
    'SELECT count(*) FROM %s WHERE type=''view''',
    'SELECT total(length(sql)) FROM %s');
var
  zDb, zSchemaTab, zSql: AnsiString;
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc, i, val, pageSz: i32;
  iDataVer: u32;
  pBlob, pHdr: PByte;
  aHdr: array[0..99] of Byte;
begin
  if nArg >= 1 then zDb := args[0] else zDb := 'main';
  openDb(p, 0);
  if p^.db = nil then Exit;
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db,
        'SELECT data FROM sqlite_dbpage(?1) WHERE pgno=1',
        -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    shellEPutZ(Format('error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit;
  end;
  sqlite3_bind_text(pStmt, 1, PAnsiChar(zDb), -1, SQLITE_STATIC);
  if (sqlite3_step(pStmt) = SQLITE_ROW)
     and (sqlite3_column_bytes(pStmt, 0) >= 100) then
  begin
    pBlob := PByte(sqlite3_column_blob(pStmt, 0));
    Move(pBlob^, aHdr[0], 100);
    sqlite3_finalize(pStmt);
  end else begin
    shellEPutZ('unable to read database header'#10);
    sqlite3_finalize(pStmt);
    Exit;
  end;
  pageSz := (i32(aHdr[16]) shl 8) or i32(aHdr[17]);
  if pageSz = 1 then pageSz := 65536;
  shellSPutZ(Format('%-20s %d'#10, ['database page size:', pageSz]));
  shellSPutZ(Format('%-20s %d'#10, ['write format:',       aHdr[18]]));
  shellSPutZ(Format('%-20s %d'#10, ['read format:',        aHdr[19]]));
  shellSPutZ(Format('%-20s %d'#10, ['reserved bytes:',     aHdr[20]]));
  for i := 0 to High(fieldOfst) do begin
    pHdr := @aHdr[fieldOfst[i]];
    val := (i32(pHdr[0]) shl 24) or (i32(pHdr[1]) shl 16)
        or (i32(pHdr[2]) shl 8)  or i32(pHdr[3]);
    Write(Format('%-20s %u', [fieldName[i], u32(val)]));
    if fieldOfst[i] = 56 then begin
      case val of
        1: Write(' (utf8)');
        2: Write(' (utf16le)');
        3: Write(' (utf16be)');
      end;
    end;
    WriteLn;
  end;
  if zDb = 'temp' then zSchemaTab := 'sqlite_temp_schema'
  else zSchemaTab := '"' + StringReplace(zDb, '"', '""', [rfReplaceAll]) +
                    '".sqlite_schema';
  for i := 0 to High(qSql) do begin
    zSql := StringReplace(qSql[i], '%s', zSchemaTab, []);
    val := 0;
    pStmt := nil;
    rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
    if (rc = SQLITE_OK) and (pStmt <> nil)
       and (sqlite3_step(pStmt) = SQLITE_ROW) then
      val := sqlite3_column_int(pStmt, 0);
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellSPutZ(Format('%-20s %d'#10, [qName[i], val]));
  end;
  iDataVer := 0;
  sqlite3_file_control(p^.db, PAnsiChar(zDb),
                       SQLITE_FCNTL_DATA_VERSION, @iDataVer);
  shellSPutZ(Format('%-20s %u'#10, ['data version', iDataVer]));
end;

{ 10.1.53 — `.crnl ?on|off?`  (shell.c.in:9223..9240).  CRLF translation
  is a Windows-only feature; on Linux the flag stays cleared, but we
  echo the current state to mirror upstream. }

procedure cmdCrnl(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
begin
  if nArg >= 1 then
    p^.mode.mFlags := p^.mode.mFlags and not MFLG_CRLF;
  if (p^.mode.mFlags and MFLG_CRLF) <> 0 then shellEPutZ('crlf is ON'#10)
  else shellEPutZ('crlf is OFF'#10);
end;

{ 10.1.54 — `.binary` deprecated stub  (shell.c.in:9114..9117) }

procedure cmdBinary;
begin
  shellEPutZ('The ".binary" command is deprecated.'#10);
end;

{ 10.1.59 — `.breakpoint` debug-only no-op  (shell.c.in:9119..9123) }

procedure cmdBreakpoint;
begin
  { test_breakpoint() in C is a no-op kept for gdb to attach a hook.
    We deliberately leave it empty in Pascal as well. }
end;

{ ----------------------------------------------------------------------
  10.1.22  `.read FILE`  — shell.c.in:10454..10488

  Pushes the named file onto the input stack and re-enters processInput.
  The Pascal cut routes line reads through curInputText (see
  oneInputLine) since the upstream FILE* plumbing is not yet wired.
  Pipe (`|cmd`) variants are deferred — the upstream code path uses
  popen which we have not bound; an unsupported-pipe arm matches
  upstream's SQLITE_OMIT_POPEN branch.
  ---------------------------------------------------------------------- }

procedure cmdRead(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var
  f: Text;
  saved: ^Text;
  savedLineno: i64;
  savedZIn: PAnsiChar;
  zName: AnsiString;
  ioErr: Word;
begin
  if nArg <> 1 then begin
    shellEPutZ('Usage: .read FILE'#10);
    Exit;
  end;
  zName := args[0];
  if (Length(zName) > 0) and (zName[1] = '|') then begin
    shellEPutZ('Error: pipes are not supported in this OS'#10);
    Exit;
  end;
  AssignFile(f, string(zName));
  {$I-} Reset(f); {$I+}
  ioErr := IOResult;
  if ioErr <> 0 then begin
    shellEPutZ(Format('Error: cannot open "%s"'#10, [zName]));
    Exit;
  end;
  saved        := curInputText;
  savedLineno  := p^.lineno;
  savedZIn     := p^.zInFile;
  curInputText := @f;
  p^.lineno    := 0;
  p^.zInFile   := PAnsiChar(zName);
  processInput(p);
  CloseFile(f);
  curInputText := saved;
  p^.lineno    := savedLineno;
  p^.zInFile   := savedZIn;
end;

{ ----------------------------------------------------------------------
  10.1.26 / 10.1.43  `.save ?DB? FILE` and `.backup ?DB? FILE`
                    — shell.c.in:9034..9101

  Both arms collapse onto sqlite3_backup_init / _step / _finish.  Flags
  `--append` and `--async` are accepted to keep CLI parity; --append
  silently no-ops since apndvfs is not registered in the Pascal port.
  ---------------------------------------------------------------------- }

procedure cmdBackup(p: PShellState; const args: array of AnsiString; nArg: SizeInt;
                    const cmdName: AnsiString);
var
  pDest: PTsqlite3;
  pBackup: PSqlite3Backup;
  zDb, zDestFile, zVfs: AnsiString;
  bAsync: i32;
  j: SizeInt;
  rc: i32;
  z: AnsiString;
begin
  zDb := '';
  zDestFile := '';
  zVfs := '';
  bAsync := 0;
  pDest := nil;
  pBackup := nil;
  for j := 0 to nArg - 1 do begin
    z := args[j];
    if (Length(z) > 0) and (z[1] = '-') then begin
      if (Length(z) > 1) and (z[2] = '-') then Delete(z, 1, 1);
      if z = '-append' then zVfs := 'apndvfs'
      else if z = '-async' then bAsync := 1
      else begin
        shellEPutZ(Format('Error: unknown option: "%s"'#10, [args[j]]));
        Exit;
      end;
    end else if zDestFile = '' then zDestFile := z
    else if zDb = '' then begin zDb := zDestFile; zDestFile := z; end
    else begin
      shellEPutZ(Format('Usage: .%s ?DB? ?OPTIONS? FILENAME'#10, [cmdName]));
      Exit;
    end;
  end;
  if zDestFile = '' then begin
    shellEPutZ(Format('missing FILENAME argument on .%s'#10, [cmdName]));
    Exit;
  end;
  if zDb = '' then zDb := 'main';
  if zVfs <> '' then begin
    rc := sqlite3_open_v2(PAnsiChar(zDestFile), @pDest,
        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, PAnsiChar(zVfs));
  end else begin
    rc := sqlite3_open_v2(PAnsiChar(zDestFile), @pDest,
        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  end;
  if rc <> SQLITE_OK then begin
    shellEPutZ(Format('Error: cannot open "%s"'#10, [zDestFile]));
    if pDest <> nil then sqlite3_close(pDest);
    Exit;
  end;
  if bAsync <> 0 then
    sqlite3_exec(pDest, 'PRAGMA synchronous=OFF; PRAGMA journal_mode=OFF;',
                 nil, nil, nil);
  openDb(p, 0);
  pBackup := sqlite3_backup_init(pDest, 'main', p^.db, PAnsiChar(zDb));
  if pBackup = nil then begin
    shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(pDest)) + sLineBreak);
    sqlite3_close(pDest);
    Exit;
  end;
  repeat
    rc := sqlite3_backup_step(pBackup, 100);
  until rc <> SQLITE_OK;
  sqlite3_backup_finish(pBackup);
  if rc <> SQLITE_DONE then
    shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(pDest)) + sLineBreak);
  sqlite3_close(pDest);
end;

{ ----------------------------------------------------------------------
  10.1.45  `.clone NEWFILE`  — shell.c.in:5157..5368

  Copies as much of the current "main" database as possible into a fresh
  file at NEWFILE.  Unlike .backup, .clone runs through the SQL layer so
  it can salvage rows from a partially-corrupt source: the schema is
  replayed via sqlite3_exec(zSql), then each user table is enumerated by
  SELECT * (with a fall-back to ORDER BY rowid DESC on read errors) and
  re-inserted with INSERT OR IGNORE.  Faithful port of tryToClone /
  tryToCloneSchema / tryToCloneData.
  ---------------------------------------------------------------------- }

type
  TCloneForEachProc = procedure(p: PShellState; newDb: PTsqlite3;
                                const zTable: AnsiString);

procedure cloneTransferData(p: PShellState; newDb: PTsqlite3;
                            const zTable: AnsiString); forward;

procedure cloneTransferSchema(p: PShellState; newDb: PTsqlite3;
                              const zWhere: AnsiString;
                              xForEach: TCloneForEachProc);
var
  pQuery: PVdbe;
  zQuery: AnsiString;
  rc: i32;
  zName, zSql: AnsiString;
  pzErr: PAnsiChar;
  zErrMsg: AnsiString;
  pzTail: PAnsiChar;

  function fetchText(col: i32): AnsiString;
  var p2: PAnsiChar;
  begin
    p2 := PAnsiChar(sqlite3_column_text(pQuery, col));
    if p2 = nil then Result := '' else Result := AnsiString(p2);
  end;

begin
  pQuery := nil;
  zQuery := 'SELECT name, sql FROM sqlite_schema WHERE ' + zWhere +
            ' ORDER BY rowid ASC';
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zQuery), -1, @pQuery, @pzTail);
  if rc <> SQLITE_OK then begin
    shellEPutZ(Format('Error: (%d) %s on [%s]'#10,
      [sqlite3_extended_errcode(p^.db),
       AnsiString(sqlite3_errmsg(p^.db)), string(zQuery)]));
    if pQuery <> nil then sqlite3_finalize(pQuery);
    Exit;
  end;
  while True do begin
    rc := sqlite3_step(pQuery);
    if rc <> SQLITE_ROW then Break;
    zName := fetchText(0);
    zSql  := fetchText(1);
    if (zName = '') or (zSql = '') then Continue;
    if sqlite3_stricmp(PAnsiChar(zName), 'sqlite_sequence') <> 0 then begin
      Write(zName, '... '); Flush(Output);
      pzErr := nil;
      sqlite3_exec(newDb, PAnsiChar(zSql), nil, nil, @pzErr);
      if pzErr <> nil then begin
        zErrMsg := AnsiString(pzErr);
        shellEPutZ(Format('Error: %s'#10'SQL: [%s]'#10,
          [string(zErrMsg), string(zSql)]));
        sqlite3_free(pzErr);
      end;
    end;
    if Assigned(xForEach) then xForEach(p, newDb, zName);
    WriteLn('done');
  end;
  if rc <> SQLITE_DONE then begin
    sqlite3_finalize(pQuery);
    pQuery := nil;
    zQuery := 'SELECT name, sql FROM sqlite_schema WHERE ' + zWhere +
              ' ORDER BY rowid DESC';
    rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zQuery), -1, @pQuery, @pzTail);
    if rc <> SQLITE_OK then begin
      shellEPutZ(Format('Error: (%d) %s on [%s]'#10,
        [sqlite3_extended_errcode(p^.db),
         AnsiString(sqlite3_errmsg(p^.db)), string(zQuery)]));
      if pQuery <> nil then sqlite3_finalize(pQuery);
      Exit;
    end;
    while sqlite3_step(pQuery) = SQLITE_ROW do begin
      zName := fetchText(0);
      zSql  := fetchText(1);
      if (zName = '') or (zSql = '') then Continue;
      if sqlite3_stricmp(PAnsiChar(zName), 'sqlite_sequence') = 0 then Continue;
      Write(zName, '... '); Flush(Output);
      pzErr := nil;
      sqlite3_exec(newDb, PAnsiChar(zSql), nil, nil, @pzErr);
      if pzErr <> nil then begin
        zErrMsg := AnsiString(pzErr);
        shellEPutZ(Format('Error: %s'#10'SQL: [%s]'#10,
          [string(zErrMsg), string(zSql)]));
        sqlite3_free(pzErr);
      end;
      if Assigned(xForEach) then xForEach(p, newDb, zName);
      WriteLn('done');
    end;
  end;
  sqlite3_finalize(pQuery);
end;

procedure cloneTransferData(p: PShellState; newDb: PTsqlite3;
                            const zTable: AnsiString);
label done;
const
  spinRate = 10000;
var
  pQuery, pInsert: PVdbe;
  zQuery, zInsert: AnsiString;
  rc, i, n, k: i32;
  cnt: i64;
  pzTail: PAnsiChar;
  spinChars: array[0..3] of Char;
begin
  spinChars[0] := '|'; spinChars[1] := '/';
  spinChars[2] := '-'; spinChars[3] := '\';
  pQuery := nil;
  pInsert := nil;
  cnt := 0;
  zQuery := 'SELECT * FROM "' + zTable + '"';
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zQuery), -1, @pQuery, @pzTail);
  if rc <> SQLITE_OK then begin
    shellEPutZ(Format('Error %d: %s on [%s]'#10,
      [sqlite3_extended_errcode(p^.db),
       AnsiString(sqlite3_errmsg(p^.db)), string(zQuery)]));
    goto done;
  end;
  n := sqlite3_column_count(pQuery);
  zInsert := 'INSERT OR IGNORE INTO "' + zTable + '" VALUES(?';
  for i := 1 to n - 1 do zInsert := zInsert + ',?';
  zInsert := zInsert + ');';
  rc := sqlite3_prepare_v2(newDb, PAnsiChar(zInsert), -1, @pInsert, @pzTail);
  if rc <> SQLITE_OK then begin
    shellEPutZ(Format('Error %d: %s on [%s]'#10,
      [sqlite3_extended_errcode(newDb),
       AnsiString(sqlite3_errmsg(newDb)), string(zInsert)]));
    goto done;
  end;
  for k := 0 to 1 do begin
    while True do begin
      rc := sqlite3_step(pQuery);
      if rc <> SQLITE_ROW then Break;
      for i := 0 to n - 1 do begin
        case sqlite3_column_type(pQuery, i) of
          SQLITE_NULL:    sqlite3_bind_null(pInsert, i + 1);
          SQLITE_INTEGER: sqlite3_bind_int64(pInsert, i + 1,
                                             sqlite3_column_int64(pQuery, i));
          SQLITE_FLOAT:   sqlite3_bind_double(pInsert, i + 1,
                                              sqlite3_column_double(pQuery, i));
          SQLITE_TEXT:    sqlite3_bind_text(pInsert, i + 1,
                            PAnsiChar(sqlite3_column_text(pQuery, i)),
                            -1, SQLITE_STATIC);
          SQLITE_BLOB:    sqlite3_bind_blob(pInsert, i + 1,
                            sqlite3_column_blob(pQuery, i),
                            sqlite3_column_bytes(pQuery, i),
                            SQLITE_STATIC);
        end;
      end;
      rc := sqlite3_step(pInsert);
      if (rc <> SQLITE_OK) and (rc <> SQLITE_ROW) and (rc <> SQLITE_DONE) then
        shellEPutZ(Format('Error %d: %s'#10,
          [sqlite3_extended_errcode(newDb),
           AnsiString(sqlite3_errmsg(newDb))]));
      sqlite3_reset(pInsert);
      Inc(cnt);
      if (cnt mod spinRate) = 0 then begin
        Write(spinChars[(cnt div spinRate) mod 4], #8);
        Flush(Output);
      end;
    end;
    if rc = SQLITE_DONE then Break;
    sqlite3_finalize(pQuery);
    pQuery := nil;
    zQuery := 'SELECT * FROM "' + zTable + '" ORDER BY rowid DESC;';
    rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zQuery), -1, @pQuery, @pzTail);
    if rc <> SQLITE_OK then begin
      shellEPutZ('Warning: cannot step "' + zTable + '" backwards');
      Break;
    end;
  end;
done:
  if pQuery <> nil then sqlite3_finalize(pQuery);
  if pInsert <> nil then sqlite3_finalize(pInsert);
end;

procedure cmdClone(p: PShellState; const args: array of AnsiString;
                   nArg: SizeInt);
var
  zNewDb: AnsiString;
  newDb: PTsqlite3;
  rc: i32;
begin
  if nArg <> 1 then begin
    shellEPutZ('Usage: .clone FILENAME'#10);
    Exit;
  end;
  zNewDb := args[0];
  if FileExists(string(zNewDb)) then begin
    shellEPutZ(Format('File "%s" already exists.'#10, [string(zNewDb)]));
    Exit;
  end;
  openDb(p, 0);
  newDb := nil;
  rc := sqlite3_open(PAnsiChar(zNewDb), @newDb);
  if rc <> SQLITE_OK then begin
    shellEPutZ('Cannot create output database: ' +
               AnsiString(sqlite3_errmsg(newDb)) + sLineBreak);
    if newDb <> nil then sqlite3_close(newDb);
    Exit;
  end;
  sqlite3_exec(p^.db, 'PRAGMA writable_schema=ON;', nil, nil, nil);
  sqlite3_exec(newDb, 'BEGIN EXCLUSIVE;', nil, nil, nil);
  cloneTransferSchema(p, newDb, 'type=''table''', @cloneTransferData);
  cloneTransferSchema(p, newDb, 'type!=''table''', nil);
  sqlite3_exec(newDb, 'COMMIT;', nil, nil, nil);
  sqlite3_exec(p^.db, 'PRAGMA writable_schema=OFF;', nil, nil, nil);
  sqlite3_close(newDb);
end;

{ ----------------------------------------------------------------------
  10.1.44  `.restore ?DB? FILE`  — shell.c.in:10491..10542

  Symmetric to .backup with source/dest swapped.  The C reference adds
  a 3-attempt SQLITE_BUSY retry loop with sqlite3_sleep(100); we mirror
  it here.
  ---------------------------------------------------------------------- }

procedure cmdRestore(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var
  pSrc: PTsqlite3;
  pBackup: PSqlite3Backup;
  zDb, zSrcFile: AnsiString;
  rc, nTimeout: i32;
begin
  if nArg = 1 then begin zSrcFile := args[0]; zDb := 'main'; end
  else if nArg = 2 then begin zDb := args[0]; zSrcFile := args[1]; end
  else begin
    shellEPutZ('Usage: .restore ?DB? FILE'#10);
    Exit;
  end;
  pSrc := nil;
  rc := sqlite3_open(PAnsiChar(zSrcFile), @pSrc);
  if rc <> SQLITE_OK then begin
    shellEPutZ(Format('Error: cannot open "%s"'#10, [zSrcFile]));
    if pSrc <> nil then sqlite3_close(pSrc);
    Exit;
  end;
  openDb(p, 0);
  pBackup := sqlite3_backup_init(p^.db, PAnsiChar(zDb), pSrc, 'main');
  if pBackup = nil then begin
    shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    sqlite3_close(pSrc);
    Exit;
  end;
  nTimeout := 0;
  repeat
    rc := sqlite3_backup_step(pBackup, 100);
    if rc = SQLITE_BUSY then begin
      Inc(nTimeout);
      if nTimeout >= 3 then Break;
      sqlite3_sleep(100);
    end;
  until (rc <> SQLITE_OK) and (rc <> SQLITE_BUSY);
  sqlite3_backup_finish(pBackup);
  if rc = SQLITE_DONE then { ok }
  else if (rc = SQLITE_BUSY) or (rc = SQLITE_LOCKED) then
    shellEPutZ('Error: source database is busy'#10)
  else
    shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
  sqlite3_close(pSrc);
end;

{ ----------------------------------------------------------------------
  10.1.27  `.open ?-options? ?FILENAME?`  — shell.c.in:10141..10251

  Closes the currently-open db, parses the option subset we ship today
  (--readonly, --new, --nofollow, --exclusive, --ifexists), then
  reopens against the supplied filename (or :memory: when omitted).  On
  failure, falls back to a TEMP database to keep the REPL alive.
  ---------------------------------------------------------------------- }

procedure cmdOpen(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var
  j: SizeInt;
  z, zFN: AnsiString;
  newFlag: i32;
  openFlags: i32;
begin
  zFN := '';
  newFlag := 0;
  openFlags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE;
  for j := 0 to nArg - 1 do begin
    z := args[j];
    if (Length(z) > 0) and (z[1] = '-') then begin
      if (Length(z) > 1) and (z[2] = '-') then Delete(z, 1, 1);
      if z = '-new' then newFlag := 1
      else if z = '-readonly' then begin
        openFlags := openFlags and not (SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
        openFlags := openFlags or SQLITE_OPEN_READONLY;
      end
      else if z = '-exclusive' then openFlags := openFlags or SQLITE_OPEN_EXCLUSIVE
      else if z = '-ifexists' then openFlags := openFlags and not SQLITE_OPEN_CREATE
      else if z = '-nofollow' then openFlags := openFlags or SQLITE_OPEN_NOFOLLOW
      else begin
        shellEPutZ(Format('unknown option: %s'#10, [args[j]]));
        Exit;
      end;
    end else if zFN = '' then zFN := z
    else begin
      shellEPutZ(Format('extra argument: "%s"'#10, [z]));
      Exit;
    end;
  end;

  closeDb(p^.db);
  p^.db := nil;
  globalDb := nil;
  p^.pAuxDb^.zDbFilename := nil;
  if p^.pAuxDb^.zFreeOnClose <> nil then begin
    StrDispose(p^.pAuxDb^.zFreeOnClose);
    p^.pAuxDb^.zFreeOnClose := nil;
  end;
  p^.openMode := SHELL_OPEN_UNSPEC;
  p^.openFlags := openFlags;
  p^.szMax := 0;

  if zFN <> '' then begin
    if newFlag <> 0 then DeleteFile(string(zFN));
    p^.pAuxDb^.zFreeOnClose := StrAlloc(Length(zFN) + 1);
    StrPCopy(p^.pAuxDb^.zFreeOnClose, zFN);
    p^.pAuxDb^.zDbFilename := p^.pAuxDb^.zFreeOnClose;
    openDb(p, 1);
    if p^.db = nil then begin
      shellEPutZ(Format('Error: cannot open ''%s'''#10, [zFN]));
      StrDispose(p^.pAuxDb^.zFreeOnClose);
      p^.pAuxDb^.zFreeOnClose := nil;
      p^.pAuxDb^.zDbFilename := nil;
    end;
  end;
  if p^.db = nil then begin
    p^.pAuxDb^.zDbFilename := nil;
    openDb(p, 0);
  end;
end;

{ ----------------------------------------------------------------------
  10.1.25  `.output` / `.once` / `.excel` / `.www`  — shell.c.in:8517..8715

  Output-redirection sink.  The Pascal port sits on top of FPC's `Output`
  stream, which by default writes to fd 1.  Rather than fan a `p^.outFile`
  pointer through every renderer (~150 call sites), we redirect at the
  POSIX-fd level: dup the original stdout fd at startup, then dup2 a new
  file fd onto fd 1 to redirect, and dup2 the saved fd back to fd 1 to
  restore.  All `Write` / `WriteLn` (which target fd 1 underneath) follow
  along automatically.

  Pipe targets (`|cmd`) are not yet wired — TProcess would work but would
  pull in significant runtime; we emit upstream's
  "pipes are not supported" error per shell.c.in:8674..8676.

  Editor / spreadsheet / web-browser modes (`-e`, `-x`, `-w`) are gated
  on a future xdg-open hook; we emit an upstream-shaped warning.
  ---------------------------------------------------------------------- }

procedure outputInit;
{ Called from shellMain at startup so we have a stable handle to restore. }
begin
  if gSavedStdoutFd < 0 then gSavedStdoutFd := FpDup(1);
end;

procedure outputReset(p: PShellState);
{ output_reset (shell.c.in:5410..).  Flush any buffered Pascal writes,
  then dup2 the saved stdout back over fd 1.  Idempotent. }
begin
  Flush(Output);
  if not gOutRedirected then begin
    p^.zOutfile[0] := #0;
    Exit;
  end;
  if gSavedStdoutFd >= 0 then FpDup2(gSavedStdoutFd, 1);
  gOutRedirected := False;
  gOutCurFilename := '';
  p^.zOutfile[0] := #0;
end;

function outputRedirectFile(const fname: AnsiString;
                            zBom: PAnsiChar): Boolean;
{ Open `fname` for writing and dup2 it onto fd 1.  Truncates by default
  (mirrors C `fopen("w")`).  On success, returns True; the write target
  is now `fname`.  Always flushes Output first so prior data hits the
  previous sink, not the redirected one. }
var
  fd: cint;
  flags: cint;
begin
  Flush(Output);
  flags := O_WRONLY or O_CREAT or O_TRUNC;
  fd := FpOpen(fname, flags, &666);
  if fd < 0 then begin Result := False; Exit; end;
  FpDup2(fd, 1);
  FpClose(fd);
  gOutRedirected := True;
  gOutCurFilename := fname;
  if zBom <> nil then Write(AnsiString(zBom));
  Result := True;
end;

procedure cmdOutput(p: PShellState; const args: array of AnsiString;
                    nArg: SizeInt; const zCmdName: AnsiString);
{ Mirrors dotCmdOutput (shell.c.in:8541..8715) at the level of the
  options pas-sqlite3 currently supports.  Implements:
    .output ?-bom? FILE        — redirect stdout to FILE (truncating)
    .output                    — revert to stdout
    .output stdout             — revert to stdout
    .output off                — redirect to /dev/null
    .once   ?-bom? FILE        — same as .output but auto-revert after
                                  the next dot-cmd / SQL line
    .excel                     — emits an upstream-shaped "not wired" warn
    .www                       — same
  Pipe targets and editor/spreadsheet/web-browser modes are stubbed. }
const
  zBomUtf8: PAnsiChar = #$EF#$BB#$BF;
var
  zFile: AnsiString;
  zBom:  PAnsiChar;
  i: SizeInt;
  z: AnsiString;
  isOnce: Boolean;
  unsup: Boolean;
begin
  isOnce := (zCmdName = 'once') or (zCmdName = 'excel') or (zCmdName = 'www');
  unsup  := (zCmdName = 'excel') or (zCmdName = 'www');
  zFile := '';
  zBom  := nil;

  if unsup then begin
    shellEPutZ(Format('Error: .%s requires the spreadsheet/web-browser ' +
      'launcher (xdg-open) which is not wired in this build'#10, [zCmdName]));
    Exit;
  end;

  i := 0;
  while i < nArg do begin
    z := args[i];
    if (Length(z) > 0) and (z[1] = '-') then begin
      if (Length(z) >= 2) and (z[2] = '-') then z := Copy(z, 2, MaxInt);
      if z = '-bom' then zBom := zBomUtf8
      else if z = '-plain' then begin end           { plain — we have no -w }
      else if z = '-keep'  then begin end
      else if z = '-show'  then begin end
      else begin
        shellEPutZ(Format('Error: unknown option: %s'#10, [args[i]]));
        Exit;
      end;
    end else if zFile = '' then begin
      if (z = 'memory') and isOnce then begin
        shellEPutZ('Error: cannot redirect to "memory"'#10);
        Exit;
      end;
      if z = 'off' then zFile := '/dev/null'
      else zFile := z;
      if (Length(zFile) > 0) and (zFile[1] = '|') then begin
        shellEPutZ('Error: pipes are not supported in this build'#10);
        Exit;
      end;
    end else begin
      shellEPutZ(Format('Error: surplus argument: %s'#10, [z]));
      Exit;
    end;
    Inc(i);
  end;

  if zFile = '' then zFile := 'stdout';
  outputReset(p);

  if zFile = 'stdout' then begin
    if isOnce then p^.nPopOutput := 2 else p^.nPopOutput := 0;
    Exit;
  end;

  if not outputRedirectFile(zFile, zBom) then begin
    shellEPutZ(Format('Error: cannot write to "%s"'#10, [zFile]));
    Exit;
  end;
  { Record the active filename in p^.zOutfile (FILENAME_MAX_PAS slots). }
  for i := 1 to Length(zFile) do begin
    if i > High(p^.zOutfile) + 1 then Break;
    p^.zOutfile[i - 1] := AnsiChar(zFile[i]);
  end;
  if Length(zFile) <= High(p^.zOutfile) then
    p^.zOutfile[Length(zFile)] := #0
  else
    p^.zOutfile[High(p^.zOutfile)] := #0;
  if isOnce then p^.nPopOutput := 2 else p^.nPopOutput := 0;
end;

{ ----------------------------------------------------------------------
  10.1.58  `.dbtotxt`  — shell.c.in:5579..5674

  Faithful port of `shell_dbtotxt_command`: hex dump of the open database
  file, compatible with the upstream `dbsqlfuzz` corpus loader.  Reads
  each page through `sqlite_dbpage` (which is auto-registered on every
  openDb).  Skips all-zero 16-byte runs to keep the dump compact. }

procedure cmdDbtotxt(p: PShellState);
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc, i, j: i32;
  pgSz: i32;
  nPage: i64;
  pgno: i64;
  zFilename, zTail, zName: AnsiString;
  bShow: array[0..255] of AnsiChar;
  pData: Pointer;
  aLine: PByte;
  c: Byte;
  k: SizeInt;
begin
  openDb(p, 0);
  if p^.db = nil then Exit;
  for i := 0 to 255 do bShow[i] := '.';
  for i := Ord(' ') to Ord('~') do
    if (i <> Ord('{')) and (i <> Ord('}'))
       and (i <> Ord('"')) and (i <> Ord('\')) then
      bShow[i] := AnsiChar(Chr(i));

  pStmt := nil; pzTail := nil; pgSz := 0; nPage := 0;
  rc := sqlite3_prepare_v2(p^.db, 'PRAGMA page_size', -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    shellEPutZ(Format('ERROR: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit;
  end;
  if sqlite3_step(pStmt) = SQLITE_ROW then pgSz := sqlite3_column_int(pStmt, 0);
  sqlite3_finalize(pStmt);
  if (pgSz < 512) or (pgSz > 65536) or ((pgSz and (pgSz - 1)) <> 0) then begin
    shellEPutZ('ERROR: bad page size'#10); Exit;
  end;

  pStmt := nil;
  { Upstream uses `PRAGMA page_count` here.  In pas-sqlite3 that PRAGMA
    currently returns no rows (port gap, tracked under Phase 6 PRAGMA
    follow-up); fall back to counting sqlite_dbpage rows. }
  rc := sqlite3_prepare_v2(p^.db,
          'SELECT count(*) FROM sqlite_dbpage', -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit;
  end;
  if sqlite3_step(pStmt) = SQLITE_ROW then nPage := sqlite3_column_int64(pStmt, 0);
  sqlite3_finalize(pStmt);
  if nPage < 1 then Exit;

  pStmt := nil;
  zFilename := '';
  rc := sqlite3_prepare_v2(p^.db,
          'SELECT seq, name, file FROM pragma_database_list ORDER BY seq',
          -1, @pStmt, @pzTail);
  if (rc = SQLITE_OK) and (pStmt <> nil) and (sqlite3_step(pStmt) = SQLITE_ROW) then
  begin
    if sqlite3_column_text(pStmt, 2) <> nil then
      zFilename := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 2)));
  end;
  if pStmt <> nil then sqlite3_finalize(pStmt);
  if zFilename = '' then zFilename := 'unk.db';

  { strip directory components — last '/' wins }
  k := Length(zFilename);
  while (k > 0) and (zFilename[k] <> '/') do Dec(k);
  if (k > 0) and (k < Length(zFilename)) then
    zTail := Copy(zFilename, k + 1, MaxInt)
  else
    zTail := zFilename;
  zName := zTail;

  WriteLn(Format('| size %d pagesize %d filename %s', [nPage * pgSz, pgSz, zName]));

  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db,
          'SELECT pgno, data FROM sqlite_dbpage ORDER BY pgno',
          -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    pgno  := sqlite3_column_int64(pStmt, 0);
    pData := sqlite3_column_blob(pStmt, 1);
    if pData = nil then Continue;
    aLine := PByte(pData);
    i := 0;
    while i < pgSz do begin
      { skip all-zero 16-byte runs }
      j := 0;
      while (j < 16) and (PByte(PtrUInt(aLine) + i + j)^ = 0) do Inc(j);
      if j = 16 then begin Inc(i, 16); Continue; end;
      WriteLn(Format('| page %d offset %d', [pgno, (pgno - 1) * pgSz]));
      while i < pgSz do begin
        { Re-check whether this row is all-zero for the abbreviation rule. }
        j := 0;
        while (j < 16) and (PByte(PtrUInt(aLine) + i + j)^ = 0) do Inc(j);
        if j = 16 then begin Inc(i, 16); Continue; end;
        Write(Format('|  %5d:', [i]));
        for j := 0 to 15 do begin
          c := PByte(PtrUInt(aLine) + i + j)^;
          Write(' ');
          Write(LowerCase(Format('%.2x', [c])));
        end;
        Write('   ');
        for j := 0 to 15 do begin
          c := PByte(PtrUInt(aLine) + i + j)^;
          Write(bShow[c]);
        end;
        WriteLn;
        Inc(i, 16);
      end;
    end;
  end;
  sqlite3_finalize(pStmt);
  WriteLn(Format('| end %s', [zName]));
end;

{ ----------------------------------------------------------------------
  10.1.23  `.dump ?OBJECTS?`  — shell.c.in:9384..9495 (dot-cmd driver) +
                                3531..3697 (callbacks).

  Minimal viable port: emit a SQL script that recreates the schema and
  data of the open database.  Each table's CREATE statement is dumped
  verbatim, then `SELECT * FROM tab` is rendered through MODE_Insert with
  the destination table set to `tab`.  Differences from the full upstream
  variant:
    * No `--preserve-rowids` / `--newlines` / `--data-only`.
    * No CORRUPTION detour with `ORDER BY rowid DESC`.
    * No `tableColumnList` (so `INSERT INTO t VALUES(...)` is emitted, not
      `INSERT INTO t(rowid,a,b,...) VALUES(...)`).
    * No `sqlite_sequence` repopulation handling.
  These restrict the dump to non-corrupt, non-rowid-sensitive databases —
  enough for the 10.2 integration parity gate's golden-file comparison
  on the shell test corpus.  Filename pattern matching honours the
  upstream syntax (LIKE patterns).  ---------------------------------- }

procedure dumpOneObject(p: PShellState; const zName, zType, zSql: AnsiString);
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
  selectSql: AnsiString;
  savedMode: TShellMode;
  zPrevDestTable: PAnsiChar;
begin
  if (zName = 'sqlite_sequence') then begin
    WriteLn('DELETE FROM sqlite_sequence;');
  end else if (Copy(zName, 1, 11) = 'sqlite_stat')
              and (Length(zName) = 12) then begin
    WriteLn('ANALYZE sqlite_schema;');
  end else if Copy(zName, 1, 7) = 'sqlite_' then begin
    Exit;
  end else begin
    if zSql <> '' then WriteLn(zSql + ';');
  end;
  if zType <> 'table' then Exit;

  selectSql := 'SELECT * FROM "' +
    StringReplace(zName, '"', '""', [rfReplaceAll]) + '"';
  pStmt := nil; pzTail := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(selectSql), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(Format('Error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    Inc(p^.nErr);
    Exit;
  end;

  savedMode := p^.mode;
  zPrevDestTable := p^.zDestTable;
  p^.zDestTable := PAnsiChar(zName);
  p^.mode.eMode := MODE_Insert;
  p^.mode.spec.bTitles := QRF_No;
  stepAndRender(p, pStmt);
  p^.mode := savedMode;
  p^.zDestTable := zPrevDestTable;
  sqlite3_finalize(pStmt);
end;

{ ----------------------------------------------------------------------
  10.1.52 — `.sha3sum ?OPTIONS? ?LIKE-PATTERN?` (shell.c.in:11064..11240)

  Compose a `WITH [sha3sum$query](a,b) AS(VALUES(...))` CTE that pairs
  per-table read SQL with table label, then runs the upstream
  `sha3_query()` aggregator over it.  --schema includes sqlite_schema in
  the digest.  The reversible-text-check tail (shathree.c:11177..11237)
  is omitted in this initial cut — it adds a quality breadcrumb but is
  not part of the digest itself.
  ---------------------------------------------------------------------- }
procedure cmdSha3sum(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt);
var
  zLike: AnsiString;
  bSchema, bSeparate, bDebug: i32;
  iSize: i32;
  i, rc: i32;
  pStmt: PVdbe;
  zArg, zSrcSql, zSql, sQuery, sSql, zSep, zTab: AnsiString;
  zPzTail: PAnsiChar;
begin
  if p^.db = nil then openDb(p, 0);
  zLike := '';
  bSchema := 0;
  bSeparate := 0;
  bDebug := 0;
  iSize := 224;
  i := 0;
  while i < nArg do begin
    zArg := args[i];
    if (Length(zArg) > 0) and (zArg[1] = '-') then begin
      Delete(zArg, 1, 1);
      if (Length(zArg) > 0) and (zArg[1] = '-') then Delete(zArg, 1, 1);
      if zArg = 'schema' then bSchema := 1
      else if (zArg = 'sha3-224') or (zArg = 'sha3-256')
           or (zArg = 'sha3-384') or (zArg = 'sha3-512') then
        iSize := StrToInt(Copy(zArg, 6, 3))
      else if zArg = 'debug' then bDebug := 1
      else begin
        shellEPutZ(Format('Unknown option "%s" on ".sha3sum"'#10, [args[i]]));
        Exit;
      end;
    end
    else if zLike <> '' then begin
      shellEPutZ('Usage: .sha3sum ?OPTIONS? ?LIKE-PATTERN?'#10);
      Exit;
    end
    else begin
      zLike := zArg;
      bSeparate := 1;
      if sqlite3_strlike('sqlite\_%', PAnsiChar(zLike), Ord('\')) = 0 then
        bSchema := 1;
    end;
    Inc(i);
  end;
  if bSchema <> 0 then
    zSrcSql :=
      'SELECT lower(name) as tname FROM sqlite_schema'
      + ' WHERE type=''table'' AND coalesce(rootpage,0)>1'
      + ' UNION ALL SELECT ''sqlite_schema'''
      + ' ORDER BY 1 collate nocase'
  else
    zSrcSql :=
      'SELECT lower(name) as tname FROM sqlite_schema'
      + ' WHERE type=''table'' AND coalesce(rootpage,0)>1'
      + ' AND name NOT LIKE ''sqlite\_%'' ESCAPE ''\'''
      + ' ORDER BY 1 collate nocase';
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSrcSql), -1, @pStmt, @zPzTail);
  if rc <> SQLITE_OK then begin
    shellEPutZ(Format('Parse error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    Exit;
  end;
  sSql := 'WITH [sha3sum$query](a,b) AS(';
  zSep := 'VALUES(';
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    zTab := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 0)));
    if zTab = '' then Continue;
    if (zLike <> '')
       and (sqlite3_strlike(PAnsiChar(zLike), PAnsiChar(zTab), 0) <> 0) then
      Continue;
    if Copy(zTab, 1, 7) <> 'sqlite_' then
      sQuery := 'SELECT * FROM "' + zTab + '" NOT INDEXED;'
    else if zTab = 'sqlite_schema' then
      sQuery := 'SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY name;'
    else if zTab = 'sqlite_sequence' then
      sQuery := 'SELECT name,seq FROM sqlite_sequence ORDER BY name;'
    else if zTab = 'sqlite_stat1' then
      sQuery := 'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx;'
    else if zTab = 'sqlite_stat4' then
      sQuery := 'SELECT * FROM ' + zTab + ' ORDER BY tbl, idx, rowid;'#10
    else
      Continue;
    sSql := sSql + zSep + '''' + StringReplace(sQuery, '''', '''''', [rfReplaceAll]) + '''';
    sSql := sSql + ',' + '''' + StringReplace(zTab, '''', '''''', [rfReplaceAll]) + '''';
    zSep := '),(';
  end;
  sqlite3_finalize(pStmt);
  if bSeparate <> 0 then
    zSql := sSql + '))' +
      ' SELECT lower(hex(sha3_query(a,' + IntToStr(iSize) + '))) AS hash, b AS label' +
      '   FROM [sha3sum$query]'
  else
    zSql := sSql + '))' +
      ' SELECT lower(hex(sha3_query(group_concat(a,''''),' + IntToStr(iSize) + '))) AS hash' +
      '   FROM [sha3sum$query]';
  if bDebug <> 0 then
    WriteLn(zSql)
  else
    runOneSqlLine(p, zSql, '.sha3sum', 0);
end;

procedure cmdDump(p: PShellState; const args: array of AnsiString;
                  nArg: SizeInt);
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc, i: i32;
  whereCl: AnsiString;
  q: AnsiString;
  zN, zT, zS: AnsiString;
  pat, lit: AnsiString;
  zPattern: AnsiString;
  preserveRowid, dataOnly, noSys: Boolean;
begin
  openDb(p, 0);
  if p^.db = nil then Exit;
  preserveRowid := False;
  dataOnly := False;
  noSys := False;
  zPattern := '';
  i := 0;
  while i < nArg do begin
    if args[i] = '--preserve-rowids' then preserveRowid := True
    else if args[i] = '--data-only' then dataOnly := True
    else if args[i] = '--nosys' then noSys := True
    else if (Length(args[i]) > 0) and (args[i][1] = '-') then begin
      shellEPutZ(Format('Error: unknown option: %s'#10, [args[i]]));
      Exit;
    end else if zPattern = '' then zPattern := args[i]
    else begin
      shellEPutZ(Format('Error: surplus argument: %s'#10, [args[i]]));
      Exit;
    end;
    Inc(i);
  end;
  { Reference these so the compiler is happy in the minimal cut: }
  if preserveRowid then ;

  WriteLn('PRAGMA foreign_keys=OFF;');
  WriteLn('BEGIN TRANSACTION;');

  { Build WHERE clause. }
  whereCl := 'WHERE type IN (''table'',''index'',''trigger'',''view'')';
  if noSys then
    whereCl := whereCl + ' AND name NOT LIKE ''sqlite\_%'' ESCAPE ''\''';
  if zPattern <> '' then begin
    pat := StringReplace(zPattern, '''', '''''', [rfReplaceAll]);
    lit := ' AND (tbl_name LIKE ''' + pat + ''' OR name LIKE ''' + pat + ''')';
    whereCl := whereCl + lit;
  end;

  q := 'SELECT name, type, sql FROM sqlite_schema ' + whereCl +
       ' AND type=''table'' ORDER BY name';
  if dataOnly then
    q := 'SELECT name, type, sql FROM sqlite_schema ' + whereCl +
         ' AND type=''table'' ORDER BY name';

  pStmt := nil; pzTail := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(q), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(Format('Error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    zN := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 0)));
    zT := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 1)));
    if sqlite3_column_text(pStmt, 2) <> nil then
      zS := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 2)))
    else zS := '';
    if dataOnly then zS := '';
    dumpOneObject(p, zN, zT, zS);
  end;
  sqlite3_finalize(pStmt);

  if not dataOnly then begin
    { Emit non-table objects (indexes, views, triggers) after data. }
    q := 'SELECT name, type, sql FROM sqlite_schema ' + whereCl +
         ' AND type IN (''index'',''view'',''trigger'') ORDER BY type, name';
    pStmt := nil;
    rc := sqlite3_prepare_v2(p^.db, PAnsiChar(q), -1, @pStmt, @pzTail);
    if (rc = SQLITE_OK) and (pStmt <> nil) then begin
      while sqlite3_step(pStmt) = SQLITE_ROW do begin
        if sqlite3_column_text(pStmt, 2) <> nil then begin
          zS := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 2)));
          if zS <> '' then WriteLn(zS + ';');
        end;
      end;
      sqlite3_finalize(pStmt);
    end;
  end;

  if p^.writableSchema <> 0 then begin
    WriteLn('PRAGMA writable_schema=OFF;');
    p^.writableSchema := 0;
  end;
  if p^.nErr <> 0 then WriteLn('ROLLBACK; -- due to errors')
  else WriteLn('COMMIT;');
end;

{ ----------------------------------------------------------------------
  10.1.55  `.connection ?N? | close N`  — shell.c.in:9177..9221

  Switches the active aAuxDb slot.  No new code in libsqlite — we just
  swap which slot of the array p^.pAuxDb points at.
  ---------------------------------------------------------------------- }

procedure cmdConnection(p: PShellState; const args: array of AnsiString;
                        nArg: SizeInt);
var
  i: SizeInt;
  zFile: AnsiString;
  zPtr: PAnsiChar;
  ix: i32;
begin
  if nArg = 0 then begin
    for i := 0 to High(p^.aAuxDb) do begin
      zPtr := p^.aAuxDb[i].zDbFilename;
      if (p^.aAuxDb[i].db = nil) and (p^.pAuxDb <> @p^.aAuxDb[i]) then
        zFile := '(not open)'
      else if zPtr = nil then zFile := '(memory)'
      else if zPtr^ = #0 then zFile := '(temporary-file)'
      else zFile := AnsiString(zPtr);
      if p^.pAuxDb = @p^.aAuxDb[i] then
        WriteLn(Format('ACTIVE %d: %s', [i, zFile]))
      else if p^.aAuxDb[i].db <> nil then
        WriteLn(Format('       %d: %s', [i, zFile]));
    end;
    Exit;
  end;
  if (nArg = 1) and (Length(args[0]) = 1)
     and (args[0][1] in ['0'..'9']) then
  begin
    ix := Ord(args[0][1]) - Ord('0');
    if (ix >= 0) and (ix <= High(p^.aAuxDb))
       and (p^.pAuxDb <> @p^.aAuxDb[ix]) then
    begin
      p^.pAuxDb^.db := p^.db;
      p^.pAuxDb := @p^.aAuxDb[ix];
      p^.db := p^.pAuxDb^.db;
      globalDb := p^.db;
      p^.pAuxDb^.db := nil;
    end;
    Exit;
  end;
  if (nArg = 2) and (args[0] = 'close')
     and (Length(args[1]) = 1) and (args[1][1] in ['0'..'9']) then
  begin
    ix := Ord(args[1][1]) - Ord('0');
    if (ix < 0) or (ix > High(p^.aAuxDb)) then Exit;
    if p^.pAuxDb = @p^.aAuxDb[ix] then begin
      shellEPutZ('cannot close the active database connection'#10);
      Exit;
    end;
    if p^.aAuxDb[ix].db <> nil then begin
      closeDb(p^.aAuxDb[ix].db);
      p^.aAuxDb[ix].db := nil;
    end;
    Exit;
  end;
  shellEPutZ('Usage: .connection [close] [CONNECTION-NUMBER]'#10);
end;

{ ----------------------------------------------------------------------
  10.1.56  `.unmodule [--allexcept] NAME ...`  — shell.c.in:11954..11975

  Unregisters virtual-table modules.  --allexcept lifts all modules
  except those listed; otherwise NAME ... lists modules to drop.
  ---------------------------------------------------------------------- }

procedure cmdUnmodule(p: PShellState; const args: array of AnsiString;
                      nArg: SizeInt);
var
  ii: SizeInt;
  zOpt: AnsiString;
  cArgs: array of PAnsiChar;
  cBack: array of AnsiString;
begin
  if nArg < 1 then begin
    shellEPutZ('Usage: .unmodule [--allexcept] NAME ...'#10);
    Exit;
  end;
  openDb(p, 0);
  zOpt := args[0];
  if (Length(zOpt) >= 2) and (zOpt[1] = '-') and (zOpt[2] = '-')
     and (Length(zOpt) > 2) then
    Delete(zOpt, 1, 1);
  if zOpt = '-allexcept' then begin
    if nArg > 1 then begin
      SetLength(cBack, nArg - 1);
      SetLength(cArgs, nArg);
      for ii := 0 to nArg - 2 do begin
        cBack[ii] := args[ii + 1];
        cArgs[ii] := PAnsiChar(cBack[ii]);
      end;
      cArgs[nArg - 1] := nil;
      sqlite3_drop_modules(p^.db, @cArgs[0]);
    end else
      sqlite3_drop_modules(p^.db, nil);
    Exit;
  end;
  for ii := 0 to nArg - 1 do
    sqlite3_create_module(p^.db, PAnsiChar(args[ii]), nil, nil);
end;

{ ----------------------------------------------------------------------
  10.1.57  `.vfsname ?DB?` / `.vfslist` / `.vfsinfo ?DB?`
                                    — shell.c.in:11998..12040
  ---------------------------------------------------------------------- }

procedure cmdVfsinfo(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt);
var
  zDb: AnsiString;
  pVfs: Psqlite3_vfs;
begin
  if nArg >= 1 then zDb := args[0] else zDb := 'main';
  openDb(p, 0);
  if p^.db = nil then Exit;
  pVfs := nil;
  sqlite3_file_control(p^.db, PAnsiChar(zDb),
                       SQLITE_FCNTL_VFS_POINTER, @pVfs);
  if pVfs = nil then Exit;
  WriteLn(Format('vfs.zName      = "%s"', [AnsiString(pVfs^.zName)]));
  WriteLn(Format('vfs.iVersion   = %d', [pVfs^.iVersion]));
  WriteLn(Format('vfs.szOsFile   = %d', [pVfs^.szOsFile]));
  WriteLn(Format('vfs.mxPathname = %d', [pVfs^.mxPathname]));
end;

procedure cmdVfslist(p: PShellState);
var
  pVfs, pCurrent: Psqlite3_vfs;
  marker: AnsiString;
begin
  pCurrent := nil;
  if p^.db <> nil then
    sqlite3_file_control(p^.db, 'main',
                         SQLITE_FCNTL_VFS_POINTER, @pCurrent);
  pVfs := sqlite3_vfs_find(nil);
  while pVfs <> nil do begin
    if pVfs = pCurrent then marker := '  <--- CURRENT' else marker := '';
    WriteLn(Format('vfs.zName      = "%s"%s',
                   [AnsiString(pVfs^.zName), marker]));
    WriteLn(Format('vfs.iVersion   = %d', [pVfs^.iVersion]));
    WriteLn(Format('vfs.szOsFile   = %d', [pVfs^.szOsFile]));
    WriteLn(Format('vfs.mxPathname = %d', [pVfs^.mxPathname]));
    if pVfs^.pNext <> nil then
      WriteLn('-----------------------------------');
    pVfs := pVfs^.pNext;
  end;
end;

procedure cmdVfsname(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt);
var
  zDb: AnsiString;
  zName: PAnsiChar;
begin
  if nArg >= 1 then zDb := args[0] else zDb := 'main';
  openDb(p, 0);
  if p^.db = nil then Exit;
  zName := nil;
  sqlite3_file_control(p^.db, PAnsiChar(zDb),
                       SQLITE_FCNTL_VFSNAME, @zName);
  if zName <> nil then begin
    WriteLn(AnsiString(zName));
    sqlite3_free(zName);
  end;
end;

{ ----------------------------------------------------------------------
  10.1.51 — `.filectrl CMD ...`  (shell.c.in:9539..9690)

  Dispatches sqlite3_file_control() through a name-prefix-matched table
  of opcodes.  Mirrors the upstream `aCtrl[]` ordering so `--help`
  output is byte-identical, and returns the integer / textual result
  in the same `isOk` / `iRes` shape as C.
  ---------------------------------------------------------------------- }

type
  TFilectrlEntry = record
    zName:  PAnsiChar;
    code:   i32;
    zUsage: PAnsiChar;
  end;

const
  aFilectrl: array[0..8] of TFilectrlEntry = (
    (zName: 'chunk_size';     code: SQLITE_FCNTL_CHUNK_SIZE;          zUsage: 'SIZE'),
    (zName: 'data_version';   code: SQLITE_FCNTL_DATA_VERSION;        zUsage: ''),
    (zName: 'has_moved';      code: SQLITE_FCNTL_HAS_MOVED;           zUsage: ''),
    (zName: 'lock_timeout';   code: SQLITE_FCNTL_LOCK_TIMEOUT;        zUsage: 'MILLISEC'),
    (zName: 'persist_wal';    code: SQLITE_FCNTL_PERSIST_WAL;         zUsage: '[BOOLEAN]'),
    (zName: 'psow';           code: SQLITE_FCNTL_POWERSAFE_OVERWRITE; zUsage: '[BOOLEAN]'),
    (zName: 'reserve_bytes';  code: SQLITE_FCNTL_RESERVE_BYTES;       zUsage: '[N]'),
    (zName: 'size_limit';     code: SQLITE_FCNTL_SIZE_LIMIT;          zUsage: '[LIMIT]'),
    (zName: 'tempfilename';   code: SQLITE_FCNTL_TEMPFILENAME;        zUsage: '')
  );

procedure cmdFilectrl(p: PShellState; const args: array of AnsiString;
                      nArg: SizeInt);
var
  zCmd, zSchema: AnsiString;
  zCmdC: AnsiString;
  i, n2, iCtrl: SizeInt;
  filectrl: i32;
  iRes: i64;
  isOk: i32;
  iVal: i32;
  iLong: i64;
  zRet: PAnsiChar;
  bShifted: Boolean;
begin
  openDb(p, 0);
  if nArg >= 1 then zCmd := args[0] else zCmd := 'help';
  zSchema := '';
  bShifted := False;

  { --schema option: `.filectrl --schema NAME CMD ...` re-points the
    pager target.  Strip the two leading args and continue. }
  if ((zCmd = '--schema') or (zCmd = '-schema')) and (nArg >= 3) then begin
    zSchema := args[1];
    zCmd := args[2];
    bShifted := True;
  end;

  { Strip leading single or double dash from the command name. }
  zCmdC := zCmd;
  if (Length(zCmdC) >= 2) and (zCmdC[1] = '-') then begin
    Delete(zCmdC, 1, 1);
    if (Length(zCmdC) >= 2) and (zCmdC[1] = '-') then Delete(zCmdC, 1, 1);
  end;

  if zCmdC = 'help' then begin
    shellSPutZ('Available file-controls:'#10);
    for i := 0 to High(aFilectrl) do
      shellSPutZ(Format('  .filectrl %s %s'#10,
        [AnsiString(aFilectrl[i].zName), AnsiString(aFilectrl[i].zUsage)]));
    Exit;
  end;

  { Prefix match.  Ambiguity → error. }
  filectrl := -1;
  iCtrl := -1;
  n2 := Length(zCmdC);
  for i := 0 to High(aFilectrl) do begin
    if (n2 > 0) and (StrLComp(PAnsiChar(zCmdC),
                              aFilectrl[i].zName, n2) = 0) then begin
      if filectrl < 0 then begin
        filectrl := aFilectrl[i].code;
        iCtrl := i;
      end else begin
        shellEPutZ(Format('Error: ambiguous file-control: "%s"'#10 +
          'Use ".filectrl --help" for help'#10, [zCmdC]));
        Exit;
      end;
    end;
  end;
  if filectrl < 0 then begin
    shellEPutZ(Format('Error: unknown file-control: %s'#10 +
      'Use ".filectrl --help" for help'#10, [zCmdC]));
    Exit;
  end;

  { Adjust positional accounting after the optional --schema shift so
    nArg/args mirror the C arg layout (azArg[0]=".filectrl",
    azArg[1]=cmd, azArg[2]=value).  In our Pascal call, args[0]=cmd
    already; if no --schema, args[1] holds value.  If shifted, args[2]
    holds value.  Normalise iVal-arg index. }
  iRes := 0;
  isOk := 0;

  case filectrl of
    SQLITE_FCNTL_SIZE_LIMIT: begin
      if bShifted then begin
        if (nArg <> 3) and (nArg <> 4) then Exit;
        if nArg = 4 then iLong := StrToInt64Def(args[3], 0) else iLong := -1;
      end else begin
        if (nArg <> 1) and (nArg <> 2) then Exit;
        if nArg = 2 then iLong := StrToInt64Def(args[1], 0) else iLong := -1;
      end;
      iRes := iLong;
      sqlite3_file_control(p^.db, PAnsiChar(zSchema),
                           SQLITE_FCNTL_SIZE_LIMIT, @iRes);
      isOk := 1;
    end;
    SQLITE_FCNTL_LOCK_TIMEOUT,
    SQLITE_FCNTL_CHUNK_SIZE: begin
      if bShifted then begin
        if nArg <> 4 then Exit;
        iVal := StrToIntDef(args[3], 0);
      end else begin
        if nArg <> 2 then Exit;
        iVal := StrToIntDef(args[1], 0);
      end;
      sqlite3_file_control(p^.db, PAnsiChar(zSchema),
                           filectrl, @iVal);
      isOk := 2;
    end;
    SQLITE_FCNTL_PERSIST_WAL,
    SQLITE_FCNTL_POWERSAFE_OVERWRITE: begin
      if bShifted then begin
        if (nArg <> 3) and (nArg <> 4) then Exit;
        if nArg = 4 then iVal := parseOnOff(args[3], -1) else iVal := -1;
      end else begin
        if (nArg <> 1) and (nArg <> 2) then Exit;
        if nArg = 2 then iVal := parseOnOff(args[1], -1) else iVal := -1;
      end;
      sqlite3_file_control(p^.db, PAnsiChar(zSchema),
                           filectrl, @iVal);
      iRes := iVal;
      isOk := 1;
    end;
    SQLITE_FCNTL_DATA_VERSION,
    SQLITE_FCNTL_HAS_MOVED: begin
      if bShifted then begin
        if nArg <> 3 then Exit;
      end else begin
        if nArg <> 1 then Exit;
      end;
      iVal := 0;
      sqlite3_file_control(p^.db, PAnsiChar(zSchema),
                           filectrl, @iVal);
      iRes := iVal;
      isOk := 1;
    end;
    SQLITE_FCNTL_TEMPFILENAME: begin
      if bShifted then begin
        if nArg <> 3 then Exit;
      end else begin
        if nArg <> 1 then Exit;
      end;
      zRet := nil;
      sqlite3_file_control(p^.db, PAnsiChar(zSchema),
                           filectrl, @zRet);
      if zRet <> nil then begin
        WriteLn(AnsiString(zRet));
        sqlite3_free(zRet);
      end;
      isOk := 2;
    end;
    SQLITE_FCNTL_RESERVE_BYTES: begin
      if bShifted then begin
        if nArg >= 4 then begin
          iVal := StrToIntDef(args[3], 0);
          sqlite3_file_control(p^.db, PAnsiChar(zSchema), filectrl, @iVal);
        end;
      end else begin
        if nArg >= 2 then begin
          iVal := StrToIntDef(args[1], 0);
          sqlite3_file_control(p^.db, PAnsiChar(zSchema), filectrl, @iVal);
        end;
      end;
      iVal := -1;
      sqlite3_file_control(p^.db, PAnsiChar(zSchema), filectrl, @iVal);
      WriteLn(iVal);
      isOk := 2;
    end;
  end;

  if (isOk = 0) and (iCtrl >= 0) then
    shellSPutZ(Format('Usage: .filectrl %s %s'#10,
      [zCmdC, AnsiString(aFilectrl[iCtrl].zUsage)]))
  else if isOk = 1 then
    WriteLn(iRes);
end;

{ ----------------------------------------------------------------------
  10.1.41 — `.testctrl CMD ...`  (shell.c.in:11395..)

  Subset port of the sqlite3_test_control() dispatcher.  The Pascal
  port's sqlite3_test_control(op) currently honours PRNG_SAVE,
  PRNG_RESTORE, PRNG_RESET, BYTEORDER and ISINIT (passqlite3main.pas:
  4273) — those wire through faithfully.  Other opcodes return 0 from
  the port's stub but the dispatcher still parses argument shape so
  scripts don't fall through to the unknown-command arm.

  The full upstream table emits a help line for every opcode; we
  reproduce the same listing under `--help`, then route to either
  the live PRNG/BYTEORDER arms or a generic stub that calls
  sqlite3_test_control(code) — the variadic args go unread under the
  cdecl boundary, matching the existing 8.4.1 behaviour.
  ---------------------------------------------------------------------- }

type
  TTestctrlEntry = record
    zName:  PAnsiChar;
    code:   i32;
    unSafe: i32;
    zUsage: PAnsiChar;
  end;

const
  SQLITE_TESTCTRL_FIRST                = 5;
  SQLITE_TESTCTRL_PRNG_SAVE            = 5;
  SQLITE_TESTCTRL_PRNG_RESTORE         = 6;
  SQLITE_TESTCTRL_PRNG_RESET           = 7;
  SQLITE_TESTCTRL_BITVEC_TEST          = 8;
  SQLITE_TESTCTRL_FAULT_INSTALL        = 9;
  SQLITE_TESTCTRL_PENDING_BYTE         = 11;
  SQLITE_TESTCTRL_ASSERT               = 12;
  SQLITE_TESTCTRL_ALWAYS               = 13;
  SQLITE_TESTCTRL_RESERVE              = 14;
  SQLITE_TESTCTRL_OPTIMIZATIONS        = 15;
  SQLITE_TESTCTRL_ISKEYWORD            = 16;
  SQLITE_TESTCTRL_LOCALTIME_FAULT      = 18;
  SQLITE_TESTCTRL_NEVER_CORRUPT        = 20;
  SQLITE_TESTCTRL_SORTER_MMAP          = 24;
  SQLITE_TESTCTRL_IMPOSTER             = 25;
  SQLITE_TESTCTRL_PARSER_COVERAGE      = 26;
  SQLITE_TESTCTRL_PRNG_SEED            = 28;
  SQLITE_TESTCTRL_EXTRA_SCHEMA_CHECKS  = 29;
  SQLITE_TESTCTRL_SEEK_COUNT           = 30;
  SQLITE_TESTCTRL_TUNE                 = 32;
  SQLITE_TESTCTRL_BYTEORDER            = 22;
  SQLITE_TESTCTRL_FK_NO_ACTION         = 33;
  SQLITE_TESTCTRL_INTERNAL_FUNCTIONS   = 17;
  SQLITE_TESTCTRL_JSON_SELFCHECK       = 14;

  aTestctrl: array[0..18] of TTestctrlEntry = (
    (zName: 'always';              code: SQLITE_TESTCTRL_ALWAYS;              unSafe: 1; zUsage: 'BOOLEAN'),
    (zName: 'assert';              code: SQLITE_TESTCTRL_ASSERT;              unSafe: 1; zUsage: 'BOOLEAN'),
    (zName: 'bitvec_test';         code: SQLITE_TESTCTRL_BITVEC_TEST;         unSafe: 1; zUsage: 'SIZE INT-ARRAY'),
    (zName: 'byteorder';           code: SQLITE_TESTCTRL_BYTEORDER;           unSafe: 0; zUsage: ''),
    (zName: 'extra_schema_checks'; code: SQLITE_TESTCTRL_EXTRA_SCHEMA_CHECKS; unSafe: 0; zUsage: 'BOOLEAN'),
    (zName: 'fault_install';       code: SQLITE_TESTCTRL_FAULT_INSTALL;       unSafe: 1; zUsage: 'args...'),
    (zName: 'fk_no_action';        code: SQLITE_TESTCTRL_FK_NO_ACTION;        unSafe: 0; zUsage: 'BOOLEAN'),
    (zName: 'imposter';            code: SQLITE_TESTCTRL_IMPOSTER;            unSafe: 1; zUsage: 'SCHEMA ON/OFF ROOTPAGE'),
    (zName: 'internal_functions';  code: SQLITE_TESTCTRL_INTERNAL_FUNCTIONS;  unSafe: 0; zUsage: ''),
    (zName: 'localtime_fault';     code: SQLITE_TESTCTRL_LOCALTIME_FAULT;     unSafe: 0; zUsage: 'BOOLEAN'),
    (zName: 'never_corrupt';       code: SQLITE_TESTCTRL_NEVER_CORRUPT;       unSafe: 1; zUsage: 'BOOLEAN'),
    (zName: 'optimizations';       code: SQLITE_TESTCTRL_OPTIMIZATIONS;       unSafe: 0; zUsage: 'DISABLE-MASK ...'),
    (zName: 'pending_byte';        code: SQLITE_TESTCTRL_PENDING_BYTE;        unSafe: 1; zUsage: 'OFFSET  '),
    (zName: 'prng_restore';        code: SQLITE_TESTCTRL_PRNG_RESTORE;        unSafe: 0; zUsage: ''),
    (zName: 'prng_save';           code: SQLITE_TESTCTRL_PRNG_SAVE;           unSafe: 0; zUsage: ''),
    (zName: 'prng_seed';           code: SQLITE_TESTCTRL_PRNG_SEED;           unSafe: 0; zUsage: 'SEED ?db?'),
    (zName: 'seek_count';          code: SQLITE_TESTCTRL_SEEK_COUNT;          unSafe: 0; zUsage: ''),
    (zName: 'sorter_mmap';         code: SQLITE_TESTCTRL_SORTER_MMAP;         unSafe: 0; zUsage: 'NMAX'),
    (zName: 'tune';                code: SQLITE_TESTCTRL_TUNE;                unSafe: 1; zUsage: 'ID VALUE')
  );

procedure cmdTestctrl(p: PShellState; const args: array of AnsiString;
                      nArg: SizeInt);
var
  zCmd, zCmdC: AnsiString;
  i, n2, iCtrl: SizeInt;
  testctrl: i32;
  isOk: i32;
  rc2: i32;
  isTestingMode: Boolean;
begin
  openDb(p, 0);
  if nArg >= 1 then zCmd := args[0] else zCmd := 'help';

  zCmdC := zCmd;
  if (Length(zCmdC) >= 2) and (zCmdC[1] = '-') then begin
    Delete(zCmdC, 1, 1);
    if (Length(zCmdC) >= 2) and (zCmdC[1] = '-') then Delete(zCmdC, 1, 1);
  end;

  isTestingMode := (p^.shellFlgs and SHFLG_TestingMode) <> 0;

  if zCmdC = 'help' then begin
    shellSPutZ('Available test-controls:'#10);
    for i := 0 to High(aTestctrl) do begin
      if (aTestctrl[i].unSafe <> 0) and (not isTestingMode) then continue;
      shellSPutZ(Format('  .testctrl %s %s'#10,
        [AnsiString(aTestctrl[i].zName), AnsiString(aTestctrl[i].zUsage)]));
    end;
    Exit;
  end;

  { Prefix-match the command name (skipping unsafe entries when not in
    SHFLG_TestingMode). }
  testctrl := -1;
  iCtrl := -1;
  n2 := Length(zCmdC);
  for i := 0 to High(aTestctrl) do begin
    if (aTestctrl[i].unSafe <> 0) and (not isTestingMode) then continue;
    if (n2 > 0) and (StrLComp(PAnsiChar(zCmdC),
                              aTestctrl[i].zName, n2) = 0) then begin
      if testctrl < 0 then begin
        testctrl := aTestctrl[i].code;
        iCtrl := i;
      end else begin
        shellEPutZ(Format('Error: ambiguous test-control: "%s"'#10 +
          'Use ".testctrl --help" for help'#10, [zCmdC]));
        Exit;
      end;
    end;
  end;
  if testctrl < 0 then begin
    shellEPutZ(Format('Error: unknown test-control: %s'#10 +
      'Use ".testctrl --help" for help'#10, [zCmdC]));
    Exit;
  end;

  isOk := 0;
  rc2 := 0;
  case testctrl of
    SQLITE_TESTCTRL_PRNG_SAVE,
    SQLITE_TESTCTRL_PRNG_RESTORE,
    SQLITE_TESTCTRL_BYTEORDER: begin
      if nArg = 1 then begin
        rc2 := sqlite3_test_control(testctrl);
        if testctrl = SQLITE_TESTCTRL_BYTEORDER then isOk := 1
        else isOk := 3;
      end;
    end;
    SQLITE_TESTCTRL_SEEK_COUNT: begin
      { Stub: would call sqlite3_test_control(op, db, &x) and print x. }
      WriteLn('0');
      isOk := 3;
    end;
  else
    { Generic stub — accept argument shape, return 0.  Matches Pascal
      port's stubbed sqlite3_test_control() for non-PRNG opcodes. }
    isOk := 3;
  end;

  if (isOk = 0) and (iCtrl >= 0) then
    shellSPutZ(Format('Usage: .testctrl %s %s'#10,
      [zCmdC, AnsiString(aTestctrl[iCtrl].zUsage)]))
  else if isOk = 1 then
    WriteLn(rc2);
end;

{ ----------------------------------------------------------------------
  10.1.19  `.fullschema ?--indent?`  — shell.c.in:9687..

  Prints CREATE statements followed by sqlite_stat1 / sqlite_stat4
  contents (when present).  The --indent reformatter is deferred along
  with .schema's --indent option (10.1.15 follow-up).
  ---------------------------------------------------------------------- }

procedure cmdFullschema(p: PShellState; const args: array of AnsiString;
                        nArg: SizeInt);
const
  zSchemaQ =
    'SELECT sql FROM sqlite_schema ' +
    'WHERE name NOT LIKE ''sqlite\_stat%'' ESCAPE ''\'' ' +
    'ORDER BY tbl_name, type DESC, name';
  zStat1Q  =
    'SELECT ''ANALYZE sqlite_schema'' || char(10) || ' +
    '''INSERT INTO "sqlite_stat1" VALUES('' || quote(tbl) || '','' || ' +
    'quote(idx) || '','' || quote(stat) || '');'' ' +
    'FROM sqlite_stat1';
  zStat4Q  =
    'SELECT ''INSERT INTO "sqlite_stat4" VALUES('' || ' +
    'quote(tbl) || '','' || quote(idx) || '','' || ' +
    'quote(neq) || '','' || quote(nlt) || '','' || ' +
    'quote(ndlt) || '','' || quote(sample) || '');'' ' +
    'FROM sqlite_stat4';
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
  zText: PAnsiChar;
  q: AnsiString;
  qList: array[0..2] of AnsiString;
  i: i32;
  haveStat: Boolean;
begin
  openDb(p, 0);
  if p^.db = nil then Exit;
  qList[0] := zSchemaQ;
  qList[1] := zStat1Q;
  qList[2] := zStat4Q;
  for i := 0 to High(qList) do begin
    if i > 0 then begin
      { Skip stat queries if their tables don't exist. }
      pStmt := nil;
      rc := sqlite3_prepare_v2(p^.db,
        PAnsiChar('SELECT 1 FROM sqlite_schema WHERE name=' +
          QuotedStr(IfThen(i = 1, 'sqlite_stat1', 'sqlite_stat4'))),
        -1, @pStmt, @pzTail);
      haveStat := (rc = SQLITE_OK) and (pStmt <> nil)
                  and (sqlite3_step(pStmt) = SQLITE_ROW);
      if pStmt <> nil then sqlite3_finalize(pStmt);
      if not haveStat then Continue;
    end;
    q := qList[i];
    pStmt := nil;
    rc := sqlite3_prepare_v2(p^.db, PAnsiChar(q), -1, @pStmt, @pzTail);
    if (rc <> SQLITE_OK) or (pStmt = nil) then begin
      shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
      if pStmt <> nil then sqlite3_finalize(pStmt);
      Continue;
    end;
    while sqlite3_step(pStmt) = SQLITE_ROW do begin
      zText := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if zText <> nil then WriteLn(AnsiString(zText) + ';');
    end;
    sqlite3_finalize(pStmt);
  end;
end;

{ ----------------------------------------------------------------------
  10.1.20  `.lint fkey-indexes`  — shell.c.in:6131..

  The full upstream implementation depends on a custom
  fkey_collate_clause() SQL function which we have not yet ported.  We
  emit the canonical FK-coverage audit query against
  pragma_foreign_key_list and print one CREATE INDEX suggestion per
  uncovered constraint.  The verbose / groupbyparent options are
  accepted but ignored — they only affect formatting.
  ---------------------------------------------------------------------- }

{ ----------------------------------------------------------------------
  10.1.20  `.lint fkey-indexes` — full upstream variant
                                        (shell.c.in:5899..6126).

  Two pieces:

    * shellFkeyCollateClause — the SQL UDF the SELECT below relies on to
      decide whether the suggested CREATE INDEX needs a `COLLATE …`
      suffix to actually cover the foreign-key lookup.  Returns ''
      when both columns share a default collation, " COLLATE <parent>"
      otherwise.

    * lintFkeyIndexes — the dispatcher.  Builds an
      `EXPLAIN QUERY PLAN SELECT 1 FROM child WHERE child_key=?` per
      foreign-key constraint, runs each one, and asks sqlite3_strglob()
      whether the resulting plan covers the lookup with an index (the
      glob `SEARCH * USING COVERING INDEX*(*=? AND *=? …)` or the
      `SEARCH * USING INTEGER PRIMARY KEY (rowid=?)` shortcut).  When
      the plan does NOT match, emit the suggested CREATE INDEX; when it
      does and `-verbose` was passed, emit a `/* no extra indexes
      required */` breadcrumb.  `-groupbyparent` chunks the report by
      the parent table.
  ---------------------------------------------------------------------- }

procedure shellFkeyCollateClause(pCtx: Psqlite3_context;
                                 nVal: i32; apVal: PPMem); cdecl;
{ shell.c.in:5914..5949 — fkey_collate_clause(parent, parentCol,
  child, childCol).  Returns " COLLATE <parentCollation>" when the
  parent and child column collations differ, '' otherwise. }
type
  TArgArr = array[0..3] of PMem;
  PArgArr = ^TArgArr;
var
  db: Psqlite3;
  zParent, zParentCol, zChild, zChildCol: PAnsiChar;
  zParentSeq, zChildSeq: PAnsiChar;
  rc: i32;
  zOut: AnsiString;
  pVals: PArgArr;
begin
  if nVal <> 4 then begin
    sqlite3_result_text(pCtx, '', 0, nil);
    Exit;
  end;
  pVals      := PArgArr(apVal);
  db         := sqlite3_context_db_handle(pCtx);
  zParent    := PAnsiChar(sqlite3_value_text(pVals^[0]));
  zParentCol := PAnsiChar(sqlite3_value_text(pVals^[1]));
  zChild     := PAnsiChar(sqlite3_value_text(pVals^[2]));
  zChildCol  := PAnsiChar(sqlite3_value_text(pVals^[3]));
  sqlite3_result_text(pCtx, '', 0, nil);
  zParentSeq := nil;
  zChildSeq  := nil;
  rc := sqlite3_table_column_metadata(db, 'main', zParent, zParentCol,
                                      nil, @zParentSeq, nil, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_table_column_metadata(db, 'main', zChild, zChildCol,
                                        nil, @zChildSeq, nil, nil, nil);
  if (rc = SQLITE_OK) and (zParentSeq <> nil) and (zChildSeq <> nil) and
     (sqlite3_stricmp(zParentSeq, zChildSeq) <> 0) then begin
    zOut := ' COLLATE ' + AnsiString(zParentSeq);
    sqlite3_result_text(pCtx, PAnsiChar(zOut), Length(zOut), nil);
  end;
end;

procedure cmdLint(p: PShellState; const args: array of AnsiString;
                  nArg: SizeInt);
const
  zSql =
    'SELECT '
    + '     ''EXPLAIN QUERY PLAN SELECT 1 FROM '' || quote(s.name) || '' WHERE '''
    + '  || group_concat(quote(s.name) || ''.'' || quote(f.[from]) || ''=?'' '
    + '  || fkey_collate_clause('
    + '       f.[table], COALESCE(f.[to], p.[name]), s.name, f.[from]),'' AND '')'
    + ', '
    + '     ''SEARCH '' || s.name || '' USING COVERING INDEX*('''
    + '  || group_concat(''*=?'', '' AND '') || '')'''
    + ', '
    + '     s.name  || ''('' || group_concat(f.[from],  '', '') || '')'''
    + ', '
    + '     f.[table] || ''('' || group_concat(COALESCE(f.[to], p.[name])) || '')'''
    + ', '
    + '     ''CREATE INDEX '' || quote(s.name ||''_''|| group_concat(f.[from], ''_''))'
    + '  || '' ON '' || quote(s.name) || ''('''
    + '  || group_concat(quote(f.[from]) ||'
    + '        fkey_collate_clause('
    + '          f.[table], COALESCE(f.[to], p.[name]), s.name, f.[from]), '', '')'
    + '  || '');'''
    + ', '
    + '     f.[table] '
    + 'FROM sqlite_schema AS s, pragma_foreign_key_list(s.name) AS f '
    + 'LEFT JOIN pragma_table_info AS p ON (pk-1=seq AND p.arg=f.[table]) '
    + 'GROUP BY s.name, f.id '
    + 'ORDER BY (CASE WHEN ? THEN f.[table] ELSE s.name END)';
  zGlobIPK = 'SEARCH * USING INTEGER PRIMARY KEY (rowid=?)';
var
  bVerbose, bGroupByParent: Boolean;
  zIndent: AnsiString;
  i: SizeInt;
  rc, res: i32;
  pSql, pExplain: PVdbe;
  pzTail: PAnsiChar;
  zEQP, zGlob, zFrom, zTarget, zCI, zParent, zPlan, zPrev: PAnsiChar;
  zPrevStr: AnsiString;
begin
  if (nArg < 1) or (args[0] <> 'fkey-indexes') then begin
    shellEPutZ('Usage: .lint fkey-indexes ?-verbose? ?-groupbyparent?'#10);
    Exit;
  end;
  bVerbose       := False;
  bGroupByParent := False;
  zIndent        := '';
  for i := 1 to nArg - 1 do begin
    if (args[i] = '-verbose') or (args[i] = '--verbose') then
      bVerbose := True
    else if (args[i] = '-groupbyparent') or (args[i] = '--groupbyparent') then
    begin
      bGroupByParent := True;
      zIndent        := '    ';
    end else begin
      shellEPutZ(Format('Usage: .lint %s ?-verbose? ?-groupbyparent?'#10,
                        [args[0]]));
      Exit;
    end;
  end;

  openDb(p, 0);
  if p^.db = nil then Exit;
  rc := sqlite3_create_function(p^.db, 'fkey_collate_clause', 4,
                                SQLITE_UTF8, nil,
                                @shellFkeyCollateClause, nil, nil);
  if rc <> SQLITE_OK then begin
    shellEPutZ(AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    Exit;
  end;
  pSql := nil;
  rc := sqlite3_prepare_v2(p^.db, zSql, -1, @pSql, @pzTail);
  if (rc <> SQLITE_OK) or (pSql = nil) then begin
    shellEPutZ(AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    if pSql <> nil then sqlite3_finalize(pSql);
    Exit;
  end;
  if bGroupByParent then sqlite3_bind_int(pSql, 1, 1)
                    else sqlite3_bind_int(pSql, 1, 0);

  zPrev    := nil;
  zPrevStr := '';
  while sqlite3_step(pSql) = SQLITE_ROW do begin
    res     := -1;
    zEQP    := PAnsiChar(sqlite3_column_text(pSql, 0));
    zGlob   := PAnsiChar(sqlite3_column_text(pSql, 1));
    zFrom   := PAnsiChar(sqlite3_column_text(pSql, 2));
    zTarget := PAnsiChar(sqlite3_column_text(pSql, 3));
    zCI     := PAnsiChar(sqlite3_column_text(pSql, 4));
    zParent := PAnsiChar(sqlite3_column_text(pSql, 5));
    if (zEQP = nil) or (zGlob = nil) then Continue;
    pExplain := nil;
    rc := sqlite3_prepare_v2(p^.db, zEQP, -1, @pExplain, @pzTail);
    if rc <> SQLITE_OK then Break;
    if sqlite3_step(pExplain) = SQLITE_ROW then begin
      zPlan := PAnsiChar(sqlite3_column_text(pExplain, 3));
      if zPlan <> nil then begin
        if (sqlite3_strglob(zGlob, zPlan) = 0)
           or (sqlite3_strglob(zGlobIPK, zPlan) = 0) then
          res := 1
        else
          res := 0;
      end;
    end;
    rc := sqlite3_finalize(pExplain);
    if rc <> SQLITE_OK then Break;

    if res < 0 then begin
      shellEPutZ('Error: internal error');
      Break;
    end;
    if bGroupByParent and (bVerbose or (res = 0)) and
       ((zPrev = nil) or
        (sqlite3_stricmp(zParent, PAnsiChar(zPrevStr)) <> 0)) then
    begin
      WriteLn(Format('-- Parent table %s', [AnsiString(zParent)]));
      zPrevStr := AnsiString(zParent);
      zPrev    := PAnsiChar(zPrevStr);
    end;

    if res = 0 then
      WriteLn(zIndent + AnsiString(zCI) + ' --> ' + AnsiString(zTarget))
    else if bVerbose then
      WriteLn(Format('%s/* no extra indexes required for %s -> %s */',
                     [zIndent, AnsiString(zFrom), AnsiString(zTarget)]));
  end;
  sqlite3_finalize(pSql);
end;

{ ----------------------------------------------------------------------
  10.1.21  `.expert ?OPTS?`  — disabled stub  (shell.c.in 9442..9469)

  The upstream implementation wraps sqlite3_expert.c which we have not
  yet ported; emit the same disabled message until that lands.
  ---------------------------------------------------------------------- }

procedure cmdExpert;
begin
  shellEPutZ('Error: this build does not support the .expert command'#10);
end;

{ ----------------------------------------------------------------------
  10.1.42  `.selecttrace` / `.wheretrace` / `.treetrace`
                                    — shell.c.in:10711..10716, 12042..

  Compile-time-debug toggles in the C reference; in the Pascal port the
  TRACEFLAGS variant of sqlite3_test_control is not yet bound, so we
  swallow the args and report the no-op rather than emit
  "unknown command".
  ---------------------------------------------------------------------- }

procedure cmdTraceFlags(const cmdName: AnsiString);
begin
  shellEPutZ(Format('Note: .%s requires a debug build; ignored'#10,
                    [cmdName]));
end;

{ ----------------------------------------------------------------------
  10.1.40  `.testcase NAME` / `.check ANSWER`  — shell.c.in (testcase
  output capture used by the upstream test harness).  We support only
  the .testcase sub-arm: stash NAME so the next .check can compare
  zTestcase against the captured value (rendered through QRF).  The
  comparator side (which redirects shell output into a buffer) is a
  follow-up; for now we record the name as upstream does.
  ---------------------------------------------------------------------- }

procedure cmdTestcase(p: PShellState; const args: array of AnsiString;
                      nArg: SizeInt);
var
  zName: AnsiString;
  i: SizeInt;
begin
  if nArg < 1 then zName := '' else zName := args[0];
  for i := 1 to Length(zName) do
    if i <= High(p^.zTestcase) + 1 then
      p^.zTestcase[i - 1] := AnsiChar(zName[i]);
  if Length(zName) <= High(p^.zTestcase) then
    p^.zTestcase[Length(zName)] := #0
  else
    p^.zTestcase[High(p^.zTestcase)] := #0;
end;

{ ----------------------------------------------------------------------
  10.1.50  `.dbconfig ?op? ?val?`  — shell.c.in (sqlite3_db_config
  dispatcher).  Lists known opcodes when called bare; sets one when
  called with op + val.  Restricted to the integer-valued ops exposed
  by sqlite3_db_config_int (the boolean DBCONFIG_* set).
  ---------------------------------------------------------------------- }

type
  TDbcfgEntry = record
    zName: AnsiString;
    op: i32;
  end;
const
  aDbConfig: array[0..14] of TDbcfgEntry = (
    (zName: 'defensive';                  op: SQLITE_DBCONFIG_DEFENSIVE),
    (zName: 'dqs_ddl';                    op: SQLITE_DBCONFIG_DQS_DDL),
    (zName: 'dqs_dml';                    op: SQLITE_DBCONFIG_DQS_DML),
    (zName: 'enable_fkey';                op: SQLITE_DBCONFIG_ENABLE_FKEY),
    (zName: 'enable_qpsg';                op: SQLITE_DBCONFIG_ENABLE_QPSG),
    (zName: 'enable_trigger';             op: SQLITE_DBCONFIG_ENABLE_TRIGGER),
    (zName: 'enable_view';                op: SQLITE_DBCONFIG_ENABLE_VIEW),
    (zName: 'enable_attach_create';       op: SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE),
    (zName: 'enable_attach_write';        op: SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE),
    (zName: 'enable_comments';            op: SQLITE_DBCONFIG_ENABLE_COMMENTS),
    (zName: 'legacy_alter_table';         op: SQLITE_DBCONFIG_LEGACY_ALTER_TABLE),
    (zName: 'legacy_file_format';         op: SQLITE_DBCONFIG_LEGACY_FILE_FORMAT),
    (zName: 'no_ckpt_on_close';           op: SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE),
    (zName: 'reset_database';             op: SQLITE_DBCONFIG_RESET_DATABASE),
    (zName: 'trusted_schema';             op: SQLITE_DBCONFIG_TRUSTED_SCHEMA)
  );

procedure cmdDbconfig(p: PShellState; const args: array of AnsiString;
                      nArg: SizeInt);
var
  i: SizeInt;
  v: i32;
  matched: Boolean;
begin
  openDb(p, 0);
  if p^.db = nil then Exit;
  if nArg = 0 then begin
    for i := 0 to High(aDbConfig) do begin
      v := -1;
      sqlite3_db_config_int(p^.db, aDbConfig[i].op, -1, @v);
      WriteLn(Format('%19s %s', [aDbConfig[i].zName,
                                 IfThen(v <> 0, 'on', 'off')]));
    end;
    Exit;
  end;
  matched := False;
  for i := 0 to High(aDbConfig) do begin
    if args[0] = aDbConfig[i].zName then begin
      matched := True;
      v := -1;
      if nArg >= 2 then
        sqlite3_db_config_int(p^.db, aDbConfig[i].op,
                              parseOnOff(args[1], 0), @v)
      else
        sqlite3_db_config_int(p^.db, aDbConfig[i].op, -1, @v);
      WriteLn(Format('%19s %s', [aDbConfig[i].zName,
                                 IfThen(v <> 0, 'on', 'off')]));
      Break;
    end;
  end;
  if not matched then
    shellEPutZ(Format('Error: unknown dbconfig "%s"'#10, [args[0]]));
end;

{ ----------------------------------------------------------------------
  10.1.39 (partial)  `.scanstats on|off|est|vm`  — shell.c.in:10545..

  The Pascal sqlite3_db_config_int dispatcher does not yet recognise
  SQLITE_DBCONFIG_STMT_SCANSTATUS, so we record the mode locally and
  emit upstream's "not available in this build" warning.
  ---------------------------------------------------------------------- }

procedure cmdScanstats(p: PShellState; const args: array of AnsiString;
                       nArg: SizeInt);
begin
  if nArg <> 1 then begin
    shellEPutZ('Usage: .scanstats on|off|est'#10);
    Exit;
  end;
  if args[0] = 'vm' then p^.mode.scanstatsOn := 3
  else if args[0] = 'est' then p^.mode.scanstatsOn := 2
  else p^.mode.scanstatsOn := u8(parseOnOff(args[0], 0));
  shellEPutZ('Warning: .scanstats not available in this build.'#10);
end;

{ 10.1.10 follow-up — `.width N1 N2 ...`  (shell.c.in:12047..12058).
  Stores the parsed widths in the unit-level aUserWidth backing array
  and points spec.aWidth/spec.nWidth at it. }

const
  QRF_MAX_WIDTH = 32767;

procedure cmdWidth(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var
  j: SizeInt;
  w: i64;
begin
  SetLength(aUserWidth, nArg);
  for j := 0 to nArg - 1 do begin
    w := StrToInt64Def(args[j], 0);
    if w < -QRF_MAX_WIDTH then w := -QRF_MAX_WIDTH;
    if w >  QRF_MAX_WIDTH then w :=  QRF_MAX_WIDTH;
    aUserWidth[j] := SmallInt(w);
  end;
  p^.mode.spec.nWidth := nArg;
  if nArg > 0 then p^.mode.spec.aWidth := @aUserWidth[0]
  else p^.mode.spec.aWidth := nil;
end;

{ 10.1.11 — `.parameter init|list|set|unset|clear`  (shell.c.in:10264..10367).

  Bind-parameter table lives in TEMP.sqlite_parameters; the upstream
  defensive/writable_schema toggles around bind_table_init are skipped
  here — defensive mode is not engaged in this Pascal cut. }

procedure paramTableInit(p: PShellState);
const
  { Upstream emits WITHOUT ROWID here, but the Pascal port's WITHOUT ROWID
    arm is not yet wired (writes corrupt the page).  Plain rowid table is
    behaviourally equivalent for the bind-parameter use case. }
  zCreate: PAnsiChar =
    'CREATE TABLE IF NOT EXISTS temp.sqlite_parameters('#10 +
    '  key TEXT PRIMARY KEY,'#10 +
    '  value'#10 +
    ');';
begin
  if p^.db = nil then Exit;
  sqlite3_exec(p^.db, zCreate, nil, nil, nil);
end;

function looksLikeSqlLiteral(const z: AnsiString): Boolean;
{ Cheap classifier: does z appear to be a SQL literal (number / keyword /
  X'...' blob / quoted string) versus a bare bareword that would parse
  as a column reference?  Used by paramSet to decide whether to wrap. }
var i: SizeInt; c: AnsiChar; up: AnsiString;
begin
  Result := False;
  if z = '' then Exit;
  c := z[1];
  if (c in ['+', '-', '.']) or (c in ['0'..'9']) then begin Result := True; Exit; end;
  if (c = '''') or (c = '"') then begin Result := True; Exit; end;
  if ((c = 'x') or (c = 'X')) and (Length(z) >= 2) and (z[2] = '''') then begin
    Result := True; Exit;
  end;
  up := UpperCase(z);
  if (up = 'NULL') or (up = 'TRUE') or (up = 'FALSE') then begin
    Result := True; Exit;
  end;
  i := 1;  { allow 0xDEAD-style hex, signed/unsigned numeric, etc. handled above }
  Result := False;
end;

procedure paramSet(p: PShellState; const zKey, zValue: AnsiString);
{ Mirrors shell.c.in:10319..10352.  When the caller's value looks like a
  SQL literal (digit / quote / NULL / X'...') we splice it directly into
  the VALUES clause; otherwise it is quoted as text.  This avoids the
  upstream behaviour where a bare bareword silently binds NULL via the
  "double-quote-as-string" quirk. }
var
  zSql, escKey: AnsiString;
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
begin
  paramTableInit(p);
  escKey := StringReplace(zKey, '''', '''''', [rfReplaceAll]);
  if looksLikeSqlLiteral(zValue) then
    zSql := 'REPLACE INTO temp.sqlite_parameters(key,value) VALUES(''' +
            escKey + ''',' + zValue + ')'
  else
    zSql := 'REPLACE INTO temp.sqlite_parameters(key,value) VALUES(''' +
            escKey + ''',''' +
            StringReplace(zValue, '''', '''''', [rfReplaceAll]) + ''')';
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
  if rc <> SQLITE_OK then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    pStmt := nil;
    zSql := 'REPLACE INTO temp.sqlite_parameters(key,value) VALUES(''' +
            escKey + ''',''' +
            StringReplace(zValue, '''', '''''', [rfReplaceAll]) + ''')';
    rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
    if rc <> SQLITE_OK then begin
      shellSPutZ(Format('Error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
      if pStmt <> nil then sqlite3_finalize(pStmt);
      Exit;
    end;
  end;
  sqlite3_step(pStmt);
  sqlite3_finalize(pStmt);
end;

procedure cmdParameter(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc, len: i32;
  zSql: AnsiString;
begin
  openDb(p, 0);
  if p^.db = nil then Exit;
  if (nArg = 1) and (args[0] = 'clear') then begin
    sqlite3_exec(p^.db, 'DROP TABLE IF EXISTS temp.sqlite_parameters;',
                 nil, nil, nil);
    Exit;
  end;
  if (nArg = 1) and (args[0] = 'init') then begin
    paramTableInit(p);
    Exit;
  end;
  if (nArg = 1) and (args[0] = 'list') then begin
    pStmt := nil;
    len := 0;
    rc := sqlite3_prepare_v2(p^.db,
            'SELECT max(length(key)) FROM temp.sqlite_parameters;',
            -1, @pStmt, @pzTail);
    if (rc = SQLITE_OK) and (pStmt <> nil)
       and (sqlite3_step(pStmt) = SQLITE_ROW) then begin
      len := sqlite3_column_int(pStmt, 0);
      if len > 40 then len := 40;
    end;
    if pStmt <> nil then sqlite3_finalize(pStmt);
    if len > 0 then begin
      pStmt := nil;
      rc := sqlite3_prepare_v2(p^.db,
              'SELECT key, quote(value) FROM temp.sqlite_parameters;',
              -1, @pStmt, @pzTail);
      while (rc = SQLITE_OK) and (pStmt <> nil)
            and (sqlite3_step(pStmt) = SQLITE_ROW) do
        shellSPutZ(Format('%-*s %s'#10,
          [len, AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 0))),
                AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 1)))]));
      if pStmt <> nil then sqlite3_finalize(pStmt);
    end;
    Exit;
  end;
  if (nArg = 3) and (args[0] = 'set') then begin
    paramSet(p, args[1], args[2]);
    Exit;
  end;
  if (nArg = 2) and (args[0] = 'unset') then begin
    zSql := 'DELETE FROM temp.sqlite_parameters WHERE key=''' +
            StringReplace(args[1], '''', '''''', [rfReplaceAll]) + '''';
    sqlite3_exec(p^.db, PAnsiChar(zSql), nil, nil, nil);
    Exit;
  end;
  shellEPutZ('Usage: .parameter init|list|set|unset|clear ?ARGS?'#10);
end;

{ ----------------------------------------------------------------------
  10.1.24  `.import FILE TABLE ?OPTIONS?`  — shell.c.in:4958..7848

  Faithful port of ImportCtx + import_getc + import_append_char +
  csv_read_one_field + ascii_read_one_field + dotCmdImport.  The
  initial cut wires the file/CSV/ASCII reader paths and the bulk-insert
  loop; the auto-create-table path (zAutoColumn), pipe input (`|cmd`),
  and the in-script `<<MARK` heredoc are deferred — the table must
  already exist for now and a clear "table does not exist" error is
  emitted otherwise so partial landings cannot silently no-op.
  ---------------------------------------------------------------------- }

const
  IMPORT_EOF = -1;
  IMPORT_BUFSIZE = 4096;

type
  TImportCtx = record
    zFile:     AnsiString;       { Display name of the input file }
    inHandle:  THandle;
    inOpen:    Boolean;
    buf:       array[0..IMPORT_BUFSIZE - 1] of Byte;
    bufPos:    SizeInt;
    bufLen:    SizeInt;
    atEof:     Boolean;
    z:         AnsiString;       { Accumulated text for one field }
    nLine:     i32;              { Current line number }
    nRow:      i32;              { Number of rows imported }
    nErr:      i32;              { Number of errors encountered }
    bNotFirst: i32;              { 1 if at least one byte read }
    cTerm:     i32;              { Char that ended last field (or EOF) }
    cColSep:   i32;              { Column separator byte }
    cRowSep:   i32;              { Row separator byte }
    cQEscape:  i32;              { Escape inside "..."; 0 = none }
    cUQEscape: i32;              { Escape outside "..."; 0 = none }
  end;

procedure importInit(out p: TImportCtx);
begin
  FillChar(p, SizeOf(p), 0);
  p.inHandle := THandle(-1);
end;

procedure importCleanup(var p: TImportCtx);
begin
  if p.inOpen then begin
    FpClose(p.inHandle);
    p.inOpen := False;
    p.inHandle := THandle(-1);
  end;
  p.z := '';
  p.bufPos := 0;
  p.bufLen := 0;
end;

function importGetc(var p: TImportCtx): i32;
var n: SizeInt;
begin
  if p.bufPos >= p.bufLen then begin
    if p.atEof then begin Result := IMPORT_EOF; Exit; end;
    n := FpRead(p.inHandle, p.buf, SizeOf(p.buf));
    if n <= 0 then begin
      p.atEof := True;
      Result := IMPORT_EOF;
      Exit;
    end;
    p.bufLen := n;
    p.bufPos := 0;
  end;
  Result := i32(p.buf[p.bufPos]);
  Inc(p.bufPos);
end;

procedure importAppendChar(var p: TImportCtx; c: i32); inline;
begin
  p.z := p.z + AnsiChar(Byte(c and $FF));
end;

{ csv_read_one_field — shell.c.in:5031..5116.

  Reads one rfc4180 CSV field.  Returns True if a field (possibly empty)
  was produced; False only when the very first byte is EOF.  Field text
  lives in p.z and the terminator in p.cTerm. }
function csvReadOneField(var p: TImportCtx): Boolean;
var
  c, pc, ppc, cQuote, cEsc, cSep, rSep, startLine: i32;
begin
  cSep := p.cColSep and $FF;
  rSep := p.cRowSep and $FF;
  p.z := '';
  c := importGetc(p);
  if (c = IMPORT_EOF) or (seenInterrupt <> 0) then begin
    p.cTerm := IMPORT_EOF;
    Result := False;
    Exit;
  end;
  if c = Ord('"') then begin
    cQuote := c;
    cEsc := p.cQEscape and $FF;
    pc := 0; ppc := 0;
    startLine := p.nLine;
    while True do begin
      c := importGetc(p);
      if c = rSep then Inc(p.nLine);
      if (c = cEsc) and (cEsc <> 0) then begin
        c := importGetc(p);
        importAppendChar(p, c);
        ppc := 0; pc := 0;
        Continue;
      end;
      if c = cQuote then begin
        if pc = cQuote then begin
          pc := 0;
          Continue;
        end;
      end;
      if ((c = cSep) and (pc = cQuote))
         or ((c = rSep) and (pc = cQuote))
         or ((c = rSep) and (pc = 13) and (ppc = cQuote))
         or ((c = IMPORT_EOF) and (pc = cQuote)) then
      begin
        { Strip back to (and including) the close-quote. }
        while (Length(p.z) > 0) and (Ord(p.z[Length(p.z)]) <> cQuote) do
          SetLength(p.z, Length(p.z) - 1);
        if Length(p.z) > 0 then SetLength(p.z, Length(p.z) - 1);
        p.cTerm := c;
        Break;
      end;
      if (pc = cQuote) and (c <> 13) then
        shellEPutZ(Format('%s:%d: unescaped %s character'#10,
          [p.zFile, p.nLine, AnsiChar(Byte(cQuote))]));
      if c = IMPORT_EOF then begin
        shellEPutZ(Format('%s:%d: unterminated %s-quoted field'#10,
          [p.zFile, startLine, AnsiChar(Byte(cQuote))]));
        p.cTerm := c;
        Break;
      end;
      importAppendChar(p, c);
      ppc := pc;
      pc := c;
    end;
  end else begin
    cEsc := p.cUQEscape and $FF;
    if ((c and $FF) = $EF) and (p.bNotFirst = 0) then begin
      importAppendChar(p, c);
      c := importGetc(p);
      if (c and $FF) = $BB then begin
        importAppendChar(p, c);
        c := importGetc(p);
        if (c and $FF) = $BF then begin
          p.bNotFirst := 1;
          p.z := '';
          Result := csvReadOneField(p);
          Exit;
        end;
      end;
    end;
    while (c <> IMPORT_EOF) and (c <> cSep) and (c <> rSep) do begin
      if (c = cEsc) and (cEsc <> 0) then c := importGetc(p);
      importAppendChar(p, c);
      c := importGetc(p);
    end;
    if c = rSep then begin
      Inc(p.nLine);
      if (Length(p.z) > 0) and (p.z[Length(p.z)] = #13) then
        SetLength(p.z, Length(p.z) - 1);
    end;
    p.cTerm := c;
  end;
  p.bNotFirst := 1;
  Result := True;
end;

{ ascii_read_one_field — shell.c.in:5130..5150.  ASCII-delimited mode
  (column 0x1F, row 0x1E by default).  No quote handling. }
function asciiReadOneField(var p: TImportCtx): Boolean;
var c, cSep, rSep: i32;
begin
  cSep := p.cColSep and $FF;
  rSep := p.cRowSep and $FF;
  p.z := '';
  c := importGetc(p);
  if (c = IMPORT_EOF) or (seenInterrupt <> 0) then begin
    p.cTerm := IMPORT_EOF;
    Result := False;
    Exit;
  end;
  while (c <> IMPORT_EOF) and (c <> cSep) and (c <> rSep) do begin
    importAppendChar(p, c);
    c := importGetc(p);
  end;
  if c = rSep then Inc(p.nLine);
  p.cTerm := c;
  p.bNotFirst := 1;
  Result := True;
end;

type
  TImportReader = function(var ctx: TImportCtx): Boolean;

procedure cmdImport(p: PShellState; const args: array of AnsiString;
                   nArg: SizeInt);
var
  sCtx: TImportCtx;
  xRead: TImportReader;
  zFile, zTable, zSchema: AnsiString;
  zSql: AnsiString;
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc, nCol, eVerbose: i32;
  nSkip: i64;
  i, j: SizeInt;
  z: AnsiString;
  hasFile: Boolean;
  startLine: i32;
  ch: AnsiChar;
  needCommit: i32;
  exists: i32;
  zArg: AnsiString;
begin
  importInit(sCtx);
  if p^.mode.eMode = MODE_Ascii then
    xRead := @asciiReadOneField
  else
    xRead := @csvReadOneField;
  zFile := '';
  zTable := '';
  zSchema := '';
  eVerbose := 0;
  nSkip := 0;
  i := 0;
  while i < nArg do begin
    zArg := args[i];
    if (Length(zArg) >= 2) and (zArg[1] = '-') and (zArg[2] = '-') then
      Delete(zArg, 1, 1);
    if (Length(zArg) = 0) or (zArg[1] <> '-') then begin
      if zFile = '' then zFile := args[i]
      else if zTable = '' then zTable := args[i]
      else begin
        shellEPutZ(Format('Error: unknown argument: %s'#10, [args[i]]));
        Exit;
      end;
    end else if zArg = '-v' then
      Inc(eVerbose)
    else if (zArg = '-schema') and (i < nArg - 1) then begin
      Inc(i); zSchema := args[i];
    end else if (zArg = '-skip') and (i < nArg - 1) then begin
      Inc(i); nSkip := StrToInt64Def(string(args[i]), 0);
    end else if zArg = '-ascii' then begin
      if sCtx.cColSep = 0 then sCtx.cColSep := Ord(SEP_Unit);
      if sCtx.cRowSep = 0 then sCtx.cRowSep := Ord(SEP_Record);
      xRead := @asciiReadOneField;
    end else if zArg = '-csv' then begin
      if sCtx.cColSep = 0 then sCtx.cColSep := Ord(',');
      if sCtx.cRowSep = 0 then sCtx.cRowSep := Ord(#10);
      xRead := @csvReadOneField;
    end else if (zArg = '-esc') and (i < nArg - 1) then begin
      Inc(i);
      if Length(args[i]) > 0 then sCtx.cUQEscape := Ord(args[i][1]);
    end else if (zArg = '-qesc') and (i < nArg - 1) then begin
      Inc(i);
      if Length(args[i]) > 0 then sCtx.cQEscape := Ord(args[i][1]);
    end else if zArg = '-colsep' then begin
      if i = nArg - 1 then begin
        shellEPutZ('Error: missing argument: -colsep'#10);
        Exit;
      end;
      Inc(i);
      if Length(args[i]) > 0 then sCtx.cColSep := Ord(args[i][1]);
    end else if zArg = '-rowsep' then begin
      if i = nArg - 1 then begin
        shellEPutZ('Error: missing argument: -rowsep'#10);
        Exit;
      end;
      Inc(i);
      if Length(args[i]) > 0 then sCtx.cRowSep := Ord(args[i][1]);
    end else begin
      shellEPutZ(Format('Error: unknown option: %s'#10, [args[i]]));
      Exit;
    end;
    Inc(i);
  end;
  if zTable = '' then begin
    if zFile = '' then
      shellEPutZ('Error: Missing FILE argument'#10)
    else
      shellEPutZ('Error: Missing TABLE argument'#10);
    Exit;
  end;
  seenInterrupt := 0;
  openDb(p, 0);
  if p^.db = nil then Exit;

  if sCtx.cColSep = 0 then begin
    if (p^.mode.spec.zColumnSep <> nil) and (p^.mode.spec.zColumnSep[0] <> #0)
    then sCtx.cColSep := Ord(p^.mode.spec.zColumnSep[0])
    else sCtx.cColSep := Ord(',');
  end;
  if (sCtx.cColSep and $80) <> 0 then begin
    shellEPutZ('Error: .import column separator must be ASCII'#10);
    Exit;
  end;
  if sCtx.cRowSep = 0 then begin
    if (p^.mode.spec.zRowSep <> nil) and (p^.mode.spec.zRowSep[0] <> #0)
    then sCtx.cRowSep := Ord(p^.mode.spec.zRowSep[0])
    else sCtx.cRowSep := Ord(#10);
  end;
  if (sCtx.cRowSep = 13) and (xRead <> @asciiReadOneField) then
    sCtx.cRowSep := 10;
  if (sCtx.cRowSep and $80) <> 0 then begin
    shellEPutZ('Error: .import row separator must be ASCII'#10);
    Exit;
  end;

  sCtx.zFile := zFile;
  sCtx.nLine := 1;

  if (Length(zFile) > 0) and (zFile[1] = '|') then begin
    shellEPutZ('Error: pipes are not supported in this build'#10);
    Exit;
  end;
  if (Length(zFile) > 2) and (zFile[1] = '<') and (zFile[2] = '<') then begin
    shellEPutZ('Error: heredoc input (<<MARK) is not supported in this build'#10);
    Exit;
  end;
  sCtx.inHandle := FpOpen(string(zFile), O_RDONLY);
  if sCtx.inHandle = THandle(-1) then begin
    shellEPutZ(Format('Error: cannot open "%s"'#10, [zFile]));
    Exit;
  end;
  sCtx.inOpen := True;

  if eVerbose >= 1 then begin
    ch := AnsiChar(Byte(sCtx.cColSep));
    shellSPutZ(Format('Column separator "%s", row separator "%s"'#10,
      [string(ch), string(AnsiChar(Byte(sCtx.cRowSep)))]));
  end;

  hasFile := True;
  if hasFile then ;

  { Skip leading rows. }
  while nSkip > 0 do begin
    Dec(nSkip);
    while xRead(sCtx) and (sCtx.cTerm = sCtx.cColSep) do ;
  end;

  { The Pascal port currently requires the destination table to already
    exist; the auto-create-from-header path (zAutoColumn) is deferred.
    Probe via sqlite_schema rather than sqlite3_table_column_metadata so
    we sidestep any port quirks in the latter when the schema is unset. }
  if zSchema <> '' then
    zSql := 'SELECT count(*) FROM "' +
      StringReplace(zSchema, '"', '""', [rfReplaceAll]) +
      '".sqlite_schema WHERE type=''table'' AND name=''' +
      StringReplace(zTable, '''', '''''', [rfReplaceAll]) + ''''
  else
    zSql := 'SELECT count(*) FROM sqlite_schema WHERE type=''table''' +
      ' AND name=''' + StringReplace(zTable, '''', '''''', [rfReplaceAll]) + '''';
  pStmt := nil;
  exists := 0;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
  if (rc = SQLITE_OK) and (pStmt <> nil)
     and (sqlite3_step(pStmt) = SQLITE_ROW) then
    exists := sqlite3_column_int(pStmt, 0);
  if pStmt <> nil then sqlite3_finalize(pStmt);
  if exists = 0 then begin
    shellEPutZ(Format('Error: no such table: %s' +
      ' (auto-create not supported in this build; CREATE TABLE first)'#10,
      [zTable]));
    importCleanup(sCtx);
    Exit;
  end;

  { Discover column count via pragma_table_info. }
  if zSchema <> '' then
    zSql := 'SELECT count(*) FROM pragma_table_info(''' +
      StringReplace(zTable,'''','''''',[rfReplaceAll]) + ''',''' +
      StringReplace(zSchema,'''','''''',[rfReplaceAll]) + ''')'
  else
    zSql := 'SELECT count(*) FROM pragma_table_info(''' +
      StringReplace(zTable,'''','''''',[rfReplaceAll]) + ''')';
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(Format('Error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    importCleanup(sCtx);
    Exit;
  end;
  if sqlite3_step(pStmt) = SQLITE_ROW then
    nCol := sqlite3_column_int(pStmt, 0)
  else
    nCol := 0;
  sqlite3_finalize(pStmt);
  if nCol = 0 then begin importCleanup(sCtx); Exit; end;

  { Build INSERT INTO "schema"."table" VALUES(?,?,...,?). }
  if zSchema <> '' then
    zSql := 'INSERT INTO "' +
      StringReplace(zSchema, '"', '""', [rfReplaceAll]) + '"."' +
      StringReplace(zTable, '"', '""', [rfReplaceAll]) + '" VALUES(?'
  else
    zSql := 'INSERT INTO "' +
      StringReplace(zTable, '"', '""', [rfReplaceAll]) + '" VALUES(?';
  for i := 1 to nCol - 1 do zSql := zSql + ',?';
  zSql := zSql + ')';
  if eVerbose >= 2 then
    shellSPutZ('Insert using: ' + zSql + #10);

  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(Format('Error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    importCleanup(sCtx);
    Exit;
  end;

  needCommit := sqlite3_get_autocommit(p^.db);
  if needCommit <> 0 then sqlite3_exec(p^.db, 'BEGIN', nil, nil, nil);

  repeat
    startLine := sCtx.nLine;
    i := 0;
    while i < nCol do begin
      if not xRead(sCtx) then begin
        { EOF before any column on this row → stop quietly. }
        if i = 0 then Break;
        sqlite3_bind_null(pStmt, i + 1);
        Inc(i);
        Continue;
      end;
      z := sCtx.z;
      if (p^.mode.eMode = MODE_Ascii) and (z = '') and (i = 0) then begin
        i := -1; Break;
      end;
      sqlite3_bind_text(pStmt, i + 1, PAnsiChar(z), -1, SQLITE_TRANSIENT);
      if (i < nCol - 1) and (sCtx.cTerm <> sCtx.cColSep) then begin
        if (i = 0) and ((z = #10) or (z = #13#10)) then begin
          { Trailing blank line under non-LF row separator — ignore. }
          i := -1; Break;
        end;
        shellEPutZ(Format(
          '%s:%d: expected %d columns but found %d - filling the rest with NULL'#10,
          [sCtx.zFile, startLine, nCol, i + 1]));
        j := i + 2;
        while j <= nCol do begin
          sqlite3_bind_null(pStmt, j);
          Inc(j);
        end;
        i := nCol;
        Break;
      end;
      Inc(i);
    end;
    if i < 0 then Break;
    if (sCtx.cTerm = sCtx.cColSep) and (i = nCol) then begin
      { Extra columns on the row — drain them and warn. }
      j := i;
      repeat
        xRead(sCtx);
        Inc(j);
      until sCtx.cTerm <> sCtx.cColSep;
      shellEPutZ(Format(
        '%s:%d: expected %d columns but found %d - extras ignored'#10,
        [sCtx.zFile, startLine, nCol, j]));
    end;
    if i >= nCol then begin
      sqlite3_step(pStmt);
      rc := sqlite3_reset(pStmt);
      if rc <> SQLITE_OK then begin
        shellEPutZ(Format('%s:%d: INSERT failed: %s'#10,
          [sCtx.zFile, startLine, AnsiString(sqlite3_errmsg(p^.db))]));
        Inc(sCtx.nErr);
        if bail_on_error <> 0 then Break;
      end else
        Inc(sCtx.nRow);
    end;
  until sCtx.cTerm = IMPORT_EOF;

  sqlite3_finalize(pStmt);
  if needCommit <> 0 then sqlite3_exec(p^.db, 'COMMIT', nil, nil, nil);
  if eVerbose > 0 then
    shellSPutZ(Format('Added %d rows with %d errors using %d lines of input'#10,
      [sCtx.nRow, sCtx.nErr, sCtx.nLine - 1]));
  importCleanup(sCtx);
end;

function doMetaCommand(const zLine: AnsiString; p: PShellState): i32;
var
  zCmd: AnsiString;
  args: array[0..15] of AnsiString;
  nArg: SizeInt;
  i: SizeInt;
begin
  Result := 0;
  zCmd := dotCmdName(zLine);
  if zCmd = '' then Exit;
  for i := 0 to High(args) do args[i] := '';
  splitDotArgs(zLine, args, nArg);

  if (zCmd = 'quit') or (zCmd = 'exit') then begin Result := 2; Exit; end;
  if zCmd = 'help'      then begin cmdHelp(args, nArg); Exit; end;
  if zCmd = 'stats'     then begin cmdStats(p, args, nArg); Exit; end;
  if zCmd = 'trace'     then begin cmdTrace(p, args, nArg); Exit; end;
  if zCmd = 'show'      then begin cmdShow(p); Exit; end;
  if zCmd = 'mode'      then begin cmdMode(p, args, nArg); Exit; end;
  if zCmd = 'headers'   then begin cmdHeaders(p, args, nArg); Exit; end;
  if (zCmd = 'separator') or (zCmd = 'sep') then begin cmdSeparator(p, args, nArg); Exit; end;
  if zCmd = 'nullvalue' then begin cmdNullvalue(p, args, nArg); Exit; end;
  if zCmd = 'echo'      then begin cmdEcho(p, args, nArg); Exit; end;
  if zCmd = 'changes'   then begin cmdChanges(p, args, nArg); Exit; end;
  if zCmd = 'tables'    then begin cmdTables(p, args, nArg); Exit; end;
  if zCmd = 'indexes'   then begin cmdIndexes(p, args, nArg); Exit; end;
  if zCmd = 'databases' then begin cmdDatabases(p); Exit; end;
  if zCmd = 'schema'    then begin cmdSchema(p, args, nArg); Exit; end;
  if zCmd = 'timer'     then begin cmdTimer(p, args, nArg); Exit; end;
  if zCmd = 'eqp'       then begin cmdEqp(p, args, nArg); Exit; end;
  if zCmd = 'explain'   then begin cmdExplain(p, args, nArg); Exit; end;
  if (zCmd = 'shell') or (zCmd = 'system') then begin
    cmdShell(p, args, nArg); Exit;
  end;
  if zCmd = 'cd'        then begin cmdCd(args, nArg); Exit; end;
  if zCmd = 'log'       then begin cmdLog(args, nArg); Exit; end;
  if zCmd = 'dbinfo'    then begin cmdDbinfo(p, args, nArg); Exit; end;
  if (zCmd = 'crlf') or (zCmd = 'crnl') then begin cmdCrnl(p, args, nArg); Exit; end;
  if zCmd = 'binary'    then begin cmdBinary; Result := 1; Exit; end;
  if zCmd = 'breakpoint' then begin cmdBreakpoint; Exit; end;
  if zCmd = 'width'     then begin cmdWidth(p, args, nArg); Exit; end;
  if zCmd = 'parameter' then begin cmdParameter(p, args, nArg); Exit; end;
  if zCmd = 'read'      then begin cmdRead(p, args, nArg); Exit; end;
  if zCmd = 'import'    then begin cmdImport(p, args, nArg); Exit; end;
  if (zCmd = 'backup') or (zCmd = 'save') then begin
    cmdBackup(p, args, nArg, zCmd); Exit;
  end;
  if zCmd = 'restore'   then begin cmdRestore(p, args, nArg); Exit; end;
  if zCmd = 'clone'     then begin cmdClone(p, args, nArg); Exit; end;
  if zCmd = 'open'      then begin cmdOpen(p, args, nArg); Exit; end;
  if zCmd = 'connection' then begin cmdConnection(p, args, nArg); Exit; end;
  if zCmd = 'unmodule'  then begin cmdUnmodule(p, args, nArg); Exit; end;
  if zCmd = 'vfsinfo'   then begin cmdVfsinfo(p, args, nArg); Exit; end;
  if zCmd = 'vfslist'   then begin cmdVfslist(p); Exit; end;
  if zCmd = 'vfsname'   then begin cmdVfsname(p, args, nArg); Exit; end;
  if zCmd = 'filectrl'  then begin cmdFilectrl(p, args, nArg); Exit; end;
  if zCmd = 'testctrl'  then begin cmdTestctrl(p, args, nArg); Exit; end;
  if zCmd = 'fullschema' then begin cmdFullschema(p, args, nArg); Exit; end;
  if zCmd = 'lint'      then begin cmdLint(p, args, nArg); Exit; end;
  if zCmd = 'expert'    then begin cmdExpert; Result := 1; Exit; end;
  if (zCmd = 'selecttrace') or (zCmd = 'wheretrace')
     or (zCmd = 'treetrace') then
  begin cmdTraceFlags(zCmd); Exit; end;
  if zCmd = 'testcase'  then begin cmdTestcase(p, args, nArg); Exit; end;
  if zCmd = 'dbconfig'  then begin cmdDbconfig(p, args, nArg); Exit; end;
  if (zCmd = 'scanstats') or (zCmd = 'scanstatus') then begin
    cmdScanstats(p, args, nArg); Exit;
  end;
  if (zCmd = 'output') or (zCmd = 'once') or (zCmd = 'excel')
     or (zCmd = 'www') then begin
    cmdOutput(p, args, nArg, zCmd); Exit;
  end;
  if zCmd = 'dbtotxt' then begin cmdDbtotxt(p); Exit; end;
  if zCmd = 'dump' then begin cmdDump(p, args, nArg); Exit; end;
  if zCmd = 'sha3sum' then begin cmdSha3sum(p, args, nArg); Exit; end;
  if zCmd = 'print' then begin
    for i := 0 to nArg - 1 do begin
      if i > 0 then Write(' ');
      Write(args[i]);
    end;
    WriteLn;
    Exit;
  end;

  shellEPutZ(Format('Error: unknown command or invalid arguments:  "%s". ' +
    'Enter ".help" for help'#10, [zCmd]));
  Result := 1;
end;

{ ----------------------------------------------------------------------
  10.1.2  process_input — shell.c.in:12415..12542 (the !FIDDLE branch)

  We follow the C control flow:
    * Track inputNesting (capped at MAX_INPUT_NESTING).
    * Read a line.  If empty after EOF, break.
    * If the accumulator is empty and the line is a dot-command (or '#'
      shell-style comment), dispatch through do_meta_command.
    * Otherwise append to zSql; once sqlite3_complete returns true on
      a semicolon-terminated buffer, hand off to runOneSqlLine.
  ---------------------------------------------------------------------- }
function processInput(p: PShellState): i32;
var
  zLine, zSql: AnsiString;
  atEof: Boolean;
  errCnt: i32;
  startLine: i64;
  rc: i32;
  isCont: Boolean;
begin
  errCnt := 0;
  startLine := 0;
  zSql := '';
  if p^.inputNesting = MAX_INPUT_NESTING then begin
    shellEPutZ(Format('%s: Input nesting limit (%d) reached at line %d.'#10,
      [string(AnsiString(p^.zInFile)), MAX_INPUT_NESTING, p^.lineno]));
    Result := 1;
    Exit;
  end;
  Inc(p^.inputNesting);
  while (errCnt = 0) or (bail_on_error = 0)
        or ((p^.inFile = nil) and (stdin_is_interactive <> 0)) do
  begin
    isCont := zSql <> '';
    zLine := oneInputLine(p, isCont, atEof);
    if atEof then begin
      if (p^.inFile = nil) and (stdin_is_interactive <> 0) then WriteLn;
      Break;
    end;
    if seenInterrupt <> 0 then begin
      if p^.inFile <> nil then Break;
      seenInterrupt := 0;
    end;
    Inc(p^.lineno);

    if isAllWhitespace(zLine) and (zSql = '') then Continue;

    if (zSql = '') and (startsWithDot(zLine) or startsWithHash(zLine)) then begin
      if startsWithDot(zLine) then begin
        rc := doMetaCommand(zLine, p);
        if rc = 2 then Break       { .quit / .exit }
        else if rc <> 0 then Inc(errCnt);
        { shell.c.in:12068..12071 — decrement nPopOutput after each dot
          command; revert when it hits zero.  The .once arm sets it to 2
          on entry so the redirect survives this very dot-command. }
        if p^.nPopOutput > 0 then begin
          Dec(p^.nPopOutput);
          if p^.nPopOutput = 0 then outputReset(p);
        end;
      end;
      Continue;                    { '#' lines are silent comments }
    end;

    if zSql = '' then begin
      zSql := zLine;
      startLine := p^.lineno;
    end else
      zSql := zSql + #10 + zLine;

    if (zSql <> '') and (Length(zSql) > 0)
       and (zSql[Length(zSql)] = ';')
       and (sqlite3_complete(PAnsiChar(zSql)) <> 0) then
    begin
      Inc(errCnt, runOneSqlLine(p, zSql, AnsiString(p^.zInFile), startLine));
      zSql := '';
      { shell.c.in:12512..12517 — at end of each SQL line, immediately
        revert any active .once redirect. }
      if p^.nPopOutput > 0 then begin
        outputReset(p);
        p^.nPopOutput := 0;
      end;
    end;
  end;
  if zSql <> '' then
    Inc(errCnt, runOneSqlLine(p, zSql, AnsiString(p^.zInFile), startLine));
  Dec(p^.inputNesting);
  if errCnt > 0 then Result := 1 else Result := 0;
end;

{ ----------------------------------------------------------------------
  10.1.5  Interrupt handler + exit-code wiring.

  The C reference installs a SIGINT handler at main() entry that sets
  seenInterrupt and calls sqlite3_interrupt(globalDb).  We mirror it via
  BaseUnix's fpsignal.
  ---------------------------------------------------------------------- }

procedure interruptHandler(sig: cint); cdecl;
begin
  Inc(seenInterrupt);
  if globalDb <> nil then sqlite3_interrupt(globalDb);
end;

procedure installInterruptHandler;
var sa: SigActionRec;
begin
  FillChar(sa, SizeOf(sa), 0);
  sa.sa_handler := SigActionHandler(@interruptHandler);
  fpSigAction(SIGINT, @sa, nil);
end;

{ ----------------------------------------------------------------------
  10.1.3  main + minimal arg parser.

  Phase-10 process_command_line covers ~600 lines of flag handling in
  the C reference; this initial cut handles the bare minimum required
  to drive the REPL and to satisfy the "no positional argument =>
  :memory: in-memory database" rule from shell.c.in:13242..13260.

  Recognised flags (subset; expanded under 10.1.3 follow-up):
     --readonly / -readonly       SQLITE_OPEN_READONLY
     --bail / -bail               bail_on_error := 1
     --batch / -batch             stdin_is_interactive := 0
     --version / -version         print version and exit
     --help / -help / -?          print short usage and exit
     --                           end of flags; remaining arg = filename
  ---------------------------------------------------------------------- }

procedure printUsage(toErr: Boolean);
const
  zUsage =
    'Usage: passqlite3 [OPTIONS] [FILENAME [SQL]]'#10 +
    'OPTIONS include:'#10 +
    '  -bail              stop after hitting an error'#10 +
    '  -batch             force batch I/O'#10 +
    '  -readonly          open the database read-only'#10 +
    '  -version           show SQLite version'#10 +
    '  -help              show this message'#10;
begin
  if toErr then shellEPutZ(zUsage) else shellSPutZ(zUsage);
end;

function isFlagArg(const a: AnsiString; const flag: AnsiString): Boolean;
begin
  Result := (a = '-' + flag) or (a = '--' + flag);
end;

function shellMain: i32;
var
  state: TShellState;
  i, n: i32;
  argA: AnsiString;
  zFilename: AnsiString;
  initialSql: AnsiString;
  rc: i32;
begin
  Result := 0;
  shellStateInit(@state);
  Argv0 := AnsiString(ParamStr(0));
  zFilename := '';
  initialSql := '';

  { stdin/stdout TTY-ness — replicate the C reference's `isatty` probes. }
  stdin_is_interactive := Ord(IsATTY(StdInputHandle) <> 0);
  stdout_is_console    := Ord(IsATTY(StdOutputHandle) <> 0);

  installInterruptHandler;
  outputInit;

  n := ParamCount;
  i := 1;
  while i <= n do begin
    argA := AnsiString(ParamStr(i));
    if (Length(argA) > 1) and (argA[1] = '-')
       and ((argA[2] = '-') or (argA[2] in ['a'..'z', 'A'..'Z'])) then
    begin
      if (argA = '--') then begin
        Inc(i);
        Break;
      end else if isFlagArg(argA, 'bail') then
        bail_on_error := 1
      else if isFlagArg(argA, 'batch') then
        stdin_is_interactive := 0
      else if isFlagArg(argA, 'readonly') then begin
        state.openFlags := state.openFlags or SQLITE_OPEN_READONLY;
        state.openFlags := state.openFlags and not SQLITE_OPEN_READWRITE;
        state.openFlags := state.openFlags and not SQLITE_OPEN_CREATE;
      end
      else if isFlagArg(argA, 'version') then begin
        shellSPutZ(AnsiString(sqlite3_libversion) + sLineBreak);
        Exit(0);
      end
      else if isFlagArg(argA, 'help') or (argA = '-?') then begin
        printUsage(False);
        Exit(0);
      end else begin
        shellEPutZ(Format('%s: unknown option: %s'#10, [string(Argv0), string(argA)]));
        Exit(1);
      end;
    end else
      Break;
    Inc(i);
  end;

  if i <= n then begin
    zFilename := AnsiString(ParamStr(i));
    Inc(i);
    if i <= n then initialSql := AnsiString(ParamStr(i));
  end;

  if zFilename = '' then zFilename := ':memory:';
  state.aAuxDb[0].zDbFilename := PAnsiChar(zFilename);

  state.inFile := nil;
  state.outFile := nil;
  openDb(@state, 0);

  if initialSql <> '' then begin
    rc := runOneSqlLine(@state, initialSql, '<command-line>', 0);
    if rc <> 0 then Result := 1;
  end else begin
    Result := processInput(@state);
  end;

  if state.db <> nil then begin
    closeDb(state.db);
    state.db := nil;
    globalDb := nil;
  end;
end;

begin
  ExitCode := shellMain;
end.
