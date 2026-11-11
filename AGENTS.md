# Project guidance

- Android is the primary client. Use Flutter so desktop clients can share the UI later.
- Android must download, decode, OCR, time and classify VODs locally without a PC or server. Keep the Python analyzer as an optional alternative. GitHub Pages is static and receives only report JSON published from the phone.
- Preserve evidence and original suggestions when saving manual corrections.
- Never label invented/demo observations as real streamer activity. Keep `is_demo` visible.
- Avoid overclaiming detection completeness or reason confidence. Unknown is valid.
- Keep video, transcript downloads, SQLite databases, tokens and signing keys out of Git.
- Verify relevant changes with `pytest -q`, `flutter analyze`, `flutter test`, `npm test`, and `node --check docs/app.js`. The OCR integration test needs FFmpeg, Tesseract English and DejaVu fonts.
- Publish dashboard exports intentionally; do not change repository visibility implicitly.

- Default Android detection uses the Gamin4Hope red bottom-left banner profile and excludes right-side chat. Preserve the explicit full-frame fallback. Reasons come from streamer transcripts, never chat OCR.
