# BRB Tracker

BRB Tracker scans Gamin4Hope VODs for the “Be Right Back” screen, times each break, and suggests reasons from captions or on-device speech recognition. The Android app handles scanning and review. The public GONE4HOPE dashboard shows reports published from the app.

[Download the Android app](https://github.com/MacTimiT/brb-tracker/releases/latest) · [Open the dashboard](https://mactimit.github.io/brb-tracker/)

## Scan a stream on Android

1. Download the signed APK under **Assets** and open it on a 64-bit Android 8.0 or newer phone. Update by opening the newer APK. [Updates from older previews](docs/android-updates.md)
2. Tap **Browse Gamin4Hope streams** to find a VOD. The list loads as you scroll, newest first. A checkmark opens a completed report saved on this phone. You can also paste a YouTube VOD link or choose an MP4 under **Files & detection settings**.
3. Tap **Scan VOD**. The app looks for the red banner in the bottom-left corner, away from chat. Use **Full frame** for other layouts. **Detailed** samples every two seconds and can catch screens that a faster scan misses.
4. Open the saved report and review each suggested reason against its quote and YouTube timestamp. Offline English speech recognition can fill in missing captions around detected breaks. Its first use downloads a 41 MB model. Leave uncertain reasons as **Unknown**.

YouTube downloads can fail when media access is restricted. You can still scan a local video you are allowed to process. Long VODs need free storage and time for the download and scan.

## Publish a report

In the app menu, open **GitHub publishing settings**. Use a fine-grained GitHub token limited to the dashboard repository with **Contents: Read and write**. The app stores the token on the phone.

Tap **Publish to dashboard** on a reviewed report. This sends report JSON, including its transcript quotes, to the repository. Publishing the same YouTube VOD replaces its published report. GitHub Pages deploys automatically from `docs/`. The dashboard provides filters, timelines, timestamp links, and CSV and JSON exports.

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
