unit CsNotes;

(* Notes: private, personal notes — nobody else can see them. Editing a note
   creates a new revision rather than overwriting, so the history is kept.

   RunNotes          — the note list (latest revision of each). Enter reads one.
   RunNoteView       — read a note; e edit (new revision), v revisions, d delete.
   RunNoteRevisions  — the revision history; Enter views a past revision read-only.

   The composer (multi-line UTF-8 editor, review, rate-limit) is reused for
   writing and editing via CsCompose.ComposeNote / EditNote. *)

{$mode objfpc}{$H+}

interface

uses
  CsSession;

procedure RunNotes(sess: TCsSession);

implementation

uses
  SysUtils, fpjson, ncurses, CsHttp, CsModels, CsUI, CsApi, CsCompose;

const
  PAGE = 20;

procedure Push(var arr: TTextLines; const s: string);
begin
  SetLength(arr, Length(arr) + 1);
  arr[High(arr)] := s;
end;

{ First non-empty line of a note, for a list row. }
function FirstLine(const s: string): string;
var
  i, p: Integer;
  line: string;
begin
  i := 1;
  while i <= Length(s) do
  begin
    p := i;
    while (p <= Length(s)) and (s[p] <> #10) and (s[p] <> #13) do
      Inc(p);
    line := Trim(Copy(s, i, p - i));
    if line <> '' then
      Exit(line);
    i := p + 1;
  end;
  Result := '(empty note)';
end;

{ Topics as "#a #b" for display; as "a b" for handing back to the composer. }
function TopicsHashes(const topics: array of string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(topics) do
    if topics[i] <> '' then
    begin
      if Result <> '' then
        Result := Result + ' ';
      Result := Result + '#' + topics[i];
    end;
end;

function TopicsPlain(const topics: array of string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(topics) do
    if topics[i] <> '' then
    begin
      if Result <> '' then
        Result := Result + ' ';
      Result := Result + topics[i];
    end;
end;

function FetchNotesPage(sess: TCsSession; const cursor: string;
  out nextCursor, err: string): TNoteArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/notes?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseNoteArray(TJSONArray(d));
      nextCursor := env.Get('cursor', '');
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

function FetchRevisions(sess: TCsSession; const id, cursor: string;
  out nextCursor, err: string): TNoteArray;
var
  env: TJSONObject;
  d: TJSONData;
  path: string;
begin
  SetLength(Result, 0);
  nextCursor := '';
  err := '';
  path := '/v1/notes/' + id + '/revisions?limit=' + IntToStr(PAGE);
  if cursor <> '' then
    path := path + '&cursor=' + cursor;
  try
    env := sess.Client.GetJSONObj(path);
    try
      d := env.Find('data');
      if (d <> nil) and (d is TJSONArray) then
        Result := ParseNoteArray(TJSONArray(d));
      nextCursor := env.Get('cursor', '');
    finally
      env.Free;
    end;
  except
    on E: ECsApi do err := '[' + E.Code + '] ' + E.Message;
    on E: Exception do err := E.Message;
  end;
end;

{ The scrollable body for reading a note: a topics line (if any), a meta line,
  a rule, then the wrapped content. Width-fitted to the current terminal. }
function NoteBodyLines(const n: TNote): TTextLines;
var
  textW, i: Integer;
  th: string;
  cw: TTextLines;
begin
  SetLength(Result, 0);
  textW := ScreenCols - 2;
  if textW < 8 then
    textW := 8;
  th := TopicsHashes(n.Topics);
  if th <> '' then
    Push(Result, th);
  Push(Result, Format('revision %d · created %s · updated %s',
    [n.Revision, Copy(n.CreatedAt, 1, 10), RelativeTime(n.UpdatedAt)]));
  Push(Result, HLine(textW));
  cw := WrapText(n.Content, textW);
  for i := 0 to High(cw) do
    Push(Result, cw[i]);
end;

{ A read-only pager over pre-wrapped lines. }
procedure PageLines(const headerBar, statusHint: string; const body: TTextLines);
var
  top, visible, maxTop, key, i, idx: Integer;
begin
  top := 0;
  repeat
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    maxTop := High(body) - visible + 1;
    if maxTop < 0 then
      maxTop := 0;
    if top > maxTop then
      top := maxTop;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, headerBar);
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(body) then
        DrawText(1 + i, 1, cpText, body[idx]);
    end;
    DrawBar(ScreenRows - 1, cpStatus, statusHint);
    UIRefresh;
    key := UIGetKey;
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if top < maxTop then
          Inc(top);
      Ord('k'), KEY_UP:
        if top > 0 then
          Dec(top);
      KEY_NPAGE:
        top := top + visible;
      KEY_PPAGE:
        top := top - visible;
      Ord('g'), KEY_HOME:
        top := 0;
      Ord('G'), KEY_END:
        top := maxTop;
    end;
  until False;
end;

procedure ShowRevision(sess: TCsSession; const id: string; rev: Integer);
var
  n: TNote;
  err: string;
begin
  if FetchNote(sess, id, rev, n, err) then
    PageLines(' note · revision ' + IntToStr(rev),
      ' j/k scroll · g/G top/bottom · q back', NoteBodyLines(n))
  else
  begin
    UIErase;
    DrawBar(0, cpHeader, ' note · revision ' + IntToStr(rev));
    DrawBar(ScreenRows - 1, cpError, ' ' + err + '   (press any key)');
    UIRefresh;
    UIGetKey;
  end;
end;

procedure RunNoteRevisions(sess: TCsSession; const id: string);
var
  revs: TNoteArray;
  cursor, nextCursor, err: string;
  sel, top, visible, key: Integer;

  procedure LoadMore(reset: Boolean);
  var
    page: TNoteArray;
    oldLen, k: Integer;
  begin
    if reset then
    begin
      revs := FetchRevisions(sess, id, '', nextCursor, err);
      cursor := nextCursor;
      sel := 0;
      top := 0;
    end
    else
    begin
      if cursor = '' then
        Exit;
      page := FetchRevisions(sess, id, cursor, nextCursor, err);
      oldLen := Length(revs);
      SetLength(revs, oldLen + Length(page));
      for k := 0 to High(page) do
        revs[oldLen + k] := page[k];
      cursor := nextCursor;
    end;
  end;

  procedure RenderRow(y: Integer; const n: TNote; selected: Boolean);
  var
    left, right: string;
    rightW, rightX, leftW: Integer;
  begin
    left := 'rev ' + IntToStr(n.Revision) + '   ' + FirstLine(n.Content);
    right := RelativeTime(n.CreatedAt);
    rightW := VisibleWidth(right);
    rightX := ScreenCols - rightW - 1;
    leftW := rightX - 3;
    if leftW < 4 then
      leftW := 4;
    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      DrawText(y, 2, cpSelect, PadOrTrunc(left, leftW));
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, 2, cpText, PadOrTrunc(left, leftW));
      if rightX > 0 then
        DrawText(y, rightX, cpMeta, right);
    end;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(revs) then
      sel := High(revs);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' note · revisions');
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(revs) then
        RenderRow(1 + i, revs[idx], idx = sel);
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (q back)')
    else if Length(revs) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no revisions   ·   q back')
    else
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d   ·   j/k · Enter view · q back', [sel + 1, Length(revs)]));
    UIRefresh;
  end;

