import Foundation
import Testing

@testable import IndraKitCore

// MARK: - Sync spy

/// Records backend calls under a lock; optionally fails every call.
final class SyncSpy: AnnotationSyncing, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case create(AnnotationCreate)
        case update(Int, AnnotationPatch)
        case delete(Int)
        case undo
        case redo
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var failAll = false

    var calls: [Call] { withLock { recorded } }

    func failEverything() {
        withLock { failAll = true }
    }

    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func record(_ call: Call) throws {
        let fails = withLock {
            recorded.append(call)
            return failAll
        }
        if fails { throw Failure() }
    }

    func createAnnotation(_ create: AnnotationCreate) async throws -> AnnotationRecord {
        try record(.create(create))
        return AnnotationRecord(
            id: 1, audioId: create.audioId, t0: create.t0, t1: create.t1,
            f0: create.f0, f1: create.f1, label: create.label, note: create.note,
            createdAt: "t", updatedAt: "t")
    }

    func updateAnnotation(id: Int, _ patch: AnnotationPatch) async throws -> AnnotationRecord {
        try record(.update(id, patch))
        return AnnotationRecord(
            id: id, audioId: patch.audioId ?? "a", t0: patch.t0 ?? 0, t1: patch.t1 ?? 0,
            createdAt: "t", updatedAt: "t")
    }

    func deleteAnnotation(id: Int) async throws {
        try record(.delete(id))
    }

    func undoRemote() async throws -> UndoResponse {
        try record(.undo)
        return UndoResponse(
            appliedPatch: [], scope: "annotations", actionName: "x",
            undoStackDepth: 0, redoStackDepth: 1)
    }

    func redoRemote() async throws -> UndoResponse {
        try record(.redo)
        return UndoResponse(
            appliedPatch: [], scope: "annotations", actionName: "x",
            undoStackDepth: 1, redoStackDepth: 0)
    }
}

// MARK: - Tests

@Suite("DocumentStore")
struct DocumentStoreTests {
    func annotation(_ id: String) -> Annotation {
        Annotation(id: id, audioId: "a1", t0: 1, t1: 2, label: "bird")
    }

    @Test func dispatchUndoRedoRoundTrip() {
        let store = DocumentStore()
        store.dispatch(.setSelection(Selection(t0: 1, t1: 2)))
        store.dispatch(.addAnnotation(annotation("x")))
        #expect(store.state.annotations.count == 1)

        #expect(store.undo()?.annotations.isEmpty == true)
        #expect(store.state.selection == Selection(t0: 1, t1: 2))
        #expect(store.undo()?.selection == nil)
        #expect(store.undo() == nil)

        #expect(store.redo()?.selection == Selection(t0: 1, t1: 2))
        #expect(store.redo()?.annotations.count == 1)
        #expect(store.redo() == nil)
    }

    @Test func menuActionNames() {
        let store = DocumentStore()
        store.dispatch(.addAnnotation(annotation("x")))
        #expect(store.undoActionName == "Add annotation")
        store.undo()
        #expect(store.undoActionName == nil)
        #expect(store.redoActionName == "Add annotation")
    }

    @Test func dragCoalescesToOneStep() {
        let store = DocumentStore()
        store.beginSelectionDrag()
        for t in 1...50 {
            store.updateSelectionDrag(Selection(t0: 0, t1: Double(t)))
        }
        store.endSelectionDrag()
        #expect(store.state.selection == Selection(t0: 0, t1: 50))
        #expect(store.undo()?.selection == nil)
        #expect(store.undo() == nil)  // the whole drag was a single step
        #expect(store.redo()?.selection == Selection(t0: 0, t1: 50))
    }

    @Test func dragNameMatchesReducerActionName() {
        #expect(EditorAction.setSelection(Selection(t0: 0, t1: 1)).name == "Change selection")
        let store = DocumentStore()
        store.beginSelectionDrag()
        store.updateSelectionDrag(Selection(t0: 0, t1: 1))
        #expect(store.undoActionName == "Change selection")
        store.endSelectionDrag()
    }

    @Test func newDispatchInvalidatesRedo() {
        let store = DocumentStore()
        store.dispatch(.setSelection(Selection(t0: 1, t1: 2)))
        store.undo()
        #expect(store.canRedo)
        store.dispatch(.toggleLens("roughness"))
        #expect(!store.canRedo)
        #expect(store.redo() == nil)
    }

