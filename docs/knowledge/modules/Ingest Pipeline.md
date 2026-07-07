---
title: Ingest Pipeline
type: module
tags:
- backend
- ingest
permalink: indra/modules/ingest-pipeline
---

Import → probe → blake3 content hash → waveform peak pyramid → STFT dB pyramid
(`backend/src/indra/ingest/`). Produces the Zarr pyramids every later feature reads.

- [design] Streaming-only: `read_blocks`/`read_range` with frame bounds; whole-file loads are forbidden at any file length #memory
- [design] Spectrogram pyramid: uint8 dB (0..255 ⇔ −100..0 dBFS), BH7 window 4096/1024, max-pool LODs, Blosc+Zstd #spectrogram
- [constraint] STFT center=False; streamed-vs-full bit-equivalence is proven by a golden test — don't change framing casually
- [perf] 1-hour file: import 46 s, RSS 221 MB (measured 2026-07-06)

## Relations

- constrained_by [[Streaming Only IO]]
- constrained_by [[dB Pyramid Contract]]
- documented_in [[Architecture Guide]]