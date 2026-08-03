unit CsModels;

(* Data models parsed from API JSON, plus small formatting helpers.

   Records with managed fields (strings, dynamic arrays) are returned by value;
   FPC initialises their managed fields, so we never FillChar them. *)

{$mode objfpc}{$H+}

interface

uses
  fpjson;

type
  TEntry = record
    PostId: string;
    AuthorId: string;
    AuthorUsername: string;
    Title: string;
    Slug: string;
    Content: string;
    CreatedAt: string;
    Topics: array of string;
    RepliesCount: Integer;
    BookmarksCount: Integer;
    IsNSFW: Boolean;
    IsPublic: Boolean;
    Deleted: Boolean;
  end;
  TEntryArray = array of TEntry;

  TReply = record
    ReplyId: string;
    PostId: string;
    ParentReplyId: string;
    AuthorId: string;
    AuthorUsername: string;
    Content: string;
    CreatedAt: string;
    Deleted: Boolean;
  end;
  TReplyArray = array of TReply;

  TNotification = record
    Id: string;
    NType: string;
    ActorUsername: string;
    TargetId: string;
    TargetType: string;
    CreatedAt: string;
    Read: Boolean;
    MetaPostSlug: string;
    MetaAuthorUsername: string;
    MetaReplyId: string;
  end;
  TNotificationArray = array of TNotification;

  TRoom = record
    Id: string;
    Slug: string;
    Name: string;
    LastMessageAt: Int64;
    SortOrder: Integer;
    OnlineCount: Integer;
  end;
  TRoomArray = array of TRoom;

  TChatMessage = record
    Id: string;
    UserId: string;
    Username: string;
    Content: string;
    Timestamp: Int64;
    IsChatAdmin: Boolean;
    IsAction: Boolean;
    Deleted: Boolean;
    ImageUrl: string;
    GifUrl: string;
  end;
  TChatMessageArray = array of TChatMessage;

  TConversation = record
    ConversationId: string;
    OtherUsername: string;
    OtherUserId: string;
    LastMessage: string;
    LastMessageAt: Int64;
    UnreadCount: Integer;
  end;
  TConversationArray = array of TConversation;

  TGuild = record
    Id: string;
    Name: string;
    Slug: string;
    FounderId: string;
    FounderUsername: string;
    Icon: string;
    Bio: string;
    Link: string;
    LinkText: string;
    MemberCount: Integer;
    CreatedAt: string;
    IsMember: Boolean; // only set by Get Guild
    Role: string;      // 'founder' | 'member' | '' (not a member / list view)
  end;
  TGuildArray = array of TGuild;

  TGuildMember = record
    Username: string;
    DisplayName: string;
    Role: string;
    JoinedAt: string;
  end;
  TGuildMemberArray = array of TGuildMember;

function ParseEntry(o: TJSONObject): TEntry;
function ParseEntryArray(a: TJSONArray): TEntryArray;
function ParseReply(o: TJSONObject): TReply;
function ParseReplyArray(a: TJSONArray): TReplyArray;
function ParseNotification(o: TJSONObject): TNotification;
function ParseNotificationArray(a: TJSONArray): TNotificationArray;

{ A human-readable phrase for what the actor did, e.g. "replied to your entry". }
function NotificationPhrase(const n: TNotification): string;

function ParseRoom(o: TJSONObject): TRoom;
function ParseRoomArray(a: TJSONArray): TRoomArray;
function ParseChatMessage(o: TJSONObject): TChatMessage;
function ParseChatMessageArray(a: TJSONArray): TChatMessageArray;
function ParseConversation(o: TJSONObject): TConversation;
function ParseConversationArray(a: TJSONArray): TConversationArray;
function ParseGuild(o: TJSONObject): TGuild;
function ParseGuildArray(a: TJSONArray): TGuildArray;
function ParseGuildMember(o: TJSONObject): TGuildMember;
function ParseGuildMemberArray(a: TJSONArray): TGuildMemberArray;

{ Format a millisecond epoch as local HH:MM. }
function MsToLocalHM(ms: Int64): string;
{ Relative age of a millisecond epoch ("now", "5m", "3h", "2d"). }
function RelativeTimeMs(ms: Int64): string;

