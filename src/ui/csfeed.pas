unit CsFeed;

(* The feed view: a scrollable, paginated list of entries from GET /v1/posts.
   This is the first interactive screen. Reading is the point; opening a thread
   and composing arrive in the next build. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

{ Runs the feed loop. Returns True if the user chose to log out (caller should
  return to the login screen), False if they quit the app. }
function RunFeed(sess: TCsSession): Boolean;

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsApi, CsThread, CsNotify,
  CsCompose, CsRooms, CsMail, CsProfile, Csearch, CsTopics, CsBookmarks, CsGuilds,
  CsNotes, CsWatches, CsRateLimit;

const
  PAGE = 25;

function FetchFeedPage(sess: TCsSession; const cursor: string;
  out nextCursor, err: string): TEntryArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/posts?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseEntryArray(TJSONArray(d));
      nextCursor := env.Get('cursor', '');
    finally
      env.Free;
    end;
  except
    on E: ECsApi do
      err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do
      err := E.Message;
  end;
end;

function RunFeed(sess: TCsSession): Boolean;
var
  entries: TEntryArray;
  cursor, nextCursor, err, derr, bid: string;
  sel, top, visible, key: LongInt;
  unread: Integer;

  procedure RefreshUnread;
  var
    uerr: string;
  begin
    if not FetchUnreadCount(sess, unread, uerr) then
      unread := 0;
  end;

  procedure LoadFirst;
  begin
    entries := FetchFeedPage(sess, '', nextCursor, err);
    cursor := nextCursor;
    sel := 0;
    top := 0;
    RefreshUnread;
  end;

  procedure LoadMore;
  var
    page: TEntryArray;
    oldLen, k: Integer;
  begin
    if cursor = '' then
      Exit;
    page := FetchFeedPage(sess, cursor, nextCursor, err);
    oldLen := Length(entries);
    SetLength(entries, oldLen + Length(page));
    for k := 0 to High(page) do
      entries[oldLen + k] := page[k];
    cursor := nextCursor;
  end;

  procedure RenderRow(y: LongInt; const e: TEntry; selected: Boolean);
  var
    W, authorX, authorW, sumX, sumW, rightW, rightX: Integer;
    right, summary, author: string;
  begin
    W := ScreenCols;
    author := '@' + e.AuthorUsername;
    right := '';
    if e.RepliesCount > 0 then
      right := IntToStr(e.RepliesCount) + '↩  ';
    right := right + RelativeTime(e.CreatedAt);
    summary := EntrySummary(e);
    if e.IsNSFW then
      summary := '[NSFW] ' + summary;

    rightW := VisibleWidth(right);
    authorX := 2;
    authorW := 16;
    sumX := authorX + authorW + 1;
    rightX := W - rightW - 1;
    sumW := rightX - sumX - 1;
    if sumW < 4 then
      sumW := 4;

    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      DrawText(y, authorX, cpSelect, PadOrTrunc(author, authorW), True);
      DrawText(y, sumX, cpSelect, PadOrTrunc(summary, sumW));
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, authorX, cpAccent, PadOrTrunc(author, authorW), True);
      DrawText(y, sumX, cpText, PadOrTrunc(summary, sumW));
      if rightX > 0 then
        DrawText(y, rightX, cpMeta, right);
    end;
  end;

procedure ShowHelp;
const
  h: array[0..20] of string = (
    '+----------------------------------------------------------------------+',
    '|                        TIESPACE - KEYBINDINGS                        |',
    '+----------------------------------+-----------------------------------+',
    '| NAVIGATION & VIEWS               | ACTIONS & CONTROLS                |',
    '|   g        Guilds                |   j / k, Up/Dn   Move up / down   |',
    '|   t        Topics                |   Home / G       Top / Bottom     |',
    '|   b / B    Bookmark / List       |   PgUp / PgDn    Page up / down   |',
    '|   n / N    Notify / Notes        |   Enter          Open / Select    |',
    '|   C        cIRC Chat             |   c              New entry / Post |',
    '|   M        C-Mail (Direct)       |   d              Delete own entry |',
    '|   p        Author Profile        |   /              Search           |',
    '|   r        Reload screen         |   q / Q          Quit / Log out   |',
    '|   W        Watches               |   ?              This help        |',
    '+----------------------------------+-----------------------------------+',
    '| CONTEXT SHORTCUTS                                                    |',
    '|   In Guild     [Enter] Thread [c] New  [m] Members [J/L] Join/Leave  |',
    '|   In Notes     [Enter] Read   [c] New  [e] Edit    [v] Revisions     |',
    '|   In Notes     [d] Delete                                            |',
    '|   In Thread    [c] Reply [i] Images [d] Delete [w] Watch [q] Back    |',
    '|   In Chat/Mail [Type+Enter] Send [Up/PgUp] Scroll  [Esc] Back        |',
    '+----------------------------------------------------------------------+'
  );
