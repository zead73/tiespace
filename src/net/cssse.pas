unit CsSSE;

(* Firebase RTDB Server-Sent-Events readers, each in a background thread.

   TRtdbSSEThread is the reusable base: it holds a long-lived streaming GET open
   (via a custom TStream sink fed by TFPHTTPClient.HTTPMethod, which blocks in
   the thread) and parses the event stream into event/path/data frames, calling
   the virtual OnEvent for each. Termination is cooperative: the sink raises once
   Terminated, unwinding the blocked request on Firebase's next keep-alive.

   TChatStreamThread turns message frames into an op queue (upsert / remove /
   mark-deleted). TPresenceThread maintains a live map of who is in a room.

   Shared state the UI reads is guarded by a critical section; the plain Boolean
   status flags are written by the thread and read by the UI without locking,
   which is fine for a status indicator. *)

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, CsModels;

type
  TSSEOpKind = (opUpsert, opRemove, opMarkDeleted);
  TSSEOp = record
    Kind: TSSEOpKind;
    Msg: TChatMessage;
    Id: string;
  end;
  TSSEOpArray = array of TSSEOp;

  TPresenceEntry = record
    UserId: string;
    Username: string;
    IsChatAdmin: Boolean;
    Online: Boolean;
    Typing: Boolean;
    LastSeen: Int64;     // 'lastSeen' (chat presence) or 'timestamp' (dm typing)
    LastActivity: Int64; // 'lastActivity' ms epoch; 0 = not reported (reads active)
  end;
  TNameArray = array of string;

  TOnlineUser = record
    Name: string;
    Idle: Boolean; // no activity within idleAfterMs -> shown asleep
  end;
  TOnlineArray = array of TOnlineUser;

  TRtdbSSEThread = class(TThread)
  private
    FUrl: string;
    FEventType, FDataBuf, FLineBuf: string;
    FConnected, FGaveUp, FGotData: Boolean;
    procedure HandleFrame;
    procedure FeedLine(const line: string);
    procedure SleepInterruptible(ms: Integer);
  protected
    procedure OnEvent(const evType, path: string; data: TJSONData); virtual; abstract;
    procedure Execute; override;
  public
    constructor Create(const AUrl: string);
    procedure Feed(const chunk: string); // called by the sink on each chunk
    function IsStopping: Boolean;
    property Connected: Boolean read FConnected;
    property GaveUp: Boolean read FGaveUp;
  end;

  TChatStreamThread = class(TRtdbSSEThread)
  private
    FLock: TRTLCriticalSection;
    FOps: TSSEOpArray;
    procedure PushOp(const op: TSSEOp);
    procedure ApplyPut(const path: string; dn: TJSONData);
    procedure ApplyPatch(const path: string; dn: TJSONData);
    procedure UpsertMsg(const id: string; obj: TJSONObject);
  protected
    procedure OnEvent(const evType, path: string; data: TJSONData); override;
  public
    constructor Create(const AUrl: string);
    destructor Destroy; override;
    procedure DrainOps(out ops: TSSEOpArray);
  end;

  TPresenceThread = class(TRtdbSSEThread)
  private
    FLock: TRTLCriticalSection;
    FMap: array of TPresenceEntry;
    function IndexOf(const uid: string): Integer;
    procedure UpsertP(const uid: string; obj: TJSONObject);
    procedure RemoveP(const uid: string);
  protected
    procedure OnEvent(const evType, path: string; data: TJSONData); override;
  public
    constructor Create(const AUrl: string);
    destructor Destroy; override;
    { Present users (online, lastSeen within staleAfterMs), sorted by name, each
      flagged idle when their reported lastActivity is older than idleAfterMs. }
    procedure GetOnlineUsers(out users: TOnlineArray; staleAfterMs, idleAfterMs: Int64);
    { Usernames currently typing (typing and fresh), excluding `exclude`. }
    procedure GetTyping(out names: TNameArray; staleAfterMs: Int64; const exclude: string);
  end;

