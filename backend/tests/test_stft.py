"""STFT streaming correctness — the riskiest correctness assumption (§6.3).

Golden tests: streamed STFT (librosa.stream and the bespoke pyav-path streamer)
must match a whole-file librosa.stft(center=False) on the concatenated signal.
Fixtures cover a sine sweep, white noise, and silence, streamed in small blocks.
"""

from __future__ import annotations

import multiprocessing
from pathlib import Path

import librosa
import numpy as np
import pytest
import soundfile as sf
import zarr

from indra.ingest.stft import (
    HOP,
    N_FFT,
    _stft_frames,
    bh7_window,
    build_spec_pyramid,
    stream_mono_overlapped,
)
from tests.conftest import SR, _sine_sweep


@pytest.fixture(scope="module")
def cancel_event():  # type: ignore[no-untyped-def]
    return multiprocessing.Manager().Event()


def _write_float_wav(path: Path, y: np.ndarray, sr: int = SR) -> None:  # type: ignore[type-arg]
    sf.write(path, y, sr, subtype="FLOAT")


def _signals() -> dict[str, np.ndarray]:  # type: ignore[type-arg]
    rng = np.random.default_rng(42)
    return {
        "sweep": _sine_sweep(30.0, SR),
        "noise": (0.5 * rng.standard_normal(30 * SR)).clip(-1, 1).astype(np.float32),
        "silence": np.zeros(30 * SR, dtype=np.float32),
    }


@pytest.mark.parametrize("name", ["sweep", "noise", "silence"])
def test_streamed_stft_matches_full(tmp_path: Path, name: str) -> None:
    y = _signals()[name]
    path = tmp_path / f"{name}.wav"
    _write_float_wav(path, y)
    window = bh7_window()

    full = np.abs(
        librosa.stft(y, n_fft=N_FFT, hop_length=HOP, window=window, center=False)
    ).T.astype(np.float32)

    parts = [
        _stft_frames(np.asarray(block, dtype=np.float32), window)
        for block in librosa.stream(
            str(path),
            block_length=5 * SR // HOP,  # ~5-second blocks
            frame_length=N_FFT,
            hop_length=HOP,
            mono=True,
            fill_value=None,
        )
        if len(block) >= N_FFT
    ]
    streamed = np.concatenate(parts, axis=0)

    assert streamed.shape == full.shape
    boundary = N_FFT // HOP
    interior = slice(boundary, full.shape[0] - boundary)
    assert np.abs(full[interior] - streamed[interior]).max() < 1e-6


@pytest.mark.parametrize("name", ["sweep", "noise"])
def test_bespoke_streamer_matches_full(tmp_path: Path, name: str) -> None:
    """The pyav-path overlap streamer must be exactly as correct as librosa.stream."""
    y = _signals()[name]
    path = tmp_path / f"{name}.wav"
    _write_float_wav(path, y)
    window = bh7_window()

    full = np.abs(
        librosa.stft(y, n_fft=N_FFT, hop_length=HOP, window=window, center=False)
    ).T.astype(np.float32)
    parts = [_stft_frames(b, window) for b in stream_mono_overlapped(path, SR)]
    streamed = np.concatenate(parts, axis=0)

    assert streamed.shape == full.shape
    assert np.abs(full - streamed).max() < 1e-6


def test_bh7_window_properties() -> None:
    w = bh7_window()
    assert w.shape == (N_FFT,)
    assert w.max() <= 1.0 + 1e-9
    assert w[0] < 1e-4  # near-zero endpoints (very low sidelobe window)


def test_pyramid_full_scale_sine_hits_0db(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    t = np.arange(10 * SR) / SR
    y = np.sin(2 * np.pi * 1000.0 * t).astype(np.float32)
    path = tmp_path / "sine.wav"
    _write_float_wav(path, y)
    meta = build_spec_pyramid(path, tmp_path / "spec.zarr", SR, cancel_event)
    group = zarr.open_group(str(tmp_path / "spec.zarr"), mode="r")
    level0 = np.asarray(group["0"][:])
    # A full-scale sine must reach ~0 dB → 255 at the tone bin.
    assert level0.max() >= 250
    peak_bin = level0[5].argmax()
    assert abs(peak_bin - round(1000.0 / (SR / N_FFT))) <= 1
    assert meta["frames_level0"] == level0.shape[0]


def test_pyramid_silence_is_zero(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    path = tmp_path / "sil.wav"
    _write_float_wav(path, np.zeros(8 * SR, dtype=np.float32))
    build_spec_pyramid(path, tmp_path / "spec.zarr", SR, cancel_event)
    group = zarr.open_group(str(tmp_path / "spec.zarr"), mode="r")
    assert np.asarray(group["0"][:]).max() == 0


def test_pyramid_lods_maxpool(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    """LODs halve in time and preserve maxima (max-pool, not average)."""
    rng = np.random.default_rng(3)
    y = (0.6 * rng.standard_normal(int(140 * SR))).clip(-1, 1).astype(np.float32)
    path = tmp_path / "long.wav"
    _write_float_wav(path, y)
    meta = build_spec_pyramid(path, tmp_path / "spec.zarr", SR, cancel_event)
    assert meta["levels"] >= 2
    group = zarr.open_group(str(tmp_path / "spec.zarr"), mode="r")
    level0 = np.asarray(group["0"][:])
    level1 = np.asarray(group["1"][:])
    assert level1.shape[0] == (level0.shape[0] + 1) // 2
    assert level1.shape[1] == level0.shape[1]
    even = (level0.shape[0] // 2) * 2
    expected = np.maximum(level0[0:even:2], level0[1:even:2])
    assert np.array_equal(level1[: even // 2], expected)
    # Top level fits one time chunk.
    top = np.asarray(group[str(meta["levels"] - 1)][:])
    assert top.shape[0] <= 1024


def test_pyramid_too_short_file_raises(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    path = tmp_path / "tiny.wav"
    _write_float_wav(path, np.zeros(N_FFT // 2, dtype=np.float32))
    with pytest.raises(ValueError, match="too short"):
        build_spec_pyramid(path, tmp_path / "spec.zarr", SR, cancel_event)
