// Constellation layout (docs/design/selection-ux.md §3): map similar-search
// results into a unit square for the cluster-map view. Dot position comes
// from the embedding's 2-D PCA coordinates, size from segment duration,
// hue from cluster label. Pure math — Linux-tested; the SwiftUI Canvas
// layer just scales to pixels and draws.

import Foundation

public enum ConstellationLayout {
    /// One drawable dot, in unit coordinates (0..1 both axes, origin
    /// top-left like screen space).
    public struct Dot: Sendable, Equatable {
        /// Index into the SimilarSearchResult.segments array.
        public var segmentIndex: Int
        public var x: Double
        public var y: Double
        /// Radius as a fraction of the canvas's smaller side.
        public var radius: Double
        public var cluster: Int
        /// 0 (far) … 1 (identical to the seed) — drives brightness.
        public var closeness: Double

        public init(
            segmentIndex: Int, x: Double, y: Double, radius: Double, cluster: Int,
            closeness: Double
        ) {
            self.segmentIndex = segmentIndex
            self.x = x
            self.y = y
            self.radius = radius
            self.cluster = cluster
            self.closeness = closeness
        }
    }

    public static let minRadius = 0.018
    public static let maxRadius = 0.06

    /// Dots for every segment that has embedding coordinates. Axes are
    /// normalized independently into [padding, 1-padding] (PCA axes have no
    /// shared scale); degenerate spans collapse to the center. Radius scales
    /// with sqrt(duration) — area ∝ duration — clamped to min/maxRadius.
    public static func dots(
        for result: SimilarSearchResult, padding: Double = 0.08
    ) -> [Dot] {
        guard let embedding = result.embedding, !embedding.xy.isEmpty else { return [] }
        let count = min(embedding.xy.count, result.segments.count)
        guard count > 0 else { return [] }
        let xs = embedding.xy.prefix(count).map { $0[0] }
        let ys = embedding.xy.prefix(count).map { $0[1] }
        let durations = result.segments.prefix(count).map { max($0.t1 - $0.t0, 0) }
        let maxDuration = max(durations.max() ?? 0, 1e-9)
        let inner = 1 - 2 * padding
        let (xLo, xHi) = (xs.min() ?? 0, xs.max() ?? 0)
        let (yLo, yHi) = (ys.min() ?? 0, ys.max() ?? 0)

        func normalize(_ value: Double, min lo: Double, max hi: Double) -> Double {
            hi - lo > 1e-12 ? padding + (value - lo) / (hi - lo) * inner : 0.5
        }

        var dots: [Dot] = []
        dots.reserveCapacity(count)
        for index in 0..<count {
            let scaled = (durations[index] / maxDuration).squareRoot()
            let cluster =
                index < embedding.cluster.count ? embedding.cluster[index] : 0
            dots.append(
                Dot(
                    segmentIndex: index,
                    x: normalize(xs[index], min: xLo, max: xHi),
                    y: normalize(ys[index], min: yLo, max: yHi),
                    radius: minRadius + (maxRadius - minRadius) * scaled,
                    cluster: cluster,
                    closeness: max(0, 1 - result.segments[index].distance)))
        }
        return dots
    }

    /// Nearest dot whose (scaled) disc contains the point, in a width×height
    /// pixel canvas; `minHitRadius` keeps tiny dots clickable. Pure geometry —
    /// views pass their pixel size and draw-space point.
    public static func hitTest(
        dots: [Dot], x: Double, y: Double, width: Double, height: Double,
        minHitRadius: Double = 6
    ) -> Int? {
        let side = min(width, height)
        var best: (index: Int, distance: Double)?
        for dot in dots {
            let dx = x - dot.x * width
            let dy = y - dot.y * height
            let distance = (dx * dx + dy * dy).squareRoot()
            let hitRadius = max(dot.radius * side, minHitRadius)
            if distance <= hitRadius, distance < (best?.distance ?? .infinity) {
                best = (dot.segmentIndex, distance)
            }
        }
        return best?.index
    }

    /// Stable, well-separated hue per cluster label (golden-angle walk).
    public static func hue(forCluster cluster: Int) -> Double {
        (Double(cluster) * 0.381966).truncatingRemainder(dividingBy: 1)
    }

    /// The seed's unit-square position, normalized with the SAME extrema as
    /// the segment dots so it lands among its matches. The seed can project
    /// outside the segments' bounding box — clamped to stay visible. Nil when
    /// there is no embedding or no seed projection.
    public static func seedPoint(
        for result: SimilarSearchResult, padding: Double = 0.08
    ) -> (x: Double, y: Double)? {
        guard let embedding = result.embedding, let seed = embedding.seedXY,
            seed.count >= 2, !embedding.xy.isEmpty
        else { return nil }
        let count = min(embedding.xy.count, result.segments.count)
        guard count > 0 else { return nil }
        let xs = embedding.xy.prefix(count).map { $0[0] }
        let ys = embedding.xy.prefix(count).map { $0[1] }
        let inner = 1 - 2 * padding

        func normalize(_ value: Double, min lo: Double, max hi: Double) -> Double {
            hi - lo > 1e-12 ? padding + (value - lo) / (hi - lo) * inner : 0.5
        }
        func clamp(_ value: Double) -> Double { Swift.min(Swift.max(value, 0.02), 0.98) }

        return (
            clamp(normalize(seed[0], min: xs.min() ?? 0, max: xs.max() ?? 0)),
            clamp(normalize(seed[1], min: ys.min() ?? 0, max: ys.max() ?? 0))
        )
    }
}
