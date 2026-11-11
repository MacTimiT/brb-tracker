import json
import math
import subprocess
import uuid
from pathlib import Path
from typing import Callable

from .detection import annotate, find_breaks, is_brb
from .models import Cue, Report
from .screen import PROFILES, prepare_screen
from .transcript import read_transcript


def analyze(
    video: Path, transcript: Path | None = None, *, title: str = "Local VOD",
    source_url: str = "", identifier: str | None = None, streamer: str = "Gamin4Hope",
    interval: float = 2, min_hits: int = 2, end_misses: int = 2,
    lookback: float = 60, phrase: str = "be right back", whisper: bool = False,
    profile: str = "full_frame",
    progress: Callable[[float], None] = lambda _: None,
) -> Report:
    from PIL import Image
    import pytesseract

    if not math.isfinite(interval) or not 0.25 <= interval <= 30:
        raise ValueError("Sampling interval must be between 0.25 and 30 seconds")
    if profile not in PROFILES:
        raise ValueError("Unknown screen detector profile")
    video = video.resolve(strict=True)
    info = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(video)
    ], timeout=30))
    duration = float(info["format"]["duration"])
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Video duration must be positive and finite")
    stream = next(s for s in info["streams"] if s["codec_type"] == "video")
    width = min(int(stream["width"]), 960)
    height = round(int(stream["height"]) * width / int(stream["width"]))
    frame_bytes = width * height * 3
    process = subprocess.Popen([
        "ffmpeg", "-v", "error", "-nostdin", "-i", str(video), "-an", "-sn",
        "-vf", f"fps=1/{interval}:start_time=0,scale={width}:{height}",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ], stdout=subprocess.PIPE)
    count = 0
    try:
        def observations():
            nonlocal count
            while True:
                frame = process.stdout.read(frame_bytes)
                if not frame:
                    break
                if len(frame) != frame_bytes:
                    raise RuntimeError("Incomplete frame from FFmpeg")
                timestamp = count * interval
                count += 1
                if timestamp >= duration:
                    continue
                image = Image.frombytes("RGB", (width, height), frame)
                image = prepare_screen(image, profile)
                text = pytesseract.image_to_string(image, config="--psm 11", timeout=20) if image is not None else ""
                progress(min(timestamp / duration, 0.99))
                yield timestamp, is_brb(text, (phrase,))
        breaks = find_breaks(observations(), duration, min_hits, end_misses)
        if process.wait(timeout=30) != 0 or count == 0:
            raise RuntimeError("FFmpeg could not decode video frames")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()
    cues: list[Cue] = []
    transcript_source = "none"
    warnings = []
    if transcript:
        cues = read_transcript(transcript)
        transcript_source = transcript.suffix.lstrip(".")
    elif whisper:
        from faster_whisper import WhisperModel
        segments, _ = WhisperModel("base.en", device="cpu", compute_type="int8").transcribe(str(video))
        cues = [Cue(start=s.start, end=s.end, text=s.text) for s in segments]
        transcript_source = "faster-whisper/base.en"
    if not cues:
        warnings.append("No usable transcript: all reasons need manual review.")
    warnings.append(f"Sampled every {interval:g}s; boundaries are estimates. Short breaks and OCR failures can be missed.")
    if profile == "gamin4hope":
        warnings.append("Gamin4Hope profile: OCR checks red banner text in the bottom-left region, excluding the right-side chat. Other layouts can be missed.")
    progress(1)
    return Report(
        id=identifier or str(uuid.uuid4()), title=title, streamer=streamer,
        video_id=identifier, source_url=source_url, duration_seconds=duration,
        sample_interval_seconds=interval, transcript_source=transcript_source,
        detector_profile=profile,
        warnings=warnings, breaks=annotate(breaks, cues, lookback),
    )
