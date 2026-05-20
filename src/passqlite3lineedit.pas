{ ----------------------------------------------------------------------
  passqlite3lineedit — raw-mode TTY line editor with history.

  Drop-in replacement for the plain ReadLn used by the interactive
  REPL.  Models linenoise's single-line editor: arrow-key cursor
  motion, Up/Down history recall, the usual Emacs-style control
  bindings (Ctrl-A/E/U/K/L/W), and Backspace/Delete.

  Falls back to plain ReadLn when stdin is not a TTY (pipes, here-docs,
  CI runs), so non-interactive callers see no behaviour change.

  History persists in memory for the lifetime of the process and may
  be loaded from / saved to a UTF-8 text file (one entry per line) via
  LineEditLoadHistory / LineEditSaveHistory.  Mirrors linenoise's
  linenoiseHistoryLoad / linenoiseHistorySave behaviour as used by
  shell.c.in (read_history / write_history) at startup / exit of the
  interactive REPL.
  ---------------------------------------------------------------------- }
unit passqlite3lineedit;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, BaseUnix, termio;

function LineEditIsTTY: Boolean;

{ Reads one line.  Prints `prompt` first.  When stdin is a TTY, runs
  the raw-mode editor; otherwise calls ReadLn.  On EOF (Ctrl-D on
  empty line, or end-of-file on stdin) sets atEof=True and returns ''.
  Ctrl-C cancels the current line and returns '' with atEof=False. }
function LineEditReadLine(const prompt: AnsiString;
                          out atEof: Boolean): AnsiString;

{ Append `line` to the in-memory history if it's non-empty and differs
  from the previous entry.  History size capped at HistoryMaxEntries. }
procedure LineEditAddHistory(const line: AnsiString);

{ Load history entries from `path` (one line per entry).  Silently
  no-ops when the file does not exist or cannot be opened — mirrors
  linenoiseHistoryLoad.  Returns True iff the file was opened. }
function LineEditLoadHistory(const path: AnsiString): Boolean;

{ Persist the current history to `path`, overwriting any existing
  file.  Mirrors linenoiseHistorySave: returns True on success. }
function LineEditSaveHistory(const path: AnsiString): Boolean;

{ Cap the in-memory history to at most `n` entries (oldest dropped
  first).  Mirrors linenoiseHistorySetMaxLen — shell.c.in calls
  shell_stifle_history(2000) right before write_history. }
procedure LineEditStifleHistory(n: Integer);

const
  HistoryMaxEntries = 1000;

implementation

uses
  Unix;

var
  rawModeActive:    Boolean = False;
  origTermios:      Termios;
  termiosInitDone:  Boolean = False;

  history:          array of AnsiString;
  historyCount:     Integer = 0;

{ ---- low-level I/O ---- }

function readByte(out b: Byte): Boolean;
var n: ssize_t;
begin
  n := fpRead(0, b, 1);
  Result := n = 1;
end;

procedure writeStr(const s: AnsiString); inline;
begin
  if Length(s) > 0 then
    fpWrite(1, s[1], Length(s));
end;

procedure writeByte(b: Byte); inline;
begin
  fpWrite(1, b, 1);
end;

{ ---- raw mode ---- }

function LineEditIsTTY: Boolean;
begin
  Result := (IsAtty(0) <> 0) and (IsAtty(1) <> 0);
end;

procedure restoreTerminal;
begin
  if rawModeActive then begin
    TCSetAttr(0, TCSAFLUSH, origTermios);
    rawModeActive := False;
  end;
end;

function enterRawMode: Boolean;
var raw: Termios;
begin
  Result := False;
  if not LineEditIsTTY then Exit;
  if not termiosInitDone then begin
    if TCGetAttr(0, origTermios) <> 0 then Exit;
    termiosInitDone := True;
    AddExitProc(@restoreTerminal);
  end;
  raw := origTermios;
  { ICANON: line buffering; ECHO: input echo; ISIG: Ctrl-C/Z signals.
    Drop them so we read keystrokes raw and render the line ourselves.
    Keep ISIG off so Ctrl-C lands here as #3 and we can cancel the
    current input without terminating the shell. }
  raw.c_lflag := raw.c_lflag and not Cardinal(ICANON or ECHO or ISIG or IEXTEN);
  raw.c_iflag := raw.c_iflag and not Cardinal(IXON or ICRNL or BRKINT or INPCK or ISTRIP);
  raw.c_cc[VMIN]  := 1;
  raw.c_cc[VTIME] := 0;
  if TCSetAttr(0, TCSAFLUSH, raw) <> 0 then Exit;
  rawModeActive := True;
  Result := True;
end;

{ ---- history ---- }

