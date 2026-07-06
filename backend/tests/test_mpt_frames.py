"""Golden-value tests for the framewise MPT integration (§8.1).

Verifies the §2 pattern end-to-end on synthetic signals with known perceptual
ordering: peaks land where they should, curves match direct per-frame MPT
calls, and the classic phenomenology holds (unison smooth / semitone rough;
entropy grows with chord densification; harmonic tone beats inharmonic
cluster on template harmonicity).
"""

from __future__ import annotations

import multiprocessing
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from indra._vendor import mpt
from indra.analyses.framing import rfft_freqs
from indra.analyses.mpt_frames import (
    compute_curve_from_file,
    entropy_curve,
    frame_peaks,
    roughness_curve,
    template_harmonicity_curve,
)
from indra.jobs.cancellation import JobCancelledError

SR = 22050
N_FFT = 4096
HOP = 1024


@pytest.fixture(scope="module")
def cancel_event():  # type: ignore[no-untyped-def]
    return multiprocessing.Manager().Event()


def _tones(freqs: list[float], duration_s: float = 1.0, amps: list[float] | None = None):  # type: ignore[no-untyped-def]
    t = np.arange(int(duration_s * SR)) / SR
    amps = amps or [0.5 / max(1, len(freqs))] * len(freqs)
    y = sum(a * np.sin(2 * np.pi * f * t) for f, a in zip(freqs, amps, strict=True))
    return np.asarray(y, dtype=np.float32)


# -- frame_peaks -----------------------------------------------------------------


def test_frame_peaks_finds_known_partials() -> None:
    y = _tones([440.0, 880.0, 1320.0])
    window = np.hanning(N_FFT + 1)[:-1]
    mag = np.abs(np.fft.rfft(y[:N_FFT] * window))
    freqs = rfft_freqs(SR, N_FFT)
    f_hz, w = frame_peaks(mag, freqs, top_k=8)
    assert f_hz.size >= 3
    resolution = SR / N_FFT
    for target in (440.0, 880.0, 1320.0):
        assert np.min(np.abs(f_hz - target)) < resolution * 1.5, f"missing {target} Hz"
    # amplitude-descending order
    assert all(w[i] >= w[i + 1] for i in range(len(w) - 1))


def test_frame_peaks_top_k_cap() -> None:
    y = _tones([200.0 * k for k in range(1, 25)])
    window = np.hanning(N_FFT + 1)[:-1]
    mag = np.abs(np.fft.rfft(y[:N_FFT] * window))
    f_hz, _w = frame_peaks(mag, rfft_freqs(SR, N_FFT), top_k=10)
    assert f_hz.size == 10


