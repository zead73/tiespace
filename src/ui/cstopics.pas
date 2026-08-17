unit CsTopics;

(* Topics: a list of all topics (most-used first), and the entries filed under a
   chosen topic. Enter on a topic opens its entry list; Enter on an entry opens
   its thread. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunTopics(sess: TCsSession);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsThread;

const
  PAGE = 20;

type
  TTopic = record
    Id: string;    // topicId / slug — used to fetch the topic's entries
    Name: string;  // display name (may be multi-word)
    Count: Integer;
  end;
  TTopicArray = array of TTopic;

function FetchTopics(sess: TCsSession; out err: string): TTopicArray;
var
  env, o: TJSONObject;
  d: TJSONData;
  a: TJSONArray;
  i: Integer;
begin
  SetLength(Result, 0);
  err := '';
  try
    env := sess.Client.GetJSONObj('/v1/topics');
    try
      d := env.Find('data');
      if d is TJSONArray then
      begin
        a := TJSONArray(d);
        SetLength(Result, a.Count);
        for i := 0 to a.Count - 1 do
          if a.Items[i] is TJSONObject then
          begin
            o := TJSONObject(a.Items[i]);
            Result[i].Id := o.Get('topicId', o.Get('slug', o.Get('name', '')));
            Result[i].Name := o.Get('name', o.Get('topic', Result[i].Id));
            Result[i].Count := o.Get('postsCount',
              o.Get('count', o.Get('postCount', o.Get('entryCount', 0))));
          end
          else if a.Items[i] is TJSONString then
          begin
            Result[i].Id := a.Items[i].AsString;
            Result[i].Name := Result[i].Id;
            Result[i].Count := -1;
          end;
      end;
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchTopicPosts(sess: TCsSession; const slug, cursor: string;
  out nextCursor, err: string): TEntryArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/topics/' + slug + '/posts?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if d is TJSONArray then
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

procedure RunTopicPosts(sess: TCsSession; const id, name: string);
var
  entries: TEntryArray;
  cursor, nextCursor, err: string;
  sel, top, visible, key: Integer;

  procedure LoadFirst;
  begin
    entries := FetchTopicPosts(sess, id, '', nextCursor, err);
    cursor := nextCursor;
    sel := 0;
    top := 0;
  end;

  procedure LoadMore;
  var
    page: TEntryArray;
    oldLen, k: Integer;
  begin
    if cursor = '' then
      Exit;
    page := FetchTopicPosts(sess, id, cursor, nextCursor, err);
    oldLen := Length(entries);
    SetLength(entries, oldLen + Length(page));
    for k := 0 to High(page) do
      entries[oldLen + k] := page[k];
    cursor := nextCursor;
  end;

  procedure RenderRow(y: Integer; const e: TEntry; selected: Boolean);
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
    summary := FeedSummary(e, sess.FilterNSFW);
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
    more: string;
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
    DrawBar(0, cpHeader, ' topic   ·   #' + name);
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(entries) then
        RenderRow(1 + i, entries[idx], idx = sel);
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (q back)')
    else if Length(entries) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no entries   ·   q back')
    else
    begin
      if cursor <> '' then
        more := ' · more below'
      else
        more := '';
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d%s   ·   j/k · Enter open · q back',
        [sel + 1, Length(entries), more]));
    end;
    UIRefresh;
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
      Ord('g'):
        sel := 0;
      Ord('G'):
        sel := High(entries);
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(entries)) then
          RunThread(sess, entries[sel]);
    end;
  until False;
end;

procedure RunTopics(sess: TCsSession);
var
  topics: TTopicArray;
  err: string;
  sel, top, visible, key: Integer;

  procedure RenderRow(y: Integer; const t: TTopic; selected: Boolean);
  var
    right: string;
    rightX: Integer;
  begin
    if t.Count >= 0 then
      right := IntToStr(t.Count) + ' entries'
    else
      right := '';
    rightX := ScreenCols - VisibleWidth(right) - 1;
    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      DrawText(y, 2, cpSelect, PadOrTrunc('#' + t.Name, rightX - 3), True);
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, 2, cpAccent, PadOrTrunc('#' + t.Name, rightX - 3), True);
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
    if sel > High(topics) then
      sel := High(topics);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   topics');
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(topics) then
        RenderRow(1 + i, topics[idx], idx = sel);
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q back)')
    else if Length(topics) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no topics · r reload · q back')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d   ·   j/k · Enter open · r reload · q back',
        [sel + 1, Length(topics)]));
    UIRefresh;
  end;

begin
  err := '';
  topics := FetchTopics(sess, err);
  sel := 0;
  top := 0;
  repeat
    Redraw;
    key := UIGetKey;
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(topics) then
          Inc(sel);
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      Ord('g'):
        sel := 0;
      Ord('G'):
        sel := High(topics);
      Ord('r'):
        begin
          err := '';
          topics := FetchTopics(sess, err);
          sel := 0;
          top := 0;
        end;
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(topics)) then
          RunTopicPosts(sess, topics[sel].Id, topics[sel].Name);
    end;
  until False;
end;

end.
