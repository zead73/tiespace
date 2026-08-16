unit CsOpen;

(* Open a web link in the user's default browser via xdg-open, fire-and-forget.

   The URL is validated to be http(s) and passed as a direct argument (no shell),
   so post content can neither inject a command nor trigger a non-web handler
   (file://, mailto:, …). xdg-open hands off to a GUI browser and exits, so it
   never touches the ncurses UI. Requires xdg-open on PATH. *)

{$mode objfpc}{$H+}

interface

{ Launch url in the default browser. False if it isn't an http(s) URL or
  xdg-open couldn't be started. }
function OpenUrl(const url: string): Boolean;

implementation

uses
  SysUtils, Process;

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
  proc := TProcess.Create(nil);
  try
    proc.Executable := 'xdg-open';
    proc.Parameters.Add(u); // single arg, no shell -> no injection
    proc.Options := [];      // launch and return; don't wait
    try
      proc.Execute;
      Result := True;
    except
      on E: Exception do
        Result := False; // xdg-open not on PATH, etc.
    end;
  finally
    proc.Free; // xdg-open exits immediately after handing off to the browser
  end;
end;

end.