def test_frame_peaks_silence_empty() -> None:
    f_hz, w = frame_peaks(np.zeros(N_FFT // 2 + 1), rfft_freqs(SR, N_FFT))
    assert f_hz.size == 0 and w.size == 0


# -- roughness -------------------------------------------------------------------


def test_roughness_semitone_rougher_than_unison_and_octave() -> None:
    rough = roughness_curve(_tones([440.0, 466.16]), SR).mean()
    unison = roughness_curve(_tones([440.0]), SR).mean()
    octave = roughness_curve(_tones([440.0, 880.0]), SR).mean()
    assert rough > octave > unison


def test_roughness_curve_matches_direct_mpt_reference() -> None:
    """Framewise curve equals a hand-rolled per-frame reference within 1e-3 (§8.1)."""
    y = _tones([300.0, 320.0], duration_s=0.8)
    curve = roughness_curve(y, SR)

    window = np.hanning(N_FFT + 1)[:-1]
    freqs = rfft_freqs(SR, N_FFT)
    reference = []
    for start in range(0, len(y) - N_FFT + 1, HOP):
        mag = np.abs(np.fft.rfft(y[start : start + N_FFT] * window))
        f_hz, w = frame_peaks(mag, freqs)
        reference.append(mpt.roughness(f_hz, w) if f_hz.size >= 2 else 0.0)
    assert curve.shape == (len(reference),)
    assert np.abs(curve - np.asarray(reference, dtype=np.float32)).max() < 1e-3


def test_roughness_profile_tracks_dyad_over_time() -> None:
    """unison → semitone dyad → unison must produce a low-high-low curve."""
    segments = [
        _tones([440.0], duration_s=0.8),
        _tones([440.0, 466.16], duration_s=0.8),
        _tones([440.0], duration_s=0.8),
    ]
    y = np.concatenate(segments)
    curve = roughness_curve(y, SR)
    third = len(curve) // 3
    # exclude boundary frames that straddle two segments
    margin = (4096 // 1024) + 1
    low1 = curve[: third - margin].mean()
    high = curve[third + margin : 2 * third - margin].mean()
    low2 = curve[2 * third + margin :].mean()
    assert high > 4 * low1
    assert high > 4 * low2


# -- spectral entropy -------------------------------------------------------------


def test_entropy_monotonic_under_chord_densification() -> None:
    single = entropy_curve(_tones([440.0]), SR).mean()
    triad = entropy_curve(_tones([440.0, 554.37, 659.26]), SR).mean()
    cluster = entropy_curve(_tones([440.0, 466.16, 493.88, 523.25, 554.37, 587.33]), SR).mean()
    assert single < triad < cluster


# -- template harmonicity ----------------------------------------------------------


def test_harmonicity_harmonic_beats_inharmonic() -> None:
    harmonic = _tones([220.0 * k for k in range(1, 7)], amps=[0.4 / k for k in range(1, 7)])
    inharmonic = _tones([220.0, 341.0, 522.0, 764.0, 1101.0, 1502.0])
    h_harm, _ = template_harmonicity_curve(harmonic, SR)
    h_inharm, _ = template_harmonicity_curve(inharmonic, SR)
    assert h_harm.mean() > h_inharm.mean()


def test_harmonicity_returns_both_measures() -> None:
    h_max, h_entropy = template_harmonicity_curve(_tones([440.0, 880.0]), SR)
    assert h_max.shape == h_entropy.shape
    assert 0.0 <= h_max.mean() <= 1.0


# -- streaming job path ------------------------------------------------------------


def _write(tmp_path: Path, y, name: str = "x.wav") -> Path:  # type: ignore[no-untyped-def]
    path = tmp_path / name
    sf.write(path, y, SR, subtype="FLOAT")
    return path


def test_streamed_curve_matches_array_curve(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    y = _tones([440.0, 466.16], duration_s=3.0)
    path = _write(tmp_path, y)
    streamed = compute_curve_from_file("roughness_mpt", path, SR, {}, cancel_event)
    direct = roughness_curve(y, SR)
    assert np.abs(streamed["value"] - direct).max() < 1e-4


def test_region_scoped_curve(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    y = _tones([440.0, 466.16], duration_s=4.0)
    path = _write(tmp_path, y)
    result = compute_curve_from_file(
        "roughness_mpt", path, SR, {"region": {"t0": 1.0, "t1": 2.0}}, cancel_event
    )
    assert result["time_s"][0] == pytest.approx(1.0, abs=0.05)
    assert result["time_s"][-1] <= 2.0
    expected = round(SR / HOP)  # ~1 s of frames
    assert abs(len(result["value"]) - expected) <= 4


def test_frequency_band_region(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    """Band-limiting to one tone of a rough dyad kills the roughness."""
    y = _tones([440.0, 466.16], duration_s=1.0)
    path = _write(tmp_path, y)
    full = compute_curve_from_file("roughness_mpt", path, SR, {}, cancel_event)
    banded = compute_curve_from_file(
        "roughness_mpt", path, SR, {"region": {"f0": 400.0, "f1": 450.0}}, cancel_event
    )
    assert banded["value"].mean() < 0.1 * full["value"].mean()


def test_cancellation_raises(tmp_path: Path) -> None:
    event = multiprocessing.Manager().Event()
    event.set()
    y = _tones([440.0], duration_s=2.0)
    path = _write(tmp_path, y)
    with pytest.raises(JobCancelledError):
        compute_curve_from_file("roughness_mpt", path, SR, {}, event)
