import Testing

@testable import IndraKitCore

@Suite("TilePlanner")
struct TilePlannerTests {
    let sr = 48000

    /// Six-LOD spectrogram manifest: 100 000 base frames at hop 1024 ≈ 2133 s.
    func makeManifest(frames0: Int = 100_000, lodCount: Int = 6) -> SpecManifest {
        var lods: [SpecLod] = []
        var frames = frames0
        for lod in 0..<lodCount {
            lods.append(SpecLod(lod: lod, frames: frames, framesPerColumn: 1 << lod))
            frames = (frames + 1) / 2
        }
        return SpecManifest(
            nFft: 4096, hop: 1024, window: "blackmanharris7", nBins: 2049,
            dbMin: -100, dbMax: 0, monoDownmix: true, lods: lods)
    }

    /// Eight-LOD waveform pyramid over 48 000 000 samples (1000 s): base
    /// bucket 256 samples → 187 500 buckets at LOD 0.
    func makeWaveformLods(totalSamples: Int = 48_000_000, count: Int = 8) -> [WaveformLod] {
        (0..<count).map { lod in
            let bucketSamples = 256 << lod
            return WaveformLod(
                lod: lod, bucketSamples: bucketSamples,
                buckets: (totalSamples + bucketSamples - 1) / bucketSamples)
        }
    }

    func makeViewport(t0: Double, t1: Double, width: Double = 1000) -> Viewport {
        Viewport(t0: t0, t1: t1, f0: 0, f1: 24000, width: width, height: 500)
    }

    // MARK: - Spectrogram LOD selection

    @Test func specLodZeroWhenZoomedIn() {
        // 10 s over 1000 px → 468.75 visible frames < 1000 px → LOD 0.
        let manifest = makeManifest()
        let lod = TilePlanner.specLod(for: makeViewport(t0: 0, t1: 10), manifest: manifest, sr: sr)
        #expect(lod == 0)
    }

    @Test func specLodMidZoom() {
        // 100 s over 1000 px → 4687.5 frames / 1000 px → floor(log2(4.6875)) = 2.
        let manifest = makeManifest()
        let viewport = makeViewport(t0: 0, t1: 100)
        let lod = TilePlanner.specLod(for: viewport, manifest: manifest, sr: sr)
        #expect(lod == 2)
        // Chosen LOD shows 1–2 columns per pixel.
        let framesVisible = viewport.timeSpan * Double(sr) / 1024.0
        let columnsPerPixel = framesVisible / Double(1 << lod) / viewport.width
        #expect(columnsPerPixel >= 1)
        #expect(columnsPerPixel < 2)
    }

    @Test func specLodClampsToMaxLod() {
        let manifest = makeManifest()
        let lod = TilePlanner.specLod(
            for: makeViewport(t0: 0, t1: 100_000), manifest: manifest, sr: sr)
        #expect(lod == 5)
    }

    @Test func specLodIntermediateZoom() {
        // 64 s over 1000 px → exactly 3000 visible frames (64 * 46.875, both
        // exact doubles) → ratio 3 → floor(log2(3)) = 1.
        let manifest = makeManifest()
        let lod = TilePlanner.specLod(for: makeViewport(t0: 0, t1: 64), manifest: manifest, sr: sr)
        #expect(lod == 1)
    }

    // MARK: - Unit conversions

