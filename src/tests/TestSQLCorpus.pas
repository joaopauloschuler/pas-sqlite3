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
  TestSQLCorpus.pas — Phase 9.1.3 + 9.1.3.followup SQL-corpus differential.

  Iterates the full MANIFEST tier-1 + tier-2 corpus, pulling embedded SQL
  string literals out of each source .pas via SQLLiteralExtractor.  Each
  extracted script (= one Add(...) or Probe(...) call's SQL payload) is
  run through both oracles (C reference and the Pascal port) via
  CorpusOracle, and the four channels (stdout, stderr, rc, db-blob) are
  byte-compared.

  Per the 9.1.3.followup ticket the goal of this gate is *breadth of
  coverage*, not closing every divergence — divergences are CATALOGED
  (per-source-file counts + the first per-file diverging script) and
  the binary still exits rc=0.  Real fixes are picked up under the
  relevant Phase 6/7/8 ticket; the db-blob channel is logged but not
  asserted until 9.1.4 lands the determinism mask.

  Scope:
    Tier-1 sources (1026-row TestExplainParity spine + smaller parity
    files) and Tier-2 Diag* feature-corner files per MANIFEST.txt.
    Tier-3 entries already overlapped by tier-1 are skipped per the
    follow-up ticket; tier-4 shell-driven entries are skipped (they are
    not in-process SQL literals).

  Output:
    Per-file:   N scripts extracted, K diverged, first-diverging script.
    Overall:    totals, plus an updated src/tests/DIVERGENCES.md the
                next phase (or a human) can triage.
}
program TestSQLCorpus;

uses
  SysUtils, Classes,
  passqlite3types,
  CorpusOracle,
  SQLLiteralExtractor;

const
  { Per-file cap on the number of detailed divergence reports we print
    so the gate output stays scannable.  Aggregate counts are still
    accurate; we just stop quoting first-16-byte windows past this. }
  MAX_REPORTS_PER_FILE = 1;

  { Per-script cap on bytes of SQL we accept — guards against runaway
    string concatenation (e.g. setup arrays of 100+ rows).  Anything
    above is still run, but logged. }
  SCRIPT_BYTE_HINT = 8192;

type
  TFileEntry = record
    path:    AnsiString;
    tier:    AnsiString;
    tag:     AnsiString;
  end;

const
  N_FILES = 51;

var
  FILES: array[0..N_FILES - 1] of TFileEntry;
  gTotalScripts, gTotalDiverge, gTotalOK, gTotalErr: i32;
  gFilesProcessed, gFilesEmpty: i32;
  gDivergenceLog: TStringList;
  gRepoRoot: AnsiString;

function ResolveRepoRoot: AnsiString;
var
  binPath, binDir: AnsiString;
begin
  binPath := ExpandFileName(ParamStr(0));
  binDir := ExtractFilePath(binPath);
  { bin/TestSQLCorpus → <repo>/bin → <repo> }
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(binDir));
  if (Length(Result) = 0) or (not DirectoryExists(Result + 'src/tests')) then
    Result := GetCurrentDir + PathDelim;
  Result := IncludeTrailingPathDelimiter(Result);
end;

procedure InitFiles;
  procedure E(i: i32; const p, t, g: AnsiString);
  begin
    FILES[i].path := p;
    FILES[i].tier := t;
    FILES[i].tag  := g;
  end;
