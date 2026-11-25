unit FloppyUfi;

interface

uses
  Winapi.Windows, FloppyDevices, FloppyWindows;

type
  TUfiCommand = (ucReady, ucSense, ucInquiry, ucFormatCapacities, ucCapacity);
  TUfiCommands = set of TUfiCommand;

procedure QueryUfi(const Device: TFloppyDevice; Commands: TUfiCommands;
  Log: TDiagnosticLog);

implementation

uses
  System.SysUtils, System.Math;

const
  IoBuffered = $0004D004;
  IoDirect = $0004D014;
  SenseSize = 32;
  FormatCapacityHeaderSize = 4;
  FormatCapacityDescriptorSize = 8;
  FormatCapacitySize = 260;
  Opcodes: array[TUfiCommand] of Byte = ($00, $03, $12, $23, $25);
  Names: array[TUfiCommand] of string = ('TEST UNIT READY', 'REQUEST SENSE',
    'INQUIRY', 'READ FORMAT CAPACITIES', 'READ CAPACITY (10)');
  TransferSizes: array[TUfiCommand] of DWORD = (0, 18, 36, FormatCapacitySize, 8);
  TransportNames: array[Boolean] of string = ('IOCTL_SCSI_PASS_THROUGH',
    'IOCTL_SCSI_PASS_THROUGH_DIRECT');

type
  TPass = record
    Length: Word;
    Status, PathId, TargetId, Lun, CdbLength, SenseLength, DataIn: Byte;
    Transfer, Timeout: DWORD;
    DataLocation: NativeUInt;
    SenseOffset: DWORD;
    Cdb: array[0..15] of Byte;
  end;
  PPass = ^TPass;

function BigEndian(const Data: TBytes; Offset, Count: Integer): UInt64;
var
  Index: Integer;
begin
  Result := 0;
  for Index := Offset to Offset + Count - 1 do
    Result := (Result shl 8) or Data[Index];
end;

procedure DecodeSense(const Data: TBytes; Log: TDiagnosticLog);
var
  KeyOffset, AscOffset: Integer;
begin
  if Length(Data) = 0 then
    Exit;
  case Data[0] and $7F of
    $70, $71:
      begin
        KeyOffset := 2;
        AscOffset := 12;
        if (Length(Data) < 14) or (Data[7] < 6) then
          AscOffset := -1;
      end;
    $72, $73:
      begin
        KeyOffset := 1;
        AscOffset := 2;
      end;
  else
    Log('Sense format not recognized');
    Exit;
  end;
  if Length(Data) > KeyOffset then
    Log(Format('Sense Key=0x%.2x', [Data[KeyOffset] and $0F]));
  if (AscOffset >= 0) and (Length(Data) > AscOffset + 1) then
    Log(Format('ASC=0x%.2x ASCQ=0x%.2x', [Data[AscOffset], Data[AscOffset + 1]]));
end;

function InquiryText(const Data: TBytes; Offset, Count: Integer): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := Offset to Offset + Count - 1 do
    if Data[Index] in [32..126] then
      Result := Result + Char(Data[Index])
    else
      Result := Result + '.';
  Result := Trim(Result);
end;

procedure DecodeFormats(const Data: TBytes; Log: TDiagnosticLog);
const
  CurrentTypes: array[0..3] of string = ('Reserved current/maximum code',
    'Unformatted medium maximum', 'Current formatted medium', 'No medium, device maximum');
var
  Offset, ListLength, Limit, Kind: Integer;
  Blocks, BlockSize: UInt64;
  LabelText: string;
  Has720, Has1440, Complete: Boolean;

  function ReportMatch(Found: Boolean): string;
  begin
    if Found then
      Result := 'listed'
    else if Complete then
      Result := 'not listed'
    else
      Result := 'undetermined (incomplete list)';
  end;

begin
  if Length(Data) < FormatCapacityHeaderSize then
  begin
    Log('Capacity list header truncated');
    Exit;
  end;
  ListLength := Data[3];
  Log(Format('Capacity list length: %d bytes', [ListLength]));
  Complete := (ListLength >= FormatCapacityDescriptorSize) and
    (ListLength mod FormatCapacityDescriptorSize = 0) and
    (Length(Data) >= FormatCapacityHeaderSize + ListLength);
  if not Complete then
    Log('Capacity list malformed or truncated');
  Limit := Min(Length(Data), FormatCapacityHeaderSize + ListLength);
  Offset := FormatCapacityHeaderSize;
  Has720 := False;
  Has1440 := False;
  while Offset + FormatCapacityDescriptorSize <= Limit do
  begin
    Blocks := BigEndian(Data, Offset, 4);
    BlockSize := BigEndian(Data, Offset + 5, 3);
    if Offset = FormatCapacityHeaderSize then
    begin
      Kind := Data[Offset + 4] and 3;
      LabelText := Format('%s (code %d)', [CurrentTypes[Kind], Kind]);
    end
    else
    begin
      LabelText := 'Formattable capacity';
      Has720 := Has720 or ((Blocks = 1440) and (BlockSize = 512));
      Has1440 := Has1440 or ((Blocks = 2880) and (BlockSize = 512));
    end;
    Log(Format('%s: %d blocks x %d bytes = %d bytes',
      [LabelText, Blocks, BlockSize, Blocks * BlockSize]));
    Inc(Offset, FormatCapacityDescriptorSize);
  end;
  Log('720 KB (1440 x 512) among formattable descriptors: ' + ReportMatch(Has720));
  Log('1.44 MB (2880 x 512) among formattable descriptors: ' + ReportMatch(Has1440));
