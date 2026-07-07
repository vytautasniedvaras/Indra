"""Onset detection: PCEN(mel) → SuperFlux → peak-pick (BUILD_SPEC §6.4).

Params per spec: n_fft=1024, hop=sr/200, n_mels=138, fmin=27.5, fmax=16000,
SuperFlux via onset_strength(lag=2, max_size=3).

Long files are processed in overlapped segments (PCEN's IIR smoother needs
warm-up, so each segment carries lead-in that is discarded) — memory stays
bounded regardless of file length (§4.4).
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray

from indra.ingest.blocks import read_blocks
from indra.jobs.cancellation import CancelEvent, check_cancel

SEGMENT_S = 60.0
WARMUP_S = 2.0

# librosa.onset.onset_detect's frame defaults, expressed in seconds (they are
# computed as time*sr/hop internally). Kept here so a re-pick with no overrides
# reproduces the original detection exactly.
PICK_DEFAULTS = {
    "delta": 0.07,
    "wait_s": 0.03,
    "pre_max_s": 0.03,
    "post_max_s": 0.0,
    "pre_avg_s": 0.10,
    "post_avg_s": 0.10,
}


def pick_peaks(
    envelope: NDArray[np.float32],
    env_times: NDArray[np.float32],
    params: dict[str, Any],
    region: tuple[float | None, float | None] | None = None,
) -> dict[str, NDArray[np.float32]]:
    """Peak-pick an onset-strength envelope; the cheap, re-runnable half of detection.

    `delta` is the sensitivity knob; the *_s windows shape the local-max /
    local-mean tests. Batch re-thresholding = call this again on the saved
    envelope with different params — no PCEN/SuperFlux recomputation.

    The envelope is [0,1]-normalized over the WHOLE input (librosa-identical
    math) before any `region` restriction, so a given `delta` means the same
    thing file-wide — re-picking a quiet region does not silently rescale it.
    """
    import librosa.onset
    import librosa.util

    if len(envelope) < 2:
        empty = np.zeros(0, dtype=np.float32)
        return {"onset_t": empty, "onset_strength": empty}
    dt = float(env_times[1] - env_times[0])
    sr_eff = 1.0 / dt  # envelope frame rate; frames == samples at hop 1
    normalized = envelope - np.min(envelope)
    normalized = normalized / (np.max(normalized) + librosa.util.tiny(normalized))
    if region is not None:
        t0, t1 = region
        lo = int(np.searchsorted(env_times, t0)) if t0 is not None else 0
        hi = int(np.searchsorted(env_times, t1)) if t1 is not None else len(env_times)
        normalized, env_times, envelope = normalized[lo:hi], env_times[lo:hi], envelope[lo:hi]
        if len(normalized) < 2:
            empty = np.zeros(0, dtype=np.float32)
            return {"onset_t": empty, "onset_strength": empty}
    merged = {**PICK_DEFAULTS, **{k: float(v) for k, v in params.items() if k in PICK_DEFAULTS}}
    peak_indices = librosa.onset.onset_detect(  # type: ignore[attr-defined]
        onset_envelope=normalized,
        sr=sr_eff,
        hop_length=1,
        units="frames",
        backtrack=False,
        normalize=False,
        delta=merged["delta"],
        wait=max(1, int(merged["wait_s"] * sr_eff)),
        pre_max=max(1, int(merged["pre_max_s"] * sr_eff)),
        post_max=max(1, int(merged["post_max_s"] * sr_eff) + 1),
        pre_avg=max(1, int(merged["pre_avg_s"] * sr_eff)),
        post_avg=max(1, int(merged["post_avg_s"] * sr_eff) + 1),
    )
    return {"onset_t": env_times[peak_indices], "onset_strength": envelope[peak_indices]}


def detect_onsets(
    path: Path,
    sr: int,
    params: dict[str, Any],
    cancel_event: CancelEvent,
    progress_cb: Callable[[float], None] | None = None,
    duration_s: float | None = None,
) -> dict[str, NDArray[np.float32]]:
    """Returns onset times/strengths plus the full strength envelope."""
    import librosa
    import librosa.onset

    n_fft = int(params.get("n_fft", 1024))
    hop = int(params.get("hop", max(1, round(sr / 200))))
    n_mels = int(params.get("n_mels", 138))
    fmin = float(params.get("fmin", 27.5))
    fmax = float(params.get("fmax", min(16000.0, sr / 2)))
    region = params.get("region") or {}
    t0 = float(region.get("t0", 0.0))
    t1 = region.get("t1")

    start_frame = round(t0 * sr)
    end_frame = None if t1 is None else round(float(t1) * sr)

    segment_frames = round(SEGMENT_S * sr)
    warmup_frames = round(WARMUP_S * sr)
    # Align segments to hop so envelope frames concatenate exactly.
    segment_frames -= segment_frames % hop
    warmup_frames -= warmup_frames % hop

    envelope_parts: list[NDArray[np.float32]] = []
    position = start_frame
    total = None
    if end_frame is not None:
        total = end_frame - start_frame
    elif duration_s is not None:
        total = round(duration_s * sr) - start_frame

    while True:
        check_cancel(cancel_event)
        lead = warmup_frames if position > start_frame else 0
        seg_start = position - lead
        seg_end = position + segment_frames
        if end_frame is not None:
            seg_end = min(seg_end, end_frame)
        if seg_end <= position:
            break
        blocks = list(read_blocks(path, 1 << 20, seg_start, seg_end))
        if not blocks:
            break
        y = np.concatenate(blocks, axis=0).mean(axis=1).astype(np.float32)
        if len(y) <= lead:
            break
        mel = librosa.feature.melspectrogram(
            y=y, sr=sr, n_fft=n_fft, hop_length=hop, n_mels=n_mels, fmin=fmin, fmax=fmax
        )
        pcen = librosa.pcen(mel * (2**31), sr=sr, hop_length=hop)
        env = librosa.onset.onset_strength(  # type: ignore[attr-defined]
            S=pcen, sr=sr, hop_length=hop, lag=2, max_size=3
        ).astype(np.float32)
        skip = lead // hop
        envelope_parts.append(env[skip:])
        got = len(y) - lead
        position += got
        if progress_cb is not None and total:
            progress_cb(min((position - start_frame) / total, 1.0))
        if got < segment_frames:
            break

    if not envelope_parts:
        empty = np.zeros(0, dtype=np.float32)
        return {"onset_t": empty, "onset_strength": empty, "env_t": empty, "env": empty}

    envelope = np.concatenate(envelope_parts)
    check_cancel(cancel_event)
    env_times = (t0 + np.arange(len(envelope)) * hop / sr).astype(np.float32)
    picked = pick_peaks(envelope, env_times, params)
    return {**picked, "env_t": env_times, "env": envelope}
