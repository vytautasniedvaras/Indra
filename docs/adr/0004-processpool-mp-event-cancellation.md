# 0004. In-process ProcessPoolExecutor + mp.Event cancellation
Date: 2026-07-06
Status: accepted
Context: Long-running analyses must be cancellable within 2 s and report progress, in a single-user local app. Broker-based queues (Celery/arq/taskiq/dramatiq/rq) add daemons and deployment weight with no benefit here.
Decision: asyncio orchestrator in the FastAPI process + ProcessPoolExecutor(mp_context=spawn) workers. Per-job multiprocessing.Event for cooperative cancellation (checked between chunks), multiprocessing.Queue for progress, bridged to asyncio and served over SSE. Job registry in memory; completed rows mirrored to SQLite for audit.
Consequences: Running jobs die with the server (accepted); every engine loop must check cancel_event (enforced via check_cancel helper); spawn context costs worker startup, amortized by a pool initializer that pre-imports heavy libs.
Alternatives considered: Celery et al. (rejected — dead weight), threads (GIL blocks CPU-bound analysis), asyncio-only (same GIL problem).
