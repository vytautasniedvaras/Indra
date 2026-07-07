---
title: Engine Version Bumps
type: invariant
tags:
- backend
- cache
permalink: indra/invariants/engine-version-bumps
---

`ENGINE_VERSION` (`backend/src/indra/__init__.py`) is part of every cache key. Any
change that alters what an analysis COMPUTES (not just how fast) must bump it —
otherwise stale cached results are served as if current.

- [constraint] Bumping invalidates ALL cached analyses project-wide; that's the intended cost
- [status] 0.2.0 = fixed-Hz profile bands in select (2026-07-07)

## Relations

- documented_in [[Architecture Guide]]