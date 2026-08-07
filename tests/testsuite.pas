program testsuite;

(* Pure-function unit tests — no network, no terminal.

   Covers the load-bearing, silently-breakable logic that the feature-by-feature
   "run it once, live" workflow can't catch: the defensive JSON parsers, HTML
   entity decoding, the entry summariser, relative-time edge cases, the
   client-side rate limiter, and the wcwidth/UTF-8 layout helpers.

   These units never call UIInit/initscr, so nothing here touches the terminal.
   The width tests rely on libc wcwidth, so a UTF-8 locale is adopted via clocale;
   the one genuinely locale-dependent assertion is skipped (not failed) otherwise.

   Build & run:  make test *)

{$mode objfpc}{$H+}

uses
  clocale, SysUtils, fpjson, jsonparser,
  CsModels, CsRateLimit, CsUI, CsMarkdown;

var
  gPass, gFail, gSkip: Integer;

procedure EqS(const got, want, name: string);
begin
  if got = want then Inc(gPass)
  else begin Inc(gFail); WriteLn('  FAIL ', name, ' — got [', got, '] want [', want, ']'); end;
end;

procedure EqI(got, want: Integer; const name: string);
begin
  if got = want then Inc(gPass)
  else begin Inc(gFail); WriteLn('  FAIL ', name, ' — got ', got, ' want ', want); end;
end;

procedure EqB(got, want: Boolean; const name: string);
begin
  if got = want then Inc(gPass)
  else begin Inc(gFail); WriteLn('  FAIL ', name, ' — got ', got, ' want ', want); end;
end;

procedure Skip(const name: string);
begin
  Inc(gSkip);
  WriteLn('  SKIP ', name);
end;

{ Parse a JSON object literal and hand the model parser the result. }
function PEntry(const j: string): TEntry;
var o: TJSONObject;
begin o := TJSONObject(GetJSON(j)); try Result := ParseEntry(o); finally o.Free; end; end;

function PNote(const j: string): TNote;
var o: TJSONObject;
begin o := TJSONObject(GetJSON(j)); try Result := ParseNote(o); finally o.Free; end; end;

function PGuild(const j: string): TGuild;
var o: TJSONObject;
begin o := TJSONObject(GetJSON(j)); try Result := ParseGuild(o); finally o.Free; end; end;

procedure TestDecodeEntities;
begin
  EqS(DecodeEntities('a &amp; b'), 'a & b', 'entities: amp');
  EqS(DecodeEntities('&lt;&gt;'), '<>', 'entities: lt/gt');
  EqS(DecodeEntities('&quot;x&quot;'), '"x"', 'entities: quot');
  EqS(DecodeEntities('it&#39;s'), 'it''s', 'entities: decimal &#39;');
  EqS(DecodeEntities('it&#x27;s'), 'it''s', 'entities: hex &#x27;');
  EqS(DecodeEntities('&#65;'), 'A', 'entities: decimal &#65;');
  EqS(DecodeEntities('a&nbsp;b'), 'a b', 'entities: nbsp -> space');
  EqS(DecodeEntities('&foo;'), '&foo;', 'entities: unknown kept verbatim');
  EqS(DecodeEntities('rock &amp roll'), 'rock &amp roll', 'entities: no semicolon kept');
  EqS(DecodeEntities('plain text'), 'plain text', 'entities: passthrough');
end;

procedure TestParsers;
var
  e: TEntry;
  n: TNote;
  g: TGuild;
begin
  e := PEntry('{"postId":"p1","authorUsername":"zead","title":"T &amp; U",'
    + '"content":"5 &lt; 6","isNSFW":true,"repliesCount":3,"topics":["a","b"]}');
  EqS(e.PostId, 'p1', 'ParseEntry: postId');
  EqS(e.AuthorUsername, 'zead', 'ParseEntry: author');
  EqS(e.Title, 'T & U', 'ParseEntry: title decoded');
  EqS(e.Content, '5 < 6', 'ParseEntry: content decoded');
  EqB(e.IsNSFW, True, 'ParseEntry: isNSFW');
  EqI(e.RepliesCount, 3, 'ParseEntry: repliesCount');
  EqI(Length(e.Topics), 2, 'ParseEntry: topics length');
  EqB(e.IsPublic, False, 'ParseEntry: isPublic default false');

  // id / revision / updatedAt fall back to their alternates.
  n := PNote('{"noteId":"n2","content":"hi","revisionNumber":5,'
    + '"createdAt":"2026-01-02T03:04:05Z"}');
  EqS(n.Id, 'n2', 'ParseNote: id from noteId');
  EqI(n.Revision, 5, 'ParseNote: revision from revisionNumber');
  EqS(n.UpdatedAt, '2026-01-02T03:04:05Z', 'ParseNote: updatedAt falls back to createdAt');

  n := PNote('{"id":"n1","content":"a &amp; b","revision":2,'
    + '"updatedAt":"2026-02-02T00:00:00Z","createdAt":"2026-01-01T00:00:00Z",'
    + '"topics":["journal"]}');
  EqS(n.Id, 'n1', 'ParseNote: id');
  EqS(n.Content, 'a & b', 'ParseNote: content decoded');
  EqI(n.Revision, 2, 'ParseNote: revision');
  EqS(n.UpdatedAt, '2026-02-02T00:00:00Z', 'ParseNote: explicit updatedAt');
  EqI(Length(n.Topics), 1, 'ParseNote: topics length');

  // role is JSON null when you aren't a member — must not blow up, must be ''.
  g := PGuild('{"id":"g1","name":"Night &amp; Day","slug":"nd","memberCount":42,'
    + '"isMember":false,"role":null}');
  EqS(g.Name, 'Night & Day', 'ParseGuild: name decoded');
  EqS(g.Slug, 'nd', 'ParseGuild: slug');
  EqI(g.MemberCount, 42, 'ParseGuild: memberCount');
  EqB(g.IsMember, False, 'ParseGuild: isMember false');
  EqS(g.Role, '', 'ParseGuild: null role -> empty string');

  g := PGuild('{"slug":"x","role":"founder","isMember":true}');
  EqS(g.Role, 'founder', 'ParseGuild: role founder');
  EqB(g.IsMember, True, 'ParseGuild: isMember true');
