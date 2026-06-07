unit PasQrf;

{
  PasQrf — faithful Pascal port of the SQLite Query Result Formatter
  (QRF) utility library, /home/bpsa/app/sqlite3/ext/qrf/qrf.c (2025-10-20).

  Exposes TQrfSpec (mirrors struct sqlite3_qrf_spec, qrf.h:27) and
  sqlite3_format_query_result (qrf.c:2962).  Used by the `db format`
  Tcl sub-command (tclsqlite.c dbQrf, 2111) ported into PasTclSqlite.

  Scope: this port covers every formatting style exercised by qrf01.test
  and qrf02.test (box, column, table, markdown, list, csv, json, jobject,
  line, insert, quote, html, count, explain, eqp) plus the full text/blob/
  escape/alignment/word-wrap/screen-width machinery.  The performance-stats
  styles (stats / stats-est / stats-vm) require SQLITE_ENABLE_STMT_SCANSTATUS
  which the oracle build lacks, so they report "not available in this build"
  exactly as the upstream #ifndef path does (qrf.c:357).
}

{$mode objfpc}{$H+}
{$POINTERMATH ON}

interface

uses passqlite3types;

type
  PQrfSpec = ^TQrfSpec;
  TQrfSpec = record
    iVersion:     u8;
    eStyle:       u8;
    eEsc:         u8;
    eText:        u8;
    eTitle:       u8;
    eBlob:        u8;
    bTitles:      u8;
    bWordWrap:    u8;
    bTextJsonb:   u8;
    eDfltAlign:   u8;
    eTitleAlign:  u8;
    bSplitColumn: u8;
    bBorder:      u8;
    nWrap:        i16;
    nScreenWidth: i16;
    nLineLimit:   i16;
    nTitleLimit:  i16;
    nMultiInsert: u32;
    nCharLimit:   i32;
    nWidth:       i32;
    nAlign:       i32;
    aWidth:       PSmallInt;        { array of short int }
    aAlign:       PByte;            { array of unsigned char }
    zColumnSep:   PAnsiChar;
    zRowSep:      PAnsiChar;
    zTableName:   PAnsiChar;
    zNull:        PAnsiChar;
    xRender:      Pointer;          { unused in this port }
    xWrite:       Pointer;          { unused in this port }
    pRenderArg:   Pointer;
    pWriteArg:    Pointer;
    pzOutput:     PPChar;
  end;

const
  QRF_MAX_WIDTH    = 10000;
  QRF_MIN_WIDTH    = 0;

  QRF_STYLE_Auto      = 0;
  QRF_STYLE_Box       = 1;
  QRF_STYLE_Column    = 2;
  QRF_STYLE_Count     = 3;
  QRF_STYLE_Csv       = 4;
  QRF_STYLE_Eqp       = 5;
  QRF_STYLE_Explain   = 6;
  QRF_STYLE_Html      = 7;
  QRF_STYLE_Insert    = 8;
  QRF_STYLE_Json      = 9;
  QRF_STYLE_JObject   = 10;
  QRF_STYLE_Line      = 11;
  QRF_STYLE_List      = 12;
  QRF_STYLE_Markdown  = 13;
  QRF_STYLE_Off       = 14;
  QRF_STYLE_Quote     = 15;
  QRF_STYLE_Stats     = 16;
  QRF_STYLE_StatsEst  = 17;
  QRF_STYLE_StatsVm   = 18;
  QRF_STYLE_Table     = 19;

  QRF_TEXT_Auto    = 0;
  QRF_TEXT_Plain   = 1;
  QRF_TEXT_Sql     = 2;
  QRF_TEXT_Csv     = 3;
  QRF_TEXT_Html    = 4;
  QRF_TEXT_Tcl     = 5;
  QRF_TEXT_Json    = 6;
  QRF_TEXT_Relaxed = 7;

  QRF_BLOB_Auto    = 0;
  QRF_BLOB_Text    = 1;
  QRF_BLOB_Sql     = 2;
  QRF_BLOB_Hex     = 3;
  QRF_BLOB_Tcl     = 4;
  QRF_BLOB_Json    = 5;
  QRF_BLOB_Size    = 6;

  QRF_ESC_Auto    = 0;
  QRF_ESC_Off     = 1;
  QRF_ESC_Ascii   = 2;
  QRF_ESC_Symbol  = 3;

  QRF_SW_Auto     = 0;
  QRF_SW_Off      = 1;
  QRF_SW_On       = 2;
  QRF_Auto        = 0;
  QRF_No          = 1;
  QRF_Yes         = 2;

  QRF_ALIGN_Auto    = 0;
  QRF_ALIGN_Left    = 1;
  QRF_ALIGN_Center  = 2;
  QRF_ALIGN_Right   = 3;
  QRF_ALIGN_Top     = 4;
  QRF_ALIGN_NW      = 5;
  QRF_ALIGN_N       = 6;
  QRF_ALIGN_NE      = 7;
  QRF_ALIGN_Middle  = 8;
  QRF_ALIGN_W       = 9;
  QRF_ALIGN_C       = 10;
  QRF_ALIGN_E       = 11;
  QRF_ALIGN_Bottom  = 12;
  QRF_ALIGN_SW      = 13;
  QRF_ALIGN_S       = 14;
  QRF_ALIGN_SE      = 15;
  QRF_ALIGN_HMASK   = 3;
  QRF_ALIGN_VMASK   = 12;

function sqlite3_format_query_result(pStmt: Pointer; pSpec: PQrfSpec;
                                     pzErr: PPChar): i32;

function sqlite3_qrf_wcwidth(c: i32): i32;
function sqlite3_qrf_wcswidth(zIn: PAnsiChar): PtrUInt;

implementation

uses SysUtils, passqlite3printf, passqlite3os, passqlite3util, passqlite3main,
     passqlite3vdbe, passqlite3parser, passqlite3codegen;

type
  TQrfUW = record
    w:      u8;
    iFirst: i32;
  end;

  PQrfEQPGraphRow = ^TQrfEQPGraphRow;
  TQrfEQPGraphRow = record
    iEqpId:    i32;
    iParentId: i32;
    pNext:     PQrfEQPGraphRow;
    zText:     record end;          { variable-length text follows (zText[1]) }
  end;

  PQrfEQPGraph = ^TQrfEQPGraph;
  TQrfEQPGraph = record
    pRow:    PQrfEQPGraphRow;
    pLast:   PQrfEQPGraphRow;
    nWidth:  i32;
    zPrefix: array[0..399] of AnsiChar;
  end;

  PQrfPerCol = ^TQrfPerCol;
  TQrfPerCol = record
    z:    PAnsiChar;
    w:    i32;
    mxW:  i32;
    e:    u8;
    fx:   u8;
    bNum: u8;
  end;

  PQrf = ^TQrf;
  TQrf = record
    pStmt:       Pointer;
    db:          PTsqlite3;
    pJTrans:     Pointer;
    pzErr:       PPChar;
    pOut:        PSqlite3Str;
    iErr:        i32;
    nCol:        i32;
    expMode:     i32;
    mxWidth:     i32;
    mxHeight:    i32;
    { union members (never used simultaneously) }
    uLineMxColWth: i32;
    uLineAzCol:    PPChar;
    pGraph:        PQrfEQPGraph;
    uNIns:         u32;
    nRow:          i64;
    actualWidth:   Pi32;
    spec:          TQrfSpec;
  end;

  PQrfColData = ^TQrfColData;
  TQrfColData = record
    p:         PQrf;
    nCol:      i32;
    bMultiRow: u8;
    nMargin:   u8;
    nRow:      i64;
    nAlloc:    i64;
    n:         i64;
    az:        PPChar;
    aiWth:     Pi32;
    abNum:     PByte;
    a:         PQrfPerCol;
  end;

const
  HEXD: array[0..15] of AnsiChar = '0123456789abcdef';

  { UTF8 box-drawing characters (qrf.c:1612) }
  BOX_24:   PAnsiChar = #$e2#$94#$80;
  BOX_13:   PAnsiChar = #$e2#$94#$82;
  BOX_234:  PAnsiChar = #$e2#$94#$ac;
  BOX_124:  PAnsiChar = #$e2#$94#$b4;
  BOX_123:  PAnsiChar = #$e2#$94#$9c;
  BOX_134:  PAnsiChar = #$e2#$94#$a4;
  BOX_1234: PAnsiChar = #$e2#$94#$bc;
  BOX_R12:  PAnsiChar = #$e2#$95#$b0;
  BOX_R23:  PAnsiChar = #$e2#$95#$ad;
  BOX_R34:  PAnsiChar = #$e2#$95#$ae;
  BOX_R14:  PAnsiChar = #$e2#$95#$af;
  DBL_123:  PAnsiChar = #$e2#$95#$9e;
  DBL_134:  PAnsiChar = #$e2#$95#$a1;
  DBL_1234: PAnsiChar = #$e2#$95#$aa;
  { 10 copies (30 bytes) of BOX_24 / DBL_24 for qrfBoxLine }
  DASH_BOX: PAnsiChar = #$e2#$94#$80#$e2#$94#$80#$e2#$94#$80#$e2#$94#$80#$e2#$94#$80
                       +#$e2#$94#$80#$e2#$94#$80#$e2#$94#$80#$e2#$94#$80#$e2#$94#$80;
  DASH_DBL: PAnsiChar = #$e2#$95#$90#$e2#$95#$90#$e2#$95#$90#$e2#$95#$90#$e2#$95#$90
                       +#$e2#$95#$90#$e2#$95#$90#$e2#$95#$90#$e2#$95#$90#$e2#$95#$90;

{$i qrftables.inc}

{ ---- ctype helpers (qrf.c:105) ---- }
function qrfSpace(x: Byte): Boolean; inline; begin Result := (qrfCType[x] and 1) <> 0; end;
function qrfDigit(x: Byte): Boolean; inline; begin Result := (qrfCType[x] and 2) <> 0; end;
function qrfAlpha(x: Byte): Boolean; inline; begin Result := (qrfCType[x] and 4) <> 0; end;
function qrfAlnum(x: Byte): Boolean; inline; begin Result := (qrfCType[x] and 6) <> 0; end;

function CLen(z: PAnsiChar): PtrInt; inline;
begin
  if z = nil then Result := 0 else Result := StrLen(z);
end;

{ sqlite3_malloc64-backed string dup (the Pas sqlite3_mprintf is single-arg
  and would mis-parse '%' in column names). }
function QrfDupStr(z: PAnsiChar): PAnsiChar;
var n: PtrInt;
begin
  if z = nil then z := '';
  n := StrLen(z);
  Result := PAnsiChar(sqlite3_malloc64(u64(n) + 1));
  if Result <> nil then Move(z^, Result^, n + 1);
end;

{ ============================================================
  Error handling
  ============================================================ }
procedure qrfError(p: PQrf; iCode: i32; const zMsg: AnsiString);
begin
  p^.iErr := iCode;
  if p^.pzErr <> nil then begin
    sqlite3_free(p^.pzErr^);
    p^.pzErr^ := nil;
    if zMsg <> '' then
      p^.pzErr^ := QrfDupStr(PAnsiChar(zMsg));
  end;
end;

procedure qrfOom(p: PQrf); inline;
begin
  qrfError(p, SQLITE_NOMEM, 'out of memory');
end;

procedure qrfStrErr(p: PQrf; pStr: PSqlite3Str);
var rc: i32;
begin
  if pStr <> nil then rc := sqlite3_str_errcode(pStr) else rc := 0;
  if rc <> 0 then qrfError(p, rc, sqlite3_errstr(rc));
end;

{ ============================================================
  EXPLAIN QUERY PLAN graph (qrf.c:162)
  ============================================================ }
function RowText(pRow: PQrfEQPGraphRow): PAnsiChar; inline;
begin
  Result := PAnsiChar(PtrUInt(pRow) + SizeOf(TQrfEQPGraphRow));
end;

