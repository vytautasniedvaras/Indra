// Draw planning for the Metal tile renderer (BUILD_SPEC §5.3, ADR 0013):
// turn (viewport, manifest, resident atlas slots) into textured quads — the
// tiles to draw, the coarser-LOD stand-ins to stretch under still-loading
// tiles, and the keys to fetch. All geometry is computed here so the MTKView
// layer only encodes what this plan says; everything is Linux-testable.
//
// Tile convention (ADR 0013): tiles are FULL-HEIGHT slabs — 512 columns ×
// nBins bins, canonical bounds [c0, c1, 0, nBins] — so keys stay stable under
// frequency pan/zoom (the frequency axis is remapped per-pixel in the
// fragment shader via FrequencyLUT). One slab at nFft 4096 is 512 × 2049 ≈
// 1 MB; the default 128-slot atlas is ≈ 128 MB, inside the §4.7 texture budget.

/// One textured quad: an atlas slice (or sub-range of one) stretched over a
/// screen x range. The quad always spans the full canvas height; the fragment
/// shader picks the bin per output row.
public struct TileQuad: Sendable, Equatable {
    /// Atlas slice to sample.
    public var slot: Int
    /// Screen x range in pixels (same space as `Viewport.timeToX`).
    public var x0: Double
    public var x1: Double
    /// Time-axis texture coordinates, normalized over the slice's 512 rows.
    public var v0: Double
    public var v1: Double
    /// Upper sampling clamp: (uploadedRows − 0.5) / 512. Partial edge tiles
    /// upload fewer than 512 rows; linear sampling past the last real texel
    /// row would blend in stale slot contents.
    public var vMax: Double

    public init(slot: Int, x0: Double, x1: Double, v0: Double, v1: Double, vMax: Double) {
        self.slot = slot
        self.x0 = x0
        self.x1 = x1
        self.v0 = v0
        self.v1 = v1
        self.vMax = vMax
    }
}

/// A frame's worth of spectrogram drawing at one LOD.
public struct SpecRenderPlan: Sendable, Equatable {
    /// LOD the quads belong to.
    public var lod: Int
    /// Resident tiles at `lod`, ready to draw.
    public var quads: [TileQuad]
    /// Coarser-LOD stand-ins covering missing tiles (draw beneath `quads`).
    public var placeholders: [TileQuad]
    /// Keys at `lod` that are visible but not resident — fetch these.
    public var missing: [TileKey]

    public init(lod: Int, quads: [TileQuad], placeholders: [TileQuad], missing: [TileKey]) {
        self.lod = lod
        self.quads = quads
        self.placeholders = placeholders
        self.missing = missing
    }
}

/// Namespace for viewport → draw-quad planning.
public enum SpecRenderPlanner {
    /// Rows per atlas slice == columns per tile (TilePlanner's tile width).
    public static let tileRows = TilePlanner.defaultTileColumns

    /// The viewport used for tile KEYS: same time range, full frequency band,
    /// so `TilePlanner.binRange` clamps to [0, nBins] and keys never change
    /// under frequency pan/zoom (f1 = sr ≥ Nyquist + a bin, forcing the clamp).
    public static func fullBandViewport(_ viewport: Viewport, sr: Int) -> Viewport {
        Viewport(
            t0: viewport.t0, t1: viewport.t1, f0: 0, f1: Double(sr),
            width: viewport.width, height: viewport.height)
    }

    /// Keys to prefetch for a viewport: visible range plus the TilePlanner
    /// read-ahead margin, full-band bounds, at the auto-selected LOD.
    public static func fetchKeys(
        audioId: String, viewport: Viewport, manifest: SpecManifest, sr: Int,
        margin: Double = TilePlanner.defaultMargin
    ) -> [TileKey] {
        TilePlanner.specTiles(
            audioId: audioId, viewport: fullBandViewport(viewport, sr: sr),
            manifest: manifest, sr: sr, margin: margin)
    }

    /// Build the draw plan for a frame. `resident` maps tile keys to atlas
    /// slots (AtlasIndex.slotsByKey). `lodOverride` forces a LOD (used to keep
    /// drawing the outgoing LOD during a cross-fade); nil auto-selects.
    public static func plan(
        audioId: String,
        viewport: Viewport,
        manifest: SpecManifest,
        sr: Int,
        resident: [TileKey: Int],
        lodOverride: Int? = nil
    ) -> SpecRenderPlan {
        let fullBand = fullBandViewport(viewport, sr: sr)
        let lodValue =
            lodOverride ?? TilePlanner.specLod(for: viewport, manifest: manifest, sr: sr)
        // Visible tiles only (margin 0) — prefetch margin is fetchKeys' job.
        let keys = TilePlanner.specTiles(
            audioId: audioId, viewport: fullBand, manifest: manifest, sr: sr,
            lod: lodValue, margin: 0)
        guard let lod = manifest.lods.first(where: { $0.lod == lodValue }) ?? manifest.lods.last
        else {
            return SpecRenderPlan(lod: lodValue, quads: [], placeholders: [], missing: [])
        }

        var quads: [TileQuad] = []
        var placeholders: [TileQuad] = []
        var missing: [TileKey] = []
        for key in keys {
            let c0 = key.bounds[0]
            let c1 = key.bounds[1]
            if let slot = resident[key] {
                let rows = c1 - c0
                let t0 = TilePlanner.seconds(atColumn: c0, manifest: manifest, lod: lod, sr: sr)
                let t1 = TilePlanner.seconds(atColumn: c1, manifest: manifest, lod: lod, sr: sr)
                quads.append(
                    TileQuad(
                        slot: slot,
                        x0: viewport.timeToX(t0),
                        x1: viewport.timeToX(t1),
                        v0: 0,
                        v1: Double(rows) / Double(tileRows),
                        vMax: (Double(rows) - 0.5) / Double(tileRows)))
            } else {
                missing.append(key)
                placeholders.append(
                    contentsOf: placeholderQuads(
                        for: key, audioId: audioId, viewport: viewport, manifest: manifest,
                        sr: sr, lod: lod, resident: resident))
            }
        }
        return SpecRenderPlan(
            lod: lod.lod, quads: quads, placeholders: placeholders, missing: missing)
    }

