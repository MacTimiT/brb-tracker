# Android native dependencies

The Android client is distributed under GPL-3.0 (see LICENSE), including its integration with the GPL-3.0 youtubedl-android downloader. The optional Python CLI and static dashboard are separate components.

- youtubedl-android 0.18.1, GPL-3.0: https://github.com/yausername/youtubedl-android/tree/0.18.1 — published as `io.github.junkfood02.youtubedl-android:library:0.18.1` and `ffmpeg:0.18.1`. Its unmodified published native binaries include Python, yt-dlp, QuickJS, FFmpeg and their dependencies. Upstream build scripts and source pointers are in BUILD_PYTHON.md and BUILD_FFMPEG.md at that tag. The app supports upstream yt-dlp updates.
- Tesseract4Android 4.9.0, Apache-2.0: https://github.com/adaptech-cz/Tesseract4Android/tree/4.9.0 — Tesseract, Leptonica, libjpeg and libpng retain their upstream licenses; see that project's LICENSE and dependency source notices.
- tessdata_fast English model, tag 4.1.0, Apache-2.0: https://github.com/tesseract-ocr/tessdata_fast/tree/4.1.0. Bundled `eng.traineddata` SHA-256: `7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2`.
- Vosk Android 0.3.75, Apache-2.0: https://github.com/alphacep/vosk-api — on-device speech recognition library. The English `vosk-model-small-en-us-0.15` model is downloaded from https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip on first use and stored in app-private storage. Model copyright Alpha Cephei Inc.; Apache-2.0. Archive SHA-256: `30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498`.
- Flutter and Dart package license notices are available in the app's Open-source licenses screen.

Android client source matching each development build is available in this repository at the build's commit. The generated 24-second Android test video is synthetic and contains no streamer footage.
