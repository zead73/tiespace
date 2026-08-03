unit CsProfile;

(* A user's profile: header (display name, bio, stats, links) above a scrollable,
   selectable list of their entries. Enter opens an entry's thread; `f` follows. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunProfile(sess: TCsSession; const username: string);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsApi, CsRateLimit, CsThread;

const
  PAGE = 20;

function FetchUserPosts(sess: TCsSession; const username, cursor: string;
  out nextCursor, err: string): TEntryArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/users/' + username + '/posts?limit=' + IntToStr(PAGE);
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

procedure RunProfile(sess: TCsSession; const username: string);
var
  entries: TEntryArray;
  header: TRenderLines;
  userId, displayName, bio, cursor, nextCursor, err, joined, followId: string;
  followers, following: Integer;
  sel, listTop, hdrH, listVisible, key: Integer;
  loaded, iFollow: Boolean;

  procedure LoadProfile;
  var
    env, d: TJSONObject;
    website, wname, wurl, loc, fErr: string;
    wrapped: TTextLines;
    i, textW: Integer;
  begin
    loaded := False;
    err := '';
    try
      env := sess.Client.GetJSONObj('/v1/users/' + username);
      try
        d := CsData(env);
        userId := d.Get('userId', '');
        displayName := d.Get('displayName', '');
        bio := DecodeEntities(d.Get('bio', ''));
        followers := d.Get('followersCount', 0);
        following := d.Get('followingCount', 0);
        joined := Copy(d.Get('createdAt', ''), 1, 10);
        wname := d.Get('websiteName', '');
        wurl := d.Get('websiteUrl', '');
        loc := d.Get('locationName', '');
        loaded := True;
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;

    // Do we follow this user? (Needed to offer unfollow.) Skip for our own.
    iFollow := False;
    followId := '';
    if loaded and (userId <> '') and (userId <> sess.UserId) then
      iFollow := FindFollowing(sess, userId, followId, fErr);

    SetLength(header, 0);
    textW := ScreenCols - 2;
    if textW < 8 then
      textW := 8;
    if displayName <> '' then
    begin
      RLAdd(header, displayName, cpAccent, True);
      RLAdd(header, '@' + username, cpMeta);
    end
    else
      RLAdd(header, '@' + username, cpAccent, True);
    if Trim(bio) <> '' then
    begin
      RLAdd(header, '', cpText);
      wrapped := WrapText(bio, textW);
      for i := 0 to High(wrapped) do
        RLAdd(header, wrapped[i], cpText);
    end;
    RLAdd(header, '', cpText);
    RLAdd(header, Format('%d followers  ·  %d following  ·  joined %s',
      [followers, following, joined]), cpMeta);
    website := '';
    if wurl <> '' then
    begin
      if wname <> '' then
        website := wname + ' — ' + wurl
      else
        website := wurl;
      RLAdd(header, website, cpMeta);
    end;
    if loc <> '' then
      RLAdd(header, '📍 ' + loc, cpMeta);
    if (userId <> '') and (userId <> sess.UserId) then
    begin
      if iFollow then
        RLAdd(header, '✓ following  (f to unfollow)', cpAccent)
      else
        RLAdd(header, 'not following  (f to follow)', cpMeta);
    end;
    RLAdd(header, HLine(textW), cpMeta);
  end;

  procedure LoadEntries(reset: Boolean);
  var
    page: TEntryArray;
    oldLen, k: Integer;
  begin
    if reset then
    begin
      entries := FetchUserPosts(sess, username, '', nextCursor, err);
      cursor := nextCursor;
      sel := 0;
      listTop := 0;
    end
    else
    begin
      if cursor = '' then
        Exit;
      page := FetchUserPosts(sess, username, cursor, nextCursor, err);
      oldLen := Length(entries);
      SetLength(entries, oldLen + Length(page));
      for k := 0 to High(page) do
        entries[oldLen + k] := page[k];
      cursor := nextCursor;
    end;
  end;

  procedure DoFollowToggle;
  var
    fid, ferr, lerr: string;
  begin
    if userId = '' then
      Exit;
    if userId = sess.UserId then
    begin
      err := 'That''s your own profile.';
      Exit;
    end;
    if not Limiter.Check('follow', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if iFollow then
    begin
      if UnfollowUser(sess, followId, ferr) then
      begin
        Limiter.Note('follow');
        iFollow := False;
        followId := '';
        err := 'Unfollowed @' + username;
      end
      else
        err := 'Unfollow failed: ' + ferr;
    end
    else
    begin
      if FollowUser(sess, userId, fid, ferr) then
      begin
        Limiter.Note('follow');
        iFollow := True;
        followId := fid;
        err := 'Now following @' + username;
      end
      else
        err := 'Follow failed: ' + ferr;
    end;
    // Refresh header + follower count from the server, keeping our status line.
    ferr := err;
    LoadProfile;
    if err = '' then
      err := ferr;
  end;

  procedure RenderEntryRow(y: Integer; const e: TEntry; selected: Boolean);
  var
    W, sumX, sumW, rightW, rightX: Integer;
    right, summary: string;
  begin
    W := ScreenCols;
    right := '';
    if e.RepliesCount > 0 then
      right := IntToStr(e.RepliesCount) + '↩  ';
    right := right + RelativeTime(e.CreatedAt);
    summary := EntrySummary(e);
    if e.IsNSFW then
      summary := '[NSFW] ' + summary;
    rightW := VisibleWidth(right);
    sumX := 2;
    rightX := W - rightW - 1;
    sumW := rightX - sumX - 1;
    if sumW < 4 then
      sumW := 4;
    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      DrawText(y, sumX, cpSelect, PadOrTrunc(summary, sumW));
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, sumX, cpText, PadOrTrunc(summary, sumW));
      if rightX > 0 then
        DrawText(y, rightX, cpMeta, right);
    end;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    fLabel: string;
  begin
    UIErase;
    DrawBar(0, cpHeader, ' profile   ·   @' + username);
    if userId = sess.UserId then
      fLabel := ''
    else if iFollow then
      fLabel := ' · f unfollow'
    else
      fLabel := ' · f follow';

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
    if sel > High(entries) then
      sel := High(entries);
    if sel < listTop then
      listTop := sel;
    if sel >= listTop + listVisible then
      listTop := sel - listVisible + 1;
    if listTop < 0 then
      listTop := 0;

    for i := 0 to listVisible - 1 do
    begin
      idx := listTop + i;
      if idx <= High(entries) then
        RenderEntryRow(1 + hdrH + i, entries[idx], idx = sel);
    end;

    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err)
    else if Length(entries) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no entries' + fLabel + ' · r reload · q back')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d entries   ·   j/k · Enter open%s · r reload · q back',
        [sel + 1, Length(entries), fLabel]));
    UIRefresh;
  end;

begin
  err := '';
  LoadProfile;
  LoadEntries(True);
  repeat
    Redraw;
    key := UIGetKey;
    if (key <> Ord('r')) and (err <> '') then
      err := '';
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(entries) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(entries) - 3) then
            LoadEntries(False);
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + listVisible;
          if (cursor <> '') and (sel > High(entries) - 3) then
            LoadEntries(False);
          if sel > High(entries) then
            sel := High(entries);
        end;
      KEY_PPAGE:
        sel := sel - listVisible;
      Ord('g'):
        sel := 0;
      Ord('G'):
        begin
          if cursor <> '' then
            LoadEntries(False);
          sel := High(entries);
        end;
      Ord('f'):
        DoFollowToggle;
      Ord('r'):
        begin
          err := '';
          LoadProfile;
          LoadEntries(True);
        end;
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(entries)) then
          RunThread(sess, entries[sel]);
    end;
  until False;
end;

end.
