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
{
  TestVectorReadOnly.pas — Phase 9.2.2 read-only parity probe.

  Walks every `*.queries.sql` under src/tests/vectors/, opens the
  matching `<name>.db` in SQLITE_OPEN_READONLY mode under both the
  C oracle (libsqlite3.so via csqlite3) AND the Pascal port
  (passqlite3main), runs the script via sqlite3_exec with a row-printing
  callback (FormatRow contract = upstream `.mode list`: pipe-separated
  columns, NULL printed empty, '\n' terminator, no header line), and
  byte-diffs the captured stdout + stderr + rc.

  No writes performed — the gate is about read-side compatibility with
  files the port did not author.  Vectors tagged `pas-skip` or `[SKIP]`
  in MANIFEST.txt are skipped (corpus skip-and-cite contract).

  First divergence prints a one-screen summary (vector, channel, first
  16-byte window) and exits non-zero.  Row-printing, exec runners, diff
  windows, and ResolveRepoRoot all come from TestVectorCommon (the same
  shared harness used by TestVectorRoundTrip / TestVectorSchemaChange).
}
program TestVectorReadOnly;

uses
  SysUtils, Classes,
  csqlite3,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3main,
  TestVectorCommon;

var
  VectorDir: AnsiString;  { resolved at startup — see ResolveRepoRoot }

{ ----------------------------------------------------------------------
  MANIFEST.txt parser — reads the status tag for each vector.  Per
  9.2.1 the status legend is:  [X]  [~]  [SKIP]  -- column 2 of the
  table.  We treat [SKIP] as skip.  Additionally, an explicit
  `pas-skip` tag added by 9.2.2 follow-up (see DIVERGENCES.md) also
  skips the vector.  All other vectors are gated.
  ---------------------------------------------------------------------- }

type
  TStatusEntry = record
    name:   AnsiString;   { e.g. 'simple.db' }
    status: AnsiString;   { 'X', '~', 'SKIP', 'pas-skip' }
  end;
  TStatusList = array of TStatusEntry;

procedure LoadManifest(out list: TStatusList);
var
  manifestPath: AnsiString;
  raw: AnsiString;
  lines: TStringList;
  i: i32;
  line: AnsiString;
  parts: TStringList;
  j: i32;
  toks: array of AnsiString;
  name, status: AnsiString;
begin
  SetLength(list, 0);
  manifestPath := IncludeTrailingPathDelimiter(VectorDir) + 'MANIFEST.txt';
  raw := ReadFileText(manifestPath);
  if raw = '' then begin
    Writeln('WARN: MANIFEST.txt not found at ', manifestPath, '; treating all vectors as gated.');
    Exit;
  end;
  lines := TStringList.Create;
  parts := TStringList.Create;
  try
    lines.Text := raw;
    for i := 0 to lines.Count - 1 do begin
      line := Trim(lines[i]);
      { skip blank lines, headers, separators }
      if (line = '') or (line[1] = '-') or (line[1] = '=') then
        Continue;
      { rough column-1 == vector name (ends in .db).  Split on whitespace. }
      parts.Clear;
      parts.Delimiter := ' ';
      parts.StrictDelimiter := False;
      parts.DelimitedText := line;
      SetLength(toks, 0);
      for j := 0 to parts.Count - 1 do
        if Trim(parts[j]) <> '' then begin
          SetLength(toks, Length(toks) + 1);
          toks[High(toks)] := Trim(parts[j]);
        end;
      if Length(toks) < 2 then Continue;
      { 9.2.x override block: lines like `pas-skip simple.db ...` set the
        skip tag explicitly and override any earlier table-row status. }
      if toks[0] = 'pas-skip' then begin
        name := toks[1];
        if Pos('.db', name) <> Length(name) - 2 then Continue;
        SetLength(list, Length(list) + 1);
        list[High(list)].name := name;
        list[High(list)].status := 'pas-skip';
        Continue;
      end;
      name := toks[0];
      if Pos('.db', name) <> Length(name) - 2 then Continue;
      status := toks[1];
      { strip [...] brackets }
      if (Length(status) >= 2) and (status[1] = '[') and
         (status[Length(status)] = ']') then
        status := Copy(status, 2, Length(status) - 2);
      SetLength(list, Length(list) + 1);
      list[High(list)].name := name;
      list[High(list)].status := status;
    end;
  finally
    parts.Free;
    lines.Free;
  end;
