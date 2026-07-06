"""Waveform min/max peak pyramid (BUILD_SPEC §6.2 step 3, ADR 0003).

int16 pyramid, 8 levels, base bucket 256 samples. Level k covers
256 * 2**k samples per bucket. Stored as a Zarr v3 group with arrays "0".."7"
of shape (n_buckets, channels, 2) where the last axis is (min, max).
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import cast

import numpy as np
import zarr
from numpy.typing import NDArray

from indra.ingest.blocks import read_blocks
from indra.jobs.cancellation import CancelEvent, check_cancel

LEVELS = 8
BASE_BUCKET = 256

Int16Array = NDArray[np.int16]


def _minmax_level0(block: NDArray[np.float32]) -> Int16Array:
    """Reduce a (frames, ch) float block to (buckets, ch, 2) int16 min/max."""
    frames, channels = block.shape
    n_buckets = (frames + BASE_BUCKET - 1) // BASE_BUCKET
    pad = n_buckets * BASE_BUCKET - frames
    if pad:
        block = np.concatenate([block, np.repeat(block[-1:], pad, axis=0)], axis=0)
    shaped = block.reshape(n_buckets, BASE_BUCKET, channels)
    scaled_min = np.clip(shaped.min(axis=1), -1.0, 1.0) * 32767.0
    scaled_max = np.clip(shaped.max(axis=1), -1.0, 1.0) * 32767.0
    return cast(Int16Array, np.stack([scaled_min, scaled_max], axis=-1).astype(np.int16))


def _downsample(level: Int16Array) -> Int16Array:
    """Pairwise min/max reduce along the bucket axis."""
    n = level.shape[0]
    if n % 2:
        level = np.concatenate([level, level[-1:]], axis=0)
        n += 1
    pairs = level.reshape(n // 2, 2, *level.shape[1:])
    out = np.empty((n // 2, *level.shape[1:]), dtype=np.int16)
    out[..., 0] = pairs[..., 0].min(axis=1)
    out[..., 1] = pairs[..., 1].max(axis=1)
    return out


def build_waveform_pyramid(
    path: Path,
    out_path: Path,
    sr: int,
    cancel_event: CancelEvent,
    progress_cb: Callable[[float], None] | None = None,
    total_frames: int | None = None,
) -> dict[str, int]:
    """Stream the file, build the 8-level pyramid, write Zarr. Returns level sizes."""
    # Block size: whole multiple of BASE_BUCKET, ~1 s of audio.
    block_frames = max(1, sr // BASE_BUCKET) * BASE_BUCKET
    chunks: list[Int16Array] = []
    done_frames = 0
    for block in read_blocks(path, block_frames=block_frames):
        check_cancel(cancel_event)
        chunks.append(_minmax_level0(block))
        done_frames += block.shape[0]
        if progress_cb is not None and total_frames:
            progress_cb(min(done_frames / total_frames, 1.0))
    if not chunks:
        raise ValueError(f"no audio decoded from {path}")

    levels: list[Int16Array] = [np.concatenate(chunks, axis=0)]
    for _ in range(1, LEVELS):
        levels.append(_downsample(levels[-1]))
        check_cancel(cancel_event)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    group = zarr.open_group(str(out_path), mode="w")
    group.attrs.update(
        {
            "sr": sr,
            "base_bucket": BASE_BUCKET,
            "levels": LEVELS,
            "dtype": "int16",
            "layout": "(bucket, channel, minmax)",
        }
    )
    sizes: dict[str, int] = {}
    for lod, data in enumerate(levels):
        arr = group.create_array(
            name=str(lod),
            shape=data.shape,
            dtype="int16",
            chunks=(min(65536, data.shape[0]), data.shape[1], 2),
        )
        arr[:] = data
        sizes[str(lod)] = int(data.shape[0])
    return sizes
