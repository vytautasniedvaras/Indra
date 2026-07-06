import Foundation
import IndraKitCore
import Testing

@testable import IndraKitNet

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

func annotationJSON(id: Int) -> String {
    """
    {"id": \(id), "audio_id": "a1", "t0": 1.5, "t1": 2.5, "f0": 100.0, "f1": 800.0,
     "label": "bird", "note": null, "created_at": "2026-07-06T10:00:00Z",
     "updated_at": "2026-07-06T10:05:00Z"}
    """
}

@Suite("APIClient annotations + undo/history")
struct HistoryEndpointTests {
    @Test func annotationsListSendsAudioIdQuery() async throws {
        let transport = MockTransport()
        transport.stub("GET", "/annotations", json: "[\(annotationJSON(id: 3))]")
        let client = makeClient(transport)
        let records = try await client.annotations(audioId: "a1")
        #expect(records.count == 1)
        #expect(records.first?.id == 3)
        #expect(records.first?.audioId == "a1")
        #expect(records.first?.f1 == 800.0)
        #expect(records.first?.note == nil)
        #expect(records.first?.updatedAt == "2026-07-06T10:05:00Z")
        let url = transport.requests.first?.url?.absoluteString ?? ""
        #expect(url.contains("audio_id=a1"))
    }

    @Test func createAnnotationPostsSnakeCaseBody() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/annotations", json: annotationJSON(id: 9))
        let client = makeClient(transport)
        let create = AnnotationCreate(
            audioId: "a1", t0: 1.5, t1: 2.5, f0: 100, f1: 800, label: "bird")
        let record = try await client.createAnnotation(create)
        #expect(record.id == 9)
        #expect(record.createdAt == "2026-07-06T10:00:00Z")
        let body = transport.requests.first?.httpBody ?? Data()
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["audio_id"] as? String == "a1")
        #expect(decoded?["t0"] as? Double == 1.5)
        #expect(decoded?["f1"] as? Double == 800)
        #expect(decoded?["label"] as? String == "bird")
        #expect(decoded?.keys.contains("note") == false)  // nil fields omitted
    }

    @Test func updateAnnotationPatchesOnlySetFields() async throws {
        let transport = MockTransport()
        transport.stub("PATCH", "/annotations/5", json: annotationJSON(id: 5))
        let client = makeClient(transport)
        let record = try await client.updateAnnotation(id: 5, AnnotationPatch(label: "owl"))
        #expect(record.id == 5)
        let request = transport.requests.first
        #expect(request?.httpMethod == "PATCH")
        #expect(request?.url?.path == "/annotations/5")
        let body = request?.httpBody ?? Data()
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?.count == 1)
        #expect(decoded?["label"] as? String == "owl")
    }

    @Test func deleteAnnotationAccepts204() async throws {
        let transport = MockTransport()
        transport.stub("DELETE", "/annotations/5", json: "", status: 204)
        let client = makeClient(transport)
        try await client.deleteAnnotation(id: 5)
        #expect(transport.requestPaths() == ["DELETE /annotations/5"])
    }

    @Test func deleteUnknownAnnotationIs404() async throws {
        let transport = MockTransport()
        transport.stub("DELETE", "/annotations/99",
            json: "{\"error\": {\"code\": \"not_found\", \"message\": \"no such annotation\", \"details\": {}}}",
            status: 404)
        let client = makeClient(transport)
        do {
            try await client.deleteAnnotation(id: 99)
            Issue.record("expected APIError")
        } catch let error as APIError {
            #expect(error.statusCode == 404)
            #expect(error.code == "not_found")
        }
    }

    @Test func undoDecodesResponse() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/undo",
            json: """
                {"applied_patch": [{"op": "remove", "path": "/annotations/3"}],
                 "scope": "annotations", "action_name": "Add annotation",
                 "undo_stack_depth": 2, "redo_stack_depth": 1}
                """)
        let client = makeClient(transport)
        let response = try await client.undo()
        #expect(response.scope == "annotations")
        #expect(response.actionName == "Add annotation")
        #expect(response.undoStackDepth == 2)
        #expect(response.redoStackDepth == 1)
        if case .object(let op)? = response.appliedPatch.first {
            #expect(op["op"]?.stringValue == "remove")
            #expect(op["path"]?.stringValue == "/annotations/3")
        } else {
            Issue.record("expected a patch-op object")
        }
        let request = transport.requests.first
        #expect(request?.httpMethod == "POST")
        #expect(request?.httpBody == nil)  // POST /undo takes no body
    }

    @Test func redoOnEmptyStackIsConflict() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/redo",
            json: "{\"error\": {\"code\": \"conflict\", \"message\": \"nothing to redo\", \"details\": {}}}",
            status: 409)
        let client = makeClient(transport)
        do {
            _ = try await client.redo()
            Issue.record("expected APIError")
        } catch let error as APIError {
            #expect(error.statusCode == 409)
            #expect(error.code == "conflict")
        }
    }

    @Test func historyDecodesEntries() async throws {
        let transport = MockTransport()
        transport.stub("GET", "/history",
            json: """
                [{"id": 12, "ts": "2026-07-06T10:00:00Z", "scope": "annotations",
                  "action_name": "Add annotation"},
                 {"id": 11, "ts": "2026-07-06T09:59:00Z", "scope": "annotations",
                  "action_name": "Delete annotation"}]
                """)
        let client = makeClient(transport)
        let entries = try await client.history()
        #expect(entries.count == 2)
        #expect(entries.first?.id == 12)
        #expect(entries.first?.actionName == "Add annotation")
        #expect(entries.last?.scope == "annotations")
    }

    @Test func apiClientConformsToAnnotationSyncing() async throws {
        let transport = MockTransport()
        transport.stub("POST", "/redo",
            json: """
                {"applied_patch": [], "scope": "annotations",
                 "action_name": "Add annotation",
                 "undo_stack_depth": 1, "redo_stack_depth": 0}
                """)
        let syncing: any AnnotationSyncing = makeClient(transport)
        let response = try await syncing.redoRemote()
        #expect(response.undoStackDepth == 1)
        #expect(transport.requestPaths() == ["POST /redo"])
    }
}
