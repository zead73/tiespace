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
  CsRateLimit;

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
    h: array[0..16] of string = (
      'tiespace — feed keys',
      '',
      '  j / k, ↑ / ↓      move          Enter   open thread',
      '  Home / G          top / bottom  PgUp/Dn page',
      '  g                 guilds        p       author profile',
      '  c                 new entry     d       delete own entry',
      '  b                 bookmark      B       bookmarks list',
      '  /                 search        t       topics',
      '  n                 notifications',
      '  C                 cIRC chat     M       C-Mail (direct msgs)',
      '  r                 reload        Q       log out',
      '  q                 quit',
      '',
      'In a guild: Enter thread · c new · m members · J/L join/leave',
      'In a thread: c reply · i images · d delete · q back',
      'In chat/mail: type + Enter send · ↑/PgUp scroll · Esc back',
      'Press any key to close');
    var i: Integer;
  begin
    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   help');
    for i := 0 to High(h) do
      if 2 + i <= ScreenRows - 1 then
        DrawText(2 + i, 2, cpText, h[i]);
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
        status := ' no entries   ·   c post · C chat · g guilds · ? help · q quit'
      else
        status := Format(' %d/%d%s   ·   Enter open · c post · g guilds · ? help · q quit',
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