end;

procedure Decode(Command: TUfiCommand; const Data: TBytes; Log: TDiagnosticLog);
var
  LastBlock, BlockSize: UInt64;
begin
  case Command of
    ucSense: DecodeSense(Data, Log);
    ucInquiry:
      if (Length(Data) >= 36) and (Data[4] >= 31) then
      begin
        Log(Format('Peripheral type=%d removable=%d',
          [Data[0] and $1F, Data[1] shr 7]));
        Log('Vendor: ' + InquiryText(Data, 8, 8));
        Log('Product: ' + InquiryText(Data, 16, 16));
        Log('Revision: ' + InquiryText(Data, 32, 4));
      end
      else
        Log('INQUIRY identification fields truncated');
    ucCapacity:
      if Length(Data) >= 8 then
      begin
        LastBlock := BigEndian(Data, 0, 4);
        BlockSize := BigEndian(Data, 4, 4);
        if LastBlock = MAXDWORD then
          Log('READ CAPACITY (10): capacity exceeds the 32-bit LBA field')
        else
          Log(Format('Current logical capacity: last LBA=%d, %d blocks x %d bytes = %d bytes',
            [LastBlock, LastBlock + 1, BlockSize, (LastBlock + 1) * BlockSize]));
      end
      else
        Log('READ CAPACITY (10) response truncated');
  end;
end;

function Send(Handle: THandle; Command: TUfiCommand; Direct: Boolean;
  AlignmentMask, Needed: DWORD; Log: TDiagnosticLog; out Payload: TBytes): Boolean;
var
  Packet, AlignedData, Sense: TBytes;
  Header: PPass;
  DataPointer: Pointer;
  PacketSize, DataOffset, Returned, Error, Code, Count: DWORD;
  Operation: string;
begin
  Result := False;
  Payload := nil;
  Operation := Names[Command] + ' / ' + TransportNames[Direct];
  DataOffset := (SizeOf(TPass) + SenseSize + AlignmentMask) and not AlignmentMask;
  PacketSize := SizeOf(TPass) + SenseSize;
  if not Direct and (Needed <> 0) then
    PacketSize := DataOffset + Needed;
  SetLength(Packet, PacketSize);
  Header := PPass(@Packet[0]);
  Header.Length := SizeOf(TPass);
  Header.CdbLength := 12;
  Header.SenseLength := SenseSize;
  Header.SenseOffset := SizeOf(TPass);
  Header.Transfer := Needed;
  Header.Timeout := 10;
  Header.DataIn := 2;
  Header.Cdb[0] := Opcodes[Command];
  case Command of
    ucSense, ucInquiry: Header.Cdb[4] := Byte(Needed);
    ucFormatCapacities:
      begin
        Header.Cdb[7] := Byte(Needed shr 8);
        Header.Cdb[8] := Byte(Needed and $FF);
      end;
  end;
  Code := IoBuffered;
  if Direct then
    Code := IoDirect;
  DataPointer := nil;
  if Needed <> 0 then
  begin
    Header.DataIn := 1;
    if Direct then
    begin
      SetLength(AlignedData, Needed + AlignmentMask);
      DataPointer := Pointer((NativeUInt(@AlignedData[0]) + AlignmentMask) and
        not NativeUInt(AlignmentMask));
      Header.DataLocation := NativeUInt(DataPointer);
    end
    else
    begin
      DataPointer := @Packet[DataOffset];
      Header.DataLocation := DataOffset;
    end;
  end;
  if not Control(Handle, Code, Header, PacketSize, Header, PacketSize, Returned,
    Error) then
  begin
    LogError(Log, Operation + ' (transport)', Error);
    Exit;
  end;
  if (Returned < SizeOf(TPass)) or (Returned > PacketSize) then
  begin
    Log(Operation + ': transport OK, invalid returned header length');
    Exit;
  end;
  Log(Format('%s: transport OK, SCSI status=0x%.2x', [Operation, Header.Status]));
  if (Header.SenseOffset = SizeOf(TPass)) and (Returned > SizeOf(TPass)) then
  begin
    Count := Min(DWORD(SenseSize), Min(DWORD(Header.SenseLength), Returned - SizeOf(TPass)));
    Sense := Copy(Packet, SizeOf(TPass), Count);
    if (Length(Sense) > 0) and (Sense[0] <> 0) then
    begin
      LogHex(Log, 'Automatic sense', Sense);
      DecodeSense(Sense, Log);
    end;
  end;
  Result := Header.Status = 0;
  if Needed = 0 then
    Exit;
  Count := Min(Needed, Header.Transfer);
  if not Direct then
    if Returned > DataOffset then
      Count := Min(Count, Returned - DataOffset)
    else
      Count := 0;
  if Command = ucFormatCapacities then
    Log(Format('READ FORMAT CAPACITIES transfer: requested=%d, reported=%d, IOCTL bytes=%d',
      [Needed, Header.Transfer, Returned]));
  SetLength(Payload, Count);
  if Count <> 0 then
    Move(DataPointer^, Payload[0], Count);
  LogHex(Log, 'Data in', Payload);
