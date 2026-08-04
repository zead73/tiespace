unit CsWatches;

(* Threads you watch (GET /v1/watches). The list only carries postIds, so each
   row is resolved to "@author · summary" lazily — only the rows actually on
   screen are fetched, once each. Enter opens the thread; `x` unwatches it. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunWatches(sess: TCsSession);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsApi, CsRateLimit, CsThread;

const
  PAGE = 20;

type
  TWatch = record
    PostId: string;
    Display: string;   // resolved lazily from the post
    Resolved: Boolean;
  end;
  TWatchArray = array of TWatch;

function FetchWatchesPage(sess: TCsSession; const cursor: string;
  out nextCursor, err: string): TWatchArray;
var
  env: TJSONObject;
  d: TJSONData;
  a: TJSONArray;
  i, n: Integer;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/watches?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if d is TJSONArray then
      begin
        a := TJSONArray(d);
        n := 0;
        SetLength(Result, a.Count);
        for i := 0 to a.Count - 1 do
          if a.Items[i] is TJSONObject then
          begin
            Result[n].PostId := TJSONObject(a.Items[i]).Get('postId', '');
            Result[n].Display := '';
            Result[n].Resolved := False;
            Inc(n);
          end;
        SetLength(Result, n);
      end;
      nextCursor := env.Get('cursor', '');
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

procedure RunWatches(sess: TCsSession);
var
  items: TWatchArray;
  cursor, nextCursor, err: string;
  sel, top, visible, key: Integer;

  procedure LoadMore(reset: Boolean);
  var
    page: TWatchArray;
    oldLen, k: Integer;
  begin
    if reset then
    begin
      items := FetchWatchesPage(sess, '', nextCursor, err);
      cursor := nextCursor;
      sel := 0;
      top := 0;
    end
    else
    begin
      if cursor = '' then
        Exit;
      page := FetchWatchesPage(sess, cursor, nextCursor, err);
      oldLen := Length(items);
      SetLength(items, oldLen + Length(page));
      for k := 0 to High(page) do
        items[oldLen + k] := page[k];
      cursor := nextCursor;
    end;
  end;

  { Fill a row's Display from its post, once. Called for on-screen rows only. }
  procedure Resolve(idx: Integer);
  var
    e: TEntry;
    ferr: string;
  begin
    if (idx < 0) or (idx > High(items)) or items[idx].Resolved then
      Exit;
    items[idx].Resolved := True;
    if items[idx].PostId = '' then
    begin
      items[idx].Display := '[unknown thread]';
      Exit;
    end;
    if FetchEntryById(sess, items[idx].PostId, e, ferr) then
      items[idx].Display := '@' + e.AuthorUsername + '  ·  ' + EntrySummary(e)
    else
      items[idx].Display := '(unavailable) ' + items[idx].PostId;
  end;

  procedure OpenSel;
  var
    e: TEntry;
    oerr: string;
  begin
    if (sel < 0) or (sel > High(items)) then
      Exit;
    if FetchEntryById(sess, items[sel].PostId, e, oerr) then
      RunThread(sess, e)
    else
      err := oerr;
  end;

  procedure UnwatchSel;
  var
    lerr, uerr: string;
  begin
    if (sel < 0) or (sel > High(items)) then
      Exit;
    if not Limiter.Check('watch', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if UnwatchThread(sess, items[sel].PostId, uerr) then
    begin
      Limiter.Note('watch');
      LoadMore(True);
    end
    else
      err := 'Unwatch failed: ' + uerr;
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
    if sel > High(items) then
      sel := High(items);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   watched threads   ·   @' + sess.Username);
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(items) then
      begin
        Resolve(idx); // only on-screen rows hit the network, once each
        if idx = sel then
        begin
          DrawBar(1 + i, cpSelect, '');
          DrawText(1 + i, 0, cpSelect, '›');
          DrawText(1 + i, 2, cpSelect, PadOrTrunc(items[idx].Display, ScreenCols - 3));
        end
        else
          DrawText(1 + i, 2, cpText, PadOrTrunc(items[idx].Display, ScreenCols - 3));
      end;
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q back)')
    else if Length(items) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no watched threads   ·   r reload · q back')
    else
    begin
      if cursor <> '' then
        more := ' · more below'
      else
        more := '';
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d%s   ·   j/k · Enter open · x unwatch · r reload · q back',
        [sel + 1, Length(items), more]));
    end;
    UIRefresh;
  end;

begin
  err := '';
  LoadMore(True);
  repeat
    Redraw;
    key := UIGetKey;
    if (key <> Ord('r')) and (err <> '') then
      err := '';
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(items) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(items) - 3) then
            LoadMore(False);
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + visible;
          if (cursor <> '') and (sel > High(items) - 3) then
            LoadMore(False);
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
            LoadMore(False);
          sel := High(items);
        end;
      Ord('x'):
        UnwatchSel;
      Ord('r'):
        begin
          err := '';
          LoadMore(True);
        end;
      10, 13, KEY_ENTER:
        OpenSel;
    end;
  until False;
end;

end.