procedure qrfEqpAppend(p: PQrf; iEqpId, p2: i32; zText: PAnsiChar);
var pNew: PQrfEQPGraphRow; nText: PtrInt;
begin
  if zText = nil then Exit;
  if p^.pGraph = nil then begin
    p^.pGraph := PQrfEQPGraph(sqlite3_malloc64(SizeOf(TQrfEQPGraph)));
    if p^.pGraph = nil then begin qrfOom(p); Exit; end;
    FillChar(p^.pGraph^, SizeOf(TQrfEQPGraph), 0);
  end;
  nText := StrLen(zText);
  pNew := PQrfEQPGraphRow(sqlite3_malloc64(SizeOf(TQrfEQPGraphRow) + u64(nText) + 1));
  if pNew = nil then begin qrfOom(p); Exit; end;
  pNew^.iEqpId := iEqpId;
  pNew^.iParentId := p2;
  Move(zText^, RowText(pNew)^, nText + 1);
  pNew^.pNext := nil;
  if p^.pGraph^.pLast <> nil then
    p^.pGraph^.pLast^.pNext := pNew
  else
    p^.pGraph^.pRow := pNew;
  p^.pGraph^.pLast := pNew;
end;

procedure qrfEqpReset(p: PQrf);
var pRow, pNext: PQrfEQPGraphRow;
begin
  if p^.pGraph <> nil then begin
    pRow := p^.pGraph^.pRow;
    while pRow <> nil do begin
      pNext := pRow^.pNext;
      sqlite3_free(pRow);
      pRow := pNext;
    end;
    sqlite3_free(p^.pGraph);
    p^.pGraph := nil;
  end;
end;

function qrfEqpNextRow(p: PQrf; iEqpId: i32; pOld: PQrfEQPGraphRow): PQrfEQPGraphRow;
var pRow: PQrfEQPGraphRow;
begin
  if pOld <> nil then pRow := pOld^.pNext else pRow := p^.pGraph^.pRow;
  while (pRow <> nil) and (pRow^.iParentId <> iEqpId) do pRow := pRow^.pNext;
  Result := pRow;
end;

procedure qrfEqpRenderLevel(p: PQrf; iEqpId: i32);
var pRow, pNext: PQrfEQPGraphRow; n: PtrInt; z, branch: PAnsiChar;
begin
  n := StrLen(@p^.pGraph^.zPrefix[0]);
  pRow := qrfEqpNextRow(p, iEqpId, nil);
  while pRow <> nil do begin
    pNext := qrfEqpNextRow(p, iEqpId, pRow);
    z := RowText(pRow);
    if pNext <> nil then branch := '|--' else branch := '`--';
    sqlite3_str_appendf(p^.pOut, '%s%s%s'#10,
        [@p^.pGraph^.zPrefix[0], branch, z]);
    if n < i64(SizeOf(p^.pGraph^.zPrefix)) - 7 then begin
      if pNext <> nil then
        Move(PAnsiChar('|  ')^, p^.pGraph^.zPrefix[n], 4)
      else
        Move(PAnsiChar('   ')^, p^.pGraph^.zPrefix[n], 4);
      qrfEqpRenderLevel(p, pRow^.iEqpId);
      p^.pGraph^.zPrefix[n] := #0;
    end;
    pRow := pNext;
  end;
end;

procedure qrfApproxInt64(pOut: PSqlite3Str; N: i64);
const aSuffix: array[0..5] of AnsiChar = ('K','M','G','T','P','E');
var i, n2: i32;
begin
  if N < 0 then begin
    if N = Low(i64) then N := High(i64) else N := -N;
    sqlite3_str_append(pOut, '-', 1);
  end;
  if N < 10000 then begin
    sqlite3_str_appendf(pOut, '%4lld ', [N]);
    Exit;
  end;
  for i := 1 to 18 do begin
    N := (N + 5) div 10;
    if N < 10000 then begin
      n2 := i32(N);
      case i mod 3 of
        0: sqlite3_str_appendf(pOut, '%d.%02d', [n2 div 1000, (n2 mod 1000) div 10]);
        1: sqlite3_str_appendf(pOut, '%2d.%d', [n2 div 100, (n2 mod 100) div 10]);
        2: sqlite3_str_appendf(pOut, '%4d', [n2 div 10]);
      end;
      sqlite3_str_append(pOut, @aSuffix[i div 3], 1);
      Break;
    end;
  end;
end;

