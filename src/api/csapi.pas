unit CsApi;

(* Small shared API helpers that more than one view needs: fetching a single
   entry (by id or by author/slug), a single reply, and the unread-notification
   count. Each returns False and fills err on failure rather than raising, so
   callers can surface the message in a status bar. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession, CsModels;

type
  { Post visibility. pvDefault omits isPublic, so the server applies the
    account's defaultPublicPost setting. }
  TPostVisibility = (pvDefault, pvPublic, pvPrivate);

function FetchEntryById(sess: TCsSession; const id: string;
  out e: TEntry; out err: string): Boolean;
function FetchEntryBySlug(sess: TCsSession; const username, slug: string;
  out e: TEntry; out err: string): Boolean;
function FetchReplyById(sess: TCsSession; const id: string;
  out r: TReply; out err: string): Boolean;
function FetchUnreadCount(sess: TCsSession; out count: Integer;
  out exact: Boolean; out err: string): Boolean;

{ Create a top-level entry. Returns the new postId. vis controls visibility:
  pvDefault leaves it to the account default. }
function CreateEntry(sess: TCsSession; const content: string;
  out postId, err: string; const title: string = '';
  const topics: string = ''; const isNSFW: Boolean = False;
  const vis: TPostVisibility = pvDefault): Boolean;
{ Create a reply to a post; pass parentReplyId to reply to a specific reply. }
function CreateReply(sess: TCsSession; const postId, content: string;
  out replyId, err: string; const parentReplyId: string = ''): Boolean;

{ Edit the body of your own entry / reply (PATCH content). Server-gated: for
  supporters, within 5 minutes of posting — otherwise a 403 comes back in err. }
function EditEntry(sess: TCsSession; const postId, content: string; out err: string): Boolean;
function EditReply(sess: TCsSession; const replyId, content: string; out err: string): Boolean;

{ Delete your own entry / reply. }
function DeleteEntry(sess: TCsSession; const id: string; out err: string): Boolean;
function DeleteReply(sess: TCsSession; const id: string; out err: string): Boolean;

{ Send a cIRC message (content may begin with / for a server-side command). }
function SendChatMessage(sess: TCsSession; const roomId, content: string;
  out messageId, err: string): Boolean;
{ Soft-delete your own cIRC message. }
function DeleteChatMessage(sess: TCsSession; const roomId, messageId: string;
  out err: string): Boolean;

{ Announce presence in a room (heartbeat). Reports our last activity (ms epoch;
  pass 0 to omit) so idle users can show as asleep; returns the cadence plus the
  idle window. }
function AnnouncePresence(sess: TCsSession; const roomId: string; lastActivity: Int64;
  out heartbeatMs, staleAfterMs, idleAfterMs: Integer; out err: string): Boolean;
{ Remove your presence from a room (on leave). }
function LeavePresence(sess: TCsSession; const roomId: string; out err: string): Boolean;

{ Follow a user by their userId. Returns the follow document id. }
function FollowUser(sess: TCsSession; const followedId: string;
  out followId, err: string): Boolean;
{ Unfollow via the follow document id. }
function UnfollowUser(sess: TCsSession; const followId: string; out err: string): Boolean;
{ Look up whether you follow a user and, if so, the follow document id (needed to
  unfollow). Pages through your following list. }
function FindFollowing(sess: TCsSession; const followedUserId: string;
  out followId, err: string): Boolean;

{ Bookmark an entry; remove a bookmark by its document id. }
function CreateBookmarkPost(sess: TCsSession; const postId: string;
  out bookmarkId, err: string): Boolean;
function RemoveBookmark(sess: TCsSession; const bookmarkId: string; out err: string): Boolean;

{ C-Mail: start/get a conversation with a user; send; mark read. }
function StartConversation(sess: TCsSession; const recipientUsername: string;
  out conversationId, otherUsername, err: string): Boolean;
function SendCMail(sess: TCsSession; const conversationId, content: string;
  out messageId, err: string): Boolean;
function MarkCMailRead(sess: TCsSession; const conversationId: string;
  out err: string): Boolean;
{ Publish/clear your "is typing" flag in a conversation. }
function SendTyping(sess: TCsSession; const conversationId: string;
  out heartbeatMs, staleAfterMs: Integer; out err: string): Boolean;
function StopTyping(sess: TCsSession; const conversationId: string; out err: string): Boolean;

{ Guilds: fetch one guild (with the caller's membership state); start a forum
  thread; join; leave. Discovery/list endpoints are read inline by the view. }
function FetchGuild(sess: TCsSession; const slug: string;
  out g: TGuild; out err: string): Boolean;
function CreateGuildThread(sess: TCsSession; const slug, content: string;
  out postId, err: string; const title: string = '';
  const topics: string = ''): Boolean;
function JoinGuild(sess: TCsSession; const slug: string;
  out role, err: string): Boolean;
function PromoteGuild(sess: TCsSession; const slug: string;
  out role, err: string): Boolean;
function LeaveGuild(sess: TCsSession; const slug: string; out err: string): Boolean;
{ Poke a user (a nudge notification). }
function PokeUser(sess: TCsSession; const username: string; out err: string): Boolean;

{ Notes: private, revisioned. Fetch one (revision 0 = latest); create; update
  (PATCH creates a new revision); soft-delete. The list and revision history are
  read inline by the view. }
function FetchNote(sess: TCsSession; const id: string; revision: Integer;
  out n: TNote; out err: string): Boolean;
function CreateNote(sess: TCsSession; const content: string;
  out noteId, err: string; const topics: string = ''): Boolean;
function UpdateNote(sess: TCsSession; const noteId, content, topics: string;
  out err: string): Boolean;
function DeleteNote(sess: TCsSession; const id: string; out err: string): Boolean;

{ Thread watching: whether you watch a thread, and watch/unwatch it (you get
  thread_reply notifications while watching). The watched list is read inline by
  the view. }
function FetchWatchStatus(sess: TCsSession; const postId: string;
  out watching: Boolean; out err: string): Boolean;
function WatchThread(sess: TCsSession; const postId: string; out err: string): Boolean;
function UnwatchThread(sess: TCsSession; const postId: string; out err: string): Boolean;

{ Load read-side preferences (currently just filterNSFW) into the session.
  Best-effort: leaves the session default on any error. }
procedure RefreshPrefs(sess: TCsSession);

{ Report content to moderators. `reason` is optional (<=500 chars). Idempotent:
  `already` comes back True if you'd already flagged it. You can't flag your own
  content (returns False with a 403 in err). }
function FlagEntry(sess: TCsSession; const postId, reason: string;
  out already: Boolean; out err: string): Boolean;
function FlagReply(sess: TCsSession; const replyId, reason: string;
  out already: Boolean; out err: string): Boolean;
function FlagChatMessage(sess: TCsSession; const roomId, messageId, reason: string;
  out already: Boolean; out err: string): Boolean;

implementation

uses
  SysUtils, fpjson, CsHttp;

function GetEntry(sess: TCsSession; const path: string;
  out e: TEntry; out err: string): Boolean;
var
  env, d: TJSONObject;
begin
  Result := False;
  err := '';
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := CsData(env);
      e := ParseEntry(d);
      Result := e.PostId <> '';
      if not Result then
        err := 'Entry not found';
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchEntryById(sess: TCsSession; const id: string;
  out e: TEntry; out err: string): Boolean;
begin
  Result := GetEntry(sess, '/v1/posts/' + id, e, err);
end;

function FetchEntryBySlug(sess: TCsSession; const username, slug: string;
  out e: TEntry; out err: string): Boolean;
begin
  Result := GetEntry(sess, '/v1/users/' + username + '/posts/' + slug, e, err);
end;

function FetchReplyById(sess: TCsSession; const id: string;
  out r: TReply; out err: string): Boolean;
var
  env, d: TJSONObject;
begin
  Result := False;
  err := '';
  try
    env := sess.Client.GetJSONObj('/v1/replies/' + id);
    try
      d := CsData(env);
      r := ParseReply(d);
      Result := r.PostId <> '';
      if not Result then
        err := 'Reply not found';
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchUnreadCount(sess: TCsSession; out count: Integer;
  out exact: Boolean; out err: string): Boolean;
var
  env, d: TJSONObject;
begin
  Result := False;
  count := 0;
  exact := True; // out params of simple types aren't auto-initialised
  err := '';
  try
    env := sess.Client.GetJSONObj('/v1/notifications/unread-count');
    try
      d := CsData(env);
      count := d.Get('count', 0);
      // exact=false once >100 unread: count then covers only the newest 100.
      exact := d.Get('exact', True);
      Result := True;
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

{ Parse a comma-separated string (e.g. "music, space music, #linux") into up to 3
  lowercased topics — a topic may be multiple words — and attach them to the body. }
procedure AddTopics(body: TJSONObject; const s: string);
var
  arr: TJSONArray;
  i: Integer;
  tok: string;

  procedure Flush;
  begin
    while (tok <> '') and (tok[1] = '#') do
      Delete(tok, 1, 1);
    tok := LowerCase(Trim(tok));
    if (tok <> '') and (arr.Count < 3) then
      arr.Add(tok);
    tok := '';
  end;

begin
  arr := TJSONArray.Create;
  tok := '';
  // Comma-separated only — a topic can be multiple words (e.g. "space music").
  for i := 1 to Length(s) do
    if s[i] = ',' then
      Flush
    else
      tok := tok + s[i];
  Flush;
  if arr.Count > 0 then
    body.Add('topics', arr)
  else
    arr.Free;
end;

function CreateEntry(sess: TCsSession; const content: string;
  out postId, err: string; const title: string = '';
  const topics: string = ''; const isNSFW: Boolean = False;
  const vis: TPostVisibility = pvDefault): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  postId := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('content', content);
    if Trim(title) <> '' then
      body.Add('title', Trim(title));
    if Trim(topics) <> '' then
      AddTopics(body, topics);
    if isNSFW then
      body.Add('isNSFW', True);
    case vis of
      pvPublic: body.Add('isPublic', True);
      pvPrivate: body.Add('isPublic', False);
      // pvDefault: omit isPublic -> server uses the account's defaultPublicPost
    end;
    try
      env := sess.Client.PostJSONObj('/v1/posts', body);
      try
        d := CsData(env);
        postId := d.Get('postId', '');
        Result := postId <> '';
        if not Result then
          err := 'Server did not return a postId';
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function CreateReply(sess: TCsSession; const postId, content: string;
  out replyId, err: string; const parentReplyId: string = ''): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  replyId := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('postId', postId);
    body.Add('content', content);
    if parentReplyId <> '' then
      body.Add('parentReplyId', parentReplyId);
    try
      env := sess.Client.PostJSONObj('/v1/replies', body);
      try
        d := CsData(env);
        replyId := d.Get('replyId', '');
        Result := replyId <> '';
        if not Result then
          err := 'Server did not return a replyId';
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function DeleteAt(sess: TCsSession; const path: string; out err: string): Boolean;
var
  env: TJSONObject;
begin
  Result := False;
  err := '';
  try
    env := sess.Client.DeleteJSONObj(path);
    env.Free;
    Result := True;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function DeleteEntry(sess: TCsSession; const id: string; out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/posts/' + id, err);
end;

function DeleteReply(sess: TCsSession; const id: string; out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/replies/' + id, err);
end;

{ PATCH only `content` — the one field a reply edit allows, and enough for an
  entry (title/topics/etc. are left untouched by not sending them). }
function EditAt(sess: TCsSession; const path, content: string; out err: string): Boolean;
var
  body, env: TJSONObject;
begin
  Result := False;
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('content', content);
    try
      env := sess.Client.PatchJSONObj(path, body);
      env.Free;
      Result := True;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function EditEntry(sess: TCsSession; const postId, content: string; out err: string): Boolean;
begin
  Result := EditAt(sess, '/v1/posts/' + postId, content, err);
end;

function EditReply(sess: TCsSession; const replyId, content: string; out err: string): Boolean;
begin
  Result := EditAt(sess, '/v1/replies/' + replyId, content, err);
end;

function SendChatMessage(sess: TCsSession; const roomId, content: string;
  out messageId, err: string): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  messageId := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('content', content);
    try
      env := sess.Client.PostJSONObj('/v1/circ/' + roomId, body);
      try
        d := CsData(env);
        messageId := d.Get('messageId', '');
        Result := messageId <> '';
        if not Result then
          err := 'Server did not return a messageId';
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function DeleteChatMessage(sess: TCsSession; const roomId, messageId: string;
  out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/circ/' + roomId + '/messages/' + messageId, err);
end;

function AnnouncePresence(sess: TCsSession; const roomId: string; lastActivity: Int64;
  out heartbeatMs, staleAfterMs, idleAfterMs: Integer; out err: string): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  heartbeatMs := 30000;
  staleAfterMs := 180000;
  idleAfterMs := 300000;
  err := '';
  body := TJSONObject.Create;
  try
    if lastActivity > 0 then
      body.Add('lastActivity', lastActivity);
    try
      env := sess.Client.PostJSONObj('/v1/circ/' + roomId + '/presence', body);
      try
        d := CsData(env);
        heartbeatMs := d.Get('heartbeatMs', heartbeatMs);
        staleAfterMs := d.Get('staleAfterMs', staleAfterMs);
        idleAfterMs := d.Get('idleAfterMs', idleAfterMs);
        Result := True;
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function LeavePresence(sess: TCsSession; const roomId: string; out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/circ/' + roomId + '/presence', err);
end;

function FollowUser(sess: TCsSession; const followedId: string;
  out followId, err: string): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  followId := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('followedId', followedId);
    try
      env := sess.Client.PostJSONObj('/v1/follows', body);
      try
        d := CsData(env);
        followId := d.Get('id', d.Get('followId', ''));
        Result := True;
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function CreateBookmarkPost(sess: TCsSession; const postId: string;
  out bookmarkId, err: string): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  bookmarkId := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('postId', postId);
    body.Add('type', 'post');
    try
      env := sess.Client.PostJSONObj('/v1/bookmarks', body);
      try
        d := CsData(env);
        bookmarkId := d.Get('id', d.Get('bookmarkId', ''));
        Result := True;
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function RemoveBookmark(sess: TCsSession; const bookmarkId: string; out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/bookmarks/' + bookmarkId, err);
end;

function UnfollowUser(sess: TCsSession; const followId: string; out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/follows/' + followId, err);
end;

function FindFollowing(sess: TCsSession; const followedUserId: string;
  out followId, err: string): Boolean;
var
  env: TJSONObject;
  o: TJSONObject;
  d, sub: TJSONData;
  a: TJSONArray;
  i, page: Integer;
  cursor, path, fid, fuid: string;
begin
  Result := False;
  followId := '';
  err := '';
  cursor := '';
  page := 0;
  try
    repeat
      path := '/v1/follows?type=following&limit=50';
      if cursor <> '' then
        path := path + '&cursor=' + cursor;
      env := sess.Client.GetJSONObj(path);
      try
        d := env.Find('data');
        if d is TJSONArray then
        begin
          a := TJSONArray(d);
          for i := 0 to a.Count - 1 do
            if a.Items[i] is TJSONObject then
            begin
              o := TJSONObject(a.Items[i]);
              fid := o.Get('id', o.Get('followId', ''));
              fuid := o.Get('followedId', o.Get('userId', ''));
              if fuid = '' then
              begin
                sub := o.Find('followed');
                if sub = nil then sub := o.Find('user');
                if sub is TJSONObject then
                  fuid := TJSONObject(sub).Get('userId', TJSONObject(sub).Get('id', ''));
              end;
              if fuid = followedUserId then
              begin
                followId := fid;
                Exit(True);
              end;
            end;
        end;
        cursor := env.Get('cursor', '');
      finally
        env.Free;
      end;
      Inc(page);
    until (cursor = '') or (page >= 10); // bound the scan
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function StartConversation(sess: TCsSession; const recipientUsername: string;
  out conversationId, otherUsername, err: string): Boolean;
var
  body, env, d: TJSONObject;
  ou: TJSONData;
begin
  Result := False;
  conversationId := '';
  otherUsername := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('recipientUsername', recipientUsername);
    try
      env := sess.Client.PostJSONObj('/v1/cmail', body);
      try
        d := CsData(env);
        conversationId := d.Get('conversationId', '');
        ou := d.Find('otherUser');
        if (ou <> nil) and (ou is TJSONObject) then
          otherUsername := TJSONObject(ou).Get('username', '');
        Result := conversationId <> '';
        if not Result then
          err := 'No conversationId returned';
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function SendCMail(sess: TCsSession; const conversationId, content: string;
  out messageId, err: string): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  messageId := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('content', content);
    try
      env := sess.Client.PostJSONObj('/v1/cmail/' + conversationId, body);
      try
        d := CsData(env);
        messageId := d.Get('messageId', '');
        Result := messageId <> '';
        if not Result then
          err := 'No messageId returned';
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function MarkCMailRead(sess: TCsSession; const conversationId: string;
  out err: string): Boolean;
var
  env: TJSONObject;
begin
  Result := False;
  err := '';
  try
    env := sess.Client.PostJSONObj('/v1/cmail/' + conversationId + '/read', nil);
    env.Free;
    Result := True;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function SendTyping(sess: TCsSession; const conversationId: string;
  out heartbeatMs, staleAfterMs: Integer; out err: string): Boolean;
var
  env, d: TJSONObject;
begin
  Result := False;
  heartbeatMs := 3000;
  staleAfterMs := 9000;
  err := '';
  try
    env := sess.Client.PostJSONObj('/v1/cmail/' + conversationId + '/typing', nil);
    try
      d := CsData(env);
      heartbeatMs := d.Get('heartbeatMs', heartbeatMs);
      staleAfterMs := d.Get('staleAfterMs', staleAfterMs);
      Result := True;
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function StopTyping(sess: TCsSession; const conversationId: string; out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/cmail/' + conversationId + '/typing', err);
end;

{ POST with no body, discarding the envelope -- used by join/leave, whose only
  outcome that matters here is success vs. the server's error (409/403/…). }
function PostNoBody(sess: TCsSession; const path: string; out err: string): Boolean;
var
  env: TJSONObject;
begin
  Result := False;
  err := '';
  try
    env := sess.Client.PostJSONObj(path, nil);
    env.Free;
    Result := True;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchGuild(sess: TCsSession; const slug: string;
  out g: TGuild; out err: string): Boolean;
var
  env, d: TJSONObject;
begin
  Result := False;
  err := '';
  try
    env := sess.Client.GetJSONObj('/v1/guilds/' + slug);
    try
      d := CsData(env);
      g := ParseGuild(d);
      Result := g.Slug <> '';
      if not Result then
        err := 'Guild not found';
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function CreateGuildThread(sess: TCsSession; const slug, content: string;
  out postId, err: string; const title: string = '';
  const topics: string = ''): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  postId := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('content', content);
    if Trim(title) <> '' then
      body.Add('title', Trim(title));
    if Trim(topics) <> '' then
      AddTopics(body, topics);
    try
      env := sess.Client.PostJSONObj('/v1/guilds/' + slug + '/posts', body);
      try
        d := CsData(env);
        postId := d.Get('postId', '');
        Result := postId <> '';
        if not Result then
          err := 'Server did not return a postId';
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

{ POST a bodyless guild membership action that returns { role } in its data. }
function GuildRoleAction(sess: TCsSession; const path: string;
  out role, err: string): Boolean;
var
  env: TJSONObject;
begin
  Result := False;
  role := '';
  err := '';
  try
    env := sess.Client.PostJSONObj(path, nil);
    try
      role := CsData(env).Get('role', '');
      Result := True;
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function JoinGuild(sess: TCsSession; const slug: string;
  out role, err: string): Boolean;
begin
  // role comes back 'member' (your first guild) or 'apprentice' (the rest).
  Result := GuildRoleAction(sess, '/v1/guilds/' + slug + '/join', role, err);
end;

function PromoteGuild(sess: TCsSession; const slug: string;
  out role, err: string): Boolean;
begin
  // Makes an apprenticeship your guild (badge); old guild becomes apprentice.
  Result := GuildRoleAction(sess, '/v1/guilds/' + slug + '/promote', role, err);
end;

function LeaveGuild(sess: TCsSession; const slug: string; out err: string): Boolean;
begin
  Result := PostNoBody(sess, '/v1/guilds/' + slug + '/leave', err);
end;

function PokeUser(sess: TCsSession; const username: string; out err: string): Boolean;
begin
  // Sends a `poke` notification. 400 self, 403 blocked, 404 unknown user.
  Result := PostNoBody(sess, '/v1/users/' + username + '/poke', err);
end;

function FetchNote(sess: TCsSession; const id: string; revision: Integer;
  out n: TNote; out err: string): Boolean;
var
  env, d: TJSONObject;
  path: string;
begin
  Result := False;
  err := '';
  path := '/v1/notes/' + id;
  if revision > 0 then
    path := path + '?revision=' + IntToStr(revision);
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := CsData(env);
      n := ParseNote(d);
      Result := n.Id <> '';
      if not Result then
        err := 'Note not found';
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function CreateNote(sess: TCsSession; const content: string;
  out noteId, err: string; const topics: string = ''): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  noteId := '';
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('content', content);
    if Trim(topics) <> '' then
      AddTopics(body, topics);
    try
      env := sess.Client.PostJSONObj('/v1/notes', body);
      try
        d := CsData(env);
        noteId := d.Get('id', d.Get('noteId', ''));
        Result := True; // creation succeeded even if the id shape surprises us
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function UpdateNote(sess: TCsSession; const noteId, content, topics: string;
  out err: string): Boolean;
var
  body, env: TJSONObject;
begin
  Result := False;
  err := '';
  body := TJSONObject.Create;
  try
    body.Add('content', content);
    if Trim(topics) <> '' then
      AddTopics(body, topics);
    try
      env := sess.Client.PatchJSONObj('/v1/notes/' + noteId, body);
      env.Free;
      Result := True;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function DeleteNote(sess: TCsSession; const id: string; out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/notes/' + id, err);
end;

function FetchWatchStatus(sess: TCsSession; const postId: string;
  out watching: Boolean; out err: string): Boolean;
var
  env, d: TJSONObject;
begin
  Result := False;
  watching := False;
  err := '';
  try
    env := sess.Client.GetJSONObj('/v1/posts/' + postId + '/watch');
    try
      d := CsData(env);
      watching := d.Get('watching', False);
      Result := True;
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function WatchThread(sess: TCsSession; const postId: string; out err: string): Boolean;
begin
  Result := PostNoBody(sess, '/v1/posts/' + postId + '/watch', err);
end;

function UnwatchThread(sess: TCsSession; const postId: string; out err: string): Boolean;
begin
  Result := DeleteAt(sess, '/v1/posts/' + postId + '/watch', err);
end;

procedure RefreshPrefs(sess: TCsSession);
var
  env, d: TJSONObject;
begin
  try
    env := sess.Client.GetJSONObj('/v1/settings');
    try
      d := CsData(env);
      sess.FilterNSFW := d.Get('filterNSFW', False);
    finally
      env.Free;
    end;
  except
    on E: Exception do
      ; // best effort — keep the current value
  end;
end;

{ POST a flag with an optional reason; success sets `already` from the response. }
function PostFlag(sess: TCsSession; const path, reason: string;
  out already: Boolean; out err: string): Boolean;
var
  body, env, d: TJSONObject;
begin
  Result := False;
  already := False;
  err := '';
  body := TJSONObject.Create;
  try
    if Trim(reason) <> '' then
      body.Add('reason', Copy(Trim(reason), 1, 500));
    try
      env := sess.Client.PostJSONObj(path, body);
      try
        d := CsData(env);
        already := d.Get('alreadyFlagged', False);
        Result := True; // no exception => 200/201, report is on file
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
  finally
    body.Free;
  end;
end;

function FlagEntry(sess: TCsSession; const postId, reason: string;
  out already: Boolean; out err: string): Boolean;
begin
  Result := PostFlag(sess, '/v1/posts/' + postId + '/flag', reason, already, err);
end;

function FlagReply(sess: TCsSession; const replyId, reason: string;
  out already: Boolean; out err: string): Boolean;
begin
  Result := PostFlag(sess, '/v1/replies/' + replyId + '/flag', reason, already, err);
end;

function FlagChatMessage(sess: TCsSession; const roomId, messageId, reason: string;
  out already: Boolean; out err: string): Boolean;
begin
  Result := PostFlag(sess, '/v1/circ/' + roomId + '/messages/' + messageId + '/flag',
    reason, already, err);
end;

end.
