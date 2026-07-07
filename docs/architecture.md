# Indra — implementation architecture and maintenance notes

The design authority is `docs/BUILD_SPEC.md`; ADRs record decisions; `docs/plan/STATUS.md` is
the live state. **This document covers what none of those do: how the implementation actually
works, its invariants, and the traps a maintainer must not fall into.** Written for a future
contributor (human or model) who was not present during the build.

## System shape

Two processes on one machine. The Python engine (`backend/src/indra/`) owns all data and
computation; the Swift app (`apple/`) is a renderer/controller that holds no authoritative
state except the in-flight editor session. They speak HTTP+SSE on 127.0.0.1 with a bearer
token from the `session.json` handshake file. The wire contract is `docs/api.md` — keep it in
lockstep with `IndraKitCore/Models.swift` + `History.swift` (snake_case JSON ⇄ camelCase Swift
via `IndraJSON`'s convertFromSnakeCase; adding a wire field means touching both sides plus a
Codable fixture test).

## Backend invariants (violating any of these is a bug)

1. **Never load whole files.** Every audio read goes through `ingest/blocks.py::read_blocks`
   (seek-based for soundfile formats, decode-skip for pyav) or a streamer built on it. If you
   write `sf.read(path)` or `librosa.load(path)` without bounds, you have broken §4.4.
2. **Every loop > 100 ms checks `cancel_event`** via `check_cancel` (§4.5). The cancellation
   test budget is 2 s; the practical granularity used everywhere is one streamed block
   (≤ 256 STFT frames or ≤ 60 s audio segments).
3. **Workers are spawn-context pool processes.** Anything a worker touches must be importable
   at module top level (`jobs/workers.py` dispatches by kind). Workers open their OWN SQLite
   connection (WAL makes that safe); they never see the server's `Database` object. Cancel
   events and progress queues are **Manager proxies** (raw `mp.Event` cannot cross a
   `ProcessPoolExecutor`).
4. **Cache keys** (§4.6): `blake3(audio_hash | kind | canonical_params_json | engine_version)`.
   The registry computes the key from the params dict AS SUBMITTED — so the runner must
   reconstruct the identical dict (`AnalysisContext.full_params()` in `runner.py`) when it
   derives blob filenames. If you change what routes put into `params`, keys change (= cache
   invalidation, acceptable) but runner/registry must stay consistent (= correctness).
   **Bump `ENGINE_VERSION` in `indra/__init__.py` whenever an analysis changes semantics.**
5. **STFT framing**: `center=False` everywhere; streamed framing is proven bit-identical to
   whole-file framing (tests/test_stft.py — the golden test). Frame k of a region starting at
   sample s covers samples `[s + k*hop, s + k*hop + n_fft)`. If you touch framing, run those
   tests first, not last.
6. **The dB mapping is a contract**: uint8 0..255 ⇔ −100..0 dB, 0 dB = full-scale sine
   (reference = window_sum/2). The Swift renderer and api_probe both assume it.
7. **undo_log patch identity**: annotation ids are AUTOINCREMENT because RFC-6902 patches
   reference ids; rowid reuse would redirect old patches to new rows (schema v2 migration
   exists for v1 databases). All annotation mutations MUST go through `HistoryManager` —
   writing to the annotations table directly desynchronizes the undo document.
8. **project.sqlite is the only non-regenerable file.** Everything in `arrays/` and `blobs/`
   must be reproducible from `audio/` + the DB. If you add a new artifact type, decide which
   side of that line it is on and wire eviction accordingly (`CacheIndex.evict_to_limit` never
   evicts `blob_kind == 'zarr'` rows whose audio_id is in the active project).

## Analysis-engine specifics that are easy to get wrong

- **MPT integration** (`analyses/mpt_frames.py`): the framewise pattern is
  rfft → `find_peaks(prominence ≥ 5% of frame max)` → MPT scalar per frame. The 5% floor is
  load-bearing: the Hann window's first sidelobe is −31.5 dB ≈ 2.7%, so a lower threshold
  hallucinates leakage peaks around every strong partial. `spectral_entropy` runs
  `normalize=False` (raw bits) because MPT's normalization divides by the entropy of the
  span-dependent grid and is non-monotonic across frames. `template_harmonicity` returns a
  TUPLE (h_max, h_entropy). Roughness input stays in Hz; entropy/harmonicity convert to cents.
  `resolution=3` (cents/grid-point) and kind-specific top_k/hop defaults are the §6.4 perf
  levers — measured numbers in STATUS.md Phase 2.
