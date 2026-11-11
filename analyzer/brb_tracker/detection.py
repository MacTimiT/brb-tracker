"""Pure timing and reason logic, independent of OCR and network access."""
import re
from collections.abc import Iterable

from .models import Break, Cue, Reason


def is_brb(text: str, phrases: tuple[str, ...] = ("be right back",)) -> bool:
    normalized = " ".join(re.findall(r"[a-z0-9]+", text.lower()))
    return any(re.search(r"\b" + re.escape(phrase.lower()) + r"\b", normalized) for phrase in phrases)


def find_breaks(
    observations: Iterable[tuple[float, bool]], duration: float,
    min_hits: int = 2, end_misses: int = 2,
) -> list[Break]:
    """Confirm consecutive hits; tolerate end_misses-1 OCR dropouts.

    Boundaries use the first hit and first confirmed absent sample. A short
    unconfirmed hit is discarded. A screen still present at EOF is truncated.
    """
    if min_hits < 1 or end_misses < 1 or duration < 0:
        raise ValueError("Invalid detector configuration")
    result: list[Break] = []
    start = None
    hits = misses = 0
    first_miss = None
    active = False
    previous = -1.0
    for timestamp, present in observations:
        if not 0 <= timestamp <= duration or timestamp <= previous:
            raise ValueError("Observations must have increasing timestamps within the video")
        previous = timestamp
        if present:
            if start is None:
                start = timestamp
            hits += 1
            misses = 0
            first_miss = None
            active = active or hits >= min_hits
        elif not active:
            start = None
            hits = 0
        else:
            if first_miss is None:
                first_miss = timestamp
            misses += 1
            if misses >= end_misses:
                result.append(Break(start_seconds=start, end_seconds=first_miss))
                start = None
                hits = misses = 0
                first_miss = None
                active = False
    if active:
        result.append(Break(start_seconds=start, end_seconds=duration, truncated=True))
    return result


PATTERNS = {
    Reason.PEE: r"\b(pee|piss|bathroom|restroom|toilet|bio break)\b",
    Reason.SNACK: r"\b(snack|food|lunch|dinner|breakfast|sandwich|eat|eating)\b",
    Reason.DRINK: r"\b(water|drink|coffee|tea|hydrate|refill)\b",
    Reason.STRETCH: r"\b(stretch|stretching|walk|walking)\b",
    Reason.TECH: r"\b(restart|reboot|technical|fix (?:the |my )?(?:audio|mic|camera))\b",
}
INTENT = re.compile(r"\b(i|i'm|im|i’ll|i'll|gonna|going to|gotta|need to|have to|let me|grab|brb|be right back)\b", re.I)
NEGATION = re.compile(r"\b(not|don't|dont|won't|wont|isn't|isnt|never|no)\b", re.I)


def categorize(cues: list[Cue], start: float, lookback: float = 60) -> tuple[Reason, str]:
    # Only complete cues before the break; a cue spanning the transition can
    # contain speech from after the break. Keep the last five complete cues.
    recent = sorted((c for c in cues if start - lookback <= c.start and c.end <= start), key=lambda c: c.start)[-5:]
    evidence = " ".join(c.text for c in recent)
    for cue in reversed(recent):
        # Handle independent sentences separately so one negation does not
        # discard a later explicit announcement in the same caption cue.
        for sentence in reversed(re.split(r"[.!?]+", cue.text)):
            if not INTENT.search(sentence) or NEGATION.search(sentence):
                continue
            matches = [reason for reason, pattern in PATTERNS.items() if re.search(pattern, sentence, re.I)]
            if len(matches) == 1:
                return matches[0], evidence
            if len(matches) > 1:
                return Reason.UNKNOWN, evidence
    return Reason.UNKNOWN, evidence


def annotate(breaks: list[Break], cues: list[Cue], lookback: float = 60) -> list[Break]:
    for item in breaks:
        reason, evidence = categorize(cues, item.start_seconds, lookback)
        item.reason = item.suggested_reason = reason
        item.evidence = evidence
        item.confidence = "keyword" if reason != Reason.UNKNOWN else "unknown"
    return breaks
