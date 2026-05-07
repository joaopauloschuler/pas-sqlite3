{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/regexp.c (928 lines in C).

  Implements the SQL functions regexp(PATTERN, STRING) and the
  case-insensitive variant regexpi(PATTERN, STRING).  Registering
  regexp() also implements the "B REGEXP A" operator.

  The compiled NFA is cached on the function context via
  sqlite3_set_auxdata so that repeated invocations with a constant
  pattern recompile only once per SQL statement.

  Public entry: sqlite3RegexpInit(db) — equivalent to
  sqlite3_regexp_init() in C.
}
{$I passqlite3.inc}
unit passqlite3regexp;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3RegexpInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os;  { sqlite3_malloc64 / sqlite3_realloc64 / sqlite3_free }

const
  RE_EOF       = 0;
  RE_START     = $fffffff;

  RE_OP_MATCH    = 1;
  RE_OP_ANY      = 2;
  RE_OP_ANYSTAR  = 3;
  RE_OP_FORK     = 4;
  RE_OP_GOTO     = 5;
  RE_OP_ACCEPT   = 6;
  RE_OP_CC_INC   = 7;
  RE_OP_CC_EXC   = 8;
  RE_OP_CC_VALUE = 9;
  RE_OP_CC_RANGE = 10;
  RE_OP_WORD     = 11;
  RE_OP_NOTWORD  = 12;
  RE_OP_DIGIT    = 13;
  RE_OP_NOTDIGIT = 14;
  RE_OP_SPACE    = 15;
  RE_OP_NOTSPACE = 16;
  RE_OP_BOUNDARY = 17;
  RE_OP_ATSTART  = 18;

type
  ReStateNumber = Word;  { unsigned short }
  PReStateNumber = ^ReStateNumber;

  PReStateSet = ^TReStateSet;
  TReStateSet = record
    nState: u32;
    aState: PReStateNumber;
  end;

  PReInput = ^TReInput;
  TReInput = record
    z:  PByte;
    i:  i32;
    mx: i32;
  end;

  TxNextChar = function(p: PReInput): u32;

  PReCompiled = ^TReCompiled;
  TReCompiled = record
    sIn:       TReInput;
    zErr:      PAnsiChar;
    aOp:       PByte;        { array of opcodes }
    aArg:      PInteger;     { array of arguments }
    xNextChar: TxNextChar;
    zInit:     array[0..11] of Byte;
    nInit:     i32;
    nState:    u32;
    nAlloc:    u32;
    mxAlloc:   u32;
  end;

{ Add a state to the given state set if not already there. }
procedure re_add_state(pSet: PReStateSet; newState: i32);
var
  i: u32;
begin
  i := 0;
  while i < pSet^.nState do
  begin
    if pSet^.aState[i] = ReStateNumber(newState) then Exit;
    Inc(i);
  end;
  pSet^.aState[pSet^.nState] := ReStateNumber(newState);
  Inc(pSet^.nState);
end;

{ Extract next unicode character from *p and advance.  UTF-8 → unicode. }
function re_next_char(p: PReInput): u32;
var
  c: u32;
