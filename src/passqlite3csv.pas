{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/csv.c (977 lines in C).

  Implements the `csv` virtual table: reads RFC-4180 CSV either from a
  file (`filename=NAME`) or from an inline string (`data=TEXT`).  Schema
  is auto-detected from the first row when neither `schema=` nor
  `columns=` is supplied; with `header=YES` the first row provides
  column names.

  Public entry: sqlite3CsvInit(db) — equivalent to sqlite3_csv_init() in
  the C extension.
}
{$I passqlite3.inc}
unit passqlite3csv;

interface

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3CsvInit(db: PTsqlite3): i32;

implementation

{ -------- libc FILE I/O bindings -------------------------------------- }

const
  CSV_INBUFSZ  = 1024;
  CSV_MXERR    = 200;
  CSV_EOF      = -1;
  SEEK_SET     = 0;

type
  PFILE = Pointer;

function csvFopen(path, mode: PAnsiChar): PFILE; cdecl;
  external 'c' name 'fopen';
function csvFclose(stream: PFILE): i32; cdecl;
  external 'c' name 'fclose';
function csvFread(buf: Pointer; sz, n: NativeUInt; stream: PFILE): NativeUInt; cdecl;
  external 'c' name 'fread';
function csvFseek(stream: PFILE; offset: NativeInt; whence: i32): i32; cdecl;
  external 'c' name 'fseek';
function csvFtell(stream: PFILE): NativeInt; cdecl;
  external 'c' name 'ftell';

{ -------- CsvReader --------------------------------------------------- }

type
  PCsvReader = ^TCsvReader;
  TCsvReader = record
    inF       : PFILE;            { csv.c:79 — input stream }
    z         : PAnsiChar;        { csv.c:80 — accumulated field text }
    n         : i64;              { csv.c:81 }
    nAlloc    : i64;              { csv.c:82 }
    nLine     : i64;              { csv.c:83 }
    bNotFirst : i32;              { csv.c:84 }
    cTerm     : i32;              { csv.c:85 — char that terminated last field, or EOF }
    iIn       : NativeUInt;       { csv.c:86 }
    nIn       : NativeUInt;       { csv.c:87 }
    zIn       : PAnsiChar;        { csv.c:88 }
    zErr      : array[0..CSV_MXERR-1] of AnsiChar; { csv.c:89 }
  end;

procedure csvReaderInit(p: PCsvReader);
begin
  FillChar(p^, SizeOf(TCsvReader), 0);
end;

procedure csvReaderReset(p: PCsvReader);
begin
  if p^.inF <> nil then begin
    csvFclose(p^.inF);
    sqlite3_free(p^.zIn);
  end;
  sqlite3_free(p^.z);
  csvReaderInit(p);
end;

{ csv.c:116 — csv_errmsg.  Format and store in p^.zErr (max CSV_MXERR-1
  bytes).  Uses Pascal's SysUtils.Format because sqlite3_vsnprintf has
  no varargs Pascal entry; semantics differ slightly but the messages
  are diagnostic only. }
procedure csvErrmsg(p: PCsvReader; const msg: AnsiString);
var n: i32;
begin
  n := Length(msg);
  if n >= CSV_MXERR then n := CSV_MXERR - 1;
  if n > 0 then Move(msg[1], p^.zErr[0], n);
  p^.zErr[n] := #0;
end;

