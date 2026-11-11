from fastapi.testclient import TestClient

from brb_tracker.api import create_app
from brb_tracker.models import Break, Report
from brb_tracker.store import Store


def test_authenticated_review_and_export_survive_restart(tmp_path):
    store = Store(tmp_path)
    store.create("example", "https://youtube.com/watch?v=IW2rEIuKGSs")
    report = Report(id="example", title="Synthetic", duration_seconds=100, sample_interval_seconds=2,
                    breaks=[Break(start_seconds=10, end_seconds=30)])
    store.update("example", status="completed", report=report)
    with TestClient(create_app(tmp_path, "test-token")) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/jobs").status_code == 401
        headers = {"Authorization": "Bearer test-token"}
        assert client.post("/jobs", json={"url": "https://localhost"}, headers=headers).status_code == 422
        assert client.patch("/jobs/example/breaks/-1", json={"reason": "Pee"}, headers=headers).status_code == 404
        result = client.patch("/jobs/example/breaks/0", json={"reason": "Snack"}, headers=headers)
        assert result.status_code == 200
        item = result.json()["breaks"][0]
        assert item["reviewed"] and item["confidence"] == "manual" and item["reason"] == "Snack"
        assert item["suggested_reason"] == "Unknown"
        assert len(client.get("/reports", headers=headers).json()["reports"]) == 1
    with TestClient(create_app(tmp_path, "test-token")) as client:
        assert client.get("/jobs/example", headers=headers).json()["report"]["breaks"][0]["reason"] == "Snack"


def test_restart_marks_incomplete_jobs_failed_and_queue_is_bounded(tmp_path):
    store = Store(tmp_path)
    for i in range(8):
        store.create(str(i), "https://youtu.be/IW2rEIuKGSs")
    import pytest
    with pytest.raises(ValueError):
        store.create("overflow", "url")
    with TestClient(create_app(tmp_path, "")) as client:
        assert all(job["status"] == "failed" for job in client.get("/jobs").json())
