"""Local worker for the Flutter Windows client. Standard output carries JSON events."""
import argparse
import json
import math
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from brb_tracker.pipeline import analyze
from brb_tracker.sources import download, video_id
from brb_tracker.transcript import read_transcript

ARCHIVE_URL = "https://www.youtube.com/@Gamin4Hope/streams"
PAGE_SIZE = 20


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
        progress=lambda fraction: progress("Scanning video locally", fraction),
    )
    report = analyze(video, captions, **options)
    if warning := metadata.get("caption_warning"):
        report.warnings.append(warning)
    set_source_date(report, metadata)
    report.analyzed_at = datetime.now(timezone.utc)
    report_path = output / "report.json"
    pending = output / "report.json.tmp"
    pending.write_text(report.model_dump_json(indent=2) + "\n", encoding="utf-8")
    pending.replace(report_path)
    emit("complete", path=str(report_path), report=report.model_dump(mode="json"))


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
    args = parser.parse_args()
    try:
        if args.catalog_start is not None:
            emit("catalog", page=archive_page(args.catalog_start))
            return 0
        configure_tools(args.runtime)
        if args.self_test:
            from yt_dlp.version import __version__

            emit("ready", downloader=__version__)
            return 0
        if not args.output or not (args.url or args.video):
            raise ValueError("Select a VOD or local video and an output folder.")
        run(args)
    except Exception as exc:
        message = str(exc)
        if "not a bot" in message.lower():
            message = "YouTube asked for sign-in verification. Choose a saved video file to scan this VOD locally."
        emit("error", message=message[-900:] or "The scan failed.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
