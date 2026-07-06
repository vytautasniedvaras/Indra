# Indra — Build Prompt for Claude Code (Claude Fable, High Reasoning, Headless Cloud)

You are Claude Code, running headlessly in a cloud Linux container against a GitHub repository. Your job is to build **Indra**, described below, to the specification in this document. This document is authoritative: decisions already made appear as directives, not options. Do not relitigate them. Where genuine engineering choice remains, use judgment and record decisions as ADRs (see §10). Ask the user only when a listed decision boundary is crossed.

Work in commits that are small, well-named, and reviewable. Prefer many small PR-shaped commits over a few large ones. Verify continuously with the test suites specified in §8. When you cannot verify something in the headless environment (Metal, SwiftUI, AVAudioEngine — see §3), state that explicitly in the commit message and produce a precise smoke-test recipe for the user to run locally.

-----

## 1. Project identity and mission

**Indra** is an interactive, human-in-the-loop audio curation tool for experimental musicians who work with massive electroacoustic recordings — noisescapes, field recordings, generative electronic pieces, drone works. It lets the user *explore, highlight, analyze, and label* long-form audio, and export structured data (timestamps, onsets, segment boundaries, per-region features) that can drive external visual, generative, or algorithmic systems.

**Primary user**: one experimental musician. **Primary hardware**: Apple Silicon Mac (M1, 8 GB baseline), later iPad.

**The first concrete guiding project**: a **1-hour experimental sound-art noisescape** where the user needs:

- Waveform + spectrogram exploration.
- Automatically detected onsets, textural boundaries, and structural segments.
- Per-region analysis curves (roughness, spectral entropy, template harmonicity, novelty).
- Ability to select interesting time-frequency regions and run *deeper localized analysis* on them.
- Ability to *audition* a selected time-frequency box in isolation (TIAALS-style).
- Human labeling and annotation, with **Blender-style undo/redo including selection state**.
- Structured export (JSON/CSV) driving external visual systems.

**File length is unbounded by design.** The 1-hour piece is only the first test case. The architecture must lazily load, tile, and hydrate arbitrarily long audio — hours, days if needed. Do not architect around “fits in RAM”. Architect around “load what is visible or needed, evict the rest.”

**Mission phrase to keep in mind while building**: *Give a musician a magnifying glass, a highlighter, and a notebook for hours of sound.*

-----

## 2. Primary references (READ BEFORE IMPLEMENTING)

Before writing any MPT-facing code, **read the Music Perception Toolbox User Guide end to end**:

- Repo: <https://github.com/andymilne/Music-Perception-Toolbox>
- User Guide: <https://github.com/andymilne/Music-Perception-Toolbox/blob/master/USER_GUIDE.md>

**Verified facts (as of April 2026):**

- **Current release**: v2.0.2 (commit `12a006c32f825c406ca2f41a5fcd5870a78c4a56`, 15 Apr 2026). Default branch is `master` (not `main`).
- **License**: MIT.
- **Python**: ≥ 3.10. Core deps NumPy + SciPy (auto-installed).  Optional `[audio]` extra pulls `soundfile` for `mpt.audio_peaks`. 
- **Not on PyPI.** Package lives in the `python/` subdirectory of the repo.  Install with the `#subdirectory=python` fragment; the naive `pip install git+...` will fail.
- **Canonical install (pin by SHA for reproducibility):**
  
  ```
  pip install "git+https://github.com/andymilne/Music-Perception-Toolbox.git@12a006c32f825c406ca2f41a5fcd5870a78c4a56#subdirectory=python"
  ```
  
  or, less strict, `@v2.0.2#subdirectory=python`. Add `[audio]` only if you use `mpt.audio_peaks` — Indra does **not** use `audio_peaks` (see below).
- **Import**: everything flat under `mpt.*`. 

**The four theoretical frameworks** (paraphrased from the guide — verify against the guide during implementation):

1. **Expectation tensors** (`mpt.build_exp_tens`, `mpt.eval_exp_tens`, `mpt.cos_sim_exp_tens*`, `mpt.entropy_exp_tens`, `mpt.batch_cos_sim_exp_tens`): Gaussian-mixture densities over r-tuples of weighted symbolic points (pitch or rhythm).  Four modes via `is_rel` and `is_per`.  Units matter — σ, `period`, and points must share units (cents by default).
1. **Roughness** (`mpt.roughness(f, w, ...)`): scalar Sethares/Plomp–Levelt roughness with configurable p-norm aggregation (Parncutt-style).  **Frequencies in Hz**,  linear amplitudes. Kwargs: `p_norm=1`, `average=False`. 
1. **Spectral entropy** (`mpt.spectral_entropy(p, w, sigma, ...)`): Shannon entropy of Gaussian-smoothed density  in the **absolute log-cents domain** (A4 = 6900). Grid-discretized (default 1200 pts/dim).  Lower = more consonant.
1. **Circular autocorrelation phase matrices** (`mpt.circ_apm(p, w, period, ...)`): symbolic-rhythm/scale meter analysis; returns `(R, rPhase, rLag)`.  Takes integer event positions in an integer-length cycle.

**Critical integration insight (VERIFIED — do not deviate):**

MPT is a **scalar/symbolic-domain library**. It does **not** perform framewise STFT peak extraction. To produce time-series curves (framewise roughness, entropy, harmonicity) from audio, **the host application does the framing itself** and calls MPT scalar functions once per frame:

```
audio  →  STFT frame  →  |X[k]|  →  scipy.signal.find_peaks (magnitude + prominence)
       →  (freqs_Hz, mags_linear)  →  MPT scalar function  →  one point in a curve
```

Do **not** use `mpt.audio_peaks` for this — it is a whole-file, single-pass extractor, not a framewise pipeline. Do **not** call `mpt.add_spectra` before feeding empirical audio peaks — the peaks already represent the full spectrum;  harmonic enrichment on top would double-count. When feeding `spectral_entropy` / `template_harmonicity`, convert Hz → absolute cents with `mpt.convert_pitch(f, 'hz', 'cents')`;  when feeding `roughness`, leave in Hz.

Amplitude convention: linear magnitude (not dB, not power). Weights default to uniform when `w=None` (Python) — MATLAB’s `[]` is `None`,  **not** `[]`. 

`coherence` and `sameness` in Python **always** return a tuple;  unpack.

Provide a single Python module `indra.mpt_frames` that wraps this pattern:

```python
def frame_peaks(mag_frame, freqs_hz, *, min_prominence, top_k=64) -> tuple[np.ndarray, np.ndarray]:
    # returns (f_hz, w_lin) sorted by amplitude desc, capped at top_k
def roughness_curve(y, sr, *, n_fft=4096, hop=1024, window='hann', **peak_kwargs) -> np.ndarray: ...
def entropy_curve(y, sr, *, sigma_cents=10.0, **kwargs) -> np.ndarray: ...
def template_harmonicity_curve(y, sr, *, sigma_cents=10.0, **kwargs) -> np.ndarray: ...
```

