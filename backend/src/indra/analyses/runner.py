"""Worker-side dispatch for on-demand analyses (BUILD_SPEC §6.4-6.5).

Runs in a pool process: looks up the audio file, streams the computation with
cancellation + progress, writes the Parquet feature table, and returns a
result_ref whose _blob section the registry uses to index the cache.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np

from indra.jobs.cancellation import CancelEvent, ProgressQueue, report
from indra.storage.cache import cache_key
from indra.storage.db import open_db
from indra.storage.paths import ProjectPaths

ANALYSIS_KINDS = frozenset(
    {
        "roughness_mpt",
        "spectral_entropy_mpt",
        "template_harmonicity_mpt",
        "onsets_superflux_pcen",
        "foote_novelty_multiscale",
        "audition",
        "magic_select",
        "select_similar",
    }
)


def run_analysis(
    spec: dict[str, Any], cancel_event: CancelEvent, progress_queue: ProgressQueue
) -> dict[str, Any]:
    params = dict(spec["params"])
    kind = str(params.pop("_kind"))
    audio_id = str(spec["audio_id"])
    paths = ProjectPaths(Path(params.pop("project_root")))

    conn = open_db(paths.db)
    try:
        row = conn.execute("SELECT * FROM audio_files WHERE id=?", (audio_id,)).fetchone()
    finally:
        conn.close()
    if row is None:
        raise ValueError(f"unknown audio file: {audio_id}")
    audio_path = paths.root / str(row["stored_path"])
    sr = int(row["sr"])
    duration_s = float(row["duration_s"])

    def progress(frac: float) -> None:
        report(progress_queue, min(frac, 1.0) * 0.95, f"computing {kind}")

    report(progress_queue, 0.0, f"computing {kind}")
    region = params.get("region") or {}
    t0 = float(region.get("t0", 0.0))
    t1 = float(region.get("t1", duration_s))

    if kind in ("roughness_mpt", "spectral_entropy_mpt", "template_harmonicity_mpt"):
        from indra.analyses.mpt_frames import compute_curve_from_file

        hop = int(params.get("hop", 1024))
        estimate = max(1, round((t1 - t0) * sr / hop))
        columns = compute_curve_from_file(
            kind, audio_path, sr, params, cancel_event, progress, estimate
        )
    elif kind == "onsets_superflux_pcen":
        from indra.analyses.onsets import detect_onsets

        result = detect_onsets(audio_path, sr, params, cancel_event, progress, duration_s)
        columns = {
            "time_s": result["env_t"],
            "value": result["env"],
            "is_onset": np.isin(result["env_t"], result["onset_t"]).astype(np.float32),
        }
        onsets = {
            "t": [float(t) for t in result["onset_t"]],
            "strength": [float(s) for s in result["onset_strength"]],
        }
    elif kind == "foote_novelty_multiscale":
        from indra.analyses.novelty import foote_novelty

        columns = foote_novelty(audio_path, sr, params, cancel_event, progress, duration_s)
    elif kind == "magic_select":
        from indra.analyses.select import magic_select

        spec_path = paths.spec_zarr(audio_id)
        if not spec_path.exists():
            raise ValueError("no spectrogram pyramid for this file; re-import first")
        selection = magic_select(
            spec_path, params.get("seed") or {}, params.get("select") or {}, cancel_event
        )
        report(progress_queue, 1.0, "selection computed")
        full_params = {**params, "_kind": kind, "project_root": str(paths.root)}
        return {
            "kind": kind,
            "audio_id": audio_id,
            "selection_id": cache_key(audio_id, kind, full_params),
            **selection,
        }
    elif kind == "select_similar":
        from indra.analyses.select import similar_segments, similar_segments_multi
        from indra.storage.features import read_feature

        spec_path = paths.spec_zarr(audio_id)
        if not spec_path.exists():
            raise ValueError("no spectrogram pyramid for this file; re-import first")
        targets = params.get("targets")
        if targets is not None:
            # Folder-wide search: scan the listed files ("all" = every import).
            conn2 = open_db(paths.db)
            try:
                if targets == "all":
                    rows2 = conn2.execute("SELECT id FROM audio_files ORDER BY id").fetchall()
                    target_ids = [str(r["id"]) for r in rows2]
                else:
                    target_ids = [str(t) for t in targets]
            finally:
                conn2.close()
            select_params = {**(params.get("select") or {}), "embed": params.get("embed", False)}
            result = similar_segments_multi(
                spec_path,
                params.get("seed") or {},
                [(tid, paths.spec_zarr(tid)) for tid in target_ids],
                select_params,
                cancel_event,
            )
            report(progress_queue, 1.0, "similar segments found")
            return {"kind": kind, "audio_id": audio_id, **result}
        curves: dict[str, Any] = {}
        conn2 = open_db(paths.db)
        try:
            for feature_kind in params.get("use_features") or []:
                row2 = conn2.execute(
                    "SELECT blob_path FROM analysis_cache WHERE audio_id=? AND kind=?"
                    " AND blob_path != '' ORDER BY created_at DESC LIMIT 1",
                    (audio_id, feature_kind),
                ).fetchone()
                if row2 is None:
                    continue
                blob = paths.root / str(row2["blob_path"])
                if blob.exists():
                    columns, _meta = read_feature(blob)
                    if "value" in columns:
                        curves[feature_kind] = (
                            np.asarray(columns["time_s"], dtype=np.float32),
                            np.asarray(columns["value"], dtype=np.float32),
                        )
        finally:
            conn2.close()
        result = similar_segments(
            spec_path,
            params.get("seed") or {},
            params.get("select") or {},
            cancel_event,
            curves or None,
        )
        report(progress_queue, 1.0, "similar segments found")
        return {"kind": kind, "audio_id": audio_id, **result}
    elif kind == "audition":
        import json as json_mod

        from indra.analyses.audition import (
            render_audition,
            render_ribbons_audition,
            render_segments_audition,
        )
        from indra.storage.cache import cache_key as compute_key

        full_params = {**params, "_kind": kind, "project_root": str(paths.root)}
        key = compute_key(audio_id, kind, full_params)
        out_path = paths.blob_path(key, "wav")
        if params.get("selection_id"):
            conn3 = open_db(paths.db)
            try:
                row3 = conn3.execute(
                    "SELECT result_json FROM analysis_cache WHERE key=?",
                    (str(params["selection_id"]),),
                ).fetchone()
            finally:
                conn3.close()
            if row3 is None:
                raise ValueError(f"unknown selection_id: {params['selection_id']}")
            ribbons = json_mod.loads(str(row3["result_json"])).get("ribbons") or []
            meta = render_ribbons_audition(
                audio_path,
                sr,
                duration_s,
                ribbons,
                out_path,
                cancel_event,
                fade_hz=float(params.get("fade_hz", 50.0)),
                fade_ms=float(params.get("fade_ms", 15.0)),
            )
        elif params.get("segments"):
            meta = render_segments_audition(
                audio_path,
                sr,
                duration_s,
                params["segments"],
                out_path,
                cancel_event,
                crossfade_ms=float(params.get("crossfade_ms", 30.0)),
            )
        else:
            meta = render_audition(
                audio_path, sr, duration_s, params.get("mask") or {}, out_path, cancel_event
            )
        report(progress_queue, 1.0, "audition rendered")
        return {
            "kind": kind,
            "audio_id": audio_id,
            "audition_id": key,
            "wav_path": str(out_path.relative_to(paths.root)),
            **meta,
            "_blob": {
                "path": str(out_path.relative_to(paths.root)),
                "kind": "wav",
                "size": out_path.stat().st_size,
            },
        }
    else:
        raise ValueError(f"unknown analysis kind: {kind}")

    report(progress_queue, 0.96, "writing feature table")
    # Key/filename must match the registry's pre-submit cache lookup: the
    # registry keys on the ORIGINAL params (with _kind/project_root), so rebuild.
    full_params = {**params, "_kind": kind, "project_root": str(paths.root)}
    key = cache_key(audio_id, kind, full_params)

    from indra.storage.features import write_feature

    out_path = write_feature(paths, audio_id, kind, key, columns, params, sr)
    size = out_path.stat().st_size

    stats: dict[str, Any] = {"n": len(columns["time_s"])}
    if "value" in columns and len(columns["value"]):
        values = columns["value"]
        stats.update(
            mean=float(values.mean()),
            std=float(values.std()),
            min=float(values.min()),
            max=float(values.max()),
        )
    result_ref: dict[str, Any] = {
        "kind": kind,
        "audio_id": audio_id,
        "feature_path": str(out_path.relative_to(paths.root)),
        "cache_key": key,
        "columns": [c for c in columns if c != "time_s"],
        "stats": stats,
        "_blob": {
            "path": str(out_path.relative_to(paths.root)),
            "kind": "parquet",
            "size": size,
        },
    }
    if kind == "onsets_superflux_pcen":
        result_ref["onsets"] = onsets
    report(progress_queue, 1.0, f"{kind} complete")
    return result_ref