end;

procedure TestEntrySummary;
var e: TEntry;
begin
  e := Default(TEntry); e.Title := 'Hello';
  EqS(EntrySummary(e), 'Hello', 'EntrySummary: title wins');

  e := Default(TEntry); e.Deleted := True; e.Title := 'x';
  EqS(EntrySummary(e), '[deleted]', 'EntrySummary: deleted');

  e := Default(TEntry); e.Content := '# Heading'#10'body';
  EqS(EntrySummary(e), 'Heading', 'EntrySummary: first line, markdown stripped');

  e := Default(TEntry);
  EqS(EntrySummary(e), '(no title)', 'EntrySummary: empty -> (no title)');

  // FeedSummary: NSFW masking honours the filter flag.
  e := Default(TEntry); e.Title := 'Hi';
  EqS(FeedSummary(e, False), 'Hi', 'FeedSummary: non-NSFW plain');
  EqS(FeedSummary(e, True), 'Hi', 'FeedSummary: non-NSFW ignores the filter');
  e.IsNSFW := True;
  EqS(FeedSummary(e, False), '[NSFW] Hi', 'FeedSummary: NSFW labelled, filter off');
  EqS(FeedSummary(e, True), '[NSFW hidden]', 'FeedSummary: NSFW masked, filter on');
end;

procedure TestRelativeTime;
begin
  // Deterministic: a date this far in the past always renders as its ISO date,
  // and unparseable input degrades to the first 10 chars.
  EqS(RelativeTime('2000-01-01T00:00:00Z'), '2000-01-01', 'RelativeTime: old date -> ISO');
  EqS(RelativeTime('garbage'), 'garbage', 'RelativeTime: unparseable -> first chars');
end;

procedure TestRateLimit;
var m: string;
begin
  EqB(Limiter.Check('bookmark', m), True, 'RateLimit: fresh action allowed');

  Limiter.Note('follow'); Limiter.Note('follow'); Limiter.Note('follow'); // rule 3/min
  EqB(Limiter.Check('follow', m), False, 'RateLimit: 4th follow within a minute blocked');

  EqB(Limiter.Check('unknown-action', m), True, 'RateLimit: unknown action unlimited');

  Limiter.Note('entry'); Limiter.Note('entry'); // rule 2/min
  EqB(Limiter.Check('entry', m), False, 'RateLimit: 3rd entry within a minute blocked');
  EqB(Limiter.Check('reply', m), True, 'RateLimit: other actions unaffected');
end;

function LineText(const line: TStyleRuns): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(line) do
    Result := Result + line[i].Text;
end;

function FindRun(const doc: TStyleLines; const needle: string; out r: TStyleRun): Boolean;
var i, j: Integer;
begin
  Result := False;
  for i := 0 to High(doc) do
    for j := 0 to High(doc[i]) do
      if doc[i][j].Text = needle then
      begin
        r := doc[i][j];
        Exit(True);
      end;
end;

procedure TestMarkdown;
var
  doc: TStyleLines;
  r: TStyleRun;