var
  i, closeRow: Integer;

  { Draw a run of line `s` (0-based col `cidx`, length `clen`) in a colour,
    at its original screen column so the box alignment is preserved. }
  procedure Seg(row: Integer; const s: string; cidx, clen, pair: Integer; bold: Boolean);
  begin
    if clen > 0 then
      DrawText(row, 2 + cidx, pair, Copy(s, cidx + 1, clen), bold);
  end;

  { A two-column cell: bold-highlight the leading key token (the run up to the
    first 2+ space gap), then draw its description in the default colour. }
  procedure DrawCell(row: Integer; const s: string; cidx, cw: Integer);
  var
    cell: string;
    keyStart, keyEnd, descStart: Integer;
  begin
    cell := Copy(s, cidx + 1, cw);
    keyStart := 0;
    while (keyStart < Length(cell)) and (cell[keyStart + 1] = ' ') do
      Inc(keyStart);
    if keyStart >= Length(cell) then
      Exit; // empty cell
    keyEnd := keyStart;
    while (keyEnd < Length(cell)) and
          not ((cell[keyEnd + 1] = ' ') and (keyEnd + 2 <= Length(cell)) and
               (cell[keyEnd + 2] = ' ')) do
      Inc(keyEnd);
    Seg(row, s, cidx + keyStart, keyEnd - keyStart, cpMeta, True); // key
    descStart := keyEnd;
    while (descStart < Length(cell)) and (cell[descStart + 1] = ' ') do
      Inc(descStart);
    if descStart < Length(cell) then
      Seg(row, s, cidx + descStart, Length(cell) - descStart, cpText, False); // desc
  end;

  { A context row: plain text with any [bracketed] keys bold-highlighted. }
  procedure DrawContext(row: Integer; const s: string);
  var
    p, e: Integer;
  begin
    Seg(row, s, 1, 70, cpText, False);
    p := 2;
    while p <= 71 do
    begin
      if s[p] = '[' then
      begin
        e := p;
        while (e <= 71) and (s[e] <> ']') do
          Inc(e);
        if e <= 71 then
        begin
          Seg(row, s, p - 1, e - p + 1, cpMeta, True);
          p := e + 1;
          Continue;
        end;
      end;
      Inc(p);
    end;
  end;

begin
  UIErase;
  DrawBar(0, cpHeader, ' tiespace - help');

  for i := 0 to High(h) do
  begin
    if 2 + i > ScreenRows - 1 then
      Break;
    DrawText(2 + i, 2, cpAccent, h[i]); // frame first (cyan borders/dividers)
    case i of                           // then overlay content by row kind
      1:      Seg(2 + i, h[i], 1, 70, cpHeader, True);   // title band
      3:      begin                                       // section headers
                Seg(2 + i, h[i], 1, 34, cpAccent, True);
                Seg(2 + i, h[i], 36, 35, cpAccent, True);
              end;
      4..12:  begin                                       // two key columns
                DrawCell(2 + i, h[i], 1, 34);
                DrawCell(2 + i, h[i], 36, 35);
              end;
      14:     Seg(2 + i, h[i], 1, 70, cpAccent, True);    // CONTEXT SHORTCUTS
      15..19: DrawContext(2 + i, h[i]);                    // context rows
    end;                                                   // 0/2/13/20: borders
  end;

  // Sits just below the box, centred under it; clamped so it stays on screen.
  closeRow := 2 + Length(h);
  if closeRow > ScreenRows - 1 then
    closeRow := ScreenRows - 1;
  DrawText(closeRow, 25, cpMeta, '[ Press any key to close ]', True);

  UIRefresh;
  UIGetKey;
