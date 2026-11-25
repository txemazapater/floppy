# Diagnostic baseline

- Mitsumi USB UFDD 061M, VID 03EE PID 6901, revision 0200.
- Windows 11 native USBSTOR_CBI.NT driver.
- Initial Code 10 cleared after disconnect/reconnect without media.
- MSX FAT volume: 730112 usable bytes; 716800 free before test write.
- COMMAND.COM, MSXDOS.SYS and AUTOEXEC.BAT copied successfully.
- TEST.TXT appeared in the directory after copying from Windows.
- FORMAT /F:720 and /T:80 /N:9 rejected parameters on a DD disk.

## Commands

| Command | Information |
| --- | --- |
| `floppy list` | Floppy interfaces, drive letters, DOS targets and USB instance IDs |
| `floppy info A:` | Physical interface, storage device number, vendor, product and revision |
| `floppy geometry A:` | Windows geometry and extended size for the inserted medium |
| `floppy mediatypes A:` | Media geometries declared by the Windows class driver |
| `floppy inquiry A:` | UFI INQUIRY through both SCSI transports |
| `floppy capacity A:` | UFI READ CAPACITY (10) for current logical capacity |
| `floppy formatcapacities A:` | UFI READ FORMAT CAPACITIES, opcode 0x23 |
| `floppy diagnose A: --report mitsumi.txt` | All queries, including TEST UNIT READY and REQUEST SENSE, with optional UTF-8 report |
| `floppy help` | Command syntax |

Replace `A:` with the detected letter. The report must name a new file in an
existing directory on a fixed local disk. Exit code 0 means the diagnostic ran.
Individual failures appear in the output and other queries continue. Code 2
indicates invalid arguments or an unvalidated target. Code 1 indicates a fatal
error such as failure to save the report.

## Design

- `FloppyConsole` handles commands, output and report creation.
- `FloppyDevices` uses SetupAPI and Configuration Manager to enumerate floppy
  interfaces and find USB ancestors. It correlates removable letters with
  interfaces by DOS target or storage device number. It also checks disk
  interfaces for the known Mitsumi VID/PID and detects native floppy DOS
  targets. Unlettered devices appear in `list`. Other commands require a letter.
- `FloppyWindows` provides Win32 handle and IOCTL helpers. `FloppyGeometry`
  decodes `IOCTL_DISK_GET_DRIVE_GEOMETRY`, `IOCTL_DISK_GET_DRIVE_GEOMETRY_EX`
  and `IOCTL_DISK_GET_MEDIA_TYPES`. `IOCTL_STORAGE_QUERY_PROPERTY` supplies
  the device descriptor and adapter alignment mask.
- `FloppyUfi` builds 12-byte CDBs with big-endian multibyte fields and a fixed
  set of query commands. It tries `IOCTL_SCSI_PASS_THROUGH` and
  `IOCTL_SCSI_PASS_THROUGH_DIRECT` independently, using native record layout
  and aligned buffers. It uses 4 KiB alignment if the mask is unavailable.
  It logs Win32 transport failures, SCSI status, sense and hex dumps separately.
  The stack may already have consumed sense data before explicit REQUEST SENSE.
  The units use a logging callback for reuse from VCL.

Windows queries open the device with zero requested access. SCSI pass-through
requires a read/write handle and may require an elevated terminal. Before
sending commands the tool validates the Mitsumi by USB VID/PID or by USB bus
and model in the storage descriptor. The permitted CDBs have data-in or no-data
directions. USBSTOR/CBI can reject pass-through before a CDB reaches the device.

The first READ FORMAT CAPACITIES descriptor reports current capacity or the
maximum for an absent or unformatted medium. Later descriptors describe
formattable capacities for the inserted medium. The report checks those later
entries for 1440 and 2880 blocks of 512 bytes and identifies incomplete lists.
When the header announces a valid descriptor length but the response is short,
the tool retries once per transport with the header and descriptor lengths added
together as the allocation length.
Windows media types and current logical capacity are reported separately.
Firmware declarations alone do not establish that Windows can format a disk
at the declared capacity.

## Verified results

### Initial run

Both Delphi targets compiled, ran and detected the Mitsumi at `A:` with
VID/PID `03EE:6901`. The current geometry query returned 80 cylinders, 2 tracks
per cylinder, 18 sectors per track and 512 bytes per sector. The physical
medium was not independently identified. The driver declared geometries of
1,228,800, 1,261,568 and 1,474,560 bytes. Extended geometry returned Win32
error 50. Opening the pass-through handle returned Win32 error 5 in both builds.
No UFI command reached the device in this run.

### Mitsumi USB UFDD 061M on 2026-11-25

- With no disk inserted, both pass-through modes returned a single descriptor
  with code 3 and a device maximum of 2,880 blocks × 512 bytes (1,474,560 bytes).
  The source report is `mitsumi-sin-disco.txt`.
- With the MSX DD 720 KB test disk inserted, the initial 260-byte allocation
  returned SCSI status `0x00` and only the 4-byte header in both pass-through
  modes. The header announced 32 bytes of descriptors. The source report is
  `mitsumi-msx-720.txt`.
- The retry requested exactly 36 bytes and received all 36 bytes in both
  modes, with SCSI status `0x00`. The 32 descriptor bytes comprised one
  current-medium descriptor and three formattable-capacity descriptors. The
  source report is `mitsumi-msx-720-reintento.txt`.

| Formattable blocks | Bytes per block | Total bytes |
| ---: | ---: | ---: |
| 2,400 | 512 | 1,228,800 |
| 1,232 | 1,024 | 1,261,568 |
| 2,880 | 512 | 1,474,560 |

The complete list did not include the 720 KB format (1,440 × 512 bytes) for
the tested disk. The current-medium descriptor and `READ CAPACITY (10)` both
reported 2,880 blocks × 512 bytes. `IOCTL_DISK_GET_DRIVE_GEOMETRY` also
reported a 1.44 MB geometry. The diagnostic sent read-only queries.

## Hypotheses and open questions

- The cause of the earlier Windows `FORMAT` rejection remains undetermined.
  Windows formatting behavior, the storage driver and the drive firmware are
  possible factors. The complete list establishes what the drive reported
  through this Windows stack for this disk.
- The reason the initial request returned only the header remains undetermined.
- Persistence of `TEST.TXT` after physical reinsertion remains unverified.

## Reproducing the diagnostic

1. In an elevated terminal run `floppy diagnose A: --report mitsumi-empty.txt`
   with no disk in the drive.
2. Repeat with a known MSX DD 720 KB disk and a known HD 1.44 MB disk, using
   separate report names and recording which physical medium is present.
3. Compare buffered and direct results. For any accepted transport, inspect the
   current/maximum descriptor separately and check for 1440 × 512 in the
   DD formattable entries.

## References

- [USB-IF UFI Command Specification](https://www.usb.org/sites/default/files/usbmass-ufi10.pdf)
- [Microsoft SetupDiGetDeviceInterfaceDetailW](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetdeviceinterfacedetailw)
- [Microsoft Windows storage reference](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/_storage/)
- [Microsoft SCSI pass-through handling](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/handling-scsi-pass-through-requests)
