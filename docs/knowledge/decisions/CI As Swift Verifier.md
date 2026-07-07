---
title: CI As Swift Verifier
type: decision
tags:
- swift
- ci
permalink: indra/decisions/ci-as-swift-verifier
---

No local Swift toolchain is obtainable in the dev container (Docker Hub/ECR, swift.org,
GitHub release assets all blocked by network policy) — so GitHub Actions IS the Swift
verifier. Linux job: IndraKit tests + Linux app stub. macOS job (`macos.yml`): compiles
the REAL app (SwiftUI/Metal/AVFoundation) — runs only on `apple/**` changes because
macOS runners bill 10× minutes.

- [gotcha] Don't spend effort trying to install Swift locally again — the full failure list is in STATUS.md history

## Relations

- documented_in [[Architecture Guide]]