// Tile request planning for the Metal tile renderer (BUILD_SPEC §5.3):
// pick the LOD whose columns-per-pixel is ~1 (at least 1 column per pixel,
// less than 2 — never blurrier than the screen), then emit TileKeys covering
// the visible range plus a read-ahead margin (§5.1), quantized to a fixed
// tile width so keys are stable under pan and cache-friendly (TileCache).
//
// Pure functions — deterministic, no side effects, allocation-light.

/// Namespace for viewport → tile-request planning.
public enum TilePlanner {
    /// Tile width in spectrogram columns (matches the 512-wide atlas tiles
    /// of BUILD_SPEC §5.3).
    public static let defaultTileColumns = 512
    /// Tile width in waveform buckets.
    public static let defaultTileBuckets = 512
    /// Read-ahead margin as a fraction of the visible time span, applied on
    /// each side (0.5 → half a viewport of margin left and right).
    public static let defaultMargin = 0.5

    // MARK: - Spectrogram LOD selection

    /// LOD for a viewport: `clamp(floor(log2(framesVisible / pixelWidth)), 0, maxLod)`
    /// where `framesVisible = (t1 - t0) * sr / hop` (LOD-0 STFT frames). This
    /// yields 1–2 columns per pixel at the chosen LOD.
    public static func specLod(for viewport: Viewport, manifest: SpecManifest, sr: Int) -> Int {
        guard sr > 0, manifest.hop > 0 else { return 0 }
        let maxLod = manifest.lods.map(\.lod).max() ?? 0
        let framesVisible = viewport.timeSpan * Double(sr) / Double(manifest.hop)
        return lodIndex(unitsVisible: framesVisible, pixelWidth: viewport.width, maxLod: maxLod)
    }

    /// Integer `clamp(floor(log2(unitsVisible / pixelWidth)), 0, maxLod)`
    /// computed by exact halving (no floating-point log edge cases).
    static func lodIndex(unitsVisible: Double, pixelWidth: Double, maxLod: Int) -> Int {
        guard pixelWidth > 0, unitsVisible > pixelWidth, maxLod > 0 else { return 0 }
        var lod = 0
        var ratio = unitsVisible / pixelWidth
        while ratio >= 2, lod < maxLod {
            ratio /= 2
            lod += 1
        }
        return lod
    }

    // MARK: - Unit conversions

    /// Column index at a LOD for a time in seconds (floor; negative seconds
    /// yield negative columns — clamp at the call site).
    public static func column(atSeconds seconds: Double, manifest: SpecManifest, lod: SpecLod, sr: Int) -> Int {
        guard sr > 0, manifest.hop > 0, lod.framesPerColumn > 0 else { return 0 }
        let cols = seconds * Double(sr) / Double(manifest.hop * lod.framesPerColumn)
        return Int(cols.rounded(.down))
    }

    /// Start time in seconds of a column at a LOD (inverse of `column(atSeconds:)`).
    public static func seconds(atColumn column: Int, manifest: SpecManifest, lod: SpecLod, sr: Int) -> Double {
        guard sr > 0 else { return 0 }
        return Double(column * manifest.hop * lod.framesPerColumn) / Double(sr)
    }

    /// Bin index for a frequency in Hz, clamped to `[0, nBins - 1]`.
    /// Bin k covers frequency `k * sr / nFft`.
    public static func bin(atHz hz: Double, manifest: SpecManifest, sr: Int) -> Int {
        guard sr > 0, manifest.nFft > 0, manifest.nBins > 0 else { return 0 }
        let bin = Int((hz * Double(manifest.nFft) / Double(sr)).rounded(.down))
        return min(max(bin, 0), manifest.nBins - 1)
    }

    /// Half-open bin range `[lower, upper)` covering `f0..f1` Hz, clamped to
    /// `[0, nBins]` and guaranteed non-empty.
    public static func binRange(f0: Double, f1: Double, manifest: SpecManifest, sr: Int) -> (lower: Int, upper: Int) {
        guard sr > 0, manifest.nFft > 0, manifest.nBins > 0 else { return (0, 1) }
        let hzToBin = Double(manifest.nFft) / Double(sr)
        let lower = min(max(Int((f0 * hzToBin).rounded(.down)), 0), manifest.nBins - 1)
        let upper = min(max(Int((f1 * hzToBin).rounded(.up)), lower + 1), manifest.nBins)
        return (lower, upper)
    }

    // MARK: - Spectrogram tile requests

    /// Tile requests covering the viewport's time range plus `margin` on each
    /// side, at the LOD chosen by `specLod`. Starts are quantized to
    /// `tileColumns`; the last tile is clamped to the file edge. Bounds are
    /// half-open `[t0Col, t1Col, f0Bin, f1Bin]` (api.md `/spec/tile`).
    public static func specTiles(
        audioId: String,
        viewport: Viewport,
        manifest: SpecManifest,
        sr: Int,
        margin: Double = defaultMargin,
        tileColumns: Int = defaultTileColumns
    ) -> [TileKey] {
        specTiles(
            audioId: audioId, viewport: viewport, manifest: manifest, sr: sr,
            lod: specLod(for: viewport, manifest: manifest, sr: sr),
            margin: margin, tileColumns: tileColumns)
    }

