"""Framewise MPT curves: roughness, spectral entropy, template harmonicity.

The verified integration pattern (BUILD_SPEC §2 — do not deviate):

    audio → STFT frame → |X[k]| → scipy.signal.find_peaks (magnitude+prominence)
          → (freqs_Hz, mags_linear) → MPT scalar function → one point in a curve

- NEVER mpt.audio_peaks (whole-file extractor, not framewise).
- NEVER mpt.add_spectra on empirical peaks (would double-count harmonics).
- roughness: frequencies in Hz, linear magnitudes.
- entropy / harmonicity: Hz → absolute cents via mpt.convert_pitch (A4 = 6900).
- template_harmonicity returns a tuple (h_max, h_entropy); h_max is the curve
  value, h_entropy is kept as an aux column.
- Weights None ⇒ uniform (MATLAB [] is None, not []).
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray
from scipy.signal import find_peaks

from indra._vendor import mpt
from indra.analyses.framing import (
    frames_from_array,
    rfft_freqs,
    stream_magnitude_frames,
)
from indra.jobs.cancellation import CancelEvent, check_cancel

FloatArray = NDArray[np.float32]

DEFAULT_N_FFT = 4096
DEFAULT_HOP = 1024
DEFAULT_TOP_K = 64
# Relative prominence floor: fraction of the frame's max magnitude. Absolute
# thresholds fail across the huge level range of noisescape material. Must sit
# above the Hann window's first sidelobe (-31.5 dB ~= 2.7% of the main lobe),
# or spectral leakage shows up as spurious peaks around every strong partial.
DEFAULT_MIN_PROMINENCE_REL = 0.05
# Below this fraction of full-scale a frame is treated as silence (curve = 0).
SILENCE_FLOOR = 1e-5


def frame_peaks(
    mag_frame: NDArray[np.floating[Any]],
    freqs_hz: NDArray[np.floating[Any]],
    *,
    min_prominence: float | None = None,
    top_k: int = DEFAULT_TOP_K,
) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """Spectral peaks of one magnitude frame → (f_hz, w_lin), amplitude-desc, ≤ top_k."""
    peak_max = float(mag_frame.max()) if mag_frame.size else 0.0
    if peak_max <= 0.0:
        return np.empty(0), np.empty(0)
    prominence = (
        min_prominence if min_prominence is not None else DEFAULT_MIN_PROMINENCE_REL * peak_max
    )
    indices, _props = find_peaks(mag_frame, prominence=prominence)
    if indices.size == 0:
        return np.empty(0), np.empty(0)
    weights = mag_frame[indices].astype(np.float64)
    order = np.argsort(weights)[::-1][:top_k]
    indices = indices[order]
    return freqs_hz[indices].astype(np.float64), weights[order]


FrameFn = Callable[[NDArray[np.float64], NDArray[np.float64]], tuple[float, ...]]


def _roughness_frame(p_norm: float, average: bool) -> FrameFn:
    def fn(f_hz: NDArray[np.float64], w: NDArray[np.float64]) -> tuple[float, ...]:
        if f_hz.size < 2:
            return (0.0,)
        return (float(mpt.roughness(f_hz, w, p_norm=p_norm, average=average)),)

    return fn


# Grid resolution (cents/point) for entropy & harmonicity. 3-cent spacing
# still oversamples the sigma=10c Gaussian ~3x while cutting MPT's grid cost
# ~6x — required to hit the §6.4 perf targets (riskiest-assumption lever #2).
DEFAULT_RESOLUTION_CENTS = 3.0


def _entropy_frame(sigma_cents: float, resolution: float) -> FrameFn:
    # normalize=False: MPT's normalization divides by the max entropy of the
    # grid actually spanned by the peaks, which makes values incomparable
    # across frames with different spans (a lone tone can out-score a chord).
    # Raw Shannon entropy in bits is monotonic under densification.
    def fn(f_hz: NDArray[np.float64], w: NDArray[np.float64]) -> tuple[float, ...]:
        if f_hz.size == 0:
            return (0.0,)
        cents = mpt.convert_pitch(f_hz, "hz", "cents")
        return (
            float(
                mpt.spectral_entropy(cents, w, sigma_cents, normalize=False, resolution=resolution)
            ),
        )

    return fn


def _harmonicity_frame(sigma_cents: float, resolution: float) -> FrameFn:
    def fn(f_hz: NDArray[np.float64], w: NDArray[np.float64]) -> tuple[float, ...]:
        if f_hz.size == 0:
            return (0.0, 0.0)
        cents = mpt.convert_pitch(f_hz, "hz", "cents")
        h_max, h_entropy = mpt.template_harmonicity(cents, w, sigma_cents, resolution=resolution)
        return (float(h_max), float(h_entropy))

    return fn


def _curve_over_frames(
    frame_blocks: Any,
    freqs_hz: NDArray[np.float64],
    frame_fn: FrameFn,
    n_out: int,
    *,
    top_k: int,
    min_prominence: float | None,
    f0: float | None = None,
    f1: float | None = None,
    cancel_event: CancelEvent | None = None,
    progress_cb: Callable[[int], None] | None = None,
) -> list[NDArray[np.float32]]:
    """Run frame_fn over streamed magnitude frame blocks → n_out value arrays."""
    band = slice(None)
    if f0 is not None or f1 is not None:
        lo = int(np.searchsorted(freqs_hz, f0)) if f0 is not None else 0
        hi = int(np.searchsorted(freqs_hz, f1)) if f1 is not None else len(freqs_hz)
        band = slice(lo, max(hi, lo + 1))
    banded_freqs = freqs_hz[band]

    outs: list[list[float]] = [[] for _ in range(n_out)]
    done = 0
    for block in frame_blocks:
        if cancel_event is not None:
            check_cancel(cancel_event)
        for frame in block:
            mag = frame[band]
            if float(mag.max(initial=0.0)) < SILENCE_FLOOR:
                values: tuple[float, ...] = tuple(0.0 for _ in range(n_out))
            else:
                f_hz, w = frame_peaks(mag, banded_freqs, min_prominence=min_prominence, top_k=top_k)
                values = frame_fn(f_hz, w) if f_hz.size else tuple(0.0 for _ in range(n_out))
            for i, value in enumerate(values):
                outs[i].append(value)
        done += block.shape[0]
        if progress_cb is not None:
            progress_cb(done)
    return [np.asarray(column, dtype=np.float32) for column in outs]


# -- public curve API (BUILD_SPEC §2 signatures; array in, array out) ------------


def roughness_curve(
    y: FloatArray,
    sr: int,
    *,
    n_fft: int = DEFAULT_N_FFT,
    hop: int = DEFAULT_HOP,
    p_norm: float = 1.0,
    average: bool = False,
    top_k: int = DEFAULT_TOP_K,
    min_prominence: float | None = None,
    cancel_event: CancelEvent | None = None,
) -> FloatArray:
    window = np.hanning(n_fft + 1)[:-1]
    frames = frames_from_array(y, n_fft=n_fft, hop=hop, window=window)
    (curve,) = _curve_over_frames(
        [frames],
        rfft_freqs(sr, n_fft),
        _roughness_frame(p_norm, average),
        1,
        top_k=top_k,
        min_prominence=min_prominence,
        cancel_event=cancel_event,
    )
    return curve


def entropy_curve(
    y: FloatArray,
    sr: int,
    *,
    sigma_cents: float = 10.0,
    resolution: float = DEFAULT_RESOLUTION_CENTS,
    n_fft: int = DEFAULT_N_FFT,
    hop: int = DEFAULT_HOP,
    top_k: int = 32,
    min_prominence: float | None = None,
    cancel_event: CancelEvent | None = None,
) -> FloatArray:
    window = np.hanning(n_fft + 1)[:-1]
    frames = frames_from_array(y, n_fft=n_fft, hop=hop, window=window)
    (curve,) = _curve_over_frames(
        [frames],
        rfft_freqs(sr, n_fft),
        _entropy_frame(sigma_cents, resolution),
        1,
        top_k=top_k,
        min_prominence=min_prominence,
        cancel_event=cancel_event,
    )
    return curve


def template_harmonicity_curve(
    y: FloatArray,
    sr: int,
    *,
    sigma_cents: float = 10.0,
    resolution: float = DEFAULT_RESOLUTION_CENTS,
    n_fft: int = DEFAULT_N_FFT,
    hop: int = DEFAULT_HOP,
    top_k: int = 32,
    min_prominence: float | None = None,
    cancel_event: CancelEvent | None = None,
) -> tuple[FloatArray, FloatArray]:
    """Returns (h_max_curve, h_entropy_curve)."""
    window = np.hanning(n_fft + 1)[:-1]
    frames = frames_from_array(y, n_fft=n_fft, hop=hop, window=window)
    h_max, h_entropy = _curve_over_frames(
        [frames],
        rfft_freqs(sr, n_fft),
        _harmonicity_frame(sigma_cents, resolution),
        2,
        top_k=top_k,
        min_prominence=min_prominence,
        cancel_event=cancel_event,
    )
    return h_max, h_entropy


# -- streaming job entrypoint -----------------------------------------------------

CURVE_SPECS: dict[str, dict[str, Any]] = {
    "roughness_mpt": {"n_out": 1, "columns": ["value"]},
    "spectral_entropy_mpt": {"n_out": 1, "columns": ["value"]},
    "template_harmonicity_mpt": {"n_out": 2, "columns": ["value", "h_entropy"]},
}


def compute_curve_from_file(
    kind: str,
    path: Path,
    sr: int,
    params: dict[str, Any],
    cancel_event: CancelEvent,
    progress_cb: Callable[[float], None] | None = None,
    total_frames_estimate: int | None = None,
) -> dict[str, NDArray[np.float32]]:
    """Streamed, cancellable curve computation for the job system.

    params: n_fft, hop, top_k, min_prominence, p_norm/average or sigma_cents,
    region {t0, t1, f0, f1}.
    """
    n_fft = int(params.get("n_fft", DEFAULT_N_FFT))
    default_hop = 2048 if kind == "template_harmonicity_mpt" else DEFAULT_HOP
    default_top_k = DEFAULT_TOP_K if kind == "roughness_mpt" else 32
    hop = int(params.get("hop", default_hop))
    top_k = int(params.get("top_k", default_top_k))
    min_prominence = params.get("min_prominence")
    resolution = float(params.get("resolution", DEFAULT_RESOLUTION_CENTS))
    region = params.get("region") or {}
    t0, t1 = region.get("t0"), region.get("t1")
    f0, f1 = region.get("f0"), region.get("f1")

    if kind == "roughness_mpt":
        frame_fn = _roughness_frame(
            float(params.get("p_norm", 1.0)), bool(params.get("average", False))
        )
    elif kind == "spectral_entropy_mpt":
        frame_fn = _entropy_frame(float(params.get("sigma_cents", 10.0)), resolution)
    elif kind == "template_harmonicity_mpt":
        frame_fn = _harmonicity_frame(float(params.get("sigma_cents", 10.0)), resolution)
    else:
        raise ValueError(f"unknown MPT curve kind: {kind}")

    spec = CURVE_SPECS[kind]

    def frame_progress(done: int) -> None:
        if progress_cb is not None and total_frames_estimate:
            progress_cb(min(done / total_frames_estimate, 1.0))

    columns = _curve_over_frames(
        stream_magnitude_frames(
            path, sr, n_fft=n_fft, hop=hop, cancel_event=cancel_event, t0=t0, t1=t1
        ),
        rfft_freqs(sr, n_fft),
        frame_fn,
        int(spec["n_out"]),
        top_k=top_k,
        min_prominence=min_prominence,
        f0=f0,
        f1=f1,
        cancel_event=cancel_event,
        progress_cb=frame_progress,
    )
    start_s = float(t0) if t0 is not None else 0.0
    n = len(columns[0])
    times = (start_s + np.arange(n) * hop / sr).astype(np.float64)
    result: dict[str, NDArray[np.float32]] = {"time_s": times.astype(np.float32)}
    for name, column in zip(spec["columns"], columns, strict=True):
        result[name] = column
    return result
