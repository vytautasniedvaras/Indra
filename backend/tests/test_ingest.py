"""Ingest pipeline tests: probe, content hash, waveform pyramid (§6.2 steps 1-3)."""

from __future__ import annotations

import multiprocessing
from itertools import pairwise
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import zarr
from fastapi.testclient import TestClient

from indra.ingest.hashing import content_hash
from indra.ingest.probe import probe
from indra.ingest.waveform import BASE_BUCKET, LEVELS, _downsample, _minmax_level0
from tests.conftest import SR, wait_for_job


def _import(client: TestClient, path: Path, mode: str = "copy") -> dict[str, Any]:
    response = client.post("/files/import", json={"path": str(path), "mode": mode})
    assert response.status_code == 200
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    result: dict[str, Any] = info["result_ref"]
    return result


# -- probe --------------------------------------------------------------------


def test_probe_wav(fixture_dir: Path) -> None:
    info = probe(fixture_dir / "sweep.wav")
    assert info.decoder == "soundfile"
    assert info.sr == SR
    assert info.channels == 2
    assert info.duration_s == pytest.approx(5.0, abs=0.01)


def test_probe_flac(fixture_dir: Path) -> None:
    info = probe(fixture_dir / "noise.flac")
    assert info.decoder == "soundfile"
    assert info.channels == 1


def test_probe_m4a_uses_av_fallback(fixture_dir: Path) -> None:
    info = probe(fixture_dir / "tone.m4a")
    assert info.decoder == "av"
    assert info.sr == SR
    assert info.channels == 1
    assert info.duration_s == pytest.approx(2.0, abs=0.2)


# -- content hash ---------------------------------------------------------------


def test_content_hash_stable_across_decodes(fixture_dir: Path) -> None:
    event = multiprocessing.Manager().Event()
    first = content_hash(fixture_dir / "sweep.wav", SR, event)
    second = content_hash(fixture_dir / "sweep.wav", SR, event)
    assert first == second
    assert len(first) == 64


def test_content_hash_differs_between_files(fixture_dir: Path) -> None:
    event = multiprocessing.Manager().Event()
    assert content_hash(fixture_dir / "sweep.wav", SR, event) != content_hash(
        fixture_dir / "silence.wav", SR, event
    )


# -- waveform pyramid units -----------------------------------------------------


def test_minmax_level0_shapes_and_values() -> None:
    block = np.zeros((BASE_BUCKET * 3, 1), dtype=np.float32)
    block[100, 0] = 0.5
    block[300, 0] = -0.25
    out = _minmax_level0(block)
    assert out.shape == (3, 1, 2)
    assert out[0, 0, 1] == int(0.5 * 32767)
    assert out[1, 0, 0] == int(-0.25 * 32767)


def test_minmax_level0_partial_bucket_padding() -> None:
    block = np.ones((BASE_BUCKET + 10, 2), dtype=np.float32) * 0.1
    out = _minmax_level0(block)
    assert out.shape == (2, 2, 2)


def test_downsample_halves_and_preserves_extrema() -> None:
    level = np.zeros((4, 1, 2), dtype=np.int16)
    level[:, 0, 0] = [-5, -10, -2, -1]
    level[:, 0, 1] = [3, 8, 1, 9]
    out = _downsample(level)
    assert out.shape == (2, 1, 2)
    assert list(out[:, 0, 0]) == [-10, -2]
    assert list(out[:, 0, 1]) == [8, 9]


def test_downsample_odd_length() -> None:
    level = np.zeros((5, 1, 2), dtype=np.int16)
    out = _downsample(level)
    assert out.shape == (3, 1, 2)


# -- end-to-end import ----------------------------------------------------------


def test_import_wav_end_to_end(client: TestClient, fixture_dir: Path) -> None:
    result = _import(client, fixture_dir / "sweep.wav")
    audio_id = result["audio_id"]
    assert not result["already_imported"]

    files = client.get("/files").json()
    entry = next(f for f in files if f["id"] == audio_id)
    assert entry["sr"] == SR
    assert entry["channels"] == 2
    assert entry["mode"] == "copy"

    manifest = client.get(f"/files/{audio_id}/manifest").json()
    lods = manifest["waveform_lods"]
    assert len(lods) == LEVELS
    assert lods[0]["bucket_samples"] == BASE_BUCKET
    for previous, current in pairwise(lods):
        assert current["bucket_samples"] == previous["bucket_samples"] * 2
        assert current["buckets"] == pytest.approx(previous["buckets"] / 2, abs=1)


def test_reimport_short_circuits(client: TestClient, fixture_dir: Path) -> None:
    first = _import(client, fixture_dir / "sweep.wav")
    second = _import(client, fixture_dir / "sweep.wav")
    assert second["audio_id"] == first["audio_id"]
    assert second["already_imported"]


def test_import_silence_yields_zero_peaks(client: TestClient, fixture_dir: Path) -> None:
    result = _import(client, fixture_dir / "silence.wav")
    project_root = client.get("/project").json()["root"]
    zarr_path = Path(project_root) / "arrays" / "waveform" / f"{result['audio_id']}.zarr"
    group = zarr.open_group(str(zarr_path), mode="r")
    level0 = np.asarray(group["0"][:])
    assert level0.min() == 0 and level0.max() == 0


def test_import_sweep_peaks_match_amplitude(client: TestClient, fixture_dir: Path) -> None:
    result = _import(client, fixture_dir / "sweep.wav")
    project_root = client.get("/project").json()["root"]
    zarr_path = Path(project_root) / "arrays" / "waveform" / f"{result['audio_id']}.zarr"
    group = zarr.open_group(str(zarr_path), mode="r")
    level0 = np.asarray(group["0"][:])
    # Channel 0 amplitude 0.8, channel 1 amplitude 0.4 (PCM_16 quantized).
    assert level0[:, 0, 1].max() == pytest.approx(0.8 * 32767, rel=0.01)
    assert level0[:, 1, 1].max() == pytest.approx(0.4 * 32767, rel=0.01)
    assert level0[:, 0, 0].min() == pytest.approx(-0.8 * 32767, rel=0.01)
    # Pyramid level extrema must survive to the top LOD.
    top = np.asarray(group[str(LEVELS - 1)][:])
    assert top[:, 0, 1].max() == level0[:, 0, 1].max()


def test_import_m4a_via_av(client: TestClient, fixture_dir: Path) -> None:
    result = _import(client, fixture_dir / "tone.m4a", mode="reference")
    manifest = client.get(f"/files/{result['audio_id']}/manifest").json()
    assert manifest["sr"] == SR
    assert len(manifest["waveform_lods"]) == LEVELS


def test_import_reference_creates_symlink(client: TestClient, fixture_dir: Path) -> None:
    result = _import(client, fixture_dir / "noise.flac", mode="reference")
    files = client.get("/files").json()
    entry = next(f for f in files if f["id"] == result["audio_id"])
    project_root = Path(client.get("/project").json()["root"])
    stored = project_root / entry["stored_path"]
    assert stored.is_symlink()
    assert stored.resolve() == (fixture_dir / "noise.flac").resolve()
