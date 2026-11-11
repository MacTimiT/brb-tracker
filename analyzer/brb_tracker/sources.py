import re
from pathlib import Path
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


def download(url: str, directory: Path) -> tuple[Path, Path | None, dict]:
    import yt_dlp

    identifier = video_id(url)
    directory.mkdir(parents=True, exist_ok=True)
    options = {
        "outtmpl": str(directory / "vod.%(ext)s"),
        "format": "best[height<=480][ext=mp4]/best[height<=480]/bestvideo[height<=480]+bestaudio",
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
    canonical = f"https://www.youtube.com/watch?v={identifier}"
    with yt_dlp.YoutubeDL(options) as ydl:
        info = ydl.extract_info(canonical, download=False)
        if info.get("is_live"):
            raise ValueError("Wait until the livestream has ended before analyzing its VOD")
        # Subtitle failures must not prevent video-only OCR analysis. Fetch
        # captions separately, then download media with caption writes disabled.
        caption_error = None
        try:
            with yt_dlp.YoutubeDL({**options, "skip_download": True}) as caption_ydl:
                caption_ydl.download([canonical])
        except yt_dlp.utils.DownloadError as exc:
            caption_error = str(exc)
        with yt_dlp.YoutubeDL({**options, "writesubtitles": False, "writeautomaticsub": False}) as media_ydl:
            media_ydl.download([canonical])
    videos = [p for p in directory.iterdir() if p.suffix in {".mp4", ".mkv", ".webm"}]
    if not videos:
        raise RuntimeError("No video downloaded; check YouTube availability and disk space")
    captions = sorted(directory.glob("*.json3")) or sorted(directory.glob("*.vtt"))
    metadata = {"id": identifier, "title": info.get("title", identifier), "url": canonical}
    if caption_error:
        metadata["caption_warning"] = "YouTube captions could not be downloaded; reason suggestions may be unavailable."
    return videos[0], captions[0] if captions else None, metadata
