# Project guidance

- Android is the primary client. Use Flutter so desktop clients can share the UI later.
- Keep OCR, timing and classification in the Python analyzer; GitHub Pages is static.
- Preserve evidence and original suggestions when saving manual corrections.
- Never label invented/demo observations as real streamer activity. Keep `is_demo` visible.
- Avoid overclaiming detection completeness or reason confidence. Unknown is valid.
- Keep video, transcript downloads, SQLite databases, tokens and signing keys out of Git.
- Verify relevant changes with `pytest -q`, `flutter analyze`, `flutter test`, `npm test`, and `node --check docs/app.js`. The OCR integration test needs FFmpeg, Tesseract English and DejaVu fonts.
- Publish dashboard exports intentionally; do not change repository visibility implicitly.
