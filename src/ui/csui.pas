unit CsUI;

(* Thin ncursesw core: init/teardown, a small colour palette, and UTF-8-aware
   drawing helpers. All layout math goes through VisibleWidth / PadOrTrunc so
   multibyte text and emoji occupy the right number of cells (via libc
   wcwidth on the decoded codepoints). *)

{$mode objfpc}{$H+}

interface

uses
  ncurses, SysUtils;

const
  cpText   = 0;   // terminal default fg/bg (pair 0 is fixed)
  cpHeader = 1;
  cpStatus = 2;
  cpAccent = 3;   // usernames, titles
  cpMeta   = 4;   // timestamps, counts
  cpSelect = 5;   // highlighted row
  cpNsfw   = 6;
  cpError  = 7;

  keyPaste = $1000; // UIGetKey returns this when a bracketed paste was captured

type
  TTextLines = array of string;
  TRenderLine = record
    Text: string;
    Pair: Integer;
    Bold: Boolean;
  end;
  TRenderLines = array of TRenderLine;

  { A styled span: one run of text with a colour pair and bold/underline attrs.
    A display line is a sequence of runs, so styling can vary within a line
    (used by the markdown renderer). }
  TStyleRun = record
    Text: string;
    Pair: Integer;
    Bold: Boolean;
    Underline: Boolean; // links
    Italic: Boolean;    // emphasis (real terminal italics)
  end;
  TStyleRuns = array of TStyleRun;
  TStyleLines = array of TStyleRuns;

procedure UIInit;
procedure UIShutdown;
function ScreenRows: Integer;
function ScreenCols: Integer;
procedure UIErase;
procedure UIRefresh;
function UIGetKey: LongInt;

{ Draw text at (y,x) in a colour pair, optionally bold. Text is truncated to
  the remaining columns so it can never wrap. }
procedure DrawText(y, x, pair: Integer; const s: string; bold: Boolean = False);
{ Fill an entire row with a colour pair, text left-aligned, padded to width. }
procedure DrawBar(y, pair: Integer; const s: string);
{ Like DrawText but with underline (links) and italic (emphasis) attributes. }
procedure DrawStyled(y, x, pair: Integer; const s: string; bold, underline, italic: Boolean);
{ Draw a sequence of styled runs left-to-right starting at (y,x). Runs are
  assumed already wrapped to fit; anything past the screen edge is clipped. }
procedure DrawRuns(y, x: Integer; const runs: TStyleRuns);

{ Display width of a UTF-8 string, in terminal cells. }
function VisibleWidth(const s: string): Integer;
{ Truncate to at most maxCols cells (never splitting a codepoint); appends an
  ellipsis if it had to cut. }
function TruncEllipsis(const s: string; maxCols: Integer): string;
{ Truncate/space-pad to exactly cols cells. }
function PadOrTrunc(const s: string; cols: Integer): string;

{ Word-wrap UTF-8 text to a cell width, splitting on spaces and hard-breaking
  any word longer than the width. Embedded newlines start new lines. }
function WrapText(const s: string; width: Integer): TTextLines;
{ A horizontal rule of box-drawing chars, cols cells wide. }
function HLine(cols: Integer): string;
{ Append a render line (text + colour pair + bold) to a buffer. }
procedure RLAdd(var arr: TRenderLines; const text: string; pair: Integer; bold: Boolean = False);

{ Codepoint-aware cursor movement over a UTF-8 buffer. `cur` is the number of
  bytes before the cursor (0..Length); these return the new byte count after
  moving one codepoint left/right. }
function PrevCharBoundary(const s: string; cur: Integer): Integer;
function NextCharBoundary(const s: string; cur: Integer): Integer;
{ Number of codepoints in a UTF-8 string. }
function CodepointCount(const s: string): Integer;

{ Position the hardware cursor / toggle its visibility (for text entry). }
procedure UIPlaceCursor(y, x: Integer);
procedure UICursorVisible(visible: Boolean);

{ Set the input wait: ms < 0 blocks (default), ms = 0 is non-blocking, ms > 0
  waits up to ms for a key. When it times out, UIGetKey returns -1. Used by
  live views that must wake periodically to drain streamed events. }
procedure UIInputTimeout(ms: Integer);

{ A cautionary yes/no prompt shown in the status line. True = yes. }
function UIConfirm(const question: string): Boolean;

{ Single-line text prompt on the bottom row (editing, cursor, paste). Returns
  True on Enter with `text` set, False on Esc. }
