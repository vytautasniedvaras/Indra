// Per-file detail harness: debug canvas, transport, analyses, annotations,
// export (BUILD_SPEC §9 Phase 3 DoD; Metal canvas replaces the debug canvas in
// Phase 4 proper, §5.3). USER-SMOKE-TESTED ONLY — not CI-verifiable; see
// docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import IndraKitCore
    import SwiftUI

    @MainActor
    struct FileDetailView: View {
        let file: AudioFile
        @Environment(AppModel.self) private var model
        @State private var playback = PlaybackController()

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    DebugCanvasView(
                        file: file,
                        playheadFraction: playback.duration > 0
                            ? playback.currentTime / playback.duration : 0,
                        onSeek: { fraction in
                            playback.seek(to: fraction * playback.duration)
                        })

                    TransportView(playback: playback)
                    AnalysesPanel(file: file)
                    AnnotationsPanel(file: file)
                    ExportPanel(file: file)

                    if !model.syncErrors.isEmpty {
                        GroupBox("Backend sync errors") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(model.syncErrors.suffix(5), id: \.self) { error in
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            .task(id: file.id) {
                playback.load(
                    url: URL(fileURLWithPath: model.resolvedAudioPath(for: file)))
            }
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text((file.origPath as NSString).lastPathComponent)
                    .font(.title3.bold())
                Text(
                    "\(ContentView.timeString(file.durationS)) · \(file.sr) Hz · "
                        + "\(file.channels) ch · \(file.format) · id \(file.id.prefix(12))…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

#endif
