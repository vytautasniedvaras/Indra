import Testing

@testable import IndraKitCore

@Suite("SpecRenderPlanner")
struct SpecRenderPlanTests {
    let sr = 48000

    /// Same fixture family as TilePlannerTests: hop 1024 → 46.875 columns/s
    /// at LOD 0, framesPerColumn doubling per LOD.
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

    func makeViewport(t0: Double, t1: Double, f0: Double = 0, f1: Double = 24000) -> Viewport {
        Viewport(t0: t0, t1: t1, f0: f0, f1: f1, width: 1000, height: 500)
    }

    func fullBandKey(_ start: Int, end: Int, lod: Int) -> TileKey {
        TileKey(audioId: "a", kind: .spec, lod: lod, bounds: [start, end, 0, 2049])
    }

    // MARK: - Canonical full-band keys

    @Test func fetchKeysAreFullBandRegardlessOfFrequencyZoom() {
        let manifest = makeManifest()
        let zoomed = makeViewport(t0: 100, t1: 110, f0: 500, f1: 900)
        let keys = SpecRenderPlanner.fetchKeys(
            audioId: "a", viewport: zoomed, manifest: manifest, sr: sr)
        #expect(!keys.isEmpty)
        for key in keys {
            #expect(key.bounds[2] == 0)
            #expect(key.bounds[3] == manifest.nBins)
        }
        // Identical keys for a different frequency window (cache stability).
        let other = SpecRenderPlanner.fetchKeys(
            audioId: "a", viewport: makeViewport(t0: 100, t1: 110, f0: 0, f1: 24000),
            manifest: manifest, sr: sr)
        #expect(keys == other)
    }

    // MARK: - Quads for resident tiles

    @Test func residentTileBecomesQuadWithScreenAndTextureCoords() {
        let manifest = makeManifest()
        let viewport = makeViewport(t0: 0, t1: 10)  // LOD 0, one tile [0, 512)
        let key = fullBandKey(0, end: 512, lod: 0)
        let plan = SpecRenderPlanner.plan(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr,
            resident: [key: 5])
        #expect(plan.lod == 0)
        #expect(plan.missing.isEmpty)
        #expect(plan.placeholders.isEmpty)
        #expect(plan.quads.count == 1)
        let quad = plan.quads[0]
        #expect(quad.slot == 5)
        #expect(quad.x0 == 0)
        // Column 512 at LOD 0 = 512 * 1024 / 48000 s → × 100 px/s.
        let expectedX1 = 512.0 * 1024.0 / 48000.0 * 100.0
        #expect(abs(quad.x1 - expectedX1) < 1e-9)
        #expect(quad.v0 == 0)
        #expect(quad.v1 == 1)
        #expect(abs(quad.vMax - 511.5 / 512.0) < 1e-12)
    }

    @Test func partialEdgeTileClampsTextureRange() throws {
        let manifest = makeManifest()
        // File ends at column 100 000; last tile is [99840, 100000) = 160 rows.
        let viewport = makeViewport(t0: 2130, t1: 2133.4)
        let key = fullBandKey(99_840, end: 100_000, lod: 0)
        let plan = SpecRenderPlanner.plan(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr,
            resident: [key: 0])
        let quad = try #require(plan.quads.first { $0.slot == 0 })
        #expect(abs(quad.v1 - 160.0 / 512.0) < 1e-12)
        #expect(abs(quad.vMax - 159.5 / 512.0) < 1e-12)
    }

    // MARK: - Missing tiles and placeholders

    @Test func missingTileIsReportedWithoutPlaceholderWhenNothingResident() {
        let manifest = makeManifest()
        let plan = SpecRenderPlanner.plan(
            audioId: "a", viewport: makeViewport(t0: 0, t1: 10), manifest: manifest, sr: sr,
            resident: [:])
        #expect(plan.quads.isEmpty)
        #expect(plan.placeholders.isEmpty)
        #expect(plan.missing == [fullBandKey(0, end: 512, lod: 0)])
    }

