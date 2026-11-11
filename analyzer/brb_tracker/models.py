from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, Field, model_validator


class Reason(StrEnum):
    PEE = "Pee"
    SNACK = "Snack"
    DRINK = "Drink"
    STRETCH = "Stretch"
    TECH = "Technical"
    OTHER = "Other"
    UNKNOWN = "Unknown"


class Cue(BaseModel):
    start: float = Field(ge=0)
    end: float = Field(ge=0)
    text: str

    @model_validator(mode="after")
    def ordered(self):
        if self.end < self.start:
            raise ValueError("Cue end must follow start")
        return self


class Break(BaseModel):
    start_seconds: float = Field(ge=0)
    end_seconds: float = Field(ge=0)
    reason: Reason = Reason.UNKNOWN
    suggested_reason: Reason = Reason.UNKNOWN
    confidence: Literal["unknown", "keyword", "manual"] = "unknown"
    evidence: str = ""
    reviewed: bool = False
    truncated: bool = False

    @model_validator(mode="after")
    def ordered(self):
        if self.end_seconds < self.start_seconds:
            raise ValueError("Break end must follow start")
        return self

    @property
    def duration(self) -> float:
        return self.end_seconds - self.start_seconds


class Report(BaseModel):
    schema_version: int = 1
    id: str
    title: str
    streamer: str = "Gamin4Hope"
    source_url: str = ""
    video_id: str | None = None
    duration_seconds: float = Field(ge=0)
    sample_interval_seconds: float = Field(gt=0)
    transcript_source: str = "none"
    detector_profile: Literal["full_frame", "gamin4hope"] = "full_frame"
    is_demo: bool = False
    warnings: list[str] = Field(default_factory=list)
    breaks: list[Break] = Field(default_factory=list)

    @model_validator(mode="after")
    def timeline(self):
        previous_end = 0.0
        for item in self.breaks:
            if item.start_seconds < previous_end or item.end_seconds > self.duration_seconds:
                raise ValueError("Breaks must be ordered, non-overlapping and inside the VOD")
            previous_end = item.end_seconds
        return self
