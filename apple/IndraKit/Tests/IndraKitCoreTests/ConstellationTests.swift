import Testing

@testable import IndraKitCore

@Suite("ConstellationLayout")
struct ConstellationTests {
    private func result(
        xy: [[Double]], clusters: [Int], segments: [(Double, Double, Double)]
    ) -> SimilarSearchResult {
        SimilarSearchResult(
            segments: segments.map { SimilarSegment(t0: $0.0, t1: $0.1, distance: $0.2) },
            threshold: 0.4,
            embedding: SegmentEmbedding(
                xy: xy, cluster: clusters, nClusters: Set(clusters).count))
    }

    @Test func normalizesIntoPaddedUnitSquare() {
        let dots = ConstellationLayout.dots(
            for: result(
                xy: [[-2, 10], [0, 20], [6, 40]],
                clusters: [1, 1, 2],
                segments: [(0, 1, 0.1), (5, 6, 0.2), (9, 13, 0.5)]))
        #expect(dots.count == 3)
        for dot in dots {
            #expect(dot.x >= 0.08 && dot.x <= 0.92)
            #expect(dot.y >= 0.08 && dot.y <= 0.92)
        }
        // Extremes land exactly on the padded edges.
        #expect(abs(dots[0].x - 0.08) < 1e-9)
        #expect(abs(dots[2].x - 0.92) < 1e-9)
    }

    @Test func radiusGrowsWithDurationAndIsClamped() {
        let dots = ConstellationLayout.dots(
            for: result(
                xy: [[0, 0], [1, 1], [2, 2]],
                clusters: [1, 1, 1],
                segments: [(0, 0.1, 0.1), (0, 1, 0.1), (0, 16, 0.1)]))
        #expect(dots[0].radius < dots[1].radius)
        #expect(dots[1].radius < dots[2].radius)
        #expect(dots[2].radius <= ConstellationLayout.maxRadius + 1e-12)
        #expect(dots[0].radius >= ConstellationLayout.minRadius - 1e-12)
        // area ∝ duration: 16× duration → 4× radius delta over the min
        #expect(abs(dots[2].radius - ConstellationLayout.maxRadius) < 1e-9)
    }

    @Test func degenerateAxisCollapsesToCenter() {
        let dots = ConstellationLayout.dots(
            for: result(
                xy: [[3, 1], [3, 2]],
                clusters: [1, 2],
                segments: [(0, 1, 0.0), (2, 3, 0.9)]))
        #expect(dots.allSatisfy { abs($0.x - 0.5) < 1e-9 })
        #expect(dots[0].closeness == 1.0)
        #expect(abs(dots[1].closeness - 0.1) < 1e-9)
    }

    @Test func noEmbeddingMeansNoDots() {
        let bare = SimilarSearchResult(
            segments: [SimilarSegment(t0: 0, t1: 1, distance: 0.1)], threshold: 0.4)
        #expect(ConstellationLayout.dots(for: bare).isEmpty)
    }

    @Test func clusterHuesAreDistinct() {
        let hues = (1...8).map { ConstellationLayout.hue(forCluster: $0) }
        for (i, a) in hues.enumerated() {
            for b in hues.dropFirst(i + 1) {
                let d = abs(a - b)
                #expect(min(d, 1 - d) > 0.05, "clusters \(a) and \(b) too close in hue")
            }
        }
    }
}
