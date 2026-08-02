unit CsMail;

(* C-Mail: private 1:1 messaging.

   The conversation view mirrors the cIRC room view -- history over REST, live
   updates over the dm_messages RTDB SSE stream, an input line to send -- minus
   the presence panel (it's 1:1). Opening a conversation marks it read; you can
   also start a new conversation by username. Typing indicators are a follow-up. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunMail(sess: TCsSession);

implementation

uses
  SysUtils, DateUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsSSE, CsApi, CsRateLimit;

procedure RunConversation(sess: TCsSession; const conversationId, otherUsername: string); forward;

function FetchConversations(sess: TCsSession; out err: string): TConversationArray;
var
  env: TJSONObject;
  d: TJSONData;
begin
  SetLength(Result, 0);
  err := '';
  try
    env := sess.Client.GetJSONObj('/v1/cmail');
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseConversationArray(TJSONArray(d));
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchDMHistory(sess: TCsSession; const convId, before: string;
  out err: string): TChatMessageArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  err := '';
  path := '/v1/cmail/' + convId + '?limit=50';
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

procedure RunConversation(sess: TCsSession; const conversationId, otherUsername: string);
var
  msgs: TChatMessageArray;
  lines: TRenderLines;
  err, streamUrl, inputBuf, presUrl: string;
  top, visible, key, lastCols, inputCur: Integer;
  stream: TChatStreamThread;
  presence: TPresenceThread;
  typingNames: TNameArray;
  typeHbMs, typeStaleMs: Integer;
  lastTypePost, lastKeyTime: TDateTime;
  wasTyping: Boolean;

  function MaxTop: Integer;
  begin
    Result := High(lines) - visible + 1;
    if Result < 0 then
      Result := 0;
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
    batch, merged: TChatMessageArray;
    i: Integer;
  begin
    before := '';
    if older and (Length(msgs) > 0) then
      before := IntToStr(msgs[0].Timestamp);
    batch := FetchDMHistory(sess, conversationId, before, err);
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
    i, j, textW, hdrPair: Integer;
    header, content: string;
    wrapped: TTextLines;
  begin
    SetLength(lines, 0);
    textW := ScreenCols - 2;
    if textW < 8 then
      textW := 8;
    for i := 0 to High(msgs) do
    begin
      if msgs[i].Deleted then
        RLAdd(lines, MsToLocalHM(msgs[i].Timestamp) + '  @' + msgs[i].Username +
          '  [deleted]', cpMeta)
      else if msgs[i].IsAction then
        RLAdd(lines, MsToLocalHM(msgs[i].Timestamp) + '  * ' + msgs[i].Username +
          ' ' + msgs[i].Content, cpMeta)
      else
      begin
        header := MsToLocalHM(msgs[i].Timestamp) + '  @' + msgs[i].Username;
        // Dim our own messages' header, colour the other person's.
        if msgs[i].Username = sess.Username then
          hdrPair := cpMeta
        else
          hdrPair := cpAccent;
        RLAdd(lines, header, hdrPair, True);
        content := msgs[i].Content;
        if (content = msgs[i].ImageUrl) or (content = msgs[i].GifUrl) then
          content := '';
        if content <> '' then
        begin
          wrapped := WrapText(content, textW - 2);
          for j := 0 to High(wrapped) do
            RLAdd(lines, '  ' + wrapped[j], cpText);
        end;
        if msgs[i].ImageUrl <> '' then
          RLAdd(lines, '  🖼 [image]', cpMeta);
        if msgs[i].GifUrl <> '' then
          RLAdd(lines, '  🖼 [gif]', cpMeta);
      end;
    end;
    if Length(lines) = 0 then
      RLAdd(lines, '(no messages yet — say hello)', cpMeta);
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
    i, idx, avail, curCol, startCol: Integer;
    live: string;
  begin
    visible := ScreenRows - 3; // header + typing line + input
    if visible < 1 then
      visible := 1;
    if top > MaxTop then
      top := MaxTop;
    if top < 0 then
      top := 0;

    if presence <> nil then
      presence.GetTyping(typingNames, typeStaleMs, sess.Username);

    UIErase;
    if stream = nil then
      live := ''
    else if stream.GaveUp then
      live := '   ·   disconnected'
    else if stream.Connected then
      live := '   ·   ● live'
    else
      live := '   ·   connecting…';
    DrawBar(0, cpHeader, ' C-Mail   ·   @' + otherUsername + live);

    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(lines) then
        DrawText(1 + i, 1, lines[idx].Pair, lines[idx].Text, lines[idx].Bold);
    end;

    // Typing line (just above the input).
    DrawBar(ScreenRows - 2, cpText, '');
    if Length(typingNames) > 0 then
      DrawText(ScreenRows - 2, 1, cpMeta, '@' + typingNames[0] + ' is typing…');

    if err <> '' then
    begin
      UICursorVisible(False);
      DrawBar(ScreenRows - 1, cpError, ' ' + err);
    end
    else if inputBuf = '' then
    begin
      DrawBar(ScreenRows - 1, cpText, '');
      DrawText(ScreenRows - 1, 0, cpMeta,
        '> type a message · Enter send · ↑/PgUp scroll · Esc back');
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
    lastKeyTime := Now;
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
    lastKeyTime := Now;
  end;

  procedure MaintainTyping;
  var
    e: string;
  begin
    if (inputBuf <> '') and (MilliSecondsBetween(Now, lastKeyTime) < 2500) then
    begin
      // actively typing: announce, then heartbeat at the server's cadence
      if (not wasTyping) or (MilliSecondsBetween(Now, lastTypePost) >= typeHbMs) then
      begin
        SendTyping(sess, conversationId, typeHbMs, typeStaleMs, e);
        lastTypePost := Now;
        wasTyping := True;
      end;
    end
    else if wasTyping then
    begin
      StopTyping(sess, conversationId, e);
      wasTyping := False;
    end;
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
      LoadHistory(True);
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
    if not Limiter.Check('cmail', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if SendCMail(sess, conversationId, inputBuf, mid, serr) then
    begin
      Limiter.Note('cmail');
      inputBuf := '';
      inputCur := 0;
      top := MaxTop;
    end
    else
      err := 'Send failed: ' + serr;
  end;

var
  base, mErr: string;
begin
  err := '';
  inputBuf := '';
  inputCur := 0;
  stream := nil;
  presence := nil;
  SetLength(typingNames, 0);
  typeHbMs := 3000;
  typeStaleMs := 9000;
  wasTyping := False;
  lastTypePost := Now;
  lastKeyTime := Now;

  try
    sess.Refresh;
  except
    on E: Exception do ;
  end;

  MarkCMailRead(sess, conversationId, mErr); // opening clears unread
  LoadHistory(False);
  BuildLines;
  visible := ScreenRows - 3;
  top := MaxTop;
  lastCols := ScreenCols;

  base := sess.RtdbUrl;
  if (base <> '') and (base[Length(base)] = '/') then
    SetLength(base, Length(base) - 1);
  if (base <> '') and (sess.IdToken <> '') then
  begin
    streamUrl := base + '/dm_messages/' + conversationId +
      '.json?auth=' + sess.IdToken + '&orderBy=%22timestamp%22&limitToLast=50';
    stream := TChatStreamThread.Create(streamUrl);
    presUrl := base + '/dm_presence/' + conversationId + '.json?auth=' + sess.IdToken;
    presence := TPresenceThread.Create(presUrl);
  end;

  UIInputTimeout(300);
  try
    repeat
      if ScreenCols <> lastCols then
      begin
        BuildLines;
        lastCols := ScreenCols;
      end;
      ApplyStreamOps;
      MaintainTyping;
      Redraw;
      key := UIGetKey;
      if (key <> -1) and (err <> '') then
        err := '';
      case key of
        -1: ;
        27: Break;
        10, 13, KEY_ENTER: DoSend;
        KEY_BACKSPACE, 127, 8: BackspaceInput;
        KEY_LEFT: inputCur := PrevCharBoundary(inputBuf, inputCur);
        KEY_RIGHT: inputCur := NextCharBoundary(inputBuf, inputCur);
        KEY_HOME: inputCur := 0;
        KEY_END: inputCur := Length(inputBuf);
        KEY_UP: ScrollUp(1);
        KEY_DOWN: ScrollDown(1);
        KEY_PPAGE: ScrollUp(visible);
        KEY_NPAGE: ScrollDown(visible);
        keyPaste: InsertInput(PasteText(False));
      else
        if (key >= 32) and (key <= 126) then
          InsertInput(Chr(key))
        else if (key >= 128) and (key <= 255) then
          InsertInput(Chr(key));
      end;
    until False;
  finally
    UICursorVisible(False);
    UIInputTimeout(-1);
    StopTyping(sess, conversationId, mErr); // clear our typing flag on leave
    MarkCMailRead(sess, conversationId, mErr); // clear unread for anything seen live
    if stream <> nil then
    begin
      stream.Terminate;
      stream := nil;
    end;
    if presence <> nil then
    begin
      presence.Terminate;
      presence := nil;
    end;
  end;
end;

procedure RunMail(sess: TCsSession);
var
  convs: TConversationArray;
  err: string;
  sel, top, visible, key: LongInt;

  procedure StartNew;
  var
    uname, cid, other, serr, lerr: string;
    k, cur: Integer;
    done: Boolean;
  begin
    uname := '';
    cur := 0;
    done := False;
    repeat
      DrawBar(ScreenRows - 1, cpStatus, ' To (username): ' + uname);
      UICursorVisible(True);
      UIPlaceCursor(ScreenRows - 1, 16 + VisibleWidth(uname));
      UIRefresh;
      k := UIGetKey;
      case k of
        27: begin UICursorVisible(False); Exit; end;
        10, 13, KEY_ENTER: done := True;
        KEY_BACKSPACE, 127, 8:
          if cur > 0 then
          begin
            cur := PrevCharBoundary(uname, cur);
            uname := Copy(uname, 1, cur);
          end;
        keyPaste:
          begin
            uname := uname + PasteText(False);
            cur := Length(uname);
          end;
      else
        if (k >= 32) and (k <= 126) then
        begin
          uname := uname + Chr(k);
          cur := Length(uname);
        end;
      end;
    until done;
    UICursorVisible(False);
    uname := Trim(uname);
    if uname = '' then
      Exit;
    if not Limiter.Check('cmail_start', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if StartConversation(sess, uname, cid, other, serr) then
    begin
      Limiter.Note('cmail_start');
      if other = '' then
        other := uname;
      RunConversation(sess, cid, other);
      convs := FetchConversations(sess, err); // refresh list on return
    end
    else
      err := 'Could not start: ' + serr;
  end;

  procedure RenderRow(y: LongInt; const c: TConversation; selected: Boolean);
  var
    W, nameX, nameW, rightX, rightW: Integer;
    right, name, preview: string;
  begin
    W := ScreenCols;
    name := '@' + c.OtherUsername;
    right := RelativeTimeMs(c.LastMessageAt);
    if c.UnreadCount > 0 then
      right := IntToStr(c.UnreadCount) + ' new  ·  ' + right;
    rightW := VisibleWidth(right);
    nameX := 2;
    nameW := 18;
    rightX := W - rightW - 1;
    preview := c.LastMessage;

    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      DrawText(y, nameX, cpSelect, PadOrTrunc(name, nameW), True);
      DrawText(y, nameX + nameW + 1, cpSelect,
        PadOrTrunc(preview, rightX - (nameX + nameW + 1) - 1));
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, nameX, cpAccent, PadOrTrunc(name, nameW), c.UnreadCount > 0);
      DrawText(y, nameX + nameW + 1, cpText,
        PadOrTrunc(preview, rightX - (nameX + nameW + 1) - 1));
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
    if sel > High(convs) then
      sel := High(convs);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;

    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   C-Mail   ·   @' + sess.Username);
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(convs) then
        RenderRow(1 + i, convs[idx], idx = sel);
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q back)')
    else if Length(convs) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no conversations   ·   n new · r reload · q back')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d   ·   j/k · Enter open · n new · r reload · q back',
        [sel + 1, Length(convs)]));
    UIRefresh;
  end;

begin
  err := '';
  convs := FetchConversations(sess, err);
  sel := 0;
  top := 0;
  repeat
    Redraw;
    key := UIGetKey;
    if (err <> '') and (key <> Ord('r')) then
      err := '';
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(convs) then
          Inc(sel);
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      Ord('g'):
        sel := 0;
      Ord('G'):
        sel := High(convs);
      Ord('n'):
        StartNew;
      Ord('r'):
        begin
          err := '';
          convs := FetchConversations(sess, err);
          sel := 0;
          top := 0;
        end;
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(convs)) then
        begin
          RunConversation(sess, convs[sel].ConversationId, convs[sel].OtherUsername);
          convs := FetchConversations(sess, err); // refresh unread counts
        end;
    end;
  until False;
end;

end.
