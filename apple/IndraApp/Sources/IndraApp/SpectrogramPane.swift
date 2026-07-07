// Metal spectrogram pane (BUILD_SPEC §5.3, ADR 0013): controls row, the
// MTKView canvas, and a SwiftUI-Canvas overlay for playhead / selection /
// magic-selection ribbons / curve lanes. Overlays live in a SwiftUI layer
// (not the Metal pass) — see ADR 0013 for the trade-off; both layers derive
// every coordinate from the same Viewport value, so they cannot drift.
// USER-SMOKE-TESTED ONLY — see docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI) && canImport(MetalKit)

    import IndraKitCore
    import SwiftUI

    @MainActor
    struct SpectrogramPane: View {
        let file: AudioFile
        let spec: SpecManifest
        var playheadTime: Double
        var onSeek: (Double) -> Void
        /// Rendered audition WAV ready — play it (PlaybackController.playScratch).
        var onAuditionReady: (URL) -> Void = { _ in }
        /// EQ quick-preview engage/clear while an audition renders (§5.5).
        var onPreviewBand: (Double?, Double?) -> Void = { _, _ in }
        /// Start the transport if idle so the quick preview is audible.
        var onPreviewPlay: () -> Void = {}

        @Environment(AppModel.self) private var model
        @State private var canvas: SpectroCanvasModel?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let canvas {
                    SpectroControls(canvas: canvas, features: model.manifest?.features ?? [])
                    if model.manifest?.features.contains("onsets_superflux_pcen") == true {
                        OnsetControls(canvas: canvas)
                    }
                    ZStack {
                        SpectroMetalView(canvas: canvas)
                        SpectroOverlayView(
                            canvas: canvas,
                            selection: model.editor.selection,
                            playheadTime: playheadTime,
                            committedOnsets: model.editor.annotations
                                .filter { $0.label == "onset" && $0.t0 == $0.t1 }
                                .map(\.t0)
                        )
                        .allowsHitTesting(false)
                    }
                    .frame(minHeight: 340)
                    .clipped()
                    if let error = canvas.renderer.initError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let message = canvas.auditionStatus ?? canvas.similarStatus
                        ?? canvas.magicStatus ?? canvas.status
                    {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let result = canvas.similarResult {
                        ConstellationView(canvas: canvas, result: result)
                    }
                } else {
                    ZStack {
                        Color.black.opacity(0.05)
                        Text("Preparing Metal canvas…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 340)
                }
            }
            .task(id: file.id) {
                setUpCanvas()
            }
            .onChange(of: model.editor.lensesEnabled) { _, enabled in
                canvas?.setEnabledLanes(enabled.sorted())
            }
            .onChange(of: model.editor.magicSelectionId) { _, id in
                // ⌘Z/⇧⌘Z of the magic selection (§5.7) lands here.
                canvas?.syncMagicSelection(to: id)
            }
            .onDisappear {
                canvas?.cancelAllWork()
            }
        }

        private func setUpCanvas() {
            guard let client = model.backend.client else { return }
            canvas?.cancelAllWork()  // superseded canvas must not keep fetching
            let next = SpectroCanvasModel(file: file, spec: spec, client: client)
            // Selection drags coalesce into ONE undo step (§5.7) through
            // AppModel's DocumentStore passthroughs.
            next.onSelectionDragBegin = { [weak model] selection in
                model?.beginSelectionDrag(selection)
            }
            next.onSelectionDragUpdate = { [weak model] selection in
                model?.updateSelectionDrag(selection)
            }
            next.onSelectionDragEnd = { [weak model] in
                model?.endSelectionDrag()
            }
            next.onSeek = onSeek
            next.onAuditionReady = onAuditionReady
            next.onPreviewBand = onPreviewBand
            next.onPreviewPlay = onPreviewPlay
            next.onMagicSelectionChanged = { [weak model] id in
                model?.dispatch(.setMagicSelection(id))
            }
            next.onOnsetsCommitted = { [weak model] in
                Task { await model?.reloadAnnotations() }
            }
            next.projectRoot = model.projectRoot
            next.setEnabledLanes(model.editor.lensesEnabled.sorted())
            canvas = next
        }
    }

    /// Colormap / frequency-scale / magic-select / lane controls + HUD.
    @MainActor
    private struct SpectroControls: View {
        let canvas: SpectroCanvasModel
        let features: [String]
        @Environment(AppModel.self) private var model

        var body: some View {
            HStack(spacing: 10) {
                Picker(
                    "Colors",
                    selection: Binding(
                        get: { canvas.colormap },
                        set: { canvas.setColormap($0) })
                ) {
                    ForEach(Colormap.allCases, id: \.self) { map in
                        Text(map.rawValue).tag(map)
                    }
                }
                .fixedSize()

                Picker(
                    "Scale",
                    selection: Binding(
                        get: { canvas.frequencyScale },
                        set: { canvas.setFrequencyScale($0) })
                ) {
                    Text("Linear").tag(FrequencyScale.linear)
                    Text("Log").tag(FrequencyScale.logarithmic)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Button("Fit") { canvas.zoomToFit() }
                    .help("Zoom out to the whole file")

                Button("Magic select") {
                    canvas.magicSelectFromSelection(model.editor.selection)
                }
                .help("Region-grow from the selection box (⌥-click seeds a point)")
                .disabled(model.editor.selection?.f0 == nil)

                if canvas.magicSelection != nil {
                    Text("±dB")
                        .font(.caption)
                    Slider(
                        value: Binding(
                            get: { canvas.magicToleranceDb },
                            set: { canvas.setMagicTolerance($0) }),
                        in: 2...24
                    )
                    .frame(width: 90)
                    .help("Live tolerance: re-grows from the same seed (ux §1)")

                    Button("Clear ribbons") { canvas.clearMagicSelection() }
                        .buttonStyle(.borderless)
                }

                Button("Audition") {
                    canvas.audition(selection: model.editor.selection)
                }
                .help("Hear the magic selection (or the drag box) in isolation — §5.5")
                .disabled(canvas.magicSelection == nil && model.editor.selection == nil)

                Menu("Feather") {
                    Picker(
                        "Frequency edge",
                        selection: Binding(
                            get: { canvas.auditionFadeHz },
                            set: { canvas.auditionFadeHz = $0 })
                    ) {
                        Text("Hard (10 Hz)").tag(10.0)
                        Text("Default (50 Hz)").tag(50.0)
                        Text("Soft (150 Hz)").tag(150.0)
                    }
                    Picker(
                        "Time edge",
                        selection: Binding(
                            get: { canvas.auditionFadeMs },
                            set: { canvas.auditionFadeMs = $0 })
                    ) {
                        Text("Hard (5 ms)").tag(5.0)
                        Text("Default (15 ms)").tag(15.0)
                        Text("Soft (40 ms)").tag(40.0)
                    }
                }
                .fixedSize()
                .help("Audition edge softness — what you hear at the selection's borders")

                Button("Find similar") {
                    canvas.findSimilar(selection: model.editor.selection)
                }
                .help("Search every imported file for this sound (constellation view)")
                .disabled(model.editor.selection == nil)

                if canvas.similarResult != nil {
                    Button("Clear matches") { canvas.clearSimilar() }
                        .buttonStyle(.borderless)
                }

                if !features.isEmpty {
                    Menu("Lanes") {
                        ForEach(features, id: \.self) { kind in
                            Toggle(
                                kind,
                                isOn: Binding(
                                    get: { model.editor.lensesEnabled.contains(kind) },
                                    set: { _ in model.dispatch(.toggleLens(kind)) }))
                        }
                    }
                    .fixedSize()
                }

                Spacer()

                Text(hud)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        private var hud: String {
            let viewport = canvas.viewport
            return String(
                format: "%@ – %@ · LOD %ld",
                TransportView.clock(viewport.t0), TransportView.clock(viewport.t1),
                canvas.displayLod)
        }
    }

    /// Onset lane controls (ux §5): show/hide the detected layer, a live
    /// sensitivity slider (each tick re-picks the SAVED envelope — no
    /// recomputation), and one-undo-step commit to the annotation layer.
    @MainActor
    private struct OnsetControls: View {
        let canvas: SpectroCanvasModel

        var body: some View {
            HStack(spacing: 10) {
                if canvas.pickedOnsets == nil {
                    Button("Show onsets") { canvas.repickOnsets(delta: nil) }
                        .help("Overlay the detected onsets (re-pickable, non-destructive)")
                } else {
                    Button("Hide onsets") { canvas.hideOnsets() }
                        .buttonStyle(.borderless)

                    Text("Sensitivity")
                        .font(.caption)
                    // Bound to the model (single source of truth): after
                    // Hide → Show, slider and pick agree again.
                    Slider(
                        value: Binding(
                            get: { canvas.onsetDelta ?? 0.07 },  // PICK_DEFAULTS delta
                            set: { canvas.repickOnsets(delta: $0) }),
                        in: 0.01...0.6
                    )
                    .frame(width: 140)
                    .help("Batch re-threshold: delta on the [0,1] envelope; lower = more onsets")

                    Button("Commit \(canvas.pickedOnsets?.n ?? 0) onsets") {
                        canvas.commitPickedOnsets()
                    }
                    .help("Materialize as point annotations — one server undo step (History panel)")
                    .disabled((canvas.pickedOnsets?.n ?? 0) == 0)
                }

                if let status = canvas.onsetStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    /// Overlay layer: playhead, selection rectangle, magic-selection ribbons,
    /// onset ticks/hairlines, and curve lanes. Observable reads happen in
    /// `body` (tracked); the Canvas closure only uses the captured values.
    @MainActor
    private struct SpectroOverlayView: View {
        let canvas: SpectroCanvasModel
        var selection: Selection?
        var playheadTime: Double
        /// Committed onset annotations (label "onset", t0 == t1), in seconds.
        var committedOnsets: [Double] = []

        private static let laneHeight: CGFloat = 44
        private static let laneColors: [Color] = [.cyan, .orange, .green, .pink, .yellow]

        var body: some View {
            let viewport = canvas.viewport
            let scale = canvas.frequencyScale
            let ribbons = canvas.magicSelection
            let lanes = canvas.lanes
            let picked = canvas.pickedOnsets
            let committed = committedOnsets
            let selection = selection
            let playhead = playheadTime
            return Canvas { context, size in
                guard viewport.width > 0, viewport.height > 0 else { return }
                // The overlay and the MTKView share the same Viewport but may
                // disagree on size for one layout tick; scale defensively.
                let fx = size.width / CGFloat(viewport.width)
                let fy = size.height / CGFloat(viewport.height)

                drawRibbons(ribbons, viewport, scale, fx, fy, &context)
                drawLanes(lanes, size, &context)
                drawOnsets(picked, committed, viewport, fx, size, &context)
                drawSelection(selection, viewport, scale, fx, fy, size, &context)
                drawPlayhead(playhead, viewport, fx, size, &context)
            }
        }

        private func drawRibbons(
            _ magic: MagicSelection?, _ viewport: Viewport, _ scale: FrequencyScale,
            _ fx: CGFloat, _ fy: CGFloat, _ context: inout GraphicsContext
        ) {
            guard let magic else { return }
            var path = Path()
            for rect in magic.rects(in: viewport, scale: scale).prefix(20_000) {
                path.addRect(
                    CGRect(
                        x: CGFloat(rect.x) * fx, y: CGFloat(rect.y) * fy,
                        width: max(CGFloat(rect.width) * fx, 1),
                        height: max(CGFloat(rect.height) * fy, 1)))
            }
            context.fill(path, with: .color(.orange.opacity(0.3)))
        }

        private func drawSelection(
            _ selection: Selection?, _ viewport: Viewport, _ scale: FrequencyScale,
            _ fx: CGFloat, _ fy: CGFloat, _ size: CGSize, _ context: inout GraphicsContext
        ) {
            guard let selection else { return }
            let x0 = CGFloat(viewport.timeToX(selection.t0)) * fx
            let x1 = CGFloat(viewport.timeToX(selection.t1)) * fx
            var y0: CGFloat = 0
            var y1: CGFloat = size.height
            if let f0 = selection.f0, let f1 = selection.f1 {
                y0 = CGFloat(viewport.freqToY(f1, scale: scale)) * fy
                y1 = CGFloat(viewport.freqToY(f0, scale: scale)) * fy
            }
            let rect = CGRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1))
            context.fill(Path(rect), with: .color(.accentColor.opacity(0.12)))
            context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1)
        }

        /// Two-layer onset display (ux §5): DETECTED (regenerable pick) as
        /// short top ticks with strength-scaled stems; COMMITTED (user-owned
        /// annotations) as full-height hairlines. Visually distinct so a
        /// re-threshold never appears to touch the user's layer.
        private func drawOnsets(
            _ picked: OnsetRepickResult?, _ committed: [Double],
            _ viewport: Viewport, _ fx: CGFloat, _ size: CGSize,
            _ context: inout GraphicsContext
        ) {
            if let picked {
                var ticks = Path()
                let maxStrength = max(picked.onsets.strength.max() ?? 1, 1e-9)
                for (index, t) in picked.onsets.t.enumerated() {
                    guard t >= viewport.t0, t <= viewport.t1 else { continue }
                    let x = CGFloat(viewport.timeToX(t)) * fx
                    let strength = index < picked.onsets.strength.count
                        ? picked.onsets.strength[index] / maxStrength : 0.5
                    let stem = 14 + CGFloat(strength) * 26
                    ticks.move(to: CGPoint(x: x, y: 0))
                    ticks.addLine(to: CGPoint(x: x, y: stem))
                }
                context.stroke(ticks, with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
            }
            if !committed.isEmpty {
                var lines = Path()
                for t in committed {
                    guard t >= viewport.t0, t <= viewport.t1 else { continue }
                    let x = CGFloat(viewport.timeToX(t)) * fx
                    lines.move(to: CGPoint(x: x, y: 0))
                    lines.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(lines, with: .color(.mint.opacity(0.55)), lineWidth: 1)
            }
        }

        private func drawPlayhead(
            _ time: Double, _ viewport: Viewport, _ fx: CGFloat, _ size: CGSize,
            _ context: inout GraphicsContext
        ) {
            let x = CGFloat(viewport.timeToX(time)) * fx
            guard x >= 0, x <= size.width else { return }
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.red), lineWidth: 1)
        }

        /// Lanes stack upward from the bottom edge, one band per enabled
        /// feature, min/max envelope per pixel column (CurveLane buckets).
        private func drawLanes(
            _ lanes: [SpectroCanvasModel.FeatureLane], _ size: CGSize,
            _ context: inout GraphicsContext
        ) {
            for (index, lane) in lanes.enumerated() {
                let bottom = size.height - CGFloat(index) * Self.laneHeight
                let top = bottom - Self.laneHeight
                let color = Self.laneColors[index % Self.laneColors.count]
                let columns = lane.buckets.count
                guard columns > 0 else { continue }
                var path = Path()
                let columnWidth = size.width / CGFloat(columns)
                for (column, bucket) in lane.buckets.enumerated() {
                    guard let bucket else { continue }
                    let x = (CGFloat(column) + 0.5) * columnWidth
                    let yHigh = bottom - CGFloat(bucket.max) * Self.laneHeight
                    let yLow = bottom - CGFloat(bucket.min) * Self.laneHeight
                    path.move(to: CGPoint(x: x, y: yHigh))
                    path.addLine(to: CGPoint(x: x, y: max(yLow, yHigh + 0.5)))
                }
                context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1)
                context.draw(
                    Text(lane.kind).font(.caption2).foregroundStyle(color),
                    at: CGPoint(x: 6, y: top + 4), anchor: .topLeading)
            }
        }
    }

#endif
