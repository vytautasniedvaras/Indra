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


def read_blocks(path: Path, block_frames: int) -> Iterator[FloatBlock]:
    try:
        sf.info(str(path))
    except sf.LibsndfileError:
        yield from _read_blocks_av(path, block_frames)
        return
    yield from _read_blocks_sf(path, block_frames)


def _read_blocks_sf(path: Path, block_frames: int) -> Iterator[FloatBlock]:
    with sf.SoundFile(str(path)) as handle:
        while True:
            block = handle.read(frames=block_frames, dtype="float32", always_2d=True)
            if block.shape[0] == 0:
                break
            yield block


def _read_blocks_av(path: Path, block_frames: int) -> Iterator[FloatBlock]:
    import av

    buffer: list[FloatBlock] = []
    buffered = 0
    with av.open(str(path)) as container:
        stream = next(s for s in container.streams if s.type == "audio")
        for frame in container.decode(stream):
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