    @Test func annotationActionsForwardToSync() async {
        let spy = SyncSpy()
        let store = DocumentStore(sync: spy)
        store.dispatch(.addAnnotation(annotation("7")))
        var edited = annotation("7")
        edited.note = "updated"
        store.dispatch(.updateAnnotation(edited))
        store.dispatch(.deleteAnnotation(id: "7"))
        await store.flushSync()

        // Fire-and-forget tasks may interleave: assert the set, not the order.
        let calls = spy.calls
        #expect(calls.count == 3)
        #expect(calls.contains(.create(AnnotationCreate(annotation("7")))))
        #expect(calls.contains(.update(7, AnnotationPatch(edited))))
        #expect(calls.contains(.delete(7)))
        #expect(store.syncErrors.isEmpty)
    }

    @Test func localActionsNeverTouchSync() async {
        let spy = SyncSpy()
        let store = DocumentStore(sync: spy)
        store.dispatch(.setSelection(Selection(t0: 0, t1: 1)))
        store.dispatch(.toggleLens("entropy"))
        store.undo()
        store.undo()
        store.redo()
        await store.flushSync()
        #expect(spy.calls.isEmpty)
        #expect(store.syncErrors.isEmpty)
    }

    @Test func annotationUndoRedoRoundTripsToBackend() async {
        let spy = SyncSpy()
        let store = DocumentStore(sync: spy)
        store.dispatch(.addAnnotation(annotation("7")))
        store.undo()
        store.redo()
        await store.flushSync()
        #expect(spy.calls.contains(.undo))
        #expect(spy.calls.contains(.redo))
    }

    @Test func mixedHistorySyncsOnlyAnnotationSteps() async {
        let spy = SyncSpy()
        let store = DocumentStore(sync: spy)
        store.dispatch(.addAnnotation(annotation("7")))
        store.dispatch(.setSelection(Selection(t0: 3, t1: 4)))

        store.undo()  // selection step: local only
        await store.flushSync()
        #expect(!spy.calls.contains(.undo))

        store.undo()  // annotation step: hits the backend
        await store.flushSync()
        #expect(spy.calls.contains(.undo))
    }

    @Test func unsyncedAnnotationEditLogsInsteadOfForwarding() async {
        let spy = SyncSpy()
        let store = DocumentStore(sync: spy)
        let local = annotation(UUID().uuidString)  // no server id yet
        store.dispatch(.addAnnotation(local))
        var edited = local
        edited.label = "renamed"
        store.dispatch(.updateAnnotation(edited))
        await store.flushSync()
        #expect(spy.calls.count == 1)  // only the create went out
        #expect(store.syncErrors.count == 1)
    }

    @Test func syncFailuresAreLoggedNotThrown() async {
        let spy = SyncSpy()
        spy.failEverything()
        let store = DocumentStore(sync: spy)
        store.dispatch(.addAnnotation(annotation("7")))
        await store.flushSync()
        #expect(store.syncErrors.count == 1)
        #expect(store.state.annotations.count == 1)  // local state unaffected
    }

    @Test func noOpDispatchRecordsNothingAndNeverSyncs() async {
        let spy = SyncSpy()
        let store = DocumentStore(sync: spy)
        store.dispatch(.deleteAnnotation(id: "9"))  // nothing to delete
        await store.flushSync()
        #expect(!store.canUndo)
        #expect(spy.calls.isEmpty)
    }

    @Test func scopeNamesMatchEditorActionNames() {
        // DocumentStore routes remote undo by undo-step name; keep them in sync.
        let a = annotation("1")
        #expect(EditorAction.addAnnotation(a).name == "Add annotation")
        #expect(EditorAction.updateAnnotation(a).name == "Edit annotation")
        #expect(EditorAction.deleteAnnotation(id: "1").name == "Delete annotation")
    }

    @Test func clearHistoryOnSaveKeepsState() {
        let store = DocumentStore()
        store.dispatch(.setSelection(Selection(t0: 0, t1: 1)))
        store.clearHistory()
        #expect(!store.canUndo && !store.canRedo)
        #expect(store.state.selection == Selection(t0: 0, t1: 1))
    }
}
