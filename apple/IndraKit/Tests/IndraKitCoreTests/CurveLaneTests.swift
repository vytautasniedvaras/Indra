import Testing

@testable import IndraKitCore

@Suite("CurveLane")
struct CurveLaneTests {
    /// 100-column lane over 0..10 s.
    func makeViewport(t0: Double = 0, t1: Double = 10, width: Double = 100) -> Viewport {
        Viewport(t0: t0, t1: t1, f0: 0, f1: 24000, width: width, height: 50)
    }

    // MARK: - minMaxBuckets

    @Test func extremaArePreserved() {
        let values: [Float] = [0, 5, -3, 8, 2, -7, 4, 1]
        let times: [Double] = [0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5]
        let buckets = CurveLane.minMaxBuckets(
            values: values, times: times, viewport: makeViewport())
        #expect(buckets.count == 100)
        let mins = buckets.compactMap { $0?.min }
        let maxes = buckets.compactMap { $0?.max }
        #expect(mins.min() == -7)
        #expect(maxes.max() == 8)
        // Every visible sample landed in exactly one bucket.
        #expect(buckets.compactMap { $0 }.count == values.count)
    }

    @Test func samplesInSameColumnMerge() {
        // Both t = 5.0 and t = 5.05 land in column 50 of a 100-column lane.
        let buckets = CurveLane.minMaxBuckets(
            values: [2, 9], times: [5.0, 5.05], viewport: makeViewport())
        #expect(buckets[50] == CurveBucket(min: 2, max: 9))
        #expect(buckets.compactMap { $0 }.count == 1)
    }

    @Test func emptyInputYieldsAllNilColumns() {
        let buckets = CurveLane.minMaxBuckets(values: [], times: [], viewport: makeViewport())
        #expect(buckets.count == 100)
        #expect(buckets.allSatisfy { $0 == nil })
    }

    @Test func singlePoint() {
        let buckets = CurveLane.minMaxBuckets(
            values: [3.5], times: [5.0], viewport: makeViewport())
        #expect(buckets[50] == CurveBucket(min: 3.5, max: 3.5))
        #expect(buckets.compactMap { $0 }.count == 1)
    }

    @Test func viewportNarrowerThanData() {
        // Data spans 0..10 s; viewport shows only [4, 6). Samples outside are
        // dropped, including the right edge (half-open).
        let values: [Float] = [1, 2, 3, 4, 5, 6]
        let times: [Double] = [0, 2, 4, 5, 6, 8]
        let buckets = CurveLane.minMaxBuckets(
            values: values, times: times, viewport: makeViewport(t0: 4, t1: 6))
        #expect(buckets.count == 100)
        let visible = buckets.compactMap { $0 }
        #expect(visible.count == 2)  // t = 4 and t = 5 only
        #expect(buckets[0] == CurveBucket(min: 3, max: 3))
        #expect(buckets[50] == CurveBucket(min: 4, max: 4))
    }

    @Test func nonFiniteValuesSkipped() {
        let buckets = CurveLane.minMaxBuckets(
            values: [1, .nan, .infinity, 2],
            times: [1, 2, 3, 4],
            viewport: makeViewport())
        #expect(buckets.compactMap { $0 }.count == 2)
        let mins = buckets.compactMap { $0?.min }
        #expect(mins.allSatisfy { $0.isFinite })
    }

    @Test func degenerateViewportYieldsEmpty() {
        let buckets = CurveLane.minMaxBuckets(
            values: [1], times: [5], viewport: makeViewport(t0: 5, t1: 5))
        #expect(buckets.isEmpty)
    }

    @Test func mismatchedLengthsUseShorterCount() {
        let buckets = CurveLane.minMaxBuckets(
            values: [1, 2, 3], times: [1, 2], viewport: makeViewport())
        #expect(buckets.compactMap { $0 }.count == 2)
    }

    // MARK: - Normalization

    @Test func normalizedScalar() {
        #expect(CurveLane.normalized(5, in: 0...10) == 0.5)
        #expect(CurveLane.normalized(0, in: 0...10) == 0)
        #expect(CurveLane.normalized(10, in: 0...10) == 1)
        // Clamped outside the range.
        #expect(CurveLane.normalized(-1, in: 0...10) == 0)
        #expect(CurveLane.normalized(11, in: 0...10) == 1)
        // Degenerate range → mid-lane.
        #expect(CurveLane.normalized(3, in: 3...3) == 0.5)
    }

    @Test func valueRangeIgnoresNonFinite() {
        #expect(CurveLane.valueRange(of: [3, -1, .nan, 7]) == -1...7)
        #expect(CurveLane.valueRange(of: []) == nil)
        #expect(CurveLane.valueRange(of: [.nan, .infinity]) == nil)
        #expect(CurveLane.valueRange(of: [2]) == 2...2)
    }

    @Test func normalizedBucketsAutoRange() {
        let buckets = CurveLane.minMaxBuckets(
            values: [2, 4, 6], times: [1, 5, 9], viewport: makeViewport())
        let normalized = CurveLane.normalized(buckets)
        #expect(normalized[10] == CurveBucket(min: 0, max: 0))
        #expect(normalized[50] == CurveBucket(min: 0.5, max: 0.5))
        #expect(normalized[90] == CurveBucket(min: 1, max: 1))
        // nil columns pass through.
        #expect(normalized[0] == nil)
    }

    @Test func normalizedBucketsFixedRange() {
        let buckets = CurveLane.minMaxBuckets(
            values: [2, 4, 6], times: [1, 5, 9], viewport: makeViewport())
        let normalized = CurveLane.normalized(buckets, fixedRange: 0...8)
        #expect(normalized[10] == CurveBucket(min: 0.25, max: 0.25))
        #expect(normalized[50] == CurveBucket(min: 0.5, max: 0.5))
        #expect(normalized[90] == CurveBucket(min: 0.75, max: 0.75))
    }

    @Test func normalizedAllNilPassesThrough() {
        let buckets: [CurveBucket?] = [nil, nil, nil]
        #expect(CurveLane.normalized(buckets).allSatisfy { $0 == nil })
        #expect(CurveLane.normalized(buckets).count == 3)
    }
}
