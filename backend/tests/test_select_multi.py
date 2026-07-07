"""Folder-wide similar search + cluster-map embedding.

The seed lives in file A (22.05 kHz); file B has a DIFFERENT sample rate
(44.1 kHz), noise floor, and level — the fixed-Hz profile bands plus per-file
baseline removal must still let the seed find its repeats in B while rejecting
each file's impostor texture.
"""

from __future__ import annotations

import multiprocessing
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from indra.analyses.select import embed_segments, similar_segments_multi
from indra.ingest.stft import build_spec_pyramid
from tests.conftest import wait_for_job


@pytest.fixture(scope="module")
def cancel_event():  # type: ignore[no-untyped-def]
    return multiprocessing.Manager().Event()


def _purr(t: np.ndarray) -> np.ndarray:  # type: ignore[type-arg]
    """AM texture: 2 kHz carrier trembling at 30 Hz — a recognizable 'thing'."""
    return 0.4 * (0.6 + 0.4 * np.sin(2 * np.pi * 30.0 * t)) * np.sin(2 * np.pi * 2000.0 * t)


def _make_file(
    path: Path, sr: int, duration_s: float, purr_at: list[float], impostor_at: float, noise: float
) -> None:
    rng = np.random.default_rng(int(sr))
    n = int(duration_s * sr)
    t = np.arange(n) / sr
    y = noise * rng.standard_normal(n)
    for start in purr_at:
        seg = (t >= start) & (t < start + 2.0)
        y[seg] += _purr(t[seg] - start)
    seg = (t >= impostor_at) & (t < impostor_at + 2.0)
    y[seg] += 0.4 * np.sin(2 * np.pi * 5000.0 * t[seg])  # steady high tone, no AM
    sf.write(path, y.astype(np.float32).clip(-1, 1), sr, subtype="FLOAT")


@pytest.fixture(scope="module")
def two_files(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, Path]:
    root = tmp_path_factory.mktemp("multi")
    a, b = root / "a.wav", root / "b.wav"
    _make_file(a, 22050, 30.0, purr_at=[3.0, 12.0], impostor_at=20.0, noise=0.02)
    _make_file(b, 44100, 25.0, purr_at=[8.0], impostor_at=15.0, noise=0.05)
    return a, b


@pytest.fixture(scope="module")
def two_specs(
    two_files: tuple[Path, Path],
    tmp_path_factory: pytest.TempPathFactory,
    cancel_event,  # type: ignore[no-untyped-def]
) -> list[tuple[str, Path]]:
    root = tmp_path_factory.mktemp("multi_spec")
    out = []
    for name, wav, sr in (("a", two_files[0], 22050), ("b", two_files[1], 44100)):
        spec = root / f"{name}.zarr"
        build_spec_pyramid(wav, spec, sr, cancel_event)
        out.append((name, spec))
    return out


def _hits(segments: list[dict[str, Any]], audio_id: str, at: float) -> bool:
    return any(s["audio_id"] == audio_id and s["t0"] < at + 2.0 and s["t1"] > at for s in segments)


def test_cross_file_search_finds_purrs_rejects_impostors(
    two_specs: list[tuple[str, Path]],
    cancel_event,  # type: ignore[no-untyped-def]
) -> None:
    result = similar_segments_multi(
        two_specs[0][1],
        {"t0": 3.0, "t1": 5.0},
        two_specs,
        {"threshold": 0.35, "min_segment_s": 0.5},
        cancel_event,
    )
    segments = result["segments"]
    assert _hits(segments, "a", 3.0), "seed must match itself"
    assert _hits(segments, "a", 12.0), "missed the repeat in the seed file"
    assert _hits(segments, "b", 8.0), "missed the repeat in the OTHER file (44.1 kHz)"
    assert not _hits(segments, "a", 20.0), "matched the 5 kHz impostor in a"
    assert not _hits(segments, "b", 15.0), "matched the 5 kHz impostor in b"
    assert result["scanned"] == ["a", "b"]
    # results arrive best-first
    distances = [s["distance"] for s in segments]
    assert distances == sorted(distances)


