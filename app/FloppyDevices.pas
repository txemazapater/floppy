unit FloppyDevices;

interface

uses
  Winapi.Windows, FloppyWindows;

type
  TFloppyDevice = record
    Drive, DosTarget, InterfacePath, InstanceId, UsbId: string;
  end;

  TFloppyDevices = array of TFloppyDevice;

function Discover(Log: TDiagnosticLog): TFloppyDevices;
function DevicePath(const Device: TFloppyDevice): string;
procedure DeviceInfo(const Device: TFloppyDevice; Handle: THandle; Log: TDiagnosticLog);
function IsUfiTarget(const Device: TFloppyDevice; Handle: THandle): Boolean;

implementation

uses
  System.SysUtils, System.StrUtils;

const
  FloppyGuid: TGUID = '{53F56311-B6BF-11D0-94F2-00A0C91EFB8B}';
  DiskGuid: TGUID = '{53F56307-B6BF-11D0-94F2-00A0C91EFB8B}';

type
  TInterfaceData = record
    Size: DWORD;
    ClassGuid: TGUID;
    Flags: DWORD;
    Reserved: NativeUInt;
  end;

  TDevInfo = record
    Size: DWORD;
    ClassGuid: TGUID;
    DevInst: DWORD;
    Reserved: NativeUInt;
  end;

  TDeviceNumber = record
    Kind, Number, Partition: DWORD;
  end;

  TDriveEntry = record
    Device: TFloppyDevice;
    Number: TDeviceNumber;
    HasNumber, Found: Boolean;
  end;

function SetupGet(const ClassGuid: TGUID; Enumerator: PChar; Parent: HWND;
  Flags: DWORD): THandle; stdcall; external 'setupapi.dll' name 'SetupDiGetClassDevsW';
function SetupEnum(SetHandle: THandle; DeviceInfo: Pointer; const ClassGuid: TGUID;
  Index: DWORD; var Info: TInterfaceData): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiEnumDeviceInterfaces';
function SetupDetail(SetHandle: THandle; var Info: TInterfaceData; Detail: Pointer;
  DetailSize: DWORD; Required: Pointer; var DeviceInfo: TDevInfo): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiGetDeviceInterfaceDetailW';
function SetupDestroy(SetHandle: THandle): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiDestroyDeviceInfoList';
function CmParent(out Parent: DWORD; Child, Flags: DWORD): DWORD; stdcall;
  external 'cfgmgr32.dll' name 'CM_Get_Parent';
function CmId(Instance: DWORD; Buffer: PChar; Count, Flags: DWORD): DWORD; stdcall;
  external 'cfgmgr32.dll' name 'CM_Get_Device_IDW';

function DosTarget(const Name: string): string;
var
  Buffer: array[0..4095] of Char;
begin
  Result := '';
  if QueryDosDevice(PChar(Name), @Buffer[0], Length(Buffer)) <> 0 then
    Result := PChar(@Buffer[0]);
end;

function ReadNumber(Handle: THandle; out Number: TDeviceNumber): Boolean;
var
  Returned, Error: DWORD;
begin
  Result := Control(Handle, IoDeviceNumber, nil, 0, @Number, SizeOf(Number),
    Returned, Error) and (Returned >= SizeOf(Number)) and (Number.Number <> MAXDWORD);
end;