These MUST support chunked/streamed input (see §6 ingest pipeline) and MUST honor a cancellation event checked between frames (§4 cancellable jobs).

-----

## 3. Hard constraints

1. **Target hardware**: Apple Silicon **M1, 8 GB baseline**. Newer Macs and iPad are targets; do not regress the M1 8 GB experience. Budget the working set accordingly: keep resident spectrogram texture heap ≤ 512 MB, waveform peaks in memory ≤ 64 MB, backend RSS ≤ 1.5 GB steady state.
1. **Platforms**: **macOS first (macOS 14 minimum, 15/16 supported), iPadOS second (17+).** No Windows, no Linux GUI, no web UI as a product.
1. **Offline-first.** All MVP features run entirely locally. Cloud tier (embeddings-at-archive-scale, heavier separation) is **Phase 5**, opt-in, clearly bounded.
1. **Loading is allowed to take time, provided the user always sees an informative progress view and can cancel** any long-running operation. Cancellation is a first-class product surface, not a nice-to-have.
1. **Decoupled architecture** (already decided):
- **Backend**: Python analysis engine + local FastAPI server bound to `127.0.0.1`. Fully testable via pytest.
- **Frontend**: native Swift app with a SwiftUI shell hosting an MTKView Metal renderer. Built and run by the user locally in Xcode.
- The two talk over HTTP+SSE on loopback. This is authoritative.
1. **Headless cloud dev environment realities** — what Claude Code CAN and CANNOT verify:
   
   |Can verify headlessly                                                                                                                                             |Cannot verify headlessly (user smoke-tests locally)   |
   |------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------|
   |Python backend: pytest, API contract, cancellation, streaming STFT correctness, cache keys, DB migrations                                                         |SwiftUI views rendering                               |
   |Pure-Swift IndraKit package: `swift build` + `swift test` on Linux (Swift 6.2 Docker) — models, API client (URLSession), state store, undo stack, tile-cache logic|Metal renderer, MTKView, colormap LUT shader          |
   |JSON/Codable contracts on both sides                                                                                                                              |AVAudioEngine playback, filtered-selection audition   |
   |GitHub Actions CI runs green                                                                                                                                      |Trackpad/pinch/Pencil gestures, ProMotion frame pacing|
   |ADRs, docs, `Package.swift`, `pyproject.toml`, lockfiles                                                                                                          |Xcode project builds / archives                       |
   
   **Explicit contract**: on every meaningful change, Claude Code writes a “Local smoke test” note in the PR description with exact commands the user should run on their Mac (see §8).
1. **Minimal web UI is OPTIONAL and probably a waste of time.** Skip a browser-based product surface entirely. A tiny throwaway `dev/api_probe.html` — a static file that hits `/tiles` and renders a canvas — may be included **only** as a developer probe, in `dev/` with a big `THROWAWAY - not a product` banner at the top of the file. Do not invest in it. Do not maintain it as a first-class surface.

-----

## 4. Architecture

### 4.1 Two-process local topology

```
┌─────────────────────────────────────────────────────────────────┐
│  Indra.app (user's Mac, Xcode-built)                            │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ SwiftUI shell                                          │    │
│  │  ├─ Sidebar / inspector / transport (SwiftUI)          │    │
│  │  ├─ Canvas: MTKView (NSViewRepresentable)              │    │
│  │  │    · Metal tile renderer                            │    │
│  │  │    · Selection overlay, playhead, curve lanes       │    │
│  │  ├─ AVAudioEngine playback + filtered audition         │    │
│  │  └─ IndraKit (pure Swift, Linux-testable)              │    │
│  │      · Models · APIClient · Store · UndoStack · Cache  │    │
│  └───────────────────────────────┬────────────────────────┘    │
│                    HTTP + SSE on 127.0.0.1:PORT                 │
│  ┌───────────────────────────────┴────────────────────────┐    │
│  │ Indra backend (Python, spawned by app or user)         │    │
│  │  FastAPI + uvicorn + sse-starlette                     │    │
│  │  Job registry (ProcessPoolExecutor + mp.Event)         │    │
│  │  Analysis engine (librosa, MPT, numpy, torch/MPS)      │    │
│  │  Zarr v3 tile pyramids  ·  Parquet feature store       │    │
│  │  SQLite (WAL) project DB  ·  sqlite-vec (later)        │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

**Server lifecycle**: the backend can run standalone (`python -m indra.server --project foo.indra --port 0`) or be spawned by the app. On spawn, the backend picks a free port, writes it and a random bearer token to `~/Library/Application Support/Indra/session.json`, and the app reads that file. Bind is `127.0.0.1` **only**. Never `0.0.0.0`. A `Bearer` token is required on every request — defense in depth against local process snooping and DNS rebinding.

### 4.2 Project bundle format (`.indra`)

An Indra project is a directory bundle (macOS package):

```
MyPiece.indra/
├── project.sqlite              ← source of truth (WAL). Human-authored data lives here.
│   Tables: audio_files, labels, annotations, undo_log,
│           analysis_cache, jobs (audit).
├── audio/                       ← symlinks OR copies of source files (user choice at import)
│   └── noisescape_2026-05-11.wav
├── arrays/                      ← regenerable cache. Safe to delete.
│   ├── waveform/<audio_id>.zarr   (int16 min/max pyramid; §6.3)
│   ├── spec/<audio_id>.zarr       (uint8 dB multi-scale pyramid; §6.4)
│   ├── features/<audio_id>/…      (Parquet: roughness, entropy, novelty, ...)
│   └── embeddings/<audio_id>/…    (Zarr: 2D embedding × time)
├── blobs/<xx>/<key>.<ext>       ← content-addressed cache (see §4.6)
└── manifest.json                ← project format version, engine version, feature registry
```

`project.sqlite` is the only file that is not regenerable. If any file in `arrays/` or `blobs/` is missing, the engine must regenerate on demand.

### 4.3 API surface (sketch — refine as you go, record schema in `docs/api.md`)

REST + SSE. All bodies JSON. All error responses `{ "error": { "code": str, "message": str, "details": {...} } }`.

```
GET  /health
GET  /project                             → project metadata
POST /files/import                         { path, mode: "copy"|"reference" } → { audio_id, ... }
GET  /files                                → list
GET  /files/{audio_id}/manifest            → sr, channels, duration, LOD list, feature list

GET  /files/{audio_id}/waveform/tile
        ?lod=..&start=..&count=..           → application/octet-stream int16 min/max
GET  /files/{audio_id}/spec/tile
        ?lod=..&t0=..&t1=..&f0=..&f1=..     → application/octet-stream uint8 dB
                                              headers: X-Indra-Tile-Shape, X-Indra-Tile-Bounds

POST /analyze                               { audio_id, kind, params, region? } → { job_id }
GET  /jobs                                  → list
GET  /jobs/{job_id}                         → { state, progress, message, eta_s, result_ref? }
GET  /jobs/{job_id}/events                  (SSE stream: progress, log, done, failed)
POST /jobs/{job_id}/cancel                  → { cancelled: bool }

