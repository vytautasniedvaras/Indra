"""Import pipeline job: probe → hash → waveform pyramid → STFT pyramid (§6.2 steps 1-4).

Runs inside a worker process. Progress spans: probe 0-0.02, hash 0.02-0.25,
copy/link 0.25-0.28, waveform 0.28-0.50, STFT pyramid 0.50-0.97, db row 0.97-1.0.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from indra.ingest.hashing import content_hash
from indra.ingest.probe import probe
from indra.ingest.stft import build_spec_pyramid
from indra.ingest.waveform import build_waveform_pyramid
from indra.jobs.cancellation import CancelEvent, ProgressQueue, check_cancel, report
from indra.storage.db import open_db
from indra.storage.paths import ProjectPaths


def run_import(
    spec: dict[str, Any], cancel_event: CancelEvent, progress_queue: ProgressQueue
) -> dict[str, Any]:
    params = spec["params"]
    src = Path(params["path"]).expanduser().resolve()
    mode = params.get("mode", "reference")
    if mode not in ("copy", "reference"):
        raise ValueError(f"invalid import mode: {mode}")
    paths = ProjectPaths(Path(params["project_root"]))
    paths.ensure()

    report(progress_queue, 0.0, f"probing {src.name}")
    info = probe(src)
    check_cancel(cancel_event)
    report(progress_queue, 0.02, "hashing content")

    audio_id = content_hash(
        src,
        info.sr,
        cancel_event,
        progress_cb=lambda frac: report(progress_queue, 0.02 + 0.23 * frac, "hashing content"),
        total_frames=info.frames or None,
    )

    conn = open_db(paths.db)
    try:
        existing = conn.execute("SELECT id FROM audio_files WHERE id=?", (audio_id,)).fetchone()
        if (
            existing is not None
            and paths.waveform_zarr(audio_id).exists()
            and paths.spec_zarr(audio_id).exists()
        ):
            report(progress_queue, 1.0, "already imported")
            return {"audio_id": audio_id, "already_imported": True}

        report(progress_queue, 0.25, "storing audio")
        stored = _store_audio(paths, src, audio_id, mode)
        check_cancel(cancel_event)

        report(progress_queue, 0.28, "building waveform pyramid")
        build_waveform_pyramid(
            src,
            paths.waveform_zarr(audio_id),
            info.sr,
            cancel_event,
            progress_cb=lambda frac: report(
                progress_queue, 0.28 + 0.22 * frac, "building waveform pyramid"
            ),
            total_frames=info.frames or None,
        )
        check_cancel(cancel_event)

        report(progress_queue, 0.50, "building spectrogram pyramid")
        build_spec_pyramid(
            src,
            paths.spec_zarr(audio_id),
            info.sr,
            cancel_event,
            progress_cb=lambda frac: report(
                progress_queue, 0.50 + 0.47 * frac, "building spectrogram pyramid"
            ),
            total_frames=info.frames or None,
        )

        report(progress_queue, 0.97, "registering file")
        with conn:
            conn.execute(
                "INSERT OR REPLACE INTO audio_files "
                "(id, orig_path, stored_path, mode, sr, channels, frames, duration_s, format)"
                " VALUES (?,?,?,?,?,?,?,?,?)",
                (
                    audio_id,
                    str(src),
                    str(stored.relative_to(paths.root)),
                    mode,
                    info.sr,
                    info.channels,
                    info.frames,
                    info.duration_s,
                    info.format,
                ),
            )
    finally:
        conn.close()

    report(progress_queue, 1.0, "import complete")
    return {"audio_id": audio_id, "already_imported": False}


def _store_audio(paths: ProjectPaths, src: Path, audio_id: str, mode: str) -> Path:
    target = paths.audio_dir / f"{src.stem}-{audio_id[:8]}{src.suffix}"
    if target.exists() or target.is_symlink():
        target.unlink()
    if mode == "copy":
        shutil.copy2(src, target)
    else:
        target.symlink_to(src)
    return target
