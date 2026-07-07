---
title: Fixed-Hz Profile Bands
type: decision
tags:
- backend
- search
permalink: indra/decisions/fixed-hz-profile-bands
---

Similar-search profiles pool the spectrogram into 24 log bands over FIXED Hz edges
(40 Hz–16 kHz), not bin indices — so profiles from files with different sample rates
live in the same space and folder-wide seeds transfer. Bands above a file's Nyquist
read as zero deviation after per-file baseline removal.

- [design] Seed exemplars (mean + spaced columns) let evolving sounds match phase-by-phase
- [gotcha] This change required [[Engine Version Bumps]] to 0.2.0

## Relations

- implements [[Spectral Select]]
- documented_in [[Selection UX Design]]