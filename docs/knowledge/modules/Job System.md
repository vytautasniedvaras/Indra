---
title: Job System
type: module
tags:
- backend
- jobs
permalink: indra/modules/job-system
---

Cancellable, resumable analysis jobs (`backend/src/indra/jobs/`). Everything long-running
goes through it; endpoints return a `job_id`, progress streams over SSE.

- [design] Spawn-context ProcessPoolExecutor + Manager Event/Queue proxies bridged to asyncio; SSE fan-out per job #jobs
- [design] Registry computes the cache key from params AS SUBMITTED; the worker reconstructs `{**params, "_kind", "project_root"}` — the two must stay in lockstep #cache
- [gotcha] Coverage can't see subprocess code — worker logic gets in-process direct tests (`test_analyses_direct.py`)
- [perf] Cancel latency budget 2 s; observed well under

## Relations

- constrained_by [[Cache Key Consistency]]
- constrained_by [[Cancellation Checks]]
- documented_in [[Architecture Guide]]