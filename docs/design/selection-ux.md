# Selection, search, overlays, onsets — interaction design

Status: design agreed in chat 2026-07-07; backend for every interaction below is
implemented and CI-tested. This document is the blueprint for the Mac-side views —
written so the UI work is mechanical: every control maps to an endpoint that already
exists (docs/api.md), and every threshold quoted here is the engine's calibrated default.

Audience for the product: electronic musicians, producers, media artists. The visual
language should feel like a **sound-design instrument**, not a photo editor: momentary
audition everywhere, playful-but-precise, everything reversible, nothing modal.

## 1. Selecting — "point at a sound, get the sound"

The unit of selection is not a rectangle; it is a **sound object**: the ribbon set that
magic select returns (per-time-slice frequency intervals that track partials, sweeps,
textures). Rectangles remain available (shift-drag) but are the fallback, not the default.

- **Tap-and-hold on the spectrogram** = seed a magic select (`POST /select/magic`,
  point seed). While held, the ribbon overlay grows out of the cursor; releasing keeps it.
  Vertical drag during the hold adjusts `tolerance_db` live (the job is cheap — it runs on
  the precomputed pyramid, no audio decode — so re-firing per gesture step is fine).
- **Rendering the selection**: not marching ants. Ribbons render as a translucent
  luminous tint over the selected cells with a soft feathered edge (mirroring the
  audition's gaussian feather, so *what you see is what you'll hear*), plus a thin
  outline on the ribbon envelope. Unselected area dims slightly (focus, like stage
  lighting — not checkerboard).
- **Contextual by default**: `adapt="local_median"` selects "what stands out from the
  local background", so a quiet-but-distinct texture is selectable under a level ramp.
  A small toggle (icon: anchor) switches to absolute-dB matching for mastering-type tasks.
- **Instant audition**: space with a live selection plays the feathered isolation
  (`POST /audition {selection_id}`); the result is mask-hash cached so replays are instant.
  Option-space plays the *complement* (everything but the selection) — producers' "what
  breaks if I remove this" move (backend: same ribbons, inverted mask — small TODO).

## 2. After selection — the verbs

A selection is a noun; give it verbs, presented as a compact radial/strip near the
selection (not a menu bar trip):

| Verb | Backend | Notes |
|---|---|---|
| Hear it / hear without it | `POST /audition` selection_id | feather = fade_hz/fade_ms controls |
| Find similar in this file | `POST /select/similar` | seed = selection bounds |
| Find similar across the project | `POST /select/similar {targets:"all", embed:true}` | folder-wide search |
| Keep as annotation | `POST /annotations` (bounds) | undoable |
| Play as sequence | `POST /audition {segments}` | equal-power crossfades, `crossfade_ms` |
| Export stems/regions | Phase 5 render TODO | segments → WAVs |

## 3. Search results — the **constellation view**

Folder-wide search returns segments of varied lengths, shapes, and classes. Two coupled
presentations, both fed by the same job result:

- **In-context markers**: every match draws as a pill on that file's timeline lane
  (stacked mini-timelines, one per scanned file, seed file first). Pill brightness =
  1 − distance. Clicking a pill scrolls that file's spectrogram to the match; holding it
  auditions the segment (segments-mode audition).
- **Constellation (cluster map)**: the `embedding` block gives 2-D coordinates and
  cluster labels per segment. Render as a starfield: each match is a dot (size = duration,
  brightness = closeness, hue = cluster, seed = ringed star at its own position).
  Classes that emerge (all the kicks; all the vinyl crackles; the two weird resonances)
  appear as visually separated groups *without the user defining classes up front*.
  - Lasso a group → becomes a multi-segment selection → same verbs as above (play as
    sequence auditions the whole class, crossfaded — instant "contact sheet for sound").
  - A distance slider re-thresholds the already-returned result client-side (segments
    carry their distances; no re-run needed until the slider exceeds the searched
    threshold).
- Varied lengths are handled by the map (size encodes duration) plus an optional
  length-sorted strip under the map for scanning extremes.

## 4. Feature curves as overlays

Feature tables (roughness, entropy, harmonicity, novelty, onset strength) are already
served with min/max bucket downsampling at any zoom (`GET /files/{id}/features/{kind}`).
Overlay grammar (all drawn by the renderer's lane system, IndraKitCore `CurveLane`):

- **Lane mode** (default): translucent filled min/max band under the spectrogram,
  one lane per active feature, shared time axis. Good for comparison and for dragging
  thresholds.
- **Heat-ribbon mode**: a feature can instead tint the spectrogram itself — a thin strip
  along the top edge (or full-canvas tint at low alpha) colored by the curve value.
  This is the "focus on something else" primer: the user *sees* where roughness lives
  before re-picking onsets by it.
- **Curves are also search modifiers**: `use_features` mixes any computed curve into
  similar-search distance — surfaced in the UI as "match texture + roughness" chips.

## 5. Onsets — shown, tweaked, re-thresholded

Onsets exist in two layers, and the UI must keep them visually distinct:

- **Detected layer** (regenerable, read-only): the current pick from the analysis,
  drawn as slim ticks on the time ruler + stems into the onset-strength lane.
- **Committed layer** (user-owned, undoable): point annotations (label "onset"),
  drawn as full-height hairlines with grab handles.

Interactions:

- **Batch re-threshold (redo)**: a sensitivity slider bound to `POST /onsets/repick`
  (synchronous, milliseconds — safe to fire on every slider tick). The detected layer
  updates live; nothing is destroyed, because detection is regenerable and the committed
  layer is untouched. Window/gap knobs (`wait_s`, `pre/post_avg_s`) live behind a
  disclosure for rhythmic material ("at most one onset per 100 ms").
- **Redo by focusing on something else**: run the pick inside a region only
  (`region` param) — lasso a section, re-threshold just it; or switch the visible
  heat-ribbon to roughness/novelty first to *see* the alternative structure, then re-pick.
- **Commit**: "keep these N onsets" → `POST /onsets/commit` — ONE undo step for the whole
  batch. ⌘Z removes the batch; redo restores it.
- **Fine tweaks**: committed onsets are annotations — drag = `PATCH` (move), delete key =
  `DELETE`, each individually undoable through the existing history.
- Strengths ride along in the annotation note, so committed onsets can still be
  brightness-scaled in the UI.

## 6. What stays Mac-side (queued in SMOKE_TESTS.md)

Everything above is API-complete and covered by backend tests (`test_select*.py`,
`test_onset_repick.py`). The Mac-side work is pure presentation: the ribbon/pill/
constellation drawing, gesture wiring, and the two-layer onset lanes. The Metal renderer
(ADR 0013) provides the canvas these overlays draw on.

Deliberately NOT built yet: complement ("hear without it") audition mask inversion,
cross-project (multi-.indra) search, learned embeddings (current embedding is the
matching profile itself — honest, fast, and explainable; revisit only if clustering
quality disappoints on real material).