    @Test func columnConversionRoundTrip() {
        let manifest = makeManifest()
        let lod = manifest.lods[2]  // framesPerColumn 4
        // One column = hop * framesPerColumn / sr seconds.
        #expect(TilePlanner.column(atSeconds: 0, manifest: manifest, lod: lod, sr: sr) == 0)
        let secondsPerColumn = 1024.0 * 4.0 / 48000.0
        #expect(
            TilePlanner.column(atSeconds: 100 * secondsPerColumn, manifest: manifest, lod: lod, sr: sr)
                == 100)
        #expect(
            TilePlanner.seconds(atColumn: 100, manifest: manifest, lod: lod, sr: sr)
                == 100 * secondsPerColumn)
    }

    @Test func binConversionClamps() {
        let manifest = makeManifest()
        #expect(TilePlanner.bin(atHz: 0, manifest: manifest, sr: sr) == 0)
        #expect(TilePlanner.bin(atHz: -100, manifest: manifest, sr: sr) == 0)
        // Bin width = sr / nFft = 11.71875 Hz.
        #expect(TilePlanner.bin(atHz: 11.72, manifest: manifest, sr: sr) == 1)
        #expect(TilePlanner.bin(atHz: 1e9, manifest: manifest, sr: sr) == 2048)
        let range = TilePlanner.binRange(f0: -10, f1: 1e9, manifest: manifest, sr: sr)
        #expect(range.lower == 0)
        #expect(range.upper == 2049)
        // Degenerate input still yields a non-empty half-open range.
        let point = TilePlanner.binRange(f0: 1000, f1: 1000, manifest: manifest, sr: sr)
        #expect(point.upper > point.lower)
    }

    // MARK: - Spectrogram tile emission

    @Test func specTilesCoverViewportPlusMarginWithoutGaps() {
        let manifest = makeManifest()
        let viewport = makeViewport(t0: 100, t1: 110)  // LOD 0
        let keys = TilePlanner.specTiles(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr)
        #expect(!keys.isEmpty)
        // Padded range 95..115 s at 46.875 columns/s → columns 4453..<5391.
        let c0 = 4453
        let c1 = 5391
        #expect(keys.first!.bounds[0] <= c0)
        #expect(keys.last!.bounds[1] >= c1)
        for key in keys {
            #expect(key.kind == .spec)
            #expect(key.lod == 0)
            #expect(key.bounds[0] % 512 == 0)  // quantized starts
            #expect(key.bounds[1] - key.bounds[0] <= 512)
            #expect(key.bounds[1] <= manifest.lods[0].frames)
        }
        // Contiguous coverage: no gaps, no overlaps.
        for i in 1..<keys.count {
            #expect(keys[i].bounds[0] == keys[i - 1].bounds[1])
        }
        #expect(keys.count == 3)  // starts 4096, 4608, 5120
        #expect(keys.first!.bounds[0] == 4096)
    }

    @Test func specTilesCarryViewportBinRange() {
        let manifest = makeManifest()
        let viewport = Viewport(t0: 100, t1: 110, f0: 100, f1: 1000, width: 1000, height: 500)
        let keys = TilePlanner.specTiles(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr)
        let bins = TilePlanner.binRange(f0: 100, f1: 1000, manifest: manifest, sr: sr)
        for key in keys {
            #expect(key.bounds[2] == bins.lower)
            #expect(key.bounds[3] == bins.upper)
        }
    }

    @Test func specTilesClampAtFileStart() {
        let manifest = makeManifest()
        let keys = TilePlanner.specTiles(
            audioId: "a", viewport: makeViewport(t0: 0, t1: 10), manifest: manifest, sr: sr)
        #expect(keys.first!.bounds[0] == 0)
    }

    @Test func specTilesClampAtFileEnd() {
        let manifest = makeManifest()
        // File ends at 100000 frames ≈ 2133.3 s; viewport hugs the edge.
        let keys = TilePlanner.specTiles(
            audioId: "a", viewport: makeViewport(t0: 2100, t1: 2133), manifest: manifest, sr: sr)
        #expect(!keys.isEmpty)
        #expect(keys.last!.bounds[1] == manifest.lods[0].frames)
        #expect(keys.last!.bounds[1] > keys.last!.bounds[0])
    }

    @Test func specTilesEmptyPastFileEnd() {
        let manifest = makeManifest()
        let keys = TilePlanner.specTiles(
            audioId: "a", viewport: makeViewport(t0: 3000, t1: 3010), manifest: manifest, sr: sr)
        #expect(keys.isEmpty)
    }

    @Test func specTilesDeterministic() {
        let manifest = makeManifest()
        let viewport = makeViewport(t0: 42, t1: 197)
        let a = TilePlanner.specTiles(audioId: "a", viewport: viewport, manifest: manifest, sr: sr)
        let b = TilePlanner.specTiles(audioId: "a", viewport: viewport, manifest: manifest, sr: sr)
        #expect(a == b)
    }

    // MARK: - Waveform LOD selection

    @Test func waveformLodSelection() {
        let lods = makeWaveformLods()
        // 10 s / 1000 px → 480 samples/px → base bucket 256 (LOD 0).
        #expect(TilePlanner.waveformLod(for: makeViewport(t0: 0, t1: 10), lods: lods, sr: sr) == 0)
        // 100 s / 1000 px → 4800 samples/px → largest bucket ≤ 4800 is 4096 (LOD 4).
        #expect(TilePlanner.waveformLod(for: makeViewport(t0: 0, t1: 100), lods: lods, sr: sr) == 4)
        // Zoomed in past base bucket → finest LOD.
        #expect(
            TilePlanner.waveformLod(for: makeViewport(t0: 0, t1: 0.05), lods: lods, sr: sr) == 0)
        // Zoomed way out → coarsest LOD.
        #expect(
            TilePlanner.waveformLod(for: makeViewport(t0: 0, t1: 10000), lods: lods, sr: sr) == 7)
    }

    // MARK: - Waveform tile emission

    @Test func waveformTilesCoverViewportPlusMargin() {
        let lods = makeWaveformLods()
        let keys = TilePlanner.waveformTiles(
            audioId: "a", viewport: makeViewport(t0: 100, t1: 110), lods: lods, sr: sr)
        #expect(!keys.isEmpty)
        // Padded 95..115 s at 187.5 buckets/s → buckets 17812..<21563.
        #expect(keys.first!.bounds[0] <= 17812)
        #expect(keys.last!.bounds[0] + keys.last!.bounds[1] >= 21563)
        for key in keys {
            #expect(key.kind == .waveform)
            #expect(key.lod == 0)
            #expect(key.bounds[0] % 512 == 0)
            #expect(key.bounds[1] <= 512)
            #expect(key.bounds[2] == 0)
            #expect(key.bounds[3] == 0)
        }
        // Contiguous: next start = previous start + count.
        for i in 1..<keys.count {
            #expect(keys[i].bounds[0] == keys[i - 1].bounds[0] + keys[i - 1].bounds[1])
        }
    }

    @Test func waveformTilesClampAtFileEnd() {
        let lods = makeWaveformLods()  // 187 500 buckets at LOD 0, 1000 s file
        let keys = TilePlanner.waveformTiles(
            audioId: "a", viewport: makeViewport(t0: 995, t1: 1000), lods: lods, sr: sr)
        #expect(!keys.isEmpty)
        let last = keys.last!
        #expect(last.bounds[0] + last.bounds[1] == 187_500)
        #expect(last.bounds[1] > 0)
    }

    @Test func waveformTilesEmptyPastFileEnd() {
        let lods = makeWaveformLods()
        let keys = TilePlanner.waveformTiles(
            audioId: "a", viewport: makeViewport(t0: 2000, t1: 2010), lods: lods, sr: sr)
        #expect(keys.isEmpty)
    }

    @Test func emptyManifestsYieldNoTiles() {
        let manifest = SpecManifest(
            nFft: 4096, hop: 1024, window: "blackmanharris7", nBins: 2049,
            dbMin: -100, dbMax: 0, monoDownmix: true, lods: [])
        let viewport = makeViewport(t0: 0, t1: 10)
        #expect(
            TilePlanner.specTiles(audioId: "a", viewport: viewport, manifest: manifest, sr: sr)
                .isEmpty)
        #expect(TilePlanner.waveformTiles(audioId: "a", viewport: viewport, lods: [], sr: sr).isEmpty)
    }
}
