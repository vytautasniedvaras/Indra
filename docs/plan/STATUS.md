# Indra — Build Status

> **This is the living resume anchor.** Any session or subagent continuing this build reads this
> file first, then `git log`, then picks up the next unchecked task. Update after every
> meaningful work chunk. The authoritative design is `docs/BUILD_SPEC.md`; deviations recorded
> here (and in ADRs when architectural) override it.

- **Current phase**: Phase 4 — Native UI (harness app + audition + render math done; Metal canvas next)
- **Branch**: `claude/fable-research-implementation-8z004i`
- **Last updated**: 2026-07-06 evening (Phase 1 backend half done, CI green, demo rendered)

## Process (agreed with user 2026-07-06)

- PR per phase from the designated branch to `main`; never push `main` directly.
- Continuous autonomous work; self-scheduled check-in triggers re-arm each turn.
- Run straight through Phases 0–3; never block on Mac smoke tests (queue them in
  `docs/plan/SMOKE_TESTS.md` and phase-boundary GitHub issues).
- Contact user only at spec §10.5 boundaries: GitHub `Question:` issue + session chat message.
- **Commit message style (user request 2026-07-06)**: a single short line, functional,
  as few characters as readability allows; conventional prefix (feat:/fix:/docs:/test:/chore:).
  No bodies unless genuinely necessary, NO attribution trailers, NO session links.
  Example: `feat: STFT tile pyramid + tile endpoints`.

## Phase 0 task checklist

- [x] Repo bootstrap: skeleton dirs, BUILD_SPEC.md, living docs, ADRs 0001–0010, CI, .gitignore
- [x] `backend/pyproject.toml` + `uv.lock` + ruff/mypy config; MPT vendored (ADR 0011) & import verified
- [x] FastAPI app factory + lifespan (SQLite WAL, ProcessPoolExecutor(spawn), JobRegistry)
- [x] Bearer-token middleware; 127.0.0.1-only bind; session.json port/token handshake
- [x] `/health`, `/project` endpoints
- [x] Cancellable job system (§4.5): JobHandle, Manager Event/Queue → asyncio bridge → SSE
- [x] Job tests: monotonic progress + ETA, cancel < 2 s, resume-from-cache, failure propagation
- [x] Content-addressed cache (§4.6): blake3 keys, blobs/ layout, analysis_cache table, LRU eviction
      (eviction never touches active-project zarr; active ids wired from audio_files)
- [x] Ingest steps 1–3 (§6.2): probe (soundfile→pyav), streamed content hash, waveform pyramid → Zarr
- [x] Synthetic fixtures generated in conftest (sweep wav, noise flac, silence wav, tone m4a for
      the pyav fallback) — nothing binary checked in
- [x] Coverage 81 % (gate 70); ruff + mypy --strict clean; CI green pending first push
- [x] Phase 0 DoD verified live: `curl -N` SSE with ETA; cancel latency 0.27 s
- [x] Phase 0 PR opened: https://github.com/vytautasniedvaras/Indra/pull/1 (smoke test in PR body)

## Phase 1 task checklist

- [x] STFT streaming equivalence validated (riskiest assumption): librosa.stream AND bespoke
      pyav-path streamer bit-identical to full STFT (tests/test_stft.py)
- [x] uint8 dB multi-scale spec pyramid (7-term Blackman-Harris per Albrecht 2001, Blosc+Zstd
      bitshuffle, max-pool LODs, 0 dB = full-scale sine) wired into import step 4
- [x] `/waveform/tile` + `/spec/tile` binary endpoints with X-Indra-Tile-* headers
- [x] IndraKit Swift package (Core/Net/AppleGlue), Swift 6 mode, swift-testing — 47 tests
      green in swift:6.2-noble via CI (local Docker blocked: registry CDNs denied by the
      environment network policy; CI is the Swift test runner for now)
- [x] APIClient covering every endpoint + byte-level SSE parser (CRLF-grapheme bug caught by CI)
      + consumer-cancellation → POST /cancel (and NOT on normal completion)
- [x] TileCache (byte-bounded LRU actor), EditorState + pure reducer, UndoStack with drag
      coalescing — all Linux-tested
