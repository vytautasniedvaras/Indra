import Testing

@testable import IndraKitCore

@Suite("UndoStack")
struct UndoStackTests {
    @Test func applyUndoRedo() {
        var stack = UndoStack(initial: 0)
        stack.apply("set 1", 1)
        stack.apply("set 2", 2)
        #expect(stack.current == 2)
        #expect(stack.undoDepth == 2)

        #expect(stack.undo() == 1)
        #expect(stack.undo() == 0)
        #expect(stack.undo() == nil)
        #expect(stack.canRedo)

        #expect(stack.redo() == 1)
        #expect(stack.redo() == 2)
        #expect(stack.redo() == nil)
    }

    @Test func newActionInvalidatesRedo() {
        var stack = UndoStack(initial: 0)
        stack.apply("a", 1)
        stack.apply("b", 2)
        stack.undo()
        #expect(stack.canRedo)
        stack.apply("c", 9)
        #expect(!stack.canRedo)
        #expect(stack.undo() == 1)
        #expect(stack.redo() == 9)
    }

    @Test func noOpApplyRecordsNothing() {
        var stack = UndoStack(initial: 5)
        stack.apply("same", 5)
        #expect(!stack.canUndo)
    }

    @Test func actionNamesForMenus() {
        var stack = UndoStack(initial: 0)
        stack.apply("Add annotation", 1)
        #expect(stack.undoActionName == "Add annotation")
        stack.undo()
        #expect(stack.redoActionName == "Add annotation")
    }

    @Test func coalescedDragIsOneStep() {
        var stack = UndoStack(initial: 0)
        stack.beginCoalescing("Change selection")
        for value in 1...50 { stack.updateCoalesced(value) }
        stack.endCoalescing()
        #expect(stack.current == 50)
        #expect(stack.undoDepth == 1)
        #expect(stack.undo() == 0)
        #expect(stack.redo() == 50)
    }

    @Test func coalescedNoChangeRecordsNothing() {
        var stack = UndoStack(initial: 7)
        stack.beginCoalescing("drag")
        stack.updateCoalesced(8)
        stack.updateCoalesced(7)  // back where it started
        stack.endCoalescing()
        #expect(!stack.canUndo)
    }

    @Test func undoDuringCoalescingClosesGroupFirst() {
        var stack = UndoStack(initial: 0)
        stack.beginCoalescing("drag")
        stack.updateCoalesced(3)
        #expect(stack.undo() == 0)
    }

    @Test func selectionAsStateUndo() {
        // Blender-style: undo restores the previous selection (ADR 0009).
        var stack = UndoStack(initial: EditorState())
        let selected = reduce(stack.current, .setSelection(Selection(t0: 1, t1: 2)))
        stack.apply("Change selection", selected)
        let cleared = reduce(stack.current, .setSelection(nil))
        stack.apply("Clear selection", cleared)
        #expect(stack.current.selection == nil)
        stack.undo()
        #expect(stack.current.selection == Selection(t0: 1, t1: 2))
    }

    @Test func limitBoundsMemory() {
        var stack = UndoStack(initial: 0, limit: 10)
        for value in 1...100 { stack.apply("n", value) }
        #expect(stack.undoDepth == 10)
    }

    @Test func clearHistory() {
        var stack = UndoStack(initial: 0)
        stack.apply("a", 1)
        stack.undo()
        stack.clearHistory()
        #expect(!stack.canUndo && !stack.canRedo)
        #expect(stack.current == 0)
    }
}
