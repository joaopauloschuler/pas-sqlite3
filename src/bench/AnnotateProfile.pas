program AnnotateProfile;
{
  Phase 11.9 — profiling hand-off helper.

  Reads either:
    bench/perf_report.txt        (text output of `perf report --stdio`)
    bench/callgrind.out          (machine-readable callgrind format)
  auto-detected via the first few lines.  Extracts the top-N hottest
  symbols (default N=20), best-effort maps each to a Pascal source
  file:line by greping src/passqlite3*.pas for the demangled function
  name, and emits bench/profile_top.md — a markdown table:

    | rank | function | percent | file | line |

  Best-effort means: if the symbol cannot be located the file / line
  columns read "(unknown)" rather than guessing.

  Invocation:
    bin/AnnotateProfile <input> [-n N] [-o output.md] [--src DIR]

  Defaults: -n 20, -o bench/profile_top.md, --src src/

  FPC traps honoured:
    - no `case`-insensitive var/type/const clashes
    - AnsiStrings used throughout; no `New()` on records with
      managed fields (we use plain dynamic arrays of records).
}

{$mode objfpc}{$H+}

uses
  SysUtils, Classes;

type
  THotEntry = record
    Sym:     AnsiString;   // raw symbol as reported
    BaseFn:  AnsiString;   // best-effort demangled function name (lower)
    Pct:     Double;       // percent of samples / events
    SrcFile: AnsiString;
    SrcLine: Integer;      // 0 = unknown
  end;
  THotArray = array of THotEntry;

{ ----------------------------------------------------------------- utils }

function LowerStr(const s: AnsiString): AnsiString;
begin Result := LowerCase(s); end;

function TrimAll(const s: AnsiString): AnsiString;
begin Result := Trim(s); end;

{ Best-effort demangle: FPC encodes unit & params into the symbol.
  Common shapes seen via DWARF + perf:
    P$PROGNAME_$$_FOO
    UNITNAME_$$_FOO$LONGINT$$BOOLEAN
    UNITNAME_FOO
    SQLITE3VDBEEXEC                (plain, for global fns)
  We pull the run between '$$_' (or '_$$_') and the next '$' or end.
  Falls back to the leading [A-Za-z0-9_]+ component before any '$'. }
function ExtractBaseFn(const Sym: AnsiString): AnsiString;
var
  s: AnsiString;
  i, j: Integer;
begin
  s := Sym;
  // strip everything before last "$$_"
  i := Pos('$$_', s);
  while i > 0 do begin
    Delete(s, 1, i + 2);
    i := Pos('$$_', s);
  end;
  // also handle "_$$_" -> we already stripped via "$$_" search above
  // truncate at first '$' (parameter mangling) or end
  j := Pos('$', s);
  if j > 0 then SetLength(s, j - 1);
  // strip a leading "UNIT_" prefix if it precedes the real function name.
  // We do this only when the candidate contains an underscore and the
  // leading token is a known unit-name prefix ("PASSQLITE3..." or
  // "P$PASSPEEDTEST1").  Otherwise leave intact.
  if (Pos('PASSQLITE3', s) = 1) then begin
    j := Pos('_', s);
    if j > 0 then Delete(s, 1, j);
  end;
  Result := LowerStr(s);
end;

{ ----------------------------------------------------------------- detect }

type
  TInputKind = (ikUnknown, ikPerf, ikCallgrind);

function DetectKind(const Path: AnsiString): TInputKind;
var
  F: TextFile;
  Line: AnsiString;
  N: Integer;
begin
  Result := ikUnknown;
  AssignFile(F, Path);
  Reset(F);
  try
    N := 0;
    while not Eof(F) and (N < 20) do begin
      ReadLn(F, Line);
      Inc(N);
      if (Pos('# Samples:', Line) > 0) or (Pos('# Event count', Line) > 0) or
         (Pos('# Overhead', Line) > 0) then begin
        Result := ikPerf; exit;
      end;
      if (Pos('creator:', Line) = 1) or (Pos('events:', Line) = 1) or
         (Pos('positions:', Line) = 1) then begin
        Result := ikCallgrind; exit;
      end;
    end;
  finally
    CloseFile(F);
  end;
end;

{ ----------------------------------------------------------------- perf }

{ Parse `perf report --stdio` lines like:
    12.34%  passpeedtest1  passpeedtest1  [.] SQLITE3VDBEEXEC$...
  Columns are whitespace-separated; the symbol is the trailing
  token-run after the "[.]" or "[k]" marker. }
procedure ParsePerf(const Path: AnsiString; var Entries: THotArray);
var
  F: TextFile;
  Line, Sym, PctStr: AnsiString;
  p, q: Integer;
  Pct: Double;
  E: THotEntry;
