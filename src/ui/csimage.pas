unit CsImage;

(* Image support for the thread view.

   Posts embed images as markdown: ![alt](https://bunker.cyberspace.online/...).
   - ExtractImages pulls those out for viewing.
   - CleanImageMarkdown rewrites them to a compact marker so the text reads
     cleanly instead of showing giant raw URLs.
   - ViewImages downloads each (unauthenticated -- it's a different host, and we
     must not leak the API bearer token there) and shells out to chafa, which
     adapts to the terminal (Kitty graphics / sixel / Unicode) and decodes WebP.
     The TUI is suspended around the external viewer. *)

{$mode objfpc}{$H+}

interface

type
  TImageRef = record
    Alt: string;
    Url: string;
  end;
  TImageRefs = array of TImageRef;

function ExtractImages(const content: string): TImageRefs;
procedure AppendImages(var dst: TImageRefs; const src: TImageRefs);
function CleanImageMarkdown(const content: string): string;
procedure ViewImages(const images: TImageRefs);

implementation

uses
  SysUtils, StrUtils, Classes, Unix, fphttpclient, opensslsockets, CsUI;

function ExtractImages(const content: string): TImageRefs;
var
  p, rb, rp: Integer;
  alt, url: string;
begin
  SetLength(Result, 0);
  p := 1;
  while True do
  begin
    p := PosEx('![', content, p);
    if p = 0 then
      Break;
    rb := PosEx(']', content, p + 2);
    if rb = 0 then
      Break;
    if (rb + 1 <= Length(content)) and (content[rb + 1] = '(') then
    begin
      rp := PosEx(')', content, rb + 2);
      if rp = 0 then
        Break;
      alt := Trim(Copy(content, p + 2, rb - (p + 2)));
      url := Trim(Copy(content, rb + 2, rp - (rb + 2)));
      if (Pos('http://', url) = 1) or (Pos('https://', url) = 1) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)].Alt := alt;
        Result[High(Result)].Url := url;
      end;
      p := rp + 1;
    end
    else
      p := rb + 1;
  end;
end;

procedure AppendImages(var dst: TImageRefs; const src: TImageRefs);
var
  i, base: Integer;
begin
  base := Length(dst);
  SetLength(dst, base + Length(src));
  for i := 0 to High(src) do
    dst[base + i] := src[i];
end;

function CleanImageMarkdown(const content: string): string;
var
  p, rb, rp, last: Integer;
  alt: string;
begin
  Result := '';
  last := 1;
  p := 1;
  while True do
  begin
    p := PosEx('![', content, p);
    if p = 0 then
      Break;
    rb := PosEx(']', content, p + 2);
    if (rb = 0) or (rb + 1 > Length(content)) or (content[rb + 1] <> '(') then
    begin
      p := p + 2;
      Continue;
    end;
    rp := PosEx(')', content, rb + 2);
    if rp = 0 then
    begin
      p := p + 2;
      Continue;
    end;
    alt := Trim(Copy(content, p + 2, rb - (p + 2)));
    Result := Result + Copy(content, last, p - last);
    if alt = '' then
      Result := Result + '🖼 [image]'
    else
      Result := Result + '🖼 [' + alt + ']';
    last := rp + 1;
    p := rp + 1;
  end;
  Result := Result + Copy(content, last, Length(content) - last + 1);
end;

function ShellQuote(const s: string): string;
begin
  Result := '''' + StringReplace(s, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function TempImagePath(const url: string; idx: Integer): string;
var
  ext: string;
  q: Integer;
begin
  ext := ExtractFileExt(url);
  q := Pos('?', ext);
  if q > 0 then
    ext := Copy(ext, 1, q - 1);
  if (ext = '') or (Length(ext) > 6) then
    ext := '.img';
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'tiespace-img-' +
    IntToStr(idx) + ext;
end;

function DownloadToFile(const url, dest: string; out err: string): Boolean;
var
  http: TFPHTTPClient;
  fs: TFileStream;
begin
  Result := False;
  err := '';
  http := TFPHTTPClient.Create(nil);
  fs := TFileStream.Create(dest, fmCreate);
  try
    http.AllowRedirect := True;
    http.AddHeader('User-Agent', 'tiespace-tui/0.1 (+cyberspace personal client)');
    try
      http.Get(url, fs); // no Authorization header: different host
      Result := fs.Size > 0;
      if not Result then
        err := 'empty response';
    except
      on E: Exception do
        err := E.Message;
    end;
  finally
    fs.Free;
    http.Free;
  end;
end;

procedure ViewImages(const images: TImageRefs);
var
  i, cols, rows: Integer;
  tmp, err, line: string;
  ok: Boolean;
begin
  if Length(images) = 0 then
    Exit;
  for i := 0 to High(images) do
  begin
    cols := ScreenCols;
    rows := ScreenRows;
    DrawBar(rows - 1, cpStatus, Format(' Downloading image %d/%d…',
      [i + 1, Length(images)]));
    UIRefresh;
    tmp := TempImagePath(images[i].Url, i);
    ok := DownloadToFile(images[i].Url, tmp, err);

    UISuspend;
    fpSystem('clear');
    if ok then
      fpSystem('chafa --size ' + IntToStr(cols) + 'x' + IntToStr(rows - 1) +
        ' ' + ShellQuote(tmp))
    else
      WriteLn('Could not download image: ', err);
    if ok then
      DeleteFile(tmp);
    Write(Format('  [%d/%d] %s    —    Enter: next    ·    q + Enter: stop  ',
      [i + 1, Length(images), images[i].Alt]));
    Flush(Output);
    ReadLn(line);
    UIResume;
    if LowerCase(Trim(line)) = 'q' then
      Break;
  end;
end;

end.
