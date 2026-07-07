// Metal tile renderer for the spectrogram canvas (BUILD_SPEC §5.3, ADR 0013):
// owns the device, the runtime-compiled shader pipeline, the tile-atlas
// texture (one texture2d_array slice per resident tile), the colormap LUT,
// and the frequency-axis LUT. Deliberately THIN — all geometry/LOD/eviction
// decisions come from IndraKitCore (SpecRenderPlanner, AtlasIndex,
// FrequencyLUT, Colormaps), which is where the CI-tested math lives.
// USER-SMOKE-TESTED ONLY — Metal cannot be exercised headlessly; see
// docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI) && canImport(MetalKit)

    import Foundation
    import IndraKitCore
    import Metal
    import MetalKit
    import QuartzCore

    @MainActor
    final class SpectroRenderer: NSObject {
        /// Atlas slices (128 × ~1 MB full-height tiles ≈ 128 MB, inside the
        /// §4.7 256 MB steady-state texture budget).
        static let atlasCapacity = 128

        let device: MTLDevice?
        /// Non-nil when Metal setup failed; the pane surfaces it.
        private(set) var initError: String?
        weak var model: SpectroCanvasModel?

        private var commandQueue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var atlasTexture: MTLTexture?
        /// Bin count the atlas was sized for (slice width).
        private var atlasBins = 0
        private var colormapTexture: MTLTexture?
        private var uploadedColormap: Colormap?
        private var lutTexture: MTLTexture?

        override init() {
            device = MTLCreateSystemDefaultDevice()
            super.init()
            buildPipeline()
        }

        // MARK: - Pipeline (runtime shader compilation, ADR 0013)

        private func buildPipeline() {
            guard let device else {
                initError = "No Metal device available."
                return
            }
            do {
                // Compiled from source at startup: robust under SwiftPM
                // executable targets, where .metal resource compilation is
                // not reliably wired up (ADR 0013). ~ms, once per launch.
                let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
                guard let vertexFunction = library.makeFunction(name: "indra_tile_vertex"),
                    let fragmentFunction = library.makeFunction(name: "indra_tile_fragment")
                else {
                    initError = "Shader functions missing from library."
                    return
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                // Premultiplied-alpha blending for the LOD cross-fade pass.
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                commandQueue = device.makeCommandQueue()
            } catch {
                initError = "Metal pipeline setup failed: \(error.localizedDescription)"
            }
        }

        // MARK: - Textures

        /// Size the atlas for a file's spectrogram pyramid. Slices are
        /// full-height slabs: nBins wide (bin axis) × 512 tall (time axis) —
        /// exactly the C-order (frames, bins) layout of /spec/tile payloads,
        /// so uploads need no CPU transpose (ADR 0013).
        func configure(spec: SpecManifest) {
            guard let device, spec.nBins != atlasBins, spec.nBins > 0 else { return }
            atlasBins = spec.nBins
            let atlasDescriptor = MTLTextureDescriptor()
            atlasDescriptor.textureType = .type2DArray
            atlasDescriptor.pixelFormat = .r8Unorm
            atlasDescriptor.width = spec.nBins
            atlasDescriptor.height = SpecRenderPlanner.tileRows
            atlasDescriptor.arrayLength = Self.atlasCapacity
            atlasDescriptor.usage = .shaderRead
            atlasTexture = device.makeTexture(descriptor: atlasDescriptor)

            // Both LUTs are height-1 2D textures (not texture1d): 2D linear
            // sampling is uniformly supported, 1D filtering is not.
            let lutDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: FrequencyLUT.defaultCount, height: 1,
                mipmapped: false)
            lutDescriptor.usage = .shaderRead
            lutTexture = device.makeTexture(descriptor: lutDescriptor)

            let colormapDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
            colormapDescriptor.usage = .shaderRead
            colormapTexture = device.makeTexture(descriptor: colormapDescriptor)
            uploadedColormap = nil

            if atlasTexture == nil || lutTexture == nil || colormapTexture == nil {
                initError = "Metal texture allocation failed."
            }
        }

        /// Whether a /spec/tile payload of this shape fits an atlas slice.
        func canUpload(frames: Int, bins: Int) -> Bool {
            atlasTexture != nil && bins == atlasBins && frames > 0
                && frames <= SpecRenderPlanner.tileRows
        }

        /// Upload a uint8 dB slab into atlas slice `slot`. Row f of the slice
        /// is STFT frame f of the tile (see `configure`).
        func uploadTile(_ data: Data, frames: Int, bins: Int, slot: Int) {
            guard let atlasTexture, canUpload(frames: frames, bins: bins),
                slot >= 0, slot < Self.atlasCapacity, data.count >= frames * bins
            else { return }
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                atlasTexture.replace(
                    region: MTLRegionMake2D(0, 0, bins, frames),
                    mipmapLevel: 0, slice: slot,
                    withBytes: base, bytesPerRow: bins, bytesPerImage: 0)
            }
        }

        private func syncColormap(_ colormap: Colormap) {
            guard colormap != uploadedColormap, let colormapTexture else { return }
            let lut = colormap.lut()  // 256 × RGBA8 (IndraKitCore, CI-tested)
            lut.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                colormapTexture.replace(
                    region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: lut.count)
            }
            uploadedColormap = colormap
        }

        private func syncFrequencyLUT(
            viewport: Viewport, scale: FrequencyScale, spec: SpecManifest, sr: Int
        ) {
            guard let lutTexture else { return }
            let values = FrequencyLUT.binFractions(
                viewport: viewport, scale: scale, manifest: spec, sr: sr,
                count: FrequencyLUT.defaultCount)
            guard values.count == FrequencyLUT.defaultCount else { return }
            values.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                lutTexture.replace(
                    region: MTLRegionMake2D(0, 0, values.count, 1), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: buffer.count)
            }
        }

        // MARK: - Drawing

        /// Matches the Metal-side TileUniforms layout: seven 4-byte scalars.
        private struct TileUniforms {
            var x0: Float
            var x1: Float
            var v0: Float
            var v1: Float
            var vMax: Float
            var alpha: Float
            var slot: UInt32
        }

        private func renderScene(in view: MTKView) {
            guard let model, let pipeline, let commandQueue,
                let atlasTexture, let colormapTexture, let lutTexture,
                let drawable = view.currentDrawable,
                let descriptor = view.currentRenderPassDescriptor
            else { return }
            let now = CACurrentMediaTime()
            let frame = model.renderFrame(at: now)
            syncColormap(model.colormap)
            syncFrequencyLUT(
                viewport: model.viewport, scale: model.frequencyScale,
                spec: model.spec, sr: model.file.sr)

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.setFragmentTexture(lutTexture, index: 1)
            encoder.setFragmentTexture(colormapTexture, index: 2)

            let width = max(model.viewport.width, 1)
            for pass in frame.passes {
                for quad in pass.quads {
                    var uniforms = TileUniforms(
                        x0: Float(quad.x0 / width), x1: Float(quad.x1 / width),
                        v0: Float(quad.v0), v1: Float(quad.v1),
                        vMax: Float(quad.vMax), alpha: pass.alpha,
                        slot: UInt32(quad.slot))
                    withUnsafeBytes(of: &uniforms) { raw in
                        encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
                        encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                    }
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()

            // Cross-fade in flight: keep redrawing (the view is on-demand —
            // isPaused/enableSetNeedsDisplay — so poke it at ~60 Hz).
            if frame.animating {
                Task { @MainActor [weak view] in
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    view?.needsDisplay = true
                }
            }
        }

        // MARK: - Shaders (compiled at runtime; ADR 0013)

        /// Tile pass: a unit quad per tile stretched over its screen x range;
        /// the fragment shader remaps screen y → STFT bin through the 1D
        /// frequency LUT (linear/log per Viewport), samples the dB byte from
        /// the atlas slice, and colors it through the 256-entry colormap LUT.
        static let shaderSource = """
            #include <metal_stdlib>
            using namespace metal;

            struct TileUniforms {
                float x0;     // screen x range, normalized 0..1
                float x1;
                float v0;     // time-axis texture range within the slice
                float v1;
                float vMax;   // clamp for partial edge tiles
                float alpha;  // LOD cross-fade opacity
                uint  slot;   // atlas slice
            };

            struct TileVaryings {
                float4 position [[position]];
                float timeV;    // time coordinate within the atlas slice
                float screenV;  // 0 at the top of the canvas, 1 at the bottom
            };

            vertex TileVaryings indra_tile_vertex(
                uint vid [[vertex_id]],
                constant TileUniforms &u [[buffer(0)]])
            {
                bool right = vid >= 2;
                bool bottom = (vid & 1) == 1;
                TileVaryings out;
                float x = right ? u.x1 : u.x0;
                out.position = float4(x * 2.0 - 1.0, bottom ? -1.0 : 1.0, 0.0, 1.0);
                out.timeV = right ? u.v1 : u.v0;
                out.screenV = bottom ? 1.0 : 0.0;
                return out;
            }

            fragment float4 indra_tile_fragment(
                TileVaryings in [[stage_in]],
                constant TileUniforms &u [[buffer(0)]],
                texture2d_array<float> atlas [[texture(0)]],
                texture2d<float> freqLUT [[texture(1)]],
                texture2d<float> colormap [[texture(2)]])
            {
                constexpr sampler s(coord::normalized, address::clamp_to_edge,
                                    filter::linear);
                // Screen row -> bin fraction (linear/log handled CPU-side when
                // the LUT is built from the viewport). LUTs are height-1 2D.
                float binFrac = freqLUT.sample(s, float2(in.screenV, 0.5)).r;
                // Atlas slice: x = bin axis, y = time axis (upload layout).
                float level = atlas.sample(
                    s, float2(binFrac, min(in.timeV, u.vMax)), u.slot).r;
                float4 color = colormap.sample(s, float2(level, 0.5)).rgba;
                return float4(color.rgb * u.alpha, u.alpha);
            }
            """
    }

    extension SpectroRenderer: MTKViewDelegate {
        // MTKViewDelegate is a nonisolated protocol; with the view configured
        // for on-demand drawing both callbacks arrive on the main thread, so
        // hopping back onto the main actor is safe (and asserted).
        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated {
                model?.setCanvasSize(
                    width: Double(view.bounds.width), height: Double(view.bounds.height))
            }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                renderScene(in: view)
            }
        }
    }

#endif