GET  /files/{audio_id}/features/{kind}
        ?t0=..&t1=..&downsample=..          → Parquet or JSON (min/max buckets or LTTB)

POST /annotations                           { audio_id, t0, t1, f0?, f1?, label, note } → { id, ... }
PATCH /annotations/{id}
DELETE /annotations/{id}
GET  /annotations?audio_id=…

POST /undo                                  → { applied: patch, undo_stack_depth }
POST /redo
GET  /history                               → recent action names for menu display

POST /audition                              { audio_id, mask_spec } → { audition_id, wav_path }
                                              (backend renders STFT→mask→ISTFT to a scratch WAV)

POST /export                                { audio_id, kinds: [...], format: "json"|"csv" }
                                            → streams file
```

The SSE endpoint yields events shaped `{ "event": "progress"|"log"|"done"|"failed", "data": {...} }`.

### 4.4 Dynamic loading principle

Only visible or requested regions are hydrated. Everything else stays on disk:

- **Waveform display**: request tiles at the current LOD covering the visible time range plus a small margin.
- **Spectrogram display**: same, but 2D in (time, freq). Tiles at LOD selected from zoom level.
- **Analysis curves**: server returns min/max buckets at the pixel resolution of the client’s viewport (or LTTB downsample if the client asks for smooth curves). Never send the full raw series if it doesn’t fit the request.
- **Playback**: `AVAudioFile` memory-maps; `scheduleSegment` reads only the needed frames.
- **File length is unbounded.** Every read path — decode, STFT, feature calc, tile serve — uses seek-based windowed I/O. Never `sf.read()` the whole file. Never `librosa.load()` without a duration. Never build in-memory arrays proportional to file length.

### 4.5 Cancellable job system (design MUST — do this early, everything depends on it)

Chosen architecture: **In-process asyncio orchestrator + `concurrent.futures.ProcessPoolExecutor(mp_context=spawn)` + per-job `multiprocessing.Event` + `multiprocessing.Queue` for progress.** Do **not** introduce Celery/arq/taskiq/dramatiq/rq — brokers are dead weight for a single-user local app.

- `JobHandle` dataclass: `id, kind, params, state ∈ {queued, running, cancelled, failed, done}, progress: float, message: str, eta_s: float | None, started_at, finished_at, result_ref, error, cancel_event, progress_queue, future`.
- Worker function signature: `def run(spec, cancel_event, progress_queue) -> ResultRef`. Workers check `cancel_event.is_set()` between chunks (STFT hops, model batches, tile writes) and raise `CancelledError` if set.
- Progress: worker calls `progress_queue.put_nowait((frac, msg, extra))`. An asyncio bridge task drains via `run_in_executor` and pushes to an `asyncio.Queue`. The SSE endpoint iterates that queue.
- ETA: exponential moving average of `frac / (now - started_at)`.
- **Resume-if-cached**: before enqueueing, compute the cache key (§4.6). Cache hit ⇒ return `done` immediately with `result_ref`.
- Job registry lives in memory (`app.state.jobs`); optionally mirror completed rows to `jobs` table for audit. Running jobs die with the server — acceptable.
- Worker pool: `ProcessPoolExecutor(max_workers=os.cpu_count() - 1, mp_context=multiprocessing.get_context("spawn"), initializer=_worker_init)`. `_worker_init` pre-imports librosa, numpy, torch (if used) to amortize import cost.
- **Cooperative cancellation is non-negotiable**: every long loop in the engine must check the event; every helper that runs > 100 ms must accept a `cancel_event` parameter. Enforce with a small `check_cancel(cancel_event)` helper that raises `CancelledError`.

On the Swift side, mirror this: every job started by IndraKit’s `APIClient` returns an `AsyncThrowingStream<JobEvent, Error>` whose `onTermination` calls `POST /jobs/{id}/cancel`. Consuming with `for try await` inside a SwiftUI `.task { }` cancels the job when the view disappears. 

### 4.6 Content-addressed analysis cache

```
cache_key = blake3(f"{audio_content_hash}|{kind}|{canonical_params_json}|{engine_version}")[:32]
```

- `audio_content_hash` = blake3 of the decoded PCM (native sr, native dtype). Computed once per import. Store on `audio_files.id`.
- `canonical_params_json` = `json.dumps(params, sort_keys=True, separators=(",", ":"))`.
- `engine_version` = a monotonic string like `"indra-engine 0.4.1"` bumped when any analysis algorithm changes semantics. Bump discipline is mandatory — if an algo changes, its cache invalidates.
- Storage: `blobs/<first-2-chars-of-key>/<key>.<ext>` (parquet/zarr/npy). Index row in `analysis_cache` SQLite table.
- Eviction: LRU by `last_used_at`, bounded by project setting (default 8 GB). Only evicts entries with `blob_kind != 'zarr' OR audio_id not in current_project`. Never evicts the primary spec pyramid of the active file.

### 4.7 Memory budgets (targets on M1 8 GB)

|Component                          |Steady-state target|Peak allowed|
|-----------------------------------|-------------------|------------|
|Backend RSS (idle)                 |200 MB             |—           |
|Backend RSS (analyzing)            |1.5 GB             |2.5 GB      |
|Metal texture heap (resident tiles)|256 MB             |512 MB      |
|Waveform peaks in Swift            |32 MB              |64 MB       |
|Analysis curves in Swift           |32 MB              |64 MB       |

If a job would exceed the peak, chunk more aggressively; do not attempt the operation whole.

-----

## 5. Native UI plan (Swift)

### 5.1 Package layout

Two source trees:

```
apple/
├── IndraKit/                    ← Swift Package. Linux-buildable. Claude Code verifies here.
│   ├── Package.swift            (swift-tools-version: 6.0)
│   └── Sources/
│       ├── IndraKitCore/        (models, state store, undo, tile-cache logic — pure Swift)
│       ├── IndraKitNet/         (URLSession API client + SSE parser — FoundationNetworking gated)
│       └── IndraKitAppleGlue/   (Apple-only bridges: SwiftUI.Color, AVAudioPCMBuffer, etc.)
│   Tests/
│       ├── IndraKitCoreTests/       (Swift Testing)
│       └── IndraKitNetTests/        (Swift Testing; mock server)
└── IndraApp/                    ← Xcode project. User builds locally.
    ├── IndraApp.xcodeproj
    └── Sources/                  (SwiftUI shell, MTKView renderer, AVAudioEngine, gestures)
