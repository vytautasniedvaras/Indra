"""Phase 0 API routes: health, project, files, jobs, analyze."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np
import zarr
from fastapi import APIRouter, Request, Response
from sse_starlette.sse import EventSourceResponse

from indra import ENGINE_VERSION
from indra.analyses.runner import ANALYSIS_KINDS
from indra.api.errors import ApiError
from indra.api.schemas import (
    AnalyzeRequest,
    AudioFile,
    CancelResponse,
    FileManifest,
    HealthResponse,
    ImportRequest,
    JobCreatedResponse,
    JobInfo,
    ProjectResponse,
    SpecLod,
    SpecManifest,
    WaveformLod,
)
from indra.jobs.registry import JobHandle, JobRegistry
from indra.jobs.workers import WORKERS
from indra.storage.db import Database
from indra.storage.features import minmax_buckets, read_feature
from indra.storage.paths import PROJECT_FORMAT_VERSION, ProjectPaths

router = APIRouter()

_TERMINAL = {"cancelled", "failed", "done"}


def _registry(request: Request) -> JobRegistry:
    registry: JobRegistry = request.app.state.jobs
    return registry


def _db(request: Request) -> Database:
    db: Database = request.app.state.db
    return db


def _paths(request: Request) -> ProjectPaths:
    paths: ProjectPaths = request.app.state.paths
    return paths


def _handle_or_404(request: Request, job_id: str) -> JobHandle:
    handle = _registry(request).jobs.get(job_id)
    if handle is None:
        raise ApiError(404, "not_found", f"no such job: {job_id}")
    return handle


@router.get("/health")
async def health() -> HealthResponse:
    return HealthResponse()


@router.get("/project")
async def project(request: Request) -> ProjectResponse:
    paths = _paths(request)
    manifest: dict[str, Any] = {}
    if paths.manifest.exists():
        manifest = json.loads(paths.manifest.read_text(encoding="utf-8"))
    return ProjectResponse(
        root=str(paths.root),
        format_version=int(manifest.get("format_version", PROJECT_FORMAT_VERSION)),
        engine_version=str(manifest.get("engine_version", ENGINE_VERSION)),
    )


@router.post("/files/import")
async def import_file(request: Request, body: ImportRequest) -> JobCreatedResponse:
    src = Path(body.path).expanduser()
    if not src.exists():
        raise ApiError(404, "not_found", f"file not found: {src}", {"path": str(src)})
    params = {
        "path": str(src.resolve()),
        "mode": body.mode,
        "project_root": str(_paths(request).root),
    }
    handle = _registry(request).submit("import", params)
    return JobCreatedResponse(job_id=handle.id)


@router.get("/files")
async def list_files(request: Request) -> list[AudioFile]:
    rows = _db(request).query("SELECT * FROM audio_files ORDER BY imported_at")
    return [AudioFile(**dict(row)) for row in rows]


@router.get("/files/{audio_id}/manifest")
async def file_manifest(request: Request, audio_id: str) -> FileManifest:
    row = _db(request).query_one("SELECT * FROM audio_files WHERE id=?", (audio_id,))
    if row is None:
        raise ApiError(404, "not_found", f"no such audio file: {audio_id}")
    lods: list[WaveformLod] = []
    wf_path = _paths(request).waveform_zarr(audio_id)
    if wf_path.exists():
        group = zarr.open_group(str(wf_path), mode="r")
        base_bucket = int(group.attrs["base_bucket"])
        levels = int(group.attrs["levels"])
        for lod in range(levels):
            arr = group[str(lod)]
            lods.append(
                WaveformLod(
                    lod=lod,
                    bucket_samples=base_bucket * (2**lod),
                    buckets=int(arr.shape[0]),
                )
            )
    spec_manifest: SpecManifest | None = None
    spec_path = _paths(request).spec_zarr(audio_id)
    if spec_path.exists():
        spec_group = zarr.open_group(str(spec_path), mode="r")
        attrs = dict(spec_group.attrs)
        spec_lods = [
            SpecLod(
                lod=lod,
                frames=int(spec_group[str(lod)].shape[0]),
                frames_per_column=2**lod,
            )
            for lod in range(int(attrs["levels"]))
        ]
        spec_manifest = SpecManifest(
            n_fft=int(attrs["n_fft"]),
            hop=int(attrs["hop"]),
            window=str(attrs["window"]),
            n_bins=int(attrs["n_bins"]),
            db_min=float(attrs["db_min"]),
            db_max=float(attrs["db_max"]),
            mono_downmix=bool(attrs["mono_downmix"]),
            lods=spec_lods,
        )
    feature_rows = _db(request).query(
        "SELECT DISTINCT kind FROM analysis_cache WHERE audio_id=? AND blob_path != ''",
        (audio_id,),
    )
    return FileManifest(
        id=str(row["id"]),
        sr=int(row["sr"]),
        channels=int(row["channels"]),
        frames=int(row["frames"]),
        duration_s=float(row["duration_s"]),
        format=str(row["format"]),
        waveform_lods=lods,
        spec=spec_manifest,
        features=sorted(str(r["kind"]) for r in feature_rows),
    )


def _open_zarr_or_404(path: Path, what: str, audio_id: str) -> zarr.Group:
    if not path.exists():
        raise ApiError(404, "not_found", f"no {what} pyramid for audio file: {audio_id}")
    return zarr.open_group(str(path), mode="r")


@router.get("/files/{audio_id}/waveform/tile")
async def waveform_tile(
    request: Request, audio_id: str, lod: int, start: int = 0, count: int = 4096
) -> Response:
    group = _open_zarr_or_404(_paths(request).waveform_zarr(audio_id), "waveform", audio_id)
    levels = int(group.attrs["levels"])
    if not 0 <= lod < levels:
        raise ApiError(400, "bad_request", f"lod must be in [0, {levels})", {"lod": lod})
    arr = group[str(lod)]
    n = int(arr.shape[0])
    start = max(0, min(start, n))
    end = max(start, min(start + max(count, 0), n))
    tile = np.ascontiguousarray(arr[start:end])
    return Response(
        content=tile.tobytes(),
        media_type="application/octet-stream",
        headers={
            "X-Indra-Tile-Shape": ",".join(str(dim) for dim in tile.shape),
            "X-Indra-Tile-Dtype": "int16",
            "X-Indra-Tile-Bounds": f"{start},{end}",
        },
    )


@router.get("/files/{audio_id}/spec/tile")
async def spec_tile(
    request: Request,
    audio_id: str,
    lod: int,
    t0: int = 0,
    t1: int | None = None,
    f0: int = 0,
    f1: int | None = None,
) -> Response:
    group = _open_zarr_or_404(_paths(request).spec_zarr(audio_id), "spectrogram", audio_id)
    levels = int(group.attrs["levels"])
    if not 0 <= lod < levels:
        raise ApiError(400, "bad_request", f"lod must be in [0, {levels})", {"lod": lod})
    arr = group[str(lod)]
    n_frames, n_bins = int(arr.shape[0]), int(arr.shape[1])
    t0 = max(0, min(t0, n_frames))
    t1 = n_frames if t1 is None else max(t0, min(t1, n_frames))
    f0 = max(0, min(f0, n_bins))
    f1 = n_bins if f1 is None else max(f0, min(f1, n_bins))
    if (t1 - t0) * (f1 - f0) > 8 * 1024 * 1024:
        raise ApiError(
            400,
            "bad_request",
            "requested tile exceeds 8 MiB; request a smaller window or higher lod",
            {"frames": t1 - t0, "bins": f1 - f0},
        )
    tile = np.ascontiguousarray(arr[t0:t1, f0:f1])
    return Response(
        content=tile.tobytes(),
        media_type="application/octet-stream",
        headers={
            "X-Indra-Tile-Shape": f"{tile.shape[0]},{tile.shape[1]}",
            "X-Indra-Tile-Dtype": "uint8",
            "X-Indra-Tile-Bounds": f"{t0},{t1},{f0},{f1}",
        },
    )


@router.post("/analyze")
async def analyze(request: Request, body: AnalyzeRequest) -> JobCreatedResponse:
    if body.kind not in WORKERS or body.kind == "import":
        raise ApiError(400, "bad_request", f"unknown analysis kind: {body.kind}")
    params = dict(body.params)
    if body.kind in ANALYSIS_KINDS and not body.audio_id:
        raise ApiError(400, "bad_request", f"{body.kind} requires audio_id")
    if body.audio_id:
        row = _db(request).query_one("SELECT id FROM audio_files WHERE id=?", (body.audio_id,))
        if row is None:
            raise ApiError(404, "not_found", f"no such audio file: {body.audio_id}")
        params["project_root"] = str(_paths(request).root)
    if body.kind in ANALYSIS_KINDS:
        params["_kind"] = body.kind
        if body.region is not None:
            region = {k: v for k, v in body.region.model_dump().items() if v is not None}
            if region:
                params["region"] = region
    handle = _registry(request).submit(body.kind, params, audio_id=body.audio_id)
    return JobCreatedResponse(job_id=handle.id)


_RAW_POINT_CAP = 20_000


@router.get("/files/{audio_id}/features/{kind}")
async def feature_values(
    request: Request,
    audio_id: str,
    kind: str,
    t0: float | None = None,
    t1: float | None = None,
    downsample: int | None = None,
    key: str | None = None,
) -> dict[str, Any]:
    db = _db(request)
    if key:
        row = db.query_one(
            "SELECT * FROM analysis_cache WHERE key=? AND audio_id=?", (key, audio_id)
        )
    else:
        row = db.query_one(
            "SELECT * FROM analysis_cache WHERE audio_id=? AND kind=? AND blob_path != '' "
            "ORDER BY created_at DESC LIMIT 1",
            (audio_id, kind),
        )
    if row is None:
        raise ApiError(404, "not_found", f"no computed {kind} for {audio_id}")
    blob = _paths(request).root / str(row["blob_path"])
    if not blob.exists():
        raise ApiError(404, "not_found", "feature table missing (evicted); re-run analysis")
    columns, metadata = read_feature(blob)

    times = columns["time_s"]
    lo = int(np.searchsorted(times, t0)) if t0 is not None else 0
    hi = int(np.searchsorted(times, t1)) if t1 is not None else len(times)
    window = slice(lo, hi)
    n = hi - lo
    if downsample is None and n > _RAW_POINT_CAP:
        raise ApiError(
            400,
            "bad_request",
            f"{n} points exceeds the raw cap ({_RAW_POINT_CAP}); pass ?downsample=<buckets>",
        )

    value_names = [c for c in columns if c not in ("time_s", "frame_index")]
    payload: dict[str, Any] = {
        "audio_id": audio_id,
        "kind": str(row["kind"]),
        "cache_key": str(row["key"]),
        "params": metadata.get("params", {}),
        "sr": metadata.get("sr"),
        "n": n,
        "t0": float(times[lo]) if n else None,
        "t1": float(times[hi - 1]) if n else None,
        "columns": value_names,
    }
    if downsample is not None:
        payload["buckets"] = {
            name: minmax_buckets(times[window], columns[name][window], downsample)
            for name in value_names
        }
    else:
        payload["values"] = {"time_s": [float(t) for t in times[window]]}
        for name in value_names:
            payload["values"][name] = [float(v) for v in columns[name][window]]
    result_json = row["result_json"]
    if result_json:
        result_ref = json.loads(str(result_json))
        if "onsets" in result_ref:
            payload["onsets"] = result_ref["onsets"]
    return payload


@router.get("/jobs")
async def list_jobs(request: Request) -> list[JobInfo]:
    handles = sorted(_registry(request).jobs.values(), key=lambda h: h.created_at)
    return [JobInfo(**h.snapshot()) for h in handles]


@router.get("/jobs/{job_id}")
async def job_info(request: Request, job_id: str) -> JobInfo:
    return JobInfo(**_handle_or_404(request, job_id).snapshot())


@router.post("/jobs/{job_id}/cancel")
async def cancel_job(request: Request, job_id: str) -> CancelResponse:
    _handle_or_404(request, job_id)
    return CancelResponse(cancelled=_registry(request).cancel(job_id))


@router.get("/jobs/{job_id}/events")
async def job_events(request: Request, job_id: str) -> EventSourceResponse:
    handle = _handle_or_404(request, job_id)
    registry = _registry(request)
    queue = registry.subscribe(handle)

    async def stream() -> Any:
        try:
            while True:
                event = await queue.get()
                yield {"event": event.event, "data": json.dumps(event.data)}
                if event.event in _TERMINAL:
                    break
                if await request.is_disconnected():
                    break
        finally:
            registry.unsubscribe(handle, queue)

    return EventSourceResponse(stream())
