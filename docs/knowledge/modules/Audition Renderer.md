---
title: Audition Renderer
type: module
tags:
- backend
- audio
permalink: indra/modules/audition-renderer
---

"Hear the selection in isolation" (`backend/src/indra/analyses/audition.py`).
Three modes: rectangle mask, magic-selection ribbons (gaussian-feathered), and
segment sequences with equal-power crossfades.

- [design] STFT → soft mask → ISTFT to a scratch WAV; params-hash cached, replay is instant
- [design] Feather sigma derives from `fade_hz`/`fade_ms` — what the overlay shows should equal what the ear gets
- [constraint] 600 s render cap (`MAX_AUDITION_S`) bounds memory
- [gotcha] Crossfade math is click-tested (`test_segments_crossfade_no_clicks`): joint discontinuity < 3× the tone's own slope

## Relations

- depends_on [[Spectral Select]]
- constrained_by [[Streaming Only IO]]
- documented_in [[Selection UX Design]]