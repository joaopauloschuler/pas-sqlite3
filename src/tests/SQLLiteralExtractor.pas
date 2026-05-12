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
  SQLLiteralExtractor.pas — Phase 9.1.3.followup helper.

  Pulls embedded SQL string literals out of the existing Diag*/Test*
  test sources so TestSQLCorpus can iterate the full MANIFEST corpus
  without copying SQL into a parallel asset tree.

  Strategy (minimal, regex-free, intentionally heuristic):

    1.  Walk the .pas source character-by-character, ignoring Pascal
        comments ({ ... }, (* ... *), //... to EOL) and Pascal single-
        quoted string literals when *outside* a call we care about.

    2.  When the identifier `Add` or `Probe` is seen followed by `(`,
        enter "call" mode and track paren depth.  Inside the call,
        single-quoted strings are collected in order; the first one is
        treated as the human label and dropped, the rest are emitted
        if they look like SQL (start with one of a fixed keyword list
        after leading whitespace).

    3.  Doubled single-quotes inside a literal are folded to a single
        quote (Pascal escape convention).

  This is intentionally narrow: it catches `Add(i, 'lbl', 'SQL')` (the
  TestExplainParity / TestWhereCorpus / TestBytecodeParity / TestParser
  spine pattern) and `Probe('lbl', ..., 'SQL')` (the Diag* feature-corner
  pattern) — which together account for all tier-1/tier-2 corpora the
  MANIFEST flags.  Setup/witness arguments that happen to be SQL are
  picked up too (filter: SQL-keyword prefix), which gives extra DDL
  coverage essentially for free.
}
unit SQLLiteralExtractor;

interface

uses
  SysUtils, Classes, passqlite3types;

{ Append every detected SQL literal in zPath to outList.
  Returns the number of literals appended.  The caller owns outList. }
function ExtractSQLLiterals(const zPath: AnsiString;
                            outList: TStringList): i32;

implementation

{ ----------------------------------------------------------------------
  Small lookup: does the trimmed string start with a SQL keyword?
  Case-insensitive, must be followed by whitespace or end-of-string so
  that  'CREATEXYZ' doesn't masquerade as a CREATE.
  ---------------------------------------------------------------------- }

const
  KW_LIST: array[0..21] of AnsiString = (
    'SELECT','INSERT','UPDATE','DELETE','CREATE','DROP','ALTER',
    'PRAGMA','BEGIN','COMMIT','ROLLBACK','SAVEPOINT','RELEASE',
    'WITH','VACUUM','ANALYZE','REINDEX','ATTACH','DETACH','EXPLAIN',
    'REPLACE','VALUES');

function StartsWithSQL(const s: AnsiString): i32;
var
  i, j, n, klen: i32;
  trimmed, head: AnsiString;
  ch: AnsiChar;