{ Current time as a UTC millisecond epoch, matching the server's timestamps. }
function NowMs: Int64;

implementation

uses
  fphttpclient, opensslsockets, jsonparser, DateUtils;

function StripPath(const p: string): string;
var
  q: Integer;
begin
  Result := p;
  if (Result <> '') and (Result[1] = '/') then
    Delete(Result, 1, 1);
  q := Pos('/', Result);
  if q > 0 then
    Result := Copy(Result, 1, q - 1);
end;

function NowMs: Int64;
begin
  Result := DateTimeToUnix(LocalTimeToUniversal(Now)) * Int64(1000);
end;

{ ---- sink ---- }

type
  TSSESink = class(TStream)
  private
    FT: TRtdbSSEThread;
  public
    constructor Create(AT: TRtdbSSEThread);
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TSSESink.Create(AT: TRtdbSSEThread);
begin
  inherited Create;
  FT := AT;
end;

function TSSESink.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TSSESink.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

function TSSESink.Write(const Buffer; Count: Longint): Longint;
var
  s: string;
begin
  Result := Count;
  if FT.IsStopping then
    raise Exception.Create('stream terminated');
  if Count > 0 then
  begin
    SetLength(s, Count);
    Move(Buffer, s[1], Count);
    FT.Feed(s);
  end;
end;

{ ---- TRtdbSSEThread ---- }

constructor TRtdbSSEThread.Create(const AUrl: string);
begin
  FUrl := AUrl;
  FreeOnTerminate := True;
  inherited Create(True); // suspended: subclass inits its state, then Start
end;

function TRtdbSSEThread.IsStopping: Boolean;
begin
  Result := Terminated;
end;

procedure TRtdbSSEThread.HandleFrame;
var
  j: TJSONData;
  o: TJSONObject;
  path: string;
  dn: TJSONData;
begin
  if (FEventType = '') or (FEventType = 'keep-alive') then
    Exit;
  if (FEventType = 'cancel') or (FEventType = 'auth_revoked') then
  begin
    FGaveUp := True;
    Exit;
  end;
  if Trim(FDataBuf) = '' then
    Exit;
  try
    j := GetJSON(FDataBuf);
  except
    Exit;
  end;
  try
    if not (j is TJSONObject) then
      Exit;
    o := TJSONObject(j);
    path := o.Get('path', '/');
    dn := o.Find('data');
    OnEvent(FEventType, path, dn);
  finally
    j.Free;
  end;
end;

procedure TRtdbSSEThread.FeedLine(const line: string);
var
  rest: string;
begin
  if line = '' then
  begin
    HandleFrame;
    FEventType := '';
    FDataBuf := '';
    Exit;
  end;
  if line[1] = ':' then
    Exit;
  if Copy(line, 1, 6) = 'event:' then
    FEventType := Trim(Copy(line, 7, MaxInt))
  else if Copy(line, 1, 5) = 'data:' then
  begin
    rest := Copy(line, 6, MaxInt);
    if (rest <> '') and (rest[1] = ' ') then
      Delete(rest, 1, 1);
    if FDataBuf <> '' then
      FDataBuf := FDataBuf + #10;
    FDataBuf := FDataBuf + rest;
  end;
end;

procedure TRtdbSSEThread.Feed(const chunk: string);
var
  i: Integer;
  line: string;
begin
  FGotData := True;
  FLineBuf := FLineBuf + chunk;
  repeat
    i := Pos(#10, FLineBuf);
    if i = 0 then
      Break;
    line := Copy(FLineBuf, 1, i - 1);
    Delete(FLineBuf, 1, i);
    if (line <> '') and (line[Length(line)] = #13) then
      SetLength(line, Length(line) - 1);
    FeedLine(line);
  until False;
end;

procedure TRtdbSSEThread.SleepInterruptible(ms: Integer);
var
  elapsed: Integer;
begin
  elapsed := 0;
  while (elapsed < ms) and (not Terminated) do
  begin
    Sleep(100);
    Inc(elapsed, 100);
  end;
end;

procedure TRtdbSSEThread.Execute;
var
  client: TFPHTTPClient;
  sink: TSSESink;
  failures: Integer;
begin
  failures := 0;
  while not Terminated do
  begin
    FConnected := False;
    FGotData := False;
    FEventType := '';
    FDataBuf := '';
    FLineBuf := '';
    client := TFPHTTPClient.Create(nil);
    sink := TSSESink.Create(Self);
    try
      client.AllowRedirect := True;
      client.IOTimeout := 60000;
      client.AddHeader('Accept', 'text/event-stream');
      client.AddHeader('User-Agent', 'tiespace-tui/0.1 (+cyberspace personal client)');
      FConnected := True;
      try
        client.HTTPMethod('GET', FUrl, sink, []);
      except
        on E: Exception do
          ;
      end;
    finally
      sink.Free;
      client.Free;
    end;
    FConnected := False;
    if Terminated or FGaveUp then
      Break;
    if FGotData then
      failures := 0
    else
      Inc(failures);
    if failures >= 6 then
    begin
      FGaveUp := True;
      Break;
    end;
    SleepInterruptible(3000);
  end;
end;

{ ---- TChatStreamThread ---- }

constructor TChatStreamThread.Create(const AUrl: string);
begin
  inherited Create(AUrl); // suspended
  InitCriticalSection(FLock);
  Start;
end;

destructor TChatStreamThread.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TChatStreamThread.PushOp(const op: TSSEOp);
begin
  EnterCriticalSection(FLock);
  try
    SetLength(FOps, Length(FOps) + 1);
    FOps[High(FOps)] := op;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TChatStreamThread.DrainOps(out ops: TSSEOpArray);
begin
  EnterCriticalSection(FLock);
  try
    ops := FOps;
    FOps := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TChatStreamThread.UpsertMsg(const id: string; obj: TJSONObject);
var
  op: TSSEOp;
begin
  op.Msg := ParseChatMessage(obj);
  if op.Msg.Id = '' then
    op.Msg.Id := id;
  op.Kind := opUpsert;
  op.Id := id;
  PushOp(op);
end;

procedure TChatStreamThread.ApplyPut(const path: string; dn: TJSONData);
var
  i: Integer;
  id: string;
  o: TJSONObject;
  op: TSSEOp;
begin
  if path = '/' then
  begin
    if not (dn is TJSONObject) then
      Exit;
    o := TJSONObject(dn);
    for i := 0 to o.Count - 1 do
      if o.Items[i] is TJSONObject then
        UpsertMsg(o.Names[i], TJSONObject(o.Items[i]));
  end
  else
  begin
    id := StripPath(path);
    if id = '' then
      Exit;
    if (dn = nil) or (dn.JSONType = jtNull) then
    begin
      op.Kind := opRemove;
      op.Id := id;
      PushOp(op);
    end
    else if dn is TJSONObject then
      UpsertMsg(id, TJSONObject(dn));
  end;
end;

procedure TChatStreamThread.ApplyPatch(const path: string; dn: TJSONData);
var
  id: string;
  o: TJSONObject;
  op: TSSEOp;
begin
  id := StripPath(path);
  if (id = '') or (not (dn is TJSONObject)) then
    Exit;
  o := TJSONObject(dn);
  if o.Get('deleted', False) or (o.Get('content', '') = '[DELETED]') then
  begin
    op.Kind := opMarkDeleted;
    op.Id := id;
    PushOp(op);
  end;
end;

procedure TChatStreamThread.OnEvent(const evType, path: string; data: TJSONData);
begin
  if evType = 'put' then
    ApplyPut(path, data)
  else if evType = 'patch' then
    ApplyPatch(path, data);
end;

{ ---- TPresenceThread ---- }

constructor TPresenceThread.Create(const AUrl: string);
begin
  inherited Create(AUrl);
  InitCriticalSection(FLock);
  Start;
end;

destructor TPresenceThread.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TPresenceThread.IndexOf(const uid: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(FMap) do
    if FMap[i].UserId = uid then
      Exit(i);
end;

procedure TPresenceThread.UpsertP(const uid: string; obj: TJSONObject);
var
  k: Integer;
  ld: TJSONData;
begin
  EnterCriticalSection(FLock);
  try
    k := IndexOf(uid);
    if k < 0 then
    begin
      SetLength(FMap, Length(FMap) + 1);
      k := High(FMap);
      FMap[k].UserId := uid;
    end;
    // Merge only fields that are present (patches are partial).
    if obj.Find('username') <> nil then
      FMap[k].Username := obj.Get('username', FMap[k].Username);
    if obj.Find('isChatAdmin') <> nil then
      FMap[k].IsChatAdmin := obj.Get('isChatAdmin', FMap[k].IsChatAdmin);
    if obj.Find('online') <> nil then
      FMap[k].Online := obj.Get('online', FMap[k].Online);
    if obj.Find('typing') <> nil then
      FMap[k].Typing := obj.Get('typing', FMap[k].Typing);
    if obj.Find('lastSeen') <> nil then
      FMap[k].LastSeen := obj.Get('lastSeen', FMap[k].LastSeen);
    if obj.Find('timestamp') <> nil then
      FMap[k].LastSeen := obj.Get('timestamp', FMap[k].LastSeen);
    ld := obj.Find('lastActivity');
    if ld <> nil then
      if ld.JSONType = jtNumber then
        FMap[k].LastActivity := ld.AsInt64
      else
        FMap[k].LastActivity := 0; // null/unknown -> treat as active
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TPresenceThread.RemoveP(const uid: string);
var
  k: Integer;
begin
  EnterCriticalSection(FLock);
  try
    k := IndexOf(uid);
    if k >= 0 then
    begin
      for k := k to High(FMap) - 1 do
        FMap[k] := FMap[k + 1];
      SetLength(FMap, Length(FMap) - 1);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TPresenceThread.OnEvent(const evType, path: string; data: TJSONData);
var
  i: Integer;
  o: TJSONObject;
  id: string;
begin
  if (evType <> 'put') and (evType <> 'patch') then
    Exit;
  if path = '/' then
  begin
    EnterCriticalSection(FLock);
    try
      SetLength(FMap, 0);
    finally
      LeaveCriticalSection(FLock);
    end;
    if data is TJSONObject then
    begin
      o := TJSONObject(data);
      for i := 0 to o.Count - 1 do
        if o.Items[i] is TJSONObject then
          UpsertP(o.Names[i], TJSONObject(o.Items[i]));
    end;
  end
  else
  begin
    id := StripPath(path);
    if id = '' then
      Exit;
    if (data = nil) or (data.JSONType = jtNull) then
      RemoveP(id)
    else if data is TJSONObject then
      UpsertP(id, TJSONObject(data));
  end;
end;

procedure TPresenceThread.GetOnlineUsers(out users: TOnlineArray; staleAfterMs, idleAfterMs: Int64);
var
  i, j: Integer;
  nowm, cutoff, idleCut: Int64;
  tmp: TOnlineUser;
begin
  SetLength(users, 0);
  nowm := NowMs;
  cutoff := nowm - staleAfterMs;
  idleCut := nowm - idleAfterMs;
  EnterCriticalSection(FLock);
  try
    for i := 0 to High(FMap) do
      if FMap[i].Online and (FMap[i].LastSeen >= cutoff) and (FMap[i].Username <> '') then
      begin
        SetLength(users, Length(users) + 1);
        users[High(users)].Name := FMap[i].Username;
        users[High(users)].Idle :=
          (FMap[i].LastActivity > 0) and (FMap[i].LastActivity < idleCut);
      end;
  finally
    LeaveCriticalSection(FLock);
  end;
  // sort case-insensitively by name (small n)
  for i := 1 to High(users) do
  begin
    tmp := users[i];
    j := i - 1;
    while (j >= 0) and (LowerCase(users[j].Name) > LowerCase(tmp.Name)) do
    begin
      users[j + 1] := users[j];
      Dec(j);
    end;
    users[j + 1] := tmp;
  end;
end;

procedure TPresenceThread.GetTyping(out names: TNameArray; staleAfterMs: Int64;
  const exclude: string);
var
  i: Integer;
  cutoff: Int64;
begin
  SetLength(names, 0);
  cutoff := NowMs - staleAfterMs;
  EnterCriticalSection(FLock);
  try
    for i := 0 to High(FMap) do
      if FMap[i].Typing and (FMap[i].LastSeen >= cutoff) and
         (FMap[i].Username <> '') and (FMap[i].Username <> exclude) then
      begin
        SetLength(names, Length(names) + 1);
        names[High(names)] := FMap[i].Username;
      end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
