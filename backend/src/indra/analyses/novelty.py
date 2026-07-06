"""Multi-scale Foote checkerboard novelty (BUILD_SPEC §6.4).

feature (MFCC or chroma) → recurrence matrix (affinity) → path enhancement →
Foote checkerboard novelty at scales {8, 32, 128} s (libfmp reference kernel).

The feature sequence is decimated so the self-similarity matrix stays bounded
(≤ MAX_SSM_FRAMES per side) for arbitrarily long inputs (§4.4).
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray

from indra.ingest.blocks import read_blocks
from indra.jobs.cancellation import CancelEvent, check_cancel

MAX_SSM_FRAMES = 4096
SEGMENT_S = 60.0
DEFAULT_SCALES_S = (8.0, 32.0, 128.0)


def _feature_frames(
    path: Path,
    sr: int,
    feature: str,
    hop: int,
    start_frame: int,
    end_frame: int | None,
    cancel_event: CancelEvent,
    progress_cb: Callable[[float], None] | None,
    total: int | None,
) -> NDArray[np.float32]:
    """Framewise features computed per segment; frame-local, so seams are exact."""
    import librosa

    segment = round(SEGMENT_S * sr)
    segment -= segment % hop
    parts: list[NDArray[np.float32]] = []
    position = start_frame
    tail: NDArray[np.float32] = np.zeros(0, dtype=np.float32)
    while True:
        check_cancel(cancel_event)
        seg_end = position + segment
        if end_frame is not None:
            seg_end = min(seg_end, end_frame)
        if seg_end <= position:
            break
        blocks = list(read_blocks(path, 1 << 20, position, seg_end))
        if not blocks:
            break
        mono = np.concatenate(blocks, axis=0).mean(axis=1).astype(np.float32)
        y = np.concatenate([tail, mono])
        if feature == "chroma":
            frames = librosa.feature.chroma_stft(y=y, sr=sr, hop_length=hop, center=False)
        else:
            frames = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=20, hop_length=hop, center=False)
        parts.append(frames.astype(np.float32))
        consumed = frames.shape[1] * hop
        tail = y[consumed:]
        got = len(mono)
        position += got
        if progress_cb is not None and total:
            progress_cb(min((position - start_frame) / total, 1.0))
        if got < seg_end - (position - got):
            break
    if not parts:
        return np.zeros((20, 0), dtype=np.float32)
    return np.concatenate(parts, axis=1)


def _checkerboard_kernel(half: int) -> NDArray[np.float64]:
    """Gaussian-tapered checkerboard kernel (Foote 2000; libfmp C4 reference)."""
    size = 2 * half + 1
    axis = np.arange(-half, half + 1)
    taper = np.exp(-((axis / (half / 2.0 + 1e-9)) ** 2))
    gaussian = np.outer(taper, taper)
    signs = np.outer(np.sign(axis + 0.5), np.sign(axis + 0.5))
    kernel = gaussian * signs
    kernel /= np.abs(kernel).sum() or 1.0
    assert kernel.shape == (size, size)
    return kernel


def _novelty_from_ssm(ssm: NDArray[np.float64], half: int) -> NDArray[np.float32]:
    kernel = _checkerboard_kernel(half)
    n = ssm.shape[0]
    padded = np.pad(ssm, half, mode="constant")
    novelty = np.empty(n, dtype=np.float32)
    for i in range(n):
        window = padded[i : i + 2 * half + 1, i : i + 2 * half + 1]
        novelty[i] = float((window * kernel).sum())
    return np.clip(novelty, 0.0, None)


def foote_novelty(
    path: Path,
    sr: int,
    params: dict[str, Any],
    cancel_event: CancelEvent,
    progress_cb: Callable[[float], None] | None = None,
    duration_s: float | None = None,
) -> dict[str, NDArray[np.float32]]:
    """Returns time_s plus one novelty column per scale (novelty_8s, …)."""
    import librosa
    import librosa.segment
    import scipy.ndimage

    feature = str(params.get("feature", "mfcc"))
    scales = tuple(float(s) for s in params.get("scales_s", DEFAULT_SCALES_S))
    hop = int(params.get("hop", 2048))
    region = params.get("region") or {}
    t0 = float(region.get("t0", 0.0))
    t1 = region.get("t1")

    start_frame = round(t0 * sr)
    end_frame = None if t1 is None else round(float(t1) * sr)
    total = None
    if end_frame is not None:
        total = end_frame - start_frame
    elif duration_s is not None:
        total = round(duration_s * sr) - start_frame

    frames = _feature_frames(
        path, sr, feature, hop, start_frame, end_frame, cancel_event, progress_cb, total
    )
    n = frames.shape[1]
    if n < 8:
        empty = np.zeros(0, dtype=np.float32)
        out = {"time_s": empty}
        for scale in scales:
            out[f"novelty_{scale:g}s"] = empty
        return out

    # Decimate so the SSM stays bounded for hours-long input.
    decimate = max(1, int(np.ceil(n / MAX_SSM_FRAMES)))
    if decimate > 1:
        cut = (n // decimate) * decimate
        frames = frames[:, :cut].reshape(frames.shape[0], -1, decimate).mean(axis=2)
        n = frames.shape[1]
    feature_rate = sr / (hop * decimate)

    check_cancel(cancel_event)
    stacked = librosa.feature.stack_memory(frames, n_steps=2, mode="edge")
    recurrence = librosa.segment.recurrence_matrix(  # type: ignore[attr-defined]
        stacked, mode="affinity", sym=True, self=True
    ).astype(np.float64)
    check_cancel(cancel_event)
    # Path enhancement: modest diagonal median smoothing.
    enhanced = scipy.ndimage.median_filter(recurrence, size=(1, 5))

    times = (t0 + np.arange(n) * (hop * decimate) / sr).astype(np.float32)
    out = {"time_s": times}
    for scale in scales:
        check_cancel(cancel_event)
        half = max(2, round(scale * feature_rate / 2))
        half = min(half, max(2, n // 2 - 1))
        out[f"novelty_{scale:g}s"] = _novelty_from_ssm(enhanced, half)
    return out
