"""Filtered-selection audition: STFT → mask → ISTFT → scratch WAV (§5.5, ADR 0008).

"Hear the selected time-frequency box in isolation." Backend-rendered because
spectral masking beats realtime EQ band-passing for arbitrary boxes. Rendered
WAVs are content-addressed by mask hash (cached; LRU-evictable blobs).

Mask forms:
- rectangle {t0, t1, f0, f1} with raised-cosine edge fades (fade_hz, fade_ms);
- ribbons (from magic select): per-time-slice frequency intervals, feathered;
- segments [[t0,t1], ...]: unmasked extracts joined with equal-power crossfades
  (segmented playback with feathering at every joint).
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


def _raised_cosine(n: int) -> NDArray[np.float32]:
    """0→1 raised-cosine ramp, n samples (sin² of a quarter period)."""
    amplitude = np.sin(np.linspace(0.0, np.pi / 2, n, dtype=np.float32))
    ramp: NDArray[np.float32] = amplitude * amplitude
    return ramp


def _fade_piece_edges(piece: NDArray[np.float32], power_ramp: NDArray[np.float32]) -> None:
    """Raised-cosine (power) fade-in/out on a segment's outer edges, in place.

    `power_ramp` is the shared full-length crossfade ramp; segments shorter
    than it get the partial slice, so the join's undo stays exact.
    """
    edge = min(len(power_ramp), piece.shape[0] // 2)
    if edge <= 0:
        return
    ramp = power_ramp[:edge, np.newaxis]
    piece[:edge] *= ramp
    piece[piece.shape[0] - edge :] *= ramp[::-1]


def _equal_power_join(
    prev: NDArray[np.float32],
    piece: NDArray[np.float32],
    power_ramp: NDArray[np.float32],
    amplitude_ramp: NDArray[np.float32],
) -> NDArray[np.float32]:
    """Overlap `piece`'s head onto `prev`'s tail with an equal-power crossfade.

    Both edges already carry raised-cosine (power) fades from
    _fade_piece_edges; an equal-power joint needs AMPLITUDE fades (sin/cos, so
    sin²+cos²=1). Rather than special-casing the fade application, undo the
    power window on the overlapping region and re-apply the amplitude window.
    Mutates prev's tail; returns piece with the overlapped head trimmed.
    """
    overlap = min(len(power_ramp), piece.shape[0] // 2, prev.shape[0])
    if overlap <= 0:
        return piece
    power = power_ramp[:overlap, np.newaxis]
    amplitude = amplitude_ramp[:overlap, np.newaxis]
    head = piece[:overlap] / np.maximum(power, 1e-6) * amplitude
    tail = prev[-overlap:] / np.maximum(power[::-1], 1e-6) * amplitude[::-1]
    prev[-overlap:] = tail + head
    return piece[overlap:]


def _fade_edges(rendered: NDArray[np.float32], sr: int, fade_ms: float) -> None:
    n_frames = rendered.shape[0]
    fade_n = min(n_frames // 2, max(1, round(fade_ms / 1000.0 * sr)))
    ramp = _raised_cosine(fade_n)
    rendered[:fade_n] *= ramp[:, np.newaxis]
    rendered[n_frames - fade_n :] *= ramp[::-1][:, np.newaxis]


def render_ribbons_audition(
    audio_path: Path,
    sr: int,
    duration_s: float,
    ribbons: list[dict[str, Any]],
    out_path: Path,
    cancel_event: CancelEvent,
    fade_hz: float = 50.0,
    fade_ms: float = 15.0,
) -> dict[str, Any]:
    """Render a magic-selection (per-time-slice frequency intervals) in isolation.

    Builds a per-STFT-frame soft gain mask from the ribbons, feathered in both
    axes, and applies it in the STFT domain.
    """
    import librosa
    import scipy.ndimage

    if not ribbons:
        raise ValueError("selection has no ribbons")
    t0 = max(0.0, float(ribbons[0]["t0"]))
    t1 = min(duration_s, float(ribbons[-1]["t1"]))
    if t1 - t0 > MAX_AUDITION_S:
        raise ValueError(
            f"selection spans {t1 - t0:.0f}s; audition maximum is {MAX_AUDITION_S:.0f}s"
        )
    region = read_range(audio_path, round(t0 * sr), round(t1 * sr))
    n_frames, n_channels = region.shape
    if n_frames < N_FFT:
        raise ValueError("selection too short to audition (needs >= one STFT window)")

    n_bins = N_FFT // 2 + 1
    # Upper bound on librosa.stft(center=True) column count for n_frames; the
    # render loop below clips to the actual spectrum width per channel.
    n_cols = 1 + (n_frames - N_FFT) // HOP + N_FFT // HOP
    # Build the binary mask on the audition STFT grid.
    hz_per_bin = sr / N_FFT
    mask = np.zeros((n_bins, n_cols), dtype=np.float32)
    for ribbon in ribbons:
        c0 = int((float(ribbon["t0"]) - t0) * sr / HOP)
        c1 = max(c0 + 1, int((float(ribbon["t1"]) - t0) * sr / HOP))
        for f_lo, f_hi in ribbon["intervals"]:
            b0 = int(float(f_lo) / hz_per_bin)
            b1 = max(b0 + 1, int(float(f_hi) / hz_per_bin))
            mask[b0 : min(b1, n_bins), max(0, c0) : min(c1, n_cols)] = 1.0
    check_cancel(cancel_event)
    # Feather: gaussian blur, sigma from fade_hz / fade_ms.
    sigma_bins = max(0.5, fade_hz / hz_per_bin / 2)
    sigma_cols = max(0.5, (fade_ms / 1000.0) * sr / HOP / 2)
    mask = scipy.ndimage.gaussian_filter(mask, sigma=(sigma_bins, sigma_cols))
    mask = np.clip(mask, 0.0, 1.0)

    rendered = np.empty_like(region)
    for channel in range(n_channels):
        check_cancel(cancel_event)
        spectrum = librosa.stft(region[:, channel], n_fft=N_FFT, hop_length=HOP)
        cols = min(spectrum.shape[1], mask.shape[1])
        spectrum[:, :cols] *= mask[:, :cols]
        spectrum[:, cols:] = 0.0
        rendered[:, channel] = librosa.istft(spectrum, n_fft=N_FFT, hop_length=HOP, length=n_frames)
    _fade_edges(rendered, sr, fade_ms)
    check_cancel(cancel_event)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(out_path, rendered, sr, subtype="FLOAT")
    return {"t0": t0, "t1": t1, "sr": sr, "channels": n_channels, "duration_s": t1 - t0}


def render_segments_audition(
    audio_path: Path,
    sr: int,
    duration_s: float,
    segments: list[list[float]],
    out_path: Path,
    cancel_event: CancelEvent,
    crossfade_ms: float = 30.0,
) -> dict[str, Any]:
    """Concatenate time segments with equal-power crossfades (feathered joints)."""
    if not segments:
        raise ValueError("no segments to play")
    clean = []
    for t0, t1 in segments:
        t0 = max(0.0, float(t0))
        t1 = min(duration_s, float(t1))
        if t1 > t0:
            clean.append((t0, t1))
    total = sum(t1 - t0 for t0, t1 in clean)
    if total <= 0:
        raise ValueError("segments are empty after clamping")
    if total > MAX_AUDITION_S:
        raise ValueError(f"segments total {total:.0f}s; audition maximum is {MAX_AUDITION_S:.0f}s")

    fade_n = max(1, round(crossfade_ms / 1000.0 * sr))
    amplitude_ramp: NDArray[np.float32] = np.sin(
        np.linspace(0.0, np.pi / 2, fade_n, dtype=np.float32)
    )
    power_ramp: NDArray[np.float32] = amplitude_ramp * amplitude_ramp
    pieces: list[NDArray[np.float32]] = []
    for index, (t0, t1) in enumerate(clean):
        check_cancel(cancel_event)
        piece = read_range(audio_path, round(t0 * sr), round(t1 * sr)).copy()
        _fade_piece_edges(piece, power_ramp)
        if index > 0 and pieces:
            piece = _equal_power_join(pieces[-1], piece, power_ramp, amplitude_ramp)
        pieces.append(piece)
    rendered = np.concatenate(pieces, axis=0)
    check_cancel(cancel_event)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(out_path, rendered, sr, subtype="FLOAT")
    return {
        "segments": [[t0, t1] for t0, t1 in clean],
        "sr": sr,
        "channels": rendered.shape[1],
        "duration_s": rendered.shape[0] / sr,
    }
