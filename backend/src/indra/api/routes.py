"""Phase 0 API routes: health, project, files, jobs, analyze."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import zarr
from fastapi import APIRouter, Request
from sse_starlette.sse import EventSourceResponse

from indra import ENGINE_VERSION
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
    WaveformLod,
)
from indra.jobs.registry import JobHandle, JobRegistry
from indra.jobs.workers import WORKERS
from indra.storage.db import Database
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
    return FileManifest(
        id=str(row["id"]),
        sr=int(row["sr"]),
        channels=int(row["channels"]),
        frames=int(row["frames"]),
        duration_s=float(row["duration_s"]),
        format=str(row["format"]),
        waveform_lods=lods,
    )


@router.post("/analyze")
async def analyze(request: Request, body: AnalyzeRequest) -> JobCreatedResponse:
    if body.kind not in WORKERS or body.kind == "import":
        raise ApiError(400, "bad_request", f"unknown analysis kind: {body.kind}")
    params = dict(body.params)
    if body.audio_id:
        row = _db(request).query_one("SELECT id FROM audio_files WHERE id=?", (body.audio_id,))
        if row is None:
            raise ApiError(404, "not_found", f"no such audio file: {body.audio_id}")
        params["project_root"] = str(_paths(request).root)
    handle = _registry(request).submit(body.kind, params, audio_id=body.audio_id)
    return JobCreatedResponse(job_id=handle.id)


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
