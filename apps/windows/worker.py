"""Local worker for the Flutter Windows client. Standard output carries JSON events."""
import argparse
import base64
import io
import json
import math
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from brb_tracker.detection import annotate, is_brb
from brb_tracker.models import Cue, Report
from brb_tracker.pipeline import analyze
from brb_tracker.sources import download, video_id
from brb_tracker.screen import prepare_screen
from brb_tracker.transcript import read_transcript

ARCHIVE_URL = "https://www.youtube.com/@Gamin4Hope/streams"
PAGE_SIZE = 20
SPEECH_MODEL = "vosk-model-small-en-us-0.15"


def archive_page(start):
    from yt_dlp import YoutubeDL

    if not 1 <= start <= 100_000:
        raise ValueError("Invalid archive page.")
    with YoutubeDL({
        "extract_flat": "in_playlist", "skip_download": True, "quiet": True,
        "playlist_items": f"{start}:{start + PAGE_SIZE}", "socket_timeout": 15,
        "retries": 1, "extractor_retries": 1, "ignoreerrors": True,
    }) as downloader:
        info = downloader.extract_info(ARCHIVE_URL, download=False)
    if not info or "entries" not in info:
        raise ValueError("Could not load the YouTube stream archive.")
    return format_archive_page(list(info["entries"]), start)


def format_archive_page(entries, start):
    unique = {}
    for item in entries[:PAGE_SIZE]:
        if not item or item.get("live_status") in {"is_live", "is_upcoming", "post_live"}:
            continue
        identifier = item.get("id", "")
        if not isinstance(identifier, str):
            continue
        try:
            video_id(f"https://youtu.be/{identifier}")
        except ValueError:
            continue
        title = (item.get("title") or "").strip()
        if title and title not in {"[Private video]", "[Deleted video]"}:
            unique.setdefault(identifier, title)
    return {
        "streams": [{"id": key, "title": title} for key, title in unique.items()],
        "next": start + PAGE_SIZE if len(entries) > PAGE_SIZE else None,
    }


def emit(event, **fields):
    # Child tools can write terminal status lines, so start the event on its own line.
    print("\n" + json.dumps({"event": event, **fields}), flush=True)


def configure_tools(runtime: Path | None):
    if runtime is not None:
        os.environ["PATH"] = str(runtime) + os.pathsep + os.environ.get("PATH", "")
        os.environ["TESSDATA_PREFIX"] = str(runtime / "tessdata")
    required = ("ffmpeg", "ffprobe", "tesseract")
    missing = [tool for tool in required if not shutil.which(tool)]
    if missing:
        raise ValueError(f"Re-extract the full app archive. Missing tools: {', '.join(missing)}.")


def set_source_date(report, metadata):
    if timestamp := metadata.get("release_timestamp"):
        try:
            report.stream_started_at = datetime.fromtimestamp(timestamp, tz=timezone.utc)
        except (ValueError, TypeError, OverflowError, OSError):
            pass
        else:
            report.vod_date = report.stream_started_at.date()
            report.vod_date_source = "release_timestamp"
            return
    for field in ("release_date", "upload_date"):
        value = metadata.get(field)
        if value:
            try:
                report.vod_date = datetime.strptime(value, "%Y%m%d").date()
            except ValueError:
                continue
            report.vod_date_source = field
            return


def transcribe(video, breaks, model_path, progress):
    from vosk import KaldiRecognizer, Model, SetLogLevel

    SetLogLevel(-1)
    model = Model(str(model_path))
    windows = []
    for item in breaks:
        end = item.start_seconds
        if end <= 0:
            continue
        start = max(0, end - 60)
        if windows and start <= windows[-1][1]:
            windows[-1] = (windows[-1][0], end)
        else:
            windows.append((start, end))
    options = {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}
    cues = []
    for index, (start, end) in enumerate(windows):
        progress(index / len(windows))
        recognizer = KaldiRecognizer(model, 16000)
        recognizer.SetWords(True)
        with subprocess.Popen([
            "ffmpeg", "-v", "error", "-nostdin", "-ss", str(start), "-i", str(video),
            "-t", str(end - start), "-vn", "-sn", "-ac", "1", "-ar", "16000", "-f", "s16le", "pipe:1",
        ], stdout=subprocess.PIPE, **options) as audio:
            try:
                results = []
                while chunk := audio.stdout.read(8000):
                    if recognizer.AcceptWaveform(chunk):
                        results.append(recognizer.Result())
                results.append(recognizer.FinalResult())
                if audio.wait() != 0:
                    raise ValueError("Could not read the video audio.")
            finally:
                if audio.poll() is None:
                    audio.kill()
        for result in results:
            words = json.loads(result).get("result", [])
            if words:
                cues.append(Cue(
                    start=start + words[0]["start"], end=start + words[-1]["end"],
                    text=" ".join(word["word"] for word in words),
                ))
    progress(1)
    return cues


