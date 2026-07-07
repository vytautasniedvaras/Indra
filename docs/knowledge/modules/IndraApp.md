---
title: IndraApp
type: module
tags:
- swift
- frontend
- macos
permalink: indra/modules/indra-app
---

The macOS app (`apple/IndraApp/`) — a SwiftPM executable, not an Xcode project
(ADR 0012). Backend spawn/discovery, import, debug canvas, annotations, analyses,
playback, export. Metal renderer in progress (ADR 0013).

- [design] macOS-only code is gated `#if os(macOS) && canImport(SwiftUI)` with a Linux stub so `swift build` passes everywhere
- [design] Verification: Linux CI builds the stub structurally; the macOS CI job compiles the REAL app (SwiftUI/Metal/AVFoundation) on `apple/**` changes
- [status] Awaiting first Mac smoke test (queue: docs/plan/SMOKE_TESTS.md)

## Relations

- depends_on [[IndraKit]]
- decided_by [[SwiftPM App Decision]]
- constrained_by [[CI As Swift Verifier]]