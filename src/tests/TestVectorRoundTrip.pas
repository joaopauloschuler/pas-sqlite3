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
  TestVectorRoundTrip.pas — Phase 9.2.3 round-trip mutator probe.

  Walks every `*.mutate.sql` under src/tests/vectors/, copies the source
  `<name>.db` into two fresh workdirs (one for the C oracle, one for the
  Pascal port), opens RW, executes the mutator script (a single explicit
  BEGIN ... COMMIT transaction), closes, then byte-diffs the resulting
  blobs after applying CorpusOracle.ApplyHeaderMask (the existing 9.1.4
  header mask).

  Vectors tagged `pas-skip` or `[SKIP]` in MANIFEST.txt are skipped (corpus
  skip-and-cite contract).  Each divergence prints a one-screen summary
  (vector, channel, first 16-byte window) and the binary exits rc=1.

  Shared harness (file/dir helpers, exec runners, diff/window helpers,
  PrintDivergence, ResolveRepoRoot) lives in TestVectorCommon.
  Re-uses CorpusOracle.pas's ApplyHeaderMask plumbing rather than
  re-implementing the mask offsets.
}
program TestVectorRoundTrip;

uses
  SysUtils, Classes,
  passqlite3types,
  CorpusOracle,
  TestVectorCommon;

var
  VectorDir: AnsiString;  { resolved at startup — see ResolveRepoRoot }

{ ----------------------------------------------------------------------
  MANIFEST.txt parser — copy of TestVectorReadOnly's parser.  Same
  legend: [X] / [~] / [SKIP] in column 2, plus explicit `pas-skip`
  override lines in the trailing block.
  ---------------------------------------------------------------------- }

type
  TStatusEntry = record
    name:   AnsiString;
    status: AnsiString;
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
      if (line = '') or (line[1] = '-') or (line[1] = '=') then Continue;
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
  Walk every *.mutate.sql under src/tests/vectors/.
  ---------------------------------------------------------------------- }

var
  manifest: TStatusList;
  sr: TSearchRec;
  mPath, dbName, dbPath, base, sql: AnsiString;
  status: AnsiString;
  tmpRoot, cWork, pWork: AnsiString;
  cOut, cErr, pOut, pErr, cBlob, pBlob: AnsiString;
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
  Writeln('TestVectorRoundTrip — 9.2.3 round-trip mutator probe');
  Writeln('Vector dir: ', VectorDir);
  Writeln('Manifest entries: ', Length(manifest));
  Writeln;

  tmpRoot := IncludeTrailingPathDelimiter(GetTempDir) + 'pas-sqlite3-rt';
  ForceDirectories(tmpRoot);

  if FindFirst(IncludeTrailingPathDelimiter(VectorDir) + '*.mutate.sql',
               faAnyFile and not faDirectory, sr) = 0 then begin
    repeat
      mPath := IncludeTrailingPathDelimiter(VectorDir) + sr.Name;
      base := Copy(sr.Name, 1, Length(sr.Name) - Length('.mutate.sql'));
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

      sql := ReadFileText(mPath);
      if sql = '' then begin
        Writeln('SKIP   ', dbName, '  (empty mutator file)');
        Inc(totalSkipped);
        Continue;
      end;

      Inc(totalGated);
      cWork := IncludeTrailingPathDelimiter(tmpRoot) + base + '-c';
      pWork := IncludeTrailingPathDelimiter(tmpRoot) + base + '-pas';

      RunCExec(dbPath, cWork, sql, cOut, cErr, cRc, cBlob);
      RunPasExec(dbPath, pWork, sql, pOut, pErr, pRc, pBlob);

      ApplyHeaderMask(cBlob);
      ApplyHeaderMask(pBlob);

      divergedThisVector := 0;
      if cRc <> pRc then begin
        Writeln('DIVERGE rc  ', dbName, ' : C=', cRc, ' Pas=', pRc);
        Writeln('  C  stderr: ', cErr);
        Writeln('  Pas stderr: ', pErr);
        Inc(divergedThisVector);
      end;
      if cOut <> pOut then begin
        PrintDivergence(dbName, sr.Name, 'stdout', cOut, pOut, 'mutator');
        Inc(divergedThisVector);
      end;
      if cErr <> pErr then begin
        PrintDivergence(dbName, sr.Name, 'stderr', cErr, pErr, 'mutator');
        Inc(divergedThisVector);
      end;
      if cBlob <> pBlob then begin
        PrintDivergence(dbName, sr.Name, 'db-blob (post-mask)', cBlob, pBlob, 'mutator');
        Inc(divergedThisVector);
      end;

      if divergedThisVector = 0 then begin
        Writeln('OK     ', dbName, '  (', Length(cBlob), ' byte blob, rc=', cRc, ')');
        Inc(totalOk);
      end else begin
        Inc(totalDiverged);
        exitCode := 1;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end else begin
    Writeln('ERROR: no *.mutate.sql files found under ', VectorDir);
    Halt(2);
  end;

  Writeln;
  Writeln('Summary: gated=', totalGated, ' ok=', totalOk,
          ' diverged=', totalDiverged, ' skipped=', totalSkipped);
  if exitCode <> 0 then
    Writeln('FAIL: round-trip parity divergence(s) above')
  else
    Writeln('PASS: all gated vectors byte-identical post-mutator across both oracles');
  Halt(exitCode);
end.
