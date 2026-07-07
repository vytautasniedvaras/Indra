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

### `POST /audition` (Phase 4, §5.5, ADR 0008)
Exactly one of three modes (400 otherwise) → `{ "job_id" }`:

- `{ "audio_id", "mask": { t0, t1, f0?, f1?, fade_hz?, fade_ms? } }` — rectangle: STFT →
  raised-cosine band mask → ISTFT, time-edge fades.
- `{ "audio_id", "selection_id", "fade_hz"?, "fade_ms"? }` — magic selection: rebuilds the
  ribbon mask on the audition STFT grid, gaussian-feathered in both axes (feather width from
  `fade_hz` / `fade_ms`), renders the selection in isolation.
- `{ "audio_id", "segments": [[t0,t1],…], "crossfade_ms"? }` — segmented playback: extracts
  joined with equal-power raised-cosine crossfades at every joint (no clicks).

Job `result_ref` = `{ audition_id, wav_path (relative to project root), sr, channels,
duration_s, … }`. Params-hash cached (identical request → instant `done` with the same
`audition_id`). Renders capped at 600 s total.

### `POST /select/magic` (Phase 4, §5)
`{ "audio_id", "seed": { t?, f? | t0?, t1?, f0?, f1? }, "tolerance_db"?: 8, "contiguous"?:
true, "adapt"?: "local_median" | "none", "max_extent_s"?: 120 }` → `{ "job_id" }`.
Magic-wand region grow on the precomputed dB pyramid, seeded by a point (grown from a small
neighborhood) or a box. `adapt: "local_median"` matches level *relative to each time slice's
median* (contextual: selection survives whole-mix level ramps); `"none"` matches absolute dB.
`contiguous: false` selects all matching cells in the window. Result `result_ref` =
`{ selection_id, ribbons: [{ t0, t1, intervals: [[f_lo, f_hi],…] },…], lod,
seconds_per_column, hz_per_bin, cells, seed_level_db, bounds }`. The `selection_id` is the
cache key — pass it straight to `POST /audition` to hear the selection, feathered.

### `POST /select/similar` (Phase 4, §5)
`{ "audio_id", "seed": { t0, t1 }, "threshold"?: 0.4, "min_segment_s"?: 0.5,
"use_features"?: ["roughness_mpt", …], "targets"?: "all" | [audio_id,…], "embed"?: false }`
→ `{ "job_id" }`. Finds time regions that sound like the seed: 24 fixed-Hz log-band energy
profiles (40 Hz–16 kHz, per-band median-over-time baseline removed, ~0.25 s smoothed,
unit-normalized), cosine distance to the NEAREST of ~6 seed exemplars (the mean plus evenly
spaced columns of the seed window — evolving seeds match phase-by-phase instead of being
smeared into one average). Distance is 0 for a perfect match; the default threshold 0.4
catches steady and evolving textures.

- Single-file (no `targets`): result `{ segments: [{ t0, t1, distance },…], threshold,
  features_used }`; `use_features` mixes already-computed feature curves into the distance.
- **Folder-wide** (`targets: "all"` or a list): scans every listed import with the same
  seed — fixed-Hz bands + per-file baseline removal make profiles comparable across
  different sample rates, levels, and noise floors. Result `{ segments: [{ audio_id, t0,
  t1, distance },…] (sorted best-first), scanned: [audio_id,…], threshold }`.
- `embed: true` (with `targets`) attaches `embedding: { xy: [[x,y],…], cluster: [int,…],
  n_clusters }` — 2-D PCA coordinates plus average-linkage cosine clusters (cut at 0.4, the
  search-threshold scale) per segment, in segment order: everything a cluster-map view
  needs for the varied classes that come back.

### `POST /onsets/repick` (synchronous)
`{ "audio_id", "key"?, "delta"?, "wait_s"?, "pre_max_s"?, "post_max_s"?, "pre_avg_s"?,
"post_avg_s"?, "region"?: { t0, t1 } }` → onsets directly (no job). **Batch
re-thresholding**: re-runs only the millisecond-scale peak pick on the SAVED
onset-strength envelope (latest `onsets_superflux_pcen` or the one named by `key`) — the
expensive PCEN/SuperFlux stage is never recomputed, so this can drive a live sensitivity
slider. With no overrides it reproduces the original detection exactly. `delta` is on the
[0,1]-normalized envelope (comparable across files); `region` re-picks only inside a window
(local redo). Response `{ audio_id, source_key, params, n, onsets: { t: […], strength: […] } }`.

### `POST /onsets/commit` (synchronous)
`{ "audio_id", "times": […], "strengths"?: […], "label"?: "onset" }` → creates one point
annotation (t0 == t1) per onset in a SINGLE undoable action (`POST /undo` removes the whole
batch; annotations PATCH/DELETE then give per-onset fine tweaking — move, delete — with the
normal undo). Response `{ created, annotations: […] }`.

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
