program spike_login;

(* M0 transport spike for the tiespace client.

   Goal: prove the whole transport path end-to-end against the live API before
   any UI exists -- TLS (OpenSSL 3) handshake, JSON round-trip, and the
   "data" / "error" response envelope.

   Step 1 needs no credentials: POST /v1/auth/check-username is a public
   endpoint, so it exercises HTTPS + JSON on its own.

  Step 2 is optional and only runs if CS_EMAIL and CS_PASSWORD are set in the
  environment; it logs in and fetches /v1/users/me. Passwords are never read
  from argv or written anywhere -- the real login UI (M1) will prompt with echo
  disabled. To try it:

      read -rs -p 'password: ' CS_PASSWORD; export CS_PASSWORD
      CS_EMAIL=you@example.com ./bin/spike_login *)

{$mode objfpc}{$H+}

uses
  SysUtils, fpjson, CsHttp;

const
  BASE = 'https://api.cyberspace.online';

procedure TestCheckUsername(c: TCsClient);
var
  body, resp: TJSONObject;
begin
  WriteLn('--- check-username (no auth) ---');
  body := TJSONObject.Create;
  try
    { A random name so we don't depend on a specific account existing. }
    body.Add('username', 'tiespace_probe_' + FormatDateTime('hhnnsszzz', Now));
    resp := c.PostJSONObj('/v1/auth/check-username', body);
    try
      WriteLn('  HTTP round-trip OK. response: ', resp.AsJSON);
    finally
      resp.Free;
    end;
  finally
    body.Free;
  end;
end;

procedure TestLogin(c: TCsClient);
var
  email, pass, idTok: string;
  body, resp, me: TJSONObject;
  data: TJSONObject;
begin
  email := GetEnvironmentVariable('CS_EMAIL');
  pass := GetEnvironmentVariable('CS_PASSWORD');
  if (email = '') or (pass = '') then
  begin
    WriteLn('--- login: skipped (set CS_EMAIL and CS_PASSWORD to test) ---');
    Exit;
  end;

  WriteLn('--- login + /users/me ---');
  body := TJSONObject.Create;
  try
    body.Add('email', email);
    body.Add('password', pass);
    resp := c.PostJSONObj('/v1/auth/login', body);
    try
      data := resp.Objects['data'];
      idTok := data.Get('idToken', '');
      c.Token := idTok;
      WriteLn('  login OK. idToken length=', Length(idTok),
        '  rtdbUrl=', data.Get('rtdbUrl', ''));
    finally
      resp.Free;
    end;
  finally
    body.Free;
  end;

  me := c.GetJSONObj('/v1/users/me');
  try
    WriteLn('  /users/me: ', me.AsJSON);
  finally
    me.Free;
  end;
end;

var
  c: TCsClient;
begin
  c := TCsClient.Create(BASE);
  try
    try
      TestCheckUsername(c);
      TestLogin(c);
      WriteLn('DONE.');
    except
      on E: ECsApi do
        WriteLn(StdErr, 'API ERROR [', E.Code, ' / HTTP ', E.HttpStatus, ']: ',
          E.Message);
      on E: Exception do
        WriteLn(StdErr, 'ERROR [', E.ClassName, ']: ', E.Message);
    end;
  finally
    c.Free;
  end;
end.
