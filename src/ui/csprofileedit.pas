unit CsProfileEdit;

(* Edit the signed-in user's profile via PATCH /v1/users/me: display name, bio,
   website (url + name), location name, and the map coordinates that place you on
   the Cyberspace globe. Fields are pre-filled with their current value where the
   API exposes it — the coordinates are write-only (GET /v1/users/me never returns
   them), so those are entered fresh. Esc leaves a field unchanged; clearing a
   field sends null, which removes it. Only changed fields are sent. The write is
   rate-limited (2/min, 15/day) to match the API. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

{ Returns True if a change was saved (so the caller can refresh its view). }
function EditOwnProfile(sess: TCsSession): Boolean;

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsUI, CsModels, CsRateLimit, CsCompose;

const
  MAX_BIO  = 640;
  MAX_NAME = 64;   // displayName, websiteName, locationName
  MAX_URL  = 2048;

type
  TCoordAction = (caKeep, caSet, caClear);

procedure ShowMsg(const s: string);
begin
  UICursorVisible(False);
  DrawBar(ScreenRows - 1, cpStatus, ' ' + s + '   (press any key)');
  UIRefresh;
  UIGetKey;
end;

procedure DrawTitle(const username: string);
begin
  UIErase;
  DrawBar(0, cpHeader, ' edit profile   ·   @' + username);
  DrawText(2, 1, cpMeta, 'Esc leaves a field unchanged. Clear a field to remove it.');
  UIRefresh;
end;

{ Single-line prompt pre-filled with `preset`; Esc keeps `preset`; the result is
  trimmed and held to `maxLen` codepoints (re-prompting if too long). `value` must
  be a different variable from `preset` (an out param is cleared before the call). }
procedure PromptField(const prompt, preset: string; maxLen: Integer; out value: string);
var
  seed: string;
begin
  seed := preset;
  repeat
    if not UIPromptLine(prompt, value, seed) then
    begin
      value := preset;   // Esc: unchanged
      Exit;
    end;
    value := Trim(value);
    if CodepointCount(value) <= maxLen then
      Exit;
    ShowMsg('Too long (max ' + IntToStr(maxLen) + ' characters).');
    seed := value;       // keep what they typed so they can trim it
  until False;
end;

function EditOwnProfile(sess: TCsSession): Boolean;
var
  me, d, body, env: TJSONObject;
  oDisplay, oBio, oUrl, oWname, oLoc: string;
  nDisplay, nBio, nUrl, nWname, nLoc, urlSeed, msg: string;
  coordAct: TCoordAction;
  lat, lon: Double;
  review: TTextLines;
  i: Integer;
  key: LongInt;
  confirmed: Boolean;

  procedure AddChange(const s: string);
  begin
    SetLength(review, Length(review) + 1);
    review[High(review)] := s;
  end;

  { Add a text field to the body only if it changed; an emptied field is sent as
    null (which removes it server-side). }
  procedure DiffText(const fkey, orig, neu: string);
  begin
    if neu = orig then
      Exit;
    if neu = '' then
    begin
      body.Add(fkey, TJSONNull.Create);
      AddChange('  ' + fkey + ': (cleared)');
    end
    else
    begin
      body.Add(fkey, neu);
      AddChange('  ' + fkey + ': ' + neu);
    end;
  end;

  { Ask whether to set / clear / leave the globe coordinates. On set, prompts for
    latitude then longitude (into the outer lat/lon), validated and ranged. }
  function AskCoords: TCoordAction;
  var
    k: LongInt;
    s, seed: string;
  begin
    DrawBar(ScreenRows - 1, cpStatus,
      ' Globe pin (current lat/long not readable): [e] set  [c] remove  [Enter] leave');
    UIRefresh;
    repeat
      k := UIGetKey;
      case k of
        Ord('e'), Ord('E'):
          begin
            seed := '';
            repeat
              if not UIPromptLine('Latitude (-90..90, decimal point; Esc cancels):', s, seed) then
                Exit(caKeep);
              if ParseCoord(s, -90, 90, lat) then
                Break;
              ShowMsg('Latitude must be a number between -90 and 90.');
              seed := Trim(s);
            until False;
            seed := '';
            repeat
              if not UIPromptLine('Longitude (-180..180, decimal point; Esc cancels):', s, seed) then
                Exit(caKeep);
              if ParseCoord(s, -180, 180, lon) then
                Break;
              ShowMsg('Longitude must be a number between -180 and 180.');
              seed := Trim(s);
            until False;
            Exit(caSet);
          end;
        Ord('c'), Ord('C'):
          Exit(caClear);
        10, 13, KEY_ENTER, 27:
          Exit(caKeep);
      end;
    until False;
  end;

begin
  Result := False;

  // Load current values (coordinates are write-only, so they're not among these).
  oDisplay := ''; oBio := ''; oUrl := ''; oWname := ''; oLoc := '';
  try
    me := sess.FetchMe;
    try
      d := CsData(me);
      oDisplay := DecodeEntities(d.Get('displayName', ''));
      oBio := DecodeEntities(d.Get('bio', ''));
      oUrl := d.Get('websiteUrl', '');
      oWname := DecodeEntities(d.Get('websiteName', ''));
      oLoc := DecodeEntities(d.Get('locationName', ''));
    finally
      me.Free;
    end;
  except
    on E: ECsApi do begin ShowMsg('[' + E.Code + '] ' + E.Message); Exit; end;
    on E: Exception do begin ShowMsg(E.Message); Exit; end;
  end;

  DrawTitle(sess.Username);

  // Single-line fields (out var always distinct from the preset).
  PromptField('Display name (max 64):', oDisplay, MAX_NAME, nDisplay);

  urlSeed := oUrl;
  repeat
    PromptField('Website URL (http/https, max 2048):', urlSeed, MAX_URL, nUrl);
    if (nUrl = '') or (Pos('http://', LowerCase(nUrl)) = 1) or
       (Pos('https://', LowerCase(nUrl)) = 1) then
      Break;
    ShowMsg('Website URL must start with http:// or https://');
    urlSeed := nUrl;
  until False;

  PromptField('Website name (max 64):', oWname, MAX_NAME, nWname);
  PromptField('Location name (max 64):', oLoc, MAX_NAME, nLoc);

  // Bio — full-screen multi-line editor, pre-filled with the current bio.
  nBio := oBio;
  repeat
    if not EditValue('edit bio', ' Ctrl+G: done     Esc: keep current', nBio) then
      nBio := oBio; // Esc: keep current
    if CodepointCount(nBio) <= MAX_BIO then
      Break;
    ShowMsg('Bio too long (max 640 characters).'); // re-opens with the long text
  until False;

  DrawTitle(sess.Username);
  coordAct := AskCoords;

  body := TJSONObject.Create;
  SetLength(review, 0);
  try
    DiffText('displayName', oDisplay, nDisplay);
    DiffText('bio', oBio, nBio);
    DiffText('websiteUrl', oUrl, nUrl);
    DiffText('websiteName', oWname, nWname);
    DiffText('locationName', oLoc, nLoc);
    case coordAct of
      caSet:
        begin
          body.Add('locationLatitude', lat);
          body.Add('locationLongitude', lon);
          AddChange(Format('  globe pin: %.5f, %.5f', [lat, lon]));
        end;
      caClear:
        begin
          body.Add('locationLatitude', TJSONNull.Create);
          body.Add('locationLongitude', TJSONNull.Create);
          AddChange('  globe pin: (removed)');
        end;
    end;

    if body.Count = 0 then
    begin
      ShowMsg('No changes.');
      Exit;
    end;

    // Review the change set and confirm.
    UICursorVisible(False);
    UIErase;
    DrawBar(0, cpHeader, ' review profile changes');
    for i := 0 to High(review) do
      if (1 + i) < ScreenRows - 1 then
        DrawText(1 + i, 1, cpText, review[i]);
    DrawBar(ScreenRows - 1, cpStatus, ' Save these changes?    [y] save    [n] cancel');
    UIRefresh;
    confirmed := False;
    repeat
      key := UIGetKey;
      case key of
        Ord('y'), Ord('Y'): begin confirmed := True; Break; end;
        Ord('n'), Ord('N'), 27: Break;
      end;
    until False;
    if not confirmed then
      Exit;

    if not Limiter.Check('profile', msg) then
    begin
      ShowMsg(msg);
      Exit;
    end;
    try
      env := sess.Client.PatchJSONObj('/v1/users/me', body);
      env.Free;
      Limiter.Note('profile');
      ShowMsg('Profile saved. ✓');
      Result := True;
    except
      on E: ECsApi do ShowMsg('[' + E.Code + '] ' + E.Message);
      on E: Exception do ShowMsg(E.Message);
    end;
  finally
    body.Free;
  end;
end;

end.
