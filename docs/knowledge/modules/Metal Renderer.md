---
title: Metal Renderer
type: module
tags:
- swift
- macos
- rendering
permalink: indra/modules/metal-renderer
---

The spectrogram canvas (ADR 0013): `SpectroRenderer/SpectroCanvasModel/
SpectroCanvasView/SpectrogramPane` in IndraApp + CI-tested math in IndraKitCore
(`SpecAtlas`, `SpecRenderPlan`, `FrequencyLUT`, `MagicSelection`, `FeatureTable`).

- [design] Full-height tile slabs in a texture2d_array atlas; colormap AND linear/log frequency remap applied in-shader via LUT textures — colormap/scale switches never refetch tiles
- [design] Runtime-compiled MSL from a Swift string (SwiftPM executables can't bundle .metal reliably); overlays are a SwiftUI Canvas layer sharing the same Viewport value
- [design] LOD cross-fade (~100 ms) + coarser-LOD placeholder stretch while tiles load
- [gotcha] `LodFade.isComplete` defers to `alpha()` — Double elapsed-time math can land a hair under the duration at the boundary
- [gotcha] `MagicSelection(resultRef:)` accepts snake_case AND camelCase keys: convertFromSnakeCase rewrites dictionary keys on some decode paths (Foundation quirk), not others

## Relations

- depends_on [[IndraKit]]
- implements [[Selection UX Design]]
- constrained_by [[dB Pyramid Contract]]
- constrained_by [[CI As Swift Verifier]]
- documented_in [[Architecture Guide]]