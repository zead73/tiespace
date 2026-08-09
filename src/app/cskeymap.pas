unit CsKeyMap;

(* Remappable feed keybindings, stored locally (~/.config/tiespace/keys).

   Only the feed's single-char "launcher" keys are remappable; navigation
   (j/k/arrows/g/G/Home/End/Enter/q/?) stays fixed. The feed passes its input
   through TranslateKey, which rewrites a pressed key to the *default* key of the
   action it's currently bound to — so the feed's own `case key of Ord('g')…`
   never changes. With no overrides, TranslateKey is the identity. *)

{$mode objfpc}{$H+}

interface

type
  TKeyAction = (kaGuilds, kaTopics, kaBookmark, kaBookmarksList, kaNotes,
    kaWatches, kaSettings, kaNotifs, kaCirc, kaMail, kaProfile, kaSearch,
    kaCompose, kaDelete, kaReload, kaStopAudio);

function ActionCount: Integer;
function ActionLabel(a: TKeyAction): string;
function DefaultKey(a: TKeyAction): Char;
function CurrentKey(a: TKeyAction): Char;      // the override, or the default
{ Keys reserved for navigation — a launcher can't be rebound onto these. }
function IsReserved(c: Char): Boolean;
{ Rewrite a raw feed keypress: a bound key -> its action's default key; a moved
  action's old default -> -2 (no-op); anything else is passed through. }
function TranslateKey(k: LongInt): LongInt;
{ Rebind an action to a printable, non-reserved key (swaps if it's taken); saves. }
procedure Rebind(a: TKeyAction; c: Char);
procedure ResetAction(a: TKeyAction);         // back to default; saves
procedure ResetAll;                           // clear all overrides; saves
procedure LoadKeymap;                          // read overrides from config

implementation

uses
  SysUtils, Classes, CsConfig;

const
  DEFAULTS: array[TKeyAction] of Char =
    ('g', 't', 'b', 'B', 'N', 'W', 'S', 'n', 'C', 'M', 'p', '/', 'c', 'd', 'r', 'o');
  LABELS: array[TKeyAction] of string =
    ('Guilds', 'Topics', 'Bookmark entry', 'Bookmarks list', 'Notes',
     'Watched threads', 'Settings', 'Notifications', 'cIRC chat', 'C-Mail',
     'Author profile', 'Search', 'New entry', 'Delete own entry', 'Reload feed',
     'Play / stop audio');
  IDS: array[TKeyAction] of string =
    ('guilds', 'topics', 'bookmark', 'bookmarks_list', 'notes', 'watches',
     'settings', 'notifs', 'circ', 'mail', 'profile', 'search', 'compose',
     'delete', 'reload', 'stop_audio');
  KEYS_FILE = 'keys';

var
  GOverride: array[TKeyAction] of Char; // #0 => use the default (zero-init)

function ActionCount: Integer;
begin
  Result := Ord(High(TKeyAction)) + 1;
end;

function ActionLabel(a: TKeyAction): string;
begin
  Result := LABELS[a];
end;

function DefaultKey(a: TKeyAction): Char;
begin
  Result := DEFAULTS[a];
end;

function CurrentKey(a: TKeyAction): Char;
begin
  if GOverride[a] <> #0 then
    Result := GOverride[a]
  else
    Result := DEFAULTS[a];
end;

function IsReserved(c: Char): Boolean;
begin
  Result := c in ['j', 'k', 'G', 'q', 'Q', '?'];
end;

function TranslateKey(k: LongInt): LongInt;
var
  a: TKeyAction;
  c: Char;
begin
  Result := k;
  if (k < 32) or (k > 126) then
    Exit; // non-printable (nav/function keys) pass through untouched
  c := Chr(k);
  for a := Low(TKeyAction) to High(TKeyAction) do
    if CurrentKey(a) = c then
      Exit(Ord(DefaultKey(a)));      // a's current key -> a's default (its case branch)
  for a := Low(TKeyAction) to High(TKeyAction) do
    if DefaultKey(a) = c then
      Exit(-2);                      // a default whose action moved away -> no-op
end;

procedure SaveKeymap;
var
  sl: TStringList;
  a: TKeyAction;
begin
  sl := TStringList.Create;
  try
    for a := Low(TKeyAction) to High(TKeyAction) do
      if GOverride[a] <> #0 then
        sl.Add(IDS[a] + '=' + GOverride[a]);
    WriteSecretFile(ConfigPath(KEYS_FILE), sl.Text);
  finally
    sl.Free;
  end;
end;

procedure SetOverride(a: TKeyAction; c: Char);
begin
  if c = DEFAULTS[a] then
    GOverride[a] := #0 // back to default: no override needed
  else
    GOverride[a] := c;
end;

procedure Rebind(a: TKeyAction; c: Char);
var
  b, other: TKeyAction;
  found: Boolean;
  oldKey: Char;
begin
  if (c < ' ') or (Ord(c) > 126) or IsReserved(c) then
    Exit;
  oldKey := CurrentKey(a);
  if oldKey = c then
    Exit;
  // If another action holds c, hand it a's old key (a swap keeps both bound).
  found := False;
  other := a;
  for b := Low(TKeyAction) to High(TKeyAction) do
    if (b <> a) and (CurrentKey(b) = c) then
    begin
      other := b;
      found := True;
      Break;
    end;
  SetOverride(a, c);
  if found then
    SetOverride(other, oldKey);
  SaveKeymap;
end;

procedure ResetAction(a: TKeyAction);
begin
  GOverride[a] := #0;
  SaveKeymap;
end;

procedure ResetAll;
var
  a: TKeyAction;
begin
  for a := Low(TKeyAction) to High(TKeyAction) do
    GOverride[a] := #0;
  SaveKeymap;
end;

function ActionById(const id: string; out a: TKeyAction): Boolean;
var
  x: TKeyAction;
begin
  Result := False;
  for x := Low(TKeyAction) to High(TKeyAction) do
    if IDS[x] = id then
    begin
      a := x;
      Exit(True);
    end;
end;

procedure LoadKeymap;
var
  sl: TStringList;
  raw, id, val: string;
  i, p: Integer;
  a: TKeyAction;
  c: Char;
begin
  for a := Low(TKeyAction) to High(TKeyAction) do
    GOverride[a] := #0;
  if not ReadFileIfExists(ConfigPath(KEYS_FILE), raw) then
    Exit;
  sl := TStringList.Create;
  try
    sl.Text := raw;
    for i := 0 to sl.Count - 1 do
    begin
      p := Pos('=', sl[i]);
      if p < 2 then
        Continue;
      id := Trim(Copy(sl[i], 1, p - 1));
      val := Copy(sl[i], p + 1, MaxInt);
      if Length(val) < 1 then
        Continue;
      c := val[1];
      if (c >= ' ') and (Ord(c) <= 126) and (not IsReserved(c)) and ActionById(id, a) then
        SetOverride(a, c);
    end;
  finally
    sl.Free;
  end;
end;

end.
