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
