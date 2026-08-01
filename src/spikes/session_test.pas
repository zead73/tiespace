program session_test;

(* M1 foundation harness: exercises the config + session + refresh layer against
   the live API.

   First run -- log in and persist the refresh token:

       read -rs -p 'password: ' CS_PASSWORD; export CS_PASSWORD; echo
       CS_EMAIL=you@example.com ./bin/session_test

   Second run -- no env needed; it restores the saved session, refreshes the
   idToken, and fetches your profile:

       ./bin/session_test

   The saved session lives at ~/.config/tiespace/session.json (mode 0600). *)

{$mode objfpc}{$H+}

uses
  SysUtils, fpjson, CsHttp, CsConfig, CsSession;

const
  BASE = 'https://api.cyberspace.online';

var
  s: TCsSession;
  email, pass: string;
  me: TJSONObject;
begin
  s := TCsSession.Create(BASE);
  try
    try
      if s.LoadPersisted then
        WriteLn('Restored saved session and refreshed. user=', s.Username,
          '  idToken len=', Length(s.IdToken))
      else
      begin
        email := GetEnvironmentVariable('CS_EMAIL');
        pass := GetEnvironmentVariable('CS_PASSWORD');
        if (email = '') or (pass = '') then
        begin
          WriteLn('No saved session, and CS_EMAIL/CS_PASSWORD not set -- nothing to do.');
          Halt(0);
        end;
        if s.Login(email, pass) then
          WriteLn('Login OK. user=', s.Username, '  uid=', s.UserId,
            '  idToken len=', Length(s.IdToken), '  rtdbUrl=', s.RtdbUrl)
        else
          WriteLn('Login returned no idToken.');
      end;

      WriteLn('Re-refreshing idToken to prove the refresh path...');
      if s.Refresh then
        WriteLn('  refresh OK. idToken len=', Length(s.IdToken))
      else
        WriteLn('  refresh failed (no refresh token?).');

      me := s.FetchMe;
      try
        WriteLn('/users/me: ', me.AsJSON);
      finally
        me.Free;
      end;

      WriteLn('Session file: ', ConfigPath('session.json'));
      WriteLn('DONE.');
    except
      on E: ECsApi do
        WriteLn(StdErr, 'API ERROR [', E.Code, ' / HTTP ', E.HttpStatus, ']: ', E.Message);
      on E: Exception do
        WriteLn(StdErr, 'ERROR [', E.ClassName, ']: ', E.Message);
    end;
  finally
    s.Free;
  end;
end.