var i: i32;
begin
  i := 0;
  { ----- Tier 1 — parity spines ----- }
  E(i, 'src/tests/TestExplainParity.pas', 'tier1', 'mixed');  Inc(i);
  E(i, 'src/tests/TestWhereCorpus.pas',   'tier1', 'dql');    Inc(i);
  E(i, 'src/tests/TestBytecodeParity.pas','tier1', 'mixed');  Inc(i);
  E(i, 'src/tests/TestParser.pas',        'tier1', 'mixed');  Inc(i);
  { TestParserSmoke + TestTokenizer use neither Add/Probe; extractor
    yields 0 — harmless but listed for completeness. }
  E(i, 'src/tests/TestParserSmoke.pas',   'tier1', 'mixed');  Inc(i);
  E(i, 'src/tests/TestTokenizer.pas',     'tier1', 'mixed');  Inc(i);

  { ----- Tier 2 — feature-corner Diag* files ----- }
  E(i, 'src/tests/DiagArith.pas',                  'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagFeatureProbe.pas',           'tier2', 'mixed');   Inc(i);
  E(i, 'src/tests/DiagPredicates.pas',             'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagScalarFunc.pas',             'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagOps.pas',                    'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagMoreFunc.pas',               'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagIndexing.pas',               'tier2', 'ddl');     Inc(i);
  E(i, 'src/tests/DiagFunctions.pas',              'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagPragma.pas',                 'tier2', 'pragma');  Inc(i);
  E(i, 'src/tests/DiagMisc.pas',                   'tier2', 'mixed');   Inc(i);
  E(i, 'src/tests/DiagLikeGlob.pas',               'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagDate.pas',                   'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagCast.pas',                   'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagWindow.pas',                 'tier2', 'window');  Inc(i);
  E(i, 'src/tests/DiagTxn.pas',                    'tier2', 'txn');     Inc(i);
  E(i, 'src/tests/DiagPrintfFmt.pas',              'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagDml.pas',                    'tier2', 'dml');     Inc(i);
  E(i, 'src/tests/DiagDropTable.pas',              'tier2', 'ddl');     Inc(i);
  E(i, 'src/tests/DiagSumOverflow.pas',            'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagSampleProg.pas',             'tier2', 'mixed');   Inc(i);
  E(i, 'src/tests/DiagRecover.pas',                'tier2', 'mixed');   Inc(i);
  E(i, 'src/tests/DiagInsertSelectGroupBy.pas',    'tier2', 'dml');     Inc(i);
  E(i, 'src/tests/DiagPubApi.pas',                 'tier2', 'mixed');   Inc(i);
  E(i, 'src/tests/DiagAnalyze.pas',                'tier2', 'pragma');  Inc(i);
  E(i, 'src/tests/DiagTempTbl.pas',                'tier2', 'ddl');     Inc(i);
  E(i, 'src/tests/DiagOrderLimitTopN.pas',         'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagJoinTrace.pas',              'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagDbdump.pas',                 'tier2', 'mixed');   Inc(i);
  E(i, 'src/tests/DiagFloatRender.pas',            'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagBloom.pas',                  'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagTrig.pas',                   'tier2', 'trigger'); Inc(i);
  E(i, 'src/tests/DiagInRecursive.pas',            'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagGroupOrder.pas',             'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagErrMsg.pas',                 'tier2', 'mixed');   Inc(i);
  E(i, 'src/tests/DiagCovering.pas',               'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagInnerJoin.pas',              'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagCreateIdx.pas',              'tier2', 'ddl');     Inc(i);
  E(i, 'src/tests/DiagVacuum.pas',                 'tier2', 'vacuum');  Inc(i);
  E(i, 'src/tests/DiagConcat.pas',                 'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagMultiValues.pas',            'tier2', 'dml');     Inc(i);
  E(i, 'src/tests/DiagColName.pas',                'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagAutoIdx.pas',                'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagAggWhere.pas',               'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagSubsel.pas',                 'tier2', 'dql');     Inc(i);
  E(i, 'src/tests/DiagMaxGroupBy.pas',             'tier2', 'dql');     Inc(i);

  if i <> N_FILES then begin
    WriteLn('FATAL: file-table count mismatch: filled=', i,
            ' decl=', N_FILES);
    Halt(2);
  end;
end;

{ ----------------------------------------------------------------------
  Diagnostic helpers.
  ---------------------------------------------------------------------- }

function FirstNBytes(const s: AnsiString; n: i32): AnsiString;
var
  i, lim: i32;
  c: Byte;
