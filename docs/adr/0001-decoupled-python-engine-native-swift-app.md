# 0001. Decoupled Python engine + native Swift app
Date: 2026-07-06
Status: accepted
Context: Indra needs heavy audio analysis (librosa, MPT, torch/MPS) and a fluid native macOS/iPadOS UI. A single-runtime approach (PyObjC, Swift-only DSP, or an Electron/web UI) either sacrifices the analysis ecosystem or the UI quality. The build environment is headless Linux; only a Python backend and pure-Swift packages are verifiable there.
Decision: Two local processes: a Python analysis engine exposing FastAPI over HTTP+SSE on 127.0.0.1, and a native Swift app (SwiftUI shell + Metal canvas) consuming it. The backend is spawnable by the app or standalone.
Consequences: Clean testability split (pytest headless; Swift app user-verified), a wire contract to maintain (docs/api.md), process-lifecycle management in the app, and loopback security handled via bearer token (ADR context in BUILD_SPEC §4.1).
Alternatives considered: PyObjC embedding (fragile, GIL vs UI), Swift-native DSP (loses librosa/MPT), web UI (explicitly rejected as product surface).