```

The Xcode app depends on `IndraKit` via SwiftPM local package reference. `IndraKitCore` and `IndraKitNet` have zero `import SwiftUI` / `import AVFoundation` / `import Metal`. `IndraKitAppleGlue` is not compiled on Linux (excluded from the CI build step; Claude Code runs `swift build --target IndraKitCore --target IndraKitNet`). 

Enable Swift 6 language mode (`.swiftLanguageMode(.v6)`) in all targets. Use `swift-testing` (`import Testing`), not XCTest.  Pin CI Docker image to `swift:6.2-noble`.

### 5.2 Shell strategy

- **SwiftUI shell**: `App`, windows, toolbar, inspector, sidebar, transport, job list, settings.
- **NSViewRepresentable-hosted MTKView** for the main canvas. Subclass `MTKView` (`IndraCanvasView`) to own gesture handling directly via `NSResponder` overrides (`scrollWheel(with:)`, `magnify(with:)`, `mouseDown/Dragged/Up`, `keyDown`). SwiftUI’s `MagnifyGesture` is used for chrome only; it does not deliver scroll-wheel events. On iPad, mirror as `UIViewRepresentable` and use `UIPanGestureRecognizer`/`UIPinchGestureRecognizer`, plus `UIPencilInteraction` for Pencil-driven precise selection.
- If SwiftUI’s window/menu system fights back (main-menu wiring, split view divider quirks), take over `NSApplicationDelegate`/`NSWindowController` in AppKit while keeping SwiftUI views.  Do not use SwiftUI `Canvas` for the spectrogram — it is CG-immediate-mode and cannot stream a hours-long file at 120 Hz.

### 5.3 Metal tile renderer

Reference model: <https://github.com/calebj0seph/spectro> (WebGL) — same algorithm, translated to Metal. Study `docs/making-of.md` there. 

- **Pipeline**: precomputed uint8 dB tiles in Zarr on the backend (§6.4). Client requests tiles via `/spec/tile` at the current LOD covering the visible viewport.
- **Texture storage**: a single `MTLTexture` **atlas** (2D array or a big 2D texture with sub-region uploads), `.r8Unorm` format. One tile = 512×256 = 128 KB. Budget 256–512 MB → 2 000–4 000 tiles resident.
- **Colormap LUT**: 256-entry 1D `MTLTexture` (`.rgba8Unorm`, or `.rgba16Float` for EDR displays). Ship viridis, magma, inferno, cividis, gray. Palette switching is free (no reprocess).
- **Frequency-axis LUT**: a second 1D texture maps screen-Y → tile-Y for log/mel/linear frequency scaling. Rebuild only on scale-mode change.
- **LOD**: mip pyramid built at ingest by **max-pooling** (not averaging — preserves transients, matches iZotope RX practice). Fragment shader trilinear-samples between adjacent mips based on `pixelsPerSecond / binsPerSecond`, or snap to nearest with a 100 ms cross-fade on zoom pop.
- **Frame pacing**: `CAMetalDisplayLink` (macOS 14+/iOS 17+), triple-buffered command buffers (`DispatchSemaphore(value: 3)`),  `maximumDrawableCount = 3`. Draw on demand: `isPaused = true, enableSetNeedsDisplay = true`. Call `setNeedsDisplay` on state change.
- **Overlays in the same pass**: playhead line, selection rectangle(s), and analysis-curve lanes drawn as extra pipeline states after the tile pass. Curve lanes use a min/max-downsampled vertex buffer sized to the visible pixel width — perfect sync with pan/zoom, no coordinate mismatch.
- **Do not use `CATiledLayer`**. Legacy, CPU-drawn, flicker on `setNeedsDisplay`, known iOS 26 threading crashes with SwiftUI hosting. Not worth the small implementation savings.

### 5.4 Analysis curves display

- **Overlaid on the spectrogram (lanes underneath or transparent overlays)**: draw in the Metal pass using min/max-downsampled pyramids fetched from the backend.
- **Inspector detail popovers (single-curve zoomed views)**: `Swift Charts` with LTTB-downsampled ≤ 2 000 points. Do not push Swift Charts past ~2k points; benchmarks show 10k causes noticeable lag, 100k is unusable.  
- The backend precomputes both the raw curve (Parquet) and a min/max pyramid (Zarr or a second Parquet with pyramid-level column) at analysis time. Clients pick which they need.

### 5.5 Playback and filtered audition (`AVAudioEngine`)

- **Long-file playback**: `AVAudioFile` (mmap’d) + `AVAudioPlayerNode.scheduleSegment(_:startingFrame:frameCount:at:)`. Schedule the next segment ~500 ms before the current drains for gapless continuation. Sample-accurate seek: compute `AVAudioFramePosition(seconds * sampleRate)` and `scheduleSegment` from there.
- **Filtered audition** (TIAALS-style “hear the box in isolation”): **backend-rendered STFT→mask→ISTFT** is the flagship path. On selection change:
1. Client sends `POST /audition { audio_id, mask_spec }` (rect, lasso, or harmonic-follower mask + fade edges).
1. Backend renders masked audio to a scratch WAV, keyed by mask hash (cached).
1. Client schedules the WAV on an `AVAudioPlayerNode`.
   This produces cleaner results than realtime `AVAudioUnitEQ` band-passing and matches iZotope RX’s isolated-region playback quality. Provide a “quick preview” mode using `AVAudioUnitEQ` with steep parametric bands as a fallback for large selections while the render is in flight.
- **Time-stretch/pitch**: `AVAudioUnitTimePitch` inserted after the player node. Sufficient for 0.25×–4× auditioning.

### 5.6 Swift concurrency for progress + cancellation

Use `AsyncThrowingStream<JobEvent, Error>` bridged from URLSession’s SSE bytes. Consuming `Task`’s cancellation calls `onTermination`, which fires `POST /jobs/{id}/cancel`. `@Observable` job models own the Task at the document/app layer so jobs outlive their UI. `try Task.checkCancellation()` inside any Swift-side chunked work.

### 5.7 Undo/redo (Swift side — see §7 for full spec)

- `UndoManager` from `@Environment(\.undoManager)`.  Standard ⌘Z / ⌘⇧Z on macOS; provide toolbar buttons on iPad.
- Reducer-style store with value-type `EditorState` snapshots per action.
- Selection **is** part of `EditorState` and undoable (Blender-style).
- Coalesce rapid selection drags into a single undo step (drag gesture wraps `beginUndoGrouping()`/`endUndoGrouping()` or uses `groupsByEvent`).
- Viewport (zoom, pan) is **not** undoable.
- Backend authoritative history: the Swift store issues `POST /undo` and `POST /redo` for annotation-affecting actions; local-only actions (e.g. selection changes) undo locally without a round-trip.

### 5.8 User’s local build steps (put in `apple/README.md`)

```
Requirements:
- Xcode 16.2 or newer (macOS 14/15/16)
- Swift 6.0+ toolchain (bundled with Xcode)
- Python 3.12 or 3.13
- uv (https://github.com/astral-sh/uv) OR pip

One-time setup:
    cd backend
    uv venv && source .venv/bin/activate
    uv pip install -e ".[dev]"
    pytest    # sanity

Run backend:
    python -m indra.server --port 0 --project ~/Music/Indra/scratch.indra

Open the app:
    open apple/IndraApp/IndraApp.xcodeproj
    ⌘R to run.
    (The app auto-launches the backend if not already running; the port is discovered
     from ~/Library/Application Support/Indra/session.json.)
```

-----

## 6. Analysis engine spec

### 6.1 Dependencies (pin these exactly in `backend/pyproject.toml`)

```
python                = ">=3.12,<3.14"
fastapi               = "~=0.139.0"
uvicorn[standard]     = "~=0.50.0"
sse-starlette         = "~=3.4"
pydantic              = "~=2.9"
numpy                 = "<2.2"
scipy                 = ">=1.13"
librosa               = "~=0.11.0"
soundfile             = ">=0.13,<0.15"
av                    = ">=12,<15"      # pyav fallback for m4a/aac
pyarrow               = ">=23,<25"
zarr                  = ">=3.1.6,<4"    # NOT 3.0.2-3.0.7 (yanked, data-loss bug)
numcodecs             = ">=0.15"
blake3                = ">=1.0"
xxhash                = ">=3.4"
sqlite-vec            = ">=0.1.9,<0.2"  # Phase 5 use
libfmp                = ">=1.2"          # for reference Foote novelty; MIT
mpt                   = "git+https://github.com/andymilne/Music-Perception-Toolbox.git@12a006c32f825c406ca2f41a5fcd5870a78c4a56#subdirectory=python"
```

**License hygiene — permissive-only policy. EXCLUDED (do not add, do not import, even transitively):**

- **Essentia** (AGPL-3.0) — copyleft, infects the app.
- **madmom** (abandoned; weights CC-BY-NC).
- **aubio** (GPL-3.0; dormant).
- **LarsNet** (CC-BY-NC 4.0).
- **CLAPSep**-family (visible license CC-BY-NC-ND 4.0).

**Permissive, allowed, but with caveats:**

- `panns-inference` — MIT,  but Snyk marks it Inactive.  Vendor into `indra/_vendor/panns/` (~200 lines) to control the dependency. Model weights (Cnn14) are Apache-2 per upstream; download verified.
- `laion-clap` — **CC0-1.0** (public domain equivalent, not Apache-2 as previously assumed). Fine to use.
- `demucs` / `demucs-infer` — MIT. Model weights MIT per Meta AI.
- **BEATs** (Microsoft) — MIT.  **No PyPI package**; vendor from `github.com/microsoft/unilm/tree/master/beats`  under `indra/_vendor/beats/`.
- **AudioSep** — code MIT, weights license unclear; do not ship until authors confirm.

### 6.2 Ingest pipeline (Phase 0–1)

`POST /files/import` triggers a job that runs these steps, each cancellable and progress-reporting:

1. **Probe** with soundfile (fall back to pyav on `LibsndfileError`): read sr, channels, duration, format. Store row in `audio_files`.
1. **Content hash** with blake3 over decoded PCM at native sr, streamed in 1-second blocks.
1. **Waveform peak pyramid** (int16 min/max, 8 levels, base bucket 256 samples). Store in `arrays/waveform/<audio_id>.zarr`.
1. **STFT tile pyramid** (uint8 dB): 4096 window, 1024 hop, 7-term Blackman-Harris.  Compute framewise via `librosa.stream(path, block_length, frame_length, hop_length, center=False)`. Convert to log-magnitude, quantize to uint8 (mapping -100..0 dB → 0..255). Store as multi-scale Zarr (OME-NGFF-inspired), chunks `(1024, 256)`, Blosc+Zstd `clevel=5`, bitshuffle. Max-pool time by 2× per LOD until one chunk covers the file.
1. **Base framewise features** (fast set): RMS, spectral centroid, spectral flatness, zero-crossing rate — Parquet.

Progress reporting is per-block; cancellation checked after every block. Expected time on M1 for a 1-hour 44.1 kHz stereo file: ingest ≤ 90 s wall clock at 4 workers.

### 6.3 STFT streaming correctness (test-worthy invariant)

`librosa.stream` with `center=False` **must produce bit-identical STFT output** to a naive `librosa.stft(y, center=False)` on the concatenated file, modulo the boundary frames. Write a golden test (§8) that:

- Loads a 30-second test file in full → naive STFT.
- Loads it streamed in 5-second blocks → concatenated streamed STFT.
- Asserts max-abs-diff < 1e-6 in the interior (excluding first/last `n_fft/hop_length` frames).

This is the riskiest correctness assumption; validate it in Phase 0.

### 6.4 On-demand analyses (Phase 2)

Each on-demand analysis is a POST /analyze job with `kind` and `params`:

|kind                      |Backing algorithm                                                                                                         |Params                                                         |M1 perf target (1-h stereo file, full)|Cancellation checkpoint|
|--------------------------|--------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------|--------------------------------------|-----------------------|
|`roughness_mpt`           |`indra.mpt_frames.roughness_curve` (framewise rfft + find_peaks + `mpt.roughness`)                                        |n_fft, hop, top_k peaks, min_prominence, p_norm, average       |≤ 60 s at 4 workers                   |every 256 frames       |
|`spectral_entropy_mpt`    |framewise → `mpt.spectral_entropy` (peaks in cents, σ=10)                                                                 |n_fft, hop, top_k, sigma_cents                                 |≤ 60 s                                |every 256 frames       |
|`template_harmonicity_mpt`|framewise → `mpt.template_harmonicity`                                                                                    |n_fft, hop, top_k, sigma_cents                                 |≤ 90 s                                |every 256 frames       |
|`onsets_superflux_pcen`   |PCEN(mel) → SuperFlux (`onset_strength` with `lag=2, max_size=3`) → peak-pick                                             |sr, n_fft=1024, hop=(sr/200), n_mels=138, fmin=27.5, fmax=16000|≤ 20 s                                |every 5 s of audio     |
|`foote_novelty_multiscale`|`chroma_cqt` (or MFCC) → `recurrence_matrix(mode='affinity')` → `path_enhance` → Foote kernel at scales {8 s, 32 s, 128 s}|feature, kernel scales                                         |≤ 40 s                                |per scale              |
|`embeddings_panns`        |PANN CNN14 (vendored) on 10-s windows, MPS device                                                                         |window_s, hop_s                                                |≤ 45 s                                |per window batch       |
|`embeddings_beats`        |BEATs (vendored) — optional heavier                                                                                       |window_s, hop_s                                                |≤ 4× PANN                             |per window batch       |

**`indra.mpt_frames` implementation notes** (Section 2 above defines the pattern):

- Use `numpy.fft.rfft` on Hann-windowed frames.
- Use `scipy.signal.find_peaks(mag, prominence=min_prominence, height=height)`; convert bin indices to Hz via `bin * sr / n_fft`.
- Cap peaks at `top_k` by magnitude to bound MPT input size (typical 32–64).
- For entropy / harmonicity: `p_cents = mpt.convert_pitch(f_hz, 'hz', 'cents')`.
- For roughness: pass `f_hz` and linear magnitudes directly.
- Do **not** call `mpt.add_spectra` on empirical peaks.
- Every frame call is stateless; parallelize with joblib or `ProcessPoolExecutor` per-block, but keep `cancel_event` visible.

Store curve outputs as Parquet with schema:

```
frame_index i64, time_s f64, value f32, [aux_field f32 ...]
metadata: audio_id, kind, params_json, engine_version, hop_length, sr
```

### 6.5 Focused / localized analysis (drill-down)

The user’s guiding project needs: *select a region, run deeper analysis inside it.*

- Client selects a time-frequency box or a time range.
- `POST /analyze { audio_id, kind, params, region: { t0, t1, f0?, f1? } }`.
- Backend applies the standard pipeline but restricted to `[t0, t1]` and (for features that support it) frequency-masked to `[f0, f1]`.
- Region-scoped results are keyed separately in the cache (region params go into `params_json`).
- Return either raw arrays or a summary object (mean, std, peaks) via `/features/{kind}?t0=..&t1=..`.

### 6.6 Export (Phase 3)

`POST /export { audio_id, kinds: [...], format: "json"|"csv", region? }` returns a streamed file. Schema examples:

- **JSON**:
  
  ```
  {
    "audio_id": "...",
    "audio": { "sr": 44100, "duration_s": 3600.0, "channels": 2 },
    "engine_version": "indra-engine 0.4.1",
    "segments": [ { "t0": .., "t1": .., "label": ..., "note": ... }, ... ],
    "onsets": [ { "t": .., "strength": .. }, ... ],
    "features": {
      "roughness":       { "hop_length": 1024, "sr": 44100, "values": [ ... ] },
      "spectral_entropy":{ "hop_length": 1024, "sr": 44100, "values": [ ... ] },
      ...
    },
    "annotations": [ ... ]
  }
  ```
- **CSV**: one row per frame, one column per feature; annotations and onsets as separate sidecar CSVs.

The user is driving external visual systems with this — keep schemas stable, versioned (`schema_version` field), and documented in `docs/export_schema.md`.

### 6.7 Cloud tier (Phase 5, later, opt-in)

Scoped down to a footer here; do not build in Phases 0–4:

- GCP Cloud Batch spot T4 workers for heavy embeddings and text-queried separation.
- GCS artifact store; jobs signal completion by writing `manifest.json`.
- Client polls or receives push via Firebase or a signed-URL callback.
- Bandwidth, cost, and privacy controls are user settings.
- Nothing runs in the cloud without explicit user consent per project.

-----

## 7. Undo/redo spec

**Chosen model**: Blender-style, patch-based, selection is first-class undoable state.

### 7.1 Backend authoritative history

- SQLite `undo_log` table holds RFC-6902 JSON Patches (forward and inverse) with timestamps and action scope.
- `HistoryManager` service:
  - `apply(action) -> patch`: computes forward+inverse, mutates DB in a transaction, appends row.
  - `undo() -> inverse_patch`: pops top row (of the *user’s* branch), applies inverse.
  - `redo() -> forward_patch`: pushes back if a redo stack exists.
  - Redo is invalidated by any new forward action (standard branching model).
- Scope: annotations, labels, project settings are undoable. Analysis cache regeneration is **not** undoable (it’s derived data).

### 7.2 Swift-side mirror

- `EditorState` value type: `selection, annotations, labels, activeAudioId, activeAnalyses, lensesEnabled, ...`.
- `viewport` (zoom, pan, current LOD) is a separate scene state — **not undoable**.
- Reducer: `func reduce(_ state: EditorState, _ action: EditorAction) -> EditorState`. Pure. No side effects.
- `DocumentStore` (`@Observable`, class, injected `UndoManager`):  snapshots `EditorState` per action, registers inverse via `undoManager.registerUndo(withTarget:)`.
- **Selection changes coalesce**: rapid drag events wrapped in `beginUndoGrouping()`/`endUndoGrouping()` — one drag = one undo step. Use a 300–500 ms trailing debounce for keyboard-driven micro-adjustments.
- Round-trips: annotation edits sync to backend via API before registering undo (`POST /undo` on ⌘Z). Local-only actions (selection, viewport) undo locally without backend contact.
- Persistence: undo stack is cleared on document save. Do not serialize the stack.

### 7.3 API

```
POST /undo   → { applied_patch: [...], scope: "annotations", undo_stack_depth: N, redo_stack_depth: M }
POST /redo   → same shape
GET  /history → [ { id, ts, scope, action_name }, ... ]  (last 100)
```

Action-name convention: `"Add annotation"`, `"Move selection"`, `"Change label color"` — appears in the Edit menu (“Undo Add annotation”).

-----

## 8. Testing and verification strategy

### 8.1 pytest suites (backend, headlessly verifiable)

- `tests/test_ingest.py`: streaming vs full STFT equivalence (§6.3). Golden audio fixtures: 30-second sine sweep, 30-second white noise, 30-second silence, 30-second field-recording clip (checked in, ≤ 5 MB).
- `tests/test_api_contract.py`: FastAPI TestClient against every endpoint; JSON schemas via pydantic. Include SSE stream tests using `httpx` streaming.
- `tests/test_jobs.py`:
  - Job runs to completion; progress events are monotonic; ETA emitted.
  - Job cancellation: submit, cancel after N progress events, assert state == cancelled within 2 s and no zombie processes.
  - Resume-from-cache: run twice, second run is `done` immediately with same `result_ref`.
- `tests/test_mpt_frames.py`:
  - Feed a known peak list to `mpt.roughness` and assert the return value.
  - Framewise roughness curve for a synthetic dyad glide matches a reference profile within 1e-3.
  - `spectral_entropy` monotonic behavior on a chord densification test.
- `tests/test_cache.py`: cache-key stability across param dict reorderings; blake3 of PCM stable across re-decodes.
- `tests/test_export.py`: round-trip a project → export JSON → parse → verify schema and value fidelity.

Run with `pytest -q --cov=indra --cov-fail-under=80` in CI.

### 8.2 Swift Testing on Linux (IndraKit)

- `IndraKitCoreTests`:
  - `UndoStack`: apply, undo, redo, invalidate-redo-on-new-action, selection-as-state undo.
  - `EditorReducer`: pure reduction; identity on no-op; determinism.
  - `TileCache`: LRU behavior, key stability.
  - Codable round-trips for every wire type.
- `IndraKitNetTests`:
  - `APIClient` against a mock `URLProtocol` returning canned responses.
  - SSE parser: split-across-chunks event framing, `data:` continuation lines, comment lines, retry field parsing.
  - Cancellation: cancelling the consumer Task issues `POST /jobs/{id}/cancel`.

Run: `docker run --rm -v "$PWD/apple/IndraKit:/src" -w /src swift:6.2-noble swift test --parallel`.

### 8.3 GitHub Actions CI

`.github/workflows/ci.yml`:

```yaml
name: CI
on: { push: { branches: [main] }, pull_request: {} }
jobs:
  backend:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: backend } }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install uv
      - run: uv pip install --system -e ".[dev]"
      - run: pytest -q --cov=indra --cov-fail-under=80
  indrakit:
    runs-on: ubuntu-latest
    container: swift:6.2-noble
    steps:
      - uses: actions/checkout@v4
      - name: Cache .build
        uses: actions/cache@v4
        with:
          path: apple/IndraKit/.build
          key: swiftpm-${{ hashFiles('apple/IndraKit/Package.resolved', 'apple/IndraKit/Package.swift') }}
      - run: swift --version
      - name: Build kit targets
        working-directory: apple/IndraKit
        run: |
          swift build --target IndraKitCore
          swift build --target IndraKitNet
      - name: Test
        working-directory: apple/IndraKit
        run: swift test --parallel