begin
  if p^.i >= p^.mx then begin Result := 0; Exit; end;
  c := p^.z[p^.i];
  Inc(p^.i);
  if c >= $80 then
  begin
    if ((c and $e0) = $c0) and (p^.i < p^.mx) and ((p^.z[p^.i] and $c0) = $80) then
    begin
      c := ((c and $1f) shl 6) or (p^.z[p^.i] and $3f);
      Inc(p^.i);
      if c < $80 then c := $fffd;
    end
    else if ((c and $f0) = $e0) and (p^.i + 1 < p^.mx)
         and ((p^.z[p^.i] and $c0) = $80)
         and ((p^.z[p^.i + 1] and $c0) = $80) then
    begin
      c := ((c and $0f) shl 12)
         or ((p^.z[p^.i] and $3f) shl 6)
         or  (p^.z[p^.i + 1] and $3f);
      Inc(p^.i, 2);
      if (c <= $7ff) or ((c >= $d800) and (c <= $dfff)) then c := $fffd;
    end
    else if ((c and $f8) = $f0) and (p^.i + 2 < p^.mx)
         and ((p^.z[p^.i]     and $c0) = $80)
         and ((p^.z[p^.i + 1] and $c0) = $80)
         and ((p^.z[p^.i + 2] and $c0) = $80) then
    begin
      c := ((c and $07) shl 18)
         or ((p^.z[p^.i]     and $3f) shl 12)
         or ((p^.z[p^.i + 1] and $3f) shl 6)
         or  (p^.z[p^.i + 2] and $3f);
      Inc(p^.i, 3);
      if (c <= $ffff) or (c > $10ffff) then c := $fffd;
    end
    else
    begin
      c := $fffd;
    end;
  end;
  Result := c;
end;

function re_next_char_nocase(p: PReInput): u32;
var
  c: u32;
begin
  c := re_next_char(p);
  if (c >= Ord('A')) and (c <= Ord('Z')) then
    Inc(c, Ord('a') - Ord('A'));
  Result := c;
end;

function re_word_char(c: i32): i32; inline;
begin
  if ((c >= Ord('0')) and (c <= Ord('9')))
  or ((c >= Ord('a')) and (c <= Ord('z')))
  or ((c >= Ord('A')) and (c <= Ord('Z')))
  or (c = Ord('_')) then
    Result := 1
  else
    Result := 0;
end;

function re_digit_char(c: i32): i32; inline;
begin
  if (c >= Ord('0')) and (c <= Ord('9')) then Result := 1 else Result := 0;
end;

function re_space_char(c: i32): i32; inline;
begin
  case c of
    Ord(' '), 9, 10, 13, 11, 12: Result := 1;
  else
    Result := 0;
  end;
end;

{ Run a compiled regular expression against zIn[0..nIn-1].  -1 means
  use strlen(zIn).  Returns 1 on match, 0 on no match, -1 on OOM. }
function re_match(pRe: PReCompiled; zIn: PByte; nIn: i32): i32;
label
  re_match_end;
var
  aStateSet: array[0..1] of TReStateSet;
  pThis, pNext: PReStateSet;
  aSpace: array[0..99] of ReStateNumber;
  pToFree: PReStateNumber;
  ii: u32;
  iSwap: u32;
  c: i32;
  cPrev: i32;
  rc: i32;
  in_: TReInput;
  x: i32;
  op: Byte;
  j, n, hit: i32;