end;

procedure QueryFormatCapacities(Handle: THandle; Direct: Boolean;
  AlignmentMask: DWORD; Log: TDiagnosticLog);
var
  Payload, RetryPayload: TBytes;
  ListLength, RetrySize: Integer;
begin
  if not Send(Handle, ucFormatCapacities, Direct, AlignmentMask,
    FormatCapacitySize, Log, Payload) then
    Exit;
  if Length(Payload) >= FormatCapacityHeaderSize then
  begin
    ListLength := Payload[FormatCapacityHeaderSize - 1];
    RetrySize := FormatCapacityHeaderSize + ListLength;
    if (ListLength >= FormatCapacityDescriptorSize) and
      (ListLength mod FormatCapacityDescriptorSize = 0) and (Length(Payload) < RetrySize) then
    begin
      Log(Format('READ FORMAT CAPACITIES: retrying with exactly %d bytes (%s)',
        [RetrySize, TransportNames[Direct]]));
      if Send(Handle, ucFormatCapacities, Direct, AlignmentMask,
        RetrySize, Log, RetryPayload) and (Length(RetryPayload) >= Length(Payload)) then
        Payload := RetryPayload;
    end;
  end;
  DecodeFormats(Payload, Log);
end;

procedure QueryUfi(const Device: TFloppyDevice; Commands: TUfiCommands;
  Log: TDiagnosticLog);
var
  Handle: THandle;
  Command: TUfiCommand;
  Data, Payload: TBytes;
  Error, AlignmentMask: DWORD;
  Direct: Boolean;
  Layout: TPass;
begin
  {$IFDEF WIN64}
  if (SizeOf(TPass) <> 56) or (NativeUInt(@Layout.DataLocation) - NativeUInt(@Layout) <> 24) then
  {$ELSE}
  if (SizeOf(TPass) <> 44) or (NativeUInt(@Layout.DataLocation) - NativeUInt(@Layout) <> 20) then
  {$ENDIF}
  begin
    Log('SCSI pass-through skipped: unexpected native record layout');
    Exit;
  end;
  Handle := OpenDevice(DevicePath(Device), 0);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    LogError(Log, 'CreateFile for UFI identification', GetLastError);
    Exit;
  end;
  try
    if not IsUfiTarget(Device, Handle) then
    begin
      Log('SCSI pass-through skipped: device not identified as Mitsumi UFDD 061M');
      Exit;
    end;
  finally
    CloseHandle(Handle);
  end;
  Handle := OpenDevice(DevicePath(Device), GENERIC_READ or GENERIC_WRITE);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    LogError(Log, 'CreateFile for SCSI pass-through (read/write access)', GetLastError);
    Exit;
  end;
  try
    if not IsUfiTarget(Device, Handle) then
    begin
      Log('SCSI pass-through skipped: target validation failed on command handle');
      Exit;
    end;
    AlignmentMask := 4095;
    if StorageProperty(Handle, 1, Data, Error) and (Length(Data) >= 20) then
    begin
      AlignmentMask := Value32(Data, 16);
      if (AlignmentMask > $FFFF) or ((AlignmentMask and (AlignmentMask + 1)) <> 0) then
      begin
        Log('Invalid adapter alignment mask; using page alignment');
        AlignmentMask := 4095;
      end
      else
        Log(Format('Storage adapter alignment mask: 0x%x', [AlignmentMask]));
    end
    else if Error <> 0 then
      LogError(Log, 'IOCTL_STORAGE_QUERY_PROPERTY (adapter), using page alignment', Error)
    else
      Log('Storage adapter descriptor truncated; using page alignment');
    for Direct := False to True do
      for Command := Low(TUfiCommand) to High(TUfiCommand) do
        if Command in Commands then
        begin
          if Command = ucFormatCapacities then
            QueryFormatCapacities(Handle, Direct, AlignmentMask, Log)
          else if Send(Handle, Command, Direct, AlignmentMask,
            TransferSizes[Command], Log, Payload) then
            Decode(Command, Payload, Log);
        end;
  finally
    CloseHandle(Handle);
  end;
end;

end.
