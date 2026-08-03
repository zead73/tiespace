unit CsGuilds;

(* Guilds: member groups, each with its own forum of threads. Three screens:

   RunGuilds       — the guild directory (most-populated first). Enter opens one.
   RunGuild        — a guild: header + membership + its forum threads. Enter opens
                     a thread; c starts one; m lists members; J/L join/leave.
   RunGuildMembers — the member roster. Enter opens a member's profile.

   A user belongs to at most one guild at a time; the forum itself is open, so
   anyone can read and start threads regardless of membership. Guild threads are
   ordinary entries, so opening one reuses the normal thread view. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunGuilds(sess: TCsSession);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsApi, CsRateLimit,
  CsThread, CsProfile, CsCompose;

const
  PAGE = 20;

function FetchGuilds(sess: TCsSession; const cursor: string;
  out nextCursor, err: string): TGuildArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/guilds?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseGuildArray(TJSONArray(d));
      nextCursor := env.Get('cursor', '');
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchGuildThreads(sess: TCsSession; const slug, cursor: string;
  out nextCursor, err: string): TEntryArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/guilds/' + slug + '/posts?limit=' + IntToStr(PAGE);
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
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchGuildMembers(sess: TCsSession; const slug, cursor: string;
  out nextCursor, err: string): TGuildMemberArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/guilds/' + slug + '/members?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseGuildMemberArray(TJSONArray(d));
      nextCursor := env.Get('cursor', '');
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

{ ----- Member roster ------------------------------------------------------- }

procedure RunGuildMembers(sess: TCsSession; const slug, guildName: string);
var
  members: TGuildMemberArray;
  cursor, nextCursor, err: string;
  sel, top, visible, key: Integer;

  procedure LoadMore(reset: Boolean);
  var
    page: TGuildMemberArray;
    oldLen, k: Integer;
  begin
    if reset then
    begin
      members := FetchGuildMembers(sess, slug, '', nextCursor, err);
      cursor := nextCursor;
      sel := 0;
      top := 0;
    end
    else
    begin
      if cursor = '' then
        Exit;
      page := FetchGuildMembers(sess, slug, cursor, nextCursor, err);
      oldLen := Length(members);
      SetLength(members, oldLen + Length(page));
      for k := 0 to High(page) do
        members[oldLen + k] := page[k];
      cursor := nextCursor;
    end;
  end;

  procedure RenderRow(y: Integer; const m: TGuildMember; selected: Boolean);
  var
    left, right: string;
    rightW, rightX, leftW: Integer;
  begin
    left := '@' + m.Username;
    if m.DisplayName <> '' then
      left := left + '  ' + m.DisplayName;
    right := '';
    if m.Role <> '' then
      right := m.Role + '  ·  ';
    right := right + 'joined ' + RelativeTime(m.JoinedAt);
    rightW := VisibleWidth(right);
    rightX := ScreenCols - rightW - 1;
    leftW := rightX - 3;
    if leftW < 4 then
      leftW := 4;
    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      DrawText(y, 2, cpSelect, PadOrTrunc(left, leftW), True);
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, 2, cpAccent, PadOrTrunc(left, leftW), True);
      if rightX > 0 then
        DrawText(y, rightX, cpMeta, right);
    end;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(members) then
      sel := High(members);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' members   ·   ' + guildName);
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(members) then
        RenderRow(1 + i, members[idx], idx = sel);
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (q back)')
    else if Length(members) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no members   ·   q back')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d   ·   j/k · Enter profile · q back',
        [sel + 1, Length(members)]));
    UIRefresh;
  end;

begin
  err := '';
  LoadMore(True);
  repeat
    Redraw;
    key := UIGetKey;
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(members) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(members) - 3) then
            LoadMore(False);
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + visible;
          if (cursor <> '') and (sel > High(members) - 3) then
            LoadMore(False);
          if sel > High(members) then
            sel := High(members);
        end;
      KEY_PPAGE:
        sel := sel - visible;
      Ord('g'):
        sel := 0;
      Ord('G'):
        sel := High(members);
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(members)) then
          RunProfile(sess, members[sel].Username);
    end;
  until False;
end;

{ ----- One guild: header, membership, forum threads ------------------------ }

