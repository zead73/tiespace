unit CsSession;

(* Authentication session: login, token refresh, and persistence.

   Login returns a short-lived idToken (~1h, the Bearer token) and a long-lived
   refreshToken. We persist only the refreshToken (plus rtdbUrl and identity) to
   a 0600 file, so a later run restores the session by refreshing rather than
   asking for the password again. Per the API, /v1/auth/refresh returns a new
   idToken but NOT a new refreshToken, so the stored one stays valid until
   revoked. *)

{$mode objfpc}{$H+}

interface

uses
  fpjson, CsHttp;

type
  TCsSession = class
  private
    FClient: TCsClient;
    FIdToken: string;
    FRefreshToken: string;
    FRtdbUrl: string;
    FUsername: string;
    FUserId: string;
    FFilterNSFW: Boolean; // read-side pref, loaded from /v1/settings
    procedure IdentifyFromMe;
    procedure PersistSession;
  public
    constructor Create(const ABaseUrl: string);
    destructor Destroy; override;
    { Log in with credentials; persists the refresh token on success. }
    function Login(const AEmail, APassword: string): Boolean;
    { Exchange the stored refresh token for a fresh idToken. }
    function Refresh: Boolean;
    { Restore a persisted session and refresh it. True if a usable session came back. }
    function LoadPersisted: Boolean;
    { Clear tokens and remove the persisted session file. }
    procedure Logout;
    { GET /v1/users/me -- caller frees the returned envelope. }
    function FetchMe: TJSONObject;
    property Client: TCsClient read FClient;
    property IdToken: string read FIdToken;
    property RefreshToken: string read FRefreshToken;
    property RtdbUrl: string read FRtdbUrl;
    property Username: string read FUsername;
    property UserId: string read FUserId;
    { Whether to filter/mask NSFW content in read views. Loaded from settings at
      feed start and updated when the settings screen saves it. }
    property FilterNSFW: Boolean read FFilterNSFW write FFilterNSFW;
  end;

implementation

uses
  SysUtils, CsConfig;

const
  SESSION_FILE = 'session.json';

constructor TCsSession.Create(const ABaseUrl: string);
begin
  inherited Create;
  FClient := TCsClient.Create(ABaseUrl);
end;

destructor TCsSession.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

procedure TCsSession.IdentifyFromMe;
var
  me: TJSONObject;
  d: TJSONObject;
begin
  me := FClient.GetJSONObj('/v1/users/me');
  try
    d := CsData(me);
    FUsername := d.Get('username', FUsername);
    // Field name for the id isn't pinned in the docs; try the common ones.
    FUserId := d.Get('userId', d.Get('uid', d.Get('id', FUserId)));
  finally
    me.Free;
  end;
end;

procedure TCsSession.PersistSession;
var
  o: TJSONObject;
begin
  o := TJSONObject.Create;
  try
    o.Add('refreshToken', FRefreshToken);
    o.Add('rtdbUrl', FRtdbUrl);
    o.Add('username', FUsername);
    o.Add('userId', FUserId);
    WriteSecretFile(ConfigPath(SESSION_FILE), o.FormatJSON);
  finally
    o.Free;
  end;
end;

function TCsSession.Login(const AEmail, APassword: string): Boolean;
var
  body, resp, d: TJSONObject;
begin
  body := TJSONObject.Create;
  try
    body.Add('email', AEmail);
    body.Add('password', APassword);
    resp := FClient.PostJSONObj('/v1/auth/login', body);
    try
      d := CsData(resp);
      FIdToken := d.Get('idToken', '');
      FRefreshToken := d.Get('refreshToken', '');
      FRtdbUrl := d.Get('rtdbUrl', '');
      FClient.Token := FIdToken;
    finally
      resp.Free;
    end;
  finally
    body.Free;
  end;

  Result := FIdToken <> '';
  if Result then
  begin
    IdentifyFromMe;
    PersistSession;
  end;
end;

function TCsSession.Refresh: Boolean;
var
  body, resp, d: TJSONObject;
begin
  Result := False;
  if FRefreshToken = '' then
    Exit;
  body := TJSONObject.Create;
  try
    body.Add('refreshToken', FRefreshToken);
    resp := FClient.PostJSONObj('/v1/auth/refresh', body);
    try
      d := CsData(resp);
      FIdToken := d.Get('idToken', '');
      FRtdbUrl := d.Get('rtdbUrl', FRtdbUrl);
      FClient.Token := FIdToken;
    finally
      resp.Free;
    end;
  finally
    body.Free;
  end;
  Result := FIdToken <> '';
end;

function TCsSession.LoadPersisted: Boolean;
var
  raw: string;
  data: TJSONData;
  o: TJSONObject;
begin
  Result := False;
  if not ReadFileIfExists(ConfigPath(SESSION_FILE), raw) then
    Exit;
  if Trim(raw) = '' then
    Exit;
  data := GetJSON(raw);
  try
    if not (data is TJSONObject) then
      Exit;
    o := TJSONObject(data);
    FRefreshToken := o.Get('refreshToken', '');
    FRtdbUrl := o.Get('rtdbUrl', '');
    FUsername := o.Get('username', '');
    FUserId := o.Get('userId', '');
  finally
    data.Free;
  end;
  if FRefreshToken = '' then
    Exit;
  Result := Refresh;
end;

procedure TCsSession.Logout;
begin
  FIdToken := '';
  FRefreshToken := '';
  FClient.Token := '';
  if FileExists(ConfigPath(SESSION_FILE)) then
    DeleteFile(ConfigPath(SESSION_FILE));
end;

function TCsSession.FetchMe: TJSONObject;
begin
  Result := FClient.GetJSONObj('/v1/users/me');
end;

end.
