# Indra — Apple targets

Two source trees (BUILD_SPEC §5.1):

- `IndraKit/` — pure-Swift package (models, API client, SSE parser, editor state, undo,
  tile cache). Builds and tests on Linux; CI runs it in `swift:6.2-noble` on every push.
- `IndraApp/` — the Xcode app (SwiftUI shell + Metal canvas). **Built locally by you**;
  it cannot be verified in the headless cloud environment. (Arrives in Phase 3/4.)

## Requirements

- Xcode 16.2 or newer (macOS 14/15/16)
- Swift 6.0+ toolchain (bundled with Xcode)
- Python 3.12 or 3.13
- [uv](https://github.com/astral-sh/uv) (or pip)

## One-time setup

```sh
cd backend
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
pytest -q        # sanity: all green expected
```

## Run the backend

```sh
python -m indra.server --port 0 --project ~/Music/Indra/scratch.indra
```

The chosen port and bearer token are written to
`~/Library/Application Support/Indra/session.json`.

## Quick check without the app

```sh
curl -s http://127.0.0.1:$PORT/health          # {"status":"ok"}
open ../dev/api_probe.html                     # throwaway tile viewer (paste port+token)
```

## IndraKit tests (what CI runs)

```sh
cd apple/IndraKit
swift test --parallel        # on macOS, or in docker swift:6.2-noble on Linux
```

## The app — debug harness (Phase 4 scaffold)

`IndraApp/` is a **SwiftPM package with an executable target**, not an `.xcodeproj` —
Xcode 16 opens `Package.swift` directly and ⌘R runs the `@main` SwiftUI app.

Open and run:

1. Backend setup is unchanged (sections above). You do **not** need to start the
   backend by hand — the app spawns it if none is running. One-time: launch the app,
   open Settings (⌘,), and set “Backend Python” to your venv interpreter, e.g.
   `<repo>/apple/../backend/.venv/bin/python` (a bare system Python lacks the `indra`
   package and the spawn will fail with a clear error + Retry button).
2. `open apple/IndraApp/Package.swift` in Xcode 16.2+ (or File ▸ Open… the
   `apple/IndraApp` folder).
3. Select the **IndraApp** scheme, destination **My Mac**, then **⌘R**.

On launch the app looks for a running backend via
`~/Library/Application Support/Indra/session.json`; if absent it spawns
`python -m indra.server --project ~/Music/Indra/scratch.indra --port 0` and polls
for the handshake file.

What's in the harness today: file import + list, a CPU-drawn waveform/spectrogram
debug canvas, annotation table with ⌘Z/⇧⌘Z undo/redo (backed by the server's
history), the five analysis kinds with live SSE progress bars + per-job cancel,
JSON export via a save panel, and AVAudioEngine playback of the original file with
click-to-seek and 0.25–4× time-pitch. **This is the debug harness, not the final
UI — the Metal tile canvas (BUILD_SPEC §5.3) lands next.**

Nothing under `IndraApp/Sources` is CI-verifiable (SwiftUI/AVFoundation need
macOS); it is user-smoke-tested only — see `docs/plan/SMOKE_TESTS.md` (Phase 4).
On Linux the target compiles to a stub executable so `swift build` remains a
structural check.
