import Foundation
import IndraKitCore
import Testing

@testable import IndraKitNet

// POST /select/magic and GET /files/{id}/features/{kind} — the renderer's
// magic-selection and curve-lane data paths (BUILD_SPEC §5.3 overlays).

@Suite("Selection and feature endpoints")
struct SelectionFeatureEndpointTests {
    @Test func magicSelectPostsSeedAndOptions() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/select/magic", json: "{\"job_id\": \"j9\"}")
        let client = makeClient(transport)
        let created = try await client.magicSelect(
            audioId: "a1", seed: ["t0": 1.0, "t1": 2.0, "f0": 100.0, "f1": 500.0],
            toleranceDb: 6.0)
        #expect(created.jobId == "j9")
        let body = transport.requests.first?.httpBody ?? Data()
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["audio_id"] as? String == "a1")
        #expect(decoded?["tolerance_db"] as? Double == 6.0)
        let seed = decoded?["seed"] as? [String: Double]
        #expect(seed == ["t0": 1.0, "t1": 2.0, "f0": 100.0, "f1": 500.0])
        // Unset options must be omitted (backend defaults apply).
        #expect(decoded?["contiguous"] == nil)
        #expect(decoded?["adapt"] == nil)
    }

    @Test func magicSelectPointSeed() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/select/magic", json: "{\"job_id\": \"j10\"}")
        let client = makeClient(transport)
        _ = try await client.magicSelect(audioId: "a1", seed: ["t": 12.5, "f": 440.0])
        let body = transport.requests.first?.httpBody ?? Data()
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["seed"] as? [String: Double] == ["t": 12.5, "f": 440.0])
    }

    @Test func featureTableRequestsBucketsAtDisplayWidth() async throws {
        let transport = MockTransport()
        transport.stub(
            "GET", "/files/a1/features/roughness_mpt",
            json: """
                {"audio_id": "a1", "kind": "roughness_mpt", "cache_key": "k1",
                 "n": 100, "columns": ["value"],
                 "buckets": {"value": {"t": [1.0], "min": [0.1], "max": [0.9]}}}
                """)
        let client = makeClient(transport)
        let table = try await client.featureTable(
            audioId: "a1", kind: "roughness_mpt", t0: 0, t1: 60, downsample: 800)
        #expect(table.kind == "roughness_mpt")
        #expect(table.buckets?["value"]?.max == [0.9])
        let url = transport.requests.first?.url?.absoluteString ?? ""
        #expect(url.contains("t0=0") && url.contains("t1=60") && url.contains("downsample=800"))
    }

    @Test func featureTable404BecomesAPIError() async throws {
        let transport = MockTransport()
        transport.stub(
            "GET", "/files/a1/features/nope",
            json: "{\"error\": {\"code\": \"not_found\", \"message\": \"gone\", \"details\": {}}}",
            status: 404)
        let client = makeClient(transport)
        do {
            _ = try await client.featureTable(audioId: "a1", kind: "nope")
            Issue.record("expected APIError")
        } catch let error as APIError {
            #expect(error.statusCode == 404)
            #expect(error.code == "not_found")
        }
    }
}
