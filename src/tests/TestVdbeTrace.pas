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
{$I ../passqlite3.inc}
program TestVdbeTrace;
{
  Phase 7.4c — differential opcode-trace gate.

  For each SQL statement in a small corpus, drive both:
    * the Pascal port via sqlite3_prepare_v2 / sqlite3_step with
      db^.flags |= SQLITE_VdbeTrace.  The capture sink lives in
      passqlite3vdbe (gVdbeTraceBuf): one normalised line per
      executed opcode '<pc> <opname> <p1> <p2> <p3> <p5>'#10.
    * the C reference via csq_prepare_v2 / csq_step with PRAGMA
      vdbe_trace=ON.  C writes the trace to stdout via the
      sqlite3VdbePrintOp helper (vdbeaux.c:2111) gated on
      SQLITE_VdbeTrace at vdbe.c:954.  We freopen() libc stdout to
      a temp file and parse the relevant trace lines back out.

  The C trace lines have the printf format:
    "%4d %-13s %4d %4d %4d %-13s %.2X %s\n"
    (pc, opname, p1, p2, p3, zP4, p5, comment)
  Plus extra noise lines that we skip:
    "VDBE Trace:" header at pc=0
    "SQL: [...]" prefix
    "R[<n>] = ..." registerTrace lines
  We compare opcode + p1/p2/p3/p5 sequence (skipping the variable
  P4 column and the comment column) — that is the meaningful
  "execution-order" signal.

  Gate: every corpus row matches the C reference exactly.
}

uses
  SysUtils,
  ctypes,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main,
  csqlite3;

{ ===== libc bindings (stdout redirection) ================================== }

type
  PCFile = Pointer;

function libc_freopen(path, mode: PAnsiChar; stream: PCFile): PCFile;
  cdecl; external 'c' name 'freopen';
function libc_fdopen(fd: cint; mode: PAnsiChar): PCFile;
  cdecl; external 'c' name 'fdopen';
function libc_fileno(stream: PCFile): cint;
  cdecl; external 'c' name 'fileno';
function libc_dup(fd: cint): cint;
  cdecl; external 'c' name 'dup';
function libc_dup2(oldfd, newfd: cint): cint;
  cdecl; external 'c' name 'dup2';
procedure libc_fflush_all; cdecl; external 'c' name 'fflush'; { fflush(NULL) }
function libc_fflush(stream: PCFile): cint;
  cdecl; external 'c' name 'fflush';

{ We do not need a handle on the C 'stdout' global directly.  Redirection
  is done at fd-1 level via libc dup/dup2/open: any fprintf(stdout,...) in
  libsqlite3.so writes through fd 1, so a dup2 over fd 1 captures it. }

const
  O_WRONLY = 1;
  O_CREAT  = $0040;
  O_TRUNC  = $0200;
  S_IRUSR  = $0100;
  S_IWUSR  = $0080;

function libc_open(path: PAnsiChar; flags, mode: cint): cint;
  cdecl; external 'c' name 'open';
function libc_close(fd: cint): cint;
  cdecl; external 'c' name 'close';

{ ===== helpers ============================================================== }

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(const name: string; cond: Boolean);
begin
  if cond then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ ===== capture C stdout to file =========================================== }

var
  gSavedFd: cint = -1;

procedure RedirectCStdout(const path: string);
var
  fd: cint;
begin
  Flush(Output);
  libc_fflush(nil);  { flush all libc streams }
  if gSavedFd < 0 then
    gSavedFd := libc_dup(1);
  fd := libc_open(PAnsiChar(path), O_WRONLY or O_CREAT or O_TRUNC,
                  S_IRUSR or S_IWUSR);
  if fd < 0 then Exit;
  libc_dup2(fd, 1);
  libc_close(fd);
end;

procedure RestoreCStdout;
begin
  libc_fflush(nil);
  if gSavedFd >= 0 then begin
    libc_dup2(gSavedFd, 1);
    libc_close(gSavedFd);
    gSavedFd := -1;
  end;
