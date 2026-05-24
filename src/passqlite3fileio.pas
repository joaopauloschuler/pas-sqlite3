{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/fileio.c (1234 lines in C).

  Provides the SQL functions readfile(X), writefile(F,D[,M[,T]]),
  lsmode(M), realpath(X), and the eponymous fsdir(D[,B[,L]]) virtual
  table for recursively walking a directory tree.

  WRITEFILE:  writes blob D to file F.  Optional MODE selects between
  regular file / symlink / directory; optional MTIME sets the file's
  last-modification time via utimes(2).

  FSDIR:      one row per filesystem entry under the given root, with
  columns (name, mode, mtime, data, level, path HIDDEN, dir HIDDEN).

  Public entry: sqlite3FileioInit(db) — equivalent to
  sqlite3_fileio_init() in C.  Auto-installed by passqlite3shell.

  Pascal-port adaptations:
    - Windows arms of fileio.c are entirely omitted (Linux-only port).
    - sqlite3_vmprintf / va_list-based ctxErrorMsg / fsdirSetErrmsg
      replaced by SysUtils.Format → sqlite3StrDup, mirroring the
      pattern already established in passqlite3csv / passqlite3scrub.
    - utimes(2) bound directly via libc (BaseUnix exposes only
      utime(2) through FpUtime which lacks usec precision).
    - DIR / dirent / stat all surfaced through BaseUnix.
}
{$I passqlite3.inc}
unit passqlite3fileio;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3FileioInit(db: PTsqlite3): i32;

implementation

uses
  SysUtils, BaseUnix, UnixType;

const
  SEEK_END = 2;
  SEEK_SET = 0;

  { POSIX file-type masks (matching <sys/stat.h> on Linux). }
  S_IFMT_  = $F000;
  S_IFREG_ = $8000;
  S_IFDIR_ = $4000;
  S_IFLNK_ = $A000;

  FSDIR_COLUMN_NAME  = 0;
  FSDIR_COLUMN_MODE  = 1;
  FSDIR_COLUMN_MTIME = 2;
  FSDIR_COLUMN_DATA  = 3;
  FSDIR_COLUMN_LEVEL = 4;
  FSDIR_COLUMN_PATH  = 5;
  FSDIR_COLUMN_DIR   = 6;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

const
  dotPath: PAnsiChar = '.';

