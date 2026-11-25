unit FloppyConsole;

interface

function RunConsole: Integer;

implementation

uses
  System.SysUtils, System.Classes, System.StrUtils, Winapi.Windows, FloppyWindows,
  FloppyDevices, FloppyGeometry, FloppyUfi;

type
  TConsoleLog = class
    Lines: TStringList;
    procedure WriteLine(const Line: string);
  end;

procedure TConsoleLog.WriteLine(const Line: string);
begin
  Writeln(Line);
  Lines.Add(Line);
end;

procedure Help;
begin
  Writeln('Floppy - read-only diagnostics');
  Writeln('  floppy list');
  Writeln('  floppy info|geometry|mediatypes|inquiry|capacity|formatcapacities X:');
  Writeln('  floppy diagnose X: [--report path.txt]');
  Writeln('  floppy help');
end;

function ReportHandle(const Path: string): THandle;
var
  Directory, FullPath, Resolved: string;
  Parent: THandle;
  Count: DWORD;
  Buffer: array[0..32767] of Char;
begin
  FullPath := ExpandFileName(Path);
  Directory := ExtractFileDir(FullPath);
  if (ExtractFileName(FullPath) = '') or (Pos(':', ExtractFileName(FullPath)) <> 0) then
    raise Exception.Create('Use a regular filename for the report.');
  Parent := CreateFile(PChar(Directory), 0, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Parent = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    Count := GetFinalPathNameByHandle(Parent, @Buffer[0], Length(Buffer), 1);
    if Count = 0 then
      RaiseLastOSError;
    if Count >= DWORD(Length(Buffer)) then
      raise Exception.Create('Report directory path is too long.');
    Resolved := PChar(@Buffer[0]);
    if not StartsText('\\?\Volume{', Resolved) or (Pos('}\', Resolved + '\') = 0) then
      raise Exception.Create('Place the report on a fixed local disk.');
    if GetDriveType(PChar(Copy(Resolved + '\', 1, Pos('}\', Resolved + '\') + 1))) <>
      DRIVE_FIXED then
      raise Exception.Create('Place the report on a fixed local disk.');
    FullPath := IncludeTrailingPathDelimiter(Resolved) + ExtractFileName(FullPath);
    Result := CreateFile(PChar(FullPath), GENERIC_WRITE, FILE_SHARE_READ, nil,
      CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if Result = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
  finally
    CloseHandle(Parent);
  end;
end;

procedure SaveReport(const Path: string; Lines: TStrings);
var
  Handle: THandle;
  Stream: THandleStream;
begin
  Handle := ReportHandle(Path);
  try
    Stream := THandleStream.Create(Handle);
    try
      Lines.SaveToStream(Stream, TEncoding.UTF8);
    finally
      Stream.Free;
    end;
  finally
    CloseHandle(Handle);
  end;
end;

function Execute(Log: TConsoleLog): Integer;
var
  Command, Drive, Report, LabelText: string;
  Devices: TFloppyDevices;
  Device: TFloppyDevice;
  Found: Boolean;
  Handle: THandle;
  Commands: TUfiCommands;
begin
  Command := LowerCase(ParamStr(1));
  if (ParamCount = 0) or ((ParamCount = 1) and (Command = 'help')) then
  begin
    Help;
    Exit(0);
  end;
  if not MatchText(Command, ['list', 'info', 'geometry', 'mediatypes',
    'inquiry', 'capacity', 'formatcapacities', 'diagnose']) then
  begin
    Help;
    Exit(2);
  end;
  if Command <> 'list' then
  begin
    Drive := UpperCase(ParamStr(2));
    if (Length(Drive) <> 2) or not CharInSet(Drive[1], ['A'..'Z']) or (Drive[2] <> ':') then
    begin
      Writeln(ErrOutput, 'Specify a validated floppy drive letter, e.g. A:.');
      Exit(2);
    end;
    if (Command = 'diagnose') and (ParamCount = 4) and
      SameText(ParamStr(3), '--report') and (ParamStr(4) <> '') then
      Report := ParamStr(4)
    else if ParamCount <> 2 then
    begin
      Help;
      Exit(2);
    end;
  end
  else if ParamCount <> 1 then
  begin
    Help;
    Exit(2);
  end;
  Log.WriteLine('Floppy phase 1 | ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) +
    ' local | ' + Command + ' ' + Drive);
  Devices := Discover(Log.WriteLine);
  if Command = 'list' then
  begin
    if Length(Devices) = 0 then
      Log.WriteLine('No floppy drives detected.');
    for Device in Devices do
    begin
      LabelText := Device.Drive;
      if LabelText = '' then
        LabelText := '(no drive letter)';
      Log.WriteLine(LabelText + '  ' + Device.DosTarget + '  ' + Device.InstanceId);
      if Device.UsbId <> '' then
        Log.WriteLine('  USB: ' + Device.UsbId);
    end;
    Exit(0);
  end;
  Found := False;
  for Device in Devices do
    if Device.Drive = Drive then
    begin
      Found := True;
      Break;
    end;
  if not Found then
  begin
    Log.WriteLine(Drive + ' could not be validated as a floppy drive.');
    Result := 2;
  end
  else
  begin
    Result := 0;
    if MatchText(Command, ['info', 'geometry', 'mediatypes', 'diagnose']) then
    begin
      Handle := OpenDevice(DevicePath(Device), 0);
      if Handle = INVALID_HANDLE_VALUE then
        LogError(Log.WriteLine, 'CreateFile for Windows queries', GetLastError)
      else
      try
        if MatchText(Command, ['info', 'diagnose']) then
          DeviceInfo(Device, Handle, Log.WriteLine);
        if MatchText(Command, ['geometry', 'diagnose']) then
          QueryGeometry(Handle, Log.WriteLine);
        if MatchText(Command, ['mediatypes', 'diagnose']) then
          QueryMediaTypes(Handle, Log.WriteLine);
      finally
        CloseHandle(Handle);
      end;
    end;
    Commands := [];
    if Command = 'diagnose' then
      Commands := [Low(TUfiCommand)..High(TUfiCommand)]
    else if Command = 'inquiry' then
      Commands := [ucInquiry]
    else if Command = 'capacity' then
      Commands := [ucCapacity]
    else if Command = 'formatcapacities' then
      Commands := [ucFormatCapacities];
    if Commands <> [] then
      QueryUfi(Device, Commands, Log.WriteLine);
  end;
  if Report <> '' then
  begin
    SaveReport(Report, Log.Lines);
    Writeln('Report saved to ', ExpandFileName(Report));
  end;
end;

function RunConsole: Integer;
var
  Log: TConsoleLog;
  OldMode: UINT;
begin
  OldMode := SetErrorMode(SEM_FAILCRITICALERRORS or SEM_NOOPENFILEERRORBOX);
  try
    Log := TConsoleLog.Create;
    try
      Log.Lines := TStringList.Create;
      try
        Result := Execute(Log);
      except
        on Failure: Exception do
        begin
          Writeln(ErrOutput, Failure.Message);
          Result := 1;
        end;
      end;
    finally
      Log.Lines.Free;
      Log.Free;
    end;
  finally
    SetErrorMode(OldMode);
  end;
end;

end.
