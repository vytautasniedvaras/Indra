---
title: dB Pyramid Contract
type: invariant
tags:
- backend
- spectrogram
permalink: indra/invariants/d-b-pyramid-contract
---

Spectrogram pyramid cells are uint8: 0..255 ⇔ −100..0 dB, where 0 dB is a full-scale
sine (BH7 window 4096/1024). Everything downstream — tile serving, magic select
tolerances (dB × 2.55), Swift colormaps — assumes exactly this mapping.

- [constraint] Changing window/normalization requires bumping [[Engine Version Bumps]] AND recalibrating select tests
- [gotcha] LODs are max-pooled (peak-preserving), not averaged — a quiet blip stays visible zoomed out

## Relations

- documented_in [[Architecture Guide]]