procedure qrfEqpRender(p: PQrf; nCycle: i64);
var pRow: PQrfEQPGraphRow; nSp: i32;
begin
  if (p^.pGraph <> nil) and (p^.pGraph^.pRow <> nil) then begin
    pRow := p^.pGraph^.pRow;
    if RowText(pRow)[0] = '-' then begin
      if pRow^.pNext = nil then begin
        qrfEqpReset(p);
        Exit;
      end;
      sqlite3_str_appendf(p^.pOut, '%s'#10, [RowText(pRow) + 3]);
      p^.pGraph^.pRow := pRow^.pNext;
      sqlite3_free(pRow);
    end else if nCycle > 0 then begin
      nSp := p^.pGraph^.nWidth - 2;
      if p^.spec.eStyle = QRF_STYLE_StatsEst then begin
        sqlite3_str_appendchar(p^.pOut, nSp, ' ');
        sqlite3_str_appendall(p^.pOut, 'Cycles      Loops  (est)  Rows   (est)'#10);
        sqlite3_str_appendchar(p^.pOut, nSp, ' ');
        sqlite3_str_appendall(p^.pOut, '----------  ------------  ------------'#10);
      end else begin
        sqlite3_str_appendchar(p^.pOut, nSp, ' ');
        sqlite3_str_appendall(p^.pOut, 'Cycles      Loops  Rows '#10);
        sqlite3_str_appendchar(p^.pOut, nSp, ' ');
        sqlite3_str_appendall(p^.pOut, '----------  -----  -----'#10);
      end;
      sqlite3_str_appendall(p^.pOut, 'QUERY PLAN');
      sqlite3_str_appendchar(p^.pOut, nSp - 10, ' ');
      qrfApproxInt64(p^.pOut, nCycle);
      sqlite3_str_appendall(p^.pOut, ' 100%'#10);
    end else begin
      sqlite3_str_appendall(p^.pOut, 'QUERY PLAN'#10);
    end;
    p^.pGraph^.zPrefix[0] := #0;
    qrfEqpRenderLevel(p, 0);
    qrfEqpReset(p);
  end;
end;

procedure qrfEqpStats(p: PQrf);
begin
  { SQLITE_ENABLE_STMT_SCANSTATUS is not compiled in this build (qrf.c:357) }
  qrfError(p, SQLITE_ERROR, 'not available in this build');
end;

{ ============================================================
  Statement / output helpers
  ============================================================ }
procedure qrfResetStmt(p: PQrf);
var rc: i32;
begin
  rc := sqlite3_reset(p^.pStmt);
  if (rc <> SQLITE_OK) and (p^.iErr = SQLITE_OK) then
    qrfError(p, rc, sqlite3_errmsg(p^.db));
end;

procedure qrfWrite(p: PQrf);
begin
  { xWrite is unused in this port (always nil from dbQrf) }
end;

{ ============================================================
  Unicode width estimation (qrf.c:565)
  ============================================================ }
function sqlite3_qrf_wcwidth(c: i32): i32;
var iFirst, iLast, iMid, cMid: i32;
begin
  if c < $300 then Exit(1);
  iFirst := 0;
  iLast := N_QRF_UWIDTH - 1;
  while iFirst < iLast - 1 do begin
    iMid := (iFirst + iLast) div 2;
    cMid := aQrfUWidth[iMid].iFirst;
    if cMid < c then
      iFirst := iMid
    else if cMid > c then
      iLast := iMid - 1
    else
      Exit(aQrfUWidth[iMid].w);
  end;
  if aQrfUWidth[iLast].iFirst > c then Exit(aQrfUWidth[iFirst].w);
  Result := aQrfUWidth[iLast].w;
end;

function qrfDecodeUtf8(z: PAnsiChar; out u: i32): i32;
var b: PByte;
begin
  b := PByte(z);
  if ((b[0] and $e0) = $c0) and ((b[1] and $c0) = $80) then begin
    u := ((b[0] and $1f) shl 6) or (b[1] and $3f);
    Exit(2);
  end;
  if ((b[0] and $f0) = $e0) and ((b[1] and $c0) = $80) and ((b[2] and $c0) = $80) then begin
    u := ((b[0] and $0f) shl 12) or ((b[1] and $3f) shl 6) or (b[2] and $3f);
    Exit(3);
  end;
  if ((b[0] and $f8) = $f0) and ((b[1] and $c0) = $80) and ((b[2] and $c0) = $80)
     and ((b[3] and $c0) = $80) then begin
    u := ((b[0] and $0f) shl 18) or ((b[1] and $3f) shl 12) or ((b[2] and $3f) shl 6)
         or (b[3] and $3f);
    Exit(4);
  end;
  u := 0;
  Result := 1;
end;

function qrfIsVt100(z: PAnsiChar): i32;
var b: PByte; i: i32;
begin
  b := PByte(z);
  if b[1] <> Ord('[') then Exit(0);
  i := 2;
  while (b[i] >= $30) and (b[i] <= $3f) do Inc(i);
  while (b[i] >= $20) and (b[i] <= $2f) do Inc(i);
  if (b[i] < $40) or (b[i] > $7e) then Exit(0);
  Result := i + 1;
end;

function sqlite3_qrf_wcswidth(zIn: PAnsiChar): PtrUInt;
var z: PByte; n: PtrUInt; k, u, len: i32;
begin
  z := PByte(zIn);
  n := 0;
  while z[0] <> 0 do begin
    if z[0] < Ord(' ') then begin
      if (z[0] = 27) then begin
        k := qrfIsVt100(PAnsiChar(z));
        if k > 0 then begin z := z + k; continue; end;
      end;
      z := z + 1;
    end else if (z[0] and $80) = 0 then begin
      Inc(n); z := z + 1;
    end else begin
      u := 0;
      len := qrfDecodeUtf8(PAnsiChar(z), u);
      z := z + len;
      n := n + sqlite3_qrf_wcwidth(u);
    end;
  end;
  Result := n;
end;

function qrfDisplayWidth(zIn: PAnsiChar; nByte: i64; pnNL: Pi32): i32;
var z, zEnd: PByte; mx, n, nNL, k, u, len: i32;
begin
  mx := 0; n := 0; nNL := 0;
  if zIn = nil then zIn := '';
  z := PByte(zIn);
  zEnd := z + nByte;
  while PtrUInt(z) < PtrUInt(zEnd) do begin
    if z[0] < Ord(' ') then begin
      if z[0] = 27 then begin
        k := qrfIsVt100(PAnsiChar(z));
        if k > 0 then begin z := z + k; continue; end;
      end;
      if z[0] = 9 then
        n := (n + 8) and (not 7)
      else if (z[0] = 10) or (z[0] = 13) then begin
        Inc(nNL);
        if n > mx then mx := n;
        n := 0;
      end;
      z := z + 1;
    end else if (z[0] and $80) = 0 then begin
      Inc(n); z := z + 1;
    end else begin
      u := 0;
      len := qrfDecodeUtf8(PAnsiChar(z), u);
      z := z + len;
      n := n + sqlite3_qrf_wcwidth(u);
    end;
  end;
  if mx > n then n := mx;
  if pnNL <> nil then pnNL^ := nNL;
  Result := n;
end;

{ Escape control chars in pStr from byte iStart onward (qrf.c:735) }
procedure qrfEscape(eEsc: i32; pStr: PSqlite3Str; iStart: i32);
var i, j, sz, nCtrl: i64; zIn, zOut: PByte; c: Byte;
begin
  zIn := PByte(sqlite3_str_value(pStr));
  if zIn = nil then Exit;
  zIn := zIn + iStart;
  nCtrl := 0;
  i := 0;
  c := zIn[i];
  while c <> 0 do begin
    if (c <= $1f) and (c <> 9) and (c <> 10)
       and ((c <> 13) or (zIn[i+1] <> 10)) then
      Inc(nCtrl);
    Inc(i); c := zIn[i];
  end;
  if nCtrl = 0 then Exit;
  sz := sqlite3_str_length(pStr) - iStart;
  if eEsc = QRF_ESC_Symbol then nCtrl := nCtrl * 2;
  sqlite3_str_appendchar(pStr, nCtrl, ' ');
  zOut := PByte(sqlite3_str_value(pStr));
  if zOut = nil then Exit;
  zOut := zOut + iStart;
  zIn := zOut + nCtrl;
  Move(zOut^, zIn^, sz);
  i := 0; j := 0;
  c := zIn[i];
  while c <> 0 do begin
    if (c > $1f) or (c = 9) or (c = 10) or ((c = 13) and (zIn[i+1] = 10)) then begin
      Inc(i); c := zIn[i]; continue;
    end;
    if i > 0 then begin
      Move(zIn^, (zOut + j)^, i);
      j := j + i;
    end;
    zIn := zIn + i + 1;
    i := -1;
    if eEsc = QRF_ESC_Symbol then begin
      zOut[j] := $e2; Inc(j);
      zOut[j] := $90; Inc(j);
      zOut[j] := $80 + c; Inc(j);
    end else begin
      zOut[j] := Ord('^'); Inc(j);
      zOut[j] := $40 + c; Inc(j);
    end;
    Inc(i); c := zIn[i];
  end;
end;

function qrfRelaxable(p: PQrf; z: PAnsiChar): Boolean;
var i, n: PtrInt; b: PByte;
begin
  b := PByte(z);
  if (b[0] = Ord('''')) or qrfSpace(b[0]) then Exit(False);
  if b[0] = 0 then
    Exit((p^.spec.zNull <> nil) and (p^.spec.zNull[0] <> #0));
  n := StrLen(z);
  if (n = 0) or (b[n-1] = Ord('''')) or qrfSpace(b[n-1]) then Exit(False);
  if (p^.spec.zNull <> nil) and (StrComp(p^.spec.zNull, z) = 0) then Exit(False);
  if (b[0] = Ord('-')) or (b[0] = Ord('+')) then i := 1 else i := 0;
  if StrComp(z + i, 'Inf') = 0 then Exit(False);
  if not qrfDigit(b[i]) then Exit(True);
  Inc(i);
  while qrfDigit(b[i]) do Inc(i);
  if b[i] = 0 then Exit(False);
  if b[i] = Ord('.') then begin
    Inc(i);
    while qrfDigit(b[i]) do Inc(i);
    if b[i] = 0 then Exit(False);
  end;
  if (b[i] = Ord('e')) or (b[i] = Ord('E')) then begin
    Inc(i);
    if (b[i] = Ord('+')) or (b[i] = Ord('-')) then Inc(i);
    if not qrfDigit(b[i]) then Exit(True);
    Inc(i);
    while qrfDigit(b[i]) do Inc(i);
  end;
  Result := b[i] <> 0;
end;

{ Append zTxt as an SQL string literal, replicating printf.c %Q (alt=False)
  and %#Q (alt=True).  %#Q uses unistr('...') with \uXXXX escapes for any
  control characters and \\ for backslash, but only when at least one
  control character is present; otherwise it degrades to plain %Q. }
procedure qrfAppendQ(pOut: PSqlite3Str; zTxt: PAnsiChar; alt: Boolean);
var z: PByte; i, nCtrl: PtrInt; c: Byte;
begin
  if zTxt = nil then begin sqlite3_str_appendall(pOut, 'NULL'); Exit; end;
  z := PByte(zTxt);
  if alt then begin
    nCtrl := 0;
    i := 0;
    while z[i] <> 0 do begin
      if z[i] <= $1f then Inc(nCtrl);
      Inc(i);
    end;
    if nCtrl = 0 then alt := False;
  end;
  if alt then sqlite3_str_appendall(pOut, 'unistr(''')
  else sqlite3_str_append(pOut, '''', 1);
  i := 0;
  while z[i] <> 0 do begin
    c := z[i];
    if alt then begin
      if c = Ord('''') then sqlite3_str_appendf(pOut, '''''', [])
      else if c = Ord('\') then sqlite3_str_append(pOut, '\\', 2)
      else if c <= $1f then begin
        if c >= $10 then sqlite3_str_appendf(pOut, '\u001%x', [i32(c and $f)])
        else sqlite3_str_appendf(pOut, '\u000%x', [i32(c and $f)]);
      end else
        sqlite3_str_append(pOut, PAnsiChar(@z[i]), 1);
    end else begin
      sqlite3_str_append(pOut, PAnsiChar(@z[i]), 1);
      if c = Ord('''') then sqlite3_str_append(pOut, '''', 1);
    end;
    Inc(i);
  end;
  if alt then sqlite3_str_appendall(pOut, ''')')
  else sqlite3_str_append(pOut, '''', 1);
end;

procedure qrfEncodeText(p: PQrf; pOut: PSqlite3Str; zTxt: PAnsiChar);
var iStart: i32; doneSql: Boolean; z: PByte; i: PtrUInt; c: Byte;
begin
  iStart := sqlite3_str_length(pOut);
  doneSql := False;
  case p^.spec.eText of
    QRF_TEXT_Relaxed:
      begin
        if qrfRelaxable(p, zTxt) then
          sqlite3_str_appendall(pOut, zTxt)
        else
          doneSql := True;   { FALLTHRU to Sql }
      end;
    QRF_TEXT_Sql: doneSql := True;
    QRF_TEXT_Csv:
      begin
        i := 0;
        while zTxt[i] <> #0 do begin
          if qrfCsvQuote[Byte(zTxt[i])] <> 0 then begin i := 0; Break; end;
          Inc(i);
        end;
        if (i = 0) or (Pos(AnsiString(p^.spec.zColumnSep), AnsiString(zTxt)) > 0) then
          sqlite3_str_appendf(pOut, '"%w"', [zTxt])
        else
          sqlite3_str_appendall(pOut, zTxt);
      end;
    QRF_TEXT_Html:
      begin
        z := PByte(zTxt);
        while z[0] <> 0 do begin
          i := 0;
          while True do begin
            c := z[i];
            if (c > Ord('>')) or ((c <> 0) and (c <> Ord('<')) and (c <> Ord('>'))
                and (c <> Ord('&')) and (c <> Ord('"')) and (c <> Ord(''''))) then
              Inc(i)
            else
              Break;
          end;
          if i > 0 then sqlite3_str_append(pOut, PAnsiChar(z), i);
          case Chr(z[i]) of
            '>': sqlite3_str_append(pOut, '&lt;', 4);
            '&': sqlite3_str_append(pOut, '&amp;', 5);
            '<': sqlite3_str_append(pOut, '&lt;', 4);
            '"': sqlite3_str_append(pOut, '&quot;', 6);
            '''': sqlite3_str_append(pOut, '&#39;', 5);
          else
            Dec(i);
          end;
          z := z + i + 1;
        end;
      end;
    QRF_TEXT_Tcl, QRF_TEXT_Json:
      begin
        z := PByte(zTxt);
        sqlite3_str_append(pOut, '"', 1);
        while z[0] <> 0 do begin
          i := 0;
          while (z[i] >= $20) and (z[i] <> Ord('\')) and (z[i] <> Ord('"')) do Inc(i);
          if i > 0 then sqlite3_str_append(pOut, PAnsiChar(z), i);
          if z[i] = 0 then Break;
          case Chr(z[i]) of
            '"':  sqlite3_str_append(pOut, '\"', 2);
            '\': sqlite3_str_append(pOut, '\\', 2);
            #8:  sqlite3_str_append(pOut, '\b', 2);
            #12: sqlite3_str_append(pOut, '\f', 2);
            #10: sqlite3_str_append(pOut, '\n', 2);
            #13: sqlite3_str_append(pOut, '\r', 2);
            #9:  sqlite3_str_append(pOut, '\t', 2);
          else
            if p^.spec.eText = QRF_TEXT_Json then
              sqlite3_str_appendf(pOut, '\u%04x', [i32(z[i])])
            else
              sqlite3_str_appendf(pOut, '\%03o', [i32(z[i])]);
          end;
          z := z + i + 1;
        end;
        sqlite3_str_append(pOut, '"', 1);
      end;
  else
    sqlite3_str_appendall(pOut, zTxt);
  end;
  if doneSql then
    qrfAppendQ(pOut, zTxt, p^.spec.eEsc <> QRF_ESC_Off);
  if p^.spec.eEsc <> QRF_ESC_Off then
    qrfEscape(p^.spec.eEsc, pOut, iStart);
end;

function qrfJsonbQuickCheck(aBlob: PByte; nBlob: i32): Boolean;
var x: Byte; i, n: i32; sz: u64;
begin
  if nBlob = 0 then Exit(False);
  x := aBlob[0] shr 4;
  if x <= 11 then Exit(nBlob = (1 + x));
  if x < 14 then n := x - 11 else n := 4 * (x - 13);
  if nBlob < 1 + n then Exit(False);
  sz := aBlob[1];
  for i := 1 to n - 1 do sz := (sz shl 8) + aBlob[i+1];
  Result := sz + n + 1 = u64(nBlob);
end;

function qrfJsonbToJson(p: PQrf; iCol: i32): PAnsiChar;
var nByte, rc: i32; pBlob: Pointer; db: PTsqlite3; pTail: PAnsiChar;
begin
  nByte := sqlite3_column_bytes(p^.pStmt, iCol);
  pBlob := sqlite3_column_blob(p^.pStmt, iCol);
  if not qrfJsonbQuickCheck(PByte(pBlob), nByte) then Exit(nil);
  if p^.pJTrans = nil then begin
    db := nil;
    rc := sqlite3_open(':memory:', @db);
    if rc <> 0 then begin sqlite3_close(db); Exit(nil); end;
    pTail := nil;
    rc := sqlite3_prepare_v2(db, 'SELECT json(?1)', -1, @p^.pJTrans, @pTail);
    if rc <> 0 then begin
      sqlite3_finalize(p^.pJTrans);
      p^.pJTrans := nil;
      sqlite3_close(db);
      Exit(nil);
    end;
  end else
    sqlite3_reset(p^.pJTrans);
  sqlite3_bind_blob(p^.pJTrans, 1, pBlob, nByte, SQLITE_STATIC);
  rc := sqlite3_step(p^.pJTrans);
  if rc = SQLITE_ROW then
    Result := sqlite3_column_text(p^.pJTrans, 0)
  else
    Result := nil;
end;

function qrfTitleLimit(zIn: PAnsiChar; N: i32): i32;
var z, zEllipsis: PByte; n2, k, u, len: i32;
begin
  z := PByte(zIn);
  n2 := 0;
  zEllipsis := nil;
  while True do begin
    if z[0] < Ord(' ') then begin
      if z[0] = 0 then begin zEllipsis := nil; Break; end
      else if z[0] = 27 then begin
        k := qrfIsVt100(PAnsiChar(z));
        if k > 0 then z := z + k else z := z + 1;  { C: only advances on vt100 }
      end
      else if z[0] = 9 then z[0] := Ord(' ')
      else if (z[0] = 10) or (z[0] = 13) then z[0] := Ord(' ')
      else z := z + 1;
    end else if (z[0] and $80) = 0 then begin
      if (n2 >= (N - 3)) and (zEllipsis = nil) then zEllipsis := z;
      if n2 = N then begin z[0] := 0; Break; end;
      Inc(n2); z := z + 1;
    end else begin
      u := 0;
      len := qrfDecodeUtf8(PAnsiChar(z), u);
      if (n2 + len > (N - 3)) and (zEllipsis = nil) then zEllipsis := z;
      if n2 + len > N then begin z[0] := 0; Break; end;
      z := z + len;
      n2 := n2 + sqlite3_qrf_wcwidth(u);
    end;
  end;
  if (zEllipsis <> nil) and (N >= 3) then Move(PAnsiChar('...')^, zEllipsis^, 4);
  Result := n2;
end;

procedure qrfRenderValue(p: PQrf; pOut: PSqlite3Str; iCol: i32);
var iStartLen, nBlob, iStart, i, j, szC, ii, w, limit, u, len: i32;
    zTxt, zJson, zVal: PAnsiChar; a: PByte; c: Byte; z: PByte;
begin
  iStartLen := sqlite3_str_length(pOut);
  case sqlite3_column_type(p^.pStmt, iCol) of
    SQLITE_INTEGER:
      sqlite3_str_appendf(pOut, '%lld', [sqlite3_column_int64(p^.pStmt, iCol)]);
    SQLITE_FLOAT:
      begin
        zTxt := sqlite3_column_text(p^.pStmt, iCol);
        sqlite3_str_appendall(pOut, zTxt);
      end;
    SQLITE_BLOB:
      begin
        zJson := nil;
        if p^.spec.bTextJsonb = QRF_Yes then
          zJson := qrfJsonbToJson(p, iCol);
        if zJson <> nil then begin
          if p^.spec.eText = QRF_TEXT_Sql then begin
            sqlite3_str_append(pOut, 'jsonb(', 6);
            qrfEncodeText(p, pOut, zJson);
            sqlite3_str_append(pOut, ')', 1);
          end else
            qrfEncodeText(p, pOut, zJson);
        end else
        case p^.spec.eBlob of
          QRF_BLOB_Hex, QRF_BLOB_Sql:
            begin
              nBlob := sqlite3_column_bytes(p^.pStmt, iCol);
              a := PByte(sqlite3_column_blob(p^.pStmt, iCol));
              if p^.spec.eBlob = QRF_BLOB_Sql then sqlite3_str_append(pOut, 'x''', 2);
              iStart := sqlite3_str_length(pOut);
              sqlite3_str_appendchar(pOut, nBlob, ' ');
              sqlite3_str_appendchar(pOut, nBlob, ' ');
              if p^.spec.eBlob = QRF_BLOB_Sql then sqlite3_str_appendchar(pOut, 1, '''');
              if sqlite3_str_errcode(pOut) <> 0 then Exit;
              zVal := sqlite3_str_value(pOut);
              i := 0; j := iStart;
              while i < nBlob do begin
                c := a[i];
                zVal[j] := HEXD[(c shr 4) and $f];
                zVal[j+1] := HEXD[c and $f];
                Inc(i); j := j + 2;
              end;
            end;
          QRF_BLOB_Tcl, QRF_BLOB_Json:
            begin
              nBlob := sqlite3_column_bytes(p^.pStmt, iCol);
              a := PByte(sqlite3_column_blob(p^.pStmt, iCol));
              if p^.spec.eBlob = QRF_BLOB_Json then szC := 6 else szC := 4;
              sqlite3_str_append(pOut, '"', 1);
              iStart := sqlite3_str_length(pOut);
              for i := szC downto 1 do sqlite3_str_appendchar(pOut, nBlob, ' ');
              sqlite3_str_appendchar(pOut, 1, '"');
              if sqlite3_str_errcode(pOut) <> 0 then Exit;
              zVal := sqlite3_str_value(pOut);
              i := 0; j := iStart;
              while i < nBlob do begin
                c := a[i];
                zVal[j] := '\';
                if szC = 4 then begin
                  zVal[j+1] := Chr(Ord('0') + ((c shr 6) and 3));
                  zVal[j+2] := Chr(Ord('0') + ((c shr 3) and 7));
                  zVal[j+3] := Chr(Ord('0') + (c and 7));
                end else begin
                  zVal[j+1] := 'u';
                  zVal[j+2] := '0';
                  zVal[j+3] := '0';
                  zVal[j+4] := HEXD[(c shr 4) and $f];
                  zVal[j+5] := HEXD[c and $f];
                end;
                Inc(i); j := j + szC;
              end;
            end;
          QRF_BLOB_Size:
            begin
              nBlob := sqlite3_column_bytes(p^.pStmt, iCol);
              sqlite3_str_appendf(pOut, '(%d-byte blob)', [nBlob]);
            end;
        else
          begin
            zTxt := sqlite3_column_text(p^.pStmt, iCol);
            qrfEncodeText(p, pOut, zTxt);
          end;
        end;
      end;
    SQLITE_NULL:
      sqlite3_str_appendall(pOut, p^.spec.zNull);
    SQLITE_TEXT:
      begin
        zTxt := sqlite3_column_text(p^.pStmt, iCol);
        qrfEncodeText(p, pOut, zTxt);
      end;
  end;
  if (p^.spec.nCharLimit > 0)
     and ((sqlite3_str_length(pOut) - iStartLen) > p^.spec.nCharLimit) then begin
    ii := 0; w := 0; limit := p^.spec.nCharLimit;
    z := PByte(sqlite3_str_value(pOut)) + iStartLen;
    if limit < 4 then limit := 4;
    while True do begin
      if z[ii] < Ord(' ') then begin
        if z[ii] = 27 then begin
          len := qrfIsVt100(PAnsiChar(z + ii));
          if len > 0 then begin ii := ii + len; continue; end;
        end;
        if z[ii] = 0 then Break;
        Inc(ii);
      end else if (z[ii] and $80) = 0 then begin
        Inc(w);
        if w > limit then Break;
        Inc(ii);
      end else begin
        u := 0;
        len := qrfDecodeUtf8(PAnsiChar(z + ii), u);
        w := w + sqlite3_qrf_wcwidth(u);
        if w > limit then Break;
        ii := ii + len;
      end;
    end;
    if w > limit then begin
      sqlite3_str_truncate(pOut, iStartLen + ii);
      sqlite3_str_append(pOut, '...', 3);
    end;
  end;
end;

procedure qrfRTrim(pOut: PSqlite3Str);
var nByte: i32; zOut: PAnsiChar;
begin
  nByte := sqlite3_str_length(pOut);
  zOut := sqlite3_str_value(pOut);
  while (nByte > 0) and (zOut[nByte-1] = ' ') do Dec(nByte);
  sqlite3_str_truncate(pOut, nByte);
end;

procedure qrfWidthPrint(p: PQrf; pOut: PSqlite3Str; w: i32; zUtf: PAnsiChar);
const mxW = 10000000;
var a: PByte; c: Byte; i, n, k, aw, u, len, x: i32;
begin
  a := PByte(zUtf);
  i := 0; n := 0;
  if w < -mxW then w := -mxW else if w > mxW then w := mxW;
  if w < 0 then aw := -w else aw := w;
  if a = nil then a := PByte(PAnsiChar(''));
  c := a[i];
  while c <> 0 do begin
    if (c and $c0) = $c0 then begin
      u := 0;
      len := qrfDecodeUtf8(PAnsiChar(a + i), u);
      x := sqlite3_qrf_wcwidth(u);
      if x + n > aw then Break;
      i := i + len; n := n + x;
    end else if c = $1b then begin
      k := qrfIsVt100(PAnsiChar(a + i));
      if k > 0 then i := i + k
      else if n >= aw then Break
      else begin Inc(n); Inc(i); end;
    end else if n >= aw then
      Break
    else begin
      Inc(n); Inc(i);
    end;
    c := a[i];
  end;
  if n >= aw then
    sqlite3_str_append(pOut, zUtf, i)
  else if w < 0 then begin
    if aw > n then sqlite3_str_appendchar(pOut, aw - n, ' ');
    sqlite3_str_append(pOut, zUtf, i);
  end else begin
    sqlite3_str_append(pOut, zUtf, i);
    if aw > n then sqlite3_str_appendchar(pOut, aw - n, ' ');
  end;
end;

procedure qrfWrapLine(zIn: PAnsiChar; w: i32; bWrap: Boolean;
                      pnThis, pnWide, piNext: Pi32);
var i, k, n, u, len, wcw: i32; z: PByte; c: Byte;
begin
  z := PByte(zIn);
  if z[0] = 0 then begin pnThis^ := 0; pnWide^ := 0; piNext^ := 0; Exit; end;
  n := 0; c := 0; i := 0;
  while n <= w do begin
    c := z[i];
    if c >= $c0 then begin
      u := 0;
      len := qrfDecodeUtf8(PAnsiChar(z + i), u);
      wcw := sqlite3_qrf_wcwidth(u);
      if wcw + n > w then Break;
      i := i + len - 1;
      n := n + wcw;
      Inc(i);
      continue;
    end;
    if c >= Ord(' ') then begin
      if n = w then Break;
      Inc(n); Inc(i);
      continue;
    end;
    if (c = 0) or (c = 10) then Break;
    if (c = 13) and (z[i+1] = 10) then begin Inc(i); c := z[i]; Break; end;
    if c = 9 then begin
      wcw := 8 - (n and 7);
      if n + wcw > w then Break;
      n := n + wcw;
      Inc(i);
      continue;
    end;
    if c = $1b then begin
      k := qrfIsVt100(PAnsiChar(z + i));
      if k > 0 then begin i := i + k - 1; Inc(i); continue; end
      else if n = w then Break
      else begin Inc(n); Inc(i); continue; end;
    end else if n = w then
      Break
    else begin
      Inc(n); Inc(i); continue;
    end;
  end;
  if c = 0 then begin pnThis^ := i; pnWide^ := n; piNext^ := i; Exit; end;
  if c = 10 then begin pnThis^ := i; pnWide^ := n; piNext^ := i + 1; Exit; end;
  if bWrap and (z[i] <> 0) and (not qrfSpace(z[i]))
     and (qrfAlnum(c) = qrfAlnum(z[i])) then begin
    k := i - 1;
    while k >= i div 2 do begin
      if qrfSpace(z[k]) then Break;
      Dec(k);
    end;
    if k < i div 2 then begin
      k := i;
      while k >= i div 2 do begin
        if (qrfAlnum(z[k-1]) <> qrfAlnum(z[k])) and ((z[k] and $c0) <> $80) then Break;
        Dec(k);
      end;
    end;
    if k >= i div 2 then begin
      i := k;
      n := qrfDisplayWidth(PAnsiChar(z), k, nil);
    end;
  end;
  pnThis^ := i;
  pnWide^ := n;
  while (zIn[i] = ' ') or (zIn[i] = #9) or (zIn[i] = #13) do Inc(i);
  piNext^ := i;
end;

procedure qrfAppendWithTabs(pOut: PSqlite3Str; zVal: PAnsiChar; nVal: i32);
var i, k, u, len: i32; col: u32; z: PByte; c: Byte; zCtrlPik: array[0..3] of AnsiChar;
begin
  i := 0; col := 0; z := PByte(zVal);
  while i < nVal do begin
    c := z[i];
    if c < Ord(' ') then begin
      sqlite3_str_append(pOut, PAnsiChar(z), i);
      nVal := nVal - i;
      z := z + i;
      i := 0;
      if c = 27 then begin
        k := qrfIsVt100(PAnsiChar(z));
        if k > 0 then begin
          sqlite3_str_append(pOut, PAnsiChar(z), k);
          z := z + k; nVal := nVal - k;
        end else begin
          col := col + 1;
          zCtrlPik[0] := #$e2; zCtrlPik[1] := #$90; zCtrlPik[2] := Chr($80 + c);
          sqlite3_str_append(pOut, @zCtrlPik[0], 3);
          z := z + 1; Dec(nVal);
        end;
      end else if c = 9 then begin
        k := 8 - (col and 7);
        sqlite3_str_appendchar(pOut, k, ' ');
        col := col + u32(k);
        z := z + 1; Dec(nVal);
      end else if (c = 13) and (nVal = 1) then begin
        z := z + 1; Dec(nVal);
      end else begin
        col := col + 1;
        zCtrlPik[0] := #$e2; zCtrlPik[1] := #$90; zCtrlPik[2] := Chr($80 + c);
        sqlite3_str_append(pOut, @zCtrlPik[0], 3);
        z := z + 1; Dec(nVal);
      end;
    end else if (c and $80) = 0 then begin
      Inc(i); Inc(col);
    end else begin
      u := 0;
      len := qrfDecodeUtf8(PAnsiChar(z + i), u);
      i := i + len;
      col := col + u32(sqlite3_qrf_wcwidth(u));
    end;
  end;
  sqlite3_str_append(pOut, PAnsiChar(z), i);
end;

procedure qrfPrintAligned(pOut: PSqlite3Str; pCol: PQrfPerCol; nVal, nWS: i32);
var eAlign: u8;
begin
  eAlign := pCol^.e and QRF_ALIGN_HMASK;
  if (eAlign = QRF_Auto) and (pCol^.bNum <> 0) then eAlign := QRF_ALIGN_Right;
  if eAlign = QRF_ALIGN_Center then begin
    sqlite3_str_appendchar(pOut, nWS div 2, ' ');
    qrfAppendWithTabs(pOut, pCol^.z, nVal);
    sqlite3_str_appendchar(pOut, nWS - nWS div 2, ' ');
  end else if eAlign = QRF_ALIGN_Right then begin
    sqlite3_str_appendchar(pOut, nWS, ' ');
    qrfAppendWithTabs(pOut, pCol^.z, nVal);
  end else begin
    qrfAppendWithTabs(pOut, pCol^.z, nVal);
    sqlite3_str_appendchar(pOut, nWS, ' ');
  end;
end;

procedure qrfColDataFree(p: PQrfColData);
var i: i64;
begin
  for i := 0 to p^.n - 1 do sqlite3_free(p^.az[i]);
  sqlite3_free(p^.az);
  sqlite3_free(p^.aiWth);
  sqlite3_free(p^.abNum);
  sqlite3_free(p^.a);
  FillChar(p^, SizeOf(p^), 0);
end;

function qrfColDataEnlarge(p: PQrfColData): Boolean;
var azData: PPChar; aiWth: Pi32; abNum: PByte;
begin
  p^.nAlloc := 2 * p^.nAlloc + 10 * p^.nCol;
  azData := PPChar(sqlite3_realloc64(p^.az, u64(p^.nAlloc) * SizeOf(PAnsiChar)));
  if azData = nil then begin qrfOom(p^.p); qrfColDataFree(p); Exit(True); end;
  p^.az := azData;
  aiWth := Pi32(sqlite3_realloc64(p^.aiWth, u64(p^.nAlloc) * SizeOf(i32)));
  if aiWth = nil then begin qrfOom(p^.p); qrfColDataFree(p); Exit(True); end;
  p^.aiWth := aiWth;
  abNum := PByte(sqlite3_realloc64(p^.abNum, u64(p^.nAlloc)));
  if abNum = nil then begin qrfOom(p^.p); qrfColDataFree(p); Exit(True); end;
  p^.abNum := abNum;
  Result := False;
end;

procedure qrfRowSeparator(pOut: PSqlite3Str; p: PQrfColData; cSep: AnsiChar);
var i: i32; useBorder: Boolean;
begin
  if p^.nCol > 0 then begin
    useBorder := p^.p^.spec.bBorder <> QRF_No;
    if useBorder then sqlite3_str_append(pOut, @cSep, 1);
    sqlite3_str_appendchar(pOut, p^.a[0].w + p^.nMargin, '-');
    for i := 1 to p^.nCol - 1 do begin
      sqlite3_str_append(pOut, @cSep, 1);
      sqlite3_str_appendchar(pOut, p^.a[i].w + p^.nMargin, '-');
    end;
    if useBorder then sqlite3_str_append(pOut, @cSep, 1);
  end;
  sqlite3_str_append(pOut, #10, 1);
end;

procedure qrfBoxLine(pOut: PSqlite3Str; N: i32; bDbl: Boolean);
const nDash = 30;
var dash: PAnsiChar;
begin
  if bDbl then dash := DASH_DBL else dash := DASH_BOX;
  N := N * 3;
  while N > nDash do begin
    sqlite3_str_append(pOut, dash, nDash);
    N := N - nDash;
  end;
  sqlite3_str_append(pOut, dash, N);
end;

procedure qrfBoxSeparator(pOut: PSqlite3Str; p: PQrfColData;
                          zSep1, zSep2, zSep3: PAnsiChar; bDbl: Boolean);
var i: i32; useBorder: Boolean;
begin
  if p^.nCol > 0 then begin
    useBorder := p^.p^.spec.bBorder <> QRF_No;
    if useBorder then sqlite3_str_appendall(pOut, zSep1);
    qrfBoxLine(pOut, p^.a[0].w + p^.nMargin, bDbl);
    for i := 1 to p^.nCol - 1 do begin
      sqlite3_str_appendall(pOut, zSep2);
      qrfBoxLine(pOut, p^.a[i].w + p^.nMargin, bDbl);
    end;
    if useBorder then sqlite3_str_appendall(pOut, zSep3);
  end;
  sqlite3_str_append(pOut, #10, 1);
end;

procedure qrfLoadAlignment(pData: PQrfColData; p: PQrf);
var i: i64; ax: u8;
begin
  for i := 0 to pData^.nCol - 1 do begin
    pData^.a[i].e := p^.spec.eDfltAlign;
    if i < p^.spec.nAlign then begin
      ax := p^.spec.aAlign[i];
      if (ax and QRF_ALIGN_HMASK) <> 0 then
        pData^.a[i].e := (ax and QRF_ALIGN_HMASK) or (pData^.a[i].e and QRF_ALIGN_VMASK);
    end else if i < p^.spec.nWidth then begin
      if p^.spec.aWidth[i] < 0 then
        pData^.a[i].e := QRF_ALIGN_Right or (pData^.a[i].e and QRF_ALIGN_VMASK);
    end;
  end;
end;

function qrfValidLayout(pData: PQrfColData; p: PQrf; nCol, nSW: i32): Pi32;
var i, nr, w, t: i32; aw: Pi32;
begin
  aw := Pi32(sqlite3_malloc64(u64(SizeOf(i32)) * nCol));
  if aw = nil then begin qrfOom(p); Exit(nil); end;
  nr := (pData^.n + nCol - 1) div nCol;
  w := 0;
  for i := 0 to pData^.n - 1 do begin
    if (i mod nr) = 0 then begin
      if i > 0 then aw[i div nr - 1] := w;
      w := pData^.aiWth[i];
    end else if pData^.aiWth[i] > w then
      w := pData^.aiWth[i];
  end;
  aw[nCol-1] := w;
  t := 0;
  for i := 0 to nCol - 1 do t := t + aw[i];
  t := t + 2 * (nCol - 1);
  if t > nSW then begin sqlite3_free(aw); Exit(nil); end;
  Result := aw;
end;

procedure qrfSplitColumn(pData: PQrfColData; p: PQrf);
var nCol, nColNext, w: i32; aw, awNew, aiWth: Pi32; az: PPChar;
    abNum: PByte; a: PQrfPerCol; nRow, i, j: i64;
begin
  nCol := 1; aw := nil; az := nil; aiWth := nil; abNum := nil; a := nil;
  nColNext := 2; nRow := 1;
  while True do begin
    awNew := qrfValidLayout(pData, p, nColNext, p^.spec.nScreenWidth);
    if awNew = nil then Break;
    sqlite3_free(aw);
    aw := awNew;
    nCol := nColNext;
    nRow := (pData^.n + nCol - 1) div nCol;
    if nRow = 1 then Break;
    Inc(nColNext);
    while (pData^.n + nColNext - 1) div nColNext = nRow do Inc(nColNext);
  end;
  if nCol = 1 then begin sqlite3_free(aw); Exit; end;
  az := PPChar(sqlite3_malloc64(u64(nRow) * nCol * SizeOf(PAnsiChar)));
  if az = nil then begin qrfOom(p); Exit; end;
  aiWth := Pi32(sqlite3_malloc64(u64(nRow) * nCol * SizeOf(i32)));
  if aiWth = nil then begin sqlite3_free(az); qrfOom(p); Exit; end;
  a := PQrfPerCol(sqlite3_malloc64(u64(nCol) * SizeOf(TQrfPerCol)));
  if a = nil then begin sqlite3_free(az); sqlite3_free(aiWth); qrfOom(p); Exit; end;
  abNum := PByte(sqlite3_malloc64(u64(nRow) * nCol));
  if abNum = nil then begin
    sqlite3_free(az); sqlite3_free(aiWth); sqlite3_free(a); qrfOom(p); Exit;
  end;
  i := 0;
  while i < pData^.n do begin
    j := (i mod nRow) * nCol + (i div nRow);
    az[j] := pData^.az[i];
    abNum[j] := pData^.abNum[i];
    pData^.az[i] := nil;
    aiWth[j] := pData^.aiWth[i];
    Inc(i);
  end;
  while i < nRow * nCol do begin
    j := (i mod nRow) * nCol + (i div nRow);
    az[j] := QrfDupStr('');
    if az[j] = nil then qrfOom(p);
    aiWth[j] := 0;
    abNum[j] := 0;
    Inc(i);
  end;
  for i := 0 to nCol - 1 do begin
    a[i].fx := 1; a[i].mxW := aw[i]; a[i].w := aw[i];
    a[i].e := pData^.a[0].e;
  end;
  sqlite3_free(pData^.az);
  sqlite3_free(pData^.aiWth);
  sqlite3_free(pData^.a);
  sqlite3_free(pData^.abNum);
  sqlite3_free(aw);
  pData^.az := az;
  pData^.aiWth := aiWth;
  pData^.a := a;
  pData^.abNum := abNum;
  pData^.nCol := nCol;
  pData^.n := nRow * nCol;
  pData^.nAlloc := nRow * nCol;
  w := 0;
  for i := 0 to nCol - 1 do w := w + a[i].w;
  pData^.nMargin := (p^.spec.nScreenWidth - w) div (nCol - 1);
  if pData^.nMargin > 5 then pData^.nMargin := 5;
end;

procedure qrfRestrictScreenWidth(pData: PQrfColData; p: PQrf);
const MIN_SQUOZE = 8; MIN_EX_SQUOZE = 16;
var sepW, sumW, targetW, i, nCol, gain, w, ix, mx: i32;
begin
  pData^.nMargin := 2;
  if p^.spec.nScreenWidth = 0 then Exit;
  if p^.spec.eStyle = QRF_STYLE_Column then
    sepW := pData^.nCol * 2 - 2
  else begin
    sepW := pData^.nCol * 3 + 1;
    if p^.spec.bBorder = QRF_No then sepW := sepW - 2;
  end;
  nCol := pData^.nCol;
  sumW := 0;
  for i := 0 to nCol - 1 do sumW := sumW + pData^.a[i].w;
  if p^.spec.nScreenWidth >= sumW + sepW then Exit;
  pData^.nMargin := 0;
  if p^.spec.eStyle = QRF_STYLE_Column then
    sepW := pData^.nCol - 1
  else begin
    sepW := pData^.nCol + 1;
    if p^.spec.bBorder = QRF_No then sepW := sepW - 2;
  end;
  targetW := p^.spec.nScreenWidth - sepW;
  while sumW > targetW do begin
    ix := -1; mx := 0;
    for i := 0 to nCol - 1 do begin
      w := pData^.a[i].w;
      if (pData^.a[i].fx = 0) and (w > mx) and (w > MIN_SQUOZE)
         and ((w > MIN_EX_SQUOZE) or (w * 2 > pData^.a[i].mxW)) then begin
        ix := i; mx := w;
      end;
    end;
    if ix < 0 then Break;
    if mx >= MIN_SQUOZE * 2 then gain := mx div 2
    else gain := mx - MIN_SQUOZE;
    if sumW - gain < targetW then gain := sumW - targetW;
    sumW := sumW - gain;
    pData^.a[ix].w := pData^.a[ix].w - gain;
    pData^.bMultiRow := 1;
  end;
end;

procedure qrfColumnar(p: PQrf);
var i, j: i64;
    colSep, rowStart, rowSep: PAnsiChar;
    szColSep, szRowSep, szRowStart, rc, nColumn, w, n, nNL, eType: i32;
    bWW, bRTrim, bMore, isTitleDataSeparator: Boolean;
    nRowLoc: i32;
    pStr: PSqlite3Str;
    data: TQrfColData;
    z, zc: PAnsiChar;
    e, saved_eText: u8;
    nThis, nWide, iNext, nWS, nE: i32;
    zSpace: PAnsiChar;
begin
  colSep := nil; rowStart := nil; rowSep := nil;
  nColumn := p^.nCol;
  rc := sqlite3_step(p^.pStmt);
  if (rc <> SQLITE_ROW) or (nColumn = 0) then Exit;
  FillChar(data, SizeOf(data), 0);
  data.nCol := p^.nCol;
  data.p := p;
  data.a := PQrfPerCol(sqlite3_malloc64(u64(nColumn) * SizeOf(TQrfPerCol)));
  if data.a = nil then begin qrfOom(p); Exit; end;
  FillChar(data.a^, u64(nColumn) * SizeOf(TQrfPerCol), 0);
  if qrfColDataEnlarge(@data) then Exit;

  if p^.spec.bTitles = QRF_Yes then begin
    saved_eText := p^.spec.eText;
    p^.spec.eText := p^.spec.eTitle;
    FillChar(data.abNum^, nColumn, 0);
    for i := 0 to nColumn - 1 do begin
      zc := sqlite3_column_name(p^.pStmt, i);
      nNL := 0;
      pStr := sqlite3_str_new(p^.db);
      if zc <> nil then qrfEncodeText(p, pStr, zc) else qrfEncodeText(p, pStr, '');
      n := sqlite3_str_length(pStr);
      qrfStrErr(p, pStr);
      z := sqlite3_str_finish(pStr);
      data.az[data.n] := z;
      if p^.spec.nTitleLimit <> 0 then begin
        nNL := 0;
        w := qrfTitleLimit(data.az[data.n], p^.spec.nTitleLimit);
        data.aiWth[data.n] := w;
      end else begin
        w := qrfDisplayWidth(z, n, @nNL);
        data.aiWth[data.n] := w;
      end;
      Inc(data.n);
      if w > data.a[i].mxW then data.a[i].mxW := w;
      if nNL <> 0 then data.bMultiRow := 1;
    end;
    p^.spec.eText := saved_eText;
    Inc(p^.nRow);
  end;

  repeat
    if data.n + nColumn > data.nAlloc then
      if qrfColDataEnlarge(@data) then Exit;
    for i := 0 to nColumn - 1 do begin
      nNL := 0;
      eType := sqlite3_column_type(p^.pStmt, i);
      pStr := sqlite3_str_new(p^.db);
      qrfRenderValue(p, pStr, i);
      n := sqlite3_str_length(pStr);
      qrfStrErr(p, pStr);
      z := sqlite3_str_finish(pStr);
      data.az[data.n] := z;
      if (eType = SQLITE_INTEGER) or (eType = SQLITE_FLOAT) then
        data.abNum[data.n] := 1 else data.abNum[data.n] := 0;
      w := qrfDisplayWidth(z, n, @nNL);
      data.aiWth[data.n] := w;
      Inc(data.n);
      if w > data.a[i].mxW then data.a[i].mxW := w;
      if nNL <> 0 then data.bMultiRow := 1;
    end;
    Inc(p^.nRow);
  until not ((sqlite3_step(p^.pStmt) = SQLITE_ROW) and (p^.iErr = SQLITE_OK));
  if p^.iErr <> 0 then begin qrfColDataFree(@data); Exit; end;

  if p^.spec.bTitles = QRF_No then
    qrfLoadAlignment(@data, p)
  else begin
    if p^.spec.eTitleAlign = QRF_Auto then e := QRF_ALIGN_Center
    else e := p^.spec.eTitleAlign;
    for i := 0 to nColumn - 1 do data.a[i].e := e;
  end;

  for i := 0 to nColumn - 1 do begin
    w := 0;
    if i < p^.spec.nWidth then begin
      w := p^.spec.aWidth[i];
      if w = -32768 then begin
        w := 0;
        if (p^.spec.nAlign > i) and ((p^.spec.aAlign[i] and QRF_ALIGN_HMASK) = 0) then
          data.a[i].e := data.a[i].e or QRF_ALIGN_Right;
      end else if w < 0 then begin
        w := -w;
        if (p^.spec.nAlign > i) and ((p^.spec.aAlign[i] and QRF_ALIGN_HMASK) = 0) then
          data.a[i].e := data.a[i].e or QRF_ALIGN_Right;
      end;
      if w <> 0 then data.a[i].fx := 1;
    end;
    if w = 0 then begin
      w := data.a[i].mxW;
      if (p^.spec.nWrap > 0) and (w > p^.spec.nWrap) then begin
        w := p^.spec.nWrap;
        data.bMultiRow := 1;
      end;
    end else if ((data.bMultiRow = 0) or (w = 1)) and (data.a[i].mxW > w) then begin
      data.bMultiRow := 1;
      if w = 1 then w := 2;
    end;
    data.a[i].w := w;
  end;

  if (nColumn = 1) and (data.n > 1) and (p^.spec.bSplitColumn = QRF_Yes)
     and (p^.spec.eStyle = QRF_STYLE_Column) and (p^.spec.bTitles = QRF_No)
     and (p^.spec.nScreenWidth > data.a[0].w + 3) then begin
    qrfSplitColumn(@data, p);
    nColumn := data.nCol;
  end else
    qrfRestrictScreenWidth(@data, p);

  case p^.spec.eStyle of
    QRF_STYLE_Box:
      begin
        if data.nMargin <> 0 then begin
          rowStart := PAnsiChar(#$e2#$94#$82' ');
          colSep := PAnsiChar(' '#$e2#$94#$82' ');
          rowSep := PAnsiChar(' '#$e2#$94#$82#10);
        end else begin
          rowStart := BOX_13;
          colSep := BOX_13;
          rowSep := PAnsiChar(#$e2#$94#$82#10);
        end;
        if p^.spec.bBorder = QRF_No then begin
          rowStart := rowStart + 3;
          rowSep := PAnsiChar(#10);
        end else
          qrfBoxSeparator(p^.pOut, @data, BOX_R23, BOX_234, BOX_R34, False);
      end;
    QRF_STYLE_Table:
      begin
        if data.nMargin <> 0 then begin
          rowStart := '| '; colSep := ' | '; rowSep := ' |'#10;
        end else begin
          rowStart := '|'; colSep := '|'; rowSep := '|'#10;
        end;
        if p^.spec.bBorder = QRF_No then begin
          rowStart := rowStart + 1;
          rowSep := PAnsiChar(#10);
        end else
          qrfRowSeparator(p^.pOut, @data, '+');
      end;
    QRF_STYLE_Column:
      begin
        zSpace := '     ';
        rowStart := '';
        if data.nMargin < 2 then colSep := ' '
        else if data.nMargin <= 5 then colSep := zSpace + (5 - data.nMargin)
        else colSep := zSpace;
        rowSep := PAnsiChar(#10);
      end;
  else
    begin   { Markdown }
      if data.nMargin <> 0 then begin
        rowStart := '| '; colSep := ' | '; rowSep := ' |'#10;
      end else begin
        rowStart := '|'; colSep := '|'; rowSep := '|'#10;
      end;
    end;
  end;
  szRowStart := CLen(rowStart);
  szRowSep := CLen(rowSep);
  szColSep := CLen(colSep);

  bWW := (p^.spec.bWordWrap = QRF_Yes) and (data.bMultiRow <> 0);
  if (p^.spec.eStyle = QRF_STYLE_Column)
     or ((p^.spec.bBorder = QRF_No)
         and ((p^.spec.eStyle = QRF_STYLE_Box) or (p^.spec.eStyle = QRF_STYLE_Table))) then
    bRTrim := True
  else
    bRTrim := False;

  i := 0;
  while (i < data.n) and (sqlite3_str_errcode(p^.pOut) = SQLITE_OK) do begin
    nRowLoc := 0;
    for j := 0 to nColumn - 1 do begin
      data.a[j].z := data.az[i+j];
      if data.a[j].z = nil then data.a[j].z := '';
      data.a[j].bNum := data.abNum[i+j];
    end;
    repeat
      sqlite3_str_append(p^.pOut, rowStart, szRowStart);
      bMore := False;
      for j := 0 to nColumn - 1 do begin
        nThis := 0; nWide := 0; iNext := 0;
        qrfWrapLine(data.a[j].z, data.a[j].w, bWW, @nThis, @nWide, @iNext);
        nWS := data.a[j].w - nWide;
        qrfPrintAligned(p^.pOut, @data.a[j], nThis, nWS);
        data.a[j].z := data.a[j].z + iNext;
        if data.a[j].z[0] <> #0 then bMore := True;
        if j < nColumn - 1 then
          sqlite3_str_append(p^.pOut, colSep, szColSep)
        else begin
          if bRTrim then qrfRTrim(p^.pOut);
          sqlite3_str_append(p^.pOut, rowSep, szRowSep);
        end;
      end;
      Inc(nRowLoc);
    until not (bMore and (nRowLoc < p^.mxHeight));
    if bMore then begin
      sqlite3_str_append(p^.pOut, rowStart, szRowStart);
      for j := 0 to nColumn - 1 do begin
        if data.a[j].z[0] = #0 then
          sqlite3_str_appendchar(p^.pOut, data.a[j].w, ' ')
        else begin
          nE := 3;
          if nE > data.a[j].w then nE := data.a[j].w;
          data.a[j].z := '...';
          qrfPrintAligned(p^.pOut, @data.a[j], nE, data.a[j].w - nE);
        end;
        if j < nColumn - 1 then
          sqlite3_str_append(p^.pOut, colSep, szColSep)
        else begin
          if bRTrim then qrfRTrim(p^.pOut);
          sqlite3_str_append(p^.pOut, rowSep, szRowSep);
        end;
      end;
    end;

    if ((i = 0) or (data.bMultiRow <> 0)) and (i + nColumn < data.n) then begin
      isTitleDataSeparator := (i = 0) and (p^.spec.bTitles = QRF_Yes);
      if isTitleDataSeparator then qrfLoadAlignment(@data, p);
      case p^.spec.eStyle of
        QRF_STYLE_Table:
          if isTitleDataSeparator or (data.bMultiRow <> 0) then
            qrfRowSeparator(p^.pOut, @data, '+');
        QRF_STYLE_Box:
          if isTitleDataSeparator then
            qrfBoxSeparator(p^.pOut, @data, DBL_123, DBL_1234, DBL_134, True)
          else if data.bMultiRow <> 0 then
            qrfBoxSeparator(p^.pOut, @data, BOX_123, BOX_1234, BOX_134, False);
        QRF_STYLE_Markdown:
          if isTitleDataSeparator then
            qrfRowSeparator(p^.pOut, @data, '|');
        QRF_STYLE_Column:
          if isTitleDataSeparator then begin
            for j := 0 to nColumn - 1 do begin
              sqlite3_str_appendchar(p^.pOut, data.a[j].w, '-');
              if j < nColumn - 1 then
                sqlite3_str_append(p^.pOut, colSep, szColSep)
              else begin
                qrfRTrim(p^.pOut);
                sqlite3_str_append(p^.pOut, rowSep, szRowSep);
              end;
            end;
          end else if data.bMultiRow <> 0 then begin
            qrfRTrim(p^.pOut);
            sqlite3_str_append(p^.pOut, #10, 1);
          end;
      end;
    end;
    i := i + nColumn;
  end;

  if p^.spec.bBorder <> QRF_No then begin
    case p^.spec.eStyle of
      QRF_STYLE_Box: qrfBoxSeparator(p^.pOut, @data, BOX_R12, BOX_124, BOX_R14, False);
      QRF_STYLE_Table: qrfRowSeparator(p^.pOut, @data, '+');
    end;
  end;
  qrfColDataFree(@data);
end;

function qrfStringInArray(zStr: PAnsiChar; const azArray: array of PAnsiChar): Boolean;
var i: i32;
begin
  if zStr = nil then Exit(False);
  for i := 0 to High(azArray) do begin
    if azArray[i] = nil then Break;
    if StrComp(zStr, azArray[i]) = 0 then Exit(True);
  end;
  Result := False;
end;

procedure qrfExplain(p: PQrf);
const
  azNext: array[0..6] of PAnsiChar = ('Next','Prev','VPrev','VNext','SorterNext','Return',nil);
  azYield: array[0..5] of PAnsiChar = ('Yield','SeekLT','SeekGT','RowSetRead','Rewind',nil);
  azGoto: array[0..1] of PAnsiChar = ('Goto',nil);
  aExplainWidth: array[0..7] of i32 = (4,13,4,4,4,13,2,13);
  aExplainMap: array[0..7] of i32 = (0,1,2,3,4,5,6,7);
var
  abYield, aiIndent, aWidth, aMap: Pi32;
  nAlloc: i64; nIndent, iOp, i, iAddr, p1, p2, p2op, nWidth, iIndent, nArg, w, len: i32;
  zOp, zCol, zVal, zSep: PAnsiChar;
begin
  abYield := nil; aiIndent := nil; nAlloc := 0; nIndent := 0;
  iOp := 0;
  while (sqlite3_step(p^.pStmt) = SQLITE_ROW) and (p^.iErr = 0) do begin
    iAddr := sqlite3_column_int(p^.pStmt, 0);
    zOp := sqlite3_column_text(p^.pStmt, 1);
    p1 := sqlite3_column_int(p^.pStmt, 2);
    p2 := sqlite3_column_int(p^.pStmt, 3);
    p2op := p2 + (iOp - iAddr);
    if iOp >= nAlloc then begin
      nAlloc := nAlloc + 100;
      aiIndent := Pi32(sqlite3_realloc64(aiIndent, u64(nAlloc) * SizeOf(i32)));
      abYield := Pi32(sqlite3_realloc64(abYield, u64(nAlloc) * SizeOf(i32)));
      if (aiIndent = nil) or (abYield = nil) then begin
        qrfOom(p); sqlite3_free(aiIndent); sqlite3_free(abYield); Exit;
      end;
    end;
    if qrfStringInArray(zOp, azYield) then abYield[iOp] := 1 else abYield[iOp] := 0;
    aiIndent[iOp] := 0;
    nIndent := iOp + 1;
    if qrfStringInArray(zOp, azNext) and (p2op > 0) then
      for i := p2op to iOp - 1 do aiIndent[i] := aiIndent[i] + 2;
    if qrfStringInArray(zOp, azGoto) and (p2op < iOp)
       and ((abYield[p2op] <> 0) or (p1 <> 0)) then
      for i := p2op to iOp - 1 do aiIndent[i] := aiIndent[i] + 2;
    Inc(iOp);
  end;
  sqlite3_free(abYield);

  sqlite3_reset(p^.pStmt);
  if p^.iErr = SQLITE_OK then begin
    aWidth := @aExplainWidth[0];
    aMap := @aExplainMap[0];
    nWidth := 8;
    iIndent := 1;
    nArg := p^.nCol;
    if nArg > nWidth then nArg := nWidth;
    iOp := 0;
    while (sqlite3_step(p^.pStmt) = SQLITE_ROW) and (p^.iErr = 0) do begin
      if iOp = 0 then begin
        for i := 0 to nArg - 1 do begin
          zCol := sqlite3_column_name(p^.pStmt, aMap[i]);
          qrfWidthPrint(p, p^.pOut, aWidth[i], zCol);
          if i = nArg - 1 then sqlite3_str_append(p^.pOut, #10, 1)
          else sqlite3_str_append(p^.pOut, '  ', 2);
        end;
        for i := 0 to nArg - 1 do begin
          sqlite3_str_appendf(p^.pOut, '%.*c', [aWidth[i], i32(Ord('-'))]);
          if i = nArg - 1 then sqlite3_str_append(p^.pOut, #10, 1)
          else sqlite3_str_append(p^.pOut, '  ', 2);
        end;
      end;
      for i := 0 to nArg - 1 do begin
        zSep := '  ';
        w := aWidth[i];
        zVal := sqlite3_column_text(p^.pStmt, aMap[i]);
        if i = nArg - 1 then w := 0;
        if zVal = nil then zVal := '';
        len := i32(sqlite3_qrf_wcswidth(zVal));
        if len > w then begin w := len; zSep := ' '; end;
        if (i = iIndent) and (aiIndent <> nil) and (iOp < nIndent) then
          sqlite3_str_appendchar(p^.pOut, aiIndent[iOp], ' ');
        qrfWidthPrint(p, p^.pOut, w, zVal);
        if i = nArg - 1 then sqlite3_str_append(p^.pOut, #10, 1)
        else sqlite3_str_appendall(p^.pOut, zSep);
      end;
      Inc(p^.nRow);
      Inc(iOp);
    end;
  end;
  sqlite3_free(aiIndent);
end;

function qrfNeedQuote(zName: PAnsiChar): Boolean;
var i: i32; z: PByte;
begin
  z := PByte(zName);
  if z = nil then Exit(True);
  if not qrfAlpha(z[0]) then Exit(True);
  i := 0;
  while z[i] <> 0 do begin
    if not qrfAlnum(z[i]) then Exit(True);
    Inc(i);
  end;
  Result := sqlite3_keyword_check(zName, i) <> 0;
end;

procedure qrfOneJsonRow(p: PQrf);
var i, nItem: i32; zCName: PAnsiChar;
begin
  nItem := 0;
  for i := 0 to p^.nCol - 1 do begin
    zCName := sqlite3_column_name(p^.pStmt, i);
    if nItem > 0 then sqlite3_str_append(p^.pOut, ',', 1);
    Inc(nItem);
    qrfEncodeText(p, p^.pOut, zCName);
    sqlite3_str_append(p^.pOut, ':', 1);
    qrfRenderValue(p, p^.pOut, i);
  end;
end;

procedure qrfOneSimpleRow(p: PQrf);
var i, mxIns, szStart, sz, nSep, mxW, cnt, nThis, nWide, iNext: i32;
    saved_eText: u8;
    zCName, zVal: PAnsiChar; pVal: PSqlite3Str; bWW: Boolean;
    zEqpLine: PAnsiChar; iEqpId, iParentId: i32;
begin
  case p^.spec.eStyle of
    QRF_STYLE_Off, QRF_STYLE_Count: ;
    QRF_STYLE_Json:
      begin
        if p^.nRow = 0 then sqlite3_str_append(p^.pOut, '[{', 2)
        else sqlite3_str_append(p^.pOut, '},'#10'{', 4);
        qrfOneJsonRow(p);
      end;
    QRF_STYLE_JObject:
      begin
        if p^.nRow = 0 then sqlite3_str_append(p^.pOut, '{', 1)
        else sqlite3_str_append(p^.pOut, '}'#10'{', 3);
        qrfOneJsonRow(p);
      end;
    QRF_STYLE_Html:
      begin
        if (p^.nRow = 0) and (p^.spec.bTitles = QRF_Yes) then begin
          sqlite3_str_append(p^.pOut, '<TR>', 4);
          for i := 0 to p^.nCol - 1 do begin
            zCName := sqlite3_column_name(p^.pStmt, i);
            sqlite3_str_append(p^.pOut, #10'<TH>', 5);
            qrfEncodeText(p, p^.pOut, zCName);
          end;
          sqlite3_str_append(p^.pOut, #10'</TR>'#10, 7);
        end;
        sqlite3_str_append(p^.pOut, '<TR>', 4);
        for i := 0 to p^.nCol - 1 do begin
          sqlite3_str_append(p^.pOut, #10'<TD>', 5);
          qrfRenderValue(p, p^.pOut, i);
        end;
        sqlite3_str_append(p^.pOut, #10'</TR>'#10, 7);
      end;
    QRF_STYLE_Insert:
      begin
        mxIns := p^.spec.nMultiInsert;
        szStart := sqlite3_str_length(p^.pOut);
        if (p^.uNIns = 0) or (p^.uNIns >= u32(mxIns)) then begin
          if p^.uNIns <> 0 then begin
            sqlite3_str_append(p^.pOut, ';'#10, 2);
            p^.uNIns := 0;
          end;
          if qrfNeedQuote(p^.spec.zTableName) then
            sqlite3_str_appendf(p^.pOut, 'INSERT INTO "%w"', [p^.spec.zTableName])
          else
            sqlite3_str_appendf(p^.pOut, 'INSERT INTO %s', [p^.spec.zTableName]);
          if p^.spec.bTitles = QRF_Yes then begin
            for i := 0 to p^.nCol - 1 do begin
              zCName := sqlite3_column_name(p^.pStmt, i);
              if qrfNeedQuote(zCName) then begin
                if i = 0 then sqlite3_str_appendf(p^.pOut, '%c"%w"', [i32(Ord('(')), zCName])
                else sqlite3_str_appendf(p^.pOut, '%c"%w"', [i32(Ord(',')), zCName]);
              end else begin
                if i = 0 then sqlite3_str_appendf(p^.pOut, '%c%s', [i32(Ord('(')), zCName])
                else sqlite3_str_appendf(p^.pOut, '%c%s', [i32(Ord(',')), zCName]);
              end;
            end;
            sqlite3_str_append(p^.pOut, ')', 1);
          end;
          sqlite3_str_append(p^.pOut, ' VALUES(', 8);
        end else
          sqlite3_str_append(p^.pOut, ','#10'  (', 5);
        for i := 0 to p^.nCol - 1 do begin
          if i > 0 then sqlite3_str_append(p^.pOut, ',', 1);
          qrfRenderValue(p, p^.pOut, i);
        end;
        p^.uNIns := p^.uNIns + u32(sqlite3_str_length(p^.pOut) + 2 - szStart);
        if p^.uNIns >= u32(mxIns) then begin
          sqlite3_str_append(p^.pOut, ');'#10, 3);
          p^.uNIns := 0;
        end else
          sqlite3_str_append(p^.pOut, ')', 1);
      end;
    QRF_STYLE_Line:
      begin
        if p^.uLineAzCol = nil then begin
          p^.uLineAzCol := PPChar(sqlite3_malloc64(u64(p^.nCol) * SizeOf(PAnsiChar)));
          if p^.uLineAzCol = nil then begin qrfOom(p); Exit; end;
          p^.uLineMxColWth := 0;
          for i := 0 to p^.nCol - 1 do begin
            zCName := sqlite3_column_name(p^.pStmt, i);
            if zCName = nil then zCName := 'unknown';
            p^.uLineAzCol[i] := QrfDupStr(zCName);
            if p^.spec.nTitleLimit > 0 then
              qrfTitleLimit(p^.uLineAzCol[i], p^.spec.nTitleLimit);
            sz := i32(sqlite3_qrf_wcswidth(p^.uLineAzCol[i]));
            if sz > p^.uLineMxColWth then p^.uLineMxColWth := sz;
          end;
        end;
        if p^.nRow <> 0 then sqlite3_str_append(p^.pOut, #10, 1);
        pVal := sqlite3_str_new(p^.db);
        nSep := CLen(p^.spec.zColumnSep);
        mxW := p^.mxWidth - (nSep + p^.uLineMxColWth);
        bWW := p^.spec.bWordWrap = QRF_Yes;
        for i := 0 to p^.nCol - 1 do begin
          cnt := 0;
          qrfWidthPrint(p, p^.pOut, -p^.uLineMxColWth, p^.uLineAzCol[i]);
          sqlite3_str_append(p^.pOut, p^.spec.zColumnSep, nSep);
          qrfRenderValue(p, pVal, i);
          zVal := sqlite3_str_value(pVal);
          if zVal = nil then zVal := '';
          repeat
            qrfWrapLine(zVal, mxW, bWW, @nThis, @nWide, @iNext);
            if cnt <> 0 then
              sqlite3_str_appendchar(p^.pOut, p^.uLineMxColWth + nSep, ' ');
            Inc(cnt);
            if cnt > p^.mxHeight then begin
              zVal := '...'; nThis := 3; iNext := 3;
            end;
            sqlite3_str_append(p^.pOut, zVal, nThis);
            sqlite3_str_append(p^.pOut, #10, 1);
            zVal := zVal + iNext;
          until zVal[0] = #0;
          sqlite3_str_reset(pVal);
        end;
        qrfStrErr(p, pVal);
        sqlite3_free(sqlite3_str_finish(pVal));
      end;
    QRF_STYLE_Eqp:
      begin
        zEqpLine := sqlite3_column_text(p^.pStmt, 3);
        iEqpId := sqlite3_column_int(p^.pStmt, 0);
        iParentId := sqlite3_column_int(p^.pStmt, 1);
        if zEqpLine = nil then zEqpLine := '';
        if zEqpLine[0] = '-' then qrfEqpRender(p, 0);
        qrfEqpAppend(p, iEqpId, iParentId, zEqpLine);
      end;
  else
    begin   { QRF_STYLE_List }
      if (p^.nRow = 0) and (p^.spec.bTitles = QRF_Yes) then begin
        saved_eText := p^.spec.eText;
        p^.spec.eText := p^.spec.eTitle;
        for i := 0 to p^.nCol - 1 do begin
          zCName := sqlite3_column_name(p^.pStmt, i);
          if i > 0 then sqlite3_str_appendall(p^.pOut, p^.spec.zColumnSep);
          qrfEncodeText(p, p^.pOut, zCName);
        end;
        sqlite3_str_appendall(p^.pOut, p^.spec.zRowSep);
        p^.spec.eText := saved_eText;
      end;
      for i := 0 to p^.nCol - 1 do begin
        if i > 0 then sqlite3_str_appendall(p^.pOut, p^.spec.zColumnSep);
        qrfRenderValue(p, p^.pOut, i);
      end;
      sqlite3_str_appendall(p^.pOut, p^.spec.zRowSep);
    end;
  end;
  Inc(p^.nRow);
end;

procedure qrfInitialize(p: PQrf; pStmt: Pointer; pSpec: PQrfSpec; pzErr: PPChar);
var done: Boolean; expMode: i32;
begin
  FillChar(p^, SizeOf(p^), 0);
  p^.pzErr := pzErr;
  if pSpec^.iVersion > 1 then begin
    qrfError(p, SQLITE_ERROR,
      Format('unusable sqlite3_qrf_spec.iVersion (%d)', [pSpec^.iVersion]));
    Exit;
  end;
  p^.pStmt := pStmt;
  p^.db := sqlite3_db_handle(pStmt);
  p^.pOut := sqlite3_str_new(p^.db);
  if p^.pOut = nil then begin qrfOom(p); Exit; end;
  p^.iErr := SQLITE_OK;
  p^.nCol := sqlite3_column_count(pStmt);
  p^.nRow := 0;
  p^.spec := pSpec^;
  if p^.spec.zNull = nil then p^.spec.zNull := '';
  p^.mxWidth := p^.spec.nScreenWidth;
  if p^.mxWidth <= 0 then p^.mxWidth := QRF_MAX_WIDTH;
  p^.mxHeight := p^.spec.nLineLimit;
  if p^.mxHeight <= 0 then p^.mxHeight := 2147483647;
  if p^.spec.eStyle > QRF_STYLE_Table then p^.spec.eStyle := QRF_Auto;
  if p^.spec.eEsc > QRF_ESC_Symbol then p^.spec.eEsc := QRF_Auto;
  if p^.spec.eText > QRF_TEXT_Relaxed then p^.spec.eText := QRF_Auto;
  if p^.spec.eTitle > QRF_TEXT_Relaxed then p^.spec.eTitle := QRF_Auto;
  if p^.spec.eBlob > QRF_BLOB_Size then p^.spec.eBlob := QRF_Auto;

  repeat
    done := True;
    case p^.spec.eStyle of
      QRF_Auto:
        begin
          case sqlite3_stmt_isexplain(pStmt) of
            0: p^.spec.eStyle := QRF_STYLE_Box;
            1: p^.spec.eStyle := QRF_STYLE_Explain;
          else
            p^.spec.eStyle := QRF_STYLE_Eqp;
          end;
          done := False;
        end;
      QRF_STYLE_List:
        begin
          if p^.spec.zColumnSep = nil then p^.spec.zColumnSep := '|';
          if p^.spec.zRowSep = nil then p^.spec.zRowSep := #10;
        end;
      QRF_STYLE_JObject, QRF_STYLE_Json:
        begin
          p^.spec.eText := QRF_TEXT_Json;
          p^.spec.zNull := 'null';
        end;
      QRF_STYLE_Html:
        begin
          p^.spec.eText := QRF_TEXT_Html;
          p^.spec.zNull := 'null';
        end;
      QRF_STYLE_Insert:
        begin
          p^.spec.eText := QRF_TEXT_Sql;
          p^.spec.zNull := 'NULL';
          if (p^.spec.zTableName = nil) or (p^.spec.zTableName[0] = #0) then
            p^.spec.zTableName := 'tab';
          p^.uNIns := 0;
        end;
      QRF_STYLE_Line:
        if p^.spec.zColumnSep = nil then p^.spec.zColumnSep := ': ';
      QRF_STYLE_Csv:
        begin
          p^.spec.eStyle := QRF_STYLE_List;
          p^.spec.eText := QRF_TEXT_Csv;
          p^.spec.zColumnSep := ',';
          p^.spec.zRowSep := #13#10;
          p^.spec.zNull := '';
        end;
      QRF_STYLE_Quote:
        begin
          p^.spec.eText := QRF_TEXT_Sql;
          p^.spec.zNull := 'NULL';
          p^.spec.zColumnSep := ',';
          p^.spec.zRowSep := #10;
        end;
      QRF_STYLE_Eqp:
        begin
          expMode := sqlite3_stmt_isexplain(p^.pStmt);
          if expMode <> 2 then begin
            sqlite3_stmt_explain(p^.pStmt, 2);
            p^.expMode := expMode + 1;
          end;
        end;
      QRF_STYLE_Explain:
        begin
          expMode := sqlite3_stmt_isexplain(p^.pStmt);
          if expMode <> 1 then begin
            sqlite3_stmt_explain(p^.pStmt, 1);
            p^.expMode := expMode + 1;
          end;
        end;
    end;
  until done;

  if p^.spec.eEsc = QRF_Auto then p^.spec.eEsc := QRF_ESC_Ascii;
  if p^.spec.eText = QRF_Auto then p^.spec.eText := QRF_TEXT_Plain;
  if p^.spec.eTitle = QRF_Auto then begin
    case p^.spec.eStyle of
      QRF_STYLE_Box, QRF_STYLE_Column, QRF_STYLE_Table:
        p^.spec.eTitle := QRF_TEXT_Plain;
    else
      p^.spec.eTitle := p^.spec.eText;
    end;
  end;
  if p^.spec.eBlob = QRF_Auto then begin
    case p^.spec.eText of
      QRF_TEXT_Sql:  p^.spec.eBlob := QRF_BLOB_Sql;
      QRF_TEXT_Csv:  p^.spec.eBlob := QRF_BLOB_Tcl;
      QRF_TEXT_Tcl:  p^.spec.eBlob := QRF_BLOB_Tcl;
      QRF_TEXT_Json: p^.spec.eBlob := QRF_BLOB_Json;
    else
      p^.spec.eBlob := QRF_BLOB_Text;
    end;
  end;
  if p^.spec.bTitles = QRF_Auto then begin
    case p^.spec.eStyle of
      QRF_STYLE_Box, QRF_STYLE_Csv, QRF_STYLE_Column, QRF_STYLE_Table, QRF_STYLE_Markdown:
        p^.spec.bTitles := QRF_Yes;
    else
      p^.spec.bTitles := QRF_No;
    end;
  end;
  if p^.spec.bWordWrap = QRF_Auto then p^.spec.bWordWrap := QRF_Yes;
  if p^.spec.bTextJsonb = QRF_Auto then p^.spec.bTextJsonb := QRF_No;
  if p^.spec.zColumnSep = nil then p^.spec.zColumnSep := ',';
  if p^.spec.zRowSep = nil then p^.spec.zRowSep := #10;
end;

procedure qrfFinalize(p: PQrf);
var i, n, szc: i64; zCombined: PAnsiChar; jdb: PTsqlite3;
begin
  case p^.spec.eStyle of
    QRF_STYLE_Count:
      sqlite3_str_appendf(p^.pOut, '%lld'#10, [p^.nRow]);
    QRF_STYLE_Json:
      if p^.nRow > 0 then sqlite3_str_append(p^.pOut, '}]'#10, 3);
    QRF_STYLE_JObject:
      if p^.nRow > 0 then sqlite3_str_append(p^.pOut, '}'#10, 2);
    QRF_STYLE_Insert:
      if p^.uNIns <> 0 then sqlite3_str_append(p^.pOut, ';'#10, 2);
    QRF_STYLE_Line:
      if p^.uLineAzCol <> nil then begin
        for i := 0 to p^.nCol - 1 do sqlite3_free(p^.uLineAzCol[i]);
        sqlite3_free(p^.uLineAzCol);
      end;
    QRF_STYLE_Stats, QRF_STYLE_StatsEst:
      qrfEqpRender(p, 0);
    QRF_STYLE_Eqp:
      qrfEqpRender(p, 0);
  end;
  qrfStrErr(p, p^.pOut);
  if p^.spec.pzOutput <> nil then begin
    if p^.spec.pzOutput^ <> nil then begin
      szc := StrLen(p^.spec.pzOutput^);
      n := sqlite3_str_length(p^.pOut);
      zCombined := PAnsiChar(sqlite3_realloc64(p^.spec.pzOutput^, u64(szc) + n + 1));
      if zCombined = nil then begin
        sqlite3_free(p^.spec.pzOutput^);
        p^.spec.pzOutput^ := nil;
        qrfOom(p);
      end else begin
        p^.spec.pzOutput^ := zCombined;
        Move(sqlite3_str_value(p^.pOut)^, (zCombined + szc)^, n + 1);
      end;
      sqlite3_free(sqlite3_str_finish(p^.pOut));
    end else
      p^.spec.pzOutput^ := sqlite3_str_finish(p^.pOut);
  end else if p^.pOut <> nil then
    sqlite3_free(sqlite3_str_finish(p^.pOut));
  if p^.expMode > 0 then
    sqlite3_stmt_explain(p^.pStmt, p^.expMode - 1);
  if p^.actualWidth <> nil then sqlite3_free(p^.actualWidth);
  if p^.pJTrans <> nil then begin
    { capture the translator's own :memory: db BEFORE finalize frees pJTrans }
    jdb := sqlite3_db_handle(p^.pJTrans);
    sqlite3_finalize(p^.pJTrans);
    sqlite3_close(jdb);
  end;
end;

function sqlite3_format_query_result(pStmt: Pointer; pSpec: PQrfSpec;
                                     pzErr: PPChar): i32;
var qrf: TQrf;
begin
  if pStmt = nil then Exit(SQLITE_OK);
  if pSpec = nil then Exit(21 { SQLITE_MISUSE });
  qrfInitialize(@qrf, pStmt, pSpec, pzErr);
  case qrf.spec.eStyle of
    QRF_STYLE_Box, QRF_STYLE_Column, QRF_STYLE_Markdown, QRF_STYLE_Table:
      qrfColumnar(@qrf);
    QRF_STYLE_Explain:
      qrfExplain(@qrf);
    QRF_STYLE_StatsVm:
      qrfEqpStats(@qrf);
    QRF_STYLE_Stats, QRF_STYLE_StatsEst:
      qrfEqpStats(@qrf);
  else
    while (qrf.iErr = SQLITE_OK) and (sqlite3_step(pStmt) = SQLITE_ROW) do
      qrfOneSimpleRow(@qrf);
  end;
  qrfResetStmt(@qrf);
  qrfFinalize(@qrf);
  Result := qrf.iErr;
end;

end.
