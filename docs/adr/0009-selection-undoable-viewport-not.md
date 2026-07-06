# 0009. Selection is undoable; viewport is not
Date: 2026-07-06
Status: accepted
Context: Blender-style editing treats what-you-had-selected as part of the edit history — losing a painstaking selection to a stray click must be recoverable. Zoom/pan history, by contrast, pollutes the undo stack.
Decision: EditorState (selection, annotations, labels, active analyses, lenses) is reducer-managed and undoable, with rapid selection drags coalesced into one undo step. Viewport (zoom, pan, LOD) is separate scene state, never on the undo stack. Backend history (RFC-6902 patch log) covers annotation-scope actions; selection undoes locally without a round-trip.
Consequences: Two state containers with a clear boundary; undo depth stays meaningful; menu shows action names ("Undo Add annotation").
Alternatives considered: everything undoable (viewport noise), nothing but data undoable (loses Blender-style selection recovery).
