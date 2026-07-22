// NavigationSplitView shell: sidebar (imported files + Import button) and the
// per-file detail harness (BUILD_SPEC §9 Phase 3 DoD / Phase 4 start).
// USER-SMOKE-TESTED ONLY — not CI-verifiable; see docs/plan/SMOKE_TESTS.md.

#if os(macOS) && canImport(SwiftUI)

    import IndraKitCore
    import SwiftUI
    import UniformTypeIdentifiers

    @MainActor
    struct ContentView: View {
        @Environment(AppModel.self) private var model
        @State private var importerPresented = false

        var body: some View {
            @Bindable var model = model
            NavigationSplitView {
                sidebar
            } detail: {
                if case .connected = model.backend.status, let file = model.selectedFile {
                    FileDetailView(file: file)
                        .id(file.id)
                } else {
                    BackendStatusView()
                }
            }
            .fileImporter(
                isPresented: $importerPresented,
                allowedContentTypes: [.audio]
            ) { result in
                if case .success(let url) = result {
                    // The app is unsandboxed (plain SwiftPM executable), but be
                    // polite about security scope anyway; the backend reads the
                    // path with its own process rights.
                    let scoped = url.startAccessingSecurityScopedResource()
                    model.importAudio(path: url.path)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
            }
        }

        private var sidebar: some View {
            @Bindable var model = model
            return List(selection: $model.selectedFileID) {
                Section("Files") {
                    ForEach(model.files, id: \.id) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((file.origPath as NSString).lastPathComponent)
                                .lineLimit(1)
                            Text(
                                "\(Self.timeString(file.durationS)) · \(file.sr) Hz · "
                                    + "\(file.channels) ch"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(file.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button("Import…") { importerPresented = true }
                    .disabled(model.backend.client == nil)
                Button {
                    Task { await model.refreshFiles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh file list")
                .disabled(model.backend.client == nil)
            }
            .onChange(of: model.selectedFileID) { _, _ in
                Task { await model.loadSelected() }
            }
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        }

        private var sidebarFooter: some View {
            VStack(alignment: .leading, spacing: 4) {
                switch model.backend.status {
                case .connected:
                    if let session = model.backend.session {
                        Text("Backend: 127.0.0.1:\(session.port)")
                    }
                case .launching(let message):
                    Text(message).lineLimit(2)
                case .failed:
                    Text("Backend: failed (see detail pane)").foregroundStyle(.red)
                case .idle:
                    Text("Backend: idle")
                }
                if let error = model.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.thinMaterial)
        }

        static func timeString(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            return String(
                format: "%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60)
        }
    }

    /// Shown while connecting, on failure, or when no file is selected.
    @MainActor
    struct BackendStatusView: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            VStack(spacing: 14) {
                switch model.backend.status {
                case .idle, .launching:
                    ProgressView()
                    Text(launchingMessage)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    ScrollView {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    Button("Retry") {
                        Task { await model.start() }
                    }
                    .keyboardShortcut(.defaultAction)
                case .connected:
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(
                        model.files.isEmpty
                            ? "Connected. Import an audio file to begin."
                            : "Connected. Select a file in the sidebar."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(30)
        }

        private var launchingMessage: String {
            if case .launching(let message) = model.backend.status { return message }
            return "Connecting to the backend…"
        }
    }

#endif
