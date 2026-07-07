import Testing

@testable import IndraKitCore

@Suite("FrequencyLUT")
struct FrequencyLUTTests {
    let sr = 48000

    var manifest: SpecManifest {
        SpecManifest(
            nFft: 4096, hop: 1024, window: "blackmanharris7", nBins: 2049,
            dbMin: -100, dbMax: 0, monoDownmix: true, lods: [])
    }

    @Test func linearFullBandSpansTheBinRange() {
        let viewport = Viewport(t0: 0, t1: 10, f0: 0, f1: 24000, width: 1000, height: 500)
        let lut = FrequencyLUT.binFractions(
            viewport: viewport, scale: .linear, manifest: manifest, sr: sr, count: 1024)
        #expect(lut.count == 1024)
        // Top row shows near-Nyquist bins, bottom row near-DC bins.
        #expect(lut.first! > 0.99)
        #expect(lut.last! < 0.01)
        for value in lut {
            #expect(value >= 0 && value <= 1)
        }
        // Linear scale: strictly decreasing top → bottom (higher y = lower f).
        for i in 1..<lut.count {
            #expect(lut[i] < lut[i - 1])
        }
    }

    @Test func linearMatchesViewportMapping() {
        let viewport = Viewport(t0: 0, t1: 10, f0: 1000, f1: 5000, width: 1000, height: 400)
        let count = 8
        let lut = FrequencyLUT.binFractions(
            viewport: viewport, scale: .linear, manifest: manifest, sr: sr, count: count)
        for row in 0..<count {
            let y = (Double(row) + 0.5) / Double(count) * viewport.height
            let hz = viewport.yToFreq(y, scale: .linear)
            let bin = hz * Double(manifest.nFft) / Double(sr)
            let expected = Float((bin + 0.5) / Double(manifest.nBins))
            #expect(abs(lut[row] - expected) < 1e-6)
        }
    }

    @Test func logScaleUsesViewportLogMapping() {
        let viewport = Viewport(t0: 0, t1: 10, f0: 20, f1: 20000, width: 1000, height: 500)
        let count = 64
        let lut = FrequencyLUT.binFractions(
            viewport: viewport, scale: .logarithmic, manifest: manifest, sr: sr, count: count)
        // Monotonically decreasing, and the midpoint sits at the geometric
        // mean frequency (log display), far below the linear midpoint.
        for i in 1..<count {
            #expect(lut[i] < lut[i - 1])
        }
        let midHz = viewport.yToFreq(viewport.height / 2, scale: .logarithmic)
        #expect(abs(midHz - (20.0 * 20000.0).squareRoot()) < 1.0)
        let linearMid = FrequencyLUT.binFractions(
            viewport: viewport, scale: .linear, manifest: manifest, sr: sr, count: count)
        #expect(lut[count / 2] < linearMid[count / 2])
    }

    @Test func outOfRangeFrequenciesClampToEdgeBins() {
        // Viewport extends past Nyquist: top rows pin to the last bin.
        let viewport = Viewport(t0: 0, t1: 10, f0: 0, f1: 100_000, width: 1000, height: 500)
        let lut = FrequencyLUT.binFractions(
            viewport: viewport, scale: .linear, manifest: manifest, sr: sr, count: 16)
        let lastBinCenter = Float((Double(manifest.nBins) - 0.5) / Double(manifest.nBins))
        #expect(lut.first! == lastBinCenter)
        #expect(lut.last! >= 0)
    }

    @Test func degenerateInputsYieldEmptyTable() {
        let viewport = Viewport(t0: 0, t1: 10, f0: 0, f1: 24000, width: 1000, height: 500)
        #expect(
            FrequencyLUT.binFractions(
                viewport: viewport, scale: .linear, manifest: manifest, sr: 0, count: 16
            ).isEmpty)
        #expect(
            FrequencyLUT.binFractions(
                viewport: viewport, scale: .linear, manifest: manifest, sr: sr, count: 0
            ).isEmpty)
    }
}
