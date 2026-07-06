# Indra — Roadmap and Definition-of-Done tracker

Mirror of `docs/BUILD_SPEC.md` §9, with live checkboxes. Detail lives in the spec; this file
tracks completion only.

## Phase 0 — Engine skeleton and ingest

- [x] Backend project scaffolding (`pyproject.toml`, `uv.lock`, ruff + mypy)
- [x] FastAPI app: `/health`, `/project`, `/files/import`, `/files`; lifespan-managed SQLite +
      ProcessPoolExecutor + JobRegistry
- [x] Bearer-token middleware
- [x] Cancellable job system (§4.5) with SSE progress endpoint, tested via httpx streaming
- [x] Ingest steps 1–3: probe, content hash, waveform peak pyramid
- [x] pytest coverage ≥ 70 % (81 %); job cancellation test green
- [x] **DoD**: `curl -N …/jobs/{id}/events` streams progress; POST cancel aborts within 2 s
      (verified live: 0.27 s)

## Phase 1 — Tile serving and IndraKit client

- [x] STFT tile pyramid (§6.4) via `librosa.stream`, multi-scale Zarr
- [x] Streaming vs full STFT equivalence test (§6.3) green — riskiest correctness assumption
      (bit-identical; also proven for the bespoke pyav-path streamer)
- [x] `/spec/tile` and `/waveform/tile` binary endpoints with `X-Indra-Tile-*` headers
- [x] `IndraKit` package: `IndraKitCore`, `IndraKitNet`, `IndraKitAppleGlue`
- [x] `APIClient` (URLSession + FoundationNetworking gate) covering every endpoint
- [x] SSE parser → `AsyncThrowingStream<SSEEvent, Error>` (byte-level, CRLF-safe)
- [x] `TileCache`, `EditorState`, reducer, undo stack — Linux-tested (swift-testing, 47 tests)
- [x] GitHub Actions CI green: `backend` + `indrakit`
- [x] **DoD**: `dev/api_probe.html` renders waveform + spectrogram tiles from a real ingested
      file (tile-serving path itself demo-verified end-to-end over HTTP); Swift tests pass
      in `swift:6.2-noble`

## Phase 2 — On-demand analyses and MPT

- [x] `indra.mpt_frames`: roughness / entropy / template-harmonicity curves — cancellable, streamed
- [x] SuperFlux-on-PCEN onset detection
- [x] Multi-scale Foote checkerboard novelty
- [x] Feature Parquet storage + min/max display downsampling
- [x] `/features/{kind}?t0=..&t1=..&downsample=..`
- [x] Region-scoped analysis (§6.5) — time and frequency-band
- [x] Golden-value tests for each MPT curve on synthetic inputs
- [x] **DoD**: all five analyses within perf targets (measured on 90 s at 44.1 kHz, extrapolated
      to 1 h at 4-worker equivalence); region drill-down verified via API test

## Phase 3 — Annotations, undo, export

- [x] Annotation CRUD API + SQLite schema (v2: AUTOINCREMENT ids)
- [x] `HistoryManager` with RFC-6902 patch log (§7)
- [x] `/undo`, `/redo`, `/history`
- [ ] Swift-side mirror: reducer + DocumentStore, selection-as-state (agent in flight)
- [x] Export endpoint (§6.6), JSON + CSV, schema documented in `docs/export_schema.md`
- [ ] **DoD**: full data path for the 1-hour noisescape — import, analyze, annotate, undo/redo,
      export JSON that drives an external visual pipeline

## Phase 4 — Native UI maturity (open-ended)

- [ ] Metal tile renderer (§5.3): colormap LUT, LOD, ProMotion pacing, triple buffer
- [ ] Gesture layer on subclassed MTKView
- [ ] Selection overlay, playhead, curve lanes in one Metal pass
- [ ] Toggleable lenses (raw dB / PCEN / roughness / harmonicity)
- [ ] AVAudioEngine playback, filtered audition, time-stretch
- [ ] Progress panel; Swift Charts inspector popovers
- [ ] Polish: window state, shortcuts, drag-and-drop import
- [ ] **DoD**: everything from Phase 3 with pointer-and-eyes UX at 60+ fps on M1 8 GB

## Phase 5 — Cloud tier (opt-in; not built without explicit user consent)

- [ ] GCP Cloud Batch workers; GCS artifacts; sqlite-vec similarity; clustering