begin
  Result := '';
  lim := Length(s);
  if lim > n then lim := n;
  for i := 1 to lim do begin
    c := Byte(s[i]);
    if (c >= 32) and (c < 127) and (c <> Byte('\')) then
      Result := Result + Char(c)
    else
      Result := Result + '\x' + LowerCase(IntToHex(c, 2));
  end;
end;

function ShortenSQL(const s: AnsiString; n: i32): AnsiString;
begin
  if Length(s) <= n then Result := s
  else Result := Copy(s, 1, n) + '...';
end;

{ ----------------------------------------------------------------------
  One script through both oracles.  Returns:
    0 = OK
    1 = divergence (rc/stdout/stderr — db-blob is logged not failed)
    2 = oracle setup error (e.g. workdir clash)
  ---------------------------------------------------------------------- }

function CheckScript(const tag, sql: AnsiString;
                     out which, cVal, pVal: AnsiString): i32;
var
  cOut, cErr, pOut, pErr: AnsiString;
  cBlob, pBlob: AnsiString;
  cRc, pRc: i32;
  workC, workP: AnsiString;
  baseTmp: AnsiString;
begin
  Result := 0;
  which  := '';
  cVal := ''; pVal := '';

  baseTmp := IncludeTrailingPathDelimiter(GetTempDir(False)) +
             'pas-sqlite3-corpus-' + IntToStr(GetProcessID) + '-';
  workC := baseTmp + tag + '-c';
  workP := baseTmp + tag + '-p';
  ForceDirectories(workC);
  ForceDirectories(workP);

  RunCOracle  (PAnsiChar(sql), PAnsiChar(workC), cOut, cErr, cRc, cBlob);
  RunPasOracle(PAnsiChar(sql), PAnsiChar(workP), pOut, pErr, pRc, pBlob);

  if cRc <> pRc then begin
    which := 'rc';
    cVal := AnsiString(IntToStr(cRc));
    pVal := AnsiString(IntToStr(pRc));
    Result := 1; Exit;
  end;
  if cOut <> pOut then begin
    which := 'stdout'; cVal := cOut; pVal := pOut;
    Result := 1; Exit;
  end;
  if cErr <> pErr then begin
    which := 'stderr'; cVal := cErr; pVal := pErr;
    Result := 1; Exit;
  end;
  { db-blob is intentionally not asserted here — see Phase 9.1.4. }
  if cBlob <> pBlob then begin
    which := 'db-blob (log-only, gated on 9.1.4)';
    cVal := AnsiString(IntToStr(Length(cBlob)));
    pVal := AnsiString(IntToStr(Length(pBlob)));
    { not a failure }
  end;
end;

{ ----------------------------------------------------------------------
  Process one MANIFEST source file.
  ---------------------------------------------------------------------- }

procedure ProcessFile(const fe: TFileEntry);
var
  scripts: TStringList;
  i, n, rc, reported: i32;
  which, cVal, pVal: AnsiString;
  fileDiverge, fileOK: i32;
  tag, firstDivSql, firstDivChan: AnsiString;
begin
  scripts := TStringList.Create;
  try
    if not FileExists(gRepoRoot + fe.path) then begin
      WriteLn('[', fe.tier, '] ', fe.path, ' — MISSING (skipped)');
      Inc(gFilesEmpty);
      Exit;
    end;

    n := ExtractSQLLiterals(gRepoRoot + fe.path, scripts);
    if n = 0 then begin
      WriteLn('[', fe.tier, '] ', fe.path,
              ' — 0 SQL literals extracted (skipped)');
      Inc(gFilesEmpty);
      Exit;
    end;
    Inc(gFilesProcessed);

    fileDiverge := 0;
    fileOK := 0;
    reported := 0;
    firstDivSql := '';
    firstDivChan := '';

    for i := 0 to scripts.Count - 1 do begin
      Inc(gTotalScripts);
      tag := ExtractFileName(fe.path) + ':' + IntToStr(i);
      rc := CheckScript(tag, scripts[i], which, cVal, pVal);
      if rc = 0 then begin
        if which = '' then begin
          Inc(fileOK);
          Inc(gTotalOK);
        end else begin
          { db-blob log-only divergence — not a counted failure. }
          Inc(fileOK);
          Inc(gTotalOK);
        end;
      end else if rc = 1 then begin
        Inc(fileDiverge);
        Inc(gTotalDiverge);
        if firstDivSql = '' then begin
          firstDivSql := scripts[i];
          firstDivChan := which;
        end;
        if reported < MAX_REPORTS_PER_FILE then begin
          WriteLn('  DIVERGE [', tag, '] channel=', which);
          WriteLn('    sql  : ', ShortenSQL(scripts[i], 120));
          WriteLn('    c[..16]: ', FirstNBytes(cVal, 16));
          WriteLn('    p[..16]: ', FirstNBytes(pVal, 16));
          WriteLn('    c.len=', Length(cVal), ' p.len=', Length(pVal));
          Inc(reported);
        end;
      end else
        Inc(gTotalErr);
    end;

    WriteLn('[', fe.tier, '] ', fe.path,
            ' — scripts=', n,
            ' ok=', fileOK,
            ' diverge=', fileDiverge);
    if fileDiverge > 0 then begin
      gDivergenceLog.Add('| ' + fe.path + ' | ' + fe.tier + ' | ' + fe.tag +
                        ' | ' + IntToStr(n) + ' | ' + IntToStr(fileDiverge) +
                        ' | ' + firstDivChan + ' | `' +
                        ShortenSQL(firstDivSql, 80) + '` |');
    end;
  finally
    scripts.Free;
  end;
end;

procedure WriteDivergencesMd(const path: AnsiString);
var
  md: TStringList;
  i: i32;
begin
  md := TStringList.Create;
  try
    md.Add('# DIVERGENCES.md');
    md.Add('');
    md.Add('Generated by `bin/TestSQLCorpus` (Phase 9.1.3.followup).');
    md.Add('Each row is a per-MANIFEST-file rollup of differential SQL');
    md.Add('execution against the C reference oracle.  The "first" column');
    md.Add('is the first diverging script in that file — additional');
    md.Add('divergences in the same file are counted but not quoted.');
    md.Add('');
    md.Add('TestSQLCorpus exits rc=0 regardless of divergence count — the');
    md.Add('purpose is *coverage breadth* and *cataloguing*, not gating.');
    md.Add('Real fixes are picked up under the relevant Phase 6/7/8');
    md.Add('ticket; db-blob differences are deferred to Phase 9.1.4.');
    md.Add('');
    md.Add('| source | tier | tag | scripts | diverge | first channel | first script (truncated) |');
    md.Add('|--------|------|-----|---------|---------|---------------|--------------------------|');
    for i := 0 to gDivergenceLog.Count - 1 do
      md.Add(gDivergenceLog[i]);
    md.Add('');
    md.Add('_End of file._');
    md.SaveToFile(path);
  finally
    md.Free;
  end;
end;

var
  i: i32;

begin
  WriteLn('=== TestSQLCorpus — Phase 9.1.3.followup full MANIFEST coverage ===');
  WriteLn('Extracting SQL literals from ', N_FILES,
          ' tier-1 + tier-2 sources.');
  WriteLn;

  gRepoRoot := ResolveRepoRoot;
  WriteLn('Repo root        : ', gRepoRoot);
  InitFiles;
  gTotalScripts   := 0;
  gTotalDiverge   := 0;
  gTotalOK        := 0;
  gTotalErr       := 0;
  gFilesProcessed := 0;
  gFilesEmpty     := 0;
  gDivergenceLog  := TStringList.Create;

  try
    for i := 0 to N_FILES - 1 do
      ProcessFile(FILES[i]);

    WriteLn;
    WriteLn('--- summary ---');
    WriteLn('  files processed : ', gFilesProcessed);
    WriteLn('  files empty/skip: ', gFilesEmpty);
    WriteLn('  scripts run     : ', gTotalScripts);
    WriteLn('  scripts ok      : ', gTotalOK);
    WriteLn('  scripts diverge : ', gTotalDiverge);
    if SCRIPT_BYTE_HINT >= 0 then ; { silence unused-const warning }

    WriteDivergencesMd(gRepoRoot + 'src/tests/DIVERGENCES.md');
    WriteLn('  divergences log : ', gRepoRoot, 'src/tests/DIVERGENCES.md');
  finally
    gDivergenceLog.Free;
  end;

  WriteLn;
  WriteLn('TestSQLCorpus: OK (rc=0; divergences catalogued, not gated — see');
  WriteLn('  tasklist 9.1.3.followup + 9.1.4)');
  Halt(0);
end.
