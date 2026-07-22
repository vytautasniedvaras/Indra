// Typed client for the Indra backend (docs/api.md). Linux-testable via
// injected HTTPTransport. Job event streams cancel the backend job when the
// consuming task is cancelled mid-flight (BUILD_SPEC §5.6).

import Foundation
import IndraKitCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct APIError: Error, Sendable, Equatable {
    public var statusCode: Int
    public var code: String
    public var message: String

    public init(statusCode: Int, code: String, message: String) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
    }
}

/// Folder-wide similar-search scope (docs/api.md POST /select/similar).
public enum SimilarTargets: Sendable, Equatable {
    /// Every imported file in the project.
    case all
    /// A specific set of audio ids.
    case ids([String])
}

/// The three POST /audition render modes (docs/api.md).
public enum AuditionMode: Sendable {
    /// Rectangle time-frequency mask: t0/t1 required, f0/f1/fade_hz/fade_ms optional.
    case mask([String: Double])
    /// A stored magic selection, feathered.
    case selection(id: String, fadeHz: Double?, fadeMs: Double?)
    /// [t0, t1] time spans joined with equal-power crossfades.
    case segments([[Double]], crossfadeMs: Double?)

    public static func selection(id: String) -> AuditionMode {
        .selection(id: id, fadeHz: nil, fadeMs: nil)
    }

    public static func segments(_ spans: [[Double]]) -> AuditionMode {
        .segments(spans, crossfadeMs: nil)
    }
}

public struct TileResponse: Sendable {
    public var data: Data
    public var shape: [Int]
    public var dtype: String
    public var bounds: [Int]

    public init(data: Data, shape: [Int], dtype: String, bounds: [Int]) {
        self.data = data
        self.shape = shape
        self.dtype = dtype
        self.bounds = bounds
    }
}

public struct APIClient: Sendable {
    public let baseURL: URL
    let token: String
    let transport: HTTPTransport

