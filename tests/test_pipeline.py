"""Real FFmpeg + Tesseract integration: validates timing and reason flow."""
import subprocess
import sys
from pathlib import Path

from brb_tracker.models import Reason
from brb_tracker.pipeline import analyze


def test_real_ocr_pipeline(tmp_path):
    script = Path(__file__).resolve().parents[1] / "scripts" / "make_fixture.py"
    subprocess.run([sys.executable, str(script), str(tmp_path)], check=True)
    report = analyze(tmp_path / "synthetic.mp4", tmp_path / "transcript.json", interval=2)
    assert len(report.breaks) == 2
    first, last = report.breaks
    assert abs(first.start_seconds - 6) <= 2
    assert abs(first.end_seconds - 14) <= 2
    assert first.reason == Reason.PEE
    assert last.reason == Reason.SNACK and last.truncated
    assert abs(last.end_seconds - 24) < 0.2


def test_report_preserves_original_vod_date_separately_from_scan_timestamp():
    from brb_tracker.models import Report
    report = Report(id="historical", title="Historical VOD", duration_seconds=100,
                    sample_interval_seconds=5, vod_date="2026-10-22",
                    vod_date_source="release_timestamp", analyzed_at="2026-11-12T12:00:00Z")
    exported = report.model_dump(mode="json")
    assert exported["vod_date"] == "2026-10-22"
    assert exported["analyzed_at"].startswith("2026-11-12")
    assert Report(id="legacy", title="Legacy", duration_seconds=100,
                  sample_interval_seconds=2).vod_date is None
