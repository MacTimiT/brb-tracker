# BRB Tracker

BRB Tracker scans Gamin4Hope VODs for the “Be Right Back” screen, times each break, and suggests reasons from captions or on-device speech recognition. The Android app handles scanning and review. The public GONE4HOPE dashboard shows reports published from the app.

[Download the Android app](https://github.com/MacTimiT/brb-tracker/releases/latest) · [Open the dashboard](https://mactimit.github.io/brb-tracker/)

## Scan a stream on Windows

The [Windows x64 preview](https://github.com/MacTimiT/brb-tracker/releases/tag/windows-v0.1.0) downloads and scans YouTube VODs or scans a video already on your computer. Extract the ZIP and open **brb_tracker_windows.exe**. The media download cap defaults to **5 Mbps** and can be changed in the app. Reports and completed downloads are saved locally. [Windows usage and build guide](apps/windows/README.md)

## Scan a stream on Android

1. Download the signed APK under **Assets** and open it on a 64-bit Android 8.0 or newer phone. Update by opening the newer APK. [Updates from older previews](docs/android-updates.md)
2. In **VODs**, tap an unscanned stream to add it to the queue. The archive shows the latest cached page while it refreshes. Use **Scanned** or **Unscanned** to filter the loaded VODs and **Load older streams** to extend those views. A checkmark opens a saved report.
3. In **Scan options**, choose the download quality, scan mode, banner profile, and speech fallback. The app remembers these options for future scans. Use this tab to queue a pasted YouTube link or a local MP4. **Detailed** mode samples every two seconds. **Full frame** covers layouts outside the red bottom-left banner.
4. In **Scans**, follow download and scan progress. The phone processes queued VODs one at a time. Tap a finished scan to review its reasons, quotes, and timestamps. English speech recognition can fill in missing captions near detected breaks. The first use downloads a 41 MB model.

Use **Up next** to move scans forward and **Retry failed scans** to requeue failures. **Downloads on this phone** shows storage used by retained videos and can delete downloads that the queue is no longer using. **Scan details** records elapsed download, decoding, OCR, and speech times when those steps run.

Finished YouTube downloads stay on the phone by default, including when the scan fails. **Auto-delete new videos after successful scans** can free space once the report is saved. In the scan’s action menu, use **Rescan saved video**, **Export video to Downloads**, or **Delete downloaded video**. A rescan creates a separate report, and deleting a video keeps the existing reports and edits. The exported MP4 may be video-only. Settings for a queued scan are captured when you add it.

YouTube downloads can fail when media access is restricted. You can still scan a local video you are allowed to process. Long VODs need free storage and time for the download and scan.

## Publish a report

Open **GitHub publishing settings** using the gear button. Use a fine-grained GitHub token limited to the dashboard repository with **Contents: Read and write**. The app stores the token on the phone.

Choose one primary reason for each break and add other reasons when the transcript supports them. The leaderboard counts every assigned reason and attributes the time away to the primary reason. Overall totals count each break once.

Tap **Publish to dashboard** on a reviewed report. This sends report JSON, including its transcript quotes, to the repository. Publishing the same YouTube VOD replaces its published report. The live dashboard reads the report file from the public `main` branch on page load and on **Refresh**. GitHub may cache the data for up to five minutes. Pages deploys when the site files change. Local dashboard previews read their local copy of `docs/data/reports.json`.

The dashboard estimates Twitch viewer-hours using each matched broadcast's average concurrent audience and time away. The separate Twitch viewership workflow refreshes the matches after reports are published and twice a day. Its data updates do not trigger a Pages deployment.

## Run the optional Python analyzer

Install Python 3.11+, FFmpeg, and Tesseract with English language data. Install DejaVu fonts to run the OCR tests.

```sh
python -m venv .venv
. .venv/bin/activate
python -m pip install -e '.[dev]'
brb-tracker analyze --video vod.mp4 --output data/report.json
```

Use `--transcript` to import VTT, JSON3, or a JSON array of cues with `start`, `end`, and `text`. For local English speech recognition, install `.[transcribe]` and use `--whisper`. See `brb-tracker --help` for the API service and export commands.

## Development

From the repository root:

```sh
pytest -q
npm ci
npm test
node --check docs/app.js
python -m http.server 8080 --directory docs
```

From `apps/mobile` with the Flutter SDK and Android toolchain:

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

GitHub Actions also runs native tests on an Android emulator. The Android app is distributed under [GPL-3.0](apps/mobile/LICENSE). [Android dependency notices](apps/mobile/THIRD_PARTY_NOTICES.md)
