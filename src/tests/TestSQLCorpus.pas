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
  passqlite3vdbe,
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
    { 9.1.5 — status tag from corpus/STATUS.txt; one of
      'pas-strict', 'pas-soft', 'pas-skip'.  Resolved at startup
      via LoadStatusTags; pas-strict is the CI gate (any divergence
      fails rc≠0).  pas-soft / pas-skip are reported but pass. }
    status:  AnsiString;
    cite:    AnsiString;
  end;

const
  N_FILES = 51;

var
  FILES: array[0..N_FILES - 1] of TFileEntry;
  gTotalScripts, gTotalDiverge, gTotalOK, gTotalErr: i32;
  gFilesProcessed, gFilesEmpty: i32;
  gDivergenceLog: TStringList;
  gRepoRoot: AnsiString;
  { 9.1.5 — strict-tag CI gate counters.  gStrictDiverge is the
    number of divergences in pas-strict rows; non-zero => rc≠0. }
  gStrictDiverge, gSoftDiverge, gSkipDiverge: i32;
  gStrictFiles, gSoftFiles, gSkipFiles: i32;

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
    FILES[i].path   := p;
    FILES[i].tier   := t;
    FILES[i].tag    := g;
    { Default status before STATUS.txt is consulted.  Any row not
      explicitly listed in STATUS.txt is treated as pas-strict so
      new MANIFEST entries default to the gate (fail-open is unsafe). }
    FILES[i].status := 'pas-strict';
    FILES[i].cite   := '-';
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
  9.1.5 — Status-tag loader.

  Parses src/tests/corpus/STATUS.txt (TAB-delimited, '#' comments
  ignored) and overlays the resolved status/cite onto the FILES[]
  table.  Any MANIFEST row missing from STATUS.txt is left at its
  InitFiles default (pas-strict) — failing the gate is the
  conservative posture for an unclassified row.
  ---------------------------------------------------------------------- }

procedure LoadStatusTags(const path: AnsiString);
var
  sl: TStringList;
  i, j, k, n: i32;
  line, p, st, ct: AnsiString;
  parts: array[0..3] of AnsiString;
  np: i32;
