# BRB Tracker for Windows

Extract the full Windows x64 ZIP to a folder and open **brb_tracker_windows.exe**. The portable preview runs on Windows 10 and 11. Keep the files and folders next to the executable. The preview is unsigned.

1. Open **VODs** to browse Gamin4Hope's finished streams from newest to oldest. Select a stream to queue it, or open its completed Windows report with the checkmark. Refresh the archive from the toolbar.
2. In **Scan options**, set the download cap and output folder. The cap is in megabits per second and defaults to **5 Mbps** (about 625 KB/s). A value of **0** allows full download speed. You can also queue a pasted link or a local video from this tab. A local scan can include an optional YouTube source link.
3. In **Scans**, follow progress, move waiting scans up, cancel scans, or retry failures. The app saves the settings with each queued item and processes one at a time. Waiting scans resume when you reopen the app. Use the scan menu to open the output folder, which contains the report and any completed download.
4. Open a finished scan to review and edit its reasons. The folder button in the app bar also opens a saved `report.json` from an older scan.

## Publish from Windows

Open **GitHub publishing settings** from the gear button. Enter a fine-grained GitHub token with **Contents: Read and write** for the dashboard repository. Windows stores the token securely on the device. In a finished report, select **Publish to dashboard** and confirm the repository and transcript quotes. Publishing the same YouTube video replaces its existing report and preserves other VODs.

The cap applies to video and audio transfers. YouTube metadata requests can make short bursts. The scan runs locally with FFmpeg and Tesseract. It uses available English YouTube captions or a transcript you supply. Breaks without transcript evidence can remain **Unknown**. **Full frame** is available for VODs with a different banner layout.

If YouTube requires sign-in verification or returns no usable download, choose a saved video file to scan it locally.

## Build

On a Windows x64 machine with Flutter 3.50.0, Python 3.12, 7-Zip, and Visual Studio 2022 with the Desktop development with C++ workload, set `RUNNER_TEMP` to a temporary directory and run `apps/windows/package.ps1`. It verifies the downloaded tool checksums, builds the portable ZIP, and runs a local scan against the bundled test video.
