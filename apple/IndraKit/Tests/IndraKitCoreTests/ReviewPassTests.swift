import Testing

@testable import IndraKitCore

// Seams added in the Phase 4 review pass: undoable magic selection,
// AuditionResult parsing, wireValue dual-key lookup, frequency bounds,
// CurveLane server-bucket rebucketing, and the constellation hit test.

@Suite("Magic selection in EditorState")
struct MagicSelectionUndoTests {
    @Test func setAndClearAreUndoableActions() {
        var state = EditorState(activeAudioId: "a1")
        state = reduce(state, .setMagicSelection("sel1"))
        #expect(state.magicSelectionId == "sel1")
        #expect(EditorAction.setMagicSelection("sel1").name == "Magic select")
        #expect(EditorAction.setMagicSelection(nil).name == "Clear magic selection")
        state = reduce(state, .setMagicSelection(nil))
        #expect(state.magicSelectionId == nil)
    }

    @Test func identityOnSameId() {
        let state = reduce(EditorState(), .setMagicSelection("x"))
        #expect(reduce(state, .setMagicSelection("x")) == state)
    }

    @Test func switchingFilesClearsIt() {
        var state = reduce(EditorState(activeAudioId: "a1"), .setMagicSelection("sel1"))
        state = reduce(state, .setActiveAudio("b2"))
        #expect(state.magicSelectionId == nil)
    }

    @Test func undoStackRoundTripsMagicSelection() {
        var state = EditorState()
        var stack = UndoStack(initial: state)
        state = reduce(state, .setMagicSelection("sel1"))
        stack.apply(EditorAction.setMagicSelection("sel1").name, state)
        state = reduce(state, .setMagicSelection(nil))
        stack.apply(EditorAction.setMagicSelection(nil).name, state)
        #expect(state.magicSelectionId == nil)
        state = stack.undo() ?? state
        #expect(state.magicSelectionId == "sel1")
        state = stack.undo() ?? state
        #expect(state.magicSelectionId == nil)
        state = stack.redo() ?? state
        #expect(state.magicSelectionId == "sel1")
    }
}

@Suite("AuditionResult")
struct AuditionResultTests {
    @Test func parsesBothKeySpellingsAndResolvesPath() {
        let snake: [String: JSONValue] = [
            "audition_id": .string("k1"), "wav_path": .string("blobs/k1.wav"),
            "duration_s": .number(3.5),
        ]
        let camel: [String: JSONValue] = [
            "auditionId": .string("k1"), "wavPath": .string("blobs/k1.wav"),
        ]
        for ref in [snake, camel] {
            let result = AuditionResult(resultRef: ref)
            #expect(result?.auditionId == "k1")
            #expect(result?.absolutePath(projectRoot: "/proj") == "/proj/blobs/k1.wav")
        }
        #expect(AuditionResult(resultRef: snake)?.durationS == 3.5)
        #expect(AuditionResult(resultRef: ["kind": .string("audition")]) == nil)
        // absolute wav paths pass through untouched
        let absolute = AuditionResult(auditionId: "k", wavPath: "/tmp/x.wav")
        #expect(absolute.absolutePath(projectRoot: "/proj") == "/tmp/x.wav")
    }
}

@Suite("MagicSelection bounds")
struct MagicSelectionBoundsTests {
    @Test func boundsSpanAllRibbons() {
        let selection = MagicSelection(
            selectionId: "s",
            ribbons: [
                MagicRibbon(t0: 1, t1: 2, intervals: [FrequencyInterval(fLo: 300, fHi: 500)]),
                MagicRibbon(
                    t0: 2, t1: 3,
                    intervals: [
                        FrequencyInterval(fLo: 100, fHi: 200),
                        FrequencyInterval(fLo: 700, fHi: 900),
                    ]),
            ])
        #expect(selection.frequencyBounds?.lo == 100)
        #expect(selection.frequencyBounds?.hi == 900)
        #expect(selection.timeBounds?.t0 == 1)
        #expect(selection.timeBounds?.t1 == 3)
        let empty = MagicSelection(selectionId: "e", ribbons: [])
        #expect(empty.frequencyBounds == nil)
        #expect(empty.timeBounds == nil)
    }
}

@Suite("CurveLane server rebucketing")
struct CurveLaneRebucketTests {
    @Test func preservesServerExtremes() {
        let series = FeatureBucketSeries(
            t: [0.5, 1.5, 2.5], min: [0.1, 0.0, 0.4], max: [0.9, 0.2, 1.6])
        let viewport = Viewport(t0: 0, t1: 3, f0: 0, f1: 100, width: 3, height: 10)
        let buckets = CurveLane.buckets(from: series, viewport: viewport)
        #expect(buckets.count == 3)
        #expect(buckets[0]?.min == 0.1 && buckets[0]?.max == 0.9)
        #expect(buckets[1]?.min == 0.0 && buckets[1]?.max == 0.2)
        #expect(buckets[2]?.min == 0.4 && buckets[2]?.max == 1.6)
    }
}

@Suite("Constellation hit test")
struct ConstellationHitTests {
    private let dots = [
        ConstellationLayout.Dot(
            segmentIndex: 0, x: 0.25, y: 0.5, radius: 0.05, cluster: 1, closeness: 0.9),
        ConstellationLayout.Dot(
            segmentIndex: 1, x: 0.75, y: 0.5, radius: 0.02, cluster: 2, closeness: 0.4),
    ]

    @Test func picksTheDotUnderThePoint() {
        #expect(
            ConstellationLayout.hitTest(dots: dots, x: 50, y: 100, width: 200, height: 200)
                == 0)
        #expect(
            ConstellationLayout.hitTest(dots: dots, x: 150, y: 100, width: 200, height: 200)
                == 1)
        #expect(
            ConstellationLayout.hitTest(dots: dots, x: 100, y: 20, width: 200, height: 200)
                == nil)
    }

    @Test func tinyDotsKeepAMinimumHitRadius() {
        // dot 1 radius = 0.02 × 200 = 4 px; minHitRadius 6 keeps a 5 px miss a hit
        #expect(
            ConstellationLayout.hitTest(dots: dots, x: 155, y: 100, width: 200, height: 200)
                == 1)
    }
}
