"""In-process job orchestration (BUILD_SPEC §4.5, ADR 0004).

asyncio orchestrator + ProcessPoolExecutor(spawn) workers. Per-job Manager
Event (cancellation) and Manager Queue (progress), bridged into asyncio and
fanned out to SSE subscribers.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import multiprocessing
import queue as queue_mod
import time
import uuid
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass, field
from multiprocessing.managers import SyncManager
from typing import Any, Literal

from indra.jobs.cancellation import CancelEvent, JobCancelledError, ProgressQueue
from indra.jobs.workers import CACHEABLE_KINDS, run_worker, worker_init
from indra.storage.cache import CacheIndex, cache_key
from indra.storage.db import Database

JobState = Literal["queued", "running", "cancelled", "failed", "done"]

_TERMINAL: frozenset[str] = frozenset({"cancelled", "failed", "done"})

_ETA_ALPHA = 0.3  # EMA smoothing for progress rate


@dataclass
class JobEvent:
    event: Literal["progress", "log", "done", "failed", "cancelled"]
    data: dict[str, Any]


@dataclass
class JobHandle:
    id: str
    kind: str
    params: dict[str, Any]
    state: JobState = "queued"
    progress: float = 0.0
    message: str = ""
    eta_s: float | None = None
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    finished_at: float | None = None
    result_ref: dict[str, Any] | None = None
    error: dict[str, Any] | None = None
    cancel_event: CancelEvent | None = None
    progress_queue: ProgressQueue | None = None
    future: asyncio.Future[dict[str, Any]] | None = None
    subscribers: list[asyncio.Queue[JobEvent]] = field(default_factory=list)
    _rate_ema: float | None = None

    def snapshot(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "state": self.state,
            "progress": round(self.progress, 4),
            "message": self.message,
            "eta_s": round(self.eta_s, 1) if self.eta_s is not None else None,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "result_ref": self.result_ref,
            "error": self.error,
        }


class JobRegistry:
    """Owns the process pool, the Manager, and all live job handles."""

    def __init__(
        self,
        db: Database,
        cache: CacheIndex,
        max_workers: int,
    ) -> None:
        self._db = db
        self._cache = cache
        ctx = multiprocessing.get_context("spawn")
        self._manager: SyncManager = ctx.Manager()
        self._pool = ProcessPoolExecutor(
            max_workers=max_workers,
            mp_context=ctx,
            initializer=worker_init,
        )
        self.jobs: dict[str, JobHandle] = {}
        self._bridges: set[asyncio.Task[None]] = set()

    async def shutdown(self) -> None:
        for handle in self.jobs.values():
            if handle.state not in _TERMINAL and handle.cancel_event is not None:
                handle.cancel_event.set()
        for task in list(self._bridges):
            task.cancel()
        await asyncio.gather(*self._bridges, return_exceptions=True)
        self._pool.shutdown(wait=False, cancel_futures=True)
        self._manager.shutdown()

    # -- submission ---------------------------------------------------------

    def submit(self, kind: str, params: dict[str, Any], audio_id: str = "") -> JobHandle:
        """Submit a job; resume-from-cache returns a completed handle immediately."""
        handle = JobHandle(id=uuid.uuid4().hex[:12], kind=kind, params=params)

        if kind in CACHEABLE_KINDS:
            key = cache_key(audio_id, kind, params)
            entry = self._cache.get(key)
            if entry is not None:
                handle.state = "done"
                handle.progress = 1.0
                handle.message = "cached"
                handle.started_at = handle.finished_at = time.time()
                handle.result_ref = entry.result_ref
                self.jobs[handle.id] = handle
                self._persist(handle)
                return handle

        spec = {"params": params, "audio_id": audio_id}
        handle.cancel_event = self._manager.Event()
        handle.progress_queue = self._manager.Queue()
        loop = asyncio.get_running_loop()
        cf_future = self._pool.submit(
            run_worker, kind, spec, handle.cancel_event, handle.progress_queue
        )
        handle.future = asyncio.wrap_future(cf_future, loop=loop)
        self.jobs[handle.id] = handle
        bridge = loop.create_task(self._bridge(handle, audio_id))
        self._bridges.add(bridge)
        bridge.add_done_callback(self._bridges.discard)
        return handle

    def cancel(self, job_id: str) -> bool:
        handle = self.jobs.get(job_id)
        if handle is None or handle.state in _TERMINAL:
            return False
        if handle.cancel_event is not None:
            handle.cancel_event.set()
        return True

    # -- SSE fan-out ---------------------------------------------------------

    def subscribe(self, handle: JobHandle) -> asyncio.Queue[JobEvent]:
        q: asyncio.Queue[JobEvent] = asyncio.Queue(maxsize=256)
        # Late joiners immediately see current state.
        q.put_nowait(JobEvent(event=self._state_event_name(handle), data=handle.snapshot()))
        if handle.state not in _TERMINAL:
            handle.subscribers.append(q)
        return q

    def unsubscribe(self, handle: JobHandle, q: asyncio.Queue[JobEvent]) -> None:
        if q in handle.subscribers:
            handle.subscribers.remove(q)

    @staticmethod
    def _state_event_name(
        handle: JobHandle,
    ) -> Literal["progress", "done", "failed", "cancelled"]:
        if handle.state == "done":
            return "done"
        if handle.state == "failed":
            return "failed"
        if handle.state == "cancelled":
            return "cancelled"
        return "progress"

    @staticmethod
    def _publish(handle: JobHandle, event: JobEvent) -> None:
        for q in list(handle.subscribers):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                # Slow consumer: drop intermediate progress; terminal events retry below.
                if event.event != "progress":
                    _ = q.get_nowait()
                    q.put_nowait(event)

    # -- bridge --------------------------------------------------------------

    async def _bridge(self, handle: JobHandle, audio_id: str) -> None:
        """Drain the worker's progress queue into asyncio and finalize state."""
        handle.state = "running"
        handle.started_at = time.time()
        assert handle.future is not None
        assert handle.progress_queue is not None
        pq = handle.progress_queue

        def _poll() -> tuple[float, str, dict[str, Any] | None] | None:
            try:
                item = pq.get(True, 0.2)
                return item  # type: ignore[no-any-return]
            except queue_mod.Empty:
                return None

        while True:
            item = await asyncio.to_thread(_poll)
            if item is not None:
                frac, msg, extra = item
                handle.progress = min(max(float(frac), handle.progress), 1.0)
                handle.message = str(msg)
                self._update_eta(handle)
                data = handle.snapshot()
                if extra:
                    data["extra"] = extra
                self._publish(handle, JobEvent(event="progress", data=data))
                continue
            if handle.future.done():
                break

        try:
            result = await handle.future
            handle.state = "done"
            handle.progress = 1.0
            handle.result_ref = result
            if handle.kind in CACHEABLE_KINDS:
                self._cache.put(
                    cache_key(audio_id, handle.kind, handle.params),
                    audio_id=audio_id,
                    kind=handle.kind,
                    params=handle.params,
                    result_ref=result,
                )
        except JobCancelledError:
            handle.state = "cancelled"
        except asyncio.CancelledError:
            handle.state = "cancelled"
            raise
        except Exception as exc:
            handle.state = "failed"
            handle.error = {"code": "worker_error", "message": str(exc)}
        finally:
            handle.finished_at = time.time()
            handle.eta_s = None
            if handle.state in _TERMINAL:
                self._publish(
                    handle,
                    JobEvent(event=self._state_event_name(handle), data=handle.snapshot()),
                )
                handle.subscribers.clear()
                self._persist(handle)

    def _update_eta(self, handle: JobHandle) -> None:
        if handle.started_at is None or handle.progress <= 0.0:
            return
        elapsed = time.time() - handle.started_at
        if elapsed <= 0:
            return
        rate = handle.progress / elapsed
        ema = handle._rate_ema
        handle._rate_ema = rate if ema is None else _ETA_ALPHA * rate + (1 - _ETA_ALPHA) * ema
        if handle._rate_ema and handle._rate_ema > 0:
            handle.eta_s = (1.0 - handle.progress) / handle._rate_ema

    def _persist(self, handle: JobHandle) -> None:
        """Mirror a completed job to the jobs table for audit (best effort)."""
        with contextlib.suppress(Exception):
            self._db.execute(
                "INSERT OR REPLACE INTO jobs "
                "(id, kind, params_json, state, started_at, finished_at, result_json, error_json)"
                " VALUES (?,?,?,?,?,?,?,?)",
                (
                    handle.id,
                    handle.kind,
                    json.dumps(handle.params, sort_keys=True),
                    handle.state,
                    handle.started_at,
                    handle.finished_at,
                    json.dumps(handle.result_ref) if handle.result_ref else None,
                    json.dumps(handle.error) if handle.error else None,
                ),
            )
