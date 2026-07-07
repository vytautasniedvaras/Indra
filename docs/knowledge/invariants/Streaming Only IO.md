---
title: Streaming Only IO
type: invariant
tags:
- backend
- memory
permalink: indra/invariants/streaming-only-io
---

Never load a whole audio file into memory. All audio access goes through
`ingest/blocks.py` (`read_blocks` / `read_range`) with explicit frame bounds; analyses
over long spans process overlapped segments. This is what keeps a 1-hour file at
~220 MB RSS.

- [constraint] New analysis code must take (path, bounds) and stream — never `sf.read(path)` bare
- [gotcha] The 600 s audition cap exists because ISTFT rendering IS an in-memory operation — bounded by design, not streamed

## Relations

- documented_in [[Architecture Guide]]