begin
  doc := RenderMarkdown('a **b** c', 80);
  EqS(LineText(doc[0]), 'a b c', 'md: ** stripped');
  EqB(FindRun(doc, 'b', r) and r.Bold, True, 'md: ** -> bold');

  doc := RenderMarkdown('a *b* c', 80);
  EqS(LineText(doc[0]), 'a b c', 'md: * stripped');
  EqB(FindRun(doc, 'b', r) and r.Underline, True, 'md: * -> italic/underline');

  doc := RenderMarkdown('a `b` c', 80);
  EqB(FindRun(doc, 'b', r) and (r.Pair = cpMeta), True, 'md: `code` -> meta colour');

  doc := RenderMarkdown('[go](http://x)', 80);
  EqB(FindRun(doc, 'go', r) and (r.Pair = cpAccent) and r.Underline, True,
    'md: link -> accent + underline');
  doc := RenderMarkdown('[](http://x)', 80);
  EqS(LineText(doc[0]), 'http://x', 'md: empty link text -> url');

  doc := RenderMarkdown('# Title', 80);
  EqS(LineText(doc[0]), 'Title', 'md: heading marker stripped');
  EqB(FindRun(doc, 'Title', r) and r.Bold and (r.Pair = cpAccent), True,
    'md: heading -> bold accent');

  doc := RenderMarkdown('- item', 80);
  EqS(LineText(doc[0]), '• item', 'md: unordered bullet');
  doc := RenderMarkdown('1. item', 80);
  EqS(LineText(doc[0]), '1. item', 'md: ordered list');
  doc := RenderMarkdown('> quoted', 80);
  EqS(LineText(doc[0]), '│ quoted', 'md: blockquote prefix');

  doc := RenderMarkdown('snake_case_name', 80);
  EqS(LineText(doc[0]), 'snake_case_name', 'md: in-word underscores literal');

  doc := RenderMarkdown('aaa bbb ccc', 7);
  EqI(Length(doc), 2, 'md: wraps at width');
  EqS(LineText(doc[0]), 'aaa bbb', 'md: wrap line 1');
  EqS(LineText(doc[1]), 'ccc', 'md: wrap line 2');

  doc := RenderMarkdown('**aaa bbb**', 5);
  EqB((Length(doc) = 2) and FindRun(doc, 'aaa', r) and r.Bold, True, 'md: bold survives wrap (1)');
  EqB(FindRun(doc, 'bbb', r) and r.Bold, True, 'md: bold survives wrap (2)');
end;

procedure TestLayout;
var w: TTextLines;
begin
  // Codepoint counting (UTF-8 lead-byte aware).
  EqI(CodepointCount('abc'), 3, 'CodepointCount: ascii');
  EqI(CodepointCount('héllo'), 5, 'CodepointCount: 2-byte é');
  EqI(CodepointCount('中文'), 2, 'CodepointCount: CJK');
  EqI(CodepointCount('😀x'), 2, 'CodepointCount: 4-byte emoji');

  // Char-boundary navigation over 'aé' (bytes: a, C3, A9).
  EqI(NextCharBoundary('aé', 0), 1, 'NextCharBoundary: past ascii');
  EqI(NextCharBoundary('aé', 1), 3, 'NextCharBoundary: skips 2-byte char');
  EqI(PrevCharBoundary('aé', 3), 1, 'PrevCharBoundary: back over 2-byte char');
  EqI(PrevCharBoundary('aé', 1), 0, 'PrevCharBoundary: to start');

  // Display width via wcwidth.
  EqI(VisibleWidth('abc'), 3, 'VisibleWidth: ascii');
  if VisibleWidth('中') = 2 then
    EqI(VisibleWidth('中文'), 4, 'VisibleWidth: CJK is 2 cells each')
  else
    Skip('VisibleWidth: wide chars (needs a UTF-8 locale)');

  // Soft-wrap.
  w := WrapText('hello world', 5);
  EqI(Length(w), 2, 'WrapText: splits at width');
  EqS(w[0], 'hello', 'WrapText: first line');
  EqS(w[1], 'world', 'WrapText: second line');

  w := WrapText('a'#10#10'b', 10);
  EqI(Length(w), 3, 'WrapText: keeps blank line');
  EqS(w[1], '', 'WrapText: blank line preserved');

  w := WrapText('', 10);
  EqI(Length(w), 1, 'WrapText: empty -> one empty line');

  w := WrapText('abcdefgh', 3); // word longer than width -> chunked
  EqB((Length(w) >= 3) and (VisibleWidth(w[0]) <= 3), True, 'WrapText: chunks over-long word');

  // Pad / truncate.
  EqI(VisibleWidth(PadOrTrunc('hi', 6)), 6, 'PadOrTrunc: pads to exact width');
  EqS(PadOrTrunc('hi', 6), 'hi    ', 'PadOrTrunc: content + spaces');
  EqB(VisibleWidth(TruncEllipsis('abcdefgh', 5)) <= 5, True, 'TruncEllipsis: fits width');
  EqB(Pos('…', TruncEllipsis('abcdefgh', 5)) > 0, True, 'TruncEllipsis: adds ellipsis');
  EqS(TruncEllipsis('hi', 5), 'hi', 'TruncEllipsis: no-op when it fits');
end;

begin
  gPass := 0; gFail := 0; gSkip := 0;

  TestDecodeEntities;
  TestParsers;
  TestEntrySummary;
  TestRelativeTime;
  TestRateLimit;
  TestLayout;
  TestMarkdown;

  WriteLn;
  WriteLn(Format('tiespace tests: %d passed, %d failed, %d skipped',
    [gPass, gFail, gSkip]));
  if gFail > 0 then
    Halt(1);
end.
