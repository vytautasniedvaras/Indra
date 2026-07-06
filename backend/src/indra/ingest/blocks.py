"""Streamed block reading of audio files — never load the whole file (§4.4).

Yields float32 arrays of shape (frames, channels). soundfile handles wav/flac/
ogg/aiff; pyav covers m4a/aac/mp3. Block sizes are frame counts at native sr.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import numpy as np
import soundfile as sf
from numpy.typing import NDArray

FloatBlock = NDArray[np.float32]


def read_blocks(
    path: Path,
    block_frames: int,
    start_frame: int = 0,
    end_frame: int | None = None,
) -> Iterator[FloatBlock]:
    """Yield float32 (frames, ch) blocks for [start_frame, end_frame) at native sr."""
    try:
        sf.info(str(path))
    except sf.LibsndfileError:
        yield from _read_blocks_av(path, block_frames, start_frame, end_frame)
        return
    yield from _read_blocks_sf(path, block_frames, start_frame, end_frame)


def _read_blocks_sf(
    path: Path, block_frames: int, start_frame: int, end_frame: int | None
) -> Iterator[FloatBlock]:
    with sf.SoundFile(str(path)) as handle:
        if start_frame:
            handle.seek(start_frame)
        remaining = None if end_frame is None else max(0, end_frame - start_frame)
        while remaining is None or remaining > 0:
            want = block_frames if remaining is None else min(block_frames, remaining)
            block = handle.read(frames=want, dtype="float32", always_2d=True)
            if block.shape[0] == 0:
                break
            if remaining is not None:
                remaining -= block.shape[0]
            yield block


def _read_blocks_av(
    path: Path, block_frames: int, start_frame: int = 0, end_frame: int | None = None
) -> Iterator[FloatBlock]:
    # Codec formats: decode from the start and skip (frame-accurate container
    # seeking in compressed audio is unreliable); fine for the drill-down sizes
    # this path serves.
    import av

    buffer: list[FloatBlock] = []
    buffered = 0
    skipped = 0
    budget = None if end_frame is None else max(0, end_frame - start_frame)
    with av.open(str(path)) as container:
        stream = next(s for s in container.streams if s.type == "audio")
        for frame in container.decode(stream):
            if budget is not None and budget <= 0:
                break
            data = frame.to_ndarray()  # planar: (channels, samples); packed: (1, s*ch)
            if data.dtype != np.float32:
                if np.issubdtype(data.dtype, np.integer):
                    scale = float(np.iinfo(data.dtype).max)
                    data = data.astype(np.float32) / scale
                else:
                    data = data.astype(np.float32)
            layout_channels = len(frame.layout.channels)
            if data.shape[0] == layout_channels:
                block = np.ascontiguousarray(data.T)
            else:  # packed interleaved in a single row
                block = data.reshape(-1, layout_channels)
            if skipped < start_frame:
                take = min(block.shape[0], start_frame - skipped)
                skipped += take
                block = block[take:]
                if block.shape[0] == 0:
                    continue
            if budget is not None:
                block = block[:budget]
                budget -= block.shape[0]
            buffer.append(block)
            buffered += block.shape[0]
            if buffered >= block_frames:
                merged = np.concatenate(buffer, axis=0)
                while merged.shape[0] >= block_frames:
                    yield merged[:block_frames]
                    merged = merged[block_frames:]
                buffer = [merged] if merged.shape[0] else []
                buffered = merged.shape[0]
    if buffered:
        yield np.concatenate(buffer, axis=0)


def read_range(path: Path, start_frame: int, end_frame: int) -> FloatBlock:
    """Read a bounded region into memory (drill-down use; caller bounds the size)."""
    blocks = list(read_blocks(path, 1 << 20, start_frame, end_frame))
    if not blocks:
        return np.zeros((0, 1), dtype=np.float32)
    merged = np.concatenate(blocks, axis=0)
    return merged[: end_frame - start_frame]