```

No macOS runner in CI. User covers app builds locally.

### 8.4 Optional throwaway dev probe (§3)

`dev/api_probe.html`: a single static HTML file with a `<canvas>` that fetches waveform tiles and one spectrogram tile from a running backend. Big banner at top: `<!-- THROWAWAY DEV TOOL — not a product surface. May be deleted at any time. -->`. Do not test it in CI. Do not evolve it into a UI.

### 8.5 User-side smoke-test checklist

After each PR that touches non-headless code, the PR description MUST include a “Local smoke test” block like:

```
## Local smoke test (please run before merging)
1. cd backend && python -m indra.server --project ~/Music/Indra/scratch.indra --port 0
2. Note the port printed. Then in another terminal:
   curl -s http://127.0.0.1:$PORT/health   # expect {"status":"ok"}
3. Open apple/IndraApp/IndraApp.xcodeproj in Xcode 16.2+, ⌘R.
4. File > Import Audio... > select a WAV.
5. Verify:
   - Progress bar appears; cancel button aborts within 2s.
   - Spectrogram renders after ingest; pan/zoom smooth at 60+ fps.
   - Click-drag selects a region; ⌘Z reverts selection.
```

-----

## 9. Phased roadmap

Definition-of-done (DoD) items are all objectively verifiable — every one has a test or a smoke-test recipe.

### Phase 0 — Engine skeleton and ingest (2–3 sessions)

- `backend/` project with `pyproject.toml`, `uv.lock`, `ruff` + `mypy` configured.
- FastAPI app with `/health`, `/project`, `/files/import`, `/files`, lifespan-managed SQLite + ProcessPoolExecutor + JobRegistry.
- Bearer-token middleware.
- Cancellable job system per §4.5, with SSE progress endpoint working end-to-end (tested via httpx streaming).
- Ingest pipeline steps 1–3 (probe, content hash, waveform peak pyramid). STFT tile pyramid deferred to Phase 1.
- pytest coverage ≥ 70% at this phase; job cancellation test green.

**DoD**: `curl -N http://127.0.0.1:PORT/jobs/{id}/events` streams progress; POST cancel aborts within 2 s.