{ ----- libc bindings (only what BaseUnix doesn't already expose) ----- }

type
  TUtTimeVal = record
    tv_sec  : i64;
    tv_usec : i64;
  end;
  PUtTimeVal = ^TUtTimeVal;

function libc_utimes(path: PAnsiChar; times: PUtTimeVal): i32; cdecl;
  external 'c' name 'utimes';
function libc_realpath(path: PAnsiChar; resolved: PAnsiChar): PAnsiChar; cdecl;
  external 'c' name 'realpath';
function libc_time(t: Pi64): i64; cdecl;
  external 'c' name 'time';

{ Convenience helpers. }
function isDir(m: i32): Boolean; inline;
begin
  Result := (m and S_IFMT_) = S_IFDIR_;
end;

function isReg(m: i32): Boolean; inline;
begin
  Result := (m and S_IFMT_) = S_IFREG_;
end;

function isLnk(m: i32): Boolean; inline;
begin
  Result := (m and S_IFMT_) = S_IFLNK_;
end;

{ ===================================================================
  fileio.c:168..203 — readFileContents.

  Set the result of context ctx to a blob containing the contents of
  file zName.  Leaves the result NULL if the file cannot be opened.
  Throws SQLITE_TOOBIG if the file size exceeds the connection's
  LENGTH limit; SQLITE_IOERR if the read short-counts.
  =================================================================== }
procedure readFileContents(ctx: Psqlite3_context; zName: PAnsiChar);
var
  inF    : PFILE;
  nIn    : i64;
  pBuf   : Pointer;
  db     : PTsqlite3;
  mxBlob : i32;
begin
  inF := libc_fopen(zName, 'rb');
  if inF = nil then Exit;
  libc_fseek(inF, 0, SEEK_END);
  nIn := libc_ftell(inF);
  libc_rewind(inF);
  db := sqlite3_context_db_handle(ctx);
  mxBlob := sqlite3_limit(db, 0, -1); { SQLITE_LIMIT_LENGTH = 0 }
  if nIn > mxBlob then begin
    sqlite3_result_error_code(ctx, 18); { SQLITE_TOOBIG }
    libc_fclose(inF);
    Exit;
  end;
  if nIn <> 0 then
    pBuf := sqlite3_malloc64(u64(nIn))
  else
    pBuf := sqlite3_malloc64(1);
  if pBuf = nil then begin
    sqlite3_result_error_nomem(ctx);
    libc_fclose(inF);
    Exit;
  end;
  if (nIn = 0) or
     (i64(libc_fread(pBuf, 1, NativeUInt(nIn), inF)) = nIn) then
    sqlite3_result_blob64(ctx, pBuf, u64(nIn), SQLITE_DYNAMIC)
  else begin
    sqlite3_result_error_code(ctx, SQLITE_IOERR);
    sqlite3_free(pBuf);
  end;
  libc_fclose(inF);
end;

{ fileio.c:210..220 — readfile(X). }
procedure readfileFunc(context: Psqlite3_context; argc: i32;
  argv: PPsqlite3_value); cdecl;
var zName: PAnsiChar;
begin
  if argc = 0 then Exit;
  zName := PAnsiChar(sqlite3_value_text(argv[0]));
  if zName = nil then Exit;
  readFileContents(context, zName);
end;

{ fileio.c:226..234 — ctxErrorMsg.  Pascal port: SysUtils.Format then
  sqlite3_result_error.  The C variadic surface is collapsed to a
  single args array. }
procedure ctxErrorMsg(ctx: Psqlite3_context; const fmt: AnsiString;
  const args: array of const);
var msg: AnsiString;
begin
  msg := SysUtils.Format(fmt, args);
  sqlite3_result_error(ctx, PAnsiChar(msg), -1);
end;

{ fileio.c:269..295 — fileStat.  On Linux this is just stat(2). }
function fileStat(zPath: PAnsiChar; var sb: Stat): i32;
begin
  Result := FpStat(zPath, sb);
end;

{ fileio.c:302..311 — fileLinkStat. }
function fileLinkStat(zPath: PAnsiChar; var sb: Stat): i32;
begin
  Result := fpLstat(zPath, @sb);
end;

{ fileio.c:324..358 — makeDirectory.

  Walk zFile component-by-component; mkdir() each parent directory
  that does not already exist.  Returns SQLITE_OK / SQLITE_NOMEM /
  SQLITE_ERROR. }
function makeDirectory(zFile: PAnsiChar): i32;
var
  zCopy : PAnsiChar;
  rc    : i32;
  nCopy : i32;
  i     : i32;
  sb    : Stat;
  rc2   : i32;
begin
  zCopy := PAnsiChar(sqlite3StrDup(zFile));
  rc := SQLITE_OK;
  if zCopy = nil then begin
    Result := SQLITE_NOMEM;
    Exit;
  end;
  nCopy := i32(StrLen(zCopy));
  i := 1;
  while rc = SQLITE_OK do begin
    while (i < nCopy) and (zCopy[i] <> '/') do Inc(i);
    if i = nCopy then Break;
    zCopy[i] := #0;
    rc2 := fileStat(zCopy, sb);
    if rc2 <> 0 then begin
      if FpMkdir(zCopy, $1FF) <> 0 then rc := SQLITE_ERROR;
    end else begin
      if not isDir(sb.st_mode) then rc := SQLITE_ERROR;
    end;
    zCopy[i] := '/';
    Inc(i);
  end;
  sqlite3_free(zCopy);
  Result := rc;
end;

{ fileio.c:364..479 — writeFile.

  Returns:
    0   success
    1   open / mkdir / chmod / utimes failed but writeFile-style retry
        via makeDirectory may help
    2   subsequent-stage failure (data write succeeded but chmod/etc
        failed) — caller treats as fatal. }
function writeFile(pCtx: Psqlite3_context; zFile: PAnsiChar;
  pData: Psqlite3_value; mode: i32; mtime: i64): i32;
var
  zTo    : PAnsiChar;
  sb     : Stat;
  nWrite : i64;
  z      : PAnsiChar;
  rc     : i32;
  outF   : PFILE;
  n      : i64;
  nBytes : i32;
  times  : array[0..1] of TUtTimeVal;
begin
  if zFile = nil then begin Result := 1; Exit; end;

  if isLnk(mode) then begin
    zTo := PAnsiChar(sqlite3_value_text(pData));
    if zTo = nil then begin Result := 1; Exit; end;
    FpUnlink(zFile);
    if fpSymlink(zTo, zFile) < 0 then begin Result := 1; Exit; end;
  end else if isDir(mode) then begin
    if FpMkdir(zFile, mode) <> 0 then begin
      { mkdir failure is OK if the directory already exists with the
        same permission bits (or chmod can fix them up). }
      if (fpgeterrno <> ESysEEXIST)
         or (fileStat(zFile, sb) <> 0)
         or (not isDir(sb.st_mode))
         or ((((sb.st_mode and $1FF) <> (mode and $1FF))
              and (FpChmod(zFile, mode and $1FF) <> 0))) then
      begin
        Result := 1;
        Exit;
      end;
    end;
  end else begin
    nWrite := 0;
    rc := 0;
    outF := libc_fopen(zFile, 'wb');
    if outF = nil then begin Result := 1; Exit; end;
    z := PAnsiChar(sqlite3_value_blob(pData));
    if z <> nil then begin
      nBytes := sqlite3_value_bytes(pData);
      n := i64(libc_fwrite(z, 1, NativeUInt(nBytes), outF));
      nWrite := nBytes;
      if nWrite <> n then rc := 1;
    end;
    libc_fclose(outF);
    if (rc = 0) and (mode <> 0) and (FpChmod(zFile, mode and $1FF) <> 0) then
      rc := 1;
    if rc <> 0 then begin Result := 2; Exit; end;
    sqlite3_result_int64(pCtx, nWrite);
  end;

  if mtime >= 0 then begin
    if not isLnk(mode) then begin
      times[0].tv_usec := 0; times[1].tv_usec := 0;
      times[0].tv_sec  := libc_time(nil);
      times[1].tv_sec  := mtime;
      if libc_utimes(zFile, @times[0]) <> 0 then begin
        Result := 1;
        Exit;
      end;
    end;
  end;

  Result := 0;
end;

{ fileio.c:485..527 — writefileFunc. }
procedure writefileFunc(context: Psqlite3_context; argc: i32;
  argv: PPsqlite3_value); cdecl;
var
  zFile : PAnsiChar;
  mode  : i32;
  res   : i32;
  mtime : i64;
begin
  if (argc < 2) or (argc > 4) then begin
    sqlite3_result_error(context,
      'wrong number of arguments to function writefile()', -1);
    Exit;
  end;
  zFile := PAnsiChar(sqlite3_value_text(argv[0]));
  if zFile = nil then Exit;
  mode := 0;
  mtime := -1;
  if argc >= 3 then mode := sqlite3_value_int(argv[2]);
  if argc = 4 then mtime := sqlite3_value_int64(argv[3]);

  res := writeFile(context, zFile, argv[1], mode, mtime);
  if (res = 1) and (fpgeterrno = ESysENOENT) then begin
    if makeDirectory(zFile) = SQLITE_OK then
      res := writeFile(context, zFile, argv[1], mode, mtime);
  end;

  if (argc > 2) and (res <> 0) then begin
    if isLnk(mode) then
      ctxErrorMsg(context, 'failed to create symlink: %s', [zFile])
    else if isDir(mode) then
      ctxErrorMsg(context, 'failed to create directory: %s', [zFile])
    else
      ctxErrorMsg(context, 'failed to write file: %s', [zFile]);
  end;
end;

{ fileio.c:535..562 — lsmode(M).  Render an ls(1) -l style mode string. }
procedure lsModeFunc(context: Psqlite3_context; argc: i32;
  argv: PPsqlite3_value); cdecl;
var
  i, m  : i32;
  iMode : i32;
  z     : array[0..15] of AnsiChar;
begin
  if argc = 0 then Exit;
  iMode := sqlite3_value_int(argv[0]);
  if isLnk(iMode) then z[0] := 'l'
  else if isReg(iMode) then z[0] := '-'
  else if isDir(iMode) then z[0] := 'd'
  else z[0] := '?';
  for i := 0 to 2 do begin
    m := iMode shr ((2 - i) * 3);
    if (m and 4) <> 0 then z[1 + i*3] := 'r' else z[1 + i*3] := '-';
    if (m and 2) <> 0 then z[2 + i*3] := 'w' else z[2 + i*3] := '-';
    if (m and 1) <> 0 then z[3 + i*3] := 'x' else z[3 + i*3] := '-';
  end;
  z[10] := #0;
  sqlite3_result_text(context, @z[0], -1, SQLITE_TRANSIENT);
end;

{ ===================================================================
  fileio.c:572..1052 — fsdir virtual table.
  =================================================================== }

type
  PFsdirLevel = ^TFsdirLevel;
  TFsdirLevel = record
    pDir : pDir;        { from FpOpendir }
    zDir : PAnsiChar;   { sqlite3_malloc'd directory name }
  end;

  PFsdirCursor = ^TFsdirCursor;
  TFsdirCursor = record
    base    : Tsqlite3_vtab_cursor;
    nLvl    : i32;
    mxLvl   : i32;
    iLvl    : i32;
    aLvl    : PFsdirLevel;
    zBase   : PAnsiChar;
    nBase   : i32;
    sStat   : Stat;
    zPath   : PAnsiChar;
    iRowid  : i64;
  end;

  PFsdirTab = ^TFsdirTab;
  TFsdirTab = record
    base : Tsqlite3_vtab;
  end;

var
  fsdirModule: Tsqlite3_module;

const
  FSDIR_SCHEMA = 'CREATE TABLE x(name,mode,mtime,data,level,path HIDDEN,dir HIDDEN)';

function fsdirConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PFsdirTab;
  rc  : i32;
begin
  rc := sqlite3_declare_vtab(db, FSDIR_SCHEMA);
  if rc = SQLITE_OK then begin
    pNew := PFsdirTab(sqlite3_malloc64(SizeOf(TFsdirTab)));
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(TFsdirTab), 0);
    sqlite3_vtab_config(db, SQLITE_VTAB_DIRECTONLY, 0);
    ppVtab^ := PSqlite3Vtab(pNew);
  end;
  Result := rc;
end;

function fsdirDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

function fsdirOpen(p: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PFsdirCursor;
begin
  pCur := PFsdirCursor(sqlite3_malloc64(SizeOf(TFsdirCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TFsdirCursor), 0);
  pCur^.iLvl := -1;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

procedure fsdirResetCursor(pCur: PFsdirCursor);
var
  i    : i32;
  pLvl : PFsdirLevel;
begin
  if pCur^.aLvl <> nil then begin
    i := 0;
    while i <= pCur^.iLvl do begin
      pLvl := pCur^.aLvl;
      Inc(pLvl, i);
      if pLvl^.pDir <> nil then FpClosedir(pLvl^.pDir^);
      sqlite3_free(pLvl^.zDir);
      Inc(i);
    end;
  end;
  sqlite3_free(pCur^.zPath);
  sqlite3_free(pCur^.aLvl);
  pCur^.aLvl    := nil;
  pCur^.zPath   := nil;
  pCur^.zBase   := nil;
  pCur^.nBase   := 0;
  pCur^.nLvl    := 0;
  pCur^.iLvl    := -1;
  pCur^.iRowid  := 1;
end;

function fsdirClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PFsdirCursor;
begin
  pCur := PFsdirCursor(cur);
  fsdirResetCursor(pCur);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

procedure fsdirSetErrmsg(pCur: PFsdirCursor; const fmt: AnsiString;
  const args: array of const);
var msg: AnsiString;
begin
  msg := SysUtils.Format(fmt, args);
  pCur^.base.pVtab^.zErrMsg := PAnsiChar(sqlite3StrDup(PAnsiChar(msg)));
end;

function fsdirNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur   : PFsdirCursor;
  m      : i32;
  iNew   : i32;
  pLvl   : PFsdirLevel;
  nNew   : i32;
  nByte  : i64;
  aNew   : PFsdirLevel;
  pEntry : pDirent;
  pName  : PAnsiChar;
begin
  pCur := PFsdirCursor(cur);
  m := pCur^.sStat.st_mode;
  Inc(pCur^.iRowid);

  if isDir(m) and (pCur^.iLvl + 3 < pCur^.mxLvl) then begin
    iNew := pCur^.iLvl + 1;
    if iNew >= pCur^.nLvl then begin
      nNew := iNew + 1;
      nByte := i64(nNew) * SizeOf(TFsdirLevel);
      aNew := PFsdirLevel(sqlite3_realloc64(pCur^.aLvl, u64(nByte)));
      if aNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
      FillChar(aNew[pCur^.nLvl], SizeOf(TFsdirLevel) * (nNew - pCur^.nLvl), 0);
      pCur^.aLvl := aNew;
      pCur^.nLvl := nNew;
    end;
    pCur^.iLvl := iNew;
    pLvl := pCur^.aLvl;
    Inc(pLvl, iNew);
    pLvl^.zDir := pCur^.zPath;
    pCur^.zPath := nil;
    pLvl^.pDir := FpOpendir(pLvl^.zDir);
    if pLvl^.pDir = nil then begin
      fsdirSetErrmsg(pCur, 'cannot read directory: %s', [pLvl^.zDir]);
      Result := SQLITE_ERROR;
      Exit;
    end;
  end;

  while pCur^.iLvl >= 0 do begin
    pLvl := pCur^.aLvl;
    Inc(pLvl, pCur^.iLvl);
    pEntry := FpReaddir(pLvl^.pDir^);
    if pEntry <> nil then begin
      pName := @pEntry^.d_name[0];
      { Skip "." and ".." }
      if pName[0] = '.' then begin
        if (pName[1] = '.') and (pName[2] = #0) then continue;
        if pName[1] = #0 then continue;
      end;
      sqlite3_free(pCur^.zPath);
      pCur^.zPath := PAnsiChar(sqlite3PfMprintf('%s/%s',
        [pLvl^.zDir, pName]));
      if pCur^.zPath = nil then begin Result := SQLITE_NOMEM; Exit; end;
      if fileLinkStat(pCur^.zPath, pCur^.sStat) <> 0 then begin
        fsdirSetErrmsg(pCur, 'cannot stat file: %s', [pCur^.zPath]);
        Result := SQLITE_ERROR;
        Exit;
      end;
      Result := SQLITE_OK;
      Exit;
    end;
    FpClosedir(pLvl^.pDir^);
    sqlite3_free(pLvl^.zDir);
    pLvl^.pDir := nil;
    pLvl^.zDir := nil;
    Dec(pCur^.iLvl);
  end;

  { EOF }
  sqlite3_free(pCur^.zPath);
  pCur^.zPath := nil;
  Result := SQLITE_OK;
end;

function fsdirColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: i32): i32; cdecl;
var
  pCur    : PFsdirCursor;
  m       : i32;
  aStatic : array[0..63] of AnsiChar;
  aBuf    : PAnsiChar;
  nBuf    : i64;
  rn      : i32;
begin
  pCur := PFsdirCursor(cur);
  case i of
    FSDIR_COLUMN_NAME:
      sqlite3_result_text(ctx, pCur^.zPath + pCur^.nBase, -1, SQLITE_TRANSIENT);
    FSDIR_COLUMN_MODE:
      sqlite3_result_int64(ctx, pCur^.sStat.st_mode);
    FSDIR_COLUMN_MTIME:
      sqlite3_result_int64(ctx, pCur^.sStat.st_mtime);
    FSDIR_COLUMN_DATA:
    begin
      m := pCur^.sStat.st_mode;
      if isDir(m) then
        sqlite3_result_null(ctx)
      else if isLnk(m) then begin
        aBuf := @aStatic[0];
        nBuf := 64;
        while True do begin
          rn := fpReadLink(pCur^.zPath, aBuf, NativeUInt(nBuf));
          if rn < nBuf then Break;
          if aBuf <> @aStatic[0] then sqlite3_free(aBuf);
          nBuf := nBuf * 2;
          aBuf := PAnsiChar(sqlite3_malloc64(u64(nBuf)));
          if aBuf = nil then begin
            sqlite3_result_error_nomem(ctx);
            Result := SQLITE_NOMEM;
            Exit;
          end;
        end;
        sqlite3_result_text(ctx, aBuf, rn, SQLITE_TRANSIENT);
        if aBuf <> @aStatic[0] then sqlite3_free(aBuf);
      end else
        readFileContents(ctx, pCur^.zPath);
    end;
    FSDIR_COLUMN_LEVEL:
      sqlite3_result_int(ctx, pCur^.iLvl + 2);
  else
    { FSDIR_COLUMN_PATH / FSDIR_COLUMN_DIR — input-only, NULL on read. }
  end;
  Result := SQLITE_OK;
end;

function fsdirRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PFsdirCursor;
begin
  pCur := PFsdirCursor(cur);
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

function fsdirEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PFsdirCursor;
begin
  pCur := PFsdirCursor(cur);
  if pCur^.zPath = nil then Result := 1 else Result := 0;
end;

function fsdirFilter(cur: PSqlite3VtabCursor; idxNum: i32;
  idxStr: PAnsiChar; argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  zDir : PAnsiChar;
  pCur : PFsdirCursor;
  i    : i32;
begin
  pCur := PFsdirCursor(cur);
  fsdirResetCursor(pCur);

  if idxNum = 0 then begin
    fsdirSetErrmsg(pCur, 'table function fsdir requires an argument', []);
    Result := SQLITE_ERROR;
    Exit;
  end;

  zDir := PAnsiChar(sqlite3_value_text(argv[0]));
  if zDir = nil then begin
    fsdirSetErrmsg(pCur,
      'table function fsdir requires a non-NULL argument', []);
    Result := SQLITE_ERROR;
    Exit;
  end;
  i := 1;
  if (idxNum and $02) <> 0 then begin
    pCur^.zBase := PAnsiChar(sqlite3_value_text(argv[i]));
    Inc(i);
  end;
  if (idxNum and $0C) <> 0 then begin
    pCur^.mxLvl := sqlite3_value_int(argv[i]);
    if (idxNum and $08) <> 0 then Inc(pCur^.mxLvl);
    if pCur^.mxLvl <= 0 then pCur^.mxLvl := 1000000000;
  end else
    pCur^.mxLvl := 1000000000;

  if pCur^.zBase <> nil then begin
    pCur^.nBase := i32(StrLen(pCur^.zBase)) + 1;
    pCur^.zPath := PAnsiChar(sqlite3PfMprintf('%s/%s',
      [pCur^.zBase, zDir]));
  end else
    pCur^.zPath := PAnsiChar(sqlite3PfMprintf('%s', [zDir]));

  if pCur^.zPath = nil then begin
    Result := SQLITE_NOMEM;
    Exit;
  end;
  if fileLinkStat(pCur^.zPath, pCur^.sStat) <> 0 then begin
    fsdirSetErrmsg(pCur, 'cannot stat file: %s', [pCur^.zPath]);
    Result := SQLITE_ERROR;
    Exit;
  end;
  Result := SQLITE_OK;
end;

{ fileio.c:920..1013 — fsdirBestIndex.

  idxNum bits:
    0x01  PATH supplied (argv[0])
    0x02  DIR supplied  (argv[1])
    0x04  LEVEL< n
    0x08  LEVEL<= n / LEVEL=n }
function fsdirBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i, idxPath, idxDir, idxLevel, idxLevelEQ : i32;
  omitLevel, seenPath, seenDir              : i32;
  pC                                        : PSqlite3IndexConstraint;
  pUse                                      : PSqlite3IndexConstraintUsage;
begin
  idxPath := -1; idxDir := -1; idxLevel := -1;
  idxLevelEQ := 0; omitLevel := 0; seenPath := 0; seenDir := 0;

  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if pC^.op = SQLITE_INDEX_CONSTRAINT_EQ then begin
      case pC^.iColumn of
        FSDIR_COLUMN_PATH:
          if pC^.usable <> 0 then begin
            idxPath := i; seenPath := 0;
          end else if idxPath < 0 then
            seenPath := 1;
        FSDIR_COLUMN_DIR:
          if pC^.usable <> 0 then begin
            idxDir := i; seenDir := 0;
          end else if idxDir < 0 then
            seenDir := 1;
        FSDIR_COLUMN_LEVEL:
          if (pC^.usable <> 0) and (idxLevel < 0) then begin
            idxLevel := i; idxLevelEQ := $08; omitLevel := 0;
          end;
      end;
    end else if (pC^.iColumn = FSDIR_COLUMN_LEVEL)
                and (pC^.usable <> 0) and (idxLevel < 0) then
    begin
      if pC^.op = SQLITE_INDEX_CONSTRAINT_LE then begin
        idxLevel := i; idxLevelEQ := $08; omitLevel := 1;
      end else if pC^.op = SQLITE_INDEX_CONSTRAINT_LT then begin
        idxLevel := i; idxLevelEQ := $04; omitLevel := 1;
      end;
    end;
    Inc(pC);
  end;

  if (seenPath <> 0) or (seenDir <> 0) then begin
    Result := SQLITE_CONSTRAINT;
    Exit;
  end;

  if idxPath < 0 then begin
    pIdxInfo^.idxNum := 0;
    pIdxInfo^.estimatedRows := $7FFFFFFF;
  end else begin
    pUse := pIdxInfo^.aConstraintUsage;
    Inc(pUse, idxPath);
    pUse^.omit := 1;
    pUse^.argvIndex := 1;
    pIdxInfo^.idxNum := $01;
    pIdxInfo^.estimatedCost := 1.0e9;
    i := 2;
    if idxDir >= 0 then begin
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, idxDir);
      pUse^.omit := 1;
      pUse^.argvIndex := i; Inc(i);
      pIdxInfo^.idxNum := pIdxInfo^.idxNum or $02;
      pIdxInfo^.estimatedCost := pIdxInfo^.estimatedCost / 1.0e4;
    end;
    if idxLevel >= 0 then begin
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, idxLevel);
      pUse^.omit := omitLevel;
      pUse^.argvIndex := i; Inc(i);
      pIdxInfo^.idxNum := pIdxInfo^.idxNum or idxLevelEQ;
      pIdxInfo^.estimatedCost := pIdxInfo^.estimatedCost / 1.0e4;
    end;
  end;

  Result := SQLITE_OK;
end;

function fsdirRegister(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'fsdir', @fsdirModule, nil);
end;

{ ===================================================================
  fileio.c:1059..1199 — realpath() / portable_realpath().
  =================================================================== }

function portableRealpath(zPath: PAnsiChar): PAnsiChar;
var
  zBuf : array[0..4095] of AnsiChar;
  z    : PAnsiChar;
begin
  Result := nil;
  if zPath = nil then Exit;
  z := libc_realpath(zPath, @zBuf[0]);
  if z <> nil then begin
    Result := PAnsiChar(sqlite3PfMprintf('%s', [PAnsiChar(@zBuf[0])]));
    Exit;
  end;
  z := libc_realpath(zPath, nil);
  if z <> nil then begin
    Result := PAnsiChar(sqlite3PfMprintf('%s', [z]));
    { libc realpath() with nil dest returns malloc'd memory; sqlite3_free
      is itself an alias for libc free (passqlite3os.pas:78). }
    sqlite3_free(z);
  end;
end;

procedure realpathFunc(context: Psqlite3_context; argc: i32;
  argv: PPsqlite3_value); cdecl;
var
  zPath, zCopy, zOut : PAnsiChar;
  cSep               : AnsiChar;
  len, i, j, n       : NativeUInt;
  zCombined          : PAnsiChar;
  zOutNew            : PAnsiChar;
begin
  if argc = 0 then Exit;
  zPath := PAnsiChar(sqlite3_value_text(argv[0]));
  if zPath = nil then Exit;
  if zPath[0] = #0 then zPath := dotPath;
  zCopy := PAnsiChar(sqlite3PfMprintf('%s', [zPath]));
  if zCopy = nil then Exit;
  len := StrLen(zCopy);
  while (len > 1) and (zCopy[len - 1] = '/') do Dec(len);
  zCopy[len] := #0;
  cSep := #0;
  zOut := nil;

  while True do begin
    zOut := portableRealpath(zCopy);
    zCopy[len] := cSep;
    if zOut <> nil then begin
      if cSep <> #0 then begin
        zCombined := PAnsiChar(sqlite3PfMprintf('%s%s',
          [zOut, @zCopy[len]]));
        sqlite3_free(zOut);
        zOut := zCombined;
      end;
      Break;
    end else begin
      i := len - 1;
      while i > 0 do begin
        if zCopy[i] = '/' then Break;
        Dec(i);
      end;
      if i = 0 then begin
        if zCopy[0] = '/' then begin
          zOut := zCopy;
          zCopy := nil;
        end else begin
          zOut := portableRealpath('.');
          if zOut <> nil then begin
            zOutNew := PAnsiChar(sqlite3PfMprintf('%s/%s', [zOut, zCopy]));
            sqlite3_free(zOut);
            zOut := zOutNew;
          end;
        end;
        Break;
      end;
      cSep := zCopy[i];
      zCopy[i] := #0;
      len := i;
    end;
  end;
  sqlite3_free(zCopy);

  if zOut <> nil then begin
    { Simplify any /./ or /../ that may have crept in. }
    n := StrLen(zOut);
    i := 0; j := 0;
    while i < n do begin
      if zOut[i] = '/' then begin
        if zOut[i + 1] = '/' then begin Inc(i); continue; end;
        if (zOut[i + 1] = '.') and (i + 2 < n) and (zOut[i + 2] = '/') then begin
          Inc(i, 1); continue;
        end;
        if (zOut[i + 1] = '.') and (i + 3 < n) and (zOut[i + 2] = '.')
           and (zOut[i + 3] = '/') then begin
          while (j > 0) and (zOut[j - 1] <> '/') do Dec(j);
          if j > 0 then Dec(j);
          Inc(i, 2);
          continue;
        end;
      end;
      zOut[j] := zOut[i];
      Inc(j); Inc(i);
    end;
    zOut[j] := #0;
    sqlite3_result_text(context, zOut, -1, SQLITE_DYNAMIC);
  end;
end;

{ ===================================================================
  fileio.c:1205..1234 — sqlite3_fileio_init.
  =================================================================== }

function sqlite3FileioInit(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_function(db, 'readfile', 1,
    SQLITE_UTF8 or SQLITE_DIRECTONLY, nil,
    @readfileFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'writefile', -1,
      SQLITE_UTF8 or SQLITE_DIRECTONLY, nil,
      @writefileFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'lsmode', 1, SQLITE_UTF8, nil,
      @lsModeFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := fsdirRegister(db);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'realpath', 1, SQLITE_UTF8, nil,
      @realpathFunc, nil, nil);
  Result := rc;
end;

initialization
  FillChar(fsdirModule, SizeOf(fsdirModule), 0);
  fsdirModule.iVersion    := 0;
  fsdirModule.xConnect    := @fsdirConnect;
  fsdirModule.xBestIndex  := @fsdirBestIndex;
  fsdirModule.xDisconnect := @fsdirDisconnect;
  fsdirModule.xOpen       := @fsdirOpen;
  fsdirModule.xClose      := @fsdirClose;
  fsdirModule.xFilter     := @fsdirFilter;
  fsdirModule.xNext       := @fsdirNext;
  fsdirModule.xEof        := @fsdirEof;
  fsdirModule.xColumn     := @fsdirColumn;
  fsdirModule.xRowid      := @fsdirRowid;
end.