end;

  procedure Redraw;
  var
    status, more: string;
    i, idx: Integer;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(entries) then
      sel := High(entries);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;

    UIErase;
    if unread > 0 then
      DrawBar(0, cpHeader, ' tiespace   ·   feed   ·   @' + sess.Username +
        '   ·   ' + IntToStr(unread) + ' unread notifs (n)')
    else
      DrawBar(0, cpHeader, ' tiespace   ·   feed   ·   @' + sess.Username);

    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(entries) then
        RenderRow(1 + i, entries[idx], idx = sel);
    end;

    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q quit)')
    else
    begin
      if cursor <> '' then
        more := ' · more below'
      else
        more := '';
      if Length(entries) = 0 then
        status := ' no entries   ·   c post · C chat · g guilds · N notes · ? help · q quit'
      else
        status := Format(' %d/%d%s   ·   Enter open · c post · g guilds · N notes · ? help · q quit',
          [sel + 1, Length(entries), more]);
      DrawBar(ScreenRows - 1, cpStatus, status);
    end;
    UIRefresh;
  end;

begin
  Result := False;
  err := '';
  LoadFirst;
  repeat
    Redraw;
    key := UIGetKey;
    case key of
      Ord('q'), 27:
        Break;
      Ord('Q'):
        begin
          Result := True; // log out
          Break;
        end;
      Ord('j'), KEY_DOWN:
        if sel < High(entries) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(entries) - 3) then
            LoadMore;
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + visible;
          if (cursor <> '') and (sel > High(entries) - 3) then
            LoadMore;
          if sel > High(entries) then
            sel := High(entries);
        end;
      KEY_PPAGE:
        sel := sel - visible;
      KEY_HOME:
        sel := 0;
      KEY_END, Ord('G'):
        begin
          if cursor <> '' then
            LoadMore;
          sel := High(entries);
        end;
      Ord('g'):
        begin
          RunGuilds(sess);
          err := '';
        end;
      Ord('r'):
        begin
          err := '';
          LoadFirst;
        end;
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(entries)) then
        begin
          if RunThread(sess, entries[sel]) then
            LoadFirst; // entry changed (reply/delete) -> refresh
          err := ''; // clear any stale feed error after returning
        end;
      Ord('d'):
        if (sel >= 0) and (sel <= High(entries)) then
        begin
          if entries[sel].AuthorUsername <> sess.Username then
            err := 'You can only delete your own entries.'
          else if UIConfirm('Delete your entry "' +
                   TruncEllipsis(EntrySummary(entries[sel]), 40) + '"?') then
          begin
            if DeleteEntry(sess, entries[sel].PostId, derr) then
              LoadFirst
            else
              err := 'Delete failed: ' + derr;
          end;
        end;
      Ord('n'):
        begin
          RunNotifications(sess);
          RefreshUnread;
          err := '';
        end;
      Ord('c'):
        begin
          if ComposeEntry(sess) then
            LoadFirst; // reload so the new entry shows
          err := '';
        end;
      Ord('C'):
        begin
          RunRooms(sess);
          err := '';
        end;
      Ord('M'):
        begin
          RunMail(sess);
          err := '';
        end;
      Ord('N'):
        begin
          RunNotes(sess);
          err := '';
        end;
      Ord('W'):
        begin
          RunWatches(sess);
          err := '';
        end;
      Ord('p'):
        if (sel >= 0) and (sel <= High(entries)) then
        begin
          RunProfile(sess, entries[sel].AuthorUsername);
          err := '';
        end;
      Ord('/'):
        begin
          RunSearch(sess);
          err := '';
        end;
      Ord('t'):
        begin
          RunTopics(sess);
          err := '';
        end;
      Ord('B'):
        begin
          RunBookmarks(sess);
          err := '';
        end;
      Ord('?'):
        ShowHelp;
      Ord('b'):
        if (sel >= 0) and (sel <= High(entries)) then
        begin
          if not Limiter.Check('bookmark', derr) then
            err := derr
          else if CreateBookmarkPost(sess, entries[sel].PostId, bid, derr) then
          begin
            Limiter.Note('bookmark');
            err := 'Bookmarked.';
          end
          else
            err := 'Bookmark failed: ' + derr;
        end;
    end;
  until False;
end;

end.
