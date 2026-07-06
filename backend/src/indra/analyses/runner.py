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
