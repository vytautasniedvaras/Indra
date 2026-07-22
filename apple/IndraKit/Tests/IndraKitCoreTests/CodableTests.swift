import Foundation
import Testing

@testable import IndraKitCore

@Suite("Codable wire types")
struct CodableTests {
    @Test func jobInfoDecodesBackendJSON() throws {
        let json = """
            {"id": "abc123", "kind": "import", "state": "running", "progress": 0.42,
             "message": "hashing content", "eta_s": 12.5, "created_at": 1783360465.2,
             "started_at": 1783360465.3, "finished_at": null,
             "result_ref": null, "error": null}
            """
        let job = try IndraJSON.decoder().decode(JobInfo.self, from: Data(json.utf8))
        #expect(job.id == "abc123")
        #expect(job.state == .running)
        #expect(job.etaS == 12.5)
        #expect(!job.isTerminal)
    }

    @Test func jobInfoResultRef() throws {
        let json = """
            {"id": "j", "kind": "import", "state": "done", "progress": 1.0, "message": "",
             "eta_s": null, "created_at": 0, "started_at": 0, "finished_at": 1,
             "result_ref": {"audio_id": "deadbeef", "already_imported": false}, "error": null}
            """
        let job = try IndraJSON.decoder().decode(JobInfo.self, from: Data(json.utf8))
        #expect(job.resultRef?["audio_id"]?.stringValue == "deadbeef")
        #expect(job.resultRef?["already_imported"]?.boolValue == false)
        #expect(job.isTerminal)
    }

    @Test func manifestDecodesWithSpec() throws {
        let json = """
            {"id": "x", "sr": 44100, "channels": 2, "frames": 3969000, "duration_s": 90.0,
             "format": "WAV/PCM_16",
             "waveform_lods": [{"lod": 0, "bucket_samples": 256, "buckets": 15504}],
             "spec": {"n_fft": 4096, "hop": 1024, "window": "blackmanharris7",
                      "n_bins": 2049, "db_min": -100.0, "db_max": 0.0,
                      "mono_downmix": true,
                      "lods": [{"lod": 0, "frames": 3872, "frames_per_column": 1}]},
             "features": []}
            """
        let manifest = try IndraJSON.decoder().decode(FileManifest.self, from: Data(json.utf8))
        #expect(manifest.spec?.nBins == 2049)
        #expect(manifest.spec?.lods.first?.framesPerColumn == 1)
        #expect(manifest.waveformLods.first?.bucketSamples == 256)
    }

    @Test func manifestDecodesWithoutSpec() throws {
        let json = """
            {"id": "x", "sr": 22050, "channels": 1, "frames": 100, "duration_s": 1.0,
             "format": "WAV/FLOAT", "waveform_lods": [], "spec": null, "features": []}
            """
        let manifest = try IndraJSON.decoder().decode(FileManifest.self, from: Data(json.utf8))
        #expect(manifest.spec == nil)
    }

    @Test func errorEnvelope() throws {
        let json = """
            {"error": {"code": "not_found", "message": "no such job: x", "details": {}}}
            """
        let envelope = try IndraJSON.decoder().decode(ApiErrorEnvelope.self, from: Data(json.utf8))
        #expect(envelope.error.code == "not_found")
    }

    @Test func sessionInfoRoundTrip() throws {
        let session = SessionInfo(port: 40213, token: "tok", pid: 99, project: "/tmp/x.indra")
        let data = try IndraJSON.encoder().encode(session)
        let back = try IndraJSON.decoder().decode(SessionInfo.self, from: data)
        #expect(back == session)
    }

    @Test func editorStateRoundTrip() throws {
        let state = EditorState(
            activeAudioId: "f1",
            selection: Selection(t0: 1, t1: 2, f0: 100, f1: 500),
            annotations: [Annotation(id: "a", audioId: "f1", t0: 0, t1: 1, note: "n")],
            lensesEnabled: ["roughness"])
        let data = try IndraJSON.encoder().encode(state)
        let back = try IndraJSON.decoder().decode(EditorState.self, from: data)
        #expect(back == state)
    }

    @Test func annotationRecordDecodesSnakeCase() throws {
        let json = """
            {"id": 7, "audio_id": "abc", "t0": 0.5, "t1": 1.5, "f0": null, "f1": null,
             "label": null, "note": "interesting", "created_at": "2026-07-06T09:00:00Z",
             "updated_at": "2026-07-06T09:30:00Z"}
            """
        let record = try IndraJSON.decoder().decode(AnnotationRecord.self, from: Data(json.utf8))
        #expect(record.id == 7)
        #expect(record.audioId == "abc")
        #expect(record.f0 == nil)
        #expect(record.note == "interesting")
        #expect(record.updatedAt == "2026-07-06T09:30:00Z")
        // Local editor-state mirror keeps the server id as a string.
        #expect(record.asAnnotation.id == "7")
        #expect(record.asAnnotation.audioId == "abc")
    }

    @Test func annotationRecordRoundTrip() throws {
        let record = AnnotationRecord(
            id: 3, audioId: "a", t0: 1, t1: 2, f0: 100, f1: 200, label: "bird",
            note: nil, createdAt: "t0", updatedAt: "t1")
        let data = try IndraJSON.encoder().encode(record)
        let back = try IndraJSON.decoder().decode(AnnotationRecord.self, from: data)
        #expect(back == record)
    }

    @Test func annotationCreateEncodesSnakeCaseAndOmitsNil() throws {
        let create = AnnotationCreate(audioId: "abc", t0: 1, t1: 2, label: "x")
        let text = String(decoding: try IndraJSON.encoder().encode(create), as: UTF8.self)
        #expect(text.contains("\"audio_id\":\"abc\""))
        #expect(!text.contains("note"))  // nil optionals stay off the wire
        #expect(!text.contains("f0"))
    }

    @Test func annotationPatchRoundTripKeepsOnlySetFields() throws {
        let patch = AnnotationPatch(t0: 2.5, label: "owl")
        let data = try IndraJSON.encoder().encode(patch)
        let back = try IndraJSON.decoder().decode(AnnotationPatch.self, from: data)
        #expect(back == patch)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?.count == 2)
    }

    @Test func undoResponseDecodesSnakeCase() throws {
        let json = """
            {"applied_patch": [{"op": "add", "path": "/annotations/0",
                                "value": {"label": "bird"}}],
             "scope": "annotations", "action_name": "Delete annotation",
             "undo_stack_depth": 4, "redo_stack_depth": 2}
            """
        let response = try IndraJSON.decoder().decode(UndoResponse.self, from: Data(json.utf8))
        #expect(response.actionName == "Delete annotation")
        #expect(response.undoStackDepth == 4)
        #expect(response.redoStackDepth == 2)
        if case .object(let op)? = response.appliedPatch.first {
            #expect(op["op"]?.stringValue == "add")
        } else {
            Issue.record("expected a patch-op object")
        }
    }

    @Test func historyEntryDecodesSnakeCase() throws {
        let json = """
            {"id": 42, "ts": "2026-07-06T10:00:00Z", "scope": "annotations",
             "action_name": "Edit annotation"}
            """
        let entry = try IndraJSON.decoder().decode(HistoryEntry.self, from: Data(json.utf8))
        #expect(entry.id == 42)
        #expect(entry.scope == "annotations")
        #expect(entry.actionName == "Edit annotation")
    }

    @Test func jsonValueRoundTrip() throws {
        let value = JSONValue.object([
            "steps": .number(20), "label": .string("x"), "flag": .bool(true),
            "nested": .array([.number(1), .null]),
        ])
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == value)
    }
}
