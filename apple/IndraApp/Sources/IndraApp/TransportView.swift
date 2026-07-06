// Transport strip: play/pause, scrub slider, elapsed/total time, and the
// 0.25–4× time-pitch rate slider (BUILD_SPEC §5.5). USER-SMOKE-TESTED ONLY —
// not CI-verifiable; see docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI) && canImport(AVFoundation)

    import SwiftUI

    @MainActor
    struct TransportView: View {
        var playback: PlaybackController
        @State private var scrubTime = 0.0
        @State private var isScrubbing = false

        var body: some View {
            GroupBox("Playback (original file)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Button {
                            playback.isPlaying ? playback.pause() : playback.play()
                        } label: {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 20)
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .disabled(!playback.isLoaded)

                        Text(Self.clock(playback.currentTime))
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)

                        Slider(
                            value: $scrubTime,
                            in: 0...max(playback.duration, 0.001)
                        ) { editing in
                            isScrubbing = editing
                            if !editing { playback.seek(to: scrubTime) }
                        }
                        .disabled(!playback.isLoaded)

                        Text(Self.clock(playback.duration))
                            .monospacedDigit()
                            .frame(width: 70, alignment: .leading)

                        Divider().frame(height: 16)

                        Text("Rate")
                            .font(.caption)
                        Slider(value: rateBinding, in: 0.25...4)
                            .frame(width: 130)
                        Text(String(format: "%.2f×", playback.rate))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .leading)
                    }
                    if let error = playback.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: playback.currentTime) { _, newValue in
                if !isScrubbing { scrubTime = newValue }
            }
        }

        private var rateBinding: Binding<Double> {
            Binding(
                get: { Double(playback.rate) },
                set: { playback.setRate(Float($0)) })
        }

        static func clock(_ seconds: Double) -> String {
            let total = Int(seconds)
            return String(
                format: "%ld:%02ld:%04.1f",
                total / 3600, (total / 60) % 60,
                seconds.truncatingRemainder(dividingBy: 60))
        }
    }

#endif
