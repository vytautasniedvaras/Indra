---
title: Vendored MPT
type: decision
tags:
- backend
- deps
permalink: indra/decisions/vendored-mpt
---

MPT (psychoacoustics library) is vendored at a pinned SHA under
`backend/src/indra/_vendor/mpt/` instead of pip-installed (ADR 0011): the upstream
`#subdirectory=python` install is broken at the pin AND at HEAD.

- [design] Framewise use only: rfft → `find_peaks(prominence ≥5% of frame max)` → MPT scalars; never `mpt.audio_peaks`, never `add_spectra` on empirical peaks
- [gotcha] Hann sidelobes are 2.7% — that's why prominence is 5%, not 1% (phantom peaks)
- [gotcha] Entropy uses `normalize=False` (raw bits): normalized entropy was span-dependent and non-monotonic

## Relations

- documented_in [[Architecture Guide]]