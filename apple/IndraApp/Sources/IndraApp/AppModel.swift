// App-level observable state: files, selection, DocumentStore wrapper
// (BUILD_SPEC §5.7, §7.2), job tracking via SSE (§4.5, §5.6), and raw
// /export access. USER-SMOKE-TESTED ONLY — not CI-verifiable; see
// docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import Foundation
    import IndraKitCore
    import IndraKitNet
    import Observation

    @MainActor
    @Observable
    final class AppModel {
        let backend = BackendController()

        private(set) var files: [AudioFile] = []
        var selectedFileID: String?
        private(set) var manifest: FileManifest?
        private(set) var projectRoot = ""
        private(set) var jobs: [JobRun] = []
        var lastError: String?

        // Mirrors of DocumentStore state, re-published for SwiftUI observation
        // (DocumentStore itself is deliberately platform-neutral, not @Observable).
        private(set) var editor = EditorState()
        private(set) var canUndo = false
        private(set) var canRedo = false
        private(set) var undoMenuTitle = "Undo"
        private(set) var redoMenuTitle = "Redo"
        private(set) var syncErrors: [String] = []

        @ObservationIgnored private var store: DocumentStore?
        @ObservationIgnored private var jobTasks: [String: Task<Void, Never>] = [:]

        struct JobRun: Identifiable, Equatable {
            var id: String
            var kind: String
            var state: JobState
            var progress: Double
            var message: String

            var isTerminal: Bool {
                state == .done || state == .failed || state == .cancelled
            }
        }

        /// (wire kind, display name) — the five Phase 2 analyses (docs/api.md).
        static let analysisKinds: [(kind: String, title: String)] = [
            ("roughness_mpt", "Roughness"),
            ("spectral_entropy_mpt", "Spectral entropy"),
            ("template_harmonicity_mpt", "Harmonicity"),
            ("onsets_superflux_pcen", "Onsets"),
            ("foote_novelty_multiscale", "Foote novelty"),
        ]

        var selectedFile: AudioFile? { files.first { $0.id == selectedFileID } }

        // MARK: - Lifecycle

        /// Called at launch and by the Retry button.
        func start() async {
            await backend.connect()
            guard let client = backend.client else { return }
            do {
                projectRoot = try await client.project().root
                files = try await client.files()
            } catch {
                lastError = describe(error)
            }
            if selectedFileID == nil { selectedFileID = files.first?.id }
            await loadSelected()
        }

        func refreshFiles() async {
            guard let client = backend.client else { return }
            do {
                files = try await client.files()
            } catch {
                lastError = describe(error)
            }
        }

        /// Load manifest + annotations for the selected file and build a fresh
        /// DocumentStore seeded with the server's annotation records (so edits
        /// and deletes carry server ids and sync per §7.2).
        func loadSelected() async {
            guard let client = backend.client, let file = selectedFile else {
                manifest = nil
                store = nil
                syncFromStore()
                return
            }
            do {
                manifest = try await client.manifest(audioId: file.id)
                let records = try await client.annotations(audioId: file.id)
                store = DocumentStore(
                    initial: EditorState(
                        activeAudioId: file.id,
                        annotations: records.map(\.asAnnotation)),
                    sync: client)
            } catch {
                lastError = describe(error)
            }
            syncFromStore()
        }

        func refreshManifest() async {
            guard let client = backend.client, let file = selectedFile else { return }
            manifest = try? await client.manifest(audioId: file.id)
        }

        /// Absolute path of the original audio for AVAudioFile playback:
        /// stored_path from GET /files resolved against the project root.
        func resolvedAudioPath(for file: AudioFile) -> String {
            file.storedPath.hasPrefix("/")
                ? file.storedPath
                : projectRoot + "/" + file.storedPath
        }

        // MARK: - Editor actions (DocumentStore routing, §5.7)

        func dispatch(_ action: EditorAction) {
            store?.dispatch(action)
            syncFromStore()
        }

        func addAnnotation(t0: Double, t1: Double, label: String) {
            guard let audioId = editor.activeAudioId else { return }
            let annotation = Annotation(
                id: UUID().uuidString,  // local id until Reload assigns server ids
                audioId: audioId,
                t0: min(t0, t1), t1: max(t0, t1),
                label: label.isEmpty ? nil : label)
            dispatch(.addAnnotation(annotation))
        }

        /// DocumentStore.undo()/redo() already POST /undo //redo for
        /// annotation-scoped steps; local-only steps never leave the process.
        func undo() {
            _ = store?.undo()
            syncFromStore()
        }

        func redo() {
            _ = store?.redo()
            syncFromStore()
        }

        /// Re-fetch annotations from the server so rows carry server ids
        /// (creates are fire-and-forget with local UUID ids until then).
        /// Rebuilding the store clears local undo history — harness trade-off.
        func reloadAnnotations() async {
            guard let client = backend.client, let file = selectedFile else { return }
            // Best-effort: give in-flight fire-and-forget creates a moment to land.
            try? await Task.sleep(nanoseconds: 400_000_000)
            do {
                let records = try await client.annotations(audioId: file.id)
                store = DocumentStore(
                    initial: EditorState(
                        activeAudioId: file.id,
                        annotations: records.map(\.asAnnotation)),
                    sync: client)
            } catch {
                lastError = describe(error)
            }
            syncFromStore()
        }

        private func syncFromStore() {
            editor = store?.state ?? EditorState()
            canUndo = store?.canUndo ?? false
            canRedo = store?.canRedo ?? false
            undoMenuTitle = store?.undoActionName.map { "Undo \($0)" } ?? "Undo"
            redoMenuTitle = store?.redoActionName.map { "Redo \($0)" } ?? "Redo"
            syncErrors = store?.syncErrors ?? []
        }

        // MARK: - Jobs (import + analyses), SSE-fed with cancel (§4.5, §5.6)

        func importAudio(path: String) {
            guard let client = backend.client else { return }
            let name = (path as NSString).lastPathComponent
            Task {
                do {
                    let created = try await client.importFile(path: path)
                    self.track(jobId: created.jobId, title: "Import \(name)")
                } catch {
                    self.lastError = self.describe(error)
                }
            }
        }

        func runAnalysis(kind: String, title: String) {
            guard let client = backend.client, let file = selectedFile else { return }
            Task {
                do {
                    let created = try await client.analyze(kind: kind, audioId: file.id)
                    self.track(jobId: created.jobId, title: title)
                } catch {
                    self.lastError = self.describe(error)
                }
            }
        }

        /// Cancelling the consuming task terminates the SSE stream, whose
        /// onTermination POSTs /jobs/{id}/cancel (APIClient.jobEvents).
        func cancelJob(_ id: String) {
            jobTasks[id]?.cancel()
            mark(id) {
                if !$0.isTerminal {
                    $0.state = .cancelled
                    $0.message = "cancel requested"
                }
            }
        }

        func clearFinishedJobs() {
            jobs.removeAll(where: \.isTerminal)
        }

        private func track(jobId: String, title: String) {
            jobs.insert(
                JobRun(id: jobId, kind: title, state: .queued, progress: 0, message: "queued"),
                at: 0)
            if jobs.count > 30 { jobs.removeLast(jobs.count - 30) }
            guard let client = backend.client else { return }
            let task = Task {
                do {
                    for try await event in client.jobEvents(id: jobId) {
                        self.apply(snapshot: event.job)
                    }
                } catch is CancellationError {
                    self.mark(jobId) {
                        $0.state = .cancelled
                        $0.message = "cancelled"
                    }
                } catch {
                    self.mark(jobId) {
                        $0.state = .failed
                        $0.message = self.describe(error)
                    }
                }
                self.jobTasks[jobId] = nil
                if self.jobs.first(where: { $0.id == jobId })?.state == .done {
                    await self.refreshFiles()
                    if self.selectedFileID == nil {
                        self.selectedFileID = self.files.first?.id
                        await self.loadSelected()
                    } else {
                        await self.refreshManifest()  // new feature kinds after analyses
                    }
                }
            }
            jobTasks[jobId] = task
        }

        private func apply(snapshot job: JobInfo) {
            mark(job.id) {
                $0.state = job.state
                $0.progress = job.progress
                $0.message = job.message
            }
        }

        private func mark(_ id: String, _ mutate: (inout JobRun) -> Void) {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            mutate(&jobs[index])
        }

        // MARK: - Export (raw request; APIClient has no /export method yet)

        struct ExportFailure: LocalizedError {
            var message: String
            var errorDescription: String? { message }
        }

        /// POST /export (format json) and return the document bytes for
        /// .fileExporter. Refreshes the manifest first so `kinds` covers every
        /// feature computed so far.
        func fetchExportJSON() async throws -> Data {
            guard let session = backend.session, let file = selectedFile else {
                throw ExportFailure(message: "No backend session or no file selected.")
            }
            await refreshManifest()
            struct ExportRequest: Encodable {
                var audioId: String
                var kinds: [String]
                var format: String
            }
            guard let url = URL(string: "http://127.0.0.1:\(session.port)/export") else {
                throw ExportFailure(message: "Bad backend port.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try IndraJSON.encoder().encode(
                ExportRequest(
                    audioId: file.id, kinds: manifest?.features ?? [], format: "json"))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                throw ExportFailure(message: "Export failed (HTTP \(status)): \(body)")
            }
            return data
        }

        private func describe(_ error: Error) -> String {
            if let api = error as? APIError {
                return "\(api.code) (\(api.statusCode)): \(api.message)"
            }
            return error.localizedDescription
        }
    }

#endif
