"""Magic select + similar segments + feathered audition modes — all headless.

The key fixture is a chirp embedded in noise: magic select seeded on the chirp
must produce a ribbon that TRACKS the rising frequency (the multimodal-wand
behavior), tolerance must be monotonic, and the contextual (local-median)
mode must survive a loudness ramp that breaks absolute thresholds.
"""

from __future__ import annotations

import multiprocessing
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from indra.analyses.audition import render_segments_audition
from indra.analyses.select import magic_select, similar_segments
from indra.ingest.stft import build_spec_pyramid
from tests.conftest import SR, wait_for_job


@pytest.fixture(scope="module")
def cancel_event():  # type: ignore[no-untyped-def]
    return multiprocessing.Manager().Event()


def _chirp_in_noise(rng: np.random.Generator) -> np.ndarray:  # type: ignore[type-arg]
    """20 s: quiet broadband noise + a loud chirp rising 1->4 kHz from 5 s to 15 s."""
    n = 20 * SR
    t = np.arange(n) / SR
    y = 0.02 * rng.standard_normal(n)
    seg = (t >= 5.0) & (t <= 15.0)
    ts = t[seg] - 5.0
    freq = 1000.0 + 300.0 * ts  # 1 kHz -> 4 kHz over 10 s
    phase = 2 * np.pi * np.cumsum(freq) / SR
    y[seg] += 0.5 * np.sin(phase)
    return y.astype(np.float32).clip(-1, 1)


@pytest.fixture(scope="module")
def chirp_spec(tmp_path_factory: pytest.TempPathFactory, cancel_event) -> tuple[Path, Path]:  # type: ignore[no-untyped-def]
    root = tmp_path_factory.mktemp("select")
    rng = np.random.default_rng(7)
    wav = root / "chirp.wav"
    sf.write(wav, _chirp_in_noise(rng), SR, subtype="FLOAT")
    spec = root / "spec.zarr"
    build_spec_pyramid(wav, spec, SR, cancel_event)
    return wav, spec


def _centroids(result: dict[str, Any]) -> tuple[list[float], list[float]]:
    times, centers = [], []
    for ribbon in result["ribbons"]:
        mids = [(lo + hi) / 2 for lo, hi in ribbon["intervals"]]
        times.append((ribbon["t0"] + ribbon["t1"]) / 2)
        centers.append(sum(mids) / len(mids))
    return times, centers