procedure LineEditAddHistory(const line: AnsiString);
var i: Integer;
begin
  if line = '' then Exit;
  if (historyCount > 0) and (history[historyCount-1] = line) then Exit;
  if historyCount >= HistoryMaxEntries then begin
    for i := 0 to historyCount-2 do history[i] := history[i+1];
    Dec(historyCount);
  end;
  if Length(history) <= historyCount then SetLength(history, historyCount + 32);
  history[historyCount] := line;
  Inc(historyCount);
end;

function LineEditLoadHistory(const path: AnsiString): Boolean;
var
  f:    TextFile;
  line: AnsiString;
  ioErr: Integer;
begin
  Result := False;
  if path = '' then Exit;
  AssignFile(f, string(path));
  {$I-} Reset(f); {$I+}
  ioErr := IOResult;
  if ioErr <> 0 then Exit;
  Result := True;
  try
    while not EOF(f) do begin
      ReadLn(f, line);
      if line <> '' then LineEditAddHistory(line);
    end;
  finally
    CloseFile(f);
  end;
end;

function LineEditSaveHistory(const path: AnsiString): Boolean;
var
  f:     TextFile;
  i:     Integer;
  ioErr: Integer;
begin
  Result := False;
  if path = '' then Exit;
  AssignFile(f, string(path));
  {$I-} Rewrite(f); {$I+}
  ioErr := IOResult;
  if ioErr <> 0 then Exit;
  try
    for i := 0 to historyCount - 1 do
      WriteLn(f, history[i]);
    Result := True;
  finally
    CloseFile(f);
  end;
end;

procedure LineEditStifleHistory(n: Integer);
var i, drop: Integer;
begin
  if n < 0 then n := 0;
  if historyCount <= n then Exit;
  drop := historyCount - n;
  for i := 0 to n - 1 do
    history[i] := history[i + drop];
  for i := n to historyCount - 1 do
    history[i] := '';
  historyCount := n;
end;

{ ---- render ---- }

type
  TEditState = record
    prompt:   AnsiString;
    buf:      AnsiString;   { current line }
    pos:      Integer;      { cursor index, 0..Length(buf) }
    histIdx:  Integer;      { -1 = editing fresh line; else history index being viewed }
    savedBuf: AnsiString;   { the in-progress line saved when user pressed Up }
  end;

procedure refreshLine(const st: TEditState);
var s: AnsiString; back: Integer;
begin
  { CR, write prompt + buffer, erase to EOL, then move cursor left by
    (visible chars after cursor) so cursor lands at st.pos. }
  s := #13 + st.prompt + st.buf + #27'[K';
  back := Length(st.buf) - st.pos;
  if back > 0 then s := s + #27'[' + IntToStr(back) + 'D';
  writeStr(s);
end;

{ ---- editor ops ---- }

procedure opInsert(var st: TEditState; ch: AnsiChar);
begin
  if st.pos = Length(st.buf) then begin
    st.buf := st.buf + ch;
    Inc(st.pos);
    { Fast path: just echo the char, no full refresh. }
    writeByte(Byte(ch));
  end else begin
    Insert(ch, st.buf, st.pos + 1);
    Inc(st.pos);
    refreshLine(st);
  end;
end;

procedure opBackspace(var st: TEditState);
begin
  if st.pos = 0 then Exit;
  Delete(st.buf, st.pos, 1);
  Dec(st.pos);
  refreshLine(st);
end;

procedure opDelete(var st: TEditState);
begin
  if st.pos >= Length(st.buf) then Exit;
  Delete(st.buf, st.pos + 1, 1);
  refreshLine(st);
end;