{ csv.c:126 — csv_reader_open. }
function csvReaderOpen(p: PCsvReader; zFilename, zData: PAnsiChar): i32;
begin
  if zFilename <> nil then begin
    p^.zIn := PAnsiChar(sqlite3_malloc64(CSV_INBUFSZ));
    if p^.zIn = nil then begin
      csvErrmsg(p, 'out of memory');
      Result := 1; Exit;
    end;
    p^.inF := csvFopen(zFilename, 'rb');
    if p^.inF = nil then begin
      sqlite3_free(p^.zIn);
      p^.zIn := nil;
      csvReaderReset(p);
      csvErrmsg(p, AnsiString('cannot open ''') + zFilename + ''' for reading');
      Result := 1; Exit;
    end;
  end else begin
    { zData is an external buffer owned by the caller — do not free. }
    p^.zIn := zData;
    if zData <> nil then p^.nIn := StrLen(zData) else p^.nIn := 0;
  end;
  Result := 0;
end;

{ csv.c:155 — csv_getc_refill. }
function csvGetcRefill(p: PCsvReader): i32;
var got: NativeUInt;
begin
  got := csvFread(p^.zIn, 1, CSV_INBUFSZ, p^.inF);
  if got = 0 then begin Result := CSV_EOF; Exit; end;
  p^.nIn := got;
  p^.iIn := 1;
  Result := i32(Byte(p^.zIn[0]));
end;

{ csv.c:169 — csv_getc. }
function csvGetc(p: PCsvReader): i32;
var c: Byte;
begin
  if p^.iIn >= p^.nIn then begin
    if p^.inF <> nil then Result := csvGetcRefill(p)
    else Result := CSV_EOF;
    Exit;
  end;
  c := Byte(p^.zIn[p^.iIn]);
  Inc(p^.iIn);
  Result := i32(c);
end;

{ csv.c:179 — csv_resize_and_append. }
function csvResizeAndAppend(p: PCsvReader; c: AnsiChar): i32;
var
  zNew: PAnsiChar;
  nNew: i64;
begin
  nNew := p^.nAlloc * 2 + 100;
  zNew := PAnsiChar(sqlite3_realloc64(p^.z, u64(nNew)));
  if zNew <> nil then begin
    p^.z := zNew;
    p^.nAlloc := nNew;
    p^.z[p^.n] := c;
    Inc(p^.n);
    Result := 0;
  end else begin
    csvErrmsg(p, 'out of memory');
    Result := 1;
  end;
end;

{ csv.c:196 — csv_append. }
function csvAppend(p: PCsvReader; c: AnsiChar): i32;
begin
  if p^.n >= p^.nAlloc - 1 then begin
    Result := csvResizeAndAppend(p, c);
    Exit;
  end;
  p^.z[p^.n] := c;
  Inc(p^.n);
  Result := 0;
end;

{ csv.c:215 — csv_read_one_field.  Reads one CSV field; stores result
  in p^.z (NUL-terminated, length p^.n).  p^.cTerm holds the
  terminator (',', '\n', or EOF).  Returns p^.z, or nil on EOF/OOM. }
function csvReadOneField(p: PCsvReader): PAnsiChar;
var
  c, pc, ppc: i32;
  startLine: i64;
  done: Boolean;
begin
  p^.n := 0;
  c := csvGetc(p);
  if c = CSV_EOF then begin
    p^.cTerm := CSV_EOF;
    Result := nil; Exit;
  end;
  if c = Ord('"') then begin
    startLine := p^.nLine;
    pc := 0; ppc := 0;
    done := False;
    while not done do begin
      c := csvGetc(p);
      if (c <= Ord('"')) or (pc = Ord('"')) then begin
        if c = Ord(#10) then Inc(p^.nLine);
        if c = Ord('"') then begin
          if pc = Ord('"') then begin
            pc := 0;
            { continue the inner loop without falling into the below
              break / append path }
            continue;
          end;
        end;
        if ((c = Ord(',')) and (pc = Ord('"')))
        or ((c = Ord(#10)) and (pc = Ord('"')))
        or ((c = Ord(#10)) and (pc = Ord(#13)) and (ppc = Ord('"')))
        or ((c = CSV_EOF) and (pc = Ord('"'))) then begin
          { Strip the closing quote.  csv.c:242 — `do{ p->n--; }
            while( p->z[p->n]!='"' );` }
          repeat
            Dec(p^.n);
          until p^.z[p^.n] = '"';
          p^.cTerm := c;
          done := True; continue;
        end;
        if (pc = Ord('"')) and (c <> Ord(#13)) then begin
          csvErrmsg(p, AnsiString('line ') + IntToStr(p^.nLine) +
            ': unescaped " character');
          done := True; continue;
        end;
        if c = CSV_EOF then begin
          csvErrmsg(p, AnsiString('line ') + IntToStr(startLine) +
            ': unterminated "-quoted field' + #10);
          p^.cTerm := c;
          done := True; continue;
        end;
      end;
      if csvAppend(p, AnsiChar(Byte(c))) <> 0 then begin
        Result := nil; Exit;
      end;
      ppc := pc;
      pc  := c;
    end;
  end else begin
    { csv.c:262 — UTF-8 BOM (0xEF BB BF) skip on first field. }
    if ((c and $ff) = $EF) and (p^.bNotFirst = 0) then begin
      csvAppend(p, AnsiChar(Byte(c)));
      c := csvGetc(p);
      if (c and $ff) = $BB then begin
        csvAppend(p, AnsiChar(Byte(c)));
        c := csvGetc(p);
        if (c and $ff) = $BF then begin
          p^.bNotFirst := 1;
          p^.n := 0;
          Result := csvReadOneField(p);
          Exit;
        end;
      end;
    end;
    while (c > Ord(',')) or
          ((c <> CSV_EOF) and (c <> Ord(',')) and (c <> Ord(#10))) do begin
      if csvAppend(p, AnsiChar(Byte(c))) <> 0 then begin
        Result := nil; Exit;
      end;
      c := csvGetc(p);
    end;
    if c = Ord(#10) then begin
      Inc(p^.nLine);
      if (p^.n > 0) and (p^.z[p^.n - 1] = #13) then Dec(p^.n);
    end;
    p^.cTerm := c;
  end;
  if p^.z <> nil then p^.z[p^.n] := #0;
  p^.bNotFirst := 1;
  Result := p^.z;
end;

{ -------- CsvTable / CsvCursor ---------------------------------------- }

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  PCsvTable = ^TCsvTable;
  TCsvTable = record
    base      : Tsqlite3_vtab;       { csv.c:312 — must be first }
    zFilename : PAnsiChar;
    zData     : PAnsiChar;
    iStart    : NativeInt;
    nCol      : i32;
    tstFlags  : u32;
  end;

  PCsvCursor = ^TCsvCursor;
  TCsvCursor = record
    base   : Tsqlite3_vtab_cursor;
    rdr    : TCsvReader;
    azVal  : PPAnsiChar;             { array of nCol PAnsiChar }
    aLen   : Pi64;                   { array of nCol i64 }
    iRowid : i64;
  end;

procedure csvXferError(pTab: PCsvTable; pRdr: PCsvReader);
begin
  sqlite3_free(pTab^.base.zErrMsg);
  pTab^.base.zErrMsg := sqlite3PfMprintf('%s', [PAnsiChar(@pRdr^.zErr[0])]);
end;

{ csv.c:342 — xDisconnect. }
function csvtabDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
var p: PCsvTable;
begin
  p := PCsvTable(pVtab);
  sqlite3_free(p^.zFilename);
  sqlite3_free(p^.zData);
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ csv.c:352 — csv_skip_whitespace. }
function csvSkipWhitespace(z: PAnsiChar): PAnsiChar;
begin
  while (z^ <> #0) and (z^ in [' ', #9, #10, #11, #12, #13]) do Inc(z);
  Result := z;
end;

{ csv.c:358 — csv_trim_whitespace.  Trims trailing whitespace in-place. }
procedure csvTrimWhitespace(z: PAnsiChar);
var n: NativeUInt;
begin
  n := StrLen(z);
  while (n > 0) and (z[n] in [' ', #9, #10, #11, #12, #13, #0]) do begin
    if n = 0 then Break;
    Dec(n);
    if not (z[n+1] in [' ', #9, #10, #11, #12, #13]) then begin
      Inc(n);
      Break;
    end;
  end;
  z[n] := #0;
end;

{ csv.c:365 — csv_dequote.  Strips matching outer ' or " quotes,
  collapses doubled quotes inside. }
procedure csvDequote(z: PAnsiChar);
var
  cQuote: AnsiChar;
  i, j, n: NativeUInt;
begin
  cQuote := z[0];
  if (cQuote <> '''') and (cQuote <> '"') then Exit;
  n := StrLen(z);
  if (n < 2) or (z[n-1] <> z[0]) then Exit;
  i := 1; j := 0;
  while i < n - 1 do begin
    if (z[i] = cQuote) and (z[i+1] = cQuote) then Inc(i);
    z[j] := z[i];
    Inc(j); Inc(i);
  end;
  z[j] := #0;
end;

{ csv.c:384 — csv_parameter.  Looks for "TAG = VALUE" with optional
  whitespace.  Returns pointer to first char of VALUE or nil. }
function csvParameter(zTag: PAnsiChar; nTag: i32; z: PAnsiChar): PAnsiChar;
begin
  z := csvSkipWhitespace(z);
  if StrLComp(zTag, z, nTag) <> 0 then begin Result := nil; Exit; end;
  z := csvSkipWhitespace(z + nTag);
  if z[0] <> '=' then begin Result := nil; Exit; end;
  Result := csvSkipWhitespace(z + 1);
end;

{ csv.c:398 — csv_string_parameter. }
function csvStringParameter(p: PCsvReader; zParam, zArg: PAnsiChar;
  pzVal: PPAnsiChar): i32;
var zValue: PAnsiChar;
begin
  zValue := csvParameter(zParam, StrLen(zParam), zArg);
  if zValue = nil then begin Result := 0; Exit; end;
  p^.zErr[0] := #0;
  if pzVal^ <> nil then begin
    csvErrmsg(p, AnsiString('more than one ''') + zParam + ''' parameter');
    Result := 1; Exit;
  end;
  pzVal^ := sqlite3PfMprintf('%s', [zValue]);
  if pzVal^ = nil then begin
    csvErrmsg(p, 'out of memory');
    Result := 1; Exit;
  end;
  csvTrimWhitespace(pzVal^);
  csvDequote(pzVal^);
  Result := 1;
end;

{ csv.c:426 — csv_boolean.  Returns 0 / 1 / -1. }
function csvBoolean(z: PAnsiChar): i32;
begin
  if (sqlite3_stricmp('yes', z) = 0)
  or (sqlite3_stricmp('on',  z) = 0)
  or (sqlite3_stricmp('true',z) = 0)
  or ((z[0] = '1') and (z[1] = #0)) then begin Result := 1; Exit; end;
  if (sqlite3_stricmp('no',   z) = 0)
  or (sqlite3_stricmp('off',  z) = 0)
  or (sqlite3_stricmp('false',z) = 0)
  or ((z[0] = '0') and (z[1] = #0)) then begin Result := 0; Exit; end;
  Result := -1;
end;

{ csv.c:449 — csv_boolean_parameter.  "TAG" or "TAG=BOOLEAN". }
function csvBooleanParameter(zTag: PAnsiChar; nTag: i32; z: PAnsiChar;
  pValue: Pi32): i32;
var b: i32;
begin
  z := csvSkipWhitespace(z);
  if StrLComp(zTag, z, nTag) <> 0 then begin Result := 0; Exit; end;
  z := csvSkipWhitespace(z + nTag);
  if z[0] = #0 then begin
    pValue^ := 1; Result := 1; Exit;
  end;
  if z[0] <> '=' then begin Result := 0; Exit; end;
  z := csvSkipWhitespace(z + 1);
  b := csvBoolean(z);
  if b >= 0 then begin
    pValue^ := b; Result := 1; Exit;
  end;
  Result := 0;
end;

{ Forward decls. }
function csvtabConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl; forward;

{ csv.c:685 — xCreate.  Same as xConnect for this read-only table. }
function csvtabCreate(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
begin
  Result := csvtabConnect(db, pAux, argc, argv, ppVtab, pzErr);
end;

{ Helper: index into the argv: PPAnsiChar array. }
function csvArg(argv: PPAnsiChar; i: i32): PAnsiChar; inline;
var p: PPAnsiChar;
begin
  p := argv;
  Inc(p, i);
  Result := p^;
end;

{ csv.c:491..666 — csvtabConnect.  Parses arguments, optionally counts
  columns / parses a header, declares the schema. }
function csvtabConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PCsvTable;
  bHeader: i32;
  rc: i32;
  i, j: i32;
  b, nCol, iCol: i32;
  z, zValue: PAnsiChar;
  sRdr: TCsvReader;
  azParam: array[0..2] of PAnsiChar;
  azPValue: array[0..2] of PAnsiChar;
  pStr: PSqlite3Str;
  zSep: PAnsiChar;
  zCsvSchema: PAnsiChar;
  hadError: Boolean;
  zMsg: PAnsiChar;
label
  csvtab_connect_oom, csvtab_connect_error, cleanup;
begin
  pNew := nil;
  bHeader := -1;
  rc := SQLITE_OK;
  nCol := -99;
  hadError := False;
  azParam[0] := 'filename';
  azParam[1] := 'data';
  azParam[2] := 'schema';
  FillChar(azPValue, SizeOf(azPValue), 0);
  csvReaderInit(@sRdr);

  i := 3;
  while i < argc do begin
    z := csvArg(argv, i);
    j := 0;
    while j < 3 do begin
      if csvStringParameter(@sRdr, azParam[j], z, @azPValue[j]) <> 0 then
        Break;
      Inc(j);
    end;
    if j < 3 then begin
      if sRdr.zErr[0] <> #0 then begin
        hadError := True; goto csvtab_connect_error;
      end;
    end else if csvBooleanParameter('header', 6, z, @b) <> 0 then begin
      if bHeader >= 0 then begin
        csvErrmsg(@sRdr, 'more than one ''header'' parameter');
        hadError := True; goto csvtab_connect_error;
      end;
      bHeader := b;
    end else begin
      zValue := csvParameter('columns', 7, z);
      if zValue <> nil then begin
        if nCol > 0 then begin
          csvErrmsg(@sRdr, 'more than one ''columns'' parameter');
          hadError := True; goto csvtab_connect_error;
        end;
        nCol := StrToIntDef(StrPas(zValue), 0);
        if nCol <= 0 then begin
          csvErrmsg(@sRdr, 'column= value must be positive');
          hadError := True; goto csvtab_connect_error;
        end;
      end else begin
        csvErrmsg(@sRdr, AnsiString('bad parameter: ''') + z + '''');
        hadError := True; goto csvtab_connect_error;
      end;
    end;
    Inc(i);
  end;

  if (azPValue[0] = nil) = (azPValue[1] = nil) then begin
    csvErrmsg(@sRdr, 'must specify either filename= or data= but not both');
    hadError := True; goto csvtab_connect_error;
  end;

  if ((nCol <= 0) or (bHeader = 1))
  and (csvReaderOpen(@sRdr, azPValue[0], azPValue[1]) <> 0) then begin
    hadError := True; goto csvtab_connect_error;
  end;

  pNew := PCsvTable(sqlite3_malloc64(SizeOf(TCsvTable)));
  ppVtab^ := PSqlite3Vtab(pNew);
  if pNew = nil then goto csvtab_connect_oom;
  FillChar(pNew^, SizeOf(TCsvTable), 0);

  if azPValue[2] = nil then begin
    pStr := sqlite3_str_new(nil);
    zSep := '';
    iCol := 0;
    sqlite3_str_appendf(pStr, 'CREATE TABLE x(', []);
    if (nCol < 0) and (bHeader < 1) then begin
      nCol := 0;
      repeat
        csvReadOneField(@sRdr);
        Inc(nCol);
      until sRdr.cTerm <> Ord(',');
    end;
    if (nCol > 0) and (bHeader < 1) then begin
      iCol := 0;
      while iCol < nCol do begin
        sqlite3_str_appendf(pStr, '%sc%d TEXT', [zSep, iCol]);
        zSep := ',';
        Inc(iCol);
      end;
    end else begin
      repeat
        z := csvReadOneField(@sRdr);
        if ((nCol > 0) and (iCol < nCol)) or ((nCol < 0) and (bHeader > 0)) then
        begin
          sqlite3_str_appendf(pStr, '%s"%w" TEXT', [zSep, z]);
          zSep := ',';
          Inc(iCol);
        end;
      until sRdr.cTerm <> Ord(',');
      if nCol < 0 then nCol := iCol
      else begin
        while iCol < nCol do begin
          Inc(iCol);
          sqlite3_str_appendf(pStr, '%sc%d TEXT', [zSep, iCol]);
          zSep := ',';
        end;
      end;
    end;
    pNew^.nCol := nCol;
    sqlite3_str_appendf(pStr, ')', []);
    azPValue[2] := sqlite3_str_finish(pStr);
    if azPValue[2] = nil then goto csvtab_connect_oom;
  end else if nCol < 0 then begin
    repeat
      csvReadOneField(@sRdr);
      Inc(pNew^.nCol);
    until sRdr.cTerm <> Ord(',');
  end else begin
    pNew^.nCol := nCol;
  end;

  pNew^.zFilename := azPValue[0]; azPValue[0] := nil;
  pNew^.zData     := azPValue[1]; azPValue[1] := nil;

  if bHeader <> 1 then
    pNew^.iStart := 0
  else if pNew^.zData <> nil then
    pNew^.iStart := NativeInt(sRdr.iIn)
  else
    pNew^.iStart := csvFtell(sRdr.inF) - NativeInt(sRdr.nIn) +
                    NativeInt(sRdr.iIn);

  csvReaderReset(@sRdr);
  zCsvSchema := azPValue[2];
  rc := sqlite3_declare_vtab(db, zCsvSchema);
  if rc <> SQLITE_OK then begin
    csvErrmsg(@sRdr, AnsiString('bad schema: ''') +
      StrPas(zCsvSchema) + ''' - ' + sqlite3_errmsg(db));
    hadError := True; goto csvtab_connect_error;
  end;
  for i := 0 to 2 do sqlite3_free(azPValue[i]);
  sqlite3_vtab_config(db, SQLITE_VTAB_DIRECTONLY, 0);
  Result := SQLITE_OK;
  Exit;

csvtab_connect_oom:
  rc := SQLITE_NOMEM;
  csvErrmsg(@sRdr, 'out of memory');
  hadError := True;

csvtab_connect_error:
cleanup:
  if pNew <> nil then csvtabDisconnect(@pNew^.base);
  for i := 0 to 2 do sqlite3_free(azPValue[i]);
  if sRdr.zErr[0] <> #0 then begin
    sqlite3_free(pzErr^);
    zMsg := PAnsiChar(@sRdr.zErr[0]);
    pzErr^ := sqlite3PfMprintf('%s', [zMsg]);
  end;
  csvReaderReset(@sRdr);
  if rc = SQLITE_OK then rc := SQLITE_ERROR;
  if not hadError and (rc = SQLITE_OK) then ; { quiet "unused" }
  Result := rc;
end;

{ csv.c:671 — csvtabCursorRowReset. }
procedure csvtabCursorRowReset(pCur: PCsvCursor);
var
  pTab: PCsvTable;
  i: i32;
  ppz: PPAnsiChar;
  paLen: Pi64;
begin
  pTab := PCsvTable(pCur^.base.pVtab);
  for i := 0 to pTab^.nCol - 1 do begin
    ppz := pCur^.azVal; Inc(ppz, i);
    sqlite3_free(ppz^);
    ppz^ := nil;
    paLen := pCur^.aLen; Inc(paLen, i);
    paLen^ := 0;
  end;
end;

{ csv.c:698 — xClose. }
function csvtabClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PCsvCursor;
begin
  pCur := PCsvCursor(cur);
  csvtabCursorRowReset(pCur);
  csvReaderReset(@pCur^.rdr);
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ csv.c:709 — xOpen. }
function csvtabOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pTab: PCsvTable;
  pCur: PCsvCursor;
  nByte: NativeUInt;
begin
  pTab := PCsvTable(p);
  nByte := SizeOf(TCsvCursor) +
    (SizeOf(PAnsiChar) + SizeOf(i64)) * NativeUInt(pTab^.nCol);
  pCur := PCsvCursor(sqlite3_malloc64(nByte));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, nByte, 0);
  { Allocate azVal / aLen as a tail of pCur. }
  pCur^.azVal := PPAnsiChar(PAnsiChar(pCur) + SizeOf(TCsvCursor));
  pCur^.aLen  := Pi64(PAnsiChar(pCur^.azVal) +
    SizeOf(PAnsiChar) * NativeUInt(pTab^.nCol));
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  if csvReaderOpen(@pCur^.rdr, pTab^.zFilename, pTab^.zData) <> 0 then
  begin
    csvXferError(pTab, @pCur^.rdr);
    Result := SQLITE_ERROR; Exit;
  end;
  Result := SQLITE_OK;
end;

{ csv.c:732 — xNext. }
function csvtabNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PCsvCursor;
  pTab: PCsvTable;
  i: i32;
  z, zNew: PAnsiChar;
  ppz: PPAnsiChar;
  paLen: Pi64;
  needed: i64;
begin
  pCur := PCsvCursor(cur);
  pTab := PCsvTable(cur^.pVtab);
  i := 0;
  z := nil;
  repeat
    z := csvReadOneField(@pCur^.rdr);
    if z = nil then Break;
    if i < pTab^.nCol then begin
      ppz := pCur^.azVal; Inc(ppz, i);
      paLen := pCur^.aLen; Inc(paLen, i);
      needed := pCur^.rdr.n + 1;
      if paLen^ < needed then begin
        zNew := PAnsiChar(sqlite3_realloc64(ppz^, u64(needed)));
        if zNew = nil then begin
          csvErrmsg(@pCur^.rdr, 'out of memory');
          csvXferError(pTab, @pCur^.rdr);
          Break;
        end;
        ppz^ := zNew;
        paLen^ := needed;
      end;
      Move(z^, ppz^^, needed);
      Inc(i);
    end;
  until pCur^.rdr.cTerm <> Ord(',');
  if (z = nil) and (i = 0) then begin
    pCur^.iRowid := -1;
  end else begin
    Inc(pCur^.iRowid);
    while i < pTab^.nCol do begin
      ppz := pCur^.azVal; Inc(ppz, i);
      paLen := pCur^.aLen; Inc(paLen, i);
      sqlite3_free(ppz^); ppz^ := nil;
      paLen^ := 0;
      Inc(i);
    end;
  end;
  Result := SQLITE_OK;
end;

{ csv.c:775 — xColumn. }
function csvtabColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur: PCsvCursor;
  pTab: PCsvTable;
  ppz: PPAnsiChar;
begin
  pCur := PCsvCursor(cur);
  pTab := PCsvTable(cur^.pVtab);
  if (i >= 0) and (i < pTab^.nCol) then begin
    ppz := pCur^.azVal; Inc(ppz, i);
    if ppz^ <> nil then
      sqlite3_result_text(ctx, ppz^, -1, SQLITE_TRANSIENT);
  end;
  Result := SQLITE_OK;
end;

{ csv.c:791 — xRowid. }
function csvtabRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PCsvCursor;
begin
  pCur := PCsvCursor(cur);
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

{ csv.c:801 — xEof. }
function csvtabEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PCsvCursor;
begin
  pCur := PCsvCursor(cur);
  if pCur^.iRowid < 0 then Result := 1 else Result := 0;
end;

{ csv.c:810 — xFilter.  Rewinds to start of data. }
function csvtabFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PCsvCursor;
  pTab: PCsvTable;
begin
  pCur := PCsvCursor(pVtabCursor);
  pTab := PCsvTable(pVtabCursor^.pVtab);
  pCur^.iRowid := 0;
  if csvAppend(@pCur^.rdr, #0) <> 0 then begin
    Result := SQLITE_NOMEM; Exit;
  end;
  if pCur^.rdr.inF = nil then
    pCur^.rdr.iIn := NativeUInt(pTab^.iStart)
  else begin
    csvFseek(pCur^.rdr.inF, pTab^.iStart, SEEK_SET);
    pCur^.rdr.iIn := 0;
    pCur^.rdr.nIn := 0;
  end;
  Result := csvtabNext(pVtabCursor);
end;

{ csv.c:843 — xBestIndex.  Always returns the same constant cost. }
function csvtabBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
begin
  pIdxInfo^.estimatedCost := 1000000.0;
  Result := SQLITE_OK;
end;

var
  csvModule: Tsqlite3_module;

function sqlite3CsvInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'csv', @csvModule, nil);
end;

initialization
  FillChar(csvModule, SizeOf(csvModule), 0);
  csvModule.iVersion    := 0;
  csvModule.xCreate     := @csvtabCreate;
  csvModule.xConnect    := @csvtabConnect;
  csvModule.xBestIndex  := @csvtabBestIndex;
  csvModule.xDisconnect := @csvtabDisconnect;
  csvModule.xDestroy    := @csvtabDisconnect;
  csvModule.xOpen       := @csvtabOpen;
  csvModule.xClose      := @csvtabClose;
  csvModule.xFilter     := @csvtabFilter;
  csvModule.xNext       := @csvtabNext;
  csvModule.xEof        := @csvtabEof;
  csvModule.xColumn     := @csvtabColumn;
  csvModule.xRowid      := @csvtabRowid;
end.
