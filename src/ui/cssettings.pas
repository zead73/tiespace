unit CsSettings;

(* Account settings: a checklist of on/off preferences you toggle locally and
   then save in one PATCH (the write limit is a stingy 2/min, so we don't save
   per-toggle). Covers the documented top-level booleans plus whatever per-type
   notification switches the server returns (read dynamically). Only the fields
   you change are sent, so the settings this screen doesn't model — keyboard
   bindings, themes, topic lists — are left untouched. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunSettings(sess: TCsSession);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsUI, CsRateLimit;

type
  TSetKind = (skBool, skNotif);
  TSetItem = record
    Key: string;      // JSON key (top-level) or notifications sub-key
    Caption: string;
    Kind: TSetKind;
    Value: Boolean;
    Dirty: Boolean;
  end;
  TSetItems = array of TSetItem;
  TBoolDef = record Key, Caption: string; end;

const
  BOOLS: array[0..6] of TBoolDef = (
    (Key: 'filterNSFW';         Caption: 'Filter NSFW posts'),
    (Key: 'autoWatchOnReply';   Caption: 'Auto-watch threads I reply to'),
    (Key: 'defaultPublicPost';  Caption: 'New posts default to public'),
    (Key: 'showFollowerCount';  Caption: 'Show my follower count'),
    (Key: 'hideImagesInFeed';   Caption: 'Hide images in the feed'),
    (Key: 'hideAudioInFeed';    Caption: 'Hide audio in the feed'),
    (Key: 'useLegacyMenuOrder'; Caption: 'Use legacy menu order')
  );

function NotifLabel(const k: string): string;
begin
  Result := 'Notify: ' + StringReplace(k, '_', ' ', [rfReplaceAll]);
end;

procedure RunSettings(sess: TCsSession);
var
  items: TSetItems;
  err, flash: string;
  flashErr: Boolean;
  sel, top, visible, key: Integer;

  procedure AddItem(const k, cap: string; kind: TSetKind; val: Boolean);
  begin
    SetLength(items, Length(items) + 1);
    items[High(items)].Key := k;
    items[High(items)].Caption := cap;
    items[High(items)].Kind := kind;
    items[High(items)].Value := val;
    items[High(items)].Dirty := False;
  end;

  procedure Load;
  var
    env, d, notif: TJSONObject;
    nd: TJSONData;
    i: Integer;
  begin
    SetLength(items, 0);
    err := '';
    try
      env := sess.Client.GetJSONObj('/v1/settings');
      try
        d := CsData(env);
        for i := 0 to High(BOOLS) do
          AddItem(BOOLS[i].Key, BOOLS[i].Caption, skBool, d.Get(BOOLS[i].Key, False));
        nd := d.Find('notifications');
        if nd is TJSONObject then
        begin
          notif := TJSONObject(nd);
          for i := 0 to notif.Count - 1 do
            if notif.Items[i].JSONType = jtBoolean then
              AddItem(notif.Names[i], NotifLabel(notif.Names[i]), skNotif,
                notif.Items[i].AsBoolean);
        end;
      finally
        env.Free;
      end;
    except
      on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
      on E: Exception do err := E.Message;
    end;
    sel := 0;
    top := 0;
  end;

  function DirtyCount: Integer;
  var
    i: Integer;
  begin
    Result := 0;
    for i := 0 to High(items) do
      if items[i].Dirty then
        Inc(Result);
  end;

  procedure ToggleSel;
  begin
    if (sel < 0) or (sel > High(items)) then
      Exit;
    items[sel].Value := not items[sel].Value;
    items[sel].Dirty := not items[sel].Dirty; // back to loaded value clears dirty
  end;

  { Save all changes in one PATCH. Notifications go out in full (every switch we
    loaded) so we're safe whether the server merges or replaces the object. }
  procedure Save;
  var
    body, notif, env: TJSONObject;
    i: Integer;
    notifDirty: Boolean;
    msg: string;
  begin
    if DirtyCount = 0 then
    begin
      flash := 'No changes to save.';
      flashErr := True;
      Exit;
    end;
    if not Limiter.Check('settings', msg) then
    begin
      flash := msg;
      flashErr := True;
      Exit;
    end;
    notifDirty := False;
    for i := 0 to High(items) do
      if (items[i].Kind = skNotif) and items[i].Dirty then
        notifDirty := True;
    body := TJSONObject.Create;
    try
      for i := 0 to High(items) do
        if (items[i].Kind = skBool) and items[i].Dirty then
          body.Add(items[i].Key, items[i].Value);
      if notifDirty then
      begin
        notif := TJSONObject.Create;
        for i := 0 to High(items) do
          if items[i].Kind = skNotif then
            notif.Add(items[i].Key, items[i].Value);
        body.Add('notifications', notif);
      end;
      try
        env := sess.Client.PatchJSONObj('/v1/settings', body);
        env.Free;
        Limiter.Note('settings');
        for i := 0 to High(items) do
          items[i].Dirty := False;
        flash := 'Saved. ✓';
        flashErr := False;
      except
        on E: ECsApi do begin flash := '[' + E.Code + '] ' + E.Message; flashErr := True; end;
        on E: Exception do begin flash := E.Message; flashErr := True; end;
      end;
    finally
      body.Free;
    end;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    row, box: string;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(items) then
      sel := High(items);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   settings   ·   @' + sess.Username);
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(items) then
      begin
        if items[idx].Value then
          box := '[x] '
        else
          box := '[ ] ';
        row := box + items[idx].Caption;
        if items[idx].Dirty then
          row := row + '  *';
        if idx = sel then
        begin
          DrawBar(1 + i, cpSelect, '');
          DrawText(1 + i, 0, cpSelect, '›');
          DrawText(1 + i, 2, cpSelect, PadOrTrunc(row, ScreenCols - 3));
        end
        else
          DrawText(1 + i, 2, cpText, row);
      end;
    end;
    if flash <> '' then
    begin
      if flashErr then
        DrawBar(ScreenRows - 1, cpError, ' ' + flash + '    (q back)')
      else
        DrawBar(ScreenRows - 1, cpAccent, ' ' + flash);
    end
    else if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q back)')
    else if Length(items) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no settings · r reload · q back')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d · %d unsaved   ·   Space toggle · s save · r reload · q back',
        [sel + 1, Length(items), DirtyCount]));
    UIRefresh;
  end;

begin
  err := '';
  flash := '';
  flashErr := False;
  Load;
  repeat
    Redraw;
    key := UIGetKey;
    flash := ''; // one-shot: clear on the next key
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        if DirtyCount = 0 then
          Break
        else if UIConfirm('Discard ' + IntToStr(DirtyCount) + ' unsaved change(s)?') then
          Break;
      Ord('j'), KEY_DOWN:
        if sel < High(items) then
          Inc(sel);
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + visible;
          if sel > High(items) then
            sel := High(items);
        end;
      KEY_PPAGE:
        sel := sel - visible;
      Ord('g'):
        sel := 0;
      Ord('G'):
        sel := High(items);
      Ord(' '), 10, 13, KEY_ENTER:
        ToggleSel;
      Ord('s'):
        Save;
      Ord('r'):
        begin
          err := '';
          Load;
        end;
    end;
  until False;
end;

end.