procedure RunGuild(sess: TCsSession; const slug: string);
var
  g: TGuild;
  threads: TEntryArray;
  header: TRenderLines;
  cursor, nextCursor, err: string;
  sel, listTop, hdrH, listVisible, key: Integer;
  loaded: Boolean;

  procedure LoadGuild;
  var
    wrapped: TTextLines;
    i, textW: Integer;
    founded: string;
  begin
    loaded := FetchGuild(sess, slug, g, err);
    SetLength(header, 0);
    if not loaded then
      Exit;
    textW := ScreenCols - 2;
    if textW < 8 then
      textW := 8;
    if g.Icon <> '' then
      RLAdd(header, g.Icon + '  ' + g.Name, cpAccent, True)
    else
      RLAdd(header, g.Name, cpAccent, True);
    RLAdd(header, '@' + g.Slug, cpMeta);
    if Trim(g.Bio) <> '' then
    begin
      RLAdd(header, '', cpText);
      wrapped := WrapText(g.Bio, textW);
      for i := 0 to High(wrapped) do
        RLAdd(header, wrapped[i], cpText);
    end;
    RLAdd(header, '', cpText);
    founded := Copy(g.CreatedAt, 1, 10);
    RLAdd(header, Format('%d members  ·  founded by @%s  ·  %s',
      [g.MemberCount, g.FounderUsername, founded]), cpMeta);
    if g.Link <> '' then
    begin
      if g.LinkText <> '' then
        RLAdd(header, g.LinkText + ' — ' + g.Link, cpMeta)
      else
        RLAdd(header, g.Link, cpMeta);
    end;
    if g.Role = 'founder' then
      RLAdd(header, '★ founder  (manage on the web)', cpAccent)
    else if g.IsMember then
      RLAdd(header, '✓ member  (L to leave)', cpAccent)
    else
      RLAdd(header, 'not a member  (J to join)', cpMeta);
    RLAdd(header, HLine(textW), cpMeta);
  end;

  procedure LoadThreads(reset: Boolean);
  var
    page: TEntryArray;
    oldLen, k: Integer;
  begin
    if reset then
    begin
      threads := FetchGuildThreads(sess, slug, '', nextCursor, err);
      cursor := nextCursor;
      sel := 0;
      listTop := 0;
    end
    else
    begin
      if cursor = '' then
        Exit;
      page := FetchGuildThreads(sess, slug, cursor, nextCursor, err);
      oldLen := Length(threads);
      SetLength(threads, oldLen + Length(page));
      for k := 0 to High(page) do
        threads[oldLen + k] := page[k];
      cursor := nextCursor;
    end;
  end;

  procedure DoJoin;
  var
    lerr, jerr, keep: string;
  begin
    if g.IsMember then
    begin
      err := 'You''re already a member.';
      Exit;
    end;
    if not Limiter.Check('guild_join', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if JoinGuild(sess, slug, jerr) then
    begin
      Limiter.Note('guild_join');
      keep := 'Joined ' + g.Name + ' ✓';
      LoadGuild;
      err := keep;
    end
    else
      err := 'Join failed: ' + jerr;
  end;

  procedure DoLeave;
  var
    lerr, lverr, keep: string;
  begin
    if g.Role = 'founder' then
    begin
      err := 'Founders manage the guild on the web.';
      Exit;
    end;
    if not g.IsMember then
    begin
      err := 'You''re not a member.';
      Exit;
    end;
    if not UIConfirm('Leave ' + g.Name + '?') then
      Exit;
    if not Limiter.Check('guild_leave', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if LeaveGuild(sess, slug, lverr) then
    begin
      Limiter.Note('guild_leave');
      keep := 'Left ' + g.Name + '.';
      LoadGuild;
      err := keep;
    end
    else
      err := 'Leave failed: ' + lverr;
  end;

  procedure DoNewThread;
  begin
    if ComposeGuildThread(sess, slug, g.Name) then
    begin
      LoadThreads(True);
      LoadGuild; // member count / activity may have moved
    end;
  end;

  procedure RenderThreadRow(y: Integer; const e: TEntry; selected: Boolean);
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

  procedure Redraw;
  var
    i, idx: Integer;
  begin
    UIErase;
    DrawBar(0, cpHeader, ' guild   ·   ' + slug);
    hdrH := Length(header);
    if hdrH > ScreenRows - 4 then
      hdrH := ScreenRows - 4;
    if hdrH < 0 then
      hdrH := 0;
    for i := 0 to hdrH - 1 do
      DrawText(1 + i, 1, header[i].Pair, header[i].Text, header[i].Bold);

    listVisible := ScreenRows - 2 - hdrH;
    if listVisible < 1 then
      listVisible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(threads) then
      sel := High(threads);
    if sel < listTop then
      listTop := sel;
    if sel >= listTop + listVisible then
      listTop := sel - listVisible + 1;
    if listTop < 0 then
      listTop := 0;

    for i := 0 to listVisible - 1 do
    begin
      idx := listTop + i;
      if idx <= High(threads) then
        RenderThreadRow(1 + hdrH + i, threads[idx], idx = sel);
    end;

    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err)
    else if not loaded then
      DrawBar(ScreenRows - 1, cpStatus, ' could not load guild · r retry · q back')
    else if Length(threads) = 0 then
      DrawBar(ScreenRows - 1, cpStatus,
        ' no threads yet · c new · m members · r reload · q back')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d   ·   Enter open · c new · m members · r reload · q back',
        [sel + 1, Length(threads)]));
    UIRefresh;
  end;

