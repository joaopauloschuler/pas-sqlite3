{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/zipfile.c (2293 lines in C).

  Implements the `zipfile` virtual table for reading and writing ZIP
  archive files plus the `zipfile()` aggregate function for assembling a
  ZIP archive image into a single BLOB.

  Vtab usage:
      CREATE VIRTUAL TABLE z USING zipfile('/path/to/archive.zip');
      SELECT name, sz, datetime(mtime,'unixepoch') FROM z;
      SELECT name, data FROM zipfile($filename);
      INSERT INTO z(name,data) VALUES('hello.txt', 'hello world');

  Aggregate usage:
      SELECT zipfile(name, data) FROM source;
      SELECT zipfile(name, mode, mtime, data, method) FROM source;

  Limitations (mirroring upstream):
    * No encryption.
    * No multi-file (split) archives.
    * No zip64 extensions.
    * Only deflate (method 8) and store (method 0) compression methods.

  Public entry: sqlite3ZipfileInit(db) — equivalent to the
  sqlite3_zipfile_init() loadable-extension entry in C.
}
{$I passqlite3.inc}
unit passqlite3zipfile;

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

function sqlite3ZipfileInit(db: PTsqlite3): i32;

implementation

uses
  ctypes;

{$POINTERMATH ON}

const
  ZIPFILE_F_COLUMN_IDX     = 7;        { hidden file-name column }
  ZIPFILE_MX_NAME          = 250;
  ZIPFILE_BUFFER_SIZE      = 200 * 1024;

  ZIPFILE_EXTRA_TIMESTAMP  = $5455;
  ZIPFILE_NEWENTRY_MADEBY  = (3 shl 8) + 30;
  ZIPFILE_NEWENTRY_REQUIRED = 20;
  ZIPFILE_NEWENTRY_FLAGS   = $800;
  ZIPFILE_SIGNATURE_CDS    = $02014b50;
  ZIPFILE_SIGNATURE_LFH    = $04034b50;
  ZIPFILE_SIGNATURE_EOCD   = $06054b50;

  ZIPFILE_LFH_FIXED_SZ     = 30;
  ZIPFILE_EOCD_FIXED_SZ    = 22;
  ZIPFILE_CDS_FIXED_SZ     = 46;

  ZIPFILE_CDS_NFILE_OFF        = 28;
  ZIPFILE_CDS_SZCOMPRESSED_OFF = 20;

  S_IFDIR = $4000;   { 040000 octal }
  S_IFREG = $8000;   { 0100000 octal }
  S_IFLNK = $A000;   { 0120000 octal }

  ZIPFILE_SCHEMA: PAnsiChar =
    'CREATE TABLE y('
    + 'name PRIMARY KEY,'
    + 'mode,'
    + 'mtime,'
    + 'sz,'
    + 'rawdata,'
    + 'data,'
    + 'method,'
    + 'z HIDDEN'
    + ') WITHOUT ROWID;';

  Z_OK_RC          = 0;
  Z_STREAM_END_RC  = 1;
  Z_NO_FLUSH       = 0;
  Z_FINISH         = 4;
  Z_DEFLATED       = 8;
  Z_DEFAULT_STRATEGY = 0;

  { sqlite3.h ON CONFLICT codes (not currently re-exported from
    passqlite3types). }
  SQLITE_REPLACE_RC  = 5;

