import pytest

from brb_tracker.detection import categorize, find_breaks, is_brb
from brb_tracker.models import Cue, Reason
from brb_tracker.sources import video_id
from brb_tracker.transcript import read_vtt


def test_ocr_phrase_normalization():
    assert is_brb("BE\nRIGHT BACK!")
    assert not is_brb("I'll be right backward")
    assert not is_brb("BRB")


def test_dropout_timing_and_short_false_positive():
    samples = [(0, False), (2, True), (4, False), (6, True), (8, True),
               (10, False), (12, True), (14, False), (16, False)]
    breaks = find_breaks(samples, 18)
    assert [(b.start_seconds, b.end_seconds) for b in breaks] == [(6, 14)]
    assert not breaks[0].truncated


def test_eof_is_truncated_and_no_detection_is_empty():
    assert find_breaks([(0, False), (2, False)], 4) == []
    item = find_breaks([(0, True), (2, True)], 4)[0]
    assert item.truncated and item.duration == 4
    assert find_breaks([(0, True)], 1) == []


def test_breaks_stay_separate_and_input_order_is_checked():
    samples = [(float(i), present) for i, present in enumerate([1, 1, 0, 0, 1, 1, 0, 0])]
    assert len(find_breaks(samples, 8)) == 2
    with pytest.raises(ValueError):
        find_breaks([(2, True), (1, False)], 4)


def test_only_preceding_transcript_is_used():
    cues = [Cue(start=80, end=85, text="I gotta pee. Be right back."),
            Cue(start=99, end=101, text="I'm grabbing a snack"),
            Cue(start=110, end=115, text="I need water")]
    assert categorize(cues, 100)[0] == Reason.PEE
    assert "snack" not in categorize(cues, 100)[1]
    assert categorize(cues, 200)[0] == Reason.UNKNOWN


@pytest.mark.parametrize("speech,expected", [
    ("I'm going to grab a snack", Reason.SNACK),
    ("I need to refill my water", Reason.DRINK),
    ("I need to stretch", Reason.STRETCH),
    ("Let me fix my mic", Reason.TECH),
    ("I don't need to pee", Reason.UNKNOWN),
    ("I need a snack and a drink", Reason.UNKNOWN),
    ("The game has a bathroom", Reason.UNKNOWN),
    ("I'll be right back", Reason.UNKNOWN),
])
def test_conservative_reasons(speech, expected):
    assert categorize([Cue(start=5, end=8, text=speech)], 10)[0] == expected


def test_vtt_parsing_and_rolling_duplicates():
    content = "WEBVTT\n\n00:00:02.000 --> 00:00:04.000 align:start\n<v Speaker>I need &amp; want water</v>\n\n00:00:04.000 --> 00:00:06.000\nI need &amp; want water\n"
    cues = read_vtt(content)
    assert len(cues) == 1
    assert cues[0].start == 2 and cues[0].end == 6
    assert cues[0].text == "I need & want water"


@pytest.mark.parametrize("url", ["https://www.youtube.com/live/IW2rEIuKGSs", "https://youtu.be/IW2rEIuKGSs?t=20", "https://youtube.com/watch?v=IW2rEIuKGSs&list=abc"])
def test_youtube_url(url):
    assert video_id(url) == "IW2rEIuKGSs"


@pytest.mark.parametrize("url", ["http://youtube.com/watch?v=IW2rEIuKGSs", "https://youtube.com.evil.com/watch?v=IW2rEIuKGSs", "https://localhost/", "https://youtube.com/playlist?list=abc", "https://youtube.com:444/watch?v=IW2rEIuKGSs"])
def test_reject_other_sources(url):
    with pytest.raises(ValueError):
        video_id(url)