begin
  err := '';
  LoadGuild;
  LoadThreads(True);
  repeat
    Redraw;
    key := UIGetKey;
    if (key <> Ord('r')) and (err <> '') then
      err := '';
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(threads) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(threads) - 3) then
            LoadThreads(False);
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + listVisible;
          if (cursor <> '') and (sel > High(threads) - 3) then
            LoadThreads(False);
          if sel > High(threads) then
            sel := High(threads);
        end;
      KEY_PPAGE:
        sel := sel - listVisible;
      Ord('g'):
        sel := 0;
      Ord('G'):
        begin
          if cursor <> '' then
            LoadThreads(False);
          sel := High(threads);
        end;
      Ord('c'):
        if loaded then
          DoNewThread;
      Ord('m'):
        if loaded then
          RunGuildMembers(sess, slug, g.Name);
      Ord('J'):
        DoJoin;
      Ord('L'):
        DoLeave;
      Ord('r'):
        begin
          err := '';
          LoadGuild;
          LoadThreads(True);
        end;
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(threads)) then
          if RunThread(sess, threads[sel]) then
            LoadThreads(True); // reply/delete changed the thread
    end;
  until False;
end;

{ ----- Guild directory ----------------------------------------------------- }

procedure RunGuilds(sess: TCsSession);
var
  guilds: TGuildArray;
  cursor, nextCursor, err: string;
  sel, top, visible, key: Integer;

  procedure LoadMore(reset: Boolean);
  var
    page: TGuildArray;
    oldLen, k: Integer;
  begin
    if reset then
    begin
      guilds := FetchGuilds(sess, '', nextCursor, err);
      cursor := nextCursor;
      sel := 0;
      top := 0;
    end
    else
    begin
      if cursor = '' then
        Exit;
      page := FetchGuilds(sess, cursor, nextCursor, err);
      oldLen := Length(guilds);
      SetLength(guilds, oldLen + Length(page));
      for k := 0 to High(page) do
        guilds[oldLen + k] := page[k];
      cursor := nextCursor;
    end;
  end;

  procedure RenderRow(y: Integer; const gu: TGuild; selected: Boolean);
  var
    left, right: string;
    rightW, rightX, leftW: Integer;
  begin
    if gu.Icon <> '' then
      left := gu.Icon + '  ' + gu.Name
    else
      left := gu.Name;
    right := IntToStr(gu.MemberCount) + ' members';
    rightW := VisibleWidth(right);
    rightX := ScreenCols - rightW - 1;
    leftW := rightX - 3;
    if leftW < 4 then
      leftW := 4;
    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      DrawText(y, 2, cpSelect, PadOrTrunc(left, leftW), True);
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, 2, cpAccent, PadOrTrunc(left, leftW), True);
      if rightX > 0 then
        DrawText(y, rightX, cpMeta, right);
    end;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    more: string;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(guilds) then
      sel := High(guilds);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   guilds');
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(guilds) then
        RenderRow(1 + i, guilds[idx], idx = sel);
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q back)')
    else if Length(guilds) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no guilds · r reload · q back')
    else
    begin
      if cursor <> '' then
        more := ' · more below'
      else
        more := '';
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d%s   ·   j/k · Enter open · r reload · q back',
        [sel + 1, Length(guilds), more]));
    end;
    UIRefresh;
  end;

begin
  err := '';
  LoadMore(True);
  repeat
    Redraw;
    key := UIGetKey;
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(guilds) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(guilds) - 3) then
            LoadMore(False);
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + visible;
          if (cursor <> '') and (sel > High(guilds) - 3) then
            LoadMore(False);
          if sel > High(guilds) then
            sel := High(guilds);
        end;
      KEY_PPAGE:
        sel := sel - visible;
      Ord('g'):
        sel := 0;
      Ord('G'):
        begin
          if cursor <> '' then
            LoadMore(False);
          sel := High(guilds);
        end;
      Ord('r'):
        begin
          err := '';
          LoadMore(True);
        end;
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(guilds)) then
          RunGuild(sess, guilds[sel].Slug);
    end;
  until False;
end;

end.
