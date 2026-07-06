# Indra

System for interactive audio information retrieval & local sound archive enrichment: an
interactive, human-in-the-loop audio curation tool for experimental musicians working with
massive electroacoustic recordings — noisescapes, field recordings, generative and drone works.
Indra lets you explore, highlight, analyze, and label long-form audio, and export structured
data (onsets, segment boundaries, per-region feature curves) that can drive external visual,
generative, or algorithmic systems.

> *A magnifying glass, a highlighter, and a notebook for hours of sound.*

## Shape

- **Backend** (`backend/`): Python analysis engine — FastAPI + SSE on `127.0.0.1`, cancellable
  job system, Zarr tile pyramids, Parquet feature store, SQLite project DB. Analyses include
  Music Perception Toolbox curves (roughness, spectral entropy, template harmonicity),
  SuperFlux onsets, and multi-scale Foote novelty.
- **Frontend** (`apple/`): native Swift app — SwiftUI shell hosting a Metal tile renderer, plus
  `IndraKit`, a pure-Swift, Linux-testable package (models, API client, undo, tile cache).
- Files of unbounded length by design: everything loads lazily, tiles, and evicts.

## Documentation

- `docs/BUILD_SPEC.md` — the authoritative build specification.
- `docs/plan/STATUS.md` — live build status, current phase, deviations. **Start here.**
- `docs/plan/ROADMAP.md` — phase/DoD tracker.
- `docs/adr/` — architecture decision records.
- `docs/api.md` — implemented wire contract.

## Status

Pre-alpha; Phase 0 (engine skeleton and ingest) in progress. See `docs/plan/STATUS.md`.
