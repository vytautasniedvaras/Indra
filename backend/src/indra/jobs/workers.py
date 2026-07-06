"""Worker-side job dispatch.

Runs inside spawn-context pool processes: everything here must be importable
at module top level. The registry maps job kind -> worker function with
signature (spec, cancel_event, progress_queue) -> result_ref dict.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

from indra.jobs.cancellation import (
    CancelEvent,
    ProgressQueue,
    check_cancel,
    report,
)

WorkerFn = Callable[[dict[str, Any], CancelEvent, ProgressQueue], dict[str, Any]]


def debug_slow(
    spec: dict[str, Any], cancel_event: CancelEvent, progress_queue: ProgressQueue
) -> dict[str, Any]:
    """Deterministic slow job for tests and manual SSE probing.

    params: steps (int), step_s (float), fail_at (optional int step index).
    """
    params = spec["params"]
    steps = int(params.get("steps", 20))
    step_s = float(params.get("step_s", 0.1))
    fail_at = params.get("fail_at")
    for i in range(steps):
        check_cancel(cancel_event)
        if fail_at is not None and i == int(fail_at):
            raise RuntimeError(f"debug_slow: injected failure at step {i}")
        time.sleep(step_s)
        report(progress_queue, (i + 1) / steps, f"step {i + 1}/{steps}")
    return {"kind": "debug_slow", "steps": steps}


def _import_audio(
    spec: dict[str, Any], cancel_event: CancelEvent, progress_queue: ProgressQueue
) -> dict[str, Any]:
    from indra.ingest.pipeline import run_import

    return run_import(spec, cancel_event, progress_queue)


def _run_analysis(
    spec: dict[str, Any], cancel_event: CancelEvent, progress_queue: ProgressQueue
) -> dict[str, Any]:
    from indra.analyses.runner import run_analysis

    return run_analysis(spec, cancel_event, progress_queue)


from indra.analyses.runner import ANALYSIS_KINDS  # noqa: E402

WORKERS: dict[str, WorkerFn] = {
    "debug_slow": debug_slow,
    "import": _import_audio,
    **{kind: _run_analysis for kind in ANALYSIS_KINDS},
}

# Kinds whose results are memoized in the content-addressed cache (§4.6).
CACHEABLE_KINDS: frozenset[str] = frozenset({"debug_slow"}) | ANALYSIS_KINDS


def run_worker(
    kind: str,
    spec: dict[str, Any],
    cancel_event: CancelEvent,
    progress_queue: ProgressQueue,
) -> dict[str, Any]:
    """Pool entrypoint: dispatch to the registered worker for `kind`."""
    fn = WORKERS.get(kind)
    if fn is None:
        raise ValueError(f"unknown job kind: {kind}")
    return fn(spec, cancel_event, progress_queue)


def worker_init() -> None:
    """Pool initializer: pre-import heavy modules to amortize spawn cost."""
    import numpy  # noqa: F401
    import soundfile  # noqa: F401
    import zarr  # noqa: F401
