# Indra backend API

Authoritative wire contract between the Python engine and IndraKit. Updated in the same
commit as any endpoint change. Design sketch: `docs/BUILD_SPEC.md` §4.3.

## Conventions

- All endpoints except `GET /health` require `Authorization: Bearer <token>`; the token is in
  the session handshake file (`~/Library/Application Support/Indra/session.json` on macOS,
  `$XDG_DATA_HOME/indra/session.json` elsewhere) written at server start:
  `{ "port": int, "token": str, "pid": int, "project": str }`.
- Every error body: `{ "error": { "code": str, "message": str, "details": {} } }`.
  Codes seen: `unauthorized`, `not_found`, `bad_request`, `validation_error`, `internal`.
- The server binds `127.0.0.1` only.

## Implemented endpoints (Phase 0)

### `GET /health` (no auth)
`{ "status": "ok" }`

### `GET /project`
`{ "root": str, "format_version": int, "engine_version": str }`

### `POST /files/import`
Body `{ "path": str, "mode": "copy" | "reference" }` (mode default `reference`).
Returns `{ "job_id": str }` — import runs as a job; the `audio_id` (blake3 content hash)
is in the job's `result_ref`: `{ "audio_id": str, "already_imported": bool }`.
404 if the path does not exist.

### `GET /files`
Array of `{ id, orig_path, stored_path, mode, sr, channels, frames, duration_s, format,
imported_at }`.

### `GET /files/{audio_id}/manifest`
`{ id, sr, channels, frames, duration_s, format, waveform_lods: [ { lod, bucket_samples,
buckets } ], features: [] }`. Waveform pyramid: 8 LODs, base bucket 256 samples, int16
min/max per (bucket, channel).

### `POST /analyze`
Body `{ "kind": str, "audio_id": str = "", "params": {} }` → `{ "job_id": str }`.
Phase 0 kinds: `debug_slow` (test/probe job; params `steps`, `step_s`, `fail_at`).
400 on unknown kind. Cacheable kinds short-circuit to a `done` job on a content-addressed
cache hit (key = blake3 of audio hash | kind | canonical params | engine version).

### `GET /jobs` · `GET /jobs/{job_id}`
Job snapshot: `{ id, kind, state, progress, message, eta_s, created_at, started_at,
finished_at, result_ref, error }` with `state ∈ queued | running | cancelled | failed | done`.

### `POST /jobs/{job_id}/cancel`
`{ "cancelled": bool }` — false if the job is already terminal. Cooperative cancellation;
observed latency well under the 2 s budget.

### `GET /jobs/{job_id}/events` (SSE)
Named events `progress | log | done | failed | cancelled`, each with a `data:` JSON job
snapshot (progress events may carry `extra`). A late subscriber to a finished job receives
one terminal event. The stream closes after a terminal event.
