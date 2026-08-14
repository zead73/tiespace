unit CsNotify;

(* The notifications view: a paginated list of your notifications with an
   unread marker, opening the related thread on Enter (and marking it read),
   plus mark-all-read. Read state is updated optimistically in the local list;
   the feed refetches the unread count when this view returns. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunNotifications(sess: TCsSession);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsApi, CsThread;

const
  PAGE = 20;

function FetchNotificationsPage(sess: TCsSession; const cursor: string;
  out nextCursor, err: string): TNotificationArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/notifications?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseNotificationArray(TJSONArray(d));
      nextCursor := env.Get('cursor', '');
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

procedure MarkRead(sess: TCsSession; const id: string);
var
  env: TJSONObject;
begin
  try
    env := sess.Client.PatchJSONObj('/v1/notifications/' + id, nil);
    env.Free;
  except
    on E: Exception do ; // best-effort; local state already updated
  end;
end;

procedure MarkAllRead(sess: TCsSession);
var
  env: TJSONObject;
  more: Boolean;
  guard: Integer;
begin
  // read-all marks up to 5,000 per call and returns hasMore; loop until done.
  // Capped and best-effort: any error just stops the loop.
  guard := 0;
  repeat
    more := False;
    Inc(guard);
    try
      env := sess.Client.PostJSONObj('/v1/notifications/read-all', nil);
      try
        more := CsData(env).Get('hasMore', False);
      finally
        env.Free;
      end;
    except
      on E: Exception do more := False;
    end;
  until (not more) or (guard >= 40);
end;

procedure RunNotifications(sess: TCsSession);
var
  items: TNotificationArray;
  cursor, nextCursor, err: string;
  sel, top, visible, key: LongInt;

  procedure LoadFirst;
  begin
    items := FetchNotificationsPage(sess, '', nextCursor, err);
    cursor := nextCursor;
    sel := 0;
    top := 0;
  end;

  procedure LoadMore;
  var
    page: TNotificationArray;
    oldLen, k: Integer;
  begin
    if cursor = '' then
      Exit;
    page := FetchNotificationsPage(sess, cursor, nextCursor, err);
    oldLen := Length(items);
    SetLength(items, oldLen + Length(page));
    for k := 0 to High(page) do
      items[oldLen + k] := page[k];
    cursor := nextCursor;
  end;

  procedure OpenSel;
  var
    n: TNotification;
    e: TEntry;
    rep: TReply;
    resolved: Boolean;
  begin
    if (sel < 0) or (sel > High(items)) then
      Exit;
    n := items[sel];
    if not n.Read then
    begin
      MarkRead(sess, n.Id);
      items[sel].Read := True;
    end;

    resolved := False;
    err := '';
    if (n.MetaAuthorUsername <> '') and (n.MetaPostSlug <> '') then
      resolved := FetchEntryBySlug(sess, n.MetaAuthorUsername, n.MetaPostSlug, e, err)
    else if (n.TargetType = 'post') and (n.TargetId <> '') then
      resolved := FetchEntryById(sess, n.TargetId, e, err)
    else if (n.TargetType = 'reply') and (n.TargetId <> '') then
    begin
      if FetchReplyById(sess, n.TargetId, rep, err) then
        resolved := FetchEntryById(sess, rep.PostId, e, err);
    end
    else if n.MetaReplyId <> '' then
    begin
      if FetchReplyById(sess, n.MetaReplyId, rep, err) then
        resolved := FetchEntryById(sess, rep.PostId, e, err);
    end;

    if resolved then
    begin
      RunThread(sess, e);
      err := '';
    end
    else if err = '' then
      err := 'Nothing to open for this notification';
  end;

  procedure RenderRow(y: LongInt; const n: TNotification; selected: Boolean);
  var
    W, authorX, aw, phraseX, phraseW, rightW, rightX: Integer;
    author, phrase, right, mark: string;
  begin
    W := ScreenCols;
    author := '@' + n.ActorUsername;
    phrase := NotificationPhrase(n);
    right := RelativeTime(n.CreatedAt);
    if n.Read then
      mark := ' '
    else
      mark := '●';

    aw := VisibleWidth(author);
    if aw > 22 then
      aw := 22;
    authorX := 2;
    phraseX := authorX + aw + 1;
    rightW := VisibleWidth(right);
    rightX := W - rightW - 1;
    phraseW := rightX - phraseX - 1;
    if phraseW < 4 then
      phraseW := 4;

    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, mark);
      DrawText(y, authorX, cpSelect, PadOrTrunc(author, aw), True);
      DrawText(y, phraseX, cpSelect, PadOrTrunc(phrase, phraseW));
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, 0, cpAccent, mark, True);
      DrawText(y, authorX, cpAccent, PadOrTrunc(author, aw), True);
      DrawText(y, phraseX, cpText, PadOrTrunc(phrase, phraseW));
      if rightX > 0 then
        DrawText(y, rightX, cpMeta, right);
    end;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    status, more: string;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(items) then
      sel := High(items);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;

    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   notifications   ·   @' + sess.Username);

    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(items) then
        RenderRow(1 + i, items[idx], idx = sel);
    end;

    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q back)')
    else
    begin
      if cursor <> '' then
        more := ' · more below'
      else
        more := '';
      if Length(items) = 0 then
        status := ' no notifications   ·   r reload · q back'
      else
        status := Format(' %d/%d%s   ·   j/k move · Enter open · a read-all · r reload · q back',
          [sel + 1, Length(items), more]);
      DrawBar(ScreenRows - 1, cpStatus, status);
    end;
    UIRefresh;
  end;

  procedure MarkAllLocal;
  var
    i: Integer;
  begin
    MarkAllRead(sess);
    for i := 0 to High(items) do
      items[i].Read := True;
    err := '';
  end;

begin
  err := '';
  LoadFirst;
  repeat
    Redraw;
    key := UIGetKey;
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(items) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(items) - 3) then
            LoadMore;
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + visible;
          if (cursor <> '') and (sel > High(items) - 3) then
            LoadMore;
          if sel > High(items) then
            sel := High(items);
        end;
      KEY_PPAGE:
        sel := sel - visible;
      Ord('g'):
        sel := 0;
      Ord('G'):
        begin
          if cursor <> '' then
            LoadMore;
          sel := High(items);
        end;
      Ord('a'):
        MarkAllLocal;
      Ord('r'):
        begin
          err := '';
          LoadFirst;
        end;
      10, 13, KEY_ENTER:
        OpenSel;
    end;
  until False;
end;

end.