begin
  rc := 0;
  iSwap := 0;
  c := RE_START;
  cPrev := 0;

  in_.z := zIn;
  in_.i := 0;
  if nIn >= 0 then
    in_.mx := nIn
  else
  begin
    in_.mx := 0;
    while zIn[in_.mx] <> 0 do Inc(in_.mx);
  end;

  { Look for the initial prefix match, if there is one. }
  if pRe^.nInit > 0 then
  begin
    while (in_.i + pRe^.nInit <= in_.mx)
       and ((zIn[in_.i] <> pRe^.zInit[0])
         or (CompareByte(zIn[in_.i], pRe^.zInit[0], pRe^.nInit) <> 0)) do
      Inc(in_.i);
    if in_.i + pRe^.nInit > in_.mx then
    begin
      Result := 0;
      Exit;
    end;
    c := RE_START - 1;
  end;

  if pRe^.nState <= (SizeOf(aSpace) div (SizeOf(aSpace[0]) * 2)) then
  begin
    pToFree := nil;
    aStateSet[0].aState := @aSpace[0];
  end
  else
  begin
    pToFree := PReStateNumber(sqlite3_malloc64(
      u64(SizeOf(ReStateNumber)) * 2 * pRe^.nState));
    if pToFree = nil then begin Result := -1; Exit; end;
    aStateSet[0].aState := pToFree;
  end;
  aStateSet[1].aState := @aStateSet[0].aState[pRe^.nState];
  pNext := @aStateSet[1];
  pNext^.nState := 0;
  re_add_state(pNext, 0);

  while (c <> RE_EOF) and (pNext^.nState > 0) do
  begin
    cPrev := c;
    c := i32(pRe^.xNextChar(@in_));
    pThis := pNext;
    pNext := @aStateSet[iSwap];
    iSwap := 1 - iSwap;
    pNext^.nState := 0;
    ii := 0;
    while ii < pThis^.nState do
    begin
      x := pThis^.aState[ii];
      op := pRe^.aOp[x];
      case op of
        RE_OP_MATCH:
          if pRe^.aArg[x] = c then re_add_state(pNext, x + 1);
        RE_OP_ATSTART:
          if cPrev = RE_START then re_add_state(pThis, x + 1);
        RE_OP_ANY:
          if c <> 0 then re_add_state(pNext, x + 1);
        RE_OP_WORD:
          if re_word_char(c) <> 0 then re_add_state(pNext, x + 1);
        RE_OP_NOTWORD:
          if (re_word_char(c) = 0) and (c <> 0) then re_add_state(pNext, x + 1);
        RE_OP_DIGIT:
          if re_digit_char(c) <> 0 then re_add_state(pNext, x + 1);
        RE_OP_NOTDIGIT:
          if (re_digit_char(c) = 0) and (c <> 0) then re_add_state(pNext, x + 1);
        RE_OP_SPACE:
          if re_space_char(c) <> 0 then re_add_state(pNext, x + 1);
        RE_OP_NOTSPACE:
          if (re_space_char(c) = 0) and (c <> 0) then re_add_state(pNext, x + 1);
        RE_OP_BOUNDARY:
          if re_word_char(c) <> re_word_char(cPrev) then
            re_add_state(pThis, x + 1);
        RE_OP_ANYSTAR:
        begin
          re_add_state(pNext, x);
          re_add_state(pThis, x + 1);
        end;
        RE_OP_FORK:
        begin
          re_add_state(pThis, x + pRe^.aArg[x]);
          re_add_state(pThis, x + 1);
        end;
        RE_OP_GOTO:
          re_add_state(pThis, x + pRe^.aArg[x]);
        RE_OP_ACCEPT:
        begin
          rc := 1;
          goto re_match_end;
        end;
        RE_OP_CC_EXC, RE_OP_CC_INC:
        begin
          { CC_EXC short-circuits when c=0 (NUL) — never matches. }
          if (op = RE_OP_CC_EXC) and (c = 0) then
          begin
            { fall through to ii++ }
          end
          else
          begin
            n := pRe^.aArg[x];
            hit := 0;
            j := 1;
            while (j > 0) and (j < n) do
            begin
              if pRe^.aOp[x + j] = RE_OP_CC_VALUE then
              begin
                if pRe^.aArg[x + j] = c then
                begin
                  hit := 1;
                  j := -1;
                end
                else
                  Inc(j);
              end
              else
              begin
                if (pRe^.aArg[x + j] <= c) and (pRe^.aArg[x + j + 1] >= c) then
                begin
                  hit := 1;
                  j := -1;
                end
                else
                  Inc(j, 2);
              end;
            end;
            if op = RE_OP_CC_EXC then
            begin
              if hit <> 0 then hit := 0 else hit := 1;
            end;
            if hit <> 0 then re_add_state(pNext, x + n);
          end;
        end;
      end;
      Inc(ii);
    end;
  end;

  { After loop, walk pNext checking for any state that reaches ACCEPT
    via GOTO chain. }
  ii := 0;
  while ii < pNext^.nState do
  begin
    x := pNext^.aState[ii];
    while pRe^.aOp[x] = RE_OP_GOTO do
      Inc(x, pRe^.aArg[x]);
    if pRe^.aOp[x] = RE_OP_ACCEPT then
    begin
      rc := 1;
      Break;
    end;
    Inc(ii);
  end;