function MitsumiUsb(const UsbId: string): Boolean;
begin
  Result := StartsText('USB\VID_03EE&PID_6901&', UsbId) or
    StartsText('USB\VID_03EE&PID_6901\', UsbId);
end;

procedure Identify(DevInst: DWORD; var Device: TFloppyDevice);
var
  Buffer: array[0..199] of Char;
  Parent: DWORD;
  InstanceId: string;
begin
  while CmId(DevInst, @Buffer[0], Length(Buffer), 0) = 0 do
  begin
    InstanceId := PChar(@Buffer[0]);
    if Device.InstanceId = '' then
      Device.InstanceId := InstanceId;
    if StartsText('USB\VID_', InstanceId) then
    begin
      Device.UsbId := InstanceId;
      Break;
    end;
    if CmParent(Parent, DevInst, 0) <> 0 then
      Break;
    DevInst := Parent;
  end;
end;

function DevicePath(const Device: TFloppyDevice): string;
begin
  Result := Device.InterfacePath;
  if Result = '' then
    Result := '\\.\' + Device.Drive;
end;

function Discover(Log: TDiagnosticLog): TFloppyDevices;
var
  Drives: array[0..25] of TDriveEntry;
  Index: Integer;
  Mask, Error: DWORD;
  Handle: THandle;

  procedure Scan(const ClassGuid: TGUID; IsFloppyClass: Boolean);
  var
    SetHandle, InterfaceHandle: THandle;
    InterfaceData: TInterfaceData;
    DevInfo: TDevInfo;
    Detail: array[0..8191] of DWORD;
    Device: TFloppyDevice;
    Target: string;
    Number: TDeviceNumber;
    InterfaceIndex, ScanError: DWORD;
    DriveIndex: Integer;
    HasNumber, Matched: Boolean;
  begin
    SetHandle := SetupGet(ClassGuid, nil, 0, $12);
    if SetHandle = INVALID_HANDLE_VALUE then
    begin
      LogError(Log, 'SetupDiGetClassDevs ' + GUIDToString(ClassGuid), GetLastError);
      Exit;
    end;
    try
      InterfaceIndex := 0;
      repeat
        InterfaceData.Size := SizeOf(InterfaceData);
        if not SetupEnum(SetHandle, nil, ClassGuid, InterfaceIndex, InterfaceData) then
        begin
          ScanError := GetLastError;
          if ScanError <> ERROR_NO_MORE_ITEMS then
            LogError(Log, 'SetupDiEnumDeviceInterfaces', ScanError);
          Break;
        end;
        Inc(InterfaceIndex);
        DevInfo.Size := SizeOf(DevInfo);
        {$IFDEF WIN64}
        Detail[0] := 8;
        {$ELSE}
        Detail[0] := 6;
        {$ENDIF}
        if not SetupDetail(SetHandle, InterfaceData, @Detail[0], SizeOf(Detail),
          nil, DevInfo) then
        begin
          LogError(Log, 'SetupDiGetDeviceInterfaceDetail', GetLastError);
          Continue;
        end;
        Device := Default(TFloppyDevice);
        Device.InterfacePath := PChar(@Detail[1]);
        Identify(DevInfo.DevInst, Device);
        if not (IsFloppyClass or MitsumiUsb(Device.UsbId)) then
          Continue;
        Target := DosTarget(Copy(Device.InterfacePath, 5, MaxInt));
        HasNumber := False;
        InterfaceHandle := OpenDevice(Device.InterfacePath, 0);
        if InterfaceHandle <> INVALID_HANDLE_VALUE then
        try
          HasNumber := ReadNumber(InterfaceHandle, Number);
        finally
          CloseHandle(InterfaceHandle);
        end;
        Matched := False;
        for DriveIndex := Low(Drives) to High(Drives) do
          if (Drives[DriveIndex].Device.Drive <> '') and
            (((Target <> '') and SameText(Target, Drives[DriveIndex].Device.DosTarget)) or
             (HasNumber and Drives[DriveIndex].HasNumber and
              (Number.Kind = Drives[DriveIndex].Number.Kind) and
              (Number.Number = Drives[DriveIndex].Number.Number))) then
          begin
            Matched := True;
            if Drives[DriveIndex].Device.InterfacePath = '' then
            begin
              Device.Drive := Drives[DriveIndex].Device.Drive;
              Device.DosTarget := Drives[DriveIndex].Device.DosTarget;
              Drives[DriveIndex].Device := Device;
              Drives[DriveIndex].Found := True;
            end;
          end;
        if not Matched then
        begin
          Device.DosTarget := Target;
          for DriveIndex := 0 to High(Result) do
            if SameText(Device.InstanceId, Result[DriveIndex].InstanceId) and
              (Device.InstanceId <> '') then
              Matched := True;
          if not Matched then
            Result := Result + [Device];
        end;
      until False;
    finally
      SetupDestroy(SetHandle);
    end;
  end;

begin
  Result := nil;
  Mask := GetLogicalDrives;
  if Mask = 0 then
  begin
    Error := GetLastError;
    LogError(Log, 'GetLogicalDrives', Error);
  end;
  for Index := Low(Drives) to High(Drives) do
  begin
    Drives[Index] := Default(TDriveEntry);
    if Mask and (DWORD(1) shl Index) = 0 then
      Continue;
    if GetDriveType(PChar(Char(Ord('A') + Index) + ':\')) <> DRIVE_REMOVABLE then
      Continue;
    Drives[Index].Device.Drive := Char(Ord('A') + Index) + ':';
    Drives[Index].Device.DosTarget := DosTarget(Drives[Index].Device.Drive);
    Drives[Index].Found := StartsText('\Device\Floppy', Drives[Index].Device.DosTarget);
    Handle := OpenDevice('\\.\' + Drives[Index].Device.Drive, 0);
    if Handle <> INVALID_HANDLE_VALUE then
    try
      Drives[Index].HasNumber := ReadNumber(Handle, Drives[Index].Number);
    finally
      CloseHandle(Handle);
    end;
  end;
  Scan(FloppyGuid, True);
  Scan(DiskGuid, False);
  for Index := Low(Drives) to High(Drives) do
    if Drives[Index].Found then
      Result := Result + [Drives[Index].Device];
end;

procedure DeviceInfo(const Device: TFloppyDevice; Handle: THandle; Log: TDiagnosticLog);
var
  Data: TBytes;
  Error: DWORD;
  Number: TDeviceNumber;
begin
  Log('DOS target: ' + Device.DosTarget);
  Log('Physical interface: ' + Device.InterfacePath);
  Log('PnP instance: ' + Device.InstanceId);
  Log('USB ancestor: ' + Device.UsbId);
  if ReadNumber(Handle, Number) then
    Log(Format('Storage device type=%d number=%d partition=%d',
      [Number.Kind, Number.Number, Number.Partition]));
  if StorageProperty(Handle, 0, Data, Error) then
  begin
    Log(Format('IOCTL_STORAGE_QUERY_PROPERTY (device): OK, bus=%d',
      [Value32(Data, 28)]));
    Log('Vendor: ' + StorageText(Data, 12));
    Log('Product: ' + StorageText(Data, 16));
    Log('Revision: ' + StorageText(Data, 20));
    Log('Serial: ' + StorageText(Data, 24));
    LogHex(Log, 'Storage device descriptor', Data);
  end
  else
    LogError(Log, 'IOCTL_STORAGE_QUERY_PROPERTY (device)', Error);
end;

function IsUfiTarget(const Device: TFloppyDevice; Handle: THandle): Boolean;
var
  Data: TBytes;
  Error: DWORD;
begin
  Result := (Device.InterfacePath <> '') and MitsumiUsb(Device.UsbId);
  if not Result then
    Result := StorageProperty(Handle, 0, Data, Error) and
      (Value32(Data, 28) = 7) and
      (Pos('MITSUMI', UpperCase(StorageText(Data, 12) + ' ' + StorageText(Data, 16))) > 0) and
      (Pos('UFDD 061M', UpperCase(StorageText(Data, 16))) > 0);
end;

end.