end;

function ManifestStatus(const list: TStatusList; const name: AnsiString): AnsiString;
var
  i: i32;
begin
  { pas-skip overrides win — scan once for the override. }
  for i := 0 to High(list) do
    if (list[i].name = name) and (list[i].status = 'pas-skip') then begin
      Result := 'pas-skip';
      Exit;
    end;
  for i := 0 to High(list) do
    if list[i].name = name then begin
      Result := list[i].status;
      Exit;
    end;
  Result := '';
end;

{ ----------------------------------------------------------------------
  Walk every *.queries.sql under src/tests/vectors/.
  ---------------------------------------------------------------------- }

var
  manifest: TStatusList;
  sr: TSearchRec;
  qPath, dbName, dbPath, base, sql: AnsiString;
  status: AnsiString;
  cOut, cErr, pOut, pErr: AnsiString;
  cRc, pRc: i32;
  totalGated, totalSkipped, totalDiverged, totalOk: i32;
  exitCode: i32;
  divergedThisVector: i32;
begin
  totalGated := 0;
  totalSkipped := 0;
  totalDiverged := 0;
  totalOk := 0;
  exitCode := 0;

  VectorDir := ResolveRepoRoot + 'src/tests/vectors';
  LoadManifest(manifest);
  Writeln('TestVectorReadOnly — 9.2.2 read-only parity probe');
  Writeln('Vector dir: ', VectorDir);
  Writeln('Manifest entries: ', Length(manifest));
  Writeln;

  if FindFirst(IncludeTrailingPathDelimiter(VectorDir) + '*.queries.sql',
               faAnyFile and not faDirectory, sr) = 0 then begin
    repeat
      qPath := IncludeTrailingPathDelimiter(VectorDir) + sr.Name;
      base := Copy(sr.Name, 1, Length(sr.Name) - Length('.queries.sql'));
      dbName := base + '.db';
      dbPath := IncludeTrailingPathDelimiter(VectorDir) + dbName;

      status := ManifestStatus(manifest, dbName);

      if (status = 'SKIP') or (status = 'pas-skip') then begin
        Writeln('SKIP   ', dbName, '  (status=', status, ')');
        Inc(totalSkipped);
        Continue;
      end;

      if not FileExists(dbPath) then begin
        Writeln('SKIP   ', dbName, '  (no .db blob — script-only entry)');
        Inc(totalSkipped);
        Continue;
      end;

      sql := ReadFileText(qPath);
      if sql = '' then begin
        Writeln('SKIP   ', dbName, '  (empty queries file)');
        Inc(totalSkipped);
        Continue;
      end;

      Inc(totalGated);
      RunCReadOnly(dbPath, sql, cOut, cErr, cRc);
      RunPasReadOnly(dbPath, sql, pOut, pErr, pRc);

      divergedThisVector := 0;
      if cRc <> pRc then begin
        Writeln('DIVERGE rc  ', dbName, ' : C=', cRc, ' Pas=', pRc);
        Inc(divergedThisVector);
      end;
      if cOut <> pOut then begin
        PrintDivergenceRO(dbName, 'stdout', cOut, pOut);
        Inc(divergedThisVector);
      end;
      if cErr <> pErr then begin
        PrintDivergenceRO(dbName, 'stderr', cErr, pErr);
        Inc(divergedThisVector);
      end;

      if divergedThisVector = 0 then begin
        Writeln('OK     ', dbName, '  (', Length(cOut), ' bytes stdout, rc=', cRc, ')');
        Inc(totalOk);
      end else begin
        Inc(totalDiverged);
        exitCode := 1;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end else begin
    Writeln('ERROR: no *.queries.sql files found under ', VectorDir);
    Halt(2);
  end;

  Writeln;
  Writeln('Summary: gated=', totalGated, ' ok=', totalOk,
          ' diverged=', totalDiverged, ' skipped=', totalSkipped);
  if exitCode <> 0 then
    Writeln('FAIL: read-only parity divergence(s) above')
  else
    Writeln('PASS: all gated vectors byte-identical across both oracles');
  Halt(exitCode);
end.