type
  PByte = ^Byte;

  { 4.3.16 — End of Central Directory record. }
  ZipfileEOCD = record
    iDisk       : u16;
    iFirstDisk  : u16;
    nEntry      : u16;
    nEntryTotal : u16;
    nSize       : u32;
    iOffset     : u32;
  end;
  PZipfileEOCD = ^ZipfileEOCD;

  { 4.3.12 — Central Directory Structure. }
  ZipfileCDS = record
    iVersionMadeBy  : u16;
    iVersionExtract : u16;
    flags           : u16;
    iCompression    : u16;
    mTime           : u16;
    mDate           : u16;
    crc32_          : u32;
    szCompressed    : u32;
    szUncompressed  : u32;
    nFile           : u16;
    nExtra          : u16;
    nComment        : u16;
    iDiskStart      : u16;
    iInternalAttr   : u16;
    iExternalAttr   : u32;
    iOffset         : u32;
    zFile           : PAnsiChar;     { sqlite3_malloc'd }
  end;
  PZipfileCDS = ^ZipfileCDS;

  { 4.3.7 — Local File Header. }
  ZipfileLFH = record
    iVersionExtract : u16;
    flags           : u16;
    iCompression    : u16;
    mTime           : u16;
    mDate           : u16;
    crc32_          : u32;
    szCompressed    : u32;
    szUncompressed  : u32;
    nFile           : u16;
    nExtra          : u16;
  end;

  PZipfileEntry = ^TZipfileEntry;
  TZipfileEntry = record
    cds       : ZipfileCDS;
    mUnixTime : u32;
    aExtra    : PByte;       { points into trailing buffer }
    iDataOff  : i64;
    aData     : PByte;       { points into trailing buffer (in-memory archives) }
    pNext     : PZipfileEntry;
  end;

  PZipfileTab = ^TZipfileTab;

  PZipfileCsr = ^TZipfileCsr;
  TZipfileCsr = record
    base       : Tsqlite3_vtab_cursor;
    iId        : i64;
    bEof       : u8;
    bNoop      : u8;
    pFile      : Pointer;        { FILE* }
    iNextOff   : i64;
    eocd       : ZipfileEOCD;
    pFreeEntry : PZipfileEntry;
    pCurrent   : PZipfileEntry;
    pCsrNext   : PZipfileCsr;
  end;

  TZipfileTab = record
    base        : Tsqlite3_vtab;
    zFile       : PAnsiChar;
    db          : PTsqlite3;
    aBuffer     : PByte;
    pCsrList    : PZipfileCsr;
    iNextCsrid  : i64;
    pFirstEntry : PZipfileEntry;
    pLastEntry  : PZipfileEntry;
    pWriteFd    : Pointer;       { FILE* }
    szCurrent   : i64;
    szOrig      : i64;
  end;

  PZipfileBuffer = ^TZipfileBuffer;
  TZipfileBuffer = record
    a      : PByte;
    n      : i32;
    nAlloc : i32;
  end;

  PZipfileCtx = ^TZipfileCtx;
  TZipfileCtx = record
    nEntry : i32;
    body   : TZipfileBuffer;
    cds    : TZipfileBuffer;
  end;

  { libc / zlib z_stream — Linux x86-64 layout (uLong = 64-bit). }
  z_stream = record
    next_in   : PByte;
    avail_in  : cuint;
    total_in  : culong;
    next_out  : PByte;
    avail_out : cuint;
    total_out : culong;
    msg       : PAnsiChar;
    state     : Pointer;
    zalloc    : Pointer;
    zfree     : Pointer;
    opaque    : Pointer;
    data_type : cint;
    adler     : culong;
    reserved  : culong;
  end;
  Pz_stream = ^z_stream;

{ ----- libc bindings ---------------------------------------------- }

function fopenC(path, mode: PAnsiChar): Pointer; cdecl; external 'c' name 'fopen';
function fcloseC(f: Pointer): cint; cdecl; external 'c' name 'fclose';
function freadC(buf: Pointer; sz, n: NativeUInt; f: Pointer): NativeUInt;
  cdecl; external 'c' name 'fread';
function fwriteC(buf: Pointer; sz, n: NativeUInt; f: Pointer): NativeUInt;
  cdecl; external 'c' name 'fwrite';
function fseekC(f: Pointer; off: clong; whence: cint): cint;
  cdecl; external 'c' name 'fseek';
function ftellC(f: Pointer): clong; cdecl; external 'c' name 'ftell';
function strlenC(s: PAnsiChar): NativeUInt; cdecl; external 'c' name 'strlen';

const
  SEEK_SET = 0;
  SEEK_END = 2;

{ ----- zlib bindings ---------------------------------------------- }

function zlib_crc32(crc: culong; buf: Pointer; len: cuint): culong;
  cdecl; external 'z' name 'crc32';
function deflateInit2_(strm: Pz_stream; level, method, windowBits,
  memLevel, strategy: cint; version: PAnsiChar; stream_size: cint): cint;
  cdecl; external 'z' name 'deflateInit2_';
function deflate(strm: Pz_stream; flush: cint): cint;
  cdecl; external 'z' name 'deflate';
function deflateEnd(strm: Pz_stream): cint;
  cdecl; external 'z' name 'deflateEnd';
function deflateBound(strm: Pz_stream; sourceLen: culong): culong;
  cdecl; external 'z' name 'deflateBound';
function inflateInit2_(strm: Pz_stream; windowBits: cint;
  version: PAnsiChar; stream_size: cint): cint;
  cdecl; external 'z' name 'inflateInit2_';
function inflate(strm: Pz_stream; flush: cint): cint;
  cdecl; external 'z' name 'inflate';
function inflateEnd(strm: Pz_stream): cint;
  cdecl; external 'z' name 'inflateEnd';
function zlibVersion: PAnsiChar; cdecl; external 'z' name 'zlibVersion';

function deflateInit2(strm: Pz_stream; level: cint): cint;
begin
  Result := deflateInit2_(strm, level, Z_DEFLATED, -15, 8,
    Z_DEFAULT_STRATEGY, zlibVersion, SizeOf(z_stream));
end;

function inflateInit2(strm: Pz_stream; windowBits: cint): cint;
begin
  Result := inflateInit2_(strm, windowBits, zlibVersion, SizeOf(z_stream));
end;

{ ----- byte get/put helpers --------------------------------------- }

function zipfileGetU16(aBuf: PByte): u16;
begin
  Result := (u16(aBuf[1]) shl 8) or u16(aBuf[0]);
end;

function zipfileGetU32(aBuf: PByte): u32;
begin
  if aBuf = nil then begin Result := 0; Exit; end;
  Result := (u32(aBuf[3]) shl 24) or (u32(aBuf[2]) shl 16)
         or (u32(aBuf[1]) shl 8)  or  u32(aBuf[0]);
end;

procedure zipfilePutU16(aBuf: PByte; val: u16);
begin
  aBuf[0] := Byte(val and $FF);
  aBuf[1] := Byte((val shr 8) and $FF);
end;

procedure zipfilePutU32(aBuf: PByte; val: u32);
begin
  aBuf[0] := Byte(val and $FF);
  aBuf[1] := Byte((val shr 8) and $FF);
  aBuf[2] := Byte((val shr 16) and $FF);
  aBuf[3] := Byte((val shr 24) and $FF);
end;

function zipfileRead16(var p: PByte): u16;
begin
  Result := zipfileGetU16(p);
  Inc(p, 2);
end;

function zipfileRead32(var p: PByte): u32;
begin
  Result := zipfileGetU32(p);
  Inc(p, 4);
end;

procedure zipfileWrite16(var p: PByte; val: u16);
begin
  zipfilePutU16(p, val);
  Inc(p, 2);
end;

procedure zipfileWrite32(var p: PByte; val: u32);
begin
  zipfilePutU32(p, val);
  Inc(p, 4);
end;

{ ----- error-message helpers -------------------------------------- }

procedure zipfileCtxErrorMsg(ctx: Psqlite3_context; const fmt: AnsiString;
  const args: array of const);
var s: AnsiString;
begin
  s := Format(fmt, args);
  sqlite3_result_error(ctx, PAnsiChar(s), -1);
end;

procedure zipfileTableErr(pTab: PZipfileTab; const fmt: AnsiString;
  const args: array of const);
var s: AnsiString;
begin
  if pTab^.base.zErrMsg <> nil then
    sqlite3_free(pTab^.base.zErrMsg);
  s := Format(fmt, args);
  pTab^.base.zErrMsg := sqlite3StrDup(PAnsiChar(s));
end;

procedure zipfileCursorErr(pCsr: PZipfileCsr; const fmt: AnsiString;
  const args: array of const);
var s: AnsiString;
begin
  if pCsr^.base.pVtab^.zErrMsg <> nil then
    sqlite3_free(pCsr^.base.pVtab^.zErrMsg);
  s := Format(fmt, args);
  pCsr^.base.pVtab^.zErrMsg := sqlite3StrDup(PAnsiChar(s));
end;

function zipfileCorrupt(pzErr: PPAnsiChar): i32;
var s: AnsiString;
begin
  if pzErr^ <> nil then sqlite3_free(pzErr^);
  s := 'zip archive is corrupt';
  pzErr^ := sqlite3StrDup(PAnsiChar(s));
  Result := SQLITE_CORRUPT;
end;

{ ----- dequote helper --------------------------------------------- }

procedure zipfileDequote(zIn: PAnsiChar);
var
  q   : AnsiChar;
  iIn, iOut: i32;
  c   : AnsiChar;
begin
  if zIn = nil then Exit;
  q := zIn[0];
  if (q = '"') or (q = '''') or (q = '`') or (q = '[') then begin
    iIn := 1;
    iOut := 0;
    if q = '[' then q := ']';
    while zIn[iIn] <> #0 do begin
      c := zIn[iIn];
      Inc(iIn);
      if c = q then begin
        if zIn[iIn] <> q then Break;
        Inc(iIn);
      end;
      zIn[iOut] := c;
      Inc(iOut);
    end;
    zIn[iOut] := #0;
  end;
end;

{ ----- file I/O wrappers ------------------------------------------ }

function zipfileReadData(pFile: Pointer; aRead: PByte; nRead, iOff: i64;
  pzErrmsg: PPAnsiChar): i32;
var
  n: NativeUInt;
  s: AnsiString;
begin
  fseekC(pFile, clong(iOff), SEEK_SET);
  n := freadC(aRead, 1, NativeUInt(nRead), pFile);
  if i64(n) <> nRead then begin
    if pzErrmsg^ <> nil then sqlite3_free(pzErrmsg^);
    s := 'error in fread()';
    pzErrmsg^ := sqlite3StrDup(PAnsiChar(s));
    Result := SQLITE_ERROR;
    Exit;
  end;
  Result := SQLITE_OK;
end;

function zipfileAppendData(pTab: PZipfileTab; aWrite: PByte; nWrite: i32): i32;
var n: NativeUInt;
begin
  if nWrite > 0 then begin
    fseekC(pTab^.pWriteFd, clong(pTab^.szCurrent), SEEK_SET);
    n := fwriteC(aWrite, 1, NativeUInt(nWrite), pTab^.pWriteFd);
    if i32(n) <> nWrite then begin
      zipfileTableErr(pTab, 'error in fwrite()', []);
      Result := SQLITE_ERROR;
      Exit;
    end;
    pTab^.szCurrent := pTab^.szCurrent + nWrite;
  end;
  Result := SQLITE_OK;
end;

{ ----- CDS / LFH decode ------------------------------------------- }

function zipfileReadCDS(aBuf: PByte; pCDS: PZipfileCDS): i32;
var
  aRead: PByte;
  sig: u32;
begin
  aRead := aBuf;
  sig := zipfileRead32(aRead);
  if sig <> ZIPFILE_SIGNATURE_CDS then begin
    Result := SQLITE_ERROR;
    Exit;
  end;
  pCDS^.iVersionMadeBy  := zipfileRead16(aRead);
  pCDS^.iVersionExtract := zipfileRead16(aRead);
  pCDS^.flags           := zipfileRead16(aRead);
  pCDS^.iCompression    := zipfileRead16(aRead);
  pCDS^.mTime           := zipfileRead16(aRead);
  pCDS^.mDate           := zipfileRead16(aRead);
  pCDS^.crc32_          := zipfileRead32(aRead);
  pCDS^.szCompressed    := zipfileRead32(aRead);
  pCDS^.szUncompressed  := zipfileRead32(aRead);
  pCDS^.nFile           := zipfileRead16(aRead);
  pCDS^.nExtra          := zipfileRead16(aRead);
  pCDS^.nComment        := zipfileRead16(aRead);
  pCDS^.iDiskStart      := zipfileRead16(aRead);
  pCDS^.iInternalAttr   := zipfileRead16(aRead);
  pCDS^.iExternalAttr   := zipfileRead32(aRead);
  pCDS^.iOffset         := zipfileRead32(aRead);
  Result := SQLITE_OK;
end;

function zipfileReadLFH(aBuffer: PByte; pLFH: PZipfileEntry): i32;
var
  aRead: PByte;
  sig: u32;
  lfh: ZipfileLFH;
begin
  aRead := aBuffer;
  sig := zipfileRead32(aRead);
  if sig <> ZIPFILE_SIGNATURE_LFH then begin
    Result := SQLITE_ERROR;
    Exit;
  end;
  lfh.iVersionExtract := zipfileRead16(aRead);
  lfh.flags           := zipfileRead16(aRead);
  lfh.iCompression    := zipfileRead16(aRead);
  lfh.mTime           := zipfileRead16(aRead);
  lfh.mDate           := zipfileRead16(aRead);
  lfh.crc32_          := zipfileRead32(aRead);
  lfh.szCompressed    := zipfileRead32(aRead);
  lfh.szUncompressed  := zipfileRead32(aRead);
  lfh.nFile           := zipfileRead16(aRead);
  lfh.nExtra          := zipfileRead16(aRead);
  if lfh.nFile > ZIPFILE_MX_NAME then begin
    Result := SQLITE_ERROR;
    Exit;
  end;
  if pLFH <> nil then begin
    pLFH^.iDataOff := i64(lfh.nFile) + i64(lfh.nExtra);
  end;
  Result := SQLITE_OK;
end;

{ Decode an LFH header into a fresh local ZipfileLFH record (no entry). }
function zipfileReadLFHRaw(aBuffer: PByte; out lfh: ZipfileLFH): i32;
var
  aRead: PByte;
  sig: u32;
begin
  aRead := aBuffer;
  sig := zipfileRead32(aRead);
  if sig <> ZIPFILE_SIGNATURE_LFH then begin
    FillChar(lfh, SizeOf(lfh), 0);
    Result := SQLITE_ERROR;
    Exit;
  end;
  lfh.iVersionExtract := zipfileRead16(aRead);
  lfh.flags           := zipfileRead16(aRead);
  lfh.iCompression    := zipfileRead16(aRead);
  lfh.mTime           := zipfileRead16(aRead);
  lfh.mDate           := zipfileRead16(aRead);
  lfh.crc32_          := zipfileRead32(aRead);
  lfh.szCompressed    := zipfileRead32(aRead);
  lfh.szUncompressed  := zipfileRead32(aRead);
  lfh.nFile           := zipfileRead16(aRead);
  lfh.nExtra          := zipfileRead16(aRead);
  if lfh.nFile > ZIPFILE_MX_NAME then begin
    Result := SQLITE_ERROR;
    Exit;
  end;
  Result := SQLITE_OK;
end;

function zipfileScanExtra(aExtra: PByte; nExtra: i32; pmTime: Pu32): i32;
var
  ret    : i32;
  p, pEnd: PByte;
  id, nByte: u16;
  b      : Byte;
begin
  ret := 0;
  p := aExtra;
  pEnd := aExtra + nExtra;
  { 2*sizeof(u16) + 1 + sizeof(u32) = 9 bytes minimum }
  while (p + 9) <= pEnd do begin
    id    := zipfileRead16(p);
    nByte := zipfileRead16(p);
    if id = ZIPFILE_EXTRA_TIMESTAMP then begin
      b := p[0];
      if (b and $01) <> 0 then begin
        pmTime^ := zipfileGetU32(p + 1);
        ret := 1;
      end;
    end;
    Inc(p, nByte);
  end;
  Result := ret;
end;

{ ----- DOS↔UNIX time conversion ----------------------------------- }

function zipfileMtime(pCDS: PZipfileCDS): u32;
var
  Y, M, D, X1, X2, A, B, sec_, min_, hr_: i32;
  JDsec: i64;
begin
  Y := 1980 + ((pCDS^.mDate shr 9) and $7F);
  M := (pCDS^.mDate shr 5) and $0F;
  D := pCDS^.mDate and $1F;
  sec_ := (pCDS^.mTime and $1F) * 2;
  min_ := (pCDS^.mTime shr 5) and $3F;
  hr_  := (pCDS^.mTime shr 11) and $1F;
  if M <= 2 then begin
    Dec(Y);
    Inc(M, 12);
  end;
  X1 := 36525 * (Y + 4716) div 100;
  X2 := 306001 * (M + 1) div 10000;
  A := Y div 100;
  B := 2 - A + (A div 4);
  { (X1 + X2 + D + B - 1524.5)*86400 — half second offset; multiply
    keeps integer arithmetic by doubling first then halving. }
  JDsec := i64((X1 + X2 + D + B) * 86400) - i64(1524) * 86400 - 43200;
  JDsec := JDsec + i64(hr_) * 3600 + i64(min_) * 60 + sec_;
  Result := u32(JDsec - i64(24405875) * i64(8640));
end;

procedure zipfileMtimeToDos(pCds: PZipfileCDS; mUnixTime: u32);
var
  JD: i64;
  A, B, C, DD, E: i32;
  yr, mon, day, hr_, min_, sec_: i32;
begin
  JD := i64(2440588) + i64(mUnixTime) div (24 * 60 * 60);
  A := i32((JD - 1867216) div 36524);   { drop .25 — recovered below }
  { Re-implement with the 0.25 lost: A = (JD - 1867216.25)/36524.25.
    The C source uses doubles; we emulate via integer with sufficient
    precision because mUnixTime fits in 32 bits. }
  A := i32(((JD * 4) - i64(1867216) * 4 - 1) div (i64(36524) * 4 + 1));
  A := i32(JD + 1 + A - (A div 4));
  B := A + 1524;
  C := i32(((i64(B) * 100) - 12210) div 36525);   { (B-122.1)/365.25 }
  DD := (36525 * (C and 32767)) div 100;
  E := i32(((i64(B - DD) * 10000)) div 306001);   { (B-D)/30.6001 }

  day := B - DD - i32((306001 * i64(E)) div 10000);
  if E < 14 then mon := E - 1 else mon := E - 13;
  if mon > 2 then yr := C - 4716 else yr := C - 4715;

  hr_  := i32((mUnixTime mod (24 * 60 * 60)) div (60 * 60));
  min_ := i32((mUnixTime mod (60 * 60)) div 60);
  sec_ := i32(mUnixTime mod 60);

  if yr >= 1980 then begin
    pCds^.mDate := u16(day + (mon shl 5) + ((yr - 1980) shl 9));
    pCds^.mTime := u16((sec_ div 2) + (min_ shl 5) + (hr_ shl 11));
  end else begin
    pCds^.mDate := 0;
    pCds^.mTime := 0;
  end;
end;

{ ----- entry constructors / lifecycle ----------------------------- }

procedure zipfileEntryFree(p: PZipfileEntry);
begin
  if p <> nil then begin
    sqlite3_free(p^.cds.zFile);
    sqlite3_free(p);
  end;
end;

function zipfileGetEntry(pTab: PZipfileTab; aBlob: PByte; nBlob: i64;
  pFile: Pointer; iOff: i64; ppEntry: PPointer): i32;
var
  aRead: PByte;
  pzErr: PPAnsiChar;
  rc: i32;
  nFile, nExtra: i32;
  nAlloc: i64;
  pNew: PZipfileEntry;
  pt: Pu32;
  s: AnsiString;
  szFix: i32;
  lfh: ZipfileLFH;
begin
  pzErr := @pTab^.base.zErrMsg;
  rc := SQLITE_OK;

  if aBlob = nil then begin
    aRead := pTab^.aBuffer;
    rc := zipfileReadData(pFile, aRead, ZIPFILE_CDS_FIXED_SZ, iOff, pzErr);
  end else begin
    if (iOff + ZIPFILE_CDS_FIXED_SZ) > nBlob then begin
      Result := zipfileCorrupt(pzErr);
      Exit;
    end;
    aRead := aBlob + iOff;
  end;

  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  nFile := zipfileGetU16(aRead + ZIPFILE_CDS_NFILE_OFF);
  nExtra := zipfileGetU16(aRead + ZIPFILE_CDS_NFILE_OFF + 2);
  Inc(nExtra, zipfileGetU16(aRead + ZIPFILE_CDS_NFILE_OFF + 4));

  nAlloc := i64(SizeOf(TZipfileEntry)) + nExtra;
  if aBlob <> nil then
    nAlloc := nAlloc + zipfileGetU32(aRead + ZIPFILE_CDS_SZCOMPRESSED_OFF);

  pNew := PZipfileEntry(sqlite3_malloc64(u64(nAlloc)));
  if pNew = nil then begin
    Result := SQLITE_NOMEM;
    Exit;
  end;
  FillChar(pNew^, SizeOf(TZipfileEntry), 0);
  rc := zipfileReadCDS(aRead, @pNew^.cds);
  if rc <> SQLITE_OK then begin
    zipfileTableErr(pTab, 'failed to read CDS at offset %d', [iOff]);
  end else if aBlob = nil then begin
    rc := zipfileReadData(pFile, aRead, nExtra + nFile,
      iOff + ZIPFILE_CDS_FIXED_SZ, pzErr);
  end else begin
    aRead := aBlob + iOff + ZIPFILE_CDS_FIXED_SZ;
    if (iOff + ZIPFILE_CDS_FIXED_SZ + nFile + nExtra) > nBlob then
      rc := zipfileCorrupt(pzErr);
  end;

  if rc = SQLITE_OK then begin
    SetLength(s, nFile);
    if nFile > 0 then Move(aRead^, PAnsiChar(s)^, nFile);
    pNew^.cds.zFile := sqlite3StrDup(PAnsiChar(s));
    pNew^.aExtra := PByte(pNew) + SizeOf(TZipfileEntry);
    Move((aRead + nFile)^, pNew^.aExtra^, nExtra);
    if pNew^.cds.zFile = nil then
      rc := SQLITE_NOMEM
    else begin
      pt := @pNew^.mUnixTime;
      if zipfileScanExtra(aRead + nFile, pNew^.cds.nExtra, pt) = 0 then
        pNew^.mUnixTime := zipfileMtime(@pNew^.cds);
    end;
  end;

  if rc = SQLITE_OK then begin
    szFix := ZIPFILE_LFH_FIXED_SZ;
    if pFile <> nil then
      rc := zipfileReadData(pFile, aRead, szFix, pNew^.cds.iOffset, pzErr)
    else begin
      aRead := aBlob + pNew^.cds.iOffset;
      if (i64(pNew^.cds.iOffset) + ZIPFILE_LFH_FIXED_SZ) > nBlob then
        rc := zipfileCorrupt(pzErr);
    end;

    FillChar(lfh, SizeOf(lfh), 0);
    if rc = SQLITE_OK then rc := zipfileReadLFHRaw(aRead, lfh);
    if rc = SQLITE_OK then begin
      pNew^.iDataOff := i64(pNew^.cds.iOffset) + ZIPFILE_LFH_FIXED_SZ;
      pNew^.iDataOff := pNew^.iDataOff + lfh.nFile + lfh.nExtra;
      if (aBlob <> nil) and (pNew^.cds.szCompressed > 0) then begin
        if (pNew^.iDataOff + pNew^.cds.szCompressed) > nBlob then
          rc := zipfileCorrupt(pzErr)
        else begin
          pNew^.aData := pNew^.aExtra + nExtra;
          Move((aBlob + pNew^.iDataOff)^, pNew^.aData^,
            pNew^.cds.szCompressed);
        end;
      end;
    end else begin
      zipfileTableErr(pTab, 'failed to read LFH at offset %d',
        [pNew^.cds.iOffset]);
    end;
  end;

  if rc <> SQLITE_OK then
    zipfileEntryFree(pNew)
  else
    ppEntry^ := pNew;

  Result := rc;
end;

{ ----- vtab connect / disconnect ---------------------------------- }

procedure zipfileCleanupTransaction(pTab: PZipfileTab);
var pEntry, pNxt: PZipfileEntry;
begin
  if pTab^.pWriteFd <> nil then begin
    fcloseC(pTab^.pWriteFd);
    pTab^.pWriteFd := nil;
  end;
  pEntry := pTab^.pFirstEntry;
  while pEntry <> nil do begin
    pNxt := pEntry^.pNext;
    zipfileEntryFree(pEntry);
    pEntry := pNxt;
  end;
  pTab^.pFirstEntry := nil;
  pTab^.pLastEntry := nil;
  pTab^.szCurrent := 0;
  pTab^.szOrig := 0;
end;

function zipfileConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  nByte, nFile: i32;
  zFile: PAnsiChar;
  pNew: PZipfileTab;
  rc: i32;
  s: AnsiString;
  pTab: PPAnsiChar;
  argv2, argv3: PAnsiChar;
begin
  nByte := SizeOf(TZipfileTab) + ZIPFILE_BUFFER_SIZE;
  nFile := 0;
  zFile := nil;
  pNew := nil;

  pTab := argv;  Inc(pTab, 2);  argv2 := pTab^;  { argv[2] }
  Inc(pTab);                    argv3 := pTab^;  { argv[3] (may be invalid) }

  { If table name is not "zipfile", require an argument. }
  if ((sqlite3StrICmp(argv2, 'zipfile') <> 0) and (argc < 4)) or (argc > 4) then
  begin
    s := 'zipfile constructor requires one argument';
    pzErr^ := sqlite3StrDup(PAnsiChar(s));
    Result := SQLITE_ERROR;
    Exit;
  end;

  if argc > 3 then begin
    zFile := argv3;
    nFile := i32(strlenC(zFile)) + 1;
  end;

  rc := sqlite3_declare_vtab(db, ZIPFILE_SCHEMA);
  if rc = SQLITE_OK then begin
    pNew := PZipfileTab(sqlite3_malloc64(u64(nByte) + u64(nFile)));
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, nByte + nFile, 0);
    pNew^.db := db;
    pNew^.aBuffer := PByte(pNew) + SizeOf(TZipfileTab);
    if zFile <> nil then begin
      pNew^.zFile := PAnsiChar(pNew^.aBuffer + ZIPFILE_BUFFER_SIZE);
      Move(zFile^, pNew^.zFile^, nFile);
      zipfileDequote(pNew^.zFile);
    end;
  end;
  sqlite3_vtab_config(db, SQLITE_VTAB_DIRECTONLY, 0);
  ppVtab^ := PSqlite3Vtab(pNew);
  Result := rc;
end;

function zipfileDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
begin
  zipfileCleanupTransaction(PZipfileTab(pVtab));
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

{ ----- cursor open/close/reset ------------------------------------ }

function zipfileOpen(p: PSqlite3Vtab;
  ppCsr: PPSqlite3VtabCursor): i32; cdecl;
var
  pTab: PZipfileTab;
  pCsr: PZipfileCsr;
begin
  pTab := PZipfileTab(p);
  pCsr := PZipfileCsr(sqlite3_malloc64(SizeOf(TZipfileCsr)));
  ppCsr^ := PSqlite3VtabCursor(pCsr);
  if pCsr = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCsr^, SizeOf(TZipfileCsr), 0);
  Inc(pTab^.iNextCsrid);
  pCsr^.iId := pTab^.iNextCsrid;
  pCsr^.pCsrNext := pTab^.pCsrList;
  pTab^.pCsrList := pCsr;
  Result := SQLITE_OK;
end;

procedure zipfileResetCursor(pCsr: PZipfileCsr);
var p, pNxt: PZipfileEntry;
begin
  pCsr^.bEof := 0;
  if pCsr^.pFile <> nil then begin
    fcloseC(pCsr^.pFile);
    pCsr^.pFile := nil;
    zipfileEntryFree(pCsr^.pCurrent);
    pCsr^.pCurrent := nil;
  end;
  p := pCsr^.pFreeEntry;
  while p <> nil do begin
    pNxt := p^.pNext;
    zipfileEntryFree(p);
    p := pNxt;
  end;
  pCsr^.pFreeEntry := nil;
end;

function zipfileClose(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PZipfileCsr;
  pTab: PZipfileTab;
  pp  : ^PZipfileCsr;
begin
  pCsr := PZipfileCsr(cur);
  pTab := PZipfileTab(pCsr^.base.pVtab);
  zipfileResetCursor(pCsr);
  pp := @pTab^.pCsrList;
  while pp^ <> pCsr do
    pp := @pp^^.pCsrNext;
  pp^ := pCsr^.pCsrNext;
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ ----- xNext / xColumn / xEof ------------------------------------- }

function zipfileNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PZipfileCsr;
  rc: i32;
  iEof: i64;
  p: PZipfileEntry;
  pTab: PZipfileTab;
begin
  pCsr := PZipfileCsr(cur);
  rc := SQLITE_OK;

  if pCsr^.pFile <> nil then begin
    iEof := i64(pCsr^.eocd.iOffset) + i64(pCsr^.eocd.nSize);
    zipfileEntryFree(pCsr^.pCurrent);
    pCsr^.pCurrent := nil;
    if pCsr^.iNextOff >= iEof then
      pCsr^.bEof := 1
    else begin
      p := nil;
      pTab := PZipfileTab(cur^.pVtab);
      rc := zipfileGetEntry(pTab, nil, 0, pCsr^.pFile, pCsr^.iNextOff,
        @p);
      if rc = SQLITE_OK then begin
        pCsr^.iNextOff := pCsr^.iNextOff + ZIPFILE_CDS_FIXED_SZ;
        pCsr^.iNextOff := pCsr^.iNextOff + i32(p^.cds.nExtra)
                                       + p^.cds.nFile + p^.cds.nComment;
      end;
      pCsr^.pCurrent := p;
    end;
  end else begin
    if pCsr^.bNoop = 0 then
      pCsr^.pCurrent := pCsr^.pCurrent^.pNext;
    if pCsr^.pCurrent = nil then
      pCsr^.bEof := 1;
  end;
  pCsr^.bNoop := 0;
  Result := rc;
end;

procedure zipfileFree(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

procedure zipfileInflate(pCtx: Psqlite3_context; aIn: PByte; nIn, nOut: i32);
var
  aRes: PByte;
  err: cint;
  str: z_stream;
begin
  aRes := PByte(sqlite3_malloc64(u64(nOut)));
  if aRes = nil then begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  FillChar(str, SizeOf(str), 0);
  str.next_in   := aIn;
  str.avail_in  := nIn;
  str.next_out  := aRes;
  str.avail_out := nOut;
  err := inflateInit2(@str, -15);
  if err <> Z_OK_RC then
    zipfileCtxErrorMsg(pCtx, 'inflateInit2() failed (%d)', [err])
  else begin
    err := inflate(@str, Z_NO_FLUSH);
    if err <> Z_STREAM_END_RC then
      zipfileCtxErrorMsg(pCtx, 'inflate() failed (%d)', [err])
    else begin
      sqlite3_result_blob(pCtx, aRes, i32(str.total_out), @zipfileFree);
      aRes := nil;
    end;
  end;
  if aRes <> nil then sqlite3_free(aRes);
  inflateEnd(@str);
end;

function zipfileDeflate(aIn: PByte; nIn: i32;
  out aOut: PByte; out nOut: i32; pzErr: PPAnsiChar): i32;
var
  rc: i32;
  nAlloc: i64;
  str: z_stream;
  res: cint;
  buf: PByte;
  s: AnsiString;
begin
  rc := SQLITE_OK;
  FillChar(str, SizeOf(str), 0);
  str.next_in  := aIn;
  str.avail_in := nIn;
  deflateInit2(@str, 9);
  nAlloc := i64(deflateBound(@str, culong(nIn)));
  buf := PByte(sqlite3_malloc64(u64(nAlloc)));
  if buf = nil then
    rc := SQLITE_NOMEM
  else begin
    str.next_out  := buf;
    str.avail_out := cuint(nAlloc);
    res := deflate(@str, Z_FINISH);
    if res = Z_STREAM_END_RC then begin
      aOut := buf;
      nOut := i32(str.total_out);
    end else begin
      sqlite3_free(buf);
      s := 'zipfile: deflate() error';
      pzErr^ := sqlite3StrDup(PAnsiChar(s));
      rc := SQLITE_ERROR;
    end;
    deflateEnd(@str);
  end;
  Result := rc;
end;

function zipfileColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCsr: PZipfileCsr;
  pCDS: PZipfileCDS;
  rc: i32;
  sz, szFinal: i32;
  aBuf, aFree: PByte;
  pFile: Pointer;
  mode: u32;
begin
  pCsr := PZipfileCsr(cur);
  pCDS := @pCsr^.pCurrent^.cds;
  rc := SQLITE_OK;
  case i of
    0: sqlite3_result_text(ctx, pCDS^.zFile, -1, SQLITE_TRANSIENT);
    1: sqlite3_result_int(ctx, i32(pCDS^.iExternalAttr shr 16));
    2: sqlite3_result_int64(ctx, i64(pCsr^.pCurrent^.mUnixTime));
    3: if sqlite3_vtab_nochange(ctx) = 0 then
         sqlite3_result_int64(ctx, i64(pCDS^.szUncompressed));
    4, 5: begin
      if (i = 4) and (sqlite3_vtab_nochange(ctx) <> 0) then
        Exit(SQLITE_OK);
      if (i = 4) or (pCDS^.iCompression = 0) or (pCDS^.iCompression = 8) then
      begin
        sz := i32(pCDS^.szCompressed);
        szFinal := i32(pCDS^.szUncompressed);
        if szFinal > 0 then begin
          aFree := nil;
          if pCsr^.pCurrent^.aData <> nil then
            aBuf := pCsr^.pCurrent^.aData
          else begin
            aBuf := PByte(sqlite3_malloc64(u64(sz)));
            aFree := aBuf;
            if aBuf = nil then
              rc := SQLITE_NOMEM
            else begin
              pFile := pCsr^.pFile;
              if pFile = nil then
                pFile := PZipfileTab(pCsr^.base.pVtab)^.pWriteFd;
              rc := zipfileReadData(pFile, aBuf, sz,
                pCsr^.pCurrent^.iDataOff, @pCsr^.base.pVtab^.zErrMsg);
            end;
          end;
          if rc = SQLITE_OK then begin
            if (i = 5) and (pCDS^.iCompression <> 0) then
              zipfileInflate(ctx, aBuf, sz, szFinal)
            else
              sqlite3_result_blob(ctx, aBuf, sz, SQLITE_TRANSIENT);
          end;
          if aFree <> nil then sqlite3_free(aFree);
        end else begin
          { Zero-sized file: only emit '' if it isn't a directory. }
          mode := pCDS^.iExternalAttr shr 16;
          if ((mode and S_IFDIR) = 0) and (pCDS^.nFile >= 1)
             and (pCDS^.zFile[pCDS^.nFile - 1] <> '/') then
            sqlite3_result_blob(ctx, PAnsiChar(''), 0, SQLITE_STATIC);
        end;
      end;
    end;
    6: sqlite3_result_int(ctx, pCDS^.iCompression);
  else
    sqlite3_result_int64(ctx, pCsr^.iId);
  end;
  Result := rc;
end;

function zipfileEof(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  Result := PZipfileCsr(cur)^.bEof;
end;

{ ----- EOCD scan + load directory --------------------------------- }

function zipfileReadEOCD(pTab: PZipfileTab; aBlob: PByte; nBlob: i64;
  pFile: Pointer; pEOCD: PZipfileEOCD): i32;
var
  aRead: PByte;
  nRead: i64;
  rc: i32;
  iOff, szFile, ii: i64;
begin
  aRead := pTab^.aBuffer;
  rc := SQLITE_OK;
  FillChar(pEOCD^, SizeOf(pEOCD^), 0);
  if aBlob = nil then begin
    fseekC(pFile, 0, SEEK_END);
    szFile := i64(ftellC(pFile));
    if szFile = 0 then begin Result := SQLITE_OK; Exit; end;
    if szFile < ZIPFILE_BUFFER_SIZE then nRead := szFile
    else nRead := ZIPFILE_BUFFER_SIZE;
    iOff := szFile - nRead;
    rc := zipfileReadData(pFile, aRead, nRead, iOff, @pTab^.base.zErrMsg);
  end else begin
    if nBlob < ZIPFILE_BUFFER_SIZE then nRead := nBlob
    else nRead := ZIPFILE_BUFFER_SIZE;
    aRead := aBlob + nBlob - nRead;
  end;

  if rc = SQLITE_OK then begin
    ii := nRead - 20;
    while ii >= 0 do begin
      if (aRead[ii] = $50) and (aRead[ii + 1] = $4b)
         and (aRead[ii + 2] = $05) and (aRead[ii + 3] = $06) then
        Break;
      Dec(ii);
    end;
    if ii < 0 then begin
      zipfileTableErr(pTab,
        'cannot find end of central directory record', []);
      Result := SQLITE_ERROR;
      Exit;
    end;
    aRead := aRead + ii + 4;
    pEOCD^.iDisk       := zipfileRead16(aRead);
    pEOCD^.iFirstDisk  := zipfileRead16(aRead);
    pEOCD^.nEntry      := zipfileRead16(aRead);
    pEOCD^.nEntryTotal := zipfileRead16(aRead);
    pEOCD^.nSize       := zipfileRead32(aRead);
    pEOCD^.iOffset     := zipfileRead32(aRead);
  end;
  Result := rc;
end;

procedure zipfileAddEntry(pTab: PZipfileTab;
  pBefore, pNew: PZipfileEntry);
var pp: ^PZipfileEntry;
begin
  Assert(pNew^.pNext = nil);
  if pBefore = nil then begin
    if pTab^.pFirstEntry = nil then begin
      pTab^.pFirstEntry := pNew;
      pTab^.pLastEntry := pNew;
    end else begin
      pTab^.pLastEntry^.pNext := pNew;
      pTab^.pLastEntry := pNew;
    end;
  end else begin
    pp := @pTab^.pFirstEntry;
    while pp^ <> pBefore do
      pp := @pp^^.pNext;
    pNew^.pNext := pBefore;
    pp^ := pNew;
  end;
end;

function zipfileLoadDirectory(pTab: PZipfileTab; aBlob: PByte; nBlob: i64): i32;
var
  eocd: ZipfileEOCD;
  rc, ii: i32;
  iOff: i64;
  pNew: PZipfileEntry;
begin
  rc := zipfileReadEOCD(pTab, aBlob, nBlob, pTab^.pWriteFd, @eocd);
  iOff := eocd.iOffset;
  ii := 0;
  while (rc = SQLITE_OK) and (ii < eocd.nEntry) do begin
    pNew := nil;
    rc := zipfileGetEntry(pTab, aBlob, nBlob, pTab^.pWriteFd, iOff,
      @pNew);
    if rc = SQLITE_OK then begin
      zipfileAddEntry(pTab, nil, pNew);
      iOff := iOff + ZIPFILE_CDS_FIXED_SZ;
      iOff := iOff + i32(pNew^.cds.nExtra)
                  + pNew^.cds.nFile + pNew^.cds.nComment;
    end;
    Inc(ii);
  end;
  Result := rc;
end;

{ ----- xFilter / xBestIndex --------------------------------------- }

function zipfileFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPMem): i32; cdecl;
var
  pTab: PZipfileTab;
  pCsr: PZipfileCsr;
  zFile: PAnsiChar;
  rc: i32;
  bInMemory: i32;
  aBlob: PByte;
  nBlob: i64;
const
  aEmptyBlob: Byte = 0;
begin
  pTab := PZipfileTab(cur^.pVtab);
  pCsr := PZipfileCsr(cur);
  zFile := nil;
  rc := SQLITE_OK;
  bInMemory := 0;

  zipfileResetCursor(pCsr);

  if pTab^.zFile <> nil then begin
    zFile := pTab^.zFile;
  end else if idxNum = 0 then begin
    zipfileCursorErr(pCsr, 'zipfile() function requires an argument', []);
    Result := SQLITE_ERROR;
    Exit;
  end else if sqlite3_value_type(argv[0]) = SQLITE_BLOB then begin
    aBlob := PByte(sqlite3_value_blob(argv[0]));
    nBlob := sqlite3_value_bytes(argv[0]);
    Assert(pTab^.pFirstEntry = nil);
    if aBlob = nil then begin
      aBlob := @aEmptyBlob;
      nBlob := 0;
    end;
    rc := zipfileLoadDirectory(pTab, aBlob, nBlob);
    pCsr^.pFreeEntry := pTab^.pFirstEntry;
    pTab^.pFirstEntry := nil;
    pTab^.pLastEntry := nil;
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    bInMemory := 1;
  end else
    zFile := PAnsiChar(sqlite3_value_text(argv[0]));

  if (pTab^.pWriteFd = nil) and (bInMemory = 0) then begin
    if zFile <> nil then
      pCsr^.pFile := fopenC(zFile, 'rb');
    if pCsr^.pFile = nil then begin
      zipfileCursorErr(pCsr, 'cannot open file: %s', [zFile]);
      rc := SQLITE_ERROR;
    end else begin
      rc := zipfileReadEOCD(pTab, nil, 0, pCsr^.pFile, @pCsr^.eocd);
      if rc = SQLITE_OK then begin
        if pCsr^.eocd.nEntry = 0 then
          pCsr^.bEof := 1
        else begin
          pCsr^.iNextOff := pCsr^.eocd.iOffset;
          rc := zipfileNext(cur);
        end;
      end;
    end;
  end else begin
    pCsr^.bNoop := 1;
    if pCsr^.pFreeEntry <> nil then
      pCsr^.pCurrent := pCsr^.pFreeEntry
    else
      pCsr^.pCurrent := pTab^.pFirstEntry;
    rc := zipfileNext(cur);
  end;
  Result := rc;
end;

function zipfileBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i, idx, unusable: i32;
  pCons: PSqlite3IndexConstraint;
  pUse:  PSqlite3IndexConstraintUsage;
begin
  idx := -1;
  unusable := 0;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    pCons := pIdxInfo^.aConstraint + i;
    if pCons^.iColumn <> ZIPFILE_F_COLUMN_IDX then continue;
    if pCons^.usable = 0 then
      unusable := 1
    else if pCons^.op = SQLITE_INDEX_CONSTRAINT_EQ then
      idx := i;
  end;
  pIdxInfo^.estimatedCost := 1000.0;
  if idx >= 0 then begin
    pUse := pIdxInfo^.aConstraintUsage + idx;
    pUse^.argvIndex := 1;
    pUse^.omit := 1;
    pIdxInfo^.idxNum := 1;
  end else if unusable <> 0 then begin
    Result := SQLITE_CONSTRAINT;
    Exit;
  end;
  Result := SQLITE_OK;
end;

{ ----- write path ------------------------------------------------- }

function zipfileNewEntry(zPath: PAnsiChar): PZipfileEntry;
var pNew: PZipfileEntry;
begin
  pNew := PZipfileEntry(sqlite3_malloc64(SizeOf(TZipfileEntry)));
  if pNew <> nil then begin
    FillChar(pNew^, SizeOf(TZipfileEntry), 0);
    pNew^.cds.zFile := sqlite3StrDup(zPath);
    if pNew^.cds.zFile = nil then begin
      sqlite3_free(pNew);
      pNew := nil;
    end;
  end;
  Result := pNew;
end;

function zipfileSerializeLFH(pEntry: PZipfileEntry; aBuf: PByte): i32;
var
  pCds: PZipfileCDS;
  a: PByte;
begin
  pCds := @pEntry^.cds;
  a := aBuf;
  pCds^.nExtra := 9;
  zipfileWrite32(a, ZIPFILE_SIGNATURE_LFH);
  zipfileWrite16(a, pCds^.iVersionExtract);
  zipfileWrite16(a, pCds^.flags);
  zipfileWrite16(a, pCds^.iCompression);
  zipfileWrite16(a, pCds^.mTime);
  zipfileWrite16(a, pCds^.mDate);
  zipfileWrite32(a, pCds^.crc32_);
  zipfileWrite32(a, pCds^.szCompressed);
  zipfileWrite32(a, pCds^.szUncompressed);
  zipfileWrite16(a, pCds^.nFile);
  zipfileWrite16(a, pCds^.nExtra);
  Move(pCds^.zFile^, a^, pCds^.nFile);
  Inc(a, pCds^.nFile);
  zipfileWrite16(a, ZIPFILE_EXTRA_TIMESTAMP);
  zipfileWrite16(a, 5);
  a[0] := $01;
  Inc(a);
  zipfileWrite32(a, pEntry^.mUnixTime);
  Result := i32(a - aBuf);
end;

function zipfileAppendEntry(pTab: PZipfileTab;
  pEntry: PZipfileEntry; pData: PByte; nData: i32): i32;
var
  aBuf: PByte;
  nBuf, rc: i32;
begin
  aBuf := pTab^.aBuffer;
  nBuf := zipfileSerializeLFH(pEntry, aBuf);
  rc := zipfileAppendData(pTab, aBuf, nBuf);
  if rc = SQLITE_OK then begin
    pEntry^.iDataOff := pTab^.szCurrent;
    rc := zipfileAppendData(pTab, pData, nData);
  end;
  Result := rc;
end;

function zipfileGetMode(pVal: PMem; bIsDir: i32;
  pMode: Pu32; pzErr: PPAnsiChar): i32;
var
  z: PAnsiChar;
  mode: u32;
  i: i32;
  s: AnsiString;
const
  zTemplate: array[0..10] of AnsiChar = '-rwxrwxrwx'#0;
label
  parse_error;
begin
  z := PAnsiChar(sqlite3_value_text(pVal));
  mode := 0;
  if z = nil then begin
    if bIsDir <> 0 then
      mode := S_IFDIR + 8*8*8 * 0 + 8*8*7 + 8*5 + 5  { 0755 }
    else
      mode := S_IFREG + 8*8*6 + 8*4 + 4;  { 0644 }
    { Re-derive in clean form: 0755 = 493, 0644 = 420. }
    if bIsDir <> 0 then mode := S_IFDIR or 493
    else mode := S_IFREG or 420;
  end else if (z[0] >= '0') and (z[0] <= '9') then begin
    mode := u32(sqlite3_value_int(pVal));
  end else begin
    if strlenC(z) <> 10 then goto parse_error;
    case z[0] of
      '-': mode := mode or S_IFREG;
      'd': mode := mode or S_IFDIR;
      'l': mode := mode or S_IFLNK;
    else
      goto parse_error;
    end;
    for i := 1 to 9 do begin
      if z[i] = zTemplate[i] then
        mode := mode or u32(1 shl (9 - i))
      else if z[i] <> '-' then goto parse_error;
    end;
  end;
  if (((mode and S_IFDIR) = 0) = (bIsDir <> 0)) then begin
    s := 'zipfile: mode does not match data';
    pzErr^ := sqlite3StrDup(PAnsiChar(s));
    Result := SQLITE_CONSTRAINT;
    Exit;
  end;
  pMode^ := mode;
  Result := SQLITE_OK;
  Exit;
parse_error:
  s := Format('zipfile: parse error in mode: %s', [StrPas(z)]);
  pzErr^ := sqlite3StrDup(PAnsiChar(s));
  Result := SQLITE_ERROR;
end;

function zipfileComparePath(zA, zB: PAnsiChar; nB: i32): i32;
var nA: i32;
begin
  nA := i32(strlenC(zA));
  if (nA > 0) and (zA[nA - 1] = '/') then Dec(nA);
  if (nB > 0) and (zB[nB - 1] = '/') then Dec(nB);
  if (nA = nB) and (CompareByte(zA^, zB^, nA) = 0) then
    Result := 0
  else
    Result := 1;
end;

function zipfileBegin(pVtab: PSqlite3Vtab): i32; cdecl;
var
  pTab: PZipfileTab;
  rc: i32;
begin
  pTab := PZipfileTab(pVtab);
  rc := SQLITE_OK;
  Assert(pTab^.pWriteFd = nil);
  if (pTab^.zFile = nil) or (pTab^.zFile[0] = #0) then begin
    zipfileTableErr(pTab, 'zipfile: missing filename', []);
    Result := SQLITE_ERROR;
    Exit;
  end;
  pTab^.pWriteFd := fopenC(pTab^.zFile, 'ab+');
  if pTab^.pWriteFd = nil then begin
    zipfileTableErr(pTab,
      'zipfile: failed to open file %s for writing', [StrPas(pTab^.zFile)]);
    rc := SQLITE_ERROR;
  end else begin
    fseekC(pTab^.pWriteFd, 0, SEEK_END);
    pTab^.szCurrent := i64(ftellC(pTab^.pWriteFd));
    pTab^.szOrig := pTab^.szCurrent;
    rc := zipfileLoadDirectory(pTab, nil, 0);
  end;
  if rc <> SQLITE_OK then
    zipfileCleanupTransaction(pTab);
  Result := rc;
end;

function zipfileTime: u32;
var
  pVfs: Psqlite3_vfs;
  ms: i64;
begin
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Result := 0; Exit; end;
  if sqlite3OsCurrentTimeInt64(pVfs, @ms) = SQLITE_OK then
    Result := u32((ms div 1000) - i64(24405875) * 8640)
  else
    Result := 0;
end;

function zipfileGetTime(pVal: PMem): u32;
begin
  if (pVal = nil) or (sqlite3_value_type(pVal) = SQLITE_NULL) then
    Result := zipfileTime
  else
    Result := u32(sqlite3_value_int64(pVal));
end;

procedure zipfileRemoveEntryFromList(pTab: PZipfileTab; pOld: PZipfileEntry);
var p: PZipfileEntry;
begin
  if pOld = nil then Exit;
  if pTab^.pFirstEntry = pOld then begin
    pTab^.pFirstEntry := pOld^.pNext;
    if pTab^.pLastEntry = pOld then pTab^.pLastEntry := nil;
  end else begin
    p := pTab^.pFirstEntry;
    while p <> nil do begin
      if p^.pNext = pOld then begin
        p^.pNext := pOld^.pNext;
        if pTab^.pLastEntry = pOld then pTab^.pLastEntry := p;
        Break;
      end;
      p := p^.pNext;
    end;
  end;
  zipfileEntryFree(pOld);
end;

function zipfileUpdate(pVtab: PSqlite3Vtab; nVal: i32;
  apVal: PPMem; pRowid: Pi64): i32; cdecl;
var
  pTab: PZipfileTab;
  rc: i32;
  pNew: PZipfileEntry;
  mode: u32;
  mTime: u32;
  sz: i64;
  zPath: PAnsiChar;
  nPath: i32;
  pData: PByte;
  nData: i32;
  iMethod: i32;
  pFree: PByte;
  zFree: PAnsiChar;
  pOld, pOld2: PZipfileEntry;
  bUpdate, bIsDir: i32;
  iCrc32: u32;
  zDelete, zUpdate: PAnsiChar;
  nDelete: i32;
  aIn: PByte;
  nIn: i32;
  bAuto, nCmp: i32;
  p: PZipfileEntry;
  pCsr: PZipfileCsr;
  s: AnsiString;
label
  zipfile_update_done;
begin
  pTab := PZipfileTab(pVtab);
  rc := SQLITE_OK;
  pNew := nil; mode := 0; mTime := 0; sz := 0;
  zPath := nil; nPath := 0; pData := nil; nData := 0;
  iMethod := 0; pFree := nil; zFree := nil;
  pOld := nil; pOld2 := nil; bUpdate := 0; bIsDir := 0; iCrc32 := 0;

  if pTab^.pWriteFd = nil then begin
    rc := zipfileBegin(pVtab);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  if sqlite3_value_type(apVal[0]) <> SQLITE_NULL then begin
    zDelete := PAnsiChar(sqlite3_value_text(apVal[0]));
    nDelete := i32(strlenC(zDelete));
    if nVal > 1 then begin
      zUpdate := PAnsiChar(sqlite3_value_text(apVal[1]));
      if (zUpdate <> nil) and
         (zipfileComparePath(zUpdate, zDelete, nDelete) <> 0) then
        bUpdate := 1;
    end;
    pOld := pTab^.pFirstEntry;
    while pOld <> nil do begin
      if zipfileComparePath(pOld^.cds.zFile, zDelete, nDelete) = 0 then Break;
      pOld := pOld^.pNext;
    end;
  end;

  if nVal > 1 then begin
    if sqlite3_value_type(apVal[5]) <> SQLITE_NULL then begin
      zipfileTableErr(pTab, 'sz must be NULL', []);
      rc := SQLITE_CONSTRAINT;
    end;
    if sqlite3_value_type(apVal[6]) <> SQLITE_NULL then begin
      zipfileTableErr(pTab, 'rawdata must be NULL', []);
      rc := SQLITE_CONSTRAINT;
    end;

    if rc = SQLITE_OK then begin
      if sqlite3_value_type(apVal[7]) = SQLITE_NULL then
        bIsDir := 1
      else begin
        aIn := PByte(sqlite3_value_blob(apVal[7]));
        nIn := sqlite3_value_bytes(apVal[7]);
        bAuto := Ord(sqlite3_value_type(apVal[8]) = SQLITE_NULL);
        iMethod := sqlite3_value_int(apVal[8]);
        sz := nIn; pData := aIn; nData := nIn;
        if (iMethod <> 0) and (iMethod <> 8) then begin
          zipfileTableErr(pTab, 'unknown compression method: %d',
            [iMethod]);
          rc := SQLITE_CONSTRAINT;
        end else begin
          if (bAuto <> 0) or (iMethod <> 0) then begin
            nCmp := 0;
            rc := zipfileDeflate(aIn, nIn, pFree, nCmp,
              @pTab^.base.zErrMsg);
            if rc = SQLITE_OK then begin
              if (iMethod <> 0) or (nCmp < nIn) then begin
                iMethod := 8;
                pData := pFree;
                nData := nCmp;
              end;
            end;
          end;
          iCrc32 := u32(zlib_crc32(0, aIn, cuint(nIn)));
        end;
      end;
    end;

    if rc = SQLITE_OK then
      rc := zipfileGetMode(apVal[3], bIsDir, @mode, @pTab^.base.zErrMsg);

    if rc = SQLITE_OK then begin
      zPath := PAnsiChar(sqlite3_value_text(apVal[2]));
      if zPath = nil then zPath := '';
      nPath := i32(strlenC(zPath));
      if nPath > ZIPFILE_MX_NAME then begin
        zipfileTableErr(pTab, 'filename too long; max: %d bytes',
          [ZIPFILE_MX_NAME]);
        rc := SQLITE_CONSTRAINT;
      end;
      mTime := zipfileGetTime(apVal[4]);
    end;

    if (rc = SQLITE_OK) and (bIsDir <> 0) then begin
      if (nPath <= 0) or (zPath[nPath - 1] <> '/') then begin
        s := Format('%s/', [StrPas(zPath)]);
        zFree := sqlite3StrDup(PAnsiChar(s));
        zPath := zFree;
        if zFree = nil then begin
          rc := SQLITE_NOMEM;
          nPath := 0;
        end else
          nPath := i32(strlenC(zPath));
      end;
    end;

    if ((pOld = nil) or (bUpdate <> 0)) and (rc = SQLITE_OK) then begin
      p := pTab^.pFirstEntry;
      while p <> nil do begin
        if zipfileComparePath(p^.cds.zFile, zPath, nPath) = 0 then begin
          case sqlite3_vtab_on_conflict(pTab^.db) of
            SQLITE_IGNORE: goto zipfile_update_done;
            SQLITE_REPLACE_RC: pOld2 := p;
          else
            zipfileTableErr(pTab, 'duplicate name: "%s"',
              [StrPas(zPath)]);
            rc := SQLITE_CONSTRAINT;
          end;
          Break;
        end;
        p := p^.pNext;
      end;
    end;

    if rc = SQLITE_OK then begin
      pNew := zipfileNewEntry(zPath);
      if pNew = nil then
        rc := SQLITE_NOMEM
      else begin
        pNew^.cds.iVersionMadeBy  := ZIPFILE_NEWENTRY_MADEBY;
        pNew^.cds.iVersionExtract := ZIPFILE_NEWENTRY_REQUIRED;
        pNew^.cds.flags           := ZIPFILE_NEWENTRY_FLAGS;
        pNew^.cds.iCompression    := u16(iMethod);
        zipfileMtimeToDos(@pNew^.cds, mTime);
        pNew^.cds.crc32_         := iCrc32;
        pNew^.cds.szCompressed   := u32(nData);
        pNew^.cds.szUncompressed := u32(sz);
        pNew^.cds.iExternalAttr  := mode shl 16;
        pNew^.cds.iOffset        := u32(pTab^.szCurrent);
        pNew^.cds.nFile          := u16(nPath);
        pNew^.mUnixTime          := mTime;
        rc := zipfileAppendEntry(pTab, pNew, pData, nData);
        zipfileAddEntry(pTab, pOld, pNew);
      end;
    end;
  end;

  if (rc = SQLITE_OK) and ((pOld <> nil) or (pOld2 <> nil)) then begin
    pCsr := pTab^.pCsrList;
    while pCsr <> nil do begin
      if (pCsr^.pCurrent <> nil) and
         ((pCsr^.pCurrent = pOld) or (pCsr^.pCurrent = pOld2)) then begin
        pCsr^.pCurrent := pCsr^.pCurrent^.pNext;
        pCsr^.bNoop := 1;
      end;
      pCsr := pCsr^.pCsrNext;
    end;
    zipfileRemoveEntryFromList(pTab, pOld);
    zipfileRemoveEntryFromList(pTab, pOld2);
  end;

zipfile_update_done:
  if pFree <> nil then sqlite3_free(pFree);
  if zFree <> nil then sqlite3_free(zFree);
  Result := rc;
end;

function zipfileSerializeEOCD(p: PZipfileEOCD; aBuf: PByte): i32;
var a: PByte;
begin
  a := aBuf;
  zipfileWrite32(a, ZIPFILE_SIGNATURE_EOCD);
  zipfileWrite16(a, p^.iDisk);
  zipfileWrite16(a, p^.iFirstDisk);
  zipfileWrite16(a, p^.nEntry);
  zipfileWrite16(a, p^.nEntryTotal);
  zipfileWrite32(a, p^.nSize);
  zipfileWrite32(a, p^.iOffset);
  zipfileWrite16(a, 0);
  Result := i32(a - aBuf);
end;

function zipfileAppendEOCD(pTab: PZipfileTab; p: PZipfileEOCD): i32;
var nBuf: i32;
begin
  nBuf := zipfileSerializeEOCD(p, pTab^.aBuffer);
  Result := zipfileAppendData(pTab, pTab^.aBuffer, nBuf);
end;

function zipfileSerializeCDS(pEntry: PZipfileEntry; aBuf: PByte): i32;
var
  a: PByte;
  pCDS: PZipfileCDS;
  n: i32;
begin
  a := aBuf;
  pCDS := @pEntry^.cds;
  if pEntry^.aExtra = nil then pCDS^.nExtra := 9;

  zipfileWrite32(a, ZIPFILE_SIGNATURE_CDS);
  zipfileWrite16(a, pCDS^.iVersionMadeBy);
  zipfileWrite16(a, pCDS^.iVersionExtract);
  zipfileWrite16(a, pCDS^.flags);
  zipfileWrite16(a, pCDS^.iCompression);
  zipfileWrite16(a, pCDS^.mTime);
  zipfileWrite16(a, pCDS^.mDate);
  zipfileWrite32(a, pCDS^.crc32_);
  zipfileWrite32(a, pCDS^.szCompressed);
  zipfileWrite32(a, pCDS^.szUncompressed);
  zipfileWrite16(a, pCDS^.nFile);
  zipfileWrite16(a, pCDS^.nExtra);
  zipfileWrite16(a, pCDS^.nComment);
  zipfileWrite16(a, pCDS^.iDiskStart);
  zipfileWrite16(a, pCDS^.iInternalAttr);
  zipfileWrite32(a, pCDS^.iExternalAttr);
  zipfileWrite32(a, pCDS^.iOffset);

  Move(pCDS^.zFile^, a^, pCDS^.nFile);
  Inc(a, pCDS^.nFile);

  if pEntry^.aExtra <> nil then begin
    n := i32(pCDS^.nExtra) + i32(pCDS^.nComment);
    Move(pEntry^.aExtra^, a^, n);
    Inc(a, n);
  end else begin
    zipfileWrite16(a, ZIPFILE_EXTRA_TIMESTAMP);
    zipfileWrite16(a, 5);
    a[0] := $01;
    Inc(a);
    zipfileWrite32(a, pEntry^.mUnixTime);
  end;
  Result := i32(a - aBuf);
end;

function zipfileCommit(pVtab: PSqlite3Vtab): i32; cdecl;
var
  pTab: PZipfileTab;
  rc: i32;
  iOffset: i64;
  p: PZipfileEntry;
  eocd: ZipfileEOCD;
  nEntry, n: i32;
begin
  pTab := PZipfileTab(pVtab);
  rc := SQLITE_OK;
  if pTab^.pWriteFd <> nil then begin
    iOffset := pTab^.szCurrent;
    nEntry := 0;
    p := pTab^.pFirstEntry;
    while (rc = SQLITE_OK) and (p <> nil) do begin
      n := zipfileSerializeCDS(p, pTab^.aBuffer);
      rc := zipfileAppendData(pTab, pTab^.aBuffer, n);
      Inc(nEntry);
      p := p^.pNext;
    end;
    eocd.iDisk := 0; eocd.iFirstDisk := 0;
    eocd.nEntry := u16(nEntry);
    eocd.nEntryTotal := u16(nEntry);
    eocd.nSize := u32(pTab^.szCurrent - iOffset);
    eocd.iOffset := u32(iOffset);
    if rc = SQLITE_OK then rc := zipfileAppendEOCD(pTab, @eocd);
    zipfileCleanupTransaction(pTab);
  end;
  Result := rc;
end;

function zipfileRollback(pVtab: PSqlite3Vtab): i32; cdecl;
begin
  Result := zipfileCommit(pVtab);
end;

function zipfileFindCursor(pTab: PZipfileTab; iId: i64): PZipfileCsr;
var pCsr: PZipfileCsr;
begin
  pCsr := pTab^.pCsrList;
  while pCsr <> nil do begin
    if pCsr^.iId = iId then Break;
    pCsr := pCsr^.pCsrNext;
  end;
  Result := pCsr;
end;

procedure zipfileFunctionCds(pCtx: Psqlite3_context;
  argc: i32; argv: PPMem); cdecl;
var
  pCsr: PZipfileCsr;
  pTab: PZipfileTab;
  p: PZipfileCDS;
  s: AnsiString;
begin
  pTab := PZipfileTab(sqlite3_user_data(pCtx));
  pCsr := zipfileFindCursor(pTab, sqlite3_value_int64(argv[0]));
  if pCsr = nil then Exit;
  p := @pCsr^.pCurrent^.cds;
  s := Format('{"version-made-by" : %u, "version-to-extract" : %u, '
    + '"flags" : %u, "compression" : %u, "time" : %u, "date" : %u, '
    + '"crc32" : %u, "compressed-size" : %u, "uncompressed-size" : %u, '
    + '"file-name-length" : %u, "extra-field-length" : %u, '
    + '"file-comment-length" : %u, "disk-number-start" : %u, '
    + '"internal-attr" : %u, "external-attr" : %u, "offset" : %u }',
    [p^.iVersionMadeBy, p^.iVersionExtract, p^.flags, p^.iCompression,
     p^.mTime, p^.mDate, p^.crc32_, p^.szCompressed, p^.szUncompressed,
     p^.nFile, p^.nExtra, p^.nComment, p^.iDiskStart, p^.iInternalAttr,
     p^.iExternalAttr, p^.iOffset]);
  sqlite3_result_text(pCtx, PAnsiChar(s), -1, SQLITE_TRANSIENT);
end;

function zipfileFindFunction(pVtab: PSqlite3Vtab; nArg: i32;
  zName: PAnsiChar; pxFunc: PPointer; ppArg: PPointer): i32; cdecl;
begin
  if sqlite3StrICmp('zipfile_cds', zName) = 0 then begin
    pxFunc^ := @zipfileFunctionCds;
    ppArg^ := pVtab;
    Result := 1;
    Exit;
  end;
  Result := 0;
end;

{ ----- aggregate function ----------------------------------------- }

function zipfileBufferGrow(pBuf: PZipfileBuffer; nByte: i64): i32;
var
  aNew: PByte;
  nNew: i64;
  nReq: i64;
begin
  if (pBuf^.n + nByte) > pBuf^.nAlloc then begin
    if pBuf^.n <> 0 then nNew := i64(pBuf^.n) * 2 else nNew := 512;
    nReq := i64(pBuf^.n) + nByte;
    while nNew < nReq do nNew := nNew * 2;
    aNew := PByte(sqlite3_realloc64(pBuf^.a, u64(nNew)));
    if aNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    pBuf^.a := aNew;
    pBuf^.nAlloc := i32(nNew);
  end;
  Result := SQLITE_OK;
end;

procedure zipfileStep(pCtx: Psqlite3_context;
  nVal: i32; apVal: PPMem); cdecl;
var
  p: PZipfileCtx;
  e: TZipfileEntry;
  pName, pMode, pMtime, pData, pMethod: PMem;
  bIsDir: i32;
  mode: u32;
  rc: i32;
  zErr: PAnsiChar;
  iMethod: i32;
  aData: PByte;
  nData, szUncompressed, nOut: i32;
  aFree: PByte;
  iCrc32: u32;
  zName: PAnsiChar;
  nName: i32;
  zFree: PAnsiChar;
  nByte: i64;
  s: AnsiString;
label
  zipfile_step_out;
begin
  pName := nil; pMode := nil; pMtime := nil; pData := nil; pMethod := nil;
  bIsDir := 0; mode := 0; rc := SQLITE_OK; zErr := nil;
  iMethod := -1;
  aData := nil; nData := 0; szUncompressed := 0; aFree := nil; iCrc32 := 0;
  zName := nil; nName := 0; zFree := nil;

  FillChar(e, SizeOf(e), 0);
  p := PZipfileCtx(sqlite3_aggregate_context(pCtx, SizeOf(TZipfileCtx)));
  if p = nil then Exit;

  if (nVal <> 2) and (nVal <> 4) and (nVal <> 5) then begin
    s := 'wrong number of arguments to function zipfile()';
    zErr := sqlite3StrDup(PAnsiChar(s));
    rc := SQLITE_ERROR;
    goto zipfile_step_out;
  end;
  pName := apVal[0];
  if nVal = 2 then begin
    pData := apVal[1];
  end else begin
    pMode  := apVal[1];
    pMtime := apVal[2];
    pData  := apVal[3];
    if nVal = 5 then pMethod := apVal[4];
  end;

  zName := PAnsiChar(sqlite3_value_text(pName));
  nName := sqlite3_value_bytes(pName);
  if zName = nil then begin
    s := 'first argument to zipfile() must be non-NULL';
    zErr := sqlite3StrDup(PAnsiChar(s));
    rc := SQLITE_ERROR;
    goto zipfile_step_out;
  end;
  if nName > ZIPFILE_MX_NAME then begin
    s := Format('filename argument to zipfile() too big; max: %d bytes',
      [ZIPFILE_MX_NAME]);
    zErr := sqlite3StrDup(PAnsiChar(s));
    rc := SQLITE_ERROR;
    goto zipfile_step_out;
  end;

  if (pMethod <> nil) and (sqlite3_value_type(pMethod) <> SQLITE_NULL) then
  begin
    iMethod := i32(sqlite3_value_int64(pMethod));
    if (iMethod <> 0) and (iMethod <> 8) then begin
      s := Format('illegal method value: %d', [iMethod]);
      zErr := sqlite3StrDup(PAnsiChar(s));
      rc := SQLITE_ERROR;
      goto zipfile_step_out;
    end;
  end;

  if sqlite3_value_type(pData) = SQLITE_NULL then begin
    bIsDir := 1;
    iMethod := 0;
  end else begin
    aData := PByte(sqlite3_value_blob(pData));
    nData := sqlite3_value_bytes(pData);
    szUncompressed := nData;
    iCrc32 := u32(zlib_crc32(0, aData, cuint(nData)));
    if (iMethod < 0) or (iMethod = 8) then begin
      rc := zipfileDeflate(aData, nData, aFree, nOut, @zErr);
      if rc <> SQLITE_OK then goto zipfile_step_out;
      if (iMethod = 8) or (nOut < nData) then begin
        aData := aFree;
        nData := nOut;
        iMethod := 8;
      end else
        iMethod := 0;
    end;
  end;

  rc := zipfileGetMode(pMode, bIsDir, @mode, @zErr);
  if rc <> 0 then goto zipfile_step_out;

  e.mUnixTime := zipfileGetTime(pMtime);

  if bIsDir = 0 then begin
    if (nName > 0) and (zName[nName - 1] = '/') then begin
      s := 'non-directory name must not end with /';
      zErr := sqlite3StrDup(PAnsiChar(s));
      rc := SQLITE_ERROR;
      goto zipfile_step_out;
    end;
  end else begin
    if (nName = 0) or (zName[nName - 1] <> '/') then begin
      s := Format('%s/', [StrPas(zName)]);
      zFree := sqlite3StrDup(PAnsiChar(s));
      zName := zFree;
      if zName = nil then begin
        rc := SQLITE_NOMEM;
        goto zipfile_step_out;
      end;
      nName := i32(strlenC(zName));
    end else begin
      while (nName > 1) and (zName[nName - 2] = '/') do Dec(nName);
    end;
  end;

  e.cds.iVersionMadeBy  := ZIPFILE_NEWENTRY_MADEBY;
  e.cds.iVersionExtract := ZIPFILE_NEWENTRY_REQUIRED;
  e.cds.flags           := ZIPFILE_NEWENTRY_FLAGS;
  e.cds.iCompression    := u16(iMethod);
  zipfileMtimeToDos(@e.cds, e.mUnixTime);
  e.cds.crc32_         := iCrc32;
  e.cds.szCompressed   := u32(nData);
  e.cds.szUncompressed := u32(szUncompressed);
  e.cds.iExternalAttr  := mode shl 16;
  e.cds.iOffset        := u32(p^.body.n);
  e.cds.nFile          := u16(nName);
  e.cds.zFile          := zName;

  nByte := ZIPFILE_LFH_FIXED_SZ + e.cds.nFile + 9;
  rc := zipfileBufferGrow(@p^.body, nByte);
  if rc <> 0 then goto zipfile_step_out;
  Inc(p^.body.n, zipfileSerializeLFH(@e, p^.body.a + p^.body.n));

  if nData > 0 then begin
    rc := zipfileBufferGrow(@p^.body, nData);
    if rc <> 0 then goto zipfile_step_out;
    Move(aData^, (p^.body.a + p^.body.n)^, nData);
    Inc(p^.body.n, nData);
  end;

  nByte := ZIPFILE_CDS_FIXED_SZ + e.cds.nFile + 9;
  rc := zipfileBufferGrow(@p^.cds, nByte);
  if rc <> 0 then goto zipfile_step_out;
  Inc(p^.cds.n, zipfileSerializeCDS(@e, p^.cds.a + p^.cds.n));

  Inc(p^.nEntry);

zipfile_step_out:
  if aFree <> nil then sqlite3_free(aFree);
  if zFree <> nil then sqlite3_free(zFree);
  if rc <> 0 then begin
    if zErr <> nil then
      sqlite3_result_error(pCtx, zErr, -1)
    else
      sqlite3_result_error_code(pCtx, rc);
  end;
  if zErr <> nil then sqlite3_free(zErr);
end;

procedure zipfileFinal(pCtx: Psqlite3_context); cdecl;
var
  p: PZipfileCtx;
  eocd: ZipfileEOCD;
  nZip: i64;
  aZip: PByte;
begin
  p := PZipfileCtx(sqlite3_aggregate_context(pCtx, SizeOf(TZipfileCtx)));
  if p = nil then Exit;
  if p^.nEntry > 0 then begin
    FillChar(eocd, SizeOf(eocd), 0);
    eocd.nEntry := u16(p^.nEntry);
    eocd.nEntryTotal := u16(p^.nEntry);
    eocd.nSize := u32(p^.cds.n);
    eocd.iOffset := u32(p^.body.n);
    nZip := i64(p^.body.n) + i64(p^.cds.n) + ZIPFILE_EOCD_FIXED_SZ;
    aZip := PByte(sqlite3_malloc64(u64(nZip)));
    if aZip = nil then
      sqlite3_result_error_nomem(pCtx)
    else begin
      Move(p^.body.a^, aZip^, p^.body.n);
      Move(p^.cds.a^, (aZip + p^.body.n)^, p^.cds.n);
      zipfileSerializeEOCD(@eocd, aZip + p^.body.n + p^.cds.n);
      sqlite3_result_blob(pCtx, aZip, i32(nZip), @zipfileFree);
    end;
  end;
  if p^.body.a <> nil then sqlite3_free(p^.body.a);
  if p^.cds.a <> nil then sqlite3_free(p^.cds.a);
end;

{ ----- module + init ---------------------------------------------- }

var
  zipfileModule: Tsqlite3_module;

function sqlite3ZipfileInit(db: PTsqlite3): i32;
var rc: i32;
begin
  zipfileModule.iVersion      := 1;
  zipfileModule.xCreate       := @zipfileConnect;
  zipfileModule.xConnect      := @zipfileConnect;
  zipfileModule.xBestIndex    := @zipfileBestIndex;
  zipfileModule.xDisconnect   := @zipfileDisconnect;
  zipfileModule.xDestroy      := @zipfileDisconnect;
  zipfileModule.xOpen         := @zipfileOpen;
  zipfileModule.xClose        := @zipfileClose;
  zipfileModule.xFilter       := @zipfileFilter;
  zipfileModule.xNext         := @zipfileNext;
  zipfileModule.xEof          := @zipfileEof;
  zipfileModule.xColumn       := @zipfileColumn;
  zipfileModule.xRowid        := nil;
  zipfileModule.xUpdate       := @zipfileUpdate;
  zipfileModule.xBegin        := @zipfileBegin;
  zipfileModule.xSync         := nil;
  zipfileModule.xCommit       := @zipfileCommit;
  zipfileModule.xRollback     := @zipfileRollback;
  zipfileModule.xFindFunction := @zipfileFindFunction;
  zipfileModule.xRename       := nil;
  zipfileModule.xSavepoint    := nil;
  zipfileModule.xRelease      := nil;
  zipfileModule.xRollbackTo   := nil;
  zipfileModule.xShadowName   := nil;
  zipfileModule.xIntegrity    := nil;

  rc := sqlite3_create_module(db, 'zipfile', @zipfileModule, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_overload_function(db, 'zipfile_cds', -1);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'zipfile', -1, SQLITE_UTF8, nil,
      nil, @zipfileStep, @zipfileFinal);
  Result := rc;
end;

end.
