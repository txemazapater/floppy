# Floppy

MSX floppy disk diagnostic and management tool for Windows, using Delphi 11.3 Alexandria.

## Phase 1
Investigate physical 720 KB formatting on Mitsumi UFDD 061M (USB VID 03EE PID 6901, UFI/CBI). Windows 11 reads FAT12 files and accepts file writes; FORMAT rejects 720 KB geometry. Write persistence after reinsertion is not yet verified.

Run `floppy list`, then `floppy diagnose A: --report mitsumi.txt` using the
detected letter. The report includes Windows storage queries and read-only UFI
diagnostics, including READ FORMAT CAPACITIES (0x23). See
[diagnostics](docs/diagnostics.md) for commands and hardware tests.

## Build
Open `app/Floppy.dpr` in Delphi 11.3 Alexandria and select a Windows target,
or run `dcc32 -B Floppy.dpr` or `dcc64 -B Floppy.dpr` from `app` in the Delphi
command prompt. Build the targets separately or use separate output directories
with `-E` and `-N0`. No third-party dependencies.

## Future
Physical formatting where supported, MSX FAT12 logical formatting, sector access and DSK images.
