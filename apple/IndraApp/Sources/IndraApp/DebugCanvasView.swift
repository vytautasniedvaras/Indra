// Debug canvas: CPU-drawn waveform min/max peaks (SwiftUI Canvas) + a CGImage
// spectrogram built from a /spec/tile slab through a local grayscale LUT.
// This is the Phase 3 harness canvas, kept behind FileDetailView's canvas
// toggle as the A/B reference for the Metal tile renderer (BUILD_SPEC §5.3,
// ADR 0013); do NOT grow this into a product surface. USER-SMOKE-TESTED ONLY
// — not CI-verifiable; see docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import CoreGraphics
    import IndraKitCore
    import IndraKitNet
    import SwiftUI

    @MainActor
    struct DebugCanvasView: View {
        let file: AudioFile
        var playheadFraction: Double
        var onSeek: (Double) -> Void

        @Environment(AppModel.self) private var model
        @State private var waveform: WaveformOverview?
        @State private var spectrogram: CGImage?
        @State private var loadError: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Waveform (CPU debug canvas — A/B reference for the Metal renderer)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                waveformCanvas
                    .frame(height: 110)

                Text("Spectrogram (uint8 dB slab, grayscale LUT)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                spectrogramView
                    .frame(height: 220)

                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .task(id: tileLoadKey) {
                await loadTiles()
            }
        }

        /// Re-runs tile loading when the file changes, when its manifest first
        /// arrives, and again once the spec pyramid shows up.
        private var tileLoadKey: String {
            let manifestState =
                model.manifest == nil ? "none" : (model.manifest?.spec == nil ? "nospec" : "spec")
            return "\(file.id)-\(manifestState)"
        }

        // MARK: - Waveform

        private var waveformCanvas: some View {
            GeometryReader { proxy in
                Canvas { context, size in
                    guard let waveform, !waveform.mins.isEmpty else { return }
                    let n = waveform.mins.count
                    let mid = size.height / 2
                    var path = Path()
                    for i in 0..<n {
                        let x = size.width * CGFloat(i) / CGFloat(max(n - 1, 1))
                        let yTop = mid - mid * CGFloat(waveform.maxs[i])
                        let yBottom = mid - mid * CGFloat(waveform.mins[i])
                        path.move(to: CGPoint(x: x, y: yTop))
                        path.addLine(to: CGPoint(x: x, y: max(yBottom, yTop + 0.5)))
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 1)

                    // Center line + playhead.
                    var center = Path()
                    center.move(to: CGPoint(x: 0, y: mid))
                    center.addLine(to: CGPoint(x: size.width, y: mid))
                    context.stroke(center, with: .color(.gray.opacity(0.4)), lineWidth: 0.5)

                    let px = size.width * CGFloat(min(max(playheadFraction, 0), 1))
                    var playhead = Path()
                    playhead.move(to: CGPoint(x: px, y: 0))
                    playhead.addLine(to: CGPoint(x: px, y: size.height))
                    context.stroke(playhead, with: .color(.red), lineWidth: 1)
                }
                .background(Color.black.opacity(0.05))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard proxy.size.width > 0 else { return }
                    onSeek(min(max(Double(location.x / proxy.size.width), 0), 1))
                }
            }
        }

        // MARK: - Spectrogram

        private var spectrogramView: some View {
            Group {
                if let spectrogram {
                    Image(decorative: spectrogram, scale: 1)
                        .resizable()
                        .frame(maxWidth: .infinity)
                } else {
                    ZStack {
                        Color.black.opacity(0.05)
                        Text(
                            model.manifest?.spec == nil
                                ? "No spectrogram pyramid yet (ingest still running?)"
                                : "Loading spectrogram…"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        // MARK: - Tile loading

        private func loadTiles() async {
            guard let client = model.backend.client, let manifest = model.manifest,
                manifest.id == file.id
            else { return }
            loadError = nil
            do {
                if let lod = Self.pickWaveformLod(manifest.waveformLods) {
                    let tile = try await client.waveformTile(
                        audioId: file.id, lod: lod.lod, start: 0,
                        count: min(lod.buckets, 8192))
                    waveform = WaveformOverview(tile: tile)
                }
                if let spec = manifest.spec, let lod = Self.pickSpecLod(spec.lods) {
                    let tile = try await client.specTile(
                        audioId: file.id, lod: lod.lod, t0: 0,
                        t1: min(lod.frames, 2048))
                    spectrogram = Self.makeSpectrogramImage(tile: tile)
                }
            } catch {
                loadError = "Tile load failed: \(error)"
            }
        }

        /// Finest LOD that still fits a single overview request.
        static func pickWaveformLod(_ lods: [WaveformLod]) -> WaveformLod? {
            lods.filter { $0.buckets <= 8192 }.max { $0.buckets < $1.buckets }
                ?? lods.min { $0.buckets < $1.buckets }
        }

        /// Finest spec LOD whose full-height slab stays under the 8 MiB cap
        /// (2048 frames × 2049 bins ≈ 4.2 MB).
        static func pickSpecLod(_ lods: [SpecLod]) -> SpecLod? {
            lods.filter { $0.frames <= 2048 }.max { $0.frames < $1.frames }
                ?? lods.min { $0.frames < $1.frames }
        }

        // MARK: - Pixel plumbing

        /// Local 256-entry grayscale LUT. Deliberately NOT dependent on any
        /// IndraKit colormap — swap in viridis when IndraKitCore ships one.
        static let grayscaleLUT: [(r: UInt8, g: UInt8, b: UInt8)] =
            (0..<256).map { (r: UInt8($0), g: UInt8($0), b: UInt8($0)) }

        /// (frames, bins) row-major uint8 dB slab → RGBA CGImage with low
        /// frequencies at the bottom.
        static func makeSpectrogramImage(tile: TileResponse) -> CGImage? {
            guard tile.shape.count >= 2 else { return nil }
            let frames = tile.shape[0]
            let bins = tile.shape[1]
            guard frames > 0, bins > 0, tile.data.count >= frames * bins else { return nil }
            let bytes = [UInt8](tile.data)
            let lut = grayscaleLUT
            var pixels = [UInt8](repeating: 255, count: frames * bins * 4)
            for y in 0..<bins {
                let bin = bins - 1 - y  // flip: bin 0 (low freq) at the bottom
                for x in 0..<frames {
                    let entry = lut[Int(bytes[x * bins + bin])]
                    let offset = (y * frames + x) * 4
                    pixels[offset] = entry.r
                    pixels[offset + 1] = entry.g
                    pixels[offset + 2] = entry.b
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
                return nil
            }
            return CGImage(
                width: frames, height: bins, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: frames * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        }
    }

    /// Parsed waveform overview: per-bucket min/max normalized to -1…1,
    /// channels folded together (min of mins, max of maxes).
    struct WaveformOverview {
        var mins: [Float] = []
        var maxs: [Float] = []

        /// Tile layout per docs/api.md: little-endian int16, C-order
        /// (count, channels, 2) with the last axis (min, max).
        init?(tile: TileResponse) {
            guard tile.shape.count == 3, tile.dtype == "int16" else { return nil }
            let count = tile.shape[0]
            let channels = tile.shape[1]
            let values = count * channels * 2
            guard count > 0, channels > 0, tile.data.count >= values * 2 else { return nil }
            // Little-endian int16 == native byte order on Apple silicon.
            let raw: [Int16] = tile.data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Int16.self).prefix(values))
            }
            mins.reserveCapacity(count)
            maxs.reserveCapacity(count)
            for i in 0..<count {
                var lo = Int16.max
                var hi = Int16.min
                for c in 0..<channels {
                    let base = (i * channels + c) * 2
                    lo = min(lo, raw[base])
                    hi = max(hi, raw[base + 1])
                }
                mins.append(Float(lo) / 32768)
                maxs.append(Float(hi) / 32768)
            }
        }
    }

#endif
