---
title: Cancellation Checks
type: invariant
tags:
- backend
- jobs
permalink: indra/invariants/cancellation-checks
---

Every worker loop calls `check_cancel(cancel_event)` at bounded intervals (per block /
per segment / every 100k BFS steps). The 2 s cancel budget is a spec DoD item and is
test-enforced.

- [constraint] New analysis kinds must thread `cancel_event` through every loop that can run >0.5 s
- [gotcha] `check_cancel` raises `JobCancelled` — never catch it broadly in worker code

## Relations

- documented_in [[Architecture Guide]]