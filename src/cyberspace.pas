program cyberspace;

(* tiespace -- a human-driven TUI client for the Cyberspace API.

   Startup restores the persisted session (refreshes the idToken). If there is
   no usable session, the login screen is shown. From the feed, `Q` logs out and
   returns here to the login screen; `q` quits. *)

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, CsHttp, CsConfig, CsSession, CsUI, CsLogin, CsFeed;

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