    /// Coarser-LOD stand-ins for one missing tile: the finest coarser LOD
    /// whose covering tiles are ALL resident (typically the LOD the user just
    /// zoomed away from), stretched over the missing tile's screen range.
    /// Empty when no coarser LOD fully covers it — background shows through.
    static func placeholderQuads(
        for key: TileKey,
        audioId: String,
        viewport: Viewport,
        manifest: SpecManifest,
        sr: Int,
        lod: SpecLod,
        resident: [TileKey: Int]
    ) -> [TileQuad] {
        let coarser = manifest.lods
            .filter { $0.lod > lod.lod && $0.framesPerColumn > 0 && $0.frames > 0 }
            .sorted { $0.lod < $1.lod }
        for parent in coarser {
            // Missing tile's column range mapped into parent columns (fractional).
            let ratio = Double(lod.framesPerColumn) / Double(parent.framesPerColumn)
            let pc0 = Double(key.bounds[0]) * ratio
            let pc1 = min(Double(key.bounds[1]) * ratio, Double(parent.frames))
            guard pc1 > pc0 else { continue }

            var covering: [(key: TileKey, slot: Int, start: Int, end: Int)] = []
            var start = Int(pc0 / Double(tileRows)) * tileRows
            var fullyResident = true
            while Double(start) < pc1 {
                let end = min(start + tileRows, parent.frames)
                let parentKey = TileKey(
                    audioId: audioId, kind: .spec, lod: parent.lod,
                    bounds: [start, end, 0, manifest.nBins])
                guard let slot = resident[parentKey] else {
                    fullyResident = false
                    break
                }
                covering.append((parentKey, slot, start, end))
                start += tileRows
            }
            guard fullyResident, !covering.isEmpty else { continue }

            return covering.map { tile in
                // Overlap of the missing range with this parent tile, in
                // parent columns.
                let o0 = max(pc0, Double(tile.start))
                let o1 = min(pc1, Double(tile.end))
                let secondsPerParentColumn =
                    Double(manifest.hop * parent.framesPerColumn) / Double(sr)
                return TileQuad(
                    slot: tile.slot,
                    x0: viewport.timeToX(o0 * secondsPerParentColumn),
                    x1: viewport.timeToX(o1 * secondsPerParentColumn),
                    v0: (o0 - Double(tile.start)) / Double(tileRows),
                    v1: (o1 - Double(tile.start)) / Double(tileRows),
                    vMax: (Double(tile.end - tile.start) - 0.5) / Double(tileRows))
            }
        }
        return []
    }
}

/// LOD cross-fade state (BUILD_SPEC §5.3: "snap to nearest with a 100 ms
/// cross-fade on zoom pop"). The renderer draws the outgoing LOD's plan at
/// full opacity underneath and the incoming LOD's quads at `alpha(at:)` on
/// top until the fade completes. Times are any monotonic clock in seconds
/// (CACurrentMediaTime on the Metal side; plain doubles in tests).
public struct LodFade: Sendable, Equatable {
    /// LOD being faded out, nil once settled.
    public var previousLod: Int?
    /// LOD being faded in (the plan's current LOD).
    public var currentLod: Int
    /// When the fade started.
    public var startedAt: Double

    public static let duration = 0.1

    public init(lod: Int, at now: Double = 0) {
        self.previousLod = nil
        self.currentLod = lod
        self.startedAt = now
    }

    /// Incoming-LOD opacity: ramps 0 → 1 over `duration`, 1 when settled.
    public func alpha(at now: Double) -> Float {
        guard previousLod != nil else { return 1 }
        let progress = (now - startedAt) / Self.duration
        return Float(min(max(progress, 0), 1))
    }

    public func isComplete(at now: Double) -> Bool {
        // Defers to alpha() so the two can't disagree at the boundary (Double
        // subtraction can land a hair under `duration`; alpha's Float rounding
        // already treats that as fully faded in).
        previousLod == nil || alpha(at: now) >= 1
    }

    /// Fade toward a new LOD. Same LOD: unchanged. During an unfinished fade
    /// the old `previousLod` is dropped (no fade chains) — the newest target
    /// simply starts fading in over what is already drawn.
    public func retargeted(to lod: Int, at now: Double) -> LodFade {
        guard lod != currentLod else { return self }
        var next = self
        next.previousLod = currentLod
        next.currentLod = lod
        next.startedAt = now
        return next
    }

    /// Drop the outgoing LOD once the fade has completed.
    public func settled(at now: Double) -> LodFade {
        guard isComplete(at: now), previousLod != nil else { return self }
        var next = self
        next.previousLod = nil
        return next
    }
}
