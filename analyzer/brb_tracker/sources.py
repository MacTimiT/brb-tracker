import re
import time
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs, urlparse


def video_id(url: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError("Use an HTTPS YouTube VOD URL")
    host = (parsed.hostname or "").lower()
    if host == "youtu.be":
        candidate = parsed.path.strip("/")
    elif host in {"youtube.com", "www.youtube.com", "m.youtube.com"}:
        parts = parsed.path.strip("/").split("/")
        if parts[0] in {"live", "shorts"} and len(parts) == 2:
            candidate = parts[1]
        elif parsed.path == "/watch":
            candidate = parse_qs(parsed.query).get("v", [""])[0]
        else:
            candidate = ""
    else:
        candidate = ""
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", candidate):
        raise ValueError("Expected one YouTube video, not a channel or playlist")
    return candidate


def _limit_response(response, rate: int, block_size: int):
    """Pace native downloader reads with a high-resolution clock."""
    original_read = response.read

    def read(amt=None):
        size = -1 if amt is None else amt
        chunks = []
        while size != 0:
            start = time.perf_counter()
            chunk = original_read(block_size if size < 0 else min(size, block_size))
            if not chunk:
                break
            delay = len(chunk) / rate - (time.perf_counter() - start)
            if delay > 0:
                time.sleep(delay)
            chunks.append(chunk)
            if size > 0:
                size -= len(chunk)
        return b"".join(chunks)

    response.read = read
    return response


def download(
    url: str, directory: Path, *, height: int = 480, rate_limit: int | None = None,
    progress: Callable[[dict], None] | None = None, runtime: Path | None = None,
    fetch_captions: bool = True,
) -> tuple[Path, Path | None, dict]:
    import yt_dlp

    identifier = video_id(url)
    if height not in (360, 480, 720, 1080) or (rate_limit is not None and rate_limit <= 0):
        raise ValueError("Invalid download quality or speed limit")
    directory.mkdir(parents=True, exist_ok=True)
    options = {
        "outtmpl": str(directory / "vod.%(ext)s"),
        "format": f"best[height<={height}][ext=mp4]/best[height<={height}]/bestvideo[height<={height}]+bestaudio",
        "merge_output_format": "mp4",
        "noplaylist": True,
        "writesubtitles": True,
        "writeautomaticsub": True,
        "subtitleslangs": ["en", "en-orig"],
        "subtitlesformat": "json3/vtt",
        "max_filesize": 8 * 1024**3,
        "socket_timeout": 30,
        "retries": 2,
        "quiet": True,
        "no_warnings": False,
    }
    block_size = max(1, min(rate_limit // 10, 64 * 1024)) if rate_limit is not None else 0
    if rate_limit is not None:
        # Use yt-dlp's own downloader and one fragment at a time so media transfers
        # share one limit. FFmpeg can still merge tracks locally afterward.
        transport = "[protocol~='^(https?|m3u8_native|http_dash_segments)$']"
        quality = f"[height<={height}]{transport}"
        options.update(
            concurrent_fragment_downloads=1, hls_prefer_native=True,
            buffersize=block_size, noresizebuffer=True,
            format=f"best{quality}[ext=mp4]/best{quality}/bestvideo{quality}+bestaudio{transport}",
        )
    if runtime is not None:
        options.update(
            ffmpeg_location=str(runtime),
            js_runtimes={"deno": {"path": str(runtime / "deno.exe")}},
            skip_unavailable_fragments=False,
        )
    canonical = f"https://www.youtube.com/watch?v={identifier}"

    class MediaDownloader(yt_dlp.YoutubeDL):
        def urlopen(self, request):
            response = super().urlopen(request)
            return _limit_response(response, rate_limit, block_size) if rate_limit is not None else response

    with yt_dlp.YoutubeDL(options) as ydl:
        info = ydl.extract_info(canonical, download=False)
        if info.get("is_live"):
            raise ValueError("Wait until the livestream has ended before analyzing its VOD")
        # Subtitle failures must not prevent video-only OCR analysis. Fetch
        # captions separately, then download media with caption writes disabled.
        caption_error = None
        if fetch_captions:
            try:
                with MediaDownloader({**options, "skip_download": True}) as caption_ydl:
                    caption_ydl.download([canonical])
            except yt_dlp.utils.DownloadError:
                caption_error = "YouTube captions could not be downloaded; reason suggestions may be unavailable."
        with MediaDownloader({
            **options, "writesubtitles": False, "writeautomaticsub": False,
            "noprogress": progress is not None,
            "progress_hooks": [progress] if progress is not None else [],
        }) as media_ydl:
            media_ydl.download([canonical])
    videos = [p for p in directory.iterdir() if p.suffix in {".mp4", ".mkv", ".webm"} and p.is_file() and p.stat().st_size > 0]
    if not videos:
        raise RuntimeError("No video downloaded; check YouTube availability and disk space")
    captions = sorted(directory.glob("*.json3")) or sorted(directory.glob("*.vtt"))
    metadata = {"id": identifier, "title": info.get("title", identifier), "url": canonical}
    for field in ("release_timestamp", "release_date", "upload_date"):
        if info.get(field) is not None:
            metadata[field] = info[field]
    if caption_error:
        metadata["caption_warning"] = caption_error
    return videos[0], captions[0] if captions else None, metadata
