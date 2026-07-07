// Editor state and pure reducer (BUILD_SPEC §5.7, §7.2, ADR 0009).
// Selection IS part of undoable state (Blender-style). Viewport is NOT here —
// zoom/pan/LOD live in separate scene state that never enters the undo stack.

import Foundation

/// A time or time-frequency selection. `f0`/`f1` nil means full-band (time-only).
public struct Selection: Codable, Sendable, Equatable {
    public var t0: Double
    public var t1: Double
    public var f0: Double?
    public var f1: Double?

    public init(t0: Double, t1: Double, f0: Double? = nil, f1: Double? = nil) {
        self.t0 = min(t0, t1)
        self.t1 = max(t0, t1)
        if let f0, let f1 {
            self.f0 = min(f0, f1)
            self.f1 = max(f0, f1)
        } else {
            self.f0 = f0
            self.f1 = f1
        }
    }
}

public struct Annotation: Codable, Sendable, Equatable, Identifiable {
    /// Server id once persisted; local UUID string before first sync.
    public var id: String
    public var audioId: String
    public var t0: Double
    public var t1: Double
    public var f0: Double?
    public var f1: Double?
    public var label: String?
    public var note: String?

    public init(
        id: String, audioId: String, t0: Double, t1: Double,
        f0: Double? = nil, f1: Double? = nil, label: String? = nil, note: String? = nil
    ) {
        self.id = id
        self.audioId = audioId
        self.t0 = t0
        self.t1 = t1
        self.f0 = f0
        self.f1 = f1
        self.label = label
        self.note = note
    }
}

public struct EditorState: Codable, Sendable, Equatable {
    public var activeAudioId: String?
    public var selection: Selection?
    /// The active magic selection's cache key (§5.7: selection is undoable —
    /// this is the flagship selection). Ribbon geometry itself is derived
    /// data, re-fetchable from the analysis cache by this id.
    public var magicSelectionId: String?
    public var annotations: [Annotation]
    public var lensesEnabled: Set<String>

    public init(
        activeAudioId: String? = nil,
        selection: Selection? = nil,
        magicSelectionId: String? = nil,
        annotations: [Annotation] = [],
        lensesEnabled: Set<String> = []
    ) {
        self.activeAudioId = activeAudioId
        self.selection = selection
        self.magicSelectionId = magicSelectionId
        self.annotations = annotations
        self.lensesEnabled = lensesEnabled
    }
}

public enum EditorAction: Sendable, Equatable {
    case setActiveAudio(String?)
    case setSelection(Selection?)
    case setMagicSelection(String?)
    case addAnnotation(Annotation)
    case updateAnnotation(Annotation)
    case deleteAnnotation(id: String)
    case toggleLens(String)

    /// Menu-facing name ("Undo Add annotation") per BUILD_SPEC §7.3.
    public var name: String {
        switch self {
        case .setActiveAudio: "Switch file"
        case .setSelection(let selection): selection == nil ? "Clear selection" : "Change selection"
        case .setMagicSelection(let id): id == nil ? "Clear magic selection" : "Magic select"
        case .addAnnotation: "Add annotation"
        case .updateAnnotation: "Edit annotation"
        case .deleteAnnotation: "Delete annotation"
        case .toggleLens: "Toggle lens"
        }
    }
}

/// Pure reducer: no side effects, deterministic, identity on no-ops.
public func reduce(_ state: EditorState, _ action: EditorAction) -> EditorState {
    var next = state
    switch action {
    case .setActiveAudio(let audioId):
        guard audioId != state.activeAudioId else { return state }
        next.activeAudioId = audioId
        next.selection = nil
        next.magicSelectionId = nil
    case .setSelection(let selection):
        guard selection != state.selection else { return state }
        next.selection = selection
    case .setMagicSelection(let id):
        guard id != state.magicSelectionId else { return state }
        next.magicSelectionId = id
    case .addAnnotation(let annotation):
        guard !state.annotations.contains(where: { $0.id == annotation.id }) else { return state }
        next.annotations.append(annotation)
    case .updateAnnotation(let annotation):
        guard let index = state.annotations.firstIndex(where: { $0.id == annotation.id }) else {
            return state
        }
        guard state.annotations[index] != annotation else { return state }
        next.annotations[index] = annotation
    case .deleteAnnotation(let id):
        guard state.annotations.contains(where: { $0.id == id }) else { return state }
        next.annotations.removeAll { $0.id == id }
    case .toggleLens(let lens):
        if next.lensesEnabled.contains(lens) {
            next.lensesEnabled.remove(lens)
        } else {
            next.lensesEnabled.insert(lens)
        }
    }
    return next
}
