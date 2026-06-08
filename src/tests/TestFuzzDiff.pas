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
  TestFuzzDiff.pas — Phase 9.3.1 in-process differential fuzz harness.

  One-shot CLI:
      bin/TestFuzzDiff <input.dbsqlfuzz>

  Reads a single dbsqlfuzz-format input (see upstream
  ../sqlite3/test/fuzzcheck.c — decodeDatabase + runCombinedDbSqlInput),
  runs it through BOTH the C oracle (libsqlite3.so) and the Pascal port
  (passqlite3main), and byte-compares all four output channels:

      stdout, stderr, rc, db-blob

  The db-blob channel is masked through ApplyHeaderMask (Phase 9.1.4 — see
  CorpusOracle.pas) so the non-deterministic header bytes (file change
  counter, version-valid-for, version number) do not produce noise.

  Exit codes:
      0  byte-identical output across both oracles on every channel
      1  CLI usage error or input I/O failure
      2  divergence detected (channel listed on stderr)
      3  malformed dbsqlfuzz frame

  dbsqlfuzz frame layout (../sqlite3/test/fuzzcheck.c:772..851 —
  decodeDatabase):

    * Input is *text*, not raw binary.  Hex digits 0..9 a..f A..F are
      paired into successive output bytes; non-hex / non-bracket / non-
      newline-marker characters are silently skipped.
    * '[NNNN]' (or '[+NNNN]') sets the half-byte output cursor to 2*N —
      this is the offset-jump that lets seeds skip blocks of zeros.
    * A literal '\n--\n' (LF, '-', '-', LF) terminates the db section.
      Everything after the '\n--\n' is the SQL script tail, copied
      verbatim (no hex decoding) into the SQL buffer.
    * If the '\n--\n' marker never appears the db section is the whole
      input and the SQL tail is empty — this is rare in seed corpora
      but legal.

  The harness does NOT use sqlite3_deserialize (the upstream fuzzcheck
  path) because the existing CorpusOracle.pas plumbing operates on an
  on-disk DB at <workdir>/test.db.  We write the decoded db blob to
  that path before running the SQL script — equivalent for our purposes
  because both oracles open the same file from the same workdir.  See
  CorpusOracle.pas header comment.
}
program TestFuzzDiff;

uses
  SysUtils, Classes,
  passqlite3types,
  CorpusOracle;

const
  WORKDIR_C   = '/tmp/pas-sqlite3-fuzzdiff-c';
  WORKDIR_PAS = '/tmp/pas-sqlite3-fuzzdiff-pas';
  { ../sqlite3/test/fuzzcheck.c:36 — MX_FILE_SZ = 524288000.  We cap a
    bit lower here just to keep the workdir bounded; oversize inputs
    are out of scope for the one-shot driver. }
  MX_DB_SZ = 64 * 1024 * 1024;

{ ---------------------------------------------------------------------- }
{ Frame parser — direct port of fuzzcheck.c:decodeDatabase + isOffset.    }
{ ---------------------------------------------------------------------- }

{ Grow aDb to newSize bytes, zero-filling the freshly-allocated tail. }
procedure declareTail(var aDb: AnsiString; newSize: i32);
var
  oldLen: i32;
begin
  oldLen := Length(aDb);
  SetLength(aDb, newSize);
  if newSize > oldLen then
    FillChar(aDb[oldLen + 1], newSize - oldLen, 0);
end;

function HexToInt(h: Byte): Byte;
begin
  { ASCII path only — EBCDIC is not a target.  Mirrors fuzzcheck.c:730. }
  Result := (h + 9 * ((h shr 6) and 1)) and $0F;
end;

function IsXDigit(c: Byte): Boolean;
begin
  Result := ((c >= Ord('0')) and (c <= Ord('9'))) or
            ((c >= Ord('a')) and (c <= Ord('f'))) or
            ((c >= Ord('A')) and (c <= Ord('F')));
end;

{ Returns True + advances pi past the closing ']' and writes the new
  half-byte cursor to pk if zIn[ofs..ofs+nIn-1] starts with "[NNNN]". }
function IsOffset(const zIn: AnsiString; ofs, nIn: i32;
                  var pk: u32; var pi: i32): Boolean;
var
  i: i32;
  k: u32;
  c: Byte;
begin
  Result := False;
  k := 0;
  i := 1;
  while i < nIn do begin
    c := Byte(zIn[ofs + i]);
    if c = Ord(']') then Break;
    if not IsXDigit(c) then Exit;
    k := k * 16 + HexToInt(c);
    Inc(i);
  end;
  if i >= nIn then Exit;
  pk := 2 * k;
  pi := pi + i;
  Result := True;
end;

