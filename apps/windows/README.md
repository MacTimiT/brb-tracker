# BRB Tracker for Windows

Extract the full Windows x64 ZIP to a folder and open **brb_tracker_windows.exe**. The portable preview runs on Windows 10 and 11. Keep the files and folders next to the executable. The preview is unsigned.

1. Paste a finished YouTube stream link, or choose a local video file. For a local video, the optional YouTube link records the source in the report.
2. Set the **Media download cap** in megabits per second. The default is **5 Mbps** (about 625 KB/s). A value of **0** allows full download speed.
3. Pick a destination and start the scan. The app saves each scan in a separate folder, keeps completed downloads, and writes a dashboard-compatible **report.json**. Open the results folder from the app when it finishes.

The cap applies to video and audio transfers. YouTube metadata requests can make short bursts. The scan runs locally with FFmpeg and Tesseract. It uses available English YouTube captions or a transcript you supply. Breaks without transcript evidence can remain **Unknown**. **Full frame** is available for VODs with a different banner layout.

If YouTube requires sign-in verification or returns no usable download, choose a saved video file to scan it locally.

## Build

On a Windows x64 machine with Flutter 3.50.0, Python 3.12, 7-Zip, and Visual Studio 2022 with the Desktop development with C++ workload, set `RUNNER_TEMP` to a temporary directory and run `apps/windows/package.ps1`. It verifies the downloaded tool checksums, builds the portable ZIP, and runs a local scan against the bundled test video.
