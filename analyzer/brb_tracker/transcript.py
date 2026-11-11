import html
import json
import re
from pathlib import Path

from .models import Cue


def read_transcript(path: Path) -> list[Cue]:
    """Read portable [{start,end,text}] JSON, YouTube json3, or WebVTT."""
    if path.suffix.lower() == ".vtt":
        return read_vtt(path.read_text(encoding="utf-8-sig"))
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return [Cue.model_validate(c) for c in data]
    cues = []
    for event in data.get("events", []):
        text = "".join(s.get("utf8", "") for s in event.get("segs", []))
        if text.strip():
            start = event["tStartMs"] / 1000
            cues.append(Cue(start=start, end=start + event.get("dDurationMs", 0) / 1000, text=text.strip()))
    return cues


def _seconds(stamp: str) -> float:
    parts = stamp.split(":")
    return sum(float(value) * 60 ** index for index, value in enumerate(reversed(parts)))


def read_vtt(content: str) -> list[Cue]:
    cues: list[Cue] = []
    for block in re.split(r"\n\s*\n", content.replace("\r\n", "\n")):
        lines = block.splitlines()
        timing = next((i for i, line in enumerate(lines) if " --> " in line), None)
        if timing is None:
            continue
        left, right = lines[timing].split(" --> ", 1)
        text = html.unescape(re.sub(r"<[^>]+>", "", " ".join(lines[timing + 1:]))).strip()
        if text:
            cue = Cue(start=_seconds(left.strip()), end=_seconds(right.split()[0]), text=text)
            if cues and cue.text == cues[-1].text:
                # YouTube rolling captions repeat the same phrase. Preserve
                # earliest start and extend the end rather than duplicate text.
                cues[-1].end = max(cues[-1].end, cue.end)
            else:
                cues.append(cue)
    return cues