procedure opMoveLeft(var st: TEditState);
begin
  if st.pos > 0 then begin
    Dec(st.pos);
    writeStr(#27'[D');
  end;
end;

procedure opMoveRight(var st: TEditState);
begin
  if st.pos < Length(st.buf) then begin
    Inc(st.pos);
    writeStr(#27'[C');
  end;
end;

procedure opHome(var st: TEditState);
begin
  if st.pos > 0 then begin
    st.pos := 0;
    refreshLine(st);
  end;
end;

procedure opEnd(var st: TEditState);
begin
  if st.pos < Length(st.buf) then begin
    st.pos := Length(st.buf);
    refreshLine(st);
  end;
end;

procedure opKillToEnd(var st: TEditState);
begin
  if st.pos < Length(st.buf) then begin
    SetLength(st.buf, st.pos);
    refreshLine(st);
  end;
end;

procedure opKillToStart(var st: TEditState);
begin
  if st.pos > 0 then begin
    Delete(st.buf, 1, st.pos);
    st.pos := 0;
    refreshLine(st);
  end;
end;

procedure opKillWord(var st: TEditState);
var i: Integer;
begin
  if st.pos = 0 then Exit;
  i := st.pos;
  while (i > 0) and (st.buf[i] = ' ') do Dec(i);
  while (i > 0) and (st.buf[i] <> ' ') do Dec(i);
  Delete(st.buf, i + 1, st.pos - i);
  st.pos := i;
  refreshLine(st);
end;

procedure opClearScreen(var st: TEditState);
begin
  writeStr(#27'[H'#27'[2J');
  refreshLine(st);
end;

procedure opHistoryPrev(var st: TEditState);
begin
  if historyCount = 0 then Exit;
  if st.histIdx = -1 then begin
    st.savedBuf := st.buf;
    st.histIdx := historyCount - 1;
  end else if st.histIdx > 0 then
    Dec(st.histIdx)
  else
    Exit;
  st.buf := history[st.histIdx];
  st.pos := Length(st.buf);
  refreshLine(st);
end;

procedure opHistoryNext(var st: TEditState);
begin
  if st.histIdx = -1 then Exit;
  if st.histIdx < historyCount - 1 then begin
    Inc(st.histIdx);
    st.buf := history[st.histIdx];
  end else begin
    st.histIdx := -1;
    st.buf := st.savedBuf;
    st.savedBuf := '';
  end;
  st.pos := Length(st.buf);
  refreshLine(st);
end;

{ ---- main loop ---- }

function editLine(const prompt: AnsiString; out atEof: Boolean): AnsiString;
var
  st: TEditState;
  b, b2, b3: Byte;
  done: Boolean;
begin
  atEof := False;
  Result := '';
  st.prompt   := prompt;
  st.buf      := '';
  st.pos      := 0;
  st.histIdx  := -1;
  st.savedBuf := '';

  writeStr(prompt);

  done := False;
  while not done do begin
    if not readByte(b) then begin
      atEof := True;
      writeStr(#10);
      Exit;
    end;
    case b of
      13, 10: begin    { Enter }
        writeStr(#10);
        Result := st.buf;
        done := True;
      end;
      3: begin         { Ctrl-C — cancel line }
        writeStr('^C'#10);
        Result := '';
        done := True;
      end;
      4: begin         { Ctrl-D — EOF only if buffer empty, else delete-fwd }
        if Length(st.buf) = 0 then begin
          atEof := True;
          writeStr(#10);
          done := True;
        end else
          opDelete(st);
      end;
      127, 8: opBackspace(st);
      1:   opHome(st);            { Ctrl-A }
      5:   opEnd(st);             { Ctrl-E }
      2:   opMoveLeft(st);        { Ctrl-B }
      6:   opMoveRight(st);       { Ctrl-F }
      11:  opKillToEnd(st);       { Ctrl-K }
      21:  opKillToStart(st);     { Ctrl-U }
      23:  opKillWord(st);        { Ctrl-W }
      12:  opClearScreen(st);     { Ctrl-L }
      14:  opHistoryNext(st);     { Ctrl-N }
      16:  opHistoryPrev(st);     { Ctrl-P }
      9: begin                    { Tab — insert as plain space-equivalent }
        opInsert(st, #9);
      end;
      27: begin       { ESC — parse CSI / SS3 escape sequence }
        if not readByte(b2) then begin Result := ''; done := True; Continue; end;
        if (b2 = Ord('[')) or (b2 = Ord('O')) then begin
          if not readByte(b3) then begin Result := ''; done := True; Continue; end;
          case Chr(b3) of
            'A': opHistoryPrev(st);   { Up }
            'B': opHistoryNext(st);   { Down }
            'C': opMoveRight(st);     { Right }
            'D': opMoveLeft(st);      { Left }
            'H': opHome(st);          { Home }
            'F': opEnd(st);           { End }
            '3': begin
              { ESC [ 3 ~  →  Delete }
              if readByte(b3) and (b3 = Ord('~')) then opDelete(st);
            end;
            '1', '4', '7', '8': begin
              { Home/End variants ending in '~' — eat the tilde and act. }
              if readByte(b3) and (b3 = Ord('~')) then begin
                if (Chr(b3) = '~') then begin end;
              end;
            end;
          end;
        end;
      end;
    else
      if (b >= 32) and (b < 127) then opInsert(st, AnsiChar(b))
      else if b >= 128 then opInsert(st, AnsiChar(b));   { pass UTF-8 bytes through }
    end;
  end;
end;

function LineEditReadLine(const prompt: AnsiString;
                          out atEof: Boolean): AnsiString;
var line: AnsiString;
begin
  atEof := False;
  if not LineEditIsTTY then begin
    Write(prompt);
    Flush(Output);
    if EOF(Input) then begin
      atEof := True;
      Result := '';
      Exit;
    end;
    ReadLn(Input, line);
    Result := line;
    Exit;
  end;
  if not enterRawMode then begin
    Write(prompt);
    Flush(Output);
    ReadLn(Input, line);
    Result := line;
    Exit;
  end;
  try
    Result := editLine(prompt, atEof);
  finally
    restoreTerminal;
  end;
end;

end.
