# Indra — Build Status

> **This is the living resume anchor.** Any session or subagent continuing this build reads this
> file first, then `git log`, then picks up the next unchecked task. Update after every
> meaningful work chunk. The authoritative design is `docs/BUILD_SPEC.md`; deviations recorded
> here (and in ADRs when architectural) override it.

- **Current phase**: Phase 0 — Engine skeleton and ingest
- **Branch**: `claude/fable-research-implementation-8z004i`
- **Last updated**: 2026-07-06

## Process (agreed with user 2026-07-06)

- PR per phase from the designated branch to `main`; never push `main` directly.
- Continuous autonomous work; self-scheduled check-in triggers re-arm each turn.
- Run straight through Phases 0–3; never block on Mac smoke tests (queue them in
  `docs/plan/SMOKE_TESTS.md` and phase-boundary GitHub issues).
- Contact user only at spec §10.5 boundaries: GitHub `Question:` issue + session chat message.

## Phase 0 task checklist

- [x] Repo bootstrap: skeleton dirs, BUILD_SPEC.md, living docs, ADRs 0001–0010, CI, .gitignore
- [x] `backend/pyproject.toml` + `uv.lock` + ruff/mypy config; MPT vendored (ADR 0011) & import verified
- [ ] FastAPI app factory + lifespan (SQLite WAL, ProcessPoolExecutor(spawn), JobRegistry)
- [ ] Bearer-token middleware; 127.0.0.1-only bind; session.json port/token handshake
- [ ] `/health`, `/project` endpoints
- [ ] Cancellable job system (§4.5): JobHandle, mp.Event, progress queue → asyncio bridge → SSE
- [ ] Job tests: monotonic progress, cancel < 2 s, no zombies, resume-from-cache
- [ ] Content-addressed cache (§4.6): blake3 keys, blobs/ layout, analysis_cache table, LRU eviction
- [ ] Ingest steps 1–3 (§6.2): probe, streamed content hash, waveform peak pyramid → Zarr
- [ ] Synthetic fixture generator script (sine sweep / noise / silence, ≤ 5 MB total)
- [ ] Coverage ≥ 70 %; ruff + mypy clean; CI green
- [ ] Phase 0 DoD: SSE streams via `curl -N`; POST cancel aborts < 2 s (live server check)
- [ ] Open Phase 0 PR + smoke-test issue → begin Phase 1

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

(none)

## Notes for the next session

- Environment: Python 3.12 via uv; Docker available for `swift:6.2-noble` tests; PyPI + MPT
  git install reachable through the agent proxy.
- Spec dependency pins are "as of April 2026" — validate against reality at install time and
  record any substitutions above.