end;

function ReadFileText(const path: string): AnsiString;
var
  fs: TextFile;
  s, all: AnsiString;
begin
  all := '';
  AssignFile(fs, path);
  {$I-}Reset(fs);{$I+}
  if IOResult <> 0 then begin Result := ''; Exit; end;
  while not Eof(fs) do begin
    ReadLn(fs, s);
    all := all + s + #10;
  end;
  CloseFile(fs);
  Result := all;
end;

{ ===== line tokenisation ==================================================== }

{ Split s on whitespace runs.  Returns AnsiString tokens via callback-style. }

function NextToken(const s: AnsiString; var i: i32): AnsiString;
var
  n: i32;
  st: i32;
begin
  n := Length(s);
  while (i <= n) and ((s[i] = ' ') or (s[i] = #9)) do Inc(i);
  st := i;
  while (i <= n) and (s[i] <> ' ') and (s[i] <> #9) do Inc(i);
  Result := Copy(s, st, i - st);
end;

function IsAllDigits(const t: AnsiString): Boolean;
var i: i32;
begin
  if Length(t) = 0 then Exit(False);
  for i := 1 to Length(t) do
    if (t[i] < '0') or (t[i] > '9') then Exit(False);
  Result := True;
end;

function IsHex2(const t: AnsiString): Boolean;
var i: i32; c: AnsiChar;
begin
  if Length(t) <> 2 then Exit(False);
  for i := 1 to 2 do begin
    c := t[i];
    if not (((c >= '0') and (c <= '9'))
         or ((c >= 'A') and (c <= 'F'))
         or ((c >= 'a') and (c <= 'f'))) then Exit(False);
  end;
  Result := True;
end;

function IsSignedInt(const t: AnsiString): Boolean;
var s: AnsiString;
begin
  s := t;
  if (Length(s) > 0) and ((s[1] = '-') or (s[1] = '+')) then s := Copy(s, 2, MaxInt);
  Result := IsAllDigits(s);
end;

{ Parse a single C-side trace line.  Returns True if the line is a real
  opcode-trace line; sets out tokens.  Format pattern reminder:

     "   3 Explain          3    0  216 SCAN main.sqlite_master 00 \n"
     "   0 Init             0    4    0               00 Start at 4\n"

  Strategy: pull tokens 0..4 (pc, opname, p1, p2, p3); then advance through
  zero-or-more zP4 tokens until we hit a 2-uppercase-hex token whose
  *position* terminates p4 (heuristic: it's followed by either end-of-line,
  a comment, or further tokens but is the FIRST 2-hex token after p3).
  This works because p4's content does not start with a 2-hex glyph plus
  trailing space when zP4 is empty (zP4="" → format prints the field as
  spaces, so the next token IS the 2-hex p5). }

function ParseCTraceLine(const line: AnsiString;
                         out pc, p1, p2, p3, p5: i32;
                         out opname: AnsiString): Boolean;
var
  i: i32;
  t: AnsiString;
begin
  Result := False;
  i := 1;
  t := NextToken(line, i);
  if not IsAllDigits(t) then Exit;
  pc := StrToIntDef(t, -1);

  opname := NextToken(line, i);
  if Length(opname) = 0 then Exit;

  t := NextToken(line, i);
  if not IsSignedInt(t) then Exit;
  p1 := StrToIntDef(t, 0);

  t := NextToken(line, i);
  if not IsSignedInt(t) then Exit;
  p2 := StrToIntDef(t, 0);

  t := NextToken(line, i);
  if not IsSignedInt(t) then Exit;
  p3 := StrToIntDef(t, 0);

  { Now consume tokens until we find the 2-hex p5.  zP4 may be empty (in
    which case the next token IS p5) or may span multiple words. }
  while True do begin
    t := NextToken(line, i);
    if Length(t) = 0 then Exit;  { malformed, no p5 }
    if IsHex2(t) then begin
      p5 := StrToIntDef('$' + t, 0);
      Exit(True);
    end;
  end;
end;

type
  TTraceRow = record
    pc, p1, p2, p3, p5: i32;
    opname: AnsiString;
  end;
  TTraceArr = array of TTraceRow;

function ParseCTraceText(const txt: AnsiString): TTraceArr;
var
  rows: TTraceArr;
  start, i, n: i32;
  line: AnsiString;
  row: TTraceRow;
begin
  SetLength(rows, 0);
  n := Length(txt);
  i := 1;
  start := 1;
  while i <= n + 1 do begin
    if (i > n) or (txt[i] = #10) then begin
      line := Copy(txt, start, i - start);
      if (Length(line) > 0) and (line[Length(line)] = #13) then
        SetLength(line, Length(line) - 1);
      { 'VDBE Trace:' header marks the start of a fresh statement's
        per-opcode trace.  We only want the LAST section (the user
        statement); discard rows accumulated for any earlier section
        such as the PRAGMA vdbe_trace=ON statement itself. }
      if Pos('VDBE Trace:', line) = 1 then
        SetLength(rows, 0)
      else if ParseCTraceLine(line, row.pc, row.p1, row.p2, row.p3, row.p5,
                              row.opname) then begin
        SetLength(rows, Length(rows) + 1);
        rows[High(rows)] := row;
      end;
      start := i + 1;
    end;
    Inc(i);
  end;
  Result := rows;
end;

function ParsePasTraceText(const txt: AnsiString): TTraceArr;
var
  rows: TTraceArr;
  start, i, n, k: i32;
  line, t: AnsiString;
  row: TTraceRow;
begin
  SetLength(rows, 0);
  n := Length(txt);
  i := 1; start := 1;
  while i <= n + 1 do begin
    if (i > n) or (txt[i] = #10) then begin
      line := Copy(txt, start, i - start);
      k := 1;
      t := NextToken(line, k);
      if IsAllDigits(t) then begin
        row.pc := StrToIntDef(t, 0);
        row.opname := NextToken(line, k);
        row.p1 := StrToIntDef(NextToken(line, k), 0);
        row.p2 := StrToIntDef(NextToken(line, k), 0);
        row.p3 := StrToIntDef(NextToken(line, k), 0);
        t := NextToken(line, k);
        row.p5 := StrToIntDef('$' + t, 0);
        SetLength(rows, Length(rows) + 1);
        rows[High(rows)] := row;
      end;
      start := i + 1;
    end;
    Inc(i);
  end;
  Result := rows;
end;

{ ===== drivers ============================================================== }

function PasRunTrace(const sql: AnsiString): TTraceArr;
var
  db: PTsqlite3;
  st: PVdbe;
  pTail: PAnsiChar;
  rcs: i32;
begin
  db := nil;
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then begin
    Result := nil; Exit;
  end;
  st := nil; pTail := nil;
  if sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @st, @pTail) <> SQLITE_OK then
  begin
    sqlite3_close(db); Result := nil; Exit;
  end;
  { Enable trace only for stepping the user statement, so the schema-load
    bytecode (run during prepare_v2) does not pollute the comparison. }
  gVdbeTraceBuf := '';
  db^.flags := db^.flags or SQLITE_VdbeTrace;
  if st <> nil then begin
    repeat rcs := sqlite3_step(st) until rcs <> SQLITE_ROW;
    sqlite3_finalize(st);
  end;
  db^.flags := db^.flags and (not SQLITE_VdbeTrace);
  sqlite3_close(db);
  Result := ParsePasTraceText(gVdbeTraceBuf);
end;

function CRunTrace(const sql: AnsiString; const tmpPath: string): TTraceArr;
var
  db: Pcsq_db;
  st: Pcsq_stmt;
  rcs: Int32;
  txt: AnsiString;
  errMsg: PChar;
  zTail: PChar;
begin
  db := nil;
  if csq_open(':memory:', db) <> 0 then begin Result := nil; Exit; end;

  { Prepare BEFORE enabling trace so schema-load bytecode is silent. }
  st := nil; zTail := nil;
  if csq_prepare_v2(db, PAnsiChar(sql), -1, st, zTail) <> 0 then begin
    csq_close(db); Result := nil; Exit;
  end;
  RedirectCStdout(tmpPath);
  errMsg := nil;
  { PRAGMA vdbe_trace=ON enables tracing; the PRAGMA itself emits trace
    lines (5).  Then csq_step on the user statement emits the lines we
    care about.  We strip the PRAGMA section in ParseCTraceText by
    keeping only lines after the LAST 'VDBE Trace:' marker. }
  csq_exec(db, 'PRAGMA vdbe_trace=ON;', nil, nil, errMsg);
  if st <> nil then begin
    repeat rcs := csq_step(st) until rcs <> SQLITE_ROW;
    csq_finalize(st);
  end;
  RestoreCStdout;
  csq_close(db);

  txt := ReadFileText(tmpPath);
  Result := ParseCTraceText(txt);
end;

{ ===== comparison =========================================================== }

function FormatRow(const r: TTraceRow): AnsiString;
begin
  Result := Format('%d %s %d %d %d %.2x',
                   [r.pc, r.opname, r.p1, r.p2, r.p3, r.p5]);
end;

function CompareTraces(const lbl: string;
                       const pas, c: TTraceArr): Boolean;
var
  i, n: i32;
  ok: Boolean;
begin
  WriteLn('  ', lbl, ': pascal=', Length(pas), ' lines  c=', Length(c), ' lines');
  ok := Length(pas) = Length(c);
  if not ok then begin
    WriteLn('    line-count differs — dumping side-by-side:');
    n := Length(pas); if Length(c) > n then n := Length(c);
    for i := 0 to n - 1 do begin
      Write('      [', i, '] ');
      if i < Length(pas) then Write('pas={', FormatRow(pas[i]), '}  ')
      else Write('pas=---  ');
      if i < Length(c)   then WriteLn('c={', FormatRow(c[i]), '}')
      else WriteLn('c=---');
    end;
  end else begin
    n := Length(pas);
    for i := 0 to n - 1 do begin
      if    (pas[i].pc     <> c[i].pc)
         or (pas[i].opname <> c[i].opname)
         or (pas[i].p1     <> c[i].p1)
         or (pas[i].p2     <> c[i].p2)
         or (pas[i].p3     <> c[i].p3)
         or (pas[i].p5     <> c[i].p5) then begin
        WriteLn('    diverge @ idx=', i);
        WriteLn('      pas: ', FormatRow(pas[i]));
        WriteLn('      c  : ', FormatRow(c[i]));
        ok := False;
        Break;
      end;
    end;
  end;
  Result := ok;
end;

{ ===== corpus =============================================================== }

procedure RunCase(const lbl, sql: AnsiString);
var
  pasRows, cRows: TTraceArr;
  tmpPath: string;
begin
  WriteLn(lbl, ': ', sql);
  tmpPath := '/tmp/test_vdbe_trace_c.txt';
  pasRows := PasRunTrace(sql);
  cRows   := CRunTrace(sql, tmpPath);
  Check(lbl, CompareTraces(lbl, pasRows, cRows));
end;

{ ===== main ================================================================ }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeTrace — Phase 7.4c differential opcode-trace gate ===');
  WriteLn;

  RunCase('T1 SELECT 1',          'SELECT 1');
  RunCase('T2 SELECT 1+2',        'SELECT 1+2');
  RunCase('T3 SELECT NULL',       'SELECT NULL');
  RunCase('T4 SELECT 1,2,3',      'SELECT 1,2,3');
  RunCase('T5 SELECT abs(-7)',    'SELECT abs(-7)');
  RunCase('T6 SELECT 2*3+4',      'SELECT 2*3+4');
  RunCase('T7 SELECT length(''hi'')', 'SELECT length(''hi'')');
  RunCase('T8 SELECT 5>3',        'SELECT 5>3');

  WriteLn;
  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
