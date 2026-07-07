// Constellation view (docs/design/selection-ux.md §3): folder-wide similar-
// search results as a starfield — dot position from the 2-D embedding, size =
// duration, hue = cluster, brightness = closeness to the seed — plus per-file
// match pills. Clicking either auditions that segment (equal-power segment
// render via POST /audition). Layout math lives in IndraKitCore
// (ConstellationLayout, CI-tested); this file only draws and hit-tests.
// USER-SMOKE-TESTED ONLY — see docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI) && canImport(MetalKit)

    import IndraKitCore
    import SwiftUI

    @MainActor
    struct ConstellationView: View {
        let canvas: SpectroCanvasModel
        let result: SimilarSearchResult
        @Environment(AppModel.self) private var model
        @State private var hovered: Int?

        private var dots: [ConstellationLayout.Dot] {
            ConstellationLayout.dots(for: result)
        }

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                starfield
                    .frame(width: 260, height: 200)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                pillRows
                Spacer(minLength: 0)
            }
        }

        /// The cluster map. Same data as the pills, spatial instead of listed:
        /// classes that emerge (kicks vs crackles vs that one weird resonance)
        /// separate visually without anyone defining classes up front.
        private var starfield: some View {
            Canvas { context, size in
                let side = min(size.width, size.height)
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
                guard let index = hitTest(location, in: CGSize(width: 260, height: 200))
                else { return }
                canvas.auditionSegment(index)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = hitTest(point, in: CGSize(width: 260, height: 200))
                case .ended:
                    hovered = nil
                }
            }
            .help("Each dot is a match: size = duration, color = cluster, brightness = closeness. Click to hear it.")
        }

        /// Matches grouped per file, best-first inside each row.
        private var pillRows: some View {
            let grouped = Dictionary(
                grouping: Array(result.segments.enumerated()),
                by: { $0.element.audioId ?? canvas.file.id })
            return ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(grouped.keys.sorted(), id: \.self) { audioId in
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
            return Button {
                canvas.auditionSegment(index)
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
            .help(String(format: "distance %.2f — click to hear", segment.distance))
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

        private func hitTest(_ point: CGPoint, in size: CGSize) -> Int? {
            let side = min(size.width, size.height)
            var best: (index: Int, distance: Double)?
            for dot in dots {
                let dx = Double(point.x) - dot.x * Double(size.width)
                let dy = Double(point.y) - dot.y * Double(size.height)
                let distance = (dx * dx + dy * dy).squareRoot()
                let hitRadius = max(dot.radius * Double(side), 6)
                if distance <= hitRadius, distance < (best?.distance ?? .infinity) {
                    best = (dot.segmentIndex, distance)
                }
            }
            return best?.index
        }
    }

#endif
