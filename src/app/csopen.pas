unit CsOpen;

(* Open a web link in the user's default browser via xdg-open, fire-and-forget.

   Browsers print to stderr when they hand a URL to an already-running instance
   (e.g. "Opening in existing browser session."), and xdg-open plus the browser
   it spawns inherit our terminal — that output would corrupt the ncurses display.
   So we launch through `sh -c` purely to redirect stdout+stderr to /dev/null;
   the URL is a positional argument ($1), never spliced into the script text, so
   there is no shell-injection risk, and it's validated to be http(s) first so no
   foreign scheme (file://, mailto:, …) is handed to the desktop opener.

   xdg-open hands off to a GUI browser and exits, so nothing touches the UI.
   Requires xdg-open on PATH. *)

{$mode objfpc}{$H+}

interface

{ Launch url in the default browser. False if it isn't an http(s) URL, or
  xdg-open isn't on PATH, or the launcher couldn't start. }
function OpenUrl(const url: string): Boolean;

implementation

uses
  SysUtils, Process;

{ Is exe found in a PATH directory? (Best-effort: existence, not the exec bit.) }
function OnPath(const exe: string): Boolean;
var
  path, dir: string;
  p: Integer;
begin
  Result := False;
  path := GetEnvironmentVariable('PATH');
  while path <> '' do
  begin
    p := Pos(':', path);
    if p = 0 then
    begin
      dir := path;
      path := '';
    end
    else
    begin
      dir := Copy(path, 1, p - 1);
      Delete(path, 1, p);
    end;
    if (dir <> '') and FileExists(IncludeTrailingPathDelimiter(dir) + exe) then
      Exit(True);
  end;
end;

function OpenUrl(const url: string): Boolean;
var
  proc: TProcess;
  u, lower: string;
begin
  Result := False;
  u := Trim(url);
  lower := LowerCase(u);
  if (Pos('http://', lower) <> 1) and (Pos('https://', lower) <> 1) then
    Exit; // web links only; never hand a foreign scheme to the desktop opener
  if not OnPath('xdg-open') then
    Exit;
  proc := TProcess.Create(nil);
  try
    proc.Executable := 'sh';
    proc.Parameters.Add('-c');
    // $1 is the URL (data, not script) -> no injection; redirect silences the
    // browser so its stderr can't land in the ncurses display.
    proc.Parameters.Add('exec xdg-open "$1" >/dev/null 2>&1');
    proc.Parameters.Add('sh'); // $0
    proc.Parameters.Add(u);    // $1
    proc.Options := [];        // launch and return; don't wait
    try
      proc.Execute;
      Result := True;
    except
      on E: Exception do
        Result := False;
    end;
  finally
    proc.Free; // sh execs xdg-open, which exits after handing off to the browser
  end;
end;

end.
