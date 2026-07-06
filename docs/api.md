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
buckets } ], spec: {...} | null, features: [] }`. Waveform pyramid: 8 LODs, base bucket 256
samples, int16 min/max per (bucket, channel). `spec` (present once ingested):
`{ n_fft: 4096, hop: 1024, window: "blackmanharris7", n_bins: 2049, db_min: -100, db_max: 0,
mono_downmix: true, lods: [ { lod, frames, frames_per_column } ] }`.

### `GET /files/{audio_id}/waveform/tile?lod=&start=&count=` (binary)
`application/octet-stream`, little-endian int16, C-order `(count, channels, 2)` with the last
axis (min, max). Headers: `X-Indra-Tile-Shape: count,channels,2`, `X-Indra-Tile-Dtype: int16`,
`X-Indra-Tile-Bounds: start,end`. Ranges clamp to available buckets; 400 on bad lod.

### `GET /files/{audio_id}/spec/tile?lod=&t0=&t1=&f0=&f1=` (binary)
uint8 dB slab, C-order `(frames, bins)`; t0/t1 are frame indices at the requested LOD,
f0/f1 bin indices (defaults: full range). Mapping: 0..255 ⇔ -100..0 dB, 0 dB = full-scale
sine. Headers: `X-Indra-Tile-Shape: frames,bins`, `X-Indra-Tile-Dtype: uint8`,
`X-Indra-Tile-Bounds: t0,t1,f0,f1`. Ranges clamp; requests over 8 MiB are rejected (400).

### `POST /analyze`
Body `{ "kind": str, "audio_id": str = "", "params": {}, "region": { t0?, t1?, f0?, f1? } | null }`
→ `{ "job_id": str }`. 400 on unknown kind; analysis kinds require `audio_id`. Cacheable kinds
short-circuit to a `done` job on a content-addressed cache hit (key = blake3 of audio hash |
kind | canonical params | engine version); `region` participates in the key.

Analysis kinds (Phase 2), all cancellable + cached, results as Parquet feature tables:

| kind | params (defaults) | result value column(s) |
|---|---|---|
| `roughness_mpt` | n_fft 4096, hop 1024, top_k 64, min_prominence (rel 0.05), p_norm 1, average false | `value` |
| `spectral_entropy_mpt` | …, top_k 32, sigma_cents 10, resolution 3 (cents/grid pt), raw Shannon bits | `value` |
| `template_harmonicity_mpt` | …, hop 2048, top_k 32, sigma_cents 10, resolution 3 | `value` (h_max), `h_entropy` |
| `onsets_superflux_pcen` | n_fft 1024, hop sr/200, n_mels 138, fmin 27.5, fmax 16000 | `value` (envelope), `is_onset`; result_ref carries `onsets {t, strength}` |
| `foote_novelty_multiscale` | feature mfcc\|chroma, scales_s [8,32,128], hop 2048 | `novelty_<scale>s` per scale |

`debug_slow` remains as the test/probe job.

### `GET /files/{audio_id}/features/{kind}?t0=&t1=&downsample=&key=`
Serves a computed feature table. `key` selects a specific cached variant (from the job's
`result_ref.cache_key`); otherwise the most recently computed variant of that kind. Raw values
(`values: { time_s, <column>… }`) are capped at 20 000 points — pass `downsample=<buckets>`
for min/max buckets per column (`buckets: { <column>: { t, min, max } }`) at display width
(§4.4). 404 if never computed or evicted.

### Annotations (Phase 3; all mutations undoable)
- `POST /annotations` — `{ audio_id, t0, t1, f0?, f1?, label?, note? }` → full record
  `{ id, audio_id, t0, t1, f0, f1, label, note, created_at, updated_at }`. 400 if t1 < t0.
- `GET /annotations?audio_id=…` — records ordered by t0.
- `PATCH /annotations/{id}` — partial body of the mutable fields → updated record.
- `DELETE /annotations/{id}` — `{ "deleted": true }`.

### `POST /undo` · `POST /redo` · `GET /history` (Phase 3, §7)
Undo/redo return `{ applied_patch: [RFC-6902 ops], scope, action_name, undo_stack_depth,
redo_stack_depth }`; 409 `nothing_to_undo` / `nothing_to_redo` on empty stacks. Any new
forward action invalidates the redo branch. `GET /history` → last 100
`{ id, ts, scope, action_name }` ("Undo Add annotation" menu naming).

### `POST /export` (Phase 3, §6.6)
`{ audio_id, kinds: [feature kinds], format: "json" | "csv", region? }` → attachment
(JSON document or zip of features.csv/annotations.csv/onsets.csv/manifest.json).
Schema documented and versioned in docs/export_schema.md (schema_version 1).

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