    public init(baseURL: URL, token: String, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    /// Discover a spawned backend from the session handshake file.
    public init?(sessionFile: URL, transport: HTTPTransport = URLSessionTransport()) {
        guard let data = try? Data(contentsOf: sessionFile),
            let session = try? IndraJSON.decoder().decode(SessionInfo.self, from: data),
            let url = URL(string: "http://127.0.0.1:\(session.port)")
        else { return nil }
        self.init(baseURL: url, token: session.token, transport: transport)
    }

    // MARK: - Endpoints

    public func health() async throws -> HealthResponse {
        try await get("/health")
    }

    public func project() async throws -> ProjectInfo {
        try await get("/project")
    }

    public func importFile(path: String, mode: String = "reference") async throws -> JobCreated {
        try await post("/files/import", body: ["path": .string(path), "mode": .string(mode)])
    }

    public func files() async throws -> [AudioFile] {
        try await get("/files")
    }

    public func manifest(audioId: String) async throws -> FileManifest {
        try await get("/files/\(audioId)/manifest")
    }

    public func analyze(
        kind: String, audioId: String = "", params: [String: JSONValue] = [:]
    ) async throws -> JobCreated {
        try await post(
            "/analyze",
            body: [
                "kind": .string(kind), "audio_id": .string(audioId), "params": .object(params),
            ])
    }

    public func jobs() async throws -> [JobInfo] {
        try await get("/jobs")
    }

    public func job(id: String) async throws -> JobInfo {
        try await get("/jobs/\(id)")
    }

    @discardableResult
    public func cancelJob(id: String) async throws -> CancelResponse {
        try await post("/jobs/\(id)/cancel", body: nil)
    }

    public func waveformTile(
        audioId: String, lod: Int, start: Int, count: Int
    ) async throws -> TileResponse {
        try await tile(
            path: "/files/\(audioId)/waveform/tile",
            query: [("lod", "\(lod)"), ("start", "\(start)"), ("count", "\(count)")])
    }

    public func specTile(
        audioId: String, lod: Int, t0: Int, t1: Int, f0: Int? = nil, f1: Int? = nil
    ) async throws -> TileResponse {
        var query = [("lod", "\(lod)"), ("t0", "\(t0)"), ("t1", "\(t1)")]
        if let f0 { query.append(("f0", "\(f0)")) }
        if let f1 { query.append(("f1", "\(f1)")) }
        return try await tile(path: "/files/\(audioId)/spec/tile", query: query)
    }

    /// POST /select/magic — magic-wand region grow on the dB pyramid
    /// (docs/api.md). `seed` is either a point `["t": …, "f": …]` or a box
    /// `["t0": …, "t1": …, "f0": …, "f1": …]`. Ribbons arrive in the job's
    /// result_ref (parse with MagicSelection).
    public func magicSelect(
        audioId: String, seed: [String: Double], toleranceDb: Double? = nil,
        contiguous: Bool? = nil, adapt: String? = nil, maxExtentS: Double? = nil
    ) async throws -> JobCreated {
        var body: [String: JSONValue] = [
            "audio_id": .string(audioId),
            "seed": .object(seed.mapValues { JSONValue.number($0) }),
        ]
        if let toleranceDb { body["tolerance_db"] = .number(toleranceDb) }
        if let contiguous { body["contiguous"] = .bool(contiguous) }
        if let adapt { body["adapt"] = .string(adapt) }
        if let maxExtentS { body["max_extent_s"] = .number(maxExtentS) }
        return try await post("/select/magic", body: body)
    }

    /// POST /select/similar — find segments that sound like the seed window
    /// (docs/api.md). `targets` nil = seed file only; `.all` / `.ids` scans a
    /// folder; `embed` attaches the constellation-view cluster map. Parse the
    /// job's result_ref with SimilarSearchResult.
    public func selectSimilar(
        audioId: String, t0: Double, t1: Double, threshold: Double? = nil,
        minSegmentS: Double? = nil, useFeatures: [String] = [],
        targets: SimilarTargets? = nil, embed: Bool = false
    ) async throws -> JobCreated {
        var body: [String: JSONValue] = [
            "audio_id": .string(audioId),
            "seed": .object(["t0": .number(t0), "t1": .number(t1)]),
        ]
        if let threshold { body["threshold"] = .number(threshold) }
        if let minSegmentS { body["min_segment_s"] = .number(minSegmentS) }
        if !useFeatures.isEmpty { body["use_features"] = .array(useFeatures.map { .string($0) }) }
        switch targets {
        case .all: body["targets"] = .string("all")
        case .ids(let ids): body["targets"] = .array(ids.map { .string($0) })
        case nil: break
        }
        if embed { body["embed"] = .bool(true) }
        return try await post("/select/similar", body: body)
    }

    /// POST /audition — render a selection to a scratch WAV, one of three
    /// modes (docs/api.md). Job result_ref carries wav_path + audition_id.
    public func audition(audioId: String, mode: AuditionMode) async throws -> JobCreated {
        var body: [String: JSONValue] = ["audio_id": .string(audioId)]
        switch mode {
        case .mask(let mask):
            body["mask"] = .object(mask.mapValues { .number($0) })
        case .selection(let id, let fadeHz, let fadeMs):
            body["selection_id"] = .string(id)
            if let fadeHz { body["fade_hz"] = .number(fadeHz) }
            if let fadeMs { body["fade_ms"] = .number(fadeMs) }
        case .segments(let spans, let crossfadeMs):
            body["segments"] = .array(spans.map { span in .array(span.map { .number($0) }) })
            if let crossfadeMs { body["crossfade_ms"] = .number(crossfadeMs) }
        }
        return try await post("/audition", body: body)
    }

    /// POST /onsets/repick — synchronous batch re-threshold on the saved
    /// onset envelope (docs/api.md); cheap enough for a live slider. Params in
    /// seconds; nil = the original detection's value.
    public func onsetsRepick(
        audioId: String, key: String? = nil, delta: Double? = nil, waitS: Double? = nil,
        preMaxS: Double? = nil, postMaxS: Double? = nil, preAvgS: Double? = nil,
        postAvgS: Double? = nil, regionT0: Double? = nil, regionT1: Double? = nil
    ) async throws -> OnsetRepickResult {
        var body: [String: JSONValue] = ["audio_id": .string(audioId)]
        if let key { body["key"] = .string(key) }
        if let delta { body["delta"] = .number(delta) }
        if let waitS { body["wait_s"] = .number(waitS) }
        if let preMaxS { body["pre_max_s"] = .number(preMaxS) }
        if let postMaxS { body["post_max_s"] = .number(postMaxS) }
        if let preAvgS { body["pre_avg_s"] = .number(preAvgS) }
        if let postAvgS { body["post_avg_s"] = .number(postAvgS) }
        if regionT0 != nil || regionT1 != nil {
            var region: [String: JSONValue] = [:]
            if let regionT0 { region["t0"] = .number(regionT0) }
            if let regionT1 { region["t1"] = .number(regionT1) }
            body["region"] = .object(region)
        }
        return try await post("/onsets/repick", body: body)
    }

    /// POST /onsets/commit — picked onsets → point annotations, ONE undo step.
    public func onsetsCommit(
        audioId: String, times: [Double], strengths: [Double]? = nil, label: String? = nil
    ) async throws -> OnsetCommitResult {
        var body: [String: JSONValue] = [
            "audio_id": .string(audioId),
            "times": .array(times.map { .number($0) }),
        ]
        if let strengths { body["strengths"] = .array(strengths.map { .number($0) }) }
        if let label { body["label"] = .string(label) }
        return try await post("/onsets/commit", body: body)
    }

    /// GET /files/{id}/features/{kind} — a computed feature curve, min/max
    /// bucketed to `downsample` display columns when given (§4.4; raw values
    /// are capped server-side at 20 000 points). Decoded with the plain
    /// decoder so bucket column names survive verbatim (see FeatureTable).
    public func featureTable(
        audioId: String, kind: String, t0: Double? = nil, t1: Double? = nil,
        downsample: Int? = nil, key: String? = nil
    ) async throws -> FeatureTable {
        var query: [(String, String)] = []
        if let t0 { query.append(("t0", "\(t0)")) }
        if let t1 { query.append(("t1", "\(t1)")) }
        if let downsample { query.append(("downsample", "\(downsample)")) }
        if let key { query.append(("key", key)) }
        let (data, info) = try await transport.send(
            makeRequest(path: "/files/\(audioId)/features/\(kind)", method: "GET", query: query))
        guard (200..<300).contains(info.statusCode) else { throw apiError(data, info) }
        return try FeatureTable.decode(data)
    }

    public func annotations(audioId: String) async throws -> [AnnotationRecord] {
        try await get("/annotations", query: [("audio_id", audioId)])
    }

    public func createAnnotation(_ create: AnnotationCreate) async throws -> AnnotationRecord {
        try await send("/annotations", method: "POST", body: create)
    }

    public func updateAnnotation(id: Int, _ patch: AnnotationPatch) async throws
        -> AnnotationRecord
    {
        try await send("/annotations/\(id)", method: "PATCH", body: patch)
    }

    /// DELETE answers 204 (or 200); any success body is ignored.
    public func deleteAnnotation(id: Int) async throws {
        let (data, info) = try await transport.send(
            makeRequest(path: "/annotations/\(id)", method: "DELETE"))
        guard (200..<300).contains(info.statusCode) else { throw apiError(data, info) }
    }

    public func undo() async throws -> UndoResponse {
        try await post("/undo", body: nil)
    }

    public func redo() async throws -> UndoResponse {
        try await post("/redo", body: nil)
    }

    public func history() async throws -> [HistoryEntry] {
        try await get("/history")
    }

    /// SSE job progress stream. Terminating the consumer before a terminal
    /// event arrives cancels the backend job (BUILD_SPEC §4.5, §5.6).
    public func jobEvents(id jobId: String) -> AsyncThrowingStream<JobEvent, Error> {
        let request = makeRequest(path: "/jobs/\(jobId)/events", method: "GET")
        let client = self
        let sawTerminal = Locked(false)
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    let (chunks, info) = try await client.transport.stream(request)
                    guard info.statusCode == 200 else {
                        throw APIError(
                            statusCode: info.statusCode, code: "stream_failed",
                            message: "SSE endpoint returned \(info.statusCode)")
                    }
                    var parser = SSEParser()
                    let decoder = IndraJSON.decoder()
                    for try await chunk in chunks {
                        for sse in parser.feed(chunk) {
                            guard let data = sse.data.data(using: .utf8) else { continue }
                            let job = try decoder.decode(JobInfo.self, from: data)
                            let event = JobEvent(name: sse.event ?? "progress", job: job)
                            continuation.yield(event)
                            if event.isTerminal {
                                sawTerminal.withLock { $0 = true }
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                // Cancel the backend job unless it already finished on its own.
                if !sawTerminal.withLock({ $0 }) {
                    Task { try? await client.cancelJob(id: jobId) }
                }
            }
        }
    }

    // MARK: - Plumbing

    func makeRequest(
        path: String, method: String, query: [(String, String)] = [], body: Data? = nil
    ) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws
        -> T
    {
        let (data, info) = try await transport.send(
            makeRequest(path: path, method: "GET", query: query))
        return try decode(data, info)
    }

    private func post<T: Decodable>(_ path: String, body: [String: JSONValue]?) async throws -> T {
        let payload = body.map { try? IndraJSON.encoder().encode($0) } ?? nil
        let (data, info) = try await transport.send(
            makeRequest(path: path, method: "POST", body: payload))
        return try decode(data, info)
    }

    private func send<Body: Encodable, T: Decodable>(
        _ path: String, method: String, body: Body
    ) async throws -> T {
        let payload = try IndraJSON.encoder().encode(body)
        let (data, info) = try await transport.send(
            makeRequest(path: path, method: method, body: payload))
        return try decode(data, info)
    }

    private func tile(path: String, query: [(String, String)]) async throws -> TileResponse {
        let (data, info) = try await transport.send(
            makeRequest(path: path, method: "GET", query: query))
        guard info.statusCode == 200 else { throw apiError(data, info) }
        func ints(_ header: String) -> [Int] {
            (info.header(header) ?? "").split(separator: ",").compactMap { Int($0) }
        }
        return TileResponse(
            data: data,
            shape: ints("x-indra-tile-shape"),
            dtype: info.header("x-indra-tile-dtype") ?? "",
            bounds: ints("x-indra-tile-bounds"))
    }

    private func decode<T: Decodable>(_ data: Data, _ info: HTTPResponseInfo) throws -> T {
        guard (200..<300).contains(info.statusCode) else { throw apiError(data, info) }
        return try IndraJSON.decoder().decode(T.self, from: data)
    }

    private func apiError(_ data: Data, _ info: HTTPResponseInfo) -> APIError {
        if let envelope = try? IndraJSON.decoder().decode(ApiErrorEnvelope.self, from: data) {
            return APIError(
                statusCode: info.statusCode, code: envelope.error.code,
                message: envelope.error.message)
        }
        return APIError(
            statusCode: info.statusCode, code: "http_\(info.statusCode)",
            message: String(decoding: data.prefix(200), as: UTF8.self))
    }
}

/// DocumentStore's backend sync surface (BUILD_SPEC §7.2) maps directly onto
/// the annotation and undo endpoints.
extension APIClient: AnnotationSyncing {
    public func undoRemote() async throws -> UndoResponse { try await undo() }
    public func redoRemote() async throws -> UndoResponse { try await redo() }
}