def test_magic_select_tracks_chirp(chirp_spec: tuple[Path, Path], cancel_event) -> None:  # type: ignore[no-untyped-def]
    _wav, spec = chirp_spec
    result = magic_select(spec, {"t": 10.0, "f": 2500.0}, {"tolerance_db": 15.0}, cancel_event)
    assert result["cells"] > 50
    bounds = result["bounds"]
    assert bounds["t0"] > 3.0 and bounds["t1"] < 17.0, (
        "selection must not leak into noise-only time"
    )
    times, centers = _centroids(result)
    assert len(times) > 10
    # centroid frequency must rise with time (chirp tracking)
    first, last = np.mean(centers[: len(centers) // 4]), np.mean(centers[-len(centers) // 4 :])
    assert last > first + 500.0, f"ribbon must track the chirp: {first:.0f} -> {last:.0f} Hz"


def test_magic_select_tolerance_monotonic(chirp_spec: tuple[Path, Path], cancel_event) -> None:  # type: ignore[no-untyped-def]
    _wav, spec = chirp_spec
    seed = {"t": 10.0, "f": 2500.0}
    small = magic_select(spec, seed, {"tolerance_db": 6.0}, cancel_event)["cells"]
    large = magic_select(spec, seed, {"tolerance_db": 20.0}, cancel_event)["cells"]
    assert large > small


def test_magic_select_contiguous_vs_global(chirp_spec: tuple[Path, Path], cancel_event) -> None:  # type: ignore[no-untyped-def]
    _wav, spec = chirp_spec
    seed = {"t": 10.0, "f": 2500.0}
    contiguous = magic_select(spec, seed, {"tolerance_db": 12.0}, cancel_event)["cells"]
    global_ = magic_select(spec, seed, {"tolerance_db": 12.0, "contiguous": False}, cancel_event)[
        "cells"
    ]
    assert global_ >= contiguous


def test_contextual_threshold_survives_mix_level_ramp(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    """The WHOLE mix (tone + floor together) ramps 24 dB — e.g. a long master
    fade. Absolute tolerance keeps only the level-band around the seed;
    local-median (contextual) measures the tone RELATIVE to its own time-slice
    floor, which is invariant under the shared ramp, and keeps the whole line.
    (A tone ramping over a FIXED floor is out of scope for this mechanism —
    there the tone-to-floor gap itself changes.)"""
    n = 12 * SR
    t = np.arange(n) / SR
    gain = 10 ** ((-24 + 24 * t / 12) / 20)  # -24 dB -> 0 dB, applied to everything
    rng = np.random.default_rng(1)
    mix = 0.45 * np.sin(2 * np.pi * 800.0 * t) + 0.02 * rng.standard_normal(n)
    y = (gain * mix).astype(np.float32)
    wav = tmp_path / "ramp.wav"
    sf.write(wav, y.clip(-1, 1), SR, subtype="FLOAT")
    spec = tmp_path / "spec.zarr"
    build_spec_pyramid(wav, spec, SR, cancel_event)

    seed = {"t": 6.0, "f": 800.0}
    absolute = magic_select(spec, seed, {"tolerance_db": 5.0, "adapt": "none"}, cancel_event)
    contextual = magic_select(
        spec, seed, {"tolerance_db": 5.0, "adapt": "local_median"}, cancel_event
    )
    span_abs = absolute["bounds"]["t1"] - absolute["bounds"]["t0"]
    span_ctx = contextual["bounds"]["t1"] - contextual["bounds"]["t0"]
    assert span_ctx > 10.0, f"contextual must track the whole ramp, got {span_ctx:.1f}s"
    assert span_ctx > span_abs + 2.0, (
        f"contextual span {span_ctx:.1f}s must beat absolute {span_abs:.1f}s"
    )


def test_similar_segments_finds_repeats(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    """Three identical narrowband bursts + one different texture: seeding one
    burst finds all three and not the impostor."""
    rng = np.random.default_rng(11)
    n = 24 * SR
    y = 0.01 * rng.standard_normal(n)
    t = np.arange(n) / SR
    for start in (2.0, 10.0, 18.0):  # the repeating texture: 600 Hz band tone
        seg = (t >= start) & (t < start + 2.0)
        y[seg] += 0.4 * np.sin(2 * np.pi * 600.0 * t[seg])
    seg = (t >= 14.0) & (t < 16.0)  # the impostor: high band noise
    y[seg] += 0.4 * (rng.standard_normal(int(seg.sum())) * np.sin(2 * np.pi * 5000.0 * t[seg]))
    wav = tmp_path / "rep.wav"
    sf.write(wav, y.astype(np.float32).clip(-1, 1), SR, subtype="FLOAT")
    spec = tmp_path / "spec.zarr"
    build_spec_pyramid(wav, spec, SR, cancel_event)

    result = similar_segments(
        spec, {"t0": 2.2, "t1": 3.8}, {"threshold": 0.45, "min_segment_s": 0.5}, cancel_event
    )
    segments = result["segments"]
    hits = [s for s in segments if any(abs(s["t0"] - x) < 1.5 for x in (2.0, 10.0, 18.0))]
    assert len(hits) >= 3, f"must find all three repeats, got {segments}"
    assert not any(13.5 < s["t0"] < 16.5 for s in segments), "impostor texture must not match"


# -- endpoint round trips ---------------------------------------------------------


@pytest.fixture(scope="module")
def audio_id(client: TestClient, chirp_spec: tuple[Path, Path]) -> str:
    wav, _spec = chirp_spec
    response = client.post("/files/import", json={"path": str(wav), "mode": "copy"})
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    return str(info["result_ref"]["audio_id"])


def test_magic_select_endpoint_and_audition_roundtrip(client: TestClient, audio_id: str) -> None:
    response = client.post(
        "/select/magic",
        json={"audio_id": audio_id, "seed": {"t": 10.0, "f": 2500.0}, "tolerance_db": 15.0},
    )
    assert response.status_code == 200, response.text
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    selection = info["result_ref"]
    assert selection["cells"] > 0
    assert selection["selection_id"]

    # hear exactly what was selected
    response = client.post(
        "/audition", json={"audio_id": audio_id, "selection_id": selection["selection_id"]}
    )
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    project_root = Path(client.get("/project").json()["root"])
    rendered, sr = sf.read(project_root / info["result_ref"]["wav_path"], dtype="float32")
    # chirp band survives, out-of-band noise floor strongly attenuated
    mono = rendered if rendered.ndim == 1 else rendered[:, 0]
    spectrum = np.abs(np.fft.rfft(mono))
    freqs = np.fft.rfftfreq(len(mono), 1.0 / sr)
    inband = float((spectrum[(freqs > 1000) & (freqs < 4200)] ** 2).sum())
    out = float((spectrum[freqs > 6000] ** 2).sum())
    assert inband > 50 * out


def test_segments_audition_endpoint(client: TestClient, audio_id: str) -> None:
    response = client.post(
        "/audition",
        json={
            "audio_id": audio_id,
            "segments": [[5.0, 7.0], [12.0, 14.0]],
            "crossfade_ms": 40.0,
        },
    )
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    project_root = Path(client.get("/project").json()["root"])
    rendered, sr = sf.read(project_root / info["result_ref"]["wav_path"], dtype="float32")
    # ~4 s minus one crossfade overlap
    assert abs(len(rendered) / sr - 4.0) < 0.1
    assert info["result_ref"]["duration_s"] == pytest.approx(len(rendered) / sr, abs=0.01)


def test_audition_mode_exclusivity(client: TestClient, audio_id: str) -> None:
    response = client.post(
        "/audition",
        json={
            "audio_id": audio_id,
            "mask": {"t0": 0.0, "t1": 1.0},
            "segments": [[0.0, 1.0]],
        },
    )
    assert response.status_code == 400


def test_select_similar_endpoint(client: TestClient, audio_id: str) -> None:
    response = client.post(
        "/select/similar",
        json={"audio_id": audio_id, "seed": {"t0": 8.0, "t1": 12.0}, "threshold": 0.45},
    )
    assert response.status_code == 200, response.text
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    segments = info["result_ref"]["segments"]
    # the chirp region should match itself
    assert any(s["t0"] < 12.0 and s["t1"] > 8.0 for s in segments)


def test_segments_crossfade_no_clicks(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    """Joint discontinuity must be far smaller than a hard cut would produce."""
    t = np.arange(4 * SR) / SR
    y = (0.8 * np.sin(2 * np.pi * 300.0 * t)).astype(np.float32)
    wav = tmp_path / "tone.wav"
    sf.write(wav, y, SR, subtype="FLOAT")
    out = tmp_path / "joined.wav"
    render_segments_audition(
        wav, SR, 4.0, [[0.0, 1.0], [2.0, 3.0]], out, cancel_event, crossfade_ms=30.0
    )
    rendered, _ = sf.read(out, dtype="float32")
    mono = rendered if rendered.ndim == 1 else rendered[:, 0]
    jumps = np.abs(np.diff(mono))
    tone_step = 0.8 * 2 * np.pi * 300.0 / SR  # max slope of the tone itself
    assert float(jumps.max()) < 3 * tone_step, "no click at the crossfade joint"