begin
  SetLength(Entries, 0);
  AssignFile(F, Path); Reset(F);
  try
    while not Eof(F) do begin
      ReadLn(F, Line);
      Line := TrimAll(Line);
      if (Line = '') or (Line[1] = '#') then continue;
      // First token must end with '%'
      p := Pos('%', Line);
      if p < 2 then continue;
      PctStr := TrimAll(Copy(Line, 1, p - 1));
      // PctStr must look like a number
      if (PctStr = '') then continue;
      if not (PctStr[1] in ['0'..'9', '.', '-', '+']) then continue;
      // Locate "[.]" / "[k]" / "[H]" tag; symbol follows it
      q := Pos('[.]', Line);
      if q = 0 then q := Pos('[k]', Line);
      if q = 0 then q := Pos('[H]', Line);
      if q = 0 then continue;
      Sym := TrimAll(Copy(Line, q + 3, MaxInt));
      if Sym = '' then continue;
      // strip trailing whitespace / inline annotation
      q := Pos(' ', Sym);
      if q > 0 then Sym := Copy(Sym, 1, q - 1);
      Val(StringReplace(PctStr, ',', '.', [rfReplaceAll]), Pct, q);
      if q <> 0 then continue;
      E.Sym := Sym;
      E.BaseFn := ExtractBaseFn(Sym);
      E.Pct := Pct;
      E.SrcFile := '';
      E.SrcLine := 0;
      SetLength(Entries, Length(Entries) + 1);
      Entries[High(Entries)] := E;
    end;
  finally
    CloseFile(F);
  end;
end;

{ ----------------------------------------------------------------- callgrind }

{ Callgrind text format: aggregate self-cost per `fn=` line.
  Lines `<lineno> <ir> [...]` after an `fn=` accumulate to that fn.
  Inclusive cost is harder; we use *self* cost here which matches what
  `callgrind_annotate` calls "self". }
procedure ParseCallgrind(const Path: AnsiString; var Entries: THotArray);
var
  F: TextFile;
  Line, CurFn, NameKey, NameVal: AnsiString;
  TotalIr: Int64;
  Idx, j: Integer;
  Costs: array of Int64;   // parallel to Entries
  Tokens: array of AnsiString;
  s: AnsiString;
  n, p: Integer;
  ir: Int64;
  err: Integer;
  i: Integer;
  NameMap: TStringList;    // key="(NNN)" → value=resolved name

  function FindOrAdd(const Fn: AnsiString): Integer;
  var k: Integer; E: THotEntry;
  begin
    for k := 0 to High(Entries) do
      if Entries[k].Sym = Fn then begin Result := k; exit; end;
    E.Sym := Fn;
    E.BaseFn := ExtractBaseFn(Fn);
    E.Pct := 0.0;
    E.SrcFile := ''; E.SrcLine := 0;
    SetLength(Entries, Length(Entries) + 1);
    Entries[High(Entries)] := E;
    SetLength(Costs, Length(Entries));
    Costs[High(Costs)] := 0;
    Result := High(Entries);
  end;