    @Test func coarserResidentTileStretchesAsPlaceholder() {
        let manifest = makeManifest()
        let viewport = makeViewport(t0: 0, t1: 10)  // missing LOD-0 tile [0, 512)
        let parent = fullBandKey(0, end: 512, lod: 1)
        let plan = SpecRenderPlanner.plan(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr,
            resident: [parent: 7])
        #expect(plan.quads.isEmpty)
        #expect(plan.missing.count == 1)
        #expect(plan.placeholders.count == 1)
        let quad = plan.placeholders[0]
        #expect(quad.slot == 7)
        // Same screen span as the missing tile…
        #expect(quad.x0 == 0)
        let expectedX1 = 512.0 * 1024.0 / 48000.0 * 100.0
        #expect(abs(quad.x1 - expectedX1) < 1e-9)
        // …but only the first half of the parent slice (2× coarser columns).
        #expect(quad.v0 == 0)
        #expect(abs(quad.v1 - 0.5) < 1e-12)
    }

    @Test func placeholderSkipsToCoarserLodWhenIntermediateMissing() {
        let manifest = makeManifest()
        let viewport = makeViewport(t0: 0, t1: 10)
        let grandparent = fullBandKey(0, end: 512, lod: 2)  // 4× coarser
        let plan = SpecRenderPlanner.plan(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr,
            resident: [grandparent: 3])
        #expect(plan.placeholders.count == 1)
        #expect(plan.placeholders[0].slot == 3)
        #expect(abs(plan.placeholders[0].v1 - 0.25) < 1e-12)
    }

    // MARK: - LOD override (cross-fade support)

    @Test func lodOverrideForcesPlanLod() {
        let manifest = makeManifest()
        let viewport = makeViewport(t0: 0, t1: 100)  // auto LOD 2
        let auto = SpecRenderPlanner.plan(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr, resident: [:])
        #expect(auto.lod == 2)
        let forced = SpecRenderPlanner.plan(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr, resident: [:],
            lodOverride: 0)
        #expect(forced.lod == 0)
        for key in forced.missing {
            #expect(key.lod == 0)
        }
        #expect(forced.missing.count > auto.missing.count)
    }

    @Test func planIsDeterministic() {
        let manifest = makeManifest()
        let viewport = makeViewport(t0: 42, t1: 197)
        let resident = [fullBandKey(2048, end: 2560, lod: 2): 1]
        let a = SpecRenderPlanner.plan(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr, resident: resident)
        let b = SpecRenderPlanner.plan(
            audioId: "a", viewport: viewport, manifest: manifest, sr: sr, resident: resident)
        #expect(a == b)
    }
}

@Suite("LodFade")
struct LodFadeTests {
    @Test func freshFadeIsSettled() {
        let fade = LodFade(lod: 3, at: 100)
        #expect(fade.alpha(at: 100) == 1)
        #expect(fade.alpha(at: 105) == 1)
        #expect(fade.isComplete(at: 100))
    }

    @Test func retargetRampsAlphaOverDuration() {
        var fade = LodFade(lod: 3, at: 100)
        fade = fade.retargeted(to: 2, at: 200)
        #expect(fade.previousLod == 3)
        #expect(fade.currentLod == 2)
        #expect(fade.alpha(at: 200) == 0)
        #expect(abs(fade.alpha(at: 200.05) - 0.5) < 1e-6)
        #expect(fade.alpha(at: 200.1) == 1)
        #expect(fade.alpha(at: 300) == 1)
        #expect(!fade.isComplete(at: 200.05))
        #expect(fade.isComplete(at: 200.1))
    }

    @Test func retargetToSameLodIsNoOp() {
        let fade = LodFade(lod: 3, at: 100)
        #expect(fade.retargeted(to: 3, at: 200) == fade)
    }

    @Test func settledDropsPreviousOnlyWhenComplete() {
        var fade = LodFade(lod: 3, at: 0).retargeted(to: 2, at: 10)
        #expect(fade.settled(at: 10.05) == fade)  // mid-fade: unchanged
        fade = fade.settled(at: 10.2)
        #expect(fade.previousLod == nil)
        #expect(fade.currentLod == 2)
    }

    @Test func rapidRetargetFadesFromLatestDrawnLod() {
        // Zooming through several LODs quickly: each retarget replaces the
        // outgoing LOD (no chains) and restarts the ramp.
        let fade = LodFade(lod: 4, at: 0)
            .retargeted(to: 3, at: 0.02)
            .retargeted(to: 2, at: 0.04)
        #expect(fade.previousLod == 3)
        #expect(fade.currentLod == 2)
        #expect(fade.alpha(at: 0.04) == 0)
    }
}
