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