begin
  SetLength(Entries, 0);
  SetLength(Costs, 0);
  TotalIr := 0;
  CurFn := '';
  Idx := -1;
  NameMap := TStringList.Create;
  NameMap.Sorted := True;
  NameMap.Duplicates := dupIgnore;
  AssignFile(F, Path); Reset(F);
  try
    while not Eof(F) do begin
      ReadLn(F, Line);
      if Line = '' then continue;
      if (Length(Line) >= 3) and (Copy(Line, 1, 3) = 'fn=') then begin
        CurFn := Copy(Line, 4, MaxInt);
        // Callgrind name compression: "(NNN) NAME" defines, "(NNN)"
        // alone references.  Build/lookup an alias map so we
        // accumulate cost under the canonical name.
        if (Length(CurFn) > 0) and (CurFn[1] = '(') then begin
          p := Pos(')', CurFn);
          if p > 0 then begin
            NameKey := Copy(CurFn, 1, p);                  // "(NNN)"
            NameVal := TrimAll(Copy(CurFn, p + 1, MaxInt));// "NAME" or ''
            if NameVal <> '' then begin
              NameMap.Values[NameKey] := NameVal;
              CurFn := NameVal;
            end else begin
              CurFn := NameMap.Values[NameKey];
              if CurFn = '' then CurFn := NameKey;
            end;
          end;
        end;
        Idx := FindOrAdd(CurFn);
        continue;
      end;
      if Line[1] = '#' then continue;
      // `cfn=(NNN) NAME` (call-target) also defines an alias; harvest
      // it before we drop the line below.
      if (Length(Line) >= 4) and (Copy(Line, 1, 4) = 'cfn=') then begin
        s := Copy(Line, 5, MaxInt);
        if (Length(s) > 0) and (s[1] = '(') then begin
          p := Pos(')', s);
          if p > 0 then begin
            NameKey := Copy(s, 1, p);
            NameVal := TrimAll(Copy(s, p + 1, MaxInt));
            if NameVal <> '' then NameMap.Values[NameKey] := NameVal;
          end;
        end;
        continue;
      end;
      if Pos('=', Line) > 0 then continue;  // events:/positions:/etc
      if Line[1] = 'c' then continue;       // calls=, cob=, etc
      if Line[1] = 'o' then continue;       // ob=
      if Line[1] = 'f' then continue;       // fi=, fe=, fl=
      // Numeric cost line: "<lineno> <ir> [...]"
      if not (Line[1] in ['0'..'9', '*', '+']) then continue;
      // tokenise on whitespace
      SetLength(Tokens, 0);
      n := 1;
      while n <= Length(Line) do begin
        while (n <= Length(Line)) and (Line[n] = ' ') do Inc(n);
        if n > Length(Line) then break;
        j := n;
        while (n <= Length(Line)) and (Line[n] <> ' ') do Inc(n);
        SetLength(Tokens, Length(Tokens) + 1);
        Tokens[High(Tokens)] := Copy(Line, j, n - j);
      end;
      if Length(Tokens) < 2 then continue;
      // events: Ir → second token is the count
      s := Tokens[1];
      Val(s, ir, err);
      if err <> 0 then continue;
      if Idx >= 0 then begin
        Costs[Idx] := Costs[Idx] + ir;
        TotalIr := TotalIr + ir;
      end;
    end;
  finally
    CloseFile(F);
  end;
  // Second pass: merge anonymous "(NNN)" entries into their named
  // counterpart (alias was defined later in the file).  Anonymous
  // leftovers remain as-is (truly unresolved).
  try
    for i := 0 to High(Entries) do begin
      s := Entries[i].Sym;
      if (Length(s) > 0) and (s[1] = '(') and (Pos(')', s) = Length(s)) then begin
        NameVal := NameMap.Values[s];
        if NameVal <> '' then begin
          // find the canonical entry and accumulate
          for j := 0 to High(Entries) do
            if (j <> i) and (Entries[j].Sym = NameVal) then begin
              Costs[j] := Costs[j] + Costs[i];
              Costs[i] := 0;
              Entries[i].Sym := '__merged__';
              break;
            end;
        end;
      end;
    end;
  finally
    NameMap.Free;
  end;
  if TotalIr <= 0 then exit;
  for i := 0 to High(Entries) do
    Entries[i].Pct := (Costs[i] * 100.0) / TotalIr;
end;

{ ----------------------------------------------------------------- sort }

procedure SortByPctDesc(var A: THotArray);
var i, j: Integer; tmp: THotEntry;
begin
  // Simple insertion sort; N is small (hundreds at most).
  for i := 1 to High(A) do begin
    tmp := A[i];
    j := i - 1;
    while (j >= 0) and (A[j].Pct < tmp.Pct) do begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := tmp;
  end;
end;

{ ----------------------------------------------------------------- lookup }

{ Best-effort src lookup: scan every src/passqlite3*.pas, look for
    ^\s*(procedure|function)\s+<basefn>\b
  Case-insensitive.  Returns first hit. }
procedure LookupSource(const SrcDir: AnsiString; var E: THotEntry);
var
  Files: TStringList;
  SR: TSearchRec;
  Path: AnsiString;
  F: TextFile;
  Line, L: AnsiString;
  LineNo, p: Integer;
  k: Integer;
  Needle: AnsiString;