def run(args):
    if not math.isfinite(args.limit_mbps) or (args.limit_mbps != 0 and not 0.1 <= args.limit_mbps <= 10_000):
        raise ValueError("Enter 0 for unlimited or a limit from 0.1 to 10,000 Mbps.")
    rate_limit = round(args.limit_mbps * 1_000_000 / 8) if args.limit_mbps else None
    identifier = video_id(args.url) if args.url else None
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    last_update = 0.0

    def progress(phase, fraction=None, **details):
        nonlocal last_update
        now = time.monotonic()
        if fraction == 1 or now - last_update >= 0.2:
            emit("progress", phase=phase, fraction=fraction, **details)
            last_update = now

    def transfer(update):
        if update["status"] == "downloading":
            total = update.get("total_bytes") or update.get("total_bytes_estimate")
            downloaded = update.get("downloaded_bytes", 0)
            progress("Downloading video", min(downloaded / total, 1) if total else None,
                     bytes=downloaded, speed=update.get("speed"))
        elif update["status"] == "finished":
            progress("Finishing download", 1)

    video = args.video
    captions = args.transcript
    if captions:
        read_transcript(captions)
    metadata = {}
    if video is None:
        emit("progress", phase="Reading YouTube VOD details and captions")
        video, downloaded_captions, metadata = download(
            args.url, output / "Video", height=args.height, rate_limit=rate_limit,
            progress=transfer, runtime=args.runtime, fetch_captions=captions is None,
            firefox_session=args.firefox_session,
        )
        if captions is None and downloaded_captions is not None:
            try:
                read_transcript(downloaded_captions)
            except (OSError, ValueError, TypeError):
                metadata["caption_warning"] = "Downloaded captions could not be parsed."
            else:
                captions = downloaded_captions
        emit("media", path=str(video))

    emit("progress", phase="Scanning video locally", fraction=0)
    options = dict(
        title=metadata.get("title") or args.title or video.stem,
        identifier=identifier,
        source_url=f"https://www.youtube.com/watch?v={identifier}" if identifier else "",
        interval=args.interval,
        profile=args.profile,
        refine=args.interval == 5,
        progress=lambda fraction: progress("Scanning video locally", fraction),
    )
    report = analyze(video, captions, **options)
    if args.speech_fallback and report.breaks and any(
        warning.startswith("No usable transcript:") for warning in report.warnings
    ):
        try:
            runtime = args.runtime or Path(os.environ.get("BRB_WINDOWS_TOOLS", "."))
            emit("progress", phase="Transcribing speech before breaks", fraction=0)
            cues = transcribe(video, report.breaks, runtime / SPEECH_MODEL,
                              lambda fraction: progress("Transcribing speech before breaks", fraction))
            if cues:
                annotate(report.breaks, cues)
                report.transcript_source = "local-speech/vosk-en"
                report.warnings = [w for w in report.warnings if not w.startswith("No usable transcript:")]
                report.warnings.append("Reasons use local English speech recognition. Review the suggestions.")
        except Exception:
            report.warnings.append("Local speech recognition could not read the audio or load the English model.")

    if warning := metadata.get("caption_warning"):
        report.warnings.append(warning)
    set_source_date(report, metadata)
    if args.previous_report and not report.vod_date:
        try:
            previous = Report.model_validate_json(args.previous_report.read_bytes())
            if previous.video_id == report.video_id:
                report.vod_date = previous.vod_date
                report.vod_date_source = previous.vod_date_source
                report.stream_started_at = previous.stream_started_at
        except (OSError, ValueError):
            report.warnings.append("Could not restore the VOD date from the previous report.")
    report.analyzed_at = datetime.now(timezone.utc)
    report_path = output / "report.json"
    pending = output / "report.json.tmp"
    pending.write_text(report.model_dump_json(indent=2) + "\n", encoding="utf-8")
    pending.replace(report_path)
    if args.delete_after_scan and args.video is None:
        try:
            video.unlink()
        except OSError:
            emit("progress", phase="The video could not be deleted. Use the scan menu to remove it.")
    emit("complete", path=str(report_path), report=report.model_dump(mode="json"))


