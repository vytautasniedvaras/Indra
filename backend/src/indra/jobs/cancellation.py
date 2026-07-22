"""Cooperative cancellation primitives (BUILD_SPEC §4.5, ADR 0004).

Every engine loop that can run longer than ~100 ms must call check_cancel
between chunks. Workers receive Manager proxies (picklable across the
spawn-context ProcessPoolExecutor), so the types here are structural.
"""

from __future__ import annotations

import contextlib
from typing import Any, Protocol


class JobCancelledError(Exception):
    """Raised inside a worker when its cancel event is set."""


class CancelEvent(Protocol):
    def is_set(self) -> bool: ...
    def set(self) -> None: ...


class ProgressQueue(Protocol):
    def put_nowait(self, item: Any) -> None: ...
    def put(self, item: Any) -> None: ...
    def get(self, block: bool = ..., timeout: float | None = ...) -> Any: ...


def check_cancel(cancel_event: CancelEvent) -> None:
    if cancel_event.is_set():
        raise JobCancelledError


def report(
    progress_queue: ProgressQueue,
    frac: float,
    message: str = "",
    extra: dict[str, Any] | None = None,
) -> None:
    """Non-blocking progress report from a worker."""
    # A full or broken queue must never kill the job.
    with contextlib.suppress(Exception):
        progress_queue.put_nowait((frac, message, extra))
