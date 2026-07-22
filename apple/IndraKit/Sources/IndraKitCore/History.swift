// Phase 3 wire types: annotations CRUD + backend-authoritative undo/history
// (docs/api.md, BUILD_SPEC §7.3). JSON uses snake_case; code with IndraJSON.

import Foundation

/// Persisted annotation as returned by the backend.
public struct AnnotationRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var audioId: String
    public var t0: Double
    public var t1: Double
    public var f0: Double?
    public var f1: Double?
    public var label: String?
    public var note: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: Int, audioId: String, t0: Double, t1: Double,
        f0: Double? = nil, f1: Double? = nil, label: String? = nil, note: String? = nil,
        createdAt: String = "", updatedAt: String = ""
    ) {
        self.id = id
        self.audioId = audioId
        self.t0 = t0
        self.t1 = t1
        self.f0 = f0
        self.f1 = f1
        self.label = label
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Local editor-state mirror of this record.
    public var asAnnotation: Annotation {
        Annotation(
            id: String(id), audioId: audioId, t0: t0, t1: t1,
            f0: f0, f1: f1, label: label, note: note)
    }
}

/// Request body for `POST /annotations`.
public struct AnnotationCreate: Codable, Sendable, Equatable {
    public var audioId: String
    public var t0: Double
    public var t1: Double
    public var f0: Double?
    public var f1: Double?
    public var label: String?
    public var note: String?

    public init(
        audioId: String, t0: Double, t1: Double,
        f0: Double? = nil, f1: Double? = nil, label: String? = nil, note: String? = nil
    ) {
        self.audioId = audioId
        self.t0 = t0
        self.t1 = t1
        self.f0 = f0
        self.f1 = f1
        self.label = label
        self.note = note
    }

    public init(_ annotation: Annotation) {
        self.init(
            audioId: annotation.audioId, t0: annotation.t0, t1: annotation.t1,
            f0: annotation.f0, f1: annotation.f1, label: annotation.label,
            note: annotation.note)
    }
}

/// Request body for `PATCH /annotations/{id}`; nil fields are omitted from the
/// JSON and left unchanged by the backend.
public struct AnnotationPatch: Codable, Sendable, Equatable {
    public var audioId: String?
    public var t0: Double?
    public var t1: Double?
    public var f0: Double?
    public var f1: Double?
    public var label: String?
    public var note: String?

    public init(
        audioId: String? = nil, t0: Double? = nil, t1: Double? = nil,
        f0: Double? = nil, f1: Double? = nil, label: String? = nil, note: String? = nil
    ) {
        self.audioId = audioId
        self.t0 = t0
        self.t1 = t1
        self.f0 = f0
        self.f1 = f1
        self.label = label
        self.note = note
    }

    /// Full-replacement patch from the local annotation (annotations never
    /// move between files, so audioId stays unset).
    public init(_ annotation: Annotation) {
        self.init(
            t0: annotation.t0, t1: annotation.t1, f0: annotation.f0, f1: annotation.f1,
            label: annotation.label, note: annotation.note)
    }
}

/// `POST /undo` and `POST /redo` response (BUILD_SPEC §7.3). `appliedPatch`
/// is the RFC-6902 patch the backend just applied to its own state.
public struct UndoResponse: Codable, Sendable, Equatable {
    public var appliedPatch: [JSONValue]
    public var scope: String
    public var actionName: String
    public var undoStackDepth: Int
    public var redoStackDepth: Int

    public init(
        appliedPatch: [JSONValue], scope: String, actionName: String,
        undoStackDepth: Int, redoStackDepth: Int
    ) {
        self.appliedPatch = appliedPatch
        self.scope = scope
        self.actionName = actionName
        self.undoStackDepth = undoStackDepth
        self.redoStackDepth = redoStackDepth
    }
}

/// `GET /history` entry (recent action names for menu display).
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var ts: String
    public var scope: String
    public var actionName: String

    public init(id: Int, ts: String, scope: String, actionName: String) {
        self.id = id
        self.ts = ts
        self.scope = scope
        self.actionName = actionName
    }
}
