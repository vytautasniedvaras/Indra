"""Shared fixtures: synthetic audio files and a lifespan-managed test client."""

from __future__ import annotations

import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from indra.app import create_app
from indra.config import ServerConfig

TEST_TOKEN = "test-token"
SR = 22050  # small fixtures, fast tests


def _sine_sweep(duration_s: float, sr: int, f0: float = 100.0, f1: float = 8000.0) -> Any:
    t = np.arange(int(duration_s * sr)) / sr
    # Exponential sweep
    k = (f1 / f0) ** (1 / duration_s)
    phase = 2 * np.pi * f0 * (k**t - 1) / np.log(k)
    return (0.8 * np.sin(phase)).astype(np.float32)


@pytest.fixture(scope="session")
def fixture_dir(tmp_path_factory: pytest.TempPathFactory) -> Path:
    root = tmp_path_factory.mktemp("audio-fixtures")
    rng = np.random.default_rng(20260706)

    sweep = _sine_sweep(5.0, SR)
    sf.write(root / "sweep.wav", np.stack([sweep, sweep * 0.5], axis=1), SR, subtype="PCM_16")

    noise = (0.5 * rng.standard_normal(3 * SR)).clip(-1, 1).astype(np.float32)
    sf.write(root / "noise.flac", noise, SR)

    sf.write(root / "silence.wav", np.zeros(2 * SR, dtype=np.float32), SR, subtype="PCM_16")

    _write_m4a(root / "tone.m4a", 2.0, SR)
    return root


def _write_m4a(path: Path, duration_s: float, sr: int) -> None:
    """Encode a 440 Hz tone as AAC/m4a to exercise the pyav fallback path."""
    import av

    t = np.arange(int(duration_s * sr)) / sr
    tone = (0.6 * np.sin(2 * np.pi * 440.0 * t)).astype(np.float32)
    with av.open(str(path), "w") as container:
        stream = container.add_stream("aac", rate=sr)
        stream.layout = "mono"
        chunk = 1024
        for start in range(0, len(tone), chunk):
            block = tone[start : start + chunk]
            frame = av.AudioFrame.from_ndarray(block[np.newaxis, :], format="fltp", layout="mono")
            frame.sample_rate = sr
            frame.pts = start
            container.mux(stream.encode(frame))
        container.mux(stream.encode(None))


@pytest.fixture(scope="module")
def client(tmp_path_factory: pytest.TempPathFactory) -> Iterator[TestClient]:
    project = tmp_path_factory.mktemp("proj") / "test.indra"
    config = ServerConfig(project_root=project, token=TEST_TOKEN, max_workers=2)
    app = create_app(config)
    with TestClient(app) as test_client:
        test_client.headers["Authorization"] = f"Bearer {TEST_TOKEN}"
        yield test_client


def wait_for_job(client: TestClient, job_id: str, timeout_s: float = 60.0) -> dict[str, Any]:
    """Poll a job until it reaches a terminal state."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        info: dict[str, Any] = client.get(f"/jobs/{job_id}").json()
        if info["state"] in ("done", "failed", "cancelled"):
            return info
        time.sleep(0.05)
    raise TimeoutError(f"job {job_id} did not finish within {timeout_s}s")