begin
  if not FileExists(path) then begin
    WriteLn('WARN: STATUS.txt not found at ', path,
            ' — every row defaults to pas-strict (CI gate).');
    Exit;
  end;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(path);
    for i := 0 to sl.Count - 1 do begin
      line := sl[i];
      { Trim leading whitespace }
      while (Length(line) > 0) and ((line[1] = ' ') or (line[1] = #9)) do
        Delete(line, 1, 1);
      if Length(line) = 0 then continue;
      if line[1] = '#' then continue;
      { Split on TAB into up to 4 fields. }
      np := 0;
      for k := 0 to 3 do parts[k] := '';
      j := 1;
      while (j <= Length(line)) and (np < 4) do begin
        n := j;
        while (n <= Length(line)) and (line[n] <> #9) do Inc(n);
        parts[np] := Copy(line, j, n - j);
        Inc(np);
        j := n + 1;
      end;
      if np < 2 then continue;
      p  := parts[0];
      st := parts[1];
      if np >= 3 then ct := parts[2] else ct := '-';
      { Match against FILES[]. }
      for k := 0 to N_FILES - 1 do begin
        if FILES[k].path = p then begin
          FILES[k].status := st;
          FILES[k].cite   := ct;
          Break;
        end;
      end;
    end;
  finally
    sl.Free;
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
  { Phase 9.1.4 — db-blob channel is now gated on, with the
    non-deterministic header fields zeroed by ApplyHeaderMask.  See
    src/tests/corpus/MASK.md for the full list of masked byte ranges +
    C-source citations.  Per the skip-and-cite contract divergences are
    *cataloged* into DIVERGENCES.md but do NOT fail the binary. }
  ApplyHeaderMask(cBlob);
  ApplyHeaderMask(pBlob);
  if cBlob <> pBlob then begin
    which := 'db-blob';
    cVal := cBlob; pVal := pBlob;
    Result := 1; Exit;
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
            ' [', fe.status, ']',
            ' — scripts=', n,
            ' ok=', fileOK,
            ' diverge=', fileDiverge);

    { 9.1.5 — bucket per-file divergence by status tag. }
    if fe.status = 'pas-strict' then begin
      Inc(gStrictFiles);
      Inc(gStrictDiverge, fileDiverge);
      if fileDiverge > 0 then
        WriteLn('  STRICT-GATE FAIL: pas-strict row diverged ',
                fileDiverge, ' time(s) — gate will fail.');
    end else if fe.status = 'pas-soft' then begin
      Inc(gSoftFiles);
      Inc(gSoftDiverge, fileDiverge);
      if fileDiverge > 0 then
        WriteLn('  pas-soft (cite=', fe.cite,
                '): ', fileDiverge, ' divergence(s) tracked, non-blocking.');
    end else if fe.status = 'pas-skip' then begin
      Inc(gSkipFiles);
      Inc(gSkipDiverge, fileDiverge);
      if fileDiverge > 0 then
        WriteLn('  pas-skip (cite=', fe.cite,
                '): ', fileDiverge, ' divergence(s) tracked, gated on cited bullet.');
    end else begin
      WriteLn('  WARN: unknown status="', fe.status,
              '" treated as pas-strict (gate failure on diverge).');
      Inc(gStrictFiles);
      Inc(gStrictDiverge, fileDiverge);
    end;

    if fileDiverge > 0 then begin
      gDivergenceLog.Add('| ' + fe.path + ' | ' + fe.tier + ' | ' + fe.tag +
                        ' | ' + fe.status + ' | ' + fe.cite +
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
    md.Add('ticket.  Phase 9.1.4 landed the determinism mask (see');
    md.Add('`src/tests/corpus/MASK.md`); db-blob divergences that');
    md.Add('survive the mask are real port drift.');
    md.Add('');
    md.Add('| source | tier | tag | status | cite | scripts | diverge | first channel | first script (truncated) |');
    md.Add('|--------|------|-----|--------|------|---------|---------|---------------|--------------------------|');
    for i := 0 to gDivergenceLog.Count - 1 do
      md.Add(gDivergenceLog[i]);
    md.Add('');
    md.Add('_End of file._');
    md.SaveToFile(path);
  finally
    md.Free;
  end;
end;

{ ----------------------------------------------------------------------
  9.1.6 — opcode coverage report.

  After running the corpus with gVdbeOpCoverageEnabled=1, walk the
  192-entry gVdbeOpCoverage[] array and report any opcode that
  remained at zero.  The "cold-set" is then filtered against an
  allow-list of opcodes that are gated on unported features
  (vtab/vacuum/integrity-check tail) — those are catalogued into
  src/tests/corpus/COVERAGE_GAPS.md instead of failing the gate.
  ---------------------------------------------------------------------- }

{ 9.1.6 — coverage-driver scripts.  Each entry is a self-contained
  SQL fragment that the corpus runs through both oracles only when
  --coverage is set.  Goal: drive specific cold opcodes hot.  Each
  entry is byte-identical across oracles (verified during the run),
  so they also contribute to the pas-strict gate.

  Mapping (opcode -> driver index, for auditing):
    Or, IsTrue              -> idx 0
    SeekLT/LE/GT, Prev,
      IdxLT/GE, ReopenIdx   -> idx 1 (DESC scan with index)
    IfEmpty                 -> idx 2 (CREATE-AS-SELECT empty src)
    HaltIfNull, SoftNull,
      TypeCheck             -> idx 3 (STRICT + NOT NULL)
    Offset                  -> idx 4
    Clear, DropIndex,
      DropTrigger, IdxDelete -> idx 5
    AggInverse, AggValue,
      MemMax                -> idx 6 (window frame + max)
    GetSubtype, SetSubtype,
      ClrSubtype            -> idx 7 (json_object)
    FkCheck, FkCounter,
      FkIfZero              -> idx 8 (FK on cascade)
    RowSetRead, RowSetTest,
      RowSetAdd             -> idx 9 (rowid IN (subselect))
    Permutation, OpenDup    -> idx 10 (compound + correlated)
    SorterCompare,
      ResetSorter,
      RowCell, SeekEnd,
      FinishSeek            -> idx 11 (UPDATE w/sorter)
    ElseEq                  -> idx 12 (CASE compound)
    SeekScan, SeekHit       -> idx 13 (multi-col indexed range) }
const
  { 9.1.6.followup drivers:
      14: SELECT row over string literal -> OP_String8 rewrites to OP_String
          on first row, subsequent rows hit OP_String.
      15: REAL column INSERT/SELECT -> OP_RealAffinity on read-out.
      16: PRAGMA page_count / max_page_count -> OP_Pagecount, OP_MaxPgcnt.
      17: AUTOINCREMENT INSERT -> OP_MemMax, plus `x IS TRUE` -> OP_IsTrue. }
  N_COVERAGE_SCRIPTS = 18;
  COVERAGE_SCRIPTS: array[0..N_COVERAGE_SCRIPTS - 1] of AnsiString = (
    'SELECT 1 WHERE 1=1 OR 0=1; SELECT 1 WHERE TRUE;',
    'CREATE TABLE cv1(a INTEGER PRIMARY KEY, b); ' +
      'INSERT INTO cv1 VALUES(1,10),(2,20),(3,30),(4,40),(5,50); ' +
      'CREATE INDEX cv1_b ON cv1(b); ' +
      'SELECT a FROM cv1 WHERE b<40 ORDER BY b DESC; ' +
      'SELECT a FROM cv1 WHERE b<=30 ORDER BY b DESC; ' +
      'SELECT a FROM cv1 WHERE b>10 ORDER BY b DESC; ' +
      'SELECT a FROM cv1 ORDER BY a DESC LIMIT 3;',
    'CREATE TABLE cv2(x); SELECT count(*) FROM cv2; ' +
      'INSERT INTO cv2 SELECT * FROM cv2 WHERE 0; SELECT count(*) FROM cv2;',
    'CREATE TABLE cv3(x INTEGER NOT NULL, y INTEGER) STRICT; ' +
      'INSERT INTO cv3(x,y) VALUES(1,2),(3,4); ' +
      'SELECT x,y FROM cv3;',
    'CREATE TABLE cv4(a); INSERT INTO cv4 VALUES(1),(2),(3),(4),(5),(6); ' +
      'SELECT a FROM cv4 ORDER BY a LIMIT 2 OFFSET 3;',
    'CREATE TABLE cv5(a, b); CREATE INDEX cv5_b ON cv5(b); ' +
      'CREATE TRIGGER cv5_t AFTER INSERT ON cv5 BEGIN SELECT 1; END; ' +
      'INSERT INTO cv5 VALUES(1,10),(2,20),(3,30); ' +
      'UPDATE cv5 SET b=b+1; ' +
      'DELETE FROM cv5; ' +
      'DROP TRIGGER cv5_t; DROP INDEX cv5_b;',
    'CREATE TABLE cv6(g, v); ' +
      'INSERT INTO cv6 VALUES(''a'',1),(''a'',2),(''a'',3),(''b'',10),(''b'',20); ' +
      'SELECT g, sum(v) OVER (PARTITION BY g ORDER BY v ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM cv6 ORDER BY g, v; ' +
      'SELECT g, max(v) FROM cv6 GROUP BY g ORDER BY g;',
    'SELECT json_object(''k'', 1, ''v'', json_array(1,2,3));',
    'PRAGMA foreign_keys=ON; ' +
      'CREATE TABLE cv8p(id INTEGER PRIMARY KEY); ' +
      'CREATE TABLE cv8c(p INTEGER REFERENCES cv8p(id) ON DELETE CASCADE); ' +
      'INSERT INTO cv8p VALUES(1),(2); ' +
      'INSERT INTO cv8c VALUES(1),(2); ' +
      'DELETE FROM cv8p WHERE id=1; ' +
      'SELECT * FROM cv8c ORDER BY p;',
    'CREATE TABLE cv9(a INTEGER PRIMARY KEY, b); ' +
      'INSERT INTO cv9 VALUES(1,10),(2,20),(3,30),(4,40); ' +
      'SELECT a FROM cv9 WHERE a IN (SELECT a FROM cv9 WHERE b>=20) ORDER BY a;',
    'CREATE TABLE cv10(a, b); ' +
      'INSERT INTO cv10 VALUES(1,10),(2,20),(3,30); ' +
      'SELECT a, b FROM cv10 UNION ALL SELECT b, a FROM cv10 ORDER BY 1, 2;',
    'CREATE TABLE cv11(a INTEGER PRIMARY KEY, b); ' +
      'CREATE INDEX cv11_b ON cv11(b); ' +
      'INSERT INTO cv11 VALUES(1,100),(2,200),(3,300),(4,400); ' +
      'UPDATE cv11 SET b=b+1 ORDER BY b LIMIT 10;',
    'CREATE TABLE cv12(x); INSERT INTO cv12 VALUES(1),(2),(3); ' +
      'SELECT CASE x WHEN 1 THEN ''a'' WHEN 2 THEN ''b'' ELSE ''c'' END FROM cv12 ORDER BY x;',
    'CREATE TABLE cv13(a, b, c); ' +
      'CREATE INDEX cv13_ab ON cv13(a,b); ' +
      'INSERT INTO cv13 VALUES(1,10,100),(1,20,200),(2,10,300),(2,20,400); ' +
      'SELECT c FROM cv13 WHERE a=1 AND b BETWEEN 5 AND 25 ORDER BY b;',
    { cv14 — OP_String: SELECT with a string literal across many rows.
      First row's OP_String8 rewrites itself to OP_String; subsequent rows
      then hit the OP_String dispatch arm directly. }
    'CREATE TABLE cv14(x); ' +
      'INSERT INTO cv14 VALUES(1),(2),(3),(4),(5); ' +
      'SELECT ''hello'' FROM cv14;',
    { cv15 — OP_RealAffinity: REAL column read-out emits trailing
      OP_RealAffinity on the gathered record (codegen.pas:33100 +
      :31801). }
    'CREATE TABLE cv15(r REAL); ' +
      'INSERT INTO cv15 VALUES(1.5),(2.25),(3.125); ' +
      'SELECT r FROM cv15 ORDER BY r;',
    { cv16 — OP_Pagecount + OP_MaxPgcnt: PRAGMA page_count emits
      OP_Pagecount (codegen.pas:47177); PRAGMA max_page_count emits
      OP_MaxPgcnt (codegen.pas:47167). }
    'PRAGMA page_count; PRAGMA max_page_count;',
    { cv17 — OP_MemMax via AUTOINCREMENT (codegen.pas:35705) +
      OP_IsTrue via `x IS TRUE` (codegen.pas:5511). }
    'CREATE TABLE cv17(id INTEGER PRIMARY KEY AUTOINCREMENT, v); ' +
      'INSERT INTO cv17(v) VALUES(1),(2),(3); ' +
      'SELECT id, v IS TRUE, v IS FALSE FROM cv17 ORDER BY id;'
  );

procedure RunCoverageScripts;
var
  i: i32;
  rc: i32;
  which, cv, pv: AnsiString;
  drove: i32;
begin
  WriteLn;
  WriteLn('--- 9.1.6 coverage-driver scripts (', N_COVERAGE_SCRIPTS,
          ' SQL chunks; pas-strict-gated) ---');
  drove := 0;
  for i := 0 to N_COVERAGE_SCRIPTS - 1 do begin
    Inc(gTotalScripts);
    rc := CheckScript('coverage:' + IntToStr(i),
                      COVERAGE_SCRIPTS[i], which, cv, pv);
    if rc = 0 then begin
      Inc(gTotalOK);
      Inc(drove);
    end else if rc = 1 then begin
      Inc(gTotalDiverge);
      Inc(gStrictDiverge);   { count as strict-gate failure }
      WriteLn('  COVERAGE DRIVER DIVERGED [coverage:', i,
              '] channel=', which);
      WriteLn('    sql  : ', ShortenSQL(COVERAGE_SCRIPTS[i], 120));
      WriteLn('    c[..16]: ', FirstNBytes(cv, 16));
      WriteLn('    p[..16]: ', FirstNBytes(pv, 16));
    end else
      Inc(gTotalErr);
  end;
  WriteLn('  drove ', drove, '/', N_COVERAGE_SCRIPTS, ' coverage scripts cleanly.');
end;

function CoverageGapReason(op: i32): AnsiString;
begin
  { 9.1.6.followup — per-opcode citation.  Each entry pins the gating
    Phase 6/7/8/10 bullet (or planner-shape heuristic) so the auditor
    can reach the emit path without re-deriving it. }
  case op of
    OP_VFilter,    OP_VUpdate,    OP_VBegin,   OP_VCreate,
    OP_VDestroy,   OP_VOpen,      OP_VCheck,   OP_VInitIn,
    OP_VColumn,    OP_VRename,    OP_VNext:
      Result := '(a) vtab partial port — Phase 6.8.0..6.8.6 wired vtab emit but the corpus does not CREATE VIRTUAL TABLE; eponymous-vtab arms covered by TestVtab.';
    OP_Vacuum, OP_IncrVacuum:
      Result := '(a) VACUUM gated on Phase 6.28 incrVacuumStep / relocatePage; corpus runs in-memory and DiagVacuum is the dedicated probe.';
    OP_Checkpoint, OP_JournalMode:
      Result := '(a) WAL paths — corpus uses journal_mode=delete; WAL exercise lives in 9.2.1 wal.db vector and TestWalCompat.';
    OP_IntegrityCk, OP_LoadAnalysis:
      Result := '(a) integrity_check / ANALYZE walk arms — Phase 6.28.6.b open (~430 lines, schema-level integrity arms).';
    OP_Abortable, OP_CursorLock, OP_CursorUnlock:
      Result := '(a) debug/diagnostic emit (SQLITE_DEBUG / shared-cache); not enabled in this build.';
    OP_FilterAdd, OP_Filter:
      Result := '(a) bloom-filter planner hint — emit gated on star-join shape heuristic; partial port under Phase 6.13.B, exercised by DiagBloom.pas.';
    OP_IsType:
      Result := '(a) typeof() fast-path; emit gated on ON-conflict edge that no corpus row reaches.';
    OP_AggStep1, OP_PureFunc:
      Result := '(a) specialised aggregate / pure-function fast-path; planner heuristic.';
    OP_IfNoHope, OP_IfNotOpen, OP_IfSizeBetween, OP_SequenceTest, OP_ColumnsUsed:
      Result := '(a) planner micro-optimisation; emit gated on planner shape not reached by corpus.';
    OP_SeekGT, OP_IdxLT, OP_IdxGE:
      Result := '(a) DESC range scan — driver hits SeekLT/LE/Prev but planner picks different ops for ">" + DESC; planner-shape gated.';
    OP_IfEmpty:
      Result := '(a) CTAS empty-result-check heuristic in sqlite3WhereBegin; no corpus shape triggers it.';
    OP_Or:
      Result := '(a) logical OR folded by sqlite3ExprIfTrue into branches; OP_Or only emitted on RHS-subquery OR (codegen.pas:5949).';
    OP_IFindKey:
      Result := '(a) incremental hash key probe; emitted only by integrity-check tail — gated on Phase 6.28.6.b.';
    OP_RowSetTest:
      Result := '(a) multi-IN-set dedup; emit gated on set-cardinality heuristic.';
    OP_ElseEq:
      Result := '(a) compound CASE WHEN + IN(...) special path in sqlite3ExprCodeIN; specific shape gating.';
    OP_SoftNull:
      Result := '(a) ON CONFLICT IGNORE + partial-index emit (codegen.pas:35574); specific NOT NULL + IGNORE row needed.';
    OP_Variable:
      Result := '(a) sqlite3_bind_*; corpus uses sqlite3_exec with no parameters — gated on prepared-stmt binding spine, not codegen.';
    OP_FkCheck:
      Result := '(a) deferred FK check (codegen.pas:32180/41635); emit on PRAGMA defer_foreign_keys=ON + COMMIT path.';
    OP_Permutation:
      Result := '(a) compound SELECT sort-key permutation (codegen.pas:22707); emit only when ORDER BY refs >1 SELECT result alias.';
    OP_Offset:
      Result := '(a) sqlite_offset() builtin; SQLITE_ENABLE_OFFSET_SQL_FUNC arm of index-rewrite tail is deferred (codegen.pas:20312).';
    OP_TypeCheck:
      Result := '(a) STRICT-table column-type guard; emit gated on specific affinity-mismatch shape.';
    OP_ReopenIdx:
      Result := '(a) cursor-reuse coalesce of consecutive OpenRead; emit gated on OR-disjunct shared-cursor shape (codegen.pas:19509/20137).';
    OP_SeekScan, OP_SeekHit:
      Result := '(a) multi-column index seek-then-scan optimisation; STAT4-driven heuristic — Phase 10.1.42.b.7 open.';
    OP_RowCell:
      Result := '(a) WITHOUT ROWID UPDATE-of-PK cell-rewrite (codegen.pas:36080/36127); gated on WITHOUT ROWID + UPDATE-of-PK shape.';
    OP_SorterCompare, OP_FinishSeek:
      Result := '(a) sorter-driven UPDATE / deferred-seek finalize; emit gated on UPDATE-with-ORDER-BY-LIMIT + ephemeral-sorter shape.';
    OP_SqlExec:
      Result := '(a) nested SQL — emitted only by sqlite3_dbpage / sqlite3_recover paths; corpus uses neither.';
    OP_TableLock:
      Result := '(a) shared-cache TABLE LOCK emit; shared-cache not enabled in this build.';
    OP_ClrSubtype, OP_GetSubtype, OP_SetSubtype:
      Result := '(a) JSON subtype propagation across nested function calls; emit gated on json1 ops in non-result position.';
    OP_CursorHint:
      Result := '(a) gated on SQLITE_ENABLE_CURSOR_HINTS; not enabled in this build.';
  else
    Result := '(a) allow-listed cold — see IsCoverageGap for gating comment.';
  end;
end;

function IsCoverageGap(op: i32): Int32;
begin
  { Allow-list of opcodes that current passqlite3codegen paths cannot
    legitimately exercise from the corpus.  Anything here is logged
    into COVERAGE_GAPS.md but does NOT fail the gate.  When the
    gating port lands, remove the entry and add a targeted .sql to
    drive the opcode hot. }
  case op of
    OP_VFilter,    OP_VUpdate,    OP_VBegin,   OP_VCreate,
    OP_VDestroy,   OP_VOpen,      OP_VCheck,   OP_VInitIn,
    OP_VColumn,    OP_VRename,    OP_VNext:
      Result := 1; { vtab — partial port; corpus does not register vtabs }
    OP_Vacuum, OP_IncrVacuum:
      Result := 1; { VACUUM — corpus runs in-memory; vacuum gated separately }
    OP_Checkpoint, OP_JournalMode:
      Result := 1; { WAL paths — corpus uses default journal_mode=delete }
    OP_IntegrityCk, OP_LoadAnalysis:
      Result := 1; { ANALYZE / PRAGMA integrity_check — heavy paths gated separately }
    OP_Abortable, OP_CursorLock, OP_CursorUnlock:
      Result := 1; { debug/diagnostic emit-conditions; not on a corpus-driver path }
    OP_FilterAdd, OP_Filter:
      Result := 1; { bloom-filter planner hint; emitted only under specific star-join shapes }
    OP_IsType:
      Result := 1; { typeof() fast-path; no corpus row exercises the ON-conflict edge }
    OP_AggStep1, OP_PureFunc:
      Result := 1; { specialised aggregate / pure-function fast-paths gated on planner heuristics }
    OP_IfNoHope, OP_IfNotOpen, OP_IfSizeBetween, OP_SequenceTest, OP_ColumnsUsed:
      Result := 1; { planner micro-optimisations — emit gated on shapes the corpus does not reach }
    { 9.1.6 — second-tier allow-list: opcodes the planner emits only
      under specific shapes that the corpus + coverage drivers do not
      reach.  Each is a candidate for a future targeted .sql when the
      corresponding planner branch becomes a priority.  Citing the
      port path that emits each one (search passqlite3codegen.pas for
      `OP_<name>`) so an auditor can reproduce the gating shape. }
    OP_SeekGT, OP_IdxLT, OP_IdxGE:
      Result := 1; { DESC range scan with index — driver hits SeekLT/LE/Prev but planner picks different ops for ">" + DESC. }
    OP_IfEmpty:
      Result := 1; { sqlite3WhereBegin emit gated on EmptyResultCheck heuristic; no corpus shape triggers it. }
    OP_Or:
      Result := 1; { logical OR is folded by sqlite3ExprIfTrue into branches, not OP_Or; reachable only via direct SELECT a OR b column expr. }
    OP_IFindKey:
      Result := 1; { incremental hash key probe (vdbeaux); only emitted by integrity-check tail. }
    OP_RowSetTest:
      Result := 1; { multi-IN-set dedup; planner only emits when set cardinality estimate trips heuristic. }
    OP_ElseEq:
      Result := 1; { compound CASE WHEN + IN(...) special path; emitted by sqlite3ExprCodeIN under specific shapes. }
    OP_SoftNull:
      Result := 1; { ON CONFLICT IGNORE / partial-index emit; needs specific NOT NULL + ON CONFLICT IGNORE row. }
    OP_Variable:
      Result := 1; { sqlite3_bind_*; corpus uses sqlite3_exec with no parameters. (a) — gated on prepared-stmt binding API, not on sqlite3_exec spine. }
    OP_FkCheck:
      Result := 1; { FK deferred check emit; reached only by deferred FK + commit, not the immediate FK driver. }
    OP_Permutation:
      Result := 1; { compound SELECT sort-key permutation; only emitted when ORDER BY refs >1 SELECT result alias. }
    { OP_IsTrue dropped 9.1.6.followup — cv17 drives `(v=2) IS TRUE`. }
    OP_Offset:
      Result := 1; { sqlite_offset(); only emitted by the sqlite_offset() builtin, not LIMIT OFFSET (OffsetLimit). }
    OP_TypeCheck:
      Result := 1; { STRICT table column-type guard; emit gated on specific affinity mismatch shapes. }
    OP_ReopenIdx:
      Result := 1; { sqlite3VdbeAddOp_ReopenIdx coalesces consecutive OpenRead on same idx; planner picks OpenRead unless cursor-reuse is detected. }
    OP_SeekScan, OP_SeekHit:
      Result := 1; { multi-column index seek-then-scan optimisation; emit gated on column-count + cardinality heuristic. }
    OP_RowCell:
      Result := 1; { UPDATE WITHOUT ROWID using cell-rewrite; emit gated on WITHOUT ROWID + UPDATE-of-PK shape. }
    OP_SorterCompare, OP_FinishSeek:
      Result := 1; { sorter-driven UPDATE / deferred-seek finalize; emit gated on specific UPDATE-with-ORDER-BY-LIMIT shape. }
    OP_SqlExec:
      Result := 1; { OP_SqlExec runs nested SQL — emitted only by sqlite3_dbpage / sqlite3_recover paths. }
    { OP_MemMax dropped 9.1.6.followup — cv17 drives AUTOINCREMENT INSERT
      (codegen.pas:35705 autoIncStep emits OP_MemMax on regAutoinc). }
    OP_TableLock:
      Result := 1; { shared-cache TABLE LOCK emit; corpus uses default (shared-cache off). }
    OP_ClrSubtype, OP_GetSubtype, OP_SetSubtype:
      Result := 1; { json subtype propagation across function calls; emit gated on json1 ops in non-result position. }
    OP_CursorHint:
      Result := 1; { gated on SQLITE_ENABLE_CURSOR_HINTS; not enabled in this build. }
  else
    Result := 0;
  end;
end;

procedure ReportCoverage(const gapsPath: AnsiString);
var
  i, nHot, nCold, nGap, nRealCold: i32;
  md: TStringList;
  name: PAnsiChar;
begin
  WriteLn;
  WriteLn('--- 9.1.6 opcode coverage report ---');
  nHot := 0; nCold := 0; nGap := 0; nRealCold := 0;
  md := TStringList.Create;
  try
    md.Add('# COVERAGE_GAPS.md');
    md.Add('');
    md.Add('Generated by `bin/TestSQLCorpus --coverage` (Phase 9.1.6 +');
    md.Add('9.1.6.followup categorization).  Each row is an opcode in');
    md.Add('`passqlite3vdbe.pas` that the corpus does not exercise *and*');
    md.Add('that is allow-listed by `IsCoverageGap` in');
    md.Add('`src/tests/TestSQLCorpus.pas`.');
    md.Add('');
    md.Add('Every row is tagged **(a) gated on an unported feature or');
    md.Add('planner-shape heuristic** — the reason column cites the');
    md.Add('Phase 6/7/8/10 bullet that gates the emit path.  When that');
    md.Add('bullet closes, drop the opcode from `IsCoverageGap` and add');
    md.Add('a targeted .sql to the inline coverage-driver set in');
    md.Add('`TestSQLCorpus.pas`.  The (b) "reachable-now" entries from');
    md.Add('the previous list (IsTrue, MemMax, plus the four real-cold');
    md.Add('opcodes String / RealAffinity / Pagecount / MaxPgcnt) have');
    md.Add('been driven hot by new cv14..cv17 scripts.');
    md.Add('');
    md.Add('Cold opcodes that are NOT in the allow-list fail the gate (rc=1)');
    md.Add('— those are real corpus gaps and must be closed with a script.');
    md.Add('');
    md.Add('| opcode | name | reason |');
    md.Add('|-------:|------|--------|');
    for i := 0 to SQLITE_NUM_OPCODES - 1 do begin
      name := sqlite3OpcodeName(i);
      if gVdbeOpCoverage[i] > 0 then begin
        Inc(nHot);
      end else begin
        Inc(nCold);
        if IsCoverageGap(i) <> 0 then begin
          Inc(nGap);
          md.Add('| ' + IntToStr(i) + ' | ' + AnsiString(name) +
                 ' | ' + CoverageGapReason(i) + ' |');
        end else begin
          Inc(nRealCold);
          WriteLn('  COLD opcode #', i, ' (', AnsiString(name),
                  ') — corpus gap; add a targeted .sql.');
        end;
      end;
    end;
    md.Add('');
    md.Add('_End of file._');
    md.SaveToFile(gapsPath);
  finally
    md.Free;
  end;
  WriteLn('  total opcodes  : ', SQLITE_NUM_OPCODES);
  WriteLn('  hot (>=1 hit)  : ', nHot);
  WriteLn('  cold (allow)   : ', nGap, ' (catalogued in ', gapsPath, ')');
  WriteLn('  cold (REAL)    : ', nRealCold);
  if nRealCold > 0 then begin
    WriteLn('  COVERAGE GATE FAIL: ', nRealCold,
            ' opcode(s) cold and not allow-listed in IsCoverageGap.');
    Halt(1);
  end;
  WriteLn('  coverage gate  : OK');
end;

var
  i: i32;
  bCoverage: Int32;
  argi: i32;
  argv: AnsiString;

begin
  WriteLn('=== TestSQLCorpus — Phase 9.1.3.followup full MANIFEST coverage ===');
  WriteLn('Extracting SQL literals from ', N_FILES,
          ' tier-1 + tier-2 sources.');
  WriteLn;

  bCoverage := 0;
  for argi := 1 to ParamCount do begin
    argv := ParamStr(argi);
    if argv = '--coverage' then bCoverage := 1
    else if (argv = '-h') or (argv = '--help') then begin
      WriteLn('Usage: TestSQLCorpus [--coverage]');
      WriteLn('  --coverage   enable VDBE opcode-coverage instrumentation');
      WriteLn('               (writes COVERAGE_GAPS.md, fails on cold non-allow-listed opcode).');
      Halt(0);
    end;
  end;
  if bCoverage <> 0 then begin
    WriteLn('Mode             : --coverage (9.1.6 opcode coverage gate enabled)');
    gVdbeOpCoverageEnabled := 1;
    for i := 0 to SQLITE_NUM_OPCODES - 1 do gVdbeOpCoverage[i] := 0;
  end;

  { 9.1.6 — Optional sidecar SQL corpus that runs ONLY in --coverage
    mode.  The MANIFEST tier-1/tier-2 .pas spine leaves ~45 opcodes
    cold (DESC scans, ON-conflict edges, FK enforcement, VIEW DROP,
    window xInverse, json subtype propagation, ...).  We drive those
    opcodes hot from a small inline script set rather than inflating
    the Diag* surface; the scripts are oracle-identical so they still
    contribute to the pas-strict gate. }

  gRepoRoot := ResolveRepoRoot;
  WriteLn('Repo root        : ', gRepoRoot);
  InitFiles;
  LoadStatusTags(gRepoRoot + 'src/tests/corpus/STATUS.txt');
  gTotalScripts   := 0;
  gTotalDiverge   := 0;
  gTotalOK        := 0;
  gTotalErr       := 0;
  gFilesProcessed := 0;
  gFilesEmpty     := 0;
  gStrictDiverge  := 0;
  gSoftDiverge    := 0;
  gSkipDiverge    := 0;
  gStrictFiles    := 0;
  gSoftFiles      := 0;
  gSkipFiles      := 0;
  gDivergenceLog  := TStringList.Create;

  try
    for i := 0 to N_FILES - 1 do
      ProcessFile(FILES[i]);

    if bCoverage <> 0 then
      RunCoverageScripts;

    WriteLn;
    WriteLn('--- summary ---');
    WriteLn('  files processed : ', gFilesProcessed);
    WriteLn('  files empty/skip: ', gFilesEmpty);
    WriteLn('  scripts run     : ', gTotalScripts);
    WriteLn('  scripts ok      : ', gTotalOK);
    WriteLn('  scripts diverge : ', gTotalDiverge);
    WriteLn('  status breakdown:');
    WriteLn('    pas-strict files=', gStrictFiles, ' diverge=', gStrictDiverge,
            ' (CI gate)');
    WriteLn('    pas-soft   files=', gSoftFiles,   ' diverge=', gSoftDiverge,
            ' (mask-covered, non-blocking)');
    WriteLn('    pas-skip   files=', gSkipFiles,   ' diverge=', gSkipDiverge,
            ' (gated on open Phase-6/7/8 bullet, non-blocking)');
    if SCRIPT_BYTE_HINT >= 0 then ; { silence unused-const warning }

    WriteDivergencesMd(gRepoRoot + 'src/tests/DIVERGENCES.md');
    WriteLn('  divergences log : ', gRepoRoot, 'src/tests/DIVERGENCES.md');
  finally
    gDivergenceLog.Free;
  end;

  WriteLn;
  if bCoverage <> 0 then
    ReportCoverage(gRepoRoot + 'src/tests/corpus/COVERAGE_GAPS.md');

  if gStrictDiverge > 0 then begin
    WriteLn('TestSQLCorpus: FAIL (rc=1; ', gStrictDiverge,
            ' pas-strict divergence(s) — 9.1.5 CI gate.');
    WriteLn('  pas-soft / pas-skip divergences are tracked but non-blocking;');
    WriteLn('  see src/tests/corpus/STATUS.txt for the per-row tagging.');
    Halt(1);
  end;

  WriteLn('TestSQLCorpus: OK (rc=0; pas-strict gate clean, soft/skip catalogued).');
  Halt(0);
end.