re_match_end:
  if pToFree <> nil then sqlite3_free(pToFree);
  Result := rc;
end;

{ Resize aOp[]/aArg[] arrays.  Returns 1 on failure (zErr set), 0 ok. }
function re_resize(p: PReCompiled; N: u32): i32;
var
  newOp:  PByte;
  newArg: PInteger;
begin
  if N > p^.mxAlloc then
  begin
    p^.zErr := 'REGEXP pattern too big';
    Result := 1;
    Exit;
  end;
  newOp := PByte(sqlite3_realloc64(p^.aOp, u64(N) * SizeOf(p^.aOp[0])));
  if newOp = nil then begin p^.zErr := 'out of memory'; Result := 1; Exit; end;
  p^.aOp := newOp;
  newArg := PInteger(sqlite3_realloc64(p^.aArg, u64(N) * SizeOf(p^.aArg[0])));
  if newArg = nil then begin p^.zErr := 'out of memory'; Result := 1; Exit; end;
  p^.aArg := newArg;
  p^.nAlloc := N;
  Result := 0;
end;

{ Insert a new opcode/argument before existing opcode iBefore. }
function re_insert(p: PReCompiled; iBefore: i32; op: i32; arg: i32): i32;
var
  i: i32;
begin
  if (p^.nAlloc <= p^.nState) and (re_resize(p, p^.nAlloc * 2) <> 0) then
  begin
    Result := 0;
    Exit;
  end;
  i := i32(p^.nState);
  while i > iBefore do
  begin
    p^.aOp[i]  := p^.aOp[i - 1];
    p^.aArg[i] := p^.aArg[i - 1];
    Dec(i);
  end;
  Inc(p^.nState);
  p^.aOp[iBefore]  := Byte(op);
  p^.aArg[iBefore] := arg;
  Result := iBefore;
end;

function re_append(p: PReCompiled; op: i32; arg: i32): i32; inline;
begin
  Result := re_insert(p, i32(p^.nState), op, arg);
end;

{ Make a copy of N opcodes starting at iStart onto end of RE. }
procedure re_copy(p: PReCompiled; iStart: i32; N: u32);
begin
  if (p^.nState + N >= p^.nAlloc) and (re_resize(p, p^.nAlloc * 2 + N) <> 0) then
    Exit;
  Move(p^.aOp[iStart],  p^.aOp[p^.nState],  N * SizeOf(p^.aOp[0]));
  Move(p^.aArg[iStart], p^.aArg[p^.nState], N * SizeOf(p^.aArg[0]));
  Inc(p^.nState, N);
end;

function re_hex(c: i32; pV: PInteger): i32;
begin
  if (c >= Ord('0')) and (c <= Ord('9')) then
    Dec(c, Ord('0'))
  else if (c >= Ord('a')) and (c <= Ord('f')) then
    Dec(c, Ord('a') - 10)
  else if (c >= Ord('A')) and (c <= Ord('F')) then
    Dec(c, Ord('A') - 10)
  else
  begin
    Result := 0;
    Exit;
  end;
  pV^ := pV^ * 16 + (c and $ff);
  Result := 1;
end;

{ A backslash has been seen — read next char and return its
  interpretation.  Mirrors re_esc_char. }
function re_esc_char(p: PReCompiled): u32;
const
  zEsc:   array[0..21] of AnsiChar = 'afnrtv\()*.+?[$^{|}]-';
  zTrans: array[0..5]  of AnsiChar = #7#12#10#13#9#11;  { a f n r t v }
var
  i, v: i32;
  c: AnsiChar;
