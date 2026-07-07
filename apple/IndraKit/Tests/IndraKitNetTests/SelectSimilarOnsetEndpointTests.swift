import Foundation
import IndraKitCore
import Testing

@testable import IndraKitNet

// POST /select/similar, /audition (three modes), /onsets/repick and
// /onsets/commit — the folder-search and onset-tweaking wire paths
// (docs/api.md; docs/design/selection-ux.md §3, §5).

@Suite("Similar-search and onset endpoints")
struct SelectSimilarOnsetEndpointTests {
    private func body(of transport: MockTransport) throws -> [String: Any] {
        let data = transport.requests.first?.httpBody ?? Data()
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func selectSimilarFolderWideSendsTargetsAndEmbed() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/select/similar", json: "{\"job_id\": \"j1\"}")
        let created = try await makeClient(transport).selectSimilar(
            audioId: "a1", t0: 3.0, t1: 5.0, threshold: 0.35, targets: .all, embed: true)
        #expect(created.jobId == "j1")
        let decoded = try body(of: transport)
        #expect(decoded["audio_id"] as? String == "a1")
        #expect(decoded["seed"] as? [String: Double] == ["t0": 3.0, "t1": 5.0])
        #expect(decoded["threshold"] as? Double == 0.35)
        #expect(decoded["targets"] as? String == "all")
        #expect(decoded["embed"] as? Bool == true)
        // use_features omitted entirely (backend 400s it alongside targets)
        #expect(decoded["use_features"] == nil)
    }

    @Test func selectSimilarSingleFileDefaultsOmitOptions() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/select/similar", json: "{\"job_id\": \"j2\"}")
        _ = try await makeClient(transport).selectSimilar(audioId: "a1", t0: 0, t1: 1)
        let decoded = try body(of: transport)
        #expect(decoded["targets"] == nil)
        #expect(decoded["embed"] == nil)
        #expect(decoded["threshold"] == nil)
    }

    @Test func selectSimilarTargetIdsList() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/select/similar", json: "{\"job_id\": \"j3\"}")
        _ = try await makeClient(transport).selectSimilar(
            audioId: "a1", t0: 0, t1: 1, targets: .ids(["a1", "b2"]))
        #expect(try body(of: transport)["targets"] as? [String] == ["a1", "b2"])
    }

    @Test func auditionSelectionModeSendsSelectionIdAndFades() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/audition", json: "{\"job_id\": \"j4\"}")
        _ = try await makeClient(transport).audition(
            audioId: "a1", mode: .selection(id: "sel9", fadeHz: 80, fadeMs: 25))
        let decoded = try body(of: transport)
        #expect(decoded["selection_id"] as? String == "sel9")
        #expect(decoded["fade_hz"] as? Double == 80)
        #expect(decoded["fade_ms"] as? Double == 25)
        #expect(decoded["mask"] == nil)
    }

    @Test func auditionSegmentsModeSendsSpans() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/audition", json: "{\"job_id\": \"j5\"}")
        _ = try await makeClient(transport).audition(
            audioId: "a1", mode: .segments([[0.0, 1.0], [2.0, 3.5]], crossfadeMs: 40))
        let decoded = try body(of: transport)
        #expect(decoded["segments"] as? [[Double]] == [[0.0, 1.0], [2.0, 3.5]])
        #expect(decoded["crossfade_ms"] as? Double == 40)
    }

    @Test func auditionMaskModePassesRectangle() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/audition", json: "{\"job_id\": \"j6\"}")
        _ = try await makeClient(transport).audition(
            audioId: "a1", mode: .mask(["t0": 1, "t1": 2, "f0": 100, "f1": 900]))
        let decoded = try body(of: transport)
        #expect(
            decoded["mask"] as? [String: Double] == ["t0": 1, "t1": 2, "f0": 100, "f1": 900])
    }

    @Test func onsetsRepickDecodesOnsets() async throws {
        let transport = MockTransport()
        transport.stub(
            "POST", "/onsets/repick",
            json: """
                {"audio_id": "a1", "source_key": "k7", "params": {"delta": 0.3}, "n": 2,
                 "onsets": {"t": [1.5, 4.0], "strength": [0.9, 0.4]}}
                """)
        let result = try await makeClient(transport).onsetsRepick(
            audioId: "a1", delta: 0.3, regionT0: 1.0, regionT1: 5.0)
        #expect(result.sourceKey == "k7")
        #expect(result.n == 2)
        #expect(result.onsets.t == [1.5, 4.0])
        #expect(result.onsets.strength == [0.9, 0.4])
        let decoded = try body(of: transport)
        #expect(decoded["delta"] as? Double == 0.3)
        #expect(decoded["region"] as? [String: Double] == ["t0": 1.0, "t1": 5.0])
        #expect(decoded["wait_s"] == nil)
    }

    @Test func onsetsCommitRoundTrips() async throws {
        let transport = MockTransport()
        transport.stub(
            "POST", "/onsets/commit",
            json: """
                {"created": 2, "annotations": [
                  {"id": 7, "audio_id": "a1", "t0": 1.5, "t1": 1.5, "f0": null, "f1": null,
                   "label": "onset", "note": "strength=0.9",
                   "created_at": "2026-01-01", "updated_at": "2026-01-01"},
                  {"id": 8, "audio_id": "a1", "t0": 4.0, "t1": 4.0, "f0": null, "f1": null,
                   "label": "onset", "note": "strength=0.4",
                   "created_at": "2026-01-01", "updated_at": "2026-01-01"}]}
                """)
        let result = try await makeClient(transport).onsetsCommit(
            audioId: "a1", times: [1.5, 4.0], strengths: [0.9, 0.4])
        #expect(result.created == 2)
        #expect(result.annotations.map(\.id) == [7, 8])
        let decoded = try body(of: transport)
        #expect(decoded["times"] as? [Double] == [1.5, 4.0])
        #expect(decoded["strengths"] as? [Double] == [0.9, 0.4])
        #expect(decoded["label"] == nil)
    }
}
