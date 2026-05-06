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
  BaseUnix,
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
  p^.mode.spec.bTitles := 1;          { off by default in shell main() but
                                        flipped on by .headers; keep at
                                        1 here so the upcoming
                                        .headers default test compares
                                        cleanly. }
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
function oneInputLine(p: PShellState; isContinuation: Boolean;
                      out atEof: Boolean): AnsiString;
begin
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
  Result dispatch — minimal MODE_List renderer used until 10.1.8 lands.
  Mirrors the (heavily simplified) inner loop of exec_prepared_stmt
  (shell.c.in:8050..) for MODE_List with no headers.
  ---------------------------------------------------------------------- }

procedure renderRowList(pStmt: PVdbe; const sep: AnsiString);
var
  nCol, i: i32;
  z: PAnsiChar;
begin
  nCol := sqlite3_column_count(pStmt);
  for i := 0 to nCol - 1 do begin
    if i > 0 then Write(sep);
    z := sqlite3_column_text(pStmt, i);
    if z <> nil then Write(AnsiString(z));
  end;
  WriteLn;
end;

{ runOneSqlLine — shell.c.in runOneSqlLine (~12290..12365).  Prepare /
  step / finalize one statement; emit each row through the active
  renderer.  This is the minimum needed for the 10.2 integration parity
  gate to start evaluating SELECTs against a known canon.   }
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
    repeat
      stepRc := sqlite3_step(pStmt);
      if stepRc = SQLITE_ROW then renderRowList(pStmt, p^.mode.spec.zColumnSep);
    until stepRc <> SQLITE_ROW;
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

function doMetaCommand(const zLine: AnsiString; p: PShellState): i32;
var
  zCmd: AnsiString;
begin
  Result := 0;
  zCmd := dotCmdName(zLine);
  if zCmd = '' then Exit;

  { .quit / .exit — minimal viable REPL termination.  Mirrors the C
    arms in do_meta_command without --code support (10.1.5 follow-up). }
  if (zCmd = 'quit') or (zCmd = 'exit') then begin
    Result := 2;
    Exit;
  end;

  { .help — stub.  10.1.33 will replace with the upstream help table. }
  if zCmd = 'help' then begin
    shellSPutZ('.help               Show this list of dot-commands' + sLineBreak);
    shellSPutZ('.quit               Exit this program' + sLineBreak);
    shellSPutZ('(other dot-commands not yet ported — see tasklist 10.1.7+)' + sLineBreak);
    Exit;
  end;

  { .show — minimal so callers can sanity-check ShellState.  10.1.32
    replaces with full coverage. }
  if zCmd = 'show' then begin
    shellSPutZ(Format('  filename: %s'#10,
      [string(AnsiString(p^.pAuxDb^.zDbFilename))]));
    shellSPutZ(Format('   bail on error: %d'#10, [bail_on_error]));
    shellSPutZ(Format('   echo: %d'#10, [Ord((p^.mode.mFlags and MFLG_ECHO) <> 0)]));
    shellSPutZ(Format('   mode: %s'#10, [aModeInfo[p^.mode.eMode].zName]));
    Exit;
  end;

  { Default fall-through — match upstream phrasing exactly so that the
    10.2 integration parity gate diff'ing bin/passqlite3 against
    sqlite3 sees byte-identical stderr for unported commands. }
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
