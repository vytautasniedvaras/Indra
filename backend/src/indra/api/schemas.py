"""Pydantic wire types. The implemented contract is documented in docs/api.md."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class ErrorBody(BaseModel):
    code: str
    message: str
    details: dict[str, Any] = Field(default_factory=dict)


class ErrorResponse(BaseModel):
    error: ErrorBody


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"


class ProjectResponse(BaseModel):
    root: str
    format_version: int
    engine_version: str


class ImportRequest(BaseModel):
    path: str
    mode: Literal["copy", "reference"] = "reference"


class JobCreatedResponse(BaseModel):
    job_id: str


class AudioFile(BaseModel):
    id: str
    orig_path: str
    stored_path: str
    mode: Literal["copy", "reference"]
    sr: int
    channels: int
    frames: int
    duration_s: float
    format: str
    imported_at: str


class WaveformLod(BaseModel):
    lod: int
    bucket_samples: int
    buckets: int


class SpecLod(BaseModel):
    lod: int
    frames: int
    frames_per_column: int  # STFT hops aggregated per pyramid column


class SpecManifest(BaseModel):
    n_fft: int
    hop: int
    window: str
    n_bins: int
    db_min: float
    db_max: float
    mono_downmix: bool
    lods: list[SpecLod]


class FileManifest(BaseModel):
    id: str
    sr: int
    channels: int
    frames: int
    duration_s: float
    format: str
    waveform_lods: list[WaveformLod]
    spec: SpecManifest | None = None
    features: list[str] = Field(default_factory=list)


class JobInfo(BaseModel):
    id: str
    kind: str
    state: Literal["queued", "running", "cancelled", "failed", "done"]
    progress: float
    message: str
    eta_s: float | None
    created_at: float
    started_at: float | None
    finished_at: float | None
    result_ref: dict[str, Any] | None
    error: dict[str, Any] | None


class CancelResponse(BaseModel):
    cancelled: bool


class Region(BaseModel):
    t0: float | None = None
    t1: float | None = None
    f0: float | None = None
    f1: float | None = None


class AnalyzeRequest(BaseModel):
    kind: str
    audio_id: str = ""
    params: dict[str, Any] = Field(default_factory=dict)
    region: Region | None = None
