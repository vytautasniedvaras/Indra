// Wire types for the Indra backend API (docs/api.md).
// JSON uses snake_case; decode with IndraJSON.decoder (convertFromSnakeCase).

import Foundation

public enum JobState: String, Codable, Sendable {
    case queued, running, cancelled, failed, done
}

public struct ApiErrorBody: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ApiErrorEnvelope: Codable, Sendable, Equatable {
    public var error: ApiErrorBody

    public init(error: ApiErrorBody) { self.error = error }
}

public struct HealthResponse: Codable, Sendable, Equatable {
    public var status: String

    public init(status: String) { self.status = status }
}

public struct ProjectInfo: Codable, Sendable, Equatable {
    public var root: String
    public var formatVersion: Int
    public var engineVersion: String

    public init(root: String, formatVersion: Int, engineVersion: String) {
        self.root = root
        self.formatVersion = formatVersion
        self.engineVersion = engineVersion
    }
}

public struct JobCreated: Codable, Sendable, Equatable {
    public var jobId: String

    public init(jobId: String) { self.jobId = jobId }
}

public struct JobInfo: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var state: JobState
    public var progress: Double
    public var message: String
    public var etaS: Double?
    public var createdAt: Double
    public var startedAt: Double?
    public var finishedAt: Double?
    public var resultRef: [String: JSONValue]?
    public var error: [String: JSONValue]?

    public init(
        id: String, kind: String, state: JobState, progress: Double, message: String,
        etaS: Double? = nil, createdAt: Double = 0, startedAt: Double? = nil,
        finishedAt: Double? = nil, resultRef: [String: JSONValue]? = nil,
        error: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.progress = progress
        self.message = message
        self.etaS = etaS
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resultRef = resultRef
        self.error = error
    }

    public var isTerminal: Bool {
        state == .done || state == .failed || state == .cancelled
    }
}

public struct CancelResponse: Codable, Sendable, Equatable {
    public var cancelled: Bool

    public init(cancelled: Bool) { self.cancelled = cancelled }
}

public struct AudioFile: Codable, Sendable, Equatable {
    public var id: String
    public var origPath: String
    public var storedPath: String
    public var mode: String
    public var sr: Int
    public var channels: Int
    public var frames: Int
    public var durationS: Double
    public var format: String
    public var importedAt: String

    public init(
        id: String, origPath: String, storedPath: String, mode: String, sr: Int,
        channels: Int, frames: Int, durationS: Double, format: String, importedAt: String
    ) {
        self.id = id
        self.origPath = origPath
        self.storedPath = storedPath
        self.mode = mode
        self.sr = sr
        self.channels = channels
        self.frames = frames
        self.durationS = durationS
        self.format = format
        self.importedAt = importedAt
    }
}

public struct WaveformLod: Codable, Sendable, Equatable {
    public var lod: Int
    public var bucketSamples: Int
    public var buckets: Int

    public init(lod: Int, bucketSamples: Int, buckets: Int) {
        self.lod = lod
        self.bucketSamples = bucketSamples
        self.buckets = buckets
    }
}

public struct SpecLod: Codable, Sendable, Equatable {
    public var lod: Int
    public var frames: Int
    public var framesPerColumn: Int

    public init(lod: Int, frames: Int, framesPerColumn: Int) {
        self.lod = lod
        self.frames = frames
        self.framesPerColumn = framesPerColumn
    }
}

public struct SpecManifest: Codable, Sendable, Equatable {
    public var nFft: Int
    public var hop: Int
    public var window: String
    public var nBins: Int
    public var dbMin: Double
    public var dbMax: Double
    public var monoDownmix: Bool
    public var lods: [SpecLod]

    public init(
        nFft: Int, hop: Int, window: String, nBins: Int, dbMin: Double, dbMax: Double,
        monoDownmix: Bool, lods: [SpecLod]
    ) {
        self.nFft = nFft
        self.hop = hop
        self.window = window
        self.nBins = nBins
        self.dbMin = dbMin
        self.dbMax = dbMax
        self.monoDownmix = monoDownmix
        self.lods = lods
    }
}

public struct FileManifest: Codable, Sendable, Equatable {
    public var id: String
    public var sr: Int
    public var channels: Int
    public var frames: Int
    public var durationS: Double
    public var format: String
    public var waveformLods: [WaveformLod]
    public var spec: SpecManifest?
    public var features: [String]

    public init(
        id: String, sr: Int, channels: Int, frames: Int, durationS: Double, format: String,
        waveformLods: [WaveformLod], spec: SpecManifest? = nil, features: [String] = []
    ) {
        self.id = id
        self.sr = sr
        self.channels = channels
        self.frames = frames
        self.durationS = durationS
        self.format = format
        self.waveformLods = waveformLods
        self.spec = spec
        self.features = features
    }
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public var port: Int
    public var token: String
    public var pid: Int
    public var project: String

    public init(port: Int, token: String, pid: Int, project: String) {
        self.port = port
        self.token = token
        self.pid = pid
        self.project = project
    }
}

/// Named SSE event + decoded job snapshot.
public struct JobEvent: Sendable, Equatable {
    public var name: String
    public var job: JobInfo

    public init(name: String, job: JobInfo) {
        self.name = name
        self.job = job
    }

    public var isTerminal: Bool {
        name == "done" || name == "failed" || name == "cancelled"
    }
}
