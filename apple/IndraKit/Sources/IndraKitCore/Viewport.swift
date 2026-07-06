// Visible window over a file: time (s) × frequency (Hz) × canvas pixels
// (BUILD_SPEC §5.3). NOT part of EditorState — zoom/pan are never undoable
// (ADR 0009); the viewport lives in separate scene state.

import Foundation

/// Frequency-axis display scaling (BUILD_SPEC §5.3, frequency-axis LUT).
public enum FrequencyScale: String, Codable, Sendable, CaseIterable {
    case linear, logarithmic
}

/// Value-type viewport. All transforms are non-mutating and return a new
/// viewport, matching the reducer style elsewhere in IndraKitCore.
///
/// Screen conventions: x grows rightward with time (x = 0 at `t0`), y grows
/// downward with y = 0 at `f1` (high frequencies on top).
public struct Viewport: Sendable, Equatable {
    /// Visible time range, seconds. Invariant: `t0 <= t1`.
    public var t0: Double
    public var t1: Double
    /// Visible frequency range, Hz. Invariant: `f0 <= f1`.
    public var f0: Double
    public var f1: Double
    /// Canvas size in pixels. Invariant: `>= 1` (clamped at init).
    public var width: Double
    public var height: Double

    /// Smallest zoomable time span, seconds.
    public static let minTimeSpan = 0.001
    /// Smallest zoomable frequency span, Hz.
    public static let minFrequencySpan = 1.0
    /// Floor for logarithmic frequency mapping (log(0) guard).
    public static let logFrequencyFloor = 20.0

    public init(t0: Double, t1: Double, f0: Double, f1: Double, width: Double, height: Double) {
        self.t0 = min(t0, t1)
        self.t1 = max(t0, t1)
        self.f0 = min(f0, f1)
        self.f1 = max(f0, f1)
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    public var timeSpan: Double { t1 - t0 }
    public var frequencySpan: Double { f1 - f0 }

    // MARK: - Time-axis pan/zoom

    /// Zoom the time axis by `factor` (> 1 zooms in), keeping `anchorT` fixed
    /// at the same screen x. Result is clamped to `[0, duration]` and to
    /// `minTimeSpan`.
    public func zoomedTime(by factor: Double, anchorT: Double, duration: Double) -> Viewport {
        guard factor > 0, duration > 0 else { return self }
        let span = timeSpan
        let newSpan = min(max(span / factor, Self.minTimeSpan), duration)
        let u = span > 0 ? (anchorT - t0) / span : 0.5
        var newT0 = anchorT - u * newSpan
        newT0 = min(max(newT0, 0), duration - newSpan)
        var next = self
        next.t0 = newT0
        next.t1 = newT0 + newSpan
        return next
    }

    /// Pan the time axis by `seconds` (positive = later), clamped so the
    /// visible range stays inside `[0, duration]`. Span is preserved (unless
    /// it exceeds `duration`, in which case the view pins to `[0, duration]`).
    public func pannedTime(bySeconds seconds: Double, duration: Double) -> Viewport {
        guard duration > 0 else { return self }
        let span = min(timeSpan, duration)
        var newT0 = t0 + seconds
        newT0 = min(max(newT0, 0), duration - span)
        var next = self
        next.t0 = newT0
        next.t1 = newT0 + span
        return next
    }

    // MARK: - Frequency-axis pan/zoom

    /// Zoom the frequency axis by `factor` (> 1 zooms in), keeping `anchorF`
    /// fixed at the same screen y. Clamped to `[0, maxFrequency]` with a
    /// `minFrequencySpan` guard.
    public func zoomedFrequency(by factor: Double, anchorF: Double, maxFrequency: Double) -> Viewport {
        guard factor > 0, maxFrequency > 0 else { return self }
        let span = frequencySpan
        let newSpan = min(max(span / factor, Self.minFrequencySpan), maxFrequency)
        let u = span > 0 ? (anchorF - f0) / span : 0.5
        var newF0 = anchorF - u * newSpan
        newF0 = min(max(newF0, 0), maxFrequency - newSpan)
        var next = self
        next.f0 = newF0
        next.f1 = newF0 + newSpan
        return next
    }

    /// Pan the frequency axis by `hz` (positive = up in frequency), clamped
    /// so the visible range stays inside `[0, maxFrequency]`.
    public func pannedFrequency(byHz hz: Double, maxFrequency: Double) -> Viewport {
        guard maxFrequency > 0 else { return self }
        let span = min(frequencySpan, maxFrequency)
        var newF0 = f0 + hz
        newF0 = min(max(newF0, 0), maxFrequency - span)
        var next = self
        next.f0 = newF0
        next.f1 = newF0 + span
        return next
    }

    // MARK: - Coordinate mapping

    /// Screen x (pixels, 0 at `t0`) for a time in seconds. Out-of-range times
    /// map off-screen (no clamping).
    public func timeToX(_ t: Double) -> Double {
        let span = timeSpan
        guard span > 0 else { return 0 }
        return (t - t0) / span * width
    }

    /// Time in seconds for a screen x in pixels.
    public func xToTime(_ x: Double) -> Double {
        t0 + x / width * timeSpan
    }

    /// Screen y (pixels, 0 at `f1`, `height` at `f0`) for a frequency in Hz.
    /// For `.logarithmic` the visible range is floored at `logFrequencyFloor`
    /// (frequencies below the floor collapse to the bottom edge).
    public func freqToY(_ f: Double, scale: FrequencyScale = .linear) -> Double {
        switch scale {
        case .linear:
            let span = frequencySpan
            guard span > 0 else { return height / 2 }
            return (1 - (f - f0) / span) * height
        case .logarithmic:
            let (lo, hi) = logRange
            let clamped = max(f, Self.logFrequencyFloor)
            return (1 - log(clamped / lo) / log(hi / lo)) * height
        }
    }

    /// Frequency in Hz for a screen y in pixels (inverse of `freqToY`).
    public func yToFreq(_ y: Double, scale: FrequencyScale = .linear) -> Double {
        switch scale {
        case .linear:
            return f0 + (1 - y / height) * frequencySpan
        case .logarithmic:
            let (lo, hi) = logRange
            return lo * pow(hi / lo, 1 - y / height)
        }
    }

    /// Effective (low, high) edges for log mapping: floored at
    /// `logFrequencyFloor` and guaranteed non-degenerate.
    private var logRange: (Double, Double) {
        let lo = max(f0, Self.logFrequencyFloor)
        let hi = max(f1, lo * 1.000001)
        return (lo, hi)
    }
}
