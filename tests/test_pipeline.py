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
