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


class AnnotationCreate(BaseModel):
    audio_id: str
    t0: float
    t1: float
    f0: float | None = None
    f1: float | None = None
    label: str | None = None
    note: str | None = None


class AnnotationPatch(BaseModel):
    t0: float | None = None
    t1: float | None = None
    f0: float | None = None
    f1: float | None = None
    label: str | None = None
    note: str | None = None


class AnnotationRecord(BaseModel):
    id: int
    audio_id: str
    t0: float
    t1: float
    f0: float | None
    f1: float | None
    label: str | None
    note: str | None
    created_at: str
    updated_at: str


class UndoResponse(BaseModel):
    applied_patch: list[dict[str, Any]]
    scope: str
    action_name: str
    undo_stack_depth: int
    redo_stack_depth: int


class HistoryEntry(BaseModel):
    id: int
    ts: str
    scope: str
    action_name: str


class MaskSpec(BaseModel):
    t0: float
    t1: float
    f0: float | None = None
    f1: float | None = None
    fade_hz: float | None = None
    fade_ms: float | None = None


class AuditionRequest(BaseModel):
    """Exactly one of mask / selection_id / segments."""

    audio_id: str
    mask: MaskSpec | None = None
    selection_id: str | None = None
    segments: list[list[float]] | None = None
    crossfade_ms: float | None = None
    fade_hz: float | None = None
    fade_ms: float | None = None


class SeedSpec(BaseModel):
    """Point (t, f) or box (t0, t1, f0, f1)."""

    t: float | None = None
    f: float | None = None
    t0: float | None = None
    t1: float | None = None
    f0: float | None = None
    f1: float | None = None


class MagicSelectRequest(BaseModel):
    audio_id: str
    seed: SeedSpec
    tolerance_db: float = 8.0
    contiguous: bool = True
    adapt: str = "local_median"
    max_extent_s: float = 120.0


class SelectSimilarRequest(BaseModel):
    audio_id: str
    seed: SeedSpec
    threshold: float = 0.4
    min_segment_s: float = 0.5
    use_features: list[str] = Field(default_factory=list)


class OnsetRepickRequest(BaseModel):
    """Re-run peak picking on a saved onset envelope — no recomputation.

    Batch re-thresholding: the expensive PCEN/SuperFlux envelope is reused;
    only the cheap pick runs. Omitted params fall back to the original pick.
    """

    audio_id: str
    key: str | None = None  # specific cached onsets analysis; default = latest
    delta: float | None = None  # sensitivity on the [0,1]-normalized envelope
    wait_s: float | None = None  # minimum gap between onsets
    pre_max_s: float | None = None
    post_max_s: float | None = None
    pre_avg_s: float | None = None
    post_avg_s: float | None = None
    region: Region | None = None  # re-pick only inside this time window


class OnsetCommitRequest(BaseModel):
    """Materialize picked onsets as point annotations — one undoable action."""

    audio_id: str
    times: list[float]
    strengths: list[float] | None = None
    label: str = "onset"


class ExportRequest(BaseModel):
    audio_id: str
    kinds: list[str] = Field(default_factory=list)
    format: Literal["json", "csv"] = "json"
    region: Region | None = None


class AnalyzeRequest(BaseModel):
    kind: str
    audio_id: str = ""
    params: dict[str, Any] = Field(default_factory=dict)
    region: Region | None = None
