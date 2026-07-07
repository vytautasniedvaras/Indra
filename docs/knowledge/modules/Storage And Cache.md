---
title: Storage And Cache
type: module
tags:
- backend
- storage
permalink: indra/modules/storage-and-cache
---

Content-addressed analysis cache + project layout (`backend/src/indra/storage/`).

- [design] Key = `blake3(audio_hash|kind|canonical_params|ENGINE_VERSION)[:32]` — identical request → instant cached `done`
- [design] LRU eviction skips blobs of currently-imported files (`active_ids_provider`)
- [constraint] `project.sqlite` holds ONLY non-regenerable state (annotations, undo log, file registry); everything else must be recomputable
- [gotcha] SQLite `datetime('now')` is 1-second granular — LRU tests sleep 1.1 s between puts

## Relations

- constrained_by [[Cache Key Consistency]]
- constrained_by [[Engine Version Bumps]]
- documented_in [[Architecture Guide]]