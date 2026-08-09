unit CsBookmarks;

(* Your bookmarks: a list of saved entries/replies. Enter opens the referenced
   thread; `x` removes a bookmark. The bookmark record shape isn't pinned in the
   docs, so fields are read defensively (embedded post/reply if present, else the
   ids). *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunBookmarks(sess: TCsSession);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsApi, CsThread;

const
  PAGE = 20;

type
  TBookmark = record
    Id: string;       // bookmark document id (for removal)
    Kind: string;     // 'post' or 'reply'
    TargetId: string; // postId or replyId
    Display: string;
    Resolved: Boolean; // False when Display is just the id (needs a lazy fetch)
  end;
  TBookmarkArray = array of TBookmark;

function FirstLine(const s: string): string;
var
  p: Integer;
begin
  Result := s;
  p := Pos(#10, Result);
  if p > 0 then
    Result := Copy(Result, 1, p - 1);
  Result := Trim(DecodeEntities(Result));
end;

function ParseBookmark(o: TJSONObject): TBookmark;
var
  sub: TJSONData;
  src: TJSONObject;
  author, content, title: string;
begin
  Result.Id := o.Get('id', o.Get('bookmarkId', ''));
  Result.Kind := o.Get('type', '');
  Result.TargetId := o.Get('postId', o.Get('replyId', ''));
  if Result.Kind = '' then
    if o.Find('replyId') <> nil then
      Result.Kind := 'reply'
    else
      Result.Kind := 'post';

  // Prefer an embedded post/reply object; fall back to top-level fields.
  sub := o.Find('post');
  if sub = nil then
    sub := o.Find('entry');
  if sub = nil then
    sub := o.Find('reply');
  if sub is TJSONObject then
    src := TJSONObject(sub)
  else
    src := o;
  author := src.Get('authorUsername', '');
  content := src.Get('content', '');
  title := src.Get('title', '');

  if author <> '' then
  begin
    Result.Display := '@' + author + '  ·  ';
    if Trim(title) <> '' then
      Result.Display := Result.Display + Trim(DecodeEntities(title))
    else
      Result.Display := Result.Display + FirstLine(content);
    Result.Resolved := True;
  end
  else
  begin
    // No embedded post/reply — fall back to the id and resolve it lazily.
    Result.Display := '[' + Result.Kind + ']  ' + Result.TargetId;
    Result.Resolved := False;
  end;
end;

function FetchBookmarks(sess: TCsSession; const cursor: string;
  out nextCursor, err: string): TBookmarkArray;
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
  path := '/v1/bookmarks?limit=' + IntToStr(PAGE);
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
            Result[n] := ParseBookmark(TJSONObject(a.Items[i]));
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

procedure RunBookmarks(sess: TCsSession);
var
  items: TBookmarkArray;
  cursor, nextCursor, err: string;
  sel, top, visible, key: Integer;

  procedure LoadFirst;
  begin
    items := FetchBookmarks(sess, '', nextCursor, err);
    cursor := nextCursor;
    sel := 0;
    top := 0;
  end;

  procedure LoadMore;
  var
    page: TBookmarkArray;
    oldLen, k: Integer;
  begin
    if cursor = '' then
      Exit;
    page := FetchBookmarks(sess, cursor, nextCursor, err);
    oldLen := Length(items);
    SetLength(items, oldLen + Length(page));
    for k := 0 to High(page) do
      items[oldLen + k] := page[k];
    cursor := nextCursor;
  end;

  procedure OpenSel;
  var
    e: TEntry;
    r: TReply;
    oerr: string;
  begin
    if (sel < 0) or (sel > High(items)) then
      Exit;
    if items[sel].Kind = 'reply' then
    begin
      if FetchReplyById(sess, items[sel].TargetId, r, oerr) then
      begin
        if FetchEntryById(sess, r.PostId, e, oerr) then
          RunThread(sess, e)
        else
          err := oerr;
      end
      else
        err := oerr;
    end
    else if FetchEntryById(sess, items[sel].TargetId, e, oerr) then
      RunThread(sess, e)
    else
      err := oerr;
  end;

  procedure RemoveSel;
  var
    rerr: string;
  begin
    if (sel < 0) or (sel > High(items)) then
      Exit;
    if items[sel].Id = '' then
    begin
      err := 'No bookmark id to remove.';
      Exit;
    end;
    if RemoveBookmark(sess, items[sel].Id, rerr) then
      LoadFirst
    else
      err := 'Remove failed: ' + rerr;
  end;

  { Fill a row's Display from its target post/reply, once. On-screen rows only. }
  procedure Resolve(idx: Integer);
  var
    e: TEntry;
    r: TReply;
    ferr: string;
  begin
    if (idx < 0) or (idx > High(items)) or items[idx].Resolved then
      Exit;
    items[idx].Resolved := True; // one attempt; keep the id fallback on failure
    if items[idx].TargetId = '' then
      Exit;
    if items[idx].Kind = 'reply' then
    begin
      if FetchReplyById(sess, items[idx].TargetId, r, ferr) then
        items[idx].Display := '@' + r.AuthorUsername + '  ·  ' + FirstLine(r.Content);
    end
    else if FetchEntryById(sess, items[idx].TargetId, e, ferr) then
      items[idx].Display := '@' + e.AuthorUsername + '  ·  ' + EntrySummary(e);
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
    DrawBar(0, cpHeader, ' tiespace   ·   bookmarks   ·   @' + sess.Username);
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(items) then
      begin
        Resolve(idx); // lazy: only on-screen rows hit the network, once each
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
      DrawBar(ScreenRows - 1, cpStatus, ' no bookmarks   ·   r reload · q back')
    else
    begin
      if cursor <> '' then
        more := ' · more below'
      else
        more := '';
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d%s   ·   j/k · Enter open · x remove · r reload · q back',
        [sel + 1, Length(items), more]));
    end;
    UIRefresh;
  end;

begin
  err := '';
  LoadFirst;
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
            LoadMore;
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      Ord('g'):
        sel := 0;
      Ord('G'):
        sel := High(items);
      Ord('x'):
        RemoveSel;
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