function UIPromptLine(const prompt: string; out text: string): Boolean;

{ Leave/re-enter curses so an external full-screen program (e.g. an image
  viewer) can own the terminal, then repaint. UISuspend restores cooked mode;
  UIResume forces a full redraw on the next refresh. }
procedure UISuspend;
procedure UIResume;

{ The most recent bracketed paste, sanitised. Valid right after UIGetKey returns
  keyPaste. keepNewlines: true keeps embedded line breaks (for the multi-line
  composer), false flattens them to spaces (for single-line inputs). }
function PasteText(keepNewlines: Boolean): string;

implementation

const
  LC_ALL = 6; // glibc
  cPasteBegin = $1001; // internal key codes for the bracketed-paste markers
  cPasteEnd   = $1002;

var
  FLastPaste: string = '';
  FCurTimeout: LongInt = -1; // mirrors the last UIInputTimeout, to restore after an ESC peek

function setlocale(category: LongInt; locale: PChar): PChar; cdecl; external 'c' name 'setlocale';
function wcwidth(wc: LongInt): LongInt; cdecl; external 'c' name 'wcwidth';

{ Decode one UTF-8 codepoint from s starting at idx (1-based); advances idx. }
function NextCodepoint(const s: string; var idx: Integer; out cp: Cardinal): Boolean;
var
  b: Byte;
  n, i: Integer;
begin
  Result := idx <= Length(s);
  if not Result then
    Exit;
  b := Byte(s[idx]);
  Inc(idx);
  if b < $80 then
  begin
    cp := b;
    n := 0;
  end
  else if (b and $E0) = $C0 then begin cp := b and $1F; n := 1; end
  else if (b and $F0) = $E0 then begin cp := b and $0F; n := 2; end
  else if (b and $F8) = $F0 then begin cp := b and $07; n := 3; end
  else begin cp := b; n := 0; end; // stray continuation/invalid: pass through
  for i := 1 to n do
  begin
    if (idx > Length(s)) or ((Byte(s[idx]) and $C0) <> $80) then
      Break;
    cp := (cp shl 6) or (Byte(s[idx]) and $3F);
    Inc(idx);
  end;
end;

function CellWidth(cp: Cardinal): Integer;
begin
  Result := wcwidth(LongInt(cp));
  if Result < 0 then
    Result := 1; // non-printable: reserve a cell rather than under-count
end;

function VisibleWidth(const s: string): Integer;
var
  idx: Integer;
  cp: Cardinal;
begin
  Result := 0;
  idx := 1;
  while NextCodepoint(s, idx, cp) do
    Inc(Result, CellWidth(cp));
end;

function TruncCols(const s: string; maxCols: Integer; out truncated: Boolean): string;
var
  idx, start, used, w: Integer;
  cp: Cardinal;
begin
  Result := '';
  used := 0;
  idx := 1;
  truncated := False;
  while idx <= Length(s) do
  begin
    start := idx;
    if not NextCodepoint(s, idx, cp) then
      Break;
    w := CellWidth(cp);
    if used + w > maxCols then
    begin
      truncated := True;
      Break;
    end;
    Result := Result + Copy(s, start, idx - start);
    Inc(used, w);
  end;
end;

function TruncEllipsis(const s: string; maxCols: Integer): string;
var
  cut: Boolean;
begin
  if maxCols <= 0 then
    Exit('');
  if VisibleWidth(s) <= maxCols then
    Exit(s);
  Result := TruncCols(s, maxCols - 1, cut) + '…';
end;

function PadOrTrunc(const s: string; cols: Integer): string;
var
  w: Integer;
begin
  if cols <= 0 then
    Exit('');
  Result := TruncEllipsis(s, cols);
  w := VisibleWidth(Result);
  if w < cols then
    Result := Result + StringOfChar(' ', cols - w);
end;

{ Write a control string straight to the terminal. ncurses' putp() goes through
  C stdio, which ncurses never flushes, so a mode-set like bracketed paste would
  never actually reach the terminal; a direct write does. }
procedure TermRaw(const s: string);
begin
  if s <> '' then
    FileWrite(StdOutputHandle, s[1], Length(s));
end;

