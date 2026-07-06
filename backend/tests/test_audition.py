"""Audition rendering: spectral isolation, fades, caching, bounds (§5.5, ADR 0008)."""

from __future__ import annotations

import multiprocessing
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from indra.analyses.audition import render_audition
from tests.conftest import SR, wait_for_job


def _band_energy(y: np.ndarray, sr: int, f_lo: float, f_hi: float) -> float:  # type: ignore[type-arg]
    spectrum = np.abs(np.fft.rfft(y))
    freqs = np.fft.rfftfreq(len(y), d=1.0 / sr)
    return float((spectrum[(freqs >= f_lo) & (freqs <= f_hi)] ** 2).sum())


@pytest.fixture(scope="module")
def cancel_event():  # type: ignore[no-untyped-def]
    return multiprocessing.Manager().Event()


@pytest.fixture(scope="module")
def dual_tone_wav(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """6 s stereo: 440 Hz + 2000 Hz throughout."""
    t = np.arange(6 * SR) / SR
    y = (0.4 * np.sin(2 * np.pi * 440.0 * t) + 0.4 * np.sin(2 * np.pi * 2000.0 * t)).astype(
        np.float32
    )
    stereo = np.stack([y, y * 0.8], axis=1)
    path = tmp_path_factory.mktemp("audition") / "dual.wav"
    sf.write(path, stereo, SR, subtype="FLOAT")
    return path


def test_band_isolation(dual_tone_wav: Path, tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    out = tmp_path / "iso.wav"
    meta = render_audition(
        dual_tone_wav,
        SR,
        6.0,
        {"t0": 1.0, "t1": 3.0, "f0": 1500.0, "f1": 2500.0},
        out,
        cancel_event,
    )
    assert meta["channels"] == 2
    rendered, sr = sf.read(out, dtype="float32")
    assert sr == SR
    assert abs(len(rendered) / SR - 2.0) < 0.01
    kept = _band_energy(rendered[:, 0], SR, 1900, 2100)
    rejected = _band_energy(rendered[:, 0], SR, 340, 540)
    assert kept > 100 * rejected, "440 Hz tone must be strongly attenuated"


def test_unmasked_frequencies_pass_through(
    dual_tone_wav: Path, tmp_path: Path, cancel_event
) -> None:  # type: ignore[no-untyped-def]
    out = tmp_path / "band.wav"
    render_audition(
        dual_tone_wav,
        SR,
        6.0,
        {"t0": 0.0, "t1": 2.0, "f0": 100.0, "f1": 5000.0},
        out,
        cancel_event,
    )
    rendered, _ = sf.read(out, dtype="float32")
    original, _ = sf.read(dual_tone_wav, dtype="float32", frames=len(rendered))
    # interior (away from edge fades) nearly identical: both tones inside the band
    interior = slice(SR // 2, len(rendered) - SR // 2)
    err = np.abs(rendered[interior] - original[interior]).max()
    assert err < 5e-3


def test_edge_fades_prevent_clicks(dual_tone_wav: Path, tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    out = tmp_path / "fade.wav"
    render_audition(
        dual_tone_wav, SR, 6.0, {"t0": 1.0, "t1": 2.0, "fade_ms": 20.0}, out, cancel_event
    )
    rendered, _ = sf.read(out, dtype="float32")
    assert np.abs(rendered[:8]).max() < 1e-3
    assert np.abs(rendered[-8:]).max() < 1e-3


def test_validation_errors(dual_tone_wav: Path, tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    with pytest.raises(ValueError, match="t1 must be > t0"):
        render_audition(
            dual_tone_wav, SR, 6.0, {"t0": 3.0, "t1": 1.0}, tmp_path / "x.wav", cancel_event
        )
    with pytest.raises(ValueError, match="maximum"):
        render_audition(
            dual_tone_wav,
            SR,
            100000.0,
            {"t0": 0.0, "t1": 99999.0},
            tmp_path / "x.wav",
            cancel_event,
        )
    with pytest.raises(ValueError, match="too short"):
        render_audition(
            dual_tone_wav, SR, 6.0, {"t0": 0.0, "t1": 0.01}, tmp_path / "x.wav", cancel_event
        )


# -- endpoint ------------------------------------------------------------------------


@pytest.fixture(scope="module")
def audio_id(client: TestClient, dual_tone_wav: Path) -> str:
    response = client.post("/files/import", json={"path": str(dual_tone_wav), "mode": "copy"})
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    return str(info["result_ref"]["audio_id"])


def test_audition_endpoint_renders_and_caches(client: TestClient, audio_id: str) -> None:
    body: dict[str, Any] = {
        "audio_id": audio_id,
        "mask": {"t0": 1.0, "t1": 3.0, "f0": 1500.0, "f1": 2500.0},
    }
    response = client.post("/audition", json=body)
    assert response.status_code == 200, response.text
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    ref = info["result_ref"]
    assert ref["wav_path"].endswith(".wav")
    project_root = Path(client.get("/project").json()["root"])
    wav = project_root / ref["wav_path"]
    assert wav.exists()
    rendered, sr = sf.read(wav, dtype="float32")
    assert abs(len(rendered) / sr - 2.0) < 0.01

    # identical mask → instant cache hit with the same audition_id
    again = client.post("/audition", json=body)
    info2 = client.get(f"/jobs/{again.json()['job_id']}").json()
    assert info2["state"] == "done"
    assert info2["message"] == "cached"
    assert info2["result_ref"]["audition_id"] == ref["audition_id"]


def test_audition_endpoint_validation(client: TestClient, audio_id: str) -> None:
    assert (
        client.post("/audition", json={"audio_id": "nope", "mask": {"t0": 0, "t1": 1}}).status_code
        == 404
    )
    response = client.post("/audition", json={"audio_id": audio_id, "mask": {"f0": 100.0}})
    assert response.status_code == 422  # t0/t1 required by schema
    bad = client.post("/audition", json={"audio_id": audio_id, "mask": {"t0": 3.0, "t1": 1.0}})
    info = wait_for_job(client, bad.json()["job_id"], timeout_s=60.0)
    assert info["state"] == "failed"
    assert "t1 must be > t0" in info["error"]["message"]