begin
  Result := 0;
  trimmed := s;
  { strip leading whitespace }
  i := 1;
  while (i <= Length(trimmed)) and
        ((trimmed[i] = ' ') or (trimmed[i] = #9) or
         (trimmed[i] = #10) or (trimmed[i] = #13)) do
    Inc(i);
  if i > Length(trimmed) then Exit;
  for j := 0 to High(KW_LIST) do begin
    klen := Length(KW_LIST[j]);
    if (Length(trimmed) - i + 1) < klen then Continue;
    head := Copy(trimmed, i, klen);
    if UpperCase(head) = KW_LIST[j] then begin
      if (i + klen - 1) = Length(trimmed) then begin
        Result := 1; Exit;
      end;
      ch := trimmed[i + klen];
      n := Ord(ch);
      if (ch = ' ') or (n = 9) or (n = 10) or (n = 13) or
         (ch = ';') or (ch = '(') then begin
        Result := 1; Exit;
      end;
    end;
  end;
end;

{ ----------------------------------------------------------------------
  Read a whole file into an AnsiString.
  ---------------------------------------------------------------------- }

function SlurpFile(const path: AnsiString): AnsiString;
var
  st: TFileStream;
begin
  Result := '';
  if not FileExists(path) then Exit;
  st := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, st.Size);
    if st.Size > 0 then st.ReadBuffer(Result[1], st.Size);
  finally
    st.Free;
  end;
end;

{ ----------------------------------------------------------------------
  Parse a Pascal single-quoted string literal starting at src[pos] = '''.
  On return pos points one past the closing quote.  Doubled '' folds to
  a single quote in the result.
  ---------------------------------------------------------------------- }

function ParsePasString(const src: AnsiString; var pos: i32): AnsiString;
var
  n: i32;
begin
  Result := '';
  n := Length(src);
  Inc(pos); { skip opening quote }
  while pos <= n do begin
    if src[pos] = '''' then begin
      if (pos < n) and (src[pos + 1] = '''') then begin
        Result := Result + '''';
        Inc(pos, 2);
      end else begin
        Inc(pos); { skip closing quote }
        Exit;
      end;
    end else begin
      Result := Result + src[pos];
      Inc(pos);
    end;
  end;
end;

{ ----------------------------------------------------------------------
  Skip a Pascal comment that has just been entered.  kind:
     0 = `{ ... }`
     1 = `(* ... *)`
     2 = `// ...` to end-of-line
  pos enters pointing at the first char after the comment opener; on
  return it points one past the closer (or at end of buffer).
  ---------------------------------------------------------------------- }

procedure SkipPasComment(const src: AnsiString; var pos: i32; kind: i32);
var
  n: i32;
begin
  n := Length(src);
  case kind of
    0: while pos <= n do begin
         if src[pos] = '}' then begin Inc(pos); Exit; end;
         Inc(pos);
       end;
    1: while pos < n do begin
         if (src[pos] = '*') and (src[pos + 1] = ')') then begin
           Inc(pos, 2); Exit;
         end;
         Inc(pos);
       end;
    2: while pos <= n do begin
         if (src[pos] = #10) or (src[pos] = #13) then Exit;
         Inc(pos);
       end;
  end;
end;

{ ----------------------------------------------------------------------
  Identifier match: is src[pos..] the identifier id, followed by a
  non-identifier char?  Identifier match is case-insensitive (FPC
  identifiers are case-insensitive).
  ---------------------------------------------------------------------- }

function IsIdChar(c: AnsiChar): i32;
begin
  if ((c >= 'A') and (c <= 'Z')) or
     ((c >= 'a') and (c <= 'z')) or
     ((c >= '0') and (c <= '9')) or
     (c = '_') then
    Result := 1
  else
    Result := 0;
end;

function MatchIdent(const src: AnsiString; pos: i32; const id: AnsiString): i32;
var
  n, k: i32;
begin
  Result := 0;
  n := Length(src);
  k := Length(id);
  if (pos + k - 1) > n then Exit;
  if UpperCase(Copy(src, pos, k)) <> UpperCase(id) then Exit;
  { previous char must not be identifier }
  if (pos > 1) and (IsIdChar(src[pos - 1]) = 1) then Exit;
  { next char must not be identifier }
  if (pos + k <= n) and (IsIdChar(src[pos + k]) = 1) then Exit;
  Result := 1;
end;

{ ----------------------------------------------------------------------
  Main extractor.
  ---------------------------------------------------------------------- }

function ExtractSQLLiterals(const zPath: AnsiString;
                            outList: TStringList): i32;
var
  src: AnsiString;
  pos, n, depth, stringsInCall, added: i32;
  c, c2: AnsiChar;
  lit, scriptBuf: AnsiString;
  inCall, hasLabel: i32;

  procedure FlushCall;
  var trimmed: AnsiString; k: i32;
  begin
    trimmed := scriptBuf;
    k := Length(trimmed);
    while (k > 0) and ((trimmed[k] = ' ') or (trimmed[k] = #9) or
                       (trimmed[k] = #10) or (trimmed[k] = #13)) do
      Dec(k);
    if k > 0 then begin
      SetLength(trimmed, k);
      outList.Add(trimmed);
      Inc(added);
    end;
    scriptBuf := '';
  end;

begin
  added := 0;
  src := SlurpFile(zPath);
  n := Length(src);
  pos := 1;
  depth := 0;
  inCall := 0;
  stringsInCall := 0;
  scriptBuf := '';
  hasLabel := 0;

  while pos <= n do begin
    c := src[pos];

    { Comments first — they can hide pseudo-string content. }
    if c = '{' then begin
      Inc(pos);
      SkipPasComment(src, pos, 0);
      Continue;
    end;
    if (c = '(') and (pos < n) and (src[pos + 1] = '*') then begin
      Inc(pos, 2);
      SkipPasComment(src, pos, 1);
      Continue;
    end;
    if (c = '/') and (pos < n) and (src[pos + 1] = '/') then begin
      Inc(pos, 2);
      SkipPasComment(src, pos, 2);
      Continue;
    end;

    { Single-quoted Pascal string. }
    if c = '''' then begin
      lit := ParsePasString(src, pos);
      if inCall = 1 then begin
        Inc(stringsInCall);
        { Skip the leading label string ONLY for Add/Probe — those calls
          always start with a label.  For label-less anchors (Run*/Check/
          TestExpr/ProbeOne/Case) every string is a candidate. }
        if (hasLabel = 0) or (stringsInCall > 1) then begin
          if (Length(lit) > 0) and (StartsWithSQL(lit) = 1) then begin
            while (Length(lit) > 0) and (lit[Length(lit)] = ';') do
              SetLength(lit, Length(lit) - 1);
            if Length(scriptBuf) > 0 then
              scriptBuf := scriptBuf + '; ';
            scriptBuf := scriptBuf + lit;
          end;
        end;
      end;
      Continue;
    end;

    { Paren depth tracking. }
    if c = '(' then begin
      Inc(depth);
      Inc(pos);
      Continue;
    end;
    if c = ')' then begin
      if depth > 0 then Dec(depth);
      if (inCall = 1) and (depth = 0) then begin
        FlushCall;
        inCall := 0;
        stringsInCall := 0;
      end;
      Inc(pos);
      Continue;
    end;

    { Identifier — only check for our two anchors when at depth 0 and
      not already inside a call.  This avoids re-triggering on nested
      Probe (none exist in practice, but safe). }
    if (IsIdChar(c) = 1) and (inCall = 0) then begin
      hasLabel := 0;
      if MatchIdent(src, pos, 'Add') = 1 then begin
        Inc(pos, 3); hasLabel := 1;
      end else if MatchIdent(src, pos, 'Probe') = 1 then begin
        Inc(pos, 5); hasLabel := 1;
      end else if MatchIdent(src, pos, 'ProbeOne') = 1 then
        Inc(pos, 8)
      else if MatchIdent(src, pos, 'RunPas') = 1 then
        Inc(pos, 6)
      else if MatchIdent(src, pos, 'RunC') = 1 then
        Inc(pos, 4)
      else if MatchIdent(src, pos, 'RunSql') = 1 then
        Inc(pos, 6)
      else if MatchIdent(src, pos, 'RunDdl') = 1 then
        Inc(pos, 6)
      else if MatchIdent(src, pos, 'RunOne') = 1 then
        Inc(pos, 6)
      else if MatchIdent(src, pos, 'RunStep') = 1 then
        Inc(pos, 7)
      else if MatchIdent(src, pos, 'Check') = 1 then
        Inc(pos, 5)
      else if MatchIdent(src, pos, 'TestExpr') = 1 then
        Inc(pos, 8)
      else if MatchIdent(src, pos, 'Case') = 1 then
        Inc(pos, 4)
      else if MatchIdent(src, pos, 'Diff') = 1 then
        Inc(pos, 4)
      else begin
        while (pos <= n) and (IsIdChar(src[pos]) = 1) do Inc(pos);
        Continue;
      end;
      { skip whitespace then look for '(' }
      while (pos <= n) and ((src[pos] = ' ') or (src[pos] = #9) or
                            (src[pos] = #10) or (src[pos] = #13)) do
        Inc(pos);
      if (pos <= n) and (src[pos] = '(') then begin
        inCall := 1;
        stringsInCall := 0;
        Inc(depth);
        Inc(pos);
      end;
      Continue;
    end;

    Inc(pos);
    { Suppress unused-var warning on c2. }
    if False then c2 := c;
  end;

  Result := added;
end;

end.
