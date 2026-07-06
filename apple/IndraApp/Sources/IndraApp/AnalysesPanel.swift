// Analyses panel: one button per Phase 2 analysis kind → POST /analyze, with
// per-job progress bars fed by the /jobs/{id}/events SSE stream and a Cancel
// button per running job (stream termination POSTs the cancel — BUILD_SPEC
// §4.5, §5.6). USER-SMOKE-TESTED ONLY — not CI-verifiable; see
// docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI)

    import IndraKitCore
    import SwiftUI

    @MainActor
    struct AnalysesPanel: View {
        let file: AudioFile
        @Environment(AppModel.self) private var model

        var body: some View {
            GroupBox("Analyses") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(AppModel.analysisKinds, id: \.kind) { entry in
                            Button(entry.title) {
                                model.runAnalysis(kind: entry.kind, title: entry.title)
                            }
                        }
                        Spacer()
                        if model.jobs.contains(where: \.isTerminal) {
                            Button("Clear finished") { model.clearFinishedJobs() }
                                .buttonStyle(.borderless)
                        }
                    }

                    if let features = model.manifest?.features, !features.isEmpty {
                        Text("Computed features: \(features.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.jobs) { run in
                        JobRow(run: run)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @MainActor
    struct JobRow: View {
        let run: AppModel.JobRun
        @Environment(AppModel.self) private var model

        var body: some View {
            HStack(spacing: 8) {
                Text(run.kind)
                    .frame(width: 150, alignment: .leading)
                    .lineLimit(1)
                ProgressView(value: min(max(run.progress, 0), 1))
                    .frame(maxWidth: .infinity)
                Text(run.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)
                Text(stateLabel)
                    .font(.caption.bold())
                    .foregroundStyle(stateColor)
                    .frame(width: 70, alignment: .trailing)
                if !run.isTerminal {
                    Button("Cancel") { model.cancelJob(run.id) }
                        .buttonStyle(.borderless)
                }
            }
        }

        private var stateLabel: String { run.state.rawValue }

        private var stateColor: Color {
            switch run.state {
            case .done: .green
            case .failed: .red
            case .cancelled: .orange
            case .queued, .running: .secondary
            }
        }
    }

#endif
