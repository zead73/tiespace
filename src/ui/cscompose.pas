unit CsCompose;

(* The composer: a multi-line text editor for a new entry or a reply.

   The buffer is a single UTF-8 string (newlines are literal). It soft-wraps to
   the terminal width for display, and the cursor is a byte offset that moves by
   whole codepoints, so multibyte text and pasted UTF-8 edit correctly. Ctrl+G
   moves to a review screen; nothing is sent until the user confirms there. A
   client-side rate-limit check runs before the confirm. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

{ Each returns True if something was successfully posted. }
function ComposeEntry(sess: TCsSession): Boolean;
function ComposeReply(sess: TCsSession; const postId, contextLabel: string): Boolean;
{ Reply to a specific reply (nested, via parentReplyId). }
function ComposeReplyTo(sess: TCsSession; const postId, parentReplyId, contextLabel: string): Boolean;
{ Start a new thread in a guild's forum (title/topics like an entry, no NSFW). }
function ComposeGuildThread(sess: TCsSession; const guildSlug, guildLabel: string): Boolean;

{ Notes are private. ComposeNote writes a new one (content + optional topics);
  EditNote re-opens an existing note's content for a revision (its topics are
  carried through unchanged). Each returns True if something was saved. }
function ComposeNote(sess: TCsSession): Boolean;
function EditNote(sess: TCsSession; const noteId, startContent, keepTopics: string): Boolean;

{ Edit the body of an existing entry / reply, pre-filled with its current text
  (content only). The server allows this for supporters within 5 minutes of
  posting; otherwise the save comes back with a 403. Returns True if saved. }
function EditEntryContent(sess: TCsSession; const postId, startContent: string): Boolean;
function EditReplyContent(sess: TCsSession; const replyId, startContent: string): Boolean;

implementation

uses
  SysUtils, ncurses, CsUI, CsApi, CsRateLimit;

const
  MAX_CHARS = 32768;

type
  TWrapRow = record
    StartByte: Integer; // 0-based bytes before this row's first char
    Text: string;
  end;
  TWrapRows = array of TWrapRow;

{ Soft-wrap a buffer into display rows, breaking at newlines and at the width.
  Always emits a final row so an empty trailing line is representable. }
function WrapBuffer(const buf: string; width: Integer): TWrapRows;
var
  i, n, rowStart, rowW, w, ni: Integer;
  rowText, chunk: string;

  procedure Emit;
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].StartByte := rowStart - 1;
    Result[High(Result)].Text := rowText;
  end;

begin
  SetLength(Result, 0);
  if width < 1 then
    width := 1;
  n := Length(buf);
  i := 1;
  rowStart := 1;
  rowText := '';
  rowW := 0;
  while i <= n do
  begin
    if buf[i] = #10 then
    begin
      Emit;
      Inc(i);
      rowStart := i;
      rowText := '';
      rowW := 0;
    end
    else
    begin
      ni := NextCharBoundary(buf, i - 1) + 1;
      chunk := Copy(buf, i, ni - i);
      w := VisibleWidth(chunk);
      if (rowW + w > width) and (rowText <> '') then
      begin
        Emit;
        rowStart := i;
        rowText := '';
        rowW := 0;
      end;
      rowText := rowText + chunk;
      Inc(rowW, w);
      i := ni;
    end;
  end;
  Emit;
end;