- [x] dev/api_probe.html throwaway probe + apple/README.md build steps
- [x] CI green for backend + indrakit jobs (run 28812887031, after user's GitHub Pro upgrade)
- [ ] **Perf follow-up (corrected)**: the earlier 35 s reading was a measurement artifact
      (an SSE curl blocked inside the timed shell window). Clean measurement: 3.25 s for the
      90 s file end-to-end through the live server; profiled stages: probe+hash+waveform 0.1 s,
      STFT pyramid 2.35 s. Projection for 1-hour stereo ≈ 4 min single-worker vs the §6.2
      target of ≤90 s at 4 workers → needs ~3x: parallelize STFT blocks across the pool
      (or per-stage jobs). Do when the 1-hour reference file testing starts (Phase 2).

## Phase 2 task checklist

- [x] `indra.analyses.mpt_frames`: frame_peaks + roughness/entropy/harmonicity curves —
      cancellable, streamed, region-scoped (time AND frequency band)
- [x] Golden-value tests: peaks at known partials, semitone>octave>unison roughness, curve ==
      direct per-frame MPT reference (<1e-3), entropy monotonic under densification (raw bits,
      normalize=False — MPT's normalization is span-dependent), harmonic>inharmonic h_max
- [x] SuperFlux-on-PCEN onsets (segmented streaming, PCEN warm-up overlap) — finds test clicks
- [x] Multi-scale Foote novelty (SSM bounded at 4096 frames via decimation) — finds boundaries
- [x] Parquet feature store + /features endpoint (raw capped at 20k pts; min/max buckets)
- [x] Region-scoped analysis with distinct cache keys
- [x] Perf targets MET after tuning (riskiest-assumption lever #2): prominence 0.05 (above
      Hann sidelobe), resolution 3 cents, top_k 32, harmonicity hop 2048 →
      roughness ~1.2 min/h single-worker, entropy ~28 s/h @4w-eq, harmonicity ~62 s/h @4w-eq
- [x] Coverage 93 % via in-process tests of worker-side code (subprocess execution is
      invisible to coverage); CI gate raised to the spec's 80. Kernel-balance and edge-response
      bugs in Foote novelty found and fixed by these tests.
- [x] Update PR #1 description for Phase 2 → next: Phase 3 (annotations, undo, export)

## Phase 3 task checklist

- [x] Annotation CRUD API (POST/GET/PATCH/DELETE /annotations) + validation
- [x] HistoryManager: RFC-6902 forward+inverse patches in undo_log; every annotation mutation
      transactional + logged; redo branch invalidated by new forward actions
- [x] /undo /redo (409 on empty stacks; §7.3 response shape) + /history (last 100)
- [x] Schema v2 migration: annotations.id AUTOINCREMENT — SQLite rowid reuse would have let a
      recycled id corrupt patch identity (caught by the redo-invalidation test)
- [x] Export §6.6: JSON document + CSV zip (features.csv on densest grid, annotations.csv,
      onsets.csv, manifest.json); region slicing; docs/export_schema.md (schema_version 1)
- [x] Swift mirror (DocumentStore w/ drag coalescing + sync routing, annotation/undo/history
      APIClient endpoints, 29 new tests) — built by a parallel agent, CI green
- [x] Phase 3 DoD verified on the 1-hour reference noisescape (44.1 kHz, 3 workers):
      import 46 s (target ≤90 s) · all five analyses concurrently 250 s wall
      (onsets+roughness 75 s, novelty 87 s, entropy 119 s, harmonicity 250 s) ·
      annotate + undo/redo OK · export 5 s → 58 MB JSON (155k roughness pts, 722k onset-env
      pts, 4k novelty pts, annotations, onsets) · backend RSS 221 MB (budget: ≤1.5 GB)
      — the guiding project's data path is complete end-to-end via API.
      Remaining DoD element (minimal SwiftUI harness view) is Mac-side → SMOKE_TESTS/Phase 4.

## Phase 4 task checklist (in progress)

- [x] `/audition` endpoint (§5.5, ADR 0008): STFT → raised-cosine mask → ISTFT to scratch WAV,
      stereo, click-free edge fades, mask-hash cached, 600 s cap — spectral isolation verified
- [x] Render-support math in IndraKitCore (CI-tested): Viewport (anchor-fixed zoom/pan, lin/log
      freq), TilePlanner (LOD choice + gap-free 512-col tile coverage), Colormaps (viridis/
      magma/inferno/cividis/gray RGBA8 LUTs), CurveLane min/max downsampler
- [x] IndraApp debug harness (SwiftPM executable, ADR 0012; user-smoke-tested only): backend
      spawn/discovery, import w/ SSE progress, CPU debug canvas (waveform + spectrogram),
      annotations table w/ ⌘Z/⇧⌘Z (server-backed), five analyses w/ progress+cancel, JSON
      export panel, AVAudioEngine playback w/ seek + 0.25-4x time-pitch. CI builds the Linux
      stub as a structural check. **READY FOR FIRST MAC SMOKE TEST** (SMOKE_TESTS.md Phase 4).
- [ ] Metal tile renderer (§5.3): MTKView canvas, tile atlas, colormap/freq-scale LUT shaders,
      LOD cross-fade, overlays (playhead/selection/lanes) — consumes the IndraKitCore math
- [ ] Gesture layer (scroll/magnify/drag on subclassed MTKView)
- [ ] Audition wiring in the app (selection → POST /audition → play rendered WAV)
- [ ] Quick-preview EQ fallback while audition renders (§5.5)

## Deviations from BUILD_SPEC.md

1. **MPT vendored, not pip-installed** (ADR 0011): the spec's canonical
   `git+…#subdirectory=python` install is broken at the pinned SHA *and* at upstream HEAD
   (pyproject references `../README.md`, rejected by modern setuptools; verified with pip and
   uv). Vendored unmodified at the pinned SHA under `backend/src/indra/_vendor/mpt/`.
2. **av pinned `<14.3`** (spec: `<15`): av 14.4.0 ships no cp312 wheels and its sdist requires
   ffmpeg 7 headers; 14.2.0 has wheels everywhere we build.
3. **soxr LGPL-2.1 exception** (transitive, mandatory under spec-pinned librosa): dynamically
   linked, policy forbids LGPL-*static* only. Documented in docs/licenses.md; user can veto.
4. **sqlite-vec not yet added**: spec lists it in §6.1 pins but marks it "Phase 5 use"; it will
   be added when Phase 5 starts.

## Blockers / waiting on user

(none — CI unlocked by the user's GitHub Pro upgrade on 2026-07-06; issue #2 can be closed)

## Notes for the next session

- Durable MCP create_trigger still blocked on approval (retried many times). In-session
  hourly CronCreate heartbeat is armed instead (re-arm at session start — it died once
  already with a container restart on 2026-07-06 evening). If the user is in the app when
  create_trigger is retried, a one-tap approval makes continuation fully durable.
- SQLite datetime('now') is 1-second granular — LRU tests sleep 1.1 s between puts. If cache
  churn ever needs sub-second LRU, switch last_used_at to unixepoch subsecond.

- Environment: Python 3.12 via uv; Docker available for `swift:6.2-noble` tests; PyPI + MPT
  git install reachable through the agent proxy.
- Spec dependency pins are "as of April 2026" — validate against reality at install time and
  record any substitutions above.