{ Decode the dbsqlfuzz text in zIn into the binary db buffer aDb (out)
  and return the byte offset in zIn where the SQL tail begins.  Returns
  -1 on malformed input.  The db buffer is grown as needed and zero-
  padded out to a 4 KiB boundary, matching upstream's mx rounding. }
function DecodeDatabase(const zIn: AnsiString; out aDb: AnsiString): i32;
var
  n, i, sqlStart: i32;
  k: u32;
  j: u32;
  c: Byte;
  b: Byte;
  mx: i32;
  newSize: i32;
begin
  Result := -1;
  aDb := '';
  n := Length(zIn);
  if n < 4 then Exit;

  { Start with a 4 KiB scratch; grow on demand. }
  SetLength(aDb, 4096);
  FillChar(aDb[1], 4096, 0);
  mx := 0;
  k := 0;
  b := 0;
  i := 1;            { 1-based AnsiString index — corresponds to C i=0 }
  sqlStart := n + 1; { default: no '\n--\n' → empty SQL tail }

  while i <= n do begin
    c := Byte(zIn[i]);
    if IsXDigit(c) then begin
      Inc(k);
      if (k and 1) = 1 then begin
        b := HexToInt(c) * 16;
      end else begin
        b := b + HexToInt(c);
        j := (k div 2) - 1;
        if j >= u32(Length(aDb)) then begin
          if Length(aDb) >= MX_DB_SZ then Exit;
          newSize := Length(aDb) * 2;
          if u32(newSize) <= j then newSize := (i32(j) + 4096) and (not 4095);
          if newSize > MX_DB_SZ then newSize := MX_DB_SZ;
          if u32(newSize) <= j then Exit;
          { Grow + zero only the newly-grown tail (FPC SetLength on
            AnsiString does NOT guarantee tail bytes are zero). }
          declareTail(aDb, newSize);
        end;
        if j >= u32(mx) then begin
          mx := (i32(j) + 4096) and (not 4095);
          if mx > MX_DB_SZ then mx := MX_DB_SZ;
        end;
        PByte(@aDb[1] + j)^ := b;
      end;
      Inc(i);
    end else if (c = Ord('[')) and (i + 3 <= n) and
                IsOffset(zIn, i, n - i + 1, k, i) then begin
      { isOffset advances i past the ']'; also bump past it. }
      Inc(i);
    end else if (c = 10) and (i + 3 <= n) and
                (Byte(zIn[i + 1]) = Ord('-')) and
                (Byte(zIn[i + 2]) = Ord('-')) and
                (Byte(zIn[i + 3]) = 10) then begin
      sqlStart := i + 4;
      i := i + 4;
      Break;
    end else begin
      Inc(i);
    end;
  end;

  { Truncate to the page-aligned 'mx' size used by upstream. }
  SetLength(aDb, mx);
  Result := sqlStart;
end;

{ ---------------------------------------------------------------------- }
{ Workdir + file I/O                                                      }
{ ---------------------------------------------------------------------- }

procedure EnsureCleanDir(const dir: AnsiString);
var
  sr: TSearchRec;
  full: AnsiString;
begin
  if not DirectoryExists(dir) then begin
    ForceDirectories(dir);
    Exit;
  end;
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*', faAnyFile, sr) = 0 then begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      full := IncludeTrailingPathDelimiter(dir) + sr.Name;
      if (sr.Attr and faDirectory) = 0 then DeleteFile(full);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

procedure WriteDbBlob(const dir: AnsiString; const blob: AnsiString);
var
  st: TFileStream;
  path: AnsiString;
begin
  EnsureCleanDir(dir);
  path := IncludeTrailingPathDelimiter(dir) + 'test.db';
  st := TFileStream.Create(path, fmCreate);
  try
    if Length(blob) > 0 then st.WriteBuffer(blob[1], Length(blob));
  finally
    st.Free;
  end;
end;

function ReadInput(const path: AnsiString): AnsiString;
var
  st: TFileStream;
begin
  Result := '';
  st := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, st.Size);
    if st.Size > 0 then st.ReadBuffer(Result[1], st.Size);
  finally
    st.Free;
  end;
end;

{ ---------------------------------------------------------------------- }
{ Channel compare + diagnostic                                            }
{ ---------------------------------------------------------------------- }

function HexHead(const s: AnsiString; nMax: i32): AnsiString;
var
  i, n: i32;
  c: Byte;
const
  HEX: array[0..15] of AnsiChar = '0123456789abcdef';
begin
  Result := '';
  n := Length(s); if n > nMax then n := nMax;
  for i := 1 to n do begin
    c := Byte(s[i]);
    Result := Result + HEX[c shr 4] + HEX[c and $0F];
  end;
  if Length(s) > nMax then Result := Result + '...';
end;

function CompareChannel(const name, cBuf, pBuf: AnsiString): Boolean;
begin
  Result := cBuf = pBuf;
  if not Result then begin
    Writeln(StdErr, 'DIVERGE channel=', name,
      ' c_len=', Length(cBuf), ' pas_len=', Length(pBuf));
    Writeln(StdErr, '  c   = ', HexHead(cBuf, 64));
    Writeln(StdErr, '  pas = ', HexHead(pBuf, 64));
  end;
end;

