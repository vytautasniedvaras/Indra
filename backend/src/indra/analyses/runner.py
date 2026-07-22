"""Worker-side dispatch for on-demand analyses (BUILD_SPEC §6.4-6.5).

Runs in a pool process. `run_analysis` resolves the audio file, builds an
`AnalysisContext`, and dispatches through the `_HANDLERS` table — one function
per kind. Curve kinds share `_curve_result` (Parquet feature table + stats);
the others return their result_ref directly. Adding a kind = write a handler,
register it in `_HANDLERS` (ANALYSIS_KINDS derives from the table).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from indra.jobs.cancellation import CancelEvent, ProgressQueue, report
from indra.storage.cache import cache_key
from indra.storage.db import open_db
from indra.storage.paths import ProjectPaths


@dataclass
class AnalysisContext:
    """Everything a kind handler needs, resolved once."""

    kind: str
    audio_id: str
    params: dict[str, Any]
    paths: ProjectPaths
    audio_path: Path
    sr: int
    duration_s: float
    cancel_event: CancelEvent
    progress_queue: ProgressQueue

    def progress(self, frac: float) -> None:
        report(self.progress_queue, min(frac, 1.0) * 0.95, f"computing {self.kind}")

    def done(self, message: str) -> None:
        report(self.progress_queue, 1.0, message)

    def full_params(self) -> dict[str, Any]:
        """Params exactly as the registry keyed them (Cache Key Consistency)."""
        return {**self.params, "_kind": self.kind, "project_root": str(self.paths.root)}

    def spec_pyramid(self) -> Path:
        path = self.paths.spec_zarr(self.audio_id)
        if not path.exists():
            raise ValueError("no spectrogram pyramid for this file; re-import first")
        return path

    def region_bounds(self) -> tuple[float, float]:
        region = self.params.get("region") or {}
        return float(region.get("t0", 0.0)), float(region.get("t1", self.duration_s))


def _blob_ref(ctx: AnalysisContext, out_path: Path, blob_kind: str) -> dict[str, Any]:
    return {
        "path": str(out_path.relative_to(ctx.paths.root)),
        "kind": blob_kind,
        "size": out_path.stat().st_size,
    }


def _curve_result(
    ctx: AnalysisContext, columns: dict[str, Any], extra: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Write the Parquet feature table and assemble the standard curve result_ref."""
    from indra.storage.features import write_feature

    report(ctx.progress_queue, 0.96, "writing feature table")
    key = cache_key(ctx.audio_id, ctx.kind, ctx.full_params())
    out_path = write_feature(ctx.paths, ctx.audio_id, ctx.kind, key, columns, ctx.params, ctx.sr)

    stats: dict[str, Any] = {"n": len(columns["time_s"])}
    if "value" in columns and len(columns["value"]):
        values = columns["value"]
        stats.update(
            mean=float(values.mean()),
            std=float(values.std()),
            min=float(values.min()),
            max=float(values.max()),
        )
    ctx.done(f"{ctx.kind} complete")
    return {
        "feature_path": str(out_path.relative_to(ctx.paths.root)),
        "cache_key": key,
        "columns": [c for c in columns if c != "time_s"],
        "stats": stats,
        **(extra or {}),
        "_blob": _blob_ref(ctx, out_path, "parquet"),
    }


def _run_mpt_curve(ctx: AnalysisContext) -> dict[str, Any]:
    from indra.analyses.mpt_frames import compute_curve_from_file

    t0, t1 = ctx.region_bounds()
    hop = int(ctx.params.get("hop", 1024))
    estimate = max(1, round((t1 - t0) * ctx.sr / hop))
    columns = compute_curve_from_file(
        ctx.kind, ctx.audio_path, ctx.sr, ctx.params, ctx.cancel_event, ctx.progress, estimate
    )
    return _curve_result(ctx, columns)


def _run_onsets(ctx: AnalysisContext) -> dict[str, Any]:
    from indra.analyses.onsets import detect_onsets

    result = detect_onsets(
        ctx.audio_path, ctx.sr, ctx.params, ctx.cancel_event, ctx.progress, ctx.duration_s
    )
    columns = {
        "time_s": result["env_t"],
        "value": result["env"],
        "is_onset": np.isin(result["env_t"], result["onset_t"]).astype(np.float32),
    }
    onsets = {
        "t": [float(t) for t in result["onset_t"]],
        "strength": [float(s) for s in result["onset_strength"]],
    }
    return _curve_result(ctx, columns, extra={"onsets": onsets})


def _run_novelty(ctx: AnalysisContext) -> dict[str, Any]:
    from indra.analyses.novelty import foote_novelty

    columns = foote_novelty(
        ctx.audio_path, ctx.sr, ctx.params, ctx.cancel_event, ctx.progress, ctx.duration_s
    )
    return _curve_result(ctx, columns)


def _run_magic_select(ctx: AnalysisContext) -> dict[str, Any]:
    from indra.analyses.select import magic_select

    selection = magic_select(
        ctx.spec_pyramid(),
        ctx.params.get("seed") or {},
        ctx.params.get("select") or {},
        ctx.cancel_event,
    )
    ctx.done("selection computed")
    return {
        "selection_id": cache_key(ctx.audio_id, ctx.kind, ctx.full_params()),
        **selection,
    }


def _select_similar_targets(ctx: AnalysisContext) -> list[tuple[str, Path]]:
    """Resolve the folder-wide target list ("all" = every import)."""
    targets = ctx.params["targets"]
    if targets == "all":
        conn = open_db(ctx.paths.db)
        try:
            rows = conn.execute("SELECT id FROM audio_files ORDER BY id").fetchall()
        finally:
            conn.close()
        target_ids = [str(r["id"]) for r in rows]
    else:
        target_ids = [str(t) for t in targets]
    return [(tid, ctx.paths.spec_zarr(tid)) for tid in target_ids]