- **Onsets** (`analyses/onsets.py`): PCEN is an IIR — segments carry a 2 s warm-up lead that
  is computed and discarded; segment boundaries are hop-aligned so envelopes concatenate
  exactly. PCEN normalizes loudness, so a transient buried in loud noise is *correctly* less
  salient — don't "fix" that.
- **Novelty** (`analyses/novelty.py`): the SSM is capped at 4096 frames by mean-decimating
  features; the checkerboard kernel uses `sign(axis)` (zero center row/col) so it sums to
  exactly 0; the first/last `half` frames are zeroed (padding artifacts). Novelty at scales
  longer than the region is meaningless — the kernel is clamped, not extrapolated.
- **Audition** (`analyses/audition.py`): rectangle mask only, ≤ 600 s selections (in-memory
  render); raised-cosine band edges + time fades. WAVs are cache blobs (`blob_kind='wav'`)
  so LRU eviction cleans them up.

## Job system data flow (the part people misread)

`routes.py` → `JobRegistry.submit` (cache check happens HERE, before any process work) →
`pool.submit(run_worker, kind, spec, event_proxy, queue_proxy)` → `_bridge` task per job:
polls the Manager queue via `asyncio.to_thread(get, timeout=0.2)`, updates the handle,
publishes to per-subscriber `asyncio.Queue`s (SSE endpoint drains one). Terminal states are
decided by the bridge from the future's outcome (`JobCancelledError` → cancelled). Completed
jobs are mirrored to the `jobs` table best-effort. Running jobs die with the server by design.
Coverage note: worker-side code runs in subprocesses which coverage cannot see — that is why
`tests/test_analyses_direct.py` calls the worker functions in-process; keep doing that for
new kinds.

## Swift architecture

- **IndraKitCore** is pure and Linux-tested: models, `EditorState` + pure `reduce()`,
  `UndoStack` (value type, drag coalescing), `DocumentStore` (routes local-only vs
  backend-synced actions; fire-and-forget sync tasks logged to `syncErrors`), `TileCache`
  (byte-bounded LRU actor), and the render math (`Viewport`, `TilePlanner`, `Colormaps`,
  `CurveLane`, atlas/render-plan types). **Anything with a formula belongs here, with tests**
  — the app layer cannot be CI-verified, so it must stay thin.
- **IndraKitNet**: `HTTPTransport` protocol (tests inject `MockTransport` — do NOT reach for
  URLProtocol), delegate-based SSE streaming (identical on Linux/Darwin), byte-level SSE
  parser (Swift String treats CRLF as ONE Character — never scan Characters for newlines).
  `jobEvents` streams cancel the backend job on consumer termination, but only if no terminal
  event was seen.
- **IndraApp** is a SwiftPM executable (ADR 0012), all sources `#if os(macOS) &&
  canImport(SwiftUI)`-gated with a stub main for the Linux CI structural build. It is
  user-smoke-tested only; every file says so in its header. Keep exactly ONE `@main` per
  build configuration.
- Swift 6 strict concurrency gotchas already hit: `NSLock.lock()` is banned in async contexts
  (use the `Locked`/`withLock` helpers); `@retroactive` conformances are rejected inside the
  same package (conform at declaration).

## Verification stack (run before any push)

Backend: `ruff check src tests && ruff format --check src tests && mypy src/indra &&
pytest -q --cov=indra --cov-fail-under=80` (in `backend/`, venv `.venv`). Swift: CI is the
compiler — this environment has no Swift toolchain (registry CDNs and swift.org are blocked
by network policy), so push and read the `indrakit` job log; keep Swift changes small enough
that a compile error is attributable. License gate: `scripts/check_licenses.py` fails CI on
non-permissive licenses; exceptions live in that file + `docs/licenses.md`.

## Where the next work goes

- Metal renderer internals: pure math in IndraKitCore (tested), Metal/AppKit in IndraApp.
- New analysis kind: `analyses/<kind>.py` (+ direct in-process tests) → write a handler
  taking `AnalysisContext`, register it in `runner.py` `_HANDLERS` (ANALYSIS_KINDS derives
  from the table) → it is automatically a cacheable job kind and appears in `/analyze`;
  add golden tests and api.md rows. Cached features load via
  `storage/features.py::load_latest_feature` — don't hand-write the SQL again.
- New wire endpoint: routes.py + schemas.py + docs/api.md + IndraKit Models/APIClient +
  Codable fixture test + MockTransport test — all six or it isn't done.
- Phase 5 (cloud) is opt-in and unstarted; sqlite-vec joins pyproject then.
