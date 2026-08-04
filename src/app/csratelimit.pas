unit CsRateLimit;

(* A courtesy client-side rate limiter mirroring the API's documented write
   limits, so the client declines and explains rather than firing a request
   that would come back 429. The server remains the source of truth; this only
   catches the obvious cases within a session.

   Per-minute windows are exact. The per-day count is per session run (it starts
   fresh each launch) -- good enough to stop accidental floods; the server
   enforces the real daily cap. *)

{$mode objfpc}{$H+}

interface

type
  TRateLimiter = class
  private
    FTimes: array of record
      Action: string;
      Ts: TDateTime;
    end;
    procedure Prune;
    function CountSince(const action: string; secs: Integer): Integer;
    function RuleFor(const action: string; out perMin, perDay: Integer): Boolean;
  public
    { True if an action of this kind is allowed right now; else False with msg. }
    function Check(const action: string; out msg: string): Boolean;
    { Record a successful action so it counts toward the windows. }
    procedure Note(const action: string);
  end;

function Limiter: TRateLimiter;

implementation

uses
  SysUtils, DateUtils;

var
  GLimiter: TRateLimiter = nil;

function Limiter: TRateLimiter;
begin
  if GLimiter = nil then
    GLimiter := TRateLimiter.Create;
  Result := GLimiter;
end;

function TRateLimiter.RuleFor(const action: string; out perMin, perDay: Integer): Boolean;
begin
  Result := True;
  perMin := 0;
  perDay := 0;
  case action of
    'entry': begin perMin := 2; perDay := 15; end;
    'reply': begin perMin := 3; perDay := 15; end;
    'bookmark': begin perMin := 5; perDay := 75; end;
    'follow': begin perMin := 3; perDay := 15; end;
    'note': begin perMin := 3; perDay := 30; end;
    'chat': begin perMin := 15; perDay := 300; end;
    'chat_delete': begin perMin := 5; perDay := 30; end;
    'cmail': begin perMin := 15; perDay := 300; end;
    'cmail_start': begin perMin := 5; perDay := 50; end;
    'guild_thread': begin perMin := 2; perDay := 15; end;
    'guild_join': begin perMin := 3; perDay := 15; end;
    'guild_leave': begin perMin := 3; perDay := 15; end;
    'watch': begin perMin := 10; perDay := 100; end;
  else
    Result := False; // no known rule -> unlimited client-side
  end;
end;

procedure TRateLimiter.Prune;
var
  i, n: Integer;
begin
  n := 0;
  for i := 0 to High(FTimes) do
    if SecondsBetween(Now, FTimes[i].Ts) <= 86400 then
    begin
      FTimes[n] := FTimes[i];
      Inc(n);
    end;
  SetLength(FTimes, n);
end;

function TRateLimiter.CountSince(const action: string; secs: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FTimes) do
    if (FTimes[i].Action = action) and (SecondsBetween(Now, FTimes[i].Ts) <= secs) then
      Inc(Result);
end;

function TRateLimiter.Check(const action: string; out msg: string): Boolean;
var
  perMin, perDay: Integer;
begin
  msg := '';
  Result := True;
  Prune;
  if not RuleFor(action, perMin, perDay) then
    Exit;
  if (perMin > 0) and (CountSince(action, 60) >= perMin) then
  begin
    msg := Format('Slow down: the %s limit is %d/min. Give it a moment.', [action, perMin]);
    Exit(False);
  end;
  if (perDay > 0) and (CountSince(action, 86400) >= perDay) then
  begin
    msg := Format('Daily %s limit reached (%d/day).', [action, perDay]);
    Exit(False);
  end;
end;

procedure TRateLimiter.Note(const action: string);
begin
  SetLength(FTimes, Length(FTimes) + 1);
  FTimes[High(FTimes)].Action := action;
  FTimes[High(FTimes)].Ts := Now;
end;

initialization

finalization
  FreeAndNil(GLimiter);
end.
