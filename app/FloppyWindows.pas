unit FloppyWindows;

interface

uses
  System.SysUtils, Winapi.Windows;

const
  IoGeometry = $00070000;
  IoGeometryEx = $000700A0;
  IoMediaTypes = $00070C00;
  IoStorageProperty = $002D1400;
  IoDeviceNumber = $002D1080;

type
  TDiagnosticLog = procedure(const Line: string) of object;

function OpenDevice(const Path: string; Access: DWORD): THandle;
function Control(Handle: THandle; Code: DWORD; Input: Pointer; InputSize: DWORD;
  Output: Pointer; OutputSize: DWORD; out Returned, Error: DWORD): Boolean;
procedure LogError(Log: TDiagnosticLog; const Operation: string; Error: DWORD);
procedure LogHex(Log: TDiagnosticLog; const Caption: string; const Data: TBytes);
function StorageProperty(Handle: THandle; Prop: DWORD; out Data: TBytes;
  out Error: DWORD): Boolean;
function StorageText(const Data: TBytes; FieldOffset: Integer): string;
function Value32(const Data: TBytes; Offset: Integer): DWORD;

implementation

function OpenDevice(const Path: string; Access: DWORD): THandle;
begin
  Result := CreateFile(PChar(Path), Access, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, 0, 0);
end;

function Control(Handle: THandle; Code: DWORD; Input: Pointer; InputSize: DWORD;
  Output: Pointer; OutputSize: DWORD; out Returned, Error: DWORD): Boolean;
begin
  Returned := 0;
  Result := DeviceIoControl(Handle, Code, Input, InputSize, Output, OutputSize,
    Returned, nil);
  if Result then
    Error := 0
  else
    Error := GetLastError;
end;

procedure LogError(Log: TDiagnosticLog; const Operation: string; Error: DWORD);
begin
  Log(Format('%s: Win32 %d (0x%.8x) %s',
    [Operation, Error, Error, SysErrorMessage(Error)]));
end;

procedure LogHex(Log: TDiagnosticLog; const Caption: string; const Data: TBytes);
var
  Index: Integer;
  Line: string;
begin
  Log(Format('%s (%d bytes)', [Caption, Length(Data)]));
  for Index := 0 to High(Data) do
  begin
    if Index mod 16 = 0 then
      Line := Format('  %.4x:', [Index]);
    Line := Line + ' ' + IntToHex(Data[Index], 2);
    if (Index mod 16 = 15) or (Index = High(Data)) then
      Log(Line);
  end;
end;

function Value32(const Data: TBytes; Offset: Integer): DWORD;
begin
  Result := 0;
  if (Offset >= 0) and (Offset <= Length(Data) - SizeOf(Result)) then
    Move(Data[Offset], Result, SizeOf(Result));
end;

function StorageProperty(Handle: THandle; Prop: DWORD; out Data: TBytes;
  out Error: DWORD): Boolean;
var
  Query: array[0..2] of DWORD;
  Header: array[0..1] of DWORD;
  Returned: DWORD;
begin
  Data := nil;
  FillChar(Query, SizeOf(Query), 0);
  Query[0] := Prop;
  if not Control(Handle, IoStorageProperty, @Query, SizeOf(Query), @Header,
    SizeOf(Header), Returned, Error) then
    Exit(False);
  if (Returned < SizeOf(Header)) or (Header[1] < SizeOf(Header)) or
    (Header[1] > 65536) then
  begin
    Error := ERROR_INVALID_DATA;
    Exit(False);
  end;
  SetLength(Data, Header[1]);
  Result := Control(Handle, IoStorageProperty, @Query, SizeOf(Query),
    @Data[0], Length(Data), Returned, Error);
  if Result and (Returned >= SizeOf(Header)) and (Returned <= DWORD(Length(Data))) then
    SetLength(Data, Returned)
  else
  begin
    if Result then
      Error := ERROR_INVALID_DATA;
    Result := False;
    Data := nil;
  end;
end;

function StorageText(const Data: TBytes; FieldOffset: Integer): string;
var
  Start, Stop: DWORD;
  Raw: AnsiString;
begin
  Result := '';
  Start := Value32(Data, FieldOffset);
  if (Start < 36) or (Start >= DWORD(Length(Data))) then
    Exit;
  Stop := Start;
  while (Stop < DWORD(Length(Data))) and (Data[Stop] <> 0) do
    Inc(Stop);
  if Stop = DWORD(Length(Data)) then
    Exit;
  SetString(Raw, PAnsiChar(@Data[Start]), Stop - Start);
  Result := Trim(string(Raw));
end;

end.
