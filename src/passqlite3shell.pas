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
  passqlite3printf,
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
  passqlite3rot13,
  passqlite3uint,
  passqlite3base64,
  passqlite3totype,
  passqlite3base85,
  passqlite3eval,
  passqlite3urifuncs,
  passqlite3anycollseq,
  passqlite3blobio,
  passqlite3nextchar,
  passqlite3remember,
  passqlite3stmtrand,
  passqlite3noop,
  passqlite3zorder,
  passqlite3randomjson,
  passqlite3wholenumber,
  passqlite3templatevtab,
  passqlite3showauth,
  passqlite3mmapwarm,
  passqlite3prefixes,
  passqlite3memstat,
  passqlite3series,
  passqlite3completion,
  passqlite3decimal,
  passqlite3normalize,
  passqlite3regexp,
  passqlite3stmt,
  passqlite3explain,
  passqlite3qpvtab,
  passqlite3btreeinfo,
  passqlite3vtablog,
  passqlite3scrub,
  passqlite3fossildelta,
  passqlite3csv,
  passqlite3closure,
  passqlite3appendvfs,
  passqlite3cksumvfs,
  passqlite3vfslog,
  passqlite3vfsstat,
  passqlite3fileio,
  passqlite3vtshim,
  passqlite3unionvtab,
  passqlite3fuzzer,
  passqlite3tmstmpvfs,
  passqlite3amatch,
  passqlite3compress,
  passqlite3sqlar,
  passqlite3zipfile,
  passqlite3spellfix,
  passqlite3intck,
  passqlite3dbdata,
  passqlite3memtrace,
  passqlite3pcachetrace,
  passqlite3recover,
  passqlite3expert,
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
    { shell.c.in:334..336 ExpertInfo — populated by .expert dot command,
      consumed by runOneSqlLine to route the next SQL through expert. }
    expertPtr:        Psqlite3expert;
    expertVerbose:    i32;
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
  { 10.1.40 — `.testcase` / `.check` capture state.  When a `.testcase`
    arms a capture, gTcCapturing is True and gTcCaptureFile names the
    temp file currently aliased onto fd 1 via dup2 (same mechanism as
    cmdOutput).  cmdCheck reads the file back, compares against the
    PATTERN, and outputReset() restores the original stdout. }
  gTcCapturing:         Boolean = False;
  gTcCaptureFile:       AnsiString = '';
  { 10.1.10 .separator / .nullvalue / .mode INSERT — keep stable
    AnsiString backing for the PAnsiChar fields in TShellMode.spec. }
  zUserColSep:          AnsiString = '|';
  zUserRowSep:          AnsiString = #10;
  { Stable backing for state.zInFile when running the REPL on stdin. }
  zStdinName:           PAnsiChar = '<stdin>';
  zUserNull:            AnsiString = '';
  { Stable backing for `.mode insert <table>` so the table-name
    PAnsiChar in ShellState.zDestTable does not dangle after cmdMode
    returns (args[] is a local AnsiString array). }
  zUserInsertTab:       AnsiString = '';
  { 10.1.3 — backing AnsiString for state.zNonce when -nonce sets it. }
  gNonceBacking:        AnsiString = '';
  { 6.22 — backing storage for ShellState.zErrPrefix during argv-sourced
    dot-command dispatch.  Mirrors C shell.c.in:13540..13547 (malloc/free of
    a 64-byte "argv[%i]:" buffer). }
  gErrPrefixBacking:    AnsiString = '';
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
  { Flush stdout before writing to stderr so that under 2>&1 (or any merged
    stream) the error message appears at the position it was emitted, not
    after all subsequent buffered stdout writes.  The C oracle's stderr is
    line-buffered (or unbuffered when isatty), so writes there flush
    immediately — but FPC's StdErr is fully buffered when redirected, and
    stdout is also buffered, so a plain `Write(StdErr,...)` lands after the
    stdout backlog when both share a destination.  Mirroring the C
    behaviour: drain stdout, write, then flush stderr. }
  Flush(Output);
  Write(StdErr, z);
  Flush(StdErr);
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
  p^.mode.autoExplain := 1;           { shell.c.in:1697 modeDefault }
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

{ ----------------------------------------------------------------------
  Built-in shell SQL UDFs — shell.c.in:1217..1388 / 1764..1773 /
  1285..1314 / 4415..4457.  Registered on every connection by openDb()
  so .schema multi-database qualification, edit() / shell_putsnl(),
  and the floating-point round-trip helpers strtod / dtostr behave
  identically to upstream.

  editFunc (shell.c.in:1864..) is intentionally deferred — it spawns
  an external editor via system() and round-trips through a temp file;
  the surface is small but the Linux/Win arm split is large.
  ---------------------------------------------------------------------- }

procedure shellSqliteFreeDel(p: Pointer); cdecl;
{ cdecl trampoline for sqlite3_free, used as destructor for
  sqlite3_result_text on sqlite3_mprintf'd buffers (mirrors the
  base64FreeDel pattern in passqlite3base64). }
begin
  sqlite3_free(p);
end;

