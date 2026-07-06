"""Filtered-selection audition: STFT → mask → ISTFT → scratch WAV (§5.5, ADR 0008).

"Hear the selected time-frequency box in isolation." Backend-rendered because
spectral masking beats realtime EQ band-passing for arbitrary boxes. Rendered
WAVs are content-addressed by mask hash (cached; LRU-evictable blobs).

MVP mask: a rectangle {t0, t1, f0, f1} with raised-cosine edge fades in both
frequency (fade_hz) and time (fade_ms). Lasso / harmonic-follower masks later.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf
from numpy.typing import NDArray

from indra.ingest.blocks import read_range
from indra.jobs.cancellation import CancelEvent, check_cancel

N_FFT = 4096
HOP = 1024
MAX_AUDITION_S = 600.0  # §4.7: bound the in-memory render; longer selections must be split


def _freq_mask(
    n_bins: int, sr: int, f0: float | None, f1: float | None, fade_hz: float
) -> NDArray[np.float32]:
    """Raised-cosine band mask over rfft bins."""
    freqs = np.fft.rfftfreq(N_FFT, d=1.0 / sr)
    mask = np.ones(n_bins, dtype=np.float32)
    if f0 is not None:
        mask *= np.clip((freqs - (f0 - fade_hz)) / max(fade_hz, 1e-6), 0.0, 1.0).astype(np.float32)
    if f1 is not None:
        mask *= np.clip(((f1 + fade_hz) - freqs) / max(fade_hz, 1e-6), 0.0, 1.0).astype(np.float32)
    # smooth the linear ramps into raised cosine
    smoothed: NDArray[np.float32] = np.sin(mask * np.pi / 2).astype(np.float32) ** 2
    return smoothed


def render_audition(
    audio_path: Path,
    sr: int,
    duration_s: float,
    mask: dict[str, Any],
    out_path: Path,
    cancel_event: CancelEvent,
) -> dict[str, Any]:
    """Render the masked region to a WAV at out_path; returns metadata."""
    import librosa

    t0 = max(0.0, float(mask.get("t0", 0.0)))
    t1 = min(duration_s, float(mask.get("t1", duration_s)))
    if t1 <= t0:
        raise ValueError("mask t1 must be > t0")
    if t1 - t0 > MAX_AUDITION_S:
        raise ValueError(f"audition selection is {t1 - t0:.0f}s; maximum is {MAX_AUDITION_S:.0f}s")
    f0 = mask.get("f0")
    f1 = mask.get("f1")
    fade_hz = float(mask.get("fade_hz", 50.0))
    fade_ms = float(mask.get("fade_ms", 15.0))

    region = read_range(audio_path, round(t0 * sr), round(t1 * sr))
    check_cancel(cancel_event)
    n_frames, n_channels = region.shape
    if n_frames < N_FFT:
        raise ValueError("selection too short to audition (needs >= one STFT window)")

    band = _freq_mask(N_FFT // 2 + 1, sr, f0, f1, fade_hz)
    rendered = np.empty_like(region)
    for channel in range(n_channels):
        check_cancel(cancel_event)
        spectrum = librosa.stft(region[:, channel], n_fft=N_FFT, hop_length=HOP)
        spectrum *= band[:, np.newaxis]
        rendered[:, channel] = librosa.istft(spectrum, n_fft=N_FFT, hop_length=HOP, length=n_frames)

    # time-domain edge fades against clicks
    fade_n = min(n_frames // 2, max(1, round(fade_ms / 1000.0 * sr)))
    ramp = np.sin(np.linspace(0.0, np.pi / 2, fade_n, dtype=np.float32)) ** 2
    rendered[:fade_n] *= ramp[:, np.newaxis]
    rendered[n_frames - fade_n :] *= ramp[::-1][:, np.newaxis]

    check_cancel(cancel_event)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(out_path, rendered, sr, subtype="FLOAT")
    return {
        "t0": t0,
        "t1": t1,
        "f0": f0,
        "f1": f1,
        "sr": sr,
        "channels": n_channels,
        "duration_s": (t1 - t0),
    }
