unit CsRooms;

(* cIRC: the room list and a room's message history (read side, REST only).

   Slice 1 of real-time chat: browse rooms, open one, read history (scrollback),
   and view any images in it. Live message streaming (RTDB SSE), sending, and
   presence come in later slices. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunRooms(sess: TCsSession);

implementation

uses
  SysUtils, DateUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsSSE, CsApi,
  CsRateLimit, CsImage;

function FetchRooms(sess: TCsSession; out err: string): TRoomArray;
var
  env: TJSONObject;
  d: TJSONData;
begin
  SetLength(Result, 0);
  err := '';
  try
    env := sess.Client.GetJSONObj('/v1/circ');
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseRoomArray(TJSONArray(d));
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchHistory(sess: TCsSession; const roomId, before: string;
  out err: string): TChatMessageArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  err := '';
  path := '/v1/circ/' + roomId + '?limit=50';
  if before <> '' then
    path := path + '&before=' + before;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseChatMessageArray(TJSONArray(d));
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

procedure RunRoom(sess: TCsSession; const room: TRoom);
var
  msgs: TChatMessageArray;
  lines: TRenderLines;
  lineMsg: array of Integer; // message index each line belongs to (-1 = none)
  err, roomId, streamUrl, inputBuf, presUrl: string;
  top, visible, key, lastCols, inputCur, selMsg: Integer;
  selMode: Boolean;
  stream: TChatStreamThread;
  presence: TPresenceThread;
  onlineNames: TNameArray;
  heartbeatMs, staleAfterMs: Integer;
  lastBeat: TDateTime;

  function MaxTop: Integer;
  begin
    Result := High(lines) - visible + 1;
    if Result < 0 then
      Result := 0;
  end;

  function PanelW: Integer;
  begin
    if ScreenCols >= 64 then
      Result := 20
    else
      Result := 0; // too narrow: drop the online panel
  end;

  function IndexOfMsg(const id: string): Integer;
  var
    i: Integer;
  begin
    Result := -1;
    for i := 0 to High(msgs) do
      if msgs[i].Id = id then
        Exit(i);
  end;

  procedure SortMsgs;
  var
    i, j: Integer;
    tmp: TChatMessage;
  begin
    // small n; simple stable insertion sort by ascending timestamp
    for i := 1 to High(msgs) do
    begin
      tmp := msgs[i];
      j := i - 1;
      while (j >= 0) and (msgs[j].Timestamp > tmp.Timestamp) do
      begin
        msgs[j + 1] := msgs[j];
        Dec(j);
      end;
      msgs[j + 1] := tmp;
    end;
  end;

  procedure BuildLines; forward;

  procedure ApplyStreamOps;
  var
    ops: TSSEOpArray;
    i, k: Integer;
    wasBottom, changed: Boolean;
  begin
    if stream = nil then
      Exit;
    stream.DrainOps(ops);
    if Length(ops) = 0 then
      Exit;
    wasBottom := top >= MaxTop;
    changed := False;
    for i := 0 to High(ops) do
    begin
      k := IndexOfMsg(ops[i].Id);
      case ops[i].Kind of
        opUpsert:
          begin
            if k >= 0 then
              msgs[k] := ops[i].Msg
            else
            begin
              SetLength(msgs, Length(msgs) + 1);
              msgs[High(msgs)] := ops[i].Msg;
            end;
            changed := True;
          end;
        opRemove:
          if k >= 0 then
          begin
            for k := k to High(msgs) - 1 do
              msgs[k] := msgs[k + 1];
            SetLength(msgs, Length(msgs) - 1);
            changed := True;
          end;
        opMarkDeleted:
          if k >= 0 then
          begin
            msgs[k].Deleted := True;
            msgs[k].Content := '[DELETED]';
            changed := True;
          end;
      end;
    end;
    if changed then
    begin
      SortMsgs;
      BuildLines;
      if wasBottom then
        top := MaxTop;
    end;
  end;

  procedure LoadHistory(older: Boolean);
  var
    before: string;
    batch: TChatMessageArray;
    merged: TChatMessageArray;
    i: Integer;
  begin
    before := '';
    if older and (Length(msgs) > 0) then
      before := IntToStr(msgs[0].Timestamp);
    batch := FetchHistory(sess, roomId, before, err);
    if not older then
      msgs := batch
    else if Length(batch) > 0 then
    begin
      SetLength(merged, Length(batch) + Length(msgs));
      for i := 0 to High(batch) do
        merged[i] := batch[i];
      for i := 0 to High(msgs) do
        merged[Length(batch) + i] := msgs[i];
      msgs := merged;
    end;
  end;

  procedure BuildLines;
  var
    i, j, textW: Integer;
    header, content: string;
    wrapped: TTextLines;

    procedure AddML(const text: string; pair: Integer; bold: Boolean; mi: Integer);
    begin
      RLAdd(lines, text, pair, bold);
      SetLength(lineMsg, Length(lines));
      lineMsg[High(lineMsg)] := mi;
    end;

  begin
    SetLength(lines, 0);
    SetLength(lineMsg, 0);
    if PanelW > 0 then
      textW := ScreenCols - PanelW - 3 // leave room for the separator + panel
    else
      textW := ScreenCols - 2;
    if textW < 8 then
      textW := 8;

    for i := 0 to High(msgs) do
    begin
      if msgs[i].Deleted then
        AddML(MsToLocalHM(msgs[i].Timestamp) + '  @' + msgs[i].Username +
          '  [deleted]', cpMeta, False, i)
      else if msgs[i].IsAction then
        AddML(MsToLocalHM(msgs[i].Timestamp) + '  * ' + msgs[i].Username +
          ' ' + msgs[i].Content, cpMeta, False, i)
      else
      begin
        header := MsToLocalHM(msgs[i].Timestamp) + '  @' + msgs[i].Username;
        if msgs[i].IsChatAdmin then
          header := header + ' (admin)';
        AddML(header, cpAccent, True, i);
        content := msgs[i].Content;
        // An attachment with no caption sometimes repeats the URL as content.
        if (content = msgs[i].ImageUrl) or (content = msgs[i].GifUrl) then
          content := '';
        if content <> '' then
        begin
          wrapped := WrapText(content, textW - 2);
          for j := 0 to High(wrapped) do
            AddML('  ' + wrapped[j], cpText, False, i);
        end;
        if msgs[i].ImageUrl <> '' then
          AddML('  🖼 [image]', cpMeta, False, i);
        if msgs[i].GifUrl <> '' then
          AddML('  🖼 [gif]', cpMeta, False, i);
      end;
    end;

    if Length(lines) = 0 then
      AddML('(no messages yet)', cpMeta, False, -1);
  end;

  function FirstLineOfMsg(mi: Integer): Integer;
  var
    i: Integer;
  begin
    Result := -1;
    for i := 0 to High(lineMsg) do
      if lineMsg[i] = mi then
        Exit(i);
  end;

  function LastLineOfMsg(mi: Integer): Integer;
  var
    i: Integer;
  begin
    Result := -1;
    for i := 0 to High(lineMsg) do
      if lineMsg[i] = mi then
        Result := i;
  end;

  procedure ScrollToMsg;
  var
    s, e2: Integer;
  begin
    s := FirstLineOfMsg(selMsg);
    if s < 0 then
      Exit;
    e2 := LastLineOfMsg(selMsg);
    if s < top then
      top := s
    else if e2 >= top + visible then
      top := e2 - visible + 1;
    if top > MaxTop then
      top := MaxTop;
    if top < 0 then
      top := 0;
  end;

  function SubByCols(const s: string; startCol, widthCols: Integer): string;
  var
    idx, col, w, ni: Integer;
    chunk: string;
  begin
    Result := '';
    idx := 1;
    col := 0;
    while (idx <= Length(s)) and (col < startCol) do
    begin
      ni := NextCharBoundary(s, idx - 1) + 1;
      Inc(col, VisibleWidth(Copy(s, idx, ni - idx)));
      idx := ni;
    end;
    col := 0;
    while idx <= Length(s) do
    begin
      ni := NextCharBoundary(s, idx - 1) + 1;
      chunk := Copy(s, idx, ni - idx);
      w := VisibleWidth(chunk);
      if col + w > widthCols then
        Break;
      Result := Result + chunk;
      Inc(col, w);
      idx := ni;
    end;
  end;

  procedure Redraw;
  var
    i, idx, avail, curCol, startCol, sepX, count: Integer;
    live: string;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if top > MaxTop then
      top := MaxTop;
    if top < 0 then
      top := 0;

    if presence <> nil then
      presence.GetOnline(onlineNames, staleAfterMs);

    UIErase;
    if stream = nil then
      live := ''
    else if stream.GaveUp then
      live := '   ·   disconnected'
    else if stream.Connected then
      live := '   ·   ● live'
    else
      live := '   ·   connecting…';
    if (presence <> nil) and (Length(onlineNames) > 0) then
      count := Length(onlineNames)
    else
      count := room.OnlineCount;
    DrawBar(0, cpHeader, ' cIRC   ·   #' + room.Slug + '   ·   ' +
      IntToStr(count) + ' online' + live);

    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(lines) then
      begin
        if selMode and (idx <= High(lineMsg)) and (lineMsg[idx] = selMsg) then
          DrawText(1 + i, 0, cpAccent, '▎', True); // selected-message marker
        DrawText(1 + i, 1, lines[idx].Pair, lines[idx].Text, lines[idx].Bold);
      end;
    end;

    // Right-side online panel.
    if PanelW > 0 then
    begin
      sepX := ScreenCols - PanelW - 1;
      for i := 1 to ScreenRows - 2 do
        DrawText(i, sepX, cpMeta, '│');
      DrawText(1, sepX + 2, cpAccent, 'online (' + IntToStr(Length(onlineNames)) + ')', True);
      for i := 0 to High(onlineNames) do
      begin
        if 3 + i > ScreenRows - 2 then
          Break;
        DrawText(3 + i - 1, sepX + 2, cpText,
          TruncEllipsis(onlineNames[i], PanelW - 3));
      end;
    end;

    // Bottom line: select-mode hint, a transient error, or the input line.
    if selMode then
    begin
      UICursorVisible(False);
      DrawBar(ScreenRows - 1, cpStatus,
        ' SELECT · j/k pick · i view image · d delete own · Esc/Tab back to input');
    end
    else if err <> '' then
    begin
      UICursorVisible(False);
      DrawBar(ScreenRows - 1, cpError, ' ' + err);
    end
    else if inputBuf = '' then
    begin
      DrawBar(ScreenRows - 1, cpText, '');
      DrawText(ScreenRows - 1, 0, cpMeta,
        '> type · Enter send · ↑/PgUp scroll · Tab select/delete · Esc leave');
      UICursorVisible(True);
      UIPlaceCursor(ScreenRows - 1, 2);
    end
    else
    begin
      avail := ScreenCols - 3;
      if avail < 4 then
        avail := 4;
      curCol := VisibleWidth(Copy(inputBuf, 1, inputCur));
      if VisibleWidth(inputBuf) <= avail then
        startCol := 0
      else
      begin
        startCol := curCol - avail;
        if startCol < 0 then
          startCol := 0;
      end;
      DrawBar(ScreenRows - 1, cpText, '');
      DrawText(ScreenRows - 1, 0, cpText, '> ' + SubByCols(inputBuf, startCol, avail));
      UICursorVisible(True);
      UIPlaceCursor(ScreenRows - 1, 2 + (curCol - startCol));
    end;
    UIRefresh;
  end;

  procedure InsertInput(const s: string);
  begin
    if CodepointCount(inputBuf) >= 2048 then
      Exit;
    inputBuf := Copy(inputBuf, 1, inputCur) + s + Copy(inputBuf, inputCur + 1, MaxInt);
    Inc(inputCur, Length(s));
  end;

  procedure BackspaceInput;
  var
    p: Integer;
  begin
    if inputCur <= 0 then
      Exit;
    p := PrevCharBoundary(inputBuf, inputCur);
    inputBuf := Copy(inputBuf, 1, p) + Copy(inputBuf, inputCur + 1, MaxInt);
    inputCur := p;
  end;

  procedure ScrollUp(n: Integer);
  begin
    if top > 0 then
    begin
      Dec(top, n);
      if top < 0 then
        top := 0;
    end
    else
    begin
      LoadHistory(True); // at the top already: pull older history
      SortMsgs;
      BuildLines;
      top := 0;
    end;
  end;

  procedure ScrollDown(n: Integer);
  begin
    Inc(top, n);
    if top > MaxTop then
      top := MaxTop;
  end;

  procedure DoSend;
  var
    mid, serr, lerr: string;
  begin
    if Trim(inputBuf) = '' then
      Exit;
    if not Limiter.Check('chat', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if SendChatMessage(sess, roomId, inputBuf, mid, serr) then
    begin
      Limiter.Note('chat');
      inputBuf := '';
      inputCur := 0;
      top := MaxTop; // follow to the bottom to watch it arrive
    end
    else
      err := 'Send failed: ' + serr;
  end;

  procedure DoDeleteMsg;
  var
    derr, lerr: string;
  begin
    if (selMsg < 0) or (selMsg > High(msgs)) then
      Exit;
    if msgs[selMsg].Username <> sess.Username then
    begin
      err := 'You can only delete your own messages.';
      Exit;
    end;
    if msgs[selMsg].Deleted then
    begin
      err := 'Already deleted.';
      Exit;
    end;
    if not Limiter.Check('chat_delete', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if UIConfirm('Delete your message? This cannot be undone.') then
    begin
      if DeleteChatMessage(sess, roomId, msgs[selMsg].Id, derr) then
      begin
        Limiter.Note('chat_delete');
        // The stream will also deliver the soft-delete; reflect it immediately.
        msgs[selMsg].Deleted := True;
        msgs[selMsg].Content := '[DELETED]';
        BuildLines;
      end
      else
        err := 'Delete failed: ' + derr;
    end;
  end;

  procedure ViewSelImage;
  var
    imgs: TImageRefs;
  begin
    if (selMsg < 0) or (selMsg > High(msgs)) then
      Exit;
    SetLength(imgs, 0);
    if msgs[selMsg].ImageUrl <> '' then
    begin
      SetLength(imgs, Length(imgs) + 1);
      imgs[High(imgs)].Alt := '@' + msgs[selMsg].Username;
      imgs[High(imgs)].Url := msgs[selMsg].ImageUrl;
    end;
    if msgs[selMsg].GifUrl <> '' then
    begin
      SetLength(imgs, Length(imgs) + 1);
      imgs[High(imgs)].Alt := '@' + msgs[selMsg].Username + ' (gif)';
      imgs[High(imgs)].Url := msgs[selMsg].GifUrl;
    end;
    if Length(imgs) = 0 then
    begin
      err := 'That message has no image.';
      Exit;
    end;
    ViewImages(imgs); // suspends the TUI, shells out to chafa, restores
    UIInputTimeout(300); // restore timed input for the live stream
  end;

  procedure Heartbeat;
  var
    e: string;
  begin
    if MilliSecondsBetween(Now, lastBeat) >= heartbeatMs then
    begin
      AnnouncePresence(sess, roomId, heartbeatMs, staleAfterMs, e); // errors ignored
      lastBeat := Now;
    end;
  end;

var
  base: string;
begin
  roomId := room.Slug;
  if roomId = '' then
    roomId := room.Id;
  err := '';
  inputBuf := '';
  inputCur := 0;
  selMode := False;
  selMsg := -1;
  stream := nil;
  presence := nil;
  SetLength(onlineNames, 0);
  heartbeatMs := 30000;
  staleAfterMs := 180000;

  // A fresh idToken keeps the stream valid for ~1h (a viewing session).
  try
    sess.Refresh;
  except
    on E: Exception do ;
  end;

  LoadHistory(False);
  BuildLines;
  visible := ScreenRows - 2;
  top := MaxTop; // start at the newest messages
  lastCols := ScreenCols;

  // Open the live stream: chat_messages/<room> over RTDB SSE.
  base := sess.RtdbUrl;
  if (base <> '') and (base[Length(base)] = '/') then
    SetLength(base, Length(base) - 1);
  if (base <> '') and (sess.IdToken <> '') then
  begin
    streamUrl := base + '/chat_messages/' + roomId +
      '.json?auth=' + sess.IdToken + '&orderBy=%22timestamp%22&limitToLast=50';
    stream := TChatStreamThread.Create(streamUrl);
    presUrl := base + '/chat_presence/' + roomId + '.json?auth=' + sess.IdToken;
    presence := TPresenceThread.Create(presUrl);
  end;

  // Announce ourselves so others see us in the room, then heartbeat in the loop.
  AnnouncePresence(sess, roomId, heartbeatMs, staleAfterMs, err);
  err := '';
  lastBeat := Now;

  UIInputTimeout(300); // wake ~3x/sec to drain streamed messages
  try
    repeat
      if ScreenCols <> lastCols then
      begin
        BuildLines;
        lastCols := ScreenCols;
      end;
      ApplyStreamOps;
      Heartbeat;
      Redraw;
      key := UIGetKey;
      if (key <> -1) and (err <> '') then
        err := ''; // a real keypress dismisses a transient error
      if selMode then
      begin
        // Select mode: pick a message to act on (delete your own).
        case key of
          -1: ;
          27, 9, 10, 13, KEY_ENTER:
            selMode := False; // Esc/Tab/Enter → back to typing
          Ord('j'), KEY_DOWN:
            if selMsg < High(msgs) then
            begin
              Inc(selMsg);
              ScrollToMsg;
            end;
          Ord('k'), KEY_UP:
            if selMsg > 0 then
            begin
              Dec(selMsg);
              ScrollToMsg;
            end;
          Ord('g'):
            begin
              selMsg := 0;
              ScrollToMsg;
            end;
          Ord('G'):
            begin
              selMsg := High(msgs);
              ScrollToMsg;
            end;
          KEY_PPAGE:
            ScrollUp(visible);
          KEY_NPAGE:
            ScrollDown(visible);
          Ord('i'):
            ViewSelImage;
          Ord('d'):
            DoDeleteMsg;
        end;
        if selMsg > High(msgs) then
          selMsg := High(msgs);
        if selMsg < 0 then
          selMsg := 0;
      end
      else
        // Input mode: type and send; Tab enters select mode.
        case key of
          -1:
            ; // input timeout: just loop to drain the stream
          27:
            Break; // Esc leaves the room
          9: // Tab → select mode (to delete a message)
            if Length(msgs) > 0 then
            begin
              selMode := True;
              selMsg := High(msgs);
              ScrollToMsg;
            end;
          10, 13, KEY_ENTER:
            DoSend;
          KEY_BACKSPACE, 127, 8:
            BackspaceInput;
          KEY_LEFT:
            inputCur := PrevCharBoundary(inputBuf, inputCur);
          KEY_RIGHT:
            inputCur := NextCharBoundary(inputBuf, inputCur);
          KEY_HOME:
            inputCur := 0;
          KEY_END:
            inputCur := Length(inputBuf);
          KEY_UP:
            ScrollUp(1);
          KEY_DOWN:
            ScrollDown(1);
          KEY_PPAGE:
            ScrollUp(visible);
          KEY_NPAGE:
            ScrollDown(visible);
          keyPaste:
            InsertInput(PasteText(False));
        else
          if (key >= 32) and (key <= 126) then
            InsertInput(Chr(key))
          else if (key >= 128) and (key <= 255) then
            InsertInput(Chr(key)); // raw byte of a multibyte paste
        end;
    until False;
  finally
    UICursorVisible(False);
    UIInputTimeout(-1); // restore blocking input for other views
    LeavePresence(sess, roomId, err); // drop out of the room's user list promptly
    err := '';
    if stream <> nil then
    begin
      stream.Terminate; // self-frees (FreeOnTerminate) once the request unwinds
      stream := nil;
    end;
    if presence <> nil then
    begin
      presence.Terminate;
      presence := nil;
    end;
  end;
end;

procedure RunRooms(sess: TCsSession);
var
  rooms: TRoomArray;
  err: string;
  sel, top, visible, key: LongInt;

  procedure RenderRow(y: LongInt; const room: TRoom; selected: Boolean);
  var
    W, nameX, nameW, timeRight, onlineRight, onlineX, timeX, pair: Integer;
    name, onlineStr, timeStr: string;
  begin
    W := ScreenCols;
    name := '#' + room.Slug;
    if room.Name <> '' then
      name := room.Name + '  (#' + room.Slug + ')';
    onlineStr := IntToStr(room.OnlineCount) + ' online';
    if room.LastMessageAt > 0 then
      timeStr := RelativeTimeMs(room.LastMessageAt)
    else
      timeStr := '';

    // Fixed, right-aligned columns so counts and times line up down the list.
    timeRight := W - 2;              // right edge of the time column
    onlineRight := timeRight - 8;    // right edge of the online column
    nameX := 2;
    nameW := onlineRight - 10 - nameX;
    if nameW < 4 then
      nameW := 4;
    onlineX := onlineRight - VisibleWidth(onlineStr) + 1;
    timeX := timeRight - VisibleWidth(timeStr) + 1;

    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      pair := cpSelect;
    end
    else
      pair := cpMeta;

    if selected then
      DrawText(y, nameX, cpSelect, PadOrTrunc(name, nameW), True)
    else
      DrawText(y, nameX, cpAccent, PadOrTrunc(name, nameW), True);
    if onlineX > nameX then
      DrawText(y, onlineX, pair, onlineStr);
    if (timeStr <> '') and (timeX > onlineX) then
      DrawText(y, timeX, pair, timeStr);
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    status: string;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(rooms) then
      sel := High(rooms);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;

    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   cIRC rooms   ·   @' + sess.Username);
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(rooms) then
        RenderRow(1 + i, rooms[idx], idx = sel);
    end;

    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q back)')
    else if Length(rooms) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no rooms   ·   r reload · q back')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d   ·   j/k move · Enter open · r reload · q back',
        [sel + 1, Length(rooms)]));
    UIRefresh;
  end;

begin
  err := '';
  rooms := FetchRooms(sess, err);
  sel := 0;
  top := 0;
  repeat
    Redraw;
    key := UIGetKey;
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(rooms) then
          Inc(sel);
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      Ord('g'):
        sel := 0;
      Ord('G'):
        sel := High(rooms);
      Ord('r'):
        begin
          err := '';
          rooms := FetchRooms(sess, err);
          sel := 0;
          top := 0;
        end;
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(rooms)) then
          RunRoom(sess, rooms[sel]);
    end;
  until False;
end;

end.
