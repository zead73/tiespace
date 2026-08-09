unit CsConfig;

(* Config/state paths and file helpers for tiespace.

   Everything lives under $XDG_CONFIG_HOME/tiespace (falling back to
   ~/.config/tiespace). The directory is created 0700 and secret files (the
   persisted refresh token) are written 0600 so the credential never sits
   world-readable. *)

{$mode objfpc}{$H+}

interface

function ConfigDir: string;                       // ensures the dir exists (0700), trailing slash
function ConfigPath(const AName: string): string; // ConfigDir + AName
function HomeDir: string;                          // $HOME with trailing slash
procedure WriteSecretFile(const APath, AContents: string);          // 0600
function ReadFileIfExists(const APath: string; out AContents: string): Boolean;
{ Read a file's exact bytes (no line-ending normalisation) -- used for the
  password file, where a stray trailing newline would corrupt the password. }
function ReadRawFile(const APath: string; out AData: string): Boolean;

{ Local UI preference: the chosen colour-theme name ('' if none saved). }
function LoadThemeName: string;
procedure SaveThemeName(const AName: string);

implementation

uses
  SysUtils, Classes, BaseUnix;

function XdgConfigHome: string;
begin
  Result := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.config';
end;

function ConfigDir: string;
var
  dir: string;
begin
  dir := IncludeTrailingPathDelimiter(XdgConfigHome) + 'tiespace';
  if not DirectoryExists(dir) then
  begin
    ForceDirectories(dir);
    fpChmod(PChar(dir), S_IRWXU); // 0700
  end;
  Result := IncludeTrailingPathDelimiter(dir);
end;

function ConfigPath(const AName: string): string;
begin
  Result := ConfigDir + AName;
end;

function HomeDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME'));
end;

procedure WriteSecretFile(const APath, AContents: string);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmCreate);
  try
    // Tighten perms before the secret hits the file.
    fpChmod(PChar(APath), S_IRUSR or S_IWUSR); // 0600
    if AContents <> '' then
      fs.WriteBuffer(AContents[1], Length(AContents));
  finally
    fs.Free;
  end;
end;

function ReadFileIfExists(const APath: string; out AContents: string): Boolean;
var
  sl: TStringList;
begin
  AContents := '';
  Result := FileExists(APath);
  if not Result then
    Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(APath);
    AContents := sl.Text;
  finally
    sl.Free;
  end;
end;

function ReadRawFile(const APath: string; out AData: string): Boolean;
var
  fs: TFileStream;
begin
  AData := '';
  Result := FileExists(APath);
  if not Result then
    Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(AData, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(AData[1], fs.Size);
  finally
    fs.Free;
  end;
end;

const
  THEME_FILE = 'theme';

function LoadThemeName: string;
var
  s: string;
begin
  Result := '';
  if ReadFileIfExists(ConfigPath(THEME_FILE), s) then
    Result := Trim(s);
end;

procedure SaveThemeName(const AName: string);
begin
  WriteSecretFile(ConfigPath(THEME_FILE), AName); // 0600 is harmless for a pref
end;

end.
