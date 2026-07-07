---
title: Onset Detection
type: module
tags:
- backend
- analysis
permalink: indra/modules/onset-detection
---

SuperFlux-on-PCEN onsets (`backend/src/indra/analyses/onsets.py`) with a split seam:
expensive envelope (segmented, PCEN warm-up lead-in) vs cheap `pick_peaks`.

- [design] `pick_peaks(envelope, times, params)` is the re-runnable half: `/onsets/repick` re-thresholds the SAVED envelope in milliseconds — live-slider cheap #ux
- [design] With no overrides the re-pick reproduces the original detection exactly (`PICK_DEFAULTS` mirror librosa's frame defaults; equivalence is test-locked)
- [design] Committed onsets are point annotations (label "onset"), batch-created as ONE undo step
- [gotcha] PCEN's IIR smoother needs warm-up — segments carry discarded lead-in; don't "optimize" it away

## Relations

- depends_on [[Job System]]
- depends_on [[History Undo]]
- documented_in [[Selection UX Design]]