# Floppy

MSX floppy disk diagnostic and management tool for Windows, using Delphi 11.3 Alexandria.

## Phase 1
Investigate physical 720 KB formatting on Mitsumi UFDD 061M (USB VID 03EE PID 6901, UFI/CBI). Windows 11 reads FAT12 files and accepts file writes; FORMAT rejects 720 KB geometry. Write persistence after reinsertion is not yet verified.

Start with read-only diagnostics: DeviceIoControl geometry and media types, then investigate SCSI pass-through and UFI READ FORMAT CAPACITIES (0x23). Report Win32 errors and sense data. No destructive commands in phase 1.

## Build
Open app/Floppy.dpr in Delphi 11.3, select Win32 and save IDE project settings locally. No third-party dependencies.

## Future
Physical formatting where supported, MSX FAT12 logical formatting, sector access and DSK images.
