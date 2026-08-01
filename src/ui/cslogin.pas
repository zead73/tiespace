unit CsLogin;

(* In-TUI login screen.

   Accessibility: if ~/.cs-pw exists, its contents are used as the password
   automatically, so the user never has to type or paste it -- they only supply
   an email (remembered across logins in ~/.config/tiespace/last-email and
   pre-filled next time) and press Enter. The password field is still there for
   anyone who wants to type; a typed value overrides the file. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

{ Returns True once logged in, False if the user quit (Esc). initialErr, if
  set, is shown as the starting status (e.g. why a session restore failed). }
function RunLogin(sess: TCsSession; const initialErr: string = ''): Boolean;

implementation

uses
  SysUtils, ncurses, CsHttp, CsUI, CsConfig;

const
  PW_FILE = '.cs-pw';
  LAST_EMAIL_FILE = 'last-email';

function LoadPwFile(out pw: string): Boolean;
var
  raw: string;
begin
  pw := '';
  Result := ReadRawFile(HomeDir + PW_FILE, raw);
  if not Result then
    Exit;
  while (Length(raw) > 0) and (raw[Length(raw)] in [#10, #13]) do
    SetLength(raw, Length(raw) - 1);
  pw := raw;
  Result := pw <> '';
end;

function LoadLastEmail: string;
var
  s: string;
begin
  if ReadFileIfExists(ConfigPath(LAST_EMAIL_FILE), s) then
    Result := Trim(s)
  else
    Result := '';
end;

procedure SaveLastEmail(const email: string);
begin
  WriteSecretFile(ConfigPath(LAST_EMAIL_FILE), email);
end;

function RunLogin(sess: TCsSession; const initialErr: string): Boolean;
var
  email, typedPw, pwFile, err, pwToUse: string;
  hasPwFile: Boolean;
  field: Integer; // 0 = email, 1 = password
  key: LongInt;

  procedure Redraw;
  var
    x, y, pwPair: Integer;
    emailShown, pwShown, pwDisplay: string;
  begin
    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   log in');
    x := 4;
    y := (ScreenRows div 2) - 3;
    if y < 2 then
      y := 2;

    DrawText(y, x, cpAccent, 'Log in to Cyberspace', True);

    emailShown := email;
    if field = 0 then
      emailShown := emailShown + '▏';
    DrawText(y + 2, x, cpText, 'Email:');
    DrawText(y + 2, x + 11, cpText, emailShown);

    if typedPw <> '' then
    begin
      pwDisplay := StringOfChar('*', Length(typedPw));
      pwPair := cpText;
    end
    else if hasPwFile then
    begin
      pwDisplay := '(from ~/.cs-pw)';
      pwPair := cpMeta;
    end
    else
    begin
      pwDisplay := '';
      pwPair := cpText;
    end;
    pwShown := pwDisplay;
    if field = 1 then
      pwShown := pwShown + '▏';
    DrawText(y + 3, x, cpText, 'Password:');
    DrawText(y + 3, x + 11, pwPair, pwShown);

    DrawText(y + 5, x, cpMeta, 'Enter: log in      Tab: switch field      Esc: quit');
    if hasPwFile then
      DrawText(y + 6, x, cpMeta,
        'Password comes from ~/.cs-pw — leave the field blank to use it.');

    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err)
    else
      DrawBar(ScreenRows - 1, cpStatus, ' ');
    UIRefresh;
  end;

begin
  Result := False;
  email := LoadLastEmail;
  typedPw := '';
  hasPwFile := LoadPwFile(pwFile);
  err := initialErr;
  field := 0;

  repeat
    Redraw;
    key := UIGetKey;
    case key of
      27:
        Exit(False);
      9:
        field := 1 - field;
      10, 13, KEY_ENTER:
        begin
          if Trim(email) = '' then
            err := 'Enter your email.'
          else
          begin
            if typedPw <> '' then
              pwToUse := typedPw
            else if hasPwFile then
              pwToUse := pwFile
            else
              pwToUse := '';
            if pwToUse = '' then
              err := 'No password: type one, or create ~/.cs-pw.'
            else
            begin
              DrawBar(ScreenRows - 1, cpStatus, ' Logging in…');
              UIRefresh;
              try
                if sess.Login(Trim(email), pwToUse) then
                begin
                  SaveLastEmail(Trim(email));
                  Exit(True);
                end
                else
                  err := 'Login failed (no token returned).';
              except
                on E: ECsApi do
                  err := '[' + E.Code + '] ' + E.Message;
                on E: Exception do
                  err := E.Message;
              end;
            end;
          end;
        end;
      KEY_BACKSPACE, 127, 8:
        if field = 0 then
        begin
          if email <> '' then
            SetLength(email, Length(email) - 1);
        end
        else
        begin
          if typedPw <> '' then
            SetLength(typedPw, Length(typedPw) - 1);
        end;
    else
      if (key >= 32) and (key < 127) then
      begin
        if field = 0 then
          email := email + Chr(key)
        else
          typedPw := typedPw + Chr(key);
      end;
    end;
  until False;
end;

end.
