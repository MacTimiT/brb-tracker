import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from .models import Report


class Store:
    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / "jobs.sqlite3"
        with self.connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL,
                progress REAL NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
                error TEXT, report TEXT)""")

    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        return db

    def interrupted(self):
        with self.connect() as db:
            db.execute("UPDATE jobs SET status='failed', error='Service restarted; submit the VOD again.' WHERE status IN ('queued','running')")

    def create(self, identifier: str, url: str):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            count = db.execute("SELECT COUNT(*) FROM jobs WHERE status IN ('queued','running')").fetchone()[0]
            if count >= 8:
                raise ValueError("Queue full; wait for an analysis to finish")
            db.execute("INSERT INTO jobs(id,url,status,created_at) VALUES(?,?,'queued',?)",
                       (identifier, url, datetime.now(timezone.utc).isoformat()))

    def update(self, identifier: str, *, status=None, progress=None, error=None, report: Report | None = None):
        fields = {"status": status, "progress": progress, "error": error,
                  "report": report.model_dump_json() if report else None}
        fields = {key: value for key, value in fields.items() if value is not None}
        if not fields:
            return
        with self.connect() as db:
            db.execute("UPDATE jobs SET " + ", ".join(f"{k}=?" for k in fields) + " WHERE id=?",
                       (*fields.values(), identifier))

    def get(self, identifier: str):
        with self.connect() as db:
            row = db.execute("SELECT * FROM jobs WHERE id=?", (identifier,)).fetchone()
        if row is None:
            return None
        result = dict(row)
        result["report"] = json.loads(result["report"]) if result["report"] else None
        return result

    def list(self):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT id,url,status,progress,created_at,error FROM jobs ORDER BY created_at DESC LIMIT 100")]

    def reports(self):
        with self.connect() as db:
            return [json.loads(row[0]) for row in db.execute("SELECT report FROM jobs WHERE status='completed' ORDER BY created_at")]

    def review(self, identifier: str, index: int, reason):
        # Hold one write transaction for read/modify/write to avoid losing a
        # correction when two clients review different breaks simultaneously.
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT report FROM jobs WHERE id=?", (identifier,)).fetchone()
            if row is None or row[0] is None:
                raise KeyError(identifier)
            report = Report.model_validate_json(row[0])
            if not 0 <= index < len(report.breaks):
                raise IndexError(index)
            item = report.breaks[index]
            item.reason, item.confidence, item.reviewed = reason, "manual", True
            db.execute("UPDATE jobs SET report=? WHERE id=?", (report.model_dump_json(), identifier))
        return report
