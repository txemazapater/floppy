# Diagnostic baseline

- Mitsumi USB UFDD 061M, VID 03EE PID 6901, revision 0200.
- Windows 11 native USBSTOR_CBI.NT driver.
- Initial Code 10 cleared after disconnect/reconnect without media.
- MSX FAT volume: 730112 usable bytes; 716800 free before test write.
- COMMAND.COM, MSXDOS.SYS and AUTOEXEC.BAT copied successfully.
- TEST.TXT appeared in directory after copying from Windows; reinsertion verification pending.
- FORMAT /F:720 and /T:80 /N:9 rejected parameters on a DD disk.
- Hypothesis: formatting geometry rejected by Windows or firmware; layer not established.
