unit CsThread;

(* The thread view: read one entry in full plus its replies, as a scrollable
   document. The entry's full content already comes down in the feed payload,
   so we only fetch replies here (GET /v1/posts/:id/replies, oldest first,
   paginated). Content is word-wrapped to the terminal width and re-wrapped on
   resize. Composing replies arrives in a later build. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession, CsModels;

{ Returns True if the feed should reload afterwards (a reply was posted, or the
  entry was deleted). }
function RunThread(sess: TCsSession; const entry: TEntry): Boolean;

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsUI, CsMarkdown, CsApi, CsRateLimit,
  CsCompose, CsImage, CsProfile, CsPlayer;

const
  PAGE = 50;

function FetchRepliesPage(sess: TCsSession; const postId, cursor: string;
  out nextCursor, err: string): TReplyArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/posts/' + postId + '/replies?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseReplyArray(TJSONArray(d));
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

function RunThread(sess: TCsSession; const entry: TEntry): Boolean;
var
  replies: TReplyArray;
  cursor, nextCursor, err, derr, bmid: string;
  lines: TStyleLines; // each display line is a sequence of styled runs
  lineOwner: array of Integer; // -2 non-selectable, -1 entry, k = reply k
  images: TImageRefs;
  top, visible, key, lastCols, selReply: Integer;
  watching, revealed: Boolean;

  { An NSFW entry whose content is currently masked (filtering on, not revealed). }
  function Gated: Boolean;
  begin
    Result := sess.FilterNSFW and entry.IsNSFW and (not revealed);
  end;

  function MaxTop: Integer;
  begin
    Result := High(lines) - visible + 1;
    if Result < 0 then
      Result := 0;
  end;

  { Append a styled display line (a sequence of runs) with an owner. }
  procedure AddRunsLine(const runs: TStyleRuns; owner: Integer);
  begin
    SetLength(lines, Length(lines) + 1);
    lines[High(lines)] := runs;
    SetLength(lineOwner, Length(lines));
    lineOwner[High(lineOwner)] := owner;
  end;

  { Append a single-style line (headers, meta, dividers). }
  procedure AddLine(const text: string; pair: Integer; bold: Boolean; owner: Integer);
  var
    r: TStyleRuns;
  begin
    SetLength(r, 1);
    r[0].Text := text;
    r[0].Pair := pair;
    r[0].Bold := bold;
    r[0].Underline := False;
    AddRunsLine(r, owner);
  end;

  { A body's markdown lines, each optionally prefixed with an indent run. }
  procedure AddMarkdown(const content, indent: string; owner: Integer; textW: Integer);
  var
    md: TStyleLines;
    r: TStyleRuns;
    k, m: Integer;
  begin
    md := RenderMarkdown(content, textW - Length(indent));
    for k := 0 to High(md) do
    begin
      SetLength(r, 0);
      if indent <> '' then
      begin
        SetLength(r, 1);
        r[0].Text := indent;
        r[0].Pair := cpText;
        r[0].Bold := False;
        r[0].Underline := False;
      end;
      for m := 0 to High(md[k]) do
      begin
        SetLength(r, Length(r) + 1);
        r[High(r)] := md[k][m];
      end;
      AddRunsLine(r, owner);
    end;
  end;

  function SelAuthor: string;
  begin
    if (selReply >= 0) and (selReply <= High(replies)) then
      Result := replies[selReply].AuthorUsername
    else
      Result := entry.AuthorUsername;
  end;

  procedure LoadReplies(reset: Boolean);
  var
    page: TReplyArray;
    oldLen, k: Integer;
  begin
    if reset then
    begin
      SetLength(replies, 0);
      cursor := '';
    end;
    page := FetchRepliesPage(sess, entry.PostId, cursor, nextCursor, err);
    oldLen := Length(replies);
    SetLength(replies, oldLen + Length(page));
    for k := 0 to High(page) do
      replies[oldLen + k] := page[k];
    cursor := nextCursor;
  end;

  procedure BuildLines;
  var
    i, textW: Integer;
    topicsLine, head, indent, detail: string;
  begin
    SetLength(lines, 0);
    SetLength(lineOwner, 0);
    SetLength(images, 0);
    if not Gated then // a gated NSFW thread exposes no images until revealed
    begin
      AppendImages(images, ExtractImages(entry.Content));
      for i := 0 to High(replies) do
        AppendImages(images, ExtractImages(replies[i].Content));
      // image attachments feed the viewer too
      for i := 0 to High(entry.Attachments) do
        if (LowerCase(entry.Attachments[i].Kind) = 'image') and
           (entry.Attachments[i].Src <> '') then
        begin
          SetLength(images, Length(images) + 1);
          images[High(images)].Alt := '@' + entry.AuthorUsername + ' attachment';
          images[High(images)].Url := entry.Attachments[i].Src;
        end;
    end;
    textW := ScreenCols - 2;
    if textW < 8 then
      textW := 8;

    // Entry header + body (owner -1).
    AddLine('@' + entry.AuthorUsername + '   ·   ' + RelativeTime(entry.CreatedAt),
      cpAccent, True, -1);
    if (not Gated) and (Trim(entry.Title) <> '') then
      AddLine(entry.Title, cpText, True, -1);
    if Length(entry.Topics) > 0 then
    begin
      topicsLine := '';
      for i := 0 to High(entry.Topics) do
        topicsLine := topicsLine + '#' + entry.Topics[i] + '  ';
      AddLine(Trim(topicsLine), cpMeta, False, -1);
    end;
    AddLine('', cpText, False, -1);

    if entry.Deleted then
      AddLine('[deleted]', cpMeta, False, -1)
    else if Gated then
      AddLine('🔞 NSFW content hidden — press x to reveal', cpNsfw, False, -1)
    else
    begin
      AddMarkdown(CleanImageMarkdown(entry.Content), '', -1, textW);
      // Non-image attachments (audio tracks) shown as text; a TUI can't play them.
      for i := 0 to High(entry.Attachments) do
        if LowerCase(entry.Attachments[i].Kind) <> 'image' then
        begin
          AddLine('', cpText, False, -1);
          AddLine(AttachmentSummary(entry.Attachments[i]), cpAccent, True, -1);
          detail := Trim(entry.Attachments[i].Genre);
          if entry.Attachments[i].Src <> '' then
            detail := Trim(detail + '   ' + entry.Attachments[i].Src);
          if detail <> '' then
            AddLine('   ' + detail, cpMeta, False, -1);
        end;
    end;

    if Length(images) > 0 then
    begin
      AddLine('', cpText, False, -2);
      AddLine('🖼 ' + IntToStr(Length(images)) +
        ' image(s) in this thread — press i to view', cpMeta, False, -2);
    end;

    AddLine('', cpText, False, -2);
    AddLine(HLine(textW), cpMeta, False, -2);
    if Length(replies) = 1 then
      AddLine('1 reply', cpMeta, False, -2)
    else
      AddLine(IntToStr(Length(replies)) + ' replies', cpMeta, False, -2);
    AddLine('', cpText, False, -2);

    // Replies (oldest first). One level of indent for nested replies.
    for i := 0 to High(replies) do
    begin
      if replies[i].ParentReplyId <> '' then
        indent := '  '
      else
        indent := '';
      head := '@' + replies[i].AuthorUsername + '   ·   ' +
        RelativeTime(replies[i].CreatedAt);
      AddLine(indent + head, cpAccent, False, i);
      if replies[i].Deleted then
        AddLine(indent + '[deleted]', cpMeta, False, i)
      else
        AddMarkdown(CleanImageMarkdown(replies[i].Content), indent, i, textW);
      AddLine('', cpText, False, i);
    end;

    if cursor <> '' then
      AddLine('— press m to load more replies —', cpMeta, False, -2);
  end;

  function FirstLineOf(owner: Integer): Integer;
  var
    i: Integer;
  begin
    Result := -1;
    for i := 0 to High(lineOwner) do
      if lineOwner[i] = owner then
        Exit(i);
  end;

  function LastLineOf(owner: Integer): Integer;
  var
    i: Integer;
  begin
    Result := -1;
    for i := 0 to High(lineOwner) do
      if lineOwner[i] = owner then
        Result := i;
  end;

  procedure ScrollToSel;
  var
    s, e2: Integer;
  begin
    s := FirstLineOf(selReply);
    if s < 0 then
      Exit;
    e2 := LastLineOf(selReply);
    if s < top then
      top := s
    else if e2 >= top + visible then
      top := s;
    if top > MaxTop then
      top := MaxTop;
    if top < 0 then
      top := 0;
  end;

  { Toggle watching this thread. The header/status flip is the success feedback;
    only failures and rate-limit blocks surface a (red) message. }
  procedure DoWatchToggle;
  var
    lerr, terr: string;
  begin
    if not Limiter.Check('watch', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if watching then
    begin
      if UnwatchThread(sess, entry.PostId, terr) then
      begin
        Limiter.Note('watch');
        watching := False;
      end
      else
        err := 'Unwatch failed: ' + terr;
    end
    else if WatchThread(sess, entry.PostId, terr) then
    begin
      Limiter.Note('watch');
      watching := True;
    end
    else
      err := 'Watch failed: ' + terr;
  end;

  { Report the selected item (entry or reply) to moderators, with an optional
    reason. Can't report your own content. }
  procedure DoFlag;
  var
    reason, lerr, kind, id: string;
    already, ok: Boolean;
  begin
    if SelAuthor = sess.Username then
    begin
      err := 'You can''t report your own content.';
      Exit;
    end;
    if selReply = -1 then
    begin
      kind := 'entry';
      id := entry.PostId;
    end
    else
    begin
      kind := 'reply';
      id := replies[selReply].ReplyId;
    end;
    if not UIConfirm('Report this ' + kind + ' to moderators?') then
      Exit;
    reason := '';
    if UIConfirm('Add a reason?') then
      if not UIPromptLine('Reason (Esc to skip):', reason) then
        reason := '';
    if not Limiter.Check('flag', lerr) then
    begin
      err := lerr;
      Exit;
    end;
    if selReply = -1 then
      ok := FlagEntry(sess, id, reason, already, lerr)
    else
      ok := FlagReply(sess, id, reason, already, lerr);
    if ok then
    begin
      Limiter.Note('flag');
      if already then
        err := 'Already reported.'
      else
        err := 'Reported. ✓';
    end
    else
      err := 'Report failed: ' + lerr;
  end;

  { The post's first playable audio attachment, if any. }
  function FirstAudio(out url, lbl: string): Boolean;
  var
    i: Integer;
  begin
    Result := False;
    for i := 0 to High(entry.Attachments) do
      if (LowerCase(entry.Attachments[i].Kind) = 'audio') and
         (entry.Attachments[i].Src <> '') then
      begin
        url := entry.Attachments[i].Src;
        lbl := AttachmentSummary(entry.Attachments[i]);
        Exit(True);
      end;
  end;

  { Toggle background playback of the post's audio attachment (via mpv). }
  procedure DoPlayAudio;
  var
    url, lbl: string;
  begin
    if not FirstAudio(url, lbl) then
    begin
      err := 'No audio attachment to play.';
      Exit;
    end;
    if IsPlaying and (PlayingUrl = url) then
    begin
      StopAudio;
      err := 'Stopped.';
    end
    else if PlayAudio(url, lbl) then
      err := 'Playing ▶ ' + lbl
    else
      err := 'Could not start mpv (need mpv + yt-dlp on PATH).';
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    status, selDesc, wtag, hsum, au, al: string;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if selReply < -1 then
      selReply := -1;
    if selReply > High(replies) then
      selReply := High(replies);
    if top > MaxTop then
      top := MaxTop;
    if top < 0 then
      top := 0;

    UIErase;
    if watching then
      wtag := ' 👁 watching'
    else
      wtag := '';
    if Gated then
      hsum := '[NSFW hidden]'
    else
      hsum := EntrySummary(entry);
    DrawBar(0, cpHeader, ' thread' + wtag + '   ·   @' + entry.AuthorUsername +
      '   ·   ' + hsum);

    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(lines) then
      begin
        if lineOwner[idx] = selReply then
          DrawText(1 + i, 0, cpAccent, '▎', True);
        DrawRuns(1 + i, 1, lines[idx]);
      end;
    end;

    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (q back)')
    else
    begin
      if selReply = -1 then
        selDesc := 'entry'
      else
        selDesc := 'reply @' + replies[selReply].AuthorUsername;
      status := ' ' + selDesc + '   ·   j/k select · c reply · b bookmark · p profile';
      if watching then
        status := status + ' · w unwatch'
      else
        status := status + ' · w watch';
      if sess.FilterNSFW and entry.IsNSFW then
        if revealed then
          status := status + ' · x hide'
        else
          status := status + ' · x reveal';
      if SelAuthor = sess.Username then
        status := status + ' · d delete'
      else
        status := status + ' · f flag';
      if Length(images) > 0 then
        status := status + ' · i img';
      if FirstAudio(au, al) then
        if IsPlaying and (PlayingUrl = au) then
          status := status + ' · o stop'
        else
          status := status + ' · o play';
      if cursor <> '' then
        status := status + ' · m more';
      status := status + ' · q back';
      DrawBar(ScreenRows - 1, cpStatus, status);
    end;
    UIRefresh;
  end;

begin
  Result := False;
  err := '';
  selReply := -1;
  revealed := False;
  LoadReplies(True);
  BuildLines;
  top := 0;
  lastCols := ScreenCols;
  FetchWatchStatus(sess, entry.PostId, watching, derr); // derr ignored: defaults to not-watching
  repeat
    if ScreenCols <> lastCols then
    begin
      BuildLines;
      lastCols := ScreenCols;
    end;
    Redraw;
    key := UIGetKey;
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        begin
          if selReply < High(replies) then
            Inc(selReply);
          ScrollToSel;
        end;
      Ord('k'), KEY_UP:
        begin
          if selReply > -1 then
            Dec(selReply);
          ScrollToSel;
        end;
      KEY_NPAGE:
        top := top + visible;
      KEY_PPAGE:
        top := top - visible;
      Ord('g'):
        begin
          selReply := -1;
          top := 0;
        end;
      Ord('G'):
        begin
          selReply := High(replies);
          ScrollToSel;
        end;
      Ord('m'):
        if cursor <> '' then
        begin
          LoadReplies(False);
          BuildLines;
        end;
      Ord('i'):
        if Gated then
          err := 'Reveal NSFW content first (x).'
        else if Length(images) > 0 then
          ViewImages(images)
        else
          err := 'No images in this thread.';
      Ord('p'):
        RunProfile(sess, SelAuthor);
      Ord('b'):
        if not Limiter.Check('bookmark', derr) then
          err := derr
        else if CreateBookmarkPost(sess, entry.PostId, bmid, derr) then
        begin
          Limiter.Note('bookmark');
          err := 'Bookmarked this post.';
        end
        else
          err := 'Bookmark failed: ' + derr;
      Ord('w'):
        DoWatchToggle;
      Ord('f'):
        DoFlag;
      Ord('o'):
        DoPlayAudio;
      Ord('x'):
        if sess.FilterNSFW and entry.IsNSFW then
        begin
          revealed := not revealed;
          BuildLines; // re-render body/images with the new gate state
        end;
      Ord('c'):
        begin
          if selReply = -1 then
          begin
            if ComposeReply(sess, entry.PostId, EntrySummary(entry)) then
              Result := True;
          end
          else if ComposeReplyTo(sess, entry.PostId, replies[selReply].ReplyId,
            '@' + replies[selReply].AuthorUsername) then
            Result := True;
          if Result then
          begin
            LoadReplies(True);
            BuildLines;
            selReply := High(replies); // select the newest reply
            ScrollToSel;
          end;
          err := '';
        end;
      Ord('d'):
        if selReply = -1 then
        begin
          if entry.AuthorUsername <> sess.Username then
            err := 'You can only delete your own entries.'
          else if UIConfirm('Delete your entry? This cannot be undone.') then
          begin
            if DeleteEntry(sess, entry.PostId, derr) then
            begin
              Result := True;
              Break;
            end
            else
              err := 'Delete failed: ' + derr;
          end;
        end
        else if replies[selReply].AuthorUsername <> sess.Username then
          err := 'You can only delete your own replies.'
        else if UIConfirm('Delete your reply? This cannot be undone.') then
        begin
          if DeleteReply(sess, replies[selReply].ReplyId, derr) then
          begin
            Result := True;
            LoadReplies(True);
            BuildLines;
            if selReply > High(replies) then
              selReply := High(replies);
            ScrollToSel;
          end
          else
            err := 'Delete failed: ' + derr;
        end;
      Ord('r'):
        begin
          err := '';
          LoadReplies(True);
          BuildLines;
          selReply := -1;
          top := 0;
        end;
    end;
  until False;
end;

end.
