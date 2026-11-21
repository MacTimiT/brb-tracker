from datetime import UTC, datetime
from pathlib import Path
import runpy

updater = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts" / "update_twitch_viewership.py"))
StreamsTable = updater["StreamsTable"]
match_streams = updater["match_streams"]


def test_matches_a_finished_broadcast_by_start_and_end():
    table = StreamsTable()
    table.feed("""<table id="streams">
      <tr><th>Stream</th><th>Duration</th><th>Avg Viewers</th></tr>
      <tr><td><i title="Current Stream"></i>2026-11-12 14:05</td><td>420</td><td>500</td></tr>
      <tr><td><i title="Past Stream"></i>2026-11-12 02:28</td><td>126</td><td>33</td></tr>
      <tr><td><i title="Past Stream"></i>2026-11-12 14:05</td><td>419</td><td>229</td></tr>
    </table>""")
    report = {
        "video_id": "9YP_ljMuDQM",
        "stream_started_at": "2026-11-12T14:05:09Z",
        "duration_seconds": 25234,
    }
    results = match_streams([report], table.streams, {})
    assert results[report["video_id"]]["average_viewers"] == 229
    assert match_streams([report], [], results) == results
    assert match_streams([{**report, "duration_seconds": 600}], [], results) == {}

    overlapping = (datetime(2026, 11, 12, 14, 6, tzinfo=UTC), 419, 120)
    assert match_streams([report], [*table.streams, overlapping], results) == {}
    assert match_streams([report, {**report, "video_id": "duplicate01"}], table.streams, {}) == {}
