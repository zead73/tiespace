unit CsHttp;

(* Transport layer for the Cyberspace API.

   Wraps TFPHTTPClient: attaches the Bearer token, sends/receives JSON, and
   maps the uniform "data" / "error" (code, message) response envelope to
   Pascal results. HTTPS is provided by the opensslsockets unit, which
   registers an OpenSSL-backed TLS handler for TFPHTTPClient.

   Ownership: the TJSONObject returned by every request method is owned by the
   caller and must be freed. Errors (transport, HTTP >= 300, or an "error"
   envelope) are raised as ECsApi. *)

{$mode objfpc}{$H+}{$J-}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, fphttpclient, opensslsockets;

type
  ECsApi = class(Exception)
  public
    Code: string;        // e.g. VALIDATION_ERROR, RATE_LIMITED, NETWORK
    HttpStatus: Integer; // HTTP status, or 0 for a transport-level failure
    constructor CreateApi(AStatus: Integer; const ACode, AMsg: string);
  end;

  TCsClient = class
  private
    FBaseUrl: string;
    FToken: string;
    FUserAgent: string;
    function Request(const AMethod, APath: string; ABody: TJSONData;
      ANeedAuth: Boolean): TJSONObject;
  public
    constructor Create(const ABaseUrl: string);
    { All return the parsed envelope object (caller frees) or raise ECsApi. }
    function GetJSONObj(const APath: string): TJSONObject;
    function PostJSONObj(const APath: string; ABody: TJSONData): TJSONObject;
    function PatchJSONObj(const APath: string; ABody: TJSONData): TJSONObject;
    function DeleteJSONObj(const APath: string): TJSONObject;
    property Token: string read FToken write FToken;
    property BaseUrl: string read FBaseUrl;
    property UserAgent: string read FUserAgent write FUserAgent;
  end;

{ Returns the "data" object inside an envelope, or the envelope itself if there
  is no "data" object. Ownership is unchanged -- the result is a borrowed
  reference into AEnvelope, which the caller still owns and frees. }
function CsData(AEnvelope: TJSONObject): TJSONObject;

implementation

function CsData(AEnvelope: TJSONObject): TJSONObject;
var
  d: TJSONData;
begin
  Result := AEnvelope;
  if AEnvelope = nil then
    Exit;
  d := AEnvelope.Find('data');
  if (d <> nil) and (d is TJSONObject) then
    Result := TJSONObject(d);
end;

constructor ECsApi.CreateApi(AStatus: Integer; const ACode, AMsg: string);
begin
  inherited Create(AMsg);
  Code := ACode;
  HttpStatus := AStatus;
end;

constructor TCsClient.Create(const ABaseUrl: string);
begin
  inherited Create;
  FBaseUrl := ABaseUrl;
  FUserAgent := 'tiespace-tui/0.1 (+cyberspace personal client)';
end;

function TCsClient.Request(const AMethod, APath: string; ABody: TJSONData;
  ANeedAuth: Boolean): TJSONObject;
var
  http: TFPHTTPClient;
  respStream, reqStream: TStringStream;
  status: Integer;
  bodyText, url, code, msg: string;
  parsed, errNode: TJSONData;
begin
  Result := nil;
  url := FBaseUrl + APath;
  http := TFPHTTPClient.Create(nil);
  respStream := TStringStream.Create('');
  reqStream := nil;
  try
    http.AddHeader('User-Agent', FUserAgent);
    http.AddHeader('Accept', 'application/json');
    if ANeedAuth and (FToken <> '') then
      http.AddHeader('Authorization', 'Bearer ' + FToken);
    if ABody <> nil then
    begin
      http.AddHeader('Content-Type', 'application/json');
      reqStream := TStringStream.Create(ABody.AsJSON);
      reqStream.Position := 0;
      http.RequestBody := reqStream;
    end;

    try
      { An empty allowed-codes list means "accept any status" -> no exception
        is raised for 4xx/5xx; we inspect ResponseStatusCode ourselves. }
      http.HTTPMethod(AMethod, url, respStream, []);
    except
      on E: Exception do
        raise ECsApi.CreateApi(0, 'NETWORK', 'Network error: ' + E.Message);
    end;

    status := http.ResponseStatusCode;
    bodyText := respStream.DataString;

    if Trim(bodyText) = '' then
    begin
      if (status >= 200) and (status < 300) then
        Exit(TJSONObject.Create)
      else
        raise ECsApi.CreateApi(status, 'HTTP_' + IntToStr(status),
          'Empty response (HTTP ' + IntToStr(status) + ')');
    end;

    try
      parsed := GetJSON(bodyText);
    except
      on E: Exception do
        raise ECsApi.CreateApi(status, 'BAD_JSON',
          'Unparseable response (HTTP ' + IntToStr(status) + '): ' +
          Copy(bodyText, 1, 200));
    end;

    if not (parsed is TJSONObject) then
    begin
      parsed.Free;
      raise ECsApi.CreateApi(status, 'BAD_JSON', 'Response was not a JSON object');
    end;

    errNode := TJSONObject(parsed).Find('error');
    if (errNode <> nil) and (errNode is TJSONObject) then
    begin
      code := TJSONObject(errNode).Get('code', 'UNKNOWN');
      msg := TJSONObject(errNode).Get('message', 'Request failed');
      parsed.Free;
      raise ECsApi.CreateApi(status, code, msg);
    end;

    if (status < 200) or (status >= 300) then
    begin
      parsed.Free;
      raise ECsApi.CreateApi(status, 'HTTP_' + IntToStr(status),
        'HTTP ' + IntToStr(status));
    end;

    Result := TJSONObject(parsed);
  finally
    respStream.Free;
    reqStream.Free;
    http.Free;
  end;
end;

function TCsClient.GetJSONObj(const APath: string): TJSONObject;
begin
  Result := Request('GET', APath, nil, True);
end;

function TCsClient.PostJSONObj(const APath: string; ABody: TJSONData): TJSONObject;
begin
  Result := Request('POST', APath, ABody, True);
end;

function TCsClient.PatchJSONObj(const APath: string; ABody: TJSONData): TJSONObject;
begin
  Result := Request('PATCH', APath, ABody, True);
end;

function TCsClient.DeleteJSONObj(const APath: string): TJSONObject;
begin
  Result := Request('DELETE', APath, nil, True);
end;

end.