### Phase 1 — Tile serving and IndraKit client (3–4 sessions)

- STFT tile pyramid (§6.4) implemented with `librosa.stream`, multi-scale Zarr output.
- Streaming vs full STFT equivalence test (§6.3) green — **riskiest correctness assumption validated here.**
- `/spec/tile` and `/waveform/tile` endpoints returning binary tile payloads with `X-Indra-Tile-*` headers.
- `IndraKit/Package.swift` with three targets (`IndraKitCore`, `IndraKitNet`, `IndraKitAppleGlue`).
- `APIClient` (URLSession + FoundationNetworking gate)  with methods for every endpoint.
- SSE parser (`URLSession.bytes(for:)` → AsyncThrowingStream<SSEEvent, Error>`).
- `TileCache`, `EditorState`, reducer, undo stack — all Linux-tested via swift-testing.
- GitHub Actions CI green: both `backend` and `indrakit` jobs.

**DoD**: `dev/api_probe.html` renders a waveform and a spectrogram tile from a real ingested file. Swift tests pass in `swift:6.2-noble`.

### Phase 2 — On-demand analyses and MPT (3–4 sessions)

- `indra.mpt_frames` module (§6.4) with `roughness_curve`, `entropy_curve`, `template_harmonicity_curve` — cancellable, parallelized.
- SuperFlux-on-PCEN onset detection.
- Multi-scale Foote checkerboard novelty (`libfmp` reference or vendored ~15-line kernel).
- Feature Parquet storage + min/max pyramid for display downsampling.
- `/features/{kind}?t0=..&t1=..&downsample=..` endpoint.
- Region-scoped analysis (§6.5).
- Golden-value tests for each MPT curve on synthetic inputs.

**DoD**: For the noisescape reference file, `POST /analyze` produces roughness, entropy, harmonicity, onsets, and Foote-novelty within perf targets. Region-scoped drill-down verified via API test.

### Phase 3 — Annotations, undo, export (2–3 sessions)

- Annotation CRUD API + SQLite schema.
- `HistoryManager` with RFC-6902 patch log (§7).
- `/undo`, `/redo`, `/history` endpoints.
- Swift-side mirror in `IndraKit`: reducer + UndoManager integration, selection-as-state.
- Export endpoint (§6.6) with JSON and CSV, schema documented.

**DoD**: For the 1-hour noisescape, end-to-end via API + a minimal SwiftUI harness view (a table of annotations, a debug canvas showing waveform peaks): user can import, run all analyses, add annotations, undo/redo, export a JSON that drives an external visual pipeline. **This completes the guiding first project’s data path.**

### Phase 4 — Native UI maturity (open-ended; iterate)

- Metal tile renderer per §5.3: colormap LUT, LOD selection, ProMotion pacing, triple buffer.
- Gesture layer on subclassed MTKView.
- Selection overlay, playhead, curve lanes in the same Metal pass.
- Multiple toggleable lenses/views (raw dB spectrogram / PCEN spectrogram / roughness heatmap / harmonicity heatmap) — implemented as alternate colormap+source-tile combinations.
- AVAudioEngine playback, filtered-selection audition, time-stretch.
- Progress panel with per-job progress bars and cancel buttons.
- Inspector using Swift Charts for detail popovers (≤ 2k downsampled points).
- Polish: window state persistence, keyboard shortcuts, drag-and-drop import.

**DoD**: full app feel — user can do everything from Phase 3 with pointer-and-eyes UX on M1 8 GB at 60+ fps sustained pan/zoom on the 1-hour file.

### Phase 5 — Cloud tier and archive scale (opt-in, later)

- GCP Cloud Batch worker image; spot T4 for BEATs, Demucs, CLAP.
- GCS artifact store; `manifest.json` completion signal.
- sqlite-vec + PANN embeddings for local similarity search across a curated corpus.
- Clustering (HDBSCAN over embeddings), audio-similar-region highlighting.
- Optional text-queried separation (only after weight-license clarification for AudioSep).

### Riskiest-assumption validation checklist (run early, revisit each phase)

1. **`librosa.stream` seam correctness at `center=False`** — Phase 0/1. If this fails, fall back to a bespoke chunked STFT with explicit overlap handling.
1. **MPT framewise perf on M1** — Phase 2. Measure roughness curve throughput at 4 workers. If target missed by > 2×, add a Cython/Numba inner loop or thin the peak input (`top_k=16`).
1. **RAM budget under real load** — every phase. Profile with `psutil` during ingest and analysis of a 1-hour file; enforce budgets in CI-adjacent perf tests where feasible.
1. **Metal tile renderer feel** — Phase 4. Ask the user to sanity-check 120 Hz feel on their actual hardware early. If unacceptable, adjust tile size, mip count, or drop to 60 fps with `present(afterMinimumDuration:)`.
1. **Cancellation latency** — Phase 0. If any cancel takes > 2 s on the reference file, the loop in question doesn’t check `cancel_event` often enough.

-----

## 10. Engineering conventions

### 10.1 Repo layout

```
indra/                              (repo root)
├── README.md
├── docs/
│   ├── api.md
│   ├── export_schema.md
│   ├── architecture.md
│   └── adr/                        (see ADR policy below)
├── backend/
│   ├── pyproject.toml
│   ├── uv.lock
│   ├── src/indra/
│   │   ├── server.py               (uvicorn entrypoint)
│   │   ├── app.py                  (FastAPI app factory + lifespan)
│   │   ├── api/                    (route modules)
│   │   ├── jobs/                   (registry, worker, cancellation)
│   │   ├── ingest/                 (probe, hash, waveform, stft pyramid)
│   │   ├── analyses/               (mpt_frames, onsets, novelty, embeddings)
│   │   ├── storage/                (zarr, parquet, sqlite, cache)
│   │   ├── history/                (patch-based undo)
│   │   └── _vendor/                (panns, beats — vendored, license headers kept)
│   └── tests/
├── apple/
│   ├── README.md                   (user-facing local build steps)
│   ├── IndraKit/                   (Swift package, Linux-testable)
│   └── IndraApp/                   (Xcode project, macOS/iPadOS)
├── dev/
│   └── api_probe.html              (throwaway)
└── .github/workflows/ci.yml
```

### 10.2 Code style

- **Python**: `ruff` (lint+format), `mypy --strict` on `indra/*`, type hints everywhere. Async where I/O; sync where CPU (delegate CPU to workers).
- **Swift**: Swift 6 language mode. Strict Sendable. `swift-testing` only. `swift-format` in CI. Value types by default; `class` only when identity or Objective-C bridging demanded.
- Line length 100 (both).

### 10.3 Commit discipline

- Conventional Commits (`feat:`, `fix:`, `refactor:`, `test:`, `chore:`, `docs:`, `perf:`).
- One logical change per commit. Test changes in the same commit as the code they cover.
- Every PR references the phase and DoD item it advances.
- Every PR touching a non-headless surface includes the “Local smoke test” block (§8.5).

### 10.4 ADRs

`docs/adr/NNNN-title.md` — one file per architectural decision. Template:

```
# NNNN. Title
Date: YYYY-MM-DD
Status: proposed | accepted | superseded by NNNN
Context: ...
Decision: ...
Consequences: ...
Alternatives considered: ...
```

Seed the repo with these ADRs on day one, capturing decisions from this document:

- 0001 Decoupled Python engine + native Swift app.
- 0002 SwiftUI shell + NSViewRepresentable-hosted MTKView.
- 0003 Zarr v3 multi-scale uint8 dB tile pyramids.
- 0004 In-process ProcessPoolExecutor + mp.Event cancellation.
- 0005 SSE (not WebSocket) for job progress streaming.
- 0006 blake3 for content addressing.
- 0007 Swift 6 language mode + swift-testing.
- 0008 Backend-rendered STFT→mask→ISTFT audition (not realtime EQ).
- 0009 Selection is undoable; viewport is not.
- 0010 Permissive-only dependency policy with named exclusions.

New decisions during Phases 1–5 get their own ADR.

### 10.5 When to ask the user vs decide autonomously

**Decide autonomously**:

- Any implementation detail within an ADR’s boundaries.
- Refactoring, test additions, doc updates.
- Choosing between two libraries with equivalent license/quality — pick one, log an ADR.
- Filling in gaps in this document with judgment consistent with its principles.

**Ask the user** (open a `Question:` GitHub issue and pause the affected work):

- Any change that would break `docs/export_schema.md` compatibility once a schema version has shipped.
- Adding a new runtime dependency with a non-permissive license or one not on the allowlist (§6.1).
- Deferring or dropping a Phase 0–3 DoD item.
- UX decisions that were left implicit here (colormap defaults, keyboard shortcut set, iPad-specific gesture assignments).
- Any change requiring model weight downloads with unclear licensing (AudioSep, third-party BEATs checkpoints).

### 10.6 License hygiene (enforce continually)

- Every new dep gets its license checked and recorded in `docs/licenses.md`.
- CI runs `pip-licenses --format=json --with-license-file --with-notice-file --output-file=backend/licenses.json` and fails on any AGPL/GPL/LGPL-static/CC-BY-NC/CC-BY-ND/CC-BY-NC-ND appearance.
- Vendored code (`_vendor/`) retains its upstream LICENSE and README with source URL and commit SHA. Do not modify vendored files except to fix imports.

-----

## Appendix A — Key reference links

- MPT repo: <https://github.com/andymilne/Music-Perception-Toolbox>
- MPT User Guide: <https://github.com/andymilne/Music-Perception-Toolbox/blob/master/USER_GUIDE.md>
- calebj0seph/spectro (WebGL reference for tile-atlas + colormap-LUT): <https://github.com/calebj0seph/spectro> — read `docs/making-of.md`.
- Sonic Visualiser (panes + layers architecture prior art): <https://github.com/sonic-visualiser/sonic-visualiser>
- TIAALS (isolated selection audition UX): reference behavior only.
- BBC audiowaveform (`.dat` peak-pyramid format spec): <https://github.com/bbc/audiowaveform>
- Zarr v3: <https://zarr.readthedocs.io/>
- sqlite-vec: <https://github.com/asg017/sqlite-vec>
- panns-inference: <https://github.com/qiuqiangkong/panns_inference>
- Demucs: <https://github.com/facebookresearch/demucs>
- LAION-CLAP: <https://github.com/LAION-AI/CLAP>
- BEATs (Microsoft unilm): <https://github.com/microsoft/unilm/tree/master/beats>
- Metal display link: <https://developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link>
- Apple audio spectrogram sample (Accelerate + vImage): <https://developer.apple.com/documentation/accelerate/visualizing-sound-as-an-audio-spectrogram>
- WWDC24 “Accelerate ML with Metal” (MPSGraph FFT): <https://developer.apple.com/videos/play/wwdc2024/10218/>
- sse-starlette: <https://github.com/sysid/sse-starlette>
- mattt/EventSource (Swift SSE client): <https://github.com/mattt/EventSource>

-----

**End of build prompt.** Begin with Phase 0. Commit early, commit often. When a non-headless surface changes, write the local smoke-test recipe into the PR body.