"""Content hashing of decoded PCM (BUILD_SPEC §6.2 step 2, ADR 0006).

blake3 over float32 PCM streamed in ~1-second blocks. The hash identifies the
decoded audio content: stable across container copies, renames, and re-decodes
with the same decoder stack.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

import blake3

from indra.ingest.blocks import read_blocks
from indra.jobs.cancellation import CancelEvent, check_cancel


def content_hash(
    path: Path,
    sr: int,
    cancel_event: CancelEvent,
    progress_cb: Callable[[float], None] | None = None,
    total_frames: int | None = None,
) -> str:
    hasher = blake3.blake3()
    done_frames = 0
    for block in read_blocks(path, block_frames=sr):
        check_cancel(cancel_event)
        hasher.update(block.tobytes())
        done_frames += block.shape[0]
        if progress_cb is not None and total_frames:
            progress_cb(min(done_frames / total_frames, 1.0))
    return hasher.hexdigest()