begin
  err := '';
  LoadMore(True);
  repeat
    Redraw;
    key := UIGetKey;
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(revs) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(revs) - 3) then
            LoadMore(False);
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + visible;
          if (cursor <> '') and (sel > High(revs) - 3) then
            LoadMore(False);
          if sel > High(revs) then
            sel := High(revs);
        end;
      KEY_PPAGE:
        sel := sel - visible;
      Ord('g'):
        sel := 0;
      Ord('G'):
        sel := High(revs);
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(revs)) then
          ShowRevision(sess, id, revs[sel].Revision);
    end;
  until False;
end;

{ Read one note with actions. Returns True if the list should reload (the note
  was edited or deleted). }
function RunNoteView(sess: TCsSession; var note: TNote): Boolean;
var
  body: TTextLines;
  top, visible, maxTop, key, i, idx: Integer;
  err, derr, ferr: string;
  changed: Boolean;

  procedure Rebuild;
  begin
    body := NoteBodyLines(note);
    top := 0;
  end;

begin
  Result := False;
  changed := False;
  err := '';
  top := 0;
  Rebuild;
  repeat
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    maxTop := High(body) - visible + 1;
    if maxTop < 0 then
      maxTop := 0;
    if top > maxTop then
      top := maxTop;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' note   ·   private');
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(body) then
        DrawText(1 + i, 1, cpText, body[idx]);
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err)
    else
      DrawBar(ScreenRows - 1, cpStatus,
        ' e edit · v revisions · d delete · j/k scroll · q back');
    UIRefresh;
    key := UIGetKey;
    if err <> '' then
      err := '';
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if top < maxTop then
          Inc(top);
      Ord('k'), KEY_UP:
        if top > 0 then
          Dec(top);
      KEY_NPAGE:
        top := top + visible;
      KEY_PPAGE:
        top := top - visible;
      Ord('g'), KEY_HOME:
        top := 0;
      Ord('G'), KEY_END:
        top := maxTop;
      Ord('e'):
        if EditNote(sess, note.Id, note.Content, TopicsPlain(note.Topics)) then
        begin
          changed := True;
          if not FetchNote(sess, note.Id, 0, note, ferr) then
            err := ferr;
          Rebuild;
        end;
      Ord('v'):
        RunNoteRevisions(sess, note.Id);
      Ord('d'):
        if UIConfirm('Delete this note? This removes all revisions.') then
        begin
          if DeleteNote(sess, note.Id, derr) then
          begin
            changed := True;
            Break;
          end
          else
            err := 'Delete failed: ' + derr;
        end;
    end;
  until False;
  Result := changed;
