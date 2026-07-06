"""End-to-end analysis jobs through the API: all five kinds, caching,
region drill-down, and the /features endpoint (§6.4-6.5, Phase 2 DoD)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from tests.conftest import SR, wait_for_job


@pytest.fixture(scope="module")
def analysis_wav(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """8 s: pure tone → rough dyad → noise, with 4 loud clicks. Structure for
    every analysis kind to find."""
    rng = np.random.default_rng(5)
    t1 = np.arange(3 * SR) / SR
    tone = 0.5 * np.sin(2 * np.pi * 440.0 * t1)
    dyad = 0.4 * np.sin(2 * np.pi * 440.0 * t1) + 0.4 * np.sin(2 * np.pi * 466.16 * t1)
    noise = (0.4 * rng.standard_normal(2 * SR)).clip(-1, 1)
    y = np.concatenate([tone, dyad, noise]).astype(np.float32)
    for click_t in (0.5, 2.0, 4.0, 6.5):
        i = int(click_t * SR)
        y[i : i + 200] += 0.9 * np.hanning(200)
    y = y.clip(-1, 1)
    path = tmp_path_factory.mktemp("analysis") / "structured.wav"
    sf.write(path, y, SR, subtype="FLOAT")
    return path


@pytest.fixture(scope="module")
def audio_id(client: TestClient, analysis_wav: Path) -> str:
    response = client.post("/files/import", json={"path": str(analysis_wav), "mode": "copy"})
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    return str(info["result_ref"]["audio_id"])


def _analyze(
    client: TestClient,
    audio_id: str,
    kind: str,
    params: dict[str, Any] | None = None,
    region: dict[str, float] | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {"kind": kind, "audio_id": audio_id, "params": params or {}}
    if region:
        body["region"] = region
    response = client.post("/analyze", json=body)
    assert response.status_code == 200, response.text
    info = wait_for_job(client, response.json()["job_id"], timeout_s=300.0)
    assert info["state"] == "done", info
    result: dict[str, Any] = info["result_ref"]
    return result


def test_roughness_job_tracks_structure(client: TestClient, audio_id: str) -> None:
    result = _analyze(client, audio_id, "roughness_mpt")
    assert result["stats"]["n"] > 100
    feature = client.get(
        f"/files/{audio_id}/features/roughness_mpt", params={"downsample": 8}
    ).json()
    buckets = feature["buckets"]["value"]
    # dyad section (3-6 s → buckets 3-5) rougher than tone section (buckets 0-2)
    assert max(buckets["max"][3:6]) > 2 * max(buckets["max"][0:2])


def test_analysis_resume_from_cache(client: TestClient, audio_id: str) -> None:
    first = _analyze(client, audio_id, "spectral_entropy_mpt")
    response = client.post(
        "/analyze", json={"kind": "spectral_entropy_mpt", "audio_id": audio_id, "params": {}}
    )
    info = client.get(f"/jobs/{response.json()['job_id']}").json()
    assert info["state"] == "done", "identical params must hit the cache instantly"
    assert info["message"] == "cached"
    assert info["result_ref"]["cache_key"] == first["cache_key"]


def test_harmonicity_job(client: TestClient, audio_id: str) -> None:
    result = _analyze(client, audio_id, "template_harmonicity_mpt")
    assert "h_entropy" in result["columns"]
    feature = client.get(
        f"/files/{audio_id}/features/template_harmonicity_mpt", params={"downsample": 8}
    ).json()
    # tonal sections clearly more harmonic than the noise tail
    harm = feature["buckets"]["value"]
    assert np.mean(harm["max"][0:2]) > np.mean(harm["max"][6:8])


def test_onsets_find_clicks(client: TestClient, audio_id: str) -> None:
    result = _analyze(client, audio_id, "onsets_superflux_pcen")
    onset_times = np.asarray(result["onsets"]["t"])
    assert onset_times.size >= 3
    for expected in (0.5, 2.0, 4.0):
        assert np.min(np.abs(onset_times - expected)) < 0.1, f"missed click at {expected}s"


def test_novelty_finds_section_boundary(client: TestClient, audio_id: str) -> None:
    result = _analyze(
        client, audio_id, "foote_novelty_multiscale", params={"scales_s": [2.0], "hop": 1024}
    )
    feature = client.get(
        f"/files/{audio_id}/features/foote_novelty_multiscale",
        params={"key": result["cache_key"]},
    ).json()
    times = np.asarray(feature["values"]["time_s"])
    novelty = np.asarray(feature["values"]["novelty_2s"])
    # strongest novelty peak near a section boundary (3 s or 6 s)
    peak_t = float(times[int(novelty.argmax())])
    assert min(abs(peak_t - 3.0), abs(peak_t - 6.0)) < 1.0, f"peak at {peak_t}s"


def test_region_scoped_analysis(client: TestClient, audio_id: str) -> None:
    result = _analyze(client, audio_id, "roughness_mpt", region={"t0": 3.0, "t1": 6.0})
    feature = client.get(
        f"/files/{audio_id}/features/roughness_mpt", params={"key": result["cache_key"]}
    ).json()
    times = feature["values"]["time_s"]
    assert times[0] >= 2.95 and times[-1] <= 6.05
    # distinct cache entry from the full-file run
    full = _analyze(client, audio_id, "roughness_mpt")
    assert result["cache_key"] != full["cache_key"]


def test_manifest_lists_computed_features(client: TestClient, audio_id: str) -> None:
    _analyze(client, audio_id, "roughness_mpt")
    manifest = client.get(f"/files/{audio_id}/manifest").json()
    assert "roughness_mpt" in manifest["features"]


def test_features_endpoint_time_slice(client: TestClient, audio_id: str) -> None:
    full = _analyze(client, audio_id, "roughness_mpt")
    feature = client.get(
        f"/files/{audio_id}/features/roughness_mpt",
        params={"t0": 1.0, "t1": 2.0, "key": full["cache_key"]},
    ).json()
    times = feature["values"]["time_s"]
    assert times[0] >= 0.99 and times[-1] <= 2.01
    assert feature["n"] == len(times)


def test_features_endpoint_unknown_kind_404(client: TestClient, audio_id: str) -> None:
    response = client.get(f"/files/{audio_id}/features/nonexistent_kind")
    assert response.status_code == 404


def test_analyze_requires_audio_id(client: TestClient) -> None:
    response = client.post("/analyze", json={"kind": "roughness_mpt"})
    assert response.status_code == 400


def test_analysis_cancellation(client: TestClient, audio_id: str) -> None:
    import time

    # Fresh params so the cache can't shortcut; harmonicity is the slowest kind.
    response = client.post(
        "/analyze",
        json={
            "kind": "template_harmonicity_mpt",
            "audio_id": audio_id,
            "params": {"sigma_cents": 11.5},
        },
    )
    job_id = response.json()["job_id"]
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        info = client.get(f"/jobs/{job_id}").json()
        if info["state"] == "running":
            break
        time.sleep(0.02)
    cancelled_at = time.monotonic()
    assert client.post(f"/jobs/{job_id}/cancel").json()["cancelled"]
    info = wait_for_job(client, job_id, timeout_s=5.0)
    assert info["state"] == "cancelled"
    assert time.monotonic() - cancelled_at < 2.0
