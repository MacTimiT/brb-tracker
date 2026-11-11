import hmac
import os
import shutil
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field, field_validator

from .models import Reason
from .pipeline import analyze
from .sources import download, video_id
from .store import Store


class Submission(BaseModel):
    url: str = Field(max_length=500)

    @field_validator("url")
    @classmethod
    def youtube_only(cls, value):
        return f"https://www.youtube.com/watch?v={video_id(value)}"


class Review(BaseModel):
    reason: Reason


def create_app(directory: Path | None = None, token: str | None = None) -> FastAPI:
    directory = directory or Path(os.environ.get("BRB_DATA_DIR", "data"))
    token = token if token is not None else os.environ.get("BRB_API_TOKEN", "")
    store = Store(directory)
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="vod-analysis")

    @asynccontextmanager
    async def lifespan(app):
        store.interrupted()
        yield
        executor.shutdown(wait=True, cancel_futures=True)

    def auth(authorization: str = Header(default="")):
        if token and not hmac.compare_digest(authorization.encode(), f"Bearer {token}".encode()):
            raise HTTPException(401, "A valid Bearer API token is required")

    app = FastAPI(title="BRB Tracker", version="0.1.0", lifespan=lifespan)

    def work(identifier: str, url: str):
        folder = directory / "work" / identifier
        try:
            store.update(identifier, status="running")
            video, captions, metadata = download(url, folder)
            last_percent = -1

            def progress(value):
                nonlocal last_percent
                percent = int(value * 100)
                if percent != last_percent:
                    store.update(identifier, progress=value)
                    last_percent = percent

            report = analyze(video, captions, title=metadata["title"], source_url=url,
                             identifier=metadata["id"], progress=progress)
            report.id = identifier
            if metadata.get("caption_warning"):
                report.warnings.append(metadata["caption_warning"])
            store.update(identifier, status="completed", progress=1, report=report)
        except Exception as exc:
            # Keep failure visible and actionable; don't return server paths or
            # download URLs to clients. Details can be inspected on the host.
            import logging
            logging.getLogger(__name__).exception("Analysis failed for %s", identifier)
            store.update(identifier, status="failed", error=f"{type(exc).__name__}: analysis failed. Check host logs, YouTube access and captions; local-file CLI is available.")
        finally:
            shutil.rmtree(folder, ignore_errors=True)

    @app.get("/health")
    def health():
        return {"status": "ok", "version": "0.1.0", "authentication_required": bool(token)}

    @app.get("/jobs", dependencies=[Depends(auth)])
    def jobs():
        return store.list()

    @app.post("/jobs", status_code=202, dependencies=[Depends(auth)])
    def submit(submission: Submission):
        identifier = str(uuid.uuid4())
        try:
            store.create(identifier, submission.url)
        except ValueError as exc:
            raise HTTPException(429, str(exc)) from exc
        executor.submit(work, identifier, submission.url)
        return store.get(identifier)

    @app.get("/jobs/{identifier}", dependencies=[Depends(auth)])
    def job(identifier: str):
        result = store.get(identifier)
        if result is None:
            raise HTTPException(404, "Job not found")
        return result

    @app.patch("/jobs/{identifier}/breaks/{index}", dependencies=[Depends(auth)])
    def review(identifier: str, index: int, correction: Review):
        try:
            return store.review(identifier, index, correction.reason)
        except (KeyError, IndexError) as exc:
            raise HTTPException(404, "Completed job or break not found") from exc

    @app.get("/reports", dependencies=[Depends(auth)])
    def reports():
        return {"schema_version": 1, "reports": store.reports()}

    return app
