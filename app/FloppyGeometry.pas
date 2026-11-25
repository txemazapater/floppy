unit FloppyGeometry;

interface

uses
  Winapi.Windows, FloppyWindows;

procedure QueryGeometry(Handle: THandle; Log: TDiagnosticLog);
procedure QueryMediaTypes(Handle: THandle; Log: TDiagnosticLog);

implementation

uses
  System.SysUtils;

type
  TDiskGeometry = record
    Cylinders: Int64;
    MediaType, Tracks, Sectors, BytesPerSector: DWORD;
  end;

const
  MediaNames: array[0..25] of string = ('Unknown', 'F5_1Pt2_512',
    'F3_1Pt44_512', 'F3_2Pt88_512', 'F3_20Pt8_512', 'F3_720_512',
    'F5_360_512', 'F5_320_512', 'F5_320_1024', 'F5_180_512', 'F5_160_512',
    'RemovableMedia', 'FixedMedia', 'F3_120M_512', 'F3_640_512',
    'F5_640_512', 'F5_720_512', 'F3_1Pt2_512', 'F3_1Pt23_1024',
    'F5_1Pt23_1024', 'F3_128Mb_512', 'F3_230Mb_512', 'F8_256_128',
    'F3_200Mb_512', 'F3_240M_512', 'F3_32M_512');

procedure Show(const Value: TDiskGeometry; Log: TDiagnosticLog);
var
  Name: string;
  Capacity: UInt64;
  Factor: DWORD;

  function Multiply(Value: DWORD): Boolean;
  begin
    Result := Value <> 0;
    if Result then
      Result := Capacity <= High(UInt64) div Value;
    if Result then
      Capacity := Capacity * Value;
  end;

begin
  Name := 'Unrecognized';
  if Value.MediaType <= High(MediaNames) then
    Name := MediaNames[Value.MediaType];
  Log(Format('  MediaType=%d (%s), cylinders=%d, tracks/cylinder=%d, ' +
    'sectors/track=%d, bytes/sector=%d', [Value.MediaType, Name, Value.Cylinders,
    Value.Tracks, Value.Sectors, Value.BytesPerSector]));
  Capacity := 0;
  if Value.Cylinders > 0 then
    Capacity := UInt64(Value.Cylinders);
  Factor := Value.Tracks;
  if (Capacity > 0) and Multiply(Factor) and Multiply(Value.Sectors) and
    Multiply(Value.BytesPerSector) then
    Log('  Calculated capacity: ' + UIntToStr(Capacity) + ' bytes')
  else
    Log('  Calculated capacity unavailable');
end;

procedure QueryGeometry(Handle: THandle; Log: TDiagnosticLog);
var
  Geometry: TDiskGeometry;
  Buffer: array[0..511] of Byte;
  Returned, Error: DWORD;
  DiskSize: Int64;
begin
  Log('Inserted medium');
  if Control(Handle, IoGeometry, nil, 0, @Geometry, SizeOf(Geometry), Returned,
    Error) and (Returned = SizeOf(Geometry)) then
  begin
    Log('IOCTL_DISK_GET_DRIVE_GEOMETRY: OK');
    Show(Geometry, Log);
  end
  else if Error <> 0 then
    LogError(Log, 'IOCTL_DISK_GET_DRIVE_GEOMETRY', Error)
  else
    Log('IOCTL_DISK_GET_DRIVE_GEOMETRY: invalid response length');
  if Control(Handle, IoGeometryEx, nil, 0, @Buffer[0], SizeOf(Buffer), Returned,
    Error) and (Returned >= SizeOf(Geometry) + SizeOf(DiskSize)) then
  begin
    Log('IOCTL_DISK_GET_DRIVE_GEOMETRY_EX: OK');
    Move(Buffer[0], Geometry, SizeOf(Geometry));
    Move(Buffer[SizeOf(Geometry)], DiskSize, SizeOf(DiskSize));
    Show(Geometry, Log);
    Log(Format('  DiskSize: %d bytes', [DiskSize]));
  end
  else if Error <> 0 then
    LogError(Log, 'IOCTL_DISK_GET_DRIVE_GEOMETRY_EX', Error)
  else
    Log('IOCTL_DISK_GET_DRIVE_GEOMETRY_EX: invalid response length');
end;

procedure QueryMediaTypes(Handle: THandle; Log: TDiagnosticLog);
var
  Geometries: array[0..127] of TDiskGeometry;
  Returned, Error: DWORD;
  Index, Count: Integer;
begin
  Log('Driver-declared media geometries');
  if not Control(Handle, IoMediaTypes, nil, 0, @Geometries[0], SizeOf(Geometries),
    Returned, Error) then
  begin
    LogError(Log, 'IOCTL_DISK_GET_MEDIA_TYPES', Error);
    Exit;
  end;
  if (Returned > SizeOf(Geometries)) or (Returned mod SizeOf(TDiskGeometry) <> 0) then
  begin
    Log('IOCTL_DISK_GET_MEDIA_TYPES: invalid response length');
    Exit;
  end;
  Count := Returned div SizeOf(TDiskGeometry);
  Log(Format('IOCTL_DISK_GET_MEDIA_TYPES: OK, %d geometries', [Count]));
  for Index := 0 to Count - 1 do
    Show(Geometries[Index], Log);
end;

end.
