# 0007. Swift 6 language mode + swift-testing
Date: 2026-07-06
Status: accepted
Context: IndraKit must be Linux-buildable for headless verification, concurrency-safe (jobs, caches, SSE streams cross actor boundaries), and testable without Xcode.
Decision: All IndraKit targets use Swift 6 language mode (.swiftLanguageMode(.v6)) with strict Sendable, and swift-testing (import Testing) instead of XCTest. CI and local checks run in the swift:6.2-noble container.
Consequences: Data-race safety enforced at compile time; tests run with swift test --parallel on Linux; Apple-only code is quarantined in IndraKitAppleGlue, excluded from Linux builds.
Alternatives considered: Swift 5 mode (defers concurrency debt), XCTest (legacy; worse Linux ergonomics and parallelism).