def _feature_curves(ctx: AnalysisContext) -> dict[str, Any]:
    """Load (times, values) for each requested already-computed feature curve."""
    from indra.storage.features import FeatureBlobMissing, load_latest_feature

    curves: dict[str, Any] = {}
    for feature_kind in ctx.params.get("use_features") or []:
        try:
            loaded = load_latest_feature(ctx.paths.db, ctx.paths.root, ctx.audio_id, feature_kind)
        except FeatureBlobMissing:
            continue
        if loaded is None:
            continue
        _row, columns, _meta = loaded
        if "value" in columns:
            curves[feature_kind] = (
                np.asarray(columns["time_s"], dtype=np.float32),
                np.asarray(columns["value"], dtype=np.float32),
            )
    return curves


def _run_select_similar(ctx: AnalysisContext) -> dict[str, Any]:
    from indra.analyses.select import similar_segments, similar_segments_multi

    spec_path = ctx.spec_pyramid()
    seed = ctx.params.get("seed") or {}
    select = ctx.params.get("select") or {}
    if ctx.params.get("targets") is not None:
        select = {**select, "embed": ctx.params.get("embed", False)}
        result = similar_segments_multi(
            spec_path,
            seed,
            _select_similar_targets(ctx),
            select,
            ctx.cancel_event,
            ctx.progress,
        )
    else:
        curves = _feature_curves(ctx)
        result = similar_segments(spec_path, seed, select, ctx.cancel_event, curves or None)
    ctx.done("similar segments found")
    return result


def _load_selection_ribbons(ctx: AnalysisContext, selection_id: str) -> list[dict[str, Any]]:
    """Ribbons of a stored magic selection — for THIS file only (audio_id guard:
    a selection from another file must not render against this one's audio)."""
    import json

    conn = open_db(ctx.paths.db)
    try:
        row = conn.execute(
            "SELECT result_json FROM analysis_cache WHERE key=? AND audio_id=?",
            (selection_id, ctx.audio_id),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        raise ValueError(f"unknown selection_id for this file: {selection_id}")
    ribbons: list[dict[str, Any]] = json.loads(str(row["result_json"])).get("ribbons") or []
    return ribbons


def _run_audition(ctx: AnalysisContext) -> dict[str, Any]:
    from indra.analyses.audition import (
        render_audition,
        render_ribbons_audition,
        render_segments_audition,
    )

    key = cache_key(ctx.audio_id, ctx.kind, ctx.full_params())
    out_path = ctx.paths.blob_path(key, "wav")
    if ctx.params.get("selection_id"):
        meta = render_ribbons_audition(
            ctx.audio_path,
            ctx.sr,
            ctx.duration_s,
            _load_selection_ribbons(ctx, str(ctx.params["selection_id"])),
            out_path,
            ctx.cancel_event,
            fade_hz=float(ctx.params.get("fade_hz", 50.0)),
            fade_ms=float(ctx.params.get("fade_ms", 15.0)),
        )
    elif ctx.params.get("segments"):
        meta = render_segments_audition(
            ctx.audio_path,
            ctx.sr,
            ctx.duration_s,
            ctx.params["segments"],
            out_path,
            ctx.cancel_event,
            crossfade_ms=float(ctx.params.get("crossfade_ms", 30.0)),
        )
    else:
        meta = render_audition(
            ctx.audio_path,
            ctx.sr,
            ctx.duration_s,
            ctx.params.get("mask") or {},
            out_path,
            ctx.cancel_event,
        )
    ctx.done("audition rendered")
    return {
        "audition_id": key,
        "wav_path": str(out_path.relative_to(ctx.paths.root)),
        **meta,
        "_blob": _blob_ref(ctx, out_path, "wav"),
    }


_HANDLERS: dict[str, Callable[[AnalysisContext], dict[str, Any]]] = {
    "roughness_mpt": _run_mpt_curve,
    "spectral_entropy_mpt": _run_mpt_curve,
    "template_harmonicity_mpt": _run_mpt_curve,
    "onsets_superflux_pcen": _run_onsets,
    "foote_novelty_multiscale": _run_novelty,
    "magic_select": _run_magic_select,
    "select_similar": _run_select_similar,
    "audition": _run_audition,
}

ANALYSIS_KINDS = frozenset(_HANDLERS)


def run_analysis(
    spec: dict[str, Any], cancel_event: CancelEvent, progress_queue: ProgressQueue
) -> dict[str, Any]:
    params = dict(spec["params"])
    kind = str(params.pop("_kind"))
    audio_id = str(spec["audio_id"])
    paths = ProjectPaths(Path(params.pop("project_root")))
    handler = _HANDLERS.get(kind)
    if handler is None:
        raise ValueError(f"unknown analysis kind: {kind}")

    conn = open_db(paths.db)
    try:
        row = conn.execute("SELECT * FROM audio_files WHERE id=?", (audio_id,)).fetchone()
    finally:
        conn.close()
    if row is None:
        raise ValueError(f"unknown audio file: {audio_id}")

    ctx = AnalysisContext(
        kind=kind,
        audio_id=audio_id,
        params=params,
        paths=paths,
        audio_path=paths.root / str(row["stored_path"]),
        sr=int(row["sr"]),
        duration_s=float(row["duration_s"]),
        cancel_event=cancel_event,
        progress_queue=progress_queue,
    )
    report(progress_queue, 0.0, f"computing {kind}")
    return {"kind": kind, "audio_id": audio_id, **handler(ctx)}
