// Export: POST /export (json) → bytes → SwiftUI .fileExporter with a minimal
// FileDocument wrapper (BUILD_SPEC §6.6, docs/export_schema.md).
// USER-SMOKE-TESTED ONLY — not CI-verifiable; see docs/plan/SMOKE_TESTS.md
// (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import IndraKitCore
    import SwiftUI
    import UniformTypeIdentifiers

    struct JSONExportDocument: FileDocument {
        static let readableContentTypes: [UTType] = [.json]

        var data: Data

        init(data: Data) {
            self.data = data
        }

        init(configuration: ReadConfiguration) throws {
            data = configuration.file.regularFileContents ?? Data()
        }

        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: data)
        }
    }

    @MainActor
    struct ExportPanel: View {
        let file: AudioFile
        @Environment(AppModel.self) private var model
        @State private var document: JSONExportDocument?
        @State private var exporterPresented = false
        @State private var isFetching = false
        @State private var statusMessage: String?

        var body: some View {
            GroupBox("Export") {
                HStack(spacing: 10) {
                    Button("Export JSON…") { fetchAndPresent() }
                        .disabled(isFetching)
                    if isFetching { ProgressView().controlSize(.small) }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fileExporter(
                isPresented: $exporterPresented,
                document: document,
                contentType: .json,
                defaultFilename: defaultFilename
            ) { result in
                switch result {
                case .success(let url):
                    statusMessage = "Saved \(url.lastPathComponent)"
                case .failure(let error):
                    statusMessage = "Save failed: \(error.localizedDescription)"
                }
            }
        }

        private var defaultFilename: String {
            let base = ((file.origPath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            return "\(base.isEmpty ? file.id : base)-indra-export.json"
        }

        private func fetchAndPresent() {
            isFetching = true
            statusMessage = "Exporting…"
            Task {
                defer { isFetching = false }
                do {
                    let data = try await model.fetchExportJSON()
                    document = JSONExportDocument(data: data)
                    statusMessage =
                        "Ready (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
                    exporterPresented = true
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

#endif
