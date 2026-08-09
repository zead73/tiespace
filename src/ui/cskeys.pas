unit CsKeys;

(* Keybindings editor — rebind the feed's launcher keys (see CsKeyMap). Reached
   from the Settings screen. Changes save immediately (local file), and the feed
   picks them up live via TranslateKey. Navigation keys are fixed and can't be
   rebound; the editor rejects reserved and non-printable keys. *)

{$mode objfpc}{$H+}

interface

procedure RunKeybindings;

implementation

uses
  SysUtils, ncurses, CsUI, CsKeyMap;

procedure RunKeybindings;
var
  sel, top, visible, key, n: Integer;
  flash: string;

  procedure DoRebind(a: TKeyAction);
  var
    k: LongInt;
    c: Char;
  begin
    DrawBar(ScreenRows - 1, cpStatus,
      ' Press the new key for "' + ActionLabel(a) + '"   ·   Esc cancels');
    UIRefresh;
    k := UIGetKey;
    if k = 27 then
    begin
      flash := 'Cancelled.';
      Exit;
    end;
    if (k < 32) or (k > 126) then
    begin
      flash := 'Not a printable key — pick a letter or symbol.';
      Exit;
    end;
    c := Chr(k);
    if IsReserved(c) then
    begin
      flash := '"' + c + '" is reserved for navigation — pick another.';
      Exit;
    end;
    Rebind(a, c);
    flash := ActionLabel(a) + '  →  ' + c;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    a: TKeyAction;
    kc: string;
  begin
    visible := ScreenRows - 3;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > n - 1 then
      sel := n - 1;
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   keybindings   ·   feed launcher keys');
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx > n - 1 then
        Break;
      a := TKeyAction(idx);
      kc := CurrentKey(a);
      if idx = sel then
      begin
        DrawBar(1 + i, cpSelect, '');
        DrawText(1 + i, 0, cpSelect, '›');
        DrawText(1 + i, 2, cpSelect, PadOrTrunc(ActionLabel(a), 22) + '  ' + kc);
        if CurrentKey(a) <> DefaultKey(a) then
          DrawText(1 + i, 30, cpSelect, '(default ' + DefaultKey(a) + ')');
      end
      else
      begin
        DrawText(1 + i, 2, cpAccent, PadOrTrunc(ActionLabel(a), 22), True);
        DrawText(1 + i, 26, cpText, kc);
        if CurrentKey(a) <> DefaultKey(a) then
          DrawText(1 + i, 30, cpMeta, '(default ' + DefaultKey(a) + ')');
      end;
    end;
    if flash <> '' then
      DrawBar(ScreenRows - 1, cpAccent, ' ' + flash)
    else
      DrawBar(ScreenRows - 1, cpStatus,
        ' Enter rebind · d default · R reset all · j/k move · q back');
    UIRefresh;
  end;

begin
  n := ActionCount;
  sel := 0;
  top := 0;
  flash := '';
  repeat
    Redraw;
    key := UIGetKey;
    flash := ''; // one-shot: clear on the next key
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < n - 1 then
          Inc(sel);
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      Ord('g'), KEY_HOME:
        sel := 0;
      Ord('G'), KEY_END:
        sel := n - 1;
      Ord(' '), 10, 13, KEY_ENTER:
        DoRebind(TKeyAction(sel));
      Ord('d'):
        begin
          ResetAction(TKeyAction(sel));
          flash := ActionLabel(TKeyAction(sel)) + ' reset to default.';
        end;
      Ord('R'):
        begin
          ResetAll;
          flash := 'All feed keys reset to defaults.';
        end;
    end;
  until False;
end;

end.
