"""Streamed STFT → multi-scale uint8 dB tile pyramid (BUILD_SPEC §6.2 step 4, §6.4, ADR 0003).

- 4096-point 7-term Blackman-Harris window (Albrecht 2001 minimum-sidelobe), hop 1024.
- Streaming via librosa.stream (center=False) for soundfile-readable files; a bespoke
  overlap streamer on top of indra.ingest.blocks for pyav-only formats. Both are proven
  bit-equivalent to a whole-file STFT in tests/test_stft.py.
- Mono downmix (channel mean) for the display pyramid.
- dB mapping: 0 dB reference = full-scale sine (window_sum/2); -100..0 dB → 0..255 uint8.
- LODs max-pool time by 2x (preserves transients) until a level fits one time chunk.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any, cast

import numpy as np
import soundfile as sf
import zarr
from numpy.typing import NDArray

from indra.ingest.blocks import read_blocks
from indra.jobs.cancellation import CancelEvent, check_cancel

N_FFT = 4096
HOP = 1024
BLOCK_FRAMES = 256  # STFT frames per streamed block
DB_MIN = -100.0
DB_MAX = 0.0
TIME_CHUNK = 1024
FREQ_CHUNK = 256

# Albrecht (2001) minimum-sidelobe 7-term Blackman-Harris coefficients.
_BH7 = np.array(
    [
        0.27105140069342,
        0.43329793923448,
        0.21812299954311,
        0.06592544638803,
        0.01081174209837,
        0.00077658482522,
        0.00001388721735,
    ]
)


def bh7_window(n: int = N_FFT) -> NDArray[np.float64]:
    """7-term Blackman-Harris window (periodic, for spectral analysis)."""
    from scipy.signal.windows import general_cosine

    return cast(NDArray[np.float64], general_cosine(n, _BH7, sym=False))


def _stft_frames(block: NDArray[np.float32], window: NDArray[np.float64]) -> NDArray[np.float32]:
    """Magnitude STFT (center=False) of a mono block → (frames, bins) float32."""
    import librosa

    spec = librosa.stft(block, n_fft=N_FFT, hop_length=HOP, window=window, center=False)
    return cast(NDArray[np.float32], np.abs(spec).T.astype(np.float32))


def stream_mono_overlapped(path: Path, sr: int) -> Iterator[NDArray[np.float32]]:
    """Overlapped mono blocks equivalent to librosa.stream for any decodable file.

    Yields blocks of BLOCK_FRAMES * HOP + (N_FFT - HOP) samples where possible;
    consecutive blocks overlap by N_FFT - HOP so per-block center=False STFTs
    concatenate exactly.
    """
    step = BLOCK_FRAMES * HOP
    overlap = N_FFT - HOP
    tail = np.zeros(0, dtype=np.float32)
    for block in read_blocks(path, block_frames=step):
        mono = block.mean(axis=1).astype(np.float32)
        merged = np.concatenate([tail, mono])
        if len(merged) >= N_FFT:
            yield merged
            tail = merged[-overlap:].copy() if overlap else np.zeros(0, dtype=np.float32)
        else:
            # Only possible on the final short chunk (step >> N_FFT mid-stream);
            # anything shorter than one analysis window is dropped, matching
            # librosa.stft(center=False) behavior.
            tail = merged


def _stream_blocks(path: Path, sr: int) -> Iterator[NDArray[np.float32]]:
    """librosa.stream when soundfile can read the file, bespoke streamer otherwise."""
    import librosa

    try:
        sf.info(str(path))
    except sf.LibsndfileError:
        yield from stream_mono_overlapped(path, sr)
        return
    for block in librosa.stream(
        str(path),
        block_length=BLOCK_FRAMES,
        frame_length=N_FFT,
        hop_length=HOP,
        mono=True,
        fill_value=None,
    ):
        block_f32 = np.asarray(block, dtype=np.float32)
        if len(block_f32) >= N_FFT:
            yield block_f32


def _to_uint8_db(mag: NDArray[np.float32], window_sum: float) -> NDArray[np.uint8]:
    """Linear magnitude → uint8 with -100..0 dB mapped to 0..255 (0 dB = full-scale sine)."""
    ref = window_sum / 2.0
    db = 20.0 * np.log10(np.maximum(mag, 1e-10) / ref)
    scaled = (np.clip(db, DB_MIN, DB_MAX) - DB_MIN) / (DB_MAX - DB_MIN) * 255.0
    return cast(NDArray[np.uint8], scaled.astype(np.uint8))


def _max_pool_time(data: NDArray[np.uint8]) -> NDArray[np.uint8]:
    """Max-pool pairs of time rows; odd tail row carries through."""
    n = data.shape[0]
    even = (n // 2) * 2
    pooled = np.maximum(data[0:even:2], data[1:even:2])
    if n % 2:
        pooled = np.concatenate([pooled, data[-1:]], axis=0)
    return pooled


def build_spec_pyramid(
    path: Path,
    out_path: Path,
    sr: int,
    cancel_event: CancelEvent,
    progress_cb: Callable[[float], None] | None = None,
    total_frames: int | None = None,
) -> dict[str, Any]:
    """Stream the file, write the uint8 dB multi-scale Zarr pyramid. Returns metadata."""
    from zarr.codecs import BloscCodec

    window = bh7_window()
    window_sum = float(window.sum())
    n_bins = N_FFT // 2 + 1

    out_path.parent.mkdir(parents=True, exist_ok=True)
    group = zarr.open_group(str(out_path), mode="w")
    compressors = [BloscCodec(cname="zstd", clevel=5, shuffle="bitshuffle")]
    level0 = group.create_array(
        name="0",
        shape=(0, n_bins),
        dtype="uint8",
        chunks=(TIME_CHUNK, FREQ_CHUNK),
        compressors=compressors,
    )

    done_samples = 0
    for block in _stream_blocks(path, sr):
        check_cancel(cancel_event)
        frames = _to_uint8_db(_stft_frames(block, window), window_sum)
        if frames.shape[0] == 0:
            continue
        level0.append(frames, axis=0)
        done_samples += len(block) - (N_FFT - HOP)
        if progress_cb is not None and total_frames:
            progress_cb(min(done_samples / total_frames, 1.0) * 0.8)

    n_frames = int(level0.shape[0])
    if n_frames == 0:
        raise ValueError(f"audio too short for a {N_FFT}-sample STFT window: {path}")

    # Higher LODs: 2x time max-pooling until a level fits one time chunk.
    levels = ["0"]
    current = level0
    lod = 0
    while current.shape[0] > TIME_CHUNK:
        check_cancel(cancel_event)
        lod += 1
        nxt = group.create_array(
            name=str(lod),
            shape=(0, n_bins),
            dtype="uint8",
            chunks=(TIME_CHUNK, FREQ_CHUNK),
            compressors=compressors,
        )
        # Stream in chunk-pairs to bound memory.
        step = TIME_CHUNK * 2
        for start in range(0, current.shape[0], step):
            chunk = np.asarray(current[start : start + step])
            nxt.append(_max_pool_time(chunk), axis=0)
        levels.append(str(lod))
        current = nxt
        if progress_cb is not None:
            progress_cb(0.8 + 0.2 * min(lod / 8, 1.0))

    meta: dict[str, Any] = {
        "sr": sr,
        "n_fft": N_FFT,
        "hop": HOP,
        "window": "blackmanharris7",
        "db_min": DB_MIN,
        "db_max": DB_MAX,
        "n_bins": n_bins,
        "levels": len(levels),
        "frames_level0": n_frames,
        "mono_downmix": True,
    }
    group.attrs.update(meta)
    if progress_cb is not None:
        progress_cb(1.0)
    return meta