def test_multi_embedding_separates_classes(
    two_specs: list[tuple[str, Path]],
    cancel_event,  # type: ignore[no-untyped-def]
) -> None:
    """Loose threshold admits purrs AND impostors → clusters must separate them."""
    result = similar_segments_multi(
        two_specs[0][1],
        {"t0": 3.0, "t1": 5.0},
        two_specs,
        {"threshold": 0.9, "min_segment_s": 0.5, "embed": True},
        cancel_event,
    )
    segments = result["segments"]
    embedding = result["embedding"]
    assert len(embedding["xy"]) == len(segments) == len(embedding["cluster"])
    purr_clusters = {
        embedding["cluster"][i]
        for i, s in enumerate(segments)
        if (s["audio_id"], round(s["t0"] // 3)) in {("a", 1), ("a", 4), ("b", 2)}
        and s["distance"] < 0.35
    }
    impostor_clusters = {
        embedding["cluster"][i] for i, s in enumerate(segments) if s["distance"] > 0.5
    }
    assert len(purr_clusters) == 1, "purr repeats should share one cluster"
    assert not (purr_clusters & impostor_clusters), "impostors must land in other clusters"


def test_embed_segments_unit() -> None:
    rng = np.random.default_rng(2)
    group_a = [np.eye(24, dtype=np.float32)[0] + 0.05 * rng.standard_normal(24) for _ in range(3)]
    group_b = [np.eye(24, dtype=np.float32)[7] + 0.05 * rng.standard_normal(24) for _ in range(3)]
    vectors = [v.astype(np.float32) / np.linalg.norm(v) for v in group_a + group_b]
    embedding = embed_segments(vectors)
    labels = embedding["cluster"]
    assert len(set(labels[:3])) == 1
    assert len(set(labels[3:])) == 1
    assert set(labels[:3]) != set(labels[3:])
    xy = np.asarray(embedding["xy"])
    within = np.linalg.norm(xy[0] - xy[1])
    across = np.linalg.norm(xy[0] - xy[3])
    assert across > within


def test_select_similar_endpoint_multi(client: TestClient, two_files: tuple[Path, Path]) -> None:
    ids = []
    for wav in two_files:
        response = client.post("/files/import", json={"path": str(wav), "mode": "copy"})
        info = wait_for_job(client, response.json()["job_id"], timeout_s=180.0)
        assert info["state"] == "done", info
        ids.append(str(info["result_ref"]["audio_id"]))

    response = client.post(
        "/select/similar",
        json={
            "audio_id": ids[0],
            "seed": {"t0": 3.0, "t1": 5.0},
            "threshold": 0.35,
            "targets": "all",
            "embed": True,
        },
    )
    assert response.status_code == 200, response.text
    info = wait_for_job(client, response.json()["job_id"], timeout_s=300.0)
    assert info["state"] == "done", info
    result = info["result_ref"]
    assert set(result["scanned"]) == set(ids)
    assert _hits(result["segments"], ids[1], 8.0), "cross-file match missing via HTTP"
    assert len(result["embedding"]["xy"]) == len(result["segments"])

    # use_features is a per-file quantity: combining it with targets is a 400
    rejected = client.post(
        "/select/similar",
        json={
            "audio_id": ids[0],
            "seed": {"t0": 3.0, "t1": 5.0},
            "targets": "all",
            "use_features": ["roughness_mpt"],
        },
    )
    assert rejected.status_code == 400

    # a selection made on file A must not audition against file B
    select = client.post(
        "/select/magic",
        json={"audio_id": ids[0], "seed": {"t": 4.0, "f": 2000.0}, "tolerance_db": 12.0},
    )
    info = wait_for_job(client, select.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    selection_id = info["result_ref"]["selection_id"]
    cross = client.post("/audition", json={"audio_id": ids[1], "selection_id": selection_id})
    info = wait_for_job(client, cross.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "failed"
    assert "selection_id" in info["error"]["message"]
