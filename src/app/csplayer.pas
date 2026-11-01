unit CsPlayer;

(* Background audio playback. Runs `yt-dlp -o - <url> | mpv -`: yt-dlp fetches
   the stream and mpv plays it from stdin. We pipe rather than let mpv fetch the
   URL itself because YouTube now 403s a direct mpv/ffmpeg fetch of a resolved
   stream (anti-bot), while yt-dlp's own downloader still works; routing through
   yt-dlp also covers direct-file (e.g. latex-origin MP3) attachments.

   The pipeline runs in a new session (setsid) so stopping can signal the whole
   process group — yt-dlp *and* mpv — not just the shell. mpv keeps --no-terminal
   and both legs redirect stderr to /dev/null, so nothing can disturb the ncurses
   UI. The URL is a positional arg ($1), never interpolated, so a post can't
   inject shell. One track at a time; the group is killed on stop and on exit.
   Requires setsid, yt-dlp and mpv on PATH. *)

{$mode objfpc}{$H+}

interface

{ Start playing url in the background, stopping any current track. `trackLabel`
  is kept for a "now playing" display. Returns False if the pipeline couldn't
  launch. }
function PlayAudio(const url, trackLabel: string): Boolean;
{ Stop the current track, if any. }
procedure StopAudio;
{ Is something playing? (Also reaps the pipeline if it finished on its own.) }
function IsPlaying: Boolean;
{ Label of the current track, or '' if nothing is playing. }
function NowPlaying: string;
{ URL of the current track, or '' — lets a caller toggle play/stop per item. }
function PlayingUrl: string;

implementation

uses
  SysUtils, Process, BaseUnix;

var
  GProc: TProcess = nil;
  GLabel: string = '';
  GUrl: string = '';

{ Drop the process handle once the pipeline has exited on its own (track ended). }
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
        // Negative pid signals the whole process group. setsid made the shell a
        // session/group leader whose PGID equals its pid (GProc.ProcessID), so
        // this reaches yt-dlp and mpv too — not just the shell.
        fpKill(-GProc.ProcessID, SIGTERM);
    except
      // ignore: process may have already exited
    end;
    FreeAndNil(GProc);
  end;
  GLabel := '';
  GUrl := '';
end;

const
  // yt-dlp fetches ($1 is the URL, never interpolated); mpv plays stdin. Both
  // legs silence stderr so nothing leaks into the ncurses UI. --no-playlist
  // keeps a "&list=" URL from pulling a whole radio queue; bestaudio/best falls
  // back to a plain file (e.g. a direct MP3) when there's no audio-only format.
  PIPELINE =
    'yt-dlp -q --no-playlist -f bestaudio/best -o - -- "$1" 2>/dev/null | ' +
    'mpv --no-video --no-terminal --really-quiet - 2>/dev/null';

function PlayAudio(const url, trackLabel: string): Boolean;
begin
  Result := False;
  StopAudio; // one at a time
  if Trim(url) = '' then
    Exit;
  GProc := TProcess.Create(nil);
  try
    // setsid: run the pipeline in a new session so StopAudio can kill the whole
    // group. The reported pid is the shell's, which (not being a group leader
    // when launched) setsid turns into the session leader in place, so its pid
    // is the group's pid.
    GProc.Executable := 'setsid';
    GProc.Parameters.Add('sh');
    GProc.Parameters.Add('-c');
    GProc.Parameters.Add(PIPELINE);
    GProc.Parameters.Add('sh');  // $0
    GProc.Parameters.Add(url);   // $1 — the stream URL, passed safely
    GProc.Options := []; // launch and return; do not wait
    GProc.Execute;
    GLabel := trackLabel;
    GUrl := url;
    Result := True;
  except
    on E: Exception do
    begin
      FreeAndNil(GProc); // setsid/sh/yt-dlp/mpv not on PATH, etc.
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