begin
  v := 0;
  if p^.sIn.i >= p^.sIn.mx then begin Result := 0; Exit; end;
  c := AnsiChar(p^.sIn.z[p^.sIn.i]);
  if (c = 'u') and (p^.sIn.i + 4 < p^.sIn.mx) then
  begin
    if (re_hex(p^.sIn.z[p^.sIn.i + 1], @v) <> 0)
    and (re_hex(p^.sIn.z[p^.sIn.i + 2], @v) <> 0)
    and (re_hex(p^.sIn.z[p^.sIn.i + 3], @v) <> 0)
    and (re_hex(p^.sIn.z[p^.sIn.i + 4], @v) <> 0) then
    begin
      Inc(p^.sIn.i, 5);
      Result := u32(v);
      Exit;
    end;
  end;
  if (c = 'x') and (p^.sIn.i + 2 < p^.sIn.mx) then
  begin
    if (re_hex(p^.sIn.z[p^.sIn.i + 1], @v) <> 0)
    and (re_hex(p^.sIn.z[p^.sIn.i + 2], @v) <> 0) then
    begin
      Inc(p^.sIn.i, 3);
      Result := u32(v);
      Exit;
    end;
  end;
  i := 0;
  while (zEsc[i] <> #0) and (zEsc[i] <> c) do Inc(i);
  if zEsc[i] <> #0 then
  begin
    if i < 6 then c := zTrans[i];
    Inc(p^.sIn.i);
  end
  else
    p^.zErr := 'unknown \ escape';
  Result := u32(Ord(c));
end;

function rePeek(p: PReCompiled): Byte; inline;
begin
  if p^.sIn.i < p^.sIn.mx then Result := p^.sIn.z[p^.sIn.i] else Result := 0;
end;

{ Forward decl }
function re_subcompile_string(p: PReCompiled): PAnsiChar; forward;

{ Compile RE up to first unmatched ')'.  Returns nil ok, error msg on fail. }
function re_subcompile_re(p: PReCompiled): PAnsiChar;
var
  zErr: PAnsiChar;
  iStart, iEnd, iGoto: i32;
begin
  iStart := i32(p^.nState);
  zErr := re_subcompile_string(p);
  if zErr <> nil then begin Result := zErr; Exit; end;
  while rePeek(p) = Ord('|') do
  begin
    iEnd := i32(p^.nState);
    re_insert(p, iStart, RE_OP_FORK, iEnd + 2 - iStart);
    iGoto := re_append(p, RE_OP_GOTO, 0);
    Inc(p^.sIn.i);
    zErr := re_subcompile_string(p);
    if zErr <> nil then begin Result := zErr; Exit; end;
    p^.aArg[iGoto] := i32(p^.nState) - iGoto;
  end;
  Result := nil;
end;

function re_subcompile_string(p: PReCompiled): PAnsiChar;
var
  iPrev, iStart: i32;
  c: u32;
  zErr: PAnsiChar;
  m, n, sz, j, iFirst: u32;
  specialOp: i32;
begin
  iPrev := -1;
  c := p^.xNextChar(@p^.sIn);
  while c <> 0 do
  begin
    iStart := i32(p^.nState);
    case c of
      Ord('|'), Ord(')'):
      begin
        Dec(p^.sIn.i);
        Result := nil;
        Exit;
      end;
      Ord('('):
      begin
        zErr := re_subcompile_re(p);
        if zErr <> nil then begin Result := zErr; Exit; end;
        if rePeek(p) <> Ord(')') then begin Result := 'unmatched ''('''; Exit; end;
        Inc(p^.sIn.i);
      end;
      Ord('.'):
      begin
        if rePeek(p) = Ord('*') then
        begin
          re_append(p, RE_OP_ANYSTAR, 0);
          Inc(p^.sIn.i);
        end
        else
          re_append(p, RE_OP_ANY, 0);
      end;
      Ord('*'):
      begin
        if iPrev < 0 then begin Result := '''*'' without operand'; Exit; end;
        re_insert(p, iPrev, RE_OP_GOTO, i32(p^.nState) - iPrev + 1);
        re_append(p, RE_OP_FORK, iPrev - i32(p^.nState) + 1);
      end;
      Ord('+'):
      begin
        if iPrev < 0 then begin Result := '''+'' without operand'; Exit; end;
        re_append(p, RE_OP_FORK, iPrev - i32(p^.nState));
      end;
      Ord('?'):
      begin
        if iPrev < 0 then begin Result := '''?'' without operand'; Exit; end;
        re_insert(p, iPrev, RE_OP_FORK, i32(p^.nState) - iPrev + 1);
      end;
      Ord('$'):
        re_append(p, RE_OP_MATCH, RE_EOF);
      Ord('^'):
        re_append(p, RE_OP_ATSTART, 0);
      Ord('{'):
      begin
        m := 0;
        n := 0;
        if iPrev < 0 then begin Result := '''{m,n}'' without operand'; Exit; end;
        c := rePeek(p);
        while (c >= Ord('0')) and (c <= Ord('9')) do
        begin
          m := m * 10 + (c - Ord('0'));
          if m * 2 > p^.mxAlloc then begin Result := 'REGEXP pattern too big'; Exit; end;
          Inc(p^.sIn.i);
          c := rePeek(p);
        end;
        n := m;
        if c = Ord(',') then
        begin
          Inc(p^.sIn.i);
          n := 0;
          c := rePeek(p);
          while (c >= Ord('0')) and (c <= Ord('9')) do
          begin
            n := n * 10 + (c - Ord('0'));
            if n * 2 > p^.mxAlloc then begin Result := 'REGEXP pattern too big'; Exit; end;
            Inc(p^.sIn.i);
            c := rePeek(p);
          end;
        end;
        if c <> Ord('}') then begin Result := 'unmatched ''{'''; Exit; end;
        if n < m then begin Result := 'n less than m in ''{m,n}'''; Exit; end;
        Inc(p^.sIn.i);
        sz := p^.nState - u32(iPrev);
        if m = 0 then
        begin
          if n = 0 then begin Result := 'both m and n are zero in ''{m,n}'''; Exit; end;
          re_insert(p, iPrev, RE_OP_FORK, i32(sz) + 1);
          Inc(iPrev);
          Dec(n);
        end
        else
        begin
          j := 1;
          while j < m do begin re_copy(p, iPrev, sz); Inc(j); end;
        end;
        j := m;
        while j < n do
        begin
          re_append(p, RE_OP_FORK, i32(sz) + 1);
          re_copy(p, iPrev, sz);
          Inc(j);
        end;
        if (n = 0) and (m > 0) then
          re_append(p, RE_OP_FORK, -i32(sz));
      end;
      Ord('['):
      begin
        iFirst := p^.nState;
        if rePeek(p) = Ord('^') then
        begin
          re_append(p, RE_OP_CC_EXC, 0);
          Inc(p^.sIn.i);
        end
        else
          re_append(p, RE_OP_CC_INC, 0);
        c := p^.xNextChar(@p^.sIn);
        while c <> 0 do
        begin
          if (c = Ord('[')) and (rePeek(p) = Ord(':')) then
          begin
            Result := 'POSIX character classes not supported';
            Exit;
          end;
          if c = Ord('\') then c := re_esc_char(p);
          if rePeek(p) = Ord('-') then
          begin
            re_append(p, RE_OP_CC_RANGE, i32(c));
            Inc(p^.sIn.i);
            c := p^.xNextChar(@p^.sIn);
            if c = Ord('\') then c := re_esc_char(p);
            re_append(p, RE_OP_CC_RANGE, i32(c));
          end
          else
            re_append(p, RE_OP_CC_VALUE, i32(c));
          if rePeek(p) = Ord(']') then
          begin
            Inc(p^.sIn.i);
            Break;
          end;
          c := p^.xNextChar(@p^.sIn);
        end;
        if c = 0 then begin Result := 'unclosed '#39'['#39; Exit; end;
        if p^.nState > iFirst then p^.aArg[iFirst] := i32(p^.nState - iFirst);
      end;
      Ord('\'):
      begin
        specialOp := 0;
        case rePeek(p) of
          Ord('b'): specialOp := RE_OP_BOUNDARY;
          Ord('d'): specialOp := RE_OP_DIGIT;
          Ord('D'): specialOp := RE_OP_NOTDIGIT;
          Ord('s'): specialOp := RE_OP_SPACE;
          Ord('S'): specialOp := RE_OP_NOTSPACE;
          Ord('w'): specialOp := RE_OP_WORD;
          Ord('W'): specialOp := RE_OP_NOTWORD;
        end;
        if specialOp <> 0 then
        begin
          Inc(p^.sIn.i);
          re_append(p, specialOp, 0);
        end
        else
        begin
          c := re_esc_char(p);
          re_append(p, RE_OP_MATCH, i32(c));
        end;
      end;
    else
      re_append(p, RE_OP_MATCH, i32(c));
    end;
    iPrev := iStart;
    c := p^.xNextChar(@p^.sIn);
  end;
  Result := nil;
end;

{ Free all memory used by a previously compiled regular expression. }
procedure re_free(pRe: PReCompiled);
begin
  if pRe = nil then Exit;
  sqlite3_free(pRe^.aOp);
  sqlite3_free(pRe^.aArg);
  sqlite3_free(pRe);
end;

procedure re_free_voidptr(p: Pointer); cdecl;
begin
  re_free(PReCompiled(p));
end;

{ Compile zIn[] into NFA.  *ppRe filled on success.  Returns nil ok or
  pointer to error message string. }
function re_compile(ppRe: PPointer; zIn: PAnsiChar; mxRe: i32;
                    noCase: i32): PAnsiChar;
var
  pRe: PReCompiled;
  zErr: PAnsiChar;
  i, j: i32;
  x: u32;
begin
  ppRe^ := nil;
  pRe := PReCompiled(sqlite3_malloc64(SizeOf(TReCompiled)));
  if pRe = nil then begin Result := 'out of memory'; Exit; end;
  FillChar(pRe^, SizeOf(pRe^), 0);
  if noCase <> 0 then
    pRe^.xNextChar := @re_next_char_nocase
  else
    pRe^.xNextChar := @re_next_char;
  pRe^.mxAlloc := u32(mxRe);
  if re_resize(pRe, 30) <> 0 then
  begin
    zErr := pRe^.zErr;
    re_free(pRe);
    Result := zErr;
    Exit;
  end;
  if zIn[0] = '^' then
    Inc(zIn)
  else
    re_append(pRe, RE_OP_ANYSTAR, 0);
  pRe^.sIn.z := PByte(zIn);
  pRe^.sIn.i := 0;
  pRe^.sIn.mx := i32(strlen(zIn));
  zErr := re_subcompile_re(pRe);
  if zErr <> nil then
  begin
    re_free(pRe);
    Result := zErr;
    Exit;
  end;
  if pRe^.sIn.i >= pRe^.sIn.mx then
  begin
    re_append(pRe, RE_OP_ACCEPT, 0);
    ppRe^ := pRe;
  end
  else
  begin
    re_free(pRe);
    Result := 'unrecognized character';
    Exit;
  end;

  { Optimisation: if regex begins with ".*" (no initial "^") and is
    followed by literal MATCH ops, copy them to zInit[] for fast
    prefix scan. }
  if (pRe^.aOp[0] = RE_OP_ANYSTAR) and (noCase = 0) then
  begin
    j := 0;
    i := 1;
    while (j < i32(SizeOf(pRe^.zInit)) - 2)
       and (pRe^.aOp[i] = RE_OP_MATCH) do
    begin
      x := u32(pRe^.aArg[i]);
      if x <= $7f then
      begin
        pRe^.zInit[j] := Byte(x); Inc(j);
      end
      else if x <= $7ff then
      begin
        pRe^.zInit[j] := Byte($c0 or (x shr 6)); Inc(j);
        pRe^.zInit[j] := Byte($80 or (x and $3f)); Inc(j);
      end
      else if x <= $ffff then
      begin
        pRe^.zInit[j] := Byte($e0 or (x shr 12)); Inc(j);
        pRe^.zInit[j] := Byte($80 or ((x shr 6) and $3f)); Inc(j);
        pRe^.zInit[j] := Byte($80 or (x and $3f)); Inc(j);
      end
      else
        Break;
      Inc(i);
    end;
    if (j > 0) and (pRe^.zInit[j - 1] = 0) then Dec(j);
    pRe^.nInit := j;
  end;
  Result := pRe^.zErr;
end;

function re_maxlen(pCtx: Psqlite3_context): i32;
var
  db: PTsqlite3;
begin
  db := sqlite3_context_db_handle(pCtx);
  Result := sqlite3_limit(db, 8 {SQLITE_LIMIT_LIKE_PATTERN_LENGTH}, -1);
end;

function re_maxnfa(mxlen: i32): i32; inline;
begin
  Result := 75 + mxlen div 2;
end;

{ Implementation of the regexp() / regexpi() SQL function.  argv[0] is
  the pattern, argv[1] is the string to match against. }
procedure re_sql_func(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pRe: PReCompiled;
  zPattern: PAnsiChar;
  zStr: PByte;
  zErr: PAnsiChar;
  setAux: i32;
  mxLen, nPattern: i32;
  nStr: i32;
  ppRe: Pointer;
begin
  setAux := 0;
  pRe := PReCompiled(sqlite3_get_auxdata(pCtx, 0));
  if pRe = nil then
  begin
    mxLen := re_maxlen(pCtx);
    zPattern := PAnsiChar(sqlite3_value_text(argv[0]));
    if zPattern = nil then Exit;
    nPattern := sqlite3_value_bytes(argv[0]);
    if nPattern > mxLen then
      zErr := 'REGEXP pattern too big'
    else
    begin
      ppRe := nil;
      if sqlite3_user_data(pCtx) <> nil then
        zErr := re_compile(@ppRe, zPattern, re_maxnfa(mxLen), 1)
      else
        zErr := re_compile(@ppRe, zPattern, re_maxnfa(mxLen), 0);
      pRe := PReCompiled(ppRe);
    end;
    if zErr <> nil then
    begin
      re_free(pRe);
      sqlite3_result_error(pCtx, zErr, -1);
      Exit;
    end;
    if pRe = nil then
    begin
      sqlite3_result_error_nomem(pCtx);
      Exit;
    end;
    setAux := 1;
  end;
  zStr := PByte(sqlite3_value_text(argv[1]));
  if zStr <> nil then
  begin
    nStr := sqlite3_value_bytes(argv[1]);
    sqlite3_result_int(pCtx, re_match(pRe, zStr, nStr));
  end;
  if setAux <> 0 then
    sqlite3_set_auxdata(pCtx, 0, pRe, @re_free_voidptr);
end;

function sqlite3RegexpInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_INNOCUOUS or SQLITE_DETERMINISTIC;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'regexp', 2, Flags, nil,
                                @re_sql_func, nil, nil);
  if rc = SQLITE_OK then
    { regexpi(PATTERN, STRING) — case-insensitive variant; the
      non-nil pUserData (we use db itself, matching the C source)
      is the case-insensitive sentinel. }
    rc := sqlite3_create_function(db, 'regexpi', 2, Flags, db,
                                  @re_sql_func, nil, nil);
  Result := rc;
end;

end.
