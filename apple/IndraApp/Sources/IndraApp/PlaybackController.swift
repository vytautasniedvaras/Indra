// AVAudioEngine playback of the ORIGINAL file: AVAudioPlayerNode with gapless
// scheduleSegment chunk chaining (next chunk queued a full chunk before the
// current drains — BUILD_SPEC §5.5) and an AVAudioUnitTimePitch for 0.25–4×
// rate. Filtered audition (backend STFT→mask→ISTFT) comes later in Phase 4.
// USER-SMOKE-TESTED ONLY — AVFoundation cannot be exercised headlessly; see
// docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI) && canImport(AVFoundation)

    import AVFoundation
    import Foundation
    import Observation

    @MainActor
    @Observable
    final class PlaybackController {
        @ObservationIgnored private let engine = AVAudioEngine()
        @ObservationIgnored private let player = AVAudioPlayerNode()
        @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
        @ObservationIgnored private var file: AVAudioFile?
        /// File frame corresponding to playerTime.sampleTime == 0 for the
        /// current schedule run.
        @ObservationIgnored private var baseFrame: AVAudioFramePosition = 0
        @ObservationIgnored private var nextScheduleFrame: AVAudioFramePosition = 0
        /// Bumped on every stop/seek so stale segment completions no-op.
        @ObservationIgnored private var generation = 0
        @ObservationIgnored private var needsReschedule = true
        @ObservationIgnored private var timer: Timer?

        private(set) var isPlaying = false
        private(set) var duration: Double = 0
        private(set) var currentTime: Double = 0
        private(set) var rate: Float = 1.0
        var lastError: String?

        var isLoaded: Bool { duration > 0 }

        /// ~5 s chunks; two are queued, so the follow-up is scheduled well over
        /// the §5.5 "~500 ms before the current drains" margin.
        private let chunkSeconds = 5.0

        init() {
            engine.attach(player)
            engine.attach(timePitch)
        }

        // MARK: - File loading

        /// AVAudioFile memory-maps; scheduleSegment reads only needed frames
        /// (BUILD_SPEC §4.4), so hour-long files are fine.
        func load(url: URL) {
            stopPlayback()
            do {
                let audioFile = try AVAudioFile(forReading: url)
                file = audioFile
                duration = Double(audioFile.length)
                    / audioFile.processingFormat.sampleRate
                engine.connect(player, to: timePitch, format: audioFile.processingFormat)
                engine.connect(
                    timePitch, to: engine.mainMixerNode,
                    format: audioFile.processingFormat)
                currentTime = 0
                lastError = nil
            } catch {
                file = nil
                duration = 0
                currentTime = 0
                lastError = "Cannot open \(url.lastPathComponent): "
                    + error.localizedDescription
            }
        }

        // MARK: - Transport

        func play() {
            guard file != nil, !isPlaying else { return }
            do {
                if !engine.isRunning { try engine.start() }
            } catch {
                lastError = "Audio engine failed to start: \(error.localizedDescription)"
                return
            }
            if needsReschedule {
                restart(at: currentTime)
            } else {
                player.play()  // resume from pause
                isPlaying = true
            }
            startTimer()
        }

        func pause() {
            player.pause()
            isPlaying = false
        }

        /// Sample-accurate seek: frame = seconds × sampleRate, rescheduled from
        /// there (BUILD_SPEC §5.5).
        func seek(to time: Double) {
            guard file != nil else { return }
            let clamped = min(max(time, 0), duration)
            currentTime = clamped
            if isPlaying {
                restart(at: clamped)
            } else {
                needsReschedule = true
            }
        }

        /// Time-pitch rate, clamped to the 0.25–4× auditioning range (§5.5).
        func setRate(_ newRate: Float) {
            rate = min(max(newRate, 0.25), 4.0)
            timePitch.rate = rate
        }

        func stopPlayback() {
            generation += 1
            player.stop()
            isPlaying = false
            needsReschedule = true
            timer?.invalidate()
            timer = nil
        }

        // MARK: - Gapless segment chaining (§5.5)

        private func restart(at time: Double) {
            guard let file else { return }
            generation += 1
            let gen = generation
            player.stop()  // clears any queued segments; resets playerTime
            let sampleRate = file.processingFormat.sampleRate
            baseFrame = min(
                max(0, AVAudioFramePosition((time * sampleRate).rounded())), file.length)
            nextScheduleFrame = baseFrame
            scheduleNextChunk(gen)
            scheduleNextChunk(gen)  // keep one chunk of lookahead queued
            player.play()
            isPlaying = true
            needsReschedule = false
            startTimer()
        }

        private func scheduleNextChunk(_ gen: Int) {
            guard let file, gen == generation, nextScheduleFrame < file.length else { return }
            let sampleRate = file.processingFormat.sampleRate
            let chunkFrames = AVAudioFramePosition((chunkSeconds * sampleRate).rounded())
            let count = AVAudioFrameCount(
                min(chunkFrames, file.length - nextScheduleFrame))
            guard count > 0 else { return }
            let start = nextScheduleFrame
            nextScheduleFrame += AVAudioFramePosition(count)
            // .dataConsumed fires when the segment's data has been read (before
            // it finishes sounding), so the next chunk queues while the current
            // one still has audio in flight — gapless continuation.
            player.scheduleSegment(
                file, startingFrame: start, frameCount: count, at: nil,
                completionCallbackType: .dataConsumed
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleNextChunk(gen)
                }
            }
        }

        // MARK: - Playhead

        private func startTimer() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateTime()
                }
            }
        }

        private func updateTime() {
            guard isPlaying, let file else { return }
            guard let nodeTime = player.lastRenderTime,
                let playerTime = player.playerTime(forNodeTime: nodeTime)
            else { return }
            let sampleRate = file.processingFormat.sampleRate
            let elapsed =
                Double(baseFrame) / sampleRate
                + Double(playerTime.sampleTime) / playerTime.sampleRate
            currentTime = min(max(elapsed, 0), duration)
            // End of file: everything scheduled and the playhead has caught up.
            if nextScheduleFrame >= file.length, currentTime >= duration - 0.05 {
                player.stop()
                isPlaying = false
                needsReschedule = true
                currentTime = duration
            }
        }
    }

#endif
