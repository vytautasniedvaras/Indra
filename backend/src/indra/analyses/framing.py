"""Streamed magnitude-spectrum frames for framewise analyses (BUILD_SPEC §2, §6.4).

audio → mono blocks (overlapped) → Hann-windowed numpy rfft → |X| frames.
Supports time regions (seek-based for soundfile formats) and cooperative
cancellation between blocks. Frames are yielded in blocks so callers can
report progress and check cancellation at spec-mandated granularity.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from indra.ingest.blocks import read_blocks
from indra.jobs.cancellation import CancelEvent, check_cancel

FRAMES_PER_BLOCK = 256  # cancellation checkpoint granularity (§6.4)

FloatArray = NDArray[np.float32]


def rfft_freqs(sr: int, n_fft: int) -> NDArray[np.float64]:
    return np.fft.rfftfreq(n_fft, d=1.0 / sr)


def frames_from_array(
    y: FloatArray, *, n_fft: int, hop: int, window: NDArray[np.float64]
) -> FloatArray:
    """Magnitude frames (n_frames, n_bins) of mono y; center=False alignment."""
    if len(y) < n_fft:
        return np.zeros((0, n_fft // 2 + 1), dtype=np.float32)
    strided = np.lib.stride_tricks.sliding_window_view(y, n_fft)[::hop]
    spectra = np.fft.rfft(strided * window, axis=1)
    return np.abs(spectra).astype(np.float32)


def stream_magnitude_frames(
    path: Path,
    sr: int,
    *,
    n_fft: int,
    hop: int,
    cancel_event: CancelEvent,
    t0: float | None = None,
    t1: float | None = None,
) -> Iterator[FloatArray]:
    """Yield (block_frames, n_bins) magnitude frames over [t0, t1) seconds.

    Frame k in the concatenated output starts at sample
    start_frame + k * hop, matching a whole-region rfft framing exactly.
    """
    window = np.hanning(n_fft + 1)[:-1]  # periodic Hann, matches librosa/scipy sym=False
    start = 0 if t0 is None else max(0, round(t0 * sr))
    end = None if t1 is None else round(t1 * sr)

    step = FRAMES_PER_BLOCK * hop
    tail: FloatArray = np.zeros(0, dtype=np.float32)
    for block in read_blocks(path, block_frames=step, start_frame=start, end_frame=end):
        check_cancel(cancel_event)
        mono = block.mean(axis=1).astype(np.float32)
        merged = np.concatenate([tail, mono])
        if len(merged) >= n_fft:
            frames = frames_from_array(merged, n_fft=n_fft, hop=hop, window=window)
            if frames.shape[0]:
                yield frames
            consumed = frames.shape[0] * hop
            tail = merged[consumed:].copy()
        else:
            tail = merged
    check_cancel(cancel_event)
