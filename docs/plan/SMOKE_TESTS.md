# Indra — Pending local smoke tests (for the user's Mac)

Accumulating queue of things only verifiable on real Apple hardware. Development never blocks
on these; run them whenever convenient and report results (a GitHub issue comment or a session
message is fine). Items are grouped by phase and removed once confirmed.

## Phase 4 — IndraApp debug harness (new)

6. Open `apple/IndraApp/Package.swift` in Xcode 16.2+, select the **IndraApp** scheme,
   destination **My Mac**, ⌘R. First run: Settings (⌘,) → set “Backend Python” to
   `<repo>/backend/.venv/bin/python`, then Retry in the main window. Verify, in order:
   - **Backend spawn/discover**: app connects (sidebar footer shows `Backend: 127.0.0.1:<port>`);
     if a server was already running it reuses it instead of spawning.
   - **Import**: Import… → pick a WAV → progress bar appears in Analyses panel; on done the
     file shows in the sidebar. Waveform peaks + grayscale spectrogram render in the debug canvas.
   - **Playback**: play/pause (space), click the waveform to seek (red playhead follows),
     rate slider 0.25–4× changes speed without pitch change; long files play gaplessly
     past the 5 s segment boundaries.
   - **Analyses**: press each of the five buttons (Roughness, Spectral entropy, Harmonicity,
     Onsets, Foote novelty) → per-job progress bars; Cancel aborts within ~2 s (state →
     cancelled); re-running a finished kind returns done ~instantly (cache hit).
   - **Annotations**: add via t0/t1/label fields; ⌘Z removes it, ⇧⌘Z restores it (check
     `GET /history` shows the undo); press “Reload from server”, then edit a note (Enter)
     and delete a row — both must survive an app restart (server-persisted). Known harness
     limits: note edits on rows marked “unsynced” don't reach the server until Reload;
     Reload clears local undo history.
   - **Export**: Export JSON… → save → file parses and matches docs/export_schema.md
     (annotations + all computed feature kinds present).
   Nothing here is CI-verifiable (SwiftUI/AVFoundation/macOS-only); on Linux the target
   builds as a stub executable only.

## Phase 4 — Metal spectrogram renderer (ADR 0013)

7. With the app running and a file imported (see item 6), on the file detail view:
   - **Default canvas**: the Metal canvas is the default; spectrogram renders in viridis.
     The Canvas segmented control swaps to the CPU debug canvas and back; the two images
     agree (grayscale vs viridis aside).
   - **Pan/zoom**: two-finger scroll pans time (x) and frequency (y); pinch zooms time
     anchored under the cursor; ⌥-pinch zooms frequency; “Fit” restores the full view.
     Zooming across a LOD boundary shows a brief (~100 ms) cross-fade, not a hard pop;
     while fine tiles load, a stretched coarse image shows instead of black.
   - **Colormap/scale**: switching colormaps is instant (no tile refetch — backend logs
     stay quiet); Log scale visibly expands low frequencies; HUD shows visible time range
     and current LOD.
   - **Selection**: drag draws a box that survives pan/zoom at the correct time/frequency
     position; one drag = ONE ⌘Z step; click (no drag) seeks the playhead.
   - **Magic select**: drag a box around a partial/noise band → “Magic select” → orange
     ribbons hug the energy region; ⌥-click on a harmonic does the same from a point seed;
     “Clear ribbons” removes them (watch the `magic_select` job in /jobs).
   - **Curve lanes**: run Roughness + Onsets, enable them under “Lanes” → min/max envelopes
     at the canvas bottom, re-windowing on pan/zoom (~150 ms debounce); lane toggles are
     undoable (lens state).
   - **Memory**: on a 1-hour file, sustained pan/zoom keeps Metal texture memory roughly
     flat (~130–200 MB, Xcode memory gauge) — the atlas LRU is working.
   - **Onset lane** (run the Onsets analysis first): “Show onsets” → yellow ticks with
     strength-scaled stems along the top edge. Drag the Sensitivity slider — the tick set
     updates live (each position is a millisecond re-pick of the saved envelope; watch the
     count change, lower = more). “Commit N onsets” → mint full-height hairlines appear
     (they are now point annotations; check the annotations table) and stay put while the
     slider keeps changing the yellow layer. The commit is ONE server undo step —
     `POST /undo` (or the History list) removes the whole batch.
   - **Find similar / constellation** (needs ≥2 imported files): drag a time selection
     around a distinctive sound → “Find similar”. A starfield appears (dot size =
     duration, color = cluster, brightness = closeness) beside per-file match pills.
     Clicking any dot or pill renders and plays that segment — including matches in the
     OTHER file. Repeats of the same sound should share one color; unrelated matches (if
     any) get different colors. “Clear matches” removes the panel. A white ringed star
     marks the seed among its matches; the Distance slider thins the field live without
     re-searching. **Lasso**: drag a loop around several dots — they highlight and a
     “Play N as sequence” button appears (crossfaded contact sheet; per-file render, the
     majority file wins and the status names skipped ones).
   - **Audition** (§5.5): drag a box (or magic-select) → “Audition”. Immediately the main
     playback (if playing) narrows to the band — that's the EQ quick preview; transport
     shows “EQ preview engaged (render pending)”. Within a couple of seconds the exact
     render takes over: transport shows “Audition render playing”, and only the selected
     time-frequency content is audible with soft feathered edges. Stop halts it; repeating
     the same audition starts instantly (server cache). ⌥-select a harmonic ribbon and
     audition it — you should hear that partial alone, tracking its movement.

## Phase 3 (optional)

5. Full data path on one of YOUR pieces: import a real recording via curl, run analyses
   (`POST /analyze` kinds: roughness_mpt, spectral_entropy_mpt, template_harmonicity_mpt,
   onsets_superflux_pcen, foote_novelty_multiscale), add an annotation, ⌘-equivalent undo via
   `POST /undo`, then `POST /export` → check the JSON drives your visual pipeline.
   (Verified headlessly on a synthetic 1-hour noisescape: import 46 s, analyses 250 s wall,
   export 58 MB in 5 s, backend RSS 221 MB.)

## Phase 0/1 (optional, low priority — everything below is also covered by CI/local tests)

1. `cd backend && uv venv && source .venv/bin/activate && uv pip install -e ".[dev]" && pytest -q`
   → expect all green on macOS (validates soundfile/av wheels on Apple Silicon).
2. `python -m indra.server --project /tmp/scratch.indra --port 0` → note port; `curl -s
   http://127.0.0.1:$PORT/health` → `{"status":"ok"}`.
3. Import a real WAV of yours via curl (token in `~/Library/Application Support/Indra/
   session.json`), then open `dev/api_probe.html`, paste port + token, press "probe" →
   waveform + spectrogram render.
4. `cd apple/IndraKit && swift test --parallel` with Xcode 16.2+ → 47 tests green on macOS
   (CI only proves Linux).
