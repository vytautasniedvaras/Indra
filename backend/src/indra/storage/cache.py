"""Content-addressed analysis cache (BUILD_SPEC §4.6, ADR 0006).

cache_key = blake3("{audio_content_hash}|{kind}|{canonical_params_json}|{engine_version}")[:32]
Blobs live at blobs/<key[:2]>/<key>.<ext>; index rows in the analysis_cache table.
"""

from __future__ import annotations

import json
import shutil
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import blake3

from indra import ENGINE_VERSION
from indra.storage.db import Database
from indra.storage.paths import ProjectPaths


def canonical_params_json(params: dict[str, Any]) -> str:
    return json.dumps(params, sort_keys=True, separators=(",", ":"))


def cache_key(
    audio_content_hash: str,
    kind: str,
    params: dict[str, Any],
    engine_version: str = ENGINE_VERSION,
) -> str:
    material = f"{audio_content_hash}|{kind}|{canonical_params_json(params)}|{engine_version}"
    return blake3.blake3(material.encode("utf-8")).hexdigest()[:32]


@dataclass(frozen=True)
class CacheEntry:
    key: str
    result_ref: dict[str, Any]
    blob_path: str
    blob_kind: str
    size_bytes: int


class CacheIndex:
    """Cache index over the analysis_cache table + blobs/ directory."""

    def __init__(
        self,
        db: Database,
        paths: ProjectPaths,
        limit_bytes: int,
        active_ids_provider: Callable[[], set[str]] | None = None,
    ) -> None:
        self._db = db
        self._paths = paths
        self._limit_bytes = limit_bytes
        self._active_ids_provider = active_ids_provider

    def get(self, key: str) -> CacheEntry | None:
        row = self._db.query_one("SELECT * FROM analysis_cache WHERE key=?", (key,))
        if row is None:
            return None
        blob_path = str(row["blob_path"])
        if blob_path and not (self._paths.root / blob_path).exists():
            # Blob evicted or deleted out-of-band: entry is stale.
            self._db.execute("DELETE FROM analysis_cache WHERE key=?", (key,))
            return None
        self._db.execute(
            "UPDATE analysis_cache SET last_used_at=datetime('now') WHERE key=?", (key,)
        )
        return CacheEntry(
            key=key,
            result_ref=json.loads(str(row["result_json"])),
            blob_path=blob_path,
            blob_kind=str(row["blob_kind"]),
            size_bytes=int(row["size_bytes"]),
        )

    def put(
        self,
        key: str,
        *,
        audio_id: str,
        kind: str,
        params: dict[str, Any],
        result_ref: dict[str, Any],
        blob_path: str = "",
        blob_kind: str = "",
        size_bytes: int = 0,
    ) -> None:
        self._db.execute(
            """
            INSERT OR REPLACE INTO analysis_cache
                (key, audio_id, kind, params_json, engine_version, result_json,
                 blob_path, blob_kind, size_bytes)
            VALUES (?,?,?,?,?,?,?,?,?)
            """,
            (
                key,
                audio_id,
                kind,
                canonical_params_json(params),
                ENGINE_VERSION,
                json.dumps(result_ref),
                blob_path,
                blob_kind,
                size_bytes,
            ),
        )
        self.evict_to_limit()

    def total_bytes(self) -> int:
        row = self._db.query_one("SELECT COALESCE(SUM(size_bytes),0) AS total FROM analysis_cache")
        return int(row["total"]) if row is not None else 0

    def evict_to_limit(self, active_audio_ids: set[str] | None = None) -> int:
        """LRU-evict blob-backed entries until under the limit.

        Never evicts zarr blobs of files in the active project (BUILD_SPEC §4.6).
        Returns the number of evicted entries.
        """
        if active_audio_ids is not None:
            active = active_audio_ids
        elif self._active_ids_provider is not None:
            active = self._active_ids_provider()
        else:
            active = set()
        evicted = 0
        while self.total_bytes() > self._limit_bytes:
            rows = self._db.query(
                "SELECT key, audio_id, blob_path, blob_kind FROM analysis_cache "
                "WHERE blob_path != '' ORDER BY last_used_at ASC LIMIT 50"
            )
            victim = None
            for row in rows:
                if str(row["blob_kind"]) == "zarr" and str(row["audio_id"]) in active:
                    continue
                victim = row
                break
            if victim is None:
                break
            target = self._paths.root / str(victim["blob_path"])
            if target.is_dir():
                shutil.rmtree(target, ignore_errors=True)
            elif target.exists():
                target.unlink()
            self._db.execute("DELETE FROM analysis_cache WHERE key=?", (str(victim["key"]),))
            evicted += 1
        return evicted
