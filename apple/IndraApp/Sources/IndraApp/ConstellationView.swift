// Constellation view (docs/design/selection-ux.md §3): folder-wide similar-
// search results as a starfield — dot position from the 2-D embedding, size =
// duration, hue = cluster, brightness = closeness to the seed — plus per-file
// match pills and a client-side distance re-threshold slider (segments carry
// their distances, so tightening never re-runs the search). Clicking a dot
// auditions it; clicking a same-file pill scrolls the spectrogram to the
// match and seeks (⌥-click auditions); other-file pills audition. Layout math
// lives in IndraKitCore (ConstellationLayout, CI-tested); this file only
// draws and hit-tests. USER-SMOKE-TESTED ONLY — see docs/plan/SMOKE_TESTS.md.

#if os(macOS) && canImport(SwiftUI) && canImport(MetalKit)

    import AppKit
    import IndraKitCore
    import SwiftUI

    @MainActor
    struct ConstellationView: View {
        let canvas: SpectroCanvasModel
        let result: SimilarSearchResult
        @Environment(AppModel.self) private var model
        @State private var hovered: Int?
        /// Client-side display cutoff; nil until the user touches the slider.
        @State private var displayThreshold: Double?

        /// One source of truth for the starfield's pixel size — the frame,
        /// the tap hit-test, and the hover hit-test must all agree.
        private static let mapSize = CGSize(width: 260, height: 200)

        private var cutoff: Double { displayThreshold ?? result.threshold }

        /// Layout over the FULL result (positions stay stable while sliding);
        /// filtered dots just disappear. segmentIndex keys the original array.
        private var dots: [ConstellationLayout.Dot] {
            ConstellationLayout.dots(for: result).filter {
                result.segments[$0.segmentIndex].distance <= cutoff
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                thresholdSlider
                HStack(alignment: .top, spacing: 12) {
                    starfield
                        .frame(width: Self.mapSize.width, height: Self.mapSize.height)
                        .background(
                            Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    pillRows
                    Spacer(minLength: 0)
                }
            }
        }

        /// Re-threshold WITHOUT re-searching: every returned segment carries
        /// its distance, so tightening the cutoff is a pure display filter.
        private var thresholdSlider: some View {
            HStack(spacing: 8) {
                Text("Distance ≤")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { cutoff },
                        set: { displayThreshold = $0 }),
                    in: 0.02...result.threshold
                )
                .frame(width: 160)
                Text(String(format: "%.2f", cutoff))
                    .font(.caption.monospacedDigit())
                Text("\(visibleCount)/\(result.segments.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }

        private var visibleCount: Int {
            result.segments.filter { $0.distance <= cutoff }.count
        }

        /// The cluster map. Same data as the pills, spatial instead of listed:
        /// classes that emerge (kicks vs crackles vs that one weird resonance)
        /// separate visually without anyone defining classes up front.
        private var starfield: some View {
            let dots = self.dots  // one layout per body evaluation, not per hover
            let seed = ConstellationLayout.seedPoint(for: result)
            return Canvas { context, size in
                let side = min(size.width, size.height)
                if let seed {
                    // The seed: a ringed star among its matches (ux §3).
                    let r = 0.035 * side
                    let rect = CGRect(
                        x: seed.x * size.width - r, y: seed.y * size.height - r,
                        width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)))
                    context.stroke(
                        Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                        with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                }
                for dot in dots {
                    let rect = CGRect(
                        x: dot.x * size.width - dot.radius * side,
                        y: dot.y * size.height - dot.radius * side,
                        width: dot.radius * side * 2,
                        height: dot.radius * side * 2)
                    let color = Color(
                        hue: ConstellationLayout.hue(forCluster: dot.cluster),
                        saturation: 0.7,
                        brightness: 0.45 + 0.55 * dot.closeness)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    if hovered == dot.segmentIndex {
                        context.stroke(
                            Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)),
                            with: .color(.white), lineWidth: 1)
                    }
                }
            }
            .onTapGesture { location in
                guard let index = hitTest(dots, location) else { return }
                canvas.auditionSegment(index)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = hitTest(dots, point)
                case .ended:
                    hovered = nil
                }
            }
            .help("Each dot is a match: size = duration, color = cluster, brightness = closeness. Click to hear it.")
        }

        /// Matches grouped per file — seed file first (ux §3), then by name.
        private var pillRows: some View {
            let visible = Array(result.segments.enumerated())
                .filter { $0.element.distance <= cutoff }
            let grouped = Dictionary(
                grouping: visible,
                by: { $0.element.audioId ?? canvas.file.id })
            let seedId = canvas.file.id
            let ordered = grouped.keys.sorted { a, b in
                if (a == seedId) != (b == seedId) { return a == seedId }
                return fileLabel(a) < fileLabel(b)
            }
            return ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ordered, id: \.self) { audioId in
                        HStack(spacing: 6) {
                            Text(fileLabel(audioId))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .trailing)
                                .lineLimit(1)
                            ForEach(grouped[audioId] ?? [], id: \.offset) { entry in
                                pill(entry.offset, entry.element)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }

        private func pill(_ index: Int, _ segment: SimilarSegment) -> some View {
            let cluster = clusterOf(index)
            let isLocal = (segment.audioId ?? canvas.file.id) == canvas.file.id
            return Button {
                let optionDown = NSEvent.modifierFlags.contains(.option)
                if isLocal && !optionDown {
                    // Navigate: scroll the spectrogram to the match and park
                    // the playhead on it (ux §3); ⌥-click auditions instead.
                    canvas.revealTime(t0: segment.t0, t1: segment.t1)
                    canvas.onSeek?(segment.t0)
                } else {
                    canvas.auditionSegment(index)
                }
            } label: {
                Text(String(format: "%.1f–%.1fs", segment.t0, segment.t1))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color(
                            hue: ConstellationLayout.hue(forCluster: cluster),
                            saturation: 0.55,
                            brightness: 0.5 + 0.5 * max(0, 1 - segment.distance)
                        ).opacity(0.35),
                        in: Capsule())
            }
            .buttonStyle(.plain)
            .help(
                isLocal
                    ? String(
                        format: "distance %.2f — click to jump there, ⌥-click to hear",
                        segment.distance)
                    : String(format: "distance %.2f — click to hear", segment.distance))
        }

        private func clusterOf(_ index: Int) -> Int {
            guard let cluster = result.embedding?.cluster, index < cluster.count else {
                return 0
            }
            return cluster[index]
        }

        private func fileLabel(_ audioId: String) -> String {
            if audioId == canvas.file.id { return "this file" }
            let path = model.files.first { $0.id == audioId }?.origPath ?? audioId
            return (path as NSString).lastPathComponent
        }

        private func hitTest(_ dots: [ConstellationLayout.Dot], _ point: CGPoint) -> Int? {
            ConstellationLayout.hitTest(
                dots: dots, x: Double(point.x), y: Double(point.y),
                width: Double(Self.mapSize.width), height: Double(Self.mapSize.height))
        }
    }

#endif
