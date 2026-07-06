# 0002. SwiftUI shell + NSViewRepresentable-hosted MTKView
Date: 2026-07-06
Status: accepted
Context: The main canvas must stream a multi-hour spectrogram at 60–120 Hz with pan/zoom, overlays, and gestures. SwiftUI Canvas is CG-immediate-mode and cannot sustain this; CATiledLayer is legacy and crash-prone under SwiftUI hosting.
Decision: SwiftUI owns chrome (sidebar, inspector, transport, job list). The canvas is a subclassed MTKView hosted via NSViewRepresentable (UIViewRepresentable on iPad), owning gesture handling through NSResponder overrides.
Consequences: Two UI idioms in one app; gesture code is AppKit/UIKit-specific; Metal renderer is not headlessly verifiable — user smoke-tests it.
Alternatives considered: SwiftUI Canvas (too slow), CATiledLayer (rejected outright per spec §5.3), full AppKit app (loses SwiftUI productivity for chrome).