    /// Same tile emission at an explicitly chosen LOD. Used by the renderer's
    /// LOD cross-fade (§5.3): during the 100 ms fade the outgoing LOD's tiles
    /// are still planned/drawn even though `specLod` already picks the new one.
    public static func specTiles(
        audioId: String,
        viewport: Viewport,
        manifest: SpecManifest,
        sr: Int,
        lod lodValue: Int,
        margin: Double = defaultMargin,
        tileColumns: Int = defaultTileColumns
    ) -> [TileKey] {
        guard sr > 0, manifest.hop > 0, tileColumns > 0, viewport.timeSpan > 0,
            !manifest.lods.isEmpty
        else { return [] }
        guard let lod = manifest.lods.first(where: { $0.lod == lodValue }) ?? manifest.lods.last,
            lod.frames > 0, lod.framesPerColumn > 0
        else { return [] }

        let marginSeconds = viewport.timeSpan * max(margin, 0)
        let c0 = max(0, column(atSeconds: viewport.t0 - marginSeconds, manifest: manifest, lod: lod, sr: sr))
        let colsEnd = (viewport.t1 + marginSeconds) * Double(sr) / Double(manifest.hop * lod.framesPerColumn)
        let c1 = min(lod.frames, Int(colsEnd.rounded(.up)))
        guard c1 > c0 else { return [] }

        let bins = binRange(f0: viewport.f0, f1: viewport.f1, manifest: manifest, sr: sr)
        var keys: [TileKey] = []
        var start = (c0 / tileColumns) * tileColumns
        keys.reserveCapacity((c1 - start + tileColumns - 1) / tileColumns)
        while start < c1 {
            let end = min(start + tileColumns, lod.frames)
            keys.append(
                TileKey(
                    audioId: audioId, kind: .spec, lod: lod.lod,
                    bounds: [start, end, bins.lower, bins.upper]))
            start += tileColumns
        }
        return keys
    }

    // MARK: - Waveform LOD selection and tile requests

    /// Waveform LOD whose `bucketSamples` yields ~1 bucket per pixel: the
    /// coarsest LOD with `bucketSamples <= samplesPerPixel` (at least one
    /// bucket per pixel), falling back to the finest LOD when zoomed in past
    /// the base bucket size.
    public static func waveformLod(for viewport: Viewport, lods: [WaveformLod], sr: Int) -> Int {
        guard let first = lods.first else { return 0 }
        guard sr > 0, viewport.width > 0 else { return first.lod }
        let samplesPerPixel = viewport.timeSpan * Double(sr) / viewport.width
        var finest = first
        var best: WaveformLod?
        for lod in lods {
            if lod.bucketSamples < finest.bucketSamples { finest = lod }
            if Double(lod.bucketSamples) <= samplesPerPixel,
                lod.bucketSamples > (best?.bucketSamples ?? 0)
            {
                best = lod
            }
        }
        return (best ?? finest).lod
    }

    /// Waveform tile requests covering the viewport plus `margin`, quantized
    /// to `tileBuckets`. Bounds are `[start, count, 0, 0]` (TileCache
    /// convention; api.md `/waveform/tile` takes start/count).
    public static func waveformTiles(
        audioId: String,
        viewport: Viewport,
        lods: [WaveformLod],
        sr: Int,
        margin: Double = defaultMargin,
        tileBuckets: Int = defaultTileBuckets
    ) -> [TileKey] {
        guard sr > 0, tileBuckets > 0, viewport.timeSpan > 0, !lods.isEmpty else { return [] }
        let lodValue = waveformLod(for: viewport, lods: lods, sr: sr)
        guard let lod = lods.first(where: { $0.lod == lodValue }),
            lod.buckets > 0, lod.bucketSamples > 0
        else { return [] }

        let marginSeconds = viewport.timeSpan * max(margin, 0)
        let bucketsPerSecond = Double(sr) / Double(lod.bucketSamples)
        let b0 = max(0, Int(((viewport.t0 - marginSeconds) * bucketsPerSecond).rounded(.down)))
        let b1 = min(lod.buckets, Int(((viewport.t1 + marginSeconds) * bucketsPerSecond).rounded(.up)))
        guard b1 > b0 else { return [] }

        var keys: [TileKey] = []
        var start = (b0 / tileBuckets) * tileBuckets
        keys.reserveCapacity((b1 - start + tileBuckets - 1) / tileBuckets)
        while start < b1 {
            let count = min(tileBuckets, lod.buckets - start)
            keys.append(
                TileKey(audioId: audioId, kind: .waveform, lod: lod.lod, bounds: [start, count, 0, 0]))
            start += tileBuckets
        }
        return keys
    }
}
