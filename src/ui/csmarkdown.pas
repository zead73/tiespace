unit CsMarkdown;

(* A small, terminal-oriented markdown renderer. It turns a decoded content
   string into wrapped, styled display lines (TStyleLines) the thread view can
   draw with DrawRuns.

   Supported: ATX headings (#..######), **bold**/__bold__, *italic*/_italic_
   (italic shows as underline, since terminal italics are unreliable), `inline
   code`, [text](url) links (rendered as the underlined text), - / * / + and
   1. lists, > blockquotes, and --- horizontal rules. Everything else is plain
   text. Inline markers inside words (snake_case underscores) are left literal.

   It does NOT handle fenced code blocks or tables (rare in this content), and
   images are expected to be pre-cleaned to a placeholder by the caller. *)

{$mode objfpc}{$H+}

interface

uses
  CsUI;

{ Render markdown source into styled display lines wrapped to `width` cells. }
function RenderMarkdown(const src: string; width: Integer): TStyleLines;

implementation

uses
  SysUtils;

type
  TSCP = record          // one styled codepoint
    Cp: string;
    Pair: Integer;
    Bold, Ul: Boolean;
    W: Integer;
  end;
  TSCPArray = array of TSCP;

{ Append text to a run buffer, merging into the previous run if the style
  matches so runs stay coarse. }
procedure AddRun(var runs: TStyleRuns; const text: string; pair: Integer;
  bold, underline: Boolean);
begin
  if text = '' then
    Exit;
  if (Length(runs) > 0) and (runs[High(runs)].Pair = pair) and
     (runs[High(runs)].Bold = bold) and (runs[High(runs)].Underline = underline) then
    runs[High(runs)].Text := runs[High(runs)].Text + text
  else
  begin
    SetLength(runs, Length(runs) + 1);
    runs[High(runs)].Text := text;
    runs[High(runs)].Pair := pair;
    runs[High(runs)].Bold := bold;
    runs[High(runs)].Underline := underline;
  end;
end;

function IsAlnum(c: Char): Boolean; inline;
begin
  Result := c in ['a'..'z', 'A'..'Z', '0'..'9'];
end;

{ Parse inline emphasis / code / links into styled runs. `basePair` colours the
  plain text (cpText normally, cpMeta inside a blockquote). Italic maps to the
  underline attribute. }
function InlineRuns(const s: string; basePair: Integer): TStyleRuns;
var
  i, n, j, cb, ce: Integer;
  bold, ital: Boolean;
  buf, txt, url: string;
begin
  SetLength(Result, 0);
  i := 1;
  n := Length(s);
  bold := False;
  ital := False;
  buf := '';
  while i <= n do
  begin
    if (s[i] = '\') and (i < n) then // escaped char -> literal
    begin
      buf := buf + s[i + 1];
      Inc(i, 2);
      Continue;
    end;
    if s[i] = '`' then // inline code
    begin
      j := i + 1;
      while (j <= n) and (s[j] <> '`') do
        Inc(j);
      if j <= n then
      begin
        AddRun(Result, buf, basePair, bold, ital); buf := '';
        AddRun(Result, Copy(s, i + 1, j - i - 1), cpMeta, False, False);
        i := j + 1;
        Continue;
      end;
    end;
    if s[i] = '[' then // link [text](url)
    begin
      cb := i + 1;
      while (cb <= n) and (s[cb] <> ']') do
        Inc(cb);
      if (cb < n) and (s[cb + 1] = '(') then
      begin
        ce := cb + 2;
        while (ce <= n) and (s[ce] <> ')') do
          Inc(ce);
        if ce <= n then
        begin
          txt := Copy(s, i + 1, cb - i - 1);
          url := Copy(s, cb + 2, ce - cb - 2);
          if Trim(txt) = '' then
            txt := url;
          AddRun(Result, buf, basePair, bold, ital); buf := '';
          AddRun(Result, txt, cpAccent, False, True); // link = accent + underline
          i := ce + 1;
          Continue;
        end;
      end;
    end;
    // bold ** or __
    if ((s[i] = '*') and (i < n) and (s[i + 1] = '*')) or
       ((s[i] = '_') and (i < n) and (s[i + 1] = '_')) then
    begin
      if (s[i] = '_') and (i > 1) and IsAlnum(s[i - 1]) and
         (i + 2 <= n) and IsAlnum(s[i + 2]) then
      begin
        buf := buf + s[i]; // __ inside a word: literal
        Inc(i);
        Continue;
      end;
      AddRun(Result, buf, basePair, bold, ital); buf := '';
      bold := not bold;
      Inc(i, 2);
      Continue;
    end;
    // italic * or _
    if (s[i] = '*') or (s[i] = '_') then
    begin
      if (s[i] = '_') and (i > 1) and IsAlnum(s[i - 1]) and
         (i < n) and IsAlnum(s[i + 1]) then
      begin
        buf := buf + s[i]; // snake_case underscore: literal
        Inc(i);
        Continue;
      end;
      AddRun(Result, buf, basePair, bold, ital); buf := '';
      ital := not ital;
      Inc(i);
      Continue;
    end;
    buf := buf + s[i];
    Inc(i);
  end;
  AddRun(Result, buf, basePair, bold, ital);
end;

{ Break run text into styled codepoints for wrapping. }
function Flatten(const runs: TStyleRuns): TSCPArray;
var
  i, bi, blen: Integer;
  piece: string;
begin
  SetLength(Result, 0);
  for i := 0 to High(runs) do
  begin
    bi := 1;
    while bi <= Length(runs[i].Text) do
    begin
      blen := 1;
      while (bi + blen <= Length(runs[i].Text)) and
            ((Byte(runs[i].Text[bi + blen]) and $C0) = $80) do
        Inc(blen);
      piece := Copy(runs[i].Text, bi, blen);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Cp := piece;
      Result[High(Result)].Pair := runs[i].Pair;
      Result[High(Result)].Bold := runs[i].Bold;
      Result[High(Result)].Ul := runs[i].Underline;
      Result[High(Result)].W := VisibleWidth(piece);
      Inc(bi, blen);
    end;
  end;
end;

{ Word-wrap styled runs to `width`, preserving per-span styling and hard-breaking
  any single word longer than the width. Always emits at least one line. }
function WrapRuns(const runs: TStyleRuns; width: Integer): TStyleLines;
var
  scp: TSCPArray;
  lineRuns, wordScp: TStyleRuns;
  lineW, wordW, k, kk: Integer;

  procedure EmitLine;
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := lineRuns;
    SetLength(lineRuns, 0);
    lineW := 0;
  end;

  procedure FlushWord;
  var
    m, chunkW: Integer;
  begin
    if wordW = 0 then
      Exit;
    if wordW > width then // hard-break an over-long word
    begin
      if lineW > 0 then
        EmitLine;
      chunkW := 0;
      for m := 0 to High(wordScp) do
      begin
        if (chunkW > 0) and (chunkW + VisibleWidth(wordScp[m].Text) > width) then
        begin
          EmitLine;
          chunkW := 0;
        end;
        AddRun(lineRuns, wordScp[m].Text, wordScp[m].Pair, wordScp[m].Bold, wordScp[m].Underline);
        Inc(chunkW, VisibleWidth(wordScp[m].Text));
        lineW := chunkW;
      end;
      SetLength(wordScp, 0);
      wordW := 0;
      Exit;
    end;
    if (lineW > 0) and (lineW + 1 + wordW > width) then
      EmitLine;
    if lineW > 0 then
    begin
      AddRun(lineRuns, ' ', cpText, False, False);
      Inc(lineW);
    end;
    for m := 0 to High(wordScp) do
      AddRun(lineRuns, wordScp[m].Text, wordScp[m].Pair, wordScp[m].Bold, wordScp[m].Underline);
    lineW := lineW + wordW;
    SetLength(wordScp, 0);
    wordW := 0;
  end;

begin
  SetLength(Result, 0);
  if width < 1 then
    width := 1;
  scp := Flatten(runs);
  SetLength(lineRuns, 0);
  SetLength(wordScp, 0);
  lineW := 0;
  wordW := 0;
  for k := 0 to High(scp) do
  begin
    if scp[k].Cp = ' ' then
      FlushWord // space ends a word; runs of spaces collapse
    else
    begin
      kk := Length(wordScp);
      SetLength(wordScp, kk + 1);
      wordScp[kk].Text := scp[k].Cp;
      wordScp[kk].Pair := scp[k].Pair;
      wordScp[kk].Bold := scp[k].Bold;
      wordScp[kk].Underline := scp[k].Ul;
      Inc(wordW, scp[k].W);
    end;
  end;
  FlushWord;
  EmitLine; // final line (may be empty, which is the intended blank line)
end;

function RenderMarkdown(const src: string; width: Integer): TStyleLines;
var
  norm, line, trimmed, rest, ind, firstPfx, contPfx: string;
  segStart, i, n, hlevel, pfxPair, num: Integer;
  body: TStyleRuns;

  { Wrap `runs` and append them, giving the first display line `firstPfx` and
    the continuations `contPfx` (both in colour `pfxPair`). }
  procedure EmitBlock(const runs: TStyleRuns; const firstP, contP: string; pPair: Integer);
  var
    wrapped: TStyleLines;
    outRuns: TStyleRuns;
    w, r: Integer;
    p: string;
  begin
    w := width - VisibleWidth(firstP);
    if w < 1 then
      w := 1;
    wrapped := WrapRuns(runs, w);
    for r := 0 to High(wrapped) do
    begin
      SetLength(outRuns, 0);
      if r = 0 then
        p := firstP
      else
        p := contP;
      if p <> '' then
        AddRun(outRuns, p, pPair, False, False);
      for w := 0 to High(wrapped[r]) do
        AddRun(outRuns, wrapped[r][w].Text, wrapped[r][w].Pair,
          wrapped[r][w].Bold, wrapped[r][w].Underline);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := outRuns;
    end;
  end;

  function AllDashes(const s: string; ch: Char): Boolean;
  var
    j: Integer;
  begin
    Result := Length(s) >= 3;
    for j := 1 to Length(s) do
      if s[j] <> ch then
        Exit(False);
  end;

begin
  SetLength(Result, 0);
  norm := StringReplace(src, #13#10, #10, [rfReplaceAll]);
  norm := StringReplace(norm, #13, #10, [rfReplaceAll]);
  segStart := 1;
  n := Length(norm);
  for i := 1 to n + 1 do
    if (i > n) or (norm[i] = #10) then
    begin
      line := Copy(norm, segStart, i - segStart);
      segStart := i + 1;
      trimmed := TrimLeft(line);

      // leading indent (for nested lists / quotes)
      ind := Copy(line, 1, Length(line) - Length(trimmed));

      if Trim(line) = '' then // blank line
      begin
        SetLength(Result, Length(Result) + 1); // an empty display line
        Continue;
      end;

      // horizontal rule
      if AllDashes(Trim(line), '-') or AllDashes(Trim(line), '*') or
         AllDashes(Trim(line), '_') then
      begin
        SetLength(body, 0);
        AddRun(body, HLine(width), cpMeta, False, False);
        EmitBlock(body, '', '', cpMeta);
        Continue;
      end;

      // ATX heading
      hlevel := 0;
      while (hlevel < Length(trimmed)) and (trimmed[hlevel + 1] = '#') do
        Inc(hlevel);
      if (hlevel >= 1) and (hlevel <= 6) and (hlevel < Length(trimmed)) and
         (trimmed[hlevel + 1] = ' ') then
      begin
        rest := TrimLeft(Copy(trimmed, hlevel + 2, MaxInt));
        body := InlineRuns(rest, cpAccent);
        for num := 0 to High(body) do
          body[num].Bold := True; // headings are bold accent
        EmitBlock(body, '', '', cpAccent);
        Continue;
      end;

      // blockquote
      if (Length(trimmed) >= 1) and (trimmed[1] = '>') then
      begin
        rest := Copy(trimmed, 2, MaxInt);
        if (rest <> '') and (rest[1] = ' ') then
          Delete(rest, 1, 1);
        body := InlineRuns(rest, cpMeta);
        EmitBlock(body, ind + '│ ', ind + '│ ', cpMeta);
        Continue;
      end;

      // unordered list
      if (Length(trimmed) >= 2) and (trimmed[1] in ['-', '*', '+']) and
         (trimmed[2] = ' ') then
      begin
        rest := TrimLeft(Copy(trimmed, 3, MaxInt));
        body := InlineRuns(rest, cpText);
        firstPfx := ind + '• ';
        contPfx := StringOfChar(' ', VisibleWidth(firstPfx));
        EmitBlock(body, firstPfx, contPfx, cpAccent);
        Continue;
      end;

      // ordered list  (N. )
      num := 0;
      while (num < Length(trimmed)) and (trimmed[num + 1] in ['0'..'9']) do
        Inc(num);
      if (num >= 1) and (num + 1 < Length(trimmed)) and (trimmed[num + 1] = '.') and
         (trimmed[num + 2] = ' ') then
      begin
        rest := TrimLeft(Copy(trimmed, num + 3, MaxInt));
        firstPfx := ind + Copy(trimmed, 1, num) + '. ';
        body := InlineRuns(rest, cpText);
        contPfx := StringOfChar(' ', VisibleWidth(firstPfx));
        EmitBlock(body, firstPfx, contPfx, cpAccent);
        Continue;
      end;

      // plain paragraph line
      pfxPair := cpText;
      body := InlineRuns(TrimLeft(line), cpText);
      EmitBlock(body, ind, StringOfChar(' ', VisibleWidth(ind)), pfxPair);
    end;
end;

end.