procedure UIInit;
begin
  setlocale(LC_ALL, ''); // adopt the terminal's UTF-8 locale before initscr
  initscr;
  cbreak;
  noecho;
  keypad(stdscr, True);
  curs_set(0);
  scrollok(stdscr, False);
  // Bracketed paste: enable it and teach ncurses the markers, so a paste arrives
  // as one keyPaste event instead of its text being read as keystrokes/commands.
  define_key(PChar(#27'[200~'), cPasteBegin);
  define_key(PChar(#27'[201~'), cPasteEnd);
  TermRaw(#27'[?2004h');
  if has_colors then
  begin
    start_color;
    use_default_colors;
    init_pair(cpHeader, COLOR_WHITE, COLOR_BLUE);
    init_pair(cpStatus, COLOR_BLACK, COLOR_WHITE);
    init_pair(cpAccent, COLOR_CYAN, -1);
    init_pair(cpMeta, COLOR_YELLOW, -1);
    init_pair(cpSelect, COLOR_BLACK, COLOR_CYAN);
    init_pair(cpNsfw, COLOR_RED, -1);
    init_pair(cpError, COLOR_WHITE, COLOR_RED);
  end;
end;

procedure UIShutdown;
begin
  TermRaw(#27'[?2004l'); // disable bracketed paste
  curs_set(1);
  endwin;
end;

function ScreenRows: Integer;
begin
  Result := LINES;
end;

function ScreenCols: Integer;
begin
  Result := COLS;
end;

procedure UIErase;
begin
  erase;
end;

procedure UIRefresh;
begin
  refresh;
end;

function UIGetKey: LongInt;
var
  k, k2: LongInt;
begin
  k := getch;
  if k = cPasteBegin then
  begin
    FLastPaste := '';
    repeat
      k := getch;
      if (k = cPasteEnd) or (k = -1) then
        Break;
      if (k >= 0) and (k <= 255) then
        FLastPaste := FLastPaste + Chr(k); // raw bytes rebuild UTF-8 correctly
      // any function-key codes inside a paste are ignored
    until False;
    Exit(keyPaste);
  end;
  if k = 27 then
  begin
    // Tell a real Escape press (nothing follows) from an unrecognised escape
    // sequence (e.g. an enhanced-keyboard report for Ctrl+Shift+V): peek for a
    // byte that arrives immediately.
    wtimeout(stdscr, 0);
    k2 := getch;
    if k2 = -1 then
    begin
      wtimeout(stdscr, FCurTimeout);
      Exit(27); // lone ESC = the Escape key
    end;
    repeat // drain the rest of the sequence, then swallow it
      k2 := getch;
    until k2 = -1;
    wtimeout(stdscr, FCurTimeout);
    Exit(-1); // report "no key" so an unknown sequence never triggers an action
  end;
  Result := k;
end;

function PasteText(keepNewlines: Boolean): string;
begin
  Result := StringReplace(FLastPaste, #13, '', [rfReplaceAll]);
  if not keepNewlines then
    Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
end;

procedure ApplyAttr(pair: Integer; bold: Boolean);
var
  a: chtype;
begin
  a := chtype(COLOR_PAIR(pair));
  if bold then
    a := a or chtype(A_BOLD);
  attrset(a);
end;

procedure DrawText(y, x, pair: Integer; const s: string; bold: Boolean = False);
var
  room: Integer;
  txt: string;
begin
  room := ScreenCols - x;
  if room <= 0 then
    Exit;
  txt := TruncEllipsis(s, room);
  ApplyAttr(pair, bold);
  mvaddstr(y, x, PChar(txt));
  attrset(chtype(A_NORMAL));
end;

procedure DrawBar(y, pair: Integer; const s: string);
begin
  ApplyAttr(pair, False);
  mvaddstr(y, 0, PChar(PadOrTrunc(s, ScreenCols)));
  attrset(chtype(A_NORMAL));
end;

procedure DrawStyled(y, x, pair: Integer; const s: string; bold, underline, italic: Boolean);
var
  room: Integer;
  txt: string;
  a: chtype;
  cut: Boolean;
begin
  room := ScreenCols - x;
  if room <= 0 then
    Exit;
  txt := TruncCols(s, room, cut); // clip to the row, no ellipsis (runs continue)
  a := chtype(COLOR_PAIR(pair));
  if bold then
    a := a or chtype(A_BOLD);
  if underline then
    a := a or chtype(A_UNDERLINE);
  if italic then
    a := a or (chtype(1) shl (23 + 8)); // A_ITALIC — FPC's ncurses unit omits it
  attrset(a);
  mvaddstr(y, x, PChar(txt));
  attrset(chtype(A_NORMAL));
end;

procedure DrawRuns(y, x: Integer; const runs: TStyleRuns);
var
  i, cx: Integer;
begin
  cx := x;
  for i := 0 to High(runs) do
  begin
    if cx >= ScreenCols then
      Break;
    DrawStyled(y, cx, runs[i].Pair, runs[i].Text, runs[i].Bold, runs[i].Underline, runs[i].Italic);
    cx := cx + VisibleWidth(runs[i].Text);
  end;
end;

procedure AppendLine(var arr: TTextLines; const s: string);
begin
  SetLength(arr, Length(arr) + 1);
  arr[High(arr)] := s;
end;

{ Split a spaceless string into chunks no wider than width cells. }
function CellChunks(const s: string; width: Integer): TTextLines;
var
  idx, start, used, w: Integer;
  cp: Cardinal;
  cur: string;
begin
  SetLength(Result, 0);
  cur := '';
  used := 0;
  idx := 1;
  while idx <= Length(s) do
  begin
    start := idx;
    if not NextCodepoint(s, idx, cp) then
      Break;
    w := CellWidth(cp);
    if (used + w > width) and (cur <> '') then
    begin
      AppendLine(Result, cur);
      cur := '';
      used := 0;
    end;
    cur := cur + Copy(s, start, idx - start);
    Inc(used, w);
  end;
  if cur <> '' then
    AppendLine(Result, cur);
  if Length(Result) = 0 then
    AppendLine(Result, '');
end;

function WrapText(const s: string; width: Integer): TTextLines;
var
  norm: string;
  segStart, i: Integer;

  procedure WrapSegment(const seg: string);
  var
    words: TTextLines;
    chunks: TTextLines;
    wStart, j, c: Integer;
    cur, word: string;
  begin
    if seg = '' then
    begin
      AppendLine(Result, '');
      Exit;
    end;
    SetLength(words, 0);
    wStart := 1;
    for j := 1 to Length(seg) + 1 do
      if (j > Length(seg)) or (seg[j] = ' ') then
      begin
        if j > wStart then
          AppendLine(words, Copy(seg, wStart, j - wStart));
        wStart := j + 1;
      end;
    cur := '';
    for j := 0 to High(words) do
    begin
      word := words[j];
      if VisibleWidth(word) > width then
      begin
        if cur <> '' then
        begin
          AppendLine(Result, cur);
          cur := '';
        end;
        chunks := CellChunks(word, width);
        for c := 0 to High(chunks) - 1 do
          AppendLine(Result, chunks[c]);
        cur := chunks[High(chunks)];
      end
      else if cur = '' then
        cur := word
      else if VisibleWidth(cur) + 1 + VisibleWidth(word) <= width then
        cur := cur + ' ' + word
      else
      begin
        AppendLine(Result, cur);
        cur := word;
      end;
    end;
    if cur <> '' then
      AppendLine(Result, cur);
  end;

begin
  SetLength(Result, 0);
  if width < 1 then
    width := 1;
  norm := StringReplace(s, #13#10, #10, [rfReplaceAll]);
  norm := StringReplace(norm, #13, #10, [rfReplaceAll]);
  segStart := 1;
  for i := 1 to Length(norm) + 1 do
    if (i > Length(norm)) or (norm[i] = #10) then
    begin
      WrapSegment(Copy(norm, segStart, i - segStart));
      segStart := i + 1;
    end;
  if Length(Result) = 0 then
    AppendLine(Result, '');
end;

function HLine(cols: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to cols do
    Result := Result + '─';
end;

procedure RLAdd(var arr: TRenderLines; const text: string; pair: Integer; bold: Boolean);
begin
  SetLength(arr, Length(arr) + 1);
  arr[High(arr)].Text := text;
  arr[High(arr)].Pair := pair;
  arr[High(arr)].Bold := bold;
end;

function IsCont(b: Byte): Boolean; inline;
begin
  Result := (b and $C0) = $80;
end;

function PrevCharBoundary(const s: string; cur: Integer): Integer;
var
  p: Integer;
begin
  if cur <= 0 then
    Exit(0);
  p := cur - 1;
  while (p > 0) and IsCont(Byte(s[p + 1])) do
    Dec(p);
  Result := p;
end;

function NextCharBoundary(const s: string; cur: Integer): Integer;
var
  p, n: Integer;
begin
  n := Length(s);
  if cur >= n then
    Exit(n);
  p := cur + 1;
  while (p < n) and IsCont(Byte(s[p + 1])) do
    Inc(p);
  Result := p;
end;

function CodepointCount(const s: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(s) do
    if not IsCont(Byte(s[i])) then
      Inc(Result);
end;

procedure UIPlaceCursor(y, x: Integer);
begin
  move(y, x);
end;

procedure UICursorVisible(visible: Boolean);
begin
  if visible then
    curs_set(1)
  else
    curs_set(0);
end;

procedure UIInputTimeout(ms: Integer);
begin
  FCurTimeout := ms;
  wtimeout(stdscr, ms);
end;

function SubFromCols(const s: string; startCol, widthCols: Integer): string;
var
  idx, col, w, ni: Integer;
  chunk: string;
begin
  Result := '';
  idx := 1;
  col := 0;
  while (idx <= Length(s)) and (col < startCol) do
  begin
    ni := NextCharBoundary(s, idx - 1) + 1;
    Inc(col, VisibleWidth(Copy(s, idx, ni - idx)));
    idx := ni;
  end;
  col := 0;
  while idx <= Length(s) do
  begin
    ni := NextCharBoundary(s, idx - 1) + 1;
    chunk := Copy(s, idx, ni - idx);
    w := VisibleWidth(chunk);
    if col + w > widthCols then
      Break;
    Result := Result + chunk;
    Inc(col, w);
    idx := ni;
  end;
end;

function UIPromptLine(const prompt: string; out text: string): Boolean;
var
  cur, key, avail, promptW, curCol, startCol, p: Integer;
  pv: string;
begin
  text := '';
  cur := 0;
  promptW := VisibleWidth(prompt) + 1;
  repeat
    DrawBar(ScreenRows - 1, cpText, '');
    DrawText(ScreenRows - 1, 0, cpAccent, prompt, True);
    avail := ScreenCols - promptW - 1;
    if avail < 4 then
      avail := 4;
    curCol := VisibleWidth(Copy(text, 1, cur));
    if VisibleWidth(text) <= avail then
      startCol := 0
    else
    begin
      startCol := curCol - avail;
      if startCol < 0 then
        startCol := 0;
    end;
    DrawText(ScreenRows - 1, promptW, cpText, SubFromCols(text, startCol, avail));
    UICursorVisible(True);
    UIPlaceCursor(ScreenRows - 1, promptW + (curCol - startCol));
    UIRefresh;
    key := UIGetKey;
    case key of
      27:
        begin
          UICursorVisible(False);
          Exit(False);
        end;
      10, 13, KEY_ENTER:
        begin
          UICursorVisible(False);
          Exit(True);
        end;
      KEY_BACKSPACE, 127, 8:
        if cur > 0 then
        begin
          p := PrevCharBoundary(text, cur);
          text := Copy(text, 1, p) + Copy(text, cur + 1, MaxInt);
          cur := p;
        end;
      KEY_LEFT:
        cur := PrevCharBoundary(text, cur);
      KEY_RIGHT:
        cur := NextCharBoundary(text, cur);
      KEY_HOME:
        cur := 0;
      KEY_END:
        cur := Length(text);
      keyPaste:
        begin
          pv := PasteText(False);
          text := Copy(text, 1, cur) + pv + Copy(text, cur + 1, MaxInt);
          Inc(cur, Length(pv));
        end;
    else
      if ((key >= 32) and (key <= 126)) or ((key >= 128) and (key <= 255)) then
      begin
        text := Copy(text, 1, cur) + Chr(key) + Copy(text, cur + 1, MaxInt);
        Inc(cur);
      end;
    end;
  until False;
end;

function UIConfirm(const question: string): Boolean;
var
  key: LongInt;
begin
  UICursorVisible(False);
  DrawBar(ScreenRows - 1, cpError, ' ' + question + '    [y] yes    [n] no');
  UIRefresh;
  repeat
    key := getch;
    case key of
      Ord('y'), Ord('Y'): Exit(True);
      Ord('n'), Ord('N'), 27: Exit(False);
    end;
  until False;
end;

procedure UISuspend;
begin
  UICursorVisible(True);
  endwin; // restore the shell's terminal modes for the external program
end;

procedure UIResume;
begin
  clear;    // blanks stdscr and forces a physical screen clear on next refresh,
  refresh;  // which removes the external viewer's output; re-enters curses mode
  curs_set(0);
  TermRaw(#27'[?2004h'); // re-enable bracketed paste (an endwin may have reset it)
end;

end.
