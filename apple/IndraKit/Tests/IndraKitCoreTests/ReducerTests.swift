import Testing

@testable import IndraKitCore

@Suite("EditorReducer")
struct ReducerTests {
    let annotation = Annotation(id: "a1", audioId: "f1", t0: 1, t1: 2, label: "hit")

    @Test func identityOnNoOps() {
        let state = EditorState(activeAudioId: "f1", annotations: [annotation])
        #expect(reduce(state, .setActiveAudio("f1")) == state)
        #expect(reduce(state, .setSelection(nil)) == state)
        #expect(reduce(state, .addAnnotation(annotation)) == state)
        #expect(reduce(state, .updateAnnotation(annotation)) == state)
        #expect(reduce(state, .deleteAnnotation(id: "missing")) == state)
    }

    @Test func determinism() {
        let state = EditorState()
        let action = EditorAction.setSelection(Selection(t0: 3, t1: 9, f0: 100, f1: 400))
        #expect(reduce(state, action) == reduce(state, action))
    }

    @Test func selectionNormalizesBounds() {
        let selection = Selection(t0: 9, t1: 3, f0: 400, f1: 100)
        #expect(selection.t0 == 3 && selection.t1 == 9)
        #expect(selection.f0 == 100 && selection.f1 == 400)
    }

    @Test func switchingFileClearsSelection() {
        var state = EditorState(activeAudioId: "f1")
        state.selection = Selection(t0: 0, t1: 1)
        let next = reduce(state, .setActiveAudio("f2"))
        #expect(next.activeAudioId == "f2")
        #expect(next.selection == nil)
    }

    @Test func annotationLifecycle() {
        var state = EditorState()
        state = reduce(state, .addAnnotation(annotation))
        #expect(state.annotations.count == 1)

        var edited = annotation
        edited.note = "louder than expected"
        state = reduce(state, .updateAnnotation(edited))
        #expect(state.annotations[0].note == "louder than expected")

        state = reduce(state, .deleteAnnotation(id: "a1"))
        #expect(state.annotations.isEmpty)
    }

    @Test func lensToggle() {
        var state = EditorState()
        state = reduce(state, .toggleLens("roughness"))
        #expect(state.lensesEnabled.contains("roughness"))
        state = reduce(state, .toggleLens("roughness"))
        #expect(!state.lensesEnabled.contains("roughness"))
    }

    @Test func actionNames() {
        #expect(EditorAction.addAnnotation(annotation).name == "Add annotation")
        #expect(EditorAction.setSelection(nil).name == "Clear selection")
        #expect(
            EditorAction.setSelection(Selection(t0: 0, t1: 1)).name == "Change selection")
    }
}
