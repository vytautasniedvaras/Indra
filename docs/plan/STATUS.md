# Indra — Build Status

> **This is the living resume anchor.** Any session or subagent continuing this build reads this
> file first, then `git log`, then picks up the next unchecked task. Update after every
> meaningful work chunk. The authoritative design is `docs/BUILD_SPEC.md`; deviations recorded
> here (and in ADRs when architectural) override it.

- **Current phase**: Phase 1 — Tile serving and IndraKit client (backend half done)
- **Branch**: `claude/fable-research-implementation-8z004i`
- **Last updated**: 2026-07-06 evening (Phase 1 backend half done, CI green, demo rendered)

## Process (agreed with user 2026-07-06)

- PR per phase from the designated branch to `main`; never push `main` directly.
- Continuous autonomous work; self-scheduled check-in triggers re-arm each turn.
- Run straight through Phases 0–3; never block on Mac smoke tests (queue them in
  `docs/plan/SMOKE_TESTS.md` and phase-boundary GitHub issues).
- Contact user only at spec §10.5 boundaries: GitHub `Question:` issue + session chat message.

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
- [ ] IndraKit Swift package (Core/Net/AppleGlue) with swift-testing on Linux via Docker
- [ ] APIClient covering every endpoint + SSE parser (AsyncThrowingStream)
- [ ] TileCache, EditorState, reducer, undo stack (Linux-tested)
- [ ] dev/api_probe.html throwaway probe
- [x] CI green for backend + indrakit jobs (run 28812887031, after user's GitHub Pro upgrade)
- [ ] **Perf follow-up**: live import of a 90 s mono 44.1 kHz file took ~35 s wall (single
      worker, serial hash→waveform→STFT). Extrapolates ~23 min for the 1-hour reference vs the
      §6.2 target of ≤90 s at 4 workers. Profile (suspects: per-append Blosc compression on
      small zarr appends, Manager-proxy progress reports per block, serial pipeline stages)
      and parallelize before Phase 1 closes.

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
