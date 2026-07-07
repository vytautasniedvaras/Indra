// Per-file detail harness: Metal spectrogram canvas (default, §5.3/ADR 0013)
// with the CPU debug canvas kept behind a toggle for A/B, transport,
// analyses, annotations, export (BUILD_SPEC §9 Phase 3 DoD → Phase 4).
// USER-SMOKE-TESTED ONLY — not CI-verifiable; see docs/plan/SMOKE_TESTS.md
// (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import IndraKitCore
    import SwiftUI

    @MainActor
    struct FileDetailView: View {
        let file: AudioFile
        @Environment(AppModel.self) private var model
        @State private var playback = PlaybackController()
        @AppStorage("indra.metalCanvas") private var useMetalCanvas = true

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    canvasSection

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

        /// Metal canvas by default; the CPU DebugCanvasView stays available
        /// behind the toggle for A/B comparison (§5.3 rollout).
        private var canvasSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Canvas", selection: $useMetalCanvas) {
                    Text("Metal").tag(true)
                    Text("Debug (CPU)").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if useMetalCanvas {
                    #if canImport(MetalKit)
                        if let spec = model.manifest?.spec {
                            SpectrogramPane(
                                file: file,
                                spec: spec,
                                playheadTime: playback.currentTime,
                                onSeek: { playback.seek(to: $0) },
                                onAuditionReady: { playback.playScratch(url: $0) },
                                onPreviewBand: { playback.setPreviewBand(f0: $0, f1: $1) })
                        } else {
                            ZStack {
                                Color.black.opacity(0.05)
                                Text("No spectrogram pyramid yet (ingest still running?)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 340)
                        }
                    #else
                        Text("MetalKit unavailable on this platform.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    #endif
                } else {
                    DebugCanvasView(
                        file: file,
                        playheadFraction: playback.duration > 0
                            ? playback.currentTime / playback.duration : 0,
                        onSeek: { fraction in
                            playback.seek(to: fraction * playback.duration)
                        })
                }
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
