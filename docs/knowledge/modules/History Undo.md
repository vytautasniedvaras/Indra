---
title: History Undo
type: module
tags:
- backend
- undo
permalink: indra/modules/history-undo
---

Backend-authoritative undo (`backend/src/indra/history/manager.py`): every annotation
mutation writes RFC-6902 forward+inverse patches to `undo_log`.

- [design] Multi-op patches are supported — a batch (e.g. commit N onsets) is one undo step
- [constraint] `annotations.id` is AUTOINCREMENT specifically so rowids never get reused — reuse would corrupt patch identity (schema v2 migration exists for this)
- [design] Any new forward action deletes the redo branch (standard branching model)
- [gotcha] Analysis results never enter the log — they're derived data, regenerable from cache

## Relations

- constrained_by [[Undo Patch Identity]]
- documented_in [[Architecture Guide]]