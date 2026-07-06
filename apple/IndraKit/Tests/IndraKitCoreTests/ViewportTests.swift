import Testing

@testable import IndraKitCore

@Suite("Viewport")
struct ViewportTests {
    func makeViewport(
        t0: Double = 10, t1: Double = 20, f0: Double = 0, f1: Double = 24000,
        width: Double = 1000, height: Double = 500
    ) -> Viewport {
        Viewport(t0: t0, t1: t1, f0: f0, f1: f1, width: width, height: height)
    }

    func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func initNormalizesBoundsAndClampsSize() {
        let vp = Viewport(t0: 20, t1: 10, f0: 500, f1: 100, width: 0, height: -5)
        #expect(vp.t0 == 10)
        #expect(vp.t1 == 20)
        #expect(vp.f0 == 100)
        #expect(vp.f1 == 500)
        #expect(vp.width == 1)
        #expect(vp.height == 1)
    }

    // MARK: - Time mapping

    @Test func timeToXRoundTrip() {
        let vp = makeViewport()
        #expect(approx(vp.timeToX(10), 0))
        #expect(approx(vp.timeToX(20), 1000))
        #expect(approx(vp.timeToX(15), 500))
        for x in [0.0, 137.5, 500, 999, 1000] {
            #expect(approx(vp.timeToX(vp.xToTime(x)), x))
        }
    }

    @Test func timesOutsideRangeMapOffScreen() {
        let vp = makeViewport()
        #expect(vp.timeToX(5) < 0)
        #expect(vp.timeToX(25) > vp.width)
    }

    // MARK: - Time zoom/pan

    @Test func zoomKeepsAnchorFixedOnScreen() {
        let vp = makeViewport()
        let anchorT = 12.0
        let xBefore = vp.timeToX(anchorT)
        let zoomed = vp.zoomedTime(by: 2, anchorT: anchorT, duration: 100)
        #expect(approx(zoomed.timeSpan, 5))
        #expect(approx(zoomed.timeToX(anchorT), xBefore))
        let zoomedOut = vp.zoomedTime(by: 0.5, anchorT: anchorT, duration: 100)
        #expect(approx(zoomedOut.timeSpan, 20))
        #expect(approx(zoomedOut.timeToX(anchorT), xBefore))
    }

    @Test func zoomInClampsToMinSpan() {
        let vp = makeViewport(t0: 10, t1: 10.002)
        let zoomed = vp.zoomedTime(by: 1000, anchorT: 10.001, duration: 100)
        #expect(approx(zoomed.timeSpan, Viewport.minTimeSpan))
    }

    @Test func zoomOutClampsToDuration() {
        let vp = makeViewport()
        let zoomed = vp.zoomedTime(by: 0.001, anchorT: 15, duration: 100)
        #expect(approx(zoomed.t0, 0))
        #expect(approx(zoomed.t1, 100))
    }

    @Test func panClampsAtFileEdges() {
        let vp = makeViewport()
        let left = vp.pannedTime(bySeconds: -50, duration: 100)
        #expect(approx(left.t0, 0))
        #expect(approx(left.t1, 10))
        let right = vp.pannedTime(bySeconds: 500, duration: 100)
        #expect(approx(right.t0, 90))
        #expect(approx(right.t1, 100))
        let small = vp.pannedTime(bySeconds: 2, duration: 100)
        #expect(approx(small.t0, 12))
        #expect(approx(small.t1, 22))
    }

    // MARK: - Frequency zoom/pan

    @Test func frequencyZoomKeepsAnchorFixed() {
        let vp = makeViewport(f0: 0, f1: 24000)
        let anchorF = 6000.0
        let yBefore = vp.freqToY(anchorF)
        let zoomed = vp.zoomedFrequency(by: 2, anchorF: anchorF, maxFrequency: 24000)
        #expect(approx(zoomed.frequencySpan, 12000))
        #expect(approx(zoomed.freqToY(anchorF), yBefore))
    }

    @Test func frequencyZoomMinSpanGuard() {
        let vp = makeViewport(f0: 1000, f1: 1002)
        let zoomed = vp.zoomedFrequency(by: 100, anchorF: 1001, maxFrequency: 24000)
        #expect(approx(zoomed.frequencySpan, Viewport.minFrequencySpan))
    }

    @Test func frequencyPanClamps() {
        let vp = makeViewport(f0: 1000, f1: 2000)
        let down = vp.pannedFrequency(byHz: -5000, maxFrequency: 24000)
        #expect(approx(down.f0, 0))
        #expect(approx(down.f1, 1000))
        let up = vp.pannedFrequency(byHz: 100_000, maxFrequency: 24000)
        #expect(approx(up.f0, 23000))
        #expect(approx(up.f1, 24000))
    }

    // MARK: - Frequency mapping

    @Test func linearFrequencyMapping() {
        let vp = makeViewport(f0: 0, f1: 24000, height: 500)
        #expect(approx(vp.freqToY(24000), 0))  // high frequency on top
        #expect(approx(vp.freqToY(0), 500))
        #expect(approx(vp.freqToY(12000), 250))
        for y in [0.0, 100, 250, 499, 500] {
            #expect(approx(vp.freqToY(vp.yToFreq(y)), y))
        }
    }

    @Test func logFrequencyMapping() {
        let vp = makeViewport(f0: 20, f1: 20000, height: 100)
        #expect(approx(vp.freqToY(20, scale: .logarithmic), 100))
        #expect(approx(vp.freqToY(20000, scale: .logarithmic), 0))
        // Geometric mean sqrt(20 * 20000) maps to mid-height.
        #expect(approx(vp.freqToY(632.4555320336759, scale: .logarithmic), 50, tolerance: 1e-6))
        for y in [0.0, 25, 50, 75, 100] {
            #expect(approx(vp.freqToY(vp.yToFreq(y, scale: .logarithmic), scale: .logarithmic), y, tolerance: 1e-6))
        }
    }

    @Test func logFrequencyFloorApplied() {
        let vp = makeViewport(f0: 0, f1: 20000, height: 100)
        // Below the 20 Hz floor everything collapses to the bottom edge.
        #expect(approx(vp.freqToY(0, scale: .logarithmic), 100))
        #expect(approx(vp.freqToY(10, scale: .logarithmic), 100))
        #expect(approx(vp.freqToY(Viewport.logFrequencyFloor, scale: .logarithmic), 100))
        #expect(vp.freqToY(21, scale: .logarithmic) < 100)
    }

    @Test func frequencyScaleCases() {
        #expect(FrequencyScale.allCases.count == 2)
        #expect(FrequencyScale(rawValue: "linear") == .linear)
        #expect(FrequencyScale(rawValue: "logarithmic") == .logarithmic)
    }
}