function CursorRow(const rows: TWrapRows; cur: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(rows) do
    if rows[i].StartByte <= cur then
      Result := i
    else
      Break;
end;

function PosAtCol(const rows: TWrapRows; row, targetCol: Integer): Integer;
var
  text, chunk: string;
  idx, used, w, ni: Integer;
begin
  text := rows[row].Text;
  used := 0;
  idx := 1;
  while idx <= Length(text) do
  begin
    ni := NextCharBoundary(text, idx - 1) + 1;
    chunk := Copy(text, idx, ni - idx);
    w := VisibleWidth(chunk);
    if used + w > targetCol then
      Break;
    Inc(used, w);
    idx := ni;
  end;
  Result := rows[row].StartByte + (idx - 1);
end;

procedure ShowMsg(const s: string);
begin
  UICursorVisible(False);
  DrawBar(ScreenRows - 1, cpStatus, ' ' + s + '   (press any key)');
  UIRefresh;
  UIGetKey;
end;

{ A full-screen review of the text with a y/n prompt. Header and prompt vary by
  what's being confirmed (a public post, a private note, …). }
function ConfirmReview(const header, content, prompt: string): Boolean;
var
  rows: TTextLines;
  i, areaH: Integer;
  key: LongInt;
begin
  UICursorVisible(False);
  UIErase;
  DrawBar(0, cpHeader, header);
  areaH := ScreenRows - 3;
  if areaH < 1 then
    areaH := 1;
  rows := WrapText(content, ScreenCols - 2);
  for i := 0 to High(rows) do
  begin
    if i >= areaH then
      Break;
    DrawText(1 + i, 1, cpText, rows[i]);
  end;
  DrawBar(ScreenRows - 1, cpStatus, prompt);
  UIRefresh;
  repeat
    key := UIGetKey;
    case key of
      Ord('y'), Ord('Y'): Exit(True);
      Ord('n'), Ord('N'), 27: Exit(False);
    end;
  until False;
end;

function ConfirmPost(const content, user, visSuffix: string): Boolean;
begin
  Result := ConfirmReview(' Review — post as @' + user + visSuffix, content,
    ' Post this?    [y] post     [n] keep editing');
end;

{ The editor. Returns True if the user asked to send (Ctrl+G), False on Esc.
  buffer is edited in place. }
function EditText(const headerText: string; var buffer: string): Boolean;
var
  cur, vtop, textW, areaH, crow, ccol: Integer;
  rows: TWrapRows;
  key: LongInt;

  procedure Recompute;
  begin
    textW := ScreenCols - 2;
    if textW < 8 then
      textW := 8;
    areaH := ScreenRows - 3;
    if areaH < 1 then
      areaH := 1;
    rows := WrapBuffer(buffer, textW);
    crow := CursorRow(rows, cur);
    ccol := VisibleWidth(Copy(buffer, rows[crow].StartByte + 1, cur - rows[crow].StartByte));
    if crow < vtop then
      vtop := crow;
    if crow >= vtop + areaH then
      vtop := crow - areaH + 1;
    if vtop < 0 then
      vtop := 0;
  end;

  procedure Draw;
  var
    i: Integer;
  begin
    UIErase;
    DrawBar(0, cpHeader, ' ' + headerText);
    for i := 0 to areaH - 1 do
      if vtop + i <= High(rows) then
        DrawText(1 + i, 1, cpText, rows[vtop + i].Text);
    DrawBar(ScreenRows - 2, cpMeta, Format('  %d chars   ·   line %d/%d',
      [CodepointCount(buffer), crow + 1, Length(rows)]));
    DrawBar(ScreenRows - 1, cpStatus, ' Ctrl+G: review & post     Esc: cancel');
    UICursorVisible(True);
    UIPlaceCursor(1 + (crow - vtop), 1 + ccol);
    UIRefresh;
  end;

  procedure InsertStr(const s: string);
  begin
    buffer := Copy(buffer, 1, cur) + s + Copy(buffer, cur + 1, MaxInt);
    Inc(cur, Length(s));
  end;

  procedure Backspace;
  var
    p: Integer;
  begin
    if cur <= 0 then
      Exit;
    p := PrevCharBoundary(buffer, cur);
    buffer := Copy(buffer, 1, p) + Copy(buffer, cur + 1, MaxInt);
    cur := p;
  end;

begin
  Result := False;
  cur := Length(buffer);
  vtop := 0;
  repeat
    Recompute;
    Draw;
    key := UIGetKey;
    case key of
      27:
        begin
          UICursorVisible(False);
          Exit(False);
        end;
      7: // Ctrl+G
        begin
          UICursorVisible(False);
          Exit(True);
        end;
      10, 13, KEY_ENTER:
        InsertStr(#10);
      KEY_BACKSPACE, 127, 8:
        Backspace;
      KEY_LEFT:
        cur := PrevCharBoundary(buffer, cur);
      KEY_RIGHT:
        cur := NextCharBoundary(buffer, cur);
      KEY_UP:
        if crow > 0 then
          cur := PosAtCol(rows, crow - 1, ccol);
      KEY_DOWN:
        if crow < High(rows) then
          cur := PosAtCol(rows, crow + 1, ccol);
      KEY_HOME:
        cur := rows[crow].StartByte;
      KEY_END:
        cur := rows[crow].StartByte + Length(rows[crow].Text);
      keyPaste:
        InsertStr(PasteText(True)); // paste keeps its line breaks here
    else
      if (key >= 32) and (key <= 126) then
        InsertStr(Chr(key))
      else if (key >= 128) and (key <= 255) then
        InsertStr(Chr(key)); // raw byte of a multibyte paste
    end;
  until False;
end;

{ A one-key content-warning prompt: y = NSFW, Enter/n/Esc = not. }
function AskNSFW: Boolean;
var
  k: LongInt;
begin
  Result := False;
  DrawBar(ScreenRows - 1, cpStatus, ' Mark as NSFW?    [y] yes    [Enter/n] no');
  UIRefresh;
  repeat
    k := UIGetKey;
    case k of
      Ord('y'), Ord('Y'): Exit(True);
      Ord('n'), Ord('N'), 10, 13, 27: Exit(False);
    end;
  until False;
end;

{ Visibility for a new entry: p = public (visible without login), n = private,
  Enter/Esc = leave it to your account default (defaultPublicPost). }
function AskPublic: TPostVisibility;
var
  k: LongInt;
begin
  Result := pvDefault;
  DrawBar(ScreenRows - 1, cpStatus,
    ' Visibility?    [p] public    [n] private    [Enter] your default');
  UIRefresh;
  repeat
    k := UIGetKey;
    case k of
      Ord('p'), Ord('P'): Exit(pvPublic);
      Ord('n'), Ord('N'): Exit(pvPrivate);
      10, 13, 27: Exit(pvDefault);
    end;
  until False;
end;

function VisLabel(vis: TPostVisibility): string;
begin
  case vis of
    pvPublic: Result := 'public';
    pvPrivate: Result := 'private';
  else
    Result := 'account default';
  end;
end;

function SendLoop(sess: TCsSession; const header, action: string;
  isReply: Boolean; const postId, parentReplyId: string;
  const guildSlug: string = ''): Boolean;
var
  buffer, newId, err, msg, title, topics, visSuffix: string;
  nsfw: Boolean;
  vis: TPostVisibility;
begin
  Result := False;
  buffer := '';
  title := '';
  topics := '';
  nsfw := False;
  vis := pvDefault;
  repeat
    if not EditText(header, buffer) then
      Exit(False); // Esc: cancelled
    if Trim(buffer) = '' then
    begin
      ShowMsg('Nothing to post.');
      Continue;
    end;
    if CodepointCount(buffer) > MAX_CHARS then
    begin
      ShowMsg('Too long (max ' + IntToStr(MAX_CHARS) + ' characters).');
      Continue;
    end;
    // Entries can carry an optional title and up to 3 topics (Esc skips either).
    if not isReply then
    begin
      if not UIPromptLine('Title (optional, Esc to skip):', title) then
        title := '';
      if not UIPromptLine('Topics (optional, space-separated):', topics) then
        topics := '';
      if guildSlug = '' then
      begin
        nsfw := AskNSFW; // guild threads have no NSFW flag
        vis := AskPublic; // ...nor a public/private choice
      end;
    end;
    if not Limiter.Check(action, msg) then
    begin
      ShowMsg(msg);
      Continue;
    end;
    if (not isReply) and (guildSlug = '') then
      visSuffix := '   ·   ' + VisLabel(vis) // only entries have a visibility choice
    else
      visSuffix := '';
    if ConfirmPost(buffer, sess.Username, visSuffix) then
    begin
      if isReply then
        Result := CreateReply(sess, postId, buffer, newId, err, parentReplyId)
      else if guildSlug <> '' then
        Result := CreateGuildThread(sess, guildSlug, buffer, newId, err, title, topics)
      else
        Result := CreateEntry(sess, buffer, newId, err, title, topics, nsfw, vis);
      if Result then
      begin
        Limiter.Note(action);
        ShowMsg('Posted. ✓');
        Exit(True);
      end
      else
        ShowMsg('Failed: ' + err); // keep the buffer, back to the editor
    end;
  until False;
end;

function ComposeEntry(sess: TCsSession): Boolean;
begin
  Result := SendLoop(sess, 'New entry — as @' + sess.Username, 'entry', False, '', '');
end;

function ComposeReply(sess: TCsSession; const postId, contextLabel: string): Boolean;
begin
  Result := SendLoop(sess, 'Reply — ' + contextLabel, 'reply', True, postId, '');
end;

function ComposeReplyTo(sess: TCsSession; const postId, parentReplyId, contextLabel: string): Boolean;
begin
  Result := SendLoop(sess, 'Reply — ' + contextLabel, 'reply', True, postId, parentReplyId);
end;

function ComposeGuildThread(sess: TCsSession; const guildSlug, guildLabel: string): Boolean;
begin
  Result := SendLoop(sess, 'New thread in ' + guildLabel + ' — as @' + sess.Username,
    'guild_thread', False, '', '', guildSlug);
end;

function ComposeNote(sess: TCsSession): Boolean;
var
  buffer, topics, newId, err, msg: string;
begin
  Result := False;
  buffer := '';
  topics := '';
  repeat
    if not EditText('New note — private to you', buffer) then
      Exit(False); // Esc: cancelled
    if Trim(buffer) = '' then
    begin
      ShowMsg('Nothing to save.');
      Continue;
    end;
    if CodepointCount(buffer) > MAX_CHARS then
    begin
      ShowMsg('Too long (max ' + IntToStr(MAX_CHARS) + ' characters).');
      Continue;
    end;
    if not UIPromptLine('Topics (optional, space-separated):', topics) then
      topics := '';
    if not Limiter.Check('note', msg) then
    begin
      ShowMsg(msg);
      Continue;
    end;
    if ConfirmReview(' Review — private note', buffer,
      ' Save this note?    [y] save     [n] keep editing') then
    begin
      Result := CreateNote(sess, buffer, newId, err, topics);
      if Result then
      begin
        Limiter.Note('note');
        ShowMsg('Saved. ✓');
        Exit(True);
      end
      else
        ShowMsg('Failed: ' + err);
    end;
  until False;
end;

function EditNote(sess: TCsSession; const noteId, startContent, keepTopics: string): Boolean;
var
  buffer, err, msg: string;
begin
  Result := False;
  buffer := startContent;
  repeat
    if not EditText('Edit note — saving creates a new revision', buffer) then
      Exit(False); // Esc: cancelled
    if Trim(buffer) = '' then
    begin
      ShowMsg('Nothing to save.');
      Continue;
    end;
    if CodepointCount(buffer) > MAX_CHARS then
    begin
      ShowMsg('Too long (max ' + IntToStr(MAX_CHARS) + ' characters).');
      Continue;
    end;
    if not Limiter.Check('note', msg) then
    begin
      ShowMsg(msg);
      Continue;
    end;
    if ConfirmReview(' Review — edit note', buffer,
      ' Save changes?    [y] save     [n] keep editing') then
    begin
      Result := UpdateNote(sess, noteId, buffer, keepTopics, err);
      if Result then
      begin
        Limiter.Note('note');
        ShowMsg('Saved. ✓');
        Exit(True);
      end
      else
        ShowMsg('Failed: ' + err);
    end;
  until False;
end;

{ Shared body for editing an entry or a reply: the content editor pre-filled,
  then PATCH content. kind is 'entry' or 'reply'. }
function EditPost(sess: TCsSession; const header, kind, id, startContent: string): Boolean;
var
  buffer, err, msg: string;
begin
  Result := False;
  buffer := startContent;
  repeat
    if not EditText(header, buffer) then
      Exit(False); // Esc: cancelled
    if Trim(buffer) = '' then
    begin
      ShowMsg('Nothing to save.');
      Continue;
    end;
    if CodepointCount(buffer) > MAX_CHARS then
    begin
      ShowMsg('Too long (max ' + IntToStr(MAX_CHARS) + ' characters).');
      Continue;
    end;
    if not Limiter.Check('edit', msg) then
    begin
      ShowMsg(msg);
      Continue;
    end;
    if ConfirmReview(' Review — edit ' + kind, buffer,
      ' Save changes?    [y] save     [n] keep editing') then
    begin
      if kind = 'entry' then
        Result := EditEntry(sess, id, buffer, err)
      else
        Result := EditReply(sess, id, buffer, err);
      if Result then
      begin
        Limiter.Note('edit');
        ShowMsg('Saved. ✓');
        Exit(True);
      end
      else
        ShowMsg('Failed: ' + err); // e.g. 403 outside the window / not a supporter
    end;
  until False;
end;

function EditEntryContent(sess: TCsSession; const postId, startContent: string): Boolean;
begin
  Result := EditPost(sess, 'Edit entry — supporters, within 5 min of posting',
    'entry', postId, startContent);
end;

function EditReplyContent(sess: TCsSession; const replyId, startContent: string): Boolean;
begin
  Result := EditPost(sess, 'Edit reply — supporters, within 5 min of posting',
    'reply', replyId, startContent);
end;

end.
