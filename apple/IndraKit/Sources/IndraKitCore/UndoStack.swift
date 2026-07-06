// Value-type undo stack over state snapshots (BUILD_SPEC §7.2).
// Any new action invalidates the redo stack (standard branching model).
// Coalescing supports Blender-style "one drag = one undo step".

import Foundation

public struct UndoStack<State: Equatable & Sendable>: Sendable {
    public private(set) var current: State
    private var undoStates: [(name: String, state: State)] = []
    private var redoStates: [(name: String, state: State)] = []
    private var coalescing: (name: String, base: State)?
    public var limit: Int

    public init(initial: State, limit: Int = 200) {
        self.current = initial
        self.limit = limit
    }

    public var canUndo: Bool { !undoStates.isEmpty || coalescing != nil }
    public var canRedo: Bool { redoStates.isEmpty == false }
    public var undoDepth: Int { undoStates.count + (coalescing == nil ? 0 : 1) }
    public var redoDepth: Int { redoStates.count }

    /// Name shown in the Edit menu ("Undo <name>").
    public var undoActionName: String? { coalescing?.name ?? undoStates.last?.name }
    public var redoActionName: String? { redoStates.last?.name }

    /// Apply a new state as a discrete undoable step.
    public mutating func apply(_ name: String, _ next: State) {
        endCoalescing()
        guard next != current else { return }
        undoStates.append((name, current))
        if undoStates.count > limit { undoStates.removeFirst() }
        redoStates.removeAll()
        current = next
    }

    /// Begin a coalesced group (e.g. a selection drag): intermediate updates
    /// collapse into a single undo step anchored at the state before the group.
    public mutating func beginCoalescing(_ name: String) {
        guard coalescing == nil else { return }
        coalescing = (name, current)
    }

    /// Update the live state inside a coalesced group (no new undo step).
    public mutating func updateCoalesced(_ next: State) {
        precondition(coalescing != nil, "updateCoalesced outside beginCoalescing")
        current = next
    }

    /// Close the group; a single undo step is recorded if the state changed.
    public mutating func endCoalescing() {
        guard let group = coalescing else { return }
        coalescing = nil
        guard group.base != current else { return }
        undoStates.append((group.name, group.base))
        if undoStates.count > limit { undoStates.removeFirst() }
        redoStates.removeAll()
    }

    @discardableResult
    public mutating func undo() -> State? {
        endCoalescing()
        guard let last = undoStates.popLast() else { return nil }
        redoStates.append((last.name, current))
        current = last.state
        return current
    }

    @discardableResult
    public mutating func redo() -> State? {
        guard let next = redoStates.popLast() else { return nil }
        undoStates.append((next.name, current))
        current = next.state
        return current
    }

    /// Cleared on document save per BUILD_SPEC §7.2 (never serialized).
    public mutating func clearHistory() {
        undoStates.removeAll()
        redoStates.removeAll()
        coalescing = nil
    }
}
