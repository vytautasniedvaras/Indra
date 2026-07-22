---
title: SwiftPM App Decision
type: decision
tags:
- swift
- build
permalink: indra/decisions/swift-pm-app-decision
---

IndraApp is a SwiftPM executable package, not an Xcode project (ADR 0012): buildable
and structurally checkable from Linux CI, diffable, no `.xcodeproj` churn. The cost:
app bundling (icon, entitlements, notarization) is deferred to a later packaging step.

## Relations

- decided_by [[CI As Swift Verifier]]
- documented_in [[Architecture Guide]]