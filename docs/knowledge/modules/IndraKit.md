---
title: IndraKit
type: module
tags:
- swift
- frontend
permalink: indra/modules/indra-kit
---

Swift package (`apple/IndraKit/`): platform-independent Core (models, EditorState
reducer, undo mirror, Viewport/TilePlanner/Colormaps/CurveLane render math, TileCache)
+ Net (APIClient, byte-level SSE parser). Swift 6 strict concurrency.

- [design] Everything testable WITHOUT a Mac lives here; Linux CI runs the full test suite #testing
- [design] Wire contract: backend snake_case ⇄ Swift camelCase via `IndraJSON` (convertFromSnakeCase)
- [gotcha] CRLF is ONE `Character` in Swift Strings — the SSE parser works on bytes, never on String
- [gotcha] `NSLock.lock()` is banned in async contexts — use the `Locked<T>` withLock helper (HTTPTransport.swift)

## Relations

- depends_on [[Job System]]
- constrained_by [[CI As Swift Verifier]]
- documented_in [[Architecture Guide]]