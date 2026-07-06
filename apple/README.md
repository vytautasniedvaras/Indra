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

## The app (Phase 3+)

`IndraApp.xcodeproj` will land with the Phase 3 milestone (annotation table + debug canvas)
and grow through Phase 4 (Metal renderer, playback, audition). Open it in Xcode and ⌘R;
it discovers a running backend via the session file, or spawns one.
