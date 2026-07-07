---
title: Cache Key Consistency
type: invariant
tags:
- backend
- cache
permalink: indra/invariants/cache-key-consistency
---

The job registry computes the cache key from params AS SUBMITTED (including `_kind`,
`project_root`); workers that need the key rebuild EXACTLY that dict. If the two drift,
resume-from-cache silently breaks (every request recomputes) or worse, collides.

- [constraint] When adding a worker that writes blobs, use `AnalysisContext.full_params()` in `runner.py` — the one place the reconstruction lives
- [gotcha] Params are canonicalized (sorted JSON) — adding a default in the schema changes the key for requests that previously omitted it

## Relations

- constrained_by [[Engine Version Bumps]]
- documented_in [[Architecture Guide]]