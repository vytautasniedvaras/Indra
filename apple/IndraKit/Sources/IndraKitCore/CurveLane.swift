// Min/max curve-lane downsampling for analysis-curve rendering
// (BUILD_SPEC §5.3 overlays, §5.4): collapse a feature curve to one
// (min, max) pair per visible pixel column — the client-side mirror of the
// backend's minmax_buckets (§4.4) — so lanes stay in perfect sync with
// pan/zoom and never draw more vertices than pixels.

/// Per-pixel-column vertical extent of a curve.
public struct CurveBucket: Sendable, Equatable {
    public var min: Float
    public var max: Float

    public init(min: Float, max: Float) {
        self.min = min
        self.max = max
    }
}

/// Namespace for curve-lane downsampling and normalization.
public enum CurveLane {
    /// Downsample a sampled curve to one optional (min, max) per pixel column
    /// of `viewport`. `times` are seconds (any order); `values[i]` pairs with
    /// `times[i]` (extra elements of the longer array are ignored). Samples
    /// outside `[t0, t1)` and non-finite values are dropped; columns that
    /// receive no samples are `nil`. Extrema are preserved exactly: every
    /// visible sample lands in exactly one bucket.
    public static func minMaxBuckets(
        values: [Float], times: [Double], viewport: Viewport
    ) -> [CurveBucket?] {
        let columns = Int(viewport.width.rounded(.down))
        guard columns > 0, viewport.timeSpan > 0 else { return [] }
        var out = [CurveBucket?](repeating: nil, count: columns)
        let scale = Double(columns) / viewport.timeSpan
        let n = Swift.min(values.count, times.count)
        for i in 0..<n {
            let v = values[i]
            guard v.isFinite else { continue }
            let column = Int(((times[i] - viewport.t0) * scale).rounded(.down))
            guard column >= 0, column < columns else { continue }
            if var bucket = out[column] {
                bucket.min = Swift.min(bucket.min, v)
                bucket.max = Swift.max(bucket.max, v)
                out[column] = bucket
            } else {
                out[column] = CurveBucket(min: v, max: v)
            }
        }
        return out
    }

    /// Observed finite value range across `values`, or nil if none are finite.
    public static func valueRange(of values: [Float]) -> ClosedRange<Float>? {
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for v in values where v.isFinite {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        guard lo <= hi else { return nil }
        return lo...hi
    }

    /// Map `value` into lane-local 0..1 over `range`, clamped. A degenerate
    /// (zero-width) range maps everything to 0.5 (mid-lane flat line).
    public static func normalized(_ value: Float, in range: ClosedRange<Float>) -> Float {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        let u = (value - range.lowerBound) / span
        return Swift.min(Swift.max(u, 0), 1)
    }

    /// Normalize buckets to lane-local 0..1. Uses `fixedRange` when given
    /// (stable scaling across pans, e.g. 0...1 for harmonicity); otherwise
    /// auto-scales to the buckets' own extent so the visible curve fills the
    /// lane. All-nil or empty input passes through unchanged.
    public static func normalized(
        _ buckets: [CurveBucket?], fixedRange: ClosedRange<Float>? = nil
    ) -> [CurveBucket?] {
        let range: ClosedRange<Float>
        if let fixedRange {
            range = fixedRange
        } else {
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            for bucket in buckets {
                guard let bucket else { continue }
                if bucket.min < lo { lo = bucket.min }
                if bucket.max > hi { hi = bucket.max }
            }
            guard lo <= hi else { return buckets }
            range = lo...hi
        }
        return buckets.map { bucket in
            bucket.map {
                CurveBucket(
                    min: normalized($0.min, in: range),
                    max: normalized($0.max, in: range))
            }
        }
    }
}
