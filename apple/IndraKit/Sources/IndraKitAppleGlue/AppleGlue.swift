// Apple-only bridges (SwiftUI colors, AVAudioPCMBuffer conversions, …).
// Everything in this target is #if-gated: on Linux it compiles to nothing so
// `swift test` can build the whole package (BUILD_SPEC §5.1).

#if canImport(SwiftUI)
    import IndraKitCore
    import SwiftUI

    extension Selection {
        /// Convenience for overlay drawing: the time span as a ClosedRange.
        public var timeRange: ClosedRange<Double> { t0...t1 }
    }
#endif
