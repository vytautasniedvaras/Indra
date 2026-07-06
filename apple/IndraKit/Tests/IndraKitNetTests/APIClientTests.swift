import Foundation
import IndraKitCore
import Testing

@testable import IndraKitNet

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Mock transport

/// Records requests; serves canned buffered responses and scripted SSE streams.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private let lock = NSLock()
    private var stubs: [String: Stub] = [:]  // keyed by "METHOD path"
    private var recorded: [URLRequest] = []
    private var streamChunks: [String] = []
    private var streamStaysOpen = false

    func stub(_ method: String, _ path: String, json: String, status: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        stubs["\(method) \(path)"] = Stub(status: status, body: Data(json.utf8))
    }

    func stubTile(_ path: String, bytes: Data, headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        stubs["GET \(path)"] = Stub(status: 200, headers: headers, body: bytes)
    }

    func scriptStream(_ chunks: [String], staysOpen: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        streamChunks = chunks
        streamStaysOpen = staysOpen
    }

    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var requests: [URLRequest] {
        withLock { recorded }
    }

    func requestPaths() -> [String] {
        requests.map { "\($0.httpMethod ?? "?") \($0.url?.path ?? "?")" }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseInfo) {
        let stub = withLock {
            recorded.append(request)
            return stubs["\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"]
        }
        guard let stub else {
            return (
                Data("{\"error\":{\"code\":\"not_found\",\"message\":\"no stub\",\"details\":{}}}".utf8),
                HTTPResponseInfo(statusCode: 404, headers: [:])
            )
        }
        return (stub.body, HTTPResponseInfo(statusCode: stub.status, headers: stub.headers))
    }

    func stream(_ request: URLRequest) async throws -> (
        AsyncThrowingStream<Data, Error>, HTTPResponseInfo
    ) {
        let (chunks, staysOpen) = withLock {
            recorded.append(request)
            return (streamChunks, streamStaysOpen)
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks {
                continuation.yield(Data(chunk.utf8))
            }
            if !staysOpen {
                continuation.finish()
            }
        }
        return (stream, HTTPResponseInfo(statusCode: 200, headers: [:]))
    }
}

func makeClient(_ transport: MockTransport) -> APIClient {
    APIClient(baseURL: URL(string: "http://127.0.0.1:9999")!, token: "tok", transport: transport)
}

func jobJSON(_ id: String, state: String, progress: Double) -> String {
    """
    {"id": "\(id)", "kind": "debug_slow", "state": "\(state)", "progress": \(progress),
     "message": "", "eta_s": null, "created_at": 0, "started_at": 0, "finished_at": null,
     "result_ref": null, "error": null}
    """.replacingOccurrences(of: "\n", with: " ")
}

// MARK: - Tests

@Suite("APIClient")
struct APIClientTests {
    @Test func bearerTokenOnEveryRequest() async throws {
        let transport = MockTransport()
        transport.stub("GET", "/project",
            json: "{\"root\": \"/x.indra\", \"format_version\": 1, \"engine_version\": \"e 1\"}")
        let client = makeClient(transport)
        _ = try await client.project()
        #expect(
            transport.requests.first?.value(forHTTPHeaderField: "Authorization")
                == "Bearer tok")
    }

    @Test func importFilePostsJSONBody() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/files/import", json: "{\"job_id\": \"j1\"}")
        let client = makeClient(transport)
        let created = try await client.importFile(path: "/tmp/a.wav", mode: "copy")
        #expect(created.jobId == "j1")
        let body = transport.requests.first?.httpBody ?? Data()
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded == ["path": "/tmp/a.wav", "mode": "copy"])
    }

    @Test func errorEnvelopeBecomesAPIError() async throws {
        let transport = MockTransport()
        transport.stub("GET", "/jobs/nope",
            json: "{\"error\": {\"code\": \"not_found\", \"message\": \"no such job\", \"details\": {}}}",
            status: 404)
        let client = makeClient(transport)
        do {
            _ = try await client.job(id: "nope")
            Issue.record("expected APIError")
        } catch let error as APIError {
            #expect(error.statusCode == 404)
            #expect(error.code == "not_found")
        }
    }

    @Test func tileParsesHeaders() async throws {
        let transport = MockTransport()
        transport.stubTile(
            "/files/a/spec/tile",
            bytes: Data(repeating: 9, count: 32),
            headers: [
                "x-indra-tile-shape": "4,8",
                "x-indra-tile-dtype": "uint8",
                "x-indra-tile-bounds": "0,4,0,8",
            ])
        let client = makeClient(transport)
        let tile = try await client.specTile(audioId: "a", lod: 0, t0: 0, t1: 4)
        #expect(tile.shape == [4, 8])
        #expect(tile.dtype == "uint8")
        #expect(tile.bounds == [0, 4, 0, 8])
        #expect(tile.data.count == 32)
        let url = transport.requests.first?.url?.absoluteString ?? ""
        #expect(url.contains("lod=0") && url.contains("t0=0") && url.contains("t1=4"))
    }

    @Test func jobEventsStreamDecodesAndFinishesOnTerminal() async throws {
        let transport = MockTransport()
        transport.scriptStream([
            "event: progress\ndata: \(jobJSON("j1", state: "running", progress: 0.5))\n\n",
            "event: done\ndata: \(jobJSON("j1", state: "done", progress: 1.0))\n\n",
            // Anything after a terminal event must be ignored.
            "event: progress\ndata: \(jobJSON("j1", state: "running", progress: 0.1))\n\n",
        ])
        let client = makeClient(transport)
        var events: [JobEvent] = []
        for try await event in client.jobEvents(id: "j1") {
            events.append(event)
        }
        #expect(events.count == 2)
        #expect(events.last?.name == "done")
        #expect(events.last?.job.state == .done)
        // Normal completion must NOT fire a cancel request.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!transport.requestPaths().contains("POST /jobs/j1/cancel"))
    }

    @Test func cancellingConsumerCancelsBackendJob() async throws {
        let transport = MockTransport()
        transport.scriptStream(
            ["event: progress\ndata: \(jobJSON("j2", state: "running", progress: 0.1))\n\n"],
            staysOpen: true)
        let client = makeClient(transport)

        let consumer = Task {
            for try await _ in client.jobEvents(id: "j2") {
                // Cancel after the first event arrives.
                break
            }
        }
        _ = try await consumer.value

        // onTermination posts the cancel asynchronously; poll briefly.
        var sawCancel = false
        for _ in 0..<50 {
            if transport.requestPaths().contains("POST /jobs/j2/cancel") {
                sawCancel = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sawCancel, "breaking out of the event stream must cancel the job")
    }

    @Test func sessionFileDiscovery() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.json")
        try Data(
            "{\"port\": 4567, \"token\": \"abc\", \"pid\": 1, \"project\": \"/x\"}".utf8
        ).write(to: file)
        let client = APIClient(sessionFile: file, transport: MockTransport())
        #expect(client?.baseURL.absoluteString == "http://127.0.0.1:4567")
    }
}