function shellQuoteChar(z: PAnsiChar): AnsiChar;
{ shell.c.in:1217..1225 — return '"' if z needs to be quoted as a SQLite
  identifier (non-alpha lead, any non-alnum/_, or matches a keyword);
  otherwise #0. }
var
  i: SizeInt;
  c: AnsiChar;
begin
  if z = nil then Exit('"');
  c := z[0];
  if not (((c >= 'A') and (c <= 'Z'))
       or ((c >= 'a') and (c <= 'z'))
       or (c = '_')) then Exit('"');
  i := 0;
  while z[i] <> #0 do begin
    c := z[i];
    if not (((c >= 'A') and (c <= 'Z'))
         or ((c >= 'a') and (c <= 'z'))
         or ((c >= '0') and (c <= '9'))
         or (c = '_')) then Exit('"');
    Inc(i);
  end;
  if sqlite3_keyword_check(z, i) <> 0 then Exit('"');
  Result := #0;
end;

procedure shellAppendQuoted(var s: AnsiString; const z: AnsiString;
                            quote: AnsiChar);
{ shell.c.in:1173..1207 — appendText with optional double-the-quote
  embedding. }
var
  i: SizeInt;
begin
  if quote = #0 then begin
    s := s + z;
    Exit;
  end;
  s := s + quote;
  for i := 1 to Length(z) do begin
    s := s + z[i];
    if z[i] = quote then s := s + quote;
  end;
  s := s + quote;
end;

function shellFakeSchemaText(db: Psqlite3; zSchema, zName: PAnsiChar): AnsiString;
{ shell.c.in:1234..1276 — synthesize a "tablename(col1,col2,...)" string
  for the view / virtual-table / table-valued function zSchema.zName by
  running PRAGMA <db>.table_info=<name>.  Returns '' when the object has
  no columns (matches C's NULL-return contract — caller checks length). }
var
  zSql: PAnsiChar;
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
  cQuote: AnsiChar;
  zCol: PAnsiChar;
  zDiv: AnsiString;
  nRow: i32;
  zSchemaStr: AnsiString;
begin
  Result := '';
  if zSchema <> nil then
    zSchemaStr := AnsiString(zSchema)
  else
    zSchemaStr := 'main';
  zSql := sqlite3PfMprintf('PRAGMA "%w".table_info=%Q;',
                          [PAnsiChar(zSchemaStr), zName]);
  if zSql = nil then Exit;
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, zSql, -1, @pStmt, @pzTail);
  sqlite3_free(zSql);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit;
  end;
  if zSchema <> nil then begin
    cQuote := shellQuoteChar(zSchema);
    if (cQuote <> #0) and (sqlite3_stricmp(zSchema, 'temp') = 0) then
      cQuote := #0;
    shellAppendQuoted(Result, AnsiString(zSchema), cQuote);
    Result := Result + '.';
  end;
  cQuote := shellQuoteChar(zName);
  shellAppendQuoted(Result, AnsiString(zName), cQuote);
  zDiv := '(';
  nRow := 0;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    zCol := PAnsiChar(sqlite3_column_text(pStmt, 1));
    Inc(nRow);
    Result := Result + zDiv;
    zDiv := ',';
    if zCol = nil then zCol := '';
    cQuote := shellQuoteChar(zCol);
    shellAppendQuoted(Result, AnsiString(zCol), cQuote);
  end;
  Result := Result + ')';
  sqlite3_finalize(pStmt);
  if nRow = 0 then Result := '';
end;

type
  TShellArgArr3 = array[0..2] of PMem;
  PShellArgArr3 = ^TShellArgArr3;

procedure shellStrtodUdf(pCtx: Psqlite3_context;
                         nVal: i32; apVal: PPMem); cdecl;
{ shell.c.in:1285..1294 — strtod(X) via the C library, for fp parity probes. }
var
  pArgs: PShellArgArr3;
  z: PAnsiChar;
  d: Double;
begin
  if nVal < 1 then Exit;
  pArgs := PShellArgArr3(apVal);
  z := PAnsiChar(sqlite3_value_text(pArgs^[0]));
  if z = nil then Exit;
  d := 0;
  try
    d := StrToFloat(AnsiString(z), DefaultFormatSettings);
  except
    on EConvertError do d := 0;
  end;
  sqlite3_result_double(pCtx, d);
end;

procedure shellDtostrUdf(pCtx: Psqlite3_context;
                         nVal: i32; apVal: PPMem); cdecl;
{ shell.c.in:1303..1315 — dtostr(X[, n]) via sprintf("%#+.*e",...). }
var
  pArgs: PShellArgArr3;
  r: Double;
  n: i32;
  z: PAnsiChar;
begin
  pArgs := PShellArgArr3(apVal);
  r := sqlite3_value_double(pArgs^[0]);
  if nVal >= 2 then n := sqlite3_value_int(pArgs^[1]) else n := 26;
  if n < 1 then n := 1;
  if n > 350 then n := 350;
  z := sqlite3PfMprintf('%#+.*e', [n, r]);
  sqlite3_result_text(pCtx, z, -1, @shellSqliteFreeDel);
end;

procedure shellAddSchemaUdf(pCtx: Psqlite3_context;
                            nVal: i32; apVal: PPMem); cdecl;
{ shell.c.in:1336..1388 — shell_add_schema(S, X, name).  When S starts
  with `CREATE TABLE/INDEX/UNIQUE INDEX/VIEW/TRIGGER/VIRTUAL TABLE` the
  schema name X (when non-NULL and not 'temp') is spliced in immediately
  after the kind keyword.  When the kind is VIEW/TRIGGER and shellFakeSchema
  returns a column-list synthesis, that synthesis is appended as a
  `/* ... */` comment for .schema rendering aids. }
const
  aPrefix: array[0..5] of PAnsiChar = (
    'TABLE', 'INDEX', 'UNIQUE INDEX', 'VIEW', 'TRIGGER', 'VIRTUAL TABLE');
var
  pArgs: PShellArgArr3;
  i, n, n7: i32;
  zIn, zSchema, zName: PAnsiChar;
  db: Psqlite3;
  z, zFake, zPrev: PAnsiChar;
  zFakeP: AnsiString;
  cQuote: AnsiChar;
  prefixHead: AnsiString;
begin
  pArgs   := PShellArgArr3(apVal);
  zIn     := PAnsiChar(sqlite3_value_text(pArgs^[0]));
  zSchema := PAnsiChar(sqlite3_value_text(pArgs^[1]));
  zName   := PAnsiChar(sqlite3_value_text(pArgs^[2]));
  db      := sqlite3_context_db_handle(pCtx);
  if (zIn <> nil) and (StrLComp(zIn, 'CREATE ', 7) = 0) then begin
    for i := 0 to High(aPrefix) do begin
      n := StrLen(aPrefix[i]);
      if (StrLComp(zIn + 7, aPrefix[i], n) = 0)
         and (zIn[n + 7] = ' ') then begin
        n7 := n + 7;
        z := nil;
        zFake := nil;
        if zSchema <> nil then begin
          cQuote := shellQuoteChar(zSchema);
          SetLength(prefixHead, n7);
          if n7 > 0 then Move(zIn^, prefixHead[1], n7);
          if (cQuote <> #0) and (sqlite3_stricmp(zSchema, 'temp') <> 0) then
            z := sqlite3PfMprintf('%s "%w".%s',
                                 [PAnsiChar(prefixHead), zSchema, zIn + n7 + 1])
          else
            z := sqlite3PfMprintf('%s %s.%s',
                                 [PAnsiChar(prefixHead), zSchema, zIn + n7 + 1]);
        end;
        if (zName <> nil) and (aPrefix[i][0] = 'V') then begin
          zFakeP := shellFakeSchemaText(db, zSchema, zName);
          if Length(zFakeP) > 0 then zFake := PAnsiChar(zFakeP);
        end;
        if zFake <> nil then begin
          if z = nil then
            z := sqlite3PfMprintf('%s'#10'/* %s */', [zIn, zFake])
          else begin
            zPrev := z;
            z := sqlite3PfMprintf('%s'#10'/* %s */', [zPrev, zFake]);
            sqlite3_free(zPrev);
          end;
        end;
        if z <> nil then begin
          sqlite3_result_text(pCtx, z, -1, @shellSqliteFreeDel);
          Exit;
        end;
      end;
    end;
  end;
  sqlite3_result_value(pCtx, pArgs^[0]);
end;

procedure shellModuleSchemaUdf(pCtx: Psqlite3_context;
                               nVal: i32; apVal: PPMem); cdecl;
{ shell.c.in:4432..4457 — return a /* fake-schema */ comment for the
  vtab / table-valued function named X.  Used by .schema for module-
  defined objects whose stored CREATE statement is incomplete. }
var
  pArgs: PShellArgArr3;
  zName: PAnsiChar;
  zFake: AnsiString;
  zOut: PAnsiChar;
begin
  pArgs := PShellArgArr3(apVal);
  zName := PAnsiChar(sqlite3_value_text(pArgs^[0]));
  if zName = nil then Exit;
  zFake := shellFakeSchemaText(sqlite3_context_db_handle(pCtx), nil, zName);
  if Length(zFake) = 0 then Exit;
  zOut := sqlite3PfMprintf('/* %s */', [PAnsiChar(zFake)]);
  if zOut <> nil then
    sqlite3_result_text(pCtx, zOut, -1, @shellSqliteFreeDel);
end;

procedure shellPutsnlUdf(pCtx: Psqlite3_context;
                         nVal: i32; apVal: PPMem); cdecl;
{ shell.c.in:1764..1773 — print the argument followed by '\n' to stdout
  and return the value unchanged.  Used by upstream as an on-the-fly
  trace helper inside SELECT pipelines. }
var
  pArgs: PShellArgArr3;
  z: PAnsiChar;
begin
  pArgs := PShellArgArr3(apVal);
  z := PAnsiChar(sqlite3_value_text(pArgs^[0]));
  if z <> nil then WriteLn(z) else WriteLn('');
  sqlite3_result_value(pCtx, pArgs^[0]);
end;

procedure shellUSleepUdf(pCtx: Psqlite3_context;
                         nVal: i32; apVal: PPMem); cdecl;
{ shell.c.in:4415..4424 — usleep(N).  Sleep N microseconds (rounded down
  to the nearest millisecond by sqlite3_sleep) and return N. }
var
  pArgs: PShellArgArr3;
  ms: i32;
begin
  pArgs := PShellArgArr3(apVal);
  ms := sqlite3_value_int(pArgs^[0]);
  sqlite3_sleep(ms div 1000);
  sqlite3_result_int(pCtx, ms);
end;

procedure registerShellBuiltins(db: Psqlite3);
{ shell.c.in:4590..4607 — registration block invoked from open_db().
  editFunc deferred (system() spawn + temp-file shuttle); everything
  else is wired so .schema, fp parity probes, and trace pipelines have
  the upstream UDF surface available. }
const
  FFlags = SQLITE_UTF8;
begin
  if db = nil then Exit;
  sqlite3_create_function(db, 'strtod', 1, FFlags, nil,
                          @shellStrtodUdf, nil, nil);
  sqlite3_create_function(db, 'dtostr', 1, FFlags, nil,
                          @shellDtostrUdf, nil, nil);
  sqlite3_create_function(db, 'dtostr', 2, FFlags, nil,
                          @shellDtostrUdf, nil, nil);
  sqlite3_create_function(db, 'shell_add_schema', 3, FFlags, nil,
                          @shellAddSchemaUdf, nil, nil);
  sqlite3_create_function(db, 'shell_module_schema', 1, FFlags, nil,
                          @shellModuleSchemaUdf, nil, nil);
  sqlite3_create_function(db, 'shell_putsnl', 1, FFlags, nil,
                          @shellPutsnlUdf, nil, nil);
  sqlite3_create_function(db, 'usleep', 1, FFlags, nil,
                          @shellUSleepUdf, nil, nil);
end;

{ shell.c.in:4110 — shellReadFile.  Slurp the entire contents of zName into
  a fresh sqlite3_malloc64 buffer; returns nil on open / read error.  Used
  exclusively by openDb's SHELL_OPEN_DESERIALIZE arm (the C source name is
  just readFile but we prefix it to avoid colliding with the readfile()
  SQL function exported by passqlite3fileio). }
function shellReadFile(zName: PAnsiChar; pnByte: Pi32): PAnsiChar;
var
  h:      THandle;
  nIn:    Int64;
  pBuf:   PAnsiChar;
  nRead:  PtrInt;
begin
  Result := nil;
  if zName = nil then Exit;
  h := FileOpen(AnsiString(zName), fmOpenRead or fmShareDenyNone);
  if h = THandle(-1) then Exit;
  nIn := FileSeek(h, Int64(0), 2);  { fsFromEnd }
  if nIn < 0 then begin
    FileClose(h);
    shellEPutZ(Format('Error: ''%s'' not seekable'#10, [AnsiString(zName)]));
    Exit;
  end;
  FileSeek(h, Int64(0), 0);  { fsFromBeginning }
  pBuf := PAnsiChar(sqlite3_malloc64(u64(nIn + 1)));
  if pBuf = nil then begin
    FileClose(h);
    shellEPutZ('Error: out of memory'#10);
    Exit;
  end;
  nRead := FileRead(h, pBuf^, nIn);
  FileClose(h);
  if nRead <> nIn then begin
    sqlite3_free(pBuf);
    shellEPutZ(Format('Error: cannot read ''%s'''#10, [AnsiString(zName)]));
    Exit;
  end;
  (pBuf + nIn)^ := #0;
  if pnByte <> nil then pnByte^ := i32(nIn);
  Result := pBuf;
end;

{ shell.c.in:4324 — shellReadHexDb.  Parse the textual hex-dump emitted by
  `.dump --hexdb` back into raw page bytes.  Each input frame has a
  `| size N pagesize K` header, optional `| page J offset K` per-page
  resets, hex rows `| OFF: x0 x1 ... x15`, terminated by `| end DB`.
  Only the file-source path is supported here (open via the filename in
  p->pAuxDb->zDbFilename); the in-script `.open --hexdb` from a `.read`
  context routes through the same path since the shell injects the
  filename on its way in. }
function shellReadHexDb(p: PShellState; pnData: Pi32): PAnsiChar;
var
  h:       THandle;
  zText:   AnsiString;
  zLine:   AnsiString;
  nByte:   Int64;
  n, pgsz: i32;
  sz:      Int64;
  iOffset: Int64;
  iOff:    Int64;
  a:       PAnsiChar;
  pos:     SizeInt;
  nlPos:   SizeInt;
  rcSscanf: i32;
  j, ii:   i32;
  x:       array[0..15] of u32;
  errLine: i32;
  zDbFilename: PAnsiChar;
  function takeLine: Boolean;
  begin
    Result := False;
    if pos > Length(zText) then Exit;
    nlPos := PosEx(#10, zText, pos);
    if nlPos = 0 then nlPos := Length(zText) + 1;
    zLine := Copy(zText, pos, nlPos - pos);
    pos := nlPos + 1;
    Result := True;
  end;
  label readHexDb_error;
begin
  Result := nil;
  if pnData <> nil then pnData^ := 0;
  a := nil;
  zDbFilename := p^.pAuxDb^.zDbFilename;
  if zDbFilename = nil then Exit;
  h := FileOpen(AnsiString(zDbFilename), fmOpenRead or fmShareDenyNone);
  if h = THandle(-1) then begin
    shellEPutZ(Format('cannot open "%s" for reading'#10,
      [AnsiString(zDbFilename)]));
    Exit;
  end;
  nByte := FileSeek(h, Int64(0), 2);
  FileSeek(h, Int64(0), 0);
  SetLength(zText, nByte);
  if nByte > 0 then FileRead(h, zText[1], nByte);
  FileClose(h);
  pos := 1;
  errLine := 1;
  if not takeLine then goto readHexDb_error;
  n := 0; pgsz := 0;
  rcSscanf := SScanf(zLine, '| size %d pagesize %d', [@n, @pgsz]);
  if rcSscanf < 2 then goto readHexDb_error;
  if n < 0 then goto readHexDb_error;
  if (pgsz < 512) or (pgsz > 65536) or ((pgsz and (pgsz - 1)) <> 0) then begin
    shellEPutZ('invalid pagesize'#10);
    goto readHexDb_error;
  end;
  sz := (Int64(n) + pgsz - 1) and not Int64(pgsz - 1);
  if sz = 0 then a := PAnsiChar(sqlite3_malloc64(1))
  else a := PAnsiChar(sqlite3_malloc64(u64(sz)));
  if a = nil then goto readHexDb_error;
  FillChar(a^, sz, 0);
  iOffset := 0;
  Inc(errLine);
  while takeLine do begin
    Inc(errLine);
    j := 0;
    rcSscanf := SScanf(zLine, '| page %d offset %d', [@j, @iOffset]);
    if rcSscanf >= 2 then Continue;
    if Copy(zLine, 1, 6) = '| end ' then Break;
    rcSscanf := SScanf(zLine,
      '| %d: %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x',
      [@j, @x[0], @x[1], @x[2], @x[3], @x[4], @x[5], @x[6], @x[7],
       @x[8], @x[9], @x[10], @x[11], @x[12], @x[13], @x[14], @x[15]]);
    if rcSscanf = 17 then begin
      iOff := iOffset + j;
      if (iOff + 16 <= sz) and (iOff >= 0) then
        for ii := 0 to 15 do
          (a + iOff + ii)^ := AnsiChar(x[ii] and $FF);
    end;
  end;
  if pnData <> nil then pnData^ := i32(sz);
  Result := a;
  Exit;

readHexDb_error:
  if a <> nil then sqlite3_free(a);
  shellEPutZ(Format('Error on line %d of --hexdb input'#10, [errLine]));
end;

{ Open the database connection backing p^ if not already open.  Mirrors
  open_db (shell.c.in:6745..) at the level needed by the dispatcher
  skeleton: --readonly / --create / default SQLITE_OPEN_READWRITE|
  SQLITE_OPEN_CREATE. }
procedure openDb(p: PShellState; keepAlive: i32);
var
  flags:  i32;
  rc:     i32;
  zErr:   PAnsiChar;
  zSql:   PAnsiChar;
  nData:  i32;
  aData:  PAnsiChar;
  szMaxLocal: i64;
begin
  if p^.db <> nil then Exit;
  if p^.pAuxDb^.zDbFilename = nil then Exit;
  flags := p^.openFlags;
  if (flags and (SQLITE_OPEN_READONLY or SQLITE_OPEN_READWRITE)) = 0 then
    flags := flags or SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE;
  { shell.c.in:4491..4510 — dispatch on openMode.  ZIPFILE opens an in-memory
    db (the zipfile vtab carries the file); DESERIALIZE/HEXDB also open a
    private temp db then sqlite3_deserialize() swaps the slurped bytes in.
    APPENDVFS passes the filename through the apndvfs shim. }
  case p^.openMode of
    SHELL_OPEN_APPENDVFS:
      rc := sqlite3_open_v2(p^.pAuxDb^.zDbFilename, @p^.db, flags, 'apndvfs');
    SHELL_OPEN_HEXDB, SHELL_OPEN_DESERIALIZE:
      rc := sqlite3_open(nil, @p^.db);
    SHELL_OPEN_ZIPFILE:
      rc := sqlite3_open(':memory:', @p^.db);
  else
    rc := sqlite3_open_v2(p^.pAuxDb^.zDbFilename, @p^.db, flags, nil);
  end;
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
  { Mirror shell.c.in:4530..4537 — reset scan-status, reflect --unsafe-testing
    on TRUSTED_SCHEMA / DEFENSIVE.  Without this the connection defaults
    leave TrustedSchema on, which diverges from the C oracle CLI on the
    `PRAGMA trusted_schema;` / `PRAGMA defensive;` round-trip. }
  sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_STMT_SCANSTATUS, 0, nil);
  if (p^.shellFlgs and SHFLG_TestingMode) <> 0 then begin
    sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 1, nil);
    sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_DEFENSIVE,      0, nil);
  end else begin
    sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, nil);
    sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_DEFENSIVE,      1, nil);
  end;
  { Built-in shell SQL UDFs — strtod / dtostr / shell_add_schema /
    shell_module_schema / shell_putsnl / usleep.  Mirrors shell.c.in
    open_db registration block (4590..4607). }
  registerShellBuiltins(p^.db);
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
  { Phase 10.1.64 — rot13() function + rot13 collation
    (ext/misc/rot13.c), uint collation (ext/misc/uint.c),
    base64() function (ext/misc/base64.c). }
  sqlite3RotInit(p^.db);
  sqlite3UintInit(p^.db);
  sqlite3Base64Init(p^.db);
  { Phase 10.1.65 — tointeger() / toreal() lossless conversion functions
    from ext/misc/totype.c. }
  sqlite3TotypeInit(p^.db);
  { Phase 10.1.66 — base85() / is_base85() (ext/misc/base85.c),
    eval(X) / eval(X,Y) (ext/misc/eval.c), and the sqlite3_uri_* /
    sqlite3_filename_* SQL wrappers (ext/misc/urifuncs.c). }
  sqlite3Base85Init(p^.db);
  sqlite3EvalInit(p^.db);
  sqlite3UrifuncsInit(p^.db);
  { Phase 10.1.67 — anycollseq fallback collation, blobio readblob/
    writeblob, next_char(), remember(), and stmtrand() — small
    ext/misc helpers from anycollseq.c, blobio.c, nextchar.c,
    remember.c, stmtrand.c. }
  sqlite3AnycollseqInit(p^.db);
  sqlite3BlobioInit(p^.db);
  sqlite3NextcharInit(p^.db);
  sqlite3RememberInit(p^.db);
  sqlite3StmtrandInit(p^.db);
  { Phase 10.1.68 — three more small ext/misc helpers from
    noop.c (noop / noop_i / noop_do / noop_nd / multitype_text),
    zorder.c (zorder / unzorder Morton-code interleave),
    randomjson.c (random_json / random_json5 deterministic
    pseudo-random JSON for fuzz testing). }
  sqlite3NoopInit(p^.db);
  sqlite3ZorderInit(p^.db);
  sqlite3RandomJsonInit(p^.db);
  { Phase 10.1.69 — four more small ext/misc helpers from
    wholenumber.c (eponymous wholenumber vtab over 1..2^32-1),
    templatevtab.c (10-row read-only template vtab),
    showauth.c (debug authorizer that traces requests to stdout),
    mmapwarm.c (sqlite3_mmap_warm pre-fault walker — no-op on the
    current Unix VFS which is iVersion=2). showauth is registered
    only on user request via .auth on; sqlite3_mmap_warm is exposed
    as a function, not auto-installed. }
  sqlite3WholenumberInit(p^.db);
  sqlite3TemplateVtabInit(p^.db);
  { Phase 10.1.70 — prefixes() table-valued function + prefix_length()
    scalar from ext/misc/prefixes.c, and the sqlite_memstat eponymous
    vtab from ext/misc/memstat.c. }
  sqlite3PrefixesInit(p^.db);
  sqlite3MemstatVtabInit(p^.db);
  { Phase 10.1.71 — generate_series eponymous vtab from
    ext/misc/series.c (937 C lines). }
  sqlite3SeriesInit(p^.db);
  { Phase 10.1.72 — completion eponymous vtab from
    ext/misc/completion.c (522 C lines).  Powers SQL tab-completion
    (KEYWORDS / DATABASES / TABLES / COLUMNS phases). }
  sqlite3CompletionVtabInit(p^.db);
  { Phase 10.1.73 — arbitrary-precision decimal arithmetic from
    ext/misc/decimal.c (952 C lines): decimal / decimal_exp / decimal_cmp /
    decimal_add / decimal_sub / decimal_mul / decimal_pow2 / decimal_sum
    aggregate, plus the `decimal` collation. }
  sqlite3DecimalInit(p^.db);
  { Phase 10.1.74 — sqlite3_normalize() helper from ext/misc/normalize.c
    (717 C lines).  Registered as a SQL function `sqlite3_normalize(X)`
    for differential testing; the underlying public C-style helper is
    also exported by passqlite3normalize. }
  sqlite3NormalizeInit(p^.db);
  { Phase 10.1.75 — regexp() / regexpi() SQL functions and the REGEXP
    operator from ext/misc/regexp.c (928 C lines).  POSIX-extended
    regular expressions over UTF-8 input via NFA matcher. }
  sqlite3RegexpInit(p^.db);
  { Phase 10.1.76 — sqlite_stmt eponymous vtab from ext/misc/stmt.c
    (347 C lines): one row per still-open prepared statement on the
    connection, with sql + the sqlite3_stmt_status() counter set. }
  sqlite3StmtVtabInit(p^.db);
  { Phase 10.1.76 — explain eponymous vtab from ext/misc/explain.c
    (323 C lines): SELECT … FROM explain('SELECT …') yields the
    bytecode rows of the inner statement (addr/opcode/p1..p5/comment). }
  sqlite3ExplainVtabInit(p^.db);
  { Phase 10.1.77 — qpvtab eponymous vtab from ext/misc/qpvtab.c
    (462 C lines): debugging vtab whose rows describe how the query
    planner called xBestIndex. }
  sqlite3QpvtabInit(p^.db);
  { Phase 10.1.78 — sqlite_btreeinfo eponymous vtab from
    ext/misc/btreeinfo.c (434 C lines): one row per btree in the
    file, with type/name/tbl_name/rootpage/sql plus estimated
    nEntry/nPage/depth/szPage/hasRowid computed from sqlite_dbpage. }
  sqlite3BinfoRegister(p^.db);
  { Phase 10.1.80 — fossil delta encoder from ext/misc/fossildelta.c
    (1109 C lines): delta_create / delta_apply / delta_output_size SQL
    functions plus the delta_parse(D) eponymous table-valued function. }
  sqlite3FossildeltaInit(p^.db);
  { Phase 10.1.82 — csv virtual table from ext/misc/csv.c (977 C lines):
    CREATE VIRTUAL TABLE temp.t USING csv(filename=…) reads RFC-4180 CSV
    either from a file or from an inline data= string. }
  sqlite3CsvInit(p^.db);
  { Phase 10.1.83 — transitive_closure virtual table from
    ext/misc/closure.c (971 C lines): CREATE VIRTUAL TABLE … USING
    transitive_closure(tablename=…, idcolumn=…, parentcolumn=…) computes
    the transitive closure of a parent/child relation in a real table. }
  sqlite3ClosureInit(p^.db);
  { Phase 10.1.84 — appendvfs VFS shim from ext/misc/appendvfs.c (672 C
    lines): allows opening a SQLite database appended at the end of
    another file (e.g. an executable) via `sqlite3_open_v2(..., "apndvfs")`. }
  sqlite3AppendvfsInit(p^.db);
  { Phase 10.1.90 — verify_checksum SQL function from
    ext/misc/cksumvfs.c (847 C lines).  Registers only the SQL helper on
    every connection; the cksmvfs shim itself is exported as
    sqlite3_register_cksumvfs() but not auto-installed because making
    cksmvfs the default VFS would intercept every open() and corrupt
    sessions on databases without an 8-byte reserve. }
  sqlite3CksumvfsInit(p^.db);
  { Phase 10.1.86 — readfile / writefile / lsmode / realpath SQL functions
    plus the fsdir() eponymous virtual table from ext/misc/fileio.c
    (1234 C lines).  fsdir is the backing storage for `.archive` and
    related shell features. }
  sqlite3FileioInit(p^.db);
  { Phase 10.1.87 — vfsstat eponymous virtual table from
    ext/misc/vfsstat.c (825 C lines).  Upstream shell.c.in does NOT
    auto-install vfsstat (it's a separately-loadable extension), so
    matching the upstream shell precedent (cf. 10.1.90 cksumvfs) we
    keep sqlite3VfsstatInit / sqlite3_register_vfsstat exported but
    do NOT auto-call them here.  Wiring this in unconditionally would
    add a "vfslog"-named VFS shim to sqlite3_vfs_find(0)->pNext and
    break byte-parity for the `.vfslist` dot-command (10.1f.15). }
  { sqlite3VfsstatInit(p^.db); }
  { vtablog (ext/misc/vtablog.c, 720 C lines) is exported but NOT
    auto-installed — every callback writes a trace line to stdout, so
    auto-registering would corrupt every shell session.  Loading it
    explicitly via `SELECT load_extension('vtablog');` (when wired) or
    a host program is up to the caller. }
  { Phase 10.1.91 — unionvtab / swarmvtab from ext/misc/unionvtab.c
    (1383 C lines): CREATE VIRTUAL TABLE temp.t USING unionvtab(<sql>)
    presents many rowid tables behind one schema; swarmvtab opens
    per-source db files on demand bounded by maxopen=N. }
  sqlite3UnionvtabInit(p^.db);
  { Phase 10.1.92 — fuzzer virtual table from ext/misc/fuzzer.c
    (1192 C lines): CREATE VIRTUAL TABLE f USING fuzzer(<rule-table>)
    generates variations on a query word at increasing edit distances
    using costed character-rewrite rules. }
  sqlite3FuzzerInit(p^.db);
  { Phase 10.1.94 — approximate_match virtual table from
    ext/misc/amatch.c (1502 C lines): CREATE VIRTUAL TABLE f USING
    approximate_match(vocabulary_table=…, vocabulary_word=…,
    edit_distances=…) yields strings from a finite vocabulary that
    are nearly the same as a single user-supplied input string,
    ranked by edit-distance under a costed character-rewrite ruleset. }
  sqlite3AmatchInit(p^.db);
  { Phase 10.1.95 — compress() / uncompress() (ext/misc/compress.c) and
    sqlar_compress() / sqlar_uncompress() (ext/misc/sqlar.c).  Both back
    onto libz; provide zlib-format payloads with an out-of-band original-
    size frame (compress prepends a 1..5 byte varint, sqlar carries SZ
    in its caller's row schema). }
  sqlite3CompressInit(p^.db);
  sqlite3SqlarInit(p^.db);
  { Phase 10.1.98 — zipfile() vtab + aggregate from ext/misc/zipfile.c
    (2293 C lines).  Reads/writes ZIP archives via libz inflate/deflate. }
  sqlite3ZipfileInit(p^.db);
  { Phase 10.1.99 — spellfix1_editdist / spellfix1_phonehash /
    spellfix1_scriptcode scalar SQL functions from ext/misc/spellfix.c
    (the editdist1 + phoneticHash + scriptCode subset; the spellfix1
    virtual table and editdist3 family are not yet ported). }
  sqlite3SpellfixInit(p^.db);
  { Phase 10.1.97 — sqlite_dbdata / sqlite_dbptr eponymous virtual tables
    from ext/recover/dbdata.c (1023 C lines).  Reads raw b-tree page bytes
    via sqlite_dbpage; backing storage for the upcoming .recover dot-cmd. }
  sqlite3DbdataRegister(p^.db);
  { 10.1.102 — shell.c.in:4613..4644 post-open block for ZIPFILE / DESERIALIZE
    / HEXDB modes.  ZIPFILE attaches a `zip` vtab over the filename;
    DESERIALIZE/HEXDB slurp the file (or hex dump) and hand the buffer to
    sqlite3_deserialize() with FREEONCLOSE|RESIZEABLE. }
  case p^.openMode of
    SHELL_OPEN_ZIPFILE: begin
      zSql := sqlite3PfMprintf(
        PAnsiChar('CREATE VIRTUAL TABLE zip USING zipfile(%Q);'),
        [p^.pAuxDb^.zDbFilename]);
      if zSql <> nil then begin
        sqlite3_exec(p^.db, zSql, nil, nil, nil);
        sqlite3_free(zSql);
      end;
    end;
    SHELL_OPEN_DESERIALIZE, SHELL_OPEN_HEXDB: begin
      nData := 0;
      if p^.openMode = SHELL_OPEN_DESERIALIZE then
        aData := shellReadFile(p^.pAuxDb^.zDbFilename, @nData)
      else
        aData := shellReadHexDb(p, @nData);
      if aData <> nil then begin
        rc := sqlite3_deserialize(p^.db, 'main', Pu8(aData),
                i64(nData), i64(nData),
                u32(SQLITE_DESERIALIZE_RESIZEABLE
                    or SQLITE_DESERIALIZE_FREEONCLOSE));
        if rc <> 0 then
          shellEPutZ(Format('Error: sqlite3_deserialize() returns %d'#10, [rc]));
        if p^.szMax > 0 then begin
          szMaxLocal := p^.szMax;
          sqlite3_file_control(p^.db, 'main', SQLITE_FCNTL_SIZE_LIMIT,
                               @szMaxLocal);
        end;
      end;
    end;
  end;
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

{ ----------------------------------------------------------------------
  10.1.2.c  DynaPrompt — dynamic continuation prompt tracker.
  Port of shell.c.in:849..906 (struct DynaPrompt + trackParenLevel +
  setLexemeOpen + dynamicContinuePrompt) plus the four CONTINUE_PROMPT_*
  macros at shell.c.in:839..847.

  Tracks open-string / open-comment / paren depth across input lines so
  the shell can render `   /*` / `   '` / `   "` / `   (x2` style
  continuation prompts.  Mutated from quickScan via continuePrompt*
  helpers below and reset from processInput at statement boundaries.
  ---------------------------------------------------------------------- }
type
  TDynaPrompt = record
    dynamicPrompt:    array[0..PROMPT_LEN_MAX-1] of AnsiChar;
    acAwait:          array[0..1] of AnsiChar;
    inParenLevel:     i32;
    zScannerAwaits:   PAnsiChar;     { nil when not awaiting a lexeme close }
  end;
  PDynaPrompt = ^TDynaPrompt;

var
  dynPrompt: TDynaPrompt;       { zero-initialised at unit load }

{ Record parenthesis nesting level change, or force level to 0.
  shell.c.in:860..864. }
procedure trackParenLevel(p: PDynaPrompt; ni: i32);
begin
  if p = nil then Exit;
  p^.inParenLevel := p^.inParenLevel + ni;
  if ni = 0 then p^.inParenLevel := 0;
  p^.zScannerAwaits := nil;
end;

{ Record that a lexeme is opened (s<>nil or c<>0), or both==0 to clear.
  shell.c.in:867..876.  Note the C: if(s!=0 || c==0) clear-and-store-s,
  else store the single char c.  We follow byte-for-byte. }
procedure setLexemeOpen(p: PDynaPrompt; s: PAnsiChar; c: AnsiChar);
begin
  if p = nil then Exit;
  if (s <> nil) or (c = #0) then begin
    p^.zScannerAwaits := s;
    p^.acAwait[0] := #0;
  end else begin
    p^.acAwait[0] := c;
    p^.zScannerAwaits := @p^.acAwait[0];
  end;
end;

{ Macro helpers — gated on stdin_is_interactive like upstream. }
procedure continuePromptReset; inline;
begin
  setLexemeOpen(@dynPrompt, nil, #0);
  trackParenLevel(@dynPrompt, 0);
end;

procedure continuePromptAwaitS(p: PDynaPrompt; s: PAnsiChar); inline;
begin
  if (p <> nil) and (stdin_is_interactive <> 0) then setLexemeOpen(p, s, #0);
end;

procedure continuePromptAwaitC(p: PDynaPrompt; c: AnsiChar); inline;
begin
  if (p <> nil) and (stdin_is_interactive <> 0) then setLexemeOpen(p, nil, c);
end;

procedure continueParenIncr(p: PDynaPrompt; n: i32); inline;
begin
  if (p <> nil) and (stdin_is_interactive <> 0) then trackParenLevel(p, n);
end;

{ shell.c.in:878..905 — derive the continuation prompt for display.
  Returns a NUL-terminated pointer into dynPrompt.dynamicPrompt when an
  open lexeme / paren level rewrites the first 3 chars; otherwise
  returns continuePromptStr unchanged. }
function dynamicContinuePromptStr: AnsiString;
var
  ncp, ndp, i: SizeInt;
  zAwait: PAnsiChar;
begin
  if (Length(continuePromptStr) = 0)
     or ((dynPrompt.zScannerAwaits = nil) and (dynPrompt.inParenLevel = 0)) then
  begin
    Result := continuePromptStr;
    Exit;
  end;
  if dynPrompt.zScannerAwaits <> nil then begin
    zAwait := dynPrompt.zScannerAwaits;
    ncp := Length(continuePromptStr);
    ndp := 0;
    while zAwait[ndp] <> #0 do Inc(ndp);
    if ndp > ncp - 3 then begin
      Result := continuePromptStr;
      Exit;
    end;
    FillChar(dynPrompt.dynamicPrompt, SizeOf(dynPrompt.dynamicPrompt), 0);
    for i := 0 to ndp-1 do dynPrompt.dynamicPrompt[i] := zAwait[i];
    while ndp < 3 do begin
      dynPrompt.dynamicPrompt[ndp] := ' ';
      Inc(ndp);
    end;
    { Copy continuePromptStr[3..] into dynamicPrompt[3..] }
    i := 4;
    while (i <= Length(continuePromptStr))
          and (3 + (i-4) < PROMPT_LEN_MAX-1) do
    begin
      dynPrompt.dynamicPrompt[3 + (i-4)] := AnsiChar(continuePromptStr[i]);
      Inc(i);
    end;
  end else begin
    FillChar(dynPrompt.dynamicPrompt, SizeOf(dynPrompt.dynamicPrompt), 0);
    if dynPrompt.inParenLevel > 9 then begin
      dynPrompt.dynamicPrompt[0] := '(';
      dynPrompt.dynamicPrompt[1] := '.';
      dynPrompt.dynamicPrompt[2] := '.';
    end else if dynPrompt.inParenLevel < 0 then begin
      dynPrompt.dynamicPrompt[0] := ')';
      dynPrompt.dynamicPrompt[1] := 'x';
      dynPrompt.dynamicPrompt[2] := '!';
    end else begin
      dynPrompt.dynamicPrompt[0] := '(';
      dynPrompt.dynamicPrompt[1] := 'x';
      dynPrompt.dynamicPrompt[2] := AnsiChar(Ord('0') + dynPrompt.inParenLevel);
    end;
    i := 4;
    while (i <= Length(continuePromptStr))
          and (3 + (i-4) < PROMPT_LEN_MAX-1) do
    begin
      dynPrompt.dynamicPrompt[3 + (i-4)] := AnsiChar(continuePromptStr[i]);
      Inc(i);
    end;
  end;
  Result := AnsiString(PAnsiChar(@dynPrompt.dynamicPrompt[0]));
end;

function oneInputLine(p: PShellState; isContinuation: Boolean;
                      out atEof: Boolean): AnsiString;
begin
  if curInputText <> nil then begin
    Result := localGetLine(curInputText^, atEof);
    Exit;
  end;
  if (p^.inFile = nil) and (stdin_is_interactive <> 0) then begin
    if isContinuation then Write(dynamicContinuePromptStr)
    else Write(mainPromptStr);
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

{ Mirrors upstream quickscan's QSS_PLAINWHITE check for a single line:
  whitespace, an SQL `--` line comment, or a fully-closed `/* ... */`
  block comment counts as "plain white".  Used by processInput so that
  comment-only lines arriving before any SQL accumulator content are
  swallowed, matching shell.c.in:35921 (and ensuring `near line N` later
  anchors at the first real SQL line, not the comment that preceded it). }
function isPlainWhiteOrComment(const s: AnsiString): Boolean;
var i, n: SizeInt;
begin
  Result := False;
  n := Length(s);
  i := 1;
  while i <= n do begin
    while (i <= n) and (s[i] in [' ', #9, #11, #13]) do Inc(i);
    if i > n then Break;
    if (i < n) and (s[i] = '-') and (s[i+1] = '-') then begin
      { line comment runs to end of line }
      i := n + 1;
      Break;
    end;
    if (i < n) and (s[i] = '/') and (s[i+1] = '*') then begin
      Inc(i, 2);
      while (i < n) and not ((s[i] = '*') and (s[i+1] = '/')) do Inc(i);
      if (i < n) and (s[i] = '*') and (s[i+1] = '/') then
        Inc(i, 2)
      else
        Exit(False);   { unterminated block comment — needs accumulator }
      Continue;
    end;
    Exit(False);
  end;
  Result := True;
end;

{ ----------------------------------------------------------------------
  10.1.2.a  quickScan — port of shell.c.in:12077..12175.

  Resumable line classifier.  The low byte of the state holds `cWait` (the
  pending close delimiter inside a string/comment, or 0 in PlainScan); two
  flag bits above sit in the high byte:
    QSS_HasDark    — a non-space, non-comment character has been seen
    QSS_EndingSemi — the last dark character was an unquoted `;`
  After each line, processInput inspects:
    QSS_SEMITERM   — exactly EndingSemi (optionally with HasDark), no cWait,
                     i.e. line ended on a logical `;`
    QSS_PLAINWHITE — neither HasDark nor cWait set
  The C is two labelled loops joined by goto; the Pascal mirrors that with
  two procedures driven by a `state` flag so the structure remains
  diff-friendly against upstream.  The CONTINUE_PROMPT_* / paren tracker
  hooks belong to 10.1.2.c — omitted here. }
type
  TQuickScanState = i32;   { upstream uses a bitfield enum; an int suffices }
const
  QSS_Start_C    : TQuickScanState = 0;
  QSS_HasDark    : TQuickScanState = $0100;     { 1 << CHAR_BIT }
  QSS_EndingSemi : TQuickScanState = $0200;     { 2 << CHAR_BIT }
  QSS_CharMask   : TQuickScanState = $00FF;
  QSS_ScanMask   : TQuickScanState = $0300;

function QSS_SETV(qss, newst: TQuickScanState): TQuickScanState; inline;
begin
  Result := newst or (qss and QSS_ScanMask);
end;

function QSS_PLAINWHITE(qss: TQuickScanState): Boolean; inline;
begin
  Result := (qss and (not QSS_EndingSemi)) = 0;
end;

function QSS_SEMITERM(qss: TQuickScanState): Boolean; inline;
begin
  Result := (qss and (not QSS_HasDark)) = QSS_EndingSemi;
end;

function QSS_INPLAIN(qss: TQuickScanState): Boolean; inline;
begin
  Result := (qss and QSS_CharMask) = 0;
end;

{ String-literal pool for CONTINUE_PROMPT_AWAITS — must be stable pointers
  since DynaPrompt.zScannerAwaits holds them across calls. }
const
  zAwaitBlockComment: PAnsiChar = '/*';

function quickScan(zLine: PAnsiChar; qss: TQuickScanState;
                   pst: PDynaPrompt): TQuickScanState;
var
  cin, cWait: AnsiChar;
  state: i32;     { 0 = PlainScan, 1 = TermScan; mirrors C's two goto labels }
begin
  cWait := AnsiChar(qss and QSS_CharMask);     { shell.c.in:12101 }
  if cWait = #0 then state := 0 else state := 1;
  while True do begin
    if state = 0 then begin
      { PlainScan — shell.c.in:12103..12145 }
      while zLine^ <> #0 do begin
        cin := zLine^;
        Inc(zLine);
        if cin in [' ', #9, #10, #11, #12, #13] then Continue;   { IsSpace }
        case cin of
          '-':
            begin
              if zLine^ <> '-' then begin
                { fall through to dark-char accounting below }
              end else begin
                { `--` line comment — scan to '\n' or EOL.  shell.c.in:12108..12114. }
                while True do begin
                  Inc(zLine);
                  cin := zLine^;
                  if cin = #0 then begin Result := qss; Exit; end;
                  if cin = #10 then Break;   { resume PlainScan past LF }
                end;
                Continue;
              end;
            end;
          ';':
            begin
              qss := qss or QSS_EndingSemi;
              Continue;
            end;
          '/':
            begin
              if zLine^ = '*' then begin
                Inc(zLine);
                cWait := '*';
                continuePromptAwaitS(pst, zAwaitBlockComment);
                qss := QSS_SETV(qss, Ord(cWait));
                state := 1;
                Break;                       { goto TermScan }
              end;
              { lone '/' — dark char accounting below }
            end;
          '[':
            begin
              cWait := ']';
              qss := QSS_HasDark or Ord(cWait);
              continuePromptAwaitC(pst, '[');  { shell.c.in:12131..12134 }
              state := 1;
              Break;
            end;
          '`', '''', '"':
            begin
              cWait := cin;
              qss := QSS_HasDark or Ord(cWait);
              continuePromptAwaitC(pst, cin);
              state := 1;
              Break;
            end;
          '(':
            begin
              continueParenIncr(pst, 1);
            end;
          ')':
            begin
              continueParenIncr(pst, -1);
            end;
        end;
        { Default dark-char tail: clear EndingSemi, set HasDark.
          shell.c.in:12144. }
        qss := (qss and (not QSS_EndingSemi)) or QSS_HasDark;
      end;
      if state = 0 then begin Result := qss; Exit; end;
    end else begin
      { TermScan — shell.c.in:12147..12172 }
      while zLine^ <> #0 do begin
        cin := zLine^;
        Inc(zLine);
        if cin = cWait then begin
          case cWait of
            '*':
              begin
                if zLine^ <> '/' then Continue;
                Inc(zLine);
                continuePromptAwaitC(pst, #0);
                qss := QSS_SETV(qss, 0);
                cWait := #0;
                state := 0;
                Break;                       { goto PlainScan }
              end;
            '`', '''', '"':
              begin
                if zLine^ = cWait then begin
                  Inc(zLine);                { swallow doubled delimiter }
                  Continue;
                end;
                continuePromptAwaitC(pst, #0);
                qss := QSS_SETV(qss, 0);
                cWait := #0;
                state := 0;
                Break;
              end;
            ']':
              begin
                continuePromptAwaitC(pst, #0);
                qss := QSS_SETV(qss, 0);
                cWait := #0;
                state := 0;
                Break;
              end;
          end;
        end;
      end;
      if state = 1 then begin Result := qss; Exit; end;
    end;
  end;
end;

{ ----------------------------------------------------------------------
  10.1.2.b  lineIsCommandTerminator — port of shell.c.in:12182..12191.

  Returns True if the trimmed line is bare `/` (Oracle) or bare `go`
  (SQL Server, case-insensitive) — both of which the shell rewrites to
  `;` so the SQL statement completes.  Hands the post-token tail to
  quickScan to ensure there's nothing dark trailing (only whitespace /
  comments are allowed). }
function lineIsCommandTerminator(zLine: PAnsiChar): Boolean;
begin
  Result := False;
  while (zLine^ <> #0) and (zLine^ in [' ', #9, #10, #11, #12, #13]) do
    Inc(zLine);
  if zLine^ = '/' then
    Inc(zLine)
  else if ((zLine^ = 'g') or (zLine^ = 'G'))
       and ((PAnsiChar(zLine + 1)^ = 'o') or (PAnsiChar(zLine + 1)^ = 'O')) then
    Inc(zLine, 2)
  else
    Exit;
  { Trailing tail must remain at QSS_Start — i.e. nothing dark.  We pass
    nil for pst since this scan is throwaway and must not perturb the
    real continuation-prompt tracker. }
  Result := quickScan(zLine, 0, nil) = 0;
end;

{ shell.c.in:12205..12217 — return True if zSql is a complete statement
  *if* a trailing `;` were appended.  In C the buffer is poked in place;
  in Pascal we append to a local copy. }
function lineIsComplete(const zSql: AnsiString): Boolean;
var z: AnsiString;
begin
  if zSql = '' then begin Result := True; Exit; end;
  z := zSql + ';';
  Result := sqlite3_complete(PAnsiChar(z)) <> 0;
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

function identNeedsQuote(const z: AnsiString): Boolean;
{ Mirrors qrf_need_quote — quote if empty, starts with non-alpha/_, or
  contains anything other than [A-Za-z0-9_].  No keyword check (upstream
  qrf_need_quote also skips keywords; quoting a keyword identifier is
  always safe). }
var
  i: SizeInt;
  c: AnsiChar;
begin
  if Length(z) = 0 then begin Result := True; Exit; end;
  c := z[1];
  if not ((c in ['A'..'Z', 'a'..'z', '_'])) then begin Result := True; Exit; end;
  for i := 2 to Length(z) do begin
    c := z[i];
    if not (c in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then begin
      Result := True; Exit;
    end;
  end;
  Result := False;
end;

function qrfEscapeCtrl(const z: AnsiString): AnsiString;
{ Mirror qrf.c qrfEscape() with eEsc=QRF_ESC_Ascii: replace control bytes
  c<=0x1f with ^X (where X=c+0x40), except \t, \n, and \r when followed by
  \n (the latter to keep CRLF runs intact).  Pass-through otherwise. }
var
  i, n: SizeInt;
  c: Byte;
  needs: Boolean;
  sb: AnsiString;
begin
  needs := False;
  n := Length(z);
  for i := 1 to n do begin
    c := Byte(z[i]);
    if (c <= $1f) and (c <> 9) and (c <> 10)
       and not ((c = 13) and (i < n) and (z[i+1] = #10))
    then begin needs := True; Break; end;
  end;
  if not needs then begin Result := z; Exit; end;
  sb := '';
  for i := 1 to n do begin
    c := Byte(z[i]);
    if (c <= $1f) and (c <> 9) and (c <> 10)
       and not ((c = 13) and (i < n) and (z[i+1] = #10))
    then begin
      sb := sb + '^' + Chr(c + $40);
    end else
      sb := sb + z[i];
  end;
  Result := sb;
end;

procedure outputSqlIdent(const z: AnsiString);
var i: SizeInt;
begin
  if not identNeedsQuote(z) then begin Write(z); Exit; end;
  Write('"');
  for i := 1 to Length(z) do begin
    if z[i] = '"' then Write('""') else Write(z[i]);
  end;
  Write('"');
end;

procedure outputCsvField(const z: AnsiString; const sep: AnsiString);
{ Mirror QRF_TEXT_Csv: quote with double-quotes if the field contains any
  byte from qrfCsvQuote (control bytes, ", and >=0x7f), embeds the column
  separator, etc.  Embedded quotes are doubled.  Then qrfEscape applies
  ^X for control bytes (except \t/\n/\r\n).  We fold the two passes:
  decide quote on raw bytes, then iterate with the same escape rules. }
var
  needQuote: Boolean;
  i, n: SizeInt;
  c: Byte;
begin
  needQuote := False;
  n := Length(z);
  for i := 1 to n do begin
    c := Byte(z[i]);
    if (c <= $1f) or (c = Byte('"')) or (c >= $7f) then begin
      needQuote := True;
      Break;
    end;
  end;
  if not needQuote and (Length(sep) > 0) and (Pos(sep, z) > 0) then
    needQuote := True;
  if not needQuote then begin
    Write(qrfEscapeCtrl(z));
    Exit;
  end;
  Write('"');
  for i := 1 to n do begin
    c := Byte(z[i]);
    if (c <= $1f) and (c <> 9) and (c <> 10)
       and not ((c = 13) and (i < n) and (z[i+1] = #10))
    then begin
      Write('^'); Write(Chr(c + $40));
    end else if z[i] = '"' then
      Write('""')
    else
      Write(z[i]);
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

function cEscapeStr(const z: AnsiString): AnsiString;
{ output_c_string body as a string (shell.c.in:2062..2103).  Wraps in
  double quotes; escapes \t \n \r \f \" \\ ; non-printable bytes as
  \ooo octal. }
var
  i: SizeInt;
  b: Byte;
begin
  Result := '"';
  for i := 1 to Length(z) do begin
    b := Byte(z[i]);
    case z[i] of
      '"', '\': Result := Result + '\' + z[i];
      #9:  Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if (b < 32) or (b = 127) then
        Result := Result + '\' +
          AnsiChar(Chr(48 + ((b shr 6) and 3))) +
          AnsiChar(Chr(48 + ((b shr 3) and 7))) +
          AnsiChar(Chr(48 + (b and 7)))
      else
        Result := Result + z[i];
    end;
  end;
  Result := Result + '"';
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
    rs.insertTab := 'tab';
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
      { Upstream renders HTML one element per line, omitting closing
        </TH> / </TD> tags (HTML5 permits this and matches shell.c.in). }
      begin
        WriteLn('<TR>');
        for i := 0 to rs.nCol - 1 do begin
          Write('<TH>'); outputHtmlString(colNameStr(pStmt, i)); WriteLn;
        end;
        WriteLn('</TR>');
      end;
    MODE_Quote:
      { Upstream qrf.c emits each title cell as a single-quoted SQL
        literal separated by zColSep, then zRowSep. }
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(rs.zColSep);
          outputSqlQuoted(colNameStr(pStmt, i));
        end;
        Write(rs.zRowSep);
      end;
    MODE_Tcl:
      { Upstream MODE_Tcl emits headers through outputCString
        regardless of type. }
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(rs.zColSep);
          outputCString(colNameStr(pStmt, i));
        end;
        Write(rs.zRowSep);
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
      { Upstream (shell.c.in aModeInfo[line]): eCSep=13 (": "), one column
        per line, blank line BETWEEN records (not after the last).  No
        leading padding — column-name flush left, then ": ", then value. }
      begin
        if rs.rowsEmitted > 0 then WriteLn;
        for i := 0 to rs.nCol - 1 do begin
          z := colTextStr(pStmt, i, isNull);
          Write(colNameStr(pStmt, i));
          Write(': ');
          if isNull then Write(rs.zNull) else Write(qrfEscapeCtrl(z));
          WriteLn;
        end;
      end;

    MODE_List, MODE_Tabs, MODE_Ascii:
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(rs.zColSep);
          z := colTextStr(pStmt, i, isNull);
          if isNull then Write(rs.zNull) else Write(qrfEscapeCtrl(z));
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
        Write('INSERT INTO ');
        if identNeedsQuote(rs.insertTab) then begin
          Write('"');
          for i := 1 to Length(rs.insertTab) do begin
            if rs.insertTab[i] = '"' then Write('""') else Write(rs.insertTab[i]);
          end;
          Write('"');
        end else
          Write(rs.insertTab);
        if rs.headersOn then begin
          for i := 0 to rs.nCol - 1 do begin
            if i = 0 then Write('(') else Write(',');
            outputSqlIdent(colNameStr(pStmt, i));
          end;
          Write(')');
        end;
        Write(' VALUES(');
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
      { Upstream emits `[{...},\n{...}]` — `[` immediately followed by the
        first object on the same line, `,\n` between rows, no newline
        before the closing `]`. }
      begin
        if rs.rowsEmitted = 0 then
          Write('[')
        else begin
          Write(',');
          WriteLn;
        end;
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
      { Upstream MODE_Tcl: integers and floats emit raw, NULL emits zNull
        verbatim (no C-quoting — matches qrf.c:1197..1199 which calls
        sqlite3_str_appendall on zNull without encoding), text/blob through
        the C-style escape vocabulary. }
      begin
        for i := 0 to rs.nCol - 1 do begin
          if i > 0 then Write(rs.zColSep);
          ty := sqlite3_column_type(pStmt, i);
          case ty of
            SQLITE_NULL:    Write(rs.zNull);
            SQLITE_INTEGER: Write(IntToStr(sqlite3_column_int64(pStmt, i)));
            SQLITE_FLOAT:   Write(FloatToStr(sqlite3_column_double(pStmt, i)));
          else
            z := colTextStr(pStmt, i, isNull);
            outputCString(z);
          end;
        end;
        Write(rs.zRowSep);
      end;

    MODE_Html:
      { Upstream qrf.c:2766..2769 unconditionally sets p->spec.zNull = "null"
        for QRF_STYLE_Html, overriding any user-configured nullvalue.  Mirror
        that here — the literal text 'null' regardless of rs.zNull. }
      begin
        WriteLn('<TR>');
        for i := 0 to rs.nCol - 1 do begin
          Write('<TD>');
          z := colTextStr(pStmt, i, isNull);
          if isNull then Write('null') else outputHtmlString(z);
          WriteLn;
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
      if rs.rowsEmitted > 0 then WriteLn(']');
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
  if isNull then Result := zNull else Result := qrfEscapeCtrl(z);
end;

procedure emitColumnar(var rs: TRenderState; pStmt: PVdbe; firstRow: AnsiString);
{ Buffer all remaining rows (`firstRow` already consumed via column-text
  capture) and emit per-mode in MODE_Column / MODE_Table / MODE_Box.
  `firstRow` is unused — kept for signature symmetry; the caller passes
  '' and we read the current row from pStmt before stepping further.

  Per-cell alignment follows upstream qrf.c:1995/1514: each cell remembers
  its own SQLite type and renders right-aligned when INTEGER or FLOAT,
  left-aligned otherwise.  A negative `.width N` overrides at the column
  level and forces right-align regardless of types (qrf.c:1696). }
var
  matrix:    array of array of AnsiString;
  cellRight: array of array of Boolean;
  headers:   array of AnsiString;
  widths:    array of i32;
  forceRight: array of Boolean;
  ty: i32;
  i, c, w, rc, nCol: i32;
  nRowBuf: i32;
  rcStep: i32;
  isBox, isTable, isCol, isMd: Boolean;
  glyphTL, glyphTR, glyphBL, glyphBR: AnsiString;
  glyphHB, glyphVB, glyphCx, glyphTU, glyphTD, glyphTL2, glyphTR2: AnsiString;
  glyphHdrHB, glyphHdrCx: AnsiString;
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

  SetLength(headers,    nCol);
  SetLength(widths,     nCol);
  SetLength(forceRight, nCol);
  for i := 0 to nCol - 1 do begin
    headers[i]    := colNameStr(pStmt, i);
    widths[i]     := utf8DispWidth(headers[i]);
    forceRight[i] := False;
  end;

  { .width is applied below, after row capture, so a negative .width can
    override the type-derived alignment without being clobbered by it. }

  { Buffer rows.  Start with the row already at pStmt (caller stepped to
    SQLITE_ROW once, then handed off without emitting). }
  nRowBuf := 0;
  SetLength(matrix,    16);
  SetLength(cellRight, 16);
  SetLength(matrix[0],    nCol);
  SetLength(cellRight[0], nCol);
  for c := 0 to nCol - 1 do begin
    matrix[0, c] := colCellText(pStmt, c, rs.zNull);
    w := utf8DispWidth(matrix[0, c]);
    if w > widths[c] then widths[c] := w;
    ty := sqlite3_column_type(pStmt, c);
    cellRight[0, c] := (ty = SQLITE_INTEGER) or (ty = SQLITE_FLOAT);
  end;
  nRowBuf := 1;

  while True do begin
    rcStep := sqlite3_step(pStmt);
    if rcStep <> SQLITE_ROW then Break;
    if nRowBuf >= Length(matrix) then begin
      SetLength(matrix,    Length(matrix)    * 2);
      SetLength(cellRight, Length(cellRight) * 2);
    end;
    SetLength(matrix[nRowBuf],    nCol);
    SetLength(cellRight[nRowBuf], nCol);
    for c := 0 to nCol - 1 do begin
      matrix[nRowBuf, c] := colCellText(pStmt, c, rs.zNull);
      w := utf8DispWidth(matrix[nRowBuf, c]);
      if w > widths[c] then widths[c] := w;
      ty := sqlite3_column_type(pStmt, c);
      cellRight[nRowBuf, c] := (ty = SQLITE_INTEGER) or (ty = SQLITE_FLOAT);
    end;
    Inc(nRowBuf);
  end;
  rs.lastStepRc := rcStep;

  { User-supplied minimum widths via .width.  C uses the absolute value
    for the cell padding; a negative .width forces right-align for every
    cell in the column regardless of type (qrf.c:1696). }
  for i := 0 to nCol - 1 do
    if (rs.p^.mode.spec.aWidth <> nil) and (i < rs.p^.mode.spec.nWidth) then begin
      w := Abs(rs.p^.mode.spec.aWidth[i]);
      if w > widths[i] then widths[i] := w;
      if rs.p^.mode.spec.aWidth[i] < 0 then forceRight[i] := True;
    end;

  { Glyphs. }
  if isBox then begin
    { Upstream qrf.c: top corners + below-header separator use rounded
      glyphs (BOX_R23/R34/R12/R14) and the title/data divider switches to
      doubled lines (DBL_24 / DBL_123 / DBL_1234 / DBL_134). }
    glyphTL  := #$E2#$95#$AD; { ╭  BOX_R23 }
    glyphTR  := #$E2#$95#$AE; { ╮  BOX_R34 }
    glyphBL  := #$E2#$95#$B0; { ╰  BOX_R12 }
    glyphBR  := #$E2#$95#$AF; { ╯  BOX_R14 }
    glyphHB  := #$E2#$94#$80; { ─ }
    glyphVB  := #$E2#$94#$82; { │ }
    glyphCx  := #$E2#$94#$BC; { ┼ }
    glyphTU  := #$E2#$94#$B4; { ┴ }
    glyphTD  := #$E2#$94#$AC; { ┬ }
    glyphTL2 := #$E2#$95#$9E; { ╞  DBL_123 }
    glyphTR2 := #$E2#$95#$A1; { ╡  DBL_134 }
    glyphHdrHB := #$E2#$95#$90; { ═  DBL_24 }
    glyphHdrCx := #$E2#$95#$AA; { ╪  DBL_1234 }
  end else if isTable then begin
    glyphTL := '+'; glyphTR := '+'; glyphBL := '+'; glyphBR := '+';
    glyphHB := '-'; glyphVB := '|';
    glyphCx := '+'; glyphTU := '+'; glyphTD := '+';
    glyphTL2 := '+'; glyphTR2 := '+';
    glyphHdrHB := '-'; glyphHdrCx := '+';
  end else if isMd then begin
    { Markdown — pipe borders, no top/bottom rules; the only horizontal
      rule sits between header and rows and uses '-'. }
    glyphTL := ''; glyphTR := ''; glyphBL := ''; glyphBR := '';
    glyphHB := '-'; glyphVB := '|';
    glyphCx := '|'; glyphTU := ''; glyphTD := '';
    glyphTL2 := '|'; glyphTR2 := '|';
    glyphHdrHB := '-'; glyphHdrCx := '|';
  end else begin
    { Column mode — no borders. }
    glyphTL := ''; glyphTR := ''; glyphBL := ''; glyphBR := '';
    glyphHB := '-'; glyphVB := '';
    glyphCx := ''; glyphTU := ''; glyphTD := '';
    glyphTL2 := ''; glyphTR2 := '';
    glyphHdrHB := '-'; glyphHdrCx := '';
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
      if c > 0 then sb := sb + glyphHdrCx;
      for i := 0 to widths[c] + 1 do sb := sb + glyphHdrHB;
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
      { MODE_Column header row.  Upstream qrf.c (~2014) sets eTitleAlign
        to QRF_ALIGN_Center for the title row, then qrfRTrim strips
        trailing whitespace before the row separator. }
      for c := 0 to nCol - 1 do begin
        if c > 0 then Write('  ');
        w := widths[c] - utf8DispWidth(headers[c]);
        if w > 0 then Write(StringOfChar(' ', w div 2));
        Write(headers[c]);
        if (c < nCol - 1) and (w > 0) then
          Write(StringOfChar(' ', w - (w div 2)));
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
        w := widths[c] - utf8DispWidth(matrix[rc, c]);
        if (cellRight[rc, c] or forceRight[c]) and (w > 0) then
          Write(StringOfChar(' ', w));
        Write(matrix[rc, c]);
        if (not (cellRight[rc, c] or forceRight[c])) and (w > 0) then
          Write(StringOfChar(' ', w));
        Write(' ');
      end;
      WriteLn(glyphVB);
    end else begin
      { MODE_Column data row.  Upstream qrfRTrim trims trailing
        whitespace on every Column row.  Build the full row into sb,
        then RTrim spaces before emit so all-NULL rows collapse to an
        empty line and trailing-NULL cells don't leak inter-column
        padding (qrf.c:1247 qrfRTrim + 2247). }
      sb := '';
      for c := 0 to nCol - 1 do begin
        if c > 0 then sb := sb + '  ';
        w := widths[c] - utf8DispWidth(matrix[rc, c]);
        if (cellRight[rc, c] or forceRight[c]) and (w > 0) then
          sb := sb + StringOfChar(' ', w);
        sb := sb + matrix[rc, c];
        if (not (cellRight[rc, c] or forceRight[c]))
           and (c < nCol - 1) and (w > 0) then
          sb := sb + StringOfChar(' ', w);
      end;
      while (Length(sb) > 0) and (sb[Length(sb)] = ' ') do
        SetLength(sb, Length(sb) - 1);
      WriteLn(sb);
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
procedure displayScanstats(p: PShellState; pStmt: Pointer); forward;
procedure shellBeginTimer(p: PShellState); forward;
procedure shellEndTimer(p: PShellState); forward;

{ Format the error prefix exactly as upstream's runOneSqlLine
  (shell.c.in:35797..35810).  zErrorType is "Error" / "Parse error" /
  "Runtime error"; zSrc is the current input source name (e.g.
  "<stdin>" / "cmdline" / a filename).  Interactive stdin emits just
  "<type>:"; everything else gets a "near line N" / "in N command line
  argument" / "near line N of FILE" qualifier. }
{ Mirrors `%r` in sqlite3_snprintf — the upstream ordinal-suffix
  formatter used by save_err_msg.  1->1st, 2->2nd, 3->3rd, 4..20->th,
  21->st, 22->nd, 23->rd, 24..30->th, ... }
function ordinalSuffix(n: i64): AnsiString;
var t: i64;
begin
  if n < 0 then n := -n;
  t := n mod 100;
  if (t >= 11) and (t <= 13) then begin
    Result := IntToStr(n) + 'th';
    Exit;
  end;
  case n mod 10 of
    1: Result := IntToStr(n) + 'st';
    2: Result := IntToStr(n) + 'nd';
    3: Result := IntToStr(n) + 'rd';
  else
    Result := IntToStr(n) + 'th';
  end;
end;

{ shell_error_context — shell.c.in:2603..2635.  Returns a two-line
  ASCII context block pointing at the offending token in zSql, using
  sqlite3_error_offset(db) as the byte offset.  Returns '' if no
  meaningful offset is available.  The returned string starts with a
  newline, so callers append it directly after the one-line errmsg. }
function shellErrorContext(const zSql: AnsiString; db: Psqlite3): AnsiString;
var
  iOffset: i32;
  zCode: AnsiString;
  pBase: PAnsiChar;
  remOff, len: Integer;
  i: Integer;
  pad: AnsiString;
begin
  Result := '';
  if (db = nil) or (zSql = '') then Exit;
  iOffset := sqlite3_error_offset(db);
  if (iOffset < 0) or (iOffset >= Length(zSql)) then Exit;
  pBase := PAnsiChar(zSql);
  remOff := iOffset;
  { Walk forward by single bytes (skipping UTF-8 continuation bytes
    that follow), keeping iOffset aligned to the visible offset of
    the token within the displayed window.  Mirrors shell.c:2616..2620. }
  while remOff > 50 do begin
    Dec(remOff);
    Inc(pBase);
    while (Byte(pBase^) and $C0) = $80 do begin
      Inc(pBase);
      Dec(remOff);
    end;
  end;
  len := StrLen(pBase);
  if len > 78 then begin
    len := 78;
    while (len > 0) and ((Byte(pBase[len]) and $C0) = $80) do Dec(len);
  end;
  SetLength(zCode, len);
  if len > 0 then Move(pBase^, zCode[1], len);
  { Replace whitespace bytes with regular space so the context line is
    a single visible row.  Mirrors shell.c:2628 IsSpace -> ' '. }
  for i := 1 to len do
    if zCode[i] in [#9, #10, #11, #12, #13] then zCode[i] := ' ';
  if remOff < 25 then begin
    SetLength(pad, remOff);
    if remOff > 0 then FillChar(pad[1], remOff, ' ');
    Result := #10 + '  ' + zCode + #10 + '  ' + pad + '^--- error here';
  end else begin
    SetLength(pad, remOff - 14);
    if (remOff - 14) > 0 then FillChar(pad[1], remOff - 14, ' ');
    Result := #10 + '  ' + zCode + #10 + '  ' + pad + 'error here ---^';
  end;
end;

function shellErrPrefix(const zErrorType, zSrc: AnsiString;
                        lineno: i64): AnsiString;
begin
  if (zSrc <> '') or (stdin_is_interactive = 0) then begin
    if zSrc = 'cmdline' then
      Result := Format('%s in %s command line argument:',
                       [string(zErrorType), string(ordinalSuffix(lineno))])
    else if zSrc = '<stdin>' then
      Result := Format('%s near line %d:',
                       [string(zErrorType), Int64(lineno)])
    else
      Result := Format('%s near line %d of %s:',
                       [string(zErrorType), Int64(lineno), string(zSrc)]);
  end else
    Result := Format('%s:', [string(zErrorType)]);
end;

{ bindPreparedStmt — shell.c.in:2993..3075 bind_prepared_stmt.
  Walk pStmt's parameter slots and bind from temp.sqlite_parameters
  (populated by `.parameter set`).  Falls back to $int_N / $text_X
  literal-name encoding, and $TIMER → prevTimer.  Slots with no
  match bind NULL.  No-op if pStmt has no parameters or the
  parameter table does not exist. }
procedure bindPreparedStmt(p: PShellState; pStmt: PVdbe);
var
  nVar, i, rc: i32;
  pQ: PVdbe;
  pzTail: PAnsiChar;
  zVar: PAnsiChar;
  zNum: array[0..31] of AnsiChar;
  zKey: AnsiString;
  zLit: AnsiString;
  iVal: i32;
  szVar: SizeInt;
begin
  if pStmt = nil then Exit;
  nVar := sqlite3_bind_parameter_count(pStmt);
  if nVar = 0 then Exit;
  pQ := nil;
  rc := SQLITE_OK;
  if sqlite3_table_column_metadata(p^.db, 'TEMP', 'sqlite_parameters',
       'key', nil, nil, nil, nil, nil) <> SQLITE_OK then
    rc := SQLITE_NOTFOUND
  else
    rc := sqlite3_prepare_v2(p^.db,
        'SELECT value FROM temp.sqlite_parameters WHERE key=?1',
        -1, @pQ, @pzTail);
  for i := 1 to nVar do begin
    zVar := sqlite3_bind_parameter_name(pStmt, i);
    if zVar = nil then begin
      StrPCopy(zNum, '?' + IntToStr(i));
      zVar := zNum;
    end;
    if (rc = SQLITE_OK) and (pQ <> nil) then begin
      sqlite3_reset(pQ);
      zKey := AnsiString(zVar);
      sqlite3_bind_text(pQ, 1, PAnsiChar(zKey), -1, SQLITE_STATIC);
      if sqlite3_step(pQ) = SQLITE_ROW then begin
        sqlite3_bind_value(pStmt, i, sqlite3_column_value(pQ, 0));
        Continue;
      end;
    end;
    szVar := StrLen(zVar);
    if (szVar > 5) and (StrLComp(zVar, '$int_', 5) = 0) then begin
      Val(string(AnsiString(zVar + 5)), iVal, rc);
      if rc <> 0 then iVal := 0;
      sqlite3_bind_int(pStmt, i, iVal);
    end else if (szVar > 6) and (StrLComp(zVar, '$text_', 6) = 0) then begin
      zLit := AnsiString(zVar + 6);
      sqlite3_bind_text(pStmt, i, PAnsiChar(zLit), -1, SQLITE_TRANSIENT);
    end else if StrComp(zVar, '$TIMER') = 0 then begin
      sqlite3_bind_double(pStmt, i, p^.prevTimer);
    end else begin
      sqlite3_bind_null(pStmt, i);
    end;
  end;
  if pQ <> nil then sqlite3_finalize(pQ);
end;

{ Forward declarations for expert routing inside runOneSqlLine.  Bodies
  live with cmdExpert further down (~line 6735). }
function expertHandleSQL(p: PShellState; zSql: PAnsiChar;
                         pzErr: PPAnsiChar): i32; forward;
function expertFinish(p: PShellState; bCancel: i32;
                      pzErr: PPAnsiChar): i32; forward;

function runOneSqlLine(p: PShellState; const zSql: AnsiString;
                       const zSrc: AnsiString; lineno: i64): i32;
{ Hold zSql as a single immutable AnsiString and walk pCursor through its
  buffer.  Earlier cuts reassigned `zCur := StrPas(pzTail)` between
  iterations, but FPC's AnsiString management was occasionally producing
  a single-byte corruption at the new buffer's first non-leading offset
  on the third+ iteration — multi-statement command-line input lost
  characters past ~2 statements (10.1.bug.3).  Anchoring to the original
  buffer avoids all reallocations. }
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
  pBase, pCursor, pEnd: PAnsiChar;
  zStmtSql: AnsiString;
  zCtx: AnsiString;
var
  rcExp, rcExp2: i32;
  zExpErr: PAnsiChar;
begin
  Result := 0;
  if p^.db = nil then openDb(p, 0);
  if Length(zSql) = 0 then Exit;
  { shell.c.in:3268 — when .expert is active, route the current SQL
    through the expert engine and immediately finalize/report. }
  if p^.expertPtr <> nil then begin
    zExpErr := nil;
    rcExp := expertHandleSQL(p, PAnsiChar(zSql), @zExpErr);
    if rcExp <> SQLITE_OK then rcExp2 := 1 else rcExp2 := 0;
    rcExp := expertFinish(p, rcExp2, @zExpErr);
    if (rcExp <> SQLITE_OK) or (rcExp2 <> 0) then begin
      if zExpErr <> nil then
        shellEPutZ('Error: ' + AnsiString(zExpErr) + sLineBreak);
      Inc(Result);
    end;
    if zExpErr <> nil then sqlite3_free(zExpErr);
    Exit;
  end;
  pBase := PAnsiChar(zSql);
  pEnd := pBase + Length(zSql);
  pCursor := pBase;
  while (pCursor <> nil) and (pCursor < pEnd) and (pCursor^ <> #0) do begin
    pStmt := nil;
    pzTail := nil;
    zStmtSql := AnsiString(pCursor);
    rc := sqlite3_prepare_v2(p^.db, pCursor, -1, @pStmt, @pzTail);
    if rc <> SQLITE_OK then begin
      zCtx := shellErrorContext(zStmtSql, p^.db);
      if rc > 1 then
        shellEPutZ(Format('%s %s (%d)%s'#10,
          [string(shellErrPrefix('Parse error', zSrc, lineno)),
           AnsiString(sqlite3_errmsg(p^.db)),
           Integer(rc),
           string(zCtx)]))
      else
        shellEPutZ(Format('%s %s%s'#10,
          [string(shellErrPrefix('Parse error', zSrc, lineno)),
           AnsiString(sqlite3_errmsg(p^.db)),
           string(zCtx)]));
      Inc(Result);
      Exit;
    end;
    if pStmt = nil then begin
      { Empty statement (whitespace, comment) — advance to tail and continue. }
      if (pzTail = nil) or (pzTail = pCursor) then Exit;
      pCursor := pzTail;
      Continue;
    end;
    p^.pStmt := pStmt;
    bindPreparedStmt(p, pStmt);
    shellBeginTimer(p);
    stepAndRender(p, pStmt);
    shellEndTimer(p);
    if p^.statsOn <> 0 then displayStats(p, 0);
    if p^.mode.scanstatsOn <> 0 then displayScanstats(p, pStmt);
    p^.pStmt := nil;
    rc := sqlite3_finalize(pStmt);
    if (rc <> SQLITE_OK) and (rc <> SQLITE_DONE) then begin
      { Mirror shell.c.in:12330..12333: when shell_exec's per-row
        QRF formatter returns an error to *pzErrMsg without a
        "stepping, " or "in prepare, " prefix, runOneSqlLine falls
        through to the else branch with zErrorType="Error" and no
        trailing "(rc)" suffix.  In the Pascal port we never compose
        a "stepping, " prefix (stepAndRender writes rows directly),
        so every step-time error lands here.  zSql is not appended
        as caret context — upstream passes zSql=NULL for stepping
        errors. }
      shellEPutZ(Format('%s %s'#10,
        [string(shellErrPrefix('Error', zSrc, lineno)),
         AnsiString(sqlite3_errmsg(p^.db))]));
      Inc(Result);
    end;
    if (pzTail = nil) or (pzTail = pCursor) then Break;
    pCursor := pzTail;
  end;
  { shell.c.in:12356..12361 — emit per-SQL `.changes` summary once at
    the end of runOneSqlLine if SHFLG_CountChanges set and no error. }
  if (Result = 0) and ((p^.shellFlgs and SHFLG_CountChanges) <> 0) then
    shellSPutZ(Format('changes: %d   total_changes: %d'#10,
      [sqlite3_changes64(p^.db), sqlite3_total_changes64(p^.db)]));
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
{ Per-line offset capture for shellDotError caret rendering.  We hold a
  static 0-based offset array sized to the same upper bound as the args[]
  buffer in doMetaCommand (16 slots); offsets are 1-based into zLine. }
const
  SHELL_MAX_DOT_ARGS = 16;
var
  gDotOfst: array[0 .. SHELL_MAX_DOT_ARGS - 1] of i32;
  gDotOrig: AnsiString;  { last zLine fed through splitDotArgs }

procedure splitDotArgs(const zLine: AnsiString; out args: array of AnsiString;
                       out nArg: SizeInt);
var i, n, k, iStart: SizeInt;
    quote: AnsiChar;
    cur: AnsiString;
    trimmed: AnsiString;
begin
  nArg := 0;
  { Mirror parseDotCmdArgs (shell.c.in:8925..8973): trim trailing whitespace
    and a single trailing ';' so gDotOrig matches p->dot.zOrig byte-for-byte. }
  trimmed := zLine;
  while (Length(trimmed) > 0) and (trimmed[Length(trimmed)] in [' ', #9, #10, #13]) do
    SetLength(trimmed, Length(trimmed) - 1);
  if (Length(trimmed) > 0) and (trimmed[Length(trimmed)] = ';') then begin
    SetLength(trimmed, Length(trimmed) - 1);
    while (Length(trimmed) > 0) and (trimmed[Length(trimmed)] in [' ', #9, #10, #13]) do
      SetLength(trimmed, Length(trimmed) - 1);
  end;
  gDotOrig := trimmed;
  FillChar(gDotOfst, SizeOf(gDotOfst), 0);
  n := Length(trimmed);
  i := 1;
  { Upstream parser starts at h=1 (skips the leading '.') and treats the
    command name as azArg[0]; we expose args[] without the cmd-name slot but
    record offsets including it — gDotOfst[0]=cmd-name offset, gDotOfst[1+k]
    =arg k offset, so iArg in shellDotError matches the C semantics. }
  if (i <= n) and (trimmed[i] = '.') then Inc(i);
  { Capture the cmd-name offset into gDotOfst[0]. }
  while (i <= n) and (trimmed[i] in [' ', #9]) do Inc(i);
  if i <= n then gDotOfst[0] := i32(i);
  while (i <= n) and not (trimmed[i] in [' ', #9]) do Inc(i);
  while i <= n do begin
    while (i <= n) and (trimmed[i] in [' ', #9]) do Inc(i);
    if i > n then Break;
    iStart := i;
    cur := '';
    if trimmed[i] in ['''', '"'] then begin
      quote := trimmed[i];
      Inc(i);
      iStart := i;  { aiOfst points past opening quote (shell.c.in:8952) }
      while (i <= n) and (trimmed[i] <> quote) do begin
        if (trimmed[i] = '\') and (i < n) then begin
          Inc(i);
          case trimmed[i] of
            'n': cur := cur + #10;
            't': cur := cur + #9;
            'r': cur := cur + #13;
            '\': cur := cur + '\';
            '''': cur := cur + '''';
            '"': cur := cur + '"';
          else
            cur := cur + trimmed[i];
          end;
          Inc(i);
        end else begin
          cur := cur + trimmed[i];
          Inc(i);
        end;
      end;
      if (i <= n) and (trimmed[i] = quote) then Inc(i);
    end else begin
      while (i <= n) and not (trimmed[i] in [' ', #9]) do begin
        cur := cur + trimmed[i];
        Inc(i);
      end;
    end;
    k := nArg;
    if k <= High(args) then begin
      args[k] := cur;
      { gDotOfst[0] holds the cmd-name offset; arg k goes into slot k+1. }
      if (k + 1) < SHELL_MAX_DOT_ARGS then gDotOfst[k + 1] := i32(iStart);
      Inc(nArg);
    end;
  end;
end;

{ shellErrorLocation — shell.c.in:1779.  Format the "<file>:<line>:" or
  "line <n>:" prefix used by failIfSafeMode / dotCmdError.  Returns a
  newly built AnsiString. }
function shellErrorLocation(p: PShellState): AnsiString;
begin
  if p^.zErrPrefix <> nil then
    Result := AnsiString(p^.zErrPrefix)
  else if (p^.zInFile = nil) or (StrPas(p^.zInFile) = '<stdin>') then
    Result := Format('line %d:', [p^.lineno])
  else
    Result := Format('%s:%d:', [StrPas(p^.zInFile), p^.lineno]);
end;

{ shellDotError — port of dotCmdError (shell.c.in:1815..1844).  Emits

    <loc> <zLine>\n
    <loc> <spaces>caret-marker <zBrief> ---^\n      (caret right of brief)
        or
    <loc> <spaces>^--- <zBrief>\n                   (caret left of brief)

  followed by an optional <loc> <zDetail>\n line.  The caret block is
  only emitted when zBrief<>'' and we have a valid iArg with a captured
  source offset; otherwise we fall back to the plain "Error: <zDetail>\n"
  form used pre-10.1.40.a.  Routes through gDotOrig/gDotOfst populated
  by splitDotArgs on each dispatch. }
procedure shellDotError(p: PShellState; iArg: i32;
                        const zBrief, zDetail: AnsiString);
var
  zLoc: AnsiString;
  iOfst, nPrompt: i32;
  pad: AnsiString;
begin
  zLoc := shellErrorLocation(p);
  if (zBrief <> '') and (iArg >= 0) and (iArg < SHELL_MAX_DOT_ARGS)
     and (gDotOrig <> '') and (gDotOfst[iArg] > 0) then
  begin
    iOfst := gDotOfst[iArg] - 1;   { 0-based to match C aiOfst[] }
    nPrompt := i32(Length(zBrief)) + 5;
    shellEPutZ(zLoc + ' ' + gDotOrig + #10);
    if iOfst > nPrompt then begin
      pad := StringOfChar(' ', 1 + iOfst - nPrompt);
      shellEPutZ(zLoc + ' ' + pad + zBrief + ' ---^'#10);
    end else begin
      pad := StringOfChar(' ', iOfst);
      shellEPutZ(zLoc + ' ' + pad + '^--- ' + zBrief + #10);
    end;
  end;
  if zDetail <> '' then
    shellEPutZ(zLoc + ' ' + zDetail + #10);
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

function cmdStats(p: PShellState; const args: array of AnsiString; nArg: SizeInt): i32;
{ shell.c.in:11324..11339 .stats arm.  Bare `.stats` invokes
  display_stats() — emits memory/lookaside counters.  One arg flips
  ShellState.statsOn (stmt=2, vmstep=3, else booleanValue).  Anything
  else: usage on stderr with rc=1. }
var
  s: AnsiString;
begin
  Result := 0;
  if nArg = 0 then begin
    displayStats(p, 0);
    Exit;
  end;
  if nArg = 1 then begin
    s := args[0];
    if      s = 'stmt'   then p^.statsOn := 2
    else if s = 'vmstep' then p^.statsOn := 3
    else                      p^.statsOn := u32(parseOnOff(s, 0));
    Exit;
  end;
  shellEPutZ('Usage: .stats ?on|off|stmt|vmstep?'#10);
  Result := 1;
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
{ Faithful port of sql_trace_callback (shell.c.in:4886..4940).
  STMT/ROW: emit "<SQL>;\n" with trailing semicolons stripped, one re-added.
  PROFILE : "<SQL>; -- <ns> ns\n"  (timing — non-deterministic across runs).
  CLOSE   : "-- closing database connection\n". }
var
  zSql, zExpanded: PAnsiChar;
  zOut: AnsiString;
  nSql: SizeInt;
  ns: Int64;
begin
  Result := 0;
  if traceSink = 0 then Exit;
  if traceType = u32(SQLITE_TRACE_CLOSE) then begin
    traceWrite('-- closing database connection'#10);
    Exit;
  end;
  zOut := '';
  if (traceType <> u32(SQLITE_TRACE_ROW)) and (pX <> nil)
     and (PAnsiChar(pX)^ = '-') then
    zOut := AnsiString(PAnsiChar(pX))
  else if traceFmt = 1 then begin
    zExpanded := sqlite3_expanded_sql(pP);
    if zExpanded <> nil then begin
      zOut := AnsiString(zExpanded);
      sqlite3_free(zExpanded);
    end else begin
      zSql := sqlite3_sql(pP);
      if zSql <> nil then zOut := AnsiString(zSql);
    end;
  end else begin
    zSql := sqlite3_sql(pP);
    if zSql <> nil then zOut := AnsiString(zSql);
  end;
  if zOut = '' then Exit;
  nSql := Length(zOut);
  while (nSql > 0) and (zOut[nSql] = ';') do Dec(nSql);
  SetLength(zOut, nSql);
  case traceType of
    u32(SQLITE_TRACE_STMT), u32(SQLITE_TRACE_ROW):
      traceWrite(zOut + ';'#10);
    u32(SQLITE_TRACE_PROFILE): begin
      if pX <> nil then ns := PInt64(pX)^ else ns := 0;
      traceWrite(zOut + Format('; -- %d ns'#10, [ns]));
    end;
  end;
end;

function cmdTrace(p: PShellState; const args: array of AnsiString; nArg: SizeInt): i32;
var
  i: SizeInt;
  mask: u32;
  s: AnsiString;
  zFile: AnsiString;
  newSink: i32;
begin
  Result := 0;
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
      shellEPutZ(Format('Unknown option "%s" on ".trace"'#10, [s]));
      Result := 1;
      Exit;
    end;
  end;
  if mask = 0 then mask := u32(SQLITE_TRACE_STMT);
  traceCloseSink;
  case newSink of
    { No positional argument → leave trace off (mirrors output_file_open
      with no file, traceOut stays NULL, sqlite3_trace_v2(...,0,0,0)). }
    0: begin
      sqlite3_trace_v2(p^.db, 0, nil, nil);
      Exit;
    end;
    1: traceSink := 1;
    2: traceSink := 2;
    3: begin
      AssignFile(traceFile, zFile);
      {$I-} Rewrite(traceFile); {$I+}
      if IOResult <> 0 then begin
        shellEPutZ(Format('Error: cannot open "%s"'#10, [zFile]));
        traceSink := 0;
        sqlite3_trace_v2(p^.db, 0, nil, nil);
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
  azHelp: array[0..251] of AnsiString = (
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
    { Session-extension help block is gated on SQLITE_ENABLE_SESSION
      upstream (shell.c.in:3894..3908).  The port's cmdSession is a
      "not compiled in" stub (passqlite3shell.pas:cmdSession) so we
      mirror the undefined-SESSION C build and omit the entries from
      azHelp.  Restore when the session extension lands (10.1.47). }
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

function cmdShow(p: PShellState; nArg: SizeInt): i32;
const
  azBool: array[0..3] of AnsiString = ('off', 'on', 'trigger', 'full');
var
  fn: AnsiString;
  i: SizeInt;
  widths: AnsiString;
begin
  Result := 0;
  { shell.c.in:11271..11275 — `.show` takes no arguments. }
  if nArg <> 0 then begin
    shellEPutZ('Usage: .show'#10);
    Result := 1;
    Exit;
  end;
  if p^.pAuxDb^.zDbFilename = nil then fn := '' else fn := AnsiString(p^.pAuxDb^.zDbFilename);
  shellSPutZ(Format('%12s: %s'#10, ['echo',         onOffStr((p^.mode.mFlags and MFLG_ECHO) <> 0)]));
  shellSPutZ(Format('%12s: %s'#10, ['eqp',          azBool[p^.mode.autoEQP and 3]]));
  if p^.mode.autoExplain <> 0 then
    shellSPutZ(Format('%12s: %s'#10, ['explain',    'auto']))
  else
    shellSPutZ(Format('%12s: %s'#10, ['explain',    'off']));
  shellSPutZ(Format('%12s: %s'#10, ['headers',      onOffStr(p^.mode.spec.bTitles = QRF_Yes)]));
  shellSPutZ(Format('%12s: %s'#10, ['mode',         StrPas(@aModeInfo[p^.mode.eMode].zName[0])]));
  shellSPutZ(Format('%12s: %s'#10, ['nullvalue',    cEscapeStr(specStr(p^.mode.spec.zNull))]));
  if gOutRedirected then
    shellSPutZ(Format('%12s: %s'#10, ['output', gOutCurFilename]))
  else
    shellSPutZ(Format('%12s: %s'#10, ['output', 'stdout']));
  shellSPutZ(Format('%12s: %s'#10, ['colseparator', cEscapeStr(specStr(p^.mode.spec.zColumnSep))]));
  shellSPutZ(Format('%12s: %s'#10, ['rowseparator', cEscapeStr(specStr(p^.mode.spec.zRowSep))]));
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
    zUserInsertTab := args[1];
    p^.zDestTable := PAnsiChar(zUserInsertTab);
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
{ shell.c.in:9878..9970 — list indexes, filtering system-generated
  sqlite_autoindex_* by default; --all / -a includes them.  This Pascal
  cut also accepts a table-name argument for backwards compatibility
  (the upstream form treats the trailing arg as a substring index-name
  pattern, but most call-sites pass a table name). }
var
  sql, tab: AnsiString;
  i: SizeInt;
  allFlag: Boolean;
begin
  allFlag := False;
  tab := '';
  for i := 0 to nArg - 1 do begin
    if (args[i] = '--all') or (args[i] = '-a') or (args[i] = '-all') then
      allFlag := True
    else if (Length(args[i]) > 0) and (args[i][1] = '-') then begin
      shellEPutZ(Format('Unknown option: "%s"'#10, [args[i]]));
      Exit;
    end else if tab = '' then
      tab := args[i]
    else begin
      shellEPutZ('Usage: .indexes ?-a|--all? ?TABLE?'#10);
      Exit;
    end;
  end;
  sql := 'SELECT name FROM sqlite_schema WHERE type=''index''';
  if tab <> '' then
    sql := sql + ' AND tbl_name='''
              + StringReplace(tab, '''', '''''', [rfReplaceAll]) + '''';
  if not allFlag then
    sql := sql + ' AND name NOT LIKE ''sqlite__%'' ESCAPE ''_''';
  sql := sql + ' ORDER BY 1';
  runStatementVerbose(p, sql);
end;

procedure cmdDatabases(p: PShellState);
{ shell.c.in:9242..9276 — list attached databases via PRAGMA database_list,
  then for each emit `<name>: <file> r/o|r/w[ read-txn|write-txn]`.
  Mirrors upstream byte-for-byte. }
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc, eTxn, bRdonly: i32;
  zSchema, zFile, zTxn: AnsiString;
  zSchemaP, zFileP: PAnsiChar;
  names: array of AnsiString;
  files: array of AnsiString;
  i, n: i32;
begin
  openDb(p, 0);
  if p^.db = nil then Exit;
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, 'PRAGMA database_list', -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    Exit;
  end;
  n := 0;
  SetLength(names, 8);
  SetLength(files, 8);
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    zSchemaP := PAnsiChar(sqlite3_column_text(pStmt, 1));
    zFileP   := PAnsiChar(sqlite3_column_text(pStmt, 2));
    if (zSchemaP = nil) or (zFileP = nil) then Continue;
    if n >= Length(names) then begin
      SetLength(names, Length(names) * 2);
      SetLength(files, Length(files) * 2);
    end;
    names[n] := AnsiString(zSchemaP);
    files[n] := AnsiString(zFileP);
    Inc(n);
  end;
  sqlite3_finalize(pStmt);
  for i := 0 to n - 1 do begin
    zSchema := names[i];
    zFile   := files[i];
    eTxn    := sqlite3_txn_state(p^.db, PAnsiChar(zSchema));
    bRdonly := sqlite3_db_readonly(p^.db, PAnsiChar(zSchema));
    case eTxn of
      0: zTxn := '';                   { SQLITE_TXN_NONE }
      1: zTxn := ' read-txn';          { SQLITE_TXN_READ }
    else
      zTxn := ' write-txn';            { SQLITE_TXN_WRITE }
    end;
    if Length(zFile) = 0 then zFile := '""';
    if bRdonly <> 0 then
      WriteLn(zSchema, ': ', zFile, ' r/o', zTxn)
    else
      WriteLn(zSchema, ': ', zFile, ' r/w', zTxn);
  end;
end;

function shellFmtIsSpace(c: AnsiChar): Boolean; inline;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #11) or (c = #12) or (c = #13);
end;

function shellFmtIsAlnum(c: AnsiChar): Boolean; inline;
begin
  Result := ((c >= 'A') and (c <= 'Z'))
         or ((c >= 'a') and (c <= 'z'))
         or ((c >= '0') and (c <= '9'));
end;

function shellFmtWsToEol(const z: AnsiString; iStart: SizeInt): Boolean;
{ shell.c.in:2348..2357 — true iff z[iStart..] contains only whitespace
  before the first newline / start-of-comment. }
var
  i: SizeInt;
begin
  i := iStart;
  while (i <= Length(z)) do begin
    if z[i] = #10 then Exit(True);
    if shellFmtIsSpace(z[i]) then begin Inc(i); Continue; end;
    if (z[i] = '-') and (i < Length(z)) and (z[i+1] = '-') then Exit(True);
    Exit(False);
  end;
  Result := True;
end;

function shellFmtStrnicmp(const z: AnsiString; iStart: SizeInt;
                          const zPat: AnsiString): Boolean;
var
  i: SizeInt;
  ca, cb: AnsiChar;
begin
  if iStart + Length(zPat) - 1 > Length(z) then Exit(False);
  for i := 1 to Length(zPat) do begin
    ca := z[iStart + i - 1]; cb := zPat[i];
    if (ca >= 'A') and (ca <= 'Z') then Inc(ca, 32);
    if (cb >= 'A') and (cb <= 'Z') then Inc(cb, 32);
    if ca <> cb then Exit(False);
  end;
  Result := True;
end;

function shellFormatSchemaText(const zSql: AnsiString;
                               bIndent: Boolean): AnsiString;
{ shell.c.in:2360..2484 — shell_format_schema().  Returns zSql with a
  trailing ';' when bIndent is False (or for CREATE VIEW / TRIGGER even
  when bIndent is True).  Otherwise rewrites the CREATE statement so that
  every column / WHERE-AND clause sits on its own indented line.  The
  rewrite only triggers when the collapsed form is >= 79 chars wide. }
var
  z: array of AnsiChar;
  zLen: SizeInt;
  out_: AnsiString;
  i, j, k, n: SizeInt;
  c, cEnd: AnsiChar;
  nParen, nLine: SizeInt;
  isIndex, isWhere: Boolean;

  procedure FlushPending(extra: AnsiString);
  begin
    if j > 0 then begin
      SetLength(out_, Length(out_) + j);
      Move(z[0], out_[Length(out_) - j + 1], j);
    end;
    out_ := out_ + extra;
    j := 0;
  end;

  function PCharAt(pos: SizeInt): AnsiChar; inline;
  begin if (pos >= 0) and (pos < zLen) then Result := z[pos] else Result := #0; end;

  function StrnicmpAt(pos: SizeInt; const zPat: AnsiString): Boolean;
  var
    ii: SizeInt; ca, cb: AnsiChar;
  begin
    if pos + Length(zPat) > zLen then Exit(False);
    for ii := 0 to Length(zPat) - 1 do begin
      ca := z[pos + ii]; cb := zPat[ii + 1];
      if (ca >= 'A') and (ca <= 'Z') then Inc(ca, 32);
      if (cb >= 'A') and (cb <= 'Z') then Inc(cb, 32);
      if ca <> cb then Exit(False);
    end;
    Result := True;
  end;

  function WsToEolAt(pos: SizeInt): Boolean;
  var ii: SizeInt;
  begin
    ii := pos;
    while ii < zLen do begin
      if z[ii] = #10 then Exit(True);
      if shellFmtIsSpace(z[ii]) then begin Inc(ii); Continue; end;
      if (z[ii] = '-') and (ii + 1 < zLen) and (z[ii+1] = '-') then Exit(True);
      Exit(False);
    end;
    Result := True;
  end;

begin
  if zSql = '' then Exit('');
  if not bIndent then Exit(zSql + ';');
  if (sqlite3_strlike('CREATE VIEW%', PAnsiChar(zSql), 0) = 0)
     or (sqlite3_strlike('CREATE TRIG%', PAnsiChar(zSql), 0) = 0) then
    Exit(zSql + ';');
  isIndex := (sqlite3_strlike('CREATE INDEX%', PAnsiChar(zSql), 0) = 0)
          or (sqlite3_strlike('CREATE UNIQUE INDEX%', PAnsiChar(zSql), 0) = 0);

  { Collapse runs of whitespace, drop padding around '(' / ')'.  Mirrors
    the first for-loop at shell.c.in:2417..2428.  We work in a 0-based
    char array because the C uses pointer arithmetic on z[] in place. }
  n := Length(zSql);
  SetLength(z, n + 1);
  if n > 0 then Move(zSql[1], z[0], n);
  z[n] := #0;

  k := 0;
  i := 0;
  while (i < n) and shellFmtIsSpace(z[i]) do Inc(i);
  while i < n do begin
    c := z[i];
    if shellFmtIsSpace(c) then begin
      if (k > 0) and (z[k-1] = #13) then z[k-1] := #10;
      if (k > 0) and (shellFmtIsSpace(z[k-1]) or (z[k-1] = '(')) then
      begin Inc(i); Continue; end;
    end else if ((c = '(') or (c = ')')) and (k > 0)
                and shellFmtIsSpace(z[k-1]) then
      Dec(k);
    z[k] := c; Inc(k);
    Inc(i);
  end;
  while (k > 0) and shellFmtIsSpace(z[k-1]) do Dec(k);
  zLen := k;

  if zLen < 79 then begin
    SetLength(Result, zLen + 1);
    if zLen > 0 then Move(z[0], Result[1], zLen);
    Result[zLen + 1] := ';';
    Exit;
  end;

  out_    := '';
  nParen  := 0;
  nLine   := 0;
  cEnd    := #0;
  isWhere := False;
  i := 0;
  j := 0;            { z[0..j-1] is the still-pending buffer }
  while i < zLen do begin
    c := z[i];
    if c = cEnd then
      cEnd := #0
    else if cEnd <> #0 then
      { inside string/comment — passthrough }
    else if (c = '"') or (c = '''') or (c = '`') then
      cEnd := c
    else if c = '[' then
      cEnd := ']'
    else if (c = '-') and (PCharAt(i+1) = '-') then
      cEnd := #10
    else if c = '(' then
      Inc(nParen)
    else if c = ')' then begin
      Dec(nParen);
      if (nLine > 0) and (nParen = 0) and (j > 0) and (not isWhere) then
        FlushPending(#10);
    end else if ((c = 'w') or (c = 'W')) and (nParen = 0) and isIndex
                and StrnicmpAt(i, 'WHERE')
                and (not shellFmtIsAlnum(PCharAt(i+5)))
                and (PCharAt(i+5) <> '_') then
      isWhere := True
    else if isWhere and ((c = 'A') or (c = 'a')) and (nParen = 0)
            and StrnicmpAt(i, 'AND')
            and (not shellFmtIsAlnum(PCharAt(i+3)))
            and (PCharAt(i+3) <> '_') then
      FlushPending(#10'    ');
    z[j] := c; Inc(j);
    if (nParen = 1) and (cEnd = #0)
       and ((c = '(') or (c = #10)
            or ((c = ',') and (not WsToEolAt(i+1))))
       and (not isWhere) then
    begin
      if c = #10 then Dec(j);
      FlushPending(#10'  ');
      Inc(nLine);
      while (i + 1 < zLen) and shellFmtIsSpace(z[i+1]) do Inc(i);
    end;
    Inc(i);
  end;
  FlushPending('');
  Result := out_ + ';';
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
  { bIndent is honoured by passing it to shellFormatSchemaText below. }

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
      sql := sql + 'SELECT shell_add_schema(sql,NULL,name) AS sql,'
                 + ' type, tbl_name, name, rowid, '
                 + IntToStr(iSchema) + ' AS snum, '
                 + '''' + StringReplace(zDb, '''', '''''', [rfReplaceAll])
                 + ''' AS sname'
                 + ' FROM "' + StringReplace(zDb, '"', '""', [rfReplaceAll])
                 + '".sqlite_schema'
    else
      sql := sql + 'SELECT shell_add_schema(sql,'
                 + '''' + StringReplace(zDb, '''', '''''', [rfReplaceAll])
                 + ''',name) AS sql,'
                 + ' type, tbl_name, name, rowid, '
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
    if zRow <> nil then
      WriteLn(shellFormatSchemaText(AnsiString(zRow), bIndent));
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

{ libc 'stderr' FILE* — used to wire -memtrace / -pcachetrace to the
  same sink as shell.c.in:13197 / :13199 (sqlite3{Mem,Pcache}TraceActivate
  receive stderr).  Declared cvar/external so FPC resolves it against
  glibc's global FILE*; on Linux this is the canonical handle, matching
  the C shell exactly. }
var
  shellLibcStderr: Pointer; external 'c' name 'stderr';

{ 10.1.24.b — libc popen/pclose/fread/fclose for the .import "|cmd" arm.
  Bound directly because FPC's Unix.POpen returns a pid bound to a
  Text/file variable, which doesn't compose with importGetc's byte-at-a-
  time read loop.  Mirrors C shell.c.in:7593..7600 which calls
  sqlite3_popen / pclose against a FILE*. }
function shellLibcPOpen(cmd, mode: PAnsiChar): Pointer;
  cdecl; external 'c' name 'popen';
function shellLibcPClose(stream: Pointer): cint;
  cdecl; external 'c' name 'pclose';
function shellLibcFRead(buf: Pointer; size, n: PtrUInt; stream: Pointer): PtrUInt;
  cdecl; external 'c' name 'fread';
function shellLibcFClose(stream: Pointer): cint;
  cdecl; external 'c' name 'fclose';
{ 10.1.36 — libc fopen + stdout + fprintf for SQLITE_CONFIG_LOG plumbing.
  Mirrors output_file_open / cli_printf in shell.c.in:1754. }
function shellLibcFOpen(path, mode: PAnsiChar): Pointer;
  cdecl; external 'c' name 'fopen';
function shellLibcFFlush(stream: Pointer): cint;
  cdecl; external 'c' name 'fflush';
function shellLibcFPrintf(stream: Pointer; const fmt: PAnsiChar): cint; cdecl; varargs;
  external 'c' name 'fprintf';
var
  shellLibcStdout: Pointer; external 'c' name 'stdout';
  { 10.1.36 — pLog FILE* installed via SQLITE_CONFIG_LOG.  nil ⇒ logging
    disabled.  Mirrors shell_state.pLog in shell.c.in:403. }
  gLogFile: Pointer = nil;

{ 10.1.36 — shellLog: xLog trampoline registered with sqlite3_config
  (SQLITE_CONFIG_LOG).  Mirrors shell.c.in:1751..1756. }
procedure shellLog(pArg: Pointer; iErrCode: i32; zMsg: PAnsiChar); cdecl;
begin
  if pArg = nil then ;
  if gLogFile = nil then Exit;
  shellLibcFPrintf(gLogFile, '(%d) %s'#10, iErrCode, zMsg);
  shellLibcFFlush(gLogFile);
end;

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

function cmdTimer(p: PShellState; const args: array of AnsiString; nArg: SizeInt): i32;
begin
  Result := 0;
  if nArg < 1 then begin
    shellEPutZ('Usage: .timer on|off|once'#10);
    Result := 1;
    Exit;
  end;
  if args[0] = 'once' then p^.enableTimer := 1
  else p^.enableTimer := 2 * parseOnOff(args[0], 0);
end;

{ 10.1.30 — `.eqp off|on|trace|trigger|full`  (shell.c.in:9479..9504) }

function cmdEqp(p: PShellState; const args: array of AnsiString; nArg: SizeInt): i32;
begin
  Result := 0;
  if nArg < 1 then begin
    shellEPutZ('Usage: .eqp off|on|trace|trigger|full'#10);
    Result := 1;
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

procedure failIfSafeMode(p: PShellState; const zMsg: AnsiString); forward;

function cmdShell(p: PShellState; const args: array of AnsiString; nArg: SizeInt;
                   const zCmdName: AnsiString): i32;
var
  zCmd, tok: AnsiString;
  i, x: i32;
begin
  Result := 0;
  { 10.1.34 — safe-mode gate (shell.c.in:11248):
      failIfSafeMode(p, "cannot run .%s in safe mode", azArg[0]); }
  failIfSafeMode(p, 'cannot run .' + zCmdName + ' in safe mode');
  if nArg < 1 then begin
    shellEPutZ('Usage: .system COMMAND'#10);
    Result := 1;
    Exit;
  end;
  zCmd := '';
  for i := 0 to nArg - 1 do begin
    if Pos(' ', args[i]) > 0 then tok := '"' + args[i] + '"' else tok := args[i];
    if i = 0 then zCmd := tok else zCmd := zCmd + ' ' + tok;
  end;
  { 10.1.34 — flush Pascal-side buffers so prior writes land in the
    currently-redirected sink before the child writes to inherited fd 1.
    With cmdOutput's fd-level dup2 onto fd 1, child stdout already follows
    the active .output FILE / .once FILE redirection automatically. }
  Flush(Output);
  x := fpsystem(zCmd);
  if x <> 0 then shellEPutZ(Format('System command returns %d'#10, [x]));
end;

{ 10.1.35 — `.cd DIRECTORY`  (shell.c.in:9127..9145) }

function cmdCd(p: PShellState; const args: array of AnsiString; nArg: SizeInt): i32;
var rc: i32;
begin
  Result := 0;
  failIfSafeMode(p, 'cannot run .cd in safe mode');
  if nArg <> 1 then begin
    shellEPutZ('Usage: .cd DIRECTORY'#10);
    Result := 1;
    Exit;
  end;
  rc := FpChdir(PAnsiChar(args[0]));
  if rc <> 0 then begin
    shellEPutZ(Format('Cannot change to directory "%s"'#10, [args[0]]));
    Result := 1;
  end;
end;

{ 10.1.36 — `.log FILENAME|on|off`  (shell.c.in:10091..10109).

  Records the destination string (for `.show`) and routes log output
  through the xLog trampoline registered via SQLITE_CONFIG_LOG (the
  Phase 8.1.1 overload).  Closes any previously-open log file before
  opening a new one. }

function cmdLog(const args: array of AnsiString; nArg: SizeInt): i32;
var
  zFile: AnsiString;
begin
  Result := 0;
  if nArg <> 1 then begin
    shellEPutZ('Usage: .log FILENAME'#10);
    Result := 1;
    Exit;
  end;
  zFile := args[0];
  { Close any user-opened file from a previous .log call.  stdout/stderr
    are libc globals and must not be fclose()d (matches output_file_close
    in shell.c.in). }
  if (gLogFile <> nil)
     and (gLogFile <> shellLibcStdout)
     and (gLogFile <> shellLibcStderr) then
    shellLibcFClose(gLogFile);
  gLogFile := nil;
  if zFile = 'on' then begin
    gLogFile := shellLibcStdout;
    zLogFile := 'stdout';
  end else if (zFile = 'off') or (zFile = '') then begin
    zLogFile := 'off';
  end else if zFile = 'stdout' then begin
    gLogFile := shellLibcStdout;
    zLogFile := zFile;
  end else if zFile = 'stderr' then begin
    gLogFile := shellLibcStderr;
    zLogFile := zFile;
  end else begin
    gLogFile := shellLibcFOpen(PAnsiChar(zFile), 'wb');
    if gLogFile = nil then begin
      shellEPutZ(Format('Error: cannot open "%s"'#10, [zFile]));
      Result := 1;
      Exit;
    end;
    zLogFile := zFile;
  end;
end;

{ 10.1.49 — `.dbinfo ?DB?`  (shell.c.in:5485..5575).  Reads the 100-byte
  page-1 header via sqlite_dbpage(?), prints the named integer fields,
  then runs the small set of count queries against sqlite_schema. }

function cmdDbinfo(p: PShellState; const args: array of AnsiString; nArg: SizeInt): i32;
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
  Result := 0;
  if nArg >= 1 then zDb := args[0] else zDb := 'main';
  openDb(p, 0);
  if p^.db = nil then begin Result := 1; Exit; end;
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db,
        'SELECT data FROM sqlite_dbpage(?1) WHERE pgno=1',
        -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    shellEPutZ(Format('error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Result := 1;
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
    Result := 1;
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

function cmdBackup(p: PShellState; const args: array of AnsiString; nArg: SizeInt;
                   const cmdName: AnsiString): i32;
var
  pDest: PTsqlite3;
  pBackup: PSqlite3Backup;
  zDb, zDestFile, zVfs: AnsiString;
  bAsync: i32;
  j: SizeInt;
  rc: i32;
  z: AnsiString;
begin
  Result := 0;
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
        Result := 1; Exit;
      end;
    end else if zDestFile = '' then zDestFile := z
    else if zDb = '' then begin zDb := zDestFile; zDestFile := z; end
    else begin
      shellEPutZ(Format('Usage: .%s ?DB? ?OPTIONS? FILENAME'#10, [cmdName]));
      Result := 1; Exit;
    end;
  end;
  if zDestFile = '' then begin
    shellEPutZ(Format('missing FILENAME argument on .%s'#10, [cmdName]));
    Result := 1; Exit;
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
    Result := 1; Exit;
  end;
  if bAsync <> 0 then
    sqlite3_exec(pDest, 'PRAGMA synchronous=OFF; PRAGMA journal_mode=OFF;',
                 nil, nil, nil);
  openDb(p, 0);
  pBackup := sqlite3_backup_init(pDest, 'main', p^.db, PAnsiChar(zDb));
  if pBackup = nil then begin
    shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(pDest)) + sLineBreak);
    sqlite3_close(pDest);
    Result := 1; Exit;
  end;
  repeat
    rc := sqlite3_backup_step(pBackup, 100);
  until rc <> SQLITE_OK;
  sqlite3_backup_finish(pBackup);
  if rc <> SQLITE_DONE then begin
    shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(pDest)) + sLineBreak);
    Result := 1;
  end;
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

function cmdClone(p: PShellState; const args: array of AnsiString;
                  nArg: SizeInt): i32;
var
  zNewDb: AnsiString;
  newDb: PTsqlite3;
  rc: i32;
begin
  Result := 0;
  if nArg <> 1 then begin
    shellEPutZ('Usage: .clone FILENAME'#10);
    Result := 1; Exit;
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
    Result := 1; Exit;
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

function cmdRestore(p: PShellState; const args: array of AnsiString; nArg: SizeInt): i32;
var
  pSrc: PTsqlite3;
  pBackup: PSqlite3Backup;
  zDb, zSrcFile: AnsiString;
  rc, nTimeout: i32;
begin
  Result := 0;
  if nArg = 1 then begin zSrcFile := args[0]; zDb := 'main'; end
  else if nArg = 2 then begin zDb := args[0]; zSrcFile := args[1]; end
  else begin
    shellEPutZ('Usage: .restore ?DB? FILE'#10);
    Result := 1; Exit;
  end;
  pSrc := nil;
  rc := sqlite3_open(PAnsiChar(zSrcFile), @pSrc);
  if rc <> SQLITE_OK then begin
    shellEPutZ(Format('Error: cannot open "%s"'#10, [zSrcFile]));
    if pSrc <> nil then sqlite3_close(pSrc);
    Result := 1; Exit;
  end;
  openDb(p, 0);
  pBackup := sqlite3_backup_init(p^.db, PAnsiChar(zDb), pSrc, 'main');
  if pBackup = nil then begin
    shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    sqlite3_close(pSrc);
    Result := 1; Exit;
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
  else if (rc = SQLITE_BUSY) or (rc = SQLITE_LOCKED) then begin
    shellEPutZ('Error: source database is busy'#10);
    Result := 1;
  end else begin
    shellEPutZ('Error: ' + AnsiString(sqlite3_errmsg(p^.db)) + sLineBreak);
    Result := 1;
  end;
  sqlite3_close(pSrc);
end;

{ ----------------------------------------------------------------------
  10.1.27  `.open ?-options? ?FILENAME?`  — shell.c.in:10141..10251

  Closes the currently-open db, parses the option set we ship today
  (--readonly, --new, --nofollow, --exclusive, --ifexists, --zip,
  --append, --deserialize, --hexdb, --normal, --maxsize N), then
  reopens against the supplied filename (or :memory: when omitted).
  --hexdb is allowed to proceed with no filename because input comes
  from the script (matches shell.c.in:10209).  On failure, falls back
  to a TEMP database to keep the REPL alive.
  ---------------------------------------------------------------------- }

function shellIntegerValue(const z: AnsiString): i64; forward;

{ 10.1.27.d — shellFilenameFromUri (shell.c.in:5807..5834).
  Given a URI of the form 'file:NAME?QUERY', return the percent-decoded
  NAME portion (everything before '?').  Used by `.open --new` so that
  pre-open deletion targets the real on-disk filename, not the URI. }
function shellFilenameFromUri(const zFN: AnsiString): AnsiString;
  function hexVal(ch: AnsiChar): i32; inline;
  begin
    case ch of
      '0'..'9': Result := Ord(ch) - Ord('0');
      'a'..'f': Result := Ord(ch) - Ord('a') + 10;
      'A'..'F': Result := Ord(ch) - Ord('A') + 10;
    else
      Result := -1;
    end;
  end;
var
  i, n, d1, d2: i32;
  c: AnsiChar;
begin
  Result := '';
  n := Length(zFN);
  if (n < 5) or (Copy(zFN, 1, 5) <> 'file:') then Exit;
  i := 6;
  while i <= n do begin
    c := zFN[i];
    if c = '?' then Break;
    if c <> '%' then begin
      Result := Result + c;
      Inc(i);
      Continue;
    end;
    if i + 2 > n then Break;
    d1 := hexVal(zFN[i + 1]);
    if d1 < 0 then Break;
    d2 := hexVal(zFN[i + 2]);
    if d2 < 0 then Break;
    Result := Result + AnsiChar(d1 * 16 + d2);
    Inc(i, 3);
  end;
end;

{ 10.1.27.e — failIfSafeMode helper (shell.c.in:1795..1810).
  No-op when p^.bSafeMode is clear; otherwise emits the
  shellErrorLocation-shaped prefix followed by zMsg and halts(1).
  Mirrors C exactly so call sites stay byte-comparable.  The inlined
  copy in cmdImport (10.1.24.b) predates this helper and is kept
  intact to avoid touching that arm. }
procedure failIfSafeMode(p: PShellState; const zMsg: AnsiString);
begin
  if p^.bSafeMode = 0 then Exit;
  if p^.zErrPrefix <> nil then
    shellEPutZ(AnsiString(p^.zErrPrefix) + ' ' + zMsg + #10)
  else if (p^.zInFile = nil) or (StrComp(p^.zInFile, '<stdin>') = 0) then
    shellEPutZ(Format('line %d: %s'#10, [Int64(p^.lineno), string(zMsg)]))
  else
    shellEPutZ(Format('%s:%d: %s'#10,
      [string(AnsiString(p^.zInFile)), Int64(p^.lineno), string(zMsg)]));
  Halt(1);
end;

{ 10.1.27.f — session_close_all pre-close hook stub (shell.c.in:10198,
  also 11052, 11305).  The session extension is not ported in
  pas-sqlite3 (tracked at 10.1.47); this stub preserves the C call
  site so future wiring is a one-line body change. }
procedure sessionCloseAll(p: PShellState; bArg: i32);
begin
  { TODO: session extension not ported — 10.1.47 }
end;

procedure cmdOpen(p: PShellState; const args: array of AnsiString; nArg: SizeInt);
var
  j: SizeInt;
  z, zFN, zDel: AnsiString;
  newFlag: i32;
  openFlags: i32;
  openMode: i32;
  szMax: i64;
begin
  zFN := '';
  newFlag := 0;
  openFlags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE;
  { 10.1.27.e — safe-mode forces read-only up front (shell.c.in:10148). }
  if p^.bSafeMode <> 0 then openFlags := SQLITE_OPEN_READONLY;
  openMode := SHELL_OPEN_UNSPEC;
  szMax := 0;
  j := 0;
  while j < nArg do begin
    z := args[j];
    if (Length(z) > 0) and (z[1] = '-') then begin
      if (Length(z) > 1) and (z[2] = '-') then Delete(z, 1, 1);
      if z = '-new' then newFlag := 1
      else if (z = '-zip') and (p^.bSafeMode = 0) then openMode := SHELL_OPEN_ZIPFILE
      else if (z = '-append') and (p^.bSafeMode = 0) then openMode := SHELL_OPEN_APPENDVFS
      else if z = '-readonly' then begin
        openFlags := openFlags and not (SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
        openFlags := openFlags or SQLITE_OPEN_READONLY;
      end
      else if z = '-exclusive' then openFlags := openFlags or SQLITE_OPEN_EXCLUSIVE
      else if z = '-ifexists' then openFlags := openFlags and not SQLITE_OPEN_CREATE
      else if z = '-nofollow' then openFlags := openFlags or SQLITE_OPEN_NOFOLLOW
      else if z = '-deserialize' then openMode := SHELL_OPEN_DESERIALIZE
      else if z = '-hexdb' then openMode := SHELL_OPEN_HEXDB
      else if z = '-normal' then openMode := SHELL_OPEN_NORMAL
      else if (z = '-maxsize') and (j + 1 < nArg) then begin
        Inc(j);
        szMax := shellIntegerValue(args[j]);
      end
      else begin
        shellEPutZ(Format('unknown option: %s'#10, [args[j]]));
        Exit;
      end;
    end else if zFN = '' then zFN := z
    else begin
      shellEPutZ(Format('extra argument: "%s"'#10, [z]));
      Exit;
    end;
    Inc(j);
  end;

  { 10.1.27.f — session_close_all(p, -1) pre-close hook
    (shell.c.in:10198).  Stub; see sessionCloseAll above. }
  sessionCloseAll(p, -1);
  closeDb(p^.db);
  p^.db := nil;
  globalDb := nil;
  p^.pAuxDb^.zDbFilename := nil;
  if p^.pAuxDb^.zFreeOnClose <> nil then begin
    StrDispose(p^.pAuxDb^.zFreeOnClose);
    p^.pAuxDb^.zFreeOnClose := nil;
  end;
  p^.openMode := openMode;
  p^.openFlags := openFlags;
  { 10.1.27.c — capture --maxsize into p^.szMax so openDb's deserialize
    arm can pass it to SQLITE_FCNTL_SIZE_LIMIT.  This diverges from
    shell.c.in:10206 (which unconditionally zeroes szMax after parsing,
    a long-standing upstream quirk that renders .open --maxsize a
    no-op); keeping it live is harmless on round-trips that stay under
    the limit and gives users the size cap they asked for. }
  p^.szMax := szMax;

  if (zFN <> '') or (p^.openMode = SHELL_OPEN_HEXDB) then begin
    { 10.1.27.d — URI-aware --new deletion (shell.c.in:10210..10218).
      When zFN starts with 'file:', percent-decode it to the real path
      before unlink so URI-form arguments delete the right file. }
    if (newFlag <> 0) and (zFN <> '') and (p^.bSafeMode = 0) then begin
      if (Length(zFN) >= 5) and (Copy(zFN, 1, 5) = 'file:') then begin
        zDel := shellFilenameFromUri(zFN);
        if zDel <> '' then DeleteFile(string(zDel));
      end else
        DeleteFile(string(zFN));
    end;
    { 10.1.27.e — refuse disk-backed databases in safe mode
      (shell.c.in:10221..10227).  HEXDB pseudo-files and the magic
      ":memory:" name are still allowed. }
    if (p^.bSafeMode <> 0)
       and (p^.openMode <> SHELL_OPEN_HEXDB)
       and (zFN <> '')
       and (zFN <> ':memory:') then
      failIfSafeMode(p, 'cannot open disk-based database files in safe mode');
    if zFN <> '' then begin
      p^.pAuxDb^.zFreeOnClose := StrAlloc(Length(zFN) + 1);
      StrPCopy(p^.pAuxDb^.zFreeOnClose, zFN);
      p^.pAuxDb^.zDbFilename := p^.pAuxDb^.zFreeOnClose;
    end else begin
      p^.pAuxDb^.zFreeOnClose := nil;
      p^.pAuxDb^.zDbFilename := nil;
    end;
    openDb(p, 1);
    if p^.db = nil then begin
      shellEPutZ(Format('Error: cannot open ''%s'''#10, [zFN]));
      if p^.pAuxDb^.zFreeOnClose <> nil then begin
        StrDispose(p^.pAuxDb^.zFreeOnClose);
        p^.pAuxDb^.zFreeOnClose := nil;
      end;
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
  rc := sqlite3_prepare_v2(p^.db, 'PRAGMA page_count', -1, @pStmt, @pzTail);
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

  Faithful port of upstream `dump_callback` + `tableColumnList` +
  `run_schema_dump_query` + `run_table_dump_query` + `outputDumpWarning`.
  --preserve-rowids and --data-only are now honoured; --newlines is
  accepted as a no-op (matches upstream's commented-out
  /*ShellSetFlag(p,SHFLG_Newlines);*/ stub).  CORRUPT detour with
  `ORDER BY rowid DESC` still deferred — the engine can't currently
  surface a SQLITE_CORRUPT mid-step in a way the dump path notices, so
  the second-pass retry is wired but inert.
  ---------------------------------------------------------------------- }

type
  TDumpStrArr = array of AnsiString;

{ shell.c.in:1217..1225 — return the quote character we should use to
  enclose zName, or #0 if it can be emitted bare. }
function dumpQuoteChar(zName: PAnsiChar): AnsiChar;
var
  i: i32;
begin
  if zName = nil then Exit('"');
  if not (zName[0] in ['A'..'Z','a'..'z','_']) then Exit('"');
  i := 0;
  while zName[i] <> #0 do begin
    if not (zName[i] in ['A'..'Z','a'..'z','0'..'9','_']) then
      Exit('"');
    Inc(i);
  end;
  if sqlite3_keyword_check(zName, i) <> 0 then Exit('"');
  Result := #0;
end;

{ Pascal-side equivalent of appendText(&s, z, cQuote): wrap z in cQuote,
  doubling the quote char if it appears in z.  cQuote=#0 means emit as-is. }
function dumpAppendQuoted(const z: AnsiString; cQuote: AnsiChar): AnsiString;
var
  i: SizeInt;
begin
  if cQuote = #0 then Exit(z);
  Result := cQuote;
  for i := 1 to Length(z) do begin
    Result := Result + z[i];
    if z[i] = cQuote then Result := Result + cQuote;
  end;
  Result := Result + cQuote;
end;

{ shell.c.in:2315..2342 — emit a CREATE statement, switching to
  CREATE TABLE IF NOT EXISTS when applicable, and rescue trailing
  /* */ or -- comments by extending the line so the appended ';' lands
  outside them. }
procedure dumpPrintSchemaLine(const z, zTail: AnsiString);
var
  zUse, candidate: AnsiString;
  i: i32;
const
  azTerm: array[0..2] of AnsiString = ('', '*/', #10);
begin
  if z = '' then Exit;
  if zTail = '' then Exit;
  zUse := z;
  if (zTail[1] = ';')
     and ((Pos('/*', z) > 0) or (Pos('--', z) > 0)) then
  begin
    for i := 0 to 2 do begin
      candidate := z + azTerm[i] + ';';
      if sqlite3_complete(PAnsiChar(candidate)) <> 0 then begin
        SetLength(candidate, Length(candidate) - 1);
        zUse := candidate;
        break;
      end;
    end;
  end;
  if sqlite3_strglob('CREATE TABLE [''"]*', PAnsiChar(zUse)) = 0 then
    Write('CREATE TABLE IF NOT EXISTS ', Copy(zUse, 14, MaxInt), zTail)
  else
    Write(zUse, zTail);
end;

{ shell.c.in:7349..7364 — emit a /* WARNING ... DEFENSIVE ... */ banner if
  the dump scope contains any CREATE VIRTUAL TABLE statements. }
procedure dumpOutputWarning(p: PShellState; const zLike: AnsiString);
var
  q: AnsiString;
  pStmt: PVdbe;
  rc: i32;
  pzTail: PAnsiChar;
begin
  q := 'SELECT 1 FROM sqlite_schema o WHERE '
    + 'sql LIKE ''CREATE VIRTUAL TABLE%'' AND ('
    + IfThen(zLike <> '', zLike, 'true') + ')';
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(q), -1, @pStmt, @pzTail);
  if (rc = SQLITE_OK) and (pStmt <> nil) and
     (sqlite3_step(pStmt) = SQLITE_ROW) then
    WriteLn('/* WARNING: '
          + 'Script requires that SQLITE_DBCONFIG_DEFENSIVE be disabled */');
  if pStmt <> nil then sqlite3_finalize(pStmt);
end;

{ shell.c.in:3414..3503 — return a list of column names for table zTab.
  Index 0 holds the rowid column name (or '' if no rowid is to be
  preserved); regular column names live at indices 1..nCol.  Returns
  False if the table can't be introspected. }
function dumpTableColumnList(p: PShellState; const zTab: AnsiString;
                             var azCol: TDumpStrArr): Boolean;
var
  pStmt: PVdbe;
  zSql, zPat: AnsiString;
  rc, nCol, nPK, isIPK: i32;
  pzTail: PAnsiChar;
  preserveRowid: Boolean;
  zType: PAnsiChar;
  i, j: i32;
const
  azRowid: array[0..2] of AnsiString = ('rowid', '_rowid_', 'oid');
begin
  Result := False;
  SetLength(azCol, 0);
  preserveRowid := (p^.shellFlgs and SHFLG_PreserveRowid) <> 0;
  zPat := zTab;
  zSql := 'PRAGMA table_info=' + dumpAppendQuoted(zPat, '''');
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
  if rc <> SQLITE_OK then Exit;

  nCol := 0; nPK := 0; isIPK := 0;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    if Length(azCol) < nCol + 2 then SetLength(azCol, nCol + 2 + 4);
    Inc(nCol);
    azCol[nCol] := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 1)));
    if sqlite3_column_int(pStmt, 5) <> 0 then begin
      Inc(nPK);
      zType := PAnsiChar(sqlite3_column_text(pStmt, 2));
      if (nPK = 1) and (zType <> nil)
         and (StrIComp(zType, 'INTEGER') = 0) then
        isIPK := 1
      else
        isIPK := 0;
    end;
  end;
  sqlite3_finalize(pStmt);
  if nCol = 0 then Exit;
  SetLength(azCol, nCol + 1);
  azCol[0] := '';

  { Decide whether rowid actually needs preserving.  If the only PK is
    INTEGER, run pragma_index_list to disambiguate IPK alias from a
    real INTEGER PK DESC / WITHOUT ROWID. }
  if preserveRowid and (isIPK <> 0) then begin
    zSql := 'SELECT 1 FROM pragma_index_list('
          + dumpAppendQuoted(zPat, '''') + ') WHERE origin=''pk''';
    pStmt := nil;
    rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
    if rc <> SQLITE_OK then Exit(False);
    rc := sqlite3_step(pStmt);
    sqlite3_finalize(pStmt);
    preserveRowid := rc = SQLITE_ROW;
  end;
  if preserveRowid then begin
    for j := 0 to 2 do begin
      i := 1;
      while (i <= nCol) and (CompareText(azRowid[j], azCol[i]) <> 0) do Inc(i);
      if i > nCol then begin
        rc := sqlite3_table_column_metadata(p^.db, nil,
                  PAnsiChar(zPat), PAnsiChar(azRowid[j]),
                  nil, nil, nil, nil, nil);
        if rc = SQLITE_OK then azCol[0] := azRowid[j];
        break;
      end;
    end;
  end;
  Result := True;
end;

{ shell.c.in:2648..2690 — drive zSelect through sqlite3_step and emit
  one SQL-comma-joined row per result, terminated by a `;`.  The
  upstream subtlety: if column 0 contains `--` we put the `;` on its
  own line so the comment doesn't swallow it. }
procedure dumpRunTableDumpQuery(p: PShellState; const zSelect: AnsiString);
var
  pStmt: PVdbe;
  rc, i, nResult: i32;
  pzTail: PAnsiChar;
  z: PAnsiChar;
  s: AnsiString;
  trailingComment: Boolean;
begin
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSelect), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    WriteLn(Format('/**** ERROR: (%d) %s *****/', [rc,
      AnsiString(sqlite3_errmsg(p^.db))]));
    if (rc and $ff) <> SQLITE_CORRUPT then Inc(p^.nErr);
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit;
  end;
  nResult := sqlite3_column_count(pStmt);
  rc := sqlite3_step(pStmt);
  while rc = SQLITE_ROW do begin
    z := PAnsiChar(sqlite3_column_text(pStmt, 0));
    if z = nil then s := '' else s := AnsiString(z);
    Write(s);
    for i := 1 to nResult - 1 do begin
      Write(',');
      Write(AnsiString(PAnsiChar(sqlite3_column_text(pStmt, i))));
    end;
    trailingComment := False;
    if z <> nil then begin
      i := 0;
      while z[i] <> #0 do begin
        if (z[i] = '-') and (z[i+1] = '-') then begin
          trailingComment := True; Break;
        end;
        Inc(i);
      end;
    end;
    if trailingComment then WriteLn(#10';')
    else WriteLn(';');
    rc := sqlite3_step(pStmt);
  end;
  rc := sqlite3_finalize(pStmt);
  if rc <> SQLITE_OK then begin
    WriteLn(Format('/**** ERROR: (%d) %s *****/', [rc,
      AnsiString(sqlite3_errmsg(p^.db))]));
    if (rc and $ff) <> SQLITE_CORRUPT then Inc(p^.nErr);
  end;
end;

{ shell.c.in:3531..3659 — per-table dump callback.  Emits the CREATE
  statement (transformed for sqlite_sequence / sqlite_stat / virtual
  tables / IF NOT EXISTS) and then the INSERT INTO ... VALUES(...) data
  via MODE_Insert, optionally with an explicit (rowid,col,...) column
  list when --preserve-rowids is in effect. }
procedure dumpOneObject(p: PShellState; const zName, zType, zSql: AnsiString);
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc, i: i32;
  selectSql, sTable, sIns: AnsiString;
  savedMode: TShellMode;
  azCol: TDumpStrArr;
  cQuote: AnsiChar;
  dataOnly, noSys: Boolean;
begin
  dataOnly := (p^.shellFlgs and SHFLG_DumpDataOnly) <> 0;
  noSys    := (p^.shellFlgs and SHFLG_DumpNoSys)    <> 0;

  if (zName = 'sqlite_sequence') and not noSys then begin
    if p^.writableSchema = 0 then begin
      WriteLn('PRAGMA writable_schema=ON;');
      p^.writableSchema := 1;
    end;
    WriteLn('CREATE TABLE IF NOT EXISTS sqlite_sequence(name,seq);');
    WriteLn('DELETE FROM sqlite_sequence;');
  end else if (sqlite3_strglob('sqlite_stat?', PAnsiChar(zName)) = 0)
              and not noSys then begin
    if not dataOnly then WriteLn('ANALYZE sqlite_schema;');
  end else if Copy(zName, 1, 7) = 'sqlite_' then begin
    Exit;
  end else if dataOnly then begin
    { skip CREATE emission }
  end else if Copy(zSql, 1, 20) = 'CREATE VIRTUAL TABLE' then begin
    if p^.writableSchema = 0 then begin
      WriteLn('PRAGMA writable_schema=ON;');
      p^.writableSchema := 1;
    end;
    WriteLn(Format(
      'INSERT INTO sqlite_schema(type,name,tbl_name,rootpage,sql)'
      + 'VALUES(''table'',%s,%s,0,%s);',
      [dumpAppendQuoted(zName, ''''),
       dumpAppendQuoted(zName, ''''),
       dumpAppendQuoted(zSql,  '''')]));
    Exit;
  end else begin
    dumpPrintSchemaLine(zSql, ';'#10);
  end;

  if zType <> 'table' then Exit;

  if not dumpTableColumnList(p, zName, azCol) then begin
    Inc(p^.nErr);
    Exit;
  end;

  cQuote := dumpQuoteChar(PAnsiChar(zName));
  sTable := dumpAppendQuoted(zName, cQuote);

  { Upstream renders the column list via MODE_Insert + bTitles=QRF_SW_On
    when --preserve-rowids is in effect (shell.c.in:3248..3250).  Until
    the QRF unit is ported, we splice the column list into the
    destination-table string here so the resulting INSERT statements
    match upstream byte-for-byte. }
  if (azCol[0] <> '')
     or ((p^.shellFlgs and SHFLG_PreserveRowid) <> 0) then
  begin
    sTable := sTable + '(';
    if azCol[0] <> '' then begin
      sTable := sTable + azCol[0] + ',';
    end;
    for i := 1 to High(azCol) do begin
      sTable := sTable + dumpAppendQuoted(azCol[i],
                          dumpQuoteChar(PAnsiChar(azCol[i])));
      if i < High(azCol) then sTable := sTable + ',';
    end;
    sTable := sTable + ')';
  end;

  selectSql := 'SELECT ';
  if azCol[0] <> '' then begin
    selectSql := selectSql + azCol[0] + ',';
  end;
  for i := 1 to High(azCol) do begin
    selectSql := selectSql + dumpAppendQuoted(azCol[i],
                  dumpQuoteChar(PAnsiChar(azCol[i])));
    if i < High(azCol) then selectSql := selectSql + ',';
  end;
  selectSql := selectSql + ' FROM ' + dumpAppendQuoted(zName, cQuote);

  pStmt := nil; pzTail := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(selectSql), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(Format('Error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
    Inc(p^.nErr);
    Exit;
  end;

  savedMode := p^.mode;
  sIns := sTable;
  p^.zDestTable := PAnsiChar(sIns);
  p^.mode.eMode := MODE_Insert;
  p^.mode.spec.bTitles := QRF_No;
  stepAndRender(p, pStmt);
  p^.mode := savedMode;
  p^.zDestTable := nil;
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
function cmdSha3sum(p: PShellState; const args: array of AnsiString;
                    nArg: SizeInt): i32;
var
  zLike: AnsiString;
  bSchema, bSeparate, bDebug: i32;
  iSize: i32;
  i, rc: i32;
  pStmt: PVdbe;
  zArg, zSrcSql, zSql, sQuery, sSql, zSep, zTab: AnsiString;
  zPzTail: PAnsiChar;
begin
  Result := 0;
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
        shellEPutZ(Format('Unknown option "%s" on "sha3sum"'#10, [args[i]]));
        showHelp('sha3sum');
        Result := 1;
        Exit;
      end;
    end
    else if zLike <> '' then begin
      shellEPutZ('Usage: .sha3sum ?OPTIONS? ?LIKE-PATTERN?'#10);
      Result := 1;
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
  rc, i: i32;
  pzTail: PAnsiChar;
  zLike, zArg, zExpr, zSql: AnsiString;
  zN, zT, zS: AnsiString;
  savedShellFlgs: u32;
  savedMode: TShellMode;
begin
  openDb(p, 0);
  if p^.db = nil then Exit;
  savedShellFlgs := p^.shellFlgs;
  p^.shellFlgs := p^.shellFlgs and not (
    SHFLG_PreserveRowid or SHFLG_DumpDataOnly or SHFLG_DumpNoSys);
  zLike := '';
  i := 0;
  while i < nArg do begin
    zArg := args[i];
    if (Length(zArg) > 0) and (zArg[1] = '-') then begin
      Delete(zArg, 1, 1);
      if (Length(zArg) > 0) and (zArg[1] = '-') then Delete(zArg, 1, 1);
      if zArg = 'preserve-rowids' then
        p^.shellFlgs := p^.shellFlgs or SHFLG_PreserveRowid
      else if zArg = 'newlines' then begin
        { upstream stub: /*ShellSetFlag(p, SHFLG_Newlines);*/ }
      end
      else if zArg = 'data-only' then
        p^.shellFlgs := p^.shellFlgs or SHFLG_DumpDataOnly
      else if zArg = 'nosys' then
        p^.shellFlgs := p^.shellFlgs or SHFLG_DumpNoSys
      else begin
        shellEPutZ(Format('Error: unknown option: --%s'#10, [zArg]));
        p^.shellFlgs := savedShellFlgs;
        Exit;
      end;
    end
    else begin
      { LIKE pattern with the upstream shadow-table EXISTS clause. }
      zExpr := Format(
        'name LIKE ''%s'' ESCAPE ''\'' OR EXISTS ('
        + 'SELECT 1 FROM sqlite_schema WHERE '
        + '  name LIKE ''%s'' ESCAPE ''\'' AND'
        + '  sql LIKE ''CREATE VIRTUAL TABLE%%'' AND'
        + '  substr(o.name, 1, length(name)+1) == (name||''_'')'
        + ')',
        [StringReplace(args[i], '''', '''''', [rfReplaceAll]),
         StringReplace(args[i], '''', '''''', [rfReplaceAll])]);
      if zLike <> '' then zLike := zLike + ' OR ' + zExpr
      else zLike := zExpr;
    end;
    Inc(i);
  end;

  savedMode := p^.mode;
  dumpOutputWarning(p, zLike);
  if (p^.shellFlgs and SHFLG_DumpDataOnly) = 0 then begin
    WriteLn('PRAGMA foreign_keys=OFF;');
    WriteLn('BEGIN TRANSACTION;');
  end;
  p^.writableSchema := 0;
  p^.mode.spec.bTitles := QRF_No;
  sqlite3_exec(p^.db, 'SAVEPOINT dump; PRAGMA writable_schema=ON',
               nil, nil, nil);
  p^.nErr := 0;
  if zLike = '' then zLike := 'true';
  zSql := Format(
    'SELECT name, type, sql FROM sqlite_schema AS o '
    + 'WHERE (%s) AND type==''table'''
    + '  AND sql NOT NULL'
    + ' ORDER BY tbl_name=''sqlite_sequence'', rowid',
    [zLike]);
  pStmt := nil;
  rc := sqlite3_prepare_v2(p^.db, PAnsiChar(zSql), -1, @pStmt, @pzTail);
  if (rc <> SQLITE_OK) or (pStmt = nil) then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    shellEPutZ(Format('Error: %s'#10, [AnsiString(sqlite3_errmsg(p^.db))]));
  end else begin
    while sqlite3_step(pStmt) = SQLITE_ROW do begin
      zN := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 0)));
      zT := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 1)));
      if sqlite3_column_text(pStmt, 2) <> nil then
        zS := AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 2)))
      else zS := '';
      dumpOneObject(p, zN, zT, zS);
    end;
    sqlite3_finalize(pStmt);
  end;

  if (p^.shellFlgs and SHFLG_DumpDataOnly) = 0 then begin
    zSql := Format(
      'SELECT sql FROM sqlite_schema AS o '
      + 'WHERE (%s) AND sql NOT NULL'
      + '  AND type IN (''index'',''trigger'',''view'') '
      + 'ORDER BY type COLLATE NOCASE DESC',
      [zLike]);
    dumpRunTableDumpQuery(p, zSql);
  end;

  if p^.writableSchema <> 0 then begin
    WriteLn('PRAGMA writable_schema=OFF;');
    p^.writableSchema := 0;
  end;
  sqlite3_exec(p^.db, 'RELEASE dump', nil, nil, nil);
  if (p^.shellFlgs and SHFLG_DumpDataOnly) = 0 then begin
    if p^.nErr <> 0 then WriteLn('ROLLBACK; -- due to errors')
    else WriteLn('COMMIT;');
  end;
  p^.mode := savedMode;
  p^.shellFlgs := savedShellFlgs;
end;

{ ----------------------------------------------------------------------
  10.1.55  `.connection ?N? | close N`  — shell.c.in:9177..9221

  Switches the active aAuxDb slot.  No new code in libsqlite — we just
  swap which slot of the array p^.pAuxDb points at.
  ---------------------------------------------------------------------- }

function cmdConnection(p: PShellState; const args: array of AnsiString;
                       nArg: SizeInt): i32;
var
  i: SizeInt;
  zFile: AnsiString;
  zPtr: PAnsiChar;
  ix: i32;
begin
  Result := 0;
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
      Result := 1;
      Exit;
    end;
    if p^.aAuxDb[ix].db <> nil then begin
      closeDb(p^.aAuxDb[ix].db);
      p^.aAuxDb[ix].db := nil;
    end;
    Exit;
  end;
  shellEPutZ('Usage: .connection [close] [CONNECTION-NUMBER]'#10);
  Result := 1;
end;

{ ----------------------------------------------------------------------
  10.1.56  `.unmodule [--allexcept] NAME ...`  — shell.c.in:11954..11975

  Unregisters virtual-table modules.  --allexcept lifts all modules
  except those listed; otherwise NAME ... lists modules to drop.
  ---------------------------------------------------------------------- }

function cmdUnmodule(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt): i32;
var
  ii: SizeInt;
  zOpt: AnsiString;
  cArgs: array of PAnsiChar;
  cBack: array of AnsiString;
begin
  Result := 0;
  if nArg < 1 then begin
    shellEPutZ('Usage: .unmodule [--allexcept] NAME ...'#10);
    Result := 1;
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
  { shell.c.in:11999 — `nArg==2 ? azArg[1] : "main"`.  The Pascal nArg
    excludes the dot-command name, so the equivalent gate is nArg=1
    (exactly one trailing token).  >1 trailing tokens silently fall back
    to "main" in C. }
  if nArg = 1 then zDb := args[0] else zDb := 'main';
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
  { shell.c.in:12031 — `nArg==2 ? azArg[1] : "main"`.  Pascal nArg
    excludes the dot-command name, so the equivalent is nArg=1. }
  if nArg = 1 then zDb := args[0] else zDb := 'main';
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

function cmdFilectrl(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt): i32;
var
  zCmd, zSchema: AnsiString;
  zCmdC: AnsiString;
  zSchemaP: PAnsiChar;
  i, n2, iCtrl: SizeInt;
  filectrl: i32;
  iRes: i64;
  isOk: i32;
  iVal: i32;
  iLong: i64;
  zRet: PAnsiChar;
  bShifted: Boolean;
begin
  Result := 0;
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

  { C passes a NULL zSchema (defaults to "main" in sqlite3DbNameToBtree)
    when --schema was not given; an empty PAnsiChar would instead make
    sqlite3FindDbName fail and leave the caller's buffer untouched. }
  if zSchema = '' then zSchemaP := nil
  else                 zSchemaP := PAnsiChar(zSchema);

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
    Result := 1;
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
        Result := 1;
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

  { On bad nArg in any arm, fall through (isOk stays 0) so the post-case
    Usage path fires with rc=1, matching C's `break` semantics. }
  case filectrl of
    SQLITE_FCNTL_SIZE_LIMIT: begin
      if bShifted then begin
        if (nArg = 3) or (nArg = 4) then begin
          if nArg = 4 then iLong := StrToInt64Def(args[3], 0) else iLong := -1;
          iRes := iLong;
          sqlite3_file_control(p^.db, zSchemaP,
                               SQLITE_FCNTL_SIZE_LIMIT, @iRes);
          isOk := 1;
        end;
      end else begin
        if (nArg = 1) or (nArg = 2) then begin
          if nArg = 2 then iLong := StrToInt64Def(args[1], 0) else iLong := -1;
          iRes := iLong;
          sqlite3_file_control(p^.db, zSchemaP,
                               SQLITE_FCNTL_SIZE_LIMIT, @iRes);
          isOk := 1;
        end;
      end;
    end;
    SQLITE_FCNTL_LOCK_TIMEOUT,
    SQLITE_FCNTL_CHUNK_SIZE: begin
      if bShifted then begin
        if nArg = 4 then begin
          iVal := StrToIntDef(args[3], 0);
          sqlite3_file_control(p^.db, zSchemaP, filectrl, @iVal);
          isOk := 2;
        end;
      end else begin
        if nArg = 2 then begin
          iVal := StrToIntDef(args[1], 0);
          sqlite3_file_control(p^.db, zSchemaP, filectrl, @iVal);
          isOk := 2;
        end;
      end;
    end;
    SQLITE_FCNTL_PERSIST_WAL,
    SQLITE_FCNTL_POWERSAFE_OVERWRITE: begin
      if bShifted then begin
        if (nArg = 3) or (nArg = 4) then begin
          if nArg = 4 then iVal := parseOnOff(args[3], -1) else iVal := -1;
          sqlite3_file_control(p^.db, zSchemaP, filectrl, @iVal);
          iRes := iVal;
          isOk := 1;
        end;
      end else begin
        if (nArg = 1) or (nArg = 2) then begin
          if nArg = 2 then iVal := parseOnOff(args[1], -1) else iVal := -1;
          sqlite3_file_control(p^.db, zSchemaP, filectrl, @iVal);
          iRes := iVal;
          isOk := 1;
        end;
      end;
    end;
    SQLITE_FCNTL_DATA_VERSION,
    SQLITE_FCNTL_HAS_MOVED: begin
      if ((bShifted and (nArg = 3)) or ((not bShifted) and (nArg = 1))) then begin
        iVal := 0;
        sqlite3_file_control(p^.db, zSchemaP, filectrl, @iVal);
        iRes := iVal;
        isOk := 1;
      end;
    end;
    SQLITE_FCNTL_TEMPFILENAME: begin
      if ((bShifted and (nArg = 3)) or ((not bShifted) and (nArg = 1))) then begin
        zRet := nil;
        sqlite3_file_control(p^.db, zSchemaP, filectrl, @zRet);
        if zRet <> nil then begin
          WriteLn(AnsiString(zRet));
          sqlite3_free(zRet);
        end;
        isOk := 2;
      end;
    end;
    SQLITE_FCNTL_RESERVE_BYTES: begin
      if bShifted then begin
        if nArg >= 4 then begin
          iVal := StrToIntDef(args[3], 0);
          sqlite3_file_control(p^.db, zSchemaP, filectrl, @iVal);
        end;
      end else begin
        if nArg >= 2 then begin
          iVal := StrToIntDef(args[1], 0);
          sqlite3_file_control(p^.db, zSchemaP, filectrl, @iVal);
        end;
      end;
      iVal := -1;
      sqlite3_file_control(p^.db, zSchemaP, filectrl, @iVal);
      WriteLn(iVal);
      isOk := 2;
    end;
  end;

  if (isOk = 0) and (iCtrl >= 0) then begin
    shellSPutZ(Format('Usage: .filectrl %s %s'#10,
      [zCmdC, AnsiString(aFilectrl[iCtrl].zUsage)]));
    Result := 1;
  end else if isOk = 1 then
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
  SQLITE_TESTCTRL_FK_NO_ACTION         = 7;   { sqlite.h.in:8690 }
  SQLITE_TESTCTRL_INTERNAL_FUNCTIONS   = 17;
  SQLITE_TESTCTRL_JSON_SELFCHECK       = 14;

  aTestctrl: array[0..19] of TTestctrlEntry = (
    (zName: 'always';              code: SQLITE_TESTCTRL_ALWAYS;              unSafe: 1; zUsage: 'BOOLEAN'),
    (zName: 'assert';              code: SQLITE_TESTCTRL_ASSERT;              unSafe: 1; zUsage: 'BOOLEAN'),
    (zName: 'bitvec_test';         code: SQLITE_TESTCTRL_BITVEC_TEST;         unSafe: 1; zUsage: 'SIZE INT-ARRAY'),
    (zName: 'byteorder';           code: SQLITE_TESTCTRL_BYTEORDER;           unSafe: 0; zUsage: ''),
    (zName: 'extra_schema_checks'; code: SQLITE_TESTCTRL_EXTRA_SCHEMA_CHECKS; unSafe: 0; zUsage: 'BOOLEAN'),
    (zName: 'fault_install';       code: SQLITE_TESTCTRL_FAULT_INSTALL;       unSafe: 1; zUsage: 'args...'),
    (zName: 'fk_no_action';        code: SQLITE_TESTCTRL_FK_NO_ACTION;        unSafe: 0; zUsage: 'BOOLEAN'),
    (zName: 'imposter';            code: SQLITE_TESTCTRL_IMPOSTER;            unSafe: 1; zUsage: 'SCHEMA ON/OFF ROOTPAGE'),
    (zName: 'internal_functions';  code: SQLITE_TESTCTRL_INTERNAL_FUNCTIONS;  unSafe: 0; zUsage: ''),
    (zName: 'json_selfcheck';      code: SQLITE_TESTCTRL_JSON_SELFCHECK;      unSafe: 0; zUsage: 'BOOLEAN'),
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

function cmdTestctrl(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt): i32;
var
  zCmd, zCmdC: AnsiString;
  i, n2, iCtrl: SizeInt;
  testctrl: i32;
  isOk: i32;
  rc2: i32;
  isTestingMode: Boolean;
begin
  Result := 0;
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
    { shell.c.in:11451 — `rc = 1; goto meta_command_exit;` after the
      help dump; surface that to the dispatcher so the per-statement
      error counter ticks (and the process exits non-zero on EOF). }
    Result := 1;
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
        { shell.c.in:11467 — ambiguous → rc=1; goto meta_command_exit. }
        Result := 1;
        Exit;
      end;
    end;
  end;
  if testctrl < 0 then begin
    shellEPutZ(Format('Error: unknown test-control: %s'#10 +
      'Use ".testctrl --help" for help'#10, [zCmdC]));
    { shell.c.in:11472..11475 — unknown leaves rc untouched (no
      `rc=1; goto`); the per-statement error counter does NOT tick. }
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
    SQLITE_TESTCTRL_OPTIMIZATIONS: begin
      { shell.c.in:11487 — accept an unsigned int mask (label parsing
        deferred); apply via sqlite3_test_control(OPTIMIZATIONS,db,N). }
      if nArg >= 2 then begin
        rc2 := sqlite3_test_control(testctrl, p^.db,
                                    i32(shellIntegerValue(args[1])));
        isOk := 3;
      end;
    end;
    SQLITE_TESTCTRL_FK_NO_ACTION,
    SQLITE_TESTCTRL_SORTER_MMAP: begin
      if nArg = 2 then begin
        rc2 := sqlite3_test_control(testctrl, p^.db,
                                    i32(shellIntegerValue(args[1])));
        isOk := 3;
      end;
    end;
    SQLITE_TESTCTRL_PENDING_BYTE: begin
      if nArg = 2 then begin
        rc2 := sqlite3_test_control(testctrl,
                                    i32(shellIntegerValue(args[1])));
        isOk := 3;
      end;
    end;
    SQLITE_TESTCTRL_PRNG_SEED: begin
      if (nArg = 2) or (nArg = 3) then begin
        rc2 := sqlite3_test_control(testctrl, p^.db,
                                    i32(shellIntegerValue(args[1])));
        isOk := 3;
      end;
    end;
    SQLITE_TESTCTRL_ASSERT,
    SQLITE_TESTCTRL_ALWAYS: begin
      if nArg = 2 then begin
        rc2 := sqlite3_test_control(testctrl,
                                    i32(shellIntegerValue(args[1])));
        isOk := 1;
      end;
    end;
    SQLITE_TESTCTRL_LOCALTIME_FAULT,
    SQLITE_TESTCTRL_NEVER_CORRUPT,
    SQLITE_TESTCTRL_EXTRA_SCHEMA_CHECKS: begin
      if nArg = 2 then begin
        rc2 := sqlite3_test_control(testctrl,
                                    i32(shellIntegerValue(args[1])));
        isOk := 3;
      end;
    end;
    SQLITE_TESTCTRL_INTERNAL_FUNCTIONS: begin
      rc2 := sqlite3_test_control(testctrl, p^.db);
      isOk := 3;
    end;
    SQLITE_TESTCTRL_JSON_SELFCHECK: begin
      if nArg = 1 then begin
        rc2 := -1;
        isOk := 1;
      end else begin
        rc2 := i32(shellIntegerValue(args[1]));
        isOk := 3;
      end;
      sqlite3_test_control(testctrl, Pi32(@rc2));
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

  if (isOk = 0) and (iCtrl >= 0) then begin
    shellSPutZ(Format('Usage: .testctrl %s %s'#10,
      [zCmdC, AnsiString(aTestctrl[iCtrl].zUsage)]));
    { shell.c.in:11869..11872 — isOk==0 + iCtrl>=0 sets rc=1. }
    Result := 1;
  end else if isOk = 1 then
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
    'SELECT sql FROM (' +
    '  SELECT sql, type, tbl_name, name, rowid x FROM sqlite_schema' +
    '  UNION ALL' +
    '  SELECT sql, type, tbl_name, name, rowid FROM sqlite_temp_schema)' +
    ' WHERE type<>''meta'' AND sql NOTNULL' +
    '   AND name NOT LIKE ''sqlite\_%'' ESCAPE ''\''' +
    ' ORDER BY x';
  zStat1Q  =
    'SELECT ''INSERT INTO sqlite_stat1 VALUES('' || quote(tbl) || '','' || ' +
    'quote(idx) || '','' || quote(stat) || '')'' ' +
    'FROM sqlite_stat1';
  zStat4Q  =
    'SELECT ''INSERT INTO sqlite_stat4 VALUES('' || ' +
    'quote(tbl) || '','' || quote(idx) || '','' || ' +
    'quote(neq) || '','' || quote(nlt) || '','' || ' +
    'quote(ndlt) || '','' || quote(sample) || '')'' ' +
    'FROM sqlite_stat4';
var
  pStmt: PVdbe;
  pzTail: PAnsiChar;
  rc: i32;
  zText: PAnsiChar;
  q: AnsiString;
  qList: array[0..2] of AnsiString;
  i, ii: i32;
  haveStat: Boolean;
begin
  for ii := 0 to nArg - 1 do begin
    if (args[ii] = '--indent') or (args[ii] = '-indent') then
      { upstream accepts and silently ignores --indent (flgs stays 0) }
    else begin
      shellEPutZ(Format('Unknown option "%s" on .fullschema'#10, [args[ii]]));
      Exit;
    end;
  end;
  openDb(p, 0);
  if p^.db = nil then Exit;
  qList[0] := zSchemaQ;
  qList[1] := zStat1Q;
  qList[2] := zStat4Q;
  haveStat := False;
  for i := 0 to High(qList) do begin
    if i > 0 then begin
      { Skip stat queries if their tables don't exist. }
      pStmt := nil;
      rc := sqlite3_prepare_v2(p^.db,
        PAnsiChar('SELECT 1 FROM sqlite_schema WHERE name=' +
          QuotedStr(IfThen(i = 1, 'sqlite_stat1', 'sqlite_stat4'))),
        -1, @pStmt, @pzTail);
      if (rc = SQLITE_OK) and (pStmt <> nil)
         and (sqlite3_step(pStmt) = SQLITE_ROW) then
      begin
        if not haveStat then begin
          WriteLn('ANALYZE sqlite_schema;');
          haveStat := True;
        end;
      end else begin
        if pStmt <> nil then sqlite3_finalize(pStmt);
        Continue;
      end;
      sqlite3_finalize(pStmt);
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
  if not haveStat then
    WriteLn('/* No STAT tables available */')
  else
    WriteLn('ANALYZE sqlite_schema;');
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
  10.1.21  `.expert ?OPTS?`  — shell.c.in:3088..3208 + 9518..9536

  Activates the sqlite3_expert engine on the current database.  The
  subsequent SQL statement (consumed by runOneSqlLine) is forwarded to
  sqlite3_expert_sql() and then immediately reported via
  sqlite3_expert_analyze() / _report().
  ---------------------------------------------------------------------- }

procedure expertReport(p: PShellState);
var
  pE: Psqlite3expert;
  i, nQuery, bVerbose: i32;
  zCand, zSql, zIdx, zEQP: PAnsiChar;
begin
  pE := p^.expertPtr;
  bVerbose := p^.expertVerbose;
  nQuery := sqlite3_expert_count(pE);
  if bVerbose <> 0 then begin
    zCand := sqlite3_expert_report(pE, 0, EXPERT_REPORT_CANDIDATES);
    shellSPutZ('-- Candidates -----------------------------'#10);
    if zCand <> nil then shellSPutZ(AnsiString(zCand) + #10);
  end;
  for i := 0 to nQuery-1 do begin
    zSql := sqlite3_expert_report(pE, i, EXPERT_REPORT_SQL);
    zIdx := sqlite3_expert_report(pE, i, EXPERT_REPORT_INDEXES);
    zEQP := sqlite3_expert_report(pE, i, EXPERT_REPORT_PLAN);
    if zIdx = nil then zIdx := '(no new indexes)'#10;
    if bVerbose <> 0 then
      shellSPutZ(Format('-- Query %d --------------------------------'#10
                       + '%s'#10#10,
                       [i+1, AnsiString(zSql)]));
    shellSPutZ(AnsiString(zIdx) + #10);
    if zEQP <> nil then shellSPutZ(AnsiString(zEQP) + #10);
  end;
end;

function expertFinish(p: PShellState; bCancel: i32;
                      pzErr: PPAnsiChar): i32;
var rc: i32; pE: Psqlite3expert;
begin
  rc := SQLITE_OK;
  pE := p^.expertPtr;
  if bCancel = 0 then begin
    rc := sqlite3_expert_analyze(pE, pzErr);
    if rc = SQLITE_OK then expertReport(p);
  end;
  sqlite3_expert_destroy(pE);
  p^.expertPtr := nil;
  Result := rc;
end;

function expertHandleSQL(p: PShellState; zSql: PAnsiChar;
                         pzErr: PPAnsiChar): i32;
begin
  Result := sqlite3_expert_sql(p^.expertPtr, zSql, pzErr);
end;

procedure cmdExpert(p: PShellState; const args: array of AnsiString;
                    nArg: SizeInt);
var
  i, n, iSample: i32;
  zErr: PAnsiChar;
  z: AnsiString;
begin
  Assert(p^.expertPtr = nil);
  p^.expertVerbose := 0;
  iSample := 0;
  zErr := nil;

  i := 0;
  while i < nArg do begin
    z := args[i];
    if (Length(z) >= 2) and (z[1] = '-') and (z[2] = '-') then
      Delete(z, 1, 1);
    n := Length(z);
    if (n >= 2) and (LeftStr(z, n) = LeftStr('-verbose', n)) then
      p^.expertVerbose := 1
    else if (n >= 2) and (LeftStr(z, n) = LeftStr('-sample', n)) then begin
      if i = nArg-1 then begin
        shellEPutZ('option requires an argument: ' + z + sLineBreak); Exit;
      end;
      Inc(i);
      iSample := StrToIntDef(string(args[i]), 0);
      if (iSample < 0) or (iSample > 100) then begin
        shellEPutZ('value out of range: ' + args[i] + sLineBreak); Exit;
      end;
    end else begin
      shellEPutZ('unknown option: ' + z + sLineBreak); Exit;
    end;
    Inc(i);
  end;

  openDb(p, 0);
  p^.expertPtr := sqlite3_expert_new(p^.db, @zErr);
  if p^.expertPtr = nil then begin
    if zErr <> nil then begin
      shellEPutZ('sqlite3_expert_new: ' + AnsiString(zErr) + sLineBreak);
      sqlite3_free(zErr);
    end else
      shellEPutZ('sqlite3_expert_new: out of memory'#10);
    Exit;
  end;
  sqlite3_expert_config(p^.expertPtr, EXPERT_CONFIG_SAMPLE, iSample);
  if zErr <> nil then sqlite3_free(zErr);
end;

{ ----------------------------------------------------------------------
  10.1.48  `.recover ?OPTS?`  — corruption-recovery dot-command
                                       (shell.c.in:7011..7086)

  Drives the sqlite3_recover_* engine (passqlite3recover) against the
  currently-open database, streaming the recovered CREATE/INSERT script
  to stdout via the SQL callback.  Mirrors the upstream switch matrix:
    --ignore-freelist            (FREELIST_CORRUPT = 0)
    --recovery-db NAME           (op 789 — debug-only ATTACH name)
    --lost-and-found TABLE       (LOST_AND_FOUND = TABLE)
    --no-rowids                  (ROWIDS = 0)
  ---------------------------------------------------------------------- }

function recoverSqlCb(pCtx: Pointer; zSql: PAnsiChar): i32; cdecl;
begin
  { Mirror upstream `cli_printf(pState->out, "%s;\n", zSql);`. }
  if zSql <> nil then begin
    Write(StdOut, AnsiString(zSql));
    Write(StdOut, ';'#10);
  end;
  Result := SQLITE_OK;
end;

{ 10.1.47 — `.session ?NAME? CMD ...` (shell.c.in:10719..10918).

  Session-extension dispatcher.  The session extension itself
  (../sqlite3/ext/session/sqlite3session.c) is not yet ported, so every
  sub-command emits the upstream "session not compiled in" breadcrumb
  via the same idiom the upstream code uses when SQLITE_ENABLE_SESSION
  is undefined: silently no-op the unknown-name fall-through with a
  showHelp-equivalent line.  Once the session extension lands, this
  stub will be expanded into the full attach / changeset / patchset /
  close / enable / filter / indirect / isempty / list / open matrix. }

procedure cmdSession(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt);
begin
  if (p = nil) or (nArg = 0) then
    ;
  if Length(args) > 0 then
    ; { suppress unused-param warning }
  shellEPutZ('Error: session extension not compiled in to this build.'#10);
end;

{ 10.1.38 — `.iotrace FILE|off|on` (shell.c.in:9979..9999).

  The upstream `.iotrace` arm is wrapped in `#ifdef SQLITE_ENABLE_IOTRACE`;
  the standard CLI build leaves the symbol undefined so `.iotrace` falls
  through to the unknown-command tail (`Error: unknown command ... rc=1`).
  Phase 10.1e.11 (TestShellMeta) gates byte-parity against that non-debug
  build, so the port follows suit: doMetaCommand simply does not route
  `iotrace` to a handler, letting it land in the unknown-command arm.
  When SQLITE_ENABLE_IOTRACE support is wired (sqlite3IoTrace sink in
  passqlite3vdbe.pas:4122 is currently a no-op stub) this stub body and
  the dispatch line can be restored together. }

procedure cmdRecover(p: PShellState; const args: array of AnsiString;
                    nArg: SizeInt);
var
  i, n: SizeInt;
  z: AnsiString;
  zRecoveryDb: AnsiString;
  zLAF: AnsiString;
  bFreelist, bRowids: i32;
  zErr: PAnsiChar;
  errCode: i32;
  pRec: Psqlite3_recover;
begin
  zRecoveryDb := '';
  zLAF        := 'lost_and_found';
  bFreelist   := 1;
  bRowids     := 1;

  i := 0;
  while i < nArg do begin
    z := args[i];
    if (Length(z) >= 2) and (z[1] = '-') and (z[2] = '-') then
      Delete(z, 1, 1);
    n := Length(z);
    if (n <= 16) and (LeftStr(z, n) = LeftStr('-ignore-freelist', n)) then
      bFreelist := 0
    else if (n <= 12) and (LeftStr(z, n) = LeftStr('-recovery-db', n))
            and (i < nArg - 1) then
    begin
      Inc(i);
      zRecoveryDb := args[i];
    end
    else if (n <= 15) and (LeftStr(z, n) = LeftStr('-lost-and-found', n))
            and (i < nArg - 1) then
    begin
      Inc(i);
      zLAF := args[i];
    end
    else if (n <= 10) and (LeftStr(z, n) = LeftStr('-no-rowids', n)) then
      bRowids := 0
    else begin
      shellEPutZ('unexpected option: ' + args[i] + sLineBreak);
      Exit;
    end;
    Inc(i);
  end;

  openDb(p, 0);

  pRec := sqlite3_recover_init_sql(p^.db, 'main', @recoverSqlCb, p);
  if pRec = nil then begin
    shellEPutZ('Error: out of memory in .recover'#10);
    Exit;
  end;

  if (p^.bSafeMode = 0) and (zRecoveryDb <> '') then
    sqlite3_recover_config(pRec, 789, PAnsiChar(zRecoveryDb));
  sqlite3_recover_config(pRec, SQLITE_RECOVER_LOST_AND_FOUND,
                         PAnsiChar(zLAF));
  sqlite3_recover_config(pRec, SQLITE_RECOVER_ROWIDS, @bRowids);
  sqlite3_recover_config(pRec, SQLITE_RECOVER_FREELIST_CORRUPT,
                         @bFreelist);

  Write(StdOut, '.dbconfig defensive off'#10);
  sqlite3_recover_run(pRec);
  if sqlite3_recover_errcode(pRec) <> SQLITE_OK then begin
    zErr := sqlite3_recover_errmsg(pRec);
    errCode := sqlite3_recover_errcode(pRec);
    shellEPutZ(Format('sql error: %s (%d)'#10,
                      [AnsiString(zErr), errCode]));
  end;
  sqlite3_recover_finish(pRec);
end;

{ ----------------------------------------------------------------------
  10.1.42  `.selecttrace` / `.wheretrace` / `.treetrace`
                                    — shell.c.in:10711..10716, 12042..

  Both upstream arms unconditionally call
  `sqlite3_test_control(SQLITE_TESTCTRL_TRACEFLAGS, ...)` which in a
  non-debug CLI build is a silent no-op (the C body is wrapped in
  SQLITE_DEBUG / SQLITE_ENABLE_SELECTTRACE / _WHERETRACE).  Upstream
  thus emits nothing on stdout/stderr and returns rc=0 regardless of
  args.  We mirror that exactly so 10.1e.G can byte-diff against the
  reference binary.  When the underlying TRACEFLAGS dispatch is wired
  in a future debug-build profile this stub can install the flag word
  via sqlite3_test_control; until then `silent` is the correct port.
  ---------------------------------------------------------------------- }

procedure cmdTraceFlags(const cmdName: AnsiString;
                        const args: array of AnsiString; nArg: SizeInt);
var
  x: u32;
begin
  { shell.c.in:10711..10716 (.selecttrace/.treetrace, opTrace=1) and
    :12042..12045 (.wheretrace, opTrace=3): if no arg, mask = 0xffffffff
    else integerValue(args[0]).  Pas's sqlite3_test_control(TRACEFLAGS)
    stores the mask in sqlite3TreeTrace / sqlite3WhereTrace; emission
    is still gated on consumer-side WHERETRACE / TREETRACE blocks that
    were skipped during the port (see passqlite3main.pas:4502). }
  if nArg >= 2 then
    x := u32(shellIntegerValue(args[1]))
  else
    x := u32($FFFFFFFF);
  if (cmdName = 'selecttrace') or (cmdName = 'treetrace') then
    sqlite3_test_control(31 { SQLITE_TESTCTRL_TRACEFLAGS }, 1, Pu32(@x))
  else if cmdName = 'wheretrace' then
    sqlite3_test_control(31 { SQLITE_TESTCTRL_TRACEFLAGS }, 3, Pu32(@x));
end;

{ ----------------------------------------------------------------------
  10.1.40  `.testcase NAME` / `.check ANSWER`  — shell.c.in:8718..8904.

  `.testcase NAME` records NAME in p^.zTestcase and arms cli_output_capture
  for the next `.check`.  Our port realises cli_output_capture as an
  fd-level dup2 onto a temp file (same mechanism as cmdOutput); cmdCheck
  reads that file back, compares against PATTERN under the chosen
  comparator (default = strip leading/trailing \r\n then memcmp, --glob,
  --notglob, --exact), and emits the upstream "%s:%lld: .check failed for
  testcase %s\n" diagnostic on mismatch.  On pass the command is silent.
  At process exit shellMain emits the "%d test(s) run with %d error(s)\n"
  summary line (shell.c.in:13657..13662).
  ---------------------------------------------------------------------- }

function tcStashName(p: PShellState; const zName: AnsiString): AnsiString;
{ Truncating snprintf into p^.zTestcase (30 bytes incl. NUL).  Returns the
  effective stored name as AnsiString. }
var i, lim: SizeInt;
begin
  lim := Length(zName);
  if lim > High(p^.zTestcase) then lim := High(p^.zTestcase);
  for i := 1 to lim do p^.zTestcase[i - 1] := AnsiChar(zName[i]);
  p^.zTestcase[lim] := #0;
  SetLength(Result, lim);
  if lim > 0 then Move(p^.zTestcase[0], Result[1], lim);
end;

function tcReadFile(const path: AnsiString): AnsiString;
{ Slurp a captured-output temp file into an AnsiString.  Used by cmdCheck. }
var
  fd: cint;
  buf: array[0..4095] of Byte;
  n: ssize_t;
begin
  Result := '';
  fd := FpOpen(path, O_RDONLY, &644);
  if fd < 0 then Exit;
  repeat
    n := FpRead(fd, buf[0], SizeOf(buf));
    if n > 0 then begin
      SetLength(Result, Length(Result) + n);
      Move(buf[0], Result[Length(Result) - n + 1], n);
    end;
  until n <= 0;
  FpClose(fd);
end;

procedure tcArmCapture(p: PShellState);
{ Mirror C dotCmdTestcase's output_reset + cli_output_capture rearm: drop
  any prior capture file, then dup2 a fresh temp file onto fd 1 so all
  subsequent stdout writes accumulate there. }
var
  fname: AnsiString;
begin
  if gTcCapturing then begin
    outputReset(p);
    if gTcCaptureFile <> '' then FpUnlink(gTcCaptureFile);
    gTcCaptureFile := '';
    gTcCapturing := False;
  end else begin
    outputReset(p);
  end;
  fname := SysUtils.GetTempDir(False) + 'pas_tc_' + IntToStr(FpGetPid) +
           '_' + IntToStr(p^.lineno) + '.out';
  if outputRedirectFile(fname, nil) then begin
    gTcCapturing := True;
    gTcCaptureFile := fname;
    { Hide from .show: this is internal capture, not a user .output target. }
    p^.zOutfile[0] := #0;
  end;
end;

function cmdTestcase(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt): i32;
{ shell.c.in:8868..8904.  We accept the same NAME-only form; --error-prefix
  is parsed and stored on p^.zErrPrefix for parity, otherwise the single
  positional is the testcase name.  When omitted, NAME defaults to
  "<file>:<lineno>" per the C snprintf fallback. }
var
  zName: AnsiString;
  i: SizeInt;
  haveName: Int32;
  z: AnsiString;
begin
  Result := 0;
  haveName := 0;
  zName := '';
  i := 0;
  while i < nArg do begin
    z := args[i];
    if (Length(z) >= 3) and (z[1] = '-') and (z[2] = '-') then
      z := Copy(z, 2, MaxInt);
    if z = '-error-prefix' then begin
      if i + 1 >= nArg then begin
        { shell.c.in:8879 — dotCmdError(p, i, "missing argument", 0). }
        shellDotError(p, i32(i) + 1, 'missing argument', '');
        Result := 1; Exit;
      end;
      Inc(i);
      if args[i] = '' then begin
        gErrPrefixBacking := '';
        p^.zErrPrefix := nil;
      end else begin
        gErrPrefixBacking := args[i];
        p^.zErrPrefix := PAnsiChar(gErrPrefixBacking);
      end;
    end else if haveName <> 0 then begin
      { shell.c.in:8886 — dotCmdError(p, i, "unknown option", 0). }
      shellDotError(p, i32(i) + 1, 'unknown option', '');
      Result := 1; Exit;
    end else begin
      zName := args[i];
      haveName := 1;
    end;
    Inc(i);
  end;
  if haveName = 0 then begin
    if p^.zInFile <> nil then
      zName := Format('%s:%d', [AnsiString(p^.zInFile), p^.lineno])
    else
      zName := Format(':%d', [p^.lineno]);
  end;
  tcStashName(p, zName);
  tcArmCapture(p);
end;

function tcGlobMatch(const zPattern, zText: AnsiString): Int32;
{ Mirrors testcase_glob via sqlite3_strglob.  Returns 1 on match. }
var pat: AnsiString;
begin
  pat := '*' + zPattern + '*';
  if sqlite3_strglob(PAnsiChar(pat), PAnsiChar(zText)) = 0 then
    Result := 1
  else
    Result := 0;
end;

function tcDefaultCompare(const zPattern, zText: AnsiString): Int32;
{ Default comparator: strip leading/trailing CR/LF on both sides then
  memcmp.  shell.c.in:8825..8836. }
var
  s1, e1, s2, e2: SizeInt;
begin
  s1 := 1; e1 := Length(zPattern);
  while (s1 <= e1) and ((zPattern[s1] = #10) or (zPattern[s1] = #13)) do Inc(s1);
  while (e1 >= s1) and ((zPattern[e1] = #10) or (zPattern[e1] = #13)) do Dec(e1);
  s2 := 1; e2 := Length(zText);
  while (s2 <= e2) and ((zText[s2] = #10) or (zText[s2] = #13)) do Inc(s2);
  while (e2 >= s2) and ((zText[e2] = #10) or (zText[e2] = #13)) do Dec(e2);
  if (e1 - s1) <> (e2 - s2) then Exit(0);
  if e1 < s1 then Exit(1);
  if CompareByte(zPattern[s1], zText[s2], e1 - s1 + 1) = 0 then
    Result := 1
  else
    Result := 0;
end;

function cmdCheck(p: PShellState; const args: array of AnsiString;
                  nArg: SizeInt): i32;
{ shell.c.in:8737..8855 dotCmdCheck.  Supports: --keep, --show, --glob,
  --notglob, --exact, plus the bare-default comparator.  PATTERN is the
  first non-option positional.  The "<<ENDMARK" multi-line PATTERN form
  (shell.c.in:8790..8802) reads subsequent REPL lines via oneInputLine
  and appends each (with its consumed newline restored) until a line
  whose first nCheck-2 bytes match the marker.  EOF without marker is
  silently accepted, matching upstream. }
var
  i: SizeInt;
  z, zCheck, zPattern, zTest, zHereLine: AnsiString;
  bKeep, eCheck, isOk, sawZCheck: Int32;
  iStart: i64;
  testcaseName: AnsiString;
  pchLen, nMark: SizeInt;
  zMark: AnsiString;
  hereEof: Boolean;
begin
  Result := 0;
  iStart := p^.lineno;
  if p^.zTestcase[0] = #0 then begin
    { Upstream shell.c.in:8751 — `dotCmdError(p, 0, "no .testcase is active", 0);` }
    shellDotError(p, 0, 'no .testcase is active', '');
    Result := 1;
    Exit;
  end;
  bKeep := 0;
  eCheck := 0;
  sawZCheck := 0;
  zCheck := '';
  i := 0;
  while i < nArg do begin
    z := args[i];
    if (Length(z) >= 3) and (z[1] = '-') and (z[2] = '-') then
      z := Copy(z, 2, MaxInt);
    if z = '-keep' then bKeep := 1
    else if z = '-show' then begin
      { Mirror the C --show: dump current capture to stdout (which is
        still the captured fd here) and implicitly --keep. }
      if gTcCapturing and (gTcCaptureFile <> '') then begin
        Flush(Output);
        { Write to the real stdout via stderr-like helper would mix
          streams; the C code emits via cli_printf(stdout,...) which
          here is the captured fd.  Do the same for byte parity. }
        shellSPutZ(tcReadFile(gTcCaptureFile));
      end;
      bKeep := 1;
    end else if z = '-glob' then begin
      if (eCheck <> 0) and (eCheck <> 1) then begin
        { shell.c.in:8768 — dotCmdError(p, i, "incompatible with prior options", 0). }
        shellDotError(p, i32(i) + 1, 'incompatible with prior options', '');
        Result := 1; Exit;
      end;
      eCheck := 1;
    end else if z = '-notglob' then begin
      if (eCheck <> 0) and (eCheck <> 2) then begin
        shellDotError(p, i32(i) + 1, 'incompatible with prior options', '');
        Result := 1; Exit;
      end;
      eCheck := 2;
    end else if z = '-exact' then begin
      if (eCheck <> 0) and (eCheck <> 3) then begin
        shellDotError(p, i32(i) + 1, 'incompatible with prior options', '');
        Result := 1; Exit;
      end;
      eCheck := 3;
    end else if sawZCheck <> 0 then begin
      { shell.c.in:8773 — dotCmdError(p, i, "unknown option", 0). }
      shellDotError(p, i32(i) + 1, 'unknown option', '');
      Result := 1; Exit;
    end else begin
      zCheck := args[i];
      sawZCheck := 1;
    end;
    Inc(i);
  end;
  if sawZCheck = 0 then begin
    { Upstream `dotCmdError(p, 0, "no PATTERN specified", 0);` (shell.c.in
      :8775 equivalent).  iArg=0 caret block fires only when nArg>0. }
    shellDotError(p, 0, 'no PATTERN specified', '');
    Result := 1; Exit;
  end;

  { Flush captured output before reading the file back. }
  Flush(Output);
  if gTcCapturing and (gTcCaptureFile <> '') then
    zTest := tcReadFile(gTcCaptureFile)
  else
    zTest := '';

  Inc(p^.nTestRun);
  { 10.1.40.b — `<<MARK` heredoc PATTERN form (shell.c.in:8790..8802).
    When zCheck begins with `<<` and has more chars, the literal text
    after `<<` is the marker (no whitespace stripping); read script
    lines via oneInputLine, append each followed by '\n' (oneInputLine
    strips the terminator), and stop when a line's first nMark bytes
    match the marker — that line is consumed but NOT appended.  EOF
    without marker is silently accepted (upstream just exits the
    while-loop without diagnostic). }
  if (Length(zCheck) >= 3) and (zCheck[1] = '<') and (zCheck[2] = '<') then begin
    nMark := Length(zCheck) - 2;
    zMark := Copy(zCheck, 3, nMark);
    zPattern := '';
    hereEof := False;
    while True do begin
      zHereLine := oneInputLine(p, False, hereEof);
      if hereEof then Break;
      Inc(p^.lineno);
      if (Length(zHereLine) >= nMark)
         and (CompareByte(zHereLine[1], zMark[1], nMark) = 0) then
        Break;
      zPattern := zPattern + zHereLine + #10;
    end;
  end else
    zPattern := zCheck;
  case eCheck of
    1: isOk := tcGlobMatch(zPattern, zTest);
    2: if tcGlobMatch(zPattern, zTest) = 0 then isOk := 1 else isOk := 0;
    3: if zPattern = zTest then isOk := 1 else isOk := 0;
  else
    isOk := tcDefaultCompare(zPattern, zTest);
  end;

  if isOk = 0 then begin
    pchLen := 0;
    while (pchLen < High(p^.zTestcase)) and (p^.zTestcase[pchLen] <> #0) do
      Inc(pchLen);
    SetLength(testcaseName, pchLen);
    if pchLen > 0 then Move(p^.zTestcase[0], testcaseName[1], pchLen);
    Inc(p^.nTestErr);
    { Restore stdout so the failure diagnostic goes to the real stderr;
      the comparator file stays on disk until outputReset below. }
    shellEPutZ(Format('%s:%d: .check failed for testcase %s'#10,
      [AnsiString(p^.zInFile), iStart, testcaseName]));
    shellEPutZ(Format('Expected: [%s]'#10, [zPattern]));
    shellEPutZ(Format('Got:      [%s]'#10, [zTest]));
  end;

  if bKeep = 0 then begin
    outputReset(p);
    if gTcCaptureFile <> '' then FpUnlink(gTcCaptureFile);
    gTcCaptureFile := '';
    gTcCapturing := False;
    p^.zTestcase[0] := #0;
  end;
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
  { Mirrors aDbConfig[] in shell.c.in:9280 exactly: same names, same order,
    same opcodes.  All boolean ops route through sqlite3_db_config_int's
    dbConfigFlagOp dispatcher; FP_DIGITS routes through the counter path in
    sqlite3_db_config_int (passqlite3main.pas:1846).  Counter/pointer-style
    ops (LOOKASIDE, MAINDBNAME, MAX_*) remain gated on Phase 8.1.1's raw
    varargs and are not exposed here. }
  aDbConfig: array[0..21] of TDbcfgEntry = (
    (zName: 'attach_create';      op: SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE),
    (zName: 'attach_write';       op: SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE),
    (zName: 'comments';           op: SQLITE_DBCONFIG_ENABLE_COMMENTS),
    (zName: 'defensive';          op: SQLITE_DBCONFIG_DEFENSIVE),
    (zName: 'dqs_ddl';            op: SQLITE_DBCONFIG_DQS_DDL),
    (zName: 'dqs_dml';            op: SQLITE_DBCONFIG_DQS_DML),
    (zName: 'enable_fkey';        op: SQLITE_DBCONFIG_ENABLE_FKEY),
    (zName: 'enable_qpsg';        op: SQLITE_DBCONFIG_ENABLE_QPSG),
    (zName: 'enable_trigger';     op: SQLITE_DBCONFIG_ENABLE_TRIGGER),
    (zName: 'enable_view';        op: SQLITE_DBCONFIG_ENABLE_VIEW),
    (zName: 'fts3_tokenizer';     op: SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER),
    (zName: 'fp_digits';          op: SQLITE_DBCONFIG_FP_DIGITS),
    (zName: 'legacy_alter_table'; op: SQLITE_DBCONFIG_LEGACY_ALTER_TABLE),
    (zName: 'legacy_file_format'; op: SQLITE_DBCONFIG_LEGACY_FILE_FORMAT),
    (zName: 'load_extension';     op: SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION),
    (zName: 'no_ckpt_on_close';   op: SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE),
    (zName: 'reset_database';     op: SQLITE_DBCONFIG_RESET_DATABASE),
    (zName: 'reverse_scanorder';  op: SQLITE_DBCONFIG_REVERSE_SCANORDER),
    (zName: 'stmt_scanstatus';    op: SQLITE_DBCONFIG_STMT_SCANSTATUS),
    (zName: 'trigger_eqp';        op: SQLITE_DBCONFIG_TRIGGER_EQP),
    (zName: 'trusted_schema';     op: SQLITE_DBCONFIG_TRUSTED_SCHEMA),
    (zName: 'writable_schema';    op: SQLITE_DBCONFIG_WRITABLE_SCHEMA)
  );

procedure cmdDbconfig(p: PShellState; const args: array of AnsiString;
                      nArg: SizeInt);
var
  i: SizeInt;
  v, setVal: i32;
  err: i32;
  matched: Boolean;
begin
  openDb(p, 0);
  if p^.db = nil then Exit;
  matched := False;
  for i := 0 to High(aDbConfig) do begin
    if (nArg >= 1) and (args[0] <> aDbConfig[i].zName) then Continue;
    matched := True;
    if nArg >= 2 then begin
      if aDbConfig[i].op = SQLITE_DBCONFIG_FP_DIGITS then begin
        Val(args[1], setVal, err);
        if err <> 0 then setVal := 0;
        sqlite3_db_config_int(p^.db, aDbConfig[i].op, setVal, nil);
      end else
        sqlite3_db_config_int(p^.db, aDbConfig[i].op,
                              parseOnOff(args[1], 0), nil);
    end;
    v := -1;
    sqlite3_db_config_int(p^.db, aDbConfig[i].op, -1, @v);
    if aDbConfig[i].op = SQLITE_DBCONFIG_FP_DIGITS then
      WriteLn(Format('%19s %d', [aDbConfig[i].zName, v]))
    else
      WriteLn(Format('%19s %s', [aDbConfig[i].zName,
                                 IfThen(v <> 0, 'on', 'off')]));
    if nArg >= 1 then Break;
  end;
  if (nArg >= 1) and (not matched) then
    shellEPutZ(Format('Error: unknown dbconfig "%s"'#10 +
                      'Enter ".dbconfig" with no arguments for a list'#10,
                      [args[0]]));
end;

{ ----------------------------------------------------------------------
  10.1.39 (partial)  `.scanstats on|off|est|vm`  — shell.c.in:10545..

  The Pascal sqlite3_db_config_int dispatcher does not yet recognise
  SQLITE_DBCONFIG_STMT_SCANSTATUS, so we record the mode locally and
  emit upstream's "not available in this build" warning.
  ---------------------------------------------------------------------- }

function cmdScanstats(p: PShellState; const args: array of AnsiString;
                      nArg: SizeInt): i32;
begin
  Result := 0;
  if nArg <> 1 then begin
    shellEPutZ('Usage: .scanstats on|off|est'#10);
    Result := 1;
    Exit;
  end;
  if args[0] = 'vm' then p^.mode.scanstatsOn := 3
  else if args[0] = 'est' then p^.mode.scanstatsOn := 2
  else p^.mode.scanstatsOn := u8(parseOnOff(args[0], 0));
  { Phase 8.2.1 — open the connection first (shell.c.in:10558
    open_db(p,0)), then toggle the per-connection STMT_SCANSTATUS flag
    so sqlite3VdbeScanStatus* populate aScan[]. }
  if p^.db = nil then openDb(p, 0);
  if p^.db <> nil then
    sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_STMT_SCANSTATUS,
                          i32(p^.mode.scanstatsOn <> 0), nil);
  { Echo the upstream non-debug-build warning verbatim so meta-text diff
    against the reference C shell stays clean — TestShellMeta gates on
    this exact string.  The data path is wired regardless (see
    displayScanstats called at end-of-statement). }
  shellEPutZ('Warning: .scanstats not available in this build.'#10);
end;

{ 10.1.39.c — qrfEqpStats EQP-tree formatter port from
  ext/qrf/qrf.c:162..454.  Builds an in-memory linked list of
  (iEqpId, iParentId, text) rows by walking the prepared
  statement's scanstatus_v2 entries, then renders them as an
  indented EQP tree with `|--` / ``--` connectors.  Rows on each
  loop are stamped with NLOOP and NVISIT counts via qrfApproxInt64
  (`%4d ` for N<10000, otherwise three-significant-digit suffix
  K/M/G/T/P/E).  NCYCLE / `est`-variant numerics deferred (the
  hwtime sampler is task 10.1.39.d); `.scanstats vm` falls through
  to a stub.  Output goes to stdout via shellSPutZ.

  C reference: ext/qrf/qrf.c
    qrfEqpAppend (162..190), qrfEqpReset (196..206), qrfEqpNextRow
    (211..215), qrfEqpRenderLevel (220..235), qrfApproxInt64
    (244..274), qrfStatsHeight (325..349), qrfEqpStats (356..454).
}
type
  PEqpRow  = ^TEqpRow;
  TEqpRow  = record
    iEqpId:    i32;
    iParentId: i32;
    pNext:     PEqpRow;
    zText:     AnsiString;
  end;
  PEqpGraph = ^TEqpGraph;
  TEqpGraph = record
    pRow:    PEqpRow;
    pLast:   PEqpRow;
    nWidth:  i32;
    zPrefix: array[0..255] of AnsiChar;
  end;

var
  gEqpGraph: PEqpGraph = nil;
  gEqpOut:   AnsiString;

procedure qrfEqpReset; forward;

procedure qrfEqpAppend(iEqpId, p2: i32; const zText: AnsiString);
{ qrf.c:162..190 — append (iEqpId, p2, zText) to the EQP graph;
  allocates the graph on first call. }
var pNew: PEqpRow;
begin
  if zText = '' then Exit;
  if gEqpGraph = nil then
  begin
    New(gEqpGraph);
    gEqpGraph^.pRow := nil;
    gEqpGraph^.pLast := nil;
    gEqpGraph^.nWidth := 0;
    gEqpGraph^.zPrefix[0] := #0;
  end;
  pNew := System.GetMem(SizeOf(TEqpRow));
  FillChar(pNew^, SizeOf(TEqpRow), 0);
  pNew^.iEqpId    := iEqpId;
  pNew^.iParentId := p2;
  pNew^.zText     := zText;
  pNew^.pNext     := nil;
  if gEqpGraph^.pLast <> nil then
    gEqpGraph^.pLast^.pNext := pNew
  else
    gEqpGraph^.pRow := pNew;
  gEqpGraph^.pLast := pNew;
end;

procedure qrfEqpReset;
{ qrf.c:196..206. }
var pRow, pNext: PEqpRow;
begin
  if gEqpGraph = nil then Exit;
  pRow := gEqpGraph^.pRow;
  while pRow <> nil do
  begin
    pNext := pRow^.pNext;
    pRow^.zText := '';     { release ref-count before FreeMem }
    System.FreeMem(pRow);
    pRow := pNext;
  end;
  Dispose(gEqpGraph);
  gEqpGraph := nil;
end;

function qrfEqpNextRow(iEqpId: i32; pOld: PEqpRow): PEqpRow;
{ qrf.c:211..215. }
var pRow: PEqpRow;
begin
  if pOld <> nil then pRow := pOld^.pNext
  else if gEqpGraph <> nil then pRow := gEqpGraph^.pRow
  else pRow := nil;
  while (pRow <> nil) and (pRow^.iParentId <> iEqpId) do
    pRow := pRow^.pNext;
  Result := pRow;
end;

procedure qrfEqpRenderLevel(iEqpId: i32);
{ qrf.c:220..235. }
var
  pRow, pNext: PEqpRow;
  n:           i32;
  connector:   PAnsiChar;
  prefixLen:   i32;
begin
  if gEqpGraph = nil then Exit;
  n := i32(CStrLen(@gEqpGraph^.zPrefix[0]));
  pRow := qrfEqpNextRow(iEqpId, nil);
  while pRow <> nil do
  begin
    pNext := qrfEqpNextRow(iEqpId, pRow);
    if pNext <> nil then connector := '|--' else connector := '`--';
    gEqpOut := gEqpOut + AnsiString(@gEqpGraph^.zPrefix[0])
                       + AnsiString(connector) + pRow^.zText + #10;
    prefixLen := i32(SizeOf(gEqpGraph^.zPrefix));
    if n < prefixLen - 7 then
    begin
      if pNext <> nil then
      begin
        gEqpGraph^.zPrefix[n]   := '|';
        gEqpGraph^.zPrefix[n+1] := ' ';
        gEqpGraph^.zPrefix[n+2] := ' ';
      end else begin
        gEqpGraph^.zPrefix[n]   := ' ';
        gEqpGraph^.zPrefix[n+1] := ' ';
        gEqpGraph^.zPrefix[n+2] := ' ';
      end;
      gEqpGraph^.zPrefix[n+3] := #0;
      qrfEqpRenderLevel(pRow^.iEqpId);
      gEqpGraph^.zPrefix[n] := #0;
    end;
    pRow := pNext;
  end;
end;

function qrfApproxInt64(N: i64): AnsiString;
{ qrf.c:244..274 — 16-char approx decimal.  N<10000 → "%4d "; else
  three-significant-digit form with K/M/G/T/P/E suffix. }
const aSuffix: array[0..5] of AnsiChar = ('K','M','G','T','P','E');
var
  prefix: AnsiString;
  ii:     i32;
  n2:     i32;
begin
  prefix := '';
  if N < 0 then
  begin
    if N = Low(i64) then N := High(i64) else N := -N;
    prefix := '-';
  end;
  if N < 10000 then
  begin
    Result := prefix + Format('%4d ', [Int64(N)]);
    Exit;
  end;
  Result := prefix;
  for ii := 1 to 18 do
  begin
    N := (N + 5) div 10;
    if N < 10000 then
    begin
      n2 := i32(N);
      case ii mod 3 of
        0: Result := Result + Format('%d.%.2d', [n2 div 1000, (n2 mod 1000) div 10]);
        1: Result := Result + Format('%2d.%d',  [n2 div 100,  (n2 mod 100)  div 10]);
        2: Result := Result + Format('%4d',     [n2 div 10]);
      end;
      Result := Result + aSuffix[ii div 3];
      break;
    end;
  end;
end;

function qrfStatsHeight(pStmt: Pointer; iEntry: i32): i32;
{ qrf.c:325..349 — walk PARENTID chain via SELECTID lookup. }
const f = 0;  { Not SCANSTAT_COMPLEX — matches upstream skip-zName=nil semantics
                in vdbeapi.c:2501..2509 so we iterate only top-level loop entries. }
var
  iPid, iId, res: i32;
  ii: i32;
begin
  iPid := 0;
  Result := 1;
  sqlite3_stmt_scanstatus_v2(pStmt, iEntry, SQLITE_SCANSTAT_SELECTID, f, @iPid);
  while iPid <> 0 do
  begin
    ii := 0;
    while True do
    begin
      iId := 0;
      res := sqlite3_stmt_scanstatus_v2(pStmt, ii, SQLITE_SCANSTAT_SELECTID, f, @iId);
      if res <> 0 then break;
      if iId = iPid then
        sqlite3_stmt_scanstatus_v2(pStmt, ii, SQLITE_SCANSTAT_PARENTID, f, @iPid);
      Inc(ii);
    end;
    Inc(Result);
  end;
end;

{ 10.1.39.c — main displayScanstats entry: ports ext/qrf/qrf.c
  qrfEqpStats (qrf.c:356..454) for the non-NCYCLE (.scanstats on)
  case.  NCYCLE arms (SQLITE_SCANSTAT_NCYCLE) report -1 in our
  build so the `if( nCycle>=0 || nLoop>=0 || nRow>=0 )` gate always
  enters the formatted path through nLoop / nRow.  After building
  the row list we prepend the "QUERY PLAN\n" header (no nCycle
  banner) and recursively render from iEqpId=0. }
procedure displayScanstats(p: PShellState; pStmt: Pointer);
const f = 0;  { Not SCANSTAT_COMPLEX — matches upstream skip-zName=nil semantics
                in vdbeapi.c:2501..2509 so we iterate only top-level loop entries. }
var
  i:        i32;
  nLoop:    i64;
  nRow:     i64;
  nCycle:   i64;
  iId:      i32;
  iPid:     i32;
  zo:       PAnsiChar;
  zName:    PAnsiChar;
  rEst:     Double;
  nWidth:   i32;
  n:        i32;
  stats:    AnsiString;
  line:     AnsiString;
  nSp:      i32;
  padCnt:   i32;
  zoStr:    AnsiString;
begin
  if (pStmt = nil) or (p^.mode.scanstatsOn = 0) then Exit;

  { First pass — compute nWidth = max(strlen(zExplain) +
    qrfStatsHeight*3) + 2. }
  nWidth := 0;
  i := 0;
  while i < 256 do  { hard safety cap }
  begin
    zo := nil;
    if sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_EXPLAIN, f, @zo) <> 0 then
      break;
    { 10.1.39.e — prefer EXPLAIN-string width (now p4type-gated in the
      v2 reader) and fall back to "SCAN <zName>" width otherwise. }
    zName := nil;
    sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_NAME, f, @zName);
    if (zo <> nil) and (CStrLen(zo) < 1024) then
      n := i32(CStrLen(zo)) + qrfStatsHeight(pStmt, i) * 3
    else if (zName <> nil) and (CStrLen(zName) < 1024) then
      n := i32(CStrLen(zName)) + 5 { "SCAN " } + qrfStatsHeight(pStmt, i) * 3
    else
      n := qrfStatsHeight(pStmt, i) * 3;
    if n > nWidth then nWidth := n;
    Inc(i);
  end;
  Inc(nWidth, 2);

  { Aggregate NCYCLE (iScan=-1).  Currently always -1 here. }
  nCycle := 0;
  sqlite3_stmt_scanstatus_v2(pStmt, -1, SQLITE_SCANSTAT_NCYCLE, f, @nCycle);
  if nCycle < 0 then nCycle := 0;

  { Second pass — append rows. }
  i := 0;
  while i < 256 do  { hard safety cap }
  begin
    zo := nil;
    if sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_EXPLAIN, f, @zo) <> 0 then
      break;
    nLoop := -1; nRow := -1; iId := 0; iPid := 0; rEst := 0.0; zName := nil;
    sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_PARENTID, f, @iPid);
    sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_EST,      f, @rEst);
    sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_NLOOP,    f, @nLoop);
    sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_NVISIT,   f, @nRow);
    sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_SELECTID, f, @iId);
    sqlite3_stmt_scanstatus_v2(pStmt, i, SQLITE_SCANSTAT_NAME,     f, @zName);

    { 10.1.39.e — SCANSTAT_EXPLAIN now gates on p4type=P4_DYNAMIC
      (passqlite3main.pas:SQLITE_SCANSTAT_EXPLAIN), so the raw EXPLAIN
      string is safe to consume here.  Upstream qrf.c:312 prefers the
      EXPLAIN-string label ("SCAN t1 USING INDEX i1") over the bare
      table/index name; fall back to "SCAN <zName>" only when the
      addrExplain stamp is missing or p4type is non-DYNAMIC. }
    zoStr := '';
    if (zo <> nil) and (CStrLen(zo) > 0) and (CStrLen(zo) < 1024) then
      zoStr := AnsiString(zo)
    else if (zName <> nil) and (CStrLen(zName) > 0) and (CStrLen(zName) < 1024) then
      zoStr := 'SCAN ' + AnsiString(zName);

    if (nLoop >= 0) or (nRow >= 0) then
    begin
      stats := '';
      nSp := 0;
      if nLoop >= 0 then
      begin
        stats := stats + qrfApproxInt64(nLoop);
        nSp := 2;
      end;
      if nRow >= 0 then
      begin
        if nSp > 0 then stats := stats + StringOfChar(' ', nSp);
        stats := stats + qrfApproxInt64(nRow);
      end;
      padCnt := nWidth - qrfStatsHeight(pStmt, i) * 3 - i32(Length(zoStr));
      if padCnt < 1 then padCnt := 1;
      line := zoStr + StringOfChar(' ', padCnt) + stats;
      qrfEqpAppend(iId, iPid, line);
    end else
      qrfEqpAppend(iId, iPid, zoStr);

    Inc(i);
  end;

  { Render — qrf.c:312 "QUERY PLAN\n" header for the non-NCYCLE case,
    then qrfEqpRenderLevel(0). }
  if gEqpGraph <> nil then
  begin
    gEqpOut := '';
    gEqpOut := gEqpOut + 'QUERY PLAN'#10;
    gEqpGraph^.zPrefix[0] := #0;
    qrfEqpRenderLevel(0);
    shellSPutZ(gEqpOut);
    gEqpOut := '';
    qrfEqpReset;
  end;
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

  Bind-parameter table lives in TEMP.sqlite_parameters; mirror the
  upstream bind_table_init (shell.c.in:2964) by toggling
  WRITABLE_SCHEMA on around the CREATE so the reserved "sqlite_"
  prefix is accepted, then restoring the prior setting. }

procedure paramTableInit(p: PShellState);
const
  zCreate: PAnsiChar =
    'CREATE TABLE IF NOT EXISTS temp.sqlite_parameters('#10 +
    '  key TEXT PRIMARY KEY,'#10 +
    '  value'#10 +
    ') WITHOUT ROWID;';
var
  wrSchema: i32;
begin
  if p^.db = nil then Exit;
  wrSchema := 0;
  sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_WRITABLE_SCHEMA, -1, @wrSchema);
  sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_WRITABLE_SCHEMA,  1, nil);
  sqlite3_exec(p^.db, zCreate, nil, nil, nil);
  sqlite3_db_config_int(p^.db, SQLITE_DBCONFIG_WRITABLE_SCHEMA, wrSchema, nil);
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
    { 10.1.24.a — heredoc input buffer.  When zIn<>nil importGetc reads
      from it instead of inHandle; sqlite3_free()'d by importCleanup.
      Mirrors C ImportCtx.zIn (shell.c.in:6788..6789). }
    zIn:       PAnsiChar;
    zInCur:    PAnsiChar;
    { 10.1.24.b — pipe input arm.  When pipeOpen=True importGetc reads
      from pipeFile (a libc FILE* returned by popen); importCleanup
      pcloses it.  Mirrors C ImportCtx.in + xCloser=pclose
      (shell.c.in:7593..7600). }
    pipeFile:  Pointer;
    pipeOpen:  Boolean;
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
  { 10.1.24.b — pclose() the popen()'d pipe.  Mirrors C xCloser=pclose
    invocation in import_cleanup (shell.c.in:6810..6814). }
  if p.pipeOpen then begin
    shellLibcPClose(p.pipeFile);
    p.pipeOpen := False;
    p.pipeFile := nil;
  end;
  if p.zIn <> nil then begin
    sqlite3_free(p.zIn);
    p.zIn    := nil;
    p.zInCur := nil;
  end;
  p.z := '';
  p.bufPos := 0;
  p.bufLen := 0;
end;

function importGetc(var p: TImportCtx): i32;
var n: SizeInt; c: Byte;
begin
  { 10.1.24.a — heredoc arm: drain the in-memory buffer first. }
  if p.zInCur <> nil then begin
    c := Byte(p.zInCur^);
    if c = 0 then begin
      Result := IMPORT_EOF;
      Exit;
    end;
    Inc(p.zInCur);
    Result := i32(c);
    Exit;
  end;
  if p.bufPos >= p.bufLen then begin
    if p.atEof then begin Result := IMPORT_EOF; Exit; end;
    { 10.1.24.b — pipe arm reads via libc fread() against the popen'd
      FILE*; everything else still uses the FpRead/inHandle path. }
    if p.pipeOpen then
      n := SizeInt(shellLibcFRead(@p.buf[0], 1, PtrUInt(SizeOf(p.buf)),
                                  p.pipeFile))
    else
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

{ ----------------------------------------------------------------------
  Faithful port of shell.c.in:7165..7339 zAutoColumn.  Maintains a
  scratch :memory: database holding incoming column-name strings, then
  emits a deduplicated parenthesised column list ("col1" ANY, "col2"
  ANY, ...) for CREATE TABLE.  Two operating modes:

    pDb=nil + zColNew non-empty → init scratch db, insert column.
    pDb<>nil + zColNew='' (collect) → emit column spec, close db.

  The SQL bodies match upstream verbatim (RENAME_MINIMAL_ONE_PASS arm;
  SHELL_COLUMN_RENAME_CLEAN is not defined in upstream's default build).
  zRenamed receives the human-readable list of renames done (empty when
  no duplicates were resolved).
  ====================================================================== }
function shellAutoColumnAdd(var pDb: PTsqlite3;
  const zColNew: AnsiString): i32;
const
  zTabMake: PAnsiChar =
    'CREATE TABLE ColNames(' +
    ' cpos INTEGER PRIMARY KEY,' +
    ' name TEXT, nlen INT, chop INT, reps INT, suff TEXT);' +
    'CREATE VIEW RepeatedNames AS' +
    ' SELECT DISTINCT t.name FROM ColNames t' +
    ' WHERE t.name COLLATE NOCASE IN (' +
    '  SELECT o.name FROM ColNames o WHERE o.cpos<>t.cpos);';
  zTabFill: PAnsiChar =
    'INSERT INTO ColNames(name,nlen,chop,reps,suff)' +
    ' VALUES(iif(length(?1)>0,?1,''?''),max(length(?1),1),0,0,'''')';
var
  rc:    i32;
  pStmt: PVdbe;
  pTail: PAnsiChar;
begin
  pStmt := nil; pTail := nil;
  if pDb = nil then begin
    rc := sqlite3_open(':memory:', @pDb);
    if rc <> SQLITE_OK then begin
      if pDb <> nil then sqlite3_close(pDb);
      pDb := nil;
      Exit(rc);
    end;
    rc := sqlite3_exec(pDb, zTabMake, nil, nil, nil);
    if rc <> SQLITE_OK then Exit(rc);
  end;
  rc := sqlite3_prepare_v2(pDb, zTabFill, -1, @pStmt, @pTail);
  if rc <> SQLITE_OK then begin
    if pStmt <> nil then sqlite3_finalize(pStmt);
    Exit(rc);
  end;
  sqlite3_bind_text(pStmt, 1, PAnsiChar(zColNew), Length(zColNew),
                    SQLITE_TRANSIENT);
  sqlite3_step(pStmt);
  sqlite3_finalize(pStmt);
  Result := SQLITE_OK;
end;

function shellAutoColumnFinish(var pDb: PTsqlite3;
  out zRenamed: AnsiString): AnsiString;
const
  zHasDupes: PAnsiChar =
    'SELECT count(DISTINCT (substring(name,1,nlen-chop)||suff)' +
    ' COLLATE NOCASE)<count(name) FROM ColNames';
  zColDigits: PAnsiChar =
    'SELECT CAST(ceil(log(count(*)+0.5)) AS INT) FROM ColNames';
  zSetReps: PAnsiChar =
    'UPDATE ColNames AS t SET reps=' +
    '(SELECT count(*) FROM ColNames d' +
    ' WHERE substring(t.name,1,t.nlen-t.chop)' +
    '=substring(d.name,1,d.nlen-d.chop) COLLATE NOCASE)';
  zRenameRank: PAnsiChar =
    'WITH Lzn(nlz) AS (' +
    '  SELECT 0 AS nlz UNION' +
    '  SELECT nlz+1 AS nlz FROM Lzn WHERE EXISTS(' +
    '   SELECT 1 FROM ColNames t, ColNames o WHERE' +
    '    iif(t.name IN (SELECT * FROM RepeatedNames),' +
    '     printf(''%s_%s'',t.name,' +
    '      substring(printf(''%.*c%0.*d'',nlz+1,''0'',?1,t.cpos),2)),' +
    '     t.name)' +
    '    =' +
    '    iif(o.name IN (SELECT * FROM RepeatedNames),' +
    '     printf(''%s_%s'',o.name,' +
    '      substring(printf(''%.*c%0.*d'',nlz+1,''0'',?1,o.cpos),2)),' +
    '     o.name)' +
    '    COLLATE NOCASE AND o.cpos<>t.cpos GROUP BY t.cpos))' +
    ' UPDATE ColNames AS t SET' +
    '  chop = 0,' +
    '  suff = iif(name IN (SELECT * FROM RepeatedNames),' +
    '   printf(''_%s'', substring(' +
    '    printf(''%.*c%0.*d'',(SELECT max(nlz) FROM Lzn)+1,''0'',1,t.cpos),' +
    '    2)),'' '')';
  zCollectVar: PAnsiChar =
    'SELECT ''(''||x''0a''' +
    ' || group_concat(' +
    '  cname||'' ANY'',' +
    '  '',''||iif((cpos-1)%4>0, '' '', x''0a''||'' ''))' +
    ' ||'')'' AS ColsSpec FROM (' +
    ' SELECT cpos, printf(''"%w"'',printf(''%!.*s%s'',nlen-chop,name,suff))' +
    ' AS cname FROM ColNames ORDER BY cpos)';
  zRenamesDone: PAnsiChar =
    'SELECT group_concat(' +
    ' printf(''"%w" to "%w"'',name,printf(''%!.*s%s'',nlen-chop,name,suff)),' +
    ' '',''||x''0a'')' +
    'FROM ColNames WHERE suff<>'''' OR chop!=0';
var
  pStmt:    PVdbe;
  pTail:    PAnsiChar;
  rc, nDig: i32;
  hasDup:   i32;
  z:        PAnsiChar;
begin
  Result := '';
  zRenamed := '';
  if pDb = nil then Exit;

  hasDup := 0; nDig := 0;
  pStmt := nil; pTail := nil;
  if sqlite3_prepare_v2(pDb, zHasDupes, -1, @pStmt, @pTail) = SQLITE_OK then
  begin
    if sqlite3_step(pStmt) = SQLITE_ROW then
      hasDup := sqlite3_column_int(pStmt, 0);
    sqlite3_finalize(pStmt);
  end;
  if hasDup <> 0 then begin
    pStmt := nil;
    if sqlite3_prepare_v2(pDb, zColDigits, -1, @pStmt, @pTail) = SQLITE_OK then
    begin
      if sqlite3_step(pStmt) = SQLITE_ROW then
        nDig := sqlite3_column_int(pStmt, 0);
      sqlite3_finalize(pStmt);
    end;
    rc := sqlite3_exec(pDb, zSetReps, nil, nil, nil);
    if rc = SQLITE_OK then begin
      pStmt := nil;
      if sqlite3_prepare_v2(pDb, zRenameRank, -1, @pStmt, @pTail) = SQLITE_OK
      then begin
        sqlite3_bind_int(pStmt, 1, nDig);
        sqlite3_step(pStmt);
        sqlite3_finalize(pStmt);
      end;
    end;
  end;

  pStmt := nil;
  if sqlite3_prepare_v2(pDb, zCollectVar, -1, @pStmt, @pTail) = SQLITE_OK then
  begin
    if sqlite3_step(pStmt) = SQLITE_ROW then begin
      z := sqlite3_column_text(pStmt, 0);
      if z <> nil then Result := AnsiString(z);
    end;
    sqlite3_finalize(pStmt);
  end;

  if hasDup <> 0 then begin
    pStmt := nil;
    if sqlite3_prepare_v2(pDb, zRenamesDone, -1, @pStmt, @pTail) = SQLITE_OK
    then begin
      if sqlite3_step(pStmt) = SQLITE_ROW then begin
        z := sqlite3_column_text(pStmt, 0);
        if z <> nil then zRenamed := AnsiString(z);
      end;
      sqlite3_finalize(pStmt);
    end;
  end;

  sqlite3_close(pDb);
  pDb := nil;
end;

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
  autoDb: PTsqlite3;
  autoRenamed, zColDefs, zCreate: AnsiString;
  { 10.1.24.a — heredoc arm locals (shell.c.in:7601..7637). }
  pContent: PSqlite3Str;
  zEndMark, zLine: AnsiString;
  nEndMark: i32;
  ckEnd: i32;
  iStart, savedLn: i64;
  atEof: Boolean;
begin
  { 10.1.24.b — failIfSafeMode gate at .import entry.  Mirrors C
    failIfSafeMode(p, "cannot run .import in safe mode") at
    shell.c.in:7502 (which formats via shellErrorLocation, writes to
    stderr, and cli_exit(1)).  Replicate shellErrorLocation inline
    (shell.c.in:1779..1789). }
  if p^.bSafeMode <> 0 then begin
    if p^.zErrPrefix <> nil then
      shellEPutZ(AnsiString(p^.zErrPrefix) + ' cannot run .import in safe mode'#10)
    else if (p^.zInFile = nil) or (StrComp(p^.zInFile, '<stdin>') = 0) then
      shellEPutZ(Format('line %d: cannot run .import in safe mode'#10,
        [Int64(p^.lineno)]))
    else
      shellEPutZ(Format('%s:%d: cannot run .import in safe mode'#10,
        [string(AnsiString(p^.zInFile)), Int64(p^.lineno)]));
    Halt(1);
  end;
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
    { 10.1.24.b — pipe arm.  Mirrors C shell.c.in:7593..7600:
        sCtx.in     = popen(zFile+1, "r");
        sCtx.zFile  = "<pipe>";
        sCtx.xCloser = pclose;
      We bind libc popen/pclose directly (see shellLibcPOpen) and route
      reads through importGetc's pipeFile branch. }
    sCtx.pipeFile := shellLibcPOpen(PAnsiChar(Copy(zFile, 2, Length(zFile) - 1)),
                                    PAnsiChar('r'));
    if sCtx.pipeFile = nil then begin
      { Mirror C dotCmdError(p, 0, 0, "cannot open \"%s\"", zFile) which
        keeps the original "|cmd" string in the message — sCtx.zFile is
        only swapped to "<pipe>" on success.  shell.c.in:7644. }
      shellEPutZ(Format('Error: cannot open "%s"'#10, [zFile]));
      importCleanup(sCtx);
      Exit;
    end;
    sCtx.pipeOpen := True;
    sCtx.zFile := '<pipe>';
  end else
  if (Length(zFile) > 2) and (zFile[1] = '<') and (zFile[2] = '<') then begin
    { 10.1.24.a — heredoc arm.  shell.c.in:7601..7637.
      zFile = '<<MARK': read subsequent script lines into an sqlite3_str
      until a line starts with MARK; route through the existing CSV/ASCII
      reader via sCtx.zIn. }
    nEndMark := Length(zFile) - 2;
    zEndMark := Copy(zFile, 3, nEndMark);
    pContent := sqlite3_str_new(p^.db);
    ckEnd := 1;
    iStart := p^.lineno;
    sCtx.zFile := AnsiString(p^.zInFile);
    sCtx.nLine := i32(p^.lineno + 1);
    atEof := False;
    while True do begin
      zLine := oneInputLine(p, False, atEof);
      if atEof then Break;
      if (ckEnd <> 0)
         and (Length(zLine) >= nEndMark)
         and (StrLComp(PAnsiChar(zLine), PAnsiChar(zEndMark), nEndMark) = 0)
      then begin
        ckEnd := 2;
        Inc(p^.lineno);  { oneInputLine consumed a '\n' terminator }
        Break;
      end;
      Inc(p^.lineno);
      ckEnd := 1;
      sqlite3_str_appendall(pContent, PAnsiChar(zLine));
      sqlite3_str_append(pContent, PAnsiChar(#10), 1);
    end;
    sCtx.zIn := sqlite3_str_finish(pContent);
    if sCtx.zIn = nil then
      sCtx.zIn := sqlite3_mprintf(PAnsiChar(''));
    if ckEnd < 2 then begin
      savedLn := p^.lineno;
      p^.lineno := iStart;
      { Mirror C dotCmdError → shellErrorLocation: prints
        "line %lld:" when zInFile is "<stdin>" (or NULL), else
        "<file>:%lld:".  shell.c.in:1779..1789, 1834..1842. }
      if (p^.zInFile = nil) or (StrComp(p^.zInFile, '<stdin>') = 0) then
        shellEPutZ(Format('line %d: Content terminator "%s" not found.'#10,
          [Int64(p^.lineno), string(zEndMark)]))
      else
        shellEPutZ(Format('%s:%d: Content terminator "%s" not found.'#10,
          [string(AnsiString(p^.zInFile)), Int64(p^.lineno), string(zEndMark)]));
      p^.lineno := savedLn;
      importCleanup(sCtx);
      Exit;
    end;
    sCtx.zInCur := sCtx.zIn;
  end else begin
    sCtx.inHandle := FpOpen(string(zFile), O_RDONLY);
    if sCtx.inHandle = THandle(-1) then begin
      shellEPutZ(Format('Error: cannot open "%s"'#10, [zFile]));
      Exit;
    end;
    sCtx.inOpen := True;
  end;

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

  { Probe whether the destination table already exists.  If not, derive
    its column list from the first row of the input via zAutoColumn —
    matching shell.c.in:7670..7717. }
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
    { Auto-create the table from the first row of input. }
    importAppendChar(sCtx, 0);
    autoDb := nil;
    autoRenamed := '';
    while xRead(sCtx) do begin
      shellAutoColumnAdd(autoDb, sCtx.z);
      if sCtx.cTerm <> sCtx.cColSep then Break;
    end;
    zColDefs := shellAutoColumnFinish(autoDb, autoRenamed);
    if autoRenamed <> '' then
      shellEPutZ('Columns renamed during .import ' + sCtx.zFile +
                 ' due to duplicates:'#10 + autoRenamed + #10);
    if zColDefs = '' then begin
      shellEPutZ(sCtx.zFile + ': empty file'#10);
      importCleanup(sCtx);
      Exit;
    end;
    if zSchema <> '' then
      zCreate := 'CREATE TABLE "' +
        StringReplace(zSchema, '"', '""', [rfReplaceAll]) + '"."' +
        StringReplace(zTable, '"', '""', [rfReplaceAll]) + '"' + zColDefs
    else
      zCreate := 'CREATE TABLE "' +
        StringReplace(zTable, '"', '""', [rfReplaceAll]) + '"' + zColDefs;
    if eVerbose >= 1 then shellSPutZ(zCreate + #10);
    rc := sqlite3_exec(p^.db, PAnsiChar(zCreate), nil, nil, nil);
    if rc <> SQLITE_OK then begin
      shellEPutZ(zCreate + ' failed:'#10 +
                 AnsiString(sqlite3_errmsg(p^.db)) + #10);
      importCleanup(sCtx);
      Exit;
    end;
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

{ ----------------------------------------------------------------------
  10.1.46  `.archive` / `.ar`  —  shell.c.in:6234..7005

  Faithful port of the SQL-archive (sqlar) and ZIP-archive (zipfile)
  manager.  Backed by ext/misc/sqlar.c (sqlar_compress/sqlar_uncompress
  — already wired in openDb), ext/misc/fileio.c (lsmode, fsdir,
  writefile, realpath — wired) and ext/misc/zipfile.c (zipfile vtab —
  wired).

  Sub-commands:
    -c, --create   create new archive
    -u, --update   add only changed files
    -i, --insert   add files (always overwrite)
    -t, --list     list contents
    -x, --extract  extract files
    -r, --remove   remove files

  Switches:
    -v, --verbose       chatty output
    -f, --file FILE     archive file (defaults to current db)
    -a, --append FILE   open as appendvfs
    -C, --directory DIR base directory for create/extract
    -n, --dryrun        print SQL but do not run
    -g, --glob          treat names as GLOB patterns
    -h, --help          help
  ---------------------------------------------------------------------- }

const
  AR_CMD_CREATE       = 1;
  AR_CMD_UPDATE       = 2;
  AR_CMD_INSERT       = 3;
  AR_CMD_EXTRACT      = 4;
  AR_CMD_LIST         = 5;
  AR_CMD_HELP         = 6;
  AR_CMD_REMOVE       = 7;
  AR_SWITCH_VERBOSE   = 8;
  AR_SWITCH_FILE      = 9;
  AR_SWITCH_DIRECTORY = 10;
  AR_SWITCH_APPEND    = 11;
  AR_SWITCH_DRYRUN    = 12;
  AR_SWITCH_GLOB      = 13;

type
  PArCommand = ^TArCommand;
  TArCommand = record
    eCmd:        u8;
    bVerbose:    u8;
    bZip:        u8;
    bDryRun:     u8;
    bAppend:     u8;
    bGlob:       u8;
    fromCmdLine: u8;
    nArg:        i32;
    zSrcTable:   PAnsiChar;          { allocated via sqlite3_mprintf }
    sFile:       AnsiString;         { backing for zFile }
    sDir:        AnsiString;         { backing for zDir }
    haveFile:    Boolean;
    haveDir:     Boolean;
    azArg:       array of AnsiString; { remaining positional args }
    p:           PShellState;
    db:          PTsqlite3;
  end;

  TArSwitch = record
    zLong:   AnsiString;
    cShort:  AnsiChar;
    eSwitch: u8;
    bArg:    u8;
  end;

const
  ar_aSwitch: array[0..12] of TArSwitch = (
    (zLong: 'create';    cShort: 'c'; eSwitch: AR_CMD_CREATE;       bArg: 0),
    (zLong: 'extract';   cShort: 'x'; eSwitch: AR_CMD_EXTRACT;      bArg: 0),
    (zLong: 'insert';    cShort: 'i'; eSwitch: AR_CMD_INSERT;       bArg: 0),
    (zLong: 'list';      cShort: 't'; eSwitch: AR_CMD_LIST;         bArg: 0),
    (zLong: 'remove';    cShort: 'r'; eSwitch: AR_CMD_REMOVE;       bArg: 0),
    (zLong: 'update';    cShort: 'u'; eSwitch: AR_CMD_UPDATE;       bArg: 0),
    (zLong: 'help';      cShort: 'h'; eSwitch: AR_CMD_HELP;         bArg: 0),
    (zLong: 'verbose';   cShort: 'v'; eSwitch: AR_SWITCH_VERBOSE;   bArg: 0),
    (zLong: 'file';      cShort: 'f'; eSwitch: AR_SWITCH_FILE;      bArg: 1),
    (zLong: 'append';    cShort: 'a'; eSwitch: AR_SWITCH_APPEND;    bArg: 1),
    (zLong: 'directory'; cShort: 'C'; eSwitch: AR_SWITCH_DIRECTORY; bArg: 1),
    (zLong: 'dryrun';    cShort: 'n'; eSwitch: AR_SWITCH_DRYRUN;    bArg: 0),
    (zLong: 'glob';      cShort: 'g'; eSwitch: AR_SWITCH_GLOB;      bArg: 0)
  );

function arUsage: i32; forward;
function arErrorMsg(pAr: PArCommand; const z: AnsiString): i32; forward;

function arUsage: i32;
{ shell.c.in:6261 — invokes the help renderer for the "archive" pattern. }
begin
  showHelp('archive');
  Result := SQLITE_ERROR;
end;

function arErrorMsg(pAr: PArCommand; const z: AnsiString): i32;
{ shell.c.in:6270.  Print error and a usage hint. }
begin
  shellEPutZ('Error: ' + z + sLineBreak);
  if pAr^.fromCmdLine <> 0 then
    shellEPutZ('Use "-A" for more help'#10)
  else
    shellEPutZ('Use ".archive --help" for more help'#10);
  Result := SQLITE_ERROR;
end;

function arProcessSwitch(pAr: PArCommand; eSwitch: u8;
                         const zArg: AnsiString): i32;
{ shell.c.in:6307 }
begin
  case eSwitch of
    AR_CMD_CREATE, AR_CMD_EXTRACT, AR_CMD_LIST, AR_CMD_REMOVE,
    AR_CMD_UPDATE, AR_CMD_INSERT, AR_CMD_HELP:
      begin
        if pAr^.eCmd <> 0 then begin
          Result := arErrorMsg(pAr, 'multiple command options');
          Exit;
        end;
        pAr^.eCmd := eSwitch;
      end;
    AR_SWITCH_DRYRUN:
      pAr^.bDryRun := 1;
    AR_SWITCH_GLOB:
      pAr^.bGlob := 1;
    AR_SWITCH_VERBOSE:
      pAr^.bVerbose := 1;
    AR_SWITCH_APPEND:
      begin
        pAr^.bAppend := 1;
        pAr^.sFile := zArg;
        pAr^.haveFile := True;
      end;
    AR_SWITCH_FILE:
      begin
        pAr^.sFile := zArg;
        pAr^.haveFile := True;
      end;
    AR_SWITCH_DIRECTORY:
      begin
        pAr^.sDir := zArg;
        pAr^.haveDir := True;
      end;
  end;
  Result := SQLITE_OK;
end;

function arParseCommand(const args: array of AnsiString; nArg: SizeInt;
                        pAr: PArCommand): i32;
{ shell.c.in:6351.  Pascal `args[]` does NOT include the dot-cmd name —
  arrange so that index 0 is implicit "archive" and the C `azArg[1..]`
  is `args[0..]`. }
var
  i, k, n: SizeInt;
  z, zArg: AnsiString;
  pOpt, pMatch: SizeInt;
  iArg: SizeInt;
begin
  if nArg <= 0 then begin
    shellEPutZ('Wrong number of arguments.  Usage:'#10);
    Result := arUsage;
    Exit;
  end;

  z := args[0];
  if (Length(z) = 0) or (z[1] <> '-') then begin
    { Traditional [tar] invocation: "ctf foo bar" — treat each char of
      args[0] as a short switch.  Switches with bArg consume the next
      positional arg. }
    iArg := 1;
    for i := 1 to Length(z) do begin
      pOpt := -1;
      for k := 0 to High(ar_aSwitch) do
        if z[i] = ar_aSwitch[k].cShort then begin pOpt := k; Break; end;
      if pOpt < 0 then begin
        Result := arErrorMsg(pAr, Format('unrecognized option: %s', [z[i]]));
        Exit;
      end;
      zArg := '';
      if ar_aSwitch[pOpt].bArg <> 0 then begin
        if iArg >= nArg then begin
          Result := arErrorMsg(pAr,
            Format('option requires an argument: %s', [z[i]]));
          Exit;
        end;
        zArg := args[iArg];
        Inc(iArg);
      end;
      Result := arProcessSwitch(pAr, ar_aSwitch[pOpt].eSwitch, zArg);
      if Result <> SQLITE_OK then Exit;
    end;
    pAr^.nArg := nArg - iArg;
    if pAr^.nArg > 0 then begin
      SetLength(pAr^.azArg, pAr^.nArg);
      for i := 0 to pAr^.nArg - 1 do
        pAr^.azArg[i] := args[iArg + i];
    end;
  end else begin
    { Non-traditional invocation: each arg starting with '-'/'--' is a
      switch.  First non-switch and everything after are positional. }
    iArg := 0;
    while iArg < nArg do begin
      z := args[iArg];
      if (Length(z) = 0) or (z[1] <> '-') then begin
        SetLength(pAr^.azArg, nArg - iArg);
        for i := 0 to (nArg - iArg) - 1 do
          pAr^.azArg[i] := args[iArg + i];
        pAr^.nArg := nArg - iArg;
        Break;
      end;
      n := Length(z);
      if (n >= 2) and (z[2] <> '-') then begin
        { One or more short options: -ctf or -t alone }
        i := 2;
        while i <= n do begin
          pOpt := -1;
          for k := 0 to High(ar_aSwitch) do
            if z[i] = ar_aSwitch[k].cShort then begin pOpt := k; Break; end;
          if pOpt < 0 then begin
            Result := arErrorMsg(pAr,
              Format('unrecognized option: %s', [z[i]]));
            Exit;
          end;
          zArg := '';
          if ar_aSwitch[pOpt].bArg <> 0 then begin
            if i < n then begin
              zArg := Copy(z, i + 1, n - i);
              i := n + 1;
            end else begin
              if iArg >= nArg - 1 then begin
                Result := arErrorMsg(pAr,
                  Format('option requires an argument: %s', [z[i]]));
                Exit;
              end;
              Inc(iArg);
              zArg := args[iArg];
            end;
          end;
          Result := arProcessSwitch(pAr,
            ar_aSwitch[pOpt].eSwitch, zArg);
          if Result <> SQLITE_OK then Exit;
          Inc(i);
        end;
      end else if (n = 2) and (z[2] = '-') then begin
        { '--' marks end-of-options. }
        if iArg + 1 < nArg then begin
          SetLength(pAr^.azArg, nArg - iArg - 1);
          for i := 0 to (nArg - iArg - 2) do
            pAr^.azArg[i] := args[iArg + 1 + i];
          pAr^.nArg := nArg - iArg - 1;
        end;
        Break;
      end else begin
        { Long option starting with '--'. }
        zArg := '';
        pMatch := -1;
        for k := 0 to High(ar_aSwitch) do begin
          if (n - 2) <= Length(ar_aSwitch[k].zLong) then begin
            if Copy(z, 3, n - 2) =
               Copy(ar_aSwitch[k].zLong, 1, n - 2) then
            begin
              if pMatch >= 0 then begin
                Result := arErrorMsg(pAr,
                  Format('ambiguous option: %s', [z]));
                Exit;
              end;
              pMatch := k;
            end;
          end;
        end;
        if pMatch < 0 then begin
          Result := arErrorMsg(pAr,
            Format('unrecognized option: %s', [z]));
          Exit;
        end;
        if ar_aSwitch[pMatch].bArg <> 0 then begin
          if iArg >= nArg - 1 then begin
            Result := arErrorMsg(pAr,
              Format('option requires an argument: %s', [z]));
            Exit;
          end;
          Inc(iArg);
          zArg := args[iArg];
        end;
        Result := arProcessSwitch(pAr,
          ar_aSwitch[pMatch].eSwitch, zArg);
        if Result <> SQLITE_OK then Exit;
      end;
      Inc(iArg);
    end;
  end;

  if pAr^.eCmd = 0 then begin
    shellEPutZ('Required argument missing.  Usage:'#10);
    Result := arUsage;
    Exit;
  end;
  Result := SQLITE_OK;
end;

function arCheckEntries(pAr: PArCommand): i32;
{ shell.c.in:6506 — verify each azArg[] member exists in the archive. }
var
  i, j, n: SizeInt;
  pTest: PVdbe;
  zSel, zSql: AnsiString;
  z: AnsiString;
  bOk: Boolean;
  rc: i32;
  zMprintf: PAnsiChar;
begin
  Result := SQLITE_OK;
  if pAr^.nArg = 0 then Exit;
  if pAr^.bGlob <> 0 then
    zSel := 'SELECT name FROM %s WHERE glob($name,name)'
  else
    zSel := 'SELECT name FROM %s WHERE name=$name';
  zMprintf := sqlite3PfMprintf(PAnsiChar(zSel),
    [AnsiString(pAr^.zSrcTable)]);
  if zMprintf = nil then begin Result := SQLITE_NOMEM; Exit; end;
  zSql := AnsiString(zMprintf);
  sqlite3_free(zMprintf);

  pTest := nil;
  rc := sqlite3_prepare_v2(pAr^.db, PAnsiChar(zSql), -1, @pTest, nil);
  if rc <> SQLITE_OK then begin
    shellEPutZ(Format('Error: %s'#10,
      [AnsiString(sqlite3_errmsg(pAr^.db))]));
    if pTest <> nil then sqlite3_finalize(pTest);
    Result := rc;
    Exit;
  end;
  j := sqlite3_bind_parameter_index(pTest, '$name');

  for i := 0 to pAr^.nArg - 1 do begin
    z := pAr^.azArg[i];
    n := Length(z);
    while (n > 0) and (z[n] = '/') do Dec(n);
    if n < Length(z) then SetLength(z, n);
    pAr^.azArg[i] := z;
    bOk := False;
    sqlite3_bind_text(pTest, j, PAnsiChar(z), -1, SQLITE_STATIC);
    if sqlite3_step(pTest) = SQLITE_ROW then bOk := True;
    sqlite3_reset(pTest);
    if not bOk then begin
      shellEPutZ(Format('not found in archive: %s'#10, [z]));
      Result := SQLITE_ERROR;
      Break;
    end;
  end;
  sqlite3_finalize(pTest);
end;

procedure arWhereClause(var rc: i32; pAr: PArCommand; out zWhere: AnsiString);
{ shell.c.in:6546.  Build a WHERE clause matching pAr^.azArg[]. }
var
  z1, z2: PAnsiChar;
  zSep1, zSep2: AnsiString;
  i, n: SizeInt;
  z: AnsiString;
  zNew: PAnsiChar;
begin
  zWhere := '';
  if rc <> SQLITE_OK then Exit;
  if pAr^.nArg = 0 then begin
    zWhere := '1';
    Exit;
  end;
  if pAr^.bGlob <> 0 then
    z1 := sqlite3PfMprintf(PAnsiChar(AnsiString('')), [])
  else
    z1 := sqlite3PfMprintf(PAnsiChar(AnsiString('name IN(')), []);
  z2 := sqlite3PfMprintf(PAnsiChar(AnsiString('')), []);
  zSep1 := '';
  zSep2 := '';
  for i := 0 to pAr^.nArg - 1 do begin
    if (z1 = nil) or (z2 = nil) then Break;
    z := pAr^.azArg[i];
    n := Length(z);
    if pAr^.bGlob <> 0 then begin
      zNew := sqlite3PfMprintf(PAnsiChar('%z%sname GLOB ''%q'''),
        [AnsiString(z1), zSep2, z]);
      z1 := zNew;
      zNew := sqlite3PfMprintf(
        PAnsiChar('%z%ssubstr(name,1,%d) GLOB ''%q/'''),
        [AnsiString(z2), zSep2, n + 1, z]);
      z2 := zNew;
    end else begin
      zNew := sqlite3PfMprintf(PAnsiChar('%z%s''%q'''),
        [AnsiString(z1), zSep1, z]);
      z1 := zNew;
      zNew := sqlite3PfMprintf(
        PAnsiChar('%z%ssubstr(name,1,%d) = ''%q/'''),
        [AnsiString(z2), zSep2, n + 1, z]);
      z2 := zNew;
    end;
    zSep1 := ', ';
    zSep2 := ' OR ';
  end;
  if (z1 = nil) or (z2 = nil) then begin
    rc := SQLITE_NOMEM;
  end else begin
    { shell.c.in:6581 — single template, the second %s closes the
      IN(..) list in the non-glob branch and is empty in the glob
      branch.  z1 is left without its trailing ')' so the close paren
      is inserted here. }
    if pAr^.bGlob = 0 then
      zNew := sqlite3PfMprintf(
        PAnsiChar('(%s%s OR (name GLOB ''*/*'' AND (%s))) '),
        [AnsiString(z1), AnsiString(')'), AnsiString(z2)])
    else
      zNew := sqlite3PfMprintf(
        PAnsiChar('(%s%s OR (name GLOB ''*/*'' AND (%s))) '),
        [AnsiString(z1), AnsiString(''), AnsiString(z2)]);
    if zNew = nil then begin
      rc := SQLITE_NOMEM;
    end else begin
      zWhere := AnsiString(zNew);
      sqlite3_free(zNew);
    end;
  end;
  if z1 <> nil then sqlite3_free(z1);
  if z2 <> nil then sqlite3_free(z2);
end;

function arListCommand(pAr: PArCommand): i32;
{ shell.c.in:6595 }
const
  azCols: array[0..1] of AnsiString = (
    'name',
    'lsmode(mode), sz, datetime(mtime, ''unixepoch''), name'
  );
var
  zWhere, zSql: AnsiString;
  pSql: PVdbe;
  rc: i32;
  z: PAnsiChar;
begin
  rc := arCheckEntries(pAr);
  arWhereClause(rc, pAr, zWhere);

  pSql := nil;
  if rc = SQLITE_OK then begin
    z := sqlite3PfMprintf(PAnsiChar('SELECT %s FROM %s WHERE %s'),
      [azCols[Ord(pAr^.bVerbose <> 0)], AnsiString(pAr^.zSrcTable), zWhere]);
    if z = nil then begin Result := SQLITE_NOMEM; Exit; end;
    zSql := AnsiString(z);
    sqlite3_free(z);
    rc := sqlite3_prepare_v2(pAr^.db, PAnsiChar(zSql), -1, @pSql, nil);
    if rc <> SQLITE_OK then
      shellEPutZ(Format('Error: %s'#10,
        [AnsiString(sqlite3_errmsg(pAr^.db))]));
  end;
  if (rc = SQLITE_OK) and (pAr^.bDryRun <> 0) then begin
    shellSPutZ(Format('%s'#10, [AnsiString(sqlite3_sql(pSql))]));
  end else if rc = SQLITE_OK then begin
    while (rc = SQLITE_OK) and (sqlite3_step(pSql) = SQLITE_ROW) do begin
      if pAr^.bVerbose <> 0 then begin
        shellSPutZ(Format('%s %10d  %s  %s'#10,
          [AnsiString(sqlite3_column_text(pSql, 0)),
           sqlite3_column_int(pSql, 1),
           AnsiString(sqlite3_column_text(pSql, 2)),
           AnsiString(sqlite3_column_text(pSql, 3))]));
      end else begin
        shellSPutZ(Format('%s'#10,
          [AnsiString(sqlite3_column_text(pSql, 0))]));
      end;
    end;
  end;
  if pSql <> nil then sqlite3_finalize(pSql);
  Result := rc;
end;

function arRemoveCommand(pAr: PArCommand): i32;
{ shell.c.in:6632 }
var
  rc: i32;
  zWhere, zSql: AnsiString;
  zErr: PAnsiChar;
  z: PAnsiChar;
begin
  rc := SQLITE_OK;
  zWhere := '';
  if pAr^.nArg > 0 then begin
    rc := arCheckEntries(pAr);
    arWhereClause(rc, pAr, zWhere);
  end;
  if rc = SQLITE_OK then begin
    z := sqlite3PfMprintf(PAnsiChar('DELETE FROM %s WHERE %s;'),
      [AnsiString(pAr^.zSrcTable), zWhere]);
    if z = nil then begin Result := SQLITE_NOMEM; Exit; end;
    zSql := AnsiString(z);
    sqlite3_free(z);
    if pAr^.bDryRun <> 0 then begin
      shellSPutZ(zSql + sLineBreak);
    end else begin
      zErr := nil;
      rc := sqlite3_exec(pAr^.db, 'SAVEPOINT ar;', nil, nil, nil);
      if rc = SQLITE_OK then begin
        rc := sqlite3_exec(pAr^.db, PAnsiChar(zSql), nil, nil, @zErr);
        if rc <> SQLITE_OK then
          sqlite3_exec(pAr^.db, 'ROLLBACK TO ar; RELEASE ar;', nil, nil, nil)
        else
          rc := sqlite3_exec(pAr^.db, 'RELEASE ar;', nil, nil, nil);
      end;
      if zErr <> nil then begin
        shellSPutZ(Format('ERROR: %s'#10, [AnsiString(zErr)]));
        sqlite3_free(zErr);
      end;
    end;
  end;
  Result := rc;
end;

function arExtractCommand(pAr: PArCommand): i32;
{ shell.c.in:6673 }
const
  zSql1 =
    'WITH dest(dpath,dlen) AS (SELECT realpath($dir),length(realpath($dir)))'#10 +
    'SELECT ($dir || name),'#10 +
    '       CASE WHEN $dryrun THEN 0'#10 +
    '            ELSE writefile($dir||name, %s, mode, mtime) END'#10 +
    '  FROM dest CROSS JOIN %s'#10 +
    ' WHERE (%s)'#10 +
    '   AND (data IS NULL OR $pass==0)'#10 +
    '   AND dpath=substr(realpath($dir||name),1,dlen)'#10 +
    '   AND name NOT GLOB ''*..[/\]*'''#10;
  azExtraArg: array[0..1] of AnsiString = (
    'sqlar_uncompress(data, sz)',
    'data'
  );
var
  pSql: PVdbe;
  rc: i32;
  zDir, zWhere, zSql: AnsiString;
  i, j: SizeInt;
  z: PAnsiChar;
begin
  pSql := nil;
  rc := arCheckEntries(pAr);
  arWhereClause(rc, pAr, zWhere);

  if rc = SQLITE_OK then begin
    if pAr^.haveDir then zDir := pAr^.sDir + '/' else zDir := '';
    z := sqlite3PfMprintf(PAnsiChar(AnsiString(zSql1)),
      [azExtraArg[pAr^.bZip], AnsiString(pAr^.zSrcTable), zWhere]);
    if z = nil then begin Result := SQLITE_NOMEM; Exit; end;
    zSql := AnsiString(z);
    sqlite3_free(z);
    rc := sqlite3_prepare_v2(pAr^.db, PAnsiChar(zSql), -1, @pSql, nil);
    if rc <> SQLITE_OK then
      shellEPutZ(Format('Error: %s'#10,
        [AnsiString(sqlite3_errmsg(pAr^.db))]));
  end;

  if rc = SQLITE_OK then begin
    j := sqlite3_bind_parameter_index(pSql, '$dir');
    sqlite3_bind_text(pSql, j, PAnsiChar(zDir), -1, SQLITE_STATIC);
    j := sqlite3_bind_parameter_index(pSql, '$dryrun');
    sqlite3_bind_int(pSql, j, pAr^.bDryRun);

    { Two passes: writefile() all, then re-touch directories so their
      mtimes match the archive (first pass mutates them while extracting
      contained files). }
    for i := 0 to 1 do begin
      j := sqlite3_bind_parameter_index(pSql, '$pass');
      sqlite3_bind_int(pSql, j, i);
      if pAr^.bDryRun <> 0 then begin
        shellSPutZ(Format('%s'#10, [AnsiString(sqlite3_sql(pSql))]));
        if pAr^.bVerbose = 0 then Break;
      end;
      while (rc = SQLITE_OK) and (sqlite3_step(pSql) = SQLITE_ROW) do begin
        if (i = 0) and (pAr^.bVerbose <> 0) then
          shellSPutZ(Format('%s'#10,
            [AnsiString(sqlite3_column_text(pSql, 0))]));
      end;
      if pAr^.bDryRun <> 0 then Break;
      sqlite3_reset(pSql);
    end;
  end;
  if pSql <> nil then sqlite3_finalize(pSql);
  Result := rc;
end;

function arExecSql(pAr: PArCommand; const zSql: AnsiString): i32;
{ shell.c.in:6753 }
var
  zErr: PAnsiChar;
  rc: i32;
begin
  if pAr^.bDryRun <> 0 then begin
    shellSPutZ(zSql + sLineBreak);
    Result := SQLITE_OK;
  end else begin
    zErr := nil;
    rc := sqlite3_exec(pAr^.db, PAnsiChar(zSql), nil, nil, @zErr);
    if zErr <> nil then begin
      shellSPutZ(Format('ERROR: %s'#10, [AnsiString(zErr)]));
      sqlite3_free(zErr);
    end;
    Result := rc;
  end;
end;

function arCreateOrUpdateCommand(pAr: PArCommand;
                                 bUpdate, bOnlyIfChanged: i32): i32;
label end_ar_transaction;
{ shell.c.in:6788 — create / insert / update (sqlar or zip targets). }
const
  zCreate =
    'CREATE TABLE IF NOT EXISTS sqlar('#10 +
    '  name TEXT PRIMARY KEY,  -- name of the file'#10 +
    '  mode INT,               -- access permissions'#10 +
    '  mtime INT,              -- last modification time'#10 +
    '  sz INT,                 -- original file size'#10 +
    '  data BLOB               -- compressed content'#10 +
    ')';
  zDrop = 'DROP TABLE IF EXISTS sqlar';
  zInsertSqlar =
    'REPLACE INTO %s(name,mode,mtime,sz,data)'#10 +
    '  SELECT'#10 +
    '    %s,'#10 +
    '    mode,'#10 +
    '    mtime,'#10 +
    '    CASE substr(lsmode(mode),1,1)'#10 +
    '      WHEN ''-'' THEN length(data)'#10 +
    '      WHEN ''d'' THEN 0'#10 +
    '      ELSE -1 END,'#10 +
    '    sqlar_compress(data)'#10 +
    '  FROM fsdir(%Q,%Q) AS disk'#10 +
    '  WHERE lsmode(mode) NOT LIKE ''?%%''%s;';
  zInsertZip =
    'REPLACE INTO %s(name,mode,mtime,data)'#10 +
    '  SELECT'#10 +
    '    %s,'#10 +
    '    mode,'#10 +
    '    mtime,'#10 +
    '    data'#10 +
    '  FROM fsdir(%Q,%Q) AS disk'#10 +
    '  WHERE lsmode(mode) NOT LIKE ''?%%''%s;';
var
  i: SizeInt;
  rc: i32;
  zTab, zExists, zSql, zTemp, zNameSel, zArgDir: AnsiString;
  z: PAnsiChar;
  r: u64;
begin
  zTemp := '';
  zTab := '';
  zArgDir := '';
  if pAr^.haveDir then zArgDir := pAr^.sDir;

  arExecSql(pAr, 'PRAGMA page_size=512');
  rc := arExecSql(pAr, 'SAVEPOINT ar;');
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  if pAr^.bZip <> 0 then begin
    if pAr^.haveFile then begin
      sqlite3_randomness(SizeOf(r), @r);
      zTemp := Format('zip%016x', [r]);
      zTab := zTemp;
      z := sqlite3PfMprintf(
        PAnsiChar('CREATE VIRTUAL TABLE temp.%s USING zipfile(%Q)'),
        [zTab, pAr^.sFile]);
      if z = nil then begin Result := SQLITE_NOMEM; goto end_ar_transaction; end;
      zSql := AnsiString(z);
      sqlite3_free(z);
      rc := arExecSql(pAr, zSql);
    end else
      zTab := 'zip';
  end else begin
    zTab := 'sqlar';
    if bUpdate = 0 then begin
      rc := arExecSql(pAr, zDrop);
      if rc <> SQLITE_OK then goto end_ar_transaction;
    end;
    rc := arExecSql(pAr, zCreate);
  end;
  if rc <> SQLITE_OK then goto end_ar_transaction;

  if bOnlyIfChanged <> 0 then begin
    z := sqlite3PfMprintf(PAnsiChar(
      ' AND NOT EXISTS('#10 +
      'SELECT 1 FROM %s AS mem'#10 +
      ' WHERE mem.name=disk.name'#10 +
      ' AND mem.mtime=disk.mtime'#10 +
      ' AND mem.mode=disk.mode)'), [zTab]);
    if z = nil then begin rc := SQLITE_NOMEM; goto end_ar_transaction; end;
    zExists := AnsiString(z);
    sqlite3_free(z);
  end else
    zExists := '';

  if pAr^.bVerbose <> 0 then
    zNameSel := 'shell_putsnl(name)'
  else
    zNameSel := 'name';

  for i := 0 to pAr^.nArg - 1 do begin
    if pAr^.bZip <> 0 then
      z := sqlite3PfMprintf(PAnsiChar(zInsertZip),
        [zTab, zNameSel, pAr^.azArg[i], zArgDir, zExists])
    else
      z := sqlite3PfMprintf(PAnsiChar(zInsertSqlar),
        [zTab, zNameSel, pAr^.azArg[i], zArgDir, zExists]);
    if z = nil then begin rc := SQLITE_NOMEM; Break; end;
    zSql := AnsiString(z);
    sqlite3_free(z);
    rc := arExecSql(pAr, zSql);
    if rc <> SQLITE_OK then Break;
  end;

end_ar_transaction:
  if rc <> SQLITE_OK then
    sqlite3_exec(pAr^.db, 'ROLLBACK TO ar; RELEASE ar;', nil, nil, nil)
  else begin
    rc := arExecSql(pAr, 'RELEASE ar;');
    if (pAr^.bZip <> 0) and pAr^.haveFile then begin
      z := sqlite3PfMprintf(PAnsiChar('DROP TABLE %s'), [zTemp]);
      if z <> nil then begin
        zSql := AnsiString(z);
        sqlite3_free(z);
        arExecSql(pAr, zSql);
      end;
    end;
  end;
  Result := rc;
end;

function arDotCommand(p: PShellState; fromCmdLine: i32;
                      const args: array of AnsiString;
                      nArg: SizeInt): i32;
label end_ar_command;
{ shell.c.in:6897.  Dispatch entry for `.archive` / `.ar`. }
var
  cmd: TArCommand;
  rc: i32;
  eDbType: i32;
  flags: i32;
  z: PAnsiChar;
begin
  FillChar(cmd, SizeOf(cmd), 0);
  cmd.fromCmdLine := fromCmdLine;
  rc := arParseCommand(args, nArg, @cmd);
  if rc = SQLITE_OK then begin
    eDbType := SHELL_OPEN_UNSPEC;
    cmd.p := p;
    cmd.db := p^.db;
    if cmd.haveFile then begin
      { deduceDatabaseType is not yet ported.  Treat any --file FILE as
        a normal sqlar database unless --append was given (then apndvfs).
        Bare-zip detection is gated on the upstream sniff that we don't
        have yet — explicit .zip handling still works through zipfile
        vtab when --file points into an existing ZIP and the open-mode
        was set elsewhere. }
      if p^.openMode = SHELL_OPEN_ZIPFILE then eDbType := SHELL_OPEN_ZIPFILE
      else eDbType := SHELL_OPEN_NORMAL;
    end else begin
      eDbType := p^.openMode;
    end;
    if eDbType = SHELL_OPEN_ZIPFILE then begin
      if (cmd.eCmd = AR_CMD_EXTRACT) or (cmd.eCmd = AR_CMD_LIST) then begin
        if not cmd.haveFile then
          cmd.zSrcTable := sqlite3_mprintf('zip')
        else begin
          z := sqlite3PfMprintf(PAnsiChar('zipfile(%Q)'),
            [cmd.sFile]);
          cmd.zSrcTable := z;
        end;
      end;
      cmd.bZip := 1;
    end else if cmd.haveFile then begin
      if cmd.bAppend <> 0 then eDbType := SHELL_OPEN_APPENDVFS;
      if (cmd.eCmd = AR_CMD_CREATE) or (cmd.eCmd = AR_CMD_INSERT)
         or (cmd.eCmd = AR_CMD_REMOVE) or (cmd.eCmd = AR_CMD_UPDATE) then
        flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE
      else
        { Upstream uses READONLY here.  The Pascal pager currently
          rejects schema-load reads against a freshly-opened READONLY
          db (no journal-recovery path → SQLITE_READONLY).  Open RW for
          read-only commands too; we only emit reads under .ar -t/-x. }
        flags := SQLITE_OPEN_READWRITE;
      cmd.db := nil;
      if cmd.bDryRun <> 0 then begin
        if eDbType = SHELL_OPEN_APPENDVFS then
          shellSPutZ(Format('-- open database ''%s'' using ''apndvfs'''#10,
            [cmd.sFile]))
        else
          shellSPutZ(Format('-- open database ''%s'''#10, [cmd.sFile]));
      end;
      if eDbType = SHELL_OPEN_APPENDVFS then
        rc := sqlite3_open_v2(PAnsiChar(cmd.sFile), @cmd.db, flags, 'apndvfs')
      else
        rc := sqlite3_open_v2(PAnsiChar(cmd.sFile), @cmd.db, flags, nil);
      if rc <> SQLITE_OK then begin
        shellEPutZ(Format('cannot open file: %s (%s)'#10,
          [cmd.sFile, AnsiString(sqlite3_errmsg(cmd.db))]));
        goto end_ar_command;
      end;
      sqlite3FileioInit(cmd.db);
      sqlite3SqlarInit(cmd.db);
    end;

    if (cmd.zSrcTable = nil) and (cmd.bZip = 0)
       and (cmd.eCmd <> AR_CMD_HELP) then
    begin
      if cmd.eCmd <> AR_CMD_CREATE then begin
        { Upstream uses sqlite3_table_column_metadata; that path needs a
          loaded schema, which is lazy in the Pascal port.  Probe via a
          trivial SELECT — present-table → SQLITE_OK, missing → error. }
        if sqlite3_exec(cmd.db, 'SELECT 1 FROM sqlar LIMIT 1',
                        nil, nil, nil) <> SQLITE_OK then
        begin
          shellEPutZ('database does not contain an ''sqlar'' table'#10);
          rc := SQLITE_ERROR;
          goto end_ar_command;
        end;
      end;
      cmd.zSrcTable := sqlite3_mprintf('sqlar');
    end;

    case cmd.eCmd of
      AR_CMD_CREATE:  rc := arCreateOrUpdateCommand(@cmd, 0, 0);
      AR_CMD_EXTRACT: rc := arExtractCommand(@cmd);
      AR_CMD_LIST:    rc := arListCommand(@cmd);
      AR_CMD_HELP:    arUsage;
      AR_CMD_INSERT:  rc := arCreateOrUpdateCommand(@cmd, 1, 0);
      AR_CMD_REMOVE:  rc := arRemoveCommand(@cmd);
      AR_CMD_UPDATE:  rc := arCreateOrUpdateCommand(@cmd, 1, 1);
    end;
  end;
end_ar_command:
  if cmd.db <> p^.db then begin
    if cmd.db <> nil then closeDb(cmd.db);
  end;
  if cmd.zSrcTable <> nil then sqlite3_free(cmd.zSrcTable);
  Result := rc;
end;

procedure cmdArchive(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt);
begin
  arDotCommand(p, 0, args, nArg);
end;

{ ----------------------------------------------------------------------
  10.1a.1.1  `.bail on|off`            shell.c.in:9104..9110
  Sets bail_on_error.  Mirrors C's booleanValue() recogniser. }
function cmdBail(const args: array of AnsiString; nArg: SizeInt): i32;
begin
  Result := 0;
  if nArg = 1 then
    bail_on_error := parseOnOff(args[0], bail_on_error)
  else begin
    shellEPutZ('Usage: .bail on|off'#10);
    Result := 1;
  end;
end;

{ 10.1a.1.2  `.timeout MS`              shell.c.in:11881..11884
  Wraps sqlite3_busy_timeout. }
function cmdTimeout(p: PShellState; const args: array of AnsiString;
                    nArg: SizeInt): i32;
var
  ms: i32;
begin
  openDb(p, 0);
  if nArg >= 1 then ms := StrToIntDef(args[0], 0) else ms := 0;
  sqlite3_busy_timeout(p^.db, ms);
  Result := 0;
end;

{ 10.1a.1.3  `.version`                 shell.c.in:11978..11996
  Print library version + sourceid + (when available) compiler tag.
  Pas port is FPC-only — emit a single fpc-<version> tag mirroring
  the gcc-<__VERSION__> arm at shell.c.in:11993..11995. }
function cmdVersion(p: PShellState): i32;
var
  zPtrSz: AnsiString;
begin
  if SizeOf(Pointer) = 8 then zPtrSz := '64-bit' else zPtrSz := '32-bit';
  shellSPutZ(Format('SQLite %s %s'#10,
    [AnsiString(sqlite3_libversion), AnsiString(sqlite3_sourceid)]));
  shellSPutZ(Format('fpc-%d.%d.%d (%s)'#10,
    [FPC_VERSION, FPC_RELEASE, FPC_PATCH, zPtrSz]));
  Result := 0;
end;

{ 10.1a.1.4  `.prompt MAIN ?CONTINUE?`  shell.c.in:10438..10445
  Update the two REPL prompt strings.  Upstream uses a fixed-size
  buffer + shell_strncpy; the Pas backing storage is AnsiString so we
  just assign. }
function cmdPrompt(const args: array of AnsiString; nArg: SizeInt): i32;
begin
  if nArg >= 1 then mainPromptStr := args[0];
  if nArg >= 2 then continuePromptStr := args[1];
  Result := 0;
end;

{ 10.1a.1.6  `.limit ?NAME? ?VAL?`      shell.c.in:10002..10061
  13-entry name/code table; case-insensitive prefix match; on success
  print "%20s %d\n" current value (or set then print on `.limit NAME VAL`).
  Ambiguous prefix and unknown name both emit C-parity errors on stderr. }
type
  TLimitEntry = record
    name: AnsiString;
    code: i32;
  end;
const
  aLimit: array[0..12] of TLimitEntry = (
    (name: 'length';              code: SQLITE_LIMIT_LENGTH),
    (name: 'sql_length';          code: SQLITE_LIMIT_SQL_LENGTH),
    (name: 'column';              code: SQLITE_LIMIT_COLUMN),
    (name: 'expr_depth';          code: SQLITE_LIMIT_EXPR_DEPTH),
    (name: 'parser_depth';        code: 12 { SQLITE_LIMIT_PARSER_DEPTH }),
    (name: 'compound_select';     code: SQLITE_LIMIT_COMPOUND_SELECT),
    (name: 'vdbe_op';             code: SQLITE_LIMIT_VDBE_OP),
    (name: 'function_arg';        code: SQLITE_LIMIT_FUNCTION_ARG),
    (name: 'attached';            code: SQLITE_LIMIT_ATTACHED),
    (name: 'like_pattern_length'; code: SQLITE_LIMIT_LIKE_PATTERN_LENGTH),
    (name: 'variable_number';     code: SQLITE_LIMIT_VARIABLE_NUMBER),
    (name: 'trigger_depth';       code: SQLITE_LIMIT_TRIGGER_DEPTH),
    (name: 'worker_threads';      code: SQLITE_LIMIT_WORKER_THREADS)
  );

function cmdLimit(p: PShellState; const args: array of AnsiString;
                  nArg: SizeInt): i32;
var
  i, iLimit, n2, newVal: i32;
  zArgLc: AnsiString;
begin
  Result := 0;
  openDb(p, 0);
  if nArg = 0 then begin
    for i := 0 to High(aLimit) do
      shellSPutZ(Format('%20s %d'#10,
        [aLimit[i].name, sqlite3_limit(p^.db, aLimit[i].code, -1)]));
    Exit;
  end;
  if nArg > 2 then begin
    shellEPutZ('Usage: .limit NAME ?NEW-VALUE?'#10);
    Result := 1;
    Exit;
  end;
  iLimit := -1;
  zArgLc := LowerCase(args[0]);
  n2 := Length(zArgLc);
  for i := 0 to High(aLimit) do begin
    if (Length(aLimit[i].name) >= n2)
       and (Copy(LowerCase(aLimit[i].name), 1, n2) = zArgLc) then
    begin
      if iLimit < 0 then iLimit := i
      else begin
        shellEPutZ(Format('ambiguous limit: "%s"'#10, [args[0]]));
        Result := 1;
        Exit;
      end;
    end;
  end;
  if iLimit < 0 then begin
    shellEPutZ(Format('unknown limit: "%s"'#10 +
      'enter ".limits" with no arguments for a list.'#10, [args[0]]));
    Result := 1;
    Exit;
  end;
  if nArg = 2 then begin
    newVal := StrToIntDef(args[1], 0);
    sqlite3_limit(p^.db, aLimit[iLimit].code, newVal);
  end else
    shellSPutZ(Format('%20s %d'#10,
      [aLimit[iLimit].name,
       sqlite3_limit(p^.db, aLimit[iLimit].code, -1)]));
end;

{ 10.1a.1.10 `.intck ?STEPS_PER_UNLOCK?` shell.c.in:9964..9978 + 7091..7121
  Wraps the already-ported passqlite3intck. STEPS_PER_UNLOCK=0 → no
  periodic unlock; negative is rejected with the C usage banner. }
function cmdIntck(p: PShellState; const args: array of AnsiString;
                  nArg: SizeInt): i32;
var
  iArg, nStep, nError: Int64;
  pCk: PIntck;
  zMsg, zErr: PAnsiChar;
  rc: i32;
begin
  Result := 0;
  iArg := 0;
  if nArg = 1 then begin
    iArg := StrToInt64Def(args[0], 0);
    if iArg = 0 then iArg := -1;
  end;
  if ((nArg <> 0) and (nArg <> 1)) or (iArg < 0) then begin
    shellEPutZ('Usage: .intck STEPS_PER_UNLOCK'#10);
    Result := 1;
    Exit;
  end;
  if nArg = 0 then iArg := 0;
  openDb(p, 0);
  pCk := nil;
  rc := sqlite3_intck_open(p^.db, 'main', @pCk);
  if rc = SQLITE_OK then begin
    nStep := 0;
    nError := 0;
    while sqlite3_intck_step(pCk) = SQLITE_OK do begin
      zMsg := sqlite3_intck_message(pCk);
      if zMsg <> nil then begin
        shellSPutZ(AnsiString(zMsg) + #10);
        Inc(nError);
      end;
      Inc(nStep);
      if (iArg <> 0) and ((nStep mod iArg) = 0) then
        sqlite3_intck_unlock(pCk);
    end;
    zErr := nil;
    rc := sqlite3_intck_error(pCk, @zErr);
    if zErr <> nil then
      shellEPutZ(AnsiString(zErr) + #10);
    sqlite3_intck_close(pCk);
    shellSPutZ(Format('%d steps, %d errors'#10, [nStep, nError]));
  end;
  Result := rc;
end;

{ 10.1a.1.9  `.load FILE ?ENTRY?`        shell.c.in:10069..10088
  Wraps sqlite3_load_extension. Pas engine is built with
  SQLITE_OMIT_LOAD_EXTENSION (main.pas:332) — sqlite3_load_extension
  returns SQLITE_ERROR + "extension loading is disabled" which we
  surface verbatim, matching upstream OMIT build behaviour. }
function cmdLoad(p: PShellState; const args: array of AnsiString;
                 nArg: SizeInt): i32;
var
  zFile, zProc: PAnsiChar;
  zErrMsg: PAnsiChar;
  rc: i32;
begin
  Result := 0;
  failIfSafeMode(p, 'cannot run .load in safe mode');
  if (nArg < 1) or (Length(args[0]) = 0) then begin
    shellEPutZ('Usage: .load FILE ?ENTRYPOINT?'#10);
    Result := 1;
    Exit;
  end;
  zFile := PAnsiChar(args[0]);
  if nArg >= 2 then zProc := PAnsiChar(args[1]) else zProc := nil;
  openDb(p, 0);
  zErrMsg := nil;
  rc := sqlite3_load_extension(p^.db, zFile, zProc, @zErrMsg);
  if rc <> SQLITE_OK then begin
    if zErrMsg <> nil then
      shellEPutZ(AnsiString(zErrMsg) + #10)
    else
      shellEPutZ(Format('Error: %s'#10,
        [AnsiString(sqlite3_errmsg(p^.db))]));
    sqlite3_free(zErrMsg);
    Result := 1;
  end;
end;

{ 10.1a.1.7  `.imposter INDEX IMPOSTER` shell.c.in:9781..9876
  Installs a fake table that reads an index (or WITHOUT ROWID table)
  root-page in raw storage order.  Depends on the typed
  sqlite3_test_control(SQLITE_TESTCTRL_IMPOSTER,...) overload added in
  passqlite3main.pas.  `.imposter off` resets all schemas. }
function cmdImposter(p: PShellState; const args: array of AnsiString;
                     nArg: SizeInt): i32;
var
  zSql, zCollist, zNewCol: PAnsiChar;
  pStmt: PVdbe;
  tnum, isWO, lenPK, i: i32;
  rc: i32;
  zCol: PAnsiChar;
  zLabel: AnsiString;
  zSqlTab: PAnsiChar;
  szCollist: i32;
begin
  Result := 0;
  zCollist := nil;
  tnum := 0;
  isWO := 0;
  lenPK := 0;
  { nArg here is the count of POST-azArg[0] arguments (the dot-cmd
    name was already consumed by the dispatcher).  C requires
    nArg==3 (.imposter X Y) or nArg==2 with azArg[1]="off"; in our
    indexing that maps to nArg=2 or (nArg=1 and args[0]="off"). }
  if not ((nArg = 2) or ((nArg = 1) and (SameText(args[0], 'off')))) then
  begin
    shellEPutZ('Usage: .imposter INDEX IMPOSTER'#10 +
               '       .imposter off'#10);
    Result := 1;
    Exit;
  end;
  openDb(p, 0);
  if nArg = 1 then begin
    sqlite3_test_control(SQLITE_TESTCTRL_IMPOSTER, p^.db,
                         PAnsiChar('main'), 0, 1);
    Exit;
  end;
  zSql := sqlite3MPrintf(nil,
    'SELECT rootpage, 0 FROM sqlite_schema'
    + ' WHERE type=''index'' AND lower(name)=lower(''%q'')'
    + 'UNION ALL '
    + 'SELECT rootpage, 1 FROM sqlite_schema'
    + ' WHERE type=''table'' AND lower(name)=lower(''%q'')'
    + '   AND sql LIKE ''%%without%%rowid%%''',
    [PAnsiChar(args[0]), PAnsiChar(args[0])]);
  pStmt := nil;
  sqlite3_prepare_v2(p^.db, zSql, -1, @pStmt, nil);
  sqlite3_free(zSql);
  if sqlite3_step(pStmt) = SQLITE_ROW then begin
    tnum := sqlite3_column_int(pStmt, 0);
    isWO := sqlite3_column_int(pStmt, 1);
  end;
  sqlite3_finalize(pStmt);
  zSql := sqlite3MPrintf(nil, 'PRAGMA index_xinfo=''%q''',
    [PAnsiChar(args[0])]);
  rc := sqlite3_prepare_v2(p^.db, zSql, -1, @pStmt, nil);
  sqlite3_free(zSql);
  i := 0;
  while (rc = SQLITE_OK) and (sqlite3_step(pStmt) = SQLITE_ROW) do begin
    zCol := PAnsiChar(sqlite3_column_text(pStmt, 2));
    Inc(i);
    if zCol = nil then begin
      if sqlite3_column_int(pStmt, 1) = -1 then
        zCol := PAnsiChar('_ROWID_')
      else begin
        zLabel := Format('expr%d', [i]);
        zCol := PAnsiChar(zLabel);
      end;
    end;
    if (isWO <> 0) and (lenPK = 0)
       and (sqlite3_column_int(pStmt, 5) = 0)
       and (zCollist <> nil) then
      lenPK := i32(StrLen(zCollist));
    if zCollist = nil then
      zCollist := sqlite3MPrintf(nil, '"%w"', [zCol])
    else begin
      zNewCol := sqlite3MPrintf(nil, '%s,"%w"', [zCollist, zCol]);
      sqlite3_free(zCollist);
      zCollist := zNewCol;
    end;
  end;
  sqlite3_finalize(pStmt);
  if (i = 0) or (tnum = 0) then begin
    shellEPutZ(Format('no such index: "%s"'#10, [args[0]]));
    Result := 1;
    sqlite3_free(zCollist);
    Exit;
  end;
  if lenPK = 0 then lenPK := 100000;
  szCollist := i32(StrLen(zCollist));
  if lenPK > szCollist then lenPK := szCollist;
  zSqlTab := sqlite3MPrintf(nil,
    'CREATE TABLE "%w"(%s,PRIMARY KEY(%.*s))WITHOUT ROWID',
    [PAnsiChar(args[1]), zCollist, lenPK, zCollist]);
  sqlite3_free(zCollist);
  rc := sqlite3_test_control(SQLITE_TESTCTRL_IMPOSTER, p^.db,
                             PAnsiChar('main'), 2, tnum);
  if rc = SQLITE_OK then begin
    rc := sqlite3_exec(p^.db, zSqlTab, nil, nil, nil);
    sqlite3_test_control(SQLITE_TESTCTRL_IMPOSTER, p^.db,
                         PAnsiChar('main'), 0, 0);
    if rc <> 0 then
      shellEPutZ(Format('Error in [%s]: %s'#10,
        [AnsiString(zSqlTab), AnsiString(sqlite3_errmsg(p^.db))]))
    else
      shellSPutZ(Format('%s;'#10, [AnsiString(zSqlTab)]));
  end else begin
    shellEPutZ(Format('SQLITE_TESTCTRL_IMPOSTER returns %d'#10, [rc]));
    rc := 1;
  end;
  sqlite3_free(zSqlTab);
  Result := rc;
end;

{ 10.1a.1.5  `.nonce STRING`            shell.c.in:10116..10128
  When ShellState.zNonce matches, clear bSafeMode for the *next*
  command and return 0 immediately (caller-side bSafeMode reset
  bypassed).  Mismatch is a hard exit — matches upstream cli_exit(1). }
function cmdNonce(p: PShellState; const args: array of AnsiString;
                  nArg: SizeInt): i32;
var
  zArg, zNonceS: AnsiString;
begin
  Result := 0;
  if nArg <> 1 then begin
    shellEPutZ('Usage: .nonce NONCE'#10);
    Result := 1;
    Exit;
  end;
  zArg := args[0];
  if p^.zNonce = nil then zNonceS := '' else zNonceS := AnsiString(p^.zNonce);
  if (zNonceS = '') or (zArg <> zNonceS) then begin
    shellEPutZ(Format('line %d: incorrect nonce: "%s"'#10,
      [p^.lineno, zArg]));
    Halt(1);
  end;
  p^.bSafeMode := 0;
  { Return 0; the do-not-reset signalling is implicit — bSafeMode is
    already 0 and the C trailing reset is harmless in the Pas build. }
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
  if zCmd = 'stats'     then begin Result := cmdStats(p, args, nArg); Exit; end;
  if zCmd = 'trace'     then begin Result := cmdTrace(p, args, nArg); Exit; end;
  if zCmd = 'show'      then begin Result := cmdShow(p, nArg); Exit; end;
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
  if zCmd = 'timer'     then begin Result := cmdTimer(p, args, nArg); Exit; end;
  if zCmd = 'eqp'       then begin Result := cmdEqp(p, args, nArg); Exit; end;
  if zCmd = 'explain'   then begin cmdExplain(p, args, nArg); Exit; end;
  if (zCmd = 'shell') or (zCmd = 'system') then begin
    Result := cmdShell(p, args, nArg, zCmd); Exit;
  end;
  if zCmd = 'cd'        then begin Result := cmdCd(p, args, nArg); Exit; end;
  if zCmd = 'log'       then begin Result := cmdLog(args, nArg); Exit; end;
  if zCmd = 'dbinfo'    then begin Result := cmdDbinfo(p, args, nArg); Exit; end;
  if (zCmd = 'crlf') or (zCmd = 'crnl') then begin cmdCrnl(p, args, nArg); Exit; end;
  if zCmd = 'binary'    then begin cmdBinary; Result := 1; Exit; end;
  if zCmd = 'breakpoint' then begin cmdBreakpoint; Exit; end;
  if zCmd = 'width'     then begin cmdWidth(p, args, nArg); Exit; end;
  if zCmd = 'parameter' then begin cmdParameter(p, args, nArg); Exit; end;
  if zCmd = 'read'      then begin cmdRead(p, args, nArg); Exit; end;
  if zCmd = 'import'    then begin cmdImport(p, args, nArg); Exit; end;
  if (zCmd = 'backup') or (zCmd = 'save') then begin
    Result := cmdBackup(p, args, nArg, zCmd); Exit;
  end;
  if zCmd = 'restore'   then begin Result := cmdRestore(p, args, nArg); Exit; end;
  if zCmd = 'clone'     then begin Result := cmdClone(p, args, nArg); Exit; end;
  if zCmd = 'open'      then begin cmdOpen(p, args, nArg); Exit; end;
  if zCmd = 'connection' then begin Result := cmdConnection(p, args, nArg); Exit; end;
  if zCmd = 'unmodule'  then begin Result := cmdUnmodule(p, args, nArg); Exit; end;
  if zCmd = 'vfsinfo'   then begin cmdVfsinfo(p, args, nArg); Exit; end;
  if zCmd = 'vfslist'   then begin cmdVfslist(p); Exit; end;
  if zCmd = 'vfsname'   then begin cmdVfsname(p, args, nArg); Exit; end;
  if zCmd = 'filectrl'  then begin Result := cmdFilectrl(p, args, nArg); Exit; end;
  if zCmd = 'testctrl'  then begin
    Result := cmdTestctrl(p, args, nArg); Exit;
  end;
  if zCmd = 'fullschema' then begin cmdFullschema(p, args, nArg); Exit; end;
  if zCmd = 'lint'      then begin cmdLint(p, args, nArg); Exit; end;
  if zCmd = 'expert'    then begin cmdExpert(p, args, nArg); Result := 1; Exit; end;
  if zCmd = 'recover'   then begin cmdRecover(p, args, nArg); Exit; end;
  if zCmd = 'session'   then begin cmdSession(p, args, nArg); Exit; end;
  { .iotrace: upstream is SQLITE_ENABLE_IOTRACE-gated; in the non-debug
    build it falls through to the unknown-command arm, so do NOT route. }
  if (zCmd = 'selecttrace') or (zCmd = 'wheretrace')
     or (zCmd = 'treetrace') then
  begin cmdTraceFlags(zCmd, args, nArg); Exit; end;
  if zCmd = 'testcase'  then begin Result := cmdTestcase(p, args, nArg); Exit; end;
  if zCmd = 'check'     then begin Result := cmdCheck(p, args, nArg); Exit; end;
  if zCmd = 'dbconfig'  then begin cmdDbconfig(p, args, nArg); Exit; end;
  if (zCmd = 'scanstats') or (zCmd = 'scanstatus') then begin
    Result := cmdScanstats(p, args, nArg); Exit;
  end;
  if (zCmd = 'output') or (zCmd = 'once') or (zCmd = 'excel')
     or (zCmd = 'www') then begin
    cmdOutput(p, args, nArg, zCmd); Exit;
  end;
  if zCmd = 'dbtotxt' then begin cmdDbtotxt(p); Exit; end;
  if zCmd = 'dump' then begin cmdDump(p, args, nArg); Exit; end;
  if zCmd = 'sha3sum' then begin Result := cmdSha3sum(p, args, nArg); Exit; end;
  if (zCmd = 'archive') or (zCmd = 'ar') then begin
    cmdArchive(p, args, nArg); Exit;
  end;
  if zCmd = 'print' then begin
    for i := 0 to nArg - 1 do begin
      if i > 0 then Write(' ');
      Write(args[i]);
    end;
    WriteLn;
    Exit;
  end;
  { 10.1a.1.1..5  bite-sized handlers (.bail/.timeout/.version/.prompt/.nonce). }
  if zCmd = 'bail'      then begin Result := cmdBail(args, nArg); Exit; end;
  if zCmd = 'timeout'   then begin Result := cmdTimeout(p, args, nArg); Exit; end;
  if zCmd = 'version'   then begin Result := cmdVersion(p); Exit; end;
  if zCmd = 'prompt'    then begin Result := cmdPrompt(args, nArg); Exit; end;
  if zCmd = 'nonce'     then begin Result := cmdNonce(p, args, nArg); Exit; end;
  { 10.1a.1.6/.9/.10  .limit / .load / .intck — dot-command wrappers. }
  if (zCmd = 'limit') or (zCmd = 'limits') then begin
    Result := cmdLimit(p, args, nArg); Exit;
  end;
  if zCmd = 'intck'     then begin Result := cmdIntck(p, args, nArg); Exit; end;
  if zCmd = 'load'      then begin Result := cmdLoad(p, args, nArg); Exit; end;
  { 10.1a.1.7  .imposter — wraps SQLITE_TESTCTRL_IMPOSTER. }
  if zCmd = 'imposter'  then begin Result := cmdImposter(p, args, nArg); Exit; end;

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
{ shell.c.in:12365..12371 — echo_group_input.  When `.echo on`, the next
  SQL statement or dot-command line is echoed to the current output sink
  immediately before it runs.  Mirrors upstream cli_printf+fflush. }
procedure echoGroupInput(p: PShellState; const zDo: AnsiString);
begin
  if (p^.mode.mFlags and MFLG_ECHO) <> 0 then begin
    WriteLn(zDo);
    Flush(Output);
  end;
end;

function processInput(p: PShellState): i32;
var
  zLine, zSql: AnsiString;
  atEof: Boolean;
  errCnt: i32;
  startLine: i64;
  rc: i32;
  isCont: Boolean;
  qss: TQuickScanState;
begin
  errCnt := 0;
  startLine := 0;
  zSql := '';
  qss := 0;     { QSS_Start — shell.c.in:12436 }
  if p^.inputNesting = MAX_INPUT_NESTING then begin
    shellEPutZ(Format('%s: Input nesting limit (%d) reached at line %d.'#10,
      [string(AnsiString(p^.zInFile)), MAX_INPUT_NESTING, p^.lineno]));
    Result := 1;
    Exit;
  end;
  Inc(p^.inputNesting);
  continuePromptReset;     { shell.c.in:12439 }
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

    { 10.1.2.b — shell.c.in:12451..12455.  When we're not inside an open
      string/comment AND this line is a bare `go` or `/` terminator AND
      the buffered SQL would be complete with a trailing `;`, rewrite
      the line to `;` so the accumulator below cuts the statement. }
    if QSS_INPLAIN(qss)
       and lineIsCommandTerminator(PAnsiChar(zLine))
       and lineIsComplete(zSql) then
    begin
      zLine := ';';
    end;

    { shell.c.in:12458 — advance quickscan state for this line. }
    qss := quickScan(PAnsiChar(zLine), qss, @dynPrompt);

    { shell.c.in:12459..12463 — swallow plain-white / comment-only lines
      while the accumulator is empty. }
    if QSS_PLAINWHITE(qss) and (zSql = '') then begin
      echoGroupInput(p, zLine);
      qss := 0;
      Continue;
    end;

    if (zSql = '') and (startsWithDot(zLine) or startsWithHash(zLine)) then begin
      continuePromptReset;       { shell.c.in:12466 }
      echoGroupInput(p, zLine);
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
      qss := 0;
      Continue;                    { '#' lines are silent comments }
    end;

    if zSql = '' then begin
      zSql := zLine;
      startLine := p^.lineno;
    end else
      zSql := zSql + #10 + zLine;

    { shell.c.in:12507 — QSS_SEMITERM(qss) && sqlite3_complete(zSql).
      quickscan supplies the "logical semicolon at end of line" predicate
      so trailing `-- comment` after `;` still trips the cut. }
    if (zSql <> '') and QSS_SEMITERM(qss)
       and (sqlite3_complete(PAnsiChar(zSql)) <> 0) then
    begin
      echoGroupInput(p, zSql);
      Inc(errCnt, runOneSqlLine(p, zSql, AnsiString(p^.zInFile), startLine));
      continuePromptReset;       { shell.c.in:12510 }
      zSql := '';
      qss := 0;     { shell.c.in:12523 }
      { shell.c.in:12512..12517 — at end of each SQL line, immediately
        revert any active .once redirect. }
      if p^.nPopOutput > 0 then begin
        outputReset(p);
        p^.nPopOutput := 0;
      end;
    end else if (zSql <> '') and QSS_PLAINWHITE(qss) then begin
      { shell.c.in:12524..12528 — accumulator went all-whitespace after
        comments stripped; discard without running. }
      echoGroupInput(p, zSql);
      zSql := '';
      qss := 0;
    end;
  end;
  if zSql <> '' then begin
    echoGroupInput(p, zSql);
    Inc(errCnt, runOneSqlLine(p, zSql, AnsiString(p^.zInFile), startLine));
    continuePromptReset;       { shell.c.in:12534 }
  end;
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
  10.1.3  main + process_command_line.

  Two-pass argument parser mirroring shell.c.in:13040..13520:
    * pass 1 picks up early/global flags that must run before openDb
      (config-style, -bail, -batch, -init, -nonce, -unsafe-testing, ...);
    * pass 2 runs *after* sqliterc + the fallback openDb so that command-
      line settings override anything the init script did (modes,
      separators, header toggles, -cmd commands, etc.).

  All documented flags are accepted; many config-only flags (heap,
  pagecache, lookaside, mmap, sorterref, multiplex, memtrace,
  pcachetrace, vfstrace) are wired where state already exists and
  consume their argument otherwise — the upstream behaviour is
  retained even when the underlying engine knob is not yet plumbed in
  the Pascal port.  Pass-1 / pass-2 split is preserved as in C.
  ---------------------------------------------------------------------- }

{ ----------------------------------------------------------------------
  10.1.3.a  find_home_dir + find_xdg_file + process_sqliterc
            — shell.c.in:12548..12714

  Linux-only port: the WIN32/_WRS_KERNEL/__RTP__ arms in C are skipped
  outright (passqlite3 README pins the supported targets to Linux), so
  find_home_dir collapses to the getpwuid()/HOME lookup and
  find_xdg_file is unconditional (no early `return 0` on Windows).

  find_home_dir caches the result in a unit-scope AnsiString.  The C
  function returns a malloc'd char* and the cached pointer remains
  valid for the lifetime of the process; mirroring with a static
  AnsiString and returning PAnsiChar(cached) is byte-equivalent.
  ---------------------------------------------------------------------- }

var
  cachedHomeDir: AnsiString = '';

function findHomeDir(clearFlag: Boolean): AnsiString;
var
  zEnv: PAnsiChar;
begin
  if clearFlag then begin
    cachedHomeDir := '';
    Result := '';
    Exit;
  end;
  if cachedHomeDir <> '' then begin
    Result := cachedHomeDir;
    Exit;
  end;

  { Deviation: C tries getpwuid(getuid()) first, then falls back to
    $HOME (shell.c.in:12564..12588).  FPC's BaseUnix does not expose a
    getpwuid binding (lives in the optional `users` package), and the
    fallback is the dominant arm on every modern Linux session.  We
    skip the getpwuid arm and rely on $HOME directly — semantically
    identical whenever $HOME is set, which is the case for any
    interactive or systemd-service user. }
  Result := '';
  zEnv := fpGetenv('HOME');
  if zEnv <> nil then Result := AnsiString(zEnv);

  if Result <> '' then cachedHomeDir := Result;
end;

function findXdgFile(const zEnvVar, zSubdir, zBaseName: AnsiString): AnsiString;
var
  zXdgDir: PAnsiChar;
  zHome, zPath: AnsiString;
begin
  Result := '';
  zXdgDir := nil;
  if zEnvVar <> '' then zXdgDir := fpGetenv(PAnsiChar(zEnvVar));
  if zXdgDir <> nil then begin
    zPath := AnsiString(zXdgDir) + '/' + zBaseName;
  end else begin
    zHome := findHomeDir(False);
    if zHome = '' then Exit;
    if zSubdir <> '' then
      zPath := zHome + '/' + zSubdir + '/' + zBaseName
    else
      zPath := zHome + '/' + zBaseName;
  end;
  if FileExists(string(zPath)) then Result := zPath;
end;

{ process_sqliterc — shell.c.in:12659..12714.

  Mirrors the C control flow: optional override, otherwise XDG lookup,
  otherwise ~/.sqliterc.  Routes line reads through curInputText (same
  idiom as cmdRead), saves/restores p^.inFile sentinel + zInFile +
  lineno across the nested processInput call. }

procedure processSqliteRc(p: PShellState; const sqlitercOverride: AnsiString);
var
  sqliterc: AnsiString;
  f: Text;
  savedIn: ^Text;
  savedInFile: PFILE;
  savedLineno: i64;
  savedZIn: PAnsiChar;
  ioErr: Word;
  homeDir: AnsiString;
  opened: Boolean;
begin
  sqliterc := sqlitercOverride;

  if sqliterc = '' then
    sqliterc := findXdgFile('XDG_CONFIG_HOME', '.config', 'sqlite3/sqliterc');

  if sqliterc = '' then begin
    homeDir := findHomeDir(False);
    if homeDir = '' then begin
      shellEPutZ('-- warning: cannot find home directory;'
        + ' cannot read ~/.sqliterc'#10);
      Exit;
    end;
    sqliterc := homeDir + '/.sqliterc';
  end;

  opened := False;
  AssignFile(f, string(sqliterc));
  {$I-} Reset(f); {$I+}
  ioErr := IOResult;
  if ioErr = 0 then opened := True;

  if opened then begin
    if stdin_is_interactive <> 0 then
      shellEPutZ(Format('-- Loading resources from %s'#10, [sqliterc]));
    savedIn      := curInputText;
    savedInFile  := p^.inFile;
    savedLineno  := p^.lineno;
    savedZIn     := p^.zInFile;
    curInputText := @f;
    { Mark inFile non-nil so processInput's stdin-only guards (e.g.
      "while errCnt=0 OR bail OR (inFile=nil and interactive)") behave
      as if reading from a real FILE*.  The sentinel is what matters;
      the value itself is not dereferenced for curInputText reads. }
    p^.inFile    := PFILE(Pointer(1));
    p^.lineno    := 0;
    p^.zInFile   := PAnsiChar(sqliterc);
    if (processInput(p) <> 0) and (bail_on_error <> 0) then begin
      CloseFile(f);
      curInputText := savedIn;
      p^.inFile    := savedInFile;
      p^.lineno    := savedLineno;
      p^.zInFile   := savedZIn;
      Halt(1);
    end;
    CloseFile(f);
    curInputText := savedIn;
    p^.inFile    := savedInFile;
    p^.lineno    := savedLineno;
    p^.zInFile   := savedZIn;
  end else if sqlitercOverride <> '' then begin
    shellEPutZ(Format('cannot open: "%s"'#10, [sqliterc]));
    if bail_on_error <> 0 then Halt(1);
  end;
end;

procedure printUsage(toErr: Boolean);
const
  zUsage =
    'Usage: passqlite3 [OPTIONS] [FILENAME [SQL]]'#10 +
    'FILENAME is the name of an SQLite database. A new database is created'#10 +
    'if the file does not previously exist.  Defaults to :memory:.'#10 +
    'OPTIONS include:'#10 +
    '   -- ARGS...           treat remaining args as positional'#10 +
    '   -A ARGS...           run ".archive ARGS" and exit'#10 +
    '   -append              open the file using the apndvfs VFS'#10 +
    '   -ascii               set output mode to "ascii"'#10 +
    '   -bail                stop after hitting an error'#10 +
    '   -batch               force batch I/O'#10 +
    '   -box                 set output mode to "box"'#10 +
    '   -column              set output mode to "column"'#10 +
    '   -cmd COMMAND         run COMMAND before reading stdin'#10 +
    '   -csv                 set output mode to "csv"'#10 +
    '   -echo                print commands before execution'#10 +
    '   -eqp                 enable automatic EXPLAIN QUERY PLAN'#10 +
    '   -eqpfull             enable EXPLAIN QUERY PLAN with detail'#10 +
    '   -escape MODE         escape mode (auto, off, ascii, symbol)'#10 +
    '   -exclusive           open db with SQLITE_OPEN_EXCLUSIVE'#10 +
    '   -header              turn headers on'#10 +
    '   -heap SIZE           Size of heap for memsys3 or memsys5'#10 +
    '   -help                show this message'#10 +
    '   -html                set output mode to HTML'#10 +
    '   -ifexists            fail if the database file does not exist'#10 +
    '   -init FILENAME       read/process FILENAME at startup'#10 +
    '   -interactive         force interactive I/O'#10 +
    '   -json                set output mode to "json"'#10 +
    '   -line                set output mode to "line"'#10 +
    '   -list                set output mode to "list"'#10 +
    '   -lookaside SZ N      use N entries of SZ bytes for lookaside'#10 +
    '   -markdown            set output mode to "markdown"'#10 +
    '   -maxsize N           maximum size for a -deserialize database'#10 +
    '   -memtrace            trace all memory allocations and deallocations'#10 +
    '   -mmap N              default mmap size set to N'#10 +
    '   -newline SEP         set output row separator. Default: ''\n'''#10 +
    '   -nofollow            refuse to open symbolic links to db files'#10 +
    '   -noheader            turn headers off'#10 +
    '   -no-rowid-in-view    Disable ROWID-in-view (off by default)'#10 +
    '   -nonce STRING        set the safe-mode escape nonce'#10 +
    '   -nullvalue TEXT      set text string for NULL values. Default ''  '''#10 +
    '   -pagecache SZ N      use N slots of SZ bytes each for page cache'#10 +
    '   -pcachetrace         trace all page cache operations'#10 +
    '   -quote               set output mode to ''quote'''#10 +
    '   -readonly            open the database read-only'#10 +
    '   -safe                enable safe-mode'#10 +
    '   -separator SEP       set output column separator. Default: ''|'''#10 +
    '   -stats               print memory stats before each finalize'#10 +
    '   -table               set output mode to "table"'#10 +
    '   -tabs                set output mode to "tabs"'#10 +
    '   -threadsafe N        threading mode (0=single, 1=serialized, 2=multi)'#10 +
    '   -unsafe-testing      allow unsafe commands and modes'#10 +
    '   -utf8                use UTF-8 for I/O (default)'#10 +
    '   -no-utf8             do not use UTF-8 for I/O'#10 +
    '   -version             show SQLite version'#10 +
    '   -vfs NAME            use NAME as the default VFS'#10;
begin
  if toErr then shellEPutZ(zUsage) else shellSPutZ(zUsage);
end;

function isFlagArg(const a: AnsiString; const flag: AnsiString): Boolean;
begin
  Result := (a = '-' + flag) or (a = '--' + flag);
end;

{ Mirrors cli_strcmp on a flag arg post double-dash strip:
  given an argv element starting with '-' (or '--'), test against
  the canonical single-dash form.  argA is the original argv string. }
function flagEq(const argA: AnsiString; const flagSingleDash: AnsiString): Boolean;
begin
  if (Length(argA) >= 2) and (argA[1] = '-') and (argA[2] = '-') then
    Result := Copy(argA, 2, Length(argA)) = flagSingleDash
  else
    Result := argA = flagSingleDash;
end;

{ shell.c.in cmdline_option_value: returns argv[++i], aborting if i is
  past the end. }
function cmdlineOptionValue(argc, idx: i32; out outVal: AnsiString): Boolean;
begin
  if idx > argc then begin
    shellEPutZ(Format('%s: Error: missing argument to %s'#10,
                      [string(Argv0), string(ParamStr(idx - 1))]));
    Result := False;
    outVal := '';
  end else begin
    outVal := AnsiString(ParamStr(idx));
    Result := True;
  end;
end;

{ Parse a decimal/hex integer like sqlite3 integerValue (shell.c.in
  helper).  Recognises ``0xFF``, ``-1234``, ``1k``/``1K``/``1m``/``1g``
  suffixes for kilo/mega/giga (×1000). }
function shellIntegerValue(const z: AnsiString): i64;
var
  s: AnsiString;
  v: i64;
  neg: Boolean;
  k, n: SizeInt;
  c: AnsiChar;
begin
  v := 0;
  s := z;
  neg := False;
  k := 1;
  n := Length(s);
  if (n >= 1) and (s[1] = '-') then begin neg := True; Inc(k); end
  else if (n >= 1) and (s[1] = '+') then Inc(k);
  if (n - k >= 1) and (s[k] = '0') and ((s[k+1] = 'x') or (s[k+1] = 'X')) then begin
    Inc(k, 2);
    while k <= n do begin
      c := s[k];
      case c of
        '0'..'9': v := v * 16 + (Ord(c) - Ord('0'));
        'a'..'f': v := v * 16 + (Ord(c) - Ord('a') + 10);
        'A'..'F': v := v * 16 + (Ord(c) - Ord('A') + 10);
      else
        Break;
      end;
      Inc(k);
    end;
  end else begin
    while (k <= n) and (s[k] in ['0'..'9']) do begin
      v := v * 10 + (Ord(s[k]) - Ord('0'));
      Inc(k);
    end;
    if k <= n then begin
      case s[k] of
        'k', 'K': v := v * 1000;
        'm', 'M': v := v * 1000 * 1000;
        'g', 'G': v := v * 1000 * 1000 * 1000;
      end;
    end;
  end;
  if neg then v := -v;
  Result := v;
end;

{ Build a clean dash-stripped form: '--foo' → '-foo'.  Returns the
  canonical single-dash form for use with flagEq. }
function canonFlag(const a: AnsiString): AnsiString;
begin
  if (Length(a) >= 2) and (a[1] = '-') and (a[2] = '-') then
    Result := Copy(a, 2, Length(a))
  else
    Result := a;
end;

type
  { Deferred -cmd / positional-SQL / dot-command list — populated in
    pass 1, executed after openDb in shellMain, mirroring shell.c.in's
    azCmd / nCmd array. }
  TDeferredCmd = record
    z:    AnsiString;
    iArg: i32;        { original argv index, used as line-no in errors }
    isCmd: Boolean;   { true ⇒ came from -cmd; runs in the goofy
                        pre-stdin pass to retain shell.c.in compat }
  end;
  TDeferredCmdArr = array of TDeferredCmd;

procedure deferredAdd(var arr: TDeferredCmdArr; const z: AnsiString;
                      iArg: i32; isCmd: Boolean);
var k: SizeInt;
begin
  k := Length(arr);
  SetLength(arr, k + 1);
  arr[k].z := z;
  arr[k].iArg := iArg;
  arr[k].isCmd := isCmd;
end;

function shellMain: i32;
var
  state: TShellState;
  i, n: i32;
  argA, z, optVal: AnsiString;
  zFilename, zVfs, zInitFile, zMode: AnsiString;
  initialSql: AnsiString;
  noInit, readStdin: Boolean;
  rc, k, threads: i32;
  szArg: i64;
  cmdQueue: TDeferredCmdArr;
  positional: TDeferredCmdArr;
  nOptsEnd: i32;
  haveDbName: Boolean;
begin
  Result := 0;
  shellStateInit(@state);
  Argv0 := AnsiString(ParamStr(0));
  zFilename := '';
  zVfs := '';
  zInitFile := '';
  initialSql := '';
  noInit := False;
  readStdin := True;
  haveDbName := False;
  cmdQueue := nil;
  positional := nil;

  stdin_is_interactive := Ord(IsATTY(StdInputHandle) <> 0);
  stdout_is_console    := Ord(IsATTY(StdOutputHandle) <> 0);

  installInterruptHandler;
  outputInit;

  { shell.c.in:12820 — enable URI filenames so `file:...?mode=rwc` etc. are
    honored both on the CLI and via `.open`. }
  sqlite3_config(SQLITE_CONFIG_URI, 1);

  { shell.c.in:12816 — install the shellLog trampoline so `.log` can route
    sqlite3_log() output through the configured FILE*.  pCtx is unused on
    the Pascal side (gLogFile is module-level) but we still pass `state`
    to match the C-shell shape. }
  sqlite3_config(SQLITE_CONFIG_LOG, @shellLog, @state);

  n := ParamCount;
  nOptsEnd := n + 1;          { everything is fair game for flags by default }

  { ---------------- Pass 1: pre-init flags ---------------- }
  i := 1;
  while i <= n do begin
    argA := AnsiString(ParamStr(i));
    if (argA = '') or (argA[1] <> '-') or (i > nOptsEnd) then begin
      { positional argument: first non-flag becomes the dbname (if not
        already set), rest are deferred SQL/dot-commands. }
      if (not haveDbName) and ((Length(argA) = 0) or (argA[1] <> '-')) then begin
        zFilename := argA;
        haveDbName := True;
      end else begin
        readStdin := False;
        stdin_is_interactive := 0;
        deferredAdd(positional, argA, i, False);
      end;
      Inc(i);
      Continue;
    end;
    z := canonFlag(argA);
    if z = '-' then begin
      nOptsEnd := i;
      Inc(i);
      Continue;
    end;
    if (z = '-separator') or (z = '-nullvalue') or (z = '-newline')
       or (z = '-cmd') then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      if z = '-cmd' then deferredAdd(cmdQueue, optVal, i, True);
    end else if z = '-init' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, zInitFile) then Exit(1);
    end else if z = '-interactive' then
      stdin_is_interactive := 1
    else if z = '-batch' then begin
      stdin_is_interactive := 0;
      stdout_is_console := 0;
      modeChange(@state, MODE_BATCH);
    end else if z = '-screenwidth' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      k := i32(shellIntegerValue(optVal));
      if k < 2 then begin
        shellEPutZ('minimum --screenwidth is 2'#10);
        Exit(1);
      end;
      stdout_tty_width := k;
    end else if (z = '-utf8') or (z = '-no-utf8')
             or (z = '-no-rowid-in-view') then
      { accepted, no Pascal-side wiring needed }
    else if (z = '-memtrace') then
      { shell.c.in:13196 — no-arg flag; activates memtrace trampoline. }
      sqlite3MemTraceActivate(shellLibcStderr)
    else if (z = '-pcachetrace') then
      { shell.c.in:13198 — no-arg flag; activates pcachetrace trampoline. }
      sqlite3PcacheTraceActivate(shellLibcStderr)
    else if (z = '-heap') or (z = '-mmap') or (z = '-vfstrace')
         or (z = '-multiplex') or (z = '-sorterref')
         or (z = '-vfs') then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      if z = '-vfs' then zVfs := optVal;
      if z = '-mmap' then begin
        szArg := shellIntegerValue(optVal);
        if szArg = 0 then ;     { wiring deferred — int-shape sqlite3_config
                                  has no MMAP_SIZE arm yet }
      end;
    end else if (z = '-pagecache') or (z = '-lookaside') then begin
      { 2-arg sizing flags — the int-shape sqlite3_config does not
        cover these; consume the args and continue. }
      Inc(i, 2);
      if i > n then begin
        shellEPutZ(Format('%s: Error: missing argument to %s'#10,
                          [string(Argv0), string(argA)]));
        Exit(1);
      end;
    end else if z = '-threadsafe' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      threads := i32(shellIntegerValue(optVal));
      case threads of
        0: sqlite3_config(SQLITE_CONFIG_SINGLETHREAD, 0);
        2: sqlite3_config(SQLITE_CONFIG_MULTITHREAD, 0);
      else
        sqlite3_config(SQLITE_CONFIG_SERIALIZED, 0);
      end;
    end else if z = '-zip' then
      state.openMode := SHELL_OPEN_ZIPFILE
    else if z = '-append' then
      state.openMode := SHELL_OPEN_APPENDVFS
    else if z = '-deserialize' then
      state.openMode := SHELL_OPEN_DESERIALIZE
    else if z = '-maxsize' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      state.szMax := shellIntegerValue(optVal);
    end else if z = '-readonly' then begin
      state.openFlags := state.openFlags
        and not (SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
      state.openFlags := state.openFlags or SQLITE_OPEN_READONLY;
    end else if z = '-nofollow' then
      state.openFlags := state.openFlags or SQLITE_OPEN_NOFOLLOW
    else if z = '-noinit' then
      noInit := True
    else if z = '-exclusive' then
      state.openFlags := state.openFlags or SQLITE_OPEN_EXCLUSIVE
    else if z = '-ifexists' then begin
      state.openFlags := state.openFlags and not SQLITE_OPEN_CREATE;
      if state.openFlags = 0 then
        state.openFlags := SQLITE_OPEN_READWRITE;
    end else if z = '-bail' then
      bail_on_error := 1
    else if z = '-nonce' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      gNonceBacking := optVal;
      state.zNonce := PAnsiChar(gNonceBacking);
    end else if z = '-unsafe-testing' then
      state.shellFlgs := state.shellFlgs or SHFLG_TestingMode
    else if z = '-safe' then begin
      { handled in pass 2 }
    end else if z = '-escape' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
    end else if z = '-test-argv' then begin
      for k := 0 to n do
        shellSPutZ(Format('argv[%d] = "%s"'#10, [k, string(ParamStr(k))]));
      Exit(0);
    end else if (Length(z) >= 2) and (z[1] = '-') and (z[2] = 'A') then begin
      { -A ... archive shorthand: not wired (zip extension absent),
        but consume remaining args so we don't error out. }
      Break;
    end else begin
      { Pass 1 doesn't error on unknown — pass 2 does, so unrecognised
        flags fall through here. }
    end;
    Inc(i);
  end;

  { ---------------- Open default db ---------------- }
  if not haveDbName then zFilename := ':memory:';
  state.aAuxDb[0].zDbFilename := PAnsiChar(zFilename);
  state.inFile := nil;
  state.outFile := nil;
  openDb(@state, 0);

  { 10.1.3.b — -init <file> payload load.  Mirrors shell.c.in:13309
    `if( !noInit ) process_sqliterc(&data, zInitFile)`.  An empty
    zInitFile is treated as NULL by processSqliteRc, triggering the
    XDG / ~/.sqliterc default lookup. }
  if not noInit then processSqliteRc(@state, zInitFile);

  { ---------------- Pass 2: settings overrides ---------------- }
  i := 1;
  while i <= n do begin
    argA := AnsiString(ParamStr(i));
    if (argA = '') or (argA[1] <> '-') or (i >= nOptsEnd) then begin
      Inc(i); Continue;
    end;
    z := canonFlag(argA);
    if z = '-init' then Inc(i)
    else if z = '-html' then modeChange(@state, MODE_Html)
    else if z = '-list' then modeChange(@state, MODE_List)
    else if z = '-quote' then modeChange(@state, MODE_Quote)
    else if z = '-line' then modeChange(@state, MODE_Line)
    else if z = '-column' then modeChange(@state, MODE_Column)
    else if z = '-json' then modeChange(@state, MODE_Json)
    else if z = '-markdown' then modeChange(@state, MODE_Markdown)
    else if z = '-table' then modeChange(@state, MODE_Table)
    else if z = '-psql' then modeChange(@state, MODE_Psql)
    else if z = '-box' then modeChange(@state, MODE_Box)
    else if z = '-csv' then modeChange(@state, MODE_Csv)
    else if z = '-ascii' then modeChange(@state, MODE_Ascii)
    else if z = '-tabs' then modeChange(@state, MODE_Tabs)
    else if z = '-escape' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      for k := 0 to High(qrfEscNames) do
        if SameText(string(optVal), string(AnsiString(qrfEscNames[k]))) then begin
          state.mode.spec.eEsc := u8(k);
          Break;
        end;
    end else if z = '-separator' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      zUserColSep := optVal;
      state.mode.spec.zColumnSep := PAnsiChar(zUserColSep);
    end else if z = '-newline' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      zUserRowSep := optVal;
      state.mode.spec.zRowSep := PAnsiChar(zUserRowSep);
    end else if z = '-nullvalue' then begin
      Inc(i);
      if not cmdlineOptionValue(n, i, optVal) then Exit(1);
      zUserNull := optVal;
      state.mode.spec.zNull := PAnsiChar(zUserNull);
    end else if z = '-header' then
      state.mode.spec.bTitles := QRF_Yes
    else if z = '-noheader' then
      state.mode.spec.bTitles := QRF_No
    else if z = '-echo' then
      state.mode.mFlags := state.mode.mFlags or MFLG_ECHO
    else if z = '-eqp' then
      state.mode.autoEQP := AUTOEQP_on
    else if z = '-eqpfull' then
      state.mode.autoEQP := AUTOEQP_full
    else if z = '-stats' then
      state.statsOn := 1
    else if z = '-scanstats' then
      state.mode.scanstatsOn := 1
    else if z = '-backslash' then
      state.shellFlgs := state.shellFlgs or SHFLG_Backslash
    else if z = '-bail' then
      { already set in pass 1 }
    else if z = '-version' then begin
      shellSPutZ(AnsiString(sqlite3_libversion) + ' (64-bit)' + sLineBreak);
      Exit(0);
    end else if z = '-interactive' then
      stdin_is_interactive := 1
    else if z = '-batch' then
      { already handled }
    else if (z = '-screenwidth') or (z = '-heap') or (z = '-mmap')
         or (z = '-memtrace') or (z = '-pcachetrace')
         or (z = '-sorterref') or (z = '-vfs')
         or (z = '-vfstrace') or (z = '-multiplex')
         or (z = '-init') then
      Inc(i)            { 1-arg: skip the value }
    else if (z = '-pagecache') or (z = '-lookaside')
         or (z = '-threadsafe') or (z = '-nonce') then
      Inc(i, 1)         { same as 1-arg here; pass 1 already consumed }
    else if z = '-help' then begin
      printUsage(False);
      Exit(0);
    end else if z = '-cmd' then begin
      Inc(i);
      { already queued in pass 1 — skip the arg here }
    end else if z = '-safe' then begin
      state.bSafeMode := 1;
      state.bSafeModePersist := 1;
    end else if (z = '-utf8') or (z = '-no-utf8') or (z = '-no-rowid-in-view')
             or (z = '-readonly') or (z = '-nofollow') or (z = '-noinit')
             or (z = '-exclusive') or (z = '-ifexists')
             or (z = '-zip') or (z = '-append') or (z = '-deserialize')
             or (z = '-maxsize') or (z = '-test-argv')
             or (z = '-unsafe-testing') then begin
      { Already handled in pass 1.  Some take an extra arg: }
      if z = '-maxsize' then Inc(i);
    end else if (Length(z) >= 2) and (z[1] = '-') and (z[2] = 'A') then begin
      Break;
    end else begin
      shellEPutZ(Format('%s: Error: unknown option: %s'#10,
                        [string(Argv0), string(argA)]));
      shellEPutZ('Use -help for a list of options.'#10);
      Exit(1);
    end;
    Inc(i);
  end;

  { ---------------- Run -cmd queue (goofy pre-stdin pass) ---------------- }
  for k := 0 to High(cmdQueue) do begin
    if (Length(cmdQueue[k].z) > 0) and (cmdQueue[k].z[1] = '.') then begin
      rc := doMetaCommand(cmdQueue[k].z, @state);
      if (rc <> 0) and (rc = 2) then Exit(0);
      if (rc <> 0) and (bail_on_error <> 0) then Exit(rc);
    end else begin
      rc := runOneSqlLine(@state, cmdQueue[k].z, 'cmdline', cmdQueue[k].iArg);
      if (rc <> 0) and (bail_on_error <> 0) then Exit(rc);
    end;
  end;

  { ---------------- Run trailing positionals ---------------- }
  { 6.22 — mirror shell.c.in:13539..13547: before each positional dot-command,
    set zInFile='<cmdline>' and zErrPrefix='argv[N]:' so shellErrorLocation
    (and failIfSafeMode) emit the argv-style prefix instead of the stdin
    "line N:" fallback.  Restored to nil after each dispatch. }
  for k := 0 to High(positional) do begin
    if (Length(positional[k].z) > 0) and (positional[k].z[1] = '.') then begin
      gErrPrefixBacking := AnsiString(Format('argv[%d]:', [positional[k].iArg]));
      state.zInFile := PAnsiChar(AnsiString('<cmdline>'));
      state.zErrPrefix := PAnsiChar(gErrPrefixBacking);
      rc := doMetaCommand(positional[k].z, @state);
      state.zErrPrefix := nil;
      gErrPrefixBacking := '';
      { shell.c.in:13548 — positional dot-cmd errors always exit (no
        bail_on_error gate); rc==2 is the .exit/.quit signal. }
      if rc <> 0 then begin
        if rc = 2 then Exit(0);
        Exit(rc);
      end;
    end else begin
      rc := runOneSqlLine(@state, positional[k].z, 'cmdline',
                          positional[k].iArg);
      if (rc <> 0) and (bail_on_error <> 0) then Exit(rc);
    end;
  end;

  { ---------------- REPL or bail ---------------- }
  if readStdin then begin
    state.zInFile := zStdinName;
    Result := processInput(@state);
  end else
    Result := 0;

  if state.expertPtr <> nil then expertFinish(@state, 1, nil);
  if state.db <> nil then begin
    closeDb(state.db);
    state.db := nil;
    globalDb := nil;
  end;
  state.zNonce := nil;
  gNonceBacking := '';
  { 10.1.40 — shell.c.in:13657..13662 test-summary epilogue.  Emitted to
    stdout when any .check ran; exit code becomes the failure count > 0. }
  if state.nTestRun > 0 then begin
    if state.nTestRun = 1 then
      if state.nTestErr = 1 then
        shellSPutZ(Format('%d test run with %d error'#10,
          [state.nTestRun, state.nTestErr]))
      else
        shellSPutZ(Format('%d test run with %d errors'#10,
          [state.nTestRun, state.nTestErr]))
    else if state.nTestErr = 1 then
      shellSPutZ(Format('%d tests run with %d error'#10,
        [state.nTestRun, state.nTestErr]))
    else
      shellSPutZ(Format('%d tests run with %d errors'#10,
        [state.nTestRun, state.nTestErr]));
    Flush(Output);
    if state.nTestErr > 0 then Result := 1;
  end;
  { Use the unused alias to satisfy the compiler — initialSql / zMode
    remain for future expansion (eventually map -mode <name> here). }
  if (initialSql = '') and (zMode = '') then ;
end;

begin
  ExitCode := shellMain;
end.
