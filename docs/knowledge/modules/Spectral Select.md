---
title: Spectral Select
type: module
tags:
- backend
- selection
- search
permalink: indra/modules/spectral-select
---

Magic select + similar-segment search (`backend/src/indra/analyses/select.py`).
Multimodal "magic wand": flood-fill region grow on the dB pyramid; folder-wide
"find this sound everywhere" search; cluster-map embedding for results.

- [design] Runs on the PRECOMPUTED pyramid — no audio decode, file-length independent #perf
- [design] `adapt="local_median"` = contextual matching (level relative to each time-slice median) — survives whole-mix level ramps
- [design] Seed statistic is the 90th percentile of the seed neighborhood, not the median (a point seed on a thin line is mostly off-line cells)
- [design] Search profiles: 24 fixed-Hz log bands (40 Hz–16 kHz) + per-file baseline removal → seeds transfer across sample rates and noise floors #search
- [design] Seed exemplars (mean + spaced columns): evolving sounds match phase-by-phase instead of smearing into one average
- [gotcha] Distances are calibrated: steady self-match ≈0.1, evolving ≈0.3, default threshold 0.4 — tests in `test_select*.py` encode this; recalibrate them together

## Relations

- depends_on [[Ingest Pipeline]]
- constrained_by [[Engine Version Bumps]]
- decided_by [[Fixed-Hz Profile Bands]]
- documented_in [[Selection UX Design]]