begin
  if E.BaseFn = '' then exit;
  Needle := E.BaseFn;
  Files := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(SrcDir) + 'passqlite3*.pas',
                 faAnyFile, SR) = 0 then
    begin
      repeat
        Files.Add(IncludeTrailingPathDelimiter(SrcDir) + SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    for k := 0 to Files.Count - 1 do begin
      Path := Files[k];
      AssignFile(F, Path);
      {$I-} Reset(F); {$I+}
      if IOResult <> 0 then continue;
      LineNo := 0;
      try
        while not Eof(F) do begin
          ReadLn(F, Line);
          Inc(LineNo);
          L := LowerStr(TrimAll(Line));
          if (Pos('procedure ', L) = 1) or (Pos('function ', L) = 1) then begin
            // skip the keyword
            if Pos('procedure ', L) = 1 then p := Length('procedure ') + 1
            else p := Length('function ') + 1;
            // extract identifier until '(' ':' ' ' ';'
            L := Copy(L, p, MaxInt);
            p := 1;
            while (p <= Length(L)) and
                  (L[p] in ['a'..'z', '0'..'9', '_']) do Inc(p);
            L := Copy(L, 1, p - 1);
            if L = Needle then begin
              E.SrcFile := ExtractFileName(Path);
              E.SrcLine := LineNo;
              exit;  // finally-block below closes F
            end;
          end;
        end;
      finally
        CloseFile(F);
      end;
    end;
  finally
    Files.Free;
  end;
end;

{ ----------------------------------------------------------------- emit }

procedure EmitMarkdown(const A: THotArray; TopN: Integer;
                       const OutPath: AnsiString;
                       const Kind: TInputKind;
                       const Input: AnsiString);
var
  F: TextFile;
  i, n: Integer;
  KindName, FileCol, LineCol: AnsiString;
begin
  if Kind = ikPerf      then KindName := 'perf'
  else if Kind = ikCallgrind then KindName := 'callgrind'
  else                       KindName := 'unknown';
  AssignFile(F, OutPath); Rewrite(F);
  try
    WriteLn(F, '# Profile top-', TopN, ' (', KindName, ')');
    WriteLn(F);
    WriteLn(F, 'Generated by `bin/AnnotateProfile` from `', Input, '`.');
    WriteLn(F);
    WriteLn(F, '| rank | function | percent | file | line |');
    WriteLn(F, '|-----:|----------|--------:|------|-----:|');
    n := 0;
    for i := 0 to High(A) do begin
      if n >= TopN then break;
      if A[i].Sym = '__merged__' then continue;
      if A[i].Pct <= 0 then continue;
      Inc(n);
      if A[i].SrcFile = '' then FileCol := '(unknown)' else FileCol := A[i].SrcFile;
      if A[i].SrcLine = 0  then LineCol := '(unknown)' else LineCol := IntToStr(A[i].SrcLine);
      WriteLn(F, '| ', n, ' | `', A[i].Sym, '` | ',
              FormatFloat('0.00', A[i].Pct), ' | ', FileCol, ' | ', LineCol, ' |');
    end;
  finally
    CloseFile(F);
  end;
end;

{ ----------------------------------------------------------------- main }

procedure Usage;
begin
  WriteLn('Usage: AnnotateProfile <input> [-n N] [-o output.md] [--src DIR]');
  WriteLn('  <input>    bench/perf_report.txt OR bench/callgrind.out');
  WriteLn('  -n N       top-N entries to emit (default 20)');
  WriteLn('  -o PATH    output markdown file (default bench/profile_top.md)');
  WriteLn('  --src DIR  pascal source dir to grep (default src/)');
end;

var
  Input, OutPath, SrcDir: AnsiString;
  TopN, i, err: Integer;
  Kind: TInputKind;
  Entries: THotArray;
begin
  if ParamCount < 1 then begin Usage; Halt(2); end;
  Input := ParamStr(1);
  TopN := 20;
  OutPath := 'bench/profile_top.md';
  SrcDir := 'src';
  i := 2;
  while i <= ParamCount do begin
    if ParamStr(i) = '-n' then begin
      Inc(i); Val(ParamStr(i), TopN, err);
      if err <> 0 then begin WriteLn('bad -n value'); Halt(2); end;
    end else if ParamStr(i) = '-o' then begin
      Inc(i); OutPath := ParamStr(i);
    end else if ParamStr(i) = '--src' then begin
      Inc(i); SrcDir := ParamStr(i);
    end else if (ParamStr(i) = '-h') or (ParamStr(i) = '--help') then begin
      Usage; Halt(0);
    end else begin
      WriteLn('unknown arg: ', ParamStr(i)); Usage; Halt(2);
    end;
    Inc(i);
  end;

  if not FileExists(Input) then begin
    WriteLn('ERROR: input not found: ', Input); Halt(1);
  end;

  Kind := DetectKind(Input);
  case Kind of
    ikPerf:      begin WriteLn('Detected perf report.'); ParsePerf(Input, Entries); end;
    ikCallgrind: begin WriteLn('Detected callgrind.out.'); ParseCallgrind(Input, Entries); end;
    else begin
      WriteLn('ERROR: cannot auto-detect format of ', Input);
      WriteLn('       expected `# Overhead`/`# Samples` (perf) or ');
      WriteLn('       `events:`/`creator:` (callgrind) in first 20 lines.');
      Halt(1);
    end;
  end;

  if Length(Entries) = 0 then begin
    WriteLn('WARN: no entries parsed from ', Input);
  end;

  SortByPctDesc(Entries);

  // Annotate a generous window — emit-loop filters merged/zero entries,
  // so widen the slice we look up to keep the markdown TopN populated.
  for i := 0 to Length(Entries) - 1 do begin
    if i >= TopN * 4 then break;
    if Entries[i].Sym = '__merged__' then continue;
    if Entries[i].Pct <= 0 then continue;
    LookupSource(SrcDir, Entries[i]);
  end;

  EmitMarkdown(Entries, TopN, OutPath, Kind, Input);
  WriteLn('Wrote ', OutPath, ' (', Length(Entries),
          ' parsed, top ', TopN, ' annotated).');
end.
