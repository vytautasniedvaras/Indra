---
title: Undo Patch Identity
type: invariant
tags:
- backend
- undo
permalink: indra/invariants/undo-patch-identity
---

Undo patches address annotations by id (`/annotations/<id>`). Ids must therefore be
stable forever: the table uses AUTOINCREMENT so SQLite never reuses a rowid. Without
it, delete + insert could hand an old patch a new row.

- [constraint] Never switch the annotations PK away from AUTOINCREMENT; never bulk-rewrite ids
- [gotcha] This was a real bug (rowid reuse) fixed by the v1→v2 schema migration

## Relations

- documented_in [[Architecture Guide]]