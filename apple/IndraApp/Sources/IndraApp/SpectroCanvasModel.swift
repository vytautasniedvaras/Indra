// State + orchestration for the Metal spectrogram canvas (BUILD_SPEC §5.3,
// ADR 0013): owns the Viewport (scene state — never undoable, ADR 0009),
// drives tile fetches through APIClient + TileCache into the renderer's
// atlas, plans each frame via SpecRenderPlanner (with LOD cross-fade), runs
// magic selection (POST /select/magic) and fetches curve-lane buckets. All
// formulas live in IndraKitCore; this class is glue. USER-SMOKE-TESTED ONLY —
// not CI-verifiable; see docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI) && canImport(MetalKit)

    import Foundation
    import IndraKitCore
    import IndraKitNet
    import Observation

    @MainActor
    @Observable
    final class SpectroCanvasModel {
        let file: AudioFile
        let spec: SpecManifest
        let renderer: SpectroRenderer
        private let client: APIClient

        /// Visible window. Observed by the SwiftUI overlay so it stays in
        /// lockstep with the Metal pass (both read the same value per frame).
        private(set) var viewport: Viewport
        private(set) var frequencyScale: FrequencyScale = .linear
        private(set) var colormap: Colormap = .viridis
        /// LOD currently drawn (HUD display; updated during draw).
        private(set) var displayLod = 0
        private(set) var magicSelection: MagicSelection?
        private(set) var magicStatus: String?
        private(set) var auditionStatus: String?
        private(set) var status: String?
        private(set) var lanes: [FeatureLane] = []
        /// Project root for resolving the audition job's relative wav_path.
        var projectRoot = ""

        @ObservationIgnored private var atlas = AtlasIndex(capacity: SpectroRenderer.atlasCapacity)
        /// Decoded-tile bytes (64 MB LRU) so atlas evictions re-upload from
        /// memory instead of refetching (§5.1).
        @ObservationIgnored private let tileCache = TileCache(limitBytes: 64 << 20)
        @ObservationIgnored private var inflight: [TileKey: Task<Void, Never>] = [:]
        @ObservationIgnored private var lodFade: LodFade
        @ObservationIgnored private var laneTask: Task<Void, Never>?
        @ObservationIgnored private var magicTask: Task<Void, Never>?
        @ObservationIgnored private var auditionTask: Task<Void, Never>?
        @ObservationIgnored private var enabledLaneKinds: [String] = []
        /// Selection-drag anchor in (seconds, Hz).
        @ObservationIgnored private var dragAnchor: (t: Double, f: Double)?

        /// Set by the hosting view: pokes the on-demand MTKView.
        @ObservationIgnored var requestRedraw: (() -> Void)?
        /// Selection-drag hooks, wired to AppModel's coalesced drag (§5.7).
        @ObservationIgnored var onSelectionDragBegin: ((Selection) -> Void)?
        @ObservationIgnored var onSelectionDragUpdate: ((Selection) -> Void)?
        @ObservationIgnored var onSelectionDragEnd: (() -> Void)?
        /// Plain click = seek (seconds).
        @ObservationIgnored var onSeek: ((Double) -> Void)?
        /// Rendered audition WAV is ready to play (absolute file URL).
        @ObservationIgnored var onAuditionReady: ((URL) -> Void)?
        /// Engage/clear the EQ quick preview while the render is in flight
        /// (§5.5): non-nil f0/f1 = engage band, (nil, nil) = clear.
        @ObservationIgnored var onPreviewBand: ((Double?, Double?) -> Void)?

        struct FeatureLane: Identifiable {
            var kind: String
            /// Lane-normalized (0..1) min/max per visible pixel column.
            var buckets: [CurveBucket?]
            var id: String { kind }
        }

        var duration: Double { file.durationS }
        var nyquist: Double { Double(file.sr) / 2 }

        init(file: AudioFile, spec: SpecManifest, client: APIClient) {
            self.file = file
            self.spec = spec
            self.client = client
            self.renderer = SpectroRenderer()
            self.viewport = Viewport(
                t0: 0, t1: max(file.durationS, Viewport.minTimeSpan),
                f0: 0, f1: max(Double(file.sr) / 2, Viewport.minFrequencySpan),
                width: 800, height: 400)
            self.lodFade = LodFade(lod: 0)
            renderer.model = self
            renderer.configure(spec: spec)
            self.lodFade = LodFade(
                lod: TilePlanner.specLod(for: viewport, manifest: spec, sr: file.sr))
            refreshTiles()
        }

        func cancelAllWork() {
            for task in inflight.values { task.cancel() }
            inflight.removeAll()
            laneTask?.cancel()
            magicTask?.cancel()
            auditionTask?.cancel()
        }

        // MARK: - Viewport changes (gestures + layout)

        func setCanvasSize(width: Double, height: Double) {
            guard width >= 1, height >= 1,
                abs(width - viewport.width) > 0.5 || abs(height - viewport.height) > 0.5
            else { return }
            viewport = Viewport(
                t0: viewport.t0, t1: viewport.t1, f0: viewport.f0, f1: viewport.f1,
                width: width, height: height)
            viewportDidChange()
        }

        /// Two-finger scroll: x pans time, y pans frequency (deltas in px).
        func panBy(deltaX: Double, deltaY: Double) {
            var next = viewport
            if deltaX != 0 {
                next = next.pannedTime(
                    bySeconds: -deltaX / next.width * next.timeSpan, duration: duration)
            }
            if deltaY != 0 {
                next = next.pannedFrequency(
                    byHz: deltaY / next.height * next.frequencySpan, maxFrequency: nyquist)
            }
            setViewport(next)
        }

        /// Pinch: zoom time anchored at the cursor (anchor-fixed math is in
        /// Viewport.zoomedTime — BUILD_SPEC §5.3 gestures).
        func zoomTime(by factor: Double, atX x: Double) {
            setViewport(
                viewport.zoomedTime(by: factor, anchorT: viewport.xToTime(x), duration: duration))
        }

        /// Option-pinch: zoom frequency anchored at the cursor.
        func zoomFrequency(by factor: Double, atY y: Double) {
            setViewport(
                viewport.zoomedFrequency(
                    by: factor, anchorF: viewport.yToFreq(y, scale: frequencyScale),
                    maxFrequency: nyquist))
        }

        func zoomToFit() {
            setViewport(
                Viewport(
                    t0: 0, t1: max(duration, Viewport.minTimeSpan), f0: 0,
                    f1: max(nyquist, Viewport.minFrequencySpan),
                    width: viewport.width, height: viewport.height))
        }

        func setColormap(_ newValue: Colormap) {
            guard newValue != colormap else { return }
            colormap = newValue
            requestRedraw?()  // palette switch is free — LUT swap only (§5.3)
        }

        func setFrequencyScale(_ newValue: FrequencyScale) {
            guard newValue != frequencyScale else { return }
            frequencyScale = newValue
            requestRedraw?()  // in-shader remap; tiles and keys are unchanged
        }

        private func setViewport(_ next: Viewport) {
            guard next != viewport else { return }
            viewport = next
            viewportDidChange()
        }

        private func viewportDidChange() {
            refreshTiles()
            scheduleLaneRefresh()
            requestRedraw?()
        }

        // MARK: - Selection drag + click (wired from SpectroMTKView)

        func selectionDragBegan(atX x: Double, y: Double) {
            let anchor = (t: viewport.xToTime(x), f: viewport.yToFreq(y, scale: frequencyScale))
            dragAnchor = anchor
            onSelectionDragBegin?(
                Selection(t0: anchor.t, t1: anchor.t, f0: anchor.f, f1: anchor.f))
        }

        func selectionDragMoved(toX x: Double, y: Double) {
            guard let anchor = dragAnchor else { return }
            onSelectionDragUpdate?(
                Selection(
                    t0: anchor.t, t1: viewport.xToTime(x),
                    f0: anchor.f, f1: viewport.yToFreq(y, scale: frequencyScale)))
        }

        func selectionDragEnded() {
            dragAnchor = nil
            onSelectionDragEnd?()
        }

        func clicked(atX x: Double, y: Double, optionDown: Bool) {
            if optionDown {
                // Option-click: point-seeded magic selection (§5, api.md).
                magicSelect(seed: [
                    "t": viewport.xToTime(x),
                    "f": viewport.yToFreq(y, scale: frequencyScale),
                ])
            } else {
                onSeek?(viewport.xToTime(x))
            }
        }

        // MARK: - Frame planning (called by the renderer per draw)

        struct RenderPass {
            var quads: [TileQuad]
            var alpha: Float
        }

        struct FrameData {
            var passes: [RenderPass]
            /// True while a LOD cross-fade is running (keep redrawing).
            var animating: Bool
        }

        func renderFrame(at now: Double) -> FrameData {
            let plan = SpecRenderPlanner.plan(
                audioId: file.id, viewport: viewport, manifest: spec, sr: file.sr,
                resident: atlas.slotsByKey)
            if plan.lod != lodFade.currentLod {
                lodFade = lodFade.retargeted(to: plan.lod, at: now)
            }
            if plan.lod != displayLod { displayLod = plan.lod }
            for key in plan.missing { ensureTile(key) }
            // Keep drawn/wanted tiles hot so LRU eviction targets off-screen ones.
            atlas.markUsed(
                SpecRenderPlanner.fetchKeys(
                    audioId: file.id, viewport: viewport, manifest: spec, sr: file.sr))

            let alpha = lodFade.alpha(at: now)
            var passes: [RenderPass] = []
            if let previous = lodFade.previousLod, alpha < 1 {
                // Outgoing LOD fully opaque underneath, incoming fading in.
                let previousPlan = SpecRenderPlanner.plan(
                    audioId: file.id, viewport: viewport, manifest: spec, sr: file.sr,
                    resident: atlas.slotsByKey, lodOverride: previous)
                passes.append(
                    RenderPass(quads: previousPlan.placeholders + previousPlan.quads, alpha: 1))
                passes.append(RenderPass(quads: plan.quads, alpha: alpha))
            } else {
                lodFade = lodFade.settled(at: now)
                passes.append(RenderPass(quads: plan.placeholders + plan.quads, alpha: 1))
            }
            return FrameData(passes: passes, animating: !lodFade.isComplete(at: now))
        }

        // MARK: - Tile fetching (APIClient → TileCache → atlas)

        private func refreshTiles() {
            let keys = SpecRenderPlanner.fetchKeys(
                audioId: file.id, viewport: viewport, manifest: spec, sr: file.sr)
            let wanted = Set(keys)
            for (key, task) in inflight where !wanted.contains(key) {
                task.cancel()
                inflight[key] = nil
            }
            for key in keys { ensureTile(key) }
        }

        private func ensureTile(_ key: TileKey) {
            guard !atlas.contains(key), inflight[key] == nil else { return }
            inflight[key] = Task { [weak self] in
                await self?.fetchTile(key)
            }
        }

        private func fetchTile(_ key: TileKey) async {
            defer { inflight[key] = nil }
            if let cached = await tileCache.tile(for: key) {
                uploadTile(cached.data, shape: cached.shape, for: key)
                return
            }
            do {
                let tile = try await client.specTile(
                    audioId: key.audioId, lod: key.lod,
                    t0: key.bounds[0], t1: key.bounds[1],
                    f0: key.bounds[2], f1: key.bounds[3])
                guard !Task.isCancelled else { return }
                await tileCache.insert(
                    Tile(data: tile.data, shape: tile.shape, dtype: tile.dtype), for: key)
                uploadTile(tile.data, shape: tile.shape, for: key)
            } catch is CancellationError {
                // Superseded by a newer viewport — silently dropped.
            } catch {
                let message = "Tile fetch failed: \(error)"
                if status != message { status = message }
            }
        }

        private func uploadTile(_ data: Data, shape: [Int], for key: TileKey) {
            guard shape.count >= 2, renderer.canUpload(frames: shape[0], bins: shape[1])
            else { return }
            let allocation = atlas.allocate(key)
            renderer.uploadTile(data, frames: shape[0], bins: shape[1], slot: allocation.slot)
            requestRedraw?()
        }

        // MARK: - Curve lanes (min/max buckets at display width, §5.3/§5.4)

        func setEnabledLanes(_ kinds: [String]) {
            guard kinds != enabledLaneKinds else { return }
            enabledLaneKinds = kinds
            scheduleLaneRefresh(debounced: false)
        }

        private func scheduleLaneRefresh(debounced: Bool = true) {
            laneTask?.cancel()
            guard !enabledLaneKinds.isEmpty else {
                if !lanes.isEmpty { lanes = [] }
                return
            }
            laneTask = Task { [weak self] in
                if debounced {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                guard !Task.isCancelled else { return }
                await self?.refreshLanes()
            }
        }

        private func refreshLanes() async {
            let target = viewport
            let columns = min(Int(target.width), 2000)
            guard columns > 0 else { return }
            var next: [FeatureLane] = []
            for kind in enabledLaneKinds {
                do {
                    let table = try await client.featureTable(
                        audioId: file.id, kind: kind, t0: target.t0, t1: target.t1,
                        downsample: columns)
                    guard
                        let series = table.buckets?["value"]
                            ?? table.columns.first.flatMap({ table.buckets?[$0] })
                    else { continue }
                    // Server buckets → per-pixel min/max via CurveLane: feed
                    // mins and maxs as two sample sets over the same times.
                    let raw = CurveLane.minMaxBuckets(
                        values: (series.min + series.max).map { Float($0) },
                        times: series.t + series.t,
                        viewport: target)
                    next.append(
                        FeatureLane(kind: kind, buckets: CurveLane.normalized(raw)))
                } catch is CancellationError {
                    return
                } catch let error as APIError where error.statusCode == 404 {
                    // Feature not computed yet — lane stays empty until the
                    // analysis job lands.
                } catch {
                    status = "Curve fetch failed (\(kind)): \(error)"
                }
            }
            guard !Task.isCancelled else { return }
            lanes = next
        }

        // MARK: - Magic selection (POST /select/magic → ribbons overlay)

        /// Box-seeded magic select from the current editor selection.
        func magicSelectFromSelection(_ selection: Selection?) {
            guard let selection, let f0 = selection.f0, let f1 = selection.f1 else {
                magicStatus = "Drag a time-frequency box first."
                return
            }
            magicSelect(seed: ["t0": selection.t0, "t1": selection.t1, "f0": f0, "f1": f1])
        }

        func magicSelect(seed: [String: Double]) {
            magicTask?.cancel()
            magicStatus = "Magic select running…"
            magicTask = Task { [weak self] in
                await self?.runMagicSelect(seed: seed)
            }
        }

        func clearMagicSelection() {
            magicSelection = nil
            magicStatus = nil
        }

        // MARK: - Audition (§5.5): hear the selection in isolation

        /// Audition the current magic selection (preferred) or the drag
        /// selection rectangle. Engages the EQ quick preview immediately; the
        /// exact backend render (STFT → feathered mask → ISTFT) replaces it
        /// when the job lands. Identical requests are params-hash cached
        /// server-side, so replays start instantly.
        func audition(selection: Selection?) {
            let mode: AuditionMode
            var previewLow: Double?
            var previewHigh: Double?
            if let magic = magicSelection {
                mode = .selection(id: magic.selectionId)
                let bounds = magic.ribbons.flatMap(\.intervals)
                previewLow = bounds.map(\.fLo).min()
                previewHigh = bounds.map(\.fHi).max()
            } else if let selection {
                var mask: [String: Double] = [
                    "t0": min(selection.t0, selection.t1),
                    "t1": max(selection.t0, selection.t1),
                ]
                if let f0 = selection.f0, let f1 = selection.f1 {
                    mask["f0"] = min(f0, f1)
                    mask["f1"] = max(f0, f1)
                    previewLow = min(f0, f1)
                    previewHigh = max(f0, f1)
                }
                mode = .mask(mask)
            } else {
                auditionStatus = "Nothing to audition — drag a box or magic-select first."
                return
            }
            auditionTask?.cancel()
            auditionStatus = "Rendering audition… (EQ preview approximates it)"
            onPreviewBand?(previewLow, previewHigh)
            auditionTask = Task { [weak self] in
                await self?.runAudition(mode: mode)
            }
        }

        private func runAudition(mode: AuditionMode) async {
            defer { onPreviewBand?(nil, nil) }
            do {
                let created = try await client.audition(audioId: file.id, mode: mode)
                for try await event in client.jobEvents(id: created.jobId) {
                    guard event.isTerminal else { continue }
                    if event.name == "done", let ref = event.job.resultRef,
                        let wavPath = (ref["wavPath"] ?? ref["wav_path"])?.stringValue
                    {
                        let path =
                            wavPath.hasPrefix("/") ? wavPath : projectRoot + "/" + wavPath
                        auditionStatus = "Playing audition render"
                        onAuditionReady?(URL(fileURLWithPath: path))
                    } else {
                        auditionStatus = "Audition \(event.name): \(event.job.message)"
                    }
                    return
                }
            } catch is CancellationError {
                // Superseded by a newer audition.
            } catch {
                auditionStatus = "Audition failed: \(error)"
            }
        }

        private func runMagicSelect(seed: [String: Double]) async {
            do {
                let created = try await client.magicSelect(audioId: file.id, seed: seed)
                for try await event in client.jobEvents(id: created.jobId) {
                    guard event.isTerminal else { continue }
                    if event.name == "done", let ref = event.job.resultRef,
                        let selection = MagicSelection(resultRef: ref)
                    {
                        magicSelection = selection
                        let cells = selection.cells.map { " (\($0) cells)" } ?? ""
                        magicStatus = "\(selection.ribbons.count) ribbon slices\(cells)"
                    } else {
                        magicStatus = "Magic select \(event.name): \(event.job.message)"
                    }
                    return
                }
            } catch is CancellationError {
                // Superseded by a newer request.
            } catch {
                magicStatus = "Magic select failed: \(error)"
            }
        }
    }

#endif
