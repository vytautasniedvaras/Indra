"""Structured export driving external visual/generative systems (BUILD_SPEC §6.6).

Schemas are stable and versioned (schema_version); documented in
docs/export_schema.md. JSON = one document; CSV = a zip archive with
features.csv (common time grid), annotations.csv, onsets.csv.
"""

from __future__ import annotations

import csv
import io
import json
import zipfile
from typing import Any

import numpy as np

from indra import ENGINE_VERSION
from indra.storage.db import Database
from indra.storage.features import FeatureBlobMissing, load_latest_feature
from indra.storage.paths import ProjectPaths

SCHEMA_VERSION = 1


class ExportError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _latest_feature(
    paths: ProjectPaths, audio_id: str, kind: str
) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """Export skips kinds that were never computed OR whose blob was evicted."""
    try:
        loaded = load_latest_feature(paths.db, paths.root, audio_id, kind)
    except FeatureBlobMissing:
        return None
    if loaded is None:
        return None
    row, columns, metadata = loaded
    result_ref = json.loads(str(row["result_json"])) if row["result_json"] else {}
    metadata["result_ref"] = result_ref
    return columns, metadata


def _slice(columns: dict[str, Any], t0: float | None, t1: float | None) -> dict[str, Any]:
    times = columns["time_s"]
    lo = int(np.searchsorted(times, t0)) if t0 is not None else 0
    hi = int(np.searchsorted(times, t1)) if t1 is not None else len(times)
    return {name: values[lo:hi] for name, values in columns.items()}


def gather(
    db: Database,
    paths: ProjectPaths,
    audio_id: str,
    kinds: list[str],
    region: dict[str, float] | None = None,
) -> dict[str, Any]:
    """Collect everything the export needs; raises ExportError on bad input."""
    audio = db.query_one("SELECT * FROM audio_files WHERE id=?", (audio_id,))
    if audio is None:
        raise ExportError("not_found", f"no such audio file: {audio_id}")
    t0 = region.get("t0") if region else None
    t1 = region.get("t1") if region else None

    features: dict[str, dict[str, Any]] = {}
    onsets: list[dict[str, float]] = []
    missing: list[str] = []
    for kind in kinds:
        found = _latest_feature(paths, audio_id, kind)
        if found is None:
            missing.append(kind)
            continue
        columns, metadata = found
        sliced = _slice(columns, t0, t1)
        features[kind] = {
            "params": metadata.get("params", {}),
            "sr": metadata.get("sr"),
            "time_s": [float(t) for t in sliced["time_s"]],
            **{
                name: [float(v) for v in values]
                for name, values in sliced.items()
                if name not in ("time_s", "frame_index")
            },
        }
        if kind == "onsets_superflux_pcen":
            raw = metadata.get("result_ref", {}).get("onsets", {})
            for t, strength in zip(raw.get("t", []), raw.get("strength", []), strict=True):
                if (t0 is None or t >= t0) and (t1 is None or t <= t1):
                    onsets.append({"t": float(t), "strength": float(strength)})
    if missing:
        raise ExportError(
            "not_found",
            f"features not computed yet: {', '.join(missing)} — run POST /analyze first",
        )

    rows = db.query("SELECT * FROM annotations WHERE audio_id=? ORDER BY t0", (audio_id,))
    annotations = [dict(row) for row in rows]
    if t0 is not None:
        annotations = [a for a in annotations if a["t1"] >= t0]
    if t1 is not None:
        annotations = [a for a in annotations if a["t0"] <= t1]

    return {
        "schema_version": SCHEMA_VERSION,
        "engine_version": ENGINE_VERSION,
        "audio_id": audio_id,
        "audio": {
            "sr": int(audio["sr"]),
            "duration_s": float(audio["duration_s"]),
            "channels": int(audio["channels"]),
            "frames": int(audio["frames"]),
            "format": str(audio["format"]),
        },
        "region": {"t0": t0, "t1": t1} if region else None,
        "annotations": annotations,
        "onsets": onsets,
        "features": features,
    }


def to_json_bytes(document: dict[str, Any]) -> bytes:
    return json.dumps(document, indent=1).encode("utf-8")


def to_csv_zip_bytes(document: dict[str, Any]) -> bytes:
    """features.csv on the finest feature time grid (nearest-neighbor aligned),
    plus annotations.csv and onsets.csv sidecars (§6.6)."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        features: dict[str, dict[str, Any]] = document["features"]
        if features:
            # finest grid = feature with the most points
            base_kind = max(features, key=lambda k: len(features[k]["time_s"]))
            grid = np.asarray(features[base_kind]["time_s"])
            header = ["time_s"]
            columns: list[np.ndarray] = [grid]  # type: ignore[type-arg]
            for kind, table in features.items():
                times = np.asarray(table["time_s"])
                for name, values in table.items():
                    if name in ("time_s", "params", "sr"):
                        continue
                    series = np.asarray(values, dtype=np.float64)
                    if len(series) == 0:
                        continue
                    if len(series) == len(grid):
                        aligned = series
                    else:  # nearest-neighbor onto the base grid
                        indices = np.clip(np.searchsorted(times, grid), 0, len(series) - 1)
                        aligned = series[indices]
                    header.append(f"{kind}.{name}")
                    columns.append(aligned)
            text = io.StringIO()
            writer = csv.writer(text)
            writer.writerow(header)
            writer.writerows(zip(*columns, strict=True))
            archive.writestr("features.csv", text.getvalue())

        text = io.StringIO()
        writer = csv.writer(text)
        writer.writerow(["id", "audio_id", "t0", "t1", "f0", "f1", "label", "note"])
        for a in document["annotations"]:
            writer.writerow(
                [a["id"], a["audio_id"], a["t0"], a["t1"], a["f0"], a["f1"], a["label"], a["note"]]
            )
        archive.writestr("annotations.csv", text.getvalue())

        text = io.StringIO()
        writer = csv.writer(text)
        writer.writerow(["t", "strength"])
        for onset in document["onsets"]:
            writer.writerow([onset["t"], onset["strength"]])
        archive.writestr("onsets.csv", text.getvalue())

        archive.writestr(
            "manifest.json",
            json.dumps(
                {
                    "schema_version": document["schema_version"],
                    "engine_version": document["engine_version"],
                    "audio_id": document["audio_id"],
                    "audio": document["audio"],
                    "region": document["region"],
                },
                indent=1,
            ),
        )
    return buffer.getvalue()
