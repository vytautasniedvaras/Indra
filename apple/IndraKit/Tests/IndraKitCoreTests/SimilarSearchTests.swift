import Testing

@testable import IndraKitCore

// select_similar result_ref parsing — the constellation view's data source
// (docs/design/selection-ux.md §3). Wire keys are snake_case; the same
// payload may arrive camelCased after convertFromSnakeCase.

@Suite("SimilarSearchResult")
struct SimilarSearchTests {
    private let folderWide: [String: JSONValue] = [
        "kind": .string("select_similar"),
        "audio_id": .string("a1"),
        "threshold": .number(0.35),
        "scanned": .array([.string("a1"), .string("b2")]),
        "segments": .array([
            .object([
                "audio_id": .string("a1"), "t0": .number(3.0), "t1": .number(5.1),
                "distance": .number(0.05),
            ]),
            .object([
                "audio_id": .string("b2"), "t0": .number(8.0), "t1": .number(10.0),
                "distance": .number(0.21),
            ]),
        ]),
        "embedding": .object([
            "xy": .array([
                .array([.number(0.1), .number(-0.2)]),
                .array([.number(0.4), .number(0.3)]),
            ]),
            "cluster": .array([.number(1), .number(1)]),
            "n_clusters": .number(1),
            "seed_xy": .array([.number(0.05), .number(-0.1)]),
        ]),
    ]

    @Test func parsesFolderWideResultWithEmbedding() {
        let result = SimilarSearchResult(resultRef: folderWide)
        #expect(result != nil)
        #expect(result?.segments.count == 2)
        #expect(result?.segments[0].audioId == "a1")
        #expect(result?.segments[1].audioId == "b2")
        #expect(result?.segments[1].t0 == 8.0)
        #expect(result?.threshold == 0.35)
        #expect(result?.scanned == ["a1", "b2"])
        #expect(result?.embedding?.xy == [[0.1, -0.2], [0.4, 0.3]])
        #expect(result?.embedding?.cluster == [1, 1])
        #expect(result?.embedding?.nClusters == 1)
        #expect(result?.embedding?.seedXY == [0.05, -0.1])
    }

    @Test func parsesCamelCasedKeys() {
        // Same payload after convertFromSnakeCase mangled the dictionary keys.
        var converted = folderWide
        var segments: [JSONValue] = []
        if case .array(let raw)? = folderWide["segments"] {
            for entry in raw {
                guard case .object(var fields) = entry else { continue }
                fields["audioId"] = fields.removeValue(forKey: "audio_id")
                segments.append(.object(fields))
            }
        }
        converted["segments"] = .array(segments)
        if case .object(var embedding)? = folderWide["embedding"] {
            embedding["nClusters"] = embedding.removeValue(forKey: "n_clusters")
            embedding["seedXy"] = embedding.removeValue(forKey: "seed_xy")
            converted["embedding"] = .object(embedding)
        }
        let result = SimilarSearchResult(resultRef: converted)
        #expect(result?.segments[1].audioId == "b2")
        #expect(result?.embedding?.nClusters == 1)
        #expect(result?.embedding?.seedXY == [0.05, -0.1])
    }

    @Test func singleFileSegmentsHaveNoAudioId() {
        let ref: [String: JSONValue] = [
            "threshold": .number(0.4),
            "segments": .array([
                .object(["t0": .number(1.0), "t1": .number(2.0), "distance": .number(0.1)])
            ]),
        ]
        let result = SimilarSearchResult(resultRef: ref)
        #expect(result?.segments.first?.audioId == nil)
        #expect(result?.scanned.isEmpty == true)
        #expect(result?.embedding == nil)
    }

    @Test func nonSearchPayloadIsNil() {
        #expect(SimilarSearchResult(resultRef: ["selection_id": .string("x")]) == nil)
    }
}
