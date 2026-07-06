"""Content-addressed cache tests: key stability, LRU eviction rules (§4.6)."""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from indra.storage.cache import CacheIndex, cache_key, canonical_params_json
from indra.storage.db import Database
from indra.storage.paths import ProjectPaths


def test_cache_key_stable_across_param_order() -> None:
    a = cache_key("hash", "roughness", {"n_fft": 4096, "hop": 1024, "top_k": 64})
    b = cache_key("hash", "roughness", {"top_k": 64, "hop": 1024, "n_fft": 4096})
    assert a == b
    assert len(a) == 32


def test_cache_key_sensitive_to_inputs() -> None:
    base = cache_key("hash", "roughness", {"n_fft": 4096})
    assert cache_key("other", "roughness", {"n_fft": 4096}) != base
    assert cache_key("hash", "entropy", {"n_fft": 4096}) != base
    assert cache_key("hash", "roughness", {"n_fft": 2048}) != base
    assert cache_key("hash", "roughness", {"n_fft": 4096}, engine_version="x 9.9") != base


def test_canonical_params_json_compact_and_sorted() -> None:
    assert canonical_params_json({"b": 1, "a": [1, 2]}) == '{"a":[1,2],"b":1}'


@pytest.fixture
def cache_env(tmp_path: Path) -> tuple[CacheIndex, ProjectPaths, Database]:
    paths = ProjectPaths(tmp_path / "proj.indra")
    paths.ensure()
    db = Database(paths.db)
    cache = CacheIndex(db, paths, limit_bytes=3000)
    return cache, paths, db


def _put_blob(
    cache: CacheIndex,
    paths: ProjectPaths,
    key: str,
    size: int,
    kind: str = "feature",
    blob_kind: str = "npy",
    audio_id: str = "a1",
) -> Path:
    blob = paths.blob_path(key, blob_kind)
    blob.parent.mkdir(parents=True, exist_ok=True)
    blob.write_bytes(b"x" * size)
    cache.put(
        key,
        audio_id=audio_id,
        kind=kind,
        params={"k": key},
        result_ref={"blob": str(blob.relative_to(paths.root))},
        blob_path=str(blob.relative_to(paths.root)),
        blob_kind=blob_kind,
        size_bytes=size,
    )
    return blob


def test_put_get_roundtrip(cache_env: tuple[CacheIndex, ProjectPaths, Database]) -> None:
    cache, paths, _db = cache_env
    _put_blob(cache, paths, "aa" * 16, 100)
    entry = cache.get("aa" * 16)
    assert entry is not None
    assert entry.size_bytes == 100


def test_get_missing_returns_none(cache_env: tuple[CacheIndex, ProjectPaths, Database]) -> None:
    cache, _paths, _db = cache_env
    assert cache.get("nope") is None


def test_stale_entry_with_deleted_blob(
    cache_env: tuple[CacheIndex, ProjectPaths, Database],
) -> None:
    cache, paths, _db = cache_env
    blob = _put_blob(cache, paths, "bb" * 16, 50)
    blob.unlink()
    assert cache.get("bb" * 16) is None
    assert cache.get("bb" * 16) is None  # row cleaned up, still none


def test_lru_eviction_order(cache_env: tuple[CacheIndex, ProjectPaths, Database]) -> None:
    cache, paths, _db = cache_env
    _put_blob(cache, paths, "01" * 16, 1500)
    time.sleep(1.1)  # sqlite datetime granularity is 1 s
    _put_blob(cache, paths, "02" * 16, 1400)
    time.sleep(1.1)
    cache.get("01" * 16)  # refresh 01 → 02 becomes LRU
    time.sleep(1.1)
    _put_blob(cache, paths, "03" * 16, 1400)  # over limit: evict 02
    assert cache.get("02" * 16) is None
    assert cache.get("01" * 16) is not None
    assert cache.get("03" * 16) is not None


def test_eviction_skips_active_zarr(cache_env: tuple[CacheIndex, ProjectPaths, Database]) -> None:
    cache, paths, _db = cache_env
    cache._active_ids_provider = lambda: {"active"}  # what the app wires up from audio_files
    _put_blob(cache, paths, "0a" * 16, 2000, blob_kind="zarr", audio_id="active")
    time.sleep(1.1)
    _put_blob(cache, paths, "0b" * 16, 2000, audio_id="other")
    assert cache.get("0a" * 16) is not None, "active-project zarr must never be evicted"
    assert cache.get("0b" * 16) is None, "the non-zarr blob is the eviction victim"