{ A one-line summary for a feed row: the title, else the first meaningful line
  of the content. }
function EntrySummary(const e: TEntry): string;

{ "now", "5m", "3h", "2d", "6w", else an ISO date. Best-effort. }
function RelativeTime(const isoUtc: string): string;

{ Decode HTML entities (&amp; &lt; &#39; …) into plain UTF-8 text. }
function DecodeEntities(const s: string): string;

implementation

uses
  SysUtils, DateUtils;

{ Encode a Unicode codepoint as UTF-8 bytes. }
function CpToUtf8(cp: Cardinal): string;
begin
  if cp <= $7F then
    Result := Chr(cp)
  else if cp <= $7FF then
    Result := Chr($C0 or (cp shr 6)) + Chr($80 or (cp and $3F))
  else if cp <= $FFFF then
    Result := Chr($E0 or (cp shr 12)) + Chr($80 or ((cp shr 6) and $3F)) +
      Chr($80 or (cp and $3F))
  else
    Result := Chr($F0 or (cp shr 18)) + Chr($80 or ((cp shr 12) and $3F)) +
      Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F));
end;

{ Decode the HTML entities the API escapes content with, into plain UTF-8 text.
  Handles the named entities we actually see plus numeric (&#NN; / &#xHH;). }
function DecodeEntities(const s: string): string;
var
  i, j, code: Integer;
  name, lname: string;
begin
  Result := '';
  i := 1;
  while i <= Length(s) do
  begin
    if s[i] = '&' then
    begin
      j := i + 1;
      while (j <= Length(s)) and (j - i <= 12) and (s[j] <> ';') and
            (s[j] <> ' ') and (s[j] <> '&') do
        Inc(j);
      if (j <= Length(s)) and (s[j] = ';') then
      begin
        name := Copy(s, i + 1, j - i - 1);
        lname := LowerCase(name);
        if lname = 'amp' then Result := Result + '&'
        else if lname = 'lt' then Result := Result + '<'
        else if lname = 'gt' then Result := Result + '>'
        else if lname = 'quot' then Result := Result + '"'
        else if lname = 'apos' then Result := Result + ''''
        else if lname = 'nbsp' then Result := Result + ' '
        else if (Length(name) >= 2) and (name[1] = '#') then
        begin
          if (name[2] = 'x') or (name[2] = 'X') then
          begin
            if TryStrToInt('$' + Copy(name, 3, Length(name) - 2), code) then
              Result := Result + CpToUtf8(Cardinal(code))
            else
              Result := Result + '&' + name + ';';
          end
          else if TryStrToInt(Copy(name, 2, Length(name) - 1), code) then
            Result := Result + CpToUtf8(Cardinal(code))
          else
            Result := Result + '&' + name + ';';
        end
        else
          Result := Result + '&' + name + ';'; // unknown: leave as-is
        i := j + 1;
        Continue;
      end;
    end;
    Result := Result + s[i];
    Inc(i);
  end;
end;

function ParseEntry(o: TJSONObject): TEntry;
var
  td: TJSONData;
  t: TJSONArray;
  i: Integer;
begin
  Result.PostId := o.Get('postId', '');
  Result.AuthorId := o.Get('authorId', '');
  Result.AuthorUsername := o.Get('authorUsername', '');
  Result.Title := DecodeEntities(o.Get('title', ''));
  Result.Slug := o.Get('slug', '');
  Result.Content := DecodeEntities(o.Get('content', ''));
  Result.CreatedAt := o.Get('createdAt', '');
  Result.RepliesCount := o.Get('repliesCount', 0);
  Result.BookmarksCount := o.Get('bookmarksCount', 0);
  Result.IsNSFW := o.Get('isNSFW', False);
  Result.IsPublic := o.Get('isPublic', False);
  Result.Deleted := o.Get('deleted', False);
  td := o.Find('topics');
  if (td <> nil) and (td is TJSONArray) then
  begin
    t := TJSONArray(td);
    SetLength(Result.Topics, t.Count);
    for i := 0 to t.Count - 1 do
      Result.Topics[i] := t.Items[i].AsString;
  end;
end;

function ParseEntryArray(a: TJSONArray): TEntryArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  if a = nil then
    Exit;
  n := 0;
  SetLength(Result, a.Count);
  for i := 0 to a.Count - 1 do
    if a.Items[i] is TJSONObject then
    begin
      Result[n] := ParseEntry(TJSONObject(a.Items[i]));
      Inc(n);
    end;
  SetLength(Result, n);
end;

function ParseReply(o: TJSONObject): TReply;
begin
  Result.ReplyId := o.Get('replyId', '');
  Result.PostId := o.Get('postId', '');
  Result.ParentReplyId := o.Get('parentReplyId', '');
  Result.AuthorId := o.Get('authorId', '');
  Result.AuthorUsername := o.Get('authorUsername', '');
  Result.Content := DecodeEntities(o.Get('content', ''));
  Result.CreatedAt := o.Get('createdAt', '');
  Result.Deleted := o.Get('deleted', False);
end;

function ParseReplyArray(a: TJSONArray): TReplyArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  if a = nil then
    Exit;
  n := 0;
  SetLength(Result, a.Count);
  for i := 0 to a.Count - 1 do
    if a.Items[i] is TJSONObject then
    begin
      Result[n] := ParseReply(TJSONObject(a.Items[i]));
      Inc(n);
    end;
  SetLength(Result, n);
end;

function ParseNotification(o: TJSONObject): TNotification;
var
  m: TJSONData;
  mo: TJSONObject;
begin
  Result.Id := o.Get('id', '');
  Result.NType := o.Get('type', '');
  Result.ActorUsername := o.Get('actorUsername', '');
  Result.TargetId := o.Get('targetId', '');
  Result.TargetType := o.Get('targetType', '');
  Result.CreatedAt := o.Get('createdAt', '');
  Result.Read := o.Get('read', False);
  m := o.Find('metadata');
  if (m <> nil) and (m is TJSONObject) then
  begin
    mo := TJSONObject(m);
    Result.MetaPostSlug := mo.Get('postSlug', '');
    Result.MetaAuthorUsername := mo.Get('authorUsername', '');
    Result.MetaReplyId := mo.Get('replyId', '');
  end;
end;

function ParseNotificationArray(a: TJSONArray): TNotificationArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  if a = nil then
    Exit;
  n := 0;
  SetLength(Result, a.Count);
  for i := 0 to a.Count - 1 do
    if a.Items[i] is TJSONObject then
    begin
      Result[n] := ParseNotification(TJSONObject(a.Items[i]));
      Inc(n);
    end;
  SetLength(Result, n);
end;

function NotificationPhrase(const n: TNotification): string;
begin
  case n.NType of
    'reply': Result := 'replied to your entry';
    'thread_reply': Result := 'replied to a thread you watch';
    'new_follower': Result := 'followed you';
    'unfollowed': Result := 'unfollowed you';
    'bookmark': Result := 'bookmarked your post';
    'new_post_following': Result := 'posted a new entry';
    'new_post_friend': Result := 'posted a new entry';
    'post_mention': Result := 'mentioned you in an entry';
    'reply_mention': Result := 'mentioned you in a reply';
    'poke': Result := 'poked you';
    'chat_mention': Result := 'mentioned you in chat';
    'dm_message': Result := 'sent you a C-Mail';
    'guild_new_thread': Result := 'started a guild thread';
    'supporter_granted': Result := 'granted you supporter';
    'supporter_removed': Result := 'removed your supporter';
    'hacker_granted': Result := 'granted you hacker';
    'hacker_removed': Result := 'removed your hacker';
    'system_ban': Result := 'system: account action';
  else
    Result := StringReplace(n.NType, '_', ' ', [rfReplaceAll]);
  end;
end;

function ParseRoom(o: TJSONObject): TRoom;
begin
  Result.Id := o.Get('id', '');
  Result.Slug := o.Get('slug', '');
  Result.Name := o.Get('name', '');
  Result.LastMessageAt := o.Get('lastMessageAt', Int64(0));
  Result.SortOrder := o.Get('sortOrder', 0);
  Result.OnlineCount := o.Get('onlineCount', 0);
end;

function ParseRoomArray(a: TJSONArray): TRoomArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  if a = nil then
    Exit;
  n := 0;
  SetLength(Result, a.Count);
  for i := 0 to a.Count - 1 do
    if a.Items[i] is TJSONObject then
    begin
      Result[n] := ParseRoom(TJSONObject(a.Items[i]));
      Inc(n);
    end;
  SetLength(Result, n);
end;

function ParseChatMessage(o: TJSONObject): TChatMessage;
begin
  Result.Id := o.Get('id', '');
  // cIRC uses userId/username; C-Mail uses senderId/senderUsername.
  Result.UserId := o.Get('userId', o.Get('senderId', ''));
  Result.Username := o.Get('username', o.Get('senderUsername', ''));
  Result.Content := DecodeEntities(o.Get('content', ''));
  Result.Timestamp := o.Get('timestamp', Int64(0));
  Result.IsChatAdmin := o.Get('isChatAdmin', False);
  Result.IsAction := o.Get('isAction', False);
  Result.Deleted := o.Get('deleted', False);
  Result.ImageUrl := o.Get('imageUrl', '');
  Result.GifUrl := o.Get('gifUrl', '');
end;

function ParseChatMessageArray(a: TJSONArray): TChatMessageArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  if a = nil then
    Exit;
  n := 0;
  SetLength(Result, a.Count);
  for i := 0 to a.Count - 1 do
    if a.Items[i] is TJSONObject then
    begin
      Result[n] := ParseChatMessage(TJSONObject(a.Items[i]));
      Inc(n);
    end;
  SetLength(Result, n);
end;

function ParseConversation(o: TJSONObject): TConversation;
var
  ou: TJSONData;
begin
  Result.ConversationId := o.Get('conversationId', '');
  Result.LastMessage := DecodeEntities(o.Get('lastMessage', ''));
  Result.LastMessageAt := o.Get('lastMessageAt', Int64(0));
  Result.UnreadCount := o.Get('unreadCount', 0);
  ou := o.Find('otherUser');
  if (ou <> nil) and (ou is TJSONObject) then
  begin
    Result.OtherUsername := TJSONObject(ou).Get('username', '');
    Result.OtherUserId := TJSONObject(ou).Get('userId', '');
  end;
end;

function ParseConversationArray(a: TJSONArray): TConversationArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  if a = nil then
    Exit;
  n := 0;
  SetLength(Result, a.Count);
  for i := 0 to a.Count - 1 do
    if a.Items[i] is TJSONObject then
    begin
      Result[n] := ParseConversation(TJSONObject(a.Items[i]));
      Inc(n);
    end;
  SetLength(Result, n);
end;

function ParseGuild(o: TJSONObject): TGuild;
var
  rd: TJSONData;
begin
  Result.Id := o.Get('id', '');
  Result.Name := DecodeEntities(o.Get('name', ''));
  Result.Slug := o.Get('slug', '');
  Result.FounderId := o.Get('founderId', '');
  Result.FounderUsername := o.Get('founderUsername', '');
  Result.Icon := o.Get('icon', '');
  Result.Bio := DecodeEntities(o.Get('bio', ''));
  Result.Link := o.Get('link', '');
  Result.LinkText := o.Get('linkText', '');
  Result.MemberCount := o.Get('memberCount', 0);
  Result.CreatedAt := o.Get('createdAt', '');
  Result.IsMember := o.Get('isMember', False);
  // role is null when the caller isn't a member -- read it defensively.
  rd := o.Find('role');
  if (rd <> nil) and (rd.JSONType = jtString) then
    Result.Role := rd.AsString
  else
    Result.Role := '';
end;

function ParseGuildArray(a: TJSONArray): TGuildArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  if a = nil then
    Exit;
  n := 0;
  SetLength(Result, a.Count);
  for i := 0 to a.Count - 1 do
    if a.Items[i] is TJSONObject then
    begin
      Result[n] := ParseGuild(TJSONObject(a.Items[i]));
      Inc(n);
    end;
  SetLength(Result, n);
end;

function ParseGuildMember(o: TJSONObject): TGuildMember;
begin
  Result.Username := o.Get('username', '');
  Result.DisplayName := DecodeEntities(o.Get('displayName', ''));
  Result.Role := o.Get('role', '');
  Result.JoinedAt := o.Get('joinedAt', '');
end;

function ParseGuildMemberArray(a: TJSONArray): TGuildMemberArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  if a = nil then
    Exit;
  n := 0;
  SetLength(Result, a.Count);
  for i := 0 to a.Count - 1 do
    if a.Items[i] is TJSONObject then
    begin
      Result[n] := ParseGuildMember(TJSONObject(a.Items[i]));
      Inc(n);
    end;
  SetLength(Result, n);
end;

function MsToLocalHM(ms: Int64): string;
begin
  if ms <= 0 then
    Exit('');
  Result := FormatDateTime('hh:nn', UniversalTimeToLocal(UnixToDateTime(ms div 1000)));
end;

function RelativeTimeMs(ms: Int64): string;
var
  dt, nowUtc: TDateTime;
  secs: Int64;
begin
  if ms <= 0 then
    Exit('');
  dt := UnixToDateTime(ms div 1000);
  nowUtc := LocalTimeToUniversal(Now);
  secs := Round((nowUtc - dt) * 86400.0);
  if secs < 45 then
    Result := 'now'
  else if secs < 3600 then
    Result := IntToStr(secs div 60) + 'm'
  else if secs < 86400 then
    Result := IntToStr(secs div 3600) + 'h'
  else
    Result := IntToStr(secs div 86400) + 'd';
end;

function EntrySummary(const e: TEntry): string;
var
  p: Integer;
  s: string;
begin
  if e.Deleted then
    Exit('[deleted]');
  if Trim(e.Title) <> '' then
    Exit(Trim(e.Title));
  s := e.Content;
  // First line only.
  p := Pos(#10, s);
  if p > 0 then
    s := Copy(s, 1, p - 1);
  p := Pos(#13, s);
  if p > 0 then
    s := Copy(s, 1, p - 1);
  s := Trim(s);
  // Strip a leading markdown marker so the row reads cleanly.
  while (s <> '') and (s[1] in ['#', '>', '-', '*', ' ']) do
    Delete(s, 1, 1);
  if Trim(s) = '' then
    Exit('(no title)');
  Result := Trim(s);
end;

function ParseIsoUtc(const s: string; out dt: TDateTime): Boolean;
var
  yy, mm, dd, hh, nn, ss: Integer;
begin
  Result := False;
  if Length(s) < 19 then
    Exit;
  if not TryStrToInt(Copy(s, 1, 4), yy) then Exit;
  if not TryStrToInt(Copy(s, 6, 2), mm) then Exit;
  if not TryStrToInt(Copy(s, 9, 2), dd) then Exit;
  if not TryStrToInt(Copy(s, 12, 2), hh) then Exit;
  if not TryStrToInt(Copy(s, 15, 2), nn) then Exit;
  if not TryStrToInt(Copy(s, 18, 2), ss) then Exit;
  if not TryEncodeDateTime(yy, mm, dd, hh, nn, ss, 0, dt) then Exit;
  Result := True;
end;

function RelativeTime(const isoUtc: string): string;
var
  dt, nowUtc: TDateTime;
  secs: Int64;
begin
  if not ParseIsoUtc(isoUtc, dt) then
    Exit(Copy(isoUtc, 1, 10));
  nowUtc := LocalTimeToUniversal(Now);
  secs := Round((nowUtc - dt) * 86400.0);
  if secs < 45 then
    Result := 'now'
  else if secs < 3600 then
    Result := IntToStr(secs div 60) + 'm'
  else if secs < 86400 then
    Result := IntToStr(secs div 3600) + 'h'
  else if secs < 7 * 86400 then
    Result := IntToStr(secs div 86400) + 'd'
  else if secs < 365 * 86400 then
    Result := IntToStr(secs div (7 * 86400)) + 'w'
  else
    Result := Copy(isoUtc, 1, 10);
end;

end.
