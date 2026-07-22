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
- [design] Failure feedback loop: raw Actions logs live on Azure blob storage the dev container CANNOT reach. `scripts/annotate-swift.sh` wraps every swift step to (a) mirror compiler errors as ::error annotations (readable via the check-runs API) and (b) tee output to /tmp/swift-ci.log, which an `if: failure()` step force-pushes to the `ci-logs-linux` / `ci-logs-macos` branches — read them with `git fetch origin ci-logs-linux && git show FETCH_HEAD:linux-<sha7>.log`
- [gotcha] The local GITHUB_TOKEN proxy only permits writes to the dev branch — utility branches must be created BY the workflow's own runner token, never locally

## Relations

- documented_in [[Architecture Guide]]