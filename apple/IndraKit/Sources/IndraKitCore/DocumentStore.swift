// DocumentStore: reducer + undo stack + backend sync split (BUILD_SPEC §7.2).
// Deliberately NOT @Observable — this stays platform-neutral and Linux-testable;
// the app layer wraps it for SwiftUI. Local-only actions (selection, lens,
// active file) undo purely in-process; annotation actions are additionally
// forwarded fire-and-forget to an AnnotationSyncing backend, whose
// authoritative history answers POST /undo / /redo (§5.7, §7.1).

import Foundation

/// Backend sync surface for annotation-scoped actions. APIClient conforms in
/// IndraKitNet; tests inject a spy. Named `undoRemote`/`redoRemote` to avoid
/// clashing with the local `DocumentStore.undo()`/`redo()`.
public protocol AnnotationSyncing: Sendable {
    func createAnnotation(_ create: AnnotationCreate) async throws -> AnnotationRecord
    func updateAnnotation(id: Int, _ patch: AnnotationPatch) async throws -> AnnotationRecord
    func deleteAnnotation(id: Int) async throws
    func undoRemote() async throws -> UndoResponse
    func redoRemote() async throws -> UndoResponse
}

public final class DocumentStore {
    private var stack: UndoStack<EditorState>
    private let sync: (any AnnotationSyncing)?
    private let errorLog = LockedBox<[String]>([])
    /// In-flight fire-and-forget sync tasks; tests await these via flushSync().
    public private(set) var pendingSyncTasks: [Task<Void, Never>] = []

    public init(
        initial: EditorState = EditorState(), sync: (any AnnotationSyncing)? = nil,
        undoLimit: Int = 200
    ) {
        self.stack = UndoStack(initial: initial, limit: undoLimit)
        self.sync = sync
    }

    public var state: EditorState { stack.current }
    public var canUndo: Bool { stack.canUndo }
    public var canRedo: Bool { stack.canRedo }
    /// Name shown in the Edit menu ("Undo <name>") per BUILD_SPEC §7.3.
    public var undoActionName: String? { stack.undoActionName }
    public var redoActionName: String? { stack.redoActionName }
    /// Failures from fire-and-forget backend sync, for the app layer to surface.
    public var syncErrors: [String] { errorLog.withLock { $0 } }

    // MARK: - Dispatch

    /// Apply an action through the pure reducer as one undo step. No-ops
    /// (reducer returns the same state) record nothing and never sync.
    public func dispatch(_ action: EditorAction) {
        let before = stack.current
        let next = reduce(before, action)
        guard next != before else { return }
        stack.apply(action.name, next)
        forwardToBackend(action)
    }

    // MARK: - Selection drag coalescing (one drag = one undo step, §5.7)

    /// Undo name for a coalesced drag — matches EditorAction.setSelection(_:).name.
    private static let selectionDragName = "Change selection"

    public func beginSelectionDrag() {
        stack.beginCoalescing(Self.selectionDragName)
    }

    /// Live selection update inside a drag; must be bracketed by
    /// beginSelectionDrag()/endSelectionDrag().
    public func updateSelectionDrag(_ selection: Selection?) {
        stack.updateCoalesced(reduce(stack.current, .setSelection(selection)))
    }

    public func endSelectionDrag() {
        stack.endCoalescing()
    }

    // MARK: - Undo / redo

    /// Undo one step, returning the restored state (nil if nothing to undo).
    /// Annotation-scoped steps also POST /undo to the backend (§5.7); local-only
    /// steps (selection, lens, active file) never leave the process.
    @discardableResult
    public func undo() -> EditorState? {
        stack.endCoalescing()  // an open drag closes first, so the name is its step's
        let name = stack.undoActionName
        guard let restored = stack.undo() else { return nil }
        if let name, Self.annotationActionNames.contains(name) {
            forward { _ = try await $0.undoRemote() }
        }
        return restored
    }

    @discardableResult
    public func redo() -> EditorState? {
        let name = stack.redoActionName
        guard let restored = stack.redo() else { return nil }
        if let name, Self.annotationActionNames.contains(name) {
            forward { _ = try await $0.redoRemote() }
        }
        return restored
    }

    /// Cleared on document save per BUILD_SPEC §7.2 (never serialized).
    public func clearHistory() {
        stack.clearHistory()
    }

    /// Await all in-flight sync tasks (tests; app teardown).
    public func flushSync() async {
        let tasks = pendingSyncTasks
        pendingSyncTasks.removeAll()
        for task in tasks { await task.value }
    }

    // MARK: - Backend forwarding

    /// Undo-step names that mirror to the backend undo_log (§7.1). Must match
    /// EditorAction.name — asserted by DocumentStoreTests.
    private static let annotationActionNames: Set<String> = [
        "Add annotation", "Edit annotation", "Delete annotation",
    ]

    private func forwardToBackend(_ action: EditorAction) {
        switch action {
        case .addAnnotation(let annotation):
            let create = AnnotationCreate(annotation)
            forward { _ = try await $0.createAnnotation(create) }
        case .updateAnnotation(let annotation):
            guard let id = Int(annotation.id) else {
                recordSyncError("edit of unsynced annotation \(annotation.id) not forwarded")
                return
            }
            let patch = AnnotationPatch(annotation)
            forward { _ = try await $0.updateAnnotation(id: id, patch) }
        case .deleteAnnotation(let id):
            guard let serverId = Int(id) else {
                recordSyncError("delete of unsynced annotation \(id) not forwarded")
                return
            }
            forward { try await $0.deleteAnnotation(id: serverId) }
        case .setActiveAudio, .setSelection, .setMagicSelection, .toggleLens:
            break  // local-only (§5.7); magic ribbons are regenerable cache data
        }
    }

    /// Fire-and-forget: failures land in syncErrors, never throw into the UI.
    /// The task captures only Sendable values (never self).
    private func forward(
        _ operation: @escaping @Sendable (any AnnotationSyncing) async throws -> Void
    ) {
        guard let sync else { return }
        let errorLog = self.errorLog
        pendingSyncTasks.append(
            Task {
                do {
                    try await operation(sync)
                } catch {
                    errorLog.withLock { $0.append("\(error)") }
                }
            })
    }

    private func recordSyncError(_ message: String) {
        guard sync != nil else { return }  // nothing to sync to — not an error
        errorLog.withLock { $0.append(message) }
    }
}

/// Locked box for cross-task mutation under Swift 6 strict concurrency
/// (Core-local twin of IndraKitNet's Locked — Core cannot depend on Net).
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