{ ---------------------------------------------------------------------- }
{ Oracle driver — seed the workdir's test.db then run the SQL tail.       }
{                                                                          }
{ Re-uses CorpusOracle.RunCOracle / RunPasOracle.  Those helpers wipe     }
{ the workdir at entry, so we have to plant the seed db AFTER the call's }
{ implicit wipe — i.e. by writing it BEFORE invoking RunXOracle would    }
{ wipe it.  Workaround: write the seed inside this proc, then arrange    }
{ for the oracle helper to *not* re-wipe.  CorpusOracle does always      }
{ wipe; rather than refactor it, we simply pre-seed and accept that the  }
{ first connection sees an empty DB (the test.db file the oracle opens   }
{ is freshly created).  For non-empty seed DBs we override below by      }
{ planting test.db immediately before each oracle call AND patching the  }
{ oracle helpers... but that requires CorpusOracle changes outside the   }
{ scope of 9.3.1.  Instead: write the seed AFTER the wipe by inlining    }
{ a thin variant of RunXOracle here that skips the wipe.                 }
{                                                                          }
{ NOTE: to honour the "reuse CorpusOracle.pas plumbing" requirement      }
{ we keep the empty-seed common path on the helpers; for non-empty       }
{ db prefixes we extend CorpusOracle in this same commit with a new      }
{ entry point that takes a pre-seeded test.db (RunCOracleSeeded /        }
{ RunPasOracleSeeded — see CorpusOracle.pas).                            }
{ ---------------------------------------------------------------------- }

procedure RunBoth(const sql, dbBlob: AnsiString;
                  out cOut, cErr, pOut, pErr: AnsiString;
                  out cRc, pRc: i32;
                  out cDb, pDb: AnsiString);
begin
  { Pre-seed the C workdir and run via the CorpusOracle helper.  The
    helper wipes the workdir first, so we plant test.db inside the
    helper-extension entry point that bypasses the wipe.  Both helpers
    end with reading test.db back into outDbBlob, which is what we
    want. }
  WriteDbBlob(WORKDIR_C, dbBlob);
  RunCOracleSeeded(PAnsiChar(sql), PAnsiChar(AnsiString(WORKDIR_C)),
                   cOut, cErr, cRc, cDb);

  WriteDbBlob(WORKDIR_PAS, dbBlob);
  RunPasOracleSeeded(PAnsiChar(sql), PAnsiChar(AnsiString(WORKDIR_PAS)),
                     pOut, pErr, pRc, pDb);

  ApplyHeaderMask(cDb);
  ApplyHeaderMask(pDb);
end;

{ ---------------------------------------------------------------------- }
{ main                                                                    }
{ ---------------------------------------------------------------------- }

var
  inputPath, raw, sql, dbBlob: AnsiString;
  cOut, cErr, pOut, pErr, cDb, pDb: AnsiString;
  cRc, pRc: i32;
  sqlStart: i32;
  ok: Boolean;

begin
  { No-argument invocation is a graceful SKIP (rc=0), not a failure.  The
    regression gate (src/tests/run_regression.sh) auto-discovers every
    bin/Test* and runs it with NO arguments; like the other corpus drivers
    (TestSQLCorpus, TestShellScanstatsVm2) this harness has no built-in
    workload, so with no input there is simply nothing to diff.  It still
    does the full differential run when an input file IS supplied. }
  if ParamCount = 0 then begin
    Writeln('SKIP    TestFuzzDiff: no <input.dbsqlfuzz> given (nothing to diff)');
    Halt(0);
  end;
  if ParamCount <> 1 then begin
    Writeln(StdErr, 'usage: TestFuzzDiff <input.dbsqlfuzz>');
    Halt(1);
  end;
  inputPath := ParamStr(1);
  if not FileExists(inputPath) then begin
    Writeln(StdErr, 'TestFuzzDiff: input not found: ', inputPath);
    Halt(1);
  end;

  try
    raw := ReadInput(inputPath);
  except
    on E: Exception do begin
      Writeln(StdErr, 'TestFuzzDiff: read failed: ', E.Message);
      Halt(1);
    end;
  end;

  sqlStart := DecodeDatabase(raw, dbBlob);
  if sqlStart < 0 then begin
    Writeln(StdErr, 'TestFuzzDiff: malformed dbsqlfuzz frame');
    Halt(3);
  end;
  if sqlStart > Length(raw) then
    sql := ''
  else
    sql := Copy(raw, sqlStart, Length(raw) - sqlStart + 1);

  Writeln('TestFuzzDiff: input=', inputPath,
          ' db_bytes=', Length(dbBlob),
          ' sql_bytes=', Length(sql));

  RunBoth(sql, dbBlob, cOut, cErr, pOut, pErr, cRc, pRc, cDb, pDb);

  ok := True;
  if not CompareChannel('stdout', cOut, pOut) then ok := False;
  if not CompareChannel('stderr', cErr, pErr) then ok := False;
  if cRc <> pRc then begin
    Writeln(StdErr, 'DIVERGE channel=rc c=', cRc, ' pas=', pRc);
    ok := False;
  end;
  if not CompareChannel('db-blob', cDb, pDb) then ok := False;

  if ok then begin
    Writeln('TestFuzzDiff: PASS (all 4 channels byte-identical)');
    Halt(0);
  end else begin
    Writeln(StdErr, 'TestFuzzDiff: FAIL');
    Halt(2);
  end;
end.
