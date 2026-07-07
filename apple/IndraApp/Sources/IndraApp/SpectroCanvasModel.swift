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
        /// Tolerance used for the current/next magic select (dB, ux §1).
        private(set) var magicToleranceDb = 8.0
        /// Audition feather controls (§5.5): frequency and time edge softness.
        var auditionFadeHz = 50.0
        var auditionFadeMs = 15.0
        private(set) var auditionStatus: String?
        private(set) var similarResult: SimilarSearchResult?
        private(set) var similarStatus: String?
        /// Live re-picked onsets (detected layer; nil = lane hidden).
        private(set) var pickedOnsets: OnsetRepickResult?
        private(set) var onsetStatus: String?
        /// Sensitivity currently applied (nil = the original detection).
        private(set) var onsetDelta: Double?
        private(set) var status: String?
        private(set) var lanes: [FeatureLane] = []
        /// Project root for resolving the audition job's relative wav_path.
        var projectRoot = ""

        @ObservationIgnored private var atlas = AtlasIndex(capacity: SpectroRenderer.atlasCapacity)
        /// Decoded-tile bytes (64 MB LRU) so atlas evictions re-upload from
        /// memory instead of refetching (§5.1).
        @ObservationIgnored private let tileCache = TileCache(limitBytes: 64 << 20)
        @ObservationIgnored private var inflight: [TileKey: Task<Void, Never>] = [:]
        @ObservationIgnored private var inflightTokens: [TileKey: UUID] = [:]
        @ObservationIgnored private var lodFade: LodFade
        @ObservationIgnored private var laneTask: Task<Void, Never>?
        @ObservationIgnored private var magicTask: Task<Void, Never>?
        @ObservationIgnored private var auditionTask: Task<Void, Never>?
        /// Bumped per audition so a superseded task's preview-clear no-ops.
        @ObservationIgnored private var auditionGeneration = 0
        @ObservationIgnored private var similarTask: Task<Void, Never>?
        @ObservationIgnored private var onsetTask: Task<Void, Never>?
        /// Commit gets its OWN slot: a slider nudge must never cancel the
        /// non-idempotent POST /onsets/commit mid-flight.
        @ObservationIgnored private var commitTask: Task<Void, Never>?
        /// Ribbons per selection id, kept for undo/redo restore (§5.7).
        @ObservationIgnored private var magicSelections: [String: MagicSelection] = [:]
        /// Seed of the most recent magic select — the live tolerance slider
        /// re-grows from the same spot (server-cached per tolerance).
        @ObservationIgnored private var lastMagicSeed: [String: Double]?
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
        /// Start the main transport if idle — makes the quick preview audible.
        @ObservationIgnored var onPreviewPlay: (() -> Void)?
        /// Magic selection committed/cleared — route into undoable state.
        @ObservationIgnored var onMagicSelectionChanged: ((String?) -> Void)?
        /// Picked onsets were committed as annotations — reload the store.
        @ObservationIgnored var onOnsetsCommitted: (() -> Void)?

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
            similarTask?.cancel()
            onsetTask?.cancel()
            // commitTask deliberately NOT cancelled: POST /onsets/commit is
            // non-idempotent; let an in-flight commit finish server-side.
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

        /// Scroll/zoom the time axis to show [t0, t1] with breathing room
        /// (search-result navigation); the frequency window is left alone.
        func revealTime(t0: Double, t1: Double) {
            let pad = max((t1 - t0) * 1.5, 0.5)
            setViewport(
                Viewport(
                    t0: max(0, t0 - pad), t1: min(duration, t1 + pad),
                    f0: viewport.f0, f1: viewport.f1,
                    width: viewport.width, height: viewport.height))
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
                inflightTokens[key] = nil
            }
            for key in keys { ensureTile(key) }
        }

        private func ensureTile(_ key: TileKey) {
            guard !atlas.contains(key), inflight[key] == nil else { return }
            let token = UUID()
            inflightTokens[key] = token
            inflight[key] = Task { [weak self] in
                await self?.fetchTile(key, token: token)
            }
        }

        private func fetchTile(_ key: TileKey, token: UUID) async {
            defer {
                // Token guard: a cancelled fetch's teardown must not clobber a
                // NEWER task's inflight entry (would allow duplicate fetches).
                if inflightTokens[key] == token {
                    inflight[key] = nil
                    inflightTokens[key] = nil
                }
            }
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
                    let raw = CurveLane.buckets(from: series, viewport: target)
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
            lastMagicSeed = seed
            magicTask?.cancel()
            magicStatus = "Magic select running…"
            magicTask = Task { [weak self] in
                await self?.runMagicSelect(seed: seed)
            }
        }

        /// Live tolerance (ux §1): re-grow from the SAME seed at a new
        /// tolerance. Debounced; each tolerance is a distinct cache key
        /// server-side, so scrubbing back and forth is instant on revisits.
        func setMagicTolerance(_ toleranceDb: Double) {
            magicToleranceDb = toleranceDb
            guard let seed = lastMagicSeed else { return }
            magicTask?.cancel()
            magicStatus = String(format: "Re-growing at ±%.0f dB…", toleranceDb)
            magicTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                await self?.runMagicSelect(seed: seed)
            }
        }

        func clearMagicSelection() {
            magicSelection = nil
            magicStatus = nil
            onMagicSelectionChanged?(nil)
        }

        // MARK: - Job following (shared by magic select / audition / search)

        /// A followed job's terminal outcome: result_ref, or the status line.
        enum JobOutcome {
            case success([String: JSONValue])
            case failure(String)
        }

        /// Follow a submitted job to its terminal event.
        private func awaitResultRef(jobId: String) async throws -> JobOutcome {
            for try await event in client.jobEvents(id: jobId) {
                guard event.isTerminal else { continue }
                if event.name == "done", let ref = event.job.resultRef {
                    return .success(ref)
                }
                return .failure("\(event.name): \(event.job.message)")
            }
            return .failure("stream ended without a terminal event")
        }

        // MARK: - Audition (§5.5): hear the selection in isolation

        /// Audition the current magic selection (preferred) or the drag
        /// selection rectangle. The §5.5 quick preview engages immediately —
        /// EQ band-pass over the ORIGINAL, seeked to the selection start and
        /// playing — and the exact backend render (STFT → feathered mask →
        /// ISTFT) replaces it when the job lands. Identical requests are
        /// params-hash cached server-side, so replays start instantly.
        func audition(selection: Selection?) {
            let mode: AuditionMode
            var band: (lo: Double, hi: Double)?
            var startTime: Double?
            // Feather (§5.5): omit defaults so the common case shares the
            // server cache entry with parameterless requests.
            let fadeHz: Double? = auditionFadeHz == 50 ? nil : auditionFadeHz
            let fadeMs: Double? = auditionFadeMs == 15 ? nil : auditionFadeMs
            if let magic = magicSelection {
                mode = .selection(id: magic.selectionId, fadeHz: fadeHz, fadeMs: fadeMs)
                band = magic.frequencyBounds
                startTime = magic.timeBounds?.t0
            } else if let selection {
                var mask: [String: Double] = [
                    "t0": min(selection.t0, selection.t1),
                    "t1": max(selection.t0, selection.t1),
                ]
                if let f0 = selection.f0, let f1 = selection.f1 {
                    mask["f0"] = min(f0, f1)
                    mask["f1"] = max(f0, f1)
                    band = (min(f0, f1), max(f0, f1))
                }
                if let fadeHz { mask["fade_hz"] = fadeHz }
                if let fadeMs { mask["fade_ms"] = fadeMs }
                mode = .mask(mask)
                startTime = min(selection.t0, selection.t1)
            } else {
                auditionStatus = "Nothing to audition — drag a box or magic-select first."
                return
            }
            let generation = beginAudition(status: "Rendering audition… (EQ preview playing)")
            onPreviewBand?(band?.lo, band?.hi)
            if let startTime { onSeek?(startTime) }
            onPreviewPlay?()
            auditionTask = Task { [weak self] in
                await self?.runAudition(mode: mode, generation: generation)
            }
        }

        /// Audition ONE search-result segment — possibly from another file.
        func auditionSegment(_ index: Int) {
            guard let segments = similarResult?.segments, segments.indices.contains(index)
            else { return }
            let segment = segments[index]
            let targetId = segment.audioId ?? file.id
            let generation = beginAudition(status: "Rendering segment audition…")
            auditionTask = Task { [weak self] in
                await self?.runAudition(
                    mode: .segments([[segment.t0, segment.t1]]), generation: generation,
                    audioId: targetId)
            }
        }

        /// Audition several search-result segments as one crossfaded sequence
        /// (the lasso's "contact sheet" — ux §3). The render is per-file, so
        /// the file holding the most lassoed segments wins (ties: seed file,
        /// then lexicographic — deterministic); others are counted in the
        /// status rather than silently dropped.
        func auditionSegments(_ indices: [Int]) {
            guard let segments = similarResult?.segments else { return }
            let chosen = indices.filter { segments.indices.contains($0) }
            guard !chosen.isEmpty else { return }
            let groups = Dictionary(grouping: chosen) { segments[$0].audioId ?? file.id }
            let seedId = file.id
            guard
                let (targetId, group) = groups.min(by: { a, b in
                    if a.value.count != b.value.count { return a.value.count > b.value.count }
                    if (a.key == seedId) != (b.key == seedId) { return a.key == seedId }
                    return a.key < b.key
                })
            else { return }
            let spans = group
                .map { [segments[$0].t0, segments[$0].t1] }
                .sorted { $0[0] < $1[0] }
            let dropped = chosen.count - group.count
            let generation = beginAudition(
                status: dropped > 0
                    ? "Sequencing \(group.count) segments (\(dropped) in other files skipped)…"
                    : "Sequencing \(group.count) segments…")
            auditionTask = Task { [weak self] in
                await self?.runAudition(
                    mode: .segments(spans), generation: generation, audioId: targetId)
            }
        }

        private func beginAudition(status: String) -> Int {
            auditionTask?.cancel()
            auditionGeneration += 1
            auditionStatus = status
            return auditionGeneration
        }

        private func runAudition(
            mode: AuditionMode, generation: Int, audioId: String? = nil
        ) async {
            defer {
                // Only the newest audition may clear the preview — a
                // superseded task's teardown must not kill its successor's
                // freshly engaged band.
                if generation == auditionGeneration { onPreviewBand?(nil, nil) }
            }
            do {
                let created = try await client.audition(
                    audioId: audioId ?? file.id, mode: mode)
                switch try await awaitResultRef(jobId: created.jobId) {
                case .success(let ref):
                    guard let result = AuditionResult(resultRef: ref) else {
                        auditionStatus = "Audition returned an unexpected payload"
                        return
                    }
                    auditionStatus = "Playing audition render"
                    onAuditionReady?(
                        URL(fileURLWithPath: result.absolutePath(projectRoot: projectRoot)))
                case .failure(let message):
                    auditionStatus = "Audition \(message)"
                }
            } catch is CancellationError {
                // Superseded by a newer audition.
            } catch {
                auditionStatus = "Audition failed: \(error)"
            }
        }

        // MARK: - Similar search + constellation (POST /select/similar, ux §3)

        /// Folder-wide "find this sound everywhere" from the drag selection's
        /// time window. Always requests the embedding — the constellation view
        /// needs coordinates + cluster labels.
        func findSimilar(selection: Selection?) {
            guard let selection else {
                similarStatus = "Drag a time selection first."
                return
            }
            similarTask?.cancel()
            similarStatus = "Searching all files…"
            let t0 = min(selection.t0, selection.t1)
            let t1 = max(selection.t0, selection.t1)
            similarTask = Task { [weak self] in
                await self?.runSimilarSearch(t0: t0, t1: t1)
            }
        }

        func clearSimilar() {
            similarResult = nil
            similarStatus = nil
        }

        private func runSimilarSearch(t0: Double, t1: Double) async {
            do {
                let created = try await client.selectSimilar(
                    audioId: file.id, t0: t0, t1: t1, targets: .all, embed: true)
                switch try await awaitResultRef(jobId: created.jobId) {
                case .success(let ref):
                    guard let result = SimilarSearchResult(resultRef: ref) else {
                        similarStatus = "Search returned an unexpected payload"
                        return
                    }
                    similarResult = result
                    let files = Set(result.segments.compactMap { $0.audioId }).count
                    similarStatus =
                        "\(result.segments.count) matches across \(max(files, 1)) file(s)"
                case .failure(let message):
                    similarStatus = "Search \(message)"
                }
            } catch is CancellationError {
                // Superseded by a newer search.
            } catch {
                similarStatus = "Similar search failed: \(error)"
            }
        }

        private func runMagicSelect(seed: [String: Double]) async {
            do {
                let created = try await client.magicSelect(
                    audioId: file.id, seed: seed, toleranceDb: magicToleranceDb)
                switch try await awaitResultRef(jobId: created.jobId) {
                case .success(let ref):
                    guard let selection = MagicSelection(resultRef: ref) else {
                        magicStatus = "Magic select returned an unexpected payload"
                        return
                    }
                    magicSelections[selection.selectionId] = selection
                    magicSelection = selection
                    let cells = selection.cells.map { " (\($0) cells)" } ?? ""
                    magicStatus = "\(selection.ribbons.count) ribbon slices\(cells)"
                    // §5.7: the magic selection is undoable editor state; the
                    // pane routes this into DocumentStore as .setMagicSelection.
                    onMagicSelectionChanged?(selection.selectionId)
                case .failure(let message):
                    magicStatus = "Magic select \(message)"
                }
            } catch is CancellationError {
                // Superseded by a newer request.
            } catch {
                magicStatus = "Magic select failed: \(error)"
            }
        }

        // MARK: - Onsets (ux §5): detected layer + live re-threshold + commit

        /// Show/re-threshold the detected-onset layer. `delta` nil = the
        /// original detection. POST /onsets/repick re-picks the SAVED envelope
        /// in milliseconds, so this is safe to drive from a live slider —
        /// calls are debounced ~120 ms and superseded ones cancelled.
        func repickOnsets(delta: Double?) {
            onsetDelta = delta
            onsetTask?.cancel()
            onsetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                await self?.runRepick(delta: delta)
            }
        }

        func hideOnsets() {
            onsetTask?.cancel()
            pickedOnsets = nil
            onsetStatus = nil
            onsetDelta = nil
        }

        /// Materialize the current pick as point annotations. Server-side this
        /// is ONE undo step (undoable via the History panel / POST /undo);
        /// the app's local ⌘Z stack is rebuilt by the reload and cannot
        /// carry it — harness trade-off, documented in SMOKE_TESTS.
        func commitPickedOnsets() {
            guard let picked = pickedOnsets, !picked.onsets.t.isEmpty else { return }
            guard commitTask == nil else { return }  // one commit at a time
            onsetStatus = "Committing \(picked.n) onsets…"
            commitTask = Task { [weak self] in
                await self?.runCommit(picked)
                self?.commitTask = nil
            }
        }

        private func runRepick(delta: Double?) async {
            do {
                let result = try await client.onsetsRepick(audioId: file.id, delta: delta)
                pickedOnsets = result
                onsetStatus = "\(result.n) onsets detected"
                requestRedraw?()
            } catch is CancellationError {
                // Superseded by a newer slider position.
            } catch let error as APIError where error.statusCode == 404 {
                onsetStatus = "Run the Onsets analysis first"
            } catch {
                onsetStatus = "Onset re-pick failed: \(error)"
            }
        }

        private func runCommit(_ picked: OnsetRepickResult) async {
            do {
                let committed = try await client.onsetsCommit(
                    audioId: file.id, times: picked.onsets.t,
                    strengths: picked.onsets.strength)
                onsetStatus =
                    "Committed \(committed.created) onsets (one undo step — History panel)"
                onOnsetsCommitted?()
            } catch is CancellationError {
                onsetStatus = "Commit interrupted — Reload from server to verify"
            } catch {
                onsetStatus = "Commit failed: \(error)"
            }
        }

        /// Follow undo/redo of `EditorState.magicSelectionId`: restore the
        /// cached ribbons for that id, or clear. Ids not seen this session
        /// clear with a hint (ribbon geometry is derived data; re-running
        /// magic select re-fetches it from the backend's cache instantly).
        func syncMagicSelection(to id: String?) {
            guard id != magicSelection?.selectionId else { return }
            if let id {
                if let cached = magicSelections[id] {
                    magicSelection = cached
                    magicStatus = "\(cached.ribbons.count) ribbon slices (restored)"
                } else {
                    magicSelection = nil
                    magicStatus = "Magic selection not cached — re-run magic select"
                }
            } else {
                magicSelection = nil
            }
        }
    }

#endif
