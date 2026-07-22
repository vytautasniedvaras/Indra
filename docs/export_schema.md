# Indra export schema

Stable, versioned contract for driving external visual/generative/algorithmic systems
(BUILD_SPEC §6.6). Breaking changes bump `schema_version` and require user sign-off once a
version has shipped (§10.5).

**Current `schema_version`: 1**

## `POST /export` request

```json
{ "audio_id": "<blake3 hex>", "kinds": ["roughness_mpt", "onsets_superflux_pcen"],
  "format": "json" | "csv", "region": { "t0": 0.0, "t1": 120.0 } | null }
```

`kinds` selects which computed features to embed (the most recent variant of each; 404 with a
clear message if a kind was never computed — run `POST /analyze` first). `region` slices
features and onsets to `[t0, t1]` and keeps annotations that overlap it. `kinds: []` exports
annotations only.

## JSON format (`format: "json"`, one document, Content-Disposition attachment)

```json
{
  "schema_version": 1,
  "engine_version": "indra-engine 0.1.0",
  "audio_id": "…",
  "audio": { "sr": 44100, "duration_s": 3600.0, "channels": 2, "frames": 158760000,
             "format": "WAV/PCM_16" },
  "region": { "t0": 0.0, "t1": 120.0 } | null,
  "annotations": [
    { "id": 1, "audio_id": "…", "t0": 12.5, "t1": 31.0, "f0": 100.0, "f1": 4000.0,
      "label": "wash", "note": "…", "created_at": "…", "updated_at": "…" }
  ],
  "onsets": [ { "t": 12.503, "strength": 4.21 } ],
  "features": {
    "roughness_mpt": {
      "params": { "...as computed..." },
      "sr": 44100,
      "time_s": [0.0, 0.0232, …],
      "value": [0.0, 312.5, …]
    },
    "template_harmonicity_mpt": { "…": "…", "value": ["h_max"], "h_entropy": [ … ] },
    "foote_novelty_multiscale": { "…": "…", "novelty_8s": [ … ], "novelty_32s": [ … ] }
  }
}
```

- Every feature carries its own `time_s` axis (features may use different hops).
- `onsets` is populated when `onsets_superflux_pcen` is among the kinds; its feature entry
  additionally contains the full strength envelope (`value`) and an `is_onset` 0/1 column.
- Curve semantics: `roughness_mpt.value` — Sethares/Plomp-Levelt roughness (linear-amplitude
  weighted); `spectral_entropy_mpt.value` — raw Shannon entropy in bits of the Gaussian-smoothed
  cents density (lower = more consonant); `template_harmonicity_mpt.value` — h_max ∈ [0, 1]
  (Milne 2013), `h_entropy` — cross-correlation entropy (Harrison & Pearce 2020).

## CSV format (`format: "csv"`, a zip archive)

| file | contents |
|---|---|
| `features.csv` | one row per frame of the **densest** exported feature's time grid; column 0 `time_s`; one column per feature value, named `<kind>.<column>` (e.g. `roughness_mpt.value`). Features on coarser grids are aligned by nearest-neighbor. |
| `annotations.csv` | `id, audio_id, t0, t1, f0, f1, label, note` |
| `onsets.csv` | `t, strength` |
| `manifest.json` | schema_version, engine_version, audio metadata, region |
