program tiespace;

(* tiespace -- a human-driven TUI client for the Cyberspace API.

   Startup restores the persisted session (refreshes the idToken). If there is
   no usable session, the login screen is shown. From the feed, `Q` logs out and
   returns here to the login screen; `q` quits. *)

{$mode objfpc}{$H+}

uses
  // cwstring: install the libc widestring manager so DefaultSystemCodePage is
  // UTF-8 (65001), not 0. Without it, fpjson's parser re-encodes parsed strings
  // via the system codepage, so every non-ASCII char in an API response (CJK,
  // emoji, curly quotes) came back mangled to '?'. Sending was fine (AsJSON just
  // concatenates bytes); this only bit the receive path.
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  SysUtils, CsHttp, CsConfig, CsSession, CsUI, CsLogin, CsFeed, CsKeyMap;

const
  BASE = 'https://api.cyberspace.online';

var
  sess: TCsSession;
  loggedIn: Boolean;
  startupErr: string;
begin
  sess := TCsSession.Create(BASE);
  try
    startupErr := '';
    loggedIn := False;
    try
      loggedIn := sess.LoadPersisted;
    except
      on E: ECsApi do
        startupErr := '[' + E.Code + '] ' + E.Message;
      on E: Exception do
        startupErr := E.Message;
    end;

    SetTheme(ThemeIndexByName(LoadThemeName)); // -1 (no saved theme) -> default
    LoadKeymap; // apply any local feed-keybinding overrides
    UIInit;
    try
      repeat
        if not loggedIn then
          loggedIn := RunLogin(sess, startupErr);
        startupErr := '';
        if not loggedIn then
          Break; // user quit the login screen

        if RunFeed(sess) then
        begin
          sess.Logout;    // log out -> back to the login screen
          loggedIn := False;
        end
        else
          Break;          // quit the app
      until False;
    finally
      UIShutdown;
    end;
  finally
    sess.Free;
  end;
end.
