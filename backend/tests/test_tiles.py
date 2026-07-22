"""Tile endpoint tests: binary payloads, headers, clamping (§4.3, Phase 1)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import pytest
from fastapi.testclient import TestClient

from tests.conftest import wait_for_job


@pytest.fixture(scope="module")
def audio_id(client: TestClient, fixture_dir: Path) -> str:
    response = client.post(
        "/files/import", json={"path": str(fixture_dir / "sweep.wav"), "mode": "copy"}
    )
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    result: dict[str, Any] = info["result_ref"]
    return str(result["audio_id"])


def test_manifest_includes_spec(client: TestClient, audio_id: str) -> None:
    manifest = client.get(f"/files/{audio_id}/manifest").json()
    spec = manifest["spec"]
    assert spec["n_fft"] == 4096
    assert spec["hop"] == 1024
    assert spec["window"] == "blackmanharris7"
    assert spec["n_bins"] == 2049
    assert spec["mono_downmix"] is True
    assert spec["lods"][0]["frames_per_column"] == 1
    assert len(spec["lods"]) >= 1


def test_waveform_tile_binary(client: TestClient, audio_id: str) -> None:
    manifest = client.get(f"/files/{audio_id}/manifest").json()
    lod0 = manifest["waveform_lods"][0]
    response = client.get(
        f"/files/{audio_id}/waveform/tile", params={"lod": 0, "start": 0, "count": 128}
    )
    assert response.status_code == 200
    assert response.headers["content-type"] == "application/octet-stream"
    shape = tuple(int(x) for x in response.headers["x-indra-tile-shape"].split(","))
    assert shape == (128, manifest["channels"], 2)
    assert response.headers["x-indra-tile-dtype"] == "int16"
    assert response.headers["x-indra-tile-bounds"] == "0,128"
    data = np.frombuffer(response.content, dtype=np.int16).reshape(shape)
    assert data[..., 1].max() > 20000  # sweep peaks near 0.8 FS
    assert lod0["buckets"] >= 128


def test_waveform_tile_clamps_overrun(client: TestClient, audio_id: str) -> None:
    manifest = client.get(f"/files/{audio_id}/manifest").json()
    buckets = manifest["waveform_lods"][0]["buckets"]
    response = client.get(
        f"/files/{audio_id}/waveform/tile",
        params={"lod": 0, "start": buckets - 5, "count": 999},
    )
    shape = tuple(int(x) for x in response.headers["x-indra-tile-shape"].split(","))
    assert shape[0] == 5
    assert response.headers["x-indra-tile-bounds"] == f"{buckets - 5},{buckets}"


def test_waveform_tile_bad_lod(client: TestClient, audio_id: str) -> None:
    response = client.get(f"/files/{audio_id}/waveform/tile", params={"lod": 99})
    assert response.status_code == 400


def test_waveform_tile_unknown_audio(client: TestClient) -> None:
    response = client.get("/files/nope/waveform/tile", params={"lod": 0})
    assert response.status_code == 404


def test_spec_tile_binary(client: TestClient, audio_id: str) -> None:
    manifest = client.get(f"/files/{audio_id}/manifest").json()
    n_bins = manifest["spec"]["n_bins"]
    response = client.get(f"/files/{audio_id}/spec/tile", params={"lod": 0, "t0": 0, "t1": 32})
    assert response.status_code == 200
    shape = tuple(int(x) for x in response.headers["x-indra-tile-shape"].split(","))
    assert shape == (32, n_bins)
    assert response.headers["x-indra-tile-dtype"] == "uint8"
    data = np.frombuffer(response.content, dtype=np.uint8).reshape(shape)
    assert data.max() > 100  # the sweep is loud


def test_spec_tile_freq_slice(client: TestClient, audio_id: str) -> None:
    response = client.get(
        f"/files/{audio_id}/spec/tile",
        params={"lod": 0, "t0": 0, "t1": 16, "f0": 100, "f1": 356},
    )
    shape = tuple(int(x) for x in response.headers["x-indra-tile-shape"].split(","))
    assert shape == (16, 256)
    assert response.headers["x-indra-tile-bounds"] == "0,16,100,356"


def test_spec_tile_clamps_to_available_frames(client: TestClient, audio_id: str) -> None:
    manifest = client.get(f"/files/{audio_id}/manifest").json()
    frames = manifest["spec"]["lods"][0]["frames"]
    response = client.get(
        f"/files/{audio_id}/spec/tile",
        params={"lod": 0, "t0": 0, "t1": frames + 5000},
    )
    assert response.status_code == 200
    assert response.headers["x-indra-tile-bounds"].startswith(f"0,{frames},")


def test_spec_tile_sweep_energy_moves_up(client: TestClient, audio_id: str) -> None:
    """In an exponential sweep, the peak bin index must increase over time."""
    manifest = client.get(f"/files/{audio_id}/manifest").json()
    frames = manifest["spec"]["lods"][0]["frames"]
    early = client.get(f"/files/{audio_id}/spec/tile", params={"lod": 0, "t0": 1, "t1": 2}).content
    late = client.get(
        f"/files/{audio_id}/spec/tile",
        params={"lod": 0, "t0": frames - 2, "t1": frames - 1},
    ).content
    early_peak = int(np.frombuffer(early, dtype=np.uint8).argmax())
    late_peak = int(np.frombuffer(late, dtype=np.uint8).argmax())
    assert late_peak > early_peak * 2