end;

{ ----- The note list ------------------------------------------------------- }

procedure RunNotes(sess: TCsSession);
var
  notes: TNoteArray;
  cursor, nextCursor, err, derr: string;
  sel, top, visible, key: Integer;

  procedure LoadMore(reset: Boolean);
  var
    page: TNoteArray;
    oldLen, k: Integer;
  begin
    if reset then
    begin
      notes := FetchNotesPage(sess, '', nextCursor, err);
      cursor := nextCursor;
      sel := 0;
      top := 0;
    end
    else
    begin
      if cursor = '' then
        Exit;
      page := FetchNotesPage(sess, cursor, nextCursor, err);
      oldLen := Length(notes);
      SetLength(notes, oldLen + Length(page));
      for k := 0 to High(page) do
        notes[oldLen + k] := page[k];
      cursor := nextCursor;
    end;
  end;

  procedure RenderRow(y: Integer; const n: TNote; selected: Boolean);
  var
    left, right: string;
    rightW, rightX, leftW: Integer;
  begin
    left := FirstLine(n.Content);
    right := '';
    if n.Revision > 1 then
      right := 'r' + IntToStr(n.Revision) + '  ';
    right := right + RelativeTime(n.UpdatedAt);
    rightW := VisibleWidth(right);
    rightX := ScreenCols - rightW - 1;
    leftW := rightX - 3;
    if leftW < 4 then
      leftW := 4;
    if selected then
    begin
      DrawBar(y, cpSelect, '');
      DrawText(y, 0, cpSelect, '›');
      DrawText(y, 2, cpSelect, PadOrTrunc(left, leftW));
      if rightX > 0 then
        DrawText(y, rightX, cpSelect, right);
    end
    else
    begin
      DrawText(y, 2, cpText, PadOrTrunc(left, leftW));
      if rightX > 0 then
        DrawText(y, rightX, cpMeta, right);
    end;
  end;

  procedure Redraw;
  var
    i, idx: Integer;
    more: string;
  begin
    visible := ScreenRows - 2;
    if visible < 1 then
      visible := 1;
    if sel < 0 then
      sel := 0;
    if sel > High(notes) then
      sel := High(notes);
    if sel < top then
      top := sel;
    if sel >= top + visible then
      top := sel - visible + 1;
    if top < 0 then
      top := 0;
    UIErase;
    DrawBar(0, cpHeader, ' tiespace   ·   notes (private)');
    for i := 0 to visible - 1 do
    begin
      idx := top + i;
      if idx <= High(notes) then
        RenderRow(1 + i, notes[idx], idx = sel);
    end;
    if err <> '' then
      DrawBar(ScreenRows - 1, cpError, ' ' + err + '    (r retry · q back)')
    else if Length(notes) = 0 then
      DrawBar(ScreenRows - 1, cpStatus, ' no notes yet · c new · r reload · q back')
    else
    begin
      if cursor <> '' then
        more := ' · more below'
      else
        more := '';
      DrawBar(ScreenRows - 1, cpStatus,
        Format(' %d/%d%s   ·   Enter read · c new · d delete · r reload · q back',
        [sel + 1, Length(notes), more]));
    end;
    UIRefresh;
  end;

begin
  err := '';
  LoadMore(True);
  repeat
    Redraw;
    key := UIGetKey;
    if (key <> Ord('r')) and (err <> '') then
      err := '';
    case key of
      Ord('q'), 27, Ord('h'), KEY_LEFT, KEY_BACKSPACE, 127:
        Break;
      Ord('j'), KEY_DOWN:
        if sel < High(notes) then
        begin
          Inc(sel);
          if (cursor <> '') and (sel > High(notes) - 3) then
            LoadMore(False);
        end;
      Ord('k'), KEY_UP:
        if sel > 0 then
          Dec(sel);
      KEY_NPAGE:
        begin
          sel := sel + visible;
          if (cursor <> '') and (sel > High(notes) - 3) then
            LoadMore(False);
          if sel > High(notes) then
            sel := High(notes);
        end;
      KEY_PPAGE:
        sel := sel - visible;
      Ord('g'):
        sel := 0;
      Ord('G'):
        begin
          if cursor <> '' then
            LoadMore(False);
          sel := High(notes);
        end;
      Ord('c'):
        if ComposeNote(sess) then
          LoadMore(True);
      Ord('d'):
        if (sel >= 0) and (sel <= High(notes)) then
          if UIConfirm('Delete this note? This removes all revisions.') then
          begin
            if DeleteNote(sess, notes[sel].Id, derr) then
              LoadMore(True)
            else
              err := 'Delete failed: ' + derr;
          end;
      Ord('r'):
        begin
          err := '';
          LoadMore(True);
        end;
      10, 13, KEY_ENTER:
        if (sel >= 0) and (sel <= High(notes)) then
          if RunNoteView(sess, notes[sel]) then
            LoadMore(True);
    end;
  until False;
end;

end.
