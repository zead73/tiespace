unit CsPlayer;

(* Background audio playback. Shells out to mpv (which uses yt-dlp) to stream an
   attachment's URL — audio only, and with --no-terminal so it never touches our
   stdin/stdout/stderr and can't disturb the ncurses UI. The URL is passed as a
   direct argument (no shell), so there's no injection risk from post content.

   One track at a time: playing a new one replaces the current. mpv is killed on
   stop and on program exit. Requires mpv + yt-dlp on PATH. *)

{$mode objfpc}{$H+}

interface

{ Start playing url in the background, stopping any current track. `trackLabel`
  is kept for a "now playing" display. Returns False if mpv couldn't launch. }
function PlayAudio(const url, trackLabel: string): Boolean;
{ Stop the current track, if any. }
procedure StopAudio;
{ Is something playing? (Also reaps mpv if it finished on its own.) }
function IsPlaying: Boolean;
{ Label of the current track, or '' if nothing is playing. }
function NowPlaying: string;
{ URL of the current track, or '' — lets a caller toggle play/stop per item. }
function PlayingUrl: string;

implementation

uses
  SysUtils, Process;

var
  GProc: TProcess = nil;
  GLabel: string = '';
  GUrl: string = '';

{ Drop the process handle once mpv has exited on its own (track ended). }
procedure Reap;
begin
  if (GProc <> nil) and (not GProc.Running) then
  begin
    FreeAndNil(GProc);
    GLabel := '';
    GUrl := '';
  end;
end;

procedure StopAudio;
begin
  if GProc <> nil then
  begin
    try
      if GProc.Running then
        GProc.Terminate(0);
    except
      // ignore: process may have already exited
    end;
    FreeAndNil(GProc);
  end;
  GLabel := '';
  GUrl := '';
end;

function PlayAudio(const url, trackLabel: string): Boolean;
begin
  Result := False;
  StopAudio; // one at a time
  if Trim(url) = '' then
    Exit;
  GProc := TProcess.Create(nil);
  try
    GProc.Executable := 'mpv';
    GProc.Parameters.Add('--no-video');
    GProc.Parameters.Add('--no-terminal'); // no stdin/stdout/stderr use
    GProc.Parameters.Add('--really-quiet');
    GProc.Parameters.Add('--'); // end options; url is never treated as a flag
    GProc.Parameters.Add(url);
    GProc.Options := []; // launch and return; do not wait
    GProc.Execute;
    GLabel := trackLabel;
    GUrl := url;
    Result := True;
  except
    on E: Exception do
    begin
      FreeAndNil(GProc); // mpv not on PATH, etc.
      GLabel := '';
      GUrl := '';
    end;
  end;
end;

function IsPlaying: Boolean;
begin
  Reap;
  Result := (GProc <> nil) and GProc.Running;
end;

function NowPlaying: string;
begin
  if IsPlaying then
    Result := GLabel
  else
    Result := '';
end;

function PlayingUrl: string;
begin
  if IsPlaying then
    Result := GUrl
  else
    Result := '';
end;

initialization

finalization
  StopAudio; // don't leave mpv playing after the client exits
end.
