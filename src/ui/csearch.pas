unit Csearch;

(* Full-text search across users, entries and replies (GET /v1/search?type=all).
   A query line at the top; results below as one flat, selectable list tagged by
   kind. Enter opens the hit: a user -> profile, a post -> its thread, a reply ->
   its parent thread. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunSearch(sess: TCsSession);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsApi, CsThread, CsProfile;

type
  TSearchKind = (skUser, skPost, skReply);
  TSearchItem = record
    Kind: TSearchKind;
    Display: string;
    Username: string;
    PostId: string;
    Entry: TEntry;
  end;
  TSearchItems = array of TSearchItem;

function UrlEncode(const s: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(s) do
  begin
    c := s[i];
    if c in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then
      Result := Result + c
    else
      Result := Result + '%' + IntToHex(Ord(c), 2);
  end;
end;

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

procedure RunSearch(sess: TCsSession);
var
  query, err: string;
  qCur: Integer;
  items: TSearchItems;
  sel, top, visible, key: Integer;
  editing: Boolean;

  procedure AddItem(k: TSearchKind; const disp, uname, pid: string; const e: TEntry);
  begin
    SetLength(items, Length(items) + 1);
    items[High(items)].Kind := k;
    items[High(items)].Display := disp;
    items[High(items)].Username := uname;
    items[High(items)].PostId := pid;
    items[High(items)].Entry := e;
  end;

  procedure DoSearch;
  var
    env, d: TJSONObject;
    arr: TJSONData;
    i: Integer;
    o: TJSONObject;
    e: TEntry;
    empty: TEntry;
  begin
    SetLength(items, 0);
    sel := 0;
    top := 0;
    err := '';
    if Trim(query) = '' then
      Exit;
    try
      env := sess.Client.GetJSONObj('/v1/search?type=all&q=' + UrlEncode(Trim(query)));
      try
        d := CsData(env);
        arr := d.Find('users');
        if arr is TJSONArray then
          for i := 0 to TJSONArray(arr).Count - 1 do
            if TJSONArray(arr).Items[i] is TJSONObject then
            begin
              o := TJSONObject(TJSONArray(arr).Items[i]);
              AddItem(skUser, '[user]  @' + o.Get('username', '?'),
                o.Get('username', ''), '', empty);
            end;
        arr := d.Find('posts');
        if arr is TJSONArray then
          for i := 0 to TJSONArray(arr).Count - 1 do
            if TJSONArray(arr).Items[i] is TJSONObject then
            begin
              e := ParseEntry(TJSONObject(TJSONArray(arr).Items[i]));
              AddItem(skPost, '[post]  @' + e.AuthorUsername + '  ·  ' + EntrySummary(e),
                e.AuthorUsername, e.PostId, e);
            end;
        arr := d.Find('replies');
        if arr is TJSONArray then
          for i := 0 to TJSONArray(arr).Count - 1 do
            if TJSONArray(arr).Items[i] is TJSONObject then
            begin
              o := TJSONObject(TJSONArray(arr).Items[i]);
              AddItem(skReply, '[reply] @' + o.Get('authorUsername', '?') + '  ·  ' +
                FirstLine(o.Get('content', '')), o.Get('authorUsername', ''),
                o.Get('postId', ''), empty);
            end;
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
    editing := Length(items) = 0; // jump to results if we got any
  end;

  procedure OpenSel;
  var
    e: TEntry;
    oerr: string;
  begin
    if (sel < 0) or (sel > High(items)) then
      Exit;
    case items[sel].Kind of
      skUser:
        RunProfile(sess, items[sel].Username);
      skPost:
        RunThread(sess, items[sel].Entry);
      skReply:
        if items[sel].PostId <> '' then
        begin
          if FetchEntryById(sess, items[sel].PostId, e, oerr) then
            RunThread(sess, e)
          else
            err := oerr;
        end;
    end;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    q: string;
  begin
    visible := ScreenRows - 3; // header + query line + status
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
    DrawBar(0, cpHeader, ' tiespace   ·   search');

    DrawBar(1, cpText, '');
    DrawText(1, 1, cpAccent, 'search: ', True);
    q := query;
    DrawText(1, 9, cpText, TruncEllipsis(q, ScreenCols - 10));

    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(items) then
      begin
        if idx = sel then
        begin
          DrawBar(2 + i, cpSelect, '');
          DrawText(2 + i, 1, cpSelect, items[idx].Display);
        end
        else
          DrawText(2 + i, 1, cpText, items[idx].Display);
      end;
    end;

    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err)
    else if editing then
      DrawBar(ScreenRows - 1, cpStatus, ' type a query · Enter search · Esc leave')
    else if Length(items) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no results · / edit query · Esc leave')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d   ·   j/k · Enter open · / new query · Esc leave',
        [sel + 1, Length(items)]));

    if editing then
    begin
      UICursorVisible(True);
      UIPlaceCursor(1, 9 + VisibleWidth(query));
    end
    else
      UICursorVisible(False);
    UIRefresh;
  end;

begin
  query := '';
  qCur := 0;
  err := '';
  editing := True;
  SetLength(items, 0);
  repeat
    Redraw;
    key := UIGetKey;
    if (err <> '') then
      err := '';
    if editing then
      case key of
        27: Break;
        10, 13, KEY_ENTER: DoSearch;
        KEY_BACKSPACE, 127, 8:
          if query <> '' then
          begin
            SetLength(query, Length(query) - 1);
            qCur := Length(query);
          end;
      else
        if (key >= 32) and (key <= 126) then
          query := query + Chr(key)
        else if (key >= 128) and (key <= 255) then
          query := query + Chr(key);
      end
    else
      case key of
        Ord('q'), 27:
          Break;
        Ord('/'):
          editing := True;
        Ord('j'), KEY_DOWN:
          if sel < High(items) then
            Inc(sel);
        Ord('k'), KEY_UP:
          if sel > 0 then
            Dec(sel);
        Ord('g'):
          sel := 0;
        Ord('G'):
          sel := High(items);
        10, 13, KEY_ENTER:
          OpenSel;
      end;
  until False;
  UICursorVisible(False);
end;

end.