def check_banner(path, timestamp, profile):
    from PIL import Image
    import pytesseract

    if timestamp is None:
        source = path
    else:
        if not math.isfinite(timestamp) or timestamp < 0:
            raise ValueError("Enter a timestamp at or after the start of the VOD.")
        options = {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}
        raw = subprocess.check_output([
            "ffmpeg", "-v", "error", "-nostdin", "-ss", str(timestamp), "-i", str(path),
            "-an", "-sn", "-frames:v", "1", "-f", "image2pipe", "-c:v", "png", "pipe:1",
        ], timeout=30, **options)
        if not raw:
            raise ValueError("No video frame at that timestamp.")
        source = io.BytesIO(raw)
    with Image.open(source) as original:
        original.thumbnail((960, 960))
        width, height = original.size
        mask = prepare_screen(original.convert("RGB"), profile)
    text = ""
    png = io.BytesIO()
    if mask is not None:
        text = pytesseract.image_to_string(mask, config="--psm 11", timeout=20).strip()
        mask.save(png, format="PNG")
    emit("banner", width=width, height=height, matched=is_brb(text), text=text,
         mask=base64.b64encode(png.getvalue()).decode("ascii"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--catalog-start", type=int)
    parser.add_argument("--title")
    parser.add_argument("--video", type=Path)
    parser.add_argument("--url")
    parser.add_argument("--transcript", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--interval", type=float, choices=(2, 5), default=2)
    parser.add_argument("--profile", choices=("gamin4hope", "full_frame"), default="gamin4hope")
    parser.add_argument("--height", type=int, choices=(360, 480, 720, 1080), default=480)
    parser.add_argument("--limit-mbps", type=float, default=5)
    parser.add_argument("--firefox-session", action="store_true")
    parser.add_argument("--delete-after-scan", action="store_true")
    parser.add_argument("--speech-fallback", action="store_true")
    parser.add_argument("--previous-report", type=Path)
    parser.add_argument("--check-banner", type=Path)
    parser.add_argument("--frame-at", type=float)
    args = parser.parse_args()
    try:
        if args.catalog_start is not None:
            emit("catalog", page=archive_page(args.catalog_start))
            return 0
        configure_tools(args.runtime)
        if args.self_test:
            from yt_dlp.version import __version__

            if args.runtime:
                from vosk import Model, SetLogLevel

                SetLogLevel(-1)
                Model(str(args.runtime / SPEECH_MODEL))
            emit("ready", downloader=__version__)
            return 0
        if args.check_banner:
            check_banner(args.check_banner, args.frame_at, args.profile)
            return 0
        if not args.output or not (args.url or args.video):
            raise ValueError("Select a VOD or local video and an output folder.")
        run(args)
    except Exception as exc:
        message = str(exc)
        lower = message.lower()
        if "not a bot" in lower or "sign in to confirm" in lower:
            if args.firefox_session:
                message = ("YouTube still requires verification. Check that this VOD plays in your signed-in "
                           "Firefox window, then retry. You can also scan a saved copy.")
            else:
                message = ("Sign in to YouTube in Firefox, enable Use Firefox sign-in in Scan options, "
                           "then queue this VOD again.")
        elif args.firefox_session and any(term in lower for term in (
            "firefox cookies database", "failed to load cookies", "sqlite", "database is locked",
        )):
            message = ("The app could not read your Firefox session. Open this VOD in a regular "
                       "signed-in Firefox window, close Firefox, and retry the scan.")
        emit("error", message=message[-900:] or "The scan failed.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
