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

  Vectors tagged `[SKIP]` in MANIFEST.txt (script-only, no .db) are
  skipped universally.  `pas-skip` lines are honoured **only** when
  their cite names a bucket other than `bucket-A` — bucket-A was the
  read-only-open umbrella closed in 9.2.divbug.A and is irrelevant to
  this RW-open gate (9.2.3.followup).  Each divergence prints a
  one-screen summary (vector, channel, first 16-byte window) and the
  binary exits rc=1.

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
  MANIFEST.txt parser — cite-aware, matching TestVectorSchemaChange's
  shape (9.2.3.followup).  Bucket-A was the read-only-open umbrella
  closed in 9.2.divbug.A; it is irrelevant to this RW-open round-trip
  gate.  So we only honour `pas-skip` lines whose cite (token after
  the vector name) names a bucket other than `bucket-A`.  [SKIP] in
  column 2 still means "no .db, skip" universally.
  ---------------------------------------------------------------------- }

type
  TStatusEntry = record
    name:   AnsiString;
    status: AnsiString; { 'pas-skip' | 'X' | '~' | 'SKIP' | '' }
    cite:   AnsiString; { e.g. 'bucket-B' — only meaningful for pas-skip }
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
  name, status, cite: AnsiString;
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
        cite := '';
        if Length(toks) >= 3 then cite := toks[2];
        SetLength(list, Length(list) + 1);
        list[High(list)].name := name;
        list[High(list)].status := 'pas-skip';
        list[High(list)].cite := cite;
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
      list[High(list)].cite := '';
    end;
  finally
    parts.Free;
    lines.Free;
  end;
end;

{ Returns non-zero when the cite (e.g. 'bucket-B' or
  'bucket-A,bucket-L') names any bucket that ACTUALLY applies to this
  round-trip-mutator gate.  Buckets that are RO-only (A/F/G/H/K) or
  schema-change-only (C/D/E) are filtered out so they don't keep
  vectors pas-skipped here.  Buckets B / I / J / L / M and any future
  9.2.divbug.* bucket open against the RT gate trigger the skip.
  Per 9.2.3.followup. }
function CiteAppliesToRoundTrip(const cite: AnsiString): Int32;
var
  parts: TStringList;
  k: i32;
  tok: AnsiString;
begin
  Result := 0;
  if cite = '' then Exit;
  parts := TStringList.Create;
  try
    parts.Delimiter := ',';
    parts.StrictDelimiter := True;
    parts.DelimitedText := cite;
    for k := 0 to parts.Count - 1 do begin
      tok := Trim(parts[k]);
      if Pos('bucket-', tok) <> 1 then Continue;
      { Filter buckets that are NOT RT-relevant. }
      if (tok = 'bucket-A') or  { RO-open umbrella (closed) }
         (tok = 'bucket-B') or  { bare VACUUM crash — RT mutators have no VACUUM keyword }
         (tok = 'bucket-C') or  { ALTER RENAME / view body (schema-change) }
         (tok = 'bucket-D') or  { CREATE INDEX WITHOUT ROWID (schema-change, closed) }
         (tok = 'bucket-E') or  { ALTER RENAME partial-index (schema-change, closed) }
         (tok = 'bucket-F') or  { PRAGMA auto_vacuum RO (closed) }
         (tok = 'bucket-G') or  { PRAGMA encoding RO (closed) }
         (tok = 'bucket-H') or  { WITHOUT ROWID RO sweep (closed) }
         (tok = 'bucket-K') then  { hex(UTF-16 text) RO byte-swap }
        Continue;
      Result := 1;
      Exit;
    end;
  finally
    parts.Free;
  end;
end;

function ManifestStatus(const list: TStatusList; const name: AnsiString): AnsiString;
var
  i: i32;
begin
  { pas-skip with an RT-applicable bucket cite wins; cites that name
    only RO-only / schema-only buckets are ignored on this RW gate
    (9.2.3.followup). }
  for i := 0 to High(list) do
    if (list[i].name = name) and (list[i].status = 'pas-skip') then begin
      if CiteAppliesToRoundTrip(list[i].cite) <> 0 then begin
        Result := 'pas-skip:' + list[i].cite;
        Exit;
      end;
    end;
  for i := 0 to High(list) do
    if list[i].name = name then begin
      if list[i].status = 'SKIP' then begin
        Result := 'SKIP';
        Exit;
      end;
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

      if status = 'SKIP' then begin
        Writeln('SKIP   ', dbName, '  (status=SKIP)');
        Inc(totalSkipped);
        Continue;
      end;
      if Pos('pas-skip:', status) = 1 then begin
        Writeln('SKIP   ', dbName, '  (', status, ')');
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
