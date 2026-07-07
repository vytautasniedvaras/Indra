"""Parquet feature store (BUILD_SPEC §6.4 storage schema).

One parquet file per computed variant at
arrays/features/<audio_id>/<kind>-<cache_key[:12]>.parquet with columns
frame_index (i64), time_s (f64), value (f32), [aux f32 …] and JSON metadata
(audio_id, kind, params, engine_version, sr) in the schema metadata.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
from numpy.typing import NDArray

from indra import ENGINE_VERSION
from indra.storage.paths import ProjectPaths

FloatArray = NDArray[np.float32]

META_KEY = b"indra"


def write_feature(
    paths: ProjectPaths,
    audio_id: str,
    kind: str,
    cache_key: str,
    columns: dict[str, FloatArray],
    params: dict[str, Any],
    sr: int,
) -> Path:
    """Write a curve/event table; 'time_s' column required, others f32."""
    times = columns["time_s"]
    n = len(times)
    fields: dict[str, pa.Array] = {
        "frame_index": pa.array(np.arange(n, dtype=np.int64)),
        "time_s": pa.array(times.astype(np.float64)),
    }
    for name, values in columns.items():
        if name == "time_s":
            continue
        if len(values) != n:
            raise ValueError(f"column {name} length {len(values)} != {n}")
        fields[name] = pa.array(values.astype(np.float32))
    metadata = {
        "audio_id": audio_id,
        "kind": kind,
        "cache_key": cache_key,
        "params": params,
        "engine_version": ENGINE_VERSION,
        "sr": sr,
    }
    table = pa.table(fields).replace_schema_metadata(
        {META_KEY: json.dumps(metadata).encode("utf-8")}
    )
    out = paths.features_dir(audio_id) / f"{kind}-{cache_key[:12]}.parquet"
    out.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(table, out, compression="zstd")  # type: ignore[no-untyped-call]
    return out


def read_feature(path: Path) -> tuple[dict[str, NDArray[Any]], dict[str, Any]]:
    table = pq.read_table(path)  # type: ignore[no-untyped-call]
    raw_meta = (table.schema.metadata or {}).get(META_KEY, b"{}")
    metadata: dict[str, Any] = json.loads(raw_meta.decode("utf-8"))
    columns = {name: np.asarray(table[name]) for name in table.column_names}
    return columns, metadata


class FeatureBlobMissing(Exception):
    """The cache row exists but its parquet was evicted; re-run the analysis."""


def load_latest_feature(
    db_path: Path,
    root: Path,
    audio_id: str,
    kind: str,
    key: str | None = None,
) -> tuple[dict[str, Any], dict[str, NDArray[Any]], dict[str, Any]] | None:
    """Newest (or `key`-named) cached feature for (audio_id, kind), read back.

    The one place the "latest analysis row" lookup lives — routes, export, and
    workers all resolve cached features through it. Opens a short-lived read
    connection (WAL allows concurrent readers), so it works from any process.
    Returns (row, columns, metadata); None if nothing was ever computed; raises
    FeatureBlobMissing if the row exists but the blob was evicted.
    """
    from indra.storage.db import open_db

    conn = open_db(db_path)
    try:
        if key:
            row = conn.execute(
                "SELECT * FROM analysis_cache WHERE key=? AND audio_id=? AND kind=?",
                (key, audio_id, kind),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT * FROM analysis_cache WHERE audio_id=? AND kind=? AND blob_path != ''"
                " ORDER BY created_at DESC LIMIT 1",
                (audio_id, kind),
            ).fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    blob = root / str(row["blob_path"])
    if not blob.exists():
        raise FeatureBlobMissing(str(blob))
    columns, metadata = read_feature(blob)
    return dict(row), columns, metadata


def minmax_buckets(
    times: NDArray[Any], values: NDArray[Any], buckets: int
) -> dict[str, list[float]]:
    """Downsample a curve to per-bucket min/max for pixel-width display (§4.4)."""
    n = len(values)
    if n == 0 or buckets <= 0:
        return {"t": [], "min": [], "max": []}
    buckets = min(buckets, n)
    edges = np.linspace(0, n, buckets + 1).astype(np.int64)
    mins, maxs, mids = [], [], []
    for i in range(buckets):
        lo, hi = int(edges[i]), max(int(edges[i + 1]), int(edges[i]) + 1)
        chunk = values[lo:hi]
        mins.append(float(chunk.min()))
        maxs.append(float(chunk.max()))
        mids.append(float(times[(lo + hi - 1) // 2]))
    return {"t": mids, "min": mins, "max": maxs}
